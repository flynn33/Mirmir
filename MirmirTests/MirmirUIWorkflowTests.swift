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
        viewModel.ashBackendStatus = .available
        viewModel.sourceProfile = sourceProfile
        viewModel.targetResolution = .p2160
        viewModel.outputURL = viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)
        viewModel.state = .ready

        XCTAssertTrue(viewModel.canStart)

        viewModel.outputURL = nil
        XCTAssertFalse(viewModel.canStart)

        viewModel.outputURL = viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)
        viewModel.targetResolution = .p1080
        XCTAssertFalse(viewModel.canStart)

        viewModel.targetResolution = .p2160
        viewModel.ashBackendStatus = .unavailable
        XCTAssertFalse(viewModel.canStart)

        viewModel.ashBackendStatus = .available
        viewModel.state = .running
        XCTAssertFalse(viewModel.canStart)
    }

    func test_defaultOutputFilenameUsesTargetResolution() {
        let viewModel = makeViewModel()
        let sourceProfile = makeSourceProfile(url: URL(fileURLWithPath: "/tmp/clip.mov"))

        let outputURL = viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)

        XCTAssertEqual(outputURL.lastPathComponent, "clip_mirmir_2160p.mp4")
    }

    func test_supportedVideoExtensionsCoverCommonAVFoundationReadableFormats() {
        XCTAssertEqual(MirmirViewModel.supportedVideoExtensions, ["mp4", "mov", "m4v", "qt", "avi", "mpg", "mpeg"])

        for fileExtension in MirmirViewModel.supportedVideoExtensions {
            let url = URL(fileURLWithPath: "/tmp/source.\(fileExtension)")
            XCTAssertTrue(MirmirViewModel.supportsVideoFile(url), fileExtension)
        }

        XCTAssertFalse(MirmirViewModel.supportsVideoFile(URL(fileURLWithPath: "/tmp/source.txt")))
    }

    func test_unsupportedFileReportsVisibleError() {
        let viewModel = makeViewModel()

        viewModel.loadSource(url: URL(fileURLWithPath: "/tmp/source.txt"))

        XCTAssertEqual(viewModel.state, .failed(MirmirViewModel.unsupportedFileMessage))
    }

    func test_mainWorkflowSourceDoesNotExposeArchitectureTerms() throws {
        let mainWorkflowSource = try mainWorkspaceSource()
        let forbiddenTerms = ["Forsetti", "Host Template", "Pattern B", "Model Assets", "backend"]

        for term in forbiddenTerms {
            XCTAssertFalse(containsWholeTerm(term, in: mainWorkflowSource), "\(term) leaked into main workflow UI")
        }
    }

    func test_settingsAndAboutCanExposeTechnicalArchitectureTerms() throws {
        let source = try settingsViewSource()

        XCTAssertTrue(source.contains("Technical Details"))
        XCTAssertTrue(source.contains("Forsetti"))
        XCTAssertTrue(source.contains("ASH"))
    }

    func test_mainWorkflowContainsDetailedWorkspaceShell() throws {
        let source = try detailedWorkspaceSource()
        let requiredTerms = [
            "Dashboard",
            "Library",
            "Upscale",
            "Queue",
            "Presets",
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
            "ASH v1.0 (Deterministic)",
            "Strategy",
            "Profile",
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
            "Mirmir/Modules/UI/Views/MirmirWorkspaceScreens.swift"
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
