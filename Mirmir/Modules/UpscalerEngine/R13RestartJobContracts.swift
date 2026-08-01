import Foundation

enum R13RestartJobError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidSourceByteCount
    case invalidFrameCount(Int)
    case invalidFrameIndex(expected: Int, actual: Int)
    case invalidOutputGeometry(width: Int, height: Int)
    case invalidPixelFormat(String)
    case invalidRelativePath(String)
    case invalidByteCount(field: String)
    case jobAlreadyExists(String)
    case jobMissing(String)
    case initializationCleanupFailed(
        jobID: String,
        triggerReason: String,
        cleanupReason: String
    )
    case immutableCoreMismatch
    case sourceDrift(expected: R13RestartSourceIdentity, observed: R13RestartSourceIdentity)
    case staleHead(expected: String, observed: String)
    case nonCanonicalDocument(String)
    case schemaMismatch(document: String)
    case recordChainMismatch(sequence: Int)
    case headMismatch
    case cachedFrameMissing(index: Int)
    case cachedFrameCorrupt(index: Int)
    case cachedFrameGeometryMismatch(index: Int)
    case routingDecisionRequired(index: Int)
    case unexpectedRoutingDecision(index: Int)
    case invalidRoutingDecision(index: Int)
    case incompleteJob(committed: Int, expected: Int)
    case prepublicationReceiptConflict
    case reauthorizationRequired(role: R13BookmarkRole)
    case bookmarkCreationFailed(role: R13BookmarkRole)
    case bookmarkResolutionFailed(role: R13BookmarkRole)
    case securityScopeDenied(role: R13BookmarkRole)
    case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)
    case arithmeticOverflow(field: String)
    case unsafeFilesystemEntry(String)
    case fileTooLarge(path: String, maximumBytes: Int)
    case ioFailure(operation: String)
}

struct R13RestartSourceIdentity: Codable, Hashable, Sendable {
    let sha256: String
    let byteCount: UInt64

    init(sha256: String, byteCount: UInt64) throws {
        self.sha256 = try R13RestartValidation.sha256(
            sha256,
            field: "source_sha256"
        )
        guard byteCount > 0 else {
            throw R13RestartJobError.invalidSourceByteCount
        }
        self.byteCount = byteCount
    }

    func validate() throws {
        _ = try R13RestartSourceIdentity(
            sha256: sha256,
            byteCount: byteCount
        )
    }
}

struct R13RestartProcessingIdentity: Codable, Hashable, Sendable {
    static let releaseIdentityComponentPrefix = "release-"

    let requestedMode: String
    let effectiveMode: String
    let routeIdentity: String
    let backendIdentity: String
    let backendRevision: String

    static func releaseIdentityComponent(
        sha256: String
    ) throws -> String {
        let validatedSHA256 = try R13RestartValidation.sha256(
            sha256,
            field: "release_identity_sha256"
        )
        return Self.releaseIdentityComponentPrefix + validatedSHA256
    }

    static func isValidReleaseIdentityComponent(
        _ value: String
    ) -> Bool {
        guard value.hasPrefix(releaseIdentityComponentPrefix) else {
            return false
        }
        return (try? R13RestartValidation.sha256(
            String(value.dropFirst(releaseIdentityComponentPrefix.count)),
            field: "release_identity_sha256"
        )) != nil
    }

    var requiresPerFrameRoutingDecision: Bool {
        [
            R13ReleaseOrchestrationKind.automatic.backendID,
            R13ReleaseOrchestrationKind.quality.backendID,
            R13ReleaseOrchestrationKind.fast.backendID
        ].contains(backendIdentity)
    }

