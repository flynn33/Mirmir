import CoreMedia
import CoreVideo
import Foundation
import Metal
import os.lock

// swiftlint:disable file_length

enum LanczosPolishPassError: Error, Equatable, Sendable, CustomStringConvertible {
    case incompatiblePlaneGeometry(
        sourceLuma: SIMD2<Int>,
        sourceChroma: SIMD2<Int>,
        destinationLuma: SIMD2<Int>,
        destinationChroma: SIMD2<Int>
    )
    case shaderLibraryCreationFailed(String)
    case shaderFunctionUnavailable(String)
    case computePipelineCreationFailed(name: String, message: String)
    case contributionBufferCreationFailed(axis: String)
    case intermediateTextureCreationFailed(plane: String, width: Int, height: Int)
    case commandEncoderCreationFailed(label: String)

    var description: String {
        switch self {
        case .incompatiblePlaneGeometry(
            let sourceLuma,
            let sourceChroma,
            let destinationLuma,
            let destinationChroma
        ):
            return "Lanczos plane geometry is inconsistent: source Y \(sourceLuma), "
                + "source CbCr \(sourceChroma), destination Y \(destinationLuma), "
                + "destination CbCr \(destinationChroma)."
        case .shaderLibraryCreationFailed(let message):
            return "Lanczos Metal library creation failed: \(message)"
        case .shaderFunctionUnavailable(let name):
            return "Lanczos Metal function is unavailable: \(name)."
        case .computePipelineCreationFailed(let name, let message):
            return "Lanczos Metal pipeline \(name) creation failed: \(message)"
        case .contributionBufferCreationFailed(let axis):
            return "Lanczos contribution buffer creation failed for \(axis)."
        case .intermediateTextureCreationFailed(let plane, let width, let height):
            return "Lanczos intermediate texture creation failed for \(plane) at \(width)x\(height)."
        case .commandEncoderCreationFailed(let label):
            return "Lanczos command encoder creation failed for \(label)."
        }
    }
}

/// Lanczos downsample of the ASH-produced 2x frame to the selected output
/// resolution. The 720p route reconstructs 2560x1440, then reduces it to
/// 1920x1080.
final class LanczosPolishPass: @unchecked Sendable {
    private static let commandBufferLabel = "Mirmir.LanczosPolish.NV12"

    private let metal: MetalRenderingService
    private let pipelines: Result<LanczosComputePipelines, LanczosPolishPassError>
    private let contributionCache = OSAllocatedUnfairLock(
        initialState: [LanczosAxisKey: LanczosAxisResources]()
    )
    private let telemetry: any ASHTelemetryRecording
    private let completionBridge = MetalCommandBufferCompletionBridge()

    init(
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) {
        self.metal = metal
        do {
            self.pipelines = .success(try LanczosComputePipelines(device: metal.device))
        } catch let error as LanczosPolishPassError {
            self.pipelines = .failure(error)
        } catch {
            self.pipelines = .failure(.shaderLibraryCreationFailed(
                error.localizedDescription
            ))
        }
        self.telemetry = telemetry
    }

    func encode(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        frameIndex: Int? = nil,
        presentationTime: CMTime? = nil
    ) async throws {
        try Task.checkCancellation()
        let context = Self.makeExecutionContext(
            frameIndex: frameIndex,
            presentationTime: presentationTime
        )
        let prepared: LanczosPreparedEncoding
        do {
            prepared = try prepare(source: source, destination: destination)
        } catch {
            recordLocalFailure(error, status: "preparation_failed", context: context)
            throw error
        }

        guard let commandBuffer = makeCommandBuffer() else {
            let error = MetalCommandBufferExecutionError.creationFailed(context: context)
            recordCreationFailure(error, context: context)
            throw error
        }
        let submission = DefaultMetalCommandBufferSubmission(
            commandBuffer: commandBuffer,
            context: context
        )
        telemetry.recordCommandBuffer(Self.observation(
            context: context,
            status: "created"
        ))

        do {
            try encodePrepared(
                prepared,
                frameIndex: frameIndex,
                commandBuffer: commandBuffer
            )
        } catch {
            recordLocalFailure(error, status: "encoding_failed", context: context)
            throw error
        }

        let resources = makeRetainedResources(
            source: source,
            destination: destination,
            prepared: prepared
        )
        do {
            let completion = try await completionBridge.commitAndWait(
                submission,
                retaining: resources,
                onCommit: { [telemetry] in
                    telemetry.recordCommandBuffer(Self.observation(
                        context: context,
                        status: "committed"
                    ))
                }
            )
            telemetry.recordCommandBuffer(Self.observation(completion: completion))
        } catch let error as MetalCommandBufferExecutionError {
            telemetry.increment(.commandBufferErrors)
            if case .executionFailed(let completion) = error {
                telemetry.recordCommandBuffer(Self.observation(completion: completion))
            }
            telemetry.recordError(error, frameIndex: frameIndex)
            throw error
        }
    }
}

