import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum VideoProcessingStage: String, Codable, CaseIterable, Sendable {
    case readerSample
    case destinationAllocation
    case backendProcessing
    case writerBackpressure
    case writerAppend
    case writerFinalize
    case outputValidation
    case atomicPublish
}

struct VideoProcessingTimingEvent: Sendable {
    let stage: VideoProcessingStage
    let frameIndex: Int?
    let durationNanoseconds: UInt64
}

struct VideoProcessingSession: Sendable {
    typealias ProgressHandler = @Sendable (UpscaleProgress) -> Void
    typealias TimingHandler = @Sendable (VideoProcessingTimingEvent) -> Void

    private let outputValidator = OutputMediaValidator()
    private let deterministicV4Session: DeterministicV4MediaProcessingSession
    private let timingHandler: TimingHandler?

    init(
        timingHandler: TimingHandler? = nil,
        deterministicV4Session: DeterministicV4MediaProcessingSession = .init()
    ) {
        self.timingHandler = timingHandler
        self.deterministicV4Session = deterministicV4Session
    }

    func process(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend: any PreparedFrameUpscaler,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> UpscaleResult {
        let audio = await Self.diagnosticAudioContext(
            request: request,
            source: source
        )
        let diagnosticProcessingContext = MirmirDiagnosticProcessingContext(
            request: request,
            source: source,
            actualBackendID: preparedBackend.actualBackendID,
            fallbackOccurred: request.backendID.isConcreteBackend
                && request.backendID != preparedBackend.actualBackendID,
            effectiveSourceAttributes:
                preparedBackend.sourcePixelBufferAttributes,
            effectiveDestinationAttributes:
                preparedBackend.destinationPixelBufferAttributes,
            durable: .init(
                isComplete: false,
                checkpointSchema: "direct-processing-v1",
                publishAttempted: false,
                atomicPublicationFailed: false
            ),
            audio: audio
        )
        do {
            return try await MirmirDiagnosticScope.$processingContext
                .withValue(diagnosticProcessingContext) {
                    try await processUninstrumented(
                        request: request,
                        source: source,
                        preparedBackend: preparedBackend,
                        cancellation: cancellation,
                        progress: progress
                    )
                }
        } catch {
            try? await preparedBackend.finish()
            MirmirDiagnosticScope.recorder.recordProcessingFailure(
                subsystem: preparedBackend
                    is any PreparedDeterministicV4RuntimePlanningBackend
                    ? "deterministic_v4" : "conventional_processing",
                operation: preparedBackend
                    is any PreparedDeterministicV4RuntimePlanningBackend
                    ? "process" : "process_conventional",
                request: request,
                source: source,
                actualBackendID: preparedBackend.actualBackendID,
                fallbackOccurred: request.backendID.isConcreteBackend
                    && request.backendID != preparedBackend.actualBackendID,
                effectiveSourceAttributes:
                    preparedBackend.sourcePixelBufferAttributes,
                effectiveDestinationAttributes:
                    preparedBackend.destinationPixelBufferAttributes,
                timing: .init(
                    nominalFrameDuration: source.minimumFrameDuration,
                    siteID: Self.timingSiteID(error)
                ),
                audio: audio,
                error: error
            )
            throw error
        }
    }

    private func processUninstrumented(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend: any PreparedFrameUpscaler,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> UpscaleResult {
        if let deterministicBackend = preparedBackend
            as? any PreparedDeterministicV4RuntimePlanningBackend {
            return try await deterministicV4Session.process(
                request: request,
                source: source,
                preparedBackend: deterministicBackend,
                cancellation: cancellation,
                progress: progress
            ).result
        }
        if source.color.alphaModel != .none {
            throw DeterministicV4WholeAssetPlannerError
                .alphaSourceRequiresProRes4444(request.outputCodec)
        }
        if request.outputCodec == .proRes4444 {
            throw DeterministicV4WholeAssetPlannerError
                .proRes4444RequiresAlphaSource
        }
        let startedAt = Date()
        let atomicOutput = try AtomicOutputFile(
            finalURL: request.outputURL,
            overwriteExistingFile: request.overwriteExistingFile
        )
        defer { atomicOutput.discard() }

        progress(event(
            phase: .preparingReaderWriter,
            source: source,
            backendID: preparedBackend.actualBackendID
        ))

        let asset = try await NativeMediaInputAssetResolverV4.asset(
            url: request.inputURL, cancellation: cancellation
        )
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard let videoTrack = videoTracks.first else {
            throw MirmirError.noVideoTrack
        }
        let sourceVideoDescriptions = try await videoTrack.load(.formatDescriptions)
        let sourceAVCChromaDeclaration = try AVCChromaLocationV4.declaration(
            from: sourceVideoDescriptions
        )
        let sourceMPEG4Sampling = try MPEG4ProgressiveSamplingV4.declaration(
            from: sourceVideoDescriptions
        )
        let sourceJFIFSampling = try LegacyVideoSamplingFacts.resolve(
            asset: asset, track: videoTrack, descriptions: sourceVideoDescriptions
        )?.nativeWorkingJFIFDeclaration
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        let expectedAudioTopology = AudioTopologyV4(
            graph: try await AVFoundationTrackGraphAdapterV4.probe(asset: asset),
            preservingAudio: request.preserveAudio
        )

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: preparedBackend.sourcePixelBufferAttributes.values
        )
        videoOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(videoOutput) else {
            throw MirmirError.readerFailed(
                "the selected backend's decoded pixel-buffer requirements are incompatible with this track"
            )
        }
        reader.add(videoOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: atomicOutput.temporaryURL,
                fileType: .mov
            )
        } catch {
            throw MirmirError.writerFailed(error.localizedDescription)
        }

        let videoSettings = writerVideoSettings(
            request: request,
            source: source
        )
        guard writer.canApply(
            outputSettings: videoSettings,
            forMediaType: .video
        ) else {
            throw MirmirError.writerFailed(
                "the selected codec rejected \(request.targetWidth) × \(request.targetHeight)"
            )
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = source.preferredTransform
        guard writer.canAdd(videoInput) else {
            throw MirmirError.writerFailed(
                "the video input could not be added to the movie writer"
            )
        }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes:
                preparedBackend.destinationPixelBufferAttributes.values
        )

        let audioPlan = try await makeAudioPlan(
            request: request,
            audioTracks: audioTracks,
            asset: asset,
            reader: reader,
            writer: writer
        )

        guard reader.startReading() else {
            throw MirmirError.readerFailed(
                reader.error?.localizedDescription ?? "startReading returned false"
            )
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MirmirError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting returned false"
            )
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            reader.cancelReading()
            writer.cancelWriting()
            throw MirmirError.writerFailed(
                "AVAssetWriter did not create its destination pixel-buffer pool"
            )
        }

