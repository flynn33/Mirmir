import Foundation

struct R13RecoverableUpscaleJob: Equatable, Identifiable, Sendable {
    let id: String
    let outputFilename: String
    let targetResolution: VideoResolution
    let codec: OutputCodec
    let preserveAudio: Bool
    let mode: UpscaleMode
    let cachedFrameCount: Int

    init(
        descriptor: R13RecoveryDescriptor,
        cachedFrameCount: Int = 0
    ) throws {
        try descriptor.validate()
        guard cachedFrameCount >= 0 else {
            throw R13RestartJobError.invalidFrameCount(cachedFrameCount)
        }
        guard let outputCodec = OutputCodec(rawValue: descriptor.codec),
              let upscaleMode = UpscaleMode(rawValue: descriptor.mode) else {
            throw R13RestartJobError.nonCanonicalDocument(
                "recovery_job_options"
            )
        }
        id = descriptor.jobID
        outputFilename = descriptor.outputFilename
        targetResolution = VideoResolution(
            width: descriptor.targetWidth,
            height: descriptor.targetHeight
        )
        codec = outputCodec
        preserveAudio = descriptor.preserveAudio
        mode = upscaleMode
        self.cachedFrameCount = cachedFrameCount
    }

    init(job: UpscaleJob) throws {
        try self.init(descriptor: R13RecoveryDescriptor(job: job))
    }
}

struct R13RecoverableJobCatalog: Equatable, Sendable {
    let jobs: [R13RecoverableUpscaleJob]
    let rejectedEntryCount: Int

    init(
        jobs: [R13RecoverableUpscaleJob],
        rejectedEntryCount: Int
    ) {
        precondition(rejectedEntryCount >= 0)
        self.jobs = jobs
        self.rejectedEntryCount = rejectedEntryCount
    }

    static let empty = R13RecoverableJobCatalog(
        jobs: [],
        rejectedEntryCount: 0
    )
}

struct R13ResolvedRecoverableUpscaleJob: @unchecked Sendable {
    let summary: R13RecoverableUpscaleJob
    let job: UpscaleJob
    let securityAccess: R13SecurityScopedAccessSet
}

final class R13SecurityScopedAccessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var retainedAccess: R13SecurityScopedAccessSet?

    init(_ access: R13SecurityScopedAccessSet?) {
        retainedAccess = access
    }

    var access: R13SecurityScopedAccessSet? {
        lock.withLock { retainedAccess }
    }

    func release() {
        lock.withLock {
            retainedAccess = nil
        }
    }
}

protocol R13RecoverableUpscalerEngine: Sendable {
    func recoverableJobs() async throws -> R13RecoverableJobCatalog
    func discardRecoverableJob(id: String) async throws
    func discardAllRecoverableJobs() async throws
    func resolveRecoverableJob(
        id: String
    ) async throws -> R13ResolvedRecoverableUpscaleJob
    func reauthorizeRecoverableJob(
        id: String,
        sourceURL: URL,
        outputDirectoryURL: URL
    ) async throws -> R13ResolvedRecoverableUpscaleJob
    func submitRecoveredJob(
        _ recovered: R13ResolvedRecoverableUpscaleJob
    ) throws -> UpscalerJobHandle
}

extension R13ReleaseUpscalerEngineService {
    func submitRecoveredJob(
        _ recovered: R13ResolvedRecoverableUpscaleJob
    ) throws -> UpscalerJobHandle {
        try makeJobHandle(
            job: recovered.job,
            securityAccess: recovered.securityAccess
        )
    }

    func recoverableJobs() async throws -> R13RecoverableJobCatalog {
        try await resolveHardeningRuntime()?.recoverableJobs() ?? .empty
    }

    func discardRecoverableJob(id: String) async throws {
        try await performRecoveryDiscard {
            guard let hardeningRuntime =
                    try resolveHardeningRuntime() else {
                throw R13RestartJobError.jobMissing(id)
            }
            try await hardeningRuntime.discardRecoverableJob(id: id)
        }
    }

    func discardAllRecoverableJobs() async throws {
        try await performRecoveryDiscard {
            try await resolveHardeningRuntime()?
                .discardAllRecoverableJobs()
        }
    }

