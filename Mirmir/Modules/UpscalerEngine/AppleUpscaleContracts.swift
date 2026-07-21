// swiftlint:disable file_length

import CoreMedia
import CoreVideo
import Foundation

enum AppleUpscaleContractError: Error, Equatable, Sendable {
    case emptyIdentityField(String)
    case duplicateCapabilityID(String)
    case invalidCapabilityQualification(String)
    case invalidArtifactSHA256(String)
    case duplicateArtifactIdentity(String)
    case emptyBoundModelAssets
    case invalidDimensions(width: Int, height: Int)
    case invalidFrameSequenceNumber(Int)
    case invalidPresentationTimestamp
    case invalidDuration
    case invalidFallbackOrdinal(expected: Int, actual: Int)
    case repeatedFallbackRoute(String)
    case fallbackChainDiscontinuity(index: Int)
    case fallbackTerminalRouteMismatch
}

struct AppleUpscaleCapabilityID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        self.rawValue = try requireAppleUpscaleIdentity(
            rawValue,
            field: "capability_id"
        )
    }
}

enum AppleUpscaleCapabilityRole: String, Hashable, Sendable {
    case primaryScaler = "primary_scaler"
    case supportFilter = "support_filter"
    case temporalAnalyzer = "temporal_analyzer"
    case cadenceTransform = "cadence_transform"
    case analysisRuntime = "analysis_runtime"
}

enum AppleUpscaleCapabilityObservationStatus: String, Hashable, Sendable {
    case notObserved = "not_observed"
    case observed
}

enum AppleUpscaleRuntimeDisposition: String, Hashable, Sendable {
    case diagnosticOnly = "diagnostic_only"
    case unavailable
    case runnable
}

enum AppleUpscaleBackendEligibility: String, Hashable, Sendable {
    case notEvaluated = "not_evaluated"
    case fixtureOnly = "fixture_only"
    case productQualified = "product_qualified"
}

enum AppleUpscaleAdmissionScope: String, Hashable, Sendable {
    case fixtureOnly = "fixture_only"
    case product
}

struct AppleUpscaleCapability: Hashable, Sendable {
    let id: AppleUpscaleCapabilityID
    let role: AppleUpscaleCapabilityRole
    let frameworkIdentity: String
    let observationStatus: AppleUpscaleCapabilityObservationStatus
    let runtimeDisposition: AppleUpscaleRuntimeDisposition
    let backendEligibility: AppleUpscaleBackendEligibility

    init(
        id: AppleUpscaleCapabilityID,
        role: AppleUpscaleCapabilityRole,
        frameworkIdentity: String,
        observationStatus: AppleUpscaleCapabilityObservationStatus,
        runtimeDisposition: AppleUpscaleRuntimeDisposition,
        backendEligibility: AppleUpscaleBackendEligibility
    ) throws {
        let frameworkIdentity = try requireAppleUpscaleIdentity(
            frameworkIdentity,
            field: "framework_identity"
        )
        if observationStatus == .notObserved,
           runtimeDisposition != .diagnosticOnly || backendEligibility != .notEvaluated {
            throw AppleUpscaleContractError.invalidCapabilityQualification(id.rawValue)
        }
        if backendEligibility == .fixtureOnly,
           observationStatus != .observed || runtimeDisposition != .runnable {
            throw AppleUpscaleContractError.invalidCapabilityQualification(id.rawValue)
        }
        if backendEligibility == .productQualified,
           observationStatus != .observed || runtimeDisposition != .runnable {
            throw AppleUpscaleContractError.invalidCapabilityQualification(id.rawValue)
        }

        self.id = id
        self.role = role
        self.frameworkIdentity = frameworkIdentity
        self.observationStatus = observationStatus
        self.runtimeDisposition = runtimeDisposition
        self.backendEligibility = backendEligibility
    }

    func isEligible(for scope: AppleUpscaleAdmissionScope) -> Bool {
        switch scope {
        case .fixtureOnly:
            return backendEligibility == .fixtureOnly
        case .product:
            return backendEligibility == .productQualified
        }
    }
}

struct AppleUpscaleCapabilityRegistry: Sendable {
    let capabilities: [AppleUpscaleCapability]
    private let capabilityIndex: [AppleUpscaleCapabilityID: AppleUpscaleCapability]

