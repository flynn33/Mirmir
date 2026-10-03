import Foundation

struct MirmirDiagnosticField: Codable, Equatable, Sendable {
    let key: MirmirDiagnosticToken
    let value: MirmirDiagnosticFieldValue

    init(key: String, value: MirmirDiagnosticFieldValue) throws {
        guard MirmirDiagnosticPrivacyValidator.permitsUserInfoKey(key) else {
            throw MirmirDiagnosticValidationError.privacyViolation
        }
        self.key = try MirmirDiagnosticToken(key, field: "diagnostic_field_key")
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case key, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(MirmirDiagnosticToken.self, forKey: .key)
        guard MirmirDiagnosticPrivacyValidator.permitsUserInfoKey(
            key.rawValue
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .key,
                in: container,
                debugDescription: "Private diagnostic field key."
            )
        }
        self.key = key
        value = try container.decode(
            MirmirDiagnosticFieldValue.self,
            forKey: .value
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(value, forKey: .value)
    }
}

struct MirmirDiagnosticErrorFrame: Codable, Equatable, Sendable {
    static let maximumUserInfoEntries = 32

    struct UserInfoEntry: Codable, Equatable, Sendable {
        let key: String
        let value: String

        init(key: String, value: String) throws {
            guard MirmirDiagnosticPrivacyValidator.permitsUserInfoKey(key),
                  let sanitized = MirmirDiagnosticPrivacyValidator
                    .sanitizedForensicString(value),
                  sanitized == value else {
                throw MirmirDiagnosticValidationError.privacyViolation
            }
            self.key = key
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case key, value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                try self.init(
                    key: container.decode(String.self, forKey: .key),
                    value: container.decode(String.self, forKey: .value)
                )
            } catch let error as DecodingError {
                throw error
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Private diagnostic error metadata."
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
        }
    }

    let type: String
    let domain: String
    let code: Int
    let userInfo: [UserInfoEntry]

    init(
        type: String,
        domain: String,
        code: Int,
        userInfo: [UserInfoEntry] = []
    ) {
        self.type = Self.safeIdentifier(type)
        self.domain = Self.safeIdentifier(domain)
        self.code = code
        self.userInfo = Array(
            userInfo.sorted { $0.key < $1.key }
                .prefix(Self.maximumUserInfoEntries)
        )
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
        case userInfo = "user_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let userInfo = try container.decodeIfPresent(
            [UserInfoEntry].self,
            forKey: .userInfo
        ) ?? []
        guard userInfo.count <= Self.maximumUserInfoEntries else {
            throw DecodingError.dataCorruptedError(
                forKey: .userInfo,
                in: container,
                debugDescription: "Too many diagnostic error metadata entries."
            )
        }
        self.init(
            type: try container.decode(String.self, forKey: .type),
            domain: try container.decode(String.self, forKey: .domain),
            code: try container.decode(Int.self, forKey: .code),
            userInfo: userInfo
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(domain, forKey: .domain)
        try container.encode(code, forKey: .code)
        if !userInfo.isEmpty {
            try container.encode(userInfo, forKey: .userInfo)
        }
    }
}

struct MirmirDiagnosticErrorIdentity: Codable, Equatable, Sendable {
    static let maximumFrames = 8
    static let maximumEncodedBytes =
        MirmirDiagnosticRetentionPolicy.production.maximumRecordBytes / 4

    let frames: [MirmirDiagnosticErrorFrame]
    let omittedUserInfoEntryCount: Int

    private struct EncodingEnvelope: Encodable {
        let frames: [MirmirDiagnosticErrorFrame]
        let omittedUserInfoEntryCount: Int

        enum CodingKeys: String, CodingKey {
            case frames
            case omittedUserInfoEntryCount = "omitted_user_info_entry_count"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(frames, forKey: .frames)
            if omittedUserInfoEntryCount > 0 {
                try container.encode(
                    omittedUserInfoEntryCount,
                    forKey: .omittedUserInfoEntryCount
                )
            }
        }
    }

