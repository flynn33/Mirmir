import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal

// This adapter keeps the closed outcome registry beside the FIFO driver mapping.
// swiftlint:disable file_length

enum R05MetalFXBackendConstructionError: Error, Equatable, Sendable {
    case subjectMissingFromFrozenCatalog(R05MetalFXSubjectID)
}

enum R05MetalFXBackendRejectionReason: String, CaseIterable, Sendable {
    case sessionContractMismatch = "r05_metalfx_session_contract_mismatch"
    case productScopeForbidden = "product_scope_forbidden"
    case productQualificationRequired = "r05_metalfx_product_qualification_required"
    case frameContractMismatch = "r05_metalfx_frame_contract_mismatch"
}

enum R05MetalFXBackendUnavailableReason: String, CaseIterable, Sendable {
    case capabilityNotObserved = "r05_metalfx_capability_not_observed"
    case capabilityUnavailable = "r05_metalfx_capability_unavailable"
    case nativeRuntimeUnavailable = "r05_metalfx_native_runtime_unavailable"
}

enum R05MetalFXBackendFailureReason: String, CaseIterable, Error, Sendable {
    case sessionConstructionFailed = "r05_metalfx_session_construction_failed"
    case outputAllocationFailed = "r05_metalfx_output_allocation_failed"
    case outputContractMismatch = "r05_metalfx_output_contract_mismatch"
}

protocol R05MetalFXSpatialDriving: AnyObject, Sendable {
    func process(
        _ request: R05MetalFXSpatialDriverRequest
    ) async -> R05MetalFXSpatialDriverOutcome
}

extension R05MetalFXSpatialDriver: R05MetalFXSpatialDriving {}

typealias R05MetalFXSpatialDriverFactory = @Sendable (
    _ route: R05MetalFXRouteDescriptor
) -> (any R05MetalFXSpatialDriving)?

typealias R05MetalFXOutputReleaseObserver = @Sendable (_ identity: String) -> Void

enum R05MetalFXBackendAdmissionPolicy: Hashable, Sendable {
    case fixtureContract
    case nativeProduct

    var admissionScope: AppleUpscaleAdmissionScope {
        switch self {
        case .fixtureContract:
            return .fixtureOnly
        case .nativeProduct:
            return .product
        }
    }

    var policyIdentity: String {
        switch self {
        case .fixtureContract:
            return R05MetalFXRouteCatalog.policyIdentity
        case .nativeProduct:
            return "r05.native-spatial.runtime-qualified.product.v1"
        }
    }
}

enum R05MetalFXCapabilityUnavailableReason: String, Hashable, Sendable {
    case deviceUnavailable = "r05_metalfx_native_device_unavailable"
    case commandQueueCreationFailed =
        "r05_metalfx_native_command_queue_creation_failed"
    case deviceSupportNotObserved =
        "r05_metalfx_native_device_support_not_observed"
    case deviceUnsupported = "r05_metalfx_native_device_unsupported"
    case descriptorConstructionReturnedNil =
        "r05_metalfx_native_descriptor_construction_returned_nil"
}

enum R05MetalFXNativeCapabilityStatus: Hashable, Sendable {
    case runnable
    case rejected(R05MetalFXRouteRejectionReason)
    case unavailable(R05MetalFXCapabilityUnavailableReason)
}

struct R05MetalFXNativeCapabilityObservation: Hashable, Sendable {
    let route: R05MetalFXRouteDescriptor
    let capability: AppleUpscaleCapability
    let status: R05MetalFXNativeCapabilityStatus
}

enum R05MetalFXNativeCapabilityObserver {
    static func observeNative(
        subjectID: R05MetalFXSubjectID
    ) throws -> R05MetalFXNativeCapabilityObservation {
        guard let route = R05MetalFXRouteCatalog.route(subjectID) else {
            throw R05MetalFXContractError.catalogIdentityMismatch(subjectID)
        }
        if let rejection = route.decodedVideoRejectionReason {
            return try makeObservation(
                route: route,
                status: .rejected(.decodedVideo(rejection)),
                supportWasObserved: true
            )
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return try makeObservation(
                route: route,
                status: .unavailable(.deviceUnavailable),
                supportWasObserved: true
            )
        }
        guard device.makeCommandQueue() != nil else {
            return try makeObservation(
                route: route,
                status: .unavailable(.commandQueueCreationFailed),
                supportWasObserved: true
            )
        }
        return try observe(
            subjectID: subjectID,
            runtime: R05MetalFXNativeSpatialRuntimeProbe(device: device)
        )
    }

