import Foundation

// The persisted schema and its actor implementation remain contiguous so a
// schema change can be reviewed as one unit.
// swiftlint:disable file_length

enum MirmirWorkHistoryBookmarkRole: String, Codable, Equatable, Sendable {
    case source
    case output
}

enum MirmirWorkHistoryBookmarkError:
    Error,
    Equatable,
    LocalizedError,
    Sendable {
    case creationFailed(role: MirmirWorkHistoryBookmarkRole)
    case resolutionFailed(role: MirmirWorkHistoryBookmarkRole)

    var errorDescription: String? {
        switch self {
        case .creationFailed:
            return "Mirmir could not preserve access to the selected item."
        case .resolutionFailed:
            return "Mirmir could not restore access to the selected item."
        }
    }
}

struct MirmirWorkHistoryResolvedBookmark: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

enum MirmirWorkHistoryOutputBookmarkScope:
    String,
    Codable,
    Equatable,
    Sendable {
    case file
    case directory
}

struct MirmirWorkHistoryResolvedLocations: Equatable, Sendable {
    let sourceURL: URL
    let outputDirectoryURL: URL
    let outputFileURL: URL
    let sourceBookmarkIsStale: Bool
    let outputBookmarkIsStale: Bool
}

enum MirmirWorkHistoryLocationError:
    Error,
    Equatable,
    LocalizedError,
    Sendable {
    case invalidFileURL(role: MirmirWorkHistoryBookmarkRole)
    case invalidDisplayName(role: MirmirWorkHistoryBookmarkRole)
    case outputFileDerivationFailed
    case legacyOutputBookmarkMismatch

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            return "A saved work-history location is not a valid file URL."
        case .invalidDisplayName:
            return "A saved work-history file name is invalid."
        case .outputFileDerivationFailed:
            return "The saved output file cannot be derived safely."
        case .legacyOutputBookmarkMismatch:
            return "The saved output bookmark does not match its file name."
        }
    }
}

protocol MirmirWorkHistoryBookmarkResolving: Sendable {
    func makeBookmark(
        for url: URL,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> Data

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark
}

struct MirmirFoundationWorkBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    func makeBookmark(
        for url: URL,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw MirmirWorkHistoryBookmarkError.creationFailed(role: role)
        }
    }

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return MirmirWorkHistoryResolvedBookmark(
                url: url,
                isStale: isStale
            )
        } catch {
            throw MirmirWorkHistoryBookmarkError.resolutionFailed(role: role)
        }
    }
}

protocol MirmirWorkFileAvailabilityChecking: Sendable {
    func isAvailable(at url: URL) -> Bool
}

