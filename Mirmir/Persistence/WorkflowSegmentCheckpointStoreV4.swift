import AVFoundation
import CryptoKit
import CoreMedia
import Darwin
import Foundation

/// Content-addressed segment state remains byte-locked to the deployed v1
/// representation. Readers explicitly retain v1 support because rewriting
/// either the measurement binding or the synthetic reopen receipt would
/// invalidate hashes embedded in durable checkpoint documents.
enum WorkflowSegmentArtifactPersistenceSchemaV4 {
    static let immutableV1: UInt16 = 1

    static func isReadable(_ schemaVersion: UInt16) -> Bool {
        schemaVersion == immutableV1
    }
}

enum WorkflowSegmentCheckpointStoreV4Error: Error, Equatable,
    LocalizedError, Sendable {
    case invalidRoot
    case invalidClaim
    case invalidBoundaryOrdinal
    case invalidSegmentSequence
    case emptyTemporalCheckpoint
    case temporalCheckpointTooLarge
    case unsafeSource(String)
    case unsafeDestination(String)
    case artifactConflict(String)
    case atomicPublicationFailed(path: String, code: Int32)
    case artifactSizeMismatch(String)
    case artifactHashMismatch(String)
    case artifactReceiptMismatch(String)
    case temporalBindingMismatch
    case checkpointAttemptMismatch

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "The segment checkpoint root is not a safe local directory."
        case .invalidClaim:
            "The workflow claim cannot publish a running checkpoint boundary."
        case .invalidBoundaryOrdinal:
            "The segment boundary ordinal is not the next append-only ordinal."
        case .invalidSegmentSequence:
            "The checkpoint segment sequence is not exactly boundary-bound."
        case .emptyTemporalCheckpoint:
            "The temporal backend returned an empty checkpoint."
        case .temporalCheckpointTooLarge:
            "The temporal backend checkpoint exceeds the configured safety limit."
        case let .unsafeSource(path):
            "The segment source is not a safe single-link regular file: \(path)"
        case let .unsafeDestination(path):
            "The checkpoint destination is outside the trusted artifact root: \(path)"
        case let .artifactConflict(path):
            "A different checkpoint artifact already occupies \(path)."
        case let .atomicPublicationFailed(path, code):
            "Atomic checkpoint publication failed for \(path): errno \(code) "
                + "(\(String(cString: strerror(code))))."
        case let .artifactSizeMismatch(path):
            "Checkpoint artifact size verification failed for \(path)."
        case let .artifactHashMismatch(path):
            "Checkpoint artifact hash verification failed for \(path)."
        case let .artifactReceiptMismatch(path):
            "Checkpoint artifact reopen verification failed for \(path)."
        case .temporalBindingMismatch:
            "The measurement-state receipt is not bound to the temporal checkpoint."
        case .checkpointAttemptMismatch:
            "The checkpoint document belongs to a different worker attempt."
        }
    }
}

struct WorkflowSegmentCheckpointPublicationRequestV4: Equatable, Sendable {
    let checkpointID: WorkflowCheckpointIDV4
    let segmentArtifactID: WorkflowArtifactIDV4
    let temporalArtifactID: WorkflowArtifactIDV4
    let measurementArtifactID: WorkflowArtifactIDV4
    let sourceSegmentURL: URL
    let existingSegments: [WorkflowSegmentCheckpointV4]
    let startTime: WorkflowMediaTimeV4
    let endTimeExclusive: WorkflowMediaTimeV4
    let nextStartTime: WorkflowMediaTimeV4?
    let codecSettingsHash: WorkflowOutputContractID
    let trackProgress: [WorkflowTrackProgressV4]
    let auxiliaryState: [WorkflowCheckpointArtifactV4]
    let committedAt: WorkflowWallClockInstantV4
    let lastCompletedInputOrdinal: Int64
    let sourceSnapshotIdentityID: WorkflowSourceIdentityID?