    static func observe(
        subjectID: R05MetalFXSubjectID,
        runtime: any R05MetalFXSpatialRuntimeProbing
    ) throws -> R05MetalFXNativeCapabilityObservation {
        guard let route = R05MetalFXRouteCatalog.route(subjectID) else {
            throw R05MetalFXContractError.catalogIdentityMismatch(subjectID)
        }
        if let rejection = route.decodedVideoRejectionReason {
            return try makeObservation(
                route: route,
                status: .rejected(.decodedVideo(rejection)),
                supportWasObserved: true
            )
        }
        switch runtime.supportsSpatialDevice(for: route) {
        case .notObserved:
            return try makeObservation(
                route: route,
                status: .unavailable(.deviceSupportNotObserved),
                supportWasObserved: false
            )
        case .observed(false):
            return try makeObservation(
                route: route,
                status: .unavailable(.deviceUnsupported),
                supportWasObserved: true
            )
        case .observed(true):
            break
        }
        switch runtime.constructSpatialScaler(for: route) {
        case .constructed:
            return try makeObservation(
                route: route,
                status: .runnable,
                supportWasObserved: true
            )
        case .returnedNil:
            return try makeObservation(
                route: route,
                status: .unavailable(.descriptorConstructionReturnedNil),
                supportWasObserved: true
            )
        }
    }

    private static func makeObservation(
        route: R05MetalFXRouteDescriptor,
        status: R05MetalFXNativeCapabilityStatus,
        supportWasObserved: Bool
    ) throws -> R05MetalFXNativeCapabilityObservation {
        let isRunnable: Bool
        switch status {
        case .runnable:
            isRunnable = true
        case .rejected, .unavailable:
            isRunnable = false
        }
        let capability = try AppleUpscaleCapability(
            id: route.capabilityID,
            role: route.backendIdentity.capabilityRole,
            frameworkIdentity: "MetalFX",
            observationStatus: supportWasObserved ? .observed : .notObserved,
            runtimeDisposition: isRunnable
                ? .runnable
                : (supportWasObserved ? .unavailable : .diagnosticOnly),
            backendEligibility: isRunnable
                ? .productQualified
                : .notEvaluated
        )
        return R05MetalFXNativeCapabilityObservation(
            route: route,
            capability: capability,
            status: status
        )
    }
}

private final class R05MetalFXNativeSpatialRuntimeProbe:
    R05MetalFXSpatialRuntimeProbing,
    @unchecked Sendable {
    private let scalerFactory: R05DefaultMetalFXSpatialScalerFactory

    init(device: any MTLDevice) {
        scalerFactory = R05DefaultMetalFXSpatialScalerFactory(device: device)
    }

    func supportsSpatialDevice(
        for route: R05MetalFXRouteDescriptor
    ) -> R05MetalFXSupportObservation {
        guard R05MetalFXSpatialRouteMapping.driverRoute(for: route) != nil else {
            return .observed(false)
        }
        return .observed(scalerFactory.supportsDevice())
    }

    func constructSpatialScaler(
        for route: R05MetalFXRouteDescriptor
    ) -> R05MetalFXSpatialConstructionObservation {
        guard let driverRoute = R05MetalFXSpatialRouteMapping.driverRoute(
            for: route
        ) else {
            return .returnedNil
        }
        let configuration = R05MetalFXSpatialScalerConfiguration(
            inputDimensions: driverRoute.sourceDimensions,
            outputDimensions: driverRoute.targetDimensions,
            colorTextureFormat: .rgba16Float,
            outputTextureFormat: .rgba16Float,
            colorMode: .linear
        )
        return scalerFactory.makeScaler(configuration: configuration) == nil
            ? .returnedNil
            : .constructed
    }
}

