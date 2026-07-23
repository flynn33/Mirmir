import CryptoKit
import Darwin
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

    // swiftlint:disable:next function_body_length
    func testResolutionBoundsValidateRangesAlignmentsAndBoundaries() {
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 0,
                maximumWidth: 1_920,
                minimumHeight: 2,
                maximumHeight: 1_080,
                widthAlignment: 2,
                heightAlignment: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidResolutionRange(
                    axis: "width",
                    minimum: 0,
                    maximum: 1_920
                )
            )
        }
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 1_920,
                minimumHeight: 1_080,
                maximumHeight: 720,
                widthAlignment: 2,
                heightAlignment: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidResolutionRange(
                    axis: "height",
                    minimum: 1_080,
                    maximum: 720
                )
            )
        }
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 1_920,
                maximumWidth: 1_280,
                minimumHeight: 2,
                maximumHeight: 1_080,
                widthAlignment: 2,
                heightAlignment: 2
            )
        )
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 1_920,
                minimumHeight: 2,
                maximumHeight: 1_080,
                widthAlignment: 0,
                heightAlignment: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidResolutionAlignment(axis: "width", alignment: 0)
            )
        }
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 1_920,
                minimumHeight: 2,
                maximumHeight: 1_080,
                widthAlignment: 2,
                heightAlignment: -1
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidResolutionAlignment(axis: "height", alignment: -1)
            )
        }
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 3,
                maximumWidth: 1_920,
                minimumHeight: 2,
                maximumHeight: 1_080,
                widthAlignment: 2,
                heightAlignment: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .unalignedResolutionBoundary(
                    axis: "width",
                    boundary: "minimum",
                    value: 3,
                    alignment: 2
                )
            )
        }
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 1_919,
                minimumHeight: 2,
                maximumHeight: 1_080,
                widthAlignment: 2,
                heightAlignment: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .unalignedResolutionBoundary(
                    axis: "width",
                    boundary: "maximum",
                    value: 1_919,
                    alignment: 2
                )
            )
        }
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 1_920,
                minimumHeight: 3,
                maximumHeight: 1_080,
                widthAlignment: 2,
                heightAlignment: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .unalignedResolutionBoundary(
                    axis: "height",
                    boundary: "minimum",
                    value: 3,
                    alignment: 2
                )
            )
        }
        XCTAssertThrowsError(
            try R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 1_920,
                minimumHeight: 2,
                maximumHeight: 1_079,
                widthAlignment: 2,
                heightAlignment: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .unalignedResolutionBoundary(
                    axis: "height",
                    boundary: "maximum",
                    value: 1_079,
                    alignment: 2
                )
            )
        }
    }

    func testResolutionBoundsAreExactAtLimitsAndSafeNearIntegerOverflow() throws {
        let bounds = try R12RouteResolutionBoundsV2(
            minimumWidth: 2,
            maximumWidth: Int.max - 1,
            minimumHeight: 2,
            maximumHeight: Int.max - 1,
            widthAlignment: 2,
            heightAlignment: 2
        )

        XCTAssertTrue(
            bounds.supports(try R12ResolutionV2(width: 2, height: 2))
        )
        XCTAssertTrue(
            bounds.supports(
                try R12ResolutionV2(
                    width: Int.max - 1,
                    height: Int.max - 1
                )
            )
        )
        XCTAssertFalse(
            bounds.supports(
                try R12ResolutionV2(width: Int.max, height: Int.max)
            )
        )
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

        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                Data("{}".utf8),
                expectedSHA256: String(repeating: "a", count: 64)
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidSHA256(field: "expected_receipt_sha256")
            )
        }
    }

    func testCanonicalReceiptRejectsMadeUpTamperedAndNoncanonicalBytes() throws {
        let fixture = try Fixture.make()
        let bytes = try fixture.nativeReceiptBytes(routeID: "route-native")
        let digest = fixtureSHA256(bytes)
        XCTAssertNoThrow(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                bytes,
                expectedSHA256: digest
            )
        )

        let madeUp = fixtureSHA256(Data("made-up-receipt".utf8))
        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                bytes,
                expectedSHA256: madeUp
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeReceiptDigestMismatch(
                    expected: madeUp,
                    actual: digest
                )
            )
        }

        var tampered = bytes
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                tampered,
                expectedSHA256: digest
            )
        )

        var noncanonical = bytes
        noncanonical.append(0x0a)
        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                noncanonical,
                expectedSHA256: fixtureSHA256(noncanonical)
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeReceiptNotCanonical
            )
        }
    }

    func testCanonicalReceiptFileLoaderRejectsSymlinkSubstitution() throws {
        let fixture = try Fixture.make()
        let bytes = try fixture.nativeReceiptBytes(routeID: "route-native")
        let root = try makeReceiptTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let receipt = root.appendingPathComponent("receipt.json")
        let symlink = root.appendingPathComponent("receipt-link.json")
        try bytes.write(to: receipt, options: .atomic)
        XCTAssertNoThrow(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                at: receipt,
                expectedSHA256: fixtureSHA256(bytes)
            )
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: receipt
        )

        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                at: symlink,
                expectedSHA256: fixtureSHA256(bytes)
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .unsafeNativeReceiptFile(symlink.path)
            )
        }
    }

    func testCanonicalReceiptFileLoaderRejectsSymlinkedAncestor() throws {
        let fixture = try Fixture.make()
        let bytes = try fixture.nativeReceiptBytes(routeID: "route-native")
        let root = try makeReceiptTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let trusted = root.appendingPathComponent("trusted", isDirectory: true)
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(
            at: trusted,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: actual,
            withIntermediateDirectories: false
        )
        let receipt = actual.appendingPathComponent("receipt.json")
        try bytes.write(to: receipt, options: .atomic)
        let linkedAncestor = trusted.appendingPathComponent(
            "link",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedAncestor,
            withDestinationURL: actual
        )
        let substituted = linkedAncestor.appendingPathComponent("receipt.json")

        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                at: substituted,
                expectedSHA256: fixtureSHA256(bytes)
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .unsafeNativeReceiptFile(substituted.path)
            )
        }
    }

    func testCanonicalReceiptFileLoaderRejectsPreexistingOversizedFile() throws {
        let root = try makeReceiptTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let oversized = Data(
            repeating: 0x61,
            count: R12NativeRouteObservationV2.maximumReceiptSize + 1
        )
        let receipt = root.appendingPathComponent("oversized.json")
        try oversized.write(to: receipt)

        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceipt(
                at: receipt,
                expectedSHA256: fixtureSHA256(oversized)
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeReceiptTooLarge(
                    maximumSize: R12NativeRouteObservationV2.maximumReceiptSize
                )
            )
        }
    }

    func testCanonicalReceiptReadRejectsGrowthAfterDescriptorOpen() throws {
        let fixture = try Fixture.make()
        let bytes = try fixture.nativeReceiptBytes(routeID: "route-native")
        let root = try makeReceiptTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let receipt = root.appendingPathComponent("growing.json")
        try bytes.write(to: receipt)
        let growth = Data(
            repeating: 0x20,
            count: R12NativeRouteObservationV2.maximumReceiptSize
                - bytes.count + 1
        )

        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceiptForTesting(
                at: receipt,
                expectedSHA256: fixtureSHA256(bytes),
                afterOpen: {
                    let writer = try FileHandle(forWritingTo: receipt)
                    defer {
                        try? writer.close()
                    }
                    _ = try writer.seekToEnd()
                    try writer.write(contentsOf: growth)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeReceiptTooLarge(
                    maximumSize: R12NativeRouteObservationV2.maximumReceiptSize
                )
            )
        }
    }

    func testCanonicalReceiptReadRejectsLeafRenameAfterDescriptorOpen() throws {
        let fixture = try Fixture.make()
        let bytes = try fixture.nativeReceiptBytes(routeID: "route-native")
        let root = try makeReceiptTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let receipt = root.appendingPathComponent("receipt.json")
        let renamed = root.appendingPathComponent("renamed.json")
        try bytes.write(to: receipt)

        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceiptForTesting(
                at: receipt,
                expectedSHA256: fixtureSHA256(bytes),
                afterOpen: {
                    try FileManager.default.moveItem(
                        at: receipt,
                        to: renamed
                    )
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeReceiptFileChanged(receipt.path)
            )
        }
    }

    func testCanonicalReceiptReadRejectsAncestorSubstitutionAfterOpen() throws {
        let fixture = try Fixture.make()
        let bytes = try fixture.nativeReceiptBytes(routeID: "route-native")
        let root = try makeReceiptTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let displaced = root.appendingPathComponent(
            "displaced",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false
        )
        let receipt = parent.appendingPathComponent("receipt.json")
        try bytes.write(to: receipt)

        XCTAssertThrowsError(
            try R12NativeRouteObservationV2.loadCanonicalReceiptForTesting(
                at: receipt,
                expectedSHA256: fixtureSHA256(bytes),
                afterOpen: {
                    try FileManager.default.moveItem(
                        at: parent,
                        to: displaced
                    )
                    try FileManager.default.createDirectory(
                        at: parent,
                        withIntermediateDirectories: false
                    )
                    try bytes.write(to: receipt)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .nativeReceiptFileChanged(receipt.path)
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

    // swiftlint:disable:next function_body_length
    func testResolverEnforcesSourceAndTargetRangeAndAlignmentBounds() throws {
        let fixture = try Fixture.make()
        let sourceBounds = try R12RouteResolutionBoundsV2(
            minimumWidth: 640,
            maximumWidth: 1_920,
            minimumHeight: 360,
            maximumHeight: 1_080,
            widthAlignment: 4,
            heightAlignment: 4
        )
        let targetBounds = try R12RouteResolutionBoundsV2(
            minimumWidth: 1_280,
            maximumWidth: 3_840,
            minimumHeight: 720,
            maximumHeight: 2_160,
            widthAlignment: 8,
            heightAlignment: 8
        )
        let sourceLimited = try fixture.candidate(
            routeID: "source-limited",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicSDRTransition,
            sourceBounds: sourceBounds,
            scaleFactors: [.two],
            requirement: .deterministicContract
        )
        let targetLimited = try fixture.candidate(
            routeID: "target-limited",
            preferenceOrdinal: 0,
            backend: fixture.deterministicBackend,
            transition: fixture.deterministicSDRTransition,
            targetBounds: targetBounds,
            scaleFactors: [.two],
            requirement: .deterministicContract
        )
        let profile = try fixture.fixtureProfile(
            routes: [sourceLimited.routeID, targetLimited.routeID]
        )

        for dimensions in [
            (638, 360, 1_276, 720),
            (640, 358, 1_280, 716),
            (1_922, 1_080, 3_844, 2_160),
            (1_920, 1_082, 3_840, 2_164),
            (1_918, 1_080, 3_836, 2_160),
            (1_920, 1_078, 3_840, 2_156)
        ] {
            let request = try fixture.request(
                input: fixture.deterministicSDR,
                output: fixture.deterministicSDR,
                profile: profile,
                sourceWidth: dimensions.0,
                sourceHeight: dimensions.1,
                targetWidth: dimensions.2,
                targetHeight: dimensions.3
            )
            let resolution = try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [sourceLimited]
            )
            XCTAssertEqual(
                resolution.fallbackRecords.map(\.rejectionReason),
                [.sourceResolutionUnsupported]
            )
        }

        for dimensions in [
            (638, 360, 1_276, 720),
            (640, 358, 1_280, 716),
            (1_922, 1_080, 3_844, 2_160),
            (1_920, 1_082, 3_840, 2_164),
            (1_918, 1_080, 3_836, 2_160),
            (1_920, 1_078, 3_840, 2_156)
        ] {
            let request = try fixture.request(
                input: fixture.deterministicSDR,
                output: fixture.deterministicSDR,
                profile: profile,
                sourceWidth: dimensions.0,
                sourceHeight: dimensions.1,
                targetWidth: dimensions.2,
                targetHeight: dimensions.3
            )
            let resolution = try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [targetLimited]
            )
            XCTAssertEqual(
                resolution.fallbackRecords.map(\.rejectionReason),
                [.targetResolutionUnsupported]
            )
        }

        for dimensions in [
            (640, 360, 1_280, 720),
            (1_920, 1_080, 3_840, 2_160)
        ] {
            let request = try fixture.request(
                input: fixture.deterministicSDR,
                output: fixture.deterministicSDR,
                profile: profile,
                sourceWidth: dimensions.0,
                sourceHeight: dimensions.1,
                targetWidth: dimensions.2,
                targetHeight: dimensions.3
            )
            let resolution = try R12RouteAndHardwareResolverV2.resolve(
                request: request,
                candidates: [targetLimited]
            )
            XCTAssertEqual(
                resolution.selectedRoute?.routeID,
                targetLimited.routeID
            )
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

    func testCanonicalReceiptIntegrityDoesNotClaimExternalObservation() throws {
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

        XCTAssertFalse(resolution.isAvailable)
        XCTAssertNil(resolution.selectedRoute)
        XCTAssertEqual(
            resolution.fallbackRecords.map(\.rejectionReason),
            [.nativeObservationNotObserved]
        )
        XCTAssertEqual(observation.hostIdentity, fixture.host)
        XCTAssertEqual(observation.receiptID, "native-receipt")
        XCTAssertEqual(
            observation.authority,
            .integrityVerifiedObservationNotObserved
        )
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

    func testNativeRouteRejectsRepeatedCharacterObservationHash() throws {
        let fixture = try Fixture.make()
        let repeatedEvidence = try R12FormatEvidenceV2.nativeObserved(
            observationSHA256: String(repeating: "c", count: 64)
        )
        let repeatedContract = try R12MediaFormatContractV2(
            format: fixture.nativeSDR.format,
            metadata: fixture.nativeSDR.metadata,
            quality: fixture.nativeSDR.quality,
            evidence: repeatedEvidence
        )
        let backend = try R12BackendFormatCapabilityV2(
            backendID: "repeated-hash-backend",
            supportedFormats: [repeatedContract],
            evidence: repeatedEvidence
        )

        XCTAssertThrowsError(
            try fixture.candidate(
                routeID: "repeated-hash-route",
                preferenceOrdinal: 0,
                backend: backend,
                transition: R12RouteFormatTransitionV2(
                    input: repeatedContract,
                    output: repeatedContract
                ),
                scaleFactors: [.two],
                requirement: .nativeObserved
            )
        ) { error in
            XCTAssertEqual(
                error as? R12RouteResolverErrorV2,
                .invalidSHA256(field: "native_observation_sha256")
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
    static let nativeEvidenceSHA256 = fixtureSHA256(
        Data("r12-native-evidence-anchor".utf8)
    )

    let deterministicEvidence: R12FormatEvidenceV2
    let nativeEvidence: R12FormatEvidenceV2
    let deterministicSDR: R12MediaFormatContractV2
    let deterministicP010: R12MediaFormatContractV2
    let nativeSDR: R12MediaFormatContractV2
    let deterministicBackend: R12BackendFormatCapabilityV2
    let nativeBackend: R12BackendFormatCapabilityV2
    let host: R12HostIdentityV2
    let sourceBounds: R12RouteResolutionBoundsV2
    let targetBounds: R12RouteResolutionBoundsV2

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
            ),
            sourceBounds: R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 8_192,
                minimumHeight: 2,
                maximumHeight: 8_192,
                widthAlignment: 2,
                heightAlignment: 2
            ),
            targetBounds: R12RouteResolutionBoundsV2(
                minimumWidth: 2,
                maximumWidth: 16_384,
                minimumHeight: 2,
                maximumHeight: 16_384,
                widthAlignment: 2,
                heightAlignment: 2
            )
        )
    }

    func candidate(
        routeID: String,
        preferenceOrdinal: Int,
        backend: R12BackendFormatCapabilityV2,
        transition: R12RouteFormatTransitionV2,
        sourceBounds: R12RouteResolutionBoundsV2? = nil,
        targetBounds: R12RouteResolutionBoundsV2? = nil,
        scaleFactors: [R12ExactScaleFactorV2],
        requirement: R12RouteExecutionRequirementV2
    ) throws -> R12RouteCapabilityV2 {
        try R12RouteCapabilityV2(
            routeID: routeID,
            preferenceOrdinal: preferenceOrdinal,
            backendCapability: backend,
            sourceResolutionBounds: sourceBounds ?? self.sourceBounds,
            targetResolutionBounds: targetBounds ?? self.targetBounds,
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
        profile: R12HardwareCapabilityProfileV2,
        sourceWidth: Int = 1_920,
        sourceHeight: Int = 1_080,
        targetWidth: Int = 3_840,
        targetHeight: Int = 2_160
    ) throws -> R12RouteRequestV2 {
        try R12RouteRequestV2(
            sourceResolution: R12ResolutionV2(
                width: sourceWidth,
                height: sourceHeight
            ),
            targetResolution: R12ResolutionV2(
                width: targetWidth,
                height: targetHeight
            ),
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
        host: R12HostIdentityV2? = nil,
        hardwareProfileID: String = "native-profile",
        hardwareTierIdentity: R12HardwareTierIdentityV2 = .appleSiliconNative,
        backendID: String = "native-backend",
        scaleFactor: R12ExactScaleFactorV2? = nil,
        inputContractSHA256: String? = nil,
        outputContractSHA256: String? = nil
    ) throws -> R12NativeRouteObservationV2 {
        let bytes = try nativeReceiptBytes(
            routeID: routeID,
            host: host,
            hardwareProfileID: hardwareProfileID,
            hardwareTierIdentity: hardwareTierIdentity,
            backendID: backendID,
            scaleFactor: scaleFactor,
            inputContractSHA256: inputContractSHA256,
            outputContractSHA256: outputContractSHA256
        )
        return try R12NativeRouteObservationV2.loadCanonicalReceipt(
            bytes,
            expectedSHA256: fixtureSHA256(bytes)
        )
    }

    func nativeReceiptBytes(
        routeID: String,
        host: R12HostIdentityV2? = nil,
        hardwareProfileID: String = "native-profile",
        hardwareTierIdentity: R12HardwareTierIdentityV2 = .appleSiliconNative,
        backendID: String = "native-backend",
        scaleFactor: R12ExactScaleFactorV2? = nil,
        inputContractSHA256: String? = nil,
        outputContractSHA256: String? = nil
    ) throws -> Data {
        let host = host ?? self.host
        let scaleFactor = try scaleFactor ?? .two
        let document: [String: Any] = [
            "artifact_kind": R12NativeRouteObservationV2.artifactKind,
            "schema_version": R12NativeRouteObservationV2.schemaVersion,
            "receipt_id": "native-receipt",
            "host_id": host.hostID,
            "model_identifier": host.modelIdentifier,
            "chip_identity": host.chipIdentity,
            "hardware_profile_id": hardwareProfileID,
            "hardware_tier_id": hardwareTierIdentity.rawValue,
            "route_id": routeID,
            "backend_id": backendID,
            "scale_numerator": scaleFactor.numerator,
            "scale_denominator": scaleFactor.denominator,
            "input_contract_sha256":
                inputContractSHA256 ?? nativeSDR.canonicalSHA256,
            "output_contract_sha256":
                outputContractSHA256 ?? nativeSDR.canonicalSHA256
        ]
        return try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
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

private func makeReceiptTestDirectory() throws -> URL {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    guard let canonicalPath = temporaryDirectory.path.withCString({
        realpath($0, nil)
    }) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer {
        free(canonicalPath)
    }
    let root = URL(
        fileURLWithPath: String(cString: canonicalPath),
        isDirectory: true
    )
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    return root
}

private func fixtureSHA256(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
