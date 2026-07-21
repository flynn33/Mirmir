import CoreVideo
import Foundation

enum R03DeterministicBackendConstructionError: Error, Equatable, Sendable {
    case subjectIsNotWholeFrame(R03BaselineSubjectID)
    case routeNotPreregistered(subject: R03BaselineSubjectID, route: R03ScaleRoute)
}

final class R03DeterministicBackend: AppleUpscaleBackend, @unchecked Sendable {
    let identity: AppleUpscaleBackendIdentity
    let capabilityID: AppleUpscaleCapabilityID
    let routeIdentity: AppleUpscaleRouteIdentity
    let subject: R03BaselineSubjectDescriptor
    let route: R03ScaleRoute

    private let configurationIdentity: String
    private let scalerFactory: R03NV12ScalerFactory
    private let outputReleaseObserver: R03OutputReleaseObserver
    private let sessionContractRejection: AppleUpscaleBackendRejected
    private let capabilityUnavailable: AppleUpscaleBackendUnavailable
    private let sessionCreationFailure: AppleUpscaleBackendFailed

    init(
        subjectID: R03BaselineSubjectID,
        route: R03ScaleRoute,
        scalerFactory: @escaping R03NV12ScalerFactory,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws {
        guard let subject = R03DeterministicBackendCatalog.subject(subjectID),
              subject.kind == .wholeFrameBackend else {
            throw R03DeterministicBackendConstructionError.subjectIsNotWholeFrame(subjectID)
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
        self.scalerFactory = scalerFactory
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

        do {
            let scaler = try scalerFactory(
                route.canonicalSourceResolution,
                route.canonicalTargetResolution
            )
            let outputPool = try PixelBufferBridge.makePool(
                width: route.canonicalTargetResolution.width,
                height: route.canonicalTargetResolution.height,
                format: R03NV12Contract.pixelFormat,
                capacity: 3
            )
            let driver = try R03DeterministicSessionDriver(
                route: routeIdentity,
                sourceResolution: route.canonicalSourceResolution,
                targetResolution: route.canonicalTargetResolution,
                outputPool: outputPool,
                scaler: scaler,
                outputReleaseObserver: outputReleaseObserver
            )
            return .created(
                try AppleUpscaleFIFOSession(identity: routeIdentity, driver: driver)
            )
        } catch R03NV12ScalingError.runtimeUnavailable {
            return .unavailable(capabilityUnavailable)
        } catch {
            return .failed(sessionCreationFailure)
        }
    }
}

extension R03DeterministicBackend {
    static func makeVImage(
        mode: R03VImageScalingMode,
        route: R03ScaleRoute,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        try R03DeterministicBackend(
            subjectID: mode.subjectID,
            route: route,
            scalerFactory: { _, _ in
                R03VImageScaler(mode: mode, route: route)
            },
            outputReleaseObserver: outputReleaseObserver
        )
    }
}

private final class R03DeterministicSessionDriver: AppleUpscaleSessionDriver,
    @unchecked Sendable {
    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let cancellationRejection: AppleUpscaleBackendRejected
    private let frameContractRejection: AppleUpscaleBackendRejected
    private let runtimeUnavailable: AppleUpscaleBackendUnavailable
    private let scalingFailure: AppleUpscaleBackendFailed
    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution
    private let outputPool: CVPixelBufferPool
    private let scaler: any R03NV12Scaling
    private let outputReleaseObserver: R03OutputReleaseObserver

    init(
        route: AppleUpscaleRouteIdentity,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        outputPool: CVPixelBufferPool,
        scaler: any R03NV12Scaling,
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
        runtimeUnavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: processingIdentity,
            reason: "r03_scaler_runtime_unavailable"
        )
        scalingFailure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "r03_scaling_failed"
        )
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.outputPool = outputPool
        self.scaler = scaler
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
            try scaler.scale(
                source: frame.pixelBuffer,
                destination: output,
                cancellation: cancellation
            )
            guard !cancellation.isCancelled else {
                return .rejected(cancellationRejection)
            }
            try R03NV12Contract.validate(
                pixelBuffer: output,
                resolution: targetResolution
            )
            let tokenIdentity = "\(processingIdentity.route.backend.backendID).output.\(frame.sequenceNumber)"
            let outputToken = try AppleUpscaleResourceLifetimeToken(
                identity: tokenIdentity,
                releaseAction: { [outputReleaseObserver] in
                    outputReleaseObserver(tokenIdentity)
                }
            )
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
        } catch R03NV12ScalingError.operationCancelled {
            return .rejected(cancellationRejection)
        } catch R03NV12ScalingError.runtimeUnavailable {
            return .unavailable(runtimeUnavailable)
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
        scaler.reset()
    }

    func finish() async {
        scaler.finish()
    }

    func cancel() async {
        scaler.cancel()
    }
}
