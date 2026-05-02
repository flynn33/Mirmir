import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

final class AVFoundationMediaPipeline: MediaPipelineService, @unchecked Sendable {

    private let metal: MetalRenderingService

    init(metal: MetalRenderingService) {
        self.metal = metal
    }

    func start() {}
    func stop() {}

    func probe(url: URL) async throws -> SourceProfile {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MediaPipelineError.noVideoTrack(url)
        }
        async let naturalSize = videoTrack.load(.naturalSize)
        async let frameRate = videoTrack.load(.nominalFrameRate)
        async let formatDescriptions = videoTrack.load(.formatDescriptions)
        async let duration = asset.load(.duration)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)

        let size = try await naturalSize
        let fps = Double(try await frameRate)
        let durationCM = try await duration
        let formats = try await formatDescriptions
        let hasAudio = !(try await audioTracks).isEmpty

        let resolution = VideoResolution(
            width: Int(abs(size.width).rounded()),
            height: Int(abs(size.height).rounded())
        )

        let codecHint: String? = formats.first.map { desc in
            let fourCC = CMFormatDescriptionGetMediaSubType(desc)
            return Self.fourCCString(fourCC)
        }

        let durationSeconds = CMTimeGetSeconds(durationCM).isFinite ? CMTimeGetSeconds(durationCM) : 0
        let estimatedFrameCount = Int((durationSeconds * fps).rounded())

        return SourceProfile(
            url: url,
            resolution: resolution,
            frameRate: fps,
            durationSeconds: durationSeconds,
            estimatedFrameCount: max(estimatedFrameCount, 0),
            codecHint: codecHint,
            hasAudio: hasAudio
        )
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        try AVFoundationMediaSession(metal: metal, source: source, output: output)
    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

final class AVFoundationMediaSession: MediaSession, @unchecked Sendable {

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let outputPixelBufferPool: CVPixelBufferPool

    private let asset: AVURLAsset
    private let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    private let audioOutput: AVAssetReaderTrackOutput?

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?

    private var frameIndex = 0
    private var isCancelled = false

    init(metal: MetalRenderingService, source: SourceProfile, output: OutputProfile) throws {
        self.sourceProfile = source
        self.outputProfile = output

        let asset = AVURLAsset(url: source.url)
        self.asset = asset

        let videoTracks = asset.tracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MediaPipelineError.noVideoTrack(source.url)
        }

        do {
            self.reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaPipelineError.readerCreationFailed(source.url, error)
        }

        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: PixelBufferBridge.preferredFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        self.videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoSettings)
        videoOutput.alwaysCopiesSampleData = false
        if reader.canAdd(videoOutput) {
            reader.add(videoOutput)
        }

        if output.preserveAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioReaderSettings: [String: Any] = [:]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioReaderSettings.isEmpty ? nil : audioReaderSettings)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
            }
            self.audioOutput = output
        } else {
            self.audioOutput = nil
        }

        if FileManager.default.fileExists(atPath: output.url.path) {
            try? FileManager.default.removeItem(at: output.url)
        }
        do {
            self.writer = try AVAssetWriter(url: output.url, fileType: .mp4)
        } catch {
            throw MediaPipelineError.writerCreationFailed(output.url, error)
        }

        let bitRate = AVFoundationMediaSession.estimateBitRate(for: output.resolution, codec: output.codec)
        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: NSNumber(value: bitRate)
        ]
        let videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: output.codec.avCodecKey,
            AVVideoWidthKey: NSNumber(value: output.resolution.width),
            AVVideoHeightKey: NSNumber(value: output.resolution.height),
            AVVideoCompressionPropertiesKey: videoCompression
        ]
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: PixelBufferBridge.preferredFormat,
            kCVPixelBufferWidthKey as String: NSNumber(value: output.resolution.width),
            kCVPixelBufferHeightKey as String: NSNumber(value: output.resolution.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        self.videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )
        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }

        if output.preserveAudio, let _ = audioOutput {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            audioInput.expectsMediaDataInRealTime = false
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            } else {
                self.audioInput = nil
            }
        } else {
            self.audioInput = nil
        }

        self.outputPixelBufferPool = try PixelBufferBridge.makePool(
            width: output.resolution.width,
            height: output.resolution.height,
            capacity: 8
        )

        guard reader.startReading() else {
            throw MediaPipelineError.readerStartFailed
        }
        guard writer.startWriting() else {
            throw MediaPipelineError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        // Loop (not recurse) over marker / metadata sample buffers without
        // image buffers — recursion would risk stack overflow on long
        // sequences.
        while !isCancelled {
            guard let sample = videoOutput.copyNextSampleBuffer() else {
                if let error = reader.error {
                    throw MediaPipelineError.writerFailed(error)
                }
                return nil
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let record = FrameRecord(pixelBuffer: buffer, presentationTime: pts, frameIndex: frameIndex)
            frameIndex += 1
            return record
        }
        return nil
    }

    func appendOutput(pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) async throws {
        while !videoInput.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
            if isCancelled { return }
        }
        if !videoAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            throw MediaPipelineError.writerFailed(writer.error)
        }
    }

    func finish() async throws {
        if isCancelled { return }
        // Drain audio (passthrough) before finalizing. .cancelled is treated
        // separately from .failed (see post-finish check below).
        if let audioOutput, let audioInput {
            do {
                while let sample = audioOutput.copyNextSampleBuffer() {
                    while !audioInput.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 1_000_000)
                        if isCancelled { return }
                    }
                    if !audioInput.append(sample) {
                        throw MediaPipelineError.audioBridgeFailed(writer.error ?? NSError(domain: "Audio", code: -1))
                    }
                }
                audioInput.markAsFinished()
            } catch let error as MediaPipelineError {
                throw error
            } catch {
                throw MediaPipelineError.audioBridgeFailed(error)
            }
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        switch writer.status {
        case .completed:
            return
        case .cancelled:
            // The writer was explicitly cancelled (typically by `cancel()`
            // racing with `finish()`). Not an error — leave the partial file
            // for the caller to clean up.
            return
        case .failed, .unknown, .writing:
            throw MediaPipelineError.writerFailed(writer.error)
        @unknown default:
            throw MediaPipelineError.writerFailed(writer.error)
        }
    }

    func cancel() {
        isCancelled = true
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
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
