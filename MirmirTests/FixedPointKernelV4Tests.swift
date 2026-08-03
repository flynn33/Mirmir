import XCTest
@testable import Mirmir

final class FixedPointKernelV4Tests: XCTestCase {
    func testEveryGeneratedKernelIsOrderedNormalizedAndDeterministic() throws {
        let plan = try SpatialScalePlanV4(
            sourceWidth: 37,
            sourceHeight: 29,
            targetWidth: 61,
            targetHeight: 48
        )
        let first = try FixedPointKernelIRV4(scalePlan: plan)
        let second = try FixedPointKernelIRV4(scalePlan: plan)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.coefficientProcedureID,
            ASHExecutionRequestV4.canonicalKernelContractID
        )

        for kernels in [first.horizontalKernels, first.verticalKernels] {
            XCTAssertEqual(kernels.map(\.phase), kernels.map(\.phase).sorted())
            for kernel in kernels {
                XCTAssertEqual(kernel.coefficients.count, 4)
                XCTAssertEqual(
                    kernel.coefficients.reduce(Int64(0)) { $0 + Int64($1) },
                    Int64(1 << 14)
                )
            }
        }
    }

    func testSourceAlignedKernelIsExactIdentity() throws {
        let kernel = try FixedPointCoefficientCompilerV4.compile(phase: .zero)
        XCTAssertEqual(kernel.coefficients, [0, 16_384, 0, 0])

        let source: [UInt16] = [
            0, 7, 31,
            63, 127, 255
        ]
        let plan = try SpatialScalePlanV4(
            sourceWidth: 3,
            sourceHeight: 2,
            targetWidth: 3,
            targetHeight: 2
        )
        let output = try FixedPointCPUExecutorV4.execute(
            source: source,
            sourceRowStride: 3,
            scalePlan: plan,
            kernelIR: FixedPointKernelIRV4(scalePlan: plan),
            minimumCode: 0,
            maximumCode: 255
        )
        XCTAssertEqual(output, source)
    }

    func testConstantPlanesRemainExactAcrossArbitraryScalesAndRanges() throws {
        for (sourceWidth, sourceHeight, targetWidth, targetHeight) in [
            (1, 1, 7, 5),
            (3, 2, 5, 7),
            (7, 5, 13, 8),
            (8, 6, 12, 9),
            (9, 7, 18, 14)
        ] {
            let plan = try SpatialScalePlanV4(
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                borderRule: .reflect101
            )
            let output = try FixedPointCPUExecutorV4.execute(
                source: Array(
                    repeating: UInt16(731),
                    count: sourceWidth * sourceHeight
                ),
                sourceRowStride: sourceWidth,
                scalePlan: plan,
                kernelIR: FixedPointKernelIRV4(scalePlan: plan),
                minimumCode: 64,
                maximumCode: 940
            )
            XCTAssertEqual(
                output,
                Array(repeating: UInt16(731), count: targetWidth * targetHeight)
            )
        }
    }

    func testPaddedStrideIsIgnoredAndRepeatedExecutionIsByteStable() throws {
        let source: [UInt16] = [
            64, 128, 256, 999, 999,
            320, 512, 700, 999, 999,
            900, 800, 640, 999, 999
        ]
        let plan = try SpatialScalePlanV4(
            sourceWidth: 3,
            sourceHeight: 3,
            targetWidth: 7,
            targetHeight: 5
        )
        let ir = try FixedPointKernelIRV4(scalePlan: plan)
        let first = try FixedPointCPUExecutorV4.execute(
            source: source,
            sourceRowStride: 5,
            scalePlan: plan,
            kernelIR: ir,
            minimumCode: 64,
            maximumCode: 940
        )
        for _ in 0..<20 {
            XCTAssertEqual(
                try FixedPointCPUExecutorV4.execute(
                    source: source,
                    sourceRowStride: 5,
                    scalePlan: plan,
                    kernelIR: ir,
                    minimumCode: 64,
                    maximumCode: 940
                ),
                first
            )
        }
        XCTAssertEqual(first.count, 35)
        XCTAssertTrue(first.allSatisfy { (64...940).contains($0) })
    }

    func testBorderRulesAndSignedTiesToEvenAreExact() throws {
        XCTAssertEqual(
            (-8...8).map {
                FixedPointCPUExecutorV4.borderIndex(
                    $0,
                    count: 4,
                    rule: .reflect101
                )
            },
            [2, 1, 0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1, 0, 1, 2]
        )
        XCTAssertEqual(
            try FixedPointCPUExecutorV4.roundTiesToEven(1, fractionalBits: 1),
            0
        )
        XCTAssertEqual(
            try FixedPointCPUExecutorV4.roundTiesToEven(3, fractionalBits: 1),
            2
        )
        XCTAssertEqual(
            try FixedPointCPUExecutorV4.roundTiesToEven(-1, fractionalBits: 1),
            0
        )
        XCTAssertEqual(
            try FixedPointCPUExecutorV4.roundTiesToEven(-3, fractionalBits: 1),
            -2
        )
        XCTAssertEqual(
            try FixedPointCPUExecutorV4.roundTiesToEven(-5, fractionalBits: 1),
            -2
        )
    }

    func testInvalidLayoutBoundsAndForgedKernelFailClosed() throws {
        let plan = try SpatialScalePlanV4(
            sourceWidth: 2,
            sourceHeight: 2,
            targetWidth: 4,
            targetHeight: 4
        )
        let ir = try FixedPointKernelIRV4(scalePlan: plan)
        XCTAssertThrowsError(
            try FixedPointCPUExecutorV4.execute(
                source: [0, 1, 2, 3],
                sourceRowStride: 1,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 0,
                maximumCode: 255
            )
        )
        XCTAssertThrowsError(
            try FixedPointCPUExecutorV4.execute(
                source: [0, 1, 2, 3],
                sourceRowStride: 2,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 255,
                maximumCode: 0
            )
        )
        XCTAssertThrowsError(
            try FixedPointPhaseKernelV4(
                phase: .zero,
                coefficients: [0, 1, 0, 0],
                fractionalBits: 14,
                roundingRule: .nearestTiesToEven
            )
        )

        let encoded = try JSONEncoder().encode(ir)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["coefficientProcedureID"] = "forged-procedure"
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                FixedPointKernelIRV4.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                error as? FixedPointKernelV4Error,
                .nonCanonicalKernelIR
            )
        }
    }
}
