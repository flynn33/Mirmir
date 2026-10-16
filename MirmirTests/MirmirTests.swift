import AppKit
import CoreMedia
import XCTest
@testable import Mirmir

final class MirmirTests: XCTestCase {
    @MainActor
    func testWindowMenuReopensClosedMainWindowWithoutCreatingDuplicates()
        async throws {
        let application = NSApplication.shared
        func mainWindows() -> [NSWindow] {
            application.windows.filter {
                $0.title == "Mirmir" && $0.canBecomeMain
                    && ($0.isVisible || $0.isMiniaturized)
            }
        }
        func waitForWindowState(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return condition()
        }
        func showMainWindow() throws {
            let windowMenu = try XCTUnwrap(application.windowsMenu)
            windowMenu.update()
            let showItem = try XCTUnwrap(windowMenu.items.first {
                $0.title == "Show Main Window"
            })
            XCTAssertTrue(showItem.isEnabled, "Reopening must remain available.")
            XCTAssertEqual(showItem.keyEquivalent, "0")
            XCTAssertTrue(showItem.keyEquivalentModifierMask.contains(.command))
            windowMenu.performActionForItem(at: windowMenu.index(of: showItem))
        }
        func windowState() -> String {
            let windows = application.windows.map { window in
                "number=\(window.windowNumber),title=\(window.title),"
                    + "visible=\(window.isVisible),"
                    + "miniaturized=\(window.isMiniaturized),"
                    + "key=\(window.isKeyWindow),"
                    + "canBecomeKey=\(window.canBecomeKey)"
            }.joined(separator: "; ")
            return "active=\(application.isActive),"
                + "keyWindow=\(application.keyWindow?.windowNumber.description ?? "nil"),"
                + "frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"),"
                + "windows=[\(windows)]"
        }

        application.activate()
        let launched = try await waitForWindowState {
            mainWindows().count == 1
        }
        XCTAssertTrue(launched, "The hosted app must present its main window.")
        let initialWindow = try XCTUnwrap(mainWindows().first)
        // macOS may refuse synthetic activation of a background test host.
        // Window lifecycle checks still run when keyboard focus is unavailable.
        _ = try await waitForWindowState {
            application.isActive
        }
        let verifiesKeyboardFocus = application.isActive
        if !verifiesKeyboardFocus {
            XCTContext.runActivity(
                named: "Keyboard focus not exercised: test host remained inactive"
            ) { activity in
                let attachment = XCTAttachment(string: windowState())
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        func verifyKeyboardFocus(_ window: NSWindow) async throws {
            guard verifiesKeyboardFocus else { return }
            let focused = try await waitForWindowState {
                application.isActive && window.isKeyWindow
            }
            XCTAssertTrue(
                focused,
                "An active hosted app must focus its main window. \(windowState())"
            )
        }
        try await verifyKeyboardFocus(initialWindow)

        initialWindow.performClose(nil)
        let closed = try await waitForWindowState {
            mainWindows().isEmpty
        }
        XCTAssertTrue(closed, "Closing the main window must dismiss it.")

        try showMainWindow()
        let reopened = try await waitForWindowState {
            mainWindows().count == 1
        }
        XCTAssertTrue(
            reopened,
            "Window > Show Main Window must reopen it. \(windowState())"
        )
        let reopenedWindow = try XCTUnwrap(mainWindows().first)
        try await verifyKeyboardFocus(reopenedWindow)

        for _ in 0..<2 {
            try showMainWindow()
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(mainWindows().count, 1)
            XCTAssertTrue(mainWindows().first === reopenedWindow)
            try await verifyKeyboardFocus(reopenedWindow)
        }

        reopenedWindow.miniaturize(nil)
        let minimized = try await waitForWindowState {
            reopenedWindow.isMiniaturized
        }
        XCTAssertTrue(minimized)
        try showMainWindow()
        let restored = try await waitForWindowState {
            reopenedWindow.isVisible && !reopenedWindow.isMiniaturized
        }
        XCTAssertTrue(
            restored,
            "Showing a minimized window must restore it. \(windowState())"
        )
        XCTAssertEqual(mainWindows().count, 1)
        XCTAssertTrue(mainWindows().first === reopenedWindow)
        try await verifyKeyboardFocus(reopenedWindow)
    }

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

    func testPrimaryNavigationSeparatesCompareFromUpscale() {
        XCTAssertTrue(MirmirProductDestination.primary.contains(.upscale))
        XCTAssertTrue(MirmirProductDestination.primary.contains(.compare))
        XCTAssertTrue(
            MirmirProductDestination.utilities.contains(.diagnostics)
        )
        XCTAssertEqual(MirmirProductDestination.upscale.title, "Upscale")
        XCTAssertEqual(MirmirProductDestination.compare.title, "Compare")
        XCTAssertEqual(
            MirmirProductDestination.diagnostics.title,
            "Diagnostics"
        )
    }

    @MainActor
    func testIdleWorkspaceTelemetryUpdatesTheDashboardWithoutJournaling()
        async throws {
        let store = MirmirDiagnosticStore(inMemoryWith: .production)
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            diagnosticStore: store
        )
        let telemetry = MirmirWorkspaceRootView.makeDashboardTelemetry(
            for: viewModel,
            sampleProvider: {
                MirmirProcessTelemetryCounters(
                    timestampTicks: 1_000,
                    userNanoseconds: 10,
                    systemNanoseconds: 5,
                    residentBytes: 4_096,
                    physicalFootprintBytes: 8_192,
                    diskReadBytes: 100,
                    diskWrittenBytes: 200
                )
            }
        )

        telemetry.refresh()
        let snapshot = try await store.snapshot()

        XCTAssertEqual(telemetry.snapshot?.physicalFootprintBytes, 8_192)
        XCTAssertFalse(snapshot.records.contains {
            $0.event.operation.rawValue == "sample_process"
                && $0.event.code.rawValue == "process_telemetry_sample"
        })
    }

