import CoreMedia
import CoreVideo
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
