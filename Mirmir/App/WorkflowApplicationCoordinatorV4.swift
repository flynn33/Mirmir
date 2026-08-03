import AVFoundation
import CoreMedia
import Foundation

enum WorkflowApplicationControllerErrorV4: Error, LocalizedError, Sendable {
    case noDispatchableJob
    case dispatchCapacityExhausted
    case deterministicBackendRequired(UpscaleBackendID)
    case backendUnavailable(UpscaleBackendID, String)
    case preparedBackendMismatch(UpscaleBackendID)
    case activationBlocked(WorkflowApplicationActivationFailureV4)
    case preparedPlanChanged(WorkflowJobID)
    case noActiveJob
    case pauseNotAllowed(WorkflowJobLifecycle)
    case cancellationNotAllowed(WorkflowJobLifecycle)
    case heartbeatFailed(String)
    case workingSegmentConflict(String)
    case checkpointMissing(WorkflowJobID)
    case invalidAssembledOutput(String)

    var errorDescription: String? {
        switch self {
        case .noDispatchableJob:
            "The durable queue has no dispatchable job."
        case .dispatchCapacityExhausted:
            "The durable processing slot is already owned by another worker."
        case .deterministicBackendRequired(let backendID):
            "Durable v4 execution requires a prepared deterministic backend; got \(backendID.rawValue)."
        case .backendUnavailable(let backendID, let reason):
            "The durable job cannot use \(backendID.rawValue): \(reason)"
        case .preparedBackendMismatch(let backendID):
            "The prepared backend changed identity from \(backendID.rawValue)."
        case .activationBlocked(let failure):
            "The durable job was contained because its bookmarks or request record could not be activated: \(String(describing: failure))."
        case .preparedPlanChanged(let jobID):
            "The source, runtime, output, or plan binding changed before \(jobID) could run."
        case .noActiveJob:
            "There is no active durable job."
        case .pauseNotAllowed(let lifecycle):
            "A pause request is not valid while the durable job is \(lifecycle.rawValue)."
        case .cancellationNotAllowed(let lifecycle):
            "Cancellation is no longer safe while the durable job is \(lifecycle.rawValue)."
        case .heartbeatFailed(let reason):
            "The durable worker lease could not be renewed: \(reason)"
        case .workingSegmentConflict(let path):
            "A pre-existing checkpoint segment must be reconciled before processing: \(path)"
        case .checkpointMissing(let jobID):
            "The paused durable job \(jobID) has no compatible checkpoint."
        case .invalidAssembledOutput(let reason):
            "The assembled durable output is invalid: \(reason)"
        }
    }
}

struct WorkflowApplicationPreparedSubmissionV4: Sendable {
    let request: UpscaleRequest
    let binding: WorkflowVerifiedPreparedPlanBindingV4
}

struct WorkflowApplicationProcessedSegmentV4: Sendable {
    let source: VideoInfo
    let segment: DeterministicV4MediaSegmentResultV4
    let temporalCheckpoint: Data
    let trackProgress: [WorkflowTrackProgressV4]
}

struct WorkflowApplicationCompletionV4: Sendable {
    let source: VideoInfo
    let result: UpscaleResult
}

enum WorkflowApplicationRunOutcomeV4: Sendable {
    case completed(WorkflowApplicationCompletionV4)
    case paused(jobID: WorkflowJobID, source: VideoInfo)
}

enum WorkflowApplicationExecutionEventV4: Sendable {
    case finished(
        jobID: WorkflowJobID,
        outcome: WorkflowApplicationRunOutcomeV4
    )
    case failed(jobID: WorkflowJobID, message: String)
}

struct WorkflowApplicationObserverV4: Sendable {
    let progress: @Sendable (WorkflowJobID, UpscaleProgress) -> Void
    let snapshot: @Sendable (WorkflowApplicationQueueSnapshotV4) -> Void
    let execution: @Sendable (WorkflowApplicationExecutionEventV4) -> Void

    static let none = WorkflowApplicationObserverV4(
        progress: { _, _ in },
        snapshot: { _ in },
        execution: { _ in }
    )
}

protocol WorkflowApplicationDeterministicExecutingV4: Sendable {
    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4

    func revalidateAndPrepare(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4
    ) async throws -> VideoInfo

