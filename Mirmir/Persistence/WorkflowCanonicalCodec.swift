import CryptoKit
import Foundation

enum WorkflowCanonicalCodecError: Error, Equatable, LocalizedError {
    case nonCanonicalEncoding
    case payloadHashMismatch
    case eventHashMismatch
    case snapshotBodyHashMismatch
    case snapshotAnchorMismatch
    case unsupportedSchemaVersion(type: String, actual: UInt16, current: UInt16)

    var errorDescription: String? {
        switch self {
        case .nonCanonicalEncoding:
            "Stored JSON is not the canonical encoding for its decoded value."
        case .payloadHashMismatch:
            "The workflow event payload hash does not match its canonical payload."
        case .eventHashMismatch:
            "The workflow event hash does not match its canonical hash material."
        case .snapshotBodyHashMismatch:
            "The workflow snapshot body hash is invalid."
        case .snapshotAnchorMismatch:
            "The workflow snapshot state does not match its declared journal head."
        case let .unsupportedSchemaVersion(type, actual, current):
            "Unsupported \(type) schema version \(actual); current version is \(current)."
        }
    }
}

/// Minimal, fail-closed discriminator used before selecting a canonical
/// persistence decoder.  Durable migrations always decode and re-encode the
/// complete versioned document after probing this field; the probe is never
/// treated as validation by itself.
struct WorkflowSchemaVersionProbeV4: Decodable, Sendable {
    let schemaVersion: UInt16
}

enum WorkflowJournalPrefixDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowSnapshotBodyDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowJournalFrameDigestPurpose: WorkflowDigestPurpose {}
enum WorkflowJournalFrameHeaderDigestPurpose: WorkflowDigestPurpose {}

typealias WorkflowJournalPrefixHash =
    WorkflowDigest<WorkflowJournalPrefixDigestPurpose>
typealias WorkflowSnapshotBodyHash =
    WorkflowDigest<WorkflowSnapshotBodyDigestPurpose>
typealias WorkflowJournalFrameHash =
    WorkflowDigest<WorkflowJournalFrameDigestPurpose>
typealias WorkflowJournalFrameHeaderHash =
    WorkflowDigest<WorkflowJournalFrameHeaderDigestPurpose>

struct WorkflowEventDraft: Equatable, Hashable, Sendable {
    let eventID: WorkflowEventID
    let commandID: WorkflowCommandID
    let scope: WorkflowEventScope
    let jobBinding: WorkflowJobBinding?
    let attemptID: WorkflowAttemptID?
    let event: WorkflowEvent

    init(
        eventID: WorkflowEventID,
        commandID: WorkflowCommandID,
        scope: WorkflowEventScope,
        jobBinding: WorkflowJobBinding?,
        attemptID: WorkflowAttemptID?,
        event: WorkflowEvent
    ) {
        self.eventID = eventID
        self.commandID = commandID
        self.scope = scope
        self.jobBinding = jobBinding
        self.attemptID = attemptID
        self.event = event
    }
}

struct WorkflowSnapshotBody: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let storeID: WorkflowIdentifier<WorkflowStoreIDPurpose>
    let generation: UInt64
    let journalByteCount: UInt64
    let journalPrefixHash: WorkflowJournalPrefixHash
    let headSequence: UInt64?
    let headEventHash: WorkflowEventHash?
    let state: WorkflowState

    init(
        storeID: WorkflowIdentifier<WorkflowStoreIDPurpose>,
        generation: UInt64,
        journalByteCount: UInt64,
        journalPrefixHash: WorkflowJournalPrefixHash,
        state: WorkflowState
    ) throws {
        guard
            state.lastEventSequence == nil
                ? state.lastEventHash == nil
                : state.lastEventHash != nil
        else {
            throw WorkflowCanonicalCodecError.snapshotAnchorMismatch
        }

        schemaVersion = Self.currentSchemaVersion
        self.storeID = storeID
        self.generation = generation
        self.journalByteCount = journalByteCount
        self.journalPrefixHash = journalPrefixHash
        headSequence = state.lastEventSequence
        headEventHash = state.lastEventHash
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storeID
        case generation
        case journalByteCount
        case journalPrefixHash
        case headSequence
        case headEventHash
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowCanonicalCodecError.unsupportedSchemaVersion(
                type: "WorkflowSnapshotBody",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }

        let storeID = try container.decode(
            WorkflowIdentifier<WorkflowStoreIDPurpose>.self,
            forKey: .storeID
        )
        let generation = try container.decode(UInt64.self, forKey: .generation)
        let journalByteCount = try container.decode(
            UInt64.self,
            forKey: .journalByteCount
        )
        let journalPrefixHash = try container.decode(
            WorkflowJournalPrefixHash.self,
            forKey: .journalPrefixHash
        )
        let headSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .headSequence
        )
        let headEventHash = try container.decodeIfPresent(
            WorkflowEventHash.self,
            forKey: .headEventHash
        )
        let state = try container.decode(WorkflowState.self, forKey: .state)
        guard
            headSequence == state.lastEventSequence,
            headEventHash == state.lastEventHash
        else {
            throw WorkflowCanonicalCodecError.snapshotAnchorMismatch
        }

        try self.init(
            storeID: storeID,
            generation: generation,
            journalByteCount: journalByteCount,
            journalPrefixHash: journalPrefixHash,
            state: state
        )
    }
}

