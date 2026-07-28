import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os.lock
@testable import Mirmir

struct RejectingOutputMediaVerifier: OutputMediaVerifying {
    struct InjectedFailure: Error {}

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        throw InjectedFailure()
    }
}

final class SuspendingOutputMediaVerifier: OutputMediaVerifying, @unchecked Sendable {
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

struct MediaOutputFixture {
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

enum MediaTestFailure: Error {
    case cannotCreateReader
    case cannotCreateWriter
    case cannotAddReaderOutput
    case cannotAddWriterInput
    case cannotStartReader
    case cannotStartWriter
    case missingPixelBufferPool
    case cannotCreatePixelBuffer(CVReturn)
    case appendFailed
    case writerFailed
    case readerFailed
    case timeout
}

func makeTimingSnapshot(
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

func writeOneFrameVideo(
    to url: URL,
    resolution: VideoResolution,
    duration: CMTime,
    pixelFormat: OSType = PixelBufferBridge.preferredFormat,
    preferredTransform: CGAffineTransform = .identity
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
    input.transform = preferredTransform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
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

func muxVideoAndAAC(
    videoURL: URL,
    audioURL: URL,
    destinationURL: URL
) async throws {
    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)
    guard let videoTrack = try await videoAsset
        .loadTracks(withMediaType: .video).first,
          let audioTrack = try await audioAsset
            .loadTracks(withMediaType: .audio).first,
          let videoFormat = try await videoTrack
            .load(.formatDescriptions).first,
          let audioFormat = try await audioTrack
            .load(.formatDescriptions).first else {
        throw MediaTestFailure.cannotCreateReader
    }
    let videoReader = try AVAssetReader(asset: videoAsset)
    let audioReader = try AVAssetReader(asset: audioAsset)
    let videoOutput = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: nil
    )
    let audioOutput = AVAssetReaderTrackOutput(
        track: audioTrack,
        outputSettings: nil
    )
    guard videoReader.canAdd(videoOutput),
          audioReader.canAdd(audioOutput) else {
        throw MediaTestFailure.cannotAddReaderOutput
    }
    videoReader.add(videoOutput)
    audioReader.add(audioOutput)

    let writer = try AVAssetWriter(url: destinationURL, fileType: .mp4)
    let videoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: videoFormat
    )
    videoInput.transform = try await videoTrack.load(.preferredTransform)
    let audioInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: nil,
        sourceFormatHint: audioFormat
    )
    guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    writer.add(videoInput)
    writer.add(audioInput)
    guard videoReader.startReading(), audioReader.startReading() else {
        throw MediaTestFailure.cannotStartReader
    }
    guard writer.startWriting() else {
        throw MediaTestFailure.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)
    try await appendCompressedSamples(
        from: videoOutput,
        reader: videoReader,
        to: videoInput,
        writer: writer
    )
    try await appendCompressedSamples(
        from: audioOutput,
        reader: audioReader,
        to: audioInput,
        writer: writer
    )
    let videoEnd = CMTimeRangeGetEnd(
        try await videoTrack.load(.timeRange)
    )
    let audioEnd = CMTimeRangeGetEnd(
        try await audioTrack.load(.timeRange)
    )
    writer.endSession(
        atSourceTime: CMTimeCompare(audioEnd, videoEnd) > 0
            ? audioEnd
            : videoEnd
    )
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw MediaTestFailure.writerFailed
    }
}

private func appendCompressedSamples(
    from output: AVAssetReaderTrackOutput,
    reader: AVAssetReader,
    to input: AVAssetWriterInput,
    writer: AVAssetWriter
) async throws {
    while let sample = output.copyNextSampleBuffer() {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw MediaTestFailure.writerFailed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard input.append(sample) else {
            throw MediaTestFailure.appendFailed
        }
    }
    guard reader.status == .completed else {
        throw MediaTestFailure.readerFailed
    }
    input.markAsFinished()
}

func fillNV12(_ pixelBuffer: CVPixelBuffer) throws {
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