    init(
        requestedMode: String,
        effectiveMode: String,
        routeIdentity: String,
        backendIdentity: String,
        backendRevision: String
    ) throws {
        self.requestedMode = try R13RestartValidation.identity(
            requestedMode,
            field: "requested_mode"
        )
        self.effectiveMode = try R13RestartValidation.identity(
            effectiveMode,
            field: "effective_mode"
        )
        self.routeIdentity = try R13RestartValidation.identity(
            routeIdentity,
            field: "route_identity"
        )
        self.backendIdentity = try R13RestartValidation.identity(
            backendIdentity,
            field: "backend_identity"
        )
        self.backendRevision = try R13RestartValidation.identity(
            backendRevision,
            field: "backend_revision"
        )
    }

    func validate() throws {
        _ = try R13RestartProcessingIdentity(
            requestedMode: requestedMode,
            effectiveMode: effectiveMode,
            routeIdentity: routeIdentity,
            backendIdentity: backendIdentity,
            backendRevision: backendRevision
        )
    }
}

struct R13RestartOutputIdentity: Codable, Hashable, Sendable {
    static let nv12VideoRangePixelFormat = "420v"
    static let p010VideoRangePixelFormat = "x420"
    static let bgraPixelFormat = "BGRA"

    let width: Int
    let height: Int
    let pixelFormat: String
    let codec: String
    let audioPolicy: String
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let chromaLocation: String
    let alphaMode: String?
    let masteringDisplaySHA256: String?
    let contentLightLevelSHA256: String?

    init(
        width: Int,
        height: Int,
        pixelFormat: String = Self.nv12VideoRangePixelFormat,
        codec: String,
        audioPolicy: String,
        colorPrimaries: String = "ITU_R_709_2",
        transferFunction: String = "ITU_R_709_2",
        yCbCrMatrix: String = "ITU_R_709_2",
        chromaLocation: String = "left",
        alphaMode: String? = nil,
        masteringDisplaySHA256: String? = nil,
        contentLightLevelSHA256: String? = nil
    ) throws {
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2) else {
            throw R13RestartJobError.invalidOutputGeometry(
                width: width,
                height: height
            )
        }
        _ = try R13CachedPixelFormat.pixelFormat(pixelFormat)
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.codec = try R13RestartValidation.identity(codec, field: "codec")
        self.audioPolicy = try R13RestartValidation.identity(
            audioPolicy,
            field: "audio_policy"
        )
        self.colorPrimaries = try R13RestartValidation.identity(
            colorPrimaries,
            field: "color_primaries"
        )
        self.transferFunction = try R13RestartValidation.identity(
            transferFunction,
            field: "transfer_function"
        )
        self.yCbCrMatrix = try R13RestartValidation.identity(
            yCbCrMatrix,
            field: "ycbcr_matrix"
        )
        self.chromaLocation = try R13RestartValidation.identity(
            chromaLocation,
            field: "chroma_location"
        )
        self.alphaMode = try alphaMode.map {
            try R13RestartValidation.identity(
                $0,
                field: "alpha_mode"
            )
        }
        self.masteringDisplaySHA256 =
            try masteringDisplaySHA256.map {
                try R13RestartValidation.sha256(
                    $0,
                    field: "mastering_display_sha256"
                )
            }
        self.contentLightLevelSHA256 =
            try contentLightLevelSHA256.map {
                try R13RestartValidation.sha256(
                    $0,
                    field: "content_light_level_sha256"
                )
            }
    }

    func validate() throws {
        _ = try R13RestartOutputIdentity(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            codec: codec,
            audioPolicy: audioPolicy,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            chromaLocation: chromaLocation,
            alphaMode: alphaMode,
            masteringDisplaySHA256: masteringDisplaySHA256,
            contentLightLevelSHA256: contentLightLevelSHA256
        )
    }
}