enum WorkflowStoreIDPurpose: WorkflowIdentifierPurpose {}
typealias WorkflowStoreID = WorkflowIdentifier<WorkflowStoreIDPurpose>

struct WorkflowSnapshotDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 2

    let schemaVersion: UInt16
    let bodyHash: WorkflowSnapshotBodyHash
    let body: WorkflowSnapshotBody

    init(bodyHash: WorkflowSnapshotBodyHash, body: WorkflowSnapshotBody) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bodyHash
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowCanonicalCodecError.unsupportedSchemaVersion(
                type: "WorkflowSnapshotDocument",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        self.init(
            bodyHash: try container.decode(
                WorkflowSnapshotBodyHash.self,
                forKey: .bodyHash
            ),
            body: try container.decode(
                WorkflowSnapshotBody.self,
                forKey: .body
            )
        )
    }
}

/// Deployed snapshot envelope retained solely as a migration input.  The
/// body schema and body hash remain immutable, so upgrading the envelope does
/// not reinterpret reducer state or weaken the journal anchor.
struct WorkflowSnapshotDocumentV1: Codable, Equatable, Sendable {
    static let schemaVersionValue: UInt16 = 1

    let schemaVersion: UInt16
    let bodyHash: WorkflowSnapshotBodyHash
    let body: WorkflowSnapshotBody

    init(bodyHash: WorkflowSnapshotBodyHash, body: WorkflowSnapshotBody) {
        schemaVersion = Self.schemaVersionValue
        self.bodyHash = bodyHash
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bodyHash
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.schemaVersionValue else {
            throw WorkflowCanonicalCodecError.unsupportedSchemaVersion(
                type: "WorkflowSnapshotDocumentV1",
                actual: schemaVersion,
                current: Self.schemaVersionValue
            )
        }
        self.init(
            bodyHash: try container.decode(
                WorkflowSnapshotBodyHash.self,
                forKey: .bodyHash
            ),
            body: try container.decode(
                WorkflowSnapshotBody.self,
                forKey: .body
            )
        )
    }
}

struct WorkflowSnapshotMigrationResultV4: Equatable, Sendable {
    let document: WorkflowSnapshotDocument
    let migratedFromSchemaVersion: UInt16?
}

struct WorkflowCanonicalCodec: Sendable {
    private static let payloadDomain = Data(
        "Mirmir.WorkflowEvent.Payload.v1\u{0}".utf8
    )
    private static let eventDomain = Data(
        "Mirmir.WorkflowEvent.Envelope.v1\u{0}".utf8
    )
    private static let prefixDomain = Data(
        "Mirmir.WorkflowJournal.Prefix.v1\u{0}".utf8
    )
    private static let snapshotDomain = Data(
        "Mirmir.WorkflowSnapshot.Body.v1\u{0}".utf8
    )
    private static let frameDomain = Data(
        "Mirmir.WorkflowJournal.Frame.v1\u{0}".utf8
    )
    private static let frameHeaderDomain = Data(
        "Mirmir.WorkflowJournal.FrameHeader.v1\u{0}".utf8
    )

