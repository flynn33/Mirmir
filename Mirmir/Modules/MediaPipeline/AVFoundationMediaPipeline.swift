import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo

protocol ASHTelemetryMediaPipelineScoping: AnyObject, Sendable {
    func scoped(to telemetry: any ASHTelemetryRecording) -> any MediaPipelineService
}

final class AVFoundationMediaPipeline:
    MediaPipelineService,
    ASHTelemetryMediaPipelineScoping,
    @unchecked Sendable {

    private let metal: MetalRenderingService
    private let telemetry: any ASHTelemetryRecording
    private let outputVerifier: any OutputMediaVerifying
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

    init(
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared,
        outputVerifier: any OutputMediaVerifying = OutputMediaVerifier()
    ) {
        self.metal = metal
        self.telemetry = telemetry
        self.outputVerifier = outputVerifier
    }

    func start() {}
    func stop() {}

    func scoped(to telemetry: any ASHTelemetryRecording) -> any MediaPipelineService {
        AVFoundationMediaPipeline(
            metal: metal,
            telemetry: telemetry,
            outputVerifier: outputVerifier
        )
    }

    func probe(url: URL) async throws -> SourceProfile {
        let stage = telemetry.beginStage(.mediaProbe)
        defer { telemetry.endStage(stage) }
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

        let profile = SourceProfile(
            url: url,
            resolution: resolution,
            frameRate: fps,
            durationSeconds: durationSeconds,
            estimatedFrameCount: max(estimatedFrameCount, 0),
            codecHint: codecHint,
            hasAudio: hasAudio
        )
        telemetry.recordMedia(ASHMediaObservation(
            kind: "media_probe",
            details: [
                "encoded_dimensions": "\(resolution.width)x\(resolution.height)",
                "estimated_frame_count": String(profile.estimatedFrameCount),
                "has_audio": String(profile.hasAudio)
            ]
        ))
        return profile
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        try await telemetry.measure(.readerSetup) {
            try await AVFoundationMediaSession.make(
                metal: metal,
                telemetry: telemetry,
                outputVerifier: outputVerifier,
                source: source,
                output: output
            )
        }
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
    enum LifecycleState {
        case active
        case cancelled
        case failed
        case committed
    }

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let outputPixelBufferPool: CVPixelBufferPool

    private let asset: AVURLAsset
    private let sourceVideoEndTime: CMTime
    let reader: AVAssetReader
    private let videoOutput: AVAssetReaderTrackOutput
    let audioOutput: AVAssetReaderTrackOutput?

    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    let audioInput: AVAssetWriterInput?
    let timedMetadataWriter: TimedMetadataWriter?
    let outputTransaction: AtomicMediaOutput
    let outputVerifier: any OutputMediaVerifying
    let telemetry: any ASHTelemetryRecording
    let lifecycleLock = NSLock()
    let timingLock = NSLock()

    private var frameIndex = 0
    private var pendingVideoSample: CMSampleBuffer?
    var lifecycleState = LifecycleState.active
    var timingLedger = FrameTimingLedger()
    var storedTerminalCleanupError: MediaPipelineError?

    var terminalCleanupError: MediaPipelineError? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return storedTerminalCleanupError
    }

    static func make(
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording,
        outputVerifier: any OutputMediaVerifying,
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
        let videoTimeRange = try await videoTrack.load(.timeRange)
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
            telemetry: telemetry,
            outputVerifier: outputVerifier,
            source: source,
            output: output,
            asset: asset,
            videoTrack: videoTrack,
            sourceVideoEndTime: CMTimeRangeGetEnd(videoTimeRange),
            videoTransform: videoTransform,
            audioTrack: audioTrack,
            audioFormatDescription: audioFormatDescription
        )
    }

    private init(
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording,
        outputVerifier: any OutputMediaVerifying,
        source: SourceProfile,
        output: OutputProfile,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        sourceVideoEndTime: CMTime,
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
        outputTransaction.attachTelemetry(telemetry)
        let writer = try Self.makeWriter(outputTransaction: outputTransaction, outputURL: output.url)
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
        self.sourceVideoEndTime = sourceVideoEndTime
        self.reader = reader
        self.videoOutput = readerOutputs.video
        self.audioOutput = readerOutputs.audio
        self.writer = writer
        self.videoInput = writerInputs.video
        self.videoAdaptor = writerInputs.adaptor
        self.audioInput = writerInputs.audio
        self.timedMetadataWriter = writerInputs.timedMetadata
        self.outputTransaction = outputTransaction
        self.outputVerifier = outputVerifier
        self.telemetry = telemetry
        telemetry.recordMedia(ASHMediaObservation(
            kind: "reader_writer_started",
            details: [
                "input_pixel_format": "420v",
                "output_pixel_format": "420v",
                "output_dimensions": "\(output.resolution.width)x\(output.resolution.height)"
            ]
        ))
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        let stage = telemetry.beginStage(.frameRead, frameIndex: frameIndex)
        defer { telemetry.endStage(stage) }
        try Task.checkCancellation()
        if sessionIsCancelled() { return nil }
        let currentSample: CMSampleBuffer
        if let pendingVideoSample {
            currentSample = pendingVideoSample
        } else if let firstSample = try copyNextVideoImageSample() {
            currentSample = firstSample
        } else {
            return nil
        }
        let nextSample = try copyNextVideoImageSample()
        pendingVideoSample = nextSample

        guard let buffer = CMSampleBufferGetImageBuffer(currentSample) else {
            throw failureAfterCleanup(
                MediaPipelineError.readerFailed(reader.error)
            )
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(currentSample)
        let nextPTS = nextSample.map(CMSampleBufferGetPresentationTimeStamp)
        let duration = FrameTiming.resolveDuration(
            sampleDuration: CMSampleBufferGetDuration(currentSample),
            presentationTime: pts,
            nextPresentationTime: nextPTS,
            timelineEnd: sourceVideoEndTime
        )
        let timing = FrameTiming(
            frameIndex: frameIndex,
            presentationTime: pts,
            duration: duration
        )
        let record = FrameRecord(pixelBuffer: buffer, timing: timing)
        telemetry.recordMedia(ASHMediaObservation(
            kind: "frame_read",
            frameIndex: frameIndex,
            presentationTimestampValue: pts.value,
            presentationTimestampTimescale: pts.timescale,
            details: [
                "pixel_format": String(CVPixelBufferGetPixelFormatType(buffer)),
                "plane_count": String(CVPixelBufferGetPlaneCount(buffer)),
                "duration_value": String(duration.value),
                "duration_timescale": String(duration.timescale)
            ]
        ))
        frameIndex += 1
        return record
    }

    private func copyNextVideoImageSample() throws -> CMSampleBuffer? {
        while let sample = videoOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { return sample }
        }
        if let error = reader.error {
            throw failureAfterCleanup(MediaPipelineError.readerFailed(error))
        }
        return nil
    }

    func appendOutput(pixelBuffer: CVPixelBuffer, timing: FrameTiming) async throws {
        let backpressure = telemetry.beginStage(.writerBackpressure)
        do {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
                if sessionIsCancelled() { throw CancellationError() }
            }
        } catch {
            telemetry.endStage(backpressure)
            throw error
        }
        telemetry.endStage(backpressure)
        let append = telemetry.beginStage(.writerAppend)
        defer { telemetry.endStage(append) }
        try Task.checkCancellation()
        if sessionIsCancelled() { throw CancellationError() }
        do {
            try timingLock.withLock {
                var candidateLedger = timingLedger
                try candidateLedger.append(timing)
                guard videoAdaptor.append(
                    pixelBuffer,
                    withPresentationTime: timing.presentationTime
                ) else {
                    throw MediaPipelineError.writerFailed(writer.error)
                }
                timingLedger = candidateLedger
            }
        } catch let error as FrameTimingLedgerError {
            throw failureAfterCleanup(
                MediaPipelineError.invalidFrameTiming(String(describing: error))
            )
        } catch {
            throw failureAfterCleanup(error)
        }
        telemetry.recordMedia(ASHMediaObservation(
            kind: "frame_appended",
            frameIndex: timing.frameIndex,
            presentationTimestampValue: timing.presentationTime.value,
            presentationTimestampTimescale: timing.presentationTime.timescale,
            details: [
                "duration_value": String(timing.duration.value),
                "duration_timescale": String(timing.duration.timescale)
            ]
        ))
    }

    deinit {
        let cleanup = outputTransaction.fail()
        retainCleanupError(cleanup)
    }
}
