import CryptoKit
import Darwin
import Foundation

// swiftlint:disable file_length

enum R12ChunkCheckpointError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidMediaTime
    case invalidBoundary(reason: String)
    case invalidRelativePath(String)
    case duplicateTrack(String)
    case missingVideoWatermark
    case trackLayoutMismatch
    case staleHead(expected: String, observed: String)
    case sourceBindingMismatch
    case checkpointSequenceMismatch
    case checkpointContinuityMismatch
    case checkpointHashMismatch
    case ledgerHeadMismatch
    case nonCanonicalLedger
    case unsafeFilesystemEntry(String)
    case artifactSizeMismatch(path: String)
    case artifactHashMismatch(path: String)
    case reopenReceiptMismatch(path: String)
    case malformedChunkEnvelope
    case ledgerAlreadyExists
    case ledgerMissing
    case ledgerSizeLimitExceeded(observed: Int, maximum: Int)
    case atomicWriteFailed
    case durabilityRollbackFailed
}

struct R12MediaTime: Codable, Comparable, Hashable, Sendable {
    private static let maximumValue: Int64 = 9_000_000_000_000
    private static let maximumTimescale: Int32 = 1_000_000

    let value: Int64
    let timescale: Int32

    init(value: Int64, timescale: Int32) throws {
        guard value >= 0,
              value <= Self.maximumValue,
              timescale > 0,
              timescale <= Self.maximumTimescale else {
            throw R12ChunkCheckpointError.invalidMediaTime
        }
        self.value = value
        self.timescale = timescale
    }

    static func < (lhs: R12MediaTime, rhs: R12MediaTime) -> Bool {
        lhs.value * Int64(rhs.timescale)
            < rhs.value * Int64(lhs.timescale)
    }
}

enum R12TrackKind: String, Codable, CaseIterable, Hashable, Sendable {
    case video
    case audio
    case subtitle
    case timedMetadata = "timed_metadata"
}

struct R12TrackIdentity: Codable, Hashable, Sendable {
    let trackID: String
    let kind: R12TrackKind

    init(trackID: String, kind: R12TrackKind) throws {
        self.trackID = try R12CheckpointValidation.identity(
            trackID,
            field: "track_id"
        )
        self.kind = kind
    }
}

struct R12TrackWatermark: Codable, Hashable, Sendable {
    let trackID: String
    let kind: R12TrackKind
    let nextSampleIndex: Int
    let time: R12MediaTime

    init(
        trackID: String,
        kind: R12TrackKind,
        nextSampleIndex: Int,
        time: R12MediaTime
    ) throws {
        self.trackID = try R12CheckpointValidation.identity(
            trackID,
            field: "track_id"
        )
        guard nextSampleIndex >= 0 else {
            throw R12ChunkCheckpointError.invalidBoundary(
                reason: "negative_track_sample_index"
            )
        }
        self.kind = kind
        self.nextSampleIndex = nextSampleIndex
        self.time = time
    }
}

enum R12BackendBoundaryState: Codable, Hashable, Sendable {
    case stateless
    case resetAtBoundary(resetIdentity: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case resetIdentity = "reset_identity"
    }

    private enum Kind: String, Codable {
        case stateless
        case resetAtBoundary = "reset_at_boundary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .stateless:
            guard !container.contains(.resetIdentity) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .resetIdentity,
                    in: container,
                    debugDescription: "Stateless boundary cannot carry reset identity."
                )
            }
            self = .stateless
        case .resetAtBoundary:
            let identity = try container.decode(String.self, forKey: .resetIdentity)
            guard (try? R12CheckpointValidation.identity(
                identity,
                field: "reset_identity"
            )) != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .resetIdentity,
                    in: container,
                    debugDescription: "Reset identity is invalid."
                )
            }
            self = .resetAtBoundary(resetIdentity: identity)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stateless:
            try container.encode(Kind.stateless, forKey: .kind)
        case .resetAtBoundary(let resetIdentity):
            _ = try R12CheckpointValidation.identity(
                resetIdentity,
                field: "reset_identity"
            )
            try container.encode(Kind.resetAtBoundary, forKey: .kind)
            try container.encode(resetIdentity, forKey: .resetIdentity)
        }
    }
}

struct R12SafeMediaBoundary: Codable, Hashable, Sendable {
    let start: R12MediaTime
    let endExclusive: R12MediaTime
    let firstVideoSampleIndex: Int
    let nextVideoSampleIndex: Int
    let nextSampleIsSync: Bool
    let trackWatermarks: [R12TrackWatermark]
    let backendStartState: R12BackendBoundaryState
    let backendState: R12BackendBoundaryState

    init(
        start: R12MediaTime,
        endExclusive: R12MediaTime,
        firstVideoSampleIndex: Int,
        nextVideoSampleIndex: Int,
        nextSampleIsSync: Bool,
        trackWatermarks: [R12TrackWatermark],
        backendStartState: R12BackendBoundaryState,
        backendState: R12BackendBoundaryState
    ) throws {
        guard start < endExclusive,
              firstVideoSampleIndex >= 0,
              nextVideoSampleIndex > firstVideoSampleIndex,
              nextSampleIsSync else {
            throw R12ChunkCheckpointError.invalidBoundary(
                reason: "unsafe_video_boundary"
            )
        }
        var trackIDs: Set<String> = []
        var videoWatermarkCount = 0
        for watermark in trackWatermarks {
            guard trackIDs.insert(watermark.trackID).inserted else {
                throw R12ChunkCheckpointError.duplicateTrack(watermark.trackID)
            }
            guard watermark.time == endExclusive else {
                throw R12ChunkCheckpointError.invalidBoundary(
                    reason: "track_watermark_time_mismatch"
                )
            }
            if watermark.kind == .video {
                videoWatermarkCount += 1
                guard watermark.nextSampleIndex == nextVideoSampleIndex else {
                    throw R12ChunkCheckpointError.invalidBoundary(
                        reason: "video_watermark_index_mismatch"
                    )
                }
            }
        }
        guard videoWatermarkCount == 1 else {
            throw R12ChunkCheckpointError.missingVideoWatermark
        }
        try Self.validateBackendState(backendStartState)
        try Self.validateBackendState(backendState)
        self.start = start
        self.endExclusive = endExclusive
        self.firstVideoSampleIndex = firstVideoSampleIndex
        self.nextVideoSampleIndex = nextVideoSampleIndex
        self.nextSampleIsSync = nextSampleIsSync
        self.trackWatermarks = trackWatermarks.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.trackID < $1.trackID
        }
        self.backendStartState = backendStartState
        self.backendState = backendState
    }

    private static func validateBackendState(
        _ state: R12BackendBoundaryState
    ) throws {
        if case .resetAtBoundary(let identity) = state {
            _ = try R12CheckpointValidation.identity(
                identity,
                field: "reset_identity"
            )
        }
    }
}

struct R12ChunkArtifactPolicy: Codable, Hashable, Sendable {
    // Canonical envelopes are decoded and retained in memory before store-owned
    // publication. A 64 MiB envelope cap keeps that multi-buffer operation
    // explicitly bounded; this is not a streaming-media artifact limit.
    static let maximumSupportedArtifactBytes: UInt64 =
        64 * 1_024 * 1_024

    let maximumArtifactBytes: UInt64

    init(maximumArtifactBytes: UInt64) throws {
        guard maximumArtifactBytes > 0,
              maximumArtifactBytes <= Self.maximumSupportedArtifactBytes else {
            throw R12ChunkCheckpointError.invalidBoundary(
                reason: "invalid_artifact_size_policy"
            )
        }
        self.maximumArtifactBytes = maximumArtifactBytes
    }

    func validate(byteCount: UInt64, path: String) throws {
        guard byteCount > 0,
              byteCount <= maximumArtifactBytes else {
            throw R12ChunkCheckpointError.artifactSizeMismatch(path: path)
        }
    }

    var readLimit: Int {
        Int(maximumArtifactBytes)
    }
}

