import CoreMedia
import CoreVideo
import Foundation
import IOSurface

// swiftlint:disable file_length

enum R04VideoToolboxSupportObservation<Value: Sendable>: Sendable {
    case observed(Value)
    case notObserved
}

extension R04VideoToolboxSupportObservation: Equatable where Value: Equatable {}

enum R04VideoToolboxHistoryBoundary: String, Hashable, Sendable {
    case firstFrame = "first_frame"
    case continuing
    case notApplicable = "not_applicable"
}

struct R04VideoToolboxHistoryFrame: @unchecked Sendable {
    let sequenceNumber: Int
    let pixelBuffer: CVPixelBuffer
    let presentationTimestamp: CMTime
    let duration: CMTime
}

struct R04VideoToolboxPrecomputedFlow: @unchecked Sendable {
    let forward: CVPixelBuffer
    let backward: CVPixelBuffer
}

enum R04VideoToolboxOpticalFlowMode: @unchecked Sendable {
    case disabled
    case appleComputed
    case precomputed(R04VideoToolboxPrecomputedFlow)
}

struct R04VideoToolboxProcessingRequest: @unchecked Sendable {
    let route: R04VideoToolboxRouteDescriptor
    let sourceFrame: AppleUpscaleFrame
    let previousSource: R04VideoToolboxHistoryFrame?
    let previousOutput: R04VideoToolboxHistoryFrame?
    let historyGeneration: UInt64
    let historyBoundary: R04VideoToolboxHistoryBoundary
    let submissionMode: R04VideoToolboxSubmissionMode
    let opticalFlowMode: R04VideoToolboxOpticalFlowMode
}

enum R04VideoToolboxResetCause: Hashable, Sendable {
    case firstFrame
    case detectedDiscontinuity
    case session(AppleUpscaleResetReason)
}

struct R04VideoToolboxResetRequest: Hashable, Sendable {
    let route: R04VideoToolboxRouteDescriptor
    let cause: R04VideoToolboxResetCause
    let historyGeneration: UInt64
}

struct R04VideoToolboxRuntimeOutput: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let releaseAction: @Sendable () -> Void

    init(
        pixelBuffer: CVPixelBuffer,
        releaseAction: @escaping @Sendable () -> Void
    ) {
        self.pixelBuffer = pixelBuffer
        self.releaseAction = releaseAction
    }
}

enum R04VideoToolboxRuntimeOutcome: @unchecked Sendable {
    case processed(R04VideoToolboxRuntimeOutput)
    case unavailable(R04VideoToolboxRouteUnavailableReason)
    case rejected(R04VideoToolboxRouteRejectionReason)
    case failed(R04VideoToolboxRouteFailureReason)
}

