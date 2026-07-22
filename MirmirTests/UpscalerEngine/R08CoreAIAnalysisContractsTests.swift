import XCTest
@testable import Mirmir

final class R08CoreAIAnalysisContractsTests: XCTestCase {
    func testFrozenProxyAndSimulationIdentityAreExact() {
        let proxy = R08AnalysisProxyIdentity.frozenAnalysisProxy
        XCTAssertEqual(proxy.fixtureID, "analysis-proxy")
        XCTAssertEqual(proxy.contentSHA256, R08AnalysisProxyIdentity.frozenAnalysisProxySHA256)
        XCTAssertEqual(proxy.width, 512)
        XCTAssertEqual(proxy.height, 288)
        XCTAssertEqual(proxy.pixelFormat, "BGRA")

        let execution = R08AnalysisExecutionIdentity.deterministicFixtureV1
        XCTAssertEqual(execution.runtimeID, "r08.deterministic-analysis-fixture-simulation.v1")
        XCTAssertEqual(execution.referencedCapabilityID, "A18")
        XCTAssertEqual(execution.mode, .deterministicFixtureSimulation)
        XCTAssertEqual(execution.nativeExecution, .notObserved)
    }

    func testScheduleResolverAppliesFrozenPrecedenceAndCadence() {
        XCTAssertEqual(
            R08AnalysisScheduleTrigger.precedence,
            [.ashRequestedFrame, .keyframe, .periodicProxyFrame]
        )
        XCTAssertEqual(R08AnalysisScheduleTrigger.periodicProxyIntervalFrames, 12)

        let everySignal = R08AnalysisScheduleSignals(ashRequested: true, keyframe: true)
        XCTAssertEqual(
            R08AnalysisScheduleResolver.resolve(signals: everySignal, frameOrdinal: 12),
            .ashRequestedFrame
        )
        let keyframe = R08AnalysisScheduleSignals(ashRequested: false, keyframe: true)
        XCTAssertEqual(
            R08AnalysisScheduleResolver.resolve(signals: keyframe, frameOrdinal: 12),
            .keyframe
        )
        let cadenceOnly = R08AnalysisScheduleSignals(ashRequested: false, keyframe: false)
        XCTAssertEqual(
            R08AnalysisScheduleResolver.resolve(signals: cadenceOnly, frameOrdinal: 12),
            .periodicProxyFrame
        )
        XCTAssertNil(
            R08AnalysisScheduleResolver.resolve(signals: cadenceOnly, frameOrdinal: 13)
        )
    }

    func testInputTransferResolverPrefersZeroCopyAndExecutesCopyFallback() throws {
        let simulation = try R08AnalysisInputTransfer(
            executionMode: .deterministicFixtureSimulation,
            zeroCopyAttempt: .notApplicableDeterministicSimulation
        )
        XCTAssertEqual(simulation.disposition, .notUsedDeterministicSimulation)

        let zeroCopy = try R08AnalysisInputTransfer(
            executionMode: .nativeCoreAI,
            zeroCopyAttempt: .succeeded
        )
        XCTAssertEqual(zeroCopy.disposition, .used)

        for attempt in [R08ZeroCopyAttempt.unavailable, .failed] {
            let fallback = try R08AnalysisInputTransfer(
                executionMode: .nativeCoreAI,
                zeroCopyAttempt: attempt
            )
            XCTAssertEqual(fallback.disposition, .copiedDeterministicFallback)
        }
    }

    func testInputTransferResolverRejectsContradictoryBindings() {
        XCTAssertThrowsError(
            try R08AnalysisInputTransfer(
                executionMode: .deterministicFixtureSimulation,
                zeroCopyAttempt: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? R08AnalysisContractError, .invalidInputTransferBinding)
        }
        XCTAssertThrowsError(
            try R08AnalysisInputTransfer(
                executionMode: .nativeCoreAI,
                zeroCopyAttempt: .notApplicableDeterministicSimulation
            )
        ) { error in
            XCTAssertEqual(error as? R08AnalysisContractError, .invalidInputTransferBinding)
        }
    }

