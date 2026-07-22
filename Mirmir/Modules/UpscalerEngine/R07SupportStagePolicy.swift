import CoreVideo
import Foundation

enum R07SupportCapabilityID: String, CaseIterable, Hashable, Sendable {
    case temporalNoiseFilter = "A04"
    case temporalAnalyzer = "A05"
    case mpsGuidedFilter = "A13"
    case coreImageEdgePreserve = "A15"
}

enum R07SupportStageRole: String, Hashable, Sendable {
    case temporalNoiseFilter = "r07_temporal_noise_filter"
    case analysisOnly = "analysis_only"
    case supportStage = "support_stage"
}

enum R07ProductGateReason: String, Hashable, Sendable {
    case upstreamNoProductQualifiedPrimaryBackend =
        "upstream_no_product_qualified_primary_backend"
}

struct R07ProductGateResult: Hashable, Sendable {
    let reason: R07ProductGateReason
    let eligibleBackendCount: Int
    let selectedRouteID: String?
    let selectedPlanID: String?
    let outputIdentity: String?
    let disposition: R06ASHDisposition
    let supportStageConstructionAttempted: Bool

    static let blocked = R07ProductGateResult(
        reason: .upstreamNoProductQualifiedPrimaryBackend,
        eligibleBackendCount: 0,
        selectedRouteID: nil,
        selectedPlanID: nil,
        outputIdentity: nil,
        disposition: .blocked,
        supportStageConstructionAttempted: false
    )
}

enum R07A04QualificationStatus: String, CaseIterable, Hashable, Sendable {
    case notObserved = "not_observed"
    case unsupported
    case fixtureAdmitted = "fixture_admitted"
}

enum R07A04AdmissionOutcome: String, Hashable, Sendable {
    case diagnosticNotPlanned = "diagnostic_not_planned"
    case unavailableNotPlanned = "unavailable_not_planned"
    case deterministicFixtureOnlyDescriptor = "deterministic_fixture_only_descriptor"
}

enum R07QualificationEstablishment: String, Hashable, Sendable {
    case notEstablished = "not_established"
}

enum R07A04DiscontinuitySource: String, Hashable, Sendable {
    case derivedFromTemporalState = "derived_from_temporal_state"
}

struct R07TemporalSupportState: Equatable, Sendable {
    let discontinuity: Bool
}

struct R07A04SupportStageDescriptor: Equatable, Sendable {
    let capabilityID: R07SupportCapabilityID
    let role: R07SupportStageRole
    let configurationIdentity: String
    let strengthQ16: R06ASHQ16
    let discontinuity: Bool
    let discontinuitySource: R07A04DiscontinuitySource

    var discontinuityHardcoded: Bool { false }
}

struct R07A04AdmissionResult: Equatable, Sendable {
    let outcome: R07A04AdmissionOutcome
    let descriptor: R07A04SupportStageDescriptor?
    let runtimeQualification: R07QualificationEstablishment
    let productQualification: R07QualificationEstablishment

    var planConstructed: Bool { descriptor != nil }
    var strengthQ16: R06ASHQ16? { descriptor?.strengthQ16 }
}

struct R07A05AnalysisPlan: Hashable, Sendable {
    let capabilityID: R07SupportCapabilityID
    let role: R07SupportStageRole
    let constructSupportStage: Bool

    static let temporalAnalyzer = R07A05AnalysisPlan(
        capabilityID: .temporalAnalyzer,
        role: .analysisOnly,
        constructSupportStage: false
    )
}

enum R07SupportStageConstructionDisposition: String, Hashable, Sendable {
    case forbidden
}

struct R07SupportStageConstructionRejection: Hashable, Sendable {
    let capabilityID: R07SupportCapabilityID
    let disposition: R07SupportStageConstructionDisposition
    let constructionAttempted: Bool

    static let a05 = R07SupportStageConstructionRejection(
        capabilityID: .temporalAnalyzer,
        disposition: .forbidden,
        constructionAttempted: false
    )
}

enum R07SupportPixelFormat: String, Hashable, Sendable {
    case r8 = "R8"
}

struct R07SupportSurfaceDescriptor: Hashable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: R07SupportPixelFormat
}

