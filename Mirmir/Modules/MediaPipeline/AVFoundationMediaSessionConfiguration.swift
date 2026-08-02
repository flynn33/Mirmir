import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation

enum ExactVideoWriterTimeScale {
    static func resolve(
        naturalTimeScale: CMTimeScale,
        trackTimeRange: CMTimeRange
    ) throws -> CMTimeScale {
        let start = trackTimeRange.start
        let end = CMTimeRangeGetEnd(trackTimeRange)
        guard naturalTimeScale > 0,
              trackTimeRange.isValid,
              start.isNumeric,
              end.isNumeric,
              start.timescale > 0,
              end.timescale > 0 else {
            throw MediaPipelineError.unrepresentableVideoTimeline(
                naturalTimeScale: naturalTimeScale,
                start: start,
                end: end
            )
        }

        var resolved = UInt64(naturalTimeScale)
        for boundary in [start, end] {
            let boundaryScale = UInt64(boundary.timescale)
            let reducedDenominator = boundaryScale
                / greatestCommonDivisor(
                    boundary.value.magnitude,
                    boundaryScale
                )
            let commonDivisor = greatestCommonDivisor(
                resolved,
                reducedDenominator
            )
            let multiplier = reducedDenominator / commonDivisor
            guard resolved <= UInt64(CMTimeScale.max) / multiplier else {
                throw MediaPipelineError.unrepresentableVideoTimeline(
                    naturalTimeScale: naturalTimeScale,
                    start: start,
                    end: end
                )
            }
            resolved *= multiplier
        }

        return CMTimeScale(resolved)
    }

    static func commonScale(_ scales: [CMTimeScale]) throws -> CMTimeScale {
        guard !scales.isEmpty, scales.allSatisfy({ $0 > 0 }) else {
            throw MediaPipelineError.invalidFrameTiming(
                "final movie track timescales must be positive"
            )
        }
        var resolved = UInt64(1)
        for scale in scales {
            let candidate = UInt64(scale)
            let commonDivisor = greatestCommonDivisor(resolved, candidate)
            let multiplier = candidate / commonDivisor
            guard resolved <= UInt64(CMTimeScale.max) / multiplier else {
                throw MediaPipelineError.invalidFrameTiming(
                    "final movie track timescales have no representable common scale"
                )
            }
            resolved *= multiplier
        }
        return CMTimeScale(resolved)
    }

    static func commonBoundaryScale(
        _ timeRanges: [CMTimeRange]
    ) throws -> CMTimeScale {
        guard !timeRanges.isEmpty else {
            throw MediaPipelineError.invalidFrameTiming(
                "final movie must contain at least one track time range"
            )
        }
        var resolved = UInt64(1)
        for timeRange in timeRanges {
            let start = timeRange.start
            let end = CMTimeRangeGetEnd(timeRange)
            guard timeRange.isValid,
                  start.isNumeric,
                  end.isNumeric,
                  start.timescale > 0,
                  end.timescale > 0 else {
                throw MediaPipelineError.invalidFrameTiming(
                    "final movie track boundaries must be numeric"
                )
            }
            for boundary in [start, end] {
                let boundaryScale = UInt64(boundary.timescale)
                let reducedDenominator = boundaryScale
                    / greatestCommonDivisor(
                        boundary.value.magnitude,
                        boundaryScale
                    )
                let commonDivisor = greatestCommonDivisor(
                    resolved,
                    reducedDenominator
                )
                let multiplier = reducedDenominator / commonDivisor
                guard resolved
                    <= UInt64(CMTimeScale.max) / multiplier else {
                    throw MediaPipelineError.invalidFrameTiming(
                        "final movie boundaries have no representable common scale"
                    )
                }
                resolved *= multiplier
            }
        }
        return CMTimeScale(resolved)
    }

    private static func greatestCommonDivisor(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        var lhs = lhs
        var rhs = rhs
        while rhs != 0 {
            (lhs, rhs) = (rhs, lhs % rhs)
        }
        return lhs
    }
}

extension AVFoundationMediaSession {
    static func makeReader(asset: AVURLAsset, sourceURL: URL) throws -> AVAssetReader {
        do {
            return try AVAssetReader(asset: asset)
        } catch {
            throw MediaPipelineError.readerCreationFailed(sourceURL, error)
        }
    }

