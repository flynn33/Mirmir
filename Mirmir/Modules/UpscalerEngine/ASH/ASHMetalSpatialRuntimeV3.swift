import CoreVideo
import Foundation
@preconcurrency import Metal

@available(macOS 15.4, *)
final class ASHMetalSpatialRuntimeV3: @unchecked Sendable {
    typealias CommandBufferFactory = @Sendable (MTLCommandQueue) -> MTLCommandBuffer?

    private struct FrameGeometry {
        let source: ASHNV12FrameGeometry
        let destination: ASHNV12FrameGeometry
    }

    private struct FrameTextures {
        let sourceLuma: ASHMetalTexturePlaneV3
        let sourceChroma: ASHMetalTexturePlaneV3
        let destinationLuma: ASHMetalTexturePlaneV3
        let destinationChroma: ASHMetalTexturePlaneV3
    }

    private struct FrameBuffers {
        let states: MTLBuffer
        let dispatches: MTLBuffer
        let reduction: MTLBuffer
        let summary: MTLBuffer
        let uniforms: MTLBuffer
    }

    private struct PreparedFrameResources {
        let encoding: ASHMetalEncodingResourcesV3
        let retainedResources: [AnyObject]
        let sizes: ASHMetalBufferSizesV3
    }

    let route: ASHSpatialRouteV2
    let constructionCounters: ASHMetalRuntimeConstructionCountersV3

    private let lut: ASHMetalRuntimeLUTV3
    private let configuration: ASHMetalRuntimeConfigurationV3
    private let mapping: ASHMetalRuntimeMappingV3
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let telemetry: any ASHTelemetryRecording
    private let textureCreator: any ASHMetalTextureCreatingV3
    private let commandBufferFactory: CommandBufferFactory
    private let commandCompleter: any ASHMetalCommandCompletingV3
    private let pipelines: ASHMetalPipelinesV3
    private let immutableLUTBuffer: MTLBuffer
    private let immutableDecoderBuffer: MTLBuffer
    private let ring: ASHMetalFrameResourceRingV3
    private let monitor: ASHMetalRuntimeMonitorV3

    init(
        route: ASHSpatialRouteV2,
        lut: ASHMetalRuntimeLUTV3,
        mapping: ASHMetalRuntimeMappingV3,
        metal: any MetalRenderingService,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared,
        ringCapacity: Int = ASHMetalFrameResourceRingV3.defaultCapacity,
        library: MTLLibrary? = nil,
        textureCreator: any ASHMetalTextureCreatingV3 = ASHDefaultMetalTextureCreatorV3(),
        commandBufferFactory: @escaping CommandBufferFactory = { $0.makeCommandBuffer() },
        commandCompleter: any ASHMetalCommandCompletingV3 = ASHDefaultMetalCommandCompleterV3()
    ) throws {
        let configuration = lut.configuration
        let routeSelection = configuration.routeSelection(for: route)
        guard lut.route == route,
              mapping.boundaryMode == configuration.boundaryMode,
              mapping.analysisGridSourceStep(for: route)
                == routeSelection.analysisGridSourceStep else {
            throw ASHMetalSpatialRuntimeErrorV3.configurationMismatch
        }
        self.route = route
        self.lut = lut
        self.configuration = configuration
        self.mapping = mapping
        self.device = metal.device
        self.commandQueue = metal.commandQueue
        self.textureCache = metal.textureCache
        self.telemetry = telemetry
        self.textureCreator = textureCreator
        self.commandBufferFactory = commandBufferFactory
        self.commandCompleter = commandCompleter
        self.ring = try ASHMetalFrameResourceRingV3(capacity: ringCapacity)
        self.monitor = ASHMetalRuntimeMonitorV3(telemetry: telemetry)

        guard let library = library
            ?? MirmirDefaultMetalLibrary.make(on: metal.device) else {
            throw ASHMetalSpatialRuntimeErrorV3.defaultLibraryUnavailable
        }
        self.pipelines = try ASHMetalSpatialRuntimePreparationV3.makePipelines(
            device: metal.device,
            library: library
        )
        self.immutableLUTBuffer = try ASHMetalSpatialRuntimePreparationV3
            .makeImmutableBuffer(
                data: lut.immutableBytes,
                label: "com.mirmir.ash.v3.lut.\(route.rawValue)",
                device: metal.device
            )
        self.immutableDecoderBuffer = try ASHMetalSpatialRuntimePreparationV3
            .makeDecoderBuffer(device: metal.device)
        self.constructionCounters = ASHMetalRuntimeConstructionCountersV3(
            pipelineCreationCount: 6,
            immutableLUTBufferCreationCount: 1,
            immutableDecoderBufferCreationCount: 1,
            textureCacheCreationCount: 0,
            runtimeTreeGenerationCount: lut.runtimeTreeGenerationCount,
            runtimeJSONLoadCount: 0
        )
    }