    func testUpscaleCompositionCannotMountCompletedComparisonPlayer()
        throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let activeUpscale = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Mirmir/App/MirmirUpscaleWorkspace.swift"
            ),
            encoding: .utf8
        )
        let moduleUpscale = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        let comparison = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Mirmir/Modules/UI/Views/"
                    + "MirmirCompletedComparisonPlaybackView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(
            activeUpscale.contains("MirmirCompletedComparisonPlaybackView")
        )
        XCTAssertFalse(
            moduleUpscale.contains("MirmirCompletedComparisonPlaybackView")
        )
        XCTAssertFalse(activeUpscale.contains("Before / After Viewer"))
        XCTAssertTrue(
            comparison.contains("MirmirCompletedComparisonPlaybackView(")
        )
        XCTAssertTrue(comparison.contains("Choose Original Movie"))
        XCTAssertTrue(comparison.contains("Choose Upscaled Movie"))
    }

    @MainActor
    func testComparisonDefaultsToUpscaledAudioOnly() {
        let controller = MirmirSynchronizedPlaybackController()

        XCTAssertTrue(controller.sourcePlayer.isMuted)
        XCTAssertFalse(controller.outputPlayer.isMuted)
    }

    func testComparisonTimelineRepresentsLoadingReadyEndedAndFailure() {
        var timeline = MirmirSynchronizedPlaybackTimeline()
        XCTAssertEqual(timeline.loadState, .idle)

        timeline.beginLoading()
        XCTAssertEqual(timeline.loadState, .loading)
        XCTAssertTrue(
            timeline.markReady(sourceDuration: 12, outputDuration: 10)
        )
        XCTAssertEqual(timeline.loadState, .ready)
        XCTAssertEqual(timeline.duration, 10)

        timeline.scrub(to: 10)
        XCTAssertTrue(timeline.hasEnded)

        timeline.markFailed("Unreadable upscaled movie")
        XCTAssertEqual(
            timeline.loadState,
            .failed("Unreadable upscaled movie")
        )
    }

    func testComparisonTimelinePlayPauseScrubEndAndReplay() throws {
        var timeline = MirmirSynchronizedPlaybackTimeline()
        XCTAssertTrue(
            timeline.markReady(sourceDuration: 12, outputDuration: 10)
        )

        timeline.scrub(to: 2)
        XCTAssertEqual(timeline.requestPlay(), 2)
        XCTAssertTrue(timeline.isPlaying)
        timeline.recordPlaybackTime(3)
        timeline.pause()
        XCTAssertFalse(timeline.isPlaying)
        XCTAssertEqual(timeline.currentTime, 3)

        XCTAssertEqual(timeline.requestPlay(), 3)
        timeline.beginScrubbing()
        XCTAssertTrue(timeline.isScrubbing)
        XCTAssertFalse(timeline.isPlaying)
        timeline.scrub(to: 6)
        let resumed = try XCTUnwrap(timeline.finishScrubbing())
        XCTAssertEqual(resumed.time, 6)
        XCTAssertTrue(resumed.resumePlayback)
        XCTAssertTrue(timeline.isPlaying)

        timeline.beginScrubbing()
        timeline.scrub(to: 10)
        let endedScrub = try XCTUnwrap(timeline.finishScrubbing())
        XCTAssertEqual(endedScrub.time, 10)
        XCTAssertFalse(endedScrub.resumePlayback)
        XCTAssertTrue(timeline.hasEnded)
        XCTAssertFalse(timeline.isPlaying)

        XCTAssertEqual(timeline.requestPlay(), 0)
        XCTAssertFalse(timeline.hasEnded)
        XCTAssertTrue(timeline.isPlaying)
        timeline.recordPlaybackTime(9.9995)
        XCTAssertEqual(timeline.currentTime, 10)
        XCTAssertTrue(timeline.hasEnded)
        XCTAssertFalse(timeline.isPlaying)

        XCTAssertEqual(timeline.requestPlay(), 0)
        XCTAssertFalse(timeline.hasEnded)
        XCTAssertTrue(timeline.isPlaying)
    }

    @MainActor
    func testWorkflowLaunchPublishesSnapshotsAndContainsRecoveryErrors() async throws {
        let generatedAt = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: 1_000
        )
        let jobID = try WorkflowJobID("contained-job")
        let queue = WorkflowApplicationQueueSnapshotV4(
            generatedAt: generatedAt,
            items: []
        )
        let containedRecovery = WorkflowLaunchRecoverySnapshotV4(
            generatedAt: generatedAt,
            items: [
                WorkflowLaunchRecoveryItemV4(
                    jobID: jobID,
                    observedLifecycle: .running,
                    presentedLifecycle: .contained,
                    status: .contained,
                    resourceSummaries: [],
                    partialDispositionCounts: [:],
                    containedFailureCount: 1,
                    reducerEvents: [],
                    resumable: false
                ),
            ]
        )
        let cleanRecovery = WorkflowLaunchRecoverySnapshotV4(
            generatedAt: generatedAt,
            items: []
        )
        let controller = StubWorkflowApplicationControllerV4(
            launches: [
                WorkflowApplicationLaunchSnapshotV4(
                    queue: queue,
                    recovery: containedRecovery
                ),
                WorkflowApplicationLaunchSnapshotV4(
                    queue: queue,
                    recovery: cleanRecovery
                ),
            ]
        )
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            workflowController: controller
        )

        await viewModel.initializeWorkflow()

        XCTAssertEqual(viewModel.workflowQueueSnapshot, queue)
        XCTAssertEqual(viewModel.workflowRecoverySnapshot, containedRecovery)
        XCTAssertEqual(
            viewModel.workflowErrorMessage,
            "Launch recovery contained durable workflow errors for: contained-job."
        )

        await viewModel.initializeWorkflow()

        XCTAssertEqual(viewModel.workflowRecoverySnapshot, cleanRecovery)
        XCTAssertNil(viewModel.workflowErrorMessage)
        XCTAssertFalse(viewModel.isInitializingWorkflow)
    }

    @MainActor
    func testAutomaticWorkflowInitializationDoesNotRelaunchWhenWindowReopens()
        async {
        let generatedAt = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: 1_000
        )
        let launch = WorkflowApplicationLaunchSnapshotV4(
            queue: WorkflowApplicationQueueSnapshotV4(
                generatedAt: generatedAt,
                items: []
            ),
            recovery: WorkflowLaunchRecoverySnapshotV4(
                generatedAt: generatedAt,
                items: []
            )
        )
        let controller = StubWorkflowApplicationControllerV4(
            launches: [launch]
        )
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            workflowController: controller,
            diagnosticStore: MirmirDiagnosticStore(
                inMemoryWith: .production
            )
        )

        await viewModel.initializeWorkflowIfNeeded()
        await viewModel.initializeWorkflowIfNeeded()

        let launchCount = await controller.launchCount
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(viewModel.workflowQueueSnapshot, launch.queue)
        XCTAssertEqual(viewModel.workflowRecoverySnapshot, launch.recovery)
        XCTAssertNil(viewModel.workflowErrorMessage)
        XCTAssertFalse(viewModel.isInitializingWorkflow)
    }

    @MainActor
    func testAutomaticWorkflowInitializationRetriesAfterInitialFailure()
        async {
        let generatedAt = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: 1_000
        )
        let launch = WorkflowApplicationLaunchSnapshotV4(
            queue: WorkflowApplicationQueueSnapshotV4(
                generatedAt: generatedAt,
                items: []
            ),
            recovery: WorkflowLaunchRecoverySnapshotV4(
                generatedAt: generatedAt,
                items: []
            )
        )
        let controller = StubWorkflowApplicationControllerV4(
            launches: [launch],
            failureMessage: "durable store unavailable"
        )
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            workflowController: controller,
            diagnosticStore: MirmirDiagnosticStore(
                inMemoryWith: .production
            )
        )

        await viewModel.initializeWorkflowIfNeeded()

        XCTAssertNil(viewModel.workflowQueueSnapshot)
        XCTAssertEqual(
            viewModel.workflowErrorMessage,
            "durable store unavailable"
        )
        await controller.setLaunchFailure(nil)

        await viewModel.initializeWorkflowIfNeeded()
        await viewModel.initializeWorkflowIfNeeded()

        let launchCount = await controller.launchCount
        XCTAssertEqual(launchCount, 2)
        XCTAssertEqual(viewModel.workflowQueueSnapshot, launch.queue)
        XCTAssertEqual(viewModel.workflowRecoverySnapshot, launch.recovery)
        XCTAssertNil(viewModel.workflowErrorMessage)
        XCTAssertFalse(viewModel.isInitializingWorkflow)
    }

    @MainActor
    func testWorkflowLaunchFailureIsContainedInViewModel() async throws {
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let controller = StubWorkflowApplicationControllerV4(
            launches: [],
            failureMessage: "durable store unavailable"
        )
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            workflowController: controller,
            diagnosticStore: diagnosticStore
        )

        await viewModel.initializeWorkflow()

        XCTAssertEqual(
            viewModel.workflowErrorMessage,
            "durable store unavailable"
        )
        XCTAssertNil(viewModel.workflowQueueSnapshot)
        XCTAssertNil(viewModel.workflowRecoverySnapshot)
        XCTAssertFalse(viewModel.isInitializingWorkflow)
        let snapshot = try await diagnosticStore.snapshot()
        let failure = try XCTUnwrap(snapshot.records.first {
            $0.event.operation.rawValue == "initialize_workflow"
        })
        XCTAssertEqual(failure.event.code.rawValue, "workflow_launch_failed")
        XCTAssertNotNil(failure.event.error)
    }

    @MainActor
    func testSourceProbeFailureReachesInjectedDiagnosticStore()
        async throws {
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let viewModel = MirmirViewModel(
            videoProbe: FailingVideoProbe(),
            workflowController: StubWorkflowApplicationControllerV4(
                launches: []
            ),
            diagnosticStore: diagnosticStore
        )

        viewModel.selectVideo(URL(fileURLWithPath: "/tmp/failing.mov"))
        await viewModel.waitForCurrentProbe()

        let snapshot = try await diagnosticStore.snapshot()
        let failure = try XCTUnwrap(snapshot.records.first {
            $0.event.operation.rawValue == "probe_source"
        })
        XCTAssertEqual(failure.event.code.rawValue, "source_probe_failed")
        XCTAssertEqual(
            failure.event.error?.frames.first?.domain,
            "com.mirmir.tests.video-probe"
        )
        XCTAssertEqual(failure.event.error?.frames.first?.code, 73)
    }

    @MainActor
    func testCacheStoreConstructionFailureReachesInjectedDiagnosticStore()
        async throws {
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            cacheLocationStoreFactory: { _ in
                throw NSError(
                    domain: "com.mirmir.tests.cache-construction",
                    code: 81
                )
            },
            diagnosticStore: diagnosticStore
        )
        await viewModel.deleteCachedJob(
            try WorkflowJobID("unavailable-cache-job")
        )

        let snapshot = try await diagnosticStore.snapshot()
        let failure = try XCTUnwrap(snapshot.records.first {
            $0.event.operation.rawValue == "initialize_cache_store"
        })
        XCTAssertEqual(
            failure.event.code.rawValue,
            "cache_store_initialization_failed"
        )
        XCTAssertEqual(
            failure.event.error?.frames.first?.domain,
            "com.mirmir.tests.cache-construction"
        )
        XCTAssertNotNil(viewModel.cacheLocationErrorMessage)
        XCTAssertNotNil(viewModel.workflowErrorMessage)
        XCTAssertTrue(snapshot.records.contains {
            $0.event.operation.rawValue == "delete_cached_job"
                && $0.event.code.rawValue
                    == "workflow_controller_unavailable"
        })
    }

    @MainActor
    func testCacheAndResumeFailuresReachInjectedDiagnosticStore()
        async throws {
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let controller = StubWorkflowApplicationControllerV4(launches: [])
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            workflowController: controller,
            diagnosticStore: diagnosticStore
        )
        let jobID = try WorkflowJobID("diagnostic-job")

        await viewModel.deleteCachedJob(jobID)
        viewModel.resumeWorkflowJob(jobID)
        await viewModel.waitForProcessing()

        let snapshot = try await diagnosticStore.snapshot()
        let cacheFailure = try XCTUnwrap(snapshot.records.first {
            $0.event.operation.rawValue == "delete_cached_job"
        })
        let resumeFailure = try XCTUnwrap(snapshot.records.first {
            $0.event.operation.rawValue == "resume_workflow"
        })
        XCTAssertEqual(
            cacheFailure.event.code.rawValue,
            "cache_job_delete_failed"
        )
        XCTAssertEqual(
            resumeFailure.event.code.rawValue,
            "workflow_resume_failed"
        )
        XCTAssertNotNil(cacheFailure.event.error)
        XCTAssertNotNil(resumeFailure.event.error)
    }

    @MainActor
    func testCancelledWorkflowResumeDoesNotReportFailure() async throws {
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let generatedAt = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: 1_000
        )
        let controller = StubWorkflowApplicationControllerV4(
            launches: [
                WorkflowApplicationLaunchSnapshotV4(
                    queue: WorkflowApplicationQueueSnapshotV4(
                        generatedAt: generatedAt,
                        items: []
                    ),
                    recovery: WorkflowLaunchRecoverySnapshotV4(
                        generatedAt: generatedAt,
                        items: []
                    )
                )
            ],
            resumeMirmirError: .cancelled
        )
        let viewModel = MirmirViewModel(
            videoProbe: WaitingVideoProbe(),
            workflowController: controller,
            diagnosticStore: diagnosticStore
        )

        viewModel.resumeWorkflowJob(try WorkflowJobID("cancelled-job"))
        await viewModel.waitForProcessing()

        let snapshot = try await diagnosticStore.snapshot()
        XCTAssertNil(viewModel.workflowErrorMessage)
        XCTAssertFalse(viewModel.isWorkflowProcessing)
        XCTAssertFalse(snapshot.records.contains {
            $0.event.code.rawValue == "workflow_resume_failed"
        })
    }
}

