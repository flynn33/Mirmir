import XCTest
@testable import Mirmir

final class R06ASHDecisionContextTests: XCTestCase {
    func testQ16AndQ15DomainsAreCheckedWithoutClamping() throws {
        XCTAssertEqual(try R06ASHQ16(0), .zero)
        XCTAssertEqual(try R06ASHQ16(65_536), .one)
        XCTAssertEqual(try R06ASHQ15(0), .zero)
        XCTAssertEqual(try R06ASHQ15(32_767), .one)

        XCTAssertThrowsError(try R06ASHQ16(-1)) { error in
            XCTAssertEqual(error as? R06ASHDecisionContextError, .q16OutOfRange(-1))
        }
        XCTAssertThrowsError(try R06ASHQ16(65_537)) { error in
            XCTAssertEqual(error as? R06ASHDecisionContextError, .q16OutOfRange(65_537))
        }
        XCTAssertThrowsError(try R06ASHQ15(-1)) { error in
            XCTAssertEqual(error as? R06ASHDecisionContextError, .q15OutOfRange(-1))
        }
        XCTAssertThrowsError(try R06ASHQ15(32_768)) { error in
            XCTAssertEqual(error as? R06ASHDecisionContextError, .q15OutOfRange(32_768))
        }
    }

    func testIdentityAndScaleValidationRejectsEmptyTrimmedAndNonpositiveValues() throws {
        let valid = try makeIdentity()
        XCTAssertEqual(valid.frameID, "frame.0001")
        XCTAssertEqual(valid.shotID, "shot.0001")
        XCTAssertEqual(valid.routeID, "fixture.route.mps_lanczos")
        XCTAssertEqual(valid.scaleNumerator, 3)
        XCTAssertEqual(valid.scaleDenominator, 2)
        XCTAssertEqual(valid.planeLayout, .nv12)
        XCTAssertEqual(valid.chromaSiting, .left)

        XCTAssertThrowsError(try makeIdentity(frameID: "")) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidIdentity(field: "frame_id")
            )
        }
        XCTAssertThrowsError(try makeIdentity(shotID: " shot.0001")) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidIdentity(field: "shot_id")
            )
        }
        XCTAssertThrowsError(try makeIdentity(routeID: "route\n")) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidIdentity(field: "route_id")
            )
        }
        XCTAssertThrowsError(try makeIdentity(scaleNumerator: 0)) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidScale(numerator: 0, denominator: 2)
            )
        }
        XCTAssertThrowsError(try makeIdentity(scaleDenominator: 0)) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidScale(numerator: 3, denominator: 0)
            )
        }
        XCTAssertNil(R06ASHPlaneLayout(rawValue: "rgba"))
    }

    func testStateContextRequiresEightFeaturesNonnegativeDwellAndExactTransition() throws {
        let previous = try ASHState(rawValue: 0)
        let current = try ASHState(rawValue: 480)
        let transition = try R06ASHStateTransition(
            previousState: previous,
            currentState: current
        )
        XCTAssertEqual(transition.message.rawValue, 8)

        XCTAssertThrowsError(
            try R06ASHStateContext(
                continuousFeatureValuesQ16: Array(repeating: .zero, count: 7),
                currentState: current,
                previousState: previous,
                stateTransition: transition,
                dwellFrames: 4
            )
        ) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidContinuousFeatureCount(expected: 8, actual: 7)
            )
        }
        XCTAssertThrowsError(
            try R06ASHStateContext(
                continuousFeatureValuesQ16: Array(repeating: .zero, count: 8),
                currentState: current,
                previousState: previous,
                stateTransition: transition,
                dwellFrames: -1
            )
        ) { error in
            XCTAssertEqual(error as? R06ASHDecisionContextError, .invalidDwellFrames(-1))
        }

        let noChange = try R06ASHStateTransition(
            previousState: previous,
            currentState: previous
        )
        XCTAssertEqual(noChange.message.rawValue, 0)
        XCTAssertThrowsError(
            try R06ASHStateContext(
                continuousFeatureValuesQ16: Array(repeating: .zero, count: 8),
                currentState: current,
                previousState: previous,
                stateTransition: noChange,
                dwellFrames: 4
            )
        ) { error in
            XCTAssertEqual(error as? R06ASHDecisionContextError, .invalidStateTransition)
        }
    }

    func testStateTransitionRejectsIntegrityFailureAndNoncodewordDelta() throws {
        let zero = try ASHState(rawValue: 0)
        let invalidIntegrity = try ASHState(rawValue: 1)
        XCTAssertFalse(invalidIntegrity.hasValidIntegrity)
        XCTAssertThrowsError(
            try R06ASHStateTransition(previousState: zero, currentState: invalidIntegrity)
        ) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidStateIntegrity(field: "current_state")
            )
        }

        let validNoncodeword = try ASHState(rawValue: 3)
        XCTAssertTrue(validNoncodeword.hasValidIntegrity)
        XCTAssertThrowsError(
            try R06ASHStateTransition(previousState: zero, currentState: validNoncodeword)
        ) { error in
            XCTAssertEqual(error as? R06ASHDecisionContextError, .invalidStateTransition)
        }

        XCTAssertEqual(ASHState.bitCount, 9)
        XCTAssertEqual(ASHState.payloadBitCount, 8)
        XCTAssertEqual(ASHCode.encode(try ASHMessage(rawValue: 8)).rawValue, 480)
    }

    func testPostflightFallbackAndBackendIdentitiesAreTypedAndValidated() throws {
        let finding = try R06ASHPostflightFinding(id: "ringing")
        let postflight = try R06ASHPostflightFindings(
            riskQ16: R06ASHQ16(32_768),
            findings: [finding]
        )
        XCTAssertEqual(postflight.riskQ16.rawValue, 32_768)
        XCTAssertEqual(postflight.findings, [finding])

        XCTAssertThrowsError(try R06ASHPostflightFinding(id: " ringing")) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidIdentity(field: "postflight_findings.id")
            )
        }
        XCTAssertThrowsError(
            try R06ASHPostflightFindings(riskQ16: .zero, findings: [finding, finding])
        ) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .duplicatePostflightFinding("ringing")
            )
        }

        let fatal = try R06ASHFallbackReason(
            code: .backendFailed,
            failedBackendID: "fixture.apple.mps_lanczos"
        )
        XCTAssertEqual(fatal.failedBackendID, "fixture.apple.mps_lanczos")
        XCTAssertEqual(fatal.fatalBackendID, "fixture.apple.mps_lanczos")
        let rejected = try R06ASHFallbackReason(
            code: .backendRejected,
            failedBackendID: "fixture.apple.metalfx_spatial"
        )
        XCTAssertNil(rejected.fatalBackendID)
        XCTAssertThrowsError(
            try R06ASHFallbackReason(code: .backendFailed, failedBackendID: "")
        ) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidIdentity(field: "fallback_reason.failed_backend_id")
            )
        }

        XCTAssertThrowsError(
            try R06ASHBackendHistory(currentBackendID: " backend", previousBackendID: nil)
        ) { error in
            XCTAssertEqual(
                error as? R06ASHDecisionContextError,
                .invalidIdentity(field: "current_backend_id")
            )
        }
        XCTAssertNoThrow(
            try R06ASHBackendHistory(currentBackendID: nil, previousBackendID: nil)
        )
    }

    func testDecisionContextPreservesAllThirtyEightFrozenFieldsAndAccessors() throws {
        let context = try makeContext()

        XCTAssertEqual(ASHDecisionContext.version, "r06.v1")
        XCTAssertEqual(context.frameID, "frame.0001")
        XCTAssertEqual(context.shotID, "shot.0001")
        XCTAssertEqual(context.routeID, "fixture.route.mps_lanczos")
        XCTAssertEqual(context.scaleNumerator, 3)
        XCTAssertEqual(context.scaleDenominator, 2)
        XCTAssertEqual(context.planeLayout, .nv12)
        XCTAssertEqual(context.chromaSiting, .left)
        XCTAssertEqual(context.continuousFeatureValuesQ16.map(\.rawValue), Array(1...8).map(Int64.init))
        XCTAssertEqual(context.currentState.rawValue, 480)
        XCTAssertEqual(context.previousState.rawValue, 0)
        XCTAssertEqual(context.stateTransition.message.rawValue, 8)
        XCTAssertEqual(context.dwellFrames, 4)
        XCTAssertEqual(
            [
                context.sceneCutConfidenceQ16,
                context.motionConfidenceQ16,
                context.occlusionConfidenceQ16,
                context.noiseEstimateQ16,
                context.blurEstimateQ16,
                context.compressionEstimateQ16,
                context.aliasingEstimateQ16
            ].map(\.rawValue),
            Array(9...15).map(Int64.init)
        )
        XCTAssertEqual(
            [
                context.faceOccupancyQ15,
                context.textOccupancyQ15,
                context.lineArtOccupancyQ15,
                context.animationOccupancyQ15,
                context.uiOccupancyQ15
            ].map(\.rawValue),
            Array(16...20).map(Int64.init)
        )
        XCTAssertEqual(context.backendAvailability, .available)
        XCTAssertEqual(context.modelReadiness, .ready)
        XCTAssertEqual(
            [
                context.backendQualityConfidenceQ16,
                context.memoryPressureQ16,
                context.thermalPressureQ16,
                context.throughputPressureQ16
            ].map(\.rawValue),
            Array(21...24).map(Int64.init)
        )
        XCTAssertEqual(context.currentBackendID, "fixture.apple.mps_lanczos")
        XCTAssertEqual(context.previousBackendID, "fixture.apple.metalfx_spatial")
        XCTAssertEqual(context.preprocessStrengthQ16.rawValue, 25)
        XCTAssertEqual(context.postprocessStrengthQ16.rawValue, 26)
        XCTAssertEqual(context.artifactRiskQ16.rawValue, 27)
        XCTAssertEqual(context.postflightFindings.riskQ16.rawValue, 32_768)
        XCTAssertEqual(context.postflightFindings.findings.map(\.id), ["ringing", "halo"])
        XCTAssertEqual(context.fallbackReason?.code, .backendFailed)
        XCTAssertEqual(context.fallbackReason?.failedBackendID, "fixture.apple.mps_lanczos")
        XCTAssertEqual(context.retryEligibility, .ineligible)

        XCTAssertEqual(context.message.rawValue, 8)
        XCTAssertEqual(context.fatalBackendID, "fixture.apple.mps_lanczos")
        XCTAssertEqual(context.postflightRiskQ16.rawValue, 32_768)
    }

    func testStatusVocabulariesPreserveTheirTypedValues() {
        XCTAssertEqual(R06ASHBackendAvailability.available.rawValue, "available")
        XCTAssertEqual(R06ASHBackendAvailability.unavailable.rawValue, "unavailable")
        XCTAssertEqual(R06ASHBackendAvailability.unknown.rawValue, "unknown")
        XCTAssertEqual(R06ASHModelReadiness.notRequired.rawValue, "not_required")
        XCTAssertEqual(R06ASHModelReadiness.ready.rawValue, "ready")
        XCTAssertEqual(R06ASHModelReadiness.unavailable.rawValue, "unavailable")
        XCTAssertEqual(R06ASHModelReadiness.acquisitionFailed.rawValue, "acquisition_failed")
        XCTAssertEqual(R06ASHRetryEligibility.eligible.rawValue, "eligible")
        XCTAssertEqual(R06ASHRetryEligibility.ineligible.rawValue, "ineligible")
    }

    private func makeIdentity(
        frameID: String = "frame.0001",
        shotID: String = "shot.0001",
        routeID: String = "fixture.route.mps_lanczos",
        scaleNumerator: Int = 3,
        scaleDenominator: Int = 2
    ) throws -> R06ASHIdentityContext {
        try R06ASHIdentityContext(
            frameID: frameID,
            shotID: shotID,
            routeID: routeID,
            scaleNumerator: scaleNumerator,
            scaleDenominator: scaleDenominator,
            planeLayout: .nv12,
            chromaSiting: .left
        )
    }

    private func makeContext() throws -> ASHDecisionContext {
        let previous = try ASHState(rawValue: 0)
        let current = try ASHState(rawValue: 480)
        return ASHDecisionContext(
            identity: try makeIdentity(),
            state: try R06ASHStateContext(
                continuousFeatureValuesQ16: try Array(1...8).map { try R06ASHQ16(Int64($0)) },
                currentState: current,
                previousState: previous,
                stateTransition: try R06ASHStateTransition(
                    previousState: previous,
                    currentState: current
                ),
                dwellFrames: 4
            ),
            signals: R06ASHSignalContext(
                sceneCutConfidenceQ16: try R06ASHQ16(9),
                motionConfidenceQ16: try R06ASHQ16(10),
                occlusionConfidenceQ16: try R06ASHQ16(11),
                noiseEstimateQ16: try R06ASHQ16(12),
                blurEstimateQ16: try R06ASHQ16(13),
                compressionEstimateQ16: try R06ASHQ16(14),
                aliasingEstimateQ16: try R06ASHQ16(15)
            ),
            protection: R06ASHProtectionContext(
                faceOccupancyQ15: try R06ASHQ15(16),
                textOccupancyQ15: try R06ASHQ15(17),
                lineArtOccupancyQ15: try R06ASHQ15(18),
                animationOccupancyQ15: try R06ASHQ15(19),
                uiOccupancyQ15: try R06ASHQ15(20)
            ),
            resources: R06ASHResourceContext(
                backendAvailability: .available,
                modelReadiness: .ready,
                backendQualityConfidenceQ16: try R06ASHQ16(21),
                memoryPressureQ16: try R06ASHQ16(22),
                thermalPressureQ16: try R06ASHQ16(23),
                throughputPressureQ16: try R06ASHQ16(24)
            ),
            backendHistory: try R06ASHBackendHistory(
                currentBackendID: "fixture.apple.mps_lanczos",
                previousBackendID: "fixture.apple.metalfx_spatial"
            ),
            effects: R06ASHEffectContext(
                preprocessStrengthQ16: try R06ASHQ16(25),
                postprocessStrengthQ16: try R06ASHQ16(26),
                artifactRiskQ16: try R06ASHQ16(27)
            ),
            outcome: R06ASHOutcomeContext(
                postflightFindings: try R06ASHPostflightFindings(
                    riskQ16: R06ASHQ16(32_768),
                    findings: [
                        try R06ASHPostflightFinding(id: "ringing"),
                        try R06ASHPostflightFinding(id: "halo")
                    ]
                ),
                fallbackReason: try R06ASHFallbackReason(
                    code: .backendFailed,
                    failedBackendID: "fixture.apple.mps_lanczos"
                ),
                retryEligibility: .ineligible
            )
        )
    }
}
