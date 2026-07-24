import CryptoKit
import Foundation

enum R13ReleaseIdentityError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidByteCount(field: String)
    case invalidOutputDimensions(width: Int, height: Int)
    case modeBindingMismatch
    case a11BindingMismatch(field: String)
    case outputRouteMismatch
    case modelAssetsMustBeNotRequired
    case fallbackHistoryMustBeEmpty
    case metadataKeysDiffer
    case metadataValueDiffers(key: String)
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

struct R13ReleaseIdentityInput: Sendable {
    let source: R13ReleaseSourceBinding
    let modeBinding: R13ReleaseModeBinding
    let output: R13ReleaseOutputBinding
    let scaleRoute: R03ScaleRoute
    let routeIdentity: AppleUpscaleRouteIdentity
    let application: R13ReleaseApplicationIdentity
    let framework: R13ReleaseFrameworkIdentity
    let runtime: R13ReleaseRuntimeIdentity
    let policyResources: R13ReleasePolicyResourceBinding
    let fallbackHistory: [AppleUpscaleFallbackLink]
}

struct R13ReleaseIdentity: Equatable, Sendable {
    static let schemaVersion = "1.0.0"
    static let modelStatus = "not_required"
    static let emptyFallbackHistory = "[]"
    static let metadataNamespace = "com.mirmir.release."

    let source: R13ReleaseSourceBinding
    let requestedMode: UpscaleMode
    let effectiveMode: UpscaleMode
    let output: R13ReleaseOutputBinding
    let capabilityID: String
    let backendID: String
    let backendRevision: String
    let routeID: String
    let configurationIdentity: String
    let policyIdentity: String
    let materialDecisionIdentity: String
    let application: R13ReleaseApplicationIdentity
    let framework: R13ReleaseFrameworkIdentity
    let runtime: R13ReleaseRuntimeIdentity
    let policyResources: R13ReleasePolicyResourceBinding
    let identitySHA256: String

    init(_ input: R13ReleaseIdentityInput) throws {
        try Self.validateModeBinding(input.modeBinding)
        try Self.validateA11Route(
            input.routeIdentity,
            scaleRoute: input.scaleRoute,
            framework: input.framework
        )
        guard input.output.width == input.scaleRoute.canonicalTargetResolution.width,
              input.output.height == input.scaleRoute.canonicalTargetResolution.height else {
            throw R13ReleaseIdentityError.outputRouteMismatch
        }
        guard input.fallbackHistory.isEmpty else {
            throw R13ReleaseIdentityError.fallbackHistoryMustBeEmpty
        }

        source = input.source
        requestedMode = input.modeBinding.requestedMode
        effectiveMode = input.modeBinding.effectiveMode
        output = input.output
        capabilityID = input.modeBinding.capabilityID
        backendID = input.routeIdentity.backend.backendID
        backendRevision = input.routeIdentity.backend.backendRevision
        routeID = input.scaleRoute.rawValue
        configurationIdentity = input.routeIdentity.configurationIdentity
        policyIdentity = input.routeIdentity.policyIdentity
        materialDecisionIdentity = input.routeIdentity.materialDecisionIdentity
        application = input.application
        framework = input.framework
        runtime = input.runtime
        policyResources = input.policyResources

        let payload = R13ReleaseCanonicalIdentity(
            schemaVersion: Self.schemaVersion,
            source: input.source,
            requestedMode: input.modeBinding.requestedMode.rawValue,
            effectiveMode: input.modeBinding.effectiveMode.rawValue,
            output: input.output,
            capabilityID: input.modeBinding.capabilityID,
            backendID: input.routeIdentity.backend.backendID,
            backendRevision: input.routeIdentity.backend.backendRevision,
            routeID: input.scaleRoute.rawValue,
            configurationIdentity: input.routeIdentity.configurationIdentity,
            modelStatus: Self.modelStatus,
            application: input.application,
            framework: input.framework,
            runtime: input.runtime,
            policyIdentity: input.routeIdentity.policyIdentity,
            materialDecisionIdentity: input.routeIdentity.materialDecisionIdentity,
            policySHA256: input.policyResources.policySHA256,
            resourceManifestSHA256: input.policyResources.resourceManifestSHA256,
            fallbackHistory: []
        )
        identitySHA256 = Self.sha256(try Self.canonicalData(payload))
    }

