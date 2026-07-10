import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo

final class AVFoundationMediaPipeline: MediaPipelineService, @unchecked Sendable {

    private let metal: MetalRenderingService
    private static let expectedColorMetadata = [
        ExpectedColorMetadata(
            key: kCMFormatDescriptionExtension_ColorPrimaries as String,
            expected: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
            label: "primaries"
        ),
        ExpectedColorMetadata(
            key: kCMFormatDescriptionExtension_TransferFunction as String,
            expected: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
            label: "transfer"
        ),
        ExpectedColorMetadata(
            key: kCMFormatDescriptionExtension_YCbCrMatrix as String,
            expected: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
            label: "matrix"
        )
    ]

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
        try await Self.validateSupportedColorProfile(track: videoTrack, formats: formats)
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
    ) async throws {
        var unsupportedValues: [String] = []
        let mediaCharacteristics = try await track.load(.mediaCharacteristics)
        if mediaCharacteristics.contains(.containsHDRVideo) {
            unsupportedValues.append("HDR")
        }

        for format in formats {
            guard let formatExtensions = CMFormatDescriptionGetExtensions(format) else {
                continue
            }
            let extensions = formatExtensions as NSDictionary
            for metadata in expectedColorMetadata {
                guard let observed = extensions[metadata.key] as? String else { continue }
                if observed != metadata.expected {
                    unsupportedValues.append("\(metadata.label)=\(observed)")
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

private struct ExpectedColorMetadata: Sendable {
    let key: String
    let expected: String
    let label: String
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
        try await AVFoundationMediaPipeline.validateSupportedColorProfile(
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

        let reader = try Self.makeReader(asset: asset, sourceURL: source.url)
        let readerOutputs = try Self.configureReaderOutputs(
            reader: reader,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            preserveAudio: output.preserveAudio
        )
        let outputTransaction = try Self.makeOutputTransaction(outputURL: output.url)
        let writer = try Self.makeWriter(outputTransaction: outputTransaction, outputURL: output.url)
        writer.metadata = Self.makeASHMetadataItems()
        let writerInputs = try Self.configureWriterInputs(
            writer: writer,
            output: output,
            videoTransform: videoTransform,
            audioOutput: readerOutputs.audio,
            audioFormatDescription: audioFormatDescription
        )
        let outputPixelBufferPool = try PixelBufferBridge.makePool(
            width: output.resolution.width,
            height: output.resolution.height,
            capacity: 8
        )
        try Self.start(reader: reader, writer: writer, outputTransaction: outputTransaction)
        writer.startSession(atSourceTime: .zero)

        self.sourceProfile = source
        self.outputProfile = output
        self.outputPixelBufferPool = outputPixelBufferPool
        self.asset = asset
        self.reader = reader
        self.videoOutput = readerOutputs.video
        self.audioOutput = readerOutputs.audio
        self.writer = writer
        self.videoInput = writerInputs.video
        self.videoAdaptor = writerInputs.adaptor
        self.audioInput = writerInputs.audio
        self.outputTransaction = outputTransaction
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

}
