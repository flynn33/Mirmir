import XCTest
@testable import Mirmir

final class R07ProtectedRegionPolicyTests: XCTestCase {
    func testProtectedKindsMatchFrozenPrecedenceOrder() {
        XCTAssertEqual(
            R07ProtectedContentKind.allCases.map(\.rawValue),
            ["ui_capture", "subtitle", "text", "face", "line_art", "animation"]
        )
    }

    func testEveryFrozenSingleKindMaskFixtureIsAccepted() throws {
        let fixtures: [(R07ProtectedContentKind, [Int64])] = [
            (.uiCapture, [32_767, 0, 0, 0]),
            (.subtitle, [0, 32_767, 0, 0]),
            (.text, [0, 0, 32_767, 0]),
            (.face, [0, 0, 0, 32_767]),
            (.lineArt, [32_767, 32_767, 0, 0]),
            (.animation, [0, 0, 32_767, 32_767])
        ]
        for (kind, samples) in fixtures {
            let mask = try makeMask(kind, samples)
            XCTAssertEqual(mask.kind, kind)
            XCTAssertEqual(mask.width, 2)
            XCTAssertEqual(mask.height, 2)
            XCTAssertEqual(mask.samplesQ15.map(\.rawValue), samples)
        }
    }

    func testEmptyRegionListProducesZeroMasksAndNilOwners() throws {
        let result = try R07ProtectedRegionPolicy.compose(
            width: 2,
            height: 2,
            regions: []
        )
        XCTAssertEqual(result.composedQ15.map(\.rawValue), [0, 0, 0, 0])
        XCTAssertEqual(result.ownerByPixel, [nil, nil, nil, nil])
        XCTAssertTrue(result.lumaChromaPostprocessIdentical)
        for mask in result.masks.orderedMasks {
            XCTAssertEqual(mask.samplesQ15, [0, 0, 0, 0])
        }
    }

    func testOverlapUsesPixelwiseMaximumAndPositiveTiePrecedence() throws {
        let regions = try [
            makeMask(.uiCapture, [32_767, 10_000, 0, 0]),
            makeMask(.subtitle, [32_767, 20_000, 0, 0]),
            makeMask(.text, [0, 20_000, 0, 0]),
            makeMask(.face, [0, 0, 0, 0]),
            makeMask(.lineArt, [0, 0, 0, 0]),
            makeMask(.animation, [0, 0, 0, 0])
        ]
        let result = try R07ProtectedRegionPolicy.compose(
            width: 2,
            height: 2,
            regions: Array(regions.reversed())
        )
        XCTAssertEqual(result.composedQ15.map(\.rawValue), [32_767, 20_000, 0, 0])
        XCTAssertEqual(result.ownerByPixel, [.uiCapture, .subtitle, nil, nil])
        XCTAssertTrue(result.lumaChromaPostprocessIdentical)
    }

    func testMultipleRegionsOfOneKindStillUsePixelwiseMaximum() throws {
        let result = try R07ProtectedRegionPolicy.compose(
            width: 2,
            height: 2,
            regions: [
                makeMask(.text, [100, 300, 0, 0]),
                makeMask(.text, [200, 200, 0, 0])
            ]
        )
        XCTAssertEqual(result.composedQ15.map(\.rawValue), [200, 300, 0, 0])
        XCTAssertEqual(result.ownerByPixel, [.text, .text, nil, nil])
    }

    func testComposedLumaChromaAndPostprocessMasksAreByteIdentical() throws {
        let result = try R07ProtectedRegionPolicy.compose(
            width: 2,
            height: 2,
            regions: [makeMask(.face, [0, 32_767, 16_384, 0])]
        )
        let masks = result.masks.orderedMasks
        XCTAssertEqual(masks.map(\.id), R06ASHMaskID.allCases)
        XCTAssertEqual(masks[0].samplesQ15, masks[1].samplesQ15)
        XCTAssertEqual(masks[1].samplesQ15, masks[2].samplesQ15)
        XCTAssertEqual(masks.map(\.width), [2, 2, 2])
        XCTAssertEqual(masks.map(\.height), [2, 2, 2])
    }

    func testCompact4096BoundaryIsAcceptedAnd4097IsRejectedNeverClamped() throws {
        let boundary = try R07ProtectedMask.constantFill(
            kind: .text,
            width: 64,
            height: 64,
            declaredSampleCount: 4_096,
            fillQ15: 32_767
        )
        XCTAssertEqual(boundary.samplesQ15.count, 4_096)
        XCTAssertEqual(boundary.samplesQ15.first?.rawValue, 32_767)
        XCTAssertEqual(boundary.samplesQ15.last?.rawValue, 32_767)

        XCTAssertThrowsError(
            try R07ProtectedMask.constantFill(
                kind: .text,
                width: 64,
                height: 64,
                declaredSampleCount: 4_097,
                fillQ15: 32_767
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ProtectedRegionPolicyError,
                .sampleCountAboveMaximum(actual: 4_097, maximum: 4_096)
            )
        }
    }

