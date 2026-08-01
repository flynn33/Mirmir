import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

@available(macOS 15.4, *)
final class R03ASHComparatorTests: XCTestCase {
    func testIdentityAndRouteBindingAreExactForBothPreregisteredRoutes() async throws {
        let subject = try XCTUnwrap(
            R03DeterministicBackendCatalog.subject(.ashCustomMetal)
        )
        let routes = R03ScaleRoute.allCases.filter {
            subject.routeIDs.contains($0.routeID)
        }
        for route in routes {
            let routeProbe = R03ASHRouteProbe()
            let completion = R03ASHCompletionProbe()
            let backend = try makeInjectedBackend(
                route: route,
                routeProbe: routeProbe,
                completion: completion
            )

            XCTAssertEqual(backend.subject.id, .ashCustomMetal)
            XCTAssertEqual(backend.subject.capabilityID, "A17")
            XCTAssertEqual(backend.subject.frameworkIdentity, "Metal")
            XCTAssertEqual(
                backend.subject.qualificationRole,
                .retainedReferenceComparator
            )
            XCTAssertEqual(
                backend.subject.productDefaultEligibility,
                .ineligibleReferenceRole
            )
            XCTAssertEqual(backend.identity.backendID, "r03.ash-custom-metal")
            XCTAssertEqual(
                backend.identity.backendRevision,
                R03DeterministicBackendCatalog.backendRevision
            )
            XCTAssertEqual(backend.identity.modelAssetsIdentity, .notRequired)
            XCTAssertEqual(
                backend.routeIdentity.configurationIdentity,
                backend.subject.configurationIdentity(for: route)
            )
            XCTAssertEqual(
                backend.routeIdentity.policyIdentity,
                R03DeterministicBackendCatalog.policyIdentity
            )
            XCTAssertEqual(
                backend.routeIdentity.materialDecisionIdentity,
                R03DeterministicBackendCatalog.materialDecisionIdentity
            )

            let creation = await backend.makeSession(
                configuration: try backend.makeConfiguration(),
                context: try R03DeterministicBackendTestSupport.makeContext(
                    subjectID: .ashCustomMetal
                )
            )
            guard case .created(let session) = creation else {
                return XCTFail("The injected exact A17 fixture session must create")
            }
            XCTAssertEqual(
                routeProbe.routes,
                [route == .scale3Over2 ? .direct3Over2 : .direct2x]
            )
            let sessionIdentity = await session.identity
            XCTAssertEqual(sessionIdentity, backend.routeIdentity)
            _ = await session.finish()
        }
    }

