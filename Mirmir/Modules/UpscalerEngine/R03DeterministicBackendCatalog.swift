import Foundation

enum R03BaselineSubjectID: String, CaseIterable, Hashable, Sendable {
    case mpsLanczos = "r03.mps.lanczos"
    case mpsBilinear = "r03.mps.bilinear"
    case coreImageLanczos = "r03.core-image.lanczos"
    case coreImageBicubic = "r03.core-image.bicubic"
    case vImageLanczos3 = "r03.vimage.lanczos-3"
    case vImageLanczos5 = "r03.vimage.lanczos-5"
    case vtPixelTransfer = "r03.vt-pixel-transfer"
    case ashCustomMetal = "r03.ash-custom-metal"
    case mpsGuidedFilter = "r03.mps.guided-filter"
    case coreImageEdgePreserve = "r03.core-image.edge-preserve"
}

enum R03BaselineSubjectKind: String, Hashable, Sendable {
    case wholeFrameBackend = "whole_frame_backend"
    case supportStage = "support_stage"
}

enum R03BaselineQualificationRole: String, Hashable, Sendable {
    case deterministicGPUQualityBaseline = "deterministic_gpu_quality_baseline"
    case diagnosticFastLowerBound = "diagnostic_fast_lower_bound"
    case compatibilityReference = "compatibility_reference"
    case tunableReferenceFallback = "tunable_reference_fallback"
    case cpuReference = "cpu_reference"
    case highQualityCPUComparator = "high_quality_cpu_comparator"
    case scalingConversionReference = "scaling_conversion_reference"
    case retainedReferenceComparator = "retained_reference_comparator"
    case maskAndChromaSupport = "mask_and_chroma_support"
}

enum R03ProductDefaultEligibility: String, Hashable, Sendable {
    case candidateAfterObservedQualification = "candidate_after_observed_qualification"
    case ineligibleReferenceRole = "ineligible_reference_role"
    case ineligibleSupportStage = "ineligible_support_stage"
}

enum R03BaselineRouteID: String, CaseIterable, Hashable, Sendable {
    case scale3Over2 = "scale_3_over_2"
    case scale2x = "scale_2x"
    case guidedSupport1x = "guided_support_1x"
    case edgePreserveSupport2x = "edge_preserve_support_2x"
}

enum R03ScaleRoute: String, CaseIterable, Hashable, Sendable {
    case scale3Over2 = "scale_3_over_2"
    case scale2x = "scale_2x"

    var routeID: R03BaselineRouteID {
        switch self {
        case .scale3Over2:
            return .scale3Over2
        case .scale2x:
            return .scale2x
        }
    }

    var scaleNumerator: Int {
        switch self {
        case .scale3Over2:
            return 3
        case .scale2x:
            return 2
        }
    }

    var scaleDenominator: Int {
        switch self {
        case .scale3Over2:
            return 2
        case .scale2x:
            return 1
        }
    }

    var canonicalSourceResolution: VideoResolution {
        switch self {
        case .scale3Over2:
            return .p720
        case .scale2x:
            return .p1080
        }
    }

    var canonicalTargetResolution: VideoResolution {
        switch self {
        case .scale3Over2:
            return .p1080
        case .scale2x:
            return .p2160
        }
    }

    func matches(
        source: VideoResolution,
        target: VideoResolution
    ) -> Bool {
        source == canonicalSourceResolution
            && target == canonicalTargetResolution
    }
}

struct R03BaselineSubjectDescriptor: Hashable, Sendable {
    let id: R03BaselineSubjectID
    let kind: R03BaselineSubjectKind
    let capabilityID: String
    let frameworkIdentity: String
    let qualificationRole: R03BaselineQualificationRole
    let productDefaultEligibility: R03ProductDefaultEligibility
    let routeIDs: [R03BaselineRouteID]

    var capabilityRole: AppleUpscaleCapabilityRole {
        switch kind {
        case .wholeFrameBackend:
            return .primaryScaler
        case .supportStage:
            return .supportFilter
        }
    }

    func configurationIdentity(for route: R03ScaleRoute) -> String? {
        guard routeIDs.contains(route.routeID) else { return nil }
        return "\(id.rawValue).\(route.rawValue).420v-bt709-video-left.v1"
    }
}

enum R03DeterministicBackendCatalog {
    static let backendRevision = "1"
    static let policyIdentity = "r03.fixture-only.v1"
    static let materialDecisionIdentity = "r03.preregistered-baseline.v1"

