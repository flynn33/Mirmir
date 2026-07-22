import CoreVideo
import XCTest
@testable import Mirmir

final class R07SupportStagePolicyTests: XCTestCase {
    private let policy = R07SupportStagePolicy()

    func testA04NotObservedIsDiagnosticAndNeverPlanned() throws {
        let result = try a04Result(
            policy.resolve(
                scope: .fixtureOnly,
                request: .a04(
                    qualificationStatus: .notObserved,
                    temporalState: R07TemporalSupportState(discontinuity: true)
                )
            )
        )

        XCTAssertEqual(result.outcome, .diagnosticNotPlanned)
        XCTAssertFalse(result.planConstructed)
        XCTAssertNil(result.strengthQ16)
        XCTAssertNil(result.descriptor)
        XCTAssertEqual(result.runtimeQualification, .notEstablished)
        XCTAssertEqual(result.productQualification, .notEstablished)
    }

    func testA04UnsupportedIsUnavailableAndNeverPlanned() throws {
        let result = try a04Result(
            policy.resolve(
                scope: .fixtureOnly,
                request: .a04(
                    qualificationStatus: .unsupported,
                    temporalState: R07TemporalSupportState(discontinuity: false)
                )
            )
        )

        XCTAssertEqual(result.outcome, .unavailableNotPlanned)
        XCTAssertFalse(result.planConstructed)
        XCTAssertNil(result.strengthQ16)
        XCTAssertNil(result.descriptor)
        XCTAssertEqual(result.runtimeQualification, .notEstablished)
        XCTAssertEqual(result.productQualification, .notEstablished)
    }

    func testA04FixtureAdmissionFreezesConfigurationAndDerivesDiscontinuity() throws {
        let discontinuous = try a04Result(
            policy.resolve(
                scope: .fixtureOnly,
                request: .a04(
                    qualificationStatus: .fixtureAdmitted,
                    temporalState: R07TemporalSupportState(discontinuity: true)
                )
            )
        )
        let continuous = try a04Result(
            policy.resolve(
                scope: .fixtureOnly,
                request: .a04(
                    qualificationStatus: .fixtureAdmitted,
                    temporalState: R07TemporalSupportState(discontinuity: false)
                )
            )
        )
        let first = try XCTUnwrap(discontinuous.descriptor)
        let second = try XCTUnwrap(continuous.descriptor)

        XCTAssertEqual(discontinuous.outcome, .deterministicFixtureOnlyDescriptor)
        XCTAssertTrue(discontinuous.planConstructed)
        XCTAssertEqual(first.capabilityID, .temporalNoiseFilter)
        XCTAssertEqual(first.role.rawValue, "r07_temporal_noise_filter")
        XCTAssertEqual(
            first.configurationIdentity,
            "r07.videotoolbox.temporal-noise-filter.fixture-only.strength-q16-24576.v1"
        )
        XCTAssertEqual(first.strengthQ16.rawValue, 24_576)
        XCTAssertEqual(first.discontinuitySource, .derivedFromTemporalState)
        XCTAssertTrue(first.discontinuity)
        XCTAssertFalse(second.discontinuity)
        XCTAssertFalse(first.discontinuityHardcoded)
        XCTAssertFalse(second.discontinuityHardcoded)
        XCTAssertEqual(discontinuous.runtimeQualification, .notEstablished)
        XCTAssertEqual(discontinuous.productQualification, .notEstablished)
    }

    func testA05IsAnalysisOnlyAndSupportStageConstructionIsForbidden() throws {
        let analysis = policy.resolve(scope: .fixtureOnly, request: .a05Analysis)
        guard case .analysisPlan(let plan) = analysis else {
            return XCTFail("Expected the frozen A05 analysis plan")
        }
        XCTAssertEqual(plan.capabilityID, .temporalAnalyzer)
        XCTAssertEqual(plan.role, .analysisOnly)
        XCTAssertFalse(plan.constructSupportStage)

        let construction = policy.resolve(
            scope: .fixtureOnly,
            request: .a05SupportStageConstruction
        )
        guard case .constructionRejected(let rejection) = construction else {
            return XCTFail("Expected A05 support-stage construction rejection")
        }
        XCTAssertEqual(rejection.capabilityID, .temporalAnalyzer)
        XCTAssertEqual(rejection.disposition, .forbidden)
        XCTAssertFalse(rejection.constructionAttempted)
    }

    func testA13DescriptorInheritsExactR03AdmissionSurfaceAndIdentity() throws {
        let descriptor = try inheritedDescriptor(
            policy.resolve(scope: .fixtureOnly, request: .a13Descriptor)
        )

        XCTAssertEqual(descriptor.capabilityID, .mpsGuidedFilter)
        XCTAssertEqual(descriptor.role, .supportStage)
        XCTAssertEqual(descriptor.contract, .mpsGuidedFilter)
        guard case .a13(let source, let guidance, let output) = descriptor.surfaces else {
            return XCTFail("Expected A13 surfaces")
        }
        XCTAssertEqual(source, surface(width: 64, height: 64))
        XCTAssertEqual(guidance, surface(width: 64, height: 64))
        XCTAssertEqual(output, surface(width: 64, height: 64))
        guard case .a13(let kernelSize, let epsilon) = descriptor.parameters else {
            return XCTFail("Expected A13 parameters")
        }
        XCTAssertEqual(kernelSize, 5)
        XCTAssertEqual(epsilon, 0.01)
        try assertProcessingIdentity(
            descriptor,
            backendID: "r03.mps.guided-filter",
            routeID: .guidedSupport1x,
            configurationIdentity:
                "r03.mps.guided-filter.guided_support_1x.r8-to-rgba8-rgba16f.k5-e0p01.v1"
        )
        assertDescriptorOnlyNoClaimBoundary(descriptor)
    }

