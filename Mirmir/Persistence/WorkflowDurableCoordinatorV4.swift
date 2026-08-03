import CryptoKit
import Darwin
import Foundation

// MARK: - Durable dispatch identity and clock

enum WorkflowWorkerIDPurposeV4: WorkflowIdentifierPurpose {}
enum WorkflowLeaseIDPurposeV4: WorkflowIdentifierPurpose {}
enum WorkflowArtifactIDPurposeV4: WorkflowIdentifierPurpose {}
enum WorkflowCheckpointIDPurposeV4: WorkflowIdentifierPurpose {}
enum WorkflowLeaseDocumentDigestPurposeV4: WorkflowDigestPurpose {}
enum WorkflowCheckpointDocumentDigestPurposeV4: WorkflowDigestPurpose {}
enum WorkflowCheckpointArtifactDigestPurposeV4: WorkflowDigestPurpose {}

typealias WorkflowWorkerIDV4 = WorkflowIdentifier<WorkflowWorkerIDPurposeV4>
typealias WorkflowLeaseIDV4 = WorkflowIdentifier<WorkflowLeaseIDPurposeV4>
typealias WorkflowArtifactIDV4 = WorkflowIdentifier<WorkflowArtifactIDPurposeV4>
typealias WorkflowCheckpointIDV4 = WorkflowIdentifier<WorkflowCheckpointIDPurposeV4>
typealias WorkflowLeaseDocumentHashV4 =
    WorkflowDigest<WorkflowLeaseDocumentDigestPurposeV4>
typealias WorkflowCheckpointDocumentHashV4 =
    WorkflowDigest<WorkflowCheckpointDocumentDigestPurposeV4>
typealias WorkflowCheckpointArtifactHashV4 =
    WorkflowDigest<WorkflowCheckpointArtifactDigestPurposeV4>

struct WorkflowWallClockInstantV4:
    Codable,
    Comparable,
    Hashable,
    Sendable
{
    let nanosecondsSinceUnixEpoch: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanosecondsSinceUnixEpoch < rhs.nanosecondsSinceUnixEpoch
    }

    func advanced(by interval: WorkflowLeaseIntervalV4) throws -> Self {
        let result = nanosecondsSinceUnixEpoch.addingReportingOverflow(
            interval.nanoseconds
        )
        guard !result.overflow else {
            throw WorkflowDurableCoordinatorErrorV4.clockOverflow
        }
        return Self(nanosecondsSinceUnixEpoch: result.partialValue)
    }
}

struct WorkflowLeaseIntervalV4: Codable, Equatable, Hashable, Sendable {
    static let maximumNanoseconds: UInt64 = 24 * 60 * 60 * 1_000_000_000

    let nanoseconds: UInt64

    init(nanoseconds: UInt64) throws {
        guard nanoseconds > 0,
              nanoseconds <= Self.maximumNanoseconds else {
            throw WorkflowDurableCoordinatorErrorV4.invalidLeaseInterval
        }
        self.nanoseconds = nanoseconds
    }
}

protocol WorkflowWallClockV4: Sendable {
    func now() -> WorkflowWallClockInstantV4
}

struct WorkflowSystemWallClockV4: WorkflowWallClockV4 {
    func now() -> WorkflowWallClockInstantV4 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_REALTIME, &value) == 0)
        let seconds = UInt64(max(0, value.tv_sec))
        let secondsProduct = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        let nanoseconds = UInt64(max(0, value.tv_nsec))
        let total = secondsProduct.partialValue.addingReportingOverflow(
            nanoseconds
        )
        return WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch:
                secondsProduct.overflow || total.overflow
                    ? UInt64.max
                    : total.partialValue
        )
    }
}

// MARK: - Canonical worker lease

enum WorkflowLeaseStatusV4: String, Codable, Equatable, Hashable, Sendable {
    case active
    case released
}

struct WorkflowLeaseBodyV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let generation: UInt64
    let leaseID: WorkflowLeaseIDV4
    let workerID: WorkflowWorkerIDV4
    let jobBinding: WorkflowJobBinding
    let acquisitionEventID: WorkflowEventID
    let acquisitionCommandID: WorkflowCommandID
    let acquiredFrom: WorkflowJobLifecycle
    let acquiredTo: WorkflowJobLifecycle
    let attemptID: WorkflowAttemptID?
    let acquiredAt: WorkflowWallClockInstantV4
    let lastHeartbeatAt: WorkflowWallClockInstantV4
    let expiresAt: WorkflowWallClockInstantV4
    let recoveredLeaseID: WorkflowLeaseIDV4?
    let status: WorkflowLeaseStatusV4
    let releasedAt: WorkflowWallClockInstantV4?

    init(
        generation: UInt64,
        leaseID: WorkflowLeaseIDV4,
        workerID: WorkflowWorkerIDV4,
        jobBinding: WorkflowJobBinding,
        acquisitionEventID: WorkflowEventID,
        acquisitionCommandID: WorkflowCommandID,
        acquiredFrom: WorkflowJobLifecycle,
        acquiredTo: WorkflowJobLifecycle,
        attemptID: WorkflowAttemptID?,
        acquiredAt: WorkflowWallClockInstantV4,
        lastHeartbeatAt: WorkflowWallClockInstantV4,
        expiresAt: WorkflowWallClockInstantV4,
        recoveredLeaseID: WorkflowLeaseIDV4?,
        status: WorkflowLeaseStatusV4,
        releasedAt: WorkflowWallClockInstantV4?
    ) throws {
        guard acquiredFrom.allowsTransition(to: acquiredTo) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidLeaseDocument
        }
        guard acquiredAt <= lastHeartbeatAt,
              lastHeartbeatAt < expiresAt else {
            throw WorkflowDurableCoordinatorErrorV4.invalidLeaseDocument
        }
        switch status {
        case .active:
            guard releasedAt == nil else {
                throw WorkflowDurableCoordinatorErrorV4.invalidLeaseDocument
            }
        case .released:
            guard let releasedAt, releasedAt >= lastHeartbeatAt else {
                throw WorkflowDurableCoordinatorErrorV4.invalidLeaseDocument
            }
        }
        if acquiredTo == .running, attemptID == nil {
            throw WorkflowDurableCoordinatorErrorV4.invalidLeaseDocument
        }

        schemaVersion = Self.currentSchemaVersion
        self.generation = generation
        self.leaseID = leaseID
        self.workerID = workerID
        self.jobBinding = jobBinding
        self.acquisitionEventID = acquisitionEventID
        self.acquisitionCommandID = acquisitionCommandID
        self.acquiredFrom = acquiredFrom
        self.acquiredTo = acquiredTo
        self.attemptID = attemptID
        self.acquiredAt = acquiredAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.expiresAt = expiresAt
        self.recoveredLeaseID = recoveredLeaseID
        self.status = status
        self.releasedAt = releasedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generation
        case leaseID
        case workerID
        case jobBinding
        case acquisitionEventID
        case acquisitionCommandID
        case acquiredFrom
        case acquiredTo
        case attemptID
        case acquiredAt
        case lastHeartbeatAt
        case expiresAt
        case recoveredLeaseID
        case status
        case releasedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw WorkflowDurableCoordinatorErrorV4.unsupportedSchemaVersion(
                type: "WorkflowLeaseBodyV4",
                actual: version,
                current: Self.currentSchemaVersion
            )
        }
        try self.init(
            generation: container.decode(UInt64.self, forKey: .generation),
            leaseID: container.decode(WorkflowLeaseIDV4.self, forKey: .leaseID),
            workerID: container.decode(WorkflowWorkerIDV4.self, forKey: .workerID),
            jobBinding: container.decode(WorkflowJobBinding.self, forKey: .jobBinding),
            acquisitionEventID: container.decode(
                WorkflowEventID.self,
                forKey: .acquisitionEventID
            ),
            acquisitionCommandID: container.decode(
                WorkflowCommandID.self,
                forKey: .acquisitionCommandID
            ),
            acquiredFrom: container.decode(
                WorkflowJobLifecycle.self,
                forKey: .acquiredFrom
            ),
            acquiredTo: container.decode(
                WorkflowJobLifecycle.self,
                forKey: .acquiredTo
            ),
            attemptID: container.decodeIfPresent(
                WorkflowAttemptID.self,
                forKey: .attemptID
            ),
            acquiredAt: container.decode(
                WorkflowWallClockInstantV4.self,
                forKey: .acquiredAt
            ),
            lastHeartbeatAt: container.decode(
                WorkflowWallClockInstantV4.self,
                forKey: .lastHeartbeatAt
            ),
            expiresAt: container.decode(
                WorkflowWallClockInstantV4.self,
                forKey: .expiresAt
            ),
            recoveredLeaseID: container.decodeIfPresent(
                WorkflowLeaseIDV4.self,
                forKey: .recoveredLeaseID
            ),
            status: container.decode(WorkflowLeaseStatusV4.self, forKey: .status),
            releasedAt: container.decodeIfPresent(
                WorkflowWallClockInstantV4.self,
                forKey: .releasedAt
            )
        )
    }
}

struct WorkflowLeaseDocumentV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 2

    let schemaVersion: UInt16
    let bodyHash: WorkflowLeaseDocumentHashV4
    let body: WorkflowLeaseBodyV4

    fileprivate init(bodyHash: WorkflowLeaseDocumentHashV4, body: WorkflowLeaseBodyV4) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }
}

/// Canonical v1 lease envelope retained for one-way, hash-preserving
/// migration.  The lease body is fully validated before a v2 envelope is
/// atomically published.
struct WorkflowLeaseDocumentV1: Codable, Equatable, Hashable, Sendable {
    static let schemaVersionValue: UInt16 = 1

