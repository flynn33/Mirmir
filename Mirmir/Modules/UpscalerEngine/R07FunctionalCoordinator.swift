import Foundation

struct R07FunctionalArtifactAnalysisInput: Equatable, Sendable {
    let ringingLowerBoundsQ16: [Int64]
    let ringingUpperBoundsQ16: [Int64]
    let haloReferenceQ16: [Int64]
    let haloSupport: [Bool]
    let beforePreviousLumaQ16: [Int64]
    let falseTextureSourceQ16: [Int64]
    let protectedReferenceQ16: [Int64]
}

struct R07LowResolutionProtectedRegion: Hashable, Sendable {
    let kind: R07ProtectedContentKind
    let samplesQ15: [Int64]
}

struct R07FunctionalArtifactAnalysisResult: Equatable, Sendable {
    let aggregate: R07ArtifactAggregate
    let notApplicableKinds: [R07ArtifactKind]
}

struct R07FunctionalProtectionResult: Equatable, Sendable {
    let composition: R07ProtectedMaskComposition
    let context: R06ASHProtectionContext
}

enum R07ProtectedIntegrityDisposition: String, Equatable, Sendable {
    case measured
    case notApplicableNoProtectedWeight = "not_applicable_no_protected_weight"
}

enum R07FunctionalTemporalDisposition: String, Equatable, Sendable {
    case analyzed
    case notApplicableDiscontinuity = "not_applicable_discontinuity"
}

struct R07FunctionalCoordinatorInput: Sendable {
    let scope: AppleUpscaleAdmissionScope
    let completedDecision: R07CompletedR06Decision
    let targetDecisionOrdinal: UInt64
    let nextBaseContext: ASHDecisionContext
    let temporalInput: R07TemporalAnalysisInput
    let sourceChromaCbQ16: [Int64]
    let sourceChromaCrQ16: [Int64]
    let lowResolutionProtectedRegions: [R07LowResolutionProtectedRegion]
    let artifactAnalysis: R07FunctionalArtifactAnalysisInput
    let candidates: [R06ASHBackendFixture]
    let reportID: String
    let discontinuity: Bool
}

struct R07FunctionalCoordinatorResult: Equatable, Sendable {
    let sourceDecision: R07CompletedR06Decision
    let targetDecisionOrdinal: UInt64
    let analysisPlan: R07A05AnalysisPlan
    let temporalAnalysis: R07TemporalAnalysisResult?
    let temporalDisposition: R07FunctionalTemporalDisposition
    let boundaryReason: R07PostflightBoundaryReason?
    let supportExecutions: [R07FunctionalSupportExecution]
    let denoisedLumaQ16: [Int64]
    let reconstructedChromaCbQ16: [Int64]
    let reconstructedChromaCrQ16: [Int64]
    let protectedComposition: R07ProtectedMaskComposition
    let artifactAggregate: R07ArtifactAggregate
    let notApplicableArtifactKinds: [R07ArtifactKind]
    let protectedIntegrity: R07WeightedMAEResult
    let protectedIntegrityDisposition: R07ProtectedIntegrityDisposition
    let consumedPostflightFindings: R06ASHPostflightFindings
    let nextDecisionContext: ASHDecisionContext
    let nextDecisionRecord: R06ASHDecisionRecord
    let history: R07TemporalHistory
}

enum R07FunctionalProductGateReason: String, Equatable, Sendable {
    case fixtureSimulationNotProductAuthorized =
        "deterministic_fixture_simulation_not_product_authorized"
}

struct R07FunctionalProductGateResult: Equatable, Sendable {
    let reason: R07FunctionalProductGateReason
    let supportExecutionAttempted: Bool

    static let blocked = R07FunctionalProductGateResult(
        reason: .fixtureSimulationNotProductAuthorized,
        supportExecutionAttempted: false
    )
}

enum R07FunctionalCoordinatorOutcome: Equatable, Sendable {
    case blocked(R07FunctionalProductGateResult)
    case completed(R07FunctionalCoordinatorResult)
}

