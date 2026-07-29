import Foundation

struct MirmirDiagnosticField: Codable, Equatable, Sendable {
    let key: MirmirDiagnosticToken
    let value: MirmirDiagnosticFieldValue

    init(key: String, value: MirmirDiagnosticFieldValue) throws {
        self.key = try MirmirDiagnosticToken(key, field: "diagnostic_field_key")
        self.value = value
    }
}

struct MirmirDiagnosticErrorFrame: Codable, Equatable, Sendable {
    let type: String
    let domain: String
    let code: Int

    init(type: String, domain: String, code: Int) {
        self.type = Self.safeIdentifier(type)
        self.domain = Self.safeIdentifier(domain)
        self.code = code
    }

    private static func safeIdentifier(_ value: String) -> String {
        guard !value.isEmpty,
              value.utf8.count <= 160,
              value.utf8.allSatisfy({ byte in
                  switch byte {
                  case 48...57, 65...90, 97...122:
                      return true
                  case 45, 46, 95:
                      return true
                  default:
                      return false
                  }
              }) else {
            return "untrusted"
        }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case type
        case domain
        case code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decode(String.self, forKey: .type),
            domain: try container.decode(String.self, forKey: .domain),
            code: try container.decode(Int.self, forKey: .code)
        )
    }
}

struct MirmirDiagnosticErrorIdentity: Codable, Equatable, Sendable {
    static let maximumFrames = 8

    let frames: [MirmirDiagnosticErrorFrame]

    init(_ error: Error) {
        var frames: [MirmirDiagnosticErrorFrame] = []
        var observed: Set<ObjectIdentifier> = []
        var current: NSError? = error as NSError
        var currentType = String(reflecting: Swift.type(of: error))

        while let error = current, frames.count < Self.maximumFrames {
            let identity = ObjectIdentifier(error)
            guard observed.insert(identity).inserted else { break }
            frames.append(MirmirDiagnosticErrorFrame(
                type: currentType,
                domain: error.domain,
                code: error.code
            ))
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            if let current {
                currentType = String(reflecting: Swift.type(of: current))
            }
        }
        self.frames = frames.isEmpty
            ? [MirmirDiagnosticErrorFrame(
                type: "untrusted",
                domain: "untrusted",
                code: 0
            )]
            : frames
    }

    init(errors: [Error]) {
        var combined: [MirmirDiagnosticErrorFrame] = []
        for error in errors where combined.count < Self.maximumFrames {
            for frame in Self.init(error).frames
            where combined.count < Self.maximumFrames {
                guard !combined.contains(frame) else { continue }
                combined.append(frame)
            }
        }
        frames = combined.isEmpty
            ? [MirmirDiagnosticErrorFrame(
                type: "untrusted",
                domain: "untrusted",
                code: 0
            )]
            : combined
    }

    private init(validatedFrames: [MirmirDiagnosticErrorFrame]) {
        frames = validatedFrames
    }

    enum CodingKeys: String, CodingKey {
        case frames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frames = try container.decode(
            [MirmirDiagnosticErrorFrame].self,
            forKey: .frames
        )
        guard !frames.isEmpty, frames.count <= Self.maximumFrames else {
            throw DecodingError.dataCorruptedError(
                forKey: .frames,
                in: container,
                debugDescription: "Invalid diagnostic error identity."
            )
        }
        self.init(validatedFrames: frames)
    }
}

struct MirmirDiagnosticSourceLocation: Codable, Equatable, Sendable {
    let fileID: String
    let line: UInt

    init(fileID: String, line: UInt) throws {
        let components = fileID.split(separator: "/", omittingEmptySubsequences: false)
        guard !fileID.isEmpty,
              !fileID.hasPrefix("/"),
              fileID.utf8.count <= 256,
              line > 0,
              !components.contains(where: { $0.isEmpty || $0 == ".." }),
              fileID.utf8.allSatisfy({ byte in
                  switch byte {
                  case 48...57, 65...90, 97...122:
                      return true
                  case 43, 45, 46, 47, 95:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw MirmirDiagnosticValidationError.invalidSourceLocation
        }
        self.fileID = fileID
        self.line = line
    }

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case line
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                fileID: container.decode(String.self, forKey: .fileID),
                line: container.decode(UInt.self, forKey: .line)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .fileID,
                in: container,
                debugDescription: "Invalid diagnostic source location."
            )
        }
    }
}

