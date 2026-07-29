import Foundation

enum MirmirDiagnosticValidationError: Error, Equatable, Sendable {
    case invalidToken(field: String)
    case invalidSHA256(field: String)
    case invalidDimensions
    case invalidRational
    case invalidSourceLocation
    case duplicateField(String)
    case tooManyFields(maximum: Int)
    case invalidTimestamp
    case invalidRecordSchema
    case invalidErrorIdentity
    case privacyViolation
}

enum MirmirDiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
}

struct MirmirDiagnosticToken:
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible {
    static let maximumBytes = 96

    let rawValue: String

    init(_ rawValue: String, field: String) throws {
        guard Self.isValid(rawValue) else {
            throw MirmirDiagnosticValidationError.invalidToken(field: field)
        }
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value, field: decoder.codingPath.last?.stringValue ?? "token")
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid diagnostic token."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              value.utf8.allSatisfy({ byte in
                  switch byte {
                  case 48...57, 97...122:
                      return true
                  case 45, 46, 58, 95:
                      return true
                  default:
                      return false
                  }
              }) else {
            return false
        }
        return value.first?.isASCII == true
    }
}

struct MirmirDiagnosticID: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }

    init(_ rawValue: String, field: String) throws {
        guard let uuid = UUID(uuidString: rawValue) else {
            throw MirmirDiagnosticValidationError.invalidToken(field: field)
        }
        self.init(uuid)
    }

    var description: String {
        rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value, field: decoder.codingPath.last?.stringValue ?? "id")
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid diagnostic identifier."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct MirmirDiagnosticSHA256:
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String, field: String) throws {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw MirmirDiagnosticValidationError.invalidSHA256(field: field)
        }
        self.rawValue = rawValue
    }

    var description: String {
        rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value, field: decoder.codingPath.last?.stringValue ?? "sha256")
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid diagnostic SHA-256."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum MirmirDiagnosticResourceLocation: String, Codable, CaseIterable, Sendable {
    case applicationSupport = "application_support"
    case userSelected = "user_selected"
    case removable
    case network
    case temporary
    case unknown
}

struct MirmirDiagnosticResourceReference: Codable, Equatable, Sendable {
    let role: MirmirDiagnosticToken
    let correlationID: MirmirDiagnosticID
    let fileExtension: MirmirDiagnosticToken?
    let location: MirmirDiagnosticResourceLocation

    init(
        role: String,
        correlationID: UUID,
        fileExtension: String?,
        location: MirmirDiagnosticResourceLocation
    ) throws {
        self.role = try MirmirDiagnosticToken(role, field: "resource_role")
        self.correlationID = MirmirDiagnosticID(correlationID)
        if let fileExtension {
            self.fileExtension = try MirmirDiagnosticToken(
                fileExtension.lowercased(),
                field: "resource_file_extension"
            )
        } else {
            self.fileExtension = nil
        }
        self.location = location
    }

    enum CodingKeys: String, CodingKey {
        case role
        case correlationID = "correlation_id"
        case fileExtension = "file_extension"
        case location
    }
}

struct MirmirDiagnosticFieldValue: Codable, Equatable, Sendable {
    private enum Kind: String, Codable {
        case boolean
        case signedInteger = "signed_integer"
        case unsignedInteger = "unsigned_integer"
        case identifier
        case sha256
        case dimensions
        case rational
        case durationMilliseconds = "duration_milliseconds"
        case byteCount = "byte_count"
        case resource
        case redacted
    }

    private let kind: Kind
    private let booleanValue: Bool?
    private let signedValue: Int64?
    private let unsignedValue: UInt64?
    private let identifierValue: MirmirDiagnosticToken?
    private let sha256Value: MirmirDiagnosticSHA256?
    private let width: Int?
    private let height: Int?
    private let numerator: Int64?
    private let denominator: Int64?
    private let resourceValue: MirmirDiagnosticResourceReference?

    static func boolean(_ value: Bool) -> Self {
        Self(kind: .boolean, booleanValue: value)
    }

    static func signedInteger(_ value: Int64) -> Self {
        Self(kind: .signedInteger, signedValue: value)
    }

    static func unsignedInteger(_ value: UInt64) -> Self {
        Self(kind: .unsignedInteger, unsignedValue: value)
    }

    static func identifier(_ value: String) throws -> Self {
        Self(
            kind: .identifier,
            identifierValue: try MirmirDiagnosticToken(
                value,
                field: "diagnostic_field_identifier"
            )
        )
    }

    static func sha256(_ value: String) throws -> Self {
        Self(
            kind: .sha256,
            sha256Value: try MirmirDiagnosticSHA256(
                value,
                field: "diagnostic_field_sha256"
            )
        )
    }

    static func dimensions(width: Int, height: Int) throws -> Self {
        guard width >= 0, height >= 0 else {
            throw MirmirDiagnosticValidationError.invalidDimensions
        }
        return Self(kind: .dimensions, width: width, height: height)
    }

    static func rational(numerator: Int64, denominator: Int64) throws -> Self {
        guard denominator > 0 else {
            throw MirmirDiagnosticValidationError.invalidRational
        }
        return Self(
            kind: .rational,
            numerator: numerator,
            denominator: denominator
        )
    }