    init(_ error: Error) {
        var frames: [MirmirDiagnosticErrorFrame] = []
        var omittedUserInfoEntryCount = 0
        var observed: Set<ObjectIdentifier> = []
        var current: NSError? = error as NSError
        var currentType = String(reflecting: Swift.type(of: error))

        while let error = current {
            let identity = ObjectIdentifier(error)
            guard observed.insert(identity).inserted else { break }
            var forensicInfo = error.userInfo
            if forensicInfo[NSLocalizedDescriptionKey] == nil {
                forensicInfo[NSLocalizedDescriptionKey] =
                    error.localizedDescription
            }
            let frame = MirmirDiagnosticErrorFrame(
                type: currentType,
                domain: error.domain,
                code: error.code,
                userInfo: Self.forensicUserInfo(forensicInfo)
            )
            if frames.count < Self.maximumFrames {
                frames.append(frame)
                omittedUserInfoEntryCount = Self.saturatingAdd(
                    omittedUserInfoEntryCount,
                    max(0, forensicInfo.count - frame.userInfo.count)
                )
            } else {
                omittedUserInfoEntryCount = Self.saturatingAdd(
                    omittedUserInfoEntryCount,
                    forensicInfo.count
                )
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            if let current {
                currentType = String(reflecting: Swift.type(of: current))
            }
        }
        self.init(
            boundingUserInfoIn: frames,
            previouslyOmittedEntryCount: omittedUserInfoEntryCount
        )
    }

    private static func forensicUserInfo(
        _ userInfo: [String: Any]
    ) -> [MirmirDiagnosticErrorFrame.UserInfoEntry] {
        userInfo.compactMap { key, value in
            guard MirmirDiagnosticPrivacyValidator.permitsUserInfoKey(key),
                  let rendered = MirmirDiagnosticPrivacyValidator
                    .sanitizedForensicString(value) else {
                return nil
            }
            return try? .init(key: key, value: rendered)
        }
    }

    init(errors: [Error]) {
        var combined: [MirmirDiagnosticErrorFrame] = []
        var previouslyOmittedEntryCount = 0
        for error in errors {
            let identity = Self.init(error)
            previouslyOmittedEntryCount = Self.saturatingAdd(
                previouslyOmittedEntryCount,
                identity.omittedUserInfoEntryCount
            )
            for frame in identity.frames {
                guard !combined.contains(frame) else { continue }
                if combined.count < Self.maximumFrames {
                    combined.append(frame)
                } else {
                    previouslyOmittedEntryCount = Self.saturatingAdd(
                        previouslyOmittedEntryCount,
                        frame.userInfo.count
                    )
                }
            }
        }
        self.init(
            boundingUserInfoIn: combined,
            previouslyOmittedEntryCount: previouslyOmittedEntryCount
        )
    }

    private init(
        boundingUserInfoIn sourceFrames: [MirmirDiagnosticErrorFrame],
        previouslyOmittedEntryCount: Int = 0
    ) {
        let nonemptyFrames = sourceFrames.isEmpty
            ? [MirmirDiagnosticErrorFrame(
                type: "untrusted",
                domain: "untrusted",
                code: 0
            )]
            : Array(sourceFrames.prefix(Self.maximumFrames))
        var boundedFrames = nonemptyFrames.map {
            MirmirDiagnosticErrorFrame(
                type: $0.type,
                domain: $0.domain,
                code: $0.code
            )
        }
        let sourceEntryCount = nonemptyFrames.reduce(0) {
            Self.saturatingAdd($0, $1.userInfo.count)
        }
        var retainedEntryCount = 0

        for frameIndex in nonemptyFrames.indices {
            for entry in nonemptyFrames[frameIndex].userInfo {
                var candidateFrames = boundedFrames
                candidateFrames[frameIndex] = MirmirDiagnosticErrorFrame(
                    type: nonemptyFrames[frameIndex].type,
                    domain: nonemptyFrames[frameIndex].domain,
                    code: nonemptyFrames[frameIndex].code,
                    userInfo: boundedFrames[frameIndex].userInfo + [entry]
                )
                let candidateRetainedEntryCount = Self.saturatingAdd(
                    retainedEntryCount,
                    1
                )
                let candidateOmittedEntryCount = Self.saturatingAdd(
                    previouslyOmittedEntryCount,
                    max(0, sourceEntryCount - candidateRetainedEntryCount)
                )
                guard let encoded = try? MirmirDiagnosticCanonicalJSON.data(
                    EncodingEnvelope(
                        frames: candidateFrames,
                        omittedUserInfoEntryCount: candidateOmittedEntryCount
                    )
                ), encoded.count <= Self.maximumEncodedBytes else {
                    continue
                }
                boundedFrames = candidateFrames
                retainedEntryCount = candidateRetainedEntryCount
            }
        }
        frames = boundedFrames
        omittedUserInfoEntryCount = Self.saturatingAdd(
            previouslyOmittedEntryCount,
            max(0, sourceEntryCount - retainedEntryCount)
        )
    }

    private static func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int.max : result
    }

