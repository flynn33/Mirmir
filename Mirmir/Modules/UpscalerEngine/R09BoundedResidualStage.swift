import Foundation

enum R09ResidualApplicationBypassReason: Error, Equatable, Sendable {
    case proposalService(R09ResidualBypassReason)
    case transactionBusy
    case proposalIdentityMismatch
    case proposalConfidenceBelowMinimum(minimumQ15: Int64, actualQ15: Int64)
    case proposalResourceBudgetExceeded(
        role: R09ResidualResourceRole,
        maximum: Int64,
        actual: Int64
    )
    case hallucinationRiskExceeded(maximumAllowedQ15: Int64, actualQ15: Int64)
    case authorizationInvalid
    case appleScalerIdentityMismatch
    case appleScalerFrameMismatch
    case postScalerFrameMismatch
    case residualGeometryMismatch(R09ResidualPlaneID)
    case unauthorizedSample(plane: R09ResidualPlaneID, index: Int)
    case protectedSample(plane: R09ResidualPlaneID, index: Int)
    case residualLimitExceeded(plane: R09ResidualPlaneID, index: Int)
    case sourceConsistencyRejected(plane: R09ResidualPlaneID, index: Int)
    case temporalConsistencyRejected(plane: R09ResidualPlaneID, index: Int)
    case noAppliedSamples
    case codec(R09NV12PlanarCodecError)
    case contract(R09ResidualContractError)
    case correctedFrameConstructionFailed
}

struct R09ResidualApplicationReceipt: Hashable, Sendable {
    let requestIdentity: R09ResidualRequestIdentity
    let authorization: R09ResidualAuthorizationIdentity
    let appleScalerIdentity: R09AppleScalerIdentity
    let appleProcessingIdentity: AppleUpscaleProcessingIdentity
    let modelIdentity: R09ResidualModelIdentity
    let executionIdentity: R09ResidualExecutionIdentity
    let limits: R09ResidualLimits
    let confidenceBudget: R09ResidualConfidenceBudget
    let resourceBudget: R09ResidualResourceBudget
    let safetySignal: R09ResidualSafetySignal
    let providerConfidenceQ15: Int64
    let resourceMeasurement: R09ResidualResourceMeasurement
    let appliedSampleCount: Int
    let appleOnlyRollbackPreserved: Bool
}

struct R09AppliedResidualFrame: Sendable {
    let correctedFrame: AppleUpscaleProcessedFrame
    let appleOnlyFrame: AppleUpscaleProcessedFrame
    let correctedPlanarFrame: R09PlanarFrameQ16
    let receipt: R09ResidualApplicationReceipt

    var rollbackFrame: AppleUpscaleProcessedFrame {
        appleOnlyFrame
    }
}

struct R09BypassedResidualFrame: Sendable {
    let appleOnlyFrame: AppleUpscaleProcessedFrame
    let reason: R09ResidualApplicationBypassReason
    let fallbackRoute = R09ResidualFallbackRoute.appleScalerOutputUnmodified
}

enum R09ResidualApplicationOutcome: Sendable {
    case applied(R09AppliedResidualFrame)
    case bypassed(R09BypassedResidualFrame)
}