    func process(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        context: ASHMetalFrameContextV3
    ) async throws -> ASHMetalCompletedFrameV3 {
        try Task.checkCancellation()
        let lease = try await ring.acquire()
        var transfersLease = false
        defer {
            if !transfersLease {
                ring.release(lease)
            }
        }

        do {
            let prepared = try prepareFrame(
                source: source,
                destination: destination,
                lease: lease
            )
            try Task.checkCancellation()
            let frame = try await execute(
                prepared,
                lease: lease,
                context: context
            )
            transfersLease = true
            return frame
        } catch {
            monitor.recordProcessingFailure(error, frameIndex: context.frameIndex)
            throw error
        }
    }

    func diagnostics() -> ASHMetalRuntimeDiagnosticsV3 {
        monitor.diagnostics(
            ring: ring,
            completionMode: commandCompleter.completionMode
        )
    }
}

@available(macOS 15.4, *)
private extension ASHMetalSpatialRuntimeV3 {
    private func prepareFrame(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        lease: ASHMetalFrameResourceLeaseV3
    ) throws -> PreparedFrameResources {
        let geometry = try frameGeometry(source: source, destination: destination)
        ASHNV12FrameCodec.setChromaSiting(mapping.chromaSiting, on: destination)
        let textures = try frameTextures(
            source: source,
            destination: destination,
            geometry: geometry
        )
        let sizes = try ASHMetalSpatialRuntimePreparationV3.bufferSizes(
            source: geometry.source,
            route: route,
            step: Int(configuration.routeSelection(for: route).analysisGridSourceStep)
        )
        let buffers = try frameBuffers(lease: lease, sizes: sizes)
        ASHMetalSpatialRuntimePreparationV3.writeUniforms(
            to: buffers.uniforms,
            inputs: ASHMetalUniformInputsV3(
                source: geometry.source,
                destination: geometry.destination,
                route: route,
                lut: lut,
                configuration: configuration,
                mapping: mapping,
                analysisColumns: sizes.analysisColumns,
                analysisRows: sizes.analysisRows
            )
        )
        let encoding = ASHMetalEncodingResourcesV3(
            sourceLuma: textures.sourceLuma.texture,
            sourceChroma: textures.sourceChroma.texture,
            destinationLuma: textures.destinationLuma.texture,
            destinationChroma: textures.destinationChroma.texture,
            states: buffers.states,
            dispatches: buffers.dispatches,
            reduction: buffers.reduction,
            summary: buffers.summary,
            uniforms: buffers.uniforms,
            immutableLUT: immutableLUTBuffer,
            immutableDecoder: immutableDecoderBuffer,
            analysisColumns: sizes.analysisColumns,
            analysisRows: sizes.analysisRows,
            dispatchCount: sizes.dispatchCount,
            destinationGeometry: geometry.destination
        )
        let retainedResources: [AnyObject] = [
            source as AnyObject,
            destination as AnyObject,
            textures.sourceLuma.reference as AnyObject,
            textures.sourceLuma.texture,
            textures.sourceChroma.reference as AnyObject,
            textures.sourceChroma.texture,
            textures.destinationLuma.reference as AnyObject,
            textures.destinationLuma.texture,
            textures.destinationChroma.reference as AnyObject,
            textures.destinationChroma.texture,
            buffers.states,
            buffers.dispatches,
            buffers.reduction,
            buffers.summary,
            buffers.uniforms,
            immutableLUTBuffer,
            immutableDecoderBuffer
        ]
        lease.slot.retainFrameResources(retainedResources)
        return PreparedFrameResources(
            encoding: encoding,
            retainedResources: retainedResources,
            sizes: sizes
        )
    }

