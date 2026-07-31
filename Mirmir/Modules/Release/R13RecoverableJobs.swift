import Foundation

struct R13RecoverableUpscaleJob: Equatable, Identifiable, Sendable {
    let id: String
    let outputFilename: String
    let targetResolution: VideoResolution
    let codec: OutputCodec
    let preserveAudio: Bool
    let mode: UpscaleMode
    let processingConfiguration: UpscaleProcessingConfiguration
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
              let upscaleMode = UpscaleMode(rawValue: descriptor.mode),
              let enginePreference = UpscaleEnginePreference(
                rawValue: descriptor.enginePreference
              ),
              let strategyPreference = UpscaleStrategyPreference(
                rawValue: descriptor.strategyPreference
              ),
              let edgeFidelityLevel = MirmirAdjustmentLevel(
                rawValue: descriptor.edgeFidelityLevel
              ),
              let detailRecoveryLevel = MirmirAdjustmentLevel(
                rawValue: descriptor.detailRecoveryLevel
              ) else {
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
        processingConfiguration = UpscaleProcessingConfiguration(
            enginePreference: enginePreference,
            strategyPreference: strategyPreference,
            temporalConsistencyEnabled:
                descriptor.temporalConsistencyEnabled,
            edgeFidelityLevel: edgeFidelityLevel,
            detailRecoveryLevel: detailRecoveryLevel,
            effects: UpscaleEffectConfiguration(
                edgePreservationEnabled:
                    descriptor.edgePreservationEnabled ?? false,
                compressionCleanupEnabled:
                    descriptor.compressionCleanupEnabled ?? false,
                textureGrainProtectionEnabled:
                    descriptor.textureGrainProtectionEnabled ?? false,
                temporalStabilityEnabled:
                    descriptor.temporalStabilityEnabled ?? false
            ),
            smoothMotion:
                try descriptor.smoothMotionConfiguration()
        )
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
    static let currentSchemaVersion = 4
    private static let supportedSchemaVersions: Set<Int> = [2, 3, 4]

    let schemaVersion: Int
    let jobID: String
    let outputFilename: String
    let targetWidth: Int
    let targetHeight: Int
    let codec: String
    let preserveAudio: Bool
    let mode: String
    let enginePreference: String
    let strategyPreference: String
    let temporalConsistencyEnabled: Bool
    let edgeFidelityLevel: String
    let detailRecoveryLevel: String
    let edgePreservationEnabled: Bool?
    let compressionCleanupEnabled: Bool?
    let textureGrainProtectionEnabled: Bool?
    let temporalStabilityEnabled: Bool?
    let smoothMotionCadence: String?
    let smoothMotionSceneCutSensitivity: String?

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
        enginePreference =
            job.processingConfiguration.enginePreference.rawValue
        strategyPreference =
            job.processingConfiguration.strategyPreference.rawValue
        temporalConsistencyEnabled =
            job.processingConfiguration.temporalConsistencyEnabled
        edgeFidelityLevel =
            job.processingConfiguration.edgeFidelityLevel.rawValue
        detailRecoveryLevel =
            job.processingConfiguration.detailRecoveryLevel.rawValue
        edgePreservationEnabled =
            job.processingConfiguration.effects.edgePreservationEnabled
        compressionCleanupEnabled =
            job.processingConfiguration.effects.compressionCleanupEnabled
        textureGrainProtectionEnabled =
            job.processingConfiguration.effects
                .textureGrainProtectionEnabled
        temporalStabilityEnabled =
            job.processingConfiguration.effects.temporalStabilityEnabled
        smoothMotionCadence =
            job.processingConfiguration.smoothMotion.cadence.rawValue
        smoothMotionSceneCutSensitivity =
            job.processingConfiguration.smoothMotion
                .sceneCutSensitivity.rawValue
    }

    func makeJob(
        access: R13SecurityScopedAccessSet
    ) throws -> UpscaleJob {
        try validate()
        guard let outputCodec = OutputCodec(rawValue: codec),
              let upscaleMode = UpscaleMode(rawValue: mode),
              let engine = UpscaleEnginePreference(
                rawValue: enginePreference
              ),
              let strategy = UpscaleStrategyPreference(
                rawValue: strategyPreference
              ),
              let edge = MirmirAdjustmentLevel(
                rawValue: edgeFidelityLevel
              ),
              let detail = MirmirAdjustmentLevel(
                rawValue: detailRecoveryLevel
              ) else {
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
            mode: upscaleMode,
            processingConfiguration: UpscaleProcessingConfiguration(
                enginePreference: engine,
                strategyPreference: strategy,
                temporalConsistencyEnabled:
                    temporalConsistencyEnabled,
                edgeFidelityLevel: edge,
                detailRecoveryLevel: detail,
                effects: effectConfiguration,
                smoothMotion: try smoothMotionConfiguration()
            )
        )
    }

    func validate() throws {
        guard Self.supportedSchemaVersions.contains(schemaVersion) else {
            throw R13RestartJobError.schemaMismatch(
                document: "recovery_descriptor"
            )
        }
        _ = try R13RestartValidation.jobID(jobID)
        _ = try Self.validateFilename(outputFilename)
        guard targetWidth > 0, targetHeight > 0,
              OutputCodec(rawValue: codec) != nil,
              let decodedMode = UpscaleMode(rawValue: mode),
              UpscaleEnginePreference(rawValue: enginePreference) != nil,
              UpscaleStrategyPreference(rawValue: strategyPreference) != nil,
              MirmirAdjustmentLevel(rawValue: edgeFidelityLevel) != nil,
              MirmirAdjustmentLevel(rawValue: detailRecoveryLevel) != nil else {
            throw R13RestartJobError.nonCanonicalDocument(
                "recovery_job_options"
            )
        }
        if let smoothMotionCadence,
           SmoothMotionCadence(rawValue: smoothMotionCadence) == nil {
            throw R13RestartJobError.nonCanonicalDocument(
                "smooth_motion_cadence"
            )
        }
        if let smoothMotionSceneCutSensitivity,
           SmoothMotionSceneCutSensitivity(
            rawValue: smoothMotionSceneCutSensitivity
           ) == nil {
            throw R13RestartJobError.nonCanonicalDocument(
                "smooth_motion_scene_cut_sensitivity"
            )
        }
        if decodedMode == .smoothMotion,
           smoothMotionCadence == nil
            || smoothMotionSceneCutSensitivity == nil {
            throw R13RestartJobError.nonCanonicalDocument(
                "smooth_motion_configuration"
            )
        }
    }

