import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import XCTest
@testable import Mirmir

final class DeterministicMetalBackendTests: XCTestCase {
    private var verifiedRuntime: ASHVerifiedRuntimeBundleV4!

    override func setUpWithError() throws {
        try super.setUpWithError()
        verifiedRuntime = try ASHV4SemanticArtifactTestSupport
            .executableSystemMetalRuntime()
    }

    private enum Pattern: String, CaseIterable {
        case constant
        case ramp
        case impulse
        case directionalEdges = "directional_edges"
    }

    private struct Difference {
        let differingSamples: Int
        let maximumAbsoluteCodeDifference: Int
        let sampleCount: Int
    }

    private enum BaselinePattern: String, CaseIterable {
        case constant
        case horizontalRamp = "horizontal_ramp"
        case diagonalEdge = "diagonal_edge"
        case impulse
        case checkerboard
        case radialDetail = "radial_detail"
        case movingEdge0 = "moving_edge_0"
        case movingEdge1 = "moving_edge_1"
        case movingEdge2 = "moving_edge_2"
        case movingEdge3 = "moving_edge_3"

        var movingEdgeThreshold: Double? {
            switch self {
            case .movingEdge0: 0.28
            case .movingEdge1: 0.38
            case .movingEdge2: 0.48
            case .movingEdge3: 0.58
            default: nil
            }
        }
    }

    private struct BaselineCaseRecord: Codable {
        let id: String
        let route: String
        let pixelFormat: String
        let pattern: String
        let sourceWidth: Int
        let sourceHeight: Int
        let targetWidth: Int
        let targetHeight: Int
        let sourceLumaByteCount: Int
        let sourceChromaByteCount: Int
        let targetLumaByteCount: Int
        let targetChromaByteCount: Int
        let sourceFile: String
        let referenceFile: String
        let cpuFile: String
        let metalFile: String
    }

    private struct BaselinePerformanceRecord: Codable {
        let id: String
        let route: String
        let pixelFormat: String
        let warmupCount: Int
        let sampleCount: Int
        let cpuMilliseconds: [Double]
        let metalMilliseconds: [Double]
        let memoryBeforeWarmups: BaselineMemorySnapshot
        let memoryAfterSamples: BaselineMemorySnapshot
        let cpuMemoryDeltas: [BaselineMemoryDelta]
        let metalMemoryDeltas: [BaselineMemoryDelta]
    }

    private struct BaselineMemorySnapshot: Codable {
        let mallocSizeInUseBytes: UInt64
        let mallocSizeAllocatedBytes: UInt64
        let residentBytes: UInt64
        let physicalFootprintBytes: UInt64
    }

    private struct BaselineMemoryDelta: Codable {
        let mallocSizeInUseBytes: Int64
        let mallocSizeAllocatedBytes: Int64
        let residentBytes: Int64
        let physicalFootprintBytes: Int64
    }

    private struct BaselineCapture: Codable {
        let schemaVersion: String
        let cpuImplementationVersion: String
        let metalImplementationVersion: String
        let sourceWidth: Int
        let sourceHeight: Int
        let cases: [BaselineCaseRecord]
        let performance: [BaselinePerformanceRecord]
    }

