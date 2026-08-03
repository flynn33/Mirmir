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
            let prepared = try metal.prepare(
                sourceRowStride: stride,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 0,
                maximumCode: item.maximum
            )
            let preparedGPU = try await prepared.execute(source: source)
            let gpu = try await metal.execute(
                source: source,
                sourceRowStride: stride,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 0,
                maximumCode: item.maximum
            )
            XCTAssertEqual(preparedGPU, cpu, "prepared case=\(caseIndex)")
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
        let prepared = try metal.prepare(
            sourceRowStride: 11,
            scalePlan: plan,
            kernelIR: ir,
            minimumCode: 0,
            maximumCode: 1_023
        )
        XCTAssertEqual(prepared.sourceSampleCount, 99)
        XCTAssertEqual(prepared.outputSampleCount, 323)
        XCTAssertEqual(prepared.reusableBufferCount, 7)
        let expected = try await prepared.execute(source: source)
        var directOutput = Array(repeating: UInt16(65_535), count: 326)
        try source.withUnsafeBufferPointer { sourceBuffer in
            try directOutput.withUnsafeMutableBufferPointer { destination in
                try prepared.execute(
                    source: sourceBuffer,
                    destination: destination
                )
            }
        }
        XCTAssertEqual(Array(directOutput.prefix(323)), expected)
        XCTAssertEqual(Array(directOutput.suffix(3)), [65_535, 65_535, 65_535])
        for _ in 0..<20 {
            let actual = try await prepared.execute(source: source)
            XCTAssertEqual(actual, expected)
        }
    }

    func testPreparedBatchSharesOneDispatchAndPreservesEveryPlane() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let metal = try FixedPointMetalExecutorV4()
        let dimensions = [
            (sourceWidth: 7, sourceHeight: 5, targetWidth: 13, targetHeight: 9),
            (sourceWidth: 4, sourceHeight: 3, targetWidth: 7, targetHeight: 5),
            (sourceWidth: 4, sourceHeight: 3, targetWidth: 7, targetHeight: 5)
        ]
        var sources: [[UInt16]] = []
        var expected: [[UInt16]] = []
        var executions: [FixedPointMetalPreparedExecutionV4] = []
        for (plane, item) in dimensions.enumerated() {
            let plan = try SpatialScalePlanV4(
                sourceWidth: item.sourceWidth,
                sourceHeight: item.sourceHeight,
                targetWidth: item.targetWidth,
                targetHeight: item.targetHeight,
                borderRule: plane.isMultiple(of: 2) ? .clamp : .reflect101
            )
            let ir = try FixedPointKernelIRV4(scalePlan: plan)
            let source = (0..<(item.sourceWidth * item.sourceHeight)).map {
                UInt16(($0 * 71 + plane * 113) % 1_024)
            }
            sources.append(source)
            expected.append(try FixedPointCPUExecutorV4.execute(
                source: source,
                sourceRowStride: item.sourceWidth,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 16,
                maximumCode: 940
            ))
            executions.append(try metal.prepare(
                sourceRowStride: item.sourceWidth,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 16,
                maximumCode: 940
            ))
        }
        let batch = try FixedPointMetalPreparedBatchV4(executions: executions)
        XCTAssertEqual(batch.executionCount, 3)
        XCTAssertEqual(batch.reusableBufferCount, 21)
        var output = expected.map {
            Array(repeating: UInt16(65_535), count: $0.count)
        }
        for _ in 0..<20 {
            try batch.execute(sources: sources, destinations: &output)
            XCTAssertEqual(output, expected)
        }
        XCTAssertThrowsError(try FixedPointMetalPreparedBatchV4(
            executions: [executions[0], executions[0]]
        )) { error in
            XCTAssertEqual(
                error as? FixedPointMetalExecutorV4Error,
                .duplicateBatchExecution
            )
        }
        var tooFewOutputs = Array(output.dropLast())
        XCTAssertThrowsError(try batch.execute(
            sources: sources,
            destinations: &tooFewOutputs
        ))

        let reversedBatch = try FixedPointMetalPreparedBatchV4(
            executions: Array(executions.reversed())
        )
        let stableSources = sources
        let stableExpected = expected
        let reversedSources = Array(stableSources.reversed())
        let reversedExpected = Array(stableExpected.reversed())
        async let forward = Self.execute(
            batch: batch,
            sources: stableSources,
            outputCounts: stableExpected.map(\.count)
        )
        async let reverse = Self.execute(
            batch: reversedBatch,
            sources: reversedSources,
            outputCounts: reversedExpected.map(\.count)
        )
        let (forwardOutput, reverseOutput) = try await (forward, reverse)
        XCTAssertEqual(forwardOutput, stableExpected)
        XCTAssertEqual(reverseOutput, reversedExpected)
    }

    func testPreparedMetalExecutionSerializesConcurrentSourceUpdates() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let metal = try FixedPointMetalExecutorV4()
        let plan = try SpatialScalePlanV4(
            sourceWidth: 13,
            sourceHeight: 7,
            targetWidth: 23,
            targetHeight: 15,
            borderRule: .reflect101
        )
        let ir = try FixedPointKernelIRV4(scalePlan: plan)
        let prepared = try metal.prepare(
            sourceRowStride: 16,
            scalePlan: plan,
            kernelIR: ir,
            minimumCode: 64,
            maximumCode: 940
        )
        var firstSource = Array(repeating: UInt16(65_535), count: 16 * 7)
        var secondSource = firstSource
        for y in 0..<7 {
            for x in 0..<13 {
                firstSource[y * 16 + x] = UInt16((x * 101 + y * 211) % 1_024)
                secondSource[y * 16 + x] = UInt16(
                    (1_023 - x * 47 - y * 71) & 1_023
                )
            }
        }
        let firstInput = firstSource
        let secondInput = secondSource
        let firstCPU = try FixedPointCPUExecutorV4.execute(
            source: firstInput,
            sourceRowStride: 16,
            scalePlan: plan,
            kernelIR: ir,
            minimumCode: 64,
            maximumCode: 940
        )
        let secondCPU = try FixedPointCPUExecutorV4.execute(
            source: secondInput,
            sourceRowStride: 16,
            scalePlan: plan,
            kernelIR: ir,
            minimumCode: 64,
            maximumCode: 940
        )
        async let firstGPU = prepared.execute(source: firstInput)
        async let secondGPU = prepared.execute(source: secondInput)
        let (first, second) = try await (firstGPU, secondGPU)
        XCTAssertEqual(first, firstCPU)
        XCTAssertEqual(second, secondCPU)
    }

    func testDirectTransferRejectsOverlappingStorageBeforeDispatch() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let metal = try FixedPointMetalExecutorV4()
        let plan = try SpatialScalePlanV4(
            sourceWidth: 2,
            sourceHeight: 2,
            targetWidth: 2,
            targetHeight: 2
        )
        let execution = try metal.prepare(
            sourceRowStride: 2,
            scalePlan: plan,
            kernelIR: FixedPointKernelIRV4(scalePlan: plan),
            minimumCode: 0,
            maximumCode: 255
        )
        let batch = try FixedPointMetalPreparedBatchV4(
            executions: [execution]
        )
        var storage = Array(repeating: UInt8(17), count: 4)
        try storage.withUnsafeMutableBytes { bytes in
            let base = try XCTUnwrap(bytes.baseAddress)
            let transfers = [FixedPointMetalComponentTransferV4(
                sourceBaseAddress: UnsafeRawPointer(base),
                sourceRowBytes: 2,
                destinationBaseAddress: base,
                destinationRowBytes: 2,
                bytesPerComponent: 1,
                componentsPerElement: 1,
                componentIndex: 0,
                storedCodeShift: 0
            )]
            XCTAssertThrowsError(try transfers.withUnsafeBufferPointer {
                try batch.execute(transfers: $0)
            }) { error in
                XCTAssertEqual(
                    error as? FixedPointKernelV4Error,
                    .overlappingSourceAndDestination
                )
            }
        }
    }

    func testBatchValidatesEveryTransferBeforeChangingRetainedInputs() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host.")
        }
        let metal = try FixedPointMetalExecutorV4()
        let plan = try SpatialScalePlanV4(
            sourceWidth: 2,
            sourceHeight: 2,
            targetWidth: 2,
            targetHeight: 2
        )
        let ir = try FixedPointKernelIRV4(scalePlan: plan)
        let executions = try (0..<2).map { _ in
            try metal.prepare(
                sourceRowStride: 2,
                scalePlan: plan,
                kernelIR: ir,
                minimumCode: 0,
                maximumCode: 255
            )
        }
        let batch = try FixedPointMetalPreparedBatchV4(
            executions: executions
        )

        var seededSource0 = [UInt8](repeating: 11, count: 4)
        var seededSource1 = [UInt8](repeating: 22, count: 4)
        var seededDestination0 = [UInt8](repeating: 0, count: 4)
        var seededDestination1 = [UInt8](repeating: 0, count: 4)
        try withTransfers(
            source0: &seededSource0,
            source1: &seededSource1,
            destination0: &seededDestination0,
            destination1: &seededDestination1,
            secondSourceRowBytes: 2
        ) { transfers in
            try batch.execute(transfers: transfers)
        }
        let before = executions.map {
            $0.retainedSourceBytesForQualification()
        }

        var attemptedSource0 = [UInt8](repeating: 99, count: 4)
        var attemptedSource1 = [UInt8](repeating: 77, count: 4)
        var attemptedDestination0 = [UInt8](repeating: 0xA5, count: 4)
        var attemptedDestination1 = [UInt8](repeating: 0xA5, count: 4)
        XCTAssertThrowsError(try withTransfers(
            source0: &attemptedSource0,
            source1: &attemptedSource1,
            destination0: &attemptedDestination0,
            destination1: &attemptedDestination1,
            secondSourceRowBytes: 1
        ) { transfers in
            try batch.execute(transfers: transfers)
        }) { error in
            XCTAssertEqual(
                error as? FixedPointMetalExecutorV4Error,
                .invalidComponentTransfer
            )
        }
        XCTAssertEqual(
            executions.map { $0.retainedSourceBytesForQualification() },
            before
        )
        XCTAssertEqual(
            attemptedDestination0,
            [UInt8](repeating: 0xA5, count: 4)
        )
        XCTAssertEqual(
            attemptedDestination1,
            [UInt8](repeating: 0xA5, count: 4)
        )
    }

    private func withTransfers<T>(
        source0: inout [UInt8],
        source1: inout [UInt8],
        destination0: inout [UInt8],
        destination1: inout [UInt8],
        secondSourceRowBytes: Int,
        operation: (UnsafeBufferPointer<FixedPointMetalComponentTransferV4>)
            throws -> T
    ) throws -> T {
        try source0.withUnsafeBytes { source0Bytes in
            try source1.withUnsafeBytes { source1Bytes in
                try destination0.withUnsafeMutableBytes { destination0Bytes in
                    try destination1.withUnsafeMutableBytes { destination1Bytes in
                        let transfers = [
                            FixedPointMetalComponentTransferV4(
                                sourceBaseAddress: try XCTUnwrap(
                                    source0Bytes.baseAddress
                                ),
                                sourceRowBytes: 2,
                                destinationBaseAddress: try XCTUnwrap(
                                    destination0Bytes.baseAddress
                                ),
                                destinationRowBytes: 2,
                                bytesPerComponent: 1,
                                componentsPerElement: 1,
                                componentIndex: 0,
                                storedCodeShift: 0
                            ),
                            FixedPointMetalComponentTransferV4(
                                sourceBaseAddress: try XCTUnwrap(
                                    source1Bytes.baseAddress
                                ),
                                sourceRowBytes: secondSourceRowBytes,
                                destinationBaseAddress: try XCTUnwrap(
                                    destination1Bytes.baseAddress
                                ),
                                destinationRowBytes: 2,
                                bytesPerComponent: 1,
                                componentsPerElement: 1,
                                componentIndex: 0,
                                storedCodeShift: 0
                            )
                        ]
                        return try transfers.withUnsafeBufferPointer(operation)
                    }
                }
            }
        }
    }

    private static func execute(
        batch: FixedPointMetalPreparedBatchV4,
        sources: [[UInt16]],
        outputCounts: [Int]
    ) throws -> [[UInt16]] {
        var output = outputCounts.map {
            Array(repeating: UInt16(0), count: $0)
        }
        try batch.execute(sources: sources, destinations: &output)
        return output
    }
}
