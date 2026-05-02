import XCTest
@testable import Mirmir

final class StrategySelectorTests: XCTestCase {

    func test_1080pToFourK_picksDirect2x() throws {
        let strategy = try StrategySelector.choose(source: .p1080, target: .p2160)
        XCTAssertEqual(strategy, .direct2x)
    }

    func test_720pTo1080p_picksTwoXThenLanczos() throws {
        let strategy = try StrategySelector.choose(source: .p720, target: .p1080)
        XCTAssertEqual(strategy, .twoXThenLanczosDownsample(intermediate: .p1440))
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
}
