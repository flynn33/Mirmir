import CoreVideo
import Foundation

enum R13ReleaseHardeningError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case resourceRejected(R13ResourceRejection)
    case resourceProbeFailed(R13ResourceProbeKind)
    case injectedFault(point: R13FaultPoint, fault: R13InjectedFault)
    case resourceLeaseUnavailable(String)
    case diskReservationExceeded(requestedBytes: UInt64, remainingBytes: UInt64)
    case outputFrameCountMismatch(expected: Int, actual: Int)
    case arithmeticOverflow(field: String)

    var description: String {
        switch self {
        case .resourceRejected(let rejection):
            return "R13 resource admission rejected the job: \(rejection)"
        case .resourceProbeFailed(let probe):
            return "R13 could not measure the required \(probe.rawValue) resource."
        case .injectedFault(let point, let fault):
            return "R13 test fault \(fault.rawValue) was observed at \(point.rawValue)."
        case .resourceLeaseUnavailable(let identity):
            return "R13 resource lease is unavailable: \(identity)"
        case .diskReservationExceeded(let requestedBytes, let remainingBytes):
            return "R13 disk reservation consumption of \(requestedBytes) bytes "
                + "exceeded the \(remainingBytes)-byte remainder."
        case .outputFrameCountMismatch(let expected, let actual):
            return "R13 expected \(expected) frames but decoded \(actual)."
        case .arithmeticOverflow(let field):
            return "R13 resource arithmetic overflowed for \(field)."
        }
    }
}

struct R13PreparedHardeningJob: Sendable {
    let sourceIdentity: R13RestartSourceIdentity
    let identity: R13ReleaseIdentity
    let plan: R13RestartAttemptPlan
    let preflight: R13StoragePreflightReceipt
    let resourceReservationDiskBytes: UInt64
    let liveDiskGrowthAllowanceBytes: UInt64
    let outputCapacityPlan: R13OutputVolumeCapacityPlan
    let createdNew: Bool
}

struct R13RestartPreparation: Sendable {
    let plan: R13RestartAttemptPlan
    let createdNew: Bool
}

struct R13OutputVolumeCapacityPlan: Equatable, Sendable {
    let outputDirectoryURL: URL
    let admissionRequiredBytes: UInt64
    let liveRecheckRequiredBytes: UInt64

    init(
        outputDirectoryURL: URL,
        expectedFinalizationPeakBytes: UInt64,
        expectedFinalOutputBytes: UInt64,
        minimumFreeDiskBytes: UInt64
    ) throws {
        let reservedOutputBytes =
            try R13ReleaseHardeningRuntime.requiredOutputVolumeBytes(
                expectedOutputBytes: expectedFinalizationPeakBytes
            )
        guard reservedOutputBytes >= expectedFinalizationPeakBytes else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "distinct_output_reserved_bytes"
            )
        }
        admissionRequiredBytes = try Self.checkedAdd(
            reservedOutputBytes,
            minimumFreeDiskBytes,
            field: "distinct_output_admission_required_bytes"
        )
        liveRecheckRequiredBytes = try Self.checkedAdd(
            try Self.checkedAdd(
                expectedFinalOutputBytes,
                reservedOutputBytes - expectedFinalizationPeakBytes,
                field: "distinct_output_live_recheck_required_bytes"
            ),
            minimumFreeDiskBytes,
            field: "distinct_output_recheck_required_bytes"
        )
        self.outputDirectoryURL = outputDirectoryURL
    }

    func verifyAdmission(
        using probe: any R13AvailableCapacityProbing
    ) throws {
        try verify(admissionRequiredBytes, using: probe)
    }

    func verifyLiveRecheck(
        using probe: any R13AvailableCapacityProbing
    ) throws {
        try verify(liveRecheckRequiredBytes, using: probe)
    }

    private func verify(
        _ requiredBytes: UInt64,
        using probe: any R13AvailableCapacityProbing
    ) throws {
        let availableBytes = try probe.availableCapacityForImportantUsage(
            at: outputDirectoryURL
        )
        guard availableBytes >= requiredBytes else {
            throw R13RestartJobError.insufficientDiskSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    private static func checkedAdd(
        _ lhs: UInt64,
        _ rhs: UInt64,
        field: String
    ) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw R13ReleaseHardeningError.arithmeticOverflow(field: field)
        }
        return sum
    }
}