struct R13RestartJobCore: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobID: String
    let source: R13RestartSourceIdentity
    let processing: R13RestartProcessingIdentity
    let output: R13RestartOutputIdentity
    let totalFrameCount: Int

    init(
        jobID: String,
        source: R13RestartSourceIdentity,
        processing: R13RestartProcessingIdentity,
        output: R13RestartOutputIdentity,
        totalFrameCount: Int
    ) throws {
        guard totalFrameCount > 0 else {
            throw R13RestartJobError.invalidFrameCount(totalFrameCount)
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.jobID = try R13RestartValidation.jobID(jobID)
        self.source = source
        self.processing = processing
        self.output = output
        self.totalFrameCount = totalFrameCount
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw R13RestartJobError.schemaMismatch(document: "job_core")
        }
        _ = try R13RestartValidation.jobID(jobID)
        try source.validate()
        try processing.validate()
        try output.validate()
        guard totalFrameCount > 0 else {
            throw R13RestartJobError.invalidFrameCount(totalFrameCount)
        }
    }
}

enum R13PartialMediaReusePolicy: String, Codable, Hashable, Sendable {
    case forbidden
}

enum R13RestartFrameDisposition: Equatable, Sendable {
    case replayVerifiedCache
    case runBackend
}

struct R13RestartRecordReference: Codable, Hashable, Sendable {
    let sequence: Int
    let relativePath: String
    let recordSHA256: String

    init(sequence: Int, relativePath: String, recordSHA256: String) throws {
        guard sequence >= 0 else {
            throw R13RestartJobError.invalidFrameIndex(
                expected: 0,
                actual: sequence
            )
        }
        self.sequence = sequence
        self.relativePath = try R13RestartValidation.relativePath(relativePath)
        self.recordSHA256 = try R13RestartValidation.sha256(
            recordSHA256,
            field: "record_sha256"
        )
    }

    func validate() throws {
        _ = try R13RestartRecordReference(
            sequence: sequence,
            relativePath: relativePath,
            recordSHA256: recordSHA256
        )
    }
}

struct R13RestartJobHead: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let coreSHA256: String
    let committedFrameCount: Int
    let headSHA256: String

    init(
        coreSHA256: String,
        committedFrameCount: Int,
        headSHA256: String
    ) throws {
        guard committedFrameCount >= 0 else {
            throw R13RestartJobError.invalidFrameCount(
                committedFrameCount
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.coreSHA256 = try R13RestartValidation.sha256(
            coreSHA256,
            field: "core_sha256"
        )
        self.committedFrameCount = committedFrameCount
        self.headSHA256 = try R13RestartValidation.sha256(
            headSHA256,
            field: "head_sha256"
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw R13RestartJobError.schemaMismatch(document: "job_head")
        }
        _ = try R13RestartJobHead(
            coreSHA256: coreSHA256,
            committedFrameCount: committedFrameCount,
            headSHA256: headSHA256
        )
    }
}

struct R13RestartAttemptPlan: Equatable, Sendable {
    let jobID: String
    let coreSHA256: String
    let headSHA256: String
    let totalFrameCount: Int
    let verifiedCachedRecords: [R13RestartRecordReference]
    let writerStartFrameIndex: Int
    let partialMediaReusePolicy: R13PartialMediaReusePolicy

    var verifiedCachedPrefixCount: Int {
        verifiedCachedRecords.count
    }

    var backendStartFrameIndex: Int {
        verifiedCachedPrefixCount
    }

    var requiresFreshMediaWriter: Bool {
        writerStartFrameIndex == 0 && partialMediaReusePolicy == .forbidden
    }

    func disposition(forFrameAt index: Int) throws -> R13RestartFrameDisposition {
        guard (0..<totalFrameCount).contains(index) else {
            throw R13RestartJobError.invalidFrameIndex(
                expected: totalFrameCount,
                actual: index
            )
        }
        return index < verifiedCachedPrefixCount
            ? .replayVerifiedCache
            : .runBackend
    }
}

struct R13PrepublicationReceipt: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobID: String
    let coreSHA256: String
    let headSHA256: String
    let frameCount: Int
    let writerStartFrameIndex: Int
    let partialMediaReusePolicy: R13PartialMediaReusePolicy
    let outputMediaSHA256: String
    let outputMediaByteCount: UInt64
    let receiptSHA256: String
}
