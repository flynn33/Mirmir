import Foundation

extension MirmirDiagnosticStore {
    struct PreparedRecord {
        let record: MirmirDiagnosticRecord?
        let persistence: MirmirDiagnosticPersistenceMutation
        let rejection: MirmirDiagnosticStoreError?
    }

    struct ParsedJournal {
        var state: MirmirDiagnosticStoreState
        let corruptTailBytes: Int
        let requiresRewrite: Bool
    }

    static func prepareRecord(
        _ event: MirmirDiagnosticEvent,
        state: inout MirmirDiagnosticStoreState,
        policy: MirmirDiagnosticRetentionPolicy,
        nowMilliseconds: Int64,
        uptimeNanoseconds: UInt64,
        sessionID: MirmirDiagnosticID
    ) throws -> PreparedRecord {
        guard state.nextSequence < UInt64.max else {
            throw MirmirDiagnosticStoreError.sequenceExhausted
        }
        let expiredRecordsPruned = pruneExpired(
            state: &state,
            policy: policy,
            nowMilliseconds: nowMilliseconds
        )
        let baselineState = state
        let record = try MirmirDiagnosticRecord(
            sequence: state.nextSequence,
            timestampUnixMilliseconds: nowMilliseconds,
            uptimeNanoseconds: uptimeNanoseconds,
            sessionID: sessionID,
            event: event
        )
        let line = try recordLine(record)
        guard line.count <= policy.maximumRecordBytes else {
            state.rejectedRecordCount = saturatingIncrement(
                state.rejectedRecordCount
            )
            let replacement = try journalData(state)
            guard replacement.count <= policy.maximumTotalBytes else {
                throw MirmirDiagnosticStoreError.journalCapacityInsufficient
            }
            state.journalByteCount = replacement.count
            return PreparedRecord(
                record: nil,
                persistence: .replace(replacement),
                rejection: .recordExceedsByteLimit(
                    observed: line.count,
                    maximum: policy.maximumRecordBytes
                )
            )
        }

        state.nextSequence += 1
        state.records.append(
            MirmirStoredDiagnosticRecord(record: record, line: line)
        )
        var requiresRewrite = expiredRecordsPruned
        while state.records.count > policy.maximumRecords {
            pruneFirst(state: &state)
            requiresRewrite = true
        }

        if !requiresRewrite,
           state.journalByteCount + line.count <= policy.maximumTotalBytes {
            state.journalByteCount += line.count
            return PreparedRecord(
                record: record,
                persistence: .append(line),
                rejection: nil
            )
        }

        var replacement = try journalData(state)
        while replacement.count > policy.maximumTotalBytes,
              state.records.count > 1 {
            pruneFirst(state: &state)
            replacement = try journalData(state)
        }
        guard replacement.count <= policy.maximumTotalBytes,
              state.records.last?.record.sequence == record.sequence else {
            state = baselineState
            state.rejectedRecordCount = saturatingIncrement(
                state.rejectedRecordCount
            )
            let rejectedReplacement = try journalData(state)
            guard rejectedReplacement.count <= policy.maximumTotalBytes else {
                throw MirmirDiagnosticStoreError.journalCapacityInsufficient
            }
            state.journalByteCount = rejectedReplacement.count
            return PreparedRecord(
                record: nil,
                persistence: .replace(rejectedReplacement),
                rejection: .journalCapacityInsufficient
            )
        }
        state.journalByteCount = replacement.count
        return PreparedRecord(
            record: record,
            persistence: .replace(replacement),
            rejection: nil
        )
    }

    static func persist(
        _ prepared: PreparedRecord,
        fileSystem: any MirmirDiagnosticFileSystem,
        journalURL: URL,
        maximumFileBytes: Int
    ) throws {
        switch prepared.persistence {
        case .append(let line):
            try fileSystem.appendLineDurably(
                line,
                to: journalURL,
                maximumFileBytes: maximumFileBytes
            )
        case .replace(let data):
            try fileSystem.replaceAtomically(data, at: journalURL)
        }
    }

