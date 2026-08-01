import Foundation
@testable import Mirmir
import XCTest

// Release-mode UI tests share actor-isolated fakes declared in this file.
// swiftlint:disable file_length type_body_length

@MainActor
final class R13UIReleaseModeTests: XCTestCase {
    func testEveryReleaseModeIsSelectableAndReadyToSubmit() {
        let engine = R13UIModeEngineService()
        let viewModel = makeReadyViewModel(engine: engine)

        for mode in UpscaleMode.allCases {
            viewModel.selectedMode = mode
            XCTAssertTrue(viewModel.canStart, mode.rawValue)
            XCTAssertEqual(viewModel.selectedModeAvailability, .available)
        }
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
            "The selected route uses no downloaded model assets."
        )
        XCTAssertTrue(
            viewModel.modelSpecializationText.hasPrefix("No model · ")
        )
        XCTAssertTrue(viewModel.modelSpecializationText.contains("r03"))

        XCTAssertEqual(
            UpscaleMode.auto.summary,
            "Uses ASH content and resource analysis to choose among "
                + "qualified Apple-native engines, with a safe whole-frame "
                + "fallback when a native route is unavailable."
        )
        XCTAssertEqual(
            UpscaleMode.quality.summary,
            "Prefers quality-oriented VideoToolbox processing, then uses "
                + "qualified high-quality Apple-native fallback paths."
        )
        XCTAssertEqual(
            UpscaleMode.fast.summary,
            "Prefers low-latency VideoToolbox, MetalFX, and MPS processing "
                + "while retaining a qualified fallback path."
        )
        XCTAssertEqual(
            UpscaleMode.deterministic.summary,
            "Uses Apple MPS Lanczos with a frozen no-fallback processing "
                + "identity."
        )
        XCTAssertEqual(MirmirWorkspaceDestination.modes.title, "Modes")
        XCTAssertEqual(
            UpscaleMode.auto.releasePickerTitle,
            "Auto"
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

    func testRecoveredJobRetainsScopesThroughTerminalHistoryPersistence()
        async throws {
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirUIRecoveredHistory-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: historyDirectory)
        }
        let sourceURL = URL(
            fileURLWithPath: "/tmp/r13-ui-recovered-history.mov"
        )
        let outputURL = URL(
            fileURLWithPath: "/tmp/r13-ui-recovered-history.mp4"
        )
        let job = UpscaleJob(
            identifier: "r13-ui-recovered-history",
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )
        let scopeAudit = R13UISecurityScopeAudit()
        var recovered: R13ResolvedRecoverableUpscaleJob? =
            R13ResolvedRecoverableUpscaleJob(
                summary: try R13RecoverableUpscaleJob(job: job),
                job: job,
                securityAccess: try makeAccessSet(
                    sourceURL: sourceURL,
                    outputDirectoryURL:
                        outputURL.deletingLastPathComponent(),
                    scopeAudit: scopeAudit
                )
            )
        let engine = R13UIModeEngineService(
            recoverableJobs: [try XCTUnwrap(recovered)]
        )
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: historyDirectory
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: historyStore,
            workHistoryBookmarkResolver:
                R13UIScopeCheckingWorkHistoryBookmarkResolver(
                    scopeAudit: scopeAudit
                ),
            workHistoryOutputIdentityMeasurer:
                R13UIScopeCheckingOutputIdentityMeasurer(
                    scopeAudit: scopeAudit
                )
        )
        for _ in 0..<200 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.resumeRecoverableJob(id: job.identifier)
        for _ in 0..<200 where viewModel.state != .running {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.state, .running)
        let handle = try XCTUnwrap(engine.latestHandle)

        engine.releaseResolvedRecoveryAccessesForTesting()
        recovered = nil
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)

        handle.completeSuccess(outputURL)
        for _ in 0..<500 where viewModel.workHistoryRecords.isEmpty {
            await Task.yield()
        }
        let record = try XCTUnwrap(viewModel.workHistoryRecords.first)
        XCTAssertEqual(record.id, job.identifier)
        XCTAssertEqual(record.terminalResult, .completed)
        XCTAssertEqual(
            record.outputVerification,
            .available(identity: String(repeating: "b", count: 64))
        )
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .finished(outputURL))
        XCTAssertEqual(scopeAudit.startCount, 2)
        XCTAssertEqual(scopeAudit.stopCount, 0)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertFalse(
            scopeAudit.events.contains { $0.hasPrefix("stop.") }
        )

        viewModel.dismissTerminalJob()
        for _ in 0..<200 where scopeAudit.stopCount < 2 {
            await Task.yield()
        }

        XCTAssertEqual(scopeAudit.startCount, 2)
        XCTAssertEqual(scopeAudit.stopCount, 2)
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
        let events = scopeAudit.events
        let firstStopIndex = try XCTUnwrap(
            events.firstIndex { $0.hasPrefix("stop.") }
        )
        for requiredEvent in [
            "bookmark.source",
            "bookmark.output",
            "measure.output"
        ] {
            let eventIndex = try XCTUnwrap(
                events.firstIndex(of: requiredEvent)
            )
            XCTAssertLessThan(eventIndex, firstStopIndex, requiredEvent)
        }
    }

    func testRecoveredFailureRetainsScopesAcrossRetry() async throws {
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirUIRecoveredRetry-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: historyDirectory)
        }
        let sourceURL = URL(
            fileURLWithPath: "/tmp/r13-ui-recovered-retry.mov"
        )
        let outputURL = URL(
            fileURLWithPath: "/tmp/r13-ui-recovered-retry.mp4"
        )
        let job = UpscaleJob(
            identifier: "r13-ui-recovered-retry",
            inputURL: sourceURL,
            outputURL: outputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )
        let scopeAudit = R13UISecurityScopeAudit()
        var recovered: R13ResolvedRecoverableUpscaleJob? =
            R13ResolvedRecoverableUpscaleJob(
                summary: try R13RecoverableUpscaleJob(job: job),
                job: job,
                securityAccess: try makeAccessSet(
                    sourceURL: sourceURL,
                    outputDirectoryURL:
                        outputURL.deletingLastPathComponent(),
                    scopeAudit: scopeAudit
                )
            )
        let engine = R13UIModeEngineService(
            recoverableJobs: [try XCTUnwrap(recovered)]
        )
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: historyDirectory
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: historyStore,
            workHistoryBookmarkResolver:
                R13UIScopeCheckingWorkHistoryBookmarkResolver(
                    scopeAudit: scopeAudit
                )
        )
        for _ in 0..<200 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.resumeRecoverableJob(id: job.identifier)
        for _ in 0..<200 where viewModel.state != .running {
            await Task.yield()
        }
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        engine.releaseResolvedRecoveryAccessesForTesting()
        recovered = nil

        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed(
                "injected recovered retry failure"
            )
        )
        for _ in 0..<500 {
            let failureWasPersisted =
                viewModel.workHistoryRecords.first?.terminalResult == .failed
            if case .failed = viewModel.state, failureWasPersisted {
                break
            }
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected the recovered attempt to fail.")
        }
        XCTAssertEqual(
            viewModel.workHistoryRecords.first?.terminalResult,
            .failed
        )
        XCTAssertEqual(scopeAudit.startCount, 2)
        XCTAssertEqual(scopeAudit.stopCount, 0)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)

        viewModel.retryFailedUpscale()
        for _ in 0..<200 where engine.submittedJobs.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(engine.submittedJobs.count, 2)
        XCTAssertEqual(viewModel.state, .running)
        XCTAssertEqual(scopeAudit.startCount, 2)
        XCTAssertEqual(scopeAudit.stopCount, 0)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)

        let retryHandle = try XCTUnwrap(engine.latestHandle)
        retryHandle.completeCancellation()
        for _ in 0..<500 {
            let cancellationWasPersisted =
                viewModel.workHistoryRecords.first?.terminalResult
                    == .cancelled
            if cancellationWasPersisted, viewModel.state == .ready {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.workHistoryRecords.first?.terminalResult,
            .cancelled
        )
        XCTAssertEqual(scopeAudit.startCount, 2)
        XCTAssertEqual(scopeAudit.stopCount, 0)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)

        viewModel.startUpscale()
        for _ in 0..<200 where engine.submittedJobs.count < 3 {
            await Task.yield()
        }

        XCTAssertEqual(engine.submittedJobs.count, 3)
        XCTAssertEqual(viewModel.state, .running)
        XCTAssertEqual(scopeAudit.startCount, 2)
        XCTAssertEqual(scopeAudit.stopCount, 0)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)

        engine.latestHandle?.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)

        viewModel.upscaleAnotherVideo()
        for _ in 0..<500 where scopeAudit.activeScopeCount != 0 {
            await Task.yield()
        }

        XCTAssertEqual(scopeAudit.startCount, 2)
        XCTAssertEqual(scopeAudit.stopCount, 2)
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
    }

    func testRecoveredCancellationRetainsSourceScopeWhenOutputFolderChanges()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent(
            "recovered-cancel-new-output.mov"
        )
        try Data([0x01]).write(to: sourceURL)
        let originalOutputDirectory = directory.appendingPathComponent(
            "OriginalOutput",
            isDirectory: true
        )
        let newOutputDirectory = directory.appendingPathComponent(
            "NewOutput",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: originalOutputDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: newOutputDirectory,
            withIntermediateDirectories: false
        )
        let originalOutputURL = originalOutputDirectory
            .appendingPathComponent("recovered-original.mp4")
        let job = UpscaleJob(
            identifier: "r13-ui-recovered-cancel-new-output",
            inputURL: sourceURL,
            outputURL: originalOutputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )
        let recoveredScopeAudit = R13UISecurityScopeAudit()
        let selectionScopeAudit = R13UIResourceAccessAudit()
        var recovered: R13ResolvedRecoverableUpscaleJob? =
            R13ResolvedRecoverableUpscaleJob(
                summary: try R13RecoverableUpscaleJob(job: job),
                job: job,
                securityAccess: try makeAccessSet(
                    sourceURL: sourceURL,
                    outputDirectoryURL: originalOutputDirectory,
                    scopeAudit: recoveredScopeAudit
                )
            )
        let engine = R13UIModeEngineService(
            recoverableJobs: [try XCTUnwrap(recovered)]
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            securityScopedResourceAccess: selectionScopeAudit.resourceAccess
        )
        for _ in 0..<200 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.resumeRecoverableJob(id: job.identifier)
        await waitForSubmittedJobs(engine, count: 1)
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        engine.releaseResolvedRecoveryAccessesForTesting()
        recovered = nil

        firstHandle.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }

        XCTAssertEqual(recoveredScopeAudit.startCount, 2)
        XCTAssertEqual(recoveredScopeAudit.stopCount, 0)
        XCTAssertEqual(recoveredScopeAudit.activeScopeCount, 2)

        viewModel.startUpscale()
        await waitForSubmittedJobs(engine, count: 2)

        XCTAssertEqual(recoveredScopeAudit.stopCount, 0)
        XCTAssertEqual(recoveredScopeAudit.activeScopeCount, 2)

        let sameOutputRetryHandle = try XCTUnwrap(engine.latestHandle)
        sameOutputRetryHandle.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }

        selectionScopeAudit.adoptSystemGrant(for: newOutputDirectory)
        XCTAssertEqual(
            selectionScopeAudit.adoptedURLs,
            [newOutputDirectory.standardizedFileURL]
        )
        let newOutputURL = try XCTUnwrap(
            viewModel.acceptOutputDirectorySelectedByUser(
                newOutputDirectory,
                requestedFilename: "recovered-new-output.mp4",
                preferredPathExtension: "mp4"
            )
        )
        XCTAssertEqual(
            selectionScopeAudit.activeURLs,
            [newOutputDirectory.standardizedFileURL]
        )
        for _ in 0..<500 where recoveredScopeAudit.stopCount != 1 {
            await Task.yield()
        }
        XCTAssertEqual(recoveredScopeAudit.stopCount, 1)
        XCTAssertEqual(recoveredScopeAudit.activeScopeCount, 1)
        XCTAssertEqual(
            recoveredScopeAudit.events.suffix(1),
            ["stop.output_directory"]
        )

        viewModel.startUpscale()
        await waitForSubmittedJobs(engine, count: 3)

        let resubmittedJob = try XCTUnwrap(engine.submittedJobs.last)
        XCTAssertEqual(resubmittedJob.inputURL, sourceURL)
        XCTAssertEqual(resubmittedJob.outputURL, newOutputURL)
        XCTAssertEqual(recoveredScopeAudit.stopCount, 1)
        XCTAssertEqual(recoveredScopeAudit.activeScopeCount, 1)
        XCTAssertEqual(
            selectionScopeAudit.activeURLs,
            [newOutputDirectory.standardizedFileURL]
        )
        XCTAssertTrue(selectionScopeAudit.stoppedURLs.isEmpty)

        engine.latestHandle?.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }
        viewModel.upscaleAnotherVideo()
        for _ in 0..<500
            where recoveredScopeAudit.activeScopeCount != 0
                || selectionScopeAudit.activeScopeCount != 0 {
            await Task.yield()
        }

        XCTAssertEqual(recoveredScopeAudit.startCount, 2)
        XCTAssertEqual(recoveredScopeAudit.stopCount, 2)
        XCTAssertEqual(recoveredScopeAudit.activeScopeCount, 0)
        XCTAssertEqual(selectionScopeAudit.activeScopeCount, 0)
        XCTAssertEqual(
            selectionScopeAudit.stoppedURLs.map(\.standardizedFileURL),
            [newOutputDirectory.standardizedFileURL]
        )
    }

    func testRecoveredCancellationReleasesScopesWhenDifferentSourceIsLoaded()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let originalSource = try makePendingQueueSource(
            in: directory,
            name: "recovered-cancel-original.mov",
            hasAudio: false
        )
        let newSource = try makePendingQueueSource(
            in: directory,
            name: "recovered-cancel-replacement.mov",
            hasAudio: false
        )
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let outputURL = outputDirectory.appendingPathComponent(
            "recovered-cancel-original.mp4"
        )
        let job = UpscaleJob(
            identifier: "r13-ui-recovered-cancel-replace-source",
            inputURL: originalSource.url,
            outputURL: outputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )
        let recoveredScopeAudit = R13UISecurityScopeAudit()
        let selectionScopeAudit = R13UIResourceAccessAudit()
        var recovered: R13ResolvedRecoverableUpscaleJob? =
            R13ResolvedRecoverableUpscaleJob(
                summary: try R13RecoverableUpscaleJob(job: job),
                job: job,
                securityAccess: try makeAccessSet(
                    sourceURL: originalSource.url,
                    outputDirectoryURL: outputDirectory,
                    scopeAudit: recoveredScopeAudit
                )
            )
        let engine = R13UIModeEngineService(
            recoverableJobs: [try XCTUnwrap(recovered)]
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: R13UIQueueMediaPipeline(
                profiles: [originalSource, newSource]
            ),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            securityScopedResourceAccess: selectionScopeAudit.resourceAccess
        )
        for _ in 0..<200 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.resumeRecoverableJob(id: job.identifier)
        await waitForSubmittedJobs(engine, count: 1)
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        engine.releaseResolvedRecoveryAccessesForTesting()
        recovered = nil

        firstHandle.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(recoveredScopeAudit.activeScopeCount, 2)
        XCTAssertEqual(recoveredScopeAudit.stopCount, 0)

        selectionScopeAudit.adoptSystemGrant(for: newSource.url)
        viewModel.acceptSourceURLSelectedByUser(newSource.url)

        XCTAssertEqual(recoveredScopeAudit.stopCount, 2)
        XCTAssertEqual(recoveredScopeAudit.activeScopeCount, 0)
        XCTAssertEqual(
            selectionScopeAudit.activeURLs,
            [newSource.url.standardizedFileURL]
        )
        for _ in 0..<500 where viewModel.sourceProfile?.url != newSource.url {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.sourceProfile?.url, newSource.url)

        viewModel.upscaleAnotherVideo()
        XCTAssertEqual(selectionScopeAudit.activeScopeCount, 0)
    }

    func testRecoveryBeginClearsPreviewRetainedFromPreviousFailure()
        async throws {
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-preview-reset"
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered]
        )
        let viewModel = makeReadyViewModel(engine: engine)
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }
        viewModel.startUpscale()
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        let preview = try makePreviewFrame()
        firstHandle.emitPreview(preview)
        for _ in 0..<100 where viewModel.latestPreviewFrame == nil {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.latestPreviewFrame, preview)
        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed("injected preview failure")
        )
        for _ in 0..<100 {
            guard case .failed = viewModel.state else {
                await Task.yield()
                continue
            }
            break
        }
        XCTAssertEqual(
            viewModel.latestPreviewFrame,
            preview,
            "Terminal failure intentionally retains the last valid pair."
        )

        viewModel.resumeRecoverableJob(id: recovered.summary.id)

        XCTAssertNil(
            viewModel.latestPreviewFrame,
            "A new recovery attempt must not display a previous job's pair."
        )
        for _ in 0..<100 where engine.submittedJobs.count < 2 {
            await Task.yield()
        }
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
        XCTAssertNil(
            viewModel.recoverableJobResumeFailureReason(
                id: recovered.summary.id
            )
        )
        viewModel.resumeRecoverableJob(id: recovered.summary.id)
        for _ in 0..<100 where !viewModel
            .recoveryRequiresReauthorization(id: recovered.summary.id) {
            await Task.yield()
        }

        XCTAssertTrue(
            viewModel.recoveryRequiresReauthorization(
                id: recovered.summary.id
            )
        )
        let recoveryReason = try XCTUnwrap(
            viewModel.recoverableJobResumeFailureReason(
                id: recovered.summary.id
            )
        )
        XCTAssertTrue(recoveryReason.contains("Select Reauthorize"))
        XCTAssertTrue(recoveryReason.contains("choose both locations"))
        XCTAssertTrue(
            viewModel.retrySameSettingsFailureReason?
                .contains("Select Reauthorize") == true
        )
        guard case .failed = viewModel.state else {
            return XCTFail("Expected the typed access failure to be shown.")
        }

        viewModel.resumeRecoverableJob(id: recovered.summary.id)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertTrue(engine.submittedJobs.isEmpty)
        XCTAssertFalse(viewModel.recoveryIsProbing)

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

    func testRetryFailureReasonsCoverCacheDestinationEngineGeometryAndCodec()
        async throws {
        let engine = R13UIModeEngineService()
        let viewModel = makeReadyViewModel(engine: engine)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-retry-reasons-\(UUID().uuidString).mp4"
            )
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(outputURL)
        )

        viewModel.startUpscale()
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed(
                "injected retry-reason failure"
            )
        )
        for _ in 0..<100 {
            guard case .failed = viewModel.state else {
                await Task.yield()
                continue
            }
            break
        }
        guard case .failed = viewModel.state else {
            return XCTFail("Expected the configured attempt to fail.")
        }
        let originalRetryable = try XCTUnwrap(
            viewModel.retryableFailedJob
        )

        XCTAssertNil(viewModel.retrySameSettingsFailureReason)
        XCTAssertNil(viewModel.retryWithCurrentSettingsFailureReason)
        XCTAssertTrue(viewModel.canRetryFailedUpscale)
        XCTAssertTrue(
            viewModel.canRetryFailedUpscaleWithCurrentSettings
        )

        viewModel.cacheLocationError =
            "The selected cache folder is offline."
        XCTAssertTrue(
            viewModel.retrySameSettingsFailureReason?
                .contains("Open Settings") == true
        )
        XCTAssertTrue(
            viewModel.retryWithCurrentSettingsFailureReason?
                .contains("Open Settings") == true
        )
        XCTAssertFalse(viewModel.canRetryFailedUpscale)
        XCTAssertFalse(
            viewModel.canRetryFailedUpscaleWithCurrentSettings
        )
        viewModel.cacheLocationError = nil

        viewModel.outputURL = nil
        XCTAssertEqual(
            viewModel.retryWithCurrentSettingsFailureReason,
            "Choose an output destination, then retry."
        )
        XCTAssertTrue(
            viewModel.retryCorrectiveActionText?
                .contains("Choose an output destination") == true
        )
        viewModel.outputURL = outputURL

        viewModel.targetResolution = .p720
        XCTAssertTrue(
            viewModel.retryWithCurrentSettingsFailureReason?
                .contains("larger supported target resolution") == true
        )
        viewModel.targetResolution = .p2160

        engine.setAvailability(
            .unavailable(reason: "Install required engine assets."),
            for: viewModel.selectedMode
        )
        XCTAssertTrue(
            viewModel.retrySameSettingsFailureReason?
                .contains("Choose an available mode or engine") == true
        )
        XCTAssertTrue(
            viewModel.retryWithCurrentSettingsFailureReason?
                .contains("Choose an available mode or engine") == true
        )
        engine.setAvailability(
            .available,
            for: viewModel.selectedMode
        )

        let incompatibleSource = SourceProfile(
            url: originalRetryable.source.url,
            resolution: originalRetryable.source.resolution,
            frameRate: originalRetryable.source.frameRate,
            durationSeconds: originalRetryable.source.durationSeconds,
            estimatedFrameCount:
                originalRetryable.source.estimatedFrameCount,
            codecHint: originalRetryable.source.codecHint,
            hasAudio: originalRetryable.source.hasAudio,
            videoFormat: .sdrBT709YUV422SixteenBit
        )
        viewModel.retryableFailedJob = MirmirViewModel
            .RetryableFailedJob(
                job: originalRetryable.job,
                source: incompatibleSource
            )
        viewModel.codec = .h264

        let sameSettingsContainerReason = try XCTUnwrap(
            viewModel.retrySameSettingsFailureReason
        )
        XCTAssertTrue(
            sameSettingsContainerReason
                .contains("output container cannot preserve")
        )
        XCTAssertTrue(
            sameSettingsContainerReason
                .contains("Select a .mov destination")
        )
        let currentSettingsContainerReason = try XCTUnwrap(
            viewModel.retryWithCurrentSettingsFailureReason
        )
        XCTAssertTrue(
            currentSettingsContainerReason
                .contains("output container cannot preserve")
        )
        XCTAssertTrue(
            currentSettingsContainerReason
                .contains("Select a .mov destination")
        )
        XCTAssertFalse(viewModel.canRetryFailedUpscale)
        XCTAssertFalse(
            viewModel.canRetryFailedUpscaleWithCurrentSettings
        )

        let codecValidationOutputURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("mov")
        let codecValidationJob = UpscaleJob(
            identifier: originalRetryable.job.identifier,
            inputURL: originalRetryable.job.inputURL,
            outputURL: codecValidationOutputURL,
            targetResolution: originalRetryable.job.targetResolution,
            codec: .h264,
            preserveAudio: originalRetryable.job.preserveAudio,
            mode: originalRetryable.job.mode,
            processingConfiguration:
                originalRetryable.job.processingConfiguration
        )
        viewModel.retryableFailedJob = MirmirViewModel
            .RetryableFailedJob(
                job: codecValidationJob,
                source: incompatibleSource
            )
        viewModel.outputURL = codecValidationOutputURL

        XCTAssertTrue(
            viewModel.retrySameSettingsFailureReason?
                .contains("preserving codec") == true
        )
        XCTAssertTrue(
            viewModel.retryWithCurrentSettingsFailureReason?
                .contains("preserving codec") == true
        )
        XCTAssertFalse(viewModel.canRetryFailedUpscale)
        XCTAssertFalse(
            viewModel.canRetryFailedUpscaleWithCurrentSettings
        )
        XCTAssertEqual(engine.submittedJobs.count, 1)
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

    func testRetryWithCurrentSettingsCreatesDistinctConfiguredJob()
        async throws {
        let engine = R13UIModeEngineService()
        let viewModel = makeReadyViewModel(engine: engine)

        viewModel.startUpscale()
        let firstJob = try XCTUnwrap(engine.submittedJobs.first)
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed(
                "injected configurable retry failure"
            )
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

        XCTAssertTrue(viewModel.selectModeForPendingJob(.smoothMotion))
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(.mpsBilinear)
        )
        XCTAssertTrue(viewModel.selectStrategyForPendingJob(.direct))
        XCTAssertTrue(
            viewModel.setTemporalConsistencyForPendingJob(false)
        )
        XCTAssertTrue(viewModel.selectEdgeFidelityForPendingJob(.high))
        XCTAssertTrue(viewModel.selectDetailRecoveryForPendingJob(.low))
        XCTAssertTrue(
            viewModel.setEdgePreservationForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.setCompressionCleanupForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.setTextureGrainProtectionForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.setTemporalStabilityForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.selectSmoothMotionCadenceForPendingJob(.quadruple)
        )
        XCTAssertTrue(
            viewModel.selectSmoothMotionSceneCutSensitivityForPendingJob(
                .high
            )
        )
        XCTAssertTrue(viewModel.canRetryFailedUpscaleWithCurrentSettings)

        viewModel.retryFailedUpscaleWithCurrentSettings()
        for _ in 0..<100 where engine.submittedJobs.count < 2 {
            await Task.yield()
        }

        let retry = try XCTUnwrap(engine.submittedJobs.last)
        XCTAssertNotEqual(retry.identifier, firstJob.identifier)
        XCTAssertEqual(retry.outputURL, firstJob.outputURL)
        XCTAssertEqual(retry.mode, .smoothMotion)
        XCTAssertEqual(
            retry.processingConfiguration,
            UpscaleProcessingConfiguration(
                enginePreference: .mpsBilinear,
                strategyPreference: .direct,
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: .high,
                detailRecoveryLevel: .low,
                effects: UpscaleEffectConfiguration(
                    edgePreservationEnabled: true,
                    compressionCleanupEnabled: true,
                    textureGrainProtectionEnabled: true,
                    temporalStabilityEnabled: true
                ),
                smoothMotion: SmoothMotionConfiguration(
                    cadence: .quadruple,
                    sceneCutSensitivity: .high
                )
            )
        )
        engine.latestHandle?.completeCancellation()
    }

    func testTerminalJobPersistsCompleteWorkHistoryRecord()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirUIHistory-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: directory
        )
        let engine = R13UIModeEngineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: historyStore,
            workHistoryBookmarkResolver:
                R13UIWorkHistoryBookmarkResolver(),
            workHistoryOutputIdentityMeasurer:
                R13UIOutputIdentityMeasurer()
        )
        let source = try SourceProfile(
            url: URL(fileURLWithPath: "/tmp/history-source.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            audioTrackCount: 2
        )
        viewModel.sourceProfile = source
        viewModel.preserveAudio = true
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                URL(fileURLWithPath: "/tmp/history-output.mp4")
            )
        )
        XCTAssertTrue(
            viewModel.setEdgePreservationForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.setCompressionCleanupForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.setTextureGrainProtectionForPendingJob(true)
        )
        XCTAssertTrue(
            viewModel.setTemporalStabilityForPendingJob(true)
        )

        viewModel.startUpscale()
        let submitted = try XCTUnwrap(engine.submittedJobs.first)
        let handle = try XCTUnwrap(engine.latestHandle)
        handle.completeSuccess(submitted.outputURL)
        for _ in 0..<200 where viewModel.workHistoryRecords.isEmpty {
            await Task.yield()
        }

        let record = try XCTUnwrap(viewModel.workHistoryRecords.first)
        XCTAssertEqual(record.id, submitted.identifier)
        XCTAssertEqual(record.sourceDisplayName, "history-source.mov")
        XCTAssertEqual(record.outputDisplayName, "history-output.mp4")
        XCTAssertEqual(record.sourceResolution, .p1080)
        XCTAssertEqual(record.targetResolution, .p2160)
        XCTAssertEqual(record.sourceAudioTrackCount, 2)
        XCTAssertTrue(record.preserveAudio)
        XCTAssertEqual(record.terminalResult, .completed)
        XCTAssertEqual(
            record.outputVerification,
            .available(identity: String(repeating: "a", count: 64))
        )
        XCTAssertEqual(
            record.processingConfiguration.effects,
            UpscaleEffectConfiguration(
                edgePreservationEnabled: true,
                compressionCleanupEnabled: true,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: true
            )
        )
        let persistedRecords = try await historyStore.records()
        XCTAssertEqual(persistedRecords, viewModel.workHistoryRecords)
    }

    func testCancelledHistoryDoesNotRetainReplacedOutputSelection()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = try makePendingQueueSource(
            in: directory,
            name: "cancelled-history-source.mov",
            hasAudio: false
        )
        let originalOutputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let replacementOutputDirectory = directory.appendingPathComponent(
            "ReplacementOutput",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementOutputDirectory,
            withIntermediateDirectories: false
        )
        let resolutionGate = R13UIBlockingResolutionGate()
        defer { resolutionGate.release() }
        let scopeAudit = R13UIResourceAccessAudit()
        let engine = R13UIModeEngineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: MirmirWorkHistoryStore(
                directoryURL: directory.appendingPathComponent(
                    "History",
                    isDirectory: true
                )
            ),
            workHistoryBookmarkResolver:
                R13UIBlockingWorkHistoryBookmarkResolver(
                    gate: resolutionGate
                ),
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready

        scopeAudit.adoptSystemGrant(for: originalOutputDirectory)
        _ = try XCTUnwrap(
            viewModel.acceptOutputDirectorySelectedByUser(
                originalOutputDirectory,
                requestedFilename: "cancelled-original.mp4",
                preferredPathExtension: "mp4"
            )
        )
        viewModel.startUpscale()
        let handle = try XCTUnwrap(engine.latestHandle)
        handle.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }
        for _ in 0..<1_000 where !resolutionGate.isWaiting {
            await Task.yield()
        }
        XCTAssertTrue(resolutionGate.isWaiting)

        scopeAudit.adoptSystemGrant(for: replacementOutputDirectory)
        _ = try XCTUnwrap(
            viewModel.acceptOutputDirectorySelectedByUser(
                replacementOutputDirectory,
                requestedFilename: "cancelled-replacement.mp4",
                preferredPathExtension: "mp4"
            )
        )

        XCTAssertEqual(
            scopeAudit.stoppedURLs.map(\.standardizedFileURL),
            [originalOutputDirectory.standardizedFileURL]
        )
        XCTAssertEqual(
            scopeAudit.activeURLs,
            [replacementOutputDirectory.standardizedFileURL]
        )

        resolutionGate.release()
        for _ in 0..<1_000 where viewModel.workHistoryRecords.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(
            viewModel.workHistoryRecords.first?.terminalResult,
            .cancelled
        )
        viewModel.upscaleAnotherVideo()
    }

    func testReprocessHistoryRestoresExactConfigurationToNewOutput()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirUIReprocess-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data([0x01]).write(to: sourceURL)
        let outputDirectory = directory.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let scopeMaterializer = R13UIScopeStartMaterializer(
            sourceURL: sourceURL,
            outputDirectoryURL: outputDirectory
        )
        let resolver = R13UIWorkHistoryBookmarkResolver()
        let configuration = UpscaleProcessingConfiguration(
            enginePreference: .mpsLanczos,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low,
            effects: UpscaleEffectConfiguration(
                edgePreservationEnabled: true,
                compressionCleanupEnabled: true,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: true
            )
        )
        let record = MirmirWorkHistoryRecord(
            id: "history-reprocess",
            sourceBookmark: try resolver.makeBookmark(
                for: sourceURL,
                role: .source
            ),
            outputBookmark: try resolver.makeBookmark(
                for: outputDirectory,
                role: .output
            ),
            outputBookmarkScope: .directory,
            sourceDisplayName: sourceURL.lastPathComponent,
            outputDisplayName: "original-output.mp4",
            sourceResolution: .p1080,
            targetResolution: .p2160,
            codec: .h264,
            preserveAudio: false,
            requestedMode: .deterministic,
            processingConfiguration: configuration,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            startedAt: Date(timeIntervalSinceReferenceDate: 11),
            completedAt: Date(timeIntervalSinceReferenceDate: 12),
            terminalResult: .failed,
            outputVerification: .unavailable
        )
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: directory.appendingPathComponent(
                "History",
                isDirectory: true
            )
        )
        _ = try await historyStore.upsert(record)
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: R13UIModeEngineService(),
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: historyStore,
            workHistoryBookmarkResolver: resolver,
            workHistoryOutputIdentityMeasurer:
                R13UIOutputIdentityMeasurer(),
            securityScopedResourceAccess:
                scopeMaterializer.resourceAccess
        )
        for _ in 0..<200
        where viewModel.workHistoryLocationStates[record.id] == nil {
            await Task.yield()
        }
        XCTAssertEqual(
            viewModel.workHistoryLocationStates[record.id],
            MirmirWorkHistoryBookmarkStates(
                source: .available,
                output: .available
            )
        )

        try FileManager.default.removeItem(at: sourceURL)
        scopeMaterializer.enableMaterialization()

        viewModel.reprocessWorkHistoryRecord(id: record.id)
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.sourceProfile?.url, sourceURL)
        XCTAssertEqual(viewModel.targetResolution, .p2160)
        XCTAssertEqual(viewModel.codec, .h264)
        XCTAssertEqual(viewModel.selectedMode, .deterministic)
        XCTAssertEqual(
            viewModel.currentEffects,
            configuration.effects
        )
        XCTAssertEqual(
            viewModel.outputURL?.deletingLastPathComponent(),
            outputDirectory
        )
        XCTAssertNotEqual(
            viewModel.outputURL?.lastPathComponent,
            record.outputDisplayName
        )
        XCTAssertTrue(
            viewModel.outputURL?.lastPathComponent
                .contains("_reprocessed_") == true
        )
        XCTAssertNotNil(viewModel.historyReprocessNavigationRequest)
        XCTAssertNil(viewModel.workHistoryReprocessInProgressID)
        XCTAssertEqual(
            scopeMaterializer.materializedURLs
                .map(\.standardizedFileURL),
            [sourceURL.standardizedFileURL]
        )
    }

    func testFailedHistoryReprocessReleasesRestoredScopes()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirUIReprocessFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data([0x01]).write(to: sourceURL)
        let outputDirectory = directory.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let resolver = R13UIWorkHistoryBookmarkResolver()
        let record = MirmirWorkHistoryRecord(
            id: "history-reprocess-failure",
            sourceBookmark: try resolver.makeBookmark(
                for: sourceURL,
                role: .source
            ),
            outputBookmark: try resolver.makeBookmark(
                for: outputDirectory,
                role: .output
            ),
            outputBookmarkScope: .directory,
            sourceDisplayName: sourceURL.lastPathComponent,
            outputDisplayName: "failed-output.mp4",
            sourceResolution: .p1080,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            requestedMode: .deterministic,
            processingConfiguration: .default,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            startedAt: Date(timeIntervalSinceReferenceDate: 11),
            completedAt: Date(timeIntervalSinceReferenceDate: 12),
            terminalResult: .failed,
            outputVerification: .unavailable
        )
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: directory.appendingPathComponent(
                "History",
                isDirectory: true
            )
        )
        _ = try await historyStore.upsert(record)
        let scopeMaterializer = R13UIScopeStartMaterializer(
            sourceURL: sourceURL,
            outputDirectoryURL: outputDirectory
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: R13UIQueueMediaPipeline(
                profiles: [],
                failingProbePaths: [sourceURL.path]
            ),
            upscalerEngine: R13UIModeEngineService(),
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: historyStore,
            workHistoryBookmarkResolver: resolver,
            securityScopedResourceAccess:
                scopeMaterializer.resourceAccess
        )
        for _ in 0..<200
        where viewModel.workHistoryLocationStates[record.id] == nil {
            await Task.yield()
        }

        XCTAssertEqual(scopeMaterializer.activeScopeCount, 0)
        viewModel.reprocessWorkHistoryRecord(id: record.id)
        for _ in 0..<500 {
            if case .failed = viewModel.state,
               scopeMaterializer.activeScopeCount == 0 {
                break
            }
            await Task.yield()
        }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected the restored source probe to fail.")
        }
        XCTAssertEqual(scopeMaterializer.activeScopeCount, 0)
        XCTAssertNil(viewModel.workHistoryReprocessInProgressID)
    }

    func testCompletedHistoryOutputStateBlocksRevealUntilFileReturns()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirUIHistoryOutput-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data([0x01]).write(to: sourceURL)
        let outputDirectory = directory.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let outputURL = outputDirectory.appendingPathComponent(
            "completed.mp4"
        )
        let resolver = R13UIWorkHistoryBookmarkResolver()
        let record = MirmirWorkHistoryRecord(
            id: "history-output-state",
            sourceBookmark: try resolver.makeBookmark(
                for: sourceURL,
                role: .source
            ),
            outputBookmark: try resolver.makeBookmark(
                for: outputDirectory,
                role: .output
            ),
            outputBookmarkScope: .directory,
            sourceDisplayName: sourceURL.lastPathComponent,
            outputDisplayName: outputURL.lastPathComponent,
            sourceResolution: .p1080,
            targetResolution: .p2160,
            codec: .h264,
            preserveAudio: false,
            requestedMode: .deterministic,
            processingConfiguration: .default,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            startedAt: Date(timeIntervalSinceReferenceDate: 11),
            completedAt: Date(timeIntervalSinceReferenceDate: 12),
            terminalResult: .completed,
            outputVerification: .available(
                identity: String(repeating: "a", count: 64)
            )
        )
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: directory.appendingPathComponent(
                "History",
                isDirectory: true
            )
        )
        _ = try await historyStore.upsert(record)
        var revealedURL: URL?
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: R13UIModeEngineService(),
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: historyStore,
            workHistoryBookmarkResolver: resolver,
            workHistoryOutputIdentityMeasurer:
                R13UIOutputIdentityMeasurer(),
            securityScopedResourceAccess:
                r13UIAlwaysGrantedResourceAccess,
            revealFileInFinder: { revealedURL = $0 }
        )
        for _ in 0..<200
        where viewModel.workHistoryLocationStates[record.id] == nil {
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.workHistoryLocationStates[record.id],
            MirmirWorkHistoryBookmarkStates(
                source: .available,
                output: .missing
            )
        )
        XCTAssertEqual(
            viewModel.workHistoryLocationStatusText(id: record.id),
            "Source available · Output missing"
        )
        let missingReason = try XCTUnwrap(
            viewModel.workHistoryRevealFailureReason(id: record.id)
        )
        XCTAssertTrue(missingReason.contains("completed.mp4"))
        XCTAssertTrue(missingReason.contains("Select Reauthorize"))
        XCTAssertNil(
            viewModel.workHistoryReprocessFailureReason(id: record.id)
        )

        viewModel.revealWorkHistoryOutput(id: record.id)
        XCTAssertNil(revealedURL)
        XCTAssertEqual(viewModel.workHistoryError, missingReason)

        try Data([0x02]).write(to: outputURL)
        viewModel.refreshWorkHistory()
        for _ in 0..<200 {
            if !viewModel.workHistoryIsLoading,
               viewModel.workHistoryLocationStates[record.id]?.output
                == .available {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(
            viewModel.workHistoryLocationStatusText(id: record.id),
            "Source available · Output available"
        )
        XCTAssertNil(
            viewModel.workHistoryRevealFailureReason(id: record.id)
        )
        viewModel.revealWorkHistoryOutput(id: record.id)
        for _ in 0..<200 where revealedURL == nil {
            await Task.yield()
        }
        XCTAssertEqual(revealedURL, outputURL)
        XCTAssertNil(viewModel.workHistoryError)
    }

    func testHistoryPermissionFailureExposesReauthorizationReason()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirUIHistoryPermission-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let sourceURL = directory.appendingPathComponent("source.mov")
        try Data([0x01]).write(to: sourceURL)
        let outputDirectory = directory.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let resolver = R13UIWorkHistoryBookmarkResolver(
            sourceBookmarkIsStale: true
        )
        let record = MirmirWorkHistoryRecord(
            id: "history-permission",
            sourceBookmark: try resolver.makeBookmark(
                for: sourceURL,
                role: .source
            ),
            outputBookmark: try resolver.makeBookmark(
                for: outputDirectory,
                role: .output
            ),
            outputBookmarkScope: .directory,
            sourceDisplayName: sourceURL.lastPathComponent,
            outputDisplayName: "original-output.mp4",
            sourceResolution: .p1080,
            targetResolution: .p2160,
            codec: .h264,
            preserveAudio: false,
            requestedMode: .deterministic,
            processingConfiguration: .default,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            startedAt: Date(timeIntervalSinceReferenceDate: 11),
            completedAt: Date(timeIntervalSinceReferenceDate: 12),
            terminalResult: .failed,
            outputVerification: .unavailable
        )
        let historyStore = MirmirWorkHistoryStore(
            directoryURL: directory.appendingPathComponent(
                "History",
                isDirectory: true
            )
        )
        _ = try await historyStore.upsert(record)
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: R13UIModeEngineService(),
            modelAssets: NotRequiredModelAssetsService(),
            workHistoryStore: historyStore,
            workHistoryBookmarkResolver: resolver,
            workHistoryOutputIdentityMeasurer:
                R13UIOutputIdentityMeasurer(),
            securityScopedResourceAccess:
                r13UIAlwaysGrantedResourceAccess
        )
        for _ in 0..<200
        where viewModel.workHistoryLocationStates[record.id] == nil {
            await Task.yield()
        }
        XCTAssertEqual(
            viewModel.workHistoryLocationStatusText(id: record.id),
            "Source permission required · Output available"
        )
        let reason = try XCTUnwrap(
            viewModel.workHistoryReprocessFailureReason(id: record.id)
        )
        XCTAssertTrue(reason.contains("Select Reauthorize"))
        XCTAssertTrue(reason.contains("source and output folder"))
        XCTAssertTrue(
            viewModel.workHistoryReauthorizationRequiredIDs
                .contains(record.id)
        )

        viewModel.reprocessWorkHistoryRecord(id: record.id)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertNil(viewModel.historyReprocessNavigationRequest)
        XCTAssertNil(viewModel.workHistoryReprocessInProgressID)

        viewModel.reprocessWorkHistoryRecord(id: record.id)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertNil(viewModel.historyReprocessNavigationRequest)
        XCTAssertEqual(
            viewModel.workHistoryReprocessFailureReason(id: record.id),
            reason
        )
    }

    func testRecoveryAndRetryKeepExactJobConfigurationIsolatedFromDefaults()
        async throws {
        let suiteName =
            "com.mirmir.tests.recovery-defaults.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let keys = MirmirPreferencesKeys.namespaced(
            "com.mirmir.tests.recovery-defaults"
        )
        let store = MirmirPreferencesStore(
            defaults: defaults,
            keys: keys
        )
        let initialDefaults = MirmirPreferencesSnapshot(
            appearanceMode: .arcticIndigo,
            defaultUpscaleMode: .quality,
            defaultOutputCodec: .hevc,
            enginePreference: .accelerateVImageHighQuality,
            strategyPreference: .direct,
            temporalConsistencyEnabled: true,
            edgeFidelityLevel: .low,
            detailRecoveryLevel: .medium
        )
        store.save(initialDefaults)
        let recoveredConfiguration = UpscaleProcessingConfiguration(
            enginePreference: .mpsBilinear,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low
        )
        let recovered = try makeRecoveredJob(
            identifier: "r13-ui-config-isolation",
            codec: .h264,
            mode: .fast,
            processingConfiguration: recoveredConfiguration
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered]
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            preferencesStore: store
        )
        for _ in 0..<100 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }

        viewModel.resumeRecoverableJob(id: recovered.summary.id)
        for _ in 0..<100 where engine.submittedJobs.isEmpty {
            await Task.yield()
        }

        let recoverySubmission = try XCTUnwrap(
            engine.submittedJobs.first
        )
        XCTAssertEqual(recoverySubmission.mode, .fast)
        XCTAssertEqual(recoverySubmission.codec, .h264)
        XCTAssertEqual(
            recoverySubmission.processingConfiguration,
            recoveredConfiguration
        )
        XCTAssertEqual(viewModel.selectedMode, .fast)
        XCTAssertEqual(viewModel.codec, .h264)
        XCTAssertEqual(viewModel.enginePreference, .mpsBilinear)
        XCTAssertEqual(viewModel.strategyPreference, .adaptive)
        XCTAssertFalse(viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(viewModel.edgeFidelityLevel, .high)
        XCTAssertEqual(viewModel.detailRecoveryLevel, .low)
        XCTAssertEqual(store.load(), initialDefaults)

        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed(
                "injected recovered job failure"
            )
        )
        for _ in 0..<100 {
            guard case .failed = viewModel.state else {
                await Task.yield()
                continue
            }
            break
        }
        guard case .failed = viewModel.state else {
            return XCTFail("Expected recovered job failure.")
        }

        viewModel.selectDefaultMode(.deterministic)
        viewModel.selectDefaultOutputCodec(.hevc)
        viewModel.selectDefaultEngine(.mpsLanczos)
        viewModel.selectDefaultStrategy(.automatic)
        viewModel.setDefaultTemporalConsistency(true)
        viewModel.selectDefaultEdgeFidelity(.medium)
        viewModel.selectDefaultDetailRecovery(.high)
        let updatedDefaults = MirmirPreferencesSnapshot(
            appearanceMode: .arcticIndigo,
            defaultUpscaleMode: .deterministic,
            defaultOutputCodec: .hevc,
            enginePreference: .mpsLanczos,
            strategyPreference: .automatic,
            temporalConsistencyEnabled: true,
            edgeFidelityLevel: .medium,
            detailRecoveryLevel: .high
        )

        viewModel.retryFailedUpscale()
        for _ in 0..<100 where engine.submittedJobs.count < 2 {
            await Task.yield()
        }

        let retrySubmission = try XCTUnwrap(
            engine.submittedJobs.last
        )
        XCTAssertEqual(
            retrySubmission.identifier,
            recoverySubmission.identifier
        )
        XCTAssertEqual(retrySubmission.mode, .fast)
        XCTAssertEqual(retrySubmission.codec, .h264)
        XCTAssertEqual(
            retrySubmission.processingConfiguration,
            recoveredConfiguration
        )
        XCTAssertEqual(viewModel.selectedMode, .fast)
        XCTAssertEqual(viewModel.codec, .h264)
        XCTAssertEqual(viewModel.enginePreference, .mpsBilinear)
        XCTAssertEqual(viewModel.strategyPreference, .adaptive)
        XCTAssertFalse(viewModel.temporalConsistencyEnabled)
        XCTAssertEqual(viewModel.edgeFidelityLevel, .high)
        XCTAssertEqual(viewModel.detailRecoveryLevel, .low)
        XCTAssertEqual(store.load(), updatedDefaults)
        engine.latestHandle?.completeCancellation()
    }

    func testPendingQueueBatchEnqueuePersistsExactDefaultsEffectsOrderAndBookmarks()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let first = try makePendingQueueSource(
            in: directory,
            name: "first.mov",
            hasAudio: true
        )
        let second = try makePendingQueueSource(
            in: directory,
            name: "second.mp4",
            hasAudio: false
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(
                profiles: [first, second]
            )
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        viewModel.selectDefaultMode(.fast)
        viewModel.selectDefaultOutputCodec(.h264)
        viewModel.selectDefaultEngine(.mpsLanczos)
        viewModel.selectDefaultStrategy(.adaptive)
        viewModel.setDefaultTemporalConsistency(false)
        viewModel.selectDefaultEdgeFidelity(.high)
        viewModel.selectDefaultDetailRecovery(.low)
        viewModel.setDefaultEdgePreservation(true)
        viewModel.setDefaultCompressionCleanup(true)
        viewModel.setDefaultTextureGrainProtection(true)
        viewModel.setDefaultTemporalStability(true)

        viewModel.enqueueSourceURLs(
            [first.url, second.url],
            outputDirectoryURL: outputDirectory
        )
        await waitForPendingQueue(
            viewModel,
            count: 2,
            requireIdle: true
        )

        let snapshot = try await queue.load()
        assertPendingQueueBatchSnapshot(
            snapshot,
            first: first,
            second: second,
            outputDirectory: outputDirectory
        )
    }

    func testPendingQueueRetainsSystemSelectionGrantsThroughBatchEnqueue()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "scoped-source.mov",
            hasAudio: false
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        let media = R13SuspendedProbeMediaPipeline()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: media
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        let scopeAudit = R13UISystemSelectionGrantAudit()
        let selectedURLs = [source.url, outputDirectory]

        viewModel.enqueueSourceURLs(
            [source.url],
            outputDirectoryURL: outputDirectory,
            retainingSystemSelectionAccesses:
                scopeAudit.adoptedLeases(for: selectedURLs)
        )

        XCTAssertTrue(scopeAudit.startedURLs.isEmpty)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)
        for _ in 0..<200 where !media.probeStarted {
            await Task.yield()
        }
        XCTAssertTrue(media.probeStarted)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)
        media.completeProbe(source)
        await waitForPendingQueue(
            viewModel,
            count: 1,
            requireIdle: true
        )
        XCTAssertTrue(scopeAudit.startedURLs.isEmpty)
        XCTAssertEqual(scopeAudit.stoppedURLs.count, selectedURLs.count)
        XCTAssertEqual(
            Set(scopeAudit.stoppedURLs.map(\.standardizedFileURL)),
            Set(selectedURLs.map(\.standardizedFileURL))
        )
    }

    func testPendingQueueReleasesSystemSelectionGrantsAfterProbeFailure()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "scoped-failure.mov",
            hasAudio: false
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        let media = R13SuspendedProbeMediaPipeline()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: media
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        let scopeAudit = R13UISystemSelectionGrantAudit()
        let selectedURLs = [source.url, outputDirectory]

        viewModel.enqueueSourceURLs(
            [source.url],
            outputDirectoryURL: outputDirectory,
            retainingSystemSelectionAccesses:
                scopeAudit.adoptedLeases(for: selectedURLs)
        )
        for _ in 0..<200 where !media.probeStarted {
            await Task.yield()
        }
        XCTAssertTrue(media.probeStarted)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)
        media.failProbe(
            MediaPipelineError.readerStartFailed
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true,
            requireError: true
        )

        XCTAssertTrue(scopeAudit.startedURLs.isEmpty)
        XCTAssertEqual(scopeAudit.stoppedURLs.count, selectedURLs.count)
        XCTAssertEqual(
            Set(scopeAudit.stoppedURLs.map(\.standardizedFileURL)),
            Set(selectedURLs.map(\.standardizedFileURL))
        )
    }

    private func assertPendingQueueBatchSnapshot(
        _ snapshot: MirmirPendingQueueSnapshot,
        first: SourceProfile,
        second: SourceProfile,
        outputDirectory: URL
    ) {
        XCTAssertEqual(
            snapshot.records.map(\.bookmarks.sourceDisplayName),
            ["first.mov", "second.mp4"]
        )
        XCTAssertEqual(snapshot.records.map(\.order), [0, 1])
        XCTAssertEqual(
            Set(snapshot.records.map(\.id)).count,
            2,
            "Each queued source must receive a distinct stable identifier."
        )
        XCTAssertTrue(snapshot.records.allSatisfy { !$0.id.isEmpty })
        let expectedConfiguration = UpscaleProcessingConfiguration(
            enginePreference: .mpsLanczos,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low,
            effects: UpscaleEffectConfiguration(
                edgePreservationEnabled: true,
                compressionCleanupEnabled: true,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: true
            )
        )
        XCTAssertEqual(
            snapshot.records.map(\.settings.processingConfiguration),
            [expectedConfiguration, expectedConfiguration]
        )
        XCTAssertEqual(
            snapshot.records.map(\.settings.requestedMode),
            [.fast, .fast]
        )
        XCTAssertEqual(
            snapshot.records.map(\.settings.codec),
            [.h264, .h264]
        )
        XCTAssertEqual(
            snapshot.records.map(\.settings.targetResolution),
            [.p1440, .p1440]
        )
        XCTAssertEqual(
            snapshot.records.map(\.settings.preserveAudio),
            [true, false]
        )
        XCTAssertEqual(
            snapshot.records.map(\.bookmarks.sourceBookmark),
            [
                Data(first.url.path.utf8),
                Data(second.url.path.utf8)
            ]
        )
        XCTAssertEqual(
            snapshot.records.map(\.bookmarks.outputBookmark),
            [
                Data(outputDirectory.path.utf8),
                Data(outputDirectory.path.utf8)
            ]
        )
        for record in snapshot.records {
            XCTAssertTrue(
                record.bookmarks.outputDisplayName.hasSuffix(".mp4")
            )
            XCTAssertTrue(
                record.bookmarks.outputDisplayName.contains("_queue_")
            )
            XCTAssertFalse(
                record.bookmarks.outputDisplayName.contains("/")
            )
        }
    }

    func testPendingQueueSelectsPreservingCodecAndContainer()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "prores-source.mov",
            hasAudio: false,
            videoFormat: .sdrBT709YUV422SixteenBit
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source])
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        viewModel.selectDefaultOutputCodec(.h264)

        viewModel.enqueueSourceURLs(
            [source.url],
            outputDirectoryURL: outputDirectory
        )
        await waitForPendingQueue(
            viewModel,
            count: 1,
            requireIdle: true
        )

        let snapshot = try await queue.load()
        let record = try XCTUnwrap(snapshot.records.first)
        XCTAssertEqual(record.settings.codec, .proRes422HQ)
        XCTAssertTrue(
            record.bookmarks.outputDisplayName.hasSuffix(".mov")
        )
    }

    func testPendingQueueBatchEnqueueIsAtomicWhenLaterProbeFails()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let first = try makePendingQueueSource(
            in: directory,
            name: "valid-first.mov",
            hasAudio: true
        )
        let rejected = try makePendingQueueSource(
            in: directory,
            name: "rejected-second.mov",
            hasAudio: true
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        let media = R13UIQueueMediaPipeline(
            profiles: [first, rejected],
            failingProbePaths: [rejected.url.path]
        )
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: media
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )

        viewModel.enqueueSourceURLs(
            [first.url, rejected.url],
            outputDirectoryURL: outputDirectory
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true,
            requireError: true
        )

        let persisted = try await queue.load()
        XCTAssertTrue(persisted.records.isEmpty)
        XCTAssertEqual(
            media.probedURLs,
            [first.url, rejected.url],
            "The failure is injected only after the first source was "
                + "successfully prepared."
        )
    }

    func testPendingQueueStartSubmitsStableIdentifierAndExactConfiguration()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "exact-config.mov",
            hasAudio: true
        )
        let resolver = R13UIQueueBookmarkResolver()
        let configuration = UpscaleProcessingConfiguration(
            enginePreference: .mpsLanczos,
            strategyPreference: .adaptive,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low,
            effects: UpscaleEffectConfiguration(
                edgePreservationEnabled: true,
                compressionCleanupEnabled: false,
                textureGrainProtectionEnabled: true,
                temporalStabilityEnabled: true
            ),
            smoothMotion: SmoothMotionConfiguration(
                cadence: .quadruple,
                sceneCutSensitivity: .high
            )
        )
        let record = try makePendingQueueWorkflowRecord(
            id: "queue-stable-id",
            order: 0,
            source: source,
            outputDirectory: outputDirectory,
            outputDisplayName: "stable-output.mp4",
            settings: makePendingQueueSettings(
                targetResolution: .p2160,
                codec: .h264,
                preserveAudio: true,
                requestedMode: .smoothMotion,
                processingConfiguration: configuration
            ),
            resolver: resolver
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueue(record)
        let engine = R13UIModeEngineService()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine,
            resolver: resolver
        )
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true
        )

        viewModel.startNextPendingWork()
        await waitForSubmittedJobs(engine, count: 1)

        let submitted = try XCTUnwrap(engine.submittedJobs.first)
        XCTAssertEqual(submitted.identifier, record.id)
        XCTAssertEqual(submitted.inputURL, source.url)
        XCTAssertEqual(
            submitted.outputURL,
            outputDirectory.appendingPathComponent("stable-output.mp4")
        )
        XCTAssertEqual(submitted.targetResolution, .p2160)
        XCTAssertEqual(submitted.codec, .h264)
        XCTAssertTrue(submitted.preserveAudio)
        XCTAssertEqual(submitted.mode, .smoothMotion)
        XCTAssertEqual(submitted.processingConfiguration, configuration)
        XCTAssertEqual(viewModel.sourceProfile?.url, source.url)
        XCTAssertEqual(viewModel.targetResolution, .p2160)
        XCTAssertEqual(viewModel.codec, .h264)
        XCTAssertTrue(viewModel.preserveAudio)
        XCTAssertEqual(viewModel.selectedMode, .smoothMotion)
        XCTAssertEqual(viewModel.currentEffects, configuration.effects)
        XCTAssertEqual(viewModel.smoothMotionCadence, .quadruple)
        XCTAssertEqual(
            viewModel.smoothMotionSceneCutSensitivity,
            .high
        )

        let claimed = try await queue.load()
        XCTAssertEqual(claimed.records.first?.id, record.id)
        XCTAssertEqual(claimed.records.first?.state, .started)
        XCTAssertNotNil(claimed.records.first?.startedAt)

        engine.latestHandle?.completeCancellation()
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
    }

    func testPendingQueuePostSubmitRefreshFailureKeepsActiveOwnership()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "post-submit-refresh-failure.mov",
            hasAudio: false
        )
        let resolver = R13UIQueueBookmarkResolver()
        let record = try makePendingQueueWorkflowRecord(
            id: "post-submit-refresh-failure-job",
            order: 0,
            source: source,
            outputDirectory: outputDirectory,
            outputDisplayName: "post-submit-refresh-failure-output.mp4",
            settings: makePendingQueueSettings(
                targetResolution: .p2160,
                preserveAudio: false
            ),
            resolver: resolver
        )
        let fileSystem = R13UIOneShotReadFailureFileSystem()
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            ),
            fileSystem: fileSystem
        )
        _ = try await queue.enqueue(record)
        let engine = R13UIModeEngineService()
        let scopeAudit = R13UIResourceAccessAudit()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine,
            resolver: resolver,
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true
        )

        fileSystem.failRead(afterSuccessfulReads: 1)
        viewModel.startNextPendingWork()
        await waitForSubmittedJobs(engine, count: 1)
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true,
            requireError: true
        )

        XCTAssertEqual(viewModel.state, .running)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)
        let started = try await queue.load()
        XCTAssertEqual(started.records.first?.id, record.id)
        XCTAssertEqual(started.records.first?.state, .started)

        let handle = try XCTUnwrap(engine.latestHandle)
        let submitted = try XCTUnwrap(engine.submittedJobs.first)
        handle.completeSuccess(submitted.outputURL)
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )

        let completed = try await queue.load()
        XCTAssertTrue(completed.records.isEmpty)
        XCTAssertEqual(viewModel.state, .finished(submitted.outputURL))
        XCTAssertNil(viewModel.pendingQueueError)
        XCTAssertEqual(
            scopeAudit.activeScopeCount,
            2,
            "The finished job retains access for reveal and history work."
        )

        viewModel.dismissTerminalJob()
        for _ in 0..<500 where scopeAudit.activeScopeCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
        XCTAssertEqual(
            scopeAudit.stoppedURLs.map(\.standardizedFileURL),
            [outputDirectory, source.url].map(\.standardizedFileURL)
        )
    }

    func testPendingQueueSuccessRemovesCompletedHeadAndAutoStartsNext()
        async throws {
        let fixture = try await makeTwoItemPendingQueueFixture(
            prefix: "success-auto-advance"
        )
        fixture.viewModel.startNextPendingWork()
        await waitForSubmittedJobs(fixture.engine, count: 1)
        let firstJob = try XCTUnwrap(fixture.engine.submittedJobs.first)
        XCTAssertEqual(firstJob.identifier, fixture.records[0].id)

        let firstHandle = try XCTUnwrap(fixture.engine.latestHandle)
        firstHandle.completeSuccess(firstJob.outputURL)
        await waitForSubmittedJobs(fixture.engine, count: 2)
        await waitForPendingQueue(
            fixture.viewModel,
            ids: [fixture.records[1].id],
            requireIdle: true
        )

        XCTAssertEqual(
            fixture.engine.submittedJobs.map(\.identifier),
            fixture.records.map(\.id)
        )
        let persisted = try await fixture.queue.load()
        XCTAssertEqual(persisted.records.map(\.id), [fixture.records[1].id])
        XCTAssertEqual(persisted.records.first?.state, .started)

        fixture.engine.latestHandle?.completeCancellation()
        await waitForPendingQueue(
            fixture.viewModel,
            ids: [],
            requireIdle: true
        )
    }

    func testGeneralRecoveryRestoresStartedQueueOwnershipAndAdvances()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let resolver = R13UIQueueBookmarkResolver()
        let sources = try [0, 1].map { index in
            try makePendingQueueSource(
                in: directory,
                name: "recovered-queue-\(index).mov",
                hasAudio: false
            )
        }
        let settings = makePendingQueueSettings(
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false,
            requestedMode: .deterministic,
            processingConfiguration: .default
        )
        let records = try sources.enumerated().map { index, source in
            try makePendingQueueWorkflowRecord(
                id: "recovered-queue-job-\(index)",
                order: index,
                source: source,
                outputDirectory: outputDirectory,
                outputDisplayName: "recovered-output-\(index).mp4",
                settings: settings,
                resolver: resolver
            )
        }
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueueMany(records)
        let claim = try await queue.markStartedOrReturnHead()
        XCTAssertEqual(claim.record?.id, records[0].id)
        XCTAssertEqual(claim.record?.state, .started)

        let recoveredJob = UpscaleJob(
            identifier: records[0].id,
            inputURL: sources[0].url,
            outputURL: outputDirectory.appendingPathComponent(
                records[0].bookmarks.outputDisplayName
            ),
            targetResolution: settings.targetResolution,
            codec: settings.codec,
            preserveAudio: settings.preserveAudio,
            mode: settings.requestedMode,
            processingConfiguration: settings.processingConfiguration
        )
        let recovered = R13ResolvedRecoverableUpscaleJob(
            summary: try R13RecoverableUpscaleJob(job: recoveredJob),
            job: recoveredJob,
            securityAccess: try makeAccessSet(
                sourceURL: recoveredJob.inputURL,
                outputDirectoryURL: outputDirectory
            )
        )
        let engine = R13UIModeEngineService(
            recoverableJobs: [recovered]
        )
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: sources),
            engine: engine,
            resolver: resolver
        )
        await waitForPendingQueue(
            viewModel,
            ids: records.map(\.id),
            requireIdle: true
        )
        for _ in 0..<1_000 where viewModel.recoverableJobs.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(
            viewModel.recoverableJobs.map(\.id),
            [records[0].id]
        )

        viewModel.resumeRecoverableJob(id: records[0].id)
        await waitForSubmittedJobs(engine, count: 1)
        let recoveredHandle = try XCTUnwrap(engine.latestHandle)
        recoveredHandle.completeSuccess(recoveredJob.outputURL)

        await waitForSubmittedJobs(engine, count: 2)
        await waitForPendingQueue(
            viewModel,
            ids: [records[1].id],
            requireIdle: true
        )
        XCTAssertEqual(
            engine.submittedJobs.map(\.identifier),
            records.map(\.id)
        )
        let persisted = try await queue.load()
        XCTAssertEqual(persisted.records.map(\.id), [records[1].id])
        XCTAssertEqual(persisted.records.first?.state, .started)

        engine.latestHandle?.completeCancellation()
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
    }

    func testPendingQueueStartsScopesBeforeCheckingRestoredPaths()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent(
            "scope-restored-source.mov",
            isDirectory: false
        )
        let outputDirectory = directory.appendingPathComponent(
            "ScopeRestoredOutput",
            isDirectory: true
        )
        let source = SourceProfile(
            url: sourceURL,
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
        let resolver = R13UIQueueBookmarkResolver()
        let record = try makePendingQueueWorkflowRecord(
            id: "queue-scope-order-job",
            order: 0,
            source: source,
            outputDirectory: outputDirectory,
            outputDisplayName: "scope-restored-output.mp4",
            settings: makePendingQueueSettings(
                targetResolution: .p2160,
                preserveAudio: false
            ),
            resolver: resolver
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueue(record)
        let scopeMaterializer = R13UIScopeStartMaterializer(
            sourceURL: sourceURL,
            outputDirectoryURL: outputDirectory
        )
        scopeMaterializer.enableMaterialization()
        let engine = R13UIModeEngineService()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine,
            resolver: resolver,
            securityScopedResourceAccess:
                scopeMaterializer.resourceAccess
        )
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputDirectory.path)
        )

        viewModel.startNextPendingWork()
        await waitForSubmittedJobs(engine, count: 1)

        XCTAssertEqual(viewModel.state, .running)
        XCTAssertEqual(engine.submittedJobs.map(\.identifier), [record.id])
        XCTAssertEqual(
            scopeMaterializer.materializedURLs
                .map(\.standardizedFileURL),
            [sourceURL, outputDirectory].map(\.standardizedFileURL)
        )
        XCTAssertEqual(scopeMaterializer.activeScopeCount, 2)

        engine.latestHandle?.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }

        XCTAssertEqual(scopeMaterializer.activeScopeCount, 2)

        viewModel.startUpscale()
        await waitForSubmittedJobs(engine, count: 2)
        XCTAssertEqual(viewModel.state, .running)
        XCTAssertEqual(scopeMaterializer.activeScopeCount, 2)

        engine.latestHandle?.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }
        XCTAssertEqual(scopeMaterializer.activeScopeCount, 2)

        viewModel.upscaleAnotherVideo()
        for _ in 0..<500 where scopeMaterializer.activeScopeCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(scopeMaterializer.activeScopeCount, 0)
    }

    func testPendingQueueFailureRemovesFailedHeadAndPausesWithNextPending()
        async throws {
        let fixture = try await makeTwoItemPendingQueueFixture(
            prefix: "failure-pause"
        )
        fixture.viewModel.startNextPendingWork()
        await waitForSubmittedJobs(fixture.engine, count: 1)

        let handle = try XCTUnwrap(fixture.engine.latestHandle)
        handle.completeFailure(
            UpscalerEngineError.strategyFailed(
                "injected queue workflow failure"
            )
        )
        await waitForPendingQueue(
            fixture.viewModel,
            ids: [fixture.records[1].id],
            requireIdle: true
        )
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(fixture.engine.submittedJobs.count, 1)
        guard case .failed = fixture.viewModel.state else {
            return XCTFail("Expected the failed queue job to be visible.")
        }
        let persisted = try await fixture.queue.load()
        XCTAssertEqual(persisted.records.map(\.id), [fixture.records[1].id])
        XCTAssertEqual(persisted.records.first?.state, .pending)
        XCTAssertNil(persisted.records.first?.startedAt)
    }

    func testPendingQueueFailureRetainsScopesAcrossRetryAndFinishedState()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "queue-retry-scope.mov",
            hasAudio: false
        )
        let resolver = R13UIQueueBookmarkResolver()
        let record = try makePendingQueueWorkflowRecord(
            id: "queue-retry-scope-job",
            order: 0,
            source: source,
            outputDirectory: outputDirectory,
            outputDisplayName: "queue-retry-scope-output.mp4",
            settings: makePendingQueueSettings(
                targetResolution: .p2160,
                preserveAudio: false
            ),
            resolver: resolver
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueue(record)
        let engine = R13UIModeEngineService()
        let scopeAudit = R13UIResourceAccessAudit()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine,
            resolver: resolver,
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true
        )

        viewModel.startNextPendingWork()
        await waitForSubmittedJobs(engine, count: 1)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertEqual(
            scopeAudit.startedURLs.map(\.standardizedFileURL),
            [source.url, outputDirectory].map(\.standardizedFileURL)
        )

        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed(
                "injected queued retry failure"
            )
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        for _ in 0..<100 {
            await Task.yield()
        }

        guard case .failed = viewModel.state else {
            return XCTFail("Expected the queued attempt to fail.")
        }
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)

        viewModel.retryFailedUpscale()
        await waitForSubmittedJobs(engine, count: 2)

        XCTAssertEqual(viewModel.state, .running)
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)

        let retryJob = try XCTUnwrap(engine.submittedJobs.last)
        let retryHandle = try XCTUnwrap(engine.latestHandle)
        retryHandle.completeSuccess(retryJob.outputURL)
        for _ in 0..<200 where viewModel.state != .finished(retryJob.outputURL) {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .finished(retryJob.outputURL))
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)

        viewModel.dismissTerminalJob()
        for _ in 0..<200 where scopeAudit.activeScopeCount != 0 {
            await Task.yield()
        }

        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
        XCTAssertEqual(
            scopeAudit.stoppedURLs.map(\.standardizedFileURL),
            [outputDirectory, source.url].map(\.standardizedFileURL)
        )
    }

    func testPendingQueueCancellationRemovesCancelledHeadAndPausesWithNextPending()
        async throws {
        let fixture = try await makeTwoItemPendingQueueFixture(
            prefix: "cancellation-pause"
        )
        fixture.viewModel.startNextPendingWork()
        await waitForSubmittedJobs(fixture.engine, count: 1)

        let handle = try XCTUnwrap(fixture.engine.latestHandle)
        handle.completeCancellation()
        await waitForPendingQueue(
            fixture.viewModel,
            ids: [fixture.records[1].id],
            requireIdle: true
        )
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(fixture.engine.submittedJobs.count, 1)
        XCTAssertEqual(fixture.viewModel.state, .ready)
        let persisted = try await fixture.queue.load()
        XCTAssertEqual(persisted.records.map(\.id), [fixture.records[1].id])
        XCTAssertEqual(persisted.records.first?.state, .pending)
        XCTAssertNil(persisted.records.first?.startedAt)
    }

    func testPendingQueueCancellationRetainsSourceScopeWhenOutputFolderChanges()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let originalOutputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let newOutputDirectory = directory.appendingPathComponent(
            "NewOutput",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: newOutputDirectory,
            withIntermediateDirectories: false
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "queue-cancel-new-output.mov",
            hasAudio: false
        )
        let resolver = R13UIQueueBookmarkResolver()
        let record = try makePendingQueueWorkflowRecord(
            id: "queue-cancel-new-output-job",
            order: 0,
            source: source,
            outputDirectory: originalOutputDirectory,
            outputDisplayName: "queue-original-output.mp4",
            settings: makePendingQueueSettings(
                targetResolution: .p2160,
                preserveAudio: false
            ),
            resolver: resolver
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueue(record)
        let engine = R13UIModeEngineService()
        let scopeAudit = R13UIResourceAccessAudit()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine,
            resolver: resolver,
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true
        )

        viewModel.startNextPendingWork()
        await waitForSubmittedJobs(engine, count: 1)
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeCancellation()
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }

        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertEqual(
            scopeAudit.startedURLs.map(\.standardizedFileURL),
            [source.url, originalOutputDirectory]
                .map(\.standardizedFileURL)
        )
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)

        viewModel.startUpscale()
        await waitForSubmittedJobs(engine, count: 2)

        XCTAssertEqual(
            scopeAudit.activeURLs,
            [source.url, originalOutputDirectory]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)

        let sameOutputRetryHandle = try XCTUnwrap(engine.latestHandle)
        sameOutputRetryHandle.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }

        scopeAudit.adoptSystemGrant(for: newOutputDirectory)
        XCTAssertEqual(
            scopeAudit.adoptedURLs,
            [newOutputDirectory.standardizedFileURL]
        )
        let newOutputURL = try XCTUnwrap(
            viewModel.acceptOutputDirectorySelectedByUser(
                newOutputDirectory,
                requestedFilename: "queue-new-output.mp4",
                preferredPathExtension: "mp4"
            )
        )
        for _ in 0..<500 where scopeAudit.stoppedURLs.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(
            scopeAudit.stoppedURLs.map(\.standardizedFileURL),
            [originalOutputDirectory.standardizedFileURL]
        )
        XCTAssertEqual(
            scopeAudit.activeURLs,
            [source.url, newOutputDirectory]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )

        viewModel.startUpscale()
        await waitForSubmittedJobs(engine, count: 3)

        let resubmittedJob = try XCTUnwrap(engine.submittedJobs.last)
        XCTAssertEqual(resubmittedJob.inputURL, source.url)
        XCTAssertEqual(resubmittedJob.outputURL, newOutputURL)
        XCTAssertEqual(
            scopeAudit.activeURLs,
            [source.url, newOutputDirectory]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )
        XCTAssertEqual(
            scopeAudit.stoppedURLs.map(\.standardizedFileURL),
            [originalOutputDirectory.standardizedFileURL]
        )

        engine.latestHandle?.completeCancellation()
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }
        viewModel.upscaleAnotherVideo()
        for _ in 0..<500 where scopeAudit.activeScopeCount != 0 {
            await Task.yield()
        }

        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
        XCTAssertEqual(
            scopeAudit.stoppedURLs.map(\.standardizedFileURL).sorted {
                $0.path < $1.path
            },
            [source.url, originalOutputDirectory, newOutputDirectory]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )
    }

    func testPendingQueueCancellationReleasesScopesWhenDifferentSourceIsLoaded()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let originalSource = try makePendingQueueSource(
            in: directory,
            name: "queue-cancel-original.mov",
            hasAudio: false
        )
        let newSource = try makePendingQueueSource(
            in: directory,
            name: "queue-cancel-replacement.mov",
            hasAudio: false
        )
        let resolver = R13UIQueueBookmarkResolver()
        let record = try makePendingQueueWorkflowRecord(
            id: "queue-cancel-replace-source-job",
            order: 0,
            source: originalSource,
            outputDirectory: outputDirectory,
            outputDisplayName: "queue-cancel-original.mp4",
            settings: makePendingQueueSettings(
                targetResolution: .p2160,
                preserveAudio: false
            ),
            resolver: resolver
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueue(record)
        let engine = R13UIModeEngineService()
        let scopeAudit = R13UIResourceAccessAudit()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(
                profiles: [originalSource, newSource]
            ),
            engine: engine,
            resolver: resolver,
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true
        )

        viewModel.startNextPendingWork()
        await waitForSubmittedJobs(engine, count: 1)
        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeCancellation()
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        for _ in 0..<500 where viewModel.state != .ready {
            await Task.yield()
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        XCTAssertEqual(scopeAudit.activeScopeCount, 2)
        XCTAssertTrue(scopeAudit.stoppedURLs.isEmpty)

        scopeAudit.adoptSystemGrant(for: newSource.url)
        viewModel.acceptSourceURLSelectedByUser(newSource.url)

        XCTAssertEqual(
            scopeAudit.stoppedURLs.map(\.standardizedFileURL),
            [outputDirectory, originalSource.url]
                .map(\.standardizedFileURL)
        )
        XCTAssertEqual(
            scopeAudit.activeURLs,
            [newSource.url.standardizedFileURL]
        )
        for _ in 0..<500 where viewModel.sourceProfile?.url != newSource.url {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.sourceProfile?.url, newSource.url)

        viewModel.upscaleAnotherVideo()
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
    }

    func testPendingQueueViewModelReordersRemovesAndClearsPersistently()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let resolver = R13UIQueueBookmarkResolver()
        let sources = try ["first.mov", "second.mov", "third.mov"].map {
            try makePendingQueueSource(
                in: directory,
                name: $0,
                hasAudio: false
            )
        }
        let records = try sources.enumerated().map { index, source in
            try makePendingQueueWorkflowRecord(
                id: "queue-mutation-\(index)",
                order: index,
                source: source,
                outputDirectory: outputDirectory,
                outputDisplayName: "output-\(index).mp4",
                resolver: resolver
            )
        }
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueueMany(records)
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: sources),
            resolver: resolver
        )
        await waitForPendingQueue(
            viewModel,
            ids: records.map(\.id),
            requireIdle: true
        )

        viewModel.movePendingWork(id: records[2].id, offset: -1)
        let reorderedIDs = [
            records[0].id,
            records[2].id,
            records[1].id
        ]
        await waitForPendingQueue(
            viewModel,
            ids: reorderedIDs,
            requireIdle: true
        )
        let reorderedSnapshot = try await queue.load()
        XCTAssertEqual(
            reorderedSnapshot.records.map(\.id),
            reorderedIDs
        )

        viewModel.removePendingWork(id: records[2].id)
        let remainingIDs = [records[0].id, records[1].id]
        await waitForPendingQueue(
            viewModel,
            ids: remainingIDs,
            requireIdle: true
        )
        let remainingSnapshot = try await queue.load()
        XCTAssertEqual(
            remainingSnapshot.records.map(\.id),
            remainingIDs
        )

        viewModel.clearPendingWork()
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        let clearedSnapshot = try await queue.load()
        XCTAssertTrue(clearedSnapshot.records.isEmpty)
    }

    func testPendingQueueStaleBookmarkReturnsClaimedHeadToPending()
        async throws {
        let fixture = try await makeSingleItemPendingQueueFixture(
            prefix: "stale-bookmark",
            resolver: R13UIQueueBookmarkResolver(
                sourceBookmarkIsStale: true
            )
        )

        fixture.viewModel.startNextPendingWork()
        await waitForPendingQueue(
            fixture.viewModel,
            ids: [fixture.record.id],
            requireIdle: true,
            requireError: true
        )

        XCTAssertTrue(fixture.engine.submittedJobs.isEmpty)
        let persisted = try await fixture.queue.load()
        XCTAssertEqual(persisted.records.first?.state, .pending)
        XCTAssertNil(persisted.records.first?.startedAt)
    }

    func testPendingQueueProbeFailureReturnsClaimedHeadToPending()
        async throws {
        let fixture = try await makeSingleItemPendingQueueFixture(
            prefix: "probe-failure",
            failingProbe: true
        )

        fixture.viewModel.startNextPendingWork()
        await waitForPendingQueue(
            fixture.viewModel,
            ids: [fixture.record.id],
            requireIdle: true,
            requireError: true
        )

        XCTAssertTrue(fixture.engine.submittedJobs.isEmpty)
        let persisted = try await fixture.queue.load()
        XCTAssertEqual(persisted.records.first?.state, .pending)
        XCTAssertNil(persisted.records.first?.startedAt)
    }

    func testPendingQueueExistingOutputReturnsClaimedHeadToPending()
        async throws {
        let fixture = try await makeSingleItemPendingQueueFixture(
            prefix: "existing-output"
        )
        let outputDirectoryPath = try XCTUnwrap(
            String(
                data: fixture.record.bookmarks.outputBookmark,
                encoding: .utf8
            )
        )
        let outputURL = URL(
            fileURLWithPath: outputDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            fixture.record.bookmarks.outputDisplayName
        )
        try Data("existing output".utf8).write(to: outputURL)

        fixture.viewModel.startNextPendingWork()
        await waitForPendingQueue(
            fixture.viewModel,
            ids: [fixture.record.id],
            requireIdle: true,
            requireError: true
        )

        XCTAssertTrue(fixture.engine.submittedJobs.isEmpty)
        XCTAssertEqual(
            fixture.viewModel.pendingQueueError,
            String(describing: UpscalerEngineError.outputAlreadyExists)
        )
        let persisted = try await fixture.queue.load()
        XCTAssertEqual(persisted.records.first?.state, .pending)
        XCTAssertNil(persisted.records.first?.startedAt)
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

    func testProcessingPathSelectionIsNonemptyOrderedAndExclusive()
        throws {
        let viewModel = makeReadyViewModel(
            engine: R13UIModeEngineService()
        )

        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            [.automatic]
        )
        XCTAssertTrue(
            viewModel.toggleProcessingPathForPendingJob(.mpsLanczos)
        )
        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            [.mpsLanczos]
        )
        XCTAssertTrue(
            viewModel.toggleProcessingPathForPendingJob(.coreImageLanczos)
        )
        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            [.mpsLanczos, .coreImageLanczos]
        )
        XCTAssertFalse(
            viewModel.selectedEnginePreferences.contains(.automatic)
        )
        XCTAssertTrue(viewModel.selectAutomaticRoutingForPendingJob())
        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            [.automatic]
        )

        XCTAssertTrue(viewModel.selectAllProcessingPathsForPendingJob())
        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            UpscaleEnginePreference.concreteProcessingPaths
        )
        XCTAssertTrue(viewModel.allProcessingPathsAreSelected)

        for path in UpscaleEnginePreference.concreteProcessingPaths
            .dropLast() {
            XCTAssertTrue(
                viewModel.toggleProcessingPathForPendingJob(path),
                path.rawValue
            )
        }
        let finalPath = try XCTUnwrap(
            UpscaleEnginePreference.concreteProcessingPaths.last
        )
        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            [finalPath]
        )
        XCTAssertFalse(
            viewModel.toggleProcessingPathForPendingJob(finalPath)
        )
        XCTAssertEqual(
            viewModel.selectedEnginePreferences,
            [finalPath]
        )
    }

    func testEveryConcreteScale4PathSelectionSubmitsExactPreference()
        async throws {
        let paths = UpscaleEnginePreference.concreteProcessingPaths
        XCTAssertEqual(paths.count, 10)

        for path in paths {
            let engine = R13UIModeEngineService()
            let viewModel = makeReadyViewModel(
                engine: engine,
                sourceResolution: .p270,
                targetResolution: .p1080,
                modelAssets: NoopModelAssetsService()
            )
            for _ in 0..<1_000 where viewModel.modelStatus != .ready {
                await Task.yield()
            }
            XCTAssertEqual(viewModel.modelStatus, .ready, path.rawValue)

            XCTAssertTrue(
                viewModel.toggleProcessingPathForPendingJob(path),
                path.rawValue
            )
            XCTAssertEqual(
                viewModel.selectedEnginePreferences,
                [path],
                path.rawValue
            )
            XCTAssertEqual(viewModel.enginePreference, path)
            XCTAssertEqual(viewModel.processingPathMenuTitle, path.title)
            XCTAssertTrue(
                viewModel.canStart,
                path.rawValue + ": "
                    + (viewModel.canStartFailureReason ?? "ready")
            )

            viewModel.startUpscale()
            await waitForSubmittedJobs(engine, count: 1)
            let job = try XCTUnwrap(engine.submittedJobs.first)
            XCTAssertEqual(job.targetResolution, .p1080)
            XCTAssertEqual(
                job.processingConfiguration.enginePreference,
                path
            )
            XCTAssertNotEqual(
                job.processingConfiguration.enginePreference,
                .automatic
            )
            XCTAssertEqual(job.outputURL, viewModel.outputURL)

            engine.latestHandle?.completeSuccess(job.outputURL)
            for _ in 0..<1_000 where viewModel.state == .running {
                await Task.yield()
            }
            XCTAssertEqual(viewModel.completedOutputURL, job.outputURL)
        }
    }

    func testProcessingPathSummaryStatesEnhancementBeforeApplePaths() {
        let viewModel = makeReadyViewModel(
            engine: R13UIModeEngineService()
        )

        XCTAssertTrue(
            viewModel.selectedModeSummary.hasPrefix(
                "Deterministic enhancement runs first. "
            )
        )

        XCTAssertTrue(
            viewModel.toggleProcessingPathForPendingJob(.mpsLanczos)
        )
        XCTAssertEqual(
            viewModel.selectedModeSummary,
            "Deterministic enhancement runs first, then the enhanced "
                + "video is processed by the explicit "
                + "\(UpscaleEnginePreference.mpsLanczos.title) path."
        )

        XCTAssertTrue(
            viewModel.toggleProcessingPathForPendingJob(.coreImageLanczos)
        )
        XCTAssertEqual(
            viewModel.selectedModeSummary,
            "Deterministic enhancement runs first for each of the 2 "
                + "selected Apple processing paths. Each path receives "
                + "the enhanced video and produces its own output; paths "
                + "are not chained."
        )
    }

    func testProcessingPathPreferencesMigrateLegacyScalarAndSortSelection()
        throws {
        let suiteName =
            "com.mirmir.tests.processing-paths.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let keys = MirmirPreferencesKeys.namespaced(suiteName)
        let store = MirmirPreferencesStore(
            defaults: defaults,
            keys: keys
        )
        defaults.set(
            UpscaleEnginePreference.mpsLanczos.rawValue,
            forKey: keys.enginePreference
        )

        XCTAssertEqual(store.loadEnginePreferences(), [.mpsLanczos])

        store.saveEnginePreferences([
            .metalFXSpatial,
            .coreImageLanczos,
            .mpsLanczos
        ])

        let expected: [UpscaleEnginePreference] = [
            .mpsLanczos,
            .coreImageLanczos,
            .metalFXSpatial
        ]
        XCTAssertEqual(store.loadEnginePreferences(), expected)
        XCTAssertEqual(store.load().enginePreferences, expected)
        XCTAssertEqual(
            defaults.string(forKey: keys.enginePreference),
            UpscaleEnginePreference.mpsLanczos.rawValue
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: keys.enginePreferences),
            expected.map(\.rawValue)
        )
    }

    func testMultiPathStartPersistsDistinctJobsAndContinuesAfterPathFailure()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "multi-path-source.mov",
            hasAudio: true
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        let engine = R13UIModeEngineService()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.preserveAudio = true
        viewModel.state = .ready
        let baseDestination = outputDirectory.appendingPathComponent(
            "multi-path-output.mp4"
        )
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(baseDestination)
        )
        XCTAssertTrue(
            viewModel.selectEngineForPendingJob(.mpsLanczos)
        )
        XCTAssertTrue(
            viewModel.toggleProcessingPathForPendingJob(.coreImageLanczos)
        )

        viewModel.startUpscale()
        await waitForSubmittedJobs(engine, count: 1)

        let firstSnapshot = try await queue.load()
        XCTAssertEqual(firstSnapshot.records.count, 2)
        XCTAssertEqual(
            firstSnapshot.records.map {
                $0.settings.processingConfiguration.enginePreference
            },
            [.mpsLanczos, .coreImageLanczos]
        )
        XCTAssertEqual(
            firstSnapshot.records.map {
                $0.bookmarks.outputDisplayName
            },
            [
                "multi-path-output_mps-lanczos.mp4",
                "multi-path-output_core-image-lanczos.mp4"
            ]
        )
        XCTAssertEqual(firstSnapshot.records[0].state, .started)
        XCTAssertEqual(firstSnapshot.records[1].state, .pending)
        XCTAssertTrue(
            firstSnapshot.records.allSatisfy {
                $0.settings.targetResolution == .p2160
                    && $0.settings.codec == viewModel.codec
                    && $0.settings.preserveAudio
                    && $0.settings.requestedMode == viewModel.selectedMode
                    && $0.settings.continuesAfterFailure
            }
        )
        let batchContexts = firstSnapshot.records.compactMap {
            $0.settings.processingPathBatch
        }
        XCTAssertEqual(batchContexts.count, 2)
        XCTAssertEqual(Set(batchContexts.map(\.id)).count, 1)
        XCTAssertEqual(batchContexts.map(\.ordinal), [0, 1])
        XCTAssertEqual(batchContexts.map(\.totalCount), [2, 2])
        XCTAssertEqual(
            batchContexts.map(\.path),
            [.mpsLanczos, .coreImageLanczos]
        )

        let firstHandle = try XCTUnwrap(engine.latestHandle)
        firstHandle.completeFailure(
            UpscalerEngineError.strategyFailed(
                "injected independent path failure"
            )
        )
        await waitForSubmittedJobs(engine, count: 2)

        XCTAssertEqual(
            engine.submittedJobs.map {
                $0.processingConfiguration.enginePreference
            },
            [.mpsLanczos, .coreImageLanczos]
        )
        XCTAssertEqual(
            Set(engine.submittedJobs.map(\.outputURL)).count,
            2
        )
        let secondJob = try XCTUnwrap(engine.submittedJobs.last)
        engine.latestHandle?.completeSuccess(secondJob.outputURL)
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        let terminal = try await queue.load()
        XCTAssertEqual(
            terminal.processingPathBatchResults.map(\.status),
            [.failed, .completed]
        )
        let summary = try XCTUnwrap(
            viewModel.processingPathBatchSummary
        )
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertTrue(summary.isComplete)
        XCTAssertFalse(summary.allSucceeded)
        guard case .failed(let reason) = viewModel.state else {
            return XCTFail(
                "A later path success masked an earlier path failure."
            )
        }
        XCTAssertTrue(reason.contains("1 of 2 successful"))
    }

    func testProcessingPathBatchFailureSurvivesRestartAndLaterSuccess()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "batch-restart-source.mov",
            hasAudio: false
        )
        let resolver = R13UIQueueBookmarkResolver()
        let queueDirectory = directory.appendingPathComponent(
            "Queue",
            isDirectory: true
        )
        let queue = MirmirPendingWorkQueue(directoryURL: queueDirectory)
        let batchID = "batch-view-model-restart"
        let paths: [UpscaleEnginePreference] = [
            .mpsLanczos,
            .coreImageLanczos
        ]
        let records = try paths.enumerated().map { index, path in
            try makePendingQueueWorkflowRecord(
                id: "batch-restart-job-\(index)",
                order: index,
                source: source,
                outputDirectory: outputDirectory,
                outputDisplayName: "batch-restart-output-\(index).mp4",
                settings: makePendingQueueSettings(
                    targetResolution: .p2160,
                    preserveAudio: false,
                    requestedMode: .deterministic,
                    processingConfiguration:
                        UpscaleProcessingConfiguration(
                            enginePreference: path
                        ),
                    continuesAfterFailure: true,
                    processingPathBatch:
                        MirmirProcessingPathBatchContext(
                            id: batchID,
                            path: path,
                            ordinal: index,
                            totalCount: paths.count
                        )
                ),
                resolver: resolver
            )
        }
        _ = try await queue.enqueueMany(records)
        _ = try await queue.markStartedOrReturnHead()
        _ = try await queue.recordTerminalResultAndRemove(
            id: records[0].id,
            status: .failed,
            reason: "injected pre-restart failure"
        )

        let restartedQueue = MirmirPendingWorkQueue(
            directoryURL: queueDirectory
        )
        let engine = R13UIModeEngineService()
        let viewModel = makePendingQueueViewModel(
            queue: restartedQueue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine,
            resolver: resolver
        )
        await waitForPendingQueue(
            viewModel,
            ids: [records[1].id],
            requireIdle: true
        )
        XCTAssertEqual(
            viewModel.processingPathBatchSummary?.failedCount,
            1
        )

        viewModel.startNextPendingWork()
        await waitForSubmittedJobs(engine, count: 1)
        let finalJob = try XCTUnwrap(engine.submittedJobs.first)
        engine.latestHandle?.completeSuccess(finalJob.outputURL)
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )

        let summary = try XCTUnwrap(
            viewModel.processingPathBatchSummary
        )
        XCTAssertEqual(
            summary.results.map(\.status),
            [.failed, .completed]
        )
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertTrue(summary.isComplete)
        XCTAssertFalse(summary.allSucceeded)
        guard case .failed = viewModel.state else {
            return XCTFail(
                "Restarted batch incorrectly reported overall success."
            )
        }
    }

    // swiftlint:disable:next function_body_length
    func testAllPathsFanOutUsesOneSourceAndIndependentOutputs()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "all-paths-source.mov",
            hasAudio: false,
            resolution: .p270
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        let engine = R13UIModeEngineService()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: [source]),
            engine: engine,
            modelAssets: NoopModelAssetsService()
        )
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p1080
        viewModel.state = .ready
        viewModel.temporalConsistencyEnabled = false
        viewModel.edgeFidelityLevel = .high
        viewModel.detailRecoveryLevel = .low
        viewModel.edgePreservationEnabled = true
        let destination = outputDirectory.appendingPathComponent(
            "all-paths-output.mp4"
        )
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(destination)
        )
        XCTAssertTrue(viewModel.selectAllProcessingPathsForPendingJob())
        XCTAssertTrue(
            viewModel.canStart,
            viewModel.canStartFailureReason ?? "All Paths must be startable."
        )

        viewModel.startUpscale()
        await waitForSubmittedJobs(engine, count: 1)

        let snapshot = try await queue.load()
        let paths = UpscaleEnginePreference.concreteProcessingPaths
        XCTAssertEqual(snapshot.records.count, paths.count)
        XCTAssertEqual(
            snapshot.records.map {
                $0.settings.processingConfiguration.enginePreference
            },
            paths
        )
        XCTAssertEqual(
            Set(snapshot.records.map(\.bookmarks.sourceBookmark)).count,
            1,
            "Every path must start from the same selected source, not the "
                + "preceding path's output."
        )
        XCTAssertEqual(
            Set(snapshot.records.map(\.bookmarks.outputDisplayName)).count,
            paths.count
        )
        XCTAssertEqual(snapshot.records.first?.state, .started)
        XCTAssertTrue(
            snapshot.records.dropFirst().allSatisfy {
                $0.state == .pending
            }
        )
        XCTAssertTrue(
            snapshot.records.allSatisfy {
                let configuration =
                    $0.settings.processingConfiguration
                return $0.settings.targetResolution == .p1080
                    && !configuration.temporalConsistencyEnabled
                    && configuration.edgeFidelityLevel == .high
                    && configuration.detailRecoveryLevel == .low
                    && configuration.effects.edgePreservationEnabled
                    && $0.settings.continuesAfterFailure
            },
            "Fan-out must copy the deterministic enhancement controls to "
                + "every independent path job."
        )

        for (index, path) in paths.enumerated() {
            await waitForSubmittedJobs(engine, count: index + 1)
            let job = engine.submittedJobs[index]
            XCTAssertEqual(job.inputURL, source.url)
            XCTAssertEqual(job.targetResolution, .p1080)
            XCTAssertEqual(
                job.processingConfiguration.enginePreference,
                path
            )
            XCTAssertEqual(
                job.outputURL.lastPathComponent,
                snapshot.records[index].bookmarks.outputDisplayName
            )
            engine.latestHandle?.completeSuccess(job.outputURL)
        }
        await waitForPendingQueue(
            viewModel,
            ids: [],
            requireIdle: true
        )
        XCTAssertEqual(
            engine.submittedJobs.map {
                $0.processingConfiguration.enginePreference
            },
            paths
        )
        XCTAssertEqual(
            Set(engine.submittedJobs.map(\.outputURL)).count,
            paths.count
        )
        let terminal = try await queue.load()
        XCTAssertTrue(terminal.records.isEmpty)
        XCTAssertEqual(
            terminal.processingPathBatchResults.map(\.batch.path),
            paths
        )
        XCTAssertTrue(
            terminal.processingPathBatchResults.allSatisfy {
                $0.status == .completed
            }
        )
        let summary = try XCTUnwrap(
            MirmirProcessingPathBatchSummary.latest(
                in: terminal.processingPathBatchResults
            )
        )
        XCTAssertEqual(summary.completedCount, paths.count)
        XCTAssertEqual(summary.results.count, paths.count)
        XCTAssertTrue(summary.isComplete)
        XCTAssertTrue(summary.allSucceeded)
    }

    func testProcessingPathOutputFilenameIsStableAndFileSystemSafe() {
        let base = URL(fileURLWithPath: "/tmp/")
            .appendingPathComponent(
                String(repeating: "é", count: 180) + ".mp4"
            )
        let first = MirmirViewModel.processingPathOutputURL(
            basedOn: base,
            path: .videoToolboxLowLatency
        )
        let second = MirmirViewModel.processingPathOutputURL(
            basedOn: base,
            path: .videoToolboxLowLatency
        )

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(
            first.lastPathComponent.hasSuffix(
                "_videotoolbox-low-latency.mp4"
            )
        )
    }

    private func makePendingQueueViewModel(
        queue: MirmirPendingWorkQueue,
        media: any MediaPipelineService,
        engine: R13UIModeEngineService = R13UIModeEngineService(),
        modelAssets: any ModelAssetsService =
            NotRequiredModelAssetsService(),
        resolver: R13UIQueueBookmarkResolver =
            R13UIQueueBookmarkResolver(),
        securityScopedResourceAccess:
            MirmirSecurityScopedResourceAccess =
                r13UIAlwaysGrantedResourceAccess
    ) -> MirmirViewModel {
        MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: engine,
            modelAssets: modelAssets,
            pendingWorkQueue: queue,
            workHistoryBookmarkResolver: resolver,
            securityScopedResourceAccess: securityScopedResourceAccess
        )
    }

    private func makePendingQueueSource(
        in directory: URL,
        name: String,
        hasAudio: Bool,
        resolution: VideoResolution = .p1080,
        videoFormat: MediaVideoFormat = .sdrBT709
    ) throws -> SourceProfile {
        let url = directory.appendingPathComponent(name)
        try Data([0x01, 0x02, 0x03]).write(to: url)
        return SourceProfile(
            url: url,
            resolution: resolution,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: hasAudio,
            videoFormat: videoFormat
        )
    }

    private func makePendingQueueOutputDirectory(
        in directory: URL
    ) throws -> URL {
        let output = directory.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: false
        )
        return output
    }

    private func makePendingQueueWorkflowRecord(
        id: String,
        order: Int,
        source: SourceProfile,
        outputDirectory: URL,
        outputDisplayName: String,
        settings: MirmirPendingWorkSettings =
            makePendingQueueSettings(),
        resolver: R13UIQueueBookmarkResolver
    ) throws -> MirmirPendingWorkRecord {
        makePendingQueueRecord(
            id: id,
            order: order,
            bookmarks: MirmirPendingWorkBookmarks(
                sourceBookmark: try resolver.makeBookmark(
                    for: source.url,
                    role: .source
                ),
                outputBookmark: try resolver.makeBookmark(
                    for: outputDirectory,
                    role: .output
                ),
                sourceDisplayName: source.url.lastPathComponent,
                outputDisplayName: outputDisplayName
            ),
            settings: settings
        )
    }

    private func makeTwoItemPendingQueueFixture(
        prefix: String
    ) async throws -> R13UITwoItemPendingQueueFixture {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let resolver = R13UIQueueBookmarkResolver()
        let sources = try [0, 1].map {
            try makePendingQueueSource(
                in: directory,
                name: "\(prefix)-\($0).mov",
                hasAudio: true
            )
        }
        let records = try sources.enumerated().map { index, source in
            try makePendingQueueWorkflowRecord(
                id: "\(prefix)-job-\(index)",
                order: index,
                source: source,
                outputDirectory: outputDirectory,
                outputDisplayName: "\(prefix)-output-\(index).mp4",
                settings: makePendingQueueSettings(
                    targetResolution: .p2160,
                    codec: .hevc,
                    preserveAudio: true,
                    requestedMode: .deterministic,
                    processingConfiguration: .default
                ),
                resolver: resolver
            )
        }
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueueMany(records)
        let engine = R13UIModeEngineService()
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: R13UIQueueMediaPipeline(profiles: sources),
            engine: engine,
            resolver: resolver
        )
        await waitForPendingQueue(
            viewModel,
            ids: records.map(\.id),
            requireIdle: true
        )
        return R13UITwoItemPendingQueueFixture(
            queue: queue,
            records: records,
            viewModel: viewModel,
            engine: engine
        )
    }

    private func makeSingleItemPendingQueueFixture(
        prefix: String,
        resolver: R13UIQueueBookmarkResolver =
            R13UIQueueBookmarkResolver(),
        failingProbe: Bool = false
    ) async throws -> R13UISingleItemPendingQueueFixture {
        let directory = try makePendingQueueTemporaryDirectory()
        let outputDirectory = try makePendingQueueOutputDirectory(
            in: directory
        )
        let source = try makePendingQueueSource(
            in: directory,
            name: "\(prefix).mov",
            hasAudio: false
        )
        let record = try makePendingQueueWorkflowRecord(
            id: "\(prefix)-job",
            order: 0,
            source: source,
            outputDirectory: outputDirectory,
            outputDisplayName: "\(prefix)-output.mp4",
            settings: makePendingQueueSettings(
                targetResolution: .p2160,
                preserveAudio: false
            ),
            resolver: R13UIQueueBookmarkResolver()
        )
        let queue = MirmirPendingWorkQueue(
            directoryURL: directory.appendingPathComponent(
                "Queue",
                isDirectory: true
            )
        )
        _ = try await queue.enqueue(record)
        let engine = R13UIModeEngineService()
        let media = R13UIQueueMediaPipeline(
            profiles: [source],
            failingProbePaths: failingProbe ? [source.url.path] : []
        )
        let viewModel = makePendingQueueViewModel(
            queue: queue,
            media: media,
            engine: engine,
            resolver: resolver
        )
        await waitForPendingQueue(
            viewModel,
            ids: [record.id],
            requireIdle: true
        )
        return R13UISingleItemPendingQueueFixture(
            queue: queue,
            record: record,
            viewModel: viewModel,
            engine: engine
        )
    }

    private func waitForPendingQueue(
        _ viewModel: MirmirViewModel,
        ids: [String]? = nil,
        count: Int? = nil,
        requireIdle: Bool,
        requireError: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            let hasExpectedIDs = ids.map {
                viewModel.pendingWorkRecords.map(\.id) == $0
            } ?? true
            let hasExpectedCount = count.map {
                viewModel.pendingWorkRecords.count == $0
            } ?? true
            let isIdle = !requireIdle
                || (
                    !viewModel.pendingQueueIsLoading
                        && !viewModel.pendingQueueMutationIsInProgress
                )
            let hasError = !requireError
                || viewModel.pendingQueueError != nil
            if hasExpectedIDs,
               hasExpectedCount,
               isIdle,
               hasError {
                return
            }
            await Task.yield()
        }
        let errorText = viewModel.pendingQueueError ?? "nil"
        XCTFail(
            "Timed out waiting for pending queue state. "
                + "IDs: \(viewModel.pendingWorkRecords.map(\.id)); "
                + "loading: \(viewModel.pendingQueueIsLoading); "
                + "mutating: \(viewModel.pendingQueueMutationIsInProgress); "
                + "error: \(errorText)",
            file: file,
            line: line
        )
    }

    private func waitForSubmittedJobs(
        _ engine: R13UIModeEngineService,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if engine.submittedJobs.count == count {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(count) submitted queue jobs; "
                + "observed \(engine.submittedJobs.count).",
            file: file,
            line: line
        )
    }

    private func makeReadyViewModel(
        engine: R13UIModeEngineService,
        sourceResolution: VideoResolution = .p1080,
        targetResolution: VideoResolution = .p2160,
        modelAssets: any ModelAssetsService =
            NotRequiredModelAssetsService()
    ) -> MirmirViewModel {
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: modelAssets
        )
        let source = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/r13-ui-source.mov"),
            resolution: sourceResolution,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: false
        )
        viewModel.sourceProfile = source
        viewModel.targetResolution = targetResolution
        viewModel.state = .ready
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(
                for: source,
                target: targetResolution
            )
        ))
        return viewModel
    }

    private func makeAccessSet(
        sourceURL: URL,
        outputDirectoryURL: URL,
        scopeAudit: R13UISecurityScopeAudit? = nil
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
                        startAccessing: {
                            scopeAudit?.recordStart(role: role)
                            return true
                        },
                        stopAccessing: {
                            scopeAudit?.recordStop(role: role)
                        }
                    )
                )
            }
        )
    }

    private func makeRecoveredJob(
        identifier: String,
        codec: OutputCodec = .hevc,
        mode: UpscaleMode = .deterministic,
        processingConfiguration:
            UpscaleProcessingConfiguration = .default
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
            codec: codec,
            preserveAudio: false,
            mode: mode,
            processingConfiguration: processingConfiguration
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

    private func makePreviewFrame() throws -> UpscalePreviewFrame {
        let source = try XCTUnwrap(
            UpscalePreviewImage(
                width: 1,
                height: 1,
                rgba8: Data([16, 16, 16, 255])
            )
        )
        let processed = try XCTUnwrap(
            UpscalePreviewImage(
                width: 1,
                height: 1,
                rgba8: Data([224, 224, 224, 255])
            )
        )
        return try XCTUnwrap(
            UpscalePreviewFrame(
                frameIndex: 3,
                presentationSeconds: 0.125,
                source: source,
                processed: processed
            )
        )
    }
}

