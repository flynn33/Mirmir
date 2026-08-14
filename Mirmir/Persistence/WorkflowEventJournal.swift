import Foundation

struct WorkflowJournalConfiguration: Equatable, Sendable {
    static let `default` = WorkflowJournalConfiguration(
        maximumEventBytes: 8 * 1_024 * 1_024,
        maximumJournalBytes: 512 * 1_024 * 1_024,
        maximumSnapshotBytes: 256 * 1_024 * 1_024
    )

    let maximumEventBytes: Int
    let maximumJournalBytes: Int
    let maximumSnapshotBytes: Int
}

enum WorkflowJournalCorruptionReason: String, Equatable, Sendable {
    case invalidHeaderMagic
    case unsupportedFrameVersion
    case nonzeroFrameFlags
    case invalidHeaderLength
    case headerHashMismatch
    case recordTooLarge
    case invalidFooter
    case frameHashMismatch
    case nonCanonicalEnvelope
    case invalidEnvelopeHash
    case sequenceMismatch
    case previousHashMismatch
    case reductionRejected
    case duplicatePhysicalEvent
}

enum WorkflowEventJournalError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case journalTooLarge(maximumBytes: Int)
    case corruptJournal(offset: Int, reason: WorkflowJournalCorruptionReason)
    case idempotencyConflict
    case snapshotGenerationExhausted
    case invalidStoreIdentity

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Workflow journal byte limits must be positive and internally consistent."
        case let .journalTooLarge(maximumBytes):
            "Workflow journal exceeds its \(maximumBytes)-byte limit."
        case let .corruptJournal(offset, reason):
            "Workflow journal corruption at byte \(offset): \(reason.rawValue)."
        case .idempotencyConflict:
            "A workflow event or command ID was reused with different content."
        case .snapshotGenerationExhausted:
            "The workflow snapshot generation counter is exhausted."
        case .invalidStoreIdentity:
            "The workflow store identity document is invalid."
        }
    }
}

enum WorkflowSnapshotRejectionReason: String, Equatable, Sendable {
    case unreadable
    case nonCanonical
    case hashMismatch
    case storeIdentityMismatch
    case byteCountOutOfBounds
    case journalPrefixMismatch
    case invalidTailAnchor
}

enum WorkflowSnapshotDisposition: Equatable, Sendable {
    case absent
    case applied(generation: UInt64)
    case rejected(WorkflowSnapshotRejectionReason)
}

enum WorkflowJournalTailDisposition: Equatable, Sendable {
    case clean
    case detected(discardableBytes: Int)
    case repaired(discardedBytes: Int, quarantineFileName: String)
}

struct WorkflowJournalRecoveryReport: Equatable, Sendable {
    let snapshot: WorkflowSnapshotDisposition
    let tail: WorkflowJournalTailDisposition
}

struct WorkflowJournalOpenResult: Equatable, Sendable {
    let storeID: WorkflowStoreID
    let state: WorkflowState
    let validJournalByteCount: UInt64
    let physicalJournalByteCount: UInt64
    let recovery: WorkflowJournalRecoveryReport
}

enum WorkflowJournalAppendDisposition: Equatable, Sendable {
    case committed
    case alreadyApplied
}

struct WorkflowJournalAppendResult: Equatable, Sendable {
    let disposition: WorkflowJournalAppendDisposition
    let envelope: WorkflowEventEnvelope?
    let receipt: WorkflowAppliedEventReceipt
    let state: WorkflowState
    let journalByteCount: UInt64
}

/// Cross-process safety comes from the permanent journal lock, not from actor
/// isolation. Every operation reloads and verifies the durable head while that
/// lock is held. No callback can suspend while the lock is owned.
struct WorkflowEventJournal: Sendable {
    let rootURL: URL

    private let fileSystem: any WorkflowDurableFileSystem
    private let configuration: WorkflowJournalConfiguration
    private let codec = WorkflowCanonicalCodec()
    private let frameCodec = WorkflowJournalFrameCodec()
    private let journalURL: URL
    private let snapshotURL: URL
    private let storeIdentityURL: URL
    private let journalLockURL: URL
    private let quarantineURL: URL
    private let jobLeaseManager: WorkflowJobLeaseManager

