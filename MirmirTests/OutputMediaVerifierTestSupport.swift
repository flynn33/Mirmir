import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
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
                scanStructure: expectation.scanStructure,
                frameCount: expectation.timing.frameCount,
                duration: duration,
                lumaPayloadBytes: 1,
                chromaPayloadBytes: 1,
                alphaPayloadBytes: 0
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

    init(
        sourceExtension: String = "mp4",
        destinationExtension: String = "mp4"
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        source = directory.appendingPathComponent(
            "source.\(sourceExtension)"
        )
        destination = directory.appendingPathComponent(
            "destination.\(destinationExtension)"
        )
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

private protocol FixtureCaptionAppender {
    func append(_ caption: AVCaption) async throws
    func finish()
}

@available(macOS 26.0, *)
private final class FixtureCaptionReceiverAppender:
    FixtureCaptionAppender {
    private let receiver: AVAssetWriterInput.CaptionReceiver

    init(
        writer: AVAssetWriter,
        input: AVAssetWriterInput
    ) {
        receiver = writer.inputCaptionReceiver(for: input)
    }

    func append(_ caption: AVCaption) async throws {
        try await receiver.append(caption)
    }

    func finish() {
        receiver.finish()
    }
}

private final class FixtureLegacyCaptionAppender:
    FixtureCaptionAppender {
    private let input: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let adaptor: AVAssetWriterInputCaptionAdaptor

    init(
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) {
        self.input = input
        self.writer = writer
        adaptor = AVAssetWriterInputCaptionAdaptor(
            assetWriterInput: input
        )
    }

    func append(_ caption: AVCaption) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: mediaFixtureTimeout)
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                writer.cancelWriting()
                throw MediaTestFailure.timeout
            }
            guard writer.status == .writing else {
                throw writer.error ?? MediaTestFailure.writerFailed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard adaptor.append(caption) else {
            throw writer.error ?? MediaTestFailure.appendFailed
        }
    }

    func finish() {
        input.markAsFinished()
    }
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
    preferredTransform: CGAffineTransform = .identity,
    pixelAspectRatio: VideoPixelAspectRatio? = nil,
    codec: OutputCodec = .h264,
    videoFormat: MediaVideoFormat? = nil,
    containerMetadata: [AVMetadataItem] = [],
    videoTrackMetadata: [AVMetadataItem] = [],
    timedMetadata: [String: String]? = nil,
    subtitleText: String? = nil,
    textTrackText: String? = nil,
    closedCaptionText: String? = nil,
    closedCaptionTimeRange: CMTimeRange? = nil,
    timecodeFrameNumber: UInt32? = nil
) async throws {
    try await writeVideoFrames(
        to: url,
        resolution: resolution,
        frameCount: 1,
        frameDuration: duration,
        pixelFormat: pixelFormat,
        preferredTransform: preferredTransform,
        pixelAspectRatio: pixelAspectRatio,
        codec: codec,
        videoFormat: videoFormat,
        containerMetadata: containerMetadata,
        videoTrackMetadata: videoTrackMetadata,
        timedMetadata: timedMetadata,
        subtitleText: subtitleText,
        textTrackText: textTrackText,
        closedCaptionText: closedCaptionText,
        closedCaptionTimeRange: closedCaptionTimeRange,
        timecodeFrameNumber: timecodeFrameNumber
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
    endWriterSession: Bool = true,
    codec: OutputCodec = .h264,
    videoFormat: MediaVideoFormat? = nil,
    containerMetadata: [AVMetadataItem] = [],
    videoTrackMetadata: [AVMetadataItem] = [],
    timedMetadata: [String: String]? = nil,
    subtitleText: String? = nil,
    textTrackText: String? = nil,
    closedCaptionText: String? = nil,
    closedCaptionTimeRange: CMTimeRange? = nil,
    timecodeFrameNumber: UInt32? = nil
) async throws {
    guard frameCount > 0, frameCount <= Int(Int32.max) else {
        throw MediaTestFailure.invalidFrameCount
    }
    let resolvedSessionEndTime = sessionEndTime
        ?? CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameCount)
        )
    let resolvedCaptionTimeRange = closedCaptionText.map { _ in
        closedCaptionTimeRange
            ?? CMTimeRange(
                start: frameDuration,
                duration: CMTimeSubtract(
                    resolvedSessionEndTime,
                    frameDuration
                )
            )
    }
    if let resolvedCaptionTimeRange {
        guard resolvedCaptionTimeRange.isValid,
              !resolvedCaptionTimeRange.isEmpty,
              resolvedCaptionTimeRange.start.isNumeric,
              resolvedCaptionTimeRange.duration.isNumeric,
              CMTimeCompare(
                resolvedCaptionTimeRange.start,
                .zero
              ) > 0,
              CMTimeCompare(
                CMTimeRangeGetEnd(resolvedCaptionTimeRange),
                resolvedSessionEndTime
              ) <= 0 else {
            throw MediaTestFailure.invalidFrameCount
        }
    }
    let writer: AVAssetWriter
    do {
        let fileType: AVFileType = url.pathExtension.lowercased() == "mov"
            ? .mov
            : .mp4
        writer = try AVAssetWriter(url: url, fileType: fileType)
    } catch {
        throw MediaTestFailure.cannotCreateWriter
    }
    if let movieTimeScale {
        writer.movieTimeScale = movieTimeScale
    }
    writer.metadata = containerMetadata
    var videoSettings: [String: Any]
    if let videoFormat {
        videoSettings = ProductVideoOutputSettings.make(
            resolution: resolution,
            codec: codec,
            videoFormat: videoFormat
        )
    } else {
        videoSettings = [
            AVVideoCodecKey: codec.avCodecKey,
            AVVideoWidthKey: resolution.width,
            AVVideoHeightKey: resolution.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey:
                    AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey:
                    AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }
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
    input.metadata = videoTrackMetadata
    input.mediaTimeScale = inputMediaTimeScale
    input.transform = preferredTransform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                videoFormat?.pixelStorage.pixelFormat ?? pixelFormat,
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
    )
    guard writer.canAdd(input) else { throw MediaTestFailure.cannotAddWriterInput }
    writer.add(input)
    var metadataInput: AVAssetWriterInput?
    var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
    var metadataGroup: AVTimedMetadataGroup?
    if let timedMetadata {
        let resolvedMetadataGroup =
            AVFoundationMediaSession.makeASHMetadataGroup(
                timedMetadata,
                timeRange: CMTimeRange(
                    start: .zero,
                    duration: resolvedSessionEndTime
                )
            )
        guard let formatDescription =
                resolvedMetadataGroup.copyFormatDescription() else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        let resolvedMetadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        resolvedMetadataInput.expectsMediaDataInRealTime = false
        resolvedMetadataInput.mediaTimeScale = inputMediaTimeScale
        guard writer.canAdd(resolvedMetadataInput) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        writer.add(resolvedMetadataInput)
        resolvedMetadataInput.addTrackAssociation(
            withTrackOf: input,
            type: AVAssetTrack.AssociationType
                .metadataReferent.rawValue
        )
        metadataInput = resolvedMetadataInput
        metadataAdaptor = AVAssetWriterInputMetadataAdaptor(
            assetWriterInput: resolvedMetadataInput
        )
        metadataGroup = resolvedMetadataGroup
    }
    var subtitleInput: AVAssetWriterInput?
    var subtitleFormatDescription: CMFormatDescription?
    if subtitleText != nil {
        let formatDescription = try makeFixtureSubtitleFormatDescription()
        let resolvedSubtitleInput = AVAssetWriterInput(
            mediaType: .subtitle,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        resolvedSubtitleInput.expectsMediaDataInRealTime = false
        resolvedSubtitleInput.mediaTimeScale = inputMediaTimeScale
        resolvedSubtitleInput.languageCode = "eng"
        resolvedSubtitleInput.extendedLanguageTag = "en-US"
        guard writer.canAdd(resolvedSubtitleInput) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        writer.add(resolvedSubtitleInput)
        subtitleInput = resolvedSubtitleInput
        subtitleFormatDescription = formatDescription
    }
    var textTrackInput: AVAssetWriterInput?
    var textTrackFormatDescription: CMFormatDescription?
    if textTrackText != nil {
        let formatDescription = try makeFixtureTextFormatDescription()
        let resolvedTextTrackInput = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        resolvedTextTrackInput.expectsMediaDataInRealTime = false
        resolvedTextTrackInput.mediaTimeScale = inputMediaTimeScale
        resolvedTextTrackInput.languageCode = "eng"
        resolvedTextTrackInput.extendedLanguageTag = "en-US"
        guard writer.canAdd(resolvedTextTrackInput) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        writer.add(resolvedTextTrackInput)
        textTrackInput = resolvedTextTrackInput
        textTrackFormatDescription = formatDescription
    }
    var timecodeInput: AVAssetWriterInput?
    var timecodeFormatDescription: CMTimeCodeFormatDescription?
    if timecodeFrameNumber != nil {
        let formatDescription = try makeFixtureTimecodeFormatDescription(
            frameDuration: frameDuration
        )
        let resolvedTimecodeInput = AVAssetWriterInput(
            mediaType: .timecode,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        resolvedTimecodeInput.expectsMediaDataInRealTime = false
        resolvedTimecodeInput.mediaTimeScale = inputMediaTimeScale
        guard writer.canAdd(resolvedTimecodeInput) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        writer.add(resolvedTimecodeInput)
        input.addTrackAssociation(
            withTrackOf: resolvedTimecodeInput,
            type: AVAssetTrack.AssociationType.timecode.rawValue
        )
        timecodeInput = resolvedTimecodeInput
        timecodeFormatDescription = formatDescription
    }
    var captionAppender: (any FixtureCaptionAppender)?
    if closedCaptionText != nil {
        let captionInput = AVAssetWriterInput(
            mediaType: .closedCaption,
            outputSettings: nil
        )
        captionInput.expectsMediaDataInRealTime = false
        captionInput.mediaTimeScale = inputMediaTimeScale
        captionInput.languageCode = "eng"
        captionInput.extendedLanguageTag = "en-US"
        if #available(macOS 26.0, *) {
            captionAppender = FixtureCaptionReceiverAppender(
                writer: writer,
                input: captionInput
            )
        } else {
            guard writer.canAdd(captionInput) else {
                throw MediaTestFailure.cannotAddWriterInput
            }
            writer.add(captionInput)
            captionAppender = FixtureLegacyCaptionAppender(
                input: captionInput,
                writer: writer
            )
        }
        input.addTrackAssociation(
            withTrackOf: captionInput,
            type: AVAssetTrack.AssociationType(rawValue: "clcp").rawValue
        )
    }
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
        try fillFixturePixelBuffer(pixelBuffer)
        videoFormat?.installAttachments(on: pixelBuffer)
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
    if let metadataInput,
       let metadataAdaptor,
       let metadataGroup {
        while !metadataInput.isReadyForMoreMediaData {
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
        guard metadataAdaptor.append(metadataGroup) else {
            throw MediaTestFailure.appendFailed
        }
        metadataInput.markAsFinished()
    }
    if let subtitleText,
       let subtitleInput,
       let subtitleFormatDescription {
        let sample = try makeFixtureSubtitleSample(
            text: subtitleText,
            duration: resolvedSessionEndTime,
            formatDescription: subtitleFormatDescription
        )
        try await appendFixtureSample(
            sample,
            to: subtitleInput,
            writer: writer,
            clock: clock,
            deadline: deadline
        )
        subtitleInput.markAsFinished()
    }
    if let textTrackText,
       let textTrackInput,
       let textTrackFormatDescription {
        let sample = try makeFixtureTextSample(
            text: textTrackText,
            duration: resolvedSessionEndTime,
            formatDescription: textTrackFormatDescription
        )
        try await appendFixtureSample(
            sample,
            to: textTrackInput,
            writer: writer,
            clock: clock,
            deadline: deadline
        )
        textTrackInput.markAsFinished()
    }
    if let timecodeFrameNumber,
       let timecodeInput,
       let timecodeFormatDescription {
        let sample = try makeFixtureTimecodeSample(
            frameNumber: timecodeFrameNumber,
            duration: resolvedSessionEndTime,
            formatDescription: timecodeFormatDescription
        )
        try await appendFixtureSample(
            sample,
            to: timecodeInput,
            writer: writer,
            clock: clock,
            deadline: deadline
        )
        timecodeInput.markAsFinished()
    }
    if let closedCaptionText,
       let resolvedCaptionTimeRange,
       let captionAppender {
        try await captionAppender.append(
            AVCaption(
                closedCaptionText,
                timeRange: resolvedCaptionTimeRange
            )
        )
        captionAppender.finish()
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

private func addStandaloneClosedCaptionTrack(
    to videoURL: URL,
    text: String,
    timeRange: CMTimeRange
) async throws {
    let directory = videoURL.deletingLastPathComponent()
    let captionURL = directory.appendingPathComponent(
        "fixture-caption-\(UUID().uuidString).mov"
    )
    let combinedURL = directory.appendingPathComponent(
        "fixture-caption-mux-\(UUID().uuidString).mov"
    )
    defer {
        if FileManager.default.fileExists(atPath: captionURL.path) {
            try? FileManager.default.removeItem(at: captionURL)
        }
        if FileManager.default.fileExists(atPath: combinedURL.path) {
            try? FileManager.default.removeItem(at: combinedURL)
        }
    }
    try await writeStandaloneClosedCaptionTrack(
        to: captionURL,
        text: text,
        timeRange: timeRange
    )

    let sourceAsset = AVURLAsset(
        url: videoURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let captionAsset = AVURLAsset(
        url: captionURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let sourceTracks = try await sourceAsset.load(.tracks)
    let captionTracks = try await captionAsset.loadTracks(
        withMediaType: .closedCaption
    )
    guard captionTracks.count == 1 else {
        throw MediaTestFailure.writerFailed
    }

    let movie = AVMutableMovie()
    movie.timescale = 600
    movie.metadata = try await sourceAsset.load(.metadata)
    movie.defaultMediaDataStorage = AVMediaDataStorage(
        url: combinedURL,
        options: nil
    )
    var destinationVideoTrack: AVMutableMovieTrack?
    var destinationCaptionTrack: AVMutableMovieTrack?
    for sourceTrack in sourceTracks + captionTracks {
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: sourceTrack.mediaType,
            copySettingsFrom: sourceTrack,
            options: nil
        ) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        let naturalTimeScale = try await sourceTrack.load(
            .naturalTimeScale
        )
        if naturalTimeScale > 0 {
            destinationTrack.timescale = naturalTimeScale
        }
        destinationTrack.isEnabled = try await sourceTrack.load(
            .isEnabled
        )
        destinationTrack.languageCode = try await sourceTrack.load(
            .languageCode
        )
        destinationTrack.extendedLanguageTag = try await sourceTrack.load(
            .extendedLanguageTag
        )
        destinationTrack.metadata = try await sourceTrack.load(.metadata)
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        do {
            try destinationTrack.insertTimeRange(
                sourceTimeRange,
                of: sourceTrack,
                at: sourceTimeRange.start,
                copySampleData: true
            )
        } catch {
            throw NSError(
                domain: "MirmirTests.CaptionMux",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Exact sample copy failed for media type "
                        + sourceTrack.mediaType.rawValue,
                    NSUnderlyingErrorKey: error
                ]
            )
        }
        if sourceTrack.mediaType == .video {
            destinationVideoTrack = destinationTrack
        } else if sourceTrack.mediaType == .closedCaption {
            destinationCaptionTrack = destinationTrack
        }
    }
    guard let destinationVideoTrack,
          let destinationCaptionTrack else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    destinationVideoTrack.addTrackAssociation(
        to: destinationCaptionTrack,
        type: AVAssetTrack.AssociationType(rawValue: "clcp")
    )
    do {
        try movie.writeHeader(
            to: combinedURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
    } catch {
        throw NSError(
            domain: "MirmirTests.CaptionMux",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Movie-header finalization failed after caption copy.",
                NSUnderlyingErrorKey: error
            ]
        )
    }
    guard Darwin.rename(
        combinedURL.path,
        videoURL.path
    ) == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [
                NSFilePathErrorKey: combinedURL.path
            ]
        )
    }
    let reopenedAsset = AVURLAsset(
        url: videoURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let reopenedVideoTracks = try await reopenedAsset.loadTracks(
        withMediaType: .video
    )
    let reopenedCaptionTracks = try await reopenedAsset.loadTracks(
        withMediaType: .closedCaption
    )
    guard !reopenedVideoTracks.isEmpty,
          reopenedCaptionTracks.count == 1 else {
        throw MediaTestFailure.writerFailed
    }
}

private func writeStandaloneClosedCaptionTrack(
    to url: URL,
    text: String,
    timeRange: CMTimeRange
) async throws {
    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(url: url, fileType: .mov)
    } catch {
        throw MediaTestFailure.cannotCreateWriter
    }
    let input = AVAssetWriterInput(
        mediaType: .closedCaption,
        outputSettings: nil
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    input.languageCode = "eng"
    input.extendedLanguageTag = "en-US"
    let appender: any FixtureCaptionAppender
    if #available(macOS 26.0, *) {
        appender = FixtureCaptionReceiverAppender(
            writer: writer,
            input: input
        )
    } else {
        guard writer.canAdd(input) else {
            throw MediaTestFailure.cannotAddWriterInput
        }
        writer.add(input)
        appender = FixtureLegacyCaptionAppender(
            input: input,
            writer: writer
        )
    }
    guard writer.startWriting() else {
        throw MediaTestFailure.cannotStartWriter
    }
    writer.startSession(atSourceTime: .zero)
    try await appender.append(
        AVCaption(text, timeRange: timeRange)
    )
    appender.finish()
    writer.endSession(atSourceTime: CMTimeRangeGetEnd(timeRange))
    let clock = ContinuousClock()
    try await finishWriting(
        writer,
        deadline: clock.now.advanced(by: mediaFixtureTimeout)
    )
}

private func makeFixtureSubtitleFormatDescription()
    throws -> CMFormatDescription {
    let transparentBlack: [String: Any] = [
        kCMTextFormatDescriptionColor_Red as String:
            NSNumber(value: UInt8(0)),
        kCMTextFormatDescriptionColor_Green as String:
            NSNumber(value: UInt8(0)),
        kCMTextFormatDescriptionColor_Blue as String:
            NSNumber(value: UInt8(0)),
        kCMTextFormatDescriptionColor_Alpha as String:
            NSNumber(value: UInt8(0))
    ]
    let opaqueWhite: [String: Any] = [
        kCMTextFormatDescriptionColor_Red as String:
            NSNumber(value: UInt8.max),
        kCMTextFormatDescriptionColor_Green as String:
            NSNumber(value: UInt8.max),
        kCMTextFormatDescriptionColor_Blue as String:
            NSNumber(value: UInt8.max),
        kCMTextFormatDescriptionColor_Alpha as String:
            NSNumber(value: UInt8.max)
    ]
    let defaultTextBox: [String: Any] = [
        kCMTextFormatDescriptionRect_Top as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionRect_Left as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionRect_Bottom as String:
            NSNumber(value: Int16(1080)),
        kCMTextFormatDescriptionRect_Right as String:
            NSNumber(value: Int16(1920))
    ]
    let defaultStyle: [String: Any] = [
        kCMTextFormatDescriptionStyle_StartChar as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionStyle_EndChar as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionStyle_Font as String:
            NSNumber(value: Int16(1)),
        kCMTextFormatDescriptionStyle_FontFace as String:
            NSNumber(value: UInt8(0)),
        kCMTextFormatDescriptionStyle_FontSize as String:
            NSNumber(value: UInt8(18)),
        kCMTextFormatDescriptionStyle_ForegroundColor as String:
            opaqueWhite
    ]
    let extensions: [String: Any] = [
        kCMTextFormatDescriptionExtension_DisplayFlags as String:
            NSNumber(value: UInt32(0)),
        kCMTextFormatDescriptionExtension_BackgroundColor as String:
            transparentBlack,
        kCMTextFormatDescriptionExtension_DefaultTextBox as String:
            defaultTextBox,
        kCMTextFormatDescriptionExtension_DefaultStyle as String:
            defaultStyle,
        kCMTextFormatDescriptionExtension_HorizontalJustification as String:
            NSNumber(value: Int8(1)),
        kCMTextFormatDescriptionExtension_VerticalJustification as String:
            NSNumber(value: Int8(-1)),
        kCMTextFormatDescriptionExtension_FontTable as String:
            ["1": "Helvetica"]
    ]
    var formatDescription: CMFormatDescription?
    let status = CMFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        mediaType: kCMMediaType_Subtitle,
        mediaSubType: kCMSubtitleFormatType_3GText,
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    return formatDescription
}

private func makeFixtureTextFormatDescription()
    throws -> CMFormatDescription {
    let black: [String: Any] = [
        kCMTextFormatDescriptionColor_Red as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionColor_Green as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionColor_Blue as String:
            NSNumber(value: Int16(0))
    ]
    let white: [String: Any] = [
        kCMTextFormatDescriptionColor_Red as String:
            NSNumber(value: Int16.max),
        kCMTextFormatDescriptionColor_Green as String:
            NSNumber(value: Int16.max),
        kCMTextFormatDescriptionColor_Blue as String:
            NSNumber(value: Int16.max)
    ]
    let defaultTextBox: [String: Any] = [
        kCMTextFormatDescriptionRect_Top as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionRect_Left as String:
            NSNumber(value: Int16(0)),
        kCMTextFormatDescriptionRect_Bottom as String:
            NSNumber(value: Int16(1080)),
        kCMTextFormatDescriptionRect_Right as String:
            NSNumber(value: Int16(1920))
    ]
    let defaultStyle: [String: Any] = [
        kCMTextFormatDescriptionStyle_StartChar as String:
            NSNumber(value: Int32(0)),
        kCMTextFormatDescriptionStyle_Font as String:
            NSNumber(value: Int16(1)),
        kCMTextFormatDescriptionStyle_FontFace as String:
            NSNumber(value: UInt8(0)),
        kCMTextFormatDescriptionStyle_FontSize as String:
            NSNumber(value: Int16(18)),
        kCMTextFormatDescriptionStyle_Height as String:
            NSNumber(value: Int16(18)),
        kCMTextFormatDescriptionStyle_Ascent as String:
            NSNumber(value: Int16(14)),
        kCMTextFormatDescriptionStyle_ForegroundColor as String:
            white
    ]
    let extensions: [String: Any] = [
        kCMTextFormatDescriptionExtension_DisplayFlags as String:
            NSNumber(value: UInt32(0)),
        kCMTextFormatDescriptionExtension_BackgroundColor as String:
            black,
        kCMTextFormatDescriptionExtension_DefaultTextBox as String:
            defaultTextBox,
        kCMTextFormatDescriptionExtension_DefaultStyle as String:
            defaultStyle,
        kCMTextFormatDescriptionExtension_TextJustification as String:
            NSNumber(value: Int32(1)),
        kCMTextFormatDescriptionExtension_DefaultFontName as String:
            "Helvetica",
        kCMTextFormatDescriptionExtension_FontTable as String:
            ["1": "Helvetica"]
    ]
    var formatDescription: CMFormatDescription?
    let status = CMFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        mediaType: kCMMediaType_Text,
        mediaSubType: kCMTextFormatType_QTText,
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    return formatDescription
}

private func makeFixtureTimecodeFormatDescription(
    frameDuration: CMTime
) throws -> CMTimeCodeFormatDescription {
    var formatDescription: CMTimeCodeFormatDescription?
    let roundedFrameQuanta = frameDuration.seconds > 0
        ? Int((1 / frameDuration.seconds).rounded())
        : 0
    guard roundedFrameQuanta > 0,
          roundedFrameQuanta <= Int(UInt32.max) else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    let status = CMTimeCodeFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
        frameDuration: frameDuration,
        frameQuanta: UInt32(roundedFrameQuanta),
        flags: UInt32(kCMTimeCodeFlag_24HourMax),
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        throw MediaTestFailure.cannotAddWriterInput
    }
    return formatDescription
}

