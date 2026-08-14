import AVFoundation
import CoreMedia
import Foundation

enum DeterministicV4MediaSegmentError: Error, Equatable, Sendable {
    case invalidMaximumInputFrames(Int)
    case primaryTrackMissing
    case segmentAlreadyExists(String)
    case readerCreationFailed
    case readerRejectedTrack
    case readerStartFailed
    case readerFailed
    case writerCreationFailed
    case writerRejectedTrack
    case writerStartFailed
    case writerFailed
    case emptySegment
    case nonContiguousBoundary
    case invalidSampleTiming
    case retimingFailed(Int32)
    case appendFailed
    case dynamicHDRMetadataMismatch
}

struct DeterministicV4MediaSegmentResultV4: Sendable {
    let segmentURL: URL
    let startTime: WorkflowMediaTimeV4
    let endTimeExclusive: WorkflowMediaTimeV4
    let inputSampleCount: Int
    let outputSampleCount: Int
    let lastCompletedInputOrdinal: Int64
    let terminal: Bool
    let processingDurationSeconds: TimeInterval
}

enum DeterministicV4MediaExecutionReceiptError: Error, Equatable, Sendable {
    case preparedPlanExecutorMismatch
    case actualBackendIdentityMismatch
    case sourceGraphIdentityMismatch
    case trackPlanIdentityMismatch
    case migrationBlueprintIdentityMismatch
    case migratedTrackInventoryMismatch
    case semanticVerificationIdentityMismatch
    case outputGraphIdentityMismatch
}

struct DeterministicV4MediaPlannedTrackReceiptV4: Codable, Equatable,
    Hashable, Sendable {
    let ordinal: Int
    let stableID: String
    let kind: String
    let action: MediaTrackActionV4
}

struct DeterministicV4MediaMigratedTrackReceiptV4: Codable, Equatable,
    Hashable, Sendable {
    let stableID: String
    let action: MediaTrackActionV4
    let migratedSampleCount: Int64
    let sourceSampleStreamSHA256: ASHSHA256V4?
    let outputSampleStreamSHA256: ASHSHA256V4?
}

