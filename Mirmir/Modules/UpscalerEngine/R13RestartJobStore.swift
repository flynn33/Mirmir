import Foundation

// Atomic frame -> record -> head publication and its replay validator remain
// co-located so the two sides of the persistence contract cannot drift.
// swiftlint:disable file_length

struct R13CachedFrameArtifactIdentity: Codable, Hashable, Sendable {
    let relativePath: String
    let encoding: R13FrameCacheEncoding
    let artifactSHA256: String
    let rawSHA256: String
    let artifactByteCount: UInt64
    let rawByteCount: UInt64
    let width: Int
    let height: Int

    init(
        relativePath: String,
        encoding: R13FrameCacheEncoding,
        artifactSHA256: String,
        rawSHA256: String,
        artifactByteCount: UInt64,
        rawByteCount: UInt64,
        width: Int,
        height: Int
    ) throws {
        let counts = try R13NV12Frame.expectedPlaneByteCounts(
            width: width,
            height: height
        )
        guard artifactByteCount > 0 else {
            throw R13RestartJobError.invalidByteCount(
                field: "artifact_byte_count"
            )
        }
        guard rawByteCount == UInt64(counts.total) else {
            throw R13RestartJobError.invalidByteCount(
                field: "raw_byte_count"
            )
        }
        self.relativePath = try R13RestartValidation.relativePath(
            relativePath
        )
        self.encoding = encoding
        self.artifactSHA256 = try R13RestartValidation.sha256(
            artifactSHA256,
            field: "artifact_sha256"
        )
        self.rawSHA256 = try R13RestartValidation.sha256(
            rawSHA256,
            field: "raw_sha256"
        )
        self.artifactByteCount = artifactByteCount
        self.rawByteCount = rawByteCount
        self.width = width
        self.height = height
    }

    func validate() throws {
        _ = try R13CachedFrameArtifactIdentity(
            relativePath: relativePath,
            encoding: encoding,
            artifactSHA256: artifactSHA256,
            rawSHA256: rawSHA256,
            artifactByteCount: artifactByteCount,
            rawByteCount: rawByteCount,
            width: width,
            height: height
        )
    }
}

struct R13RestartCommitRecord: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sequence: Int
    let artifact: R13CachedFrameArtifactIdentity
    let previousRecordSHA256: String
    let recordSHA256: String

    init(
        sequence: Int,
        artifact: R13CachedFrameArtifactIdentity,
        previousRecordSHA256: String,
        recordSHA256: String
    ) throws {
        guard sequence >= 0 else {
            throw R13RestartJobError.invalidFrameIndex(
                expected: 0,
                actual: sequence
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.sequence = sequence
        self.artifact = artifact
        self.previousRecordSHA256 = try R13RestartValidation.sha256(
            previousRecordSHA256,
            field: "previous_record_sha256"
        )
        self.recordSHA256 = try R13RestartValidation.sha256(
            recordSHA256,
            field: "record_sha256"
        )
    }

    fileprivate var payload: R13RestartCommitRecordPayload {
        R13RestartCommitRecordPayload(
            schemaVersion: schemaVersion,
            sequence: sequence,
            artifact: artifact,
            previousRecordSHA256: previousRecordSHA256
        )
    }
}

private struct R13RestartCommitRecordPayload: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let sequence: Int
    let artifact: R13CachedFrameArtifactIdentity
    let previousRecordSHA256: String
}

private struct R13PrepublicationReceiptPayload:
    Codable,
    Hashable,
    Sendable {
    let schemaVersion: Int
    let jobID: String
    let coreSHA256: String
    let headSHA256: String
    let frameCount: Int
    let writerStartFrameIndex: Int
    let partialMediaReusePolicy: R13PartialMediaReusePolicy
    let outputMediaSHA256: String
    let outputMediaByteCount: UInt64
}

