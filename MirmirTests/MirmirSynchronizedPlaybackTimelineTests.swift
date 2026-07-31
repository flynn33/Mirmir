import AVFoundation
import Foundation
@testable import Mirmir
import XCTest

final class MirmirSynchronizedPlaybackTimelineTests: XCTestCase {
    func test_readyTimelineUsesShorterAssetAsSharedDuration() {
        var timeline = MirmirSynchronizedPlaybackTimeline()

        XCTAssertTrue(
            timeline.markReady(
                sourceDuration: 120,
                outputDuration: 119.75
            )
        )

        XCTAssertEqual(timeline.loadState, .ready)
        XCTAssertEqual(timeline.duration, 119.75, accuracy: 0.000_001)
        XCTAssertEqual(timeline.currentTime, 0)
        XCTAssertTrue(timeline.isReady)
        XCTAssertFalse(timeline.isPlaying)
        XCTAssertFalse(timeline.hasEnded)
    }

    func test_invalidAssetDurationProducesVisibleFailureState() {
        var timeline = MirmirSynchronizedPlaybackTimeline()

        XCTAssertFalse(
            timeline.markReady(
                sourceDuration: .nan,
                outputDuration: 12
            )
        )

        XCTAssertEqual(
            timeline.loadState,
            .failed(
                "The source or completed output has an invalid duration."
            )
        )
        XCTAssertFalse(timeline.isReady)
        XCTAssertEqual(timeline.duration, 0)
    }

    func test_scrubbingClampsTimeAndResumesOnlyWhenPreviouslyPlaying() {
        var timeline = readyTimeline(duration: 60)
        XCTAssertEqual(timeline.requestPlay(), 0)

        timeline.beginScrubbing()
        XCTAssertTrue(timeline.isScrubbing)
        XCTAssertFalse(timeline.isPlaying)

        timeline.scrub(to: 18.5)
        XCTAssertEqual(timeline.currentTime, 18.5, accuracy: 0.000_001)
        XCTAssertEqual(
            timeline.finishScrubbing(),
            MirmirPlaybackScrubCompletion(
                time: 18.5,
                resumePlayback: true
            )
        )
        XCTAssertTrue(timeline.isPlaying)
        XCTAssertFalse(timeline.isScrubbing)

        timeline.beginScrubbing()
        timeline.scrub(to: 200)
        XCTAssertEqual(timeline.currentTime, 60)
        XCTAssertTrue(timeline.hasEnded)
        XCTAssertEqual(
            timeline.finishScrubbing(),
            MirmirPlaybackScrubCompletion(
                time: 60,
                resumePlayback: false
            )
        )
        XCTAssertFalse(timeline.isPlaying)
    }

    func test_pausedScrubDoesNotStartPlayback() {
        var timeline = readyTimeline(duration: 30)

        timeline.beginScrubbing()
        timeline.scrub(to: 12)

        XCTAssertEqual(
            timeline.finishScrubbing(),
            MirmirPlaybackScrubCompletion(
                time: 12,
                resumePlayback: false
            )
        )
        XCTAssertFalse(timeline.isPlaying)
    }

    func test_endThenPlayRequestsReplayFromZero() {
        var timeline = readyTimeline(duration: 30)
        _ = timeline.requestPlay()

        timeline.markEnded()

        XCTAssertEqual(timeline.currentTime, 30)
        XCTAssertTrue(timeline.hasEnded)
        XCTAssertFalse(timeline.isPlaying)
        XCTAssertEqual(timeline.requestPlay(), 0)
        XCTAssertEqual(timeline.currentTime, 0)
        XCTAssertFalse(timeline.hasEnded)
        XCTAssertTrue(timeline.isPlaying)
    }

    func test_periodicTimeCannotMoveTimelineDuringScrub() {
        var timeline = readyTimeline(duration: 30)
        _ = timeline.requestPlay()
        timeline.beginScrubbing()
        timeline.scrub(to: 10)

        timeline.recordPlaybackTime(15)

        XCTAssertEqual(timeline.currentTime, 10)
        XCTAssertNil(timeline.requestPlay())
    }

    func test_invalidOrPausedPeriodicTimeDoesNotMoveTimeline() {
        var timeline = readyTimeline(duration: 30)

        timeline.recordPlaybackTime(12)
        XCTAssertEqual(timeline.currentTime, 0)

        _ = timeline.requestPlay()
        timeline.recordPlaybackTime(8)
        timeline.recordPlaybackTime(.nan)

        XCTAssertEqual(timeline.currentTime, 8)
    }

