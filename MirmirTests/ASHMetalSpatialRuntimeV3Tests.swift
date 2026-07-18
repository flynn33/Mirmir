import CoreVideo
import Foundation
@preconcurrency import Metal
import XCTest
import os.lock
@testable import Mirmir

// Exhaustive Metal parity and lifecycle coverage is intentionally colocated.
// swiftlint:disable file_length type_body_length

@available(macOS 15.4, *)
final class ASHMetalSpatialRuntimeV3Tests: XCTestCase {
    private struct SendablePixelBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    private struct StateProbeInput {
        let magnitude: Float
        let coherence: Float
        let texture: Float
        let risk: Float
        let chromaAlignment: Float
        let tangent: Float
    }

    private struct DescriptorProbeOutput: Equatable {
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

    private struct FailingTextureCreator: ASHMetalTextureCreatingV3 {
        func makeTexture(
            cache _: CVMetalTextureCache,
            pixelBuffer _: CVPixelBuffer,
            pixelFormat _: MTLPixelFormat,
            width _: Int,
            height _: Int,
            plane: Int,
            usage _: MTLTextureUsage
        ) throws -> ASHMetalTexturePlaneV3 {
            throw ASHMetalSpatialRuntimeErrorV3.textureCreationFailed(
                plane: plane,
                status: -6_601
            )
        }
    }

    private struct FailingCommandCompleter: ASHMetalCommandCompletingV3 {
        func commitAndComplete(
            _ submission: any MetalCommandBufferSubmitting,
            retaining _: MetalCommandBufferRetainedResources
        ) async throws -> MetalCommandBufferCompletion {
            throw MetalCommandBufferExecutionError.executionFailed(
                MetalCommandBufferCompletion(
                    context: submission.context,
                    status: .error,
                    error: MetalCommandBufferErrorSnapshot(
                        domain: "ASHMetalSpatialRuntimeV3Tests",
                        code: 7,
                        message: "injected command failure"
                    )
                )
            )
        }
    }