struct R12ChunkArtifactIdentity: Codable, Hashable, Sendable {
    let relativePath: String
    let byteCount: UInt64
    let sha256: String
    let reopenReceiptSHA256: String

    init(
        relativePath: String,
        byteCount: UInt64,
        sha256: String,
        reopenReceiptSHA256: String
    ) throws {
        self.relativePath = try R12CheckpointValidation.relativePath(relativePath)
        guard byteCount > 0 else {
            throw R12ChunkCheckpointError.artifactSizeMismatch(path: relativePath)
        }
        self.byteCount = byteCount
        self.sha256 = try R12CheckpointValidation.sha256(
            sha256,
            field: "artifact_sha256"
        )
        self.reopenReceiptSHA256 = try R12CheckpointValidation.sha256(
            reopenReceiptSHA256,
            field: "reopen_receipt_sha256"
        )
    }

    static func make(
        relativePath: String,
        data: Data,
        digest: any R12Digesting = R12CryptoKitDigest()
    ) throws -> R12ChunkArtifactIdentity {
        let validatedPath = try R12CheckpointValidation.relativePath(relativePath)
        guard !data.isEmpty else {
            throw R12ChunkCheckpointError.artifactSizeMismatch(path: relativePath)
        }
        let contentSHA256 = digest.sha256(data)
        let receiptSHA256 = digest.sha256(
            R12CheckpointCanonical.reopenReceiptData(
                relativePath: validatedPath,
                byteCount: UInt64(data.count),
                sha256: contentSHA256
            )
        )
        return try R12ChunkArtifactIdentity(
            relativePath: validatedPath,
            byteCount: UInt64(data.count),
            sha256: contentSHA256,
            reopenReceiptSHA256: receiptSHA256
        )
    }
}

struct R12ChunkLedgerHeader: Codable, Hashable, Sendable {
    static let schemaVersion = "1.0.0"

    let schemaVersion: String
    let sourceIdentitySHA256: String
    let jobID: String
    let formatContractSHA256: String
    let routeIdentity: String
    let hardwareTierIdentity: String
    let executionIdentity: String
    let chunkPolicyIdentity: String
    let trackLayout: [R12TrackIdentity]
    let initialTrackWatermarks: [R12TrackWatermark]
    let initialBackendState: R12BackendBoundaryState
    let artifactPolicy: R12ChunkArtifactPolicy

    init(
        sourceIdentitySHA256: String,
        jobID: String,
        formatContractSHA256: String,
        routeIdentity: String,
        hardwareTierIdentity: String,
        executionIdentity: String,
        chunkPolicyIdentity: String,
        trackLayout: [R12TrackIdentity],
        initialTrackWatermarks: [R12TrackWatermark],
        initialBackendState: R12BackendBoundaryState,
        artifactPolicy: R12ChunkArtifactPolicy
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.sourceIdentitySHA256 = try R12CheckpointValidation.sha256(
            sourceIdentitySHA256,
            field: "source_identity_sha256"
        )
        self.jobID = try R12CheckpointValidation.identity(jobID, field: "job_id")
        self.formatContractSHA256 = try R12CheckpointValidation.sha256(
            formatContractSHA256,
            field: "format_contract_sha256"
        )
        self.routeIdentity = try R12CheckpointValidation.identity(
            routeIdentity,
            field: "route_identity"
        )
        self.hardwareTierIdentity = try R12CheckpointValidation.identity(
            hardwareTierIdentity,
            field: "hardware_tier_identity"
        )
        self.executionIdentity = try R12CheckpointValidation.identity(
            executionIdentity,
            field: "execution_identity"
        )
        self.chunkPolicyIdentity = try R12CheckpointValidation.identity(
            chunkPolicyIdentity,
            field: "chunk_policy_identity"
        )
        var trackIDs: Set<String> = []
        var videoTrackCount = 0
        for track in trackLayout {
            guard trackIDs.insert(track.trackID).inserted else {
                throw R12ChunkCheckpointError.duplicateTrack(track.trackID)
            }
            if track.kind == .video {
                videoTrackCount += 1
            }
        }
        guard videoTrackCount == 1 else {
            throw R12ChunkCheckpointError.missingVideoWatermark
        }
        let sortedLayout = trackLayout.sorted(by: Self.trackOrder)
        let sortedWatermarks = initialTrackWatermarks.sorted(
            by: R12CheckpointValidation.trackWatermarkOrder
        )
        guard try sortedWatermarks.map({
            try R12TrackIdentity(trackID: $0.trackID, kind: $0.kind)
        }) == sortedLayout,
        let initialTime = sortedWatermarks.first?.time,
        sortedWatermarks.allSatisfy({
            $0.nextSampleIndex == 0 && $0.time == initialTime
        }),
        initialTime.value == 0 else {
            throw R12ChunkCheckpointError.trackLayoutMismatch
        }
        if case .resetAtBoundary(let identity) = initialBackendState {
            _ = try R12CheckpointValidation.identity(
                identity,
                field: "reset_identity"
            )
        }
        self.trackLayout = sortedLayout
        self.initialTrackWatermarks = sortedWatermarks
        self.initialBackendState = initialBackendState
        self.artifactPolicy = artifactPolicy
    }

    private static func trackOrder(
        _ lhs: R12TrackIdentity,
        _ rhs: R12TrackIdentity
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.trackID < rhs.trackID
    }
}

struct R12ChunkCheckpoint: Codable, Hashable, Sendable {
    let sequence: Int
    let boundary: R12SafeMediaBoundary
    let artifact: R12ChunkArtifactIdentity
    let previousRecordSHA256: String
    let recordSHA256: String
}

struct R12ChunkCheckpointLedgerV1: Codable, Hashable, Sendable {
    static let schemaVersion = "1.0.0"

    let schemaVersion: String
    let header: R12ChunkLedgerHeader
    let records: [R12ChunkCheckpoint]
    let headSHA256: String
}

/// A deterministic canonical-envelope verification result.
///
/// Boundary, watermark, sync-safe, and backend-state values are decoded from
/// the canonical R12 envelope bytes. This verifier does not inspect a native
/// media container, sample table, codec bitstream, or AVFoundation boundary.
struct R12VerifiedChunk: Hashable, Sendable {
    static let verificationScope =
        "deterministic_canonical_envelope_v1_not_native_media_observation"
    let boundary: R12SafeMediaBoundary
    let verifiedArtifactSHA256: String

    fileprivate let canonicalArtifactData: Data
    fileprivate let headerSHA256: String

    static func makeCanonicalArtifactData(
        mediaPayload: Data,
        boundary: R12SafeMediaBoundary,
        header: R12ChunkLedgerHeader,
        digest: any R12Digesting = R12CryptoKitDigest()
    ) throws -> Data {
        guard !mediaPayload.isEmpty else {
            throw R12ChunkCheckpointError.malformedChunkEnvelope
        }
        try header.artifactPolicy.validate(
            byteCount: UInt64(mediaPayload.count),
            path: "canonical-media-payload"
        )
        try R12CheckpointSemanticValidation.validateTrackLayout(
            header: header,
            boundary: boundary
        )
        let headerSHA256 = try R12CheckpointValidation.sha256(
            digest.sha256(try R12CheckpointCanonical.data(header)),
            field: "chunk_header_sha256"
        )
        let envelope = try R12CheckpointCanonical.data(
            R12CanonicalMediaChunkEnvelopeV1(
                schemaVersion: R12CanonicalMediaChunkEnvelopeV1.schemaVersion,
                headerSHA256: headerSHA256,
                boundary: boundary,
                mediaPayload: mediaPayload
            )
        )
        try header.artifactPolicy.validate(
            byteCount: UInt64(envelope.count),
            path: "canonical-media-envelope"
        )
        return envelope
    }

