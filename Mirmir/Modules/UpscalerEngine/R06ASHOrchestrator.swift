import Foundation

// swiftlint:disable file_length

enum R06ASHOrchestrationError: Error, Equatable, Sendable {
    case componentOutOfRange(name: String, value: Int64)
    case invalidParameter(String)
    case emptyIdentity(String)
    case duplicateBackendID(String)
    case duplicateRouteID(String)
    case noEligibleFixtureBackend
    case noBackendAfterFatalFailure(String)
    case fatalBackendNotEligible(String)
    case fatalBackendDoesNotMatchCurrent(failed: String, current: String?)
    case currentBackendNotEligible(String)
    case arithmeticOverflow(routeID: String, operation: String)
}

struct R06ASHScoreComponents: Hashable, Sendable {
    static let maximumQ16: Int64 = 65_536

    let qualityConfidenceQ16: Int64
    let messageAlignmentQ16: Int64
    let artifactRiskQ16: Int64
    let transitionCostQ16: Int64
    let resourceCostQ16: Int64
    let postflightPenaltyQ16: Int64

    init(
        qualityConfidenceQ16: Int64,
        messageAlignmentQ16: Int64,
        artifactRiskQ16: Int64,
        transitionCostQ16: Int64,
        resourceCostQ16: Int64,
        postflightPenaltyQ16: Int64
    ) throws {
        let values = [
            ("quality_confidence_q16", qualityConfidenceQ16),
            ("message_alignment_q16", messageAlignmentQ16),
            ("artifact_risk_q16", artifactRiskQ16),
            ("transition_cost_q16", transitionCostQ16),
            ("resource_cost_q16", resourceCostQ16),
            ("postflight_penalty_q16", postflightPenaltyQ16)
        ]
        for (name, value) in values where !(0...Self.maximumQ16).contains(value) {
            throw R06ASHOrchestrationError.componentOutOfRange(
                name: name,
                value: value
            )
        }
        self.qualityConfidenceQ16 = qualityConfidenceQ16
        self.messageAlignmentQ16 = messageAlignmentQ16
        self.artifactRiskQ16 = artifactRiskQ16
        self.transitionCostQ16 = transitionCostQ16
        self.resourceCostQ16 = resourceCostQ16
        self.postflightPenaltyQ16 = postflightPenaltyQ16
    }
}

struct R06ASHScoreWeights: Hashable, Sendable {
    let qualityConfidence: Int64
    let messageAlignment: Int64
    let artifactRiskPenalty: Int64
    let transitionCostPenalty: Int64
    let resourceCostPenalty: Int64
    let postflightPenalty: Int64

    init(
        qualityConfidence: Int64,
        messageAlignment: Int64,
        artifactRiskPenalty: Int64,
        transitionCostPenalty: Int64,
        resourceCostPenalty: Int64,
        postflightPenalty: Int64
    ) throws {
        let values = [
            qualityConfidence,
            messageAlignment,
            artifactRiskPenalty,
            transitionCostPenalty,
            resourceCostPenalty,
            postflightPenalty
        ]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw R06ASHOrchestrationError.invalidParameter("score_weights")
        }
        self.qualityConfidence = qualityConfidence
        self.messageAlignment = messageAlignment
        self.artifactRiskPenalty = artifactRiskPenalty
        self.transitionCostPenalty = transitionCostPenalty
        self.resourceCostPenalty = resourceCostPenalty
        self.postflightPenalty = postflightPenalty
    }
}

struct R06ASHThresholds: Hashable, Sendable {
    let hysteresisMarginQ16: Int64
    let minimumDwellFrames: Int
    let sceneCutConfidenceQ16: Int64

    init(
        hysteresisMarginQ16: Int64,
        minimumDwellFrames: Int,
        sceneCutConfidenceQ16: Int64
    ) throws {
        guard (0...R06ASHScoreComponents.maximumQ16).contains(hysteresisMarginQ16),
              minimumDwellFrames >= 1,
              (0...R06ASHScoreComponents.maximumQ16).contains(sceneCutConfidenceQ16) else {
            throw R06ASHOrchestrationError.invalidParameter("thresholds")
        }
        self.hysteresisMarginQ16 = hysteresisMarginQ16
        self.minimumDwellFrames = minimumDwellFrames
        self.sceneCutConfidenceQ16 = sceneCutConfidenceQ16
    }
}

