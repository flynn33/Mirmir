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
}

struct R13ProductionReleaseEnvironmentCollector:
    R13ReleaseEnvironmentCollecting {
    private static let metalPerformanceShadersPath =
        "/System/Library/Frameworks/MetalPerformanceShaders.framework"

    func collect() throws -> R13ReleaseEnvironment {
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

        guard let frameworkBundle = Bundle(
            path: Self.metalPerformanceShadersPath
        ) else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "bundle"
            )
        }
        guard let frameworkVersion = frameworkBundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "version"
            )
        }
        guard let frameworkBuild = frameworkBundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String else {
            throw R13ReleaseEnvironmentError.frameworkIdentityUnavailable(
                field: "build"
            )
        }

        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        return try R13ReleaseEnvironment(
            application: R13ReleaseApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                semanticVersion: semanticVersion,
                buildVersion: buildVersion,
                executableSHA256: executable.sha256,
                executableByteCount: executable.byteCount
            ),
            framework: R13ReleaseFrameworkIdentity(
                frameworkIdentifier: R03A11ProductAdmission.frameworkIdentity,
                version: frameworkVersion,
                buildIdentity: frameworkBuild
            ),
            runtime: R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                buildIdentity: try Self.operatingSystemBuildIdentity(),
                architecture: Self.architecture
            )
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
            schemaVersion: 1,
            allowedRequestedModes: [
                UpscaleMode.deterministic.rawValue,
                UpscaleMode.fast.rawValue,
                UpscaleMode.quality.rawValue
            ],
            effectiveMode: UpscaleMode.deterministic.rawValue,
            backendID: R03A11ProductAdmission.subjectID.rawValue,
            backendRevision: R03DeterministicBackendCatalog.backendRevision,
            policyIdentity: R03A11ProductAdmission.policyIdentity,
            materialDecisionIdentity:
                R03A11ProductAdmission.materialDecisionIdentity,
            modelStatus: R13ReleaseIdentity.modelStatus,
            fallbackPolicy: "forbidden"
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

private struct R13ReleasePolicyDocument: Codable {
    let schemaVersion: Int
    let allowedRequestedModes: [String]
    let effectiveMode: String
    let backendID: String
    let backendRevision: String
    let policyIdentity: String
    let materialDecisionIdentity: String
    let modelStatus: String
    let fallbackPolicy: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case allowedRequestedModes = "allowed_requested_modes"
        case effectiveMode = "effective_mode"
        case backendID = "backend_id"
        case backendRevision = "backend_revision"
        case policyIdentity = "policy_identity"
        case materialDecisionIdentity = "material_decision_identity"
        case modelStatus = "model_status"
        case fallbackPolicy = "fallback_policy"
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
