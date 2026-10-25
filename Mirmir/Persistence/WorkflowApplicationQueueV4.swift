import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation

// MARK: - Prepared-plan authority

enum WorkflowApplicationRequestDocumentDigestPurposeV4:
    WorkflowDigestPurpose
{}

enum WorkflowApplicationPriorityDocumentDigestPurposeV4:
    WorkflowDigestPurpose
{}

enum WorkflowApplicationPublicationIntentDigestPurposeV4:
    WorkflowDigestPurpose
{}

enum WorkflowApplicationPublicationStageDigestPurposeV4:
    WorkflowDigestPurpose
{}

enum WorkflowApplicationPublicationReceiptDigestPurposeV4:
    WorkflowDigestPurpose
{}

typealias WorkflowApplicationRequestDocumentHashV4 =
    WorkflowDigest<WorkflowApplicationRequestDocumentDigestPurposeV4>
typealias WorkflowApplicationPriorityDocumentHashV4 =
    WorkflowDigest<WorkflowApplicationPriorityDocumentDigestPurposeV4>
typealias WorkflowApplicationPublicationIntentHashV4 =
    WorkflowDigest<WorkflowApplicationPublicationIntentDigestPurposeV4>
typealias WorkflowApplicationPublicationStageHashV4 =
    WorkflowDigest<WorkflowApplicationPublicationStageDigestPurposeV4>
typealias WorkflowApplicationPublicationReceiptHashV4 =
    WorkflowDigest<WorkflowApplicationPublicationReceiptDigestPurposeV4>

enum WorkflowApplicationRequestEnvelopeSchemaV4 {
    static let legacy: UInt16 = 1
    static let legacyWithPreparedPlanBinding: UInt16 = 2
    static let current: UInt16 = 3
}

enum WorkflowApplicationQueueErrorV4: Error, Equatable, LocalizedError {
    case unsafeApplicationSupportRoot(String)
    case invalidApplicationIdentifier(String)
    case fileSystemRootMismatch(expected: String, actual: String)
    case invalidTargetDimensions(width: Int, height: Int)
    case unresolvedBackend
    case preparedBackendMismatch(
        request: UpscaleBackendID,
        prepared: UpscaleBackendID
    )
    case preparedBindingHashMismatch
    case invalidOutputURL(String)
    case jobNotFound(WorkflowJobID)
    case requestDocumentMissing(WorkflowJobID)
    case requestDocumentCorrupt(WorkflowJobID)
    case requestDocumentUnsupportedSchema(
        jobID: WorkflowJobID,
        actual: UInt16,
        current: UInt16
    )
    case requestDocumentBindingMismatch(WorkflowJobID)
    case requestDocumentConflict(WorkflowJobID)
    case sourceSnapshotInvalid(WorkflowJobID)
    case legacySourceSnapshotRequiresReenqueue(
        jobID: WorkflowJobID,
        snapshotFileName: String
    )
    case sourceSnapshotFilesystemFailure(
        operation: String,
        path: String,
        code: Int32
    )
    case dispatchJobMismatch(expected: WorkflowJobID, actual: WorkflowJobID)
    case preparedPlanChanged(WorkflowJobID)
    case terminalCheckpointMissing(WorkflowJobID)
    case failedCheckpointResumeUnavailable(WorkflowJobID)
    case workingArtifactConflict(String)
    case unsafeWorkingArtifact(String)
    case priorityDocumentCorrupt
    case jobNotQueued(WorkflowJobID)
    case jobDeletionNotAllowed(
        jobID: WorkflowJobID,
        lifecycle: WorkflowJobLifecycle
    )
    case cacheClearBlocked([WorkflowJobID])
    case cacheCleanupFailed(String)
    case publicationDocumentCorrupt(WorkflowJobID)
    case publicationDocumentConflict(WorkflowJobID)
    case publicationBindingMismatch(WorkflowJobID)
    case publicationStageMissing(WorkflowJobID)
    case publicationStageConflict(String)
    case publicationDestinationConflict(String)
    case publicationVerificationInvalid
    case publicationFilesystemFailure(
        operation: String,
        path: String,
        code: Int32
    )
    case injectedPublicationTermination

    var errorDescription: String? {
        switch self {
        case .unsafeApplicationSupportRoot(let path):
            "The workflow Application Support root is unsafe: \(path)"
        case .invalidApplicationIdentifier(let value):
            "The workflow application identifier is invalid: \(value)"
        case .fileSystemRootMismatch(let expected, let actual):
            "The injected workflow filesystem root is \(actual), expected \(expected)."
        case .invalidTargetDimensions(let width, let height):
            "The queued target dimensions are invalid: \(width)x\(height)."
        case .unresolvedBackend:
            "A durable job requires a concrete, prepared upscale backend."
        case .preparedBackendMismatch(let request, let prepared):
            "The request backend \(request.rawValue) does not match the prepared backend \(prepared.rawValue)."
        case .preparedBindingHashMismatch:
            "The prepared-plan binding hash does not match its canonical constituents."
        case .invalidOutputURL(let path):
            "The queued output URL is invalid: \(path)"
        case .jobNotFound(let jobID):
            "The durable workflow job \(jobID) was not found."
        case .requestDocumentMissing(let jobID):
            "The durable request document for \(jobID) is missing."
        case .requestDocumentCorrupt(let jobID):
            "The durable request document for \(jobID) is noncanonical or hash-invalid."
        case let .requestDocumentUnsupportedSchema(jobID, actual, current):
            "The durable request document for \(jobID) uses unsupported schema \(actual); current is \(current)."
        case .requestDocumentBindingMismatch(let jobID):
            "The durable request document for \(jobID) does not match the journal binding."
        case .requestDocumentConflict(let jobID):
            "A different durable request document already exists for \(jobID)."
        case .sourceSnapshotInvalid(let jobID):
            "The private source snapshot for \(jobID) is missing, changed, or unsafe."
        case let .legacySourceSnapshotRequiresReenqueue(
            jobID,
            snapshotFileName
        ):
            "The verified durable job \(jobID) uses legacy source snapshot \(snapshotFileName), which does not authenticate the original source filename. Re-enqueue the original source as a new request; this job was failed before dispatch and none of its checkpoints will be reused."
        case let .sourceSnapshotFilesystemFailure(operation, path, code):
            "The private source snapshot operation \(operation) failed for \(path) with errno \(code)."
        case .dispatchJobMismatch(let expected, let actual):
            "The dispatcher selected \(actual), expected \(expected)."
        case .preparedPlanChanged(let jobID):
            "The revalidated prepared plan for \(jobID) no longer matches its durable binding."
        case .terminalCheckpointMissing(let jobID):
            "The durable job \(jobID) has no compatible terminal segment checkpoint."
        case .failedCheckpointResumeUnavailable(let jobID):
            "The failed durable job \(jobID) has no verified nonterminal checkpoint to resume."
        case .workingArtifactConflict(let path):
            "A durable working artifact already exists at \(path)."
        case .unsafeWorkingArtifact(let path):
            "A durable working artifact is unsafe: \(path)."
        case .priorityDocumentCorrupt:
            "The durable application queue priority document is noncanonical or hash-invalid."
        case .jobNotQueued(let jobID):
            "The durable workflow job \(jobID) is not currently queued."
        case let .jobDeletionNotAllowed(jobID, lifecycle):
            "The durable workflow job \(jobID) cannot be deleted while it is \(lifecycle.rawValue). Pause or cancel it first."
        case .cacheClearBlocked(let jobIDs):
            "The cache cannot be cleared while these jobs are active: "
                + jobIDs.map(\.rawValue).joined(separator: ", ")
                + ". Pause or cancel them first."
        case .cacheCleanupFailed(let path):
            "Mirmir recorded the job deletion but could not remove cached data at \(path). Retry Clear Cache after checking that the storage location is available."
        case .publicationDocumentCorrupt(let jobID):
            "The durable publication record for \(jobID) is noncanonical or hash-invalid."
        case .publicationDocumentConflict(let jobID):
            "A conflicting durable publication record already exists for \(jobID)."
        case .publicationBindingMismatch(let jobID):
            "The durable publication record for \(jobID) does not match its request and terminal checkpoint."
        case .publicationStageMissing(let jobID):
            "The verified publication stage for \(jobID) is missing."
        case .publicationStageConflict(let path):
            "The durable publication stage is unsafe or changed identity: \(path)."
        case .publicationDestinationConflict(let path):
            "The final output changed after publication intent was recorded: \(path)."
        case .publicationVerificationInvalid:
            "The final media migration verification is incomplete or inconsistent."
        case let .publicationFilesystemFailure(operation, path, code):
            "The durable publication operation \(operation) failed for \(path) with errno \(code)."
        case .injectedPublicationTermination:
            "A qualification fault terminated publication after the atomic rename."
        }
    }
}

enum WorkflowApplicationQueueMoveV4: Sendable {
    case earlier
    case later
}

private struct WorkflowApplicationPriorityEntryV4:
    Codable,
    Equatable,
    Sendable
{
    let jobID: WorkflowJobID
    let value: Int32
}

private struct WorkflowApplicationPriorityBodyV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let entries: [WorkflowApplicationPriorityEntryV4]

    init(entries: [WorkflowApplicationPriorityEntryV4]) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = entries
    }
}

private struct WorkflowApplicationPriorityDocumentV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationPriorityDocumentHashV4
    let body: WorkflowApplicationPriorityBodyV4

    init(
        bodyHash: WorkflowApplicationPriorityDocumentHashV4,
        body: WorkflowApplicationPriorityBodyV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }
}

// MARK: - Two-phase output publication

struct WorkflowApplicationMigrationVerificationV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1
    static let translatedMetadataSchemaVersion: UInt16 = 2

    let schemaVersion: UInt16
    let sourceGraphSHA256: ASHSHA256V4
    let trackPlanSHA256: ASHSHA256V4
    let blueprintSHA256: ASHSHA256V4
    let sourceAssetMetadataSHA256: ASHSHA256V4
    let aacGaplessMetadataTranslation: AACGaplessMetadataTranslationV4?
    let outputAssetMetadataSHA256: ASHSHA256V4
    let sourceChapterMetadataSHA256: ASHSHA256V4
    let outputChapterMetadataSHA256: ASHSHA256V4
    let outputGraphSHA256: ASHSHA256V4
    let semanticReportSHA256: ASHSHA256V4
    let trackResults: [AVFoundationTrackMigrationTrackResultV4]

    init(
        sourceGraphSHA256: ASHSHA256V4,
        trackPlanSHA256: ASHSHA256V4,
        blueprintSHA256: ASHSHA256V4,
        sourceAssetMetadataSHA256: ASHSHA256V4,
        outputAssetMetadataSHA256: ASHSHA256V4,
        sourceChapterMetadataSHA256: ASHSHA256V4,
        outputChapterMetadataSHA256: ASHSHA256V4,
        outputGraphSHA256: ASHSHA256V4,
        semanticReportSHA256: ASHSHA256V4,
        trackResults: [AVFoundationTrackMigrationTrackResultV4],
        aacGaplessMetadataTranslation: AACGaplessMetadataTranslationV4? = nil
    ) throws {
        let sorted = trackResults.sorted { $0.trackID < $1.trackID }
        guard !sorted.isEmpty,
              Set(sorted.map(\.trackID)).count == sorted.count,
              sorted.allSatisfy({ $0.migratedSampleCount >= 0 }) else {
            throw WorkflowApplicationQueueErrorV4
                .publicationVerificationInvalid
        }
        schemaVersion = aacGaplessMetadataTranslation == nil
            ? Self.currentSchemaVersion : Self.translatedMetadataSchemaVersion
        self.aacGaplessMetadataTranslation = aacGaplessMetadataTranslation
        self.sourceGraphSHA256 = sourceGraphSHA256
        self.trackPlanSHA256 = trackPlanSHA256
        self.blueprintSHA256 = blueprintSHA256
        self.sourceAssetMetadataSHA256 = sourceAssetMetadataSHA256
        self.outputAssetMetadataSHA256 = outputAssetMetadataSHA256
        self.sourceChapterMetadataSHA256 = sourceChapterMetadataSHA256
        self.outputChapterMetadataSHA256 = outputChapterMetadataSHA256
        self.outputGraphSHA256 = outputGraphSHA256
        self.semanticReportSHA256 = semanticReportSHA256
        self.trackResults = sorted
        guard try metadataIsConformant() else {
            throw WorkflowApplicationQueueErrorV4.publicationVerificationInvalid
        }
    }

    func metadataIsConformant() throws -> Bool {
        if schemaVersion == Self.currentSchemaVersion {
            return aacGaplessMetadataTranslation == nil
                && sourceAssetMetadataSHA256 == outputAssetMetadataSHA256
        }
        guard schemaVersion == Self.translatedMetadataSchemaVersion,
              let translation = aacGaplessMetadataTranslation else { return false }
        try translation.validate()
        return translation.identifiedPlan.planSHA256 == trackPlanSHA256
            && translation.identifiedPlan.plan.sourceGraphSHA256 == sourceGraphSHA256
            && translation.sourceAssetMetadataSHA256 == sourceAssetMetadataSHA256
            && translation.outputAssetMetadataSHA256 == outputAssetMetadataSHA256
            && trackResults.contains(where: { $0.trackID == translation.trackID && $0.action == .transcode })
    }

    init(_ result: AVFoundationTrackMigrationExecutionResultV4) throws {
        let outputGraphSHA256 = try result.outputGraph.canonicalSHA256
        let reportSHA256 = try result.verificationReport.canonicalSHA256
        guard result.verificationReport.isConformant,
              result.verificationReport.planSHA256 == result.planSHA256,
              result.verificationReport.outputGraphSHA256
                == outputGraphSHA256 else {
            throw WorkflowApplicationQueueErrorV4
                .publicationVerificationInvalid
        }
        try self.init(
            sourceGraphSHA256: result.sourceGraphSHA256,
            trackPlanSHA256: result.planSHA256,
            blueprintSHA256: result.blueprintSHA256,
            sourceAssetMetadataSHA256: result.sourceAssetMetadataSHA256,
            outputAssetMetadataSHA256: result.outputAssetMetadataSHA256,
            sourceChapterMetadataSHA256: result.sourceChapterMetadataSHA256,
            outputChapterMetadataSHA256: result.outputChapterMetadataSHA256,
            outputGraphSHA256: outputGraphSHA256,
            semanticReportSHA256: reportSHA256,
            trackResults: result.trackResults,
            aacGaplessMetadataTranslation: result.aacGaplessMetadataTranslation
        )
    }
}

struct WorkflowApplicationFinalizedOutputV4: Sendable {
    let destinationURL: URL
    let verification: WorkflowApplicationMigrationVerificationV4
}

private struct WorkflowApplicationPublicationFileV4:
    Codable,
    Equatable,
    Sendable
{
    let identity: WorkflowFileIdentityV4
    let byteCount: UInt64
    let sha256: ASHSHA256V4
}

private struct WorkflowApplicationPublicationIntentBodyV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let jobBinding: WorkflowJobBinding
    let checkpointID: WorkflowCheckpointIDV4
    let checkpointDocumentHash: WorkflowCheckpointDocumentHashV4
    let outputContractID: WorkflowOutputContractID
    let finalFileName: WorkflowOutputFileName
    let stagingFileName: String
    let migrationTemporaryFileName: String
    let overwriteExistingFile: Bool
    let originalDestination: WorkflowApplicationPublicationFileV4?
    let createdAt: WorkflowWallClockInstantV4

    init(
        jobBinding: WorkflowJobBinding,
        checkpointID: WorkflowCheckpointIDV4,
        checkpointDocumentHash: WorkflowCheckpointDocumentHashV4,
        outputContractID: WorkflowOutputContractID,
        finalFileName: WorkflowOutputFileName,
        stagingFileName: String,
        migrationTemporaryFileName: String,
        overwriteExistingFile: Bool,
        originalDestination: WorkflowApplicationPublicationFileV4?,
        createdAt: WorkflowWallClockInstantV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.jobBinding = jobBinding
        self.checkpointID = checkpointID
        self.checkpointDocumentHash = checkpointDocumentHash
        self.outputContractID = outputContractID
        self.finalFileName = finalFileName
        self.stagingFileName = stagingFileName
        self.migrationTemporaryFileName = migrationTemporaryFileName
        self.overwriteExistingFile = overwriteExistingFile
        self.originalDestination = originalDestination
        self.createdAt = createdAt
    }
}

struct WorkflowApplicationPublicationIntentV4: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationPublicationIntentHashV4
    fileprivate let body: WorkflowApplicationPublicationIntentBodyV4

    fileprivate init(
        bodyHash: WorkflowApplicationPublicationIntentHashV4,
        body: WorkflowApplicationPublicationIntentBodyV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }

    var jobID: WorkflowJobID { body.jobBinding.jobID }
    var checkpointID: WorkflowCheckpointIDV4 { body.checkpointID }
}

private struct WorkflowApplicationPublicationStageBodyV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let intentHash: WorkflowApplicationPublicationIntentHashV4
    let jobBinding: WorkflowJobBinding
    let stagedFile: WorkflowApplicationPublicationFileV4
    let migrationVerification: WorkflowApplicationMigrationVerificationV4
    let verifiedAt: WorkflowWallClockInstantV4

    init(
        intentHash: WorkflowApplicationPublicationIntentHashV4,
        jobBinding: WorkflowJobBinding,
        stagedFile: WorkflowApplicationPublicationFileV4,
        migrationVerification: WorkflowApplicationMigrationVerificationV4,
        verifiedAt: WorkflowWallClockInstantV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.intentHash = intentHash
        self.jobBinding = jobBinding
        self.stagedFile = stagedFile
        self.migrationVerification = migrationVerification
        self.verifiedAt = verifiedAt
    }
}

struct WorkflowApplicationPublicationStageV4: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationPublicationStageHashV4
    fileprivate let body: WorkflowApplicationPublicationStageBodyV4

    fileprivate init(
        bodyHash: WorkflowApplicationPublicationStageHashV4,
        body: WorkflowApplicationPublicationStageBodyV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }
}

enum WorkflowApplicationPublicationMethodV4:
    String,
    Codable,
    Equatable,
    Sendable
{
    case exclusiveRename = "exclusive_rename"
    case atomicSwap = "atomic_swap"
    case recoveredPublishedFile = "recovered_published_file"
}

private struct WorkflowApplicationPublicationReceiptBodyV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let stageHash: WorkflowApplicationPublicationStageHashV4
    let jobBinding: WorkflowJobBinding
    let finalFile: WorkflowApplicationPublicationFileV4
    let method: WorkflowApplicationPublicationMethodV4
    let displacedDestination: WorkflowApplicationPublicationFileV4?
    let publishedAt: WorkflowWallClockInstantV4

    init(
        stageHash: WorkflowApplicationPublicationStageHashV4,
        jobBinding: WorkflowJobBinding,
        finalFile: WorkflowApplicationPublicationFileV4,
        method: WorkflowApplicationPublicationMethodV4,
        displacedDestination: WorkflowApplicationPublicationFileV4?,
        publishedAt: WorkflowWallClockInstantV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.stageHash = stageHash
        self.jobBinding = jobBinding
        self.finalFile = finalFile
        self.method = method
        self.displacedDestination = displacedDestination
        self.publishedAt = publishedAt
    }
}

struct WorkflowApplicationPublicationReceiptV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationPublicationReceiptHashV4
    fileprivate let body: WorkflowApplicationPublicationReceiptBodyV4

    fileprivate init(
        bodyHash: WorkflowApplicationPublicationReceiptHashV4,
        body: WorkflowApplicationPublicationReceiptBodyV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }
}

struct WorkflowApplicationPublicationStateV4: Sendable {
    let intent: WorkflowApplicationPublicationIntentV4
    let stage: WorkflowApplicationPublicationStageV4?
    let receipt: WorkflowApplicationPublicationReceiptV4?

    var stageIsVerified: Bool { stage != nil }
    var isPublished: Bool { receipt != nil }
}

struct WorkflowApplicationPublicationRecoveryCandidateV4: Sendable {
    let jobID: WorkflowJobID
    let lifecycle: WorkflowJobLifecycle
    let hasIntent: Bool
}

