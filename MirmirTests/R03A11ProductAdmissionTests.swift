import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class R03A11ProductAdmissionTests: XCTestCase {
    func testProductProfileAndCapabilityRegistryBindOnlyA11() throws {
        let profile = R03DeterministicBackendAdmissionProfile.productQualifiedA11
        XCTAssertEqual(profile.admissionScope, .product)
        XCTAssertEqual(profile.policyIdentity, R03A11ProductAdmission.policyIdentity)
        XCTAssertEqual(
            profile.materialDecisionIdentity,
            R03A11ProductAdmission.materialDecisionIdentity
        )

        let registry = try R03A11ProductAdmission
            .makeProductQualifiedCapabilityRegistry()
        XCTAssertEqual(registry.capabilities.count, 1)
        let capability = try XCTUnwrap(
            registry.capability(for: AppleUpscaleCapabilityID("A11"))
        )
        XCTAssertEqual(capability.role, .primaryScaler)
        XCTAssertEqual(capability.frameworkIdentity, "MetalPerformanceShaders")
        XCTAssertEqual(capability.observationStatus, .observed)
        XCTAssertEqual(capability.runtimeDisposition, .runnable)
        XCTAssertEqual(capability.backendEligibility, .productQualified)
        XCTAssertTrue(capability.isEligible(for: .product))
        XCTAssertFalse(capability.isEligible(for: .fixtureOnly))
    }

    func testProductionFactoryBindsGenuineMPSLanczosProductIdentityForBothRoutes() throws {
        for route in R03ScaleRoute.allCases {
            let backend = try R03DeterministicBackend
                .makeProductQualifiedMPSLanczos(route: route)
            XCTAssertEqual(backend.subject.id, .mpsLanczos)
            XCTAssertEqual(backend.capabilityID.rawValue, "A11")
            XCTAssertEqual(backend.admissionProfile, .productQualifiedA11)
            XCTAssertEqual(
                backend.routeIdentity.policyIdentity,
                R03A11ProductAdmission.policyIdentity
            )
            XCTAssertEqual(
                backend.routeIdentity.materialDecisionIdentity,
                R03A11ProductAdmission.materialDecisionIdentity
            )
            XCTAssertEqual(
                backend.routeIdentity.configurationIdentity,
                try XCTUnwrap(backend.subject.configurationIdentity(for: route))
            )
        }
    }

    func testDefaultConstructionRetainsExactFixtureOnlyAdmission() async throws {
        let probe = R03A11InjectedScalerFactoryProbe()
        let backend = try makeInjectedBackend(
            subjectID: .vImageLanczos3,
            route: .scale3Over2,
            probe: probe
        )
        XCTAssertEqual(backend.admissionProfile, .fixtureOnly)
        XCTAssertEqual(
            backend.routeIdentity.policyIdentity,
            R03DeterministicBackendCatalog.policyIdentity
        )
        XCTAssertEqual(
            backend.routeIdentity.materialDecisionIdentity,
            R03DeterministicBackendCatalog.materialDecisionIdentity
        )

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R03DeterministicBackendTestSupport.makeContext(
                subjectID: .vImageLanczos3
            )
        )
        guard case .created(let session) = outcome else {
            return XCTFail("The unchanged fixture-only contract must create its session")
        }
        XCTAssertEqual(probe.factoryCallCount, 1)
        let identity = await session.identity
        XCTAssertEqual(identity, backend.routeIdentity)
        _ = await session.finish()
    }

    func testProductProfileRejectsEveryReferenceAndSupportSubjectAtConstruction() throws {
        for subject in R03DeterministicBackendCatalog.wholeFrameSubjects
            where subject.id != .mpsLanczos {
            XCTAssertThrowsError(
                try makeInjectedBackend(
                    subjectID: subject.id,
                    route: .scale3Over2,
                    admissionProfile: .productQualifiedA11,
                    probe: R03A11InjectedScalerFactoryProbe()
                )
            ) { error in
                XCTAssertEqual(
                    error as? R03DeterministicBackendConstructionError,
                    .admissionProfileDoesNotPermitSubject(
                        profile: .productQualifiedA11,
                        subject: subject.id
                    )
                )
            }
        }

        for subject in R03DeterministicBackendCatalog.supportStageSubjects {
            XCTAssertThrowsError(
                try makeInjectedBackend(
                    subjectID: subject.id,
                    route: .scale3Over2,
                    admissionProfile: .productQualifiedA11,
                    probe: R03A11InjectedScalerFactoryProbe()
                )
            ) { error in
                XCTAssertEqual(
                    error as? R03DeterministicBackendConstructionError,
                    .subjectIsNotWholeFrame(subject.id)
                )
            }
        }
    }

    func testInjectedA11ProductConstructionRequiresFactoryAuthorization() throws {
        XCTAssertThrowsError(
            try makeInjectedBackend(
                subjectID: .mpsLanczos,
                route: .scale3Over2,
                admissionProfile: .productQualifiedA11,
                probe: R03A11InjectedScalerFactoryProbe()
            )
        ) { error in
            XCTAssertEqual(
                error as? R03DeterministicBackendConstructionError,
                .productAdmissionAuthorizationRequired(.mpsLanczos)
            )
        }
    }

    func testProductAdmissionRequiresExactScopePolicyAndCapability() async throws {
        let backend = try R03DeterministicBackend
            .makeProductQualifiedMPSLanczos(route: .scale3Over2)
        let configuration = try backend.makeConfiguration()
        let productCapability = try R03A11ProductAdmission
            .makeProductQualifiedCapability()

        let wrongScope = try makeContext(
            capability: productCapability,
            scope: .fixtureOnly,
            policy: R03A11ProductAdmission.policyIdentity
        )
        assertCreationRejected(
            await backend.makeSession(configuration: configuration, context: wrongScope),
            route: backend.routeIdentity
        )

        let wrongPolicy = try makeContext(
            capability: productCapability,
            scope: .product,
            policy: R03DeterministicBackendCatalog.policyIdentity
        )
        assertCreationRejected(
            await backend.makeSession(configuration: configuration, context: wrongPolicy),
            route: backend.routeIdentity
        )

        let fixtureCapability = try R03DeterministicBackendCatalog
            .makeFixtureCapability(for: .mpsLanczos)
        let wrongEligibility = try makeContext(
            capability: fixtureCapability,
            scope: .product,
            policy: R03A11ProductAdmission.policyIdentity
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: configuration,
                context: wrongEligibility
            ),
            route: backend.routeIdentity
        )

        let wrongFramework = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "Accelerate",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .productQualified
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: configuration,
                context: try makeContext(
                    capability: wrongFramework,
                    scope: .product,
                    policy: R03A11ProductAdmission.policyIdentity
                )
            ),
            route: backend.routeIdentity
        )
    }

    func testSupportFactoriesRejectProductScopeBeforeNativeConstruction() throws {
        let context = try R03A11ProductAdmission.makeProductSessionContext()
        assertSupportCreationRejected(
            try R03SupportStageFactory.makeMPSGuidedFilter(context: context)
        )
        assertSupportCreationRejected(
            try R03SupportStageFactory.makeCoreImageEdgePreserve(context: context)
        )
    }

    private func makeInjectedBackend(
        subjectID: R03BaselineSubjectID,
        route: R03ScaleRoute,
        admissionProfile: R03DeterministicBackendAdmissionProfile = .fixtureOnly,
        probe: R03A11InjectedScalerFactoryProbe
    ) throws -> R03DeterministicBackend {
        try R03DeterministicBackend(
            subjectID: subjectID,
            route: route,
            admissionProfile: admissionProfile,
            scalerFactory: { _, _ in probe.makeScaler() }
        )
    }

    private func makeContext(
        capability: AppleUpscaleCapability,
        scope: AppleUpscaleAdmissionScope,
        policy: String
    ) throws -> AppleUpscaleSessionContext {
        try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: scope,
            policyIdentity: policy
        )
    }

    private func assertCreationRejected(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected typed session rejection", file: file, line: line)
        }
        XCTAssertEqual(rejection.reason, "r03_session_contract_mismatch", file: file, line: line)
        XCTAssertEqual(rejection.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
    }

    private func assertSupportCreationRejected(
        _ outcome: R03SupportStageCreationOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected product support-stage rejection", file: file, line: line)
        }
        XCTAssertEqual(
            rejection.reason,
            "r03_support_stage_contract_mismatch",
            file: file,
            line: line
        )
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
    }
}

private final class R03A11InjectedScalerFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var factoryCalls = 0

    var factoryCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return factoryCalls
    }

    func makeScaler() -> any R03NV12Scaling {
        lock.lock()
        factoryCalls += 1
        lock.unlock()
        return R03A11InjectedNoopScaler()
    }
}

private final class R03A11InjectedNoopScaler: R03NV12Scaling, @unchecked Sendable {
    func scale(
        source _: CVPixelBuffer,
        destination _: CVPixelBuffer,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) throws {}
}
