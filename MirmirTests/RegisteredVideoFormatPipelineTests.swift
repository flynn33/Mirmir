import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import XCTest
@testable import Mirmir

// The registered-format matrix intentionally keeps every storage route visible.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class RegisteredVideoFormatPipelineTests: XCTestCase {
    func testPixelStorageRegistryDeclaresExactProcessingSemantics() {
        XCTAssertEqual(MediaVideoPixelStorage.allCases.count, 18)
        XCTAssertEqual(
            Set(MediaVideoPixelStorage.allCases.map(\.pixelFormat)).count,
            MediaVideoPixelStorage.allCases.count
        )

        for storage in MediaVideoPixelStorage.allCases {
            let expected = expectedStorageIdentity(for: storage)
            XCTAssertEqual(
                storage.pixelFormat,
                expected.pixelFormat,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.chromaSampling,
                expected.chromaSampling,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.codeRange,
                expected.codeRange,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.bitDepth,
                expected.bitDepth,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.storedCodeShift,
                expected.storedCodeShift,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.bytesPerComponent,
                expected.bytesPerComponent,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.expectedPlaneCount,
                expected.planeCount,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.alphaBitDepth,
                expected.alphaBitDepth,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.hasAlpha,
                expected.alphaBitDepth != nil,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.usesYCbCr,
                expected.chromaSampling != .rgb,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.isBiPlanar,
                expected.planeCount == 2,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.isTriPlanar,
                expected.planeCount == 3,
                storage.rawValue
            )
            XCTAssertEqual(
                storage.isPacked,
                expected.planeCount == 0,
                storage.rawValue
            )
        }
    }

    func testEveryRegisteredFormatDeclaresItsProductionCodecRoute() {
        for format in registeredVideoFormats {
            let expectedCodecs: [OutputCodec]
            switch format.pixelStorage.chromaSampling {
            case .yuv420:
                expectedCodecs = format.pixelStorage.bitDepth == 8
                    ? [.hevc, .h264]
                    : [.hevc]
            case .yuv422:
                expectedCodecs = format.pixelStorage.bitDepth == 16
                    ? [.proRes422HQ]
                    : [.hevc]
            case .yuv444:
                expectedCodecs = [.proRes4444]
            case .rgb:
                expectedCodecs = [.hevc]
            }
            XCTAssertEqual(
                format.supportedOutputCodecs,
                expectedCodecs,
                format.description
            )
            for codec in OutputCodec.allCases {
                XCTAssertEqual(
                    format.supports(outputCodec: codec),
                    expectedCodecs.contains(codec),
                    "\(format.description)/\(codec.rawValue)"
                )
            }
            XCTAssertEqual(
                format.requiresQuickTimeMovieOutput,
                expectedCodecs.allSatisfy(
                    \.requiresQuickTimeMovieContainer
                ),
                format.description
            )
        }
    }

    func testFormatDescriptionResolverCoversEveryRegisteredStorage()
        throws {
        let resolution = registeredFixtureResolution
        for format in registeredVideoFormats + registeredHDRFormats {
            let description = try makeNon420FormatDescription(
                resolution: resolution,
                format: Non420VideoFixtureFormat(
                    videoFormat: format
                )
            )

            let resolved =
                try AVFoundationMediaPipeline.resolveSupportedVideoFormat(
                    format: description,
                    hasHDRCharacteristic: format.isHDR,
                    hasAlphaCharacteristic: format.hasAlpha
                )

            XCTAssertEqual(resolved, format, format.description)
        }
    }

    func testProductWriterReopensAndDecodesEveryRegisteredCodecRoute()
        async {
        for encodingCase in registeredEncodingCases {
            do {
                let outcome = try await exerciseRegisteredEncoding(
                    encodingCase
                )
                XCTAssertEqual(
                    outcome.result.frameCount,
                    registeredFixtureFrameCount,
                    encodingCase.label
                )
                XCTAssertEqual(
                    outcome.result.resolution,
                    registeredFixtureResolution,
                    encodingCase.label
                )
                XCTAssertEqual(
                    CMTimeCompare(
                        outcome.result.duration,
                        registeredFixtureDuration
                    ),
                    0,
                    encodingCase.label
                )
                XCTAssertGreaterThan(
                    outcome.result.lumaPayloadBytes,
                    0,
                    encodingCase.label
                )
                XCTAssertEqual(
                    outcome.result.chromaPayloadBytes > 0,
                    encodingCase.format.pixelStorage
                        .expectedPlaneCount >= 2,
                    encodingCase.label
                )
                XCTAssertEqual(
                    outcome.result.alphaPayloadBytes > 0,
                    encodingCase.format.pixelStorage
                        .expectedPlaneCount == 3,
                    encodingCase.label
                )
                XCTAssertEqual(
                    outcome.temporaryFileCount,
                    0,
                    encodingCase.label
                )
            } catch {
                XCTFail("\(encodingCase.label): \(error)")
            }
        }
    }

    func testProbeReadsEveryRegisteredNonAlphaUncompressedStorage()
        async {
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        for format in registeredVideoFormats where !format.hasAlpha {
            do {
                let fixture = try MediaOutputFixture(
                    sourceExtension: "mov",
                    destinationExtension: "mov"
                )
                defer { fixture.remove() }
                try await writeUncompressedNon420VideoFixture(
                    to: fixture.source,
                    resolution: registeredFixtureResolution,
                    format: Non420VideoFixtureFormat(
                        videoFormat: format
                    ),
                    frameCount: registeredFixtureFrameCount,
                    frameDuration: registeredFixtureFrameDuration
                )

                let source = try await pipeline.probe(
                    url: fixture.source
                )

                XCTAssertEqual(
                    source.videoFormat,
                    format,
                    format.description
                )
                XCTAssertEqual(
                    source.resolution,
                    registeredFixtureResolution,
                    format.description
                )
            } catch {
                XCTFail("\(format.description): \(error)")
            }
        }
    }

    func testFullPipelinePublishesRepresentativeRegisteredFormats()
        async {
        let mastering = Data((0..<24).map(UInt8.init))
        let contentLight = Data([0x03, 0xE8, 0x01, 0x90])
        let pipelineCases = [
            RegisteredPipelineCase(
                label: "422v-to-hevc-main42210",
                format: .sdrBT709YUV422,
                codec: .hevc,
                sourceKind: .uncompressed
            ),
            RegisteredPipelineCase(
                label: "xf44-pq-to-prores4444",
                format: .hdrBT2020PQYUV444FullRange(
                    masteringDisplayColorVolume: mastering,
                    contentLightLevelInfo: contentLight
                ),
                codec: .proRes4444,
                sourceKind: .compressed
            ),
            RegisteredPipelineCase(
                label: "s4as-straight-to-prores4444",
                format: .sdrBT709HighPrecisionAlpha(
                    mode: .straight
                ),
                codec: .proRes4444,
                sourceKind: .compressed
            ),
            RegisteredPipelineCase(
                label: "bgra-premultiplied-to-hevc-alpha",
                format: .sdrBT709WithAlpha(
                    mode: .premultiplied
                ),
                codec: .hevc,
                sourceKind: .compressed
            )
        ]

        for pipelineCase in pipelineCases {
            do {
                let outcome = try await exerciseRegisteredPipeline(
                    pipelineCase
                )
                XCTAssertEqual(
                    outcome.sourceFormat,
                    pipelineCase.format,
                    pipelineCase.label
                )
                XCTAssertEqual(
                    outcome.outputFrameCount,
                    registeredFixtureFrameCount,
                    pipelineCase.label
                )
                XCTAssertEqual(
                    outcome.verification.frameCount,
                    registeredFixtureFrameCount,
                    pipelineCase.label
                )
                XCTAssertEqual(
                    outcome.temporaryFileCount,
                    0,
                    pipelineCase.label
                )
                XCTAssertTrue(
                    outcome.destinationExists,
                    pipelineCase.label
                )
            } catch {
                XCTFail("\(pipelineCase.label): \(error)")
            }
        }
    }

    func testUnsupportedCodecIsRejectedBeforeOutputTransaction()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let format = MediaVideoFormat.sdrBT709YUV444
        try await writeUncompressedNon420VideoFixture(
            to: fixture.source,
            resolution: registeredFixtureResolution,
            format: Non420VideoFixtureFormat(videoFormat: format),
            frameCount: registeredFixtureFrameCount,
            frameDuration: registeredFixtureFrameDuration
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)

        do {
            _ = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: fixture.destination,
                    resolution: registeredFixtureResolution,
                    codec: .hevc,
                    preserveAudio: false
                )
            )
            XCTFail("Expected exact codec-preservation rejection.")
        } catch let error as MediaPipelineError {
            guard case .outputCodecCannotPreserveVideoFormat(
                let codec,
                let rejectedFormat
            ) = error else {
                return XCTFail("Unexpected pipeline error: \(error)")
            }
            XCTAssertEqual(codec, .hevc)
            XCTAssertEqual(rejectedFormat, format)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testProResRouteRejectsNonMOVBeforeOutputTransaction()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mp4"
        )
        defer { fixture.remove() }
        let format = MediaVideoFormat.sdrBT709YUV444TenBitFullRange
        try await writeUncompressedNon420VideoFixture(
            to: fixture.source,
            resolution: registeredFixtureResolution,
            format: Non420VideoFixtureFormat(videoFormat: format),
            frameCount: registeredFixtureFrameCount,
            frameDuration: registeredFixtureFrameDuration
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)

        do {
            _ = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: fixture.destination,
                    resolution: registeredFixtureResolution,
                    codec: .proRes4444,
                    preserveAudio: false
                )
            )
            XCTFail("Expected exact ProRes container rejection.")
        } catch let error as MediaPipelineError {
            guard case .outputContainerCannotPreserveCodec(
                let pathExtension,
                let rejectedCodec
            ) = error else {
                return XCTFail("Unexpected pipeline error: \(error)")
            }
            XCTAssertEqual(pathExtension, "mp4")
            XCTAssertEqual(rejectedCodec, .proRes4444)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
    }

    func testRegisteredFormatVerificationFailureCannotPublish()
        async throws {
        let fixture = try MediaOutputFixture(
            sourceExtension: "mov",
            destinationExtension: "mov"
        )
        defer { fixture.remove() }
        let format = MediaVideoFormat.sdrBT709YUV422
        try await writeUncompressedNon420VideoFixture(
            to: fixture.source,
            resolution: registeredFixtureResolution,
            format: Non420VideoFixtureFormat(videoFormat: format),
            frameCount: registeredFixtureFrameCount,
            frameDuration: registeredFixtureFrameDuration
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            outputVerifier: RejectingOutputMediaVerifier()
        )
        let source = try await pipeline.probe(url: fixture.source)
        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: registeredFixtureResolution,
                codec: .hevc,
                preserveAudio: false
            )
        )
        while let record = try await session.nextSourceFrame() {
            let output = try PixelBufferBridge.dequeue(
                from: session.outputPixelBufferPool
            )
            try copyRegisteredVideoPayload(
                from: record.pixelBuffer,
                to: output
            )
            try await session.appendOutput(
                pixelBuffer: output,
                timing: record.timing
            )
        }

        do {
            try await session.finish()
            XCTFail("Expected injected reopen verification failure.")
        } catch let error as MediaPipelineError {
            guard case .outputVerificationFailed = error else {
                return XCTFail("Unexpected pipeline error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        XCTAssertTrue(fixture.recognizedTemporaryFiles().isEmpty)
        XCTAssertNil(session.terminalCleanupError)
    }
}

private struct RegisteredStorageIdentity {
    let pixelFormat: OSType
    let chromaSampling: MediaVideoChromaSampling
    let codeRange: MediaVideoCodeRange
    let bitDepth: Int
    let storedCodeShift: Int
    let bytesPerComponent: Int
    let planeCount: Int
    let alphaBitDepth: Int?
}

private struct RegisteredEncodingCase {
    let label: String
    let format: MediaVideoFormat
    let codec: OutputCodec
}

private struct RegisteredEncodingOutcome {
    let result: OutputMediaVerificationResult
    let temporaryFileCount: Int
}

private enum RegisteredSourceKind {
    case uncompressed
    case compressed
}

private struct RegisteredPipelineCase {
    let label: String
    let format: MediaVideoFormat
    let codec: OutputCodec
    let sourceKind: RegisteredSourceKind
}

private struct RegisteredPipelineOutcome {
    let sourceFormat: MediaVideoFormat
    let outputFrameCount: Int
    let verification: OutputMediaVerificationResult
    let temporaryFileCount: Int
    let destinationExists: Bool
}

private enum RegisteredVideoFormatTestError: Error {
    case sourceFormatMismatch(
        expected: MediaVideoFormat,
        actual: MediaVideoFormat
    )
    case pixelFormatMismatch(expected: OSType, actual: OSType)
    case dimensionsMismatch
    case planeCountMismatch(expected: Int, actual: Int)
    case missingBaseAddress(planeIndex: Int?)
    case lockFailed(CVReturn)
    case destinationMissing
}

private let registeredFixtureResolution = VideoResolution(
    width: 64,
    height: 64
)
private let registeredFixtureFrameCount = 2
private let registeredFixtureFrameDuration = CMTime(
    value: 1,
    timescale: 30
)
private let registeredFixtureDuration = CMTime(
    value: Int64(registeredFixtureFrameCount),
    timescale: registeredFixtureFrameDuration.timescale
)

private var registeredVideoFormats: [MediaVideoFormat] {
    [
        .sdrBT709,
        .sdrBT709FullRange,
        .sdrBT709TenBit,
        .sdrBT709TenBitFullRange,
        .sdrBT709YUV422,
        .sdrBT709YUV422FullRange,
        .sdrBT709YUV422TenBit,
        .sdrBT709YUV422TenBitFullRange,
        .sdrBT709YUV422SixteenBit,
        .sdrBT709YUV444,
        .sdrBT709YUV444FullRange,
        .sdrBT709YUV444TenBit,
        .sdrBT709YUV444TenBitFullRange,
        .sdrBT709YUV444SixteenBit,
        .sdrBT709YUV444WithAlpha(mode: .straight),
        .sdrBT709HighPrecisionPackedAlpha(
            mode: .premultiplied
        ),
        .sdrBT709HighPrecisionAlpha(mode: .straight),
        .sdrBT709WithAlpha(mode: .premultiplied)
    ]
}

private var registeredHDRFormats: [MediaVideoFormat] {
    let mastering = Data((0..<24).map(UInt8.init))
    let contentLight = Data([0x03, 0xE8, 0x01, 0x90])
    return [
        .hdrBT2020PQ(
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLG(),
        .hdrBT2020PQYUV444FullRange(
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLGYUV444FullRange()
    ]
}

private var registeredEncodingCases: [RegisteredEncodingCase] {
    let sdrCases = registeredVideoFormats.flatMap { format in
        format.supportedOutputCodecs.map { codec in
            RegisteredEncodingCase(
                label:
                    "\(format.pixelStorage.rawValue)-\(codec.rawValue)",
                format: format,
                codec: codec
            )
        }
    }
    let hdrCases = registeredHDRFormats.map { format in
        RegisteredEncodingCase(
            label:
                "\(format.pixelStorage.rawValue)-"
                    + "\(format.transferFunction.rawValue)-"
                    + "\(format.supportedOutputCodecs[0].rawValue)",
            format: format,
            codec: format.supportedOutputCodecs[0]
        )
    }
    return sdrCases + hdrCases
}

private func exerciseRegisteredEncoding(
    _ encodingCase: RegisteredEncodingCase
) async throws -> RegisteredEncodingOutcome {
    let fixture = try MediaOutputFixture(
        sourceExtension: "mov",
        destinationExtension: "mov"
    )
    defer { fixture.remove() }
    try await writeCompressedRegisteredVideoFixture(
        to: fixture.destination,
        resolution: registeredFixtureResolution,
        videoFormat: encodingCase.format,
        codec: encodingCase.codec,
        frameCount: registeredFixtureFrameCount,
        frameDuration: registeredFixtureFrameDuration
    )
    let result = try await OutputMediaVerifier().verify(
        url: fixture.destination,
        expectation: OutputMediaVerificationExpectation(
            resolution: registeredFixtureResolution,
            codec: encodingCase.codec,
            timing: try registeredFixtureTiming(),
            videoColor: .preserving(
                encodingCase.format,
                codec: encodingCase.codec
            )
        )
    )
    return RegisteredEncodingOutcome(
        result: result,
        temporaryFileCount:
            fixture.recognizedTemporaryFiles().count
    )
}

private func exerciseRegisteredPipeline(
    _ pipelineCase: RegisteredPipelineCase
) async throws -> RegisteredPipelineOutcome {
    let fixture = try MediaOutputFixture(
        sourceExtension: "mov",
        destinationExtension: "mov"
    )
    defer { fixture.remove() }
    switch pipelineCase.sourceKind {
    case .uncompressed:
        try await writeUncompressedNon420VideoFixture(
            to: fixture.source,
            resolution: registeredFixtureResolution,
            format: Non420VideoFixtureFormat(
                videoFormat: pipelineCase.format
            ),
            frameCount: registeredFixtureFrameCount,
            frameDuration: registeredFixtureFrameDuration
        )
    case .compressed:
        try await writeCompressedRegisteredVideoFixture(
            to: fixture.source,
            resolution: registeredFixtureResolution,
            videoFormat: pipelineCase.format,
            codec: pipelineCase.codec,
            frameCount: registeredFixtureFrameCount,
            frameDuration: registeredFixtureFrameDuration
        )
    }
    let pipeline = AVFoundationMediaPipeline(
        metal: NoopMetalRenderingService()
    )
    let source = try await pipeline.probe(url: fixture.source)
    guard source.videoFormat == pipelineCase.format else {
        throw RegisteredVideoFormatTestError.sourceFormatMismatch(
            expected: pipelineCase.format,
            actual: source.videoFormat
        )
    }
    let session = try await pipeline.beginSession(
        source: source,
        output: OutputProfile(
            url: fixture.destination,
            resolution: registeredFixtureResolution,
            codec: pipelineCase.codec,
            preserveAudio: false
        )
    )
    defer { session.cancel() }
    var timing = FrameTimingLedger()
    while let record = try await session.nextSourceFrame() {
        let output = try PixelBufferBridge.dequeue(
            from: session.outputPixelBufferPool
        )
        try copyRegisteredVideoPayload(
            from: record.pixelBuffer,
            to: output
        )
        try await session.appendOutput(
            pixelBuffer: output,
            timing: record.timing
        )
        try timing.append(record.timing)
    }
    try await session.finish()
    guard FileManager.default.fileExists(
        atPath: fixture.destination.path
    ) else {
        throw RegisteredVideoFormatTestError.destinationMissing
    }
    let verification = try await OutputMediaVerifier().verify(
        url: fixture.destination,
        expectation: OutputMediaVerificationExpectation(
            resolution: registeredFixtureResolution,
            codec: pipelineCase.codec,
            timing: timing.snapshot,
            videoColor: .preserving(
                pipelineCase.format,
                codec: pipelineCase.codec
            )
        )
    )
    return RegisteredPipelineOutcome(
        sourceFormat: source.videoFormat,
        outputFrameCount: timing.snapshot.frameCount,
        verification: verification,
        temporaryFileCount:
            fixture.recognizedTemporaryFiles().count,
        destinationExists: true
    )
}

private func registeredFixtureTiming() throws
    -> FrameTimingLedgerSnapshot {
    var timing = FrameTimingLedger()
    for frameIndex in 0..<registeredFixtureFrameCount {
        try timing.append(
            FrameTiming(
                frameIndex: frameIndex,
                presentationTime: CMTimeMultiply(
                    registeredFixtureFrameDuration,
                    multiplier: Int32(frameIndex)
                ),
                duration: registeredFixtureFrameDuration
            )
        )
    }
    return timing.snapshot
}

private func copyRegisteredVideoPayload(
    from source: CVPixelBuffer,
    to destination: CVPixelBuffer
) throws {
    let sourceFormat = CVPixelBufferGetPixelFormatType(source)
    let destinationFormat =
        CVPixelBufferGetPixelFormatType(destination)
    guard sourceFormat == destinationFormat else {
        throw RegisteredVideoFormatTestError.pixelFormatMismatch(
            expected: sourceFormat,
            actual: destinationFormat
        )
    }
    guard CVPixelBufferGetWidth(source)
            == CVPixelBufferGetWidth(destination),
          CVPixelBufferGetHeight(source)
            == CVPixelBufferGetHeight(destination) else {
        throw RegisteredVideoFormatTestError.dimensionsMismatch
    }
    let sourcePlaneCount = CVPixelBufferGetPlaneCount(source)
    let destinationPlaneCount =
        CVPixelBufferGetPlaneCount(destination)
    guard sourcePlaneCount == destinationPlaneCount else {
        throw RegisteredVideoFormatTestError.planeCountMismatch(
            expected: sourcePlaneCount,
            actual: destinationPlaneCount
        )
    }

    let sourceLock = CVPixelBufferLockBaseAddress(
        source,
        .readOnly
    )
    guard sourceLock == kCVReturnSuccess else {
        throw RegisteredVideoFormatTestError.lockFailed(sourceLock)
    }
    defer {
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    let destinationLock = CVPixelBufferLockBaseAddress(
        destination,
        []
    )
    guard destinationLock == kCVReturnSuccess else {
        throw RegisteredVideoFormatTestError.lockFailed(
            destinationLock
        )
    }
    defer {
        CVPixelBufferUnlockBaseAddress(destination, [])
    }

    if sourcePlaneCount == 0 {
        guard let sourceAddress =
                CVPixelBufferGetBaseAddress(source),
              let destinationAddress =
                CVPixelBufferGetBaseAddress(destination) else {
            throw RegisteredVideoFormatTestError
                .missingBaseAddress(planeIndex: nil)
        }
        try copyRegisteredRows(
            sourceAddress: sourceAddress,
            sourceBytesPerRow:
                CVPixelBufferGetBytesPerRow(source),
            destinationAddress: destinationAddress,
            destinationBytesPerRow:
                CVPixelBufferGetBytesPerRow(destination),
            rowCount: CVPixelBufferGetHeight(source)
        )
        return
    }

    for planeIndex in 0..<sourcePlaneCount {
        guard let sourceAddress =
                CVPixelBufferGetBaseAddressOfPlane(
                    source,
                    planeIndex
                ),
              let destinationAddress =
                CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    planeIndex
                ) else {
            throw RegisteredVideoFormatTestError
                .missingBaseAddress(planeIndex: planeIndex)
        }
        let sourceHeight = CVPixelBufferGetHeightOfPlane(
            source,
            planeIndex
        )
        let destinationHeight = CVPixelBufferGetHeightOfPlane(
            destination,
            planeIndex
        )
        guard sourceHeight == destinationHeight else {
            throw RegisteredVideoFormatTestError.dimensionsMismatch
        }
        try copyRegisteredRows(
            sourceAddress: sourceAddress,
            sourceBytesPerRow:
                CVPixelBufferGetBytesPerRowOfPlane(
                    source,
                    planeIndex
                ),
            destinationAddress: destinationAddress,
            destinationBytesPerRow:
                CVPixelBufferGetBytesPerRowOfPlane(
                    destination,
                    planeIndex
                ),
            rowCount: sourceHeight
        )
    }
}

private func copyRegisteredRows(
    sourceAddress: UnsafeMutableRawPointer,
    sourceBytesPerRow: Int,
    destinationAddress: UnsafeMutableRawPointer,
    destinationBytesPerRow: Int,
    rowCount: Int
) throws {
    guard sourceBytesPerRow > 0,
          destinationBytesPerRow > 0,
          rowCount > 0 else {
        throw RegisteredVideoFormatTestError.dimensionsMismatch
    }
    let copiedBytes = min(
        sourceBytesPerRow,
        destinationBytesPerRow
    )
    for row in 0..<rowCount {
        let destinationRow = destinationAddress.advanced(
            by: row * destinationBytesPerRow
        )
        memset(destinationRow, 0, destinationBytesPerRow)
        memcpy(
            destinationRow,
            sourceAddress.advanced(
                by: row * sourceBytesPerRow
            ),
            copiedBytes
        )
    }
}

private func expectedStorageIdentity(
    for storage: MediaVideoPixelStorage
) -> RegisteredStorageIdentity {
    switch storage {
    case .nv12VideoRange8Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            chromaSampling: .yuv420,
            codeRange: .video,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .nv12FullRange8Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            chromaSampling: .yuv420,
            codeRange: .full,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .p010VideoRange10Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            chromaSampling: .yuv420,
            codeRange: .video,
            bitDepth: 10,
            storedCodeShift: 6,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .p010FullRange10Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            chromaSampling: .yuv420,
            codeRange: .full,
            bitDepth: 10,
            storedCodeShift: 6,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv422VideoRange8Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
            chromaSampling: .yuv422,
            codeRange: .video,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv422FullRange8Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
            chromaSampling: .yuv422,
            codeRange: .full,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv422VideoRange10Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            chromaSampling: .yuv422,
            codeRange: .video,
            bitDepth: 10,
            storedCodeShift: 6,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv422FullRange10Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
            chromaSampling: .yuv422,
            codeRange: .full,
            bitDepth: 10,
            storedCodeShift: 6,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv422VideoRange16Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
            chromaSampling: .yuv422,
            codeRange: .video,
            bitDepth: 16,
            storedCodeShift: 0,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv444VideoRange8Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
            chromaSampling: .yuv444,
            codeRange: .video,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv444FullRange8Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
            chromaSampling: .yuv444,
            codeRange: .full,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv444VideoRange10Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
            chromaSampling: .yuv444,
            codeRange: .video,
            bitDepth: 10,
            storedCodeShift: 6,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv444FullRange10Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
            chromaSampling: .yuv444,
            codeRange: .full,
            bitDepth: 10,
            storedCodeShift: 6,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv444VideoRange16Bit:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
            chromaSampling: .yuv444,
            codeRange: .video,
            bitDepth: 16,
            storedCodeShift: 0,
            bytesPerComponent: 2,
            planeCount: 2,
            alphaBitDepth: nil
        )
    case .yuv444VideoRange8BitWithAlpha:
        return RegisteredStorageIdentity(
            pixelFormat: kCVPixelFormatType_4444AYpCbCr8,
            chromaSampling: .yuv444,
            codeRange: .video,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 0,
            alphaBitDepth: 8
        )
    case .yuv444VideoRange16BitWithAlpha:
        return RegisteredStorageIdentity(
            pixelFormat: kCVPixelFormatType_4444AYpCbCr16,
            chromaSampling: .yuv444,
            codeRange: .video,
            bitDepth: 16,
            storedCodeShift: 0,
            bytesPerComponent: 2,
            planeCount: 0,
            alphaBitDepth: 16
        )
    case .yuv444VideoRange16BitWithAlphaTriPlanar:
        return RegisteredStorageIdentity(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            chromaSampling: .yuv444,
            codeRange: .video,
            bitDepth: 16,
            storedCodeShift: 0,
            bytesPerComponent: 2,
            planeCount: 3,
            alphaBitDepth: 16
        )
    case .bgra8WithAlpha:
        return RegisteredStorageIdentity(
            pixelFormat: kCVPixelFormatType_32BGRA,
            chromaSampling: .rgb,
            codeRange: .full,
            bitDepth: 8,
            storedCodeShift: 0,
            bytesPerComponent: 1,
            planeCount: 0,
            alphaBitDepth: 8
        )
    }
}