@MainActor
private struct R13UITwoItemPendingQueueFixture {
    let queue: MirmirPendingWorkQueue
    let records: [MirmirPendingWorkRecord]
    let viewModel: MirmirViewModel
    let engine: R13UIModeEngineService
}

@MainActor
private struct R13UISingleItemPendingQueueFixture {
    let queue: MirmirPendingWorkQueue
    let record: MirmirPendingWorkRecord
    let viewModel: MirmirViewModel
    let engine: R13UIModeEngineService
}

private let r13UIAlwaysGrantedResourceAccess =
    MirmirSecurityScopedResourceAccess(
        startAccessing: { _ in true },
        stopAccessing: { _ in },
        canCreateBookmark: { _ in true }
    )

private final class R13UIScopeStartMaterializer: @unchecked Sendable {
    private struct State {
        var materializationEnabled = false
        var materializedURLs: [URL] = []
        var activeCounts: [URL: Int] = [:]
    }

    private let lock = NSLock()
    private let sourceURL: URL
    private let outputDirectoryURL: URL
    private var state = State()

    init(sourceURL: URL, outputDirectoryURL: URL) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
    }

    var materializedURLs: [URL] {
        lock.withLock { state.materializedURLs }
    }

    var activeScopeCount: Int {
        lock.withLock { state.activeCounts.values.reduce(0, +) }
    }

    func enableMaterialization() {
        lock.withLock {
            state.materializationEnabled = true
        }
    }

    var resourceAccess: MirmirSecurityScopedResourceAccess {
        MirmirSecurityScopedResourceAccess(
            startAccessing: { [weak self] url in
                self?.startAccessing(url) ?? false
            },
            stopAccessing: { [weak self] url in
                self?.stopAccessing(url)
            },
            canCreateBookmark: { _ in true }
        )
    }

    private func startAccessing(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let shouldMaterialize = lock.withLock {
            state.materializationEnabled
        }
        if shouldMaterialize {
            do {
                if standardizedURL.path == sourceURL.path,
                   !FileManager.default.fileExists(atPath: sourceURL.path) {
                    try Data([0x01]).write(to: sourceURL)
                    lock.withLock {
                        state.materializedURLs.append(sourceURL)
                    }
                } else if standardizedURL.path == outputDirectoryURL.path,
                          !FileManager.default.fileExists(
                              atPath: outputDirectoryURL.path
                          ) {
                    try FileManager.default.createDirectory(
                        at: outputDirectoryURL,
                        withIntermediateDirectories: false
                    )
                    lock.withLock {
                        state.materializedURLs.append(outputDirectoryURL)
                    }
                }
            } catch {
                return false
            }
        }
        lock.withLock {
            state.activeCounts[standardizedURL, default: 0] += 1
        }
        return true
    }

    private func stopAccessing(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        lock.withLock {
            let count = state.activeCounts[standardizedURL] ?? 0
            if count <= 1 {
                state.activeCounts.removeValue(forKey: standardizedURL)
            } else {
                state.activeCounts[standardizedURL] = count - 1
            }
        }
    }
}

