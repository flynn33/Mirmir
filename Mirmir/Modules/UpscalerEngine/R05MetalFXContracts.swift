import Foundation

// swiftlint:disable file_length

enum R05MetalFXContractError: Error, Equatable, Sendable {
    case invalidScaleFactor(numerator: Int, denominator: Int)
    case scaleDoesNotMatchRoute(R05MetalFXRouteID)
    case routeContractMismatch(R05MetalFXSubjectID)
    case catalogIdentityMismatch(R05MetalFXSubjectID)
}

enum R05MetalFXSubjectID: String, CaseIterable, Hashable, Sendable {
    case spatial1p5x = "r05.metalfx.spatial-1p5x"
    case spatial2x = "r05.metalfx.spatial-2x"
    case temporal1p5x = "r05.metalfx.temporal-1p5x"
    case temporal2x = "r05.metalfx.temporal-2x"
    case denoisedTemporal1p5x = "r05.metalfx.denoised-temporal-1p5x"
    case denoisedTemporal2x = "r05.metalfx.denoised-temporal-2x"
    case frameInterpolation1080p = "r05.metalfx.frame-interpolation-1080p"
}

enum R05MetalFXRouteID: String, CaseIterable, Hashable, Sendable {
    case spatial1p5x = "spatial_1p5x"
    case spatial2x = "spatial_2x"
    case temporal1p5xContract = "temporal_1p5x_contract"
    case temporal2xContract = "temporal_2x_contract"
    case denoisedTemporal1p5xContract = "denoised_temporal_1p5x_contract"
    case denoisedTemporal2xContract = "denoised_temporal_2x_contract"
    case frameInterpolation1080pContract = "frame_interpolation_1080p_contract"
}

enum R05MetalFXBackendIdentity: String, Hashable, Sendable {
    case spatial
    case temporal
    case temporalDenoised = "temporal_denoised"
    case frameInterpolation = "frame_interpolation"

    var capabilityRole: AppleUpscaleCapabilityRole {
        switch self {
        case .spatial, .temporal, .temporalDenoised:
            return .primaryScaler
        case .frameInterpolation:
            return .cadenceTransform
        }
    }
}

enum R05MetalFXRouteGate: String, Hashable, Sendable {
    case runtimeObservationRequired = "runtime_observation_required"
    case missingRendererInputsRejected = "missing_renderer_inputs_rejected"
}

enum R05MetalFXInitialStatus: String, Hashable, Sendable {
    case notObserved = "not_observed"
    case contractRejected = "contract_rejected"
}

enum R05MetalFXInitialDisposition: String, Hashable, Sendable {
    case notObserved = "not_observed"
    case rejectedForDecodedVideo = "rejected_for_decoded_video"
}

enum R05MetalFXProductDefaultEligibility: String, Hashable, Sendable {
    case candidateAfterObservedQualification = "candidate_after_observed_qualification"
    case ineligibleContractRejection = "ineligible_contract_rejection"
}

enum R05MetalFXProductQualification: String, Hashable, Sendable {
    case notClaimed = "not_claimed"
}

enum R05MetalFXProductScope: String, Hashable, Sendable {
    case forbidden
}

enum R05MetalFXFallbackPolicy: String, Hashable, Sendable {
    case forbidden
}

enum R05MetalFXDecodedVideoRejectionReason: String, Hashable, Sendable {
    case missingTemporalRendererSemantics =
        "missing_renderer_motion_depth_jitter_semantics"
    case missingDenoisedRendererSemantics =
        "missing_renderer_gbuffer_motion_depth_camera_semantics"
    case missingInterpolationRendererSemantics =
        "missing_renderer_motion_depth_camera_and_output_timing_contract"
}

struct R05MetalFXScaleFactor: Hashable, Sendable {
    let numerator: Int
    let denominator: Int