    func test_driftCorrectionFollowsOutputLeaderOnlyPastTolerance() {
        var timeline = readyTimeline(duration: 90)
        _ = timeline.requestPlay()

        XCTAssertNil(
            timeline.correctionTarget(
                sourceTime: 10.04,
                outputTime: 10
            )
        )
        XCTAssertEqual(
            timeline.correctionTarget(
                sourceTime: 10.2,
                outputTime: 10
            ),
            10
        )
        XCTAssertEqual(
            timeline.correctionTarget(
                sourceTime: 88,
                outputTime: 100
            ),
            90
        )
    }

    func test_driftCorrectionIsDisabledWhenPausedOrScrubbing() {
        var timeline = readyTimeline(duration: 90)

        XCTAssertNil(
            timeline.correctionTarget(
                sourceTime: 12,
                outputTime: 10
            )
        )

        _ = timeline.requestPlay()
        timeline.beginScrubbing()
        XCTAssertNil(
            timeline.correctionTarget(
                sourceTime: 12,
                outputTime: 10
            )
        )
    }

    func test_loadingAndFailureResetPriorPlaybackState() {
        var timeline = readyTimeline(duration: 20)
        _ = timeline.requestPlay()
        timeline.recordPlaybackTime(8)

        timeline.beginLoading()

        XCTAssertEqual(timeline.loadState, .loading)
        XCTAssertEqual(timeline.duration, 0)
        XCTAssertEqual(timeline.currentTime, 0)
        XCTAssertFalse(timeline.isPlaying)

        timeline.markFailed("  Asset load failed.  ")

        XCTAssertEqual(
            timeline.loadState,
            .failed("Asset load failed.")
        )
        XCTAssertEqual(timeline.scrubberUpperBound, 1)
    }

    func test_assetFailuresProvideRestoreRetryAndLibraryRecovery() {
        let errors: [MirmirCompletedPlaybackError] = [
            .fileMissing(
                role: .completedOutput,
                filename: "finished.mp4"
            ),
            .notPlayable(role: .source),
            .videoTrackMissing(role: .completedOutput),
            .invalidDuration(role: .source),
            .assetLoadFailed(
                role: .completedOutput,
                detail: "Permission denied"
            )
        ]

        for error in errors {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains("Restore or replace"))
            XCTAssertTrue(message.contains("Retry Playback"))
            XCTAssertTrue(message.contains("open Library"))
            XCTAssertTrue(message.contains("reauthorize or reprocess"))
        }
        XCTAssertTrue(
            errors[0].errorDescription?.contains("finished.mp4") == true
        )
    }

    private func readyTimeline(
        duration: Double
    ) -> MirmirSynchronizedPlaybackTimeline {
        var timeline = MirmirSynchronizedPlaybackTimeline()
        XCTAssertTrue(
            timeline.markReady(
                sourceDuration: duration,
                outputDuration: duration
            )
        )
        return timeline
    }
}

@MainActor
final class MirmirSynchronizedPlaybackControllerTests: XCTestCase {
    func test_realMediaReadinessAndTeardown() async throws {
        let fixture = try PlaybackMediaFixture()
        defer { fixture.remove() }
        try await fixture.writePlayableSourceAndOutput()

        let controller = MirmirSynchronizedPlaybackController()
        controller.load(
            sourceURL: fixture.sourceURL,
            completedOutputURL: fixture.outputURL
        )

        let becameReady = await waitUntil {
            controller.timeline.isReady
        }
        let playerItemsWereReadyWhenPublished =
            controller.sourcePlayer.currentItem?.status == .readyToPlay
                && controller.outputPlayer.currentItem?.status
                    == .readyToPlay
        let itemsBecameReady = await waitUntil {
            controller.sourcePlayer.currentItem?.status == .readyToPlay
                && controller.outputPlayer.currentItem?.status
                    == .readyToPlay
        }
        controller.tearDown()

        XCTAssertTrue(becameReady)
        XCTAssertTrue(playerItemsWereReadyWhenPublished)
        XCTAssertTrue(itemsBecameReady)
        XCTAssertFalse(
            controller.sourcePlayer.automaticallyWaitsToMinimizeStalling
        )
        XCTAssertFalse(
            controller.outputPlayer.automaticallyWaitsToMinimizeStalling
        )
        XCTAssertEqual(controller.timeline.loadState, .idle)
        XCTAssertNil(controller.sourcePlayer.currentItem)
        XCTAssertNil(controller.outputPlayer.currentItem)
    }

