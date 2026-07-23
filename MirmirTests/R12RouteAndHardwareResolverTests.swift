import XCTest
@testable import Mirmir

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class R12RouteAndHardwareResolverTests: XCTestCase {
    func testExactScaleDerivationReducesWithoutFloatingPointApproximation() throws {
        let scale = try R12ExactScaleFactorV2.derive(
            source: R12ResolutionV2(width: 1_920, height: 1_080),
            target: R12ResolutionV2(width: 2_880, height: 1_620)
        )

        XCTAssertEqual(scale, try R12ExactScaleFactorV2(numerator: 3, denominator: 2))
        XCTAssertEqual(scale.description, "3/2")
        XCTAssertEqual(
            try R12ExactScaleFactorV2(numerator: 6, denominator: 4),
            scale
        )
    }

    func testScaleDerivationRejectsNonUniformAndNonpositiveFactors() throws {
        XCTAssertThrowsError(
            try R12ExactScaleFactorV2.derive(
                source: R12ResolutionV2(width: 1_920, height: 1_080),
                target: R12ResolutionV2(width: 2_880, height: 2_160)
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nonUniformScale(
                    widthNumerator: 3,
                    widthDenominator: 2,
                    heightNumerator: 2,
                    heightDenominator: 1
                )
            )
        }
        XCTAssertThrowsError(
            try R12ExactScaleFactorV2(numerator: 0, denominator: 1)
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidScaleFactor(numerator: 0, denominator: 1)
            )
        }
    }

    func testHardwareProfileCanonicalizesExplicitRoutesAndRejectsDuplicates() throws {
        let profile = try R12HardwareCapabilityProfileV2(
            profileID: "fixture-profile",
            tierIdentity: .deterministicFixture,
            executionContext: .deterministicFixture,
            availableRouteIDs: ["route-z", "route-a"]
        )

        XCTAssertEqual(profile.availableRouteIDs, ["route-a", "route-z"])
        XCTAssertTrue(profile.declaresAvailable(routeID: "route-a"))
        XCTAssertFalse(profile.declaresAvailable(routeID: "route-missing"))
        XCTAssertThrowsError(
            try R12HardwareCapabilityProfileV2(
                profileID: "duplicate-profile",
                tierIdentity: .deterministicFixture,
                executionContext: .deterministicFixture,
                availableRouteIDs: ["route-a", "route-a"]
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .duplicateHardwareRoute("route-a")
            )
        }
    }

    func testHostAndReceiptIdentitiesFailClosed() throws {
        XCTAssertThrowsError(
            try R12HostIdentityV2(
                hostID: " host",
                modelIdentifier: "Mac-test",
                chipIdentity: "Apple-test"
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidIdentity(field: "host_id")
            )
        }

        let host = try R12HostIdentityV2(
            hostID: "host",
            modelIdentifier: "Mac-test",
            chipIdentity: "Apple-test"
        )
        XCTAssertThrowsError(
            try R12NativeRouteObservationV2(
                receiptID: "receipt",
                receiptSHA256: "not-a-sha",
                hostIdentity: host,
                hardwareProfileID: "profile",
                hardwareTierIdentity: .appleSiliconNative,
                routeID: "route",
                backendID: "backend",
                scaleFactor: R12ExactScaleFactorV2(numerator: 2, denominator: 1),
                inputContractSHA256: String(repeating: "a", count: 64),
                outputContractSHA256: String(repeating: "b", count: 64)
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidSHA256(field: "receipt_sha256")
            )
        }
    }

    func testDeterministicFixtureSelectsOnlyDeterministicContractAuthority() throws {
        let fixture = try Fixture.make()
        let candidate = try fixture.candidate(
            routeID: "route-deterministic",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicSDRTransition,
            scaleFactors: [.two],
            requirement: .deterministicContract
        )
        let request = try fixture.request(
            input: fixture.deterministicSDR,
            output: fixture.deterministicSDR,
            profile: try fixture.fixtureProfile(routes: [candidate.routeID])
        )

        let resolution = try R12RouteAndHardwareResolverV2.resolve(
            request: request,
            candidates: [candidate]
        )

        XCTAssertTrue(resolution.isAvailable)
        XCTAssertEqual(resolution.authority, .softwareFunctionOnly)
        XCTAssertEqual(resolution.selectedRoute?.authority, .softwareFunctionOnly)
        XCTAssertEqual(
            resolution.fallbackRecords,
            [
                R12RouteFallbackRecordV2(
                    attemptOrdinal: 0,
                    routeID: candidate.routeID,
                    backendID: fixture.deterministicBackend.backendID,
                    disposition: .selected,
                    rejectionReason: nil
                )
            ]
        )
        guard case .deterministicContract? = resolution.selectedRoute?.evidence else {
            return XCTFail("Fixture selection must carry deterministic_contract only")
        }
    }

    func testNativeRouteWithoutObservationIsUnavailable() throws {
        let fixture = try Fixture.make()
        let candidate = try fixture.nativeCandidate(routeID: "route-native")
        let request = try fixture.nativeRequest(routes: [candidate.routeID])

        let resolution = try R12RouteAndHardwareResolverV2.resolve(
            request: request,
            candidates: [candidate]
        )

        XCTAssertFalse(resolution.isAvailable)
        XCTAssertNil(resolution.selectedRoute)
        XCTAssertEqual(
            resolution.fallbackRecords.map(\.rejectionReason),
            [.nativeObservationMissing]
        )
    }

    func testNativeSelectionBindsExactHostReceiptProfileFormatsAndScale() throws {
        let fixture = try Fixture.make()
        let candidate = try fixture.nativeCandidate(routeID: "route-native")
        let request = try fixture.nativeRequest(routes: [candidate.routeID])
        let observation = try fixture.nativeObservation(
            routeID: candidate.routeID
        )

        let resolution = try R12RouteAndHardwareResolverV2.resolve(
            request: request,
            candidates: [candidate],
            nativeObservations: [observation]
        )

        XCTAssertTrue(resolution.isAvailable)
        XCTAssertEqual(resolution.selectedRoute?.routeID, candidate.routeID)
        XCTAssertEqual(resolution.selectedRoute?.authority, .softwareFunctionOnly)
        guard case .nativeObserved(let selectedObservation)? =
            resolution.selectedRoute?.evidence else {
            return XCTFail("Native selection must retain its exact observation")
        }
        XCTAssertEqual(selectedObservation, observation)
        XCTAssertEqual(selectedObservation.hostIdentity, fixture.host)
        XCTAssertEqual(selectedObservation.receiptID, "native-receipt")
        XCTAssertEqual(selectedObservation.receiptSHA256, Fixture.receiptSHA256)
    }

    func testEveryNativeObservationBindingMismatchIsRejected() throws {
        let fixture = try Fixture.make()
        let candidate = try fixture.nativeCandidate(routeID: "route-native")
        let request = try fixture.nativeRequest(routes: [candidate.routeID])
        let otherHost = try R12HostIdentityV2(
            hostID: "other-host",
            modelIdentifier: "Mac-other",
            chipIdentity: "Apple-other"
        )
        let mismatches = try [
            fixture.nativeObservation(routeID: candidate.routeID, host: otherHost),
            fixture.nativeObservation(
                routeID: candidate.routeID,
                hardwareProfileID: "other-profile"
            ),
            fixture.nativeObservation(
                routeID: candidate.routeID,
                hardwareTierIdentity: .deterministicFixture
            ),
            fixture.nativeObservation(
                routeID: candidate.routeID,
                backendID: "other-backend"
            ),
            fixture.nativeObservation(
                routeID: candidate.routeID,
                receiptSHA256: String(repeating: "d", count: 64)
            ),
            fixture.nativeObservation(
                routeID: candidate.routeID,
                scaleFactor: .threeOverTwo
            ),
            fixture.nativeObservation(
                routeID: candidate.routeID,
                inputContractSHA256: fixture.deterministicSDR.canonicalSHA256
            ),
            fixture.nativeObservation(
                routeID: candidate.routeID,
                outputContractSHA256: fixture.deterministicSDR.canonicalSHA256
            )
        ]

        for observation in mismatches {
            let resolution = try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [candidate],
                nativeObservations: [observation]
            )
            XCTAssertFalse(resolution.isAvailable)
            XCTAssertEqual(
                resolution.fallbackRecords.map(\.rejectionReason),
                [.nativeObservationMismatch]
            )
        }
    }

    func testFixtureContextCannotAuthorizeNativeEvenWithAReceipt() throws {
        let fixture = try Fixture.make()
        let candidate = try fixture.nativeCandidate(routeID: "route-native")
        let fixtureProfile = try fixture.fixtureProfile(routes: [candidate.routeID])
        let request = try fixture.request(
            input: fixture.nativeSDR,
            output: fixture.nativeSDR,
            profile: fixtureProfile
        )
        let observation = try fixture.nativeObservation(
            routeID: candidate.routeID,
            hardwareProfileID: fixtureProfile.profileID,
            hardwareTierIdentity: fixtureProfile.tierIdentity
        )

        let resolution = try R12RouteAndHardwareResolverV2.resolve(
            request: request,
            candidates: [candidate],
            nativeObservations: [observation]
        )

        XCTAssertFalse(resolution.isAvailable)
        XCTAssertEqual(
            resolution.fallbackRecords.map(\.rejectionReason),
            [.fixtureCannotAuthorizeNative]
        )
    }

    func testFallbackOrderingIsStableAndRecordsEveryInspectedRoute() throws {
        let fixture = try Fixture.make()
        let scaleMismatch = try fixture.candidate(
            routeID: "route-a",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicSDRTransition,
            scaleFactors: [.threeOverTwo],
            requirement: .deterministicContract
        )
        let formatMismatch = try fixture.candidate(
            routeID: "route-b",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicP010Transition,
            scaleFactors: [.two],
            requirement: .deterministicContract
        )
        let selected = try fixture.candidate(
            routeID: "route-c",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicSDRTransition,
            scaleFactors: [.two],
            requirement: .deterministicContract
        )
        let profile = try fixture.fixtureProfile(
            routes: [selected.routeID, formatMismatch.routeID, scaleMismatch.routeID]
        )
        let request = try fixture.request(
            input: fixture.deterministicSDR,
            output: fixture.deterministicSDR,
            profile: profile
        )

        let first = try R12RouteAndHardwareResolverV2.resolve(
            request: request,
            candidates: [selected, scaleMismatch, formatMismatch]
        )
        let second = try R12RouteAndHardwareResolverV2.resolve(
            request: request,
            candidates: [formatMismatch, selected, scaleMismatch]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selectedRoute?.routeID, "route-c")
        XCTAssertEqual(first.fallbackRecords.map(\.attemptOrdinal), [0, 1, 2])
        XCTAssertEqual(first.fallbackRecords.map(\.routeID), [
            "route-a",
            "route-b",
            "route-c"
        ])
        XCTAssertEqual(first.fallbackRecords.map(\.rejectionReason), [
            .exactScaleUnsupported,
            .formatTransitionUnsupported,
            nil
        ])
    }

    func testHardwareProfileAvailabilityPrecedesRouteClaims() throws {
        let fixture = try Fixture.make()
        let candidate = try fixture.candidate(
            routeID: "route-not-declared",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicSDRTransition,
            scaleFactors: [.two],
            requirement: .deterministicContract
        )
        let request = try fixture.request(
            input: fixture.deterministicSDR,
            output: fixture.deterministicSDR,
            profile: try fixture.fixtureProfile(routes: [])
        )

        let resolution = try R12RouteAndHardwareResolverV2.resolve(
            request: request,
            candidates: [candidate]
        )

        XCTAssertFalse(resolution.isAvailable)
        XCTAssertEqual(
            resolution.fallbackRecords.map(\.rejectionReason),
            [.hardwareProfileDoesNotDeclareRoute]
        )
    }

    func testNativeRequirementRejectsDeterministicFormatOrBackendEvidence() throws {
        let fixture = try Fixture.make()

        XCTAssertThrowsError(
            try fixture.candidate(
                routeID: "invalid-native",
                preferenceOrdinal: 0,
                backend: fixture.deterministicBackend,
                transition: fixture.deterministicSDRTransition,
                scaleFactors: [.two],
                requirement: .nativeObserved
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeRouteRequiresNativeEvidence(routeID: "invalid-native")
            )
        }

        let otherEvidence = try R12FormatEvidenceV2.nativeObserved(
            observationSHA256: String(repeating: "e", count: 64)
        )
        let otherContract = try R12MediaFormatContractV2(
            format: fixture.nativeSDR.format,
            metadata: fixture.nativeSDR.metadata,
            quality: fixture.nativeSDR.quality,
            evidence: otherEvidence
        )
        let mixedEvidenceBackend = try R12BackendFormatCapabilityV2(
            backendID: "mixed-native-evidence",
            supportedFormats: [otherContract],
            evidence: fixture.nativeEvidence
        )
        XCTAssertThrowsError(
            try fixture.candidate(
                routeID: "mixed-native",
                preferenceOrdinal: 0,
                backend: mixedEvidenceBackend,
                transition: R12RouteFormatTransitionV2(
                    input: otherContract,
                    output: otherContract
                ),
                scaleFactors: [.two],
                requirement: .nativeObserved
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeEvidenceMismatch(routeID: "mixed-native")
            )
        }
    }

    func testDuplicateAndOutOfScopeNativeEvidenceIsRejected() throws {
        let fixture = try Fixture.make()
        let native = try fixture.nativeCandidate(routeID: "route-native")
        let request = try fixture.nativeRequest(routes: [native.routeID])
        let observation = try fixture.nativeObservation(routeID: native.routeID)

        XCTAssertThrowsError(
            try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [native, native]
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .duplicateCandidateRoute(native.routeID)
            )
        }
        XCTAssertThrowsError(
            try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [native],
                nativeObservations: [observation, observation]
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .duplicateNativeObservation(native.routeID)
            )
        }

        let unknown = try fixture.nativeObservation(routeID: "unknown-route")
        XCTAssertThrowsError(
            try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [native],
                nativeObservations: [unknown]
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeObservationForUnknownRoute("unknown-route")
            )
        }

        let deterministic = try fixture.candidate(
            routeID: "route-deterministic",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicSDRTransition,
            scaleFactors: [.two],
            requirement: .deterministicContract
        )
        let disallowedObservation = try fixture.nativeObservation(
            routeID: deterministic.routeID,
            backendID: fixture.deterministicBackend.backendID,
            inputContractSHA256: fixture.deterministicSDR.canonicalSHA256,
            outputContractSHA256: fixture.deterministicSDR.canonicalSHA256
        )
        XCTAssertThrowsError(
            try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [deterministic],
                nativeObservations: [disallowedObservation]
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeObservationForDeterministicRoute(deterministic.routeID)
            )
        }
    }

    func testDuplicateCatalogFactsAndBackendFormatMismatchAreRejected() throws {
        let fixture = try Fixture.make()
        let duplicateScale = [try Scale.two, try R12ExactScaleFactorV2(
            numerator: 4,
            denominator: 2
        )]
        XCTAssertThrowsError(
            try fixture.candidate(
                routeID: "duplicate-scale",
                preferenceOrdinal: 0,
                backend: fixture.deterministicBackend,
                transition: fixture.deterministicSDRTransition,
                scaleFactors: duplicateScale,
                requirement: .deterministicContract
            )
        )

        let limitedBackend = try R12BackendFormatCapabilityV2(
            backendID: "limited-backend",
            supportedFormats: [fixture.deterministicSDR],
            evidence: fixture.deterministicEvidence
        )
        XCTAssertThrowsError(
            try fixture.candidate(
                routeID: "format-mismatch",
                preferenceOrdinal: 0,
                backend: limitedBackend,
                transition: fixture.deterministicP010Transition,
                scaleFactors: [.two],
                requirement: .deterministicContract
            )
        ) { error in
            guard case .backendFormatMismatch(let routeID, _) =
                error as? R12RouteResolverErrorV2 else {
                return XCTFail("Expected backendFormatMismatch, got \(error)")
            }
            XCTAssertEqual(routeID, "format-mismatch")
        }
    }
}

