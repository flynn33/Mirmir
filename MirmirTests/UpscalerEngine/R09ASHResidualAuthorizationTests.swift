import XCTest
@testable import Mirmir

final class R09ASHResidualAuthorizationTests: XCTestCase {
    func testAnalyzedSidecarAuthorizesExactRequestAndEchoesPlanSuppliedBounds() async throws {
        let heads = try Self.heads(
            aliasing: [30_000, 24_000, 16_000, 8_000],
            texture: [28_000, 20_000, 12_000, 4_000],
            motionRisk: [1_000, 2_000, 3_000, 4_000]
        )
        let fixture = try await makeFixture(
            heads: heads,
            ashSamples: Array(repeating: 25_000, count: 16)
        )

        let request = try authorizedRequest(fixture)

        XCTAssertEqual(
            request.ashApprovedMask.luma.samplesQ15,
            [
                25_000, 25_000, 20_000, 20_000,
                25_000, 25_000, 20_000, 20_000,
                12_000, 12_000, 4_000, 4_000,
                12_000, 12_000, 4_000, 4_000
            ]
        )
        XCTAssertEqual(request.ashApprovedMask.chromaCb.samplesQ15, [25_000, 20_000, 12_000, 4_000])
        XCTAssertEqual(request.ashApprovedMask.chromaCr.samplesQ15, request.ashApprovedMask.chromaCb.samplesQ15)
        XCTAssertTrue(request.protectedMask.orderedPlanes.allSatisfy {
            $0.samplesQ15.allSatisfy { $0 == 0 }
        })
        XCTAssertEqual(request.identity, fixture.identity)
        XCTAssertEqual(request.authorization, fixture.authorization)
        XCTAssertEqual(request.scalerIdentity, fixture.scalerIdentity)
        XCTAssertEqual(request.modelIdentity, fixture.modelIdentity)
        XCTAssertEqual(request.postScalerFrame, fixture.postScalerFrame)
        XCTAssertEqual(request.limits, fixture.limits)
        XCTAssertEqual(request.sourceReference, fixture.sourceReference)
        XCTAssertEqual(request.temporalReference, fixture.temporalReference)
        XCTAssertEqual(request.confidenceBudget, fixture.confidenceBudget)
        XCTAssertEqual(request.resourceBudget, fixture.resourceBudget)
        XCTAssertEqual(request.safetySignal, fixture.safetySignal)
    }
    func testFaceTextAndR07ProtectionSuppressEligibilityAndUseMaximumProtection() async throws {
        var protected = Array(repeating: Int64(0), count: 16)
        protected[8] = 3_000
        let fixture = try await makeFixture(
            heads: try Self.heads(
                face: [1_000, 0, 0, 0],
                text: [0, 2_000, 0, 0],
                aliasing: Self.fullMap,
                texture: Self.fullMap,
                motionRisk: Self.zeroMap
            ),
            ashSamples: Array(repeating: R09MaskPlaneQ15.maximumSample, count: 16),
            protectedSamples: protected
        )

        let request = try authorizedRequest(fixture)
        let eligibility = request.ashApprovedMask.luma.samplesQ15
        let protection = request.protectedMask.luma.samplesQ15

        for index in [0, 1, 4, 5, 2, 3, 6, 7, 8] {
            XCTAssertEqual(eligibility[index], 0, "index \(index)")
        }
        XCTAssertEqual(eligibility[9], R09MaskPlaneQ15.maximumSample)
        XCTAssertEqual(eligibility[15], R09MaskPlaneQ15.maximumSample)
        XCTAssertEqual(protection[0], 1_000)
        XCTAssertEqual(protection[2], 2_000)
        XCTAssertEqual(protection[8], 3_000)
        XCTAssertEqual(request.protectedMask.chromaCb.samplesQ15, [1_000, 2_000, 3_000, 0])
        XCTAssertEqual(request.protectedMask.chromaCr.samplesQ15, request.protectedMask.chromaCb.samplesQ15)
        XCTAssertEqual(request.ashApprovedMask.chromaCb.samplesQ15, [0, 0, 0, 32_767])
    }
    func testChromaEligibilityUsesMinimumOfEachTwoByTwoLumaBlock() async throws {
        let ashSamples: [Int64] = [
            30_000, 20_000, 28_000, 27_000,
            25_000, 15_000, 26_000, 25_000,
            24_000, 23_000, 22_000, 21_000,
            20_000, 19_000, 18_000, 17_000
        ]
        let fixture = try await makeFixture(
            heads: try Self.heads(
                aliasing: Self.fullMap,
                texture: Self.fullMap,
                motionRisk: Self.zeroMap
            ),
            ashSamples: ashSamples
        )

        let request = try authorizedRequest(fixture)

        XCTAssertEqual(request.ashApprovedMask.luma.samplesQ15, ashSamples)
        XCTAssertEqual(request.ashApprovedMask.chromaCb.samplesQ15, [15_000, 25_000, 19_000, 17_000])
        XCTAssertEqual(request.ashApprovedMask.chromaCr.samplesQ15, request.ashApprovedMask.chromaCb.samplesQ15)
    }
    func testR08BypassProducesTypedNoAuthorizationAndAppleOnlyFallback() async throws {
        let fixture = try await makeFixture(availabilityBypass: .frameworkUnavailable)

        let outcome = R09ASHResidualAuthorizer.authorize(fixture.input)

        guard case .notAuthorized(let bypass) = outcome else {
            return XCTFail("Expected R08 bypass to prevent R09 authorization")
        }
        XCTAssertEqual(bypass.requestIdentity, fixture.identity)
        XCTAssertEqual(bypass.authorization, fixture.authorization)
        XCTAssertEqual(bypass.scalerIdentity, fixture.scalerIdentity)
        XCTAssertEqual(bypass.reason, .r08AnalysisBypassed(.frameworkUnavailable))
        XCTAssertEqual(bypass.fallbackRoute, .appleScalerOutputUnmodified)
    }
    func testFrameShotStreamGenerationAndPrimaryRouteMismatchesReject() async throws {
        var frameOptions = R08TestRequestOptions()
        frameOptions.frameID = "other.frame"
        let frameFixture = try await makeFixture(r08Options: frameOptions)
        assertAuthorizationError(
            .analysisFrameMismatch(expected: "r07.frame.101", actual: "other.frame"),
            fixture: frameFixture
        )

        var shotOptions = R08TestRequestOptions()
        shotOptions.shotID = "other.shot"
        let shotFixture = try await makeFixture(r08Options: shotOptions)
        assertAuthorizationError(
            .analysisShotMismatch(expected: "r07.shot", actual: "other.shot"),
            fixture: shotFixture
        )

        var streamOptions = R08TestRequestOptions()
        streamOptions.streamID = "other.stream"
        let streamFixture = try await makeFixture(r08Options: streamOptions)
        assertAuthorizationError(
            .analysisStreamMismatch(expected: "r08.stream", actual: "other.stream"),
            fixture: streamFixture
        )

        var stateOptions = R08TestRequestOptions()
        stateOptions.stateGeneration = 1
        let stateFixture = try await makeFixture(r08Options: stateOptions)
        assertAuthorizationError(
            .analysisStateGenerationMismatch(expected: 0, actual: 1),
            fixture: stateFixture
        )

        let routeFixture = try await makeFixture(
            contextOptions: R07FunctionalContextOptions(
                currentBackendID: "other.backend",
                previousBackendID: "backend.previous"
            )
        )
        assertAuthorizationError(
            .decisionPrimaryBackendMismatch(
                expected: R09AppleScalerIdentity.deterministicPrimaryBackendID,
                actual: "other.backend"
            ),
            fixture: routeFixture
        )
    }
    func testAuthorizationReplayAndFrozenContractDriftReject() async throws {
        var replay = try await makeFixture()
        replay.authorization = try Self.authorization(stateGeneration: 1)
        assertAuthorizationError(
            .authorizationStateGenerationMismatch(expected: 0, actual: 1),
            fixture: replay
        )

        var routeReplay = try await makeFixture()
        routeReplay.authorization = try Self.authorization(
            primaryProcessingIdentity: R09ResidualTestSupport.processingIdentity(
                backendID: R09AppleScalerIdentity.deterministicPrimaryBackendID,
                backendRevision: R09AppleScalerIdentity.deterministicPrimaryBackendVersion,
                configurationIdentity: "r09.fixture.replayed-configuration"
            )
        )
        assertAuthorizationError(
            .authorizationPrimaryRouteMismatch,
            fixture: routeReplay
        )

        var sourceReplay = try await makeFixture()
        sourceReplay.sourceReference = try R09ResidualReferenceFrame(
            kind: .source,
            frameID: "source.replayed",
            shotID: sourceReplay.identity.shotID,
            streamID: sourceReplay.identity.streamID,
            stateGeneration: sourceReplay.identity.stateGeneration,
            frameOrdinal: sourceReplay.identity.frameOrdinal,
            frame: sourceReplay.sourceReference.frame
        )
        assertAuthorizationError(
            .authorizationSourceReferenceMismatch,
            fixture: sourceReplay
        )

        var r08Drift = try await makeFixture()
        r08Drift.authorization = try Self.authorization(
            referencedR08AcceptanceSHA256: String(repeating: "a", count: 64)
        )
        assertAuthorizationError(
            .acceptedR08BindingMismatch(
                expected: Self.acceptedR08SHA256,
                actual: String(repeating: "a", count: 64)
            ),
            fixture: r08Drift
        )

        var contractDrift = try await makeFixture()
        contractDrift.identity = try Self.identity(
            ioContractSHA256: String(repeating: "b", count: 64)
        )
        assertAuthorizationError(
            .requestContractMismatch(
                expected: R09ResidualRequestIdentity.ioContractSHA256,
                actual: String(repeating: "b", count: 64)
            ),
            fixture: contractDrift
        )

        var preprocessingDrift = try await makeFixture()
        preprocessingDrift.modelIdentity = try R09ResidualModelIdentity(
            modelID: R09BoundedResidualStage.deterministicModelID,
            modelVersion: R09BoundedResidualStage.deterministicModelVersion,
            artifactKind: .deterministicSimulationContract,
            contentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
            preprocessingIdentity: "r09.preprocessing.drift",
            postprocessingIdentity:
                R09ResidualModelIdentity.deterministicPostprocessingIdentity,
            residualContractIdentity:
                R09ResidualModelIdentity.deterministicResidualContractIdentity
        )
        assertAuthorizationError(
            .deterministicModelBindingMismatch,
            fixture: preprocessingDrift
        )
    }
}