    init(capabilities: [AppleUpscaleCapability]) throws {
        var index: [AppleUpscaleCapabilityID: AppleUpscaleCapability] = [:]
        for capability in capabilities {
            guard index.updateValue(capability, forKey: capability.id) == nil else {
                throw AppleUpscaleContractError.duplicateCapabilityID(
                    capability.id.rawValue
                )
            }
        }
        self.capabilities = capabilities
        self.capabilityIndex = index
    }

    func capability(for id: AppleUpscaleCapabilityID) -> AppleUpscaleCapability? {
        capabilityIndex[id]
    }
}

struct AppleUpscaleArtifactIdentity: Hashable, Sendable {
    let identifier: String
    let sha256: String

    init(identifier: String, sha256: String) throws {
        self.identifier = try requireAppleUpscaleIdentity(
            identifier,
            field: "artifact_identifier"
        )
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ byte in
                  (48...57).contains(Int(byte)) || (97...102).contains(Int(byte))
              }) else {
            throw AppleUpscaleContractError.invalidArtifactSHA256(identifier)
        }
        self.sha256 = sha256
    }
}

enum AppleUpscaleModelAssetsIdentity: Hashable, Sendable {
    case notRequired
    case bound([AppleUpscaleArtifactIdentity])
}

struct AppleUpscaleBackendIdentity: Hashable, Sendable {
    let backendID: String
    let backendRevision: String
    let modelAssetsIdentity: AppleUpscaleModelAssetsIdentity

    init(
        backendID: String,
        backendRevision: String,
        modelAssetsIdentity: AppleUpscaleModelAssetsIdentity
    ) throws {
        self.backendID = try requireAppleUpscaleIdentity(
            backendID,
            field: "backend_id"
        )
        self.backendRevision = try requireAppleUpscaleIdentity(
            backendRevision,
            field: "backend_revision"
        )
        if case .bound(let artifacts) = modelAssetsIdentity {
            guard !artifacts.isEmpty else {
                throw AppleUpscaleContractError.emptyBoundModelAssets
            }
            guard Set(artifacts.map(\.identifier)).count == artifacts.count else {
                throw AppleUpscaleContractError.duplicateArtifactIdentity(backendID)
            }
        }
        self.modelAssetsIdentity = modelAssetsIdentity
    }
}

struct AppleUpscaleRouteIdentity: Hashable, Sendable {
    let backend: AppleUpscaleBackendIdentity
    let configurationIdentity: String
    let policyIdentity: String
    let materialDecisionIdentity: String

    init(
        backend: AppleUpscaleBackendIdentity,
        configurationIdentity: String,
        policyIdentity: String,
        materialDecisionIdentity: String
    ) throws {
        self.backend = backend
        self.configurationIdentity = try requireAppleUpscaleIdentity(
            configurationIdentity,
            field: "configuration_identity"
        )
        self.policyIdentity = try requireAppleUpscaleIdentity(
            policyIdentity,
            field: "policy_identity"
        )
        self.materialDecisionIdentity = try requireAppleUpscaleIdentity(
            materialDecisionIdentity,
            field: "material_decision_identity"
        )
    }
}

enum AppleUpscaleFallbackReasonCode: String, Hashable, Sendable {
    case backendUnavailable = "backend_unavailable"
    case backendRejected = "backend_rejected"
    case backendFailed = "backend_failed"
}

struct AppleUpscaleFallbackLink: Hashable, Sendable {
    let failedRoute: AppleUpscaleRouteIdentity
    let selectedRoute: AppleUpscaleRouteIdentity
    let reasonCode: AppleUpscaleFallbackReasonCode
    let selectedFallbackOrdinal: Int

    init(
        failedRoute: AppleUpscaleRouteIdentity,
        selectedRoute: AppleUpscaleRouteIdentity,
        reasonCode: AppleUpscaleFallbackReasonCode,
        selectedFallbackOrdinal: Int
    ) throws {
        guard selectedFallbackOrdinal >= 0 else {
            throw AppleUpscaleContractError.invalidFallbackOrdinal(
                expected: 0,
                actual: selectedFallbackOrdinal
            )
        }
        guard failedRoute != selectedRoute else {
            throw AppleUpscaleContractError.repeatedFallbackRoute(
                failedRoute.backend.backendID
            )
        }
        self.failedRoute = failedRoute
        self.selectedRoute = selectedRoute
        self.reasonCode = reasonCode
        self.selectedFallbackOrdinal = selectedFallbackOrdinal
    }
}