private typealias Scale = R12ExactScaleFactorV2

private extension R12ExactScaleFactorV2 {
    static var two: R12ExactScaleFactorV2 {
        get throws {
            try R12ExactScaleFactorV2(numerator: 2, denominator: 1)
        }
    }

    static var threeOverTwo: R12ExactScaleFactorV2 {
        get throws {
            try R12ExactScaleFactorV2(numerator: 3, denominator: 2)
        }
    }
}

private struct Fixture {
    static let deterministicFixtureID = "r12-route-fixture"
    static let nativeEvidenceSHA256 = String(repeating: "c", count: 64)
    static let receiptSHA256 = nativeEvidenceSHA256

    let deterministicEvidence: R12FormatEvidenceV2
    let nativeEvidence: R12FormatEvidenceV2
    let deterministicSDR: R12MediaFormatContractV2
    let deterministicP010: R12MediaFormatContractV2
    let nativeSDR: R12MediaFormatContractV2
    let deterministicBackend: R12BackendFormatCapabilityV2
    let nativeBackend: R12BackendFormatCapabilityV2
    let host: R12HostIdentityV2

    var deterministicSDRTransition: R12RouteFormatTransitionV2 {
        R12RouteFormatTransitionV2(
            input: deterministicSDR,
            output: deterministicSDR
        )
    }

