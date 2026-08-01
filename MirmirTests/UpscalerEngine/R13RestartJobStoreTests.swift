import Foundation
import XCTest
@testable import Mirmir

// Persistence scenarios share one descriptor-pinned restart-store fixture.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class R13RestartJobStoreTests: XCTestCase {
    func testReopenVerifiesCachedPrefixForFreshWriterReplay() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 3)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await store.create(core)
        let first = try fixture.frame(value: 10)
        let second = try fixture.frame(value: 20)
        plan = try await store.commitProcessedFrame(
            first,
            at: 0,
            using: plan
        )
        plan = try await store.commitProcessedFrame(
            second,
            at: 1,
            using: plan
        )

        let reopened = try await store.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )

        XCTAssertTrue(reopened.requiresFreshMediaWriter)
        XCTAssertEqual(reopened.writerStartFrameIndex, 0)
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 2)
        XCTAssertEqual(reopened.backendStartFrameIndex, 2)
        XCTAssertEqual(
            try reopened.disposition(forFrameAt: 0),
            .replayVerifiedCache
        )
        XCTAssertEqual(
            try reopened.disposition(forFrameAt: 1),
            .replayVerifiedCache
        )
        XCTAssertEqual(
            try reopened.disposition(forFrameAt: 2),
            .runBackend
        )
        let replayedFirst = try await store.loadCachedFrame(
            at: 0,
            using: reopened
        )
        let replayedSecond = try await store.loadCachedFrame(
            at: 1,
            using: reopened
        )
        XCTAssertEqual(replayedFirst, first)
        XCTAssertEqual(replayedSecond, second)
    }

    func testCommitAndReopenPreserveAuxiliaryAlphaPlaneByteAccounting()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let pixelFormat =
            kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar
        let pixelFormatFourCC = try R13CachedPixelFormat.fourCC(
            pixelFormat
        )
        let core = try fixture.makeCore(
            totalFrameCount: 1,
            pixelFormat: pixelFormatFourCC
        )
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: 4,
            height: 2,
            pixelFormat: pixelFormat
        )
        let frame = try R13NV12Frame(
            width: 4,
            height: 2,
            pixelFormat: pixelFormat,
            luma: Data(repeating: 0x20, count: counts.luma),
            chroma: Data(repeating: 0x40, count: counts.chroma),
            auxiliaryPlanes: counts.auxiliary.map {
                Data(repeating: 0x60, count: $0)
            }
        )
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        let plan = try await store.create(core)
        _ = try await store.commitProcessedFrame(
            frame,
            at: 0,
            using: plan
        )

        let reopened = try await store.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )
        let replayed = try await store.loadCachedFrame(
            at: 0,
            using: reopened
        )

        XCTAssertEqual(replayed, frame)
        XCTAssertEqual(replayed.auxiliaryPlanes.count, 1)
        XCTAssertEqual(
            replayed.tightRawData.count,
            counts.total
        )
    }

    func testRoutedCachePersistsExactDecisionsAndMarksOnlyFinalPrefixWarmup()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(
            totalFrameCount: 3,
            backendIdentity:
                R13ReleaseOrchestrationKind.automatic.backendID
        )
        let primary = try fixture.route(
            backendID: "test.restart.primary"
        )
        let fallback = try fixture.route(
            backendID: "test.restart.fallback"
        )
        let decisions = [
            R13ProductASHDecisionEvent(
                sequenceNumber: 0,
                selectedRouteIdentity: primary,
                reason: .initialSelection,
                fallbackHistory: [],
                processingPressureQ16: 4_096
            ),
            R13ProductASHDecisionEvent(
                sequenceNumber: 1,
                selectedRouteIdentity: fallback,
                reason: .fatalBackendFailover,
                fallbackHistory: [
                    try AppleUpscaleFallbackLink(
                        failedRoute: primary,
                        selectedRoute: fallback,
                        reasonCode: .backendFailed,
                        selectedFallbackOrdinal: 0
                    )
                ],
                processingPressureQ16: 32_768
            )
        ]
        let frames = [
            try fixture.frame(value: 10),
            try fixture.frame(value: 20)
        ]
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        var plan = try await store.create(core)
        for index in frames.indices {
            plan = try await store.commitProcessedFrame(
                frames[index],
                routingDecision: decisions[index],
                at: index,
                using: plan
            )
        }

        let reopened = try await store.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )
        let first = try await store.loadCachedFrameReplay(
            at: 0,
            using: reopened
        )
        let second = try await store.loadCachedFrameReplay(
            at: 1,
            using: reopened
        )

        XCTAssertEqual(first.frame, frames[0])
        XCTAssertEqual(first.routingDecision, decisions[0])
        XCTAssertFalse(first.isFinalCachedPrefixFrame)
        XCTAssertFalse(first.requiresBackendWarmup)
        XCTAssertEqual(second.frame, frames[1])
        XCTAssertEqual(second.routingDecision, decisions[1])
        XCTAssertTrue(second.isFinalCachedPrefixFrame)
        XCTAssertTrue(second.requiresBackendWarmup)
    }

    func testFullCacheRoutedReplayRequiresZeroBackendWarmup()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(
            totalFrameCount: 1,
            backendIdentity:
                R13ReleaseOrchestrationKind.quality.backendID
        )
        let decision = R13ProductASHDecisionEvent(
            sequenceNumber: 0,
            selectedRouteIdentity: try fixture.route(
                backendID: "test.restart.full-cache"
            ),
            reason: .initialSelection,
            fallbackHistory: [],
            processingPressureQ16: 8_192
        )
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 30),
            routingDecision: decision,
            at: 0,
            using: plan
        )

        let replay = try await store.loadCachedFrameReplay(
            at: 0,
            using: plan
        )

        XCTAssertEqual(replay.routingDecision, decision)
        XCTAssertTrue(replay.isFinalCachedPrefixFrame)
        XCTAssertFalse(replay.requiresBackendWarmup)
    }

    func testRoutedCommitRequiresDecisionAndDirectCommitRejectsOne()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let routedCore = try fixture.makeCore(
            jobID: "job-routed",
            totalFrameCount: 1,
            backendIdentity:
                R13ReleaseOrchestrationKind.fast.backendID
        )
        let directCore = try fixture.makeCore(
            jobID: "job-direct",
            totalFrameCount: 1
        )
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        let routedPlan = try await store.create(routedCore)
        let directPlan = try await store.create(directCore)
        let decision = R13ProductASHDecisionEvent(
            sequenceNumber: 0,
            selectedRouteIdentity: try fixture.route(
                backendID: "test.restart.direct-rejection"
            ),
            reason: .initialSelection,
            fallbackHistory: []
        )

        do {
            _ = try await store.commitProcessedFrame(
                fixture.frame(value: 40),
                at: 0,
                using: routedPlan
            )
            XCTFail("A routed cache record must bind its route decision.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .routingDecisionRequired(index: 0)
            )
        }
        do {
            _ = try await store.commitProcessedFrame(
                fixture.frame(value: 41),
                routingDecision: decision,
                at: 0,
                using: directPlan
            )
            XCTFail("A direct cache record must not claim routed evidence.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .unexpectedRoutingDecision(index: 0)
            )
        }
    }

    func testRoutedCommitRejectsInvalidPressureEvidence()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(
            totalFrameCount: 1,
            backendIdentity:
                R13ReleaseOrchestrationKind.automatic.backendID
        )
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        let plan = try await store.create(core)
        let decision = R13ProductASHDecisionEvent(
            sequenceNumber: 0,
            selectedRouteIdentity: try fixture.route(
                backendID: "test.restart.invalid-pressure"
            ),
            reason: .initialSelection,
            fallbackHistory: [],
            processingPressureQ16: R06ASHQ16.scale + 1
        )

        do {
            _ = try await store.commitProcessedFrame(
                fixture.frame(value: 50),
                routingDecision: decision,
                at: 0,
                using: plan
            )
            XCTFail("Out-of-range processing pressure must be rejected.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .invalidRoutingDecision(index: 0)
            )
        }
    }

    func testRouteAndPressureTamperingBreaksRecordChain()
        async throws {
        for tamper in [
            R13RestartRecordTamper.selectedBackendID,
            .processingPressure
        ] {
            let fixture = try R13RestartStoreFixture()
            defer { fixture.cleanup() }
            let core = try fixture.makeCore(
                jobID: "job-\(tamper.rawValue)",
                totalFrameCount: 1,
                backendIdentity:
                    R13ReleaseOrchestrationKind.automatic.backendID
            )
            let store = R13RestartJobStore(
                jobsRootURL: fixture.jobsRoot
            )
            var plan = try await store.create(core)
            plan = try await store.commitProcessedFrame(
                fixture.frame(value: 60),
                routingDecision: R13ProductASHDecisionEvent(
                    sequenceNumber: 0,
                    selectedRouteIdentity: try fixture.route(
                        backendID: "test.restart.tamper"
                    ),
                    reason: .initialSelection,
                    fallbackHistory: [],
                    processingPressureQ16: 1_024
                ),
                at: 0,
                using: plan
            )
            try fixture.tamperRecord(
                jobID: core.jobID,
                tamper: tamper
            )

            do {
                _ = try await R13RestartJobStore(
                    jobsRootURL: fixture.jobsRoot
                ).reopen(
                    jobID: core.jobID,
                    expecting: core,
                    observedSource: core.source
                )
                XCTFail("Tampered route evidence must break the chain.")
            } catch {
                XCTAssertEqual(
                    error as? R13RestartJobError,
                    .recordChainMismatch(sequence: 0)
                )
            }
        }
    }

    func testDirectSchemaOneAndTwoRecordsRemainReplayable()
        async throws {
        for schemaVersion in [1, 2] {
            let fixture = try R13RestartStoreFixture()
            defer { fixture.cleanup() }
            let core = try fixture.makeCore(
                jobID: "job-schema-\(schemaVersion)",
                totalFrameCount: 1
            )
            let expected = try fixture.frame(
                value: UInt8(70 + schemaVersion)
            )
            let store = R13RestartJobStore(
                jobsRootURL: fixture.jobsRoot
            )
            var plan = try await store.create(core)
            plan = try await store.commitProcessedFrame(
                expected,
                at: 0,
                using: plan
            )
            try fixture.rewriteRecordAsLegacy(
                jobID: core.jobID,
                schemaVersion: schemaVersion
            )

            let reopened = try await R13RestartJobStore(
                jobsRootURL: fixture.jobsRoot
            ).reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: core.source
            )
            let replayed = try await R13RestartJobStore(
                jobsRootURL: fixture.jobsRoot
            ).loadCachedFrame(
                at: 0,
                using: reopened
            )
            XCTAssertEqual(replayed, expected)
        }
    }

    func testLegacyRoutedRecordWithoutDecisionIsNotMisrepresentedAsContinuity()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(
            totalFrameCount: 1,
            backendIdentity:
                R13ReleaseOrchestrationKind.automatic.backendID
        )
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 80),
            routingDecision: R13ProductASHDecisionEvent(
                sequenceNumber: 0,
                selectedRouteIdentity: try fixture.route(
                    backendID: "test.restart.legacy-routed"
                ),
                reason: .initialSelection,
                fallbackHistory: []
            ),
            at: 0,
            using: plan
        )
        try fixture.rewriteRecordAsLegacy(
            jobID: core.jobID,
            schemaVersion: 2
        )

        do {
            _ = try await R13RestartJobStore(
                jobsRootURL: fixture.jobsRoot
            ).reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: core.source
            )
            XCTFail(
                "Legacy routed cache has no exact decision evidence."
            )
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .routingDecisionRequired(index: 0)
            )
        }
    }

    func testSchemaThreeRoutedCacheWithoutExactFallbackEvidenceIsRejected()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(
            totalFrameCount: 1,
            backendIdentity:
                R13ReleaseOrchestrationKind.automatic.backendID
        )
        let failedRoute = try fixture.route(
            backendID: "test.restart.schema3.failed"
        )
        let selectedRoute = try fixture.route(
            backendID: "test.restart.schema3.selected"
        )
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 81),
            routingDecision: R13ProductASHDecisionEvent(
                sequenceNumber: 0,
                selectedRouteIdentity: selectedRoute,
                reason: .fatalBackendFailover,
                fallbackHistory: [
                    try AppleUpscaleFallbackLink(
                        failedRoute: failedRoute,
                        selectedRoute: selectedRoute,
                        reasonCode: .backendUnavailable,
                        selectedFallbackOrdinal: 0
                    )
                ]
            ),
            at: 0,
            using: plan
        )
        try fixture.rewriteRoutedRecordAsSchemaThree(
            jobID: core.jobID
        )

        let legacyRecord = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(
                contentsOf: fixture.jobDirectory(
                    jobID: core.jobID
                ).appendingPathComponent("records/0.json")
            )
        )
        XCTAssertEqual(legacyRecord.schemaVersion, 3)
        XCTAssertNil(
            try XCTUnwrap(legacyRecord.routingDecision)
                .fallbackHistory,
            "A schema-three backend-ID list must not be upgraded into invented route/reason links."
        )

        do {
            _ = try await R13RestartJobStore(
                jobsRootURL: fixture.jobsRoot
            ).reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: core.source
            )
            XCTFail(
                "Recovery must reject routed cache that lacks exact per-hop fallback evidence."
            )
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .recordChainMismatch(sequence: 0)
            )
        }
    }

    func testUnchangedFullValidationReusesDescriptorPinnedSnapshots()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 3)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 10),
            at: 0,
            using: plan
        )
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 20),
            at: 1,
            using: plan
        )

        fileSystem.resetCounts()
        let firstValidatedCount = try await store.validateRecoverableJob(
            jobID: core.jobID
        )
        XCTAssertEqual(firstValidatedCount, 2)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 2)
        XCTAssertEqual(fileSystem.counts().snapshotComparisons, 0)

        fileSystem.resetCounts()
        let reusedValidatedCount = try await store.validateRecoverableJob(
            jobID: core.jobID
        )
        XCTAssertEqual(reusedValidatedCount, 2)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
        XCTAssertEqual(fileSystem.counts().snapshotComparisons, 6)

        fileSystem.resetCounts()
        let reopened = try await store.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 2)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
        XCTAssertEqual(fileSystem.counts().snapshotComparisons, 6)

        fileSystem.resetCounts()
        _ = try await store.loadCachedFrame(at: 0, using: reopened)
        XCTAssertEqual(
            fileSystem.counts().artifactContentReads,
            1,
            "Replay must continue to validate the selected frame payload."
        )
    }

    func testCachedValidationRejectsArtifactTamperBeforeReopen()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 31),
            at: 0,
            using: plan
        )
        _ = try await store.validateRecoverableJob(jobID: core.jobID)
        let artifactURL = try fixture.artifactURL(
            jobID: core.jobID,
            frameIndex: 0
        )
        var artifact = try Data(contentsOf: artifactURL)
        artifact[artifact.startIndex] ^= 0x01
        try artifact.write(to: artifactURL, options: .atomic)

        fileSystem.resetCounts()
        do {
            _ = try await store.reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: core.source
            )
            XCTFail("A changed artifact must invalidate cached evidence.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .cachedFrameCorrupt(index: 0)
            )
        }
        XCTAssertGreaterThan(fileSystem.counts().snapshotComparisons, 0)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 1)
    }

    func testSameContentArtifactReplacementForcesFullRevalidation()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 44),
            at: 0,
            using: plan
        )
        _ = try await store.validateRecoverableJob(jobID: core.jobID)
        let artifactURL = R13RestartPath.resolvingExistingAncestor(
            of: try fixture.artifactURL(
                jobID: core.jobID,
                frameIndex: 0
            )
        )
        let localFileSystem = R13LocalRestartFileSystem()
        let before = try XCTUnwrap(
            localFileSystem.readRegularFileWithSnapshot(
                artifactURL,
                maximumBytes: Int.max
            ).snapshot
        )
        let replacementURL = artifactURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try Data(contentsOf: artifactURL).write(to: replacementURL)
        try FileManager.default.removeItem(at: artifactURL)
        try FileManager.default.moveItem(
            at: replacementURL,
            to: artifactURL
        )
        let after = try XCTUnwrap(
            localFileSystem.readRegularFileWithSnapshot(
                artifactURL,
                maximumBytes: Int.max
            ).snapshot
        )
        XCTAssertNotEqual(before.fileID, after.fileID)

        fileSystem.resetCounts()
        let replacementValidatedCount =
            try await store.validateRecoverableJob(jobID: core.jobID)
        XCTAssertEqual(replacementValidatedCount, 1)
        XCTAssertGreaterThan(fileSystem.counts().snapshotComparisons, 0)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 1)

        fileSystem.resetCounts()
        let reusedReplacementCount =
            try await store.validateRecoverableJob(jobID: core.jobID)
        XCTAssertEqual(reusedReplacementCount, 1)
        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
    }

    func testSequentialCommitDoesNotReadPriorFrameArtifacts()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let fileSystem = R13CountingSnapshotFileSystem()
        let store = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 51),
            at: 0,
            using: plan
        )

        fileSystem.resetCounts()
        _ = try await store.commitProcessedFrame(
            fixture.frame(value: 52),
            at: 1,
            using: plan
        )

        XCTAssertEqual(fileSystem.counts().artifactContentReads, 0)
    }

    func testSourceDriftFailsBeforeWriterOrBackendCreation() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        _ = try await store.create(core)
        let drifted = try R13RestartSourceIdentity(
            sha256: String(repeating: "9", count: 64),
            byteCount: core.source.byteCount
        )
        var writerCreated = false
        var backendCalled = false

        do {
            _ = try await store.reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: drifted
            )
            writerCreated = true
            backendCalled = true
            XCTFail("Source drift must fail before downstream work.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .sourceDrift(expected: core.source, observed: drifted)
            )
        }
        XCTAssertFalse(writerCreated)
        XCTAssertFalse(backendCalled)
    }

    func testCachedFrameTamperFailsBeforeWriterOrBackendCreation() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 2)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await store.create(core)
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 8),
            at: 0,
            using: plan
        )
        let recordURL = fixture.jobDirectory(jobID: core.jobID)
            .appendingPathComponent("records/0.json")
        let record = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(contentsOf: recordURL)
        )
        let artifactURL = fixture.jobDirectory(jobID: core.jobID)
            .appendingPathComponent(record.artifact.relativePath)
        var artifact = try Data(contentsOf: artifactURL)
        artifact[artifact.index(before: artifact.endIndex)] ^= 0x01
        try artifact.write(to: artifactURL, options: .atomic)
        var writerCreated = false
        var backendCalled = false

        do {
            _ = try await store.reopen(
                jobID: core.jobID,
                expecting: core,
                observedSource: core.source
            )
            writerCreated = true
            backendCalled = true
            XCTFail("Tampered cache data must fail before downstream work.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .cachedFrameCorrupt(index: 0)
            )
        }
        XCTAssertFalse(writerCreated)
        XCTAssertFalse(backendCalled)
    }

    func testInterruptedCommitLeavesHeadAuthoritativeAndRetryable() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let fileSystem = R13FailingHeadFileSystem()
        let failingStore = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot,
            fileSystem: fileSystem
        )
        let initialPlan = try await failingStore.create(core)
        fileSystem.clearEvents()
        fileSystem.failNextHeadReplacement()

        do {
            _ = try await failingStore.commitProcessedFrame(
                fixture.frame(value: 44),
                at: 0,
                using: initialPlan
            )
            XCTFail("The injected head publication failure must surface.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .ioFailure(operation: "injected_head_replace")
            )
        }
        XCTAssertEqual(
            fileSystem.events().suffix(3),
            ["frame", "record", "head"]
        )

        let retryStore = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var reopened = try await retryStore.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 0)
        reopened = try await retryStore.commitProcessedFrame(
            fixture.frame(value: 44),
            at: 0,
            using: reopened
        )
        XCTAssertEqual(reopened.verifiedCachedPrefixCount, 1)
    }

    func testPrepublicationReceiptRequiresCompleteVerifiedCache() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await store.create(core)

        do {
            _ = try await store.preparePrepublicationReceipt(
                using: plan,
                observedSource: core.source,
                outputMediaSHA256: String(repeating: "f", count: 64),
                outputMediaByteCount: 100
            )
            XCTFail("Incomplete frame caches cannot authorize publication.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .incompleteJob(committed: 0, expected: 1)
            )
        }
        plan = try await store.commitProcessedFrame(
            fixture.frame(value: 12),
            at: 0,
            using: plan
        )
        let first = try await store.preparePrepublicationReceipt(
            using: plan,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "f", count: 64),
            outputMediaByteCount: 100
        )
        let second = try await store.preparePrepublicationReceipt(
            using: plan,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "f", count: 64),
            outputMediaByteCount: 100
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.writerStartFrameIndex, 0)
        XCTAssertEqual(first.partialMediaReusePolicy, .forbidden)
        XCTAssertEqual(first.frameCount, 1)
    }

    func testReopenClearsTentativeReceiptAndAllowsDifferentRetryReceipt()
        async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let core = try fixture.makeCore(totalFrameCount: 1)
        let firstStore = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        var plan = try await firstStore.create(core)
        plan = try await firstStore.commitProcessedFrame(
            fixture.frame(value: 21),
            at: 0,
            using: plan
        )
        let first = try await firstStore.preparePrepublicationReceipt(
            using: plan,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "a", count: 64),
            outputMediaByteCount: 100
        )
        let receiptURL = fixture.jobDirectory(jobID: core.jobID)
            .appendingPathComponent("prepublication-receipt-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))

        let relaunchedStore = R13RestartJobStore(
            jobsRootURL: fixture.jobsRoot
        )
        let reopened = try await relaunchedStore.reopen(
            jobID: core.jobID,
            expecting: core,
            observedSource: core.source
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: receiptURL.path)
        )
        let retry = try await relaunchedStore.preparePrepublicationReceipt(
            using: reopened,
            observedSource: core.source,
            outputMediaSHA256: String(repeating: "b", count: 64),
            outputMediaByteCount: 101
        )
        XCTAssertNotEqual(retry, first)
        XCTAssertEqual(
            retry.outputMediaSHA256,
            String(repeating: "b", count: 64)
        )
        XCTAssertEqual(retry.outputMediaByteCount, 101)
    }

    func testDiscardRemovesOnlyTheExactValidatedJobDirectory() async throws {
        let fixture = try R13RestartStoreFixture()
        defer { fixture.cleanup() }
        let firstCore = try fixture.makeCore(
            jobID: "job-first",
            totalFrameCount: 1
        )
        let secondCore = try fixture.makeCore(
            jobID: "job-second",
            totalFrameCount: 1
        )
        let store = R13RestartJobStore(jobsRootURL: fixture.jobsRoot)
        _ = try await store.create(firstCore)
        _ = try await store.create(secondCore)

        try await store.discard(jobID: firstCore.jobID)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(jobID: firstCore.jobID).path
            )
        )
        XCTAssertNoThrow(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.jobDirectory(jobID: secondCore.jobID).path
            )
        )
        _ = try await store.reopen(
            jobID: secondCore.jobID,
            expecting: secondCore,
            observedSource: secondCore.source
        )
    }
}

