import CoreVideo
import Foundation
@preconcurrency import Metal

enum ASHMetalRuntimeLayoutV3 {
    static let stateStride = 32
    static let dispatchStride = 24
    static let uniformWordCount = 64
    static let telemetryWordCount = 562
    static let summaryWordCount = 18
    static let stateHistogramCount = 512
    static let messageHistogramCount = 16
    static let operatorHistogramCount = 16
}

struct ASHMetalPipelinesV3 {
    let analyzeLuma: MTLComputePipelineState
    let analyzeChroma: MTLComputePipelineState
    let decodeDispatch: MTLComputePipelineState
    let reconstructLuma: MTLComputePipelineState
    let reconstructChroma: MTLComputePipelineState
    let finalizeReduction: MTLComputePipelineState
}

struct ASHMetalBufferSizesV3 {
    let analysisColumns: Int
    let analysisRows: Int
    let dispatchCount: Int
    let stateBytes: Int
    let dispatchBytes: Int
}

struct ASHMetalUniformInputsV3 {
    let source: ASHNV12FrameGeometry
    let destination: ASHNV12FrameGeometry
    let route: ASHSpatialRouteV2
    let lut: ASHMetalRuntimeLUTV3
    let configuration: ASHMetalRuntimeConfigurationV3
    let mapping: ASHMetalRuntimeMappingV3
    let analysisColumns: Int
    let analysisRows: Int
}

