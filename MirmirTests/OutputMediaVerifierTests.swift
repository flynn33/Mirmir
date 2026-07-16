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

private struct RejectingOutputMediaVerifier: OutputMediaVerifying {
    struct InjectedFailure: Error {}

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        throw InjectedFailure()
    }
}

private final class SuspendingOutputMediaVerifier: OutputMediaVerifying, @unchecked Sendable {
    private struct State {
        var didStart = false
        var expectation: OutputMediaVerificationExpectation?
        var continuation: CheckedContinuation<OutputMediaVerificationResult, Error>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.didStart = true
                state.expectation = expectation
                state.continuation = continuation
            }
        }
    }

    func waitUntilStarted() async throws {
        for _ in 0..<100_000 {
            if state.withLock({ $0.didStart }) { return }
            await Task.yield()
        }
        throw MediaTestFailure.timeout
    }

    func resumeSuccessfully() {
        let resume = state.withLock { state -> (
            CheckedContinuation<OutputMediaVerificationResult, Error>,
            OutputMediaVerificationResult
        )? in
            guard let continuation = state.continuation,
                  let expectation = state.expectation,
                  let duration = expectation.timing.sessionEndTime else {
                return nil
            }
            state.continuation = nil
            let result = OutputMediaVerificationResult(
                codec: "avc1",
                resolution: expectation.resolution,
                frameCount: expectation.timing.frameCount,
                duration: duration,
                lumaPayloadBytes: 1,
                chromaPayloadBytes: 1
            )
            return (continuation, result)
        }
        guard let resume else { return }
        resume.0.resume(returning: resume.1)
    }
}

private struct MediaOutputFixture {
    let directory: URL
    let source: URL
    let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        source = directory.appendingPathComponent("source.mp4")
        destination = directory.appendingPathComponent("destination.mp4")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func recognizedTemporaryFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.lastPathComponent.hasPrefix(".destination.mirmir-")
                && $0.lastPathComponent.contains(".partial")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum MediaTestFailure: Error {
    case cannotCreateWriter
    case cannotAddWriterInput
    case cannotStartWriter
    case missingPixelBufferPool
    case cannotCreatePixelBuffer(CVReturn)
    case appendFailed
    case writerFailed
    case timeout
}

private func makeTimingSnapshot(
    presentationTime: CMTime,
    duration: CMTime
) throws -> FrameTimingLedgerSnapshot {
    var ledger = FrameTimingLedger()
    try ledger.append(FrameTiming(
        frameIndex: 0,
        presentationTime: presentationTime,
        duration: duration
    ))
    return ledger.snapshot
}

private func writeOneFrameVideo(
    to url: URL,
    resolution: VideoResolution,
    duration: CMTime
) async throws {
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(url: url, fileType: .mp4)
    } catch {
        throw MediaTestFailure.cannotCreateWriter
    }
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: resolution.width,
            AVVideoHeightKey: resolution.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    )
    input.mediaTimeScale = 600
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: PixelBufferBridge.preferredFormat,
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
    )
    guard writer.canAdd(input) else { throw MediaTestFailure.cannotAddWriterInput }
    writer.add(input)
    guard writer.startWriting() else { throw MediaTestFailure.cannotStartWriter }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else { throw MediaTestFailure.missingPixelBufferPool }
    var optionalPixelBuffer: CVPixelBuffer?
    let createStatus = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault,
        pool,
        &optionalPixelBuffer
    )
    guard createStatus == kCVReturnSuccess, let pixelBuffer = optionalPixelBuffer else {
        throw MediaTestFailure.cannotCreatePixelBuffer(createStatus)
    }
    try fillNV12(pixelBuffer)
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
        throw MediaTestFailure.appendFailed
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: duration)
    await writer.finishWriting()
    guard writer.status == .completed else { throw MediaTestFailure.writerFailed }
}

private func fillNV12(_ pixelBuffer: CVPixelBuffer) throws {
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else { throw MediaTestFailure.appendFailed }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw MediaTestFailure.appendFailed
    }
    for planeIndex in 0..<2 {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex) else {
            throw MediaTestFailure.appendFailed
        }
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
        memset(baseAddress, planeIndex == 0 ? 64 : 128, height * bytesPerRow)
    }
}