enum R05MetalFXSpatialRouteMapping {
    static func driverRoute(
        for route: R05MetalFXRouteDescriptor
    ) -> R05MetalFXSpatialDriverRoute? {
        guard route.capabilityID.rawValue == "A07",
              route.backendIdentity == .spatial,
              route.gate == .runtimeObservationRequired,
              route.decodedVideoRejectionReason == nil else {
            return nil
        }
        switch route.subjectID {
        case .spatial1p5x:
            guard route.routeID == .spatial1p5x,
                  route.sourceResolution == .p720,
                  route.targetResolution == .p1080,
                  route.scaleFactor == .oneAndOneHalf else {
                return nil
            }
            return .oneAndOneHalf
        case .spatial2x:
            guard route.routeID == .spatial2x,
                  route.sourceResolution == .p1080,
                  route.targetResolution == .p2160,
                  route.scaleFactor == .two else {
                return nil
            }
            return .two
        case .temporal1p5x,
             .temporal2x,
             .denoisedTemporal1p5x,
             .denoisedTemporal2x,
             .frameInterpolation1080p:
            return nil
        }
    }
}

final class R05MetalFXSpatialBackend: AppleUpscaleBackend, @unchecked Sendable {
    let identity: AppleUpscaleBackendIdentity
    let capabilityID: AppleUpscaleCapabilityID
    let routeIdentity: AppleUpscaleRouteIdentity
    let route: R05MetalFXRouteDescriptor

    private let driverFactory: R05MetalFXSpatialDriverFactory
    private let outputReleaseObserver: R05MetalFXOutputReleaseObserver
    private let outcomes: R05MetalFXAppleOutcomes
    private let admissionPolicy: R05MetalFXBackendAdmissionPolicy

