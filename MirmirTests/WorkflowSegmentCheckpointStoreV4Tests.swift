import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import XCTest
#if canImport(Mirmir)
@testable import Mirmir
#endif

final class WorkflowSegmentCheckpointStoreV4Tests: XCTestCase {
    func testPauseResumePublishesAndRestoresOpaqueStateThenAssemblesEquivalentMovies()
        async throws {
        let fixture = try makeFixture()
        let segment0 = fixture.root.appendingPathComponent("source-0.mov")
        let segment1 = fixture.root.appendingPathComponent("source-1.mov")
        try await writeSegment(
            to: segment0,
            colors: [(16, 32, 48), (24, 40, 56)]
        )
        try await writeSegment(
            to: segment1,
            colors: [(80, 96, 112), (88, 104, 120)]
        )

        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store
        )
        let specification = try makeSpecification()
        try await enqueue(specification, into: coordinator)
        let probingClaim = try await coordinator.acquire(
            acquisition(
                jobID: nil,
                lease: "lease-initial",
                worker: "worker-initial",
                event: "event-claim-initial",
                command: "command-claim-initial",
                from: .queued,
                to: .probing,
                attempt: nil
            )
        )
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-planned",
                command: "command-planned",
                from: .probing,
                to: .planned,
                attempt: nil
            ),
            using: probingClaim
        )
        let firstAttempt = try WorkflowAttemptID("attempt-initial")
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-running-initial",
                command: "command-running-initial",
                from: .planned,
                to: .running,
                attempt: firstAttempt
            ),
            using: probingClaim
        )
        let runningClaim = try await coordinator.currentClaim(for: probingClaim)
        let planSHA = try ASHSHA256V4(digest(101))
        let firstEngine = CheckpointEngineProbeV4(
            checkpoint: Data("opaque-state-after-frame-1".utf8)
        )
        let store = try WorkflowSegmentCheckpointStoreV4(
            rootURL: fixture.store
        )
        let firstRequest = try publicationRequest(
            checkpoint: 0,
            sourceURL: segment0,
            existing: [],
            start: 0,
            end: 2,
            nextStart: 2,
            nextSample: 2
        )
        let firstPublication = try await store.publishBoundary(
            firstRequest,
            using: runningClaim,
            upscaler: firstEngine,
            planSHA256: planSHA
        )
        // Models process death after append-only artifact publication but
        // before the coordinator head is advanced. Replaying the exact
        // boundary must reopen, verify, and reuse all bytes.
        let replayedPublication = try await store.publishBoundary(
            firstRequest,
            using: runningClaim,
            upscaler: firstEngine,
            planSHA256: planSHA
        )
        XCTAssertEqual(replayedPublication, firstPublication)
        let firstCommit = try await coordinator.commitCheckpoint(
            firstPublication.draft,
            using: runningClaim
        )
        XCTAssertEqual(firstCommit.document.body.segments.count, 1)
        let measurementURL = fixture.store.appendingPathComponent(
            firstCommit.document.body.measurementHysteresis.relativePath
        )
        let immutableMeasurementV1 = try Data(contentsOf: measurementURL)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: immutableMeasurementV1
            ).schemaVersion,
            WorkflowSegmentArtifactPersistenceSchemaV4.immutableV1
        )
        let immutableReceiptHashesV1 =
            firstCommit.document.body.segments.map {
                $0.artifact.reopenReceiptSHA256
            }
            + [
                firstCommit.document.body.temporalHistory
                    .reopenReceiptSHA256,
                firstCommit.document.body.measurementHysteresis
                    .reopenReceiptSHA256
            ]
        let capturedOrdinal = await firstEngine.lastCheckpointOrdinal()
        XCTAssertEqual(capturedOrdinal, 1)

        _ = try await coordinator.transition(
            lifecycle(
                event: "event-pausing",
                command: "command-pausing",
                from: .running,
                to: .pausing,
                attempt: firstAttempt
            ),
            using: runningClaim
        )
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-paused",
                command: "command-paused",
                from: .pausing,
                to: .paused,
                attempt: firstAttempt
            ),
            using: runningClaim
        )

        let secondAttempt = try WorkflowAttemptID("attempt-resumed")
        let resumedClaim = try await coordinator.acquire(
            acquisition(
                jobID: specification.jobID,
                lease: "lease-resumed",
                worker: "worker-resumed",
                event: "event-claim-resumed",
                command: "command-claim-resumed",
                from: .paused,
                to: .running,
                attempt: secondAttempt
            )
        )
        let resumedStore = try WorkflowSegmentCheckpointStoreV4(
            rootURL: fixture.store
        )
        let resumedEngine = CheckpointEngineProbeV4(
            checkpoint: Data("opaque-state-after-frame-3".utf8)
        )
        _ = try await resumedStore.restoreCheckpoint(
            firstCommit.document,
            using: resumedClaim,
            into: resumedEngine,
            planSHA256: planSHA
        )
        let restoredCheckpoint = await resumedEngine.restoredCheckpoint()
        XCTAssertEqual(
            restoredCheckpoint,
            Data("opaque-state-after-frame-1".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: measurementURL),
            immutableMeasurementV1
        )
        XCTAssertEqual(
            firstCommit.document.body.segments.map {
                $0.artifact.reopenReceiptSHA256
            }
                + [
                    firstCommit.document.body.temporalHistory
                        .reopenReceiptSHA256,
                    firstCommit.document.body.measurementHysteresis
                        .reopenReceiptSHA256
                ],
            immutableReceiptHashesV1
        )

        let secondPublication = try await resumedStore.publishBoundary(
            publicationRequest(
                checkpoint: 1,
                sourceURL: segment1,
                existing: firstCommit.document.body.segments,
                start: 2,
                end: 4,
                nextStart: nil,
                nextSample: 4
            ),
            using: resumedClaim,
            upscaler: resumedEngine,
            planSHA256: planSHA
        )
        let secondCommit = try await coordinator.commitCheckpoint(
            secondPublication.draft,
            using: resumedClaim
        )
        let verification = try await resumedStore.verifyCheckpoint(
            secondCommit.document
        )
        XCTAssertEqual(verification.verifiedSegments.count, 2)
        XCTAssertEqual(secondCommit.document.body.segments.map(\.ordinal), [0, 1])

        // Run the same two boundaries without pausing in an independent
        // durable store. This makes the equivalence check compare genuinely
        // uninterrupted execution with the recovered execution above.
        let uninterruptedFixture = try makeFixture()
        let uninterruptedSetup = try await makeRunningCoordinator(
            fixture: uninterruptedFixture
        )
        let uninterruptedStore = try WorkflowSegmentCheckpointStoreV4(
            rootURL: uninterruptedFixture.store
        )
        let uninterruptedFirst = try await uninterruptedStore.publishBoundary(
            firstRequest,
            using: uninterruptedSetup.claim,
            temporalCheckpoint: Data("continuous-state-after-frame-1".utf8)
        )
        let uninterruptedFirstCommit = try await uninterruptedSetup.coordinator
            .commitCheckpoint(
                uninterruptedFirst.draft,
                using: uninterruptedSetup.claim
            )
        let uninterruptedSecond = try await uninterruptedStore.publishBoundary(
            publicationRequest(
                checkpoint: 1,
                sourceURL: segment1,
                existing: uninterruptedFirstCommit.document.body.segments,
                start: 2,
                end: 4,
                nextStart: nil,
                nextSample: 4
            ),
            using: uninterruptedSetup.claim,
            temporalCheckpoint: Data("continuous-state-after-frame-3".utf8)
        )
        let uninterruptedCommit = try await uninterruptedSetup.coordinator
            .commitCheckpoint(
                uninterruptedSecond.draft,
                using: uninterruptedSetup.claim
            )

        let uninterruptedURL = uninterruptedFixture.output.appendingPathComponent(
            "uninterrupted.mov"
        )
        let resumedURL = fixture.output.appendingPathComponent("resumed.mov")
        let assembler = AVFoundationSegmentAssemblerV4()
        let uninterrupted = try await assembler.assemble(
            AVFoundationSegmentAssemblyRequestV4(
                artifactRootURL: uninterruptedFixture.store,
                segments: uninterruptedCommit.document.body.segments,
                mediaTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 30
                ),
                outputTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 1
                ),
                destinationURL: uninterruptedURL
            )
        )
        let reopenedAssembler = AVFoundationSegmentAssemblerV4()
        let resumed = try await reopenedAssembler.assemble(
            AVFoundationSegmentAssemblyRequestV4(
                artifactRootURL: fixture.store,
                segments: secondCommit.document.body.segments,
                mediaTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 30
                ),
                outputTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 1
                ),
                destinationURL: resumedURL
            )
        )
        let equivalence = AVFoundationSegmentAssemblyEquivalenceV4(
            uninterrupted,
            resumed
        )
        XCTAssertTrue(equivalence.semanticIdentityIsIdentical)
        let uninterruptedDecoded = try await decodedVideoReceipt(
            uninterruptedURL
        )
        let resumedDecoded = try await decodedVideoReceipt(resumedURL)
        XCTAssertEqual(uninterruptedDecoded, resumedDecoded)
        XCTAssertTrue(uninterrupted.preservation.contains(.exactSampleTiming))
        XCTAssertTrue(
            uninterrupted.preservation.contains(.containerBytesNotContractual)
        )
        // MOV atom ordering and encoder/exporter metadata are not part of the
        // checkpoint contract. Equality is recorded when observed, but decoded
        // pixels, elementary payloads, and timing above are the release gate.
        _ = equivalence.containerBytesAreIdentical
    }

    func testTamperedOpaqueStateIsContainedBeforeBackendRestore() async throws {
        let fixture = try makeFixture()
        let source = fixture.root.appendingPathComponent("source.mov")
        try await writeSegment(to: source, colors: [(1, 2, 3), (4, 5, 6)])
        let setup = try await makeRunningCoordinator(fixture: fixture)
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)
        let publication = try await store.publishBoundary(
            publicationRequest(
                checkpoint: 0,
                sourceURL: source,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 2,
                nextSample: 2
            ),
            using: setup.claim,
            temporalCheckpoint: Data("valid-temporal-state".utf8)
        )
        let committed = try await setup.coordinator.commitCheckpoint(
            publication.draft,
            using: setup.claim
        )
        let temporalURL = fixture.store.appendingPathComponent(
            committed.document.body.temporalHistory.relativePath
        )
        let handle = try FileHandle(forWritingTo: temporalURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([0xff]))
        try handle.synchronize()
        try handle.close()

        let backend = CheckpointEngineProbeV4(checkpoint: Data("unused".utf8))
        do {
            _ = try await store.restoreCheckpoint(
                committed.document,
                using: setup.claim,
                into: backend,
                planSHA256: ASHSHA256V4(digest(101))
            )
            XCTFail("Tampered temporal state was restored.")
        } catch let error as WorkflowSegmentCheckpointStoreV4Error {
            XCTAssertEqual(
                error,
                .artifactHashMismatch(
                    committed.document.body.temporalHistory.relativePath
                )
            )
        }
        let unexpectedlyRestored = await backend.restoredCheckpoint()
        XCTAssertNil(unexpectedlyRestored)
    }

    func testConflictingRetryCannotReplacePublishedSegment() async throws {
        let fixture = try makeFixture()
        let source = fixture.root.appendingPathComponent("source.mov")
        try await writeSegment(to: source, colors: [(7, 8, 9), (10, 11, 12)])
        let setup = try await makeRunningCoordinator(fixture: fixture)
        let expectedRelative = "jobs/job-segment-v4/checkpoint-artifacts-v4/"
            + "segments/segment-00000000000000000000-segment-artifact-0.mov"
        let conflictURL = fixture.store.appendingPathComponent(expectedRelative)
        try FileManager.default.createDirectory(
            at: conflictURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreign = Data("foreign-owned-data".utf8)
        try foreign.write(to: conflictURL, options: .withoutOverwriting)

        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)
        do {
            _ = try await store.publishBoundary(
                publicationRequest(
                    checkpoint: 0,
                    sourceURL: source,
                    existing: [],
                    start: 0,
                    end: 2,
                    nextStart: 2,
                    nextSample: 2
                ),
                using: setup.claim,
                temporalCheckpoint: Data("state".utf8)
            )
            XCTFail("A conflicting artifact was replaced.")
        } catch let error as WorkflowSegmentCheckpointStoreV4Error {
            guard case .artifactConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: conflictURL), foreign)
    }

    func testSymlinkedArtifactDirectoryCannotEscapeTrustedStore() async throws {
        let fixture = try makeFixture()
        let source = fixture.root.appendingPathComponent("source.mov")
        try await writeSegment(to: source, colors: [(13, 14, 15), (16, 17, 18)])
        let setup = try await makeRunningCoordinator(fixture: fixture)

        let outside = fixture.root.appendingPathComponent(
            "outside-artifact-store",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let checkpointDirectory = fixture.store
            .appendingPathComponent("jobs/job-segment-v4")
            .appendingPathComponent("checkpoint-artifacts-v4")
        try FileManager.default.createSymbolicLink(
            at: checkpointDirectory,
            withDestinationURL: outside
        )

        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)
        do {
            _ = try await store.publishBoundary(
                publicationRequest(
                    checkpoint: 0,
                    sourceURL: source,
                    existing: [],
                    start: 0,
                    end: 2,
                    nextStart: 2,
                    nextSample: 2
                ),
                using: setup.claim,
                temporalCheckpoint: Data("state".utf8)
            )
            XCTFail("A symlinked checkpoint directory escaped the trusted root.")
        } catch let error as WorkflowSegmentCheckpointStoreV4Error {
            guard case .unsafeDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path),
            []
        )
    }

    func testBoundaryContractPersistsTrueGapAndRejectsInvalidTailStates()
        async throws {
        let fixture = try makeFixture()
        let firstSource = fixture.root.appendingPathComponent("gap-source-0.mov")
        let secondSource = fixture.root.appendingPathComponent("gap-source-1.mov")
        try await writeSegment(
            to: firstSource,
            colors: [(20, 30, 40), (21, 31, 41)]
        )
        try await writeSegment(
            to: secondSource,
            colors: [(50, 60, 70), (51, 61, 71)]
        )
        let setup = try await makeRunningCoordinator(fixture: fixture)
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)

        let first = try await store.publishBoundary(
            publicationRequest(
                checkpoint: 0,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 3,
                nextSample: 2
            ),
            using: setup.claim,
            temporalCheckpoint: Data("gap-state-0".utf8)
        )
        XCTAssertEqual(
            first.draft.segments[0].nextStartTime,
            try WorkflowMediaTimeV4(value: 3, timescale: 30)
        )
        _ = try await setup.coordinator.commitCheckpoint(
            first.draft,
            using: setup.claim
        )
        let specification = try makeSpecification()
        let loadedFirst = try await setup.coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        let reopenedFirst = try XCTUnwrap(loadedFirst)
        XCTAssertEqual(
            reopenedFirst.body.segments[0].nextStartTime,
            try WorkflowMediaTimeV4(value: 3, timescale: 30)
        )

        let invalidRequests = try [
            publicationRequest(
                checkpoint: 10,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 1,
                nextSample: 2
            ),
            publicationRequest(
                checkpoint: 11,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: nil,
                nextSample: 2
            ),
            publicationRequest(
                checkpoint: 12,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 3,
                nextSample: 4
            ),
            publicationRequest(
                checkpoint: 13,
                sourceURL: secondSource,
                existing: reopenedFirst.body.segments,
                start: 4,
                end: 6,
                nextStart: nil,
                nextSample: 4
            )
        ]
        for request in invalidRequests {
            do {
                _ = try await store.publishBoundary(
                    request,
                    using: setup.claim,
                    temporalCheckpoint: Data("must-not-publish".utf8)
                )
                XCTFail("An invalid persisted boundary was published.")
            } catch let error as WorkflowSegmentCheckpointStoreV4Error {
                XCTAssertEqual(error, .invalidSegmentSequence)
            }
        }

        let terminal = try await store.publishBoundary(
            publicationRequest(
                checkpoint: 1,
                sourceURL: secondSource,
                existing: reopenedFirst.body.segments,
                start: 3,
                end: 5,
                nextStart: nil,
                nextSample: 4
            ),
            using: setup.claim,
            temporalCheckpoint: Data("gap-state-1".utf8)
        )
        XCTAssertEqual(
            terminal.draft.segments.map(\.startTime.value),
            [0, 3]
        )
        XCTAssertEqual(
            terminal.draft.segments.map(\.endTimeExclusive.value),
            [2, 5]
        )
        XCTAssertNil(terminal.draft.segments.last?.nextStartTime)
        _ = try await setup.coordinator.commitCheckpoint(
            terminal.draft,
            using: setup.claim
        )
        let loadedTerminal = try await setup.coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        let reopenedTerminal = try XCTUnwrap(loadedTerminal)
        XCTAssertEqual(
            reopenedTerminal.body.segments.map(\.nextStartTime?.value),
            [3, nil]
        )

        let assembledURL = fixture.output.appendingPathComponent(
            "dynamic-gap-assembled.mov"
        )
        let assembly = try await AVFoundationSegmentAssemblerV4().assemble(
            AVFoundationSegmentAssemblyRequestV4(
                artifactRootURL: fixture.store,
                segments: reopenedTerminal.body.segments,
                mediaTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 30
                ),
                outputTimelineStart: try WorkflowMediaTimeV4(
                    value: 2,
                    timescale: 30
                ),
                destinationURL: assembledURL
            )
        )
        XCTAssertEqual(assembly.segmentCount, 2)
        XCTAssertEqual(
            CMTimeCompare(
                CMTime(
                    value: assembly.outputIdentity.duration.value,
                    timescale: assembly.outputIdentity.duration.timescale
                ),
                CMTime(value: 7, timescale: 30)
            ),
            0
        )
        let assembledAsset = AVURLAsset(
            url: assembledURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let assembledVideoTracks = try await assembledAsset.loadTracks(
            withMediaType: .video
        )
        let assembledVideoTrack = try XCTUnwrap(assembledVideoTracks.first)
        let assembledTrackRange = try await assembledVideoTrack.load(
            .timeRange
        )
        XCTAssertEqual(
            CMTimeCompare(
                assembledTrackRange.start,
                .zero
            ),
            0
        )
        let trackSegments = try await assembledVideoTrack.load(.segments)
        XCTAssertEqual(trackSegments.count, 4)
        let expectedTargetEdits: [
            (isEmpty: Bool, start: Int64, duration: Int64)
        ] = [
            (true, 0, 2),
            (false, 2, 2),
            (true, 4, 1),
            (false, 5, 2)
        ]
        for (actual, expected) in zip(trackSegments, expectedTargetEdits) {
            XCTAssertEqual(actual.isEmpty, expected.isEmpty)
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.target.start,
                    CMTime(value: expected.start, timescale: 30)
                ),
                0
            )
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.target.duration,
                    CMTime(value: expected.duration, timescale: 30)
                ),
                0
            )
        }
        let mediaEdits = trackSegments.filter { !$0.isEmpty }
        XCTAssertEqual(mediaEdits.count, 2)
        let expectedSourceEdits: [(start: Int64, duration: Int64)] = [
            (0, 2),
            (2, 2)
        ]
        for (actual, expected) in zip(mediaEdits, expectedSourceEdits) {
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.source.start,
                    CMTime(value: expected.start, timescale: 30)
                ),
                0
            )
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.source.duration,
                    CMTime(value: expected.duration, timescale: 30)
                ),
                0
            )
        }
        let presentationTimes = try await videoConcreteOutputPresentationTimes(
            assembledURL
        )
        XCTAssertEqual(presentationTimes.count, 4)
        for (actual, expected) in zip(presentationTimes, [2, 3, 5, 6]) {
            XCTAssertEqual(
                CMTimeCompare(
                    actual,
                    CMTime(value: Int64(expected), timescale: 30)
                ),
                0
            )
        }
    }
}

