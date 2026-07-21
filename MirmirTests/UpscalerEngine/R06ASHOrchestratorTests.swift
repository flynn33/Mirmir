import XCTest
@testable import Mirmir

// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
final class R06ASHOrchestratorTests: XCTestCase {
    func testFrozenCatalogMatchesExactDescriptorsComponentsAndScores() throws {
        let fixtures = R06ASHBackendCatalog.fixtures
        XCTAssertEqual(
            fixtures.map(\.backendID),
            [
                "fixture.apple.metalfx_spatial",
                "fixture.apple.mps_lanczos",
                "fixture.apple.videotoolbox_low_latency"
            ]
        )
        XCTAssertEqual(
            fixtures.map(\.routeID),
            [
                "fixture.route.metalfx_spatial",
                "fixture.route.mps_lanczos",
                "fixture.route.videotoolbox_low_latency"
            ]
        )
        XCTAssertTrue(fixtures.allSatisfy(\.fixtureEligible))
        XCTAssertTrue(fixtures.allSatisfy { !$0.productQualified })
        XCTAssertTrue(fixtures.allSatisfy(\.wholeFrameOnly))

        let record = try selectedRecord(
            context: makeContext(),
            candidates: fixtures
        )
        XCTAssertEqual(
            record.candidateScores.map(\.routeID),
            [
                "fixture.route.metalfx_spatial",
                "fixture.route.mps_lanczos",
                "fixture.route.videotoolbox_low_latency"
            ]
        )
        XCTAssertEqual(record.candidateScores.map(\.totalQ16), [278_528, 278_528, 208_896])
        XCTAssertEqual(record.reason, .initialSelection)
        XCTAssertEqual(
            record.selectedPlan.selectedRouteID,
            "fixture.route.metalfx_spatial"
        )
        XCTAssertEqual(record.selectedPlan.policyProfileID, .message00)
    }

    func testProductGateRunsBeforeScoringAndPlanConstructionForEveryAblation() throws {
        let orchestrator = R06ASHOrchestrator(parameters: .frozen)
        let frozen = try XCTUnwrap(R06ASHBackendCatalog.fixtures.first)
        let syntheticProductCandidate = try R06ASHBackendFixture(
            backendID: "synthetic.unbound.product",
            routeID: "synthetic.unbound.product.route",
            fixtureEligible: true,
            productQualified: true,
            wholeFrameOnly: true,
            scoreComponents: frozen.scoreComponents
        )

        for ablation in R06ASHAblationMode.allCases {
            let outcome = orchestrator.decide(
                scope: .product,
                context: try makeContext(),
                candidates: [syntheticProductCandidate, syntheticProductCandidate],
                masks: try makeMasks(),
                ablation: ablation
            )
            XCTAssertEqual(outcome, .blocked(.blocked), ablation.rawValue)
        }
    }

    func testEveryCandidatePermutationProducesIdenticalOrderedRecordAndSelection() throws {
        let fixtures = R06ASHBackendCatalog.fixtures
        let permutations = [
            [fixtures[0], fixtures[1], fixtures[2]],
            [fixtures[0], fixtures[2], fixtures[1]],
            [fixtures[1], fixtures[0], fixtures[2]],
            [fixtures[1], fixtures[2], fixtures[0]],
            [fixtures[2], fixtures[0], fixtures[1]],
            [fixtures[2], fixtures[1], fixtures[0]]
        ]
        let baseline = try selectedRecord(
            context: makeContext(),
            candidates: permutations[0]
        )
        for permutation in permutations.dropFirst() {
            XCTAssertEqual(
                try selectedRecord(context: makeContext(), candidates: permutation),
                baseline
            )
        }
    }

