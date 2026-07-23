import XCTest
@testable import Mirmir

final class R09CoreAIResidualContractsTests: XCTestCase {
    func testUnsignedQ16PlaneValidatesGeometryCountAndRange() throws {
        let plane = try R09UnsignedPlaneQ16(
            id: .luma,
            width: 2,
            height: 2,
            samplesQ16: [0, 1, 65_535, 65_536]
        )
        XCTAssertEqual(plane.samplesQ16, [0, 1, 65_535, 65_536])

        XCTAssertThrowsError(
            try R09UnsignedPlaneQ16(
                id: .luma,
                width: 0,
                height: 2,
                samplesQ16: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R09ResidualContractError,
                .invalidDimension(plane: .luma, width: 0, height: 2)
            )
        }
        XCTAssertThrowsError(
            try R09UnsignedPlaneQ16(
                id: .luma,
                width: 2,
                height: 2,
                samplesQ16: [0]
            )
        )
        XCTAssertThrowsError(
            try R09UnsignedPlaneQ16(
                id: .luma,
                width: 1,
                height: 1,
                samplesQ16: [65_537]
            )
        )
    }

    func testPlanarContractsRequireExactlyOneOfEveryPlane() throws {
        let luma = try R09UnsignedPlaneQ16(
            id: .luma,
            width: 1,
            height: 1,
            samplesQ16: [0]
        )
        XCTAssertThrowsError(try R09PlanarFrameQ16(planes: [luma, luma, luma])) { error in
            XCTAssertEqual(
                error as? R09ResidualContractError,
                .duplicatePlaneID(role: "frame", plane: .luma)
            )
        }
        XCTAssertThrowsError(try R09PlanarFrameQ16(planes: [luma])) { error in
            XCTAssertEqual(
                error as? R09ResidualContractError,
                .planeCountMismatch(role: "frame", expected: 3, actual: 1)
            )
        }
    }

    func testMasksLimitsAndSignedResidualsEnforceIntegerDomains() throws {
        XCTAssertThrowsError(
            try R09MaskPlaneQ15(
                id: .luma,
                width: 1,
                height: 1,
                samplesQ15: [32_768]
            )
        )
        XCTAssertThrowsError(
            try R09PlaneResidualLimitQ16(
                id: .luma,
                maximumMagnitudeQ16: 4_097
            )
        )
        let signed = try R09SignedResidualPlaneQ16(
            id: .luma,
            width: 2,
            height: 2,
            samplesQ16: [-4_096, -1, 0, 4_096]
        )
        XCTAssertEqual(signed.samplesQ16, [-4_096, -1, 0, 4_096])
        XCTAssertThrowsError(
            try R09SignedResidualPlaneQ16(
                id: .luma,
                width: 1,
                height: 1,
                samplesQ16: [-4_097]
            )
        )
    }

    func testRequestRejectsAnyGeometryMismatch() async throws {
        let input = try await R09ResidualTestSupport.authorizationInput()
        let wrongMask = try R09MaskPlaneQ15(
            id: .luma,
            width: 1,
            height: 4,
            samplesQ15: [0, 0, 0, 0]
        )
        let invalidInput = R09ASHResidualAuthorizationInput(
            identity: input.identity,
            authorization: input.authorization,
            scalerIdentity: input.scalerIdentity,
            modelIdentity: input.modelIdentity,
            postScalerFrame: input.postScalerFrame,
            decisionContext: input.decisionContext,
            analysisSidecar: input.analysisSidecar,
            ashRequestedLumaMask: wrongMask,
            protectedComposition: input.protectedComposition,
            limits: input.limits,
            sourceReference: input.sourceReference,
            temporalReference: input.temporalReference,
            confidenceBudget: input.confidenceBudget,
            resourceBudget: input.resourceBudget,
            safetySignal: input.safetySignal
        )
        guard case .notAuthorized(let bypass) = R09ASHResidualAuthorizer.authorize(
            invalidInput
        ) else {
            return XCTFail("Mismatched geometry must not create an R09 request")
        }
        XCTAssertEqual(
            bypass.reason,
            .authorizationInvalid(
                .geometryMismatch(
                    role: .ashRequestedLuma,
                    expectedWidth: 4,
                    expectedHeight: 4,
                    actualWidth: 1,
                    actualHeight: 4
                )
            )
        )
        XCTAssertEqual(bypass.fallbackRoute, .appleScalerOutputUnmodified)
    }

