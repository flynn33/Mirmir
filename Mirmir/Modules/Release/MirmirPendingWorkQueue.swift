import Foundation

actor MirmirPendingWorkQueue {
    static let schemaVersion = 1
    static let documentFileName = "pending-work-v1.json"

    private struct VersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    private struct Document: Codable {
        let schemaVersion: Int
        var records: [MirmirPendingWorkRecord]
        var processingPathBatchResults:
            [MirmirProcessingPathBatchResult]

        init(
            schemaVersion: Int,
            records: [MirmirPendingWorkRecord],
            processingPathBatchResults:
                [MirmirProcessingPathBatchResult] = []
        ) {
            self.schemaVersion = schemaVersion
            self.records = records
            self.processingPathBatchResults = processingPathBatchResults
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case records
            case processingPathBatchResults
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(
                Int.self,
                forKey: .schemaVersion
            )
            records = try container.decode(
                [MirmirPendingWorkRecord].self,
                forKey: .records
            )
            processingPathBatchResults = try container.decodeIfPresent(
                [MirmirProcessingPathBatchResult].self,
                forKey: .processingPathBatchResults
            ) ?? []
        }
    }

    private let directoryURL: URL
    private let documentURL: URL
    let limits: MirmirPendingQueueLimits
    private let fileSystem: any R13RestartFileSystem

    init(
        directoryURL: URL,
        limits: MirmirPendingQueueLimits = .production,
        fileSystem: any R13RestartFileSystem = R13LocalRestartFileSystem()
    ) {
        let resolvedDirectory = R13RestartPath.resolvingExistingAncestor(
            of: directoryURL
        )
        self.directoryURL = resolvedDirectory
        self.documentURL = resolvedDirectory.appendingPathComponent(
            Self.documentFileName,
            isDirectory: false
        )
        self.limits = limits
        self.fileSystem = fileSystem
    }

    static func production(
        fileManager: FileManager = .default,
        limits: MirmirPendingQueueLimits = .production
    ) throws -> MirmirPendingWorkQueue {
        let applicationSupport: URL
        do {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw MirmirPendingQueueError.persistenceFailure(
                operation: .locateApplicationSupport
            )
        }
        let fileSystem: R13LocalRestartFileSystem
        do {
            fileSystem = try R13LocalRestartFileSystem(
                trustedRootURL: applicationSupport
            )
        } catch {
            throw MirmirPendingQueueError.persistenceFailure(
                operation: .initialize
            )
        }
        return MirmirPendingWorkQueue(
            directoryURL: applicationSupport
                .appendingPathComponent("Mirmir", isDirectory: true)
                .appendingPathComponent("PendingWork", isDirectory: true),
            limits: limits,
            fileSystem: fileSystem
        )
    }

    func load() throws -> MirmirPendingQueueSnapshot {
        let loaded = try loadDocument()
        return snapshot(from: loaded)
    }

    func head() throws -> MirmirPendingWorkRecord? {
        try load().head
    }

    func record(id: String) throws -> MirmirPendingWorkRecord? {
        try validateIdentity(id)
        return try load().records.first { $0.id == id }
    }

    @discardableResult
    func enqueue(
        _ record: MirmirPendingWorkRecord
    ) throws -> MirmirPendingQueueSnapshot {
        try enqueueMany([record])
    }

    @discardableResult
    func enqueueMany(
        _ records: [MirmirPendingWorkRecord]
    ) throws -> MirmirPendingQueueSnapshot {
        guard !records.isEmpty else {
            return try load()
        }
        let orderedBatch = try validatedEnqueueBatch(records)
        var loaded = try loadDocument()
        let existingIDs = Set(loaded.document.records.map(\.id))
        guard orderedBatch.allSatisfy({
            !existingIDs.contains($0.id)
        }) else {
            throw MirmirPendingQueueError.duplicateJobID
        }
        guard loaded.document.records.count
            <= limits.maximumRecords - orderedBatch.count else {
            throw MirmirPendingQueueError.capacityExceeded
        }

        let startingOrder = loaded.document.records.count
        loaded.document.records.append(
            contentsOf: orderedBatch.enumerated().map { offset, record in
                record.assigningOrder(startingOrder + offset)
            }
        )
        pruneProcessingPathBatchResults(in: &loaded.document)
        try validateQueue(loaded.document.records)
        try validateBatchResults(loaded.document.processingPathBatchResults)
        try persist(loaded.document)
        return snapshot(from: loaded)
    }

    @discardableResult
    func recordTerminalResultAndRemove(
        id: String,
        status: MirmirProcessingPathTerminalStatus,
        reason: String?,
        completedAt: Date = Date()
    ) throws -> MirmirPendingQueueSnapshot {
        try validateIdentity(id)
        var loaded = try loadDocument()
        guard let index = loaded.document.records.firstIndex(
            where: { $0.id == id }
        ) else {
            throw MirmirPendingQueueError.recordNotFound
        }
        let record = loaded.document.records[index]
        appendProcessingPathBatchResult(
            for: record,
            status: status,
            reason: reason,
            completedAt: completedAt,
            to: &loaded.document
        )
        loaded.document.records.remove(at: index)
        loaded.document.records = loaded.document.records
            .enumerated()
            .map { $0.element.assigningOrder($0.offset) }
        pruneProcessingPathBatchResults(in: &loaded.document)
        try validateQueue(loaded.document.records)
        try validateBatchResults(loaded.document.processingPathBatchResults)
        try persist(loaded.document)
        return snapshot(from: loaded)
    }

    @discardableResult
    func update(
        _ record: MirmirPendingWorkRecord
    ) throws -> MirmirPendingQueueSnapshot {
        try validate(record)
        var loaded = try loadDocument()
        guard let index = loaded.document.records.firstIndex(
            where: { $0.id == record.id }
        ) else {
            throw MirmirPendingQueueError.recordNotFound
        }
        let existing = loaded.document.records[index]
        guard existing.state == .pending else {
            throw MirmirPendingQueueError.recordAlreadyStarted
        }
        guard record.order == existing.order,
              record.state == .pending,
              record.startedAt == nil else {
            throw MirmirPendingQueueError.invalidRecord(field: .lifecycle)
        }
        loaded.document.records[index] = record
        try validateQueue(loaded.document.records)
        try persist(loaded.document)
        return snapshot(from: loaded)
    }

    @discardableResult
    func reorder(
        ids: [String]
    ) throws -> MirmirPendingQueueSnapshot {
        for id in ids {
            try validateIdentity(id)
        }
        var loaded = try loadDocument()
        let requestedIDs = Set(ids)
        let existingIDs = Set(loaded.document.records.map(\.id))
        guard ids.count == loaded.document.records.count,
              requestedIDs.count == ids.count,
              requestedIDs == existingIDs else {
            throw MirmirPendingQueueError.invalidReorder
        }
        if loaded.document.records.first?.state == .started,
           ids.first != loaded.document.records.first?.id {
            throw MirmirPendingQueueError.invalidReorder
        }
        let recordsByID = Dictionary(
            uniqueKeysWithValues: loaded.document.records.map {
                ($0.id, $0)
            }
        )
        loaded.document.records = try ids.enumerated().map { order, id in
            guard let record = recordsByID[id] else {
                throw MirmirPendingQueueError.invalidReorder
            }
            return record.assigningOrder(order)
        }
        try validateQueue(loaded.document.records)
        try persist(loaded.document)
        return snapshot(from: loaded)
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        try validateIdentity(id)
        var loaded = try loadDocument()
        guard let index = loaded.document.records.firstIndex(
            where: { $0.id == id }
        ) else {
            return false
        }
        let record = loaded.document.records[index]
        appendProcessingPathBatchResult(
            for: record,
            status: .cancelled,
            reason: "Removed from the pending queue by the user.",
            completedAt: Date(),
            to: &loaded.document
        )
        loaded.document.records.remove(at: index)
        loaded.document.records = loaded.document.records
            .enumerated()
            .map { $0.element.assigningOrder($0.offset) }
        pruneProcessingPathBatchResults(in: &loaded.document)
        try validateQueue(loaded.document.records)
        try validateBatchResults(loaded.document.processingPathBatchResults)
        try persist(loaded.document)
        return true
    }

    @discardableResult
    func clear() throws -> MirmirPendingQueueSnapshot {
        var loaded = try loadDocument()
        guard !loaded.document.records.isEmpty else {
            return snapshot(from: loaded)
        }
        let completedAt = Date()
        for record in loaded.document.records {
            appendProcessingPathBatchResult(
                for: record,
                status: .cancelled,
                reason: "Cleared from the pending queue by the user.",
                completedAt: completedAt,
                to: &loaded.document
            )
        }
        loaded.document.records = []
        pruneProcessingPathBatchResults(in: &loaded.document)
        try validateQueue(loaded.document.records)
        try validateBatchResults(loaded.document.processingPathBatchResults)
        try persist(loaded.document)
        return snapshot(from: loaded)
    }

    func markStartedOrReturnHead(
        startedAt: Date = Date()
    ) throws -> MirmirPendingQueueHeadClaim {
        var loaded = try loadDocument()
        guard let head = loaded.document.records.first else {
            return MirmirPendingQueueHeadClaim(
                record: nil,
                didMarkStarted: false,
                processingPathBatchResults:
                    loaded.document.processingPathBatchResults,
                recovery: loaded.recovery
            )
        }
        if head.state == .started {
            return MirmirPendingQueueHeadClaim(
                record: head,
                didMarkStarted: false,
                processingPathBatchResults:
                    loaded.document.processingPathBatchResults,
                recovery: loaded.recovery
            )
        }
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              startedAt >= head.createdAt else {
            throw MirmirPendingQueueError.invalidRecord(field: .lifecycle)
        }
        let started = head.markingStarted(at: startedAt)
        loaded.document.records[0] = started
        try validateQueue(loaded.document.records)
        try persist(loaded.document)
        return MirmirPendingQueueHeadClaim(
            record: started,
            didMarkStarted: true,
            processingPathBatchResults:
                loaded.document.processingPathBatchResults,
            recovery: loaded.recovery
        )
    }

    @discardableResult
    func returnStartedHeadToPending(
        id: String
    ) throws -> MirmirPendingQueueSnapshot {
        try validateIdentity(id)
        var loaded = try loadDocument()
        guard let head = loaded.document.records.first else {
            throw MirmirPendingQueueError.recordNotFound
        }
        guard head.id == id else {
            if loaded.document.records.contains(where: { $0.id == id }) {
                throw MirmirPendingQueueError.recordNotQueueHead
            }
            throw MirmirPendingQueueError.recordNotFound
        }
        guard head.state == .started else {
            return snapshot(from: loaded)
        }
        loaded.document.records[0] = head.returningToPending()
        try validateQueue(loaded.document.records)
        try persist(loaded.document)
        return snapshot(from: loaded)
    }
}

