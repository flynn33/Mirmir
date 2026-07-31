import Foundation
import XCTest
@testable import Mirmir

// Storage lifecycle scenarios share one fixture and exercise it end to end.
// swiftlint:disable file_length type_body_length

final class R13HardeningStorageLifecycleTests: XCTestCase {
    func testRecoveryDescriptorStoreCanonicalizesSymlinkedRootBeforeTraversal()
        async throws {
        let fileManager = FileManager.default
        let sandbox = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: sandbox) }
        let canonicalRoot = sandbox.appendingPathComponent(
            "Canonical",
            isDirectory: true
        )
        let jobsRoot = canonicalRoot.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        let jobID = "r13-canonical-recovery-root"
        let jobDirectory = jobsRoot.appendingPathComponent(
            jobID,
            isDirectory: true
        )
        let outputDirectory = canonicalRoot.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: jobDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let sourceURL = canonicalRoot.appendingPathComponent("source.mov")
        try Data("recovery-root-source".utf8).write(to: sourceURL)
        let aliasRoot = sandbox.appendingPathComponent(
            "Alias",
            isDirectory: true
        )
        try fileManager.createSymbolicLink(
            at: aliasRoot,
            withDestinationURL: canonicalRoot
        )
        let aliasedJobsRoot = aliasRoot.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        let store = R13RecoveryDescriptorStore(
            jobsRootURL: aliasedJobsRoot
        )
        let job = UpscaleJob(
            identifier: jobID,
            inputURL: sourceURL,
            outputURL: outputDirectory.appendingPathComponent("output.mp4"),
            targetResolution: .p1080,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )

        try await store.save(job: job)
        let listing = try await store.list()

        XCTAssertEqual(listing.descriptors.map(\.jobID), [jobID])
        XCTAssertEqual(listing.rejectedEntryCount, 0)
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: jobDirectory.appendingPathComponent(
                    "recovery-v2.json"
                ).path
            )
        )
    }

    func testCacheRootAndOutputDirectoryCapacityRejectIndependently()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let firstCacheProbe = R13CapacityProbe(capacity: UInt64.max)
        let firstOutputProbe = R13CapacityProbe(capacity: 11)
        let firstRuntime = try fixture.makeRuntime(
            cacheProbe: firstCacheProbe,
            outputProbe: firstOutputProbe
        )

        do {
            _ = try await firstRuntime.prepare(
                job: fixture.makeJob(identifier: "r13-output-capacity"),
                source: fixture.sourceProfile,
                route: .scale3Over2,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .deterministic
                )
            )
            XCTFail("The output volume must reject insufficient capacity.")
        } catch {
            guard case .insufficientDiskSpace(_, let available) =
                    error as? R13RestartJobError else {
                return XCTFail("Unexpected output-volume error: \(error)")
            }
            XCTAssertEqual(available, 11)
        }
        XCTAssertEqual(firstOutputProbe.probedURLs, [fixture.outputDirectory])
        XCTAssertTrue(firstCacheProbe.probedURLs.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: "r13-output-capacity"
                ).path
            )
        )

        let secondCacheProbe = R13CapacityProbe(capacity: 22)
        let secondOutputProbe = R13CapacityProbe(capacity: UInt64.max)
        let secondRuntime = try fixture.makeRuntime(
            cacheProbe: secondCacheProbe,
            outputProbe: secondOutputProbe
        )

        do {
            _ = try await secondRuntime.prepare(
                job: fixture.makeJob(identifier: "r13-cache-capacity"),
                source: fixture.sourceProfile,
                route: .scale3Over2,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .deterministic
                )
            )
            XCTFail("The cache root must reject insufficient capacity.")
        } catch {
            guard case .insufficientDiskSpace(_, let available) =
                    error as? R13RestartJobError else {
                return XCTFail("Unexpected cache-root error: \(error)")
            }
            XCTAssertEqual(available, 22)
        }
        XCTAssertEqual(secondOutputProbe.probedURLs, [fixture.outputDirectory])
        XCTAssertEqual(secondCacheProbe.probedURLs, [fixture.jobsRoot])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: "r13-cache-capacity"
                ).path
            )
        )
    }

    func testFailedReopenNeverDiscardsExistingRecoveryDescriptor()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let job = fixture.makeJob(identifier: "r13-existing-recovery")
        let firstRuntime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let firstAttempt = try await firstRuntime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(for: .deterministic)
        )
        await firstAttempt.releaseResources()
        let descriptorURL = fixture.jobDirectory(
            identifier: job.identifier
        ).appendingPathComponent("recovery-v2.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: descriptorURL.path)
        )

        let failingRuntime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: 1)
        )
        do {
            _ = try await failingRuntime.prepare(
                job: job,
                source: fixture.sourceProfile,
                route: .scale3Over2,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .deterministic
                )
            )
            XCTFail("The existing job must fail output-volume preflight.")
        } catch {
            guard case .insufficientDiskSpace =
                    error as? R13RestartJobError else {
                return XCTFail("Unexpected recovery failure: \(error)")
            }
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: descriptorURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: job.identifier
                ).appendingPathComponent("job-core-v1.json").path
            )
        )
    }

    func testReauthorizationRebindsExactSourceAndPreservesStableJobID()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let job = fixture.makeJob(identifier: "r13-reauthorized")
        let attempt = try await runtime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(for: .deterministic)
        )
        await attempt.releaseResources()
        let reboundSource = fixture.root.appendingPathComponent(
            "reauthorized-source.mov"
        )
        try Data(contentsOf: fixture.sourceURL).write(to: reboundSource)
        let reboundOutput = fixture.root.appendingPathComponent(
            "ReauthorizedOutput",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: reboundOutput,
            withIntermediateDirectories: false
        )

        let rebound = try await runtime.reauthorizeRecoverableJob(
            id: job.identifier,
            sourceURL: reboundSource,
            outputDirectoryURL: reboundOutput
        )

        XCTAssertEqual(rebound.summary.id, job.identifier)
        XCTAssertEqual(rebound.job.identifier, job.identifier)
        XCTAssertEqual(rebound.job.inputURL.path, reboundSource.path)
        XCTAssertEqual(
            rebound.job.outputURL.path,
            reboundOutput.appendingPathComponent(
                job.outputURL.lastPathComponent
            ).path
        )

        let changedSource = fixture.root.appendingPathComponent(
            "changed-source.mov"
        )
        try Data("different-source".utf8).write(to: changedSource)
        do {
            _ = try await runtime.reauthorizeRecoverableJob(
                id: job.identifier,
                sourceURL: changedSource,
                outputDirectoryURL: fixture.outputDirectory
            )
            XCTFail("A different source must not replace recovery access.")
        } catch {
            guard case .sourceDrift =
                    error as? R13RestartJobError else {
                return XCTFail(
                    "Unexpected reauthorization error: \(error)"
                )
            }
        }
        let stillRebound = try await runtime.resolveRecoverableJob(
            id: job.identifier
        )
        XCTAssertEqual(
            stillRebound.job.inputURL.path,
            reboundSource.path
        )
        XCTAssertEqual(
            stillRebound.job.outputURL.deletingLastPathComponent().path,
            reboundOutput.path
        )
    }

    func testCatalogReportsRejectedEntriesWithoutHidingValidRecovery()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let job = fixture.makeJob(identifier: "r13-valid-catalog-job")
        let attempt = try await runtime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(for: .deterministic)
        )
        await attempt.releaseResources()
        let malformedDirectory = fixture.jobsRoot.appendingPathComponent(
            "malformed-catalog-job",
            isDirectory: true
        )
        let orphanDirectory = fixture.jobsRoot.appendingPathComponent(
            "orphan-catalog-job",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: malformedDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: orphanDirectory,
            withIntermediateDirectories: false
        )
        try Data("{\"invalid\":true}".utf8).write(
            to: malformedDirectory.appendingPathComponent(
                "recovery-v2.json"
            )
        )

        let catalog = try await runtime.recoverableJobs()

        XCTAssertEqual(catalog.jobs.map(\.id), [job.identifier])
        XCTAssertEqual(catalog.rejectedEntryCount, 2)
        let diagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertEqual(
            diagnostics.records.filter {
                $0.event.code == .recoveryDiscovered
                    && $0.event.severity == .warning
            }.count,
            2
        )

        try await runtime.discardAllRecoverableJobs()

        let clearedCatalog = try await runtime.recoverableJobs()
        XCTAssertTrue(clearedCatalog.jobs.isEmpty)
        XCTAssertEqual(clearedCatalog.rejectedEntryCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: malformedDirectory.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanDirectory.path)
        )
    }

    func testCatalogRejectsDescriptorWhoseProcessingConfigurationDiffersFromCore()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let job = fixture.makeJob(
            identifier: "r13-mismatched-processing-configuration"
        )
        let attempt = try await runtime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        await attempt.releaseResources()

        let changedConfiguration = UpscaleProcessingConfiguration(
            enginePreference:
                job.processingConfiguration.enginePreference,
            strategyPreference:
                job.processingConfiguration.strategyPreference,
            temporalConsistencyEnabled:
                job.processingConfiguration.temporalConsistencyEnabled,
            edgeFidelityLevel: .high,
            detailRecoveryLevel:
                job.processingConfiguration.detailRecoveryLevel,
            effects: job.processingConfiguration.effects,
            smoothMotion: job.processingConfiguration.smoothMotion
        )
        let changedDescriptor = try R13RecoveryDescriptor(
            job: UpscaleJob(
                identifier: job.identifier,
                inputURL: job.inputURL,
                outputURL: job.outputURL,
                targetResolution: job.targetResolution,
                codec: job.codec,
                preserveAudio: job.preserveAudio,
                mode: job.mode,
                processingConfiguration: changedConfiguration
            )
        )
        try R13RestartCanonical.data(changedDescriptor).write(
            to: fixture.jobDirectory(
                identifier: job.identifier
            ).appendingPathComponent("recovery-v2.json"),
            options: .atomic
        )

        let catalog = try await runtime.recoverableJobs()

        XCTAssertTrue(catalog.jobs.isEmpty)
        XCTAssertEqual(catalog.rejectedEntryCount, 1)
    }

    func testDiscardRecoverableJobRemovesSelectedCacheAndPreservesOthers()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let cachedJob = fixture.makeJob(
            identifier: "r13-discard-cached"
        )
        let retainedJob = fixture.makeJob(
            identifier: "r13-discard-retained"
        )

        let cachedAttempt = try await runtime.prepare(
            job: cachedJob,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        try await cachedAttempt.commit(
            frame: R13NV12Frame.captureTightActivePlanes(
                from: R13ReleaseTestFrames.makeOutput(
                    resolution: .p1080
                )
            ),
            at: 0
        )
        await cachedAttempt.releaseResources()

        let retainedAttempt = try await runtime.prepare(
            job: retainedJob,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        await retainedAttempt.releaseResources()

        let initialCatalog = try await runtime.recoverableJobs()
        XCTAssertEqual(
            initialCatalog.jobs.map(\.id),
            [cachedJob.identifier, retainedJob.identifier]
        )
        XCTAssertEqual(
            initialCatalog.jobs.map(\.cachedFrameCount),
            [1, 0]
        )

        try await runtime.discardRecoverableJob(
            id: cachedJob.identifier
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: cachedJob.identifier
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: retainedJob.identifier
                ).path
            )
        )
        let remainingCatalog = try await runtime.recoverableJobs()
        XCTAssertEqual(
            remainingCatalog.jobs.map(\.id),
            [retainedJob.identifier]
        )
    }

    func testDiscardedResolvedJobCannotRecreateRecoveryOnSubmission()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let job = fixture.makeJob(
            identifier: "r13-discarded-resolved-job"
        )
        let attempt = try await runtime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
        await attempt.releaseResources()
        let resolved = try await runtime.resolveRecoverableJob(
            id: job.identifier
        )

        try await runtime.discardRecoverableJob(id: job.identifier)

        do {
            _ = try await runtime.prepare(
                job: resolved.job,
                source: fixture.sourceProfile,
                route: .scale3Over2,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .deterministic
                ),
                requiresExistingRestartState: true
            )
            XCTFail("Discarded recovery state must not be recreated.")
        } catch {
            XCTAssertEqual(
                error as? R13RestartJobError,
                .jobMissing(job.identifier)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: job.identifier
                ).path
            )
        )
        let catalog = try await runtime.recoverableJobs()
        XCTAssertTrue(catalog.jobs.isEmpty)
    }

    func testSuccessfulCompletionRemovesMultiGigabyteCacheJobDirectory()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let job = fixture.makeJob(identifier: "r13-cache-cleanup")
        let attempt = try await runtime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(for: .deterministic)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: job.identifier
                ).appendingPathComponent("recovery-v2.json").path
            )
        )

        do {
            try await attempt.beforeBackendStart()
            try await attempt.recheckResources()
            try await attempt.commit(
                frame: R13NV12Frame.captureTightActivePlanes(
                    from: R13ReleaseTestFrames.makeOutput(
                        resolution: .p1080
                    )
                ),
                at: 0
            )
            try Data("published-output".utf8).write(
                to: job.outputURL,
                options: .atomic
            )
            try await attempt.validateBeforePublish(
                outputURL: job.outputURL,
                metadata: attempt.identity.timedMetadata
            )
            let jobDirectory = fixture.jobDirectory(
                identifier: job.identifier
            )
            let sparseCacheURL = jobDirectory.appendingPathComponent(
                "multi-gigabyte-cache.sparse"
            )
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: sparseCacheURL.path,
                    contents: nil
                )
            )
            let sparseCache = try FileHandle(forWritingTo: sparseCacheURL)
            try sparseCache.truncate(
                atOffset:
                    R13StorageDisclosures.p1080At30FPSForOneMinute
                        .rawNV12ByteCount
            )
            try sparseCache.close()
            let attributes = try FileManager.default.attributesOfItem(
                atPath: sparseCacheURL.path
            )
            XCTAssertEqual(
                (attributes[.size] as? NSNumber)?.uint64Value,
                R13StorageDisclosures.p1080At30FPSForOneMinute
                    .rawNV12ByteCount
            )

            let output = try R13LocalRestartSourceMeasurer()
                .measureSource(at: job.outputURL)
            try await attempt.completePublishedOutput(
                at: job.outputURL,
                publicationIdentity: MediaOutputPublicationIdentity(
                    sha256: output.sha256,
                    byteCount: output.byteCount
                ),
                mediaCleanupFailed: true
            )
            await attempt.releaseResources()

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: jobDirectory.path)
            )
            let diagnostics = await runtime.diagnosticsSnapshot()
            XCTAssertTrue(
                diagnostics.records.contains { record in
                    record.event.code
                        == .postpublicationMaintenanceDeferred
                        && record.event.fields.contains { field in
                            field.key == .reason
                                && field.value
                                    == R13ReleaseDiagnosticReason
                                        .mediaCleanupFailed.rawValue
                        }
                }
            )
        } catch {
            await attempt.releaseResources()
            throw error
        }
    }
}