        let audioTask = Task {
            try await copyAudioTracks(
                plan: audioPlan,
                reader: reader,
                writer: writer,
                source: source,
                backendID: preparedBackend.actualBackendID,
                cancellation: cancellation,
                progress: progress
            )
        }

        do {
            progress(event(
                phase: .processingVideo,
                source: source,
                backendID: preparedBackend.actualBackendID
            ))
            let frameCount = try await processVideo(
                output: videoOutput,
                sourceAVCChromaDeclaration: sourceAVCChromaDeclaration,
                sourceMPEG4Sampling: sourceMPEG4Sampling,
                sourceJFIFSampling: sourceJFIFSampling,
                input: videoInput,
                adaptor: adaptor,
                pool: pool,
                reader: reader,
                writer: writer,
                backend: preparedBackend,
                source: source,
                cancellation: cancellation,
                progress: progress
            )
            try await preparedBackend.finish()
            videoInput.markAsFinished()
            try await audioTask.value
            writer.endSession(atSourceTime: source.duration)

            guard reader.status == .completed else {
                throw MirmirError.readerFailed(
                    reader.error?.localizedDescription
                        ?? "the reader ended with status \(reader.status.rawValue)"
                )
            }

            progress(event(
                phase: .finalizing,
                source: source,
                backendID: preparedBackend.actualBackendID,
                frameCount: frameCount
            ))
            let writerFinalizeStarted = timingStart()
            await finishWriting(writer)
            recordTiming(
                .writerFinalize,
                frameIndex: nil,
                startedAt: writerFinalizeStarted
            )
            guard writer.status == .completed else {
                throw MirmirError.writerFailed(
                    writer.error?.localizedDescription
                        ?? "finishWriting ended with status \(writer.status.rawValue)"
                )
            }

            progress(event(
                phase: .validatingOutput,
                source: source,
                backendID: preparedBackend.actualBackendID,
                frameCount: frameCount
            ))
            let validationStarted = timingStart()
            let facts = try await outputValidator.validate(
                url: atomicOutput.temporaryURL,
                expectedWidth: request.targetWidth,
                expectedHeight: request.targetHeight,
                expectedAudioTopology: expectedAudioTopology
            )
            recordTiming(
                .outputValidation,
                frameIndex: nil,
                startedAt: validationStarted
            )
            try cancellation.check()
            let publicationStarted = timingStart()
            try atomicOutput.publish()
            recordTiming(
                .atomicPublish,
                frameIndex: nil,
                startedAt: publicationStarted
            )

            progress(event(
                phase: .completed,
                source: source,
                backendID: preparedBackend.actualBackendID,
                fraction: 1,
                frameCount: frameCount,
                processedTime: facts.duration
            ))
            return UpscaleResult(
                outputURL: request.outputURL,
                actualBackendID: preparedBackend.actualBackendID,
                encodedWidth: facts.encodedWidth,
                encodedHeight: facts.encodedHeight,
                durationSeconds: CMTimeGetSeconds(facts.duration),
                outputCodec: request.outputCodec,
                audioResult: audioPlan.result,
                processedFrameCount: frameCount,
                processingDurationSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch is CancellationError {
            audioTask.cancel()
            reader.cancelReading()
            writer.cancelWriting()
            throw MirmirError.cancelled
        } catch {
            audioTask.cancel()
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    static func diagnosticAudioContext(
        request: UpscaleRequest,
        source: VideoInfo
    ) async -> MirmirDiagnosticAudioContext {
        guard request.preserveAudio else {
            return .init(
                openedTrackCount: 0,
                codecs: [],
                alternateGroupFlags: [],
                readerDrainMode: "omitted_by_request"
            )
        }
        guard let asset = try? await NativeMediaInputAssetResolverV4.asset(url: request.inputURL) else {
            return .init(openedTrackCount: source.audioTrackCount, codecs: [],
                         alternateGroupFlags: [], readerDrainMode: "source_unavailable")
        }
        guard let tracks = try? await asset.load(.tracks) else {
            return .init(
                openedTrackCount: source.audioTrackCount,
                codecs: ["probe_unavailable"],
                alternateGroupFlags: [],
                readerDrainMode: "round_robin_serial_reader"
            )
        }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        let groups = (try? await asset.load(.trackGroups)) ?? []
        let groupedIDs = Set(groups.flatMap { $0.trackIDs.map(\.int32Value) })
        var codecs: [String] = []
        for track in audioTracks {
            guard let description = try? await track.load(
                .formatDescriptions
            ).first else {
                codecs.append("unknown")
                continue
            }
            codecs.append(Self.fourCC(
                CMFormatDescriptionGetMediaSubType(description)
            ))
        }
        return .init(
            openedTrackCount: audioTracks.count,
            codecs: codecs,
            alternateGroupFlags: audioTracks.map {
                groupedIDs.contains($0.trackID)
            },
            readerDrainMode: "round_robin_serial_reader"
        )
    }

    private static func timingSiteID(_ error: Error) -> String? {
        guard case let DeterministicV4MediaSegmentError
            .invalidSampleTiming(site) = error else {
            return nil
        }
        return site.rawValue
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
            ?? String(format: "0x%08x", value)
    }

    /// Executes the same production deterministic route as `process`, while
    /// retaining the immutable receipt emitted from the actual session plan,
    /// backend, migration, and output verification.
    func processWithDeterministicV4ExecutionReceipt(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend: any PreparedFrameUpscaler,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> DeterministicV4MediaProcessingExecutionV4 {
        guard let deterministicBackend = preparedBackend
                as? any PreparedDeterministicV4RuntimePlanningBackend else {
            throw DeterministicV4WholeAssetPlannerError
                .deterministicPlanningBackendRequired
        }
        return try await deterministicV4Session.process(
            request: request,
            source: source,
            preparedBackend: deterministicBackend,
            cancellation: cancellation,
            progress: progress
        )
    }
}

private extension VideoProcessingSession {
    func recordTiming(
        _ stage: VideoProcessingStage,
        frameIndex: Int?,
        startedAt: UInt64?
    ) {
        guard let timingHandler, let startedAt else {
            return
        }
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        timingHandler(VideoProcessingTimingEvent(
            stage: stage,
            frameIndex: frameIndex,
            durationNanoseconds: finishedAt - startedAt
        ))
    }

    func timingStart() -> UInt64? {
        timingHandler == nil ? nil : DispatchTime.now().uptimeNanoseconds
    }

    struct AudioPath: @unchecked Sendable {
        let sourceTrackID: CMPersistentTrackID
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let result: AudioOutputResult
    }

    struct AudioPlan: @unchecked Sendable {
        let paths: [AudioPath]
        let result: AudioOutputResult
    }

    func makeAudioPlan(
        request: UpscaleRequest,
        audioTracks: [AVAssetTrack],
        asset: AVAsset,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> AudioPlan {
        guard request.preserveAudio else {
            return AudioPlan(paths: [], result: .omitted)
        }
        guard !audioTracks.isEmpty else {
            return AudioPlan(paths: [], result: .absent)
        }

        var paths: [AudioPath] = []
        paths.reserveCapacity(audioTracks.count)
        for audioTrack in audioTracks {
            paths.append(try await makeAudioPath(
                audioTrack: audioTrack,
                reader: reader,
                writer: writer
            ))
        }
        try await addAudioInputGroups(
            for: paths,
            sourceTracks: audioTracks,
            asset: asset,
            writer: writer
        )
        return AudioPlan(
            paths: paths,
            result: paths.contains { $0.result == .transcoded }
                ? .transcoded : .preserved
        )
    }

    func makeAudioPath(
        audioTrack: AVAssetTrack,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> AudioPath {
        let descriptions = try await audioTrack.load(.formatDescriptions)
        guard let formatHint = descriptions.first else {
            throw MirmirError.unsupportedVideo(
                "the audio track has no format description for preservation"
            )
        }

        let passthroughOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: nil
        )
        passthroughOutput.alwaysCopiesSampleData = true
        let passthroughInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: formatHint
        )
        passthroughInput.expectsMediaDataInRealTime = false
        try await copyAudioTrackProperties(
            from: audioTrack,
            to: passthroughInput
        )
        if reader.canAdd(passthroughOutput), writer.canAdd(passthroughInput) {
            reader.add(passthroughOutput)
            writer.add(passthroughInput)
            return AudioPath(
                sourceTrackID: audioTrack.trackID,
                output: passthroughOutput,
                input: passthroughInput,
                result: .preserved
            )
        }

        guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            formatHint
        )?.pointee else {
            throw MirmirError.unsupportedVideo(
                "the audio format does not expose a channel count and sample rate for AAC transcoding"
            )
        }
        let channelCount = Int(streamDescription.mChannelsPerFrame)
        let sampleRate = streamDescription.mSampleRate
        guard (1...8).contains(channelCount),
              sampleRate.isFinite,
              (8_000...192_000).contains(sampleRate) else {
            throw MirmirError.unsupportedVideo(
                "AAC transcoding supports 1–8 channels and 8–192 kHz; this track reports \(channelCount) channels at \(sampleRate) Hz"
            )
        }

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let decodedOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: pcmSettings
        )
        decodedOutput.alwaysCopiesSampleData = true
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channelCount,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: min(384_000, max(96_000, channelCount * 96_000))
        ]
        guard writer.canApply(
            outputSettings: aacSettings,
            forMediaType: .audio
        ) else {
            throw MirmirError.unsupportedVideo(
                "AVAssetWriter rejected AAC transcoding for \(channelCount) channels at \(sampleRate) Hz"
            )
        }
        let aacInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: aacSettings
        )
        aacInput.expectsMediaDataInRealTime = false
        try await copyAudioTrackProperties(from: audioTrack, to: aacInput)
        guard reader.canAdd(decodedOutput), writer.canAdd(aacInput) else {
            throw MirmirError.unsupportedVideo(
                "the audio track cannot be decoded to PCM and encoded as AAC in this movie"
            )
        }
        reader.add(decodedOutput)
        writer.add(aacInput)
        return AudioPath(
            sourceTrackID: audioTrack.trackID,
            output: decodedOutput,
            input: aacInput,
            result: .transcoded
        )
    }

