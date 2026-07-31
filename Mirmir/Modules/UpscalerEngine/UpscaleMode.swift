import Foundation

public enum UpscaleMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case auto
    case quality
    case fast
    case deterministic
    case smoothMotion = "smooth_motion"

    public var id: String { rawValue }
}

enum R13ReleaseScalerKind:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable {
    case highQualityVImage = "vimage_lanczos_high_quality"
    case fastMPSBilinear = "mps_bilinear"
    case deterministicMPSLanczos = "mps_lanczos"

    var subjectID: R03BaselineSubjectID {
        switch self {
        case .highQualityVImage:
            return .vImageLanczos5
        case .fastMPSBilinear:
            return .mpsBilinear
        case .deterministicMPSLanczos:
            return R03A11ProductAdmission.subjectID
        }
    }

    var capabilityID: String {
        guard let subject = R03DeterministicBackendCatalog.subject(subjectID)
        else {
            preconditionFailure(
                "Every release scaler must remain in the R03 backend catalog."
            )
        }
        return subject.capabilityID
    }

    var frameworkIdentity: String {
        guard let subject = R03DeterministicBackendCatalog.subject(subjectID)
        else {
            preconditionFailure(
                "Every release scaler must retain a framework identity."
            )
        }
        return subject.frameworkIdentity
    }

    func configurationIdentity(
        for route: R03ScaleRoute
    ) -> String? {
        R03DeterministicBackendCatalog
            .subject(subjectID)?
            .configurationIdentity(for: route)
    }

    func adaptiveConfigurationIdentity(
        for plan: R13AdaptiveScalePlan
    ) -> String {
        "\(rawValue).adaptive."
            + "\(plan.processingSourceResolution.width)x"
            + "\(plan.processingSourceResolution.height)-to-"
            + "\(plan.targetResolution.width)x"
            + "\(plan.targetResolution.height).420v-bt709-video-left.v1"
    }

    var adaptiveRouteID: String {
        "adaptive_\(rawValue)"
    }

    var policyIdentity: String {
        switch self {
        case .highQualityVImage:
            return "r13.quality.vimage-high-quality.no-fallback.v1"
        case .fastMPSBilinear:
            return "r13.fast.mps-bilinear.no-fallback.v1"
        case .deterministicMPSLanczos:
            return R03A11ProductAdmission.policyIdentity
        }
    }

    var materialDecisionIdentity: String {
        switch self {
        case .highQualityVImage:
            return "r13.quality.vimage-high-quality-resampling.v1"
        case .fastMPSBilinear:
            return "r13.fast.mps-bilinear-resampling.v1"
        case .deterministicMPSLanczos:
            return R03A11ProductAdmission.materialDecisionIdentity
        }
    }
}

enum R13ReleaseOrchestrationKind:
    String,
    CaseIterable,
    Hashable,
    Sendable {
    case none
    case automatic = "ash_auto"
    case quality = "quality_router"
    case fast = "fast_router"

    var capabilityID: String {
        switch self {
        case .none:
            preconditionFailure(
                "Direct release modes use their scaler capability."
            )
        case .automatic:
            return "R13-ASH-AUTO"
        case .quality:
            return "R13-QUALITY-ROUTER"
        case .fast:
            return "R13-FAST-ROUTER"
        }
    }

    var backendID: String {
        switch self {
        case .none:
            preconditionFailure(
                "Direct release modes use their scaler backend."
            )
        case .automatic:
            return "r13.ash.auto"
        case .quality:
            return "r13.quality.router"
        case .fast:
            return "r13.fast.router"
        }
    }

    var policyIdentity: String {
        switch self {
        case .none:
            preconditionFailure(
                "Direct release modes use their scaler policy."
            )
        case .automatic:
            return "r13.ash.auto.content-resource-hysteresis.v1"
        case .quality:
            return "r13.quality.native-preferred-fallback.v1"
        case .fast:
            return "r13.fast.latency-preferred-fallback.v1"
        }
    }

    var materialDecisionIdentity: String {
        switch self {
        case .none:
            preconditionFailure(
                "Direct release modes use their scaler decision."
            )
        case .automatic:
            return "r13.ash.auto.multi-engine-whole-frame.v1"
        case .quality:
            return "r13.quality.multi-engine-whole-frame.v1"
        case .fast:
            return "r13.fast.multi-engine-whole-frame.v1"
        }
    }
}

