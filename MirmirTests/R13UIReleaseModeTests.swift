import Foundation
@testable import Mirmir
import XCTest

@MainActor
final class R13UIReleaseModeTests: XCTestCase {
    func testReleaseModesExposeTruthfulAvailabilityAndAutoCannotSubmit() {
        let engine = R13UIModeEngineService()
        let viewModel = makeReadyViewModel(engine: engine)

        for mode in [UpscaleMode.quality, .fast, .deterministic] {
            viewModel.selectedMode = mode
            XCTAssertTrue(viewModel.canStart, mode.rawValue)
            XCTAssertEqual(viewModel.selectedModeAvailability, .available)
        }

        viewModel.selectedMode = .auto
        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            R13ReleaseModePolicy.autoUnavailableReason
        )
        viewModel.startUpscale()
        XCTAssertTrue(engine.submittedJobs.isEmpty)
        XCTAssertEqual(viewModel.state, .ready)
    }

    func testSelectedModeIsPassedUnchangedIntoSubmittedJob() async throws {
        let engine = R13UIModeEngineService()
        let viewModel = makeReadyViewModel(engine: engine)
        viewModel.selectedMode = .quality

        viewModel.startUpscale()

        XCTAssertEqual(engine.submittedJobs.map(\.mode), [.quality])
        let handle = try XCTUnwrap(engine.latestHandle)
        handle.completeCancellation()
        for _ in 0..<100 where viewModel.state == .running {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.state, .ready)
    }

    func testModeAndNoModelAssetTextMakesNoRelativeClaim() {
        let viewModel = makeReadyViewModel(engine: R13UIModeEngineService())
        viewModel.modelStatus = .notRequired

        XCTAssertEqual(viewModel.modelAssetsStatusText, "No model download required")
        XCTAssertEqual(
            viewModel.modelAssetsDetailText,
            "The selected Apple MPS Lanczos mode uses no downloaded model assets."
        )
        XCTAssertEqual(viewModel.modelSpecializationText, "Specialization not required")

        let releaseModes: [UpscaleMode] = [
            .quality,
            .fast,
            .deterministic
        ]
        XCTAssertEqual(
            Set(releaseModes.map(\.summary)),
            [
                "Uses the same qualified deterministic Apple MPS "
                    + "Lanczos A11 path in this release."
            ]
        )
        XCTAssertEqual(MirmirWorkspaceDestination.modes.title, "Modes")
        XCTAssertEqual(
            UpscaleMode.auto.releasePickerTitle,
            "Auto (Unavailable)"
        )
        XCTAssertEqual(
            MirmirWorkspaceDestination.primary,
            [.dashboard, .library, .upscale, .queue, .modes, .settings]
        )

        let forbiddenClaims = ["better", "faster", "best", "superior", "higher quality"]
        for mode in UpscaleMode.allCases {
            let summary = mode.summary.lowercased()
            for claim in forbiddenClaims {
                XCTAssertFalse(
                    summary.contains(claim),
                    "\(mode.rawValue) contains \(claim)"
                )
            }
        }
    }

    func testRecoveredJobIsExposedAndSubmittedWithItsStableIdentifier()
        async throws {
        let identifier = "r13-ui-recovered-job"
        let sourceURL = URL(fileURLWithPath: "/tmp/r13-ui-recovered.mov")
        let outputURL = URL(fileURLWithPath: "/tmp/r13-ui-recovered.mp4")
        let job = UpscaleJob(
            identifier: identifier,
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            mode: .fast
        )
        let recovered = R13ResolvedRecoverableUpscaleJob(
            summary: try R13RecoverableUpscaleJob(job: job),
            job: job,
            securityAccess: try makeAccessSet(
                sourceURL: sourceURL,
                outputDirectoryURL: outputURL.deletingLastPathComponent()
            )
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered]
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.recoverableJobs.map(\.id), [identifier])

        viewModel.resumeRecoverableJob(id: identifier)
        for _ in 0..<100 where engine.submittedJobs.isEmpty {
            await Task.yield()
        }

        let submitted = try XCTUnwrap(engine.submittedJobs.first)
        XCTAssertEqual(submitted.identifier, identifier)
        XCTAssertEqual(submitted.inputURL, sourceURL)
        XCTAssertEqual(submitted.outputURL, outputURL)
        XCTAssertEqual(submitted.targetResolution, .p2160)
        XCTAssertEqual(submitted.mode, .fast)
        engine.latestHandle?.completeCancellation()
    }

    func testCancelledRecoveryProbeCannotSubmitOrOverwriteState()
        async throws {
        let identifier = "r13-ui-cancelled-recovery"
        let sourceURL = URL(
            fileURLWithPath: "/tmp/r13-ui-cancelled-recovery.mov"
        )
        let outputURL = URL(
            fileURLWithPath: "/tmp/r13-ui-cancelled-recovery.mp4"
        )
        let job = UpscaleJob(
            identifier: identifier,
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p2160,
            preserveAudio: false,
            mode: .deterministic
        )
        let recovered = R13ResolvedRecoverableUpscaleJob(
            summary: try R13RecoverableUpscaleJob(job: job),
            job: job,
            securityAccess: try makeAccessSet(
                sourceURL: sourceURL,
                outputDirectoryURL:
                    outputURL.deletingLastPathComponent()
            )
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered]
        )
        let media = R13SuspendedProbeMediaPipeline()
        let viewModel = MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.resumeRecoverableJob(id: identifier)
        for _ in 0..<100 where !media.probeStarted {
            await Task.yield()
        }
        XCTAssertTrue(media.probeStarted)
        XCTAssertTrue(viewModel.recoveryIsProbing)

        viewModel.cancelRecoveryProbe()
        media.completeProbe(
            SourceProfile(
                url: sourceURL,
                resolution: .p1080,
                frameRate: 30,
                durationSeconds: 1,
                estimatedFrameCount: 30,
                codecHint: nil,
                hasAudio: false
            )
        )
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertTrue(engine.submittedJobs.isEmpty)
        XCTAssertNil(viewModel.sourceProfile)
        XCTAssertFalse(viewModel.recoveryIsProbing)
        XCTAssertEqual(viewModel.state, .idle)
    }

    func testRecoveryCatalogPublishesEveryJobAndRejectedCount()
        async throws {
        let recoveries = try ["first", "second"].map { suffix in
            let job = UpscaleJob(
                identifier: "r13-ui-\(suffix)",
                inputURL: URL(
                    fileURLWithPath: "/tmp/r13-ui-\(suffix).mov"
                ),
                outputURL: URL(
                    fileURLWithPath: "/tmp/r13-ui-\(suffix).mp4"
                ),
                targetResolution: .p2160,
                preserveAudio: false,
                mode: .deterministic
            )
            return R13ResolvedRecoverableUpscaleJob(
                summary: try R13RecoverableUpscaleJob(job: job),
                job: job,
                securityAccess: try makeAccessSet(
                    sourceURL: job.inputURL,
                    outputDirectoryURL:
                        job.outputURL.deletingLastPathComponent()
                )
            )
        }
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: R13UIModeEngineService(
                recoverableJobs: recoveries,
                rejectedEntryCount: 3
            ),
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100
            where viewModel.recoverableJobs.count != recoveries.count {
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.recoverableJobs.map(\.id),
            ["r13-ui-first", "r13-ui-second"]
        )
        XCTAssertEqual(viewModel.recoveryRejectedEntryCount, 3)
    }

    private func makeReadyViewModel(
        engine: R13UIModeEngineService
    ) -> MirmirViewModel {
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        let source = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/r13-ui-source.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: false
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(for: source, target: .p2160)
        ))
        return viewModel
    }

    private func makeAccessSet(
        sourceURL: URL,
        outputDirectoryURL: URL
    ) throws -> R13SecurityScopedAccessSet {
        let bindings: [(R13BookmarkRole, URL)] = [
            (.source, sourceURL),
            (.outputDirectory, outputDirectoryURL)
        ]
        return R13SecurityScopedAccessSet(
            leases: try bindings.map { role, url in
                try R13SecurityScopeLease(
                    role: role,
                    resolved: R13ResolvedSecurityScopedBookmark(
                        url: url,
                        isStale: false,
                        startAccessing: { true },
                        stopAccessing: {}
                    )
                )
            }
        )
    }
}