    func testAdmissionIsFixtureOnlyAndNotObservedIsTypedUnavailable() async throws {
        let routeProbe = R03ASHRouteProbe()
        let backend = try makeInjectedBackend(
            route: .scale3Over2,
            routeProbe: routeProbe,
            completion: R03ASHCompletionProbe()
        )
        let configuration = try backend.makeConfiguration()

        let productContext = try R03DeterministicBackendTestSupport.makeContext(
            subjectID: .ashCustomMetal,
            admissionScope: .product
        )
        guard case .rejected(let productRejection) = await backend.makeSession(
            configuration: configuration,
            context: productContext
        ) else {
            return XCTFail("The R03 ASH comparator must reject product admission")
        }
        XCTAssertEqual(productRejection.reason, "r03_session_contract_mismatch")
        XCTAssertEqual(productRejection.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(productRejection.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertTrue(routeProbe.routes.isEmpty)

        let notObserved = try R03DeterministicBackendCatalog
            .makeNotObservedCapability(for: .ashCustomMetal)
        let unavailableContext = try R03DeterministicBackendTestSupport.makeContext(
            subjectID: .ashCustomMetal,
            capability: notObserved
        )
        guard case .unavailable(let unavailable) = await backend.makeSession(
            configuration: configuration,
            context: unavailableContext
        ) else {
            return XCTFail("A not-observed A17 capability must be unavailable")
        }
        XCTAssertEqual(unavailable.reason, "r03_capability_unavailable")
        XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertTrue(routeProbe.routes.isEmpty)
    }

    func testFactoryFailureIsTypedUnavailableWithoutFallback() async throws {
        struct MissingLockedRuntime: Error {}

        let backend = try R03ASHComparatorBackend(
            route: .scale2x,
            ashBackendFactory: { _ in throw MissingLockedRuntime() }
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R03DeterministicBackendTestSupport.makeContext(
                subjectID: .ashCustomMetal
            )
        )
        guard case .unavailable(let unavailable) = creation else {
            return XCTFail("Missing locked assets or Metal runtime must be unavailable")
        }
        XCTAssertEqual(unavailable.reason, "r03_capability_unavailable")
        XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
    }

    func testCompletionTransfersToOutputLifetimeTokenExactlyOnce() async throws {
        let completion = R03ASHCompletionProbe()
        let outputReleaseProbe = R03ASHReleaseProbe()
        let backend = try makeInjectedBackend(
            route: .scale3Over2,
            routeProbe: R03ASHRouteProbe(),
            completion: completion,
            outputReleaseObserver: { identity in
                outputReleaseProbe.record(identity)
            }
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R03DeterministicBackendTestSupport.makeContext(
                subjectID: .ashCustomMetal
            )
        )
        guard case .created(let session) = creation else {
            return XCTFail("The injected exact A17 fixture session must create")
        }
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 4,
            seed: 71,
            tokenPrefix: "r03.ash.input"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .processed(let output) = outcome else {
            return XCTFail("The injected ownership fixture must process")
        }
        XCTAssertEqual(completion.finishCount, 0)
        XCTAssertEqual(output.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(output.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(output.sequenceNumber, fixture.frame.sequenceNumber)
        XCTAssertEqual(output.presentationTimestamp, fixture.frame.presentationTimestamp)
        XCTAssertEqual(output.duration, fixture.frame.duration)
        XCTAssertEqual(output.colorDescription, fixture.frame.colorDescription)
        XCTAssertEqual(output.metadataIdentity, fixture.frame.metadataIdentity)
        XCTAssertNoThrow(
            try R03NV12Contract.validate(
                pixelBuffer: output.pixelBuffer,
                resolution: .p1080
            )
        )
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )

        output.resourceLifetimeToken.release()
        output.resourceLifetimeToken.release()
        XCTAssertEqual(completion.finishCount, 1)
        XCTAssertEqual(
            outputReleaseProbe.identities,
            ["r03.ash-custom-metal.output.4"]
        )
        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.terminalizationCount, 1)
    }

    func testBundledLockedMetalPathExecutesOnlyWhenExactResourcesArePresent() async throws {
        let bundle = Bundle(for: R03ASHComparatorBackend.self)
        let resources = bundle.resourceURL ?? bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let lockedRoot = resources
            .appendingPathComponent("ASH", isDirectory: true)
            .appendingPathComponent("LockedV3", isDirectory: true)
        let observedNames = (try? FileManager.default.contentsOfDirectory(
            atPath: lockedRoot.path
        ).sorted()) ?? []
        let exactResourcesPresent = observedNames
            == ASHLockedArtifactStoreV3.expectedFilenames

        let backend = try R03ASHComparatorBackend(
            route: .scale3Over2,
            bundle: bundle
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R03DeterministicBackendTestSupport.makeContext(
                subjectID: .ashCustomMetal
            )
        )
        if !exactResourcesPresent {
            guard case .unavailable(let unavailable) = creation else {
                return XCTFail("Absent exact LockedV3 resources must be unavailable")
            }
            XCTAssertEqual(unavailable.reason, "r03_capability_unavailable")
            XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
            return
        }

        switch creation {
        case .created(let session):
            let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
                route: .scale3Over2,
                sequenceNumber: 0,
                tokenPrefix: "r03.ash.genuine"
            )
            let outcome = await session.submit(fixture.frame)
            switch outcome {
            case .processed(let output):
                XCTAssertEqual(output.processingIdentity.route, backend.routeIdentity)
                XCTAssertTrue(output.processingIdentity.fallbackHistory.isEmpty)
                output.resourceLifetimeToken.release()
            case .unavailable(let unavailable):
                XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
                XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
            case .rejected, .failed:
                XCTFail("The genuine locked-Metal frame must process or report unavailable")
            }
            _ = await session.finish()
        case .unavailable(let unavailable):
            XCTAssertEqual(unavailable.processingIdentity.route, backend.routeIdentity)
            XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
        case .rejected, .failed:
            XCTFail("Exact genuine construction must create or report unavailable")
        }
    }

    private func makeInjectedBackend(
        route: R03ScaleRoute,
        routeProbe: R03ASHRouteProbe,
        completion: R03ASHCompletionProbe,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03ASHComparatorBackend {
        try R03ASHComparatorBackend(
            route: route,
            ashBackendFactory: { ashRoute in
                routeProbe.record(ashRoute)
                return R03ASHFixtureBackend(completion: completion)
            },
            outputReleaseObserver: outputReleaseObserver
        )
    }
}

@available(macOS 15.4, *)
private final class R03ASHFixtureBackend: ASHUpscaleBackend, @unchecked Sendable {
    private let completion: R03ASHCompletionProbe

    init(completion: R03ASHCompletionProbe) {
        self.completion = completion
    }

    func reset() {}

    func process(
        source _: CVPixelBuffer,
        into _: CVPixelBuffer,
        context _: ASHUpscaleFrameContext
    ) async throws -> any ASHUpscaleFrameCompletion {
        completion
    }
}

@available(macOS 15.4, *)
private final class R03ASHCompletionProbe: ASHUpscaleFrameCompletion,
    @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var finishCount: Int {
        count.withLock { $0 }
    }

    func finishAfterAppend() {
        count.withLock { $0 += 1 }
    }
}

@available(macOS 15.4, *)
private final class R03ASHRouteProbe: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [ASHSpatialRouteV2]())

    var routes: [ASHSpatialRouteV2] {
        storage.withLock { $0 }
    }

    func record(_ route: ASHSpatialRouteV2) {
        storage.withLock { $0.append(route) }
    }
}

private final class R03ASHReleaseProbe: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())

    var identities: [String] {
        storage.withLock { $0 }
    }

    func record(_ identity: String) {
        storage.withLock { $0.append(identity) }
    }
}
