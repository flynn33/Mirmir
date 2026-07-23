import Foundation

struct R09ResidualProducerCapability: Sendable {
    fileprivate init() {}

#if DEBUG
    static func testingOnly() -> Self { Self() }
#endif
}

struct R09RawResidualPlaneQ16: Hashable, Sendable {
    let id: R09ResidualPlaneID
    let width: Int
    let height: Int
    let samplesQ16: [Int64]
}

struct R09RawResidualProviderOutput: Hashable, Sendable {
    let executionIdentity: R09ResidualExecutionIdentity
    let planes: [R09RawResidualPlaneQ16]
    let confidenceQ15: Int64
    let workingSetBytes: Int64
    let elapsedMicroseconds: Int64
}

typealias R09ResidualProvider = @Sendable (
    R09ResidualRequest
) async throws -> R09RawResidualProviderOutput

private struct R09ResidualSampleBounds {
    let current: Int64
    let source: Int64
    let temporal: Int64
    let approvalQ15: Int64
    let protectionQ15: Int64
    let edgeLimitQ16: Int64
    let planeLimitQ16: Int64
    let contentLimitQ16: Int64
    let consistencyLimits: R09ConsistencyLimitsQ16
}

enum R09DeterministicResidualProvider {
    static let nominalWorkingSetBytes: Int64 = 4_096
    static let nominalElapsedMicroseconds: Int64 = 1_000

    static func predict(
        request: R09ResidualRequest
    ) async throws -> R09RawResidualProviderOutput {
        let planes = R09ResidualPlaneID.allCases.map { id in
            let current = request.postScalerFrame[id]
            let source = request.sourceReference.frame[id]
            let temporal = request.temporalReference.frame[id]
            let samples = current.samplesQ16.indices.map { index in
                preferredResidual(
                    current: current.samplesQ16[index],
                    source: source.samplesQ16[index],
                    temporal: temporal.samplesQ16[index]
                )
            }
            return R09RawResidualPlaneQ16(
                id: id,
                width: current.width,
                height: current.height,
                samplesQ16: samples
            )
        }
        return R09RawResidualProviderOutput(
            executionIdentity: .deterministicSimulationV1,
            planes: planes,
            confidenceQ15: min(
                request.confidenceBudget.ashEligibilityQ15,
                request.confidenceBudget.sourceReferenceQ15,
                request.confidenceBudget.temporalReferenceQ15
            ),
            workingSetBytes: nominalWorkingSetBytes,
            elapsedMicroseconds: nominalElapsedMicroseconds
        )
    }

    private static func preferredResidual(
        current: Int64,
        source: Int64,
        temporal: Int64
    ) -> Int64 {
        let sourceDelta = source - current
        let temporalDelta = temporal - current
        let sourceSign = R09ResidualMath.sign(sourceDelta)
        let temporalSign = R09ResidualMath.sign(temporalDelta)
        guard sourceSign != 0, sourceSign == temporalSign else {
            return 0
        }
        let evidenceMagnitude = min(
            R09ResidualMath.magnitude(sourceDelta),
            R09ResidualMath.magnitude(temporalDelta)
        )
        let proposedMagnitude = min(
            (evidenceMagnitude + 1) / 2,
            R09PlaneResidualLimitQ16.hardMaximumMagnitude
        )
        return sourceSign * proposedMagnitude
    }
}

actor R09DeterministicResidualService: R09CoreAIResidualService {
    private let provider: R09ResidualProvider
    private let availabilityFailure: R09ResidualAvailabilityReason?
    private let policyEnabled: Bool
    private var isInFlight = false

    init(
        availabilityFailure: R09ResidualAvailabilityReason? = nil,
        policyEnabled: Bool = true
    ) {
        self.availabilityFailure = availabilityFailure
        self.policyEnabled = policyEnabled
        self.provider = { request in
            try await R09DeterministicResidualProvider.predict(request: request)
        }
    }

#if DEBUG
    init(
        testingProvider: @escaping R09ResidualProvider,
        availabilityFailure: R09ResidualAvailabilityReason? = nil,
        policyEnabled: Bool = true
    ) {
        self.availabilityFailure = availabilityFailure
        self.policyEnabled = policyEnabled
        self.provider = testingProvider
    }
#endif

    func predictResidual(for request: R09ResidualRequest) async -> R09ResidualDisposition {
        if let reason = preflightFailure(for: request) {
            return bypass(request, reason: reason)
        }
        guard !isInFlight else {
            return bypass(request, reason: .busy)
        }

        isInFlight = true
        defer { isInFlight = false }

        let raw: R09RawResidualProviderOutput
        do {
            raw = try await provider(request)
        } catch is CancellationError {
            return bypass(request, reason: .cancelled)
        } catch {
            return bypass(request, reason: .providerFailed)
        }
        guard !Task.isCancelled else {
            return bypass(request, reason: .cancelled)
        }
        return validatedDisposition(raw, request: request)
    }
}