struct R06ASHParameters: Hashable, Sendable {
    let version: String
    let fixedPointScale: Int64
    let weights: R06ASHScoreWeights
    let thresholds: R06ASHThresholds
    let fatalBackendErrorBypassesHolds: Bool

    private static let frozenWeights = makeFrozenWeights()
    private static let frozenThresholds = makeFrozenThresholds()

    init(
        version: String,
        fixedPointScale: Int64,
        weights: R06ASHScoreWeights,
        thresholds: R06ASHThresholds,
        fatalBackendErrorBypassesHolds: Bool
    ) throws {
        guard version == "r06.parameters.v1",
              fixedPointScale == R06ASHScoreComponents.maximumQ16,
              weights == Self.frozenWeights,
              thresholds == Self.frozenThresholds,
              fatalBackendErrorBypassesHolds else {
            throw R06ASHOrchestrationError.invalidParameter("r06_parameters")
        }
        self.version = version
        self.fixedPointScale = fixedPointScale
        self.weights = weights
        self.thresholds = thresholds
        self.fatalBackendErrorBypassesHolds = fatalBackendErrorBypassesHolds
    }

    static let frozen = makeFrozen()

    private static func makeFrozen() -> R06ASHParameters {
        do {
            return try R06ASHParameters(
                version: "r06.parameters.v1",
                fixedPointScale: 65_536,
                weights: frozenWeights,
                thresholds: frozenThresholds,
                fatalBackendErrorBypassesHolds: true
            )
        } catch {
            preconditionFailure("Frozen R06 parameters must satisfy their contract: \(error)")
        }
    }

    private static func makeFrozenWeights() -> R06ASHScoreWeights {
        do {
            return try R06ASHScoreWeights(
                qualityConfidence: 4,
                messageAlignment: 2,
                artifactRiskPenalty: 3,
                transitionCostPenalty: 2,
                resourceCostPenalty: 1,
                postflightPenalty: 2
            )
        } catch {
            preconditionFailure("Frozen R06 score weights must be valid: \(error)")
        }
    }

    private static func makeFrozenThresholds() -> R06ASHThresholds {
        do {
            return try R06ASHThresholds(
                hysteresisMarginQ16: 8_192,
                minimumDwellFrames: 12,
                sceneCutConfidenceQ16: 49_152
            )
        } catch {
            preconditionFailure("Frozen R06 thresholds must be valid: \(error)")
        }
    }
}

struct R06ASHBackendFixture: Hashable, Sendable {
    let backendID: String
    let routeID: String
    let fixtureEligible: Bool
    let productQualified: Bool
    let wholeFrameOnly: Bool
    let scoreComponents: R06ASHScoreComponents

    init(
        backendID: String,
        routeID: String,
        fixtureEligible: Bool,
        productQualified: Bool,
        wholeFrameOnly: Bool,
        scoreComponents: R06ASHScoreComponents
    ) throws {
        self.backendID = try Self.requireIdentity(backendID, field: "backend_id")
        self.routeID = try Self.requireIdentity(routeID, field: "route_id")
        self.fixtureEligible = fixtureEligible
        self.productQualified = productQualified
        self.wholeFrameOnly = wholeFrameOnly
        self.scoreComponents = scoreComponents
    }

    private static func requireIdentity(_ value: String, field: String) throws -> String {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw R06ASHOrchestrationError.emptyIdentity(field)
        }
        return value
    }
}

enum R06ASHBackendCatalog {
    static let fixtures: [R06ASHBackendFixture] = [
        makeFixture(
            backendID: "fixture.apple.metalfx_spatial",
            routeID: "fixture.route.metalfx_spatial",
            quality: 49_152,
            alignment: 65_536,
            artifact: 8_192,
            transition: 4_096,
            resource: 16_384,
            postflight: 0
        ),
        makeFixture(
            backendID: "fixture.apple.mps_lanczos",
            routeID: "fixture.route.mps_lanczos",
            quality: 49_152,
            alignment: 65_536,
            artifact: 8_192,
            transition: 4_096,
            resource: 16_384,
            postflight: 0
        ),
        makeFixture(
            backendID: "fixture.apple.videotoolbox_low_latency",
            routeID: "fixture.route.videotoolbox_low_latency",
            quality: 45_056,
            alignment: 49_152,
            artifact: 12_288,
            transition: 8_192,
            resource: 8_192,
            postflight: 4_096
        )
    ]