actor R09BoundedResidualStage {
    static let acceptedR08FunctionalAcceptanceSHA256 =
        "0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0"
    static let deterministicPrimaryBackendID = R09AppleScalerIdentity.deterministicPrimaryBackendID
    static let deterministicPrimaryBackendVersion =
        R09AppleScalerIdentity.deterministicPrimaryBackendVersion
    static let deterministicModelID = R09ResidualModelIdentity.deterministicModelID
    static let deterministicModelVersion = R09ResidualModelIdentity.deterministicModelVersion

    private var isInFlight = false

    func process(
        request: R09ResidualRequest,
        appleOnlyFrame: AppleUpscaleProcessedFrame,
        service: any R09CoreAIResidualService
    ) async -> R09ResidualApplicationOutcome {
        guard !isInFlight else {
            return Self.fallback(appleOnlyFrame, reason: .transactionBusy)
        }
        isInFlight = true
        defer { isInFlight = false }
        guard !Task.isCancelled else {
            return Self.fallback(appleOnlyFrame, reason: .proposalService(.cancelled))
        }
        let disposition = await service.predictResidual(for: request)
        guard !Task.isCancelled else {
            return Self.fallback(appleOnlyFrame, reason: .proposalService(.cancelled))
        }
        let outcome = Self.apply(disposition, request: request, to: appleOnlyFrame)
        guard !Task.isCancelled else {
            return Self.fallback(appleOnlyFrame, reason: .proposalService(.cancelled))
        }
        return outcome
    }

    private static func apply(
        _ disposition: R09ResidualDisposition,
        request: R09ResidualRequest,
        to appleOnlyFrame: AppleUpscaleProcessedFrame
    ) -> R09ResidualApplicationOutcome {
        switch disposition {
        case .bypassed(let bypass):
            let reason: R09ResidualApplicationBypassReason =
                bypassMatchesRequest(bypass, request: request)
                ? .proposalService(bypass.reason)
                : .proposalIdentityMismatch
            return fallback(appleOnlyFrame, reason: reason)
        case .produced(let output):
            return applyProduced(
                output,
                request: request,
                to: appleOnlyFrame
            )
        }
    }
}

private extension R09BoundedResidualStage {
    static func applyProduced(
        _ output: R09ResidualOutput,
        request: R09ResidualRequest,
        to appleOnlyFrame: AppleUpscaleProcessedFrame
    ) -> R09ResidualApplicationOutcome {
        guard !Task.isCancelled else {
            return fallback(appleOnlyFrame, reason: .proposalService(.cancelled))
        }
        do {
            try validateAuthorization(request)
            try validateOutputIdentity(output, request: request)
            try validateAppleFrame(appleOnlyFrame, request: request)
            let decoded = try R09NV12PlanarCodec.decode(appleOnlyFrame.pixelBuffer)
            guard decoded == request.postScalerFrame else {
                throw R09ResidualApplicationBypassReason.postScalerFrameMismatch
            }
            let correction = try correctedFrame(
                base: decoded,
                residual: output.residual,
                request: request
            )
            let correctedBuffer = try R09NV12PlanarCodec.encode(
                correction.frame,
                matching: appleOnlyFrame.pixelBuffer
            )
            let materializedFrame = try R09NV12PlanarCodec.decode(correctedBuffer)
            try R09NV12PlanarCodec.requireExactRepresentation(
                correction.frame,
                materialized: materializedFrame
            )
            let token = try AppleUpscaleResourceLifetimeToken(
                identity: "\(appleOnlyFrame.resourceLifetimeToken.identity).r09.corrected",
                releaseAction: {}
            )
            let correctedFrame = try AppleUpscaleProcessedFrame(
                sequenceNumber: appleOnlyFrame.sequenceNumber,
                pixelBuffer: correctedBuffer,
                presentationTimestamp: appleOnlyFrame.presentationTimestamp,
                duration: appleOnlyFrame.duration,
                colorDescription: appleOnlyFrame.colorDescription,
                metadataIdentity: appleOnlyFrame.metadataIdentity,
                resourceLifetimeToken: token,
                processingIdentity: appleOnlyFrame.processingIdentity
            )
            return .applied(
                R09AppliedResidualFrame(
                    correctedFrame: correctedFrame,
                    appleOnlyFrame: appleOnlyFrame,
                    correctedPlanarFrame: materializedFrame,
                    receipt: R09ResidualApplicationReceipt(
                        requestIdentity: request.identity,
                        authorization: request.authorization,
                        appleScalerIdentity: request.scalerIdentity,
                        appleProcessingIdentity: appleOnlyFrame.processingIdentity,
                        modelIdentity: request.modelIdentity,
                        executionIdentity: output.executionIdentity,
                        limits: request.limits,
                        confidenceBudget: request.confidenceBudget,
                        resourceBudget: request.resourceBudget,
                        safetySignal: request.safetySignal,
                        providerConfidenceQ15: output.confidenceQ15,
                        resourceMeasurement: output.resourceMeasurement,
                        appliedSampleCount: correction.appliedSampleCount,
                        appleOnlyRollbackPreserved: true
                    )
                )
            )
        } catch let reason as R09ResidualApplicationBypassReason {
            return fallback(appleOnlyFrame, reason: reason)
        } catch let error as R09NV12PlanarCodecError {
            return fallback(appleOnlyFrame, reason: .codec(error))
        } catch let error as R09ResidualContractError {
            return fallback(appleOnlyFrame, reason: .contract(error))
        } catch {
            return fallback(appleOnlyFrame, reason: .correctedFrameConstructionFailed)
        }
    }

