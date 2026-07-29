import Foundation

extension R13ReleaseUpscalerEngineService {
    func resolveHardeningRuntime() throws
        -> R13ReleaseHardeningRuntime? {
        let runtime = try hardeningRuntimeProvider()
        hardeningRuntimeState.withLock { $0 = runtime }
        return runtime
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
        hardeningRuntimeState.withLock { $0 = nil }
        return status
    }

    func start() {}

    func stop() {
        let activeHandle: R13ReleaseUpscalerJobHandle? =
            activeJobState.withLock { state in
            switch state {
            case .idle, .changingCacheLocation:
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
