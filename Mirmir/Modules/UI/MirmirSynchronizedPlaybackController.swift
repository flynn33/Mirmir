@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class MirmirSynchronizedPlaybackController: ObservableObject {
    let sourcePlayer = AVPlayer()
    let outputPlayer = AVPlayer()
    @Published private(set) var timeline = MirmirSynchronizedPlaybackTimeline()
    private var loadedIdentity: MirmirPlaybackAssetIdentity?
    private var loadTask: Task<Void, Never>?
    private var timeObserverTokens: [MirmirPlaybackTimeObserverToken] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var statusObservations: [NSKeyValueObservation] = []
    private var securityScopedAccess: [(url: URL, started: Bool)] = []
    private var pendingDurations:
        (source: Double, output: Double)?
    private var seekGeneration = 0
    private var seekCompletionCount = 0
    private var seekDidFail = false
    private var isSeekInFlight = false
    private var observerGeneration = 0
    init() {
        sourcePlayer.isMuted = true
        outputPlayer.isMuted = false
        sourcePlayer.actionAtItemEnd = .pause
        outputPlayer.actionAtItemEnd = .pause
        sourcePlayer.automaticallyWaitsToMinimizeStalling = false
        outputPlayer.automaticallyWaitsToMinimizeStalling = false
    }
    deinit {
        loadTask?.cancel()
        sourcePlayer.pause()
        outputPlayer.pause()
        for token in timeObserverTokens {
            outputPlayer.removeTimeObserver(token.value)
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for access in securityScopedAccess where access.started {
            access.url.stopAccessingSecurityScopedResource()
        }
    }
    func load(
        sourceURL: URL,
        completedOutputURL: URL
    ) {
        let identity = MirmirPlaybackAssetIdentity(
            sourceURL: sourceURL,
            completedOutputURL: completedOutputURL
        )
        if loadedIdentity == identity,
           timeline.loadState == .loading || timeline.isReady {
            return
        }

        stopResources(clearIdentity: false)
        loadedIdentity = identity
        timeline.beginLoading()

        guard sourceURL.isFileURL, completedOutputURL.isFileURL else {
            fail(
                "Comparison playback accepts local files only."
            )
            return
        }

        beginSecurityScopedAccess(
            to: [sourceURL, completedOutputURL]
        )

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sourceAsset = try await loadAsset(
                    at: sourceURL,
                    role: .source
                )
                try Task.checkCancellation()
                let outputAsset = try await loadAsset(
                    at: completedOutputURL,
                    role: .completedOutput
                )
                try Task.checkCancellation()

                guard loadedIdentity == identity else { return }
                install(
                    sourceAsset: sourceAsset,
                    outputAsset: outputAsset
                )
                loadTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard loadedIdentity == identity else { return }
                fail(error.localizedDescription)
            }
        }
    }
    func retry() {
        guard let identity = loadedIdentity else { return }
        load(
            sourceURL: identity.sourceURL,
            completedOutputURL: identity.completedOutputURL
        )
    }
    func togglePlayback() {
        if timeline.isPlaying {
            pause()
            return
        }

        guard let startTime = timeline.requestPlay() else { return }
        synchronizedSeek(to: startTime, resumePlayback: true)
    }
    func pause() {
        seekGeneration += 1
        sourcePlayer.pause()
        outputPlayer.pause()
        isSeekInFlight = false
        timeline.pause()
    }
    func beginScrubbing() {
        guard timeline.isReady else { return }
        seekGeneration += 1
        sourcePlayer.pause()
        outputPlayer.pause()
        isSeekInFlight = false
        timeline.beginScrubbing()
    }

    func scrub(to seconds: Double) { timeline.scrub(to: seconds) }

    func finishScrubbing() {
        guard let completion = timeline.finishScrubbing() else { return }
        synchronizedSeek(
            to: completion.time,
            resumePlayback: completion.resumePlayback
        )
    }

    func tearDown() {
        stopResources(clearIdentity: true)
        timeline.reset()
    }

}
private extension MirmirSynchronizedPlaybackController {
    func loadAsset(
        at url: URL,
        role: MirmirPlaybackAssetRole
    ) async throws -> MirmirLoadedPlaybackAsset {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MirmirCompletedPlaybackError.fileMissing(
                role: role,
                filename: url.lastPathComponent
            )
        }

        do {
            let asset = AVURLAsset(url: url)
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                throw MirmirCompletedPlaybackError.notPlayable(role: role)
            }

