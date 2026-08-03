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
    private let timingHandler: TimingHandler?

    init(timingHandler: TimingHandler? = nil) {
        self.timingHandler = timingHandler
    }

    func process(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend: any PreparedFrameUpscaler,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> UpscaleResult {
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

        let asset = AVURLAsset(
            url: request.inputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard let videoTrack = videoTracks.first else {
            throw MirmirError.noVideoTrack
        }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        if request.preserveAudio, audioTracks.count > 1 {
            throw MirmirError.unsupportedVideo(
                "audio preservation currently supports one audio track; this asset has \(audioTracks.count)"
            )
        }

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

        let audioPath = try await makeAudioPath(
            request: request,
            audioTracks: audioTracks,
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
            try await copyAudio(
                path: audioPath,
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
                requiresAudio: request.preserveAudio && source.hasAudio
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
                audioResult: audioPath.result,
                processedFrameCount: frameCount,
                processingDurationSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch is CancellationError {
            audioTask.cancel()
            reader.cancelReading()
            writer.cancelWriting()
            try? await preparedBackend.finish()
            throw MirmirError.cancelled
        } catch {
            audioTask.cancel()
            reader.cancelReading()
            writer.cancelWriting()
            try? await preparedBackend.finish()
            throw error
        }
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
        let output: AVAssetReaderTrackOutput?
        let input: AVAssetWriterInput?
        let result: AudioOutputResult
    }

    func makeAudioPath(
        request: UpscaleRequest,
        audioTracks: [AVAssetTrack],
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> AudioPath {
        guard request.preserveAudio else {
            return AudioPath(output: nil, input: nil, result: .omitted)
        }
        guard let audioTrack = audioTracks.first else {
            return AudioPath(output: nil, input: nil, result: .absent)
        }
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
        if reader.canAdd(passthroughOutput), writer.canAdd(passthroughInput) {
            reader.add(passthroughOutput)
            writer.add(passthroughInput)
            return AudioPath(
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
        guard reader.canAdd(decodedOutput), writer.canAdd(aacInput) else {
            throw MirmirError.unsupportedVideo(
                "the audio track cannot be decoded to PCM and encoded as AAC in this movie"
            )
        }
        reader.add(decodedOutput)
        writer.add(aacInput)
        return AudioPath(output: decodedOutput, input: aacInput, result: .transcoded)
    }

    func processVideo(
        output: AVAssetReaderTrackOutput,
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

    func copyAudio(
        path: AudioPath,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        source: VideoInfo,
        backendID: UpscaleBackendID,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws {
        guard let output = path.output, let input = path.input else {
            return
        }
        progress(event(
            phase: .processingAudio,
            source: source,
            backendID: backendID
        ))
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            try await waitUntilReady(
                input,
                reader: reader,
                writer: writer,
                cancellation: cancellation
            )
            guard input.append(sample) else {
                throw MirmirError.writerFailed(
                    writer.error?.localizedDescription
                        ?? "the writer rejected an audio sample"
                )
            }
        }
        input.markAsFinished()
    }

    func waitUntilReady(
        _ input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        cancellation: ProcessingCancellation
    ) async throws {
        while !input.isReadyForMoreMediaData {
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