protocol R04VideoToolboxRuntime: AnyObject, Sendable {
    func quality2xSupport(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Bool>

    func lowLatencySupportedScaleFactors(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Set<R04VideoToolboxScaleFactor>>

    func opticalFlowSupport(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Bool>

    func configurationDiagnostics(
        for route: R04VideoToolboxRouteDescriptor
    ) async -> R04VideoToolboxSupportObservation<
        R04VideoToolboxConfigurationDiagnostics
    >

    func process(
        _ request: R04VideoToolboxProcessingRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> R04VideoToolboxRuntimeOutcome

    func reset(
        _ request: R04VideoToolboxResetRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async

    func finish() async
    func cancel() async
}

typealias R04VideoToolboxRuntimeFactory = @Sendable () async throws
    -> any R04VideoToolboxRuntime

typealias R04VideoToolboxOpticalFlowProvider = @Sendable (
    _ previousSource: R04VideoToolboxHistoryFrame?,
    _ sourceFrame: AppleUpscaleFrame
) async -> R04VideoToolboxOpticalFlowMode

protocol R04VideoToolboxHistoryBufferCopying: Sendable {
    func makeOwnedCopy(
        of source: CVPixelBuffer,
        resolution: VideoResolution
    ) throws -> CVPixelBuffer
}

enum R04VideoToolboxRouteResolver {
    static func resolve(
        _ route: R04VideoToolboxRouteDescriptor,
        using runtime: any R04VideoToolboxRuntime
    ) async -> R04VideoToolboxRouteDecision {
        switch route.gate {
        case .publicContractUnrepresentable:
            return .rejected(
                R04VideoToolboxRouteRejected(
                    route: route,
                    reason: .publicContractUnrepresentable
                )
            )
        case .runtimeSupportRequired:
            switch await runtime.quality2xSupport(
                sourceResolution: route.sourceResolution
            ) {
            case .notObserved:
                return unavailable(route, reason: .runtimeSupportNotObserved)
            case .observed(false):
                return unavailable(route, reason: .runtimeSupportUnavailable)
            case .observed(true):
                return .runnable(route)
            }
        case .exactDimensionQueryRequired:
            switch await runtime.lowLatencySupportedScaleFactors(
                sourceResolution: route.sourceResolution
            ) {
            case .notObserved:
                return unavailable(route, reason: .runtimeSupportNotObserved)
            case .observed(let scales):
                guard scales.contains(route.scaleFactor) else {
                    return .rejected(
                        R04VideoToolboxRouteRejected(
                            route: route,
                            reason: .exactDimensionQueryRejected
                        )
                    )
                }
                return .runnable(route)
            }
        case .optionalRuntimeSupport:
            switch await runtime.opticalFlowSupport(
                sourceResolution: route.sourceResolution
            ) {
            case .notObserved:
                return unavailable(route, reason: .runtimeSupportNotObserved)
            case .observed(false):
                return unavailable(route, reason: .optionalSupportUnavailable)
            case .observed(true):
                return .optionalSupported(route)
            }
        }
    }

    private static func unavailable(
        _ route: R04VideoToolboxRouteDescriptor,
        reason: R04VideoToolboxRouteUnavailableReason
    ) -> R04VideoToolboxRouteDecision {
        .unavailable(
            R04VideoToolboxRouteUnavailable(route: route, reason: reason)
        )
    }
}

enum R04VideoToolboxBackendAdmissionPolicy: Hashable, Sendable {
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
            return R04VideoToolboxRouteCatalog.policyIdentity
        case .nativeProduct:
            return "r04.native-runtime-qualified.product.v1"
        }
    }
}

enum R04VideoToolboxNativeCapabilityStatus: Hashable, Sendable {
    case runnable
    case optionalSupported
    case rejected(R04VideoToolboxRouteRejectionReason)
    case unavailable(R04VideoToolboxRouteUnavailableReason)
}

struct R04VTNativeCapabilityObservation: Hashable, Sendable {
    let route: R04VideoToolboxRouteDescriptor
    let capability: AppleUpscaleCapability
    let status: R04VideoToolboxNativeCapabilityStatus
    let diagnostics: R04VideoToolboxConfigurationDiagnostics?
}

enum R04VTNativeRuntimeProviderError: Error, Equatable, Sendable {
    case unavailableOnCurrentPlatform
}

enum R04VideoToolboxNativeRuntimeProvider {
    static var isCompiledForNativeRuntime: Bool {
#if compiler(>=6.2) && !targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    static func makeRuntime(
        qualityFlowConfiguration: VTNativeQualityFlowConfiguration = .appleComputed
    ) async throws -> any R04VideoToolboxRuntime {
#if compiler(>=6.2) && !targetEnvironment(simulator)
        guard #available(macOS 26.0, *) else {
            throw R04VTNativeRuntimeProviderError
                .unavailableOnCurrentPlatform
        }
        return VTSuperResolutionDriver(
            qualityFlowConfiguration: qualityFlowConfiguration
        )
#else
        throw R04VTNativeRuntimeProviderError
            .unavailableOnCurrentPlatform
#endif
    }
}

enum R04VideoToolboxNativeCapabilityObserver {
    static func observe(
        subjectID: R04VideoToolboxSubjectID,
        runtimeFactory: @escaping R04VideoToolboxRuntimeFactory
    ) async throws -> R04VTNativeCapabilityObservation {
        guard let route = R04VideoToolboxRouteCatalog.route(subjectID) else {
            throw R04VideoToolboxContractError.catalogIdentityMismatch(subjectID)
        }
        let runtime: any R04VideoToolboxRuntime
        do {
            runtime = try await runtimeFactory()
        } catch {
            return try makeObservation(
                route: route,
                status: .unavailable(.runtimeUnavailable),
                diagnostics: nil,
                supportWasObserved: true
            )
        }

        let decision = await R04VideoToolboxRouteResolver.resolve(
            route,
            using: runtime
        )
        switch decision {
        case .runnable:
            let diagnosticsObservation = await runtime.configurationDiagnostics(
                for: route
            )
            await runtime.finish()
            switch diagnosticsObservation {
            case .notObserved:
                return try makeObservation(
                    route: route,
                    status: .unavailable(.configurationDiagnosticsNotObserved),
                    diagnostics: nil,
                    supportWasObserved: false
                )
            case .observed(let diagnostics):
                switch R04VideoToolboxDiagnosticsValidator.validate(
                    route: route,
                    diagnostics: diagnostics
                ) {
                case .accepted:
                    return try makeObservation(
                        route: route,
                        status: .runnable,
                        diagnostics: diagnostics,
                        supportWasObserved: true
                    )
                case .rejected(let reason):
                    return try makeObservation(
                        route: route,
                        status: .rejected(reason),
                        diagnostics: diagnostics,
                        supportWasObserved: true
                    )
                case .unavailable(let reason):
                    return try makeObservation(
                        route: route,
                        status: .unavailable(reason),
                        diagnostics: diagnostics,
                        supportWasObserved: true
                    )
                }
            }
        case .optionalSupported:
            await runtime.finish()
            return try makeObservation(
                route: route,
                status: .optionalSupported,
                diagnostics: nil,
                supportWasObserved: true
            )
        case .rejected(let rejection):
            await runtime.finish()
            return try makeObservation(
                route: route,
                status: .rejected(rejection.reason),
                diagnostics: nil,
                supportWasObserved: true
            )
        case .unavailable(let unavailable):
            await runtime.finish()
            let supportWasObserved = unavailable.reason
                != .runtimeSupportNotObserved
            return try makeObservation(
                route: route,
                status: .unavailable(unavailable.reason),
                diagnostics: nil,
                supportWasObserved: supportWasObserved
            )
        }
    }

    private static func makeObservation(
        route: R04VideoToolboxRouteDescriptor,
        status: R04VideoToolboxNativeCapabilityStatus,
        diagnostics: R04VideoToolboxConfigurationDiagnostics?,
        supportWasObserved: Bool
    ) throws -> R04VTNativeCapabilityObservation {
        let role: AppleUpscaleCapabilityRole = route.backendKind
            == .optionalFlowSupport ? .temporalAnalyzer : .primaryScaler
        let isRunnable: Bool
        switch status {
        case .runnable, .optionalSupported:
            isRunnable = true
        case .rejected, .unavailable:
            isRunnable = false
        }
        let capability = try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(route.capabilityID),
            role: role,
            frameworkIdentity: "VideoToolbox",
            observationStatus: supportWasObserved ? .observed : .notObserved,
            runtimeDisposition: isRunnable
                ? .runnable
                : (supportWasObserved ? .unavailable : .diagnosticOnly),
            backendEligibility: isRunnable
                ? .productQualified
                : .notEvaluated
        )
        return R04VTNativeCapabilityObservation(
            route: route,
            capability: capability,
            status: status,
            diagnostics: diagnostics
        )
    }
}

enum R04VideoToolboxDiagnosticsValidation: Hashable, Sendable {
    case accepted
    case rejected(R04VideoToolboxRouteRejectionReason)
    case unavailable(R04VideoToolboxRouteUnavailableReason)
}

enum R04VideoToolboxDiagnosticsValidator {
    static func validate(
        route: R04VideoToolboxRouteDescriptor,
        diagnostics: R04VideoToolboxConfigurationDiagnostics
    ) -> R04VideoToolboxDiagnosticsValidation {
        guard diagnostics.supportedPixelFormats.contains(
            R04VideoToolboxRouteCatalog.pixelFormat
        ) else {
            return .rejected(.supportedPixelFormatRejected)
        }
        switch (route.backendKind, diagnostics.nativeIdentity) {
        case (.quality, .quality(let configuration)):
            guard configuration.frameWidth == route.sourceResolution.width,
                  configuration.frameHeight == route.sourceResolution.height,
                  route.scaleFactor.denominator == 1,
                  configuration.integerScaleFactor == route.scaleFactor.numerator,
                  configuration.inputType == .video,
                  configuration.qualityPriority == .normal,
                  configuration.revision >= 0,
                  diagnostics.processingMode == .quality else {
                return .rejected(.configurationIdentityMismatch)
            }
            guard diagnostics.modelStatus == .ready else {
                return .unavailable(.modelNotReady)
            }
            return .accepted
        case (.lowLatency, .lowLatency(let configuration)):
            let expectedScale = Float(route.scaleFactor.numerator)
                / Float(route.scaleFactor.denominator)
            guard configuration.frameWidth == route.sourceResolution.width,
                  configuration.frameHeight == route.sourceResolution.height,
                  configuration.scaleFactor == expectedScale,
                  diagnostics.processingMode == .lowLatency,
                  diagnostics.modelStatus == .notRequired else {
                return .rejected(.configurationIdentityMismatch)
            }
            return .accepted
        case (.optionalFlowSupport, _):
            return .rejected(.optionalSupportOnly)
        default:
            return .rejected(.configurationIdentityMismatch)
        }
    }
}

final class R04VideoToolboxBackend: AppleUpscaleBackend, @unchecked Sendable {
    let identity: AppleUpscaleBackendIdentity
    let capabilityID: AppleUpscaleCapabilityID
    let routeIdentity: AppleUpscaleRouteIdentity
    let route: R04VideoToolboxRouteDescriptor

