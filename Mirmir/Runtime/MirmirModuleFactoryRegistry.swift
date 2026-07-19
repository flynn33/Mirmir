import Foundation

enum MirmirModuleFactoryRegistryError: Error, Equatable, LocalizedError {
    case invalidDescriptor(moduleID: String, reason: String)
    case duplicateModuleID(String)
    case duplicateEntryPoint(String)
    case moduleNotRegistered(String)
    case entryPointNotRegistered(String)
    case factoryDescriptorMismatch(
        expected: MirmirModuleDescriptor,
        actual: MirmirModuleDescriptor
    )

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor(let moduleID, let reason):
            return "Module descriptor \(moduleID) is invalid: \(reason)"
        case .duplicateModuleID(let moduleID):
            return "Module ID is already registered: \(moduleID)"
        case .duplicateEntryPoint(let entryPoint):
            return "Module entry point is already registered: \(entryPoint)"
        case .moduleNotRegistered(let moduleID):
            return "Module ID is not registered: \(moduleID)"
        case .entryPointNotRegistered(let entryPoint):
            return "Module entry point is not registered: \(entryPoint)"
        case .factoryDescriptorMismatch(let expected, let actual):
            return "Factory for \(expected.moduleID) returned descriptor \(actual.moduleID)"
        }
    }
}

@MainActor
final class MirmirModuleFactoryRegistry {
    typealias Factory = @MainActor () -> any MirmirModule

    private struct Registration {
        let descriptor: MirmirModuleDescriptor
        let factory: Factory
    }

    private var registrationsByModuleID: [String: Registration] = [:]
    private var moduleIDByEntryPoint: [String: String] = [:]

    var registeredDescriptors: [MirmirModuleDescriptor] {
        registrationsByModuleID.values
            .map(\.descriptor)
            .sorted { $0.moduleID < $1.moduleID }
    }

    func register(
        descriptor: MirmirModuleDescriptor,
        factory: @escaping Factory
    ) throws {
        try Self.validate(descriptor)
        guard registrationsByModuleID[descriptor.moduleID] == nil else {
            throw MirmirModuleFactoryRegistryError.duplicateModuleID(descriptor.moduleID)
        }
        guard moduleIDByEntryPoint[descriptor.entryPoint] == nil else {
            throw MirmirModuleFactoryRegistryError.duplicateEntryPoint(descriptor.entryPoint)
        }

        registrationsByModuleID[descriptor.moduleID] = Registration(
            descriptor: descriptor,
            factory: factory
        )
        moduleIDByEntryPoint[descriptor.entryPoint] = descriptor.moduleID
    }

    func descriptor(moduleID: String) -> MirmirModuleDescriptor? {
        registrationsByModuleID[moduleID]?.descriptor
    }

    func makeModule(moduleID: String) throws -> any MirmirModule {
        guard let registration = registrationsByModuleID[moduleID] else {
            throw MirmirModuleFactoryRegistryError.moduleNotRegistered(moduleID)
        }
        return try makeModule(registration: registration)
    }

    func makeModule(entryPoint: String) throws -> any MirmirModule {
        guard let moduleID = moduleIDByEntryPoint[entryPoint] else {
            throw MirmirModuleFactoryRegistryError.entryPointNotRegistered(entryPoint)
        }
        return try makeModule(moduleID: moduleID)
    }

    private func makeModule(registration: Registration) throws -> any MirmirModule {
        let module = registration.factory()
        guard module.descriptor == registration.descriptor else {
            throw MirmirModuleFactoryRegistryError.factoryDescriptorMismatch(
                expected: registration.descriptor,
                actual: module.descriptor
            )
        }
        return module
    }

    private static func validate(_ descriptor: MirmirModuleDescriptor) throws {
        let fields = [
            ("module ID", descriptor.moduleID),
            ("display name", descriptor.displayName),
            ("version string", descriptor.versionString),
            ("entry point", descriptor.entryPoint)
        ]
        for (name, value) in fields where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MirmirModuleFactoryRegistryError.invalidDescriptor(
                moduleID: descriptor.moduleID,
                reason: "\(name) must not be empty"
            )
        }
    }
}