    static func durationMilliseconds(_ value: UInt64) -> Self {
        Self(kind: .durationMilliseconds, unsignedValue: value)
    }

    static func byteCount(_ value: UInt64) -> Self {
        Self(kind: .byteCount, unsignedValue: value)
    }

    static func resource(_ value: MirmirDiagnosticResourceReference) -> Self {
        Self(kind: .resource, resourceValue: value)
    }

    static func redacting(_ privateValue: String) -> Self {
        withExtendedLifetime(privateValue) {}
        return Self(kind: .redacted)
    }

    static var redacted: Self {
        Self(kind: .redacted)
    }

    private init(
        kind: Kind,
        booleanValue: Bool? = nil,
        signedValue: Int64? = nil,
        unsignedValue: UInt64? = nil,
        identifierValue: MirmirDiagnosticToken? = nil,
        sha256Value: MirmirDiagnosticSHA256? = nil,
        width: Int? = nil,
        height: Int? = nil,
        numerator: Int64? = nil,
        denominator: Int64? = nil,
        resourceValue: MirmirDiagnosticResourceReference? = nil
    ) {
        self.kind = kind
        self.booleanValue = booleanValue
        self.signedValue = signedValue
        self.unsignedValue = unsignedValue
        self.identifierValue = identifierValue
        self.sha256Value = sha256Value
        self.width = width
        self.height = height
        self.numerator = numerator
        self.denominator = denominator
        self.resourceValue = resourceValue
    }

    var displayValue: String {
        switch kind {
        case .boolean:
            return booleanValue == true ? "true" : "false"
        case .signedInteger:
            return String(signedValue ?? 0)
        case .unsignedInteger, .durationMilliseconds, .byteCount:
            return String(unsignedValue ?? 0)
        case .identifier:
            return identifierValue?.rawValue ?? "untrusted"
        case .sha256:
            return sha256Value?.rawValue ?? "untrusted"
        case .dimensions:
            return "\(width ?? 0)x\(height ?? 0)"
        case .rational:
            return "\(numerator ?? 0)/\(denominator ?? 1)"
        case .resource:
            guard let resourceValue else { return "untrusted" }
            let fileExtension = resourceValue.fileExtension?.rawValue ?? "none"
            return [
                resourceValue.role.rawValue,
                resourceValue.correlationID.rawValue,
                fileExtension,
                resourceValue.location.rawValue
            ].joined(separator: ":")
        case .redacted:
            return "<redacted>"
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case booleanValue = "boolean_value"
        case signedValue = "signed_value"
        case unsignedValue = "unsigned_value"
        case identifierValue = "identifier_value"
        case sha256Value = "sha256_value"
        case width
        case height
        case numerator
        case denominator
        case resourceValue = "resource_value"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .boolean:
            self = .boolean(
                try container.decode(Bool.self, forKey: .booleanValue)
            )
        case .signedInteger:
            self = .signedInteger(
                try container.decode(Int64.self, forKey: .signedValue)
            )
        case .unsignedInteger:
            self = .unsignedInteger(
                try container.decode(UInt64.self, forKey: .unsignedValue)
            )
        case .identifier:
            self = Self(
                kind: kind,
                identifierValue: try container.decode(
                    MirmirDiagnosticToken.self,
                    forKey: .identifierValue
                )
            )
        case .sha256:
            self = Self(
                kind: kind,
                sha256Value: try container.decode(
                    MirmirDiagnosticSHA256.self,
                    forKey: .sha256Value
                )
            )
        case .dimensions:
            do {
                self = try .dimensions(
                    width: container.decode(Int.self, forKey: .width),
                    height: container.decode(Int.self, forKey: .height)
                )
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .width,
                    in: container,
                    debugDescription: "Invalid diagnostic dimensions."
                )
            }
        case .rational:
            do {
                self = try .rational(
                    numerator: container.decode(Int64.self, forKey: .numerator),
                    denominator: container.decode(Int64.self, forKey: .denominator)
                )
            } catch {
                throw DecodingError.dataCorruptedError(
                    forKey: .denominator,
                    in: container,
                    debugDescription: "Invalid diagnostic rational."
                )
            }
        case .durationMilliseconds:
            self = .durationMilliseconds(
                try container.decode(UInt64.self, forKey: .unsignedValue)
            )
        case .byteCount:
            self = .byteCount(
                try container.decode(UInt64.self, forKey: .unsignedValue)
            )
        case .resource:
            self = .resource(
                try container.decode(
                    MirmirDiagnosticResourceReference.self,
                    forKey: .resourceValue
                )
            )
        case .redacted:
            self = .redacted
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch kind {
        case .boolean:
            try container.encode(booleanValue, forKey: .booleanValue)
        case .signedInteger:
            try container.encode(signedValue, forKey: .signedValue)
        case .unsignedInteger, .durationMilliseconds, .byteCount:
            try container.encode(unsignedValue, forKey: .unsignedValue)
        case .identifier:
            try container.encode(identifierValue, forKey: .identifierValue)
        case .sha256:
            try container.encode(sha256Value, forKey: .sha256Value)
        case .dimensions:
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
        case .rational:
            try container.encode(numerator, forKey: .numerator)
            try container.encode(denominator, forKey: .denominator)
        case .resource:
            try container.encode(resourceValue, forKey: .resourceValue)
        case .redacted:
            break
        }
    }
}
