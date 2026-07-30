import Foundation
@testable import Mirmir
import XCTest

@MainActor
final class MirmirUIWorkflowTests: XCTestCase {

    func test_debugDeploymentDefaultsToProductShellWithoutDeveloperEnvironment() {
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: [:]), .production)
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: ["MIRMIR_DEVELOPER_WORKSPACE": "0"]), .production)
    }

    func test_developerWorkspaceRequiresExplicitEnvironmentOptIn() {
        #if DEBUG
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: ["MIRMIR_DEVELOPER_WORKSPACE": "1"]), .development)
        #else
        XCTAssertEqual(MirmirDeploymentMode.resolve(environment: ["MIRMIR_DEVELOPER_WORKSPACE": "1"]), .production)
        #endif
    }

    func test_canStartRequiresValidReadyWorkflowState() {
        let viewModel = makeViewModel()
        let sourceProfile = makeSourceProfile()
        viewModel.sourceProfile = sourceProfile
        viewModel.targetResolution = .p2160
        viewModel.state = .ready

        XCTAssertFalse(viewModel.canStart)
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)
        ))
        XCTAssertTrue(viewModel.canStart)

        viewModel.targetResolution = .p1080
        XCTAssertFalse(viewModel.canStart)

        viewModel.targetResolution = .p2160
        viewModel.state = .running
        XCTAssertFalse(viewModel.canStart)
    }

    func test_runningStateReportsProgressWithoutClaimingDuplicateSubmission() {
        let viewModel = makeViewModel()

        viewModel.state = .running

        XCTAssertEqual(
            viewModel.canStartFailureReason,
            "Upscale in progress."
        )
        XCTAssertFalse(viewModel.canStart)
    }

    func test_unavailableEngineDisablesStartAndExplainsRoadmapTransition() {
        let engine = RecordingUnavailableEngineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let sourceProfile = makeSourceProfile()

        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            UnavailableUpscalerEngineService.roadmapTransitionReason
        )
        XCTAssertEqual(viewModel.engineReadinessText, "Selected Mode Unavailable")
        XCTAssertEqual(viewModel.engineSelectionText, "No available release mode")

        viewModel.sourceProfile = sourceProfile
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)
        ))

        viewModel.startUpscale()

        XCTAssertEqual(engine.submitCount, 0)
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            UnavailableUpscalerEngineService.roadmapTransitionReason
        )
    }

    func test_defaultOutputFilenameUsesTargetResolution() {
        let viewModel = makeViewModel()
        let sourceProfile = makeSourceProfile(url: URL(fileURLWithPath: "/tmp/clip.mov"))

        let outputURL = viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)

        XCTAssertEqual(outputURL.lastPathComponent, "clip_mirmir_2160p.mp4")
    }

    func test_sourceAndOutputMustBeDifferentFiles() {
        let source = URL(fileURLWithPath: "/tmp/source.mov")

        XCTAssertTrue(MirmirViewModel.urlsReferToSameFile(source, source))
        XCTAssertFalse(
            MirmirViewModel.urlsReferToSameFile(
                source,
                URL(fileURLWithPath: "/tmp/source_mirmir_2160p.mp4")
            )
        )
    }

    func test_fileIdentityDetectsSymlinkAndHardLinkAliases() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.mov")
        let symlink = directory.appendingPathComponent("source-symlink.mov")
        let hardLink = directory.appendingPathComponent("source-hardlink.mov")
        try Data("source".utf8).write(to: source)
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: source)
        try fileManager.linkItem(at: source, to: hardLink)

        XCTAssertTrue(MirmirViewModel.urlsReferToSameFile(source, symlink))
        XCTAssertTrue(MirmirViewModel.urlsReferToSameFile(source, hardLink))
    }

    func test_sourceCannotBeAcceptedAsOutput() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
        let viewModel = makeViewModel()
        viewModel.sourceProfile = makeSourceProfile(url: sourceURL)
        viewModel.targetResolution = .p2160
        viewModel.state = .ready

        XCTAssertFalse(viewModel.acceptOutputURLSelectedByUser(sourceURL))
        XCTAssertNil(viewModel.outputURL)
        XCTAssertEqual(
            viewModel.canStartFailureReason,
            MirmirViewModel.sourceOutputConflictMessage
        )
    }

    func test_loadingSourceRequiresExplicitOutputSelection() async {
        let viewModel = makeViewModel()

        viewModel.loadSource(url: URL(fileURLWithPath: "/tmp/source.mov"))
        for _ in 0..<100 where viewModel.state == .probing {
            await Task.yield()
        }

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertNil(viewModel.outputURL)
        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(viewModel.canStartFailureReason, "Choose an output location.")
    }

    func test_loadingSourceIsIgnoredWhileAJobIsRunning() async {
        let media = CountingMediaPipelineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: media,
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService()
        )
        viewModel.state = .running

        viewModel.loadSource(url: URL(fileURLWithPath: "/tmp/replacement.mov"))
        await Task.yield()

        XCTAssertEqual(media.probeCount, 0)
        XCTAssertEqual(viewModel.state, .running)
    }

    func test_rawCancellationKeepsWorkflowRunningUntilHandleTerminates() async throws {
        let engine = DelayedCancellationEngineService()
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let source = makeSourceProfile()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(for: source, target: .p2160)
        ))

        viewModel.startUpscale()
        let handle = try XCTUnwrap(engine.latestHandle)
        XCTAssertEqual(viewModel.state, .running)

        viewModel.cancelUpscale()
        XCTAssertTrue(handle.cancelRequested)
        XCTAssertEqual(viewModel.state, .running)
        XCTAssertFalse(viewModel.canStart)

        handle.completeCancellation()
        for _ in 0..<100 where viewModel.state == .running {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.state, .ready)
    }

    func test_dismissTerminalJobClearsFailedAndFinishedWorkflowState() {
        for terminalState in [
            MirmirViewModel.JobState.failed("injected failure"),
            .finished(URL(fileURLWithPath: "/tmp/finished.mp4"))
        ] {
            let viewModel = makeViewModel()
            let source = makeSourceProfile()
            viewModel.sourceProfile = source
            viewModel.outputURL = viewModel.defaultOutputURL(
                for: source,
                target: .p2160
            )
            viewModel.progress = UpscaleProgress(
                framesProcessed: 1,
                totalFrames: 2,
                throughputFPS: 1,
                etaSeconds: 1
            )
            viewModel.state = terminalState

            viewModel.dismissTerminalJob()

            XCTAssertEqual(viewModel.state, .idle)
            XCTAssertNil(viewModel.sourceProfile)
            XCTAssertNil(viewModel.outputURL)
            XCTAssertNil(viewModel.progress)
        }
    }

    func test_inputAdmissionDefersFormatSupportToMediaProbe() {
        for fileExtension in [
            "mp4", "mov", "mkv", "webm", "mxf", "unknown"
        ] {
            let url = URL(
                fileURLWithPath: "/tmp/source.\(fileExtension)"
            )
            XCTAssertTrue(
                MirmirViewModel.supportsVideoFile(url),
                fileExtension
            )
        }
        XCTAssertFalse(
            MirmirViewModel.supportsVideoFile(
                URL(string: "https://example.com/source.mp4")!
            )
        )
    }

    func test_targetPolicyPreservesQualifiedRoutesAndAdaptsOddGeometry() {
        XCTAssertEqual(
            MirmirViewModel.targets(for: .p720),
            [.p1080]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(for: .p1080),
            [.p2160]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(
                for: VideoResolution(width: 728, height: 410)
            ),
            [VideoResolution(width: 1_278, height: 720)]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(
                for: VideoResolution(width: 854, height: 480)
            ),
            [VideoResolution(width: 1_282, height: 720)]
        )
        XCTAssertEqual(
            MirmirViewModel.targets(for: .p1440),
            [.p2160]
        )
        XCTAssertTrue(
            MirmirViewModel.targets(for: .p2160).isEmpty
        )
    }

    func test_nonFileSourceReportsVisibleError() {
        let viewModel = makeViewModel()

        viewModel.loadSource(
            url: URL(string: "https://example.com/source.mp4")!
        )

        XCTAssertEqual(
            viewModel.state,
            .failed(MirmirViewModel.unsupportedFileMessage)
        )
    }

    func test_probeFailureIsPersistedInInjectedDiagnosticStore() async throws {
        let store = MirmirDiagnosticStore(inMemoryWith: .production)
        let privateSourceURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/"
                + "token-sk_test_SENTINEL/source.mov"
        )
        let viewModel = MirmirViewModel(
            mediaPipeline: FailingProbeMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService(),
            diagnostics: store
        )

        viewModel.loadSource(url: privateSourceURL)

        var failureRecord: MirmirDiagnosticRecord?
        for _ in 0..<200 where failureRecord == nil {
            let snapshot = try await store.snapshot()
            failureRecord = snapshot.records.first {
                $0.event.code.rawValue == "source_probe_failed"
            }
            if failureRecord == nil {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        let persistedFailure = try XCTUnwrap(failureRecord)
        let fields = Dictionary(
            uniqueKeysWithValues: persistedFailure.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(persistedFailure.event.severity, .error)
        XCTAssertEqual(
            persistedFailure.event.operation.rawValue,
            "source_probe"
        )
        XCTAssertNotNil(persistedFailure.event.error)
        XCTAssertTrue(
            persistedFailure.event.error?.frames.contains {
                $0.domain == "NSPOSIXErrorDomain" && $0.code == 5
            } == true
        )
        XCTAssertEqual(fields["failure_category"], "reader_creation_failed")
        XCTAssertEqual(
            fields["source_video"],
            "source_video:"
                + (persistedFailure.event.correlationID?.rawValue ?? "")
                + ":mov:user_selected"
        )
        guard case .failed = viewModel.state else {
            return XCTFail("Expected the ViewModel to expose probe failure.")
        }
        let json = try await store.exportJSON()
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(jsonText.contains("alice"))
        XCTAssertFalse(jsonText.contains("Secret Client"))
        XCTAssertFalse(jsonText.contains("token-sk_test_SENTINEL"))
        XCTAssertFalse(jsonText.contains("/Users/"))
    }

    func test_mainWorkflowSourceDoesNotExposeArchitectureTerms() throws {
        let mainWorkflowSource = try mainWorkspaceSource()
        let forbiddenTerms = ["Forsetti", "Host Template", "Pattern B", "Model Assets"]

        for term in forbiddenTerms {
            XCTAssertFalse(containsWholeTerm(term, in: mainWorkflowSource), "\(term) leaked into main workflow UI")
        }
    }

    func test_settingsAndAboutCanExposeTechnicalArchitectureTerms() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Technical Details"))
        XCTAssertTrue(source.contains("Mirmir module runtime"))
        XCTAssertTrue(source.contains("ASH remains a directly testable reference"))
        XCTAssertFalse(source.contains("Forsetti"))
    }

    func test_liveSettingsExposePersistentDiagnosticViewerAndBothExports() throws {
        let appSource = try sourceText(for: ["Mirmir/App/MirmirApp.swift"])
        let settingsSource = try settingsViewSource()
        let workspaceSource = try sourceText(
            for: ["Mirmir/Modules/UI/Views/MirmirWorkspaceScreens.swift"]
        )

        XCTAssertTrue(appSource.contains("Settings {"))
        XCTAssertTrue(appSource.contains("MirmirDiagnosticSettingsView("))
        XCTAssertTrue(
            appSource.contains("store: MirmirDiagnosticStore.application")
        )
        XCTAssertTrue(
            settingsSource.contains(
                "struct MirmirDiagnosticSettingsView: View"
            )
        )
        XCTAssertTrue(settingsSource.contains("try await store.snapshot()"))
        XCTAssertTrue(settingsSource.contains("try await store.exportJSON()"))
        XCTAssertTrue(
            settingsSource.contains("try await store.exportMarkdown()")
        )
        XCTAssertTrue(settingsSource.contains("Button(\"JSON…\")"))
        XCTAssertTrue(settingsSource.contains("Button(\"Markdown…\")"))
        XCTAssertTrue(settingsSource.contains(".fileExporter("))
        XCTAssertTrue(workspaceSource.contains("SettingsLink {"))
        XCTAssertTrue(
            workspaceSource.contains("Open Diagnostic Log Settings…")
        )
    }

    func test_diagnosticSettingsSurfacesPersistenceHealthAndRetainsExports()
        throws {
        let settingsSource = try settingsViewSource()
        let requiredSourceFragments = [
            "persistenceHealth = await store.persistenceHealth()",
            "persistenceHealth.failedOperationCount > 0",
            #"\(persistenceHealth.failedOperationCount) failed "#,
            #"\(persistenceHealth.lastFailedOperation ?? "unknown")."#,
            "try await store.exportJSON()",
            "try await store.exportMarkdown()",
            "Button(\"JSON…\")",
            "Button(\"Markdown…\")",
            ".fileExporter("
        ]

        for fragment in requiredSourceFragments {
            XCTAssertTrue(
                settingsSource.contains(fragment),
                "Missing Diagnostic Settings source wiring: \(fragment)"
            )
        }
    }

    func test_mainWorkflowContainsDetailedWorkspaceShell() throws {
        let source = try detailedWorkspaceSource()
        let requiredTerms = [
            "Dashboard",
            "Library",
            "Upscale",
            "Queue",
            "Modes",
            "Settings",
            "Before",
            "After",
            "Choose Source",
            "Start Upscale",
            "Source",
            "Output",
            "Deterministic State",
            "Confidence",
            "Frames"
        ]

        for term in requiredTerms {
            XCTAssertTrue(source.contains(term), "\(term) is missing from the detailed workspace shell")
        }
    }

    func test_mainWorkflowContainsRequiredInspectorControls() throws {
        let source = try detailedWorkspaceSource()
        let requiredControls = [
            "engineSelectionText",
            "Strategy",
            "Mode",
            "Temporal Consistency",
            "Edge Fidelity",
            "Detail Recovery",
            "Output Format",
            "Destination"
        ]

        for control in requiredControls {
            XCTAssertTrue(source.contains(control), "\(control) is missing from the upscale inspector")
        }
    }

    func test_sampledPreviewUsesProductionPairOnOneCommonCanvas() throws {
        let source = try sourceText(
            for: [
                "Mirmir/Modules/UI/Views/"
                    + "MirmirUpscaleWorkspaceView.swift"
            ]
        )
        let requiredWiring = [
            "MirmirPreviewRaster(image: frame.processed)",
            "MirmirPreviewRaster(image: frame.source)",
            ".mask(alignment: .leading)",
            ".frame(width: size.width, height: size.height)",
            "Live sampled preview",
            "Both sides show the same sampled production frame.",
            "Continuous playback and scrubbing are not included.",
            ".accessibilityHidden(true)",
            "Upscale failed: \\(reason)"
        ]

        for fragment in requiredWiring {
            XCTAssertTrue(
                source.contains(fragment),
                "Missing truthful sampled-preview wiring: \(fragment)"
            )
        }
        XCTAssertFalse(source.contains("previewHalf("))
        XCTAssertFalse(
            source.contains("Live frame playback is not available.")
        )
        XCTAssertFalse(
            source.contains("The current source cannot be prepared.")
        )
        XCTAssertFalse(
            source.contains(
                ".accessibilityLabel(\"Before after split handle\")"
            )
        )
    }

    func test_previewTimestampFloorsWithoutSyntheticFrameComponent() {
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: 0),
            "00:00:00"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: 59.999),
            "00:00:59"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: 3_661.999),
            "01:01:01"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: -1),
            "00:00:00"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.timestamp(seconds: .nan),
            "00:00:00"
        )
    }

    func test_lastPreviewPairSurvivesTerminalFailureAndExposesReason()
        async throws {
        let preview = try makePreviewFrame()
        let engine = PreviewFailingEngineService(preview: preview)
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let source = makeSourceProfile()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                viewModel.defaultOutputURL(for: source, target: .p2160)
            )
        )

        viewModel.startUpscale()

        for _ in 0..<200 {
            if case .failed = viewModel.state,
               viewModel.latestPreviewFrame != nil {
                break
            }
            await Task.yield()
        }

        let retained = try XCTUnwrap(viewModel.latestPreviewFrame)
        XCTAssertEqual(retained, preview)
        guard case .failed(let reason) = viewModel.state else {
            return XCTFail("Expected the injected terminal failure.")
        }
        XCTAssertEqual(
            reason,
            "Upscale strategy failed: writer finalization rejected the output"
        )
        XCTAssertEqual(
            MirmirPreviewPresentation.message(for: viewModel.state),
            "Upscale failed: \(reason)"
        )

        viewModel.upscaleAnotherVideo()
        XCTAssertNil(viewModel.latestPreviewFrame)
    }

    func test_retryRejectionClearsPreviewFromPriorAttempt()
        async throws {
        let preview = try makePreviewFrame()
        let engine = PreviewFailingEngineService(preview: preview)
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: engine,
            modelAssets: NoopModelAssetsService()
        )
        let source = makeSourceProfile()
        viewModel.sourceProfile = source
        viewModel.targetResolution = .p2160
        viewModel.state = .ready
        XCTAssertTrue(
            viewModel.acceptOutputURLSelectedByUser(
                viewModel.defaultOutputURL(for: source, target: .p2160)
            )
        )

        viewModel.startUpscale()
        for _ in 0..<200 {
            if case .failed = viewModel.state,
               viewModel.latestPreviewFrame != nil {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(viewModel.latestPreviewFrame, preview)

        viewModel.retryFailedUpscale()

        XCTAssertNil(viewModel.latestPreviewFrame)
        XCTAssertEqual(
            viewModel.state,
            .failed("An upscale job is already running.")
        )
    }

    func test_queueAndRecoveryControlsAreWiredToFunctionalActions()
        throws {
        let source = try detailedWorkspaceSource()
        let requiredWiring = [
            "viewModel.discardRecoverableJob(",
            "viewModel.discardAllRecoverableJobs()",
            "viewModel.retryFailedUpscale()",
            "viewModel.dismissTerminalJob()",
            "if viewModel.recoveryRequiresReauthorization(",
            "confirmationDialog(",
            "cachedFrameCount",
            "Discard All Interrupted"
        ]

        for fragment in requiredWiring {
            XCTAssertTrue(
                source.contains(fragment),
                "Missing queue/recovery wiring: \(fragment)"
            )
        }
        XCTAssertFalse(source.contains("Button(\"Clear Completed\") {}"))
        XCTAssertFalse(source.contains("Button(\"Retry\") {}"))
    }

    func test_themeTokensAreCentralizedForDetailedSpec() throws {
        let source = try themeTokenSource()
        let requiredTokens = [
            "Midnight Nordic",
            "Arctic Indigo",
            "background",
            "surfaceElevated",
            "surfaceInset",
            "borderSubtle",
            "accentPrimary",
            "viewerOverlay",
            "focusRing",
            "space4",
            "radiusLarge"
        ]

        for token in requiredTokens {
            XCTAssertTrue(source.contains(token), "\(token) is missing from the Mirmir theme token system")
        }
    }

    private func makeViewModel() -> MirmirViewModel {
        MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: NoopModelAssetsService()
        )
    }

    private func makeSourceProfile(url: URL = URL(fileURLWithPath: "/tmp/source.mov")) -> SourceProfile {
        SourceProfile(
            url: url,
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: false
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
                frameIndex: 17,
                presentationSeconds: 0.5,
                source: source,
                processed: processed
            )
        )
    }

    private func workflowViewSource() throws -> String {
        let url = repoRootURL().appendingPathComponent("Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func mainWorkspaceSource() throws -> String {
        try sourceText(for: [
            "Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift",
            "Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift",
            "Mirmir/Modules/UI/Views/MirmirStatusStripView.swift",
            "Mirmir/Modules/UI/Views/MirmirWorkspaceComponents.swift"
        ])
    }

    private func detailedWorkspaceSource() throws -> String {
        try sourceText(for: [
            "Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift",
            "Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift",
            "Mirmir/Modules/UI/Views/MirmirStatusStripView.swift",
            "Mirmir/Modules/UI/Views/MirmirWorkspaceComponents.swift",
            "Mirmir/Modules/UI/Views/MirmirWorkspaceScreens.swift",
            "Mirmir/Modules/UI/Views/R13UpscaleActionPanel.swift"
        ])
    }

    private func settingsViewSource() throws -> String {
        let url = repoRootURL().appendingPathComponent("Mirmir/Modules/UI/Views/MirmirSettingsViews.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func themeTokenSource() throws -> String {
        let url = repoRootURL().appendingPathComponent("Mirmir/Modules/UI/Theme/MirmirTheme.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceText(for paths: [String]) throws -> String {
        try paths.map { path in
            let url = repoRootURL().appendingPathComponent(path)
            return try String(contentsOf: url, encoding: .utf8)
        }
        .joined(separator: "\n")
    }

    private func containsWholeTerm(_ term: String, in source: String) -> Bool {
        let escapedTerm = NSRegularExpression.escapedPattern(for: term)
        let pattern = #"(?i)(?<![A-Za-z0-9])"# + escapedTerm + #"(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("Invalid scan expression for \(term)")
            return true
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.firstMatch(in: source, range: range) != nil
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class CountingMediaPipelineService: MediaPipelineService, @unchecked Sendable {
    private let count = NSLock()
    private var storedProbeCount = 0

    var probeCount: Int {
        count.withLock { storedProbeCount }
    }

    func probe(url: URL) async throws -> SourceProfile {
        count.withLock { storedProbeCount += 1 }
        return SourceProfile(
            url: url,
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        let pool = try PixelBufferBridge.makePool(width: 16, height: 16)
        return StubMediaSession(
            sourceProfile: source,
            outputProfile: output,
            outputPixelBufferPool: pool
        )
    }

    func start() {}
    func stop() {}
}

private final class FailingProbeMediaPipelineService:
    MediaPipelineService,
    @unchecked Sendable {
    func probe(url: URL) async throws -> SourceProfile {
        let underlying = NSError(
            domain: "NSPOSIXErrorDomain",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Private source failure at \(url.path)"
            ]
        )
        throw MediaPipelineError.readerCreationFailed(url, underlying)
    }

    func beginSession(
        source: SourceProfile,
        output _: OutputProfile
    ) async throws -> MediaSession {
        throw MediaPipelineError.readerCreationFailed(source.url, nil)
    }

    func start() {}
    func stop() {}
}

private final class RecordingUnavailableEngineService: UpscalerEngineService, @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .unavailable(
        reason: UnavailableUpscalerEngineService.roadmapTransitionReason
    )

    private let count = NSLock()
    private var storedSubmitCount = 0

    var submitCount: Int {
        count.withLock { storedSubmitCount }
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        count.withLock { storedSubmitCount += 1 }
        throw UpscalerEngineError.backendUnavailable(
            reason: UnavailableUpscalerEngineService.roadmapTransitionReason
        )
    }

    func start() {}
    func stop() {}
}

private final class DelayedCancellationEngineService: UpscalerEngineService, @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available

    private let handleLock = NSLock()
    private var storedHandle: DelayedCancellationJobHandle?

    var latestHandle: DelayedCancellationJobHandle? {
        handleLock.withLock { storedHandle }
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        let handle = DelayedCancellationJobHandle()
        handleLock.withLock { storedHandle = handle }
        return handle
    }

    func start() {}
    func stop() {}
}

private final class DelayedCancellationJobHandle: UpscalerJobHandle, @unchecked Sendable {
    private struct State {
        var cancelRequested = false
        var completed = false
        var waiter: CheckedContinuation<URL, Error>?
    }

    let progressStream: AsyncStream<UpscaleProgress>
    private let state = NSLock()
    private var storedState = State()

    init() {
        self.progressStream = AsyncStream { $0.finish() }
    }

    var cancelRequested: Bool {
        state.withLock { storedState.cancelRequested }
    }

    func cancel() {
        state.withLock { storedState.cancelRequested = true }
    }

    func waitForCompletion() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completeNow = state.withLock {
                if storedState.completed {
                    return true
                }
                storedState.waiter = continuation
                return false
            }
            if completeNow {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func completeCancellation() {
        let waiter = state.withLock { () -> CheckedContinuation<URL, Error>? in
            storedState.completed = true
            defer { storedState.waiter = nil }
            return storedState.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }
}

private final class PreviewFailingEngineService:
    UpscalerEngineService,
    @unchecked Sendable {
    let availability: UpscalerEngineAvailability = .available
    private let preview: UpscalePreviewFrame
    private let lock = NSLock()
    private var submissionCount = 0

    init(preview: UpscalePreviewFrame) {
        self.preview = preview
    }

    func submit(_: UpscaleJob) throws -> UpscalerJobHandle {
        let isRetry = lock.withLock {
            submissionCount += 1
            return submissionCount > 1
        }
        if isRetry {
            throw UpscalerEngineError.jobAlreadyRunning
        }
        return PreviewFailingJobHandle(preview: preview)
    }

    func start() {}
    func stop() {}
}

private final class PreviewFailingJobHandle:
    UpscalerJobHandle,
    @unchecked Sendable {
    let progressStream: AsyncStream<UpscaleProgress>
    let previewStream: AsyncStream<UpscalePreviewFrame>

    init(preview: UpscalePreviewFrame) {
        progressStream = AsyncStream { continuation in
            continuation.finish()
        }
        previewStream = AsyncStream(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            continuation.yield(preview)
            continuation.finish()
        }
    }

    func cancel() {}

    func waitForCompletion() async throws -> URL {
        await Task.yield()
        throw UpscalerEngineError.strategyFailed(
            "writer finalization rejected the output"
        )
    }
}
