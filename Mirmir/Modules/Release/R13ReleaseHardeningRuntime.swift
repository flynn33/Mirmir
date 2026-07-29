import Foundation

struct R13ReleaseHardeningRuntime: Sendable {
    let jobsRootURL: URL
    private let cacheLocationAccess: R13CacheLocationAccess?
    private let sourceMeasurer: any R13RestartSourceMeasuring
    private let sourceSnapshotter: any R13SourceSnapshotting
    private let frameCounter: any R13SourceFrameCountMeasuring
    private let environmentCollector: any R13ReleaseEnvironmentCollecting
    private let documents: R13ReleaseHardeningDocuments
    private let restartStore: R13RestartJobStore
    private let bookmarkStore: R13SecurityScopedBookmarkStore
    private let recoveryStore: R13RecoveryDescriptorStore
    private let bookmarkResolver: any R13SecurityScopedBookmarkResolving
    private let storagePreflight: R13StoragePreflight
    private let outputCapacityProbe: any R13AvailableCapacityProbing
    private let resourceGovernor: R13ResourceGovernor
    private let faultInjector: any R13FaultInjecting
    let diagnostics: R13ReleaseDiagnostics
    private let persistentDiagnostics: MirmirDiagnosticRecorder

    init(
        jobsRootURL: URL,
        sourceMeasurer: any R13RestartSourceMeasuring,
        frameCounter: any R13SourceFrameCountMeasuring,
        environmentCollector: any R13ReleaseEnvironmentCollecting,
        documents: R13ReleaseHardeningDocuments,
        bookmarkResolver: any R13SecurityScopedBookmarkResolving,
        storagePreflight: R13StoragePreflight,
        outputCapacityProbe: any R13AvailableCapacityProbing,
        resourceGovernor: R13ResourceGovernor,
        faultInjector: any R13FaultInjecting,
        diagnostics: R13ReleaseDiagnostics,
        sourceSnapshotter: (any R13SourceSnapshotting)? = nil,
        cacheLocationAccess: R13CacheLocationAccess? = nil,
        restartFileSystem: any R13RestartFileSystem =
            R13LocalRestartFileSystem(),
        persistentDiagnostics: MirmirDiagnosticRecorder =
            MirmirDiagnosticRecorder(store: nil)
    ) {
        self.jobsRootURL = jobsRootURL
        self.cacheLocationAccess = cacheLocationAccess
        self.sourceMeasurer = sourceMeasurer
        self.sourceSnapshotter = sourceSnapshotter
            ?? R13LocalSourceSnapshotter(
                sourceMeasurer: sourceMeasurer,
                fileSystem: restartFileSystem,
                minimumFreeDiskBytes:
                    documents.resourcePolicy.minimumFreeDiskBytes
            )
        self.frameCounter = frameCounter
        self.environmentCollector = environmentCollector
        self.documents = documents
        restartStore = R13RestartJobStore(
            jobsRootURL: jobsRootURL,
            fileSystem: restartFileSystem
        )
        bookmarkStore = R13SecurityScopedBookmarkStore(
            jobsRootURL: jobsRootURL,
            fileSystem: restartFileSystem
        )
        recoveryStore = R13RecoveryDescriptorStore(
            jobsRootURL: jobsRootURL,
            fileSystem: restartFileSystem
        )
        self.bookmarkResolver = bookmarkResolver
        self.storagePreflight = storagePreflight
        self.outputCapacityProbe = outputCapacityProbe
        self.resourceGovernor = resourceGovernor
        self.faultInjector = faultInjector
        self.diagnostics = diagnostics
        self.persistentDiagnostics = persistentDiagnostics
    }
}

extension R13ReleaseHardeningRuntime {
    func prepare(
        job: UpscaleJob,
        source: SourceProfile,
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding
    ) async throws -> R13ReleaseHardeningAttempt {
        let stagedSource = try await stageSource(for: job)
        return try await prepare(
            job: job,
            source: source,
            route: route,
            modeBinding: modeBinding,
            stagedSource: stagedSource
        )
    }

