import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class OutputMediaVerifierTests: XCTestCase {
    func testVerifierReopensDecodesAndChecksOneFrameNV12Output() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let timing = try makeTimingSnapshot(
            presentationTime: .zero,
            duration: duration
        )

        let result = try await OutputMediaVerifier().verify(
            url: fixture.source,
            expectation: OutputMediaVerificationExpectation(
                resolution: VideoResolution(width: 64, height: 64),
                codec: .h264,
                timing: timing
            )
        )

        XCTAssertEqual(result.frameCount, 1)
        XCTAssertEqual(result.resolution, VideoResolution(width: 64, height: 64))
        XCTAssertGreaterThan(result.lumaPayloadBytes, 0)
        XCTAssertGreaterThan(result.chromaPayloadBytes, 0)
        XCTAssertEqual(CMTimeCompare(result.duration, duration), 0)
    }

    func testSessionEmbedsAndReopensExactFinalASHIdentity() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let staticMetadata = [
            "com.mirmir.ash.configuration-id": "fixture-configuration",
            "com.mirmir.ash.release-manifest-sha256": String(repeating: "a", count: 64)
        ]
        let template = staticMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": "0"
        ]) { _, final in final }
        let finalMetadata = staticMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": "7"
        ]) { _, final in final }
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: template
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        try await session.finish(finalMetadata: finalMetadata)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        _ = try await OutputMediaVerifier().verify(
            url: fixture.destination,
            expectation: OutputMediaVerificationExpectation(
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                timing: try makeTimingSnapshot(
                    presentationTime: record.presentationTime,
                    duration: record.duration
                ),
                timedMetadata: finalMetadata
            )
        )
    }

    func testSessionRejectsFinalASHIdentityKeyDriftWithoutPublishing() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false,
                timedMetadataTemplate: [
                    "com.mirmir.ash.numerical-fallback-count": "0"
                ]
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        do {
            try await session.finish(finalMetadata: [
                "com.mirmir.ash.unexpected": "1"
            ])
            XCTFail("Expected final ASH identity key-closure rejection.")
        } catch let error as MediaPipelineError {
            guard case .outputMetadataMismatch = error else {
                return XCTFail("Unexpected media pipeline error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testVerifierRejectsExactPTSMismatch() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let mismatchedTiming = try makeTimingSnapshot(
            presentationTime: CMTime(value: 1, timescale: 600),
            duration: duration
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.source,
                expectation: OutputMediaVerificationExpectation(
                    resolution: VideoResolution(width: 64, height: 64),
                    codec: .h264,
                    timing: mismatchedTiming
                )
            )
            XCTFail("Expected exact PTS verification failure.")
        } catch let error as OutputMediaVerificationError {
            guard case .presentationTimeMismatch(let frameIndex, _, _) = error else {
                return XCTFail("Unexpected verification error: \(error)")
            }
            XCTAssertEqual(frameIndex, 0)
        }
    }

    func testVerificationFailureRemovesPartialAndDoesNotPublish() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            outputVerifier: RejectingOutputMediaVerifier()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: VideoResolution(width: 128, height: 128),
                codec: .h264,
                preserveAudio: false
            )
        )
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        do {
            try await session.finish()
            XCTFail("Expected injected reopen verification failure.")
        } catch let error as MediaPipelineError {
            guard case .outputVerificationFailed = error else {
                return XCTFail("Unexpected pipeline error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
        XCTAssertNil(session.terminalCleanupError)
    }

    func testCancellationDuringVerificationCannotPublish() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let verifier = SuspendingOutputMediaVerifier()
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            outputVerifier: verifier
        )
        let source = try await pipeline.probe(url: fixture.source)
        let outputProfile = OutputProfile(
            url: fixture.destination,
            resolution: VideoResolution(width: 128, height: 128),
            codec: .h264,
            preserveAudio: false
        )
        let session = try await pipeline.beginSession(source: source, output: outputProfile)
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        let finishTask = Task { try await session.finish() }
        try await verifier.waitUntilStarted()
        session.cancel()
        verifier.resumeSuccessfully()

        do {
            try await finishTask.value
            XCTFail("Expected cancellation while reopen verification was suspended.")
        } catch is CancellationError {
            // Expected cancellation remains distinct from cleanup failure.
        }
        XCTAssertNil(session.terminalCleanupError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testOneFrameDirect1080pTo2160pMediaRoutePublishesVerifiedOutput() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: .p1080,
            duration: duration
        )
        let pipeline = AVFoundationMediaPipeline(metal: NoopMetalRenderingService())
        let source = try await pipeline.probe(url: fixture.source)
        let outputProfile = OutputProfile(
            url: fixture.destination,
            resolution: .p2160,
            codec: .h264,
            preserveAudio: false
        )
        let session = try await pipeline.beginSession(source: source, output: outputProfile)
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        let output = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
        try fillNV12(output)
        try await session.appendOutput(pixelBuffer: output, timing: record.timing)
        let endOfStream = try await session.nextSourceFrame()
        XCTAssertNil(endOfStream)

        try await session.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
        XCTAssertNil(session.terminalCleanupError)
        let timing = try makeTimingSnapshot(
            presentationTime: record.presentationTime,
            duration: record.duration
        )
        let verification = try await OutputMediaVerifier().verify(
            url: fixture.destination,
            expectation: OutputMediaVerificationExpectation(
                resolution: .p2160,
                codec: .h264,
                timing: timing
            )
        )
        XCTAssertEqual(verification.frameCount, 1)
        XCTAssertGreaterThan(verification.lumaPayloadBytes, 0)
        XCTAssertGreaterThan(verification.chromaPayloadBytes, 0)
    }
}
