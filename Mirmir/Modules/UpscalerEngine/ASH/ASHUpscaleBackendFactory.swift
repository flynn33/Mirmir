import Foundation

@available(macOS 15.4, *)
protocol ASHUpscaleBackendFactory: Sendable {
    func makeBackend(
        route: ASHSpatialRouteV2,
        telemetry: any ASHTelemetryRecording
    ) async throws -> any ASHUpscaleBackend
}

@available(macOS 15.4, *)
struct ASHDevelopmentUpscaleBackendFactory: ASHUpscaleBackendFactory {
    func makeBackend(
        route: ASHSpatialRouteV2,
        telemetry: any ASHTelemetryRecording
    ) async throws -> any ASHUpscaleBackend {
        ASHDeterministicUpscaleBackend(route: route, telemetry: telemetry)
    }
}

@available(macOS 15.4, *)
final class ASHLockedUpscaleBackendFactoryV3: ASHUpscaleBackendFactory, @unchecked Sendable {
    private enum ExecutionMode {
        case developmentCPU
        case productionMetal(any MetalRenderingService)
    }

    private let artifactStore: ASHLockedArtifactStoreV3
    private let executionMode: ExecutionMode

    init(resourceRoot: URL) {
        self.artifactStore = ASHLockedArtifactStoreV3(resourceRoot: resourceRoot)
        self.executionMode = .developmentCPU
    }

    convenience init(bundle: Bundle, metal: any MetalRenderingService) {
        let resources = bundle.resourceURL ?? bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        self.init(
            artifactStore: ASHLockedArtifactStoreV3(
                resourceRoot: resources
                .appendingPathComponent("ASH", isDirectory: true)
                .appendingPathComponent("LockedV3", isDirectory: true)
            ),
            metal: metal
        )
    }

    init(artifactStore: ASHLockedArtifactStoreV3) {
        self.artifactStore = artifactStore
        self.executionMode = .developmentCPU
    }

    init(
        artifactStore: ASHLockedArtifactStoreV3,
        metal: any MetalRenderingService
    ) {
        self.artifactStore = artifactStore
        self.executionMode = .productionMetal(metal)
    }

    func makeBackend(
        route: ASHSpatialRouteV2,
        telemetry: any ASHTelemetryRecording
    ) async throws -> any ASHUpscaleBackend {
        let artifacts = try await artifactStore.artifacts()
        switch executionMode {
        case .developmentCPU:
            return try ASHLockedUpscaleBackendV3(
                route: route,
                artifacts: artifacts,
                telemetry: telemetry
            )
        case .productionMetal(let metal):
            return try ASHMetalUpscaleBackendV3(
                route: route,
                artifacts: artifacts,
                metal: metal,
                telemetry: telemetry
            )
        }
    }
}
