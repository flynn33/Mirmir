import Foundation

extension R13ReleaseUpscalerEngineService {
    func resolveHardeningRuntime() throws
        -> R13ReleaseHardeningRuntime? {
        while true {
            let snapshot = hardeningRuntimeState.withLock {
                (runtime: $0.runtime, epoch: $0.epoch)
            }
            if let runtime = snapshot.runtime {
                return runtime
            }

            let resolvedRuntime: R13ReleaseHardeningRuntime?
            do {
                resolvedRuntime = try hardeningRuntimeProvider()
            } catch {
                let current = hardeningRuntimeState.withLock {
                    (runtime: $0.runtime, epoch: $0.epoch)
                }
                if let runtime = current.runtime {
                    return runtime
                }
                if current.epoch !== snapshot.epoch {
                    continue
                }
                throw error
            }

            let publication: (
                accepted: Bool,
                runtime: R13ReleaseHardeningRuntime?
            ) = hardeningRuntimeState.withLock { state in
                if let runtime = state.runtime {
                    return (accepted: true, runtime: runtime)
                }
                guard state.epoch === snapshot.epoch else {
                    return (accepted: false, runtime: resolvedRuntime)
                }
                state.runtime = resolvedRuntime
                return (accepted: true, runtime: resolvedRuntime)
            }
            if publication.accepted {
                return publication.runtime
            }
        }
    }

    func performCacheLocationChange(
        _ operation: () throws -> R13CacheLocationStatus
    ) throws -> R13CacheLocationStatus {
        let reserved = activeJobState.withLock { state in
            guard case .idle = state else { return false }
            state = .changingCacheLocation
            return true
        }
        guard reserved else {
            throw R13CacheLocationError.changeWhileJobRunning
        }
        defer {
            activeJobState.withLock { state in
                guard case .changingCacheLocation = state else {
                    preconditionFailure(
                        "R13 cache-location reservation changed unexpectedly."
                    )
                }
                state = .idle
            }
        }
        let status = try operation()
        hardeningRuntimeState.withLock { state in
            state.runtime = nil
            state.epoch = HardeningRuntimeEpoch()
        }
        return status
    }

    func start() {}

    func stop() {
        let activeHandle: R13ReleaseUpscalerJobHandle? =
            activeJobState.withLock { state in
            switch state {
            case .idle, .changingCacheLocation, .discardingRecovery:
                return nil
            case .reserved:
                state = .stoppingReserved
                return nil
            case .stoppingReserved:
                return nil
            case .active(let handle):
                return handle
            }
        }
        activeHandle?.cancel()
    }
}