    init(
        rootURL: URL,
        fileSystem: (any WorkflowDurableFileSystem)? = nil,
        configuration: WorkflowJournalConfiguration = .default
    ) throws {
        guard
            configuration.maximumEventBytes > 0,
            configuration.maximumJournalBytes
                > configuration.maximumEventBytes,
            configuration.maximumSnapshotBytes > 0
        else {
            throw WorkflowEventJournalError.invalidConfiguration
        }

        let resolvedFileSystem: any WorkflowDurableFileSystem
        if let fileSystem {
            resolvedFileSystem = fileSystem
        } else {
            resolvedFileSystem = try WorkflowLocalDurableFileSystem(
                trustedRootURL: rootURL
            )
        }
        let standardizedRoot = rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        try resolvedFileSystem.ensureDirectory(standardizedRoot)
        let quarantineURL = standardizedRoot.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        try resolvedFileSystem.ensureDirectory(quarantineURL)

        self.rootURL = standardizedRoot
        self.fileSystem = resolvedFileSystem
        self.configuration = configuration
        journalURL = standardizedRoot.appendingPathComponent("events-v1.bin")
        snapshotURL = standardizedRoot.appendingPathComponent("snapshot-v1.json")
        storeIdentityURL = standardizedRoot.appendingPathComponent("store-v1.json")
        journalLockURL = standardizedRoot.appendingPathComponent("journal.lock")
        self.quarantineURL = quarantineURL
        jobLeaseManager = try WorkflowJobLeaseManager(
            rootURL: standardizedRoot,
            fileSystem: resolvedFileSystem
        )
    }

    func open(repairTornTail: Bool = true) throws -> WorkflowJournalOpenResult {
        try fileSystem.withExclusiveLock(at: journalLockURL) { transaction in
            let loaded = try loadLocked(
                fileSystem: transaction,
                repairTornTail: repairTornTail
            )
            return loaded.publicResult
        }
    }

    func append(_ draft: WorkflowEventDraft) throws -> WorkflowJournalAppendResult {
        try fileSystem.withExclusiveLock(at: journalLockURL) { transaction in
            let loaded = try loadLocked(
                fileSystem: transaction,
                repairTornTail: true
            )
            let nextSequence: UInt64
            if let lastSequence = loaded.state.lastEventSequence {
                guard lastSequence < UInt64.max else {
                    throw WorkflowReducerError.eventSequenceExhausted
                }
                nextSequence = lastSequence + 1
            } else {
                nextSequence = 0
            }
            let candidate = try codec.seal(
                draft,
                sequence: nextSequence,
                previousEventHash: loaded.state.lastEventHash
            )

            if let existing = loaded.state.appliedEvents.first(where: {
                $0.eventID == draft.eventID
            }) {
                guard Self.sameCommand(existing, candidate) else {
                    throw WorkflowEventJournalError.idempotencyConflict
                }
                return WorkflowJournalAppendResult(
                    disposition: .alreadyApplied,
                    envelope: nil,
                    receipt: existing,
                    state: loaded.state,
                    journalByteCount: UInt64(loaded.validJournalData.count)
                )
            }
            if let existing = loaded.state.appliedEvents.first(where: {
                $0.commandID == draft.commandID
            }) {
                guard Self.sameCommand(existing, candidate) else {
                    throw WorkflowEventJournalError.idempotencyConflict
                }
                return WorkflowJournalAppendResult(
                    disposition: .alreadyApplied,
                    envelope: nil,
                    receipt: existing,
                    state: loaded.state,
                    journalByteCount: UInt64(loaded.validJournalData.count)
                )
            }

            let nextState = try WorkflowReducer.reduce(
                loaded.state,
                applying: candidate
            )
            let frame = try frameCodec.makeFrame(
                envelope: candidate,
                codec: codec,
                maximumEventBytes: configuration.maximumEventBytes
            )
            let currentCount = loaded.validJournalData.count
            let (bodyEnd, bodyOverflow) = currentCount.addingReportingOverflow(
                frame.body.count
            )
            let (frameEnd, frameOverflow) = bodyEnd.addingReportingOverflow(
                frame.footer.count
            )
            guard
                !bodyOverflow,
                !frameOverflow,
                frameEnd <= configuration.maximumJournalBytes
            else {
                throw WorkflowEventJournalError.journalTooLarge(
                    maximumBytes: configuration.maximumJournalBytes
                )
            }

            // A body without its independently synced footer is uncommitted and
            // is the only class of tail that replay is allowed to truncate.
            try transaction.appendDurably(
                frame.body,
                to: journalURL,
                maximumFileBytes: configuration.maximumJournalBytes
            )
            try transaction.appendDurably(
                frame.footer,
                to: journalURL,
                maximumFileBytes: configuration.maximumJournalBytes
            )

            guard let receipt = nextState.appliedEvents.last else {
                preconditionFailure("A committed reduction must create a receipt.")
            }
            return WorkflowJournalAppendResult(
                disposition: .committed,
                envelope: candidate,
                receipt: receipt,
                state: nextState,
                journalByteCount: UInt64(frameEnd)
            )
        }
    }

