import Foundation
@testable import Mirmir

struct R07FunctionalInputOptions {
    var scope: AppleUpscaleAdmissionScope = .fixtureOnly
    var completedDecision: R07CompletedR06Decision?
    var targetDecisionOrdinal: UInt64?
    var nextBaseContext: ASHDecisionContext?
    var currentLumaQ16: [Int64]?
    var previousLumaQ16: [Int64]?
    var alignedPreviousLumaQ16: [Int64]?
    var occlusionMask: [Int64]?
    var sourceChromaCbQ16: [Int64]?
    var sourceChromaCrQ16: [Int64]?
    var protectedRegions: [R07LowResolutionProtectedRegion] = []
    var artifactAnalysis: R07FunctionalArtifactAnalysisInput?
    var candidates: [R06ASHBackendFixture]?
    var reportID = "r07.report.100"
    var discontinuity = false
}

struct R07FunctionalContextOptions {
    var shotID = "r07.shot"
    var currentBackendID: String? = "backend.current"
    var previousBackendID: String? = "backend.previous"
    var dwellFrames = 20
    var fatalBackendID: String?
}

enum R07FunctionalTestError: Error {
    case injectedFailure
    case unexpectedCoordinatorOutcome
}

enum R07FunctionalTestFixtures {
    static let fullCount = R07FunctionalSupportGeometry.fullSampleCount
    static let lowCount = R07FunctionalSupportGeometry.lowSampleCount
    static let currentBackendID = "backend.current"
    static let alternateBackendID = "backend.alternate"

    static func constant(_ value: Int64) -> [Int64] {
        Array(repeating: value, count: fullCount)
    }

    static func lowConstant(_ value: Int64) -> [Int64] {
        Array(repeating: value, count: lowCount)
    }

    static func edgePlane(
        edgeColumn: Int = 32,
        low: Int64 = 20_000,
        high: Int64 = 40_000
    ) -> [Int64] {
        (0..<R07FunctionalSupportGeometry.fullHeight).flatMap { _ in
            (0..<R07FunctionalSupportGeometry.fullWidth).map { column in
                column < edgeColumn ? low : high
            }
        }
    }
}

extension R07FunctionalTestFixtures {
    static func input(
        _ options: R07FunctionalInputOptions = R07FunctionalInputOptions()
    ) throws -> R07FunctionalCoordinatorInput {
        let completed = try options.completedDecision ?? completedDecision()
        let current = options.currentLumaQ16 ?? edgePlane()
        let previous = options.previousLumaQ16 ?? current
        let aligned = options.alignedPreviousLumaQ16 ?? current
        let occlusion = options.occlusionMask ?? constant(0)
        let context = try options.nextBaseContext ?? makeContext()
        let artifact = options.artifactAnalysis ?? artifactInput(
            current: current,
            previous: previous
        )
        return R07FunctionalCoordinatorInput(
            scope: options.scope,
            completedDecision: completed,
            targetDecisionOrdinal:
                options.targetDecisionOrdinal ?? completed.decisionOrdinal + 1,
            nextBaseContext: context,
            temporalInput: R07TemporalAnalysisInput(
                previousFrameOrdinal: Int64(completed.decisionOrdinal) - 1,
                currentFrameOrdinal: Int64(completed.decisionOrdinal),
                currentLumaQ16: current,
                previousLumaQ16: previous,
                alignedPreviousLumaQ16: aligned,
                occlusionMask: occlusion
            ),
            sourceChromaCbQ16:
                options.sourceChromaCbQ16
                    ?? edgePlane(edgeColumn: 29, low: 12_000, high: 36_000),
            sourceChromaCrQ16:
                options.sourceChromaCrQ16
                    ?? edgePlane(edgeColumn: 35, low: 18_000, high: 52_000),
            lowResolutionProtectedRegions: options.protectedRegions,
            artifactAnalysis: artifact,
            candidates: try options.candidates ?? makeCandidates(),
            reportID: options.reportID,
            discontinuity: options.discontinuity
        )
    }