    func testIdentityBudgetAndOrdinalValidationRejectInvalidValues() throws {
        XCTAssertThrowsError(try R08TestSupport.model(hashCharacter: "A")) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .invalidSHA256(field: "content_sha256")
            )
        }
        XCTAssertThrowsError(try R08TestSupport.model(version: " 1")) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .invalidIdentity(field: "model_version")
            )
        }
        XCTAssertThrowsError(
            try R08AnalysisBudgets(maximumMemoryBytes: 0, maximumLatencyMicroseconds: 1)
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .invalidBudget(role: "maximum_memory_bytes", value: 0)
            )
        }
        XCTAssertThrowsError(
            try R08AnalysisRequestIdentity(
                requestID: "request",
                streamID: "stream",
                frameID: "frame",
                shotID: "shot",
                frameOrdinal: -1,
                stateGeneration: 0
            )
        ) { error in
            XCTAssertEqual(error as? R08AnalysisContractError, .invalidFrameOrdinal(-1))
        }
    }

    func testQ15MapAcceptsBoundariesAndRejectsInvalidGeometryOrSamples() throws {
        let map = try R08Q15Map(
            width: 2,
            height: 2,
            samples: [0, 1, 32_766, 32_767],
            role: "boundary"
        )
        XCTAssertEqual(map.minimum, 0)
        XCTAssertEqual(map.maximum, 32_767)
        XCTAssertEqual(map.samples.count, 4)

        XCTAssertThrowsError(
            try R08Q15Map(width: 2, height: 2, samples: [0], role: "count")
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .sampleCountMismatch(role: "count", expected: 4, actual: 1)
            )
        }
        XCTAssertThrowsError(
            try R08Q15Map(width: 1, height: 1, samples: [32_768], role: "range")
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .sampleOutOfRange(role: "range", index: 0, value: 32_768)
            )
        }
        XCTAssertThrowsError(
            try R08Q15Map(width: 1, height: 1, samples: [-1], role: "negative")
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .sampleOutOfRange(role: "negative", index: 0, value: -1)
            )
        }
        XCTAssertEqual(try R08Q15Value(0, role: "minimum").rawValue, 0)
        XCTAssertEqual(try R08Q15Value(32_767, role: "maximum").rawValue, 32_767)
        XCTAssertThrowsError(try R08Q15Value(-1, role: "scalar_negative"))
        XCTAssertThrowsError(try R08Q15Value(32_768, role: "scalar_overflow"))
    }

    func testAnalysisHeadsRequireEightTwoByTwoMapsPlusOneScalar() throws {
        let validMap = try R08Q15Map(
            width: 2,
            height: 2,
            samples: [1, 2, 3, 4],
            role: "valid"
        )
        let heads = try makeHeads(map: validMap)
        let spatialMaps = [
            heads.protection.faceSkinQ15,
            heads.protection.textLineArtQ15,
            heads.condition.animationUILikelihoodQ15,
            heads.condition.noiseCompressionSeverityQ15,
            heads.condition.blurMotionBlurEstimateQ15,
            heads.riskConfidence.aliasingRingingRiskQ15,
            heads.riskConfidence.textureDetailConfidenceQ15,
            heads.riskConfidence.motionReliabilityOcclusionRiskQ15
        ]
        XCTAssertEqual(spatialMaps.count, 8)
        XCTAssertTrue(spatialMaps.allSatisfy { $0.width == 2 && $0.height == 2 })
        XCTAssertEqual(spatialMaps.count + 1, 9)
        XCTAssertEqual(heads.noReferenceQualityQ15.rawValue, 5)
        XCTAssertEqual(
            R08AnalysisOutputHeadID.allCases.map(\.rawValue),
            [
                "face_skin_protection_mask",
                "text_line_art_protection_mask",
                "animation_ui_content_likelihood",
                "noise_compression_severity_map",
                "blur_motion_blur_estimate",
                "aliasing_ringing_risk_map",
                "texture_detail_confidence",
                "motion_reliability_occlusion_risk",
                "no_reference_quality_estimate"
            ]
        )
        XCTAssertEqual(R08AnalysisOutputHeadID.allCases.count, 9)
        XCTAssertEqual(heads.sourceClassification.classification, .mixed)

        let wrongGeometry = try R08Q15Map(
            width: 1,
            height: 4,
            samples: [1, 2, 3, 4],
            role: "wrong_geometry"
        )
        XCTAssertThrowsError(try makeHeads(map: wrongGeometry)) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .headGeometryMismatch(
                    role: "face_skin_protection",
                    expectedWidth: 2,
                    expectedHeight: 2
                )
            )
        }
    }

    func testResetCausesAndPixelAuthorityAreFrozen() {
        XCTAssertEqual(
            R08AnalysisStateResetReason.allCases,
            [.sceneCut, .discontinuity, .cancellation, .endOfStream]
        )
        XCTAssertEqual(
            R08AnalysisPixelAuthority.analysisOnlyNoPixelOutput.rawValue,
            "analysis_only_no_pixel_output"
        )
    }

    func testResultRejectsCrossModeExecutionBinding() throws {
        let request = try R08TestSupport.request()
        let nativeExecution = try R08AnalysisExecutionIdentity(
            runtimeID: "r08.native.test",
            referencedCapabilityID: "A18",
            mode: .nativeCoreAI,
            nativeExecution: .observed
        )
        XCTAssertThrowsError(
            try makeResult(request: request, executionIdentity: nativeExecution)
        ) { error in
            XCTAssertEqual(error as? R08AnalysisContractError, .invalidSimulationBinding)
        }

        var nativeOptions = R08TestRequestOptions()
        nativeOptions.model = try R08TestSupport.model(artifactKind: .coreAIModel)
        nativeOptions.executionMode = .nativeCoreAI
        nativeOptions.zeroCopyAttempt = .failed
        let nativeRequest = try R08TestSupport.request(nativeOptions)
        let nativeResult = try makeResult(
            request: nativeRequest,
            executionIdentity: nativeExecution
        )
        XCTAssertEqual(
            nativeResult.resourceUsage.zeroCopyDisposition,
            .copiedDeterministicFallback
        )
    }

    func testResultRejectsStateScheduleTransferAndAOTMismatch() throws {
        let request = try R08TestSupport.request()
        let execution = R08AnalysisExecutionIdentity.deterministicFixtureV1

        XCTAssertThrowsError(
            try makeResult(
                request: request,
                executionIdentity: execution,
                stateReceipt: R08AnalysisStateReceipt(generation: 1, frameOrdinal: 12)
            )
        )
        XCTAssertThrowsError(
            try makeResult(
                request: request,
                executionIdentity: execution,
                stateReceipt: R08AnalysisStateReceipt(generation: 0, frameOrdinal: 24)
            )
        )

        var unscheduledOptions = R08TestRequestOptions()
        unscheduledOptions.frameOrdinal = 13
        XCTAssertThrowsError(
            try makeResult(
                request: R08TestSupport.request(unscheduledOptions),
                executionIdentity: execution
            )
        )

        XCTAssertThrowsError(
            try makeResult(
                request: request,
                executionIdentity: execution,
                resourceUsage: R08AnalysisResourceUsage(
                    memoryBytes: 4_096,
                    latencyMicroseconds: 1_000,
                    zeroCopyDisposition: .copiedDeterministicFallback,
                    aotCompilation: .notRequested
                )
            )
        )
        XCTAssertThrowsError(
            try makeResult(
                request: request,
                executionIdentity: execution,
                resourceUsage: R08AnalysisResourceUsage(
                    memoryBytes: 4_096,
                    latencyMicroseconds: 1_000,
                    zeroCopyDisposition: .notUsedDeterministicSimulation,
                    aotCompilation: .behaviorallyEquivalent
                )
            )
        )
    }
}