private func makeFixtureSubtitleSample(
    text: String,
    duration: CMTime,
    formatDescription: CMFormatDescription
) throws -> CMSampleBuffer {
    let textData = Data(text.utf8)
    guard textData.count <= Int(UInt16.max) else {
        throw MediaTestFailure.appendFailed
    }
    var length = UInt16(textData.count).bigEndian
    var payload = withUnsafeBytes(of: &length) { Data($0) }
    payload.append(textData)
    return try makeFixtureDataSample(
        payload: payload,
        duration: duration,
        formatDescription: formatDescription
    )
}

private func makeFixtureTextSample(
    text: String,
    duration: CMTime,
    formatDescription: CMFormatDescription
) throws -> CMSampleBuffer {
    let textData = Data(text.utf8)
    guard textData.count <= Int(UInt16.max) else {
        throw MediaTestFailure.appendFailed
    }
    var length = UInt16(textData.count).bigEndian
    var payload = withUnsafeBytes(of: &length) { Data($0) }
    payload.append(textData)
    return try makeFixtureDataSample(
        payload: payload,
        duration: duration,
        formatDescription: formatDescription
    )
}

private func makeFixtureTimecodeSample(
    frameNumber: UInt32,
    duration: CMTime,
    formatDescription: CMTimeCodeFormatDescription
) throws -> CMSampleBuffer {
    var bigEndianFrameNumber = frameNumber.bigEndian
    let payload = withUnsafeBytes(of: &bigEndianFrameNumber) {
        Data($0)
    }
    return try makeFixtureDataSample(
        payload: payload,
        duration: duration,
        formatDescription: formatDescription
    )
}