struct MirmirFoundationWorkFileChecker:
    MirmirWorkFileAvailabilityChecking {
    func isAvailable(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

enum MirmirWorkHistoryBookmarkState: String, Equatable, Sendable {
    case available
    case missing
    case reauthorizationRequired = "reauthorization_required"
}

struct MirmirWorkHistoryBookmarkStates: Equatable, Sendable {
    let source: MirmirWorkHistoryBookmarkState
    let output: MirmirWorkHistoryBookmarkState
}

enum MirmirWorkTerminalResult:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Sendable {
    case completed
    case failed
    case cancelled
    case interrupted
}

enum MirmirWorkOutputAvailability:
    String,
    Codable,
    Equatable,
    Sendable {
    case available
    case unavailable
}

struct MirmirWorkOutputVerification: Codable, Equatable, Sendable {
    let availability: MirmirWorkOutputAvailability
    let identity: String?

    static func available(identity: String) -> Self {
        Self(availability: .available, identity: identity)
    }

    static let unavailable = Self(
        availability: .unavailable,
        identity: nil
    )
}

struct MirmirWorkHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceBookmark: Data
    let outputBookmark: Data
    let outputBookmarkScope: MirmirWorkHistoryOutputBookmarkScope
    let sourceDisplayName: String
    let outputDisplayName: String
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let codec: OutputCodec
    // Nil identifies a record written before exact audio-track counts existed.
    let sourceAudioTrackCount: Int?
    // Nil identifies a record written before exact scan structure existed.
    let sourceScanStructure: MediaVideoScanStructure?
    let preserveAudio: Bool
    let requestedMode: UpscaleMode
    let processingConfiguration: UpscaleProcessingConfiguration
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date
    let terminalResult: MirmirWorkTerminalResult
    let outputVerification: MirmirWorkOutputVerification

    init(
        id: String,
        sourceBookmark: Data,
        outputBookmark: Data,
        outputBookmarkScope:
            MirmirWorkHistoryOutputBookmarkScope = .directory,
        sourceDisplayName: String,
        outputDisplayName: String,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        codec: OutputCodec,
        sourceAudioTrackCount: Int? = nil,
        sourceScanStructure: MediaVideoScanStructure? = nil,
        preserveAudio: Bool,
        requestedMode: UpscaleMode,
        processingConfiguration: UpscaleProcessingConfiguration,
        createdAt: Date,
        startedAt: Date?,
        completedAt: Date,
        terminalResult: MirmirWorkTerminalResult,
        outputVerification: MirmirWorkOutputVerification
    ) {
        self.id = id
        self.sourceBookmark = sourceBookmark
        self.outputBookmark = outputBookmark
        self.outputBookmarkScope = outputBookmarkScope
        self.sourceDisplayName = sourceDisplayName
        self.outputDisplayName = outputDisplayName
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.codec = codec
        self.sourceAudioTrackCount = sourceAudioTrackCount
        self.sourceScanStructure = sourceScanStructure
        self.preserveAudio = preserveAudio
        self.requestedMode = requestedMode
        self.processingConfiguration = processingConfiguration
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.terminalResult = terminalResult
        self.outputVerification = outputVerification
    }

    // A history record intentionally captures the complete processing request.
    // swiftlint:disable:next function_parameter_count
    static func capturing(
        id: String,
        sourceURL: URL,
        outputURL: URL,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        codec: OutputCodec,
        sourceAudioTrackCount: Int,
        sourceScanStructure: MediaVideoScanStructure? = nil,
        preserveAudio: Bool,
        requestedMode: UpscaleMode,
        processingConfiguration: UpscaleProcessingConfiguration,
        createdAt: Date,
        startedAt: Date?,
        completedAt: Date,
        terminalResult: MirmirWorkTerminalResult,
        outputVerification: MirmirWorkOutputVerification,
        resolver: any MirmirWorkHistoryBookmarkResolving
    ) throws -> Self {
        let validatedSourceURL =
            try MirmirWorkHistoryLocationValidator.fileURL(
                sourceURL,
                role: .source
            )
        let validatedOutputURL =
            try MirmirWorkHistoryLocationValidator.fileURL(
                outputURL,
                role: .output
            )
        let sourceDisplayName =
            validatedSourceURL.lastPathComponent
        try MirmirWorkHistoryLocationValidator.validateDisplayName(
            sourceDisplayName,
            role: .source
        )
        let outputDisplayName =
            validatedOutputURL.lastPathComponent
        try MirmirWorkHistoryLocationValidator.validateDisplayName(
            outputDisplayName,
            role: .output
        )
        let outputDirectoryURL =
            validatedOutputURL.deletingLastPathComponent()
        let derivedOutputURL =
            try MirmirWorkHistoryLocationValidator.outputFileURL(
                directoryURL: outputDirectoryURL,
                displayName: outputDisplayName
            )
        guard derivedOutputURL == validatedOutputURL else {
            throw MirmirWorkHistoryLocationError
                .outputFileDerivationFailed
        }

        let sourceBookmark: Data
        let outputBookmark: Data
        do {
            sourceBookmark = try resolver.makeBookmark(
                for: validatedSourceURL,
                role: .source
            )
        } catch {
            throw MirmirWorkHistoryBookmarkError.creationFailed(role: .source)
        }
        do {
            outputBookmark = try resolver.makeBookmark(
                for: outputDirectoryURL,
                role: .output
            )
        } catch {
            throw MirmirWorkHistoryBookmarkError.creationFailed(role: .output)
        }
        return Self(
            id: id,
            sourceBookmark: sourceBookmark,
            outputBookmark: outputBookmark,
            outputBookmarkScope: .directory,
            sourceDisplayName: sourceDisplayName,
            outputDisplayName: outputDisplayName,
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            codec: codec,
            sourceAudioTrackCount: sourceAudioTrackCount,
            sourceScanStructure: sourceScanStructure,
            preserveAudio: preserveAudio,
            requestedMode: requestedMode,
            processingConfiguration: processingConfiguration,
            createdAt: createdAt,
            startedAt: startedAt,
            completedAt: completedAt,
            terminalResult: terminalResult,
            outputVerification: outputVerification
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceBookmark
        case outputBookmark
        case outputBookmarkScope
        case sourceDisplayName
        case outputDisplayName
        case sourceResolution
        case targetResolution
        case codec
        case sourceAudioTrackCount
        case sourceScanStructure
        case preserveAudio
        case requestedMode
        case processingConfiguration
        case createdAt
        case startedAt
        case completedAt
        case terminalResult
        case outputVerification
    }

    private struct StoredResolution: Codable {
        let width: Int
        let height: Int
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceBookmark = try container.decode(Data.self, forKey: .sourceBookmark)
        outputBookmark = try container.decode(Data.self, forKey: .outputBookmark)
        outputBookmarkScope = try container.decodeIfPresent(
            MirmirWorkHistoryOutputBookmarkScope.self,
            forKey: .outputBookmarkScope
        ) ?? .file
        sourceDisplayName = try container.decode(
            String.self,
            forKey: .sourceDisplayName
        )
        outputDisplayName = try container.decode(
            String.self,
            forKey: .outputDisplayName
        )
        let source = try container.decode(
            StoredResolution.self,
            forKey: .sourceResolution
        )
        sourceResolution = VideoResolution(
            width: source.width,
            height: source.height
        )
        let target = try container.decode(
            StoredResolution.self,
            forKey: .targetResolution
        )
        targetResolution = VideoResolution(
            width: target.width,
            height: target.height
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
        sourceAudioTrackCount = try container.decodeIfPresent(
            Int.self,
            forKey: .sourceAudioTrackCount
        )
        sourceScanStructure = try container.decodeIfPresent(
            MediaVideoScanStructure.self,
            forKey: .sourceScanStructure
        )
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
        processingConfiguration = try container.decode(
            UpscaleProcessingConfiguration.self,
            forKey: .processingConfiguration
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        terminalResult = try container.decode(
            MirmirWorkTerminalResult.self,
            forKey: .terminalResult
        )
        outputVerification = try container.decode(
            MirmirWorkOutputVerification.self,
            forKey: .outputVerification
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceBookmark, forKey: .sourceBookmark)
        try container.encode(outputBookmark, forKey: .outputBookmark)
        try container.encode(
            outputBookmarkScope,
            forKey: .outputBookmarkScope
        )
        try container.encode(sourceDisplayName, forKey: .sourceDisplayName)
        try container.encode(outputDisplayName, forKey: .outputDisplayName)
        try container.encode(
            StoredResolution(
                width: sourceResolution.width,
                height: sourceResolution.height
            ),
            forKey: .sourceResolution
        )
        try container.encode(
            StoredResolution(
                width: targetResolution.width,
                height: targetResolution.height
            ),
            forKey: .targetResolution
        )
        try container.encode(codec.rawValue, forKey: .codec)
        try container.encodeIfPresent(
            sourceAudioTrackCount,
            forKey: .sourceAudioTrackCount
        )
        try container.encodeIfPresent(
            sourceScanStructure,
            forKey: .sourceScanStructure
        )
        try container.encode(preserveAudio, forKey: .preserveAudio)
        try container.encode(requestedMode.rawValue, forKey: .requestedMode)
        try container.encode(
            processingConfiguration,
            forKey: .processingConfiguration
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(terminalResult, forKey: .terminalResult)
        try container.encode(outputVerification, forKey: .outputVerification)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.sourceBookmark == rhs.sourceBookmark
            && lhs.outputBookmark == rhs.outputBookmark
            && lhs.outputBookmarkScope == rhs.outputBookmarkScope
            && lhs.sourceDisplayName == rhs.sourceDisplayName
            && lhs.outputDisplayName == rhs.outputDisplayName
            && lhs.sourceResolution == rhs.sourceResolution
            && lhs.targetResolution == rhs.targetResolution
            && lhs.codec.rawValue == rhs.codec.rawValue
            && lhs.sourceAudioTrackCount == rhs.sourceAudioTrackCount
            && lhs.sourceScanStructure == rhs.sourceScanStructure
            && lhs.preserveAudio == rhs.preserveAudio
            && lhs.requestedMode.rawValue == rhs.requestedMode.rawValue
            && lhs.processingConfiguration == rhs.processingConfiguration
            && lhs.createdAt == rhs.createdAt
            && lhs.startedAt == rhs.startedAt
            && lhs.completedAt == rhs.completedAt
            && lhs.terminalResult == rhs.terminalResult
            && lhs.outputVerification == rhs.outputVerification
    }
}

private enum MirmirWorkHistoryLocationValidator {
    static func fileURL(
        _ url: URL,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> URL {
        let host = url.host(percentEncoded: false)
        guard url.isFileURL,
              url.scheme?.lowercased() == "file",
              host == nil || host == "" || host == "localhost",
              url.query(percentEncoded: false) == nil,
              url.fragment(percentEncoded: false) == nil else {
            throw MirmirWorkHistoryLocationError
                .invalidFileURL(role: role)
        }
        let standardized = url.absoluteURL.standardizedFileURL
        guard standardized.isFileURL,
              standardized.path.hasPrefix("/"),
              !standardized.path.isEmpty else {
            throw MirmirWorkHistoryLocationError
                .invalidFileURL(role: role)
        }
        return standardized
    }

    static func validateDisplayName(
        _ value: String,
        role: MirmirWorkHistoryBookmarkRole
    ) throws {
        guard displayNameIsValid(value) else {
            throw MirmirWorkHistoryLocationError
                .invalidDisplayName(role: role)
        }
    }

    static func displayNameIsValid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 512
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\u{0}")
    }

    static func outputFileURL(
        directoryURL: URL,
        displayName: String
    ) throws -> URL {
        try validateDisplayName(displayName, role: .output)
        let directory = try fileURL(directoryURL, role: .output)
        let output = directory
            .appendingPathComponent(displayName, isDirectory: false)
            .standardizedFileURL
        let derivedParent = output.deletingLastPathComponent()
            .standardizedFileURL
        guard output != directory,
              derivedParent.path == directory.path,
              output.lastPathComponent == displayName else {
            throw MirmirWorkHistoryLocationError
                .outputFileDerivationFailed
        }
        return output
    }
}

struct MirmirWorkHistoryLimits: Equatable, Sendable {
    static let production = MirmirWorkHistoryLimits(
        maximumRecords: 1_000,
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
              maximumDocumentBytes <= 64 * 1_024 * 1_024,
              maximumBookmarkBytes > 0,
              maximumBookmarkBytes <= 16 * 1_024 * 1_024,
              maximumBookmarkBytes < maximumDocumentBytes else {
            throw MirmirWorkHistoryStoreError.invalidLimits
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

enum MirmirWorkHistoryRecordField: String, Equatable, Sendable {
    case jobID = "job_id"
    case sourceBookmark = "source_bookmark"
    case outputBookmark = "output_bookmark"
    case sourceDisplayName = "source_display_name"
    case outputDisplayName = "output_display_name"
    case sourceResolution = "source_resolution"
    case targetResolution = "target_resolution"
    case sourceAudioTrackCount = "source_audio_track_count"
    case sourceScanStructure = "source_scan_structure"
    case timestamps
    case outputVerification = "output_verification"
}

enum MirmirWorkHistoryPersistenceOperation:
    String,
    Equatable,
    Sendable {
    case locateApplicationSupport = "locate_application_support"
    case initialize
    case read
    case write
    case quarantine
}

enum MirmirWorkHistoryRecoveryReason: String, Equatable, Sendable {
    case malformedDocument = "malformed_document"
    case invalidRecord = "invalid_record"
    case duplicateJobID = "duplicate_job_id"
}

struct MirmirWorkHistoryRecovery: Equatable, Sendable {
    let reason: MirmirWorkHistoryRecoveryReason
    let quarantineFileName: String
}

struct MirmirWorkHistorySnapshot: Equatable, Sendable {
    let records: [MirmirWorkHistoryRecord]
    let recovery: MirmirWorkHistoryRecovery?
}

enum MirmirWorkHistoryStoreError:
    Error,
    Equatable,
    LocalizedError,
    Sendable {
    case invalidLimits
    case invalidRecord(field: MirmirWorkHistoryRecordField)
    case recordNotFound
    case unsupportedSchemaVersion(Int)
    case documentTooLarge
    case persistenceFailure(operation: MirmirWorkHistoryPersistenceOperation)

    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            return "The work-history retention policy is invalid."
        case .invalidRecord:
            return "The work-history record is invalid."
        case .recordNotFound:
            return "The requested work-history record was not found."
        case .unsupportedSchemaVersion:
            return "The saved work history requires a different app version."
        case .documentTooLarge:
            return "The saved work history exceeds its storage limit."
        case .persistenceFailure:
            return "Mirmir could not update saved work history."
        }
    }
}

// Persistence, recovery, validation, and bookmark status share actor state.
// swiftlint:disable type_body_length
actor MirmirWorkHistoryStore {
    static let documentFileName = "work-history-v1.json"
    static let schemaVersion = 1

    private struct VersionEnvelope: Decodable {
        let schemaVersion: Int
    }

    private struct Document: Codable {
        let schemaVersion: Int
        var records: [MirmirWorkHistoryRecord]
    }

    private let directoryURL: URL
    private let documentURL: URL
    private let limits: MirmirWorkHistoryLimits
    private let fileSystem: any R13RestartFileSystem

    init(
        directoryURL: URL,
        limits: MirmirWorkHistoryLimits = .production,
        fileSystem: any R13RestartFileSystem = R13LocalRestartFileSystem()
    ) {
        let resolvedDirectory = R13RestartPath.resolvingExistingAncestor(
            of: directoryURL
        )
        self.directoryURL = resolvedDirectory
        self.documentURL = resolvedDirectory
            .appendingPathComponent(Self.documentFileName, isDirectory: false)
        self.limits = limits
        self.fileSystem = fileSystem
    }

    static func production(
        fileManager: FileManager = .default,
        limits: MirmirWorkHistoryLimits = .production
    ) throws -> MirmirWorkHistoryStore {
        let applicationSupport: URL
        do {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw MirmirWorkHistoryStoreError.persistenceFailure(
                operation: .locateApplicationSupport
            )
        }
        let fileSystem: R13LocalRestartFileSystem
        do {
            fileSystem = try R13LocalRestartFileSystem(
                trustedRootURL: applicationSupport
            )
        } catch {
            throw MirmirWorkHistoryStoreError.persistenceFailure(
                operation: .initialize
            )
        }
        return MirmirWorkHistoryStore(
            directoryURL: applicationSupport
                .appendingPathComponent("Mirmir", isDirectory: true)
                .appendingPathComponent("WorkHistory", isDirectory: true),
            limits: limits,
            fileSystem: fileSystem
        )
    }

    func snapshot() throws -> MirmirWorkHistorySnapshot {
        let loaded = try loadDocument()
        return MirmirWorkHistorySnapshot(
            records: loaded.document.records,
            recovery: loaded.recovery
        )
    }

    func records() throws -> [MirmirWorkHistoryRecord] {
        try snapshot().records
    }

    func record(id: String) throws -> MirmirWorkHistoryRecord? {
        try validateIdentity(id, field: .jobID)
        return try records().first { $0.id == id }
    }

    func resolveLocations(
        id: String,
        resolver: any MirmirWorkHistoryBookmarkResolving
    ) throws -> MirmirWorkHistoryResolvedLocations {
        guard let record = try record(id: id) else {
            throw MirmirWorkHistoryStoreError.recordNotFound
        }
        let source = try resolver.resolveBookmark(
            record.sourceBookmark,
            role: .source
        )
        let output = try resolver.resolveBookmark(
            record.outputBookmark,
            role: .output
        )
        let sourceURL =
            try MirmirWorkHistoryLocationValidator.fileURL(
                source.url,
                role: .source
            )
        let outputLocations = try resolvedOutputLocations(
            record: record,
            resolvedBookmark: output
        )
        return MirmirWorkHistoryResolvedLocations(
            sourceURL: sourceURL,
            outputDirectoryURL: outputLocations.directoryURL,
            outputFileURL: outputLocations.fileURL,
            sourceBookmarkIsStale: source.isStale,
            outputBookmarkIsStale: output.isStale
        )
    }

    @discardableResult
    func upsert(
        _ record: MirmirWorkHistoryRecord
    ) throws -> MirmirWorkHistorySnapshot {
        try validate(record)
        var loaded = try loadDocument()
        loaded.document.records.removeAll { $0.id == record.id }
        loaded.document.records.append(record)
        loaded.document.records = boundedNewestFirst(
            loaded.document.records
        )
        try persist(loaded.document)
        return MirmirWorkHistorySnapshot(
            records: loaded.document.records,
            recovery: loaded.recovery
        )
    }

    @discardableResult
    func update(
        _ record: MirmirWorkHistoryRecord
    ) throws -> MirmirWorkHistorySnapshot {
        try validate(record)
        var loaded = try loadDocument()
        guard let index = loaded.document.records.firstIndex(
            where: { $0.id == record.id }
        ) else {
            throw MirmirWorkHistoryStoreError.recordNotFound
        }
        loaded.document.records[index] = record
        loaded.document.records = boundedNewestFirst(
            loaded.document.records
        )
        try persist(loaded.document)
        return MirmirWorkHistorySnapshot(
            records: loaded.document.records,
            recovery: loaded.recovery
        )
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        try validateIdentity(id, field: .jobID)
        var loaded = try loadDocument()
        let originalCount = loaded.document.records.count
        loaded.document.records.removeAll { $0.id == id }
        guard loaded.document.records.count != originalCount else {
            return false
        }
        try persist(loaded.document)
        return true
    }

    func bookmarkStates(
        id: String,
        resolver: any MirmirWorkHistoryBookmarkResolving,
        availabilityChecker: any MirmirWorkFileAvailabilityChecking =
            MirmirFoundationWorkFileChecker()
    ) throws -> MirmirWorkHistoryBookmarkStates {
        guard let record = try record(id: id) else {
            throw MirmirWorkHistoryStoreError.recordNotFound
        }
        return MirmirWorkHistoryBookmarkStates(
            source: sourceBookmarkState(
                record: record,
                resolver: resolver,
                availabilityChecker: availabilityChecker
            ),
            output: outputBookmarkState(
                record: record,
                resolver: resolver,
                availabilityChecker: availabilityChecker
            )
        )
    }

    func bookmarkStates(
        records: [MirmirWorkHistoryRecord],
        resolver: any MirmirWorkHistoryBookmarkResolving,
        availabilityChecker: any MirmirWorkFileAvailabilityChecking =
            MirmirFoundationWorkFileChecker()
    ) -> [String: MirmirWorkHistoryBookmarkStates] {
        var result: [String: MirmirWorkHistoryBookmarkStates] = [:]
        result.reserveCapacity(records.count)
        for record in records {
            result[record.id] = MirmirWorkHistoryBookmarkStates(
                source: sourceBookmarkState(
                    record: record,
                    resolver: resolver,
                    availabilityChecker: availabilityChecker
                ),
                output: outputBookmarkState(
                    record: record,
                    resolver: resolver,
                    availabilityChecker: availabilityChecker
                )
            )
        }
        return result
    }

    private func sourceBookmarkState(
        record: MirmirWorkHistoryRecord,
        resolver: any MirmirWorkHistoryBookmarkResolving,
        availabilityChecker: any MirmirWorkFileAvailabilityChecking
    ) -> MirmirWorkHistoryBookmarkState {
        let resolved: MirmirWorkHistoryResolvedBookmark
        do {
            resolved = try resolver.resolveBookmark(
                record.sourceBookmark,
                role: .source
            )
        } catch {
            return .reauthorizationRequired
        }
        guard !resolved.isStale else {
            return .reauthorizationRequired
        }
        let sourceURL: URL
        do {
            sourceURL =
                try MirmirWorkHistoryLocationValidator.fileURL(
                    resolved.url,
                    role: .source
                )
        } catch {
            return .reauthorizationRequired
        }
        return availabilityChecker.isAvailable(at: sourceURL)
            ? .available
            : .missing
    }

    private func outputBookmarkState(
        record: MirmirWorkHistoryRecord,
        resolver: any MirmirWorkHistoryBookmarkResolving,
        availabilityChecker: any MirmirWorkFileAvailabilityChecking
    ) -> MirmirWorkHistoryBookmarkState {
        let resolved: MirmirWorkHistoryResolvedBookmark
        do {
            resolved = try resolver.resolveBookmark(
                record.outputBookmark,
                role: .output
            )
        } catch {
            return .reauthorizationRequired
        }
        guard !resolved.isStale else {
            return .reauthorizationRequired
        }
        let locations: (directoryURL: URL, fileURL: URL)
        do {
            locations = try resolvedOutputLocations(
                record: record,
                resolvedBookmark: resolved
            )
        } catch {
            return .reauthorizationRequired
        }
        let requiresOutputFile =
            record.terminalResult == .completed
            || record.outputVerification.availability == .available
        let assessedURL = requiresOutputFile
            ? locations.fileURL
            : locations.directoryURL
        return availabilityChecker.isAvailable(at: assessedURL)
            ? .available
            : .missing
    }

    private func resolvedOutputLocations(
        record: MirmirWorkHistoryRecord,
        resolvedBookmark: MirmirWorkHistoryResolvedBookmark
    ) throws -> (directoryURL: URL, fileURL: URL) {
        switch record.outputBookmarkScope {
        case .directory:
            let directoryURL =
                try MirmirWorkHistoryLocationValidator.fileURL(
                    resolvedBookmark.url,
                    role: .output
                )
            return (
                directoryURL,
                try MirmirWorkHistoryLocationValidator.outputFileURL(
                    directoryURL: directoryURL,
                    displayName: record.outputDisplayName
                )
            )
        case .file:
            let legacyFileURL =
                try MirmirWorkHistoryLocationValidator.fileURL(
                    resolvedBookmark.url,
                    role: .output
                )
            let directoryURL =
                legacyFileURL.deletingLastPathComponent()
                    .standardizedFileURL
            let derivedFileURL =
                try MirmirWorkHistoryLocationValidator.outputFileURL(
                    directoryURL: directoryURL,
                    displayName: record.outputDisplayName
                )
            guard derivedFileURL == legacyFileURL else {
                throw MirmirWorkHistoryLocationError
                    .legacyOutputBookmarkMismatch
            }
            return (directoryURL, derivedFileURL)
        }
    }

    private func loadDocument() throws
        -> (document: Document, recovery: MirmirWorkHistoryRecovery?) {
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
                maximumBytes: limits.maximumDocumentBytes
            )
        } catch {
            throw MirmirWorkHistoryStoreError.persistenceFailure(
                operation: .read
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
            throw MirmirWorkHistoryStoreError.unsupportedSchemaVersion(
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
        var observedIDs = Set<String>()
        do {
            for record in document.records {
                try validate(record)
                guard observedIDs.insert(record.id).inserted else {
                    return try quarantineAndReset(
                        data,
                        reason: .duplicateJobID
                    )
                }
            }
        } catch {
            return try quarantineAndReset(data, reason: .invalidRecord)
        }
        let decodedRecords = document.records
        document.records = boundedNewestFirst(decodedRecords)
        if document.records != decodedRecords {
            try persist(document)
        }
        return (document, nil)
    }

    private func quarantineAndReset(
        _ data: Data,
        reason: MirmirWorkHistoryRecoveryReason
    ) throws -> (document: Document, recovery: MirmirWorkHistoryRecovery?) {
        let fileName = "work-history-corrupt-\(UUID().uuidString.lowercased()).json"
        let quarantineURL = directoryURL.appendingPathComponent(
            fileName,
            isDirectory: false
        )
        do {
            try fileSystem.writeNewAtomically(data, to: quarantineURL)
        } catch {
            throw MirmirWorkHistoryStoreError.persistenceFailure(
                operation: .quarantine
            )
        }
        let empty = Document(schemaVersion: Self.schemaVersion, records: [])
        try persist(empty)
        return (
            empty,
            MirmirWorkHistoryRecovery(
                reason: reason,
                quarantineFileName: fileName
            )
        )
    }

    private func persist(_ document: Document) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(document)
        } catch {
            throw MirmirWorkHistoryStoreError.persistenceFailure(
                operation: .write
            )
        }
        guard data.count <= limits.maximumDocumentBytes else {
            throw MirmirWorkHistoryStoreError.documentTooLarge
        }
        do {
            if fileSystem.exists(documentURL) {
                try fileSystem.replaceAtomically(data, at: documentURL)
            } else {
                try fileSystem.writeNewAtomically(data, to: documentURL)
            }
        } catch {
            throw MirmirWorkHistoryStoreError.persistenceFailure(
                operation: .write
            )
        }
    }

    private func boundedNewestFirst(
        _ records: [MirmirWorkHistoryRecord]
    ) -> [MirmirWorkHistoryRecord] {
        Array(
            records.sorted(by: Self.isNewer).prefix(limits.maximumRecords)
        )
    }

    private static func isNewer(
        _ lhs: MirmirWorkHistoryRecord,
        _ rhs: MirmirWorkHistoryRecord
    ) -> Bool {
        if lhs.completedAt != rhs.completedAt {
            return lhs.completedAt > rhs.completedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    private func validate(_ record: MirmirWorkHistoryRecord) throws {
        try validateIdentity(record.id, field: .jobID)
        try validateBookmark(
            record.sourceBookmark,
            field: .sourceBookmark
        )
        try validateBookmark(
            record.outputBookmark,
            field: .outputBookmark
        )
        try validateDisplayName(
            record.sourceDisplayName,
            field: .sourceDisplayName
        )
        try validateDisplayName(
            record.outputDisplayName,
            field: .outputDisplayName
        )
        try validateResolution(
            record.sourceResolution,
            field: .sourceResolution
        )
        try validateResolution(
            record.targetResolution,
            field: .targetResolution
        )
        if let sourceAudioTrackCount = record.sourceAudioTrackCount,
           sourceAudioTrackCount < 0 {
            throw MirmirWorkHistoryStoreError.invalidRecord(
                field: .sourceAudioTrackCount
            )
        }
        guard record.createdAt.timeIntervalSinceReferenceDate.isFinite,
              record.completedAt.timeIntervalSinceReferenceDate.isFinite,
              record.completedAt >= record.createdAt else {
            throw MirmirWorkHistoryStoreError.invalidRecord(
                field: .timestamps
            )
        }
        if let startedAt = record.startedAt {
            guard startedAt.timeIntervalSinceReferenceDate.isFinite,
                  startedAt >= record.createdAt,
                  startedAt <= record.completedAt else {
                throw MirmirWorkHistoryStoreError.invalidRecord(
                    field: .timestamps
                )
            }
        }
        switch record.outputVerification.availability {
        case .available:
            guard let identity = record.outputVerification.identity else {
                throw MirmirWorkHistoryStoreError.invalidRecord(
                    field: .outputVerification
                )
            }
            try validateIdentity(identity, field: .outputVerification)
        case .unavailable:
            guard record.outputVerification.identity == nil else {
                throw MirmirWorkHistoryStoreError.invalidRecord(
                    field: .outputVerification
                )
            }
        }
        if record.terminalResult == .completed,
           record.outputVerification.availability != .available {
            throw MirmirWorkHistoryStoreError.invalidRecord(
                field: .outputVerification
            )
        }
    }

    private func validateIdentity(
        _ value: String,
        field: MirmirWorkHistoryRecordField
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= 192,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || $0 == "."
                      || $0 == "_"
                      || $0 == "-"
                      || $0 == ":"
              }) else {
            throw MirmirWorkHistoryStoreError.invalidRecord(field: field)
        }
    }

    private func validateBookmark(
        _ bookmark: Data,
        field: MirmirWorkHistoryRecordField
    ) throws {
        guard !bookmark.isEmpty,
              bookmark.count <= limits.maximumBookmarkBytes else {
            throw MirmirWorkHistoryStoreError.invalidRecord(field: field)
        }
    }

    private func validateDisplayName(
        _ value: String,
        field: MirmirWorkHistoryRecordField
    ) throws {
        guard MirmirWorkHistoryLocationValidator
                .displayNameIsValid(value) else {
            throw MirmirWorkHistoryStoreError.invalidRecord(field: field)
        }
    }

    private func validateResolution(
        _ resolution: VideoResolution,
        field: MirmirWorkHistoryRecordField
    ) throws {
        guard resolution.width > 0,
              resolution.height > 0,
              resolution.width <= 131_072,
              resolution.height <= 131_072 else {
            throw MirmirWorkHistoryStoreError.invalidRecord(field: field)
        }
    }

    private func persistenceBoundary<T>(
        operation: MirmirWorkHistoryPersistenceOperation,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as MirmirWorkHistoryStoreError {
            throw error
        } catch {
            throw MirmirWorkHistoryStoreError.persistenceFailure(
                operation: operation
            )
        }
    }
}
// swiftlint:enable type_body_length