    @discardableResult
    func writeSnapshot() throws -> WorkflowSnapshotDocument {
        try fileSystem.withExclusiveLock(at: journalLockURL) { transaction in
            let loaded = try loadLocked(
                fileSystem: transaction,
                repairTornTail: true
            )
            let nextGeneration: UInt64
            if let generation = loaded.appliedSnapshotGeneration {
                guard generation < UInt64.max else {
                    throw WorkflowEventJournalError.snapshotGenerationExhausted
                }
                nextGeneration = generation + 1
            } else {
                nextGeneration = 1
            }
            let document = try codec.makeSnapshotDocument(
                storeID: loaded.storeID,
                generation: nextGeneration,
                journalData: loaded.validJournalData,
                state: loaded.state
            )
            let data = try codec.canonicalSnapshotData(document)
            guard data.count <= configuration.maximumSnapshotBytes else {
                throw WorkflowDurableFileSystemError.fileTooLarge(
                    path: snapshotURL.path,
                    maximumBytes: configuration.maximumSnapshotBytes
                )
            }

            let snapshotExists = try transaction.regularFileExists(snapshotURL)
            if snapshotExists {
                try transaction.replaceAtomically(data, at: snapshotURL)
            } else {
                try transaction.writeNewAtomically(data, to: snapshotURL)
            }
            return document
        }
    }

    func acquireJobLease(
        for jobID: WorkflowJobID
    ) throws -> WorkflowExclusiveFileLease {
        try jobLeaseManager.acquireLease(for: jobID)
    }
}

private extension WorkflowEventJournal {
    struct LoadedJournal {
        let storeID: WorkflowStoreID
        let state: WorkflowState
        let validJournalData: Data
        let physicalJournalByteCount: Int
        let recovery: WorkflowJournalRecoveryReport
        let appliedSnapshotGeneration: UInt64?

        var publicResult: WorkflowJournalOpenResult {
            WorkflowJournalOpenResult(
                storeID: storeID,
                state: state,
                validJournalByteCount: UInt64(validJournalData.count),
                physicalJournalByteCount: UInt64(physicalJournalByteCount),
                recovery: recovery
            )
        }
    }