private func makeFixtureDataSample(
    payload: Data,
    duration: CMTime,
    formatDescription: CMFormatDescription
) throws -> CMSampleBuffer {
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: payload.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: payload.count,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
        throw MediaTestFailure.appendFailed
    }
    let copyStatus = payload.withUnsafeBytes { bytes -> OSStatus in
        guard let baseAddress = bytes.baseAddress else {
            return kCMBlockBufferBadPointerParameterErr
        }
        return CMBlockBufferReplaceDataBytes(
            with: baseAddress,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: payload.count
        )
    }
    guard copyStatus == kCMBlockBufferNoErr else {
        throw MediaTestFailure.appendFailed
    }
    var timing = CMSampleTimingInfo(
        duration: duration,
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleSize = payload.count
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
        throw MediaTestFailure.appendFailed
    }
    return sampleBuffer
}

private func appendFixtureSample(
    _ sampleBuffer: CMSampleBuffer,
    to input: AVAssetWriterInput,
    writer: AVAssetWriter,
    clock: ContinuousClock,
    deadline: ContinuousClock.Instant
) async throws {
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
    guard input.append(sampleBuffer) else {
        throw MediaTestFailure.appendFailed
    }
}

private func fillFixturePixelBuffer(
    _ pixelBuffer: CVPixelBuffer
) throws {
    switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        try fillP010(pixelBuffer)
    case kCVPixelFormatType_32BGRA:
        try fillBGRA(pixelBuffer)
    default:
        try fillNV12(pixelBuffer)
    }
}

