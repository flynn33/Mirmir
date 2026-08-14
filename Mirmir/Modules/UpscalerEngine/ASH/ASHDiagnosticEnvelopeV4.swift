import Foundation

enum ASHDiagnosticEnvelopeV4Error: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case invalidIdentifier(field: String, value: String)
    case invalidFieldValue(String)
    case nonCanonicalFieldOrdering
    case nonCanonicalParentOrdering
    case invalidFrameIndex(Int64)
}

enum ASHRuntimeEventKindV4: String, Codable, Hashable, Sendable {
    case observation
    case planning
    case preparation
    case execution
    case verification
    case recovery
    case containment
}

enum ASHDiagnosticSeverityV4: String, Codable, Hashable, Sendable {
    case trace
    case information
    case warning
    case error
    case fatal
}

enum ASHRecoveryDispositionV4: String, Codable, Hashable, Sendable {
    case none
    case retryable
    case resetHistory = "reset_history"
    case quarantineArtifact = "quarantine_artifact"
    case failJob = "fail_job"
    case safeHalt = "safe_halt"
}

enum ASHDiagnosticValueKindV4: String, Codable, Hashable, Sendable {
    case boolean
    case digest
    case identifier
    case integer
    case rational
    case text
}

struct ASHDiagnosticValueV4: Codable, Equatable, Hashable, Sendable {
    let kind: ASHDiagnosticValueKindV4
    let boolean: Bool?
    let digest: ASHSHA256V4?
    let integer: Int64?
    let rational: ExactRationalV4?
    let string: String?

    static func boolean(_ value: Bool) -> Self {
        Self(
            kind: .boolean,
            boolean: value,
            digest: nil,
            integer: nil,
            rational: nil,
            string: nil
        )
    }

    static func digest(_ value: ASHSHA256V4) -> Self {
        Self(
            kind: .digest,
            boolean: nil,
            digest: value,
            integer: nil,
            rational: nil,
            string: nil
        )
    }

    static func identifier(_ value: String) throws -> Self {
        guard ASHStableIdentifierV4.isValid(value) else {
            throw ASHDiagnosticEnvelopeV4Error.invalidIdentifier(
                field: "diagnostic value",
                value: value
            )
        }
        return Self(
            kind: .identifier,
            boolean: nil,
            digest: nil,
            integer: nil,
            rational: nil,
            string: value
        )
    }

    static func integer(_ value: Int64) -> Self {
        Self(
            kind: .integer,
            boolean: nil,
            digest: nil,
            integer: value,
            rational: nil,
            string: nil
        )
    }

    static func rational(_ value: ExactRationalV4) -> Self {
        Self(
            kind: .rational,
            boolean: nil,
            digest: nil,
            integer: nil,
            rational: value,
            string: nil
        )
    }

    static func text(_ value: String) throws -> Self {
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }),
              value.utf8.count <= 4_096 else {
            throw ASHDiagnosticEnvelopeV4Error.invalidFieldValue(value)
        }
        return Self(
            kind: .text,
            boolean: nil,
            digest: nil,
            integer: nil,
            rational: nil,
            string: value
        )
    }

    func validate() throws {
        let populated = [
            boolean != nil,
            digest != nil,
            integer != nil,
            rational != nil,
            string != nil
        ].filter { $0 }.count
        guard populated == 1 else {
            throw ASHDiagnosticEnvelopeV4Error.invalidFieldValue(kind.rawValue)
        }
        let matchesKind: Bool = switch kind {
        case .boolean: boolean != nil
        case .digest: digest != nil
        case .integer: integer != nil
        case .rational: rational != nil
        case .identifier:
            string.map(ASHStableIdentifierV4.isValid) ?? false
        case .text:
            string.map {
                !$0.unicodeScalars.contains(where: { $0.value == 0 })
                    && $0.utf8.count <= 4_096
            } ?? false
        }
        guard matchesKind else {
            throw ASHDiagnosticEnvelopeV4Error.invalidFieldValue(kind.rawValue)
        }
    }
}