    func testAuthorizationCannotReplayAcrossBoundaryIdentity() async throws {
        var wrongFrame = R09ResidualTestRequestOptions()
        wrongFrame.authorizationFrameID = "r09.frame.other"
        var wrongShot = R09ResidualTestRequestOptions()
        wrongShot.authorizationShotID = "r09.shot.other"
        var wrongStream = R09ResidualTestRequestOptions()
        wrongStream.authorizationStreamID = "r09.stream.other"
        var wrongGeneration = R09ResidualTestRequestOptions()
        wrongGeneration.authorizationStateGeneration = 4
        var wrongBackend = R09ResidualTestRequestOptions()
        wrongBackend.authorizationBackendID = "r03.mps.other"
        var wrongRoute = R09ResidualTestRequestOptions()
        wrongRoute.authorizationProcessingIdentity = try R09ResidualTestSupport
            .processingIdentity(
                backendID: R09AppleScalerIdentity.deterministicPrimaryBackendID,
                backendRevision: R09AppleScalerIdentity.deterministicPrimaryBackendVersion,
                configurationIdentity: "r09.fixture.replayed-route"
            )

        for options in [
            wrongFrame,
            wrongShot,
            wrongStream,
            wrongGeneration,
            wrongBackend,
            wrongRoute
        ] {
            let outcome = try await R09ResidualTestSupport.authorizationOutcome(options)
            guard case .notAuthorized(let bypass) = outcome else {
                return XCTFail("Boundary-replayed authorization must be rejected")
            }
            XCTAssertEqual(bypass.fallbackRoute, .appleScalerOutputUnmodified)
        }
    }

    func testExecutionIdentityCannotMisstateNativeObservation() throws {
        XCTAssertEqual(
            R09ResidualExecutionIdentity.deterministicSimulationV1.nativeExecution,
            .notObserved
        )
        XCTAssertThrowsError(
            try R09ResidualExecutionIdentity(
                runtimeID: "r09.invalid",
                modelContentSHA256: R09ResidualModelIdentity.deterministicProviderSHA256,
                ioContractSHA256: R09ResidualRequestIdentity.ioContractSHA256,
                mode: .deterministicFixtureSimulation,
                nativeExecution: .observed
            )
        ) { error in
            XCTAssertEqual(
                error as? R09ResidualContractError,
                .invalidExecutionBinding
            )
        }
    }

    func testReferenceOrdinalsAndResourceBudgetsFailClosedAtConstruction() async throws {
        let frame = try R09ResidualTestSupport.frame(
            samplesQ16: R09ResidualTestSupport.currentSamplesQ16
        )
        XCTAssertThrowsError(
            try R09ResidualReferenceFrame(
                kind: .source,
                frameID: "r09.source",
                shotID: "r09.shot",
                streamID: "r09.stream",
                stateGeneration: 0,
                frameOrdinal: -1,
                frame: frame
            )
        )
        XCTAssertThrowsError(
            try R09ResidualResourceBudget(
                maximumWorkingSetBytes: 0,
                maximumElapsedMicroseconds: 1
            )
        )
        XCTAssertThrowsError(
            try R09ResidualConfidenceBudget(
                ashEligibilityQ15: 32_768,
                sourceReferenceQ15: 1,
                temporalReferenceQ15: 1,
                minimumRequiredQ15: 1
            )
        )

        let input = try await R09ResidualTestSupport.authorizationInput()
        let mismatchedSource = try R09ResidualReferenceFrame(
            kind: .source,
            frameID: input.sourceReference.frameID,
            shotID: "r09.other-shot",
            streamID: input.identity.streamID,
            stateGeneration: input.identity.stateGeneration,
            frameOrdinal: input.identity.frameOrdinal,
            frame: input.sourceReference.frame
        )
        let mismatchedInput = R09ASHResidualAuthorizationInput(
            identity: input.identity,
            authorization: input.authorization,
            scalerIdentity: input.scalerIdentity,
            modelIdentity: input.modelIdentity,
            postScalerFrame: input.postScalerFrame,
            decisionContext: input.decisionContext,
            analysisSidecar: input.analysisSidecar,
            ashRequestedLumaMask: input.ashRequestedLumaMask,
            protectedComposition: input.protectedComposition,
            limits: input.limits,
            sourceReference: mismatchedSource,
            temporalReference: input.temporalReference,
            confidenceBudget: input.confidenceBudget,
            resourceBudget: input.resourceBudget,
            safetySignal: input.safetySignal
        )
        guard case .notAuthorized(let bypass) = R09ASHResidualAuthorizer.authorize(
            mismatchedInput
        ) else {
            return XCTFail("Reference boundary replay must not authorize")
        }
        XCTAssertEqual(bypass.reason, .contractInvalid(.invalidReferenceBinding))
        XCTAssertEqual(bypass.fallbackRoute, .appleScalerOutputUnmodified)
    }
}
