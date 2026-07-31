import CoreMedia
import CoreVideo
import Foundation

// swiftlint:disable file_length

enum R04VideoToolboxContractError: Error, Equatable, Sendable {
    case invalidScaleFactor(numerator: Int, denominator: Int)
    case scaleDoesNotMatchRoute(R04VideoToolboxRouteID)
    case duplicateSubject(R04VideoToolboxSubjectID)
    case duplicateRoute(R04VideoToolboxRouteID)
    case catalogIdentityMismatch(R04VideoToolboxSubjectID)
}

enum R04VideoToolboxSubjectID: String, CaseIterable, Hashable, Sendable {
    case quality2x = "r04.videotoolbox.quality-2x"
    case quality1p5xContract = "r04.videotoolbox.quality-1p5x-contract"
    case lowLatency1p5x = "r04.videotoolbox.low-latency-1p5x"
    case lowLatency2x = "r04.videotoolbox.low-latency-2x"
    case opticalFlowSupport = "r04.videotoolbox.optical-flow-support"
}

enum R04VideoToolboxNativeRouteIntent: String, Hashable, Sendable {
    case quality
    case lowLatency = "low_latency"
}

struct R04VideoToolboxNativeRouteBinding: Hashable, Sendable {
    let intent: R04VideoToolboxNativeRouteIntent
    let route: R04VideoToolboxRouteDescriptor

    var subjectID: R04VideoToolboxSubjectID { route.subjectID }
    var requiresConfigurationModel: Bool { intent == .quality }
}

enum R04VideoToolboxNativeRouteSelector {
    static func exactBinding(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        intent: R04VideoToolboxNativeRouteIntent
    ) -> R04VideoToolboxNativeRouteBinding? {
        let subjectID: R04VideoToolboxSubjectID?
        switch (sourceResolution, targetResolution, intent) {
        case (.p1080, .p2160, .quality):
            subjectID = .quality2x
        case (.p720, .p1080, .lowLatency):
            subjectID = .lowLatency1p5x
        case (.p1080, .p2160, .lowLatency):
            subjectID = .lowLatency2x
        default:
            subjectID = nil
        }
        guard let subjectID,
              let route = R04VideoToolboxRouteCatalog.route(subjectID),
              route.sourceResolution == sourceResolution,
              route.targetResolution == targetResolution else {
            return nil
        }
        return R04VideoToolboxNativeRouteBinding(intent: intent, route: route)
    }
}

enum R04VideoToolboxRouteID: String, CaseIterable, Hashable, Sendable {
    case quality2x = "quality_2x"
    case quality1p5xContract = "quality_1p5x_contract"
    case lowLatency1p5x = "low_latency_1p5x"
    case lowLatency2x = "low_latency_2x"
    case opticalFlow1080p = "optical_flow_1080p"
}

enum R04VideoToolboxBackendKind: String, Hashable, Sendable {
    case quality
    case lowLatency = "low_latency"
    case optionalFlowSupport = "optional_flow_support"
}

enum R04VideoToolboxRouteGate: String, Hashable, Sendable {
    case runtimeSupportRequired = "runtime_support_required"
    case publicContractUnrepresentable = "public_contract_unrepresentable"
    case exactDimensionQueryRequired = "exact_dimension_query_required"
    case optionalRuntimeSupport = "optional_runtime_support"
}

enum R04VideoToolboxSubmissionMode: String, Hashable, Sendable {
    case sequential
    case random
}

enum R04VideoToolboxProductDefaultEligibility: String, Hashable, Sendable {
    case candidateAfterObservedQualification = "candidate_after_observed_qualification"
    case ineligibleContractRejection = "ineligible_contract_rejection"
    case ineligibleOptionalSupport = "ineligible_optional_support"
}

enum R04VideoToolboxProductQualification: String, Hashable, Sendable {
    case notClaimed = "not_claimed"
}

enum R04VideoToolboxOpticalFlowRole: String, Hashable, Sendable {
    case optionalQualityInput = "optional_quality_input"
    case notApplicable = "not_applicable"
    case optionalSupportOnly = "optional_support_only"
}

struct R04VideoToolboxScaleFactor: Hashable, Sendable {
    let numerator: Int
    let denominator: Int

