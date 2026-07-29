import AVFoundation
import AudioToolbox
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
                timing: timing,
                videoColor: .sdrBT709VideoRangeLeft
            )
        )

        XCTAssertEqual(result.frameCount, 1)
        XCTAssertEqual(result.resolution, VideoResolution(width: 64, height: 64))
        XCTAssertGreaterThan(result.lumaPayloadBytes, 0)
        XCTAssertGreaterThan(result.chromaPayloadBytes, 0)
        XCTAssertEqual(CMTimeCompare(result.duration, duration), 0)
    }

    func testVerifierRejectsVideoColorIdentityMismatch() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )
        let expected = OutputMediaVideoColorExpectation(
            colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
            transferFunction: "fixture-wrong-transfer-function",
            yCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            chromaLocation: kCMFormatDescriptionChromaLocation_Left as String
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.source,
                expectation: OutputMediaVerificationExpectation(
                    resolution: VideoResolution(width: 64, height: 64),
                    codec: .h264,
                    timing: try makeTimingSnapshot(
                        presentationTime: .zero,
                        duration: duration
                    ),
                    videoColor: expected
                )
            )
            XCTFail("Expected exact color verification failure.")
        } catch let error as OutputMediaVerificationError {
            guard case .videoColorMismatch(let field, let expected, let actual) = error else {
                return XCTFail("Unexpected verification error: \(error)")
            }
            XCTAssertEqual(field, "transfer function")
            XCTAssertEqual(expected, "fixture-wrong-transfer-function")
            XCTAssertEqual(
                actual,
                kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
            )
        }
    }

    func testVerifierRejectsCompressedFullRangeVideoWhenVideoRangeExpected() async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.source,
                expectation: OutputMediaVerificationExpectation(
                    resolution: VideoResolution(width: 64, height: 64),
                    codec: .h264,
                    timing: try makeTimingSnapshot(
                        presentationTime: .zero,
                        duration: duration
                    ),
                    videoColor: .sdrBT709VideoRangeLeft
                )
            )
            XCTFail("Expected compressed full-range video rejection.")
        } catch let error as OutputMediaVerificationError {
            guard case .videoColorMismatch(let field, let expected, let actual) = error else {
                return XCTFail("Unexpected verification error: \(error)")
            }
            XCTAssertEqual(field, "full range video")
            XCTAssertEqual(expected, "false")
            XCTAssertEqual(actual, "true")
        }
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

    func testNormalizerConformsAnamorphicSourceToSquarePixelPresentationGeometry()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let codedResolution = VideoResolution(width: 1_440, height: 1_080)
        let sourcePixelAspectRatio = try XCTUnwrap(
            VideoPixelAspectRatio(
                horizontalSpacing: 4,
                verticalSpacing: 3
            )
        )
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: codedResolution,
            duration: CMTime(value: 1, timescale: 30),
            pixelAspectRatio: sourcePixelAspectRatio
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )

        let source = try await pipeline.probe(url: fixture.source)

        XCTAssertEqual(source.resolution, .p1080)
        XCTAssertEqual(source.codedResolution, codedResolution)
        XCTAssertEqual(source.pixelAspectRatio, sourcePixelAspectRatio)

        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: .p2160,
                codec: .h264,
                preserveAudio: false
            )
        )
        defer { session.cancel() }
        let nextRecord = try await session.nextSourceFrame()
        let record = try XCTUnwrap(nextRecord)
        XCTAssertEqual(
            CVPixelBufferGetWidth(record.pixelBuffer),
            codedResolution.width
        )
        XCTAssertEqual(
            CVPixelBufferGetHeight(record.pixelBuffer),
            codedResolution.height
        )

        let normalized = try R13NV12FrameNormalizer().normalize(
            record.pixelBuffer,
            codedResolution: codedResolution,
            presentationResolution: .p1080,
            pixelAspectRatio: sourcePixelAspectRatio
        )
        try R03NV12Contract.validate(
            pixelBuffer: normalized,
            resolution: .p1080
        )
        XCTAssertEqual(
            try pixelAspectRatio(in: normalized),
            try XCTUnwrap(
                VideoPixelAspectRatio(
                    horizontalSpacing: 1,
                    verticalSpacing: 1
                )
            )
        )
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
