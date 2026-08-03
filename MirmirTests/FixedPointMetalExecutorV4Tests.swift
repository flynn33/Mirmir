import Metal
import XCTest
@testable import Mirmir

final class FixedPointMetalExecutorV4Tests: XCTestCase {
    func testCPUAndMetalAreByteIdenticalAcrossArbitraryScaleMatrix() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let metal = try FixedPointMetalExecutorV4()
        let cases: [(
            sourceWidth: Int,
            sourceHeight: Int,
            targetWidth: Int,
            targetHeight: Int,
            stridePadding: Int,
            maximum: UInt16,
            border: SpatialBorderRuleV4
        )] = [
            (1, 1, 3, 5, 2, 255, .clamp),
            (3, 2, 5, 3, 3, 255, .reflect101),
            (5, 3, 8, 7, 1, 940, .clamp),
            (7, 5, 13, 8, 5, 1_023, .reflect101),
            (8, 6, 12, 9, 4, 1_023, .clamp),
            (9, 7, 18, 14, 7, 65_535, .reflect101)
        ]

        for (caseIndex, item) in cases.enumerated() {
            let stride = item.sourceWidth + item.stridePadding
            var source = Array(
                repeating: UInt16(0),
                count: stride * item.sourceHeight
            )
            for y in 0..<item.sourceHeight {
                for x in 0..<item.sourceWidth {
                    source[y * stride + x] = UInt16(
                        (x * 97 + y * 193 + caseIndex * 41)
                            % (Int(item.maximum) + 1)
                    )
                }
                for x in item.sourceWidth..<stride {
                    source[y * stride + x] = item.maximum
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
            let cpu = try FixedPointCPUExecutorV4.execute(
                source: source,
                sourceRowStride: stride,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 0,
                maximumCode: item.maximum
            )
            let gpu = try await metal.execute(
                source: source,
                sourceRowStride: stride,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 0,
                maximumCode: item.maximum
            )
            XCTAssertEqual(gpu, cpu, "case=\(caseIndex)")
        }
    }

    func testMetalOutputIsRepeatableAcrossDispatches() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let metal = try FixedPointMetalExecutorV4()
        let plan = try SpatialScalePlanV4(
            sourceWidth: 11,
            sourceHeight: 9,
            targetWidth: 19,
            targetHeight: 17
        )
        let ir = try FixedPointKernelIRV4(scalePlan: plan)
        var source: [UInt16] = []
        source.reserveCapacity(11 * 9)
        for index in 0..<(11 * 9) {
            let value = (index * 37 + 11) % 1_024
            source.append(UInt16(value))
        }
        let expected = try await metal.execute(
            source: source,
            sourceRowStride: 11,
            scalePlan: plan,
            kernelIR: ir,
            minimumCode: 0,
            maximumCode: 1_023
        )
        for _ in 0..<20 {
            let actual = try await metal.execute(
                source: source,
                sourceRowStride: 11,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 0,
                maximumCode: 1_023
            )
            XCTAssertEqual(actual, expected)
        }
    }
}
