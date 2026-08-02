import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class DeterministicCPUBackendTests: XCTestCase {
    func testCanonicalASHCodeAndStrictDecoderExhaustivelyMatchTheFiniteContract() {
        XCTAssertEqual(ASHCode.codewords.count, 16)
        XCTAssertEqual(Set(ASHCode.codewords).count, 16)

        for codeword in ASHCode.codewords {
            XCTAssertTrue(codeword.hasValidIntegrity)
            XCTAssertEqual(codeword.bit(coordinate: 8), 0)
        }

        for leftIndex in ASHCode.codewords.indices {
            for rightIndex in ASHCode.codewords.indices where leftIndex < rightIndex {
                XCTAssertGreaterThanOrEqual(
                    ASHCode.codewords[leftIndex].hammingDistance(
                        to: ASHCode.codewords[rightIndex]
                    ),
                    4
                )
            }
        }

        var exactCount = 0
        var correctedCount = 0
        var uncorrectableCount = 0
        for rawValue in 0..<(1 << ASHState.bitCount) {
            let received = ASHState(validatedRawValue: UInt16(rawValue))
            let decoded = ASHCode.decode(received)
            let bruteForce = bruteForceDecode(received)
            XCTAssertEqual(decoded, bruteForce, "Mismatch for state \(received)")
            switch decoded.status {
            case .exact:
                exactCount += 1
            case .corrected:
                correctedCount += 1
            case .uncorrectable:
                uncorrectableCount += 1
            }
        }
        XCTAssertEqual(exactCount, 16)
        XCTAssertEqual(correctedCount, 144)
        XCTAssertEqual(uncorrectableCount, 352)
    }

    func testCanonicalASHStrictDecoderRejectsEveryTwoBitCodewordCorruption() {
        for codeword in ASHCode.codewords {
            for firstCoordinate in 1..<ASHState.bitCount {
                for secondCoordinate in (firstCoordinate + 1)...ASHState.bitCount {
                    let corrupted = codeword
                        .toggled(coordinate: firstCoordinate)
                        .toggled(coordinate: secondCoordinate)
                    let decoded = ASHCode.decode(corrupted)
                    XCTAssertEqual(decoded.status, .uncorrectable)
                    XCTAssertNil(decoded.codeword)
                    XCTAssertGreaterThanOrEqual(decoded.distance, 2)
                }
            }
        }
    }

    func testCanonicalASHAffineDecoderCorrectsEverySingleBitError() {
        for rawAnchor in 0..<(1 << ASHState.bitCount) {
            let anchor = ASHState(validatedRawValue: UInt16(rawAnchor))
            guard anchor.hasValidIntegrity else { continue }

            for codeword in ASHCode.codewords {
                let expected = anchor.xor(codeword)
                for coordinate in 1...ASHState.bitCount {
                    let decoded = ASHCode.decodeAffine(
                        received: expected.toggled(coordinate: coordinate),
                        anchor: anchor
                    )
                    XCTAssertEqual(decoded.status, .corrected)
                    XCTAssertEqual(decoded.codeword, expected)
                    XCTAssertEqual(decoded.distance, 1)
                    XCTAssertEqual(decoded.nearestCount, 1)
                }
            }
        }
    }

    func testRouteAvailabilityAcceptsOnlyExistingReferenceRoutes() async throws {
        let backend = try makeBackend()
        let source = makeSourceInfo(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let direct2x = await backend.availability(
            for: source,
            targetSize: CGSize(width: 32, height: 24),
            environment: deterministicTestEnvironment
        )
        let direct3Over2 = await backend.availability(
            for: source,
            targetSize: CGSize(width: 24, height: 18),
            environment: deterministicTestEnvironment
        )
        XCTAssertEqual(direct2x, .available)
        XCTAssertEqual(direct3Over2, .available)
        guard case .unavailable(let reason) = await backend.availability(
            for: source,
            targetSize: CGSize(width: 28, height: 20),
            environment: deterministicTestEnvironment
        ) else {
            return XCTFail("An arbitrary deterministic geometry was accepted.")
        }
        XCTAssertEqual(
            reason,
            .unsupportedScaleFactor(
                details: "the CPU reference exposes only exact 2× and 3:2 ASH routes"
            )
        )
    }

    func testRepeatedCPUReferenceFramesAreByteIdenticalForBothNV12Ranges() async throws {
        for pixelFormat in [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ] {
            let sourceInfo = makeSourceInfo(pixelFormat: pixelFormat)
            let backend = try makeBackend()
            let request = BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            )
            let first = try await backend.prepare(
                request: request,
                environment: deterministicTestEnvironment
            )
            let second = try await backend.prepare(
                request: request,
                environment: deterministicTestEnvironment
            )
            let source = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12,
                pixelFormat: pixelFormat
            )
            try SyntheticNV12PixelBuffer.fill(source, luma: 91, cb: 117, cr: 143)
            attachProgressiveBT709(to: source)
            let firstOutput = try SyntheticNV12PixelBuffer.make(
                width: 32,
                height: 24,
                pixelFormat: pixelFormat
            )
            let secondOutput = try SyntheticNV12PixelBuffer.make(
                width: 32,
                height: 24,
                pixelFormat: pixelFormat
            )
            let timing = FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 30)
            )

            try await first.process(
                source: source,
                destination: firstOutput,
                timing: timing
            )
            try await second.process(
                source: source,
                destination: secondOutput,
                timing: timing
            )

            XCTAssertEqual(
                try SyntheticNV12PixelBuffer.visibleBytes(firstOutput, plane: 0),
                try SyntheticNV12PixelBuffer.visibleBytes(secondOutput, plane: 0)
            )
            XCTAssertEqual(
                try SyntheticNV12PixelBuffer.visibleBytes(firstOutput, plane: 1),
                try SyntheticNV12PixelBuffer.visibleBytes(secondOutput, plane: 1)
            )
        }
    }

    func testMissingProgressiveChromaLocationFailsWithoutFallback() async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let backend = try makeBackend()
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            ),
            environment: deterministicTestEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 16, height: 12)
        let destination = try SyntheticNV12PixelBuffer.make(width: 32, height: 24)

        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: FrameTiming(
                    frameIndex: 0,
                    presentationTime: .zero,
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
            XCTFail("Expected an explicit chroma-location failure.")
        } catch let error as MirmirError {
            guard case .backendProcessingFailed(let backendID, _, let details) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(backendID, .mirmirDeterministicCPU)
            XCTAssertTrue(details.contains("no explicit progressive chroma location"))
        }
    }

    func testFinishIsIdempotentAndPreventsFurtherCPUProcessing() async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let backend = try makeBackend()
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: sourceInfo,
                targetSize: CGSize(width: 32, height: 24)
            ),
            environment: deterministicTestEnvironment
        )
        let source = try SyntheticNV12PixelBuffer.make(width: 16, height: 12)
        let destination = try SyntheticNV12PixelBuffer.make(width: 32, height: 24)
        try SyntheticNV12PixelBuffer.fill(source, luma: 91, cb: 117, cr: 143)
        attachProgressiveBT709(to: source)

        try await prepared.finish()
        try await prepared.finish()

        do {
            try await prepared.process(
                source: source,
                destination: destination,
                timing: FrameTiming(
                    frameIndex: 7,
                    presentationTime: .zero,
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
            XCTFail("Expected processing after finish to fail.")
        } catch let error as MirmirError {
            guard case .backendProcessingFailed(let backendID, let frameIndex, let details) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(backendID, .mirmirDeterministicCPU)
            XCTAssertEqual(frameIndex, 7)
            XCTAssertTrue(details.contains("already finished"))
        }
    }

    private func bruteForceDecode(_ received: ASHState) -> ASHDecodeResult {
        let distances = ASHCode.codewords.map { codeword in
            (distance: received.hammingDistance(to: codeword), codeword: codeword)
        }
        let minimum = distances.map(\.distance).min() ?? ASHState.bitCount
        let nearest = distances.filter { $0.distance == minimum }.map(\.codeword)

        guard minimum <= 1, nearest.count == 1, let codeword = nearest.first else {
            return ASHDecodeResult(
                status: .uncorrectable,
                received: received,
                codeword: nil,
                messageBits: nil,
                distance: minimum,
                nearestCount: nearest.count
            )
        }

        return ASHDecodeResult(
            status: minimum == 0 ? .exact : .corrected,
            received: received,
            codeword: codeword,
            messageBits: ASHCode.messageBits(for: codeword),
            distance: minimum,
            nearestCount: 1
        )
    }

    private func makeBackend() throws -> DeterministicCPUBackend {
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        return try XCTUnwrap(DeterministicCPUBackend(descriptor: descriptor))
    }

    private func makeSourceInfo(pixelFormat: OSType) -> VideoInfo {
        let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        return VideoInfo(
            url: URL(fileURLWithPath: "/tmp/deterministic-source.mov"),
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
                isFullRange: fullRange,
                fieldCount: 1,
                fieldDetail: nil,
                hasMasteringDisplayMetadata: false,
                hasContentLightLevelMetadata: false,
                dynamicRange: .sdr
            )
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
}

private let deterministicTestEnvironment = RuntimeEnvironment(
    operatingSystem: RuntimeOperatingSystem(
        OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    ),
    capabilityProbe: DeterministicTestCapabilityProbe()
)

private struct DeterministicTestCapabilityProbe: BackendCapabilityProbing {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability {
        .available
    }
}
