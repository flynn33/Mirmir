import CoreMedia
import CoreVideo
import Darwin
import Foundation
import XCTest
@testable import Mirmir

final class DeterministicMetalBackendTests: XCTestCase {
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

    func testPreviewLUTUsesSourceP05ValuesWithoutLockMetadata() throws {
        let lut = try ASHMetalDevelopmentRuntimeFactoryV3.makeLUT(
            route: .direct2x
        )
        let source = ASHSpatialRuntimeConfigurationV2.developmentP05
        let parameters = ASHSpatialDevelopmentParametersV2.p05DevelopmentOnly
        let encoded = lut.configuration.operatorParameters

        XCTAssertEqual(
            encoded.detailGainQ12,
            UInt16((parameters.controlledDetailGain * 4_096).rounded())
        )
        XCTAssertEqual(
            encoded.relaxedLimiterAlphaQ12,
            UInt16((parameters.relaxedLimiterAlpha * 4_096).rounded())
        )
        XCTAssertEqual(lut.configuration.boundaryMode, source.boundaryMode)
        XCTAssertEqual(
            lut.configuration.direct2x.lumaCoordinatePolicy,
            source.coordinatePolicy
        )
        XCTAssertNil(lut.configuration.direct2x.spatialPolicyID)
        XCTAssertEqual(
            Array(lut.immutableBytes[64..<96]),
            try ASHLUTHashV3(hex: source.mappingSHA256).bytes
        )
        XCTAssertEqual(
            Array(lut.immutableBytes[96..<128]),
            try ASHLUTHashV3(hex: source.operatorBankSHA256).bytes
        )
        XCTAssertEqual(
            Array(lut.immutableBytes[128..<256]),
            [UInt8](repeating: 0, count: 128)
        )
        XCTAssertEqual(lut.immutableBytes[300], UInt8.max)
    }

    func testMetalPreviewIsAvailableAndKeepsItsExactBackendIdentity() async throws {
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
            "ash-p05-metal-v3-preview"
        )
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

    func testRealMetalJobsAreRepeatableAndReportCPUReferenceDifferences() async throws {
        for pixelFormat in [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ] {
            for route in ASHSpatialRouteV2.allCases {
                let target = CGSize(
                    width: try route.destinationExtent(for: 16),
                    height: try route.destinationExtent(for: 12)
                )
                let sourceInfo = makeSourceInfo(pixelFormat: pixelFormat)
                let metal = try await makeMetalBackend().prepare(
                    request: BackendPreparationRequest(
                        source: sourceInfo,
                        targetSize: target
                    ),
                    environment: deterministicMetalTestEnvironment
                )
                let concreteMetal = try XCTUnwrap(
                    metal as? PreparedDeterministicMetalUpscaler
                )
                for (frameIndex, pattern) in Pattern.allCases.enumerated() {
                    let cpu = try await makeCPUBackend().prepare(
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
                        destination: firstMetalOutput,
                        timing: timing
                    )
                    try await metal.process(
                        source: source,
                        destination: repeatMetalOutput,
                        timing: FrameTiming(
                            frameIndex: frameIndex + 100,
                            presentationTime: CMTime(
                                value: Int64(frameIndex + 100),
                                timescale: 30
                            ),
                            duration: timing.duration
                        )
                    )

                    let firstBytes = try visibleBytes(firstMetalOutput)
                    let repeatBytes = try visibleBytes(repeatMetalOutput)
                    XCTAssertEqual(
                        firstBytes,
                        repeatBytes,
                        "Metal output changed for \(route.rawValue), \(pattern.rawValue)"
                    )
                    let difference = compare(
                        try visibleBytes(cpuOutput),
                        firstBytes
                    )
                    print(
                        "ASH_METAL_CPU_COMPARISON route=\(route.rawValue) "
                            + "range=\(FourCC.string(from: pixelFormat) ?? String(pixelFormat)) "
                            + "pattern=\(pattern.rawValue) samples=\(difference.sampleCount) "
                            + "differing=\(difference.differingSamples) "
                            + "max_abs_code_difference="
                            + "\(difference.maximumAbsoluteCodeDifference)"
                    )
                    XCTAssertEqual(metal.actualBackendID, .mirmirDeterministicMetal)
                    let lastSummary = await concreteMetal.developmentLastFrameSummary()
                    let summary = try XCTUnwrap(lastSummary)
                    XCTAssertGreaterThan(summary.dispatchCount, 0)
                    XCTAssertGreaterThan(summary.actualOperatorInvocationCount, 0)
                    XCTAssertEqual(summary.fatalFaultCount, 0)
                    XCTAssertEqual(summary.affineFallbackCount, 0)
                }
                try await metal.finish()
            }
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
        return try XCTUnwrap(DeterministicMetalBackend(descriptor: descriptor))
    }

    private func makeCPUBackend() throws -> DeterministicCPUBackend {
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        return try XCTUnwrap(DeterministicCPUBackend(descriptor: descriptor))
    }

    private func makeSourceInfo(pixelFormat: OSType) -> VideoInfo {
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
