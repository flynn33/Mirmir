import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
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

    func testPremultipliedAlphaPostconditionReconcilesAllFourStorages()
        throws {
        let resolution = VideoResolution(width: 8, height: 8)
        for format in premultipliedAlphaFormats {
            let output = try makeTranslucentAlphaBuffer(
                resolution: resolution,
                format: format,
                validPremultipliedRGB: false
            )
            let pixelFormat = CVPixelBufferGetPixelFormatType(output)
            let alphaBefore = try R13PixelLayoutTestFixtures.alphaCodes(output)
            let propagatedBefore = CVBufferCopyAttachments(
                output,
                .shouldPropagate
            ) as NSDictionary?
            let localKey = "com.mirmir.test.alpha-postcondition" as CFString
            CVBufferSetAttachment(
                output,
                localKey,
                "local-value" as CFString,
                .shouldNotPropagate
            )
            let localBefore = CVBufferCopyAttachments(
                output,
                .shouldNotPropagate
            ) as NSDictionary?

            try R13PremultipliedAlphaOutputPostcondition.reconcile(
                output,
                format: format
            )

            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(output),
                pixelFormat,
                format.description
            )
            XCTAssertEqual(
                try R13PixelLayoutTestFixtures.alphaCodes(output),
                alphaBefore,
                format.description
            )
            XCTAssertEqual(
                CVBufferCopyAttachments(
                    output,
                    .shouldPropagate
                ) as NSDictionary?,
                propagatedBefore,
                format.description
            )
            XCTAssertEqual(
                CVBufferCopyAttachments(
                    output,
                    .shouldNotPropagate
                ) as NSDictionary?,
                localBefore,
                format.description
            )
            try R13MediaVideoFormatContract.validate(
                output,
                resolution: resolution,
                format: format
            )
            try assertPremultipliedRGBDomain(
                output,
                format: format,
                path: "shared-postcondition"
            )
        }
    }

    func testPremultipliedAlphaPostconditionDoesNotTouchStraightAlpha()
        throws {
        let resolution = VideoResolution(width: 8, height: 8)
        for format in straightAlphaFormats {
            let output = try makeTranslucentAlphaBuffer(
                resolution: resolution,
                format: format,
                validPremultipliedRGB: false
            )
            let before = try R13TightPixelFrame(capturing: output)
            let attachmentsBefore = CVBufferCopyAttachments(
                output,
                .shouldPropagate
            ) as NSDictionary?

            try R13PremultipliedAlphaOutputPostcondition.reconcile(
                output,
                format: format
            )

            XCTAssertEqual(
                try R13TightPixelFrame(capturing: output),
                before,
                format.description
            )
            XCTAssertEqual(
                CVBufferCopyAttachments(
                    output,
                    .shouldPropagate
                ) as NSDictionary?,
                attachmentsBefore,
                format.description
            )
        }
    }

    func testSelectableFormatPreservingScalersPublishPremultipliedRGB()
        throws {
        let sourceResolution = VideoResolution(width: 8, height: 8)
        let targetResolution = VideoResolution(width: 12, height: 12)
        for format in premultipliedAlphaFormats {
            let source = try makeTranslucentAlphaBuffer(
                resolution: sourceResolution,
                format: format,
                validPremultipliedRGB: true
            )
            let scalers: [(String, any R03NV12Scaling)] = [
                (
                    "vImage",
                    R13FormatPreservingVImageScaler(
                        sourceResolution: sourceResolution,
                        targetResolution: targetResolution,
                        videoFormat: format,
                        quality: .highQuality
                    )
                ),
                (
                    "MPS",
                    try R13FormatPreservingMPSScaler(
                        mode: .lanczos,
                        sourceResolution: sourceResolution,
                        targetResolution: targetResolution,
                        videoFormat: format
                    )
                ),
                (
                    "Core Image",
                    try R03CoreImageScaler(
                        mode: .lanczos,
                        sourceResolution: sourceResolution,
                        targetResolution: targetResolution,
                        videoFormat: format
                    )
                ),
                (
                    "VT Pixel Transfer",
                    R13FormatPreservingVTPixelTransferScaler(
                        sourceResolution: sourceResolution,
                        targetResolution: targetResolution,
                        videoFormat: format
                    )
                )
            ]

            for (path, scaler) in scalers {
                let destination = try makeBuffer(
                    resolution: targetResolution,
                    format: format,
                    initialize: false
                )
                try scaler.scale(
                    source: source,
                    destination: destination,
                    cancellation: AppleUpscaleOperationCancellationSignal()
                )
                scaler.finish()

                try R13MediaVideoFormatContract.validate(
                    destination,
                    resolution: targetResolution,
                    format: format
                )
                try assertPremultipliedRGBDomain(
                    destination,
                    format: format,
                    path: path
                )
            }
        }
    }

    func testVideoToolboxPixelTransferPreservesEveryRegisteredFormat()
        throws {
        let sourceResolution = VideoResolution(width: 8, height: 8)
        let targetResolution = VideoResolution(width: 12, height: 12)
        let formats = R13PixelLayoutTestFixtures.allMediaVideoFormats
        XCTAssertEqual(formats.count, MediaVideoPixelStorage.allCases.count)

        for format in formats {
            let source = try makeBuffer(
                resolution: sourceResolution,
                format: format
            )
            let destination = try makeBuffer(
                resolution: targetResolution,
                format: format,
                initialize: false
            )
            CVBufferRemoveAllAttachments(destination)
            let scaler = R13FormatPreservingVTPixelTransferScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: format
            )

            try scaler.scale(
                source: source,
                destination: destination,
                cancellation: AppleUpscaleOperationCancellationSignal()
            )
            scaler.finish()

            try R13MediaVideoFormatContract.validate(
                destination,
                resolution: targetResolution,
                format: format
            )
            XCTAssertGreaterThan(
                Set(
                    try R13PixelLayoutTestFixtures.lumaCodes(
                        destination
                    )
                ).count,
                1,
                format.description
            )
            if format.hasAlpha {
                XCTAssertGreaterThan(
                    Set(
                        try R13PixelLayoutTestFixtures.alphaCodes(
                            destination
                        )
                    ).count,
                    1,
                    format.description
                )
            }
            try assertCanonicalTargetGeometry(
                destination,
                resolution: targetResolution
            )
        }
    }

    func testVideoToolboxPixelTransferInstallsHDRMetadata() throws {
        let sourceResolution = VideoResolution(width: 8, height: 8)
        let targetResolution = VideoResolution(width: 12, height: 12)
        let displayVolume = Data((0x20..<(0x20 + 24)).map(UInt8.init))
        let contentLight = Data([0x60, 0x70, 0x80, 0x90])
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume: displayVolume,
            contentLightLevelInfo: contentLight
        )
        let source = try makeBuffer(
            resolution: sourceResolution,
            format: format
        )
        let destination = try makeBuffer(
            resolution: targetResolution,
            format: format,
            initialize: false
        )
        CVBufferRemoveAllAttachments(destination)
        let scaler = R13FormatPreservingVTPixelTransferScaler(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            videoFormat: format
        )

        try scaler.scale(
            source: source,
            destination: destination,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )

        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: targetResolution,
            format: format
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                nil
            ) as? Data,
            displayVolume
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferContentLightLevelInfoKey,
                nil
            ) as? Data,
            contentLight
        )
    }

    func testVideoToolboxPixelTransferReturnsTypedCancellation()
        throws {
        let sourceResolution = VideoResolution(width: 8, height: 8)
        let targetResolution = VideoResolution(width: 12, height: 12)
        let format = MediaVideoFormat.sdrBT709
        let source = try makeBuffer(
            resolution: sourceResolution,
            format: format
        )
        let destination = try makeBuffer(
            resolution: targetResolution,
            format: format,
            initialize: false
        )
        let cancellation = AppleUpscaleOperationCancellationSignal()
        cancellation.cancel()

        XCTAssertThrowsError(
            try R13FormatPreservingVTPixelTransferScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: format
            ).scale(
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
    }

    func testVideoToolboxPixelTransferReturnsTypedFormatFailure()
        throws {
        let sourceResolution = VideoResolution(width: 8, height: 8)
        let targetResolution = VideoResolution(width: 12, height: 12)
        let format = MediaVideoFormat.sdrBT709
        let source = try makeBuffer(
            resolution: sourceResolution,
            format: format
        )
        let destination = try makeBuffer(
            resolution: targetResolution,
            format: .sdrBT709TenBit,
            initialize: false
        )

        XCTAssertThrowsError(
            try R13FormatPreservingVTPixelTransferScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: format
            ).scale(
                source: source,
                destination: destination,
                cancellation: AppleUpscaleOperationCancellationSignal()
            )
        ) { error in
            XCTAssertEqual(
                error as? R03NV12ScalingError,
                .invalidPixelFormat(
                    expected: format.pixelStorage.pixelFormat,
                    actual:
                        MediaVideoFormat.sdrBT709TenBit
                            .pixelStorage.pixelFormat
                )
            )
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
    var premultipliedAlphaFormats: [MediaVideoFormat] {
        [
            .sdrBT709YUV444WithAlpha(mode: .premultiplied),
            .sdrBT709HighPrecisionPackedAlpha(mode: .premultiplied),
            .sdrBT709HighPrecisionAlpha(mode: .premultiplied),
            .sdrBT709WithAlpha(mode: .premultiplied)
        ]
    }

    var straightAlphaFormats: [MediaVideoFormat] {
        [
            .sdrBT709YUV444WithAlpha(mode: .straight),
            .sdrBT709HighPrecisionPackedAlpha(mode: .straight),
            .sdrBT709HighPrecisionAlpha(mode: .straight),
            .sdrBT709WithAlpha(mode: .straight)
        ]
    }

    func makeTranslucentAlphaBuffer(
        resolution: VideoResolution,
        format: MediaVideoFormat,
        validPremultipliedRGB: Bool
    ) throws -> CVPixelBuffer {
        var components: [Float16] = []
        components.reserveCapacity(
            resolution.width * resolution.height * 4
        )
        for row in 0..<resolution.height {
            for column in 0..<resolution.width {
                let phase = Double(
                    (row * resolution.width + column) % 11
                ) / 10
                let alpha = 0.22 + 0.48 * phase
                let rgb: [Double]
                if validPremultipliedRGB {
                    rgb = [
                        0.008 + 0.012 * phase,
                        0.012 + 0.016 * phase,
                        0.016 + 0.020 * phase
                    ]
                } else {
                    rgb = [
                        0.82 + 0.08 * phase,
                        0.76 + 0.10 * phase,
                        0.88 + 0.06 * phase
                    ]
                }
                components.append(contentsOf: rgb.map(Float16.init))
                components.append(Float16(alpha))
            }
        }
        let frame = try R05LinearRGBA16FloatFrame(
            width: resolution.width,
            height: resolution.height,
            components: components
        )
        let pixelBuffer = try makeBuffer(
            resolution: resolution,
            format: format,
            initialize: false
        )
        try R05MetalFXFormatColorBridge.encodeClippingFiniteRGB(
            frame,
            into: pixelBuffer,
            format: format
        )
        R13MediaVideoFormatContract.install(
            format,
            on: pixelBuffer,
            resolution: resolution
        )
        return pixelBuffer
    }

    func assertPremultipliedRGBDomain(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat,
        path: String
    ) throws {
        let frame = try R05MetalFXFormatColorBridge.decode(
            pixelBuffer: pixelBuffer,
            format: format
        )
        let tolerance = format.pixelStorage.bitDepth == 8
            ? 0.01
            : 0.001
        var foundTranslucentColor = false
        for row in 0..<frame.height {
            for column in 0..<frame.width {
                let offset = row * frame.componentsPerRow + column * 4
                let rgb = (0..<3).map {
                    Double(frame.components[offset + $0])
                }
                let alpha = Double(frame.components[offset + 3])
                XCTAssertGreaterThan(
                    alpha,
                    0,
                    "\(path) transparent sample for \(format)."
                )
                XCTAssertLessThan(
                    alpha,
                    1,
                    "\(path) opaque sample for \(format)."
                )
                for color in rgb {
                    XCTAssertLessThanOrEqual(
                        color,
                        alpha + tolerance,
                        "\(path) RGB exceeds alpha for \(format)."
                    )
                    if color > 0 {
                        foundTranslucentColor = true
                    }
                }
            }
        }
        XCTAssertTrue(
            foundTranslucentColor,
            "\(path) flattened translucent color for \(format)."
        )
    }

    func assertCanonicalTargetGeometry(
        _ pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        let cleanAperture = try XCTUnwrap(
            CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferCleanApertureKey,
                nil
            ) as? NSDictionary
        )
        XCTAssertEqual(
            cleanAperture[
                kCVImageBufferCleanApertureWidthKey
            ] as? NSNumber,
            NSNumber(value: resolution.width)
        )
        XCTAssertEqual(
            cleanAperture[
                kCVImageBufferCleanApertureHeightKey
            ] as? NSNumber,
            NSNumber(value: resolution.height)
        )
        let pixelAspectRatio = try XCTUnwrap(
            CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferPixelAspectRatioKey,
                nil
            ) as? NSDictionary
        )
        XCTAssertEqual(
            pixelAspectRatio[
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey
            ] as? NSNumber,
            NSNumber(value: 1)
        )
        XCTAssertEqual(
            pixelAspectRatio[
                kCVImageBufferPixelAspectRatioVerticalSpacingKey
            ] as? NSNumber,
            NSNumber(value: 1)
        )
    }

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