    static func configureReaderOutputs(
        reader: AVAssetReader,
        videoTrack: AVAssetTrack,
        videoFormat: MediaVideoFormat
    ) throws -> ReaderOutputs {
        var videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                videoFormat.pixelStorage.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        if videoFormat.pixelStorage.bitDepth > 8
            || videoFormat.colorPrimaries == .bt2020
            || videoFormat.isHDR {
            videoSettings[AVVideoAllowWideColorKey] = true
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(videoOutput) else {
            throw MediaPipelineError.cannotAddReaderOutput("video")
        }
        reader.add(videoOutput)
        return ReaderOutputs(video: videoOutput)
    }

    static func makeOutputTransaction(
        outputURL: URL,
        transactionIdentifier: String
    ) throws -> AtomicMediaOutput {
        do {
            return try AtomicMediaOutput(
                destinationURL: outputURL,
                temporaryIdentifier: transactionIdentifier
            )
        } catch {
            throw MediaPipelineError.outputPreparationFailed(outputURL, error)
        }
    }

    static func makeWriter(
        outputTransaction: AtomicMediaOutput,
        stagingFile: MediaPipelineStagingFile,
        outputURL: URL,
        videoFormat: MediaVideoFormat
    ) throws -> AVAssetWriter {
        let fileType: AVFileType
        do {
            let finalFileType = try writerFileType(for: outputURL)
            fileType = videoFormat.hasAlpha
                || videoFormat.requiresQuickTimeMovieOutput
                ? .mov
                : finalFileType
        } catch {
            let cleanup = outputTransaction.fail()
            if let cleanupError = cleanup.error {
                throw MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
            }
            throw error
        }
        do {
            return try AVAssetWriter(
                url: stagingFile.url,
                fileType: fileType
            )
        } catch {
            let cleanup = outputTransaction.fail()
            if let cleanupError = cleanup.error {
                throw MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
            }
            throw MediaPipelineError.writerCreationFailed(outputURL, error)
        }
    }

    static func makeStagingFile(
        outputTransaction: AtomicMediaOutput,
        outputURL: URL,
        videoFormat: MediaVideoFormat
    ) throws -> MediaPipelineStagingFile {
        do {
            return try MediaPipelineStagingFile(
                finalTemporaryURL: outputTransaction.temporaryURL,
                pathExtensionOverride: videoFormat.hasAlpha
                    || videoFormat.requiresQuickTimeMovieOutput
                    ? "mov"
                    : nil,
                fileSystem:
                    outputTransaction.fileSystemForSiblingTemporaryFiles
            )
        } catch {
            let cleanup = outputTransaction.fail()
            if let cleanupError = cleanup.error {
                throw MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
            }
            throw MediaPipelineError.outputPreparationFailed(
                outputURL,
                error
            )
        }
    }

    static func writerFileType(for outputURL: URL) throws -> AVFileType {
        let pathExtension = outputURL.pathExtension.lowercased()
        switch pathExtension {
        case "mp4":
            return .mp4
        case "mov":
            return .mov
        default:
            throw MediaPipelineError.unsupportedOutputContainer(pathExtension)
        }
    }

    static func configureWriterInputs(
        writer: AVAssetWriter,
        output: OutputProfile,
        videoFormat: MediaVideoFormat,
        sourceResolution: VideoResolution,
        videoTimeScale: CMTimeScale,
        videoTransform: CGAffineTransform
    ) throws -> WriterInputs {
        let outputTransform = try scaledVideoTransform(
            videoTransform,
            sourceResolution: sourceResolution,
            outputResolution: output.resolution
        )
        let videoOutputSettings = ProductVideoOutputSettings.make(
            resolution: output.resolution,
            codec: output.codec,
            videoFormat: videoFormat
        )
        guard writer.canApply(
            outputSettings: videoOutputSettings,
            forMediaType: .video
        ) else {
            throw MediaPipelineError.outputEncoderUnavailable(
                codec: output.codec,
                format: videoFormat
            )
        }
        let videoInput = try makeVideoInput(
            outputSettings: videoOutputSettings,
            videoTimeScale: videoTimeScale,
            videoTransform: outputTransform
        )
        writer.movieTimeScale = videoTimeScale
        guard writer.canAdd(videoInput) else {
            throw MediaPipelineError.cannotAddWriterInput("video")
        }
        writer.add(videoInput)
        let timedMetadata = try makeTimedMetadataWriter(
            writer: writer,
            template: output.timedMetadataTemplate,
            mediaTimeScale: videoTimeScale
        )
        return WriterInputs(
            video: videoInput,
            timedMetadata: timedMetadata,
            videoTransform: outputTransform
        )
    }

    static func scaledVideoTransform(
        _ transform: CGAffineTransform,
        sourceResolution: VideoResolution,
        outputResolution: VideoResolution
    ) throws -> CGAffineTransform {
        guard sourceResolution.width > 0,
              sourceResolution.height > 0 else {
            throw MediaPipelineError.invalidFrameTiming(
                "source encoded dimensions must be positive"
            )
        }
        let horizontalScale = CGFloat(outputResolution.width)
            / CGFloat(sourceResolution.width)
        let verticalScale = CGFloat(outputResolution.height)
            / CGFloat(sourceResolution.height)
        guard horizontalScale.isFinite,
              verticalScale.isFinite,
              R13AspectRatioContract.preservesWithinOneOutputPixel(
                  source: sourceResolution,
                  target: outputResolution
              ) else {
            throw MediaPipelineError.invalidFrameTiming(
                "output aspect must preserve source geometry within one pixel"
            )
        }
        return CGAffineTransform(
            a: transform.a,
            b: transform.b,
            c: transform.c,
            d: transform.d,
            tx: transform.tx * horizontalScale,
            ty: transform.ty * verticalScale
        )
    }

    static func start(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        outputTransaction: AtomicMediaOutput,
        stagingFile: MediaPipelineStagingFile
    ) throws {
        guard reader.startReading() else {
            let cleanup = outputTransaction.fail()
            if let cleanupError = cleanup.error {
                throw MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
            }
            throw MediaPipelineError.readerStartFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            let cleanup = outputTransaction.fail()
            if let cleanupError = cleanup.error {
                throw MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
            }
            throw MediaPipelineError.writerStartFailed
        }
        do {
            try stagingFile.claimCreatedFileIfNeeded()
            try outputTransaction.beginWriting()
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            let stagingError = stagingFile.cleanup()
            let cleanup = outputTransaction.fail()
            if let stagingError {
                throw MediaPipelineError.partialCleanupFailed(
                    stagingFile.url,
                    String(describing: stagingError)
                )
            }
            if let cleanupError = cleanup.error {
                throw MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
            }
            throw error
        }
    }

    static func makeASHMetadataItems(
        _ metadata: [String: String] = ASHSpatialRuntimeConfigurationV2
            .developmentP05
            .outputMetadata
    ) -> [AVMetadataItem] {
        metadata
            .sorted { $0.key < $1.key }
            .map { key, value -> AVMetadataItem in
                let item = AVMutableMetadataItem()
                item.keySpace = .quickTimeMetadata
                item.key = key as NSString
                item.value = value as NSString
                item.dataType = kCMMetadataBaseDataType_UTF8 as String
                return item
            }
    }

    static func makeASHMetadataGroup(
        _ metadata: [String: String],
        timeRange: CMTimeRange
    ) -> AVTimedMetadataGroup {
        AVTimedMetadataGroup(
            items: makeASHMetadataItems(metadata),
            timeRange: timeRange
        )
    }

    private static func makeTimedMetadataWriter(
        writer: AVAssetWriter,
        template: [String: String],
        mediaTimeScale: CMTimeScale
    ) throws -> TimedMetadataWriter? {
        guard !template.isEmpty else { return nil }
        try MirmirTimedMetadataPolicy.validate(template)
        let templateGroup = makeASHMetadataGroup(
            template,
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(value: 1, timescale: 1)
            )
        )
        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: templateGroup.copyFormatDescription()
        )
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = mediaTimeScale
        guard writer.canAdd(input) else {
            throw MediaPipelineError.cannotAddWriterInput("Mirmir identity metadata")
        }
        writer.add(input)
        return TimedMetadataWriter(
            input: input,
            adaptor: AVAssetWriterInputMetadataAdaptor(assetWriterInput: input),
            expectedKeys: Set(template.keys)
        )
    }

    private static func makeVideoInput(
        outputSettings: [String: Any],
        videoTimeScale: CMTimeScale,
        videoTransform: CGAffineTransform
    ) throws -> AVAssetWriterInput {
        guard videoTimeScale > 0 else {
            throw MediaPipelineError.invalidFrameTiming(
                "source video track has a nonpositive natural timescale: \(videoTimeScale)"
            )
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = videoTimeScale
        videoInput.transform = videoTransform
        return videoInput
    }

    static func makeVideoSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        timing: FrameTiming
    ) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw MediaPipelineError.writerFailed(
                NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(formatStatus)
                )
            )
        }
        var sampleTiming = CMSampleTimingInfo(
            duration: timing.duration,
            presentationTimeStamp: timing.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &sampleTiming,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw MediaPipelineError.writerFailed(
                NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(sampleStatus)
                )
            )
        }
        return sampleBuffer
    }

}