    var deterministicP010Transition: R12RouteFormatTransitionV2 {
        R12RouteFormatTransitionV2(
            input: deterministicP010,
            output: deterministicP010
        )
    }

    var nativeSDRTransition: R12RouteFormatTransitionV2 {
        R12RouteFormatTransitionV2(input: nativeSDR, output: nativeSDR)
    }

    static func make() throws -> Fixture {
        let deterministicEvidence = try R12FormatEvidenceV2.deterministicContract(
            fixtureID: deterministicFixtureID
        )
        let nativeEvidence = try R12FormatEvidenceV2.nativeObserved(
            observationSHA256: nativeEvidenceSHA256
        )
        let sdrDescriptor = try R12MediaFormatDescriptorV2(
            storage: .nv12,
            bitDepth: .eight,
            chromaSubsampling: .yuv420,
            codeRange: .video,
            colorPrimaries: .bt709,
            transferFunction: .bt709,
            yCbCrMatrix: .bt709,
            chromaSiting: .left,
            scanStructure: .progressive,
            deinterlacePolicy: .notRequired,
            alphaSemantics: .none
        )
        let p010Descriptor = try R12MediaFormatDescriptorV2(
            storage: .p010,
            bitDepth: .ten,
            chromaSubsampling: .yuv420,
            codeRange: .video,
            colorPrimaries: .bt2020,
            transferFunction: .pq,
            yCbCrMatrix: .bt2020NCL,
            chromaSiting: .left,
            scanStructure: .progressive,
            deinterlacePolicy: .notRequired,
            alphaSemantics: .none
        )
        let deterministicSDR = try contract(
            descriptor: sdrDescriptor,
            metadata: .sdrPreserving,
            evidence: deterministicEvidence
        )
        let deterministicP010 = try contract(
            descriptor: p010Descriptor,
            metadata: .hdrPreserving,
            evidence: deterministicEvidence
        )
        let nativeSDR = try contract(
            descriptor: sdrDescriptor,
            metadata: .sdrPreserving,
            evidence: nativeEvidence
        )
        return try Fixture(
            deterministicEvidence: deterministicEvidence,
            nativeEvidence: nativeEvidence,
            deterministicSDR: deterministicSDR,
            deterministicP010: deterministicP010,
            nativeSDR: nativeSDR,
            deterministicBackend: R12BackendFormatCapabilityV2(
                backendID: "deterministic-backend",
                supportedFormats: [deterministicSDR, deterministicP010],
                evidence: deterministicEvidence
            ),
            nativeBackend: R12BackendFormatCapabilityV2(
                backendID: "native-backend",
                supportedFormats: [nativeSDR],
                evidence: nativeEvidence
            ),
            host: R12HostIdentityV2(
                hostID: "native-host",
                modelIdentifier: "Mac-test",
                chipIdentity: "Apple-test"
            )
        )
    }

