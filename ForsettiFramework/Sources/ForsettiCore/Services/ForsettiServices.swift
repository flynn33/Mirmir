import Foundation

public protocol ForsettiServiceProviding: Sendable {
    func resolve<T>(_ type: T.Type) -> T?
}

public protocol NetworkingService: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public protocol StorageService: Sendable {
    func set(_ value: String, forKey key: String)
    func value(forKey key: String) -> String?
    func removeValue(forKey key: String)
}

public protocol SecureStorageService: Sendable {
    func set(_ value: Data, forKey key: String) throws
    func value(forKey key: String) throws -> Data?
    func removeValue(forKey key: String) throws
}

public protocol FileExportService: Sendable {
    func export(data: Data, suggestedFileName: String) throws -> URL
}

public protocol TelemetryService: Sendable {
    func track(event: String, properties: [String: String])
}

public final class ForsettiServiceContainer: ForsettiServiceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var services: [ObjectIdentifier: Any] = [:]

    public init() {}

    public func register<T>(_ type: T.Type, service: T) {
        lock.lock()
        services[ObjectIdentifier(type)] = service
        lock.unlock()
    }

    public func resolve<T>(_ type: T.Type) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return services[ObjectIdentifier(type)] as? T
    }
}

public final class CapabilityScopedServiceProvider: ForsettiServiceProviding, @unchecked Sendable {
    private let baseProvider: any ForsettiServiceProviding
    private let moduleID: String
    private let grantedCapabilities: Set<Capability>
    private let logger: any ForsettiLogger

    public init(
        baseProvider: any ForsettiServiceProviding,
        moduleID: String,
        grantedCapabilities: Set<Capability>,
        logger: any ForsettiLogger
    ) {
        self.baseProvider = baseProvider
        self.moduleID = moduleID
        self.grantedCapabilities = grantedCapabilities
        self.logger = logger
    }

    public func resolve<T>(_ type: T.Type) -> T? {
        guard let requiredCapability = Self.requiredCapability(for: type) else {
            logDeniedResolution(type: type, reason: "No capability mapping exists for this service type.")
            return nil
        }

        guard grantedCapabilities.contains(requiredCapability) else {
            logDeniedResolution(
                type: type,
                reason: "Missing capability \(requiredCapability.rawValue)."
            )
            return nil
        }

        return baseProvider.resolve(type)
    }

    private static func requiredCapability<T>(for type: T.Type) -> Capability? {
        switch ObjectIdentifier(type) {
        case ObjectIdentifier(NetworkingService.self):
            return .networking
        case ObjectIdentifier(StorageService.self):
            return .storage
        case ObjectIdentifier(SecureStorageService.self):
            return .secureStorage
        case ObjectIdentifier(FileExportService.self):
            return .fileExport
        case ObjectIdentifier(TelemetryService.self):
            return .telemetry
        default:
            return nil
        }
    }

    private func logDeniedResolution<T>(type: T.Type, reason: String) {
        logger.log(
            .warning,
            message: "Denied service resolution for \(String(describing: type)). \(reason)",
            sourceModuleID: moduleID
        )
    }
}