    func loadLocked(
        fileSystem: any WorkflowDurableFileSystem,
        repairTornTail: Bool
    ) throws -> LoadedJournal {
        let storeID = try loadOrCreateStoreID(fileSystem: fileSystem)
        try ensureJournalExists(fileSystem: fileSystem)
        try fileSystem.synchronizeRegularFileDurably(journalURL)
        let journalData = try fileSystem.readRegularFile(
            journalURL,
            maximumBytes: configuration.maximumJournalBytes
        )
        let physicalByteCount = journalData.count

        var snapshotDisposition: WorkflowSnapshotDisposition = .absent
        var snapshotGeneration: UInt64?
        var baseState = WorkflowState()
        var startOffset = 0

        if try fileSystem.regularFileExists(snapshotURL) {
            do {
                try fileSystem.synchronizeRegularFileDurably(snapshotURL)
                let snapshotData = try fileSystem.readRegularFile(
                    snapshotURL,
                    maximumBytes: configuration.maximumSnapshotBytes
                )
                let decoded = try codec.decodeCanonicalSnapshotMigrating(
                    snapshotData
                )
                let document = decoded.document
                guard document.body.storeID == storeID else {
                    throw SnapshotValidationFailure.storeIdentityMismatch
                }
                guard
                    document.body.journalByteCount <= UInt64(journalData.count),
                    document.body.journalByteCount <= UInt64(Int.max)
                else {
                    throw SnapshotValidationFailure.byteCountOutOfBounds
                }
                let byteCount = Int(document.body.journalByteCount)
                let prefix = journalData.prefix(byteCount)
                guard
                    try codec.journalPrefixHash(Data(prefix))
                        == document.body.journalPrefixHash
                else {
                    throw SnapshotValidationFailure.journalPrefixMismatch
                }
                baseState = document.body.state
                startOffset = byteCount
                snapshotGeneration = document.body.generation
                snapshotDisposition = .applied(
                    generation: document.body.generation
                )
                if decoded.migratedFromSchemaVersion != nil {
                    try fileSystem.replaceAtomically(
                        codec.canonicalSnapshotData(document),
                        at: snapshotURL
                    )
                }
            } catch let failure as SnapshotValidationFailure {
                snapshotDisposition = .rejected(failure.reason)
                baseState = WorkflowState()
                startOffset = 0
                snapshotGeneration = nil
            } catch let error as WorkflowCanonicalCodecError {
                snapshotDisposition = .rejected(
                    Self.snapshotReason(for: error)
                )
                baseState = WorkflowState()
                startOffset = 0
                snapshotGeneration = nil
            } catch let error as WorkflowDurableFileSystemError {
                switch error {
                case .fileTooLarge, .entryNotFound:
                    snapshotDisposition = .rejected(.unreadable)
                    baseState = WorkflowState()
                    startOffset = 0
                    snapshotGeneration = nil
                case .unsafePath, .entryAlreadyExists, .lockUnavailable,
                     .ioFailure, .indeterminate:
                    throw error
                }
            } catch {
                snapshotDisposition = .rejected(.unreadable)
                baseState = WorkflowState()
                startOffset = 0
                snapshotGeneration = nil
            }
        }

        let replay: WorkflowJournalReplayResult
        do {
            replay = try frameCodec.replay(
                journalData,
                startingAt: startOffset,
                initialState: baseState,
                codec: codec,
                maximumEventBytes: configuration.maximumEventBytes
            )
        } catch where startOffset > 0 {
            // A valid snapshot must point to a frame boundary. Fall back to the
            // authoritative journal before classifying the bytes as corrupt.
            snapshotDisposition = .rejected(.invalidTailAnchor)
            snapshotGeneration = nil
            replay = try frameCodec.replay(
                journalData,
                startingAt: 0,
                initialState: WorkflowState(),
                codec: codec,
                maximumEventBytes: configuration.maximumEventBytes
            )
        }

        let tailDisposition: WorkflowJournalTailDisposition
        let validData: Data
        if replay.validByteCount == journalData.count {
            tailDisposition = .clean
            validData = journalData
        } else {
            let discardedBytes = journalData.count - replay.validByteCount
            if repairTornTail {
                let quarantineName = try quarantineTornTail(
                    journalData.suffix(discardedBytes),
                    fileSystem: fileSystem
                )
                try fileSystem.truncateDurably(
                    journalURL,
                    toByteCount: UInt64(replay.validByteCount)
                )
                tailDisposition = .repaired(
                    discardedBytes: discardedBytes,
                    quarantineFileName: quarantineName
                )
                validData = Data(journalData.prefix(replay.validByteCount))
            } else {
                tailDisposition = .detected(
                    discardableBytes: discardedBytes
                )
                validData = Data(journalData.prefix(replay.validByteCount))
            }
        }

        return LoadedJournal(
            storeID: storeID,
            state: replay.state,
            validJournalData: validData,
            physicalJournalByteCount: physicalByteCount,
            recovery: WorkflowJournalRecoveryReport(
                snapshot: snapshotDisposition,
                tail: tailDisposition
            ),
            appliedSnapshotGeneration: snapshotGeneration
        )
    }

    func ensureJournalExists(
        fileSystem: any WorkflowDurableFileSystem
    ) throws {
        guard try !fileSystem.regularFileExists(journalURL) else { return }
        do {
            try fileSystem.writeNewAtomically(Data(), to: journalURL)
        } catch WorkflowDurableFileSystemError.entryAlreadyExists {
            // Another cooperating process can only win before this process
            // obtains the permanent lock; treating that as success is safe.
        }
    }