struct MirmirDiagnosticEvent: Codable, Equatable, Sendable {
    static let maximumFields = 32

    let severity: MirmirDiagnosticSeverity
    let subsystem: MirmirDiagnosticToken
    let operation: MirmirDiagnosticToken
    let code: MirmirDiagnosticToken
    let correlationID: MirmirDiagnosticID?
    let fields: [MirmirDiagnosticField]
    let error: MirmirDiagnosticErrorIdentity?
    let source: MirmirDiagnosticSourceLocation?

    init(
        severity: MirmirDiagnosticSeverity,
        subsystem: String,
        operation: String,
        code: String,
        correlationID: UUID? = nil,
        fields: [MirmirDiagnosticField] = [],
        error: MirmirDiagnosticErrorIdentity? = nil,
        source: MirmirDiagnosticSourceLocation? = nil
    ) throws {
        guard fields.count <= Self.maximumFields else {
            throw MirmirDiagnosticValidationError.tooManyFields(
                maximum: Self.maximumFields
            )
        }
        let sortedFields = fields.sorted {
            $0.key.rawValue < $1.key.rawValue
        }
        for (left, right) in zip(sortedFields, sortedFields.dropFirst())
        where left.key == right.key {
            throw MirmirDiagnosticValidationError.duplicateField(
                left.key.rawValue
            )
        }
        self.severity = severity
        self.subsystem = try MirmirDiagnosticToken(
            subsystem,
            field: "diagnostic_subsystem"
        )
        self.operation = try MirmirDiagnosticToken(
            operation,
            field: "diagnostic_operation"
        )
        self.code = try MirmirDiagnosticToken(code, field: "diagnostic_code")
        self.correlationID = correlationID.map(MirmirDiagnosticID.init)
        self.fields = sortedFields
        self.error = error
        self.source = source
    }

    private init(
        severity: MirmirDiagnosticSeverity,
        subsystem: MirmirDiagnosticToken,
        operation: MirmirDiagnosticToken,
        code: MirmirDiagnosticToken,
        correlationID: MirmirDiagnosticID?,
        fields: [MirmirDiagnosticField],
        error: MirmirDiagnosticErrorIdentity?,
        source: MirmirDiagnosticSourceLocation?
    ) throws {
        try self.init(
            severity: severity,
            subsystem: subsystem.rawValue,
            operation: operation.rawValue,
            code: code.rawValue,
            correlationID: correlationID.flatMap {
                UUID(uuidString: $0.rawValue)
            },
            fields: fields,
            error: error,
            source: source
        )
    }

    enum CodingKeys: String, CodingKey {
        case severity
        case subsystem
        case operation
        case code
        case correlationID = "correlation_id"
        case fields
        case error
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                severity: container.decode(
                    MirmirDiagnosticSeverity.self,
                    forKey: .severity
                ),
                subsystem: container.decode(
                    MirmirDiagnosticToken.self,
                    forKey: .subsystem
                ),
                operation: container.decode(
                    MirmirDiagnosticToken.self,
                    forKey: .operation
                ),
                code: container.decode(
                    MirmirDiagnosticToken.self,
                    forKey: .code
                ),
                correlationID: container.decodeIfPresent(
                    MirmirDiagnosticID.self,
                    forKey: .correlationID
                ),
                fields: container.decode(
                    [MirmirDiagnosticField].self,
                    forKey: .fields
                ),
                error: container.decodeIfPresent(
                    MirmirDiagnosticErrorIdentity.self,
                    forKey: .error
                ),
                source: container.decodeIfPresent(
                    MirmirDiagnosticSourceLocation.self,
                    forKey: .source
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .fields,
                in: container,
                debugDescription: "Invalid diagnostic event."
            )
        }
    }
}