private actor CheckpointEngineProbeV4:
    PreparedCheckpointableTemporalFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes = PixelBufferAttributes()
    nonisolated let destinationPixelBufferAttributes = PixelBufferAttributes()
    nonisolated let actualBackendID = UpscaleBackendID.mirmirDeterministicCPU
    nonisolated let maximumOutputFramesPerInput = 1

    private let checkpoint: Data
    private var restored: Data?
    private var checkpointOrdinal: Int64?

    init(checkpoint: Data) {
        self.checkpoint = checkpoint
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {}

    func processTemporal(
        source: FramePixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming
    ) async throws -> [TemporalOutputFrame] {
        []
    }

    func finish() async throws {}

    func makeTemporalCheckpoint(
        planSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64
    ) async throws -> Data {
        checkpointOrdinal = lastCompletedInputOrdinal
        return checkpoint
    }

    func restoreTemporalCheckpoint(
        _ data: Data,
        planSHA256: ASHSHA256V4
    ) async throws {
        restored = data
    }

    func restoredCheckpoint() -> Data? { restored }
    func lastCheckpointOrdinal() -> Int64? { checkpointOrdinal }
}

private struct SegmentCheckpointFixtureV4 {
    let root: URL
    let store: URL
    let output: URL
}

private extension WorkflowSegmentCheckpointStoreV4Tests {
    func makeFixture() throws -> SegmentCheckpointFixtureV4 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "segment-checkpoint-v4-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = root.appendingPathComponent("store", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SegmentCheckpointFixtureV4(root: root, store: store, output: output)
    }

    func makeRunningCoordinator(
        fixture: SegmentCheckpointFixtureV4
    ) async throws -> (
        coordinator: WorkflowDurableCoordinatorV4,
        claim: WorkflowDispatchClaimV4
    ) {
        let coordinator = try WorkflowDurableCoordinatorV4(rootURL: fixture.store)
        let specification = try makeSpecification()
        try await enqueue(specification, into: coordinator)
        let probing = try await coordinator.acquire(
            acquisition(
                jobID: nil,
                lease: "lease-fixture",
                worker: "worker-fixture",
                event: "event-claim-fixture",
                command: "command-claim-fixture",
                from: .queued,
                to: .probing,
                attempt: nil
            )
        )
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-planned-fixture",
                command: "command-planned-fixture",
                from: .probing,
                to: .planned,
                attempt: nil
            ),
            using: probing
        )
        let attempt = try WorkflowAttemptID("attempt-fixture")
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-running-fixture",
                command: "command-running-fixture",
                from: .planned,
                to: .running,
                attempt: attempt
            ),
            using: probing
        )
        return (
            coordinator,
            try await coordinator.currentClaim(for: probing)
        )
    }

    func publicationRequest(
        checkpoint: Int,
        sourceURL: URL,
        existing: [WorkflowSegmentCheckpointV4],
        start: Int64,
        end: Int64,
        nextStart: Int64?,
        nextSample: UInt64
    ) throws -> WorkflowSegmentCheckpointPublicationRequestV4 {
        try WorkflowSegmentCheckpointPublicationRequestV4(
            checkpointID: WorkflowCheckpointIDV4("checkpoint-\(checkpoint)"),
            segmentArtifactID: WorkflowArtifactIDV4(
                "segment-artifact-\(checkpoint)"
            ),
            temporalArtifactID: WorkflowArtifactIDV4(
                "temporal-artifact-\(checkpoint)"
            ),
            measurementArtifactID: WorkflowArtifactIDV4(
                "measurement-artifact-\(checkpoint)"
            ),
            sourceSegmentURL: sourceURL,
            existingSegments: existing,
            startTime: WorkflowMediaTimeV4(value: start, timescale: 30),
            endTimeExclusive: WorkflowMediaTimeV4(value: end, timescale: 30),
            nextStartTime: try nextStart.map {
                try WorkflowMediaTimeV4(value: $0, timescale: 30)
            },
            codecSettingsHash: WorkflowOutputContractID(digest(9)),
            trackProgress: [
                WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: nextSample,
                    nextOutputSampleIndex: nextSample,
                    lastInputTime: WorkflowMediaTimeV4(
                        value: Int64(nextSample - 1),
                        timescale: 30
                    ),
                    lastOutputTime: WorkflowMediaTimeV4(
                        value: Int64(nextSample - 1),
                        timescale: 30
                    ),
                    isComplete: nextSample == 4
                )
            ],
            committedAt: WorkflowSystemWallClockV4().now(),
            lastCompletedInputOrdinal: Int64(nextSample - 1)
        )
    }

    func makeSpecification() throws -> WorkflowJobSpecification {
        let sourceBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("source-bookmark-segment-v4"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(1))
        )
        let outputBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("output-bookmark-segment-v4"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(2))
        )
        let runtime = WorkflowRuntimeBinding(
            id: try WorkflowRuntimeBindingID(digest(3)),
            runtimeManifestID: try WorkflowRuntimeManifestID(digest(4)),
            planID: try WorkflowPlanID(digest(5)),
            backendID: try WorkflowBackendID("backend-v4"),
            backendRevisionID: try WorkflowBackendRevisionID("backend-v4-p06"),
            mediaContractID: try WorkflowMediaContractID(digest(6))
        )
        return WorkflowJobSpecification(
            jobID: try WorkflowJobID("job-segment-v4"),
            requestID: try WorkflowRequestID(digest(7)),
            source: WorkflowSourceSpecification(
                identityID: try WorkflowSourceIdentityID(digest(8)),
                bookmark: sourceBookmark
            ),
            output: WorkflowOutputSpecification(
                contractID: try WorkflowOutputContractID(digest(9)),
                directoryBookmark: outputBookmark,
                fileName: try WorkflowOutputFileName("assembled.mov")
            ),
            runtimeBinding: runtime
        )
    }

    func enqueue(
        _ specification: WorkflowJobSpecification,
        into coordinator: WorkflowDurableCoordinatorV4
    ) async throws {
        _ = try await coordinator.append(
            WorkflowEventDraft(
                eventID: try WorkflowEventID("event-enqueue-segment-v4"),
                commandID: try WorkflowCommandID("command-enqueue-segment-v4"),
                scope: .job(specification.jobID),
                jobBinding: specification.binding,
                attemptID: nil,
                event: .jobEnqueued(specification)
            )
        )
    }

    func acquisition(
        jobID: WorkflowJobID?,
        lease: String,
        worker: String,
        event: String,
        command: String,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle,
        attempt: WorkflowAttemptID?
    ) throws -> WorkflowLeaseAcquisitionRequestV4 {
        try WorkflowLeaseAcquisitionRequestV4(
            jobID: jobID,
            leaseID: WorkflowLeaseIDV4(lease),
            workerID: WorkflowWorkerIDV4(worker),
            eventID: WorkflowEventID(event),
            commandID: WorkflowCommandID(command),
            expectedLifecycle: from,
            targetLifecycle: to,
            attemptID: attempt,
            duration: WorkflowLeaseIntervalV4(
                nanoseconds: 60_000_000_000
            )
        )
    }

    func lifecycle(
        event: String,
        command: String,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle,
        attempt: WorkflowAttemptID?
    ) throws -> WorkflowLifecycleCommandV4 {
        try WorkflowLifecycleCommandV4(
            eventID: WorkflowEventID(event),
            commandID: WorkflowCommandID(command),
            from: from,
            to: to,
            attemptID: attempt
        )
    }

    func writeSegment(
        to url: URL,
        colors: [(UInt8, UInt8, UInt8)]
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: 1,
                    AVVideoAverageBitRateKey: 200_000,
                    AVVideoExpectedSourceFrameRateKey: 30
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        guard writer.canAdd(input) else {
            throw AVFoundationSegmentV4Error.exportUnavailable
        }
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .commonIdentifierTitle
        metadata.value = "Mirmir deterministic segment" as NSString
        writer.metadata = [metadata]
        writer.add(input)
        guard writer.startWriting() else {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: writer.error)
            )
        }
        writer.startSession(atSourceTime: .zero)
        for (index, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else {
                throw AVFoundationSegmentV4Error.exportUnavailable
            }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &optional
            ) == kCVReturnSuccess,
            let buffer = optional else {
                throw AVFoundationSegmentV4Error.exportUnavailable
            }
            fill(buffer, color: color)
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: Int64(index), timescale: 30)
            ) else {
                throw AVFoundationSegmentV4Error.exportFailed(
                    String(describing: writer.error)
                )
            }
        }
        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(value: Int64(colors.count), timescale: 30)
        )
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: writer.error)
            )
        }
    }

    func fill(
        _ buffer: CVPixelBuffer,
        color: (UInt8, UInt8, UInt8)
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        for row in 0 ..< height {
            let bytes = base.advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                bytes[column * 4] = color.2
                bytes[column * 4 + 1] = color.1
                bytes[column * 4 + 2] = color.0
                bytes[column * 4 + 3] = 255
            }
        }
    }

    func decodedVideoReceipt(_ url: URL) async throws -> String {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AVFoundationSegmentV4Error.unreadableAsset("missing video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        guard reader.canAdd(output) else {
            throw AVFoundationSegmentV4Error.unreadableAsset("decode rejected")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        var hasher = SHA256()
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else {
                throw AVFoundationSegmentV4Error.unreadableAsset("missing image")
            }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(image) else {
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                throw AVFoundationSegmentV4Error.unreadableAsset("missing pixels")
            }
            let byteCount = CVPixelBufferGetBytesPerRow(image)
                * CVPixelBufferGetHeight(image)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: base,
                count: byteCount
            ))
            for time in [
                CMSampleBufferGetPresentationTimeStamp(sample),
                CMSampleBufferGetDuration(sample)
            ] {
                var value = time.value.bigEndian
                var timescale = time.timescale.bigEndian
                withUnsafeBytes(of: &value) {
                    hasher.update(bufferPointer: $0)
                }
                withUnsafeBytes(of: &timescale) {
                    hasher.update(bufferPointer: $0)
                }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        guard reader.status == .completed else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func videoConcreteOutputPresentationTimes(
        _ url: URL
    ) async throws -> [CMTime] {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let track = try await asset.loadTracks(
            withMediaType: .video
        ).first else {
            throw AVFoundationSegmentV4Error.unreadableAsset("missing video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                "sample timing read rejected"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            guard time.isNumeric,
                  !time.flags.contains(.hasBeenRounded) else {
                throw AVFoundationSegmentV4Error.assembledTimingMismatch
            }
            times.append(time)
        }
        guard reader.status == .completed else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        return times
    }
}

private func digest(_ value: Int) -> String {
    String(format: "%064llx", value)
}