            let videoTracks = try await asset.loadTracks(
                withMediaType: .video
            )
            guard !videoTracks.isEmpty else {
                throw MirmirCompletedPlaybackError.videoTrackMissing(
                    role: role
                )
            }

            let duration = try await asset.load(.duration)
            let durationSeconds = duration.seconds
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw MirmirCompletedPlaybackError.invalidDuration(
                    role: role
                )
            }

            return MirmirLoadedPlaybackAsset(
                asset: asset,
                durationSeconds: durationSeconds
            )
        } catch let error as MirmirCompletedPlaybackError {
            throw error
        } catch {
            throw MirmirCompletedPlaybackError.assetLoadFailed(
                role: role,
                detail: error.localizedDescription
            )
        }
    }

    private func install(
        sourceAsset: MirmirLoadedPlaybackAsset,
        outputAsset: MirmirLoadedPlaybackAsset
    ) {
        pendingDurations = (
            source: sourceAsset.durationSeconds,
            output: outputAsset.durationSeconds
        )
        let sourceItem = AVPlayerItem(asset: sourceAsset.asset)
        let outputItem = AVPlayerItem(asset: outputAsset.asset)
        sourcePlayer.replaceCurrentItem(with: sourceItem)
        outputPlayer.replaceCurrentItem(with: outputItem)
        let generation = observerGeneration
        observeStatus(
            of: sourceItem,
            role: .source,
            generation: generation
        )
        observeStatus(
            of: outputItem,
            role: .completedOutput,
            generation: generation
        )
        observePlaybackFailure(
            of: sourceItem,
            role: .source,
            generation: generation
        )
        observePlaybackFailure(
            of: outputItem,
            role: .completedOutput,
            generation: generation
        )
        completeReadinessIfPossible(generation: generation)
    }

    private func completeReadinessIfPossible(generation: Int) {
        guard observerGeneration == generation,
              timeline.loadState == .loading,
              let pendingDurations,
              sourcePlayer.currentItem?.status == .readyToPlay,
              outputPlayer.currentItem?.status == .readyToPlay else {
            return
        }
        guard timeline.markReady(
            sourceDuration: pendingDurations.source,
            outputDuration: pendingDurations.output
        ) else {
            fail(
                "The original or upscaled movie has an invalid duration."
            )
            return
        }

        self.pendingDurations = nil
        installTimeObservers(generation: generation)
        MirmirCompletedPlaybackLogging.recordReady(
            durationSeconds: timeline.duration
        )
    }

    private func installTimeObservers(generation: Int) {
        let interval = CMTime(
            seconds: 0.05,
            preferredTimescale: 600
        )
        let periodicToken = outputPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard self?.observerGeneration == generation else {
                    return
                }
                self?.handlePeriodicTime(time)
            }
        }
        timeObserverTokens.append(
            MirmirPlaybackTimeObserverToken(periodicToken)
        )

        let boundaryTime = CMTime(
            seconds: timeline.duration,
            preferredTimescale: 600
        )
        let boundaryToken = outputPlayer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundaryTime)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.observerGeneration == generation else {
                    return
                }
                self?.finishAtEnd()
            }
        }
        timeObserverTokens.append(
            MirmirPlaybackTimeObserverToken(boundaryToken)
        )
    }
    private func observeStatus(
        of item: AVPlayerItem,
        role: MirmirPlaybackAssetRole,
        generation: Int
    ) {
        let observation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self] observedItem, _ in
            let status = observedItem.status
            guard status == .readyToPlay || status == .failed else {
                return
            }
            let detail = status == .failed
                ? observedItem.error?.localizedDescription
                    ?? "The player item could not become ready."
                : nil
            Task { @MainActor [weak self] in
                guard self?.observerGeneration == generation else {
                    return
                }
                if let detail {
                    self?.fail(
                        "\(role.displayName) failed: \(detail). "
                            + role.recoveryGuidance
                    )
                } else {
                    self?.completeReadinessIfPossible(
                        generation: generation
                    )
                }
            }
        }
        statusObservations.append(observation)
    }

    private func observePlaybackFailure(
        of item: AVPlayerItem,
        role: MirmirPlaybackAssetRole,
        generation: Int
    ) {
        let observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let detail = (
                notification.userInfo?[
                    AVPlayerItemFailedToPlayToEndTimeErrorKey
                ] as? Error
            )?.localizedDescription ?? "Playback stopped unexpectedly."
            Task { @MainActor [weak self] in
                guard self?.observerGeneration == generation else {
                    return
                }
                self?.fail(
                    "\(role.displayName) failed: \(detail). "
                        + role.recoveryGuidance
                )
            }
        }
        notificationObservers.append(observer)
    }
    private func handlePeriodicTime(_ time: CMTime) {
        guard timeline.isReady,
              timeline.isPlaying,
              !isSeekInFlight else {
            return
        }

        let outputSeconds = time.seconds
        timeline.recordPlaybackTime(outputSeconds)
        if timeline.hasEnded {
            finishAtEnd()
            return
        }

        let sourceSeconds = sourcePlayer.currentTime().seconds
        guard let target = timeline.correctionTarget(
            sourceTime: sourceSeconds,
            outputTime: outputSeconds
        ) else {
            return
        }

        sourcePlayer.seek(
            to: playerTime(target),
            toleranceBefore: correctionTolerance,
            toleranceAfter: correctionTolerance
        )
    }

}
private extension MirmirSynchronizedPlaybackController {
    func synchronizedSeek(
        to seconds: Double,
        resumePlayback: Bool
    ) {
        guard timeline.isReady else { return }

        sourcePlayer.pause()
        outputPlayer.pause()
        isSeekInFlight = true
        seekGeneration += 1
        let generation = seekGeneration
        seekCompletionCount = 0
        seekDidFail = false
        let target = playerTime(seconds)

        sourcePlayer.seek(
            to: target,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.completeSeek(
                    generation: generation,
                    target: target,
                    resumePlayback: resumePlayback,
                    finished: finished
                )
            }
        }
        outputPlayer.seek(
            to: target,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.completeSeek(
                    generation: generation,
                    target: target,
                    resumePlayback: resumePlayback,
                    finished: finished
                )
            }
        }
    }

    private func completeSeek(
        generation: Int,
        target: CMTime,
        resumePlayback: Bool,
        finished: Bool
    ) {
        guard generation == seekGeneration else { return }

        seekCompletionCount += 1
        seekDidFail = seekDidFail || !finished
        guard seekCompletionCount == 2 else { return }
        isSeekInFlight = false

        if seekDidFail {
            fail("The synchronized playback seek could not be completed.")
            return
        }

        guard resumePlayback, timeline.isPlaying else { return }
        startPlayers(at: target)
    }

    private func startPlayers(at time: CMTime) {
        let leadTime = CMTime(seconds: 0.05, preferredTimescale: 600)
        let hostTime = CMTimeAdd(
            CMClockGetTime(CMClockGetHostTimeClock()),
            leadTime
        )
        sourcePlayer.setRate(1, time: time, atHostTime: hostTime)
        outputPlayer.setRate(1, time: time, atHostTime: hostTime)
    }

    private func finishAtEnd() {
        guard timeline.isReady, !isSeekInFlight else { return }
        seekGeneration += 1
        sourcePlayer.pause()
        outputPlayer.pause()
        timeline.markEnded()
    }

    private func fail(_ message: String) {
        MirmirCompletedPlaybackLogging.recordFailure(message)
        stopResources(clearIdentity: false)
        timeline.markFailed(message)
    }

    private func stopResources(clearIdentity: Bool) {
        loadTask?.cancel()
        loadTask = nil
        seekGeneration += 1
        observerGeneration += 1
        isSeekInFlight = false
        pendingDurations = nil

        sourcePlayer.pause()
        outputPlayer.pause()
        sourcePlayer.cancelPendingPrerolls()
        outputPlayer.cancelPendingPrerolls()

        for token in timeObserverTokens {
            outputPlayer.removeTimeObserver(token.value)
        }
        timeObserverTokens.removeAll()

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
        statusObservations.removeAll()

        sourcePlayer.replaceCurrentItem(with: nil)
        outputPlayer.replaceCurrentItem(with: nil)

        for access in securityScopedAccess where access.started {
            access.url.stopAccessingSecurityScopedResource()
        }
        securityScopedAccess.removeAll()

        if clearIdentity {
            loadedIdentity = nil
        }
    }

    private func beginSecurityScopedAccess(to urls: [URL]) {
        var seenURLs = Set<URL>()
        for url in urls.map(\.standardizedFileURL)
        where seenURLs.insert(url).inserted {
            securityScopedAccess.append(
                (url, url.startAccessingSecurityScopedResource())
            )
        }
    }

    private func playerTime(_ seconds: Double) -> CMTime {
        let clampedSeconds = min(max(seconds, 0), timeline.duration)
        return CMTime(seconds: clampedSeconds, preferredTimescale: 600)
    }

    private var correctionTolerance: CMTime {
        CMTime(value: 6, timescale: 600)
    }
}