private extension R09DeterministicResidualService {
    func validatedDisposition(
        _ raw: R09RawResidualProviderOutput,
        request: R09ResidualRequest
    ) -> R09ResidualDisposition {
        do {
            let indexed = try validate(raw, for: request)
            if let limitFailure = planeLimitFailure(indexed, request: request) {
                return bypass(request, reason: limitFailure)
            }
            if raw.confidenceQ15 < request.confidenceBudget.minimumRequiredQ15 {
                return bypass(
                    request,
                    reason: .confidenceBelowMinimum(
                        role: .providerOutput,
                        minimumQ15: request.confidenceBudget.minimumRequiredQ15,
                        actualQ15: raw.confidenceQ15
                    )
                )
            }
            if raw.workingSetBytes > request.resourceBudget.maximumWorkingSetBytes {
                return bypass(
                    request,
                    reason: .resourceBudgetExceeded(
                        role: .workingSetBytes,
                        maximum: request.resourceBudget.maximumWorkingSetBytes,
                        actual: raw.workingSetBytes
                    )
                )
            }
            if raw.elapsedMicroseconds > request.resourceBudget.maximumElapsedMicroseconds {
                return bypass(
                    request,
                    reason: .resourceBudgetExceeded(
                        role: .elapsedMicroseconds,
                        maximum: request.resourceBudget.maximumElapsedMicroseconds,
                        actual: raw.elapsedMicroseconds
                    )
                )
            }

            let residual = try boundedResidual(raw: indexed, request: request)
            guard residual.orderedPlanes.contains(where: { plane in
                plane.samplesQ16.contains(where: { $0 != 0 })
            }) else {
                return bypass(request, reason: .sourceTemporalConsistencyRejected)
            }
            let resourceMeasurement = try R09ResidualResourceMeasurement(
                workingSetBytes: raw.workingSetBytes,
                elapsedMicroseconds: raw.elapsedMicroseconds
            )
            return .produced(
                try R09ResidualOutput(
                    producerCapability: R09ResidualProducerCapability(),
                    requestIdentity: request.identity,
                    authorization: request.authorization,
                    scalerIdentity: request.scalerIdentity,
                    modelIdentity: request.modelIdentity,
                    executionIdentity: raw.executionIdentity,
                    residual: residual,
                    confidenceQ15: raw.confidenceQ15,
                    resourceMeasurement: resourceMeasurement
                )
            )
        } catch let error as R09ResidualProviderOutputError {
            return bypass(request, reason: .invalidProviderOutput(error))
        } catch {
            return bypass(
                request,
                reason: .invalidProviderOutput(.invalidResourceMeasurement)
            )
        }
    }

    func planeLimitFailure(
        _ raw: [R09ResidualPlaneID: R09RawResidualPlaneQ16],
        request: R09ResidualRequest
    ) -> R09ResidualBypassReason? {
        for planeID in R09ResidualPlaneID.allCases {
            guard let plane = raw[planeID] else { continue }
            let maximum = request.limits.perPlane[planeID].maximumMagnitudeQ16
            for (index, value) in plane.samplesQ16.enumerated()
            where R09ResidualMath.magnitude(value) > maximum {
                return .planeLimitExceeded(
                    plane: planeID,
                    index: index,
                    maximumMagnitudeQ16: maximum,
                    actualQ16: value
                )
            }
        }
        return nil
    }

    func preflightFailure(
        for request: R09ResidualRequest
    ) -> R09ResidualBypassReason? {
        if Task.isCancelled {
            return .cancelled
        }
        guard policyEnabled else {
            return .disabledByPolicy
        }
        if let availabilityFailure {
            return .unavailable(availabilityFailure)
        }
        guard hasValidSimulationBinding(request) else {
            return .identityInvalid
        }
        if let reason = confidenceFailure(request.confidenceBudget) {
            return reason
        }
        guard request.safetySignal.hallucinationRiskQ15
                <= request.safetySignal.maximumAllowedHallucinationRiskQ15 else {
            return .hallucinationRiskExceeded(
                maximumAllowedQ15: request.safetySignal.maximumAllowedHallucinationRiskQ15,
                actualQ15: request.safetySignal.hallucinationRiskQ15
            )
        }
        guard hasEligibleRegion(request) else {
            return .noEligibleRegion
        }
        return nil
    }