final class MirmirDashboardTelemetryTests: XCTestCase {
    func testPerformanceFieldsKeepMeasuredPhasesSeparateFromEngineDuration()
        throws {
        let fields = try MirmirDiagnosticRecorder.performanceFields(
            elapsedNanoseconds: 60_000_000_000,
            processingDurationSeconds: 10.25,
            completedInputFrames: 120,
            sourceAuthenticationNanoseconds: 7_000_000_000,
            segmentProcessingNanoseconds: 11_000_000_000,
            checkpointCommitNanoseconds: 3_000_000_000
        )
        let values = Dictionary(uniqueKeysWithValues: fields.map {
            ($0.key.rawValue, $0.value.displayValue)
        })
        XCTAssertEqual(values["run_elapsed_ms"], "60000")
        XCTAssertEqual(values["processing_duration_ms"], "10250")
        XCTAssertEqual(values["source_authentication_ms"], "7000")
        XCTAssertEqual(values["segment_processing_ms"], "11000")
        XCTAssertEqual(values["checkpoint_commit_ms"], "3000")
        XCTAssertEqual(values["frames_per_second_hundredths"], "200")
    }

    func testMachResourceUsageTicksConvertBeforeCPUCalculation() throws {
        let timebase = MirmirMachTimebase(numerator: 125, denominator: 3)
        let previous = counters(timestamp: 12_000_000)
        let current = counters(
            timestamp: 24_000_000,
            user: timebase.nanoseconds(forMachTicks: 12_000_000)
        )

        XCTAssertEqual(current.userNanoseconds, 500_000_000)
        let snapshot = MirmirTelemetryCalculator.snapshot(
            previous: previous, current: current, timebase: timebase
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.processCPUPercent), 100,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testTelemetryJournalSamplesOnlyActiveWorkAtMinuteIntervals()
        async throws {
        let store = MirmirDiagnosticStore(inMemoryWith: .production)
        let samples = MirmirTelemetryTestSequence()
        var workActive = false
        let telemetry = MirmirDashboardTelemetry(
            sampleProvider: { samples.next() },
            timebase: MirmirMachTimebase(numerator: 1, denominator: 1),
            diagnosticRecorder: MirmirDiagnosticRecorder(store: store),
            isWorkActive: { workActive },
            diagnosticUptime: { samples.uptime() }
        )

        telemetry.refresh()
        workActive = true
        telemetry.refresh()
        for _ in 0..<59 { telemetry.refresh() }
        var records = try await store.snapshot().records.filter {
            $0.event.code.rawValue == "process_telemetry_sample"
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].event.fields.contains {
            $0.key.rawValue == "process_cpu_percent_hundredths"
        })
        XCTAssertFalse(records[0].event.fields.contains {
            $0.key.rawValue == "metal_device_name"
        })

        telemetry.refresh()
        workActive = false
        for _ in 0..<70 { telemetry.refresh() }
        records = try await store.snapshot().records.filter {
            $0.event.code.rawValue == "process_telemetry_sample"
        }
        XCTAssertEqual(records.count, 2)
        workActive = true
        telemetry.refresh()
        records = try await store.snapshot().records.filter {
            $0.event.code.rawValue == "process_telemetry_sample"
        }
        XCTAssertEqual(records.count, 3)
    }

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

private final class MirmirTelemetryTestSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleOrdinal: UInt64 = 0

