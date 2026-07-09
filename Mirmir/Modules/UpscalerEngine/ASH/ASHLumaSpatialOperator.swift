import Foundation
import Metal

enum ASHLumaSpatialOperator {
    static func applyCPU(
        source: ASHImage,
        message: ASHMessage,
        scale: Int = ASHReconstruction.defaultScale,
        strength: Double = ASHReconstruction.defaultOperatorStrength
    ) throws -> ASHImage {
        guard source.channels == 1 else { throw ASHCoreError.invalidImageShape }
        guard scale > 0 else { throw ASHCoreError.invalidScale(scale) }

        let outputWidth = source.width * scale
        let outputHeight = source.height * scale
        var result = Array(repeating: 0.0, count: outputWidth * outputHeight)

        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                let center = baseline(source: source, scale: scale, row: row, column: column)
                let horizontalBlur = (
                    baseline(source: source, scale: scale, row: row, column: max(column - 1, 0))
                        + (2.0 * center)
                        + baseline(source: source, scale: scale, row: row, column: min(column + 1, outputWidth - 1))
                ) / 4.0
                let verticalBlur = verticalBlurValue(
                    source: source,
                    scale: scale,
                    outputHeight: outputHeight,
                    row: row,
                    column: column
                )
                let isotropicBlur = (
                    verticalBlurValue(
                        source: source,
                        scale: scale,
                        outputHeight: outputHeight,
                        row: row,
                        column: max(column - 1, 0)
                    )
                        + (2.0 * verticalBlur)
                        + verticalBlurValue(
                            source: source,
                            scale: scale,
                            outputHeight: outputHeight,
                            row: row,
                            column: min(column + 1, outputWidth - 1)
                        )
                ) / 4.0

                var value = center
                if message.bits[0] == 1 {
                    value += strength * (center - horizontalBlur)
                }
                if message.bits[1] == 1 {
                    value += strength * (center - verticalBlur)
                }
                if message.bits[2] == 1 {
                    value += strength * (center - isotropicBlur)
                }
                if message.bits[3] == 1 {
                    value -= strength * (center - isotropicBlur)
                }
                result[(row * outputWidth) + column] = min(1.0, max(0.0, value))
            }
        }

        return try ASHImage(width: outputWidth, height: outputHeight, channels: 1, values: result)
    }

    private static func baseline(source: ASHImage, scale: Int, row: Int, column: Int) -> Double {
        source.value(row: min(source.height - 1, row / scale), column: min(source.width - 1, column / scale))
    }

    private static func verticalBlurValue(
        source: ASHImage,
        scale: Int,
        outputHeight: Int,
        row: Int,
        column: Int
    ) -> Double {
        (
            baseline(source: source, scale: scale, row: max(row - 1, 0), column: column)
                + (2.0 * baseline(source: source, scale: scale, row: row, column: column))
                + baseline(source: source, scale: scale, row: min(row + 1, outputHeight - 1), column: column)
        ) / 4.0
    }
}

struct ASHMetalLumaSpatialOperator {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState

    init(device: MTLDevice) throws {
        self.device = device
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let function = library.makeFunction(name: "ash_luma_spatial_operator") else {
            throw ASHAssetValidationError.invalidCSV("metal shader")
        }
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    func apply(
        source: ASHImage,
        message: ASHMessage,
        scale: Int = ASHReconstruction.defaultScale,
        strength: Double = ASHReconstruction.defaultOperatorStrength
    ) throws -> ASHImage {
        guard source.channels == 1 else { throw ASHCoreError.invalidImageShape }
        guard scale > 0 else { throw ASHCoreError.invalidScale(scale) }
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw UpscalerEngineError.strategyFailed("ASH Metal luma operator could not create command encoder")
        }

        let input = source.values.map(Float.init)
        let outputCount = source.width * scale * source.height * scale
        let parameters = [
            Int32(source.width),
            Int32(source.height),
            Int32(scale)
        ] + message.bits.map(Int32.init)
        var strengthValue = Float(strength)

        let inputBuffer = input.withUnsafeBytes { bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: [.storageModeShared]
            )
        }
        let parametersBuffer = parameters.withUnsafeBytes { bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: [.storageModeShared]
            )
        }
        let strengthBuffer = withUnsafeBytes(of: &strengthValue) { bytes in
            device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: [.storageModeShared]
            )
        }

        guard let inputBuffer,
              let outputBuffer = device.makeBuffer(
                  length: MemoryLayout<Float>.stride * outputCount,
                  options: [.storageModeShared]
              ),
              let parametersBuffer,
              let strengthBuffer else {
            throw UpscalerEngineError.strategyFailed("ASH Metal luma operator could not allocate buffers")
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBuffer(parametersBuffer, offset: 0, index: 2)
        encoder.setBuffer(strengthBuffer, offset: 0, index: 3)

        let outputWidth = source.width * scale
        let outputHeight = source.height * scale
        let threadWidth = min(pipeline.threadExecutionWidth, outputWidth)
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, outputHeight))
        encoder.dispatchThreads(
            MTLSize(width: outputWidth, height: outputHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw UpscalerEngineError.strategyFailed("ASH Metal luma operator failed: \(error.localizedDescription)")
        }

        let outputPointer = outputBuffer.contents().assumingMemoryBound(to: Float.self)
        let values = (0..<outputCount).map { Double(outputPointer[$0]) }
        return try ASHImage(
            width: outputWidth,
            height: outputHeight,
            channels: 1,
            values: values
        )
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    inline float ash_baseline(
        device const float *source,
        int width,
        int height,
        int scale,
        int outX,
        int outY
    ) {
        int sourceX = clamp(outX / scale, 0, width - 1);
        int sourceY = clamp(outY / scale, 0, height - 1);
        return source[(sourceY * width) + sourceX];
    }

    inline float ash_vertical_blur(
        device const float *source,
        int width,
        int height,
        int scale,
        int outputHeight,
        int outX,
        int outY
    ) {
        float before = ash_baseline(source, width, height, scale, outX, max(outY - 1, 0));
        float center = ash_baseline(source, width, height, scale, outX, outY);
        float after = ash_baseline(source, width, height, scale, outX, min(outY + 1, outputHeight - 1));
        return (before + (2.0 * center) + after) / 4.0;
    }

    kernel void ash_luma_spatial_operator(
        device const float *source [[buffer(0)]],
        device float *output [[buffer(1)]],
        constant int *parameters [[buffer(2)]],
        constant float &strength [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        int width = parameters[0];
        int height = parameters[1];
        int scale = parameters[2];
        int outputWidth = width * scale;
        int outputHeight = height * scale;
        int x = int(gid.x);
        int y = int(gid.y);
        if (x >= outputWidth || y >= outputHeight) {
            return;
        }

        float center = ash_baseline(source, width, height, scale, x, y);
        float horizontalBlur = (
            ash_baseline(source, width, height, scale, max(x - 1, 0), y)
                + (2.0 * center)
                + ash_baseline(source, width, height, scale, min(x + 1, outputWidth - 1), y)
        ) / 4.0;
        float verticalBlur = ash_vertical_blur(source, width, height, scale, outputHeight, x, y);
        float isotropicBlur = (
            ash_vertical_blur(source, width, height, scale, outputHeight, max(x - 1, 0), y)
                + (2.0 * verticalBlur)
                + ash_vertical_blur(source, width, height, scale, outputHeight, min(x + 1, outputWidth - 1), y)
        ) / 4.0;

        float value = center;
        if (parameters[3] == 1) {
            value += strength * (center - horizontalBlur);
        }
        if (parameters[4] == 1) {
            value += strength * (center - verticalBlur);
        }
        if (parameters[5] == 1) {
            value += strength * (center - isotropicBlur);
        }
        if (parameters[6] == 1) {
            value -= strength * (center - isotropicBlur);
        }
        output[(y * outputWidth) + x] = clamp(value, 0.0, 1.0);
    }
    """
}