private struct WorkflowApplicationPreparedBindingMaterialV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let sourceIdentityID: WorkflowSourceIdentityID
    let outputContractID: WorkflowOutputContractID
    let runtimeManifestID: WorkflowRuntimeManifestID
    let planID: WorkflowPlanID
    let workflowBackendID: WorkflowBackendID
    let backendRevisionID: WorkflowBackendRevisionID
    let mediaContractID: WorkflowMediaContractID
    let resolvedBackendID: UpscaleBackendID

    init(
        sourceIdentityID: WorkflowSourceIdentityID,
        outputContractID: WorkflowOutputContractID,
        runtimeManifestID: WorkflowRuntimeManifestID,
        planID: WorkflowPlanID,
        workflowBackendID: WorkflowBackendID,
        backendRevisionID: WorkflowBackendRevisionID,
        mediaContractID: WorkflowMediaContractID,
        resolvedBackendID: UpscaleBackendID
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.sourceIdentityID = sourceIdentityID
        self.outputContractID = outputContractID
        self.runtimeManifestID = runtimeManifestID
        self.planID = planID
        self.workflowBackendID = workflowBackendID
        self.backendRevisionID = backendRevisionID
        self.mediaContractID = mediaContractID
        self.resolvedBackendID = resolvedBackendID
    }
}

/// A prepared plan contributes its real, already-verified constituent IDs.
/// Only the aggregate runtime-binding ID is derived here, from canonical
/// domain-separated material. No plan, runtime, media, source, or output ID is
/// synthesized by the queue layer.
struct WorkflowVerifiedPreparedPlanBindingV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let sourceIdentityID: WorkflowSourceIdentityID
    let outputContractID: WorkflowOutputContractID
    let runtimeManifestID: WorkflowRuntimeManifestID
    let planID: WorkflowPlanID
    let workflowBackendID: WorkflowBackendID
    let backendRevisionID: WorkflowBackendRevisionID
    let mediaContractID: WorkflowMediaContractID
    let resolvedBackendID: UpscaleBackendID
    let runtimeBindingID: WorkflowRuntimeBindingID

    init(
        sourceIdentityID: WorkflowSourceIdentityID,
        outputContractID: WorkflowOutputContractID,
        runtimeManifestID: WorkflowRuntimeManifestID,
        planID: WorkflowPlanID,
        workflowBackendID: WorkflowBackendID,
        backendRevisionID: WorkflowBackendRevisionID,
        mediaContractID: WorkflowMediaContractID,
        resolvedBackendID: UpscaleBackendID,
        expectedRuntimeBindingID: WorkflowRuntimeBindingID? = nil
    ) throws {
        guard resolvedBackendID.isConcreteBackend else {
            throw WorkflowApplicationQueueErrorV4.unresolvedBackend
        }
        let material = WorkflowApplicationPreparedBindingMaterialV4(
            sourceIdentityID: sourceIdentityID,
            outputContractID: outputContractID,
            runtimeManifestID: runtimeManifestID,
            planID: planID,
            workflowBackendID: workflowBackendID,
            backendRevisionID: backendRevisionID,
            mediaContractID: mediaContractID,
            resolvedBackendID: resolvedBackendID
        )
        let computed = try Self.bindingID(for: material)
        if let expectedRuntimeBindingID,
           expectedRuntimeBindingID != computed {
            throw WorkflowApplicationQueueErrorV4
                .preparedBindingHashMismatch
        }

        schemaVersion = Self.currentSchemaVersion
        self.sourceIdentityID = sourceIdentityID
        self.outputContractID = outputContractID
        self.runtimeManifestID = runtimeManifestID
        self.planID = planID
        self.workflowBackendID = workflowBackendID
        self.backendRevisionID = backendRevisionID
        self.mediaContractID = mediaContractID
        self.resolvedBackendID = resolvedBackendID
        runtimeBindingID = computed
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceIdentityID
        case outputContractID
        case runtimeManifestID
        case planID
        case workflowBackendID
        case backendRevisionID
        case mediaContractID
        case resolvedBackendID
        case runtimeBindingID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowVerifiedPreparedPlanBindingV4",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        try self.init(
            sourceIdentityID: container.decode(
                WorkflowSourceIdentityID.self,
                forKey: .sourceIdentityID
            ),
            outputContractID: container.decode(
                WorkflowOutputContractID.self,
                forKey: .outputContractID
            ),
            runtimeManifestID: container.decode(
                WorkflowRuntimeManifestID.self,
                forKey: .runtimeManifestID
            ),
            planID: container.decode(
                WorkflowPlanID.self,
                forKey: .planID
            ),
            workflowBackendID: container.decode(
                WorkflowBackendID.self,
                forKey: .workflowBackendID
            ),
            backendRevisionID: container.decode(
                WorkflowBackendRevisionID.self,
                forKey: .backendRevisionID
            ),
            mediaContractID: container.decode(
                WorkflowMediaContractID.self,
                forKey: .mediaContractID
            ),
            resolvedBackendID: container.decode(
                UpscaleBackendID.self,
                forKey: .resolvedBackendID
            ),
            expectedRuntimeBindingID: container.decode(
                WorkflowRuntimeBindingID.self,
                forKey: .runtimeBindingID
            )
        )
    }

    fileprivate var runtimeBinding: WorkflowRuntimeBinding {
        WorkflowRuntimeBinding(
            id: runtimeBindingID,
            runtimeManifestID: runtimeManifestID,
            planID: planID,
            backendID: workflowBackendID,
            backendRevisionID: backendRevisionID,
            mediaContractID: mediaContractID
        )
    }

    fileprivate func revalidated() throws -> Self {
        try Self(
            sourceIdentityID: sourceIdentityID,
            outputContractID: outputContractID,
            runtimeManifestID: runtimeManifestID,
            planID: planID,
            workflowBackendID: workflowBackendID,
            backendRevisionID: backendRevisionID,
            mediaContractID: mediaContractID,
            resolvedBackendID: resolvedBackendID,
            expectedRuntimeBindingID: runtimeBindingID
        )
    }

    private static func bindingID(
        for material: WorkflowApplicationPreparedBindingMaterialV4
    ) throws -> WorkflowRuntimeBindingID {
        let codec = WorkflowCanonicalCodec()
        return try WorkflowRuntimeBindingID(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.PreparedBinding.v1\u{0}",
                data: codec.canonicalData(material)
            )
        )
    }
}

// MARK: - Canonical durable request

private struct WorkflowApplicationRequestIdentityMaterialV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4
    let outputFileName: WorkflowOutputFileName
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: OutputCodec
    let preserveAudio: Bool
    let overwriteExistingFile: Bool

    init(
        preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4,
        outputFileName: WorkflowOutputFileName,
        targetWidth: Int,
        targetHeight: Int,
        outputCodec: OutputCodec,
        preserveAudio: Bool,
        overwriteExistingFile: Bool
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.preparedPlanBinding = preparedPlanBinding
        self.outputFileName = outputFileName
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.outputCodec = outputCodec
        self.preserveAudio = preserveAudio
        self.overwriteExistingFile = overwriteExistingFile
    }
}

private struct WorkflowApplicationSourceSnapshotIdentityMaterialV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let byteCount: UInt64
    let sha256: ASHSHA256V4

    init(byteCount: UInt64, sha256: ASHSHA256V4) {
        schemaVersion = Self.currentSchemaVersion
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Canonical, full-file identity of the queue-owned source copy. Its durable
/// request also binds the relative path so bytes from another job namespace
/// cannot be substituted as authority.
struct WorkflowApplicationSourceSnapshotBindingV4:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let relativePath: String
    let byteCount: UInt64
    let sha256: ASHSHA256V4
    let identityID: WorkflowSourceIdentityID

    init(
        relativePath: String,
        byteCount: UInt64,
        sha256: ASHSHA256V4,
        expectedIdentityID: WorkflowSourceIdentityID? = nil
    ) throws {
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 1_024,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              byteCount > 0 else {
            throw WorkflowDomainValidationError.invalidIdentifier(relativePath)
        }
        let material = WorkflowApplicationSourceSnapshotIdentityMaterialV4(
            byteCount: byteCount,
            sha256: sha256
        )
        let computed = try WorkflowSourceIdentityID(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.SourceSnapshot.v1\u{0}",
                data: WorkflowCanonicalCodec().canonicalData(material)
            )
        )
        if let expectedIdentityID, expectedIdentityID != computed {
            throw WorkflowApplicationQueueErrorV4
                .preparedBindingHashMismatch
        }
        schemaVersion = Self.currentSchemaVersion
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        identityID = computed
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case relativePath
        case byteCount
        case sha256
        case identityID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowApplicationSourceSnapshotBindingV4",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        try self.init(
            relativePath: container.decode(String.self, forKey: .relativePath),
            byteCount: container.decode(UInt64.self, forKey: .byteCount),
            sha256: container.decode(ASHSHA256V4.self, forKey: .sha256),
            expectedIdentityID: container.decode(
                WorkflowSourceIdentityID.self,
                forKey: .identityID
            )
        )
    }
}

private struct WorkflowApplicationBookmarkAuthorizationMaterialV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let jobID: WorkflowJobID
    let requestID: WorkflowRequestID
    let runtimeBindingID: WorkflowRuntimeBindingID
    let role: WorkflowScopedResourceRoleV4

    init(
        jobID: WorkflowJobID,
        requestID: WorkflowRequestID,
        runtimeBindingID: WorkflowRuntimeBindingID,
        role: WorkflowScopedResourceRoleV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.jobID = jobID
        self.requestID = requestID
        self.runtimeBindingID = runtimeBindingID
        self.role = role
    }
}

private struct WorkflowApplicationRequestBodyV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 3

    let schemaVersion: UInt16
    let specification: WorkflowJobSpecification
    let cacheBookmark: WorkflowBookmarkReference
    let sourceSnapshot: WorkflowApplicationSourceSnapshotBindingV4
    /// The exact source basename used while preparing the filename-sensitive
    /// source/media/plan binding. `nil` is accepted only when atomically
    /// migrating a deployed legacy `source[.<ext>]` snapshot whose original
    /// basename was never persisted and therefore cannot be reconstructed.
    let canonicalSourceFileName: String?
    let preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: OutputCodec
    let preserveAudio: Bool
    let overwriteExistingFile: Bool

    init(
        specification: WorkflowJobSpecification,
        cacheBookmark: WorkflowBookmarkReference,
        sourceSnapshot: WorkflowApplicationSourceSnapshotBindingV4,
        canonicalSourceFileName: String?,
        preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4,
        targetWidth: Int,
        targetHeight: Int,
        outputCodec: OutputCodec,
        preserveAudio: Bool,
        overwriteExistingFile: Bool
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.specification = specification
        self.cacheBookmark = cacheBookmark
        self.sourceSnapshot = sourceSnapshot
        self.canonicalSourceFileName = canonicalSourceFileName
        self.preparedPlanBinding = preparedPlanBinding
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.outputCodec = outputCodec
        self.preserveAudio = preserveAudio
        self.overwriteExistingFile = overwriteExistingFile
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case specification
        case cacheBookmark
        case sourceSnapshot
        case canonicalSourceFileName
        case preparedPlanBinding
        case targetWidth
        case targetHeight
        case outputCodec
        case preserveAudio
        case overwriteExistingFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowApplicationRequestBodyV4",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        self.init(
            specification: try container.decode(
                WorkflowJobSpecification.self,
                forKey: .specification
            ),
            cacheBookmark: try container.decode(
                WorkflowBookmarkReference.self,
                forKey: .cacheBookmark
            ),
            sourceSnapshot: try container.decode(
                WorkflowApplicationSourceSnapshotBindingV4.self,
                forKey: .sourceSnapshot
            ),
            canonicalSourceFileName: try container.decodeIfPresent(
                String.self,
                forKey: .canonicalSourceFileName
            ),
            preparedPlanBinding: try container.decode(
                WorkflowVerifiedPreparedPlanBindingV4.self,
                forKey: .preparedPlanBinding
            ),
            targetWidth: try container.decode(Int.self, forKey: .targetWidth),
            targetHeight: try container.decode(Int.self, forKey: .targetHeight),
            outputCodec: try container.decode(
                OutputCodec.self,
                forKey: .outputCodec
            ),
            preserveAudio: try container.decode(
                Bool.self,
                forKey: .preserveAudio
            ),
            overwriteExistingFile: try container.decode(
                Bool.self,
                forKey: .overwriteExistingFile
            )
        )
    }
}

/// Deployed request-body schema used before the source snapshot preserved and
/// authenticated the filename that participated in deterministic planning.
/// This type exists only to verify old bytes before an atomic v3 migration.
private struct WorkflowApplicationRequestBodyV2:
    Codable,
    Equatable,
    Sendable
{
    static let schemaVersionValue: UInt16 = 2

    let schemaVersion: UInt16
    let specification: WorkflowJobSpecification
    let cacheBookmark: WorkflowBookmarkReference
    let sourceSnapshot: WorkflowApplicationSourceSnapshotBindingV4
    let preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: OutputCodec
    let preserveAudio: Bool
    let overwriteExistingFile: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case specification
        case cacheBookmark
        case sourceSnapshot
        case preparedPlanBinding
        case targetWidth
        case targetHeight
        case outputCodec
        case preserveAudio
        case overwriteExistingFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.schemaVersionValue else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowApplicationRequestBodyV2",
                actual: schemaVersion,
                current: Self.schemaVersionValue
            )
        }
        self.schemaVersion = schemaVersion
        specification = try container.decode(
            WorkflowJobSpecification.self,
            forKey: .specification
        )
        cacheBookmark = try container.decode(
            WorkflowBookmarkReference.self,
            forKey: .cacheBookmark
        )
        sourceSnapshot = try container.decode(
            WorkflowApplicationSourceSnapshotBindingV4.self,
            forKey: .sourceSnapshot
        )
        preparedPlanBinding = try container.decode(
            WorkflowVerifiedPreparedPlanBindingV4.self,
            forKey: .preparedPlanBinding
        )
        targetWidth = try container.decode(Int.self, forKey: .targetWidth)
        targetHeight = try container.decode(Int.self, forKey: .targetHeight)
        outputCodec = try container.decode(
            OutputCodec.self,
            forKey: .outputCodec
        )
        preserveAudio = try container.decode(Bool.self, forKey: .preserveAudio)
        overwriteExistingFile = try container.decode(
            Bool.self,
            forKey: .overwriteExistingFile
        )
    }
}

private struct WorkflowApplicationRequestDocumentV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        WorkflowApplicationRequestEnvelopeSchemaV4.current

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationRequestDocumentHashV4
    let body: WorkflowApplicationRequestBodyV4

    init(
        bodyHash: WorkflowApplicationRequestDocumentHashV4,
        body: WorkflowApplicationRequestBodyV4
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.bodyHash = bodyHash
        self.body = body
    }
}

/// Canonical deployed request envelopes accepted only as atomic migration
/// input. Their hashed bodies are revalidated before the v3 envelope replaces
/// them.
private struct WorkflowApplicationRequestDocumentV1:
    Codable,
    Equatable,
    Sendable
{
    static let schemaVersionValue =
        WorkflowApplicationRequestEnvelopeSchemaV4.legacy

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationRequestDocumentHashV4
    fileprivate let body: WorkflowApplicationRequestBodyV2

    fileprivate init(
        bodyHash: WorkflowApplicationRequestDocumentHashV4,
        body: WorkflowApplicationRequestBodyV2
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
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowApplicationRequestDocumentV1",
                actual: schemaVersion,
                current: Self.schemaVersionValue
            )
        }
        self.init(
            bodyHash: try container.decode(
                WorkflowApplicationRequestDocumentHashV4.self,
                forKey: .bodyHash
            ),
            body: try container.decode(
                WorkflowApplicationRequestBodyV2.self,
                forKey: .body
            )
        )
    }
}

private struct WorkflowApplicationRequestDocumentV2:
    Codable,
    Equatable,
    Sendable
{
    static let schemaVersionValue =
        WorkflowApplicationRequestEnvelopeSchemaV4
            .legacyWithPreparedPlanBinding

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationRequestDocumentHashV4
    fileprivate let body: WorkflowApplicationRequestBodyV2

    fileprivate init(
        bodyHash: WorkflowApplicationRequestDocumentHashV4,
        body: WorkflowApplicationRequestBodyV2
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
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowApplicationRequestDocumentV2",
                actual: schemaVersion,
                current: Self.schemaVersionValue
            )
        }
        self.init(
            bodyHash: try container.decode(
                WorkflowApplicationRequestDocumentHashV4.self,
                forKey: .bodyHash
            ),
            body: try container.decode(
                WorkflowApplicationRequestBodyV2.self,
                forKey: .body
            )
        )
    }
}

// MARK: - Immutable application presentation

enum WorkflowApplicationRequestRecordStatusV4:
    String,
    Codable,
    Equatable,
    Sendable
{
    case ready
    case missing
    case corrupt
    case bindingMismatch = "binding_mismatch"
    case legacySourceSnapshotRequiresReenqueue =
        "legacy_source_snapshot_requires_reenqueue"
}

struct WorkflowApplicationRequestSummaryV4:
    Codable,
    Equatable,
    Sendable
{
    let requestID: WorkflowRequestID
    let outputFileName: WorkflowOutputFileName
    let backendID: UpscaleBackendID
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: OutputCodec
    let preserveAudio: Bool
    let overwriteExistingFile: Bool
}

struct WorkflowApplicationQueueItemV4: Codable, Equatable, Sendable {
    let jobID: WorkflowJobID
    let lifecycle: WorkflowJobLifecycle
    let queueOrdinal: Int?
    let priority: Int32
    let binding: WorkflowJobBinding
    let requestRecordStatus: WorkflowApplicationRequestRecordStatusV4
    let request: WorkflowApplicationRequestSummaryV4?
}

struct WorkflowApplicationQueueSnapshotV4: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let generatedAt: WorkflowWallClockInstantV4
    let items: [WorkflowApplicationQueueItemV4]

    init(
        generatedAt: WorkflowWallClockInstantV4,
        items: [WorkflowApplicationQueueItemV4]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.items = items
    }
}

enum WorkflowCachedJobSelectionV4: String, Codable, Equatable, Sendable {
    case finished
    case unfinished
    case all
}

struct WorkflowCacheClearResultV4: Equatable, Sendable {
    let deletedJobCount: Int
    let deletedArtifactCount: Int
}

struct WorkflowApplicationLaunchSnapshotV4: Equatable, Sendable {
    let queue: WorkflowApplicationQueueSnapshotV4
    let recovery: WorkflowLaunchRecoverySnapshotV4
}

struct WorkflowApplicationEnqueueReceiptV4: Equatable, Sendable {
    let specification: WorkflowJobSpecification
    let priority: Int32
    let requestDocumentHash: WorkflowApplicationRequestDocumentHashV4
    let bookmarkSetHash: WorkflowBookmarkSetHashV4
    let journalReceipt: WorkflowAppliedEventReceipt
}

enum WorkflowApplicationActivationFailureV4: Equatable, Sendable {
    case jobNotFound
    case requestDocumentMissing
    case requestDocumentCorrupt
    case requestDocumentBindingMismatch
    case sourceSnapshotInvalid
    case legacySourceSnapshotRequiresReenqueue(snapshotFileName: String)
    case bookmarkBlocked([WorkflowBookmarkActivationFailureV4])
}

enum WorkflowApplicationActivationResultV4: Sendable {
    case active(WorkflowActivatedUpscaleRequestV4)
    case blocked(WorkflowApplicationActivationFailureV4)
}

/// Owns all three security-scope leases for exactly as long as the rebuilt
/// request and its cache capability are in use.
final class WorkflowActivatedUpscaleRequestV4: @unchecked Sendable {
    let specification: WorkflowJobSpecification
    let request: UpscaleRequest
    let cacheDirectoryURL: URL
    let preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4
    let sourceSnapshot: WorkflowApplicationSourceSnapshotBindingV4
    let bookmarkReceipts: [WorkflowBookmarkActivationReceiptV4]

