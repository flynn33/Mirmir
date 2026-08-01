import CoreVideo
import Foundation
@preconcurrency import Metal

// Exhaustive route/plane/phase/descriptor parity remains one auditable producer.
// swiftlint:disable file_length type_body_length

@available(macOS 15.4, *)
enum ASHP08DescriptorParityRuntime {
    private struct ProbeOutput: Equatable {
        let value0Bits: UInt32
        let value1Bits: UInt32
        let state: UInt32
        let primaryMessage: UInt32
        let descriptor: UInt32
        let phase: UInt32
        let plane: UInt32
        let invocationCount: UInt32
        let fallbackCount: UInt32
        let fatalCount: UInt32
        let lutWord0: UInt32
        let lutWord1: UInt32
        let lutWord2: UInt32
        let lutWord3: UInt32
        let lutWord4: UInt32
        let lutWord5: UInt32

        var values: [Float] {
            plane == 0
                ? [Float(bitPattern: value0Bits)]
                : [Float(bitPattern: value0Bits), Float(bitPattern: value1Bits)]
        }

        var lutBytes: Data {
            [lutWord0, lutWord1, lutWord2, lutWord3, lutWord4, lutWord5]
                .withUnsafeBytes { Data($0) }
        }
    }

    private struct ProbeRun: Equatable {
        let rows: [ProbeOutput]
        let completion: MetalCommandBufferCompletion
    }

