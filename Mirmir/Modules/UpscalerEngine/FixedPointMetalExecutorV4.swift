import Foundation
import Metal

enum FixedPointMetalExecutorV4Error: Error, Equatable, Sendable {
    case metalUnavailable
    case defaultLibraryUnavailable
    case functionUnavailable(String)
    case pipelineCreationFailed(String)
    case bufferAllocationFailed(label: String, byteCount: Int)
    case commandQueueUnavailable
    case commandBufferUnavailable
    case commandEncoderUnavailable
    case commandFailed(String)
    case planExceedsMetalRepresentation
    case invalidBatchLayout(expected: Int, actual: Int)
    case duplicateBatchExecution
    case incompatibleBatchDevice
}

/// Serialized reusable Metal state for one validated scale/stride/range.
/// Immutable plan buffers plus source/output storage survive across frames;
/// only source bytes and command objects change per execution.
final class FixedPointMetalPreparedExecutionV4: @unchecked Sendable {
    let sourceSampleCount: Int
    let outputSampleCount: Int
    let reusableBufferCount = 7

    fileprivate let lock = NSLock()
    private let sourceWidth: Int
    private let sourceHeight: Int
    private let sourceRowStride: Int
    private let targetWidth: Int
    private let targetHeight: Int
    private let sourceByteCount: Int
    private let outputByteCount: Int
    fileprivate let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let sourceBuffer: MTLBuffer
    private let horizontalPositionBuffer: MTLBuffer
    private let verticalPositionBuffer: MTLBuffer
    private let horizontalCoefficientBuffer: MTLBuffer
    private let verticalCoefficientBuffer: MTLBuffer
    private let outputBuffer: MTLBuffer
    private let uniformBuffer: MTLBuffer
    private let threadsPerThreadgroup: MTLSize