    private func performRecoveryDiscard(
        _ operation: () async throws -> Void
    ) async throws {
        let reserved = activeJobState.withLock { state in
            guard case .idle = state else { return false }
            state = .discardingRecovery
            return true
        }
        guard reserved else {
            throw UpscalerEngineError.jobAlreadyRunning
        }
        defer {
            activeJobState.withLock { state in
                guard case .discardingRecovery = state else {
                    preconditionFailure(
                        "R13 recovery-discard reservation changed unexpectedly."
                    )
                }
                state = .idle
            }
        }
        try await operation()
    }

    func resolveRecoverableJob(
        id: String
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        guard let hardeningRuntime = try resolveHardeningRuntime() else {
            throw R13RestartJobError.jobMissing(id)
        }
        return try await hardeningRuntime.resolveRecoverableJob(id: id)
    }

    func reauthorizeRecoverableJob(
        id: String,
        sourceURL: URL,
        outputDirectoryURL: URL
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        guard let hardeningRuntime = try resolveHardeningRuntime() else {
            throw R13RestartJobError.jobMissing(id)
        }
        return try await hardeningRuntime.reauthorizeRecoverableJob(
            id: id,
            sourceURL: sourceURL,
            outputDirectoryURL: outputDirectoryURL
        )
    }
}

struct R13RecoveryDescriptor: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobID: String
    let outputFilename: String
    let targetWidth: Int
    let targetHeight: Int
    let codec: String
    let preserveAudio: Bool
    let mode: String

    init(job: UpscaleJob) throws {
        schemaVersion = Self.currentSchemaVersion
        jobID = try R13RestartValidation.jobID(job.identifier)
        outputFilename = try Self.validateFilename(
            job.outputURL.lastPathComponent
        )
        guard job.targetResolution.width > 0,
              job.targetResolution.height > 0 else {
            throw R13RestartJobError.invalidOutputGeometry(
                width: job.targetResolution.width,
                height: job.targetResolution.height
            )
        }
        targetWidth = job.targetResolution.width
        targetHeight = job.targetResolution.height
        codec = job.codec.rawValue
        preserveAudio = job.preserveAudio
        mode = job.mode.rawValue
    }

    func makeJob(
        access: R13SecurityScopedAccessSet
    ) throws -> UpscaleJob {
        try validate()
        guard let outputCodec = OutputCodec(rawValue: codec),
              let upscaleMode = UpscaleMode(rawValue: mode) else {
            throw R13RestartJobError.nonCanonicalDocument(
                "recovery_job_options"
            )
        }
        return UpscaleJob(
            identifier: jobID,
            inputURL: access.url(for: .source),
            outputURL: access.url(for: .outputDirectory)
                .appendingPathComponent(outputFilename),
            targetResolution: VideoResolution(
                width: targetWidth,
                height: targetHeight
            ),
            codec: outputCodec,
            preserveAudio: preserveAudio,
            mode: upscaleMode
        )
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw R13RestartJobError.schemaMismatch(
                document: "recovery_descriptor"
            )
        }
        _ = try R13RestartValidation.jobID(jobID)
        _ = try Self.validateFilename(outputFilename)
        guard targetWidth > 0, targetHeight > 0,
              OutputCodec(rawValue: codec) != nil,
              UpscaleMode(rawValue: mode) != nil else {
            throw R13RestartJobError.nonCanonicalDocument(
                "recovery_job_options"
            )
        }
    }

    private static func validateFilename(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= 255,
              !value.contains("/"),
              !value.contains("\0"),
              URL(fileURLWithPath: value).lastPathComponent == value else {
            throw R13RestartJobError.invalidRelativePath(value)
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case outputFilename = "output_filename"
        case targetWidth = "target_width"
        case targetHeight = "target_height"
        case codec
        case preserveAudio = "preserve_audio"
        case mode
    }
}