    func test_realMediaPlayPauseOnly() async throws {
        let fixture = try PlaybackMediaFixture()
        defer { fixture.remove() }
        try await fixture.writePlayableSourceAndOutput()

        let controller = MirmirSynchronizedPlaybackController()
        defer { controller.tearDown() }
        controller.load(
            sourceURL: fixture.sourceURL,
            completedOutputURL: fixture.outputURL
        )

        let becameReady = await waitUntil {
            controller.timeline.isReady
                && controller.sourcePlayer.currentItem?.status == .readyToPlay
                && controller.outputPlayer.currentItem?.status == .readyToPlay
        }
        guard becameReady else {
            return XCTFail("Real local media did not become ready.")
        }

        controller.togglePlayback()
        let startedTogether = await waitUntil {
            controller.sourcePlayer.rate > 0
                && controller.outputPlayer.rate > 0
        }
        let outputClockAdvanced = await waitUntil {
            controller.outputPlayer.currentTime().seconds > 0.08
        }
        let clockDifference = abs(
            controller.sourcePlayer.currentTime().seconds
                - controller.outputPlayer.currentTime().seconds
        )
        controller.pause()

        XCTAssertTrue(startedTogether)
        XCTAssertTrue(outputClockAdvanced)
        XCTAssertLessThanOrEqual(clockDifference, 0.15)
        XCTAssertFalse(controller.timeline.isPlaying)
        XCTAssertEqual(controller.sourcePlayer.rate, 0)
        XCTAssertEqual(controller.outputPlayer.rate, 0)
    }