    // The row builder is intentionally atomic so coverage and comparisons cannot diverge.
    // swiftlint:disable:next function_body_length
    static func measure(context: ASHP08NativeContext) async throws -> [String: Any] {
        guard MemoryLayout<ProbeOutput>.size == 64,
              MemoryLayout<ProbeOutput>.stride == 64 else {
            throw ASHP08NativeError.invalidArtifact(
                "descriptor parity result ABI is not 64 bytes"
            )
        }
        let source = try ASHP08NativeSupport.makePixelBuffer(width: 16, height: 16)
        try fillSyntheticSource(source)
        let inputSHA256 = try ASHP08NativeSupport.pixelBufferSHA256(source)
        let sourceFrame = try ASHNV12FrameCodec.extract(from: source)
        let luma = try ASHNV12FrameCodec.normalizedPlane(
            sourceFrame.luma,
            channel: .luma
        )
        let cb = try ASHNV12FrameCodec.normalizedPlane(sourceFrame.cb, channel: .chroma)
        let cr = try ASHNV12FrameCodec.normalizedPlane(sourceFrame.cr, channel: .chroma)

        var routes: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            let first = try await runProbe(
                route: route,
                artifacts: context.artifacts,
                metal: context.metal,
                source: source
            )
            let second = try await runProbe(
                route: route,
                artifacts: context.artifacts,
                metal: context.metal,
                source: source
            )
            guard first.rows.count == route.phasePairCount * 2 * 16,
                  second.rows.count == first.rows.count else {
                throw ASHP08NativeError.invalidArtifact(
                    "descriptor parity row count differs for \(route.rawValue)"
                )
            }
            let orderedFirst = first.rows.sorted(by: rowOrder)
            let orderedSecond = second.rows.sorted(by: rowOrder)
            let lut = context.artifacts.lut(for: route)
            var rows: [[String: Any]] = []
            for (metal, repeatMetal) in zip(orderedFirst, orderedSecond) {
                guard metal.plane == repeatMetal.plane,
                      metal.phase == repeatMetal.phase,
                      metal.descriptor == repeatMetal.descriptor else {
                    throw ASHP08NativeError.invalidArtifact(
                        "descriptor parity repeat order differs"
                    )
                }
                let planeRole: ASHLUTPlaneRoleV3 = metal.plane == 0 ? .luma : .chroma
                let state = ASHState(validatedRawValue: 0)
                let entry = try lut.entry(
                    state: state,
                    planeRole: planeRole,
                    phaseOrdinal: Int(metal.phase),
                    context: .spatialOnly
                )
                let cpu = try cpuProbeValues(
                    route: route,
                    planeRole: planeRole,
                    phaseOrdinal: Int(metal.phase),
                    descriptorID: UInt8(metal.descriptor),
                    entry: entry,
                    lut: lut,
                    artifacts: context.artifacts,
                    luma: luma,
                    cb: cb,
                    cr: cr
                )
                let metalValues = metal.values
                guard metalValues.count == cpu.count else {
                    throw ASHP08NativeError.invalidArtifact(
                        "descriptor parity channel count differs"
                    )
                }
                let errors = zip(metalValues, cpu).map {
                    abs(Double($0.0) - $0.1)
                }
                let maximumError = errors.max() ?? 0
                let rms = (errors.map { $0 * $0 }.reduce(0, +)
                    / Double(errors.count)).squareRoot()
                let maximumCodeDifference = zip(metalValues, cpu).map {
                    abs(
                        quantizedCode(Double($0.0), luma: metal.plane == 0)
                            - quantizedCode($0.1, luma: metal.plane == 0)
                    )
                }.max() ?? 0
                let expectedLUTBytes = rawLUTEntryBytes(
                    lut: lut,
                    state: state,
                    planeRole: planeRole,
                    phaseOrdinal: Int(metal.phase)
                )
                rows.append([
                    "plane": metal.plane == 0 ? "y" : "cbcr",
                    "phase_ordinal": Int(metal.phase),
                    "descriptor_id": Int(metal.descriptor),
                    "fixture_id": "synthetic_descriptor_fixture_v1",
                    "input_sha256": inputSHA256,
                    "cpu_output_sha256": outputSHA256(cpu.map(Float.init)),
                    "metal_repeat_output_sha256_values": [
                        outputSHA256(metalValues),
                        outputSHA256(repeatMetal.values)
                    ],
                    "maximum_normalized_absolute_error": maximumError,
                    "normalized_rms_error": rms,
                    "maximum_output_code_difference": maximumCodeDifference,
                    "finite": metalValues.allSatisfy(\.isFinite)
                        && cpu.allSatisfy(\.isFinite),
                    "state_bytes_equal": metal.state == UInt32(state.rawValue),
                    "message_bytes_equal": metal.primaryMessage
                        == UInt32(entry.primaryMessage.rawValue),
                    "lut_lookup_bytes_equal": metal.lutBytes == expectedLUTBytes
                ])
            }
            routes.append([
                "route": route.rawValue,
                "phase_count": route.phasePairCount,
                "rows": rows
            ])
        }
        return [
            "same_device_repeat_minimum": 2,
            "pixel_determinism_scope":
                "same device, identical locked fixture bytes, decoded plane bytes",
            "routes": routes
        ]
    }

    static func capture(
        route: ASHSpatialRouteV2,
        context: ASHP08NativeContext,
        outputURL: URL
    ) async throws -> [String: Any] {
        guard outputURL.path.hasPrefix("/"),
              outputURL.standardizedFileURL.path == outputURL.path,
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ASHP08NativeError.invalidPath(
                "GPU capture output must be an absent absolute normalized path"
            )
        }
        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ASHP08NativeError.invalidPath("GPU capture parent is absent")
        }
        let source = try ASHP08NativeSupport.makePixelBuffer(width: 16, height: 16)
        try fillSyntheticSource(source)
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = context.metal.commandQueue
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = outputURL
        let manager = MTLCaptureManager.shared()
        try manager.startCapture(with: descriptor)
        let probe: ProbeRun
        do {
            probe = try await runProbe(
                route: route,
                artifacts: context.artifacts,
                metal: context.metal,
                source: source
            )
            guard probe.rows.count == route.phasePairCount * 2 * 16,
                  probe.completion.status.isCompleted,
                  probe.completion.error == nil else {
                throw ASHP08NativeError.invalidArtifact(
                    "captured descriptor parity completion or row count differs"
                )
            }
            manager.stopCapture()
        } catch {
            manager.stopCapture()
            throw error
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ASHP08NativeError.invalidArtifact("GPU capture archive is absent")
        }
        let commandBufferError: Any
        if let error = probe.completion.error {
            commandBufferError = [
                "domain": error.domain,
                "code": error.code,
                "message": error.message
            ]
        } else {
            commandBufferError = NSNull()
        }
        let phases = Array(0..<route.phasePairCount)
        let descriptors = Array(0..<16)
        return [
            "route": route.rawValue,
            "archive_name": outputURL.lastPathComponent,
            "capture_scope":
                "exhaustive synthetic route-plane-phase-descriptor parity fixtures; not a natural-frame coverage claim",
            "capture_succeeded": true,
            "command_buffer_count": 1,
            "command_buffer_status": probe.completion.status.name,
            "command_buffer_error": commandBufferError,
            "compute_encoder_count": 1,
            "kernel_names": ["ash_v3_descriptor_parity_probe"],
            "plane_coverage": [
                ["plane": "y", "phase_ordinals": phases, "descriptor_ids": descriptors],
                ["plane": "cbcr", "phase_ordinals": phases, "descriptor_ids": descriptors]
            ]
        ]
    }

    // One encoder construction binds every probe resource and completion check.
    // swiftlint:disable:next function_body_length
    private static func runProbe(
        route: ASHSpatialRouteV2,
        artifacts: ASHLockedArtifactSetV3,
        metal: any MetalRenderingService,
        source: CVPixelBuffer
    ) async throws -> ProbeRun {
        guard let library = MirmirDefaultMetalLibrary.make(on: metal.device),
              let function = library.makeFunction(
                name: "ash_v3_descriptor_parity_probe"
              ) else {
            throw ASHMetalSpatialRuntimeErrorV3.functionUnavailable(
                "ash_v3_descriptor_parity_probe"
            )
        }
        let pipeline = try await metal.device.makeComputePipelineState(function: function)
        let geometry = try ASHNV12FrameCodec.geometry(of: source)
        let textureCreator = ASHDefaultMetalTextureCreatorV3()
        let sourceLuma = try textureCreator.makeTexture(
            cache: metal.textureCache,
            pixelBuffer: source,
            pixelFormat: .r8Unorm,
            width: geometry.lumaWidth,
            height: geometry.lumaHeight,
            plane: 0,
            usage: .shaderRead
        )
        let sourceChroma = try textureCreator.makeTexture(
            cache: metal.textureCache,
            pixelBuffer: source,
            pixelFormat: .rg8Unorm,
            width: geometry.chromaWidth,
            height: geometry.chromaHeight,
            plane: 1,
            usage: .shaderRead
        )
        let lut = artifacts.lut(for: route)
        guard let lutBuffer = lut.immutableBytes.withUnsafeBytes({ (bytes: UnsafeRawBufferPointer) -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return metal.device.makeBuffer(
                bytes: base,
                length: bytes.count,
                options: .storageModeShared
            )
        }) else {
            throw ASHMetalSpatialRuntimeErrorV3.immutableBufferAllocationFailed(
                label: "p08 descriptor LUT",
                length: lut.immutableBytes.count
            )
        }
        var state = probeState()
        guard let stateBuffer = metal.device.makeBuffer(
            bytes: &state,
            length: MemoryLayout<ASHMetalStateSampleABIV3>.stride,
            options: .storageModeShared
        ) else {
            throw ASHMetalSpatialRuntimeErrorV3.immutableBufferAllocationFailed(
                label: "p08 descriptor state",
                length: MemoryLayout<ASHMetalStateSampleABIV3>.stride
            )
        }
        var uniforms = try probeUniforms(
            route: route,
            lut: lut,
            artifacts: artifacts,
            sourceGeometry: geometry
        )
        guard let uniformBuffer = uniforms.withUnsafeMutableBytes({ (bytes: UnsafeMutableRawBufferPointer) -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return metal.device.makeBuffer(
                bytes: base,
                length: bytes.count,
                options: .storageModeShared
            )
        }) else {
            throw ASHMetalSpatialRuntimeErrorV3.immutableBufferAllocationFailed(
                label: "p08 descriptor uniforms",
                length: uniforms.count * MemoryLayout<UInt32>.stride
            )
        }
        let count = route.phasePairCount * 2 * 16
        guard let outputBuffer = metal.device.makeBuffer(
            length: count * MemoryLayout<ProbeOutput>.stride,
            options: .storageModeShared
        ) else {
            throw ASHMetalSpatialRuntimeErrorV3.immutableBufferAllocationFailed(
                label: "p08 descriptor output",
                length: count * MemoryLayout<ProbeOutput>.stride
            )
        }
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ASHMetalSpatialRuntimeErrorV3.encoderCreationFailed(
                stage: "p08 descriptor parity"
            )
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceLuma.texture, index: 0)
        encoder.setTexture(sourceChroma.texture, index: 1)
        encoder.setBuffer(stateBuffer, offset: 0, index: 0)
        encoder.setBuffer(lutBuffer, offset: 0, index: 1)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 2)
        encoder.setBuffer(outputBuffer, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(pipeline.maxTotalThreadsPerThreadgroup, count),
                height: 1,
                depth: 1
            )
        )
        encoder.endEncoding()
        let completion = try await MetalCommandBufferCompletionBridge().commitAndWait(
            DefaultMetalCommandBufferSubmission(
                commandBuffer: commandBuffer,
                context: MetalCommandBufferExecutionContext(
                    label: "com.mirmir.ash.p08.descriptor-parity.\(route.rawValue)"
                )
            ),
            retaining: MetalCommandBufferRetainedResources([
                source as AnyObject,
                sourceLuma.reference as AnyObject,
                sourceLuma.texture,
                sourceChroma.reference as AnyObject,
                sourceChroma.texture,
                lutBuffer,
                stateBuffer,
                uniformBuffer,
                outputBuffer,
                pipeline
            ])
        )
        let rows = Array(UnsafeBufferPointer(
            start: outputBuffer.contents().bindMemory(
                to: ProbeOutput.self,
                capacity: count
            ),
            count: count
        ))
        return ProbeRun(rows: rows, completion: completion)
    }

    private static func probeUniforms(
        route: ASHSpatialRouteV2,
        lut: ASHLUTLoadedV3,
        artifacts: ASHLockedArtifactSetV3,
        sourceGeometry: ASHNV12FrameGeometry
    ) throws -> [UInt32] {
        var values = [UInt32](repeating: 0, count: 64)
        func integer(_ index: Int, _ value: Int) { values[index] = UInt32(value) }
        func floating(_ index: Int, _ value: Double) {
            values[index] = Float(value).bitPattern
        }
        let selection = artifacts.configuration.routeSelection(for: route)
        integer(0, sourceGeometry.lumaWidth)
        integer(1, sourceGeometry.lumaHeight)
        integer(2, sourceGeometry.chromaWidth)
        integer(3, sourceGeometry.chromaHeight)
        integer(4, try route.destinationExtent(for: sourceGeometry.lumaWidth))
        integer(5, try route.destinationExtent(for: sourceGeometry.lumaHeight))
        integer(6, try route.destinationExtent(for: sourceGeometry.chromaWidth))
        integer(7, try route.destinationExtent(for: sourceGeometry.chromaHeight))
        integer(8, 1)
        integer(9, 1)
        integer(10, Int(selection.analysisGridSourceStep))
        integer(11, route.scaleNumerator)
        integer(12, route.scaleDenominator)
        integer(13, route.phasePairCount)
        integer(14, artifacts.configuration.boundaryMode == .clamp ? 0 : 1)
        integer(15, artifacts.mapping.codeRange == .video ? 0 : 1)
        integer(16, Int(artifacts.mapping.chromaSiting.horizontalLumaOffsetNumerator))
        integer(17, Int(artifacts.mapping.chromaSiting.verticalLumaOffsetNumerator))
        integer(18, selection.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        integer(19, selection.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        integer(20, Int(selection.lumaAnisotropyMode.rawValue))
        integer(21, Int(selection.chromaAnisotropyMode.rawValue))
        values[22] = ASHLUTLittleEndianV3.uint32(lut.immutableBytes, at: 40)
        values[23] = ASHLUTLittleEndianV3.uint32(lut.immutableBytes, at: 44)
        values[24] = UInt32(lut.parameters.count)
        values[25] = UInt32(lut.immutableBytes.count)
        let analyzer = artifacts.mapping.analyzerConfiguration
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
        let locked = artifacts.configuration.operatorParameters
        floating(46, Double(locked.minimumAnisotropicMagnitudeUNorm15) / 32_767)
        floating(47, Double(locked.minimumAnisotropicCoherenceUNorm15) / 32_767)
        floating(48, Double(locked.riskSuppressionUNorm15) / 32_767)
        floating(49, Double(locked.lowPassRadiusQ8x8) / 256)
        values[50] = locked.weightEpsilonF32Bits
        return values
    }

    private static func probeState() -> ASHMetalStateSampleABIV3 {
        var state = ASHMetalStateSampleABIV3()
        state.state = ASHState(validatedRawValue: 0).rawValue
        state.orientationQ15 = 2_607
        state.magnitudeQ15 = 24_575
        state.coherenceQ15 = 26_214
        state.textureQ15 = 12_288
        state.riskQ15 = 4_096
        state.chromaAlignmentQ15 = 16_384
        state.localMinimum = 0
        state.localMaximum = UInt16.max
        return state
    }

    private static func rawLUTEntryBytes(
        lut: ASHLUTLoadedV3,
        state: ASHState,
        planeRole: ASHLUTPlaneRoleV3,
        phaseOrdinal: Int
    ) -> Data {
        let entriesPerPlane = lut.route.phasePairCount * 4 * 256
        let logicalIndex = Int(planeRole.rawValue) * entriesPerPlane
            + phaseOrdinal * 4 * 256
            + Int(state.rawValue >> 1)
        let offset = Int(ASHLUTLittleEndianV3.uint32(lut.immutableBytes, at: 44))
            + logicalIndex * 24
        return lut.immutableBytes.subdata(in: offset..<(offset + 24))
    }

    // Explicit inputs make each CPU/Metal parity dependency visible at the call site.
    // swiftlint:disable:next function_parameter_count
    private static func cpuProbeValues(
        route: ASHSpatialRouteV2,
        planeRole: ASHLUTPlaneRoleV3,
        phaseOrdinal: Int,
        descriptorID: UInt8,
        entry: ASHLUTLoadedEntryV3,
        lut: ASHLUTLoadedV3,
        artifacts: ASHLockedArtifactSetV3,
        luma: ASHSpatialPlaneV2,
        cb: ASHSpatialPlaneV2,
        cr: ASHSpatialPlaneV2
    ) throws -> [Double] {
        let parameterIndex = Int(entry.parameterIndex)
        guard lut.parameters.indices.contains(parameterIndex) else {
            throw ASHP08NativeError.invalidArtifact("descriptor parameter index is invalid")
        }
        let slot = lut.parameters[parameterIndex].primary
        let selection = artifacts.configuration.routeSelection(for: route)
        let mode = planeRole == .luma
            ? selection.lumaAnisotropyMode
            : selection.chromaAnisotropyMode
        let state = probeState()
        let baseOrientation = Double(Float(state.orientationQ15) / 32_767 * .pi)
        var orientation = baseOrientation + Double(slot.delta.orientation) * (.pi / 4)
        orientation.formTruncatingRemainder(dividingBy: .pi)
        if orientation < 0 { orientation += .pi }
        let sidecar = try ASHSpatialSidecarV2(
            orientationRadians: orientation,
            normalizedMagnitude: Double(Float(state.magnitudeQ15) / 32_767),
            coherence: Double(Float(state.coherenceQ15) / 32_767),
            risk: Double(Float(state.riskQ15) / 32_767),
            chromaAlignment: Double(Float(state.chromaAlignmentQ15) / 32_767),
            localMinimum: 0,
            localMaximum: 1
        )
        let locked = artifacts.configuration.operatorParameters
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: Double(mode.anisotropyStrengthQ12) / 4_096,
            minimumAnisotropicMagnitude:
                Double(slot.minimumAnisotropicMagnitudeUNorm15) / 32_767,
            minimumAnisotropicCoherence:
                Double(slot.minimumAnisotropicCoherenceUNorm15) / 32_767,
            controlledDetailGain: Double(slot.detailGainQ12) / 4_096,
            relaxedLimiterAlpha: Double(slot.relaxedLimiterAlphaQ12) / 4_096,
            riskDetailSuppressionThreshold: Double(slot.riskSuppressionUNorm15) / 32_767,
            lowPassRadius: Double(locked.lowPassRadiusQ8x8) / 256,
            weightEpsilon: Double(Float(bitPattern: slot.weightEpsilonF32Bits)),
            supportRadius: Double(slot.supportRadiusQ8x8) / 256
        )
        let effectiveDescriptorID = mode.usesAnisotropy
            ? descriptorID
            : descriptorID & ~UInt8(2)
        let descriptor = try ASHSpatialDescriptorV2(id: effectiveDescriptorID)
        let horizontalPhase = phaseOrdinal % route.scaleNumerator
        let verticalPhase = phaseOrdinal / route.scaleNumerator
        let coordinates = ASHSpatialSourceCoordinatesV2(
            horizontal: ASHSpatialRationalCoordinateV2(
                numerator: Int64(3 * route.scaleNumerator
                    + horizontalPhase * route.scaleDenominator),
                denominator: Int64(route.scaleNumerator)
            ),
            vertical: ASHSpatialRationalCoordinateV2(
                numerator: Int64(3 * route.scaleNumerator
                    + verticalPhase * route.scaleDenominator),
                denominator: Int64(route.scaleNumerator)
            )
        )
        return try (planeRole == .luma ? [luma] : [cb, cr]).map { plane in
            try ASHSpatialOperatorBankV2.evaluateSample(ASHSpatialSampleRequestV2(
                plane: plane,
                destinationColumn: 0,
                destinationRow: 0,
                route: route,
                coordinatePolicy: .halfPixelCenter,
                descriptor: descriptor,
                sidecar: sidecar,
                boundary: artifacts.configuration.boundaryMode,
                parameters: parameters,
                coordinateOverride: coordinates
            )).value
        }
    }

    private static func fillSyntheticSource(_ pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                throw ASHP08NativeError.mediaFailure("synthetic source plane is absent")
            }
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let activeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 0 ? 1 : 2)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<activeWidth {
                    bytes[row * stride + column] = UInt8(
                        (row * 29 + column * 17 + plane * 47) % 200 + 20
                    )
                }
            }
        }
    }

    private static func outputSHA256(_ values: [Float]) -> String {
        let words = values.map(\.bitPattern)
        return words.withUnsafeBytes {
            ASHP08NativeSupport.sha256(Data($0))
        }
    }

    private static func quantizedCode(_ value: Double, luma: Bool) -> Int {
        let clamped = min(1, max(0, value))
        return Int((16 + clamped * (luma ? 219 : 224)).rounded())
    }

    private static func rowOrder(_ lhs: ProbeOutput, _ rhs: ProbeOutput) -> Bool {
        if lhs.plane != rhs.plane { return lhs.plane < rhs.plane }
        if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
        return lhs.descriptor < rhs.descriptor
    }
}

// swiftlint:enable file_length type_body_length