    func testVerifiedP06RuntimeContainsEveryBoundArtifactAndRealMetalKernel()
        throws {
        try verifiedRuntime.verifyBinding()
        XCTAssertEqual(
            verifiedRuntime.manifest.runtimeID,
            ASHRuntimeManifestV4.runtimeIdentity
        )
        XCTAssertEqual(
            verifiedRuntime.manifest.releaseStatus,
            .releaseQualified
        )
        XCTAssertEqual(
            Set(verifiedRuntime.manifest.artifacts.map(\.role)),
            Set(ASHRuntimeArtifactRoleV4.allCases)
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try ASHP06MetalLibraryFactoryV4.makeLibrary(
            runtime: verifiedRuntime,
            device: device
        )
        XCTAssertNotNil(library.makeFunction(name: "ashFixedPointScaleV4"))
    }

    func testMetalP06IsAvailableAndKeepsItsExactBackendIdentity() async throws {
        let backend = try makeMetalBackend()
        let source = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let availability = await backend.availability(
            for: source,
            targetSize: CGSize(width: 32, height: 24),
            environment: deterministicMetalTestEnvironment
        )
        XCTAssertEqual(availability, .available)
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 32, height: 24)
            ),
            environment: deterministicMetalTestEnvironment
        )
        XCTAssertEqual(prepared.actualBackendID, .mirmirDeterministicMetal)
        let concrete = try XCTUnwrap(
            prepared as? PreparedDeterministicMetalUpscaler
        )
        XCTAssertEqual(
            concrete.deterministicConfiguration.implementationVersion,
            ASHRuntimeManifestV4.runtimeIdentity
        )
        XCTAssertEqual(
            concrete.deterministicConfiguration.runtimeManifestSHA256,
            verifiedRuntime.manifestSHA256.rawValue
        )
        XCTAssertTrue(concrete.deterministicConfiguration.stateInputEnabled)
        try await prepared.finish()
        try await prepared.finish()

        let input = try SyntheticNV12PixelBuffer.make(
            width: 16,
            height: 12,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        attachProgressiveBT709(to: input)
        let output = try makeOutput(
            CGSize(width: 32, height: 24),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        do {
            try await prepared.process(
                source: input,
                destination: output,
                timing: FrameTiming(
                    frameIndex: 0,
                    presentationTime: .zero,
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
            XCTFail("processing after finish should fail")
        } catch is CancellationError {
            XCTFail("processing after finish reported cancellation")
        } catch {
            XCTAssertTrue(String(describing: error).contains("already finished"))
        }
    }

    func testAlphaMetalExecutionUsesTheVerifiedP06Library() async throws {
        let backend = try makeMetalBackend()
        let source = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_32BGRA,
            alphaModel: .straight
        )
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: 24, height: 18)
            ),
            environment: deterministicMetalTestEnvironment
        )
        let alpha = try XCTUnwrap(
            prepared as? PreparedDeterministicAlphaPlanningBackendV4
        )

        switch try await alpha.makeAlphaExecutionContext() {
        case .cpu:
            XCTFail("The Metal backend returned a CPU alpha context.")
        case .metal(_, let library):
            XCTAssertNotNil(library.makeFunction(name: "ashFixedPointScaleV4"))
        }
    }

    func testCPUAndMetalAreByteIdenticalAcrossRangesRoutesAndPatterns()
        async throws {
        for pixelFormat in [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ] {
            for target in [
                CGSize(width: 24, height: 18),
                CGSize(width: 32, height: 24),
                CGSize(width: 29, height: 21)
            ] {
                let sourceInfo = makeSourceInfo(pixelFormat: pixelFormat)
                for pattern in Pattern.allCases {
                    let cpu = try await makeCPUBackend().prepare(
                        request: BackendPreparationRequest(
                            source: sourceInfo,
                            targetSize: target
                        ),
                        environment: deterministicMetalTestEnvironment
                    )
                    let firstMetal = try await makeMetalBackend().prepare(
                        request: BackendPreparationRequest(
                            source: sourceInfo,
                            targetSize: target
                        ),
                        environment: deterministicMetalTestEnvironment
                    )
                    let repeatedMetal = try await makeMetalBackend().prepare(
                        request: BackendPreparationRequest(
                            source: sourceInfo,
                            targetSize: target
                        ),
                        environment: deterministicMetalTestEnvironment
                    )
                    let source = try SyntheticNV12PixelBuffer.make(
                        width: 16,
                        height: 12,
                        pixelFormat: pixelFormat
                    )
                    try write(pattern: pattern, to: source)
                    attachProgressiveBT709(to: source)
                    let cpuOutput = try makeOutput(target, pixelFormat: pixelFormat)
                    let firstMetalOutput = try makeOutput(target, pixelFormat: pixelFormat)
                    let repeatMetalOutput = try makeOutput(target, pixelFormat: pixelFormat)
                    let timing = FrameTiming(
                        // Each loop iteration prepares a fresh actor. Its first
                        // input is always stream ordinal zero even though the
                        // corpus pattern has an outer-loop index.
                        frameIndex: 0,
                        presentationTime: .zero,
                        duration: CMTime(value: 1, timescale: 30)
                    )
                    try await cpu.process(
                        source: source,
                        destination: cpuOutput,
                        timing: timing
                    )
                    try await firstMetal.process(
                        source: source,
                        destination: firstMetalOutput,
                        timing: timing
                    )
                    try await repeatedMetal.process(
                        source: source,
                        destination: repeatMetalOutput,
                        timing: timing
                    )

                    let cpuBytes = try visibleBytes(cpuOutput)
                    let firstBytes = try visibleBytes(firstMetalOutput)
                    let repeatBytes = try visibleBytes(repeatMetalOutput)
                    XCTAssertEqual(
                        firstBytes,
                        repeatBytes,
                        "Metal output changed for \(target), \(pattern.rawValue)"
                    )
                    XCTAssertEqual(
                        cpuBytes,
                        firstBytes,
                        "CPU/Metal mismatch for \(target), \(pattern.rawValue)"
                    )
                    XCTAssertEqual(
                        firstMetal.actualBackendID,
                        .mirmirDeterministicMetal
                    )
                    try await cpu.finish()
                    try await firstMetal.finish()
                    try await repeatedMetal.finish()
                }
            }
        }
    }

    func testCPUAndMetalApplyEveryTypedResetBeforeReadingHistory()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 32, height: 24)
        )
        let preparedCPU = try await makeCPUBackend().prepare(
            request: request,
            environment: deterministicMetalTestEnvironment
        )
        let preparedMetal = try await makeMetalBackend().prepare(
            request: request,
            environment: deterministicMetalTestEnvironment
        )
        let cpu = try XCTUnwrap(
            preparedCPU as? PreparedDeterministicV4Upscaler
        )
        let metal = try XCTUnwrap(
            preparedMetal as? PreparedDeterministicV4Upscaler
        )
        let declared: [ASHTemporalResetReasonV4] = [
            .seek,
            .discontinuity,
            .editBoundary,
            .formatChange,
            .geometryChange,
            .pixelFormatChange,
            .colorDomainChange,
            .hdrMetadataChange,
            .fieldCadenceChange,
            .contractChange,
            .explicitReset,
        ]
        var expectedGeneration: UInt64 = 0
        for frameIndex in 0...(declared.count + 1) {
            let source = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12,
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            try write(pattern: .directionalEdges, to: source)
            attachProgressiveBT709(to: source)
            let cpuOutput = try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let metalOutput = try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let declaredReason: ASHTemporalResetReasonV4?
            let expectedReason: ASHTemporalResetReasonV4
            let presentationValue: Int64
            if frameIndex == 0 {
                declaredReason = nil
                expectedReason = .streamStart
                presentationValue = 0
            } else if frameIndex <= declared.count {
                declaredReason = declared[frameIndex - 1]
                expectedReason = declared[frameIndex - 1]
                presentationValue = Int64(frameIndex)
            } else {
                declaredReason = nil
                expectedReason = .presentationTimeDiscontinuity
                presentationValue = Int64(frameIndex + 1)
            }
            let timing = FrameTiming(
                frameIndex: frameIndex,
                presentationTime: CMTime(
                    value: presentationValue,
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30),
                temporalResetReason: declaredReason
            )
            let cpuFrames = try await cpu.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [FramePixelBuffer(cpuOutput)],
                timing: timing
            )
            let metalFrames = try await metal.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [FramePixelBuffer(metalOutput)],
                timing: timing
            )
            let cpuFrame = try XCTUnwrap(cpuFrames.first)
            let metalFrame = try XCTUnwrap(metalFrames.first)
            expectedGeneration += 1
            XCTAssertEqual(cpuFrame.temporalResetReason, expectedReason)
            XCTAssertEqual(metalFrame.temporalResetReason, expectedReason)
            XCTAssertEqual(cpuFrame.temporalGeneration, expectedGeneration)
            XCTAssertEqual(metalFrame.temporalGeneration, expectedGeneration)
            XCTAssertEqual(
                try visibleBytes(cpuOutput),
                try visibleBytes(metalOutput),
                "typed reset parity failed for \(expectedReason.rawValue)"
            )
        }
    }

    func testPreparedDispatcherSelectsCanonicalBoundedPathFor8K()
        async throws {
        let configuration = DeterministicPreparedConfigurationV4(
            backendID: .mirmirDeterministicCPU,
            executionBackend: .cpu,
            storage: .nv12VideoRange8Bit,
            sourceWidth: 4_096,
            sourceHeight: 2_160,
            targetWidth: 8_192,
            targetHeight: 4_320,
            scanMode: .progressive
        )
        let prepared = try PreparedDeterministicV4Upscaler(
            configuration: configuration,
            runtime: verifiedRuntime
        )
        XCTAssertTrue(prepared.usesBoundedTiledTemporalPath)
        XCTAssertEqual(prepared.temporalTilePolicy, .canonical)
        let contract = try XCTUnwrap(prepared.tiledAllocationContract)
        XCTAssertEqual(
            contract.policyID,
            ASHTemporalTilePolicyV4.canonical.policyID
        )
        XCTAssertEqual(contract.sourceFullFrameSampleCount, 4_096 * 2_160)
        XCTAssertEqual(contract.sourceTileCount, 16 * 9)
        XCTAssertEqual(contract.targetFullFrameSampleCount, 8_192 * 4_320)
        XCTAssertEqual(contract.targetTileCount, 32 * 17)
        XCTAssertGreaterThan(
            contract.targetFullFrameSampleCount,
            ASHTemporalPlaneV4.maximumSampleCount
        )
        XCTAssertEqual(contract.fullFrameSampleArrayAllocationCap, 0)
        XCTAssertEqual(
            contract.maximumRetainedTileSampleCount,
            ASHTemporalTilePolicyV4.canonical
                .maximumRetainedTileSampleCount
        )
        XCTAssertEqual(contract.maximumOutputTileSampleCount, 256 * 256)
        XCTAssertLessThan(
            contract.maximumRetainedTileSampleCount,
            contract.targetFullFrameSampleCount
        )
        let diagnostics = await prepared.workspaceDiagnostics()
        XCTAssertEqual(
            diagnostics.scalerFullPlaneSwiftArrayStagingSampleCount,
            0
        )
        XCTAssertTrue(diagnostics.scalerUsesDirectPixelBufferIO)
        XCTAssertEqual(
            diagnostics.scalerCPUReusableHorizontalSampleCount,
            4 * 8_192 + 4 * 4_096
        )
        XCTAssertLessThan(
            diagnostics.scalerCPUReusableHorizontalSampleCount,
            contract.targetFullFrameSampleCount
        )
        let misalignedPolicy = try ASHTemporalTilePolicyV4(
            policyID: "ash.test.misaligned-production-tiles",
            tileWidth: 10,
            tileHeight: 8,
            searchHalo: 5,
            maximumFrameWidth: 32_768,
            maximumFrameHeight: 32_768
        )
        XCTAssertThrowsError(try PreparedDeterministicV4Upscaler(
            configuration: configuration,
            runtime: verifiedRuntime,
            temporalTilePolicy: misalignedPolicy
        )) { error in
            XCTAssertEqual(
                error as? ASHTemporalV4Error,
                .invalidConfiguration
            )
        }
    }

    func testCanonical8KEndToEndAllocationGateWhenRequested()
        async throws {
        guard ProcessInfo.processInfo.environment[
            "MIRMIR_RUN_8K_ALLOCATION_GATE"
        ] == "1" else {
            throw XCTSkip(
                "Set MIRMIR_RUN_8K_ALLOCATION_GATE=1 for the physical 8K gate."
            )
        }
        let configuration = DeterministicPreparedConfigurationV4(
            backendID: .mirmirDeterministicCPU,
            executionBackend: .cpu,
            storage: .nv12VideoRange8Bit,
            sourceWidth: 4_096,
            sourceHeight: 2_160,
            targetWidth: 8_192,
            targetHeight: 4_320,
            scanMode: .progressive
        )
        let prepared = try PreparedDeterministicV4Upscaler(
            configuration: configuration,
            runtime: verifiedRuntime
        )
        let source = try PixelBufferSignalCodecV4.makeBuffer(
            storage: configuration.storage,
            width: configuration.sourceWidth,
            height: configuration.sourceHeight,
            metalCompatible: false
        )
        let destination = try PixelBufferSignalCodecV4.makeBuffer(
            storage: configuration.storage,
            width: configuration.targetWidth,
            height: configuration.targetHeight,
            metalCompatible: false
        )
        try write(pattern: .ramp, to: source)
        attachProgressiveBT709(to: source)
        let outputs = try await prepared.processTemporal(
            source: FramePixelBuffer(source),
            destinations: [FramePixelBuffer(destination)],
            timing: FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 30)
            )
        )
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].temporalResetReason, .streamStart)
        let diagnostics = await prepared.workspaceDiagnostics()
        let contract = try XCTUnwrap(prepared.tiledAllocationContract)
        XCTAssertEqual(diagnostics.tiledTemporalHistoryCount, 1)
        XCTAssertEqual(
            diagnostics.tiledSourceFullFrameSampleArrayAllocationCount,
            contract.fullFrameSampleArrayAllocationCap
        )
        XCTAssertEqual(
            diagnostics.tiledOutputFullFrameSampleArrayAllocationCount,
            contract.fullFrameSampleArrayAllocationCap
        )
        XCTAssertEqual(
            diagnostics.tiledReconstructionFullFrameSampleArrayAllocationCount,
            contract.fullFrameSampleArrayAllocationCap
        )
        XCTAssertEqual(
            diagnostics.tiledMotionFullFrameVectorArrayAllocationCount,
            0
        )
        XCTAssertEqual(diagnostics.tiledMaterializedAlignedSampleCount, 0)
        XCTAssertEqual(
            diagnostics.scalerFullPlaneSwiftArrayStagingSampleCount,
            0
        )
        XCTAssertTrue(diagnostics.scalerUsesDirectPixelBufferIO)
        XCTAssertLessThanOrEqual(
            diagnostics.tiledLargestContiguousSampleAllocation,
            contract.maximumRetainedTileSampleCount
        )
    }

    func testForcedTiledPreparedPathIsCPUAndMetalExactAndResumable()
        async throws {
        let policy = try forcedPreparedTilePolicy()
        let reference = try makeDirectPrepared(
            executionBackend: .cpu,
            tilePolicy: nil
        )
        let tiledCPU = try makeDirectPrepared(
            executionBackend: .cpu,
            tilePolicy: policy
        )
        let tiledMetal = try makeDirectPrepared(
            executionBackend: .metal,
            tilePolicy: policy
        )
        let resumedCPU = try makeDirectPrepared(
            executionBackend: .cpu,
            tilePolicy: policy
        )
        let plan = ASHSHA256V4(rawData: Data(
            "forced-tiled-prepared-plan".utf8
        ))

        var checkpoint: Data?
        for frameIndex in 0..<3 {
            let source = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12,
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            try write(pattern: .ramp, to: source)
            attachProgressiveBT709(to: source)
            let timing = FrameTiming(
                frameIndex: frameIndex,
                presentationTime: CMTime(
                    value: Int64(frameIndex),
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30)
            )
            let referenceOutput = try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let cpuOutput = try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let metalOutput = try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let referenceFrames = try await reference.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [FramePixelBuffer(referenceOutput)],
                timing: timing
            )
            let cpuFrames = try await tiledCPU.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [FramePixelBuffer(cpuOutput)],
                timing: timing
            )
            let metalFrames = try await tiledMetal.processTemporal(
                source: FramePixelBuffer(source),
                destinations: [FramePixelBuffer(metalOutput)],
                timing: timing
            )
            let referenceFrame = try XCTUnwrap(referenceFrames.first)
            let cpuFrame = try XCTUnwrap(cpuFrames.first)
            let metalFrame = try XCTUnwrap(metalFrames.first)
            XCTAssertEqual(
                try visibleBytes(cpuOutput),
                try visibleBytes(referenceOutput),
                "tiled/contiguous mismatch at frame \(frameIndex)"
            )
            XCTAssertEqual(
                try visibleBytes(metalOutput),
                try visibleBytes(cpuOutput),
                "tiled CPU/Metal mismatch at frame \(frameIndex)"
            )
            XCTAssertEqual(cpuFrame.temporalResetReason,
                           referenceFrame.temporalResetReason)
            XCTAssertEqual(metalFrame.temporalResetReason,
                           cpuFrame.temporalResetReason)
            XCTAssertEqual(metalFrame.temporalGeneration,
                           cpuFrame.temporalGeneration)

            if frameIndex == 1 {
                let encoded = try await tiledCPU.makeTemporalCheckpoint(
                    planSHA256: plan,
                    lastCompletedInputOrdinal: 1
                )
                let repeated = try await tiledCPU.makeTemporalCheckpoint(
                    planSHA256: plan,
                    lastCompletedInputOrdinal: 1
                )
                XCTAssertEqual(encoded, repeated)
                let parsedValue = try ASHCanonicalJSONV4.parse(encoded)
                guard case .object(let parsed) = parsedValue,
                      case .string(let schemaID)? = parsed["schemaID"],
                      case .object(let durableHistory)? = parsed["history"],
                      case .integer(let durableCapacity)? =
                        durableHistory["capacity"],
                      case .array(let durableEntries)? =
                        durableHistory["entries"] else {
                    return XCTFail("tiled checkpoint root was not canonical")
                }
                XCTAssertEqual(
                    schemaID,
                    ASHPreparedTiledTemporalCheckpointV4.currentSchemaID
                )
                XCTAssertEqual(durableCapacity, 1)
                XCTAssertEqual(durableEntries.count, 1)
                checkpoint = encoded
                try await resumedCPU.restoreTemporalCheckpoint(
                    encoded,
                    planSHA256: plan
                )
                do {
                    try await resumedCPU.restoreTemporalCheckpoint(
                        encoded,
                        planSHA256: ASHSHA256V4(rawData: Data(
                            "different-forced-tiled-plan".utf8
                        ))
                    )
                    XCTFail("identity-mismatched tiled checkpoint was accepted")
                } catch {
                    XCTAssertEqual(
                        error as? ASHPreparedTemporalCheckpointV4Error,
                        .identityMismatch
                    )
                }
                var nonCanonical = encoded
                nonCanonical.append(0x0a)
                do {
                    try await resumedCPU.restoreTemporalCheckpoint(
                        nonCanonical,
                        planSHA256: plan
                    )
                    XCTFail("non-canonical tiled checkpoint was accepted")
                } catch {
                    XCTAssertEqual(
                        error as? ASHPreparedTemporalCheckpointV4Error,
                        .nonCanonicalEncoding
                    )
                }
            } else if frameIndex == 2 {
                let resumedOutput = try makeOutput(
                    CGSize(width: 32, height: 24),
                    pixelFormat:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                )
                _ = try await resumedCPU.processTemporal(
                    source: FramePixelBuffer(source),
                    destinations: [FramePixelBuffer(resumedOutput)],
                    timing: timing
                )
                XCTAssertEqual(
                    try visibleBytes(resumedOutput),
                    try visibleBytes(cpuOutput),
                    "checkpoint resume changed the next tiled pixel"
                )
            }
        }
        XCTAssertNotNil(checkpoint)
        let diagnostics = await tiledCPU.workspaceDiagnostics()
        XCTAssertTrue(diagnostics.usesBoundedTiledTemporalPath)
        XCTAssertEqual(diagnostics.temporalHistoryCount, 0)
        XCTAssertEqual(diagnostics.tiledTemporalHistoryCapacity, 2)
        XCTAssertEqual(diagnostics.tiledTemporalHistoryCount, 2)
        XCTAssertEqual(
            diagnostics.tiledSourceFullFrameSampleArrayAllocationCount,
            0
        )
        XCTAssertEqual(
            diagnostics.tiledOutputFullFrameSampleArrayAllocationCount,
            0
        )
        XCTAssertEqual(
            diagnostics.tiledMotionFullFrameVectorArrayAllocationCount,
            0
        )
        XCTAssertEqual(
            diagnostics.tiledReconstructionFullFrameSampleArrayAllocationCount,
            0
        )
        XCTAssertEqual(diagnostics.tiledMaterializedAlignedSampleCount, 0)
        XCTAssertEqual(
            diagnostics.scalerFullPlaneSwiftArrayStagingSampleCount,
            0
        )
        XCTAssertTrue(diagnostics.scalerUsesDirectPixelBufferIO)
        XCTAssertLessThanOrEqual(
            diagnostics.tiledLargestContiguousSampleAllocation,
            policy.maximumRetainedTileSampleCount
        )
    }

    func testTiledCancellationLeavesCanonicalStateAndSeekRetryExact()
        async throws {
        let policy = try forcedPreparedTilePolicy()
        let cancelled = try makeDirectPrepared(
            executionBackend: .cpu,
            tilePolicy: policy
        )
        let clean = try makeDirectPrepared(
            executionBackend: .cpu,
            tilePolicy: policy
        )
        let plan = ASHSHA256V4(rawData: Data(
            "forced-tiled-cancellation-plan".utf8
        ))
        let firstSource = try SyntheticNV12PixelBuffer.make(
            width: 16,
            height: 12,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        try write(pattern: .directionalEdges, to: firstSource)
        attachProgressiveBT709(to: firstSource)
        let firstTiming = FrameTiming(
            frameIndex: 0,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 30)
        )
        for subject in [cancelled, clean] {
            let output = try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            _ = try await subject.processTemporal(
                source: FramePixelBuffer(firstSource),
                destinations: [FramePixelBuffer(output)],
                timing: firstTiming
            )
        }
        let checkpointBefore = try await cancelled.makeTemporalCheckpoint(
            planSHA256: plan,
            lastCompletedInputOrdinal: 0
        )
        await cancelled.setTiledTileBoundaryTestHook { tileIndex in
            if tileIndex == 2 { throw CancellationError() }
        }
        let seekSource = try SyntheticNV12PixelBuffer.make(
            width: 16,
            height: 12,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        try write(pattern: .ramp, to: seekSource)
        attachProgressiveBT709(to: seekSource)
        let seekTiming = FrameTiming(
            frameIndex: 1,
            presentationTime: CMTime(value: 1, timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            temporalResetReason: .seek
        )
        let interruptedOutput = try makeOutput(
            CGSize(width: 32, height: 24),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        do {
            _ = try await cancelled.processTemporal(
                source: FramePixelBuffer(seekSource),
                destinations: [FramePixelBuffer(interruptedOutput)],
                timing: seekTiming
            )
            XCTFail("injected tiled cancellation did not escape")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await cancelled.setTiledTileBoundaryTestHook(nil)
        let checkpointAfterCancellation = try await cancelled
            .makeTemporalCheckpoint(
                planSHA256: plan,
                lastCompletedInputOrdinal: 0
            )
        XCTAssertEqual(
            checkpointBefore,
            checkpointAfterCancellation,
            "cancelled tiled work committed temporal state"
        )
        let retryOutput = try makeOutput(
            CGSize(width: 32, height: 24),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let cleanOutput = try makeOutput(
            CGSize(width: 32, height: 24),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let retryFrames = try await cancelled.processTemporal(
            source: FramePixelBuffer(seekSource),
            destinations: [FramePixelBuffer(retryOutput)],
            timing: seekTiming
        )
        let cleanFrames = try await clean.processTemporal(
            source: FramePixelBuffer(seekSource),
            destinations: [FramePixelBuffer(cleanOutput)],
            timing: seekTiming
        )
        let retryFrame = try XCTUnwrap(retryFrames.first)
        let cleanFrame = try XCTUnwrap(cleanFrames.first)
        XCTAssertEqual(retryFrame.temporalResetReason, .seek)
        XCTAssertEqual(retryFrame.temporalGeneration, 2)
        XCTAssertEqual(retryFrame.temporalGeneration,
                       cleanFrame.temporalGeneration)
        XCTAssertEqual(
            try visibleBytes(retryOutput),
            try visibleBytes(cleanOutput)
        )
    }

    func testForcedTiledInterlacedStateDoesNotRestartAndResumesExactly()
        async throws {
        let policy = try forcedPreparedTilePolicy()
        let uninterrupted = try makeDirectPrepared(
            executionBackend: .cpu,
            tilePolicy: policy,
            scanMode: .interlaced(.topFieldFirst)
        )
        let resumed = try makeDirectPrepared(
            executionBackend: .cpu,
            tilePolicy: policy,
            scanMode: .interlaced(.topFieldFirst)
        )
        let plan = ASHSHA256V4(rawData: Data(
            "forced-tiled-interlaced-plan".utf8
        ))
        var secondInputFrames: [TemporalOutputFrame] = []
        for frameIndex in 0..<2 {
            let source = try makeInterlacedSource()
            let destinations = try (0..<2).map { _ in
                FramePixelBuffer(try makeOutput(
                    CGSize(width: 32, height: 24),
                    pixelFormat:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ))
            }
            let frames = try await uninterrupted.processTemporal(
                source: FramePixelBuffer(source),
                destinations: destinations,
                timing: FrameTiming(
                    frameIndex: frameIndex,
                    presentationTime: CMTime(
                        value: Int64(frameIndex),
                        timescale: 30
                    ),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
            XCTAssertEqual(frames.count, 2)
            if frameIndex == 0 {
                XCTAssertEqual(frames[0].temporalResetReason, .streamStart)
            } else {
                XCTAssertNotEqual(frames[0].temporalResetReason, .streamStart)
                secondInputFrames = frames
            }
        }
        let checkpoint = try await uninterrupted.makeTemporalCheckpoint(
            planSHA256: plan,
            lastCompletedInputOrdinal: 1
        )
        try await resumed.restoreTemporalCheckpoint(
            checkpoint,
            planSHA256: plan
        )
        XCTAssertEqual(secondInputFrames.count, 2)
        let source = try makeInterlacedSource()
        let uninterruptedDestinations = try (0..<2).map { _ in
            FramePixelBuffer(try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ))
        }
        let resumedDestinations = try (0..<2).map { _ in
            FramePixelBuffer(try makeOutput(
                CGSize(width: 32, height: 24),
                pixelFormat:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ))
        }
        let timing = FrameTiming(
            frameIndex: 2,
            presentationTime: CMTime(value: 2, timescale: 30),
            duration: CMTime(value: 1, timescale: 30)
        )
        let uninterruptedFrames = try await uninterrupted.processTemporal(
            source: FramePixelBuffer(source),
            destinations: uninterruptedDestinations,
            timing: timing
        )
        let resumedFrames = try await resumed.processTemporal(
            source: FramePixelBuffer(source),
            destinations: resumedDestinations,
            timing: timing
        )
        XCTAssertEqual(
            uninterruptedFrames.map(\.temporalResetReason),
            resumedFrames.map(\.temporalResetReason)
        )
        for index in 0..<2 {
            XCTAssertEqual(
                try visibleBytes(uninterruptedDestinations[index].value),
                try visibleBytes(resumedDestinations[index].value)
            )
        }
    }

    func testCaptureV3BaselineWhenRequested() async throws {
        guard let requestedDirectory = ProcessInfo.processInfo.environment[
            "MIRMIR_V4_BASELINE_DIR"
        ], !requestedDirectory.isEmpty else {
            throw XCTSkip("Set MIRMIR_V4_BASELINE_DIR to capture the locked v3 corpus.")
        }

        let outputDirectory = URL(fileURLWithPath: requestedDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let warmupCount = max(
            0,
            Int(ProcessInfo.processInfo.environment["MIRMIR_V4_WARMUP_COUNT"] ?? "5")
                ?? 5
        )
        let sampleCount = max(
            1,
            Int(ProcessInfo.processInfo.environment["MIRMIR_V4_SAMPLE_COUNT"] ?? "10")
                ?? 10
        )
        let sourceWidth = 16
        let sourceHeight = 12
        var caseRecords: [BaselineCaseRecord] = []
        var performanceRecords: [BaselinePerformanceRecord] = []
        var cpuImplementationVersion: String?
        var metalImplementationVersion: String?
        var frameIndex = 0

        for pixelFormat in [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ] {
            let formatName = FourCC.string(from: pixelFormat) ?? String(pixelFormat)
            let sourceInfo = makeSourceInfo(pixelFormat: pixelFormat)

            for route in ASHSpatialRouteV2.allCases {
                let target = CGSize(
                    width: try route.destinationExtent(for: sourceWidth),
                    height: try route.destinationExtent(for: sourceHeight)
                )
                let request = BackendPreparationRequest(
                    source: sourceInfo,
                    targetSize: target
                )
                let cpu = try await makeCPUBackend().prepare(
                    request: request,
                    environment: deterministicMetalTestEnvironment
                )
                let metal = try await makeMetalBackend().prepare(
                    request: request,
                    environment: deterministicMetalTestEnvironment
                )
                if let concrete = cpu as? PreparedDeterministicCPUUpscaler {
                    cpuImplementationVersion = concrete.deterministicConfiguration
                        .implementationVersion
                }
                if let concrete = metal as? PreparedDeterministicMetalUpscaler {
                    metalImplementationVersion = concrete.deterministicConfiguration
                        .implementationVersion
                }

                for pattern in BaselinePattern.allCases {
                    let source = try SyntheticNV12PixelBuffer.make(
                        width: sourceWidth,
                        height: sourceHeight,
                        pixelFormat: pixelFormat
                    )
                    let reference = try makeOutput(target, pixelFormat: pixelFormat)
                    let cpuOutput = try makeOutput(target, pixelFormat: pixelFormat)
                    let metalOutput = try makeOutput(target, pixelFormat: pixelFormat)
                    try writeBaseline(pattern: pattern, to: source)
                    try writeBaseline(pattern: pattern, to: reference)
                    attachProgressiveBT709(to: source)
                    let timing = FrameTiming(
                        frameIndex: frameIndex,
                        presentationTime: CMTime(value: Int64(frameIndex), timescale: 30),
                        duration: CMTime(value: 1, timescale: 30)
                    )
                    try await cpu.process(
                        source: source,
                        destination: cpuOutput,
                        timing: timing
                    )
                    try await metal.process(
                        source: source,
                        destination: metalOutput,
                        timing: timing
                    )
                    frameIndex += 1

                    let caseID = [formatName, route.rawValue, pattern.rawValue]
                        .joined(separator: "-")
                    let sourcePlaneBytes = try planeBytes(source)
                    let referencePlaneBytes = try planeBytes(reference)
                    let sourceFile = "\(caseID)-source.bin"
                    let referenceFile = "\(caseID)-reference.bin"
                    let cpuFile = "\(caseID)-cpu.bin"
                    let metalFile = "\(caseID)-metal.bin"
                    try write(
                        sourcePlaneBytes.luma + sourcePlaneBytes.chroma,
                        named: sourceFile,
                        to: outputDirectory
                    )
                    try write(
                        referencePlaneBytes.luma + referencePlaneBytes.chroma,
                        named: referenceFile,
                        to: outputDirectory
                    )
                    try write(try visibleBytes(cpuOutput), named: cpuFile, to: outputDirectory)
                    try write(
                        try visibleBytes(metalOutput),
                        named: metalFile,
                        to: outputDirectory
                    )
                    caseRecords.append(BaselineCaseRecord(
                        id: caseID,
                        route: route.rawValue,
                        pixelFormat: formatName,
                        pattern: pattern.rawValue,
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        targetWidth: Int(target.width),
                        targetHeight: Int(target.height),
                        sourceLumaByteCount: sourcePlaneBytes.luma.count,
                        sourceChromaByteCount: sourcePlaneBytes.chroma.count,
                        targetLumaByteCount: referencePlaneBytes.luma.count,
                        targetChromaByteCount: referencePlaneBytes.chroma.count,
                        sourceFile: sourceFile,
                        referenceFile: referenceFile,
                        cpuFile: cpuFile,
                        metalFile: metalFile
                    ))
                }

                let benchmarkSource = try SyntheticNV12PixelBuffer.make(
                    width: sourceWidth,
                    height: sourceHeight,
                    pixelFormat: pixelFormat
                )
                try writeBaseline(pattern: .radialDetail, to: benchmarkSource)
                attachProgressiveBT709(to: benchmarkSource)
                let cpuBenchmarkOutput = try makeOutput(target, pixelFormat: pixelFormat)
                let metalBenchmarkOutput = try makeOutput(target, pixelFormat: pixelFormat)
                let memoryBeforeWarmups = try baselineMemorySnapshot()

                for iteration in 0..<warmupCount {
                    let timing = FrameTiming(
                        frameIndex: frameIndex + iteration,
                        presentationTime: CMTime(
                            value: Int64(frameIndex + iteration),
                            timescale: 30
                        ),
                        duration: CMTime(value: 1, timescale: 30)
                    )
                    try await cpu.process(
                        source: benchmarkSource,
                        destination: cpuBenchmarkOutput,
                        timing: timing
                    )
                    try await metal.process(
                        source: benchmarkSource,
                        destination: metalBenchmarkOutput,
                        timing: timing
                    )
                }
                frameIndex += warmupCount

                var cpuSamples: [Double] = []
                var metalSamples: [Double] = []
                var cpuMemoryDeltas: [BaselineMemoryDelta] = []
                var metalMemoryDeltas: [BaselineMemoryDelta] = []
                for iteration in 0..<sampleCount {
                    let timing = FrameTiming(
                        frameIndex: frameIndex + iteration,
                        presentationTime: CMTime(
                            value: Int64(frameIndex + iteration),
                            timescale: 30
                        ),
                        duration: CMTime(value: 1, timescale: 30)
                    )
                    let cpuMemoryBefore = try baselineMemorySnapshot()
                    cpuSamples.append(try await measuredMilliseconds {
                        try await cpu.process(
                            source: benchmarkSource,
                            destination: cpuBenchmarkOutput,
                            timing: timing
                        )
                    })
                    let cpuMemoryAfter = try baselineMemorySnapshot()
                    cpuMemoryDeltas.append(baselineMemoryDelta(
                        from: cpuMemoryBefore,
                        to: cpuMemoryAfter
                    ))
                    let metalMemoryBefore = try baselineMemorySnapshot()
                    metalSamples.append(try await measuredMilliseconds {
                        try await metal.process(
                            source: benchmarkSource,
                            destination: metalBenchmarkOutput,
                            timing: timing
                        )
                    })
                    let metalMemoryAfter = try baselineMemorySnapshot()
                    metalMemoryDeltas.append(baselineMemoryDelta(
                        from: metalMemoryBefore,
                        to: metalMemoryAfter
                    ))
                }
                frameIndex += sampleCount
                let memoryAfterSamples = try baselineMemorySnapshot()
                performanceRecords.append(BaselinePerformanceRecord(
                    id: "\(formatName)-\(route.rawValue)-radial_detail",
                    route: route.rawValue,
                    pixelFormat: formatName,
                    warmupCount: warmupCount,
                    sampleCount: sampleCount,
                    cpuMilliseconds: cpuSamples,
                    metalMilliseconds: metalSamples,
                    memoryBeforeWarmups: memoryBeforeWarmups,
                    memoryAfterSamples: memoryAfterSamples,
                    cpuMemoryDeltas: cpuMemoryDeltas,
                    metalMemoryDeltas: metalMemoryDeltas
                ))
                try await cpu.finish()
                try await metal.finish()
            }
        }

        let capture = BaselineCapture(
            schemaVersion: "mirmir-v4-baseline-v1",
            cpuImplementationVersion: try XCTUnwrap(cpuImplementationVersion),
            metalImplementationVersion: try XCTUnwrap(metalImplementationVersion),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            cases: caseRecords.sorted { $0.id < $1.id },
            performance: performanceRecords.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(capture).write(
            to: outputDirectory.appendingPathComponent("engine-results.json"),
            options: .atomic
        )
    }

    private func makeMetalBackend() throws -> DeterministicMetalBackend {
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicMetal)
        )
        return try XCTUnwrap(DeterministicMetalBackend(
            descriptor: descriptor,
            runtimeProvider: .fixed(verifiedRuntime)
        ))
    }

    private func makeCPUBackend() throws -> DeterministicCPUBackend {
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        return try XCTUnwrap(DeterministicCPUBackend(
            descriptor: descriptor,
            runtimeProvider: .fixed(verifiedRuntime)
        ))
    }

    private func forcedPreparedTilePolicy() throws
        -> ASHTemporalTilePolicyV4 {
        try ASHTemporalTilePolicyV4(
            policyID: "ash.test.prepared.tiles.8x8-motion4-spatial1",
            tileWidth: 8,
            tileHeight: 8,
            searchHalo: 5,
            maximumFrameWidth: 64,
            maximumFrameHeight: 64
        )
    }

    private func makeDirectPrepared(
        executionBackend: FixedPointExecutionBackendV4,
        tilePolicy: ASHTemporalTilePolicyV4?,
        scanMode: DeterministicScanModeV4 = .progressive
    ) throws -> PreparedDeterministicV4Upscaler {
        let backendID: UpscaleBackendID = executionBackend == .cpu
            ? .mirmirDeterministicCPU
            : .mirmirDeterministicMetal
        let configuration = DeterministicPreparedConfigurationV4(
            backendID: backendID,
            executionBackend: executionBackend,
            storage: .nv12VideoRange8Bit,
            sourceWidth: 16,
            sourceHeight: 12,
            targetWidth: 32,
            targetHeight: 24,
            scanMode: scanMode
        )
        if executionBackend == .cpu {
            return try PreparedDeterministicV4Upscaler(
                configuration: configuration,
                runtime: verifiedRuntime,
                temporalTilePolicy: tilePolicy
            )
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try ASHP06MetalLibraryFactoryV4.makeLibrary(
            runtime: verifiedRuntime,
            device: device
        )
        return try PreparedDeterministicV4Upscaler(
            configuration: configuration,
            runtime: verifiedRuntime,
            temporalTilePolicy: tilePolicy,
            metalDevice: device,
            metalLibrary: library
        )
    }

    private func makeInterlacedSource() throws -> CVPixelBuffer {
        let source = try SyntheticNV12PixelBuffer.make(
            width: 16,
            height: 12,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        try write(pattern: .ramp, to: source)
        attachProgressiveBT709(to: source)
        CVBufferSetAttachment(
            source,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 2),
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferFieldDetailKey,
            kCVImageBufferFieldDetailTemporalTopFirst,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        return source
    }

    private func makeSourceInfo(
        pixelFormat: OSType,
        alphaModel: CanonicalAlphaModelV4 = .none
    ) -> VideoInfo {
        VideoInfo(
            url: URL(fileURLWithPath: "/tmp/deterministic-metal-source.mov"),
            duration: CMTime(value: 1, timescale: 30),
            geometry: VideoGeometry(
                encodedSize: CGSize(width: 16, height: 12),
                naturalSize: CGSize(width: 16, height: 12),
                presentationSize: CGSize(width: 16, height: 12),
                displaySize: CGSize(width: 16, height: 12),
                preferredTransform: .identity,
                cleanAperture: nil,
                pixelAspectRatio: VideoPixelAspectRatio(
                    horizontalSpacing: 1,
                    verticalSpacing: 1
                )
            ),
            nominalFrameRate: 30,
            minimumFrameDuration: CMTime(value: 1, timescale: 30),
            estimatedFrameCount: 1,
            estimatedDataRate: nil,
            codecFourCC: kCMVideoCodecType_H264,
            hasAudio: false,
            audioTrackCount: 0,
            videoTrackCount: 1,
            isReadable: true,
            isPlayable: true,
            fileSizeBytes: nil,
            color: VideoColorInfo(
                colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
                bitDepth: 8,
                pixelFormat: pixelFormat,
                isFullRange:
                    pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                fieldCount: 1,
                fieldDetail: nil,
                alphaModel: alphaModel,
                hasMasteringDisplayMetadata: false,
                hasContentLightLevelMetadata: false,
                dynamicRange: .sdr
            )
        )
    }

    private func makeOutput(
        _ size: CGSize,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        try SyntheticNV12PixelBuffer.make(
            width: Int(size.width),
            height: Int(size.height),
            pixelFormat: pixelFormat
        )
    }

    private func attachProgressiveBT709(to buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }

    private func write(pattern: Pattern, to buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let channels = plane == 0 ? 1 : 2
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            ).assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let rowBase = base.advanced(by: row * stride)
                for column in 0..<width {
                    for channel in 0..<channels {
                        let value: UInt8
                        switch pattern {
                        case .constant:
                            value = plane == 0 ? 96 : (channel == 0 ? 112 : 144)
                        case .ramp:
                            value = UInt8(
                                16 + ((column * 11 + row * 7 + channel * 19) % 220)
                            )
                        case .impulse:
                            value = column == width / 2 && row == height / 2
                                ? 235 : (plane == 0 ? 16 : 128)
                        case .directionalEdges:
                            value = column + row / 2 < width / 2
                                ? (plane == 0 ? 32 : 96)
                                : (plane == 0 ? 220 : 176)
                        }
                        rowBase[column * channels + channel] = value
                    }
                }
            }
        }
    }

    private func writeBaseline(
        pattern: BaselinePattern,
        to buffer: CVPixelBuffer
    ) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let channels = plane == 0 ? 1 : 2
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            ).assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let rowBase = base.advanced(by: row * stride)
                for column in 0..<width {
                    let x = (Double(column) + 0.5) / Double(width)
                    let y = (Double(row) + 0.5) / Double(height)
                    for channel in 0..<channels {
                        rowBase[column * channels + channel] = baselineValue(
                            pattern: pattern,
                            x: x,
                            y: y,
                            plane: plane,
                            channel: channel
                        )
                    }
                }
            }
        }
    }

    private func baselineValue(
        pattern: BaselinePattern,
        x: Double,
        y: Double,
        plane: Int,
        channel: Int
    ) -> UInt8 {
        let neutral = plane == 0 ? 96.0 : (channel == 0 ? 112.0 : 144.0)
        let low = plane == 0 ? 20.0 : (channel == 0 ? 72.0 : 88.0)
        let high = plane == 0 ? 232.0 : (channel == 0 ? 184.0 : 208.0)
        let value: Double
        switch pattern {
        case .constant:
            value = neutral
        case .horizontalRamp:
            value = low + (high - low) * (0.82 * x + 0.18 * y)
        case .diagonalEdge:
            value = x + 0.42 * y < 0.69 ? low : high
        case .impulse:
            let dx = x - 0.5
            let dy = y - 0.5
            let gaussian = exp(-(dx * dx + dy * dy) / 0.006)
            value = low + (high - low) * gaussian
        case .checkerboard:
            let cellX = Int(floor(x * 8.0))
            let cellY = Int(floor(y * 6.0))
            value = (cellX + cellY).isMultiple(of: 2) ? low : high
        case .radialDetail:
            let dx = x - 0.5
            let dy = y - 0.5
            let radius = sqrt(dx * dx + dy * dy)
            let wave = 0.5 + 0.5 * sin(62.0 * radius + 7.0 * x - 5.0 * y)
            value = low + (high - low) * wave
        case .movingEdge0, .movingEdge1, .movingEdge2, .movingEdge3:
            let threshold = pattern.movingEdgeThreshold ?? 0.5
            value = x + 0.18 * y < threshold ? low : high
        }
        return UInt8(clamping: Int(value.rounded()))
    }

    private func planeBytes(
        _ buffer: CVPixelBuffer
    ) throws -> (luma: [UInt8], chroma: [UInt8]) {
        (
            try SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 0),
            try SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 1)
        )
    }

    private func write(
        _ bytes: [UInt8],
        named name: String,
        to directory: URL
    ) throws {
        try Data(bytes).write(
            to: directory.appendingPathComponent(name),
            options: .atomic
        )
    }

    private func baselineMemorySnapshot() throws -> BaselineMemorySnapshot {
        var mallocStatistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &mallocStatistics)
        let resourceUsage = try MirmirSystemProcessTelemetrySampler().sample()
        return BaselineMemorySnapshot(
            mallocSizeInUseBytes: UInt64(max(0, mallocStatistics.size_in_use)),
            mallocSizeAllocatedBytes: UInt64(max(0, mallocStatistics.size_allocated)),
            residentBytes: resourceUsage.residentBytes,
            physicalFootprintBytes: resourceUsage.physicalFootprintBytes
        )
    }

    private func baselineMemoryDelta(
        from before: BaselineMemorySnapshot,
        to after: BaselineMemorySnapshot
    ) -> BaselineMemoryDelta {
        BaselineMemoryDelta(
            mallocSizeInUseBytes: signedDelta(
                from: before.mallocSizeInUseBytes,
                to: after.mallocSizeInUseBytes
            ),
            mallocSizeAllocatedBytes: signedDelta(
                from: before.mallocSizeAllocatedBytes,
                to: after.mallocSizeAllocatedBytes
            ),
            residentBytes: signedDelta(
                from: before.residentBytes,
                to: after.residentBytes
            ),
            physicalFootprintBytes: signedDelta(
                from: before.physicalFootprintBytes,
                to: after.physicalFootprintBytes
            )
        )
    }

    private func signedDelta(from before: UInt64, to after: UInt64) -> Int64 {
        if after >= before {
            return Int64(clamping: after - before)
        }
        return -Int64(clamping: before - after)
    }

    private func measuredMilliseconds(
        _ operation: () async throws -> Void
    ) async throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }

    private func visibleBytes(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        try SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 0)
            + SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 1)
    }

    private func compare(_ reference: [UInt8], _ observed: [UInt8]) -> Difference {
        XCTAssertEqual(reference.count, observed.count)
        var differing = 0
        var maximum = 0
        for (lhs, rhs) in zip(reference, observed) {
            let difference = abs(Int(lhs) - Int(rhs))
            if difference != 0 { differing += 1 }
            maximum = max(maximum, difference)
        }
        return Difference(
            differingSamples: differing,
            maximumAbsoluteCodeDifference: maximum,
            sampleCount: min(reference.count, observed.count)
        )
    }
}

private let deterministicMetalTestEnvironment = RuntimeEnvironment(
    operatingSystem: RuntimeOperatingSystem(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    ),
    capabilityProbe: DeterministicMetalTestCapabilityProbe()
)

private struct DeterministicMetalTestCapabilityProbe: BackendCapabilityProbing {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability {
        .available
    }
}