    func loadOrCreateStoreID(
        fileSystem: any WorkflowDurableFileSystem
    ) throws -> WorkflowStoreID {
        if try !fileSystem.regularFileExists(storeIdentityURL) {
            let storeID = try WorkflowStoreID(
                UUID().uuidString.lowercased()
            )
            let document = WorkflowStoreIdentityDocument(storeID: storeID)
            let data = try codec.canonicalData(document)
            do {
                try fileSystem.writeNewAtomically(data, to: storeIdentityURL)
            } catch WorkflowDurableFileSystemError.entryAlreadyExists {
                // A concurrent initializer may have created the identity.
            }
        }
        do {
            try fileSystem.synchronizeRegularFileDurably(storeIdentityURL)
            let data = try fileSystem.readRegularFile(
                storeIdentityURL,
                maximumBytes: 16 * 1_024
            )
            let schema = try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: data
            ).schemaVersion
            switch schema {
            case WorkflowStoreIdentityDocument.currentSchemaVersion:
                return try codec.decodeCanonical(
                    WorkflowStoreIdentityDocument.self,
                    from: data
                ).storeID
            case WorkflowStoreIdentityDocumentV1.schemaVersionValue:
                let legacy = try codec.decodeCanonical(
                    WorkflowStoreIdentityDocumentV1.self,
                    from: data
                )
                let migrated = WorkflowStoreIdentityDocument(
                    storeID: legacy.storeID
                )
                try fileSystem.replaceAtomically(
                    codec.canonicalData(migrated),
                    at: storeIdentityURL
                )
                return migrated.storeID
            default:
                throw WorkflowCanonicalCodecError.unsupportedSchemaVersion(
                    type: "WorkflowStoreIdentityDocument",
                    actual: schema,
                    current: WorkflowStoreIdentityDocument
                        .currentSchemaVersion
                )
            }
        } catch {
            throw WorkflowEventJournalError.invalidStoreIdentity
        }
    }

    func quarantineTornTail(
        _ bytes: Data.SubSequence,
        fileSystem: any WorkflowDurableFileSystem
    ) throws -> String {
        let name = "torn-tail-\(UUID().uuidString.lowercased()).bin"
        let url = quarantineURL.appendingPathComponent(name)
        try fileSystem.writeNewAtomically(Data(bytes), to: url)
        return name
    }

    static func sameCommand(
        _ receipt: WorkflowAppliedEventReceipt,
        _ candidate: WorkflowEventEnvelope
    ) -> Bool {
        receipt.commandID == candidate.commandID
            && receipt.scope == candidate.scope
            && receipt.jobBinding == candidate.jobBinding
            && receipt.attemptID == candidate.attemptID
            && receipt.payloadHash == candidate.payloadHash
    }

    static func snapshotReason(
        for error: WorkflowCanonicalCodecError
    ) -> WorkflowSnapshotRejectionReason {
        switch error {
        case .nonCanonicalEncoding:
            .nonCanonical
        case .snapshotBodyHashMismatch:
            .hashMismatch
        case .snapshotAnchorMismatch:
            .invalidTailAnchor
        case .unsupportedSchemaVersion:
            .nonCanonical
        case .payloadHashMismatch, .eventHashMismatch:
            .unreadable
        }
    }
}

private enum SnapshotValidationFailure: Error {
    case storeIdentityMismatch
    case byteCountOutOfBounds
    case journalPrefixMismatch

    var reason: WorkflowSnapshotRejectionReason {
        switch self {
        case .storeIdentityMismatch:
            .storeIdentityMismatch
        case .byteCountOutOfBounds:
            .byteCountOutOfBounds
        case .journalPrefixMismatch:
            .journalPrefixMismatch
        }
    }
}

private struct WorkflowStoreIdentityDocument: Codable {
    static let currentSchemaVersion: UInt16 = 2

    let schemaVersion: UInt16
    let storeID: WorkflowStoreID

    init(storeID: WorkflowStoreID) {
        schemaVersion = Self.currentSchemaVersion
        self.storeID = storeID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowCanonicalCodecError.unsupportedSchemaVersion(
                type: "WorkflowStoreIdentityDocument",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        self.init(
            storeID: try container.decode(
                WorkflowStoreID.self,
                forKey: .storeID
            )
        )
    }
}

private struct WorkflowStoreIdentityDocumentV1: Codable {
    static let schemaVersionValue: UInt16 = 1

    let schemaVersion: UInt16
    let storeID: WorkflowStoreID

    init(storeID: WorkflowStoreID) {
        schemaVersion = Self.schemaVersionValue
        self.storeID = storeID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.schemaVersionValue else {
            throw WorkflowCanonicalCodecError.unsupportedSchemaVersion(
                type: "WorkflowStoreIdentityDocumentV1",
                actual: schemaVersion,
                current: Self.schemaVersionValue
            )
        }
        self.init(
            storeID: try container.decode(
                WorkflowStoreID.self,
                forKey: .storeID
            )
        )
    }
}

struct WorkflowJournalFrame: Equatable, Sendable {
    let body: Data
    let footer: Data