    init(
        checkpointID: WorkflowCheckpointIDV4,
        segmentArtifactID: WorkflowArtifactIDV4,
        temporalArtifactID: WorkflowArtifactIDV4,
        measurementArtifactID: WorkflowArtifactIDV4,
        sourceSegmentURL: URL,
        existingSegments: [WorkflowSegmentCheckpointV4],
        startTime: WorkflowMediaTimeV4,
        endTimeExclusive: WorkflowMediaTimeV4,
        nextStartTime: WorkflowMediaTimeV4?,
        codecSettingsHash: WorkflowOutputContractID,
        trackProgress: [WorkflowTrackProgressV4],
        auxiliaryState: [WorkflowCheckpointArtifactV4] = [],
        committedAt: WorkflowWallClockInstantV4,
        lastCompletedInputOrdinal: Int64,
        sourceSnapshotIdentityID: WorkflowSourceIdentityID? = nil
    ) {
        self.checkpointID = checkpointID
        self.segmentArtifactID = segmentArtifactID
        self.temporalArtifactID = temporalArtifactID
        self.measurementArtifactID = measurementArtifactID
        self.sourceSegmentURL = sourceSegmentURL
        self.existingSegments = existingSegments
        self.startTime = startTime
        self.endTimeExclusive = endTimeExclusive
        self.nextStartTime = nextStartTime
        self.codecSettingsHash = codecSettingsHash
        self.trackProgress = trackProgress
        self.auxiliaryState = auxiliaryState
        self.committedAt = committedAt
        self.lastCompletedInputOrdinal = lastCompletedInputOrdinal
        self.sourceSnapshotIdentityID = sourceSnapshotIdentityID
    }
}

struct WorkflowSegmentCheckpointPublicationV4: Equatable, Sendable {
    let draft: WorkflowCheckpointDraftV4
    let segmentIdentity: AVFoundationSegmentIdentityV4
}

struct WorkflowSegmentCheckpointVerificationV4: Equatable, Sendable {
    let verifiedSegments: [AVFoundationSegmentIdentityV4]
    let temporalCheckpointByteCount: UInt64
    let temporalCheckpointSHA256: WorkflowCheckpointArtifactHashV4
    let lastCompletedInputOrdinal: Int64
}

struct WorkflowSegmentCheckpointResumePayloadV4: Sendable {
    let verification: WorkflowSegmentCheckpointVerificationV4
    let temporalCheckpoint: Data
}

struct WorkflowVerifiedSegmentArtifactV4: Equatable, Sendable {
    let url: URL
    let identity: AVFoundationSegmentIdentityV4
}

