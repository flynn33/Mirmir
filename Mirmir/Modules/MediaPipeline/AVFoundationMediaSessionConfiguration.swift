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

    static func makeOutputTransaction(outputURL: URL) throws -> AtomicMediaOutput {
        do {
            return try AtomicMediaOutput(destinationURL: outputURL)
        } catch {
            throw MediaPipelineError.outputPreparationFailed(outputURL, error)
        }
    }

    static func makeWriter(outputTransaction: AtomicMediaOutput, outputURL: URL) throws -> AVAssetWriter {
        do {
            return try AVAssetWriter(url: outputTransaction.temporaryURL, fileType: .mp4)
        } catch {
            outputTransaction.discard()
            throw MediaPipelineError.writerCreationFailed(outputURL, error)
        }
    }

    static func configureWriterInputs(
        writer: AVAssetWriter,
        output: OutputProfile,
        videoTransform: CGAffineTransform,
        audioOutput: AVAssetReaderTrackOutput?,
        audioFormatDescription: CMFormatDescription?
    ) throws -> WriterInputs {
        let videoInput = makeVideoInput(output: output, videoTransform: videoTransform)
        let adaptor = makeVideoAdaptor(videoInput: videoInput, resolution: output.resolution)
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
        return WriterInputs(video: videoInput, adaptor: adaptor, audio: audioInput)
    }

    static func start(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        outputTransaction: AtomicMediaOutput
    ) throws {
        guard reader.startReading() else {
            outputTransaction.discard()
            throw MediaPipelineError.readerStartFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            outputTransaction.discard()
            throw MediaPipelineError.writerStartFailed
        }
    }

    static func makeASHMetadataItems() -> [AVMetadataItem] {
        ASHRuntimeConfiguration.current.outputMetadata
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
        videoTransform: CGAffineTransform
    ) -> AVAssetWriterInput {
        let bitRate = estimateBitRate(for: output.resolution, codec: output.codec)
        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: NSNumber(value: bitRate)
        ]
        let videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: output.codec.avCodecKey,
            AVVideoWidthKey: NSNumber(value: output.resolution.width),
            AVVideoHeightKey: NSNumber(value: output.resolution.height),
            AVVideoCompressionPropertiesKey: videoCompression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = videoTransform
        return videoInput
    }

    private static func makeVideoAdaptor(
        videoInput: AVAssetWriterInput,
        resolution: VideoResolution
    ) -> AVAssetWriterInputPixelBufferAdaptor {
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: PixelBufferBridge.preferredFormat,
            kCVPixelBufferWidthKey as String: NSNumber(value: resolution.width),
            kCVPixelBufferHeightKey as String: NSNumber(value: resolution.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        return AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )
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

    private static func estimateBitRate(for resolution: VideoResolution, codec: OutputCodec) -> Int {
        let pixels = resolution.width * resolution.height
        let bppFactor: Double
        switch codec {
        case .hevc: bppFactor = 0.10
        case .h264: bppFactor = 0.15
        }
        return max(2_000_000, Int(Double(pixels) * 30 * bppFactor))
    }
}

struct ReaderOutputs {
    let video: AVAssetReaderTrackOutput
    let audio: AVAssetReaderTrackOutput?
}

struct WriterInputs {
    let video: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let audio: AVAssetWriterInput?
}
