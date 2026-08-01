import CoreMedia
import CoreVideo
import Foundation
import os.lock

struct R13ReleaseUpscaleSessionBinding: Sendable {
    let session: any AppleUpscaleSession
    let route: R03ScaleRoute
    let routeIdentity: AppleUpscaleRouteIdentity
    let admittedFrameRouteIdentities:
        Set<AppleUpscaleRouteIdentity>

    init(
        session: any AppleUpscaleSession,
        route: R03ScaleRoute,
        routeIdentity: AppleUpscaleRouteIdentity,
        admittedFrameRouteIdentities:
            Set<AppleUpscaleRouteIdentity> = []
    ) {
        self.session = session
        self.route = route
        self.routeIdentity = routeIdentity
        self.admittedFrameRouteIdentities =
            admittedFrameRouteIdentities
    }

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

typealias R13ModeAwareReleaseUpscaleSessionFactory = @Sendable (
    _ route: R03ScaleRoute,
    _ modeBinding: R13ReleaseModeBinding
) async throws -> R13ReleaseUpscaleSessionBinding

typealias R13JobAwareReleaseUpscaleSessionFactory = @Sendable (
    _ route: R03ScaleRoute,
    _ modeBinding: R13ReleaseModeBinding,
    _ processingConfiguration: UpscaleProcessingConfiguration,
    _ jobIdentifier: String
) async throws -> R13ReleaseUpscaleSessionBinding

typealias R13AdaptiveScalerFactory = @Sendable (
    _ plan: R13AdaptiveScalePlan
) throws -> any R03NV12Scaling

typealias R13ModeAwareAdaptiveScalerFactory = @Sendable (
    _ plan: R13AdaptiveScalePlan,
    _ modeBinding: R13ReleaseModeBinding
) throws -> any R03NV12Scaling

typealias R13ReleaseResourceReleaseObserver = @Sendable (_ identity: String) -> Void
typealias R13ReleaseBeforeHandleStart = @Sendable () -> Void
typealias R13ReleaseHardeningRuntimeProvider = @Sendable () throws
    -> R13ReleaseHardeningRuntime?
final class R13ReleaseUpscalerEngineService: UpscalerEngineService,
    R13RecoverableUpscalerEngine,
    R13ReleaseDiagnosticsProviding,
    @unchecked Sendable {
    final class HardeningRuntimeEpoch: @unchecked Sendable {}

    struct HardeningRuntimeCacheState {
        var runtime: R13ReleaseHardeningRuntime?
        var epoch = HardeningRuntimeEpoch()
    }

    enum ActiveJobState {
        case idle
        case changingCacheLocation
        case discardingRecovery
        case reserved
        case stoppingReserved
        case active(R13ReleaseUpscalerJobHandle)
    }

    private enum ReservationAttempt {
        case reserved
        case rejected(activeState: String)
    }

    private let media: MediaPipelineService
    private let sessionFactory:
        R13JobAwareReleaseUpscaleSessionFactory
    private let adaptiveScalerFactory: R13ModeAwareAdaptiveScalerFactory
    private let normalizer: R13ReleaseVideoFrameNormalizer
    private let previewEncoder: any R13PreviewFrameEncoding
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
        OSAllocatedUnfairLock<HardeningRuntimeCacheState>

    var hardeningRuntime: R13ReleaseHardeningRuntime? {
        hardeningRuntimeState.withLock { $0.runtime }
    }

    var availability: UpscalerEngineAvailability { .available }

    init(
        media: MediaPipelineService,
        sessionFactory: R13ReleaseUpscaleSessionFactory? = nil,
        modeAwareSessionFactory:
            R13ModeAwareReleaseUpscaleSessionFactory? = nil,
        adaptiveScalerFactory:
            R13AdaptiveScalerFactory? = nil,
        modeAwareAdaptiveScalerFactory:
            R13ModeAwareAdaptiveScalerFactory? = nil,
        normalizer: any R13NV12FrameNormalizing = R13NV12FrameNormalizer(),
        previewEncoder: any R13PreviewFrameEncoding =
            R13PreviewFrameEncoder(),
        inputReleaseObserver: @escaping R13ReleaseResourceReleaseObserver = { _ in },
        hardeningRuntime: R13ReleaseHardeningRuntime? = nil,
        cacheLocationStore: R13CacheLocationStore? = nil,
        beforeHandleStart: @escaping R13ReleaseBeforeHandleStart = {},
        diagnostics: MirmirDiagnosticStore? = nil
    ) {
        self.media = media
        if let modeAwareSessionFactory {
            self.sessionFactory = {
                route,
                modeBinding,
                _,
                _ in
                try await modeAwareSessionFactory(
                    route,
                    modeBinding
                )
            }
        } else if let sessionFactory {
            self.sessionFactory = { route, _, _, _ in
                try await sessionFactory(route)
            }
        } else {
            self.sessionFactory = {
                route,
                modeBinding,
                processingConfiguration,
                jobIdentifier in
                try await R13A11ProductSessionFactory.makeSession(
                    route: route,
                    modeBinding: modeBinding,
                    processingConfiguration:
                        processingConfiguration,
                    streamIdentifier: jobIdentifier
                )
            }
        }
        if let modeAwareAdaptiveScalerFactory {
            self.adaptiveScalerFactory =
                modeAwareAdaptiveScalerFactory
        } else if let adaptiveScalerFactory {
            self.adaptiveScalerFactory = { plan, _ in
                try adaptiveScalerFactory(plan)
            }
        } else {
            self.adaptiveScalerFactory = { plan, modeBinding in
                switch modeBinding.scalerKind {
                case .standardVImage:
                    return R03VImageScaler(
                        mode: .lanczos3,
                        adaptivePlan: plan
                    )
                case .highQualityVImage:
                    return R03VImageScaler(
                        mode: .lanczos5,
                        adaptivePlan: plan
                    )
                case .fastMPSBilinear:
                    return try R03MPSScaler(
                        mode: .bilinear,
                        adaptivePlan: plan
                    )
                case .deterministicMPSLanczos:
                    return try R03MPSScaler(
                        mode: .lanczos,
                        adaptivePlan: plan
                    )
                case .coreImageLanczos:
                    return R03CoreImageScaler(
                        mode: .lanczos,
                        adaptivePlan: plan
                    )
                case .coreImageBicubic:
                    return R03CoreImageScaler(
                        mode: .bicubic,
                        adaptivePlan: plan
                    )
                case .videoToolboxPixelTransfer:
                    return try R03VTPixelTransferScaler(
                        adaptivePlan: plan
                    )
                }
            }
        }
        self.normalizer = R13ReleaseVideoFrameNormalizer(
            nv12: normalizer
        )
        self.previewEncoder = previewEncoder
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
            initialState: HardeningRuntimeCacheState(
                runtime: hardeningRuntime
            )
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
            let modeBinding = R13ReleaseModePolicy.binding(
                for: job.mode,
                enginePreference:
                    job.processingConfiguration.enginePreference
            )
            guard AtomicMediaOutput.isValidTemporaryIdentifier(job.identifier) else {
                throw UpscalerEngineError.invalidJobIdentifier(job.identifier)
            }
            guard !FileURLIdentity.refersToSameFile(job.inputURL, job.outputURL) else {
                throw UpscalerEngineError.inputOutputCollision
            }
            if securityAccess == nil,
               FileManager.default.fileExists(atPath: job.outputURL.path) {
                throw UpscalerEngineError.outputAlreadyExists
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
                    case .idle, .changingCacheLocation,
                         .discardingRecovery, .active:
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
                adaptiveScalerFactory: adaptiveScalerFactory,
                normalizer: normalizer,
                previewEncoder: previewEncoder,
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
                case .idle, .changingCacheLocation,
                     .discardingRecovery, .active:
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
        case .discardingRecovery:
            return "discarding_recovery"
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
             UpscalerEngineError.outputAlreadyExists,
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
        case UpscalerEngineError.outputAlreadyExists:
            return "release_job_submit_rejected_output_exists"
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
    let normalizer: R13ReleaseVideoFrameNormalizer
    let previewEmitter: R13UpscalePreviewEmitter
    let inputReleaseObserver: R13ReleaseResourceReleaseObserver
    let hardeningRuntime: R13ReleaseHardeningRuntime?
    let securityAccess: R13SecurityScopedAccessSet?
    let progressContinuation: AsyncStream<UpscaleProgress>.Continuation
    let diagnosticRecorder: MirmirDiagnosticRecorder

    func resolving(
        modeBinding: R13ReleaseModeBinding
    ) -> R13ReleaseJobRuntime {
        R13ReleaseJobRuntime(
            job: job,
            modeBinding: modeBinding,
            normalizer: normalizer,
            previewEmitter: previewEmitter,
            inputReleaseObserver: inputReleaseObserver,
            hardeningRuntime: hardeningRuntime,
            securityAccess: securityAccess,
            progressContinuation: progressContinuation,
            diagnosticRecorder: diagnosticRecorder
        )
    }
}

final class R13ReleaseUpscalerJobHandle: UpscalerJobHandle,
    @unchecked Sendable {
    private struct ExecutionState {
        var task: Task<URL, Error>?
        var cancellationRequested = false
    }

    let progressStream: AsyncStream<UpscaleProgress>
    let previewStream: AsyncStream<UpscalePreviewFrame>

    private let progressContinuation: AsyncStream<UpscaleProgress>.Continuation
    private let previewEmitter: R13UpscalePreviewEmitter
    private let job: UpscaleJob
    private let modeBinding: R13ReleaseModeBinding
    private let media: MediaPipelineService
    private let sessionFactory:
        R13JobAwareReleaseUpscaleSessionFactory
    private let adaptiveScalerFactory: R13ModeAwareAdaptiveScalerFactory
    private let normalizer: R13ReleaseVideoFrameNormalizer
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
        sessionFactory:
            @escaping R13JobAwareReleaseUpscaleSessionFactory,
        adaptiveScalerFactory:
            @escaping R13ModeAwareAdaptiveScalerFactory,
        normalizer: R13ReleaseVideoFrameNormalizer,
        previewEncoder: any R13PreviewFrameEncoding,
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
        self.adaptiveScalerFactory = adaptiveScalerFactory
        self.normalizer = normalizer
        let previewEmitter = R13UpscalePreviewEmitter(
            encoder: previewEncoder,
            failureObserver: { [diagnosticRecorder, job] failure in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "release_engine",
                    operation: "encode_preview_sample",
                    code: "release_preview_encoding_failed",
                    job: job,
                    additionalFields: failure.diagnosticFields,
                    error: failure
                )
            }
        )
        self.previewEmitter = previewEmitter
        previewStream = previewEmitter.stream
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

    // Task launch, terminal signaling, and security-scope release form one
    // lifecycle boundary whose defer ordering must remain visible together.
    func start() {
        let runtime = R13ReleaseJobRuntime(
            job: job,
            modeBinding: modeBinding,
            normalizer: normalizer,
            previewEmitter: previewEmitter,
            inputReleaseObserver: inputReleaseObserver,
            hardeningRuntime: hardeningRuntime,
            securityAccess: securityAccessHolder.access,
            progressContinuation: progressContinuation,
            diagnosticRecorder: diagnosticRecorder
        )
        let startGate = R13ReleaseTaskStartGate()
        let launchedTask = Task.detached(
            priority: .userInitiated
        ) { [runtime, media, sessionFactory, adaptiveScalerFactory, onTerminal, startGate, securityAccessHolder] in
            defer {
                securityAccessHolder.release()
                runtime.progressContinuation.finish()
                runtime.previewEmitter.finish()
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
                        sessionFactory: sessionFactory,
                        adaptiveScalerFactory:
                            adaptiveScalerFactory
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
        sessionFactory: R13JobAwareReleaseUpscaleSessionFactory,
        adaptiveScalerFactory: R13ModeAwareAdaptiveScalerFactory
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
            media: media,
            requiresExistingRestartState:
                runtime.securityAccess != nil
        )
        let runtime = runtime.resolving(
            modeBinding: preparedSource.modeBinding
        )
        let source = preparedSource.source
        let hardeningAttempt = preparedSource.hardeningAttempt
        let enhancementResolution: VideoResolution
        switch preparedSource.scalePlan {
        case .productQualified(let route):
            enhancementResolution = route.canonicalSourceResolution
        case .adaptiveMPSLanczos(let plan):
            enhancementResolution = plan.processingSourceResolution
        }
        let enhancementProcessor =
            try R13ReleaseFormatEnhancementProcessor(
                targetResolution: enhancementResolution,
                videoFormat: source.videoFormat,
                temporalConsistencyEnabled:
                    job.processingConfiguration
                        .temporalConsistencyEnabled,
                edgeFidelityLevel:
                    job.processingConfiguration.edgeFidelityLevel,
                detailRecoveryLevel:
                    job.processingConfiguration.detailRecoveryLevel,
                edgePreservationEnabled:
                    job.processingConfiguration.effects
                        .edgePreservationEnabled,
                compressionCleanupEnabled:
                    job.processingConfiguration.effects
                        .compressionCleanupEnabled,
                textureGrainProtectionEnabled:
                    job.processingConfiguration.effects
                        .textureGrainProtectionEnabled,
                temporalStabilityEnabled:
                    job.processingConfiguration.effects
                        .temporalStabilityEnabled
            )
        defer {
            enhancementProcessor.cancel()
        }
        runtime.diagnosticRecorder.enqueue(
            severity: .info,
            subsystem: "release_engine",
            operation: "prepare_source",
            code: "release_source_prepared",
            job: job,
            source: source
        )
        if runtime.modeBinding.usesFormatPreservingFallback {
            return try await runFormatPreservingJob(
                runtime: runtime,
                source: source,
                scalePlan: preparedSource.scalePlan,
                enhancementProcessor: enhancementProcessor,
                hardeningAttempt: hardeningAttempt,
                media: media
            )
        }
        if case .adaptiveMPSLanczos(let adaptivePlan) =
            preparedSource.scalePlan {
            return try await runAdaptiveJob(
                runtime: runtime,
                source: source,
                plan: adaptivePlan,
                enhancementProcessor: enhancementProcessor,
                hardeningAttempt: hardeningAttempt,
                media: media,
                scalerFactory: adaptiveScalerFactory
            )
        }
        guard case .productQualified(let route) =
            preparedSource.scalePlan else {
            throw UpscalerEngineError.strategyFailed(
                "Release source preparation returned an invalid scale plan."
            )
        }
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
            let upscaleBinding = try await sessionFactory(
                route,
                runtime.modeBinding,
                runtime.job.processingConfiguration,
                runtime.job.identifier
            )
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
                        hardeningAttempt?.identity.timedMetadata
                        ?? productRoutingMetadataTemplate(
                            modeBinding: runtime.modeBinding
                        ),
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
                let baseMediaSession = try await media.beginSession(
                    source: source,
                    output: output
                )
                let mediaSession =
                    try R13SmoothMotionIntegration.makeMediaSession(
                        base: baseMediaSession,
                        runtime: runtime,
                        source: source
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
                    enhancementProcessor: enhancementProcessor,
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

    private static func runFormatPreservingJob(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        scalePlan: R13ReleaseScalePlan,
        enhancementProcessor:
            R13ReleaseFormatEnhancementProcessor,
        hardeningAttempt: R13ReleaseHardeningAttempt?,
        media: MediaPipelineService
    ) async throws -> URL {
        do {
            try await hardeningAttempt?.beforeBackendStart()
            let processingResolution: VideoResolution
            switch scalePlan {
            case .productQualified(let route):
                processingResolution =
                    route.canonicalSourceResolution
            case .adaptiveMPSLanczos(let plan):
                processingResolution =
                    plan.processingSourceResolution
            }
            let scalingExecution =
                try makeFormatPreservingScalingExecution(
                    runtime: runtime,
                    source: source,
                    scalePlan: scalePlan,
                    processingResolution: processingResolution
                )
            let scalingRoute = runtime.modeBinding
                .usesProductOrchestration
                ? "multi_engine_router"
                : runtime.modeBinding.scalerKind.rawValue
            runtime.diagnosticRecorder.enqueue(
                severity: .notice,
                subsystem: "release_engine",
                operation: "start_format_preserving_scaler",
                code: "release_format_preserving_scaler_ready",
                job: runtime.job,
                source: source,
                additionalFields:
                    formatDiagnosticFields(
                        runtime.modeBinding
                    )
                    + [
                        try? MirmirDiagnosticField(
                            key: "format_scaling_route",
                            value: try .identifier(scalingRoute)
                        )
                    ].compactMap { $0 }
                    + candidateAdmissionDiagnosticFields(
                        scalingExecution.candidateExclusions
                    )
            )
            let output = OutputProfile(
                url: runtime.job.outputURL,
                resolution: runtime.job.targetResolution,
                codec: runtime.job.codec,
                preserveAudio: runtime.job.preserveAudio,
                videoFormat: source.videoFormat,
                timedMetadataTemplate:
                    hardeningAttempt?.identity.timedMetadata
                    ?? formatPreservingTimedMetadata(
                        runtime: runtime,
                        scalePlan: scalePlan
                    ),
                transactionIdentifier: runtime.job.identifier
            )
            let baseMediaSession = try await media.beginSession(
                source: source,
                output: output
            )
            let mediaSession =
                try R13SmoothMotionIntegration.makeMediaSession(
                    base: baseMediaSession,
                    runtime: runtime,
                    source: source
                )
            let cancellation =
                AppleUpscaleOperationCancellationSignal()
            let result = try await withTaskCancellationHandler {
                do {
                    return try await processFormatPreservingFrames(
                        runtime: runtime,
                        source: source,
                        scalePlan: scalePlan,
                        scalingExecution: scalingExecution,
                        cancellation: cancellation,
                        enhancementProcessor:
                            enhancementProcessor,
                        mediaSession: mediaSession,
                        hardeningAttempt: hardeningAttempt
                    )
                } catch {
                    await scalingExecution.cancel()
                    mediaSession.cancel()
                    enhancementProcessor.cancel()
                    if error is CancellationError
                        || Task.isCancelled {
                        throw UpscalerEngineError.cancelled
                    }
                    throw error
                }
            } onCancel: {
                cancellation.cancel()
                enhancementProcessor.cancel()
                mediaSession.cancel()
                Task.detached(priority: .userInitiated) {
                    await scalingExecution.cancel()
                }
            }
            await hardeningAttempt?.releaseResources()
            return result
        } catch {
            await hardeningAttempt?.releaseResources()
            throw error
        }
    }

    private static func processFormatPreservingFrames(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        scalePlan: R13ReleaseScalePlan,
        scalingExecution: R13AdaptiveScalingExecution,
        cancellation: AppleUpscaleOperationCancellationSignal,
        enhancementProcessor:
            R13ReleaseFormatEnhancementProcessor,
        mediaSession: MediaSession,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws -> URL {
        let estimatedTotalFrames = max(
            source.estimatedFrameCount,
            0
        )
        let startedAt = Date()
        var processedFrameCount = 0
        var recordedFirstDecodedFrame = false
        while let record = try await mediaSession.nextSourceFrame() {
            try Task.checkCancellation()
            try await hardeningAttempt?.recheckResources()
            if !recordedFirstDecodedFrame {
                recordedFirstDecodedFrame = true
                recordFirstDecodedFrame(
                    record,
                    runtime: runtime,
                    source: source
                )
            }
            do {
                try await processFormatPreservingRecord(
                    record,
                    runtime: runtime,
                    source: source,
                    scalePlan: scalePlan,
                    scalingExecution: scalingExecution,
                    cancellation: cancellation,
                    enhancementProcessor:
                        enhancementProcessor,
                    mediaSession: mediaSession,
                    hardeningAttempt: hardeningAttempt
                )
            } catch {
                runtime.diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "release_engine",
                    operation:
                        "process_format_preserving_frame",
                    code:
                        "release_format_preserving_frame_failed",
                    job: runtime.job,
                    source: source,
                    frame: record,
                    expectedFrameResolution: source.resolution,
                    additionalFields: formatDiagnosticFields(
                        runtime.modeBinding
                    ),
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
        let routingMetadata =
            try await scalingExecution.finish()
        if let routingMetadata {
            try recordRoutingFallbackDiagnostics(
                routingMetadata,
                runtime: runtime
            )
            runtime.diagnosticRecorder.enqueue(
                severity: .notice,
                subsystem: "release_engine",
                operation: "finalize_backend_routing",
                code: "release_product_routing_completed",
                job: runtime.job,
                source: source,
                additionalFields:
                    routingDiagnosticFields(routingMetadata)
            )
        }
        try enhancementProcessor.finish()
        try await hardeningAttempt?.beforeOutputFinalize()
        let baseMetadata = try finalizedRoutingBaseMetadata(
            hardeningAttempt: hardeningAttempt,
            mediaSession: mediaSession,
            routingMetadata: routingMetadata
        )
        let metadata = try await finalizedSmoothMotionMetadata(
            baseMetadata,
            mediaSession: mediaSession
        )
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
        let cleanupError = mediaSession.terminalCleanupError
        if let cleanupError {
            runtime.diagnosticRecorder.enqueue(
                severity: .warning,
                subsystem: "release_engine",
                operation: "cleanup_media_session",
                code: "release_media_cleanup_deferred",
                job: runtime.job,
                source: source,
                error: cleanupError
            )
        }
        try await hardeningAttempt?.completePublishedOutput(
            at: runtime.job.outputURL,
            publicationIdentity:
                mediaSession.publishedOutputIdentity,
            mediaCleanupFailed: cleanupError != nil
        )
        runtime.diagnosticRecorder.enqueue(
            severity: .notice,
            subsystem: "release_engine",
            operation: "finalize_media_session",
            code:
                "release_format_preserving_output_published",
            job: runtime.job,
            source: source,
            additionalFields: formatDiagnosticFields(
                runtime.modeBinding
            )
        )
        R13ReleaseJobContracts.yieldProgress(
            processedFrameCount: processedFrameCount,
            estimatedTotalFrames: estimatedTotalFrames,
            startedAt: startedAt,
            terminal: true,
            continuation: runtime.progressContinuation
        )
        return runtime.job.outputURL
    }

    private static func processFormatPreservingRecord(
        _ record: FrameRecord,
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        scalePlan: R13ReleaseScalePlan,
        scalingExecution: R13AdaptiveScalingExecution,
        cancellation: AppleUpscaleOperationCancellationSignal,
        enhancementProcessor:
            R13ReleaseFormatEnhancementProcessor,
        mediaSession: MediaSession,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws {
        let disposition = try await hardeningAttempt?
            .disposition(forFrameAt: record.frameIndex)
        if disposition == .replayVerifiedCache {
            let replay = try await hardeningAttempt?
                .replayFrameWithRoutingDecision(
                    at: record.frameIndex
                )
            guard let replay else {
                throw UpscalerEngineError.strategyFailed(
                    "R13 format-preserving cache replay did not "
                        + "return its verified frame."
                )
            }
            let normalized = try normalizeFormatSource(
                record.pixelBuffer,
                runtime: runtime,
                source: source,
                scalePlan: scalePlan
            )
            let enhancedSource = try enhancementProcessor.process(
                normalized
            )
            try await scalingExecution.replayCachedDecision(
                source: enhancedSource,
                frameIndex: record.frameIndex,
                decision: replay.routingDecision,
                isFinalCachedPrefixFrame:
                    replay.isFinalCachedPrefixFrame
            )
            let processed = try replay.frame.makePixelBuffer(
                videoFormat: source.videoFormat
            )
            R13MediaVideoFormatContract.install(
                source.videoFormat,
                on: processed,
                resolution: runtime.job.targetResolution
            )
            try R13MediaVideoFormatContract.validate(
                processed,
                resolution: runtime.job.targetResolution,
                format: source.videoFormat
            )
            try await mediaSession.appendOutput(
                pixelBuffer: processed,
                timing: record.timing
            )
            runtime.previewEmitter.offer(
                source: { normalized },
                processed: processed,
                sourcePresentationResolution: source.resolution,
                frameIndex: record.frameIndex,
                presentationTime: record.presentationTime,
                presentationTransform:
                    mediaSession.presentationTransform
            )
            return
        }
        let normalized = try normalizeFormatSource(
            record.pixelBuffer,
            runtime: runtime,
            source: source,
            scalePlan: scalePlan
        )
        let enhancedSource = try enhancementProcessor.process(normalized)
        try Task.checkCancellation()
        let processed = try PixelBufferBridge.dequeue(
            from: mediaSession.outputPixelBufferPool
        )
        R13MediaVideoFormatContract.install(
            source.videoFormat,
            on: processed,
            resolution: runtime.job.targetResolution
        )
        let routingDecision = try await scalingExecution.scale(
            source: enhancedSource,
            destination: processed,
            frameIndex: record.frameIndex,
            frameDuration: record.duration,
            cancellation: cancellation
        )
        try Task.checkCancellation()
        let cacheFrame =
            try R13NV12Frame.captureTightActivePlanes(
                from: processed
            )
        try await hardeningAttempt?.commit(
            frame: cacheFrame,
            routingDecision: routingDecision,
            at: record.frameIndex
        )
        try await mediaSession.appendOutput(
            pixelBuffer: processed,
            timing: record.timing
        )
        runtime.previewEmitter.offer(
            source: { normalized },
            processed: processed,
            sourcePresentationResolution: source.resolution,
            frameIndex: record.frameIndex,
            presentationTime: record.presentationTime,
            presentationTransform:
                mediaSession.presentationTransform
        )
    }

    private static func normalizeFormatSource(
        _ pixelBuffer: CVPixelBuffer,
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        scalePlan: R13ReleaseScalePlan
    ) throws -> CVPixelBuffer {
        switch scalePlan {
        case .productQualified:
            return try runtime.normalizer.normalize(
                pixelBuffer,
                codedResolution: source.codedResolution,
                presentationResolution: source.resolution,
                pixelAspectRatio: source.pixelAspectRatio,
                videoFormat: source.videoFormat
            )
        case .adaptiveMPSLanczos(let plan):
            return try runtime.normalizer
                .normalizeForAdaptiveScaling(
                    pixelBuffer,
                    codedResolution: source.codedResolution,
                    presentationResolution: source.resolution,
                    processingResolution:
                        plan.processingSourceResolution,
                    pixelAspectRatio: source.pixelAspectRatio,
                    videoFormat: source.videoFormat
                )
        }
    }

    private static func formatPreservingTimedMetadata(
        runtime: R13ReleaseJobRuntime,
        scalePlan: R13ReleaseScalePlan
    ) -> [String: String] {
        let configurationIdentity: String
        let routeID: String
        switch scalePlan {
        case .productQualified(let route):
            configurationIdentity =
                runtime.modeBinding.configurationIdentity(for: route)
                ?? "format-preserving-configuration-unavailable"
            routeID = route.rawValue
        case .adaptiveMPSLanczos(let plan):
            configurationIdentity =
                runtime.modeBinding
                    .adaptiveConfigurationIdentity(for: plan)
            routeID = runtime.modeBinding.adaptiveRouteID
        }
        var metadata = [
            "com.mirmir.release.backend-id":
                runtime.modeBinding.backendID,
            "com.mirmir.release.configuration-id":
                configurationIdentity,
            "com.mirmir.release.effective-mode":
                runtime.modeBinding.effectiveMode.rawValue,
            "com.mirmir.release.requested-mode":
                runtime.modeBinding.requestedMode.rawValue,
            "com.mirmir.release.route-id": routeID,
            "com.mirmir.release.video-format":
                runtime.modeBinding.executionFormat.identityComponent
        ]
        if runtime.modeBinding.usesProductOrchestration {
            metadata.merge(
                R13ProductASHDecisionMetadata.pendingValues
            ) { _, pending in pending }
        }
        return metadata
    }

    private static func formatDiagnosticFields(
        _ binding: R13ReleaseModeBinding
    ) -> [MirmirDiagnosticField] {
        [
            try? MirmirDiagnosticField(
                key: "execution_pixel_format",
                value: try .identifier(
                    binding.executionFormat.fourCC
                )
            ),
            try? MirmirDiagnosticField(
                key: "execution_video_format",
                value: try .identifier(
                    binding.executionFormat.identityComponent
                )
            ),
            try? MirmirDiagnosticField(
                key: "format_backend_id",
                value: try .identifier(binding.backendID)
            )
        ].compactMap { $0 }
    }

    private static func makeFormatPreservingScalingExecution(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        scalePlan: R13ReleaseScalePlan,
        processingResolution: VideoResolution
    ) throws -> R13AdaptiveScalingExecution {
        let targetResolution = runtime.job.targetResolution
        guard runtime.modeBinding.usesProductOrchestration else {
            return .direct(
                try R13ProductASHScalingCandidateFactory
                    .makeFormatPreservingScaler(
                        kind: runtime.modeBinding.scalerKind,
                        sourceResolution: processingResolution,
                        targetResolution: targetResolution,
                        videoFormat: source.videoFormat
                    )
            )
        }
        let candidateSet =
            try R13ProductASHScalingCandidateFactory
                .makeCandidates(
                    scalePlan: scalePlan,
                    videoFormat: source.videoFormat,
                    orchestrationKind:
                        runtime.modeBinding.orchestrationKind,
                    enginePreference:
                        runtime.modeBinding.enginePreference,
                    makeScaler: { kind in
                        try R13ProductASHScalingCandidateFactory
                            .makeFormatPreservingScaler(
                                kind: kind,
                                sourceResolution:
                                    processingResolution,
                                targetResolution:
                                    targetResolution,
                                videoFormat: source.videoFormat
                            )
                    }
                )
        return .routed(
            try R13ProductASHScalingRouter(
                scaleContext:
                    R13ProductASHScalingCandidateFactory
                        .scaleContext(
                            for: scalePlan,
                            routeID:
                                runtime.modeBinding.adaptiveRouteID
                        ),
                orchestrationKind:
                    runtime.modeBinding.orchestrationKind,
                processingConfiguration:
                    runtime.job.processingConfiguration,
                streamIdentifier: runtime.job.identifier,
                candidates: candidateSet.candidates,
                candidateExclusions:
                    candidateSet.exclusions,
                declaredRouteIdentities:
                    candidateSet.declaredRouteIdentities
            )
        )
    }

    private static func finalizedRoutingBaseMetadata(
        hardeningAttempt: R13ReleaseHardeningAttempt?,
        mediaSession: MediaSession,
        routingMetadata: R13ProductASHDecisionMetadata?
    ) throws -> [String: String] {
        if let identity = hardeningAttempt?.identity {
            return try identity.finalizedTimedMetadata(
                routingDecisionMetadata: routingMetadata
            )
        }
        var metadata =
            mediaSession.outputProfile.timedMetadataTemplate
        if let routingMetadata {
            metadata.merge(routingMetadata.values) {
                _, finalized in finalized
            }
        }
        return metadata
    }

    private static func makeAdaptiveScalingExecution(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        plan: R13AdaptiveScalePlan,
        scalerFactory: R13ModeAwareAdaptiveScalerFactory
    ) throws -> R13AdaptiveScalingExecution {
        guard runtime.modeBinding.usesProductOrchestration else {
            return .direct(
                try scalerFactory(plan, runtime.modeBinding)
            )
        }
        let scalePlan = R13ReleaseScalePlan
            .adaptiveMPSLanczos(plan)
        let candidateSet =
            try R13ProductASHScalingCandidateFactory
                .makeCandidates(
                    scalePlan: scalePlan,
                    videoFormat: source.videoFormat,
                    orchestrationKind:
                        runtime.modeBinding.orchestrationKind,
                    enginePreference:
                        runtime.modeBinding.enginePreference,
                    makeScaler: { kind in
                        let binding =
                            R13ProductASHScalingCandidateFactory
                                .directModeBinding(
                                    for: kind,
                                    videoFormat:
                                        source.videoFormat
                                )
                        return try scalerFactory(plan, binding)
                    }
                )
        return .routed(
            try R13ProductASHScalingRouter(
                scaleContext:
                    R13ProductASHScalingCandidateFactory
                        .scaleContext(
                            for: scalePlan,
                            routeID:
                                runtime.modeBinding.adaptiveRouteID
                        ),
                orchestrationKind:
                    runtime.modeBinding.orchestrationKind,
                processingConfiguration:
                    runtime.job.processingConfiguration,
                streamIdentifier: runtime.job.identifier,
                candidates: candidateSet.candidates,
                candidateExclusions:
                    candidateSet.exclusions,
                declaredRouteIdentities:
                    candidateSet.declaredRouteIdentities
            )
        )
    }

    private static func runAdaptiveJob(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        plan: R13AdaptiveScalePlan,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
        hardeningAttempt: R13ReleaseHardeningAttempt?,
        media: MediaPipelineService,
        scalerFactory: R13ModeAwareAdaptiveScalerFactory
    ) async throws -> URL {
        do {
            try await hardeningAttempt?.beforeBackendStart()
            let result = try await runAdaptiveMediaSession(
                runtime: runtime,
                source: source,
                plan: plan,
                enhancementProcessor: enhancementProcessor,
                hardeningAttempt: hardeningAttempt,
                media: media,
                scalerFactory: scalerFactory
            )
            await hardeningAttempt?.releaseResources()
            return result
        } catch {
            await hardeningAttempt?.releaseResources()
            throw error
        }
    }

    private static func runAdaptiveMediaSession(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        plan: R13AdaptiveScalePlan,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
        hardeningAttempt: R13ReleaseHardeningAttempt?,
        media: MediaPipelineService,
        scalerFactory: R13ModeAwareAdaptiveScalerFactory
    ) async throws -> URL {
        try Task.checkCancellation()
        runtime.diagnosticRecorder.enqueue(
            severity: .notice,
            subsystem: "release_engine",
            operation: "start_adaptive_scaler",
            code: "release_adaptive_scaler_starting",
            job: runtime.job,
            source: source,
            additionalFields: adaptiveDiagnosticFields(
                plan,
                modeBinding: runtime.modeBinding
            )
        )
        let scalingExecution =
            try makeAdaptiveScalingExecution(
                runtime: runtime,
                source: source,
                plan: plan,
                scalerFactory: scalerFactory
            )
        runtime.diagnosticRecorder.enqueue(
            severity: .notice,
            subsystem: "release_engine",
            operation: "start_adaptive_scaler",
            code: "release_adaptive_scaler_ready",
            job: runtime.job,
            source: source,
            additionalFields:
                adaptiveDiagnosticFields(
                    plan,
                    modeBinding: runtime.modeBinding
                )
                + candidateAdmissionDiagnosticFields(
                    scalingExecution.candidateExclusions
                )
        )
        let outputPool = try PixelBufferBridge.makePool(
            width: plan.targetResolution.width,
            height: plan.targetResolution.height,
            format: R03NV12Contract.pixelFormat,
            capacity: 3
        )
        let output = OutputProfile(
            url: runtime.job.outputURL,
            resolution: plan.targetResolution,
            codec: runtime.job.codec,
            preserveAudio: runtime.job.preserveAudio,
            timedMetadataTemplate:
                hardeningAttempt?.identity.timedMetadata
                ?? adaptiveFallbackTimedMetadata(
                    runtime: runtime,
                    plan: plan
                ),
            transactionIdentifier: runtime.job.identifier
        )
        let baseMediaSession = try await media.beginSession(
            source: source,
            output: output
        )
        let mediaSession =
            try R13SmoothMotionIntegration.makeMediaSession(
                base: baseMediaSession,
                runtime: runtime,
                source: source
            )
        let cancellation =
            AppleUpscaleOperationCancellationSignal()
        return try await withTaskCancellationHandler {
            do {
                let result = try await processAdaptiveFrames(
                    runtime: runtime,
                    source: source,
                    plan: plan,
                    scalingExecution: scalingExecution,
                    outputPool: outputPool,
                    cancellation: cancellation,
                    enhancementProcessor: enhancementProcessor,
                    mediaSession: mediaSession,
                    hardeningAttempt: hardeningAttempt
                )
                return result
            } catch {
                await scalingExecution.cancel()
                mediaSession.cancel()
                enhancementProcessor.cancel()
                if error is CancellationError || Task.isCancelled {
                    throw UpscalerEngineError.cancelled
                }
                throw error
            }
        } onCancel: {
            cancellation.cancel()
            enhancementProcessor.cancel()
            mediaSession.cancel()
            Task.detached(priority: .userInitiated) {
                await scalingExecution.cancel()
            }
        }
    }

    // Decode, resource recheck, progress, scaler terminalization, verified
    // finalization, and publication are one ordered release transaction.
    // swiftlint:disable:next function_body_length
    private static func processAdaptiveFrames(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        plan: R13AdaptiveScalePlan,
        scalingExecution: R13AdaptiveScalingExecution,
        outputPool: CVPixelBufferPool,
        cancellation: AppleUpscaleOperationCancellationSignal,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
        mediaSession: MediaSession,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws -> URL {
        let estimatedTotalFrames = max(
            source.estimatedFrameCount,
            0
        )
        let startedAt = Date()
        var processedFrameCount = 0
        var recordedFirstDecodedFrame = false
        while let record = try await mediaSession.nextSourceFrame() {
            try Task.checkCancellation()
            try await hardeningAttempt?.recheckResources()
            if !recordedFirstDecodedFrame {
                recordedFirstDecodedFrame = true
                recordFirstDecodedFrame(
                    record,
                    runtime: runtime,
                    source: source
                )
            }
            do {
                try await processAdaptiveRecord(
                    record,
                    runtime: runtime,
                    source: source,
                    plan: plan,
                    scalingExecution: scalingExecution,
                    outputPool: outputPool,
                    cancellation: cancellation,
                    enhancementProcessor: enhancementProcessor,
                    mediaSession: mediaSession,
                    hardeningAttempt: hardeningAttempt
                )
            } catch {
                runtime.diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "release_engine",
                    operation: "process_adaptive_frame",
                    code: "release_adaptive_frame_processing_failed",
                    job: runtime.job,
                    source: source,
                    frame: record,
                    expectedFrameResolution: source.resolution,
                    additionalFields: adaptiveDiagnosticFields(
                        plan,
                        modeBinding: runtime.modeBinding
                    ),
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
        let routingMetadata =
            try await scalingExecution.finish()
        if let routingMetadata {
            runtime.diagnosticRecorder.enqueue(
                severity: .notice,
                subsystem: "release_engine",
                operation: "finalize_backend_routing",
                code: "release_product_routing_completed",
                job: runtime.job,
                source: source,
                additionalFields:
                    routingDiagnosticFields(routingMetadata)
            )
        }
        try enhancementProcessor.finish()
        try await hardeningAttempt?.beforeOutputFinalize()
        runtime.diagnosticRecorder.enqueue(
            severity: .info,
            subsystem: "release_engine",
            operation: "finalize_media_session",
            code: "release_media_finalization_started",
            job: runtime.job,
            source: source,
            additionalFields: adaptiveDiagnosticFields(
                plan,
                modeBinding: runtime.modeBinding
            )
        )
        let baseMetadata = try finalizedRoutingBaseMetadata(
            hardeningAttempt: hardeningAttempt,
            mediaSession: mediaSession,
            routingMetadata: routingMetadata
        )
        let metadata = try await finalizedSmoothMotionMetadata(
            baseMetadata,
            mediaSession: mediaSession
        )
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
        let cleanupError = mediaSession.terminalCleanupError
        if let cleanupError {
            runtime.diagnosticRecorder.enqueue(
                severity: .warning,
                subsystem: "release_engine",
                operation: "cleanup_media_session",
                code: "release_media_cleanup_deferred",
                job: runtime.job,
                source: source,
                error: cleanupError
            )
        }
        try await hardeningAttempt?.completePublishedOutput(
            at: runtime.job.outputURL,
            publicationIdentity: mediaSession.publishedOutputIdentity,
            mediaCleanupFailed: cleanupError != nil
        )
        runtime.diagnosticRecorder.enqueue(
            severity: .notice,
            subsystem: "release_engine",
            operation: "finalize_media_session",
            code: "release_adaptive_media_output_published",
            job: runtime.job,
            source: source,
            additionalFields: adaptiveDiagnosticFields(
                plan,
                modeBinding: runtime.modeBinding
            )
        )
        R13ReleaseJobContracts.yieldProgress(
            processedFrameCount: processedFrameCount,
            estimatedTotalFrames: estimatedTotalFrames,
            startedAt: startedAt,
            terminal: true,
            continuation: runtime.progressContinuation
        )
        return runtime.job.outputURL
    }

    // The explicit dependencies document every mutable resource whose lifetime
    // is bounded to one adaptive frame.
    // swiftlint:disable:next function_parameter_count
    private static func processAdaptiveRecord(
        _ record: FrameRecord,
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        plan: R13AdaptiveScalePlan,
        scalingExecution: R13AdaptiveScalingExecution,
        outputPool: CVPixelBufferPool,
        cancellation: AppleUpscaleOperationCancellationSignal,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
        mediaSession: MediaSession,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws {
        let disposition = try await hardeningAttempt?
            .disposition(forFrameAt: record.frameIndex)
        if disposition == .replayVerifiedCache {
            let replay = try await hardeningAttempt?
                .replayFrameWithRoutingDecision(
                    at: record.frameIndex
                )
            guard let replay else {
                throw UpscalerEngineError.strategyFailed(
                    "R13 adaptive cache replay did not return its verified frame."
                )
            }
            let normalized = try runtime.normalizer
                .normalizeForAdaptiveScaling(
                    record.pixelBuffer,
                    codedResolution:
                        source.codedResolution,
                    presentationResolution:
                        source.resolution,
                    processingResolution:
                        plan.processingSourceResolution,
                    pixelAspectRatio:
                        source.pixelAspectRatio
                )
            let enhancedSource = try enhancementProcessor.process(
                normalized
            )
            try await scalingExecution.replayCachedDecision(
                source: enhancedSource,
                frameIndex: record.frameIndex,
                decision: replay.routingDecision,
                isFinalCachedPrefixFrame:
                    replay.isFinalCachedPrefixFrame
            )
            let processed = try replay.frame
                .makeVideoRangePixelBuffer()
            try R03NV12Contract.validate(
                pixelBuffer: processed,
                resolution: plan.targetResolution
            )
            try await mediaSession.appendOutput(
                pixelBuffer: processed,
                timing: record.timing
            )
            runtime.previewEmitter.offer(
                source: { normalized },
                processed: processed,
                sourcePresentationResolution: source.resolution,
                frameIndex: record.frameIndex,
                presentationTime: record.presentationTime,
                presentationTransform:
                    mediaSession.presentationTransform
            )
            return
        }

        let normalized = try runtime.normalizer
            .normalizeForAdaptiveScaling(
                record.pixelBuffer,
                codedResolution: source.codedResolution,
                presentationResolution: source.resolution,
                processingResolution:
                    plan.processingSourceResolution,
                pixelAspectRatio: source.pixelAspectRatio
            )
        let enhancedSource = try enhancementProcessor.process(normalized)
        try Task.checkCancellation()
        let processed = try PixelBufferBridge.dequeue(
            from: outputPool
        )
        R13NV12GeometryTransfer.installCanonicalAttachments(
            on: processed,
            resolution: plan.targetResolution
        )
        R03NV12Contract.installColorAttachments(on: processed)
        let routingDecision = try await scalingExecution.scale(
            source: enhancedSource,
            destination: processed,
            frameIndex: record.frameIndex,
            frameDuration: record.duration,
            cancellation: cancellation
        )
        try Task.checkCancellation()
        let cacheFrame = try R13NV12Frame.captureTightActivePlanes(
            from: processed
        )
        try await hardeningAttempt?.commit(
            frame: cacheFrame,
            routingDecision: routingDecision,
            at: record.frameIndex
        )
        try await mediaSession.appendOutput(
            pixelBuffer: processed,
            timing: record.timing
        )
        runtime.previewEmitter.offer(
            source: { normalized },
            processed: processed,
            sourcePresentationResolution: source.resolution,
            frameIndex: record.frameIndex,
            presentationTime: record.presentationTime,
            presentationTransform:
                mediaSession.presentationTransform
        )
    }

    private static func recordFirstDecodedFrame(
        _ record: FrameRecord,
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile
    ) {
        let decodedResolution = VideoResolution(
            width: CVPixelBufferGetWidth(record.pixelBuffer),
            height: CVPixelBufferGetHeight(record.pixelBuffer)
        )
        let matchesExpectedGeometry =
            decodedResolution == source.codedResolution
        runtime.diagnosticRecorder.enqueue(
            severity: matchesExpectedGeometry ? .info : .warning,
            subsystem: "release_engine",
            operation: "decode_source_frame",
            code: matchesExpectedGeometry
                ? "release_first_decoded_frame_observed"
                : "release_first_decoded_frame_geometry_mismatch",
            job: runtime.job,
            source: source,
            frame: record,
            expectedFrameResolution: source.codedResolution
        )
    }

    private static func adaptiveFallbackTimedMetadata(
        runtime: R13ReleaseJobRuntime,
        plan: R13AdaptiveScalePlan
    ) -> [String: String] {
        var metadata = [
            "com.mirmir.release.backend-id":
                runtime.modeBinding.backendID,
            "com.mirmir.release.configuration-id":
                runtime.modeBinding
                    .adaptiveConfigurationIdentity(for: plan),
            "com.mirmir.release.effective-mode":
                runtime.modeBinding.effectiveMode.rawValue,
            "com.mirmir.release.requested-mode":
                runtime.modeBinding.requestedMode.rawValue,
            "com.mirmir.release.route-id":
                runtime.modeBinding.adaptiveRouteID
        ]
        if runtime.modeBinding.usesProductOrchestration {
            metadata.merge(
                R13ProductASHDecisionMetadata.pendingValues
            ) { _, pending in pending }
        }
        return metadata
    }

    private static func adaptiveDiagnosticFields(
        _ plan: R13AdaptiveScalePlan,
        modeBinding: R13ReleaseModeBinding
    ) -> [MirmirDiagnosticField] {
        [
            try? MirmirDiagnosticField(
                key: "adaptive_configuration_identity",
                value: try .identifier(
                    modeBinding
                        .adaptiveConfigurationIdentity(for: plan)
                )
            ),
            try? MirmirDiagnosticField(
                key: "adaptive_processing_source_width",
                value: .unsignedInteger(
                    UInt64(
                        plan.processingSourceResolution.width
                    )
                )
            ),
            try? MirmirDiagnosticField(
                key: "adaptive_processing_source_height",
                value: .unsignedInteger(
                    UInt64(
                        plan.processingSourceResolution.height
                    )
                )
            )
        ].compactMap { $0 }
    }

    private static func runActiveSessions(
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        route: R03ScaleRoute,
        mediaSession: MediaSession,
        upscaleBinding: R13ReleaseUpscaleSessionBinding,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
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
                            decodedResolution == source.codedResolution
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
                            expectedFrameResolution: source.codedResolution
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
                            enhancementProcessor:
                                enhancementProcessor,
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
                        "The release scaler FIFO terminal summary did not "
                            + "match processed media frames."
                    )
                }
                let routingMetadata =
                    try await productRoutingDecisionMetadata(
                        for: upscaleBinding.session
                    )
                if let routingMetadata {
                    try recordRoutingFallbackDiagnostics(
                        routingMetadata,
                        runtime: runtime
                    )
                    runtime.diagnosticRecorder.enqueue(
                        severity: .notice,
                        subsystem: "release_engine",
                        operation: "finalize_backend_routing",
                        code: "release_product_routing_completed",
                        job: runtime.job,
                        source: source,
                        additionalFields:
                            routingDiagnosticFields(
                                routingMetadata
                            )
                    )
                }
                try Task.checkCancellation()
                try enhancementProcessor.finish()
                try await hardeningAttempt?.beforeOutputFinalize()
                runtime.diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "release_engine",
                    operation: "finalize_media_session",
                    code: "release_media_finalization_started",
                    job: runtime.job,
                    source: source
                )
                let baseMetadata: [String: String]
                if let identity = hardeningAttempt?.identity {
                    baseMetadata =
                        try identity.finalizedTimedMetadata(
                            routingDecisionMetadata:
                                routingMetadata
                        )
                } else {
                    var unboundMetadata =
                        mediaSession.outputProfile
                            .timedMetadataTemplate
                    if let routingMetadata {
                        unboundMetadata.merge(
                            routingMetadata.values
                        ) { _, finalized in finalized }
                    }
                    baseMetadata = unboundMetadata
                }
                let metadata =
                    try await finalizedSmoothMotionMetadata(
                        baseMetadata,
                        mediaSession: mediaSession
                    )
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
                let mediaCleanupError =
                    mediaSession.terminalCleanupError
                if let mediaCleanupError {
                    runtime.diagnosticRecorder.enqueue(
                        severity: .warning,
                        subsystem: "release_engine",
                        operation: "cleanup_media_session",
                        code: "release_media_cleanup_deferred",
                        job: runtime.job,
                        source: source,
                        error: mediaCleanupError
                    )
                }
                try await hardeningAttempt?.completePublishedOutput(
                    at: runtime.job.outputURL,
                    publicationIdentity: mediaSession.publishedOutputIdentity,
                    mediaCleanupFailed: mediaCleanupError != nil
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
                enhancementProcessor.cancel()
                Task.detached(priority: .userInitiated) {
                    mediaSession.cancel()
                    await upscaleBinding.session.cancel()
                }
            }
        } catch {
            enhancementProcessor.cancel()
            mediaSession.cancel()
            await upscaleBinding.session.cancel()
            if let cleanupError = mediaSession.terminalCleanupError {
                runtime.diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "release_engine",
                    operation: "cleanup_media_session",
                    code: "release_media_cleanup_failed",
                    job: runtime.job,
                    source: source,
                    error: cleanupError
                )
            }
            if error is CancellationError || Task.isCancelled {
                throw UpscalerEngineError.cancelled
            }
            throw error
        }
    }

    private static func productRoutingMetadataTemplate(
        modeBinding: R13ReleaseModeBinding
    ) -> [String: String] {
        modeBinding.usesProductOrchestration
            ? R13ProductASHDecisionMetadata.pendingValues
            : [:]
    }

    private static func productRoutingDecisionMetadata(
        for session: any AppleUpscaleSession
    ) async throws -> R13ProductASHDecisionMetadata? {
        guard let reporter =
            session as? any R13ProductASHDecisionReporting else {
            return nil
        }
        return try await reporter.decisionSummary()
            .outputMetadata()
    }

    private static func routingDiagnosticFields(
        _ metadata: R13ProductASHDecisionMetadata
    ) -> [MirmirDiagnosticField] {
        [
            try? MirmirDiagnosticField(
                key: "routing_decision_count",
                value: .unsignedInteger(
                    UInt64(metadata.decisionCount)
                )
            ),
            try? MirmirDiagnosticField(
                key: "routing_transition_count",
                value: .unsignedInteger(
                    UInt64(metadata.transitionCount)
                )
            ),
            try? MirmirDiagnosticField(
                key: "routing_fallback_count",
                value: .unsignedInteger(
                    UInt64(metadata.fallbackCount)
                )
            ),
            try? MirmirDiagnosticField(
                key: "routing_selected_backend_count",
                value: .unsignedInteger(
                    UInt64(metadata.selectedBackendIDs.count)
                )
            ),
            try? MirmirDiagnosticField(
                key: "routing_journal_sha256",
                value: try .sha256(metadata.journalSHA256)
            )
        ].compactMap { $0 }
    }

    private static func recordRoutingFallbackDiagnostics(
        _ metadata: R13ProductASHDecisionMetadata,
        runtime: R13ReleaseJobRuntime
    ) throws {
        for event in metadata.fallbackEvents {
            runtime.diagnosticRecorder.enqueue(
                severity: .notice,
                subsystem: "release_engine",
                operation: "record_backend_fallback",
                code: "release_product_routing_fallback_recorded",
                job: runtime.job,
                additionalFields: try routingFallbackDiagnosticFields(
                    event,
                    journalSHA256: metadata.journalSHA256
                )
            )
            try recordRoutingFallbackArtifactDiagnostics(
                event,
                runtime: runtime,
                journalSHA256: metadata.journalSHA256
            )
        }
    }

    private static func routingFallbackDiagnosticFields(
        _ event: R13ProductASHFallbackEventEvidence,
        journalSHA256: String
    ) throws -> [MirmirDiagnosticField] {
        var fields = [
            try MirmirDiagnosticField(
                key: "routing_sequence_number",
                value: .unsignedInteger(
                    UInt64(event.sequenceNumber)
                )
            ),
            try MirmirDiagnosticField(
                key: "routing_fallback_ordinal",
                value: .unsignedInteger(
                    UInt64(event.selectedFallbackOrdinal)
                )
            ),
            try MirmirDiagnosticField(
                key: "routing_fallback_reason",
                value: try .identifier(event.reason)
            ),
            try MirmirDiagnosticField(
                key: "routing_journal_sha256",
                value: try .sha256(journalSHA256)
            )
        ]
        fields.append(contentsOf: try routingRouteDiagnosticFields(
            event.failedRoute,
            prefix: "routing_failed_route"
        ))
        fields.append(contentsOf: try routingRouteDiagnosticFields(
            event.selectedRoute,
            prefix: "routing_selected_route"
        ))
        precondition(
            fields.count + 6 <= MirmirDiagnosticEvent.maximumFields,
            "Fallback diagnostics must fit with all six job context fields."
        )
        return fields
    }

    private static func routingRouteDiagnosticFields(
        _ route: R13ProductASHRoutingRouteEvidence,
        prefix: String
    ) throws -> [MirmirDiagnosticField] {
        var fields = [
            try MirmirDiagnosticField(
                key: "\(prefix)_backend_id",
                value: try .identifier(route.backendID)
            ),
            try MirmirDiagnosticField(
                key: "\(prefix)_backend_revision",
                value: try .identifier(route.backendRevision)
            ),
            try MirmirDiagnosticField(
                key: "\(prefix)_configuration_identity",
                value: try .identifier(route.configurationIdentity)
            ),
            try MirmirDiagnosticField(
                key: "\(prefix)_policy_identity",
                value: try .identifier(route.policyIdentity)
            ),
            try MirmirDiagnosticField(
                key: "\(prefix)_material_decision_identity",
                value: try .identifier(
                    route.materialDecisionIdentity
                )
            ),
            try MirmirDiagnosticField(
                key: "\(prefix)_model_status",
                value: try .identifier(route.modelStatus.rawValue)
            ),
            try MirmirDiagnosticField(
                key: "\(prefix)_model_artifact_count",
                value: .unsignedInteger(
                    UInt64(route.modelArtifacts.count)
                )
            )
        ]
        if let configurationIdentity =
                route.modelConfigurationIdentity {
            fields.append(
                try MirmirDiagnosticField(
                    key: "\(prefix)_model_configuration_identity",
                    value: try .identifier(configurationIdentity)
                )
            )
        }
        return fields
    }

    private static func recordRoutingFallbackArtifactDiagnostics(
        _ event: R13ProductASHFallbackEventEvidence,
        runtime: R13ReleaseJobRuntime,
        journalSHA256: String
    ) throws {
        for (role, route) in [
            ("failed", event.failedRoute),
            ("selected", event.selectedRoute)
        ] {
            for (index, artifact) in route.modelArtifacts.enumerated() {
                runtime.diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "release_engine",
                    operation: "record_backend_fallback_artifact",
                    code:
                        "release_product_routing_fallback_artifact_recorded",
                    job: runtime.job,
                    additionalFields: [
                        try MirmirDiagnosticField(
                            key: "routing_sequence_number",
                            value: .unsignedInteger(
                                UInt64(event.sequenceNumber)
                            )
                        ),
                        try MirmirDiagnosticField(
                            key: "routing_fallback_ordinal",
                            value: .unsignedInteger(
                                UInt64(event.selectedFallbackOrdinal)
                            )
                        ),
                        try MirmirDiagnosticField(
                            key: "routing_route_role",
                            value: try .identifier(role)
                        ),
                        try MirmirDiagnosticField(
                            key: "routing_model_artifact_index",
                            value: .unsignedInteger(UInt64(index))
                        ),
                        try MirmirDiagnosticField(
                            key: "routing_model_artifact_identifier",
                            value: try .identifier(artifact.identifier)
                        ),
                        try MirmirDiagnosticField(
                            key: "routing_model_artifact_sha256",
                            value: try .sha256(artifact.sha256)
                        ),
                        try MirmirDiagnosticField(
                            key: "routing_journal_sha256",
                            value: try .sha256(journalSHA256)
                        )
                    ]
                )
            }
        }
    }

    private static func candidateAdmissionDiagnosticFields(
        _ exclusions:
            [R13ProductASHScalingCandidateExclusion]
    ) -> [MirmirDiagnosticField] {
        var fields: [MirmirDiagnosticField] = [
            try? MirmirDiagnosticField(
                key: "routing_candidate_exclusion_count",
                value: .unsignedInteger(
                    UInt64(exclusions.count)
                )
            )
        ].compactMap { $0 }
        if let sha256 = try? R13ProductASHScalingCandidateExclusionEncoding
            .sha256(exclusions),
           let field = try? MirmirDiagnosticField(
               key: "routing_candidate_exclusions_sha256",
               value: try .sha256(sha256)
           ) {
            fields.append(field)
        }
        for (index, exclusion) in exclusions.enumerated() {
            let prefix = "routing_candidate_exclusion_\(index)"
            fields.append(
                contentsOf: [
                    try? MirmirDiagnosticField(
                        key: "\(prefix)_kind",
                        value: try .identifier(
                            exclusion.declaredKind.rawValue
                        )
                    ),
                    try? MirmirDiagnosticField(
                        key: "\(prefix)_backend",
                        value: try .identifier(
                            exclusion.expectedBackendID
                        )
                    ),
                    try? MirmirDiagnosticField(
                        key: "\(prefix)_phase",
                        value: try .identifier(
                            exclusion.phase.rawValue
                        )
                    ),
                    try? MirmirDiagnosticField(
                        key: "\(prefix)_reason",
                        value: try .identifier(
                            exclusion.failure.reasonCode
                        )
                    ),
                    try? MirmirDiagnosticField(
                        key: "\(prefix)_error_domain",
                        value: try .identifier(
                            exclusion.failure.errorDomain
                        )
                    ),
                    try? MirmirDiagnosticField(
                        key: "\(prefix)_error_code",
                        value: .signedInteger(
                            Int64(
                                exclusion.failure.errorCode
                            )
                        )
                    )
                ].compactMap { $0 }
            )
        }
        return fields
    }

}