    static func verifyCanonicalArtifact(
        rootURL: URL,
        relativePath: String,
        header: R12ChunkLedgerHeader,
        expectedArtifactSHA256: String,
        digest: any R12Digesting = R12CryptoKitDigest(),
        fileSystem: any R12CheckpointFileSystem = R12LocalCheckpointFileSystem()
    ) throws -> R12VerifiedChunk {
        let standardizedRoot = rootURL.standardizedFileURL
        let candidateURL = try R12CheckpointArtifactLocator.containedURL(
            rootURL: standardizedRoot,
            relativePath: relativePath,
            fileSystem: fileSystem
        )
        let data = try fileSystem.readRegularFile(
            candidateURL,
            maximumBytes: header.artifactPolicy.readLimit
        )
        let envelope: R12CanonicalMediaChunkEnvelopeV1
        do {
            envelope = try JSONDecoder().decode(
                R12CanonicalMediaChunkEnvelopeV1.self,
                from: data
            )
        } catch {
            throw R12ChunkCheckpointError.malformedChunkEnvelope
        }
        guard envelope.schemaVersion ==
                R12CanonicalMediaChunkEnvelopeV1.schemaVersion,
              !envelope.mediaPayload.isEmpty,
              try R12CheckpointCanonical.data(envelope) == data else {
            throw R12ChunkCheckpointError.malformedChunkEnvelope
        }
        try R12CheckpointSemanticValidation.validateStoredBoundary(
            envelope.boundary
        )
        try R12CheckpointSemanticValidation.validateTrackLayout(
            header: header,
            boundary: envelope.boundary
        )
        let expectedHeaderSHA256 = try R12CheckpointValidation.sha256(
            digest.sha256(try R12CheckpointCanonical.data(header)),
            field: "chunk_header_sha256"
        )
        guard envelope.headerSHA256 == expectedHeaderSHA256 else {
            throw R12ChunkCheckpointError.sourceBindingMismatch
        }
        try header.artifactPolicy.validate(
            byteCount: UInt64(data.count),
            path: relativePath
        )
        let artifactSHA256 = try R12CheckpointValidation.sha256(
            digest.sha256(data),
            field: "verified_artifact_sha256"
        )
        let expectedSHA256 = try R12CheckpointValidation.sha256(
            expectedArtifactSHA256,
            field: "expected_artifact_sha256"
        )
        guard artifactSHA256 == expectedSHA256 else {
            throw R12ChunkCheckpointError.artifactHashMismatch(
                path: relativePath
            )
        }
        return R12VerifiedChunk(
            boundary: envelope.boundary,
            verifiedArtifactSHA256: artifactSHA256,
            canonicalArtifactData: data,
            headerSHA256: expectedHeaderSHA256
        )
    }
}

struct R12ResumeExpectation: Hashable, Sendable {
    let header: R12ChunkLedgerHeader
    let expectedHeadSHA256: String?

    init(
        header: R12ChunkLedgerHeader,
        expectedHeadSHA256: String? = nil
    ) throws {
        if let expectedHeadSHA256 {
            self.expectedHeadSHA256 = try R12CheckpointValidation.sha256(
                expectedHeadSHA256,
                field: "expected_head_sha256"
            )
        } else {
            self.expectedHeadSHA256 = nil
        }
        self.header = header
    }
}

struct R12ResumeCursor: Codable, Hashable, Sendable {
    let nextSequence: Int
    let nextVideoSampleIndex: Int
    let resumeTime: R12MediaTime
    let trackWatermarks: [R12TrackWatermark]
    let backendResumeState: R12BackendBoundaryState
    let headSHA256: String
}

protocol R12Digesting: Sendable {
    func sha256(_ data: Data) -> String
}

struct R12CryptoKitDigest: R12Digesting {
    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

protocol R12CheckpointFileSystem: Sendable {
    func ensureDirectory(_ url: URL) throws
    func validateDirectory(_ url: URL) throws
    func exists(_ url: URL) -> Bool
    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data
    func writeNewAtomically(_ data: Data, to url: URL) throws
    func replaceAtomically(_ data: Data, at url: URL) throws
    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (_ transactionFileSystem: any R12CheckpointFileSystem) throws -> T
    ) throws -> T
}

enum R12CheckpointFileSystemHookPoint: Equatable, Sendable {
    case afterReadPathSnapshot
    case beforeReadPathResnapshot
    case beforeCreateRename
    case afterCreateRename
    case beforeReplacePathResnapshot
    case afterReplaceTemporaryContentRead
    case afterReplaceSwap
    case beforeRollbackSwap
}

// swiftlint:disable:next type_body_length
struct R12LocalCheckpointFileSystem: R12CheckpointFileSystem {
    typealias DirectorySynchronizer =
        @Sendable (Int32, URL) throws -> Void
    typealias OperationHook =
        @Sendable (R12CheckpointFileSystemHookPoint, URL) throws -> Void

    private let directorySynchronizer: DirectorySynchronizer
    private let operationHook: OperationHook
    private let anchorDescriptor: Int32?
    private let anchorURL: URL?
    private let anchorDevice: UInt64?
    private let anchorInode: UInt64?
    private let anchorLockName: String?
    private let anchorLockDevice: UInt64?
    private let anchorLockInode: UInt64?

