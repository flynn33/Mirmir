import Foundation

extension R13ReleaseUpscalerEngineService {
    func releaseDiagnosticsSnapshot() async
        -> R13ReleaseDiagnosticsSnapshot? {
        await hardeningRuntime?.diagnosticsSnapshot()
    }
}

extension R13ReleaseHardeningRuntime {
    func diagnosticsSnapshot() async -> R13ReleaseDiagnosticsSnapshot {
        await diagnostics.snapshot()
    }
}

enum R13ReleaseDiagnosticsError: Error, Equatable, Sendable {
    case invalidSHA256(field: String)
    case emptyFields
    case tooManyFields(maximum: Int)
    case duplicateField(String)
    case invalidPolicy(reason: String)
    case recordExceedsByteLimit(observed: Int, maximum: Int)
}

enum R13ReleaseDiagnosticCode: String, CaseIterable, Sendable {
    case releaseIdentityCreated = "release_identity_created"
    case resourceAdmitted = "resource_admitted"
    case resourceRejected = "resource_rejected"
    case resourceReleased = "resource_released"
    case faultObserved = "fault_observed"
    case outputReopened = "output_reopened"
    case bookmarkReopened = "bookmark_reopened"
    case recoveryDiscovered = "recovery_discovered"
    case cacheFrameReplayed = "cache_frame_replayed"
    case cacheFrameCommitted = "cache_frame_committed"
    case jobCompleted = "job_completed"
    case sourceSnapshotCleanupFailed =
        "source_snapshot_cleanup_failed"
    case postpublicationMaintenanceDeferred =
        "postpublication_maintenance_deferred"
}

enum R13ReleaseDiagnosticSeverity: String, CaseIterable, Sendable {
    case info
    case warning
    case error
}

enum R13ReleaseDiagnosticOutcome: String, CaseIterable, Sendable {
    case accepted
    case rejected
    case released
    case alreadyReleased = "already_released"
    case notObserved = "not_observed"
    case reopened
}

enum R13ReleaseDiagnosticReason: String, CaseIterable, Sendable {
    case concurrencyLimit = "concurrency_limit"
    case diskInsufficient = "disk_insufficient"
    case memoryInsufficient = "memory_insufficient"
    case thermalLimited = "thermal_limited"
    case probeFailed = "probe_failed"
    case injectedFault = "injected_fault"
    case metadataMismatch = "metadata_mismatch"
    case identityMismatch = "identity_mismatch"
    case prepublicationReceiptUnavailable =
        "prepublication_receipt_unavailable"
    case publishedOutputIdentityMismatch =
        "published_output_identity_mismatch"
    case cacheCleanupFailed = "cache_cleanup_failed"
    case mediaCleanupFailed = "media_cleanup_failed"
    case sourceSnapshotCleanupFailed =
        "source_snapshot_cleanup_failed"
}

enum R13ReleaseDiagnosticFieldKey: String, CaseIterable, Sendable {
    case releaseIdentitySHA256 = "release_identity_sha256"
    case jobIdentitySHA256 = "job_identity_sha256"
    case policySHA256 = "policy_sha256"
    case resourceManifestSHA256 = "resource_manifest_sha256"
    case mode
    case backendID = "backend_id"
    case routeID = "route_id"
    case outcome
    case reason
    case faultPoint = "fault_point"
}

struct R13ReleaseDiagnosticField: Equatable, Sendable {
    let key: R13ReleaseDiagnosticFieldKey
    let value: String

    private init(key: R13ReleaseDiagnosticFieldKey, value: String) {
        self.key = key
        self.value = value
    }

    static func releaseIdentitySHA256(
        _ value: String
    ) throws -> R13ReleaseDiagnosticField {
        try hashField(
            key: .releaseIdentitySHA256,
            value: value,
            field: "diagnostic_release_identity_sha256"
        )
    }

    static func jobIdentitySHA256(
        _ value: String
    ) throws -> R13ReleaseDiagnosticField {
        try hashField(
            key: .jobIdentitySHA256,
            value: value,
            field: "diagnostic_job_identity_sha256"
        )
    }

    static func policySHA256(
        _ value: String
    ) throws -> R13ReleaseDiagnosticField {
        try hashField(
            key: .policySHA256,
            value: value,
            field: "diagnostic_policy_sha256"
        )
    }

    static func resourceManifestSHA256(
        _ value: String
    ) throws -> R13ReleaseDiagnosticField {
        try hashField(
            key: .resourceManifestSHA256,
            value: value,
            field: "diagnostic_resource_manifest_sha256"
        )
    }

    static func mode(_ value: UpscaleMode) -> R13ReleaseDiagnosticField {
        R13ReleaseDiagnosticField(key: .mode, value: value.rawValue)
    }

    static var a11Backend: R13ReleaseDiagnosticField {
        R13ReleaseDiagnosticField(
            key: .backendID,
            value: R03A11ProductAdmission.subjectID.rawValue
        )
    }

    static func backend(
        _ value: String
    ) -> R13ReleaseDiagnosticField {
        R13ReleaseDiagnosticField(
            key: .backendID,
            value: value
        )
    }

    static func route(_ value: R03ScaleRoute) -> R13ReleaseDiagnosticField {
        R13ReleaseDiagnosticField(key: .routeID, value: value.rawValue)
    }

    static func outcome(
        _ value: R13ReleaseDiagnosticOutcome
    ) -> R13ReleaseDiagnosticField {
        R13ReleaseDiagnosticField(key: .outcome, value: value.rawValue)
    }