private enum R13UIQueueFileSystemFault: Error {
    case injectedReadFailure
}

private final class R13UIOneShotReadFailureFileSystem:
    R13RestartFileSystem,
    @unchecked Sendable {
    private let base = R13LocalRestartFileSystem()
    private let lock = NSLock()
    private var successfulReadsBeforeFailure: Int?

    func failRead(afterSuccessfulReads count: Int) {
        precondition(count >= 0)
        lock.withLock {
            successfulReadsBeforeFailure = count
        }
    }

    func ensureDirectory(_ url: URL) throws {
        try base.ensureDirectory(url)
    }

    func createDirectoryExclusively(_ url: URL) throws {
        try base.createDirectoryExclusively(url)
    }

    func validateDirectory(_ url: URL) throws {
        try base.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        base.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let shouldFail = lock.withLock { () -> Bool in
            guard let remaining = successfulReadsBeforeFailure else {
                return false
            }
            guard remaining > 0 else {
                successfulReadsBeforeFailure = nil
                return true
            }
            successfulReadsBeforeFailure = remaining - 1
            return false
        }
        if shouldFail {
            throw R13UIQueueFileSystemFault.injectedReadFailure
        }
        return try base.readRegularFile(
            url,
            maximumBytes: maximumBytes
        )
    }

    func readRegularFileWithSnapshot(
        _ url: URL,
        maximumBytes: Int
    ) throws -> R13RestartRegularFileRead {
        R13RestartRegularFileRead(
            data: try readRegularFile(url, maximumBytes: maximumBytes),
            snapshot: nil
        )
    }

    func regularFile(
        _ url: URL,
        matches snapshot: R13RestartRegularFileSnapshot
    ) -> Bool {
        base.regularFile(url, matches: snapshot)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try base.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try base.replaceAtomically(data, at: url)
    }

    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        try base.publishDirectoryAtomically(
            from: sourceURL,
            to: destinationURL
        )
    }

    func removeFile(_ url: URL) throws {
        try base.removeFile(url)
    }

    func removeDirectory(_ url: URL) throws {
        try base.removeDirectory(url)
    }
}