    init(
        directorySynchronizer: DirectorySynchronizer? = nil,
        operationHook: OperationHook? = nil
    ) {
        self.directorySynchronizer = directorySynchronizer ?? { descriptor, _ in
            guard fsync(descriptor) == 0 else {
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
        }
        self.operationHook = operationHook ?? { _, _ in }
        self.anchorDescriptor = nil
        self.anchorURL = nil
        self.anchorDevice = nil
        self.anchorInode = nil
        self.anchorLockName = nil
        self.anchorLockDevice = nil
        self.anchorLockInode = nil
    }

    private init(
        directorySynchronizer: @escaping DirectorySynchronizer,
        operationHook: @escaping OperationHook,
        anchorDescriptor: Int32,
        anchorURL: URL,
        anchorMetadata: stat,
        anchorLockName: String,
        anchorLockMetadata: stat
    ) {
        self.directorySynchronizer = directorySynchronizer
        self.operationHook = operationHook
        self.anchorDescriptor = anchorDescriptor
        self.anchorURL = anchorURL.standardizedFileURL
        self.anchorDevice = UInt64(anchorMetadata.st_dev)
        self.anchorInode = UInt64(anchorMetadata.st_ino)
        self.anchorLockName = anchorLockName
        self.anchorLockDevice = UInt64(anchorLockMetadata.st_dev)
        self.anchorLockInode = UInt64(anchorLockMetadata.st_ino)
    }

    func ensureDirectory(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        let traversal = try directoryTraversalStart(for: standardized)
        var descriptor = traversal.descriptor
        defer { close(descriptor) }
        var currentURL = traversal.currentURL
        for component in traversal.components {
            var nextDescriptor = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if nextDescriptor < 0 && errno == ENOENT {
                guard mkdirat(
                    descriptor,
                    component,
                    S_IRWXU
                ) == 0 else {
                    throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                        standardized.path
                    )
                }
                let createdURL = currentURL.appendingPathComponent(
                    component,
                    isDirectory: true
                )
                do {
                    try directorySynchronizer(descriptor, currentURL)
                    nextDescriptor = openat(
                        descriptor,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                    guard nextDescriptor >= 0 else {
                        throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                            standardized.path
                        )
                    }
                    try directorySynchronizer(nextDescriptor, createdURL)
                } catch {
                    if nextDescriptor >= 0 {
                        close(nextDescriptor)
                    }
                    do {
                        try rollbackCreatedDirectory(
                            parentDescriptor: descriptor,
                            name: component,
                            parentURL: currentURL
                        )
                    } catch {
                        throw R12ChunkCheckpointError.atomicWriteFailed
                    }
                    throw error
                }
                close(descriptor)
                descriptor = nextDescriptor
                currentURL = createdURL
                continue
            }
            guard nextDescriptor >= 0 else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                    standardized.path
                )
            }
            close(descriptor)
            descriptor = nextDescriptor
            currentURL.appendPathComponent(component, isDirectory: true)
        }
        try validateAnchorPath()
    }

    func validateDirectory(_ url: URL) throws {
        let descriptor = try openDirectoryDescriptor(url)
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        try validateAnchorPath()
    }

    func exists(_ url: URL) -> Bool {
        let observed = try? withParentDirectoryDescriptor(
            of: url
        ) { parentDescriptor, name, _ in
            var metadata = stat()
            return fstatat(
                parentDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        }
        guard let observed else {
            return false
        }
        return (try? validateAnchorPath()) != nil && observed
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try withParentDirectoryDescriptor(of: url) { parentDescriptor, name, _ in
            var before = stat()
            guard fstatat(
                parentDescriptor,
                name,
                &before,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Self.isBoundedRegularFile(before, maximumBytes: maximumBytes) else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            try operationHook(.afterReadPathSnapshot, url)
            let descriptor = openat(
                parentDescriptor,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  Self.sameFileSnapshot(before, opened) else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            var output = Data(count: Int(opened.st_size))
            try Self.readExactly(output: &output, descriptor: descriptor, url: url)
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  Self.sameFileSnapshot(opened, after) else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            try operationHook(.beforeReadPathResnapshot, url)
            var pathAfter = stat()
            guard fstatat(
                parentDescriptor,
                name,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Self.sameFileSnapshot(after, pathAfter) else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            try validateAnchorPath()
            return output
        }
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try withParentDirectoryDescriptor(of: url) { parentDescriptor, destinationName, parentURL in
            guard try Self.pathEntry(
                parentDescriptor: parentDescriptor,
                name: destinationName
            ) == nil else {
                throw R12ChunkCheckpointError.ledgerAlreadyExists
            }
            let temporaryName = Self.temporaryName(for: destinationName)
            let temporary = try Self.writeExclusivePinned(
                data,
                parentDescriptor: parentDescriptor,
                name: temporaryName
            )
            defer { close(temporary.descriptor) }
            var temporaryExists = true
            var destinationPublished = false
            do {
                try operationHook(.beforeCreateRename, url)
                try Self.validatePinnedWrittenFile(
                    temporary,
                    data: data,
                    parentDescriptor: parentDescriptor,
                    pathName: temporaryName,
                    url: url
                )
                let flags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                guard renameatx_np(
                    parentDescriptor,
                    temporaryName,
                    parentDescriptor,
                    destinationName,
                    flags
                ) == 0 else {
                    throw R12ChunkCheckpointError.atomicWriteFailed
                }
                temporaryExists = false
                destinationPublished = true
                try operationHook(.afterCreateRename, url)
                try Self.validatePinnedWrittenFile(
                    temporary,
                    data: data,
                    parentDescriptor: parentDescriptor,
                    pathName: destinationName,
                    url: url
                )
                try validateAnchorPath()
                try directorySynchronizer(parentDescriptor, parentURL)
                try validateAnchorPath()
            } catch {
                if destinationPublished {
                    do {
                        try removeEntryDurably(
                            parentDescriptor: parentDescriptor,
                            name: destinationName,
                            parentURL: parentURL
                        )
                    } catch {
                        throw R12ChunkCheckpointError.durabilityRollbackFailed
                    }
                } else if temporaryExists {
                    _ = unlinkat(parentDescriptor, temporaryName, 0)
                    try? directorySynchronizer(parentDescriptor, parentURL)
                }
                throw error
            }
        }
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try withParentDirectoryDescriptor(of: url) { parentDescriptor, destinationName, parentURL in
            guard let destinationBefore = try Self.pathEntry(
                parentDescriptor: parentDescriptor,
                name: destinationName
            ),
            Self.isSingleLinkRegularFile(destinationBefore) else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            let temporaryName = Self.temporaryName(for: destinationName)
            let temporary = try Self.writeExclusivePinned(
                data,
                parentDescriptor: parentDescriptor,
                name: temporaryName
            )
            defer { close(temporary.descriptor) }
            do {
                try operationHook(.beforeReplacePathResnapshot, url)
                try Self.validatePinnedWrittenFile(
                    temporary,
                    data: data,
                    parentDescriptor: parentDescriptor,
                    pathName: temporaryName,
                    url: url,
                    afterContentRead: {
                        try operationHook(
                            .afterReplaceTemporaryContentRead, url
                        )
                    }
                )
                try validateAnchorPath()
            } catch {
                _ = unlinkat(parentDescriptor, temporaryName, 0)
                try? directorySynchronizer(parentDescriptor, parentURL)
                throw error
            }
            guard let destinationNow = try Self.pathEntry(
                parentDescriptor: parentDescriptor,
                name: destinationName
            ),
            Self.sameFileSnapshot(destinationBefore, destinationNow) else {
                _ = unlinkat(parentDescriptor, temporaryName, 0)
                try? directorySynchronizer(parentDescriptor, parentURL)
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
            let flags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
            guard renameatx_np(
                parentDescriptor,
                temporaryName,
                parentDescriptor,
                destinationName,
                flags
            ) == 0 else {
                _ = unlinkat(parentDescriptor, temporaryName, 0)
                try? directorySynchronizer(parentDescriptor, parentURL)
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
            do {
                try operationHook(.afterReplaceSwap, url)
                try validateAnchorPath()
                guard let destinationAfter = try Self.pathEntry(
                    parentDescriptor: parentDescriptor,
                    name: destinationName
                ),
                let temporaryAfter = try Self.pathEntry(
                    parentDescriptor: parentDescriptor,
                    name: temporaryName
                ),
                Self.sameFileIdentityAndShape(
                    temporary.snapshot,
                    destinationAfter
                ),
                Self.sameFileIdentityAndShape(
                    destinationBefore,
                    temporaryAfter
                ) else {
                    throw R12ChunkCheckpointError.atomicWriteFailed
                }
                try Self.validatePinnedWrittenFile(
                    temporary,
                    data: data,
                    parentDescriptor: parentDescriptor,
                    pathName: destinationName,
                    url: url
                )
                try directorySynchronizer(parentDescriptor, parentURL)
                try validateAnchorPath()
            } catch {
                try rollbackSwap(
                    parentDescriptor: parentDescriptor,
                    temporaryName: temporaryName,
                    destinationName: destinationName,
                    parentURL: parentURL,
                    destinationURL: url
                )
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
            // The new destination and previous-ledger recovery entry are now
            // durable. Cleanup cannot invalidate the committed destination.
            if unlinkat(parentDescriptor, temporaryName, 0) == 0 {
                try? directorySynchronizer(parentDescriptor, parentURL)
            }
        }
    }

    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (_ transactionFileSystem: any R12CheckpointFileSystem) throws -> T
    ) throws -> T {
        try withParentDirectoryDescriptor(of: url) { parentDescriptor, name, parentURL in
            guard flock(parentDescriptor, LOCK_EX) == 0 else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                    parentURL.path
                )
            }
            defer { _ = flock(parentDescriptor, LOCK_UN) }
            let descriptor = openat(
                parentDescriptor,
                name,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  Self.isSingleLinkRegularFile(opened),
                  flock(descriptor, LOCK_EX) == 0 else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            var pathEntry = stat()
            guard fstatat(
                parentDescriptor,
                name,
                &pathEntry,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Self.sameFileSnapshot(opened, pathEntry) else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            var rootMetadata = stat()
            guard fstat(parentDescriptor, &rootMetadata) == 0,
                  (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                    parentURL.path
                )
            }
            let transactionFileSystem = Self(
                directorySynchronizer: directorySynchronizer,
                operationHook: operationHook,
                anchorDescriptor: parentDescriptor,
                anchorURL: parentURL,
                anchorMetadata: rootMetadata,
                anchorLockName: name,
                anchorLockMetadata: opened
            )
            try transactionFileSystem.validateAnchorPath()
            return try operation(transactionFileSystem)
        }
    }

    private func rollbackSwap(
        parentDescriptor: Int32,
        temporaryName: String,
        destinationName: String,
        parentURL: URL,
        destinationURL: URL
    ) throws {
        do {
            try operationHook(.beforeRollbackSwap, destinationURL)
            let flags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
            guard renameatx_np(
                parentDescriptor,
                temporaryName,
                parentDescriptor,
                destinationName,
                flags
            ) == 0 else {
                throw R12ChunkCheckpointError.durabilityRollbackFailed
            }
            try directorySynchronizer(parentDescriptor, parentURL)
        } catch {
            // A failed swap-back leaves the prior ledger at `temporaryName`.
            // Never unlink that recovery entry.
            try? directorySynchronizer(parentDescriptor, parentURL)
            throw R12ChunkCheckpointError.durabilityRollbackFailed
        }
        if unlinkat(parentDescriptor, temporaryName, 0) == 0 {
            // Rollback itself is already durable. This barrier only persists
            // cleanup of the failed new-ledger entry.
            try? directorySynchronizer(parentDescriptor, parentURL)
        }
    }

    private func removeEntryDurably(
        parentDescriptor: Int32,
        name: String,
        parentURL: URL
    ) throws {
        let result = unlinkat(parentDescriptor, name, 0)
        guard result == 0 || errno == ENOENT else {
            throw R12ChunkCheckpointError.durabilityRollbackFailed
        }
        try directorySynchronizer(parentDescriptor, parentURL)
    }

    private func rollbackCreatedDirectory(
        parentDescriptor: Int32,
        name: String,
        parentURL: URL
    ) throws {
        let result = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
        guard result == 0 || errno == ENOENT else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        try directorySynchronizer(parentDescriptor, parentURL)
    }

    private func withParentDirectoryDescriptor<T>(
        of url: URL,
        _ operation: (
            _ parentDescriptor: Int32,
            _ name: String,
            _ parentURL: URL
        ) throws -> T
    ) throws -> T {
        let standardized = url.standardizedFileURL
        let parentURL = standardized.deletingLastPathComponent()
        let name = standardized.lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/") else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        let descriptor = try openDirectoryDescriptor(parentURL)
        defer { close(descriptor) }
        return try operation(descriptor, name, parentURL)
    }

    private func openDirectoryDescriptor(_ url: URL) throws -> Int32 {
        if let anchorDescriptor, let anchorURL {
            try validateAnchorPath()
            let components = try relativePathComponents(
                url,
                anchorURL: anchorURL
            )
            let descriptor = dup(anchorDescriptor)
            guard descriptor >= 0 else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            return try Self.openDirectoryComponents(
                components,
                startingAt: descriptor,
                failurePath: url.path
            )
        }
        return try Self.openAbsoluteDirectoryDescriptor(url)
    }

    private static func openAbsoluteDirectoryDescriptor(
        _ url: URL
    ) throws -> Int32 {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        let descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        return try openDirectoryComponents(
            pathComponents(standardized),
            startingAt: descriptor,
            failurePath: url.path
        )
    }

    private static func openDirectoryComponents(
        _ components: [String],
        startingAt initialDescriptor: Int32,
        failurePath: String
    ) throws -> Int32 {
        var descriptor = initialDescriptor
        for component in components {
            let nextDescriptor = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextDescriptor >= 0 else {
                close(descriptor)
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                    failurePath
                )
            }
            close(descriptor)
            descriptor = nextDescriptor
        }
        return descriptor
    }

    private struct DirectoryTraversal {
        let descriptor: Int32
        let currentURL: URL
        let components: [String]
    }

    private func directoryTraversalStart(
        for url: URL
    ) throws -> DirectoryTraversal {
        if let anchorDescriptor, let anchorURL {
            try validateAnchorPath()
            let components = try relativePathComponents(
                url,
                anchorURL: anchorURL
            )
            let descriptor = dup(anchorDescriptor)
            guard descriptor >= 0 else {
                throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
            }
            return DirectoryTraversal(
                descriptor: descriptor,
                currentURL: anchorURL,
                components: components
            )
        }
        guard url.path.hasPrefix("/") else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        let descriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        return DirectoryTraversal(
            descriptor: descriptor,
            currentURL: URL(fileURLWithPath: "/", isDirectory: true),
            components: Self.pathComponents(url)
        )
    }

    private func relativePathComponents(
        _ url: URL,
        anchorURL: URL
    ) throws -> [String] {
        let standardized = url.standardizedFileURL
        let standardizedAnchor = anchorURL.standardizedFileURL
        if standardized.path == standardizedAnchor.path {
            return []
        }
        let prefix = standardizedAnchor.path.hasSuffix("/")
            ? standardizedAnchor.path
            : standardizedAnchor.path + "/"
        guard standardized.path.hasPrefix(prefix) else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        return standardized.path
            .dropFirst(prefix.count)
            .split(separator: "/")
            .map(String.init)
    }

    private func validateAnchorPath() throws {
        guard let anchorURL,
              let anchorDevice,
              let anchorInode else {
            return
        }
        let descriptor = try Self.openAbsoluteDirectoryDescriptor(anchorURL)
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              UInt64(metadata.st_dev) == anchorDevice,
              UInt64(metadata.st_ino) == anchorInode else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                anchorURL.path
            )
        }
        guard let anchorDescriptor,
              let anchorLockName,
              let anchorLockDevice,
              let anchorLockInode else {
            return
        }
        var lockMetadata = stat()
        guard fstatat(
            anchorDescriptor,
            anchorLockName,
            &lockMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        Self.isSingleLinkRegularFile(lockMetadata),
        UInt64(lockMetadata.st_dev) == anchorLockDevice,
        UInt64(lockMetadata.st_ino) == anchorLockInode else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                anchorURL
                    .appendingPathComponent(anchorLockName)
                    .path
            )
        }
    }

    private static func pathComponents(_ url: URL) -> [String] {
        url.path.split(separator: "/").map(String.init)
    }

    private static func pathEntry(
        parentDescriptor: Int32,
        name: String
    ) throws -> stat? {
        var metadata = stat()
        if fstatat(
            parentDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return metadata
        }
        guard errno == ENOENT else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        return nil
    }

    private static func temporaryName(for destinationName: String) -> String {
        ".\(destinationName).\(UUID().uuidString).tmp"
    }

    private struct PinnedWrittenFile {
        let descriptor: Int32
        let snapshot: stat
    }

    private static func writeExclusive(
        _ data: Data,
        parentDescriptor: Int32,
        name: String
    ) throws {
        let pinned = try writeExclusivePinned(
            data,
            parentDescriptor: parentDescriptor,
            name: name
        )
        close(pinned.descriptor)
    }

    private static func writeExclusivePinned(
        _ data: Data,
        parentDescriptor: Int32,
        name: String
    ) throws -> PinnedWrittenFile {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        var succeeded = false
        defer {
            if !succeeded {
                close(descriptor)
                _ = unlinkat(parentDescriptor, name, 0)
            }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
            var offset = 0
            while offset < rawBuffer.count {
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard amount > 0 else {
                    throw R12ChunkCheckpointError.atomicWriteFailed
                }
                offset += amount
            }
        }
        guard fsync(descriptor) == 0 else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        var snapshot = stat()
        guard fstat(descriptor, &snapshot) == 0,
              isSingleLinkRegularFile(snapshot),
              snapshot.st_size == data.count else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        succeeded = true
        return PinnedWrittenFile(
            descriptor: descriptor,
            snapshot: snapshot
        )
    }

    private static func validatePinnedWrittenFile(
        _ pinned: PinnedWrittenFile,
        data: Data,
        parentDescriptor: Int32,
        pathName: String,
        url: URL,
        afterContentRead: () throws -> Void = {}
    ) throws {
        var descriptorBefore = stat()
        guard fstat(pinned.descriptor, &descriptorBefore) == 0,
              sameFileIdentityAndShape(
                pinned.snapshot,
                descriptorBefore
              ),
              let pathBefore = try pathEntry(
                parentDescriptor: parentDescriptor,
                name: pathName
              ),
              sameFileSnapshot(descriptorBefore, pathBefore),
              try descriptorContainsExactly(
                pinned.descriptor,
                data: data
              ) else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        try afterContentRead()
        var descriptorAfter = stat()
        var pathAfter = stat()
        guard fstat(pinned.descriptor, &descriptorAfter) == 0,
              sameFileSnapshot(descriptorBefore, descriptorAfter),
              fstatat(
                parentDescriptor,
                pathName,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameFileSnapshot(descriptorAfter, pathAfter) else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        guard descriptorAfter.st_nlink == 1 else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
    }

    private static func descriptorContainsExactly(
        _ descriptor: Int32,
        data: Data
    ) throws -> Bool {
        var observed = Data(count: data.count)
        let count: Int = try observed.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return 0
            }
            var offset = 0
            while offset < rawBuffer.count {
                let amount = pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                    off_t(offset)
                )
                guard amount > 0 else {
                    throw R12ChunkCheckpointError.atomicWriteFailed
                }
                offset += amount
            }
            return offset
        }
        guard count == data.count else {
            return false
        }
        var extraByte: UInt8 = 0
        let extraCount = pread(
            descriptor,
            &extraByte,
            1,
            off_t(data.count)
        )
        return extraCount == 0 && observed == data
    }

    private static func readExactly(
        output: inout Data,
        descriptor: Int32,
        url: URL
    ) throws {
        let total = output.count
        let readCount: Int = try output.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return 0
            }
            var offset = 0
            while offset < total {
                let amount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    total - offset
                )
                guard amount > 0 else {
                    throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
                }
                offset += amount
            }
            return offset
        }
        guard readCount == total else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
    }

    private static func isBoundedRegularFile(
        _ metadata: stat,
        maximumBytes: Int
    ) -> Bool {
        isSingleLinkRegularFile(metadata)
            && metadata.st_size > 0
            && metadata.st_size <= maximumBytes
    }

    private static func isSingleLinkRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
    }

    private static func sameFileSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFileIdentityAndShape(lhs, rhs)
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameFileIdentityAndShape(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
    }
}

