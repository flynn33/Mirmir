import Foundation

struct MirmirDiagnosticSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAtUnixMilliseconds: Int64
    let retainedRecordCount: Int
    let retainedByteCount: Int
    let prunedRecordCount: UInt64
    let rejectedRecordCount: UInt64
    let recoveredCorruptTailCount: UInt64
    let recoveredCorruptByteCount: UInt64
    let persistenceFailureCount: UInt64
    let lastPersistenceFailureOperation: String?
    let records: [MirmirDiagnosticRecord]

    init(
        exportedAtUnixMilliseconds: Int64,
        retainedByteCount: Int,
        prunedRecordCount: UInt64,
        rejectedRecordCount: UInt64,
        recoveredCorruptTailCount: UInt64,
        recoveredCorruptByteCount: UInt64,
        persistenceFailureCount: UInt64 = 0,
        lastPersistenceFailureOperation: String? = nil,
        records: [MirmirDiagnosticRecord]
    ) throws {
        guard exportedAtUnixMilliseconds >= 0,
              retainedByteCount >= 0 else {
            throw MirmirDiagnosticValidationError.invalidTimestamp
        }
        if let lastPersistenceFailureOperation {
            _ = try MirmirDiagnosticToken(
                lastPersistenceFailureOperation,
                field: "last_persistence_failure_operation"
            )
        }
        let ordered = records.sorted { $0.sequence < $1.sequence }
        for (left, right) in zip(ordered, ordered.dropFirst())
        where left.sequence == right.sequence {
            throw MirmirDiagnosticValidationError.invalidRecordSchema
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAtUnixMilliseconds = exportedAtUnixMilliseconds
        self.retainedRecordCount = ordered.count
        self.retainedByteCount = retainedByteCount
        self.prunedRecordCount = prunedRecordCount
        self.rejectedRecordCount = rejectedRecordCount
        self.recoveredCorruptTailCount = recoveredCorruptTailCount
        self.recoveredCorruptByteCount = recoveredCorruptByteCount
        self.persistenceFailureCount = persistenceFailureCount
        self.lastPersistenceFailureOperation =
            lastPersistenceFailureOperation
        self.records = ordered
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAtUnixMilliseconds = "exported_at_unix_ms"
        case retainedRecordCount = "retained_record_count"
        case retainedByteCount = "retained_byte_count"
        case prunedRecordCount = "pruned_record_count"
        case rejectedRecordCount = "rejected_record_count"
        case recoveredCorruptTailCount = "recovered_corrupt_tail_count"
        case recoveredCorruptByteCount = "recovered_corrupt_byte_count"
        case persistenceFailureCount = "persistence_failure_count"
        case lastPersistenceFailureOperation =
            "last_persistence_failure_operation"
        case records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported diagnostic snapshot schema."
            )
        }
        let retainedRecordCount = try container.decode(
            Int.self,
            forKey: .retainedRecordCount
        )
        let records = try container.decode(
            [MirmirDiagnosticRecord].self,
            forKey: .records
        )
        guard retainedRecordCount == records.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .retainedRecordCount,
                in: container,
                debugDescription: "Invalid diagnostic record count."
            )
        }
        do {
            try self.init(
                exportedAtUnixMilliseconds: container.decode(
                    Int64.self,
                    forKey: .exportedAtUnixMilliseconds
                ),
                retainedByteCount: container.decode(
                    Int.self,
                    forKey: .retainedByteCount
                ),
                prunedRecordCount: container.decode(
                    UInt64.self,
                    forKey: .prunedRecordCount
                ),
                rejectedRecordCount: container.decode(
                    UInt64.self,
                    forKey: .rejectedRecordCount
                ),
                recoveredCorruptTailCount: container.decode(
                    UInt64.self,
                    forKey: .recoveredCorruptTailCount
                ),
                recoveredCorruptByteCount: container.decode(
                    UInt64.self,
                    forKey: .recoveredCorruptByteCount
                ),
                persistenceFailureCount: container.decodeIfPresent(
                    UInt64.self,
                    forKey: .persistenceFailureCount
                ) ?? 0,
                lastPersistenceFailureOperation: container.decodeIfPresent(
                    String.self,
                    forKey: .lastPersistenceFailureOperation
                ),
                records: records
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: "Invalid diagnostic snapshot."
            )
        }
    }
}