    let schemaVersion: UInt16
    let bodyHash: WorkflowLeaseDocumentHashV4
    let body: WorkflowLeaseBodyV4

    init(bodyHash: WorkflowLeaseDocumentHashV4, body: WorkflowLeaseBodyV4) {
        schemaVersion = Self.schemaVersionValue
        self.bodyHash = bodyHash
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bodyHash
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.schemaVersionValue else {
            throw WorkflowDurableCoordinatorErrorV4.unsupportedSchemaVersion(
                type: "WorkflowLeaseDocumentV1",
                actual: schemaVersion,
                current: Self.schemaVersionValue
            )
        }
        self.init(
            bodyHash: try container.decode(
                WorkflowLeaseDocumentHashV4.self,
                forKey: .bodyHash
            ),
            body: try container.decode(
                WorkflowLeaseBodyV4.self,
                forKey: .body
            )
        )
    }
}

struct WorkflowLeaseAcquisitionRequestV4: Equatable, Hashable, Sendable {
    let jobID: WorkflowJobID?
    let leaseID: WorkflowLeaseIDV4
    let workerID: WorkflowWorkerIDV4
    let eventID: WorkflowEventID
    let commandID: WorkflowCommandID
    let expectedLifecycle: WorkflowJobLifecycle
    let targetLifecycle: WorkflowJobLifecycle
    let attemptID: WorkflowAttemptID?
    let duration: WorkflowLeaseIntervalV4

    init(
        jobID: WorkflowJobID? = nil,
        leaseID: WorkflowLeaseIDV4,
        workerID: WorkflowWorkerIDV4,
        eventID: WorkflowEventID,
        commandID: WorkflowCommandID,
        expectedLifecycle: WorkflowJobLifecycle = .queued,
        targetLifecycle: WorkflowJobLifecycle = .probing,
        attemptID: WorkflowAttemptID? = nil,
        duration: WorkflowLeaseIntervalV4
    ) throws {
        guard expectedLifecycle.allowsTransition(to: targetLifecycle),
              !expectedLifecycle.isTerminal else {
            throw WorkflowDurableCoordinatorErrorV4.invalidAcquisitionTransition
        }
        if jobID == nil {
            guard expectedLifecycle == .queued, targetLifecycle == .probing else {
                throw WorkflowDurableCoordinatorErrorV4.invalidAcquisitionTransition
            }
        }
        let transitionRequiresAttempt = targetLifecycle == .running
            || expectedLifecycle == .running
            || expectedLifecycle == .pausing
        if transitionRequiresAttempt {
            guard attemptID != nil else {
                throw WorkflowDurableCoordinatorErrorV4.invalidAcquisitionTransition
            }
        } else if attemptID != nil {
            throw WorkflowDurableCoordinatorErrorV4.invalidAcquisitionTransition
        }
        self.jobID = jobID
        self.leaseID = leaseID
        self.workerID = workerID
        self.eventID = eventID
        self.commandID = commandID
        self.expectedLifecycle = expectedLifecycle
        self.targetLifecycle = targetLifecycle
        self.attemptID = attemptID
        self.duration = duration
    }
}

struct WorkflowDispatchClaimV4: Equatable, Hashable, Sendable {
    let jobID: WorkflowJobID
    let jobBinding: WorkflowJobBinding
    let leaseID: WorkflowLeaseIDV4
    let workerID: WorkflowWorkerIDV4
    let acquisitionCommandID: WorkflowCommandID
    let lifecycle: WorkflowJobLifecycle
    let attemptID: WorkflowAttemptID?
    let expiresAt: WorkflowWallClockInstantV4
    let leaseGeneration: UInt64
}

struct WorkflowLeaseHeartbeatV4: Equatable, Hashable, Sendable {
    let claim: WorkflowDispatchClaimV4
    let interval: WorkflowLeaseIntervalV4
}

struct WorkflowLifecycleCommandV4: Equatable, Hashable, Sendable {
    let eventID: WorkflowEventID
    let commandID: WorkflowCommandID
    let from: WorkflowJobLifecycle
    let to: WorkflowJobLifecycle
    let attemptID: WorkflowAttemptID?

    init(
        eventID: WorkflowEventID,
        commandID: WorkflowCommandID,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle,
        attemptID: WorkflowAttemptID?
    ) throws {
        guard from.allowsTransition(to: to) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidLifecycleCommand
        }
        self.eventID = eventID
        self.commandID = commandID
        self.from = from
        self.to = to
        self.attemptID = attemptID
    }
}

enum WorkflowLeaseInspectionV4: Equatable, Sendable {
    case activelyOwned(leaseID: WorkflowLeaseIDV4?)
    case awaitingExpiry(leaseID: WorkflowLeaseIDV4, expiresAt: WorkflowWallClockInstantV4)
    case recoverableExpired(leaseID: WorkflowLeaseIDV4)
    case recoverableMissingOrReleased
    case idle(WorkflowJobLifecycle)
    case terminal(WorkflowJobLifecycle)
}

// MARK: - Pause/resume checkpoint contract

struct WorkflowMediaTimeV4: Codable, Equatable, Hashable, Sendable {
    let value: Int64
    let timescale: Int32

    init(value: Int64, timescale: Int32) throws {
        guard timescale > 0, timescale <= 1_000_000_000 else {
            throw WorkflowDurableCoordinatorErrorV4.invalidMediaTime
        }
        self.value = value
        self.timescale = timescale
    }
}

enum WorkflowCheckpointTrackKindV4:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case video
    case audio
    case subtitle
    case caption
    case chapter
    case timecode
    case timedMetadata = "timed_metadata"
    case auxiliary
}

struct WorkflowTrackProgressV4: Codable, Equatable, Hashable, Sendable {
    let trackID: String
    let kind: WorkflowCheckpointTrackKindV4
    let nextInputSampleIndex: UInt64
    let nextOutputSampleIndex: UInt64
    let lastInputTime: WorkflowMediaTimeV4?
    let lastOutputTime: WorkflowMediaTimeV4?
    let isComplete: Bool

    init(
        trackID: String,
        kind: WorkflowCheckpointTrackKindV4,
        nextInputSampleIndex: UInt64,
        nextOutputSampleIndex: UInt64,
        lastInputTime: WorkflowMediaTimeV4?,
        lastOutputTime: WorkflowMediaTimeV4?,
        isComplete: Bool
    ) throws {
        guard WorkflowV4Validation.isIdentifier(trackID) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidTrackID(trackID)
        }
        guard (nextInputSampleIndex == 0) == (lastInputTime == nil),
              (nextOutputSampleIndex == 0) == (lastOutputTime == nil) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidTrackProgress(trackID)
        }
        self.trackID = trackID
        self.kind = kind
        self.nextInputSampleIndex = nextInputSampleIndex
        self.nextOutputSampleIndex = nextOutputSampleIndex
        self.lastInputTime = lastInputTime
        self.lastOutputTime = lastOutputTime
        self.isComplete = isComplete
    }
}

enum WorkflowCheckpointArtifactKindV4:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case segment
    case temporalHistory = "temporal_history"
    case measurementHysteresis = "measurement_hysteresis"
    case trackState = "track_state"
}

struct WorkflowCheckpointArtifactV4: Codable, Equatable, Hashable, Sendable {
    let artifactID: WorkflowArtifactIDV4
    let kind: WorkflowCheckpointArtifactKindV4
    let relativePath: String
    let byteCount: UInt64
    let sha256: WorkflowCheckpointArtifactHashV4
    let reopenReceiptSHA256: WorkflowCheckpointArtifactHashV4

    init(
        artifactID: WorkflowArtifactIDV4,
        kind: WorkflowCheckpointArtifactKindV4,
        relativePath: String,
        byteCount: UInt64,
        sha256: WorkflowCheckpointArtifactHashV4,
        reopenReceiptSHA256: WorkflowCheckpointArtifactHashV4
    ) throws {
        guard WorkflowV4Validation.isSafeRelativePath(relativePath),
              byteCount > 0 else {
            throw WorkflowDurableCoordinatorErrorV4.invalidCheckpointArtifact(
                relativePath
            )
        }
        self.artifactID = artifactID
        self.kind = kind
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.reopenReceiptSHA256 = reopenReceiptSHA256
    }
}

struct WorkflowSegmentCheckpointV4: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt64
    let artifact: WorkflowCheckpointArtifactV4
    let startTime: WorkflowMediaTimeV4
    let endTimeExclusive: WorkflowMediaTimeV4
    let codecSettingsHash: WorkflowOutputContractID
    let isIndependentlyDecodable: Bool

    init(
        ordinal: UInt64,
        artifact: WorkflowCheckpointArtifactV4,
        startTime: WorkflowMediaTimeV4,
        endTimeExclusive: WorkflowMediaTimeV4,
        codecSettingsHash: WorkflowOutputContractID,
        isIndependentlyDecodable: Bool
    ) throws {
        guard artifact.kind == .segment,
              startTime.timescale == endTimeExclusive.timescale,
              startTime.value < endTimeExclusive.value,
              isIndependentlyDecodable else {
            throw WorkflowDurableCoordinatorErrorV4.invalidSegmentBoundary
        }
        self.ordinal = ordinal
        self.artifact = artifact
        self.startTime = startTime
        self.endTimeExclusive = endTimeExclusive
        self.codecSettingsHash = codecSettingsHash
        self.isIndependentlyDecodable = isIndependentlyDecodable
    }
}