    static func artifactInput(
        current: [Int64],
        previous: [Int64],
        ringingUpper: Int64 = R06ASHQ16.scale,
        haloSupport: Bool = true,
        protectedReference: [Int64]? = nil
    ) -> R07FunctionalArtifactAnalysisInput {
        R07FunctionalArtifactAnalysisInput(
            ringingLowerBoundsQ16: constant(0),
            ringingUpperBoundsQ16: constant(ringingUpper),
            haloReferenceQ16: current,
            haloSupport: Array(repeating: haloSupport, count: fullCount),
            beforePreviousLumaQ16: previous,
            falseTextureSourceQ16: current,
            protectedReferenceQ16: protectedReference ?? current
        )
    }

    static func protectedRegion(
        kind: R07ProtectedContentKind,
        fillQ15: Int64
    ) -> R07LowResolutionProtectedRegion {
        R07LowResolutionProtectedRegion(
            kind: kind,
            samplesQ15: lowConstant(fillQ15)
        )
    }
}

extension R07FunctionalTestFixtures {
    static func makeContext(
        _ options: R07FunctionalContextOptions = R07FunctionalContextOptions()
    ) throws -> ASHDecisionContext {
        let state = try ASHState(rawValue: 0)
        let fallback = try options.fatalBackendID.map {
            try R06ASHFallbackReason(code: .backendFailed, failedBackendID: $0)
        }
        return ASHDecisionContext(
            identity: try R06ASHIdentityContext(
                frameID: "r07.frame.101",
                shotID: options.shotID,
                routeID: "r07.route.pending",
                scaleNumerator: 2,
                scaleDenominator: 1,
                planeLayout: .nv12,
                chromaSiting: .left
            ),
            state: try R06ASHStateContext(
                continuousFeatureValuesQ16: Array(repeating: .zero, count: 8),
                currentState: state,
                previousState: state,
                stateTransition: R06ASHStateTransition(
                    previousState: state,
                    currentState: state
                ),
                dwellFrames: options.dwellFrames
            ),
            signals: R06ASHSignalContext(
                sceneCutConfidenceQ16: .zero,
                motionConfidenceQ16: .zero,
                occlusionConfidenceQ16: .zero,
                noiseEstimateQ16: .zero,
                blurEstimateQ16: .zero,
                compressionEstimateQ16: .zero,
                aliasingEstimateQ16: .zero
            ),
            protection: R06ASHProtectionContext(
                faceOccupancyQ15: .zero,
                textOccupancyQ15: .zero,
                lineArtOccupancyQ15: .zero,
                animationOccupancyQ15: .zero,
                uiOccupancyQ15: .zero
            ),
            resources: R06ASHResourceContext(
                backendAvailability: .available,
                modelReadiness: .notRequired,
                backendQualityConfidenceQ16: .one,
                memoryPressureQ16: .zero,
                thermalPressureQ16: .zero,
                throughputPressureQ16: .zero
            ),
            backendHistory: try R06ASHBackendHistory(
                currentBackendID: options.currentBackendID,
                previousBackendID: options.previousBackendID
            ),
            effects: R06ASHEffectContext(
                preprocessStrengthQ16: .zero,
                postprocessStrengthQ16: .zero,
                artifactRiskQ16: .zero
            ),
            outcome: R06ASHOutcomeContext(
                postflightFindings: try R06ASHPostflightFindings(
                    riskQ16: .zero,
                    findings: []
                ),
                fallbackReason: fallback,
                retryEligibility: .eligible
            )
        )
    }

    static func completedDecision(
        shotID: String = "r07.shot",
        ordinal: UInt64 = 100,
        backendID: String = currentBackendID
    ) throws -> R07CompletedR06Decision {
        try R07CompletedR06Decision(
            shotID: shotID,
            decisionOrdinal: ordinal,
            record: R06ASHDecisionRecord(
                candidateScores: [],
                selectedPlan: R06ASHWholeFramePlan(
                    planID: "r06.plan.completed",
                    selectedBackendID: backendID,
                    selectedRouteID: "route.completed",
                    policyProfileID: .message00,
                    masks: try zeroMasks(width: 1, height: 1)
                ),
                reason: .initialSelection,
                ablation: .ashPlusContinuousSidecar
            ),
            decisionCompleted: true
        )
    }