actor R13RestartJobStore {
    private static let maximumCoreBytes = 64 * 1_024
    private static let maximumHeadBytes = 64 * 1_024 * 1_024
    private static let maximumRecordBytes = 64 * 1_024
    private static let maximumReceiptBytes = 64 * 1_024

    private let jobsRootURL: URL
    private let fileSystem: any R13RestartFileSystem
    private let digest: any R13RestartDigesting
    private let frameCodec: any R13NV12FrameCacheCoding

    init(
        jobsRootURL: URL,
        fileSystem: any R13RestartFileSystem = R13LocalRestartFileSystem(),
        digest: any R13RestartDigesting = R13CryptoKitRestartDigest(),
        frameCodec: any R13NV12FrameCacheCoding =
            R13LZFSEFrameCacheCodec()
    ) {
        self.jobsRootURL = R13RestartPath.resolvingExistingAncestor(
            of: jobsRootURL
        )
        self.fileSystem = fileSystem
        self.digest = digest
        self.frameCodec = frameCodec
    }

    func reopen(
        jobID: String,
        expecting expectedCore: R13RestartJobCore,
        observedSource: R13RestartSourceIdentity
    ) throws -> R13RestartAttemptPlan {
        let state = try loadValidatedState(
            jobID: jobID,
            validateArtifacts: true
        )
        guard state.core.source == observedSource else {
            throw R13RestartJobError.sourceDrift(
                expected: state.core.source,
                observed: observedSource
            )
        }
        guard state.core == expectedCore else {
            throw R13RestartJobError.immutableCoreMismatch
        }
        let urls = try jobURLs(jobID: jobID)
        if fileSystem.exists(urls.receipt) {
            try fileSystem.removeFile(urls.receipt)
        }
        return attemptPlan(
            core: state.core,
            head: state.head,
            references: state.recordReferences
        )
    }

    func commitProcessedFrame(
        _ frame: R13NV12Frame,
        at frameIndex: Int,
        using plan: R13RestartAttemptPlan
    ) throws -> R13RestartAttemptPlan {
        let state = try loadValidatedState(
            jobID: plan.jobID,
            validateArtifacts: false
        )
        guard state.coreSHA256 == plan.coreSHA256 else {
            throw R13RestartJobError.immutableCoreMismatch
        }
        guard state.head.headSHA256 == plan.headSHA256 else {
            throw R13RestartJobError.staleHead(
                expected: plan.headSHA256,
                observed: state.head.headSHA256
            )
        }
        let expectedFrameIndex = state.head.committedFrameCount
        guard plan.verifiedCachedPrefixCount == expectedFrameIndex else {
            throw R13RestartJobError.headMismatch
        }
        guard frameIndex == expectedFrameIndex else {
            throw R13RestartJobError.invalidFrameIndex(
                expected: expectedFrameIndex,
                actual: frameIndex
            )
        }
        guard frameIndex < state.core.totalFrameCount else {
            throw R13RestartJobError.invalidFrameIndex(
                expected: state.core.totalFrameCount - 1,
                actual: frameIndex
            )
        }
        guard frame.width == state.core.output.width,
              frame.height == state.core.output.height else {
            throw R13RestartJobError.cachedFrameGeometryMismatch(
                index: frameIndex
            )
        }

        let encoded = try frameCodec.encode(frame)
        let artifactSHA256 = digest.sha256(encoded.data)
        let artifactRelativePath =
            "frames/\(frameIndex)-\(artifactSHA256).r13nv12"
        let artifact = try R13CachedFrameArtifactIdentity(
            relativePath: artifactRelativePath,
            encoding: encoded.encoding,
            artifactSHA256: artifactSHA256,
            rawSHA256: encoded.rawSHA256,
            artifactByteCount: UInt64(encoded.data.count),
            rawByteCount: UInt64(frame.luma.count + frame.chroma.count),
            width: frame.width,
            height: frame.height
        )
        let urls = try jobURLs(jobID: state.core.jobID)
        try writeNewOrVerify(
            encoded.data,
            to: urls.directory.appendingPathComponent(artifactRelativePath),
            maximumBytes: encoded.data.count
        )

        let payload = R13RestartCommitRecordPayload(
            schemaVersion: R13RestartCommitRecord.currentSchemaVersion,
            sequence: frameIndex,
            artifact: artifact,
            previousRecordSHA256: state.head.headSHA256
        )
        let recordSHA256 = digest.sha256(
            try R13RestartCanonical.data(payload)
        )
        let record = try R13RestartCommitRecord(
            sequence: frameIndex,
            artifact: artifact,
            previousRecordSHA256: state.head.headSHA256,
            recordSHA256: recordSHA256
        )
        let recordRelativePath = "records/\(frameIndex).json"
        let recordData = try R13RestartCanonical.data(record)
        try writeNewOrVerify(
            recordData,
            to: urls.directory.appendingPathComponent(recordRelativePath),
            maximumBytes: Self.maximumRecordBytes
        )

        let reference = try R13RestartRecordReference(
            sequence: frameIndex,
            relativePath: recordRelativePath,
            recordSHA256: recordSHA256
        )
        let nextHead = try R13RestartJobHead(
            coreSHA256: state.coreSHA256,
            committedFrameCount: frameIndex + 1,
            headSHA256: recordSHA256
        )
        try fileSystem.replaceAtomically(
            R13RestartCanonical.data(nextHead),
            at: urls.head
        )
        return attemptPlan(
            core: state.core,
            head: nextHead,
            references: plan.verifiedCachedRecords + [reference]
        )
    }

    func loadCachedFrame(
        at frameIndex: Int,
        using plan: R13RestartAttemptPlan
    ) throws -> R13NV12Frame {
        guard plan.verifiedCachedRecords.indices.contains(frameIndex) else {
            throw R13RestartJobError.invalidFrameIndex(
                expected: plan.verifiedCachedPrefixCount,
                actual: frameIndex
            )
        }
        let state = try loadValidatedState(
            jobID: plan.jobID,
            validateArtifacts: false
        )
        guard state.coreSHA256 == plan.coreSHA256 else {
            throw R13RestartJobError.immutableCoreMismatch
        }
        guard state.head.headSHA256 == plan.headSHA256 else {
            throw R13RestartJobError.staleHead(
                expected: plan.headSHA256,
                observed: state.head.headSHA256
            )
        }
        let reference = plan.verifiedCachedRecords[frameIndex]
        let record = try loadValidatedRecord(
            reference,
            expectedPreviousSHA256: frameIndex == 0
                ? state.coreSHA256
                : plan.verifiedCachedRecords[frameIndex - 1].recordSHA256,
            jobID: plan.jobID
        )
        return try loadAndValidateFrame(
            record.artifact,
            frameIndex: frameIndex,
            jobID: plan.jobID
        )
    }

    func preparePrepublicationReceipt(
        using plan: R13RestartAttemptPlan,
        observedSource: R13RestartSourceIdentity,
        outputMediaSHA256: String,
        outputMediaByteCount: UInt64
    ) throws -> R13PrepublicationReceipt {
        let outputSHA256 = try R13RestartValidation.sha256(
            outputMediaSHA256,
            field: "output_media_sha256"
        )
        guard outputMediaByteCount > 0 else {
            throw R13RestartJobError.invalidByteCount(
                field: "output_media_byte_count"
            )
        }
        let state = try loadValidatedState(
            jobID: plan.jobID,
            validateArtifacts: true
        )
        guard state.coreSHA256 == plan.coreSHA256 else {
            throw R13RestartJobError.immutableCoreMismatch
        }
        guard state.core.source == observedSource else {
            throw R13RestartJobError.sourceDrift(
                expected: state.core.source,
                observed: observedSource
            )
        }
        guard state.head.headSHA256 == plan.headSHA256 else {
            throw R13RestartJobError.staleHead(
                expected: plan.headSHA256,
                observed: state.head.headSHA256
            )
        }
        guard state.head.committedFrameCount == state.core.totalFrameCount else {
            throw R13RestartJobError.incompleteJob(
                committed: state.head.committedFrameCount,
                expected: state.core.totalFrameCount
            )
        }
        let payload = R13PrepublicationReceiptPayload(
            schemaVersion: R13PrepublicationReceipt.currentSchemaVersion,
            jobID: state.core.jobID,
            coreSHA256: state.coreSHA256,
            headSHA256: state.head.headSHA256,
            frameCount: state.core.totalFrameCount,
            writerStartFrameIndex: 0,
            partialMediaReusePolicy: .forbidden,
            outputMediaSHA256: outputSHA256,
            outputMediaByteCount: outputMediaByteCount
        )
        let receipt = R13PrepublicationReceipt(
            schemaVersion: payload.schemaVersion,
            jobID: payload.jobID,
            coreSHA256: payload.coreSHA256,
            headSHA256: payload.headSHA256,
            frameCount: payload.frameCount,
            writerStartFrameIndex: payload.writerStartFrameIndex,
            partialMediaReusePolicy: payload.partialMediaReusePolicy,
            outputMediaSHA256: payload.outputMediaSHA256,
            outputMediaByteCount: payload.outputMediaByteCount,
            receiptSHA256: digest.sha256(
                try R13RestartCanonical.data(payload)
            )
        )
        let urls = try jobURLs(jobID: state.core.jobID)
        let receiptData = try R13RestartCanonical.data(receipt)
        if fileSystem.exists(urls.receipt) {
            let stored = try fileSystem.readRegularFile(
                urls.receipt,
                maximumBytes: Self.maximumReceiptBytes
            )
            guard stored == receiptData else {
                throw R13RestartJobError.prepublicationReceiptConflict
            }
        } else {
            try fileSystem.writeNewAtomically(receiptData, to: urls.receipt)
        }
        return receipt
    }

    func discard(jobID: String) throws {
        let urls = try jobURLs(jobID: jobID)
        guard fileSystem.exists(urls.directory) else { return }
        try fileSystem.removeDirectory(urls.directory)
    }
}

