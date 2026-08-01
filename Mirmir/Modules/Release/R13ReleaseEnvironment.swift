import AVFoundation
import Darwin
import Foundation

enum R13ReleaseEnvironmentError: Error, Equatable, Sendable {
    case applicationSupportDirectoryUnavailable
    case applicationIdentityUnavailable(field: String)
    case frameworkIdentityUnavailable(field: String)
    case runtimeIdentityUnavailable(field: String)
    case frameCountReaderFailed(String)
    case frameCountUnavailable
    case memoryProbeFailed
    case arithmeticOverflow(field: String)
}

struct R13ReleaseEnvironment: Sendable {
    let application: R13ReleaseApplicationIdentity
    let framework: R13ReleaseFrameworkIdentity
    let runtime: R13ReleaseRuntimeIdentity
}

protocol R13ReleaseEnvironmentCollecting: Sendable {
    func collect() throws -> R13ReleaseEnvironment
    func collect(
        frameworkIdentity: String
    ) throws -> R13ReleaseEnvironment
}

extension R13ReleaseEnvironmentCollecting {
    func collect(
        frameworkIdentity: String
    ) throws -> R13ReleaseEnvironment {
        let environment = try collect()
        guard environment.framework.frameworkIdentifier
            == frameworkIdentity else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "requested_framework"
            )
        }
        return environment
    }
}

enum R13FrameworkBundleIdentityCanonicalizer {
    private static let encodedPrefix = "utf8-hex-"
    private static let maximumEncodableUTF8ByteCount = 75

    static func version(_ value: String) throws -> String {
        try canonicalValue(
            value,
            environmentField: "version",
            identityField: "framework_version"
        )
    }

    static func build(_ value: String) throws -> String {
        try canonicalValue(
            value,
            environmentField: "build",
            identityField: "framework_build_identity"
        )
    }

    private static func canonicalValue(
        _ value: String,
        environmentField: String,
        identityField: String
    ) throws -> String {
        if !value.hasPrefix(encodedPrefix),
           let unchanged = try? R13ReleaseIdentityValidation.identity(
               value,
               field: identityField
           ) {
            return unchanged
        }
        guard !value.isEmpty,
              value.utf8.count <= maximumEncodableUTF8ByteCount,
              value.unicodeScalars.allSatisfy(Self.isPrintable) else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: environmentField
            )
        }
        let encoded = encodedPrefix
            + value.utf8.map { String(format: "%02x", $0) }.joined()
        guard let canonical = try? R13ReleaseIdentityValidation.identity(
            encoded,
            field: identityField
        ) else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: environmentField
            )
        }
        return canonical
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control,
             .format,
             .lineSeparator,
             .paragraphSeparator,
             .surrogate,
             .unassigned:
            return false
        default:
            return true
        }
    }
}

