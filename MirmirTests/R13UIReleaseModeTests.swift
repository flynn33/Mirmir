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
                R13UIOutputIdentityMeasurer()
        )
        for _ in 0..<200 where viewModel.workHistoryRecords.isEmpty {
            await Task.yield()
        }

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
                R13UIOutputIdentityMeasurer()
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

    private func makePendingQueueViewModel(
        queue: MirmirPendingWorkQueue,
        media: R13UIQueueMediaPipeline,
        engine: R13UIModeEngineService = R13UIModeEngineService(),
        resolver: R13UIQueueBookmarkResolver =
            R13UIQueueBookmarkResolver()
    ) -> MirmirViewModel {
        MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: engine,
            modelAssets: NotRequiredModelAssetsService(),
            pendingWorkQueue: queue,
            workHistoryBookmarkResolver: resolver
        )
    }

    private func makePendingQueueSource(
        in directory: URL,
        name: String,
        hasAudio: Bool,
        videoFormat: MediaVideoFormat = .sdrBT709
    ) throws -> SourceProfile {
        let url = directory.appendingPathComponent(name)
        try Data([0x01, 0x02, 0x03]).write(to: url)
        return SourceProfile(
            url: url,
            resolution: .p1080,
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