extension R13RestartJobStore {
    func create(_ core: R13RestartJobCore) throws -> R13RestartAttemptPlan {
        try core.validate()
        try fileSystem.ensureDirectory(jobsRootURL)
        let finalURLs = try jobURLs(jobID: core.jobID)
        guard !fileSystem.exists(finalURLs.directory) else {
            throw R13RestartJobError.jobAlreadyExists(core.jobID)
        }
        let stagingURLs = try jobURLs(
            jobID: ".r13-init-\(UUID().uuidString)"
        )
        var stagingDirectoryCreated = false
        do {
            try fileSystem.createDirectoryExclusively(
                stagingURLs.directory
            )
            stagingDirectoryCreated = true
            try fileSystem.ensureDirectory(stagingURLs.framesDirectory)
            try fileSystem.ensureDirectory(stagingURLs.recordsDirectory)
            let coreData = try R13RestartCanonical.data(core)
            let coreSHA256 = digest.sha256(coreData)
            let head = try R13RestartJobHead(
                coreSHA256: coreSHA256,
                committedFrameCount: 0,
                headSHA256: coreSHA256
            )
            try fileSystem.writeNewAtomically(
                coreData,
                to: stagingURLs.core
            )
            try fileSystem.writeNewAtomically(
                R13RestartCanonical.data(head),
                to: stagingURLs.head
            )
            try fileSystem.publishDirectoryAtomically(
                from: stagingURLs.directory,
                to: finalURLs.directory
            )
            stagingDirectoryCreated = false
            return attemptPlan(core: core, head: head, references: [])
        } catch {
            let trigger = error
            if stagingDirectoryCreated,
               fileSystem.exists(stagingURLs.directory) {
                do {
                    try fileSystem.removeDirectory(stagingURLs.directory)
                } catch {
                    throw R13RestartJobError.initializationCleanupFailed(
                        jobID: core.jobID,
                        triggerReason: String(describing: trigger),
                        cleanupReason: String(describing: error)
                    )
                }
            }
            let fileSystemError = trigger as NSError
            if fileSystemError.domain == NSPOSIXErrorDomain,
               fileSystemError.code == Int(EEXIST) {
                throw R13RestartJobError.jobAlreadyExists(core.jobID)
            }
            throw trigger
        }
    }