func fillP010(_ pixelBuffer: CVPixelBuffer) throws {
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else {
        throw MediaTestFailure.appendFailed
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw MediaTestFailure.appendFailed
    }
    let values: [UInt16] = [64 << 6, 512 << 6]
    for planeIndex in 0..<2 {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            planeIndex
        ) else {
            throw MediaTestFailure.appendFailed
        }
        let height = CVPixelBufferGetHeightOfPlane(
            pixelBuffer,
            planeIndex
        )
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            planeIndex
        )
        guard bytesPerRow.isMultiple(of: MemoryLayout<UInt16>.size)
        else {
            throw MediaTestFailure.appendFailed
        }
        for row in 0..<height {
            let words = baseAddress
                .advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            words.update(
                repeating: values[planeIndex],
                count: bytesPerRow / MemoryLayout<UInt16>.size
            )
        }
    }
}

func fillBGRA(_ pixelBuffer: CVPixelBuffer) throws {
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else {
        throw MediaTestFailure.appendFailed
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw MediaTestFailure.appendFailed
    }
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard bytesPerRow.isMultiple(of: 4) else {
        throw MediaTestFailure.appendFailed
    }
    for row in 0..<height {
        let bytes = baseAddress
            .advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: bytesPerRow, by: 4) {
            bytes[offset] = 32
            bytes[offset + 1] = 64
            bytes[offset + 2] = 96
            bytes[offset + 3] = 160
        }
    }
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