private struct R13RestartStoreFixture {
    let root: URL
    let jobsRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        jobsRoot = root.appendingPathComponent("Jobs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func makeCore(
        jobID: String = "job-restart",
        totalFrameCount: Int,
        backendIdentity: String = "r03.mps.lanczos",
        pixelFormat: String =
            R13RestartOutputIdentity.nv12VideoRangePixelFormat
    ) throws -> R13RestartJobCore {
        try R13RestartJobCore(
            jobID: jobID,
            source: R13RestartSourceIdentity(
                sha256: String(repeating: "1", count: 64),
                byteCount: 123
            ),
            processing: R13RestartProcessingIdentity(
                requestedMode: "deterministic",
                effectiveMode: "deterministic",
                routeIdentity: "scale_3_over_2",
                backendIdentity: backendIdentity,
                backendRevision: "1"
            ),
            output: R13RestartOutputIdentity(
                width: 4,
                height: 2,
                pixelFormat: pixelFormat,
                codec: "hevc",
                audioPolicy: "preserve"
            ),
            totalFrameCount: totalFrameCount
        )
    }

    func route(
        backendID: String
    ) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: backendID,
                backendRevision: "test.restart.backend.v1",
                modelAssetsIdentity: .notRequired
            ),
            configurationIdentity:
                "\(backendID).configuration.v1",
            policyIdentity: "test.restart.policy.v1",
            materialDecisionIdentity:
                "test.restart.material-decision.v1"
        )
    }

    func frame(value: UInt8) throws -> R13NV12Frame {
        try R13NV12Frame(
            width: 4,
            height: 2,
            luma: Data(repeating: value, count: 8),
            chroma: Data(repeating: value &+ 1, count: 4)
        )
    }

    func jobDirectory(jobID: String) -> URL {
        jobsRoot.appendingPathComponent(jobID, isDirectory: true)
    }

    func artifactURL(
        jobID: String,
        frameIndex: Int
    ) throws -> URL {
        let jobDirectory = jobDirectory(jobID: jobID)
        let record = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(
                contentsOf: jobDirectory.appendingPathComponent(
                    "records/\(frameIndex).json"
                )
            )
        )
        return jobDirectory.appendingPathComponent(
            record.artifact.relativePath
        )
    }

    func tamperRecord(
        jobID: String,
        tamper: R13RestartRecordTamper
    ) throws {
        let recordURL = jobDirectory(jobID: jobID)
            .appendingPathComponent("records/0.json")
        let data = try Data(contentsOf: recordURL)
        guard var object = try JSONSerialization
            .jsonObject(with: data) as? [String: Any],
              var decision = object["routingDecision"]
                as? [String: Any] else {
            throw R13RestartFixtureError.invalidRecord
        }
        switch tamper {
        case .selectedBackendID:
            guard var route = decision["selectedRouteIdentity"]
                    as? [String: Any] else {
                throw R13RestartFixtureError.invalidRecord
            }
            route["backendID"] =
                "test.restart.tampered-backend"
            decision["selectedRouteIdentity"] = route
        case .processingPressure:
            decision["processingPressureQ16"] = 2_048
        }
        object["routingDecision"] = decision
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: recordURL, options: .atomic)
    }

    func rewriteRecordAsLegacy(
        jobID: String,
        schemaVersion: Int
    ) throws {
        guard [1, 2].contains(schemaVersion) else {
            throw R13RestartFixtureError.invalidSchema
        }
        let directory = jobDirectory(jobID: jobID)
        let recordURL = directory.appendingPathComponent(
            "records/0.json"
        )
        let current = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(contentsOf: recordURL)
        )
        let artifact: R13CachedFrameArtifactIdentity
        if schemaVersion == 1 {
            let legacyRelativePath =
                "frames/\(current.sequence)-"
                + "\(current.artifact.artifactSHA256).r13nv12"
            artifact = try R13CachedFrameArtifactIdentity(
                relativePath: legacyRelativePath,
                encoding: current.artifact.encoding,
                artifactSHA256:
                    current.artifact.artifactSHA256,
                rawSHA256: current.artifact.rawSHA256,
                artifactByteCount:
                    current.artifact.artifactByteCount,
                rawByteCount:
                    current.artifact.rawByteCount,
                width: current.artifact.width,
                height: current.artifact.height
            )
            try FileManager.default.moveItem(
                at: directory.appendingPathComponent(
                    current.artifact.relativePath
                ),
                to: directory.appendingPathComponent(
                    legacyRelativePath
                )
            )
        } else {
            artifact = current.artifact
        }
        let payload = R13LegacyCommitRecordPayload(
            schemaVersion: schemaVersion,
            sequence: current.sequence,
            artifact: artifact,
            previousRecordSHA256:
                current.previousRecordSHA256
        )
        let digest = R13CryptoKitRestartDigest()
        let recordSHA256 = digest.sha256(
            try R13RestartCanonical.data(payload)
        )
        let legacyRecord = R13LegacyCommitRecord(
            schemaVersion: schemaVersion,
            sequence: current.sequence,
            artifact: artifact,
            previousRecordSHA256:
                current.previousRecordSHA256,
            recordSHA256: recordSHA256
        )
        try R13RestartCanonical.data(legacyRecord)
            .write(to: recordURL, options: .atomic)

        let headURL = directory.appendingPathComponent(
            "head-v1.json"
        )
        let head = try JSONDecoder().decode(
            R13RestartJobHead.self,
            from: Data(contentsOf: headURL)
        )
        let updatedHead = try R13RestartJobHead(
            coreSHA256: head.coreSHA256,
            committedFrameCount: head.committedFrameCount,
            headSHA256: recordSHA256
        )
        try R13RestartCanonical.data(updatedHead)
            .write(to: headURL, options: .atomic)
    }

    func rewriteRoutedRecordAsSchemaThree(
        jobID: String
    ) throws {
        let directory = jobDirectory(jobID: jobID)
        let recordURL = directory.appendingPathComponent(
            "records/0.json"
        )
        let current = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(contentsOf: recordURL)
        )
        let currentDecision = try XCTUnwrap(
            current.routingDecision
        )
        let event = try currentDecision.event()
        let legacyDecision = R13SchemaThreeRoutingDecisionRecord(
            sequenceNumber: currentDecision.sequenceNumber,
            selectedRouteIdentity:
                currentDecision.selectedRouteIdentity,
            reason: currentDecision.reason,
            failedBackendIDs: event.failedBackendIDs,
            processingPressureQ16:
                currentDecision.processingPressureQ16
        )
        let payload = R13SchemaThreeCommitRecordPayload(
            schemaVersion: 3,
            sequence: current.sequence,
            artifact: current.artifact,
            previousRecordSHA256:
                current.previousRecordSHA256,
            routingDecision: legacyDecision
        )
        let recordSHA256 = R13CryptoKitRestartDigest().sha256(
            try R13RestartCanonical.data(payload)
        )
        let record = R13SchemaThreeCommitRecord(
            schemaVersion: 3,
            sequence: current.sequence,
            artifact: current.artifact,
            previousRecordSHA256:
                current.previousRecordSHA256,
            routingDecision: legacyDecision,
            recordSHA256: recordSHA256
        )
        try R13RestartCanonical.data(record)
            .write(to: recordURL, options: .atomic)

        let headURL = directory.appendingPathComponent(
            "head-v1.json"
        )
        let head = try JSONDecoder().decode(
            R13RestartJobHead.self,
            from: Data(contentsOf: headURL)
        )
        let updatedHead = try R13RestartJobHead(
            coreSHA256: head.coreSHA256,
            committedFrameCount: head.committedFrameCount,
            headSHA256: recordSHA256
        )
        try R13RestartCanonical.data(updatedHead)
            .write(to: headURL, options: .atomic)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum R13RestartRecordTamper: String {
    case selectedBackendID = "selected-backend"
    case processingPressure = "processing-pressure"
}