    func validateRecoverableJob(jobID: String) throws -> Int {
        let state = try loadValidatedState(
            jobID: jobID,
            validateArtifacts: true
        )
        return state.head.committedFrameCount
    }

    func validateRecoverableSource(
        jobID: String,
        observedSource: R13RestartSourceIdentity
    ) throws {
        let state = try loadValidatedState(
            jobID: jobID,
            validateArtifacts: true
        )
        guard state.core.source == observedSource else {
            throw R13RestartJobError.sourceDrift(
                expected: state.core.source,
                observed: observedSource
            )
        }
    }
}

private extension R13RestartJobStore {
    struct JobURLs {
        let directory: URL
        let core: URL
        let head: URL
        let receipt: URL
        let framesDirectory: URL
        let recordsDirectory: URL
    }

    struct ValidatedState {
        let core: R13RestartJobCore
        let coreSHA256: String
        let head: R13RestartJobHead
        let recordReferences: [R13RestartRecordReference]
    }

    func jobURLs(jobID: String) throws -> JobURLs {
        let validatedJobID = try R13RestartValidation.jobID(jobID)
        let directory = jobsRootURL.appendingPathComponent(
            validatedJobID,
            isDirectory: true
        )
        return JobURLs(
            directory: directory,
            core: directory.appendingPathComponent("job-core-v1.json"),
            head: directory.appendingPathComponent("head-v1.json"),
            receipt: directory.appendingPathComponent(
                "prepublication-receipt-v1.json"
            ),
            framesDirectory: directory.appendingPathComponent(
                "frames",
                isDirectory: true
            ),
            recordsDirectory: directory.appendingPathComponent(
                "records",
                isDirectory: true
            )
        )
    }