    fileprivate init(
        sourceWidth: Int,
        sourceHeight: Int,
        sourceRowStride: Int,
        targetWidth: Int,
        targetHeight: Int,
        sourceSampleCount: Int,
        outputSampleCount: Int,
        sourceByteCount: Int,
        outputByteCount: Int,
        commandQueue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        sourceBuffer: MTLBuffer,
        horizontalPositionBuffer: MTLBuffer,
        verticalPositionBuffer: MTLBuffer,
        horizontalCoefficientBuffer: MTLBuffer,
        verticalCoefficientBuffer: MTLBuffer,
        outputBuffer: MTLBuffer,
        uniformBuffer: MTLBuffer,
        threadsPerThreadgroup: MTLSize
    ) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceRowStride = sourceRowStride
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.sourceSampleCount = sourceSampleCount
        self.outputSampleCount = outputSampleCount
        self.sourceByteCount = sourceByteCount
        self.outputByteCount = outputByteCount
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.sourceBuffer = sourceBuffer
        self.horizontalPositionBuffer = horizontalPositionBuffer
        self.verticalPositionBuffer = verticalPositionBuffer
        self.horizontalCoefficientBuffer = horizontalCoefficientBuffer
        self.verticalCoefficientBuffer = verticalCoefficientBuffer
        self.outputBuffer = outputBuffer
        self.uniformBuffer = uniformBuffer
        self.threadsPerThreadgroup = threadsPerThreadgroup
    }

    func execute(source: [UInt16]) async throws -> [UInt16] {
        var output = Array(repeating: UInt16(0), count: outputSampleCount)
        try source.withUnsafeBufferPointer { sourceBuffer in
            try output.withUnsafeMutableBufferPointer { destination in
                try execute(
                    source: sourceBuffer,
                    destination: destination
                )
            }
        }
        return output
    }

    func execute(
        source: UnsafeBufferPointer<UInt16>,
        destination: UnsafeMutableBufferPointer<UInt16>
    ) throws {
        try validate(
            sourceCount: source.count,
            destinationCount: destination.count
        )
        try lock.withLock {
            upload(source: source)
            let commandBuffer = try makeCommandBuffer()
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw FixedPointMetalExecutorV4Error.commandEncoderUnavailable
            }
            encode(into: encoder)
            encoder.endEncoding()
            try commitAndWait(commandBuffer)
            download(to: destination)
        }
    }

    fileprivate func validate(
        sourceCount: Int,
        destinationCount: Int
    ) throws {
        guard sourceCount >= sourceSampleCount else {
            throw FixedPointKernelV4Error.invalidSourceLayout(
                width: sourceWidth,
                height: sourceHeight,
                rowStride: sourceRowStride,
                sampleCount: sourceCount
            )
        }
        guard destinationCount >= outputSampleCount else {
            throw FixedPointKernelV4Error.invalidDestinationLayout(
                expectedCount: outputSampleCount,
                actualCount: destinationCount
            )
        }
    }

    fileprivate func upload(source: UnsafeBufferPointer<UInt16>) {
        source.withMemoryRebound(to: UInt8.self) { bytes in
            precondition(bytes.count >= sourceByteCount)
            _ = memcpy(
                sourceBuffer.contents(),
                bytes.baseAddress!,
                sourceByteCount
            )
        }
    }

    fileprivate func encode(into encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
        encoder.setBuffer(horizontalPositionBuffer, offset: 0, index: 1)
        encoder.setBuffer(verticalPositionBuffer, offset: 0, index: 2)
        encoder.setBuffer(horizontalCoefficientBuffer, offset: 0, index: 3)
        encoder.setBuffer(verticalCoefficientBuffer, offset: 0, index: 4)
        encoder.setBuffer(outputBuffer, offset: 0, index: 5)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 6)
        encoder.dispatchThreads(
            MTLSize(width: targetWidth, height: targetHeight, depth: 1),
            threadsPerThreadgroup: threadsPerThreadgroup
        )
    }

    fileprivate func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw FixedPointMetalExecutorV4Error.commandBufferUnavailable
        }
        return commandBuffer
    }

    fileprivate func commitAndWait(_ commandBuffer: MTLCommandBuffer) throws {
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw FixedPointMetalExecutorV4Error.commandFailed(
                commandBuffer.error.map(String.init(describing:))
                    ?? "Metal command ended with status \(commandBuffer.status.rawValue)."
            )
        }
    }

    fileprivate func download(
        to destination: UnsafeMutableBufferPointer<UInt16>
    ) {
        _ = memcpy(
            destination.baseAddress!,
            outputBuffer.contents(),
            outputByteCount
        )
    }
}

/// A prepared group shares one command buffer and one completion wait across
/// multiple planes. Source/output arrays and all seven buffers per plane are
/// caller-owned or retained, so repeated frame dispatches do not allocate.
final class FixedPointMetalPreparedBatchV4: @unchecked Sendable {
    // Separate batches may contain overlapping executions in different plane
    // orders. One process-wide acquisition gate prevents cross-batch lock-order
    // inversion while individual single-plane calls still synchronize narrowly.
    private static let executionAcquisitionLock = NSLock()

    let executionCount: Int
    let reusableBufferCount: Int

    private let executions: [FixedPointMetalPreparedExecutionV4]

    init(executions: [FixedPointMetalPreparedExecutionV4]) throws {
        guard !executions.isEmpty else {
            throw FixedPointMetalExecutorV4Error.invalidBatchLayout(
                expected: 1,
                actual: 0
            )
        }
        guard Set(executions.map(ObjectIdentifier.init)).count
                == executions.count else {
            throw FixedPointMetalExecutorV4Error.duplicateBatchExecution
        }
        let device = ObjectIdentifier(
            executions[0].commandQueue.device as AnyObject
        )
        guard executions.dropFirst().allSatisfy({
            ObjectIdentifier($0.commandQueue.device as AnyObject) == device
        }) else {
            throw FixedPointMetalExecutorV4Error.incompatibleBatchDevice
        }
        self.executions = executions
        self.executionCount = executions.count
        self.reusableBufferCount = executions.reduce(0) {
            $0 + $1.reusableBufferCount
        }
    }