    func testFrozenTransitionFixturesProduceEveryTypedSelectionReason() throws {
        let tied = Array(R06ASHBackendCatalog.fixtures.prefix(2))
        let initial = try selectedRecord(context: makeContext(), candidates: tied)
        XCTAssertEqual(initial.reason, .initialSelection)
        XCTAssertEqual(initial.selectedPlan.selectedBackendID, "fixture.apple.metalfx_spatial")

        let steady = try selectedRecord(
            context: makeContext(
                dwellFrames: 20,
                currentBackendID: "fixture.apple.mps_lanczos"
            ),
            candidates: tied
        )
        XCTAssertEqual(steady.reason, .hysteresisHold)
        XCTAssertEqual(steady.selectedPlan.selectedBackendID, "fixture.apple.mps_lanczos")

        let minimumDwell = try selectedRecord(
            context: makeContext(
                currentStateRaw: 480,
                dwellFrames: 4,
                currentBackendID: "fixture.apple.mps_lanczos"
            ),
            candidates: tied
        )
        XCTAssertEqual(minimumDwell.reason, .minimumDwellHold)
        XCTAssertEqual(minimumDwell.selectedPlan.selectedBackendID, "fixture.apple.mps_lanczos")
        XCTAssertEqual(minimumDwell.selectedPlan.policyProfileID, .message08)

        let sceneCut = try selectedRecord(
            context: makeContext(
                currentStateRaw: 480,
                dwellFrames: 4,
                sceneCutQ16: 49_152,
                currentBackendID: "fixture.apple.mps_lanczos"
            ),
            candidates: tied
        )
        XCTAssertEqual(sceneCut.reason, .sceneCutReset)
        XCTAssertEqual(sceneCut.selectedPlan.selectedBackendID, "fixture.apple.metalfx_spatial")

        let fatal = try selectedRecord(
            context: makeContext(
                dwellFrames: 4,
                currentBackendID: "fixture.apple.mps_lanczos",
                fatalBackendID: "fixture.apple.mps_lanczos"
            ),
            candidates: tied
        )
        XCTAssertEqual(fatal.reason, .fatalBackendFailover)
        XCTAssertEqual(fatal.selectedPlan.selectedBackendID, "fixture.apple.metalfx_spatial")

        let scoreWinner = try selectedRecord(
            context: makeContext(
                dwellFrames: 20,
                currentBackendID: "fixture.apple.videotoolbox_low_latency"
            ),
            candidates: R06ASHBackendCatalog.fixtures
        )
        XCTAssertEqual(scoreWinner.reason, .scoreWinnerSelected)
        XCTAssertEqual(
            scoreWinner.selectedPlan.selectedBackendID,
            "fixture.apple.metalfx_spatial"
        )
    }

    func testHysteresisSwitchesAtExactMarginAndHoldsOneStepBelow() throws {
        let current = try makeCandidate(
            backendID: "fixture.apple.current",
            routeID: "fixture.route.current",
            qualityQ16: 10_000
        )
        let exact = try makeCandidate(
            backendID: "fixture.apple.exact",
            routeID: "fixture.route.exact",
            qualityQ16: 12_048
        )
        let below = try makeCandidate(
            backendID: "fixture.apple.below",
            routeID: "fixture.route.below",
            qualityQ16: 12_047
        )
        let context = try makeContext(
            dwellFrames: 12,
            currentBackendID: current.backendID
        )

        let exactRecord = try selectedRecord(
            context: context,
            candidates: [current, exact]
        )
        XCTAssertEqual(exactRecord.reason, .scoreWinnerSelected)
        XCTAssertEqual(exactRecord.selectedPlan.selectedBackendID, exact.backendID)

        let belowRecord = try selectedRecord(
            context: context,
            candidates: [current, below]
        )
        XCTAssertEqual(belowRecord.reason, .hysteresisHold)
        XCTAssertEqual(belowRecord.selectedPlan.selectedBackendID, current.backendID)
    }

