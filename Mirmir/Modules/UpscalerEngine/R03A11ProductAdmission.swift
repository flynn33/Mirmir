import Foundation

struct R03A11ProductAdmissionAuthorization: Sendable {
    init() {}
}

enum R03DeterministicBackendAdmissionProfile: Hashable, Sendable {
    case fixtureOnly
    case productQualifiedA11
    case productQualifiedReleaseScaler(R13ReleaseScalerKind)

    var admissionScope: AppleUpscaleAdmissionScope {
        switch self {
        case .fixtureOnly:
            return .fixtureOnly
        case .productQualifiedA11, .productQualifiedReleaseScaler:
            return .product
        }
    }

    var policyIdentity: String {
        switch self {
        case .fixtureOnly:
            return R03DeterministicBackendCatalog.policyIdentity
        case .productQualifiedA11:
            return R03A11ProductAdmission.policyIdentity
        case .productQualifiedReleaseScaler(let kind):
            return kind.policyIdentity
        }
    }

    var materialDecisionIdentity: String {
        switch self {
        case .fixtureOnly:
            return R03DeterministicBackendCatalog.materialDecisionIdentity
        case .productQualifiedA11:
            return R03A11ProductAdmission.materialDecisionIdentity
        case .productQualifiedReleaseScaler(let kind):
            return kind.materialDecisionIdentity
        }
    }

    var requiresProductAuthorization: Bool {
        switch self {
        case .fixtureOnly:
            return false
        case .productQualifiedA11, .productQualifiedReleaseScaler:
            return true
        }
    }

    func permits(subject: R03BaselineSubjectDescriptor) -> Bool {
        switch self {
        case .fixtureOnly:
            return true
        case .productQualifiedA11:
            return subject.id == .mpsLanczos
                && subject.kind == .wholeFrameBackend
                && subject.capabilityID == R03A11ProductAdmission.capabilityID
                && subject.frameworkIdentity == R03A11ProductAdmission.frameworkIdentity
                && subject.qualificationRole == .deterministicGPUQualityBaseline
                && subject.productDefaultEligibility == .candidateAfterObservedQualification
                && subject.routeIDs == [
                    .scale3Over2,
                    .scale2x,
                    .scale4x
                ]
        case .productQualifiedReleaseScaler(let kind):
            return subject.id == kind.subjectID
                && subject.kind == .wholeFrameBackend
                && subject.capabilityID == kind.capabilityID
                && subject.frameworkIdentity == kind.frameworkIdentity
                && subject.routeIDs == [
                    .scale3Over2,
                    .scale2x,
                    .scale4x
                ]
        }
    }

    func permits(context: AppleUpscaleSessionContext) -> Bool {
        context.admissionScope == admissionScope
            && context.policyIdentity == policyIdentity
    }

    func permits(capability: AppleUpscaleCapability) -> Bool {
        switch self {
        case .fixtureOnly:
            return capability.backendEligibility == .fixtureOnly
                && capability.isEligible(for: .fixtureOnly)
        case .productQualifiedA11:
            return capability.id.rawValue == R03A11ProductAdmission.capabilityID
                && capability.backendEligibility == .productQualified
                && capability.isEligible(for: .product)
        case .productQualifiedReleaseScaler(let kind):
            return capability.id.rawValue == kind.capabilityID
                && capability.frameworkIdentity == kind.frameworkIdentity
                && capability.backendEligibility == .productQualified
                && capability.isEligible(for: .product)
        }
    }
}

enum R13ReleaseScalerAdmission {
    static func makeProductSessionContext(
        for kind: R13ReleaseScalerKind
    ) throws -> AppleUpscaleSessionContext {
        if kind == .deterministicMPSLanczos {
            return try R03A11ProductAdmission.makeProductSessionContext()
        }
        let capability = try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(kind.capabilityID),
            role: .primaryScaler,
            frameworkIdentity: kind.frameworkIdentity,
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .productQualified
        )
        return try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: .product,
            policyIdentity: kind.policyIdentity
        )
    }
}

enum R03A11ProductAdmission {
    static let subjectID = R03BaselineSubjectID.mpsLanczos
    static let capabilityID = "A11"
    static let frameworkIdentity = "MetalPerformanceShaders"
    static let policyIdentity = "r03.a11.product-qualified.no-fallback.v1"
    static let materialDecisionIdentity =
        "r03.a11.genuine-mps-lanczos-product-admission.v1"

    static func makeProductQualifiedCapability() throws -> AppleUpscaleCapability {
        let subject = productSubject
        return try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(subject.capabilityID),
            role: .primaryScaler,
            frameworkIdentity: subject.frameworkIdentity,
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .productQualified
        )
    }

    static func makeProductQualifiedCapabilityRegistry() throws
        -> AppleUpscaleCapabilityRegistry {
        try AppleUpscaleCapabilityRegistry(
            capabilities: [makeProductQualifiedCapability()]
        )
    }

    static func makeProductSessionContext() throws -> AppleUpscaleSessionContext {
        try AppleUpscaleSessionContext(
            capabilityRegistry: makeProductQualifiedCapabilityRegistry(),
            admissionScope: .product,
            policyIdentity: policyIdentity
        )
    }

    static func makeGenuineMPSLanczosScaler(
        route: R03ScaleRoute,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution
    ) throws -> any R03NV12Scaling {
        try requireExactResolution(
            sourceResolution,
            expected: route.canonicalSourceResolution
        )
        try requireExactResolution(
            targetResolution,
            expected: route.canonicalTargetResolution
        )
        return try R03MPSScaler(mode: .lanczos, route: route)
    }

    private static var productSubject: R03BaselineSubjectDescriptor {
        guard let subject = R03DeterministicBackendCatalog.subject(subjectID),
              R03DeterministicBackendAdmissionProfile.productQualifiedA11
                .permits(subject: subject) else {
            preconditionFailure("The frozen R03 catalog must retain MPS Lanczos as A11")
        }
        return subject
    }

    private static func requireExactResolution(
        _ actual: VideoResolution,
        expected: VideoResolution
    ) throws {
        guard actual == expected else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: actual.width,
                actualHeight: actual.height
            )
        }
    }
}

extension R03DeterministicBackend {
    static func makeProductQualifiedMPSLanczos(
        route: R03ScaleRoute,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in },
        historyGenerationObserver: @escaping R03HistoryGenerationObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        try R03DeterministicBackend(
            subjectID: .mpsLanczos,
            route: route,
            admissionProfile: .productQualifiedA11,
            productAdmissionAuthorization: R03A11ProductAdmissionAuthorization(),
            scalerFactory: { sourceResolution, targetResolution in
                try R03A11ProductAdmission.makeGenuineMPSLanczosScaler(
                    route: route,
                    sourceResolution: sourceResolution,
                    targetResolution: targetResolution
                )
            },
            outputReleaseObserver: outputReleaseObserver,
            historyGenerationObserver: historyGenerationObserver
        )
    }
}