    static func makeCandidates() throws -> [R06ASHBackendFixture] {
        [
            try candidate(
                backendID: currentBackendID,
                routeID: "route.current",
                qualityQ16: 40_000
            ),
            try candidate(
                backendID: alternateBackendID,
                routeID: "route.alternate",
                qualityQ16: 50_000
            )
        ]
    }

    static func history(frameOrdinal: Int64 = 99) -> R07TemporalHistory {
        var history = R07TemporalHistory()
        _ = history.insert(
            R07TemporalHistoryEntry(
                frameOrdinal: frameOrdinal,
                backendID: "backend.legacy",
                preprocessStrengthQ16: .zero,
                postprocessStrengthQ16: .zero,
                artifactRiskQ16: .zero
            )
        )
        return history
    }

    static func governance(
        completed: R07CompletedR06Decision,
        riskQ16: Int64
    ) throws -> R07PostflightGovernance {
        var governance = R07PostflightGovernance()
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: R07PostflightReport(
                reportID: "r07.report.preseed",
                shotID: completed.shotID,
                decisionOrdinal: completed.decisionOrdinal,
                findings: try R06ASHPostflightFindings(
                    riskQ16: R06ASHQ16(riskQ16),
                    findings: [try R06ASHPostflightFinding(id: "preseed")]
                )
            ),
            to: completed
        )
        return governance
    }
}

extension R07FunctionalTestFixtures {
    static func result(
        _ outcome: R07FunctionalCoordinatorOutcome
    ) throws -> R07FunctionalCoordinatorResult {
        guard case .completed(let result) = outcome else {
            throw R07FunctionalTestError.unexpectedCoordinatorOutcome
        }
        return result
    }

    static func identity(
        _ capability: R07SupportCapabilityID
    ) -> R07FunctionalSupportIdentity {
        switch capability {
        case .temporalNoiseFilter:
            R07FunctionalSupportIdentity(
                simulationIdentity: R07FunctionalSimulationIdentity.a04,
                referencedNativeIdentity: .a04Configuration(
                    R07SupportStagePolicy.a04ConfigurationIdentity
                )
            )
        case .mpsGuidedFilter:
            R07FunctionalSupportIdentity(
                simulationIdentity: R07FunctionalSimulationIdentity.a13,
                referencedNativeIdentity: .inheritedProcessing(
                    R07SupportStagePolicy.a13Descriptor.processingIdentity
                )
            )
        case .coreImageEdgePreserve:
            R07FunctionalSupportIdentity(
                simulationIdentity: R07FunctionalSimulationIdentity.a15,
                referencedNativeIdentity: .inheritedProcessing(
                    R07SupportStagePolicy.a15Descriptor.processingIdentity
                )
            )
        case .temporalAnalyzer:
            preconditionFailure("A05 has no functional support execution identity")
        }
    }

    static func request(
        _ capability: R07SupportCapabilityID,
        identity: R07FunctionalSupportIdentity? = nil
    ) -> R07FunctionalSupportRequest {
        let resolvedIdentity = identity ?? self.identity(capability)
        switch capability {
        case .temporalNoiseFilter:
            return R07FunctionalSupportRequest.a04(
                identity: resolvedIdentity,
                currentLumaQ16: constant(40_000),
                strengthQ16: R07SupportStagePolicy.a04StrengthQ16,
                temporalState: R07FunctionalA04TemporalState.continuous(
                    alignedHistoryLumaQ16: constant(20_000),
                    occlusionMask: constant(0)
                )
            )
        case .mpsGuidedFilter:
            return R07FunctionalSupportRequest.a13(
                identity: resolvedIdentity,
                sourceChromaCbQ16: constant(20_000),
                sourceChromaCrQ16: constant(30_000),
                sameFrameLumaQ16: constant(30_000),
                protectionMaskQ15: constant(0)
            )
        case .coreImageEdgePreserve:
            return R07FunctionalSupportRequest.a15(
                identity: resolvedIdentity,
                lowResolutionMaskQ15: lowConstant(0),
                sameFrameLumaQ16: constant(30_000)
            )
        case .temporalAnalyzer:
            preconditionFailure("A05 is analysis-only")
        }
    }
}