    func seal(
        _ draft: WorkflowEventDraft,
        sequence: UInt64,
        previousEventHash: WorkflowEventHash?
    ) throws -> WorkflowEventEnvelope {
        let payloadData = try canonicalData(draft.event)
        let payloadHash = try WorkflowPayloadHash(
            Self.domainSeparatedSHA256(
                domain: Self.payloadDomain,
                components: [payloadData]
            )
        )
        let material = WorkflowEventHashMaterial(
            envelopeSchemaVersion: WorkflowEventEnvelope.currentSchemaVersion,
            sequence: sequence,
            eventID: draft.eventID,
            commandID: draft.commandID,
            scope: draft.scope,
            jobBinding: draft.jobBinding,
            attemptID: draft.attemptID,
            previousEventHash: previousEventHash,
            payloadHash: payloadHash
        )
        let materialData = try canonicalData(material)
        let eventHash = try WorkflowEventHash(
            Self.domainSeparatedSHA256(
                domain: Self.eventDomain,
                components: [materialData, payloadData]
            )
        )
        return try WorkflowEventEnvelope(
            sequence: sequence,
            eventID: draft.eventID,
            commandID: draft.commandID,
            scope: draft.scope,
            jobBinding: draft.jobBinding,
            attemptID: draft.attemptID,
            previousEventHash: previousEventHash,
            payloadHash: payloadHash,
            eventHash: eventHash,
            event: draft.event
        )
    }

    func verify(_ envelope: WorkflowEventEnvelope) throws {
        let payloadData = try canonicalData(envelope.event)
        let expectedPayloadHash = try WorkflowPayloadHash(
            Self.domainSeparatedSHA256(
                domain: Self.payloadDomain,
                components: [payloadData]
            )
        )
        guard expectedPayloadHash == envelope.payloadHash else {
            throw WorkflowCanonicalCodecError.payloadHashMismatch
        }

        let material = WorkflowEventHashMaterial(
            envelopeSchemaVersion: envelope.schemaVersion,
            sequence: envelope.sequence,
            eventID: envelope.eventID,
            commandID: envelope.commandID,
            scope: envelope.scope,
            jobBinding: envelope.jobBinding,
            attemptID: envelope.attemptID,
            previousEventHash: envelope.previousEventHash,
            payloadHash: envelope.payloadHash
        )
        let expectedEventHash = try WorkflowEventHash(
            Self.domainSeparatedSHA256(
                domain: Self.eventDomain,
                components: [try canonicalData(material), payloadData]
            )
        )
        guard expectedEventHash == envelope.eventHash else {
            throw WorkflowCanonicalCodecError.eventHashMismatch
        }
    }

    func canonicalEnvelopeData(
        _ envelope: WorkflowEventEnvelope
    ) throws -> Data {
        try verify(envelope)
        return try canonicalData(envelope)
    }

    func decodeCanonicalEnvelope(_ data: Data) throws -> WorkflowEventEnvelope {
        let envelope: WorkflowEventEnvelope = try decodeCanonical(
            WorkflowEventEnvelope.self,
            from: data
        )
        try verify(envelope)
        return envelope
    }

    func journalPrefixHash(_ data: Data) throws -> WorkflowJournalPrefixHash {
        try WorkflowJournalPrefixHash(
            Self.domainSeparatedSHA256(
                domain: Self.prefixDomain,
                components: [data]
            )
        )
    }

    func journalFrameHash(_ data: Data) throws -> WorkflowJournalFrameHash {
        try WorkflowJournalFrameHash(
            Self.domainSeparatedSHA256(
                domain: Self.frameDomain,
                components: [data]
            )
        )
    }

    func journalFrameHeaderHash(
        _ data: Data
    ) throws -> WorkflowJournalFrameHeaderHash {
        try WorkflowJournalFrameHeaderHash(
            Self.domainSeparatedSHA256(
                domain: Self.frameHeaderDomain,
                components: [data]
            )
        )
    }

    func makeSnapshotDocument(
        storeID: WorkflowStoreID,
        generation: UInt64,
        journalData: Data,
        state: WorkflowState
    ) throws -> WorkflowSnapshotDocument {
        let body = try WorkflowSnapshotBody(
            storeID: storeID,
            generation: generation,
            journalByteCount: UInt64(journalData.count),
            journalPrefixHash: journalPrefixHash(journalData),
            state: state
        )
        let bodyHash = try WorkflowSnapshotBodyHash(
            Self.domainSeparatedSHA256(
                domain: Self.snapshotDomain,
                components: [try canonicalData(body)]
            )
        )
        return WorkflowSnapshotDocument(bodyHash: bodyHash, body: body)
    }

    func canonicalSnapshotData(
        _ document: WorkflowSnapshotDocument
    ) throws -> Data {
        try verifySnapshotDocument(document)
        return try canonicalData(document)
    }

