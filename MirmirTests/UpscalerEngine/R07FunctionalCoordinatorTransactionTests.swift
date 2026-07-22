import XCTest
@testable import Mirmir

final class R07FunctionalCoordinatorTransactionTests: XCTestCase {
    func testEmptyCandidatesFailsWithoutCommittingCoordinatorState() throws {
        var options = R07FunctionalInputOptions()
        options.candidates = []
        let input = try R07FunctionalTestFixtures.input(options)

        try assertFailurePreservesState(
            input: input,
            history: R07FunctionalTestFixtures.history(),
            expected: .r06Failed(.noEligibleFixtureBackend)
        )
    }

    func testDuplicateAndStaleHistoryInsertionDoNotCommitState() throws {
        let input = try R07FunctionalTestFixtures.input()
        let cases: [(Int64, R07TemporalHistoryInsertionDisposition)] = [
            (101, .duplicateRejected),
            (102, .staleRejected)
        ]

        for (latestOrdinal, disposition) in cases {
            try assertFailurePreservesState(
                input: input,
                history: R07FunctionalTestFixtures.history(
                    frameOrdinal: latestOrdinal
                ),
                expected: .historyInsertionRejected(disposition)
            )
        }
    }

    func testShotAndTargetOrdinalMismatchDoNotCommitState() throws {
        var otherShotContext = R07FunctionalContextOptions()
        otherShotContext.shotID = "other.shot"
        var shotOptions = R07FunctionalInputOptions()
        shotOptions.nextBaseContext = try R07FunctionalTestFixtures.makeContext(
            otherShotContext
        )
        let shotInput = try R07FunctionalTestFixtures.input(shotOptions)
        try assertFailurePreservesState(
            input: shotInput,
            history: R07FunctionalTestFixtures.history(),
            expected: .shotIdentityMismatch(
                expected: "r07.shot",
                actual: "other.shot"
            )
        )

        var ordinalOptions = R07FunctionalInputOptions()
        ordinalOptions.targetDecisionOrdinal = 999
        let ordinalInput = try R07FunctionalTestFixtures.input(ordinalOptions)
        try assertFailurePreservesState(
            input: ordinalInput,
            history: R07FunctionalTestFixtures.history(),
            expected: .targetDecisionOrdinalMismatch(expected: 101, actual: 999)
        )
    }
}

private extension R07FunctionalCoordinatorTransactionTests {
    func assertFailurePreservesState(
        input: R07FunctionalCoordinatorInput,
        history: R07TemporalHistory,
        expected: R07FunctionalCoordinatorError
    ) throws {
        let postflight = try R07FunctionalTestFixtures.governance(
            completed: input.completedDecision,
            riskQ16: 10_000
        )
        var coordinator = R07FunctionalCoordinator(
            supportExecutor: R07DeterministicFixtureSupportExecutor(),
            history: history,
            postflightGovernance: postflight
        )

        XCTAssertThrowsError(try coordinator.process(input)) { error in
            XCTAssertEqual(error as? R07FunctionalCoordinatorError, expected)
        }
        XCTAssertEqual(coordinator.history, history)
        XCTAssertEqual(coordinator.postflightGovernance, postflight)
    }
}
