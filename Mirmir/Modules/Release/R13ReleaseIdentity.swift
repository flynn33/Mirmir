import CryptoKit
import Foundation

enum R13ReleaseIdentityError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidByteCount(field: String)
    case invalidOutputDimensions(width: Int, height: Int)
    case modeBindingMismatch
    case a11BindingMismatch(field: String)
    case releaseScalerBindingMismatch(field: String)
    case adaptiveBindingMismatch(field: String)
    case frameworkRuntimeIdentityMismatch(field: String)
    case outputRouteMismatch
    case modelAssetsMustBeNotRequired
    case fallbackHistoryMustBeEmpty
    case routingDecisionMetadataMissing
    case routingDecisionMetadataUnexpected
    case routingDecisionMetadataInvalid(field: String)
    case smoothMotionMetadataInvalid(field: String)
    case metadataKeysDiffer
    case metadataValueDiffers(key: String)
}

enum R13ReleasePolicyRouteClass:
    String,
    Codable,
    Equatable,
    Sendable {
    case canonicalProduct = "canonical_product"
    case adaptiveFormatGeometry =
        "adaptive_format_geometry"
}

enum R13ReleasePolicyModelStatus:
    String,
    Codable,
    Equatable,
    Sendable {
    case notRequired = "not_required"
    case runtimeSelected = "runtime_selected"
}

enum R13ReleasePolicyFallbackSemantics:
    String,
    Codable,
    Equatable,
    Sendable {
    case forbidden
    case runtimeSelectedOrderedFailover =
        "runtime_selected_ordered_failover"
}

enum R13ReleaseRoutePolicyClaimError:
    Error,
    Equatable,
    Sendable {
    case modelStatusMismatch(
        routeClass: R13ReleasePolicyRouteClass,
        expected: R13ReleasePolicyModelStatus,
        actual: R13ReleasePolicyModelStatus
    )
    case fallbackSemanticsMismatch(
        routeClass: R13ReleasePolicyRouteClass,
        expected: R13ReleasePolicyFallbackSemantics,
        actual: R13ReleasePolicyFallbackSemantics
    )
}

struct R13ReleaseRoutePolicyClaim:
    Codable,
    Equatable,
    Sendable {
    let routeClass: R13ReleasePolicyRouteClass
    let modelStatus: R13ReleasePolicyModelStatus
    let fallbackSemantics:
        R13ReleasePolicyFallbackSemantics

    init(
        routeClass: R13ReleasePolicyRouteClass,
        binding: R13ReleaseModeBinding,
        modelStatus: R13ReleasePolicyModelStatus,
        fallbackSemantics:
            R13ReleasePolicyFallbackSemantics
    ) throws {
        let expected = Self.canonical(
            routeClass: routeClass,
            binding: binding
        )
        guard modelStatus == expected.modelStatus else {
            throw R13ReleaseRoutePolicyClaimError
                .modelStatusMismatch(
                    routeClass: routeClass,
                    expected: expected.modelStatus,
                    actual: modelStatus
                )
        }
        guard fallbackSemantics
                == expected.fallbackSemantics else {
            throw R13ReleaseRoutePolicyClaimError
                .fallbackSemanticsMismatch(
                    routeClass: routeClass,
                    expected:
                        expected.fallbackSemantics,
                    actual: fallbackSemantics
                )
        }
        self = expected
    }

    static func canonical(
        routeClass: R13ReleasePolicyRouteClass,
        binding: R13ReleaseModeBinding
    ) -> R13ReleaseRoutePolicyClaim {
        let isOrchestrated =
            binding.usesProductOrchestration
        let isExactNative =
            binding.enginePreference.requiresNativeUpscaleSession
        let modelStatus:
            R13ReleasePolicyModelStatus
        switch routeClass {
        case .canonicalProduct:
            modelStatus = isOrchestrated
                && (!isExactNative
                    || binding.enginePreference
                        == .videoToolboxQuality)
                ? .runtimeSelected
                : .notRequired
        case .adaptiveFormatGeometry:
            modelStatus =
                binding.enginePreference == .videoToolboxQuality
                    ? .runtimeSelected
                    : .notRequired
        }
        return R13ReleaseRoutePolicyClaim(
            validatedRouteClass: routeClass,
            modelStatus: modelStatus,
            fallbackSemantics: isOrchestrated && !isExactNative
                ? .runtimeSelectedOrderedFailover
                : .forbidden
        )
    }

    private init(
        validatedRouteClass:
            R13ReleasePolicyRouteClass,
        modelStatus: R13ReleasePolicyModelStatus,
        fallbackSemantics:
            R13ReleasePolicyFallbackSemantics
    ) {
        routeClass = validatedRouteClass
        self.modelStatus = modelStatus
        self.fallbackSemantics = fallbackSemantics
    }

    private enum CodingKeys: String, CodingKey {
        case routeClass = "route_class"
        case modelStatus = "model_status"
        case fallbackSemantics = "fallback_semantics"
    }
}

struct R13ReleaseSourceBinding: Codable, Equatable, Sendable {
    let sha256: String
    let byteCount: UInt64

    init(sha256: String, byteCount: UInt64) throws {
        self.sha256 = try R13ReleaseIdentityValidation.sha256(
            sha256,
            field: "source_sha256"
        )
        guard byteCount > 0 else {
            throw R13ReleaseIdentityError.invalidByteCount(
                field: "source_byte_count"
            )
        }
        self.byteCount = byteCount
    }
}

struct R13ReleaseOutputBinding: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let codec: String
    let preserveAudio: Bool

    init(
        resolution: VideoResolution,
        codec: OutputCodec,
        preserveAudio: Bool
    ) throws {
        guard resolution.width > 0,
              resolution.height > 0,
              resolution.width <= 32_768,
              resolution.height <= 32_768 else {
            throw R13ReleaseIdentityError.invalidOutputDimensions(
                width: resolution.width,
                height: resolution.height
            )
        }
        width = resolution.width
        height = resolution.height
        self.codec = codec.rawValue
        self.preserveAudio = preserveAudio
    }

    var metadataValue: String {
        "\(width)x\(height):\(codec):audio-\(preserveAudio ? "preserved" : "omitted")"
    }
}