    init(numerator: Int, denominator: Int) throws {
        guard numerator > 0, denominator > 0 else {
            throw R04VideoToolboxContractError.invalidScaleFactor(
                numerator: numerator,
                denominator: denominator
            )
        }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    static let one = makeStatic(numerator: 1, denominator: 1)
    static let oneAndOneHalf = makeStatic(numerator: 3, denominator: 2)
    static let two = makeStatic(numerator: 2, denominator: 1)

    func matches(
        source: VideoResolution,
        target: VideoResolution
    ) -> Bool {
        let widthLeft = source.width.multipliedReportingOverflow(by: numerator)
        let widthRight = target.width.multipliedReportingOverflow(by: denominator)
        let heightLeft = source.height.multipliedReportingOverflow(by: numerator)
        let heightRight = target.height.multipliedReportingOverflow(by: denominator)
        guard !widthLeft.overflow,
              !widthRight.overflow,
              !heightLeft.overflow,
              !heightRight.overflow else {
            return false
        }
        return widthLeft.partialValue == widthRight.partialValue
            && heightLeft.partialValue == heightRight.partialValue
    }

    private static func makeStatic(
        numerator: Int,
        denominator: Int
    ) -> R04VideoToolboxScaleFactor {
        do {
            return try R04VideoToolboxScaleFactor(
                numerator: numerator,
                denominator: denominator
            )
        } catch {
            preconditionFailure("Static R04 scale factors must be valid: \(error)")
        }
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return first
    }
}

struct R04VideoToolboxTemporalPolicy: Hashable, Sendable {
    let firstFrameSubmissionMode: R04VideoToolboxSubmissionMode
    let continuingSubmissionMode: R04VideoToolboxSubmissionMode
    let suppliesPreviousSource: Bool
    let suppliesPreviousOutput: Bool
    let resetsOnFirstFrame: Bool
    let resetReasons: Set<AppleUpscaleResetReason>

    static let qualitySequential = R04VideoToolboxTemporalPolicy(
        firstFrameSubmissionMode: .random,
        continuingSubmissionMode: .sequential,
        suppliesPreviousSource: true,
        suppliesPreviousOutput: true,
        resetsOnFirstFrame: true,
        resetReasons: [.sceneCut, .discontinuity, .callerRequested]
    )

    static let statelessRandom = R04VideoToolboxTemporalPolicy(
        firstFrameSubmissionMode: .random,
        continuingSubmissionMode: .random,
        suppliesPreviousSource: false,
        suppliesPreviousOutput: false,
        resetsOnFirstFrame: false,
        resetReasons: []
    )

    func submissionMode(
        for boundary: R04VideoToolboxHistoryBoundary
    ) -> R04VideoToolboxSubmissionMode {
        boundary == .continuing
            ? continuingSubmissionMode
            : firstFrameSubmissionMode
    }
}

enum R04VideoToolboxInputTypeIdentity: String, Hashable, Sendable {
    case video
}

enum R04VideoToolboxPrecomputedFlowChoice: String, Hashable, Sendable {
    case optionalPerRequest = "optional_per_request"
    case notApplicable = "not_applicable"
}

enum R04VideoToolboxQualityPriorityIdentity: String, Hashable, Sendable {
    case quality
    case notApplicable = "not_applicable"
}

enum R04VideoToolboxRevisionIdentity: String, Hashable, Sendable {
    case runtimeSelectedNotObserved = "runtime_selected_not_observed"
}

enum R04VideoToolboxSupportedFormatsIdentity: String, Hashable, Sendable {
    case notObserved = "not_observed"
}

enum R04VideoToolboxModelStatusIdentity: String, Hashable, Sendable {
    case notObserved = "not_observed"
    case notRequired = "not_required"
}

enum R04VideoToolboxProcessingModeIdentity: String, Hashable, Sendable {
    case qualityTemporal = "quality_temporal"
    case lowLatencyStateless = "low_latency_stateless"
    case optionalFlowSupport = "optional_flow_support"
}

enum R04VideoToolboxObservedQualityPriority: String, Hashable, Sendable {
    case normal
}

enum R04VideoToolboxObservedModelStatus: String, Hashable, Sendable {
    case notObserved = "not_observed"
    case notRequired = "not_required"
    case downloadRequired = "download_required"
    case downloading
    case ready
    case failed
}

enum R04VideoToolboxObservedProcessingMode: String, Hashable, Sendable {
    case quality
    case lowLatency = "low_latency"
}

struct R04ObservedQualityConfiguration: Hashable, Sendable {
    let frameWidth: Int
    let frameHeight: Int
    let integerScaleFactor: Int
    let inputType: R04VideoToolboxInputTypeIdentity
    let usesPrecomputedFlow: Bool
    let qualityPriority: R04VideoToolboxObservedQualityPriority
    let revision: Int