actor R13RecoveryDescriptorStore {
    private static let maximumDescriptorBytes = 64 * 1_024
    private static let maximumRecoverableJobs = 1_024

    private let jobsRootURL: URL
    private let fileSystem: any R13RestartFileSystem
    private let fileManager: FileManager

    init(
        jobsRootURL: URL,
        fileSystem: any R13RestartFileSystem = R13LocalRestartFileSystem(),
        fileManager: FileManager = .default
    ) {
        self.jobsRootURL = R13RestartPath.resolvingExistingAncestor(
            of: jobsRootURL
        )
        self.fileSystem = fileSystem
        self.fileManager = fileManager
    }

    func save(job: UpscaleJob) throws {
        let descriptor = try R13RecoveryDescriptor(job: job)
        let directory = jobsRootURL.appendingPathComponent(
            descriptor.jobID,
            isDirectory: true
        )
        try fileSystem.validateDirectory(directory)
        let url = directory.appendingPathComponent("recovery-v1.json")
        let data = try R13RestartCanonical.data(descriptor)
        if fileSystem.exists(url) {
            let stored = try fileSystem.readRegularFile(
                url,
                maximumBytes: Self.maximumDescriptorBytes
            )
            guard stored == data else {
                throw R13RestartJobError.immutableCoreMismatch
            }
        } else {
            try fileSystem.writeNewAtomically(data, to: url)
        }
    }

    func list() throws -> R13RecoveryDescriptorListing {
        guard fileSystem.exists(jobsRootURL) else { return .empty }
        try fileSystem.validateDirectory(jobsRootURL)
        let entries = try fileManager.contentsOfDirectory(
            at: jobsRootURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        )
        guard entries.count <= Self.maximumRecoverableJobs else {
            throw R13RestartJobError.fileTooLarge(
                path: jobsRootURL.path,
                maximumBytes: Self.maximumRecoverableJobs
            )
        }
        var descriptors: [R13RecoveryDescriptor] = []
        var rejectedEntryCount = 0
        descriptors.reserveCapacity(entries.count)
        for directory in entries {
            do {
                let values = try directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    throw R13RestartJobError.unsafeFilesystemEntry(
                        directory.path
                    )
                }
                let jobID = try R13RestartValidation.jobID(
                    directory.lastPathComponent
                )
                descriptors.append(try load(jobID: jobID))
            } catch {
                rejectedEntryCount += 1
            }
        }
        return R13RecoveryDescriptorListing(
            descriptors: descriptors.sorted { $0.jobID < $1.jobID },
            rejectedEntryCount: rejectedEntryCount
        )
    }

    func load(jobID: String) throws -> R13RecoveryDescriptor {
        let validatedJobID = try R13RestartValidation.jobID(jobID)
        let directory = jobsRootURL.appendingPathComponent(
            validatedJobID,
            isDirectory: true
        )
        try fileSystem.validateDirectory(directory)
        let url = directory.appendingPathComponent("recovery-v1.json")
        let data = try fileSystem.readRegularFile(
            url,
            maximumBytes: Self.maximumDescriptorBytes
        )
        let descriptor: R13RecoveryDescriptor
        do {
            descriptor = try JSONDecoder().decode(
                R13RecoveryDescriptor.self,
                from: data
            )
        } catch {
            throw R13RestartJobError.nonCanonicalDocument(
                "recovery_descriptor"
            )
        }
        guard try R13RestartCanonical.data(descriptor) == data else {
            throw R13RestartJobError.nonCanonicalDocument(
                "recovery_descriptor"
            )
        }
        try descriptor.validate()
        guard descriptor.jobID == validatedJobID else {
            throw R13RestartJobError.immutableCoreMismatch
        }
        return descriptor
    }
}

struct R13RecoveryDescriptorListing: Equatable, Sendable {
    let descriptors: [R13RecoveryDescriptor]
    let rejectedEntryCount: Int

    init(
        descriptors: [R13RecoveryDescriptor],
        rejectedEntryCount: Int
    ) {
        precondition(rejectedEntryCount >= 0)
        self.descriptors = descriptors
        self.rejectedEntryCount = rejectedEntryCount
    }

    static let empty = R13RecoveryDescriptorListing(
        descriptors: [],
        rejectedEntryCount: 0
    )
}