    func testA15DescriptorInheritsExactR03AdmissionSurfaceAndIdentity() throws {
        let descriptor = try inheritedDescriptor(
            policy.resolve(scope: .fixtureOnly, request: .a15Descriptor)
        )

        XCTAssertEqual(descriptor.capabilityID, .coreImageEdgePreserve)
        XCTAssertEqual(descriptor.role, .supportStage)
        XCTAssertEqual(descriptor.contract, .coreImageEdgePreserve)
        guard case .a15(let mask, let guidance, let output) = descriptor.surfaces else {
            return XCTFail("Expected A15 surfaces")
        }
        XCTAssertEqual(mask, surface(width: 32, height: 32))
        XCTAssertEqual(guidance, surface(width: 64, height: 64))
        XCTAssertEqual(output, surface(width: 64, height: 64))
        guard case .a15(let spatialSigma, let lumaSigma) = descriptor.parameters else {
            return XCTFail("Expected A15 parameters")
        }
        XCTAssertEqual(spatialSigma, 3)
        XCTAssertEqual(lumaSigma, 0.15)
        try assertProcessingIdentity(
            descriptor,
            backendID: "r03.core-image.edge-preserve",
            routeID: .edgePreserveSupport2x,
            configurationIdentity:
                "r03.core-image.edge-preserve.edge_preserve_support_2x.r8.s3-l0p15.v1"
        )
        assertDescriptorOnlyNoClaimBoundary(descriptor)
    }

    func testProductGateRunsBeforeEveryRequestAndConstructsNothing() {
        let requests: [R07SupportStageRequest] = [
            .a04(
                qualificationStatus: .fixtureAdmitted,
                temporalState: R07TemporalSupportState(discontinuity: true)
            ),
            .a05Analysis,
            .a05SupportStageConstruction,
            .a13Descriptor,
            .a15Descriptor
        ]

        for request in requests {
            let outcome = policy.resolve(scope: .product, request: request)
            XCTAssertEqual(outcome, .blocked(.blocked))
            guard case .blocked(let gate) = outcome else {
                return XCTFail("Expected the product gate")
            }
            XCTAssertEqual(
                gate.reason.rawValue,
                "upstream_no_product_qualified_primary_backend"
            )
            XCTAssertEqual(gate.eligibleBackendCount, 0)
            XCTAssertNil(gate.selectedRouteID)
            XCTAssertNil(gate.selectedPlanID)
            XCTAssertNil(gate.outputIdentity)
            XCTAssertEqual(gate.disposition, .blocked)
            XCTAssertFalse(gate.supportStageConstructionAttempted)
        }
    }

    private func a04Result(
        _ outcome: R07SupportStagePolicyOutcome
    ) throws -> R07A04AdmissionResult {
        guard case .a04Admission(let result) = outcome else {
            throw TestError.unexpectedOutcome
        }
        return result
    }

    private func inheritedDescriptor(
        _ outcome: R07SupportStagePolicyOutcome
    ) throws -> R07InheritedSupportStageDescriptor {
        guard case .inheritedDescriptor(let descriptor) = outcome else {
            throw TestError.unexpectedOutcome
        }
        return descriptor
    }

    private func surface(width: Int, height: Int) -> R07SupportSurfaceDescriptor {
        R07SupportSurfaceDescriptor(width: width, height: height, pixelFormat: .r8)
    }

    private func assertProcessingIdentity(
        _ descriptor: R07InheritedSupportStageDescriptor,
        backendID: String,
        routeID: R03BaselineRouteID,
        configurationIdentity: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(descriptor.contract.routeID, routeID, file: file, line: line)
        XCTAssertEqual(
            descriptor.processingIdentity.route.backend.backendID,
            backendID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.processingIdentity.route.backend.backendRevision,
            "1",
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.processingIdentity.route.backend.modelAssetsIdentity,
            .notRequired,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.processingIdentity.route.configurationIdentity,
            configurationIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.processingIdentity.route.policyIdentity,
            "r03.fixture-only.v1",
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.processingIdentity.route.materialDecisionIdentity,
            "r03.preregistered-baseline.v1",
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.processingIdentity.fallbackHistory,
            [],
            file: file,
            line: line
        )
    }

    private func assertDescriptorOnlyNoClaimBoundary(
        _ descriptor: R07InheritedSupportStageDescriptor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(descriptor.productPrimaryBackend, file: file, line: line)
        XCTAssertEqual(
            descriptor.conformanceScope,
            .descriptorAndAdmissionOnly,
            file: file,
            line: line
        )
        XCTAssertEqual(
            descriptor.reconstructionExecution,
            .notObserved,
            file: file,
            line: line
        )
        XCTAssertEqual(descriptor.outputClaims, .forbidden, file: file, line: line)
    }

    private enum TestError: Error {
        case unexpectedOutcome
    }
}