enum R07FunctionalCoordinatorError: Error, Equatable, Sendable {
    case targetDecisionOrdinalOverflow(UInt64)
    case targetDecisionOrdinalMismatch(expected: UInt64, actual: UInt64)
    case decisionOrdinalOutsideTemporalDomain(UInt64)
    case temporalDecisionOrdinalMismatch(expected: Int64, actual: Int64)
    case shotIdentityMismatch(expected: String, actual: String)
    case invalidFullResolutionSampleCount(role: String, actual: Int)
    case invalidLowResolutionSampleCount(role: String, actual: Int)
    case inputSampleOutOfRange(role: String, index: Int, value: Int64)
    case invalidSupportPolicy(R07SupportCapabilityID)
    case invalidSupportPolicyParameters(R07SupportCapabilityID)
    case supportExecutionCapabilityMismatch(
        expected: R07SupportCapabilityID,
        actual: R07SupportCapabilityID
    )
    case supportExecutionIdentityMismatch(R07SupportCapabilityID)
    case supportExecutionPayloadMismatch(R07SupportCapabilityID)
    case supportOutputSampleOutOfRange(
        capability: R07SupportCapabilityID,
        index: Int,
        value: Int64
    )
    case invalidProtectedComposition
    case postflightReportRejected(R07PostflightRejection?)
    case postflightFeedbackMissing
    case r06Blocked(R06ASHProductGateResult)
    case r06Failed(R06ASHOrchestrationError)
    case historyInsertionRejected(R07TemporalHistoryInsertionDisposition)
}

struct R07FunctionalCoordinator: Sendable {
    let supportExecutor: any R07FunctionalSupportExecuting
    let supportPolicy = R07SupportStagePolicy()
    private let r06Orchestrator = R06ASHOrchestrator(parameters: .frozen)

    private(set) var history: R07TemporalHistory
    private(set) var postflightGovernance: R07PostflightGovernance

    init(
        supportExecutor: any R07FunctionalSupportExecuting,
        history: R07TemporalHistory = R07TemporalHistory(),
        postflightGovernance: R07PostflightGovernance = R07PostflightGovernance()
    ) {
        self.supportExecutor = supportExecutor
        self.history = history
        self.postflightGovernance = postflightGovernance
    }

    mutating func process(
        _ input: R07FunctionalCoordinatorInput
    ) throws -> R07FunctionalCoordinatorOutcome {
        guard input.scope != .product else { return .blocked(.blocked) }
        let targetOrdinal = try R07FunctionalCoordinatorValidation.validateInput(input)
        let analysisPlan = try resolveAnalysisPlan(scope: input.scope)
        let temporal = try evaluateTemporal(input)

        var nextHistory = history
        var nextPostflight = postflightGovernance
        if let boundaryReason = temporal.boundaryReason {
            try nextHistory.reset(
                cause: boundaryReason == .sceneCut ? .sceneCut : .discontinuity
            )
            _ = nextPostflight.applyBoundary(boundaryReason)
        }

        let support = try runSupport(input, temporal: temporal)
        let frame = try evaluateFrame(
            input,
            support: support,
            temporal: temporal
        )
        return try finalize(
            input: input,
            targetOrdinal: targetOrdinal,
            analysisPlan: analysisPlan,
            temporal: temporal,
            support: support,
            frame: frame,
            nextHistory: nextHistory,
            nextPostflight: nextPostflight
        )
    }
}

