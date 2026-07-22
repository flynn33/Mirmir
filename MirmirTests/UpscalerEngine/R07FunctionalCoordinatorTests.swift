import XCTest
@testable import Mirmir

final class R07FunctionalCoordinatorTests: XCTestCase {
    func testEndToEndExecutesSupportAndCarriesFeedbackIntoNPlus1() throws {
        let current = R07FunctionalTestFixtures.edgePlane()
        let alignedHistory = current.map { $0 - 8_000 }
        var options = R07FunctionalInputOptions()
        options.currentLumaQ16 = current
        options.previousLumaQ16 = current
        options.alignedPreviousLumaQ16 = alignedHistory
        options.protectedRegions = [
            R07FunctionalTestFixtures.protectedRegion(kind: .face, fillQ15: 10_000),
            R07FunctionalTestFixtures.protectedRegion(kind: .text, fillQ15: 20_000)
        ]
        options.artifactAnalysis = R07FunctionalTestFixtures.artifactInput(
            current: current,
            previous: current,
            ringingUpper: 30_000
        )
        let input = try R07FunctionalTestFixtures.input(options)
        let sourceRecord = input.completedDecision.record
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: R07DeterministicFixtureSupportExecutor()
        )

        let result = try R07FunctionalTestFixtures.result(
            coordinator.process(input)
        )

