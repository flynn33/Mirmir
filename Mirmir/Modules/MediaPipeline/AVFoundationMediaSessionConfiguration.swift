import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

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
        audioTrack: AVAssetTrack?,
        preserveAudio: Bool
    ) throws -> ReaderOutputs {
        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: PixelBufferBridge.preferredFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw MediaPipelineError.cannotAddReaderOutput("video")
        }
        reader.add(videoOutput)

        let audioOutput = try makeAudioOutput(reader: reader, audioTrack: audioTrack, preserveAudio: preserveAudio)
        return ReaderOutputs(video: videoOutput, audio: audioOutput)
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

    static func makeWriter(outputTransaction: AtomicMediaOutput, outputURL: URL) throws -> AVAssetWriter {
        let fileType: AVFileType
        do {
            fileType = try writerFileType(for: outputURL)
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
                url: outputTransaction.temporaryURL,
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
        sourceResolution: VideoResolution,
        videoTimeScale: CMTimeScale,
        videoTransform: CGAffineTransform,
        audioOutput: AVAssetReaderTrackOutput?,
        audioFormatDescription: CMFormatDescription?
    ) throws -> WriterInputs {
        let outputTransform = try scaledVideoTransform(
            videoTransform,
            sourceResolution: sourceResolution,
            outputResolution: output.resolution
        )
        let videoInput = try makeVideoInput(
            output: output,
            videoTimeScale: videoTimeScale,
            videoTransform: outputTransform
        )
        writer.movieTimeScale = videoTimeScale
        guard writer.canAdd(videoInput) else {
            throw MediaPipelineError.cannotAddWriterInput("video")
        }
        writer.add(videoInput)
        let audioInput = try makeAudioInput(
            writer: writer,
            preserveAudio: output.preserveAudio,
            audioOutput: audioOutput,
            audioFormatDescription: audioFormatDescription
        )
        let timedMetadata = try makeTimedMetadataWriter(
            writer: writer,
            template: output.timedMetadataTemplate,
            mediaTimeScale: videoTimeScale
        )
        return WriterInputs(
            video: videoInput,
            audio: audioInput,
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
              abs(horizontalScale - verticalScale) <= 0.000_001 else {
            throw MediaPipelineError.invalidFrameTiming(
                "output must scale both encoded axes uniformly to preserve orientation"
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
        outputTransaction: AtomicMediaOutput
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
            try outputTransaction.beginWriting()
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            let cleanup = outputTransaction.fail()
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

    private static func makeAudioOutput(
        reader: AVAssetReader,
        audioTrack: AVAssetTrack?,
        preserveAudio: Bool
    ) throws -> AVAssetReaderTrackOutput? {
        guard preserveAudio, let audioTrack else { return nil }
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            throw MediaPipelineError.cannotAddReaderOutput("audio")
        }
        reader.add(audioOutput)
        return audioOutput
    }

    private static func makeVideoInput(
        output: OutputProfile,
        videoTimeScale: CMTimeScale,
        videoTransform: CGAffineTransform
    ) throws -> AVAssetWriterInput {
        guard videoTimeScale > 0 else {
            throw MediaPipelineError.invalidFrameTiming(
                "source video track has a nonpositive natural timescale: \(videoTimeScale)"
            )
        }
        let videoOutputSettings = ProductVideoOutputSettings.make(
            resolution: output.resolution,
            codec: output.codec
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
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

    private static func makeAudioInput(
        writer: AVAssetWriter,
        preserveAudio: Bool,
        audioOutput: AVAssetReaderTrackOutput?,
        audioFormatDescription: CMFormatDescription?
    ) throws -> AVAssetWriterInput? {
        guard preserveAudio, audioOutput != nil else { return nil }
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: audioFormatDescription
        )
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            throw MediaPipelineError.cannotAddWriterInput("audio")
        }
        writer.add(audioInput)
        return audioInput
    }

}

struct ReaderOutputs {
    let video: AVAssetReaderTrackOutput
    let audio: AVAssetReaderTrackOutput?
}

struct WriterInputs {
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
    let timedMetadata: TimedMetadataWriter?
    let videoTransform: CGAffineTransform
}

struct TimedMetadataWriter {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputMetadataAdaptor
    let expectedKeys: Set<String>
}