struct WorkflowCheckpointCompatibilityBindingV4:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let jobBinding: WorkflowJobBinding
    let runtimeManifestID: WorkflowRuntimeManifestID
    let mediaContractID: WorkflowMediaContractID
    let sourceBookmark: WorkflowBookmarkReference
    let outputDirectoryBookmark: WorkflowBookmarkReference
    let sourceSnapshotIdentityID: WorkflowSourceIdentityID?

    init(
        specification: WorkflowJobSpecification,
        sourceSnapshotIdentityID: WorkflowSourceIdentityID? = nil
    ) {
        jobBinding = specification.binding
        runtimeManifestID = specification.runtimeBinding.runtimeManifestID
        mediaContractID = specification.runtimeBinding.mediaContractID
        sourceBookmark = specification.source.bookmark
        outputDirectoryBookmark = specification.output.directoryBookmark
        self.sourceSnapshotIdentityID = sourceSnapshotIdentityID
    }

    func compatibilityFailures(
        with specification: WorkflowJobSpecification,
        expectedSourceSnapshotIdentityID: WorkflowSourceIdentityID? = nil
    ) -> [WorkflowCheckpointIncompatibilityV4] {
        var failures: [WorkflowCheckpointIncompatibilityV4] = []
        if jobBinding != specification.binding { failures.append(.jobBinding) }
        if runtimeManifestID != specification.runtimeBinding.runtimeManifestID {
            failures.append(.runtimeManifest)
        }
        if mediaContractID != specification.runtimeBinding.mediaContractID {
            failures.append(.mediaContract)
        }
        if sourceBookmark != specification.source.bookmark {
            failures.append(.sourceBookmark)
        }
        if outputDirectoryBookmark != specification.output.directoryBookmark {
            failures.append(.outputBookmark)
        }
        if sourceSnapshotIdentityID != expectedSourceSnapshotIdentityID {
            failures.append(.sourceSnapshot)
        }
        return failures
    }
}

enum WorkflowCheckpointIncompatibilityV4:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    case jobBinding = "job_binding"
    case runtimeManifest = "runtime_manifest"
    case mediaContract = "media_contract"
    case sourceBookmark = "source_bookmark"
    case outputBookmark = "output_bookmark"
    case sourceSnapshot = "source_snapshot"
    case codecSettings = "codec_settings"
}

struct WorkflowCheckpointBodyV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 2

    let schemaVersion: UInt16
    let checkpointID: WorkflowCheckpointIDV4
    let ordinal: UInt64
    let previousCheckpointHash: WorkflowCheckpointDocumentHashV4?
    let compatibility: WorkflowCheckpointCompatibilityBindingV4
    let attemptID: WorkflowAttemptID
    let committedAt: WorkflowWallClockInstantV4
    let segments: [WorkflowSegmentCheckpointV4]
    let trackProgress: [WorkflowTrackProgressV4]
    let temporalHistory: WorkflowCheckpointArtifactV4
    let measurementHysteresis: WorkflowCheckpointArtifactV4
    let auxiliaryState: [WorkflowCheckpointArtifactV4]

    init(
        checkpointID: WorkflowCheckpointIDV4,
        ordinal: UInt64,
        previousCheckpointHash: WorkflowCheckpointDocumentHashV4?,
        compatibility: WorkflowCheckpointCompatibilityBindingV4,
        attemptID: WorkflowAttemptID,
        committedAt: WorkflowWallClockInstantV4,
        segments: [WorkflowSegmentCheckpointV4],
        trackProgress: [WorkflowTrackProgressV4],
        temporalHistory: WorkflowCheckpointArtifactV4,
        measurementHysteresis: WorkflowCheckpointArtifactV4,
        auxiliaryState: [WorkflowCheckpointArtifactV4]
    ) throws {
        for segment in segments {
            _ = try WorkflowCheckpointArtifactV4(
                artifactID: segment.artifact.artifactID,
                kind: segment.artifact.kind,
                relativePath: segment.artifact.relativePath,
                byteCount: segment.artifact.byteCount,
                sha256: segment.artifact.sha256,
                reopenReceiptSHA256: segment.artifact.reopenReceiptSHA256
            )
            _ = try WorkflowSegmentCheckpointV4(
                ordinal: segment.ordinal,
                artifact: segment.artifact,
                startTime: WorkflowMediaTimeV4(
                    value: segment.startTime.value,
                    timescale: segment.startTime.timescale
                ),
                endTimeExclusive: WorkflowMediaTimeV4(
                    value: segment.endTimeExclusive.value,
                    timescale: segment.endTimeExclusive.timescale
                ),
                codecSettingsHash: segment.codecSettingsHash,
                isIndependentlyDecodable: segment.isIndependentlyDecodable
            )
        }
        for progress in trackProgress {
            _ = try WorkflowTrackProgressV4(
                trackID: progress.trackID,
                kind: progress.kind,
                nextInputSampleIndex: progress.nextInputSampleIndex,
                nextOutputSampleIndex: progress.nextOutputSampleIndex,
                lastInputTime: try progress.lastInputTime.map {
                    try WorkflowMediaTimeV4(
                        value: $0.value,
                        timescale: $0.timescale
                    )
                },
                lastOutputTime: try progress.lastOutputTime.map {
                    try WorkflowMediaTimeV4(
                        value: $0.value,
                        timescale: $0.timescale
                    )
                },
                isComplete: progress.isComplete
            )
        }
        for artifact in [temporalHistory, measurementHysteresis] + auxiliaryState {
            _ = try WorkflowCheckpointArtifactV4(
                artifactID: artifact.artifactID,
                kind: artifact.kind,
                relativePath: artifact.relativePath,
                byteCount: artifact.byteCount,
                sha256: artifact.sha256,
                reopenReceiptSHA256: artifact.reopenReceiptSHA256
            )
        }
        guard (ordinal == 0) == (previousCheckpointHash == nil),
              segments.count == Int(ordinal) + 1,
              segments.enumerated().allSatisfy({
                  $0.element.ordinal == UInt64($0.offset)
              }),
              temporalHistory.kind == .temporalHistory,
              measurementHysteresis.kind == .measurementHysteresis else {
            throw WorkflowDurableCoordinatorErrorV4.invalidCheckpoint
        }
        for index in segments.indices.dropFirst() {
            let previous = segments[index - 1]
            let current = segments[index]
            guard previous.endTimeExclusive == current.startTime,
                  previous.codecSettingsHash == current.codecSettingsHash else {
                throw WorkflowDurableCoordinatorErrorV4.invalidCheckpoint
            }
        }
        let trackIDs = trackProgress.map(\.trackID)
        guard !trackProgress.isEmpty,
              Set(trackIDs).count == trackIDs.count,
              trackProgress.contains(where: { $0.kind == .video }) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidCheckpoint
        }
        let allArtifacts = segments.map(\.artifact)
            + [temporalHistory, measurementHysteresis]
            + auxiliaryState
        guard Set(allArtifacts.map(\.artifactID)).count == allArtifacts.count,
              Set(allArtifacts.map(\.relativePath)).count == allArtifacts.count,
              auxiliaryState.allSatisfy({ $0.kind == .trackState }) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidCheckpoint
        }

        schemaVersion = Self.currentSchemaVersion
        self.checkpointID = checkpointID
        self.ordinal = ordinal
        self.previousCheckpointHash = previousCheckpointHash
        self.compatibility = compatibility
        self.attemptID = attemptID
        self.committedAt = committedAt
        self.segments = segments
        self.trackProgress = trackProgress.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.trackID < $1.trackID
        }
        self.temporalHistory = temporalHistory
        self.measurementHysteresis = measurementHysteresis
        self.auxiliaryState = auxiliaryState.sorted {
            $0.artifactID < $1.artifactID
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case checkpointID
        case ordinal
        case previousCheckpointHash
        case compatibility
        case attemptID
        case committedAt
        case segments
        case trackProgress
        case temporalHistory
        case measurementHysteresis
        case auxiliaryState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw WorkflowDurableCoordinatorErrorV4.unsupportedSchemaVersion(
                type: "WorkflowCheckpointBodyV4",
                actual: version,
                current: Self.currentSchemaVersion
            )
        }
        try self.init(
            checkpointID: container.decode(
                WorkflowCheckpointIDV4.self,
                forKey: .checkpointID
            ),
            ordinal: container.decode(UInt64.self, forKey: .ordinal),
            previousCheckpointHash: container.decodeIfPresent(
                WorkflowCheckpointDocumentHashV4.self,
                forKey: .previousCheckpointHash
            ),
            compatibility: container.decode(
                WorkflowCheckpointCompatibilityBindingV4.self,
                forKey: .compatibility
            ),
            attemptID: container.decode(WorkflowAttemptID.self, forKey: .attemptID),
            committedAt: container.decode(
                WorkflowWallClockInstantV4.self,
                forKey: .committedAt
            ),
            segments: container.decode(
                [WorkflowSegmentCheckpointV4].self,
                forKey: .segments
            ),
            trackProgress: container.decode(
                [WorkflowTrackProgressV4].self,
                forKey: .trackProgress
            ),
            temporalHistory: container.decode(
                WorkflowCheckpointArtifactV4.self,
                forKey: .temporalHistory
            ),
            measurementHysteresis: container.decode(
                WorkflowCheckpointArtifactV4.self,
                forKey: .measurementHysteresis
            ),
            auxiliaryState: container.decode(
                [WorkflowCheckpointArtifactV4].self,
                forKey: .auxiliaryState
            )
        )
    }
}

struct WorkflowCheckpointDocumentV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 2

    let schemaVersion: UInt16
    let bodyHash: WorkflowCheckpointDocumentHashV4
    let body: WorkflowCheckpointBodyV4

    fileprivate init(
        bodyHash: WorkflowCheckpointDocumentHashV4,
        body: WorkflowCheckpointBodyV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }
}