    private static func makeFixture(
        backendID: String,
        routeID: String,
        quality: Int64,
        alignment: Int64,
        artifact: Int64,
        transition: Int64,
        resource: Int64,
        postflight: Int64
    ) -> R06ASHBackendFixture {
        do {
            return try R06ASHBackendFixture(
                backendID: backendID,
                routeID: routeID,
                fixtureEligible: true,
                productQualified: false,
                wholeFrameOnly: true,
                scoreComponents: R06ASHScoreComponents(
                    qualityConfidenceQ16: quality,
                    messageAlignmentQ16: alignment,
                    artifactRiskQ16: artifact,
                    transitionCostQ16: transition,
                    resourceCostQ16: resource,
                    postflightPenaltyQ16: postflight
                )
            )
        } catch {
            preconditionFailure("Frozen R06 backend fixtures must be valid: \(error)")
        }
    }
}

enum R06ASHTransitionReason: String, CaseIterable, Hashable, Sendable {
    case initialSelection = "initial_selection"
    case scoreWinnerSelected = "score_winner_selected"
    case hysteresisHold = "hysteresis_hold"
    case minimumDwellHold = "minimum_dwell_hold"
    case sceneCutReset = "scene_cut_reset"
    case fatalBackendFailover = "fatal_backend_failover"
    case noProductQualifiedPrimaryBackend = "no_product_qualified_primary_backend"
}

enum R06ASHDisposition: String, Hashable, Sendable {
    case selected
    case blocked
}

struct R06ASHCandidateScore: Hashable, Sendable {
    let backendID: String
    let routeID: String
    let components: R06ASHScoreComponents
    let effectivePostflightPenaltyQ16: Int64
    let totalQ16: Int64
}

struct R06ASHWholeFramePlan: Hashable, Sendable {
    let planID: String
    let selectedBackendID: String
    let selectedRouteID: String
    let policyProfileID: R06ASHPolicyProfileID
    let masks: R06ASHMaskSet
}

struct R06ASHDecisionRecord: Hashable, Sendable {
    let candidateScores: [R06ASHCandidateScore]
    let selectedPlan: R06ASHWholeFramePlan
    let reason: R06ASHTransitionReason
    let ablation: R06ASHAblationMode
}

struct R06ASHProductGateResult: Hashable, Sendable {
    let reason: R06ASHTransitionReason
    let eligibleBackendCount: Int
    let selectedRouteID: String?
    let selectedPlanID: String?
    let outputIdentity: String?
    let disposition: R06ASHDisposition

    static let blocked = R06ASHProductGateResult(
        reason: .noProductQualifiedPrimaryBackend,
        eligibleBackendCount: 0,
        selectedRouteID: nil,
        selectedPlanID: nil,
        outputIdentity: nil,
        disposition: .blocked
    )
}

enum R06ASHOrchestrationOutcome: Equatable, Sendable {
    case selected(R06ASHDecisionRecord)
    case blocked(R06ASHProductGateResult)
    case failed(R06ASHOrchestrationError)
}

struct R06ASHOrchestrator: Sendable {
    let parameters: R06ASHParameters

    func decide(
        scope: AppleUpscaleAdmissionScope,
        context: ASHDecisionContext,
        candidates: [R06ASHBackendFixture],
        masks: R06ASHMaskSet,
        ablation: R06ASHAblationMode
    ) -> R06ASHOrchestrationOutcome {
        if scope == .product {
            return .blocked(.blocked)
        }
        let eligible = candidates.filter { candidate in
            candidate.wholeFrameOnly && candidate.fixtureEligible
        }
        guard !eligible.isEmpty else {
            return .failed(.noEligibleFixtureBackend)
        }

        do {
            try validateUniqueIdentities(eligible)
            let candidatesAfterFailure = try removingFatalBackend(
                from: eligible,
                context: context
            )
            let scores = try score(
                candidatesAfterFailure,
                contextPostflightRiskQ16: contextRisk(for: ablation, context: context)
            )
            let selection = try select(
                scores: scores,
                context: context,
                ablation: ablation
            )
            let profile = R06ASHPolicyCatalog.profile(
                for: policyMessage(for: ablation, context: context)
            )
            let plan = R06ASHWholeFramePlan(
                planID: "r06.plan.\(selection.score.routeID).\(profile.id.rawValue)",
                selectedBackendID: selection.score.backendID,
                selectedRouteID: selection.score.routeID,
                policyProfileID: profile.id,
                masks: masks
            )
            return .selected(
                R06ASHDecisionRecord(
                    candidateScores: scores,
                    selectedPlan: plan,
                    reason: selection.reason,
                    ablation: ablation
                )
            )
        } catch let error as R06ASHOrchestrationError {
            return .failed(error)
        } catch {
            preconditionFailure("R06 orchestration throws only typed contract errors: \(error)")
        }
    }