extension R13ReleaseHardeningRuntime {
    static func makeReleaseIdentity(
        job: UpscaleJob,
        scalePlan: R13ReleaseScalePlan,
        modeBinding: R13ReleaseModeBinding,
        source: R13RestartSourceIdentity,
        environment: R13ReleaseEnvironment,
        policyResources: R13ReleasePolicyResourceBinding,
        sourceScanStructure:
            MediaVideoScanStructure = .progressive
    ) throws -> R13ReleaseIdentity {
        let routeIdentity: AppleUpscaleRouteIdentity
        switch scalePlan {
        case .productQualified(let route):
            routeIdentity = try R13ReleaseIdentity.makeProductRoute(
                for: route,
                modeBinding: modeBinding
            )
        case .adaptiveMPSLanczos(let plan):
            routeIdentity = try R13ReleaseIdentity.makeAdaptiveRoute(
                for: plan,
                modeBinding: modeBinding
            )
        }
        let boundPolicyResources = try Self.policyResources(
            for: scalePlan,
            modeBinding: modeBinding,
            base: policyResources
        )
        return try R13ReleaseIdentity(
            R13ReleaseIdentityInput(
                source: R13ReleaseSourceBinding(
                    sha256: source.sha256,
                    byteCount: source.byteCount
                ),
                modeBinding: modeBinding,
                output: R13ReleaseOutputBinding(
                    resolution: job.targetResolution,
                    codec: job.codec,
                    preserveAudio: job.preserveAudio
                ),
                scalePlan: scalePlan,
                routeIdentity: routeIdentity,
                application: environment.application,
                framework: environment.framework,
                runtime: environment.runtime,
                policyResources: boundPolicyResources,
                fallbackHistory: [],
                processingConfiguration:
                    job.processingConfiguration,
                sourceScanStructure: sourceScanStructure,
                deinterlacingAlgorithmIdentity:
                    sourceScanStructure.requiresDeinterlacing
                    ? R13FormatPreservingDeinterlacer
                        .algorithmIdentity
                    : "not_required"
            )
        )
    }

    static func policyResources(
        for scalePlan: R13ReleaseScalePlan,
        modeBinding: R13ReleaseModeBinding,
        base: R13ReleasePolicyResourceBinding
    ) throws -> R13ReleasePolicyResourceBinding {
        switch scalePlan {
        case .productQualified:
            return base
        case .adaptiveMPSLanczos(let plan):
            let policy = R13AdaptiveReleasePolicyDocument(
                plan: plan,
                modeBinding: modeBinding
            )
            let policySHA256 = R13CryptoKitRestartDigest().sha256(
                try R13RestartCanonical.data(policy)
            )
            return try R13ReleasePolicyResourceBinding(
                policySHA256: policySHA256,
                resourceManifestSHA256:
                    base.resourceManifestSHA256
            )
        }
    }

    static func policyResources(
        for scalePlan: R13ReleaseScalePlan,
        base: R13ReleasePolicyResourceBinding
    ) throws -> R13ReleasePolicyResourceBinding {
        try policyResources(
            for: scalePlan,
            modeBinding: R13ReleaseModeBinding(
                requestedMode: .deterministic
            ),
            base: base
        )
    }

    static func makeReleaseIdentity(
        job: UpscaleJob,
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding,
        source: R13RestartSourceIdentity,
        environment: R13ReleaseEnvironment,
        policyResources: R13ReleasePolicyResourceBinding,
        sourceScanStructure:
            MediaVideoScanStructure = .progressive
    ) throws -> R13ReleaseIdentity {
        try makeReleaseIdentity(
            job: job,
            scalePlan: .productQualified(route),
            modeBinding: modeBinding,
            source: source,
            environment: environment,
            policyResources: policyResources,
            sourceScanStructure: sourceScanStructure
        )
    }