    init(
        subjectID: R05MetalFXSubjectID,
        driverFactory: @escaping R05MetalFXSpatialDriverFactory,
        outputReleaseObserver: @escaping R05MetalFXOutputReleaseObserver = { _ in },
        admissionPolicy: R05MetalFXBackendAdmissionPolicy = .fixtureContract
    ) throws {
        guard let route = R05MetalFXRouteCatalog.route(subjectID) else {
            throw R05MetalFXBackendConstructionError
                .subjectMissingFromFrozenCatalog(subjectID)
        }
        let catalogRouteIdentity = try R05MetalFXRouteCatalog.makeRouteIdentity(
            for: route
        )
        let routeIdentity = try AppleUpscaleRouteIdentity(
            backend: catalogRouteIdentity.backend,
            configurationIdentity: catalogRouteIdentity.configurationIdentity,
            policyIdentity: admissionPolicy.policyIdentity,
            materialDecisionIdentity: catalogRouteIdentity.materialDecisionIdentity
        )
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: routeIdentity,
            fallbackHistory: []
        )
        self.identity = routeIdentity.backend
        self.capabilityID = route.capabilityID
        self.routeIdentity = routeIdentity
        self.route = route
        self.driverFactory = driverFactory
        self.outputReleaseObserver = outputReleaseObserver
        self.admissionPolicy = admissionPolicy
        self.outcomes = try R05MetalFXAppleOutcomes(
            processingIdentity: processingIdentity
        )
    }

    static func makeNative(
        subjectID: R05MetalFXSubjectID,
        outputReleaseObserver: @escaping R05MetalFXOutputReleaseObserver = { _ in }
    ) throws -> R05MetalFXSpatialBackend {
        try R05MetalFXSpatialBackend(
            subjectID: subjectID,
            driverFactory: { route in
                guard route.backendIdentity == .spatial,
                      let device = MTLCreateSystemDefaultDevice(),
                      let queue = device.makeCommandQueue() else {
                    return nil
                }
                return R05MetalFXSpatialDriver(device: device, commandQueue: queue)
            },
            outputReleaseObserver: outputReleaseObserver,
            admissionPolicy: .nativeProduct
        )
    }

    static func observeNativeCapability(
        subjectID: R05MetalFXSubjectID
    ) throws -> R05MetalFXNativeCapabilityObservation {
        try R05MetalFXNativeCapabilityObserver.observeNative(subjectID: subjectID)
    }

    func makeConfiguration() throws -> AppleUpscaleSessionConfiguration {
        try AppleUpscaleSessionConfiguration(
            capabilityID: capabilityID,
            sourceResolution: route.sourceResolution,
            targetResolution: route.targetResolution,
            pixelFormat: R05MetalFXColorBridge.pixelFormat,
            configurationIdentity: route.configurationIdentity
        )
    }

    // The admission, live-runtime, and allocation gates form one closed outcome map.
    // swiftlint:disable:next function_body_length
    func makeSession(
        configuration: AppleUpscaleSessionConfiguration,
        context: AppleUpscaleSessionContext
    ) async -> AppleUpscaleSessionCreationOutcome {
        guard configurationMatches(configuration),
              context.policyIdentity == routeIdentity.policyIdentity else {
            return .rejected(
                outcomes.rejection(
                    R05MetalFXBackendRejectionReason.sessionContractMismatch.rawValue
                )
            )
        }
        if let rejection = route.decodedVideoRejectionReason {
            return .rejected(outcomes.rejection(rejection.rawValue))
        }
        guard context.admissionScope == admissionPolicy.admissionScope else {
            return .rejected(
                outcomes.rejection(
                    (
                        admissionPolicy == .fixtureContract
                            ? R05MetalFXBackendRejectionReason.productScopeForbidden
                            : .productQualificationRequired
                    ).rawValue
                )
            )
        }
        guard let driverRoute = R05MetalFXSpatialRouteMapping.driverRoute(
            for: route
        ) else {
            return .rejected(
                outcomes.rejection(
                    R05MetalFXBackendRejectionReason.sessionContractMismatch.rawValue
                )
            )
        }
        guard let capability = context.capabilityRegistry.capability(for: capabilityID)
        else {
            return .unavailable(
                outcomes.unavailable(
                    R05MetalFXBackendUnavailableReason.capabilityNotObserved.rawValue
                )
            )
        }
        guard capability.role == .primaryScaler,
              capability.frameworkIdentity == "MetalFX" else {
            return .rejected(
                outcomes.rejection(
                    R05MetalFXBackendRejectionReason.sessionContractMismatch.rawValue
                )
            )
        }
        guard capability.observationStatus == .observed else {
            return .unavailable(
                outcomes.unavailable(
                    R05MetalFXBackendUnavailableReason.capabilityNotObserved.rawValue
                )
            )
        }
        guard capability.runtimeDisposition == .runnable else {
            return .unavailable(
                outcomes.unavailable(
                    R05MetalFXBackendUnavailableReason.capabilityUnavailable.rawValue
                )
            )
        }
        guard capability.isEligible(for: context.admissionScope) else {
            return .rejected(
                outcomes.rejection(
                    (
                        admissionPolicy == .fixtureContract
                            ? R05MetalFXBackendRejectionReason.productScopeForbidden
                            : .productQualificationRequired
                    ).rawValue
                )
            )
        }
        guard let driver = driverFactory(route) else {
            return .unavailable(
                outcomes.unavailable(
                    R05MetalFXBackendUnavailableReason.nativeRuntimeUnavailable.rawValue
                )
            )
        }

        do {
            let outputPool = try PixelBufferBridge.makePool(
                width: route.targetResolution.width,
                height: route.targetResolution.height,
                format: R05MetalFXColorBridge.pixelFormat,
                capacity: 3
            )
            let sessionDriver = R05MetalFXAppleSessionDriver(
                route: route,
                driverRoute: driverRoute,
                routeIdentity: routeIdentity,
                outputPool: outputPool,
                driver: driver,
                outcomes: outcomes,
                outputReleaseObserver: outputReleaseObserver
            )
            return .created(
                try AppleUpscaleFIFOSession(
                    identity: routeIdentity,
                    driver: sessionDriver
                )
            )
        } catch {
            return .failed(
                outcomes.failure(
                    R05MetalFXBackendFailureReason.sessionConstructionFailed.rawValue
                )
            )
        }
    }

    private func configurationMatches(
        _ configuration: AppleUpscaleSessionConfiguration
    ) -> Bool {
        configuration.capabilityID == capabilityID
            && configuration.sourceResolution == route.sourceResolution
            && configuration.targetResolution == route.targetResolution
            && configuration.pixelFormat == R05MetalFXColorBridge.pixelFormat
            && configuration.configurationIdentity == route.configurationIdentity
    }

}

private struct R05MetalFXAppleOutcomes: Sendable {
    let processingIdentity: AppleUpscaleProcessingIdentity
    private let rejections: [String: AppleUpscaleBackendRejected]
    private let unavailableValues: [String: AppleUpscaleBackendUnavailable]
    private let failures: [String: AppleUpscaleBackendFailed]