struct R13ReleaseModeBinding: Hashable, Sendable {
    let requestedMode: UpscaleMode
    let enginePreference: UpscaleEnginePreference
    let effectiveMode: UpscaleMode
    let scalerKind: R13ReleaseScalerKind
    let orchestrationKind: R13ReleaseOrchestrationKind
    let executionFormat: R13ReleaseVideoFormatBinding
    let usesFormatPreservingFallback: Bool
    let capabilityID: String
    let backendID: String
    let backendRevision: String
    let policyIdentity: String
    let materialDecisionIdentity: String

    var frameworkIdentity: String {
        return orchestrationKind == .none
            ? scalerKind.frameworkIdentity
            : "AppleNativeMultiEngine"
    }

    var usesProductOrchestration: Bool {
        orchestrationKind != .none
    }

    func configurationIdentity(
        for route: R03ScaleRoute
    ) -> String? {
        if usesFormatPreservingFallback {
            return "\(backendID).\(route.rawValue)."
                + "\(executionFormat.identityComponent).v1"
        }
        if orchestrationKind == .none {
            return scalerKind.configurationIdentity(for: route)
        }
        return "\(backendID).\(route.rawValue)."
            + "\(executionFormat.identityComponent).v1"
    }

    func adaptiveConfigurationIdentity(
        for plan: R13AdaptiveScalePlan
    ) -> String {
        if usesFormatPreservingFallback {
            return "\(backendID).adaptive."
                + "\(plan.processingSourceResolution.width)x"
                + "\(plan.processingSourceResolution.height)-to-"
                + "\(plan.targetResolution.width)x"
                + "\(plan.targetResolution.height)."
                + "\(executionFormat.identityComponent).v1"
        }
        if orchestrationKind == .none {
            return scalerKind.adaptiveConfigurationIdentity(
                for: plan
            )
        }
        return "\(backendID).adaptive."
            + "\(plan.processingSourceResolution.width)x"
            + "\(plan.processingSourceResolution.height)-to-"
            + "\(plan.targetResolution.width)x"
            + "\(plan.targetResolution.height)."
            + "fallback-\(scalerKind.rawValue)."
            + "\(executionFormat.identityComponent).v1"
    }

    var adaptiveRouteID: String {
        if usesFormatPreservingFallback {
            return orchestrationKind == .none
                ? "adaptive_format_preserving_"
                    + "\(scalerKind.rawValue)"
                : "adaptive_format_preserving_"
                    + "\(orchestrationKind.rawValue)"
        }
        return orchestrationKind == .none
            ? scalerKind.adaptiveRouteID
            : "adaptive_\(orchestrationKind.rawValue)"
    }

