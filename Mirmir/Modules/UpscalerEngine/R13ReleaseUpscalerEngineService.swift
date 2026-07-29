import CoreMedia
import CoreVideo
import Foundation
import os.lock

struct R13ReleaseUpscaleSessionBinding: Sendable {
    let session: any AppleUpscaleSession
    let route: R03ScaleRoute
    let routeIdentity: AppleUpscaleRouteIdentity

    var processingIdentity: AppleUpscaleProcessingIdentity {
        get throws {
            try AppleUpscaleProcessingIdentity(
                route: routeIdentity,
                fallbackHistory: []
            )
        }
    }
}

typealias R13ReleaseUpscaleSessionFactory = @Sendable (
    _ route: R03ScaleRoute
) async throws -> R13ReleaseUpscaleSessionBinding

typealias R13ReleaseResourceReleaseObserver = @Sendable (_ identity: String) -> Void
typealias R13ReleaseBeforeHandleStart = @Sendable () -> Void
typealias R13ReleaseHardeningRuntimeProvider = @Sendable () throws
    -> R13ReleaseHardeningRuntime?
final class R13ReleaseUpscalerEngineService: UpscalerEngineService,
    R13RecoverableUpscalerEngine,
    R13ReleaseDiagnosticsProviding,
    @unchecked Sendable {
    enum ActiveJobState {
        case idle
        case changingCacheLocation
        case reserved
        case stoppingReserved
        case active(R13ReleaseUpscalerJobHandle)
    }

    private enum ReservationAttempt {
        case reserved
        case rejected(activeState: String)
    }

    private let media: MediaPipelineService
    private let sessionFactory: R13ReleaseUpscaleSessionFactory
    private let normalizer: any R13NV12FrameNormalizing
    private let inputReleaseObserver: R13ReleaseResourceReleaseObserver
    private let diagnosticRecorder: MirmirDiagnosticRecorder
    let hardeningRuntimeProvider:
        R13ReleaseHardeningRuntimeProvider
    private let beforeHandleStart: R13ReleaseBeforeHandleStart
    let cacheLocationStore: R13CacheLocationStore?
    let activeJobState = OSAllocatedUnfairLock(
        initialState: ActiveJobState.idle
    )
    let hardeningRuntimeState:
        OSAllocatedUnfairLock<R13ReleaseHardeningRuntime?>

    var hardeningRuntime: R13ReleaseHardeningRuntime? {
        hardeningRuntimeState.withLock { $0 }
    }

    var availability: UpscalerEngineAvailability { .available }

    init(
        media: MediaPipelineService,
        sessionFactory: @escaping R13ReleaseUpscaleSessionFactory = {
            try await R13A11ProductSessionFactory.makeSession(route: $0)
        },
        normalizer: any R13NV12FrameNormalizing = R13NV12FrameNormalizer(),
        inputReleaseObserver: @escaping R13ReleaseResourceReleaseObserver = { _ in },
        hardeningRuntime: R13ReleaseHardeningRuntime? = nil,
        cacheLocationStore: R13CacheLocationStore? = nil,
        beforeHandleStart: @escaping R13ReleaseBeforeHandleStart = {},
        diagnostics: MirmirDiagnosticStore? = nil
    ) {
        self.media = media
        self.sessionFactory = sessionFactory
        self.normalizer = normalizer
        self.inputReleaseObserver = inputReleaseObserver
        let diagnosticRecorder = MirmirDiagnosticRecorder(
            store: diagnostics
        )
        self.diagnosticRecorder = diagnosticRecorder
        self.cacheLocationStore = cacheLocationStore
        if let cacheLocationStore {
            hardeningRuntimeProvider = {
                try R13ReleaseHardeningRuntime.production(
                    cacheLocation: cacheLocationStore.configuration(),
                    diagnostics: diagnostics
                )
            }
        } else {
            hardeningRuntimeProvider = { hardeningRuntime }
        }
        hardeningRuntimeState = OSAllocatedUnfairLock(
            initialState: hardeningRuntime
        )
        self.beforeHandleStart = beforeHandleStart
    }

    func availability(
        for mode: UpscaleMode
    ) -> UpscalerEngineAvailability {
        R13ReleaseModePolicy.availability(for: mode)
    }

    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle {
        try makeJobHandle(job: job, securityAccess: nil)
    }

    func makeJobHandle(
        job: UpscaleJob,
        securityAccess: R13SecurityScopedAccessSet?
    ) throws -> UpscalerJobHandle {
        var activeStateAtRejection: String?
        diagnosticRecorder.enqueue(
            severity: .info,
            subsystem: "release_engine",
            operation: "submit_job",
            code: "release_job_submit_requested",
            job: job
        )

        do {
            let modeBinding = try R13ReleaseModePolicy.binding(for: job.mode)
            guard AtomicMediaOutput.isValidTemporaryIdentifier(job.identifier) else {
                throw UpscalerEngineError.invalidJobIdentifier(job.identifier)
            }
            guard !FileURLIdentity.refersToSameFile(job.inputURL, job.outputURL) else {
                throw UpscalerEngineError.inputOutputCollision
            }
            let reservation = activeJobState.withLock { state in
                if case .idle = state {
                    state = .reserved
                    return ReservationAttempt.reserved
                }
                return ReservationAttempt.rejected(
                    activeState: Self.diagnosticIdentifier(for: state)
                )
            }
            guard case .reserved = reservation else {
                if case .rejected(let activeState) = reservation {
                    activeStateAtRejection = activeState
                }
                throw UpscalerEngineError.jobAlreadyRunning
            }
            let hardeningRuntime: R13ReleaseHardeningRuntime?
            do {
                hardeningRuntime = try resolveHardeningRuntime()
            } catch {
                activeJobState.withLock { state in
                    switch state {
                    case .reserved, .stoppingReserved:
                        state = .idle
                    case .idle, .changingCacheLocation, .active:
                        preconditionFailure(
                            "R13 active-job reservation changed unexpectedly."
                        )
                    }
                }
                throw error
            }

            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "release_engine",
                operation: "submit_job",
                code: "release_job_submit_accepted",
                job: job
            )
            let handle = R13ReleaseUpscalerJobHandle(
                job: job,
                modeBinding: modeBinding,
                media: media,
                sessionFactory: sessionFactory,
                normalizer: normalizer,
                inputReleaseObserver: inputReleaseObserver,
                hardeningRuntime: hardeningRuntime,
                securityAccess: securityAccess,
                diagnosticRecorder: diagnosticRecorder,
                onTerminal: { [weak self] in
                    self?.activeJobState.withLock { $0 = .idle }
                }
            )
            let cancelImmediately = activeJobState.withLock { state in
                switch state {
                case .reserved:
                    state = .active(handle)
                    return false
                case .stoppingReserved:
                    state = .active(handle)
                    return true
                case .idle, .changingCacheLocation, .active:
                    preconditionFailure(
                        "R13 active-job reservation changed unexpectedly."
                    )
                }
            }
            beforeHandleStart()
            handle.start()
            if cancelImmediately {
                handle.cancel()
            }
            return handle
        } catch {
            let rejectionCode = Self.submissionRejectionCode(error)
            let rejectionSeverity = Self.submissionRejectionSeverity(error)
            let rejectionFields = Self.submissionRejectionFields(
                activeJobState: activeStateAtRejection
            )
            diagnosticRecorder.enqueue(
                severity: rejectionSeverity,
                subsystem: "release_engine",
                operation: "submit_job",
                code: rejectionCode,
                job: job,
                additionalFields: rejectionFields
            )
            throw error
        }
    }

    private static func diagnosticIdentifier(
        for state: ActiveJobState
    ) -> String {
        switch state {
        case .idle:
            return "idle"
        case .changingCacheLocation:
            return "changing_cache_location"
        case .reserved:
            return "reserved"
        case .stoppingReserved:
            return "stopping_reserved"
        case .active:
            return "active"
        }
    }

    private static func submissionRejectionFields(
        activeJobState: String?
    ) -> [MirmirDiagnosticField] {
        guard let activeJobState,
              let value = try? MirmirDiagnosticFieldValue.identifier(
                  activeJobState
              ),
              let field = try? MirmirDiagnosticField(
                  key: "active_job_state",
                  value: value
              ) else {
            return []
        }
        return [field]
    }

    private static func submissionRejectionSeverity(
        _ error: Error
    ) -> MirmirDiagnosticSeverity {
        switch error {
        case UpscalerEngineError.jobAlreadyRunning,
             UpscalerEngineError.invalidJobIdentifier,
             UpscalerEngineError.inputOutputCollision,
             UpscalerEngineError.modeUnavailable:
            return .warning
        default:
            return .error
        }
    }

    private static func submissionRejectionCode(_ error: Error) -> String {
        switch error {
        case UpscalerEngineError.jobAlreadyRunning:
            return "release_job_submit_rejected_already_running"
        case UpscalerEngineError.invalidJobIdentifier:
            return "release_job_submit_rejected_invalid_identifier"
        case UpscalerEngineError.inputOutputCollision:
            return "release_job_submit_rejected_input_output_collision"
        case UpscalerEngineError.modeUnavailable:
            return "release_job_submit_rejected_mode_unavailable"
        default:
            return "release_job_submit_rejected"
        }
    }
}

