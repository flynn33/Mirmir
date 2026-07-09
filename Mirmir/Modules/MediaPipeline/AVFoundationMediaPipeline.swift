import Foundation
import AVFoundation
import AudioToolbox
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
        let size = try await videoTrack.load(.naturalSize)
        let fps = Double(try await videoTrack.load(.nominalFrameRate))
        let formats = try await videoTrack.load(.formatDescriptions)
        try Self.validateSupportedColorProfile(track: videoTrack, formats: formats)
        let durationCM = try await asset.load(.duration)
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty

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
        try await AVFoundationMediaSession.make(metal: metal, source: source, output: output)
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

    fileprivate static func validateSupportedColorProfile(
        track: AVAssetTrack,
        formats: [CMFormatDescription]
    ) throws {
        var unsupportedValues: [String] = []
        if track.hasMediaCharacteristic(.containsHDRVideo) {
            unsupportedValues.append("HDR")
        }

        let expectedValues: [(CFString, CFString, String)] = [
            (
                kCMFormatDescriptionExtension_ColorPrimaries,
                kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
                "primaries"
            ),
            (
                kCMFormatDescriptionExtension_TransferFunction,
                kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                "transfer"
            ),
            (
                kCMFormatDescriptionExtension_YCbCrMatrix,
                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
                "matrix"
            )
        ]

        for format in formats {
            let extensions = CMFormatDescriptionGetExtensions(format) as NSDictionary
            for (key, expected, label) in expectedValues {
                guard let observed = extensions[key] as? String else { continue }
                let expectedString = expected as String
                if observed != expectedString {
                    unsupportedValues.append("\(label)=\(observed)")
                }
            }
        }

        guard unsupportedValues.isEmpty else {
            throw MediaPipelineError.unsupportedColorProfile(
                Array(Set(unsupportedValues)).sorted().joined(separator: ", ")
            )
        }
    }
}

final class AtomicMediaOutput: @unchecked Sendable {
    let destinationURL: URL
    let temporaryURL: URL

    init(destinationURL: URL, fileManager: FileManager = .default) throws {
        self.destinationURL = destinationURL
        let directory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard destinationURL.isFileURL,
              fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }

        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        let pathExtension = destinationURL.pathExtension
        let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        self.temporaryURL = directory.appendingPathComponent(
            ".\(baseName).mirmir-\(UUID().uuidString).partial\(extensionSuffix)",
            isDirectory: false
        )
    }

    func commit(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func discard(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: temporaryURL)
    }

    deinit {
        discard()
    }
}

final class AVFoundationMediaSession: MediaSession, @unchecked Sendable {
    private enum LifecycleState {
        case active
        case cancelled
        case committed
    }


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
    private let outputTransaction: AtomicMediaOutput
    private let lifecycleLock = NSLock()

    private var frameIndex = 0
    private var lifecycleState = LifecycleState.active