    private func frameGeometry(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws -> FrameGeometry {
        let sourceGeometry = try ASHMetalSpatialRuntimePreparationV3.validatedGeometry(
            source,
            expectedRange: mapping.codeRange,
            expectedSiting: mapping.chromaSiting
        )
        let destinationGeometry = try ASHMetalSpatialRuntimePreparationV3.validatedGeometry(
            destination,
            expectedRange: mapping.codeRange,
            expectedSiting: nil
        )
        try ASHMetalSpatialRuntimePreparationV3.validateRouteGeometry(
            source: sourceGeometry,
            destination: destinationGeometry,
            route: route
        )
        return FrameGeometry(
            source: sourceGeometry,
            destination: destinationGeometry
        )
    }

    private func frameTextures(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        geometry: FrameGeometry
    ) throws -> FrameTextures {
        let sourceLuma = try textureCreator.makeTexture(
            cache: textureCache,
            pixelBuffer: source,
            pixelFormat: .r8Unorm,
            width: geometry.source.lumaWidth,
            height: geometry.source.lumaHeight,
            plane: 0,
            usage: .shaderRead
        )
        let sourceChroma = try textureCreator.makeTexture(
            cache: textureCache,
            pixelBuffer: source,
            pixelFormat: .rg8Unorm,
            width: geometry.source.chromaWidth,
            height: geometry.source.chromaHeight,
            plane: 1,
            usage: .shaderRead
        )
        let destinationLuma = try textureCreator.makeTexture(
            cache: textureCache,
            pixelBuffer: destination,
            pixelFormat: .r8Unorm,
            width: geometry.destination.lumaWidth,
            height: geometry.destination.lumaHeight,
            plane: 0,
            usage: .shaderWrite
        )
        let destinationChroma = try textureCreator.makeTexture(
            cache: textureCache,
            pixelBuffer: destination,
            pixelFormat: .rg8Unorm,
            width: geometry.destination.chromaWidth,
            height: geometry.destination.chromaHeight,
            plane: 1,
            usage: .shaderWrite
        )
        return FrameTextures(
            sourceLuma: sourceLuma,
            sourceChroma: sourceChroma,
            destinationLuma: destinationLuma,
            destinationChroma: destinationChroma
        )
    }

    private func frameBuffers(
        lease: ASHMetalFrameResourceLeaseV3,
        sizes: ASHMetalBufferSizesV3
    ) throws -> FrameBuffers {
        let slot = lease.slot
        let states = try slot.reusableBuffer(
            kind: .stateSamples,
            minimumLength: sizes.stateBytes,
            device: device
        )
        let dispatches = try slot.reusableBuffer(
            kind: .dispatches,
            minimumLength: sizes.dispatchBytes,
            device: device
        )
        let reduction = try slot.reusableBuffer(
            kind: .telemetryReduction,
            minimumLength: ASHMetalRuntimeLayoutV3.telemetryWordCount
                * MemoryLayout<UInt32>.stride,
            device: device
        )
        let summary = try slot.reusableBuffer(
            kind: .telemetrySummary,
            minimumLength: ASHMetalRuntimeLayoutV3.summaryWordCount
                * MemoryLayout<UInt32>.stride,
            device: device
        )
        let uniforms = try slot.reusableBuffer(
            kind: .uniforms,
            minimumLength: ASHMetalRuntimeLayoutV3.uniformWordCount
                * MemoryLayout<UInt32>.stride,
            device: device
        )
        return FrameBuffers(
            states: states,
            dispatches: dispatches,
            reduction: reduction,
            summary: summary,
            uniforms: uniforms
        )
    }

    private func execute(
        _ prepared: PreparedFrameResources,
        lease: ASHMetalFrameResourceLeaseV3,
        context: ASHMetalFrameContextV3
    ) async throws -> ASHMetalCompletedFrameV3 {
        guard let commandBuffer = commandBufferFactory(commandQueue) else {
            throw ASHMetalSpatialRuntimeErrorV3.commandBufferCreationFailed(
                frameIndex: context.frameIndex
            )
        }
        let executionContext = MetalCommandBufferExecutionContext(
            label: "com.mirmir.ash.v3.frame",
            frameIndex: context.frameIndex,
            presentationTimestampValue: context.presentationTimestampValue,
            presentationTimestampTimescale: context.presentationTimestampTimescale
        )
        let submission = DefaultMetalCommandBufferSubmission(
            commandBuffer: commandBuffer,
            context: executionContext
        )
        try ASHMetalSpatialFrameEncoderV3.encode(
            commandBuffer: commandBuffer,
            resources: prepared.encoding,
            pipelines: pipelines
        )

        monitor.markSubmission()
        let completion: MetalCommandBufferCompletion
        do {
            completion = try await commandCompleter.commitAndComplete(
                submission,
                retaining: MetalCommandBufferRetainedResources(
                    prepared.retainedResources
                )
            )
            monitor.markCompletion(failed: false)
        } catch {
            monitor.markCompletion(failed: !(error is CancellationError))
            monitor.recordCommandFailure(error, context: executionContext)
            if error is CancellationError { throw error }
            if let execution = error as? MetalCommandBufferExecutionError,
               case .executionFailed(let completion) = execution {
                throw ASHMetalSpatialRuntimeErrorV3.commandExecutionFailed(
                    status: completion.status.name,
                    reason: completion.error?.message
                )
            }
            throw error
        }
        monitor.recordCommandCompletion(completion)
        let frameSummary = ASHMetalSpatialRuntimePreparationV3.readSummary(
            reduction: prepared.encoding.reduction,
            summary: prepared.encoding.summary
        )
        guard frameSummary.fatalFaultCount == 0 else {
            throw ASHMetalSpatialRuntimeErrorV3.fatalNumericalFault(
                count: frameSummary.fatalFaultCount
            )
        }
        monitor.record(frameSummary, context: context, completion: completion)
        return ASHMetalCompletedFrameV3(
            summary: frameSummary,
            ring: ring,
            lease: lease,
            stateSamples: prepared.encoding.states,
            analysisCellCount: prepared.sizes.analysisColumns
                * prepared.sizes.analysisRows,
            telemetry: telemetry,
            gpuElapsedSeconds: ASHMetalSpatialRuntimePreparationV3
                .gpuElapsedSeconds(completion)
        )
    }
}