    func testWithoutHysteresisStillHonorsMinimumDwell() throws {
        let tied = Array(R06ASHBackendCatalog.fixtures.prefix(2))
        let shortDwell = try selectedRecord(
            context: makeContext(
                dwellFrames: 4,
                currentBackendID: "fixture.apple.mps_lanczos"
            ),
            candidates: tied,
            ablation: .ashWithoutHysteresis
        )
        XCTAssertEqual(shortDwell.reason, .minimumDwellHold)
        XCTAssertEqual(shortDwell.selectedPlan.selectedBackendID, "fixture.apple.mps_lanczos")

        let completedDwell = try selectedRecord(
            context: makeContext(
                dwellFrames: 12,
                currentBackendID: "fixture.apple.mps_lanczos"
            ),
            candidates: tied,
            ablation: .ashWithoutHysteresis
        )
        XCTAssertEqual(completedDwell.reason, .scoreWinnerSelected)
        XCTAssertEqual(
            completedDwell.selectedPlan.selectedBackendID,
            "fixture.apple.metalfx_spatial"
        )
    }

    func testPostflightAblationsZeroOnlyContextRiskAndRetainCandidateComponent() throws {
        let candidate = try XCTUnwrap(R06ASHBackendCatalog.fixtures.last)
        let context = try makeContext(postflightRiskQ16: 32_768)
        let withFeedback = try selectedRecord(
            context: context,
            candidates: [candidate],
            ablation: .ashPlusContinuousSidecar
        ).candidateScores[0]
        let withoutFeedback = try selectedRecord(
            context: context,
            candidates: [candidate],
            ablation: .ashWithoutPostflightFeedback
        ).candidateScores[0]
        let stateOnly = try selectedRecord(
            context: context,
            candidates: [candidate],
            ablation: .ashStateOnlyRouter
        ).candidateScores[0]

        XCTAssertEqual(withFeedback.components.postflightPenaltyQ16, 4_096)
        XCTAssertEqual(withFeedback.effectivePostflightPenaltyQ16, 36_864)
        XCTAssertEqual(withoutFeedback.components.postflightPenaltyQ16, 4_096)
        XCTAssertEqual(withoutFeedback.effectivePostflightPenaltyQ16, 4_096)
        XCTAssertEqual(stateOnly.effectivePostflightPenaltyQ16, 4_096)
        XCTAssertEqual(withoutFeedback.totalQ16 - withFeedback.totalQ16, 65_536)
    }

    func testAblationsSeparateASHMessageSidecarAndTransitionCausality() throws {
        let tied = Array(R06ASHBackendCatalog.fixtures.prefix(2))
        let context = try makeContext(
            currentStateRaw: 480,
            dwellFrames: 20,
            currentBackendID: "fixture.apple.mps_lanczos",
            postflightRiskQ16: 32_768
        )

        let fixed = try selectedRecord(
            context: context,
            candidates: tied,
            ablation: .bestFixedEligibleAppleBackend
        )
        let continuous = try selectedRecord(
            context: context,
            candidates: tied,
            ablation: .simpleContinuousRouterWithoutASH
        )
        let stateOnly = try selectedRecord(
            context: context,
            candidates: tied,
            ablation: .ashStateOnlyRouter
        )
        let combined = try selectedRecord(
            context: context,
            candidates: tied,
            ablation: .ashPlusContinuousSidecar
        )

        XCTAssertEqual(fixed.ablation, .bestFixedEligibleAppleBackend)
        XCTAssertEqual(fixed.selectedPlan.policyProfileID, .message00)
        XCTAssertEqual(fixed.reason, .scoreWinnerSelected)
        XCTAssertEqual(continuous.ablation, .simpleContinuousRouterWithoutASH)
        XCTAssertEqual(continuous.selectedPlan.policyProfileID, .message00)
        XCTAssertEqual(continuous.candidateScores[0].effectivePostflightPenaltyQ16, 32_768)
        XCTAssertEqual(stateOnly.ablation, .ashStateOnlyRouter)
        XCTAssertEqual(stateOnly.selectedPlan.policyProfileID, .message08)
        XCTAssertEqual(stateOnly.candidateScores[0].effectivePostflightPenaltyQ16, 0)
        XCTAssertEqual(stateOnly.reason, .hysteresisHold)
        XCTAssertEqual(combined.ablation, .ashPlusContinuousSidecar)
        XCTAssertEqual(combined.selectedPlan.policyProfileID, .message08)
        XCTAssertEqual(combined.candidateScores[0].effectivePostflightPenaltyQ16, 32_768)
        XCTAssertEqual(combined.reason, .hysteresisHold)
    }