private extension LanczosPolishPass {
    private func prepare(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws -> LanczosPreparedEncoding {
        let sourceTextures = try PixelBufferBridge.makeNV12Textures(
            from: source,
            cache: metal.textureCache
        )
        let destinationTextures = try PixelBufferBridge.makeNV12Textures(
            from: destination,
            cache: metal.textureCache
        )
        try Self.validatePlaneGeometry(
            source: sourceTextures,
            destination: destinationTextures
        )
        let activePipelines = try pipelines.get()
        return try LanczosPreparedEncoding(
            sourceTextures: sourceTextures,
            destinationTextures: destinationTextures,
            pipelines: activePipelines,
            lumaResources: makePlaneResources(
                plane: "luma",
                source: sourceTextures.luma.texture,
                destination: destinationTextures.luma.texture,
                intermediateFormat: .r32Sint
            ),
            chromaResources: makePlaneResources(
                plane: "chroma",
                source: sourceTextures.chroma.texture,
                destination: destinationTextures.chroma.texture,
                intermediateFormat: .rg32Sint
            )
        )
    }

    private func encodePrepared(
        _ prepared: LanczosPreparedEncoding,
        frameIndex: Int?,
        commandBuffer: MTLCommandBuffer
    ) throws {
        try encodePlane(
            pipelines: prepared.pipelines.luma,
            source: prepared.sourceTextures.luma.texture,
            destination: prepared.destinationTextures.luma.texture,
            resources: prepared.lumaResources,
            stage: .reconstructLuma,
            frameIndex: frameIndex,
            commandBuffer: commandBuffer
        )
        try encodePlane(
            pipelines: prepared.pipelines.chroma,
            source: prepared.sourceTextures.chroma.texture,
            destination: prepared.destinationTextures.chroma.texture,
            resources: prepared.chromaResources,
            stage: .reconstructChroma,
            frameIndex: frameIndex,
            commandBuffer: commandBuffer
        )
    }

    private func makeRetainedResources(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        prepared: LanczosPreparedEncoding
    ) -> MetalCommandBufferRetainedResources {
        MetalCommandBufferRetainedResources(
            [source as AnyObject, destination as AnyObject]
                + prepared.sourceTextures.all.map { $0 as AnyObject }
                + prepared.destinationTextures.all.map { $0 as AnyObject }
                + prepared.lumaResources.retainedResources
                + prepared.chromaResources.retainedResources
        )
    }

    private func recordLocalFailure(
        _ error: Error,
        status: String,
        context: MetalCommandBufferExecutionContext
    ) {
        telemetry.increment(.commandBufferErrors)
        telemetry.recordCommandBuffer(Self.observation(
            context: context,
            status: status
        ))
        telemetry.recordError(error, frameIndex: context.frameIndex)
    }

    private func makeCommandBuffer() -> MTLCommandBuffer? {
        #if DEBUG
        let descriptor = MTLCommandBufferDescriptor()
        descriptor.errorOptions = [.encoderExecutionStatus]
        return metal.commandQueue.makeCommandBuffer(descriptor: descriptor)
        #else
        return metal.commandQueue.makeCommandBuffer()
        #endif
    }

    private func encodePlane(
        pipelines: LanczosPlanePipelines,
        source: MTLTexture,
        destination: MTLTexture,
        resources: LanczosPlaneResources,
        stage: ASHTelemetryStage,
        frameIndex: Int?,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let stageToken = telemetry.beginStage(stage, frameIndex: frameIndex)
        defer { telemetry.endStage(stageToken) }
        try encodePass(
            label: "Mirmir.LanczosPolish.\(resources.plane).horizontal",
            pipeline: pipelines.horizontal,
            source: source,
            destination: resources.intermediate,
            contributions: resources.horizontal,
            width: destination.width,
            height: source.height,
            commandBuffer: commandBuffer
        )
        try encodePass(
            label: "Mirmir.LanczosPolish.\(resources.plane).vertical",
            pipeline: pipelines.vertical,
            source: resources.intermediate,
            destination: destination,
            contributions: resources.vertical,
            width: destination.width,
            height: destination.height,
            commandBuffer: commandBuffer
        )
    }

    private func makePlaneResources(
        plane: String,
        source: MTLTexture,
        destination: MTLTexture,
        intermediateFormat: MTLPixelFormat
    ) throws -> LanczosPlaneResources {
        let horizontal = try axisResources(
            sourceCount: source.width,
            destinationCount: destination.width
        )
        let vertical = try axisResources(
            sourceCount: source.height,
            destinationCount: destination.height
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: intermediateFormat,
            width: destination.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let intermediate = metal.device.makeTexture(descriptor: descriptor) else {
            throw LanczosPolishPassError.intermediateTextureCreationFailed(
                plane: plane,
                width: destination.width,
                height: source.height
            )
        }
        intermediate.label = "Mirmir.LanczosPolish.\(plane).intermediate"
        return LanczosPlaneResources(
            plane: plane,
            horizontal: horizontal,
            vertical: vertical,
            intermediate: intermediate
        )
    }

    private func axisResources(
        sourceCount: Int,
        destinationCount: Int
    ) throws -> LanczosAxisResources {
        let key = LanczosAxisKey(
            sourceCount: sourceCount,
            destinationCount: destinationCount
        )
        if let cached = contributionCache.withLock({ $0[key] }) {
            return cached
        }
        let created = try LanczosAxisResources(device: metal.device, key: key)
        return contributionCache.withLock { cache in
            if let cached = cache[key] {
                return cached
            }
            cache[key] = created
            return created
        }
    }

    private func encodePass(
        label: String,
        pipeline: MTLComputePipelineState,
        source: MTLTexture,
        destination: MTLTexture,
        contributions: LanczosAxisResources,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw LanczosPolishPassError.commandEncoderCreationFailed(label: label)
        }
        encoder.label = label
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(contributions.headers, offset: 0, index: 0)
        encoder.setBuffer(contributions.taps, offset: 0, index: 1)
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        let availableThreadHeight = pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        let threadHeight = max(1, min(availableThreadHeight, height))
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

    private func recordCreationFailure(
        _ error: MetalCommandBufferExecutionError,
        context: MetalCommandBufferExecutionContext
    ) {
        telemetry.increment(.commandBufferErrors)
        telemetry.recordCommandBuffer(Self.observation(
            context: context,
            status: "creation_failed"
        ))
        telemetry.recordError(error, frameIndex: context.frameIndex)
    }

    private static func makeExecutionContext(
        frameIndex: Int?,
        presentationTime: CMTime?
    ) -> MetalCommandBufferExecutionContext {
        guard let presentationTime, presentationTime.isValid else {
            return MetalCommandBufferExecutionContext(
                label: commandBufferLabel,
                frameIndex: frameIndex
            )
        }
        return MetalCommandBufferExecutionContext(
            label: commandBufferLabel,
            frameIndex: frameIndex,
            presentationTimestampValue: presentationTime.value,
            presentationTimestampTimescale: presentationTime.timescale
        )
    }

    private static func validatePlaneGeometry(
        source: PixelBufferNV12Textures,
        destination: PixelBufferNV12Textures
    ) throws {
        let sourceLuma = SIMD2(source.luma.texture.width, source.luma.texture.height)
        let sourceChroma = SIMD2(source.chroma.texture.width, source.chroma.texture.height)
        let destinationLuma = SIMD2(
            destination.luma.texture.width,
            destination.luma.texture.height
        )
        let destinationChroma = SIMD2(
            destination.chroma.texture.width,
            destination.chroma.texture.height
        )
        let sourceIsNV12 = sourceLuma == sourceChroma &* 2
        let destinationIsNV12 = destinationLuma == destinationChroma &* 2
        let ratiosMatch = destinationLuma.x * sourceChroma.x
            == sourceLuma.x * destinationChroma.x
            && destinationLuma.y * sourceChroma.y
            == sourceLuma.y * destinationChroma.y
        guard sourceIsNV12, destinationIsNV12, ratiosMatch else {
            throw LanczosPolishPassError.incompatiblePlaneGeometry(
                sourceLuma: sourceLuma,
                sourceChroma: sourceChroma,
                destinationLuma: destinationLuma,
                destinationChroma: destinationChroma
            )
        }
    }

    private static func observation(
        context: MetalCommandBufferExecutionContext,
        status: String
    ) -> ASHCommandBufferObservation {
        ASHCommandBufferObservation(
            label: context.label,
            status: status,
            frameIndex: context.frameIndex,
            presentationTimestampValue: context.presentationTimestampValue,
            presentationTimestampTimescale: context.presentationTimestampTimescale
        )
    }

    private static func observation(
        completion: MetalCommandBufferCompletion
    ) -> ASHCommandBufferObservation {
        ASHCommandBufferObservation(
            label: completion.context.label,
            status: completion.status.name,
            frameIndex: completion.context.frameIndex,
            presentationTimestampValue: completion.context.presentationTimestampValue,
            presentationTimestampTimescale: completion.context.presentationTimestampTimescale,
            errorDomain: completion.error?.domain,
            errorCode: completion.error?.code,
            gpuStartSeconds: completion.gpuStartSeconds,
            gpuEndSeconds: completion.gpuEndSeconds
        )
    }
}

private struct LanczosPreparedEncoding {
    let sourceTextures: PixelBufferNV12Textures
    let destinationTextures: PixelBufferNV12Textures
    let pipelines: LanczosComputePipelines
    let lumaResources: LanczosPlaneResources
    let chromaResources: LanczosPlaneResources
}

private struct LanczosAxisKey: Hashable {
    let sourceCount: Int
    let destinationCount: Int
}

private struct LanczosContributionHeader {
    let offset: UInt32
    let count: UInt32
}

private struct LanczosWeightedIndex {
    let sourceIndex: UInt32
    let weight: Int32
}

private final class LanczosAxisResources: @unchecked Sendable {
    let headers: MTLBuffer
    let taps: MTLBuffer

    init(device: MTLDevice, key: LanczosAxisKey) throws {
        let values = LanczosWeights.makeAxis(
            sourceCount: key.sourceCount,
            destinationCount: key.destinationCount
        )
        let axis = "\(key.sourceCount)-to-\(key.destinationCount)"
        guard let headers = Self.makeBuffer(device: device, values: values.headers),
              let taps = Self.makeBuffer(device: device, values: values.taps) else {
            throw LanczosPolishPassError.contributionBufferCreationFailed(axis: axis)
        }
        headers.label = "Mirmir.LanczosPolish.weights.\(axis).headers"
        taps.label = "Mirmir.LanczosPolish.weights.\(axis).taps"
        self.headers = headers
        self.taps = taps
    }

    private static func makeBuffer<Element>(
        device: MTLDevice,
        values: [Element]
    ) -> MTLBuffer? {
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: [.storageModeShared]
            )
        }
    }
}

