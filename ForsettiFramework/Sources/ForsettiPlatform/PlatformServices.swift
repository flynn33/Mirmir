import Foundation
import ForsettiCore

#if canImport(OSLog)
import OSLog
#endif

#if canImport(Security)
import Security
#endif

public final class URLSessionNetworkingService: NetworkingService, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public final class UserDefaultsStorageService: StorageService, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func value(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

public final class InMemorySecureStorageService: SecureStorageService, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func set(_ value: Data, forKey key: String) {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }

    public func value(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func removeValue(forKey key: String) {
        lock.lock()
        storage[key] = nil
        lock.unlock()
    }
}

public enum KeychainSecureStorageError: Error, LocalizedError, Equatable {
    case unavailable
    case unexpectedStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Keychain secure storage is unavailable on this platform."
        case let .unexpectedStatus(status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

public final class KeychainSecureStorageService: SecureStorageService, @unchecked Sendable {
    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "Forsetti") {
        self.service = service
    }

    public func set(_ value: Data, forKey key: String) throws {
        #if canImport(Security)
        var addQuery = keychainQuery(forKey: key)
        addQuery[kSecValueData as String] = value

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery = keychainQuery(forKey: key)
            let attributes = [kSecValueData as String: value]
            try validate(status: SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary))
            return
        }

        try validate(status: status)
        #else
        throw KeychainSecureStorageError.unavailable
        #endif
    }

    public func value(forKey key: String) throws -> Data? {
        #if canImport(Security)
        var query = keychainQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }

        try validate(status: status)
        return result as? Data
        #else
        throw KeychainSecureStorageError.unavailable
        #endif
    }

    public func removeValue(forKey key: String) throws {
        #if canImport(Security)
        let status = SecItemDelete(keychainQuery(forKey: key) as CFDictionary)
        if status == errSecItemNotFound {
            return
        }

        try validate(status: status)
        #else
        throw KeychainSecureStorageError.unavailable
        #endif
    }

    #if canImport(Security)
    private func keychainQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func validate(status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw KeychainSecureStorageError.unexpectedStatus(Int32(status))
        }
    }
    #endif
}

public enum LocalFileExportError: Error, LocalizedError, Equatable {
    case invalidFileName
    case targetEscapesExportDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidFileName:
            return "Suggested file name is invalid."
        case .targetEscapesExportDirectory:
            return "Export target must remain inside the configured export directory."
        }
    }
}

public final class LocalFileExportService: FileExportService, @unchecked Sendable {
    private let directoryURL: URL

    public init(directoryURL: URL = FileManager.default.temporaryDirectory) {
        self.directoryURL = directoryURL
    }

    public func export(data: Data, suggestedFileName: String) throws -> URL {
        let sanitizedFileName = try sanitize(fileName: suggestedFileName)
        let exportDirectory = directoryURL.standardizedFileURL
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let targetURL = exportDirectory
            .appendingPathComponent(sanitizedFileName, isDirectory: false)
            .standardizedFileURL
        guard targetURL.deletingLastPathComponent().path == exportDirectory.path else {
            throw LocalFileExportError.targetEscapesExportDirectory
        }

        try data.write(to: targetURL, options: .atomic)
        return targetURL
    }

    private func sanitize(fileName: String) throws -> String {
        let normalized = fileName
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lastPathComponent = URL(fileURLWithPath: normalized).lastPathComponent
        let sanitized = lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            throw LocalFileExportError.invalidFileName
        }

        return sanitized
    }
}

public final class NoopTelemetryService: TelemetryService, @unchecked Sendable {
    public init() {}

    public func track(event _: String, properties _: [String: String]) {}
}

public final class OSLogForsettiLogger: ForsettiLogger, @unchecked Sendable {
    #if canImport(OSLog)
    private let logger: Logger
    #endif

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "Forsetti",
        category: String = "Runtime"
    ) {
        #if canImport(OSLog)
        logger = Logger(subsystem: subsystem, category: category)
        #endif
    }

    public func log(_ level: LogLevel, message: String) {
        #if canImport(OSLog)
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
        #else
        #if DEBUG
        print("[Forsetti][\(level.rawValue.uppercased())] \(message)")
        #endif
        #endif
    }
}

public final class DefaultForsettiPlatformServices {
    public let container: ForsettiServiceContainer

    public init(
        networking: NetworkingService = URLSessionNetworkingService(),
        storage: StorageService = UserDefaultsStorageService(),
        secureStorage: SecureStorageService = KeychainSecureStorageService(),
        fileExport: FileExportService = LocalFileExportService(),
        telemetry: TelemetryService = NoopTelemetryService()
    ) {
        container = ForsettiServiceContainer()
        container.register(NetworkingService.self, service: networking)
        container.register(StorageService.self, service: storage)
        container.register(SecureStorageService.self, service: secureStorage)
        container.register(FileExportService.self, service: fileExport)
        container.register(TelemetryService.self, service: telemetry)
    }
}