struct ReaderOutputs {
    let video: AVAssetReaderTrackOutput
}

struct WriterInputs {
    let video: AVAssetWriterInput
    let timedMetadata: TimedMetadataWriter?
    let videoTransform: CGAffineTransform
}

struct TimedMetadataWriter {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputMetadataAdaptor
    let expectedKeys: Set<String>
}

final class MediaPipelineStagingFile: @unchecked Sendable {
    enum Role: String {
        case videoStage = "video-stage"
        case finalMuxSource = "final-mux-source"
        case sourceSeed = "source-seed"
    }

    private enum StagingFileError: Error, CustomStringConvertible {
        case createdFileMissing
        case unownedPathPreserved
        case cleanupFailed(attempts: Int, underlying: Error?)

        var description: String {
            switch self {
            case .createdFileMissing:
                return "The transaction staging file was not created."
            case .unownedPathPreserved:
                return "A staging path not owned by this attempt was preserved."
            case .cleanupFailed(let attempts, let underlying):
                return "The transaction staging file could not be removed after "
                    + "\(attempts) attempts: "
                    + "\(underlying.map(String.init(describing:)) ?? "file remained")."
            }
        }
    }

    let url: URL

    private static let cleanupAttemptLimit = 3
    private let fileSystem: any AtomicMediaFileSystem
    private let lock = NSLock()
    private var ownedFile: AtomicMediaVerifiedTemporaryFile?
    private var wasRemoved = false

