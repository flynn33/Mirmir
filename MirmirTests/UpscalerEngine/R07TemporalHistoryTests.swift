import XCTest
@testable import Mirmir

final class R07TemporalHistoryTests: XCTestCase {
    func testBackendChurnFixtureUsesExactMostRecentTransitionRatio() throws {
        var history = R07TemporalHistory()
        XCTAssertEqual(history.insert(try makeEntry(ordinal: 0, backendID: "A")), .inserted)
        XCTAssertEqual(history.insert(try makeEntry(ordinal: 1, backendID: "A")), .inserted)
        XCTAssertEqual(history.insert(try makeEntry(ordinal: 2, backendID: "B")), .inserted)

        let metric = try history.backendChurn()
        XCTAssertEqual(metric.changes, 1)
        XCTAssertEqual(metric.transitionCount, 2)
        XCTAssertEqual(metric.windowEntryCount, 3)
        XCTAssertEqual(metric.valueQ16.rawValue, 32_768)
        XCTAssertTrue(metric.withinBound)
        XCTAssertFalse(metric.excessive)
    }

    func testStrengthChurnFixtureAveragesBothAxesPerTransition() throws {
        var history = R07TemporalHistory()
        XCTAssertEqual(
            history.insert(try makeEntry(ordinal: 10, preprocess: 0, postprocess: 0)),
            .inserted
        )
        XCTAssertEqual(
            history.insert(try makeEntry(ordinal: 11, preprocess: 8_192, postprocess: 8_192)),
            .inserted
        )
        XCTAssertEqual(
            history.insert(try makeEntry(ordinal: 12, preprocess: 16_384, postprocess: 16_384)),
            .inserted
        )

        let metric = try history.strengthChurn()
        XCTAssertEqual(metric.transitionCount, 2)
        XCTAssertEqual(metric.windowEntryCount, 3)
        XCTAssertEqual(metric.meanTransitionDeltaQ16.rawValue, 8_192)
        XCTAssertTrue(metric.withinBound)
        XCTAssertFalse(metric.excessive)
    }

    func testArtifactPersistenceFixtureUsesLastUpToFourEntries() throws {
        var history = R07TemporalHistory()
        let risks: [Int64] = [4_096, 8_192, 12_288, 8_192]
        for (offset, risk) in risks.enumerated() {
            XCTAssertEqual(
                history.insert(try makeEntry(ordinal: Int64(20 + offset), artifactRisk: risk)),
                .inserted
            )
        }

        let metric = try history.artifactPersistence()
        XCTAssertEqual(metric.windowEntryCount, 4)
        XCTAssertEqual(metric.meanRiskQ16.rawValue, 8_192)
        XCTAssertTrue(metric.withinBound)
        XCTAssertFalse(metric.excessive)
    }

    func testEveryFrozenResetCauseClearsHistoryAndIncrementsGenerationOnce() throws {
        let expectedCauses: [R07TemporalHistoryResetCause] = [
            .sceneCut,
            .discontinuity,
            .callerRequested,
            .cancellation,
            .endOfStream
        ]
        XCTAssertEqual(R07TemporalHistoryResetCause.allCases, expectedCauses)
        XCTAssertEqual(
            expectedCauses.map(\.rawValue),
            ["scene_cut", "discontinuity", "caller_requested", "cancellation", "end_of_stream"]
        )

        var history = R07TemporalHistory(generation: 7)
        var observedGenerations: [Int64] = []
        for (offset, cause) in expectedCauses.enumerated() {
            XCTAssertEqual(
                history.insert(try makeEntry(ordinal: Int64(offset))),
                .inserted
            )
            try history.reset(cause: cause)
            XCTAssertTrue(history.entries.isEmpty)
            observedGenerations.append(history.generation)
        }
        XCTAssertEqual(observedGenerations, [8, 9, 10, 11, 12])
    }