    func candidate(
        routeID: String,
        preferenceOrdinal: Int,
        backend: R12BackendFormatCapabilityV2,
        transition: R12RouteFormatTransitionV2,
        scaleFactors: [R12ExactScaleFactorV2],
        requirement: R12RouteExecutionRequirementV2
    ) throws -> R12RouteCapabilityV2 {
        try R12RouteCapabilityV2(
            routeID: routeID,
            preferenceOrdinal: preferenceOrdinal,
            backendCapability: backend,
            supportedScaleFactors: scaleFactors,
            formatTransitions: [transition],
            executionRequirement: requirement
        )
    }

    func nativeCandidate(routeID: String) throws -> R12RouteCapabilityV2 {
        try candidate(
            routeID: routeID,
            preferenceOrdinal: 0,
            backend: nativeBackend,
            transition: nativeSDRTransition,
            scaleFactors: [.two],
            requirement: .nativeObserved
        )
    }

    func fixtureProfile(routes: [String]) throws -> R12HardwareCapabilityProfileV2 {
        try R12HardwareCapabilityProfileV2(
            profileID: "fixture-profile",
            tierIdentity: .deterministicFixture,
            executionContext: .deterministicFixture,
            availableRouteIDs: routes
        )
    }

    func nativeProfile(routes: [String]) throws -> R12HardwareCapabilityProfileV2 {
        try R12HardwareCapabilityProfileV2(
            profileID: "native-profile",
            tierIdentity: .appleSiliconNative,
            executionContext: .nativeHost(host),
            availableRouteIDs: routes
        )
    }