private extension MirmirPendingWorkQueue {
    private typealias LoadedDocument = (
        document: Document,
        recovery: MirmirPendingQueueRecovery?
    )

    private func snapshot(
        from loaded: LoadedDocument
    ) -> MirmirPendingQueueSnapshot {
        MirmirPendingQueueSnapshot(
            records: loaded.document.records,
            processingPathBatchResults:
                loaded.document.processingPathBatchResults,
            recovery: loaded.recovery
        )
    }

    private func appendProcessingPathBatchResult(
        for record: MirmirPendingWorkRecord,
        status: MirmirProcessingPathTerminalStatus,
        reason: String?,
        completedAt: Date,
        to document: inout Document
    ) {
        guard let batch = record.settings.processingPathBatch else {
            return
        }
        document.processingPathBatchResults.append(
            MirmirProcessingPathBatchResult(
                batch: batch,
                jobID: record.id,
                outputDisplayName: record.bookmarks.outputDisplayName,
                status: status,
                reason: reason,
                completedAt: completedAt
            )
        )
    }

    private func loadDocument() throws -> LoadedDocument {
        try persistenceBoundary(operation: .initialize) {
            try fileSystem.ensureDirectory(directoryURL)
        }
        guard fileSystem.exists(documentURL) else {
            return (
                Document(schemaVersion: Self.schemaVersion, records: []),
                nil
            )
        }

        let data: Data
        do {
            data = try fileSystem.readRegularFile(
                documentURL,
                maximumBytes:
                    MirmirPendingQueueLimits.absoluteMaximumDocumentBytes
            )
        } catch {
            throw MirmirPendingQueueError.persistenceFailure(operation: .read)
        }
        guard data.count <= limits.maximumDocumentBytes else {
            return try quarantineAndReset(
                data,
                reason: .oversizedDocument
            )
        }

        let decoder = JSONDecoder()
        let envelope: VersionEnvelope
        do {
            envelope = try decoder.decode(VersionEnvelope.self, from: data)
        } catch {
            return try quarantineAndReset(
                data,
                reason: .malformedDocument
            )
        }
        guard envelope.schemaVersion == Self.schemaVersion else {
            throw MirmirPendingQueueError.unsupportedSchemaVersion(
                envelope.schemaVersion
            )
        }

        var document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            return try quarantineAndReset(
                data,
                reason: .malformedDocument
            )
        }
        if let reason = recoveryReason(for: document.records) {
            return try quarantineAndReset(data, reason: reason)
        }
        do {
            try validateBatchResults(document.processingPathBatchResults)
        } catch {
            return try quarantineAndReset(data, reason: .invalidRecord)
        }
        let decodedRecords = document.records
        document.records.sort(by: Self.isEarlier)
        if document.records != decodedRecords {
            try persist(document)
        }
        return (document, nil)
    }

    private func persist(_ document: Document) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(document)
        } catch {
            throw MirmirPendingQueueError.persistenceFailure(operation: .write)
        }
        guard data.count <= limits.maximumDocumentBytes else {
            throw MirmirPendingQueueError.documentTooLarge
        }
        do {
            if fileSystem.exists(documentURL) {
                try fileSystem.replaceAtomically(data, at: documentURL)
            } else {
                try fileSystem.writeNewAtomically(data, to: documentURL)
            }
        } catch {
            throw MirmirPendingQueueError.persistenceFailure(operation: .write)
        }
    }

    private func quarantineAndReset(
        _ data: Data,
        reason: MirmirPendingQueueRecoveryReason
    ) throws -> LoadedDocument {
        let fileName = "pending-work-corrupt-"
            + "\(UUID().uuidString.lowercased()).json"
        let quarantineURL = directoryURL.appendingPathComponent(
            fileName,
            isDirectory: false
        )
        do {
            try fileSystem.writeNewAtomically(data, to: quarantineURL)
        } catch {
            throw MirmirPendingQueueError.persistenceFailure(
                operation: .quarantine
            )
        }
        let empty = Document(schemaVersion: Self.schemaVersion, records: [])
        try persist(empty)
        return (
            empty,
            MirmirPendingQueueRecovery(
                reason: reason,
                quarantineFileName: fileName
            )
        )
    }

    private func pruneProcessingPathBatchResults(
        in document: inout Document
    ) {
        let activeBatchIDs = Set(
            document.records.compactMap {
                $0.settings.processingPathBatch?.id
            }
        )
        let latestBatchID = document.processingPathBatchResults
            .last?.batch.id
        document.processingPathBatchResults.removeAll { result in
            !activeBatchIDs.contains(result.batch.id)
                && result.batch.id != latestBatchID
        }
    }

    func persistenceBoundary<T>(
        operation: MirmirPendingQueueOperation,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as MirmirPendingQueueError {
            throw error
        } catch {
            throw MirmirPendingQueueError.persistenceFailure(
                operation: operation
            )
        }
    }
}