/// Canonical v1 checkpoint envelope.  Segment and temporal artifact hashes,
/// compatibility bindings, and the predecessor hash are never rewritten by
/// this envelope-only migration.
struct WorkflowCheckpointDocumentV1:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let schemaVersionValue: UInt16 = 1

    let schemaVersion: UInt16
    let bodyHash: WorkflowCheckpointDocumentHashV4
    let body: WorkflowCheckpointBodyV4

    init(
        bodyHash: WorkflowCheckpointDocumentHashV4,
        body: WorkflowCheckpointBodyV4
    ) {
        schemaVersion = Self.schemaVersionValue
        self.bodyHash = bodyHash
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case bodyHash
        case body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.schemaVersionValue else {
            throw WorkflowDurableCoordinatorErrorV4.unsupportedSchemaVersion(
                type: "WorkflowCheckpointDocumentV1",
                actual: schemaVersion,
                current: Self.schemaVersionValue
            )
        }
        self.init(
            bodyHash: try container.decode(
                WorkflowCheckpointDocumentHashV4.self,
                forKey: .bodyHash
            ),
            body: try container.decode(
                WorkflowCheckpointBodyV4.self,
                forKey: .body
            )
        )
    }
}

struct WorkflowCheckpointDraftV4: Equatable, Hashable, Sendable {
    let checkpointID: WorkflowCheckpointIDV4
    let committedAt: WorkflowWallClockInstantV4
    let segments: [WorkflowSegmentCheckpointV4]
    let trackProgress: [WorkflowTrackProgressV4]
    let temporalHistory: WorkflowCheckpointArtifactV4
    let measurementHysteresis: WorkflowCheckpointArtifactV4
    let auxiliaryState: [WorkflowCheckpointArtifactV4]
    let sourceSnapshotIdentityID: WorkflowSourceIdentityID?

    init(
        checkpointID: WorkflowCheckpointIDV4,
        committedAt: WorkflowWallClockInstantV4,
        segments: [WorkflowSegmentCheckpointV4],
        trackProgress: [WorkflowTrackProgressV4],
        temporalHistory: WorkflowCheckpointArtifactV4,
        measurementHysteresis: WorkflowCheckpointArtifactV4,
        auxiliaryState: [WorkflowCheckpointArtifactV4],
        sourceSnapshotIdentityID: WorkflowSourceIdentityID? = nil
    ) {
        self.checkpointID = checkpointID
        self.committedAt = committedAt
        self.segments = segments
        self.trackProgress = trackProgress
        self.temporalHistory = temporalHistory
        self.measurementHysteresis = measurementHysteresis
        self.auxiliaryState = auxiliaryState
        self.sourceSnapshotIdentityID = sourceSnapshotIdentityID
    }
}

enum WorkflowCheckpointCommitDispositionV4: Equatable, Sendable {
    case committed
    case alreadyCommitted
}

struct WorkflowCheckpointCommitResultV4: Equatable, Sendable {
    let disposition: WorkflowCheckpointCommitDispositionV4
    let document: WorkflowCheckpointDocumentV4
}

// MARK: - Registered partial ownership

struct WorkflowFileIdentityV4: Codable, Equatable, Hashable, Sendable {
    let device: UInt64
    let fileID: UInt64
}

struct WorkflowOwnedPartialArtifactV4: Codable, Equatable, Hashable, Sendable {
    let artifactID: WorkflowArtifactIDV4
    let jobBinding: WorkflowJobBinding
    let runtimeManifestID: WorkflowRuntimeManifestID
    let outputBookmark: WorkflowBookmarkReference
    let fileName: String
    let fileIdentity: WorkflowFileIdentityV4
    let creatingLeaseID: WorkflowLeaseIDV4

    init(
        artifactID: WorkflowArtifactIDV4,
        specification: WorkflowJobSpecification,
        fileName: String,
        fileIdentity: WorkflowFileIdentityV4,
        creatingLeaseID: WorkflowLeaseIDV4
    ) throws {
        guard WorkflowV4Validation.isMirmirPartialFileName(fileName) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidPartialFileName(
                fileName
            )
        }
        self.artifactID = artifactID
        jobBinding = specification.binding
        runtimeManifestID = specification.runtimeBinding.runtimeManifestID
        outputBookmark = specification.output.directoryBookmark
        self.fileName = fileName
        self.fileIdentity = fileIdentity
        self.creatingLeaseID = creatingLeaseID
    }
}

enum WorkflowPartialRegistryEnvelopeSchemaV4 {
    static let legacy: UInt16 = 1
    static let current: UInt16 = 2
}

private struct WorkflowPartialRegistryDocumentV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        WorkflowPartialRegistryEnvelopeSchemaV4.current

    let schemaVersion: UInt16
    let jobBinding: WorkflowJobBinding
    let generation: UInt64
    let artifacts: [WorkflowOwnedPartialArtifactV4]

    init(
        jobBinding: WorkflowJobBinding,
        generation: UInt64,
        artifacts: [WorkflowOwnedPartialArtifactV4]
    ) throws {
        guard Set(artifacts.map(\.artifactID)).count == artifacts.count,
              Set(artifacts.map(\.fileName)).count == artifacts.count,
              artifacts.allSatisfy({ $0.jobBinding == jobBinding }) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidPartialRegistry
        }
        schemaVersion = Self.currentSchemaVersion
        self.jobBinding = jobBinding
        self.generation = generation
        self.artifacts = artifacts.sorted { $0.artifactID < $1.artifactID }
    }
}

private struct WorkflowPartialRegistryDocumentV1:
    Codable,
    Equatable,
    Sendable
{
    static let schemaVersionValue =
        WorkflowPartialRegistryEnvelopeSchemaV4.legacy

    let schemaVersion: UInt16
    let jobBinding: WorkflowJobBinding
    let generation: UInt64
    let artifacts: [WorkflowOwnedPartialArtifactV4]

    init(
        jobBinding: WorkflowJobBinding,
        generation: UInt64,
        artifacts: [WorkflowOwnedPartialArtifactV4]
    ) {
        schemaVersion = Self.schemaVersionValue
        self.jobBinding = jobBinding
        self.generation = generation
        self.artifacts = artifacts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case jobBinding
        case generation
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.schemaVersionValue else {
            throw WorkflowDurableCoordinatorErrorV4
                .unsupportedSchemaVersion(
                    type: "WorkflowPartialRegistryDocumentV1",
                    actual: schemaVersion,
                    current: WorkflowPartialRegistryDocumentV4
                        .currentSchemaVersion
                )
        }
        self.init(
            jobBinding: try container.decode(
                WorkflowJobBinding.self,
                forKey: .jobBinding
            ),
            generation: try container.decode(
                UInt64.self,
                forKey: .generation
            ),
            artifacts: try container.decode(
                [WorkflowOwnedPartialArtifactV4].self,
                forKey: .artifacts
            )
        )
    }
}

// MARK: - Coordinator errors

enum WorkflowDurableCoordinatorErrorV4: Error, Equatable, LocalizedError {
    case invalidLeaseInterval
    case clockOverflow
    case unsupportedSchemaVersion(type: String, actual: UInt16, current: UInt16)
    case invalidLeaseDocument
    case corruptLeaseDocument
    case invalidAcquisitionTransition
    case invalidLifecycleCommand
    case noClaimableJob(WorkflowJobID?)
    case leaseExpired(WorkflowLeaseIDV4)
    case leaseNotHeld(WorkflowLeaseIDV4)
    case leaseIdentityMismatch
    case activeLeaseMetadata(WorkflowLeaseIDV4, WorkflowWallClockInstantV4)
    case leaseGenerationExhausted
    case invalidMediaTime
    case invalidTrackID(String)
    case invalidTrackProgress(String)
    case invalidCheckpointArtifact(String)
    case invalidSegmentBoundary
    case invalidCheckpoint
    case corruptCheckpoint
    case checkpointNotAllowed(WorkflowJobLifecycle)
    case checkpointAttemptMismatch
    case checkpointOrdinalExhausted
    case checkpointConflict
    case checkpointIncompatible([WorkflowCheckpointIncompatibilityV4])
    case invalidPartialFileName(String)
    case invalidPartialRegistry
    case partialRegistryConflict
    case partialScopeMismatch
    case unsafePartialFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidLeaseInterval:
            "Workflow lease intervals must be between one nanosecond and 24 hours."
        case .clockOverflow:
            "Workflow clock arithmetic overflowed."
        case let .unsupportedSchemaVersion(type, actual, current):
            "Unsupported \(type) schema version \(actual); current is \(current)."
        case .invalidLeaseDocument:
            "The workflow lease document violates its canonical contract."
        case .corruptLeaseDocument:
            "The workflow lease document is noncanonical or has an invalid hash."
        case .invalidAcquisitionTransition:
            "The requested lease acquisition transition is invalid."
        case .invalidLifecycleCommand:
            "The requested workflow lifecycle command is invalid."
        case let .noClaimableJob(jobID):
            jobID.map { "Workflow job \($0) cannot currently be claimed." }
                ?? "No queued workflow job can currently be claimed."
        case let .leaseExpired(leaseID):
            "Workflow lease \(leaseID) expired before the operation."
        case let .leaseNotHeld(leaseID):
            "Workflow lease \(leaseID) is not held by this dispatcher."
        case .leaseIdentityMismatch:
            "The workflow claim does not match its durable lease identity."
        case let .activeLeaseMetadata(leaseID, expiresAt):
            "Workflow lease \(leaseID) remains active until \(expiresAt.nanosecondsSinceUnixEpoch)."
        case .leaseGenerationExhausted:
            "The workflow lease generation counter is exhausted."
        case .invalidMediaTime:
            "Checkpoint media time is invalid."
        case let .invalidTrackID(trackID):
            "Checkpoint track ID is invalid: \(trackID)"
        case let .invalidTrackProgress(trackID):
            "Checkpoint progress is inconsistent for track \(trackID)."
        case let .invalidCheckpointArtifact(path):
            "Checkpoint artifact path or size is invalid: \(path)"
        case .invalidSegmentBoundary:
            "Checkpoint segment is not an independently decodable positive boundary."
        case .invalidCheckpoint:
            "Checkpoint metadata violates the v4 pause/resume contract."
        case .corruptCheckpoint:
            "Checkpoint metadata is noncanonical or has an invalid hash."
        case let .checkpointNotAllowed(lifecycle):
            "A checkpoint cannot be committed while a job is \(lifecycle.rawValue)."
        case .checkpointAttemptMismatch:
            "Checkpoint attempt identity does not match the active worker attempt."
        case .checkpointOrdinalExhausted:
            "The checkpoint ordinal is exhausted."
        case .checkpointConflict:
            "A different checkpoint already occupies the requested ordinal."
        case let .checkpointIncompatible(failures):
            "Checkpoint compatibility failed: \(failures.map(\.rawValue).joined(separator: ","))."
        case let .invalidPartialFileName(name):
            "Partial output name is not owned by the Mirmir naming contract: \(name)"
        case .invalidPartialRegistry:
            "The registered partial artifact document is invalid."
        case .partialRegistryConflict:
            "A partial artifact ID or filename was reused with different ownership."
        case .partialScopeMismatch:
            "A partial artifact is outside its activated output bookmark scope."
        case let .unsafePartialFile(path):
            "Partial output is not a single-link regular file: \(path)"
        }
    }
}