    private let accessSet: WorkflowActivatedBookmarkAccessSetV4
    private let sourceSnapshotValidator: @Sendable () throws -> Void

    fileprivate init(
        specification: WorkflowJobSpecification,
        request: UpscaleRequest,
        cacheDirectoryURL: URL,
        preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4,
        sourceSnapshot: WorkflowApplicationSourceSnapshotBindingV4,
        accessSet: WorkflowActivatedBookmarkAccessSetV4,
        sourceSnapshotValidator: @escaping @Sendable () throws -> Void
    ) {
        self.specification = specification
        self.request = request
        self.cacheDirectoryURL = cacheDirectoryURL
        self.preparedPlanBinding = preparedPlanBinding
        self.sourceSnapshot = sourceSnapshot
        bookmarkReceipts = accessSet.receipts
        self.accessSet = accessSet
        self.sourceSnapshotValidator = sourceSnapshotValidator
    }

    func revalidateAll() throws {
        try accessSet.revalidateAll()
        try sourceSnapshotValidator()
    }

    func close() {
        accessSet.close()
    }

    deinit {
        close()
    }
}

// MARK: - Application bridge

actor WorkflowApplicationQueueV4 {
    typealias JobTokenFactory = @Sendable () -> UUID

    static let defaultMaximumConcurrentJobs = 1
    static let defaultLeaseDurationNanoseconds: UInt64 = 30_000_000_000

    let rootURL: URL
    let cacheDirectoryURL: URL

    private static let maximumRequestDocumentBytes = 1 * 1_024 * 1_024
    private static let maximumPriorityDocumentBytes = 4 * 1_024 * 1_024
    private static let maximumPublicationDocumentBytes = 16 * 1_024 * 1_024
    private static let maximumTargetDimension = 131_072
    private static let requestDocumentName = "request-v1.json"
    private static let priorityDocumentName = "application-priorities-v1.json"
    private static let priorityLockName = "application-priorities.lock"
    private static let publicationIntentName = "publication-intent-v1.json"
    private static let publicationStageName = "publication-stage-v1.json"
    private static let publicationReceiptName = "publication-receipt-v1.json"
    private static let publicationLockName = "publication.lock"
    private static let sourceSnapshotDirectoryName = "source-snapshot-v4"
    private static let sourceSnapshotReadSize = 1_048_576

    private let fileSystem: any WorkflowDurableFileSystem
    private let resolver: any WorkflowSecurityScopedBookmarkResolvingV4
    private let clock: any WorkflowWallClockV4
    private let tokenFactory: JobTokenFactory
    private let codec = WorkflowCanonicalCodec()
    private let coordinator: WorkflowDurableCoordinatorV4
    private let bookmarkStore: WorkflowSecurityScopedBookmarkStoreV4
    private let dispatcher: WorkflowQueueDispatcherV4
    private let recoveryPresenter: WorkflowLaunchRecoveryPresenterV4
    private let leaseDuration: WorkflowLeaseIntervalV4
    private var terminateAfterPublicationRename = false

    init(
        trustedRootURL: URL,
        workerID: WorkflowWorkerIDV4,
        maximumConcurrentJobs: Int = defaultMaximumConcurrentJobs,
        leaseDuration: WorkflowLeaseIntervalV4? = nil,
        fileSystem: (any WorkflowDurableFileSystem)? = nil,
        resolver: any WorkflowSecurityScopedBookmarkResolvingV4 =
            WorkflowFoundationSecurityScopedBookmarkResolverV4(),
        clock: any WorkflowWallClockV4 = WorkflowSystemWallClockV4(),
        tokenFactory: @escaping JobTokenFactory = { UUID() }
    ) throws {
        let root = try Self.prepareTrustedRoot(trustedRootURL)
        let durableFileSystem: any WorkflowDurableFileSystem
        if let fileSystem {
            let actual = fileSystem.trustedRootURL.standardizedFileURL
                .resolvingSymlinksInPath()
            guard actual == root else {
                throw WorkflowApplicationQueueErrorV4.fileSystemRootMismatch(
                    expected: root.path,
                    actual: actual.path
                )
            }
            durableFileSystem = fileSystem
        } else {
            durableFileSystem = try WorkflowLocalDurableFileSystem(
                trustedRootURL: root
            )
        }

        let cache = root.appendingPathComponent("cache-v4", isDirectory: true)
        try durableFileSystem.ensureDirectory(cache)
        let effectiveLeaseDuration: WorkflowLeaseIntervalV4
        if let leaseDuration {
            effectiveLeaseDuration = leaseDuration
        } else {
            effectiveLeaseDuration = try WorkflowLeaseIntervalV4(
                nanoseconds: Self.defaultLeaseDurationNanoseconds
            )
        }
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: root,
            fileSystem: durableFileSystem,
            clock: clock
        )
        let bookmarkStore = try WorkflowSecurityScopedBookmarkStoreV4(
            rootURL: root,
            fileSystem: durableFileSystem
        )
        let dispatcher = try WorkflowQueueDispatcherV4(
            coordinator: coordinator,
            rootURL: root,
            workerID: workerID,
            maximumConcurrentJobs: maximumConcurrentJobs,
            leaseDuration: effectiveLeaseDuration,
            fileSystem: durableFileSystem
        )
        let decisionStore = try WorkflowRecoveryDecisionStoreV4(
            rootURL: root,
            fileSystem: durableFileSystem
        )

        rootURL = root
        cacheDirectoryURL = cache
        self.fileSystem = durableFileSystem
        self.resolver = resolver
        self.clock = clock
        self.tokenFactory = tokenFactory
        self.coordinator = coordinator
        self.bookmarkStore = bookmarkStore
        self.dispatcher = dispatcher
        self.leaseDuration = effectiveLeaseDuration
        recoveryPresenter = WorkflowLaunchRecoveryPresenterV4(
            coordinator: coordinator,
            bookmarkStore: bookmarkStore,
            dispatcher: dispatcher,
            decisionStore: decisionStore,
            clock: clock
        )
    }

    static func live(
        applicationIdentifier: String,
        maximumConcurrentJobs: Int = defaultMaximumConcurrentJobs,
        resolver: any WorkflowSecurityScopedBookmarkResolvingV4 =
            WorkflowFoundationSecurityScopedBookmarkResolverV4(),
        clock: any WorkflowWallClockV4 = WorkflowSystemWallClockV4()
    ) throws -> WorkflowApplicationQueueV4 {
        guard WorkflowV4Validation.isIdentifier(applicationIdentifier),
              !applicationIdentifier.contains(":"),
              !applicationIdentifier.contains("/") else {
            throw WorkflowApplicationQueueErrorV4.invalidApplicationIdentifier(
                applicationIdentifier
            )
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let root = base
            .appendingPathComponent(applicationIdentifier, isDirectory: true)
            .appendingPathComponent("WorkflowV4", isDirectory: true)
        let workerID = try WorkflowWorkerIDV4(
            "application-worker-\(UUID().uuidString.lowercased())"
        )
        return try WorkflowApplicationQueueV4(
            trustedRootURL: root,
            workerID: workerID,
            maximumConcurrentJobs: maximumConcurrentJobs,
            resolver: resolver,
            clock: clock
        )
    }

    @discardableResult
    func enqueue(
        request: UpscaleRequest,
        preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4,
        priority: Int32 = 0
    ) async throws -> WorkflowApplicationEnqueueReceiptV4 {
        guard priority >= WorkflowQueuePriorityV4.minimum,
              priority <= WorkflowQueuePriorityV4.maximum else {
            throw WorkflowQueueDispatcherErrorV4.invalidPriority(priority)
        }
        let binding = try preparedPlanBinding.revalidated()
        try Self.validate(request: request, preparedBinding: binding)
        let outputFileName = try Self.outputFileName(for: request.outputURL)
        let token = tokenFactory().uuidString.lowercased()
        let jobID = try WorkflowJobID("job-\(token)")
        let requestID = try Self.requestID(
            request: request,
            outputFileName: outputFileName,
            binding: binding,
            codec: codec
        )
        let sourceBookmark = try Self.bookmarkReference(
            token: token,
            jobID: jobID,
            requestID: requestID,
            runtimeBindingID: binding.runtimeBindingID,
            role: .inputFile,
            codec: codec
        )
        let outputBookmark = try Self.bookmarkReference(
            token: token,
            jobID: jobID,
            requestID: requestID,
            runtimeBindingID: binding.runtimeBindingID,
            role: .outputDirectory,
            codec: codec
        )
        let cacheBookmark = try Self.bookmarkReference(
            token: token,
            jobID: jobID,
            requestID: requestID,
            runtimeBindingID: binding.runtimeBindingID,
            role: .cacheDirectory,
            codec: codec
        )
        let snapshot = try createApplicationSourceSnapshot(
            sourceURL: request.inputURL,
            jobID: jobID
        )
        do {
            let specification = WorkflowJobSpecification(
                jobID: jobID,
                requestID: requestID,
                source: WorkflowSourceSpecification(
                    identityID: binding.sourceIdentityID,
                    bookmark: sourceBookmark
                ),
                output: WorkflowOutputSpecification(
                    contractID: binding.outputContractID,
                    directoryBookmark: outputBookmark,
                    fileName: outputFileName
                ),
                runtimeBinding: binding.runtimeBinding
            )
            let body = WorkflowApplicationRequestBodyV4(
                specification: specification,
                cacheBookmark: cacheBookmark,
                sourceSnapshot: snapshot.binding,
                canonicalSourceFileName: snapshot.url.lastPathComponent,
                preparedPlanBinding: binding,
                targetWidth: request.targetWidth,
                targetHeight: request.targetHeight,
                outputCodec: request.outputCodec,
                preserveAudio: request.preserveAudio,
                overwriteExistingFile: request.overwriteExistingFile
            )
            let requestDocument = try makeRequestDocument(body)

            // Bookmark authority is durably registered before the enqueue
            // event is published. A failure at either earlier step leaves no
            // dispatchable job; replaying an exact document is idempotent.
            let bookmarkDocument = try await bookmarkStore.register(
                specification: specification,
                registrations: [
                    WorkflowBookmarkRegistrationV4(
                        role: .inputFile,
                        authorizationReference: sourceBookmark,
                        url: snapshot.url
                    ),
                    WorkflowBookmarkRegistrationV4(
                        role: .outputDirectory,
                        authorizationReference: outputBookmark,
                        url: request.outputURL.deletingLastPathComponent()
                    ),
                    WorkflowBookmarkRegistrationV4(
                        role: .cacheDirectory,
                        authorizationReference: cacheBookmark,
                        url: cacheDirectoryURL
                    ),
                ],
                resolver: resolver
            )
            try persistRequestDocument(requestDocument)
            // Priority is committed before the enqueue event. Therefore any
            // job visible in the journal already has its requested priority,
            // even if the process is killed at the next instruction. An entry
            // whose enqueue never becomes visible is pruned during launch.
            try persistPriority(jobID: jobID, value: priority)
            let append = try await coordinator.append(
                WorkflowEventDraft(
                    eventID: WorkflowEventID("enqueue-event-\(token)"),
                    commandID: WorkflowCommandID(
                        "enqueue-command-\(token)"
                    ),
                    scope: .job(jobID),
                    jobBinding: specification.binding,
                    attemptID: nil,
                    event: .jobEnqueued(specification)
                )
            )
            return WorkflowApplicationEnqueueReceiptV4(
                specification: specification,
                priority: priority,
                requestDocumentHash: requestDocument.bodyHash,
                bookmarkSetHash: bookmarkDocument.bodyHash,
                journalReceipt: append.receipt
            )
        } catch {
            // An append can throw after durable visibility. Retain the source
            // whenever durable state is uncertain; launch recovery will make
            // the terminal cleanup decision.
            let durableJobExists: Bool
            do {
                durableJobExists = try await coordinator.open().state.job(
                    id: jobID
                ) != nil
            } catch {
                // A failed replay cannot prove that the enqueue is absent.
                // Retaining private recovery authority is safer than
                // orphaning a possibly durable job.
                durableJobExists = true
            }
            if !durableJobExists {
                try? removeApplicationSourceSnapshot(
                    jobID: jobID,
                    binding: snapshot.binding
                )
            }
            throw error
        }
    }

    func queueSnapshot() async throws -> WorkflowApplicationQueueSnapshotV4 {
        let state = try await coordinator.open().state
        let priorities = try loadPriorities()
        let ordinals = Dictionary(
            uniqueKeysWithValues: state.queueOrder.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let orderedJobs = state.jobs.values.sorted { lhs, rhs in
            let left = ordinals[lhs.specification.jobID]
            let right = ordinals[rhs.specification.jobID]
            switch (left, right) {
            case (.some(let left), .some(let right)):
                let leftPriority = priorities[
                    lhs.specification.jobID,
                    default: 0
                ]
                let rightPriority = priorities[
                    rhs.specification.jobID,
                    default: 0
                ]
                if leftPriority != rightPriority {
                    return leftPriority > rightPriority
                }
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.specification.jobID < rhs.specification.jobID
            }
        }
        let items = orderedJobs.map { job in
            queueItem(
                job: job,
                queueOrdinal: ordinals[job.specification.jobID],
                priority: priorities[job.specification.jobID, default: 0]
            )
        }
        return WorkflowApplicationQueueSnapshotV4(
            generatedAt: clock.now(),
            items: items
        )
    }

    func deleteCachedJob(jobID: WorkflowJobID) async throws {
        let state = try await coordinator.open().state
        guard let job = state.job(id: jobID) else {
            throw WorkflowApplicationQueueErrorV4.jobNotFound(jobID)
        }
        guard Self.isCacheDeletionAllowed(job.lifecycle) else {
            throw WorkflowApplicationQueueErrorV4.jobDeletionNotAllowed(
                jobID: jobID,
                lifecycle: job.lifecycle
            )
        }

        let token = UUID().uuidString.lowercased()
        _ = try await coordinator.append(
            WorkflowEventDraft(
                eventID: try WorkflowEventID(
                    "cache-delete-event-\(token)"
                ),
                commandID: try WorkflowCommandID(
                    "cache-delete-command-\(token)"
                ),
                scope: .job(jobID),
                jobBinding: job.specification.binding,
                attemptID: nil,
                event: .jobDeleted
            )
        )

        do {
            try removeCachedJobDirectory(jobID: jobID)
        } catch {
            throw WorkflowApplicationQueueErrorV4.cacheCleanupFailed(
                cachedJobDirectoryURL(jobID: jobID).path
            )
        }
        let retained = Set(try await coordinator.open().state.jobs.keys)
        try pruneOrphanPriorities(retaining: retained)
    }

    func deleteCachedJobs(
        selection: WorkflowCachedJobSelectionV4
    ) async throws -> Int {
        let snapshot = try await queueSnapshot()
        let matching = snapshot.items.filter {
            Self.matchesCacheDeletionSelection(
                $0.lifecycle,
                selection: selection
            )
        }
        let blocked = matching.filter {
            !Self.isCacheDeletionAllowed($0.lifecycle)
        }.map(\.jobID)
        guard blocked.isEmpty else {
            throw WorkflowApplicationQueueErrorV4.cacheClearBlocked(blocked)
        }

        var deleted = 0
        for item in matching {
            try await deleteCachedJob(jobID: item.jobID)
            deleted += 1
        }
        return deleted
    }

    func clearApplicationCache() async throws -> WorkflowCacheClearResultV4 {
        let deletedJobs = try await deleteCachedJobs(selection: .all)
        let deletedArtifacts = try await clearOrphanCachedJobDirectories()
            + clearApplicationWorkingArtifacts()
        return WorkflowCacheClearResultV4(
            deletedJobCount: deletedJobs,
            deletedArtifactCount: deletedArtifacts
        )
    }

    func recoverAtLaunch(
        commandKey: WorkflowRecoveryCommandKeyV4,
        policy: WorkflowPartialScavengingPolicyV4 = .quarantineAllOwned
    ) async -> WorkflowLaunchRecoverySnapshotV4 {
        await recoveryPresenter.recoverAtLaunch(
            commandKey: commandKey,
            policy: policy,
            resolver: resolver
        )
    }

    func launchSnapshot(
        commandKey: WorkflowRecoveryCommandKeyV4,
        policy: WorkflowPartialScavengingPolicyV4 = .quarantineAllOwned
    ) async throws -> WorkflowApplicationLaunchSnapshotV4 {
        try scavengeAbandonedApplicationWorkingArtifacts()
        let recovery = await recoverAtLaunch(
            commandKey: commandKey,
            policy: policy
        )
        try pruneOrphanPriorities(
            retaining: Set(try await coordinator.open().state.jobs.keys)
        )
        let queue = try await queueSnapshot()
        return WorkflowApplicationLaunchSnapshotV4(
            queue: queue,
            recovery: recovery
        )
    }

    func activate(
        jobID: WorkflowJobID
    ) async -> WorkflowApplicationActivationResultV4 {
        let job: WorkflowJobState
        do {
            guard let found = try await coordinator.open().state.job(id: jobID) else {
                return .blocked(.jobNotFound)
            }
            job = found
        } catch {
            return .blocked(.requestDocumentCorrupt)
        }

        let document: WorkflowApplicationRequestDocumentV4
        do {
            document = try loadVerifiedRequestDocument(
                specification: job.specification
            )
        } catch WorkflowApplicationQueueErrorV4.requestDocumentMissing {
            return .blocked(.requestDocumentMissing)
        } catch WorkflowApplicationQueueErrorV4.requestDocumentBindingMismatch {
            return .blocked(.requestDocumentBindingMismatch)
        } catch {
            return .blocked(.requestDocumentCorrupt)
        }

        switch await bookmarkStore.activate(
            specification: job.specification,
            resolver: resolver
        ) {
        case .blocked(let failures):
            return .blocked(.bookmarkBlocked(failures))
        case .active(let accessSet):
            do {
                let input = try accessSet.url(for: .inputFile)
                let outputDirectory = try accessSet.url(for: .outputDirectory)
                let cache = try accessSet.url(for: .cacheDirectory)
                let output = try Self.outputURL(
                    directory: outputDirectory,
                    fileName: job.specification.output.fileName
                )
                let body = document.body
                let request = UpscaleRequest(
                    inputURL: input,
                    outputURL: output,
                    backendID: body.preparedPlanBinding.resolvedBackendID,
                    targetWidth: body.targetWidth,
                    targetHeight: body.targetHeight,
                    outputCodec: body.outputCodec,
                    preserveAudio: body.preserveAudio,
                    overwriteExistingFile: body.overwriteExistingFile
                )
                try accessSet.revalidateAll()
                try Self.verifyApplicationSourceSnapshot(
                    at: input,
                    trustedRootURL: rootURL,
                    jobID: jobID,
                    binding: body.sourceSnapshot
                )
                if Self.requiresLegacySourceSnapshotReenqueue(body) {
                    let snapshotFileName = input.lastPathComponent
                    accessSet.close()
                    return .blocked(
                        .legacySourceSnapshotRequiresReenqueue(
                            snapshotFileName: snapshotFileName
                        )
                    )
                }
                let snapshotBinding = body.sourceSnapshot
                let snapshotRoot = rootURL
                return .active(
                    WorkflowActivatedUpscaleRequestV4(
                        specification: job.specification,
                        request: request,
                        cacheDirectoryURL: cache,
                        preparedPlanBinding: body.preparedPlanBinding,
                        sourceSnapshot: snapshotBinding,
                        accessSet: accessSet,
                        sourceSnapshotValidator: {
                            try Self.verifyApplicationSourceSnapshot(
                                at: input,
                                trustedRootURL: snapshotRoot,
                                jobID: jobID,
                                binding: snapshotBinding
                            )
                        }
                    )
                )
            } catch WorkflowApplicationQueueErrorV4.sourceSnapshotInvalid {
                accessSet.close()
                return .blocked(.sourceSnapshotInvalid)
            } catch {
                accessSet.close()
                return .blocked(.requestDocumentBindingMismatch)
            }
        }
    }

    /// Internal visibility is intentional: qualification tests can corrupt the
    /// exact durable record without exposing its layout as product API.
    func requestDocumentURL(jobID: WorkflowJobID) -> URL {
        rootURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobID.rawValue, isDirectory: true)
            .appendingPathComponent("application-request-v4", isDirectory: true)
            .appendingPathComponent(Self.requestDocumentName)
    }
}