extension R13HardeningStorageLifecycleTests {
    func testMismatchedPublicationIdentityCannotAuthorizeCompletion()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let job = fixture.makeJob(identifier: "r13-identity-mismatch")
        let attempt = try await runtime.prepare(
            job: job,
            source: fixture.sourceProfile,
            route: .scale3Over2,
            modeBinding: R13ReleaseModePolicy.binding(for: .deterministic)
        )
        try await attempt.beforeBackendStart()
        try await attempt.recheckResources()
        try await attempt.commit(
            frame: R13NV12Frame.captureTightActivePlanes(
                from: R13ReleaseTestFrames.makeOutput(
                    resolution: .p1080
                )
            ),
            at: 0
        )
        try Data("published-output".utf8).write(to: job.outputURL)
        try await attempt.validateBeforePublish(
            outputURL: job.outputURL,
            metadata: attempt.identity.timedMetadata
        )

        do {
            try await attempt.completePublishedOutput(
                at: job.outputURL,
                publicationIdentity: MediaOutputPublicationIdentity(
                    sha256: String(repeating: "0", count: 64),
                    byteCount: 1
                )
            )
            XCTFail("A different published file identity must not complete.")
        } catch let error as R13RestartJobError {
            XCTAssertEqual(error, .prepublicationReceiptConflict)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.jobDirectory(
                    identifier: job.identifier
                ).path
            )
        )
        let diagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(
            diagnostics.records.contains { record in
                record.event.code == .postpublicationMaintenanceDeferred
                    && record.event.fields.contains { field in
                        field.key == .reason
                            && field.value == R13ReleaseDiagnosticReason
                                .publishedOutputIdentityMismatch.rawValue
                    }
            }
        )
        await attempt.releaseResources()
    }
}

// swiftlint:enable file_length type_body_length
