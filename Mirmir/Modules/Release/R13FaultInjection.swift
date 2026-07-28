enum R13FaultPoint: String, CaseIterable, Hashable, Sendable {
    case beforeResourceAdmission = "before_resource_admission"
    case afterResourceAdmission = "after_resource_admission"
    case beforeBackendStart = "before_backend_start"
    case beforeOutputFinalize = "before_output_finalize"
    case beforeMetadataReopen = "before_metadata_reopen"
}

enum R13InjectedFault: String, CaseIterable, Equatable, Sendable {
    case cancellation
    case diskFull = "disk_full"
    case lowMemory = "low_memory"
    case thermalCritical = "thermal_critical"
    case backendUnavailable = "backend_unavailable"
    case metadataReopenFailure = "metadata_reopen_failure"
}

protocol R13FaultInjecting: Sendable {
    func fault(at point: R13FaultPoint) async -> R13InjectedFault?
}

struct R13ProductionNoOpFaultInjector: R13FaultInjecting {
    func fault(at _: R13FaultPoint) async -> R13InjectedFault? {
        nil
    }
}

enum R13FaultInjectorFactory {
    static func production() -> any R13FaultInjecting {
        R13ProductionNoOpFaultInjector()
    }
}
