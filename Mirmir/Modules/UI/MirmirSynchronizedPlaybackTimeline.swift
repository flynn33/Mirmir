import Foundation

enum MirmirCompletedPlaybackLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

struct MirmirPlaybackScrubCompletion: Equatable, Sendable {
    let time: Double
    let resumePlayback: Bool
}

struct MirmirSynchronizedPlaybackTimeline: Equatable, Sendable {
    static let driftToleranceSeconds = 0.08
    static let endToleranceSeconds = 0.001

    private(set) var loadState: MirmirCompletedPlaybackLoadState = .idle
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isScrubbing = false
    private(set) var hasEnded = false

    private var resumeAfterScrubbing = false

    init() {}

    var isReady: Bool {
        loadState == .ready
    }

    var scrubberUpperBound: Double {
        max(duration, 1)
    }

    mutating func reset() {
        self = Self()
    }

    mutating func beginLoading() {
        self = Self(loadState: .loading)
    }

    @discardableResult
    mutating func markReady(
        sourceDuration: Double,
        outputDuration: Double
    ) -> Bool {
        guard Self.isValidDuration(sourceDuration),
              Self.isValidDuration(outputDuration) else {
            markFailed(
                "The source or completed output has an invalid duration."
            )
            return false
        }

        loadState = .ready
        duration = min(sourceDuration, outputDuration)
        currentTime = 0
        isPlaying = false
        isScrubbing = false
        hasEnded = false
        resumeAfterScrubbing = false
        return true
    }

    mutating func markFailed(_ message: String) {
        let trimmedMessage = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self = Self(
            loadState: .failed(
                trimmedMessage.isEmpty
                    ? "Completed comparison playback failed."
                    : trimmedMessage
            )
        )
    }

    @discardableResult
    mutating func requestPlay() -> Double? {
        guard isReady, !isScrubbing else { return nil }

        if hasEnded || currentTime >= duration {
            currentTime = 0
            hasEnded = false
        }

        isPlaying = true
        return currentTime
    }

    mutating func pause() {
        isPlaying = false
        resumeAfterScrubbing = false
    }

    mutating func beginScrubbing() {
        guard isReady, !isScrubbing else { return }
        resumeAfterScrubbing = isPlaying
        isPlaying = false
        isScrubbing = true
    }

    mutating func scrub(to seconds: Double) {
        guard isReady else { return }
        currentTime = clampedTime(seconds)
        hasEnded = currentTime >= duration
    }

    mutating func finishScrubbing() -> MirmirPlaybackScrubCompletion? {
        guard isReady, isScrubbing else { return nil }

        isScrubbing = false
        let shouldResume = resumeAfterScrubbing && !hasEnded
        resumeAfterScrubbing = false
        isPlaying = shouldResume
        return MirmirPlaybackScrubCompletion(
            time: currentTime,
            resumePlayback: shouldResume
        )
    }

    mutating func recordPlaybackTime(_ seconds: Double) {
        guard isReady,
              isPlaying,
              !isScrubbing,
              seconds.isFinite else {
            return
        }

        currentTime = clampedTime(seconds)
        if duration - currentTime <= Self.endToleranceSeconds {
            markEnded()
        }
    }

    mutating func markEnded() {
        guard isReady else { return }
        currentTime = duration
        isPlaying = false
        isScrubbing = false
        hasEnded = true
        resumeAfterScrubbing = false
    }

    func correctionTarget(
        sourceTime: Double,
        outputTime: Double
    ) -> Double? {
        guard isReady,
              isPlaying,
              !isScrubbing,
              sourceTime.isFinite,
              outputTime.isFinite,
              abs(sourceTime - outputTime)
                > Self.driftToleranceSeconds else {
            return nil
        }

        return clampedTime(outputTime)
    }

    private static func isValidDuration(_ duration: Double) -> Bool {
        duration.isFinite && duration > 0
    }

    private func clampedTime(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), duration)
    }

    private init(loadState: MirmirCompletedPlaybackLoadState) {
        self.loadState = loadState
    }
}
