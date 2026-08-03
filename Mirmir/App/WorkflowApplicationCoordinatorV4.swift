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
    let result: UpscaleResult
}

struct WorkflowApplicationCompletionV4: Sendable {
    let source: VideoInfo
    let result: UpscaleResult
}

enum WorkflowApplicationRunOutcomeV4: Sendable {
    case completed(WorkflowApplicationCompletionV4)
    case paused(jobID: WorkflowJobID, source: VideoInfo)
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
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4

    func inspectCompletion(
        request: UpscaleRequest,
        checkpoint: WorkflowCheckpointDocumentV4,
        segmentResult: UpscaleResult?,
        processingDurationSeconds: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4

    func abandonPrepared(jobID: WorkflowJobID) async
}

protocol WorkflowApplicationControllingV4: Sendable {
    func launch() async throws -> WorkflowApplicationLaunchSnapshotV4

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
}

actor WorkflowDeterministicApplicationEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    private struct PreparedExecution: Sendable {
        let source: VideoInfo
        let backend: any PreparedDeterministicV4PlanningBackend
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
            try await backend.finish()
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
                try? await previous.backend.finish()
            }
            preparedByJobID[jobID] = PreparedExecution(
                source: source,
                backend: backend
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
        cancellation: ProcessingCancellation,
        progress: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        guard let prepared = preparedByJobID.removeValue(forKey: jobID) else {
            throw WorkflowApplicationControllerErrorV4.noActiveJob
        }
        let result = try await session.process(
            request: request,
            source: prepared.source,
            preparedBackend: prepared.backend,
            cancellation: cancellation,
            progress: progress
        )
        return WorkflowApplicationProcessedSegmentV4(
            source: prepared.source,
            result: result
        )
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
        try? await prepared.backend.finish()
    }
}

private extension WorkflowDeterministicApplicationEngineV4 {
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
    ) async throws -> any PreparedDeterministicV4PlanningBackend {
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
                as? any PreparedDeterministicV4PlanningBackend else {
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
    private var active: ActiveExecution?
    private var heartbeatTask: Task<Void, Never>?

    init(
        queue: WorkflowApplicationQueueV4,
        engine: any WorkflowApplicationDeterministicExecutingV4
    ) {
        self.queue = queue
        self.engine = engine
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
        try await queue.launchSnapshot(
            commandKey: try Self.commandKey(stage: "launch-recovery")
        )
    }

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4 {
        try await queue.queueSnapshot()
    }

    func submit(
        request: UpscaleRequest,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        let prepared = try await engine.prepareSubmission(request: request)
        let enqueue = try await queue.enqueue(
            request: prepared.request,
            preparedPlanBinding: prepared.binding
        )
        await emitSnapshot(to: snapshot)

        while true {
            let outcome = try await runNext(
                observedJobID: enqueue.specification.jobID,
                progress: progress,
                snapshot: snapshot
            )
            if outcome.jobID == enqueue.specification.jobID {
                return outcome.outcome
            }
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
            _ = try await queue.verifyApplicationCheckpoint(checkpoint)
            progress(Self.resumeProgress(
                request: activated.request,
                phase: .validatingOutput
            ))
            let completion = try await finalize(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                checkpoint: checkpoint,
                segmentResult: nil,
                progress: progress
            )
            stopHeartbeat()
            active = nil
            await emitSnapshot(to: snapshot)
            return .completed(completion)
        } catch {
            await terminateActive(
                error: error,
                containmentRequired: Self.requiresContainment(error)
            )
            throw error
        }
    }
}

private extension WorkflowApplicationCoordinatorV4 {
    struct ClaimedOutcome: Sendable {
        let jobID: WorkflowJobID
        let outcome: WorkflowApplicationRunOutcomeV4
    }

    func runNext(
        observedJobID: WorkflowJobID,
        progress: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot: @escaping @Sendable (
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
        let attemptID = try Self.attemptID(jobID: jobID)
        let cancellation = ProcessingCancellation()
        active = ActiveExecution(
            dispatch: dispatch,
            cancellation: cancellation,
            attemptID: attemptID,
            snapshotHandler: snapshot,
            lifecycle: .probing,
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
                await emitSnapshot(to: snapshot)
            }
            try throwIfActiveControlFailed()

            let workingURL = try Self.workingSegmentURL(
                request: activated.request,
                jobID: jobID
            )
            let workingRequest = Self.request(
                activated.request,
                outputURL: workingURL,
                overwriteExistingFile: false
            )
            let startedAt = Date()
            let segment = try await engine.processPrepared(
                jobID: jobID,
                request: workingRequest,
                cancellation: cancellation,
                progress: progress
            )
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
            let checkpoint = try await queue.commitTerminalApplicationCheckpoint(
                dispatch: dispatch,
                specification: activated.specification,
                segmentURL: workingURL,
                outputContractID:
                    activated.preparedPlanBinding.outputContractID,
                processedInputFrameCount: segment.result.processedFrameCount
            )
            try Self.removeCommittedWorkingSegment(workingURL)

            if active?.lifecycle == .pausing {
                _ = try await queue.completeApplicationPause(
                    dispatch,
                    commandKey: try Self.commandKey(
                        stage: "pause-commit",
                        jobID: jobID
                    )
                )
                stopHeartbeat()
                active = nil
                await emitSnapshot(to: snapshot)
                return ClaimedOutcome(
                    jobID: jobID,
                    outcome: .paused(jobID: jobID, source: source)
                )
            }

            let completion = try await finalize(
                dispatch: dispatch,
                attemptID: attemptID,
                activated: activated,
                checkpoint: checkpoint.checkpoint,
                segmentResult: segment.result,
                processingDurationSeconds: Date().timeIntervalSince(startedAt),
                progress: progress
            )
            stopHeartbeat()
            active = nil
            await emitSnapshot(to: snapshot)
            return ClaimedOutcome(
                jobID: jobID,
                outcome: .completed(completion)
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

    func finalize(
        dispatch: WorkflowQueueDispatchReceiptV4,
        attemptID: WorkflowAttemptID,
        activated: WorkflowActivatedUpscaleRequestV4,
        checkpoint: WorkflowCheckpointDocumentV4,
        segmentResult: UpscaleResult?,
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
        _ = try await queue.assembleApplicationCheckpoint(
            checkpoint,
            destinationURL: activated.request.outputURL,
            overwriteExistingFile: activated.request.overwriteExistingFile
        )
        let completion = try await engine.inspectCompletion(
            request: activated.request,
            checkpoint: checkpoint,
            segmentResult: segmentResult,
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
        if current.cancelRequested || error is CancellationError
            || (error as? MirmirError) == .cancelled {
            target = current.lifecycle == .committing ? .failed : .cancelled
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

    nonisolated static func workingSegmentURL(
        request: UpscaleRequest,
        jobID: WorkflowJobID
    ) throws -> URL {
        let url = request.outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".mirmir-\(jobID.rawValue).partial.segment.mov",
                isDirectory: false
            )
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WorkflowApplicationControllerErrorV4
                .workingSegmentConflict(url.path)
        }
        return url
    }

    nonisolated static func removeCommittedWorkingSegment(_ url: URL) throws {
        guard WorkflowV4Validation.isMirmirPartialFileName(
            url.lastPathComponent
        ) else {
            throw WorkflowApplicationControllerErrorV4
                .workingSegmentConflict(url.path)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
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
