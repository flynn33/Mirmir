import XCTest
@testable import Mirmir

final class R08ASHAnalysisBridgeTests: XCTestCase {
    func testBypassPreservesBaseContextAndDeterministicRegionsExactly() async throws {
        let base = try R07FunctionalTestFixtures.makeContext()
        let deterministicRegions = [
            R07FunctionalTestFixtures.protectedRegion(kind: .face, fillQ15: 1_234)
        ]
        let service = try R08DeterministicAnalysisService(
            availabilityBypassReason: .frameworkUnavailable
        )
        let outcome = try await service.analyze(try R08TestSupport.request())

        let integration = try R08ASHAnalysisBridge.integrate(
            outcome: outcome,
            into: base,
            deterministicRegions: deterministicRegions
        )

        XCTAssertEqual(integration.decisionContext, base)
        XCTAssertEqual(integration.lowResolutionProtectedRegions, deterministicRegions)
        XCTAssertEqual(integration.sidecar.outcome, outcome)
        XCTAssertEqual(integration.sidecar.bypass?.reason, .frameworkUnavailable)
        XCTAssertNil(integration.sidecar.analyzedResult)
    }

    func testAnalyzedSidecarStrengthensOnlyAnalysisFields() async throws {
        let base = try R07FunctionalTestFixtures.makeContext()
        let deterministic = R07FunctionalTestFixtures.protectedRegion(
            kind: .text,
            fillQ15: 2_000
        )
        let result = try await analyzedResult()

        let integration = try R08ASHAnalysisBridge.integrate(
            outcome: .analyzed(result),
            into: base,
            deterministicRegions: [deterministic]
        )
        let context = integration.decisionContext

        XCTAssertEqual(integration.lowResolutionProtectedRegions.first, deterministic)
        XCTAssertEqual(integration.lowResolutionProtectedRegions.count, 6)
        XCTAssertEqual(
            Array(integration.lowResolutionProtectedRegions.dropFirst().map(\.kind)),
            [.face, .text, .lineArt, .animation, .uiCapture]
        )
        XCTAssertTrue(
            integration.lowResolutionProtectedRegions.dropFirst().allSatisfy {
                $0.samplesQ15.count == R07FunctionalSupportGeometry.lowSampleCount
            }
        )
        XCTAssertEqual(integration.sidecar.analyzedResult, result)
        XCTAssertNil(integration.sidecar.bypass)
        XCTAssertEqual(result.pixelAuthority, .analysisOnlyNoPixelOutput)

        assertNonAnalysisFieldsPreserved(base: base, integrated: context)
        XCTAssertEqual(context.modelReadiness, base.modelReadiness)
        XCTAssertEqual(
            context.faceOccupancyQ15.rawValue,
            result.heads.protection.faceSkinQ15.mean
        )
        XCTAssertEqual(
            context.textOccupancyQ15.rawValue,
            result.heads.protection.textLineArtQ15.mean
        )
        XCTAssertEqual(
            context.animationOccupancyQ15.rawValue,
            result.heads.condition.animationUILikelihoodQ15.mean
        )
        XCTAssertGreaterThan(context.noiseEstimateQ16.rawValue, base.noiseEstimateQ16.rawValue)
        XCTAssertGreaterThan(context.blurEstimateQ16.rawValue, base.blurEstimateQ16.rawValue)
        XCTAssertGreaterThan(context.aliasingEstimateQ16.rawValue, base.aliasingEstimateQ16.rawValue)
        XCTAssertGreaterThan(context.artifactRiskQ16.rawValue, base.artifactRiskQ16.rawValue)

        XCTAssertEqual(
            integration.sidecar.analyzedResult?.heads.riskConfidence.textureDetailConfidenceQ15,
            result.heads.riskConfidence.textureDetailConfidenceQ15
        )
        XCTAssertEqual(
            integration.sidecar.analyzedResult?.heads.noReferenceQualityQ15,
            result.heads.noReferenceQualityQ15
        )
        XCTAssertEqual(
            integration.sidecar.analyzedResult?.heads.sourceClassification,
            result.heads.sourceClassification
        )
    }

    func testTwoByTwoProtectionMapExpandsByDeterministicNearestNeighbor() async throws {
        let result = try await analyzedResult()
        let integration = try R08ASHAnalysisBridge.integrate(
            outcome: .analyzed(result),
            into: try R07FunctionalTestFixtures.makeContext(),
            deterministicRegions: []
        )
        let expanded = try XCTUnwrap(
            integration.lowResolutionProtectedRegions.first { $0.kind == .face }
        ).samplesQ15
        let source = result.heads.protection.faceSkinQ15.samples
        let width = R07FunctionalSupportGeometry.lowWidth
        let halfWidth = width / 2
        let halfHeight = R07FunctionalSupportGeometry.lowHeight / 2

        XCTAssertEqual(expanded[0], source[0])
        XCTAssertEqual(expanded[halfWidth - 1], source[0])
        XCTAssertEqual(expanded[halfWidth], source[1])
        XCTAssertEqual(expanded[halfHeight * width], source[2])
        XCTAssertEqual(expanded[halfHeight * width + halfWidth], source[3])
        XCTAssertEqual(expanded.last, source[3])
    }