actor R12ChunkCheckpointStore {
    private static let defaultMaximumLedgerBytes = 16 * 1_024 * 1_024
    private static let sealedArtifactDirectoryName =
        ".r12-checkpoint-artifacts-v1"

    private let rootURL: URL
    private let ledgerURL: URL
    private let lockURL: URL
    private let sealedArtifactDirectoryURL: URL
    private let digest: any R12Digesting
    private let fileSystem: any R12CheckpointFileSystem
    private let maximumLedgerBytes: Int

    init(
        rootURL: URL,
        digest: any R12Digesting = R12CryptoKitDigest(),
        fileSystem: any R12CheckpointFileSystem = R12LocalCheckpointFileSystem(),
        maximumLedgerBytes: Int = R12ChunkCheckpointStore
            .defaultMaximumLedgerBytes
    ) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.ledgerURL = standardizedRoot
            .appendingPathComponent("checkpoint-ledger-v1.json")
        self.lockURL = standardizedRoot
            .appendingPathComponent(".checkpoint-ledger-v1.lock")
        self.sealedArtifactDirectoryURL = standardizedRoot.appendingPathComponent(
            Self.sealedArtifactDirectoryName
        )
        self.digest = digest
        self.fileSystem = fileSystem
        self.maximumLedgerBytes = min(
            Self.defaultMaximumLedgerBytes,
            max(1, maximumLedgerBytes)
        )
    }

    func create(header: R12ChunkLedgerHeader) throws -> R12ResumeCursor {
        try fileSystem.ensureDirectory(rootURL)
        return try fileSystem.withExclusiveLock(at: lockURL) { transactionFileSystem in
            try transactionFileSystem.ensureDirectory(
                sealedArtifactDirectoryURL
            )
            guard !transactionFileSystem.exists(ledgerURL) else {
                throw R12ChunkCheckpointError.ledgerAlreadyExists
            }
            try Self.validateStoredHeader(header)
            let head = try R12CheckpointValidation.sha256(
                digest.sha256(try R12CheckpointCanonical.data(header)),
                field: "ledger_head_sha256"
            )
            let ledger = R12ChunkCheckpointLedgerV1(
                schemaVersion: R12ChunkCheckpointLedgerV1.schemaVersion,
                header: header,
                records: [],
                headSHA256: head
            )
            let ledgerData = try boundedCanonicalLedgerData(ledger)
            try transactionFileSystem.writeNewAtomically(
                ledgerData,
                to: ledgerURL
            )
            return try Self.cursor(for: ledger)
        }
    }

    func appendVerified(
        _ chunk: R12VerifiedChunk,
        expectedHeadSHA256: String
    ) throws -> R12ResumeCursor {
        let expectedHead = try R12CheckpointValidation.sha256(
            expectedHeadSHA256,
            field: "expected_head_sha256"
        )
        return try withExistingLedgerLock { transactionFileSystem in
            var ledger = try loadValidatedLedger(
                validateArtifactContents: false,
                fileSystem: transactionFileSystem
            )
            guard ledger.headSHA256 == expectedHead else {
                throw R12ChunkCheckpointError.staleHead(
                    expected: expectedHead,
                    observed: ledger.headSHA256
                )
            }
            let headerSHA256 = try R12CheckpointValidation.sha256(
                digest.sha256(
                    try R12CheckpointCanonical.data(ledger.header)
                ),
                field: "chunk_header_sha256"
            )
            guard chunk.headerSHA256 == headerSHA256 else {
                throw R12ChunkCheckpointError.sourceBindingMismatch
            }
            try R12CheckpointSemanticValidation.validateTrackLayout(
                header: ledger.header,
                boundary: chunk.boundary
            )
            try R12CheckpointSemanticValidation.validateContinuity(
                header: ledger.header,
                previous: ledger.records.last?.boundary,
                next: chunk.boundary
            )
            let sequence = ledger.records.count
            let artifact = try verifiedArtifactIdentity(
                chunk,
                sequence: sequence,
                policy: ledger.header.artifactPolicy
            )
            let payload = R12CheckpointRecordPayload(
                sequence: sequence,
                boundary: chunk.boundary,
                artifact: artifact,
                previousRecordSHA256: ledger.headSHA256
            )
            let recordHash = try R12CheckpointValidation.sha256(
                digest.sha256(try R12CheckpointCanonical.data(payload)),
                field: "record_sha256"
            )
            let record = R12ChunkCheckpoint(
                sequence: sequence,
                boundary: chunk.boundary,
                artifact: artifact,
                previousRecordSHA256: ledger.headSHA256,
                recordSHA256: recordHash
            )
            ledger = R12ChunkCheckpointLedgerV1(
                schemaVersion: ledger.schemaVersion,
                header: ledger.header,
                records: ledger.records + [record],
                headSHA256: recordHash
            )
            let ledgerData = try boundedCanonicalLedgerData(ledger)
            try publishVerifiedArtifact(
                chunk,
                artifact: artifact,
                policy: ledger.header.artifactPolicy,
                fileSystem: transactionFileSystem
            )
            try transactionFileSystem.replaceAtomically(
                ledgerData,
                at: ledgerURL
            )
            return try Self.cursor(for: ledger)
        }
    }

    func reopen(expecting expectation: R12ResumeExpectation) throws -> R12ResumeCursor {
        try withExistingLedgerLock { transactionFileSystem in
            let ledger = try loadValidatedLedger(
                validateArtifactContents: true,
                fileSystem: transactionFileSystem
            )
            guard ledger.header == expectation.header else {
                throw R12ChunkCheckpointError.sourceBindingMismatch
            }
            if let expected = expectation.expectedHeadSHA256,
               ledger.headSHA256 != expected {
                throw R12ChunkCheckpointError.staleHead(
                    expected: expected,
                    observed: ledger.headSHA256
                )
            }
            return try Self.cursor(for: ledger)
        }
    }

    func canonicalLedgerData() throws -> Data {
        try withExistingLedgerLock { transactionFileSystem in
            try R12CheckpointCanonical.data(
                loadValidatedLedger(
                    validateArtifactContents: true,
                    fileSystem: transactionFileSystem
                )
            )
        }
    }
}