// MARK: - Shipping application execution bridge

private struct WorkflowApplicationOutputContractMaterialV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let ashPlanSHA256: ASHSHA256V4
    let trackPlanSHA256: ASHSHA256V4
    let encodedFormatDescriptor: MediaTrackFormatDescriptorV4
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: OutputCodec
    let preserveAudio: Bool

    init(
        preparedPlan: DeterministicV4PreparedAssetPlan,
        request: UpscaleRequest
    ) {
        schemaVersion = Self.currentSchemaVersion
        ashPlanSHA256 = preparedPlan.ashPlan.planSHA256
        trackPlanSHA256 = preparedPlan.trackPlan.planSHA256
        encodedFormatDescriptor = preparedPlan.encodedFormatDescriptor
        targetWidth = request.targetWidth
        targetHeight = request.targetHeight
        outputCodec = request.outputCodec
        preserveAudio = request.preserveAudio
    }

    init(ashPlanSHA256: ASHSHA256V4, trackPlanSHA256: ASHSHA256V4,
         encodedFormatDescriptor: MediaTrackFormatDescriptorV4, request: UpscaleRequest) {
        schemaVersion = Self.currentSchemaVersion
        self.ashPlanSHA256 = ashPlanSHA256
        self.trackPlanSHA256 = trackPlanSHA256
        self.encodedFormatDescriptor = encodedFormatDescriptor
        targetWidth = request.targetWidth
        targetHeight = request.targetHeight
        outputCodec = request.outputCodec
        preserveAudio = request.preserveAudio
    }
}

private struct WorkflowApplicationMediaContractMaterialV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let canonicalMediaSHA256: ASHSHA256V4
    let sourceGraphSHA256: ASHSHA256V4
    let trackPlanSHA256: ASHSHA256V4

    init(preparedPlan: DeterministicV4PreparedAssetPlan) throws {
        schemaVersion = Self.currentSchemaVersion
        canonicalMediaSHA256 = try preparedPlan.canonicalMedia.canonicalSHA256
        sourceGraphSHA256 = try preparedPlan.sourceGraph.canonicalSHA256
        trackPlanSHA256 = preparedPlan.trackPlan.planSHA256
    }
}

struct WorkflowApplicationBoundaryCheckpointV4: Sendable {
    let checkpoint: WorkflowCheckpointDocumentV4
    let segmentIdentity: AVFoundationSegmentIdentityV4
}

extension WorkflowApplicationQueueV4 {
    /// Qualification boundary representing kernel death after the output
    /// directory rename is durable but before the publication receipt exists.
    func injectProcessTerminationAfterApplicationPublicationRename() {
        terminateAfterPublicationRename = true
    }

    /// Qualification boundary representing kernel death while a durable job
    /// owns its dispatcher and coordinator lease descriptors. Canonical lease
    /// metadata remains on disk for the launch reconciler.
    func injectProcessTerminationAfterApplicationLeasePersistence() async {
        await dispatcher.injectProcessTerminationAfterLeasePersistence()
    }

    /// Converts only already-verified deterministic planning facts into the
    /// workflow identifier vocabulary. The queue does not invent a runtime,
    /// plan, media state, or backend choice.
    nonisolated static func preparedBinding(
        preparedPlan: DeterministicV4PreparedAssetPlan,
        request: UpscaleRequest,
        resolvedBackendID: UpscaleBackendID
    ) throws -> WorkflowVerifiedPreparedPlanBindingV4 {
        try preparedPlan.ashPlan.verify()
        try preparedPlan.trackPlan.verify()
        guard request.backendID == resolvedBackendID,
              resolvedBackendID.isConcreteBackend else {
            throw WorkflowApplicationQueueErrorV4.preparedBackendMismatch(
                request: request.backendID,
                prepared: resolvedBackendID
            )
        }
        let codec = WorkflowCanonicalCodec()
        let outputMaterial = WorkflowApplicationOutputContractMaterialV4(
            preparedPlan: preparedPlan,
            request: request
        )
        let mediaMaterial = try WorkflowApplicationMediaContractMaterialV4(
            preparedPlan: preparedPlan
        )
        let plan = preparedPlan.ashPlan.plan
        return try WorkflowVerifiedPreparedPlanBindingV4(
            sourceIdentityID: WorkflowSourceIdentityID(
                plan.mediaStateSHA256.rawValue
            ),
            outputContractID: WorkflowOutputContractID(
                WorkflowV4Validation.domainSeparatedSHA256(
                    domain: "Mirmir.WorkflowApplication.OutputContract.v1\u{0}",
                    data: codec.canonicalData(outputMaterial)
                )
            ),
            runtimeManifestID: WorkflowRuntimeManifestID(
                plan.runtimeManifestSHA256.rawValue
            ),
            planID: WorkflowPlanID(preparedPlan.ashPlan.planSHA256.rawValue),
            workflowBackendID: WorkflowBackendID(resolvedBackendID.rawValue),
            backendRevisionID: WorkflowBackendRevisionID(
                plan.runtimeProvenanceSHA256.rawValue
            ),
            mediaContractID: WorkflowMediaContractID(
                WorkflowV4Validation.domainSeparatedSHA256(
                    domain: "Mirmir.WorkflowApplication.MediaContract.v1\u{0}",
                    data: codec.canonicalData(mediaMaterial)
                )
            ),
            resolvedBackendID: resolvedBackendID
        )
    }

    func claimNextApplicationJob(
        cycleID: WorkflowDispatchCycleIDV4
    ) async throws -> WorkflowQueueDispatchResultV4 {
        if let incompatible = try await failVerifiedLegacySourceSnapshotJobs() {
            throw WorkflowApplicationQueueErrorV4
                .legacySourceSnapshotRequiresReenqueue(
                    jobID: incompatible.jobID,
                    snapshotFileName: incompatible.snapshotFileName
                )
        }
        let state = try await coordinator.open().state
        let persisted = try loadPriorities()
        let priorities = try state.queueOrder.map { jobID in
            try WorkflowQueuePriorityV4(
                jobID: jobID,
                value: persisted[jobID, default: 0]
            )
        }
        return try await dispatcher.claimNext(
            cycleID: cycleID,
            priorities: priorities
        )
    }

    private struct LegacySourceSnapshotReenqueueV4: Sendable {
        let jobID: WorkflowJobID
        let snapshotFileName: String
    }

    /// A deployed request that records only `source[.<ext>]` cannot prove the
    /// basename used by filename-sensitive deterministic planning. Verify its
    /// private bytes before recording the terminal disposition, then keep the
    /// snapshot for an explicit fresh enqueue. The transition is published
    /// before the dispatcher sees candidates, so this process never claims or
    /// resumes an incompatible job and no checkpoint can be reused.
    private func failVerifiedLegacySourceSnapshotJobs() async throws
        -> LegacySourceSnapshotReenqueueV4?
    {
        let state = try await coordinator.open().state
        var firstFailure: LegacySourceSnapshotReenqueueV4?
        for jobID in state.queueOrder {
            guard let job = state.job(id: jobID),
                  job.lifecycle == .queued,
                  let document = try? loadVerifiedRequestDocument(
                    specification: job.specification
                  ),
                  Self.requiresLegacySourceSnapshotReenqueue(document.body)
            else { continue }

            let activation = await activate(jobID: jobID)
            guard case let .blocked(
                .legacySourceSnapshotRequiresReenqueue(snapshotFileName)
            ) = activation else {
                // Bookmark or byte verification failures retain their
                // existing containment path and are never mislabeled as a
                // successful compatibility verification.
                continue
            }

            let current = try await coordinator.open().state
            guard let currentJob = current.job(id: jobID),
                  currentJob.lifecycle == .queued,
                  currentJob.specification == job.specification else {
                continue
            }
            let token = try Self.jobToken(from: jobID)
            _ = try await coordinator.append(
                WorkflowEventDraft(
                    eventID: try WorkflowEventID(
                        "legacy-source-reenqueue-event-\(token)"
                    ),
                    commandID: try WorkflowCommandID(
                        "legacy-source-reenqueue-command-\(token)"
                    ),
                    scope: .job(jobID),
                    jobBinding: currentJob.specification.binding,
                    attemptID: nil,
                    event: .lifecycleTransition(
                        WorkflowLifecycleTransition(
                            from: .queued,
                            to: .failed
                        )
                    )
                )
            )
            if firstFailure == nil {
                firstFailure = LegacySourceSnapshotReenqueueV4(
                    jobID: jobID,
                    snapshotFileName: snapshotFileName
                )
            }
        }
        return firstFailure
    }

    func setApplicationJobPriority(
        jobID: WorkflowJobID,
        value: Int32
    ) async throws {
        guard value >= WorkflowQueuePriorityV4.minimum,
              value <= WorkflowQueuePriorityV4.maximum else {
            throw WorkflowQueueDispatcherErrorV4.invalidPriority(value)
        }
        let state = try await coordinator.open().state
        guard state.job(id: jobID)?.lifecycle == .queued else {
            throw WorkflowApplicationQueueErrorV4.jobNotQueued(jobID)
        }
        try persistPriority(jobID: jobID, value: value)
    }

    func reorderApplicationQueue(
        _ orderedJobIDs: [WorkflowJobID]
    ) async throws {
        let state = try await coordinator.open().state
        guard Set(orderedJobIDs) == Set(state.queueOrder),
              Set(orderedJobIDs).count == orderedJobIDs.count else {
            throw WorkflowReducerError.queueMembershipMismatch
        }
        guard orderedJobIDs != state.queueOrder else { return }
        let token = tokenFactory().uuidString.lowercased()
        _ = try await coordinator.append(
            WorkflowEventDraft(
                eventID: try WorkflowEventID(
                    "application-reorder-event-\(token)"
                ),
                commandID: try WorkflowCommandID(
                    "application-reorder-command-\(token)"
                ),
                scope: .queue,
                jobBinding: nil,
                attemptID: nil,
                event: .queueReordered(orderedJobIDs)
            )
        )
    }

    func moveApplicationJob(
        jobID: WorkflowJobID,
        direction: WorkflowApplicationQueueMoveV4
    ) async throws {
        var order = try await coordinator.open().state.queueOrder
        guard let index = order.firstIndex(of: jobID) else {
            throw WorkflowApplicationQueueErrorV4.jobNotQueued(jobID)
        }
        let priorities = try loadPriorities()
        let priority = priorities[jobID, default: 0]
        let destination: Int?
        switch direction {
        case .earlier:
            destination = order[..<index].lastIndex {
                priorities[$0, default: 0] == priority
            }
        case .later:
            destination = order[order.index(after: index)...].firstIndex {
                priorities[$0, default: 0] == priority
            }
        }
        guard let destination else { return }
        order.swapAt(index, destination)
        try await reorderApplicationQueue(order)
    }

    func transitionApplicationJob(
        _ dispatch: WorkflowQueueDispatchReceiptV4,
        expected: WorkflowJobLifecycle,
        target: WorkflowJobLifecycle,
        commandKey: WorkflowRecoveryCommandKeyV4,
        stage: String,
        attemptID: WorkflowAttemptID?,
        releaseAfterTransition: Bool = false
    ) async throws -> WorkflowQueueTransitionReceiptV4 {
        try await dispatcher.transition(
            dispatch,
            expected: expected,
            target: target,
            commandKey: commandKey,
            stage: stage,
            attemptID: attemptID,
            releaseAfterTransition: releaseAfterTransition
        )
    }

    func requestApplicationPause(
        _ dispatch: WorkflowQueueDispatchReceiptV4,
        commandKey: WorkflowRecoveryCommandKeyV4
    ) async throws -> WorkflowQueueTransitionReceiptV4 {
        try await dispatcher.requestPause(dispatch, commandKey: commandKey)
    }

    func completeApplicationPause(
        _ dispatch: WorkflowQueueDispatchReceiptV4,
        commandKey: WorkflowRecoveryCommandKeyV4
    ) async throws -> WorkflowQueueTransitionReceiptV4 {
        try await dispatcher.completePause(dispatch, commandKey: commandKey)
    }

    func resumeApplicationJob(
        jobID: WorkflowJobID,
        commandKey: WorkflowRecoveryCommandKeyV4,
        attemptID: WorkflowAttemptID
    ) async throws -> WorkflowQueueDispatchReceiptV4 {
        let state = try await coordinator.open().state
        if state.job(id: jobID)?.lifecycle == .failed {
            guard let job = state.job(id: jobID) else {
                throw WorkflowApplicationQueueErrorV4.jobNotFound(jobID)
            }
            let document = try loadVerifiedRequestDocument(
                specification: job.specification
            )
            guard let checkpoint = try await coordinator
                .loadCompatibleCheckpoint(
                    jobID: jobID,
                    expectedCodecSettingsHash:
                        document.body.preparedPlanBinding.outputContractID,
                    expectedSourceSnapshotIdentityID:
                        document.body.sourceSnapshot.identityID
                ) else {
                throw WorkflowApplicationQueueErrorV4
                    .failedCheckpointResumeUnavailable(jobID)
            }
            let store = try WorkflowSegmentCheckpointStoreV4(rootURL: rootURL)
            let verification = try await store.verifyCheckpoint(checkpoint)
            let videoProgress = checkpoint.body.trackProgress.filter {
                $0.kind == .video && $0.nextOutputSampleIndex > 0
            }
            guard verification.lastCompletedInputOrdinal >= 0,
                  checkpoint.body.segments.last?.nextStartTime != nil,
                  videoProgress.count == 1,
                  !videoProgress[0].isComplete else {
                throw WorkflowApplicationQueueErrorV4
                    .failedCheckpointResumeUnavailable(jobID)
            }
            let ordinal = UInt64(checkpoint.body.segments.count)
            let workingURL = applicationWorkingDirectoryURL
                .appendingPathComponent(
                    String(
                        format: ".mirmir-%@-boundary-%020llu.partial.segment.mov",
                        jobID.rawValue,
                        ordinal
                    ),
                    isDirectory: false
                )
            if FileManager.default.fileExists(atPath: workingURL.path) {
                try removeApplicationWorkingArtifact(workingURL)
            }
            try await dispatcher.reopenFailedCheckpointForResume(
                jobID: jobID,
                commandKey: commandKey
            )
        }
        return try await dispatcher.resume(
            jobID: jobID,
            commandKey: commandKey,
            attemptID: attemptID
        )
    }

    @discardableResult
    func heartbeatApplicationJob(
        _ dispatch: WorkflowQueueDispatchReceiptV4
    ) async throws -> WorkflowDispatchClaimV4 {
        let current = try await dispatcher.refreshedDispatch(dispatch)
        return try await coordinator.heartbeat(WorkflowLeaseHeartbeatV4(
            claim: current.claim,
            interval: leaseDuration
        ))
    }

    func compatibleApplicationCheckpoint(
        jobID: WorkflowJobID,
        outputContractID: WorkflowOutputContractID,
        sourceSnapshotIdentityID: WorkflowSourceIdentityID? = nil
    ) async throws -> WorkflowCheckpointDocumentV4? {
        try await coordinator.loadCompatibleCheckpoint(
            jobID: jobID,
            expectedCodecSettingsHash: outputContractID,
            expectedSourceSnapshotIdentityID: sourceSnapshotIdentityID
        )
    }

    func applicationCheckpointURL(jobID: WorkflowJobID) async -> URL {
        await coordinator.checkpointHeadURLForDiagnostics(jobID: jobID)
    }

    func commitApplicationCheckpointBoundary(
        dispatch: WorkflowQueueDispatchReceiptV4,
        specification: WorkflowJobSpecification,
        segment: DeterministicV4MediaSegmentResultV4,
        outputContractID: WorkflowOutputContractID,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        trackProgress: [WorkflowTrackProgressV4],
        temporalCheckpoint: Data,
        sourceSnapshotIdentityID: WorkflowSourceIdentityID? = nil
    ) async throws -> WorkflowApplicationBoundaryCheckpointV4 {
        let current = try await dispatcher.refreshedDispatch(dispatch)
        guard current.claim.jobID == specification.jobID,
              current.claim.jobBinding == specification.binding else {
            throw WorkflowApplicationQueueErrorV4.dispatchJobMismatch(
                expected: specification.jobID,
                actual: current.claim.jobID
            )
        }
        let durableSnapshotIdentityID = try loadVerifiedRequestDocument(
            specification: specification
        ).body.sourceSnapshot.identityID
        guard sourceSnapshotIdentityID == nil
                || sourceSnapshotIdentityID == durableSnapshotIdentityID else {
            throw WorkflowDurableCoordinatorErrorV4
                .checkpointIncompatible([.sourceSnapshot])
        }
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: rootURL)
        let identity = try await AVFoundationSegmentProbeV4().probe(
            url: segment.segmentURL
        )
        let existingSegments = previousCheckpoint?.body.segments ?? []
        guard previousCheckpoint?.body.compatibility == nil
                || previousCheckpoint?.body.compatibility
                    == WorkflowCheckpointCompatibilityBindingV4(
                        specification: specification,
                        sourceSnapshotIdentityID: durableSnapshotIdentityID
                    ) else {
            throw WorkflowDurableCoordinatorErrorV4
                .checkpointIncompatible([.jobBinding])
        }
        let boundaryOrdinal = UInt64(existingSegments.count)
        let token = try Self.boundaryToken(
            jobID: specification.jobID,
            planID: specification.runtimeBinding.planID,
            outputContractID: outputContractID,
            segmentIdentity: identity,
            boundaryOrdinal: boundaryOrdinal
        )
        let publication = try await store.publishBoundary(
            WorkflowSegmentCheckpointPublicationRequestV4(
                checkpointID: try WorkflowCheckpointIDV4(
                    "checkpoint-boundary-\(token)"
                ),
                segmentArtifactID: try WorkflowArtifactIDV4(
                    "artifact-segment-\(token)"
                ),
                temporalArtifactID: try WorkflowArtifactIDV4(
                    "artifact-temporal-\(token)"
                ),
                measurementArtifactID: try WorkflowArtifactIDV4(
                    "artifact-measurement-\(token)"
                ),
                sourceSegmentURL: segment.segmentURL,
                existingSegments: existingSegments,
                startTime: segment.startTime,
                endTimeExclusive: segment.endTimeExclusive,
                nextStartTime: segment.nextStartTime,
                codecSettingsHash: outputContractID,
                trackProgress: trackProgress,
                committedAt: clock.now(),
                lastCompletedInputOrdinal:
                    segment.lastCompletedInputOrdinal,
                sourceSnapshotIdentityID: durableSnapshotIdentityID
            ),
            using: current.claim,
            temporalCheckpoint: temporalCheckpoint
        )
        let committed = try await coordinator.commitCheckpoint(
            publication.draft,
            using: current.claim
        )
        return WorkflowApplicationBoundaryCheckpointV4(
            checkpoint: committed.document,
            segmentIdentity: publication.segmentIdentity
        )
    }

    func verifyApplicationCheckpoint(
        _ checkpoint: WorkflowCheckpointDocumentV4
    ) async throws -> WorkflowSegmentCheckpointVerificationV4 {
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: rootURL)
        return try await store.verifyCheckpoint(checkpoint)
    }

    func applicationCheckpointResumePayload(
        _ checkpoint: WorkflowCheckpointDocumentV4
    ) async throws -> WorkflowSegmentCheckpointResumePayloadV4 {
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: rootURL)
        return try await store.loadResumePayload(checkpoint)
    }

    func applicationWorkingSegmentURL(
        jobID: WorkflowJobID,
        boundaryOrdinal: UInt64
    ) throws -> URL {
        let directory = applicationWorkingDirectoryURL
        try fileSystem.ensureDirectory(directory)
        let url = directory.appendingPathComponent(
            String(
                format: ".mirmir-%@-boundary-%020llu.partial.segment.mov",
                jobID.rawValue,
                boundaryOrdinal
            ),
            isDirectory: false
        )
        guard Self.isApplicationWorkingArtifactName(url.lastPathComponent) else {
            throw WorkflowApplicationQueueErrorV4
                .unsafeWorkingArtifact(url.path)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WorkflowApplicationQueueErrorV4
                .workingArtifactConflict(url.path)
        }
        return url
    }

    func applicationAssembledVideoURL(
        jobID: WorkflowJobID,
        checkpointID: WorkflowCheckpointIDV4
    ) throws -> URL {
        let directory = applicationWorkingDirectoryURL
        try fileSystem.ensureDirectory(directory)
        let url = directory.appendingPathComponent(
            ".mirmir-\(jobID.rawValue)-\(checkpointID.rawValue).assembled-video.mov",
            isDirectory: false
        )
        guard Self.isApplicationWorkingArtifactName(url.lastPathComponent) else {
            throw WorkflowApplicationQueueErrorV4
                .unsafeWorkingArtifact(url.path)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try removeApplicationWorkingArtifact(url)
        }
        return url
    }

    func removeApplicationWorkingArtifact(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent()
                == applicationWorkingDirectoryURL,
              Self.isApplicationWorkingArtifactName(
                  standardized.lastPathComponent
              ) else {
            throw WorkflowApplicationQueueErrorV4
                .unsafeWorkingArtifact(url.path)
        }
        var metadata = stat()
        if lstat(standardized.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw WorkflowApplicationQueueErrorV4
                    .unsafeWorkingArtifact(url.path)
            }
            return
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw WorkflowApplicationQueueErrorV4
                .unsafeWorkingArtifact(url.path)
        }
        try FileManager.default.removeItem(at: standardized)
    }

    func assembleApplicationCheckpoint(
        _ checkpoint: WorkflowCheckpointDocumentV4,
        timeline: WorkflowApplicationAssemblyTimelineDescriptorV4,
        destinationURL: URL,
        overwriteExistingFile: Bool
    ) async throws -> AVFoundationSegmentAssemblyResultV4 {
        let jobBinding = checkpoint.body.compatibility.jobBinding
        let mediaTimelineStart = CMTime(
            value: timeline.mediaTimelineStart.value,
            timescale: timeline.mediaTimelineStart.timescale
        )
        let outputTimelineStart = CMTime(
            value: timeline.outputTimelineStart.value,
            timescale: timeline.outputTimelineStart.timescale
        )
        let firstSegmentStart = checkpoint.body.segments.first.map {
            CMTime(value: $0.startTime.value, timescale: $0.startTime.timescale)
        }
        guard timeline.planID == jobBinding.planID,
              let firstSegmentStart,
              mediaTimelineStart.isNumeric,
              outputTimelineStart.isNumeric,
              !mediaTimelineStart.flags.contains(.hasBeenRounded),
              !outputTimelineStart.flags.contains(.hasBeenRounded),
              CMTimeCompare(mediaTimelineStart, firstSegmentStart) == 0,
              CMTimeCompare(mediaTimelineStart, .zero) >= 0,
              CMTimeCompare(outputTimelineStart, .zero) >= 0 else {
            throw WorkflowApplicationQueueErrorV4
                .preparedPlanChanged(jobBinding.jobID)
        }
        return try await AVFoundationSegmentAssemblerV4().assemble(.init(
            artifactRootURL: rootURL,
            segments: checkpoint.body.segments,
            mediaTimelineStart: timeline.mediaTimelineStart,
            outputTimelineStart: timeline.outputTimelineStart,
            destinationURL: destinationURL,
            outputFileType: .mov,
            overwriteExistingFile: overwriteExistingFile
        ))
    }
}

