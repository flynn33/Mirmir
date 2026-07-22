import XCTest
@testable import Mirmir

final class R08AnalysisOutputDecoderTests: XCTestCase {
    func testDecoderAcceptsExactNineHeadInventoryAndRetainsClassification() throws {
        let classification = try sourceClassification()
        let decoded = try R08AnalysisOutputDecoder.decode(
            rawHeads(),
            sourceClassification: classification
        )

        XCTAssertEqual(decoded.protection.faceSkinQ15.samples, [0, 8_192, 16_384, 32_767])
        XCTAssertEqual(decoded.protection.textLineArtQ15.samples.count, 4)
        XCTAssertEqual(decoded.condition.animationUILikelihoodQ15.samples.count, 4)
        XCTAssertEqual(decoded.condition.noiseCompressionSeverityQ15.samples.count, 4)
        XCTAssertEqual(decoded.condition.blurMotionBlurEstimateQ15.samples.count, 4)
        XCTAssertEqual(decoded.riskConfidence.aliasingRingingRiskQ15.samples.count, 4)
        XCTAssertEqual(decoded.riskConfidence.textureDetailConfidenceQ15.samples.count, 4)
        XCTAssertEqual(
            decoded.riskConfidence.motionReliabilityOcclusionRiskQ15.samples.count,
            4
        )
        XCTAssertEqual(decoded.noReferenceQualityQ15.rawValue, 24_576)
        XCTAssertEqual(decoded.sourceClassification, classification)
    }

    func testDecoderRejectsMissingDuplicateAndUnexpectedHeadIDs() throws {
        var missing = rawHeads()
        missing.removeLast()
        XCTAssertThrowsError(
            try R08AnalysisOutputDecoder.decode(
                missing,
                sourceClassification: sourceClassification()
            )
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .missingOutputHead("no_reference_quality_estimate")
            )
        }

        var duplicate = rawHeads()
        duplicate.append(duplicate[6])
        XCTAssertThrowsError(
            try R08AnalysisOutputDecoder.decode(
                duplicate,
                sourceClassification: sourceClassification()
            )
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .duplicateOutputHead("texture_detail_confidence")
            )
        }

        var unexpected = rawHeads()
        unexpected.append(
            R08RawAnalysisOutputHead(
                id: "other_analysis_head",
                payload: .spatial(width: 2, height: 2, samplesQ15: [0, 0, 0, 0])
            )
        )
        XCTAssertThrowsError(
            try R08AnalysisOutputDecoder.decode(
                unexpected,
                sourceClassification: sourceClassification()
            )
        ) { error in
            XCTAssertEqual(
                error as? R08AnalysisContractError,
                .unexpectedOutputHead("other_analysis_head")
            )
        }
    }

    func testDecoderRejectsPixelAndBackendAuthorityOutputsWithTypedErrors() throws {
        for id in ["pixel_frame", "pixel_residual"] {
            var heads = rawHeads()
            heads.append(
                R08RawAnalysisOutputHead(
                    id: id,
                    payload: .spatial(width: 2, height: 2, samplesQ15: [0, 0, 0, 0])
                )
            )
            assertDecodeError(heads, expected: .forbiddenPixelOutput(id))
        }

        var backendSelection = rawHeads()
        backendSelection.append(
            R08RawAnalysisOutputHead(
                id: "selected_backend_id",
                payload: .scalar(samplesQ15: [1])
            )
        )
        assertDecodeError(
            backendSelection,
            expected: .forbiddenModelDecisionAuthority("selected_backend_id")
        )
    }

    func testDecoderRejectsKindAndSampleCountMismatches() throws {
        var wrongKind = rawHeads()
        wrongKind[0] = R08RawAnalysisOutputHead(
            id: R08AnalysisOutputHeadID.faceSkinProtectionMask.rawValue,
            payload: .scalar(samplesQ15: [0])
        )
        assertDecodeError(
            wrongKind,
            expected: .outputHeadKindMismatch("face_skin_protection_mask")
        )

        var spatialCount = rawHeads()
        spatialCount[0] = R08RawAnalysisOutputHead(
            id: R08AnalysisOutputHeadID.faceSkinProtectionMask.rawValue,
            payload: .spatial(width: 2, height: 2, samplesQ15: [0, 1, 2])
        )
        assertDecodeError(
            spatialCount,
            expected: .sampleCountMismatch(
                role: "face_skin_protection_mask",
                expected: 4,
                actual: 3
            )
        )

        var scalarCount = rawHeads()
        scalarCount[8] = R08RawAnalysisOutputHead(
            id: R08AnalysisOutputHeadID.noReferenceQualityEstimate.rawValue,
            payload: .scalar(samplesQ15: [1, 2])
        )
        assertDecodeError(
            scalarCount,
            expected: .sampleCountMismatch(
                role: "no_reference_quality_estimate",
                expected: 1,
                actual: 2
            )
        )
    }

    func testDecoderRejectsQ15UnderflowAndOverflowWithoutClamping() {
        for value in [Int64(-1), 32_768] {
            var heads = rawHeads()
            heads[0] = R08RawAnalysisOutputHead(
                id: R08AnalysisOutputHeadID.faceSkinProtectionMask.rawValue,
                payload: .spatial(width: 2, height: 2, samplesQ15: [value, 0, 0, 0])
            )
            assertDecodeError(
                heads,
                expected: .sampleOutOfRange(
                    role: "face_skin_protection_mask",
                    index: 0,
                    value: value
                )
            )
        }
    }
}

private extension R08AnalysisOutputDecoderTests {
    func rawHeads() -> [R08RawAnalysisOutputHead] {
        R08AnalysisOutputHeadID.allCases.map { id in
            if id == .noReferenceQualityEstimate {
                return R08RawAnalysisOutputHead(
                    id: id.rawValue,
                    payload: .scalar(samplesQ15: [24_576])
                )
            }
            return R08RawAnalysisOutputHead(
                id: id.rawValue,
                payload: .spatial(
                    width: 2,
                    height: 2,
                    samplesQ15: [0, 8_192, 16_384, 32_767]
                )
            )
        }
    }

    func sourceClassification() throws -> R08SourceClassificationResult {
        R08SourceClassificationResult(
            classification: .mixed,
            confidenceQ15: try R08Q15Value(22_500, role: "classification")
        )
    }

    func assertDecodeError(
        _ heads: [R08RawAnalysisOutputHead],
        expected: R08AnalysisContractError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try R08AnalysisOutputDecoder.decode(
                heads,
                sourceClassification: sourceClassification()
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? R08AnalysisContractError, expected, file: file, line: line)
        }
    }
}