    init(
        finalTemporaryURL: URL,
        pathExtensionOverride: String? = nil,
        role: Role = .videoStage,
        fileSystem: any AtomicMediaFileSystem =
            LocalAtomicMediaFileSystem()
    ) throws {
        let directory = finalTemporaryURL.deletingLastPathComponent()
        let pathExtension = pathExtensionOverride
            ?? finalTemporaryURL.pathExtension
        let extensionSuffix = pathExtension.isEmpty
            ? ""
            : ".\(pathExtension)"
        let baseName = finalTemporaryURL
            .deletingPathExtension()
            .lastPathComponent
        url = directory.appendingPathComponent(
            "\(baseName).\(role.rawValue)\(extensionSuffix)",
            isDirectory: false
        )
        self.fileSystem = fileSystem
        try fileSystem.reclaimTransactionTemporaryFile(at: url)
    }

    func claimCreatedFileIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if ownedFile != nil {
            return
        }
        guard fileSystem.pathEntryExists(at: url) else {
            throw StagingFileError.createdFileMissing
        }
        ownedFile = try AtomicMediaVerifiedTemporaryFile(
            url: url,
            requirePopulatedFile: false
        )
    }

    func cleanup() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if wasRemoved {
            return nil
        }
        guard fileSystem.pathEntryExists(at: url) else {
            wasRemoved = true
            return nil
        }
        guard let ownedFile else {
            return StagingFileError.unownedPathPreserved
        }
        let identity: AtomicMediaPinnedFileIdentity
        do {
            identity = try ownedFile.makePinnedFileIdentity()
        } catch {
            return error
        }
        var lastError: Error?
        for _ in 0..<Self.cleanupAttemptLimit {
            do {
                guard fileSystem.pathEntryExists(at: url) else {
                    wasRemoved = true
                    return nil
                }
                try fileSystem.removeItem(
                    at: url,
                    ifMatchingFile: identity
                )
                guard !fileSystem.pathEntryExists(at: url) else {
                    continue
                }
                wasRemoved = true
                return nil
            } catch {
                lastError = error
            }
        }
        return StagingFileError.cleanupFailed(
            attempts: Self.cleanupAttemptLimit,
            underlying: lastError
        )
    }

    deinit {
        _ = cleanup()
    }
}

// Exact writer setup and its owned staging-file lifecycle form one transaction.
// swiftlint:disable:this file_length
