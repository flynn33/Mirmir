import Foundation

extension DefaultModelAssetsService {
    func refreshEquivalentBinding(
        _ binding: ModelAssetsRouteBinding,
        for target: ModelAssetsTarget
    ) -> Bool {
        let isEquivalent = lock.withLock {
            $0.targets[target]?.binding == binding
        }
        guard isEquivalent else { return false }
        refreshStatus(for: target)
        retryFailedQualityBindingIfNeeded(binding, for: target)
        if case .downloading = currentStatus(for: target) {
            startOperationIfNeeded(
                for: target,
                binding: binding,
                allowDownload: false
            )
        }
        return true
    }

    func resolve(
        _ binding: ModelAssetsRouteBinding
    ) -> ModelAssetsBoundRoute {
        switch binding {
        case .unresolved:
            return ModelAssetsBoundRoute(
                stager: nil,
                status: .unknown
            )
        case .notRequired:
            return ModelAssetsBoundRoute(
                stager: nil,
                status: .notRequired
            )
        case .videoToolboxQuality(let nativeBinding):
            return resolveQualityBinding(nativeBinding)
        }
    }

    func resolveQualityBinding(
        _ binding: R04VideoToolboxNativeRouteBinding
    ) -> ModelAssetsBoundRoute {
        guard binding.requiresConfigurationModel else {
            return ModelAssetsBoundRoute(
                stager: nil,
                status: .failed(
                    reason: ModelAssetsServiceError
                        .configurationNotBound.description
                )
            )
        }
        do {
            let stager = try stagerFactory(binding)
            return ModelAssetsBoundRoute(
                stager: stager,
                status: Self.serviceStatus(
                    for: stager.currentStatus()
                )
            )
        } catch {
            return ModelAssetsBoundRoute(
                stager: nil,
                status: .failed(
                    reason: Self.errorDescription(error)
                )
            )
        }
    }

    func refreshStatus(for target: ModelAssetsTarget) {
        let snapshot = lock.withLock { state in
            let targetState =
                state.targets[target] ?? ModelAssetsTargetState()
            return ModelAssetsStatusSnapshot(
                binding: targetState.binding,
                stager: targetState.stager,
                operationIsActive: targetState.operation != nil
            )
        }
        guard !snapshot.operationIsActive,
              let stager = snapshot.stager else {
            return
        }
        updateStatus(
            Self.serviceStatus(for: stager.currentStatus()),
            for: target,
            binding: snapshot.binding
        )
    }

    func retryFailedQualityBindingIfNeeded(
        _ binding: ModelAssetsRouteBinding,
        for target: ModelAssetsTarget
    ) {
        guard case .videoToolboxQuality(let nativeBinding) = binding else {
            return
        }
        let result: ModelAssetsRebindResult = lock.withLock { state in
            guard var targetState = state.targets[target],
                  targetState.binding == binding,
                  targetState.operation == nil,
                  case .failed = targetState.status else {
                return (nil, [])
            }
            let reboundRoute = resolveQualityBinding(nativeBinding)
            targetState.stager = reboundRoute.stager
            targetState.status = reboundRoute.status
            state.targets[target] = targetState
            return (
                reboundRoute.status,
                Array(
                    state.continuations[target]?.values
                        ?? [:].values
                )
            )
        }
        guard let status = result.status else { return }
        result.continuations.forEach { $0.yield(status) }
    }

    func startOperationIfNeeded(
        for target: ModelAssetsTarget,
        binding: ModelAssetsRouteBinding,
        allowDownload: Bool
    ) {
        refreshStatus(for: target)
        let context: ModelAssetsOperationContext? =
            lock.withLock { state in
            guard var targetState = state.targets[target],
                  targetState.binding == binding,
                  targetState.operation == nil,
                  let stager = targetState.stager else {
                return nil
            }
            switch targetState.status {
            case .downloadRequired where allowDownload, .downloading:
                break
            case .unknown, .notRequired, .downloadRequired, .ready,
                 .failed:
                return nil
            }
            let id = UUID()
            targetState.operation = ModelAssetsAcquisitionOperation(
                id: id,
                binding: binding,
                task: nil
            )
            state.targets[target] = targetState
            return ModelAssetsOperationContext(
                id: id,
                binding: binding,
                stager: stager
            )
        }
        guard let context else { return }

        if currentStatus(for: target) == .downloadRequired {
            updateStatus(
                .downloading(progress: 0),
                for: target,
                operationID: context.id,
                binding: binding
            )
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performOperation(context, for: target)
        }
        let retained = lock.withLock { state -> Bool in
            guard var targetState = state.targets[target],
                  targetState.operation?.id == context.id,
                  targetState.operation?.binding == binding else {
                return false
            }
            targetState.operation?.task = task
            state.targets[target] = targetState
            return true
        }
        if !retained {
            task.cancel()
        }
    }