    init(numerator: Int, denominator: Int) throws {
        guard numerator > 0, denominator > 0 else {
            throw R05MetalFXContractError.invalidScaleFactor(
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

    func matches(source: VideoResolution, target: VideoResolution) -> Bool {
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
    ) -> R05MetalFXScaleFactor {
        do {
            return try R05MetalFXScaleFactor(
                numerator: numerator,
                denominator: denominator
            )
        } catch {
            preconditionFailure("Static R05 scale factors must be valid: \(error)")
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

struct R05MetalFXColorBridgeContract: Hashable, Sendable {
    let pixelFormatIdentity: String
    let bitDepth: Int
    let rangeIdentity: String
    let transferFunctionIdentity: String
    let matrixIdentity: String
    let chromaLocationIdentity: String
    let bridgeTextureFormatIdentity: String
    let processingSpaceIdentity: String
    let chromaUpsamplingIdentity: String
    let chromaDownsamplingIdentity: String

    static let frozen = R05MetalFXColorBridgeContract(
        pixelFormatIdentity: "420v",
        bitDepth: 8,
        rangeIdentity: "video",
        transferFunctionIdentity: "ITU_R_709_2",
        matrixIdentity: "ITU_R_709_2",
        chromaLocationIdentity: "left",
        bridgeTextureFormatIdentity: "rgba16Float",
        processingSpaceIdentity: "linear_bt709",
        chromaUpsamplingIdentity: "left_cosited_horizontal_centered_vertical_bilinear",
        chromaDownsamplingIdentity: "left_cosited_horizontal_centered_vertical_filter"
    )

    var stableIdentity: String {
        [
            "pixel-\(pixelFormatIdentity)",
            "bits-\(bitDepth)",
            "range-\(rangeIdentity)",
            "transfer-\(transferFunctionIdentity)",
            "matrix-\(matrixIdentity)",
            "chroma-\(chromaLocationIdentity)",
            "texture-\(bridgeTextureFormatIdentity)",
            "space-\(processingSpaceIdentity)",
            "upsample-\(chromaUpsamplingIdentity)",
            "downsample-\(chromaDownsamplingIdentity)"
        ].joined(separator: ".")
    }
}

struct R05MetalFXRouteDescriptor: Hashable, Sendable {
    let subjectID: R05MetalFXSubjectID
    let routeID: R05MetalFXRouteID
    let capabilityID: AppleUpscaleCapabilityID
    let backendIdentity: R05MetalFXBackendIdentity
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let scaleFactor: R05MetalFXScaleFactor
    let gate: R05MetalFXRouteGate
    let initialStatus: R05MetalFXInitialStatus
    let initialDisposition: R05MetalFXInitialDisposition
    let decodedVideoRejectionReason: R05MetalFXDecodedVideoRejectionReason?
    let productDefaultEligibility: R05MetalFXProductDefaultEligibility
    let productQualification: R05MetalFXProductQualification
    let productScope: R05MetalFXProductScope
    let fallbackPolicy: R05MetalFXFallbackPolicy
    let colorBridge: R05MetalFXColorBridgeContract

    init(
        subjectID: R05MetalFXSubjectID,
        routeID: R05MetalFXRouteID,
        capabilityID: AppleUpscaleCapabilityID,
        backendIdentity: R05MetalFXBackendIdentity,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        scaleFactor: R05MetalFXScaleFactor,
        gate: R05MetalFXRouteGate,
        initialStatus: R05MetalFXInitialStatus,
        initialDisposition: R05MetalFXInitialDisposition,
        decodedVideoRejectionReason: R05MetalFXDecodedVideoRejectionReason?,
        productDefaultEligibility: R05MetalFXProductDefaultEligibility,
        colorBridge: R05MetalFXColorBridgeContract = .frozen
    ) throws {
        guard scaleFactor.matches(
            source: sourceResolution,
            target: targetResolution
        ) else {
            throw R05MetalFXContractError.scaleDoesNotMatchRoute(routeID)
        }
        let isSpatial = backendIdentity == .spatial
        let spatialContractIsExact = gate == .runtimeObservationRequired
            && initialStatus == .notObserved
            && initialDisposition == .notObserved
            && decodedVideoRejectionReason == nil
            && productDefaultEligibility == .candidateAfterObservedQualification
        let rejectedContractIsExact = gate == .missingRendererInputsRejected
            && initialStatus == .contractRejected
            && initialDisposition == .rejectedForDecodedVideo
            && decodedVideoRejectionReason != nil
            && productDefaultEligibility == .ineligibleContractRejection
        guard (isSpatial && spatialContractIsExact)
                || (!isSpatial && rejectedContractIsExact) else {
            throw R05MetalFXContractError.routeContractMismatch(subjectID)
        }

        self.subjectID = subjectID
        self.routeID = routeID
        self.capabilityID = capabilityID
        self.backendIdentity = backendIdentity
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.scaleFactor = scaleFactor
        self.gate = gate
        self.initialStatus = initialStatus
        self.initialDisposition = initialDisposition
        self.decodedVideoRejectionReason = decodedVideoRejectionReason
        self.productDefaultEligibility = productDefaultEligibility
        self.productQualification = .notClaimed
        self.productScope = .forbidden
        self.fallbackPolicy = .forbidden
        self.colorBridge = colorBridge
    }

    var configurationIdentity: String {
        [
            subjectID.rawValue,
            routeID.rawValue,
            capabilityID.rawValue,
            backendIdentity.rawValue,
            "source-\(sourceResolution.width)x\(sourceResolution.height)",
            "target-\(targetResolution.width)x\(targetResolution.height)",
            "scale-\(scaleFactor.numerator)-over-\(scaleFactor.denominator)",
            "gate-\(gate.rawValue)",
            colorBridge.stableIdentity,
            "product-scope-\(productScope.rawValue)",
            "fallback-\(fallbackPolicy.rawValue)",
            "v1"
        ].joined(separator: ".")
    }
}

enum R05MetalFXRejectionDisposition: String, Hashable, Sendable {
    case rejectedForDecodedVideo = "rejected_for_decoded_video"
    case productScopeForbidden = "product_scope_forbidden"
}

enum R05MetalFXRouteRejectionReason: Hashable, Sendable {
    case decodedVideo(R05MetalFXDecodedVideoRejectionReason)
    case productScopeForbidden

    var disposition: R05MetalFXRejectionDisposition {
        switch self {
        case .decodedVideo:
            return .rejectedForDecodedVideo
        case .productScopeForbidden:
            return .productScopeForbidden
        }
    }
}

enum R05MetalFXRouteUnavailableReason: String, Hashable, Sendable {
    case deviceSupportNotObserved = "metalfx_spatial_device_support_not_observed"
    case deviceUnsupported = "metalfx_spatial_device_unsupported"
    case descriptorConstructionReturnedNil = "metalfx_spatial_descriptor_construction_returned_nil"
}

struct R05MetalFXRouteRejected: Error, Hashable, Sendable {
    let route: R05MetalFXRouteDescriptor
    let reason: R05MetalFXRouteRejectionReason

    var disposition: R05MetalFXRejectionDisposition {
        reason.disposition
    }
}

struct R05MetalFXRouteUnavailable: Error, Hashable, Sendable {
    let route: R05MetalFXRouteDescriptor
    let reason: R05MetalFXRouteUnavailableReason
}

enum R05MetalFXRouteDecision: Hashable, Sendable {
    case spatialContractAdmitted(R05MetalFXRouteDescriptor)
    case rejected(R05MetalFXRouteRejected)
    case unavailable(R05MetalFXRouteUnavailable)
}

enum R05MetalFXSupportObservation: Hashable, Sendable {
    case notObserved
    case observed(Bool)
}

enum R05MetalFXSpatialConstructionObservation: Hashable, Sendable {
    case constructed
    case returnedNil
}

protocol R05MetalFXSpatialRuntimeProbing: Sendable {
    func supportsSpatialDevice(
        for route: R05MetalFXRouteDescriptor
    ) -> R05MetalFXSupportObservation

    func constructSpatialScaler(
        for route: R05MetalFXRouteDescriptor
    ) -> R05MetalFXSpatialConstructionObservation
}

enum R05MetalFXRouteResolver {
    static func resolve(
        _ route: R05MetalFXRouteDescriptor,
        admissionScope: AppleUpscaleAdmissionScope,
        using runtime: any R05MetalFXSpatialRuntimeProbing
    ) throws -> R05MetalFXRouteDecision {
        guard R05MetalFXRouteCatalog.route(route.subjectID) == route else {
            throw R05MetalFXContractError.catalogIdentityMismatch(route.subjectID)
        }

        if let rejectionReason = route.decodedVideoRejectionReason {
            return .rejected(
                R05MetalFXRouteRejected(
                    route: route,
                    reason: .decodedVideo(rejectionReason)
                )
            )
        }
        guard admissionScope != .product else {
            return .rejected(
                R05MetalFXRouteRejected(
                    route: route,
                    reason: .productScopeForbidden
                )
            )
        }

        switch runtime.supportsSpatialDevice(for: route) {
        case .notObserved:
            return unavailable(route, reason: .deviceSupportNotObserved)
        case .observed(false):
            return unavailable(route, reason: .deviceUnsupported)
        case .observed(true):
            break
        }
        switch runtime.constructSpatialScaler(for: route) {
        case .constructed:
            return .spatialContractAdmitted(route)
        case .returnedNil:
            return unavailable(route, reason: .descriptorConstructionReturnedNil)
        }
    }

    private static func unavailable(
        _ route: R05MetalFXRouteDescriptor,
        reason: R05MetalFXRouteUnavailableReason
    ) -> R05MetalFXRouteDecision {
        .unavailable(R05MetalFXRouteUnavailable(route: route, reason: reason))
    }
}

enum R05MetalFXRouteCatalog {
    static let backendRevision = "1"
    static let policyIdentity = "r05.local-implementation.no-product.no-fallback.v1"
    static let materialDecisionIdentity = "r05.preregistered-metalfx-suitability.v1"

    static let routes: [R05MetalFXRouteDescriptor] = makeRoutes()

    static func route(
        _ subjectID: R05MetalFXSubjectID
    ) -> R05MetalFXRouteDescriptor? {
        routes.first { $0.subjectID == subjectID }
    }

    static func route(_ routeID: R05MetalFXRouteID) -> R05MetalFXRouteDescriptor? {
        routes.first { $0.routeID == routeID }
    }

    static func makeNotObservedCapability(
        for route: R05MetalFXRouteDescriptor
    ) throws -> AppleUpscaleCapability {
        guard self.route(route.subjectID) == route else {
            throw R05MetalFXContractError.catalogIdentityMismatch(route.subjectID)
        }
        return try AppleUpscaleCapability(
            id: route.capabilityID,
            role: route.backendIdentity.capabilityRole,
            frameworkIdentity: "MetalFX",
            observationStatus: .notObserved,
            runtimeDisposition: .diagnosticOnly,
            backendEligibility: .notEvaluated
        )
    }

    static func makeNotObservedCapabilityRegistry() throws
        -> AppleUpscaleCapabilityRegistry {
        var seen: Set<AppleUpscaleCapabilityID> = []
        var capabilities: [AppleUpscaleCapability] = []
        for route in routes where seen.insert(route.capabilityID).inserted {
            capabilities.append(try makeNotObservedCapability(for: route))
        }
        return try AppleUpscaleCapabilityRegistry(capabilities: capabilities)
    }

    static func makeBackendIdentity(
        for route: R05MetalFXRouteDescriptor
    ) throws -> AppleUpscaleBackendIdentity {
        guard self.route(route.subjectID) == route else {
            throw R05MetalFXContractError.catalogIdentityMismatch(route.subjectID)
        }
        return try AppleUpscaleBackendIdentity(
            backendID: route.subjectID.rawValue,
            backendRevision: backendRevision,
            modelAssetsIdentity: .notRequired
        )
    }

    static func makeRouteIdentity(
        for route: R05MetalFXRouteDescriptor
    ) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: makeBackendIdentity(for: route),
            configurationIdentity: route.configurationIdentity,
            policyIdentity: policyIdentity,
            materialDecisionIdentity: materialDecisionIdentity
        )
    }

    static func makeProcessingIdentity(
        for route: R05MetalFXRouteDescriptor
    ) throws -> AppleUpscaleProcessingIdentity {
        try AppleUpscaleProcessingIdentity(
            route: makeRouteIdentity(for: route),
            fallbackHistory: []
        )
    }

    // The frozen route matrix stays together so order and one-to-one identities remain visible.
    private static func makeRoutes() -> [R05MetalFXRouteDescriptor] {
        do {
            let values = try [
                makeSpatial(
                    subjectID: .spatial1p5x,
                    routeID: .spatial1p5x,
                    source: .p720,
                    target: .p1080,
                    scale: .oneAndOneHalf
                ),
                makeSpatial(
                    subjectID: .spatial2x,
                    routeID: .spatial2x,
                    source: .p1080,
                    target: .p2160,
                    scale: .two
                ),
                makeRejected(
                    subjectID: .temporal1p5x,
                    routeID: .temporal1p5xContract,
                    capabilityID: "A08",
                    backend: .temporal,
                    source: .p720,
                    target: .p1080,
                    scale: .oneAndOneHalf,
                    reason: .missingTemporalRendererSemantics
                ),
                makeRejected(
                    subjectID: .temporal2x,
                    routeID: .temporal2xContract,
                    capabilityID: "A08",
                    backend: .temporal,
                    source: .p1080,
                    target: .p2160,
                    scale: .two,
                    reason: .missingTemporalRendererSemantics
                ),
                makeRejected(
                    subjectID: .denoisedTemporal1p5x,
                    routeID: .denoisedTemporal1p5xContract,
                    capabilityID: "A09",
                    backend: .temporalDenoised,
                    source: .p720,
                    target: .p1080,
                    scale: .oneAndOneHalf,
                    reason: .missingDenoisedRendererSemantics
                ),
                makeRejected(
                    subjectID: .denoisedTemporal2x,
                    routeID: .denoisedTemporal2xContract,
                    capabilityID: "A09",
                    backend: .temporalDenoised,
                    source: .p1080,
                    target: .p2160,
                    scale: .two,
                    reason: .missingDenoisedRendererSemantics
                ),
                makeRejected(
                    subjectID: .frameInterpolation1080p,
                    routeID: .frameInterpolation1080pContract,
                    capabilityID: "A10",
                    backend: .frameInterpolation,
                    source: .p1080,
                    target: .p1080,
                    scale: .one,
                    reason: .missingInterpolationRendererSemantics
                )
            ]
            guard values.map(\.subjectID) == R05MetalFXSubjectID.allCases,
                  values.map(\.routeID) == R05MetalFXRouteID.allCases else {
                preconditionFailure("The frozen R05 route catalog order is invalid")
            }
            return values
        } catch {
            preconditionFailure("The frozen R05 route catalog is invalid: \(error)")
        }
    }

    private static func makeSpatial(
        subjectID: R05MetalFXSubjectID,
        routeID: R05MetalFXRouteID,
        source: VideoResolution,
        target: VideoResolution,
        scale: R05MetalFXScaleFactor
    ) throws -> R05MetalFXRouteDescriptor {
        try R05MetalFXRouteDescriptor(
            subjectID: subjectID,
            routeID: routeID,
            capabilityID: AppleUpscaleCapabilityID("A07"),
            backendIdentity: .spatial,
            sourceResolution: source,
            targetResolution: target,
            scaleFactor: scale,
            gate: .runtimeObservationRequired,
            initialStatus: .notObserved,
            initialDisposition: .notObserved,
            decodedVideoRejectionReason: nil,
            productDefaultEligibility: .candidateAfterObservedQualification
        )
    }

    private static func makeRejected(
        subjectID: R05MetalFXSubjectID,
        routeID: R05MetalFXRouteID,
        capabilityID: String,
        backend: R05MetalFXBackendIdentity,
        source: VideoResolution,
        target: VideoResolution,
        scale: R05MetalFXScaleFactor,
        reason: R05MetalFXDecodedVideoRejectionReason
    ) throws -> R05MetalFXRouteDescriptor {
        try R05MetalFXRouteDescriptor(
            subjectID: subjectID,
            routeID: routeID,
            capabilityID: AppleUpscaleCapabilityID(capabilityID),
            backendIdentity: backend,
            sourceResolution: source,
            targetResolution: target,
            scaleFactor: scale,
            gate: .missingRendererInputsRejected,
            initialStatus: .contractRejected,
            initialDisposition: .rejectedForDecodedVideo,
            decodedVideoRejectionReason: reason,
            productDefaultEligibility: .ineligibleContractRejection
        )
    }
}

// swiftlint:enable file_length