    static func validateAuthorization(_ request: R09ResidualRequest) throws {
        guard request.authorization.referencedR08AcceptanceSHA256
                == acceptedR08FunctionalAcceptanceSHA256,
              request.authorization.scope == .deterministicSimulationOnly,
              request.identity.ioContractSHA256 == R09ResidualRequestIdentity.ioContractSHA256,
              request.scalerIdentity.backendID == deterministicPrimaryBackendID,
              request.scalerIdentity.implementationVersion
                == deterministicPrimaryBackendVersion,
              request.scalerIdentity.kind == .metalPerformanceShaders,
              request.scalerIdentity.scaleNumerator == 2,
              request.scalerIdentity.scaleDenominator == 1,
              request.scalerIdentity.processingIdentity.route.backend.modelAssetsIdentity
                == .notRequired,
              request.modelIdentity.artifactKind == .deterministicSimulationContract,
              request.modelIdentity.modelID == deterministicModelID,
              request.modelIdentity.modelVersion == deterministicModelVersion,
              request.modelIdentity.contentSHA256
                == R09ResidualModelIdentity.deterministicProviderSHA256,
              request.modelIdentity.preprocessingIdentity
                == R09ResidualModelIdentity.deterministicPreprocessingIdentity,
              request.modelIdentity.postprocessingIdentity
                == R09ResidualModelIdentity.deterministicPostprocessingIdentity,
              request.modelIdentity.residualContractIdentity
                == R09ResidualModelIdentity.deterministicResidualContractIdentity,
              request.scalerIdentity.executionMode == .deterministicFixtureSimulation,
              request.scalerIdentity.nativeExecution == .notObserved,
              request.confidenceBudget.ashEligibilityQ15
                >= request.confidenceBudget.minimumRequiredQ15,
              request.confidenceBudget.sourceReferenceQ15
                >= request.confidenceBudget.minimumRequiredQ15,
              request.confidenceBudget.temporalReferenceQ15
                >= request.confidenceBudget.minimumRequiredQ15 else {
            throw R09ResidualApplicationBypassReason.authorizationInvalid
        }
        guard request.safetySignal.hallucinationRiskQ15
                <= request.safetySignal.maximumAllowedHallucinationRiskQ15 else {
            throw R09ResidualApplicationBypassReason.hallucinationRiskExceeded(
                maximumAllowedQ15:
                    request.safetySignal.maximumAllowedHallucinationRiskQ15,
                actualQ15: request.safetySignal.hallucinationRiskQ15
            )
        }
    }

