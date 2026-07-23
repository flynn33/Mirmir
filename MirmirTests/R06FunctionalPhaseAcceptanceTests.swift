import XCTest
@testable import Mirmir

final class R06FunctionalPhaseAcceptanceTests: XCTestCase {
    func testEligibilityFilterProducesOneTraceablePlanWithoutMutatingInputs() throws {
        let validCandidate = try XCTUnwrap(R06ASHBackendCatalog.fixtures.first)
        let excludedScoreComponents = try R06ASHScoreComponents(
            qualityConfidenceQ16: 65_536,
            messageAlignmentQ16: 65_536,
            artifactRiskQ16: 0,
            transitionCostQ16: 0,
            resourceCostQ16: 0,
            postflightPenaltyQ16: 0
        )
        let fixtureIneligible = try R06ASHBackendFixture(
            backendID: "fixture.apple.excluded.fixture-ineligible",
            routeID: "fixture.route.excluded.fixture-ineligible",
            fixtureEligible: false,
            productQualified: false,
            wholeFrameOnly: true,
            scoreComponents: excludedScoreComponents
        )
        let nonWholeFrame = try R06ASHBackendFixture(
            backendID: "fixture.apple.excluded.non-whole-frame",
            routeID: "fixture.route.excluded.non-whole-frame",
            fixtureEligible: true,
            productQualified: false,
            wholeFrameOnly: false,
            scoreComponents: excludedScoreComponents
        )
        let context = try makeInitialContext()
        let masks = try makeMasks()
        let candidates = [fixtureIneligible, validCandidate, nonWholeFrame]
        let reorderedCandidates = [nonWholeFrame, fixtureIneligible, validCandidate]
        let contextBeforeDecision = context
        let masksBeforeDecision = masks
        let candidatesBeforeDecision = candidates
        let reorderedCandidatesBeforeDecision = reorderedCandidates
        let orchestrator = R06ASHOrchestrator(parameters: .frozen)

        let validPotentialScore = try R06ASHOrchestrator.checkedTotal(
            components: validCandidate.scoreComponents,
            effectivePostflightPenaltyQ16:
                validCandidate.scoreComponents.postflightPenaltyQ16,
            weights: R06ASHParameters.frozen.weights,
            routeID: validCandidate.routeID
        )
        let excludedPotentialScore = try R06ASHOrchestrator.checkedTotal(
            components: excludedScoreComponents,
            effectivePostflightPenaltyQ16:
                excludedScoreComponents.postflightPenaltyQ16,
            weights: R06ASHParameters.frozen.weights,
            routeID: fixtureIneligible.routeID
        )
        XCTAssertGreaterThan(excludedPotentialScore, validPotentialScore)

        let outcome = orchestrator.decide(
            scope: .fixtureOnly,
            context: context,
            candidates: candidates,
            masks: masks,
            ablation: .ashPlusContinuousSidecar
        )
        let reorderedOutcome = orchestrator.decide(
            scope: .fixtureOnly,
            context: context,
            candidates: reorderedCandidates,
            masks: masks,
            ablation: .ashPlusContinuousSidecar
        )

        XCTAssertEqual(reorderedOutcome, outcome)
        guard case .selected(let record) = outcome else {
            return XCTFail("Expected one selected R06 whole-frame plan, received \(outcome)")
        }
        XCTAssertEqual(record.candidateScores.count, 1)
        XCTAssertEqual(record.candidateScores.first?.backendID, validCandidate.backendID)
        XCTAssertEqual(record.candidateScores.first?.routeID, validCandidate.routeID)
        XCTAssertEqual(record.candidateScores.first?.components, validCandidate.scoreComponents)
        XCTAssertEqual(record.candidateScores.first?.totalQ16, validPotentialScore)
        XCTAssertEqual(record.selectedPlan.selectedBackendID, validCandidate.backendID)
        XCTAssertEqual(record.selectedPlan.selectedRouteID, validCandidate.routeID)
        XCTAssertEqual(
            record.selectedPlan.planID,
            "r06.plan.\(validCandidate.routeID).policy.message.00"
        )
        XCTAssertEqual(record.selectedPlan.policyProfileID, .message00)
        XCTAssertEqual(record.selectedPlan.masks, masks)
        XCTAssertEqual(record.reason, .initialSelection)
        XCTAssertEqual(record.ablation, .ashPlusContinuousSidecar)
        XCTAssertEqual(context, contextBeforeDecision)
        XCTAssertEqual(masks, masksBeforeDecision)
        XCTAssertEqual(candidates, candidatesBeforeDecision)
        XCTAssertEqual(reorderedCandidates, reorderedCandidatesBeforeDecision)
    }
}

private extension R06FunctionalPhaseAcceptanceTests {
    func makeInitialContext() throws -> ASHDecisionContext {
        let state = try ASHState(rawValue: 0)
        return ASHDecisionContext(
            identity: try R06ASHIdentityContext(
                frameID: "fixture.frame.r06.functional",
                shotID: "fixture.shot.r06.functional",
                routeID: "fixture.route.pending",
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
                dwellFrames: 0
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
                currentBackendID: nil,
                previousBackendID: nil
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
                fallbackReason: nil,
                retryEligibility: .eligible
            )
        )
    }

    func makeMasks() throws -> R06ASHMaskSet {
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
}
