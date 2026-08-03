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
        // Run the platform-independent validator before allocating GPU state.
        guard minimumCode <= maximumCode else {
            throw FixedPointKernelV4Error.invalidCodeBounds(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        let (requiredSourceCount, sourceCountOverflow) = sourceRowStride
            .multipliedReportingOverflow(by: scalePlan.sourceHeight)
        guard sourceRowStride >= scalePlan.sourceWidth,
              !sourceCountOverflow,
              source.count >= requiredSourceCount else {
            throw FixedPointKernelV4Error.invalidSourceLayout(
                width: scalePlan.sourceWidth,
                height: scalePlan.sourceHeight,
                rowStride: sourceRowStride,
                sampleCount: source.count
            )
        }
        try kernelIR.validate(scalePlan: scalePlan)

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
        let (outputCount, outputCountOverflow) = scalePlan.targetWidth
            .multipliedReportingOverflow(by: scalePlan.targetHeight)
        let (outputByteCount, outputByteCountOverflow) = outputCount
            .multipliedReportingOverflow(by: MemoryLayout<UInt16>.stride)
        guard !outputCountOverflow, !outputByteCountOverflow else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }

        let sourceBuffer = try makeBuffer(
            values: source,
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
        guard let outputBuffer = device.makeBuffer(
            length: outputByteCount,
            options: .storageModeShared
        ) else {
            throw FixedPointMetalExecutorV4Error.bufferAllocationFailed(
                label: "v4 output",
                byteCount: outputByteCount
            )
        }
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

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw FixedPointMetalExecutorV4Error.commandBufferUnavailable
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw FixedPointMetalExecutorV4Error.commandEncoderUnavailable
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
        encoder.setBuffer(horizontalPositionBuffer, offset: 0, index: 1)
        encoder.setBuffer(verticalPositionBuffer, offset: 0, index: 2)
        encoder.setBuffer(horizontalCoefficientBuffer, offset: 0, index: 3)
        encoder.setBuffer(verticalCoefficientBuffer, offset: 0, index: 4)
        encoder.setBuffer(outputBuffer, offset: 0, index: 5)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 6)
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
        encoder.dispatchThreads(
            MTLSize(
                width: scalePlan.targetWidth,
                height: scalePlan.targetHeight,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(
                width: executionWidth,
                height: executionHeight,
                depth: 1
            )
        )
        encoder.endEncoding()
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }
        guard commandBuffer.status == .completed else {
            throw FixedPointMetalExecutorV4Error.commandFailed(
                commandBuffer.error.map(String.init(describing:))
                    ?? "Metal command ended with status \(commandBuffer.status.rawValue)."
            )
        }

        let pointer = outputBuffer.contents().bindMemory(
            to: UInt16.self,
            capacity: outputCount
        )
        return Array(UnsafeBufferPointer(start: pointer, count: outputCount))
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
}