    static func makeRestartCore(
        job: UpscaleJob,
        scalePlan: R13ReleaseScalePlan,
        identity: R13ReleaseIdentity,
        modeBinding: R13ReleaseModeBinding,
        source: R13RestartSourceIdentity,
        totalFrameCount: Int
    ) throws -> R13RestartJobCore {
        let expectedRouteID: String
        switch scalePlan {
        case .productQualified(let route):
            expectedRouteID = route.rawValue
        case .adaptiveMPSLanczos:
            expectedRouteID = identity.routeID
        }
        guard identity.routeID == expectedRouteID else {
            throw R13RestartJobError.invalidIdentity(
                field: "processing_route_identity"
            )
        }
        let releaseIdentityComponent =
            try R13RestartProcessingIdentity.releaseIdentityComponent(
                sha256: identity.identitySHA256
            )
        return try R13RestartJobCore(
            jobID: job.identifier,
            source: source,
            processing: R13RestartProcessingIdentity(
                requestedMode: identity.requestedMode.rawValue,
                effectiveMode: identity.effectiveMode.rawValue,
                routeIdentity:
                    "\(expectedRouteID):"
                    + "\(identity.configurationIdentity):"
                    + "\(releaseIdentityComponent):"
                    + "\(identity.processingConfigurationIdentity):"
                    + "\(identity.sourceScanStructure.rawValue):"
                    + identity.deinterlacingAlgorithmIdentity,
                backendIdentity: identity.backendID,
                backendRevision: identity.backendRevision
            ),
            output: R13RestartOutputIdentity(
                width: job.targetResolution.width,
                height: job.targetResolution.height,
                pixelFormat: modeBinding.executionFormat.fourCC,
                codec: job.codec.rawValue,
                audioPolicy: job.preserveAudio ? "preserve" : "omit",
                colorPrimaries:
                    modeBinding.executionFormat.colorPrimaries,
                transferFunction:
                    modeBinding.executionFormat.transferFunction,
                yCbCrMatrix:
                    modeBinding.executionFormat.yCbCrMatrix,
                chromaLocation:
                    modeBinding.executionFormat.chromaLocation,
                alphaMode:
                    modeBinding.executionFormat.alphaMode == "none"
                    ? nil
                    : modeBinding.executionFormat.alphaMode,
                masteringDisplaySHA256:
                    modeBinding.executionFormat
                        .displayVolumeSHA256,
                contentLightLevelSHA256:
                    modeBinding.executionFormat
                        .contentLightLevelSHA256
            ),
            totalFrameCount: totalFrameCount
        )
    }

    static func makeRestartCore(
        job: UpscaleJob,
        route: R03ScaleRoute,
        identity: R13ReleaseIdentity,
        modeBinding: R13ReleaseModeBinding? = nil,
        source: R13RestartSourceIdentity,
        totalFrameCount: Int
    ) throws -> R13RestartJobCore {
        let resolvedModeBinding = modeBinding
            ?? R13ReleaseModeBinding(
                requestedMode: identity.requestedMode,
                enginePreference: identity.enginePreference
            )
        return try makeRestartCore(
            job: job,
            scalePlan: .productQualified(route),
            identity: identity,
            modeBinding: resolvedModeBinding,
            source: source,
            totalFrameCount: totalFrameCount
        )
    }

    static func processingSourceResolution(
        for scalePlan: R13ReleaseScalePlan
    ) -> VideoResolution {
        switch scalePlan {
        case .productQualified(let route):
            return route.canonicalSourceResolution
        case .adaptiveMPSLanczos(let plan):
            return plan.processingSourceResolution
        }
    }