final class R08AnalysisBudgetContractTests: XCTestCase {
    func testFunctionalBudgetIsFixedAndCannotBeRaisedByRequest() throws {
        let budget = try R08AnalysisBudgets(
            maximumMemoryBytes: 67_108_864,
            maximumLatencyMicroseconds: 20_000
        )
        XCTAssertEqual(budget.maximumMemoryBytes, R08AnalysisBudgets.functionalMemoryBytes)
        XCTAssertEqual(
            budget.maximumLatencyMicroseconds,
            R08AnalysisBudgets.functionalLatencyMicroseconds
        )

        for memory in [Int64(67_108_863), 67_108_865] {
            XCTAssertThrowsError(
                try R08AnalysisBudgets(
                    maximumMemoryBytes: memory,
                    maximumLatencyMicroseconds: 20_000
                )
            ) { error in
                XCTAssertEqual(
                    error as? R08AnalysisContractError,
                    .invalidBudget(role: "maximum_memory_bytes", value: memory)
                )
            }
        }
        for latency in [Int64(19_999), 20_001] {
            XCTAssertThrowsError(
                try R08AnalysisBudgets(
                    maximumMemoryBytes: 67_108_864,
                    maximumLatencyMicroseconds: latency
                )
            ) { error in
                XCTAssertEqual(
                    error as? R08AnalysisContractError,
                    .invalidBudget(role: "maximum_latency_microseconds", value: latency)
                )
            }
        }
    }