private enum LanczosWeights {
    private static let radius = 3.0
    private static let fixedPointScale: Int64 = 1 << 20

    static func makeAxis(
        sourceCount: Int,
        destinationCount: Int
    ) -> (headers: [LanczosContributionHeader], taps: [LanczosWeightedIndex]) {
        let scale = Double(destinationCount) / Double(sourceCount)
        let filterScale = min(scale, 1.0)
        let support = radius / filterScale
        var headers: [LanczosContributionHeader] = []
        var taps: [LanczosWeightedIndex] = []
        headers.reserveCapacity(destinationCount)

        for destinationIndex in 0..<destinationCount {
            let sourceCoordinate = (Double(destinationIndex) + 0.5) / scale - 0.5
            let firstSourceIndex = Int(floor(sourceCoordinate - support))
            let lastSourceIndex = Int(ceil(sourceCoordinate + support))
            var weightsBySourceIndex: [Int: Double] = [:]
            var weightSum = 0.0
            for unboundedSourceIndex in firstSourceIndex...lastSourceIndex {
                let distance = (
                    sourceCoordinate - Double(unboundedSourceIndex)
                ) * filterScale
                let weight = lanczos3(distance) * filterScale
                guard weight != 0 else { continue }
                let sourceIndex = min(max(unboundedSourceIndex, 0), sourceCount - 1)
                weightsBySourceIndex[sourceIndex, default: 0] += weight
                weightSum += weight
            }
            let orderedWeights = weightsBySourceIndex.sorted { $0.key < $1.key }
            headers.append(LanczosContributionHeader(
                offset: UInt32(taps.count),
                count: UInt32(orderedWeights.count)
            ))
            var fixedPointWeights = orderedWeights.map { _, weight in
                Int64((weight * Double(fixedPointScale) / weightSum).rounded())
            }
            if let correctionIndex = orderedWeights.indices.max(by: {
                abs(orderedWeights[$0].value) < abs(orderedWeights[$1].value)
            }) {
                let residual = fixedPointScale - fixedPointWeights.reduce(0, +)
                fixedPointWeights[correctionIndex] += residual
            }
            taps.append(contentsOf: zip(orderedWeights, fixedPointWeights).map { entry, fixedPointWeight in
                LanczosWeightedIndex(
                    sourceIndex: UInt32(entry.key),
                    weight: Int32(fixedPointWeight)
                )
            })
        }
        return (headers, taps)
    }

