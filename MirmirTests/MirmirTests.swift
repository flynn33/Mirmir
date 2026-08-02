import CoreMedia
import XCTest
@testable import Mirmir

final class MirmirTests: XCTestCase {
    @MainActor
    func testInitialStateIsEmpty() {
        let viewModel = MirmirViewModel()
        XCTAssertEqual(viewModel.state, .empty)
    }

    @MainActor
    func testSelectingFileURLAndClearingUpdatesState() {
        let viewModel = MirmirViewModel(videoProbe: WaitingVideoProbe())
        let videoURL = URL(fileURLWithPath: "/tmp/example.mov")

        viewModel.selectVideo(videoURL)
        XCTAssertEqual(viewModel.state, .probing(videoURL))

        viewModel.clear()
        XCTAssertEqual(viewModel.state, .empty)
    }

    @MainActor
    func testSelectingNonFileURLShowsFailure() {
        let viewModel = MirmirViewModel()

        viewModel.selectVideo(URL(string: "https://example.com/video.mov")!)

        XCTAssertEqual(
            viewModel.state,
            .failed(.invalidRequest("Select a video file stored on this Mac."))
        )
    }

    @MainActor
    func testRootViewFormatsOutOfRangeAndRoundedZeroFactsAsUnknown() {
        let rootView = RootView(
            viewModel: MirmirViewModel(videoProbe: WaitingVideoProbe())
        )

        XCTAssertEqual(
            rootView.sizeText(
                CGSize(width: CGFloat(Int.max), height: 180)
            ),
            "Unknown"
        )
        XCTAssertEqual(
            rootView.sizeText(CGSize(width: 0.0009, height: 180)),
            "Unknown"
        )
        XCTAssertEqual(
            rootView.durationText(
                CMTime(value: CMTimeValue.max, timescale: 1)
            ),
            "Unknown"
        )
    }
}

private struct WaitingVideoProbe: VideoProbing {
    func probe(url: URL) async throws -> VideoInfo {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}