struct R13ReleaseApplicationIdentity: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let semanticVersion: String
    let buildVersion: String
    let executableSHA256: String
    let executableByteCount: UInt64

    init(
        bundleIdentifier: String,
        semanticVersion: String,
        buildVersion: String,
        executableSHA256: String,
        executableByteCount: UInt64
    ) throws {
        self.bundleIdentifier = try R13ReleaseIdentityValidation.identity(
            bundleIdentifier,
            field: "app_bundle_identifier"
        )
        self.semanticVersion = try R13ReleaseIdentityValidation.identity(
            semanticVersion,
            field: "app_semantic_version"
        )
        self.buildVersion = try R13ReleaseIdentityValidation.identity(
            buildVersion,
            field: "app_build_version"
        )
        self.executableSHA256 = try R13ReleaseIdentityValidation.sha256(
            executableSHA256,
            field: "app_executable_sha256"
        )
        guard executableByteCount > 0 else {
            throw R13ReleaseIdentityError.invalidByteCount(
                field: "app_executable_byte_count"
            )
        }
        self.executableByteCount = executableByteCount
    }

    var metadataValue: String {
        "\(bundleIdentifier):\(semanticVersion):\(buildVersion)"
    }
}

struct R13ReleaseFrameworkIdentity: Codable, Equatable, Sendable {
    let frameworkIdentifier: String
    let version: String
    let buildIdentity: String

    init(
        frameworkIdentifier: String,
        version: String,
        buildIdentity: String
    ) throws {
        self.frameworkIdentifier = try R13ReleaseIdentityValidation.identity(
            frameworkIdentifier,
            field: "framework_identifier"
        )
        self.version = try R13ReleaseIdentityValidation.identity(
            version,
            field: "framework_version"
        )
        self.buildIdentity = try R13ReleaseIdentityValidation.identity(
            buildIdentity,
            field: "framework_build_identity"
        )
    }

    var metadataValue: String {
        "\(frameworkIdentifier):\(version):\(buildIdentity)"
    }
}

struct R13ReleaseRuntimeIdentity: Codable, Equatable, Sendable {
    let runtimeIdentifier: String
    let version: String
    let buildIdentity: String
    let architecture: String

    init(
        runtimeIdentifier: String,
        version: String,
        buildIdentity: String,
        architecture: String
    ) throws {
        self.runtimeIdentifier = try R13ReleaseIdentityValidation.identity(
            runtimeIdentifier,
            field: "runtime_identifier"
        )
        self.version = try R13ReleaseIdentityValidation.identity(
            version,
            field: "runtime_version"
        )
        self.buildIdentity = try R13ReleaseIdentityValidation.identity(
            buildIdentity,
            field: "runtime_build_identity"
        )
        self.architecture = try R13ReleaseIdentityValidation.identity(
            architecture,
            field: "runtime_architecture"
        )
    }

    var metadataValue: String {
        "\(runtimeIdentifier):\(version):\(buildIdentity):\(architecture)"
    }
}

struct R13ReleasePolicyResourceBinding: Codable, Equatable, Sendable {
    let policySHA256: String
    let resourceManifestSHA256: String

    init(policySHA256: String, resourceManifestSHA256: String) throws {
        self.policySHA256 = try R13ReleaseIdentityValidation.sha256(
            policySHA256,
            field: "policy_sha256"
        )
        self.resourceManifestSHA256 = try R13ReleaseIdentityValidation.sha256(
            resourceManifestSHA256,
            field: "resource_manifest_sha256"
        )
    }
}

struct R13AdaptiveReleasePolicyDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let allowedRequestedModes: [String]
    let effectiveMode: String
    let capabilityID: String
    let backendID: String
    let backendRevision: String
    let routeID: String
    let configurationIdentity: String
    let frameworkIdentity: String
    let processingSourceWidth: Int
    let processingSourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let policyIdentity: String
    let materialDecisionIdentity: String
    let modelStatus: String
    let fallbackPolicy: String

    init(
        plan: R13AdaptiveScalePlan,
        modeBinding: R13ReleaseModeBinding
    ) {
        let routePolicy =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass:
                    .adaptiveFormatGeometry,
                binding: modeBinding
            )
        schemaVersion = Self.schemaVersion
        allowedRequestedModes = [modeBinding.requestedMode.rawValue]
        effectiveMode = modeBinding.effectiveMode.rawValue
        capabilityID = modeBinding.capabilityID
        backendID = modeBinding.backendID
        backendRevision = modeBinding.backendRevision
        routeID = modeBinding.adaptiveRouteID
        configurationIdentity =
            modeBinding.adaptiveConfigurationIdentity(for: plan)
        frameworkIdentity = modeBinding.frameworkIdentity
        processingSourceWidth = plan.processingSourceResolution.width
        processingSourceHeight = plan.processingSourceResolution.height
        targetWidth = plan.targetResolution.width
        targetHeight = plan.targetResolution.height
        policyIdentity = modeBinding.policyIdentity
        materialDecisionIdentity = modeBinding.materialDecisionIdentity
        modelStatus = routePolicy.modelStatus.rawValue
        fallbackPolicy =
            routePolicy.fallbackSemantics.rawValue
    }

    init(plan: R13AdaptiveScalePlan) {
        self.init(
            plan: plan,
            modeBinding: R13ReleaseModeBinding(
                requestedMode: .deterministic
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case allowedRequestedModes = "allowed_requested_modes"
        case effectiveMode = "effective_mode"
        case capabilityID = "capability_id"
        case backendID = "backend_id"
        case backendRevision = "backend_revision"
        case routeID = "route_id"
        case configurationIdentity = "configuration_identity"
        case frameworkIdentity = "framework_identity"
        case processingSourceWidth = "processing_source_width"
        case processingSourceHeight = "processing_source_height"
        case targetWidth = "target_width"
        case targetHeight = "target_height"
        case policyIdentity = "policy_identity"
        case materialDecisionIdentity = "material_decision_identity"
        case modelStatus = "model_status"
        case fallbackPolicy = "fallback_policy"
    }
}

struct R13ReleaseIdentityInput: Sendable {
    let source: R13ReleaseSourceBinding
    let modeBinding: R13ReleaseModeBinding
    let output: R13ReleaseOutputBinding
    let scalePlan: R13ReleaseScalePlan
    let routeIdentity: AppleUpscaleRouteIdentity
    let application: R13ReleaseApplicationIdentity
    let framework: R13ReleaseFrameworkIdentity
    let runtime: R13ReleaseRuntimeIdentity
    let policyResources: R13ReleasePolicyResourceBinding
    let fallbackHistory: [AppleUpscaleFallbackLink]
    let processingConfiguration: UpscaleProcessingConfiguration
    let sourceScanStructure: MediaVideoScanStructure
    let deinterlacingAlgorithmIdentity: String

    init(
        source: R13ReleaseSourceBinding,
        modeBinding: R13ReleaseModeBinding,
        output: R13ReleaseOutputBinding,
        scalePlan: R13ReleaseScalePlan,
        routeIdentity: AppleUpscaleRouteIdentity,
        application: R13ReleaseApplicationIdentity,
        framework: R13ReleaseFrameworkIdentity,
        runtime: R13ReleaseRuntimeIdentity,
        policyResources: R13ReleasePolicyResourceBinding,
        fallbackHistory: [AppleUpscaleFallbackLink],
        processingConfiguration:
            UpscaleProcessingConfiguration = .default,
        sourceScanStructure:
            MediaVideoScanStructure = .progressive,
        deinterlacingAlgorithmIdentity: String = "not_required"
    ) {
        self.source = source
        self.modeBinding = modeBinding
        self.output = output
        self.scalePlan = scalePlan
        self.routeIdentity = routeIdentity
        self.application = application
        self.framework = framework
        self.runtime = runtime
        self.policyResources = policyResources
        self.fallbackHistory = fallbackHistory
        self.processingConfiguration = processingConfiguration
        self.sourceScanStructure = sourceScanStructure
        self.deinterlacingAlgorithmIdentity =
            deinterlacingAlgorithmIdentity
    }
}

struct R13ReleaseIdentity: Equatable, Sendable {
    static let schemaVersion = "3.0.0"
    static let emptyFallbackHistory = "[]"
    static let metadataNamespace = "com.mirmir.release."
    static let adaptiveCapabilityID = "R13_ADAPTIVE"
    static let adaptiveBackendID = "r13.mps.lanczos.adaptive"
    static let adaptiveBackendRevision = "1"
    static let adaptiveRouteID = "adaptive_mps_lanczos"
    static let adaptivePolicyIdentity =
        "r13.adaptive-mps-lanczos.no-fallback.v1"
    static let adaptiveMaterialDecisionIdentity =
        "r13.mps-lanczos.dimension-bound.v1"

    let source: R13ReleaseSourceBinding
    let requestedMode: UpscaleMode
    let enginePreference: UpscaleEnginePreference
    let effectiveMode: UpscaleMode
    let output: R13ReleaseOutputBinding
    let capabilityID: String
    let backendID: String
    let backendRevision: String
    let routeID: String
    let configurationIdentity: String
    let policyIdentity: String
    let materialDecisionIdentity: String
    let processingConfigurationIdentity: String
    let smoothMotionConfiguration: SmoothMotionConfiguration
    let sourceScanStructure: MediaVideoScanStructure
    let deinterlacingAlgorithmIdentity: String
    let modelStatusPolicy: R13ReleasePolicyModelStatus
    let application: R13ReleaseApplicationIdentity
    let framework: R13ReleaseFrameworkIdentity
    let runtime: R13ReleaseRuntimeIdentity
    let policyResources: R13ReleasePolicyResourceBinding
    let identitySHA256: String

    init(_ input: R13ReleaseIdentityInput) throws {
        let routeBinding = try Self.validateAndResolveRouteBinding(input)
        try Self.validateFrameworkRuntimeIdentity(input)
        let routePolicy =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: {
                    switch input.scalePlan {
                    case .productQualified:
                        return .canonicalProduct
                    case .adaptiveMPSLanczos:
                        return .adaptiveFormatGeometry
                    }
                }(),
                binding: input.modeBinding
            )
        guard input.fallbackHistory.isEmpty else {
            throw R13ReleaseIdentityError.fallbackHistoryMustBeEmpty
        }

        source = input.source
        requestedMode = input.modeBinding.requestedMode
        enginePreference = input.modeBinding.enginePreference
        effectiveMode = input.modeBinding.effectiveMode
        output = input.output
        capabilityID = routeBinding.capabilityID
        backendID = input.routeIdentity.backend.backendID
        backendRevision = input.routeIdentity.backend.backendRevision
        routeID = routeBinding.routeID
        configurationIdentity = input.routeIdentity.configurationIdentity
        policyIdentity = input.routeIdentity.policyIdentity
        materialDecisionIdentity = input.routeIdentity.materialDecisionIdentity
        processingConfigurationIdentity =
            input.processingConfiguration.identity
        smoothMotionConfiguration =
            input.processingConfiguration.smoothMotion
        sourceScanStructure = input.sourceScanStructure
        deinterlacingAlgorithmIdentity =
            try R13ReleaseIdentityValidation.identity(
                input.deinterlacingAlgorithmIdentity,
                field: "deinterlacing_algorithm_identity"
            )
        let requiredDeinterlacingIdentity =
            input.sourceScanStructure.requiresDeinterlacing
            ? R13FormatPreservingDeinterlacer.algorithmIdentity
            : "not_required"
        guard deinterlacingAlgorithmIdentity
                == requiredDeinterlacingIdentity else {
            throw R13ReleaseIdentityError.invalidIdentity(
                field: "deinterlacing_algorithm_identity"
            )
        }
        modelStatusPolicy = routePolicy.modelStatus
        application = input.application
        framework = input.framework
        runtime = input.runtime
        policyResources = input.policyResources

        let payload = R13ReleaseCanonicalIdentity(
            schemaVersion: Self.schemaVersion,
            source: input.source,
            requestedMode: input.modeBinding.requestedMode.rawValue,
            enginePreference:
                input.modeBinding.enginePreference.rawValue,
            effectiveMode: input.modeBinding.effectiveMode.rawValue,
            output: input.output,
            capabilityID: routeBinding.capabilityID,
            backendID: input.routeIdentity.backend.backendID,
            backendRevision: input.routeIdentity.backend.backendRevision,
            routeID: routeBinding.routeID,
            configurationIdentity: input.routeIdentity.configurationIdentity,
            modelStatus: routePolicy.modelStatus.rawValue,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyIdentity: input.routeIdentity.policyIdentity,
            materialDecisionIdentity: input.routeIdentity.materialDecisionIdentity,
            processingConfigurationIdentity:
                input.processingConfiguration.identity,
            sourceScanStructure:
                input.sourceScanStructure.rawValue,
            deinterlacingAlgorithmIdentity:
                deinterlacingAlgorithmIdentity,
            policySHA256: input.policyResources.policySHA256,
            resourceManifestSHA256: input.policyResources.resourceManifestSHA256,
            fallbackHistory: []
        )
        identitySHA256 = Self.sha256(try Self.canonicalData(payload))
    }

    var timedMetadata: [String: String] {
        var metadata = [
            "com.mirmir.release.identity-sha256": identitySHA256,
            "com.mirmir.release.source-sha256": source.sha256,
            "com.mirmir.release.source-bytes": String(source.byteCount),
            "com.mirmir.release.requested-mode": requestedMode.rawValue,
            "com.mirmir.release.engine-preference":
                enginePreference.rawValue,
            "com.mirmir.release.effective-mode": effectiveMode.rawValue,
            "com.mirmir.release.output": output.metadataValue,
            "com.mirmir.release.capability-id": capabilityID,
            "com.mirmir.release.backend-id": backendID,
            "com.mirmir.release.backend-revision": backendRevision,
            "com.mirmir.release.route-id": routeID,
            "com.mirmir.release.configuration-id": configurationIdentity,
            "com.mirmir.release.model-status":
                modelStatusPolicy.rawValue,
            "com.mirmir.release.app": application.metadataValue,
            "com.mirmir.release.app-executable-sha256": application.executableSHA256,
            "com.mirmir.release.app-executable-bytes":
                String(application.executableByteCount),
            "com.mirmir.release.framework": framework.metadataValue,
            "com.mirmir.release.runtime": runtime.metadataValue,
            "com.mirmir.release.policy-id": policyIdentity,
            "com.mirmir.release.material-decision-id": materialDecisionIdentity,
            "com.mirmir.release.processing-configuration":
                processingConfigurationIdentity,
            "com.mirmir.release.source-scan-structure":
                sourceScanStructure.rawValue,
            "com.mirmir.release.deinterlacing-algorithm":
                deinterlacingAlgorithmIdentity,
            "com.mirmir.release.output-scan-structure":
                MediaVideoScanStructure.progressive.rawValue,
            "com.mirmir.release.policy-sha256": policyResources.policySHA256,
            "com.mirmir.release.resource-manifest-sha256":
                policyResources.resourceManifestSHA256,
            "com.mirmir.release.fallback-history": Self.emptyFallbackHistory
        ]
        if usesFrameRouter {
            metadata.merge(
                R13ProductASHDecisionMetadata.pendingValues
            ) { _, pending in pending }
        }
        if usesSmoothMotion {
            metadata.merge(
                SmoothMotionDecisionMetadata.pendingValues
            ) { _, pending in pending }
        }
        return metadata
    }

    func finalizedTimedMetadata(
        routingDecisionMetadata:
            R13ProductASHDecisionMetadata?
    ) throws -> [String: String] {
        if usesFrameRouter {
            guard let routingDecisionMetadata else {
                throw R13ReleaseIdentityError
                    .routingDecisionMetadataMissing
            }
            var metadata = timedMetadata
            metadata.merge(routingDecisionMetadata.values) {
                _, finalized in finalized
            }
            try validateRoutingMetadata(metadata)
            return metadata
        }
        guard routingDecisionMetadata == nil else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataUnexpected
        }
        return timedMetadata
    }

    func validateTimedMetadata(_ metadata: [String: String]) throws {
        let expected = timedMetadata
        guard Set(metadata.keys) == Set(expected.keys),
              metadata.keys.allSatisfy({ $0.hasPrefix(Self.metadataNamespace) }) else {
            throw R13ReleaseIdentityError.metadataKeysDiffer
        }
        let routingKeys = Set(
            R13ProductASHDecisionMetadata.pendingValues.keys
        )
        let smoothMotionKeys = Set(
            SmoothMotionDecisionMetadata.pendingValues.keys
        )
        for key in expected.keys.sorted()
        where (!usesFrameRouter || !routingKeys.contains(key))
            && (!usesSmoothMotion
                || !smoothMotionKeys.contains(key))
            && metadata[key] != expected[key] {
            throw R13ReleaseIdentityError.metadataValueDiffers(key: key)
        }
        if usesFrameRouter {
            try validateRoutingMetadata(metadata)
        }
        if usesSmoothMotion {
            try validateSmoothMotionMetadata(metadata)
        }
    }

    static func makeProductRoute(
        for scaleRoute: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding
    ) throws -> AppleUpscaleRouteIdentity {
        guard let configurationIdentity =
            modeBinding.configurationIdentity(for: scaleRoute) else {
            throw R13ReleaseIdentityError.releaseScalerBindingMismatch(
                field: "configuration_identity"
            )
        }
        return try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: modeBinding.backendID,
                backendRevision: modeBinding.backendRevision,
                modelAssetsIdentity: .notRequired
            ),
            configurationIdentity: configurationIdentity,
            policyIdentity: modeBinding.policyIdentity,
            materialDecisionIdentity:
                modeBinding.materialDecisionIdentity
        )
    }

    static func makeA11Route(
        for scaleRoute: R03ScaleRoute
    ) throws -> AppleUpscaleRouteIdentity {
        try makeProductRoute(
            for: scaleRoute,
            modeBinding: R13ReleaseModeBinding(
                requestedMode: .deterministic
            )
        )
    }

    static func makeAdaptiveRoute(
        for plan: R13AdaptiveScalePlan,
        modeBinding: R13ReleaseModeBinding
    ) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: modeBinding.backendID,
                backendRevision: modeBinding.backendRevision,
                modelAssetsIdentity: .notRequired
            ),
            configurationIdentity:
                modeBinding.adaptiveConfigurationIdentity(for: plan),
            policyIdentity: modeBinding.policyIdentity,
            materialDecisionIdentity:
                modeBinding.materialDecisionIdentity
        )
    }

    static func makeAdaptiveRoute(
        for plan: R13AdaptiveScalePlan
    ) throws -> AppleUpscaleRouteIdentity {
        try makeAdaptiveRoute(
            for: plan,
            modeBinding: R13ReleaseModeBinding(
                requestedMode: .deterministic
            )
        )
    }
}

