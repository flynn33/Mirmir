import XCTest
@testable import Mirmir

final class R07PostflightFeedbackConsumptionTests: XCTestCase {
    func testConsumeMergesAllExactTargetFeedbackOnceInPendingOrder() throws {
        let completed = try makeCompletedDecision()
        var governance = R07PostflightGovernance()
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: makeReport(
                reportID: "report-100-a",
                riskQ16: 16_384,
                findingIDs: ["ringing", "halo"]
            ),
            to: completed
        )
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: makeReport(
                reportID: "report-100-b",
                riskQ16: 49_152,
                findingIDs: ["ghosting", "flicker"]
            ),
            to: completed
        )

        let consumed = try XCTUnwrap(
            governance.consumeFeedback(forShotID: "shot-A", decisionOrdinal: 101)
        )

        XCTAssertEqual(consumed.riskQ16.rawValue, 49_152)
        XCTAssertEqual(
            consumed.findings.map(\.id),
            ["ringing", "halo", "ghosting", "flicker"]
        )
        XCTAssertEqual(governance.pendingFeedbackCount, 0)
        XCTAssertNil(
            try governance.consumeFeedback(forShotID: "shot-A", decisionOrdinal: 101)
        )
    }

    func testConsumeLeavesUnrelatedPendingFeedbackUntouched() throws {
        let shotA = try makeCompletedDecision(shotID: "shot-A")
        let shotB = try makeCompletedDecision(shotID: "shot-B")
        var governance = R07PostflightGovernance()
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: makeReport(reportID: "report-a", shotID: "shot-A"),
            to: shotA
        )
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: makeReport(
                reportID: "report-b",
                shotID: "shot-B",
                riskQ16: 8_192,
                findingIDs: ["halo"]
            ),
            to: shotB
        )

        let shotAFindings = try XCTUnwrap(
            governance.consumeFeedback(forShotID: "shot-A", decisionOrdinal: 101)
        )

        XCTAssertEqual(shotAFindings.findings.map(\.id), ["ringing", "ghosting"])
        XCTAssertEqual(governance.pendingFeedbackCount, 1)
        XCTAssertEqual(
            governance.feedback(forShotID: "shot-B", decisionOrdinal: 101)
                .map(\.reportID),
            ["report-b"]
        )
    }

    func testConsumeStableDeduplicatesFindingIDsAndConsumesExactlyOnce() throws {
        let completed = try makeCompletedDecision()
        var governance = R07PostflightGovernance()
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: makeReport(
                reportID: "report-100-a",
                riskQ16: 16_384,
                findingIDs: ["ringing", "halo"]
            ),
            to: completed
        )
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: makeReport(
                reportID: "report-100-b",
                riskQ16: 49_152,
                findingIDs: ["ringing", "ghosting"]
            ),
            to: completed
        )
        let consumed = try XCTUnwrap(
            governance.consumeFeedback(forShotID: "shot-A", decisionOrdinal: 101)
        )

        XCTAssertEqual(consumed.riskQ16.rawValue, 49_152)
        XCTAssertEqual(
            consumed.findings.map(\.id),
            ["ringing", "halo", "ghosting"]
        )
        XCTAssertEqual(governance.pendingFeedbackCount, 0)
        XCTAssertNil(
            try governance.consumeFeedback(forShotID: "shot-A", decisionOrdinal: 101)
        )
    }

    func testConsumeInvalidShotIdentityFailsWithoutMutation() throws {
        var governance = R07PostflightGovernance()
        _ = try governance.apply(
            scope: .fixtureOnly,
            report: makeReport(),
            to: makeCompletedDecision()
        )
        let pendingBeforeConsume = governance.pendingFeedback

        XCTAssertThrowsError(
            try governance.consumeFeedback(forShotID: " shot-A", decisionOrdinal: 101)
        ) { error in
            XCTAssertEqual(
                error as? R07PostflightGovernanceError,
                .invalidIdentity(field: "consume_feedback.shot_id")
            )
        }
        XCTAssertEqual(governance.pendingFeedback, pendingBeforeConsume)
    }
}

private extension R07PostflightFeedbackConsumptionTests {
    func makeCompletedDecision(
        shotID: String = "shot-A"
    ) throws -> R07CompletedR06Decision {
        try R07CompletedR06Decision(
            shotID: shotID,
            decisionOrdinal: 100,
            record: makeDecisionRecord(),
            decisionCompleted: true
        )
    }

    func makeReport(
        reportID: String = "report-100",
        shotID: String = "shot-A",
        riskQ16: Int64 = 32_768,
        findingIDs: [String] = ["ringing", "ghosting"]
    ) throws -> R07PostflightReport {
        try R07PostflightReport(
            reportID: reportID,
            shotID: shotID,
            decisionOrdinal: 100,
            findings: R06ASHPostflightFindings(
                riskQ16: R06ASHQ16(riskQ16),
                findings: try findingIDs.map(R06ASHPostflightFinding.init(id:))
            )
        )
    }

    func makeDecisionRecord() throws -> R06ASHDecisionRecord {
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

    func makeMasks() throws -> R06ASHMaskSet {
        let mask = try R06ASHMask(
            id: .lumaProtection,
            width: 1,
            height: 1,
            samplesQ15: [0]
        )
        return try R06ASHMaskSet(
            lumaProtection: mask,
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
}