/// Immutable facts emitted from the exact plan, backend, migration result,
/// and output verification used by one deterministic whole-asset execution.
/// No caller-provided preflight value participates in this receipt.
struct DeterministicV4MediaExecutionReceiptV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID =
        "ash.deterministic-media-execution-receipt.v4.1"

    let schemaID: String
    let preparedBackendType: String
    let executor: ASHExecutorV4
    let requestedBackendID: UpscaleBackendID
    let actualBackendID: UpscaleBackendID
    let ashPlanSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let runtimeProvenanceSHA256: ASHSHA256V4
    let trackPlanSHA256: ASHSHA256V4
    let sourceGraphSHA256: ASHSHA256V4
    let migrationSourceGraphSHA256: ASHSHA256V4
    let migrationPlanSHA256: ASHSHA256V4
    let migrationBlueprintSHA256: ASHSHA256V4
    let sourceAssetMetadataSHA256: ASHSHA256V4
    let outputAssetMetadataSHA256: ASHSHA256V4
    let sourceChapterMetadataSHA256: ASHSHA256V4
    let outputChapterMetadataSHA256: ASHSHA256V4
    let outputGraphSHA256: ASHSHA256V4
    let semanticVerificationSHA256: ASHSHA256V4
    let primaryTrackOrdinal: Int
    let plannedTracks: [DeterministicV4MediaPlannedTrackReceiptV4]
    let migratedTracks: [DeterministicV4MediaMigratedTrackReceiptV4]
    let targetWidth: Int
    let targetHeight: Int
    let encodedWidth: Int
    let encodedHeight: Int
    let processedFrameCount: Int
    let sourceVideoTrackCount: Int
    let sourceAudioTrackCount: Int
    let plannedEnabledTrackCount: Int
    let alphaVerification: AlphaVideoWriterVerificationV4?

    init(
        request: UpscaleRequest,
        preparedBackend: any PreparedDeterministicV4RuntimePlanningBackend,
        preparedPlan: DeterministicV4PreparedAssetPlan,
        migration: AVFoundationTrackMigrationExecutionResultV4,
        result: UpscaleResult,
        alphaVerification: AlphaVideoWriterVerificationV4?
    ) throws {
        guard preparedPlan.ashPlan.plan.executor
                == preparedBackend.deterministicExecutor else {
            throw DeterministicV4MediaExecutionReceiptError
                .preparedPlanExecutorMismatch
        }
        guard result.actualBackendID == preparedBackend.actualBackendID else {
            throw DeterministicV4MediaExecutionReceiptError
                .actualBackendIdentityMismatch
        }
        let sourceGraphSHA256 = try preparedPlan.sourceGraph.canonicalSHA256
        guard migration.sourceGraphSHA256 == sourceGraphSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .sourceGraphIdentityMismatch
        }
        guard migration.planSHA256 == preparedPlan.trackPlan.planSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .trackPlanIdentityMismatch
        }
        guard migration.blueprintSHA256
                == (try preparedPlan.migrationBlueprint.canonicalSHA256) else {
            throw DeterministicV4MediaExecutionReceiptError
                .migrationBlueprintIdentityMismatch
        }
        let expectedMigratedTracks = preparedPlan.trackPlan.plan.tracks.filter {
            $0.action != .dropWithConsent
        }
        guard migration.trackResults.count == expectedMigratedTracks.count,
              zip(migration.trackResults, expectedMigratedTracks).allSatisfy({
                  migrated, planned in
                  migrated.trackID == planned.source.identity.stableID
                      && migrated.action == planned.action
              }) else {
            throw DeterministicV4MediaExecutionReceiptError
                .migratedTrackInventoryMismatch
        }
        let outputGraphSHA256 = try migration.outputGraph.canonicalSHA256
        guard migration.verificationReport.planSHA256
                == preparedPlan.trackPlan.planSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .semanticVerificationIdentityMismatch
        }
        guard migration.verificationReport.outputGraphSHA256
                == outputGraphSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .outputGraphIdentityMismatch
        }
        let enabledTracks = preparedPlan.sourceGraph.tracks.filter(\.enabled)

        schemaID = Self.currentSchemaID
        preparedBackendType = String(reflecting: type(of: preparedBackend))
        executor = preparedBackend.deterministicExecutor
        requestedBackendID = request.backendID
        actualBackendID = result.actualBackendID
        ashPlanSHA256 = preparedPlan.ashPlan.planSHA256
        runtimeManifestSHA256 = preparedPlan.ashPlan.plan
            .runtimeManifestSHA256
        runtimeProvenanceSHA256 = preparedPlan.ashPlan.plan
            .runtimeProvenanceSHA256
        trackPlanSHA256 = preparedPlan.trackPlan.planSHA256
        self.sourceGraphSHA256 = sourceGraphSHA256
        migrationSourceGraphSHA256 = migration.sourceGraphSHA256
        migrationPlanSHA256 = migration.planSHA256
        migrationBlueprintSHA256 = migration.blueprintSHA256
        sourceAssetMetadataSHA256 = migration.sourceAssetMetadataSHA256
        outputAssetMetadataSHA256 = migration.outputAssetMetadataSHA256
        sourceChapterMetadataSHA256 = migration.sourceChapterMetadataSHA256
        outputChapterMetadataSHA256 = migration.outputChapterMetadataSHA256
        self.outputGraphSHA256 = outputGraphSHA256
        semanticVerificationSHA256 = try migration.verificationReport
            .canonicalSHA256
        primaryTrackOrdinal = Int(
            preparedPlan.primaryGraphTrack.identity.ordinal
        )
        plannedTracks = preparedPlan.trackPlan.plan.tracks.map {
            DeterministicV4MediaPlannedTrackReceiptV4(
                ordinal: Int($0.source.identity.ordinal),
                stableID: $0.source.identity.stableID.rawValue,
                kind: $0.source.kind.rawValue,
                action: $0.action
            )
        }
        migratedTracks = migration.trackResults.map {
            DeterministicV4MediaMigratedTrackReceiptV4(
                stableID: $0.trackID.rawValue,
                action: $0.action,
                migratedSampleCount: $0.migratedSampleCount,
                sourceSampleStreamSHA256: $0.sourceSampleStreamSHA256,
                outputSampleStreamSHA256: $0.outputSampleStreamSHA256
            )
        }
        targetWidth = request.targetWidth
        targetHeight = request.targetHeight
        encodedWidth = result.encodedWidth
        encodedHeight = result.encodedHeight
        processedFrameCount = result.processedFrameCount
        sourceVideoTrackCount = enabledTracks.filter {
            $0.kind == .video
        }.count
        sourceAudioTrackCount = enabledTracks.filter {
            $0.kind == .audio
        }.count
        plannedEnabledTrackCount = enabledTracks.count
        self.alphaVerification = alphaVerification
    }
}

