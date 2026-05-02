import Foundation

public typealias ModuleFactory = @Sendable () -> ForsettiModule

public enum ModuleRegistryError: Error, LocalizedError {
    case entryPointNotRegistered(String)

    public var errorDescription: String? {
        switch self {
        case let .entryPointNotRegistered(entryPoint):
            return "No module factory registered for entryPoint '\(entryPoint)'."
        }
    }
}

public final class ModuleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var factories: [String: ModuleFactory]

    public init(registrations: [String: ModuleFactory] = [:]) {
        self.factories = registrations
    }

    public var registeredEntryPoints: [String] {
        lock.lock()
        defer { lock.unlock() }
        return factories.keys.sorted()
    }

    public func register(entryPoint: String, factory: @escaping ModuleFactory) {
        lock.lock()
        factories[entryPoint] = factory
        lock.unlock()
    }

    public func makeModule(entryPoint: String) throws -> ForsettiModule {
        lock.lock()
        let factory = factories[entryPoint]
        lock.unlock()

        guard let factory else {
            throw ModuleRegistryError.entryPointNotRegistered(entryPoint)
        }

        return factory()
    }
}