    var stableIdentity: String {
        [
            "quality",
            "width-\(frameWidth)",
            "height-\(frameHeight)",
            "integer-scale-\(integerScaleFactor)",
            "input-\(inputType.rawValue)",
            "precomputed-flow-\(usesPrecomputedFlow ? "true" : "false")",
            "priority-\(qualityPriority.rawValue)",
            "revision-\(revision)"
        ].joined(separator: ".")
    }
}

struct R04ObservedLowLatencyConfiguration: Hashable, Sendable {
    let frameWidth: Int
    let frameHeight: Int
    let scaleFactor: Float

    var stableIdentity: String {
        [
            "low-latency",
            "width-\(frameWidth)",
            "height-\(frameHeight)",
            "float-scale-bits-\(String(format: "%08x", scaleFactor.bitPattern))"
        ].joined(separator: ".")
    }
}

enum R04VideoToolboxNativeConfigIdentity: Hashable, Sendable {
    case quality(R04ObservedQualityConfiguration)
    case lowLatency(R04ObservedLowLatencyConfiguration)

    var stableIdentity: String {
        switch self {
        case .quality(let configuration):
            return configuration.stableIdentity
        case .lowLatency(let configuration):
            return configuration.stableIdentity
        }
    }
}

struct R04VideoToolboxConfigurationDiagnostics: Hashable, Sendable {
    let nativeIdentity: R04VideoToolboxNativeConfigIdentity
    let supportedPixelFormats: [OSType]
    let modelStatus: R04VideoToolboxObservedModelStatus
    let processingMode: R04VideoToolboxObservedProcessingMode

    init(
        nativeIdentity: R04VideoToolboxNativeConfigIdentity,
        supportedPixelFormats: [OSType],
        modelStatus: R04VideoToolboxObservedModelStatus,
        processingMode: R04VideoToolboxObservedProcessingMode
    ) {
        self.nativeIdentity = nativeIdentity
        self.supportedPixelFormats = Array(Set(supportedPixelFormats)).sorted()
        self.modelStatus = modelStatus
        self.processingMode = processingMode
    }

    var stableIdentity: String {
        let formats = supportedPixelFormats
            .map { String(format: "%08x", $0) }
            .joined(separator: ",")
        return [
            nativeIdentity.stableIdentity,
            "formats-\(formats)",
            "model-\(modelStatus.rawValue)",
            "mode-\(processingMode.rawValue)"
        ].joined(separator: ".")
    }
}

struct R04VideoToolboxConfigurationContract: Hashable, Sendable {
    let frameWidth: Int
    let frameHeight: Int
    let scaleFactorIdentity: String
    let inputType: R04VideoToolboxInputTypeIdentity
    let precomputedFlowChoice: R04VideoToolboxPrecomputedFlowChoice
    let qualityPriority: R04VideoToolboxQualityPriorityIdentity
    let revision: R04VideoToolboxRevisionIdentity
    let supportedFormats: R04VideoToolboxSupportedFormatsIdentity
    let modelStatus: R04VideoToolboxModelStatusIdentity
    let processingMode: R04VideoToolboxProcessingModeIdentity
    let exactDimensionQueryRequired: Bool