    func performOperation(
        _ context: ModelAssetsOperationContext,
        for target: ModelAssetsTarget
    ) async {
        do {
            try await context.stager.ensureReady { [weak self] progress in
                self?.updateStatus(
                    .downloading(progress: Self.normalized(progress)),
                    for: target,
                    operationID: context.id,
                    binding: context.binding
                )
            }
            try Task.checkCancellation()
            finishOperation(context, for: target, status: .ready)
        } catch is CancellationError {
            finishOperation(
                context,
                for: target,
                status: Self.serviceStatus(
                    for: context.stager.currentStatus()
                )
            )
        } catch VTModelStagerError.acquisitionNotAuthorized {
            finishOperation(
                context,
                for: target,
                status: .downloadRequired
            )
        } catch VTModelStagerError.downloadAlreadyInProgress(
            let progress
        ) {
            finishOperation(
                context,
                for: target,
                status: .downloading(
                    progress: Self.normalized(progress)
                )
            )
        } catch VTModelStagerError.unavailable(let reason) {
            finishOperation(
                context,
                for: target,
                status: .failed(reason: reason)
            )
        } catch VTModelStagerError.downloadCompletedWithoutReady(
            let status
        ) {
            finishOperation(
                context,
                for: target,
                status: .failed(
                    reason: "model_download_ended_\(status)"
                )
            )
        } catch {
            finishOperation(
                context,
                for: target,
                status: .failed(
                    reason: Self.errorDescription(error)
                )
            )
        }
    }

    func finishOperation(
        _ context: ModelAssetsOperationContext,
        for target: ModelAssetsTarget,
        status: ModelAssetsStatus
    ) {
        let continuations: [ModelAssetsStatusContinuation] =
            lock.withLock { state in
            guard var targetState = state.targets[target],
                  targetState.binding == context.binding,
                  targetState.operation?.id == context.id else {
                return []
            }
            targetState.operation = nil
            targetState.status = status
            state.targets[target] = targetState
            return Array(
                state.continuations[target]?.values ?? [:].values
            )
        }
        continuations.forEach { $0.yield(status) }
    }

    func updateStatus(
        _ status: ModelAssetsStatus,
        for target: ModelAssetsTarget,
        operationID: UUID? = nil,
        binding: ModelAssetsRouteBinding
    ) {
        let continuations: [ModelAssetsStatusContinuation] =
            lock.withLock { state in
            guard var targetState = state.targets[target],
                  targetState.binding == binding else {
                return []
            }
            if let operationID,
               targetState.operation?.id != operationID {
                return []
            }
            guard targetState.status != status else { return [] }
            targetState.status = status
            state.targets[target] = targetState
            return Array(
                state.continuations[target]?.values ?? [:].values
            )
        }
        continuations.forEach { $0.yield(status) }
    }

    func registerWaiter(
        _ id: UUID,
        for target: ModelAssetsTarget
    ) {
        lock.withLock { state in
            var targetState =
                state.targets[target] ?? ModelAssetsTargetState()
            targetState.waiters.insert(id)
            state.targets[target] = targetState
        }
    }

    func unregisterWaiter(
        _ id: UUID,
        for target: ModelAssetsTarget
    ) {
        let task: Task<Void, Never>? = lock.withLock { state in
            guard var targetState = state.targets[target] else {
                return nil
            }
            targetState.waiters.remove(id)
            state.targets[target] = targetState
            guard targetState.waiters.isEmpty else { return nil }
            return targetState.operation?.task
        }
        task?.cancel()
    }

    func removeContinuation(
        _ id: UUID,
        for target: ModelAssetsTarget
    ) {
        _ = lock.withLock { state in
            state.continuations[target]?.removeValue(forKey: id)
        }
    }

    static func serviceStatus(
        for nativeStatus: VTModelStagerStatus
    ) -> ModelAssetsStatus {
        switch nativeStatus {
        case .downloadRequired:
            return .downloadRequired
        case .downloading(let progress):
            return .downloading(progress: normalized(progress))
        case .ready:
            return .ready
        case .unavailable(let reason):
            return .failed(reason: reason)
        }
    }

    static func normalized(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    static func errorDescription(_ error: Error) -> String {
        if let serviceError = error as? ModelAssetsServiceError {
            return serviceError.description
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    static func makeProductionStager(
        binding: R04VideoToolboxNativeRouteBinding
    ) throws -> VTModelStager {
        #if compiler(>=6.2) && !targetEnvironment(simulator)
        guard #available(macOS 26.0, *) else {
            throw ModelAssetsServiceError.unsupportedOSVersion
        }
        let configuration = try R04VTNativeConfigurationFactory
            .makeQualityConfiguration(binding: binding)
        return VTModelStager(
            configuration: configuration,
            acquisitionAuthority: .systemDownloadAuthorized
        )
        #else
        _ = binding
        throw ModelAssetsServiceError.unsupportedOSVersion
        #endif
    }
}