    func decodeCanonicalSnapshot(
        _ data: Data
    ) throws -> WorkflowSnapshotDocument {
        try decodeCanonicalSnapshotMigrating(data).document
    }

    func decodeCanonicalSnapshotMigrating(
        _ data: Data
    ) throws -> WorkflowSnapshotMigrationResultV4 {
        let schema = try JSONDecoder().decode(
            WorkflowSchemaVersionProbeV4.self,
            from: data
        ).schemaVersion
        switch schema {
        case WorkflowSnapshotDocument.currentSchemaVersion:
            let document: WorkflowSnapshotDocument = try decodeCanonical(
                WorkflowSnapshotDocument.self,
                from: data
            )
            try verifySnapshotDocument(document)
            return WorkflowSnapshotMigrationResultV4(
                document: document,
                migratedFromSchemaVersion: nil
            )
        case WorkflowSnapshotDocumentV1.schemaVersionValue:
            let legacy: WorkflowSnapshotDocumentV1 = try decodeCanonical(
                WorkflowSnapshotDocumentV1.self,
                from: data
            )
            try verifySnapshotBodyHash(
                bodyHash: legacy.bodyHash,
                body: legacy.body
            )
            let migrated = WorkflowSnapshotDocument(
                bodyHash: legacy.bodyHash,
                body: legacy.body
            )
            try verifySnapshotDocument(migrated)
            return WorkflowSnapshotMigrationResultV4(
                document: migrated,
                migratedFromSchemaVersion: legacy.schemaVersion
            )
        default:
            throw WorkflowCanonicalCodecError.unsupportedSchemaVersion(
                type: "WorkflowSnapshotDocument",
                actual: schema,
                current: WorkflowSnapshotDocument.currentSchemaVersion
            )
        }
    }

    func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    func decodeCanonical<Value: Codable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        let value = try JSONDecoder().decode(type, from: data)
        guard try canonicalData(value) == data else {
            throw WorkflowCanonicalCodecError.nonCanonicalEncoding
        }
        return value
    }

    static func rawSHA256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func verifySnapshotDocument(
        _ document: WorkflowSnapshotDocument
    ) throws {
        guard
            document.body.headSequence == document.body.state.lastEventSequence,
            document.body.headEventHash == document.body.state.lastEventHash
        else {
            throw WorkflowCanonicalCodecError.snapshotAnchorMismatch
        }
        try verifySnapshotBodyHash(
            bodyHash: document.bodyHash,
            body: document.body
        )
    }

    private func verifySnapshotBodyHash(
        bodyHash: WorkflowSnapshotBodyHash,
        body: WorkflowSnapshotBody
    ) throws {
        let expectedHash = try WorkflowSnapshotBodyHash(
            Self.domainSeparatedSHA256(
                domain: Self.snapshotDomain,
                components: [try canonicalData(body)]
            )
        )
        guard expectedHash == bodyHash else {
            throw WorkflowCanonicalCodecError.snapshotBodyHashMismatch
        }
    }

    private static func domainSeparatedSHA256(
        domain: Data,
        components: [Data]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: domain)
        for component in components {
            var length = UInt64(component.count).bigEndian
            withUnsafeBytes(of: &length) { bytes in
                hasher.update(bufferPointer: bytes)
            }
            hasher.update(data: component)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private struct WorkflowEventHashMaterial: Codable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let envelopeSchemaVersion: UInt16
    let sequence: UInt64
    let eventID: WorkflowEventID
    let commandID: WorkflowCommandID
    let scope: WorkflowEventScope
    let jobBinding: WorkflowJobBinding?
    let attemptID: WorkflowAttemptID?
    let previousEventHash: WorkflowEventHash?
    let payloadHash: WorkflowPayloadHash

    init(
        envelopeSchemaVersion: UInt16,
        sequence: UInt64,
        eventID: WorkflowEventID,
        commandID: WorkflowCommandID,
        scope: WorkflowEventScope,
        jobBinding: WorkflowJobBinding?,
        attemptID: WorkflowAttemptID?,
        previousEventHash: WorkflowEventHash?,
        payloadHash: WorkflowPayloadHash
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.envelopeSchemaVersion = envelopeSchemaVersion
        self.sequence = sequence
        self.eventID = eventID
        self.commandID = commandID
        self.scope = scope
        self.jobBinding = jobBinding
        self.attemptID = attemptID
        self.previousEventHash = previousEventHash
        self.payloadHash = payloadHash
    }
}