enum R07InheritedSupportSurfaces: Hashable, Sendable {
    case a13(
        source: R07SupportSurfaceDescriptor,
        guidance: R07SupportSurfaceDescriptor,
        output: R07SupportSurfaceDescriptor
    )
    case a15(
        mask: R07SupportSurfaceDescriptor,
        guidance: R07SupportSurfaceDescriptor,
        output: R07SupportSurfaceDescriptor
    )
}

enum R07InheritedSupportParameters: Hashable, Sendable {
    case a13(kernelSize: Int, epsilon: Float)
    case a15(spatialSigma: Float, lumaSigma: Float)
}

enum R07SupportConformanceScope: String, Hashable, Sendable {
    case descriptorAndAdmissionOnly = "descriptor_and_admission_only"
}

enum R07ReconstructionExecution: String, Hashable, Sendable {
    case notObserved = "not_observed"
}

enum R07OutputClaims: String, Hashable, Sendable {
    case forbidden
}

struct R07InheritedSupportStageDescriptor: Hashable, Sendable {
    let capabilityID: R07SupportCapabilityID
    let role: R07SupportStageRole
    let contract: R03SupportStageContract
    let surfaces: R07InheritedSupportSurfaces
    let parameters: R07InheritedSupportParameters
    let processingIdentity: AppleUpscaleProcessingIdentity
    let productPrimaryBackend: Bool
    let conformanceScope: R07SupportConformanceScope
    let reconstructionExecution: R07ReconstructionExecution
    let outputClaims: R07OutputClaims
}

enum R07SupportStageRequest: Equatable, Sendable {
    case a04(
        qualificationStatus: R07A04QualificationStatus,
        temporalState: R07TemporalSupportState
    )
    case a05Analysis
    case a05SupportStageConstruction
    case a13Descriptor
    case a15Descriptor
}

enum R07SupportStagePolicyOutcome: Equatable, Sendable {
    case blocked(R07ProductGateResult)
    case a04Admission(R07A04AdmissionResult)
    case analysisPlan(R07A05AnalysisPlan)
    case inheritedDescriptor(R07InheritedSupportStageDescriptor)
    case constructionRejected(R07SupportStageConstructionRejection)
}

struct R07SupportStagePolicy: Sendable {
    static let a04ConfigurationIdentity =
        "r07.videotoolbox.temporal-noise-filter.fixture-only.strength-q16-24576.v1"
    static let a04StrengthQ16 = makeA04Strength()
    static let a13Descriptor = makeA13Descriptor()
    static let a15Descriptor = makeA15Descriptor()

    func resolve(
        scope: AppleUpscaleAdmissionScope,
        request: R07SupportStageRequest
    ) -> R07SupportStagePolicyOutcome {
        guard scope != .product else {
            return .blocked(.blocked)
        }

        switch request {
        case .a04(let qualificationStatus, let temporalState):
            return .a04Admission(
                Self.a04Admission(
                    qualificationStatus: qualificationStatus,
                    temporalState: temporalState
                )
            )
        case .a05Analysis:
            return .analysisPlan(.temporalAnalyzer)
        case .a05SupportStageConstruction:
            return .constructionRejected(.a05)
        case .a13Descriptor:
            return .inheritedDescriptor(Self.a13Descriptor)
        case .a15Descriptor:
            return .inheritedDescriptor(Self.a15Descriptor)
        }
    }

    private static func a04Admission(
        qualificationStatus: R07A04QualificationStatus,
        temporalState: R07TemporalSupportState
    ) -> R07A04AdmissionResult {
        let outcome: R07A04AdmissionOutcome
        let descriptor: R07A04SupportStageDescriptor?
        switch qualificationStatus {
        case .notObserved:
            outcome = .diagnosticNotPlanned
            descriptor = nil
        case .unsupported:
            outcome = .unavailableNotPlanned
            descriptor = nil
        case .fixtureAdmitted:
            outcome = .deterministicFixtureOnlyDescriptor
            descriptor = R07A04SupportStageDescriptor(
                capabilityID: .temporalNoiseFilter,
                role: .temporalNoiseFilter,
                configurationIdentity: a04ConfigurationIdentity,
                strengthQ16: a04StrengthQ16,
                discontinuity: temporalState.discontinuity,
                discontinuitySource: .derivedFromTemporalState
            )
        }
        return R07A04AdmissionResult(
            outcome: outcome,
            descriptor: descriptor,
            runtimeQualification: .notEstablished,
            productQualification: .notEstablished
        )
    }

