@preconcurrency import Metal

struct ASHMetalEncodingResourcesV3 {
    let sourceLuma: MTLTexture
    let sourceChroma: MTLTexture
    let destinationLuma: MTLTexture
    let destinationChroma: MTLTexture
    let states: MTLBuffer
    let dispatches: MTLBuffer
    let reduction: MTLBuffer
    let summary: MTLBuffer
    let uniforms: MTLBuffer
    let immutableLUT: MTLBuffer
    let immutableDecoder: MTLBuffer
    let analysisColumns: Int
    let analysisRows: Int
    let dispatchCount: Int
    let destinationGeometry: ASHNV12FrameGeometry
}

enum ASHMetalSpatialFrameEncoderV3 {
    static func encode(
        commandBuffer: MTLCommandBuffer,
        resources: ASHMetalEncodingResourcesV3,
        pipelines: ASHMetalPipelinesV3
    ) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ASHMetalSpatialRuntimeErrorV3.encoderCreationFailed(stage: "clear")
        }
        blit.label = "com.mirmir.ash.v3.clear_reduction"
        blit.fill(
            buffer: resources.reduction,
            range: 0..<ASHMetalRuntimeLayoutV3.telemetryWordCount * 4,
            value: 0
        )
        blit.fill(
            buffer: resources.summary,
            range: 0..<ASHMetalRuntimeLayoutV3.summaryWordCount * 4,
            value: 0
        )
        blit.endEncoding()

        try encode2D(
            commandBuffer: commandBuffer,
            label: "analyze_luma",
            pipeline: pipelines.analyzeLuma,
            width: resources.analysisColumns,
            height: resources.analysisRows
        ) { encoder in
            encoder.setTexture(resources.sourceLuma, index: 0)
            encoder.setBuffer(resources.states, offset: 0, index: 0)
            encoder.setBuffer(resources.uniforms, offset: 0, index: 1)
        }
        try encode2D(
            commandBuffer: commandBuffer,
            label: "analyze_chroma_state",
            pipeline: pipelines.analyzeChroma,
            width: resources.analysisColumns,
            height: resources.analysisRows
        ) { encoder in
            encoder.setTexture(resources.sourceChroma, index: 0)
            encoder.setBuffer(resources.states, offset: 0, index: 0)
            encoder.setBuffer(resources.uniforms, offset: 0, index: 1)
            encoder.setBuffer(resources.reduction, offset: 0, index: 2)
        }
        try encode1D(
            commandBuffer: commandBuffer,
            label: "decode_dispatch",
            pipeline: pipelines.decodeDispatch,
            count: resources.dispatchCount
        ) { encoder in
            encoder.setBuffer(resources.states, offset: 0, index: 0)
            encoder.setBuffer(resources.immutableLUT, offset: 0, index: 1)
            encoder.setBuffer(resources.immutableDecoder, offset: 0, index: 2)
            encoder.setBuffer(resources.dispatches, offset: 0, index: 3)
            encoder.setBuffer(resources.uniforms, offset: 0, index: 4)
            encoder.setBuffer(resources.reduction, offset: 0, index: 5)
        }
        try encode2D(
            commandBuffer: commandBuffer,
            label: "reconstruct_luma",
            pipeline: pipelines.reconstructLuma,
            width: resources.destinationGeometry.lumaWidth,
            height: resources.destinationGeometry.lumaHeight
        ) { encoder in
            encoder.setTexture(resources.sourceLuma, index: 0)
            encoder.setTexture(resources.destinationLuma, index: 1)
            encoder.setBuffer(resources.states, offset: 0, index: 0)
            encoder.setBuffer(resources.dispatches, offset: 0, index: 1)
            encoder.setBuffer(resources.immutableLUT, offset: 0, index: 2)
            encoder.setBuffer(resources.uniforms, offset: 0, index: 3)
            encoder.setBuffer(resources.reduction, offset: 0, index: 4)
        }
        try encode2D(
            commandBuffer: commandBuffer,
            label: "reconstruct_chroma",
            pipeline: pipelines.reconstructChroma,
            width: resources.destinationGeometry.chromaWidth,
            height: resources.destinationGeometry.chromaHeight
        ) { encoder in
            encoder.setTexture(resources.sourceChroma, index: 0)
            encoder.setTexture(resources.destinationChroma, index: 1)
            encoder.setBuffer(resources.states, offset: 0, index: 0)
            encoder.setBuffer(resources.dispatches, offset: 0, index: 1)
            encoder.setBuffer(resources.immutableLUT, offset: 0, index: 2)
            encoder.setBuffer(resources.uniforms, offset: 0, index: 3)
            encoder.setBuffer(resources.reduction, offset: 0, index: 4)
        }
        try encode1D(
            commandBuffer: commandBuffer,
            label: "finalize_reduction",
            pipeline: pipelines.finalizeReduction,
            count: ASHMetalRuntimeLayoutV3.summaryWordCount
        ) { encoder in
            encoder.setBuffer(resources.reduction, offset: 0, index: 0)
            encoder.setBuffer(resources.summary, offset: 0, index: 1)
        }
    }

    private static func encode2D(
        commandBuffer: MTLCommandBuffer,
        label: String,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int,
        bindings: (MTLComputeCommandEncoder) -> Void
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ASHMetalSpatialRuntimeErrorV3.encoderCreationFailed(stage: label)
        }
        encoder.label = "com.mirmir.ash.v3.\(label)"
        encoder.setComputePipelineState(pipeline)
        bindings(encoder)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        encoder.endEncoding()
    }

    private static func encode1D(
        commandBuffer: MTLCommandBuffer,
        label: String,
        pipeline: MTLComputePipelineState,
        count: Int,
        bindings: (MTLComputeCommandEncoder) -> Void
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ASHMetalSpatialRuntimeErrorV3.encoderCreationFailed(stage: label)
        }
        encoder.label = "com.mirmir.ash.v3.\(label)"
        encoder.setComputePipelineState(pipeline)
        bindings(encoder)
        let width = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            pipeline.threadExecutionWidth
        )
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
    }
}
