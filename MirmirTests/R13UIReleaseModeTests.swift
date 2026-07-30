import Foundation
@testable import Mirmir
import XCTest

// Release-mode UI tests share actor-isolated fakes declared in this file.
// swiftlint:disable file_length type_body_length

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

    func testDiscardAllRemovesSuccessfulJobsAndRetainsFailedDeletion()
        async throws {
        let first = try makeRecoveredJob(
            identifier: "r13-ui-discard-first"
        )
        let second = try makeRecoveredJob(
            identifier: "r13-ui-discard-second"
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [first, second],
            discardFailureIDs: [second.summary.id]
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100 where viewModel.recoverableJobs.count != 2 {
            await Task.yield()
        }

        viewModel.discardAllRecoverableJobs()
        for _ in 0..<100 where viewModel.recoveryMutationIsInProgress {
            await Task.yield()
        }

        XCTAssertEqual(
            engine.discardedJobIDs,
            [first.summary.id]
        )
        XCTAssertEqual(
            viewModel.recoverableJobs.map(\.id),
            [second.summary.id]
        )
        XCTAssertNotNil(viewModel.recoveryError)
    }

    func testDiscardAllClearsUnverifiedRecoveryRecords()
        async throws {
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-discard-unverified"
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered],
            rejectedEntryCount: 2
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100
            where viewModel.recoveryRejectedEntryCount != 2 {
            await Task.yield()
        }

        viewModel.discardAllRecoverableJobs()
        for _ in 0..<100 where viewModel.recoveryMutationIsInProgress {
            await Task.yield()
        }

        XCTAssertEqual(engine.discardAllCount, 1)
        XCTAssertTrue(viewModel.recoverableJobs.isEmpty)
        XCTAssertEqual(viewModel.recoveryRejectedEntryCount, 0)
        XCTAssertNil(viewModel.recoveryError)
    }

    func testDiscardBlocksCacheChangesUntilMutationCompletes()
        async throws {
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-discard-cache-guard"
        )
        let gate = R13UIAsyncGate()
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered],
            discardGate: gate
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.discardRecoverableJob(id: recovered.summary.id)
        await gate.waitUntilStarted()

        XCTAssertTrue(viewModel.recoveryMutationIsInProgress)
        XCTAssertFalse(viewModel.canChangeCacheLocation)

        await gate.release()
        for _ in 0..<100 where viewModel.recoveryMutationIsInProgress {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.recoverableJobs.isEmpty)
    }

    func testDiscardInvalidatesOlderRecoveryCatalogResult()
        async throws {
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-discard-catalog-race"
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
        let catalogGate = R13UIAsyncGate()
        engine.suspendNextCatalog(using: catalogGate)
        viewModel.loadRecoverableJobs()
        await catalogGate.waitUntilStarted()

        viewModel.discardRecoverableJob(id: recovered.summary.id)
        for _ in 0..<100 where viewModel.recoveryMutationIsInProgress {
            await Task.yield()
        }
        await catalogGate.release()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertTrue(viewModel.recoverableJobs.isEmpty)
        XCTAssertEqual(
            engine.discardedJobIDs,
            [recovered.summary.id]
        )
    }

    func testRecoverableCatalogDoesNotBlockNewConfiguredJob()
        async throws {
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-existing-recovery"
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered]
        )
        let viewModel = makeReadyViewModel(engine: engine)
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.recoverableJobs.map(\.id),
            [recovered.summary.id]
        )
        XCTAssertTrue(viewModel.canStart)
    }

    func testReauthorizationAppearsOnlyAfterTypedAccessFailure()
        async throws {
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-auth-required"
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered],
            resolveFailures: [
                recovered.summary.id:
                    .securityScopeDenied(role: .source)
            ]
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        XCTAssertFalse(
            viewModel.recoveryRequiresReauthorization(
                id: recovered.summary.id
            )
        )
        viewModel.resumeRecoverableJob(id: recovered.summary.id)
        for _ in 0..<100 where viewModel.recoveryIsProbing {
            await Task.yield()
        }

        XCTAssertTrue(
            viewModel.recoveryRequiresReauthorization(
                id: recovered.summary.id
            )
        )
        guard case .failed = viewModel.state else {
            return XCTFail("Expected the typed access failure to be shown.")
        }

        viewModel.discardRecoverableJob(id: recovered.summary.id)
        for _ in 0..<100 where viewModel.recoveryMutationIsInProgress {
            await Task.yield()
        }
        XCTAssertFalse(
            viewModel.recoveryRequiresReauthorization(
                id: recovered.summary.id
            )
        )
    }

    func testNonAuthorizationRecoveryFailureDoesNotOfferReauthorization()
        async throws {
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-non-auth-failure"
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered],
            resolveFailures: [
                recovered.summary.id:
                    .ioFailure(operation: "injected_recovery_failure")
            ]
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService()
        )
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.resumeRecoverableJob(id: recovered.summary.id)
        for _ in 0..<100 where viewModel.recoveryIsProbing {
            await Task.yield()
        }

        XCTAssertFalse(
            viewModel.recoveryRequiresReauthorization(
                id: recovered.summary.id
            )
        )
        guard case .failed = viewModel.state else {
            return XCTFail("Expected the injected recovery failure.")
        }
    }

    func testRetryResubmitsExactFailedJobIdentifier() async throws {
        let engine = R13UIModeEngineService()
        let viewModel = makeReadyViewModel(engine: engine)

        viewModel.startUpscale()
        let firstJob = try XCTUnwrap(engine.submittedJobs.first)
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed("injected retry failure")
        )
        for _ in 0..<100 {
            guard case .failed = viewModel.state else {
                await Task.yield()
                continue
            }
            break
        }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected the first attempt to fail.")
        }
        XCTAssertTrue(viewModel.canRetryFailedUpscale)

        viewModel.retryFailedUpscale()
        for _ in 0..<100 where engine.submittedJobs.count != 2 {
            await Task.yield()
        }

        XCTAssertEqual(engine.submittedJobs.count, 2)
        XCTAssertEqual(
            engine.submittedJobs.map(\.identifier),
            [firstJob.identifier, firstJob.identifier]
        )
        XCTAssertEqual(
            engine.submittedJobs.map(\.outputURL),
            [firstJob.outputURL, firstJob.outputURL]
        )
        engine.latestHandle?.completeCancellation()
    }

    func testDefaultOutputURLUsesAuthorizedDirectory() {
        let viewModel = makeReadyViewModel(
            engine: R13UIModeEngineService()
        )
        let source = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/clip.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: false
        )
        let authorizedDirectory = URL(
            fileURLWithPath: "/Volumes/NVME/Output",
            isDirectory: true
        )

        XCTAssertEqual(
            viewModel.defaultOutputURL(
                for: source,
                target: .p2160,
                in: authorizedDirectory
            ),
            authorizedDirectory.appendingPathComponent(
                "clip_mirmir_2160p.mp4"
            )
        )
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

    private func makeRecoveredJob(
        identifier: String
    ) throws -> R13ResolvedRecoverableUpscaleJob {
        let sourceURL = URL(
            fileURLWithPath: "/tmp/\(identifier)-source.mov"
        )
        let outputURL = URL(
            fileURLWithPath: "/tmp/\(identifier).mp4"
        )
        let job = UpscaleJob(
            identifier: identifier,
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p2160,
            preserveAudio: false,
            mode: .deterministic
        )
        return R13ResolvedRecoverableUpscaleJob(
            summary: try R13RecoverableUpscaleJob(job: job),
            job: job,
            securityAccess: try makeAccessSet(
                sourceURL: sourceURL,
                outputDirectoryURL: outputURL.deletingLastPathComponent()
            )
        )
    }
}

