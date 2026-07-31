import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

// Exact media verification scenarios share one media fixture contract.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class OutputMediaVerifierTests: XCTestCase {
    func testUnsupportedAudioFormatGuidanceNamesShippingExactCodecs() {
        XCTAssertEqual(
            MediaPipelineError.unsupportedAudioFormat("Opus").description,
            "Audio preservation does not support source format Opus; "
                + "exact passthrough accepts AAC, Apple Lossless, and "
                + "supported interleaved Linear PCM."
        )
    }

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

    func testVerifierRejectsNonProgressiveScanExpectation()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let duration = CMTime(value: 1, timescale: 30)
        try await writeOneFrameVideo(
            to: fixture.source,
            resolution: VideoResolution(width: 64, height: 64),
            duration: duration
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.source,
                expectation: OutputMediaVerificationExpectation(
                    resolution: VideoResolution(
                        width: 64,
                        height: 64
                    ),
                    codec: .h264,
                    timing: try makeTimingSnapshot(
                        presentationTime: .zero,
                        duration: duration
                    ),
                    scanStructure: .interlacedTopFieldFirst
                )
            )
            XCTFail("Expected scan-structure verification failure.")
        } catch let error as OutputMediaVerificationError {
            guard case .scanStructureMismatch(
                let expected,
                let actual
            ) = error else {
                return XCTFail(
                    "Unexpected verification error: \(error)"
                )
            }
            XCTAssertEqual(expected, .interlacedTopFieldFirst)
            XCTAssertEqual(actual, .progressive)
        }
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

    func testMixedTimeScaleEditBoundaryPublishesExactTrailingDuration()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let sourceResolution = VideoResolution(width: 64, height: 64)
        let outputResolution = VideoResolution(width: 128, height: 128)
        let sourceEndTime = CMTime(value: 11_262, timescale: 90_000)
        let expectedLastDuration = CMTime(
            value: 15_018,
            timescale: 360_000
        )
        try await writeMixedTimeScaleEditBoundaryVideo(
            to: fixture.source,
            resolution: sourceResolution
        )
        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .video
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceNaturalTimeScale = try await sourceTrack.load(
            .naturalTimeScale
        )
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        XCTAssertEqual(sourceNaturalTimeScale, 24_000)
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeRangeGetEnd(sourceTimeRange),
                sourceEndTime
            ),
            0
        )

        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: outputResolution,
                codec: .h264,
                preserveAudio: false
            )
        )
        defer { session.cancel() }
        var timings: [FrameTiming] = []
        while let record = try await session.nextSourceFrame() {
            let output = try PixelBufferBridge.dequeue(
                from: session.outputPixelBufferPool
            )
            try fillNV12(output)
            try await session.appendOutput(
                pixelBuffer: output,
                timing: record.timing
            )
            timings.append(record.timing)
        }
        XCTAssertEqual(timings.count, 3)
        let finalTiming = try XCTUnwrap(timings.last)
        XCTAssertEqual(
            CMTimeCompare(finalTiming.duration, expectedLastDuration),
            0
        )

        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let outputTrack = try XCTUnwrap(outputTracks.first)
        let outputNaturalTimeScale = try await outputTrack.load(
            .naturalTimeScale
        )
        let outputTimeRange = try await outputTrack.load(.timeRange)
        XCTAssertEqual(outputNaturalTimeScale, 120_000)
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeRangeGetEnd(outputTimeRange),
                sourceEndTime
            ),
            0
        )

        var timingLedger = FrameTimingLedger()
        for timing in timings {
            try timingLedger.append(timing)
        }
        let verification = try await OutputMediaVerifier().verify(
            url: fixture.destination,
            expectation: OutputMediaVerificationExpectation(
                resolution: outputResolution,
                codec: .h264,
                timing: timingLedger.snapshot
            )
        )
        XCTAssertEqual(verification.frameCount, 3)
    }

    func testCompressedPassthroughMuxPreservesIrregularVideoAndLongerAACEndpoints()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let videoURL = fixture.directory.appendingPathComponent("video.mp4")
        let audioURL = fixture.directory.appendingPathComponent("audio.m4a")
        let expectedVideoEnd = CMTime(value: 11_262, timescale: 90_000)
        try await writeMixedTimeScaleEditBoundaryVideo(
            to: videoURL,
            resolution: VideoResolution(width: 64, height: 64)
        )
        try writeAACFixture(to: audioURL, frameCount: 12_000)
        try await muxVideoAndAAC(
            videoURL: videoURL,
            audioURL: audioURL,
            destinationURL: fixture.source,
            preserveExactVideoEndWithMarker: true
        )

        let outputAsset = AVURLAsset(
            url: fixture.source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let videoTimeRange = try await videoTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeRangeGetEnd(videoTimeRange),
                expectedVideoEnd
            ),
            0
        )
        let audioTracks = try await outputAsset.loadTracks(
            withMediaType: .audio
        )
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let audioTimeRange = try await audioTrack.load(.timeRange)
        let audioEnd = CMTimeRangeGetEnd(audioTimeRange)
        XCTAssertGreaterThan(
            CMTimeCompare(audioEnd, expectedVideoEnd),
            0
        )
        let outputDuration = try await outputAsset.load(.duration)
        XCTAssertEqual(
            CMTimeCompare(
                outputDuration,
                audioEnd
            ),
            0
        )
    }

    // The integration contract is intentionally verified end to end.
    // swiftlint:disable:next function_body_length
    func testMixedTimeScaleEditBoundaryWithLongerAACPreservesBothEndpoints()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let videoURL = fixture.directory.appendingPathComponent("video.mp4")
        let audioURL = fixture.directory.appendingPathComponent("audio.m4a")
        let sourceResolution = VideoResolution(width: 64, height: 64)
        let outputResolution = VideoResolution(width: 128, height: 128)
        let expectedVideoEnd = CMTime(value: 11_262, timescale: 90_000)
        try await writeMixedTimeScaleEditBoundaryVideo(
            to: videoURL,
            resolution: sourceResolution
        )
        try writeAACFixture(to: audioURL, frameCount: 12_000)
        try await muxVideoAndAAC(
            videoURL: videoURL,
            audioURL: audioURL,
            destinationURL: fixture.source,
            preserveExactVideoEndWithMarker: true
        )
        let expectedAAC = try await OutputMediaAACIdentityReader()
            .read(url: fixture.source)
        let expectedAudioEnd = CMTimeRangeGetEnd(
            expectedAAC.trackTimeRange
        )
        let compressedAccessUnitDuration = expectedAAC.samples.reduce(
            CMTime.zero
        ) { partial, sample in
            CMTimeAdd(partial, sample.duration)
        }
        XCTAssertNotEqual(
            CMTimeCompare(
                compressedAccessUnitDuration,
                expectedAAC.trackTimeRange.duration
            ),
            0,
            "fixture must retain an AAC edit boundary that differs from "
                + "the full compressed access-unit span"
        )
        XCTAssertGreaterThan(
            CMTimeCompare(expectedAudioEnd, expectedVideoEnd),
            0
        )
        let sourceAsset = AVURLAsset(
            url: fixture.source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let sourceVideoTracks = try await sourceAsset.loadTracks(
            withMediaType: .video
        )
        let sourceVideoTrack = try XCTUnwrap(sourceVideoTracks.first)
        let sourceVideoRange = try await sourceVideoTrack.load(.timeRange)
        let actualSourceVideoEnd = CMTimeRangeGetEnd(sourceVideoRange)
        XCTAssertEqual(
            CMTimeCompare(
                actualSourceVideoEnd,
                expectedVideoEnd
            ),
            0,
            "source video end \(actualSourceVideoEnd)"
        )

        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: outputResolution,
                codec: .h264,
                preserveAudio: true
            )
        )
        defer { session.cancel() }
        var frameCount = 0
        while let record = try await session.nextSourceFrame() {
            let output = try PixelBufferBridge.dequeue(
                from: session.outputPixelBufferPool
            )
            try fillNV12(output)
            try await session.appendOutput(
                pixelBuffer: output,
                timing: record.timing
            )
            frameCount += 1
        }
        XCTAssertEqual(frameCount, 3)

        try await session.finish()

        let outputAsset = AVURLAsset(
            url: fixture.destination,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let outputDuration = try await outputAsset.load(.duration)
        XCTAssertEqual(
            CMTimeCompare(outputDuration, expectedAudioEnd),
            0
        )
        let outputVideoTracks = try await outputAsset.loadTracks(
            withMediaType: .video
        )
        let outputVideoTrack = try XCTUnwrap(outputVideoTracks.first)
        let outputVideoRange = try await outputVideoTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeRangeGetEnd(outputVideoRange),
                expectedVideoEnd
            ),
            0
        )
        let actualAAC = try await OutputMediaAACIdentityReader()
            .read(url: fixture.destination)
        XCTAssertEqual(actualAAC, expectedAAC)
        XCTAssertTrue(fixture.recognizedStagingFiles().isEmpty)
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

    func testCancellationDuringDecodedFrameScanPropagatesCancellation()
        async throws {
        let fixture = try MediaOutputFixture()
        defer { fixture.remove() }
        let resolution = VideoResolution(width: 64, height: 64)
        let frameDuration = CMTime(value: 1, timescale: 30)
        try await writeVideoFrames(
            to: fixture.source,
            resolution: resolution,
            frameCount: 3,
            frameDuration: frameDuration
        )
        var ledger = FrameTimingLedger()
        for frameIndex in 0..<3 {
            try ledger.append(FrameTiming(
                frameIndex: frameIndex,
                presentationTime: CMTimeMultiply(
                    frameDuration,
                    multiplier: Int32(frameIndex)
                ),
                duration: frameDuration
            ))
        }
        let cancellation = VerificationCancellationProbe(
            cancellationCheckNumber: 10
        )

        do {
            _ = try await OutputMediaVerifier().verify(
                url: fixture.source,
                expectation: OutputMediaVerificationExpectation(
                    resolution: resolution,
                    codec: .h264,
                    timing: ledger.snapshot
                ),
                cancellationCheck: { @Sendable in
                    try cancellation.check()
                }
            )
            XCTFail("Expected cancellation during decoded-frame verification.")
        } catch is CancellationError {
            XCTAssertEqual(cancellation.checkCount, 10)
        }
    }

}

// swiftlint:enable file_length