    func testDuplicateAndStaleInsertionsAreRejectedWithoutMutation() throws {
        var history = R07TemporalHistory()
        XCTAssertEqual(history.insert(try makeEntry(ordinal: 30)), .inserted)
        let acceptedSnapshot = history

        XCTAssertEqual(history.insert(try makeEntry(ordinal: 30)), .duplicateRejected)
        XCTAssertEqual(history, acceptedSnapshot)
        XCTAssertEqual(history.insert(try makeEntry(ordinal: 29)), .staleRejected)
        XCTAssertEqual(history, acceptedSnapshot)
        XCTAssertEqual(
            [
                R07TemporalHistoryInsertionDisposition.duplicateRejected.rawValue,
                R07TemporalHistoryInsertionDisposition.staleRejected.rawValue
            ],
            ["duplicate_rejected", "stale_rejected"]
        )
    }

    func testNinthInsertionEvictsOnlyTheOldestEntry() throws {
        var history = R07TemporalHistory()
        for ordinal in Int64(0)...Int64(8) {
            XCTAssertEqual(history.insert(try makeEntry(ordinal: ordinal)), .inserted)
        }

        XCTAssertEqual(R07TemporalHistory.capacity, 8)
        XCTAssertEqual(history.entries.map(\.frameOrdinal), Array(Int64(1)...Int64(8)))
        XCTAssertFalse(history.entries.contains { $0.frameOrdinal == 0 })
    }

    func testZeroTransitionMetricsUseExactNonexcessiveInitialValues() throws {
        var history = R07TemporalHistory()
        XCTAssertEqual(
            history.insert(
                try makeEntry(
                    ordinal: 40,
                    backendID: "A",
                    preprocess: 4_096,
                    postprocess: 8_192
                )
            ),
            .inserted
        )

        let backend = try history.backendChurn()
        XCTAssertEqual(backend.transitionCount, 0)
        XCTAssertEqual(backend.valueQ16, .zero)
        XCTAssertTrue(backend.withinBound)
        XCTAssertFalse(backend.excessive)

        let strength = try history.strengthChurn()
        XCTAssertEqual(strength.transitionCount, 0)
        XCTAssertEqual(strength.meanTransitionDeltaQ16, .zero)
        XCTAssertTrue(strength.withinBound)
        XCTAssertFalse(strength.excessive)
    }

    func testEmptyAndSingleArtifactPersistenceUseExactInitialSemantics() throws {
        var history = R07TemporalHistory()
        let empty = try history.artifactPersistence()
        XCTAssertEqual(empty.windowEntryCount, 0)
        XCTAssertEqual(empty.meanRiskQ16, .zero)
        XCTAssertTrue(empty.withinBound)
        XCTAssertFalse(empty.excessive)

        XCTAssertEqual(
            history.insert(try makeEntry(ordinal: 50, artifactRisk: 4_096)),
            .inserted
        )
        let single = try history.artifactPersistence()
        XCTAssertEqual(single.windowEntryCount, 1)
        XCTAssertEqual(single.meanRiskQ16.rawValue, 4_096)
        XCTAssertTrue(single.withinBound)
        XCTAssertFalse(single.excessive)
    }

    func testMetricsUseOnlyTheirFrozenMostRecentWindows() throws {
        var history = R07TemporalHistory()
        XCTAssertEqual(
            history.insert(
                try makeEntry(
                    ordinal: 0,
                    backendID: "A",
                    preprocess: 65_536,
                    postprocess: 65_536,
                    artifactRisk: 65_536
                )
            ),
            .inserted
        )
        for ordinal in Int64(1)...Int64(5) {
            XCTAssertEqual(
                history.insert(
                    try makeEntry(
                        ordinal: ordinal,
                        backendID: "B",
                        preprocess: 0,
                        postprocess: 0,
                        artifactRisk: 0
                    )
                ),
                .inserted
            )
        }

        let backend = try history.backendChurn()
        XCTAssertEqual(backend.windowEntryCount, 5)
        XCTAssertEqual(backend.transitionCount, 4)
        XCTAssertEqual(backend.changes, 0)
        XCTAssertEqual(backend.valueQ16, .zero)

        let strength = try history.strengthChurn()
        XCTAssertEqual(strength.windowEntryCount, 5)
        XCTAssertEqual(strength.meanTransitionDeltaQ16, .zero)

        let artifact = try history.artifactPersistence()
        XCTAssertEqual(artifact.windowEntryCount, 4)
        XCTAssertEqual(artifact.meanRiskQ16, .zero)
    }