struct AppleUpscaleProcessingIdentity: Hashable, Sendable {
    let route: AppleUpscaleRouteIdentity
    let fallbackHistory: [AppleUpscaleFallbackLink]

    init(
        route: AppleUpscaleRouteIdentity,
        fallbackHistory: [AppleUpscaleFallbackLink]
    ) throws {
        var visitedRoutes: Set<AppleUpscaleRouteIdentity> = []
        for (index, link) in fallbackHistory.enumerated() {
            guard link.selectedFallbackOrdinal == index else {
                throw AppleUpscaleContractError.invalidFallbackOrdinal(
                    expected: index,
                    actual: link.selectedFallbackOrdinal
                )
            }
            if index > 0,
               fallbackHistory[index - 1].selectedRoute != link.failedRoute {
                throw AppleUpscaleContractError.fallbackChainDiscontinuity(index: index)
            }
            guard visitedRoutes.insert(link.failedRoute).inserted,
                  !visitedRoutes.contains(link.selectedRoute) else {
                throw AppleUpscaleContractError.repeatedFallbackRoute(
                    link.selectedRoute.backend.backendID
                )
            }
        }
        if let selectedRoute = fallbackHistory.last?.selectedRoute,
           selectedRoute != route {
            throw AppleUpscaleContractError.fallbackTerminalRouteMismatch
        }
        self.route = route
        self.fallbackHistory = fallbackHistory
    }
}

enum AppleUpscaleColorRange: String, Hashable, Sendable {
    case video
    case full
}

struct AppleUpscaleColorDescription: Hashable, Sendable {
    let colorPrimaries: String
    let transferFunction: String
    let matrix: String
    let chromaSiting: String
    let range: AppleUpscaleColorRange

    init(
        colorPrimaries: String,
        transferFunction: String,
        matrix: String,
        chromaSiting: String,
        range: AppleUpscaleColorRange
    ) throws {
        self.colorPrimaries = try requireAppleUpscaleIdentity(
            colorPrimaries,
            field: "color_primaries"
        )
        self.transferFunction = try requireAppleUpscaleIdentity(
            transferFunction,
            field: "transfer_function"
        )
        self.matrix = try requireAppleUpscaleIdentity(matrix, field: "matrix")
        self.chromaSiting = try requireAppleUpscaleIdentity(
            chromaSiting,
            field: "chroma_siting"
        )
        self.range = range
    }
}

struct AppleUpscaleMetadataIdentity: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        self.rawValue = try requireAppleUpscaleIdentity(
            rawValue,
            field: "metadata_identity"
        )
    }
}

final class AppleUpscaleResourceLifetimeToken: @unchecked Sendable {
    let identity: String

    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(
        identity: String,
        releaseAction: @escaping @Sendable () -> Void
    ) throws {
        self.identity = try requireAppleUpscaleIdentity(
            identity,
            field: "resource_lifetime_token"
        )
        self.releaseAction = releaseAction
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return releaseAction == nil
    }

    func release() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        release()
    }
}

struct AppleUpscaleFrame: @unchecked Sendable {
    let sequenceNumber: Int
    let pixelBuffer: CVPixelBuffer
    let presentationTimestamp: CMTime
    let duration: CMTime
    let colorDescription: AppleUpscaleColorDescription
    let metadataIdentity: AppleUpscaleMetadataIdentity
    let resourceLifetimeToken: AppleUpscaleResourceLifetimeToken

    init(
        sequenceNumber: Int,
        pixelBuffer: CVPixelBuffer,
        presentationTimestamp: CMTime,
        duration: CMTime,
        colorDescription: AppleUpscaleColorDescription,
        metadataIdentity: AppleUpscaleMetadataIdentity,
        resourceLifetimeToken: AppleUpscaleResourceLifetimeToken
    ) throws {
        try validateAppleUpscaleFrameTiming(
            sequenceNumber: sequenceNumber,
            presentationTimestamp: presentationTimestamp,
            duration: duration
        )
        self.sequenceNumber = sequenceNumber
        self.pixelBuffer = pixelBuffer
        self.presentationTimestamp = presentationTimestamp
        self.duration = duration
        self.colorDescription = colorDescription
        self.metadataIdentity = metadataIdentity
        self.resourceLifetimeToken = resourceLifetimeToken
    }
}

