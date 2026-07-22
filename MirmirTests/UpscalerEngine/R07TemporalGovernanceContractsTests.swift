import XCTest
@testable import Mirmir

final class R07TemporalGovernanceContractsTests: XCTestCase {
    func testIdenticalFixtureProducesExactZeroAndOneMetrics() throws {
        let result = try R07TemporalAnalysisEngine.analyze(
            makeInput(
                frameOrdinals: [10, 11],
                current: [0, 16_384, 32_768, 65_536],
                previous: [0, 16_384, 32_768, 65_536],
                alignedPrevious: [0, 16_384, 32_768, 65_536],
                occlusionMask: [0, 0, 0, 0]
            )
        )

        XCTAssertEqual(result.sampleCount, 4)
        XCTAssertEqual(result.sceneCutRawQ16, .zero)
        XCTAssertFalse(result.sceneCutDetected)
        XCTAssertEqual(result.motionConfidenceQ16, .one)
        XCTAssertTrue(result.motionValid)
        XCTAssertEqual(result.validMotionSampleCount, 4)
        XCTAssertEqual(result.occlusionQ16, .zero)
        XCTAssertFalse(result.occlusionDetected)
    }

    func testHardCutFixtureIsAcceptedWithInvalidMotionConfidence() throws {
        let result = try R07TemporalAnalysisEngine.analyze(
            makeInput(
                frameOrdinals: [20, 21],
                current: [65_536, 65_536, 65_536, 65_536],
                previous: [0, 0, 0, 0],
                alignedPrevious: [0, 0, 0, 0],
                occlusionMask: [0, 0, 0, 0]
            )
        )

        XCTAssertEqual(result.sceneCutRawQ16, .one)
        XCTAssertTrue(result.sceneCutDetected)
        XCTAssertEqual(result.motionConfidenceQ16, .zero)
        XCTAssertFalse(result.motionValid)
        XCTAssertEqual(result.occlusionQ16, .zero)
        XCTAssertFalse(result.occlusionDetected)
    }

    func testAlignedTranslationFixtureUsesAlignedPreviousSamples() throws {
        let result = try R07TemporalAnalysisEngine.analyze(
            makeInput(
                frameOrdinals: [30, 31],
                current: [0, 65_536, 0, 0],
                previous: [65_536, 0, 0, 0],
                alignedPrevious: [0, 65_536, 0, 0],
                occlusionMask: [0, 0, 0, 0]
            )
        )

        XCTAssertEqual(result.sceneCutRawQ16.rawValue, 32_768)
        XCTAssertFalse(result.sceneCutDetected)
        XCTAssertEqual(result.motionConfidenceQ16, .one)
        XCTAssertTrue(result.motionValid)
    }

    func testPartiallyOccludedFixtureExcludesOccludedMotionSamples() throws {
        let result = try R07TemporalAnalysisEngine.analyze(
            makeInput(
                frameOrdinals: [40, 41],
                current: [8_192, 8_192, 65_536, 65_536],
                previous: [8_192, 8_192, 0, 0],
                alignedPrevious: [8_192, 8_192, 0, 0],
                occlusionMask: [0, 0, 1, 1]
            )
        )

        XCTAssertEqual(result.motionConfidenceQ16, .one)
        XCTAssertTrue(result.motionValid)
        XCTAssertEqual(result.validMotionSampleCount, 2)
        XCTAssertEqual(result.occlusionQ16.rawValue, 32_768)
        XCTAssertTrue(result.occlusionDetected)
    }