private extension R07FunctionalTestFixtures {
    static func candidate(
        backendID: String,
        routeID: String,
        qualityQ16: Int64
    ) throws -> R06ASHBackendFixture {
        try R06ASHBackendFixture(
            backendID: backendID,
            routeID: routeID,
            fixtureEligible: true,
            productQualified: false,
            wholeFrameOnly: true,
            scoreComponents: R06ASHScoreComponents(
                qualityConfidenceQ16: qualityQ16,
                messageAlignmentQ16: 0,
                artifactRiskQ16: 0,
                transitionCostQ16: 0,
                resourceCostQ16: 0,
                postflightPenaltyQ16: 0
            )
        )
    }

    static func zeroMasks(width: Int, height: Int) throws -> R06ASHMaskSet {
        let samples = [UInt16](repeating: 0, count: width * height)
        return try R06ASHMaskSet(
            lumaProtection: R06ASHMask(
                id: .lumaProtection,
                width: width,
                height: height,
                samplesQ15: samples
            ),
            chromaProtection: R06ASHMask(
                id: .chromaProtection,
                width: width,
                height: height,
                samplesQ15: samples
            ),
            postprocessSuppression: R06ASHMask(
                id: .postprocessSuppression,
                width: width,
                height: height,
                samplesQ15: samples
            )
        )
    }
}

enum R07SupportExecutionMutation: Sendable {
    case none
    case identity(R07SupportCapabilityID)
    case payload(R07SupportCapabilityID)
    case failure(R07SupportCapabilityID)
}

final class R07RecordingSupportExecutor: R07FunctionalSupportExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let simulator = R07DeterministicFixtureSupportExecutor()
    private let mutation: R07SupportExecutionMutation
    private var recordedRequests: [R07FunctionalSupportRequest] = []

    init(mutation: R07SupportExecutionMutation = .none) {
        self.mutation = mutation
    }

    var requests: [R07FunctionalSupportRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func execute(
        _ request: R07FunctionalSupportRequest
    ) throws -> R07FunctionalSupportExecution {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
        if case .failure(let capability) = mutation,
           capability == request.capabilityID {
            throw R07FunctionalTestError.injectedFailure
        }
        let execution = try simulator.execute(request)
        if case .identity(let capability) = mutation,
           capability == request.capabilityID {
            return R07FunctionalSupportExecution(
                capabilityID: execution.capabilityID,
                identity: R07FunctionalSupportIdentity(
                    simulationIdentity: execution.identity.simulationIdentity + ".forged",
                    referencedNativeIdentity: execution.identity.referencedNativeIdentity
                ),
                payload: execution.payload
            )
        }
        if case .payload(let capability) = mutation,
           capability == request.capabilityID {
            return R07FunctionalSupportExecution(
                capabilityID: execution.capabilityID,
                identity: execution.identity,
                payload: wrongPayload(for: capability)
            )
        }
        return execution
    }

    private func wrongPayload(
        for capability: R07SupportCapabilityID
    ) -> R07FunctionalSupportPayload {
        switch capability {
        case .temporalNoiseFilter:
            .upsampledProtectionMaskQ15([])
        case .mpsGuidedFilter:
            .denoisedLumaQ16([])
        case .coreImageEdgePreserve:
            .reconstructedChromaQ16(cb: [], cr: [])
        case .temporalAnalyzer:
            preconditionFailure("A05 has no support payload")
        }
    }
}