    enum CodingKeys: String, CodingKey {
        case frames
        case omittedUserInfoEntryCount = "omitted_user_info_entry_count"
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
        let omittedUserInfoEntryCount = try container.decodeIfPresent(
            Int.self,
            forKey: .omittedUserInfoEntryCount
        ) ?? 0
        guard omittedUserInfoEntryCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .omittedUserInfoEntryCount,
                in: container,
                debugDescription: "Invalid omitted error metadata count."
            )
        }
        self.frames = frames
        self.omittedUserInfoEntryCount = omittedUserInfoEntryCount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frames, forKey: .frames)
        if omittedUserInfoEntryCount > 0 {
            try container.encode(
                omittedUserInfoEntryCount,
                forKey: .omittedUserInfoEntryCount
            )
        }
    }
}

struct MirmirDiagnosticSourceLocation: Codable, Equatable, Sendable {
    let fileID: String
    let function: String?
    let line: UInt

    init(fileID: String, function: String? = nil, line: UInt) throws {
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
        self.function = function.map { String($0.prefix(512)) }
        self.line = line
    }

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case function
        case line
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                fileID: container.decode(String.self, forKey: .fileID),
                function: container.decodeIfPresent(
                    String.self,
                    forKey: .function
                ),
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
    static let maximumFields = 128

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
        "auth",
        "bookmark",
        "bookmark_data",
        "cookie",
        "credential",
        "credentials",
        "passcode",
        "passwd",
        "password",
        "pwd",
        "secret",
        "token",
        "api_key",
        "authorization"
    ]
    private static let privateKeyWords: Set<String> = [
        "auth", "bookmark", "cookie", "credential", "credentials",
        "passcode", "passwd", "password", "passphrase", "pwd",
        "secret", "secrets", "token", "tokens",
        "authorization"
    ]
    private static let privateCollapsedKeys: Set<String> = [
        "accesskey", "apikey", "privatekey", "secretkey", "accesstoken",
        "refreshtoken", "authtoken", "oauthtoken", "sessiontoken",
        "idtoken", "clienttoken", "apitoken", "clientsecret"
    ]
    private static let privateKeyWordPairs: Set<String> = [
        "access:key", "api:key", "private:key"
    ]
    private static let privateCollapsedKeySuffixes = privateKeyWords.union(
        privateCollapsedKeys
    )
    private static let privateCollapsedKeyPrefixes = privateKeyWords.union(
        privateCollapsedKeys
    )
    private static let safeCollapsedLeadingWords = [
        "tokenization", "secretariat", "authentication"
    ]
    private static let credentialExpression = Result {
        try NSRegularExpression(
            pattern: #"""
            (?ix)
            (?:
                (?<![A-Za-z0-9])
                (?:
                    sk[-_](?:live|test|proj)[-_][A-Za-z0-9_./+=:-]+
                    |sk-[A-Za-z0-9_-]{16,}
                    |gh[pousr]_[A-Za-z0-9_]{8,}
                    |github_pat_[A-Za-z0-9_]{8,}
                    |xox[baprs]-[A-Za-z0-9-]+
                    |AKIA[0-9A-Z]{16}
                    |eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}
                )
                |\b(?:bearer|basic)\s+[A-Za-z0-9_./+=:-]+
                |-----BEGIN(?:[ A-Z]+)?PRIVATE\s+KEY-----
                |://[^\s/:@]+:[^\s/@]+@
                |(?<![A-Za-z0-9_])["']?
                (
                    [A-Za-z_][A-Za-z0-9_-]*
                    (?:
                        (?:[\x20\t]+|[./])
                            [A-Za-z_][A-Za-z0-9_-]*
                        |\[[\x20\t]*["']?
                            [A-Za-z_][A-Za-z0-9_-]*
                            ["']?[\x20\t]*\]
                    ){0,7}
                )
                ["']?\s*[:=](?!//)
            )
            """#
        )
    }

    static func permitsUserInfoKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        let collapsed = normalized.filter { $0.isLetter || $0.isNumber }
        let keyWords = words(in: key)
        let wordPairs = zip(keyWords, keyWords.dropFirst()).map {
            "\($0):\($1)"
        }
        return !privateKeys.contains(normalized)
            && privateKeyWords.isDisjoint(with: keyWords)
            && privateKeyWordPairs.isDisjoint(with: wordPairs)
            && !privateCollapsedKeys.contains(collapsed)
            && !privateCollapsedKeySuffixes.contains(where: {
                collapsed.hasSuffix($0)
            })
            && !hasPrivateCollapsedPrefix(collapsed)
    }

    private static func hasPrivateCollapsedPrefix(_ key: String) -> Bool {
        let candidate = safeCollapsedLeadingWords.first(where: {
            key.hasPrefix($0)
        }).map {
            String(key.dropFirst($0.count))
        } ?? key
        return privateCollapsedKeyPrefixes.contains(where: {
            candidate.hasPrefix($0)
        })
    }

    private static func words(in key: String) -> [String] {
        let characters = Array(key)
        var words: [String] = []
        var word = ""

        func appendWord() {
            guard !word.isEmpty else { return }
            words.append(word.lowercased())
            word.removeAll(keepingCapacity: true)
        }

        for index in characters.indices {
            let character = characters[index]
            guard character.isLetter || character.isNumber else {
                appendWord()
                continue
            }
            if !word.isEmpty, character.isUppercase {
                let previous = characters[characters.index(before: index)]
                let next = characters.index(after: index) < characters.endIndex
                    ? characters[characters.index(after: index)]
                    : nil
                if previous.isLowercase || previous.isNumber
                    || (previous.isUppercase && next?.isLowercase == true) {
                    appendWord()
                }
            }
            word.append(character)
        }
        appendWord()
        return words
    }

    static func sanitizedForensicString(_ value: Any) -> String? {
        let rendered: String
        switch value {
        case let url as URL:
            rendered = url.isFileURL ? url.path : url.absoluteString
        case let string as String:
            rendered = string
        case let number as NSNumber:
            rendered = number.stringValue
        case let value as CustomStringConvertible:
            rendered = value.description
        default:
            return nil
        }
        guard rendered.utf8.count <= 16_384,
              !rendered.unicodeScalars.contains(where: { $0.value < 0x20 }),
              (try? containsCredential(rendered)) != true else {
            return nil
        }
        return rendered
    }

    static func validateJSON(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        try validateJSONValue(object)
    }

    static func validateDocumentText(_ value: String) throws {
        guard try !containsCredential(value) else {
            throw MirmirDiagnosticValidationError.privacyViolation
        }
    }

    private static func validateJSONValue(_ value: Any) throws {
        switch value {
        case let object as [String: Any]:
            for (key, child) in object {
                guard permitsUserInfoKey(key) else {
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
                  try !containsCredential(string) else {
                throw MirmirDiagnosticValidationError.privacyViolation
            }
        default:
            break
        }
    }

    private static func containsCredential(_ value: String) throws -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let expression = try credentialExpression.get()
        var containsCredential = false
        expression.enumerateMatches(in: value, range: range) {
            match,
            _,
            stop in
            guard let match else { return }
            let assignmentKeyRange = match.range(at: 1)
            guard assignmentKeyRange.location != NSNotFound,
                  let assignmentKeyRange = Range(
                    assignmentKeyRange,
                    in: value
                  ) else {
                containsCredential = true
                stop.pointee = true
                return
            }
            if !permitsUserInfoKey(String(value[assignmentKeyRange])) {
                containsCredential = true
                stop.pointee = true
            }
        }
        return containsCredential
    }
}