struct R13ProductionReleaseEnvironmentCollector:
    R13ReleaseEnvironmentCollecting {
    private static let metalPerformanceShadersPath =
        "/System/Library/Frameworks/MetalPerformanceShaders.framework"
    private static let acceleratePath =
        "/System/Library/Frameworks/Accelerate.framework"
    private static let coreImagePath =
        "/System/Library/Frameworks/CoreImage.framework"
    private static let videoToolboxPath =
        "/System/Library/Frameworks/VideoToolbox.framework"
    private static let metalFXPath =
        "/System/Library/Frameworks/MetalFX.framework"

    func collect() throws -> R13ReleaseEnvironment {
        try collect(
            frameworkIdentity:
                R03A11ProductAdmission.frameworkIdentity
        )
    }

    func collect(
        frameworkIdentity: String
    ) throws -> R13ReleaseEnvironment {
        let bundle = Bundle.main
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            throw R13ReleaseEnvironmentError.applicationIdentityUnavailable(
                field: "bundle_identifier"
            )
        }
        guard let semanticVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            throw R13ReleaseEnvironmentError.applicationIdentityUnavailable(
                field: "semantic_version"
            )
        }
        guard let buildVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String else {
            throw R13ReleaseEnvironmentError.applicationIdentityUnavailable(
                field: "build_version"
            )
        }
        guard let executableURL = bundle.executableURL else {
            throw R13ReleaseEnvironmentError.applicationIdentityUnavailable(
                field: "executable_url"
            )
        }
        let executable = try R13LocalRestartSourceMeasurer()
            .measureSource(at: executableURL)

        let processInfo = ProcessInfo.processInfo
        let operatingSystemVersion = processInfo.operatingSystemVersion
        let runtimeVersion =
            "\(operatingSystemVersion.majorVersion)."
            + "\(operatingSystemVersion.minorVersion)."
            + "\(operatingSystemVersion.patchVersion)"
        let runtimeBuild = try Self.operatingSystemBuildIdentity()

        let frameworkVersion: String
        let frameworkBuild: String
        switch frameworkIdentity {
        case "MetalPerformanceShaders":
            (frameworkVersion, frameworkBuild) = try Self.frameworkIdentity(
                at: Self.metalPerformanceShadersPath
            )
        case "Accelerate":
            (frameworkVersion, frameworkBuild) = try Self.frameworkIdentity(
                at: Self.acceleratePath
            )
        case "CoreImage":
            (frameworkVersion, frameworkBuild) = try Self.frameworkIdentity(
                at: Self.coreImagePath
            )
        case "VideoToolbox":
            (frameworkVersion, frameworkBuild) = try Self.frameworkIdentity(
                at: Self.videoToolboxPath
            )
        case "MetalFX":
            (frameworkVersion, frameworkBuild) = try Self.frameworkIdentity(
                at: Self.metalFXPath
            )
        case "AppleNativeMultiEngine":
            frameworkVersion = runtimeVersion
            frameworkBuild = runtimeBuild
        default:
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "requested_framework"
            )
        }

        return try R13ReleaseEnvironment(
            application: R13ReleaseApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                semanticVersion: semanticVersion,
                buildVersion: buildVersion,
                executableSHA256: executable.sha256,
                executableByteCount: executable.byteCount
            ),
            framework: R13ReleaseFrameworkIdentity(
                frameworkIdentifier: frameworkIdentity,
                version: frameworkVersion,
                buildIdentity: frameworkBuild
            ),
            runtime: R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: runtimeVersion,
                buildIdentity: runtimeBuild,
                architecture: Self.architecture
            )
        )
    }

    private static func frameworkIdentity(
        at path: String
    ) throws -> (version: String, build: String) {
        guard let frameworkBundle = Bundle(path: path) else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "bundle"
            )
        }
        guard let version = frameworkBundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "version"
            )
        }
        guard let build = frameworkBundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "build"
            )
        }
        return (
            try R13FrameworkBundleIdentityCanonicalizer.version(version),
            try R13FrameworkBundleIdentityCanonicalizer.build(build)
        )
    }

    private static func operatingSystemBuildIdentity() throws -> String {
        var byteCount = 0
        guard sysctlbyname(
            "kern.osversion",
            nil,
            &byteCount,
            nil,
            0
        ) == 0,
        byteCount > 1 else {
            throw R13ReleaseEnvironmentError.runtimeIdentityUnavailable(
                field: "operating_system_build"
            )
        }
        var bytes = [CChar](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes {
            sysctlbyname(
                "kern.osversion",
                $0.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0 else {
            throw R13ReleaseEnvironmentError.runtimeIdentityUnavailable(
                field: "operating_system_build"
            )
        }
        let value = String(cString: bytes)
        guard !value.isEmpty else {
            throw R13ReleaseEnvironmentError.runtimeIdentityUnavailable(
                field: "operating_system_build"
            )
        }
        return value
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unsupported_architecture"
        #endif
    }
}

protocol R13SourceFrameCountMeasuring: Sendable {
    func exactVideoFrameCount(at url: URL) async throws -> Int
}

struct R13AVFoundationSourceFrameCounter:
    R13SourceFrameCountMeasuring {
    func exactVideoFrameCount(at url: URL) async throws -> Int {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw R13ReleaseEnvironmentError.frameCountUnavailable
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw R13ReleaseEnvironmentError.frameCountReaderFailed(
                String(describing: error)
            )
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw R13ReleaseEnvironmentError.frameCountReaderFailed(
                "reader_rejected_video_track"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw R13ReleaseEnvironmentError.frameCountReaderFailed(
                String(describing: reader.error)
            )
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var frameCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            frameCount = try Self.addingSampleCount(
                CMSampleBufferGetNumSamples(sampleBuffer),
                to: frameCount
            )
        }
        guard reader.status == .completed else {
            throw R13ReleaseEnvironmentError.frameCountReaderFailed(
                String(describing: reader.error)
            )
        }
        guard frameCount > 0 else {
            throw R13ReleaseEnvironmentError.frameCountUnavailable
        }
        return frameCount
    }

    static func addingSampleCount(
        _ sampleCount: Int,
        to frameCount: Int
    ) throws -> Int {
        let (next, overflow) = frameCount.addingReportingOverflow(
            sampleCount
        )
        guard sampleCount >= 0, !overflow else {
            throw R13ReleaseEnvironmentError.arithmeticOverflow(
                field: "source_frame_count"
            )
        }
        return next
    }
}

struct R13ReleaseHardeningDocuments: Sendable {
    let policyResources: R13ReleasePolicyResourceBinding
    let resourcePolicy: R13ResourcePolicy

    static func production() throws -> R13ReleaseHardeningDocuments {
        let releasePolicy = R13ReleasePolicyDocument(
            bindings: UpscaleMode.allCases
                .sorted { $0.rawValue < $1.rawValue }
                .flatMap { mode in
                    UpscaleEnginePreference.allCases
                        .sorted { $0.rawValue < $1.rawValue }
                        .map {
                            R13ReleaseModeBinding(
                                requestedMode: mode,
                                enginePreference: $0
                            )
                        }
                }
        )
        let resourceManifest = R13ReleaseResourceManifest(
            schemaVersion: 1,
            minimumFreeDiskBytes: 1_073_741_824,
            minimumFreeMemoryBytes: 536_870_912,
            maximumThermalCondition: R13ThermalCondition.serious.rawValue,
            maximumConcurrentJobs: 1,
            cacheSchema: "r13-nv12-lzfse-or-raw-v1",
            partialMediaReusePolicy:
                R13PartialMediaReusePolicy.forbidden.rawValue
        )
        let digest = R13CryptoKitRestartDigest()
        let policySHA256 = digest.sha256(
            try R13RestartCanonical.data(releasePolicy)
        )
        let resourceManifestSHA256 = digest.sha256(
            try R13RestartCanonical.data(resourceManifest)
        )
        return try R13ReleaseHardeningDocuments(
            policyResources: R13ReleasePolicyResourceBinding(
                policySHA256: policySHA256,
                resourceManifestSHA256: resourceManifestSHA256
            ),
            resourcePolicy: R13ResourcePolicy(
                policySHA256: resourceManifestSHA256,
                minimumFreeDiskBytes:
                    resourceManifest.minimumFreeDiskBytes,
                minimumFreeMemoryBytes:
                    resourceManifest.minimumFreeMemoryBytes,
                maximumThermalCondition: .serious,
                maximumConcurrentJobs:
                    resourceManifest.maximumConcurrentJobs
            )
        )
    }
}

struct R13ProductionResourceProbe {
    static func make(
        storageURL: URL
    ) -> R13ResourceProbes {
        R13ResourceProbes(
            availableDiskBytes: {
                try R13FoundationAvailableCapacityProbe()
                    .availableCapacityForImportantUsage(at: storageURL)
            },
            availableMemoryBytes: {
                try availableMemoryBytes()
            },
            thermalCondition: {
                thermalCondition()
            }
        )
    }

    private static func availableMemoryBytes() throws -> UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride
                / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    $0,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else {
            throw R13ReleaseEnvironmentError.memoryProbeFailed
        }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            throw R13ReleaseEnvironmentError.memoryProbeFailed
        }
        let reclaimablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
        let (bytes, overflow) = reclaimablePages.multipliedReportingOverflow(
            by: UInt64(pageSize)
        )
        guard !overflow else {
            throw R13ReleaseEnvironmentError.arithmeticOverflow(
                field: "available_memory_bytes"
            )
        }
        return bytes
    }

    private static func thermalCondition() -> R13ThermalCondition {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .critical
        }
    }
}