    func execute(
        sources: [[UInt16]],
        destinations: inout [[UInt16]]
    ) throws {
        guard sources.count == executions.count else {
            throw FixedPointMetalExecutorV4Error.invalidBatchLayout(
                expected: executions.count,
                actual: sources.count
            )
        }
        guard destinations.count == executions.count else {
            throw FixedPointMetalExecutorV4Error.invalidBatchLayout(
                expected: executions.count,
                actual: destinations.count
            )
        }
        try Self.executionAcquisitionLock.withLock {
            try withExecutionLocks(at: 0) {
                for index in executions.indices {
                    try executions[index].validate(
                        sourceCount: sources[index].count,
                        destinationCount: destinations[index].count
                    )
                    sources[index].withUnsafeBufferPointer {
                        executions[index].upload(source: $0)
                    }
                }
                let commandBuffer = try executions[0].makeCommandBuffer()
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw FixedPointMetalExecutorV4Error.commandEncoderUnavailable
                }
                for execution in executions {
                    execution.encode(into: encoder)
                }
                encoder.endEncoding()
                try executions[0].commitAndWait(commandBuffer)
                for index in executions.indices {
                    destinations[index].withUnsafeMutableBufferPointer {
                        executions[index].download(to: $0)
                    }
                }
            }
        }
    }

    private func withExecutionLocks<T>(
        at index: Int,
        _ operation: () throws -> T
    ) rethrows -> T {
        guard index < executions.count else {
            return try operation()
        }
        return try executions[index].lock.withLock {
            try withExecutionLocks(at: index + 1, operation)
        }
    }
}

/// Metal executor for the exact same Q14 IR consumed by
/// `FixedPointCPUExecutorV4`. Coefficients and source coordinates are uploaded
/// from the canonical plan; the shader does not derive phases or policy.
final class FixedPointMetalExecutorV4: @unchecked Sendable {
    private struct Position {
        let sourceBase: Int32
        let kernelIndex: UInt32
    }