    private func contextRisk(
        for ablation: R06ASHAblationMode,
        context: ASHDecisionContext
    ) -> Int64 {
        switch ablation {
        case .simpleContinuousRouterWithoutASH, .ashPlusContinuousSidecar,
             .ashWithoutHysteresis:
            return context.postflightRiskQ16.rawValue
        case .bestFixedEligibleAppleBackend, .ashStateOnlyRouter,
             .ashWithoutPostflightFeedback:
            return 0
        }
    }

    private func policyMessage(
        for ablation: R06ASHAblationMode,
        context: ASHDecisionContext
    ) -> ASHMessage {
        switch ablation {
        case .bestFixedEligibleAppleBackend, .simpleContinuousRouterWithoutASH:
            return ASHMessage(validatedRawValue: 0)
        case .ashStateOnlyRouter, .ashPlusContinuousSidecar,
             .ashWithoutHysteresis, .ashWithoutPostflightFeedback:
            return context.message
        }
    }

    private func removingFatalBackend(
        from candidates: [R06ASHBackendFixture],
        context: ASHDecisionContext
    ) throws -> [R06ASHBackendFixture] {
        guard let failedID = context.fatalBackendID else { return candidates }
        guard failedID == context.currentBackendID else {
            throw R06ASHOrchestrationError.fatalBackendDoesNotMatchCurrent(
                failed: failedID,
                current: context.currentBackendID
            )
        }
        guard candidates.contains(where: { $0.backendID == failedID }) else {
            throw R06ASHOrchestrationError.fatalBackendNotEligible(failedID)
        }
        let remaining = candidates.filter { $0.backendID != failedID }
        guard !remaining.isEmpty else {
            throw R06ASHOrchestrationError.noBackendAfterFatalFailure(failedID)
        }
        return remaining
    }

    private func validateUniqueIdentities(_ candidates: [R06ASHBackendFixture]) throws {
        var backendIDs: Set<String> = []
        var routeIDs: Set<String> = []
        for candidate in candidates {
            guard backendIDs.insert(candidate.backendID).inserted else {
                throw R06ASHOrchestrationError.duplicateBackendID(candidate.backendID)
            }
            guard routeIDs.insert(candidate.routeID).inserted else {
                throw R06ASHOrchestrationError.duplicateRouteID(candidate.routeID)
            }
        }
    }

    private func score(
        _ candidates: [R06ASHBackendFixture],
        contextPostflightRiskQ16: Int64
    ) throws -> [R06ASHCandidateScore] {
        var records: [R06ASHCandidateScore] = []
        for candidate in candidates {
            let sum = candidate.scoreComponents.postflightPenaltyQ16
                .addingReportingOverflow(contextPostflightRiskQ16)
            guard !sum.overflow else {
                throw R06ASHOrchestrationError.arithmeticOverflow(
                    routeID: candidate.routeID,
                    operation: "effective_postflight_add"
                )
            }
            let effectivePostflight = min(R06ASHScoreComponents.maximumQ16, sum.partialValue)
            let total = try Self.checkedTotal(
                components: candidate.scoreComponents,
                effectivePostflightPenaltyQ16: effectivePostflight,
                weights: parameters.weights,
                routeID: candidate.routeID
            )
            records.append(
                R06ASHCandidateScore(
                    backendID: candidate.backendID,
                    routeID: candidate.routeID,
                    components: candidate.scoreComponents,
                    effectivePostflightPenaltyQ16: effectivePostflight,
                    totalQ16: total
                )
            )
        }
        return records.sorted { lhs, rhs in
            lhs.totalQ16 == rhs.totalQ16
                ? lhs.routeID < rhs.routeID
                : lhs.totalQ16 > rhs.totalQ16
        }
    }