// MARK: - Durable dispatcher and checkpoint store

actor WorkflowDurableCoordinatorV4 {
    fileprivate final class HeldLease: @unchecked Sendable {
        let operatingSystemLease: WorkflowExclusiveFileLease
        var document: WorkflowLeaseDocumentV4
        var lifecycle: WorkflowJobLifecycle

        init(
            operatingSystemLease: WorkflowExclusiveFileLease,
            document: WorkflowLeaseDocumentV4,
            lifecycle: WorkflowJobLifecycle
        ) {
            self.operatingSystemLease = operatingSystemLease
            self.document = document
            self.lifecycle = lifecycle
        }
    }

    let rootURL: URL

    private let fileSystem: any WorkflowDurableFileSystem
    private let journal: WorkflowEventJournal
    private let clock: any WorkflowWallClockV4
    private let codec = WorkflowCanonicalCodec()
    private var heldLeases: [WorkflowLeaseIDV4: HeldLease] = [:]

    init(
        rootURL: URL,
        fileSystem: (any WorkflowDurableFileSystem)? = nil,
        clock: any WorkflowWallClockV4 = WorkflowSystemWallClockV4()
    ) throws {
        let standardizedRoot = rootURL.standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedFileSystem = try fileSystem
            ?? WorkflowLocalDurableFileSystem(trustedRootURL: standardizedRoot)
        self.rootURL = standardizedRoot
        self.fileSystem = resolvedFileSystem
        self.clock = clock
        journal = try WorkflowEventJournal(
            rootURL: standardizedRoot,
            fileSystem: resolvedFileSystem
        )
    }

    func open() throws -> WorkflowJournalOpenResult {
        try journal.open()
    }

    func append(_ draft: WorkflowEventDraft) throws -> WorkflowJournalAppendResult {
        try journal.append(draft)
    }

    func acquire(
        _ request: WorkflowLeaseAcquisitionRequestV4
    ) throws -> WorkflowDispatchClaimV4 {
        if let held = heldLeases[request.leaseID] {
            return try claim(from: held, matching: request)
        }

        let now = clock.now()
        let opened = try journal.open()
        let candidateIDs: [WorkflowJobID]
        if let jobID = request.jobID {
            candidateIDs = [jobID]
        } else {
            candidateIDs = opened.state.queueOrder
        }

        for jobID in candidateIDs {
            guard let initialJob = opened.state.job(id: jobID) else { continue }
            let operatingSystemLease: WorkflowExclusiveFileLease
            do {
                operatingSystemLease = try journal.acquireJobLease(for: jobID)
            } catch WorkflowDurableFileSystemError.lockUnavailable {
                continue
            }

            do {
                let latestState = try journal.open().state
                guard let job = latestState.job(id: jobID) else {
                    operatingSystemLease.release()
                    continue
                }
                guard job.specification.binding == initialJob.specification.binding else {
                    throw WorkflowDurableCoordinatorErrorV4.leaseIdentityMismatch
                }

                let previous = try loadLeaseDocument(jobID: jobID)
                if let restored = try restoreExactClaimIfPossible(
                    request: request,
                    job: job,
                    previous: previous,
                    now: now,
                    operatingSystemLease: operatingSystemLease
                ) {
                    return restored
                }
                if let previous,
                   previous.body.status == .active,
                   now < previous.body.expiresAt {
                    operatingSystemLease.release()
                    if request.jobID != nil {
                        throw WorkflowDurableCoordinatorErrorV4.activeLeaseMetadata(
                            previous.body.leaseID,
                            previous.body.expiresAt
                        )
                    }
                    continue
                }
                guard job.lifecycle == request.expectedLifecycle else {
                    operatingSystemLease.release()
                    continue
                }

                let nextGeneration = try leaseGeneration(after: previous)
                let body = try WorkflowLeaseBodyV4(
                    generation: nextGeneration,
                    leaseID: request.leaseID,
                    workerID: request.workerID,
                    jobBinding: job.specification.binding,
                    acquisitionEventID: request.eventID,
                    acquisitionCommandID: request.commandID,
                    acquiredFrom: request.expectedLifecycle,
                    acquiredTo: request.targetLifecycle,
                    attemptID: request.attemptID,
                    acquiredAt: now,
                    lastHeartbeatAt: now,
                    expiresAt: try now.advanced(by: request.duration),
                    recoveredLeaseID:
                        previous?.body.status == .active
                            ? previous?.body.leaseID
                            : nil,
                    status: .active,
                    releasedAt: nil
                )
                let document = try makeLeaseDocument(body)
                try persistLeaseDocument(document, jobID: jobID)

                let draft = WorkflowEventDraft(
                    eventID: request.eventID,
                    commandID: request.commandID,
                    scope: .job(jobID),
                    jobBinding: job.specification.binding,
                    attemptID: request.attemptID,
                    event: .lifecycleTransition(
                        WorkflowLifecycleTransition(
                            from: request.expectedLifecycle,
                            to: request.targetLifecycle
                        )
                    )
                )
                let result = try journal.append(draft)
                guard let reducedJob = result.state.job(id: jobID),
                      reducedJob.lifecycle == request.targetLifecycle else {
                    throw WorkflowDurableCoordinatorErrorV4.leaseIdentityMismatch
                }
                let held = HeldLease(
                    operatingSystemLease: operatingSystemLease,
                    document: document,
                    lifecycle: reducedJob.lifecycle
                )
                heldLeases[request.leaseID] = held
                return publicClaim(from: held)
            } catch {
                operatingSystemLease.release()
                throw error
            }
        }
        throw WorkflowDurableCoordinatorErrorV4.noClaimableJob(request.jobID)
    }

    func heartbeat(
        _ heartbeat: WorkflowLeaseHeartbeatV4
    ) throws -> WorkflowDispatchClaimV4 {
        let held = try requireHeld(heartbeat.claim)
        let now = clock.now()
        guard now < held.document.body.expiresAt else {
            throw WorkflowDurableCoordinatorErrorV4.leaseExpired(
                heartbeat.claim.leaseID
            )
        }
        let current = held.document.body
        guard now >= current.lastHeartbeatAt else {
            throw WorkflowDurableCoordinatorErrorV4.invalidLeaseDocument
        }
        guard current.generation < UInt64.max else {
            throw WorkflowDurableCoordinatorErrorV4.leaseGenerationExhausted
        }
        let body = try WorkflowLeaseBodyV4(
            generation: current.generation + 1,
            leaseID: current.leaseID,
            workerID: current.workerID,
            jobBinding: current.jobBinding,
            acquisitionEventID: current.acquisitionEventID,
            acquisitionCommandID: current.acquisitionCommandID,
            acquiredFrom: current.acquiredFrom,
            acquiredTo: current.acquiredTo,
            attemptID: current.attemptID,
            acquiredAt: current.acquiredAt,
            lastHeartbeatAt: now,
            expiresAt: try now.advanced(by: heartbeat.interval),
            recoveredLeaseID: current.recoveredLeaseID,
            status: .active,
            releasedAt: nil
        )
        let document = try makeLeaseDocument(body)
        try persistLeaseDocument(document, jobID: current.jobBinding.jobID)
        held.document = document
        return publicClaim(from: held)
    }

    func currentClaim(
        for claim: WorkflowDispatchClaimV4
    ) throws -> WorkflowDispatchClaimV4 {
        publicClaim(from: try requireHeld(claim))
    }

    func transition(
        _ command: WorkflowLifecycleCommandV4,
        using claim: WorkflowDispatchClaimV4
    ) throws -> WorkflowJournalAppendResult {
        let draft = WorkflowEventDraft(
            eventID: command.eventID,
            commandID: command.commandID,
            scope: .job(claim.jobID),
            jobBinding: claim.jobBinding,
            attemptID: command.attemptID,
            event: .lifecycleTransition(
                WorkflowLifecycleTransition(from: command.from, to: command.to)
            )
        )

        guard let held = heldLeases[claim.leaseID] else {
            // A retry after a release is safe only when the command is already
            // present. The journal then verifies exact payload idempotency.
            let state = try journal.open().state
            guard state.appliedEvents.contains(where: {
                $0.commandID == command.commandID
            }) else {
                throw WorkflowDurableCoordinatorErrorV4.leaseNotHeld(
                    claim.leaseID
                )
            }
            return try journal.append(draft)
        }
        _ = try requireHeld(claim)
        let now = clock.now()
        guard now < held.document.body.expiresAt else {
            throw WorkflowDurableCoordinatorErrorV4.leaseExpired(claim.leaseID)
        }

        let result = try journal.append(draft)
        guard let job = result.state.job(id: claim.jobID),
              job.lifecycle == command.to else {
            throw WorkflowDurableCoordinatorErrorV4.leaseIdentityMismatch
        }
        held.lifecycle = command.to
        if command.to == .running, held.document.body.attemptID == nil {
            try updateAttemptID(command.attemptID, held: held)
        }
        if Self.releasesWorker(at: command.to) {
            try release(held: held, at: now)
            heldLeases.removeValue(forKey: claim.leaseID)
        }
        return result
    }

    func releaseWithoutTransition(
        _ claim: WorkflowDispatchClaimV4
    ) throws {
        let held = try requireHeld(claim)
        try release(held: held, at: clock.now())
        heldLeases.removeValue(forKey: claim.leaseID)
    }

    /// Fault-injection boundary used by forced-termination qualification. It
    /// models the kernel releasing process-owned `flock` descriptors while
    /// deliberately leaving canonical lease metadata untouched.
    func injectProcessTerminationAfterLeasePersistence() {
        for held in heldLeases.values {
            held.operatingSystemLease.release()
        }
        heldLeases.removeAll(keepingCapacity: false)
    }

    func inspectRecovery(
        jobID: WorkflowJobID
    ) throws -> WorkflowLeaseInspectionV4 {
        let state = try journal.open().state
        guard let job = state.job(id: jobID) else {
            throw WorkflowReducerError.jobNotFound(jobID)
        }
        if job.lifecycle.isTerminal { return .terminal(job.lifecycle) }

        let lease: WorkflowExclusiveFileLease
        do {
            lease = try journal.acquireJobLease(for: jobID)
        } catch WorkflowDurableFileSystemError.lockUnavailable {
            let persisted = try loadLeaseDocument(jobID: jobID)
            return .activelyOwned(leaseID: persisted?.body.leaseID)
        }
        defer { lease.release() }

        guard let persisted = try loadLeaseDocument(jobID: jobID),
              persisted.body.status == .active else {
            if job.lifecycle == .queued || job.lifecycle == .paused {
                return .idle(job.lifecycle)
            }
            return .recoverableMissingOrReleased
        }
        let now = clock.now()
        if now < persisted.body.expiresAt {
            return .awaitingExpiry(
                leaseID: persisted.body.leaseID,
                expiresAt: persisted.body.expiresAt
            )
        }
        if job.lifecycle == .queued || job.lifecycle == .paused {
            return .idle(job.lifecycle)
        }
        return .recoverableExpired(leaseID: persisted.body.leaseID)
    }

    func commitCheckpoint(
        _ draft: WorkflowCheckpointDraftV4,
        using claim: WorkflowDispatchClaimV4
    ) throws -> WorkflowCheckpointCommitResultV4 {
        let held = try requireHeld(claim)
        let now = clock.now()
        guard now < held.document.body.expiresAt else {
            throw WorkflowDurableCoordinatorErrorV4.leaseExpired(claim.leaseID)
        }
        guard held.lifecycle == .running || held.lifecycle == .pausing else {
            throw WorkflowDurableCoordinatorErrorV4.checkpointNotAllowed(
                held.lifecycle
            )
        }
        let state = try journal.open().state
        guard let job = state.job(id: claim.jobID) else {
            throw WorkflowReducerError.jobNotFound(claim.jobID)
        }
        guard let activeAttemptID = job.activeAttemptID,
              activeAttemptID == held.document.body.attemptID else {
            throw WorkflowDurableCoordinatorErrorV4.checkpointAttemptMismatch
        }

        let previous = try loadCheckpointDocument(jobID: claim.jobID)
        if let previous,
           previous.body.checkpointID == draft.checkpointID {
            guard previous.body.compatibility.sourceSnapshotIdentityID
                    == draft.sourceSnapshotIdentityID,
                  previous.body.segments == draft.segments,
                  previous.body.trackProgress == draft.trackProgress.sorted(by: {
                      if $0.kind.rawValue != $1.kind.rawValue {
                          return $0.kind.rawValue < $1.kind.rawValue
                      }
                      return $0.trackID < $1.trackID
                  }),
                  previous.body.temporalHistory == draft.temporalHistory,
                  previous.body.measurementHysteresis
                    == draft.measurementHysteresis,
                  previous.body.auxiliaryState
                    == draft.auxiliaryState.sorted(by: {
                        $0.artifactID < $1.artifactID
                    }) else {
                throw WorkflowDurableCoordinatorErrorV4.checkpointConflict
            }
            return WorkflowCheckpointCommitResultV4(
                disposition: .alreadyCommitted,
                document: previous
            )
        }
        guard draft.committedAt <= now,
              previous?.body.committedAt ?? draft.committedAt
                <= draft.committedAt else {
            throw WorkflowDurableCoordinatorErrorV4.invalidCheckpoint
        }
        let ordinal: UInt64
        if let previous {
            guard previous.body.ordinal < UInt64.max else {
                throw WorkflowDurableCoordinatorErrorV4.checkpointOrdinalExhausted
            }
            ordinal = previous.body.ordinal + 1
        } else {
            ordinal = 0
        }
        let body = try WorkflowCheckpointBodyV4(
            checkpointID: draft.checkpointID,
            ordinal: ordinal,
            previousCheckpointHash: previous?.bodyHash,
            compatibility: WorkflowCheckpointCompatibilityBindingV4(
                specification: job.specification,
                sourceSnapshotIdentityID: draft.sourceSnapshotIdentityID
            ),
            attemptID: activeAttemptID,
            committedAt: draft.committedAt,
            segments: draft.segments,
            trackProgress: draft.trackProgress,
            temporalHistory: draft.temporalHistory,
            measurementHysteresis: draft.measurementHysteresis,
            auxiliaryState: draft.auxiliaryState
        )
        let document = try makeCheckpointDocument(body)
        let archiveURL = checkpointArchiveURL(
            jobID: claim.jobID,
            document: document
        )
        try fileSystem.ensureDirectory(checkpointDirectoryURL(jobID: claim.jobID))
        if try fileSystem.regularFileExists(archiveURL) {
            let existing = try decodeCheckpointDocument(
                fileSystem.readRegularFile(archiveURL, maximumBytes: 16 * 1_024 * 1_024)
            )
            guard existing == document else {
                throw WorkflowDurableCoordinatorErrorV4.checkpointConflict
            }
        } else {
            try fileSystem.writeNewAtomically(
                try codec.canonicalData(document),
                to: archiveURL
            )
        }

        let headURL = checkpointHeadURL(jobID: claim.jobID)
        let data = try codec.canonicalData(document)
        if try fileSystem.regularFileExists(headURL) {
            if try decodeCheckpointDocument(
                fileSystem.readRegularFile(headURL, maximumBytes: 16 * 1_024 * 1_024)
            ) == document {
                return WorkflowCheckpointCommitResultV4(
                    disposition: .alreadyCommitted,
                    document: document
                )
            }
            try fileSystem.replaceAtomically(data, at: headURL)
        } else {
            try fileSystem.writeNewAtomically(data, to: headURL)
        }
        return WorkflowCheckpointCommitResultV4(
            disposition: .committed,
            document: document
        )
    }

    func loadCompatibleCheckpoint(
        jobID: WorkflowJobID,
        expectedCodecSettingsHash: WorkflowOutputContractID,
        expectedSourceSnapshotIdentityID: WorkflowSourceIdentityID? = nil
    ) throws -> WorkflowCheckpointDocumentV4? {
        guard let document = try loadCheckpointDocument(jobID: jobID) else {
            return nil
        }
        let state = try journal.open().state
        guard let job = state.job(id: jobID) else {
            throw WorkflowReducerError.jobNotFound(jobID)
        }
        var failures = document.body.compatibility.compatibilityFailures(
            with: job.specification,
            expectedSourceSnapshotIdentityID:
                expectedSourceSnapshotIdentityID
        )
        if document.body.segments.contains(where: {
            $0.codecSettingsHash != expectedCodecSettingsHash
        }) {
            failures.append(.codecSettings)
        }
        guard failures.isEmpty else {
            throw WorkflowDurableCoordinatorErrorV4.checkpointIncompatible(
                failures
            )
        }
        return document
    }

    func registerPartialArtifact(
        artifactID: WorkflowArtifactIDV4,
        fileURL: URL,
        in scope: WorkflowActivatedOutputScopeV4,
        using claim: WorkflowDispatchClaimV4
    ) throws -> WorkflowOwnedPartialArtifactV4 {
        let held = try requireHeld(claim)
        guard clock.now() < held.document.body.expiresAt else {
            throw WorkflowDurableCoordinatorErrorV4.leaseExpired(claim.leaseID)
        }
        let state = try journal.open().state
        guard let job = state.job(id: claim.jobID) else {
            throw WorkflowReducerError.jobNotFound(claim.jobID)
        }
        guard scope.bookmark == job.specification.output.directoryBookmark,
              fileURL.deletingLastPathComponent().standardizedFileURL
                == scope.directoryURL.standardizedFileURL else {
            throw WorkflowDurableCoordinatorErrorV4.partialScopeMismatch
        }
        let identity = try WorkflowV4Validation.regularFileIdentity(at: fileURL)
        let artifact = try WorkflowOwnedPartialArtifactV4(
            artifactID: artifactID,
            specification: job.specification,
            fileName: fileURL.lastPathComponent,
            fileIdentity: identity,
            creatingLeaseID: claim.leaseID
        )
        let previous = try loadPartialRegistry(jobID: claim.jobID)
        if let exact = previous?.artifacts.first(where: {
            $0.artifactID == artifactID || $0.fileName == artifact.fileName
        }) {
            guard exact == artifact else {
                throw WorkflowDurableCoordinatorErrorV4.partialRegistryConflict
            }
            return exact
        }
        let generation: UInt64
        if let previous {
            guard previous.generation < UInt64.max else {
                throw WorkflowDurableCoordinatorErrorV4.leaseGenerationExhausted
            }
            generation = previous.generation + 1
        } else {
            generation = 1
        }
        let document = try WorkflowPartialRegistryDocumentV4(
            jobBinding: job.specification.binding,
            generation: generation,
            artifacts: (previous?.artifacts ?? []) + [artifact]
        )
        let data = try codec.canonicalData(document)
        let url = partialRegistryURL(jobID: claim.jobID)
        if try fileSystem.regularFileExists(url) {
            try fileSystem.replaceAtomically(data, at: url)
        } else {
            try fileSystem.writeNewAtomically(data, to: url)
        }
        return artifact
    }

    func registeredPartialArtifacts(
        jobID: WorkflowJobID
    ) throws -> [WorkflowOwnedPartialArtifactV4] {
        try loadPartialRegistry(jobID: jobID)?.artifacts ?? []
    }
}

