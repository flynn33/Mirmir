import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os.lock
@testable import Mirmir

// Media writer fixtures remain together to preserve one timing contract.
// swiftlint:disable file_length

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

final class VerificationCancellationProbe: @unchecked Sendable {
    private let cancellationCheckNumber: Int
    private let state = OSAllocatedUnfairLock(initialState: 0)

    init(cancellationCheckNumber: Int) {
        precondition(cancellationCheckNumber > 0)
        self.cancellationCheckNumber = cancellationCheckNumber
    }

    var checkCount: Int {
        state.withLock { $0 }
    }

    func check() throws {
        let shouldCancel = state.withLock { count in
            count += 1
            return count >= cancellationCheckNumber
        }
        if shouldCancel {
            throw CancellationError()
        }
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
            let name = $0.lastPathComponent
            return (name.hasPrefix(".destination.mirmir-")
                && name.contains(".partial"))
                || name.hasPrefix(".mirmir-video-stage-")
        }
    }

    func recognizedStagingFiles() -> [URL] {
        recognizedTemporaryFiles().filter {
            $0.lastPathComponent.hasPrefix(".mirmir-video-stage-")
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
    case invalidFrameCount
}

private let mediaFixtureTimeout: Duration = .seconds(120)

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
    preferredTransform: CGAffineTransform = .identity,
    pixelAspectRatio: VideoPixelAspectRatio? = nil
) async throws {
    try await writeVideoFrames(
        to: url,
        resolution: resolution,
        frameCount: 1,
        frameDuration: duration,
        pixelFormat: pixelFormat,
        preferredTransform: preferredTransform,
        pixelAspectRatio: pixelAspectRatio
    )
}

// Writer setup and completion form one end-to-end fixture operation.
// swiftlint:disable:next cyclomatic_complexity function_body_length
func writeVideoFrames(
    to url: URL,
    resolution: VideoResolution,
    frameCount: Int,
    frameDuration: CMTime,
    pixelFormat: OSType = PixelBufferBridge.preferredFormat,
    preferredTransform: CGAffineTransform = .identity,
    pixelAspectRatio: VideoPixelAspectRatio? = nil,
    inputMediaTimeScale: CMTimeScale = 600,
    movieTimeScale: CMTimeScale? = nil,
    sessionEndTime: CMTime? = nil,
    useEndDurationMarker: Bool = false,
    endWriterSession: Bool = true
) async throws {
    guard frameCount > 0, frameCount <= Int(Int32.max) else {
        throw MediaTestFailure.invalidFrameCount
    }
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(url: url, fileType: .mp4)
    } catch {
        throw MediaTestFailure.cannotCreateWriter
    }
    if let movieTimeScale {
        writer.movieTimeScale = movieTimeScale
    }
    var videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: resolution.width,
        AVVideoHeightKey: resolution.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    ]
    if let pixelAspectRatio {
        videoSettings[AVVideoPixelAspectRatioKey] = [
            AVVideoPixelAspectRatioHorizontalSpacingKey:
                pixelAspectRatio.horizontalSpacing,
            AVVideoPixelAspectRatioVerticalSpacingKey:
                pixelAspectRatio.verticalSpacing
        ]
    }
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: videoSettings
    )
    input.mediaTimeScale = inputMediaTimeScale
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
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: mediaFixtureTimeout)
    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                writer.cancelWriting()
                throw MediaTestFailure.timeout
            }
            guard writer.status == .writing else {
                throw MediaTestFailure.writerFailed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        var optionalPixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &optionalPixelBuffer
        )
        guard createStatus == kCVReturnSuccess,
              let pixelBuffer = optionalPixelBuffer else {
            throw MediaTestFailure.cannotCreatePixelBuffer(createStatus)
        }
        try fillNV12(pixelBuffer)
        let presentationTime = CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameIndex)
        )
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: presentationTime
        ) else {
            throw MediaTestFailure.appendFailed
        }
    }
    let resolvedSessionEndTime = sessionEndTime
        ?? CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameCount)
        )
    if useEndDurationMarker {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                writer.cancelWriting()
                throw MediaTestFailure.timeout
            }
            guard writer.status == .writing else {
                throw MediaTestFailure.writerFailed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let marker = try makeEndDurationMarker(
            at: resolvedSessionEndTime
        )
        guard input.append(marker) else {
            throw MediaTestFailure.appendFailed
        }
    }
    input.markAsFinished()
    if endWriterSession {
        writer.endSession(atSourceTime: resolvedSessionEndTime)
    }
    try await finishWriting(
        writer,
        deadline: deadline
    )
}

private func makeEndDurationMarker(
    at presentationTime: CMTime
) throws -> CMSampleBuffer {
    var timing = CMSampleTimingInfo(
        duration: .invalid,
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: presentationTime
    )
    var marker: CMSampleBuffer?
    let status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: nil,
        sampleCount: 0,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &marker
    )
    guard status == noErr, let marker else {
        throw MediaTestFailure.appendFailed
    }
    CMSetAttachment(
        marker,
        key: kCMSampleBufferAttachmentKey_EndsPreviousSampleDuration,
        value: kCFBooleanTrue,
        attachmentMode: kCMAttachmentMode_ShouldNotPropagate
    )
    return marker
}