    static func validateOutputIdentity(
        _ output: R09ResidualOutput,
        request: R09ResidualRequest
    ) throws {
        guard output.requestIdentity == request.identity,
              output.authorization == request.authorization,
              output.scalerIdentity == request.scalerIdentity,
              output.modelIdentity == request.modelIdentity,
              output.executionIdentity == .deterministicSimulationV1 else {
            throw R09ResidualApplicationBypassReason.proposalIdentityMismatch
        }
        guard output.confidenceQ15 >= request.confidenceBudget.minimumRequiredQ15 else {
            throw R09ResidualApplicationBypassReason.proposalConfidenceBelowMinimum(
                minimumQ15: request.confidenceBudget.minimumRequiredQ15,
                actualQ15: output.confidenceQ15
            )
        }
        guard output.resourceMeasurement.workingSetBytes
                <= request.resourceBudget.maximumWorkingSetBytes else {
            throw R09ResidualApplicationBypassReason.proposalResourceBudgetExceeded(
                role: .workingSetBytes,
                maximum: request.resourceBudget.maximumWorkingSetBytes,
                actual: output.resourceMeasurement.workingSetBytes
            )
        }
        guard output.resourceMeasurement.elapsedMicroseconds
                <= request.resourceBudget.maximumElapsedMicroseconds else {
            throw R09ResidualApplicationBypassReason.proposalResourceBudgetExceeded(
                role: .elapsedMicroseconds,
                maximum: request.resourceBudget.maximumElapsedMicroseconds,
                actual: output.resourceMeasurement.elapsedMicroseconds
            )
        }
    }

    static func validateAppleFrame(
        _ frame: AppleUpscaleProcessedFrame,
        request: R09ResidualRequest
    ) throws {
        let backend = frame.processingIdentity.route.backend
        guard frame.processingIdentity == request.scalerIdentity.processingIdentity,
              backend.backendID == request.scalerIdentity.backendID,
              backend.backendRevision == request.scalerIdentity.implementationVersion else {
            throw R09ResidualApplicationBypassReason.appleScalerIdentityMismatch
        }
        guard Int64(frame.sequenceNumber) == request.identity.frameOrdinal,
              frame.metadataIdentity.rawValue == request.identity.frameID else {
            throw R09ResidualApplicationBypassReason.appleScalerFrameMismatch
        }
    }

    static func bypassMatchesRequest(
        _ bypass: R09ResidualBypass,
        request: R09ResidualRequest
    ) -> Bool {
        bypass.requestIdentity == request.identity
            && bypass.authorization == request.authorization
            && bypass.scalerIdentity == request.scalerIdentity
            && bypass.modelIdentity == request.modelIdentity
            && bypass.executionIdentity == .deterministicSimulationV1
    }

    static func fallback(
        _ frame: AppleUpscaleProcessedFrame,
        reason: R09ResidualApplicationBypassReason
    ) -> R09ResidualApplicationOutcome {
        .bypassed(
            R09BypassedResidualFrame(
                appleOnlyFrame: frame,
                reason: reason
            )
        )
    }
}

private extension R09BoundedResidualStage {
    struct Correction {
        let frame: R09PlanarFrameQ16
        let appliedSampleCount: Int
    }

    struct SampleValidationContext {
        let baseQ16: Int64
        let approvalQ15: Int64
        let protectionQ15: Int64
        let edgeLimitQ16: Int64
        let sourceQ16: Int64
        let temporalQ16: Int64
    }

    static func correctedFrame(
        base: R09PlanarFrameQ16,
        residual: R09PlanarResidualQ16,
        request: R09ResidualRequest
    ) throws -> Correction {
        var planes: [R09UnsignedPlaneQ16] = []
        var appliedSampleCount = 0
        for planeID in R09ResidualPlaneID.allCases {
            let corrected = try correctedPlane(
                planeID,
                base: base[planeID],
                residual: residual[planeID],
                request: request
            )
            planes.append(corrected.plane)
            appliedSampleCount += corrected.appliedSampleCount
        }
        guard appliedSampleCount > 0 else {
            throw R09ResidualApplicationBypassReason.noAppliedSamples
        }
        return try Correction(
            frame: R09PlanarFrameQ16(planes: planes),
            appliedSampleCount: appliedSampleCount
        )
    }

