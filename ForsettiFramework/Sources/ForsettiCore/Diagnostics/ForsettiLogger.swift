import Foundation

public enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol ForsettiLogger: Sendable {
    func log(_ level: LogLevel, message: String)
}

public extension ForsettiLogger {
    func log(
        _ level: LogLevel,
        message: String,
        sourceModuleID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        var prefixComponents: [String] = []

        if let sourceModuleID, !sourceModuleID.isEmpty {
            prefixComponents.append("module=\(sourceModuleID)")
        }

        if !metadata.isEmpty {
            let renderedMetadata = metadata
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            prefixComponents.append(renderedMetadata)
        }

        if prefixComponents.isEmpty {
            log(level, message: message)
            return
        }

        log(level, message: "[\(prefixComponents.joined(separator: " "))] \(message)")
    }

    func logError(
        _ error: any Error,
        message: String,
        sourceModuleID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        var mergedMetadata = metadata
        mergedMetadata["errorDescription"] = error.localizedDescription
        mergedMetadata["errorType"] = String(describing: type(of: error))

        log(
            .error,
            message: message,
            sourceModuleID: sourceModuleID,
            metadata: mergedMetadata
        )
    }
}

public struct ConsoleForsettiLogger: ForsettiLogger {
    public init() {}

    public func log(_ level: LogLevel, message: String) {
        #if DEBUG
        print("[Forsetti][\(level.rawValue.uppercased())] \(message)")
        #endif
    }
}
