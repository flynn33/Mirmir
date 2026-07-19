import Foundation

final class RoadmapTransitionModelAssetsService: ModelAssetsService, @unchecked Sendable {
    func currentStatus(for _: ModelAssetsTarget) -> ModelAssetsStatus {
        .unknown
    }

    func statusStream(for _: ModelAssetsTarget) -> AsyncStream<ModelAssetsStatus> {
        AsyncStream { continuation in
            continuation.yield(.unknown)
            continuation.finish()
        }
    }

    func ensureReady(for _: ModelAssetsTarget) async throws {
        throw UpscalerEngineError.backendUnavailable(
            reason: UnavailableUpscalerEngineService.roadmapTransitionReason
        )
    }

    func start() {}
    func stop() {}
}