struct AppleUpscaleProcessedFrame: @unchecked Sendable {
    let sequenceNumber: Int
    let pixelBuffer: CVPixelBuffer
    let presentationTimestamp: CMTime
    let duration: CMTime
    let colorDescription: AppleUpscaleColorDescription
    let metadataIdentity: AppleUpscaleMetadataIdentity
    let resourceLifetimeToken: AppleUpscaleResourceLifetimeToken
    let processingIdentity: AppleUpscaleProcessingIdentity

    init(
        sequenceNumber: Int,
        pixelBuffer: CVPixelBuffer,
        presentationTimestamp: CMTime,
        duration: CMTime,
        colorDescription: AppleUpscaleColorDescription,
        metadataIdentity: AppleUpscaleMetadataIdentity,
        resourceLifetimeToken: AppleUpscaleResourceLifetimeToken,
        processingIdentity: AppleUpscaleProcessingIdentity
    ) throws {
        try validateAppleUpscaleFrameTiming(
            sequenceNumber: sequenceNumber,
            presentationTimestamp: presentationTimestamp,
            duration: duration
        )
        self.sequenceNumber = sequenceNumber
        self.pixelBuffer = pixelBuffer
        self.presentationTimestamp = presentationTimestamp
        self.duration = duration
        self.colorDescription = colorDescription
        self.metadataIdentity = metadataIdentity
        self.resourceLifetimeToken = resourceLifetimeToken
        self.processingIdentity = processingIdentity
    }
}

struct AppleUpscaleBackendUnavailable: Error, Hashable, Sendable {
    let processingIdentity: AppleUpscaleProcessingIdentity
    let reason: String

    var route: AppleUpscaleRouteIdentity {
        processingIdentity.route
    }

    init(
        processingIdentity: AppleUpscaleProcessingIdentity,
        reason: String
    ) throws {
        self.processingIdentity = processingIdentity
        self.reason = try requireAppleUpscaleIdentity(reason, field: "unavailable_reason")
    }
}

struct AppleUpscaleBackendRejected: Error, Hashable, Sendable {
    let processingIdentity: AppleUpscaleProcessingIdentity
    let reason: String

    var route: AppleUpscaleRouteIdentity {
        processingIdentity.route
    }

    init(
        processingIdentity: AppleUpscaleProcessingIdentity,
        reason: String
    ) throws {
        self.processingIdentity = processingIdentity
        self.reason = try requireAppleUpscaleIdentity(reason, field: "rejection_reason")
    }
}

struct AppleUpscaleBackendFailed: Error, Hashable, Sendable {
    let processingIdentity: AppleUpscaleProcessingIdentity
    let reason: String

    var route: AppleUpscaleRouteIdentity {
        processingIdentity.route
    }

    init(
        processingIdentity: AppleUpscaleProcessingIdentity,
        reason: String
    ) throws {
        self.processingIdentity = processingIdentity
        self.reason = try requireAppleUpscaleIdentity(reason, field: "failure_reason")
    }
}

struct AppleUpscaleFallbackApplied: Sendable {
    let processedFrame: AppleUpscaleProcessedFrame

    init(processedFrame: AppleUpscaleProcessedFrame) throws {
        guard !processedFrame.processingIdentity.fallbackHistory.isEmpty else {
            throw AppleUpscaleContractError.fallbackTerminalRouteMismatch
        }
        self.processedFrame = processedFrame
    }
}

enum AppleUpscaleBackendOutcome<Output: Sendable>: Sendable {
    case processed(Output)
    case unavailable(AppleUpscaleBackendUnavailable)
    case rejected(AppleUpscaleBackendRejected)
    case failed(AppleUpscaleBackendFailed)
}