    func hasValidSimulationBinding(_ request: R09ResidualRequest) -> Bool {
        request.authorization.scope == .deterministicSimulationOnly
            && request.scalerIdentity.backendID
                == R09AppleScalerIdentity.deterministicPrimaryBackendID
            && request.scalerIdentity.implementationVersion
                == R09AppleScalerIdentity.deterministicPrimaryBackendVersion
            && request.scalerIdentity.kind == .metalPerformanceShaders
            && request.scalerIdentity.scaleNumerator == 2
            && request.scalerIdentity.scaleDenominator == 1
            && request.scalerIdentity.processingIdentity.route.backend.modelAssetsIdentity
                == .notRequired
            && request.scalerIdentity.executionMode == .deterministicFixtureSimulation
            && request.scalerIdentity.nativeExecution == .notObserved
            && request.modelIdentity.modelID == R09ResidualModelIdentity.deterministicModelID
            && request.modelIdentity.modelVersion
                == R09ResidualModelIdentity.deterministicModelVersion
            && request.modelIdentity.artifactKind == .deterministicSimulationContract
            && request.modelIdentity.contentSHA256
                == R09ResidualModelIdentity.deterministicProviderSHA256
            && request.modelIdentity.preprocessingIdentity
                == R09ResidualModelIdentity.deterministicPreprocessingIdentity
            && request.modelIdentity.postprocessingIdentity
                == R09ResidualModelIdentity.deterministicPostprocessingIdentity
            && request.modelIdentity.residualContractIdentity
                == R09ResidualModelIdentity.deterministicResidualContractIdentity
            && request.identity.ioContractSHA256 == R09ResidualRequestIdentity.ioContractSHA256
    }

    func confidenceFailure(
        _ budget: R09ResidualConfidenceBudget
    ) -> R09ResidualBypassReason? {
        let values: [(R09ResidualConfidenceRole, Int64)] = [
            (.ashEligibility, budget.ashEligibilityQ15),
            (.sourceReference, budget.sourceReferenceQ15),
            (.temporalReference, budget.temporalReferenceQ15)
        ]
        guard let failure = values.first(where: { $0.1 < budget.minimumRequiredQ15 }) else {
            return nil
        }
        return .confidenceBelowMinimum(
            role: failure.0,
            minimumQ15: budget.minimumRequiredQ15,
            actualQ15: failure.1
        )
    }

    func hasEligibleRegion(_ request: R09ResidualRequest) -> Bool {
        R09ResidualPlaneID.allCases.contains { id in
            let approval = request.ashApprovedMask[id].samplesQ15
            let protection = request.protectedMask[id].samplesQ15
            let edge = request.limits.edge[id].maximumMagnitudesQ16
            let planeLimit = request.limits.perPlane[id].maximumMagnitudeQ16
            guard planeLimit > 0, request.limits.content.maximumMagnitudeQ16 > 0 else {
                return false
            }
            return approval.indices.contains { index in
                approval[index] > 0
                    && protection[index] == 0
                    && edge[index] > 0
            }
        }
    }

    func validate(
        _ raw: R09RawResidualProviderOutput,
        for request: R09ResidualRequest
    ) throws -> [R09ResidualPlaneID: R09RawResidualPlaneQ16] {
        guard raw.executionIdentity == .deterministicSimulationV1 else {
            throw R09ResidualProviderOutputError.executionIdentityMismatch
        }
        guard (0...R09MaskPlaneQ15.maximumSample).contains(raw.confidenceQ15) else {
            throw R09ResidualProviderOutputError.invalidConfidence(raw.confidenceQ15)
        }
        guard raw.workingSetBytes >= 0, raw.elapsedMicroseconds >= 0 else {
            throw R09ResidualProviderOutputError.invalidResourceMeasurement
        }
        guard raw.planes.count == R09ResidualPlaneID.allCases.count else {
            throw R09ResidualProviderOutputError.planeCountMismatch(
                expected: R09ResidualPlaneID.allCases.count,
                actual: raw.planes.count
            )
        }

        var indexed: [R09ResidualPlaneID: R09RawResidualPlaneQ16] = [:]
        for plane in raw.planes {
            guard indexed.updateValue(plane, forKey: plane.id) == nil else {
                throw R09ResidualProviderOutputError.duplicatePlane(plane.id)
            }
        }
        for id in R09ResidualPlaneID.allCases {
            guard let plane = indexed[id] else {
                throw R09ResidualProviderOutputError.missingPlane(id)
            }
            let expected = request.postScalerFrame[id]
            guard plane.width == expected.width, plane.height == expected.height else {
                throw R09ResidualProviderOutputError.geometryMismatch(id)
            }
            guard plane.samplesQ16.count == expected.samplesQ16.count else {
                throw R09ResidualProviderOutputError.sampleCountMismatch(id)
            }
            let maximumMagnitude = R09PlaneResidualLimitQ16.hardMaximumMagnitude
            for (index, value) in plane.samplesQ16.enumerated() {
                guard (-maximumMagnitude...maximumMagnitude).contains(value) else {
                    throw R09ResidualProviderOutputError.sampleOutOfRange(
                        plane: id,
                        index: index,
                        value: value
                    )
                }
                guard isDirectionConsistent(
                    value,
                    current: expected.samplesQ16[index],
                    source: request.sourceReference.frame[id].samplesQ16[index],
                    temporal: request.temporalReference.frame[id].samplesQ16[index]
                ) else {
                    throw R09ResidualProviderOutputError.directionInconsistent(
                        plane: id,
                        index: index
                    )
                }
            }
        }
        return indexed
    }