private extension WorkflowApplicationQueueV4 {
    var applicationWorkingDirectoryURL: URL {
        cacheDirectoryURL.appendingPathComponent(
            "application-working-media-v4",
            isDirectory: true
        )
    }

    nonisolated static func isCacheDeletionAllowed(
        _ lifecycle: WorkflowJobLifecycle
    ) -> Bool {
        lifecycle.canDeleteCachedData
    }

    nonisolated static func matchesCacheDeletionSelection(
        _ lifecycle: WorkflowJobLifecycle,
        selection: WorkflowCachedJobSelectionV4
    ) -> Bool {
        switch selection {
        case .finished:
            lifecycle.isTerminal
        case .unfinished:
            !lifecycle.isTerminal
        case .all:
            true
        }
    }

    func cachedJobDirectoryURL(jobID: WorkflowJobID) -> URL {
        rootURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobID.rawValue, isDirectory: true)
    }

    func removeCachedJobDirectory(jobID: WorkflowJobID) throws {
        let jobsURL = rootURL.appendingPathComponent(
            "jobs",
            isDirectory: true
        )
        let directory = cachedJobDirectoryURL(jobID: jobID)
        guard directory.deletingLastPathComponent() == jobsURL,
              directory.lastPathComponent == jobID.rawValue else {
            throw WorkflowApplicationQueueErrorV4.cacheCleanupFailed(
                directory.path
            )
        }
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw WorkflowApplicationQueueErrorV4.cacheCleanupFailed(
                    directory.path
                )
            }
            return
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw WorkflowApplicationQueueErrorV4.cacheCleanupFailed(
                directory.path
            )
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw WorkflowApplicationQueueErrorV4.cacheCleanupFailed(
                directory.path
            )
        }
        let parent = open(
            jobsURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if parent >= 0 {
            _ = fsync(parent)
            close(parent)
        }
    }

    func clearApplicationWorkingArtifacts() throws -> Int {
        let directory = applicationWorkingDirectoryURL
        try fileSystem.ensureDirectory(directory)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        var deleted = 0
        for name in names where Self.isApplicationWorkingArtifactName(name) {
            try removeApplicationWorkingArtifact(
                directory.appendingPathComponent(name, isDirectory: false)
            )
            deleted += 1
        }
        return deleted
    }

    func clearOrphanCachedJobDirectories() async throws -> Int {
        let jobsURL = rootURL.appendingPathComponent(
            "jobs",
            isDirectory: true
        )
        try fileSystem.ensureDirectory(jobsURL)
        let retained = Set(try await coordinator.open().state.jobs.keys)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: jobsURL.path
        )
        var deleted = 0
        for name in names {
            guard let jobID = try? WorkflowJobID(name),
                  !retained.contains(jobID) else {
                continue
            }
            try removeCachedJobDirectory(jobID: jobID)
            deleted += 1
        }
        return deleted
    }

    func scavengeAbandonedApplicationWorkingArtifacts() throws {
        let directory = applicationWorkingDirectoryURL
        try fileSystem.ensureDirectory(directory)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard Self.isApplicationWorkingArtifactName(name) else {
                // This namespace is private to the workflow bridge. Unknown
                // entries are never deleted automatically.
                continue
            }
            try removeApplicationWorkingArtifact(url)
        }
    }

    nonisolated static func isApplicationWorkingArtifactName(
        _ value: String
    ) -> Bool {
        guard value.utf8.count <= 240,
              value.hasPrefix(".mirmir-job-"),
              !value.contains("/"),
              !value.contains("\\") else {
            return false
        }
        return value.hasSuffix(".partial.segment.mov")
            || value.hasSuffix(".assembled-video.mov")
    }

    nonisolated static func boundaryToken(
        jobID: WorkflowJobID,
        planID: WorkflowPlanID,
        outputContractID: WorkflowOutputContractID,
        segmentIdentity: AVFoundationSegmentIdentityV4,
        boundaryOrdinal: UInt64
    ) throws -> String {
        let data = Data([
            jobID.rawValue,
            planID.rawValue,
            outputContractID.rawValue,
            String(boundaryOrdinal),
            try segmentIdentity.canonicalSHA256,
        ].joined(separator: "\u{0}").utf8)
        return String(WorkflowV4Validation.domainSeparatedSHA256(
            domain: "Mirmir.WorkflowApplication.Boundary.v2\u{0}",
            data: data
        ).prefix(40))
    }

    nonisolated static func checkpointKind(
        _ key: AVFoundationSegmentTrackKeyV4
    ) -> WorkflowCheckpointTrackKindV4 {
        switch key.mediaType {
        case AVMediaType.video.rawValue: .video
        case AVMediaType.audio.rawValue: .audio
        case AVMediaType.subtitle.rawValue: .subtitle
        case AVMediaType.closedCaption.rawValue: .caption
        case AVMediaType.timecode.rawValue: .timecode
        case AVMediaType.metadata.rawValue: .timedMetadata
        default: .auxiliary
        }
    }
}

// MARK: - Crash-consistent final publication

extension WorkflowApplicationQueueV4 {
    func prepareApplicationPublication(
        activated: WorkflowActivatedUpscaleRequestV4,
        checkpoint: WorkflowCheckpointDocumentV4
    ) async throws -> WorkflowApplicationPublicationIntentV4 {
        try activated.revalidateAll()
        let specification = activated.specification
        let jobID = specification.jobID
        let opened = try await coordinator.open()
        guard let job = opened.state.job(id: jobID) else {
            throw WorkflowApplicationQueueErrorV4.jobNotFound(jobID)
        }
        guard job.lifecycle == .committing || job.lifecycle == .recovering,
              job.specification.binding == specification.binding,
              checkpoint.body.compatibility
                == WorkflowCheckpointCompatibilityBindingV4(
                    specification: specification,
                    sourceSnapshotIdentityID:
                        activated.sourceSnapshot.identityID
                ),
              checkpoint.body.compatibility.jobBinding
                == specification.binding,
              checkpoint.body.trackProgress.contains(where: {
                  $0.kind == .video && $0.isComplete
              }),
              activated.preparedPlanBinding.outputContractID
                == checkpoint.body.segments.last?.codecSettingsHash,
              activated.request.outputURL.lastPathComponent
                == specification.output.fileName.rawValue else {
            throw WorkflowApplicationQueueErrorV4
                .publicationBindingMismatch(jobID)
        }
        _ = try await verifyApplicationCheckpoint(checkpoint)

        let directory = activated.request.outputURL
            .deletingLastPathComponent()
            .standardizedFileURL
        let token = publicationToken(
            jobBinding: specification.binding,
            checkpoint: checkpoint
        )
        let stagingName = ".mirmir-publication-\(token).partial.mov"
        let migrationName = ".mirmir-migration-\(token).partial.mov"
        guard WorkflowV4Validation.isMirmirPartialFileName(stagingName),
              WorkflowV4Validation.isMirmirPartialFileName(migrationName)
        else {
            throw WorkflowApplicationQueueErrorV4
                .publicationBindingMismatch(jobID)
        }
        let finalURL = activated.request.outputURL.standardizedFileURL
        let stagingURL = directory.appendingPathComponent(
            stagingName,
            isDirectory: false
        )
        let migrationURL = directory.appendingPathComponent(
            migrationName,
            isDirectory: false
        )
        let publicationDirectory = publicationDirectoryURL(jobID: jobID)
        try fileSystem.ensureDirectory(publicationDirectory)

        let intent = try fileSystem.withExclusiveLock(
            at: publicationLockURL(jobID: jobID)
        ) { transaction in
            if let existing = try loadPublicationState(
                jobID: jobID,
                transaction: transaction
            ) {
                try verifyPublicationIntent(
                    existing.intent,
                    specification: specification,
                    checkpoint: checkpoint,
                    activated: activated
                )
                return existing.intent
            }

            let original = try observePublicationFileIfPresent(at: finalURL)
            guard original == nil || activated.request.overwriteExistingFile else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationDestinationConflict(finalURL.path)
            }
            guard try observePublicationFileIfPresent(at: stagingURL) == nil else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationStageConflict(stagingURL.path)
            }
            guard try observePublicationFileIfPresent(at: migrationURL) == nil else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationStageConflict(migrationURL.path)
            }
            let body = WorkflowApplicationPublicationIntentBodyV4(
                jobBinding: specification.binding,
                checkpointID: checkpoint.body.checkpointID,
                checkpointDocumentHash: checkpoint.bodyHash,
                outputContractID:
                    activated.preparedPlanBinding.outputContractID,
                finalFileName: specification.output.fileName,
                stagingFileName: stagingName,
                migrationTemporaryFileName: migrationName,
                overwriteExistingFile:
                    activated.request.overwriteExistingFile,
                originalDestination: original,
                createdAt: clock.now()
            )
            let document = try makePublicationIntent(body)
            try transaction.writeNewAtomically(
                codec.canonicalData(document),
                to: publicationIntentURL(jobID: jobID)
            )
            return document
        }
        try activated.revalidateAll()
        return intent
    }

    func applicationPublicationState(
        jobID: WorkflowJobID
    ) throws -> WorkflowApplicationPublicationStateV4? {
        let directory = publicationDirectoryURL(jobID: jobID)
        try fileSystem.ensureDirectory(directory)
        return try fileSystem.withExclusiveLock(
            at: publicationLockURL(jobID: jobID)
        ) { transaction in
            try loadPublicationState(jobID: jobID, transaction: transaction)
        }
    }

    func applicationPublicationStagingURL(
        _ intent: WorkflowApplicationPublicationIntentV4,
        activated: WorkflowActivatedUpscaleRequestV4
    ) throws -> URL {
        try publicationURLs(intent: intent, activated: activated).staging
    }

    func applicationPublicationMigrationTemporaryURL(
        _ intent: WorkflowApplicationPublicationIntentV4,
        activated: WorkflowActivatedUpscaleRequestV4
    ) throws -> URL {
        try publicationURLs(intent: intent, activated: activated).migration
    }

    func discardApplicationUnverifiedPublicationArtifacts(
        _ intent: WorkflowApplicationPublicationIntentV4,
        activated: WorkflowActivatedUpscaleRequestV4
    ) throws {
        try activated.revalidateAll()
        let urls = try publicationURLs(intent: intent, activated: activated)
        try fileSystem.withExclusiveLock(
            at: publicationLockURL(jobID: intent.jobID)
        ) { transaction in
            let state = try requirePublicationState(
                intent: intent,
                transaction: transaction
            )
            if state.stage == nil {
                try removePublicationFileIfPresent(at: urls.staging)
            }
            try removePublicationFileIfPresent(at: urls.migration)
        }
        try activated.revalidateAll()
    }

    func recordApplicationStagedPublication(
        _ intent: WorkflowApplicationPublicationIntentV4,
        finalized: WorkflowApplicationFinalizedOutputV4,
        activated: WorkflowActivatedUpscaleRequestV4
    ) async throws -> WorkflowApplicationPublicationStageV4 {
        try activated.revalidateAll()
        let urls = try publicationURLs(intent: intent, activated: activated)
        guard finalized.destinationURL.standardizedFileURL == urls.staging else {
            throw WorkflowApplicationQueueErrorV4
                .publicationBindingMismatch(intent.jobID)
        }
        let translationFile: WorkflowApplicationPublicationFileV4?
        if finalized.verification.aacGaplessMetadataTranslation != nil {
            translationFile = try observePublicationFile(at: urls.staging)
            try await verifyPublicationAACTranslation(finalized.verification,
                activated: activated, outputURL: urls.staging)
        } else { translationFile = nil }
        let result = try fileSystem.withExclusiveLock(
            at: publicationLockURL(jobID: intent.jobID)
        ) { transaction in
            if let translationFile {
                guard try observePublicationFile(at: urls.staging) == translationFile else {
                    throw WorkflowApplicationQueueErrorV4.publicationVerificationInvalid
                }
            }
            let state = try requirePublicationState(
                intent: intent,
                transaction: transaction
            )
            if let existing = state.stage {
                let observed = try observePublicationFile(at: urls.staging)
                guard observed == existing.body.stagedFile,
                      existing.body.migrationVerification
                        == finalized.verification else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationDocumentConflict(intent.jobID)
                }
                return existing
            }
            guard try observePublicationFileIfPresent(at: urls.migration) == nil
            else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationStageConflict(urls.migration.path)
            }
            let observed = try observePublicationFile(at: urls.staging)
            guard observed.byteCount > 0 else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationVerificationInvalid
            }
            let body = WorkflowApplicationPublicationStageBodyV4(
                intentHash: intent.bodyHash,
                jobBinding: intent.body.jobBinding,
                stagedFile: observed,
                migrationVerification: finalized.verification,
                verifiedAt: clock.now()
            )
            let document = try makePublicationStage(body)
            try transaction.writeNewAtomically(
                codec.canonicalData(document),
                to: publicationStageURL(jobID: intent.jobID)
            )
            return document
        }
        try activated.revalidateAll()
        return result
    }

    func publishApplicationStagedOutput(
        _ intent: WorkflowApplicationPublicationIntentV4,
        activated: WorkflowActivatedUpscaleRequestV4
    ) async throws -> WorkflowApplicationPublicationReceiptV4 {
        try activated.revalidateAll()
        let urls = try publicationURLs(intent: intent, activated: activated)
        let checkedTranslationStage: WorkflowApplicationPublicationStageV4?
        if let stage = try applicationPublicationState(jobID: intent.jobID)?.stage,
           stage.body.migrationVerification.aacGaplessMetadataTranslation != nil {
            let outputURL: URL
            if try observePublicationFileIfPresent(at: urls.staging) == stage.body.stagedFile {
                outputURL = urls.staging
            } else if try observePublicationFileIfPresent(at: urls.final) == stage.body.stagedFile {
                outputURL = urls.final
            } else { throw WorkflowApplicationQueueErrorV4.publicationVerificationInvalid }
            try await verifyPublicationAACTranslation(stage.body.migrationVerification,
                activated: activated, outputURL: outputURL)
            checkedTranslationStage = stage
        } else { checkedTranslationStage = nil }
        let result = try fileSystem.withExclusiveLock(
            at: publicationLockURL(jobID: intent.jobID)
        ) { transaction in
            let state = try requirePublicationState(
                intent: intent,
                transaction: transaction
            )
            guard let stage = state.stage else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationStageMissing(intent.jobID)
            }
            guard stage.body.migrationVerification.aacGaplessMetadataTranslation == nil
                    || checkedTranslationStage == stage else {
                throw WorkflowApplicationQueueErrorV4.publicationVerificationInvalid
            }
            if let receipt = state.receipt {
                let final = try observePublicationFile(at: urls.final)
                guard final == receipt.body.finalFile,
                      final == stage.body.stagedFile else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationDestinationConflict(urls.final.path)
                }
                try cleanupDisplacedPublicationFile(
                    at: urls.staging,
                    intent: intent,
                    receipt: receipt
                )
                return receipt
            }

            let staged = try observePublicationFileIfPresent(at: urls.staging)
            let final = try observePublicationFileIfPresent(at: urls.final)
            let method: WorkflowApplicationPublicationMethodV4
            let displaced: WorkflowApplicationPublicationFileV4?
            var performedRename = false

            if final == stage.body.stagedFile {
                guard staged == nil
                        || staged == intent.body.originalDestination else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationStageConflict(urls.staging.path)
                }
                method = .recoveredPublishedFile
                displaced = staged
            } else {
                guard staged == stage.body.stagedFile else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationStageMissing(intent.jobID)
                }
                if let original = intent.body.originalDestination {
                    guard intent.body.overwriteExistingFile,
                          final == original else {
                        throw WorkflowApplicationQueueErrorV4
                            .publicationDestinationConflict(urls.final.path)
                    }
                    try atomicSwapPublicationFiles(
                        stagingURL: urls.staging,
                        finalURL: urls.final
                    )
                    let published = try observePublicationFile(at: urls.final)
                    let displacedObserved = try observePublicationFile(
                        at: urls.staging
                    )
                    guard published == stage.body.stagedFile,
                          displacedObserved == original else {
                        try? atomicSwapPublicationFiles(
                            stagingURL: urls.staging,
                            finalURL: urls.final
                        )
                        throw WorkflowApplicationQueueErrorV4
                            .publicationDestinationConflict(urls.final.path)
                    }
                    method = .atomicSwap
                    displaced = displacedObserved
                    performedRename = true
                } else {
                    guard final == nil else {
                        throw WorkflowApplicationQueueErrorV4
                            .publicationDestinationConflict(urls.final.path)
                    }
                    try exclusiveRenamePublicationFile(
                        stagingURL: urls.staging,
                        finalURL: urls.final
                    )
                    method = .exclusiveRename
                    displaced = nil
                    performedRename = true
                }
                try synchronizePublicationDirectory(urls.directory)
            }

            if performedRename && terminateAfterPublicationRename {
                terminateAfterPublicationRename = false
                throw WorkflowApplicationQueueErrorV4
                    .injectedPublicationTermination
            }

            let published = try observePublicationFile(at: urls.final)
            guard published == stage.body.stagedFile else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationDestinationConflict(urls.final.path)
            }
            let body = WorkflowApplicationPublicationReceiptBodyV4(
                stageHash: stage.bodyHash,
                jobBinding: intent.body.jobBinding,
                finalFile: published,
                method: method,
                displacedDestination: displaced,
                publishedAt: clock.now()
            )
            let receipt = try makePublicationReceipt(body)
            try transaction.writeNewAtomically(
                codec.canonicalData(receipt),
                to: publicationReceiptURL(jobID: intent.jobID)
            )
            try cleanupDisplacedPublicationFile(
                at: urls.staging,
                intent: intent,
                receipt: receipt
            )
            return receipt
        }
        try activated.revalidateAll()
        return result
    }

    func applicationPublicationRecoveryCandidates()
        async throws -> [WorkflowApplicationPublicationRecoveryCandidateV4]
    {
        let state = try await coordinator.open().state
        return state.jobs.values.sorted {
            $0.specification.jobID < $1.specification.jobID
        }.compactMap { job in
            guard job.lifecycle == .committing
                    || job.lifecycle == .recovering else {
                return nil
            }
            let hasIntent: Bool
            do {
                hasIntent = try applicationPublicationState(
                    jobID: job.specification.jobID
                ) != nil
            } catch {
                // A corrupt publication document is still a recovery
                // candidate. Claiming it lets the coordinator contain this
                // job without preventing unrelated publications from being
                // reconciled.
                return WorkflowApplicationPublicationRecoveryCandidateV4(
                    jobID: job.specification.jobID,
                    lifecycle: job.lifecycle,
                    hasIntent: true
                )
            }
            if job.lifecycle == .committing || hasIntent {
                return WorkflowApplicationPublicationRecoveryCandidateV4(
                    jobID: job.specification.jobID,
                    lifecycle: job.lifecycle,
                    hasIntent: hasIntent
                )
            }
            return nil
        }
    }

    func beginApplicationPublicationRecovery(
        jobID: WorkflowJobID,
        commandKey: WorkflowRecoveryCommandKeyV4
    ) async throws -> WorkflowRecoveryClaimResultV4 {
        try await dispatcher.beginRecovery(
            jobID: jobID,
            commandKey: commandKey
        )
    }

    func completeApplicationPublicationRecovery(
        _ dispatch: WorkflowQueueDispatchReceiptV4,
        target: WorkflowJobLifecycle,
        commandKey: WorkflowRecoveryCommandKeyV4
    ) async throws -> WorkflowQueueTransitionReceiptV4 {
        try await dispatcher.completeRecovery(
            dispatch,
            target: target,
            commandKey: commandKey
        )
    }

    func cleanupCompletedApplicationPublications() async throws {
        let state = try await coordinator.open().state
        for job in state.jobs.values where job.lifecycle == .completed {
            let jobID = job.specification.jobID
            guard let publication = try applicationPublicationState(jobID: jobID),
                  let receipt = publication.receipt else {
                continue
            }
            let activation = await activate(jobID: jobID)
            guard case .active(let activated) = activation else { continue }
            defer { activated.close() }
            let urls = try publicationURLs(
                intent: publication.intent,
                activated: activated
            )
            try fileSystem.withExclusiveLock(
                at: publicationLockURL(jobID: jobID)
            ) { _ in
                let final = try observePublicationFile(at: urls.final)
                guard final == receipt.body.finalFile else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationDestinationConflict(urls.final.path)
                }
                try cleanupDisplacedPublicationFile(
                    at: urls.staging,
                    intent: publication.intent,
                    receipt: receipt
                )
                try removePublicationFileIfPresent(at: urls.migration)
            }
        }
    }

    /// Source copies are recovery authority and therefore outlive every
    /// nonterminal disposition, including failed, contained, paused, and
    /// recovering jobs. Only durable success or cancellation permits removal.
    func cleanupTerminalApplicationSourceSnapshots() async throws {
        let state = try await coordinator.open().state
        for job in state.jobs.values
        where job.lifecycle == .completed || job.lifecycle == .cancelled {
            let document: WorkflowApplicationRequestDocumentV4
            do {
                document = try loadVerifiedRequestDocument(
                    specification: job.specification
                )
            } catch {
                // A corrupt authority record cannot authorize deletion.
                continue
            }
            do {
                try removeApplicationSourceSnapshot(
                    jobID: job.specification.jobID,
                    binding: document.body.sourceSnapshot
                )
            } catch {
                // Retention is the safe recovery behavior for an unexpected
                // filesystem shape; a later launch can retry after inspection.
                continue
            }
        }
    }
}