    func copyAudioTrackProperties(
        from track: AVAssetTrack,
        to input: AVAssetWriterInput
    ) async throws {
        input.metadata = try await track.load(.metadata)
        input.languageCode = try await track.load(.languageCode)
        input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
    }

    func addAudioInputGroups(
        for paths: [AudioPath],
        sourceTracks: [AVAssetTrack],
        asset: AVAsset,
        writer: AVAssetWriter
    ) async throws {
        let pathByTrackID = Dictionary(
            uniqueKeysWithValues: paths.map { ($0.sourceTrackID, $0) }
        )
        let sourceByTrackID = Dictionary(
            uniqueKeysWithValues: sourceTracks.map { ($0.trackID, $0) }
        )
        var groupedTrackIDs = Set<CMPersistentTrackID>()

        for group in try await asset.load(.trackGroups) {
            let memberIDs = group.trackIDs.map(\.int32Value)
            let audioMemberIDs = memberIDs.filter { pathByTrackID[$0] != nil }
            guard !audioMemberIDs.isEmpty else { continue }
            guard audioMemberIDs.count == memberIDs.count else {
                throw MirmirError.unsupportedVideo(
                    "an alternate-track group mixes audio with unsupported track types"
                )
            }
            guard audioMemberIDs.allSatisfy({ groupedTrackIDs.insert($0).inserted })
            else {
                throw MirmirError.unsupportedVideo(
                    "an audio track belongs to more than one alternate-track group"
                )
            }
            var enabledIDs: [CMPersistentTrackID] = []
            for trackID in audioMemberIDs {
                guard let track = sourceByTrackID[trackID] else {
                    throw MirmirError.unsupportedVideo(
                        "an alternate-audio group is missing a source track"
                    )
                }
                if try await track.load(.isEnabled) {
                    enabledIDs.append(trackID)
                }
            }
            guard enabledIDs.count <= 1 else {
                throw MirmirError.unsupportedVideo(
                    "an alternate-audio group has more than one enabled track"
                )
            }
            let inputs = audioMemberIDs.compactMap { pathByTrackID[$0]?.input }
            guard inputs.count == audioMemberIDs.count else {
                throw MirmirError.unsupportedVideo(
                    "an alternate-audio group is missing an output track"
                )
            }
            let defaultInput = enabledIDs.first.flatMap { pathByTrackID[$0]?.input }
            let writerGroup = AVAssetWriterInputGroup(
                inputs: inputs,
                defaultInput: defaultInput
            )
            guard writer.canAdd(writerGroup) else {
                throw MirmirError.unsupportedVideo(
                    "the movie writer rejected an alternate-audio group"
                )
            }
            writer.add(writerGroup)
        }

        for path in paths where !groupedTrackIDs.contains(path.sourceTrackID) {
            guard let track = sourceByTrackID[path.sourceTrackID] else {
                throw MirmirError.unsupportedVideo(
                    "an audio output lost its source-track identity"
                )
            }
            path.input.marksOutputTrackAsEnabled = try await track.load(.isEnabled)
        }
    }