private enum R13RestartFixtureError: Error {
    case invalidRecord
    case invalidSchema
}

private struct R13LegacyCommitRecordPayload: Codable {
    let schemaVersion: Int
    let sequence: Int
    let artifact: R13CachedFrameArtifactIdentity
    let previousRecordSHA256: String
}

private struct R13LegacyCommitRecord: Codable {
    let schemaVersion: Int
    let sequence: Int
    let artifact: R13CachedFrameArtifactIdentity
    let previousRecordSHA256: String
    let recordSHA256: String
}

private struct R13SchemaThreeRoutingDecisionRecord: Codable {
    let sequenceNumber: Int
    let selectedRouteIdentity: R13RestartRoutingRouteIdentity
    let reason: String
    let failedBackendIDs: [String]
    let processingPressureQ16: Int64
}

private struct R13SchemaThreeCommitRecordPayload: Codable {
    let schemaVersion: Int
    let sequence: Int
    let artifact: R13CachedFrameArtifactIdentity
    let previousRecordSHA256: String
    let routingDecision: R13SchemaThreeRoutingDecisionRecord?
}

private struct R13SchemaThreeCommitRecord: Codable {
    let schemaVersion: Int
    let sequence: Int
    let artifact: R13CachedFrameArtifactIdentity
    let previousRecordSHA256: String
    let routingDecision: R13SchemaThreeRoutingDecisionRecord?
    let recordSHA256: String
}