enum AppleUpscaleOutcome: Sendable {
    case processed(AppleUpscaleProcessedFrame)
    case unavailable(AppleUpscaleBackendUnavailable)
    case rejected(AppleUpscaleBackendRejected)
    case failed(AppleUpscaleBackendFailed)
    case fallbackApplied(AppleUpscaleFallbackApplied)
}

enum AppleUpscaleSessionCreationOutcome: Sendable {
    case created(any AppleUpscaleSession)
    case unavailable(AppleUpscaleBackendUnavailable)
    case rejected(AppleUpscaleBackendRejected)
    case failed(AppleUpscaleBackendFailed)
}

struct AppleUpscaleSessionConfiguration: Hashable, Sendable {
    let capabilityID: AppleUpscaleCapabilityID
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let pixelFormat: OSType
    let configurationIdentity: String

    init(
        capabilityID: AppleUpscaleCapabilityID,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        pixelFormat: OSType,
        configurationIdentity: String
    ) throws {
        try validateAppleUpscaleDimensions(sourceResolution)
        try validateAppleUpscaleDimensions(targetResolution)
        self.capabilityID = capabilityID
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.pixelFormat = pixelFormat
        self.configurationIdentity = try requireAppleUpscaleIdentity(
            configurationIdentity,
            field: "configuration_identity"
        )
    }
}

struct AppleUpscaleSessionContext: Sendable {
    let capabilityRegistry: AppleUpscaleCapabilityRegistry
    let admissionScope: AppleUpscaleAdmissionScope
    let policyIdentity: String

    init(
        capabilityRegistry: AppleUpscaleCapabilityRegistry,
        admissionScope: AppleUpscaleAdmissionScope,
        policyIdentity: String
    ) throws {
        self.capabilityRegistry = capabilityRegistry
        self.admissionScope = admissionScope
        self.policyIdentity = try requireAppleUpscaleIdentity(
            policyIdentity,
            field: "policy_identity"
        )
    }
}

enum AppleUpscaleResetReason: String, Hashable, Sendable {
    case sceneCut = "scene_cut"
    case discontinuity
    case callerRequested = "caller_requested"
}

struct AppleUpscaleSessionSummary: Hashable, Sendable {
    let submittedFrameCount: Int
    let processedFrameCount: Int
    let terminalizationCount: Int
}

protocol AppleUpscaleBackend: AnyObject, Sendable {
    var identity: AppleUpscaleBackendIdentity { get }
    var capabilityID: AppleUpscaleCapabilityID { get }

    func makeSession(
        configuration: AppleUpscaleSessionConfiguration,
        context: AppleUpscaleSessionContext
    ) async -> AppleUpscaleSessionCreationOutcome
}

extension AppleUpscaleBackend {
    func capability(
        in registry: AppleUpscaleCapabilityRegistry
    ) -> AppleUpscaleCapability? {
        registry.capability(for: capabilityID)
    }
}

protocol AppleUpscaleSession: Actor {
    var identity: AppleUpscaleRouteIdentity { get }

    func submit(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
    func reset(reason: AppleUpscaleResetReason) async
    func finish() async -> AppleUpscaleSessionSummary
    func cancel() async
}

func requireAppleUpscaleIdentity(
    _ value: String,
    field: String
) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value else {
        throw AppleUpscaleContractError.emptyIdentityField(field)
    }
    return value
}

private func validateAppleUpscaleDimensions(_ resolution: VideoResolution) throws {
    guard resolution.width > 0, resolution.height > 0 else {
        throw AppleUpscaleContractError.invalidDimensions(
            width: resolution.width,
            height: resolution.height
        )
    }
}

private func validateAppleUpscaleFrameTiming(
    sequenceNumber: Int,
    presentationTimestamp: CMTime,
    duration: CMTime
) throws {
    guard sequenceNumber >= 0 else {
        throw AppleUpscaleContractError.invalidFrameSequenceNumber(sequenceNumber)
    }
    guard presentationTimestamp.isValid, presentationTimestamp.isNumeric else {
        throw AppleUpscaleContractError.invalidPresentationTimestamp
    }
    guard duration.isValid,
          duration.isNumeric,
          CMTimeCompare(duration, .zero) > 0 else {
        throw AppleUpscaleContractError.invalidDuration
    }
}

// swiftlint:enable file_length
