import XCTest
@testable import Mirmir

// swiftlint:disable type_body_length

final class R05MetalFXContractsTests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testCatalogMatchesFrozenSevenSubjectRouteMatrixExactly() {
        let observed = R05MetalFXRouteCatalog.routes.map(ExpectedRoute.init)
        let expected: [ExpectedRoute] = [
            .init(
                subjectID: .spatial1p5x,
                routeID: .spatial1p5x,
                capabilityID: "A07",
                backend: .spatial,
                source: .p720,
                target: .p1080,
                scale: .oneAndOneHalf,
                gate: .runtimeObservationRequired,
                status: .notObserved,
                disposition: .notObserved,
                rejectionReason: nil
            ),
            .init(
                subjectID: .spatial2x,
                routeID: .spatial2x,
                capabilityID: "A07",
                backend: .spatial,
                source: .p1080,
                target: .p2160,
                scale: .two,
                gate: .runtimeObservationRequired,
                status: .notObserved,
                disposition: .notObserved,
                rejectionReason: nil
            ),
            .init(
                subjectID: .temporal1p5x,
                routeID: .temporal1p5xContract,
                capabilityID: "A08",
                backend: .temporal,
                source: .p720,
                target: .p1080,
                scale: .oneAndOneHalf,
                gate: .missingRendererInputsRejected,
                status: .contractRejected,
                disposition: .rejectedForDecodedVideo,
                rejectionReason: .missingTemporalRendererSemantics
            ),
            .init(
                subjectID: .temporal2x,
                routeID: .temporal2xContract,
                capabilityID: "A08",
                backend: .temporal,
                source: .p1080,
                target: .p2160,
                scale: .two,
                gate: .missingRendererInputsRejected,
                status: .contractRejected,
                disposition: .rejectedForDecodedVideo,
                rejectionReason: .missingTemporalRendererSemantics
            ),
            .init(
                subjectID: .denoisedTemporal1p5x,
                routeID: .denoisedTemporal1p5xContract,
                capabilityID: "A09",
                backend: .temporalDenoised,
                source: .p720,
                target: .p1080,
                scale: .oneAndOneHalf,
                gate: .missingRendererInputsRejected,
                status: .contractRejected,
                disposition: .rejectedForDecodedVideo,
                rejectionReason: .missingDenoisedRendererSemantics
            ),
            .init(
                subjectID: .denoisedTemporal2x,
                routeID: .denoisedTemporal2xContract,
                capabilityID: "A09",
                backend: .temporalDenoised,
                source: .p1080,
                target: .p2160,
                scale: .two,
                gate: .missingRendererInputsRejected,
                status: .contractRejected,
                disposition: .rejectedForDecodedVideo,
                rejectionReason: .missingDenoisedRendererSemantics
            ),
            .init(
                subjectID: .frameInterpolation1080p,
                routeID: .frameInterpolation1080pContract,
                capabilityID: "A10",
                backend: .frameInterpolation,
                source: .p1080,
                target: .p1080,
                scale: .one,
                gate: .missingRendererInputsRejected,
                status: .contractRejected,
                disposition: .rejectedForDecodedVideo,
                rejectionReason: .missingInterpolationRendererSemantics
            )
        ]