    private let runtimeFactory: R04VideoToolboxRuntimeFactory
    private let opticalFlowProvider: R04VideoToolboxOpticalFlowProvider
    private let historyBufferCopier: any R04VideoToolboxHistoryBufferCopying
    private let admissionPolicy: R04VideoToolboxBackendAdmissionPolicy
    private let rejections: [
        R04VideoToolboxRouteRejectionReason: AppleUpscaleBackendRejected
    ]
    private let unavailable: [
        R04VideoToolboxRouteUnavailableReason: AppleUpscaleBackendUnavailable
    ]
    private let failures: [
        R04VideoToolboxRouteFailureReason: AppleUpscaleBackendFailed
    ]

    init(
        subjectID: R04VideoToolboxSubjectID,
        modelAssetsIdentity: AppleUpscaleModelAssetsIdentity,
        runtimeFactory: @escaping R04VideoToolboxRuntimeFactory,
        opticalFlowProvider: @escaping R04VideoToolboxOpticalFlowProvider = { _, _ in
            .disabled
        },
        historyBufferCopier: any R04VideoToolboxHistoryBufferCopying =
            R04VideoToolboxNV12HistoryBufferCopier(),
        admissionPolicy: R04VideoToolboxBackendAdmissionPolicy = .fixtureContract
    ) throws {
        guard let route = R04VideoToolboxRouteCatalog.route(subjectID) else {
            throw R04VideoToolboxContractError.catalogIdentityMismatch(subjectID)
        }
        let catalogRouteIdentity = try R04VideoToolboxRouteCatalog.makeRouteIdentity(
            for: route,
            modelAssetsIdentity: modelAssetsIdentity
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
        identity = routeIdentity.backend
        capabilityID = try AppleUpscaleCapabilityID(route.capabilityID)
        self.routeIdentity = routeIdentity
        self.route = route
        self.runtimeFactory = runtimeFactory
        self.opticalFlowProvider = opticalFlowProvider
        self.historyBufferCopier = historyBufferCopier
        self.admissionPolicy = admissionPolicy
        rejections = try Dictionary(
            uniqueKeysWithValues: R04VideoToolboxRouteRejectionReason.allCases.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendRejected(
                        processingIdentity: processingIdentity,
                        reason: reason.rawValue
                    )
                )
            }
        )
        unavailable = try Dictionary(
            uniqueKeysWithValues: R04VideoToolboxRouteUnavailableReason.allCases.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendUnavailable(
                        processingIdentity: processingIdentity,
                        reason: reason.rawValue
                    )
                )
            }
        )
        failures = try Dictionary(
            uniqueKeysWithValues: R04VideoToolboxRouteFailureReason.allCases.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendFailed(
                        processingIdentity: processingIdentity,
                        reason: reason.rawValue
                    )
                )
            }
        )
    }

    static func makeNative(
        subjectID: R04VideoToolboxSubjectID,
        modelAssetsIdentity: AppleUpscaleModelAssetsIdentity = .notRequired,
        qualityFlowConfiguration: VTNativeQualityFlowConfiguration = .appleComputed,
        opticalFlowProvider: @escaping R04VideoToolboxOpticalFlowProvider = { _, _ in
            .disabled
        }
    ) throws -> R04VideoToolboxBackend {
        try R04VideoToolboxBackend(
            subjectID: subjectID,
            modelAssetsIdentity: modelAssetsIdentity,
            runtimeFactory: {
                try await R04VideoToolboxNativeRuntimeProvider.makeRuntime(
                    qualityFlowConfiguration: qualityFlowConfiguration
                )
            },
            opticalFlowProvider: opticalFlowProvider,
            admissionPolicy: .nativeProduct
        )
    }

    static func observeNativeCapability(
        subjectID: R04VideoToolboxSubjectID,
        qualityFlowConfiguration: VTNativeQualityFlowConfiguration = .appleComputed
    ) async throws -> R04VTNativeCapabilityObservation {
        try await R04VideoToolboxNativeCapabilityObserver.observe(
            subjectID: subjectID,
            runtimeFactory: {
                try await R04VideoToolboxNativeRuntimeProvider.makeRuntime(
                    qualityFlowConfiguration: qualityFlowConfiguration
                )
            }
        )
    }

    func makeConfiguration() throws -> AppleUpscaleSessionConfiguration {
        try AppleUpscaleSessionConfiguration(
            capabilityID: capabilityID,
            sourceResolution: route.sourceResolution,
            targetResolution: route.targetResolution,
            pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat,
            configurationIdentity: route.configurationIdentity
        )
    }

    // The frozen admission matrix maps each gate to a distinct typed outcome.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func makeSession(
        configuration: AppleUpscaleSessionConfiguration,
        context: AppleUpscaleSessionContext
    ) async -> AppleUpscaleSessionCreationOutcome {
        guard configurationMatches(configuration),
              context.policyIdentity == routeIdentity.policyIdentity else {
            return rejected(.sessionContractMismatch)
        }
        guard context.admissionScope == admissionPolicy.admissionScope else {
            return rejected(
                admissionPolicy == .fixtureContract
                    ? .productScopeForbidden
                    : .productQualificationRequired
            )
        }
        if route.gate == .publicContractUnrepresentable {
            return rejected(.publicContractUnrepresentable)
        }
        if route.backendKind == .optionalFlowSupport {
            return rejected(.optionalSupportOnly)
        }
        guard let capability = context.capabilityRegistry.capability(for: capabilityID),
              capability.role == .primaryScaler,
              capability.frameworkIdentity == "VideoToolbox" else {
            return rejected(.sessionContractMismatch)
        }
        guard capability.observationStatus == .observed else {
            return unavailableOutcome(.capabilityNotObserved)
        }
        guard capability.runtimeDisposition == .runnable else {
            return unavailableOutcome(.capabilityUnavailable)
        }
        guard capability.isEligible(for: context.admissionScope) else {
            return rejected(
                admissionPolicy == .fixtureContract
                    ? .productScopeForbidden
                    : .productQualificationRequired
            )
        }

        let runtime: any R04VideoToolboxRuntime
        do {
            runtime = try await runtimeFactory()
        } catch {
            return failed(.runtimeConstructionFailed)
        }

        switch await R04VideoToolboxRouteResolver.resolve(route, using: runtime) {
        case .runnable:
            let diagnostics: R04VideoToolboxConfigurationDiagnostics
            switch await runtime.configurationDiagnostics(for: route) {
            case .notObserved:
                await runtime.finish()
                return unavailableOutcome(.configurationDiagnosticsNotObserved)
            case .observed(let observed):
                diagnostics = observed
            }
            switch R04VideoToolboxDiagnosticsValidator.validate(
                route: route,
                diagnostics: diagnostics
            ) {
            case .rejected(let reason):
                await runtime.finish()
                return rejected(reason)
            case .unavailable(let reason):
                await runtime.finish()
                return unavailableOutcome(reason)
            case .accepted:
                break
            }
            do {
                let observedRouteIdentity = try AppleUpscaleRouteIdentity(
                    backend: identity,
                    configurationIdentity: [
                        route.configurationIdentity,
                        "observed",
                        diagnostics.stableIdentity
                    ].joined(separator: "."),
                    policyIdentity: routeIdentity.policyIdentity,
                    materialDecisionIdentity: R04VideoToolboxRouteCatalog
                        .materialDecisionIdentity
                )
                let driver = try R04VideoToolboxSessionDriver(
                    route: route,
                    routeIdentity: observedRouteIdentity,
                    diagnostics: diagnostics,
                    runtime: runtime,
                    opticalFlowProvider: opticalFlowProvider,
                    historyBufferCopier: historyBufferCopier
                )
                return .created(
                    try AppleUpscaleFIFOSession(
                        identity: observedRouteIdentity,
                        driver: driver
                    )
                )
            } catch {
                await runtime.cancel()
                return failed(.runtimeConstructionFailed)
            }
        case .optionalSupported:
            await runtime.finish()
            return rejected(.optionalSupportOnly)
        case .rejected(let rejection):
            await runtime.finish()
            return rejected(rejection.reason)
        case .unavailable(let value):
            await runtime.finish()
            return unavailableOutcome(value.reason)
        }
    }

    private func configurationMatches(
        _ configuration: AppleUpscaleSessionConfiguration
    ) -> Bool {
        configuration.capabilityID == capabilityID
            && configuration.sourceResolution == route.sourceResolution
            && configuration.targetResolution == route.targetResolution
            && configuration.pixelFormat == R04VideoToolboxRouteCatalog.pixelFormat
            && configuration.configurationIdentity == route.configurationIdentity
    }

    private func rejected(
        _ reason: R04VideoToolboxRouteRejectionReason
    ) -> AppleUpscaleSessionCreationOutcome {
        guard let value = rejections[reason] else {
            preconditionFailure("Every R04 route rejection is constructed at initialization")
        }
        return .rejected(value)
    }

    private func unavailableOutcome(
        _ reason: R04VideoToolboxRouteUnavailableReason
    ) -> AppleUpscaleSessionCreationOutcome {
        guard let value = unavailable[reason] else {
            preconditionFailure("Every R04 unavailability is constructed at initialization")
        }
        return .unavailable(value)
    }

    private func failed(
        _ reason: R04VideoToolboxRouteFailureReason
    ) -> AppleUpscaleSessionCreationOutcome {
        guard let value = failures[reason] else {
            preconditionFailure("Every R04 failure is constructed at initialization")
        }
        return .failed(value)
    }
}

