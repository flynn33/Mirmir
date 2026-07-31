import Foundation
import os.lock

struct ModelAssetsAcquisitionOperation {
    let id: UUID
    let binding: ModelAssetsRouteBinding
    var task: Task<Void, Never>?
}

struct ModelAssetsTargetState {
    var binding: ModelAssetsRouteBinding = .unresolved
    var stager: VTModelStager?
    var status: ModelAssetsStatus = .unknown
    var operation: ModelAssetsAcquisitionOperation?
    var waiters: Set<UUID> = []
}

struct DefaultModelAssetsServiceState {
    var targets: [ModelAssetsTarget: ModelAssetsTargetState] = [:]
    var continuations:
        [ModelAssetsTarget:
            [UUID: AsyncStream<ModelAssetsStatus>.Continuation]] = [:]
}

struct ModelAssetsBoundRoute {
    let stager: VTModelStager?
    let status: ModelAssetsStatus
}

struct ModelAssetsOperationContext {
    let id: UUID
    let binding: ModelAssetsRouteBinding
    let stager: VTModelStager
}

struct ModelAssetsStatusSnapshot {
    let binding: ModelAssetsRouteBinding
    let stager: VTModelStager?
    let operationIsActive: Bool
}

typealias ModelAssetsStatusContinuation =
    AsyncStream<ModelAssetsStatus>.Continuation

typealias ModelAssetsRebindResult = (
    status: ModelAssetsStatus?,
    continuations: [ModelAssetsStatusContinuation]
)

final class DefaultModelAssetsService:
    ModelAssetsRouteBindingService,
    @unchecked Sendable {

    typealias StagerFactory = @Sendable (
        R04VideoToolboxNativeRouteBinding
    ) throws -> VTModelStager

    let lock = OSAllocatedUnfairLock(
        initialState: DefaultModelAssetsServiceState()
    )
    let stagerFactory: StagerFactory

    init(
        stagerFactory: @escaping StagerFactory =
            { binding in
                try DefaultModelAssetsService.makeProductionStager(
                    binding: binding
                )
            }
    ) {
        self.stagerFactory = stagerFactory
    }

    deinit {
        let resources = lock.withLock { state -> (
            [Task<Void, Never>],
            [AsyncStream<ModelAssetsStatus>.Continuation]
        ) in
            let tasks = state.targets.values.compactMap {
                $0.operation?.task
            }
            let continuations = state.continuations.values.flatMap {
                $0.values
            }
            state.targets.removeAll()
            state.continuations.removeAll()
            return (tasks, continuations)
        }
        resources.0.forEach { $0.cancel() }
        resources.1.forEach { $0.finish() }
    }

    func bind(
        _ binding: ModelAssetsRouteBinding,
        for target: ModelAssetsTarget
    ) {
        if refreshEquivalentBinding(binding, for: target) {
            return
        }

        let boundRoute = resolve(binding)
        let result = lock.withLock { state -> (
            Task<Void, Never>?,
            [AsyncStream<ModelAssetsStatus>.Continuation]
        ) in
            var targetState =
                state.targets[target] ?? ModelAssetsTargetState()
            let staleTask = targetState.operation?.task
            targetState.binding = binding
            targetState.stager = boundRoute.stager
            targetState.status = boundRoute.status
            targetState.operation = nil
            state.targets[target] = targetState
            return (
                staleTask,
                Array(state.continuations[target]?.values ?? [:].values)
            )
        }
        result.0?.cancel()
        result.1.forEach { $0.yield(boundRoute.status) }

        if case .downloading = boundRoute.status {
            startOperationIfNeeded(
                for: target,
                binding: binding,
                allowDownload: false
            )
        }
    }

    func currentBinding(
        for target: ModelAssetsTarget
    ) -> ModelAssetsRouteBinding {
        lock.withLock {
            $0.targets[target]?.binding ?? .unresolved
        }
    }

    func currentStatus(
        for target: ModelAssetsTarget
    ) -> ModelAssetsStatus {
        lock.withLock {
            $0.targets[target]?.status ?? .unknown
        }
    }

    func statusStream(
        for target: ModelAssetsTarget
    ) -> AsyncStream<ModelAssetsStatus> {
        AsyncStream { continuation in
            let id = UUID()
            let initial = lock.withLock { state in
                state.continuations[target, default: [:]][id] =
                    continuation
                return state.targets[target]?.status ?? .unknown
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id, for: target)
            }
        }
    }

    func ensureReady(for target: ModelAssetsTarget) async throws {
        try Task.checkCancellation()
        refreshStatus(for: target)
        let expectedBinding = currentBinding(for: target)

        switch expectedBinding {
        case .unresolved:
            throw ModelAssetsServiceError.configurationNotBound
        case .notRequired:
            return
        case .videoToolboxQuality:
            retryFailedQualityBindingIfNeeded(
                expectedBinding,
                for: target
            )
        }

        let waiterID = UUID()
        registerWaiter(waiterID, for: target)
        defer {
            unregisterWaiter(waiterID, for: target)
        }

        startOperationIfNeeded(
            for: target,
            binding: expectedBinding,
            allowDownload: true
        )

        for await status in statusStream(for: target) {
            try Task.checkCancellation()
            guard currentBinding(for: target) == expectedBinding else {
                throw ModelAssetsServiceError.configurationChanged
            }
            switch status {
            case .ready, .notRequired:
                return
            case .failed(let reason):
                throw ModelAssetsServiceError.downloadFailed(reason)
            case .unknown:
                throw ModelAssetsServiceError.configurationNotBound
            case .downloadRequired, .downloading:
                continue
            }
        }
        try Task.checkCancellation()
        throw ModelAssetsServiceError.downloadFailed(
            "model_status_stream_ended"
        )
    }

    func start() {
        for target in ModelAssetsTarget.allCases {
            refreshStatus(for: target)
            if case .downloading = currentStatus(for: target) {
                startOperationIfNeeded(
                    for: target,
                    binding: currentBinding(for: target),
                    allowDownload: false
                )
            }
        }
    }

    func stop() {
        let stoppedStatus = ModelAssetsStatus.failed(
            reason: ModelAssetsServiceError.serviceStopped.description
        )
        let resources = lock.withLock { state -> (
            [Task<Void, Never>],
            [ModelAssetsStatusContinuation]
        ) in
            let tasks = state.targets.values.compactMap {
                $0.operation?.task
            }
            for target in state.targets.keys {
                guard state.targets[target]?.operation != nil
                        || state.targets[target]?.waiters.isEmpty == false
                else {
                    continue
                }
                state.targets[target]?.operation = nil
                state.targets[target]?.waiters.removeAll()
                state.targets[target]?.status = stoppedStatus
            }
            let continuations = state.continuations
                .filter { target, _ in
                    state.targets[target]?.status == stoppedStatus
                }
                .flatMap(\.value.values)
            return (tasks, Array(continuations))
        }
        resources.0.forEach { $0.cancel() }
        resources.1.forEach { $0.yield(stoppedStatus) }
    }

}
