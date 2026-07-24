import Foundation

final class NotRequiredModelAssetsService: ModelAssetsService, @unchecked Sendable {
    func currentStatus(for _: ModelAssetsTarget) -> ModelAssetsStatus {
        .notRequired
    }

    func statusStream(for _: ModelAssetsTarget) -> AsyncStream<ModelAssetsStatus> {
        AsyncStream { continuation in
            continuation.yield(.notRequired)
            continuation.finish()
        }
    }

    func ensureReady(for _: ModelAssetsTarget) async throws {}

    func start() {}
    func stop() {}
}