    func testThresholdEqualityIsWithinBoundAndOneUnitAboveIsExcessive() throws {
        var equalityHistory = R07TemporalHistory()
        XCTAssertEqual(equalityHistory.insert(try makeEntry(ordinal: 0, backendID: "A")), .inserted)
        XCTAssertEqual(equalityHistory.insert(try makeEntry(ordinal: 1, backendID: "A")), .inserted)
        XCTAssertEqual(equalityHistory.insert(try makeEntry(ordinal: 2, backendID: "B")), .inserted)
        let backendEquality = try equalityHistory.backendChurn()
        XCTAssertEqual(backendEquality.valueQ16.rawValue, 32_768)
        XCTAssertTrue(backendEquality.withinBound)
        XCTAssertFalse(backendEquality.excessive)

        var excessiveHistory = R07TemporalHistory()
        XCTAssertEqual(
            excessiveHistory.insert(
                try makeEntry(ordinal: 0, preprocess: 0, postprocess: 0, artifactRisk: 8_193)
            ),
            .inserted
        )
        XCTAssertEqual(
            excessiveHistory.insert(
                try makeEntry(
                    ordinal: 1,
                    preprocess: 8_193,
                    postprocess: 8_193,
                    artifactRisk: 8_193
                )
            ),
            .inserted
        )
        let strength = try excessiveHistory.strengthChurn()
        XCTAssertEqual(strength.meanTransitionDeltaQ16.rawValue, 8_193)
        XCTAssertFalse(strength.withinBound)
        XCTAssertTrue(strength.excessive)
        let artifact = try excessiveHistory.artifactPersistence()
        XCTAssertEqual(artifact.meanRiskQ16.rawValue, 8_193)
        XCTAssertFalse(artifact.withinBound)
        XCTAssertTrue(artifact.excessive)

        var backendExcessive = R07TemporalHistory()
        XCTAssertEqual(backendExcessive.insert(try makeEntry(ordinal: 0, backendID: "A")), .inserted)
        XCTAssertEqual(backendExcessive.insert(try makeEntry(ordinal: 1, backendID: "B")), .inserted)
        XCTAssertEqual(try backendExcessive.backendChurn().valueQ16, .one)
        XCTAssertTrue(try backendExcessive.backendChurn().excessive)
    }

    func testStrengthNestedMeansAndFinalMeanBothRoundTowardZero() throws {
        var history = R07TemporalHistory()
        XCTAssertEqual(
            history.insert(try makeEntry(ordinal: 0, preprocess: 0, postprocess: 0)),
            .inserted
        )
        XCTAssertEqual(
            history.insert(try makeEntry(ordinal: 1, preprocess: 1, postprocess: 0)),
            .inserted
        )
        XCTAssertEqual(
            history.insert(try makeEntry(ordinal: 2, preprocess: 3, postprocess: 1)),
            .inserted
        )

        let metric = try history.strengthChurn()
        XCTAssertEqual(metric.transitionCount, 2)
        XCTAssertEqual(metric.meanTransitionDeltaQ16.rawValue, 0)
    }

    func testGenerationOverflowRejectsResetWithoutMutation() throws {
        var history = R07TemporalHistory(generation: Int64.max)
        XCTAssertEqual(history.insert(try makeEntry(ordinal: 0)), .inserted)
        let snapshot = history

        XCTAssertThrowsError(try history.reset(cause: .callerRequested)) { error in
            XCTAssertEqual(error as? R07CheckedInt64Error, .overflow(operation: "addition"))
        }
        XCTAssertEqual(history, snapshot)
    }

    private func makeEntry(
        ordinal: Int64,
        backendID: String = "A",
        preprocess: Int64 = 0,
        postprocess: Int64 = 0,
        artifactRisk: Int64 = 0
    ) throws -> R07TemporalHistoryEntry {
        R07TemporalHistoryEntry(
            frameOrdinal: ordinal,
            backendID: backendID,
            preprocessStrengthQ16: try R06ASHQ16(preprocess),
            postprocessStrengthQ16: try R06ASHQ16(postprocess),
            artifactRiskQ16: try R06ASHQ16(artifactRisk)
        )
    }
}