        XCTAssertEqual(
            result.supportExecutions.map(\.capabilityID),
            [.temporalNoiseFilter, .coreImageEdgePreserve,
             .coreImageEdgePreserve, .mpsGuidedFilter]
        )
        XCTAssertEqual(result.denoisedLumaQ16.first, 17_000)
        XCTAssertEqual(result.denoisedLumaQ16.last, 37_000)
        XCTAssertNotEqual(
            result.reconstructedChromaCbQ16,
            result.reconstructedChromaCrQ16
        )
        XCTAssertEqual(result.protectedComposition.composedQ15.first?.rawValue, 20_000)
        XCTAssertEqual(result.protectedComposition.ownerByPixel.first, .text)
        XCTAssertTrue(result.protectedComposition.lumaChromaPostprocessIdentical)
        XCTAssertEqual(result.nextDecisionContext.faceOccupancyQ15.rawValue, 10_000)
        XCTAssertEqual(result.nextDecisionContext.textOccupancyQ15.rawValue, 20_000)
        XCTAssertEqual(
            result.nextDecisionRecord.selectedPlan.masks,
            result.protectedComposition.masks
        )
        XCTAssertTrue(
            result.consumedPostflightFindings.findings.map(\.id).contains("ringing")
        )
        XCTAssertEqual(
            result.nextDecisionContext.postflightFindings,
            result.consumedPostflightFindings
        )
        XCTAssertGreaterThan(result.nextDecisionContext.postflightRiskQ16.rawValue, 0)
        XCTAssertTrue(result.nextDecisionRecord.candidateScores.allSatisfy {
            $0.effectivePostflightPenaltyQ16
                > $0.components.postflightPenaltyQ16
        })
        XCTAssertEqual(result.sourceDecision.record, sourceRecord)
        XCTAssertEqual(input.completedDecision.record, sourceRecord)
        XCTAssertEqual(result.history.entries.map(\.frameOrdinal), [101])
        XCTAssertEqual(coordinator.history, result.history)
        XCTAssertEqual(coordinator.postflightGovernance.pendingFeedbackCount, 0)
    }

    func testEmptyAndAllZeroProtectionAreExplicitlyNotApplicable() throws {
        let regionSets: [[R07LowResolutionProtectedRegion]] = [
            [],
            [R07FunctionalTestFixtures.protectedRegion(kind: .face, fillQ15: 0)]
        ]

        for regions in regionSets {
            var options = R07FunctionalInputOptions()
            options.protectedRegions = regions
            var coordinator = R07FunctionalCoordinator(
                supportExecutor: R07DeterministicFixtureSupportExecutor()
            )
            let result = try R07FunctionalTestFixtures.result(
                coordinator.process(R07FunctionalTestFixtures.input(options))
            )

            XCTAssertEqual(
                result.protectedIntegrityDisposition,
                .notApplicableNoProtectedWeight
            )
            XCTAssertEqual(result.protectedIntegrity.weightedMAEQ16, .zero)
            XCTAssertTrue(result.protectedComposition.composedQ15.allSatisfy {
                $0 == .zero
            })
            XCTAssertEqual(
                result.supportExecutions.filter {
                    $0.capabilityID == .coreImageEdgePreserve
                }.count,
                regions.count
            )
        }
    }

    func testProductGatePrecedesValidationAndSupportExecution() throws {
        let executor = R07RecordingSupportExecutor()
        var options = R07FunctionalInputOptions()
        options.scope = .product
        options.targetDecisionOrdinal = 999
        let initialHistory = R07FunctionalTestFixtures.history()
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: executor,
            history: initialHistory
        )

        let outcome = try coordinator.process(
            R07FunctionalTestFixtures.input(options)
        )

        XCTAssertEqual(outcome, .blocked(.blocked))
        XCTAssertEqual(
            R07FunctionalProductGateResult.blocked.reason,
            .fixtureSimulationNotProductAuthorized
        )
        XCTAssertFalse(R07FunctionalProductGateResult.blocked.supportExecutionAttempted)
        XCTAssertTrue(executor.requests.isEmpty)
        XCTAssertEqual(coordinator.history, initialHistory)
        XCTAssertEqual(coordinator.postflightGovernance, R07PostflightGovernance())
    }

    func testPreseededHigherRiskControlsEffectsScoresAndHistory() throws {
        let flat = R07FunctionalTestFixtures.constant(30_000)
        let completed = try R07FunctionalTestFixtures.completedDecision()
        let governance = try R07FunctionalTestFixtures.governance(
            completed: completed,
            riskQ16: 50_000
        )
        var options = R07FunctionalInputOptions()
        options.completedDecision = completed
        options.currentLumaQ16 = flat
        options.previousLumaQ16 = flat
        options.alignedPreviousLumaQ16 = flat
        options.sourceChromaCbQ16 = flat
        options.sourceChromaCrQ16 = flat
        options.artifactAnalysis = R07FunctionalTestFixtures.artifactInput(
            current: flat,
            previous: flat
        )
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: R07DeterministicFixtureSupportExecutor(),
            postflightGovernance: governance
        )

        let result = try R07FunctionalTestFixtures.result(
            coordinator.process(R07FunctionalTestFixtures.input(options))
        )

        XCTAssertEqual(result.consumedPostflightFindings.riskQ16.rawValue, 50_000)
        XCTAssertEqual(
            result.consumedPostflightFindings.findings.map(\.id).first,
            "preseed"
        )
        XCTAssertEqual(result.nextDecisionContext.artifactRiskQ16.rawValue, 50_000)
        XCTAssertEqual(result.nextDecisionContext.postflightRiskQ16.rawValue, 50_000)
        XCTAssertEqual(result.history.entries.last?.artifactRiskQ16.rawValue, 50_000)
        XCTAssertTrue(result.nextDecisionRecord.candidateScores.allSatisfy {
            $0.effectivePostflightPenaltyQ16 == 50_000
        })
    }

    func testFailurePreservesHistoryAndPostflightState() throws {
        let completed = try R07FunctionalTestFixtures.completedDecision()
        let initialHistory = R07FunctionalTestFixtures.history()
        let initialPostflight = try R07FunctionalTestFixtures.governance(
            completed: completed,
            riskQ16: 20_000
        )
        var options = R07FunctionalInputOptions()
        options.completedDecision = completed
        options.protectedRegions = [
            R07FunctionalTestFixtures.protectedRegion(kind: .face, fillQ15: 10_000)
        ]
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: R07RecordingSupportExecutor(
                mutation: .payload(.mpsGuidedFilter)
            ),
            history: initialHistory,
            postflightGovernance: initialPostflight
        )

        XCTAssertThrowsError(
            try coordinator.process(R07FunctionalTestFixtures.input(options))
        ) { error in
            XCTAssertEqual(
                error as? R07FunctionalCoordinatorError,
                .supportExecutionPayloadMismatch(.mpsGuidedFilter)
            )
        }
        XCTAssertEqual(coordinator.history, initialHistory)
        XCTAssertEqual(coordinator.postflightGovernance, initialPostflight)
    }

    func testForgedExecutionIdentityAndPayloadFailClosedForEveryStage() throws {
        let capabilities: [R07SupportCapabilityID] = [
            .temporalNoiseFilter,
            .coreImageEdgePreserve,
            .mpsGuidedFilter
        ]
        var options = R07FunctionalInputOptions()
        options.protectedRegions = [
            R07FunctionalTestFixtures.protectedRegion(kind: .face, fillQ15: 10_000)
        ]
        let input = try R07FunctionalTestFixtures.input(options)

        for capability in capabilities {
            try assertCoordinatorRejects(
                mutation: .identity(capability),
                expected: .supportExecutionIdentityMismatch(capability),
                input: input
            )
            try assertCoordinatorRejects(
                mutation: .payload(capability),
                expected: .supportExecutionPayloadMismatch(capability),
                input: input
            )
        }
    }
}

private extension R07FunctionalCoordinatorTests {
    func assertCoordinatorRejects(
        mutation: R07SupportExecutionMutation,
        expected: R07FunctionalCoordinatorError,
        input: R07FunctionalCoordinatorInput
    ) throws {
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: R07RecordingSupportExecutor(mutation: mutation)
        )
        XCTAssertThrowsError(try coordinator.process(input)) { error in
            XCTAssertEqual(error as? R07FunctionalCoordinatorError, expected)
        }
    }
}