    private static func lanczos3(_ value: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude < radius else { return 0 }
        guard magnitude > Double.ulpOfOne else { return 1 }
        return sinc(value) * sinc(value / radius)
    }

    private static func sinc(_ value: Double) -> Double {
        let argument = Double.pi * value
        return sin(argument) / argument
    }
}

private struct LanczosPlaneResources {
    let plane: String
    let horizontal: LanczosAxisResources
    let vertical: LanczosAxisResources
    let intermediate: MTLTexture

    var retainedResources: [AnyObject] {
        [
            intermediate as AnyObject,
            horizontal.headers as AnyObject,
            horizontal.taps as AnyObject,
            vertical.headers as AnyObject,
            vertical.taps as AnyObject
        ]
    }
}

private struct LanczosPlanePipelines {
    let horizontal: MTLComputePipelineState
    let vertical: MTLComputePipelineState
}

private struct LanczosComputePipelines {
    let luma: LanczosPlanePipelines
    let chroma: LanczosPlanePipelines

    init(device: MTLDevice) throws {
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: options)
        } catch {
            throw LanczosPolishPassError.shaderLibraryCreationFailed(
                error.localizedDescription
            )
        }
        library.label = "Mirmir.LanczosPolish.library"
        self.luma = LanczosPlanePipelines(
            horizontal: try Self.makePipeline(
                device: device,
                library: library,
                functionName: "lanczos_horizontal_luma",
                label: "Mirmir.LanczosPolish.pipeline.luma.horizontal"
            ),
            vertical: try Self.makePipeline(
                device: device,
                library: library,
                functionName: "lanczos_vertical_luma",
                label: "Mirmir.LanczosPolish.pipeline.luma.vertical"
            )
        )
        self.chroma = LanczosPlanePipelines(
            horizontal: try Self.makePipeline(
                device: device,
                library: library,
                functionName: "lanczos_horizontal_chroma",
                label: "Mirmir.LanczosPolish.pipeline.chroma.horizontal"
            ),
            vertical: try Self.makePipeline(
                device: device,
                library: library,
                functionName: "lanczos_vertical_chroma",
                label: "Mirmir.LanczosPolish.pipeline.chroma.vertical"
            )
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        functionName: String,
        label: String
    ) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: functionName) else {
            throw LanczosPolishPassError.shaderFunctionUnavailable(functionName)
        }
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = label
        descriptor.computeFunction = function
        do {
            return try device.makeComputePipelineState(
                descriptor: descriptor,
                options: [],
                reflection: nil
            )
        } catch {
            throw LanczosPolishPassError.computePipelineCreationFailed(
                name: functionName,
                message: error.localizedDescription
            )
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LanczosContributionHeader {
        uint offset;
        uint count;
    };

    struct LanczosWeightedIndex {
        uint sourceIndex;
        int weight;
    };

    inline int lanczos_quantize(long sum) {
        constexpr long scaleSquared = 1099511627776;
        long clamped = clamp(sum, long(0), long(255) * scaleSquared);
        return int((clamped + (scaleSquared / 2)) / scaleSquared);
    }

    kernel void lanczos_horizontal_luma(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<int, access::write> destination [[texture(1)]],
        const device LanczosContributionHeader *headers [[buffer(0)]],
        const device LanczosWeightedIndex *taps [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        LanczosContributionHeader header = headers[gid.x];
        long sum = 0;
        for (uint tapIndex = 0; tapIndex < header.count; ++tapIndex) {
            LanczosWeightedIndex tap = taps[header.offset + tapIndex];
            int sourceCode = int(round(
                source.read(uint2(tap.sourceIndex, gid.y)).r * 255.0f
            ));
            sum += long(sourceCode) * long(tap.weight);
        }
        destination.write(int4(int(sum), 0, 0, 1), gid);
    }

    kernel void lanczos_vertical_luma(
        texture2d<int, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        const device LanczosContributionHeader *headers [[buffer(0)]],
        const device LanczosWeightedIndex *taps [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        LanczosContributionHeader header = headers[gid.y];
        long sum = 0;
        for (uint tapIndex = 0; tapIndex < header.count; ++tapIndex) {
            LanczosWeightedIndex tap = taps[header.offset + tapIndex];
            int sourceCode = source.read(uint2(gid.x, tap.sourceIndex)).r;
            sum += long(sourceCode) * long(tap.weight);
        }
        int codeValue = lanczos_quantize(sum);
        destination.write(float4(float(codeValue) / 255.0f, 0.0f, 0.0f, 1.0f), gid);
    }

    kernel void lanczos_horizontal_chroma(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<int, access::write> destination [[texture(1)]],
        const device LanczosContributionHeader *headers [[buffer(0)]],
        const device LanczosWeightedIndex *taps [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        LanczosContributionHeader header = headers[gid.x];
        long2 sum = long2(0);
        for (uint tapIndex = 0; tapIndex < header.count; ++tapIndex) {
            LanczosWeightedIndex tap = taps[header.offset + tapIndex];
            int2 sourceCode = int2(round(
                source.read(uint2(tap.sourceIndex, gid.y)).rg * 255.0f
            ));
            sum += long2(sourceCode) * long(tap.weight);
        }
        destination.write(int4(int2(sum), 0, 1), gid);
    }

    kernel void lanczos_vertical_chroma(
        texture2d<int, access::read> source [[texture(0)]],
        texture2d<float, access::write> destination [[texture(1)]],
        const device LanczosContributionHeader *headers [[buffer(0)]],
        const device LanczosWeightedIndex *taps [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
            return;
        }
        LanczosContributionHeader header = headers[gid.y];
        long2 sum = long2(0);
        for (uint tapIndex = 0; tapIndex < header.count; ++tapIndex) {
            LanczosWeightedIndex tap = taps[header.offset + tapIndex];
            int2 sourceCode = source.read(uint2(gid.x, tap.sourceIndex)).rg;
            sum += long2(sourceCode) * long(tap.weight);
        }
        int2 codeValue = int2(
            lanczos_quantize(sum.x),
            lanczos_quantize(sum.y)
        );
        destination.write(float4(float2(codeValue) / 255.0f, 0.0f, 1.0f), gid);
    }
    """
}

// swiftlint:enable file_length