    var stableIdentity: String {
        [
            "width-\(frameWidth)",
            "height-\(frameHeight)",
            "scale-\(scaleFactorIdentity)",
            "input-\(inputType.rawValue)",
            "flow-\(precomputedFlowChoice.rawValue)",
            "priority-\(qualityPriority.rawValue)",
            "revision-\(revision.rawValue)",
            "formats-\(supportedFormats.rawValue)",
            "model-\(modelStatus.rawValue)",
            "mode-\(processingMode.rawValue)",
            "dimension-query-\(exactDimensionQueryRequired ? "required" : "not_required")"
        ].joined(separator: ".")
    }
}

struct R04VideoToolboxRouteDescriptor: Hashable, Sendable {
    let subjectID: R04VideoToolboxSubjectID
    let routeID: R04VideoToolboxRouteID
    let capabilityID: String
    let backendKind: R04VideoToolboxBackendKind
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let scaleFactor: R04VideoToolboxScaleFactor
    let gate: R04VideoToolboxRouteGate
    let configurationContract: R04VideoToolboxConfigurationContract
    let temporalPolicy: R04VideoToolboxTemporalPolicy
    let opticalFlowRole: R04VideoToolboxOpticalFlowRole
    let productDefaultEligibility: R04VideoToolboxProductDefaultEligibility
    let productQualification: R04VideoToolboxProductQualification

    init(
        subjectID: R04VideoToolboxSubjectID,
        routeID: R04VideoToolboxRouteID,
        capabilityID: String,
        backendKind: R04VideoToolboxBackendKind,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        scaleFactor: R04VideoToolboxScaleFactor,
        gate: R04VideoToolboxRouteGate,
        configurationContract: R04VideoToolboxConfigurationContract,
        temporalPolicy: R04VideoToolboxTemporalPolicy,
        opticalFlowRole: R04VideoToolboxOpticalFlowRole,
        productDefaultEligibility: R04VideoToolboxProductDefaultEligibility,
        productQualification: R04VideoToolboxProductQualification = .notClaimed
    ) throws {
        guard scaleFactor.matches(source: sourceResolution, target: targetResolution) else {
            throw R04VideoToolboxContractError.scaleDoesNotMatchRoute(routeID)
        }
        guard configurationContract.frameWidth == sourceResolution.width,
              configurationContract.frameHeight == sourceResolution.height else {
            throw R04VideoToolboxContractError.catalogIdentityMismatch(subjectID)
        }
        self.subjectID = subjectID
        self.routeID = routeID
        self.capabilityID = try requireAppleUpscaleIdentity(
            capabilityID,
            field: "r04_capability_id"
        )
        self.backendKind = backendKind
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.scaleFactor = scaleFactor
        self.gate = gate
        self.configurationContract = configurationContract
        self.temporalPolicy = temporalPolicy
        self.opticalFlowRole = opticalFlowRole
        self.productDefaultEligibility = productDefaultEligibility
        self.productQualification = productQualification
    }

    var configurationIdentity: String {
        "\(subjectID.rawValue).\(routeID.rawValue).\(configurationContract.stableIdentity).420v-bt709-video-left.v1"
    }
}

enum R04VideoToolboxRouteRejectionReason: String, Hashable, Sendable {
    case publicContractUnrepresentable = "public_contract_unrepresentable"
    case exactDimensionQueryRejected = "exact_dimension_query_rejected"
    case sessionContractMismatch = "r04_session_contract_mismatch"
    case productScopeForbidden = "r04_product_scope_forbidden"
    case productQualificationRequired = "r04_product_qualification_required"
    case optionalSupportOnly = "r04_optional_support_only"
    case frameContractMismatch = "r04_frame_contract_mismatch"
    case operationCancelled = "operation_cancelled"
    case runtimeRejected = "r04_runtime_rejected"
    case configurationIdentityMismatch = "r04_configuration_identity_mismatch"
    case supportedPixelFormatRejected = "r04_supported_pixel_format_rejected"
}

enum R04VideoToolboxRouteUnavailableReason: String, Hashable, Sendable {
    case capabilityNotObserved = "r04_capability_not_observed"
    case capabilityUnavailable = "r04_capability_unavailable"
    case runtimeSupportNotObserved = "r04_runtime_support_not_observed"
    case runtimeSupportUnavailable = "r04_runtime_support_unavailable"
    case optionalSupportUnavailable = "r04_optional_support_unavailable"
    case runtimeUnavailable = "r04_runtime_unavailable"
    case configurationDiagnosticsNotObserved = "r04_configuration_diagnostics_not_observed"
    case modelNotReady = "r04_model_not_ready"
}

enum R04VideoToolboxRouteFailureReason: String, Hashable, Sendable {
    case runtimeConstructionFailed = "r04_runtime_construction_failed"
    case runtimeProcessingFailed = "r04_runtime_processing_failed"
    case outputContractMismatch = "r04_output_contract_mismatch"
}

struct R04VideoToolboxRouteRejected: Error, Hashable, Sendable {
    let route: R04VideoToolboxRouteDescriptor
    let reason: R04VideoToolboxRouteRejectionReason
}

struct R04VideoToolboxRouteUnavailable: Error, Hashable, Sendable {
    let route: R04VideoToolboxRouteDescriptor
    let reason: R04VideoToolboxRouteUnavailableReason
}

enum R04VideoToolboxRouteDecision: Hashable, Sendable {
    case runnable(R04VideoToolboxRouteDescriptor)
    case optionalSupported(R04VideoToolboxRouteDescriptor)
    case rejected(R04VideoToolboxRouteRejected)
    case unavailable(R04VideoToolboxRouteUnavailable)
}

enum R04VideoToolboxRouteCatalog {
    static let backendRevision = "1"
    static let policyIdentity = "r04.fixture-only.no-product-qualification.v1"
    static let materialDecisionIdentity = "r04.preregistered-videotoolbox-contract.v1"
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    static let routes: [R04VideoToolboxRouteDescriptor] = makeRoutes()

