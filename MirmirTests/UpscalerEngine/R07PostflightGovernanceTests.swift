import XCTest
@testable import Mirmir

final class R07PostflightGovernanceTests: XCTestCase {
    func testCompletedNIsBoundWithoutRewritingItsR06Decision() throws {
        let completed = try makeCompletedDecision()
        let originalRecord = completed.record
        let report = try makeReport()
        var governance = R07PostflightGovernance()

        let result = try evaluated(
            governance.apply(scope: .fixtureOnly, report: report, to: completed)
        )

        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.disposition, .acceptedScheduledForNPlus1)
        XCTAssertFalse(result.rewritesDecisionN)
        XCTAssertEqual(completed.record, originalRecord)
        XCTAssertEqual(result.feedback?.sourceDecisionOrdinal, 100)
        XCTAssertEqual(result.feedback?.targetDecisionOrdinal, 101)
    }

    func testFeedbackAppliesOnlyToSameShotNPlus1WithExactOrderedPayload() throws {
        let completed = try makeCompletedDecision()
        let report = try makeReport()
        var governance = R07PostflightGovernance()

        let result = try evaluated(
            governance.apply(scope: .fixtureOnly, report: report, to: completed)
        )
        let feedback = try XCTUnwrap(result.feedback)

        XCTAssertEqual(feedback.reportID, "report-100")
        XCTAssertEqual(feedback.shotID, "shot-A")
        XCTAssertEqual(feedback.sourceDecisionOrdinal, 100)
        XCTAssertEqual(feedback.targetDecisionOrdinal, 101)
        XCTAssertEqual(feedback.artifactRiskQ16.rawValue, 32_768)
        XCTAssertEqual(feedback.findingIDs, ["ringing", "ghosting"])
        XCTAssertEqual(governance.feedback(forShotID: "shot-A", decisionOrdinal: 101), [feedback])
        XCTAssertTrue(governance.feedback(forShotID: "shot-A", decisionOrdinal: 100).isEmpty)
        XCTAssertTrue(governance.feedback(forShotID: "shot-A", decisionOrdinal: 102).isEmpty)
        XCTAssertTrue(governance.feedback(forShotID: "shot-B", decisionOrdinal: 101).isEmpty)
    }

    func testStaleAndFutureReportsAreRejectedAndDiscarded() throws {
        let completed = try makeCompletedDecision()
        let cases: [(UInt64, R07PostflightRejection)] = [
            (99, .stale),
            (101, .future)
        ]

        for (ordinal, rejection) in cases {
            var governance = R07PostflightGovernance()
            let report = try makeReport(
                reportID: "report-\(ordinal)",
                decisionOrdinal: ordinal
            )
            let result = try evaluated(
                governance.apply(scope: .fixtureOnly, report: report, to: completed)
            )
            XCTAssertFalse(result.accepted)
            XCTAssertEqual(result.disposition, .rejectedDiscarded)
            XCTAssertEqual(result.selectedRejection, rejection)
            XCTAssertNil(result.feedback)
            XCTAssertFalse(result.rewritesDecisionN)
            XCTAssertEqual(governance.pendingFeedbackCount, 0)
        }
    }

    func testDuplicateSequenceSchedulesOnceThenRejectsAndDiscards() throws {
        let completed = try makeCompletedDecision()
        let report = try makeReport()
        var governance = R07PostflightGovernance()

        let first = try evaluated(
            governance.apply(scope: .fixtureOnly, report: report, to: completed)
        )
        let second = try evaluated(
            governance.apply(scope: .fixtureOnly, report: report, to: completed)
        )

        XCTAssertEqual(first.disposition, .acceptedScheduledForNPlus1)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(second.disposition, .duplicateRejectedDiscarded)
        XCTAssertEqual(second.selectedRejection, .duplicate)
        XCTAssertFalse(second.accepted)
        XCTAssertFalse(second.rewritesDecisionN)
        XCTAssertEqual(governance.pendingFeedbackCount, 1)
        XCTAssertEqual(governance.pendingFeedbackCount(reportID: "report-100"), 1)
    }

    func testCrossShotReportIsRejectedAndDiscarded() throws {
        let completed = try makeCompletedDecision(shotID: "shot-B")
        let report = try makeReport(shotID: "shot-A")
        var governance = R07PostflightGovernance()

        let result = try evaluated(
            governance.apply(scope: .fixtureOnly, report: report, to: completed)
        )

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.disposition, .rejectedDiscarded)
        XCTAssertEqual(result.selectedRejection, .crossShot)
        XCTAssertNil(result.feedback)
        XCTAssertFalse(result.rewritesDecisionN)
    }

    func testOverlappingInvalidityUsesExactFrozenRejectionPrecedence() {
        let invalidity = R07PostflightInvalidity(
            duplicate: true,
            crossShot: true,
            stale: true,
            future: true
        )

        XCTAssertEqual(R07PostflightRejection.precedence, [.duplicate, .crossShot, .stale, .future])
        XCTAssertEqual(R07PostflightGovernance.selectRejection(invalidity), .duplicate)
        XCTAssertEqual(
            R07PostflightGovernance.rejectionDisposition(invalidity),
            .rejectedDiscarded
        )
        XCTAssertEqual(
            R07PostflightGovernance.rejectionDisposition(
                R07PostflightInvalidity(
                    duplicate: true,
                    crossShot: false,
                    stale: false,
                    future: false
                )
            ),
            .duplicateRejectedDiscarded
        )
        XCTAssertEqual(
            R07PostflightGovernance.selectRejection(
                R07PostflightInvalidity(
                    duplicate: false,
                    crossShot: true,
                    stale: true,
                    future: true
                )
            ),
            .crossShot
        )
        XCTAssertEqual(
            R07PostflightGovernance.selectRejection(
                R07PostflightInvalidity(
                    duplicate: false,
                    crossShot: false,
                    stale: true,
                    future: true
                )
            ),
            .stale
        )
        XCTAssertEqual(
            R07PostflightGovernance.selectRejection(
                R07PostflightInvalidity(
                    duplicate: false,
                    crossShot: false,
                    stale: false,
                    future: true
                )
            ),
            .future
        )
    }

    func testProductGateRunsBeforePostflightValidationOrScheduling() throws {
        let completed = try makeCompletedDecision(decisionOrdinal: .max)
        let report = try makeReport(decisionOrdinal: .max)
        var governance = R07PostflightGovernance()

        let outcome = try governance.apply(
            scope: .product,
            report: report,
            to: completed
        )

        XCTAssertEqual(outcome, .blocked(.blocked))
        XCTAssertTrue(governance.acceptedReportIDs.isEmpty)
        XCTAssertTrue(governance.pendingFeedback.isEmpty)
    }

    func testEveryResetAndCancellationBoundaryDiscardsPendingFeedback() throws {
        for reason in R07PostflightBoundaryReason.allCases {
            var governance = R07PostflightGovernance()
            _ = try governance.apply(
                scope: .fixtureOnly,
                report: makeReport(),
                to: makeCompletedDecision()
            )
            let boundary = governance.applyBoundary(reason)

            XCTAssertEqual(boundary.reason, reason)
            XCTAssertEqual(boundary.discardedPendingFeedbackCount, 1)
            XCTAssertEqual(boundary.clearedAcceptedReportIdentityCount, 1)
            XCTAssertTrue(governance.pendingFeedback.isEmpty)
            XCTAssertTrue(governance.acceptedReportIDs.isEmpty)
        }
    }

    func testIncompleteDecisionInvalidIdentityAndOrdinalOverflowFailClosed() throws {
        XCTAssertThrowsError(
            try R07CompletedR06Decision(
                shotID: "shot-A",
                decisionOrdinal: 100,
                record: makeDecisionRecord(),
                decisionCompleted: false
            )
        ) { error in
            XCTAssertEqual(error as? R07PostflightGovernanceError, .decisionNotCompleted)
        }
        XCTAssertThrowsError(
            try makeReport(reportID: " report-100")
        ) { error in
            XCTAssertEqual(
                error as? R07PostflightGovernanceError,
                .invalidIdentity(field: "report_id")
            )
        }

        let completed = try makeCompletedDecision(decisionOrdinal: .max)
        let report = try makeReport(decisionOrdinal: .max)
        var governance = R07PostflightGovernance()
        XCTAssertThrowsError(
            try governance.apply(scope: .fixtureOnly, report: report, to: completed)
        ) { error in
            XCTAssertEqual(
                error as? R07PostflightGovernanceError,
                .targetDecisionOrdinalOverflow(.max)
            )
        }
        XCTAssertTrue(governance.acceptedReportIDs.isEmpty)
        XCTAssertTrue(governance.pendingFeedback.isEmpty)
    }

    private func evaluated(
        _ outcome: R07PostflightGovernanceOutcome
    ) throws -> R07PostflightApplicationResult {
        guard case .evaluated(let result) = outcome else {
            throw TestError.unexpectedOutcome
        }
        return result
    }

    private func makeCompletedDecision(
        shotID: String = "shot-A",
        decisionOrdinal: UInt64 = 100
    ) throws -> R07CompletedR06Decision {
        try R07CompletedR06Decision(
            shotID: shotID,
            decisionOrdinal: decisionOrdinal,
            record: makeDecisionRecord(),
            decisionCompleted: true
        )
    }

    private func makeReport(
        reportID: String = "report-100",
        shotID: String = "shot-A",
        decisionOrdinal: UInt64 = 100,
        riskQ16: Int64 = 32_768,
        findingIDs: [String] = ["ringing", "ghosting"]
    ) throws -> R07PostflightReport {
        try R07PostflightReport(
            reportID: reportID,
            shotID: shotID,
            decisionOrdinal: decisionOrdinal,
            findings: R06ASHPostflightFindings(
                riskQ16: R06ASHQ16(riskQ16),
                findings: try findingIDs.map(R06ASHPostflightFinding.init(id:))
            )
        )
    }

    private func makeDecisionRecord() throws -> R06ASHDecisionRecord {
        R06ASHDecisionRecord(
            candidateScores: [],
            selectedPlan: R06ASHWholeFramePlan(
                planID: "r06.plan.fixture",
                selectedBackendID: "fixture.apple.mps_lanczos",
                selectedRouteID: "fixture.route.mps_lanczos",
                policyProfileID: .message00,
                masks: try makeMasks()
            ),
            reason: .initialSelection,
            ablation: .ashPlusContinuousSidecar
        )
    }

    private func makeMasks() throws -> R06ASHMaskSet {
        try R06ASHMaskSet(
            lumaProtection: R06ASHMask(
                id: .lumaProtection,
                width: 1,
                height: 1,
                samplesQ15: [0]
            ),
            chromaProtection: R06ASHMask(
                id: .chromaProtection,
                width: 1,
                height: 1,
                samplesQ15: [0]
            ),
            postprocessSuppression: R06ASHMask(
                id: .postprocessSuppression,
                width: 1,
                height: 1,
                samplesQ15: [0]
            )
        )
    }

    private enum TestError: Error {
        case unexpectedOutcome
    }
}
