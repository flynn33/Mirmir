import Combine
import Foundation
import OSLog

enum MirmirModuleLifecycleState: Equatable, Sendable {
    case registered
    case starting
    case active
    case stopped
    case failed(String)
}

struct MirmirModuleRecord: Equatable, Identifiable, Sendable {
    let descriptor: MirmirModuleDescriptor
    var lifecycleState: MirmirModuleLifecycleState

    var id: String { descriptor.moduleID }
}

enum MirmirModuleHostState: Equatable, Sendable {
    case idle
    case starting
    case active
    case stopped
    case failed(moduleID: String, reason: String)
}

enum MirmirModuleHostError: Error, Equatable, LocalizedError {
    case invalidActivationOrder(String)
    case missingRegistrations([String])
    case unexpectedRegistrations([String])
    case descriptorMismatch(moduleID: String)
    case moduleStartFailed(moduleID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidActivationOrder(let reason):
            return "Module activation order is invalid: \(reason)"
        case .missingRegistrations(let moduleIDs):
            return "Required module registrations are missing: \(moduleIDs.joined(separator: ", "))"
        case .unexpectedRegistrations(let moduleIDs):
            return "Unexpected module registrations are present: \(moduleIDs.joined(separator: ", "))"
        case .descriptorMismatch(let moduleID):
            return "Registered descriptor does not match the required descriptor: \(moduleID)"
        case .moduleStartFailed(let moduleID, let reason):
            return "Module \(moduleID) failed to start: \(reason)"
        }
    }
}

@MainActor
final class MirmirModuleHost: ObservableObject {
    private struct ActiveModule {
        let module: any MirmirModule
        let context: MirmirModuleContext
    }

    @Published private(set) var state: MirmirModuleHostState = .idle
    @Published private(set) var records: [MirmirModuleRecord]

    private let registry: MirmirModuleFactoryRegistry
    private let activationOrder: [MirmirModuleDescriptor]
    private let loggingSubsystem: String
    private var activeModules: [ActiveModule] = []

    init(
        registry: MirmirModuleFactoryRegistry,
        activationOrder: [MirmirModuleDescriptor] = MirmirModuleCatalog.activationOrder,
        loggingSubsystem: String = Bundle.main.bundleIdentifier ?? "com.mirmir.app"
    ) throws {
        try Self.validateActivationOrder(activationOrder)
        try Self.validateRegistrations(registry.registeredDescriptors, required: activationOrder)

        self.registry = registry
        self.activationOrder = activationOrder
        self.loggingSubsystem = loggingSubsystem
        self.records = activationOrder.map {
            MirmirModuleRecord(descriptor: $0, lifecycleState: .registered)
        }
    }

    func start() throws {
        guard state != .active, state != .starting else { return }

        activeModules.removeAll(keepingCapacity: true)
        records = activationOrder.map {
            MirmirModuleRecord(descriptor: $0, lifecycleState: .registered)
        }
        state = .starting

        for descriptor in activationOrder {
            setLifecycleState(.starting, moduleID: descriptor.moduleID)
            let context = MirmirModuleContext(
                moduleID: descriptor.moduleID,
                logger: Logger(subsystem: loggingSubsystem, category: descriptor.moduleID)
            )
            var attemptedModule: (any MirmirModule)?

            do {
                let module = try registry.makeModule(moduleID: descriptor.moduleID)
                attemptedModule = module
                try module.start(context: context)
                activeModules.append(ActiveModule(module: module, context: context))
                setLifecycleState(.active, moduleID: descriptor.moduleID)
            } catch {
                attemptedModule?.stop(context: context)
                rollbackActiveModules()
                let reason = Self.describe(error)
                setLifecycleState(.failed(reason), moduleID: descriptor.moduleID)
                state = .failed(moduleID: descriptor.moduleID, reason: reason)
                throw MirmirModuleHostError.moduleStartFailed(
                    moduleID: descriptor.moduleID,
                    reason: reason
                )
            }
        }

        state = .active
    }

    func stop() {
        guard !activeModules.isEmpty else { return }
        rollbackActiveModules()
        state = .stopped
    }

    func isActive(moduleID: String) -> Bool {
        records.first(where: { $0.descriptor.moduleID == moduleID })?.lifecycleState == .active
    }

    private func rollbackActiveModules() {
        for activeModule in activeModules.reversed() {
            activeModule.module.stop(context: activeModule.context)
            setLifecycleState(.stopped, moduleID: activeModule.module.descriptor.moduleID)
        }
        activeModules.removeAll(keepingCapacity: true)
    }

    private func setLifecycleState(
        _ lifecycleState: MirmirModuleLifecycleState,
        moduleID: String
    ) {
        guard let index = records.firstIndex(where: { $0.descriptor.moduleID == moduleID }) else {
            return
        }
        records[index].lifecycleState = lifecycleState
    }

    private static func validateActivationOrder(
        _ activationOrder: [MirmirModuleDescriptor]
    ) throws {
        guard !activationOrder.isEmpty else {
            throw MirmirModuleHostError.invalidActivationOrder("at least one module is required")
        }
        let moduleIDs = activationOrder.map(\.moduleID)
        guard Set(moduleIDs).count == moduleIDs.count else {
            throw MirmirModuleHostError.invalidActivationOrder("module IDs must be unique")
        }
        let entryPoints = activationOrder.map(\.entryPoint)
        guard Set(entryPoints).count == entryPoints.count else {
            throw MirmirModuleHostError.invalidActivationOrder("entry points must be unique")
        }
        let uiModules = activationOrder.filter { $0.kind == .ui }
        guard uiModules.count == 1 else {
            throw MirmirModuleHostError.invalidActivationOrder("exactly one UI module is required")
        }
        guard activationOrder.last?.kind == .ui else {
            throw MirmirModuleHostError.invalidActivationOrder("the UI module must be last")
        }
        guard activationOrder.dropLast().allSatisfy({ $0.kind == .service }) else {
            throw MirmirModuleHostError.invalidActivationOrder("all modules before the UI must be services")
        }
        guard activationOrder == MirmirModuleCatalog.activationOrder else {
            throw MirmirModuleHostError.invalidActivationOrder(
                "modules must match the fixed Mirmir activation order"
            )
        }
    }

    private static func validateRegistrations(
        _ registrations: [MirmirModuleDescriptor],
        required: [MirmirModuleDescriptor]
    ) throws {
        let registeredIDs = Set(registrations.map(\.moduleID))
        let requiredIDs = Set(required.map(\.moduleID))
        let missing = requiredIDs.subtracting(registeredIDs).sorted()
        guard missing.isEmpty else {
            throw MirmirModuleHostError.missingRegistrations(missing)
        }
        let unexpected = registeredIDs.subtracting(requiredIDs).sorted()
        guard unexpected.isEmpty else {
            throw MirmirModuleHostError.unexpectedRegistrations(unexpected)
        }

        let registrationsByID = Dictionary(uniqueKeysWithValues: registrations.map {
            ($0.moduleID, $0)
        })
        for descriptor in required where registrationsByID[descriptor.moduleID] != descriptor {
            throw MirmirModuleHostError.descriptorMismatch(moduleID: descriptor.moduleID)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
