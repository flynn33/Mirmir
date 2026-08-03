import AVFoundation
import CoreMedia
import Darwin
import Foundation

// MARK: - Prepared-plan authority

enum WorkflowApplicationRequestDocumentDigestPurposeV4:
    WorkflowDigestPurpose
{}

enum WorkflowApplicationPriorityDocumentDigestPurposeV4:
    WorkflowDigestPurpose
{}

typealias WorkflowApplicationRequestDocumentHashV4 =
    WorkflowDigest<WorkflowApplicationRequestDocumentDigestPurposeV4>
typealias WorkflowApplicationPriorityDocumentHashV4 =
    WorkflowDigest<WorkflowApplicationPriorityDocumentDigestPurposeV4>

enum WorkflowApplicationRequestEnvelopeSchemaV4 {
    static let legacy: UInt16 = 1
    static let current: UInt16 = 2
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
    case dispatchJobMismatch(expected: WorkflowJobID, actual: WorkflowJobID)
    case preparedPlanChanged(WorkflowJobID)
    case terminalCheckpointMissing(WorkflowJobID)
    case workingArtifactConflict(String)
    case unsafeWorkingArtifact(String)
    case priorityDocumentCorrupt
    case jobNotQueued(WorkflowJobID)

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
        case .dispatchJobMismatch(let expected, let actual):
            "The dispatcher selected \(actual), expected \(expected)."
        case .preparedPlanChanged(let jobID):
            "The revalidated prepared plan for \(jobID) no longer matches its durable binding."
        case .terminalCheckpointMissing(let jobID):
            "The durable job \(jobID) has no compatible terminal segment checkpoint."
        case .workingArtifactConflict(let path):
            "A durable working artifact already exists at \(path)."
        case .unsafeWorkingArtifact(let path):
            "A durable working artifact is unsafe: \(path)."
        case .priorityDocumentCorrupt:
            "The durable application queue priority document is noncanonical or hash-invalid."
        case .jobNotQueued(let jobID):
            "The durable workflow job \(jobID) is not currently queued."
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
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let specification: WorkflowJobSpecification
    let cacheBookmark: WorkflowBookmarkReference
    let preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4
    let targetWidth: Int
    let targetHeight: Int
    let outputCodec: OutputCodec
    let preserveAudio: Bool
    let overwriteExistingFile: Bool