    func testExactLearnedMaskWinsR07PixelwiseMaximumComposition() async throws {
        let service = try R08DeterministicAnalysisService(
            analysisHeadProvider: { _ in
                try R08ASHAnalysisBridgeTests.exactHeads(faceQ15: 28_672)
            }
        )
        let result = try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request())
        )
        let deterministic = R07FunctionalTestFixtures.protectedRegion(
            kind: .face,
            fillQ15: 24_576
        )
        let integration = try R08ASHAnalysisBridge.integrate(
            outcome: .analyzed(result),
            into: try R07FunctionalTestFixtures.makeContext(),
            deterministicRegions: [deterministic]
        )
        let masks = try integration.lowResolutionProtectedRegions.map { region in
            try R07ProtectedMask(
                kind: region.kind,
                width: R07FunctionalSupportGeometry.lowWidth,
                height: R07FunctionalSupportGeometry.lowHeight,
                samplesQ15: region.samplesQ15
            )
        }
        let composition = try R07ProtectedRegionPolicy.compose(
            width: R07FunctionalSupportGeometry.lowWidth,
            height: R07FunctionalSupportGeometry.lowHeight,
            regions: masks
        )

        XCTAssertTrue(deterministic.samplesQ15.allSatisfy { $0 == 24_576 })
        XCTAssertTrue(
            integration.lowResolutionProtectedRegions[1].samplesQ15.allSatisfy {
                $0 == 28_672
            }
        )
        XCTAssertTrue(composition.composedQ15.allSatisfy { $0.rawValue == 28_672 })
        XCTAssertTrue(composition.ownerByPixel.allSatisfy { $0 == .face })
        for mask in composition.masks.orderedMasks {
            XCTAssertTrue(mask.samplesQ15.allSatisfy { $0 == 28_672 })
        }
    }

    func testRepeatedIntegrationNeverReducesConservativeContributions() async throws {
        let result = try await analyzedResult()
        let first = try R08ASHAnalysisBridge.integrate(
            outcome: .analyzed(result),
            into: try R07FunctionalTestFixtures.makeContext(),
            deterministicRegions: []
        )
        let second = try R08ASHAnalysisBridge.integrate(
            outcome: .analyzed(result),
            into: first.decisionContext,
            deterministicRegions: first.lowResolutionProtectedRegions
        )

        XCTAssertGreaterThanOrEqual(
            second.decisionContext.occlusionConfidenceQ16.rawValue,
            first.decisionContext.occlusionConfidenceQ16.rawValue
        )
        XCTAssertLessThanOrEqual(
            second.decisionContext.motionConfidenceQ16.rawValue,
            first.decisionContext.motionConfidenceQ16.rawValue
        )
        XCTAssertGreaterThanOrEqual(
            second.decisionContext.faceOccupancyQ15.rawValue,
            first.decisionContext.faceOccupancyQ15.rawValue
        )
        XCTAssertGreaterThanOrEqual(
            second.decisionContext.artifactRiskQ16.rawValue,
            first.decisionContext.artifactRiskQ16.rawValue
        )
        XCTAssertEqual(second.decisionContext.modelReadiness, first.decisionContext.modelReadiness)
    }

    func testFrameAndShotMismatchAreRejectedBeforeContextMutation() async throws {
        let base = try R07FunctionalTestFixtures.makeContext()

        var frameOptions = R08TestRequestOptions()
        frameOptions.frameID = "other.frame"
        let frameResult = try await analyzedResult(frameOptions)
        XCTAssertThrowsError(
            try R08ASHAnalysisBridge.integrate(
                outcome: .analyzed(frameResult),
                into: base,
                deterministicRegions: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R08ASHAnalysisBridgeError,
                .frameIdentityMismatch(expected: "r07.frame.101", actual: "other.frame")
            )
        }

        var shotOptions = R08TestRequestOptions()
        shotOptions.shotID = "other.shot"
        let shotResult = try await analyzedResult(shotOptions)
        XCTAssertThrowsError(
            try R08ASHAnalysisBridge.integrate(
                outcome: .analyzed(shotResult),
                into: base,
                deterministicRegions: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R08ASHAnalysisBridgeError,
                .shotIdentityMismatch(expected: "r07.shot", actual: "other.shot")
            )
        }
        XCTAssertEqual(base, try R07FunctionalTestFixtures.makeContext())
    }
}