    private struct Uniforms {
        let sourceWidth: UInt32
        let sourceHeight: UInt32
        let sourceRowStride: UInt32
        let targetWidth: UInt32
        let targetHeight: UInt32
        let horizontalKernelCount: UInt32
        let verticalKernelCount: UInt32
        let horizontalBorderRule: UInt32
        let verticalBorderRule: UInt32
        let minimumCode: UInt32
        let maximumCode: UInt32
        let fractionalBits: UInt32
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FixedPointMetalExecutorV4Error.metalUnavailable
        }
        try self.init(device: device)
    }

    init(device: MTLDevice, library: MTLLibrary? = nil) throws {
        guard MemoryLayout<Position>.stride == 8,
              MemoryLayout<Uniforms>.stride == 48 else {
            throw FixedPointMetalExecutorV4Error.planExceedsMetalRepresentation
        }
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw FixedPointMetalExecutorV4Error.commandQueueUnavailable
        }
        let resolvedLibrary: MTLLibrary
        if let library {
            resolvedLibrary = library
        } else {
            guard let defaultLibrary = device.makeDefaultLibrary() else {
                throw FixedPointMetalExecutorV4Error.defaultLibraryUnavailable
            }
            resolvedLibrary = defaultLibrary
        }
        let functionName = "ashFixedPointScaleV4"
        guard let function = resolvedLibrary.makeFunction(name: functionName) else {
            throw FixedPointMetalExecutorV4Error.functionUnavailable(functionName)
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw FixedPointMetalExecutorV4Error.pipelineCreationFailed(
                String(describing: error)
            )
        }
        self.commandQueue = commandQueue
    }

    func execute(
        source: [UInt16],
        sourceRowStride: Int,
        scalePlan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4,
        minimumCode: UInt16,
        maximumCode: UInt16
    ) async throws -> [UInt16] {
        let prepared = try prepare(
            sourceRowStride: sourceRowStride,
            scalePlan: scalePlan,
            kernelIR: kernelIR,
            minimumCode: minimumCode,
            maximumCode: maximumCode
        )
        return try await prepared.execute(source: source)
    }

    func prepare(
        sourceRowStride: Int,
        scalePlan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4,
        minimumCode: UInt16,
        maximumCode: UInt16
    ) throws -> FixedPointMetalPreparedExecutionV4 {
        guard minimumCode <= maximumCode else {
            throw FixedPointKernelV4Error.invalidCodeBounds(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        let preparedScale = try FixedPointPreparedScaleV4(
            scalePlan: scalePlan,
            kernelIR: kernelIR
        )
        let (sourceSampleCount, sourceCountOverflow) = sourceRowStride
            .multipliedReportingOverflow(by: scalePlan.sourceHeight)
        guard sourceRowStride >= scalePlan.sourceWidth,
              !sourceCountOverflow else {
            throw FixedPointKernelV4Error.invalidSourceLayout(
                width: scalePlan.sourceWidth,
                height: scalePlan.sourceHeight,
                rowStride: sourceRowStride,
                sampleCount: 0
            )
        }
        let horizontalPositions = try makePositions(
            scalePlan.horizontal.positions,
            kernelIndices: kernelIR.horizontalKernelIndexByDestination
        )
        let verticalPositions = try makePositions(
            scalePlan.vertical.positions,
            kernelIndices: kernelIR.verticalKernelIndexByDestination
        )
        let horizontalCoefficients = kernelIR.horizontalKernels.flatMap(
            \.coefficients
        )
        let verticalCoefficients = kernelIR.verticalKernels.flatMap(
            \.coefficients
        )
        let uniforms = try makeUniforms(
            sourceRowStride: sourceRowStride,
            scalePlan: scalePlan,
            kernelIR: kernelIR,
            minimumCode: minimumCode,
            maximumCode: maximumCode
        )
        let (sourceByteCount, sourceByteCountOverflow) = sourceSampleCount
            .multipliedReportingOverflow(by: MemoryLayout<UInt16>.stride)
        let (outputByteCount, outputByteCountOverflow) = preparedScale
            .outputSampleCount
            .multipliedReportingOverflow(by: MemoryLayout<UInt16>.stride)
        guard !sourceByteCountOverflow, !outputByteCountOverflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
        let sourceBuffer = try makeEmptyBuffer(
            byteCount: sourceByteCount,
            label: "v4 source"
        )
        let horizontalPositionBuffer = try makeBuffer(
            values: horizontalPositions,
            label: "v4 horizontal positions"
        )
        let verticalPositionBuffer = try makeBuffer(
            values: verticalPositions,
            label: "v4 vertical positions"
        )
        let horizontalCoefficientBuffer = try makeBuffer(
            values: horizontalCoefficients,
            label: "v4 horizontal coefficients"
        )
        let verticalCoefficientBuffer = try makeBuffer(
            values: verticalCoefficients,
            label: "v4 vertical coefficients"
        )
        let outputBuffer = try makeEmptyBuffer(
            byteCount: outputByteCount,
            label: "v4 output"
        )
        var mutableUniforms = uniforms
        guard let uniformBuffer = withUnsafeBytes(of: &mutableUniforms, {
            bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            )
        }) else {
            throw FixedPointMetalExecutorV4Error.bufferAllocationFailed(
                label: "v4 uniforms",
                byteCount: MemoryLayout<Uniforms>.stride
            )
        }
        let executionWidth = max(
            1,
            min(pipeline.threadExecutionWidth, scalePlan.targetWidth)
        )
        let executionHeight = max(
            1,
            min(
                pipeline.maxTotalThreadsPerThreadgroup / executionWidth,
                scalePlan.targetHeight
            )
        )
        return FixedPointMetalPreparedExecutionV4(
            sourceWidth: scalePlan.sourceWidth,
            sourceHeight: scalePlan.sourceHeight,
            sourceRowStride: sourceRowStride,
            targetWidth: scalePlan.targetWidth,
            targetHeight: scalePlan.targetHeight,
            sourceSampleCount: sourceSampleCount,
            outputSampleCount: preparedScale.outputSampleCount,
            sourceByteCount: sourceByteCount,
            outputByteCount: outputByteCount,
            commandQueue: commandQueue,
            pipeline: pipeline,
            sourceBuffer: sourceBuffer,
            horizontalPositionBuffer: horizontalPositionBuffer,
            verticalPositionBuffer: verticalPositionBuffer,
            horizontalCoefficientBuffer: horizontalCoefficientBuffer,
            verticalCoefficientBuffer: verticalCoefficientBuffer,
            outputBuffer: outputBuffer,
            uniformBuffer: uniformBuffer,
            threadsPerThreadgroup: MTLSize(
                width: executionWidth,
                height: executionHeight,
                depth: 1
            )
        )
    }

    private func makePositions(
        _ positions: [SpatialSamplePositionV4],
        kernelIndices: [Int]
    ) throws -> [Position] {
        guard positions.count == kernelIndices.count else {
            throw FixedPointMetalExecutorV4Error.planExceedsMetalRepresentation
        }
        return try zip(positions, kernelIndices).map { position, kernelIndex in
            guard let sourceBase = Int32(exactly: position.sourceBase),
                  let index = UInt32(exactly: kernelIndex) else {
                throw FixedPointMetalExecutorV4Error
                    .planExceedsMetalRepresentation
            }
            return Position(sourceBase: sourceBase, kernelIndex: index)
        }
    }

    private func makeUniforms(
        sourceRowStride: Int,
        scalePlan: SpatialScalePlanV4,
        kernelIR: FixedPointKernelIRV4,
        minimumCode: UInt16,
        maximumCode: UInt16
    ) throws -> Uniforms {
        guard let sourceWidth = UInt32(exactly: scalePlan.sourceWidth),
              let sourceHeight = UInt32(exactly: scalePlan.sourceHeight),
              let sourceStride = UInt32(exactly: sourceRowStride),
              let targetWidth = UInt32(exactly: scalePlan.targetWidth),
              let targetHeight = UInt32(exactly: scalePlan.targetHeight),
              let horizontalCount = UInt32(
                exactly: kernelIR.horizontalKernels.count
              ),
              let verticalCount = UInt32(
                exactly: kernelIR.verticalKernels.count
              ),
              let fractionalBits = UInt32(exactly: kernelIR.fractionalBits)
        else {
            throw FixedPointMetalExecutorV4Error.planExceedsMetalRepresentation
        }
        return Uniforms(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceRowStride: sourceStride,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            horizontalKernelCount: horizontalCount,
            verticalKernelCount: verticalCount,
            horizontalBorderRule: scalePlan.horizontal.borderRule == .clamp
                ? 0 : 1,
            verticalBorderRule: scalePlan.vertical.borderRule == .clamp ? 0 : 1,
            minimumCode: UInt32(minimumCode),
            maximumCode: UInt32(maximumCode),
            fractionalBits: fractionalBits
        )
    }

    private func makeBuffer<Element>(
        values: [Element],
        label: String
    ) throws -> MTLBuffer {
        let (byteCount, overflow) = values.count.multipliedReportingOverflow(
            by: MemoryLayout<Element>.stride
        )
        guard !overflow, byteCount > 0 else {
            throw FixedPointMetalExecutorV4Error.bufferAllocationFailed(
                label: label,
                byteCount: byteCount
            )
        }
        let buffer = values.withUnsafeBytes { bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: byteCount,
                options: .storageModeShared
            )
        }
        guard let buffer else {
            throw FixedPointMetalExecutorV4Error.bufferAllocationFailed(
                label: label,
                byteCount: byteCount
            )
        }
        buffer.label = label
        return buffer
    }

    private func makeEmptyBuffer(
        byteCount: Int,
        label: String
    ) throws -> MTLBuffer {
        guard byteCount > 0,
              let buffer = device.makeBuffer(
                  length: byteCount,
                  options: .storageModeShared
              ) else {
            throw FixedPointMetalExecutorV4Error.bufferAllocationFailed(
                label: label,
                byteCount: byteCount
            )
        }
        buffer.label = label
        return buffer
    }
}
