import Foundation
import os.lock

@available(macOS 15.4, *)
final class DefaultModelAssetsService: ModelAssetsService, @unchecked Sendable {

    private struct State {
        var statusByTarget: [ModelAssetsTarget: ModelAssetsStatus] = [:]
        var continuationsByTarget: [ModelAssetsTarget: [UUID: AsyncStream<ModelAssetsStatus>.Continuation]] = [:]
        var inFlight: Set<ModelAssetsTarget> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let stager = VTModelStager()

    func currentStatus(for target: ModelAssetsTarget) -> ModelAssetsStatus {
        lock.withLock { state in
            state.statusByTarget[target] ?? .unknown
        }
    }

    func statusStream(for target: ModelAssetsTarget) -> AsyncStream<ModelAssetsStatus> {
        AsyncStream { continuation in
            let id = UUID()
            let initial: ModelAssetsStatus = lock.withLock { state in
                state.continuationsByTarget[target, default: [:]][id] = continuation
                return state.statusByTarget[target] ?? .unknown
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { state in
                    state.continuationsByTarget[target]?.removeValue(forKey: id)
                }
            }
        }
    }

    func ensureReady(for target: ModelAssetsTarget) async throws {
        let alreadyInFlight: Bool = lock.withLock { state in
            if state.inFlight.contains(target) { return true }
            state.inFlight.insert(target)
            return false
        }
        if alreadyInFlight {
            for await status in statusStream(for: target) {
                if case .ready = status { return }
                if case .failed(let reason) = status {
                    throw ModelAssetsServiceError.downloadFailed(reason)
                }
            }
            return
        }

        defer {
            lock.withLock { state in
                state.inFlight.remove(target)
            }
        }

        do {
            updateStatus(.downloading(progress: 0), for: target)
            try await stager.ensureReady { [weak self] progress in
                self?.updateStatus(.downloading(progress: progress), for: target)
            }
            updateStatus(.ready, for: target)
        } catch {
            updateStatus(.failed(reason: String(describing: error)), for: target)
            throw error
        }
    }

    func start() {
        for target in ModelAssetsTarget.allCases {
            updateStatus(.unknown, for: target)
        }
    }

    func stop() {
        lock.withLock { state in
            for (_, conts) in state.continuationsByTarget {
                for cont in conts.values {
                    cont.finish()
                }
            }
            state.continuationsByTarget.removeAll()
            state.inFlight.removeAll()
        }
    }

    private func updateStatus(_ status: ModelAssetsStatus, for target: ModelAssetsTarget) {
        let conts: [AsyncStream<ModelAssetsStatus>.Continuation] = lock.withLock { state in
            state.statusByTarget[target] = status
            return Array(state.continuationsByTarget[target]?.values ?? Dictionary<UUID, AsyncStream<ModelAssetsStatus>.Continuation>().values)
        }
        for cont in conts {
            cont.yield(status)
        }
    }
}