    init(
        requestedMode: UpscaleMode,
        enginePreference: UpscaleEnginePreference = .automatic
    ) {
        self.requestedMode = requestedMode
        self.enginePreference = enginePreference
        executionFormat = .canonicalNV12
        usesFormatPreservingFallback = false
        switch enginePreference {
        case .automatic:
            switch requestedMode {
            case .auto:
                effectiveMode = .auto
                scalerKind = .highQualityVImage
                orchestrationKind = .automatic
            case .quality:
                effectiveMode = .quality
                scalerKind = .highQualityVImage
                orchestrationKind = .quality
            case .fast:
                effectiveMode = .fast
                scalerKind = .fastMPSBilinear
                orchestrationKind = .fast
            case .deterministic:
                effectiveMode = .deterministic
                scalerKind = .deterministicMPSLanczos
                orchestrationKind = .none
            case .smoothMotion:
                effectiveMode = .smoothMotion
                scalerKind = .highQualityVImage
                orchestrationKind = .quality
            }
        case .accelerateVImageHighQuality:
            effectiveMode =
                requestedMode == .smoothMotion
                    ? .smoothMotion
                    : .quality
            scalerKind = .highQualityVImage
            orchestrationKind = .none
        case .mpsBilinear:
            effectiveMode =
                requestedMode == .smoothMotion
                    ? .smoothMotion
                    : .fast
            scalerKind = .fastMPSBilinear
            orchestrationKind = .none
        case .mpsLanczos:
            effectiveMode =
                requestedMode == .smoothMotion
                    ? .smoothMotion
                    : .deterministic
            scalerKind = .deterministicMPSLanczos
            orchestrationKind = .none
        }
        if orchestrationKind == .none {
            capabilityID = scalerKind.capabilityID
            backendID = scalerKind.subjectID.rawValue
            backendRevision =
                R03DeterministicBackendCatalog.backendRevision
            policyIdentity = scalerKind.policyIdentity
            materialDecisionIdentity =
                scalerKind.materialDecisionIdentity
        } else {
            capabilityID = orchestrationKind.capabilityID
            backendID = orchestrationKind.backendID
            backendRevision = "r13.product-router.v1"
            policyIdentity = orchestrationKind.policyIdentity
            materialDecisionIdentity =
                orchestrationKind.materialDecisionIdentity
        }
    }

    func resolving(
        videoFormat: MediaVideoFormat
    ) -> R13ReleaseModeBinding {
        let format = R13ReleaseVideoFormatBinding(videoFormat)
        guard !format.isCanonicalNV12 else {
            return self
        }
        return R13ReleaseModeBinding(
            source: self,
            executionFormat: format
        )
    }

    var canonicalReconstruction: R13ReleaseModeBinding {
        let base = R13ReleaseModeBinding(
            requestedMode: requestedMode,
            enginePreference: enginePreference
        )
        guard !executionFormat.isCanonicalNV12 else {
            return base
        }
        return R13ReleaseModeBinding(
            source: base,
            executionFormat: executionFormat
        )
    }

    private init(
        source: R13ReleaseModeBinding,
        executionFormat: R13ReleaseVideoFormatBinding
    ) {
        requestedMode = source.requestedMode
        enginePreference = source.enginePreference
        effectiveMode = source.effectiveMode
        scalerKind = source.scalerKind
        orchestrationKind = source.orchestrationKind
        self.executionFormat = executionFormat
        usesFormatPreservingFallback = true
        capabilityID = source.capabilityID
        backendID = source.backendID
        backendRevision = source.backendRevision
        policyIdentity =
            source.policyIdentity
            + ".format-preserving."
            + "\(executionFormat.pixelStorage).v2"
        materialDecisionIdentity =
            source.materialDecisionIdentity
            + ".format-preserving."
            + "\(executionFormat.pixelStorage).v2"
    }
}

enum R13ReleaseModePolicy {
    static func availability(
        for _: UpscaleMode
    ) -> UpscalerEngineAvailability {
        .available
    }

    static func binding(for mode: UpscaleMode) -> R13ReleaseModeBinding {
        R13ReleaseModeBinding(requestedMode: mode)
    }

    static func binding(
        for mode: UpscaleMode,
        enginePreference: UpscaleEnginePreference
    ) -> R13ReleaseModeBinding {
        R13ReleaseModeBinding(
            requestedMode: mode,
            enginePreference: enginePreference
        )
    }

    static func nativeVideoToolboxBinding(
        for mode: UpscaleMode,
        enginePreference: UpscaleEnginePreference,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution
    ) -> R04VideoToolboxNativeRouteBinding? {
        guard enginePreference == .automatic else { return nil }
        let intent: R04VideoToolboxNativeRouteIntent
        switch mode {
        case .auto, .quality, .smoothMotion:
            intent = .quality
        case .fast:
            intent = .lowLatency
        case .deterministic:
            return nil
        }
        return R04VideoToolboxNativeRouteSelector.exactBinding(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            intent: intent
        )
    }
}