    func testConstructorParametersRejectAnyDriftFromFrozenCatalog() throws {
        let driftedWeights = try R06ASHScoreWeights(
            qualityConfidence: 5,
            messageAlignment: 2,
            artifactRiskPenalty: 3,
            transitionCostPenalty: 2,
            resourceCostPenalty: 1,
            postflightPenalty: 2
        )
        XCTAssertThrowsError(
            try R06ASHParameters(
                version: "r06.parameters.v1",
                fixedPointScale: 65_536,
                weights: driftedWeights,
                thresholds: R06ASHParameters.frozen.thresholds,
                fatalBackendErrorBypassesHolds: true
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHOrchestrationError,
                .invalidParameter("r06_parameters")
            )
        }
        XCTAssertThrowsError(
            try R06ASHThresholds(
                hysteresisMarginQ16: 8_192,
                minimumDwellFrames: 0,
                sceneCutConfidenceQ16: 49_152
            )
        )
    }

    func testFixedPointComponentsRejectOutOfRangeAndScoringFailsClosedOnOverflow() throws {
        XCTAssertThrowsError(
            try R06ASHScoreComponents(
                qualityConfidenceQ16: 65_537,
                messageAlignmentQ16: 0,
                artifactRiskQ16: 0,
                transitionCostQ16: 0,
                resourceCostQ16: 0,
                postflightPenaltyQ16: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHOrchestrationError,
                .componentOutOfRange(name: "quality_confidence_q16", value: 65_537)
            )
        }

        let components = try R06ASHScoreComponents(
            qualityConfidenceQ16: 65_536,
            messageAlignmentQ16: 0,
            artifactRiskQ16: 0,
            transitionCostQ16: 0,
            resourceCostQ16: 0,
            postflightPenaltyQ16: 0
        )
        let weights = try R06ASHScoreWeights(
            qualityConfidence: .max,
            messageAlignment: 0,
            artifactRiskPenalty: 0,
            transitionCostPenalty: 0,
            resourceCostPenalty: 0,
            postflightPenalty: 0
        )
        XCTAssertThrowsError(
            try R06ASHOrchestrator.checkedTotal(
                components: components,
                effectivePostflightPenaltyQ16: 0,
                weights: weights,
                routeID: "fixture.route.overflow"
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHOrchestrationError,
                .arithmeticOverflow(
                    routeID: "fixture.route.overflow",
                    operation: "quality_multiply"
                )
            )
        }
    }

    func testTypedFailuresRejectDuplicateRoutesFatalMismatchAndEmptyFixtureSet() throws {
        let candidate = try XCTUnwrap(R06ASHBackendCatalog.fixtures.first)
        let context = try makeContext()
        XCTAssertEqual(
            decide(context: context, candidates: [candidate, candidate]),
            .failed(.duplicateBackendID(candidate.backendID))
        )
        XCTAssertEqual(
            decide(context: context, candidates: []),
            .failed(.noEligibleFixtureBackend)
        )

        let mismatch = try makeContext(
            currentBackendID: "fixture.apple.current",
            fatalBackendID: "fixture.apple.failed"
        )
        XCTAssertEqual(
            decide(context: mismatch, candidates: [candidate]),
            .failed(
                .fatalBackendDoesNotMatchCurrent(
                    failed: "fixture.apple.failed",
                    current: "fixture.apple.current"
                )
            )
        )

        let missingFatal = try makeContext(
            currentBackendID: "fixture.apple.absent",
            fatalBackendID: "fixture.apple.absent"
        )
        XCTAssertEqual(
            decide(context: missingFatal, candidates: [candidate]),
            .failed(.fatalBackendNotEligible("fixture.apple.absent"))
        )

        let missingCurrent = try makeContext(currentBackendID: "fixture.apple.absent")
        XCTAssertEqual(
            decide(context: missingCurrent, candidates: [candidate]),
            .failed(.currentBackendNotEligible("fixture.apple.absent"))
        )
    }