// MARK: - Validation and persistence

private extension WorkflowApplicationQueueV4 {
    struct ApplicationSourceSnapshotCreationV4 {
        let url: URL
        let binding: WorkflowApplicationSourceSnapshotBindingV4
    }

    func createApplicationSourceSnapshot(
        sourceURL: URL,
        jobID: WorkflowJobID
    ) throws -> ApplicationSourceSnapshotCreationV4 {
        let jobsURL = rootURL.appendingPathComponent("jobs", isDirectory: true)
        let jobURL = jobsURL.appendingPathComponent(
            jobID.rawValue,
            isDirectory: true
        )
        try fileSystem.ensureDirectory(jobsURL)
        try fileSystem.ensureDirectory(jobURL)

        let fileName = sourceURL.lastPathComponent
        guard Self.isSafeApplicationSourceSnapshotFileName(fileName) else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        let finalDirectory = jobURL.appendingPathComponent(
            Self.sourceSnapshotDirectoryName,
            isDirectory: true
        )
        let temporaryDirectory = jobURL.appendingPathComponent(
            ".\(Self.sourceSnapshotDirectoryName).\(UUID().uuidString.lowercased()).partial",
            isDirectory: true
        )
        let temporaryURL = temporaryDirectory.appendingPathComponent(fileName)
        let finalURL = finalDirectory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: finalDirectory.path),
              mkdir(temporaryDirectory.path, S_IRWXU) == 0 else {
            throw Self.sourceSnapshotFilesystemError(
                operation: "create_private_directory",
                path: temporaryDirectory.path
            )
        }

        var finalInstalled = false
        do {
            let sourcePath = sourceURL.standardizedFileURL.path
            var sourcePathBefore = stat()
            guard lstat(sourcePath, &sourcePathBefore) == 0,
                  Self.isSafeApplicationSourceFile(sourcePathBefore) else {
                throw WorkflowApplicationQueueErrorV4
                    .sourceSnapshotInvalid(jobID)
            }
            let sourceDescriptor = open(
                sourcePath,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard sourceDescriptor >= 0 else {
                throw Self.sourceSnapshotFilesystemError(
                    operation: "open_source",
                    path: sourcePath
                )
            }
            defer { close(sourceDescriptor) }
            var sourceBefore = stat()
            guard fstat(sourceDescriptor, &sourceBefore) == 0,
                  Self.sameSourceSnapshotFile(
                    sourcePathBefore,
                    sourceBefore
                  ) else {
                throw WorkflowApplicationQueueErrorV4
                    .sourceSnapshotInvalid(jobID)
            }

            let directoryDescriptor = open(
                temporaryDirectory.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryDescriptor >= 0 else {
                throw Self.sourceSnapshotFilesystemError(
                    operation: "open_private_directory",
                    path: temporaryDirectory.path
                )
            }
            defer { close(directoryDescriptor) }
            let destinationDescriptor = openat(
                directoryDescriptor,
                fileName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard destinationDescriptor >= 0 else {
                throw Self.sourceSnapshotFilesystemError(
                    operation: "create_snapshot",
                    path: temporaryURL.path
                )
            }
            defer { close(destinationDescriptor) }

            var byteCount: UInt64 = 0
            var hasher = SHA256()
            var buffer = [UInt8](
                repeating: 0,
                count: Self.sourceSnapshotReadSize
            )
            while true {
                let count = Darwin.read(
                    sourceDescriptor,
                    &buffer,
                    buffer.count
                )
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else {
                    throw Self.sourceSnapshotFilesystemError(
                        operation: "read_source",
                        path: sourcePath
                    )
                }
                guard count > 0 else { break }
                let (nextCount, overflow) = byteCount.addingReportingOverflow(
                    UInt64(count)
                )
                guard !overflow else {
                    throw WorkflowApplicationQueueErrorV4
                        .sourceSnapshotInvalid(jobID)
                }
                try Self.writeApplicationSourceSnapshotBytes(
                    buffer,
                    count: count,
                    descriptor: destinationDescriptor,
                    jobID: jobID,
                    path: temporaryURL.path
                )
                buffer.withUnsafeBytes {
                    hasher.update(
                        bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])
                    )
                }
                byteCount = nextCount
            }

            var sourceAfter = stat()
            var sourcePathAfter = stat()
            guard byteCount > 0,
                  fstat(sourceDescriptor, &sourceAfter) == 0,
                  lstat(sourcePath, &sourcePathAfter) == 0,
                  Self.sameSourceSnapshotFile(sourceBefore, sourceAfter),
                  Self.sameSourceSnapshotFile(sourceAfter, sourcePathAfter),
                  fchmod(destinationDescriptor, S_IRUSR) == 0,
                  fsync(destinationDescriptor) == 0,
                  fsync(directoryDescriptor) == 0 else {
                throw WorkflowApplicationQueueErrorV4
                    .sourceSnapshotInvalid(jobID)
            }
            let digest = try ASHSHA256V4(Self.hex(hasher.finalize()))
            let relativePath = "jobs/\(jobID.rawValue)/\(Self.sourceSnapshotDirectoryName)/\(fileName)"
            let binding = try WorkflowApplicationSourceSnapshotBindingV4(
                relativePath: relativePath,
                byteCount: byteCount,
                sha256: digest
            )

            guard rename(temporaryDirectory.path, finalDirectory.path) == 0
            else {
                throw Self.sourceSnapshotFilesystemError(
                    operation: "install_snapshot",
                    path: finalDirectory.path
                )
            }
            finalInstalled = true
            let jobDescriptor = open(
                jobURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard jobDescriptor >= 0, fsync(jobDescriptor) == 0 else {
                if jobDescriptor >= 0 { close(jobDescriptor) }
                throw Self.sourceSnapshotFilesystemError(
                    operation: "sync_snapshot_parent",
                    path: jobURL.path
                )
            }
            close(jobDescriptor)
            try Self.verifyApplicationSourceSnapshot(
                at: finalURL,
                trustedRootURL: rootURL,
                jobID: jobID,
                binding: binding
            )
            return ApplicationSourceSnapshotCreationV4(
                url: finalURL,
                binding: binding
            )
        } catch {
            let target = finalInstalled ? finalDirectory : temporaryDirectory
            try? Self.removeOwnedApplicationSourceSnapshotDirectory(
                target,
                expectedFileName: fileName
            )
            throw error
        }
    }

    nonisolated static func verifyApplicationSourceSnapshot(
        at url: URL,
        trustedRootURL: URL,
        jobID: WorkflowJobID,
        binding: WorkflowApplicationSourceSnapshotBindingV4
    ) throws {
        let expectedRelativePath = "jobs/\(jobID.rawValue)/\(Self.sourceSnapshotDirectoryName)/\(url.lastPathComponent)"
        let expectedURL = trustedRootURL.appendingPathComponent(
            binding.relativePath,
            isDirectory: false
        ).standardizedFileURL
        guard Self.isExpectedApplicationSourceSnapshotRelativePath(
                binding.relativePath,
                jobID: jobID
              ),
              binding.relativePath == expectedRelativePath,
              url.standardizedFileURL == expectedURL,
              url.deletingLastPathComponent().lastPathComponent
                == Self.sourceSnapshotDirectoryName else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        let rootDescriptor = open(
            trustedRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        defer { close(rootDescriptor) }
        let jobsDescriptor = openat(
            rootDescriptor,
            "jobs",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard jobsDescriptor >= 0 else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        defer { close(jobsDescriptor) }
        let jobDescriptor = openat(
            jobsDescriptor,
            jobID.rawValue,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard jobDescriptor >= 0 else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        defer { close(jobDescriptor) }
        let snapshotDirectoryDescriptor = openat(
            jobDescriptor,
            Self.sourceSnapshotDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard snapshotDirectoryDescriptor >= 0 else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        defer { close(snapshotDirectoryDescriptor) }
        var openedDirectoryMetadata = stat()
        var pathDirectoryMetadata = stat()
        guard fstat(
                snapshotDirectoryDescriptor,
                &openedDirectoryMetadata
              ) == 0,
              lstat(
                url.deletingLastPathComponent().path,
                &pathDirectoryMetadata
              ) == 0,
              (openedDirectoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              openedDirectoryMetadata.st_dev == pathDirectoryMetadata.st_dev,
              openedDirectoryMetadata.st_ino == pathDirectoryMetadata.st_ino,
              (openedDirectoryMetadata.st_mode & 0o077) == 0 else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        let descriptor = openat(
            snapshotDirectoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              Self.isSafeSourceSnapshotFile(before),
              (before.st_mode & 0o777) == S_IRUSR,
              UInt64(before.st_size) == binding.byteCount else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        var hasher = SHA256()
        var observedByteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.sourceSnapshotReadSize)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw WorkflowApplicationQueueErrorV4
                    .sourceSnapshotInvalid(jobID)
            }
            guard count > 0 else { break }
            let (next, overflow) = observedByteCount.addingReportingOverflow(
                UInt64(count)
            )
            guard !overflow, next <= binding.byteCount else {
                throw WorkflowApplicationQueueErrorV4
                    .sourceSnapshotInvalid(jobID)
            }
            buffer.withUnsafeBytes {
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])
                )
            }
            observedByteCount = next
        }
        var after = stat()
        var pathAfter = stat()
        var directoryAfter = stat()
        guard observedByteCount == binding.byteCount,
              try ASHSHA256V4(Self.hex(hasher.finalize())) == binding.sha256,
              fstat(descriptor, &after) == 0,
              lstat(url.path, &pathAfter) == 0,
              lstat(
                url.deletingLastPathComponent().path,
                &directoryAfter
              ) == 0,
              Self.sameSourceSnapshotFile(before, after),
              Self.sameSourceSnapshotFile(after, pathAfter),
              openedDirectoryMetadata.st_dev == directoryAfter.st_dev,
              openedDirectoryMetadata.st_ino == directoryAfter.st_ino else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
    }

    nonisolated static func isExpectedApplicationSourceSnapshotRelativePath(
        _ relativePath: String,
        jobID: WorkflowJobID
    ) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "jobs",
              components[1] == Substring(jobID.rawValue),
              components[2] == Substring(Self.sourceSnapshotDirectoryName)
        else { return false }
        let name = String(components[3])
        return isSafeApplicationSourceSnapshotFileName(name)
    }

    nonisolated static func sourceSnapshotFileName(
        _ binding: WorkflowApplicationSourceSnapshotBindingV4
    ) -> String? {
        let components = binding.relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 4 else { return nil }
        let name = String(components[3])
        return isSafeApplicationSourceSnapshotFileName(name) ? name : nil
    }

