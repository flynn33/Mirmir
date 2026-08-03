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

    func testRouteAvailabilityAcceptsArbitraryRationalUpscaleRoutes() async throws {
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
        let arbitrary = await backend.availability(
            for: source,
            targetSize: CGSize(width: 28, height: 20),
            environment: deterministicTestEnvironment
        )
        XCTAssertEqual(arbitrary, .available)
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

    func testMissingChromaLocationDoesNotInventOrRequireAHiddenFallback() async throws {
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

        try SyntheticNV12PixelBuffer.fill(
            source,
            luma: 91,
            cb: 117,
            cr: 143
        )
        try await prepared.process(
            source: source,
            destination: destination,
            timing: FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 30)
            )
        )
        XCTAssertNil(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferChromaLocationTopFieldKey,
                nil
            )
        )
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

    func testPreparedCheckpointProducesByteIdenticalProgressiveResume()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let backend = try makeBackend()
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 28, height: 20)
        )
        let continuousPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let checkpointPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let resumedPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let continuous = try XCTUnwrap(
            continuousPrepared as? PreparedDeterministicV4Upscaler
        )
        let checkpointSource = try XCTUnwrap(
            checkpointPrepared as? PreparedDeterministicV4Upscaler
        )
        let resumed = try XCTUnwrap(
            resumedPrepared as? PreparedDeterministicV4Upscaler
        )
        let sources = try (0..<3).map { frameIndex in
            let buffer = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12
            )
            try writeMovingPattern(frameIndex: frameIndex, to: buffer)
            attachProgressiveBT709(to: buffer)
            return buffer
        }
        let timings = (0..<3).map { frameIndex in
            FrameTiming(
                frameIndex: frameIndex,
                presentationTime: CMTime(
                    value: Int64(frameIndex),
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30)
            )
        }
        var continuousOutputs: [CVPixelBuffer] = []
        for frameIndex in sources.indices {
            let destination = try SyntheticNV12PixelBuffer.make(
                width: 28,
                height: 20
            )
            try await continuous.process(
                source: sources[frameIndex],
                destination: destination,
                timing: timings[frameIndex]
            )
            continuousOutputs.append(destination)
        }

        for frameIndex in 0...1 {
            let destination = try SyntheticNV12PixelBuffer.make(
                width: 28,
                height: 20
            )
            try await checkpointSource.process(
                source: sources[frameIndex],
                destination: destination,
                timing: timings[frameIndex]
            )
        }
        let planIdentity = ASHSHA256V4(
            rawData: Data("resume-plan-progressive".utf8)
        )
        let checkpointData = try await checkpointSource
            .makeTemporalCheckpoint(
                planSHA256: planIdentity,
                lastCompletedInputOrdinal: 1
            )
        let repeatedCheckpointData = try await checkpointSource
            .makeTemporalCheckpoint(
                planSHA256: planIdentity,
                lastCompletedInputOrdinal: 1
            )
        XCTAssertEqual(
            checkpointData,
            repeatedCheckpointData
        )
        try await resumed.restoreTemporalCheckpoint(
            checkpointData,
            planSHA256: planIdentity
        )
        let resumedOutput = try SyntheticNV12PixelBuffer.make(
            width: 28,
            height: 20
        )
        try await resumed.process(
            source: sources[2],
            destination: resumedOutput,
            timing: timings[2]
        )
        for plane in 0..<2 {
            XCTAssertEqual(
                try SyntheticNV12PixelBuffer.visibleBytes(
                    continuousOutputs[2],
                    plane: plane
                ),
                try SyntheticNV12PixelBuffer.visibleBytes(
                    resumedOutput,
                    plane: plane
                )
            )
        }

        let wrongPlan = ASHSHA256V4(rawData: Data("wrong-plan".utf8))
        await XCTAssertThrowsErrorAsync(
            try await resumed.restoreTemporalCheckpoint(
                checkpointData,
                planSHA256: wrongPlan
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHPreparedTemporalCheckpointV4Error,
                .identityMismatch
            )
        }
    }

    func testInterlacedPreparedPathUsesExactDoubleRateTimingAndResume()
        async throws {
        let sourceInfo = makeSourceInfo(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            fieldCount: 2,
            fieldDetail: kCVImageBufferFieldDetailTemporalTopFirst as String
        )
        let backend = try makeBackend()
        let request = BackendPreparationRequest(
            source: sourceInfo,
            targetSize: CGSize(width: 32, height: 24)
        )
        let continuousPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let checkpointPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let resumedPrepared = try await backend.prepare(
            request: request,
            environment: deterministicTestEnvironment
        )
        let continuous = try XCTUnwrap(
            continuousPrepared as? PreparedDeterministicV4Upscaler
        )
        let checkpointSource = try XCTUnwrap(
            checkpointPrepared as? PreparedDeterministicV4Upscaler
        )
        let resumed = try XCTUnwrap(
            resumedPrepared as? PreparedDeterministicV4Upscaler
        )
        XCTAssertEqual(continuous.maximumOutputFramesPerInput, 2)
        let sources = try (0..<2).map { frameIndex in
            let buffer = try SyntheticNV12PixelBuffer.make(
                width: 16,
                height: 12
            )
            try writeFieldPattern(frameIndex: frameIndex, to: buffer)
            attachProgressiveBT709(to: buffer)
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferFieldCountKey,
                NSNumber(value: 2),
                .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer,
                kCVImageBufferFieldDetailKey,
                kCVImageBufferFieldDetailTemporalTopFirst,
                .shouldPropagate
            )
            return buffer
        }
        let duration = CMTime(value: 1_001, timescale: 30_000)
        let timings = [
            FrameTiming(
                frameIndex: 0,
                presentationTime: CMTime(value: 1_001, timescale: 30_000),
                duration: duration
            ),
            FrameTiming(
                frameIndex: 1,
                presentationTime: CMTime(value: 2_002, timescale: 30_000),
                duration: duration
            )
        ]
        let firstContinuousDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        let firstOutputs = try await continuous.processTemporal(
            source: FramePixelBuffer(sources[0]),
            destinations: firstContinuousDestinations.map(FramePixelBuffer.init),
            timing: timings[0]
        )
        XCTAssertEqual(firstOutputs.count, 2)
        XCTAssertEqual(
            firstOutputs[0].presentationTime,
            CMTime(value: 1_001, timescale: 30_000)
        )
        XCTAssertEqual(
            firstOutputs[1].presentationTime,
            CMTime(value: 1_001, timescale: 20_000)
        )
        for output in firstOutputs {
            XCTAssertEqual(
                (CVBufferCopyAttachment(
                    output.pixelBuffer.value,
                    kCVImageBufferFieldCountKey,
                    nil
                ) as? NSNumber)?.intValue,
                1
            )
            XCTAssertNil(CVBufferCopyAttachment(
                output.pixelBuffer.value,
                kCVImageBufferFieldDetailKey,
                nil
            ))
        }

        let secondContinuousDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        let secondContinuousOutputs = try await continuous.processTemporal(
            source: FramePixelBuffer(sources[1]),
            destinations: secondContinuousDestinations.map(FramePixelBuffer.init),
            timing: timings[1]
        )

        _ = try await checkpointSource.processTemporal(
            source: FramePixelBuffer(sources[0]),
            destinations: try makeDestinations(
                count: 2,
                width: 32,
                height: 24
            ).map(FramePixelBuffer.init),
            timing: timings[0]
        )
        let planIdentity = ASHSHA256V4(
            rawData: Data("resume-plan-interlaced".utf8)
        )
        let checkpointData = try await checkpointSource
            .makeTemporalCheckpoint(
                planSHA256: planIdentity,
                lastCompletedInputOrdinal: 0
            )
        try await resumed.restoreTemporalCheckpoint(
            checkpointData,
            planSHA256: planIdentity
        )
        let resumedDestinations = try makeDestinations(
            count: 2,
            width: 32,
            height: 24
        )
        let resumedOutputs = try await resumed.processTemporal(
            source: FramePixelBuffer(sources[1]),
            destinations: resumedDestinations.map(FramePixelBuffer.init),
            timing: timings[1]
        )
        XCTAssertEqual(
            secondContinuousOutputs.map(\.presentationTime),
            resumedOutputs.map(\.presentationTime)
        )
        for outputIndex in 0..<2 {
            for plane in 0..<2 {
                XCTAssertEqual(
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        secondContinuousOutputs[outputIndex].pixelBuffer.value,
                        plane: plane
                    ),
                    try SyntheticNV12PixelBuffer.visibleBytes(
                        resumedOutputs[outputIndex].pixelBuffer.value,
                        plane: plane
                    )
                )
            }
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ash-p06-cpu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: directory
        )
        return try XCTUnwrap(DeterministicCPUBackend(
            descriptor: descriptor,
            runtimeProvider: .fixed(runtime)
        ))
    }

    private func makeSourceInfo(
        pixelFormat: OSType,
        fieldCount: Int = 1,
        fieldDetail: String? = nil
    ) -> VideoInfo {
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
                fieldCount: fieldCount,
                fieldDetail: fieldDetail,
                alphaModel: .none,
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

    private func makeDestinations(
        count: Int,
        width: Int,
        height: Int
    ) throws -> [CVPixelBuffer] {
        try (0..<count).map { _ in
            try SyntheticNV12PixelBuffer.make(width: width, height: height)
        }
    }

    private func writeMovingPattern(
        frameIndex: Int,
        to buffer: CVPixelBuffer
    ) throws {
        try SyntheticNV12PixelBuffer.fill(
            buffer,
            luma: 16,
            cb: 128,
            cr: 128
        )
        let frame = try PixelBufferSignalCodecV4.read(
            buffer,
            storage: .nv12VideoRange8Bit
        )
        let luma = frame.planes[0]
        var lumaValues: [UInt16] = []
        lumaValues.reserveCapacity(luma.width * luma.height)
        for index in 0..<(luma.width * luma.height) {
            let x = index % luma.width
            let y = index / luma.width
            let code = 16 + ((x * 13 + y * 7 + frameIndex * 29) % 220)
            lumaValues.append(UInt16(code))
        }
        let chroma = frame.planes[1]
        var chromaValues: [UInt16] = []
        chromaValues.reserveCapacity(chroma.samples.count)
        for index in 0..<(chroma.width * chroma.height) {
            chromaValues.append(UInt16(32 + ((index * 5 + frameIndex * 11) % 190)))
            chromaValues.append(UInt16(32 + ((index * 9 + frameIndex * 17) % 190)))
        }
        try PixelBufferSignalCodecV4.write(
            PixelBufferSignalFrameV4(
                storage: frame.storage,
                width: frame.width,
                height: frame.height,
                planes: [
                    try luma.replacingComponent(0, with: lumaValues),
                    try PixelBufferSignalPlaneV4(
                        width: chroma.width,
                        height: chroma.height,
                        componentsPerElement: chroma.componentsPerElement,
                        componentBounds: chroma.componentBounds,
                        samples: chromaValues
                    )
                ]
            ),
            to: buffer
        )
    }

    private func writeFieldPattern(
        frameIndex: Int,
        to buffer: CVPixelBuffer
    ) throws {
        try SyntheticNV12PixelBuffer.fill(
            buffer,
            luma: 16,
            cb: 128,
            cr: 128
        )
        let frame = try PixelBufferSignalCodecV4.read(
            buffer,
            storage: .nv12VideoRange8Bit
        )
        var planes: [PixelBufferSignalPlaneV4] = []
        for (planeIndex, plane) in frame.planes.enumerated() {
            var samples = plane.samples
            for y in 0..<plane.height {
                for x in 0..<plane.width {
                    for component in 0..<plane.componentsPerElement {
                        let index = ((y * plane.width) + x)
                            * plane.componentsPerElement + component
                        let base = y.isMultiple(of: 2) ? 48 : 196
                        samples[index] = UInt16(
                            min(235, base + ((x + component * 7
                                + planeIndex * 11 + frameIndex * 13) % 24))
                        )
                    }
                }
            }
            planes.append(try PixelBufferSignalPlaneV4(
                width: plane.width,
                height: plane.height,
                componentsPerElement: plane.componentsPerElement,
                componentBounds: plane.componentBounds,
                samples: samples
            ))
        }
        try PixelBufferSignalCodecV4.write(
            PixelBufferSignalFrameV4(
                storage: frame.storage,
                width: frame.width,
                height: frame.height,
                planes: planes
            ),
            to: buffer
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
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