struct R13ReleaseJobRuntime: Sendable {
    let job: UpscaleJob
    let modeBinding: R13ReleaseModeBinding
    let normalizer: any R13NV12FrameNormalizing
    let inputReleaseObserver: R13ReleaseResourceReleaseObserver
    let hardeningRuntime: R13ReleaseHardeningRuntime?
    let securityAccess: R13SecurityScopedAccessSet?
    let progressContinuation: AsyncStream<UpscaleProgress>.Continuation
    let diagnosticRecorder: MirmirDiagnosticRecorder
}

final class R13ReleaseUpscalerJobHandle: UpscalerJobHandle,
    @unchecked Sendable {
    private struct ExecutionState {
        var task: Task<URL, Error>?
        var cancellationRequested = false
    }

    let progressStream: AsyncStream<UpscaleProgress>

    private let progressContinuation: AsyncStream<UpscaleProgress>.Continuation
    private let job: UpscaleJob
    private let modeBinding: R13ReleaseModeBinding
    private let media: MediaPipelineService
    private let sessionFactory: R13ReleaseUpscaleSessionFactory
    private let normalizer: any R13NV12FrameNormalizing
    private let inputReleaseObserver: R13ReleaseResourceReleaseObserver
    private let hardeningRuntime: R13ReleaseHardeningRuntime?
    private let securityAccessHolder: R13SecurityScopedAccessHolder
    private let diagnosticRecorder: MirmirDiagnosticRecorder
    private let onTerminal: @Sendable () -> Void
    private let executionState = OSAllocatedUnfairLock(
        initialState: ExecutionState()
    )

    init(
        job: UpscaleJob,
        modeBinding: R13ReleaseModeBinding,
        media: MediaPipelineService,
        sessionFactory: @escaping R13ReleaseUpscaleSessionFactory,
        normalizer: any R13NV12FrameNormalizing,
        inputReleaseObserver: @escaping R13ReleaseResourceReleaseObserver,
        hardeningRuntime: R13ReleaseHardeningRuntime?,
        securityAccess: R13SecurityScopedAccessSet? = nil,
        diagnosticRecorder: MirmirDiagnosticRecorder,
        onTerminal: @escaping @Sendable () -> Void
    ) {
        self.job = job
        self.modeBinding = modeBinding
        self.media = media
        self.sessionFactory = sessionFactory
        self.normalizer = normalizer
        self.inputReleaseObserver = inputReleaseObserver
        self.hardeningRuntime = hardeningRuntime
        securityAccessHolder = R13SecurityScopedAccessHolder(securityAccess)
        self.diagnosticRecorder = diagnosticRecorder
        self.onTerminal = onTerminal
        var continuation: AsyncStream<UpscaleProgress>.Continuation!
        progressStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        progressContinuation = continuation
    }

    func start() {
        let runtime = R13ReleaseJobRuntime(
            job: job,
            modeBinding: modeBinding,
            normalizer: normalizer,
            inputReleaseObserver: inputReleaseObserver,
            hardeningRuntime: hardeningRuntime,
            securityAccess: securityAccessHolder.access,
            progressContinuation: progressContinuation,
            diagnosticRecorder: diagnosticRecorder
        )
        let startGate = R13ReleaseTaskStartGate()
        let launchedTask = Task.detached(
            priority: .userInitiated
        ) { [runtime, media, sessionFactory, onTerminal, startGate, securityAccessHolder] in
            defer {
                securityAccessHolder.release()
                runtime.progressContinuation.finish()
                onTerminal()
                runtime.diagnosticRecorder.enqueue(
                    severity: .debug,
                    subsystem: "release_engine",
                    operation: "reset_active_job",
                    code: "release_active_state_reset",
                    job: runtime.job
                )
            }
            await startGate.waitUntilOpen()
            runtime.diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "release_engine",
                operation: "execute_job",
                code: "release_job_handle_started",
                job: runtime.job
            )

            let result: Result<URL, Error>
            do {
                try Task.checkCancellation()
                result = .success(
                    try await Self.runJob(
                        runtime: runtime,
                        media: media,
                        sessionFactory: sessionFactory
                    )
                )
            } catch is CancellationError {
                result = .failure(UpscalerEngineError.cancelled)
            } catch let error as UpscalerEngineError {
                result = .failure(error)
            } catch {
                if Task.isCancelled {
                    result = .failure(UpscalerEngineError.cancelled)
                } else {
                    result = .failure(error)
                }
            }

            switch result {
            case .success:
                runtime.diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "release_engine",
                    operation: "execute_job",
                    code: "release_job_completed",
                    job: runtime.job
                )
            case .failure(let error):
                let cancelled: Bool
                if case UpscalerEngineError.cancelled = error {
                    cancelled = true
                } else {
                    cancelled = false
                }
                runtime.diagnosticRecorder.enqueue(
                    severity: cancelled ? .notice : .error,
                    subsystem: "release_engine",
                    operation: "execute_job",
                    code: cancelled
                        ? "release_job_cancelled"
                        : "release_job_failed",
                    job: runtime.job,
                    error: error
                )
            }
            return try result.get()
        }
        let cancelImmediately = executionState.withLock { state in
            precondition(
                state.task == nil,
                "R13 release handles can start exactly once."
            )
            state.task = launchedTask
            return state.cancellationRequested
        }
        if cancelImmediately {
            launchedTask.cancel()
        }
        startGate.open()
    }

    func cancel() {
        let runningTask = executionState.withLock { state in
            state.cancellationRequested = true
            return state.task
        }
        runningTask?.cancel()
    }

    func waitForCompletion() async throws -> URL {
        guard let task = executionState.withLock({ $0.task }) else {
            throw UpscalerEngineError.strategyFailed("job was never started")
        }
        return try await task.value
    }

    private static func runJob(
        runtime: R13ReleaseJobRuntime,
        media: MediaPipelineService,
        sessionFactory: R13ReleaseUpscaleSessionFactory
    ) async throws -> URL {
        defer {
            withExtendedLifetime(runtime.securityAccess) {}
        }
        let job = runtime.job
        try Task.checkCancellation()
        let isAccessingInput = job.inputURL.startAccessingSecurityScopedResource()
        let isAccessingOutput = job.outputURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingOutput {
                job.outputURL.stopAccessingSecurityScopedResource()
            }
            if isAccessingInput {
                job.inputURL.stopAccessingSecurityScopedResource()
            }
        }

        runtime.diagnosticRecorder.enqueue(
            severity: .info,
            subsystem: "release_engine",
            operation: "prepare_source",
            code: "release_source_preparation_started",
            job: job
        )
        let preparedSource = try await R13ReleaseSourceStaging.prepare(
            job: job,
            modeBinding: runtime.modeBinding,
            hardeningRuntime: runtime.hardeningRuntime,
            media: media
        )
        let source = preparedSource.source
        let route = preparedSource.route
        let hardeningAttempt = preparedSource.hardeningAttempt
        runtime.diagnosticRecorder.enqueue(
            severity: .info,
            subsystem: "release_engine",
            operation: "prepare_source",
            code: "release_source_prepared",
            job: job,
            source: source
        )
        do {
            try await hardeningAttempt?.beforeBackendStart()
            runtime.diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "release_engine",
                operation: "start_backend_session",
                code: "release_backend_session_starting",
                job: job,
                source: source
            )
            let upscaleBinding = try await sessionFactory(route)
            do {
                try R13ReleaseJobContracts.validate(
                    upscaleBinding,
                    route: route,
                    modeBinding: runtime.modeBinding
                )
                runtime.diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "release_engine",
                    operation: "start_backend_session",
                    code: "release_backend_session_ready",
                    job: job,
                    source: source
                )
                try Task.checkCancellation()
                let output = OutputProfile(
                    url: job.outputURL,
                    resolution: job.targetResolution,
                    codec: job.codec,
                    preserveAudio: job.preserveAudio,
                    timedMetadataTemplate:
                        hardeningAttempt?.identity.timedMetadata ?? [:],
                    transactionIdentifier: job.identifier
                )
                runtime.diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "release_engine",
                    operation: "begin_media_session",
                    code: "release_media_session_starting",
                    job: job,
                    source: source
                )
                let mediaSession = try await media.beginSession(
                    source: source,
                    output: output
                )
                runtime.diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "release_engine",
                    operation: "begin_media_session",
                    code: "release_media_session_ready",
                    job: job,
                    source: source
                )
                let result = try await runActiveSessions(
                    runtime: runtime,
                    source: source,
                    route: route,
                    mediaSession: mediaSession,
                    upscaleBinding: upscaleBinding,
                    hardeningAttempt: hardeningAttempt
                )
                await hardeningAttempt?.releaseResources()
                return result
            } catch {
                await upscaleBinding.session.cancel()
                throw error
            }
        } catch {
            await hardeningAttempt?.releaseResources()
            throw error
        }
    }

    private static func runActiveSessions(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        route: R03ScaleRoute,
        mediaSession: MediaSession,
        upscaleBinding: R13ReleaseUpscaleSessionBinding,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws -> URL {
        do {
            return try await withTaskCancellationHandler {
                let estimatedTotalFrames = max(source.estimatedFrameCount, 0)
                let startedAt = Date()
                var processedFrameCount = 0
                var backendProcessedFrameCount = 0
                var recordedFirstDecodedFrame = false

                while let record = try await mediaSession.nextSourceFrame() {
                    try Task.checkCancellation()
                    try await hardeningAttempt?.recheckResources()
                    if !recordedFirstDecodedFrame {
                        recordedFirstDecodedFrame = true
                        let decodedResolution = VideoResolution(
                            width: CVPixelBufferGetWidth(record.pixelBuffer),
                            height: CVPixelBufferGetHeight(record.pixelBuffer)
                        )
                        let matchesExpectedGeometry =
                            decodedResolution == source.resolution
                        runtime.diagnosticRecorder.enqueue(
                            severity: matchesExpectedGeometry
                                ? .info
                                : .warning,
                            subsystem: "release_engine",
                            operation: "decode_source_frame",
                            code: matchesExpectedGeometry
                                ? "release_first_decoded_frame_observed"
                                : "release_first_decoded_frame_geometry_mismatch",
                            job: runtime.job,
                            source: source,
                            frame: record,
                            expectedFrameResolution: source.resolution
                        )
                    }
                    do {
                        if try await processRecord(
                            record,
                            runtime: runtime,
                            source: source,
                            route: route,
                            mediaSession: mediaSession,
                            upscaleBinding: upscaleBinding,
                            hardeningAttempt: hardeningAttempt
                        ) {
                            backendProcessedFrameCount += 1
                        }
                    } catch {
                        runtime.diagnosticRecorder.enqueue(
                            severity: .error,
                            subsystem: "release_engine",
                            operation: "process_frame",
                            code: "release_frame_processing_failed",
                            job: runtime.job,
                            source: source,
                            frame: record,
                            expectedFrameResolution: source.resolution,
                            error: error
                        )
                        throw error
                    }
                    processedFrameCount += 1
                    R13ReleaseJobContracts.yieldProgress(
                        processedFrameCount: processedFrameCount,
                        estimatedTotalFrames: estimatedTotalFrames,
                        startedAt: startedAt,
                        terminal: false,
                        continuation: runtime.progressContinuation
                    )
                }

                try Task.checkCancellation()
                try await hardeningAttempt?.validateFrameCount(
                    processedFrameCount
                )
                let summary = await upscaleBinding.session.finish()
                guard summary.submittedFrameCount
                        == backendProcessedFrameCount,
                      summary.processedFrameCount
                        == backendProcessedFrameCount,
                      summary.terminalizationCount == 1 else {
                    throw UpscalerEngineError.strategyFailed(
                        "A11 FIFO terminal summary did not match processed media frames."
                    )
                }
                try Task.checkCancellation()
                try await hardeningAttempt?.beforeOutputFinalize()
                runtime.diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "release_engine",
                    operation: "finalize_media_session",
                    code: "release_media_finalization_started",
                    job: runtime.job,
                    source: source
                )
                let metadata =
                    hardeningAttempt?.identity.timedMetadata
                    ?? mediaSession.outputProfile.timedMetadataTemplate
                let prepublicationOutputURL =
                    mediaSession.prepublicationOutputURL
                try await mediaSession.finish(
                    finalMetadata: metadata,
                    beforeReopen: {
                        try await hardeningAttempt?.beforeMetadataReopen()
                    },
                    validatingBeforePublish: {
                        try await hardeningAttempt?.validateBeforePublish(
                            outputURL: prepublicationOutputURL,
                            metadata: metadata
                        )
                    }
                )
                try await hardeningAttempt?.completePublishedOutput(
                    at: runtime.job.outputURL,
                    publicationIdentity: mediaSession.publishedOutputIdentity,
                    mediaCleanupFailed: mediaSession.terminalCleanupError != nil
                )
                runtime.diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "release_engine",
                    operation: "finalize_media_session",
                    code: "release_media_output_published",
                    job: runtime.job,
                    source: source
                )
                R13ReleaseJobContracts.yieldProgress(
                    processedFrameCount: processedFrameCount,
                    estimatedTotalFrames: estimatedTotalFrames,
                    startedAt: startedAt,
                    terminal: true,
                    continuation: runtime.progressContinuation
                )
                return runtime.job.outputURL
            } onCancel: {
                mediaSession.cancel()
                Task {
                    await upscaleBinding.session.cancel()
                }
            }
        } catch {
            mediaSession.cancel()
            await upscaleBinding.session.cancel()
            if let cleanupError = mediaSession.terminalCleanupError {
                throw cleanupError
            }
            if error is CancellationError || Task.isCancelled {
                throw UpscalerEngineError.cancelled
            }
            throw error
        }
    }

}