    func testInvalidMaskMatrixRejectsWithoutClamping() {
        XCTAssertThrowsError(
            try R07ProtectedMask(
                kind: .text,
                width: 0,
                height: 1,
                samplesQ15: []
            )
        ) { error in
            XCTAssertEqual(error as? R07ProtectedRegionPolicyError, .invalidWidth(0))
        }
        XCTAssertThrowsError(
            try R07ProtectedMask(
                kind: .text,
                width: 65,
                height: 1,
                samplesQ15: []
            )
        ) { error in
            XCTAssertEqual(error as? R07ProtectedRegionPolicyError, .invalidWidth(65))
        }
        XCTAssertThrowsError(
            try R07ProtectedMask(
                kind: .text,
                width: 2,
                height: 2,
                samplesQ15: [0, 0, 0]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ProtectedRegionPolicyError,
                .sampleCountMismatch(role: "mask_q15", expected: 4, actual: 3)
            )
        }
        XCTAssertThrowsError(
            try R07ProtectedMask(
                kind: .text,
                width: 1,
                height: 1,
                samplesQ15: [32_768]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ProtectedRegionPolicyError,
                .maskSampleOutOfRange(index: 0, value: 32_768)
            )
        }
    }

    func testMaskDimensionMultiplicationFailsClosedOnOverflow() {
        XCTAssertThrowsError(
            try R07ProtectedMask(
                kind: .text,
                width: .max,
                height: 2,
                samplesQ15: []
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ProtectedRegionPolicyError,
                .sampleCountOverflow(width: .max, height: 2)
            )
        }
    }

    func testCompositionRejectsRegionDimensionMismatch() throws {
        let region = try R07ProtectedMask(
            kind: .subtitle,
            width: 1,
            height: 1,
            samplesQ15: [32_767]
        )
        XCTAssertThrowsError(
            try R07ProtectedRegionPolicy.compose(width: 2, height: 2, regions: [region])
        ) { error in
            XCTAssertEqual(
                error as? R07ProtectedRegionPolicyError,
                .regionDimensionMismatch(
                    kind: .subtitle,
                    expectedWidth: 2,
                    expectedHeight: 2,
                    actualWidth: 1,
                    actualHeight: 1
                )
            )
        }
    }
}

extension R07ProtectedRegionPolicyTests {
    func testFrozenWeightedMAEFixtureUsesCheckedTowardZeroDivision() throws {
        let result = try R07ProtectedRegionPolicy.weightedMAE(
            candidateQ16: [0, 65_536, 0, 65_536],
            referenceQ16: [0, 0, 0, 0],
            maskQ15: [32_767, 32_767, 32_767, 32_767]
        )
        XCTAssertEqual(result.weightedMAEQ16.rawValue, 32_768)
        XCTAssertEqual(R07WeightedMAEResult.thresholdQ16, 1_024)
        XCTAssertTrue(result.violatesProtectedIntegrity)
    }

    func testWeightedMAEThresholdEqualityDoesNotViolate() throws {
        let equality = try R07ProtectedRegionPolicy.weightedMAE(
            candidateQ16: [1_024],
            referenceQ16: [0],
            maskQ15: [32_767]
        )
        let oneAbove = try R07ProtectedRegionPolicy.weightedMAE(
            candidateQ16: [1_025],
            referenceQ16: [0],
            maskQ15: [32_767]
        )
        XCTAssertFalse(equality.violatesProtectedIntegrity)
        XCTAssertTrue(oneAbove.violatesProtectedIntegrity)
    }

    func testWeightedMAERejectsZeroWeightExactly() {
        XCTAssertThrowsError(
            try R07ProtectedRegionPolicy.weightedMAE(
                candidateQ16: [0, 65_536],
                referenceQ16: [0, 0],
                maskQ15: [0, 0]
            )
        ) { error in
            XCTAssertEqual(error as? R07ProtectedRegionPolicyError, .zeroWeightRejected)
        }
    }

    func testWeightedMAERejectsOversizeCountMismatchAndDomains() {
        XCTAssertThrowsError(
            try R07ProtectedRegionPolicy.weightedMAE(
                candidateQ16: [Int64](repeating: 0, count: 4_097),
                referenceQ16: [Int64](repeating: 0, count: 4_097),
                maskQ15: [Int64](repeating: 1, count: 4_097)
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ProtectedRegionPolicyError,
                .sampleCountAboveMaximum(actual: 4_097, maximum: 4_096)
            )
        }
        XCTAssertThrowsError(
            try R07ProtectedRegionPolicy.weightedMAE(
                candidateQ16: [0, 0],
                referenceQ16: [0],
                maskQ15: [1, 1]
            )
        )
        XCTAssertThrowsError(
            try R07ProtectedRegionPolicy.weightedMAE(
                candidateQ16: [-1],
                referenceQ16: [0],
                maskQ15: [1]
            )
        ) { error in
            XCTAssertEqual(
                error as? R07ProtectedRegionPolicyError,
                .lumaSampleOutOfRange(role: "candidate", index: 0, value: -1)
            )
        }
        XCTAssertThrowsError(
            try R07ProtectedRegionPolicy.weightedMAE(
                candidateQ16: [0],
                referenceQ16: [0],
                maskQ15: [32_768]
            )
        )
    }

    func testProtectedPolicyValuesAreSendableAndHashable() throws {
        let mask = try makeMask(.uiCapture, [32_767, 0, 0, 0])
        let composition = try R07ProtectedRegionPolicy.compose(
            width: 2,
            height: 2,
            regions: [mask]
        )
        requireSendable(mask)
        requireSendable(composition)
        XCTAssertEqual(Set([mask, mask]).count, 1)
        XCTAssertEqual(Set([composition, composition]).count, 1)
    }
}

private extension R07ProtectedRegionPolicyTests {
    func makeMask(
        _ kind: R07ProtectedContentKind,
        _ samples: [Int64]
    ) throws -> R07ProtectedMask {
        try R07ProtectedMask(
            kind: kind,
            width: 2,
            height: 2,
            samplesQ15: samples
        )
    }

    func requireSendable<Value: Sendable>(_ value: Value) {
        _ = value
    }
}