    func isDirectionConsistent(
        _ residual: Int64,
        current: Int64,
        source: Int64,
        temporal: Int64
    ) -> Bool {
        guard residual != 0 else { return true }
        let direction = R09ResidualMath.sign(residual)
        return R09ResidualMath.sign(source - current) == direction
            && R09ResidualMath.sign(temporal - current) == direction
    }

    func boundedResidual(
        raw: [R09ResidualPlaneID: R09RawResidualPlaneQ16],
        request: R09ResidualRequest
    ) throws -> R09PlanarResidualQ16 {
        let planes = try R09ResidualPlaneID.allCases.map { id in
            guard let rawPlane = raw[id] else {
                throw R09ResidualProviderOutputError.missingPlane(id)
            }
            let current = request.postScalerFrame[id]
            let source = request.sourceReference.frame[id]
            let temporal = request.temporalReference.frame[id]
            let approval = request.ashApprovedMask[id]
            let protection = request.protectedMask[id]
            let edge = request.limits.edge[id]
            let samples = rawPlane.samplesQ16.indices.map { index in
                boundedSample(
                    rawPlane.samplesQ16[index],
                    bounds: R09ResidualSampleBounds(
                        current: current.samplesQ16[index],
                        source: source.samplesQ16[index],
                        temporal: temporal.samplesQ16[index],
                        approvalQ15: approval.samplesQ15[index],
                        protectionQ15: protection.samplesQ15[index],
                        edgeLimitQ16: edge.maximumMagnitudesQ16[index],
                        planeLimitQ16:
                            request.limits.perPlane[id].maximumMagnitudeQ16,
                        contentLimitQ16: request.limits.content.maximumMagnitudeQ16,
                        consistencyLimits: request.limits.consistency
                    )
                )
            }
            return try R09SignedResidualPlaneQ16(
                id: id,
                width: current.width,
                height: current.height,
                samplesQ16: samples
            )
        }
        return try R09PlanarResidualQ16(planes: planes)
    }

    func boundedSample(
        _ raw: Int64,
        bounds: R09ResidualSampleBounds
    ) -> Int64 {
        guard raw != 0 else { return 0 }
        let sourceMagnitude = R09ResidualMath.magnitude(bounds.source - bounds.current)
        let temporalMagnitude = R09ResidualMath.magnitude(bounds.temporal - bounds.current)
        let limit = min(
            sourceMagnitude,
            temporalMagnitude,
            bounds.consistencyLimits.sourceMaximumMagnitudeQ16,
            bounds.consistencyLimits.temporalMaximumMagnitudeQ16,
            bounds.planeLimitQ16,
            bounds.contentLimitQ16,
            bounds.edgeLimitQ16
        )
        let clamped = R09ResidualMath.sign(raw) * min(R09ResidualMath.magnitude(raw), limit)
        let approved = clamped * bounds.approvalQ15 / R09MaskPlaneQ15.maximumSample
        let inverseProtection = R09MaskPlaneQ15.maximumSample - bounds.protectionQ15
        return approved * inverseProtection / R09MaskPlaneQ15.maximumSample
    }

    func bypass(
        _ request: R09ResidualRequest,
        reason: R09ResidualBypassReason
    ) -> R09ResidualDisposition {
        .bypassed(
            R09ResidualBypass(
                requestIdentity: request.identity,
                authorization: request.authorization,
                scalerIdentity: request.scalerIdentity,
                modelIdentity: request.modelIdentity,
                executionIdentity: .deterministicSimulationV1,
                reason: reason
            )
        )
    }
}