    func test_realMediaSupportsReadyPlayPauseScrubEndAndReplay()
        async throws {
        let fixture = try PlaybackMediaFixture()
        defer { fixture.remove() }
        try await fixture.writePlayableSourceAndOutput()

        let controller = MirmirSynchronizedPlaybackController()
        defer { controller.tearDown() }
        controller.load(
            sourceURL: fixture.sourceURL,
            completedOutputURL: fixture.outputURL
        )

        let becameReady = await waitUntil {
            controller.timeline.isReady
        }
        XCTAssertTrue(
            becameReady,
            "Real local media did not reach playback readiness."
        )
        let itemsBecameReady = await waitUntil {
            controller.sourcePlayer.currentItem?.status == .readyToPlay
                && controller.outputPlayer.currentItem?.status
                    == .readyToPlay
        }
        XCTAssertTrue(
            itemsBecameReady,
            "Both real AVPlayer items did not become ready."
        )

        controller.togglePlayback()
        let startedTogether = await waitUntil {
            controller.timeline.isPlaying
                && controller.sourcePlayer.rate > 0
                && controller.outputPlayer.rate > 0
        }
        XCTAssertTrue(
            startedTogether,
            "Both players did not start together."
        )
        let outputClockAdvanced = await waitUntil {
            controller.outputPlayer.currentTime().seconds > 0.08
        }
        XCTAssertTrue(
            outputClockAdvanced,
            "The output playback clock did not advance."
        )
        XCTAssertLessThanOrEqual(
            abs(
                controller.sourcePlayer.currentTime().seconds
                    - controller.outputPlayer.currentTime().seconds
            ),
            0.15
        )

        controller.pause()
        XCTAssertFalse(controller.timeline.isPlaying)
        XCTAssertEqual(controller.sourcePlayer.rate, 0)
        XCTAssertEqual(controller.outputPlayer.rate, 0)

        controller.beginScrubbing()
        controller.scrub(to: 0.5)
        controller.finishScrubbing()
        let scrubbedTogether = await waitUntil {
            abs(
                controller.sourcePlayer.currentTime().seconds
                    - 0.5
            ) <= 0.08
                && abs(
                    controller.outputPlayer.currentTime().seconds
                        - 0.5
                ) <= 0.08
        }
        XCTAssertTrue(
            scrubbedTogether,
            "A paused scrub did not seek both players to the same time."
        )
        XCTAssertEqual(
            controller.timeline.currentTime,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertFalse(controller.timeline.isPlaying)

        controller.togglePlayback()
        let reachedEnd = await waitUntil(timeout: 3) {
            controller.timeline.hasEnded
        }
        XCTAssertTrue(
            reachedEnd,
            "Real playback did not reach the shared end state."
        )
        XCTAssertEqual(
            controller.timeline.currentTime,
            controller.timeline.duration,
            accuracy: 0.001
        )
        XCTAssertFalse(controller.timeline.isPlaying)

        controller.togglePlayback()
        let replayed = await waitUntil {
            controller.timeline.isPlaying
                && controller.outputPlayer.rate > 0
                && controller.outputPlayer.currentTime().seconds < 0.4
        }
        XCTAssertTrue(
            replayed,
            "Replay did not seek to zero and restart."
        )
    }

    func test_missingOutputRetryRecoversAfterRealFileIsRestored()
        async throws {
        let fixture = try PlaybackMediaFixture()
        defer { fixture.remove() }
        try await fixture.writePlayableSource()

        let controller = MirmirSynchronizedPlaybackController()
        defer { controller.tearDown() }
        controller.load(
            sourceURL: fixture.sourceURL,
            completedOutputURL: fixture.outputURL
        )

        let reportedMissingOutput = await waitUntil {
            if case .failed = controller.timeline.loadState {
                return true
            }
            return false
        }
        XCTAssertTrue(
            reportedMissingOutput,
            "A missing output did not produce a visible failure."
        )
        guard case .failed(let message) =
                controller.timeline.loadState else {
            return XCTFail("Expected missing-output failure.")
        }
        XCTAssertTrue(message.contains(fixture.outputURL.lastPathComponent))
        XCTAssertTrue(message.contains("Restore or replace"))
        XCTAssertTrue(message.contains("Retry Playback"))
        XCTAssertTrue(message.contains("open Library"))

        try await fixture.writePlayableOutput()
        controller.retry()

        let retryBecameReady = await waitUntil {
            controller.timeline.isReady
        }
        XCTAssertTrue(
            retryBecameReady,
            "Retry did not recover after restoring the real output file."
        )
    }

    func test_unreadableOutputRetryRecoversAfterRealFileIsReplaced()
        async throws {
        let fixture = try PlaybackMediaFixture()
        defer { fixture.remove() }
        try await fixture.writePlayableSource()
        try fixture.writeUnreadableOutput()

        let controller = MirmirSynchronizedPlaybackController()
        defer { controller.tearDown() }
        controller.load(
            sourceURL: fixture.sourceURL,
            completedOutputURL: fixture.outputURL
        )

        let reportedUnreadableOutput = await waitUntil {
            if case .failed = controller.timeline.loadState {
                return true
            }
            return false
        }
        XCTAssertTrue(
            reportedUnreadableOutput,
            "An unreadable output did not produce a visible failure."
        )
        guard case .failed(let message) =
                controller.timeline.loadState else {
            return XCTFail("Expected unreadable-output failure.")
        }
        XCTAssertTrue(message.contains("Verified completed output"))
        XCTAssertTrue(message.contains("Restore or replace"))
        XCTAssertTrue(message.contains("Retry Playback"))
        XCTAssertTrue(message.contains("open Library"))

        try FileManager.default.removeItem(at: fixture.outputURL)
        try await fixture.writePlayableOutput()
        controller.retry()

        let retryBecameReady = await waitUntil {
            controller.timeline.isReady
        }
        XCTAssertTrue(
            retryBecameReady,
            "Retry did not recover after replacing the unreadable output."
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

private struct PlaybackMediaFixture {
    let directoryURL: URL
    let sourceURL: URL
    let outputURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirCompletedPlayback-\(UUID().uuidString)",
                isDirectory: true
            )
        sourceURL = directoryURL.appendingPathComponent("source.mp4")
        outputURL = directoryURL.appendingPathComponent("output.mp4")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
    }

    func writePlayableSourceAndOutput() async throws {
        try await writePlayableSource()
        try await writePlayableOutput()
    }

    func writePlayableSource() async throws {
        try await writePlayableVideo(to: sourceURL)
    }

    func writePlayableOutput() async throws {
        try await writePlayableVideo(to: outputURL)
    }

    func writeUnreadableOutput() throws {
        try Data("not a playable movie".utf8).write(to: outputURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func writePlayableVideo(to url: URL) async throws {
        try await writeVideoFrames(
            to: url,
            resolution: VideoResolution(width: 64, height: 64),
            frameCount: 30,
            frameDuration: CMTime(value: 1, timescale: 30)
        )
    }
}