    var data: Data {
        var result = body
        result.append(footer)
        return result
    }
}

struct WorkflowJournalReplayResult: Equatable, Sendable {
    let state: WorkflowState
    let validByteCount: Int
}

struct WorkflowJournalFrameCodec: Sendable {
    static let headerByteCount = 96
    static let footerByteCount = 56

    private static let formatVersion: UInt16 = 1
    private static let headerMagic = Data("MIRJNL1B".utf8)
    private static let footerMagic = Data("MIRJNL1C".utf8)

    func makeFrame(
        envelope: WorkflowEventEnvelope,
        codec: WorkflowCanonicalCodec,
        maximumEventBytes: Int
    ) throws -> WorkflowJournalFrame {
        let payload = try codec.canonicalEnvelopeData(envelope)
        guard payload.count <= maximumEventBytes else {
            throw WorkflowEventJournalError.corruptJournal(
                offset: 0,
                reason: .recordTooLarge
            )
        }
        let frameHash = try codec.journalFrameHash(payload)
        let rawHash = try Self.rawDigest(frameHash.rawValue)

        var header = Data()
        header.append(Self.headerMagic)
        header.appendBigEndian(Self.formatVersion)
        header.appendBigEndian(UInt16(0))
        header.appendBigEndian(UInt32(Self.headerByteCount))
        header.appendBigEndian(UInt64(payload.count))
        header.appendBigEndian(envelope.sequence)
        header.append(rawHash)
        let headerHash = try codec.journalFrameHeaderHash(header)
        header.append(try Self.rawDigest(headerHash.rawValue))
        precondition(header.count == Self.headerByteCount)

        var body = header
        body.append(payload)
        var footer = Data()
        footer.append(Self.footerMagic)
        footer.appendBigEndian(UInt64(body.count))
        footer.appendBigEndian(envelope.sequence)
        footer.append(rawHash)
        precondition(footer.count == Self.footerByteCount)
        return WorkflowJournalFrame(body: body, footer: footer)
    }