// The actor owns the complete FIFO temporal state machine and its typed outcomes.
// swiftlint:disable:next type_body_length
private actor R04VideoToolboxSessionDriver: AppleUpscaleSessionDriver {
    private let route: R04VideoToolboxRouteDescriptor
    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let diagnostics: R04VideoToolboxConfigurationDiagnostics
    private let runtime: any R04VideoToolboxRuntime
    private let opticalFlowProvider: R04VideoToolboxOpticalFlowProvider
    private let historyBufferCopier: any R04VideoToolboxHistoryBufferCopying
    private let rejections: [
        R04VideoToolboxRouteRejectionReason: AppleUpscaleBackendRejected
    ]
    private let unavailable: [
        R04VideoToolboxRouteUnavailableReason: AppleUpscaleBackendUnavailable
    ]
    private let failures: [
        R04VideoToolboxRouteFailureReason: AppleUpscaleBackendFailed
    ]

    private var previousSource: R04VideoToolboxHistoryFrame?
    private var previousOutput: R04VideoToolboxHistoryFrame?
    private var acceptedHistoryGeneration: UInt64?
    private var resetSatisfiedGeneration: UInt64?

    init(
        route: R04VideoToolboxRouteDescriptor,
        routeIdentity: AppleUpscaleRouteIdentity,
        diagnostics: R04VideoToolboxConfigurationDiagnostics,
        runtime: any R04VideoToolboxRuntime,
        opticalFlowProvider: @escaping R04VideoToolboxOpticalFlowProvider,
        historyBufferCopier: any R04VideoToolboxHistoryBufferCopying
    ) throws {
        self.route = route
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: routeIdentity,
            fallbackHistory: []
        )
        self.processingIdentity = processingIdentity
        self.diagnostics = diagnostics
        self.runtime = runtime
        self.opticalFlowProvider = opticalFlowProvider
        self.historyBufferCopier = historyBufferCopier
        rejections = try Dictionary(
            uniqueKeysWithValues: R04VideoToolboxRouteRejectionReason.allCases.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendRejected(
                        processingIdentity: processingIdentity,
                        reason: reason.rawValue
                    )
                )
            }
        )
        unavailable = try Dictionary(
            uniqueKeysWithValues: R04VideoToolboxRouteUnavailableReason.allCases.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendUnavailable(
                        processingIdentity: processingIdentity,
                        reason: reason.rawValue
                    )
                )
            }
        )
        failures = try Dictionary(
            uniqueKeysWithValues: R04VideoToolboxRouteFailureReason.allCases.map { reason in
                (
                    reason,
                    try AppleUpscaleBackendFailed(
                        processingIdentity: processingIdentity,
                        reason: reason.rawValue
                    )
                )
            }
        )
    }

    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard !cancellation.isCancelled else {
            return rejected(.operationCancelled)
        }
        guard R04VideoToolboxMediaContract.matches(
            frame: frame,
            resolution: route.sourceResolution
        ) else {
            return rejected(.frameContractMismatch)
        }

        let transition = prepareHistory(
            for: frame,
            generation: historyGeneration
        )
        let historyBoundary = transition.boundary
        if let resetCause = transition.resetCause {
            await runtime.reset(
                R04VideoToolboxResetRequest(
                    route: route,
                    cause: resetCause,
                    historyGeneration: historyGeneration
                ),
                cancellation: cancellation
            )
            guard !cancellation.isCancelled else {
                return rejected(.operationCancelled)
            }
            resetSatisfiedGeneration = historyGeneration
        }

        let suppliedPreviousSource = route.temporalPolicy.suppliesPreviousSource
            ? previousSource
            : nil
        let suppliedPreviousOutput = route.temporalPolicy.suppliesPreviousOutput
            ? previousOutput
            : nil
        let flowMode: R04VideoToolboxOpticalFlowMode
        if route.opticalFlowRole == .optionalQualityInput {
            flowMode = await opticalFlowProvider(suppliedPreviousSource, frame)
        } else {
            flowMode = .disabled
        }
        guard !cancellation.isCancelled else {
            return rejected(.operationCancelled)
        }
        guard flowModeIsCompatible(flowMode) else {
            return rejected(.configurationIdentityMismatch)
        }

        let request = R04VideoToolboxProcessingRequest(
            route: route,
            sourceFrame: frame,
            previousSource: suppliedPreviousSource,
            previousOutput: suppliedPreviousOutput,
            historyGeneration: historyGeneration,
            historyBoundary: historyBoundary,
            submissionMode: route.temporalPolicy.submissionMode(
                for: historyBoundary
            ),
            opticalFlowMode: flowMode
        )
        let outcome = await runtime.process(request, cancellation: cancellation)
        if cancellation.isCancelled {
            if case .processed(let output) = outcome {
                output.releaseAction()
            }
            return rejected(.operationCancelled)
        }

        switch outcome {
        case .processed(let output):
            return makeProcessed(
                output,
                source: frame,
                historyGeneration: historyGeneration
            )
        case .unavailable(let reason):
            return unavailableOutcome(reason)
        case .rejected(let reason):
            return rejected(reason)
        case .failed(let reason):
            return failed(reason)
        }
    }

    func reset(
        reason: AppleUpscaleResetReason,
        nextHistoryGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async {
        clearHistory()
        await runtime.reset(
            R04VideoToolboxResetRequest(
                route: route,
                cause: .session(reason),
                historyGeneration: nextHistoryGeneration
            ),
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else { return }
        acceptedHistoryGeneration = nextHistoryGeneration
        resetSatisfiedGeneration = nextHistoryGeneration
    }

    func finish() async {
        clearHistory()
        await runtime.finish()
    }

    func cancel() async {
        clearHistory()
        await runtime.cancel()
    }

    private struct HistoryTransition {
        let boundary: R04VideoToolboxHistoryBoundary
        let resetCause: R04VideoToolboxResetCause?
    }

    private func prepareHistory(
        for frame: AppleUpscaleFrame,
        generation: UInt64
    ) -> HistoryTransition {
        guard route.backendKind == .quality else {
            clearHistory()
            acceptedHistoryGeneration = generation
            return HistoryTransition(boundary: .notApplicable, resetCause: nil)
        }
        guard acceptedHistoryGeneration == generation else {
            clearHistory()
            acceptedHistoryGeneration = generation
            resetSatisfiedGeneration = nil
            return firstFrameTransition(generation: generation)
        }
        guard let previousSource, previousOutput != nil else {
            return firstFrameTransition(generation: generation)
        }
        guard isContiguous(previous: previousSource, current: frame) else {
            clearHistory()
            resetSatisfiedGeneration = nil
            return HistoryTransition(
                boundary: .firstFrame,
                resetCause: .detectedDiscontinuity
            )
        }
        return HistoryTransition(boundary: .continuing, resetCause: nil)
    }

    private func firstFrameTransition(
        generation: UInt64
    ) -> HistoryTransition {
        let requiresReset = route.temporalPolicy.resetsOnFirstFrame
            && resetSatisfiedGeneration != generation
        return HistoryTransition(
            boundary: .firstFrame,
            resetCause: requiresReset ? .firstFrame : nil
        )
    }

    private func isContiguous(
        previous: R04VideoToolboxHistoryFrame,
        current: AppleUpscaleFrame
    ) -> Bool {
        guard previous.sequenceNumber < Int.max,
              current.sequenceNumber == previous.sequenceNumber + 1,
              current.duration == previous.duration else {
            return false
        }
        let expectedTimestamp = CMTimeAdd(
            previous.presentationTimestamp,
            previous.duration
        )
        return CMTimeCompare(current.presentationTimestamp, expectedTimestamp) == 0
    }

    private func flowModeIsCompatible(
        _ mode: R04VideoToolboxOpticalFlowMode
    ) -> Bool {
        guard case .quality(let configuration) = diagnostics.nativeIdentity else {
            if case .disabled = mode { return true }
            return false
        }
        switch mode {
        case .disabled:
            return !configuration.usesPrecomputedFlow
        case .appleComputed:
            return !configuration.usesPrecomputedFlow
        case .precomputed:
            return configuration.usesPrecomputedFlow
        }
    }

    private func makeProcessed(
        _ output: R04VideoToolboxRuntimeOutput,
        source: AppleUpscaleFrame,
        historyGeneration: UInt64
    ) -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard R04VideoToolboxMediaContract.matches(
            pixelBuffer: output.pixelBuffer,
            resolution: route.targetResolution
        ) else {
            output.releaseAction()
            return failed(.outputContractMismatch)
        }

        let ownedHistory: (
            source: R04VideoToolboxHistoryFrame,
            output: R04VideoToolboxHistoryFrame
        )?
        if route.backendKind == .quality {
            do {
                let sourceCopy = try historyBufferCopier.makeOwnedCopy(
                    of: source.pixelBuffer,
                    resolution: route.sourceResolution
                )
                let outputCopy = try historyBufferCopier.makeOwnedCopy(
                    of: output.pixelBuffer,
                    resolution: route.targetResolution
                )
                ownedHistory = (
                    R04VideoToolboxHistoryFrame(
                        sequenceNumber: source.sequenceNumber,
                        pixelBuffer: sourceCopy,
                        presentationTimestamp: source.presentationTimestamp,
                        duration: source.duration
                    ),
                    R04VideoToolboxHistoryFrame(
                        sequenceNumber: source.sequenceNumber,
                        pixelBuffer: outputCopy,
                        presentationTimestamp: source.presentationTimestamp,
                        duration: source.duration
                    )
                )
            } catch {
                output.releaseAction()
                return failed(.runtimeProcessingFailed)
            }
        } else {
            ownedHistory = nil
        }

        let tokenIdentity = "\(route.subjectID.rawValue).output.\(source.sequenceNumber).g\(historyGeneration)"
        do {
            let token = try AppleUpscaleResourceLifetimeToken(
                identity: tokenIdentity,
                releaseAction: output.releaseAction
            )
            do {
                let processed = try AppleUpscaleProcessedFrame(
                    sequenceNumber: source.sequenceNumber,
                    pixelBuffer: output.pixelBuffer,
                    presentationTimestamp: source.presentationTimestamp,
                    duration: source.duration,
                    colorDescription: source.colorDescription,
                    metadataIdentity: source.metadataIdentity,
                    resourceLifetimeToken: token,
                    processingIdentity: processingIdentity
                )
                if let ownedHistory {
                    previousSource = ownedHistory.source
                    previousOutput = ownedHistory.output
                    acceptedHistoryGeneration = historyGeneration
                }
                return .processed(processed)
            } catch {
                token.release()
                return failed(.runtimeProcessingFailed)
            }
        } catch {
            output.releaseAction()
            return failed(.runtimeProcessingFailed)
        }
    }

    private func clearHistory() {
        previousSource = nil
        previousOutput = nil
    }

    private func rejected(
        _ reason: R04VideoToolboxRouteRejectionReason
    ) -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard let value = rejections[reason] else {
            preconditionFailure("Every R04 rejection is constructed at initialization")
        }
        return .rejected(value)
    }

    private func unavailableOutcome(
        _ reason: R04VideoToolboxRouteUnavailableReason
    ) -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard let value = unavailable[reason] else {
            preconditionFailure("Every R04 unavailability is constructed at initialization")
        }
        return .unavailable(value)
    }

    private func failed(
        _ reason: R04VideoToolboxRouteFailureReason
    ) -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        guard let value = failures[reason] else {
            preconditionFailure("Every R04 failure is constructed at initialization")
        }
        return .failed(value)
    }
}

