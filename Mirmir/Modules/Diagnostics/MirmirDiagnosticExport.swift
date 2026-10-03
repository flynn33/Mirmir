import Foundation
import OSLog

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
    static let maximumExportBytes = 256 * 1_024 * 1_024

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
                if let function = source.function {
                    lines.append(
                        "- Function: \(markdownInline(function))"
                    )
                }
            }
            for field in record.event.fields {
                lines.append(
                    "- \(markdownInline(field.key.rawValue)): "
                        + markdownInline(field.value.displayValue)
                )
            }
            if let error = record.event.error {
                if error.omittedUserInfoEntryCount > 0 {
                    lines.append(
                        "- Omitted error userInfo entries: "
                            + "\(error.omittedUserInfoEntryCount)"
                    )
                }
                for (index, frame) in error.frames.enumerated() {
                    lines.append(
                        "- Error \(index): "
                            + "\(markdownInline(frame.type)) "
                            + "[\(markdownInline(frame.domain)):\(frame.code)]"
                    )
                    for entry in frame.userInfo {
                        lines.append(
                            "- Error \(index) userInfo."
                                + "\(markdownInline(entry.key)): "
                                + markdownInline(entry.value)
                        )
                    }
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

/// Exports the unified log entries the OS still exposes for this process.
/// The persistent diagnostic journal remains the source for older sessions
/// and for failures that must survive a process crash.
enum MirmirDiagnosticApplicationLogExport {
    enum CandidateOrder: Equatable, Sendable {
        case chronological
        case newestFirst
    }

    struct Limits: Equatable, Sendable {
        static let production = Self(
            maximumEntries: 50_000,
            maximumBytes: 64 * 1_024 * 1_024,
            maximumMessageBytes: 16_384,
            maximumScannedEntries: 100_000
        )

        let maximumEntries: Int
        let maximumBytes: Int
        let maximumMessageBytes: Int
        let maximumScannedEntries: Int

        init(
            maximumEntries: Int,
            maximumBytes: Int,
            maximumMessageBytes: Int,
            maximumScannedEntries: Int? = nil
        ) {
            self.maximumEntries = max(maximumEntries, 0)
            self.maximumBytes = max(maximumBytes, 0)
            self.maximumMessageBytes = max(maximumMessageBytes, 0)
            self.maximumScannedEntries = max(
                maximumScannedEntries ?? Int.max,
                0
            )
        }
    }

    struct Environment: Equatable, Sendable {
        let exportedAtUnixMilliseconds: Int64
        let applicationName: String
        let bundleIdentifier: String
        let applicationVersion: String
        let applicationBuild: String
        let operatingSystem: String
        let architecture: String
        let processName: String
        let processIdentifier: Int32
        let diagnosticSessionID: String?

        init(
            exportedAtUnixMilliseconds: Int64,
            applicationName: String,
            bundleIdentifier: String,
            applicationVersion: String,
            applicationBuild: String,
            operatingSystem: String,
            architecture: String,
            processName: String,
            processIdentifier: Int32,
            diagnosticSessionID: String? = nil
        ) {
            self.exportedAtUnixMilliseconds = exportedAtUnixMilliseconds
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.applicationVersion = applicationVersion
            self.applicationBuild = applicationBuild
            self.operatingSystem = operatingSystem
            self.architecture = architecture
            self.processName = processName
            self.processIdentifier = processIdentifier
            self.diagnosticSessionID = diagnosticSessionID
        }

        static func current(
            date: Date = Date(),
            diagnosticSessionID: String? = nil
        ) -> Self {
            let bundle = Bundle.main
            let process = ProcessInfo.processInfo
            return Self(
                exportedAtUnixMilliseconds: unixMilliseconds(date),
                applicationName: bundle.object(
                    forInfoDictionaryKey: "CFBundleDisplayName"
                ) as? String
                    ?? bundle.object(
                        forInfoDictionaryKey: "CFBundleName"
                    ) as? String
                    ?? process.processName,
                bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
                applicationVersion: bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                applicationBuild: bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown",
                operatingSystem: process.operatingSystemVersionString,
                architecture: currentArchitecture,
                processName: process.processName,
                processIdentifier: process.processIdentifier,
                diagnosticSessionID: diagnosticSessionID
            )
        }
    }

    enum EntryKind: String, Encodable, Equatable, Sendable {
        case log
        case signpost
    }

    struct SourceEntry: Equatable, Sendable {
        let kind: EntryKind
        let timestampUnixMilliseconds: Int64
        let storeCategory: String
        let process: String
        let processIdentifier: Int32
        let threadIdentifier: UInt64
        let activityIdentifier: UInt64
        let sender: String
        let subsystem: String
        let category: String
        let message: String
        let level: String?
        let signpostName: String?
        let signpostType: String?
        let signpostIdentifier: UInt64?

        init(
            kind: EntryKind,
            timestampUnixMilliseconds: Int64,
            storeCategory: String,
            process: String,
            processIdentifier: Int32,
            threadIdentifier: UInt64,
            activityIdentifier: UInt64,
            sender: String,
            subsystem: String,
            category: String,
            message: String,
            level: String? = nil,
            signpostName: String? = nil,
            signpostType: String? = nil,
            signpostIdentifier: UInt64? = nil
        ) {
            self.kind = kind
            self.timestampUnixMilliseconds = timestampUnixMilliseconds
            self.storeCategory = storeCategory
            self.process = process
            self.processIdentifier = processIdentifier
            self.threadIdentifier = threadIdentifier
            self.activityIdentifier = activityIdentifier
            self.sender = sender
            self.subsystem = subsystem
            self.category = category
            self.message = message
            self.level = level
            self.signpostName = signpostName
            self.signpostType = signpostType
            self.signpostIdentifier = signpostIdentifier
        }
    }

    enum Candidate: Equatable, Sendable {
        case entry(SourceEntry)
        case unsupported
    }

    private struct Entry: Encodable {
        let kind: EntryKind
        let timestampUnixMilliseconds: Int64
        let storeCategory: String
        let process: String
        let processIdentifier: Int32
        let threadIdentifier: UInt64
        let activityIdentifier: UInt64
        let sender: String
        let subsystem: String
        let category: String
        let message: String
        let level: String?
        let signpostName: String?
        let signpostType: String?
        let signpostIdentifier: UInt64?

        enum CodingKeys: String, CodingKey {
            case kind
            case timestampUnixMilliseconds = "timestamp_unix_ms"
            case storeCategory = "store_category"
            case process
            case processIdentifier = "process_identifier"
            case threadIdentifier = "thread_identifier"
            case activityIdentifier = "activity_identifier"
            case sender, subsystem, category, message, level
            case signpostName = "signpost_name"
            case signpostType = "signpost_type"
            case signpostIdentifier = "signpost_identifier"
        }

        init(_ source: SourceEntry) {
            kind = source.kind
            timestampUnixMilliseconds = source.timestampUnixMilliseconds
            storeCategory = singleLine(source.storeCategory)
            process = singleLine(source.process)
            processIdentifier = source.processIdentifier
            threadIdentifier = source.threadIdentifier
            activityIdentifier = source.activityIdentifier
            sender = singleLine(source.sender)
            subsystem = singleLine(source.subsystem)
            category = singleLine(source.category)
            message = singleLine(source.message)
            level = source.level.map(singleLine)
            signpostName = source.signpostName.map(singleLine)
            signpostType = source.signpostType.map(singleLine)
            signpostIdentifier = source.signpostIdentifier
        }
    }

    private struct Document: Encodable {
        let schemaVersion: Int
        let exportedAtUnixMilliseconds: Int64
        let scope: String
        let applicationName: String
        let bundleIdentifier: String
        let applicationVersion: String
        let applicationBuild: String
        let operatingSystem: String
        let architecture: String
        let processName: String
        let processIdentifier: Int32
        let diagnosticSessionID: String?
        let scannedEntryCount: Int
        let scanEntryLimit: Int
        let retainedEntryCount: Int
        let omittedPrivateEntryCount: Int
        let omittedOversizeEntryCount: Int
        let omittedUnsupportedEntryCount: Int
        let omittedEntryLimitCount: Int
        let omittedByteLimitEntryCount: Int
        let omittedScanLimitEntryCountMinimum: Int
        let truncated: Bool
        let entries: [Entry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case exportedAtUnixMilliseconds = "exported_at_unix_ms"
            case scope
            case applicationName = "application_name"
            case bundleIdentifier = "bundle_identifier"
            case applicationVersion = "application_version"
            case applicationBuild = "application_build"
            case operatingSystem = "operating_system"
            case architecture
            case processName = "process_name"
            case processIdentifier = "process_identifier"
            case diagnosticSessionID = "diagnostic_session_id"
            case scannedEntryCount = "scanned_entry_count"
            case scanEntryLimit = "scan_entry_limit"
            case retainedEntryCount = "retained_entry_count"
            case omittedPrivateEntryCount = "omitted_private_entry_count"
            case omittedOversizeEntryCount = "omitted_oversize_entry_count"
            case omittedUnsupportedEntryCount =
                "omitted_unsupported_entry_count"
            case omittedEntryLimitCount = "omitted_entry_limit_count"
            case omittedByteLimitEntryCount =
                "omitted_byte_limit_entry_count"
            case omittedScanLimitEntryCountMinimum =
                "omitted_scan_limit_entry_count_minimum"
            case truncated, entries
        }
    }

    static func json(diagnosticSessionID: String? = nil) throws -> Data {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let candidates = try store.getEntries(
            with: [.reverse],
            at: nil,
            matching: nil
        ).lazy.map { candidate($0) }
        return try json(
            candidates: candidates,
            environment: .current(
                diagnosticSessionID: diagnosticSessionID
            ),
            limits: .production,
            candidateOrder: .newestFirst
        )
    }

    static func json<S: Sequence>(
        candidates: S,
        environment: Environment,
        limits: Limits,
        candidateOrder: CandidateOrder = .chronological
    ) throws -> Data where S.Element == Candidate {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var entries: [Entry] = []
        var omittedPrivateEntryCount = 0
        var omittedOversizeEntryCount = 0
        var omittedUnsupportedEntryCount = 0
        var omittedEntryLimitCount = 0
        var omittedByteLimitEntryCount = 0
        var retainedEntryByteCount = 0
        var scannedEntryCount = 0

        let maximumEnvelope = document(
            environment: environment,
            scannedEntryCount: Int.max,
            scanEntryLimit: Int.max,
            retainedEntryCount: Int.max,
            omittedPrivateEntryCount: Int.max,
            omittedOversizeEntryCount: Int.max,
            omittedUnsupportedEntryCount: Int.max,
            omittedEntryLimitCount: Int.max,
            omittedByteLimitEntryCount: Int.max,
            omittedScanLimitEntryCountMinimum: Int.max,
            truncated: false,
            entries: []
        )
        let maximumEnvelopeByteCount = try encoder.encode(
            maximumEnvelope
        ).count
        guard maximumEnvelopeByteCount + 1 <= limits.maximumBytes else {
            throw MirmirDiagnosticExportError.exportExceedsByteLimit(
                observed: maximumEnvelopeByteCount + 1,
                maximum: limits.maximumBytes
            )
        }

        var iterator = candidates.makeIterator()
        while scannedEntryCount < limits.maximumScannedEntries,
              let candidate = iterator.next() {
            increment(&scannedEntryCount)
            guard case .entry(let source) = candidate else {
                increment(&omittedUnsupportedEntryCount)
                continue
            }
            let entry = Entry(source)
            guard entry.message.utf8.count <= limits.maximumMessageBytes else {
                increment(&omittedOversizeEntryCount)
                continue
            }
            let entryData = try encoder.encode(entry)
            guard (try? MirmirDiagnosticPrivacyValidator.validateJSON(
                entryData
            )) != nil else {
                increment(&omittedPrivateEntryCount)
                continue
            }
            guard entries.count < limits.maximumEntries else {
                increment(&omittedEntryLimitCount)
                continue
            }

            let newEntryCount = entries.count + 1
            let byteCounts = [
                maximumEnvelopeByteCount,
                retainedEntryByteCount,
                entryData.count,
                max(newEntryCount - 1, 0),
                1
            ]
            guard sumFits(byteCounts, maximum: limits.maximumBytes) else {
                increment(&omittedByteLimitEntryCount)
                continue
            }
            retainedEntryByteCount += entryData.count
            entries.append(entry)
        }
        let omittedScanLimitEntryCountMinimum = iterator.next() == nil ? 0 : 1
        if candidateOrder == .newestFirst {
            entries.reverse()
        }

        let document = document(
            environment: environment,
            scannedEntryCount: scannedEntryCount,
            scanEntryLimit: limits.maximumScannedEntries,
            retainedEntryCount: entries.count,
            omittedPrivateEntryCount: omittedPrivateEntryCount,
            omittedOversizeEntryCount: omittedOversizeEntryCount,
            omittedUnsupportedEntryCount: omittedUnsupportedEntryCount,
            omittedEntryLimitCount: omittedEntryLimitCount,
            omittedByteLimitEntryCount: omittedByteLimitEntryCount,
            omittedScanLimitEntryCountMinimum:
                omittedScanLimitEntryCountMinimum,
            truncated: omittedEntryLimitCount > 0
                || omittedByteLimitEntryCount > 0
                || omittedScanLimitEntryCountMinimum > 0,
            entries: entries
        )
        var data = try encoder.encode(document)
        data.append(0x0A)
        guard data.count <= limits.maximumBytes else {
            throw MirmirDiagnosticExportError.exportExceedsByteLimit(
                observed: data.count,
                maximum: limits.maximumBytes
            )
        }
        try MirmirDiagnosticPrivacyValidator.validateJSON(data)
        return data
    }

    private static func candidate(_ entry: OSLogEntry) -> Candidate {
        if let log = entry as? OSLogEntryLog {
            return .entry(SourceEntry(
                kind: .log,
                timestampUnixMilliseconds: unixMilliseconds(log.date),
                storeCategory: String(describing: log.storeCategory),
                process: log.process,
                processIdentifier: log.processIdentifier,
                threadIdentifier: log.threadIdentifier,
                activityIdentifier: log.activityIdentifier,
                sender: log.sender,
                subsystem: log.subsystem,
                category: log.category,
                message: log.composedMessage,
                level: String(describing: log.level)
            ))
        }
        if let signpost = entry as? OSLogEntrySignpost {
            return .entry(SourceEntry(
                kind: .signpost,
                timestampUnixMilliseconds: unixMilliseconds(signpost.date),
                storeCategory: String(describing: signpost.storeCategory),
                process: signpost.process,
                processIdentifier: signpost.processIdentifier,
                threadIdentifier: signpost.threadIdentifier,
                activityIdentifier: signpost.activityIdentifier,
                sender: signpost.sender,
                subsystem: signpost.subsystem,
                category: signpost.category,
                message: signpost.composedMessage,
                signpostName: signpost.signpostName,
                signpostType: String(describing: signpost.signpostType),
                signpostIdentifier: signpost.signpostIdentifier
            ))
        }
        return .unsupported
    }

    private static func document(
        environment: Environment,
        scannedEntryCount: Int,
        scanEntryLimit: Int,
        retainedEntryCount: Int,
        omittedPrivateEntryCount: Int,
        omittedOversizeEntryCount: Int,
        omittedUnsupportedEntryCount: Int,
        omittedEntryLimitCount: Int,
        omittedByteLimitEntryCount: Int,
        omittedScanLimitEntryCountMinimum: Int,
        truncated: Bool,
        entries: [Entry]
    ) -> Document {
        Document(
            schemaVersion: 1,
            exportedAtUnixMilliseconds:
                environment.exportedAtUnixMilliseconds,
            scope: "current_process_available_unified_logs",
            applicationName: singleLine(environment.applicationName),
            bundleIdentifier: singleLine(environment.bundleIdentifier),
            applicationVersion: singleLine(environment.applicationVersion),
            applicationBuild: singleLine(environment.applicationBuild),
            operatingSystem: singleLine(environment.operatingSystem),
            architecture: singleLine(environment.architecture),
            processName: singleLine(environment.processName),
            processIdentifier: environment.processIdentifier,
            diagnosticSessionID: environment.diagnosticSessionID.map(
                singleLine
            ),
            scannedEntryCount: scannedEntryCount,
            scanEntryLimit: scanEntryLimit,
            retainedEntryCount: retainedEntryCount,
            omittedPrivateEntryCount: omittedPrivateEntryCount,
            omittedOversizeEntryCount: omittedOversizeEntryCount,
            omittedUnsupportedEntryCount: omittedUnsupportedEntryCount,
            omittedEntryLimitCount: omittedEntryLimitCount,
            omittedByteLimitEntryCount: omittedByteLimitEntryCount,
            omittedScanLimitEntryCountMinimum:
                omittedScanLimitEntryCountMinimum,
            truncated: truncated,
            entries: entries
        )
    }

    private static func sumFits(
        _ values: [Int],
        maximum: Int
    ) -> Bool {
        var remaining = maximum
        for value in values {
            guard value >= 0, value <= remaining else { return false }
            remaining -= value
        }
        return true
    }

    private static func increment(_ value: inout Int) {
        if value < Int.max {
            value += 1
        }
    }

    private static func singleLine(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            scalar.value < 0x20 ? Character(" ") : Character(scalar)
        })
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000).rounded()
        guard value.isFinite else { return 0 }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