    /// Exact basename grammar emitted by the deployed pre-fix snapshot
    /// writer. A missing canonical name is migration-incompatible only for
    /// this grammar; post-fix request bodies with an authenticated original
    /// basename are unaffected even when that basename itself is `source.mov`.
    nonisolated static func isLegacyApplicationSourceSnapshotFileName(
        _ name: String
    ) -> Bool {
        if name == "source" { return true }
        guard name.hasPrefix("source.") else { return false }
        let suffix = name.dropFirst(7)
        return !suffix.isEmpty
            && suffix.utf8.count <= 16
            && suffix.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x7a).contains($0)
            }
    }

    nonisolated static func requiresLegacySourceSnapshotReenqueue(
        _ body: WorkflowApplicationRequestBodyV4
    ) -> Bool {
        guard body.canonicalSourceFileName == nil,
              let snapshotFileName = sourceSnapshotFileName(
                body.sourceSnapshot
              ) else {
            return false
        }
        return isLegacyApplicationSourceSnapshotFileName(snapshotFileName)
    }

    nonisolated static func isSafeApplicationSourceSnapshotFileName(
        _ name: String
    ) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && name.utf8.count <= Int(NAME_MAX)
            && !name.utf8.contains(0)
            && !name.contains("/")
    }

    func removeApplicationSourceSnapshot(
        jobID: WorkflowJobID,
        binding: WorkflowApplicationSourceSnapshotBindingV4
    ) throws {
        let url = rootURL.appendingPathComponent(binding.relativePath)
            .standardizedFileURL
        let expectedRelativePath = "jobs/\(jobID.rawValue)/\(Self.sourceSnapshotDirectoryName)/\(url.lastPathComponent)"
        guard binding.relativePath == expectedRelativePath,
              Self.isExpectedApplicationSourceSnapshotRelativePath(
                binding.relativePath,
                jobID: jobID
              ) else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotInvalid(jobID)
        }
        let rootDescriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw Self.sourceSnapshotFilesystemError(
                operation: "open_cleanup_root",
                path: rootURL.path
            )
        }
        defer { close(rootDescriptor) }
        let jobsDescriptor = openat(
            rootDescriptor,
            "jobs",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard jobsDescriptor >= 0 else {
            throw Self.sourceSnapshotFilesystemError(
                operation: "open_cleanup_jobs",
                path: url.path
            )
        }
        defer { close(jobsDescriptor) }
        let jobDescriptor = openat(
            jobsDescriptor,
            jobID.rawValue,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard jobDescriptor >= 0 else {
            throw Self.sourceSnapshotFilesystemError(
                operation: "open_cleanup_job",
                path: url.path
            )
        }
        defer { close(jobDescriptor) }
        let directoryDescriptor = openat(
            jobDescriptor,
            Self.sourceSnapshotDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return }
            throw Self.sourceSnapshotFilesystemError(
                operation: "open_cleanup_snapshot",
                path: url.path
            )
        }
        defer { close(directoryDescriptor) }
        var openedDirectory = stat()
        var pathDirectory = stat()
        var fileMetadata = stat()
        guard fstat(directoryDescriptor, &openedDirectory) == 0,
              lstat(url.deletingLastPathComponent().path, &pathDirectory) == 0,
              openedDirectory.st_dev == pathDirectory.st_dev,
              openedDirectory.st_ino == pathDirectory.st_ino,
              (openedDirectory.st_mode & S_IFMT) == S_IFDIR,
              (openedDirectory.st_mode & 0o077) == 0,
              try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path
              ) == [url.lastPathComponent],
              fstatat(
                directoryDescriptor,
                url.lastPathComponent,
                &fileMetadata,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              (fileMetadata.st_mode & S_IFMT) == S_IFREG,
              fileMetadata.st_nlink == 1 else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotFilesystemFailure(
                    operation: "unsafe_cleanup_snapshot",
                    path: url.path,
                    code: EINVAL
                )
        }
        guard unlinkat(
                directoryDescriptor,
                url.lastPathComponent,
                0
              ) == 0,
              unlinkat(
                jobDescriptor,
                Self.sourceSnapshotDirectoryName,
                AT_REMOVEDIR
              ) == 0,
              fsync(jobDescriptor) == 0 else {
            throw Self.sourceSnapshotFilesystemError(
                operation: "remove_snapshot",
                path: url.path
            )
        }
    }

    nonisolated static func removeOwnedApplicationSourceSnapshotDirectory(
        _ directory: URL,
        expectedFileName: String
    ) throws {
        var directoryMetadata = stat()
        guard lstat(directory.path, &directoryMetadata) == 0 else {
            if errno == ENOENT { return }
            throw sourceSnapshotFilesystemError(
                operation: "inspect_cleanup_directory",
                path: directory.path
            )
        }
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        guard (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              (directoryMetadata.st_mode & 0o077) == 0,
              entries.isEmpty || entries == [expectedFileName] else {
            throw WorkflowApplicationQueueErrorV4
                .sourceSnapshotFilesystemFailure(
                    operation: "unsafe_cleanup_directory",
                    path: directory.path,
                    code: EINVAL
                )
        }
        if !entries.isEmpty {
            let fileURL = directory.appendingPathComponent(expectedFileName)
            var fileMetadata = stat()
            guard lstat(fileURL.path, &fileMetadata) == 0,
                  (fileMetadata.st_mode & S_IFMT) == S_IFREG,
                  fileMetadata.st_nlink == 1,
                  unlink(fileURL.path) == 0 else {
                throw WorkflowApplicationQueueErrorV4
                    .sourceSnapshotFilesystemFailure(
                        operation: "unsafe_cleanup_file",
                        path: fileURL.path,
                        code: EINVAL
                    )
            }
        }
        guard rmdir(directory.path) == 0 else {
            throw sourceSnapshotFilesystemError(
                operation: "remove_snapshot",
                path: directory.path
            )
        }
    }

    nonisolated static func isSafeSourceSnapshotFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_size > 0
    }

    /// User-selected source media may legitimately have multiple hard links.
    /// The queue copies from a no-follow descriptor, verifies that descriptor
    /// against the selected path before and after the copy, and hashes every
    /// copied byte. Queue-owned snapshots retain the stricter single-link
    /// invariant so their path continues to prove exclusive ownership.
    nonisolated static func isSafeApplicationSourceFile(
        _ metadata: stat
    ) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink >= 1
            && metadata.st_size > 0
    }

    nonisolated static func sameSourceSnapshotFile(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    nonisolated static func writeApplicationSourceSnapshotBytes(
        _ buffer: [UInt8],
        count: Int,
        descriptor: Int32,
        jobID: WorkflowJobID,
        path: String
    ) throws {
        try buffer.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw WorkflowApplicationQueueErrorV4
                    .sourceSnapshotInvalid(jobID)
            }
            var offset = 0
            while offset < count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset
                )
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    throw sourceSnapshotFilesystemError(
                        operation: "write_snapshot",
                        path: path
                    )
                }
                offset += written
            }
        }
    }

    nonisolated static func sourceSnapshotFilesystemError(
        operation: String,
        path: String
    ) -> WorkflowApplicationQueueErrorV4 {
        WorkflowApplicationQueueErrorV4.sourceSnapshotFilesystemFailure(
            operation: operation,
            path: path,
            code: errno
        )
    }

    nonisolated static func hex<D: Sequence>(_ digest: D) -> String
    where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func prepareTrustedRoot(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw WorkflowApplicationQueueErrorV4
                .unsafeApplicationSupportRoot(url.path)
        }

        var before = stat()
        if lstat(candidate.path, &before) == 0 {
            guard (before.st_mode & S_IFMT) == S_IFDIR,
                  (before.st_mode & S_IFMT) != S_IFLNK else {
                throw WorkflowApplicationQueueErrorV4
                    .unsafeApplicationSupportRoot(candidate.path)
            }
        } else {
            guard errno == ENOENT else {
                throw WorkflowApplicationQueueErrorV4
                    .unsafeApplicationSupportRoot(candidate.path)
            }
            do {
                try FileManager.default.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw WorkflowApplicationQueueErrorV4
                    .unsafeApplicationSupportRoot(candidate.path)
            }
        }

        let resolved = candidate.resolvingSymlinksInPath()
        var after = stat()
        guard lstat(resolved.path, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFDIR,
              (after.st_mode & S_IFMT) != S_IFLNK else {
            throw WorkflowApplicationQueueErrorV4
                .unsafeApplicationSupportRoot(candidate.path)
        }
        return resolved
    }

    static func validate(
        request: UpscaleRequest,
        preparedBinding: WorkflowVerifiedPreparedPlanBindingV4
    ) throws {
        guard (1...maximumTargetDimension).contains(request.targetWidth),
              (1...maximumTargetDimension).contains(request.targetHeight) else {
            throw WorkflowApplicationQueueErrorV4.invalidTargetDimensions(
                width: request.targetWidth,
                height: request.targetHeight
            )
        }
        guard request.backendID.isConcreteBackend else {
            throw WorkflowApplicationQueueErrorV4.unresolvedBackend
        }
        guard request.backendID == preparedBinding.resolvedBackendID else {
            throw WorkflowApplicationQueueErrorV4.preparedBackendMismatch(
                request: request.backendID,
                prepared: preparedBinding.resolvedBackendID
            )
        }
        _ = try outputFileName(for: request.outputURL)
        guard request.inputURL.isFileURL,
              request.outputURL.isFileURL,
              request.outputURL.deletingLastPathComponent().isFileURL else {
            throw WorkflowApplicationQueueErrorV4.invalidOutputURL(
                request.outputURL.path
            )
        }
    }

    static func outputFileName(for url: URL) throws -> WorkflowOutputFileName {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard !standardized.hasDirectoryPath,
              !name.isEmpty,
              standardized.deletingLastPathComponent()
                .appendingPathComponent(name, isDirectory: false)
                .standardizedFileURL == standardized else {
            throw WorkflowApplicationQueueErrorV4.invalidOutputURL(url.path)
        }
        return try WorkflowOutputFileName(name)
    }

    static func outputURL(
        directory: URL,
        fileName: WorkflowOutputFileName
    ) throws -> URL {
        let standardizedDirectory = directory.standardizedFileURL
        let output = standardizedDirectory
            .appendingPathComponent(fileName.rawValue, isDirectory: false)
            .standardizedFileURL
        guard output.deletingLastPathComponent() == standardizedDirectory else {
            throw WorkflowApplicationQueueErrorV4.invalidOutputURL(output.path)
        }
        return output
    }

    static func requestID(
        request: UpscaleRequest,
        outputFileName: WorkflowOutputFileName,
        binding: WorkflowVerifiedPreparedPlanBindingV4,
        codec: WorkflowCanonicalCodec
    ) throws -> WorkflowRequestID {
        let material = WorkflowApplicationRequestIdentityMaterialV4(
            preparedPlanBinding: binding,
            outputFileName: outputFileName,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            outputCodec: request.outputCodec,
            preserveAudio: request.preserveAudio,
            overwriteExistingFile: request.overwriteExistingFile
        )
        return try WorkflowRequestID(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.RequestIdentity.v1\u{0}",
                data: codec.canonicalData(material)
            )
        )
    }

    static func bookmarkReference(
        token: String,
        jobID: WorkflowJobID,
        requestID: WorkflowRequestID,
        runtimeBindingID: WorkflowRuntimeBindingID,
        role: WorkflowScopedResourceRoleV4,
        codec: WorkflowCanonicalCodec
    ) throws -> WorkflowBookmarkReference {
        let material = WorkflowApplicationBookmarkAuthorizationMaterialV4(
            jobID: jobID,
            requestID: requestID,
            runtimeBindingID: runtimeBindingID,
            role: role
        )
        let hash = try WorkflowBookmarkDocumentHash(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.BookmarkAuthorization.v1\u{0}",
                data: codec.canonicalData(material)
            )
        )
        let suffix: String
        switch role {
        case .inputFile: suffix = "input"
        case .outputDirectory: suffix = "output"
        case .cacheDirectory: suffix = "cache"
        }
        return try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("bookmark-\(token)-\(suffix)"),
            revision: 1,
            documentHash: hash
        )
    }

    func makeRequestDocument(
        _ body: WorkflowApplicationRequestBodyV4
    ) throws -> WorkflowApplicationRequestDocumentV4 {
        let hash = try WorkflowApplicationRequestDocumentHashV4(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.RequestDocument.v1\u{0}",
                data: codec.canonicalData(body)
            )
        )
        return WorkflowApplicationRequestDocumentV4(
            bodyHash: hash,
            body: body
        )
    }

    func verifyLegacyRequestBodyHash(
        _ body: WorkflowApplicationRequestBodyV2,
        expectedHash: WorkflowApplicationRequestDocumentHashV4,
        jobID: WorkflowJobID
    ) throws {
        let actual = try WorkflowApplicationRequestDocumentHashV4(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.RequestDocument.v1\u{0}",
                data: codec.canonicalData(body)
            )
        )
        guard actual == expectedHash else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentCorrupt(jobID)
        }
    }

    func migrateLegacyRequestBody(
        _ legacy: WorkflowApplicationRequestBodyV2,
        jobID: WorkflowJobID
    ) throws -> WorkflowApplicationRequestBodyV4 {
        guard let snapshotFileName = Self.sourceSnapshotFileName(
            legacy.sourceSnapshot
        ) else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentBindingMismatch(jobID)
        }
        let canonicalSourceFileName =
            Self.isLegacyApplicationSourceSnapshotFileName(snapshotFileName)
            ? nil
            : snapshotFileName
        return WorkflowApplicationRequestBodyV4(
            specification: legacy.specification,
            cacheBookmark: legacy.cacheBookmark,
            sourceSnapshot: legacy.sourceSnapshot,
            canonicalSourceFileName: canonicalSourceFileName,
            preparedPlanBinding: legacy.preparedPlanBinding,
            targetWidth: legacy.targetWidth,
            targetHeight: legacy.targetHeight,
            outputCodec: legacy.outputCodec,
            preserveAudio: legacy.preserveAudio,
            overwriteExistingFile: legacy.overwriteExistingFile
        )
    }

    func verifyRequestDocument(
        _ document: WorkflowApplicationRequestDocumentV4,
        specification: WorkflowJobSpecification
    ) throws {
        guard document.schemaVersion
                == WorkflowApplicationRequestDocumentV4.currentSchemaVersion,
              try makeRequestDocument(document.body) == document else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentCorrupt(specification.jobID)
        }
        let body = document.body
        let binding: WorkflowVerifiedPreparedPlanBindingV4
        do {
            binding = try body.preparedPlanBinding.revalidated()
        } catch {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentCorrupt(specification.jobID)
        }
        guard body.specification == specification,
              body.specification.source.identityID == binding.sourceIdentityID,
              body.specification.output.contractID == binding.outputContractID,
              body.specification.runtimeBinding == binding.runtimeBinding,
              let snapshotFileName = Self.sourceSnapshotFileName(
                body.sourceSnapshot
              ),
              body.canonicalSourceFileName == nil
                ? Self.isLegacyApplicationSourceSnapshotFileName(
                    snapshotFileName
                )
                : body.canonicalSourceFileName == snapshotFileName else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentBindingMismatch(specification.jobID)
        }
        let syntheticRequest = UpscaleRequest(
            inputURL: URL(fileURLWithPath: "/request-identity-input"),
            outputURL: URL(fileURLWithPath: "/")
                .appendingPathComponent(
                    specification.output.fileName.rawValue,
                    isDirectory: false
                ),
            backendID: binding.resolvedBackendID,
            targetWidth: body.targetWidth,
            targetHeight: body.targetHeight,
            outputCodec: body.outputCodec,
            preserveAudio: body.preserveAudio,
            overwriteExistingFile: body.overwriteExistingFile
        )
        try Self.validate(request: syntheticRequest, preparedBinding: binding)
        let expectedRequestID = try Self.requestID(
            request: syntheticRequest,
            outputFileName: specification.output.fileName,
            binding: binding,
            codec: codec
        )
        let token = try Self.jobToken(from: specification.jobID)
        let expectedSource = try Self.bookmarkReference(
            token: token,
            jobID: specification.jobID,
            requestID: expectedRequestID,
            runtimeBindingID: binding.runtimeBindingID,
            role: .inputFile,
            codec: codec
        )
        let expectedOutput = try Self.bookmarkReference(
            token: token,
            jobID: specification.jobID,
            requestID: expectedRequestID,
            runtimeBindingID: binding.runtimeBindingID,
            role: .outputDirectory,
            codec: codec
        )
        let expectedCache = try Self.bookmarkReference(
            token: token,
            jobID: specification.jobID,
            requestID: expectedRequestID,
            runtimeBindingID: binding.runtimeBindingID,
            role: .cacheDirectory,
            codec: codec
        )
        guard specification.requestID == expectedRequestID,
              specification.source.bookmark == expectedSource,
              specification.output.directoryBookmark == expectedOutput,
              body.cacheBookmark == expectedCache,
              Self.isExpectedApplicationSourceSnapshotRelativePath(
                body.sourceSnapshot.relativePath,
                jobID: specification.jobID
              ) else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentBindingMismatch(specification.jobID)
        }
    }

    static func jobToken(from jobID: WorkflowJobID) throws -> String {
        let prefix = "job-"
        guard jobID.rawValue.hasPrefix(prefix) else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentBindingMismatch(jobID)
        }
        let token = String(jobID.rawValue.dropFirst(prefix.count))
        guard UUID(uuidString: token) != nil,
              token == token.lowercased() else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentBindingMismatch(jobID)
        }
        return token
    }

    func persistRequestDocument(
        _ document: WorkflowApplicationRequestDocumentV4
    ) throws {
        let jobID = document.body.specification.jobID
        try verifyRequestDocument(
            document,
            specification: document.body.specification
        )
        let directory = requestDirectoryURL(jobID: jobID)
        try fileSystem.ensureDirectory(directory)
        try fileSystem.withExclusiveLock(at: requestLockURL(jobID: jobID)) {
            transaction in
            let url = requestDocumentURL(jobID: jobID)
            if try transaction.regularFileExists(url) {
                let existing = try loadVerifiedRequestDocument(
                    specification: document.body.specification,
                    transaction: transaction
                )
                guard existing == document else {
                    throw WorkflowApplicationQueueErrorV4
                        .requestDocumentConflict(jobID)
                }
                return
            }
            try transaction.writeNewAtomically(
                codec.canonicalData(document),
                to: url
            )
        }
    }

    func loadVerifiedRequestDocument(
        specification: WorkflowJobSpecification
    ) throws -> WorkflowApplicationRequestDocumentV4 {
        let directory = requestDirectoryURL(jobID: specification.jobID)
        try fileSystem.ensureDirectory(directory)
        return try fileSystem.withExclusiveLock(
            at: requestLockURL(jobID: specification.jobID)
        ) { transaction in
            try loadVerifiedRequestDocument(
                specification: specification,
                transaction: transaction
            )
        }
    }

    func loadVerifiedRequestDocument(
        specification: WorkflowJobSpecification,
        transaction: any WorkflowDurableFileSystem
    ) throws -> WorkflowApplicationRequestDocumentV4 {
        let url = requestDocumentURL(jobID: specification.jobID)
        guard try transaction.regularFileExists(url) else {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentMissing(specification.jobID)
        }
        do {
            let data = try transaction.readRegularFile(
                url,
                maximumBytes: Self.maximumRequestDocumentBytes
            )
            let schema = try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: data
            ).schemaVersion
            let document: WorkflowApplicationRequestDocumentV4
            switch schema {
            case WorkflowApplicationRequestDocumentV4.currentSchemaVersion:
                document = try codec.decodeCanonical(
                    WorkflowApplicationRequestDocumentV4.self,
                    from: data
                )
            case WorkflowApplicationRequestDocumentV2.schemaVersionValue:
                let legacy = try codec.decodeCanonical(
                    WorkflowApplicationRequestDocumentV2.self,
                    from: data
                )
                try verifyLegacyRequestBodyHash(
                    legacy.body,
                    expectedHash: legacy.bodyHash,
                    jobID: specification.jobID
                )
                document = try makeRequestDocument(
                    migrateLegacyRequestBody(
                        legacy.body,
                        jobID: specification.jobID
                    )
                )
                try verifyRequestDocument(
                    document,
                    specification: specification
                )
                try transaction.replaceAtomically(
                    codec.canonicalData(document),
                    at: url
                )
            case WorkflowApplicationRequestDocumentV1.schemaVersionValue:
                let legacy = try codec.decodeCanonical(
                    WorkflowApplicationRequestDocumentV1.self,
                    from: data
                )
                try verifyLegacyRequestBodyHash(
                    legacy.body,
                    expectedHash: legacy.bodyHash,
                    jobID: specification.jobID
                )
                document = try makeRequestDocument(
                    migrateLegacyRequestBody(
                        legacy.body,
                        jobID: specification.jobID
                    )
                )
                try verifyRequestDocument(
                    document,
                    specification: specification
                )
                try transaction.replaceAtomically(
                    codec.canonicalData(document),
                    at: url
                )
            default:
                throw WorkflowApplicationQueueErrorV4
                    .requestDocumentUnsupportedSchema(
                        jobID: specification.jobID,
                        actual: schema,
                        current: WorkflowApplicationRequestDocumentV4
                            .currentSchemaVersion
                    )
            }
            try verifyRequestDocument(document, specification: specification)
            return document
        } catch let error as WorkflowApplicationQueueErrorV4 {
            throw error
        } catch {
            throw WorkflowApplicationQueueErrorV4
                .requestDocumentCorrupt(specification.jobID)
        }
    }

    func queueItem(
        job: WorkflowJobState,
        queueOrdinal: Int?,
        priority: Int32
    ) -> WorkflowApplicationQueueItemV4 {
        do {
            let document = try loadVerifiedRequestDocument(
                specification: job.specification
            )
            let body = document.body
            return WorkflowApplicationQueueItemV4(
                jobID: job.specification.jobID,
                lifecycle: job.lifecycle,
                queueOrdinal: queueOrdinal,
                priority: priority,
                binding: job.specification.binding,
                requestRecordStatus:
                    Self.requiresLegacySourceSnapshotReenqueue(body)
                    ? .legacySourceSnapshotRequiresReenqueue
                    : .ready,
                request: WorkflowApplicationRequestSummaryV4(
                    requestID: job.specification.requestID,
                    outputFileName: job.specification.output.fileName,
                    backendID: body.preparedPlanBinding.resolvedBackendID,
                    targetWidth: body.targetWidth,
                    targetHeight: body.targetHeight,
                    outputCodec: body.outputCodec,
                    preserveAudio: body.preserveAudio,
                    overwriteExistingFile: body.overwriteExistingFile
                )
            )
        } catch WorkflowApplicationQueueErrorV4.requestDocumentMissing {
            return blockedQueueItem(
                job: job,
                queueOrdinal: queueOrdinal,
                priority: priority,
                status: .missing
            )
        } catch WorkflowApplicationQueueErrorV4.requestDocumentBindingMismatch {
            return blockedQueueItem(
                job: job,
                queueOrdinal: queueOrdinal,
                priority: priority,
                status: .bindingMismatch
            )
        } catch {
            return blockedQueueItem(
                job: job,
                queueOrdinal: queueOrdinal,
                priority: priority,
                status: .corrupt
            )
        }
    }

    func blockedQueueItem(
        job: WorkflowJobState,
        queueOrdinal: Int?,
        priority: Int32,
        status: WorkflowApplicationRequestRecordStatusV4
    ) -> WorkflowApplicationQueueItemV4 {
        WorkflowApplicationQueueItemV4(
            jobID: job.specification.jobID,
            lifecycle: job.lifecycle,
            queueOrdinal: queueOrdinal,
            priority: priority,
            binding: job.specification.binding,
            requestRecordStatus: status,
            request: nil
        )
    }

    func makePriorityDocument(
        _ priorities: [WorkflowJobID: Int32]
    ) throws -> WorkflowApplicationPriorityDocumentV4 {
        let entries = priorities.map {
            WorkflowApplicationPriorityEntryV4(
                jobID: $0.key,
                value: $0.value
            )
        }.sorted { $0.jobID < $1.jobID }
        let body = WorkflowApplicationPriorityBodyV4(entries: entries)
        let hash = try WorkflowApplicationPriorityDocumentHashV4(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.Priorities.v1\u{0}",
                data: codec.canonicalData(body)
            )
        )
        return WorkflowApplicationPriorityDocumentV4(
            bodyHash: hash,
            body: body
        )
    }

    func verifiedPriorities(
        _ document: WorkflowApplicationPriorityDocumentV4
    ) throws -> [WorkflowJobID: Int32] {
        guard document.schemaVersion
                == WorkflowApplicationPriorityDocumentV4.currentSchemaVersion,
              document.body.schemaVersion
                == WorkflowApplicationPriorityBodyV4.currentSchemaVersion else {
            throw WorkflowApplicationQueueErrorV4.priorityDocumentCorrupt
        }
        var result: [WorkflowJobID: Int32] = [:]
        for entry in document.body.entries {
            guard entry.value >= WorkflowQueuePriorityV4.minimum,
                  entry.value <= WorkflowQueuePriorityV4.maximum,
                  result.updateValue(entry.value, forKey: entry.jobID) == nil
            else {
                throw WorkflowApplicationQueueErrorV4
                    .priorityDocumentCorrupt
            }
        }
        guard try makePriorityDocument(result) == document else {
            throw WorkflowApplicationQueueErrorV4.priorityDocumentCorrupt
        }
        return result
    }

    func loadPriorities() throws -> [WorkflowJobID: Int32] {
        try fileSystem.withExclusiveLock(at: priorityLockURL()) {
            transaction in
            try loadPriorities(transaction: transaction)
        }
    }

    func loadPriorities(
        transaction: any WorkflowDurableFileSystem
    ) throws -> [WorkflowJobID: Int32] {
        let url = priorityDocumentURL()
        guard try transaction.regularFileExists(url) else { return [:] }
        do {
            let data = try transaction.readRegularFile(
                url,
                maximumBytes: Self.maximumPriorityDocumentBytes
            )
            let document = try codec.decodeCanonical(
                WorkflowApplicationPriorityDocumentV4.self,
                from: data
            )
            return try verifiedPriorities(document)
        } catch let error as WorkflowApplicationQueueErrorV4 {
            throw error
        } catch {
            throw WorkflowApplicationQueueErrorV4.priorityDocumentCorrupt
        }
    }

    func persistPriority(jobID: WorkflowJobID, value: Int32) throws {
        try fileSystem.withExclusiveLock(at: priorityLockURL()) {
            transaction in
            var priorities = try loadPriorities(transaction: transaction)
            priorities[jobID] = value
            let document = try makePriorityDocument(priorities)
            let data = try codec.canonicalData(document)
            let url = priorityDocumentURL()
            if try transaction.regularFileExists(url) {
                try transaction.replaceAtomically(data, at: url)
            } else {
                try transaction.writeNewAtomically(data, to: url)
            }
        }
    }

    func pruneOrphanPriorities(retaining jobIDs: Set<WorkflowJobID>) throws {
        try fileSystem.withExclusiveLock(at: priorityLockURL()) {
            transaction in
            let priorities = try loadPriorities(transaction: transaction)
            let retained = priorities.filter { jobIDs.contains($0.key) }
            guard retained.count != priorities.count else { return }
            let document = try makePriorityDocument(retained)
            let data = try codec.canonicalData(document)
            let url = priorityDocumentURL()
            if try transaction.regularFileExists(url) {
                try transaction.replaceAtomically(data, at: url)
            } else if !retained.isEmpty {
                try transaction.writeNewAtomically(data, to: url)
            }
        }
    }

    func priorityDocumentURL() -> URL {
        rootURL.appendingPathComponent(Self.priorityDocumentName)
    }

    func priorityLockURL() -> URL {
        rootURL.appendingPathComponent(Self.priorityLockName)
    }

    func requestDirectoryURL(jobID: WorkflowJobID) -> URL {
        rootURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobID.rawValue, isDirectory: true)
            .appendingPathComponent("application-request-v4", isDirectory: true)
    }

    func requestLockURL(jobID: WorkflowJobID) -> URL {
        requestDirectoryURL(jobID: jobID)
            .appendingPathComponent("request.lock")
    }

    struct PublicationURLs {
        let directory: URL
        let final: URL
        let staging: URL
        let migration: URL
    }

    func publicationToken(
        jobBinding: WorkflowJobBinding,
        checkpoint: WorkflowCheckpointDocumentV4
    ) -> String {
        let material = [
            jobBinding.jobID.rawValue,
            jobBinding.requestID.rawValue,
            jobBinding.outputContractID.rawValue,
            checkpoint.body.checkpointID.rawValue,
            checkpoint.bodyHash.rawValue,
        ].joined(separator: "\u{0}")
        return String(WorkflowV4Validation.domainSeparatedSHA256(
            domain: "Mirmir.WorkflowApplication.PublicationToken.v1\u{0}",
            data: Data(material.utf8)
        ).prefix(40))
    }

    func publicationURLs(
        intent: WorkflowApplicationPublicationIntentV4,
        activated: WorkflowActivatedUpscaleRequestV4
    ) throws -> PublicationURLs {
        let body = intent.body
        let final = activated.request.outputURL.standardizedFileURL
        let directory = final.deletingLastPathComponent()
        guard body.jobBinding == activated.specification.binding,
              body.outputContractID
                == activated.preparedPlanBinding.outputContractID,
              body.finalFileName == activated.specification.output.fileName,
              final.lastPathComponent == body.finalFileName.rawValue,
              body.overwriteExistingFile
                == activated.request.overwriteExistingFile,
              WorkflowV4Validation.isMirmirPartialFileName(
                  body.stagingFileName
              ),
              WorkflowV4Validation.isMirmirPartialFileName(
                  body.migrationTemporaryFileName
              ),
              body.stagingFileName != body.migrationTemporaryFileName else {
            throw WorkflowApplicationQueueErrorV4
                .publicationBindingMismatch(intent.jobID)
        }
        let staging = directory.appendingPathComponent(
            body.stagingFileName,
            isDirectory: false
        ).standardizedFileURL
        let migration = directory.appendingPathComponent(
            body.migrationTemporaryFileName,
            isDirectory: false
        ).standardizedFileURL
        guard staging.deletingLastPathComponent() == directory,
              migration.deletingLastPathComponent() == directory,
              staging != final,
              migration != final else {
            throw WorkflowApplicationQueueErrorV4
                .publicationBindingMismatch(intent.jobID)
        }
        return PublicationURLs(
            directory: directory,
            final: final,
            staging: staging,
            migration: migration
        )
    }

    func verifyPublicationAACTranslation(
        _ verification: WorkflowApplicationMigrationVerificationV4,
        activated: WorkflowActivatedUpscaleRequestV4,
        outputURL: URL
    ) async throws {
        guard try verification.metadataIsConformant(),
              let translation = verification.aacGaplessMetadataTranslation,
              activated.request.preserveAudio else {
            throw WorkflowApplicationQueueErrorV4.publicationVerificationInvalid
        }
        let processedVideo = translation.identifiedPlan.plan.tracks.filter {
            $0.source.kind == .video && $0.action == .process
        }
        guard processedVideo.count == 1,
              let formats = processedVideo.first?.expectedOutput?.formatDescriptors,
              formats.count == 1, let format = formats.first else {
            throw WorkflowApplicationQueueErrorV4.publicationVerificationInvalid
        }
        let material = try WorkflowApplicationOutputContractMaterialV4(
            ashPlanSHA256: ASHSHA256V4(activated.preparedPlanBinding.planID.rawValue),
            trackPlanSHA256: translation.identifiedPlan.planSHA256,
            encodedFormatDescriptor: format, request: activated.request)
        let observedContract = try WorkflowOutputContractID(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.OutputContract.v1\0",
                data: codec.canonicalData(material)))
        guard observedContract == activated.preparedPlanBinding.outputContractID else {
            throw WorkflowApplicationQueueErrorV4.publicationVerificationInvalid
        }
        try await translation.verifyMetadata(sourceURL: activated.request.inputURL,
            outputURL: outputURL)
        try activated.revalidateAll()
    }

    func verifyPublicationIntent(
        _ intent: WorkflowApplicationPublicationIntentV4,
        specification: WorkflowJobSpecification,
        checkpoint: WorkflowCheckpointDocumentV4,
        activated: WorkflowActivatedUpscaleRequestV4
    ) throws {
        guard intent.body.jobBinding == specification.binding,
              intent.body.checkpointID == checkpoint.body.checkpointID,
              intent.body.checkpointDocumentHash == checkpoint.bodyHash,
              intent.body.outputContractID == specification.output.contractID,
              intent.body.finalFileName == specification.output.fileName,
              intent.body.overwriteExistingFile
                == activated.request.overwriteExistingFile else {
            throw WorkflowApplicationQueueErrorV4
                .publicationBindingMismatch(specification.jobID)
        }
        _ = try publicationURLs(intent: intent, activated: activated)
    }

    func makePublicationIntent(
        _ body: WorkflowApplicationPublicationIntentBodyV4
    ) throws -> WorkflowApplicationPublicationIntentV4 {
        WorkflowApplicationPublicationIntentV4(
            bodyHash: try WorkflowApplicationPublicationIntentHashV4(
                WorkflowV4Validation.domainSeparatedSHA256(
                    domain: "Mirmir.WorkflowApplication.PublicationIntent.v1\u{0}",
                    data: codec.canonicalData(body)
                )
            ),
            body: body
        )
    }

    func makePublicationStage(
        _ body: WorkflowApplicationPublicationStageBodyV4
    ) throws -> WorkflowApplicationPublicationStageV4 {
        WorkflowApplicationPublicationStageV4(
            bodyHash: try WorkflowApplicationPublicationStageHashV4(
                WorkflowV4Validation.domainSeparatedSHA256(
                    domain: "Mirmir.WorkflowApplication.PublicationStage.v1\u{0}",
                    data: codec.canonicalData(body)
                )
            ),
            body: body
        )
    }

    func makePublicationReceipt(
        _ body: WorkflowApplicationPublicationReceiptBodyV4
    ) throws -> WorkflowApplicationPublicationReceiptV4 {
        WorkflowApplicationPublicationReceiptV4(
            bodyHash: try WorkflowApplicationPublicationReceiptHashV4(
                WorkflowV4Validation.domainSeparatedSHA256(
                    domain: "Mirmir.WorkflowApplication.PublicationReceipt.v1\u{0}",
                    data: codec.canonicalData(body)
                )
            ),
            body: body
        )
    }

    func requirePublicationState(
        intent: WorkflowApplicationPublicationIntentV4,
        transaction: any WorkflowDurableFileSystem
    ) throws -> WorkflowApplicationPublicationStateV4 {
        guard let state = try loadPublicationState(
            jobID: intent.jobID,
            transaction: transaction
        ), state.intent == intent else {
            throw WorkflowApplicationQueueErrorV4
                .publicationDocumentConflict(intent.jobID)
        }
        return state
    }

    func loadPublicationState(
        jobID: WorkflowJobID,
        transaction: any WorkflowDurableFileSystem
    ) throws -> WorkflowApplicationPublicationStateV4? {
        let intentURL = publicationIntentURL(jobID: jobID)
        let stageURL = publicationStageURL(jobID: jobID)
        let receiptURL = publicationReceiptURL(jobID: jobID)
        let intentExists = try transaction.regularFileExists(intentURL)
        let stageExists = try transaction.regularFileExists(stageURL)
        let receiptExists = try transaction.regularFileExists(receiptURL)
        guard intentExists else {
            guard !stageExists, !receiptExists else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationDocumentCorrupt(jobID)
            }
            return nil
        }
        do {
            let intent = try codec.decodeCanonical(
                WorkflowApplicationPublicationIntentV4.self,
                from: transaction.readRegularFile(
                    intentURL,
                    maximumBytes: Self.maximumPublicationDocumentBytes
                )
            )
            guard intent.schemaVersion
                    == WorkflowApplicationPublicationIntentV4
                        .currentSchemaVersion,
                  intent.body.schemaVersion
                    == WorkflowApplicationPublicationIntentBodyV4
                        .currentSchemaVersion,
                  intent.body.jobBinding.jobID == jobID,
                  intent.body.outputContractID
                    == intent.body.jobBinding.outputContractID,
                  intent.body.finalFileName.rawValue
                    != intent.body.stagingFileName,
                  intent.body.finalFileName.rawValue
                    != intent.body.migrationTemporaryFileName,
                  intent.body.stagingFileName
                    != intent.body.migrationTemporaryFileName,
                  WorkflowV4Validation.isMirmirPartialFileName(
                      intent.body.stagingFileName
                  ),
                  WorkflowV4Validation.isMirmirPartialFileName(
                      intent.body.migrationTemporaryFileName
                  ),
                  intent.body.overwriteExistingFile
                    || intent.body.originalDestination == nil,
                  try makePublicationIntent(intent.body) == intent else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationDocumentCorrupt(jobID)
            }

            let stage: WorkflowApplicationPublicationStageV4?
            if stageExists {
                let decoded = try codec.decodeCanonical(
                    WorkflowApplicationPublicationStageV4.self,
                    from: transaction.readRegularFile(
                        stageURL,
                        maximumBytes: Self.maximumPublicationDocumentBytes
                    )
                )
                let verification = decoded.body.migrationVerification
                guard decoded.schemaVersion
                        == WorkflowApplicationPublicationStageV4
                            .currentSchemaVersion,
                      decoded.body.schemaVersion
                        == WorkflowApplicationPublicationStageBodyV4
                            .currentSchemaVersion,
                      decoded.body.intentHash == intent.bodyHash,
                      decoded.body.jobBinding == intent.body.jobBinding,
                      try verification.metadataIsConformant(),
                      verification.sourceChapterMetadataSHA256
                        == verification.outputChapterMetadataSHA256,
                      decoded.body.stagedFile.byteCount > 0,
                      !verification.trackResults.isEmpty,
                      Set(verification.trackResults.map(\.trackID)).count
                        == verification.trackResults.count,
                      verification.trackResults.allSatisfy({
                          $0.migratedSampleCount >= 0
                      }),
                      verification.trackResults
                        == verification.trackResults.sorted(by: {
                            $0.trackID < $1.trackID
                        }),
                      try makePublicationStage(decoded.body) == decoded else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationDocumentCorrupt(jobID)
                }
                stage = decoded
            } else {
                stage = nil
            }

            let receipt: WorkflowApplicationPublicationReceiptV4?
            if receiptExists {
                guard let stage else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationDocumentCorrupt(jobID)
                }
                let decoded = try codec.decodeCanonical(
                    WorkflowApplicationPublicationReceiptV4.self,
                    from: transaction.readRegularFile(
                        receiptURL,
                        maximumBytes: Self.maximumPublicationDocumentBytes
                    )
                )
                let methodIsValid: Bool
                switch decoded.body.method {
                case .exclusiveRename:
                    methodIsValid = intent.body.originalDestination == nil
                        && decoded.body.displacedDestination == nil
                case .atomicSwap:
                    methodIsValid = intent.body.originalDestination != nil
                        && decoded.body.displacedDestination
                            == intent.body.originalDestination
                case .recoveredPublishedFile:
                    methodIsValid = decoded.body.displacedDestination == nil
                        || decoded.body.displacedDestination
                            == intent.body.originalDestination
                }
                guard decoded.schemaVersion
                        == WorkflowApplicationPublicationReceiptV4
                            .currentSchemaVersion,
                      decoded.body.schemaVersion
                        == WorkflowApplicationPublicationReceiptBodyV4
                            .currentSchemaVersion,
                      decoded.body.stageHash == stage.bodyHash,
                      decoded.body.jobBinding == intent.body.jobBinding,
                      decoded.body.finalFile == stage.body.stagedFile,
                      methodIsValid,
                      try makePublicationReceipt(decoded.body) == decoded else {
                    throw WorkflowApplicationQueueErrorV4
                        .publicationDocumentCorrupt(jobID)
                }
                receipt = decoded
            } else {
                receipt = nil
            }
            return WorkflowApplicationPublicationStateV4(
                intent: intent,
                stage: stage,
                receipt: receipt
            )
        } catch let error as WorkflowApplicationQueueErrorV4 {
            throw error
        } catch {
            throw WorkflowApplicationQueueErrorV4
                .publicationDocumentCorrupt(jobID)
        }
    }

    func observePublicationFileIfPresent(
        at url: URL
    ) throws -> WorkflowApplicationPublicationFileV4? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw publicationFilesystemError("lstat", url: url)
        }
        return try observePublicationFile(at: url)
    }

    func observePublicationFile(
        at url: URL
    ) throws -> WorkflowApplicationPublicationFileV4 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw publicationFilesystemError("open", url: url)
        }
        defer { _ = Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw publicationFilesystemError("fstat-before", url: url)
        }
        guard (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0 else {
            throw WorkflowApplicationQueueErrorV4
                .publicationStageConflict(url.path)
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw publicationFilesystemError("read", url: url)
            }
            hasher.update(data: Data(buffer[..<Int(count)]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw publicationFilesystemError("fstat-after", url: url)
        }
        var pathMetadata = stat()
        guard lstat(url.path, &pathMetadata) == 0,
              publicationStatIsStable(before, after),
              publicationStatIsStable(after, pathMetadata) else {
            throw WorkflowApplicationQueueErrorV4
                .publicationStageConflict(url.path)
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return WorkflowApplicationPublicationFileV4(
            identity: WorkflowFileIdentityV4(
                device: UInt64(after.st_dev),
                fileID: UInt64(after.st_ino)
            ),
            byteCount: UInt64(after.st_size),
            sha256: try ASHSHA256V4(digest)
        )
    }

    func publicationStatIsStable(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    func removePublicationFileIfPresent(at url: URL) throws {
        guard try observePublicationFileIfPresent(at: url) != nil else { return }
        guard Darwin.unlink(url.path) == 0 else {
            throw publicationFilesystemError("unlink", url: url)
        }
        try synchronizePublicationDirectory(url.deletingLastPathComponent())
    }

    func cleanupDisplacedPublicationFile(
        at stagingURL: URL,
        intent: WorkflowApplicationPublicationIntentV4,
        receipt: WorkflowApplicationPublicationReceiptV4
    ) throws {
        let observed = try observePublicationFileIfPresent(at: stagingURL)
        if let displaced = receipt.body.displacedDestination {
            guard observed == nil || observed == displaced,
                  displaced == intent.body.originalDestination else {
                throw WorkflowApplicationQueueErrorV4
                    .publicationStageConflict(stagingURL.path)
            }
            if observed != nil {
                try removePublicationFileIfPresent(at: stagingURL)
            }
        } else if observed != nil {
            throw WorkflowApplicationQueueErrorV4
                .publicationStageConflict(stagingURL.path)
        }
    }

    func exclusiveRenamePublicationFile(
        stagingURL: URL,
        finalURL: URL
    ) throws {
        guard renameatx_np(
            AT_FDCWD,
            stagingURL.path,
            AT_FDCWD,
            finalURL.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw publicationFilesystemError(
                "rename-exclusive",
                url: finalURL
            )
        }
    }

    func atomicSwapPublicationFiles(
        stagingURL: URL,
        finalURL: URL
    ) throws {
        guard renameatx_np(
            AT_FDCWD,
            stagingURL.path,
            AT_FDCWD,
            finalURL.path,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw publicationFilesystemError("rename-swap", url: finalURL)
        }
    }

    func synchronizePublicationDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY
        )
        guard descriptor >= 0 else {
            throw publicationFilesystemError("open-directory", url: directory)
        }
        defer { _ = Darwin.close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else {
            throw publicationFilesystemError("fsync-directory", url: directory)
        }
    }

    func publicationFilesystemError(
        _ operation: String,
        url: URL
    ) -> WorkflowApplicationQueueErrorV4 {
        .publicationFilesystemFailure(
            operation: operation,
            path: url.path,
            code: errno
        )
    }

    func publicationDirectoryURL(jobID: WorkflowJobID) -> URL {
        requestDirectoryURL(jobID: jobID)
            .appendingPathComponent("publication-v4", isDirectory: true)
    }

    func publicationIntentURL(jobID: WorkflowJobID) -> URL {
        publicationDirectoryURL(jobID: jobID)
            .appendingPathComponent(Self.publicationIntentName)
    }

    func publicationStageURL(jobID: WorkflowJobID) -> URL {
        publicationDirectoryURL(jobID: jobID)
            .appendingPathComponent(Self.publicationStageName)
    }

    func publicationReceiptURL(jobID: WorkflowJobID) -> URL {
        publicationDirectoryURL(jobID: jobID)
            .appendingPathComponent(Self.publicationReceiptName)
    }

    func publicationLockURL(jobID: WorkflowJobID) -> URL {
        publicationDirectoryURL(jobID: jobID)
            .appendingPathComponent(Self.publicationLockName)
    }
}