enum MirmirDiagnosticExportError: Error, Equatable, Sendable {
    case exportExceedsByteLimit(observed: Int, maximum: Int)
}

enum MirmirDiagnosticExport {
    static let maximumExportBytes = 32 * 1_024 * 1_024

    static func json(_ snapshot: MirmirDiagnosticSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        guard data.count <= maximumExportBytes else {
            throw MirmirDiagnosticExportError.exportExceedsByteLimit(
                observed: data.count,
                maximum: maximumExportBytes
            )
        }
        try MirmirDiagnosticPrivacyValidator.validateJSON(data)
        return data
    }

    static func markdown(_ snapshot: MirmirDiagnosticSnapshot) throws -> Data {
        var lines = [
            "# Mirmir Diagnostic Log",
            "",
            "- Schema version: \(snapshot.schemaVersion)",
            "- Exported at: \(utcTimestamp(snapshot.exportedAtUnixMilliseconds))",
            "- Retained records: \(snapshot.retainedRecordCount)",
            "- Retained bytes: \(snapshot.retainedByteCount)",
            "- Pruned records: \(snapshot.prunedRecordCount)",
            "- Rejected records: \(snapshot.rejectedRecordCount)",
            "- Recovered corrupt tails: \(snapshot.recoveredCorruptTailCount)",
            "- Recovered corrupt bytes: \(snapshot.recoveredCorruptByteCount)",
            "- Persistence failures: \(snapshot.persistenceFailureCount)",
            "- Last persistence failure: "
                + (snapshot.lastPersistenceFailureOperation ?? "none"),
            "",
            "## Records"
        ]

        for record in snapshot.records {
            lines.append("")
            lines.append(
                "### Record \(String(format: "%020llu", record.sequence))"
            )
            lines.append("")
            lines.append(
                "- Timestamp: \(utcTimestamp(record.timestampUnixMilliseconds))"
            )
            lines.append("- Severity: \(record.event.severity.rawValue)")
            lines.append(
                "- Subsystem: \(markdownInline(record.event.subsystem.rawValue))"
            )
            lines.append(
                "- Operation: \(markdownInline(record.event.operation.rawValue))"
            )
            lines.append("- Code: \(markdownInline(record.event.code.rawValue))")
            lines.append("- Session: \(record.sessionID.rawValue)")
            if let correlationID = record.event.correlationID {
                lines.append("- Correlation: \(correlationID.rawValue)")
            }
            lines.append("- Uptime ns: \(record.uptimeNanoseconds)")
            if let source = record.event.source {
                lines.append(
                    "- Source: \(markdownInline(source.fileID)):\(source.line)"
                )
            }
            for field in record.event.fields {
                lines.append(
                    "- \(markdownInline(field.key.rawValue)): "
                        + markdownInline(field.value.displayValue)
                )
            }
            if let error = record.event.error {
                for (index, frame) in error.frames.enumerated() {
                    lines.append(
                        "- Error \(index): "
                            + "\(markdownInline(frame.type)) "
                            + "[\(markdownInline(frame.domain)):\(frame.code)]"
                    )
                }
            }
        }

        let value = lines.joined(separator: "\n") + "\n"
        guard let data = value.data(using: .utf8) else {
            throw MirmirDiagnosticValidationError.privacyViolation
        }
        guard data.count <= maximumExportBytes else {
            throw MirmirDiagnosticExportError.exportExceedsByteLimit(
                observed: data.count,
                maximum: maximumExportBytes
            )
        }
        try MirmirDiagnosticPrivacyValidator.validateDocumentText(value)
        return data
    }

    static func utcTimestamp(_ milliseconds: Int64) -> String {
        let date = Date(
            timeIntervalSince1970: Double(milliseconds) / 1_000
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func markdownInline(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "<", ">"] {
            escaped = escaped.replacingOccurrences(
                of: character,
                with: "\\\(character)"
            )
        }
        return escaped
    }
}