    func processVideo(
        output: AVAssetReaderTrackOutput,
        sourceAVCChromaDeclaration: AVCChromaLocationV4.Declaration? = nil,
        sourceMPEG4Sampling: MPEG4ProgressiveSamplingV4? = nil,
        sourceJFIFSampling: JFIFVideoSamplingV4? = nil,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        pool: CVPixelBufferPool,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        backend: any PreparedFrameUpscaler,
        source: VideoInfo,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> Int {
        var sourceFrameIndex = 0
        var outputFrameCount = 0
        var previousSourcePTS: CMTime?
        var previousOutputPTS: CMTime?
        let temporalBackend = backend as? any PreparedTemporalFrameUpscaler

        while true {
            let readerStarted = timingStart()
            guard let sample = output.copyNextSampleBuffer() else {
                break
            }
            recordTiming(
                .readerSample,
                frameIndex: sourceFrameIndex,
                startedAt: readerStarted
            )
            try cancellation.check()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw MirmirError.readerFailed(
                    "video sample \(sourceFrameIndex) contains no image buffer"
                )
            }
            try AVCChromaLocationV4.normalizeDecodedBuffer(
                pixelBuffer, source: sourceAVCChromaDeclaration
            )
            try MPEG4ProgressiveSamplingV4.normalizeDecodedBuffer(
                pixelBuffer, source: sourceMPEG4Sampling
            )
            try JFIFVideoSamplingV4.normalizeDecodedBuffer(
                pixelBuffer, source: sourceJFIFSampling
            )
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            guard pts.isNumeric else {
                throw MirmirError.readerFailed(
                    "video sample \(sourceFrameIndex) has an invalid presentation timestamp"
                )
            }
            if let previousSourcePTS,
               CMTimeCompare(pts, previousSourcePTS) <= 0 {
                throw MirmirError.readerFailed(
                    "video presentation timestamps are not strictly increasing at frame \(sourceFrameIndex)"
                )
            }

            let timing = FrameTiming(
                frameIndex: sourceFrameIndex,
                presentationTime: pts,
                duration: duration
            )
            let outputFrames: [TemporalOutputFrame]
            if let temporalBackend {
                var destinations: [CVPixelBuffer] = []
                destinations.reserveCapacity(
                    temporalBackend.maximumOutputFramesPerInput
                )
                for _ in 0..<temporalBackend.maximumOutputFramesPerInput {
                    let allocationStarted = timingStart()
                    destinations.append(try allocatePixelBuffer(from: pool))
                    recordTiming(
                        .destinationAllocation,
                        frameIndex: sourceFrameIndex,
                        startedAt: allocationStarted
                    )
                }
                let backendStarted = timingStart()
                outputFrames = try await temporalBackend.processTemporal(
                    source: FramePixelBuffer(pixelBuffer),
                    destinations: destinations.map(FramePixelBuffer.init),
                    timing: timing
                )
                recordTiming(
                    .backendProcessing,
                    frameIndex: sourceFrameIndex,
                    startedAt: backendStarted
                )
            } else {
                let allocationStarted = timingStart()
                let destination = try allocatePixelBuffer(from: pool)
                recordTiming(
                    .destinationAllocation,
                    frameIndex: sourceFrameIndex,
                    startedAt: allocationStarted
                )
                let backendStarted = timingStart()
                try await backend.process(
                    source: pixelBuffer,
                    destination: destination,
                    timing: timing
                )
                recordTiming(
                    .backendProcessing,
                    frameIndex: sourceFrameIndex,
                    startedAt: backendStarted
                )
                outputFrames = [TemporalOutputFrame(
                    pixelBuffer: FramePixelBuffer(destination),
                    presentationTime: pts
                )]
            }

            for outputFrame in outputFrames {
                if let previousOutputPTS,
                   CMTimeCompare(
                    outputFrame.presentationTime,
                    previousOutputPTS
                   ) <= 0 {
                    throw MirmirError.writerFailed(
                        "backend output timestamps are not strictly increasing at output frame \(outputFrameCount)"
                    )
                }
                let backpressureStarted = timingStart()
                try await waitUntilReady(
                    input,
                    reader: reader,
                    writer: writer,
                    cancellation: cancellation
                )
                recordTiming(
                    .writerBackpressure,
                    frameIndex: outputFrameCount,
                    startedAt: backpressureStarted
                )
                let appendStarted = timingStart()
                let appended = adaptor.append(
                    outputFrame.pixelBuffer.value,
                    withPresentationTime: outputFrame.presentationTime
                )
                recordTiming(
                    .writerAppend,
                    frameIndex: outputFrameCount,
                    startedAt: appendStarted
                )
                guard appended else {
                    throw MirmirError.writerFailed(
                        writer.error?.localizedDescription
                            ?? "the video adaptor rejected output frame \(outputFrameCount) at \(CMTimeGetSeconds(outputFrame.presentationTime)) seconds"
                    )
                }
                outputFrameCount += 1
                previousOutputPTS = outputFrame.presentationTime
            }

            sourceFrameIndex += 1
            previousSourcePTS = pts
            let fraction = progressFraction(time: pts, duration: source.duration)
            progress(event(
                phase: .processingVideo,
                source: source,
                backendID: backend.actualBackendID,
                fraction: fraction,
                frameCount: outputFrameCount,
                processedTime: pts
            ))
        }

        guard outputFrameCount > 0 else {
            throw MirmirError.readerFailed(
                reader.error?.localizedDescription
                    ?? "the video track yielded no decoded frames"
            )
        }
        return outputFrameCount
    }