struct DeterministicV4MediaProcessingExecutionV4: Sendable {
    let result: UpscaleResult
    let receipt: DeterministicV4MediaExecutionReceiptV4
}

/// Executes the deterministic v4 whole-asset plan. AVFoundation policy is
/// fixed before migration, the processed track is the only decoded stream,
/// and every pass-through stream is verified by encoded-sample digest.
struct DeterministicV4MediaProcessingSession: Sendable {
    typealias ProgressHandler = @Sendable (UpscaleProgress) -> Void

    private let planner: DeterministicV4WholeAssetPlanner
    private let executor: AVFoundationTrackMigrationExecutorV4
    private let outputValidator: OutputMediaValidator

    init(
        planner: DeterministicV4WholeAssetPlanner = .init(),
        executor: AVFoundationTrackMigrationExecutorV4 = .init(),
        outputValidator: OutputMediaValidator = .init()
    ) {
        self.planner = planner
        self.executor = executor
        self.outputValidator = outputValidator
    }

    func process(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend: any PreparedDeterministicV4RuntimePlanningBackend,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> DeterministicV4MediaProcessingExecutionV4 {
        let startedAt = Date()
        do {
            try cancellation.check()
            progress(event(
                phase: .preparingReaderWriter,
                source: source,
                backendID: preparedBackend.actualBackendID
            ))
            let preparedPlan = try await planner.prepare(
                request: request,
                source: source,
                backend: preparedBackend,
                cancellation: cancellation
            )
            try cancellation.check()
            let hook = try preparedPlan.makeProcessingHook(
                backend: preparedBackend
            )
            let migrationCancellation =
                AVFoundationTrackMigrationCancellationV4()
            let cancellationMonitor = Task {
                while !Task.isCancelled {
                    do {
                        try cancellation.check()
                    } catch {
                        migrationCancellation.cancel()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            defer { cancellationMonitor.cancel() }

            let migration: AVFoundationTrackMigrationExecutionResultV4
            do {
                migration = try await executor.execute(
                    .init(
                        sourceURL: request.inputURL,
                        destinationURL: request.outputURL,
                        outputFileType: .mov,
                        overwriteExistingFile:
                            request.overwriteExistingFile,
                        sourceGraph: preparedPlan.sourceGraph,
                        identifiedPlan: preparedPlan.trackPlan,
                        blueprint: preparedPlan.migrationBlueprint,
                        videoProcessingHooks: [hook],
                        nonVideoTranscodeHooks:
                            preparedPlan.nonVideoTranscodeHooks
                    ),
                    cancellation: migrationCancellation,
                    progress: { state in
                        progress(self.event(
                            phase: self.phase(for: state.stage),
                            source: source,
                            backendID: preparedBackend.actualBackendID,
                            frameCount: Int(clamping: state.migratedSampleCount)
                        ))
                    }
                )
            } catch AVFoundationTrackMigrationExecutorV4Error.cancelled {
                throw MirmirError.cancelled
            }
            try cancellation.check()
            let alphaVerification = try await preparedPlan.verifyProcessedOutput(
                at: request.outputURL
            )
            progress(event(
                phase: .validatingOutput,
                source: source,
                backendID: preparedBackend.actualBackendID
            ))
            let facts = try await outputValidator.validate(
                url: request.outputURL,
                expectedWidth: request.targetWidth,
                expectedHeight: request.targetHeight,
                requiresAudio: request.preserveAudio && source.hasAudio
            )
            let primaryResult = migration.trackResults.first {
                $0.trackID == preparedPlan.primaryGraphTrack.identity.stableID
            }
            let frameCount = Int(clamping:
                primaryResult?.migratedSampleCount ?? 0
            )
            progress(event(
                phase: .completed,
                source: source,
                backendID: preparedBackend.actualBackendID,
                fraction: 1,
                frameCount: frameCount,
                processedTime: facts.duration
            ))
            let result = UpscaleResult(
                outputURL: request.outputURL,
                actualBackendID: preparedBackend.actualBackendID,
                encodedWidth: facts.encodedWidth,
                encodedHeight: facts.encodedHeight,
                durationSeconds: CMTimeGetSeconds(facts.duration),
                outputCodec: request.outputCodec,
                audioResult: audioResult(
                    request: request,
                    preparedPlan: preparedPlan
                ),
                processedFrameCount: frameCount,
                processingDurationSeconds: Date().timeIntervalSince(startedAt)
            )
            let receipt = try DeterministicV4MediaExecutionReceiptV4(
                request: request,
                preparedBackend: preparedBackend,
                preparedPlan: preparedPlan,
                migration: migration,
                result: result,
                alphaVerification: alphaVerification
            )
            return DeterministicV4MediaProcessingExecutionV4(
                result: result,
                receipt: receipt
            )
        } catch {
            try? await preparedBackend.finish()
            throw error
        }
    }

    /// Encodes one bounded, independently decodable primary-video segment.
    /// The backend observes global frame ordinals and timestamps; only the
    /// samples submitted to this segment's writer are rebased to zero.
    func processSegment(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedPlan: DeterministicV4PreparedAssetPlan,
        preparedBackend: any PreparedDeterministicV4RuntimePlanningBackend,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames: Int,
        segmentURL: URL,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> DeterministicV4MediaSegmentResultV4 {
        guard maximumInputFrames > 0 else {
            throw DeterministicV4MediaSegmentError
                .invalidMaximumInputFrames(maximumInputFrames)
        }
        guard !FileManager.default.fileExists(atPath: segmentURL.path) else {
            throw DeterministicV4MediaSegmentError
                .segmentAlreadyExists(segmentURL.path)
        }
        let startedAt = Date()
        let asset = AVURLAsset(
            url: request.inputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let primaryOrdinal = Int(
            preparedPlan.primaryGraphTrack.identity.ordinal
        )
        guard tracks.indices.contains(primaryOrdinal),
              tracks[primaryOrdinal].mediaType == .video else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        let sourceTrack = tracks[primaryOrdinal]
        let hook = try preparedPlan.makeProcessingHook(
            backend: preparedBackend,
            startingFrameIndex: startingInputFrameIndex,
            finishBackendAtEnd: false,
            recordAlphaForFinalVerification: false
        )
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DeterministicV4MediaSegmentError.readerCreationFailed
        }
        let readerOutput = AVAssetReaderTrackOutput(
            track: sourceTrack,
            outputSettings: hook.readerOutputSettings
        )
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        reader.add(readerOutput)
        if let startTime {
            let start = CMTime(
                value: startTime.value,
                timescale: startTime.timescale
            )
            let assetDuration = try await asset.load(.duration)
            let remaining = CMTimeSubtract(assetDuration, start)
            guard remaining.isNumeric, remaining.value > 0 else {
                throw DeterministicV4MediaSegmentError
                    .nonContiguousBoundary
            }
            reader.timeRange = CMTimeRange(start: start, duration: remaining)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: segmentURL, fileType: .mov)
        } catch {
            throw DeterministicV4MediaSegmentError.writerCreationFailed
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: hook.writerOutputSettings
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.metadata = try await sourceTrack.load(.metadata)
        writerInput.languageCode = try await sourceTrack.load(.languageCode)
        writerInput.extendedLanguageTag = try await sourceTrack
            .load(.extendedLanguageTag)
        if let naturalSize = hook.outputNaturalSize {
            writerInput.naturalSize = naturalSize
        } else {
            writerInput.naturalSize = try await sourceTrack.load(.naturalSize)
        }
        if let transform = hook.outputPreferredTransform {
            writerInput.transform = transform
        } else {
            writerInput.transform = try await sourceTrack
                .load(.preferredTransform)
        }
        guard writer.canAdd(writerInput) else {
            throw DeterministicV4MediaSegmentError.writerRejectedTrack
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw DeterministicV4MediaSegmentError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        var inputCount = 0
        var outputCount = 0
        var segmentOrigin: CMTime?
        var globalEnd: CMTime?
        var expectedDynamicHDR = DynamicHDRMetadataStreamAccumulatorV4()
        let alphaVerifier: AVFoundationAlphaVideoOutputVerifierV4?
        if case .alpha(let delivery) = preparedPlan.videoDelivery {
            alphaVerifier = try AVFoundationAlphaVideoOutputVerifierV4(
                contract: delivery.writerContract
            )
        } else {
            alphaVerifier = nil
        }

        do {
            while inputCount < maximumInputFrames {
                try cancellation.check()
                guard let sourceSample = readerOutput.copyNextSampleBuffer() else {
                    break
                }
                let sourcePTS = CMSampleBufferGetPresentationTimeStamp(
                    sourceSample
                )
                guard sourcePTS.isNumeric else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming
                }
                if segmentOrigin == nil {
                    if let startTime {
                        let expected = CMTime(
                            value: startTime.value,
                            timescale: startTime.timescale
                        )
                        guard CMTimeCompare(sourcePTS, expected) == 0 else {
                            throw DeterministicV4MediaSegmentError
                                .nonContiguousBoundary
                        }
                        segmentOrigin = expected
                    } else {
                        segmentOrigin = sourcePTS
                    }
                }
                let outputs = try await hook.processTemporal(
                    AVFoundationVideoSampleV4(sampleBuffer: sourceSample)
                )
                guard let origin = segmentOrigin, !outputs.isEmpty else {
                    throw DeterministicV4MediaSegmentError.emptySegment
                }
                for output in outputs {
                    let absolute = output.sampleBuffer
                    let duration = CMSampleBufferGetDuration(absolute)
                    let pts = CMSampleBufferGetPresentationTimeStamp(absolute)
                    guard duration.isNumeric, duration.value > 0,
                          pts.isNumeric else {
                        throw DeterministicV4MediaSegmentError
                            .invalidSampleTiming
                    }
                    globalEnd = CMTimeAdd(pts, duration)
                    let local = try retime(absolute, subtracting: origin)
                    try expectedDynamicHDR.append(local)
                    try await alphaVerifier?.record(local)
                    try await waitUntilReady(
                        writerInput,
                        reader: reader,
                        writer: writer,
                        cancellation: cancellation
                    )
                    guard writerInput.append(local) else {
                        throw DeterministicV4MediaSegmentError.appendFailed
                    }
                    outputCount += 1
                }
                inputCount += 1
                progress(event(
                    phase: .processingVideo,
                    source: source,
                    backendID: preparedBackend.actualBackendID,
                    fraction: min(
                        1,
                        Double(inputCount) / Double(maximumInputFrames)
                    ),
                    frameCount: startingInputFrameIndex + inputCount,
                    processedTime: globalEnd
                ))
            }
            guard inputCount > 0,
                  let segmentOrigin,
                  let globalEnd else {
                throw DeterministicV4MediaSegmentError.emptySegment
            }
            let nextSample = inputCount == maximumInputFrames
                ? readerOutput.copyNextSampleBuffer()
                : nil
            let terminal = nextSample == nil
            if reader.status == .failed || reader.status == .cancelled {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            try await hook.finish()
            writerInput.markAsFinished()
            await finishWriting(writer)
            guard writer.status == .completed else {
                throw DeterministicV4MediaSegmentError.writerFailed
            }
            reader.cancelReading()

            try await verifySegment(
                at: segmentURL,
                plan: preparedPlan,
                expectedDynamicHDR: expectedDynamicHDR,
                alphaVerifier: alphaVerifier
            )
            let preferredTimescale = startTime?.timescale
                ?? segmentOrigin.timescale
            let workflowStart = try workflowTime(
                segmentOrigin,
                timescale: preferredTimescale
            )
            let workflowEnd = try workflowTime(
                globalEnd,
                timescale: preferredTimescale
            )
            return DeterministicV4MediaSegmentResultV4(
                segmentURL: segmentURL,
                startTime: workflowStart,
                endTimeExclusive: workflowEnd,
                inputSampleCount: inputCount,
                outputSampleCount: outputCount,
                lastCompletedInputOrdinal: Int64(
                    startingInputFrameIndex + inputCount - 1
                ),
                terminal: terminal,
                processingDurationSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: segmentURL)
            throw error
        }
    }
}

private extension DeterministicV4MediaProcessingSession {
    func retime(
        _ sample: CMSampleBuffer,
        subtracting origin: CMTime
    ) throws -> CMSampleBuffer {
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming
        }
        var timing = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(),
            count: count
        )
        var needed = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: timing.count,
            arrayToFill: &timing,
            entriesNeededOut: &needed
        )
        guard status == noErr, needed == count else {
            throw DeterministicV4MediaSegmentError.retimingFailed(status)
        }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isNumeric {
                timing[index].presentationTimeStamp = CMTimeSubtract(
                    timing[index].presentationTimeStamp,
                    origin
                )
            }
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeSubtract(
                    timing[index].decodeTimeStamp,
                    origin
                )
            }
        }
        var copy: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else {
            throw DeterministicV4MediaSegmentError.retimingFailed(status)
        }
        return copy
    }

    func waitUntilReady(
        _ input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        cancellation: ProcessingCancellation
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try cancellation.check()
            guard reader.status != .failed,
                  reader.status != .cancelled else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            guard writer.status != .failed,
                  writer.status != .cancelled else {
                throw DeterministicV4MediaSegmentError.writerFailed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    func workflowTime(
        _ time: CMTime,
        timescale: Int32
    ) throws -> WorkflowMediaTimeV4 {
        guard time.isNumeric else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming
        }
        let converted = CMTimeConvertScale(
            time,
            timescale: timescale,
            method: .default
        )
        guard CMTimeCompare(time, converted) == 0 else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming
        }
        return try WorkflowMediaTimeV4(
            value: converted.value,
            timescale: converted.timescale
        )
    }

    func verifySegment(
        at url: URL,
        plan: DeterministicV4PreparedAssetPlan,
        expectedDynamicHDR: DynamicHDRMetadataStreamAccumulatorV4,
        alphaVerifier: AVFoundationAlphaVideoOutputVerifierV4?
    ) async throws {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        switch plan.videoDelivery {
        case .opaque(let contract):
            try contract.verifyReopenedFormat(
                format,
                preferredTransform: try await track.load(.preferredTransform)
            )
            let decodedReader = try AVAssetReader(asset: asset)
            let decodedOutput = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: contract.sourcePixelBufferAttributes
            )
            guard decodedReader.canAdd(decodedOutput) else {
                throw DeterministicV4MediaSegmentError.readerRejectedTrack
            }
            decodedReader.add(decodedOutput)
            guard decodedReader.startReading() else {
                throw DeterministicV4MediaSegmentError.readerStartFailed
            }
            while let sample = decodedOutput.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw DeterministicV4MediaSegmentError.readerFailed
                }
                try contract.verifyDecodedPixelBuffer(pixelBuffer)
            }
            guard decodedReader.status == .completed else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
        case .alpha(let delivery):
            guard let alphaVerifier else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            let report = try await alphaVerifier.verify(
                outputURL: url,
                videoTrackOrdinal: 0
            )
            guard report.encodedFormat == delivery.encodedFormatDescriptor else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
        }

        let encodedReader = try AVAssetReader(asset: asset)
        let encodedOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        encodedOutput.alwaysCopiesSampleData = false
        guard encodedReader.canAdd(encodedOutput) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        encodedReader.add(encodedOutput)
        guard encodedReader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        var actualDynamicHDR = DynamicHDRMetadataStreamAccumulatorV4()
        while let sample = encodedOutput.copyNextSampleBuffer() {
            try actualDynamicHDR.append(sample)
        }
        guard encodedReader.status == .completed else {
            throw DeterministicV4MediaSegmentError.readerFailed
        }
        guard actualDynamicHDR == expectedDynamicHDR else {
            throw DeterministicV4MediaSegmentError
                .dynamicHDRMetadataMismatch
        }
    }

    func phase(
        for stage: AVFoundationTrackMigrationExecutionStageV4
    ) -> UpscalePhase {
        switch stage {
        case .validating, .preparingReaderWriter:
            .preparingReaderWriter
        case .migrating:
            .processingVideo
        case .finalizing:
            .finalizing
        case .verifying, .publishing:
            .validatingOutput
        case .completed:
            .completed
        }
    }

    func audioResult(
        request: UpscaleRequest,
        preparedPlan: DeterministicV4PreparedAssetPlan
    ) -> AudioOutputResult {
        guard request.preserveAudio else { return .omitted }
        let audioTracks = preparedPlan.trackPlan.plan.tracks.filter {
            $0.source.kind == .audio && $0.expectedOutput != nil
        }
        guard !audioTracks.isEmpty else { return .absent }
        return audioTracks.contains { $0.action == .transcode }
            ? .transcoded
            : .preserved
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
}