private final class R13UIModeEngineService:
    UpscalerEngineService,
    R13RecoverableUpscalerEngine,
    @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available

    private let lock = NSLock()
    private let storedRecoverableJobs:
        [R13ResolvedRecoverableUpscaleJob]
    private let rejectedEntryCount: Int
    private var storedHandle: R13UIHoldingJobHandle?
    private var storedJobs: [UpscaleJob] = []

    init(
        recoverableJobs: [R13ResolvedRecoverableUpscaleJob] = [],
        rejectedEntryCount: Int = 0
    ) {
        storedRecoverableJobs = recoverableJobs
        self.rejectedEntryCount = rejectedEntryCount
    }

    var latestHandle: R13UIHoldingJobHandle? {
        lock.withLock { storedHandle }
    }

    var submittedJobs: [UpscaleJob] {
        lock.withLock { storedJobs }
    }

    func availability(for mode: UpscaleMode) -> UpscalerEngineAvailability {
        R13ReleaseModePolicy.availability(for: mode)
    }

    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle {
        if case .unavailable(let reason) = availability(for: job.mode) {
            throw UpscalerEngineError.modeUnavailable(mode: job.mode, reason: reason)
        }
        let handle = R13UIHoldingJobHandle()
        lock.withLock {
            storedHandle = handle
            storedJobs.append(job)
        }
        return handle
    }

    func recoverableJobs() async throws -> R13RecoverableJobCatalog {
        R13RecoverableJobCatalog(
            jobs: storedRecoverableJobs.map(\.summary),
            rejectedEntryCount: rejectedEntryCount
        )
    }

    func resolveRecoverableJob(
        id: String
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        guard let recovered = storedRecoverableJobs.first(
            where: { $0.summary.id == id }
        ) else {
            throw R13RestartJobError.jobMissing(id)
        }
        return recovered
    }

    func reauthorizeRecoverableJob(
        id: String,
        sourceURL _: URL,
        outputDirectoryURL _: URL
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        try await resolveRecoverableJob(id: id)
    }

    func submitRecoveredJob(
        _ recovered: R13ResolvedRecoverableUpscaleJob
    ) throws -> UpscalerJobHandle {
        try submit(recovered.job)
    }

    func start() {}
    func stop() {}
}

