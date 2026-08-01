import CoreVideo
import Foundation
import os.lock

@available(macOS 15.4, *)
typealias R03ASHComparatorFactory = @Sendable (
    _ route: ASHSpatialRouteV2
) async throws -> any ASHUpscaleBackend

@available(macOS 15.4, *)
final class R03ASHComparatorBackend: AppleUpscaleBackend, @unchecked Sendable {
    let identity: AppleUpscaleBackendIdentity
    let capabilityID: AppleUpscaleCapabilityID
    let routeIdentity: AppleUpscaleRouteIdentity
    let subject: R03BaselineSubjectDescriptor
    let route: R03ScaleRoute

    private let configurationIdentity: String
    private let ashRoute: ASHSpatialRouteV2
    private let ashBackendFactory: R03ASHComparatorFactory
    private let outputReleaseObserver: R03OutputReleaseObserver
    private let sessionContractRejection: AppleUpscaleBackendRejected
    private let capabilityUnavailable: AppleUpscaleBackendUnavailable
    private let sessionCreationFailure: AppleUpscaleBackendFailed

    convenience init(
        route: R03ScaleRoute,
        bundle: Bundle = .main,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws {
        try self.init(
            route: route,
            ashBackendFactory: { ashRoute in
                let metal = try DefaultMetalRenderingService()
                return try await ASHLockedUpscaleBackendFactoryV3(
                    bundle: bundle,
                    metal: metal
                ).makeBackend(
                    route: ashRoute,
                    telemetry: ASHNoopTelemetryRecorder.shared
                )
            },
            outputReleaseObserver: outputReleaseObserver
        )
    }

    init(
        route: R03ScaleRoute,
        ashBackendFactory: @escaping R03ASHComparatorFactory,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws {
        let subjectID = R03BaselineSubjectID.ashCustomMetal
        guard let subject = R03DeterministicBackendCatalog.subject(subjectID),
              subject.kind == .wholeFrameBackend else {
            throw R03DeterministicBackendConstructionError.subjectIsNotWholeFrame(
                subjectID
            )
        }
        guard let configurationIdentity = subject.configurationIdentity(for: route) else {
            throw R03DeterministicBackendConstructionError.routeNotPreregistered(
                subject: subjectID,
                route: route
            )
        }

        let identity = try AppleUpscaleBackendIdentity(
            backendID: subject.id.rawValue,
            backendRevision: R03DeterministicBackendCatalog.backendRevision,
            modelAssetsIdentity: .notRequired
        )
        let capabilityID = try AppleUpscaleCapabilityID(subject.capabilityID)
        let routeIdentity = try AppleUpscaleRouteIdentity(
            backend: identity,
            configurationIdentity: configurationIdentity,
            policyIdentity: R03DeterministicBackendCatalog.policyIdentity,
            materialDecisionIdentity: R03DeterministicBackendCatalog.materialDecisionIdentity
        )
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: routeIdentity,
            fallbackHistory: []
        )

        self.identity = identity
        self.capabilityID = capabilityID
        self.routeIdentity = routeIdentity
        self.subject = subject
        self.route = route
        self.configurationIdentity = configurationIdentity
        switch route {
        case .scale3Over2:
            ashRoute = .direct3Over2
        case .scale2x:
            ashRoute = .direct2x
        case .scale4x:
            throw R03DeterministicBackendConstructionError
                .routeNotPreregistered(
                    subject: subjectID,
                    route: route
                )
        }
        self.ashBackendFactory = ashBackendFactory
        self.outputReleaseObserver = outputReleaseObserver
        sessionContractRejection = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "r03_session_contract_mismatch"
        )
        capabilityUnavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: processingIdentity,
            reason: "r03_capability_unavailable"
        )
        sessionCreationFailure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "r03_session_creation_failed"
        )
    }

    func makeConfiguration() throws -> AppleUpscaleSessionConfiguration {
        try AppleUpscaleSessionConfiguration(
            capabilityID: capabilityID,
            sourceResolution: route.canonicalSourceResolution,
            targetResolution: route.canonicalTargetResolution,
            pixelFormat: R03NV12Contract.pixelFormat,
            configurationIdentity: configurationIdentity
        )
    }

    func makeSession(
        configuration: AppleUpscaleSessionConfiguration,
        context: AppleUpscaleSessionContext
    ) async -> AppleUpscaleSessionCreationOutcome {
        guard configuration.capabilityID == capabilityID,
              route.matches(
                  source: configuration.sourceResolution,
                  target: configuration.targetResolution
              ),
              configuration.pixelFormat == R03NV12Contract.pixelFormat,
              configuration.configurationIdentity == configurationIdentity,
              context.admissionScope == .fixtureOnly,
              context.policyIdentity == R03DeterministicBackendCatalog.policyIdentity else {
            return .rejected(sessionContractRejection)
        }
        guard let capability = context.capabilityRegistry.capability(for: capabilityID) else {
            return .unavailable(capabilityUnavailable)
        }
        guard capability.role == .primaryScaler,
              capability.frameworkIdentity == subject.frameworkIdentity else {
            return .rejected(sessionContractRejection)
        }
        guard capability.observationStatus == .observed,
              capability.runtimeDisposition == .runnable else {
            return .unavailable(capabilityUnavailable)
        }
        guard capability.backendEligibility == .fixtureOnly,
              capability.isEligible(for: .fixtureOnly) else {
            return .rejected(sessionContractRejection)
        }

        let ashBackend: any ASHUpscaleBackend
        do {
            ashBackend = try await ashBackendFactory(ashRoute)
        } catch {
            return .unavailable(capabilityUnavailable)
        }

        do {
            let outputPool = try PixelBufferBridge.makePool(
                width: route.canonicalTargetResolution.width,
                height: route.canonicalTargetResolution.height,
                format: R03NV12Contract.pixelFormat,
                capacity: 3
            )
            let driver = try R03ASHComparatorSessionDriver(
                route: routeIdentity,
                sourceResolution: route.canonicalSourceResolution,
                targetResolution: route.canonicalTargetResolution,
                outputPool: outputPool,
                ashBackend: ashBackend,
                outputReleaseObserver: outputReleaseObserver
            )
            return .created(
                try AppleUpscaleFIFOSession(identity: routeIdentity, driver: driver)
            )
        } catch {
            return .failed(sessionCreationFailure)
        }
    }
}