    var timedMetadata: [String: String] {
        [
            "com.mirmir.release.identity-sha256": identitySHA256,
            "com.mirmir.release.source-sha256": source.sha256,
            "com.mirmir.release.source-bytes": String(source.byteCount),
            "com.mirmir.release.requested-mode": requestedMode.rawValue,
            "com.mirmir.release.effective-mode": effectiveMode.rawValue,
            "com.mirmir.release.output": output.metadataValue,
            "com.mirmir.release.capability-id": capabilityID,
            "com.mirmir.release.backend-id": backendID,
            "com.mirmir.release.backend-revision": backendRevision,
            "com.mirmir.release.route-id": routeID,
            "com.mirmir.release.configuration-id": configurationIdentity,
            "com.mirmir.release.model-status": Self.modelStatus,
            "com.mirmir.release.app": application.metadataValue,
            "com.mirmir.release.app-executable-sha256": application.executableSHA256,
            "com.mirmir.release.app-executable-bytes":
                String(application.executableByteCount),
            "com.mirmir.release.framework": framework.metadataValue,
            "com.mirmir.release.runtime": runtime.metadataValue,
            "com.mirmir.release.policy-id": policyIdentity,
            "com.mirmir.release.material-decision-id": materialDecisionIdentity,
            "com.mirmir.release.policy-sha256": policyResources.policySHA256,
            "com.mirmir.release.resource-manifest-sha256":
                policyResources.resourceManifestSHA256,
            "com.mirmir.release.fallback-history": Self.emptyFallbackHistory
        ]
    }

    func validateTimedMetadata(_ metadata: [String: String]) throws {
        let expected = timedMetadata
        guard Set(metadata.keys) == Set(expected.keys),
              metadata.keys.allSatisfy({ $0.hasPrefix(Self.metadataNamespace) }) else {
            throw R13ReleaseIdentityError.metadataKeysDiffer
        }
        for key in expected.keys.sorted() where metadata[key] != expected[key] {
            throw R13ReleaseIdentityError.metadataValueDiffers(key: key)
        }
    }

    static func makeA11Route(
        for scaleRoute: R03ScaleRoute
    ) throws -> AppleUpscaleRouteIdentity {
        guard let subject = R03DeterministicBackendCatalog.subject(
            R03A11ProductAdmission.subjectID
        ),
        let configurationIdentity = subject.configurationIdentity(for: scaleRoute) else {
            throw R13ReleaseIdentityError.a11BindingMismatch(
                field: "configuration_identity"
            )
        }
        return try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: subject.id.rawValue,
                backendRevision: R03DeterministicBackendCatalog.backendRevision,
                modelAssetsIdentity: .notRequired
            ),
            configurationIdentity: configurationIdentity,
            policyIdentity: R03A11ProductAdmission.policyIdentity,
            materialDecisionIdentity: R03A11ProductAdmission.materialDecisionIdentity
        )
    }
}

private extension R13ReleaseIdentity {
    static func validateModeBinding(
        _ binding: R13ReleaseModeBinding
    ) throws {
        guard binding.requestedMode != .auto,
              binding.effectiveMode == .deterministic,
              binding.capabilityID == R03A11ProductAdmission.capabilityID,
              binding.backendID == R03A11ProductAdmission.subjectID.rawValue,
              binding.policyIdentity == R03A11ProductAdmission.policyIdentity,
              binding.materialDecisionIdentity
                == R03A11ProductAdmission.materialDecisionIdentity else {
            throw R13ReleaseIdentityError.modeBindingMismatch
        }
    }

    static func validateA11Route(
        _ route: AppleUpscaleRouteIdentity,
        scaleRoute: R03ScaleRoute,
        framework: R13ReleaseFrameworkIdentity
    ) throws {
        guard route.backend.backendID == R03A11ProductAdmission.subjectID.rawValue else {
            throw R13ReleaseIdentityError.a11BindingMismatch(field: "backend_id")
        }
        guard route.backend.backendRevision
            == R03DeterministicBackendCatalog.backendRevision else {
            throw R13ReleaseIdentityError.a11BindingMismatch(
                field: "backend_revision"
            )
        }
        guard case .notRequired = route.backend.modelAssetsIdentity else {
            throw R13ReleaseIdentityError.modelAssetsMustBeNotRequired
        }
        guard let subject = R03DeterministicBackendCatalog.subject(
            R03A11ProductAdmission.subjectID
        ),
        route.configurationIdentity == subject.configurationIdentity(for: scaleRoute) else {
            throw R13ReleaseIdentityError.a11BindingMismatch(
                field: "configuration_identity"
            )
        }
        guard route.policyIdentity == R03A11ProductAdmission.policyIdentity else {
            throw R13ReleaseIdentityError.a11BindingMismatch(
                field: "policy_identity"
            )
        }
        guard route.materialDecisionIdentity
            == R03A11ProductAdmission.materialDecisionIdentity else {
            throw R13ReleaseIdentityError.a11BindingMismatch(
                field: "material_decision_identity"
            )
        }
        guard framework.frameworkIdentifier
            == R03A11ProductAdmission.frameworkIdentity else {
            throw R13ReleaseIdentityError.a11BindingMismatch(
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
    let policySHA256: String
    let resourceManifestSHA256: String
    let fallbackHistory: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case requestedMode = "requested_mode"
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