        XCTAssertEqual(observed, expected)
        XCTAssertEqual(
            R05MetalFXRouteCatalog.routes.map(\.subjectID),
            R05MetalFXSubjectID.allCases
        )
        XCTAssertEqual(
            R05MetalFXRouteCatalog.routes.map(\.routeID),
            R05MetalFXRouteID.allCases
        )
    }

    func testEveryRouteForbidsProductScopeFallbackAndQualificationClaims() {
        for route in R05MetalFXRouteCatalog.routes {
            XCTAssertEqual(route.productScope, .forbidden)
            XCTAssertEqual(route.fallbackPolicy, .forbidden)
            XCTAssertEqual(route.productQualification, .notClaimed)
        }
    }

    func testFrozenColorBridgeMatchesCatalogExactly() {
        let bridge = R05MetalFXColorBridgeContract.frozen

        XCTAssertEqual(bridge.pixelFormatIdentity, "420v")
        XCTAssertEqual(bridge.bitDepth, 8)
        XCTAssertEqual(bridge.rangeIdentity, "video")
        XCTAssertEqual(bridge.transferFunctionIdentity, "ITU_R_709_2")
        XCTAssertEqual(bridge.matrixIdentity, "ITU_R_709_2")
        XCTAssertEqual(bridge.chromaLocationIdentity, "left")
        XCTAssertEqual(bridge.bridgeTextureFormatIdentity, "rgba16Float")
        XCTAssertEqual(bridge.processingSpaceIdentity, "linear_bt709")
        XCTAssertEqual(
            bridge.chromaUpsamplingIdentity,
            "left_cosited_horizontal_centered_vertical_bilinear"
        )
        XCTAssertEqual(
            bridge.chromaDownsamplingIdentity,
            "left_cosited_horizontal_centered_vertical_filter"
        )
        XCTAssertTrue(
            R05MetalFXRouteCatalog.routes.allSatisfy { $0.colorBridge == bridge }
        )
    }

    func testScaleFactorsNormalizeAndRejectInvalidOrMismatchedRoutes() throws {
        XCTAssertEqual(
            try R05MetalFXScaleFactor(numerator: 6, denominator: 4),
            .oneAndOneHalf
        )
        XCTAssertThrowsError(
            try R05MetalFXScaleFactor(numerator: 0, denominator: 1)
        )
        XCTAssertThrowsError(
            try makeSpatialDescriptor(
                subjectID: .spatial2x,
                routeID: .spatial2x,
                source: .p720,
                target: .p1080,
                scale: .two
            )
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXContractError,
                .scaleDoesNotMatchRoute(.spatial2x)
            )
        }
    }

    func testDescriptorRejectsSpatialOrDecodedVideoContractDrift() throws {
        XCTAssertThrowsError(
            try R05MetalFXRouteDescriptor(
                subjectID: .temporal1p5x,
                routeID: .temporal1p5xContract,
                capabilityID: AppleUpscaleCapabilityID("A08"),
                backendIdentity: .temporal,
                sourceResolution: .p720,
                targetResolution: .p1080,
                scaleFactor: .oneAndOneHalf,
                gate: .runtimeObservationRequired,
                initialStatus: .notObserved,
                initialDisposition: .notObserved,
                decodedVideoRejectionReason: nil,
                productDefaultEligibility: .candidateAfterObservedQualification
            )
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXContractError,
                .routeContractMismatch(.temporal1p5x)
            )
        }
    }

    func testStableRouteAndProcessingIdentitiesContainNoFallback() throws {
        for route in R05MetalFXRouteCatalog.routes {
            let routeIdentity = try R05MetalFXRouteCatalog.makeRouteIdentity(for: route)
            let processingIdentity = try R05MetalFXRouteCatalog.makeProcessingIdentity(
                for: route
            )

            XCTAssertEqual(routeIdentity.backend.backendID, route.subjectID.rawValue)
            XCTAssertEqual(
                routeIdentity.backend.backendRevision,
                R05MetalFXRouteCatalog.backendRevision
            )
            XCTAssertEqual(routeIdentity.configurationIdentity, route.configurationIdentity)
            XCTAssertEqual(
                routeIdentity.policyIdentity,
                R05MetalFXRouteCatalog.policyIdentity
            )
            XCTAssertEqual(
                routeIdentity.materialDecisionIdentity,
                R05MetalFXRouteCatalog.materialDecisionIdentity
            )
            XCTAssertEqual(processingIdentity.route, routeIdentity)
            XCTAssertTrue(processingIdentity.fallbackHistory.isEmpty)
        }
        XCTAssertEqual(
            Set(R05MetalFXRouteCatalog.routes.map(\.configurationIdentity)).count,
            7
        )
    }

    func testNotObservedCapabilityRegistryPreservesFrozenRolesAndProductIneligibility()
        throws {
        let registry = try R05MetalFXRouteCatalog.makeNotObservedCapabilityRegistry()
        XCTAssertEqual(registry.capabilities.map(\.id.rawValue), ["A07", "A08", "A09", "A10"])

        for capability in registry.capabilities {
            XCTAssertEqual(capability.frameworkIdentity, "MetalFX")
            XCTAssertEqual(capability.observationStatus, .notObserved)
            XCTAssertEqual(capability.runtimeDisposition, .diagnosticOnly)
            XCTAssertEqual(capability.backendEligibility, .notEvaluated)
            XCTAssertFalse(capability.isEligible(for: .fixtureOnly))
            XCTAssertFalse(capability.isEligible(for: .product))
        }
        XCTAssertEqual(registry.capabilities.last?.role, .cadenceTransform)
        XCTAssertTrue(registry.capabilities.dropLast().allSatisfy { $0.role == .primaryScaler })
    }

    func testEveryA08A09AndA10RouteRejectsBeforeSupportOrFactoryProbe() throws {
        let rejectedRoutes = R05MetalFXRouteCatalog.routes.filter {
            $0.backendIdentity != .spatial
        }
        for route in rejectedRoutes {
            let runtime = ProbeRuntime()
            let decision = try R05MetalFXRouteResolver.resolve(
                route,
                admissionScope: .fixtureOnly,
                using: runtime
            )

            guard case .rejected(let rejection) = decision else {
                return XCTFail("Expected decoded-video rejection for \(route.subjectID)")
            }
            XCTAssertEqual(rejection.disposition, .rejectedForDecodedVideo)
            XCTAssertEqual(
                rejection.reason,
                .decodedVideo(try XCTUnwrap(route.decodedVideoRejectionReason))
            )
            XCTAssertEqual(runtime.events, [])
        }
    }

    func testDecodedVideoRejectionsRemainFirstEvenForProductAdmission() throws {
        let route = try XCTUnwrap(
            R05MetalFXRouteCatalog.route(.frameInterpolation1080p)
        )
        let runtime = ProbeRuntime()
        let decision = try R05MetalFXRouteResolver.resolve(
            route,
            admissionScope: .product,
            using: runtime
        )

        guard case .rejected(let rejection) = decision else {
            return XCTFail("Expected decoded-video rejection")
        }
        XCTAssertEqual(rejection.disposition, .rejectedForDecodedVideo)
        XCTAssertEqual(runtime.events, [])
    }

    func testSpatialProductAdmissionRejectsBeforeSupportOrFactoryProbe() throws {
        let route = try XCTUnwrap(
            R05MetalFXRouteCatalog.route(R05MetalFXSubjectID.spatial2x)
        )
        let runtime = ProbeRuntime()
        let decision = try R05MetalFXRouteResolver.resolve(
            route,
            admissionScope: .product,
            using: runtime
        )

        guard case .rejected(let rejection) = decision else {
            return XCTFail("Expected product-scope rejection")
        }
        XCTAssertEqual(rejection.reason, .productScopeForbidden)
        XCTAssertEqual(rejection.disposition, .productScopeForbidden)
        XCTAssertEqual(runtime.events, [])
    }

    func testSpatialSupportQueryPrecedesConstruction() throws {
        let route = try XCTUnwrap(
            R05MetalFXRouteCatalog.route(R05MetalFXSubjectID.spatial1p5x)
        )
        let runtime = ProbeRuntime(
            support: .observed(true),
            construction: .constructed
        )
        let decision = try R05MetalFXRouteResolver.resolve(
            route,
            admissionScope: .fixtureOnly,
            using: runtime
        )

        XCTAssertEqual(decision, .spatialContractAdmitted(route))
        XCTAssertEqual(runtime.events, [.support(.spatial1p5x), .factory(.spatial1p5x)])
    }

    func testSpatialUnavailableSupportNeverCallsFactory() throws {
        let route = try XCTUnwrap(
            R05MetalFXRouteCatalog.route(R05MetalFXSubjectID.spatial1p5x)
        )
        for observation: R05MetalFXSupportObservation in [
            .notObserved,
            .observed(false)
        ] {
            let runtime = ProbeRuntime(support: observation)
            let decision = try R05MetalFXRouteResolver.resolve(
                route,
                admissionScope: .fixtureOnly,
                using: runtime
            )

            guard case .unavailable(let unavailable) = decision else {
                return XCTFail("Expected typed support unavailability")
            }
            let expected: R05MetalFXRouteUnavailableReason = observation == .notObserved
                ? .deviceSupportNotObserved
                : .deviceUnsupported
            XCTAssertEqual(unavailable.reason, expected)
            XCTAssertEqual(runtime.events, [.support(.spatial1p5x)])
        }
    }

    func testSpatialNilConstructionIsTypedUnavailabilityWithoutFallback() throws {
        let route = try XCTUnwrap(
            R05MetalFXRouteCatalog.route(R05MetalFXSubjectID.spatial2x)
        )
        let runtime = ProbeRuntime(
            support: .observed(true),
            construction: .returnedNil
        )
        let decision = try R05MetalFXRouteResolver.resolve(
            route,
            admissionScope: .fixtureOnly,
            using: runtime
        )

        guard case .unavailable(let unavailable) = decision else {
            return XCTFail("Expected typed construction unavailability")
        }
        XCTAssertEqual(unavailable.reason, .descriptorConstructionReturnedNil)
        XCTAssertEqual(runtime.events, [.support(.spatial2x), .factory(.spatial2x)])
        XCTAssertEqual(unavailable.route.fallbackPolicy, .forbidden)
    }

    private func makeSpatialDescriptor(
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
}