    func allocatePixelBuffer(
        from pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else {
            throw MirmirError.writerFailed(
                "destination pixel-buffer allocation failed with Core Video status \(status)"
            )
        }
        return destination
    }

    func copyAudioTracks(
        plan: AudioPlan,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        source: VideoInfo,
        backendID: UpscaleBackendID,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws {
        guard !plan.paths.isEmpty else { return }
        progress(event(
            phase: .processingAudio,
            source: source,
            backendID: backendID
        ))
        var finished = Array(repeating: false, count: plan.paths.count)
        var remaining = plan.paths.count
        while remaining > 0 {
            for (index, path) in plan.paths.enumerated() where !finished[index] {
                try Task.checkCancellation()
                try cancellation.check()
                guard let sample = path.output.copyNextSampleBuffer() else {
                    path.input.markAsFinished()
                    finished[index] = true
                    remaining -= 1
                    continue
                }
                try await waitUntilReady(
                    path.input,
                    reader: reader,
                    writer: writer,
                    cancellation: cancellation
                )
                let writerSample = try UniformPCMSampleBufferV4.compactingSizes(in: sample)
                guard path.input.append(writerSample) else {
                    throw MirmirError.writerFailed(
                        writer.error?.localizedDescription
                            ?? "the writer rejected an audio sample"
                    )
                }
            }
        }
    }

    func waitUntilReady(
        _ input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        cancellation: ProcessingCancellation
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try cancellation.check()
            if reader.status == .failed {
                throw MirmirError.readerFailed(
                    reader.error?.localizedDescription ?? "reader failed"
                )
            }
            if writer.status == .failed || writer.status == .cancelled {
                throw MirmirError.writerFailed(
                    writer.error?.localizedDescription ?? "writer stopped"
                )
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }

    func writerVideoSettings(
        request: UpscaleRequest,
        source: VideoInfo
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: request.outputCodec.avVideoCodecType,
            AVVideoWidthKey: request.targetWidth,
            AVVideoHeightKey: request.targetHeight
        ]
        var color: [String: Any] = [:]
        if let primaries = source.color.colorPrimaries {
            color[AVVideoColorPrimariesKey] = primaries
        }
        if let transfer = source.color.transferFunction {
            color[AVVideoTransferFunctionKey] = transfer
        }
        if let matrix = source.color.yCbCrMatrix {
            color[AVVideoYCbCrMatrixKey] = matrix
        }
        if !color.isEmpty {
            settings[AVVideoColorPropertiesKey] = color
        }
        return settings
    }

    func event(
        phase: UpscalePhase,
        source: VideoInfo,
        backendID: UpscaleBackendID,
        fraction: Double? = nil,
        frameCount: Int = 0,
        processedTime: CMTime? = nil
    ) -> UpscaleProgress {
        UpscaleProgress(
            phase: phase,
            fractionCompleted: fraction,
            processedFrameCount: frameCount,
            processedTime: processedTime,
            duration: source.duration,
            actualBackendID: backendID
        )
    }

    func progressFraction(time: CMTime, duration: CMTime) -> Double? {
        let timeSeconds = CMTimeGetSeconds(time)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard time.isNumeric,
              duration.isNumeric,
              timeSeconds.isFinite,
              durationSeconds.isFinite,
              durationSeconds > 0 else {
            return nil
        }
        return min(max(timeSeconds / durationSeconds, 0), 1)
    }
}
