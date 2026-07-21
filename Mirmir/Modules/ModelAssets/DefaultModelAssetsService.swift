import Foundation
import os.lock

@available(macOS 26.0, *)
final class DefaultModelAssetsService: ModelAssetsService, @unchecked Sendable {

    private struct State {
        var statusByTarget: [ModelAssetsTarget: ModelAssetsStatus] = [:]
        var continuationsByTarget: [ModelAssetsTarget: [UUID: AsyncStream<ModelAssetsStatus>.Continuation]] = [:]
        var inFlight: Set<ModelAssetsTarget> = []
        var ownedAcquisitions: Set<ModelAssetsTarget> = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let stager: VTModelStager

    init(stager: VTModelStager = VTModelStager()) {
        self.stager = stager
    }

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
                _ = self?.lock.withLock { state in
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
                let acquisitionOwned = lock.withLock { state in
                    state.ownedAcquisitions.contains(target)
                }
                if let error = Self.terminalWaiterError(
                    for: status,
                    acquisitionAuthority: stager.acquisitionAuthority,
                    acquisitionOwned: acquisitionOwned
                ) {
                    throw error
                }
            }
            return
        }

        defer {
            lock.withLock { state in
                _ = state.inFlight.remove(target)
                _ = state.ownedAcquisitions.remove(target)
            }
        }

        do {
            let status = stager.currentStatus()
            if status == .downloadRequired,
               stager.acquisitionAuthority == .systemDownloadAuthorized {
                lock.withLock { state in
                    _ = state.ownedAcquisitions.insert(target)
                }
            }
            updateStatus(Self.serviceStatus(for: status), for: target)
            if status == .ready { return }
            try await stager.ensureReady { [weak self] progress in
                self?.updateStatus(.downloading(progress: progress), for: target)
            }
            updateStatus(.ready, for: target)
        } catch VTModelStagerError.acquisitionNotAuthorized {
            updateStatus(.downloadRequired, for: target)
            throw ModelAssetsServiceError.acquisitionNotAuthorized
        } catch VTModelStagerError.downloadAlreadyInProgress(let progress) {
            lock.withLock { state in
                _ = state.ownedAcquisitions.remove(target)
            }
            updateStatus(.downloading(progress: progress), for: target)
            throw ModelAssetsServiceError.downloadAlreadyInProgress(progress: progress)
        } catch VTModelStagerError.unavailable {
            updateStatus(.failed(reason: "quality_configuration_not_bound"), for: target)
            throw ModelAssetsServiceError.configurationNotBound
        } catch VTModelStagerError.downloadCompletedWithoutReady(let status) {
            let reason = String(describing: status)
            updateStatus(.failed(reason: reason), for: target)
            throw ModelAssetsServiceError.downloadFailed(reason)
        } catch {
            updateStatus(.failed(reason: String(describing: error)), for: target)
            throw error
        }
    }

    func start() {
        for target in ModelAssetsTarget.allCases {
            updateStatus(Self.serviceStatus(for: stager.currentStatus()), for: target)
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
            state.ownedAcquisitions.removeAll()
        }
    }

    private func updateStatus(_ status: ModelAssetsStatus, for target: ModelAssetsTarget) {
        let conts: [AsyncStream<ModelAssetsStatus>.Continuation] = lock.withLock { state in
            state.statusByTarget[target] = status
            return Array(state.continuationsByTarget[target]?.values ?? [UUID: AsyncStream<ModelAssetsStatus>.Continuation]().values)
        }
        for cont in conts {
            cont.yield(status)
        }
    }

    private static func serviceStatus(
        for nativeStatus: VTModelStagerStatus
    ) -> ModelAssetsStatus {
        switch nativeStatus {
        case .downloadRequired:
            return .downloadRequired
        case .downloading(let progress):
            return .downloading(progress: progress)
        case .ready:
            return .ready
        case .unavailable(let reason):
            return .failed(reason: reason)
        }
    }

    static func terminalWaiterError(
        for status: ModelAssetsStatus,
        acquisitionAuthority: VTModelAcquisitionAuthority,
        acquisitionOwned: Bool
    ) -> ModelAssetsServiceError? {
        switch status {
        case .downloadRequired where acquisitionAuthority == .statusOnly:
            return .acquisitionNotAuthorized
        case .downloading(let progress) where !acquisitionOwned:
            return .downloadAlreadyInProgress(progress: progress)
        case .failed(let reason):
            return .downloadFailed(reason)
        case .unknown, .downloadRequired, .downloading, .ready:
            return nil
        }
    }
}
