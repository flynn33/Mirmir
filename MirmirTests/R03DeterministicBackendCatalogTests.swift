import XCTest
@testable import Mirmir

final class R03DeterministicBackendCatalogTests: XCTestCase {
    func testCatalogMatchesPreregisteredSubjectMatrixExactly() {
        let expected: [ExpectedSubject] = [
            .init(
                id: .mpsLanczos,
                kind: .wholeFrameBackend,
                capabilityID: "A11",
                framework: "MetalPerformanceShaders",
                role: .deterministicGPUQualityBaseline,
                eligibility: .candidateAfterObservedQualification,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .mpsBilinear,
                kind: .wholeFrameBackend,
                capabilityID: "A12",
                framework: "MetalPerformanceShaders",
                role: .diagnosticFastLowerBound,
                eligibility: .ineligibleReferenceRole,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .coreImageLanczos,
                kind: .wholeFrameBackend,
                capabilityID: "A14",
                framework: "CoreImage",
                role: .compatibilityReference,
                eligibility: .ineligibleReferenceRole,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .coreImageBicubic,
                kind: .wholeFrameBackend,
                capabilityID: "A14",
                framework: "CoreImage",
                role: .tunableReferenceFallback,
                eligibility: .ineligibleReferenceRole,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .vImageLanczos3,
                kind: .wholeFrameBackend,
                capabilityID: "A16",
                framework: "Accelerate",
                role: .cpuReference,
                eligibility: .ineligibleReferenceRole,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .vImageLanczos5,
                kind: .wholeFrameBackend,
                capabilityID: "A16",
                framework: "Accelerate",
                role: .highQualityCPUComparator,
                eligibility: .ineligibleReferenceRole,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .vtPixelTransfer,
                kind: .wholeFrameBackend,
                capabilityID: "A06",
                framework: "VideoToolbox",
                role: .scalingConversionReference,
                eligibility: .ineligibleReferenceRole,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .ashCustomMetal,
                kind: .wholeFrameBackend,
                capabilityID: "A17",
                framework: "Metal",
                role: .retainedReferenceComparator,
                eligibility: .ineligibleReferenceRole,
                routes: [.scale3Over2, .scale2x]
            ),
            .init(
                id: .mpsGuidedFilter,
                kind: .supportStage,
                capabilityID: "A13",
                framework: "MetalPerformanceShaders",
                role: .maskAndChromaSupport,
                eligibility: .ineligibleSupportStage,
                routes: [.guidedSupport1x]
            ),
            .init(
                id: .coreImageEdgePreserve,
                kind: .supportStage,
                capabilityID: "A15",
                framework: "CoreImage",
                role: .maskAndChromaSupport,
                eligibility: .ineligibleSupportStage,
                routes: [.edgePreserveSupport2x]
            )
        ]

        XCTAssertEqual(
            R03DeterministicBackendCatalog.subjects.map(ExpectedSubject.init),
            expected
        )
    }

    func testScaleRoutesAdmitOnlyExactPreregisteredExtents() {
        XCTAssertEqual(R03ScaleRoute.scale3Over2.scaleNumerator, 3)
        XCTAssertEqual(R03ScaleRoute.scale3Over2.scaleDenominator, 2)
        XCTAssertEqual(R03ScaleRoute.scale3Over2.canonicalSourceResolution, .p720)
        XCTAssertEqual(R03ScaleRoute.scale3Over2.canonicalTargetResolution, .p1080)
        XCTAssertTrue(
            R03ScaleRoute.scale3Over2.matches(source: .p720, target: .p1080)
        )
        XCTAssertFalse(
            R03ScaleRoute.scale3Over2.matches(
                source: VideoResolution(width: 640, height: 360),
                target: VideoResolution(width: 960, height: 540)
            )
        )

        XCTAssertEqual(R03ScaleRoute.scale2x.scaleNumerator, 2)
        XCTAssertEqual(R03ScaleRoute.scale2x.scaleDenominator, 1)
        XCTAssertEqual(R03ScaleRoute.scale2x.canonicalSourceResolution, .p1080)
        XCTAssertEqual(R03ScaleRoute.scale2x.canonicalTargetResolution, .p2160)
        XCTAssertTrue(R03ScaleRoute.scale2x.matches(source: .p1080, target: .p2160))
        XCTAssertFalse(
            R03ScaleRoute.scale2x.matches(
                source: VideoResolution(width: 16, height: 8),
                target: VideoResolution(width: 32, height: 16)
            )
        )
    }

    func testRegistryBuildersDeduplicateSharedCapabilitiesWithoutQualificationInference() throws {
        let fixtureRegistry = try R03DeterministicBackendCatalog
            .makeFixtureCapabilityRegistry()
        let notObservedRegistry = try R03DeterministicBackendCatalog
            .makeNotObservedCapabilityRegistry()
        let expectedIDs = ["A11", "A12", "A14", "A16", "A06", "A17", "A13", "A15"]

        XCTAssertEqual(fixtureRegistry.capabilities.map(\.id.rawValue), expectedIDs)
        XCTAssertEqual(notObservedRegistry.capabilities.map(\.id.rawValue), expectedIDs)
        XCTAssertEqual(Set(fixtureRegistry.capabilities.map(\.id.rawValue)).count, 8)
        XCTAssertTrue(fixtureRegistry.capabilities.allSatisfy { capability in
            capability.observationStatus == .observed
                && capability.runtimeDisposition == .runnable
                && capability.backendEligibility == .fixtureOnly
                && capability.isEligible(for: .fixtureOnly)
                && !capability.isEligible(for: .product)
        })
        XCTAssertTrue(notObservedRegistry.capabilities.allSatisfy { capability in
            capability.observationStatus == .notObserved
                && capability.runtimeDisposition == .diagnosticOnly
                && capability.backendEligibility == .notEvaluated
                && !capability.isEligible(for: .fixtureOnly)
                && !capability.isEligible(for: .product)
        })
    }
}

private struct ExpectedSubject: Equatable {
    let id: R03BaselineSubjectID
    let kind: R03BaselineSubjectKind
    let capabilityID: String
    let framework: String
    let role: R03BaselineQualificationRole
    let eligibility: R03ProductDefaultEligibility
    let routes: [R03BaselineRouteID]

    init(
        id: R03BaselineSubjectID,
        kind: R03BaselineSubjectKind,
        capabilityID: String,
        framework: String,
        role: R03BaselineQualificationRole,
        eligibility: R03ProductDefaultEligibility,
        routes: [R03BaselineRouteID]
    ) {
        self.id = id
        self.kind = kind
        self.capabilityID = capabilityID
        self.framework = framework
        self.role = role
        self.eligibility = eligibility
        self.routes = routes
    }

    init(_ subject: R03BaselineSubjectDescriptor) {
        self.init(
            id: subject.id,
            kind: subject.kind,
            capabilityID: subject.capabilityID,
            framework: subject.frameworkIdentity,
            role: subject.qualificationRole,
            eligibility: subject.productDefaultEligibility,
            routes: subject.routeIDs
        )
    }
}