    static let subjects: [R03BaselineSubjectDescriptor] = [
        descriptor(
            .mpsLanczos,
            capabilityID: "A11",
            framework: "MetalPerformanceShaders",
            role: .deterministicGPUQualityBaseline,
            eligibility: .candidateAfterObservedQualification
        ),
        descriptor(
            .mpsBilinear,
            capabilityID: "A12",
            framework: "MetalPerformanceShaders",
            role: .diagnosticFastLowerBound,
            eligibility: .ineligibleReferenceRole
        ),
        descriptor(
            .coreImageLanczos,
            capabilityID: "A14",
            framework: "CoreImage",
            role: .compatibilityReference,
            eligibility: .ineligibleReferenceRole
        ),
        descriptor(
            .coreImageBicubic,
            capabilityID: "A14",
            framework: "CoreImage",
            role: .tunableReferenceFallback,
            eligibility: .ineligibleReferenceRole
        ),
        descriptor(
            .vImageLanczos3,
            capabilityID: "A16",
            framework: "Accelerate",
            role: .cpuReference,
            eligibility: .ineligibleReferenceRole
        ),
        descriptor(
            .vImageLanczos5,
            capabilityID: "A16",
            framework: "Accelerate",
            role: .highQualityCPUComparator,
            eligibility: .ineligibleReferenceRole
        ),
        descriptor(
            .vtPixelTransfer,
            capabilityID: "A06",
            framework: "VideoToolbox",
            role: .scalingConversionReference,
            eligibility: .ineligibleReferenceRole
        ),
        descriptor(
            .ashCustomMetal,
            capabilityID: "A17",
            framework: "Metal",
            role: .retainedReferenceComparator,
            eligibility: .ineligibleReferenceRole
        ),
        supportDescriptor(
            .mpsGuidedFilter,
            capabilityID: "A13",
            framework: "MetalPerformanceShaders",
            routeID: .guidedSupport1x
        ),
        supportDescriptor(
            .coreImageEdgePreserve,
            capabilityID: "A15",
            framework: "CoreImage",
            routeID: .edgePreserveSupport2x
        )
    ]

    static var wholeFrameSubjects: [R03BaselineSubjectDescriptor] {
        subjects.filter { $0.kind == .wholeFrameBackend }
    }

    static var supportStageSubjects: [R03BaselineSubjectDescriptor] {
        subjects.filter { $0.kind == .supportStage }
    }

    static func subject(
        _ id: R03BaselineSubjectID
    ) -> R03BaselineSubjectDescriptor? {
        subjects.first { $0.id == id }
    }

    static func makeFixtureCapability(
        for id: R03BaselineSubjectID
    ) throws -> AppleUpscaleCapability {
        guard let subject = subject(id) else {
            preconditionFailure("The frozen R03 catalog must contain every subject ID")
        }
        return try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(subject.capabilityID),
            role: subject.capabilityRole,
            frameworkIdentity: subject.frameworkIdentity,
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
    }

    static func makeNotObservedCapability(
        for id: R03BaselineSubjectID
    ) throws -> AppleUpscaleCapability {
        guard let subject = subject(id) else {
            preconditionFailure("The frozen R03 catalog must contain every subject ID")
        }
        return try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(subject.capabilityID),
            role: subject.capabilityRole,
            frameworkIdentity: subject.frameworkIdentity,
            observationStatus: .notObserved,
            runtimeDisposition: .diagnosticOnly,
            backendEligibility: .notEvaluated
        )
    }

    static func makeFixtureCapabilityRegistry() throws -> AppleUpscaleCapabilityRegistry {
        try AppleUpscaleCapabilityRegistry(
            capabilities: uniqueSubjectsByCapabilityID.map { subject in
                try makeFixtureCapability(for: subject.id)
            }
        )
    }

    static func makeNotObservedCapabilityRegistry() throws -> AppleUpscaleCapabilityRegistry {
        try AppleUpscaleCapabilityRegistry(
            capabilities: uniqueSubjectsByCapabilityID.map { subject in
                try makeNotObservedCapability(for: subject.id)
            }
        )
    }

    private static var uniqueSubjectsByCapabilityID: [R03BaselineSubjectDescriptor] {
        var seenCapabilityIDs: Set<String> = []
        return subjects.filter { subject in
            seenCapabilityIDs.insert(subject.capabilityID).inserted
        }
    }

    private static func descriptor(
        _ id: R03BaselineSubjectID,
        capabilityID: String,
        framework: String,
        role: R03BaselineQualificationRole,
        eligibility: R03ProductDefaultEligibility
    ) -> R03BaselineSubjectDescriptor {
        R03BaselineSubjectDescriptor(
            id: id,
            kind: .wholeFrameBackend,
            capabilityID: capabilityID,
            frameworkIdentity: framework,
            qualificationRole: role,
            productDefaultEligibility: eligibility,
            routeIDs: [.scale3Over2, .scale2x]
        )
    }

    private static func supportDescriptor(
        _ id: R03BaselineSubjectID,
        capabilityID: String,
        framework: String,
        routeID: R03BaselineRouteID
    ) -> R03BaselineSubjectDescriptor {
        R03BaselineSubjectDescriptor(
            id: id,
            kind: .supportStage,
            capabilityID: capabilityID,
            frameworkIdentity: framework,
            qualificationRole: .maskAndChromaSupport,
            productDefaultEligibility: .ineligibleSupportStage,
            routeIDs: [routeID]
        )
    }
}