    func testAllThreeDetectionThresholdsIncludeEquality() throws {
        let sceneCut = try R07TemporalAnalysisEngine.analyze(
            makeInput(
                frameOrdinals: [60, 61],
                current: [49_152],
                previous: [0],
                alignedPrevious: [0],
                occlusionMask: [0]
            )
        )
        XCTAssertEqual(sceneCut.sceneCutRawQ16.rawValue, 49_152)
        XCTAssertTrue(sceneCut.sceneCutDetected)

        let motion = try R07TemporalAnalysisEngine.analyze(
            makeInput(
                frameOrdinals: [70, 71],
                current: [16_384],
                previous: [0],
                alignedPrevious: [0],
                occlusionMask: [0]
            )
        )
        XCTAssertEqual(motion.motionConfidenceQ16.rawValue, 49_152)
        XCTAssertTrue(motion.motionValid)

        let occlusion = try R07TemporalAnalysisEngine.analyze(
            makeInput(
                frameOrdinals: [80, 81],
                current: [0, 0, 0, 0],
                previous: [0, 0, 0, 0],
                alignedPrevious: [0, 0, 0, 0],
                occlusionMask: [1, 0, 0, 0]
            )
        )
        XCTAssertEqual(occlusion.occlusionQ16.rawValue, 16_384)
        XCTAssertTrue(occlusion.occlusionDetected)
    }

    func testFrameOrdinalsMustBeStrictlyIncreasing() {
        let stale = makeInput(
            frameOrdinals: [51, 50],
            current: [0],
            previous: [0],
            alignedPrevious: [0],
            occlusionMask: [0]
        )
        XCTAssertThrowsError(try R07TemporalAnalysisEngine.analyze(stale)) { error in
            let expected = R07TemporalAnalysisError.frameOrdinalsNotStrictlyIncreasing(
                previous: 51,
                current: 50
            )
            XCTAssertEqual(error as? R07TemporalAnalysisError, expected)
            XCTAssertEqual((error as? R07TemporalAnalysisError)?.reason, "frame_ordinals_not_strictly_increasing")
        }

        let duplicate = makeInput(
            frameOrdinals: [51, 51],
            current: [0],
            previous: [0],
            alignedPrevious: [0],
            occlusionMask: [0]
        )
        XCTAssertThrowsError(try R07TemporalAnalysisEngine.analyze(duplicate))
    }

    func testCompactConstantFillBoundaryAccepts4096AndRejects4097WithoutClamping() throws {
        let boundary = try R07TemporalAnalysisInput.constantFill(
            previousFrameOrdinal: 90,
            currentFrameOrdinal: 91,
            declaredSampleCount: 4_096,
            currentFillQ16: 0,
            previousFillQ16: 0,
            alignedPreviousFillQ16: 0,
            occlusionFill: 0
        )
        let result = try R07TemporalAnalysisEngine.analyze(boundary)
        XCTAssertEqual(boundary.currentLumaQ16.count, 4_096)
        XCTAssertEqual(boundary.previousLumaQ16.count, 4_096)
        XCTAssertEqual(boundary.alignedPreviousLumaQ16.count, 4_096)
        XCTAssertEqual(boundary.occlusionMask.count, 4_096)
        XCTAssertEqual(result.sampleCount, 4_096)

        XCTAssertThrowsError(
            try R07TemporalAnalysisInput.constantFill(
                previousFrameOrdinal: 90,
                currentFrameOrdinal: 91,
                declaredSampleCount: 4_097,
                currentFillQ16: 0,
                previousFillQ16: 0,
                alignedPreviousFillQ16: 0,
                occlusionFill: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? R07TemporalAnalysisError,
                .vectorOrMaskOversizeRejected(actual: 4_097, maximum: 4_096)
            )
        }
    }

    func testEmptyMismatchAndAllOccludedInputsFailClosedWithExactReasons() {
        let empty = makeInput(
            frameOrdinals: [100, 101],
            current: [],
            previous: [],
            alignedPrevious: [],
            occlusionMask: []
        )
        assertRejection(
            empty,
            expected: .emptyVectorRejected,
            reason: "empty_vector_rejected"
        )

        let mismatch = makeInput(
            frameOrdinals: [110, 111],
            current: [0, 0],
            previous: [0],
            alignedPrevious: [0, 0],
            occlusionMask: [0, 0]
        )
        assertRejection(
            mismatch,
            expected: .sampleCountMismatchRejected,
            reason: "sample_count_mismatch_rejected"
        )

        let allOccluded = makeInput(
            frameOrdinals: [120, 121],
            current: [0, 0],
            previous: [0, 0],
            alignedPrevious: [0, 0],
            occlusionMask: [1, 1]
        )
        assertRejection(
            allOccluded,
            expected: .noValidMotionSamplesRejected,
            reason: "no_valid_motion_samples_rejected"
        )
    }