enum ASHMetalSpatialRuntimePreparationV3 {
    static func makePipelines(
        device: MTLDevice,
        library: MTLLibrary
    ) throws -> ASHMetalPipelinesV3 {
        func make(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw ASHMetalSpatialRuntimeErrorV3.functionUnavailable(name)
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw ASHMetalSpatialRuntimeErrorV3.pipelineCreationFailed(
                    function: name,
                    reason: String(describing: error)
                )
            }
        }
        return try ASHMetalPipelinesV3(
            analyzeLuma: make("ash_v3_analyze_luma"),
            analyzeChroma: make("ash_v3_analyze_chroma_and_pack_state"),
            decodeDispatch: make("ash_v3_decode_dispatch"),
            reconstructLuma: make("ash_v3_reconstruct_luma"),
            reconstructChroma: make("ash_v3_reconstruct_chroma"),
            finalizeReduction: make("ash_v3_finalize_reduction")
        )
    }

    static func makeImmutableBuffer(
        data: Data,
        label: String,
        device: MTLDevice
    ) throws -> MTLBuffer {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let buffer = device.makeBuffer(
                    bytes: baseAddress,
                    length: bytes.count,
                    options: .storageModeShared
                  ) else {
                throw ASHMetalSpatialRuntimeErrorV3.immutableBufferAllocationFailed(
                    label: label,
                    length: bytes.count
                )
            }
            buffer.label = label
            return buffer
        }
    }

    static func makeDecoderBuffer(device: MTLDevice) throws -> MTLBuffer {
        let decoder = makeDecoderTable()
        return try decoder.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let buffer = device.makeBuffer(
                    bytes: baseAddress,
                    length: bytes.count,
                    options: .storageModeShared
                  ) else {
                throw ASHMetalSpatialRuntimeErrorV3.immutableBufferAllocationFailed(
                    label: "com.mirmir.ash.v3.decoder",
                    length: bytes.count
                )
            }
            buffer.label = "com.mirmir.ash.v3.decoder"
            return buffer
        }
    }

    static func validatedGeometry(
        _ pixelBuffer: CVPixelBuffer,
        expectedRange: ASHVideoCodeRange8Bit,
        expectedSiting: ASHChromaSitingV2?
    ) throws -> ASHNV12FrameGeometry {
        let expectedFormat: OSType = expectedRange == .video
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == expectedFormat else {
            throw ASHMetalSpatialRuntimeErrorV3.invalidPixelFormat(
                expected: expectedFormat,
                observed: format
            )
        }
        let geometry = try ASHNV12FrameCodec.geometry(of: pixelBuffer)
        guard geometry.lumaWidth > 0,
              geometry.lumaHeight > 0,
              geometry.chromaWidth == (geometry.lumaWidth + 1) / 2,
              geometry.chromaHeight == (geometry.lumaHeight + 1) / 2 else {
            throw ASHMetalSpatialRuntimeErrorV3.invalidPlaneGeometry
        }
        guard try ASHNV12FrameCodec.codeRange(for: pixelBuffer) == expectedRange else {
            throw ASHMetalSpatialRuntimeErrorV3.codeRangeMismatch
        }
        if let expectedSiting,
           try ASHNV12FrameCodec.chromaSiting(for: pixelBuffer) != expectedSiting {
            throw ASHMetalSpatialRuntimeErrorV3.chromaSitingMismatch
        }
        return geometry
    }

    static func validateRouteGeometry(
        source: ASHNV12FrameGeometry,
        destination: ASHNV12FrameGeometry,
        route: ASHSpatialRouteV2
    ) throws {
        guard try route.destinationExtent(for: source.lumaWidth) == destination.lumaWidth,
              try route.destinationExtent(for: source.lumaHeight) == destination.lumaHeight,
              try route.destinationExtent(for: source.chromaWidth) == destination.chromaWidth,
              try route.destinationExtent(for: source.chromaHeight) == destination.chromaHeight else {
            throw ASHMetalSpatialRuntimeErrorV3.routeGeometryMismatch
        }
    }

    static func bufferSizes(
        source: ASHNV12FrameGeometry,
        route: ASHSpatialRouteV2,
        step: Int
    ) throws -> ASHMetalBufferSizesV3 {
        guard step > 0 else {
            throw ASHMetalSpatialRuntimeErrorV3.invalidPlaneGeometry
        }
        let columns = (source.lumaWidth + step - 1) / step
        let rows = (source.lumaHeight + step - 1) / step
        let cells = try checkedMultiply(columns, rows)
        let planeDispatches = try checkedMultiply(cells, route.phasePairCount)
        let dispatchCount = try checkedMultiply(planeDispatches, 2)
        return ASHMetalBufferSizesV3(
            analysisColumns: columns,
            analysisRows: rows,
            dispatchCount: dispatchCount,
            stateBytes: try checkedMultiply(cells, ASHMetalRuntimeLayoutV3.stateStride),
            dispatchBytes: try checkedMultiply(
                dispatchCount,
                ASHMetalRuntimeLayoutV3.dispatchStride
            )
        )
    }

    static func writeUniforms(
        to buffer: MTLBuffer,
        inputs: ASHMetalUniformInputsV3
    ) {
        let values = buffer.contents().bindMemory(
            to: UInt32.self,
            capacity: ASHMetalRuntimeLayoutV3.uniformWordCount
        )
        values.initialize(repeating: 0, count: ASHMetalRuntimeLayoutV3.uniformWordCount)
        func integer(_ index: Int, _ value: Int) { values[index] = UInt32(value) }
        func floating(_ index: Int, _ value: Double) {
            values[index] = Float(value).bitPattern
        }
        let selection = inputs.configuration.routeSelection(for: inputs.route)
        integer(0, inputs.source.lumaWidth)
        integer(1, inputs.source.lumaHeight)
        integer(2, inputs.source.chromaWidth)
        integer(3, inputs.source.chromaHeight)
        integer(4, inputs.destination.lumaWidth)
        integer(5, inputs.destination.lumaHeight)
        integer(6, inputs.destination.chromaWidth)
        integer(7, inputs.destination.chromaHeight)
        integer(8, inputs.analysisColumns)
        integer(9, inputs.analysisRows)
        integer(10, Int(selection.analysisGridSourceStep))
        integer(11, inputs.route.scaleNumerator)
        integer(12, inputs.route.scaleDenominator)
        integer(13, inputs.route.phasePairCount)
        integer(14, inputs.configuration.boundaryMode == .clamp ? 0 : 1)
        integer(15, inputs.mapping.codeRange == .video ? 0 : 1)
        integer(16, Int(inputs.mapping.chromaSiting.horizontalLumaOffsetNumerator))
        integer(17, Int(inputs.mapping.chromaSiting.verticalLumaOffsetNumerator))
        integer(18, selection.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        integer(19, selection.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        integer(20, Int(selection.lumaAnisotropyMode.rawValue))
        integer(21, Int(selection.chromaAnisotropyMode.rawValue))
        values[22] = ASHLUTLittleEndianV3.uint32(inputs.lut.immutableBytes, at: 40)
        values[23] = ASHLUTLittleEndianV3.uint32(inputs.lut.immutableBytes, at: 44)
        values[24] = UInt32(inputs.lut.parameterCount)
        values[25] = UInt32(inputs.lut.immutableBytes.count)
        floating(30, inputs.mapping.analyzerConfiguration.riskWeights.laplacian)
        floating(31, inputs.mapping.analyzerConfiguration.riskWeights.alternatingDifference)
        floating(32, inputs.mapping.analyzerConfiguration.epsilon)
        floating(33, inputs.mapping.analyzerConfiguration.chromaEdgeConfidenceThreshold)
        floating(34, inputs.mapping.analyzerConfiguration.bands.edgePresent.low)
        floating(35, inputs.mapping.analyzerConfiguration.bands.edgePresent.high)
        floating(36, inputs.mapping.analyzerConfiguration.bands.coherentStructure.low)
        floating(37, inputs.mapping.analyzerConfiguration.bands.coherentStructure.high)
        floating(38, inputs.mapping.analyzerConfiguration.bands.textureHighFrequency.low)
        floating(39, inputs.mapping.analyzerConfiguration.bands.textureHighFrequency.high)
        floating(40, inputs.mapping.analyzerConfiguration.bands.aliasOrRingingRisk.low)
        floating(41, inputs.mapping.analyzerConfiguration.bands.aliasOrRingingRisk.high)
        floating(42, inputs.mapping.analyzerConfiguration.bands.temporalSupportValid.low)
        floating(43, inputs.mapping.analyzerConfiguration.bands.temporalSupportValid.high)
        floating(44, inputs.mapping.analyzerConfiguration.bands.chromaLumaStructureAligned.low)
        floating(45, inputs.mapping.analyzerConfiguration.bands.chromaLumaStructureAligned.high)
        floating(
            46,
            Double(inputs.configuration.operatorParameters.minimumAnisotropicMagnitudeUNorm15)
                / 32767.0
        )
        floating(
            47,
            Double(inputs.configuration.operatorParameters.minimumAnisotropicCoherenceUNorm15)
                / 32767.0
        )
        floating(
            48,
            Double(inputs.configuration.operatorParameters.riskSuppressionUNorm15) / 32767.0
        )
        floating(
            49,
            Double(inputs.configuration.operatorParameters.lowPassRadiusQ8x8) / 256.0
        )
        values[50] = inputs.configuration.operatorParameters.weightEpsilonF32Bits
    }

    static func readSummary(
        reduction: MTLBuffer,
        summary: MTLBuffer
    ) -> ASHMetalFrameSummaryV3 {
        let reductionValues = reduction.contents().bindMemory(
            to: UInt32.self,
            capacity: ASHMetalRuntimeLayoutV3.telemetryWordCount
        )
        let summaryValues = summary.contents().bindMemory(
            to: UInt32.self,
            capacity: ASHMetalRuntimeLayoutV3.summaryWordCount
        )
        let numericalFallbackCount = summaryValues[7]
        let lumaNumericalFallbackCount = summaryValues[15]
        return ASHMetalFrameSummaryV3(
            stateHistogram: Array(UnsafeBufferPointer(
                start: reductionValues,
                count: ASHMetalRuntimeLayoutV3.stateHistogramCount
            )),
            messageHistogram: Array(UnsafeBufferPointer(
                start: reductionValues.advanced(
                    by: ASHMetalRuntimeLayoutV3.stateHistogramCount
                ),
                count: ASHMetalRuntimeLayoutV3.messageHistogramCount
            )),
            operatorHistogram: Array(UnsafeBufferPointer(
                start: reductionValues.advanced(
                    by: ASHMetalRuntimeLayoutV3.stateHistogramCount
                        + ASHMetalRuntimeLayoutV3.messageHistogramCount
                ),
                count: ASHMetalRuntimeLayoutV3.operatorHistogramCount
            )),
            exactDecodeCount: summaryValues[0],
            correctedDecodeCount: summaryValues[1],
            rejectedDecodeCount: summaryValues[2],
            oneCandidateDispatchCount: summaryValues[3],
            twoCandidateDispatchCount: summaryValues[4],
            dispatchCount: summaryValues[5],
            actualOperatorInvocationCount: summaryValues[6],
            actualLumaOperatorInvocationCount: summaryValues[13],
            actualChromaOperatorInvocationCount: summaryValues[14],
            numericalFallbackCount: numericalFallbackCount,
            lumaNumericalFallbackCount: lumaNumericalFallbackCount,
            chromaNumericalFallbackCount: numericalFallbackCount
                - min(numericalFallbackCount, lumaNumericalFallbackCount),
            affineFallbackCount: summaryValues[16],
            parityRecomputationCount: summaryValues[17],
            sourceAlignedPreservationCount: summaryValues[8],
            lumaOutputCount: summaryValues[9],
            chromaOutputCount: summaryValues[10],
            fatalFaultCount: summaryValues[11],
            analysisCellCount: summaryValues[12]
        )
    }

    static func gpuElapsedSeconds(
        _ completion: MetalCommandBufferCompletion
    ) -> Double? {
        guard let start = completion.gpuStartSeconds,
              let end = completion.gpuEndSeconds,
              end > start else { return nil }
        return end - start
    }

    private static func makeDecoderTable() -> [UInt32] {
        (0..<512).map { rawValue in
            let result = ASHCode.decode(ASHState(validatedRawValue: UInt16(rawValue)))
            let status: UInt32
            switch result.status {
            case .exact: status = 0
            case .corrected: status = 1
            case .uncorrectable: status = 2
            }
            let message: UInt32
            if let bits = result.messageBits,
               let value = try? ASHMessage(bits: bits) {
                message = UInt32(value.rawValue)
            } else {
                message = 0xff
            }
            return message | (status << 8)
        }
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let value = lhs.multipliedReportingOverflow(by: rhs)
        guard !value.overflow, value.partialValue > 0 else {
            throw ASHMetalSpatialRuntimeErrorV3.arithmeticOverflow
        }
        return value.partialValue
    }
}