private func isRestartFrameArtifact(_ url: URL) -> Bool {
    switch url.pathExtension {
    case "r13nv12", "r13frame":
        true
    default:
        false
    }
}

private final class R13CountingSnapshotFileSystem:
    R13RestartFileSystem,
    @unchecked Sendable {
    struct Counts {
        var artifactContentReads = 0
        var snapshotComparisons = 0
    }

    private let base = R13LocalRestartFileSystem()
    private let lock = NSLock()
    private var observedCounts = Counts()

    func ensureDirectory(_ url: URL) throws {
        try base.ensureDirectory(url)
    }

    func createDirectoryExclusively(_ url: URL) throws {
        try base.createDirectoryExclusively(url)
    }

    func validateDirectory(_ url: URL) throws {
        try base.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        base.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        recordContentRead(at: url)
        return try base.readRegularFile(
            url,
            maximumBytes: maximumBytes
        )
    }

    func readRegularFileWithSnapshot(
        _ url: URL,
        maximumBytes: Int
    ) throws -> R13RestartRegularFileRead {
        recordContentRead(at: url)
        return try base.readRegularFileWithSnapshot(
            url,
            maximumBytes: maximumBytes
        )
    }

    func regularFile(
        _ url: URL,
        matches snapshot: R13RestartRegularFileSnapshot
    ) -> Bool {
        lock.withLock {
            observedCounts.snapshotComparisons += 1
        }
        return base.regularFile(url, matches: snapshot)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try base.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try base.replaceAtomically(data, at: url)
    }

    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try base.publishDirectoryAtomically(
            from: sourceURL,
            to: destinationURL
        )
    }

    func removeFile(_ url: URL) throws {
        try base.removeFile(url)
    }

    func removeDirectory(_ url: URL) throws {
        try base.removeDirectory(url)
    }

    func resetCounts() {
        lock.withLock {
            observedCounts = Counts()
        }
    }

    func counts() -> Counts {
        lock.withLock { observedCounts }
    }

    private func recordContentRead(at url: URL) {
        guard isRestartFrameArtifact(url) else { return }
        lock.withLock {
            observedCounts.artifactContentReads += 1
        }
    }
}

