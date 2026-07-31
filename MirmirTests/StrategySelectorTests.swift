import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest
@testable import Mirmir

final class StrategySelectorTests: XCTestCase {

    func test_1080pToFourK_picksDirect2x() throws {
        let strategy = try StrategySelector.choose(source: .p1080, target: .p2160)
        XCTAssertEqual(strategy, .direct2x)
    }

    func test_720pTo1080p_picksDirect3Over2() throws {
        let strategy = try StrategySelector.choose(source: .p720, target: .p1080)
        XCTAssertEqual(strategy, .direct3Over2)
        XCTAssertEqual(strategy.srOutputResolution(forSource: .p720), .p1080)
    }

    func test_unsupportedSourceTargetPair_throws() {
        XCTAssertThrowsError(try StrategySelector.choose(source: .p2160, target: .p1080))
        XCTAssertThrowsError(try StrategySelector.choose(source: .p720, target: .p2160))
        XCTAssertThrowsError(try StrategySelector.choose(source: .p1080, target: .p1080))
    }

    func test_unsupportedGeometryErrorDoesNotHideAdaptiveProductScope() {
        let error = UpscaleStrategyError.unsupportedResolutionPair(
            source: VideoResolution(width: 1_280, height: 720),
            target: VideoResolution(width: 2_560, height: 1_440)
        )
        let message = error.description

        XCTAssertTrue(message.contains("Automatic and Adaptive"))
        XCTAssertTrue(message.contains("other valid geometries"))
        XCTAssertTrue(message.contains("Direct strategy"))
    }

    func test_videoResolutionScaling() {
        XCTAssertEqual(VideoResolution.p1080.scaled(by: 2), .p2160)
        XCTAssertEqual(VideoResolution.p720.scaled(by: 2), VideoResolution(width: 2560, height: 1440))
    }

    func test_videoResolutionDescriptions() {
        XCTAssertEqual(String(describing: VideoResolution.p1080), "1920x1080")
        XCTAssertEqual(String(describing: VideoResolution.p2160), "3840x2160")
    }

    func test_productVideoOutputSettingsMatchDefaultHEVCPolicy() throws {
        let resolution = VideoResolution(width: 324, height: 192)
        let settings = ProductVideoOutputSettings.make(
            resolution: resolution,
            codec: .hevc
        )
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
        XCTAssertEqual((settings[AVVideoWidthKey] as? NSNumber)?.intValue, 324)
        XCTAssertEqual((settings[AVVideoHeightKey] as? NSNumber)?.intValue, 192)
        let compression = try XCTUnwrap(
            settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            (compression[AVVideoAverageBitRateKey] as? NSNumber)?.intValue,
            2_000_000
        )
        XCTAssertEqual(
            (
                compression[
                    kVTCompressionPropertyKey_FieldCount as String
                ] as? NSNumber
            )?.intValue,
            1
        )
        let color = try XCTUnwrap(
            settings[AVVideoColorPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            color[AVVideoColorPrimariesKey] as? String,
            AVVideoColorPrimaries_ITU_R_709_2
        )
        XCTAssertEqual(
            color[AVVideoTransferFunctionKey] as? String,
            AVVideoTransferFunction_ITU_R_709_2
        )
        XCTAssertEqual(
            color[AVVideoYCbCrMatrixKey] as? String,
            AVVideoYCbCrMatrix_ITU_R_709_2
        )
    }

    func test_productVideoOutputBitRateScalesByCodec() {
        XCTAssertEqual(
            ProductVideoOutputSettings.estimatedBitRate(
                width: 3_840,
                height: 2_160,
                codec: .hevc
            ),
            24_883_200
        )
        XCTAssertEqual(
            ProductVideoOutputSettings.estimatedBitRate(
                width: 3_840,
                height: 2_160,
                codec: .h264
            ),
            37_324_800
        )
    }

    func test_productVideoOutputSettingsConfigureExactP010PQIdentity()
        throws {
        let mastering = Data((0..<24).map(UInt8.init))
        let contentLight = Data([0x03, 0xE8, 0x01, 0x90])
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight
        )
        let settings = ProductVideoOutputSettings.make(
            resolution: VideoResolution(width: 384, height: 216),
            codec: .hevc,
            videoFormat: format
        )

        XCTAssertEqual(
            settings[AVVideoCodecKey] as? AVVideoCodecType,
            .hevc
        )
        let compression = try XCTUnwrap(
            settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            compression[AVVideoProfileLevelKey] as? String,
            kVTProfileLevel_HEVC_Main10_AutoLevel as String
        )
        XCTAssertEqual(
            compression[
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String
            ] as? String,
            kVTHDRMetadataInsertionMode_Auto as String
        )
        XCTAssertEqual(
            compression[
                kVTCompressionPropertyKey_MasteringDisplayColorVolume
                    as String
            ] as? Data,
            mastering
        )
        XCTAssertEqual(
            compression[
                kVTCompressionPropertyKey_ContentLightLevelInfo as String
            ] as? Data,
            contentLight
        )
        let color = try XCTUnwrap(
            settings[AVVideoColorPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            color[AVVideoColorPrimariesKey] as? String,
            AVVideoColorPrimaries_ITU_R_2020
        )
        XCTAssertEqual(
            color[AVVideoTransferFunctionKey] as? String,
            AVVideoTransferFunction_SMPTE_ST_2084_PQ
        )
        XCTAssertEqual(
            color[AVVideoYCbCrMatrixKey] as? String,
            AVVideoYCbCrMatrix_ITU_R_2020
        )
    }

    func test_productVideoOutputSettingsConfigureHEVCWithStraightAlpha()
        throws {
        let format = MediaVideoFormat.sdrBT709WithAlpha(
            mode: .straight
        )
        let settings = ProductVideoOutputSettings.make(
            resolution: VideoResolution(width: 384, height: 216),
            codec: .hevc,
            videoFormat: format
        )

        XCTAssertEqual(
            settings[AVVideoCodecKey] as? AVVideoCodecType,
            .hevcWithAlpha
        )
        let compression = try XCTUnwrap(
            settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        )
        XCTAssertEqual(
            compression[
                kVTCompressionPropertyKey_AlphaChannelMode as String
            ] as? String,
            kVTAlphaChannelMode_StraightAlpha as String
        )
    }

    func test_mediaVideoFormatValidatesP010PoolAndAttachments() throws {
        let format = MediaVideoFormat.hdrBT2020HLG()
        let pool = try PixelBufferBridge.makePool(
            width: 64,
            height: 64,
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            capacity: 1
        )
        let pixelBuffer = try PixelBufferBridge.dequeue(from: pool)

        try format.validate(pixelBuffer: pixelBuffer)
        format.installAttachments(on: pixelBuffer)

        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(pixelBuffer), 2)
        XCTAssertEqual(
            CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                nil
            ) as? String,
            kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                nil
            ) as? String,
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        )
    }
}