private extension R12ChunkCheckpointStore {
    private func loadValidatedLedger(
        validateArtifactContents: Bool,
        fileSystem: any R12CheckpointFileSystem
    ) throws -> R12ChunkCheckpointLedgerV1 {
        try fileSystem.validateDirectory(rootURL)
        guard fileSystem.exists(ledgerURL) else {
            throw R12ChunkCheckpointError.ledgerMissing
        }
        let data = try fileSystem.readRegularFile(
            ledgerURL,
            maximumBytes: maximumLedgerBytes
        )
        let ledger: R12ChunkCheckpointLedgerV1
        do {
            ledger = try JSONDecoder().decode(
                R12ChunkCheckpointLedgerV1.self,
                from: data
            )
        } catch {
            throw R12ChunkCheckpointError.nonCanonicalLedger
        }
        guard ledger.schemaVersion == R12ChunkCheckpointLedgerV1.schemaVersion,
              ledger.header.schemaVersion == R12ChunkLedgerHeader.schemaVersion,
              try R12CheckpointCanonical.data(ledger) == data else {
            throw R12ChunkCheckpointError.nonCanonicalLedger
        }
        try Self.validateStoredHeader(ledger.header)
        _ = try R12CheckpointValidation.sha256(
            ledger.headSHA256,
            field: "ledger_head_sha256"
        )
        var expectedHead = try R12CheckpointValidation.sha256(
            digest.sha256(
                try R12CheckpointCanonical.data(ledger.header)
            ),
            field: "computed_header_sha256"
        )
        var previousBoundary: R12SafeMediaBoundary?
        for (expectedSequence, record) in ledger.records.enumerated() {
            guard record.sequence == expectedSequence else {
                throw R12ChunkCheckpointError.checkpointSequenceMismatch
            }
            guard record.previousRecordSHA256 == expectedHead else {
                throw R12ChunkCheckpointError.checkpointHashMismatch
            }
            try R12CheckpointSemanticValidation.validateStoredBoundary(
                record.boundary
            )
            try R12CheckpointSemanticValidation.validateTrackLayout(
                header: ledger.header,
                boundary: record.boundary
            )
            try Self.validateStoredArtifact(
                record.artifact,
                policy: ledger.header.artifactPolicy
            )
            _ = try R12CheckpointValidation.sha256(
                record.previousRecordSHA256,
                field: "previous_record_sha256"
            )
            _ = try R12CheckpointValidation.sha256(
                record.recordSHA256,
                field: "record_sha256"
            )
            try R12CheckpointSemanticValidation.validateContinuity(
                header: ledger.header,
                previous: previousBoundary,
                next: record.boundary
            )
            if validateArtifactContents {
                try validateArtifact(
                    record.artifact,
                    policy: ledger.header.artifactPolicy,
                    fileSystem: fileSystem
                )
            }
            let payload = R12CheckpointRecordPayload(
                sequence: record.sequence,
                boundary: record.boundary,
                artifact: record.artifact,
                previousRecordSHA256: record.previousRecordSHA256
            )
            let observedHash = try R12CheckpointValidation.sha256(
                digest.sha256(
                    try R12CheckpointCanonical.data(payload)
                ),
                field: "computed_record_sha256"
            )
            guard observedHash == record.recordSHA256 else {
                throw R12ChunkCheckpointError.checkpointHashMismatch
            }
            expectedHead = observedHash
            previousBoundary = record.boundary
        }
        guard ledger.headSHA256 == expectedHead else {
            throw R12ChunkCheckpointError.ledgerHeadMismatch
        }
        return ledger
    }

