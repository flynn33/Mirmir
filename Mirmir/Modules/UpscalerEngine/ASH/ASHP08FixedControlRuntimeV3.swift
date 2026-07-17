import CoreVideo
import Foundation
@preconcurrency import Metal
import os.lock

// The fixed-control comparator mirrors one complete Metal pipeline for auditability.
// swiftlint:disable file_length type_body_length

@available(macOS 15.4, *)
final class ASHP08FixedCompletedFrame: @unchecked Sendable {
    let summary: ASHMetalFrameSummaryV3
    let gpuElapsedSeconds: Double

    private let ring: ASHMetalFrameResourceRingV3
    private let lease = OSAllocatedUnfairLock<ASHMetalFrameResourceLeaseV3?>(
        initialState: nil
    )

    init(
        summary: ASHMetalFrameSummaryV3,
        gpuElapsedSeconds: Double,
        ring: ASHMetalFrameResourceRingV3,
        lease: ASHMetalFrameResourceLeaseV3
    ) {
        self.summary = summary
        self.gpuElapsedSeconds = gpuElapsedSeconds
        self.ring = ring
        self.lease.withLock { $0 = lease }
    }

    func finishAfterAppend() {
        let retained = lease.withLock { value -> ASHMetalFrameResourceLeaseV3? in
            defer { value = nil }
            return value
        }
        if let retained { ring.release(retained) }
    }

    deinit {
        finishAfterAppend()
    }
}

@available(macOS 15.4, *)
final class ASHP08FixedMetalRuntimeV3: @unchecked Sendable {
    private enum Layout {
        static let stateStride = 32
        static let uniformWordCount = 64
        static let telemetryWordCount = 562
        static let summaryWordCount = 18
        static let stateHistogramCount = 512
        static let messageHistogramCount = 16
        static let operatorHistogramCount = 16
    }

    private struct Pipelines {
        let analyzeLuma: MTLComputePipelineState
        let analyzeChroma: MTLComputePipelineState
        let reconstructLuma: MTLComputePipelineState
        let reconstructChroma: MTLComputePipelineState
        let finalizeReduction: MTLComputePipelineState
    }

    private struct Counters {
        var submissionCount: UInt64 = 0
        var completionCount: UInt64 = 0
        var failureCount: UInt64 = 0
        var currentGPUFrameCount = 0
        var peakGPUFrameCount = 0
    }

    let route: ASHSpatialRouteV2
    let descriptorID: UInt8

    private let configuration: ASHLUTLockedConfigurationV3
    private let mapping: ASHLockedVideoMappingV2
    private let lut: ASHLUTLoadedV3
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipelines: Pipelines
    private let ring: ASHMetalFrameResourceRingV3
    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    private let textureCreator = ASHDefaultMetalTextureCreatorV3()
    private let completionBridge = MetalCommandBufferCompletionBridge()

    init(
        route: ASHSpatialRouteV2,
        descriptorID: UInt8,
        artifacts: ASHLockedArtifactSetV3,
        metal: any MetalRenderingService,
        ringCapacity: Int = ASHMetalFrameResourceRingV3.defaultCapacity
    ) throws {
        guard descriptorID < ASHSpatialDescriptorV2.count else {
            throw ASHLockedControlRuntimeV2Error.invalidDescriptorID(Int(descriptorID))
        }
        try artifacts.mapping.validate(configuration: artifacts.configuration)
        self.route = route
        self.descriptorID = descriptorID
        self.configuration = artifacts.configuration
        self.mapping = artifacts.mapping
        self.lut = artifacts.lut(for: route)
        self.device = metal.device
        self.commandQueue = metal.commandQueue
        self.textureCache = metal.textureCache
        self.ring = try ASHMetalFrameResourceRingV3(capacity: ringCapacity)
        guard let library = metal.device.makeDefaultLibrary() else {
            throw ASHMetalSpatialRuntimeErrorV3.defaultLibraryUnavailable
        }
        self.pipelines = try Self.makePipelines(
            device: metal.device,
            library: library,
            route: route,
            descriptorID: descriptorID,
            configuration: artifacts.configuration
        )
    }