    func validate(
        against persisted: R13ValidatedRecoverableJob
    ) throws {
        try validate()
        guard let mode = UpscaleMode(rawValue: mode),
              let engine = UpscaleEnginePreference(
                rawValue: enginePreference
              ),
              let strategy = UpscaleStrategyPreference(
                rawValue: strategyPreference
              ),
              let edge = MirmirAdjustmentLevel(
                rawValue: edgeFidelityLevel
              ),
              let detail = MirmirAdjustmentLevel(
                rawValue: detailRecoveryLevel
              ) else {
            throw R13RestartJobError.nonCanonicalDocument(
                "recovery_job_options"
            )
        }
        let binding = R13ReleaseModePolicy.binding(
            for: mode,
            enginePreference: engine
        )
        let configuration = UpscaleProcessingConfiguration(
            enginePreference: engine,
            strategyPreference: strategy,
            temporalConsistencyEnabled:
                temporalConsistencyEnabled,
            edgeFidelityLevel: edge,
            detailRecoveryLevel: detail,
            effects: effectConfiguration,
            smoothMotion: try smoothMotionConfiguration()
        )
        let expectedAudioPolicy =
            preserveAudio ? "preserve" : "omit"
        guard persisted.processing.requestedMode
                == binding.requestedMode.rawValue,
              persisted.processing.effectiveMode
                == binding.effectiveMode.rawValue,
              persisted.processing.backendIdentity
                == binding.backendID,
              persisted.processing.backendRevision
                == binding.backendRevision,
              routeIdentity(
                persisted.processing.routeIdentity,
                binds: configuration
              ),
              persisted.output.width == targetWidth,
              persisted.output.height == targetHeight,
              persisted.output.codec == codec,
              persisted.output.audioPolicy
                == expectedAudioPolicy else {
            throw R13RestartJobError.immutableCoreMismatch
        }
    }

    private func routeIdentity(
        _ routeIdentity: String,
        binds configuration: UpscaleProcessingConfiguration
    ) -> Bool {
        let configurationSuffix = ":\(configuration.identity)"
        if routeIdentity.hasSuffix(configurationSuffix) {
            return true
        }
        return MediaVideoScanStructure.allCases.contains { scanStructure in
            let deinterlacingIdentity =
                scanStructure.requiresDeinterlacing
                ? R13FormatPreservingDeinterlacer.algorithmIdentity
                : "not_required"
            return routeIdentity.hasSuffix(
                configurationSuffix
                    + ":\(scanStructure.rawValue)"
                    + ":\(deinterlacingIdentity)"
            )
        }
    }

    private var effectConfiguration: UpscaleEffectConfiguration {
        UpscaleEffectConfiguration(
            edgePreservationEnabled:
                edgePreservationEnabled ?? false,
            compressionCleanupEnabled:
                compressionCleanupEnabled ?? false,
            textureGrainProtectionEnabled:
                textureGrainProtectionEnabled ?? false,
            temporalStabilityEnabled:
                temporalStabilityEnabled ?? false
        )
    }

    func smoothMotionConfiguration()
        throws -> SmoothMotionConfiguration {
        let cadence: SmoothMotionCadence
        let sensitivity: SmoothMotionSceneCutSensitivity
        if let smoothMotionCadence {
            guard let value =
                    SmoothMotionCadence(
                        rawValue: smoothMotionCadence
                    ) else {
                throw R13RestartJobError.nonCanonicalDocument(
                    "smooth_motion_cadence"
                )
            }
            cadence = value
        } else {
            cadence = .double
        }
        if let smoothMotionSceneCutSensitivity {
            guard let value =
                    SmoothMotionSceneCutSensitivity(
                        rawValue:
                            smoothMotionSceneCutSensitivity
                    ) else {
                throw R13RestartJobError.nonCanonicalDocument(
                    "smooth_motion_scene_cut_sensitivity"
                )
            }
            sensitivity = value
        } else {
            sensitivity = .standard
        }
        return SmoothMotionConfiguration(
            cadence: cadence,
            sceneCutSensitivity: sensitivity
        )
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
        case enginePreference = "engine_preference"
        case strategyPreference = "strategy_preference"
        case temporalConsistencyEnabled =
            "temporal_consistency_enabled"
        case edgeFidelityLevel = "edge_fidelity_level"
        case detailRecoveryLevel = "detail_recovery_level"
        case edgePreservationEnabled =
            "edge_preservation_enabled"
        case compressionCleanupEnabled =
            "compression_cleanup_enabled"
        case textureGrainProtectionEnabled =
            "texture_grain_protection_enabled"
        case temporalStabilityEnabled =
            "temporal_stability_enabled"
        case smoothMotionCadence =
            "smooth_motion_cadence"
        case smoothMotionSceneCutSensitivity =
            "smooth_motion_scene_cut_sensitivity"
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
        let url = directory.appendingPathComponent("recovery-v2.json")
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
        let url = directory.appendingPathComponent("recovery-v2.json")
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
