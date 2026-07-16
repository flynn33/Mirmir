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
    private let artifactStore: ASHLockedArtifactStoreV3

    init(resourceRoot: URL) {
        self.artifactStore = ASHLockedArtifactStoreV3(resourceRoot: resourceRoot)
    }

    convenience init(bundle: Bundle) {
        let resources = bundle.resourceURL ?? bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        self.init(
            resourceRoot: resources
                .appendingPathComponent("ASH", isDirectory: true)
                .appendingPathComponent("LockedV3", isDirectory: true)
        )
    }

    init(artifactStore: ASHLockedArtifactStoreV3) {
        self.artifactStore = artifactStore
    }

    func makeBackend(
        route: ASHSpatialRouteV2,
        telemetry: any ASHTelemetryRecording
    ) async throws -> any ASHUpscaleBackend {
        let artifacts = try await artifactStore.artifacts()
        return try ASHLockedUpscaleBackendV3(
            route: route,
            artifacts: artifacts,
            telemetry: telemetry
        )
    }
}