    static func loadAndRepair(
        fileSystem: any MirmirDiagnosticFileSystem,
        journalURL: URL,
        policy: MirmirDiagnosticRetentionPolicy,
        nowMilliseconds: Int64,
        uptimeNanoseconds: UInt64,
        sessionID: MirmirDiagnosticID
    ) throws -> MirmirDiagnosticStoreState {
        guard fileSystem.exists(journalURL) else {
            var empty = MirmirDiagnosticStoreState.empty
            let data = try journalData(empty)
            guard data.count <= policy.maximumTotalBytes else {
                throw MirmirDiagnosticStoreError.journalCapacityInsufficient
            }
            try fileSystem.writeNewAtomically(data, to: journalURL)
            empty.journalByteCount = data.count
            return empty
        }

        let data = try fileSystem.readRegularFile(
            journalURL,
            maximumBytes: policy.maximumTotalBytes
        )
        var parsed = try parseJournal(data, policy: policy)
        var requiresRewrite = parsed.requiresRewrite
        if parsed.corruptTailBytes > 0 {
            parsed.state.recoveredCorruptTailCount = saturatingIncrement(
                parsed.state.recoveredCorruptTailCount
            )
            parsed.state.recoveredCorruptByteCount = saturatingAdd(
                parsed.state.recoveredCorruptByteCount,
                UInt64(parsed.corruptTailBytes)
            )
            try appendRecoveryRecord(
                state: &parsed.state,
                recoveredBytes: parsed.corruptTailBytes,
                policy: policy,
                nowMilliseconds: nowMilliseconds,
                uptimeNanoseconds: uptimeNanoseconds,
                sessionID: sessionID
            )
            requiresRewrite = true
            logger.warning(
                "Recovered a corrupt diagnostic journal tail; bytes=\(parsed.corruptTailBytes, privacy: .public)"
            )
        }
        if pruneExpired(
            state: &parsed.state,
            policy: policy,
            nowMilliseconds: nowMilliseconds
        ) {
            requiresRewrite = true
        }
        while parsed.state.records.count > policy.maximumRecords {
            pruneFirst(state: &parsed.state)
            requiresRewrite = true
        }

        var replacement = try journalData(parsed.state)
        while replacement.count > policy.maximumTotalBytes,
              !parsed.state.records.isEmpty {
            pruneFirst(state: &parsed.state)
            replacement = try journalData(parsed.state)
            requiresRewrite = true
        }
        guard replacement.count <= policy.maximumTotalBytes else {
            throw MirmirDiagnosticStoreError.journalCapacityInsufficient
        }
        if requiresRewrite {
            try fileSystem.replaceAtomically(replacement, at: journalURL)
            parsed.state.journalByteCount = replacement.count
        } else {
            parsed.state.journalByteCount = data.count
        }
        return parsed.state
    }

    static func parseJournal(
        _ data: Data,
        policy: MirmirDiagnosticRetentionPolicy
    ) throws -> ParsedJournal {
        let lines = completeLines(in: data)
        guard let headerLine = lines.values.first else {
            return ParsedJournal(
                state: .empty,
                corruptTailBytes: data.count,
                requiresRewrite: true
            )
        }
        let header: MirmirDiagnosticJournalHeader
        do {
            header = try decodeCanonical(
                MirmirDiagnosticJournalHeader.self,
                from: headerLine
            )
        } catch let error as MirmirDiagnosticStoreError {
            if case .unsupportedJournalSchema = error {
                throw error
            }
            return ParsedJournal(
                state: .empty,
                corruptTailBytes: data.count,
                requiresRewrite: true
            )
        } catch {
            if let version = journalSchemaVersion(in: headerLine),
               version > MirmirDiagnosticJournalHeader.currentSchemaVersion {
                throw MirmirDiagnosticStoreError.unsupportedJournalSchema(
                    version
                )
            }
            return ParsedJournal(
                state: .empty,
                corruptTailBytes: data.count,
                requiresRewrite: true
            )
        }

        var records: [MirmirStoredDiagnosticRecord] = []
        var previousSequence: UInt64?
        var corruptStart = lines.trailingStart
        for (index, line) in lines.values.dropFirst().enumerated() {
            do {
                let record = try decodeCanonical(
                    MirmirDiagnosticRecord.self,
                    from: line
                )
                guard record.sequence < UInt64.max,
                      previousSequence.map({ record.sequence > $0 }) ?? true else {
                    throw MirmirDiagnosticStoreError.malformedJournal
                }
                var canonicalLine = line
                canonicalLine.append(0x0A)
                guard canonicalLine.count <= policy.maximumRecordBytes else {
                    throw MirmirDiagnosticStoreError.malformedJournal
                }
                records.append(
                    MirmirStoredDiagnosticRecord(
                        record: record,
                        line: canonicalLine
                    )
                )
                previousSequence = record.sequence
            } catch {
                corruptStart = lines.starts[index + 1]
                break
            }
        }

        let lastSequenceNext = records.last.map {
            $0.record.sequence + 1
        } ?? 0
        let state = MirmirDiagnosticStoreState(
            nextSequence: max(header.nextSequence, lastSequenceNext),
            prunedRecordCount: header.prunedRecordCount,
            rejectedRecordCount: header.rejectedRecordCount,
            recoveredCorruptTailCount: header.recoveredCorruptTailCount,
            recoveredCorruptByteCount: header.recoveredCorruptByteCount,
            records: records,
            journalByteCount: data.count
        )
        let recoveredBytes = corruptStart < data.count
            ? data.count - corruptStart
            : 0
        return ParsedJournal(
            state: state,
            corruptTailBytes: recoveredBytes,
            requiresRewrite: recoveredBytes > 0
        )
    }