    private func withExistingLedgerLock<T>(
        _ operation: (
            _ transactionFileSystem: any R12CheckpointFileSystem
        ) throws -> T
    ) throws -> T {
        try fileSystem.validateDirectory(rootURL)
        return try fileSystem.withExclusiveLock(at: lockURL, operation)
    }

    private func boundedCanonicalLedgerData(
        _ ledger: R12ChunkCheckpointLedgerV1
    ) throws -> Data {
        let data = try R12CheckpointCanonical.data(ledger)
        guard data.count <= maximumLedgerBytes else {
            throw R12ChunkCheckpointError.ledgerSizeLimitExceeded(
                observed: data.count,
                maximum: maximumLedgerBytes
            )
        }
        return data
    }

    private func verifiedArtifactIdentity(
        _ chunk: R12VerifiedChunk,
        sequence: Int,
        policy: R12ChunkArtifactPolicy
    ) throws -> R12ChunkArtifactIdentity {
        try policy.validate(
            byteCount: UInt64(chunk.canonicalArtifactData.count),
            path: "verified-chunk"
        )
        let relativePath = Self.sealedArtifactDirectoryName
            + "/\(sequence)-\(chunk.verifiedArtifactSHA256).r12chunk"
        return try R12ChunkArtifactIdentity.make(
            relativePath: relativePath,
            data: chunk.canonicalArtifactData,
            digest: digest
        )
    }

    private func publishVerifiedArtifact(
        _ chunk: R12VerifiedChunk,
        artifact: R12ChunkArtifactIdentity,
        policy: R12ChunkArtifactPolicy,
        fileSystem: any R12CheckpointFileSystem
    ) throws {
        let relativePath = artifact.relativePath
        let url = try R12CheckpointArtifactLocator.containedURL(
            rootURL: rootURL,
            relativePath: relativePath,
            fileSystem: fileSystem
        )
        if fileSystem.exists(url) {
            let existing = try fileSystem.readRegularFile(
                url,
                maximumBytes: policy.readLimit
            )
            guard existing == chunk.canonicalArtifactData else {
                throw R12ChunkCheckpointError.artifactHashMismatch(
                    path: relativePath
                )
            }
        } else {
            try fileSystem.writeNewAtomically(
                chunk.canonicalArtifactData,
                to: url
            )
        }
        try validateArtifact(
            artifact,
            policy: policy,
            fileSystem: fileSystem
        )
    }

    private func validateArtifact(
        _ artifact: R12ChunkArtifactIdentity,
        policy: R12ChunkArtifactPolicy,
        fileSystem: any R12CheckpointFileSystem
    ) throws {
        try Self.validateStoredArtifact(artifact, policy: policy)
        let url = try R12CheckpointArtifactLocator.containedURL(
            rootURL: rootURL,
            relativePath: artifact.relativePath,
            fileSystem: fileSystem
        )
        let data = try fileSystem.readRegularFile(
            url,
            maximumBytes: policy.readLimit
        )
        guard UInt64(data.count) == artifact.byteCount else {
            throw R12ChunkCheckpointError.artifactSizeMismatch(
                path: artifact.relativePath
            )
        }
        let contentSHA256 = try R12CheckpointValidation.sha256(
            digest.sha256(data),
            field: "computed_artifact_sha256"
        )
        guard contentSHA256 == artifact.sha256 else {
            throw R12ChunkCheckpointError.artifactHashMismatch(
                path: artifact.relativePath
            )
        }
        let receipt = try R12CheckpointValidation.sha256(
            digest.sha256(
                R12CheckpointCanonical.reopenReceiptData(
                    relativePath: artifact.relativePath,
                    byteCount: artifact.byteCount,
                    sha256: artifact.sha256
                )
            ),
            field: "computed_reopen_receipt_sha256"
        )
        guard receipt == artifact.reopenReceiptSHA256 else {
            throw R12ChunkCheckpointError.reopenReceiptMismatch(
                path: artifact.relativePath
            )
        }
    }

