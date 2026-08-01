import Foundation

struct MirmirPendingWorkBookmarks: Codable, Equatable, Sendable {
    let sourceBookmark: Data
    let outputBookmark: Data
    let sourceDisplayName: String
    let outputDisplayName: String
}

struct MirmirProcessingPathBatchContext:
    Codable,
    Equatable,
    Sendable {
    let id: String
    let path: UpscaleEnginePreference
    let ordinal: Int
    let totalCount: Int
}

enum MirmirProcessingPathTerminalStatus:
    String,
    Codable,
    Equatable,
    Sendable {
    case completed
    case failed
    case cancelled
}

struct MirmirProcessingPathBatchResult:
    Codable,
    Equatable,
    Sendable {
    let batch: MirmirProcessingPathBatchContext
    let jobID: String
    let outputDisplayName: String
    let status: MirmirProcessingPathTerminalStatus
    let reason: String?
    let completedAt: Date
}

struct MirmirProcessingPathBatchSummary: Equatable, Sendable {
    let batchID: String
    let totalCount: Int
    let results: [MirmirProcessingPathBatchResult]

    init?(
        batchID: String,
        results: [MirmirProcessingPathBatchResult]
    ) {
        let matching = results
            .filter { $0.batch.id == batchID }
            .sorted { lhs, rhs in
                if lhs.batch.ordinal != rhs.batch.ordinal {
                    return lhs.batch.ordinal < rhs.batch.ordinal
                }
                return lhs.completedAt < rhs.completedAt
            }
        guard let first = matching.first else { return nil }
        self.batchID = batchID
        totalCount = first.batch.totalCount
        self.results = matching
    }

    static func latest(
        in results: [MirmirProcessingPathBatchResult]
    ) -> Self? {
        guard let latest = results.last else {
            return nil
        }
        return Self(batchID: latest.batch.id, results: results)
    }

    var completedCount: Int {
        results.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        results.filter { $0.status == .failed }.count
    }

    var cancelledCount: Int {
        results.filter { $0.status == .cancelled }.count
    }

    var isComplete: Bool {
        results.count == totalCount
    }

    var allSucceeded: Bool {
        isComplete && completedCount == totalCount
    }
}

struct MirmirPendingWorkSettings: Codable, Equatable, Sendable {
    let targetResolution: VideoResolution
    let codec: OutputCodec
    let preserveAudio: Bool
    let requestedMode: UpscaleMode
    let processingConfiguration: UpscaleProcessingConfiguration
    let continuesAfterFailure: Bool
    let processingPathBatch: MirmirProcessingPathBatchContext?

    init(
        targetResolution: VideoResolution,
        codec: OutputCodec,
        preserveAudio: Bool,
        requestedMode: UpscaleMode,
        processingConfiguration: UpscaleProcessingConfiguration,
        continuesAfterFailure: Bool = false,
        processingPathBatch: MirmirProcessingPathBatchContext? = nil
    ) {
        self.targetResolution = targetResolution
        self.codec = codec
        self.preserveAudio = preserveAudio
        self.requestedMode = requestedMode
        self.processingConfiguration = processingConfiguration
        self.continuesAfterFailure = continuesAfterFailure
        self.processingPathBatch = processingPathBatch
    }

    private enum CodingKeys: String, CodingKey {
        case targetResolution
        case codec
        case preserveAudio
        case requestedMode
        case processingConfiguration
        case continuesAfterFailure
        case processingPathBatch
    }