    func request(
        input: R12MediaFormatContractV2,
        output: R12MediaFormatContractV2,
        profile: R12HardwareCapabilityProfileV2
    ) throws -> R12RouteRequestV2 {
        try R12RouteRequestV2(
            sourceResolution: R12ResolutionV2(width: 1_920, height: 1_080),
            targetResolution: R12ResolutionV2(width: 3_840, height: 2_160),
            inputFormat: input,
            outputFormat: output,
            hardwareProfile: profile
        )
    }

    func nativeRequest(routes: [String]) throws -> R12RouteRequestV2 {
        try request(
            input: nativeSDR,
            output: nativeSDR,
            profile: nativeProfile(routes: routes)
        )
    }

    func nativeObservation(
        routeID: String,
        receiptSHA256: String = Fixture.receiptSHA256,
        host: R12HostIdentityV2? = nil,
        hardwareProfileID: String = "native-profile",
        hardwareTierIdentity: R12HardwareTierIdentityV2 = .appleSiliconNative,
        backendID: String = "native-backend",
        scaleFactor: R12ExactScaleFactorV2? = nil,
        inputContractSHA256: String? = nil,
        outputContractSHA256: String? = nil
    ) throws -> R12NativeRouteObservationV2 {
        try R12NativeRouteObservationV2(
            receiptID: "native-receipt",
            receiptSHA256: receiptSHA256,
            hostIdentity: host ?? self.host,
            hardwareProfileID: hardwareProfileID,
            hardwareTierIdentity: hardwareTierIdentity,
            routeID: routeID,
            backendID: backendID,
            scaleFactor: scaleFactor ?? .two,
            inputContractSHA256: inputContractSHA256 ?? nativeSDR.canonicalSHA256,
            outputContractSHA256: outputContractSHA256 ?? nativeSDR.canonicalSHA256
        )
    }

    private static func contract(
        descriptor: R12MediaFormatDescriptorV2,
        metadata: R12MetadataPreservationContractV2,
        evidence: R12FormatEvidenceV2
    ) throws -> R12MediaFormatContractV2 {
        try R12MediaFormatContractV2(
            format: descriptor,
            metadata: metadata,
            quality: .preserving(alpha: false),
            evidence: evidence
        )
    }
}