    func stageSource(
        for job: UpscaleJob
    ) async throws -> R13RetainedSourceSnapshot {
        do {
            return try sourceSnapshotter.createSnapshot(
                sourceURL: job.inputURL,
                jobID: job.identifier,
                jobsRootURL: jobsRootURL
            )
        } catch {
            if error is R13SourceSnapshotCleanupError {
                let recorder = recoveryRecorder(jobID: job.identifier)
                try? await recorder.recordSourceSnapshotCleanupFailed()
            }
            throw error
        }
    }

    func discardStagedSource(
        _ snapshot: R13RetainedSourceSnapshot,
        jobID: String
    ) async -> R13SourceSnapshotCleanupResult {
        let cleanup = R13SourceSnapshotCleanup.discard(
            snapshot,
            using: sourceSnapshotter
        )
        if cleanup.error != nil {
            let recorder = recoveryRecorder(jobID: jobID)
            try? await recorder.recordSourceSnapshotCleanupFailed()
        }
        return cleanup
    }

    func prepare(
        job: UpscaleJob,
        source: SourceProfile,
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding,
        stagedSource: R13RetainedSourceSnapshot
    ) async throws -> R13ReleaseHardeningAttempt {
        do {
            let prepared = try await prepareJobState(
                job: job,
                source: source,
                route: route,
                modeBinding: modeBinding,
                stagedSource: stagedSource
            )
            do {
                let jobIdentitySHA256 =
                    R13CryptoKitRestartDigest().sha256(
                        Data(job.identifier.utf8)
                    )
                let recorder = R13ReleaseHardeningDiagnosticRecorder(
                    diagnostics: diagnostics,
                    jobIdentitySHA256: jobIdentitySHA256,
                    policyResources: documents.policyResources,
                    persistentDiagnostics: persistentDiagnostics,
                    correlationID: UUID(uuidString: job.identifier)
                )
                let faultGate = R13ReleaseFaultGate(
                    injector: faultInjector,
                    recorder: recorder
                )
                try await recorder.recordRecoveryDiscovered(
                    hasCachedPrefix:
                        prepared.plan.verifiedCachedPrefixCount > 0
                )
                try await faultGate.check(.beforeResourceAdmission)
                let request = try R13ResourceRequest(
                    jobIdentity: job.identifier,
                    requiredDiskBytes: prepared.resourceReservationDiskBytes,
                    liveDiskGrowthAllowanceBytes: prepared.liveDiskGrowthAllowanceBytes,
                    requiredMemoryBytes: try Self.requiredWorkingMemoryBytes(
                        source: source.resolution,
                        target: job.targetResolution
                    )
                )
                let admission = await resourceGovernor.admit(request)
                try await recorder.recordAdmission(admission)
                let lease: R13ResourceLease
                switch admission {
                case .admitted(let admittedLease):
                    lease = admittedLease
                case .rejected(let rejection):
                    throw R13ReleaseHardeningError.resourceRejected(
                        rejection
                    )
                case .probeFailed(let probe):
                    throw R13ReleaseHardeningError.resourceProbeFailed(
                        probe
                    )
                }

                do {
                    try await faultGate.check(.afterResourceAdmission)
                    try await recorder.recordIdentity(
                        prepared.identity,
                        route: route
                    )
                    try await recoveryStore.save(job: job)
                    return R13ReleaseHardeningAttempt(
                        identity: prepared.identity,
                        sourceIdentity: prepared.sourceIdentity,
                        sourceSnapshot: stagedSource,
                        sourceSnapshotter: sourceSnapshotter,
                        plan: prepared.plan,
                        store: restartStore,
                        sourceMeasurer: sourceMeasurer,
                        resourceGovernor: resourceGovernor,
                        outputCapacityProbe: outputCapacityProbe,
                        distinctOutputCapacityPlan:
                            prepared.distinctOutputCapacityPlan,
                        cacheReservationBytesPerFrame:
                            prepared.preflight
                                .cacheReservationBytesPerFrame,
                        resourceLease: lease,
                        faultGate: faultGate,
                        recorder: recorder
                    )
                } catch {
                    let release = await resourceGovernor.release(lease)
                    try? await recorder.recordRelease(release)
                    throw error
                }
            } catch {
                if prepared.createdNew {
                    try? await restartStore.discard(
                        jobID: job.identifier
                    )
                }
                throw error
            }
        } catch {
            _ = await discardStagedSource(
                stagedSource,
                jobID: job.identifier
            )
            throw error
        }
    }