    private final class DelayedCommandCompleter: ASHMetalCommandCompletingV3,
        @unchecked Sendable {
        // The gate belongs exclusively to this test completer.
        // swiftlint:disable:next nesting
        private struct GateState {
            var isReleased = false
            var continuation: CheckedContinuation<Void, Never>?
        }

        private let onCommit: @Sendable () -> Void
        private let gate = OSAllocatedUnfairLock(initialState: GateState())

        init(onCommit: @escaping @Sendable () -> Void) {
            self.onCommit = onCommit
        }

        func commitAndComplete(
            _ submission: any MetalCommandBufferSubmitting,
            retaining resources: MetalCommandBufferRetainedResources
        ) async throws -> MetalCommandBufferCompletion {
            let onCommit = onCommit
            let detached = Task.detached {
                try await MetalCommandBufferCompletionBridge().commitAndWait(
                    submission,
                    retaining: resources,
                    onCommit: onCommit
                )
            }
            let completion = try await detached.value
            await withCheckedContinuation { continuation in
                let resumeImmediately = gate.withLock { state -> Bool in
                    if state.isReleased { return true }
                    state.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
            try Task.checkCancellation()
            return completion
        }

        func release() {
            let continuation = gate.withLock { state -> CheckedContinuation<Void, Never>? in
                state.isReleased = true
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume()
        }
    }

    func testSwiftAndMetalPackedABIsMatch() {
        XCTAssertEqual(MemoryLayout<ASHMetalStateSampleABIV3>.size, 32)
        XCTAssertEqual(MemoryLayout<ASHMetalStateSampleABIV3>.stride, 32)
        XCTAssertEqual(MemoryLayout<ASHMetalStateSampleABIV3>.offset(of: \.state), 0)
        XCTAssertEqual(MemoryLayout<ASHMetalStateSampleABIV3>.offset(of: \.flags), 2)
        XCTAssertEqual(
            MemoryLayout<ASHMetalStateSampleABIV3>.offset(of: \.orientationQ15),
            4
        )
        XCTAssertEqual(
            MemoryLayout<ASHMetalStateSampleABIV3>.offset(of: \.chromaAlignmentQ15),
            16
        )
        XCTAssertEqual(
            MemoryLayout<ASHMetalStateSampleABIV3>.offset(of: \.motionXQ8x8),
            22
        )
        XCTAssertEqual(
            MemoryLayout<ASHMetalStateSampleABIV3>.offset(of: \.reserved1),
            28
        )

        XCTAssertEqual(MemoryLayout<ASHMetalDispatchABIV3>.size, 24)
        XCTAssertEqual(MemoryLayout<ASHMetalDispatchABIV3>.stride, 24)
        XCTAssertEqual(
            MemoryLayout<ASHMetalDispatchABIV3>.offset(of: \.primaryDescriptor),
            4
        )
        XCTAssertEqual(
            MemoryLayout<ASHMetalDispatchABIV3>.offset(of: \.primaryWeightQ16),
            8
        )
        XCTAssertEqual(
            MemoryLayout<ASHMetalDispatchABIV3>.offset(of: \.parameterIndex),
            16
        )
        XCTAssertEqual(
            MemoryLayout<ASHMetalDispatchABIV3>.offset(of: \.provenanceCRC32),
            20
        )
    }

    func testDevelopmentStateReadbackIncrementsMeasuredGPUReadbackCounter() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let telemetry = DefaultASHTelemetryRecorder(emitsSignposts: false)
        telemetry.beginRun(id: "gpu-readback-counter")
        let runtime = try ASHMetalSpatialRuntimeV3(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal,
            telemetry: telemetry
        )
        let source = try makePixelBuffer(width: 8, height: 4)
        let destination = try makePixelBuffer(width: 16, height: 8)
        fill(source)
        let frame = try await runtime.process(
            source: source,
            into: destination,
            context: ASHMetalFrameContextV3(frameIndex: 0)
        )
        defer { frame.finishAfterAppend() }
        XCTAssertEqual(
            runtime.diagnostics().commandCompletionMode,
            .asynchronousCompletionHandler
        )

        XCTAssertEqual(
            telemetry.snapshot().counters[
                ASHTelemetryCounter.fullFrameGPUReadbacks.rawValue
            ],
            0
        )
        _ = frame.developmentParityStateValues()
        XCTAssertEqual(
            telemetry.snapshot().counters[
                ASHTelemetryCounter.fullFrameGPUReadbacks.rawValue
            ],
            1
        )
    }

    func testDirect2xLumaParityAndExactReductionCounters() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let source = try makePixelBuffer(width: 8, height: 4)
        fill(source)
        let referenceDestination = try makePixelBuffer(width: 16, height: 8)
        let metalDestination = try makePixelBuffer(width: 16, height: 8)

        let reference = try ASHLockedUpscaleBackendV3(
            route: .direct2x,
            artifacts: artifacts
        )
        try await reference.process(source: source, into: referenceDestination)

        let runtime = try ASHMetalSpatialRuntimeV3(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal
        )
        let frame = try await runtime.process(
            source: source,
            into: metalDestination,
            context: ASHMetalFrameContextV3(frameIndex: 0)
        )
        defer { frame.finishAfterAppend() }

        let referenceLuma = readPlane(referenceDestination, plane: 0)
        let metalLuma = readPlane(metalDestination, plane: 0)
        XCTAssertEqual(referenceLuma.count, metalLuma.count)
        XCTAssertLessThanOrEqual(maximumAbsoluteError(referenceLuma, metalLuma), 1)

        let step = Int(
            artifacts.configuration.routes.direct2x.analysisGridSourceStep
        )
        let expectedCells = UInt32(((8 + step - 1) / step) * ((4 + step - 1) / step))
        let expectedDispatches = expectedCells
            * UInt32(ASHSpatialRouteV2.direct2x.phasePairCount)
            * 2
        XCTAssertEqual(frame.summary.analysisCellCount, expectedCells)
        XCTAssertEqual(frame.summary.dispatchCount, expectedDispatches)
        XCTAssertEqual(frame.summary.lumaOutputCount, 128)
        XCTAssertEqual(frame.summary.chromaOutputCount, 64)
        XCTAssertEqual(
            frame.summary.actualLumaOperatorInvocationCount
                + frame.summary.actualChromaOperatorInvocationCount,
            frame.summary.actualOperatorInvocationCount
        )
        XCTAssertEqual(frame.summary.fatalFaultCount, 0)
        XCTAssertEqual(frame.summary.stateHistogram.reduce(0, +), expectedCells)
        XCTAssertEqual(
            frame.summary.oneCandidateDispatchCount
                + frame.summary.twoCandidateDispatchCount,
            frame.summary.dispatchCount
        )
        XCTAssertEqual(
            runtime.constructionCounters,
            ASHMetalRuntimeConstructionCountersV3(
                pipelineCreationCount: 6,
                immutableLUTBufferCreationCount: 1,
                immutableDecoderBufferCreationCount: 1,
                textureCacheCreationCount: 0,
                runtimeTreeGenerationCount: 0,
                runtimeJSONLoadCount: 0
            )
        )
    }

    func testStatePackingIsExactAtEveryBandPointAndSectorTie() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let configuration = artifacts.mapping.analyzerConfiguration
        var namedInputs: [(String, StateProbeInput)] = []
        let bands: [(String, ASHVideoAnalyzerV2ThresholdBand)] = [
            ("edge", configuration.bands.edgePresent),
            ("coherence", configuration.bands.coherentStructure),
            ("texture", configuration.bands.textureHighFrequency),
            ("risk", configuration.bands.aliasOrRingingRisk),
            ("temporal_forced_off", configuration.bands.temporalSupportValid),
            ("chroma", configuration.bands.chromaLumaStructureAligned)
        ]
        for (name, band) in bands {
            for (point, value) in [
                ("low", band.low),
                ("mid", (band.low + band.high) * 0.5),
                ("high", band.high)
            ] {
                var input = StateProbeInput(
                    magnitude: 0,
                    coherence: 0,
                    texture: 0,
                    risk: 0,
                    chromaAlignment: 0,
                    tangent: 0
                )
                switch name {
                case "edge":
                    input = StateProbeInput(
                        magnitude: Float(value), coherence: 0, texture: 0,
                        risk: 0, chromaAlignment: 0, tangent: 0
                    )
                case "coherence":
                    input = StateProbeInput(
                        magnitude: 1, coherence: Float(value), texture: 0,
                        risk: 0, chromaAlignment: 0, tangent: 0
                    )
                case "texture":
                    input = StateProbeInput(
                        magnitude: 1, coherence: 0, texture: Float(value),
                        risk: 0, chromaAlignment: 0, tangent: 0
                    )
                case "risk":
                    input = StateProbeInput(
                        magnitude: 1, coherence: 0, texture: 0,
                        risk: Float(value), chromaAlignment: 0, tangent: 0
                    )
                case "chroma":
                    input = StateProbeInput(
                        magnitude: 1, coherence: 0, texture: 0,
                        risk: 0, chromaAlignment: Float(value), tangent: 0
                    )
                default:
                    break
                }
                namedInputs.append(("\(name)_\(point)", input))
            }
        }
        for sector in 0..<4 {
            let tie = Float.pi / 8 + Float(sector) * Float.pi / 4
            namedInputs.append(("sector_\(sector)_below", sectorInput(tie.nextDown)))
            namedInputs.append(("sector_\(sector)_tie", sectorInput(tie)))
            namedInputs.append(("sector_\(sector)_above", sectorInput(tie.nextUp)))
        }

        let metalStates = try await runStatePackProbe(
            namedInputs.map(\.1),
            configuration: configuration
        )
        XCTAssertEqual(metalStates.count, namedInputs.count)
        for (index, item) in namedInputs.enumerated() {
            let input = item.1
            let expected = try ASHVideoAnalyzerV2.packState(
                measurements: ASHVideoAnalyzerV2Measurements(
                    tensorXX: 0,
                    tensorYY: 0,
                    tensorXY: 0,
                    normalizedGradientMagnitude: Double(input.magnitude),
                    structureCoherence: Double(input.coherence),
                    edgeNormalRadians: 0,
                    edgeTangentRadians: Double(input.tangent),
                    orientationSector: ASHVideoAnalyzerV2.quantizeTangentSector(
                        Double(input.tangent)
                    ),
                    textureEnergy: Double(input.texture),
                    riskProxy: Double(input.risk),
                    localNoiseEstimate: 0,
                    chromaAlignment: Double(input.chromaAlignment),
                    chromaEdgeConfidence: 0,
                    localMinimumY: 0,
                    localMaximumY: 1
                ),
                history: nil,
                temporalEvidence: nil,
                configuration: configuration
            )
            XCTAssertEqual(metalStates[index], expected.rawValue, item.0)
        }
    }

