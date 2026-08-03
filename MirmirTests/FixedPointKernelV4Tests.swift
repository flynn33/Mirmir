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

    func testPreparedDirectExecutionMatchesIndependentScalarOracle() throws {
        let cases: [(
            sourceWidth: Int,
            sourceHeight: Int,
            targetWidth: Int,
            targetHeight: Int,
            padding: Int,
            border: SpatialBorderRuleV4,
            minimum: UInt16,
            maximum: UInt16
        )] = [
            (1, 1, 7, 5, 3, .clamp, 0, 65_535),
            (2, 3, 5, 8, 5, .reflect101, 64, 940),
            (7, 5, 13, 9, 1, .clamp, 0, 1_023),
            (17, 11, 29, 19, 7, .reflect101, 16, 235)
        ]
        for (caseIndex, item) in cases.enumerated() {
            let stride = item.sourceWidth + item.padding
            var source = Array(
                repeating: item.maximum,
                count: stride * item.sourceHeight
            )
            for y in 0..<item.sourceHeight {
                for x in 0..<item.sourceWidth {
                    let selector = (x + y * item.sourceWidth + caseIndex) % 5
                    source[y * stride + x] = switch selector {
                    case 0: item.minimum
                    case 1: item.maximum
                    case 2: UInt16((Int(item.minimum) + Int(item.maximum)) / 2)
                    case 3: UInt16((x * 257 + y * 509) % 65_536)
                    default: UInt16((x ^ y) &* 4_099 % 65_536)
                    }
                }
            }
            let plan = try SpatialScalePlanV4(
                sourceWidth: item.sourceWidth,
                sourceHeight: item.sourceHeight,
                targetWidth: item.targetWidth,
                targetHeight: item.targetHeight,
                borderRule: item.border
            )
            let ir = try FixedPointKernelIRV4(scalePlan: plan)
            let prepared = try FixedPointPreparedScaleV4(
                scalePlan: plan,
                kernelIR: ir
            )
            let expected = try scalarOracle(
                source: source,
                sourceRowStride: stride,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: item.minimum,
                maximumCode: item.maximum
            )
            var workspace = FixedPointCPUWorkspaceV4()
            let first = try FixedPointCPUExecutorV4.execute(
                source: source,
                sourceRowStride: stride,
                preparedScale: prepared,
                minimumCode: item.minimum,
                maximumCode: item.maximum,
                workspace: &workspace
            )
            XCTAssertEqual(first, expected, "case=\(caseIndex)")
            XCTAssertEqual(
                workspace.reusableHorizontalSampleCount,
                item.targetWidth * 4
            )

            var direct = Array(
                repeating: UInt16.max,
                count: prepared.outputSampleCount + 3
            )
            try source.withUnsafeBufferPointer { sourceBuffer in
                try direct.withUnsafeMutableBufferPointer { destination in
                    try FixedPointCPUExecutorV4.execute(
                        source: sourceBuffer,
                        sourceRowStride: stride,
                        preparedScale: prepared,
                        minimumCode: item.minimum,
                        maximumCode: item.maximum,
                        destination: destination,
                        workspace: &workspace
                    )
                }
            }
            XCTAssertEqual(Array(direct.prefix(expected.count)), expected)
            XCTAssertEqual(Array(direct.suffix(3)), [UInt16.max, .max, .max])
        }
    }

    func testPreparedExecutionRejectsShortAndOverlappingDestinations() throws {
        let plan = try SpatialScalePlanV4(
            sourceWidth: 3,
            sourceHeight: 3,
            targetWidth: 5,
            targetHeight: 5
        )
        let prepared = try FixedPointPreparedScaleV4(
            scalePlan: plan,
            kernelIR: FixedPointKernelIRV4(scalePlan: plan)
        )
        let capacity = max(9, prepared.outputSampleCount)
        let storage = UnsafeMutableBufferPointer<UInt16>.allocate(
            capacity: capacity
        )
        storage.initialize(repeating: 17)
        defer {
            storage.deinitialize()
            storage.deallocate()
        }
        var workspace = FixedPointCPUWorkspaceV4()
        let source = UnsafeBufferPointer(start: storage.baseAddress, count: 9)
        XCTAssertThrowsError(
            try FixedPointCPUExecutorV4.execute(
                source: source,
                sourceRowStride: 3,
                preparedScale: prepared,
                minimumCode: 0,
                maximumCode: 255,
                destination: UnsafeMutableBufferPointer(
                    start: storage.baseAddress,
                    count: prepared.outputSampleCount
                ),
                workspace: &workspace
            )
        ) { error in
            XCTAssertEqual(
                error as? FixedPointKernelV4Error,
                .overlappingSourceAndDestination
            )
        }

        let separate = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: 24)
        separate.initialize(repeating: 0)
        defer {
            separate.deinitialize()
            separate.deallocate()
        }
        XCTAssertThrowsError(
            try FixedPointCPUExecutorV4.execute(
                source: source,
                sourceRowStride: 3,
                preparedScale: prepared,
                minimumCode: 0,
                maximumCode: 255,
                destination: separate,
                workspace: &workspace
            )
        ) { error in
            XCTAssertEqual(
                error as? FixedPointKernelV4Error,
                .invalidDestinationLayout(expectedCount: 25, actualCount: 24)
            )
        }
    }

    func testInterleavedExecutionRejectsOverlapAndSpanOverflowBeforeAccess()
        throws {
        let plan = try SpatialScalePlanV4(
            sourceWidth: 2,
            sourceHeight: 2,
            targetWidth: 2,
            targetHeight: 2
        )
        let prepared = try FixedPointPreparedScaleV4(
            scalePlan: plan,
            kernelIR: FixedPointKernelIRV4(scalePlan: plan)
        )
        var workspace = FixedPointCPUWorkspaceV4()
        var storage = Array(repeating: UInt8(17), count: 8)
        try storage.withUnsafeMutableBytes { bytes in
            let base = try XCTUnwrap(bytes.baseAddress)
            XCTAssertThrowsError(try FixedPointCPUExecutorV4
                .executeInterleavedComponent(
                    sourceBaseAddress: UnsafeRawPointer(base),
                    sourceRowBytes: 2,
                    destinationBaseAddress: base,
                    destinationRowBytes: 2,
                    bytesPerComponent: 1,
                    componentsPerElement: 1,
                    componentIndex: 0,
                    storedCodeShift: 0,
                    preparedScale: prepared,
                    minimumCode: 0,
                    maximumCode: 255,
                    workspace: &workspace
                )) { error in
                XCTAssertEqual(
                    error as? FixedPointKernelV4Error,
                    .overlappingSourceAndDestination
                )
            }

            XCTAssertThrowsError(try FixedPointCPUExecutorV4
                .executeInterleavedComponent(
                    sourceBaseAddress: UnsafeRawPointer(base),
                    sourceRowBytes: Int.max,
                    destinationBaseAddress: base.advanced(by: 4),
                    destinationRowBytes: 2,
                    bytesPerComponent: 1,
                    componentsPerElement: 1,
                    componentIndex: 0,
                    storedCodeShift: 0,
                    preparedScale: prepared,
                    minimumCode: 0,
                    maximumCode: 255,
                    workspace: &workspace
                )) { error in
                XCTAssertEqual(
                    error as? FixedPointKernelV4Error,
                    .executionArithmeticOverflow
                )
            }
        }
    }

    func testOneByteInterleavedExecutionRejectsUnrepresentableStoredCodes()
        throws {
        let plan = try SpatialScalePlanV4(
            sourceWidth: 2,
            sourceHeight: 2,
            targetWidth: 2,
            targetHeight: 2
        )
        let prepared = try FixedPointPreparedScaleV4(
            scalePlan: plan,
            kernelIR: FixedPointKernelIRV4(scalePlan: plan)
        )
        var workspace = FixedPointCPUWorkspaceV4()
        let source = Array(repeating: UInt8(17), count: 4)
        var destination = Array(repeating: UInt8(0xA5), count: 4)

        for (maximumCode, storedCodeShift) in [
            (UInt16(256), 0),
            (UInt16(255), 1),
            (UInt16(0), 8)
        ] {
            let before = destination
            try source.withUnsafeBytes { sourceBytes in
                try destination.withUnsafeMutableBytes { destinationBytes in
                    XCTAssertThrowsError(try FixedPointCPUExecutorV4
                        .executeInterleavedComponent(
                            sourceBaseAddress: try XCTUnwrap(
                                sourceBytes.baseAddress
                            ),
                            sourceRowBytes: 2,
                            destinationBaseAddress: try XCTUnwrap(
                                destinationBytes.baseAddress
                            ),
                            destinationRowBytes: 2,
                            bytesPerComponent: 1,
                            componentsPerElement: 1,
                            componentIndex: 0,
                            storedCodeShift: storedCodeShift,
                            preparedScale: prepared,
                            minimumCode: 0,
                            maximumCode: maximumCode,
                            workspace: &workspace
                        )) { error in
                            XCTAssertEqual(
                                error as? FixedPointKernelV4Error,
                                .executionArithmeticOverflow
                            )
                        }
                }
            }
            XCTAssertEqual(destination, before)
        }
    }

    private func scalarOracle(
        source: [UInt16],
        sourceRowStride: Int,
        scalePlan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4,
        minimumCode: UInt16,
        maximumCode: UInt16
    ) throws -> [UInt16] {
        let targetWidth = scalePlan.targetWidth
        var horizontal = Array(
            repeating: Int64(0),
            count: targetWidth * scalePlan.sourceHeight
        )
        for sourceY in 0..<scalePlan.sourceHeight {
            for targetX in 0..<targetWidth {
                let position = scalePlan.horizontal.positions[targetX]
                let kernel = kernelIR.horizontalKernels[
                    kernelIR.horizontalKernelIndexByDestination[targetX]
                ]
                var accumulator: Int64 = 0
                for tap in 0..<4 {
                    let sourceX = FixedPointCPUExecutorV4.borderIndex(
                        position.sourceBase
                            + FixedPointPhaseKernelV4.tapOffsets[tap],
                        count: scalePlan.sourceWidth,
                        rule: scalePlan.horizontal.borderRule
                    )
                    accumulator += Int64(
                        source[sourceY * sourceRowStride + sourceX]
                    ) * Int64(kernel.coefficients[tap])
                }
                horizontal[sourceY * targetWidth + targetX] = accumulator
            }
        }
        var output = Array(
            repeating: UInt16(0),
            count: targetWidth * scalePlan.targetHeight
        )
        for targetY in 0..<scalePlan.targetHeight {
            let position = scalePlan.vertical.positions[targetY]
            let kernel = kernelIR.verticalKernels[
                kernelIR.verticalKernelIndexByDestination[targetY]
            ]
            for targetX in 0..<targetWidth {
                var accumulator: Int64 = 0
                for tap in 0..<4 {
                    let sourceY = FixedPointCPUExecutorV4.borderIndex(
                        position.sourceBase
                            + FixedPointPhaseKernelV4.tapOffsets[tap],
                        count: scalePlan.sourceHeight,
                        rule: scalePlan.vertical.borderRule
                    )
                    accumulator += horizontal[sourceY * targetWidth + targetX]
                        * Int64(kernel.coefficients[tap])
                }
                let rounded = try FixedPointCPUExecutorV4.roundTiesToEven(
                    accumulator,
                    fractionalBits: kernelIR.fractionalBits * 2
                )
                output[targetY * targetWidth + targetX] = UInt16(
                    min(
                        Int64(maximumCode),
                        max(Int64(minimumCode), rounded)
                    )
                )
            }
        }
        return output
    }
}