private struct R13UIQueueBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    let sourceBookmarkIsStale: Bool
    let outputBookmarkIsStale: Bool

    init(
        sourceBookmarkIsStale: Bool = false,
        outputBookmarkIsStale: Bool = false
    ) {
        self.sourceBookmarkIsStale = sourceBookmarkIsStale
        self.outputBookmarkIsStale = outputBookmarkIsStale
    }

    func makeBookmark(
        for url: URL,
        role _: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark {
        guard let path = String(data: bookmark, encoding: .utf8),
              path.hasPrefix("/") else {
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: role)
        }
        let isStale: Bool
        switch role {
        case .source:
            isStale = sourceBookmarkIsStale
        case .output:
            isStale = outputBookmarkIsStale
        }
        return MirmirWorkHistoryResolvedBookmark(
            url: URL(fileURLWithPath: path),
            isStale: isStale
        )
    }
}

private enum R13UIQueueProbeError: Error {
    case injectedFailure(String)
    case missingProfile(String)
}

private final class R13UIQueueMediaPipeline:
    MediaPipelineService,
    @unchecked Sendable {
    private let lock = NSLock()
    private let profilesByPath: [String: SourceProfile]
    private let failingProbePaths: Set<String>
    private var storedProbedURLs: [URL] = []

    init(
        profiles: [SourceProfile],
        failingProbePaths: Set<String> = []
    ) {
        profilesByPath = Dictionary(
            uniqueKeysWithValues: profiles.map {
                ($0.url.path, $0)
            }
        )
        self.failingProbePaths = failingProbePaths
    }

    var probedURLs: [URL] {
        lock.withLock { storedProbedURLs }
    }

    func probe(url: URL) async throws -> SourceProfile {
        lock.withLock {
            storedProbedURLs.append(url)
        }
        if failingProbePaths.contains(url.path) {
            throw R13UIQueueProbeError.injectedFailure(url.path)
        }
        guard let profile = profilesByPath[url.path] else {
            throw R13UIQueueProbeError.missingProfile(url.path)
        }
        return profile
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        try await NoopMediaPipelineService().beginSession(
            source: source,
            output: output
        )
    }

    func start() {}
    func stop() {}
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
    private var modeAvailabilityOverrides:
        [UpscaleMode: UpscalerEngineAvailability]

    init(
        recoverableJobs: [R13ResolvedRecoverableUpscaleJob] = [],
        rejectedEntryCount: Int = 0,
        discardFailureIDs: Set<String> = [],
        resolveFailures: [String: R13RestartJobError] = [:],
        discardGate: R13UIAsyncGate? = nil,
        modeAvailabilityOverrides:
            [UpscaleMode: UpscalerEngineAvailability] = [:]
    ) {
        storedRecoverableJobs = recoverableJobs
        storedRejectedEntryCount = rejectedEntryCount
        self.discardFailureIDs = discardFailureIDs
        self.resolveFailures = resolveFailures
        self.discardGate = discardGate
        self.modeAvailabilityOverrides = modeAvailabilityOverrides
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

    func releaseResolvedRecoveryAccessesForTesting() {
        lock.withLock {
            storedRecoverableJobs = []
        }
    }

    func suspendNextCatalog(using gate: R13UIAsyncGate) {
        lock.withLock {
            nextCatalogGate = gate
        }
    }

    func setAvailability(
        _ availability: UpscalerEngineAvailability,
        for mode: UpscaleMode
    ) {
        lock.withLock {
            modeAvailabilityOverrides[mode] = availability
        }
    }

    func availability(for mode: UpscaleMode) -> UpscalerEngineAvailability {
        lock.withLock {
            modeAvailabilityOverrides[mode]
                ?? R13ReleaseModePolicy.availability(for: mode)
        }
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
    let previewStream: AsyncStream<UpscalePreviewFrame>
    private let previewContinuation:
        AsyncStream<UpscalePreviewFrame>.Continuation
    private let lock = NSLock()
    private var state = State()

    init() {
        progressStream = AsyncStream { $0.finish() }
        var continuation:
            AsyncStream<UpscalePreviewFrame>.Continuation!
        previewStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        previewContinuation = continuation
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

    func completeSuccess(_ outputURL: URL) {
        complete(.success(outputURL))
    }

    func emitPreview(_ preview: UpscalePreviewFrame) {
        previewContinuation.yield(preview)
    }

    private func complete(_ result: Result<URL, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        previewContinuation.finish()
        waiter?.resume(with: result)
    }
}

private struct R13UIWorkHistoryBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    let sourceBookmarkIsStale: Bool
    let outputBookmarkIsStale: Bool

    init(
        sourceBookmarkIsStale: Bool = false,
        outputBookmarkIsStale: Bool = false
    ) {
        self.sourceBookmarkIsStale = sourceBookmarkIsStale
        self.outputBookmarkIsStale = outputBookmarkIsStale
    }

    func makeBookmark(
        for url: URL,
        role _: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark {
        guard let path = String(data: bookmark, encoding: .utf8),
              path.hasPrefix("/") else {
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: role)
        }
        let isStale: Bool
        switch role {
        case .source:
            isStale = sourceBookmarkIsStale
        case .output:
            isStale = outputBookmarkIsStale
        }
        return MirmirWorkHistoryResolvedBookmark(
            url: URL(fileURLWithPath: path),
            isStale: isStale
        )
    }
}

private struct R13UIOutputIdentityMeasurer:
    R13RestartSourceMeasuring {
    func measureSource(at _: URL) throws -> R13RestartSourceIdentity {
        try R13RestartSourceIdentity(
            sha256: String(repeating: "a", count: 64),
            byteCount: 1
        )
    }
}

private final class R13UISecurityScopeAudit: @unchecked Sendable {
    private struct State {
        var activeRoles: Set<R13BookmarkRole> = []
        var events: [String] = []
        var startCount = 0
        var stopCount = 0
    }

    private let state = NSLock()
    private var storage = State()

    var activeScopeCount: Int {
        state.withLock { storage.activeRoles.count }
    }

    var events: [String] {
        state.withLock { storage.events }
    }

    var startCount: Int {
        state.withLock { storage.startCount }
    }

    var stopCount: Int {
        state.withLock { storage.stopCount }
    }

    func recordStart(role: R13BookmarkRole) {
        state.withLock {
            storage.activeRoles.insert(role)
            storage.startCount += 1
            storage.events.append("start.\(role.rawValue)")
        }
    }

    func recordStop(role: R13BookmarkRole) {
        state.withLock {
            storage.activeRoles.remove(role)
            storage.stopCount += 1
            storage.events.append("stop.\(role.rawValue)")
        }
    }

    func recordProtectedOperation(_ event: String) -> Bool {
        state.withLock {
            storage.events.append(event)
            return storage.activeRoles == Set(R13BookmarkRole.allCases)
        }
    }
}

private struct R13UIScopeCheckingWorkHistoryBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    let scopeAudit: R13UISecurityScopeAudit

    func makeBookmark(
        for url: URL,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        guard scopeAudit.recordProtectedOperation(
            "bookmark.\(role.rawValue)"
        ) else {
            throw MirmirWorkHistoryBookmarkError.creationFailed(role: role)
        }
        return Data(url.path.utf8)
    }

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark {
        guard scopeAudit.recordProtectedOperation(
            "resolve.\(role.rawValue)"
        ) else {
            throw MirmirWorkHistoryBookmarkError.resolutionFailed(role: role)
        }
        guard let path = String(data: bookmark, encoding: .utf8) else {
            throw MirmirWorkHistoryBookmarkError.resolutionFailed(role: role)
        }
        return MirmirWorkHistoryResolvedBookmark(
            url: URL(fileURLWithPath: path),
            isStale: false
        )
    }
}

private struct R13UIScopeCheckingOutputIdentityMeasurer:
    R13RestartSourceMeasuring {
    let scopeAudit: R13UISecurityScopeAudit

    func measureSource(at _: URL) throws -> R13RestartSourceIdentity {
        guard scopeAudit.recordProtectedOperation("measure.output") else {
            throw R13RestartJobError.securityScopeDenied(
                role: .outputDirectory
            )
        }
        return try R13RestartSourceIdentity(
            sha256: String(repeating: "b", count: 64),
            byteCount: 1
        )
    }
}

private final class R13UIBlockingResolutionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false

    var isWaiting: Bool {
        condition.withLock { waiting }
    }

    func wait() {
        condition.lock()
        waiting = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

private struct R13UIBlockingWorkHistoryBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    let gate: R13UIBlockingResolutionGate

    func makeBookmark(
        for url: URL,
        role _: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark {
        gate.wait()
        guard let path = String(data: bookmark, encoding: .utf8),
              path.hasPrefix("/") else {
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: role)
        }
        return MirmirWorkHistoryResolvedBookmark(
            url: URL(fileURLWithPath: path),
            isStale: false
        )
    }
}

private final class R13UIResourceAccessAudit: @unchecked Sendable {
    private struct State {
        var startedURLs: [URL] = []
        var adoptedURLs: [URL] = []
        var stoppedURLs: [URL] = []
        var activeCounts: [URL: Int] = [:]
    }

    private let lock = NSLock()
    private var state = State()

    var startedURLs: [URL] {
        lock.withLock { state.startedURLs }
    }

    var stoppedURLs: [URL] {
        lock.withLock { state.stoppedURLs }
    }

    var adoptedURLs: [URL] {
        lock.withLock { state.adoptedURLs }
    }

    var activeURLs: [URL] {
        lock.withLock {
            state.activeCounts.keys.sorted { $0.path < $1.path }
        }
    }

    var activeScopeCount: Int {
        lock.withLock { state.activeCounts.values.reduce(0, +) }
    }

    func adoptSystemGrant(for url: URL) {
        let standardizedURL = url.standardizedFileURL
        lock.withLock {
            state.adoptedURLs.append(standardizedURL)
            state.activeCounts[standardizedURL, default: 0] += 1
        }
    }

    var resourceAccess: MirmirSecurityScopedResourceAccess {
        MirmirSecurityScopedResourceAccess(
            startAccessing: { [weak self] url in
                let standardizedURL = url.standardizedFileURL
                self?.lock.withLock {
                    self?.state.startedURLs.append(standardizedURL)
                    self?.state.activeCounts[standardizedURL, default: 0]
                        += 1
                }
                return true
            },
            stopAccessing: { [weak self] url in
                let standardizedURL = url.standardizedFileURL
                self?.lock.withLock {
                    self?.state.stoppedURLs.append(standardizedURL)
                    let activeCount =
                        self?.state.activeCounts[standardizedURL] ?? 0
                    if activeCount <= 1 {
                        self?.state.activeCounts.removeValue(
                            forKey: standardizedURL
                        )
                    } else {
                        self?.state.activeCounts[standardizedURL] =
                            activeCount - 1
                    }
                }
            },
            canCreateBookmark: { [weak self] url in
                let standardizedURL = url.standardizedFileURL
                return self?.lock.withLock {
                    (self?.state.activeCounts[standardizedURL] ?? 0) > 0
                } ?? false
            }
        )
    }
}

private final class R13UISystemSelectionGrantAudit:
    @unchecked Sendable {
    private struct State {
        var startedURLs: [URL] = []
        var stoppedURLs: [URL] = []
    }

    private let state = NSLock()
    private var storage = State()

    var startedURLs: [URL] {
        state.withLock { storage.startedURLs }
    }

    var stoppedURLs: [URL] {
        state.withLock { storage.stoppedURLs }
    }

    func adoptedLeases(
        for urls: [URL]
    ) -> [MirmirSecurityScopedSelectionLease] {
        let access = MirmirSecurityScopedResourceAccess(
            startAccessing: { [weak self] url in
                self?.state.withLock {
                    self?.storage.startedURLs.append(url)
                }
                return true
            },
            stopAccessing: { [weak self] url in
                self?.state.withLock {
                    self?.storage.stoppedURLs.append(url)
                }
            },
            canCreateBookmark: { _ in true }
        )
        return urls.map { url in
            MirmirSecurityScopedSelectionLease(
                url: url,
                access: access,
                acquisition: .adoptedSystemGrant
            )
        }
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

    func failProbe(_ error: Error) {
        let continuation = lock.withLock {
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: error)
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