    func processPrepared(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames: Int,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4

    func restorePrepared(
        jobID: WorkflowJobID,
        temporalCheckpoint: Data,
        lastCompletedInputOrdinal: Int64
    ) async throws

    func finalizePreparedOutput(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        assembledVideoURL: URL,
        publicationURL: URL,
        migrationTemporaryURL: URL,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4

    func inspectCompletion(
        request: UpscaleRequest,
        checkpoint: WorkflowCheckpointDocumentV4,
        segmentResult: UpscaleResult?,
        processingDurationSeconds: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4

    func abandonPrepared(jobID: WorkflowJobID) async
}

protocol WorkflowApplicationControllingV4: Sendable {
    func installObserver(_ observer: WorkflowApplicationObserverV4) async
    func launch() async throws -> WorkflowApplicationLaunchSnapshotV4

    func enqueue(
        request: UpscaleRequest,
        priority: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4

    func submit(
        request: UpscaleRequest,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4

    func requestPause() async throws
    func cancelActive() async throws

    func resume(
        jobID: WorkflowJobID,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4

    func setPriority(jobID: WorkflowJobID, value: Int32) async throws
    func move(
        jobID: WorkflowJobID,
        direction: WorkflowApplicationQueueMoveV4
    ) async throws
}

actor WorkflowDeterministicApplicationEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    private struct PreparedExecution: Sendable {
        let source: VideoInfo
        let backend: any PreparedDeterministicV4RuntimePlanningBackend
        let plan: DeterministicV4PreparedAssetPlan
    }

    private let videoProbe: any VideoProbing
    private let backendCatalog: UpscaleBackendCatalog
    private let runtimeEnvironment: RuntimeEnvironment
    private let planner: DeterministicV4WholeAssetPlanner
    private let session: DeterministicV4MediaProcessingSession
    private var preparedByJobID: [WorkflowJobID: PreparedExecution] = [:]

    init(
        videoProbe: any VideoProbing,
        backendCatalog: UpscaleBackendCatalog,
        runtimeEnvironment: RuntimeEnvironment,
        planner: DeterministicV4WholeAssetPlanner = .init(),
        session: DeterministicV4MediaProcessingSession = .init()
    ) {
        self.videoProbe = videoProbe
        self.backendCatalog = backendCatalog
        self.runtimeEnvironment = runtimeEnvironment
        self.planner = planner
        self.session = session
    }

    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        let source = try await videoProbe.probe(url: request.inputURL)
        let resolved = try await resolvedRequest(request, source: source)
        let backend = try await preparedBackend(
            request: resolved,
            source: source
        )
        do {
            let plan = try await planner.prepare(
                request: resolved,
                source: source,
                backend: backend
            )
            let binding = try WorkflowApplicationQueueV4.preparedBinding(
                preparedPlan: plan,
                request: resolved,
                resolvedBackendID: resolved.backendID
            )
            await plan.finishProcessingBackend(planningBackend: backend)
            return WorkflowApplicationPreparedSubmissionV4(
                request: resolved,
                binding: binding
            )
        } catch {
            try? await backend.finish()
            throw error
        }
    }

    func revalidateAndPrepare(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4
    ) async throws -> VideoInfo {
        let source = try await videoProbe.probe(url: request.inputURL)
        let backend = try await preparedBackend(
            request: request,
            source: source
        )
        do {
            let plan = try await planner.prepare(
                request: request,
                source: source,
                backend: backend
            )
            let actualBinding = try WorkflowApplicationQueueV4.preparedBinding(
                preparedPlan: plan,
                request: request,
                resolvedBackendID: request.backendID
            )
            guard actualBinding == expectedBinding else {
                throw WorkflowApplicationControllerErrorV4
                    .preparedPlanChanged(jobID)
            }
            if let previous = preparedByJobID.removeValue(forKey: jobID) {
                await previous.plan.finishProcessingBackend(
                    planningBackend: previous.backend
                )
            }
            preparedByJobID[jobID] = PreparedExecution(
                source: source,
                backend: backend,
                plan: plan
            )
            return source
        } catch {
            try? await backend.finish()
            throw error
        }
    }

    func processPrepared(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames: Int,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        guard let prepared = preparedByJobID[jobID] else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let segment = try await session.processSegment(
            request: request,
            source: prepared.source,
            preparedPlan: prepared.plan,
            preparedBackend: prepared.backend,
            startingInputFrameIndex: startingInputFrameIndex,
            startTime: startTime,
            maximumInputFrames: maximumInputFrames,
            segmentURL: request.outputURL,
            cancellation: cancellation,
            progress: progress
        )
        let checkpointable = try prepared.plan
            .checkpointableProcessingBackend(
                planningBackend: prepared.backend
            )
        let temporalCheckpoint = try await checkpointable
            .makeTemporalCheckpoint(
                planSHA256: prepared.plan.ashPlan.planSHA256,
                lastCompletedInputOrdinal:
                    segment.lastCompletedInputOrdinal
            )
        let trackProgress = try await checkpointTrackProgress(
            prepared: prepared,
            segment: segment,
            previousCheckpoint: previousCheckpoint
        )
        return WorkflowApplicationProcessedSegmentV4(
            source: prepared.source,
            segment: segment,
            temporalCheckpoint: temporalCheckpoint,
            trackProgress: trackProgress
        )
    }

    func restorePrepared(
        jobID: WorkflowJobID,
        temporalCheckpoint: Data,
        lastCompletedInputOrdinal: Int64
    ) async throws {
        guard let prepared = preparedByJobID[jobID],
              lastCompletedInputOrdinal >= 0 else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let checkpointable = try prepared.plan
            .checkpointableProcessingBackend(
                planningBackend: prepared.backend
            )
        try await checkpointable.restoreTemporalCheckpoint(
            temporalCheckpoint,
            planSHA256: prepared.plan.ashPlan.planSHA256
        )
    }

    func finalizePreparedOutput(
        jobID: WorkflowJobID,
        request: UpscaleRequest,
        assembledVideoURL: URL,
        publicationURL: URL,
        migrationTemporaryURL: URL,
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        guard let prepared = preparedByJobID[jobID] else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let migrationCancellation = AVFoundationTrackMigrationCancellationV4()
        let monitor = Task {
            while !Task.isCancelled {
                do {
                    try cancellation.check()
                } catch {
                    migrationCancellation.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { monitor.cancel() }
        do {
            let result = try await AVFoundationTrackMigrationExecutorV4().execute(
                .init(
                    sourceURL: request.inputURL,
                    destinationURL: publicationURL,
                    temporaryURL: migrationTemporaryURL,
                    outputFileType: .mov,
                    overwriteExistingFile: false,
                    sourceGraph: prepared.plan.sourceGraph,
                    identifiedPlan: prepared.plan.trackPlan,
                    blueprint: prepared.plan.migrationBlueprint,
                    processedVideoReplacement: .init(
                        trackID: prepared.plan.primaryGraphTrack.identity.stableID,
                        sourceURL: assembledVideoURL
                    )
                ),
                cancellation: migrationCancellation,
                progress: { state in
                    progress(UpscaleProgress(
                        phase: state.stage == .completed
                            ? .validatingOutput : .finalizing,
                        fractionCompleted: state.stage == .completed ? 1 : nil,
                        processedFrameCount: Int(
                            clamping: state.migratedSampleCount
                        ),
                        processedTime: nil,
                        duration: prepared.source.duration,
                        actualBackendID: prepared.backend.actualBackendID
                    ))
                }
            )
            return WorkflowApplicationFinalizedOutputV4(
                destinationURL: result.destinationURL,
                verification: try WorkflowApplicationMigrationVerificationV4(
                    result
                )
            )
        } catch AVFoundationTrackMigrationExecutorV4Error.cancelled {
            throw MirmirError.cancelled
        }
    }

    func inspectCompletion(
        request: UpscaleRequest,
        checkpoint: WorkflowCheckpointDocumentV4,
        segmentResult: UpscaleResult?,
        processingDurationSeconds: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        let source = try await videoProbe.probe(url: request.inputURL)
        let output = try await videoProbe.probe(url: request.outputURL)
        guard let encodedSize = output.geometry.encodedSize,
              encodedSize.width.isFinite,
              encodedSize.height.isFinite,
              let width = Int(exactly: encodedSize.width.rounded()),
              let height = Int(exactly: encodedSize.height.rounded()),
              width == request.targetWidth,
              height == request.targetHeight else {
            throw WorkflowApplicationControllerErrorV4.invalidAssembledOutput(
                "the encoded raster does not match the durable request"
            )
        }
        let videoFrames = checkpoint.body.trackProgress
            .filter { $0.kind == .video }
            .reduce(UInt64(0)) { partial, track in
                partial.addingReportingOverflow(
                    track.nextOutputSampleIndex
                ).partialValue
            }
        let result = UpscaleResult(
            outputURL: request.outputURL,
            actualBackendID: request.backendID,
            encodedWidth: width,
            encodedHeight: height,
            durationSeconds: CMTimeGetSeconds(output.duration),
            outputCodec: request.outputCodec,
            audioResult: request.preserveAudio
                ? (output.hasAudio ? .preserved : .absent)
                : .omitted,
            processedFrameCount: segmentResult?.processedFrameCount
                ?? Int(clamping: videoFrames),
            processingDurationSeconds: max(
                segmentResult?.processingDurationSeconds ?? 0,
                processingDurationSeconds
            )
        )
        return WorkflowApplicationCompletionV4(
            source: source,
            result: result
        )
    }

    func abandonPrepared(jobID: WorkflowJobID) async {
        guard let prepared = preparedByJobID.removeValue(forKey: jobID) else {
            return
        }
        await prepared.plan.finishProcessingBackend(
            planningBackend: prepared.backend
        )
    }
}

private extension WorkflowDeterministicApplicationEngineV4 {
    private func checkpointTrackProgress(
        prepared: PreparedExecution,
        segment: DeterministicV4MediaSegmentResultV4,
        previousCheckpoint: WorkflowCheckpointDocumentV4?
    ) async throws -> [WorkflowTrackProgressV4] {
        let previous = Dictionary(
            uniqueKeysWithValues: (previousCheckpoint?.body.trackProgress ?? [])
                .map { ($0.trackID, $0) }
        )
        let asset = AVURLAsset(
            url: prepared.source.url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let assetTracks = try await asset.load(.tracks)
        guard assetTracks.count == prepared.plan.sourceGraph.tracks.count else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("source track inventory changed")
        }
        let plannedByID = Dictionary(
            uniqueKeysWithValues: prepared.plan.trackPlan.plan.tracks.map {
                ($0.source.identity.stableID, $0)
            }
        )
        var result: [WorkflowTrackProgressV4] = []
        for (node, track) in zip(
            prepared.plan.sourceGraph.tracks,
            assetTracks
        ) {
            let id = node.identity.stableID.rawValue
            let kind = checkpointKind(node.kind)
            if node.identity.stableID
                == prepared.plan.primaryGraphTrack.identity.stableID {
                let priorOutput = previous[id]?.nextOutputSampleIndex ?? 0
                result.append(try WorkflowTrackProgressV4(
                    trackID: id,
                    kind: kind,
                    nextInputSampleIndex: UInt64(
                        segment.lastCompletedInputOrdinal + 1
                    ),
                    nextOutputSampleIndex: priorOutput + UInt64(
                        segment.outputSampleCount
                    ),
                    lastInputTime: segment.endTimeExclusive,
                    lastOutputTime: segment.endTimeExclusive,
                    isComplete: segment.terminal
                ))
                continue
            }
            let observed = try await sourceProgress(
                asset: asset,
                track: track,
                through: segment.endTimeExclusive
            )
            let action = plannedByID[node.identity.stableID]?.action
            result.append(try WorkflowTrackProgressV4(
                trackID: id,
                kind: kind,
                nextInputSampleIndex: observed.count,
                nextOutputSampleIndex: 0,
                lastInputTime: observed.lastEnd,
                lastOutputTime: nil,
                isComplete: segment.terminal && action == .dropWithConsent
            ))
        }
        return result
    }

    func sourceProgress(
        asset: AVAsset,
        track: AVAssetTrack,
        through boundary: WorkflowMediaTimeV4
    ) async throws -> (count: UInt64, lastEnd: WorkflowMediaTimeV4?) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("source progress reader rejected a track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("source progress reader failed")
        }
        let end = CMTime(value: boundary.value, timescale: boundary.timescale)
        var count: UInt64 = 0
        var lastEnd: WorkflowMediaTimeV4?
        while let sample = output.copyNextSampleBuffer() {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            guard presentation.isNumeric else { continue }
            if CMTimeCompare(presentation, end) >= 0 { break }
            count += 1
            let duration = CMSampleBufferGetDuration(sample)
            let sampleEnd = duration.isNumeric && duration.value > 0
                ? CMTimeAdd(presentation, duration) : presentation
            lastEnd = try WorkflowMediaTimeV4(
                value: sampleEnd.value,
                timescale: sampleEnd.timescale
            )
        }
        reader.cancelReading()
        return (count, lastEnd)
    }

    nonisolated func checkpointKind(
        _ kind: MediaTrackKindV4
    ) -> WorkflowCheckpointTrackKindV4 {
        switch kind {
        case .video: .video
        case .audio: .audio
        case .subtitle: .subtitle
        case .caption: .caption
        case .timecode: .timecode
        case .timedMetadata: .timedMetadata
        case .chapter: .chapter
        case .auxiliary, .unknown: .auxiliary
        }
    }

    func resolvedRequest(
        _ request: UpscaleRequest,
        source: VideoInfo
    ) async throws -> UpscaleRequest {
        let snapshot = await backendCatalog.snapshot(
            for: source,
            targetSize: request.targetSize,
            environment: runtimeEnvironment
        )
        let resolution = snapshot.resolution(for: request.backendID)
        guard resolution.availability == .available,
              let actualBackendID = resolution.actualBackendID else {
            throw WorkflowApplicationControllerErrorV4.backendUnavailable(
                request.backendID,
                resolution.availability.statusText
            )
        }
        return UpscaleRequest(
            inputURL: request.inputURL,
            outputURL: request.outputURL,
            backendID: actualBackendID,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            outputCodec: request.outputCodec,
            preserveAudio: request.preserveAudio,
            overwriteExistingFile: request.overwriteExistingFile
        )
    }

    func preparedBackend(
        request: UpscaleRequest,
        source: VideoInfo
    ) async throws -> any PreparedDeterministicV4RuntimePlanningBackend {
        guard request.backendID == .mirmirDeterministicCPU
                || request.backendID == .mirmirDeterministicMetal else {
            throw WorkflowApplicationControllerErrorV4
                .deterministicBackendRequired(request.backendID)
        }
        let prepared = try await backendCatalog.prepare(
            backendID: request.backendID,
            request: BackendPreparationRequest(
                source: source,
                targetSize: request.targetSize
            ),
            environment: runtimeEnvironment
        )
        guard prepared.actualBackendID == request.backendID,
              let deterministic = prepared
                as? any PreparedDeterministicV4RuntimePlanningBackend else {
            try? await prepared.finish()
            throw WorkflowApplicationControllerErrorV4
                .preparedBackendMismatch(request.backendID)
        }
        return deterministic
    }
}

actor WorkflowApplicationCoordinatorV4: WorkflowApplicationControllingV4 {
    private struct ActiveExecution: Sendable {
        let dispatch: WorkflowQueueDispatchReceiptV4
        let cancellation: ProcessingCancellation
        let attemptID: WorkflowAttemptID
        let snapshotHandler: @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
        var lifecycle: WorkflowJobLifecycle
        var pauseRequested: Bool
        var cancelRequested: Bool
        var heartbeatFailure: String?
    }

    private let queue: WorkflowApplicationQueueV4
    private let engine: any WorkflowApplicationDeterministicExecutingV4
    private let maximumInputFramesPerBoundary: Int
    private var active: ActiveExecution?
    private var heartbeatTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var publicationRecoveryTask: Task<Void, Never>?
    private var observer = WorkflowApplicationObserverV4.none
    private var currentDrainJobID: WorkflowJobID?
    private var completionWaiters: [
        WorkflowJobID:
            [CheckedContinuation<WorkflowApplicationRunOutcomeV4, Error>]
    ] = [:]
    private var waiterProgressHandlers: [
        WorkflowJobID: @Sendable (UpscaleProgress) -> Void
    ] = [:]
    private var waiterSnapshotHandlers: [
        WorkflowJobID:
            @Sendable (WorkflowApplicationQueueSnapshotV4) -> Void
    ] = [:]
    private var drainRescheduleRequested = false

    private static let dispatchCapacityRetryNanoseconds: UInt64 =
        1_000_000_000

    init(
        queue: WorkflowApplicationQueueV4,
        engine: any WorkflowApplicationDeterministicExecutingV4,
        maximumInputFramesPerBoundary: Int = 60
    ) {
        precondition(maximumInputFramesPerBoundary > 0)
        self.queue = queue
        self.engine = engine
        self.maximumInputFramesPerBoundary = maximumInputFramesPerBoundary
    }

    static func live(
        applicationIdentifier: String,
        videoProbe: any VideoProbing,
        backendCatalog: UpscaleBackendCatalog,
        runtimeEnvironment: RuntimeEnvironment
    ) throws -> WorkflowApplicationCoordinatorV4 {
        let queue = try WorkflowApplicationQueueV4.live(
            applicationIdentifier: applicationIdentifier
        )
        return WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: videoProbe,
                backendCatalog: backendCatalog,
                runtimeEnvironment: runtimeEnvironment
            )
        )
    }

    func launch() async throws -> WorkflowApplicationLaunchSnapshotV4 {
        let publicationRecoveryDeferred = try await
            recoverInterruptedPublications()
        let snapshot = try await queue.launchSnapshot(
            commandKey: try Self.commandKey(stage: "launch-recovery")
        )
        try await queue.cleanupCompletedApplicationPublications()
        observer.snapshot(snapshot.queue)
        if publicationRecoveryDeferred {
            schedulePublicationRecoveryRetry()
        }
        scheduleDrain()
        return snapshot
    }

    func installObserver(_ observer: WorkflowApplicationObserverV4) async {
        self.observer = observer
    }

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4 {
        try await queue.queueSnapshot()
    }

    func enqueue(
        request: UpscaleRequest,
        priority: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4 {
        let receipt = try await enqueuePrepared(
            request: request,
            priority: priority
        )
        scheduleDrain()
        return receipt
    }

    func setPriority(jobID: WorkflowJobID, value: Int32) async throws {
        try await queue.setApplicationJobPriority(jobID: jobID, value: value)
        await emitSnapshot(to: observer.snapshot)
    }

    func move(
        jobID: WorkflowJobID,
        direction: WorkflowApplicationQueueMoveV4
    ) async throws {
        try await queue.moveApplicationJob(
            jobID: jobID,
            direction: direction
        )
        await emitSnapshot(to: observer.snapshot)
    }

    func submit(
        request: UpscaleRequest,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        let receipt = try await enqueuePrepared(
            request: request,
            priority: 0
        )
        let jobID = receipt.specification.jobID
        waiterProgressHandlers[jobID] = progress
        waiterSnapshotHandlers[jobID] = snapshot
        return try await withCheckedThrowingContinuation { continuation in
            completionWaiters[jobID, default: []].append(continuation)
            scheduleDrain()
        }
    }

    func requestPause() async throws {
        guard var current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        switch current.lifecycle {
        case .probing, .planned:
            current.pauseRequested = true
            active = current
        case .running:
            _ = try await queue.requestApplicationPause(
                current.dispatch,
                commandKey: try Self.commandKey(
                    stage: "pause-request",
                    jobID: current.dispatch.claim.jobID
                )
            )
            current.lifecycle = .pausing
            current.pauseRequested = true
            active = current
            await emitSnapshot(to: current.snapshotHandler)
        case .pausing:
            current.pauseRequested = true
            active = current
        default:
            throw WorkflowApplicationControllerErrorV4.pauseNotAllowed(
                current.lifecycle
            )
        }
    }

    func cancelActive() async throws {
        guard var current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        guard current.lifecycle != .committing,
              !current.lifecycle.isTerminal else {
            throw WorkflowApplicationControllerErrorV4
                .cancellationNotAllowed(current.lifecycle)
        }
        current.cancelRequested = true
        current.cancellation.cancel()
        active = current
    }

    func resume(
        jobID: WorkflowJobID,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        guard active == nil else {
            throw WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted
        }
        let attemptID = try Self.attemptID(jobID: jobID)
        let dispatch = try await queue.resumeApplicationJob(
            jobID: jobID,
            commandKey: try Self.commandKey(
                stage: "resume",
                jobID: jobID
            ),
            attemptID: attemptID
        )
        let cancellation = ProcessingCancellation()
        active = ActiveExecution(
            dispatch: dispatch,
            cancellation: cancellation,
            attemptID: attemptID,
            snapshotHandler: snapshot,
            lifecycle: .running,
            pauseRequested: false,
            cancelRequested: false,
            heartbeatFailure: nil
        )
        startHeartbeat(jobID: jobID)
        await emitSnapshot(to: snapshot)

        let activation = await queue.activate(jobID: jobID)
        guard case .active(let activated) = activation else {
            let failure: WorkflowApplicationActivationFailureV4
            if case .blocked(let blocked) = activation {
                failure = blocked
            } else {
                failure = .jobNotFound
            }
            let error = WorkflowApplicationControllerErrorV4
                .activationBlocked(failure)
            await terminateActive(error: error, containmentRequired: true)
            throw error
        }
        defer { activated.close() }
        do {
            try activated.revalidateAll()
            guard let checkpoint = try await queue
                .compatibleApplicationCheckpoint(
                    jobID: jobID,
                    outputContractID:
                        activated.preparedPlanBinding.outputContractID
                ) else {
                throw WorkflowApplicationControllerErrorV4
                    .checkpointMissing(jobID)
            }
            let source = try await engine.revalidateAndPrepare(
                jobID: jobID,
                request: activated.request,
                expectedBinding: activated.preparedPlanBinding
            )
            let payload = try await queue
                .applicationCheckpointResumePayload(checkpoint)
            try await engine.restorePrepared(
                jobID: jobID,
                temporalCheckpoint: payload.temporalCheckpoint,
                lastCompletedInputOrdinal:
                    payload.verification.lastCompletedInputOrdinal
            )
            let outcome = try await continueProcessing(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                source: source,
                checkpoint: checkpoint,
                startingInputFrameIndex: Int(
                    payload.verification.lastCompletedInputOrdinal + 1
                ),
                processingDurationSeconds: 0,
                progress: progress,
                snapshot: snapshot
            )
            stopHeartbeat()
            active = nil
            await emitSnapshot(to: snapshot)
            scheduleDrain()
            return outcome
        } catch {
            await terminateActive(
                error: error,
                containmentRequired: Self.requiresContainment(error)
            )
            scheduleDrain()
            throw error
        }
    }
}

private extension WorkflowApplicationCoordinatorV4 {
    struct ClaimedOutcome: Sendable {
        let jobID: WorkflowJobID
        let outcome: WorkflowApplicationRunOutcomeV4
    }

    func recoverInterruptedPublications() async throws -> Bool {
        let candidates = try await queue
            .applicationPublicationRecoveryCandidates()
        var deferred = false
        for candidate in candidates {
            guard active == nil else {
                deferred = true
                continue
            }
            let commandKey = try Self.commandKey(
                stage: "publication-recovery",
                jobID: candidate.jobID
            )
            let claim = try await queue.beginApplicationPublicationRecovery(
                jobID: candidate.jobID,
                commandKey: commandKey
            )
            let dispatch: WorkflowQueueDispatchReceiptV4
            switch claim {
            case .claimed(let receipt):
                dispatch = receipt
            case .deferred:
                deferred = true
                continue
            case .terminal, .contained:
                continue
            }

            let cancellation = ProcessingCancellation()
            active = ActiveExecution(
                dispatch: dispatch,
                cancellation: cancellation,
                attemptID: try Self.attemptID(jobID: candidate.jobID),
                snapshotHandler: observer.snapshot,
                lifecycle: .recovering,
                pauseRequested: false,
                cancelRequested: false,
                heartbeatFailure: nil
            )
            startHeartbeat(jobID: candidate.jobID)
            await emitSnapshot(to: observer.snapshot)
            do {
                let completion = try await recoverInterruptedPublication(
                    dispatch: dispatch,
                    cancellation: cancellation
                )
                try throwIfActiveControlFailed()
                _ = try await queue.completeApplicationPublicationRecovery(
                    dispatch,
                    target: .completed,
                    commandKey: commandKey
                )
                stopHeartbeat()
                active = nil
                await engine.abandonPrepared(jobID: candidate.jobID)
                observer.execution(
                    .finished(
                        jobID: candidate.jobID,
                        outcome: .completed(completion)
                    )
                )
                await emitSnapshot(to: observer.snapshot)
            } catch {
                await terminateActive(
                    error: error,
                    containmentRequired: true
                )
                observer.execution(
                    .failed(
                        jobID: candidate.jobID,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return deferred
    }

    func recoverInterruptedPublication(
        dispatch: WorkflowQueueDispatchReceiptV4,
        cancellation: ProcessingCancellation
    ) async throws -> WorkflowApplicationCompletionV4 {
        let jobID = dispatch.claim.jobID
        let activation = await queue.activate(jobID: jobID)
        guard case .active(let activated) = activation else {
            let failure: WorkflowApplicationActivationFailureV4
            if case .blocked(let blocked) = activation {
                failure = blocked
            } else {
                failure = .jobNotFound
            }
            throw WorkflowApplicationControllerErrorV4
                .activationBlocked(failure)
        }
        defer { activated.close() }
        try activated.revalidateAll()
        guard let checkpoint = try await queue
            .compatibleApplicationCheckpoint(
                jobID: jobID,
                outputContractID:
                    activated.preparedPlanBinding.outputContractID
            ), checkpointIsTerminal(checkpoint) else {
            throw WorkflowApplicationControllerErrorV4
                .checkpointMissing(jobID)
        }
        _ = try await queue.verifyApplicationCheckpoint(checkpoint)
        _ = try await engine.revalidateAndPrepare(
            jobID: jobID,
            request: activated.request,
            expectedBinding: activated.preparedPlanBinding
        )
        try throwIfActiveControlFailed()

        let intent = try await queue.prepareApplicationPublication(
            activated: activated,
            checkpoint: checkpoint
        )
        var state = try await queue.applicationPublicationState(jobID: jobID)
        if state?.stageIsVerified != true {
            try await queue.discardApplicationUnverifiedPublicationArtifacts(
                intent,
                activated: activated
            )
            let assembledVideoURL = try await queue
                .applicationAssembledVideoURL(
                    jobID: jobID,
                    checkpointID: checkpoint.body.checkpointID
                )
            do {
                _ = try await queue.assembleApplicationCheckpoint(
                    checkpoint,
                    destinationURL: assembledVideoURL,
                    overwriteExistingFile: false
                )
                try throwIfActiveControlFailed()
                let finalized = try await engine.finalizePreparedOutput(
                    jobID: jobID,
                    request: activated.request,
                    assembledVideoURL: assembledVideoURL,
                    publicationURL: try await queue
                        .applicationPublicationStagingURL(
                            intent,
                            activated: activated
                        ),
                    migrationTemporaryURL: try await queue
                        .applicationPublicationMigrationTemporaryURL(
                            intent,
                            activated: activated
                        ),
                    cancellation: cancellation,
                    progress: { [weak self] progress in
                        Task {
                            await self?.forwardProgress(
                                jobID: jobID,
                                progress: progress
                            )
                        }
                    }
                )
                _ = try await queue.recordApplicationStagedPublication(
                    intent,
                    finalized: finalized,
                    activated: activated
                )
                try await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
            } catch {
                try? await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
                throw error
            }
            state = try await queue.applicationPublicationState(jobID: jobID)
        }
        guard state?.stageIsVerified == true else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("publication stage was not verified")
        }
        try throwIfActiveControlFailed()
        _ = try await queue.publishApplicationStagedOutput(
            intent,
            activated: activated
        )
        let completion = try await engine.inspectCompletion(
            request: activated.request,
            checkpoint: checkpoint,
            segmentResult: nil,
            processingDurationSeconds: 0
        )
        return completion
    }

    func schedulePublicationRecoveryRetry() {
        guard publicationRecoveryTask == nil else { return }
        publicationRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let deferred = try await self.recoverInterruptedPublications()
                try await self.queue.cleanupCompletedApplicationPublications()
                let snapshot = try await self.queue.queueSnapshot()
                await self.forwardSnapshotForLaunch(snapshot)
                await self.clearPublicationRecoveryTask()
                if deferred {
                    await self.schedulePublicationRecoveryRetry()
                } else {
                    await self.scheduleDrain()
                }
            } catch {
                guard let self else { return }
                await self.clearPublicationRecoveryTask()
                await self.schedulePublicationRecoveryRetry()
            }
        }
    }

    func clearPublicationRecoveryTask() {
        publicationRecoveryTask = nil
    }

    func forwardSnapshotForLaunch(
        _ snapshot: WorkflowApplicationQueueSnapshotV4
    ) {
        observer.snapshot(snapshot)
    }

    func enqueuePrepared(
        request: UpscaleRequest,
        priority: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4 {
        let prepared = try await engine.prepareSubmission(request: request)
        let receipt = try await queue.enqueue(
            request: prepared.request,
            preparedPlanBinding: prepared.binding,
            priority: priority
        )
        await emitSnapshot(to: observer.snapshot)
        return receipt
    }

    func scheduleDrain() {
        if drainTask != nil {
            drainRescheduleRequested = true
            return
        }
        drainRescheduleRequested = false
        drainTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    func drainQueue() async {
        while !Task.isCancelled {
            guard active == nil else { break }
            currentDrainJobID = nil
            do {
                let outcome = try await runNext(
                    progress: { [weak self] jobID, progress in
                        Task {
                            await self?.forwardProgress(
                                jobID: jobID,
                                progress: progress
                            )
                        }
                    },
                    snapshot: { [weak self] jobID, snapshot in
                        Task {
                            await self?.forwardSnapshot(
                                jobID: jobID,
                                snapshot: snapshot
                            )
                        }
                    }
                )
                currentDrainJobID = outcome.jobID
                finish(
                    jobID: outcome.jobID,
                    result: .success(outcome.outcome)
                )
            } catch WorkflowApplicationControllerErrorV4.noDispatchableJob {
                break
            } catch WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted {
                do {
                    try await Task.sleep(
                        nanoseconds: Self.dispatchCapacityRetryNanoseconds
                    )
                } catch {
                    break
                }
                continue
            } catch {
                guard let jobID = currentDrainJobID else { break }
                finish(jobID: jobID, result: .failure(error))
            }
        }
        currentDrainJobID = nil
        drainTask = nil
        if drainRescheduleRequested {
            drainRescheduleRequested = false
            scheduleDrain()
        }
    }

    func forwardProgress(
        jobID: WorkflowJobID,
        progress: UpscaleProgress
    ) {
        observer.progress(jobID, progress)
        waiterProgressHandlers[jobID]?(progress)
    }

    func forwardSnapshot(
        jobID: WorkflowJobID,
        snapshot: WorkflowApplicationQueueSnapshotV4
    ) {
        observer.snapshot(snapshot)
        waiterSnapshotHandlers[jobID]?(snapshot)
    }

    func finish(
        jobID: WorkflowJobID,
        result: Result<WorkflowApplicationRunOutcomeV4, Error>
    ) {
        let waiters = completionWaiters.removeValue(forKey: jobID) ?? []
        waiterProgressHandlers.removeValue(forKey: jobID)
        waiterSnapshotHandlers.removeValue(forKey: jobID)
        switch result {
        case .success(let outcome):
            observer.execution(.finished(jobID: jobID, outcome: outcome))
            waiters.forEach { $0.resume(returning: outcome) }
        case .failure(let error):
            observer.execution(
                .failed(jobID: jobID, message: error.localizedDescription)
            )
            waiters.forEach { $0.resume(throwing: error) }
        }
    }

    func runNext(
        progress: @escaping @Sendable (
            WorkflowJobID,
            UpscaleProgress
        ) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowJobID,
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> ClaimedOutcome {
        guard active == nil else {
            throw WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted
        }
        let result = try await queue.claimNextApplicationJob(
            cycleID: try Self.cycleID()
        )
        let dispatch: WorkflowQueueDispatchReceiptV4
        switch result {
        case .claimed(let claimed):
            dispatch = claimed
        case .noEligibleJob:
            throw WorkflowApplicationControllerErrorV4.noDispatchableJob
        case .capacityExhausted:
            throw WorkflowApplicationControllerErrorV4
                .dispatchCapacityExhausted
        }
        let jobID = dispatch.claim.jobID
        currentDrainJobID = jobID
        let jobProgress: @Sendable (UpscaleProgress) -> Void = {
            progress(jobID, $0)
        }
        let jobSnapshot: @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void = {
            snapshot(jobID, $0)
        }
        let attemptID = try Self.attemptID(jobID: jobID)
        let cancellation = ProcessingCancellation()
        active = ActiveExecution(
            dispatch: dispatch,
            cancellation: cancellation,
            attemptID: attemptID,
            snapshotHandler: jobSnapshot,
            lifecycle: .probing,
            pauseRequested: false,
            cancelRequested: false,
            heartbeatFailure: nil
        )
        startHeartbeat(jobID: jobID)
        await emitSnapshot(to: jobSnapshot)

        let activation = await queue.activate(jobID: jobID)
        guard case .active(let activated) = activation else {
            let failure: WorkflowApplicationActivationFailureV4
            if case .blocked(let blocked) = activation {
                failure = blocked
            } else {
                failure = .jobNotFound
            }
            let error = WorkflowApplicationControllerErrorV4
                .activationBlocked(failure)
            await terminateActive(error: error, containmentRequired: true)
            throw error
        }
        defer { activated.close() }

        do {
            try activated.revalidateAll()
            let source = try await engine.revalidateAndPrepare(
                jobID: jobID,
                request: activated.request,
                expectedBinding: activated.preparedPlanBinding
            )
            try await transitionActive(
                expected: .probing,
                target: .planned,
                attemptID: nil,
                stage: "planning-complete"
            )
            try await transitionActive(
                expected: .planned,
                target: .running,
                attemptID: attemptID,
                stage: "processing-started"
            )
            if active?.pauseRequested == true {
                _ = try await queue.requestApplicationPause(
                    dispatch,
                    commandKey: try Self.commandKey(
                        stage: "pause-request",
                        jobID: jobID
                    )
                )
                active?.lifecycle = .pausing
                await emitSnapshot(to: jobSnapshot)
            }
            try throwIfActiveControlFailed()

            let outcome = try await continueProcessing(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                source: source,
                checkpoint: nil,
                startingInputFrameIndex: 0,
                processingDurationSeconds: 0,
                progress: jobProgress,
                snapshot: jobSnapshot
            )
            stopHeartbeat()
            active = nil
            await emitSnapshot(to: jobSnapshot)
            return ClaimedOutcome(
                jobID: jobID,
                outcome: outcome
            )
        } catch {
            await engine.abandonPrepared(jobID: jobID)
            await terminateActive(
                error: error,
                containmentRequired: Self.requiresContainment(error)
            )
            throw error
        }
    }

    func continueProcessing(
        dispatch: WorkflowQueueDispatchReceiptV4,
        attemptID: WorkflowAttemptID,
        activated: WorkflowActivatedUpscaleRequestV4,
        source: VideoInfo,
        checkpoint initialCheckpoint: WorkflowCheckpointDocumentV4?,
        startingInputFrameIndex initialFrameIndex: Int,
        processingDurationSeconds initialDuration: TimeInterval,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        let jobID = dispatch.claim.jobID
        var checkpoint = initialCheckpoint
        var nextFrameIndex = initialFrameIndex
        var processingDuration = initialDuration
        if checkpointIsTerminal(checkpoint) {
            let completion = try await finalize(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                checkpoint: checkpoint!,
                processingDurationSeconds: processingDuration,
                progress: progress
            )
            return .completed(completion)
        }

        while true {
            try throwIfActiveControlFailed()
            guard let cancellation = active?.cancellation else {
                throw WorkflowApplicationControllerErrorV4.noActiveJob
            }
            let ordinal = UInt64(checkpoint?.body.segments.count ?? 0)
            let workingURL = try await queue.applicationWorkingSegmentURL(
                jobID: jobID,
                boundaryOrdinal: ordinal
            )
            let workingRequest = Self.request(
                activated.request,
                outputURL: workingURL,
                overwriteExistingFile: false
            )
            let segment: WorkflowApplicationProcessedSegmentV4
            do {
                segment = try await engine.processPrepared(
                    jobID: jobID,
                    request: workingRequest,
                    startingInputFrameIndex: nextFrameIndex,
                    startTime: checkpoint?.body.segments.last?
                        .endTimeExclusive,
                    maximumInputFrames: maximumInputFramesPerBoundary,
                    previousCheckpoint: checkpoint,
                    cancellation: cancellation,
                    progress: progress
                )
            } catch {
                try? await queue.removeApplicationWorkingArtifact(workingURL)
                throw error
            }
            processingDuration += segment.segment.processingDurationSeconds
            try throwIfActiveControlFailed()
            if active?.pauseRequested == true,
               active?.lifecycle == .running {
                _ = try await queue.requestApplicationPause(
                    dispatch,
                    commandKey: try Self.commandKey(
                        stage: "pause-request",
                        jobID: jobID
                    )
                )
                active?.lifecycle = .pausing
                await emitSnapshot(to: snapshot)
            }
            let committed = try await queue
                .commitApplicationCheckpointBoundary(
                    dispatch: dispatch,
                    specification: activated.specification,
                    segment: segment.segment,
                    outputContractID:
                        activated.preparedPlanBinding.outputContractID,
                    previousCheckpoint: checkpoint,
                    trackProgress: segment.trackProgress,
                    temporalCheckpoint: segment.temporalCheckpoint
                )
            try await queue.removeApplicationWorkingArtifact(workingURL)
            checkpoint = committed.checkpoint
            nextFrameIndex = Int(
                segment.segment.lastCompletedInputOrdinal + 1
            )

            if active?.lifecycle == .pausing {
                _ = try await queue.completeApplicationPause(
                    dispatch,
                    commandKey: try Self.commandKey(
                        stage: "pause-commit",
                        jobID: jobID
                    )
                )
                await engine.abandonPrepared(jobID: jobID)
                return .paused(jobID: jobID, source: source)
            }
            if segment.segment.terminal {
                let completion = try await finalize(
                    dispatch: dispatch,
                    attemptID: attemptID,
                    activated: activated,
                    checkpoint: committed.checkpoint,
                    processingDurationSeconds: processingDuration,
                    progress: progress
                )
                return .completed(completion)
            }
        }
    }

    func checkpointIsTerminal(
        _ checkpoint: WorkflowCheckpointDocumentV4?
    ) -> Bool {
        checkpoint?.body.trackProgress.contains(where: {
            $0.kind == .video
                && $0.nextOutputSampleIndex > 0
                && $0.isComplete
        }) == true
    }

    func finalize(
        dispatch: WorkflowQueueDispatchReceiptV4,
        attemptID: WorkflowAttemptID,
        activated: WorkflowActivatedUpscaleRequestV4,
        checkpoint: WorkflowCheckpointDocumentV4,
        processingDurationSeconds: TimeInterval = 0,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationCompletionV4 {
        try throwIfActiveControlFailed()
        try await transitionActive(
            expected: .running,
            target: .verifying,
            attemptID: attemptID,
            stage: "checkpoint-verification"
        )
        _ = try await queue.verifyApplicationCheckpoint(checkpoint)
        try await transitionActive(
            expected: .verifying,
            target: .committing,
            attemptID: nil,
            stage: "output-commit"
        )
        progress(Self.resumeProgress(
            request: activated.request,
            phase: .finalizing
        ))
        let intent = try await queue.prepareApplicationPublication(
            activated: activated,
            checkpoint: checkpoint
        )
        var publication = try await queue.applicationPublicationState(
            jobID: dispatch.claim.jobID
        )
        if publication?.stageIsVerified != true {
            try await queue.discardApplicationUnverifiedPublicationArtifacts(
                intent,
                activated: activated
            )
            let assembledVideoURL = try await queue
                .applicationAssembledVideoURL(
                    jobID: dispatch.claim.jobID,
                    checkpointID: checkpoint.body.checkpointID
                )
            do {
                _ = try await queue.assembleApplicationCheckpoint(
                    checkpoint,
                    destinationURL: assembledVideoURL,
                    overwriteExistingFile: false
                )
                guard let cancellation = active?.cancellation else {
                    throw WorkflowApplicationControllerErrorV4.noActiveJob
                }
                let finalized = try await engine.finalizePreparedOutput(
                    jobID: dispatch.claim.jobID,
                    request: activated.request,
                    assembledVideoURL: assembledVideoURL,
                    publicationURL: try await queue
                        .applicationPublicationStagingURL(
                            intent,
                            activated: activated
                        ),
                    migrationTemporaryURL: try await queue
                        .applicationPublicationMigrationTemporaryURL(
                            intent,
                            activated: activated
                        ),
                    cancellation: cancellation,
                    progress: progress
                )
                _ = try await queue.recordApplicationStagedPublication(
                    intent,
                    finalized: finalized,
                    activated: activated
                )
                try await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
            } catch {
                try? await queue.removeApplicationWorkingArtifact(
                    assembledVideoURL
                )
                throw error
            }
            publication = try await queue.applicationPublicationState(
                jobID: dispatch.claim.jobID
            )
        }
        guard publication?.stageIsVerified == true else {
            throw WorkflowApplicationControllerErrorV4
                .invalidAssembledOutput("publication stage was not verified")
        }
        _ = try await queue.publishApplicationStagedOutput(
            intent,
            activated: activated
        )
        let completion = try await engine.inspectCompletion(
            request: activated.request,
            checkpoint: checkpoint,
            segmentResult: nil,
            processingDurationSeconds: processingDurationSeconds
        )
        try await transitionActive(
            expected: .committing,
            target: .completed,
            attemptID: nil,
            stage: "output-committed",
            releaseAfterTransition: true
        )
        progress(Self.resumeProgress(
            request: activated.request,
            phase: .completed,
            result: completion.result
        ))
        await engine.abandonPrepared(jobID: dispatch.claim.jobID)
        return completion
    }

    func transitionActive(
        expected: WorkflowJobLifecycle,
        target: WorkflowJobLifecycle,
        attemptID: WorkflowAttemptID?,
        stage: String,
        releaseAfterTransition: Bool = false
    ) async throws {
        guard var current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        _ = try await queue.transitionApplicationJob(
            current.dispatch,
            expected: expected,
            target: target,
            commandKey: try Self.commandKey(
                stage: stage,
                jobID: current.dispatch.claim.jobID
            ),
            stage: stage,
            attemptID: attemptID,
            releaseAfterTransition: releaseAfterTransition
        )
        current.lifecycle = target
        active = current
        await emitSnapshot(to: current.snapshotHandler)
    }

    func terminateActive(
        error: Error,
        containmentRequired: Bool
    ) async {
        guard let current = active else { return }
        stopHeartbeat()
        current.cancellation.cancel()
        await engine.abandonPrepared(jobID: current.dispatch.claim.jobID)

        let target: WorkflowJobLifecycle
        if current.lifecycle == .committing {
            let publicationExists = (try? await queue
                .applicationPublicationState(
                    jobID: current.dispatch.claim.jobID
                )) != nil
            // Once an immutable publication intent exists, a commit failure
            // must remain recoverable. The recovery pass either completes the
            // verified publication or contains a permanent conflict.
            target = publicationExists ? .recovering : .contained
        } else if current.cancelRequested || error is CancellationError
            || (error as? MirmirError) == .cancelled {
            target = .cancelled
        } else {
            target = containmentRequired ? .contained : .failed
        }
        if current.lifecycle.allowsTransition(to: target) {
            _ = try? await queue.transitionApplicationJob(
                current.dispatch,
                expected: current.lifecycle,
                target: target,
                commandKey: try Self.commandKey(
                    stage: "terminal-\(target.rawValue)",
                    jobID: current.dispatch.claim.jobID
                ),
                stage: "terminal-\(target.rawValue)",
                attemptID: current.lifecycle == .running
                    || current.lifecycle == .pausing
                    ? current.attemptID
                    : nil,
                releaseAfterTransition: true
            )
        }
        let handler = current.snapshotHandler
        active = nil
        await emitSnapshot(to: handler)
        if target == .recovering {
            schedulePublicationRecoveryRetry()
        }
    }

    func throwIfActiveControlFailed() throws {
        guard let current = active else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        if let heartbeatFailure = current.heartbeatFailure {
            throw WorkflowApplicationControllerErrorV4
                .heartbeatFailed(heartbeatFailure)
        }
        if current.cancelRequested {
            throw CancellationError()
        }
    }

    func startHeartbeat(jobID: WorkflowJobID) {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.performHeartbeat(jobID: jobID)
            }
        }
    }

    func performHeartbeat(jobID: WorkflowJobID) async {
        guard var current = active,
              current.dispatch.claim.jobID == jobID else { return }
        do {
            _ = try await queue.heartbeatApplicationJob(current.dispatch)
        } catch {
            current.heartbeatFailure = error.localizedDescription
            current.cancellation.cancel()
            active = current
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func emitSnapshot(
        to handler: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async {
        guard let value = try? await queue.queueSnapshot() else { return }
        handler(value)
    }

    nonisolated static func request(
        _ request: UpscaleRequest,
        outputURL: URL,
        overwriteExistingFile: Bool
    ) -> UpscaleRequest {
        UpscaleRequest(
            inputURL: request.inputURL,
            outputURL: outputURL,
            backendID: request.backendID,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            outputCodec: request.outputCodec,
            preserveAudio: request.preserveAudio,
            overwriteExistingFile: overwriteExistingFile
        )
    }

    nonisolated static func cycleID() throws -> WorkflowDispatchCycleIDV4 {
        try WorkflowDispatchCycleIDV4(
            "application-cycle-\(UUID().uuidString.lowercased())"
        )
    }

    nonisolated static func attemptID(
        jobID: WorkflowJobID
    ) throws -> WorkflowAttemptID {
        try WorkflowAttemptID(
            "attempt-\(jobID.rawValue)-\(UUID().uuidString.lowercased())"
        )
    }

    nonisolated static func commandKey(
        stage: String,
        jobID: WorkflowJobID? = nil
    ) throws -> WorkflowRecoveryCommandKeyV4 {
        let suffix = jobID.map { "-\($0.rawValue)" } ?? ""
        return try WorkflowRecoveryCommandKeyV4(
            "application-\(stage)\(suffix)-\(UUID().uuidString.lowercased())"
        )
    }

    nonisolated static func requiresContainment(_ error: Error) -> Bool {
        switch error {
        case WorkflowApplicationControllerErrorV4.activationBlocked,
             WorkflowApplicationControllerErrorV4.preparedPlanChanged,
             WorkflowApplicationControllerErrorV4.checkpointMissing,
             WorkflowApplicationQueueErrorV4.requestDocumentMissing,
             WorkflowApplicationQueueErrorV4.requestDocumentCorrupt,
             WorkflowApplicationQueueErrorV4.requestDocumentBindingMismatch,
             WorkflowDurableCoordinatorErrorV4.checkpointIncompatible:
            true
        default:
            false
        }
    }

    nonisolated static func resumeProgress(
        request: UpscaleRequest,
        phase: UpscalePhase,
        result: UpscaleResult? = nil
    ) -> UpscaleProgress {
        UpscaleProgress(
            phase: phase,
            fractionCompleted: phase == .completed ? 1 : nil,
            processedFrameCount: result?.processedFrameCount ?? 0,
            processedTime: nil,
            duration: nil,
            actualBackendID: request.backendID
        )
    }

}