    private func createOrReopen(
        core: R13RestartJobCore,
        observedSource: R13RestartSourceIdentity
    ) async throws -> R13RestartPreparation {
        do {
            return R13RestartPreparation(
                plan: try await restartStore.reopen(
                    jobID: core.jobID,
                    expecting: core,
                    observedSource: observedSource
                ),
                createdNew: false
            )
        } catch R13RestartJobError.jobMissing(let jobID)
            where jobID == core.jobID {
            return R13RestartPreparation(
                plan: try await restartStore.create(core),
                createdNew: true
            )
        }
    }

    private func prepareJobState(
        job: UpscaleJob,
        source: SourceProfile,
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding,
        stagedSource: R13RetainedSourceSnapshot
    ) async throws -> R13PreparedHardeningJob {
        let observedSource = stagedSource.identity
        let totalFrameCount = try await frameCounter.exactVideoFrameCount(
            at: stagedSource.processingURL
        )
        let identity = try Self.makeReleaseIdentity(
            job: job,
            route: route,
            modeBinding: modeBinding,
            source: observedSource,
            environment: environmentCollector.collect(),
            policyResources: documents.policyResources
        )
        let core = try Self.makeRestartCore(
            job: job,
            route: route,
            identity: identity,
            source: observedSource,
            totalFrameCount: totalFrameCount
        )
        let restart = try await createOrReopen(
            core: core,
            observedSource: observedSource
        )
        do {
            try await bookmarkStore.save(
                jobID: job.identifier,
                sourceURL: job.inputURL,
                outputDirectoryURL: job.outputURL.deletingLastPathComponent(),
                resolver: bookmarkResolver
            )
            let expectedOutputBytes = try Self.expectedOutputBytes(
                source: source,
                sourceByteCount: observedSource.byteCount,
                job: job
            )
            let outputDirectoryURL = job.outputURL.deletingLastPathComponent()
            let outputSharesCacheVolume = try storagePreflight
                .sharesVolume(jobsRootURL, outputDirectoryURL)
            let distinctOutputCapacityPlan =
                outputSharesCacheVolume ? nil
                : try R13DistinctOutputVolumeCapacityPlan(
                    outputDirectoryURL: outputDirectoryURL,
                    expectedOutputBytes: expectedOutputBytes,
                    minimumFreeDiskBytes:
                        documents.resourcePolicy.minimumFreeDiskBytes
                )
            try distinctOutputCapacityPlan?.verifyAdmission(
                using: outputCapacityProbe
            )
            let remainingFrameCount = max(
                totalFrameCount
                    - restart.plan.verifiedCachedPrefixCount,
                0
            )
            let preflight = try storagePreflight.evaluate(
                R13StoragePreflightRequest(
                    outputWidth: job.targetResolution.width,
                    outputHeight: job.targetResolution.height,
                    totalFrameCount: max(remainingFrameCount, 1),
                    expectedFinalOutputBytes: outputSharesCacheVolume
                        ? expectedOutputBytes : 1,
                    additionalReserveBytes: 67_108_864
                ),
                at: jobsRootURL
            )
            if outputSharesCacheVolume {
                try Self.validateCombinedStorageCapacity(
                    preflight,
                    minimumFreeDiskBytes: documents.resourcePolicy.minimumFreeDiskBytes
                )
            }
            return R13PreparedHardeningJob(
                sourceIdentity: observedSource,
                identity: identity,
                plan: restart.plan,
                preflight: preflight,
                resourceReservationDiskBytes: preflight.requiredBytes,
                liveDiskGrowthAllowanceBytes:
                    outputSharesCacheVolume ? preflight.expectedFinalOutputBytes : 0,
                distinctOutputCapacityPlan: distinctOutputCapacityPlan,
                createdNew: restart.createdNew
            )
        } catch {
            if restart.createdNew {
                try? await restartStore.discard(jobID: job.identifier)
            }
            throw error
        }
    }

}