func writeMixedTimeScaleEditBoundaryVideo(
    to url: URL,
    resolution: VideoResolution
) async throws {
    try await writeVideoFrames(
        to: url,
        resolution: resolution,
        frameCount: 3,
        frameDuration: CMTime(value: 1_001, timescale: 24_000),
        inputMediaTimeScale: 24_000,
        movieTimeScale: 90_000,
        sessionEndTime: CMTime(value: 11_262, timescale: 90_000),
        useEndDurationMarker: true,
        endWriterSession: false
    )
}

func muxVideoAndAAC(
    videoURL: URL,
    audioURL: URL,
    destinationURL: URL,
    preserveExactVideoEndWithMarker: Bool = false
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
    let videoTimeRange = try await videoTrack.load(.timeRange)
    let videoEnd = CMTimeRangeGetEnd(videoTimeRange)
    let audioEnd = CMTimeRangeGetEnd(
        try await audioTrack.load(.timeRange)
    )
    let exactVideoTimeScale: CMTimeScale?
    if preserveExactVideoEndWithMarker {
        exactVideoTimeScale = try ExactVideoWriterTimeScale.resolve(
            naturalTimeScale: try await videoTrack.load(.naturalTimeScale),
            trackTimeRange: videoTimeRange
        )
    } else {
        exactVideoTimeScale = nil
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
    if let exactVideoTimeScale {
        writer.movieTimeScale = exactVideoTimeScale
    }
    let videoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: videoFormat
    )
    if let exactVideoTimeScale {
        videoInput.mediaTimeScale = exactVideoTimeScale
    }
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
    try await appendCompressedSamplesInterleaved(
        videoOutput: videoOutput,
        videoReader: videoReader,
        videoInput: videoInput,
        videoEndMarkerTime: preserveExactVideoEndWithMarker
            ? videoEnd
            : nil,
        audioOutput: audioOutput,
        audioReader: audioReader,
        audioInput: audioInput,
        writer: writer
    )
    if !preserveExactVideoEndWithMarker {
        writer.endSession(
            atSourceTime: CMTimeCompare(audioEnd, videoEnd) > 0
                ? audioEnd
                : videoEnd
        )
    }
    let clock = ContinuousClock()
    try await finishWriting(
        writer,
        deadline: clock.now.advanced(by: mediaFixtureTimeout)
    )
}

private func finishWriting(
    _ writer: AVAssetWriter,
    deadline: ContinuousClock.Instant
) async throws {
    writer.finishWriting(completionHandler: {})
    let clock = ContinuousClock()
    do {
        while writer.status == .writing {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw MediaTestFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    } catch {
        writer.cancelWriting()
        throw error
    }
    guard writer.status == .completed else {
        throw MediaTestFailure.writerFailed
    }
}

private func appendCompressedSamplesInterleaved(
    videoOutput: AVAssetReaderTrackOutput,
    videoReader: AVAssetReader,
    videoInput: AVAssetWriterInput,
    videoEndMarkerTime: CMTime?,
    audioOutput: AVAssetReaderTrackOutput,
    audioReader: AVAssetReader,
    audioInput: AVAssetWriterInput,
    writer: AVAssetWriter
) async throws {
    var videoFinished = false
    var audioFinished = false
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: mediaFixtureTimeout)
    while !videoFinished || !audioFinished {
        try Task.checkCancellation()
        guard clock.now < deadline else {
            videoReader.cancelReading()
            audioReader.cancelReading()
            writer.cancelWriting()
            throw MediaTestFailure.timeout
        }
        guard writer.status == .writing else {
            throw MediaTestFailure.writerFailed
        }
        var madeProgress = false

        if !videoFinished, videoInput.isReadyForMoreMediaData {
            if let sample = videoOutput.copyNextSampleBuffer() {
                guard videoInput.append(sample) else {
                    throw MediaTestFailure.appendFailed
                }
            } else {
                guard videoReader.status == .completed else {
                    throw MediaTestFailure.readerFailed
                }
                if let videoEndMarkerTime {
                    let marker = try makeEndDurationMarker(
                        at: videoEndMarkerTime
                    )
                    guard videoInput.append(marker) else {
                        throw MediaTestFailure.appendFailed
                    }
                }
                videoInput.markAsFinished()
                videoFinished = true
            }
            madeProgress = true
        }

        if !audioFinished, audioInput.isReadyForMoreMediaData {
            if let sample = audioOutput.copyNextSampleBuffer() {
                guard audioInput.append(sample) else {
                    throw MediaTestFailure.appendFailed
                }
            } else {
                guard audioReader.status == .completed else {
                    throw MediaTestFailure.readerFailed
                }
                audioInput.markAsFinished()
                audioFinished = true
            }
            madeProgress = true
        }

        if !madeProgress {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
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

func pixelAspectRatio(
    in pixelBuffer: CVPixelBuffer
) throws -> VideoPixelAspectRatio {
    guard let dictionary = CVBufferCopyAttachment(
        pixelBuffer,
        kCVImageBufferPixelAspectRatioKey,
        nil
    ) as? NSDictionary,
          let horizontal = dictionary[
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey
          ] as? NSNumber,
          let vertical = dictionary[
            kCVImageBufferPixelAspectRatioVerticalSpacingKey
          ] as? NSNumber,
          let ratio = VideoPixelAspectRatio(
            horizontalSpacing: horizontal.intValue,
            verticalSpacing: vertical.intValue
          ) else {
        throw MediaTestFailure.readerFailed
    }
    return ratio
}

// swiftlint:enable file_length