    static func route(
        _ subjectID: R04VideoToolboxSubjectID
    ) -> R04VideoToolboxRouteDescriptor? {
        routes.first { $0.subjectID == subjectID }
    }

    static func route(
        _ routeID: R04VideoToolboxRouteID
    ) -> R04VideoToolboxRouteDescriptor? {
        routes.first { $0.routeID == routeID }
    }

    static func makeBackendIdentity(
        for route: R04VideoToolboxRouteDescriptor,
        modelAssetsIdentity: AppleUpscaleModelAssetsIdentity
    ) throws -> AppleUpscaleBackendIdentity {
        guard self.route(route.subjectID) == route else {
            throw R04VideoToolboxContractError.catalogIdentityMismatch(route.subjectID)
        }
        return try AppleUpscaleBackendIdentity(
            backendID: route.subjectID.rawValue,
            backendRevision: backendRevision,
            modelAssetsIdentity: modelAssetsIdentity
        )
    }

    static func makeRouteIdentity(
        for route: R04VideoToolboxRouteDescriptor,
        modelAssetsIdentity: AppleUpscaleModelAssetsIdentity
    ) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: makeBackendIdentity(
                for: route,
                modelAssetsIdentity: modelAssetsIdentity
            ),
            configurationIdentity: route.configurationIdentity,
            policyIdentity: policyIdentity,
            materialDecisionIdentity: materialDecisionIdentity
        )
    }

    // The frozen route matrix stays together so ordering and duplicate checks remain visible.
    // swiftlint:disable:next function_body_length
    private static func makeRoutes() -> [R04VideoToolboxRouteDescriptor] {
        do {
            let values = try [
                R04VideoToolboxRouteDescriptor(
                    subjectID: .quality2x,
                    routeID: .quality2x,
                    capabilityID: "A01",
                    backendKind: .quality,
                    sourceResolution: .p1080,
                    targetResolution: .p2160,
                    scaleFactor: .two,
                    gate: .runtimeSupportRequired,
                    configurationContract: qualityConfiguration(
                        source: .p1080,
                        scaleFactorIdentity: "2",
                        modelStatus: .notObserved
                    ),
                    temporalPolicy: .qualitySequential,
                    opticalFlowRole: .optionalQualityInput,
                    productDefaultEligibility: .candidateAfterObservedQualification
                ),
                R04VideoToolboxRouteDescriptor(
                    subjectID: .quality1p5xContract,
                    routeID: .quality1p5xContract,
                    capabilityID: "A01",
                    backendKind: .quality,
                    sourceResolution: .p720,
                    targetResolution: .p1080,
                    scaleFactor: .oneAndOneHalf,
                    gate: .publicContractUnrepresentable,
                    configurationContract: qualityConfiguration(
                        source: .p720,
                        scaleFactorIdentity: "1.5-public-contract-unrepresentable",
                        modelStatus: .notObserved
                    ),
                    temporalPolicy: .qualitySequential,
                    opticalFlowRole: .optionalQualityInput,
                    productDefaultEligibility: .ineligibleContractRejection
                ),
                R04VideoToolboxRouteDescriptor(
                    subjectID: .lowLatency1p5x,
                    routeID: .lowLatency1p5x,
                    capabilityID: "A02",
                    backendKind: .lowLatency,
                    sourceResolution: .p720,
                    targetResolution: .p1080,
                    scaleFactor: .oneAndOneHalf,
                    gate: .exactDimensionQueryRequired,
                    configurationContract: lowLatencyConfiguration(
                        source: .p720,
                        floatScaleFactorIdentity: "1.5"
                    ),
                    temporalPolicy: .statelessRandom,
                    opticalFlowRole: .notApplicable,
                    productDefaultEligibility: .candidateAfterObservedQualification
                ),
                R04VideoToolboxRouteDescriptor(
                    subjectID: .lowLatency2x,
                    routeID: .lowLatency2x,
                    capabilityID: "A02",
                    backendKind: .lowLatency,
                    sourceResolution: .p1080,
                    targetResolution: .p2160,
                    scaleFactor: .two,
                    gate: .exactDimensionQueryRequired,
                    configurationContract: lowLatencyConfiguration(
                        source: .p1080,
                        floatScaleFactorIdentity: "2.0"
                    ),
                    temporalPolicy: .statelessRandom,
                    opticalFlowRole: .notApplicable,
                    productDefaultEligibility: .candidateAfterObservedQualification
                ),
                R04VideoToolboxRouteDescriptor(
                    subjectID: .opticalFlowSupport,
                    routeID: .opticalFlow1080p,
                    capabilityID: "A05",
                    backendKind: .optionalFlowSupport,
                    sourceResolution: .p1080,
                    targetResolution: .p1080,
                    scaleFactor: .one,
                    gate: .optionalRuntimeSupport,
                    configurationContract: R04VideoToolboxConfigurationContract(
                        frameWidth: VideoResolution.p1080.width,
                        frameHeight: VideoResolution.p1080.height,
                        scaleFactorIdentity: "1.0",
                        inputType: .video,
                        precomputedFlowChoice: .notApplicable,
                        qualityPriority: .notApplicable,
                        revision: .runtimeSelectedNotObserved,
                        supportedFormats: .notObserved,
                        modelStatus: .notRequired,
                        processingMode: .optionalFlowSupport,
                        exactDimensionQueryRequired: false
                    ),
                    temporalPolicy: .statelessRandom,
                    opticalFlowRole: .optionalSupportOnly,
                    productDefaultEligibility: .ineligibleOptionalSupport
                )
            ]
            guard Set(values.map(\.subjectID)).count == values.count else {
                throw R04VideoToolboxContractError.duplicateSubject(values[0].subjectID)
            }
            guard Set(values.map(\.routeID)).count == values.count else {
                throw R04VideoToolboxContractError.duplicateRoute(values[0].routeID)
            }
            return values
        } catch {
            preconditionFailure("The frozen R04 route catalog is invalid: \(error)")
        }
    }

    private static func qualityConfiguration(
        source: VideoResolution,
        scaleFactorIdentity: String,
        modelStatus: R04VideoToolboxModelStatusIdentity
    ) -> R04VideoToolboxConfigurationContract {
        R04VideoToolboxConfigurationContract(
            frameWidth: source.width,
            frameHeight: source.height,
            scaleFactorIdentity: scaleFactorIdentity,
            inputType: .video,
            precomputedFlowChoice: .optionalPerRequest,
            qualityPriority: .quality,
            revision: .runtimeSelectedNotObserved,
            supportedFormats: .notObserved,
            modelStatus: modelStatus,
            processingMode: .qualityTemporal,
            exactDimensionQueryRequired: false
        )
    }

    private static func lowLatencyConfiguration(
        source: VideoResolution,
        floatScaleFactorIdentity: String
    ) -> R04VideoToolboxConfigurationContract {
        R04VideoToolboxConfigurationContract(
            frameWidth: source.width,
            frameHeight: source.height,
            scaleFactorIdentity: floatScaleFactorIdentity,
            inputType: .video,
            precomputedFlowChoice: .notApplicable,
            qualityPriority: .notApplicable,
            revision: .runtimeSelectedNotObserved,
            supportedFormats: .notObserved,
            modelStatus: .notRequired,
            processingMode: .lowLatencyStateless,
            exactDimensionQueryRequired: true
        )
    }
}

// swiftlint:enable file_length