    private static func validateStoredHeader(
        _ header: R12ChunkLedgerHeader
    ) throws {
        let validated = try R12ChunkLedgerHeader(
            sourceIdentitySHA256: header.sourceIdentitySHA256,
            jobID: header.jobID,
            formatContractSHA256: header.formatContractSHA256,
            routeIdentity: header.routeIdentity,
            hardwareTierIdentity: header.hardwareTierIdentity,
            executionIdentity: header.executionIdentity,
            chunkPolicyIdentity: header.chunkPolicyIdentity,
            trackLayout: try header.trackLayout.map {
                try R12TrackIdentity(
                    trackID: $0.trackID,
                    kind: $0.kind
                )
            },
            initialTrackWatermarks: try header.initialTrackWatermarks.map {
                try R12TrackWatermark(
                    trackID: $0.trackID,
                    kind: $0.kind,
                    nextSampleIndex: $0.nextSampleIndex,
                    time: try R12MediaTime(
                        value: $0.time.value,
                        timescale: $0.time.timescale
                    )
                )
            },
            initialBackendState: header.initialBackendState,
            artifactPolicy: try R12ChunkArtifactPolicy(
                maximumArtifactBytes:
                    header.artifactPolicy.maximumArtifactBytes
            )
        )
        guard validated == header else {
            throw R12ChunkCheckpointError.sourceBindingMismatch
        }
    }

    private static func validateStoredArtifact(
        _ artifact: R12ChunkArtifactIdentity,
        policy: R12ChunkArtifactPolicy
    ) throws {
        let validated = try R12ChunkArtifactIdentity(
            relativePath: artifact.relativePath,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            reopenReceiptSHA256: artifact.reopenReceiptSHA256
        )
        guard validated == artifact else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(
                artifact.relativePath
            )
        }
        try policy.validate(
            byteCount: artifact.byteCount,
            path: artifact.relativePath
        )
    }

    private static func cursor(
        for ledger: R12ChunkCheckpointLedgerV1
    ) throws -> R12ResumeCursor {
        if let boundary = ledger.records.last?.boundary {
            return R12ResumeCursor(
                nextSequence: ledger.records.count,
                nextVideoSampleIndex: boundary.nextVideoSampleIndex,
                resumeTime: boundary.endExclusive,
                trackWatermarks: boundary.trackWatermarks,
                backendResumeState: boundary.backendState,
                headSHA256: ledger.headSHA256
            )
        }
        return R12ResumeCursor(
            nextSequence: 0,
            nextVideoSampleIndex: 0,
            resumeTime: ledger.header.initialTrackWatermarks[0].time,
            trackWatermarks: ledger.header.initialTrackWatermarks,
            backendResumeState: ledger.header.initialBackendState,
            headSHA256: ledger.headSHA256
        )
    }
}

private struct R12CanonicalMediaChunkEnvelopeV1: Codable, Hashable, Sendable {
    static let schemaVersion = "1.0.0"

    let schemaVersion: String
    let headerSHA256: String
    let boundary: R12SafeMediaBoundary
    let mediaPayload: Data
}

private enum R12CheckpointArtifactLocator {
    static func containedURL(
        rootURL: URL,
        relativePath: String,
        fileSystem: any R12CheckpointFileSystem
    ) throws -> URL {
        let relative = try R12CheckpointValidation.relativePath(relativePath)
        let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/")
            ? rootURL.path
            : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw R12ChunkCheckpointError.invalidRelativePath(relativePath)
        }
        var current = rootURL
        try fileSystem.validateDirectory(current)
        let components = relative.split(separator: "/")
        for component in components.dropLast() {
            current.appendPathComponent(String(component))
            try fileSystem.validateDirectory(current)
        }
        return candidate
    }
}

private enum R12CheckpointSemanticValidation {
    static func validateContinuity(
        header: R12ChunkLedgerHeader,
        previous: R12SafeMediaBoundary?,
        next: R12SafeMediaBoundary
    ) throws {
        let priorWatermarks: [R12TrackWatermark]
        let expectedStart: R12MediaTime
        let expectedVideoSampleIndex: Int
        let expectedBackendState: R12BackendBoundaryState
        if let previous {
            priorWatermarks = previous.trackWatermarks
            expectedStart = previous.endExclusive
            expectedVideoSampleIndex = previous.nextVideoSampleIndex
            expectedBackendState = previous.backendState
        } else {
            priorWatermarks = header.initialTrackWatermarks
            expectedStart = header.initialTrackWatermarks[0].time
            expectedVideoSampleIndex = header.initialTrackWatermarks.first {
                $0.kind == .video
            }?.nextSampleIndex ?? -1
            expectedBackendState = header.initialBackendState
        }
        guard next.start == expectedStart,
              next.firstVideoSampleIndex == expectedVideoSampleIndex,
              next.backendStartState == expectedBackendState else {
            throw R12ChunkCheckpointError.checkpointContinuityMismatch
        }
        let priorByTrack = Dictionary(
            uniqueKeysWithValues: priorWatermarks.map {
                ($0.trackID, $0)
            }
        )
        guard priorByTrack.count == next.trackWatermarks.count else {
            throw R12ChunkCheckpointError.checkpointContinuityMismatch
        }
        for watermark in next.trackWatermarks {
            guard let prior = priorByTrack[watermark.trackID],
                  prior.kind == watermark.kind,
                  watermark.nextSampleIndex >= prior.nextSampleIndex else {
                throw R12ChunkCheckpointError.checkpointContinuityMismatch
            }
        }
    }

    static func validateTrackLayout(
        header: R12ChunkLedgerHeader,
        boundary: R12SafeMediaBoundary
    ) throws {
        let observed = try boundary.trackWatermarks.map {
            try R12TrackIdentity(
                trackID: $0.trackID,
                kind: $0.kind
            )
        }
        guard observed == header.trackLayout else {
            throw R12ChunkCheckpointError.trackLayoutMismatch
        }
    }

    static func validateStoredBoundary(
        _ boundary: R12SafeMediaBoundary
    ) throws {
        let start = try R12MediaTime(
            value: boundary.start.value,
            timescale: boundary.start.timescale
        )
        let end = try R12MediaTime(
            value: boundary.endExclusive.value,
            timescale: boundary.endExclusive.timescale
        )
        let watermarks = try boundary.trackWatermarks.map {
            try R12TrackWatermark(
                trackID: $0.trackID,
                kind: $0.kind,
                nextSampleIndex: $0.nextSampleIndex,
                time: try R12MediaTime(
                    value: $0.time.value,
                    timescale: $0.time.timescale
                )
            )
        }
        let validated = try R12SafeMediaBoundary(
            start: start,
            endExclusive: end,
            firstVideoSampleIndex: boundary.firstVideoSampleIndex,
            nextVideoSampleIndex: boundary.nextVideoSampleIndex,
            nextSampleIsSync: boundary.nextSampleIsSync,
            trackWatermarks: watermarks,
            backendStartState: boundary.backendStartState,
            backendState: boundary.backendState
        )
        guard validated == boundary else {
            throw R12ChunkCheckpointError.invalidBoundary(
                reason: "noncanonical_stored_boundary"
            )
        }
    }
}

private struct R12CheckpointRecordPayload: Codable {
    let sequence: Int
    let boundary: R12SafeMediaBoundary
    let artifact: R12ChunkArtifactIdentity
    let previousRecordSHA256: String
}

private enum R12CheckpointCanonical {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func reopenReceiptData(
        relativePath: String,
        byteCount: UInt64,
        sha256: String
    ) -> Data {
        Data(
            "r12_chunk_reopen_receipt_v1\u{0}\(relativePath)\u{0}\(byteCount)\u{0}\(sha256)"
                .utf8
        )
    }
}

private enum R12CheckpointValidation {
    static func trackWatermarkOrder(
        _ lhs: R12TrackWatermark,
        _ rhs: R12TrackWatermark
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.trackID < rhs.trackID
    }

    static func identity(_ value: String, field: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 160,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || $0 == "."
                      || $0 == "_"
                      || $0 == "-"
                      || $0 == ":"
              }) else {
            throw R12ChunkCheckpointError.invalidIdentity(field: field)
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x61 && $0.value <= 0x66)
              }),
              value != String(repeating: "0", count: 64) else {
            throw R12ChunkCheckpointError.invalidSHA256(field: field)
        }
        return value
    }

    static func relativePath(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 512,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\u{0}") else {
            throw R12ChunkCheckpointError.invalidRelativePath(value)
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw R12ChunkCheckpointError.invalidRelativePath(value)
        }
        return value
    }
}

// swiftlint:enable file_length
