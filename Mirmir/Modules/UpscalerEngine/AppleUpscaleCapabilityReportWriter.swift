import Foundation

struct R01RawReportWriter {
    static let maximumByteCount = 25 * 1_024 * 1_024

    func encode(
        _ report: R01RawHostReport,
        modelIdentity: String?,
        modelSHA256: String?
    ) throws -> Data {
        try report.validate(modelIdentity: modelIdentity, modelSHA256: modelSHA256)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0A)
        guard data.count <= Self.maximumByteCount else {
            throw R01LiveReportError.reportNotClosed
        }
        let object = try JSONSerialization.jsonObject(with: data)
        try R01PrivacyValidator.validate(object)
        return data
    }

    func write(
        _ report: R01RawHostReport,
        modelIdentity: String?,
        modelSHA256: String?,
        to outputURL: URL
    ) throws {
        let data = try encode(
            report,
            modelIdentity: modelIdentity,
            modelSHA256: modelSHA256
        )
        let manager = FileManager.default
        guard !manager.fileExists(atPath: outputURL.path) else {
            throw R01LiveReportError.outputAlreadyExists
        }
        let parent = outputURL.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey
        ])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw R01LiveReportError.outputNotRegular
        }
        do {
            try data.write(to: outputURL, options: [.atomic, .withoutOverwriting])
        } catch CocoaError.fileWriteFileExists {
            throw R01LiveReportError.outputAlreadyExists
        }
        let values = try outputURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == data.count else {
            throw R01LiveReportError.outputNotRegular
        }
    }
}

enum R01PrivacyValidator {
    private static let privateKeys: Set<String> = [
        "account", "account_id", "hardware_uuid", "home_directory", "hostname",
        "ip_address", "mac_address", "serial", "serial_number", "user_name", "username"
    ]
    private static let emailExpression = Result {
        try NSRegularExpression(
            pattern: #"(?i)(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        )
    }
    private static let privatePathExpression = Result {
        try NSRegularExpression(pattern: #"(?i)(?:file://|/Users/|/home/)"#)
    }
    private static let labeledPrivateExpression = Result {
        try NSRegularExpression(
            pattern: #"(?i)(?:serial(?: number)?|hardware uuid|account(?: id)?|username)\s*[:=]"#
        )
    }

    static func validate(_ value: Any) throws {
        switch value {
        case let object as [String: Any]:
            for (key, child) in object {
                guard !privateKeys.contains(key.lowercased()) else {
                    throw R01LiveReportError.privacyViolation
                }
                try validate(child)
            }
        case let array as [Any]:
            for child in array { try validate(child) }
        case let string as String:
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            let emailExpression = try Self.emailExpression.get()
            let privatePathExpression = try Self.privatePathExpression.get()
            let labeledPrivateExpression = try Self.labeledPrivateExpression.get()
            guard !string.unicodeScalars.contains(where: { $0.value < 0x20 }),
                  emailExpression.firstMatch(in: string, range: range) == nil,
                  privatePathExpression.firstMatch(in: string, range: range) == nil,
                  labeledPrivateExpression.firstMatch(in: string, range: range) == nil else {
                throw R01LiveReportError.privacyViolation
            }
        default:
            break
        }
    }
}