/// Append-only artifact store for independently decodable media segments and
/// the complete opaque state of a checkpointable temporal backend. The store
/// never mutates a published artifact. Repeating an interrupted publication is
/// idempotent only when the reopened bytes and semantic receipt are identical.
actor WorkflowSegmentCheckpointStoreV4 {
    static let maximumTemporalCheckpointBytes = 256 * 1_024 * 1_024

    let rootURL: URL
    private let durableFileSystem: WorkflowLocalDurableFileSystem
    private let publicationOperationHook:
        WorkflowLocalDurableFileSystem.OperationHook

    init(
        rootURL: URL,
        publicationOperationHook:
            WorkflowLocalDurableFileSystem.OperationHook? = nil
    ) throws {
        guard rootURL.isFileURL else {
            throw WorkflowSegmentCheckpointStoreV4Error.invalidRoot
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var metadata = stat()
        guard lstat(resolved.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkflowSegmentCheckpointStoreV4Error.invalidRoot
        }
        self.rootURL = resolved
        durableFileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: resolved
        )
        self.publicationOperationHook = publicationOperationHook ?? { _, _ in }
    }

    func publishBoundary(
        _ request: WorkflowSegmentCheckpointPublicationRequestV4,
        using claim: WorkflowDispatchClaimV4,
        upscaler: any PreparedCheckpointableTemporalFrameUpscaler,
        planSHA256: ASHSHA256V4
    ) async throws -> WorkflowSegmentCheckpointPublicationV4 {
        let temporalCheckpoint = try await upscaler.makeTemporalCheckpoint(
            planSHA256: planSHA256,
            lastCompletedInputOrdinal: request.lastCompletedInputOrdinal
        )
        return try await publishBoundary(
            request,
            using: claim,
            temporalCheckpoint: temporalCheckpoint
        )
    }

    /// Opaque-data overload keeps the persistence boundary testable without
    /// teaching the workflow layer how a specific backend encodes history.
    func publishBoundary(
        _ request: WorkflowSegmentCheckpointPublicationRequestV4,
        using claim: WorkflowDispatchClaimV4,
        temporalCheckpoint: Data
    ) async throws -> WorkflowSegmentCheckpointPublicationV4 {
        guard claim.jobID == claim.jobBinding.jobID,
              claim.lifecycle == .running || claim.lifecycle == .pausing,
              claim.attemptID != nil else {
            throw WorkflowSegmentCheckpointStoreV4Error.invalidClaim
        }
        guard !temporalCheckpoint.isEmpty else {
            throw WorkflowSegmentCheckpointStoreV4Error.emptyTemporalCheckpoint
        }
        guard temporalCheckpoint.count <= Self.maximumTemporalCheckpointBytes else {
            throw WorkflowSegmentCheckpointStoreV4Error.temporalCheckpointTooLarge
        }
        let processedVideoProgress = request.trackProgress.filter {
            $0.kind == .video && $0.nextOutputSampleIndex > 0
        }
        guard request.lastCompletedInputOrdinal >= 0,
              request.startTime.timescale == request.endTimeExclusive.timescale,
              request.startTime.value >= 0,
              request.startTime.value < request.endTimeExclusive.value,
              request.nextStartTime.map({
                  $0.timescale == request.startTime.timescale
                      && $0.value >= request.endTimeExclusive.value
              }) ?? true,
              processedVideoProgress.count == 1,
              (request.nextStartTime == nil)
                == processedVideoProgress[0].isComplete else {
            throw WorkflowSegmentCheckpointStoreV4Error.invalidSegmentSequence
        }
        try Self.validateExistingSegments(
            request.existingSegments,
            nextStart: request.startTime,
            codecSettingsHash: request.codecSettingsHash
        )
        let newArtifactIDs = [
            request.segmentArtifactID,
            request.temporalArtifactID,
            request.measurementArtifactID
        ]
        let occupiedArtifactIDs = Set(
            request.existingSegments.map(\.artifact.artifactID)
                + request.auxiliaryState.map(\.artifactID)
        )
        guard Set(newArtifactIDs).count == newArtifactIDs.count,
              newArtifactIDs.allSatisfy({
                  !occupiedArtifactIDs.contains($0)
              }) else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .invalidBoundaryOrdinal
        }
        let ordinal = UInt64(request.existingSegments.count)
        let directory = "jobs/\(claim.jobID.rawValue)/checkpoint-artifacts-v4"
        let segmentPath = directory + String(
            format: "/segments/segment-%020llu-%@.mov",
            ordinal,
            request.segmentArtifactID.rawValue
        )
        let temporalPath = directory + String(
            format: "/state/temporal-%020llu-%@.bin",
            ordinal,
            request.temporalArtifactID.rawValue
        )
        let measurementPath = directory + String(
            format: "/state/measurement-%020llu-%@.json",
            ordinal,
            request.measurementArtifactID.rawValue
        )

        let sourceIdentity = try await AVFoundationSegmentProbeV4().probe(
            url: request.sourceSegmentURL
        )
        let declaredDuration = CMTime(
            value: request.endTimeExclusive.value - request.startTime.value,
            timescale: request.startTime.timescale
        )
        let observedDuration = CMTime(
            value: sourceIdentity.duration.value,
            timescale: sourceIdentity.duration.timescale
        )
        guard sourceIdentity.tracks.contains(where: {
            $0.key.mediaType == AVMediaType.video.rawValue
        }), CMTimeCompare(observedDuration, declaredDuration) >= 0 else {
            throw WorkflowSegmentCheckpointStoreV4Error.invalidSegmentSequence
        }
        if let firstSegment = request.existingSegments.first {
            let first = try await Self.verifySegmentArtifact(
                firstSegment.artifact,
                artifactRootURL: rootURL
            )
            guard try first.identity.layoutSHA256
                    == sourceIdentity.layoutSHA256 else {
                throw WorkflowSegmentCheckpointStoreV4Error
                    .invalidSegmentSequence
            }
        }
        let segmentArtifact = try await publishFile(
            sourceURL: request.sourceSegmentURL,
            relativePath: segmentPath,
            artifactID: request.segmentArtifactID,
            kind: .segment,
            expectedMediaIdentity: sourceIdentity
        )
        let segment = try WorkflowSegmentCheckpointV4(
            ordinal: ordinal,
            artifact: segmentArtifact,
            startTime: request.startTime,
            endTimeExclusive: request.endTimeExclusive,
            nextStartTime: request.nextStartTime,
            codecSettingsHash: request.codecSettingsHash,
            isIndependentlyDecodable: true
        )
        let temporalArtifact = try await publishData(
            temporalCheckpoint,
            relativePath: temporalPath,
            artifactID: request.temporalArtifactID,
            kind: .temporalHistory
        )
        let measurementBinding = WorkflowMeasurementStateBindingV4(
            checkpointID: request.checkpointID,
            ordinal: ordinal,
            temporalArtifactID: temporalArtifact.artifactID,
            temporalSHA256: temporalArtifact.sha256,
            lastCompletedInputOrdinal: request.lastCompletedInputOrdinal
        )
        let measurementData = try WorkflowCanonicalCodec().canonicalData(
            measurementBinding
        )
        let measurementArtifact = try await publishData(
            measurementData,
            relativePath: measurementPath,
            artifactID: request.measurementArtifactID,
            kind: .measurementHysteresis
        )
        let draft = WorkflowCheckpointDraftV4(
            checkpointID: request.checkpointID,
            committedAt: request.committedAt,
            segments: request.existingSegments + [segment],
            trackProgress: request.trackProgress,
            temporalHistory: temporalArtifact,
            measurementHysteresis: measurementArtifact,
            auxiliaryState: request.auxiliaryState,
            sourceSnapshotIdentityID: request.sourceSnapshotIdentityID
        )
        return WorkflowSegmentCheckpointPublicationV4(
            draft: draft,
            segmentIdentity: sourceIdentity
        )
    }

    func verifyCheckpoint(
        _ document: WorkflowCheckpointDocumentV4
    ) async throws -> WorkflowSegmentCheckpointVerificationV4 {
        var segmentIdentities: [AVFoundationSegmentIdentityV4] = []
        for segment in document.body.segments {
            let verified = try await Self.verifySegmentArtifact(
                segment.artifact,
                artifactRootURL: rootURL
            )
            segmentIdentities.append(verified.identity)
        }
        let temporal = try await Self.verifyArtifact(
            document.body.temporalHistory,
            artifactRootURL: rootURL,
            mediaIdentity: nil
        )
        let measurement = try await Self.verifyArtifact(
            document.body.measurementHysteresis,
            artifactRootURL: rootURL,
            mediaIdentity: nil
        )
        let binding: WorkflowMeasurementStateBindingV4
        do {
            binding = try WorkflowCanonicalCodec().decodeCanonical(
                WorkflowMeasurementStateBindingV4.self,
                from: measurement.data
            )
        } catch {
            throw WorkflowSegmentCheckpointStoreV4Error.temporalBindingMismatch
        }
        guard binding.checkpointID == document.body.checkpointID,
              binding.ordinal == document.body.ordinal,
              binding.temporalArtifactID
                == document.body.temporalHistory.artifactID,
              binding.temporalSHA256 == document.body.temporalHistory.sha256,
              binding.lastCompletedInputOrdinal >= 0 else {
            throw WorkflowSegmentCheckpointStoreV4Error.temporalBindingMismatch
        }
        for artifact in document.body.auxiliaryState {
            _ = try await Self.verifyArtifact(
                artifact,
                artifactRootURL: rootURL,
                mediaIdentity: nil
            )
        }
        return WorkflowSegmentCheckpointVerificationV4(
            verifiedSegments: segmentIdentities,
            temporalCheckpointByteCount: temporal.byteCount,
            temporalCheckpointSHA256: document.body.temporalHistory.sha256,
            lastCompletedInputOrdinal: binding.lastCompletedInputOrdinal
        )
    }

    func loadResumePayload(
        _ document: WorkflowCheckpointDocumentV4
    ) async throws -> WorkflowSegmentCheckpointResumePayloadV4 {
        let verification = try await verifyCheckpoint(document)
        // Reopen the exact hash-bound state after verifying the rest of the
        // checkpoint. `verifyArtifact` uses O_NOFOLLOW and a descriptor-bound
        // identity, so a pathname swap cannot substitute resume state.
        let temporal = try await Self.verifyArtifact(
            document.body.temporalHistory,
            artifactRootURL: rootURL,
            mediaIdentity: nil
        )
        return WorkflowSegmentCheckpointResumePayloadV4(
            verification: verification,
            temporalCheckpoint: temporal.data
        )
    }

    func restoreCheckpoint(
        _ document: WorkflowCheckpointDocumentV4,
        using claim: WorkflowDispatchClaimV4,
        into upscaler: any PreparedCheckpointableTemporalFrameUpscaler,
        planSHA256: ASHSHA256V4
    ) async throws -> WorkflowSegmentCheckpointVerificationV4 {
        guard claim.jobID == document.body.compatibility.jobBinding.jobID,
              claim.jobBinding == document.body.compatibility.jobBinding,
              claim.attemptID != nil,
              claim.lifecycle == .running || claim.lifecycle == .recovering else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .checkpointAttemptMismatch
        }
        let verification = try await verifyCheckpoint(document)
        let temporal = try await Self.verifyArtifact(
            document.body.temporalHistory,
            artifactRootURL: rootURL,
            mediaIdentity: nil
        )
        try await upscaler.restoreTemporalCheckpoint(
            temporal.data,
            planSHA256: planSHA256
        )
        return verification
    }

    static func verifySegmentArtifact(
        _ artifact: WorkflowCheckpointArtifactV4,
        artifactRootURL: URL
    ) async throws -> WorkflowVerifiedSegmentArtifactV4 {
        guard artifact.kind == .segment else {
            throw WorkflowSegmentCheckpointStoreV4Error.artifactConflict(
                artifact.relativePath
            )
        }
        let url = try resolve(
            artifact.relativePath,
            artifactRootURL: artifactRootURL
        )
        try validateArtifactPath(url, artifactRootURL: artifactRootURL)
        let before = try WorkflowV4Validation.regularFileIdentity(at: url)
        let identity = try await AVFoundationSegmentProbeV4().probe(url: url)
        _ = try await verifyArtifact(
            artifact,
            artifactRootURL: artifactRootURL,
            mediaIdentity: identity
        )
        let after = try WorkflowV4Validation.regularFileIdentity(at: url)
        guard before == after else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .artifactReceiptMismatch(artifact.relativePath)
        }
        return WorkflowVerifiedSegmentArtifactV4(url: url, identity: identity)
    }

    static func rawFileIdentity(
        _ url: URL
    ) throws -> (byteCount: UInt64, sha256: String) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(url.path)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(url.path)
        }
        var hasher = SHA256()
        var total: UInt64 = 0
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(
                    url.path
                )
            }
            hasher.update(data: Data(bytes[0 ..< count]))
            total += UInt64(count)
        }
        return (total, Self.hex(hasher.finalize()))
    }
}

