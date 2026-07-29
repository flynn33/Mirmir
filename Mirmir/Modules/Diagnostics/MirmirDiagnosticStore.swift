import Foundation
import OSLog

actor MirmirDiagnosticStore {
    static let journalFileName = "diagnostics-v1.jsonl"
    static let lockFileName = "diagnostics-v1.lock"

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

    init(
        inMemoryWith policy: MirmirDiagnosticRetentionPolicy = .production,
        clock: MirmirDiagnosticClock = .production,
        sessionID: UUID = UUID()
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
            return MirmirDiagnosticStore(inMemoryWith: .production)
        }
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
            throw error
        } catch {
            Self.reportPersistenceFailure(error, operation: "record")
            throw error
        }
    }

    func snapshot() throws -> MirmirDiagnosticSnapshot {
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
            return try Self.snapshot(state: state, exportedAt: now)
        } catch let error as MirmirDiagnosticStoreError {
            throw error
        } catch {
            Self.reportPersistenceFailure(error, operation: "snapshot")
            throw error
        }
    }

    func exportJSON() throws -> Data {
        try MirmirDiagnosticExport.json(snapshot())
    }

    func exportMarkdown() throws -> Data {
        try MirmirDiagnosticExport.markdown(snapshot())
    }

    private static func snapshot(
        state: MirmirDiagnosticStoreState,
        exportedAt: Int64
    ) throws -> MirmirDiagnosticSnapshot {
        try MirmirDiagnosticSnapshot(
            exportedAtUnixMilliseconds: exportedAt,
            retainedByteCount: state.retainedRecordByteCount,
            prunedRecordCount: state.prunedRecordCount,
            rejectedRecordCount: state.rejectedRecordCount,
            recoveredCorruptTailCount: state.recoveredCorruptTailCount,
            recoveredCorruptByteCount: state.recoveredCorruptByteCount,
            records: state.records.map(\.record)
        )
    }
}