    private func select(
        scores: [R06ASHCandidateScore],
        context: ASHDecisionContext,
        ablation: R06ASHAblationMode
    ) throws -> (score: R06ASHCandidateScore, reason: R06ASHTransitionReason) {
        guard let winner = scores.first else {
            throw R06ASHOrchestrationError.noEligibleFixtureBackend
        }
        if context.fatalBackendID != nil {
            return (winner, .fatalBackendFailover)
        }
        if context.sceneCutConfidenceQ16.rawValue
            >= parameters.thresholds.sceneCutConfidenceQ16 {
            return (winner, .sceneCutReset)
        }
        guard let currentID = context.currentBackendID else {
            return (winner, .initialSelection)
        }
        guard let current = scores.first(where: { $0.backendID == currentID }) else {
            throw R06ASHOrchestrationError.currentBackendNotEligible(currentID)
        }
        guard winner.backendID != current.backendID else {
            return (winner, .scoreWinnerSelected)
        }
        guard ablation.usesASHTransitionHolds else {
            return (winner, .scoreWinnerSelected)
        }
        if context.dwellFrames < parameters.thresholds.minimumDwellFrames {
            return (current, .minimumDwellHold)
        }
        guard ablation != .ashWithoutHysteresis else {
            return (winner, .scoreWinnerSelected)
        }
        let advantage = winner.totalQ16.subtractingReportingOverflow(current.totalQ16)
        guard !advantage.overflow else {
            throw R06ASHOrchestrationError.arithmeticOverflow(
                routeID: winner.routeID,
                operation: "hysteresis_advantage_subtract"
            )
        }
        if advantage.partialValue < parameters.thresholds.hysteresisMarginQ16 {
            return (current, .hysteresisHold)
        }
        return (winner, .scoreWinnerSelected)
    }

    static func checkedTotal(
        components: R06ASHScoreComponents,
        effectivePostflightPenaltyQ16: Int64,
        weights: R06ASHScoreWeights,
        routeID: String
    ) throws -> Int64 {
        let quality = try checkedMultiply(
            components.qualityConfidenceQ16,
            weights.qualityConfidence,
            routeID: routeID,
            operation: "quality_multiply"
        )
        let alignment = try checkedMultiply(
            components.messageAlignmentQ16,
            weights.messageAlignment,
            routeID: routeID,
            operation: "alignment_multiply"
        )
        var total = try checkedAdd(
            quality,
            alignment,
            routeID: routeID,
            operation: "alignment_add"
        )
        let penalties = [
            (components.artifactRiskQ16, weights.artifactRiskPenalty, "artifact"),
            (components.transitionCostQ16, weights.transitionCostPenalty, "transition"),
            (components.resourceCostQ16, weights.resourceCostPenalty, "resource"),
            (effectivePostflightPenaltyQ16, weights.postflightPenalty, "postflight")
        ]
        for (value, weight, name) in penalties {
            let penalty = try checkedMultiply(
                value,
                weight,
                routeID: routeID,
                operation: "\(name)_multiply"
            )
            total = try checkedSubtract(
                total,
                penalty,
                routeID: routeID,
                operation: "\(name)_subtract"
            )
        }
        return total
    }

    private static func checkedMultiply(
        _ lhs: Int64,
        _ rhs: Int64,
        routeID: String,
        operation: String
    ) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw R06ASHOrchestrationError.arithmeticOverflow(
                routeID: routeID,
                operation: operation
            )
        }
        return result.partialValue
    }

    private static func checkedAdd(
        _ lhs: Int64,
        _ rhs: Int64,
        routeID: String,
        operation: String
    ) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw R06ASHOrchestrationError.arithmeticOverflow(
                routeID: routeID,
                operation: operation
            )
        }
        return result.partialValue
    }

    private static func checkedSubtract(
        _ lhs: Int64,
        _ rhs: Int64,
        routeID: String,
        operation: String
    ) throws -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard !result.overflow else {
            throw R06ASHOrchestrationError.arithmeticOverflow(
                routeID: routeID,
                operation: operation
            )
        }
        return result.partialValue
    }
}

private extension R06ASHAblationMode {
    var usesASHTransitionHolds: Bool {
        switch self {
        case .bestFixedEligibleAppleBackend, .simpleContinuousRouterWithoutASH:
            return false
        case .ashStateOnlyRouter, .ashPlusContinuousSidecar,
             .ashWithoutHysteresis, .ashWithoutPostflightFeedback:
            return true
        }
    }
}
