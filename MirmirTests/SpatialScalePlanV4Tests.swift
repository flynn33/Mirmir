import XCTest
@testable import Mirmir

final class SpatialScalePlanV4Tests: XCTestCase {
    func testEveryPositionMatchesTheIndependentExactCenterFormula() throws {
        for sourceExtent in 1...17 {
            for targetExtent in sourceExtent...23 {
                let plan = try SpatialAxisScalePlanV4(
                    axis: .horizontal,
                    sourceExtent: sourceExtent,
                    targetExtent: targetExtent
                )
                XCTAssertEqual(plan.positions.count, targetExtent)
                XCTAssertEqual(
                    plan.scale,
                    try ExactRationalV4(
                        Int64(targetExtent),
                        Int64(sourceExtent)
                    )
                )

                for position in plan.positions {
                    let j = Int64(position.destinationIndex)
                    let independent = try ExactRationalV4(
                        (2 * j + 1) * Int64(sourceExtent) - Int64(targetExtent),
                        2 * Int64(targetExtent)
                    )
                    XCTAssertEqual(
                        try position.sourceCenterCoordinate(),
                        independent,
                        "source=\(sourceExtent) target=\(targetExtent) j=\(j)"
                    )
                    XCTAssertGreaterThanOrEqual(position.phase, .zero)
                    XCTAssertLessThan(position.phase, .one)
                }
            }
        }
    }

    func testTwoXAndThreeHalvesCompatibilityPhasesAreExact() throws {
        let twoX = try SpatialAxisScalePlanV4(
            axis: .horizontal,
            sourceExtent: 8,
            targetExtent: 16
        )
        XCTAssertEqual(
            twoX.uniquePhases,
            [try ExactRationalV4(1, 4), try ExactRationalV4(3, 4)]
        )
        XCTAssertEqual(twoX.positions[0].sourceBase, -1)
        XCTAssertEqual(twoX.positions[0].phase, try ExactRationalV4(3, 4))
        XCTAssertEqual(twoX.positions[1].sourceBase, 0)
        XCTAssertEqual(twoX.positions[1].phase, try ExactRationalV4(1, 4))

        let threeHalves = try SpatialAxisScalePlanV4(
            axis: .vertical,
            sourceExtent: 8,
            targetExtent: 12
        )
        XCTAssertEqual(
            threeHalves.uniquePhases,
            [
                try ExactRationalV4(1, 6),
                try ExactRationalV4(1, 2),
                try ExactRationalV4(5, 6)
            ]
        )
    }

    func testCoprimeOddAndAnisotropicDimensionsProduceIndependentAxes() throws {
        let plan = try SpatialScalePlanV4(
            sourceWidth: 7,
            sourceHeight: 5,
            targetWidth: 13,
            targetHeight: 8,
            borderRule: .reflect101
        )
        XCTAssertEqual(plan.sourceWidth, 7)
        XCTAssertEqual(plan.sourceHeight, 5)
        XCTAssertEqual(plan.targetWidth, 13)
        XCTAssertEqual(plan.targetHeight, 8)
        XCTAssertEqual(plan.horizontal.uniquePhases.count, 13)
        XCTAssertEqual(plan.vertical.uniquePhases.count, 8)
        XCTAssertEqual(plan.horizontal.borderRule, .reflect101)
        XCTAssertEqual(plan.vertical.borderRule, .reflect101)

        for index in 0..<plan.horizontal.positions.count {
            let mirrored = plan.horizontal.positions.count - 1 - index
            let sum = try plan.horizontal.positions[index]
                .sourceCenterCoordinate()
                .adding(
                    plan.horizontal.positions[mirrored]
                        .sourceCenterCoordinate()
                )
            XCTAssertEqual(sum, try ExactRationalV4(6))
        }
    }

    func testIdentityPlanUsesOnlyTheSourceAlignedPhase() throws {
        let plan = try SpatialAxisScalePlanV4(
            axis: .horizontal,
            sourceExtent: 9,
            targetExtent: 9
        )
        XCTAssertEqual(plan.uniquePhases, [.zero])
        XCTAssertEqual(
            plan.positions.map(\.sourceBase),
            Array(0..<9)
        )
    }

    func testCanonicalSerializationRebuildsAndRejectsDerivedFieldTampering() throws {
        let plan = try SpatialAxisScalePlanV4(
            axis: .horizontal,
            sourceExtent: 3,
            targetExtent: 5
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(plan)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SpatialAxisScalePlanV4.self,
                from: encoded
            ),
            plan
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["scale"] = ["numerator": 2, "denominator": 1]
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SpatialAxisScalePlanV4.self,
                from: tampered
            )
        ) { error in
            XCTAssertEqual(
                error as? SpatialScalePlanV4Error,
                .nonCanonicalSerializedPlan(axis: .horizontal)
            )
        }
    }

    func testTwoDimensionalSerializationIsVersionedAndAxisLocked() throws {
        let plan = try SpatialScalePlanV4(
            sourceWidth: 3,
            sourceHeight: 2,
            targetWidth: 7,
            targetHeight: 5
        )
        let encoded = try JSONEncoder().encode(plan)
        XCTAssertEqual(
            try JSONDecoder().decode(SpatialScalePlanV4.self, from: encoded),
            plan
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let horizontal = object["horizontal"]
        object["horizontal"] = object["vertical"]
        object["vertical"] = horizontal
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder().decode(SpatialScalePlanV4.self, from: tampered)
        ) { error in
            XCTAssertEqual(
                error as? SpatialScalePlanV4Error,
                .nonCanonicalTwoDimensionalPlan
            )
        }
    }

    func testInvalidAndOutOfPolicyExtentsFailClosed() throws {
        XCTAssertThrowsError(
            try SpatialAxisScalePlanV4(
                axis: .horizontal,
                sourceExtent: 0,
                targetExtent: 1
            )
        )
        XCTAssertThrowsError(
            try SpatialAxisScalePlanV4(
                axis: .vertical,
                sourceExtent: 9,
                targetExtent: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? SpatialScalePlanV4Error,
                .downscalingIsNotAdmitted(
                    axis: .vertical,
                    source: 9,
                    target: 8
                )
            )
        }
        XCTAssertThrowsError(
            try SpatialAxisScalePlanV4(
                axis: .horizontal,
                sourceExtent: 1,
                targetExtent:
                    SpatialAxisScalePlanV4.maximumSupportedExtent + 1
            )
        )
    }
}
