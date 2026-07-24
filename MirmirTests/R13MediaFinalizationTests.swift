import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class R13MediaFinalizationTests: XCTestCase {
    func testPreservedAudioCapacityAddsSourceBytesToEncodedVideo()
        throws {
        let sourceURL = URL(fileURLWithPath: "/source.mp4")
        let outputURL = URL(fileURLWithPath: "/output.mp4")
        let targetResolution = VideoResolution.p720
        let source = SourceProfile(
            url: sourceURL,
            resolution: .p720,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: true
        )
        let sourceByteCount: UInt64 = 4_096
        let omittedAudioJob = UpscaleJob(
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: targetResolution,
            codec: .h264,
            preserveAudio: false
        )
        let preservedAudioJob = UpscaleJob(
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: targetResolution,
            codec: .h264,
            preserveAudio: true
        )

        let omittedAudioBytes =
            try R13ReleaseHardeningRuntime.expectedOutputBytes(
                source: source,
                sourceByteCount: sourceByteCount,
                job: omittedAudioJob
            )
        let preservedAudioBytes =
            try R13ReleaseHardeningRuntime.expectedOutputBytes(
                source: source,
                sourceByteCount: sourceByteCount,
                job: preservedAudioJob
            )

        XCTAssertGreaterThan(
            omittedAudioBytes,
            sourceByteCount
        )
        XCTAssertEqual(
            preservedAudioBytes,
            omittedAudioBytes + sourceByteCount
        )
    }

    func testPreservedAudioCapacityAdditionRejectsOverflow() {
        let sourceURL = URL(fileURLWithPath: "/source.mp4")
        let targetResolution = VideoResolution.p720
        let source = SourceProfile(
            url: sourceURL,
            resolution: .p720,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: true
        )
        let job = UpscaleJob(
            inputURL: sourceURL,
            outputURL: URL(fileURLWithPath: "/output.mp4"),
            targetResolution: targetResolution,
            codec: .h264,
            preserveAudio: true
        )

        XCTAssertThrowsError(
            try R13ReleaseHardeningRuntime.expectedOutputBytes(
                source: source,
                sourceByteCount: UInt64.max,
                job: job
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseHardeningError,
                .arithmeticOverflow(field: "expected_output_bytes")
            )
        }
    }

    func testPreservedAudioCapacityRetainsSourceSizedVideoBound()
        throws {
        let sourceURL = URL(fileURLWithPath: "/source.mp4")
        let outputURL = URL(fileURLWithPath: "/output.mp4")
        let source = SourceProfile(
            url: sourceURL,
            resolution: .p720,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: true
        )
        let omittedAudioJob = UpscaleJob(
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p720,
            codec: .h264,
            preserveAudio: false
        )
        let preservedAudioJob = UpscaleJob(
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p720,
            codec: .h264,
            preserveAudio: true
        )
        let estimatedVideoBytes =
            try R13ReleaseHardeningRuntime.expectedOutputBytes(
                source: source,
                sourceByteCount: 0,
                job: omittedAudioJob
            )
        let sourceByteCount = estimatedVideoBytes + 1

        XCTAssertEqual(
            try R13ReleaseHardeningRuntime.expectedOutputBytes(
                source: source,
                sourceByteCount: sourceByteCount,
                job: preservedAudioJob
            ),
            sourceByteCount * 2
        )
    }

    func testBeforeReopenAndPrepublicationHooksRunInExactOrder() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let session = try await makeReadySession(fixture: fixture)
        let observation = R13FinalizationOrderObservation()

        try await session.finish(
            finalMetadata: [:],
            beforeReopen: {
                await observation.record("before_reopen")
            },
            validatingBeforePublish: {
                await observation.record("after_reopen_before_publish")
            }
        )

        let events = await observation.events
        XCTAssertEqual(
            events,
            ["before_reopen", "after_reopen_before_publish"]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
    }

    func testPrepublicationValidationRunsAfterReopenAndBeforePublication() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let session = try await makeReadySession(fixture: fixture)
        let gate = R13PrepublicationGate()

        let finishTask = Task {
            try await session.finish(
                finalMetadata: [:],
                validatingBeforePublish: {
                    await gate.suspend()
                }
            )
        }
        try await gate.waitUntilEntered()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let partials = fixture.recognizedTemporaryFiles()
        XCTAssertEqual(partials.count, 1)
        XCTAssertEqual(
            partials.first?.lastPathComponent,
            ".destination.mirmir-r13-prepublication-test.partial.mp4"
        )

        await gate.resume()
        try await finishTask.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testPrepublicationValidationFailureCleansPartialAndCannotPublish() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let session = try await makeReadySession(fixture: fixture)
        let observation = R13ValidationObservation()

        do {
            try await session.finish(
                finalMetadata: [:],
                validatingBeforePublish: {
                    await observation.recordInvocation()
                    throw R13InjectedValidationFailure()
                }
            )
            XCTFail("Expected injected prepublication validation failure.")
        } catch is R13InjectedValidationFailure {
            // Exact injected failure is preserved after cleanup.
        }

        let validationWasInvoked = await observation.wasInvoked
        XCTAssertTrue(validationWasInvoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
        XCTAssertNil(session.terminalCleanupError)
    }

    func testCancellationWhilePrepublicationValidationIsSuspendedCannotPublish() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let session = try await makeReadySession(fixture: fixture)
        let gate = R13PrepublicationGate()

        let finishTask = Task {
            try await session.finish(
                finalMetadata: [:],
                validatingBeforePublish: {
                    await gate.suspend()
                }
            )
        }
        try await gate.waitUntilEntered()
        session.cancel()
        await gate.resume()

        do {
            try await finishTask.value
            XCTFail("Expected cancellation at the prepublication boundary.")
        } catch is CancellationError {
            // Cancellation remains distinct from cleanup failure.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
        XCTAssertNil(session.terminalCleanupError)
    }

    func testRotatedSourcePublishesScaledPreferredTransform() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let sourceTransform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 32,
            ty: 0
        )
        let session = try await makeReadySession(
            fixture: fixture,
            sourceResolution: VideoResolution(width: 64, height: 32),
            outputResolution: VideoResolution(width: 128, height: 64),
            sourceTransform: sourceTransform
        )

        try await session.finish(finalMetadata: [:])

        let asset = AVURLAsset(url: fixture.destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let actual = try await track.load(.preferredTransform)
        XCTAssertEqual(actual.a, 0, accuracy: 0.000_001)
        XCTAssertEqual(actual.b, 1, accuracy: 0.000_001)
        XCTAssertEqual(actual.c, -1, accuracy: 0.000_001)
        XCTAssertEqual(actual.d, 0, accuracy: 0.000_001)
        XCTAssertEqual(actual.tx, 64, accuracy: 0.000_001)
        XCTAssertEqual(actual.ty, 0, accuracy: 0.000_001)
    }

    func testAACBeyondVideoEndpointIsPreservedWithoutExtendingVideo() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let videoURL = fixture.directory.appendingPathComponent("video.mp4")
        let audioURL = fixture.directory.appendingPathComponent("audio.m4a")
        let videoEnd = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: videoURL,
            resolution: VideoResolution(width: 64, height: 64),
            duration: videoEnd
        )
        try writeAACFixture(to: audioURL, frameCount: 4_800)
        try await muxVideoAndAAC(
            videoURL: videoURL,
            audioURL: audioURL,
            destinationURL: fixture.source
        )
        let expectedAAC = try await OutputMediaAACIdentityReader()
            .read(url: fixture.source)
        let expectedAudioEnd = CMTimeRangeGetEnd(
            expectedAAC.trackTimeRange
        )
        XCTAssertGreaterThan(
            CMTimeCompare(expectedAudioEnd, videoEnd),
            0
        )
        let session = try await makeReadySession(
            fixture: fixture,
            preserveAudio: true,
            materializeSource: false
        )

        try await session.finish(finalMetadata: [:])

        let actualAAC = try await OutputMediaAACIdentityReader()
            .read(url: fixture.destination)
        XCTAssertEqual(actualAAC, expectedAAC)
        let outputAsset = AVURLAsset(url: fixture.destination)
        let outputDuration = try await outputAsset.load(.duration)
        XCTAssertEqual(
            CMTimeCompare(outputDuration, expectedAudioEnd),
            0
        )
        let videoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let videoTimeRange = try await videoTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeRangeGetEnd(videoTimeRange),
                videoEnd
            ),
            0
        )
    }

    private func makeReadySession(
        fixture: MediaOutputFixture,
        sourceResolution: VideoResolution = VideoResolution(
            width: 64,
            height: 64
        ),
        outputResolution: VideoResolution = VideoResolution(
            width: 128,
            height: 128
        ),
        sourceTransform: CGAffineTransform = .identity,
        preserveAudio: Bool = false,
        materializeSource: Bool = true
    ) async throws -> any MediaSession {
        let duration = CMTime(value: 1, timescale: 30)
        if materializeSource {
            try await writeOneFrameVideo(
                to: fixture.source,
                resolution: sourceResolution,
                duration: duration,
                preferredTransform: sourceTransform
            )
        }
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: outputResolution,
                codec: .h264,
                preserveAudio: preserveAudio,
                transactionIdentifier: "r13-prepublication-test"
            )
        )
        let optionalRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(optionalRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)
        return session
    }
}

private struct R13InjectedValidationFailure: Error {}

private actor R13ValidationObservation {
    private(set) var wasInvoked = false

    func recordInvocation() {
        wasInvoked = true
    }
}

private actor R13FinalizationOrderObservation {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor R13PrepublicationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async throws {
        for _ in 0..<100_000 {
            if entered { return }
            await Task.yield()
        }
        throw MediaTestFailure.timeout
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
