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
    case ledgerAlreadyExists
    case ledgerMissing
    case atomicWriteFailed
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
    let backendState: R12BackendBoundaryState

    init(
        start: R12MediaTime,
        endExclusive: R12MediaTime,
        firstVideoSampleIndex: Int,
        nextVideoSampleIndex: Int,
        nextSampleIsSync: Bool,
        trackWatermarks: [R12TrackWatermark],
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
        if case .resetAtBoundary(let identity) = backendState {
            _ = try R12CheckpointValidation.identity(
                identity,
                field: "reset_identity"
            )
        }
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
        self.backendState = backendState
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

    init(
        sourceIdentitySHA256: String,
        jobID: String,
        formatContractSHA256: String,
        routeIdentity: String,
        hardwareTierIdentity: String,
        executionIdentity: String,
        chunkPolicyIdentity: String,
        trackLayout: [R12TrackIdentity]
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
        self.trackLayout = trackLayout.sorted(by: Self.trackOrder)
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

struct R12VerifiedChunk: Hashable, Sendable {
    let boundary: R12SafeMediaBoundary
    let artifact: R12ChunkArtifactIdentity
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
        _ operation: () throws -> T
    ) throws -> T
}

struct R12LocalCheckpointFileSystem: R12CheckpointFileSystem {
    func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try validateDirectory(url)
    }

    func validateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
    }

    func exists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        var before = stat()
        guard lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= maximumBytes else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              Self.sameIdentity(before, opened) else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        var output = Data(count: Int(before.st_size))
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
        var after = stat()
        guard readCount == total,
              fstat(descriptor, &after) == 0,
              Self.sameIdentity(opened, after) else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        return output
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try validateDirectory(url.deletingLastPathComponent())
        guard !exists(url) else {
            throw R12ChunkCheckpointError.ledgerAlreadyExists
        }
        let temporary = Self.temporaryURL(for: url)
        do {
            try Self.writeExclusive(data, to: temporary)
            guard link(temporary.path, url.path) == 0 else {
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
            guard unlink(temporary.path) == 0 else {
                _ = unlink(url.path)
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
        } catch {
            _ = unlink(temporary.path)
            throw error
        }
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try validateDirectory(url.deletingLastPathComponent())
        var destinationBefore = stat()
        guard lstat(url.path, &destinationBefore) == 0,
              (destinationBefore.st_mode & S_IFMT) == S_IFREG,
              destinationBefore.st_nlink == 1 else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        let temporary = Self.temporaryURL(for: url)
        do {
            try Self.writeExclusive(data, to: temporary)
            var destinationNow = stat()
            guard lstat(url.path, &destinationNow) == 0,
                  Self.sameIdentity(destinationBefore, destinationNow) else {
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
        } catch {
            _ = unlink(temporary.path)
            throw error
        }
    }

    func withExclusiveLock<T>(
        at url: URL,
        _ operation: () throws -> T
    ) throws -> T {
        try validateDirectory(url.deletingLastPathComponent())
        let descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1 else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        var locked = stat()
        var pathEntry = stat()
        guard fstat(descriptor, &locked) == 0,
              lstat(url.path, &pathEntry) == 0,
              locked.st_nlink == 1,
              Self.sameIdentity(locked, pathEntry) else {
            throw R12ChunkCheckpointError.unsafeFilesystemEntry(url.path)
        }
        return try operation()
    }

    private static func temporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded {
                _ = unlink(url.path)
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
        succeeded = true
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}

actor R12ChunkCheckpointStore {
    private static let maximumLedgerBytes = 16 * 1_024 * 1_024

    private let rootURL: URL
    private let ledgerURL: URL
    private let lockURL: URL
    private let digest: any R12Digesting
    private let fileSystem: any R12CheckpointFileSystem

    init(
        rootURL: URL,
        digest: any R12Digesting = R12CryptoKitDigest(),
        fileSystem: any R12CheckpointFileSystem = R12LocalCheckpointFileSystem()
    ) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.ledgerURL = standardizedRoot
            .appendingPathComponent("checkpoint-ledger-v1.json")
        self.lockURL = standardizedRoot
            .appendingPathComponent(".checkpoint-ledger-v1.lock")
        self.digest = digest
        self.fileSystem = fileSystem
    }

    func create(header: R12ChunkLedgerHeader) throws -> R12ResumeCursor {
        try fileSystem.ensureDirectory(rootURL)
        return try fileSystem.withExclusiveLock(at: lockURL) {
            guard !fileSystem.exists(ledgerURL) else {
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
            try fileSystem.writeNewAtomically(
                try R12CheckpointCanonical.data(ledger),
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
        return try withExistingLedgerLock {
            var ledger = try loadValidatedLedger()
            guard ledger.headSHA256 == expectedHead else {
                throw R12ChunkCheckpointError.staleHead(
                    expected: expectedHead,
                    observed: ledger.headSHA256
                )
            }
            try Self.validateTrackLayout(
                header: ledger.header,
                boundary: chunk.boundary
            )
            try validateArtifact(chunk.artifact)
            try Self.validateContinuity(
                previous: ledger.records.last?.boundary,
                next: chunk.boundary
            )
            let sequence = ledger.records.count
            let payload = R12CheckpointRecordPayload(
                sequence: sequence,
                boundary: chunk.boundary,
                artifact: chunk.artifact,
                previousRecordSHA256: ledger.headSHA256
            )
            let recordHash = try R12CheckpointValidation.sha256(
                digest.sha256(try R12CheckpointCanonical.data(payload)),
                field: "record_sha256"
            )
            let record = R12ChunkCheckpoint(
                sequence: sequence,
                boundary: chunk.boundary,
                artifact: chunk.artifact,
                previousRecordSHA256: ledger.headSHA256,
                recordSHA256: recordHash
            )
            ledger = R12ChunkCheckpointLedgerV1(
                schemaVersion: ledger.schemaVersion,
                header: ledger.header,
                records: ledger.records + [record],
                headSHA256: recordHash
            )
            try fileSystem.replaceAtomically(
                try R12CheckpointCanonical.data(ledger),
                at: ledgerURL
            )
            return try Self.cursor(for: ledger)
        }
    }

    func reopen(expecting expectation: R12ResumeExpectation) throws -> R12ResumeCursor {
        try withExistingLedgerLock {
            let ledger = try loadValidatedLedger()
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
        try withExistingLedgerLock {
            try R12CheckpointCanonical.data(loadValidatedLedger())
        }
    }
}

private extension R12ChunkCheckpointStore {
    private func loadValidatedLedger() throws -> R12ChunkCheckpointLedgerV1 {
        try fileSystem.validateDirectory(rootURL)
        guard fileSystem.exists(ledgerURL) else {
            throw R12ChunkCheckpointError.ledgerMissing
        }
        let data = try fileSystem.readRegularFile(
            ledgerURL,
            maximumBytes: Self.maximumLedgerBytes
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
            try Self.validateStoredBoundary(record.boundary)
            try Self.validateTrackLayout(
                header: ledger.header,
                boundary: record.boundary
            )
            try Self.validateStoredArtifact(record.artifact)
            _ = try R12CheckpointValidation.sha256(
                record.previousRecordSHA256,
                field: "previous_record_sha256"
            )
            _ = try R12CheckpointValidation.sha256(
                record.recordSHA256,
                field: "record_sha256"
            )
            try Self.validateContinuity(
                previous: previousBoundary,
                next: record.boundary
            )
            try validateArtifact(record.artifact)
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
        _ operation: () throws -> T
    ) throws -> T {
        try fileSystem.validateDirectory(rootURL)
        return try fileSystem.withExclusiveLock(at: lockURL, operation)
    }

    private func validateArtifact(_ artifact: R12ChunkArtifactIdentity) throws {
        try Self.validateStoredArtifact(artifact)
        let url = try containedURL(for: artifact.relativePath)
        let data = try fileSystem.readRegularFile(
            url,
            maximumBytes: Self.maximumLedgerBytes
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

    private func containedURL(for relativePath: String) throws -> URL {
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

    private static func validateContinuity(
        previous: R12SafeMediaBoundary?,
        next: R12SafeMediaBoundary
    ) throws {
        guard let previous else {
            guard next.firstVideoSampleIndex == 0,
                  next.start.value == 0 else {
                throw R12ChunkCheckpointError.checkpointContinuityMismatch
            }
            return
        }
        guard previous.endExclusive == next.start,
              previous.nextVideoSampleIndex == next.firstVideoSampleIndex else {
            throw R12ChunkCheckpointError.checkpointContinuityMismatch
        }
        let previousWatermarks = Dictionary(
            uniqueKeysWithValues: previous.trackWatermarks.map {
                ($0.trackID, $0)
            }
        )
        guard previousWatermarks.count == next.trackWatermarks.count else {
            throw R12ChunkCheckpointError.checkpointContinuityMismatch
        }
        for watermark in next.trackWatermarks {
            guard let prior = previousWatermarks[watermark.trackID],
                  prior.kind == watermark.kind,
                  watermark.nextSampleIndex >= prior.nextSampleIndex else {
                throw R12ChunkCheckpointError.checkpointContinuityMismatch
            }
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
            }
        )
        guard validated == header else {
            throw R12ChunkCheckpointError.sourceBindingMismatch
        }
    }

    private static func validateTrackLayout(
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

    private static func validateStoredBoundary(
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
            backendState: boundary.backendState
        )
        guard validated == boundary else {
            throw R12ChunkCheckpointError.invalidBoundary(
                reason: "noncanonical_stored_boundary"
            )
        }
    }

    private static func validateStoredArtifact(
        _ artifact: R12ChunkArtifactIdentity
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
    }

    private static func cursor(
        for ledger: R12ChunkCheckpointLedgerV1
    ) throws -> R12ResumeCursor {
        if let boundary = ledger.records.last?.boundary {
            return R12ResumeCursor(
                nextSequence: ledger.records.count,
                nextVideoSampleIndex: boundary.nextVideoSampleIndex,
                resumeTime: boundary.endExclusive,
                headSHA256: ledger.headSHA256
            )
        }
        return R12ResumeCursor(
            nextSequence: 0,
            nextVideoSampleIndex: 0,
            resumeTime: try R12MediaTime(value: 0, timescale: 1),
            headSHA256: ledger.headSHA256
        )
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