    private static func makeA04Strength() -> R06ASHQ16 {
        do {
            return try R06ASHQ16(24_576)
        } catch {
            preconditionFailure("Frozen R07 A04 strength must be valid: \(error)")
        }
    }

    private static func makeA13Descriptor() -> R07InheritedSupportStageDescriptor {
        let contract = R03SupportStageContract.mpsGuidedFilter
        requireR8(contract.source, field: "a13.source")
        requireR8(contract.guidance, field: "a13.guidance")
        requireR8(contract.output, field: "a13.output")
        return makeInheritedDescriptor(
            capabilityID: .mpsGuidedFilter,
            contract: contract,
            surfaces: .a13(
                source: surface(contract.source),
                guidance: surface(contract.guidance),
                output: surface(contract.output)
            ),
            parameters: .a13(
                kernelSize: R03SupportStageParameters.guidedFilterKernelDiameter,
                epsilon: R03SupportStageParameters.guidedFilterEpsilon
            )
        )
    }

    private static func makeA15Descriptor() -> R07InheritedSupportStageDescriptor {
        let contract = R03SupportStageContract.coreImageEdgePreserve
        requireR8(contract.source, field: "a15.mask")
        requireR8(contract.guidance, field: "a15.guidance")
        requireR8(contract.output, field: "a15.output")
        return makeInheritedDescriptor(
            capabilityID: .coreImageEdgePreserve,
            contract: contract,
            surfaces: .a15(
                mask: surface(contract.source),
                guidance: surface(contract.guidance),
                output: surface(contract.output)
            ),
            parameters: .a15(
                spatialSigma: R03SupportStageParameters.edgePreserveSpatialSigma,
                lumaSigma: R03SupportStageParameters.edgePreserveLumaSigma
            )
        )
    }

    private static func makeInheritedDescriptor(
        capabilityID: R07SupportCapabilityID,
        contract: R03SupportStageContract,
        surfaces: R07InheritedSupportSurfaces,
        parameters: R07InheritedSupportParameters
    ) -> R07InheritedSupportStageDescriptor {
        do {
            let backend = try AppleUpscaleBackendIdentity(
                backendID: contract.subjectID.rawValue,
                backendRevision: R03DeterministicBackendCatalog.backendRevision,
                modelAssetsIdentity: .notRequired
            )
            let route = try AppleUpscaleRouteIdentity(
                backend: backend,
                configurationIdentity: contract.configurationIdentity,
                policyIdentity: R03DeterministicBackendCatalog.policyIdentity,
                materialDecisionIdentity:
                    R03DeterministicBackendCatalog.materialDecisionIdentity
            )
            return R07InheritedSupportStageDescriptor(
                capabilityID: capabilityID,
                role: .supportStage,
                contract: contract,
                surfaces: surfaces,
                parameters: parameters,
                processingIdentity: try AppleUpscaleProcessingIdentity(
                    route: route,
                    fallbackHistory: []
                ),
                productPrimaryBackend: false,
                conformanceScope: .descriptorAndAdmissionOnly,
                reconstructionExecution: .notObserved,
                outputClaims: .forbidden
            )
        } catch {
            preconditionFailure("Frozen R07 inherited support identity must be valid: \(error)")
        }
    }

    private static func surface(
        _ contract: R03SupportImageContract
    ) -> R07SupportSurfaceDescriptor {
        R07SupportSurfaceDescriptor(
            width: contract.width,
            height: contract.height,
            pixelFormat: .r8
        )
    }

    private static func requireR8(
        _ contract: R03SupportImageContract,
        field: String
    ) {
        precondition(
            contract.pixelFormat == kCVPixelFormatType_OneComponent8,
            "Frozen R07 \(field) must inherit the R03 R8 contract"
        )
    }
}
