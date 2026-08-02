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

final class MirmirDashboardTelemetryTests: XCTestCase {
    func testFirstSamplePublishesMemoryAndCumulativeIOWithoutRates() {
        let current = counters(
            timestamp: 1_000,
            user: 100,
            system: 25,
            resident: 8_192,
            footprint: 4_096,
            read: 3_000,
            written: 2_000
        )

        let snapshot = MirmirTelemetryCalculator.snapshot(
            previous: nil,
            current: current,
            timebase: MirmirMachTimebase(numerator: 1, denominator: 1)
        )

        XCTAssertNil(snapshot.processCPUPercent)
        XCTAssertNil(snapshot.diskReadBytesPerSecond)
        XCTAssertNil(snapshot.diskWrittenBytesPerSecond)
        XCTAssertEqual(snapshot.residentBytes, 8_192)
        XCTAssertEqual(snapshot.physicalFootprintBytes, 4_096)
        XCTAssertEqual(snapshot.cumulativeDiskReadBytes, 3_000)
        XCTAssertEqual(snapshot.cumulativeDiskWrittenBytes, 2_000)
    }

    func testTelemetryRatesUseIndependentCounterDeltas() throws {
        let previous = counters(
            timestamp: 1_000_000_000,
            user: 100_000_000,
            system: 50_000_000,
            read: 500,
            written: 1_000
        )
        let current = counters(
            timestamp: 2_000_000_000,
            user: 300_000_000,
            system: 100_000_000,
            read: 1_500,
            written: 3_500
        )

        let snapshot = MirmirTelemetryCalculator.snapshot(
            previous: previous,
            current: current,
            timebase: MirmirMachTimebase(numerator: 1, denominator: 1)
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.processCPUPercent),
            25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.diskReadBytesPerSecond),
            1_000,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.diskWrittenBytesPerSecond),
            2_500,
            accuracy: 0.000_001
        )
    }

    func testTelemetryCPUPercentageIsNotCappedAtOneCore() throws {
        let previous = counters(timestamp: 1_000_000_000)
        let current = counters(
            timestamp: 2_000_000_000,
            user: 2_000_000_000,
            system: 500_000_000
        )

        let snapshot = MirmirTelemetryCalculator.snapshot(
            previous: previous,
            current: current,
            timebase: MirmirMachTimebase(numerator: 1, denominator: 1)
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.processCPUPercent),
            250,
            accuracy: 0.000_001
        )
    }

    func testCounterRegressionInvalidatesOnlyAffectedRate() throws {
        let previous = counters(
            timestamp: 1_000_000_000,
            user: 100,
            system: 100,
            read: 2_000,
            written: 500
        )
        let current = counters(
            timestamp: 2_000_000_000,
            user: 200,
            system: 200,
            read: 1_000,
            written: 1_500
        )

        let snapshot = MirmirTelemetryCalculator.snapshot(
            previous: previous,
            current: current,
            timebase: MirmirMachTimebase(numerator: 1, denominator: 1)
        )

        XCTAssertNil(snapshot.diskReadBytesPerSecond)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.diskWrittenBytesPerSecond),
            1_000,
            accuracy: 0.000_001
        )
        XCTAssertNotNil(snapshot.processCPUPercent)
    }

    func testLiveProcessSamplerReturnsAUsableSnapshot() throws {
        let counters = try MirmirSystemProcessTelemetrySampler().sample()

        XCTAssertGreaterThan(counters.timestampTicks, 0)
        XCTAssertGreaterThan(counters.physicalFootprintBytes, 0)
        XCTAssertGreaterThan(counters.residentBytes, 0)
    }

    private func counters(
        timestamp: UInt64,
        user: UInt64 = 0,
        system: UInt64 = 0,
        resident: UInt64 = 0,
        footprint: UInt64 = 0,
        read: UInt64 = 0,
        written: UInt64 = 0
    ) -> MirmirProcessTelemetryCounters {
        MirmirProcessTelemetryCounters(
            timestampTicks: timestamp,
            userNanoseconds: user,
            systemNanoseconds: system,
            residentBytes: resident,
            physicalFootprintBytes: footprint,
            diskReadBytes: read,
            diskWrittenBytes: written
        )
    }
}

private struct WaitingVideoProbe: VideoProbing {
    func probe(url: URL) async throws -> VideoInfo {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}