// swiftlint:enable type_body_length

private struct ExpectedRoute: Equatable {
    let subjectID: R05MetalFXSubjectID
    let routeID: R05MetalFXRouteID
    let capabilityID: String
    let backend: R05MetalFXBackendIdentity
    let source: VideoResolution
    let target: VideoResolution
    let scale: R05MetalFXScaleFactor
    let gate: R05MetalFXRouteGate
    let status: R05MetalFXInitialStatus
    let disposition: R05MetalFXInitialDisposition
    let rejectionReason: R05MetalFXDecodedVideoRejectionReason?

    init(
        subjectID: R05MetalFXSubjectID,
        routeID: R05MetalFXRouteID,
        capabilityID: String,
        backend: R05MetalFXBackendIdentity,
        source: VideoResolution,
        target: VideoResolution,
        scale: R05MetalFXScaleFactor,
        gate: R05MetalFXRouteGate,
        status: R05MetalFXInitialStatus,
        disposition: R05MetalFXInitialDisposition,
        rejectionReason: R05MetalFXDecodedVideoRejectionReason?
    ) {
        self.subjectID = subjectID
        self.routeID = routeID
        self.capabilityID = capabilityID
        self.backend = backend
        self.source = source
        self.target = target
        self.scale = scale
        self.gate = gate
        self.status = status
        self.disposition = disposition
        self.rejectionReason = rejectionReason
    }