private final class R13UIHoldingJobHandle: UpscalerJobHandle,
    @unchecked Sendable {
    private struct State {
        var completed = false
        var waiter: CheckedContinuation<URL, Error>?
    }

    let progressStream: AsyncStream<UpscaleProgress>
    private let lock = NSLock()
    private var state = State()

    init() {
        progressStream = AsyncStream { $0.finish() }
    }

    func cancel() {}

    func waitForCompletion() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completeNow = lock.withLock {
                if state.completed { return true }
                state.waiter = continuation
                return false
            }
            if completeNow {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func completeCancellation() {
        let waiter = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            state.completed = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }
}

private final class R13SuspendedProbeMediaPipeline:
    MediaPipelineService,
    @unchecked Sendable {
    private struct State {
        var probeStarted = false
        var continuation:
            CheckedContinuation<SourceProfile, Error>?
    }

    private let lock = NSLock()
    private var state = State()

    var probeStarted: Bool {
        lock.withLock { state.probeStarted }
    }

    func probe(url _: URL) async throws -> SourceProfile {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                state.probeStarted = true
                state.continuation = continuation
            }
        }
    }

    func completeProbe(_ profile: SourceProfile) {
        let continuation = lock.withLock {
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: profile)
    }

    func beginSession(
        source _: SourceProfile,
        output _: OutputProfile
    ) async throws -> MediaSession {
        fatalError("The recovery probe test never begins a media session.")
    }

    func start() {}
    func stop() {}
}