    private struct StoredResolution: Codable {
        let width: Int
        let height: Int
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolution = try container.decode(
            StoredResolution.self,
            forKey: .targetResolution
        )
        targetResolution = VideoResolution(
            width: resolution.width,
            height: resolution.height
        )
        let codecValue = try container.decode(String.self, forKey: .codec)
        guard let decodedCodec = OutputCodec(rawValue: codecValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .codec,
                in: container,
                debugDescription: "Unsupported output codec."
            )
        }
        codec = decodedCodec
        preserveAudio = try container.decode(Bool.self, forKey: .preserveAudio)
        let modeValue = try container.decode(String.self, forKey: .requestedMode)
        guard let decodedMode = UpscaleMode(rawValue: modeValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .requestedMode,
                in: container,
                debugDescription: "Unsupported upscale mode."
            )
        }
        requestedMode = decodedMode
        processingConfiguration = try container.decodeIfPresent(
            UpscaleProcessingConfiguration.self,
            forKey: .processingConfiguration
        ) ?? .default
        continuesAfterFailure = try container.decodeIfPresent(
            Bool.self,
            forKey: .continuesAfterFailure
        ) ?? false
        processingPathBatch = try container.decodeIfPresent(
            MirmirProcessingPathBatchContext.self,
            forKey: .processingPathBatch
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            StoredResolution(
                width: targetResolution.width,
                height: targetResolution.height
            ),
            forKey: .targetResolution
        )
        try container.encode(codec.rawValue, forKey: .codec)
        try container.encode(preserveAudio, forKey: .preserveAudio)
        try container.encode(requestedMode.rawValue, forKey: .requestedMode)
        try container.encode(
            processingConfiguration,
            forKey: .processingConfiguration
        )
        if continuesAfterFailure {
            try container.encode(
                true,
                forKey: .continuesAfterFailure
            )
        }
        try container.encodeIfPresent(
            processingPathBatch,
            forKey: .processingPathBatch
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.targetResolution == rhs.targetResolution
            && lhs.codec.rawValue == rhs.codec.rawValue
            && lhs.preserveAudio == rhs.preserveAudio
            && lhs.requestedMode.rawValue == rhs.requestedMode.rawValue
            && lhs.processingConfiguration == rhs.processingConfiguration
            && lhs.continuesAfterFailure == rhs.continuesAfterFailure
            && lhs.processingPathBatch == rhs.processingPathBatch
    }
}

enum MirmirPendingWorkState:
    String,
    Codable,
    Equatable,
    Sendable {
    case pending
    case started
}

struct MirmirPendingWorkRecord:
    Codable,
    Equatable,
    Identifiable,
    Sendable {
    let id: String
    let bookmarks: MirmirPendingWorkBookmarks
    let settings: MirmirPendingWorkSettings
    let createdAt: Date
    let order: Int
    let state: MirmirPendingWorkState
    let startedAt: Date?

    init(
        id: String,
        bookmarks: MirmirPendingWorkBookmarks,
        settings: MirmirPendingWorkSettings,
        createdAt: Date,
        order: Int,
        state: MirmirPendingWorkState = .pending,
        startedAt: Date? = nil
    ) {
        self.id = id
        self.bookmarks = bookmarks
        self.settings = settings
        self.createdAt = createdAt
        self.order = order
        self.state = state
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bookmarks
        case settings
        case createdAt
        case order
        case state
        case startedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookmarks = try container.decode(
            MirmirPendingWorkBookmarks.self,
            forKey: .bookmarks
        )
        settings = try container.decode(
            MirmirPendingWorkSettings.self,
            forKey: .settings
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        order = try container.decode(Int.self, forKey: .order)
        state = try container.decodeIfPresent(
            MirmirPendingWorkState.self,
            forKey: .state
        ) ?? .pending
        startedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .startedAt
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bookmarks, forKey: .bookmarks)
        try container.encode(settings, forKey: .settings)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(order, forKey: .order)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
    }

    func assigningOrder(_ value: Int) -> Self {
        Self(
            id: id,
            bookmarks: bookmarks,
            settings: settings,
            createdAt: createdAt,
            order: value,
            state: state,
            startedAt: startedAt
        )
    }

    func markingStarted(at date: Date) -> Self {
        Self(
            id: id,
            bookmarks: bookmarks,
            settings: settings,
            createdAt: createdAt,
            order: order,
            state: .started,
            startedAt: date
        )
    }

    func returningToPending() -> Self {
        Self(
            id: id,
            bookmarks: bookmarks,
            settings: settings,
            createdAt: createdAt,
            order: order,
            state: .pending,
            startedAt: nil
        )
    }
}

struct MirmirPendingQueueLimits: Equatable, Sendable {
    static let absoluteMaximumDocumentBytes = 64 * 1_024 * 1_024

    static let production = MirmirPendingQueueLimits(
        maximumRecords: 500,
        maximumDocumentBytes: 8 * 1_024 * 1_024,
        maximumBookmarkBytes: 256 * 1_024,
        validated: true
    )

    let maximumRecords: Int
    let maximumDocumentBytes: Int
    let maximumBookmarkBytes: Int

    init(
        maximumRecords: Int,
        maximumDocumentBytes: Int,
        maximumBookmarkBytes: Int
    ) throws {
        guard maximumRecords > 0,
              maximumRecords <= 100_000,
              maximumDocumentBytes >= 1_024,
              maximumDocumentBytes <= Self.absoluteMaximumDocumentBytes,
              maximumBookmarkBytes > 0,
              maximumBookmarkBytes <= 16 * 1_024 * 1_024,
              maximumBookmarkBytes < maximumDocumentBytes else {
            throw MirmirPendingQueueError.invalidLimits
        }
        self.maximumRecords = maximumRecords
        self.maximumDocumentBytes = maximumDocumentBytes
        self.maximumBookmarkBytes = maximumBookmarkBytes
    }