private extension R13ReleaseIdentity {
    var usesSmoothMotion: Bool {
        requestedMode == .smoothMotion
    }

    var usesFrameRouter: Bool {
        let routerBackendIDs = Set(
            R13ReleaseOrchestrationKind.allCases
                .filter { $0 != .none }
                .map(\.backendID)
        )
        return routerBackendIDs.contains(backendID)
    }

    func validateRoutingMetadata(
        _ metadata: [String: String]
    ) throws {
        guard metadata[
            R13ProductASHDecisionMetadata.statusKey
        ] == "complete" else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_status"
                )
        }
        let decisionCount = try routingCount(
            metadata,
            key: R13ProductASHDecisionMetadata
                .decisionCountKey,
            field: "routing_decision_count"
        )
        let transitionCount = try routingCount(
            metadata,
            key: R13ProductASHDecisionMetadata
                .transitionCountKey,
            field: "routing_transition_count"
        )
        let fallbackCount = try routingCount(
            metadata,
            key: R13ProductASHDecisionMetadata
                .fallbackCountKey,
            field: "routing_fallback_count"
        )
        let candidateExclusionCount = try routingCount(
            metadata,
            key: R13ProductASHDecisionMetadata
                .candidateExclusionCountKey,
            field: "routing_candidate_exclusion_count"
        )
        let resumeBoundaryCount = try routingCount(
            metadata,
            key: R13ProductASHDecisionMetadata
                .resumeBoundaryCountKey,
            field: "routing_resume_boundary_count"
        )
        guard decisionCount > 0,
              transitionCount <= max(decisionCount - 1, 0),
              fallbackCount >= 0 else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_counts"
                )
        }
        guard let selected = metadata[
            R13ProductASHDecisionMetadata.selectedBackendsKey
        ] else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_selected_backends"
                )
        }
        let backendIDs = selected.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard let selectedModelStatusesValue = metadata[
            R13ProductASHDecisionMetadata
                .selectedModelStatusesKey
        ] else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_selected_model_statuses"
                )
        }
        let selectedModelStatusValues =
            selectedModelStatusesValue.split(
                separator: ",",
                omittingEmptySubsequences: false
            ).map(String.init)
        let selectedModelStatuses =
            selectedModelStatusValues.compactMap(
                R13ProductASHSelectedModelStatus.init(rawValue:)
            )
        let expectedModelStatus =
            selectedModelStatuses.count == 1
                ? selectedModelStatuses[0].rawValue
                : "mixed"
        guard !backendIDs.isEmpty,
              backendIDs.allSatisfy({
                  (try? R13ReleaseIdentityValidation.identity(
                      String($0),
                      field: "routing_selected_backend"
                  )) != nil
              }) else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_selected_backends"
                )
        }
        guard !selectedModelStatuses.isEmpty,
              selectedModelStatuses.count
                == selectedModelStatusValues.count,
              Set(selectedModelStatuses).count
                == selectedModelStatuses.count,
              selectedModelStatusValues
                == selectedModelStatusValues.sorted() else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_selected_model_statuses"
                )
        }
        if modelStatusPolicy == .notRequired,
           selectedModelStatuses != [.notRequired] {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_model_status_policy"
                )
        }
        if enginePreference.requiresNativeUpscaleSession {
            let selectedBackendIDs = backendIDs.map(String.init)
            let allowedBackendIDs: Set<String>
            let requiredModelStatus:
                R13ProductASHSelectedModelStatus
            switch enginePreference {
            case .videoToolboxQuality:
                allowedBackendIDs = [
                    R04VideoToolboxSubjectID.quality2x.rawValue,
                    R04VideoToolboxSubjectID.quality4x.rawValue
                ]
                requiredModelStatus =
                    .appleConfigurationManagedReady
            case .videoToolboxLowLatency:
                allowedBackendIDs = [
                    R04VideoToolboxSubjectID
                        .lowLatency1p5x.rawValue,
                    R04VideoToolboxSubjectID
                        .lowLatency2x.rawValue,
                    R04VideoToolboxSubjectID
                        .lowLatency4x.rawValue,
                    "r04.videotoolbox.low-latency.adaptive"
                ]
                requiredModelStatus = .notRequired
            case .metalFXSpatial:
                allowedBackendIDs = [
                    R05MetalFXSubjectID.spatial1p5x.rawValue,
                    R05MetalFXSubjectID.spatial2x.rawValue,
                    R05MetalFXSubjectID.spatial4x.rawValue,
                    "r05.metalfx.spatial.adaptive"
                ]
                requiredModelStatus = .notRequired
            case .automatic,
                 .accelerateVImageStandard,
                 .accelerateVImageHighQuality,
                 .mpsBilinear,
                 .mpsLanczos,
                 .coreImageLanczos,
                 .coreImageBicubic,
                 .videoToolboxPixelTransfer:
                preconditionFailure(
                    "Only exact native preferences reach native metadata validation."
                )
            }
            guard selectedBackendIDs.count == 1,
                  allowedBackendIDs.contains(
                    selectedBackendIDs[0]
                  ),
                  transitionCount == 0,
                  fallbackCount == 0,
                  candidateExclusionCount == 0,
                  selectedModelStatuses
                    == [requiredModelStatus] else {
                throw R13ReleaseIdentityError
                    .routingDecisionMetadataInvalid(
                        field: "routing_exact_native_policy"
                    )
            }
        }
        guard metadata[
            R13ProductASHDecisionMetadata.modelStatusKey
        ] == expectedModelStatus else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_model_status"
                )
        }
        try validateRoutingFallbackEvents(
            metadata,
            expectedCount: fallbackCount,
            decisionCount: decisionCount,
            selectedBackendIDs: Set(
                backendIDs.map(String.init)
            ),
            selectedModelStatuses: Set(selectedModelStatuses)
        )
        guard let candidateExclusionsJSON = metadata[
            R13ProductASHDecisionMetadata
                .candidateExclusionsKey
        ],
              let candidateExclusionsData =
                candidateExclusionsJSON.data(using: .utf8),
              let candidateExclusions = try? JSONDecoder()
                .decode(
                    [R13ProductASHScalingCandidateExclusion].self,
                    from: candidateExclusionsData
                ),
              candidateExclusions.count
                == candidateExclusionCount,
              Set(
                  candidateExclusions.map(
                      \.expectedBackendID
                  )
              ).count == candidateExclusions.count,
              Set(
                  candidateExclusions.map(
                      \.expectedBackendID
                  )
              ).isDisjoint(
                  with: Set(backendIDs.map(String.init))
              ),
              candidateExclusions.allSatisfy({
                  (try? R13ReleaseIdentityValidation.identity(
                      $0.expectedBackendID,
                      field:
                          "routing_excluded_backend_id"
                  )) != nil
                      && (try? R13ReleaseIdentityValidation
                          .identity(
                              $0.failure.reasonCode,
                              field:
                                  "routing_exclusion_reason"
                          )) != nil
                      && (try? R13ReleaseIdentityValidation
                          .identity(
                              $0.failure.errorType,
                              field:
                                  "routing_exclusion_error_type"
                          )) != nil
                      && (try? R13ReleaseIdentityValidation
                          .identity(
                              $0.failure.errorDomain,
                              field:
                                  "routing_exclusion_error_domain"
                          )) != nil
                      && (try? R13ReleaseIdentityValidation
                          .sha256(
                              $0.failure.detailSHA256,
                              field:
                                  "routing_exclusion_detail_sha256"
                          )) != nil
              }),
              (try? R13ProductASHScalingCandidateExclusionEncoding
                  .canonicalJSON(candidateExclusions))
                == candidateExclusionsJSON else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_candidate_exclusions"
                )
        }
        guard let resumeBoundariesJSON = metadata[
            R13ProductASHDecisionMetadata
                .resumeBoundariesKey
        ],
              let resumeBoundariesData =
                resumeBoundariesJSON.data(using: .utf8),
              let resumeBoundaries = try? JSONDecoder()
                .decode(
                    [R13ProductASHResumeBoundary].self,
                    from: resumeBoundariesData
                ),
              resumeBoundaries.count == resumeBoundaryCount,
              resumeBoundaries.allSatisfy({
                  $0.sequenceNumber >= 0
                      && $0.restoredHistoryFrameCount
                          == ($0.kind
                              == .oneFrameSelectedCandidateWarmup
                              ? 1
                              : 0)
              }),
              (try? R13ProductASHDecisionMetadata
                  .canonicalResumeBoundariesJSON(
                      resumeBoundaries
                  )) == resumeBoundariesJSON else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_resume_boundaries"
                )
        }
        guard let journalSHA256 = metadata[
            R13ProductASHDecisionMetadata.journalSHA256Key
        ],
              (try? R13ReleaseIdentityValidation.sha256(
                  journalSHA256,
                  field: "routing_journal_sha256"
              )) != nil else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(
                    field: "routing_journal_sha256"
                )
        }
    }

    func validateRoutingFallbackEvents(
        _ metadata: [String: String],
        expectedCount: Int,
        decisionCount: Int,
        selectedBackendIDs: Set<String>,
        selectedModelStatuses:
            Set<R13ProductASHSelectedModelStatus>
    ) throws {
        func invalid() -> R13ReleaseIdentityError {
            .routingDecisionMetadataInvalid(
                field: "routing_fallback_events"
            )
        }

        guard let json = metadata[
            R13ProductASHDecisionMetadata.fallbackEventsKey
        ],
              let data = json.data(using: .utf8),
              let events = try? JSONDecoder().decode(
                  [R13ProductASHFallbackEventEvidence].self,
                  from: data
              ),
              events.count == expectedCount,
              (try? R13ProductASHDecisionMetadata
                  .canonicalFallbackEventsJSON(events)) == json else {
            throw invalid()
        }
        guard !events.isEmpty || expectedCount == 0 else {
            throw invalid()
        }

        var failedBackendIDs: Set<String> = []
        var fallbackSequenceNumbers: Set<Int> = []
        var currentSequenceNumber: Int?
        var currentLinks: [AppleUpscaleFallbackLink] = []

        func validateCurrentChain() throws {
            guard let terminalRoute = currentLinks.last?.selectedRoute,
                  (try? AppleUpscaleProcessingIdentity(
                      route: terminalRoute,
                      fallbackHistory: currentLinks
                  )) != nil,
                  selectedBackendIDs.contains(
                      terminalRoute.backend.backendID
                  ),
                  selectedModelStatuses.contains(
                      R13ProductASHSelectedModelStatus(
                          modelAssetsIdentity:
                              terminalRoute.backend
                                  .modelAssetsIdentity
                      )
                  ) else {
                throw invalid()
            }
        }

        for event in events {
            let link: AppleUpscaleFallbackLink
            do {
                link = try event.appleLink()
            } catch {
                throw invalid()
            }
            if let currentSequenceNumber {
                guard event.sequenceNumber >= currentSequenceNumber else {
                    throw invalid()
                }
                if event.sequenceNumber != currentSequenceNumber {
                    try validateCurrentChain()
                    currentLinks.removeAll(keepingCapacity: true)
                }
            }
            if currentSequenceNumber != event.sequenceNumber {
                guard fallbackSequenceNumbers.insert(
                    event.sequenceNumber
                ).inserted else {
                    throw invalid()
                }
                currentSequenceNumber = event.sequenceNumber
            }
            guard event.selectedFallbackOrdinal
                    == currentLinks.count,
                  failedBackendIDs.insert(
                      link.failedRoute.backend.backendID
                  ).inserted else {
                throw invalid()
            }
            currentLinks.append(link)
        }
        if !currentLinks.isEmpty {
            try validateCurrentChain()
        }
        guard fallbackSequenceNumbers.count <= decisionCount else {
            throw invalid()
        }
    }

    func validateSmoothMotionMetadata(
        _ metadata: [String: String]
    ) throws {
        let cadenceMultiplier = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .cadenceMultiplierKey,
            field: "smooth_motion_cadence_multiplier"
        )
        guard cadenceMultiplier
            == smoothMotionConfiguration.cadence.multiplier else {
            throw R13ReleaseIdentityError
                .smoothMotionMetadataInvalid(
                    field: "smooth_motion_cadence_multiplier"
                )
        }
        let sourceCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .sourceFrameCountKey,
            field: "smooth_motion_source_frame_count"
        )
        let outputCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .outputFrameCountKey,
            field: "smooth_motion_output_frame_count"
        )
        let generatedCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .generatedFrameCountKey,
            field: "smooth_motion_generated_frame_count"
        )
        let interpolatedCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .interpolatedFrameCountKey,
            field: "smooth_motion_interpolated_frame_count"
        )
        let heldCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .heldFrameCountKey,
            field: "smooth_motion_held_frame_count"
        )
        let sceneCutCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata.sceneCutCountKey,
            field: "smooth_motion_scene_cut_count"
        )
        let analysisFailureCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .sceneAnalysisFailureCountKey,
            field: "smooth_motion_scene_analysis_failure_count"
        )
        let nativeFallbackCount = try smoothMotionCount(
            metadata,
            key: SmoothMotionDecisionMetadata
                .nativeRuntimeFallbackCountKey,
            field: "smooth_motion_native_runtime_fallback_count"
        )
        let (expectedOutputCount, outputOverflow) =
            sourceCount.multipliedReportingOverflow(
                by: cadenceMultiplier
            )
        let (expectedGeneratedCount, generatedUnderflow) =
            outputCount.subtractingReportingOverflow(sourceCount)
        let (classifiedGeneratedCount, classifiedOverflow) =
            interpolatedCount.addingReportingOverflow(heldCount)
        let transitionCount = max(sourceCount - 1, 0)
        let (protectedTransitionCount, protectedOverflow) =
            sceneCutCount.addingReportingOverflow(
                analysisFailureCount
            )
        guard !outputOverflow,
              !generatedUnderflow,
              !classifiedOverflow,
              !protectedOverflow,
              outputCount == expectedOutputCount,
              generatedCount == expectedGeneratedCount,
              generatedCount == classifiedGeneratedCount,
              protectedTransitionCount <= transitionCount,
              nativeFallbackCount <= 1 else {
            throw R13ReleaseIdentityError
                .smoothMotionMetadataInvalid(
                    field: "smooth_motion_counts"
                )
        }

        let fallbackReasons = Set(
            SmoothMotionNativeAvailabilityReason.allMetadataValues
                + ["none", "native_processing_failed"]
        )
        guard let fallbackReason = metadata[
            SmoothMotionDecisionMetadata.fallbackReasonKey
        ],
              fallbackReasons.contains(fallbackReason),
              (nativeFallbackCount == 0)
                == (fallbackReason != "native_processing_failed")
        else {
            throw R13ReleaseIdentityError
                .smoothMotionMetadataInvalid(
                    field: "smooth_motion_fallback_reason"
                )
        }

        let nativeRoute =
            SmoothMotionInterpolationRoute
                .videoToolboxLowLatency.rawValue
        let fallbackRoute =
            SmoothMotionInterpolationRoute
                .deterministicFormatBlend.rawValue
        let validRoutes = Set([
            "frame_hold_only",
            nativeRoute,
            fallbackRoute,
            [nativeRoute, fallbackRoute]
                .sorted()
                .joined(separator: "+")
        ])
        guard let route = metadata[
            SmoothMotionDecisionMetadata.routeKey
        ],
              validRoutes.contains(route),
              let outputFrameRate = Double(
                metadata[
                    SmoothMotionDecisionMetadata
                        .outputFrameRateKey
                ] ?? ""
              ),
              outputFrameRate.isFinite,
              outputFrameRate >= 0 else {
            throw R13ReleaseIdentityError
                .smoothMotionMetadataInvalid(
                    field: "smooth_motion_route_or_frame_rate"
                )
        }
    }

    func smoothMotionCount(
        _ metadata: [String: String],
        key: String,
        field: String
    ) throws -> Int {
        guard let value = metadata[key],
              let count = Int(value),
              count >= 0 else {
            throw R13ReleaseIdentityError
                .smoothMotionMetadataInvalid(field: field)
        }
        return count
    }

    func routingCount(
        _ metadata: [String: String],
        key: String,
        field: String
    ) throws -> Int {
        guard let value = metadata[key],
              let count = Int(value),
              count >= 0 else {
            throw R13ReleaseIdentityError
                .routingDecisionMetadataInvalid(field: field)
        }
        return count
    }

    struct ResolvedRouteBinding {
        let capabilityID: String
        let routeID: String
    }

    static func validateAndResolveRouteBinding(
        _ input: R13ReleaseIdentityInput
    ) throws -> ResolvedRouteBinding {
        guard input.modeBinding.enginePreference
            == input.processingConfiguration.enginePreference else {
            throw R13ReleaseIdentityError.modeBindingMismatch
        }
        switch input.scalePlan {
        case .productQualified(let scaleRoute):
            guard input.processingConfiguration.strategyPreference
                != .adaptive else {
                throw R13ReleaseIdentityError.outputRouteMismatch
            }
            try validateModeBinding(input.modeBinding)
            try validateProductRoute(
                input.routeIdentity,
                scaleRoute: scaleRoute,
                modeBinding: input.modeBinding,
                framework: input.framework
            )
            guard input.output.width
                    == scaleRoute.canonicalTargetResolution.width,
                  input.output.height
                    == scaleRoute.canonicalTargetResolution.height else {
                throw R13ReleaseIdentityError.outputRouteMismatch
            }
            return ResolvedRouteBinding(
                capabilityID: input.modeBinding.capabilityID,
                routeID: scaleRoute.rawValue
            )
        case .adaptiveMPSLanczos(let plan):
            guard input.processingConfiguration.strategyPreference
                != .direct else {
                throw R13ReleaseIdentityError.outputRouteMismatch
            }
            try validateModeBinding(input.modeBinding)
            try validateAdaptiveRoute(
                input.routeIdentity,
                plan: plan,
                modeBinding: input.modeBinding,
                framework: input.framework
            )
            guard input.output.width == plan.targetResolution.width,
                  input.output.height == plan.targetResolution.height else {
                throw R13ReleaseIdentityError.outputRouteMismatch
            }
            return ResolvedRouteBinding(
                capabilityID: input.modeBinding.capabilityID,
                routeID: input.modeBinding.adaptiveRouteID
            )
        }
    }

    static func validateModeBinding(
        _ binding: R13ReleaseModeBinding
    ) throws {
        guard binding == binding.canonicalReconstruction else {
            throw R13ReleaseIdentityError.modeBindingMismatch
        }
    }

    static func validateFrameworkRuntimeIdentity(
        _ input: R13ReleaseIdentityInput
    ) throws {
        guard input.framework.frameworkIdentifier
                == "AppleNativeMultiEngine" else {
            return
        }
        guard input.framework.version == input.runtime.version else {
            throw R13ReleaseIdentityError
                .frameworkRuntimeIdentityMismatch(
                    field: "framework_version"
                )
        }
        guard input.framework.buildIdentity
                == input.runtime.buildIdentity else {
            throw R13ReleaseIdentityError
                .frameworkRuntimeIdentityMismatch(
                    field: "framework_build_identity"
                )
        }
    }

    static func validateProductRoute(
        _ route: AppleUpscaleRouteIdentity,
        scaleRoute: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding,
        framework: R13ReleaseFrameworkIdentity
    ) throws {
        guard route.backend.backendID == modeBinding.backendID else {
            throw R13ReleaseIdentityError.releaseScalerBindingMismatch(
                field: "backend_id"
            )
        }
        guard route.backend.backendRevision
            == modeBinding.backendRevision else {
            throw R13ReleaseIdentityError.releaseScalerBindingMismatch(
                field: "backend_revision"
            )
        }
        guard case .notRequired = route.backend.modelAssetsIdentity else {
            throw R13ReleaseIdentityError.modelAssetsMustBeNotRequired
        }
        guard route.configurationIdentity
            == modeBinding.configurationIdentity(for: scaleRoute) else {
            throw R13ReleaseIdentityError.releaseScalerBindingMismatch(
                field: "configuration_identity"
            )
        }
        guard route.policyIdentity == modeBinding.policyIdentity else {
            throw R13ReleaseIdentityError.releaseScalerBindingMismatch(
                field: "policy_identity"
            )
        }
        guard route.materialDecisionIdentity
            == modeBinding.materialDecisionIdentity else {
            throw R13ReleaseIdentityError.releaseScalerBindingMismatch(
                field: "material_decision_identity"
            )
        }
        guard framework.frameworkIdentifier
            == modeBinding.frameworkIdentity else {
            throw R13ReleaseIdentityError.releaseScalerBindingMismatch(
                field: "framework_identifier"
            )
        }
    }

    static func validateAdaptiveRoute(
        _ route: AppleUpscaleRouteIdentity,
        plan: R13AdaptiveScalePlan,
        modeBinding: R13ReleaseModeBinding,
        framework: R13ReleaseFrameworkIdentity
    ) throws {
        guard route.backend.backendID == modeBinding.backendID else {
            throw R13ReleaseIdentityError.adaptiveBindingMismatch(
                field: "backend_id"
            )
        }
        guard route.backend.backendRevision
            == modeBinding.backendRevision else {
            throw R13ReleaseIdentityError.adaptiveBindingMismatch(
                field: "backend_revision"
            )
        }
        guard case .notRequired = route.backend.modelAssetsIdentity else {
            throw R13ReleaseIdentityError.modelAssetsMustBeNotRequired
        }
        guard route.configurationIdentity
            == modeBinding.adaptiveConfigurationIdentity(for: plan) else {
            throw R13ReleaseIdentityError.adaptiveBindingMismatch(
                field: "configuration_identity"
            )
        }
        guard route.policyIdentity == modeBinding.policyIdentity else {
            throw R13ReleaseIdentityError.adaptiveBindingMismatch(
                field: "policy_identity"
            )
        }
        guard route.materialDecisionIdentity
            == modeBinding.materialDecisionIdentity else {
            throw R13ReleaseIdentityError.adaptiveBindingMismatch(
                field: "material_decision_identity"
            )
        }
        guard framework.frameworkIdentifier
            == modeBinding.frameworkIdentity else {
            throw R13ReleaseIdentityError.adaptiveBindingMismatch(
                field: "framework_identifier"
            )
        }
    }

    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct R13ReleaseCanonicalIdentity: Codable {
    let schemaVersion: String
    let source: R13ReleaseSourceBinding
    let requestedMode: String
    let enginePreference: String
    let effectiveMode: String
    let output: R13ReleaseOutputBinding
    let capabilityID: String
    let backendID: String
    let backendRevision: String
    let routeID: String
    let configurationIdentity: String
    let modelStatus: String
    let application: R13ReleaseApplicationIdentity
    let framework: R13ReleaseFrameworkIdentity
    let runtime: R13ReleaseRuntimeIdentity
    let policyIdentity: String
    let materialDecisionIdentity: String
    let processingConfigurationIdentity: String
    let sourceScanStructure: String
    let deinterlacingAlgorithmIdentity: String
    let policySHA256: String
    let resourceManifestSHA256: String
    let fallbackHistory: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case requestedMode = "requested_mode"
        case enginePreference = "engine_preference"
        case effectiveMode = "effective_mode"
        case output
        case capabilityID = "capability_id"
        case backendID = "backend_id"
        case backendRevision = "backend_revision"
        case routeID = "route_id"
        case configurationIdentity = "configuration_identity"
        case modelStatus = "model_status"
        case application
        case framework
        case runtime
        case policyIdentity = "policy_identity"
        case materialDecisionIdentity = "material_decision_identity"
        case processingConfigurationIdentity =
            "processing_configuration_identity"
        case sourceScanStructure = "source_scan_structure"
        case deinterlacingAlgorithmIdentity =
            "deinterlacing_algorithm_identity"
        case policySHA256 = "policy_sha256"
        case resourceManifestSHA256 = "resource_manifest_sha256"
        case fallbackHistory = "fallback_history"
    }
}

enum R13ReleaseIdentityValidation {
    static func identity(_ value: String, field: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 160,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || $0 == "."
                      || $0 == "_"
                      || $0 == "-"
                      || $0 == ":"
              }) else {
            throw R13ReleaseIdentityError.invalidIdentity(field: field)
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        guard value.utf8.count == 64,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x61 && $0.value <= 0x66)
              }),
              value != String(repeating: "0", count: 64) else {
            throw R13ReleaseIdentityError.invalidSHA256(field: field)
        }
        return value
    }
}

// swiftlint:disable:this file_length