    static func correctedPlane(
        _ planeID: R09ResidualPlaneID,
        base: R09UnsignedPlaneQ16,
        residual: R09SignedResidualPlaneQ16,
        request: R09ResidualRequest
    ) throws -> (plane: R09UnsignedPlaneQ16, appliedSampleCount: Int) {
        guard residual.width == base.width,
              residual.height == base.height,
              residual.samplesQ16.count == base.samplesQ16.count else {
            throw R09ResidualApplicationBypassReason.residualGeometryMismatch(planeID)
        }
        let approval = request.ashApprovedMask[planeID]
        let protection = request.protectedMask[planeID]
        let edge = request.limits.edge[planeID]
        let source = request.sourceReference.frame[planeID]
        let temporal = request.temporalReference.frame[planeID]
        var corrected: [Int64] = []
        var appliedSampleCount = 0
        corrected.reserveCapacity(base.samplesQ16.count)
        for index in base.samplesQ16.indices {
            guard !Task.isCancelled else {
                throw R09ResidualApplicationBypassReason.proposalService(.cancelled)
            }
            let value = residual.samplesQ16[index]
            if value != 0 {
                try validateNonzeroResidual(
                    value,
                    plane: planeID,
                    index: index,
                    context: SampleValidationContext(
                        baseQ16: base.samplesQ16[index],
                        approvalQ15: approval.samplesQ15[index],
                        protectionQ15: protection.samplesQ15[index],
                        edgeLimitQ16: edge.maximumMagnitudesQ16[index],
                        sourceQ16: source.samplesQ16[index],
                        temporalQ16: temporal.samplesQ16[index]
                    ),
                    request: request
                )
                appliedSampleCount += 1
            }
            corrected.append(
                min(
                    R09UnsignedPlaneQ16.scale,
                    max(0, base.samplesQ16[index] + value)
                )
            )
        }
        return try (
            R09UnsignedPlaneQ16(
                id: planeID,
                width: base.width,
                height: base.height,
                samplesQ16: corrected
            ),
            appliedSampleCount
        )
    }

    static func validateNonzeroResidual(
        _ residualQ16: Int64,
        plane: R09ResidualPlaneID,
        index: Int,
        context: SampleValidationContext,
        request: R09ResidualRequest
    ) throws {
        guard context.protectionQ15 == 0 else {
            throw R09ResidualApplicationBypassReason.protectedSample(
                plane: plane,
                index: index
            )
        }
        guard context.approvalQ15 > 0 else {
            throw R09ResidualApplicationBypassReason.unauthorizedSample(
                plane: plane,
                index: index
            )
        }
        let magnitude = abs(residualQ16)
        let unattenuatedMaximum = min(
            request.limits.perPlane[plane].maximumMagnitudeQ16,
            request.limits.content.maximumMagnitudeQ16,
            context.edgeLimitQ16
        )
        let maximumMagnitude = unattenuatedMaximum
            * context.approvalQ15 / R09MaskPlaneQ15.maximumSample
        guard magnitude <= maximumMagnitude else {
            throw R09ResidualApplicationBypassReason.residualLimitExceeded(
                plane: plane,
                index: index
            )
        }
        try validateConsistency(
            residualQ16,
            deltaQ16: context.sourceQ16 - context.baseQ16,
            maximumMagnitudeQ16: request.limits.consistency.sourceMaximumMagnitudeQ16,
            rejection: .sourceConsistencyRejected(plane: plane, index: index)
        )
        try validateConsistency(
            residualQ16,
            deltaQ16: context.temporalQ16 - context.baseQ16,
            maximumMagnitudeQ16: request.limits.consistency.temporalMaximumMagnitudeQ16,
            rejection: .temporalConsistencyRejected(plane: plane, index: index)
        )
    }

    static func validateConsistency(
        _ residualQ16: Int64,
        deltaQ16: Int64,
        maximumMagnitudeQ16: Int64,
        rejection: R09ResidualApplicationBypassReason
    ) throws {
        guard abs(deltaQ16) <= maximumMagnitudeQ16,
              abs(residualQ16) <= abs(deltaQ16),
              (residualQ16 > 0 && deltaQ16 > 0)
                || (residualQ16 < 0 && deltaQ16 < 0) else {
            throw rejection
        }
    }
}