    static func reason(
        _ value: R13ReleaseDiagnosticReason
    ) -> R13ReleaseDiagnosticField {
        R13ReleaseDiagnosticField(key: .reason, value: value.rawValue)
    }

    static func faultPoint(
        _ value: R13FaultPoint
    ) -> R13ReleaseDiagnosticField {
        R13ReleaseDiagnosticField(key: .faultPoint, value: value.rawValue)
    }

    private static func hashField(
        key: R13ReleaseDiagnosticFieldKey,
        value: String,
        field: String
    ) throws -> R13ReleaseDiagnosticField {
        do {
            return R13ReleaseDiagnosticField(
                key: key,
                value: try R13ReleaseIdentityValidation.sha256(
                    value,
                    field: field
                )
            )
        } catch {
            throw R13ReleaseDiagnosticsError.invalidSHA256(field: field)
        }
    }
}

struct R13ReleaseDiagnosticEvent: Equatable, Sendable {
    static let maximumFields = 8

    let code: R13ReleaseDiagnosticCode
    let severity: R13ReleaseDiagnosticSeverity
    let fields: [R13ReleaseDiagnosticField]

    init(
        code: R13ReleaseDiagnosticCode,
        severity: R13ReleaseDiagnosticSeverity,
        fields: [R13ReleaseDiagnosticField]
    ) throws {
        guard !fields.isEmpty else {
            throw R13ReleaseDiagnosticsError.emptyFields
        }
        guard fields.count <= Self.maximumFields else {
            throw R13ReleaseDiagnosticsError.tooManyFields(
                maximum: Self.maximumFields
            )
        }
        var observed: Set<String> = []
        for field in fields {
            guard observed.insert(field.key.rawValue).inserted else {
                throw R13ReleaseDiagnosticsError.duplicateField(
                    field.key.rawValue
                )
            }
        }
        self.code = code
        self.severity = severity
        self.fields = fields.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    var boundedByteCount: Int {
        code.rawValue.utf8.count
            + severity.rawValue.utf8.count
            + fields.reduce(into: 0) { count, field in
                count += field.key.rawValue.utf8.count
                count += field.value.utf8.count
                count += 2
            }
            + 16
    }
}

struct R13ReleaseDiagnosticsPolicy: Equatable, Sendable {
    let maximumRecords: Int
    let maximumTotalBytes: Int

    init(maximumRecords: Int, maximumTotalBytes: Int) throws {
        guard maximumRecords > 0, maximumRecords <= 256 else {
            throw R13ReleaseDiagnosticsError.invalidPolicy(
                reason: "maximum_records_out_of_range"
            )
        }
        guard maximumTotalBytes > 0, maximumTotalBytes <= 65_536 else {
            throw R13ReleaseDiagnosticsError.invalidPolicy(
                reason: "maximum_total_bytes_out_of_range"
            )
        }
        self.maximumRecords = maximumRecords
        self.maximumTotalBytes = maximumTotalBytes
    }
}

struct R13ReleaseDiagnosticRecord: Equatable, Sendable {
    let sequence: UInt64
    let event: R13ReleaseDiagnosticEvent
    let boundedByteCount: Int
}

enum R13ReleaseDiagnosticWriteOutcome: Equatable, Sendable {
    case recorded(R13ReleaseDiagnosticRecord)
    case rejected(R13ReleaseDiagnosticsError)
}

struct R13ReleaseDiagnosticsSnapshot: Equatable, Sendable {
    let records: [R13ReleaseDiagnosticRecord]
    let retainedByteCount: Int
    let droppedRecordCount: UInt64
    let nextSequence: UInt64
}

actor R13ReleaseDiagnostics {
    private let policy: R13ReleaseDiagnosticsPolicy
    private var records: [R13ReleaseDiagnosticRecord] = []
    private var retainedByteCount = 0
    private var droppedRecordCount: UInt64 = 0
    private var nextSequence: UInt64 = 0

    init(policy: R13ReleaseDiagnosticsPolicy) {
        self.policy = policy
    }

    func record(
        _ event: R13ReleaseDiagnosticEvent
    ) -> R13ReleaseDiagnosticWriteOutcome {
        let byteCount = event.boundedByteCount
        guard byteCount <= policy.maximumTotalBytes else {
            return .rejected(
                .recordExceedsByteLimit(
                    observed: byteCount,
                    maximum: policy.maximumTotalBytes
                )
            )
        }

        while records.count >= policy.maximumRecords
            || retainedByteCount + byteCount > policy.maximumTotalBytes {
            let removed = records.removeFirst()
            retainedByteCount -= removed.boundedByteCount
            if droppedRecordCount < UInt64.max {
                droppedRecordCount += 1
            }
        }

        let record = R13ReleaseDiagnosticRecord(
            sequence: nextSequence,
            event: event,
            boundedByteCount: byteCount
        )
        if nextSequence < UInt64.max {
            nextSequence += 1
        }
        records.append(record)
        retainedByteCount += byteCount
        return .recorded(record)
    }

    func snapshot() -> R13ReleaseDiagnosticsSnapshot {
        R13ReleaseDiagnosticsSnapshot(
            records: records,
            retainedByteCount: retainedByteCount,
            droppedRecordCount: droppedRecordCount,
            nextSequence: nextSequence
        )
    }
}

protocol R13ReleaseDiagnosticsProviding: Sendable {
    func releaseDiagnosticsSnapshot() async
        -> R13ReleaseDiagnosticsSnapshot?
}