    private func decide(
        context: ASHDecisionContext,
        candidates: [R06ASHBackendFixture],
        ablation: R06ASHAblationMode = .ashPlusContinuousSidecar
    ) -> R06ASHOrchestrationOutcome {
        R06ASHOrchestrator(parameters: .frozen).decide(
            scope: .fixtureOnly,
            context: context,
            candidates: candidates,
            masks: makeStaticMasks(),
            ablation: ablation
        )
    }

    private func selectedRecord(
        context: ASHDecisionContext,
        candidates: [R06ASHBackendFixture],
        ablation: R06ASHAblationMode = .ashPlusContinuousSidecar
    ) throws -> R06ASHDecisionRecord {
        let outcome = R06ASHOrchestrator(parameters: .frozen).decide(
            scope: .fixtureOnly,
            context: context,
            candidates: candidates,
            masks: try makeMasks(),
            ablation: ablation
        )
        let record: R06ASHDecisionRecord? = if case .selected(let record) = outcome {
            record
        } else {
            nil
        }
        return try XCTUnwrap(
            record,
            "Expected selected R06 outcome, received \(outcome)"
        )
    }

    private func makeContext(
        currentStateRaw: UInt16 = 0,
        previousStateRaw: UInt16 = 0,
        dwellFrames: Int = 0,
        sceneCutQ16: Int64 = 0,
        currentBackendID: String? = nil,
        fatalBackendID: String? = nil,
        postflightRiskQ16: Int64 = 0
    ) throws -> ASHDecisionContext {
        let previousState = try ASHState(rawValue: previousStateRaw)
        let currentState = try ASHState(rawValue: currentStateRaw)
        let fallback = try fatalBackendID.map {
            try R06ASHFallbackReason(code: .backendFailed, failedBackendID: $0)
        }
        return ASHDecisionContext(
            identity: try R06ASHIdentityContext(
                frameID: "fixture.frame.0001",
                shotID: "fixture.shot.0001",
                routeID: "fixture.route.pending",
                scaleNumerator: 2,
                scaleDenominator: 1,
                planeLayout: .nv12,
                chromaSiting: .left
            ),
            state: try R06ASHStateContext(
                continuousFeatureValuesQ16: Array(repeating: .zero, count: 8),
                currentState: currentState,
                previousState: previousState,
                stateTransition: R06ASHStateTransition(
                    previousState: previousState,
                    currentState: currentState
                ),
                dwellFrames: dwellFrames
            ),
            signals: R06ASHSignalContext(
                sceneCutConfidenceQ16: try R06ASHQ16(sceneCutQ16),
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
                currentBackendID: currentBackendID,
                previousBackendID: nil
            ),
            effects: R06ASHEffectContext(
                preprocessStrengthQ16: .zero,
                postprocessStrengthQ16: .zero,
                artifactRiskQ16: .zero
            ),
            outcome: R06ASHOutcomeContext(
                postflightFindings: try R06ASHPostflightFindings(
                    riskQ16: try R06ASHQ16(postflightRiskQ16),
                    findings: []
                ),
                fallbackReason: fallback,
                retryEligibility: .eligible
            )
        )
    }

    private func makeCandidate(
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

    private func makeMasks() throws -> R06ASHMaskSet {
        try R06ASHMaskSet(
            lumaProtection: R06ASHMask(
                id: .lumaProtection,
                width: 2,
                height: 2,
                samplesQ15: [0, 8_192, 16_384, 32_767]
            ),
            chromaProtection: R06ASHMask(
                id: .chromaProtection,
                width: 2,
                height: 2,
                samplesQ15: [32_767, 16_384, 8_192, 0]
            ),
            postprocessSuppression: R06ASHMask(
                id: .postprocessSuppression,
                width: 2,
                height: 2,
                samplesQ15: [0, 32_767, 32_767, 0]
            )
        )
    }

    private func makeStaticMasks() -> R06ASHMaskSet {
        do {
            return try makeMasks()
        } catch {
            preconditionFailure("Frozen R06 test masks must be valid: \(error)")
        }
    }
}
