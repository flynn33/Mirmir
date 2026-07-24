import Foundation
import XCTest
@testable import Mirmir

@MainActor
final class MirmirAppBootstrapTests: XCTestCase {
    func test_injectedBootstrapBootsExactRuntimeAndRegistersWorkspaceView() throws {
        let bootstrap = try MirmirAppBootstrap(services: MirmirServices(
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            media: NoopMediaPipelineService(),
            upscaler: NoopUpscalerEngineService()
        ))

        XCTAssertEqual(bootstrap.productionState, .idle)
        bootstrap.bootForProduction()
        bootstrap.bootForProduction()

        XCTAssertEqual(bootstrap.productionState, .ready)
        XCTAssertEqual(bootstrap.moduleHost.state, .active)
        XCTAssertEqual(
            bootstrap.moduleHost.records.map(\.descriptor),
            MirmirModuleCatalog.activationOrder
        )
        XCTAssertEqual(
            bootstrap.moduleHost.records.map(\.lifecycleState),
            Array(repeating: .active, count: 5)
        )
        XCTAssertNotNil(
            bootstrap.viewRegistry.resolve(viewID: MirmirUIConstants.primaryViewID)
        )
    }

    func test_defaultBootstrapUsesReleaseA11ModesAndNoModelAssets() async {
        let bootstrap = MirmirAppBootstrap()

        XCTAssertEqual(bootstrap.viewModel.engineAvailability, .available)
        XCTAssertEqual(bootstrap.viewModel.selectedMode, .deterministic)
        XCTAssertEqual(bootstrap.viewModel.selectedModeAvailability, .available)
        XCTAssertEqual(
            bootstrap.viewModel.engineSelectionText,
            "Apple MPS Lanczos (A11)"
        )

        bootstrap.viewModel.selectedMode = .auto
        XCTAssertEqual(
            bootstrap.viewModel.canStartFailureReason,
            R13ReleaseModePolicy.autoUnavailableReason
        )

        for _ in 0..<100 where bootstrap.viewModel.modelStatus != .notRequired {
            await Task.yield()
        }
        XCTAssertEqual(bootstrap.viewModel.modelStatus, .notRequired)
        XCTAssertEqual(
            bootstrap.viewModel.modelAssetsStatusText,
            "No model download required"
        )
    }

    func test_developerRootContainsNoModuleMutationControls() throws {
        let source = try String(
            contentsOf: repoRootURL().appendingPathComponent(
                "Mirmir/App/MirmirDeveloperRootView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("host.stop"))
        XCTAssertFalse(source.contains("deactivate"))
        XCTAssertFalse(source.contains("Toggle("))
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