private extension R08ASHAnalysisBridgeTests {
    static func exactHeads(faceQ15: Int64) throws -> R08AnalysisHeads {
        let face = try R08Q15Map(
            width: 2,
            height: 2,
            samples: Array(repeating: faceQ15, count: 4),
            role: "face_skin_protection"
        )
        let zero = try R08Q15Map(
            width: 2,
            height: 2,
            samples: Array(repeating: 0, count: 4),
            role: "zero"
        )
        return try R08AnalysisHeads(
            protection: R08ProtectionHeads(faceSkinQ15: face, textLineArtQ15: zero),
            condition: R08ConditionHeads(
                animationUILikelihoodQ15: zero,
                noiseCompressionSeverityQ15: zero,
                blurMotionBlurEstimateQ15: zero
            ),
            riskConfidence: R08RiskConfidenceHeads(
                aliasingRingingRiskQ15: zero,
                textureDetailConfidenceQ15: zero,
                motionReliabilityOcclusionRiskQ15: zero
            ),
            noReferenceQualityQ15: try R08Q15Value(0, role: "no_reference"),
            sourceClassification: R08SourceClassificationResult(
                classification: .mixed,
                confidenceQ15: try R08Q15Value(0, role: "classification")
            )
        )
    }

    func analyzedResult(
        _ options: R08TestRequestOptions = R08TestRequestOptions()
    ) async throws -> R08AnalysisResult {
        let service = try R08DeterministicAnalysisService()
        return try R08TestSupport.analyzed(
            try await service.analyze(try R08TestSupport.request(options))
        )
    }

    func assertNonAnalysisFieldsPreserved(
        base: ASHDecisionContext,
        integrated: ASHDecisionContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(integrated.frameID, base.frameID, file: file, line: line)
        XCTAssertEqual(integrated.shotID, base.shotID, file: file, line: line)
        XCTAssertEqual(integrated.routeID, base.routeID, file: file, line: line)
        XCTAssertEqual(integrated.scaleNumerator, base.scaleNumerator, file: file, line: line)
        XCTAssertEqual(integrated.scaleDenominator, base.scaleDenominator, file: file, line: line)
        XCTAssertEqual(integrated.planeLayout, base.planeLayout, file: file, line: line)
        XCTAssertEqual(integrated.chromaSiting, base.chromaSiting, file: file, line: line)
        XCTAssertEqual(
            integrated.continuousFeatureValuesQ16,
            base.continuousFeatureValuesQ16,
            file: file,
            line: line
        )
        XCTAssertEqual(integrated.currentState, base.currentState, file: file, line: line)
        XCTAssertEqual(integrated.previousState, base.previousState, file: file, line: line)
        XCTAssertEqual(integrated.stateTransition, base.stateTransition, file: file, line: line)
        XCTAssertEqual(integrated.dwellFrames, base.dwellFrames, file: file, line: line)
        XCTAssertEqual(
            integrated.sceneCutConfidenceQ16,
            base.sceneCutConfidenceQ16,
            file: file,
            line: line
        )
        XCTAssertEqual(
            integrated.backendAvailability,
            base.backendAvailability,
            file: file,
            line: line
        )
        XCTAssertEqual(integrated.modelReadiness, base.modelReadiness, file: file, line: line)
        XCTAssertEqual(
            integrated.backendQualityConfidenceQ16,
            base.backendQualityConfidenceQ16,
            file: file,
            line: line
        )
        XCTAssertEqual(integrated.memoryPressureQ16, base.memoryPressureQ16, file: file, line: line)
        XCTAssertEqual(integrated.thermalPressureQ16, base.thermalPressureQ16, file: file, line: line)
        XCTAssertEqual(
            integrated.throughputPressureQ16,
            base.throughputPressureQ16,
            file: file,
            line: line
        )
        XCTAssertEqual(integrated.currentBackendID, base.currentBackendID, file: file, line: line)
        XCTAssertEqual(integrated.previousBackendID, base.previousBackendID, file: file, line: line)
        XCTAssertEqual(
            integrated.preprocessStrengthQ16,
            base.preprocessStrengthQ16,
            file: file,
            line: line
        )
        XCTAssertEqual(
            integrated.postprocessStrengthQ16,
            base.postprocessStrengthQ16,
            file: file,
            line: line
        )
        XCTAssertEqual(integrated.postflightFindings, base.postflightFindings, file: file, line: line)
        XCTAssertEqual(integrated.fallbackReason, base.fallbackReason, file: file, line: line)
        XCTAssertEqual(integrated.retryEligibility, base.retryEligibility, file: file, line: line)
    }
}
