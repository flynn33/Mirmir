import Foundation
import OSLog

enum MirmirDiagnosticStorageKind: String, Sendable {
    case persistent
    case memoryOnly = "memory_only"
}

struct MirmirDiagnosticPersistenceHealth: Equatable, Sendable {
    let storageKind: MirmirDiagnosticStorageKind
    let failedOperationCount: UInt64
    let lastFailedOperation: String?
}

actor MirmirDiagnosticStore {
    static let journalFileName = "diagnostics-v1.jsonl"
    static let lockFileName = "diagnostics-v1.lock"
    static let application = productionOrInMemory()

    static let logger = Logger(
        subsystem: "com.mirmir.app",
        category: "Diagnostics"
    )

    private let policy: MirmirDiagnosticRetentionPolicy
    private let clock: MirmirDiagnosticClock
    private let sessionID: MirmirDiagnosticID
    private let directoryURL: URL?
    private let journalURL: URL?
    private let lockURL: URL?
    private let fileSystem: (any MirmirDiagnosticFileSystem)?
    private var state: MirmirDiagnosticStoreState
    private var persistenceFailureCount: UInt64
    private var lastPersistenceFailureOperation: String?
    nonisolated let storageKind: MirmirDiagnosticStorageKind
    nonisolated let diagnosticSubmissionQueue: MirmirDiagnosticSubmissionQueue

    init(
        inMemoryWith policy: MirmirDiagnosticRetentionPolicy = .production,
        clock: MirmirDiagnosticClock = .production,
        sessionID: UUID = UUID(),
        initialPersistenceFailureCount: UInt64 = 0,
        initialPersistenceFailureOperation: String? = nil
    ) {
        var initialState = MirmirDiagnosticStoreState.empty
        initialState.journalByteCount =
            (try? Self.journalData(initialState).count) ?? 0
        self.policy = policy
        self.clock = clock
        self.sessionID = MirmirDiagnosticID(sessionID)
        self.directoryURL = nil
        self.journalURL = nil
        self.lockURL = nil
        self.fileSystem = nil
        self.state = initialState
        self.persistenceFailureCount = initialPersistenceFailureCount
        if let initialPersistenceFailureOperation,
           MirmirDiagnosticToken.isValid(
               initialPersistenceFailureOperation
           ) {
            self.lastPersistenceFailureOperation =
                initialPersistenceFailureOperation
        } else if initialPersistenceFailureCount > 0 {
            self.lastPersistenceFailureOperation = "unknown"
        } else {
            self.lastPersistenceFailureOperation = nil
        }
        self.storageKind = .memoryOnly
        self.diagnosticSubmissionQueue = MirmirDiagnosticSubmissionQueue()
    }

    init(
        persistentDirectoryURL: URL,
        policy: MirmirDiagnosticRetentionPolicy = .production,
        clock: MirmirDiagnosticClock = .production,
        sessionID: UUID = UUID()
    ) throws {
        let standardizedDirectory = R13RestartPath.resolvingExistingAncestor(
            of: persistentDirectoryURL
        )
        guard standardizedDirectory.isFileURL else {
            throw MirmirDiagnosticStoreError.persistenceFailure(
                operation: "validate_directory"
            )
        }
        let fileSystem = MirmirLocalDiagnosticFileSystem()
        let journalURL = standardizedDirectory.appendingPathComponent(
            Self.journalFileName,
            isDirectory: false
        )
        let lockURL = standardizedDirectory.appendingPathComponent(
            Self.lockFileName,
            isDirectory: false
        )
        try Self.persistenceBoundary(operation: "initialize") {
            try fileSystem.ensureDirectory(standardizedDirectory)
        }

        self.policy = policy
        self.clock = clock
        self.sessionID = MirmirDiagnosticID(sessionID)
        self.directoryURL = standardizedDirectory
        self.journalURL = journalURL
        self.lockURL = lockURL
        self.fileSystem = fileSystem
        self.storageKind = .persistent
        self.diagnosticSubmissionQueue = MirmirDiagnosticSubmissionQueue()
        self.persistenceFailureCount = 0
        self.lastPersistenceFailureOperation = nil
        self.state = try Self.persistenceBoundary(operation: "load") {
            try fileSystem.withExclusiveLock(at: lockURL) { transaction in
                try Self.loadAndRepair(
                    fileSystem: transaction,
                    journalURL: journalURL,
                    policy: policy,
                    nowMilliseconds: clock.wallMilliseconds(),
                    uptimeNanoseconds: clock.uptimeNanoseconds(),
                    sessionID: MirmirDiagnosticID(sessionID)
                )
            }
        }
    }

    static func production() throws -> MirmirDiagnosticStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let diagnosticsDirectory = applicationSupport
            .appendingPathComponent("Mirmir", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        return try MirmirDiagnosticStore(
            persistentDirectoryURL: diagnosticsDirectory
        )
    }

    static func productionOrInMemory() -> MirmirDiagnosticStore {
        do {
            return try production()
        } catch {
            reportPersistenceFailure(error, operation: "production_fallback")
            return MirmirDiagnosticStore(
                inMemoryWith: .production,
                initialPersistenceFailureCount: 1,
                initialPersistenceFailureOperation: "production_fallback"
            )
        }
    }

    func persistenceHealth() -> MirmirDiagnosticPersistenceHealth {
        MirmirDiagnosticPersistenceHealth(
            storageKind: storageKind,
            failedOperationCount: persistenceFailureCount,
            lastFailedOperation: lastPersistenceFailureOperation
        )
    }

    @discardableResult
    func record(_ event: MirmirDiagnosticEvent) throws
        -> MirmirDiagnosticRecord {
        let now = clock.wallMilliseconds()
        let uptime = clock.uptimeNanoseconds()
        do {
            if let fileSystem, let journalURL, let lockURL {
                let result = try Self.persistenceBoundary(operation: "record") {
                    try fileSystem.withExclusiveLock(at: lockURL) { transaction in
                        var loaded = try Self.loadAndRepair(
                            fileSystem: transaction,
                            journalURL: journalURL,
                            policy: policy,
                            nowMilliseconds: now,
                            uptimeNanoseconds: uptime,
                            sessionID: sessionID
                        )
                        let mutation = try Self.prepareRecord(
                            event,
                            state: &loaded,
                            policy: policy,
                            nowMilliseconds: now,
                            uptimeNanoseconds: uptime,
                            sessionID: sessionID
                        )
                        try Self.persist(
                            mutation,
                            fileSystem: transaction,
                            journalURL: journalURL,
                            maximumFileBytes: policy.maximumTotalBytes
                        )
                        return (loaded, mutation)
                    }
                }
                state = result.0
                if let rejection = result.1.rejection {
                    throw rejection
                }
                guard let record = result.1.record else {
                    throw MirmirDiagnosticStoreError.malformedJournal
                }
                return record
            }

            let mutation = try Self.prepareRecord(
                event,
                state: &state,
                policy: policy,
                nowMilliseconds: now,
                uptimeNanoseconds: uptime,
                sessionID: sessionID
            )
            state.journalByteCount = try Self.journalData(state).count
            if let rejection = mutation.rejection {
                throw rejection
            }
            guard let record = mutation.record else {
                throw MirmirDiagnosticStoreError.malformedJournal
            }
            return record
        } catch let error as MirmirDiagnosticStoreError {
            registerOperationalFailureIfNeeded(
                error,
                operation: "record"
            )
            throw error
        } catch {
            registerPersistenceFailure(operation: "record")
            Self.reportPersistenceFailure(error, operation: "record")
            throw error
        }
    }

    func snapshot() async throws -> MirmirDiagnosticSnapshot {
        await diagnosticSubmissionQueue.flush()
        let now = clock.wallMilliseconds()
        let uptime = clock.uptimeNanoseconds()
        do {
            if let fileSystem, let journalURL, let lockURL {
                state = try Self.persistenceBoundary(operation: "snapshot") {
                    try fileSystem.withExclusiveLock(at: lockURL) { transaction in
                        try Self.loadAndRepair(
                            fileSystem: transaction,
                            journalURL: journalURL,
                            policy: policy,
                            nowMilliseconds: now,
                            uptimeNanoseconds: uptime,
                            sessionID: sessionID
                        )
                    }
                }
            } else if Self.pruneExpired(
                state: &state,
                policy: policy,
                nowMilliseconds: now
            ) {
                state.journalByteCount = try Self.journalData(state).count
            }
            return try Self.snapshot(
                state: state,
                exportedAt: now,
                rejectedSubmissionCount:
                    diagnosticSubmissionQueue.rejectedSubmissionCount(),
                persistenceFailureCount: persistenceFailureCount,
                lastPersistenceFailureOperation:
                    lastPersistenceFailureOperation
            )
        } catch let error as MirmirDiagnosticStoreError {
            registerOperationalFailureIfNeeded(
                error,
                operation: "snapshot"
            )
            throw error
        } catch {
            registerPersistenceFailure(operation: "snapshot")
            Self.reportPersistenceFailure(error, operation: "snapshot")
            throw error
        }
    }

    func exportJSON() async throws -> Data {
        try MirmirDiagnosticExport.json(await snapshot())
    }

    func exportMarkdown() async throws -> Data {
        try MirmirDiagnosticExport.markdown(await snapshot())
    }

    private static func snapshot(
        state: MirmirDiagnosticStoreState,
        exportedAt: Int64,
        rejectedSubmissionCount: UInt64 = 0,
        persistenceFailureCount: UInt64 = 0,
        lastPersistenceFailureOperation: String? = nil
    ) throws -> MirmirDiagnosticSnapshot {
        try MirmirDiagnosticSnapshot(
            exportedAtUnixMilliseconds: exportedAt,
            retainedByteCount: state.retainedRecordByteCount,
            prunedRecordCount: state.prunedRecordCount,
            rejectedRecordCount: saturatingAdd(
                state.rejectedRecordCount,
                rejectedSubmissionCount
            ),
            recoveredCorruptTailCount: state.recoveredCorruptTailCount,
            recoveredCorruptByteCount: state.recoveredCorruptByteCount,
            persistenceFailureCount: persistenceFailureCount,
            lastPersistenceFailureOperation:
                lastPersistenceFailureOperation,
            records: state.records.map(\.record)
        )
    }

    private func registerOperationalFailureIfNeeded(
        _ error: MirmirDiagnosticStoreError,
        operation: String
    ) {
        switch error {
        case .invalidRetentionPolicy, .recordExceedsByteLimit:
            return
        case .journalCapacityInsufficient, .sequenceExhausted,
             .unsupportedJournalSchema, .malformedJournal,
             .persistenceFailure:
            registerPersistenceFailure(operation: operation)
        }
    }

    private func registerPersistenceFailure(operation: String) {
        persistenceFailureCount = Self.saturatingIncrement(
            persistenceFailureCount
        )
        lastPersistenceFailureOperation =
            MirmirDiagnosticToken.isValid(operation)
            ? operation
            : "unknown"
    }
}