    func testResourceMeasurementRejectsNegativeValues() {
        XCTAssertThrowsError(
            try R08AnalysisResourceMeasurement(
                workingSetBytes: -1,
                elapsedMicroseconds: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .invalidBudget(role: "measured_working_set_bytes", value: -1)
            )
        }
        XCTAssertThrowsError(
            try R08AnalysisResourceMeasurement(
                workingSetBytes: 0,
                elapsedMicroseconds: -1
            )
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .invalidBudget(role: "measured_elapsed_microseconds", value: -1)
            )
        }
    }
}

final class R08AnalysisIdentityContractTests: XCTestCase {
    func testMissingCalibrationIdentityFailsBeforeARequestCanExist() {
        XCTAssertThrowsError(
            try R08AnalysisModelIdentity(
                modelID: "r08.fixture.analysis-model",
                modelVersion: "1",
                artifactKind: .deterministicSimulationContract,
                contentSHA256: String(repeating: "a", count: 64),
                preprocessingID: "r08.fixture.preprocessing.bgra-512x288.v1",
                postprocessingID: "r08.fixture.postprocessing.q15-2x2.v1",
                calibrationID: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .invalidIdentity(field: "calibration_id")
            )
        }
    }
}

private extension R08CoreAIAnalysisContractsTests {
    func makeHeads(map: R08Q15Map) throws -> R08AnalysisHeads {
        try R08AnalysisHeads(
            protection: R08ProtectionHeads(faceSkinQ15: map, textLineArtQ15: map),
            condition: R08ConditionHeads(
                animationUILikelihoodQ15: map,
                noiseCompressionSeverityQ15: map,
                blurMotionBlurEstimateQ15: map
            ),
            riskConfidence: R08RiskConfidenceHeads(
                aliasingRingingRiskQ15: map,
                textureDetailConfidenceQ15: map,
                motionReliabilityOcclusionRiskQ15: map
            ),
            noReferenceQualityQ15: try R08Q15Value(5, role: "no_reference"),
            sourceClassification: R08SourceClassificationResult(
                classification: .mixed,
                confidenceQ15: try R08Q15Value(6, role: "classification")
            )
        )
    }

    func makeResult(
        request: R08AnalysisRequest,
        executionIdentity: R08AnalysisExecutionIdentity,
        stateReceipt: R08AnalysisStateReceipt? = nil,
        resourceUsage: R08AnalysisResourceUsage? = nil
    ) throws -> R08AnalysisResult {
        let map = try R08Q15Map(
            width: 2,
            height: 2,
            samples: [1, 2, 3, 4],
            role: "result"
        )
        return try R08AnalysisResult(
            request: request,
            executionIdentity: executionIdentity,
            heads: makeHeads(map: map),
            resourceUsage: resourceUsage ?? R08AnalysisResourceUsage(
                memoryBytes: 4_096,
                latencyMicroseconds: 1_000,
                zeroCopyDisposition: request.zeroCopyDisposition,
                aotCompilation: request.aotCompilation
            ),
            stateReceipt: stateReceipt ?? R08AnalysisStateReceipt(
                generation: request.stateGeneration,
                frameOrdinal: request.frameOrdinal
            ),
            cacheDisposition: .specialized
        )
    }
}