    func loadValidatedState(
        jobID: String,
        validateArtifacts: Bool
    ) throws -> ValidatedState {
        let urls = try jobURLs(jobID: jobID)
        guard fileSystem.exists(urls.directory) else {
            throw R13RestartJobError.jobMissing(jobID)
        }
        try fileSystem.validateDirectory(urls.directory)
        try fileSystem.validateDirectory(urls.framesDirectory)
        try fileSystem.validateDirectory(urls.recordsDirectory)

        let coreData = try fileSystem.readRegularFile(
            urls.core,
            maximumBytes: Self.maximumCoreBytes
        )
        let core: R13RestartJobCore = try decodeCanonical(
            R13RestartJobCore.self,
            from: coreData,
            document: "job_core"
        )
        try core.validate()
        let validatedJobID = try R13RestartValidation.jobID(jobID)
        guard core.jobID == validatedJobID else {
            throw R13RestartJobError.immutableCoreMismatch
        }
        let coreSHA256 = digest.sha256(coreData)

        let headData = try fileSystem.readRegularFile(
            urls.head,
            maximumBytes: Self.maximumHeadBytes
        )
        let head: R13RestartJobHead = try decodeCanonical(
            R13RestartJobHead.self,
            from: headData,
            document: "job_head"
        )
        try head.validate()
        guard head.coreSHA256 == coreSHA256,
              head.committedFrameCount <= core.totalFrameCount else {
            throw R13RestartJobError.headMismatch
        }

        if !validateArtifacts {
            return ValidatedState(
                core: core,
                coreSHA256: coreSHA256,
                head: head,
                recordReferences: []
            )
        }
        var previousSHA256 = coreSHA256
        var references: [R13RestartRecordReference] = []
        references.reserveCapacity(head.committedFrameCount)
        for sequence in 0..<head.committedFrameCount {
            let reference = try loadRecordReference(
                sequence: sequence,
                jobID: core.jobID
            )
            try reference.validate()
            guard reference.sequence == sequence,
                  reference.relativePath == "records/\(sequence).json"
            else {
                throw R13RestartJobError.recordChainMismatch(
                    sequence: sequence
                )
            }
            let record = try loadValidatedRecord(
                reference,
                expectedPreviousSHA256: previousSHA256,
                jobID: core.jobID
            )
            guard record.artifact.width == core.output.width,
                  record.artifact.height == core.output.height else {
                throw R13RestartJobError.cachedFrameGeometryMismatch(
                    index: sequence
                )
            }
            if validateArtifacts {
                _ = try loadAndValidateFrame(
                    record.artifact,
                    frameIndex: sequence,
                    jobID: core.jobID
                )
            }
            previousSHA256 = reference.recordSHA256
            references.append(reference)
        }
        guard head.headSHA256 == previousSHA256 else {
            throw R13RestartJobError.headMismatch
        }
        return ValidatedState(
            core: core,
            coreSHA256: coreSHA256,
            head: head,
            recordReferences: references
        )
    }

    func loadRecordReference(
        sequence: Int,
        jobID: String
    ) throws -> R13RestartRecordReference {
        let urls = try jobURLs(jobID: jobID)
        let relativePath = "records/\(sequence).json"
        let recordData = try fileSystem.readRegularFile(
            urls.directory.appendingPathComponent(relativePath),
            maximumBytes: Self.maximumRecordBytes
        )
        let record: R13RestartCommitRecord = try decodeCanonical(
            R13RestartCommitRecord.self,
            from: recordData,
            document: "commit_record"
        )
        return try R13RestartRecordReference(
            sequence: sequence,
            relativePath: relativePath,
            recordSHA256: record.recordSHA256
        )
    }