    static func make(
        metal: MetalRenderingService,
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> AVFoundationMediaSession {
        let asset = AVURLAsset(url: source.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw MediaPipelineError.noVideoTrack(source.url)
        }
        let videoTransform = try await videoTrack.load(.preferredTransform)
        let videoFormats = try await videoTrack.load(.formatDescriptions)
        try AVFoundationMediaPipeline.validateSupportedColorProfile(
            track: videoTrack,
            formats: videoFormats
        )
        let audioTracks = output.preserveAudio
            ? try await asset.loadTracks(withMediaType: .audio)
            : []
        guard audioTracks.count <= 1 else {
            throw MediaPipelineError.unsupportedAudioTrackCount(audioTracks.count)
        }
        let audioTrack = audioTracks.first
        let audioFormatDescription: CMFormatDescription?
        if let audioTrack {
            audioFormatDescription = try await audioTrack.load(.formatDescriptions).first
            if let audioFormatDescription {
                let subtype = CMFormatDescriptionGetMediaSubType(audioFormatDescription)
                guard subtype == kAudioFormatMPEG4AAC else {
                    throw MediaPipelineError.unsupportedAudioFormat(String(format: "0x%08x", subtype))
                }
            }
        } else {
            audioFormatDescription = nil
        }

        return try AVFoundationMediaSession(
            metal: metal,
            source: source,
            output: output,
            asset: asset,
            videoTrack: videoTrack,
            videoTransform: videoTransform,
            audioTrack: audioTrack,
            audioFormatDescription: audioFormatDescription
        )
    }

    private init(
        metal: MetalRenderingService,
        source: SourceProfile,
        output: OutputProfile,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        videoTransform: CGAffineTransform,
        audioTrack: AVAssetTrack?,
        audioFormatDescription: CMFormatDescription?
    ) throws {
        guard !FileURLIdentity.refersToSameFile(source.url, output.url) else {
            throw MediaPipelineError.inputOutputCollision(source.url)
        }
        self.sourceProfile = source
        self.outputProfile = output
        self.asset = asset

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
        guard reader.canAdd(videoOutput) else {
            throw MediaPipelineError.cannotAddReaderOutput("video")
        }
        reader.add(videoOutput)

        if output.preserveAudio, let audioTrack {
            let audioReaderSettings: [String: Any] = [:]
            let audioTrackOutput = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: audioReaderSettings.isEmpty ? nil : audioReaderSettings
            )
            audioTrackOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(audioTrackOutput) else {
                throw MediaPipelineError.cannotAddReaderOutput("audio")
            }
            reader.add(audioTrackOutput)
            self.audioOutput = audioTrackOutput
        } else {
            self.audioOutput = nil
        }

        do {
            self.outputTransaction = try AtomicMediaOutput(destinationURL: output.url)
        } catch {
            throw MediaPipelineError.outputPreparationFailed(output.url, error)
        }
        do {
            self.writer = try AVAssetWriter(url: outputTransaction.temporaryURL, fileType: .mp4)
        } catch {
            outputTransaction.discard()
            throw MediaPipelineError.writerCreationFailed(output.url, error)
        }
        writer.metadata = Self.makeASHMetadataItems()

        let bitRate = AVFoundationMediaSession.estimateBitRate(for: output.resolution, codec: output.codec)
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
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = videoTransform

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
        guard writer.canAdd(videoInput) else {
            throw MediaPipelineError.cannotAddWriterInput("video")
        }
        writer.add(videoInput)

        if output.preserveAudio, audioOutput != nil {
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
            self.audioInput = audioInput
        } else {
            self.audioInput = nil
        }

        self.outputPixelBufferPool = try PixelBufferBridge.makePool(
            width: output.resolution.width,
            height: output.resolution.height,
            capacity: 8
        )

        guard reader.startReading() else {
            discardWorkingOutput()
            throw MediaPipelineError.readerStartFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            discardWorkingOutput()
            throw MediaPipelineError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        // Loop (not recurse) over marker / metadata sample buffers without
        // image buffers — recursion would risk stack overflow on long
        // sequences.
        while !sessionIsCancelled() {
            try Task.checkCancellation()
            guard let sample = videoOutput.copyNextSampleBuffer() else {
                if let error = reader.error {
                    throw MediaPipelineError.readerFailed(error)
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
            if sessionIsCancelled() { throw CancellationError() }
        }
        try Task.checkCancellation()
        if sessionIsCancelled() { throw CancellationError() }
        if !videoAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            throw MediaPipelineError.writerFailed(writer.error)
        }
    }

    func finish() async throws {
        try Task.checkCancellation()
        if sessionIsCancelled() { throw CancellationError() }
        // Drain audio (passthrough) before finalizing. .cancelled is treated
        // separately from .failed (see post-finish check below).
        if let audioOutput, let audioInput {
            do {
                while let sample = audioOutput.copyNextSampleBuffer() {
                    while !audioInput.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 1_000_000)
                        if sessionIsCancelled() { throw CancellationError() }
                    }
                    try Task.checkCancellation()
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
            do {
                try commitOutput()
                return
            } catch {
                discardWorkingOutput()
                throw MediaPipelineError.outputPreparationFailed(outputProfile.url, error)
            }
        case .cancelled:
            discardWorkingOutput()
            throw CancellationError()
        case .failed, .unknown, .writing:
            throw MediaPipelineError.writerFailed(writer.error)
        @unknown default:
            throw MediaPipelineError.writerFailed(writer.error)
        }
    }

    func cancel() {
        var shouldCancelResources = false
        var shouldDiscardOutput = false

        lifecycleLock.lock()
        switch lifecycleState {
        case .active:
            lifecycleState = .cancelled
            shouldCancelResources = true
            shouldDiscardOutput = true
        case .cancelled:
            shouldDiscardOutput = true
        case .committed:
            break
        }
        lifecycleLock.unlock()

        if shouldCancelResources {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        if shouldDiscardOutput {
            discardWorkingOutput()
        }
    }

    deinit {
        discardWorkingOutput()
    }

    private func commitOutput() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard case .active = lifecycleState else {
            throw CancellationError()
        }
        try outputTransaction.commit()
        lifecycleState = .committed
    }

    private func discardWorkingOutput() {
        outputTransaction.discard()
    }

    private func sessionIsCancelled() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard case .cancelled = lifecycleState else { return false }
        return true
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

    private static func makeASHMetadataItems() -> [AVMetadataItem] {
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
}