@available(macOS 15.4, *)
private final class R03ASHComparatorSessionDriver: AppleUpscaleSessionDriver,
    @unchecked Sendable {
    private typealias ProcessingTask = Task<any ASHUpscaleFrameCompletion, Error>

    private struct ProcessingBuffers: @unchecked Sendable {
        let source: CVPixelBuffer
        let destination: CVPixelBuffer
    }

    private struct ActiveProcessing: Sendable {
        let generation: UInt64
        let task: ProcessingTask
    }

    private struct State: Sendable {
        var nextGeneration: UInt64 = 0
        var active: ActiveProcessing?
    }

    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let cancellationRejection: AppleUpscaleBackendRejected
    private let frameContractRejection: AppleUpscaleBackendRejected
    private let scalingFailure: AppleUpscaleBackendFailed
    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution
    private let outputPool: CVPixelBufferPool
    private let ashBackend: any ASHUpscaleBackend
    private let outputReleaseObserver: R03OutputReleaseObserver
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        route: AppleUpscaleRouteIdentity,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        outputPool: CVPixelBufferPool,
        ashBackend: any ASHUpscaleBackend,
        outputReleaseObserver: @escaping R03OutputReleaseObserver
    ) throws {
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: route,
            fallbackHistory: []
        )
        self.processingIdentity = processingIdentity
        cancellationRejection = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "operation_cancelled"
        )
        frameContractRejection = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "r03_frame_contract_mismatch"
        )
        scalingFailure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "r03_scaling_failed"
        )
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.outputPool = outputPool
        self.ashBackend = ashBackend
        self.outputReleaseObserver = outputReleaseObserver
    }

    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration _: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard !cancellation.isCancelled else {
            return .rejected(cancellationRejection)
        }
        do {
            try R03NV12Contract.validate(frame: frame, resolution: sourceResolution)
        } catch {
            return .rejected(frameContractRejection)
        }

        do {
            let output = try PixelBufferBridge.dequeue(from: outputPool)
            R03NV12Contract.installColorAttachments(on: output)
            try R03NV12Contract.validate(
                pixelBuffer: output,
                resolution: targetResolution
            )
            let context = ASHUpscaleFrameContext(
                frameIndex: frame.sequenceNumber,
                presentationTimestampValue: frame.presentationTimestamp.value,
                presentationTimestampTimescale: frame.presentationTimestamp.timescale
            )
            let buffers = ProcessingBuffers(
                source: frame.pixelBuffer,
                destination: output
            )
            let task = Task { @Sendable [ashBackend, buffers, context] in
                try await ashBackend.process(
                    source: buffers.source,
                    into: buffers.destination,
                    context: context
                )
            }
            let generation = install(task)
            defer { clearActive(generation: generation) }

            let completion = try await task.value
            var completionTransferred = false
            defer {
                if !completionTransferred {
                    completion.finishAfterAppend()
                }
            }
            guard !cancellation.isCancelled, !Task.isCancelled else {
                return .rejected(cancellationRejection)
            }
            try R03NV12Contract.validate(
                pixelBuffer: output,
                resolution: targetResolution
            )

            let tokenIdentity = "\(processingIdentity.route.backend.backendID).output.\(frame.sequenceNumber)"
            let outputToken = try AppleUpscaleResourceLifetimeToken(
                identity: tokenIdentity,
                releaseAction: { [completion, outputReleaseObserver] in
                    completion.finishAfterAppend()
                    outputReleaseObserver(tokenIdentity)
                }
            )
            completionTransferred = true
            return .processed(
                try AppleUpscaleProcessedFrame(
                    sequenceNumber: frame.sequenceNumber,
                    pixelBuffer: output,
                    presentationTimestamp: frame.presentationTimestamp,
                    duration: frame.duration,
                    colorDescription: frame.colorDescription,
                    metadataIdentity: frame.metadataIdentity,
                    resourceLifetimeToken: outputToken,
                    processingIdentity: processingIdentity
                )
            )
        } catch is CancellationError {
            return .rejected(cancellationRejection)
        } catch {
            return .failed(scalingFailure)
        }
    }

    func reset(
        reason _: AppleUpscaleResetReason,
        nextHistoryGeneration _: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async {
        guard !cancellation.isCancelled else { return }
        ashBackend.reset()
    }

    func finish() async {}

    func cancel() async {
        let task = state.withLock { state -> ProcessingTask? in
            state.active?.task.cancel()
            return state.active?.task
        }
        _ = await task?.result
        ashBackend.reset()
    }

    private func install(_ task: ProcessingTask) -> UInt64 {
        state.withLock { state in
            let generation = state.nextGeneration
            state.nextGeneration += 1
            state.active = ActiveProcessing(generation: generation, task: task)
            return generation
        }
    }

    private func clearActive(generation: UInt64) {
        state.withLock { state in
            guard state.active?.generation == generation else { return }
            state.active = nil
        }
    }
}
