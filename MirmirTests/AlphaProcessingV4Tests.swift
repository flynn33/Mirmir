import XCTest
@testable import Mirmir

final class AlphaProcessingV4Tests: XCTestCase {
    func testEightBitScalarMathExhaustivelyMatchesIndependentTieEvenOracle() throws {
        let fullScale = UInt16(255)
        for alpha in UInt16(0)...fullScale {
            for color in UInt16(0)...fullScale {
                let actual = try AlphaSampleMathV4.premultiply(
                    straight: color,
                    alpha: alpha,
                    fullScale: fullScale
                )
                let expected = tieEvenOracle(
                    numerator: UInt64(color) * UInt64(alpha),
                    denominator: UInt64(fullScale)
                )
                if actual != expected {
                    XCTFail(
                        "premultiply mismatch color=\(color) alpha=\(alpha) "
                            + "actual=\(actual) expected=\(expected)"
                    )
                    return
                }
            }
        }

        for alpha in UInt16(1)...fullScale {
            for color in UInt16(0)...alpha {
                let actual = try AlphaSampleMathV4.unpremultiply(
                    premultiplied: color,
                    alpha: alpha,
                    fullScale: fullScale
                )
                let expected = tieEvenOracle(
                    numerator: UInt64(color) * UInt64(fullScale),
                    denominator: UInt64(alpha)
                )
                if actual != expected {
                    XCTFail(
                        "unpremultiply mismatch color=\(color) alpha=\(alpha) "
                            + "actual=\(actual) expected=\(expected)"
                    )
                    return
                }
            }
        }
    }

    func testTieToEvenVectorsAndMaximumAlphaIdentity() throws {
        XCTAssertEqual(
            try AlphaSampleMathV4.unpremultiply(
                premultiplied: 1,
                alpha: 2,
                fullScale: 255
            ),
            128
        )
        XCTAssertEqual(
            try AlphaSampleMathV4.unpremultiply(
                premultiplied: 1,
                alpha: 6,
                fullScale: 255
            ),
            42
        )

        let plan = try makePlan(
            source: .straight,
            destination: .premultiplied,
            policy: .rejectNonZeroColor
        )
        let source = AlphaSampleV4(red: 255, green: 127, blue: 1, alpha: 255)
        XCTAssertEqual(try AlphaProcessingV4.process(source, using: plan), source)
    }

    func testTenBitStraightAndPremultipliedConversionUsesSignalScale() throws {
        let premultiply = try makePlan(
            source: .straight,
            destination: .premultiplied,
            policy: .clearColor,
            signalBitDepth: 10
        )
        let unpremultiply = try makePlan(
            source: .premultiplied,
            destination: .straight,
            policy: .clearColor,
            signalBitDepth: 10
        )
        let straight = AlphaSampleV4(
            red: 1_023,
            green: 510,
            blue: 0,
            alpha: 341
        )
        let premultiplied = AlphaSampleV4(
            red: 341,
            green: 170,
            blue: 0,
            alpha: 341
        )
        XCTAssertEqual(
            try AlphaProcessingV4.process(straight, using: premultiply),
            premultiplied
        )
        XCTAssertEqual(
            try AlphaProcessingV4.process(premultiplied, using: unpremultiply),
            straight
        )
    }

    func testZeroAlphaPoliciesAreExplicitAndFailClosed() throws {
        let hiddenColor = AlphaSampleV4(red: 255, green: 40, blue: 1, alpha: 0)

        let clear = try makePlan(
            source: .straight,
            destination: .premultiplied,
            policy: .clearColor
        )
        XCTAssertEqual(
            try AlphaProcessingV4.process(hiddenColor, using: clear),
            AlphaSampleV4(red: 0, green: 0, blue: 0, alpha: 0)
        )

        let preserve = try makePlan(
            source: .straight,
            destination: .straight,
            policy: .preserveStraightColor
        )
        XCTAssertEqual(
            try AlphaProcessingV4.process(hiddenColor, using: preserve),
            hiddenColor
        )

        let invalidPreserve = try makePlan(
            source: .straight,
            destination: .premultiplied,
            policy: .preserveStraightColor
        )
        XCTAssertThrowsError(
            try AlphaProcessingV4.process(hiddenColor, using: invalidPreserve)
        ) { error in
            XCTAssertEqual(
                error as? AlphaProcessingV4Error,
                .hiddenColorCannotBePreservedInPremultipliedOutput
            )
        }

        let reject = try makePlan(
            source: .straight,
            destination: .straight,
            policy: .rejectNonZeroColor
        )
        XCTAssertThrowsError(try AlphaProcessingV4.process(hiddenColor, using: reject)) {
            error in
            XCTAssertEqual(
                error as? AlphaProcessingV4Error,
                .zeroAlphaColorRejected(red: 255, green: 40, blue: 1)
            )
        }
    }