    static func expectedOutputBytes(
        source: SourceProfile,
        sourceByteCount: UInt64,
        job: UpscaleJob
    ) throws -> UInt64 {
        let conservativeVideoBytes = try expectedEncodedVideoBytes(
            source: source,
            sourceByteCount: sourceByteCount,
            job: job
        )
        guard job.preserveAudio, source.hasAudio else {
            return conservativeVideoBytes
        }
        let (expectedOutputBytes, overflow) = conservativeVideoBytes
            .addingReportingOverflow(sourceByteCount)
        guard !overflow else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "expected_output_bytes"
            )
        }
        return expectedOutputBytes
    }

    static func expectedFinalizationPeakBytes(
        source: SourceProfile,
        sourceByteCount: UInt64,
        job: UpscaleJob
    ) throws -> UInt64 {
        let conservativeVideoBytes = try expectedEncodedVideoBytes(
            source: source,
            sourceByteCount: sourceByteCount,
            job: job
        )
        let expectedFinalOutputBytes = try expectedOutputBytes(
            source: source,
            sourceByteCount: sourceByteCount,
            job: job
        )
        let (peakBytes, overflow) = conservativeVideoBytes
            .addingReportingOverflow(expectedFinalOutputBytes)
        guard !overflow else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "expected_finalization_peak_bytes"
            )
        }
        return peakBytes
    }

    static func expectedEncodedVideoBytes(
        source: SourceProfile,
        sourceByteCount: UInt64,
        job: UpscaleJob
    ) throws -> UInt64 {
        let bitRate = ProductVideoOutputSettings.estimatedBitRate(
            width: job.targetResolution.width,
            height: job.targetResolution.height,
            codec: job.codec
        )
        guard source.durationSeconds.isFinite,
              source.durationSeconds >= 0 else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "expected_output_duration"
            )
        }
        let estimated = ceil(
            Double(bitRate) * source.durationSeconds / 8
        )
        guard estimated.isFinite,
              estimated >= 0,
              estimated < Double(UInt64.max) else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "expected_output_bytes"
            )
        }
        let expectedVideoBytes = max(UInt64(estimated), 1)
        let conservativeVideoBytes = max(
            sourceByteCount,
            expectedVideoBytes
        )
        return conservativeVideoBytes
    }

    static func requiredWorkingMemoryBytes(
        source: VideoResolution,
        target: VideoResolution,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ) throws -> UInt64 {
        let sourceCounts = try R13NV12Frame.expectedPlaneByteCounts(
            width: source.width,
            height: source.height,
            pixelFormat: pixelFormat
        )
        let targetCounts = try R13NV12Frame.expectedPlaneByteCounts(
            width: target.width,
            height: target.height,
            pixelFormat: pixelFormat
        )
        let (combined, addOverflow) = UInt64(sourceCounts.total)
            .addingReportingOverflow(UInt64(targetCounts.total))
        let (buffered, multiplyOverflow) = combined
            .multipliedReportingOverflow(
                by: UInt64(R03DeterministicBackend.outputPoolCapacity)
            )
        let (required, reserveOverflow) = buffered
            .addingReportingOverflow(67_108_864)
        guard !addOverflow,
              !multiplyOverflow,
              !reserveOverflow else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "required_working_memory_bytes"
            )
        }
        return required
    }

    static func requiredOutputVolumeBytes(
        expectedOutputBytes: UInt64
    ) throws -> UInt64 {
        let (required, overflow) = expectedOutputBytes
            .addingReportingOverflow(67_108_864)
        guard !overflow else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "required_output_volume_bytes"
            )
        }
        return required
    }

    static func validateCombinedStorageCapacity(
        _ receipt: R13StoragePreflightReceipt,
        minimumFreeDiskBytes: UInt64
    ) throws {
        let (required, overflow) = receipt.requiredBytes
            .addingReportingOverflow(minimumFreeDiskBytes)
        guard !overflow else {
            throw R13ReleaseHardeningError.arithmeticOverflow(
                field: "combined_storage_required_bytes"
            )
        }
        guard receipt.availableBytes >= required else {
            throw R13RestartJobError.insufficientDiskSpace(
                requiredBytes: required,
                availableBytes: receipt.availableBytes
            )
        }
    }

}