struct MirmirDiagnosticRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sequence: UInt64
    let timestampUnixMilliseconds: Int64
    let uptimeNanoseconds: UInt64
    let sessionID: MirmirDiagnosticID
    let event: MirmirDiagnosticEvent

    init(
        sequence: UInt64,
        timestampUnixMilliseconds: Int64,
        uptimeNanoseconds: UInt64,
        sessionID: MirmirDiagnosticID,
        event: MirmirDiagnosticEvent
    ) throws {
        guard timestampUnixMilliseconds >= 0 else {
            throw MirmirDiagnosticValidationError.invalidTimestamp
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.sequence = sequence
        self.timestampUnixMilliseconds = timestampUnixMilliseconds
        self.uptimeNanoseconds = uptimeNanoseconds
        self.sessionID = sessionID
        self.event = event
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sequence
        case timestampUnixMilliseconds = "timestamp_unix_ms"
        case uptimeNanoseconds = "uptime_ns"
        case sessionID = "session_id"
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported diagnostic record schema."
            )
        }
        do {
            try self.init(
                sequence: container.decode(UInt64.self, forKey: .sequence),
                timestampUnixMilliseconds: container.decode(
                    Int64.self,
                    forKey: .timestampUnixMilliseconds
                ),
                uptimeNanoseconds: container.decode(
                    UInt64.self,
                    forKey: .uptimeNanoseconds
                ),
                sessionID: container.decode(
                    MirmirDiagnosticID.self,
                    forKey: .sessionID
                ),
                event: container.decode(
                    MirmirDiagnosticEvent.self,
                    forKey: .event
                )
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .timestampUnixMilliseconds,
                in: container,
                debugDescription: "Invalid diagnostic record."
            )
        }
    }
}

enum MirmirDiagnosticCanonicalJSON {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

enum MirmirDiagnosticPrivacyValidator {
    private static let privateKeys: Set<String> = [
        "account",
        "account_id",
        "bookmark",
        "bookmark_data",
        "filename",
        "home_directory",
        "hostname",
        "message",
        "password",
        "path",
        "secret",
        "token",
        "url",
        "user_name",
        "username"
    ]
    private static let emailExpression = Result {
        try NSRegularExpression(
            pattern: #"(?i)(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        )
    }
    private static let privatePathExpression = Result {
        try NSRegularExpression(pattern: #"(?i)(?:file://|/Users/|/home/)"#)
    }
    private static let credentialExpression = Result {
        try NSRegularExpression(
            pattern: #"(?i)(?:sk_(?:live|test|proj)|gh[pousr]_|xox[baprs]-|bearer\s+)[A-Za-z0-9_-]+"#
        )
    }

    static func validateJSON(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        try validateJSONValue(object)
    }

    static func validateDocumentText(_ value: String) throws {
        guard try !containsPrivateText(value) else {
            throw MirmirDiagnosticValidationError.privacyViolation
        }
    }

    private static func validateJSONValue(_ value: Any) throws {
        switch value {
        case let object as [String: Any]:
            for (key, child) in object {
                guard !privateKeys.contains(key.lowercased()) else {
                    throw MirmirDiagnosticValidationError.privacyViolation
                }
                try validateJSONValue(child)
            }
        case let array as [Any]:
            for child in array {
                try validateJSONValue(child)
            }
        case let string as String:
            guard !string.unicodeScalars.contains(where: { $0.value < 0x20 }),
                  try !containsPrivateText(string) else {
                throw MirmirDiagnosticValidationError.privacyViolation
            }
        default:
            break
        }
    }

    private static func containsPrivateText(_ value: String) throws -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return try emailExpression.get().firstMatch(in: value, range: range) != nil
            || privatePathExpression.get().firstMatch(in: value, range: range) != nil
            || credentialExpression.get().firstMatch(in: value, range: range) != nil
    }
}