private extension WorkflowDurableCoordinatorV4 {
    static func releasesWorker(at lifecycle: WorkflowJobLifecycle) -> Bool {
        lifecycle == .paused || lifecycle == .contained || lifecycle.isTerminal
    }

    func jobDirectoryURL(_ jobID: WorkflowJobID) -> URL {
        rootURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobID.rawValue, isDirectory: true)
    }

    func leaseURL(jobID: WorkflowJobID) -> URL {
        jobDirectoryURL(jobID).appendingPathComponent("lease-v4.json")
    }

    func checkpointDirectoryURL(jobID: WorkflowJobID) -> URL {
        jobDirectoryURL(jobID).appendingPathComponent(
            "checkpoints-v4",
            isDirectory: true
        )
    }

    func checkpointHeadURL(jobID: WorkflowJobID) -> URL {
        checkpointDirectoryURL(jobID: jobID).appendingPathComponent(
            "head-v1.json"
        )
    }

    func checkpointArchiveURL(
        jobID: WorkflowJobID,
        document: WorkflowCheckpointDocumentV4
    ) -> URL {
        checkpointDirectoryURL(jobID: jobID).appendingPathComponent(
            String(format: "checkpoint-%020llu-%@.json", document.body.ordinal, String(document.bodyHash.rawValue.prefix(16)))
        )
    }

    func partialRegistryURL(jobID: WorkflowJobID) -> URL {
        jobDirectoryURL(jobID).appendingPathComponent(
            "partial-artifacts-v4.json"
        )
    }

    func makeLeaseDocument(
        _ body: WorkflowLeaseBodyV4
    ) throws -> WorkflowLeaseDocumentV4 {
        let data = try codec.canonicalData(body)
        return WorkflowLeaseDocumentV4(
            bodyHash: try WorkflowLeaseDocumentHashV4(
                WorkflowV4Validation.domainSeparatedSHA256(
                    domain: "Mirmir.WorkflowLeaseV4\u{0}",
                    data: data
                )
            ),
            body: body
        )
    }

    func verifyLeaseDocument(_ document: WorkflowLeaseDocumentV4) throws {
        guard document.schemaVersion == WorkflowLeaseDocumentV4.currentSchemaVersion,
              try makeLeaseDocument(document.body) == document else {
            throw WorkflowDurableCoordinatorErrorV4.corruptLeaseDocument
        }
    }

    func loadLeaseDocument(
        jobID: WorkflowJobID
    ) throws -> WorkflowLeaseDocumentV4? {
        let url = leaseURL(jobID: jobID)
        guard try fileSystem.regularFileExists(url) else { return nil }
        do {
            let data = try fileSystem.readRegularFile(url, maximumBytes: 256 * 1_024)
            let schema = try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: data
            ).schemaVersion
            let document: WorkflowLeaseDocumentV4
            switch schema {
            case WorkflowLeaseDocumentV4.currentSchemaVersion:
                document = try codec.decodeCanonical(
                    WorkflowLeaseDocumentV4.self,
                    from: data
                )
            case WorkflowLeaseDocumentV1.schemaVersionValue:
                let legacy = try codec.decodeCanonical(
                    WorkflowLeaseDocumentV1.self,
                    from: data
                )
                let migrated = try makeLeaseDocument(legacy.body)
                guard migrated.bodyHash == legacy.bodyHash else {
                    throw WorkflowDurableCoordinatorErrorV4
                        .corruptLeaseDocument
                }
                try verifyLeaseDocument(migrated)
                try fileSystem.replaceAtomically(
                    codec.canonicalData(migrated),
                    at: url
                )
                document = migrated
            default:
                throw WorkflowDurableCoordinatorErrorV4
                    .unsupportedSchemaVersion(
                        type: "WorkflowLeaseDocumentV4",
                        actual: schema,
                        current: WorkflowLeaseDocumentV4
                            .currentSchemaVersion
                    )
            }
            try verifyLeaseDocument(document)
            return document
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            throw error
        } catch {
            throw WorkflowDurableCoordinatorErrorV4.corruptLeaseDocument
        }
    }

    func persistLeaseDocument(
        _ document: WorkflowLeaseDocumentV4,
        jobID: WorkflowJobID
    ) throws {
        try verifyLeaseDocument(document)
        let url = leaseURL(jobID: jobID)
        let data = try codec.canonicalData(document)
        if try fileSystem.regularFileExists(url) {
            try fileSystem.replaceAtomically(data, at: url)
        } else {
            try fileSystem.writeNewAtomically(data, to: url)
        }
    }

    func leaseGeneration(
        after document: WorkflowLeaseDocumentV4?
    ) throws -> UInt64 {
        guard let document else { return 1 }
        guard document.body.generation < UInt64.max else {
            throw WorkflowDurableCoordinatorErrorV4.leaseGenerationExhausted
        }
        return document.body.generation + 1
    }

    func restoreExactClaimIfPossible(
        request: WorkflowLeaseAcquisitionRequestV4,
        job: WorkflowJobState,
        previous: WorkflowLeaseDocumentV4?,
        now: WorkflowWallClockInstantV4,
        operatingSystemLease: WorkflowExclusiveFileLease
    ) throws -> WorkflowDispatchClaimV4? {
        guard let previous,
              previous.body.status == .active,
              previous.body.leaseID == request.leaseID,
              previous.body.workerID == request.workerID,
              previous.body.acquisitionEventID == request.eventID,
              previous.body.acquisitionCommandID == request.commandID,
              previous.body.acquiredFrom == request.expectedLifecycle,
              previous.body.acquiredTo == request.targetLifecycle,
              previous.body.attemptID == request.attemptID,
              previous.body.jobBinding == job.specification.binding else {
            return nil
        }
        guard now < previous.body.expiresAt else {
            throw WorkflowDurableCoordinatorErrorV4.leaseExpired(
                previous.body.leaseID
            )
        }
        guard job.lifecycle == request.targetLifecycle else {
            return nil
        }
        let held = HeldLease(
            operatingSystemLease: operatingSystemLease,
            document: previous,
            lifecycle: job.lifecycle
        )
        heldLeases[request.leaseID] = held
        return publicClaim(from: held)
    }

    func claim(
        from held: HeldLease,
        matching request: WorkflowLeaseAcquisitionRequestV4
    ) throws -> WorkflowDispatchClaimV4 {
        let body = held.document.body
        guard body.leaseID == request.leaseID,
              body.workerID == request.workerID,
              body.acquisitionEventID == request.eventID,
              body.acquisitionCommandID == request.commandID,
              body.acquiredFrom == request.expectedLifecycle,
              body.acquiredTo == request.targetLifecycle,
              body.attemptID == request.attemptID,
              request.jobID == nil || request.jobID == body.jobBinding.jobID else {
            throw WorkflowDurableCoordinatorErrorV4.leaseIdentityMismatch
        }
        return publicClaim(from: held)
    }

    func publicClaim(from held: HeldLease) -> WorkflowDispatchClaimV4 {
        let body = held.document.body
        return WorkflowDispatchClaimV4(
            jobID: body.jobBinding.jobID,
            jobBinding: body.jobBinding,
            leaseID: body.leaseID,
            workerID: body.workerID,
            acquisitionCommandID: body.acquisitionCommandID,
            lifecycle: held.lifecycle,
            attemptID: body.attemptID,
            expiresAt: body.expiresAt,
            leaseGeneration: body.generation
        )
    }

    func requireHeld(_ claim: WorkflowDispatchClaimV4) throws -> HeldLease {
        guard let held = heldLeases[claim.leaseID] else {
            throw WorkflowDurableCoordinatorErrorV4.leaseNotHeld(claim.leaseID)
        }
        let body = held.document.body
        guard held.operatingSystemLease.isHeld else {
            throw WorkflowDurableCoordinatorErrorV4.leaseNotHeld(claim.leaseID)
        }
        guard body.status == .active,
              body.jobBinding == claim.jobBinding,
              body.workerID == claim.workerID,
              body.acquisitionCommandID == claim.acquisitionCommandID else {
            throw WorkflowDurableCoordinatorErrorV4.leaseIdentityMismatch
        }
        return held
    }

    func updateAttemptID(
        _ attemptID: WorkflowAttemptID?,
        held: HeldLease
    ) throws {
        guard let attemptID else {
            throw WorkflowDurableCoordinatorErrorV4.checkpointAttemptMismatch
        }
        let current = held.document.body
        guard current.generation < UInt64.max else {
            throw WorkflowDurableCoordinatorErrorV4.leaseGenerationExhausted
        }
        let body = try WorkflowLeaseBodyV4(
            generation: current.generation + 1,
            leaseID: current.leaseID,
            workerID: current.workerID,
            jobBinding: current.jobBinding,
            acquisitionEventID: current.acquisitionEventID,
            acquisitionCommandID: current.acquisitionCommandID,
            acquiredFrom: current.acquiredFrom,
            acquiredTo: current.acquiredTo,
            attemptID: attemptID,
            acquiredAt: current.acquiredAt,
            lastHeartbeatAt: current.lastHeartbeatAt,
            expiresAt: current.expiresAt,
            recoveredLeaseID: current.recoveredLeaseID,
            status: .active,
            releasedAt: nil
        )
        let document = try makeLeaseDocument(body)
        try persistLeaseDocument(document, jobID: current.jobBinding.jobID)
        held.document = document
    }

    func release(
        held: HeldLease,
        at now: WorkflowWallClockInstantV4
    ) throws {
        let current = held.document.body
        guard current.generation < UInt64.max else {
            throw WorkflowDurableCoordinatorErrorV4.leaseGenerationExhausted
        }
        let releasedAt = max(now, current.lastHeartbeatAt)
        let body = try WorkflowLeaseBodyV4(
            generation: current.generation + 1,
            leaseID: current.leaseID,
            workerID: current.workerID,
            jobBinding: current.jobBinding,
            acquisitionEventID: current.acquisitionEventID,
            acquisitionCommandID: current.acquisitionCommandID,
            acquiredFrom: current.acquiredFrom,
            acquiredTo: current.acquiredTo,
            attemptID: current.attemptID,
            acquiredAt: current.acquiredAt,
            lastHeartbeatAt: current.lastHeartbeatAt,
            expiresAt: current.expiresAt,
            recoveredLeaseID: current.recoveredLeaseID,
            status: .released,
            releasedAt: releasedAt
        )
        let document = try makeLeaseDocument(body)
        try persistLeaseDocument(document, jobID: current.jobBinding.jobID)
        held.document = document
        held.operatingSystemLease.release()
    }

    func makeCheckpointDocument(
        _ body: WorkflowCheckpointBodyV4
    ) throws -> WorkflowCheckpointDocumentV4 {
        let data = try codec.canonicalData(body)
        return WorkflowCheckpointDocumentV4(
            bodyHash: try WorkflowCheckpointDocumentHashV4(
                WorkflowV4Validation.domainSeparatedSHA256(
                    domain: "Mirmir.WorkflowCheckpointV4\u{0}",
                    data: data
                )
            ),
            body: body
        )
    }

    func decodeCheckpointDocument(
        _ data: Data
    ) throws -> WorkflowCheckpointDocumentV4 {
        try decodeCheckpointDocumentMigrating(data).document
    }

    struct CheckpointMigrationResult {
        let document: WorkflowCheckpointDocumentV4
        let migratedFromSchemaVersion: UInt16?
    }

    func decodeCheckpointDocumentMigrating(
        _ data: Data
    ) throws -> CheckpointMigrationResult {
        do {
            let schema = try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: data
            ).schemaVersion
            let document: WorkflowCheckpointDocumentV4
            let migratedFromSchemaVersion: UInt16?
            switch schema {
            case WorkflowCheckpointDocumentV4.currentSchemaVersion:
                document = try codec.decodeCanonical(
                    WorkflowCheckpointDocumentV4.self,
                    from: data
                )
                migratedFromSchemaVersion = nil
            case WorkflowCheckpointDocumentV1.schemaVersionValue:
                let legacy = try codec.decodeCanonical(
                    WorkflowCheckpointDocumentV1.self,
                    from: data
                )
                let migrated = try makeCheckpointDocument(legacy.body)
                guard migrated.bodyHash == legacy.bodyHash else {
                    throw WorkflowDurableCoordinatorErrorV4.corruptCheckpoint
                }
                document = migrated
                migratedFromSchemaVersion = legacy.schemaVersion
            default:
                throw WorkflowDurableCoordinatorErrorV4
                    .unsupportedSchemaVersion(
                        type: "WorkflowCheckpointDocumentV4",
                        actual: schema,
                        current: WorkflowCheckpointDocumentV4
                            .currentSchemaVersion
                    )
            }
            guard document.schemaVersion
                    == WorkflowCheckpointDocumentV4.currentSchemaVersion,
                  try makeCheckpointDocument(document.body) == document else {
                throw WorkflowDurableCoordinatorErrorV4.corruptCheckpoint
            }
            return CheckpointMigrationResult(
                document: document,
                migratedFromSchemaVersion: migratedFromSchemaVersion
            )
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            throw error
        } catch {
            throw WorkflowDurableCoordinatorErrorV4.corruptCheckpoint
        }
    }

    func loadCheckpointDocument(
        jobID: WorkflowJobID
    ) throws -> WorkflowCheckpointDocumentV4? {
        try fileSystem.ensureDirectory(checkpointDirectoryURL(jobID: jobID))
        let url = checkpointHeadURL(jobID: jobID)
        guard try fileSystem.regularFileExists(url) else { return nil }
        let decoded = try decodeCheckpointDocumentMigrating(
            fileSystem.readRegularFile(
                url,
                maximumBytes: 16 * 1_024 * 1_024
            )
        )
        if decoded.migratedFromSchemaVersion != nil {
            let data = try codec.canonicalData(decoded.document)
            let archiveURL = checkpointArchiveURL(
                jobID: jobID,
                document: decoded.document
            )
            if try fileSystem.regularFileExists(archiveURL) {
                try fileSystem.replaceAtomically(data, at: archiveURL)
            } else {
                try fileSystem.writeNewAtomically(data, to: archiveURL)
            }
            try fileSystem.replaceAtomically(data, at: url)
        }
        return decoded.document
    }

    func loadPartialRegistry(
        jobID: WorkflowJobID
    ) throws -> WorkflowPartialRegistryDocumentV4? {
        try fileSystem.ensureDirectory(jobDirectoryURL(jobID))
        let url = partialRegistryURL(jobID: jobID)
        guard try fileSystem.regularFileExists(url) else { return nil }
        do {
            let data = try fileSystem.readRegularFile(url, maximumBytes: 4 * 1_024 * 1_024)
            let schema = try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: data
            ).schemaVersion
            let document: WorkflowPartialRegistryDocumentV4
            let migrated: Bool
            switch schema {
            case WorkflowPartialRegistryDocumentV4.currentSchemaVersion:
                document = try codec.decodeCanonical(
                    WorkflowPartialRegistryDocumentV4.self,
                    from: data
                )
                migrated = false
            case WorkflowPartialRegistryDocumentV1.schemaVersionValue:
                let legacy = try codec.decodeCanonical(
                    WorkflowPartialRegistryDocumentV1.self,
                    from: data
                )
                document = try WorkflowPartialRegistryDocumentV4(
                    jobBinding: legacy.jobBinding,
                    generation: legacy.generation,
                    artifacts: legacy.artifacts
                )
                guard document.artifacts == legacy.artifacts else {
                    throw WorkflowDurableCoordinatorErrorV4
                        .invalidPartialRegistry
                }
                migrated = true
            default:
                throw WorkflowDurableCoordinatorErrorV4
                    .unsupportedSchemaVersion(
                        type: "WorkflowPartialRegistryDocumentV4",
                        actual: schema,
                        current: WorkflowPartialRegistryDocumentV4
                            .currentSchemaVersion
                    )
            }
            guard document.schemaVersion
                    == WorkflowPartialRegistryDocumentV4.currentSchemaVersion,
                  try WorkflowPartialRegistryDocumentV4(
                      jobBinding: document.jobBinding,
                      generation: document.generation,
                      artifacts: document.artifacts
                  ) == document else {
                throw WorkflowDurableCoordinatorErrorV4.invalidPartialRegistry
            }
            if migrated {
                try fileSystem.replaceAtomically(
                    codec.canonicalData(document),
                    at: url
                )
            }
            return document
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            throw error
        } catch {
            throw WorkflowDurableCoordinatorErrorV4.invalidPartialRegistry
        }
    }
}

enum WorkflowV4Validation {
    static func isIdentifier(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty,
              scalars.count <= 128,
              let first = scalars.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return scalars.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == "-" || $0 == "_" || $0 == "." || $0 == ":"
        }
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              !value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func isMirmirPartialFileName(_ value: String) -> Bool {
        guard !value.contains("/"),
              value.hasPrefix("."),
              value.contains("mirmir-"),
              value.contains(".partial"),
              value.utf8.count <= 255 else {
            return false
        }
        let scalars = value.unicodeScalars
        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    static func regularFileIdentity(at url: URL) throws -> WorkflowFileIdentityV4 {
        var metadata = stat()
        guard url.isFileURL,
              lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw WorkflowDurableCoordinatorErrorV4.unsafePartialFile(url.path)
        }
        return WorkflowFileIdentityV4(
            device: UInt64(metadata.st_dev),
            fileID: UInt64(metadata.st_ino)
        )
    }

    static func domainSeparatedSHA256(domain: String, data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(domain.utf8))
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48 ... 57, 65 ... 90, 97 ... 122:
            true
        default:
            false
        }
    }
}