    func next() -> MirmirProcessTelemetryCounters {
        lock.withLock {
            sampleOrdinal += 1
            return MirmirProcessTelemetryCounters(
                timestampTicks: sampleOrdinal * 1_000_000_000,
                userNanoseconds: sampleOrdinal * 250_000_000,
                systemNanoseconds: 0,
                residentBytes: 4_096,
                physicalFootprintBytes: 8_192,
                diskReadBytes: sampleOrdinal * 100,
                diskWrittenBytes: sampleOrdinal * 200
            )
        }
    }

    func uptime() -> UInt64 {
        lock.withLock { sampleOrdinal * 1_000_000_000 }
    }
}

private struct WaitingVideoProbe: VideoProbing {
    func probe(url: URL) async throws -> VideoInfo {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}

private struct FailingVideoProbe: VideoProbing {
    func probe(url _: URL) async throws -> VideoInfo {
        throw NSError(
            domain: "com.mirmir.tests.video-probe",
            code: 73
        )
    }
}

private actor StubWorkflowApplicationControllerV4:
    WorkflowApplicationControllingV4
{
    private struct LaunchFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private var launches: [WorkflowApplicationLaunchSnapshotV4]
    private var failureMessage: String?
    private let resumeMirmirError: MirmirError?
    private(set) var launchCount = 0

    init(
        launches: [WorkflowApplicationLaunchSnapshotV4],
        failureMessage: String? = nil,
        resumeMirmirError: MirmirError? = nil
    ) {
        self.launches = launches
        self.failureMessage = failureMessage
        self.resumeMirmirError = resumeMirmirError
    }

    func installObserver(_ observer: WorkflowApplicationObserverV4) async {}

    func setLaunchFailure(_ message: String?) {
        failureMessage = message
    }

    func launch() async throws -> WorkflowApplicationLaunchSnapshotV4 {
        launchCount += 1
        if let failureMessage {
            throw LaunchFailure(message: failureMessage)
        }
        guard !launches.isEmpty else {
            throw LaunchFailure(message: "Unexpected workflow launch.")
        }
        return launches.removeFirst()
    }

    func submit(
        request _: UpscaleRequest,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot _: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        throw LaunchFailure(message: "Unexpected workflow submission.")
    }

    func enqueue(
        request _: UpscaleRequest,
        priority _: Int32
    ) async throws -> WorkflowApplicationEnqueueReceiptV4 {
        throw LaunchFailure(message: "Unexpected workflow enqueue.")
    }

    func requestPause() async throws {
        throw LaunchFailure(message: "Unexpected workflow pause.")
    }

    func cancelActive() async throws {
        throw LaunchFailure(message: "Unexpected workflow cancellation.")
    }

    func resume(
        jobID _: WorkflowJobID,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void,
        snapshot _: @escaping @Sendable (
            WorkflowApplicationQueueSnapshotV4
        ) -> Void
    ) async throws -> WorkflowApplicationRunOutcomeV4 {
        if let resumeMirmirError {
            throw resumeMirmirError
        }
        throw LaunchFailure(message: "Unexpected workflow resume.")
    }

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4 {
        guard let launch = launches.first else {
            throw LaunchFailure(message: "Unexpected workflow snapshot.")
        }
        return launch.queue
    }

    func setPriority(jobID _: WorkflowJobID, value _: Int32) async throws {
        throw LaunchFailure(message: "Unexpected workflow priority change.")
    }

    func move(
        jobID _: WorkflowJobID,
        direction _: WorkflowApplicationQueueMoveV4
    ) async throws {
        throw LaunchFailure(message: "Unexpected workflow reorder.")
    }

    func deleteCachedJob(jobID _: WorkflowJobID) async throws {
        throw LaunchFailure(message: "Unexpected cached-job deletion.")
    }

    func deleteCachedJobs(
        selection _: WorkflowCachedJobSelectionV4
    ) async throws -> Int {
        throw LaunchFailure(message: "Unexpected cached-job deletion.")
    }

    func clearCache() async throws -> WorkflowCacheClearResultV4 {
        throw LaunchFailure(message: "Unexpected cache clearing.")
    }
}
