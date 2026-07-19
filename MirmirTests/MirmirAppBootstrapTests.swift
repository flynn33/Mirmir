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

    func test_defaultBootstrapUsesRoadmapTransitionAvailability() {
        let bootstrap = MirmirAppBootstrap()

        XCTAssertEqual(
            bootstrap.viewModel.engineAvailability,
            .unavailable(reason: UnavailableUpscalerEngineService.roadmapTransitionReason)
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
