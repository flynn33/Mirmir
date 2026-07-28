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

    private let media: MediaPipelineService
    private let sessionFactory: R13ReleaseUpscaleSessionFactory
    private let normalizer: any R13NV12FrameNormalizing
    private let inputReleaseObserver: R13ReleaseResourceReleaseObserver
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
        beforeHandleStart: @escaping R13ReleaseBeforeHandleStart = {}
    ) {
        self.media = media
        self.sessionFactory = sessionFactory
        self.normalizer = normalizer
        self.inputReleaseObserver = inputReleaseObserver
        self.cacheLocationStore = cacheLocationStore
        if let cacheLocationStore {
            hardeningRuntimeProvider = {
                try R13ReleaseHardeningRuntime.production(
                    cacheLocation: cacheLocationStore.configuration()
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
        let modeBinding = try R13ReleaseModePolicy.binding(for: job.mode)
        guard AtomicMediaOutput.isValidTemporaryIdentifier(job.identifier) else {
            throw UpscalerEngineError.invalidJobIdentifier(job.identifier)
        }
        guard !FileURLIdentity.refersToSameFile(job.inputURL, job.outputURL) else {
            throw UpscalerEngineError.inputOutputCollision
        }
        let reserved = activeJobState.withLock { state in
            guard case .idle = state else { return false }
            state = .reserved
            return true
        }
        guard reserved else {
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

        let handle = R13ReleaseUpscalerJobHandle(
            job: job,
            modeBinding: modeBinding,
            media: media,
            sessionFactory: sessionFactory,
            normalizer: normalizer,
            inputReleaseObserver: inputReleaseObserver,
            hardeningRuntime: hardeningRuntime,
            securityAccess: securityAccess,
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
            progressContinuation: progressContinuation
        )
        let startGate = R13ReleaseTaskStartGate()
        let launchedTask = Task.detached(
            priority: .userInitiated
        ) { [runtime, media, sessionFactory, onTerminal, startGate, securityAccessHolder] in
            defer {
                securityAccessHolder.release()
                runtime.progressContinuation.finish()
                onTerminal()
            }
            do {
                await startGate.waitUntilOpen()
                try Task.checkCancellation()
                return try await Self.runJob(
                    runtime: runtime,
                    media: media,
                    sessionFactory: sessionFactory
                )
            } catch is CancellationError {
                throw UpscalerEngineError.cancelled
            } catch let error as UpscalerEngineError {
                throw error
            } catch {
                if Task.isCancelled {
                    throw UpscalerEngineError.cancelled
                }
                throw error
            }
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

        let preparedSource = try await R13ReleaseSourceStaging.prepare(
            job: job,
            modeBinding: runtime.modeBinding,
            hardeningRuntime: runtime.hardeningRuntime,
            media: media
        )
        let source = preparedSource.source
        let route = preparedSource.route
        let hardeningAttempt = preparedSource.hardeningAttempt
        do {
            try await hardeningAttempt?.beforeBackendStart()
            let upscaleBinding = try await sessionFactory(route)
            do {
                try R13ReleaseJobContracts.validate(
                    upscaleBinding,
                    route: route,
                    modeBinding: runtime.modeBinding
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
                let mediaSession = try await media.beginSession(
                    source: source,
                    output: output
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

                while let record = try await mediaSession.nextSourceFrame() {
                    try Task.checkCancellation()
                    try await hardeningAttempt?.recheckResources()
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