private struct WorkflowMeasurementStateBindingV4: Codable, Equatable,
    Sendable {
    static let currentSchemaVersion =
        WorkflowSegmentArtifactPersistenceSchemaV4.immutableV1

    let schemaVersion: UInt16
    let checkpointID: WorkflowCheckpointIDV4
    let ordinal: UInt64
    let temporalArtifactID: WorkflowArtifactIDV4
    let temporalSHA256: WorkflowCheckpointArtifactHashV4
    let lastCompletedInputOrdinal: Int64

    init(
        checkpointID: WorkflowCheckpointIDV4,
        ordinal: UInt64,
        temporalArtifactID: WorkflowArtifactIDV4,
        temporalSHA256: WorkflowCheckpointArtifactHashV4,
        lastCompletedInputOrdinal: Int64
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.checkpointID = checkpointID
        self.ordinal = ordinal
        self.temporalArtifactID = temporalArtifactID
        self.temporalSHA256 = temporalSHA256
        self.lastCompletedInputOrdinal = lastCompletedInputOrdinal
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case checkpointID
        case ordinal
        case temporalArtifactID
        case temporalSHA256
        case lastCompletedInputOrdinal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard WorkflowSegmentArtifactPersistenceSchemaV4.isReadable(
            schemaVersion
        ) else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .temporalBindingMismatch
        }
        self.init(
            checkpointID: try container.decode(
                WorkflowCheckpointIDV4.self,
                forKey: .checkpointID
            ),
            ordinal: try container.decode(UInt64.self, forKey: .ordinal),
            temporalArtifactID: try container.decode(
                WorkflowArtifactIDV4.self,
                forKey: .temporalArtifactID
            ),
            temporalSHA256: try container.decode(
                WorkflowCheckpointArtifactHashV4.self,
                forKey: .temporalSHA256
            ),
            lastCompletedInputOrdinal: try container.decode(
                Int64.self,
                forKey: .lastCompletedInputOrdinal
            )
        )
    }
}