    // Resource acquisition, encoding, completion, and summary reopening are one transaction.
    // swiftlint:disable:next function_body_length
    func process(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        frameIndex: Int
    ) async throws -> ASHP08FixedCompletedFrame {
        try Task.checkCancellation()
        let lease = try await ring.acquire()
        var transfersLease = false
        defer {
            if !transfersLease { ring.release(lease) }
        }

        do {
            let sourceGeometry = try validatedGeometry(
                source,
                expectedRange: mapping.codeRange,
                expectedSiting: mapping.chromaSiting
            )
            let destinationGeometry = try validatedGeometry(
                destination,
                expectedRange: mapping.codeRange,
                expectedSiting: nil
            )
            try validateRouteGeometry(
                source: sourceGeometry,
                destination: destinationGeometry
            )
            ASHNV12FrameCodec.setChromaSiting(mapping.chromaSiting, on: destination)

            let sourceLuma = try textureCreator.makeTexture(
                cache: textureCache,
                pixelBuffer: source,
                pixelFormat: .r8Unorm,
                width: sourceGeometry.lumaWidth,
                height: sourceGeometry.lumaHeight,
                plane: 0,
                usage: .shaderRead
            )
            let sourceChroma = try textureCreator.makeTexture(
                cache: textureCache,
                pixelBuffer: source,
                pixelFormat: .rg8Unorm,
                width: sourceGeometry.chromaWidth,
                height: sourceGeometry.chromaHeight,
                plane: 1,
                usage: .shaderRead
            )
            let destinationLuma = try textureCreator.makeTexture(
                cache: textureCache,
                pixelBuffer: destination,
                pixelFormat: .r8Unorm,
                width: destinationGeometry.lumaWidth,
                height: destinationGeometry.lumaHeight,
                plane: 0,
                usage: .shaderWrite
            )
            let destinationChroma = try textureCreator.makeTexture(
                cache: textureCache,
                pixelBuffer: destination,
                pixelFormat: .rg8Unorm,
                width: destinationGeometry.chromaWidth,
                height: destinationGeometry.chromaHeight,
                plane: 1,
                usage: .shaderWrite
            )

            let selection = configuration.routeSelection(for: route)
            let step = Int(selection.analysisGridSourceStep)
            let columns = (sourceGeometry.lumaWidth + step - 1) / step
            let rows = (sourceGeometry.lumaHeight + step - 1) / step
            let cellCount = try checkedMultiply(columns, rows)
            let slot = lease.slot
            let states = try slot.reusableBuffer(
                kind: .stateSamples,
                minimumLength: try checkedMultiply(cellCount, Layout.stateStride),
                device: device
            )
            let reduction = try slot.reusableBuffer(
                kind: .telemetryReduction,
                minimumLength: Layout.telemetryWordCount * MemoryLayout<UInt32>.stride,
                device: device
            )
            let summaryBuffer = try slot.reusableBuffer(
                kind: .telemetrySummary,
                minimumLength: Layout.summaryWordCount * MemoryLayout<UInt32>.stride,
                device: device
            )
            let uniforms = try slot.reusableBuffer(
                kind: .uniforms,
                minimumLength: Layout.uniformWordCount * MemoryLayout<UInt32>.stride,
                device: device
            )
            writeUniforms(
                uniforms,
                source: sourceGeometry,
                destination: destinationGeometry,
                columns: columns,
                rows: rows
            )

            let retainedResources: [AnyObject] = [
                source as AnyObject,
                destination as AnyObject,
                sourceLuma.reference as AnyObject,
                sourceLuma.texture,
                sourceChroma.reference as AnyObject,
                sourceChroma.texture,
                destinationLuma.reference as AnyObject,
                destinationLuma.texture,
                destinationChroma.reference as AnyObject,
                destinationChroma.texture,
                states,
                reduction,
                summaryBuffer,
                uniforms
            ]
            slot.retainFrameResources(retainedResources)
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw ASHMetalSpatialRuntimeErrorV3.commandBufferCreationFailed(
                    frameIndex: frameIndex
                )
            }
            try encode(
                commandBuffer: commandBuffer,
                sourceLuma: sourceLuma.texture,
                sourceChroma: sourceChroma.texture,
                destinationLuma: destinationLuma.texture,
                destinationChroma: destinationChroma.texture,
                states: states,
                reduction: reduction,
                summary: summaryBuffer,
                uniforms: uniforms,
                columns: columns,
                rows: rows,
                destination: destinationGeometry
            )
            markSubmission()
            let completion = try await completionBridge.commitAndWait(
                DefaultMetalCommandBufferSubmission(
                    commandBuffer: commandBuffer,
                    context: MetalCommandBufferExecutionContext(
                        label: "com.mirmir.ash.p08.fixed.\(route.rawValue)",
                        frameIndex: frameIndex
                    )
                ),
                retaining: MetalCommandBufferRetainedResources(retainedResources)
            )
            markCompletion(failed: false)
            guard let start = completion.gpuStartSeconds,
                  let end = completion.gpuEndSeconds,
                  end > start else {
                throw ASHMetalSpatialRuntimeErrorV3.commandExecutionFailed(
                    status: completion.status.name,
                    reason: "GPU timestamps unavailable"
                )
            }
            let frameSummary = readSummary(reduction, summary: summaryBuffer)
            guard frameSummary.fatalFaultCount == 0 else {
                throw ASHMetalSpatialRuntimeErrorV3.fatalNumericalFault(
                    count: frameSummary.fatalFaultCount
                )
            }
            transfersLease = true
            return ASHP08FixedCompletedFrame(
                summary: frameSummary,
                gpuElapsedSeconds: end - start,
                ring: ring,
                lease: lease
            )
        } catch {
            markCompletion(failed: true)
            throw error
        }
    }

    func diagnostics() -> ASHMetalRuntimeDiagnosticsV3 {
        let snapshot = counters.withLock { $0 }
        return ASHMetalRuntimeDiagnosticsV3(
            ring: ring.snapshot(),
            commandCompletionMode: .asynchronousCompletionHandler,
            submissionCount: snapshot.submissionCount,
            completionCount: snapshot.completionCount,
            failureCount: snapshot.failureCount,
            currentGPUFrameCount: snapshot.currentGPUFrameCount,
            peakGPUFrameCount: snapshot.peakGPUFrameCount
        )
    }

    private static func makePipelines(
        device: MTLDevice,
        library: MTLLibrary,
        route: ASHSpatialRouteV2,
        descriptorID: UInt8,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> Pipelines {
        func ordinary(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw ASHMetalSpatialRuntimeErrorV3.functionUnavailable(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        let semantics = ASHLUTLeafCompilerV3.apply(
            delta: ASHLUTSemanticDeltaV3(
                orientation: 0,
                support: 0,
                detail: 0,
                regularization: 0
            ),
            to: descriptorID,
            parameters: configuration.operatorParameters,
            steps: configuration.semanticSteps
        )
        guard semantics.descriptorID == descriptorID else {
            throw ASHLockedControlRuntimeV2Error.invalidControlMode
        }
        let locked = configuration.operatorParameters
        let constants = MTLFunctionConstantValues()
        var descriptor = UInt32(descriptorID)
        constants.setConstantValue(&descriptor, type: .uint, index: 100)
        let values: [(Int, Float)] = [
            (101, Float(Double(locked.minimumAnisotropicMagnitudeUNorm15) / 32_767.0)),
            (102, Float(Double(locked.minimumAnisotropicCoherenceUNorm15) / 32_767.0)),
            (103, Float(Double(semantics.detailGainQ12) / 4_096.0)),
            (104, Float(Double(semantics.relaxedLimiterAlphaQ12) / 4_096.0)),
            (105, Float(Double(locked.riskSuppressionUNorm15) / 32_767.0)),
            (106, Float(Double(locked.lowPassRadiusQ8x8) / 256.0)),
            (107, Float(bitPattern: locked.weightEpsilonF32Bits)),
            (108, Float(Double(semantics.supportRadiusQ8x8) / 256.0))
        ]
        for (index, value) in values {
            var mutableValue = value
            constants.setConstantValue(
                &mutableValue,
                type: .float,
                index: index
            )
        }
        func specialized(_ name: String) throws -> MTLComputePipelineState {
            let function = try library.makeFunction(
                name: name,
                constantValues: constants
            )
            return try device.makeComputePipelineState(function: function)
        }
        _ = route
        return try Pipelines(
            analyzeLuma: ordinary("ash_v3_analyze_luma"),
            analyzeChroma: ordinary("ash_v3_analyze_chroma_and_pack_state"),
            reconstructLuma: specialized("ash_p08_fixed_reconstruct_luma"),
            reconstructChroma: specialized("ash_p08_fixed_reconstruct_chroma"),
            finalizeReduction: ordinary("ash_v3_finalize_reduction")
        )
    }

    private func validatedGeometry(
        _ buffer: CVPixelBuffer,
        expectedRange: ASHVideoCodeRange8Bit,
        expectedSiting: ASHChromaSitingV2?
    ) throws -> ASHNV12FrameGeometry {
        let expectedFormat = expectedRange == .video
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard CVPixelBufferGetPixelFormatType(buffer) == expectedFormat else {
            throw ASHMetalSpatialRuntimeErrorV3.invalidPixelFormat(
                expected: expectedFormat,
                observed: CVPixelBufferGetPixelFormatType(buffer)
            )
        }
        let geometry = try ASHNV12FrameCodec.geometry(of: buffer)
        guard geometry.chromaWidth == (geometry.lumaWidth + 1) / 2,
              geometry.chromaHeight == (geometry.lumaHeight + 1) / 2 else {
            throw ASHMetalSpatialRuntimeErrorV3.invalidPlaneGeometry
        }
        guard try ASHNV12FrameCodec.codeRange(for: buffer) == expectedRange else {
            throw ASHMetalSpatialRuntimeErrorV3.codeRangeMismatch
        }
        if let expectedSiting,
           try ASHNV12FrameCodec.chromaSiting(for: buffer) != expectedSiting {
            throw ASHMetalSpatialRuntimeErrorV3.chromaSitingMismatch
        }
        return geometry
    }

    private func validateRouteGeometry(
        source: ASHNV12FrameGeometry,
        destination: ASHNV12FrameGeometry
    ) throws {
        guard try route.destinationExtent(for: source.lumaWidth) == destination.lumaWidth,
              try route.destinationExtent(for: source.lumaHeight) == destination.lumaHeight,
              try route.destinationExtent(for: source.chromaWidth) == destination.chromaWidth,
              try route.destinationExtent(for: source.chromaHeight) == destination.chromaHeight else {
            throw ASHMetalSpatialRuntimeErrorV3.routeGeometryMismatch
        }
    }

    private func writeUniforms(
        _ buffer: MTLBuffer,
        source: ASHNV12FrameGeometry,
        destination: ASHNV12FrameGeometry,
        columns: Int,
        rows: Int
    ) {
        let values = buffer.contents().bindMemory(
            to: UInt32.self,
            capacity: Layout.uniformWordCount
        )
        values.initialize(repeating: 0, count: Layout.uniformWordCount)
        func integer(_ index: Int, _ value: Int) { values[index] = UInt32(value) }
        func floating(_ index: Int, _ value: Double) {
            values[index] = Float(value).bitPattern
        }
        let selection = configuration.routeSelection(for: route)
        integer(0, source.lumaWidth)
        integer(1, source.lumaHeight)
        integer(2, source.chromaWidth)
        integer(3, source.chromaHeight)
        integer(4, destination.lumaWidth)
        integer(5, destination.lumaHeight)
        integer(6, destination.chromaWidth)
        integer(7, destination.chromaHeight)
        integer(8, columns)
        integer(9, rows)
        integer(10, Int(selection.analysisGridSourceStep))
        integer(11, route.scaleNumerator)
        integer(12, route.scaleDenominator)
        integer(13, route.phasePairCount)
        integer(14, configuration.boundaryMode == .clamp ? 0 : 1)
        integer(15, mapping.codeRange == .video ? 0 : 1)
        integer(16, Int(mapping.chromaSiting.horizontalLumaOffsetNumerator))
        integer(17, Int(mapping.chromaSiting.verticalLumaOffsetNumerator))
        integer(18, selection.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        integer(19, selection.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        integer(20, Int(selection.lumaAnisotropyMode.rawValue))
        integer(21, Int(selection.chromaAnisotropyMode.rawValue))
        values[22] = ASHLUTLittleEndianV3.uint32(lut.immutableBytes, at: 40)
        values[23] = ASHLUTLittleEndianV3.uint32(lut.immutableBytes, at: 44)
        integer(24, lut.parameters.count)
        integer(25, lut.immutableBytes.count)
        let analyzer = mapping.analyzerConfiguration
        floating(30, analyzer.riskWeights.laplacian)
        floating(31, analyzer.riskWeights.alternatingDifference)
        floating(32, analyzer.epsilon)
        floating(33, analyzer.chromaEdgeConfidenceThreshold)
        floating(34, analyzer.bands.edgePresent.low)
        floating(35, analyzer.bands.edgePresent.high)
        floating(36, analyzer.bands.coherentStructure.low)
        floating(37, analyzer.bands.coherentStructure.high)
        floating(38, analyzer.bands.textureHighFrequency.low)
        floating(39, analyzer.bands.textureHighFrequency.high)
        floating(40, analyzer.bands.aliasOrRingingRisk.low)
        floating(41, analyzer.bands.aliasOrRingingRisk.high)
        floating(42, analyzer.bands.temporalSupportValid.low)
        floating(43, analyzer.bands.temporalSupportValid.high)
        floating(44, analyzer.bands.chromaLumaStructureAligned.low)
        floating(45, analyzer.bands.chromaLumaStructureAligned.high)
        let locked = configuration.operatorParameters
        floating(46, Double(locked.minimumAnisotropicMagnitudeUNorm15) / 32_767.0)
        floating(47, Double(locked.minimumAnisotropicCoherenceUNorm15) / 32_767.0)
        floating(48, Double(locked.riskSuppressionUNorm15) / 32_767.0)
        floating(49, Double(locked.lowPassRadiusQ8x8) / 256.0)
        values[50] = locked.weightEpsilonF32Bits
    }

    // Explicit Metal resources keep the comparator's bound pipeline inputs visible.
    // swiftlint:disable:next function_parameter_count
    private func encode(
        commandBuffer: MTLCommandBuffer,
        sourceLuma: MTLTexture,
        sourceChroma: MTLTexture,
        destinationLuma: MTLTexture,
        destinationChroma: MTLTexture,
        states: MTLBuffer,
        reduction: MTLBuffer,
        summary: MTLBuffer,
        uniforms: MTLBuffer,
        columns: Int,
        rows: Int,
        destination: ASHNV12FrameGeometry
    ) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw ASHMetalSpatialRuntimeErrorV3.encoderCreationFailed(stage: "clear")
        }
        blit.fill(buffer: reduction, range: 0..<(Layout.telemetryWordCount * 4), value: 0)
        blit.fill(buffer: summary, range: 0..<(Layout.summaryWordCount * 4), value: 0)
        blit.endEncoding()
        try encode2D(
            commandBuffer,
            label: "analyze_luma",
            pipeline: pipelines.analyzeLuma,
            width: columns,
            height: rows
        ) { encoder in
            encoder.setTexture(sourceLuma, index: 0)
            encoder.setBuffer(states, offset: 0, index: 0)
            encoder.setBuffer(uniforms, offset: 0, index: 1)
        }
        try encode2D(
            commandBuffer,
            label: "analyze_chroma",
            pipeline: pipelines.analyzeChroma,
            width: columns,
            height: rows
        ) { encoder in
            encoder.setTexture(sourceChroma, index: 0)
            encoder.setBuffer(states, offset: 0, index: 0)
            encoder.setBuffer(uniforms, offset: 0, index: 1)
            encoder.setBuffer(reduction, offset: 0, index: 2)
        }
        try encode2D(
            commandBuffer,
            label: "fixed_luma",
            pipeline: pipelines.reconstructLuma,
            width: destination.lumaWidth,
            height: destination.lumaHeight
        ) { encoder in
            encoder.setTexture(sourceLuma, index: 0)
            encoder.setTexture(destinationLuma, index: 1)
            encoder.setBuffer(states, offset: 0, index: 0)
            encoder.setBuffer(uniforms, offset: 0, index: 1)
            encoder.setBuffer(reduction, offset: 0, index: 2)
        }
        try encode2D(
            commandBuffer,
            label: "fixed_chroma",
            pipeline: pipelines.reconstructChroma,
            width: destination.chromaWidth,
            height: destination.chromaHeight
        ) { encoder in
            encoder.setTexture(sourceChroma, index: 0)
            encoder.setTexture(destinationChroma, index: 1)
            encoder.setBuffer(states, offset: 0, index: 0)
            encoder.setBuffer(uniforms, offset: 0, index: 1)
            encoder.setBuffer(reduction, offset: 0, index: 2)
        }
        try encode1D(
            commandBuffer,
            label: "finalize",
            pipeline: pipelines.finalizeReduction,
            count: Layout.summaryWordCount
        ) { encoder in
            encoder.setBuffer(reduction, offset: 0, index: 0)
            encoder.setBuffer(summary, offset: 0, index: 1)
        }
    }

    private func encode2D(
        _ commandBuffer: MTLCommandBuffer,
        label: String,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int,
        bindings: (MTLComputeCommandEncoder) -> Void
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ASHMetalSpatialRuntimeErrorV3.encoderCreationFailed(stage: label)
        }
        encoder.label = "com.mirmir.ash.p08.\(label)"
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

    private func encode1D(
        _ commandBuffer: MTLCommandBuffer,
        label: String,
        pipeline: MTLComputePipelineState,
        count: Int,
        bindings: (MTLComputeCommandEncoder) -> Void
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ASHMetalSpatialRuntimeErrorV3.encoderCreationFailed(stage: label)
        }
        encoder.label = "com.mirmir.ash.p08.\(label)"
        encoder.setComputePipelineState(pipeline)
        bindings(encoder)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
    }

    private func readSummary(
        _ reduction: MTLBuffer,
        summary: MTLBuffer
    ) -> ASHMetalFrameSummaryV3 {
        let reductionValues = reduction.contents().bindMemory(
            to: UInt32.self,
            capacity: Layout.telemetryWordCount
        )
        let values = summary.contents().bindMemory(
            to: UInt32.self,
            capacity: Layout.summaryWordCount
        )
        let fallbackCount = values[7]
        let lumaFallbackCount = values[15]
        return ASHMetalFrameSummaryV3(
            stateHistogram: Array(UnsafeBufferPointer(
                start: reductionValues,
                count: Layout.stateHistogramCount
            )),
            messageHistogram: Array(UnsafeBufferPointer(
                start: reductionValues.advanced(by: Layout.stateHistogramCount),
                count: Layout.messageHistogramCount
            )),
            operatorHistogram: Array(UnsafeBufferPointer(
                start: reductionValues.advanced(
                    by: Layout.stateHistogramCount + Layout.messageHistogramCount
                ),
                count: Layout.operatorHistogramCount
            )),
            exactDecodeCount: values[0],
            correctedDecodeCount: values[1],
            rejectedDecodeCount: values[2],
            oneCandidateDispatchCount: values[3],
            twoCandidateDispatchCount: values[4],
            dispatchCount: values[5],
            actualOperatorInvocationCount: values[6],
            actualLumaOperatorInvocationCount: values[13],
            actualChromaOperatorInvocationCount: values[14],
            numericalFallbackCount: fallbackCount,
            lumaNumericalFallbackCount: lumaFallbackCount,
            chromaNumericalFallbackCount: fallbackCount - min(fallbackCount, lumaFallbackCount),
            affineFallbackCount: values[16],
            parityRecomputationCount: values[17],
            sourceAlignedPreservationCount: values[8],
            lumaOutputCount: values[9],
            chromaOutputCount: values[10],
            fatalFaultCount: values[11],
            analysisCellCount: values[12]
        )
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow, result.partialValue > 0 else {
            throw ASHMetalSpatialRuntimeErrorV3.arithmeticOverflow
        }
        return result.partialValue
    }

    private func markSubmission() {
        counters.withLock { state in
            state.submissionCount &+= 1
            state.currentGPUFrameCount += 1
            state.peakGPUFrameCount = max(
                state.peakGPUFrameCount,
                state.currentGPUFrameCount
            )
        }
    }

    private func markCompletion(failed: Bool) {
        counters.withLock { state in
            if state.currentGPUFrameCount > 0 { state.currentGPUFrameCount -= 1 }
            if failed {
                state.failureCount &+= 1
            } else {
                state.completionCount &+= 1
            }
        }
    }
}

// swiftlint:enable file_length type_body_length