    // Exhaustive parity keeps route, plane, repeat, and exact-state checks atomic.
    // swiftlint:disable:next function_body_length
    func testBothRoutesAllNV12PlanesAreParityBoundAndRepeatDeterministic() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let source = try makePixelBuffer(width: 8, height: 4)
        fill(source)
        let sourceFrame = try ASHNV12FrameCodec.extract(from: source)

        for route in ASHSpatialRouteV2.allCases {
            let width = try route.destinationExtent(for: 8)
            let height = try route.destinationExtent(for: 4)
            let referenceDestination = try makePixelBuffer(width: width, height: height)
            let firstDestination = try makePixelBuffer(width: width, height: height)
            let secondDestination = try makePixelBuffer(width: width, height: height)
            let reference = try ASHLockedUpscaleBackendV3(
                route: route,
                artifacts: artifacts
            )
            try await reference.process(source: source, into: referenceDestination)
            let referenceSummary = try XCTUnwrap(reference.lastDebugSummary)
            let preparedReference = try ASHLockedRuntimeV3.prepareFrame(
                lut: artifacts.lut(for: route),
                configuration: artifacts.configuration,
                luma: sourceFrame.luma,
                cb: sourceFrame.cb,
                cr: sourceFrame.cr,
                chromaSiting: sourceFrame.chromaSiting,
                analyzerConfiguration: artifacts.mapping.analyzerConfiguration
            )
            let referenceStates = preparedReference.analysisGrid.cells.map {
                $0.analysis.state.rawValue
            }

            let runtime = try ASHMetalSpatialRuntimeV3(
                route: route,
                artifacts: artifacts,
                metal: metal
            )
            let first = try await runtime.process(
                source: source,
                into: firstDestination,
                context: ASHMetalFrameContextV3(frameIndex: 0)
            )
            let second = try await runtime.process(
                source: source,
                into: secondDestination,
                context: ASHMetalFrameContextV3(frameIndex: 1)
            )
            defer {
                first.finishAfterAppend()
                second.finishAfterAppend()
            }

            XCTAssertEqual(
                first.developmentParityStateValues(),
                referenceStates,
                route.rawValue
            )
            XCTAssertEqual(
                second.developmentParityStateValues(),
                referenceStates,
                route.rawValue
            )
            XCTAssertEqual(first.summary, second.summary, route.rawValue)
            for plane in 0..<2 {
                let cpuBytes = readPlane(referenceDestination, plane: plane)
                let firstBytes = readPlane(firstDestination, plane: plane)
                let secondBytes = readPlane(secondDestination, plane: plane)
                XCTAssertEqual(firstBytes, secondBytes, "\(route.rawValue) plane \(plane)")
                XCTAssertLessThanOrEqual(
                    maximumAbsoluteError(cpuBytes, firstBytes),
                    1,
                    "\(route.rawValue) plane \(plane)"
                )
            }
            XCTAssertEqual(
                first.summary.exactDecodeCount,
                UInt32(referenceSummary.exactDecodeCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.correctedDecodeCount,
                UInt32(referenceSummary.correctedDecodeCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.rejectedDecodeCount,
                UInt32(referenceSummary.rejectedDecodeCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.affineFallbackCount,
                UInt32(referenceSummary.affineFallbackCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.parityRecomputationCount,
                UInt32(referenceSummary.parityRecomputationCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.dispatchCount,
                UInt32(referenceSummary.dispatchRecordCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.actualOperatorInvocationCount,
                UInt32(referenceSummary.actualOperatorInvocationCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.actualLumaOperatorInvocationCount,
                UInt32(referenceSummary.actualLumaOperatorInvocationCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.actualChromaOperatorInvocationCount,
                UInt32(referenceSummary.actualChromaOperatorInvocationCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.actualLumaOperatorInvocationCount
                    + first.summary.actualChromaOperatorInvocationCount,
                first.summary.actualOperatorInvocationCount,
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.lumaNumericalFallbackCount,
                UInt32(referenceSummary.lumaNumericalFallbackCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.chromaNumericalFallbackCount,
                UInt32(referenceSummary.chromaNumericalFallbackCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.lumaNumericalFallbackCount
                    + first.summary.chromaNumericalFallbackCount,
                first.summary.numericalFallbackCount,
                route.rawValue
            )
            XCTAssertLessThanOrEqual(
                first.summary.actualLumaOperatorInvocationCount,
                first.summary.lumaOutputCount * 2
                    + first.summary.lumaNumericalFallbackCount,
                route.rawValue
            )
            XCTAssertLessThanOrEqual(
                first.summary.actualChromaOperatorInvocationCount,
                first.summary.chromaOutputCount * 2
                    + first.summary.chromaNumericalFallbackCount,
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.numericalFallbackCount,
                UInt32(referenceSummary.numericalFallbackCount),
                route.rawValue
            )
            XCTAssertEqual(
                first.summary.sourceAlignedPreservationCount,
                UInt32(referenceSummary.sourceAlignedPreservationCount),
                route.rawValue
            )
            let referenceOperatorHistogram = referenceSummary.lumaOperatorHistogram
                .merging(referenceSummary.chromaOperatorHistogram, uniquingKeysWith: +)
            for descriptor in 0..<16 {
                XCTAssertEqual(
                    first.summary.operatorHistogram[descriptor],
                    UInt32(referenceOperatorHistogram[UInt8(descriptor), default: 0]),
                    "\(route.rawValue) descriptor \(descriptor)"
                )
            }
        }
    }

    func testVideoRangeExcursionsPreserveAnalysisAndClampReconstruction() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let source = try makePixelBuffer(width: 16, height: 8)
        fillVideoRangeExcursions(source)
        let sourceFrame = try ASHNV12FrameCodec.extract(from: source)

        for route in ASHSpatialRouteV2.allCases {
            let width = try route.destinationExtent(for: 16)
            let height = try route.destinationExtent(for: 8)
            let referenceDestination = try makePixelBuffer(width: width, height: height)
            let metalDestination = try makePixelBuffer(width: width, height: height)
            let reference = try ASHLockedUpscaleBackendV3(
                route: route,
                artifacts: artifacts
            )
            try await reference.process(source: source, into: referenceDestination)
            let preparedReference = try ASHLockedRuntimeV3.prepareFrame(
                lut: artifacts.lut(for: route),
                configuration: artifacts.configuration,
                luma: sourceFrame.luma,
                cb: sourceFrame.cb,
                cr: sourceFrame.cr,
                chromaSiting: sourceFrame.chromaSiting,
                analyzerConfiguration: artifacts.mapping.analyzerConfiguration
            )
            let referenceStates = preparedReference.analysisGrid.cells.map {
                $0.analysis.state.rawValue
            }
            let runtime = try ASHMetalSpatialRuntimeV3(
                route: route,
                artifacts: artifacts,
                metal: metal
            )
            let completed = try await runtime.process(
                source: source,
                into: metalDestination,
                context: ASHMetalFrameContextV3(frameIndex: 0)
            )
            defer { completed.finishAfterAppend() }

            XCTAssertEqual(
                completed.developmentParityStateValues(),
                referenceStates,
                "\(route.rawValue) analysis states"
            )
            for plane in 0..<2 {
                let cpuBytes = readPlane(referenceDestination, plane: plane)
                let metalBytes = readPlane(metalDestination, plane: plane)
                XCTAssertEqual(
                    cpuBytes.count,
                    metalBytes.count,
                    "\(route.rawValue) plane \(plane)"
                )
                XCTAssertLessThanOrEqual(
                    maximumAbsoluteError(cpuBytes, metalBytes),
                    1,
                    "\(route.rawValue) plane \(plane)"
                )
            }
        }
    }

    func testEveryRoutePlanePhaseDescriptorRowExecutesOnMetalWithExactLookup() async throws {
        XCTAssertEqual(MemoryLayout<DescriptorProbeOutput>.size, 64)
        XCTAssertEqual(MemoryLayout<DescriptorProbeOutput>.stride, 64)
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let source = try makePixelBuffer(width: 16, height: 16)
        fill(source)
        let sourceFrame = try ASHNV12FrameCodec.extract(from: source)
        let luma = try ASHNV12FrameCodec.normalizedPlane(sourceFrame.luma, channel: .luma)
        let cb = try ASHNV12FrameCodec.normalizedPlane(sourceFrame.cb, channel: .chroma)
        let cr = try ASHNV12FrameCodec.normalizedPlane(sourceFrame.cr, channel: .chroma)
        let sourceState = ASHState(validatedRawValue: 0)
        var coverage: Set<String> = []
        var squaredError = 0.0
        var numericValueCount = 0
        var maximumError = 0.0

        for route in ASHSpatialRouteV2.allCases {
            let first = try await runDescriptorProbe(
                route: route,
                artifacts: artifacts,
                metal: metal,
                source: source
            )
            let second = try await runDescriptorProbe(
                route: route,
                artifacts: artifacts,
                metal: metal,
                source: source
            )
            XCTAssertEqual(first, second, "\(route.rawValue) repeat")
            XCTAssertEqual(first.count, route.phasePairCount * 2 * 16)
            let lut = artifacts.lut(for: route)

            for row in first {
                let label = "\(route.rawValue):\(row.plane):\(row.phase):\(row.descriptor)"
                coverage.insert(label)
                XCTAssertEqual(row.state, UInt32(sourceState.rawValue), label)
                XCTAssertLessThan(row.plane, 2, label)
                XCTAssertLessThan(row.phase, UInt32(route.phasePairCount), label)
                XCTAssertLessThan(row.descriptor, 16, label)
                XCTAssertEqual(row.fallbackCount, 0, label)
                XCTAssertEqual(row.fatalCount, 0, label)
                XCTAssertEqual(row.invocationCount, row.plane == 0 ? 1 : 2, label)

                let planeRole: ASHLUTPlaneRoleV3 = row.plane == 0 ? .luma : .chroma
                let entry = try lut.entry(
                    state: sourceState,
                    planeRole: planeRole,
                    phaseOrdinal: Int(row.phase),
                    context: .spatialOnly
                )
                XCTAssertEqual(row.primaryMessage, UInt32(entry.primaryMessage.rawValue), label)
                XCTAssertEqual(
                    row.lutBytes,
                    rawLUTEntryBytes(
                        lut: lut,
                        state: sourceState,
                        planeRole: planeRole,
                        phaseOrdinal: Int(row.phase)
                    ),
                    label
                )

                let expected = try cpuDescriptorProbeValues(
                    route: route,
                    planeRole: planeRole,
                    phaseOrdinal: Int(row.phase),
                    descriptorID: UInt8(row.descriptor),
                    entry: entry,
                    lut: lut,
                    artifacts: artifacts,
                    luma: luma,
                    cb: cb,
                    cr: cr
                )
                XCTAssertEqual(row.values.count, expected.count, label)
                for (metalValue, cpuValue) in zip(row.values, expected) {
                    XCTAssertTrue(metalValue.isFinite, label)
                    let error = abs(Double(metalValue) - cpuValue)
                    maximumError = max(maximumError, error)
                    squaredError += error * error
                    numericValueCount += 1
                    XCTAssertLessThanOrEqual(
                        abs(quantizedCode(Double(metalValue), luma: row.plane == 0)
                            - quantizedCode(cpuValue, luma: row.plane == 0)),
                        1,
                        label
                    )
                }
            }
        }

        XCTAssertEqual(coverage.count, 416)
        XCTAssertEqual(numericValueCount, 624)
        XCTAssertLessThanOrEqual(maximumError, 2.0 / 65_535.0)
        XCTAssertLessThanOrEqual(
            (squaredError / Double(numericValueCount)).squareRoot(),
            1.0 / 65_535.0
        )
    }

    func testControlledTwoCandidateProbeCountsCbAndCrEvaluationsSeparately() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let source = try makePixelBuffer(width: 16, height: 16)
        fill(source)
        let lut = artifacts.lut(for: .direct2x)
        let target = try XCTUnwrap(
            ASHLUTStateOrdinalTableV3.validStates.lazy.compactMap { state in
                (0..<ASHSpatialRouteV2.direct2x.phasePairCount).first { phase in
                    guard let entry = try? lut.entry(
                        state: state,
                        planeRole: .chroma,
                        phaseOrdinal: phase,
                        context: .spatialOnly
                    ) else { return false }
                    return entry.secondaryDescriptorID != nil
                }.map { (state, $0) }
            }.first
        )

        let rows = try await runDescriptorProbe(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal,
            source: source,
            probeState: target.0,
            controlledTwoCandidate: true
        )
        let chroma = try XCTUnwrap(rows.first {
            $0.plane == 1 && $0.phase == target.1 && $0.descriptor == 0
        })
        XCTAssertEqual(chroma.fallbackCount, 0)
        XCTAssertEqual(chroma.fatalCount, 0)
        XCTAssertEqual(chroma.invocationCount, 4)
    }

    func testTextureCommandCreationAndCommandExecutionFailuresAreTypedAndReleaseSlots() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let source = try makePixelBuffer(width: 8, height: 4)
        let destination = try makePixelBuffer(width: 16, height: 8)
        fill(source)

        let textureRuntime = try ASHMetalSpatialRuntimeV3(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal,
            textureCreator: FailingTextureCreator()
        )
        do {
            _ = try await textureRuntime.process(
                source: source,
                into: destination,
                context: ASHMetalFrameContextV3(frameIndex: 1)
            )
            XCTFail("Expected texture creation failure")
        } catch {
            XCTAssertEqual(
                error as? ASHMetalSpatialRuntimeErrorV3,
                .textureCreationFailed(plane: 0, status: -6_601)
            )
        }
        XCTAssertEqual(textureRuntime.diagnostics().ring.inFlightSlotCount, 0)

        let creationRuntime = try ASHMetalSpatialRuntimeV3(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal,
            commandBufferFactory: { _ in nil }
        )
        do {
            _ = try await creationRuntime.process(
                source: source,
                into: destination,
                context: ASHMetalFrameContextV3(frameIndex: 2)
            )
            XCTFail("Expected command-buffer creation failure")
        } catch {
            XCTAssertEqual(
                error as? ASHMetalSpatialRuntimeErrorV3,
                .commandBufferCreationFailed(frameIndex: 2)
            )
        }
        XCTAssertEqual(creationRuntime.diagnostics().ring.inFlightSlotCount, 0)

        let executionRuntime = try ASHMetalSpatialRuntimeV3(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal,
            commandCompleter: FailingCommandCompleter()
        )
        do {
            _ = try await executionRuntime.process(
                source: source,
                into: destination,
                context: ASHMetalFrameContextV3(frameIndex: 3)
            )
            XCTFail("Expected command execution failure")
        } catch {
            XCTAssertEqual(
                error as? ASHMetalSpatialRuntimeErrorV3,
                .commandExecutionFailed(
                    status: "error",
                    reason: "injected command failure"
                )
            )
        }
        let executionDiagnostics = executionRuntime.diagnostics()
        XCTAssertEqual(executionDiagnostics.ring.inFlightSlotCount, 0)
        XCTAssertEqual(executionDiagnostics.submissionCount, 1)
        XCTAssertEqual(executionDiagnostics.completionCount, 1)
        XCTAssertEqual(executionDiagnostics.failureCount, 1)
        XCTAssertEqual(executionDiagnostics.currentGPUFrameCount, 0)
    }

    func testCancellationAfterCommitRetainsSlotUntilGPUCompletionBoundary() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let committed = expectation(description: "command committed")
        let completer = DelayedCommandCompleter { committed.fulfill() }
        let runtime = try ASHMetalSpatialRuntimeV3(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal,
            commandCompleter: completer
        )
        let source = try makePixelBuffer(width: 8, height: 4)
        let destination = try makePixelBuffer(width: 16, height: 8)
        fill(source)
        let sendableSource = SendablePixelBuffer(value: source)
        let sendableDestination = SendablePixelBuffer(value: destination)
        let task = Task { [sendableSource, sendableDestination] in
            try await runtime.process(
                source: sendableSource.value,
                into: sendableDestination.value,
                context: ASHMetalFrameContextV3(frameIndex: 9)
            )
        }
        await fulfillment(of: [committed], timeout: 5)
        task.cancel()
        XCTAssertEqual(runtime.diagnostics().ring.inFlightSlotCount, 1)
        completer.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation after command submission")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let diagnostics = runtime.diagnostics()
        XCTAssertEqual(diagnostics.ring.inFlightSlotCount, 0)
        XCTAssertEqual(diagnostics.ring.releaseCount, 1)
        XCTAssertEqual(diagnostics.submissionCount, 1)
        XCTAssertEqual(diagnostics.completionCount, 1)
        XCTAssertEqual(diagnostics.failureCount, 0)
        XCTAssertEqual(diagnostics.currentGPUFrameCount, 0)
    }

    func testThreeHundredFramesRemainWithinTheRetainedThreeSlotBound() async throws {
        let artifacts = try await ASHLockedReleaseTestSupportV3.artifacts()
        let metal = try DefaultMetalRenderingService()
        let runtime = try ASHMetalSpatialRuntimeV3(
            route: .direct2x,
            artifacts: artifacts,
            metal: metal
        )
        let source = try makePixelBuffer(width: 2, height: 2)
        let destination = try makePixelBuffer(width: 4, height: 4)
        fill(source)
        for frameIndex in 0..<300 {
            let frame = try await runtime.process(
                source: source,
                into: destination,
                context: ASHMetalFrameContextV3(frameIndex: frameIndex)
            )
            frame.finishAfterAppend()
        }
        let diagnostics = runtime.diagnostics()
        XCTAssertEqual(diagnostics.submissionCount, 300)
        XCTAssertEqual(diagnostics.completionCount, 300)
        XCTAssertEqual(diagnostics.failureCount, 0)
        XCTAssertEqual(diagnostics.currentGPUFrameCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.peakGPUFrameCount, 3)
        XCTAssertEqual(diagnostics.ring.capacity, 3)
        XCTAssertEqual(diagnostics.ring.availableSlotCount, 3)
        XCTAssertEqual(diagnostics.ring.inFlightSlotCount, 0)
        XCTAssertEqual(diagnostics.ring.waitingTaskCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.ring.peakInFlightSlotCount, 3)
        XCTAssertEqual(diagnostics.ring.acquisitionCount, 300)
        XCTAssertEqual(diagnostics.ring.releaseCount, 300)
    }

    // Probe setup mirrors the complete bound Metal encoder in one helper.
    // swiftlint:disable:next function_body_length
    private func runDescriptorProbe(
        route: ASHSpatialRouteV2,
        artifacts: ASHLockedArtifactSetV3,
        metal: any MetalRenderingService,
        source: CVPixelBuffer,
        probeState: ASHState = ASHState(validatedRawValue: 0),
        controlledTwoCandidate: Bool = false
    ) async throws -> [DescriptorProbeOutput] {
        let library = try XCTUnwrap(metal.device.makeDefaultLibrary())
        let function = try XCTUnwrap(
            library.makeFunction(name: "ash_v3_descriptor_parity_probe")
        )
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
        let lutBuffer = try lut.immutableBytes.withUnsafeBytes { bytes in
            try XCTUnwrap(metal.device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
        var state = descriptorProbeState(probeState)
        let stateBuffer = try XCTUnwrap(metal.device.makeBuffer(
            bytes: &state,
            length: MemoryLayout<ASHMetalStateSampleABIV3>.stride,
            options: .storageModeShared
        ))
        var uniforms = try descriptorProbeUniforms(
            route: route,
            lut: lut,
            artifacts: artifacts,
            sourceGeometry: geometry
        )
        uniforms[29] = controlledTwoCandidate ? 1 : 0
        let uniformBuffer = try uniforms.withUnsafeMutableBytes { bytes in
            try XCTUnwrap(metal.device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
        let count = route.phasePairCount * 2 * 16
        let outputBuffer = try XCTUnwrap(metal.device.makeBuffer(
            length: count * MemoryLayout<DescriptorProbeOutput>.stride,
            options: .storageModeShared
        ))
        let commandBuffer = try XCTUnwrap(metal.commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
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
        _ = try await MetalCommandBufferCompletionBridge().commitAndWait(
            DefaultMetalCommandBufferSubmission(
                commandBuffer: commandBuffer,
                context: MetalCommandBufferExecutionContext(
                    label: "com.mirmir.ash.v3.descriptor_parity.\(route.rawValue)"
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
        return Array(UnsafeBufferPointer(
            start: outputBuffer.contents().bindMemory(
                to: DescriptorProbeOutput.self,
                capacity: count
            ),
            count: count
        ))
    }

    private func descriptorProbeUniforms(
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
        floating(46, Double(locked.minimumAnisotropicMagnitudeUNorm15) / 32_767.0)
        floating(47, Double(locked.minimumAnisotropicCoherenceUNorm15) / 32_767.0)
        floating(48, Double(locked.riskSuppressionUNorm15) / 32_767.0)
        floating(49, Double(locked.lowPassRadiusQ8x8) / 256.0)
        values[50] = locked.weightEpsilonF32Bits
        return values
    }

    private func descriptorProbeState(
        _ sourceState: ASHState = ASHState(validatedRawValue: 0)
    ) -> ASHMetalStateSampleABIV3 {
        var state = ASHMetalStateSampleABIV3()
        state.state = sourceState.rawValue
        state.orientationQ15 = 2_607
        state.magnitudeQ15 = 24_575
        state.coherenceQ15 = 26_214
        state.textureQ15 = 12_288
        state.riskQ15 = 4_096
        state.temporalConfidenceQ15 = 0
        state.chromaAlignmentQ15 = 16_384
        state.localMinimum = 0
        state.localMaximum = UInt16.max
        return state
    }

    private func rawLUTEntryBytes(
        lut: ASHLUTLoadedV3,
        state: ASHState,
        planeRole: ASHLUTPlaneRoleV3,
        phaseOrdinal: Int
    ) -> Data {
        let entriesPerPlane = lut.route.phasePairCount * 4 * 256
        let logicalIndex = Int(planeRole.rawValue) * entriesPerPlane
            + phaseOrdinal * 4 * 256
            + Int(state.rawValue >> 1)
        let entryOffset = Int(ASHLUTLittleEndianV3.uint32(lut.immutableBytes, at: 44))
            + logicalIndex * 24
        return lut.immutableBytes.subdata(in: entryOffset..<(entryOffset + 24))
    }

    // Explicit arguments expose every CPU comparator dependency.
    // swiftlint:disable:next function_parameter_count
    private func cpuDescriptorProbeValues(
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
        let pair = try XCTUnwrap(
            lut.parameters.indices.contains(parameterIndex)
                ? lut.parameters[parameterIndex]
                : nil
        )
        let slot = pair.primary
        let selection = artifacts.configuration.routeSelection(for: route)
        let mode = planeRole == .luma
            ? selection.lumaAnisotropyMode
            : selection.chromaAnisotropyMode
        let state = descriptorProbeState()
        let baseOrientation = Double(
            Float(state.orientationQ15) / 32_767.0 * Float.pi
        )
        var orientation = baseOrientation + Double(slot.delta.orientation) * (.pi / 4.0)
        orientation.formTruncatingRemainder(dividingBy: .pi)
        if orientation < 0 { orientation += .pi }
        let sidecar = try ASHSpatialSidecarV2(
            orientationRadians: orientation,
            normalizedMagnitude: Double(Float(state.magnitudeQ15) / 32_767.0),
            coherence: Double(Float(state.coherenceQ15) / 32_767.0),
            risk: Double(Float(state.riskQ15) / 32_767.0),
            chromaAlignment: Double(Float(state.chromaAlignmentQ15) / 32_767.0),
            localMinimum: 0,
            localMaximum: 1
        )
        let locked = artifacts.configuration.operatorParameters
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: Double(mode.anisotropyStrengthQ12) / 4_096.0,
            minimumAnisotropicMagnitude: Double(slot.minimumAnisotropicMagnitudeUNorm15)
                / 32_767.0,
            minimumAnisotropicCoherence: Double(slot.minimumAnisotropicCoherenceUNorm15)
                / 32_767.0,
            controlledDetailGain: Double(slot.detailGainQ12) / 4_096.0,
            relaxedLimiterAlpha: Double(slot.relaxedLimiterAlphaQ12) / 4_096.0,
            riskDetailSuppressionThreshold: Double(slot.riskSuppressionUNorm15) / 32_767.0,
            lowPassRadius: Double(locked.lowPassRadiusQ8x8) / 256.0,
            weightEpsilon: Double(Float(bitPattern: slot.weightEpsilonF32Bits)),
            supportRadius: Double(slot.supportRadiusQ8x8) / 256.0
        )
        let effectiveDescriptorID = mode.usesAnisotropy
            ? descriptorID
            : descriptorID & ~UInt8(2)
        let descriptor = try ASHSpatialDescriptorV2(id: effectiveDescriptorID)
        let horizontalPhase = phaseOrdinal % route.scaleNumerator
        let verticalPhase = phaseOrdinal / route.scaleNumerator
        let denominator = Int64(route.scaleNumerator)
        let coordinates = ASHSpatialSourceCoordinatesV2(
            horizontal: ASHSpatialRationalCoordinateV2(
                numerator: Int64(3 * route.scaleNumerator
                    + horizontalPhase * route.scaleDenominator),
                denominator: denominator
            ),
            vertical: ASHSpatialRationalCoordinateV2(
                numerator: Int64(3 * route.scaleNumerator
                    + verticalPhase * route.scaleDenominator),
                denominator: denominator
            )
        )
        let planes = planeRole == .luma ? [luma] : [cb, cr]
        return try planes.map { plane in
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

    private func quantizedCode(_ value: Double, luma: Bool) -> Int {
        let clamped = min(1.0, max(0.0, value))
        let minimum = 16.0
        let maximum = luma ? 235.0 : 240.0
        return Int((minimum + clamped * (maximum - minimum)).rounded())
    }

    private func sectorInput(_ tangent: Float) -> StateProbeInput {
        StateProbeInput(
            magnitude: 1,
            coherence: 0,
            texture: 0,
            risk: 0,
            chromaAlignment: 0,
            tangent: tangent
        )
    }

    private func runStatePackProbe(
        _ inputs: [StateProbeInput],
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) async throws -> [UInt16] {
        let metal = try DefaultMetalRenderingService()
        let library = try XCTUnwrap(metal.device.makeDefaultLibrary())
        let function = try XCTUnwrap(
            library.makeFunction(name: "ash_v3_state_pack_parity_probe")
        )
        let pipeline = try await metal.device.makeComputePipelineState(function: function)
        let inputBuffer = try inputs.withUnsafeBytes { bytes in
            try XCTUnwrap(metal.device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ))
        }
        let outputBuffer = try XCTUnwrap(metal.device.makeBuffer(
            length: inputs.count * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        ))
        let uniformBuffer = try XCTUnwrap(metal.device.makeBuffer(
            length: 64 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ))
        let uniforms = uniformBuffer.contents().bindMemory(to: UInt32.self, capacity: 64)
        uniforms.initialize(repeating: 0, count: 64)
        func set(_ index: Int, _ value: Double) {
            uniforms[index] = Float(value).bitPattern
        }
        set(34, configuration.bands.edgePresent.low)
        set(35, configuration.bands.edgePresent.high)
        set(36, configuration.bands.coherentStructure.low)
        set(37, configuration.bands.coherentStructure.high)
        set(38, configuration.bands.textureHighFrequency.low)
        set(39, configuration.bands.textureHighFrequency.high)
        set(40, configuration.bands.aliasOrRingingRisk.low)
        set(41, configuration.bands.aliasOrRingingRisk.high)
        set(44, configuration.bands.chromaLumaStructureAligned.low)
        set(45, configuration.bands.chromaLumaStructureAligned.high)

        let commandBuffer = try XCTUnwrap(metal.commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        var count = UInt32(inputs.count)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: inputs.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(pipeline.threadExecutionWidth, inputs.count),
                height: 1,
                depth: 1
            )
        )
        encoder.endEncoding()
        _ = try await MetalCommandBufferCompletionBridge().commitAndWait(
            DefaultMetalCommandBufferSubmission(
                commandBuffer: commandBuffer,
                context: MetalCommandBufferExecutionContext(
                    label: "com.mirmir.ash.v3.state_pack_parity"
                )
            ),
            retaining: MetalCommandBufferRetainedResources([
                inputBuffer, outputBuffer, uniformBuffer, pipeline
            ])
        )
        return Array(UnsafeBufferPointer(
            start: outputBuffer.contents().bindMemory(
                to: UInt16.self,
                capacity: inputs.count
            ),
            count: inputs.count
        ))
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw ASHMetalSpatialRuntimeErrorV3.textureCreationFailed(
                plane: -1,
                status: status
            )
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        return pixelBuffer
    }

    private func fill(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                return XCTFail("Missing plane \(plane)")
            }
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let activeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 0 ? 1 : 2)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<activeWidth {
                    let value = (row * 29 + column * 17 + plane * 47) % 200
                    bytes[row * stride + column] = UInt8(value + 20)
                }
            }
        }
    }

    private func fillVideoRangeExcursions(_ pixelBuffer: CVPixelBuffer) {
        let lumaCodes: [UInt8] = [0, 15, 16, 235, 236, 255]
        let chromaCodes: [UInt8] = [0, 15, 16, 240, 241, 255]
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                return XCTFail("Missing plane \(plane)")
            }
            let codes = plane == 0 ? lumaCodes : chromaCodes
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let activeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 0 ? 1 : 2)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for column in 0..<activeWidth {
                    bytes[row * stride + column] = codes[
                        (row * activeWidth + column) % codes.count
                    ]
                }
            }
        }
    }

    private func readPlane(_ pixelBuffer: CVPixelBuffer, plane: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            XCTFail("Missing plane \(plane)")
            return []
        }
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            * (plane == 0 ? 1 : 2)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []
        result.reserveCapacity(width * height)
        for row in 0..<height {
            result.append(contentsOf: UnsafeBufferPointer(
                start: bytes.advanced(by: row * stride),
                count: width
            ))
        }
        return result
    }

    private func maximumAbsoluteError(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}

// swiftlint:enable file_length type_body_length