private struct WorkflowCheckpointArtifactReopenReceiptV4: Codable,
    Equatable, Sendable {
    static let currentSchemaVersion =
        WorkflowSegmentArtifactPersistenceSchemaV4.immutableV1

    let schemaVersion: UInt16
    let artifactID: WorkflowArtifactIDV4
    let kind: WorkflowCheckpointArtifactKindV4
    let relativePath: String
    let byteCount: UInt64
    let sha256: WorkflowCheckpointArtifactHashV4
    let mediaIdentitySHA256: String?

    init(
        artifactID: WorkflowArtifactIDV4,
        kind: WorkflowCheckpointArtifactKindV4,
        relativePath: String,
        byteCount: UInt64,
        sha256: WorkflowCheckpointArtifactHashV4,
        mediaIdentitySHA256: String?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.artifactID = artifactID
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mediaIdentitySHA256 = mediaIdentitySHA256
    }
}

private extension WorkflowSegmentCheckpointStoreV4 {
    struct VerifiedArtifact {
        let data: Data
        let byteCount: UInt64
    }

    static func validateExistingSegments(
        _ segments: [WorkflowSegmentCheckpointV4],
        nextStart: WorkflowMediaTimeV4,
        codecSettingsHash: WorkflowOutputContractID
    ) throws {
        guard segments.enumerated().allSatisfy({
            $0.element.ordinal == UInt64($0.offset)
        }) else {
            throw WorkflowSegmentCheckpointStoreV4Error.invalidBoundaryOrdinal
        }
        for index in segments.indices.dropFirst() {
            let previous = segments[index - 1]
            let current = segments[index]
            guard previous.endTimeExclusive.timescale
                    == current.startTime.timescale,
                  previous.endTimeExclusive.value <= current.startTime.value,
                  previous.nextStartTime == current.startTime,
                  previous.codecSettingsHash == current.codecSettingsHash else {
                throw WorkflowSegmentCheckpointStoreV4Error
                    .invalidSegmentSequence
            }
        }
        if let last = segments.last {
            guard last.endTimeExclusive.timescale == nextStart.timescale,
                  last.endTimeExclusive.value <= nextStart.value,
                  last.nextStartTime == nextStart,
                  last.codecSettingsHash == codecSettingsHash else {
                throw WorkflowSegmentCheckpointStoreV4Error
                    .invalidSegmentSequence
            }
        } else if nextStart.value < 0 {
            throw WorkflowSegmentCheckpointStoreV4Error.invalidSegmentSequence
        }
    }