    init(_ route: R05MetalFXRouteDescriptor) {
        self.init(
            subjectID: route.subjectID,
            routeID: route.routeID,
            capabilityID: route.capabilityID.rawValue,
            backend: route.backendIdentity,
            source: route.sourceResolution,
            target: route.targetResolution,
            scale: route.scaleFactor,
            gate: route.gate,
            status: route.initialStatus,
            disposition: route.initialDisposition,
            rejectionReason: route.decodedVideoRejectionReason
        )
    }
}

private enum ProbeEvent: Equatable {
    case support(R05MetalFXRouteID)
    case factory(R05MetalFXRouteID)
}

private final class ProbeRuntime: R05MetalFXSpatialRuntimeProbing, @unchecked Sendable {
    private(set) var events: [ProbeEvent] = []
    private let support: R05MetalFXSupportObservation
    private let construction: R05MetalFXSpatialConstructionObservation

    init(
        support: R05MetalFXSupportObservation = .observed(true),
        construction: R05MetalFXSpatialConstructionObservation = .constructed
    ) {
        self.support = support
        self.construction = construction
    }

    func supportsSpatialDevice(
        for route: R05MetalFXRouteDescriptor
    ) -> R05MetalFXSupportObservation {
        events.append(.support(route.routeID))
        return support
    }

    func constructSpatialScaler(
        for route: R05MetalFXRouteDescriptor
    ) -> R05MetalFXSpatialConstructionObservation {
        events.append(.factory(route.routeID))
        return construction
    }
}