    func testMalformedPremultipliedAndOutOfRangeSamplesAreRejected() throws {
        let premultiplied = try makePlan(
            source: .premultiplied,
            destination: .straight,
            policy: .clearColor
        )
        XCTAssertThrowsError(
            try AlphaProcessingV4.process(
                AlphaSampleV4(red: 1, green: 0, blue: 0, alpha: 0),
                using: premultiplied
            )
        ) { error in
            XCTAssertEqual(
                error as? AlphaProcessingV4Error,
                .invalidPremultipliedComponent(
                    component: .red,
                    value: 1,
                    alpha: 0
                )
            )
        }

        let straight = try makePlan(
            source: .straight,
            destination: .premultiplied,
            policy: .clearColor
        )
        XCTAssertThrowsError(
            try AlphaProcessingV4.process(
                AlphaSampleV4(red: 256, green: 0, blue: 0, alpha: 255),
                using: straight
            )
        ) { error in
            XCTAssertEqual(
                error as? AlphaProcessingV4Error,
                .componentOutOfRange(component: .red, value: 256, maximum: 255)
            )
        }
    }

    func testPlanningRejectsUnsupportedDomainsAndBitDepths() throws {
        XCTAssertThrowsError(
            try AlphaProcessingPlanV4(
                sourceAssociation: .straight,
                destinationAssociation: .premultiplied,
                zeroAlphaPolicy: .clearColor,
                colorDomain: .encodedYCbCr,
                signalBitDepth: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? AlphaProcessingV4Error,
                .unsupportedColorDomain(.encodedYCbCr)
            )
        }
        XCTAssertThrowsError(
            try AlphaProcessingPlanV4(
                sourceAssociation: .straight,
                destinationAssociation: .premultiplied,
                zeroAlphaPolicy: .clearColor,
                colorDomain: .fullRangeRGB,
                signalBitDepth: 17
            )
        )
    }

    func testLowAlphaQuantizationIsExplicitlyNotRoundTripIdentity() throws {
        let premultiply = try makePlan(
            source: .straight,
            destination: .premultiplied,
            policy: .clearColor
        )
        let unpremultiply = try makePlan(
            source: .premultiplied,
            destination: .straight,
            policy: .clearColor
        )
        let source = AlphaSampleV4(red: 1, green: 0, blue: 0, alpha: 1)
        let associated = try AlphaProcessingV4.process(source, using: premultiply)
        let recovered = try AlphaProcessingV4.process(associated, using: unpremultiply)
        XCTAssertEqual(associated, AlphaSampleV4(red: 0, green: 0, blue: 0, alpha: 1))
        XCTAssertNotEqual(recovered, source)
    }

    private func makePlan(
        source: AlphaAssociationV4,
        destination: AlphaAssociationV4,
        policy: ZeroAlphaPolicyV4,
        signalBitDepth: Int = 8
    ) throws -> AlphaProcessingPlanV4 {
        try AlphaProcessingPlanV4(
            sourceAssociation: source,
            destinationAssociation: destination,
            zeroAlphaPolicy: policy,
            colorDomain: .fullRangeRGB,
            signalBitDepth: signalBitDepth
        )
    }

    private func tieEvenOracle(
        numerator: UInt64,
        denominator: UInt64
    ) -> UInt16 {
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        let doubled = remainder * 2
        if doubled < denominator {
            return UInt16(quotient)
        }
        if doubled > denominator {
            return UInt16(quotient + 1)
        }
        return UInt16(quotient.isMultiple(of: 2) ? quotient : quotient + 1)
    }
}