private final class R13UIModeEngineService:
    UpscalerEngineService,
    R13RecoverableUpscalerEngine,
    @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available

    private let lock = NSLock()
    private var storedRecoverableJobs:
        [R13ResolvedRecoverableUpscaleJob]
    private var storedRejectedEntryCount: Int
    private let discardFailureIDs: Set<String>
    private let resolveFailures: [String: R13RestartJobError]
    private let discardGate: R13UIAsyncGate?
    private var storedHandle: R13UIHoldingJobHandle?
    private var storedJobs: [UpscaleJob] = []
    private var storedDiscardedJobIDs: [String] = []
    private var storedDiscardAllCount = 0
    private var nextCatalogGate: R13UIAsyncGate?

    init(
        recoverableJobs: [R13ResolvedRecoverableUpscaleJob] = [],
        rejectedEntryCount: Int = 0,
        discardFailureIDs: Set<String> = [],
        resolveFailures: [String: R13RestartJobError] = [:],
        discardGate: R13UIAsyncGate? = nil
    ) {
        storedRecoverableJobs = recoverableJobs
        storedRejectedEntryCount = rejectedEntryCount
        self.discardFailureIDs = discardFailureIDs
        self.resolveFailures = resolveFailures
        self.discardGate = discardGate
    }

    var latestHandle: R13UIHoldingJobHandle? {
        lock.withLock { storedHandle }
    }

    var submittedJobs: [UpscaleJob] {
        lock.withLock { storedJobs }
    }

    var discardedJobIDs: [String] {
        lock.withLock { storedDiscardedJobIDs }
    }

    var discardAllCount: Int {
        lock.withLock { storedDiscardAllCount }
    }

    func suspendNextCatalog(using gate: R13UIAsyncGate) {
        lock.withLock {
            nextCatalogGate = gate
        }
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
        let result = lock.withLock {
            let gate = nextCatalogGate
            nextCatalogGate = nil
            let catalog = R13RecoverableJobCatalog(
                jobs: storedRecoverableJobs.map(\.summary),
                rejectedEntryCount: storedRejectedEntryCount
            )
            return (catalog, gate)
        }
        if let gate = result.1 {
            await gate.wait()
        }
        return result.0
    }

    func discardRecoverableJob(id: String) async throws {
        if let discardGate {
            await discardGate.wait()
        }
        try lock.withLock {
            if discardFailureIDs.contains(id) {
                throw R13RestartJobError.ioFailure(
                    operation: "discard_recoverable_job"
                )
            }
            storedRecoverableJobs.removeAll {
                $0.summary.id == id
            }
            storedDiscardedJobIDs.append(id)
        }
    }

    func discardAllRecoverableJobs() async throws {
        lock.withLock {
            storedRecoverableJobs = []
            storedRejectedEntryCount = 0
            storedDiscardAllCount += 1
        }
    }

    func resolveRecoverableJob(
        id: String
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        if let failure = resolveFailures[id] {
            throw failure
        }
        guard let recovered = lock.withLock({
            storedRecoverableJobs.first(
                where: { $0.summary.id == id }
            )
        }) else {
            throw R13RestartJobError.jobMissing(id)
        }
        return recovered
    }

    func reauthorizeRecoverableJob(
        id: String,
        sourceURL _: URL,
        outputDirectoryURL _: URL
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        guard let recovered = lock.withLock({
            storedRecoverableJobs.first(
                where: { $0.summary.id == id }
            )
        }) else {
            throw R13RestartJobError.jobMissing(id)
        }
        return recovered
    }

    func submitRecoveredJob(
        _ recovered: R13ResolvedRecoverableUpscaleJob
    ) throws -> UpscalerJobHandle {
        try submit(recovered.job)
    }

    func start() {}
    func stop() {}
}

private actor R13UIAsyncGate {
    private var isStarted = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isStarted = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !isStarted {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class R13UIHoldingJobHandle: UpscalerJobHandle,
    @unchecked Sendable {
    private struct State {
        var result: Result<URL, Error>?
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
            let completedResult: Result<URL, Error>? = lock.withLock { () -> Result<URL, Error>? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let completedResult {
                continuation.resume(with: completedResult)
            }
        }
    }

    func completeCancellation() {
        complete(.failure(CancellationError()))
    }

    func completeFailure(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<URL, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(with: result)
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

// swiftlint:enable file_length type_body_length