struct ASHDiagnosticFieldV4: Codable, Comparable, Equatable, Hashable,
    Sendable {
    let key: String
    let value: ASHDiagnosticValueV4

    init(key: String, value: ASHDiagnosticValueV4) throws {
        guard ASHStableIdentifierV4.isValid(key) else {
            throw ASHDiagnosticEnvelopeV4Error.invalidIdentifier(
                field: "field key",
                value: key
            )
        }
        try value.validate()
        self.key = key
        self.value = value
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }
}

struct ASHRuntimeEventEnvelopeV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.runtime-event-envelope.v4.1"
    static let identityDomain = "ash-runtime-event-envelope-v4"

    let schemaID: String
    let attemptID: String
    let ordinal: UInt64
    let kind: ASHRuntimeEventKindV4
    let severity: ASHDiagnosticSeverityV4
    let code: String
    let recoveryDisposition: ASHRecoveryDispositionV4
    let parentEventSHA256: [ASHSHA256V4]
    let planSHA256: ASHSHA256V4?
    let runtimeManifestSHA256: ASHSHA256V4?
    let trackID: String?
    let frameIndex: Int64?
    let presentationTime: ExactRationalV4?
    let fields: [ASHDiagnosticFieldV4]

    init(
        attemptID: String,
        ordinal: UInt64,
        kind: ASHRuntimeEventKindV4,
        severity: ASHDiagnosticSeverityV4,
        code: String,
        recoveryDisposition: ASHRecoveryDispositionV4,
        parentEventSHA256: [ASHSHA256V4],
        planSHA256: ASHSHA256V4?,
        runtimeManifestSHA256: ASHSHA256V4?,
        trackID: String?,
        frameIndex: Int64?,
        presentationTime: ExactRationalV4?,
        fields: [ASHDiagnosticFieldV4]
    ) throws {
        self.schemaID = Self.currentSchemaID
        self.attemptID = attemptID
        self.ordinal = ordinal
        self.kind = kind
        self.severity = severity
        self.code = code
        self.recoveryDisposition = recoveryDisposition
        self.parentEventSHA256 = parentEventSHA256
        self.planSHA256 = planSHA256
        self.runtimeManifestSHA256 = runtimeManifestSHA256
        self.trackID = trackID
        self.frameIndex = frameIndex
        self.presentationTime = presentationTime
        self.fields = fields
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID else {
            throw ASHDiagnosticEnvelopeV4Error.unsupportedSchema(schemaID)
        }
        for (field, value) in [
            ("attempt ID", attemptID),
            ("diagnostic code", code)
        ] where !ASHStableIdentifierV4.isValid(value) {
            throw ASHDiagnosticEnvelopeV4Error.invalidIdentifier(
                field: field,
                value: value
            )
        }
        if let trackID, !ASHStableIdentifierV4.isValid(trackID) {
            throw ASHDiagnosticEnvelopeV4Error.invalidIdentifier(
                field: "track ID",
                value: trackID
            )
        }
        if let frameIndex, frameIndex < 0 {
            throw ASHDiagnosticEnvelopeV4Error.invalidFrameIndex(frameIndex)
        }
        guard parentEventSHA256 == Array(Set(parentEventSHA256)).sorted() else {
            throw ASHDiagnosticEnvelopeV4Error.nonCanonicalParentOrdering
        }
        guard fields == fields.sorted(),
              Set(fields.map(\.key)).count == fields.count else {
            throw ASHDiagnosticEnvelopeV4Error.nonCanonicalFieldOrdering
        }
        try fields.forEach { try $0.value.validate() }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try validate()
            return try ASHCanonicalJSONV4.hash(
                self,
                domain: Self.identityDomain
            )
        }
    }
}

private enum ASHStableIdentifierV4 {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 160 else { return false }
        return value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5a).contains(byte)
                || (0x61...0x7a).contains(byte)
                || [0x2d, 0x2e, 0x3a, 0x5f].contains(byte)
        }
    }
}