    func testLumaDomainAndBinaryOcclusionMaskAreRejectedInsteadOfClamped() {
        let invalidLuma = makeInput(
            frameOrdinals: [0, 1],
            current: [65_537],
            previous: [0],
            alignedPrevious: [0],
            occlusionMask: [0]
        )
        assertRejection(
            invalidLuma,
            expected: .lumaSampleOutOfRange(role: .current, index: 0, value: 65_537),
            reason: "luma_sample_out_of_range"
        )

        let invalidMask = makeInput(
            frameOrdinals: [0, 1],
            current: [0],
            previous: [0],
            alignedPrevious: [0],
            occlusionMask: [2]
        )
        assertRejection(
            invalidMask,
            expected: .invalidOcclusionMaskValue(index: 0, value: 2),
            reason: "invalid_occlusion_mask_value"
        )
    }

    func testCheckedInt64HelpersRejectEveryUnsafeOperationAndRoundTowardZero() throws {
        XCTAssertEqual(try R07CheckedInt64.divideTowardZero(3, by: 2), 1)
        XCTAssertEqual(try R07CheckedInt64.divideTowardZero(-3, by: 2), -1)
        XCTAssertEqual(try R07CheckedInt64.divideTowardZero(3, by: -2), -1)
        XCTAssertEqual(try R07CheckedInt64.magnitude(-65_536), 65_536)

        XCTAssertThrowsError(try R07CheckedInt64.add(Int64.max, 1)) { error in
            XCTAssertEqual(error as? R07CheckedInt64Error, .overflow(operation: "addition"))
        }
        XCTAssertThrowsError(try R07CheckedInt64.subtract(Int64.min, 1)) { error in
            XCTAssertEqual(error as? R07CheckedInt64Error, .overflow(operation: "subtraction"))
        }
        XCTAssertThrowsError(try R07CheckedInt64.multiply(Int64.max, 2)) { error in
            XCTAssertEqual(error as? R07CheckedInt64Error, .overflow(operation: "multiplication"))
        }
        XCTAssertThrowsError(try R07CheckedInt64.divideTowardZero(Int64.min, by: -1)) { error in
            XCTAssertEqual(error as? R07CheckedInt64Error, .overflow(operation: "division"))
        }
        XCTAssertThrowsError(try R07CheckedInt64.divideTowardZero(1, by: 0)) { error in
            XCTAssertEqual(error as? R07CheckedInt64Error, .divisionByZero)
        }
        XCTAssertThrowsError(try R07CheckedInt64.magnitude(Int64.min)) { error in
            XCTAssertEqual(error as? R07CheckedInt64Error, .minimumMagnitude)
        }
    }

    private func makeInput(
        frameOrdinals: [Int64],
        current: [Int64],
        previous: [Int64],
        alignedPrevious: [Int64],
        occlusionMask: [Int64]
    ) -> R07TemporalAnalysisInput {
        precondition(frameOrdinals.count == 2)
        return R07TemporalAnalysisInput(
            previousFrameOrdinal: frameOrdinals[0],
            currentFrameOrdinal: frameOrdinals[1],
            currentLumaQ16: current,
            previousLumaQ16: previous,
            alignedPreviousLumaQ16: alignedPrevious,
            occlusionMask: occlusionMask
        )
    }

    private func assertRejection(
        _ input: R07TemporalAnalysisInput,
        expected: R07TemporalAnalysisError,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try R07TemporalAnalysisEngine.analyze(input),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? R07TemporalAnalysisError, expected, file: file, line: line)
            XCTAssertEqual((error as? R07TemporalAnalysisError)?.reason, reason, file: file, line: line)
        }
    }
}