extension R13ReleaseHardeningRuntime {
    func recoverableJobs() async throws -> R13RecoverableJobCatalog {
        let listing = try await recoveryStore.list()
        var jobs: [R13RecoverableUpscaleJob] = []
        var rejectedEntryCount = listing.rejectedEntryCount
        jobs.reserveCapacity(listing.descriptors.count)
        for descriptor in listing.descriptors {
            do {
                let cachedPrefixCount = try await restartStore
                    .validateRecoverableJob(
                    jobID: descriptor.jobID
                )
                try await bookmarkStore.validateAccessDocument(
                    jobID: descriptor.jobID
                )
                let job = try R13RecoverableUpscaleJob(
                    descriptor: descriptor
                )
                let recorder = recoveryRecorder(
                    jobID: descriptor.jobID
                )
                try? await recorder.recordRecoveryDiscovered(
                    hasCachedPrefix: cachedPrefixCount > 0
                )
                jobs.append(job)
            } catch {
                rejectedEntryCount += 1
            }
        }
        let rejectedRecorder = recoveryRecorder(
            jobID: "rejected-recovery-entry"
        )
        for _ in 0..<rejectedEntryCount {
            try? await rejectedRecorder.recordRecoveryRejected()
        }
        return R13RecoverableJobCatalog(
            jobs: jobs,
            rejectedEntryCount: rejectedEntryCount
        )
    }

    func resolveRecoverableJob(
        id: String
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        let descriptor = try await recoveryStore.load(jobID: id)
        return try await resolveRecoverableJob(descriptor: descriptor)
    }

    func reauthorizeRecoverableJob(
        id: String,
        sourceURL: URL,
        outputDirectoryURL: URL
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        let descriptor = try await recoveryStore.load(jobID: id)
        let observedSource = try sourceMeasurer.measureSource(at: sourceURL)
        try await restartStore.validateRecoverableSource(
            jobID: descriptor.jobID,
            observedSource: observedSource
        )
        let outputURL = outputDirectoryURL.appendingPathComponent(descriptor.outputFilename)
        guard !FileURLIdentity.refersToSameFile(
            sourceURL,
            outputURL
        ) else {
            throw UpscalerEngineError.inputOutputCollision
        }
        try await bookmarkStore.save(
            jobID: descriptor.jobID,
            sourceURL: sourceURL,
            outputDirectoryURL: outputDirectoryURL,
            resolver: bookmarkResolver
        )
        return try await resolveRecoverableJob(descriptor: descriptor)
    }

    private func resolveRecoverableJob(
        descriptor: R13RecoveryDescriptor
    ) async throws -> R13ResolvedRecoverableUpscaleJob {
        _ = try await restartStore.validateRecoverableJob(
            jobID: descriptor.jobID
        )
        let access = try await bookmarkStore.resolveAccess(
            jobID: descriptor.jobID,
            resolver: bookmarkResolver
        )
        let recorder = recoveryRecorder(jobID: descriptor.jobID)
        try? await recorder.recordBookmarkReopened()
        return R13ResolvedRecoverableUpscaleJob(
            summary: try R13RecoverableUpscaleJob(
                descriptor: descriptor
            ),
            job: try descriptor.makeJob(access: access),
            securityAccess: access
        )
    }

    private func recoveryRecorder(jobID: String)
        -> R13ReleaseHardeningDiagnosticRecorder {
        R13ReleaseHardeningDiagnosticRecorder(
            diagnostics: diagnostics,
            jobIdentitySHA256: R13CryptoKitRestartDigest().sha256(
                Data(jobID.utf8)
            ),
            policyResources: documents.policyResources,
            persistentDiagnostics: persistentDiagnostics,
            correlationID: UUID(uuidString: jobID)
        )
    }
}