    init(processingIdentity: AppleUpscaleProcessingIdentity) throws {
        self.processingIdentity = processingIdentity
        let rejectionReasons = R05MetalFXBackendRejectionReason.allCases.map(\.rawValue)
            + [
                R05MetalFXDecodedVideoRejectionReason
                    .missingTemporalRendererSemantics.rawValue,
                R05MetalFXDecodedVideoRejectionReason
                    .missingDenoisedRendererSemantics.rawValue,
                R05MetalFXDecodedVideoRejectionReason
                    .missingInterpolationRendererSemantics.rawValue
            ]
            + R05MetalFXSpatialDriverRejectionReason.allCases.map(\.rawValue)
            + R05MetalFXSpatialCancellationReason.allCases.map(\.rawValue)
        rejections = try Dictionary(
            uniqueKeysWithValues: rejectionReasons.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendRejected(
                        processingIdentity: processingIdentity,
                        reason: reason
                    )
                )
            }
        )

        let unavailableReasons = R05MetalFXBackendUnavailableReason.allCases
            .map(\.rawValue)
            + R05MetalFXSpatialDriverUnsupportedReason.allCases.map(\.rawValue)
            + R05MetalFXSpatialDriverUnavailableReason.allCases.map(\.rawValue)
        unavailableValues = try Dictionary(
            uniqueKeysWithValues: unavailableReasons.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendUnavailable(
                        processingIdentity: processingIdentity,
                        reason: reason
                    )
                )
            }
        )

        let failureReasons = R05MetalFXBackendFailureReason.allCases.map(\.rawValue)
            + R05MetalFXSpatialDriverFailureReason.allCases.map(\.rawValue)
        failures = try Dictionary(
            uniqueKeysWithValues: failureReasons.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendFailed(
                        processingIdentity: processingIdentity,
                        reason: reason
                    )
                )
            }
        )
    }

    func rejection(_ reason: String) -> AppleUpscaleBackendRejected {
        guard let value = rejections[reason] else {
            preconditionFailure("Unregistered R05 rejection reason: \(reason)")
        }
        return value
    }

    func unavailable(_ reason: String) -> AppleUpscaleBackendUnavailable {
        guard let value = unavailableValues[reason] else {
            preconditionFailure("Unregistered R05 unavailable reason: \(reason)")
        }
        return value
    }

    func failure(_ reason: String) -> AppleUpscaleBackendFailed {
        guard let value = failures[reason] else {
            preconditionFailure("Unregistered R05 failure reason: \(reason)")
        }
        return value
    }
}