private final class R13FailingHeadFileSystem:
    R13RestartFileSystem,
    @unchecked Sendable {
    private let base = R13LocalRestartFileSystem()
    private let lock = NSLock()
    private var shouldFailHead = false
    private var observedEvents: [String] = []

    func ensureDirectory(_ url: URL) throws {
        try base.ensureDirectory(url)
    }

    func createDirectoryExclusively(_ url: URL) throws {
        try base.createDirectoryExclusively(url)
    }

    func validateDirectory(_ url: URL) throws {
        try base.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        base.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try base.readRegularFile(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        if isRestartFrameArtifact(url) {
            appendEvent("frame")
        } else if url.deletingLastPathComponent().lastPathComponent
                    == "records" {
            appendEvent("record")
        }
        try base.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        if url.lastPathComponent == "head-v1.json" {
            appendEvent("head")
            let fails = lock.withLock {
                defer { shouldFailHead = false }
                return shouldFailHead
            }
            if fails {
                throw R13RestartJobError.ioFailure(
                    operation: "injected_head_replace"
                )
            }
        }
        try base.replaceAtomically(data, at: url)
    }

    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try base.publishDirectoryAtomically(
            from: sourceURL,
            to: destinationURL
        )
    }

    func removeDirectory(_ url: URL) throws {
        try base.removeDirectory(url)
    }

    func removeFile(_ url: URL) throws {
        try base.removeFile(url)
    }

    func failNextHeadReplacement() {
        lock.withLock {
            shouldFailHead = true
        }
    }

    func clearEvents() {
        lock.withLock {
            observedEvents = []
        }
    }

    func events() -> [String] {
        lock.withLock { observedEvents }
    }

    private func appendEvent(_ event: String) {
        lock.withLock {
            observedEvents.append(event)
        }
    }
}

// swiftlint:enable file_length