    func publishData(
        _ data: Data,
        relativePath: String,
        artifactID: WorkflowArtifactIDV4,
        kind: WorkflowCheckpointArtifactKindV4
    ) async throws -> WorkflowCheckpointArtifactV4 {
        let temporaryInput = rootURL.appendingPathComponent(
            ".checkpoint-input-\(UUID().uuidString).tmp"
        )
        do {
            try Self.writePrivateTemporaryData(data, to: temporaryInput)
            defer { try? FileManager.default.removeItem(at: temporaryInput) }
            return try await publishFile(
                sourceURL: temporaryInput,
                relativePath: relativePath,
                artifactID: artifactID,
                kind: kind,
                expectedMediaIdentity: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryInput)
            throw error
        }
    }

    func publishFile(
        sourceURL: URL,
        relativePath: String,
        artifactID: WorkflowArtifactIDV4,
        kind: WorkflowCheckpointArtifactKindV4,
        expectedMediaIdentity: AVFoundationSegmentIdentityV4?
    ) async throws -> WorkflowCheckpointArtifactV4 {
        guard WorkflowV4Validation.isSafeRelativePath(relativePath) else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeDestination(
                relativePath
            )
        }
        let destination = try Self.resolve(
            relativePath,
            artifactRootURL: rootURL
        )
        do {
            try durableFileSystem.ensureDirectory(
                destination.deletingLastPathComponent()
            )
        } catch let error as WorkflowDurableFileSystemError {
            if case let .ioFailure(_, _, code) = error {
                throw WorkflowSegmentCheckpointStoreV4Error
                    .atomicPublicationFailed(
                        path: destination.path,
                        code: code
                    )
            }
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeDestination(
                relativePath
            )
        } catch {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeDestination(
                relativePath
            )
        }
        let expected = try Self.rawFileIdentity(sourceURL)
        let sourceMediaSHA = try expectedMediaIdentity?.canonicalSHA256

        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".publish-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try publicationOperationHook(.beforeTemporaryCreate, temporary)
        } catch let error as WorkflowDurableFileSystemError {
            if case let .ioFailure(_, _, code) = error {
                throw WorkflowSegmentCheckpointStoreV4Error
                    .atomicPublicationFailed(
                        path: temporary.path,
                        code: code
                    )
            }
            throw error
        }
        try Self.copyAndSync(sourceURL, to: temporary)
        let temporaryIdentity = try Self.rawFileIdentity(temporary)
        guard temporaryIdentity == expected else {
            throw WorkflowSegmentCheckpointStoreV4Error.artifactHashMismatch(
                relativePath
            )
        }
        do {
            try Self.renameExclusively(temporary, to: destination)
            try Self.syncDirectory(destination.deletingLastPathComponent())
        } catch WorkflowSegmentCheckpointStoreV4Error.artifactConflict {
            // A retry after process termination is idempotent only if the
            // previously published artifact is exactly the intended artifact.
            guard try durableFileSystem.regularFileExists(destination) else {
                throw WorkflowSegmentCheckpointStoreV4Error.artifactConflict(
                    relativePath
                )
            }
            let existing = try Self.rawFileIdentity(destination)
            guard existing == expected else {
                throw WorkflowSegmentCheckpointStoreV4Error.artifactConflict(
                    relativePath
                )
            }
        }
        if let expectedMediaIdentity {
            guard try durableFileSystem.regularFileExists(destination) else {
                throw WorkflowSegmentCheckpointStoreV4Error
                    .artifactReceiptMismatch(relativePath)
            }
            let reopened = try await AVFoundationSegmentProbeV4().probe(
                url: destination
            )
            guard reopened == expectedMediaIdentity else {
                throw WorkflowSegmentCheckpointStoreV4Error
                    .artifactReceiptMismatch(relativePath)
            }
        }
        let sha = try WorkflowCheckpointArtifactHashV4(expected.sha256)
        let receipt = WorkflowCheckpointArtifactReopenReceiptV4(
            artifactID: artifactID,
            kind: kind,
            relativePath: relativePath,
            byteCount: expected.byteCount,
            sha256: sha,
            mediaIdentitySHA256: sourceMediaSHA
        )
        let receiptData = try WorkflowCanonicalCodec().canonicalData(receipt)
        let receiptSHA = try WorkflowCheckpointArtifactHashV4(
            Self.sha256(receiptData)
        )
        return try WorkflowCheckpointArtifactV4(
            artifactID: artifactID,
            kind: kind,
            relativePath: relativePath,
            byteCount: expected.byteCount,
            sha256: sha,
            reopenReceiptSHA256: receiptSHA
        )
    }

    static func verifyArtifact(
        _ artifact: WorkflowCheckpointArtifactV4,
        artifactRootURL: URL,
        mediaIdentity: AVFoundationSegmentIdentityV4?
    ) async throws -> VerifiedArtifact {
        let url = try resolve(
            artifact.relativePath,
            artifactRootURL: artifactRootURL
        )
        try validateArtifactPath(url, artifactRootURL: artifactRootURL)
        let observed = try rawFileIdentity(url)
        guard observed.byteCount == artifact.byteCount else {
            throw WorkflowSegmentCheckpointStoreV4Error.artifactSizeMismatch(
                artifact.relativePath
            )
        }
        guard observed.sha256 == artifact.sha256.rawValue else {
            throw WorkflowSegmentCheckpointStoreV4Error.artifactHashMismatch(
                artifact.relativePath
            )
        }
        let receipt = WorkflowCheckpointArtifactReopenReceiptV4(
            artifactID: artifact.artifactID,
            kind: artifact.kind,
            relativePath: artifact.relativePath,
            byteCount: artifact.byteCount,
            sha256: artifact.sha256,
            mediaIdentitySHA256: try mediaIdentity?.canonicalSHA256
        )
        let receiptData = try WorkflowCanonicalCodec().canonicalData(receipt)
        guard Self.sha256(receiptData)
                == artifact.reopenReceiptSHA256.rawValue else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .artifactReceiptMismatch(artifact.relativePath)
        }
        let maximum = artifact.kind == .segment
            ? Int.max
            : Self.maximumTemporalCheckpointBytes
        guard artifact.byteCount <= UInt64(maximum) else {
            throw WorkflowSegmentCheckpointStoreV4Error.temporalCheckpointTooLarge
        }
        let data: Data
        if artifact.kind == .segment {
            data = Data()
        } else {
            data = try readVerifiedStateData(
                url,
                expectedByteCount: artifact.byteCount,
                expectedSHA256: artifact.sha256.rawValue,
                maximumBytes: maximum
            )
        }
        return VerifiedArtifact(data: data, byteCount: observed.byteCount)
    }

    static func resolve(
        _ relativePath: String,
        artifactRootURL: URL
    ) throws -> URL {
        guard WorkflowV4Validation.isSafeRelativePath(relativePath) else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeDestination(
                relativePath
            )
        }
        let root = artifactRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeDestination(
                relativePath
            )
        }
        return candidate
    }

    static func validateArtifactPath(
        _ url: URL,
        artifactRootURL: URL
    ) throws {
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: artifactRootURL.standardizedFileURL
                .resolvingSymlinksInPath()
        )
        guard try fileSystem.regularFileExists(url) else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(url.path)
        }
    }

    static func copyAndSync(_ source: URL, to destination: URL) throws {
        let sourceFD = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(
                source.path
            )
        }
        defer { close(sourceFD) }
        var sourceMetadata = stat()
        guard fstat(sourceFD, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFREG,
              sourceMetadata.st_nlink == 1 else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(
                source.path
            )
        }
        let destinationFD = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationFD >= 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: destination.path, code: code)
        }
        var closeDestination = true
        defer { if closeDestination { close(destinationFD) } }
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let readCount = Darwin.read(sourceFD, &bytes, bytes.count)
            if readCount == 0 { break }
            guard readCount > 0 else {
                if errno == EINTR { continue }
                throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(
                    source.path
                )
            }
            var written = 0
            while written < readCount {
                let writeCount = bytes.withUnsafeBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return -1 }
                    return Darwin.write(
                        destinationFD,
                        base.advanced(by: written),
                        readCount - written
                    )
                }
                guard writeCount > 0 else {
                    if writeCount < 0, errno == EINTR { continue }
                    let code = errno
                    throw WorkflowSegmentCheckpointStoreV4Error
                        .atomicPublicationFailed(
                            path: destination.path,
                            code: code
                        )
                }
                written += writeCount
            }
        }
        guard fsync(destinationFD) == 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: destination.path, code: code)
        }
        let closeStatus = close(destinationFD)
        closeDestination = false
        guard closeStatus == 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: destination.path, code: code)
        }
    }

    static func renameExclusively(_ source: URL, to destination: URL) throws {
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        if errno == EEXIST {
            throw WorkflowSegmentCheckpointStoreV4Error.artifactConflict(
                destination.path
            )
        }
        let code = errno
        throw WorkflowSegmentCheckpointStoreV4Error
            .atomicPublicationFailed(path: destination.path, code: code)
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: directory.path, code: code)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: directory.path, code: code)
        }
    }

    static func writePrivateTemporaryData(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: url.path, code: code)
        }
        var shouldClose = true
        defer { if shouldClose { close(descriptor) } }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    buffer.count - written
                )
                guard count > 0 else {
                    if count < 0, errno == EINTR { continue }
                    let code = errno
                    throw WorkflowSegmentCheckpointStoreV4Error
                        .atomicPublicationFailed(path: url.path, code: code)
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: url.path, code: code)
        }
        let closeStatus = close(descriptor)
        shouldClose = false
        guard closeStatus == 0 else {
            let code = errno
            throw WorkflowSegmentCheckpointStoreV4Error
                .atomicPublicationFailed(path: url.path, code: code)
        }
    }

    static func readVerifiedStateData(
        _ url: URL,
        expectedByteCount: UInt64,
        expectedSHA256: String,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(url.path)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) == expectedByteCount,
              expectedByteCount <= UInt64(maximumBytes) else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .artifactSizeMismatch(url.path)
        }
        var data = Data()
        data.reserveCapacity(Int(expectedByteCount))
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw WorkflowSegmentCheckpointStoreV4Error.unsafeSource(
                    url.path
                )
            }
            let chunk = Data(buffer[0 ..< count])
            data.append(chunk)
            hasher.update(data: chunk)
        }
        guard UInt64(data.count) == expectedByteCount else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .artifactSizeMismatch(url.path)
        }
        guard hex(hasher.finalize()) == expectedSHA256 else {
            throw WorkflowSegmentCheckpointStoreV4Error
                .artifactHashMismatch(url.path)
        }
        return data
    }

    static func sha256(_ data: Data) -> String {
        Self.hex(SHA256.hash(data: data))
    }

    static func hex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
