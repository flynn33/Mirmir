import AVFoundation
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
}