private final class R05MetalFXAppleSessionDriver: AppleUpscaleSessionDriver,
    @unchecked Sendable {
    private let route: R05MetalFXRouteDescriptor
    private let driverRoute: R05MetalFXSpatialDriverRoute
    private let routeIdentity: AppleUpscaleRouteIdentity
    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let outputPool: CVPixelBufferPool
    private let driver: any R05MetalFXSpatialDriving
    private let outcomes: R05MetalFXAppleOutcomes
    private let outputReleaseObserver: R05MetalFXOutputReleaseObserver

    init(
        route: R05MetalFXRouteDescriptor,
        driverRoute: R05MetalFXSpatialDriverRoute,
        routeIdentity: AppleUpscaleRouteIdentity,
        outputPool: CVPixelBufferPool,
        driver: any R05MetalFXSpatialDriving,
        outcomes: R05MetalFXAppleOutcomes,
        outputReleaseObserver: @escaping R05MetalFXOutputReleaseObserver
    ) {
        self.route = route
        self.driverRoute = driverRoute
        self.routeIdentity = routeIdentity
        self.processingIdentity = outcomes.processingIdentity
        self.outputPool = outputPool
        self.driver = driver
        self.outcomes = outcomes
        self.outputReleaseObserver = outputReleaseObserver
    }

    // The closed driver-outcome switch and ownership transfer stay in one scope.
    // swiftlint:disable:next function_body_length
    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard !cancellation.isCancelled else {
            return .rejected(
                outcomes.rejection(
                    R05MetalFXSpatialCancellationReason.beforeCommit.rawValue
                )
            )
        }
        do {
            try R03NV12Contract.validate(
                frame: frame,
                resolution: route.sourceResolution
            )
            try R05MetalFXColorBridge.validate(pixelBuffer: frame.pixelBuffer)
        } catch {
            return .rejected(
                outcomes.rejection(
                    R05MetalFXBackendRejectionReason.frameContractMismatch.rawValue
                )
            )
        }

        let output: CVPixelBuffer
        do {
            output = try PixelBufferBridge.dequeue(from: outputPool)
        } catch {
            return .failed(
                outcomes.failure(
                    R05MetalFXBackendFailureReason.outputAllocationFailed.rawValue
                )
            )
        }
        let outputIdentity = [
            routeIdentity.backend.backendID,
            "output",
            "\(frame.sequenceNumber)",
            "g\(historyGeneration)"
        ].joined(separator: ".")
        var outputTransferred = false
        defer {
            if !outputTransferred {
                outputReleaseObserver(outputIdentity)
            }
        }

        R05MetalFXColorBridge.installRequiredAttachments(on: output)
        let sourceSurface = R05MetalFXSpatialCVPixelBufferSurface(
            pixelBuffer: frame.pixelBuffer
        )
        let destinationSurface = R05MetalFXSpatialCVPixelBufferSurface(
            pixelBuffer: output
        )
        let publication = R05MetalFXPublicationProbe(
            validate: { [destinationSurface, route] in
                try R05MetalFXColorBridge.validate(
                    pixelBuffer: destinationSurface.pixelBuffer
                )
                try R03NV12Contract.validate(
                    pixelBuffer: destinationSurface.pixelBuffer,
                    resolution: route.targetResolution
                )
            }
        )
        let driverOutcome = await driver.process(
            R05MetalFXSpatialDriverRequest(
                route: driverRoute,
                source: sourceSurface,
                destination: destinationSurface,
                cancellation: R05MetalFXSpatialDriverCancellation(
                    isCancelled: { cancellation.isCancelled }
                ),
                publish: { try publication.publish() }
            )
        )

        switch driverOutcome {
        case .processed(let processed):
            guard processed.route == driverRoute,
                  let returnedSurface = processed.destination
                    as? R05MetalFXSpatialCVPixelBufferSurface,
                  returnedSurface === destinationSurface,
                  publication.wasPublishedExactlyOnce else {
                return .failed(
                    outcomes.failure(
                        R05MetalFXBackendFailureReason.outputContractMismatch.rawValue
                    )
                )
            }
            do {
                try R05MetalFXColorBridge.validate(pixelBuffer: output)
                try R03NV12Contract.validate(
                    pixelBuffer: output,
                    resolution: route.targetResolution
                )
                let outputToken = try AppleUpscaleResourceLifetimeToken(
                    identity: outputIdentity,
                    releaseAction: { [outputReleaseObserver] in
                        outputReleaseObserver(outputIdentity)
                    }
                )
                outputTransferred = true
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
            } catch {
                return .failed(
                    outcomes.failure(
                        R05MetalFXBackendFailureReason.outputContractMismatch.rawValue
                    )
                )
            }
        case .rejected(let reason):
            return .rejected(outcomes.rejection(reason.rawValue))
        case .unsupported(let reason):
            return .unavailable(outcomes.unavailable(reason.rawValue))
        case .unavailable(let reason):
            return .unavailable(outcomes.unavailable(reason.rawValue))
        case .failed(let reason):
            return .failed(outcomes.failure(reason.rawValue))
        case .cancelled(let reason):
            return .rejected(outcomes.rejection(reason.rawValue))
        }
    }

    func reset(
        reason _: AppleUpscaleResetReason,
        nextHistoryGeneration _: UInt64,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) async {}

    func finish() async {}

    func cancel() async {}
}

private final class R05MetalFXPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let validate: @Sendable () throws -> Void
    private var attemptCount = 0
    private var successCount = 0

    init(validate: @escaping @Sendable () throws -> Void) {
        self.validate = validate
    }

    var wasPublishedExactlyOnce: Bool {
        lock.withLock { attemptCount == 1 && successCount == 1 }
    }

    func publish() throws {
        try lock.withLock {
            attemptCount += 1
            guard attemptCount == 1 else {
                throw R05MetalFXBackendFailureReason.outputContractMismatch
            }
        }
        try validate()
        lock.withLock { successCount += 1 }
    }
}

// swiftlint:enable file_length