private extension R07FunctionalCoordinator {
    mutating func finalize(
        input: R07FunctionalCoordinatorInput,
        targetOrdinal: UInt64,
        analysisPlan: R07A05AnalysisPlan,
        temporal: R07FunctionalTemporalEvaluation,
        support: R07FunctionalSupportBundle,
        frame: R07FunctionalFrameEvaluation,
        nextHistory initialHistory: R07TemporalHistory,
        nextPostflight initialPostflight: R07PostflightGovernance
    ) throws -> R07FunctionalCoordinatorOutcome {
        var nextHistory = initialHistory
        var nextPostflight = initialPostflight
        let report = try R07PostflightReport(
            reportID: input.reportID,
            shotID: input.completedDecision.shotID,
            decisionOrdinal: input.completedDecision.decisionOrdinal,
            findings: frame.reportFindings
        )
        let application = try nextPostflight.apply(
            scope: input.scope,
            report: report,
            to: input.completedDecision
        )
        guard case .evaluated(let applicationResult) = application,
              applicationResult.accepted else {
            let rejection: R07PostflightRejection? = if case .evaluated(let result) = application {
                result.selectedRejection
            } else {
                nil
            }
            throw R07FunctionalCoordinatorError.postflightReportRejected(rejection)
        }
        guard let consumed = try nextPostflight.consumeFeedback(
            forShotID: input.completedDecision.shotID,
            decisionOrdinal: targetOrdinal
        ) else {
            throw R07FunctionalCoordinatorError.postflightFeedbackMissing
        }

        let combinedRisk = max(
            frame.artifactAnalysis.aggregate.maximumNormalizedRiskQ16,
            frame.protectedIntegrity.weightedMAEQ16
        )
        let nextContext = try R07FunctionalCoordinatorAnalysis.makeNextContext(
            base: input.nextBaseContext,
            completedDecision: input.completedDecision,
            temporalSignals: temporal.signals,
            boundary: temporal.boundaryReason != nil,
            protection: support.protection.context,
            artifactRiskQ16: max(combinedRisk, consumed.riskQ16),
            postflightFindings: consumed
        )
        let nextRecord = try selectedRecord(
            input: input,
            context: nextContext,
            masks: support.protection.composition.masks
        )
        let insertion = nextHistory.insert(
            R07TemporalHistoryEntry(
                frameOrdinal: Int64(targetOrdinal),
                backendID: nextRecord.selectedPlan.selectedBackendID,
                preprocessStrengthQ16: nextContext.preprocessStrengthQ16,
                postprocessStrengthQ16: nextContext.postprocessStrengthQ16,
                artifactRiskQ16: nextContext.artifactRiskQ16
            )
        )
        guard insertion == .inserted else {
            throw R07FunctionalCoordinatorError.historyInsertionRejected(insertion)
        }

        history = nextHistory
        postflightGovernance = nextPostflight
        return .completed(
            R07FunctionalCoordinatorResult(
                sourceDecision: input.completedDecision,
                targetDecisionOrdinal: targetOrdinal,
                analysisPlan: analysisPlan,
                temporalAnalysis: temporal.analysis,
                temporalDisposition: temporal.disposition,
                boundaryReason: temporal.boundaryReason,
                supportExecutions: support.executions,
                denoisedLumaQ16: support.denoisedLumaQ16,
                reconstructedChromaCbQ16: support.reconstructedChromaCbQ16,
                reconstructedChromaCrQ16: support.reconstructedChromaCrQ16,
                protectedComposition: support.protection.composition,
                artifactAggregate: frame.artifactAnalysis.aggregate,
                notApplicableArtifactKinds: frame.artifactAnalysis.notApplicableKinds,
                protectedIntegrity: frame.protectedIntegrity,
                protectedIntegrityDisposition: frame.protectedIntegrityDisposition,
                consumedPostflightFindings: consumed,
                nextDecisionContext: nextContext,
                nextDecisionRecord: nextRecord,
                history: nextHistory
            )
        )
    }

    func selectedRecord(
        input: R07FunctionalCoordinatorInput,
        context: ASHDecisionContext,
        masks: R06ASHMaskSet
    ) throws -> R06ASHDecisionRecord {
        switch r06Orchestrator.decide(
            scope: input.scope,
            context: context,
            candidates: input.candidates,
            masks: masks,
            ablation: .ashPlusContinuousSidecar
        ) {
        case .selected(let record): return record
        case .blocked(let gate): throw R07FunctionalCoordinatorError.r06Blocked(gate)
        case .failed(let error): throw R07FunctionalCoordinatorError.r06Failed(error)
        }
    }
}