    func loadValidatedRecord(
        _ reference: R13RestartRecordReference,
        expectedPreviousSHA256: String,
        jobID: String
    ) throws -> R13RestartCommitRecord {
        let urls = try jobURLs(jobID: jobID)
        let recordURL = urls.directory.appendingPathComponent(
            reference.relativePath
        )
        let recordData = try fileSystem.readRegularFile(
            recordURL,
            maximumBytes: Self.maximumRecordBytes
        )
        let record: R13RestartCommitRecord = try decodeCanonical(
            R13RestartCommitRecord.self,
            from: recordData,
            document: "commit_record"
        )
        guard record.schemaVersion
                == R13RestartCommitRecord.currentSchemaVersion,
              record.sequence == reference.sequence,
              record.previousRecordSHA256 == expectedPreviousSHA256,
              record.recordSHA256 == reference.recordSHA256 else {
            throw R13RestartJobError.recordChainMismatch(
                sequence: reference.sequence
            )
        }
        try record.artifact.validate()
        let expectedArtifactPath =
            "frames/\(record.sequence)-\(record.artifact.artifactSHA256).r13nv12"
        guard record.artifact.relativePath == expectedArtifactPath,
              digest.sha256(
                  try R13RestartCanonical.data(record.payload)
              ) == record.recordSHA256 else {
            throw R13RestartJobError.recordChainMismatch(
                sequence: reference.sequence
            )
        }
        return record
    }

    func loadAndValidateFrame(
        _ artifact: R13CachedFrameArtifactIdentity,
        frameIndex: Int,
        jobID: String
    ) throws -> R13NV12Frame {
        let maximumArtifactBytes: UInt64
        do {
            maximumArtifactBytes =
                try R13LZFSEFrameCacheCodec.maximumArtifactByteCount(
                    width: artifact.width,
                    height: artifact.height
                )
        } catch {
            throw R13RestartJobError.cachedFrameCorrupt(index: frameIndex)
        }
        guard artifact.artifactByteCount <= maximumArtifactBytes,
              let maximumReadBytes = Int(
                  exactly: artifact.artifactByteCount
              ) else {
            throw R13RestartJobError.cachedFrameCorrupt(index: frameIndex)
        }
        let urls = try jobURLs(jobID: jobID)
        let artifactURL = urls.directory.appendingPathComponent(
            artifact.relativePath
        )
        guard fileSystem.exists(artifactURL) else {
            throw R13RestartJobError.cachedFrameMissing(index: frameIndex)
        }
        let artifactData: Data
        do {
            artifactData = try fileSystem.readRegularFile(
                artifactURL,
                maximumBytes: maximumReadBytes
            )
        } catch {
            throw R13RestartJobError.cachedFrameCorrupt(index: frameIndex)
        }
        guard UInt64(artifactData.count) == artifact.artifactByteCount,
              digest.sha256(artifactData) == artifact.artifactSHA256 else {
            throw R13RestartJobError.cachedFrameCorrupt(index: frameIndex)
        }
        let frame: R13NV12Frame
        do {
            frame = try frameCodec.decode(artifactData)
        } catch {
            throw R13RestartJobError.cachedFrameCorrupt(index: frameIndex)
        }
        guard frame.width == artifact.width,
              frame.height == artifact.height,
              UInt64(frame.luma.count + frame.chroma.count)
                == artifact.rawByteCount,
              digest.sha256(frame.tightRawData) == artifact.rawSHA256 else {
            throw R13RestartJobError.cachedFrameCorrupt(index: frameIndex)
        }
        return frame
    }

    func attemptPlan(
        core: R13RestartJobCore,
        head: R13RestartJobHead,
        references: [R13RestartRecordReference]
    ) -> R13RestartAttemptPlan {
        R13RestartAttemptPlan(
            jobID: core.jobID,
            coreSHA256: head.coreSHA256,
            headSHA256: head.headSHA256,
            totalFrameCount: core.totalFrameCount,
            verifiedCachedRecords: references,
            writerStartFrameIndex: 0,
            partialMediaReusePolicy: .forbidden
        )
    }

    func writeNewOrVerify(
        _ data: Data,
        to url: URL,
        maximumBytes: Int
    ) throws {
        if fileSystem.exists(url) {
            let stored = try fileSystem.readRegularFile(
                url,
                maximumBytes: maximumBytes
            )
            guard stored == data else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            return
        }
        try fileSystem.writeNewAtomically(data, to: url)
    }

    func decodeCanonical<T: Decodable & Encodable>(
        _ type: T.Type,
        from data: Data,
        document: String
    ) throws -> T {
        let value: T
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            throw R13RestartJobError.nonCanonicalDocument(document)
        }
        guard try R13RestartCanonical.data(value) == data else {
            throw R13RestartJobError.nonCanonicalDocument(document)
        }
        return value
    }
}

// swiftlint:enable file_length