struct R13ReleasePolicyDocument:
    Codable,
    Equatable,
    Sendable {
    static let schemaVersion = 3

    let schemaVersion: Int
    let modes: [R13ReleaseModePolicyEntry]

    init(bindings: [R13ReleaseModeBinding]) {
        schemaVersion = Self.schemaVersion
        modes = bindings.map(R13ReleaseModePolicyEntry.init)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modes
    }
}

struct R13ReleaseModePolicyEntry:
    Codable,
    Equatable,
    Sendable {
    let requestedMode: String
    let enginePreference: String
    let effectiveMode: String
    let scalerKind: String
    let capabilityID: String
    let backendID: String
    let backendRevision: String
    let frameworkIdentity: String
    let policyIdentity: String
    let materialDecisionIdentity: String
    let canonicalProductRoutePolicy:
        R13ReleaseRoutePolicyClaim
    let adaptiveFormatGeometryRoutePolicy:
        R13ReleaseRoutePolicyClaim

    init(_ binding: R13ReleaseModeBinding) {
        requestedMode = binding.requestedMode.rawValue
        enginePreference = binding.enginePreference.rawValue
        effectiveMode = binding.effectiveMode.rawValue
        scalerKind = binding.scalerKind.rawValue
        capabilityID = binding.capabilityID
        backendID = binding.backendID
        backendRevision = binding.backendRevision
        frameworkIdentity = binding.frameworkIdentity
        policyIdentity = binding.policyIdentity
        materialDecisionIdentity =
            binding.materialDecisionIdentity
        canonicalProductRoutePolicy =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass: .canonicalProduct,
                binding: binding
            )
        adaptiveFormatGeometryRoutePolicy =
            R13ReleaseRoutePolicyClaim.canonical(
                routeClass:
                    .adaptiveFormatGeometry,
                binding: binding
            )
    }

    private enum CodingKeys: String, CodingKey {
        case requestedMode = "requested_mode"
        case enginePreference = "engine_preference"
        case effectiveMode = "effective_mode"
        case scalerKind = "scaler_kind"
        case capabilityID = "capability_id"
        case backendID = "backend_id"
        case backendRevision = "backend_revision"
        case frameworkIdentity = "framework_identity"
        case policyIdentity = "policy_identity"
        case materialDecisionIdentity = "material_decision_identity"
        case canonicalProductRoutePolicy =
            "canonical_product_route_policy"
        case adaptiveFormatGeometryRoutePolicy =
            "adaptive_format_geometry_route_policy"
    }
}

private struct R13ReleaseResourceManifest: Codable {
    let schemaVersion: Int
    let minimumFreeDiskBytes: UInt64
    let minimumFreeMemoryBytes: UInt64
    let maximumThermalCondition: Int
    let maximumConcurrentJobs: Int
    let cacheSchema: String
    let partialMediaReusePolicy: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case minimumFreeDiskBytes = "minimum_free_disk_bytes"
        case minimumFreeMemoryBytes = "minimum_free_memory_bytes"
        case maximumThermalCondition = "maximum_thermal_condition"
        case maximumConcurrentJobs = "maximum_concurrent_jobs"
        case cacheSchema = "cache_schema"
        case partialMediaReusePolicy = "partial_media_reuse_policy"
    }
}