    static func appendRecoveryRecord(
        state: inout MirmirDiagnosticStoreState,
        recoveredBytes: Int,
        policy: MirmirDiagnosticRetentionPolicy,
        nowMilliseconds: Int64,
        uptimeNanoseconds: UInt64,
        sessionID: MirmirDiagnosticID
    ) throws {
        guard state.nextSequence < UInt64.max else {
            throw MirmirDiagnosticStoreError.sequenceExhausted
        }
        let event = try MirmirDiagnosticEvent(
            severity: .warning,
            subsystem: "diagnostics",
            operation: "load_journal",
            code: "diagnostic_store_tail_recovered",
            fields: [
                try MirmirDiagnosticField(
                    key: "recovered_byte_count",
                    value: .byteCount(UInt64(recoveredBytes))
                )
            ]
        )
        let record = try MirmirDiagnosticRecord(
            sequence: state.nextSequence,
            timestampUnixMilliseconds: nowMilliseconds,
            uptimeNanoseconds: uptimeNanoseconds,
            sessionID: sessionID,
            event: event
        )
        let line = try recordLine(record)
        guard line.count <= policy.maximumRecordBytes else {
            throw MirmirDiagnosticStoreError.recordExceedsByteLimit(
                observed: line.count,
                maximum: policy.maximumRecordBytes
            )
        }
        state.nextSequence += 1
        state.records.append(
            MirmirStoredDiagnosticRecord(record: record, line: line)
        )
    }

    struct CompleteLines {
        let values: [Data]
        let starts: [Int]
        let trailingStart: Int
    }

    static func completeLines(in data: Data) -> CompleteLines {
        var values: [Data] = []
        var starts: [Int] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            starts.append(start)
            values.append(Data(data[start..<index]))
            start = data.index(after: index)
        }
        return CompleteLines(
            values: values,
            starts: starts,
            trailingStart: start
        )
    }

    static func decodeCanonical<T: Codable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        let value = try JSONDecoder().decode(type, from: data)
        guard try MirmirDiagnosticCanonicalJSON.data(value) == data else {
            throw MirmirDiagnosticStoreError.malformedJournal
        }
        try MirmirDiagnosticPrivacyValidator.validateJSON(data)
        return value
    }

    static func journalSchemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary["schema_version"] as? Int
    }

    static func journalData(_ state: MirmirDiagnosticStoreState) throws -> Data {
        var output = try MirmirDiagnosticCanonicalJSON.data(state.header)
        try MirmirDiagnosticPrivacyValidator.validateJSON(output)
        output.append(0x0A)
        for stored in state.records {
            output.append(stored.line)
        }
        return output
    }

    static func recordLine(_ record: MirmirDiagnosticRecord) throws -> Data {
        var data = try MirmirDiagnosticCanonicalJSON.data(record)
        try MirmirDiagnosticPrivacyValidator.validateJSON(data)
        data.append(0x0A)
        return data
    }

    static func pruneExpired(
        state: inout MirmirDiagnosticStoreState,
        policy: MirmirDiagnosticRetentionPolicy,
        nowMilliseconds: Int64
    ) -> Bool {
        let cutoff = nowMilliseconds > policy.maximumAgeMilliseconds
            ? nowMilliseconds - policy.maximumAgeMilliseconds
            : 0
        let originalCount = state.records.count
        state.records.removeAll {
            $0.record.timestampUnixMilliseconds < cutoff
        }
        let removedCount = originalCount - state.records.count
        guard removedCount > 0 else { return false }
        state.prunedRecordCount = saturatingAdd(
            state.prunedRecordCount,
            UInt64(removedCount)
        )
        return true
    }

    static func pruneFirst(state: inout MirmirDiagnosticStoreState) {
        guard !state.records.isEmpty else { return }
        state.records.removeFirst()
        state.prunedRecordCount = saturatingIncrement(
            state.prunedRecordCount
        )
    }

    static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