    init(
        specification: WorkflowJobSpecification,
        cacheBookmark: WorkflowBookmarkReference,
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

/// Canonical deployed request envelope accepted only as an atomic migration
/// input.  Its hashed body is immutable and is revalidated before the v2
/// envelope replaces it.
private struct WorkflowApplicationRequestDocumentV1:
    Codable,
    Equatable,
    Sendable
{
    static let schemaVersionValue =
        WorkflowApplicationRequestEnvelopeSchemaV4.legacy

    let schemaVersion: UInt16
    let bodyHash: WorkflowApplicationRequestDocumentHashV4
    fileprivate let body: WorkflowApplicationRequestBodyV4

    fileprivate init(
        bodyHash: WorkflowApplicationRequestDocumentHashV4,
        body: WorkflowApplicationRequestBodyV4
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
                WorkflowApplicationRequestBodyV4.self,
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
    let bookmarkReceipts: [WorkflowBookmarkActivationReceiptV4]

    private let accessSet: WorkflowActivatedBookmarkAccessSetV4

    fileprivate init(
        specification: WorkflowJobSpecification,
        request: UpscaleRequest,
        cacheDirectoryURL: URL,
        preparedPlanBinding: WorkflowVerifiedPreparedPlanBindingV4,
        accessSet: WorkflowActivatedBookmarkAccessSetV4
    ) {
        self.specification = specification
        self.request = request
        self.cacheDirectoryURL = cacheDirectoryURL
        self.preparedPlanBinding = preparedPlanBinding
        bookmarkReceipts = accessSet.receipts
        self.accessSet = accessSet
    }

    func revalidateAll() throws {
        try accessSet.revalidateAll()
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
    private static let maximumTargetDimension = 131_072
    private static let requestDocumentName = "request-v1.json"
    private static let priorityDocumentName = "application-priorities-v1.json"
    private static let priorityLockName = "application-priorities.lock"

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
            preparedPlanBinding: binding,
            targetWidth: request.targetWidth,
            targetHeight: request.targetHeight,
            outputCodec: request.outputCodec,
            preserveAudio: request.preserveAudio,
            overwriteExistingFile: request.overwriteExistingFile
        )
        let requestDocument = try makeRequestDocument(body)

        // Bookmark authority is durably registered before the enqueue event is
        // published. A failure at either earlier step leaves no dispatchable
        // job; replaying an exact document remains idempotent.
        let bookmarkDocument = try await bookmarkStore.register(
            specification: specification,
            registrations: [
                WorkflowBookmarkRegistrationV4(
                    role: .inputFile,
                    authorizationReference: sourceBookmark,
                    url: request.inputURL
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
        // Priority is committed before the enqueue event. Therefore any job
        // visible in the journal already has its requested dispatch priority,
        // even if the process is killed at the next instruction. A priority
        // entry whose enqueue never becomes visible is harmless and is pruned
        // during launch reconciliation.
        try persistPriority(jobID: jobID, value: priority)
        let append = try await coordinator.append(
            WorkflowEventDraft(
                eventID: WorkflowEventID("enqueue-event-\(token)"),
                commandID: WorkflowCommandID("enqueue-command-\(token)"),
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
                return .active(
                    WorkflowActivatedUpscaleRequestV4(
                        specification: job.specification,
                        request: request,
                        cacheDirectoryURL: cache,
                        preparedPlanBinding: body.preparedPlanBinding,
                        accessSet: accessSet
                    )
                )
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
        try await dispatcher.resume(
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
        outputContractID: WorkflowOutputContractID
    ) async throws -> WorkflowCheckpointDocumentV4? {
        try await coordinator.loadCompatibleCheckpoint(
            jobID: jobID,
            expectedCodecSettingsHash: outputContractID
        )
    }

    func commitApplicationCheckpointBoundary(
        dispatch: WorkflowQueueDispatchReceiptV4,
        specification: WorkflowJobSpecification,
        segment: DeterministicV4MediaSegmentResultV4,
        outputContractID: WorkflowOutputContractID,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        trackProgress: [WorkflowTrackProgressV4],
        temporalCheckpoint: Data
    ) async throws -> WorkflowApplicationBoundaryCheckpointV4 {
        let current = try await dispatcher.refreshedDispatch(dispatch)
        guard current.claim.jobID == specification.jobID,
              current.claim.jobBinding == specification.binding else {
            throw WorkflowApplicationQueueErrorV4.dispatchJobMismatch(
                expected: specification.jobID,
                actual: current.claim.jobID
            )
        }
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: rootURL)
        let identity = try await AVFoundationSegmentProbeV4().probe(
            url: segment.segmentURL
        )
        let existingSegments = previousCheckpoint?.body.segments ?? []
        guard previousCheckpoint?.body.compatibility == nil
                || previousCheckpoint?.body.compatibility
                    == WorkflowCheckpointCompatibilityBindingV4(
                        specification: specification
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
                codecSettingsHash: outputContractID,
                trackProgress: trackProgress,
                committedAt: clock.now(),
                lastCompletedInputOrdinal:
                    segment.lastCompletedInputOrdinal
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
        destinationURL: URL,
        overwriteExistingFile: Bool
    ) async throws -> AVFoundationSegmentAssemblyResultV4 {
        try await AVFoundationSegmentAssemblerV4().assemble(.init(
            artifactRootURL: rootURL,
            segments: checkpoint.body.segments,
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

// MARK: - Validation and persistence

private extension WorkflowApplicationQueueV4 {
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
              body.specification.runtimeBinding == binding.runtimeBinding else {
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
              body.cacheBookmark == expectedCache else {
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
            case WorkflowApplicationRequestDocumentV1.schemaVersionValue:
                let legacy = try codec.decodeCanonical(
                    WorkflowApplicationRequestDocumentV1.self,
                    from: data
                )
                let expected = try makeRequestDocument(legacy.body)
                guard expected.bodyHash == legacy.bodyHash else {
                    throw WorkflowApplicationQueueErrorV4
                        .requestDocumentCorrupt(specification.jobID)
                }
                document = expected
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
                requestRecordStatus: .ready,
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
}