enum R04VideoToolboxHistoryCopyError: Error, Equatable, Sendable {
    case sourceContractMismatch
    case allocationFailed(CVReturn)
    case destinationNotIOSurfaceBacked
    case sourceLockFailed(CVReturn)
    case destinationLockFailed(CVReturn)
    case missingPlaneBaseAddress(Int)
}

struct R04VideoToolboxNV12HistoryBufferCopier:
    R04VideoToolboxHistoryBufferCopying {
    func makeOwnedCopy(
        of source: CVPixelBuffer,
        resolution: VideoResolution
    ) throws -> CVPixelBuffer {
        guard R04VideoToolboxMediaContract.matches(
            pixelBuffer: source,
            resolution: resolution
        ) else {
            throw R04VideoToolboxHistoryCopyError.sourceContractMismatch
        }
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var destination: CVPixelBuffer?
        let allocationStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            resolution.width,
            resolution.height,
            R04VideoToolboxRouteCatalog.pixelFormat,
            attributes as CFDictionary,
            &destination
        )
        guard allocationStatus == kCVReturnSuccess, let destination else {
            throw R04VideoToolboxHistoryCopyError.allocationFailed(allocationStatus)
        }
        guard CVPixelBufferGetIOSurface(destination) != nil else {
            throw R04VideoToolboxHistoryCopyError.destinationNotIOSurfaceBacked
        }

        let sourceLockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockStatus == kCVReturnSuccess else {
            throw R04VideoToolboxHistoryCopyError.sourceLockFailed(sourceLockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let destinationLockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            throw R04VideoToolboxHistoryCopyError.destinationLockFailed(
                destinationLockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        for plane in 0..<2 {
            guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                      destination,
                      plane
                  ) else {
                throw R04VideoToolboxHistoryCopyError.missingPlaneBaseAddress(plane)
            }
            let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(
                destination,
                plane
            )
            let rowCount = CVPixelBufferGetHeightOfPlane(source, plane)
            let bytesPerRow = min(sourceStride, destinationStride)
            for row in 0..<rowCount {
                memcpy(
                    destinationBase.advanced(by: row * destinationStride),
                    sourceBase.advanced(by: row * sourceStride),
                    bytesPerRow
                )
            }
        }
        R04VideoToolboxMediaContract.installColorAttachments(on: destination)
        return destination
    }
}

private enum R04VideoToolboxMediaContract {
    static func matches(
        frame: AppleUpscaleFrame,
        resolution: VideoResolution
    ) -> Bool {
        matches(colorDescription: frame.colorDescription)
            && matches(pixelBuffer: frame.pixelBuffer, resolution: resolution)
    }

    static func matches(
        pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution
    ) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == R04VideoToolboxRouteCatalog.pixelFormat,
              CVPixelBufferGetWidth(pixelBuffer) == resolution.width,
              CVPixelBufferGetHeight(pixelBuffer) == resolution.height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == resolution.width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == resolution.height,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) == resolution.width / 2,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) == resolution.height / 2 else {
            return false
        }
        return expectedAttachments.allSatisfy { key, value in
            CVBufferCopyAttachment(pixelBuffer, key, nil) as? String == value as String
        }
    }

    static func installColorAttachments(on pixelBuffer: CVPixelBuffer) {
        for (key, value) in expectedAttachments {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
    }

    private static func matches(
        colorDescription: AppleUpscaleColorDescription
    ) -> Bool {
        colorDescription.colorPrimaries
                == kCVImageBufferColorPrimaries_ITU_R_709_2 as String
            && colorDescription.transferFunction
                == kCVImageBufferTransferFunction_ITU_R_709_2 as String
            && colorDescription.matrix
                == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
            && colorDescription.chromaSiting
                == kCVImageBufferChromaLocation_Left as String
            && colorDescription.range == .video
    }

    private static var expectedAttachments: [(CFString, CFString)] {
        [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
        ]
    }
}

private extension R04VideoToolboxRouteRejectionReason {
    static var allCases: [R04VideoToolboxRouteRejectionReason] {
        [
            .publicContractUnrepresentable,
            .exactDimensionQueryRejected,
            .sessionContractMismatch,
            .productScopeForbidden,
            .productQualificationRequired,
            .optionalSupportOnly,
            .frameContractMismatch,
            .operationCancelled,
            .runtimeRejected,
            .configurationIdentityMismatch,
            .supportedPixelFormatRejected
        ]
    }
}

private extension R04VideoToolboxRouteUnavailableReason {
    static var allCases: [R04VideoToolboxRouteUnavailableReason] {
        [
            .capabilityNotObserved,
            .capabilityUnavailable,
            .runtimeSupportNotObserved,
            .runtimeSupportUnavailable,
            .optionalSupportUnavailable,
            .runtimeUnavailable,
            .configurationDiagnosticsNotObserved,
            .modelNotReady
        ]
    }
}

private extension R04VideoToolboxRouteFailureReason {
    static var allCases: [R04VideoToolboxRouteFailureReason] {
        [
            .runtimeConstructionFailed,
            .runtimeProcessingFailed,
            .outputContractMismatch
        ]
    }
}

// swiftlint:enable file_length
