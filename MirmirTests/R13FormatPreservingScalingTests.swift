import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class R13FormatPreservingScalingTests: XCTestCase {
    func testMPSScalersPreserveEveryDeclaredVideoFormat() throws {
        let displayVolume = Data((0..<24).map(UInt8.init))
        let contentLight = Data([0x05, 0x06, 0x07, 0x08])
        let formats: [MediaVideoFormat] = [
            .sdrBT709,
            .sdrBT709TenBit,
            .sdrBT2020TenBit,
            .hdrBT2020PQ(
                masteringDisplayColorVolume: displayVolume,
                contentLightLevelInfo: contentLight
            ),
            .hdrBT2020HLG(
                masteringDisplayColorVolume: displayVolume,
                contentLightLevelInfo: contentLight
            ),
            .sdrBT709WithAlpha(mode: .straight),
            .sdrBT709WithAlpha(mode: .premultiplied)
        ]

        for mode in R03MPSScalingMode.allCases {
            for format in formats {
                let source = try makeBuffer(
                    resolution:
                        VideoResolution(width: 4, height: 4),
                    format: format
                )
                let destination = try makeBuffer(
                    resolution:
                        VideoResolution(width: 8, height: 8),
                    format: format,
                    initialize: false
                )
                let scaler = try R13FormatPreservingMPSScaler(
                    mode: mode,
                    sourceResolution:
                        VideoResolution(width: 4, height: 4),
                    targetResolution:
                        VideoResolution(width: 8, height: 8),
                    videoFormat: format
                )

                try scaler.scale(
                    source: source,
                    destination: destination,
                    cancellation:
                        AppleUpscaleOperationCancellationSignal()
                )
                scaler.finish()

                try R13MediaVideoFormatContract.validate(
                    destination,
                    resolution:
                        VideoResolution(width: 8, height: 8),
                    format: format
                )
                if format.pixelStorage
                    == .p010VideoRange10Bit {
                    try assertValidP010(destination)
                }
                if format.hasAlpha {
                    try assertAlphaRemainsNonOpaque(
                        destination
                    )
                }
            }
        }
    }

    func testFormatPreservingMPSScalerHonorsCancellation()
        throws {
        let format = MediaVideoFormat.sdrBT2020TenBit
        let source = try makeBuffer(
            resolution: VideoResolution(width: 4, height: 4),
            format: format
        )
        let destination = try makeBuffer(
            resolution: VideoResolution(width: 8, height: 8),
            format: format,
            initialize: false
        )
        let scaler = try R13FormatPreservingMPSScaler(
            mode: .lanczos,
            sourceResolution:
                VideoResolution(width: 4, height: 4),
            targetResolution:
                VideoResolution(width: 8, height: 8),
            videoFormat: format
        )
        let cancellation =
            AppleUpscaleOperationCancellationSignal()
        cancellation.cancel()

        XCTAssertThrowsError(
            try scaler.scale(
                source: source,
                destination: destination,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(
                error as? R03NV12ScalingError,
                .operationCancelled
            )
        }
        scaler.cancel()
    }

    func testVImageScalerPreservesEveryDeclaredVideoFormat() throws {
        let displayVolume = Data((0..<24).map(UInt8.init))
        let contentLight = Data([0x05, 0x06, 0x07, 0x08])
        let formats: [MediaVideoFormat] = [
            .sdrBT709,
            .sdrBT709TenBit,
            .sdrBT2020TenBit,
            .hdrBT2020PQ(
                masteringDisplayColorVolume: displayVolume,
                contentLightLevelInfo: contentLight
            ),
            .hdrBT2020HLG(
                masteringDisplayColorVolume: displayVolume,
                contentLightLevelInfo: contentLight
            ),
            .sdrBT709WithAlpha(mode: .straight),
            .sdrBT709WithAlpha(mode: .premultiplied)
        ]

        for format in formats {
            let source = try makeBuffer(
                resolution: VideoResolution(width: 4, height: 4),
                format: format
            )
            let destination = try makeBuffer(
                resolution: VideoResolution(width: 8, height: 8),
                format: format,
                initialize: false
            )
            let scaler = R13FormatPreservingVImageScaler(
                sourceResolution:
                    VideoResolution(width: 4, height: 4),
                targetResolution:
                    VideoResolution(width: 8, height: 8),
                videoFormat: format,
                quality: .highQuality
            )

            try scaler.scale(
                source: source,
                destination: destination,
                cancellation:
                    AppleUpscaleOperationCancellationSignal()
            )

            try R13MediaVideoFormatContract.validate(
                destination,
                resolution: VideoResolution(width: 8, height: 8),
                format: format
            )
            if format.pixelStorage == .p010VideoRange10Bit {
                try assertValidP010(destination)
            }
            if format.hasAlpha {
                try assertAlphaRemainsNonOpaque(destination)
            }
        }
    }

    func testExtendedEnhancementPreservesP010StorageAndHDRMetadata()
        throws {
        let displayVolume =
            Data((0x10..<(0x10 + 24)).map(UInt8.init))
        let contentLight = Data([0x50, 0x60, 0x70, 0x80])
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume: displayVolume,
            contentLightLevelInfo: contentLight
        )
        let source = try makeBuffer(
            resolution: VideoResolution(width: 8, height: 8),
            format: format
        )
        let processor = try R13ReleaseFormatEnhancementProcessor(
            targetResolution:
                VideoResolution(width: 8, height: 8),
            videoFormat: format,
            temporalConsistencyEnabled: true,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high,
            edgePreservationEnabled: true,
            compressionCleanupEnabled: true,
            textureGrainProtectionEnabled: true,
            temporalStabilityEnabled: true
        )

        let first = try processor.process(source)
        let second = try processor.process(source)

        for output in [first, second] {
            try R13MediaVideoFormatContract.validate(
                output,
                resolution: VideoResolution(width: 8, height: 8),
                format: format
            )
            try assertValidP010(output)
        }
        try processor.finish()
    }

    func testExtendedEnhancementNeverModifiesCurrentFrameAlpha()
        throws {
        let format = MediaVideoFormat.sdrBT709WithAlpha(
            mode: .straight
        )
        let source = try makeBuffer(
            resolution: VideoResolution(width: 8, height: 8),
            format: format
        )
        let processor = try R13ReleaseFormatEnhancementProcessor(
            targetResolution:
                VideoResolution(width: 8, height: 8),
            videoFormat: format,
            temporalConsistencyEnabled: true,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high,
            edgePreservationEnabled: true,
            compressionCleanupEnabled: true,
            textureGrainProtectionEnabled: true,
            temporalStabilityEnabled: true
        )

        let output = try processor.process(source)

        XCTAssertEqual(
            try alphaBytes(output),
            try alphaBytes(source)
        )
        try R13MediaVideoFormatContract.validate(
            output,
            resolution: VideoResolution(width: 8, height: 8),
            format: format
        )
    }

    func testCheckpointCodecRoundTripsP010AndBGRAExactly() throws {
        let formats: [MediaVideoFormat] = [
            .sdrBT2020TenBit,
            .sdrBT709WithAlpha(mode: .premultiplied)
        ]
        let codec = R13LZFSEFrameCacheCodec()
        for format in formats {
            let source = try makeBuffer(
                resolution: VideoResolution(width: 8, height: 8),
                format: format
            )
            let captured =
                try R13NV12Frame.captureTightActivePlanes(
                    from: source
                )
            let decoded = try codec.decode(
                codec.encode(captured).data
            )
            let replay = try decoded.makePixelBuffer(
                videoFormat: format
            )
            let recaptured =
                try R13NV12Frame.captureTightActivePlanes(
                    from: replay
                )

            XCTAssertEqual(decoded, captured)
            XCTAssertEqual(recaptured, captured)
            XCTAssertEqual(
                decoded.pixelFormat,
                format.pixelStorage.pixelFormat
            )
        }
    }

    func testCodecAdmissionRejectsH264BeforeBackendExecution()
        throws {
        for format in [
            MediaVideoFormat.sdrBT709TenBit,
            .hdrBT2020HLG(),
            .sdrBT709WithAlpha(mode: .straight)
        ] {
            XCTAssertThrowsError(
                try R13ReleaseJobContracts.validateOutputCodec(
                    .h264,
                    for: format
                )
            ) { error in
                guard case MediaPipelineError
                    .outputCodecCannotPreserveVideoFormat(
                        codec: .h264,
                        format: format
                    ) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertNoThrow(
                try R13ReleaseJobContracts.validateOutputCodec(
                    .hevc,
                    for: format
                )
            )
        }
        XCTAssertNoThrow(
            try R13ReleaseJobContracts.validateOutputCodec(
                .h264,
                for: .sdrBT709
            )
        )
    }
}

private extension R13FormatPreservingScalingTests {
    func makeBuffer(
        resolution: VideoResolution,
        format: MediaVideoFormat,
        initialize: Bool = true
    ) throws -> CVPixelBuffer {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: format.pixelStorage.pixelFormat,
            capacity: 1
        )
        let buffer = try PixelBufferBridge.dequeue(from: pool)
        R13MediaVideoFormatContract.install(
            format,
            on: buffer,
            resolution: resolution
        )
        if initialize {
            try fill(buffer, format: format)
        }
        return buffer
    }

    func fill(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let fixture =
            try R13PixelLayoutTestFixtures.makeGradientBuffer(
                pixelFormat: format.pixelStorage.pixelFormat,
                width: width,
                height: height
            )
        try R13PixelLayoutProcessor.copy(
            source: fixture,
            destination: pixelBuffer
        )
        R13MediaVideoFormatContract.install(
            format,
            on: pixelBuffer,
            resolution: VideoResolution(width: width, height: height)
        )
    }

    func assertValidP010(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        for plane in 0..<2 {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(
                    pixelBuffer,
                    plane
                )
            ).assumingMemoryBound(to: UInt16.self)
            let stride =
                CVPixelBufferGetBytesPerRowOfPlane(
                    pixelBuffer,
                    plane
                ) / 2
            let width =
                CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
                * (plane == 1 ? 2 : 1)
            let height =
                CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            for row in 0..<height {
                for column in 0..<width {
                    let word = base[row * stride + column]
                    XCTAssertEqual(word & 0x003f, 0)
                    let code = Int(word >> 6)
                    if plane == 0 {
                        XCTAssertTrue((64...940).contains(code))
                    } else {
                        XCTAssertTrue((64...960).contains(code))
                    }
                }
            }
        }
    }

    func assertAlphaRemainsNonOpaque(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let alpha = try alphaBytes(pixelBuffer)
        XCTAssertTrue(alpha.contains(where: { $0 > 0 && $0 < 255 }))
    }

    func alphaBytes(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> [UInt8] {
        let status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return [] }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let base = try XCTUnwrap(
            CVPixelBufferGetBaseAddress(pixelBuffer)
        ).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        return (0..<height).flatMap { row in
            (0..<width).map { column in
                base[row * stride + column * 4 + 3]
            }
        }
    }
}