    private init(
        maximumRecords: Int,
        maximumDocumentBytes: Int,
        maximumBookmarkBytes: Int,
        validated: Bool
    ) {
        precondition(validated)
        self.maximumRecords = maximumRecords
        self.maximumDocumentBytes = maximumDocumentBytes
        self.maximumBookmarkBytes = maximumBookmarkBytes
    }
}

enum MirmirPendingQueueField: String, Equatable, Sendable {
    case jobID = "job_id"
    case sourceBookmark = "source_bookmark"
    case outputBookmark = "output_bookmark"
    case sourceDisplayName = "source_display_name"
    case outputDisplayName = "output_display_name"
    case targetResolution = "target_resolution"
    case createdAt = "created_at"
    case order
    case lifecycle
    case processingPathBatch = "processing_path_batch"
}

enum MirmirPendingQueueOperation: String, Equatable, Sendable {
    case locateApplicationSupport = "locate_application_support"
    case initialize
    case read
    case write
    case quarantine
}

enum MirmirPendingQueueRecoveryReason: String, Equatable, Sendable {
    case malformedDocument = "malformed_document"
    case invalidRecord = "invalid_record"
    case duplicateJobID = "duplicate_job_id"
    case invalidOrder = "invalid_order"
    case invalidLifecycle = "invalid_lifecycle"
    case oversizedDocument = "oversized_document"
    case countBoundExceeded = "count_bound_exceeded"
}

struct MirmirPendingQueueRecovery: Equatable, Sendable {
    let reason: MirmirPendingQueueRecoveryReason
    let quarantineFileName: String
}

struct MirmirPendingQueueSnapshot: Equatable, Sendable {
    let records: [MirmirPendingWorkRecord]
    let processingPathBatchResults:
        [MirmirProcessingPathBatchResult]
    let recovery: MirmirPendingQueueRecovery?

    init(
        records: [MirmirPendingWorkRecord],
        processingPathBatchResults:
            [MirmirProcessingPathBatchResult] = [],
        recovery: MirmirPendingQueueRecovery?
    ) {
        self.records = records
        self.processingPathBatchResults = processingPathBatchResults
        self.recovery = recovery
    }

    var head: MirmirPendingWorkRecord? {
        records.first
    }
}

struct MirmirPendingQueueHeadClaim: Equatable, Sendable {
    let record: MirmirPendingWorkRecord?
    let didMarkStarted: Bool
    let processingPathBatchResults:
        [MirmirProcessingPathBatchResult]
    let recovery: MirmirPendingQueueRecovery?

    init(
        record: MirmirPendingWorkRecord?,
        didMarkStarted: Bool,
        processingPathBatchResults:
            [MirmirProcessingPathBatchResult] = [],
        recovery: MirmirPendingQueueRecovery?
    ) {
        self.record = record
        self.didMarkStarted = didMarkStarted
        self.processingPathBatchResults = processingPathBatchResults
        self.recovery = recovery
    }
}

enum MirmirPendingQueueError:
    Error,
    Equatable,
    LocalizedError,
    Sendable {
    case invalidLimits
    case invalidRecord(field: MirmirPendingQueueField)
    case duplicateJobID
    case recordNotFound
    case recordNotQueueHead
    case recordAlreadyStarted
    case invalidReorder
    case capacityExceeded
    case documentTooLarge
    case unsupportedSchemaVersion(Int)
    case persistenceFailure(operation: MirmirPendingQueueOperation)

    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            return "The pending-work retention policy is invalid."
        case .invalidRecord:
            return "A pending-work record is invalid."
        case .duplicateJobID:
            return "That work item is already queued."
        case .recordNotFound:
            return "The requested pending-work record was not found."
        case .recordNotQueueHead:
            return "Only the queue head can change processing state."
        case .recordAlreadyStarted:
            return "Started work cannot be edited in the pending queue."
        case .invalidReorder:
            return "The requested queue order is invalid."
        case .capacityExceeded:
            return "The pending-work queue is full."
        case .documentTooLarge:
            return "The pending-work queue exceeds its storage limit."
        case .unsupportedSchemaVersion:
            return "The saved pending queue requires a different app version."
        case .persistenceFailure:
            return "Mirmir could not update the pending-work queue."
        }
    }
}