    func replay(
        _ data: Data,
        startingAt initialOffset: Int,
        initialState: WorkflowState,
        codec: WorkflowCanonicalCodec,
        maximumEventBytes: Int
    ) throws -> WorkflowJournalReplayResult {
        guard initialOffset >= 0, initialOffset <= data.count else {
            throw WorkflowEventJournalError.corruptJournal(
                offset: initialOffset,
                reason: .invalidHeaderLength
            )
        }
        var state = initialState
        var offset = initialOffset
        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= Self.headerByteCount else {
                return WorkflowJournalReplayResult(
                    state: state,
                    validByteCount: offset
                )
            }
            guard data[offset ..< offset + 8] == Self.headerMagic else {
                throw corruption(offset, .invalidHeaderMagic)
            }
            let version = data.readUInt16BigEndian(at: offset + 8)
            guard version == Self.formatVersion else {
                throw corruption(offset, .unsupportedFrameVersion)
            }
            guard data.readUInt16BigEndian(at: offset + 10) == 0 else {
                throw corruption(offset, .nonzeroFrameFlags)
            }
            guard
                data.readUInt32BigEndian(at: offset + 12)
                    == UInt32(Self.headerByteCount)
            else {
                throw corruption(offset, .invalidHeaderLength)
            }
            let rawFrameHashRange = offset + 32 ..< offset + 64
            let rawHash = Data(data[rawFrameHashRange])
            let rawHeaderHashRange = offset + 64 ..< offset + 96
            let rawHeaderHash = Data(data[rawHeaderHashRange])
            let expectedHeaderHash: WorkflowJournalFrameHeaderHash
            do {
                expectedHeaderHash = try codec.journalFrameHeaderHash(
                    Data(data[offset ..< offset + 64])
                )
            } catch {
                throw corruption(offset, .headerHashMismatch)
            }
            guard
                try Self.rawDigest(expectedHeaderHash.rawValue)
                    == rawHeaderHash
            else {
                throw corruption(offset, .headerHashMismatch)
            }
            let payloadLength = data.readUInt64BigEndian(at: offset + 16)
            guard
                payloadLength <= UInt64(maximumEventBytes),
                payloadLength <= UInt64(Int.max)
            else {
                throw corruption(offset, .recordTooLarge)
            }
            let sequence = data.readUInt64BigEndian(at: offset + 24)
            let bodyLength = Self.headerByteCount + Int(payloadLength)
            let (frameLength, overflow) = bodyLength.addingReportingOverflow(
                Self.footerByteCount
            )
            guard !overflow else {
                throw corruption(offset, .recordTooLarge)
            }
            guard remaining >= frameLength else {
                return WorkflowJournalReplayResult(
                    state: state,
                    validByteCount: offset
                )
            }

            let payloadStart = offset + Self.headerByteCount
            let payloadEnd = payloadStart + Int(payloadLength)
            let footerStart = payloadEnd
            guard
                data[footerStart ..< footerStart + 8] == Self.footerMagic,
                data.readUInt64BigEndian(at: footerStart + 8)
                    == UInt64(bodyLength),
                data.readUInt64BigEndian(at: footerStart + 16) == sequence,
                Data(data[footerStart + 24 ..< footerStart + 56]) == rawHash
            else {
                throw corruption(offset, .invalidFooter)
            }

            let payload = Data(data[payloadStart ..< payloadEnd])
            let expectedFrameHash: WorkflowJournalFrameHash
            do {
                expectedFrameHash = try codec.journalFrameHash(payload)
            } catch {
                throw corruption(offset, .frameHashMismatch)
            }
            guard
                try Self.rawDigest(expectedFrameHash.rawValue) == rawHash
            else {
                throw corruption(offset, .frameHashMismatch)
            }

            let envelope: WorkflowEventEnvelope
            do {
                envelope = try codec.decodeCanonicalEnvelope(payload)
            } catch WorkflowCanonicalCodecError.nonCanonicalEncoding {
                throw corruption(offset, .nonCanonicalEnvelope)
            } catch {
                throw corruption(offset, .invalidEnvelopeHash)
            }
            let expectedSequence: UInt64
            if let lastSequence = state.lastEventSequence {
                guard lastSequence < UInt64.max else {
                    throw corruption(offset, .sequenceMismatch)
                }
                expectedSequence = lastSequence + 1
            } else {
                expectedSequence = 0
            }
            guard
                sequence == envelope.sequence,
                envelope.sequence == expectedSequence
            else {
                throw corruption(offset, .sequenceMismatch)
            }
            guard envelope.previousEventHash == state.lastEventHash else {
                throw corruption(offset, .previousHashMismatch)
            }

            let nextState: WorkflowState
            do {
                nextState = try WorkflowReducer.reduce(
                    state,
                    applying: envelope
                )
            } catch {
                throw corruption(offset, .reductionRejected)
            }
            guard
                nextState.lastEventSequence == envelope.sequence,
                nextState.appliedEvents.count == state.appliedEvents.count + 1
            else {
                throw corruption(offset, .duplicatePhysicalEvent)
            }
            state = nextState
            offset += frameLength
        }
        return WorkflowJournalReplayResult(
            state: state,
            validByteCount: offset
        )
    }

    private func corruption(
        _ offset: Int,
        _ reason: WorkflowJournalCorruptionReason
    ) -> WorkflowEventJournalError {
        .corruptJournal(offset: offset, reason: reason)
    }

    private static func rawDigest(_ hex: String) throws -> Data {
        guard hex.utf8.count == 64 else {
            throw WorkflowCanonicalCodecError.eventHashMismatch
        }
        var result = Data()
        result.reserveCapacity(32)
        var index = hex.startIndex
        for _ in 0 ..< 32 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else {
                throw WorkflowCanonicalCodecError.eventHashMismatch
            }
            result.append(byte)
            index = next
        }
        return result
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    func readUInt16BigEndian(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8)
            | UInt16(self[offset + 1])
    }

    func readUInt32BigEndian(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func readUInt64BigEndian(at offset: Int) -> UInt64 {
        (UInt64(self[offset]) << 56)
            | (UInt64(self[offset + 1]) << 48)
            | (UInt64(self[offset + 2]) << 40)
            | (UInt64(self[offset + 3]) << 32)
            | (UInt64(self[offset + 4]) << 24)
            | (UInt64(self[offset + 5]) << 16)
            | (UInt64(self[offset + 6]) << 8)
            | UInt64(self[offset + 7])
    }
}
