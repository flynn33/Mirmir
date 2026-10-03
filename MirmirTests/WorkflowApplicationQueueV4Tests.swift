import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

private extension URL {
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private struct WorkflowCacheBookmarkResolverStubV4:
    WorkflowCacheBookmarkResolvingV4 {
    func makeBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(
        _ data: Data
    ) throws -> WorkflowResolvedCacheBookmarkV4 {
        guard let path = String(data: data, encoding: .utf8),
              path.hasPrefix("/") else {
            throw WorkflowCacheLocationErrorV4.bookmarkResolutionFailed
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return WorkflowResolvedCacheBookmarkV4(
            url: url,
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }
}

private struct WorkflowUnavailableCacheBookmarkResolverStubV4:
    WorkflowCacheBookmarkResolvingV4 {
    func makeBookmark(for _: URL) throws -> Data {
        throw WorkflowCacheLocationErrorV4.bookmarkCreationFailed
    }

    func resolveBookmark(
        _: Data
    ) throws -> WorkflowResolvedCacheBookmarkV4 {
        throw WorkflowCacheLocationErrorV4.bookmarkResolutionFailed
    }
}

final class WorkflowApplicationQueueV4Tests: XCTestCase {
    @MainActor
    func testCacheControlsDeleteCompletedFailedCancelledThenPausedContainedAndUnlockLocation()
        async throws {
        let context = try makeCacheControlFixture()
        let queue = try makeQueue(
            fixture: context.fixture,
            tokenFactory: { UUID() }
        )
        let completed = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "completed.mov",
            lifecycle: .completed
        )
        let failed = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "failed.mov",
            lifecycle: .failed
        )
        let cancelled = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "cancelled.mov",
            lifecycle: .cancelled
        )
        let paused = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "paused.mov",
            lifecycle: .paused
        )
        let contained = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "contained.mov",
            lifecycle: .contained
        )
        let destination = context.fixture.outputDirectoryURL
            .appendingPathComponent("completed.mov")
        let destinationBytes = Data("finished-output".utf8)
        try destinationBytes.write(to: destination)
        let viewModel = MirmirViewModel(cacheLocationStore: context.store)
        await viewModel.initializeWorkflow()

        XCTAssertEqual(viewModel.finishedCachedJobCount, 3)
        XCTAssertEqual(viewModel.unfinishedCachedJobCount, 2)
        XCTAssertFalse(viewModel.canChangeCacheLocation)

        await viewModel.deleteCachedJobs(.finished)

        XCTAssertNil(viewModel.cacheLocationErrorMessage)
        XCTAssertEqual(viewModel.finishedCachedJobCount, 0)
        XCTAssertEqual(viewModel.unfinishedCachedJobCount, 2)
        XCTAssertFalse(viewModel.canChangeCacheLocation)
        XCTAssertFalse(cacheJobDirectory(context.fixture, completed).fileExists)
        XCTAssertFalse(cacheJobDirectory(context.fixture, failed).fileExists)
        XCTAssertFalse(cacheJobDirectory(context.fixture, cancelled).fileExists)
        XCTAssertTrue(cacheJobDirectory(context.fixture, paused).fileExists)
        XCTAssertTrue(cacheJobDirectory(context.fixture, contained).fileExists)

        await viewModel.deleteCachedJobs(.unfinished)

        XCTAssertNil(viewModel.cacheLocationErrorMessage)
        XCTAssertEqual(viewModel.finishedCachedJobCount, 0)
        XCTAssertEqual(viewModel.unfinishedCachedJobCount, 0)
        XCTAssertTrue(viewModel.workflowQueueSnapshot?.items.isEmpty == true)
        XCTAssertTrue(viewModel.canChangeCacheLocation)
        XCTAssertFalse(cacheJobDirectory(context.fixture, paused).fileExists)
        XCTAssertFalse(cacheJobDirectory(context.fixture, contained).fileExists)
        XCTAssertEqual(try Data(contentsOf: destination), destinationBytes)
    }

    @MainActor
    func testCacheControlsClearCompletedFailedCancelledPausedContainedAndOrphans()
        async throws {
        let context = try makeCacheControlFixture()
        let queue = try makeQueue(
            fixture: context.fixture,
            tokenFactory: { UUID() }
        )
        let completed = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "completed.mov",
            lifecycle: .completed
        )
        let failed = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "failed.mov",
            lifecycle: .failed
        )
        let cancelled = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "cancelled.mov",
            lifecycle: .cancelled
        )
        let paused = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "paused.mov",
            lifecycle: .paused
        )
        let contained = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "contained.mov",
            lifecycle: .contained
        )
        let jobIDs = [completed, failed, cancelled, paused, contained]
        let orphan = context.fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(
                "job-cache-control-orphan",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )
        try Data("orphan".utf8).write(
            to: orphan.appendingPathComponent("checkpoint")
        )
        let viewModel = MirmirViewModel(cacheLocationStore: context.store)
        await viewModel.initializeWorkflow()
        XCTAssertEqual(viewModel.finishedCachedJobCount, 3)
        XCTAssertEqual(viewModel.unfinishedCachedJobCount, 2)

        await viewModel.clearCache()

        XCTAssertNil(viewModel.cacheLocationErrorMessage)
        XCTAssertEqual(viewModel.finishedCachedJobCount, 0)
        XCTAssertEqual(viewModel.unfinishedCachedJobCount, 0)
        XCTAssertTrue(viewModel.workflowQueueSnapshot?.items.isEmpty == true)
        XCTAssertTrue(viewModel.canChangeCacheLocation)
        for jobID in jobIDs {
            XCTAssertFalse(cacheJobDirectory(context.fixture, jobID).fileExists)
        }
        XCTAssertFalse(orphan.fileExists)
    }

    @MainActor
    func testCacheControlsDeleteContainedRowAndUnlockLocation() async throws {
        let context = try makeCacheControlFixture()
        let queue = try makeQueue(fixture: context.fixture)
        let contained = try await seedCacheJob(
            queue: queue,
            fixture: context.fixture,
            name: "contained.mov",
            lifecycle: .contained
        )
        let viewModel = MirmirViewModel(cacheLocationStore: context.store)
        await viewModel.initializeWorkflow()
        XCTAssertEqual(viewModel.unfinishedCachedJobCount, 1)
        XCTAssertFalse(viewModel.canChangeCacheLocation)

        await viewModel.deleteCachedJob(contained)

        XCTAssertNil(viewModel.cacheLocationErrorMessage)
        XCTAssertEqual(viewModel.unfinishedCachedJobCount, 0)
        XCTAssertTrue(viewModel.workflowQueueSnapshot?.items.isEmpty == true)
        XCTAssertTrue(viewModel.canChangeCacheLocation)
        XCTAssertFalse(cacheJobDirectory(context.fixture, contained).fileExists)
    }

    func testDeleteCachedQueuedJobRemovesStateAndOwnedDirectory()
        async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        let receipt = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )
        let jobDirectory = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(
                receipt.specification.jobID.rawValue,
                isDirectory: true
            )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: jobDirectory.path)
        )

        try await queue.deleteCachedJob(
            jobID: receipt.specification.jobID
        )

        let deletedSnapshot = try await queue.queueSnapshot()
        XCTAssertTrue(deletedSnapshot.items.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: jobDirectory.path)
        )
        let relaunched = try makeQueue(
            fixture: fixture,
            workerID: "application-worker-delete-relaunch"
        )
        let relaunchedSnapshot = try await relaunched.queueSnapshot()
        XCTAssertTrue(relaunchedSnapshot.items.isEmpty)
    }

    func testDeleteCachedJobRejectsActiveLifecycleWithoutRemovingData()
        async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        let receipt = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )
        guard case .claimed = try await queue.claimNextApplicationJob(
            cycleID: WorkflowDispatchCycleIDV4("delete-active-claim")
        ) else {
            return XCTFail("Expected the queued job to be claimed")
        }

        do {
            try await queue.deleteCachedJob(
                jobID: receipt.specification.jobID
            )
            XCTFail("An active cached job must not be deleted")
        } catch let error as WorkflowApplicationQueueErrorV4 {
            XCTAssertEqual(
                error,
                .jobDeletionNotAllowed(
                    jobID: receipt.specification.jobID,
                    lifecycle: .probing
                )
            )
        }
        let retainedSnapshot = try await queue.queueSnapshot()
        XCTAssertEqual(retainedSnapshot.items.count, 1)
    }

    func testBulkFinishedDeletionRemovesTerminalJobsAndPreservesDestinations()
        async throws {
        let fixture = try makeFixture()
        let tokens = WorkflowApplicationTokenSequenceV4([
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
        ])
        let queue = try makeQueue(
            fixture: fixture,
            tokenFactory: { tokens.next() }
        )
        let failedOutput = fixture.outputDirectoryURL.appendingPathComponent(
            "finished-failed.mov"
        )
        let cancelledOutput = fixture.outputDirectoryURL.appendingPathComponent(
            "finished-cancelled.mov"
        )
        let failedBytes = Data("retained-failed-destination".utf8)
        let cancelledBytes = Data("retained-cancelled-destination".utf8)
        try failedBytes.write(to: failedOutput)
        try cancelledBytes.write(to: cancelledOutput)
        let failed = try await queue.enqueue(
            request: request(fixture: fixture, outputName: failedOutput.lastPathComponent),
            preparedPlanBinding: preparedBinding()
        )
        let cancelled = try await queue.enqueue(
            request: request(
                fixture: fixture,
                outputName: cancelledOutput.lastPathComponent
            ),
            preparedPlanBinding: preparedBinding()
        )
        let unfinished = try await queue.enqueue(
            request: request(fixture: fixture, outputName: "unfinished-retained.mov"),
            preparedPlanBinding: preparedBinding()
        )

        guard case .claimed(let failedDispatch) = try await queue
            .claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4("bulk-finished-failed")
            ) else {
            return XCTFail("Expected the failed job to be claimed")
        }
        _ = try await queue.transitionApplicationJob(
            failedDispatch,
            expected: .probing,
            target: .failed,
            commandKey: WorkflowRecoveryCommandKeyV4("bulk-finished-failed"),
            stage: "bulk-finished-failed",
            attemptID: nil,
            releaseAfterTransition: true
        )
        guard case .claimed(let cancelledDispatch) = try await queue
            .claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4("bulk-finished-cancelled")
            ) else {
            return XCTFail("Expected the cancelled job to be claimed")
        }
        _ = try await queue.transitionApplicationJob(
            cancelledDispatch,
            expected: .probing,
            target: .cancelled,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "bulk-finished-cancelled"
            ),
            stage: "bulk-finished-cancelled",
            attemptID: nil,
            releaseAfterTransition: true
        )

        let deletedFinished = try await queue.deleteCachedJobs(
            selection: .finished
        )
        XCTAssertEqual(deletedFinished, 2)
        let snapshot = try await queue.queueSnapshot()
        XCTAssertEqual(snapshot.items.map(\.jobID), [unfinished.specification.jobID])
        XCTAssertFalse(snapshot.items.contains { $0.jobID == failed.specification.jobID })
        XCTAssertFalse(snapshot.items.contains { $0.jobID == cancelled.specification.jobID })
        XCTAssertEqual(try Data(contentsOf: failedOutput), failedBytes)
        XCTAssertEqual(try Data(contentsOf: cancelledOutput), cancelledBytes)
    }

    func testBulkUnfinishedDeletionRemovesInactiveJobsAndRetainsFinishedJobs()
        async throws {
        let fixture = try makeFixture()
        let tokens = WorkflowApplicationTokenSequenceV4([
            UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
        ])
        let queue = try makeQueue(
            fixture: fixture,
            tokenFactory: { tokens.next() }
        )
        let finished = try await queue.enqueue(
            request: request(fixture: fixture, outputName: "finished-retained.mov"),
            preparedPlanBinding: preparedBinding()
        )
        guard case .claimed(let dispatch) = try await queue
            .claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4("bulk-unfinished-finished")
            ) else {
            return XCTFail("Expected the terminal job to be claimed")
        }
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .probing,
            target: .failed,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "bulk-unfinished-finished"
            ),
            stage: "bulk-unfinished-finished",
            attemptID: nil,
            releaseAfterTransition: true
        )
        let queuedFirst = try await queue.enqueue(
            request: request(fixture: fixture, outputName: "queued-first.mov"),
            preparedPlanBinding: preparedBinding()
        )
        let queuedSecond = try await queue.enqueue(
            request: request(fixture: fixture, outputName: "queued-second.mov"),
            preparedPlanBinding: preparedBinding()
        )

        let deletedUnfinished = try await queue.deleteCachedJobs(
            selection: .unfinished
        )
        XCTAssertEqual(deletedUnfinished, 2)
        let snapshot = try await queue.queueSnapshot()
        XCTAssertEqual(snapshot.items.map(\.jobID), [finished.specification.jobID])
        XCTAssertFalse(snapshot.items.contains { $0.jobID == queuedFirst.specification.jobID })
        XCTAssertFalse(snapshot.items.contains { $0.jobID == queuedSecond.specification.jobID })
    }

    func testClearCacheRemovesResidualOwnedJobDirectory() async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        let orphanJobID = try WorkflowJobID("job-residual-cache-test")
        let orphanDirectory = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(orphanJobID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: orphanDirectory,
            withIntermediateDirectories: true
        )
        try Data("residual".utf8).write(
            to: orphanDirectory.appendingPathComponent("checkpoint")
        )

        let result = try await queue.clearApplicationCache()

        XCTAssertEqual(result.deletedJobCount, 0)
        XCTAssertEqual(result.deletedArtifactCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanDirectory.path)
        )
    }

    func testClearCacheRemovesInactiveJobsAndOwnedWorkingArtifactsOnly()
        async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        let destination = fixture.outputDirectoryURL.appendingPathComponent(
            "completed-destination.mov"
        )
        let destinationBytes = Data("completed-output-must-survive".utf8)
        try destinationBytes.write(to: destination)
        _ = try await queue.enqueue(
            request: request(
                fixture: fixture,
                outputName: destination.lastPathComponent
            ),
            preparedPlanBinding: preparedBinding()
        )
        let workingDirectory = fixture.storeURL
            .appendingPathComponent("cache-v4", isDirectory: true)
            .appendingPathComponent(
                "application-working-media-v4",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let ownedArtifact = workingDirectory.appendingPathComponent(
            ".mirmir-job-clear-test.partial.segment.mov"
        )
        let unknownArtifact = workingDirectory.appendingPathComponent(
            "user-file.mov"
        )
        try Data("owned".utf8).write(to: ownedArtifact)
        try Data("unknown".utf8).write(to: unknownArtifact)

        let result = try await queue.clearApplicationCache()
        let snapshot = try await queue.queueSnapshot()

        XCTAssertEqual(result.deletedJobCount, 1)
        XCTAssertEqual(result.deletedArtifactCount, 1)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedArtifact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownArtifact.path))
        XCTAssertEqual(try Data(contentsOf: destination), destinationBytes)
    }

    func testCacheLocationSelectionPersistsAndRestoresDefault() throws {
        let fixture = try makeFixture()
        let selected = fixture.rootURL.appendingPathComponent(
            "ExternalCache",
            isDirectory: true
        )
        let defaultSupport = fixture.rootURL.appendingPathComponent(
            "DefaultSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selected,
            withIntermediateDirectories: true
        )
        let suiteName = "MirmirCacheLocationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let resolver = WorkflowCacheBookmarkResolverStubV4()
        let store = try WorkflowCacheLocationStoreV4(
            applicationIdentifier: "com.mirmir.cache-tests",
            defaults: defaults,
            bookmarkResolver: resolver,
            defaultApplicationSupportProvider: { defaultSupport }
        )

        let defaultConfiguration = try store.configuration()
        XCTAssertEqual(
            defaultConfiguration.workflowRootURL,
            defaultSupport
                .appendingPathComponent(
                    "com.mirmir.cache-tests",
                    isDirectory: true
                )
                .appendingPathComponent("WorkflowV4", isDirectory: true)
        )
        XCTAssertFalse(defaultConfiguration.isCustom)

        let custom = try store.select(selected)
        XCTAssertEqual(
            custom.workflowRootURL,
            selected
                .appendingPathComponent("Mirmir", isDirectory: true)
                .appendingPathComponent("WorkflowV4", isDirectory: true)
        )
        XCTAssertTrue(custom.isCustom)
        XCTAssertTrue(store.status().isAvailable)

        let relaunched = try WorkflowCacheLocationStoreV4(
            applicationIdentifier: "com.mirmir.cache-tests",
            defaults: defaults,
            bookmarkResolver: resolver,
            defaultApplicationSupportProvider: { defaultSupport }
        )
        XCTAssertEqual(
            try relaunched.configuration().workflowRootURL,
            custom.workflowRootURL
        )
        let customPreference = relaunched.preferenceSnapshot()
        XCTAssertFalse(try relaunched.useDefault().isCustom)
        relaunched.restorePreference(customPreference)
        XCTAssertEqual(
            try relaunched.configuration().workflowRootURL,
            custom.workflowRootURL
        )
    }

    func testUnavailableCustomCacheCanRecoverToInternalStorage() throws {
        let fixture = try makeFixture()
        let selected = fixture.rootURL.appendingPathComponent(
            "UnavailableExternalCache",
            isDirectory: true
        )
        let defaultSupport = fixture.rootURL.appendingPathComponent(
            "RecoveryDefaultSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: selected,
            withIntermediateDirectories: true
        )
        let suiteName = "MirmirUnavailableCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let availableStore = try WorkflowCacheLocationStoreV4(
            applicationIdentifier: "com.mirmir.unavailable-cache-tests",
            defaults: defaults,
            bookmarkResolver: WorkflowCacheBookmarkResolverStubV4(),
            defaultApplicationSupportProvider: { defaultSupport }
        )
        _ = try availableStore.select(selected)

        let unavailableStore = try WorkflowCacheLocationStoreV4(
            applicationIdentifier: "com.mirmir.unavailable-cache-tests",
            defaults: defaults,
            bookmarkResolver: WorkflowUnavailableCacheBookmarkResolverStubV4(),
            defaultApplicationSupportProvider: { defaultSupport }
        )
        let unavailableStatus = unavailableStore.status()
        XCTAssertTrue(unavailableStatus.isCustom)
        XCTAssertFalse(unavailableStatus.isAvailable)
        XCTAssertEqual(unavailableStatus.path, selected.path)
        XCTAssertEqual(
            unavailableStatus.availabilityError,
            WorkflowCacheLocationErrorV4.bookmarkResolutionFailed
                .localizedDescription
        )

        let recovered = try unavailableStore.useDefault()
        XCTAssertFalse(recovered.isCustom)
        XCTAssertEqual(
            recovered.workflowRootURL,
            defaultSupport
                .appendingPathComponent(
                    "com.mirmir.unavailable-cache-tests",
                    isDirectory: true
                )
                .appendingPathComponent("WorkflowV4", isDirectory: true)
        )
        XCTAssertTrue(unavailableStore.status().isAvailable)
        XCTAssertFalse(unavailableStore.status().isCustom)
    }
    func testEnqueueAcceptsHardLinkedSourceAndOwnsPrivateSnapshot()
        async throws {
        let fixture = try makeFixture()
        let linkedSource = fixture.rootURL.appendingPathComponent(
            "photos-linked-source.mov"
        )
        try FileManager.default.linkItem(
            at: fixture.inputURL,
            to: linkedSource
        )
        let queue = try makeQueue(fixture: fixture)
        let original = request(fixture: fixture)
        let receipt = try await queue.enqueue(
            request: UpscaleRequest(
                inputURL: linkedSource,
                outputURL: original.outputURL,
                backendID: original.backendID,
                targetWidth: original.targetWidth,
                targetHeight: original.targetHeight,
                outputCodec: original.outputCodec,
                preserveAudio: original.preserveAudio,
                overwriteExistingFile: original.overwriteExistingFile
            ),
            preparedPlanBinding: preparedBinding()
        )

        let activation = await queue.activate(
            jobID: receipt.specification.jobID
        )
        guard case .active(let activated) = activation else {
            return XCTFail("Expected the hard-linked source to activate")
        }
        defer { activated.close() }
        let snapshotURL = activated.request.inputURL
        let sourceAttributes = try FileManager.default.attributesOfItem(
            atPath: linkedSource.path
        )
        let snapshotAttributes = try FileManager.default.attributesOfItem(
            atPath: snapshotURL.path
        )
        XCTAssertGreaterThan(
            (sourceAttributes[.referenceCount] as? NSNumber)?.intValue ?? 0,
            1
        )
        XCTAssertEqual(
            (snapshotAttributes[.referenceCount] as? NSNumber)?.intValue,
            1
        )
        XCTAssertEqual(
            try Data(contentsOf: snapshotURL),
            try Data(contentsOf: linkedSource)
        )
    }

    func testFailedJobResumesOnlyFromVerifiedNonterminalCheckpoint()
        async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        let binding = try preparedBinding()
        let enqueued = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: binding
        )
        guard case .claimed(let dispatch) = try await queue
            .claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4(
                    "failed-checkpoint-resume-claim"
                )
            ) else {
            return XCTFail("Expected the test job to be claimed")
        }
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .probing,
            target: .planned,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "failed-checkpoint-resume-planned"
            ),
            stage: "failed-checkpoint-resume-planned",
            attemptID: nil
        )
        let initialAttempt = try WorkflowAttemptID(
            "failed-checkpoint-resume-initial-attempt"
        )
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .planned,
            target: .running,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "failed-checkpoint-resume-running"
            ),
            stage: "failed-checkpoint-resume-running",
            attemptID: initialAttempt
        )
        let segmentURL = fixture.rootURL.appendingPathComponent(
            "failed-checkpoint-resume-segment.mov"
        )
        try await writePublicationSegment(to: segmentURL)
        let start = try WorkflowMediaTimeV4(value: 0, timescale: 30)
        let end = try WorkflowMediaTimeV4(value: 1, timescale: 30)
        _ = try await queue.commitApplicationCheckpointBoundary(
            dispatch: dispatch,
            specification: enqueued.specification,
            segment: DeterministicV4MediaSegmentResultV4(
                segmentURL: segmentURL,
                startTime: start,
                endTimeExclusive: end,
                inputSampleCount: 1,
                outputSampleCount: 1,
                lastCompletedInputOrdinal: 0,
                terminal: false,
                nextStartTime: end,
                processingDurationSeconds: 0.01
            ),
            outputContractID: binding.outputContractID,
            previousCheckpoint: nil,
            trackProgress: [
                try WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: 1,
                    nextOutputSampleIndex: 1,
                    lastInputTime: end,
                    lastOutputTime: end,
                    isComplete: false
                )
            ],
            temporalCheckpoint: Data("resume-temporal-state".utf8)
        )
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .running,
            target: .failed,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "failed-checkpoint-resume-failed"
            ),
            stage: "failed-checkpoint-resume-failed",
            attemptID: initialAttempt,
            releaseAfterTransition: true
        )
        let staleWorkingURL = try await queue.applicationWorkingSegmentURL(
            jobID: enqueued.specification.jobID,
            boundaryOrdinal: 1
        )
        try Data("uncommitted-boundary".utf8).write(to: staleWorkingURL)

        let resumed = try await queue.resumeApplicationJob(
            jobID: enqueued.specification.jobID,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "failed-checkpoint-resume"
            ),
            attemptID: try WorkflowAttemptID(
                "failed-checkpoint-resume-new-attempt"
            )
        )

        XCTAssertEqual(resumed.claim.lifecycle, .running)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleWorkingURL.path)
        )
    }

    func testCleanLaunchHasImmutableEmptyQueueAndRecoverySnapshots() async throws {
        let fixture = try makeFixture()
        let clock = WorkflowApplicationQueueTestClockV4(7_000_000_000)
        let queue = try makeQueue(fixture: fixture, clock: clock)

        let snapshot = try await queue.launchSnapshot(
            commandKey: WorkflowRecoveryCommandKeyV4("launch-clean")
        )

        XCTAssertEqual(snapshot.queue.generatedAt, clock.now())
        XCTAssertTrue(snapshot.queue.items.isEmpty)
        XCTAssertEqual(snapshot.recovery.generatedAt, clock.now())
        XCTAssertTrue(snapshot.recovery.items.isEmpty)
    }

    func testEnqueueRelaunchAndActivatedRequestRoundTrip() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let clock = WorkflowApplicationQueueTestClockV4(8_000_000_000)
        let original = request(fixture: fixture)
        let admissionBytes = try Data(contentsOf: original.inputURL)
        let binding = try preparedBinding()
        let first = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            clock: clock
        )

        let receipt = try await first.enqueue(
            request: original,
            preparedPlanBinding: binding
        )
        XCTAssertEqual(receipt.specification.source.identityID, binding.sourceIdentityID)
        XCTAssertEqual(receipt.specification.output.contractID, binding.outputContractID)
        XCTAssertEqual(receipt.specification.runtimeBinding.planID, binding.planID)
        XCTAssertEqual(
            receipt.specification.runtimeBinding.runtimeManifestID,
            binding.runtimeManifestID
        )
        XCTAssertEqual(receipt.specification.runtimeBinding.id, binding.runtimeBindingID)

        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            clock: clock,
            workerID: "application-worker-relaunch"
        )
        let snapshot = try await relaunched.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].jobID, receipt.specification.jobID)
        XCTAssertEqual(snapshot.items[0].lifecycle, .queued)
        XCTAssertEqual(snapshot.items[0].queueOrdinal, 0)
        XCTAssertEqual(snapshot.items[0].requestRecordStatus, .ready)
        XCTAssertEqual(snapshot.items[0].request?.targetWidth, original.targetWidth)
        XCTAssertEqual(snapshot.items[0].request?.targetHeight, original.targetHeight)
        XCTAssertEqual(snapshot.items[0].request?.outputCodec, original.outputCodec)

        let recovery = await relaunched.recoverAtLaunch(
            commandKey: try WorkflowRecoveryCommandKeyV4("launch-relaunch")
        )
        XCTAssertEqual(recovery.items.count, 1)
        XCTAssertEqual(recovery.items[0].jobID, receipt.specification.jobID)
        XCTAssertEqual(recovery.items[0].status, .idle)

        let activation = await relaunched.activate(
            jobID: receipt.specification.jobID
        )
        guard case .active(let activated) = activation else {
            return XCTFail("Expected all bookmark capabilities to activate")
        }
        defer { activated.close() }
        try activated.revalidateAll()
        XCTAssertNotEqual(
            activated.request.inputURL.standardizedFileURL,
            original.inputURL.standardizedFileURL
        )
        XCTAssertEqual(
            activated.request.inputURL.lastPathComponent,
            original.inputURL.lastPathComponent
        )
        XCTAssertTrue(
            activated.request.inputURL.path.hasPrefix(fixture.storeURL.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: activated.request.inputURL),
            admissionBytes
        )
        let snapshotAttributes = try FileManager.default.attributesOfItem(
            atPath: activated.request.inputURL.path
        )
        XCTAssertEqual(
            (snapshotAttributes[.posixPermissions] as? NSNumber)?.uint16Value,
            0o400
        )
        XCTAssertEqual(
            activated.sourceSnapshot.byteCount,
            UInt64(admissionBytes.count)
        )
        XCTAssertEqual(
            activated.request.outputURL.standardizedFileURL,
            original.outputURL.standardizedFileURL
        )
        XCTAssertEqual(activated.request.backendID, original.backendID)
        XCTAssertEqual(activated.request.targetWidth, original.targetWidth)
        XCTAssertEqual(activated.request.targetHeight, original.targetHeight)
        XCTAssertEqual(activated.request.outputCodec, original.outputCodec)
        XCTAssertEqual(activated.request.preserveAudio, original.preserveAudio)
        XCTAssertEqual(
            activated.request.overwriteExistingFile,
            original.overwriteExistingFile
        )
        XCTAssertEqual(
            activated.cacheDirectoryURL.standardizedFileURL,
            fixture.storeURL
                .appendingPathComponent("cache-v4", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(
            activated.bookmarkReceipts.map(\.role),
            WorkflowScopedResourceRoleV4.allCases.sorted()
        )
    }

    func testBackslashSourceBasenameSurvivesQueueRelaunchBinding()
        async throws
    {
        let sourceName = #"original\selected-source.mov"#
        let fixture = try makeFixture(inputFileName: sourceName)
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let first = try makeQueue(fixture: fixture, resolver: resolver)
        let receipt = try await first.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )

        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-backslash-relaunch"
        )
        let activation = await relaunched.activate(
            jobID: receipt.specification.jobID
        )
        guard case .active(let activated) = activation else {
            return XCTFail(
                "A legal macOS backslash basename must survive relaunch"
            )
        }
        defer { activated.close() }

        XCTAssertEqual(activated.request.inputURL.lastPathComponent, sourceName)
        XCTAssertTrue(
            activated.sourceSnapshot.relativePath.hasSuffix("/\(sourceName)")
        )
        XCTAssertEqual(
            try Data(contentsOf: activated.request.inputURL),
            Data("source-media".utf8)
        )
        try activated.revalidateAll()
    }

    func testFoundationResolverRegistersPrivateApplicationSourceSnapshot()
        async throws
    {
        let fixture = try makeFixture()
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: fixture.storeURL,
            workerID: try WorkflowWorkerIDV4(
                "application-worker-foundation-bookmarks"
            ),
            resolver: WorkflowFoundationSecurityScopedBookmarkResolverV4(),
            clock: WorkflowApplicationQueueTestClockV4(8_500_000_000),
            tokenFactory: {
                UUID(
                    uuidString:
                        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
                )!
            }
        )

        let receipt = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )
        let relaunched = try WorkflowApplicationQueueV4(
            trustedRootURL: fixture.storeURL,
            workerID: try WorkflowWorkerIDV4(
                "application-worker-foundation-bookmarks-relaunch"
            ),
            resolver: WorkflowFoundationSecurityScopedBookmarkResolverV4(),
            clock: WorkflowApplicationQueueTestClockV4(8_500_000_001)
        )
        let activation = await relaunched.activate(
            jobID: receipt.specification.jobID
        )
        guard case .active(let activated) = activation else {
            return XCTFail(
                "Foundation bookmarks must activate the private source snapshot"
            )
        }
        defer { activated.close() }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: activated.request.inputURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
            0o400
        )
        XCTAssertEqual(
            try Data(contentsOf: activated.request.inputURL),
            Data("source-media".utf8)
        )
        try activated.revalidateAll()
    }

    func testTamperedRequestIsContainedWithoutChangingJournalLifecycle() async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        let receipt = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )
        let documentURL = await queue.requestDocumentURL(
            jobID: receipt.specification.jobID
        )
        var bytes = try Data(contentsOf: documentURL)
        bytes.append(0x20)
        try bytes.write(to: documentURL, options: .atomic)

        let snapshot = try await queue.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].lifecycle, .queued)
        XCTAssertEqual(snapshot.items[0].requestRecordStatus, .corrupt)
        XCTAssertNil(snapshot.items[0].request)

        let activation = await queue.activate(jobID: receipt.specification.jobID)
        guard case .blocked(let reason) = activation else {
            return XCTFail("A noncanonical request document must fail closed")
        }
        XCTAssertEqual(reason, .requestDocumentCorrupt)
    }

    func testRequestEnvelopeV1MigratesAtomicallyOnRelaunch() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let first = try makeQueue(fixture: fixture, resolver: resolver)
        let receipt = try await first.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )
        let documentURL = await first.requestDocumentURL(
            jobID: receipt.specification.jobID
        )
        let current = try Data(contentsOf: documentURL)
        let legacy = try legacyApplicationRequestDocument(
            from: current,
            envelopeSchemaVersion:
                WorkflowApplicationRequestEnvelopeSchemaV4.legacy
        )
        try legacy.write(to: documentURL, options: .atomic)

        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-migration"
        )
        let snapshot = try await relaunched.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].requestRecordStatus, .ready)
        XCTAssertEqual(snapshot.items[0].jobID, receipt.specification.jobID)

        let migrated = try Data(contentsOf: documentURL)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: migrated
            ).schemaVersion,
            WorkflowApplicationRequestEnvelopeSchemaV4.current
        )
        XCTAssertEqual(migrated, current)
    }

    func testVerifiedLegacySourceSnapshotRequiresReenqueueBeforeDispatch()
        async throws
    {
        let fixture = try makeFixture(inputFileName: "source.mov")
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let first = try makeQueue(fixture: fixture, resolver: resolver)
        let requested = request(fixture: fixture)
        let binding = try preparedBinding()
        let receipt = try await first.enqueue(
            request: requested,
            preparedPlanBinding: binding
        )
        let jobID = receipt.specification.jobID
        let documentURL = await first.requestDocumentURL(jobID: jobID)
        let current = try Data(contentsOf: documentURL)
        XCTAssertEqual(
            try canonicalSourceFileName(in: current),
            "source.mov"
        )

        // Reproduce the authenticated deployed v2 shape: the snapshot uses
        // the fixed legacy basename, while no original basename was recorded.
        let legacy = try legacyApplicationRequestDocument(
            from: current,
            envelopeSchemaVersion:
                WorkflowApplicationRequestEnvelopeSchemaV4
                    .legacyWithPreparedPlanBinding
        )
        try legacy.write(to: documentURL, options: .atomic)

        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-legacy-source-migration"
        )
        let beforeDispatch = try await relaunched.queueSnapshot()
        XCTAssertEqual(beforeDispatch.items.count, 1)
        XCTAssertEqual(beforeDispatch.items[0].jobID, jobID)
        XCTAssertEqual(beforeDispatch.items[0].lifecycle, .queued)
        XCTAssertEqual(
            beforeDispatch.items[0].requestRecordStatus,
            .legacySourceSnapshotRequiresReenqueue
        )
        XCTAssertEqual(
            beforeDispatch.items[0].request?.targetWidth,
            requested.targetWidth
        )
        XCTAssertEqual(
            beforeDispatch.items[0].request?.targetHeight,
            requested.targetHeight
        )
        XCTAssertEqual(
            beforeDispatch.items[0].request?.outputCodec,
            requested.outputCodec
        )
        XCTAssertEqual(
            beforeDispatch.items[0].request?.preserveAudio,
            requested.preserveAudio
        )
        XCTAssertEqual(
            beforeDispatch.items[0].request?.overwriteExistingFile,
            requested.overwriteExistingFile
        )

        let migrated = try Data(contentsOf: documentURL)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: migrated
            ).schemaVersion,
            WorkflowApplicationRequestEnvelopeSchemaV4.current
        )
        XCTAssertNil(try canonicalSourceFileName(in: migrated))

        let activation = await relaunched.activate(jobID: jobID)
        guard case let .blocked(reason) = activation else {
            return XCTFail(
                "An ambiguous legacy basename must require a fresh enqueue"
            )
        }
        XCTAssertEqual(
            reason,
            .legacySourceSnapshotRequiresReenqueue(
                snapshotFileName: "source.mov"
            )
        )

        do {
            _ = try await relaunched.claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4(
                    "legacy-source-migration-cycle"
                )
            )
            XCTFail("The legacy job must be failed before dispatcher claim")
        } catch let error as WorkflowApplicationQueueErrorV4 {
            XCTAssertEqual(
                error,
                .legacySourceSnapshotRequiresReenqueue(
                    jobID: jobID,
                    snapshotFileName: "source.mov"
                )
            )
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Re-enqueue the original source"
                )
            )
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "none of its checkpoints will be reused"
                )
            )
        }

        let afterDispatch = try await relaunched.queueSnapshot()
        XCTAssertEqual(afterDispatch.items.count, 1)
        XCTAssertEqual(afterDispatch.items[0].lifecycle, .failed)
        XCTAssertNil(afterDispatch.items[0].queueOrdinal)
        XCTAssertEqual(
            afterDispatch.items[0].requestRecordStatus,
            .legacySourceSnapshotRequiresReenqueue
        )
        let snapshotURL = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobID.rawValue, isDirectory: true)
            .appendingPathComponent("source-snapshot-v4", isDirectory: true)
            .appendingPathComponent("source.mov", isDirectory: false)
        XCTAssertEqual(
            try Data(contentsOf: snapshotURL),
            Data("source-media".utf8)
        )
        let incompatibleCheckpoint = try await relaunched
            .compatibleApplicationCheckpoint(
                jobID: jobID,
                outputContractID: binding.outputContractID,
                sourceSnapshotIdentityID: nil
            )
        XCTAssertNil(
            incompatibleCheckpoint
        )
        let retry = try await relaunched.claimNextApplicationJob(
            cycleID: WorkflowDispatchCycleIDV4(
                "legacy-source-migration-retry-cycle"
            )
        )
        guard case .noEligibleJob = retry else {
            return XCTFail("A failed legacy job must never be dispatchable")
        }
    }

    func testBookmarkDenialAndOriginalPathReplacementUsesAdmissionSnapshot()
        async throws
    {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let queue = try makeQueue(fixture: fixture, resolver: resolver)
        let admissionBytes = try Data(contentsOf: fixture.inputURL)
        let receipt = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )

        resolver.deniedRole = .inputFile
        let denied = await queue.activate(jobID: receipt.specification.jobID)
        guard case .blocked(.bookmarkBlocked(let deniedFailures)) = denied else {
            return XCTFail("Denied input scope must be contained")
        }
        XCTAssertEqual(
            deniedFailures,
            [
                WorkflowBookmarkActivationFailureV4(
                    role: .inputFile,
                    reason: .accessDenied
                )
            ]
        )

        resolver.deniedRole = nil
        try FileManager.default.removeItem(at: fixture.inputURL)
        try Data("replacement".utf8).write(to: fixture.inputURL)
        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-original-replaced"
        )
        let replaced = await relaunched.activate(
            jobID: receipt.specification.jobID
        )
        guard case .active(let activated) = replaced else {
            return XCTFail("Original path replacement must not affect the private snapshot")
        }
        defer { activated.close() }
        XCTAssertNotEqual(
            activated.request.inputURL.standardizedFileURL,
            fixture.inputURL.standardizedFileURL
        )
        XCTAssertEqual(
            try Data(contentsOf: activated.request.inputURL),
            admissionBytes
        )
    }

    func testTamperedPrivateSourceSnapshotFailsClosedAcrossRelaunch()
        async throws
    {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let first = try makeQueue(fixture: fixture, resolver: resolver)
        let receipt = try await first.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding()
        )
        let firstActivation = await first.activate(
            jobID: receipt.specification.jobID
        )
        guard case .active(let activated) = firstActivation else {
            return XCTFail("Expected the authenticated snapshot to activate")
        }
        let snapshotURL = activated.request.inputURL
        activated.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshotURL.path
        )
        try Data("snapshot-tamper".utf8).write(to: snapshotURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: snapshotURL.path
        )

        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-snapshot-tamper"
        )
        let result = await relaunched.activate(
            jobID: receipt.specification.jobID
        )
        guard case .blocked(let failure) = result else {
            return XCTFail("A changed private snapshot must fail closed")
        }
        XCTAssertEqual(failure, .sourceSnapshotInvalid)
    }

    func testBookmarkRegistrationFailureCannotPublishAQueuedJob() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        resolver.failedBookmarkCreationRole = .inputFile
        let queue = try makeQueue(fixture: fixture, resolver: resolver)

        do {
            _ = try await queue.enqueue(
                request: request(fixture: fixture),
                preparedPlanBinding: preparedBinding()
            )
            XCTFail("Expected bookmark creation to fail")
        } catch WorkflowApplicationBookmarkResolverStubErrorV4.injectedFailure {
            // Expected.
        }

        let snapshot = try await queue.queueSnapshot()
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testPreparedBindingRejectsMismatchedCanonicalAggregateHash() throws {
        let valid = try preparedBinding()
        XCTAssertThrowsError(
            try WorkflowVerifiedPreparedPlanBindingV4(
                sourceIdentityID: valid.sourceIdentityID,
                outputContractID: valid.outputContractID,
                runtimeManifestID: valid.runtimeManifestID,
                planID: valid.planID,
                workflowBackendID: valid.workflowBackendID,
                backendRevisionID: valid.backendRevisionID,
                mediaContractID: valid.mediaContractID,
                resolvedBackendID: valid.resolvedBackendID,
                expectedRuntimeBindingID: WorkflowRuntimeBindingID(
                    workflowApplicationDigest(99)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkflowApplicationQueueErrorV4,
                .preparedBindingHashMismatch
            )
        }
    }

    func testPriorityAndQueueOrderSurviveRelaunchAndDriveDispatch() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let tokens = WorkflowApplicationTokenSequenceV4([
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        ])
        let firstQueue = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            tokenFactory: { tokens.next() }
        )
        let first = try await firstQueue.enqueue(
            request: request(fixture: fixture, outputName: "first.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 5
        )
        let second = try await firstQueue.enqueue(
            request: request(fixture: fixture, outputName: "second.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 20
        )
        let third = try await firstQueue.enqueue(
            request: request(fixture: fixture, outputName: "third.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 20
        )

        XCTAssertEqual(first.priority, 5)
        XCTAssertEqual(second.priority, 20)
        XCTAssertEqual(third.priority, 20)
        let initialSnapshot = try await firstQueue.queueSnapshot()
        XCTAssertEqual(
            initialSnapshot.items.map(\.jobID),
            [second.specification.jobID, third.specification.jobID,
             first.specification.jobID]
        )

        try await firstQueue.moveApplicationJob(
            jobID: third.specification.jobID,
            direction: .earlier
        )
        let relaunched = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-priority-relaunch",
            tokenFactory: { tokens.next() }
        )
        let relaunchedSnapshot = try await relaunched.queueSnapshot()
        XCTAssertEqual(
            relaunchedSnapshot.items.map(\.jobID),
            [third.specification.jobID, second.specification.jobID,
             first.specification.jobID]
        )
        XCTAssertEqual(relaunchedSnapshot.items.map(\.priority), [20, 20, 5])

        try await relaunched.setApplicationJobPriority(
            jobID: first.specification.jobID,
            value: 40
        )
        let dispatch = try await relaunched.claimNextApplicationJob(
            cycleID: WorkflowDispatchCycleIDV4("priority-relaunch-cycle")
        )
        guard case .claimed(let receipt) = dispatch else {
            return XCTFail("The highest-priority durable job was not claimed.")
        }
        XCTAssertEqual(receipt.claim.jobID, first.specification.jobID)
        XCTAssertEqual(receipt.priority, 40)
    }

    func testCorruptPriorityDocumentFailsClosed() async throws {
        let fixture = try makeFixture()
        let queue = try makeQueue(fixture: fixture)
        _ = try await queue.enqueue(
            request: request(fixture: fixture),
            preparedPlanBinding: preparedBinding(),
            priority: 7
        )
        let priorityURL = fixture.storeURL.appendingPathComponent(
            "application-priorities-v1.json"
        )
        var data = try Data(contentsOf: priorityURL)
        data.append(0x20)
        try data.write(to: priorityURL, options: .atomic)

        do {
            _ = try await queue.queueSnapshot()
            XCTFail("A noncanonical priority document must fail closed.")
        } catch let error as WorkflowApplicationQueueErrorV4 {
            XCTAssertEqual(error, .priorityDocumentCorrupt)
        }
    }

    func testLaunchAutomaticallyDispatchesPersistedJobsInPriorityOrder()
        async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let tokens = WorkflowApplicationTokenSequenceV4([
            UUID(uuidString: "aaaaaaaa-1111-1111-1111-111111111111")!,
            UUID(uuidString: "bbbbbbbb-2222-2222-2222-222222222222")!,
            UUID(uuidString: "cccccccc-3333-3333-3333-333333333333")!,
            UUID(uuidString: "dddddddd-4444-4444-4444-444444444444")!,
        ])
        let beforeKill = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-before-kill",
            tokenFactory: { tokens.next() }
        )
        let first = try await beforeKill.enqueue(
            request: request(fixture: fixture, outputName: "a.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 0
        )
        let second = try await beforeKill.enqueue(
            request: request(fixture: fixture, outputName: "b.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 50
        )
        let third = try await beforeKill.enqueue(
            request: request(fixture: fixture, outputName: "c.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 50
        )
        try await beforeKill.moveApplicationJob(
            jobID: third.specification.jobID,
            direction: .earlier
        )

        // This new queue/coordinator pair models a fresh application process:
        // no in-memory submit call or waiter survives the boundary.
        let afterRelaunch = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-after-kill",
            tokenFactory: { tokens.next() }
        )
        let recorder = WorkflowApplicationDispatchRecorderV4()
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: afterRelaunch,
            engine: WorkflowApplicationFailingEngineV4(recorder: recorder)
        )
        _ = try await coordinator.launch()

        let observed = await recorder.waitForCount(3)
        XCTAssertEqual(
            observed,
            [third.specification.jobID, second.specification.jobID,
             first.specification.jobID]
        )
        let snapshot = try await coordinator.queueSnapshot()
        XCTAssertEqual(snapshot.items.map(\.lifecycle), [.failed, .failed, .failed])
        XCTAssertEqual(snapshot.items.map(\.priority), [0, 50, 50])
    }

    func testAutonomousDrainRetriesAfterAnotherWorkerReleasesCapacity()
        async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let tokens = WorkflowApplicationTokenSequenceV4([
            UUID(uuidString: "eeeeeeee-1111-1111-1111-111111111111")!,
            UUID(uuidString: "ffffffff-2222-2222-2222-222222222222")!,
        ])
        let holder = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-capacity-holder",
            tokenFactory: { tokens.next() }
        )
        let held = try await holder.enqueue(
            request: request(fixture: fixture, outputName: "held.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 100
        )
        let waiting = try await holder.enqueue(
            request: request(fixture: fixture, outputName: "waiting.mov"),
            preparedPlanBinding: preparedBinding(),
            priority: 0
        )
        let initial = try await holder.claimNextApplicationJob(
            cycleID: WorkflowDispatchCycleIDV4("capacity-holder-cycle")
        )
        guard case .claimed(let heldDispatch) = initial else {
            return XCTFail("The capacity-holder job was not claimed.")
        }
        XCTAssertEqual(heldDispatch.claim.jobID, held.specification.jobID)

        let contender = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-capacity-contender"
        )
        let recorder = WorkflowApplicationDispatchRecorderV4()
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: contender,
            engine: WorkflowApplicationFailingEngineV4(recorder: recorder)
        )
        _ = try await coordinator.launch()
        try await Task.sleep(nanoseconds: 150_000_000)
        let beforeRelease = await recorder.values()
        XCTAssertEqual(beforeRelease, [])

        _ = try await holder.transitionApplicationJob(
            heldDispatch,
            expected: .probing,
            target: .failed,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "capacity-holder-release"
            ),
            stage: "capacity-holder-release",
            attemptID: nil,
            releaseAfterTransition: true
        )

        let afterRelease = await recorder.waitForCount(1)
        XCTAssertEqual(afterRelease, [waiting.specification.jobID])
    }

    func testPublicationRecoversExclusiveRenameBeforeDurableReceipt()
        async throws {
        let context = try await makeTerminalPublicationContext()
        defer { context.activated.close() }
        let intent = try await context.queue.prepareApplicationPublication(
            activated: context.activated,
            checkpoint: context.checkpoint
        )
        let stagingURL = try await context.queue
            .applicationPublicationStagingURL(
                intent,
                activated: context.activated
            )
        let expected = Data("new-published-output".utf8)
        try expected.write(to: stagingURL)
        _ = try await context.queue.recordApplicationStagedPublication(
            intent,
            finalized: WorkflowApplicationFinalizedOutputV4(
                destinationURL: stagingURL,
                verification: try publicationVerification()
            ),
            activated: context.activated
        )

        await context.queue
            .injectProcessTerminationAfterApplicationPublicationRename()
        do {
            _ = try await context.queue.publishApplicationStagedOutput(
                intent,
                activated: context.activated
            )
            XCTFail("Expected the post-rename qualification fault.")
        } catch let error as WorkflowApplicationQueueErrorV4 {
            XCTAssertEqual(error, .injectedPublicationTermination)
        }
        XCTAssertEqual(try Data(contentsOf: context.outputURL), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        var state = try await context.queue.applicationPublicationState(
            jobID: intent.jobID
        )
        XCTAssertEqual(state?.stageIsVerified, true)
        XCTAssertEqual(state?.isPublished, false)

        let recovered = try await context.queue.publishApplicationStagedOutput(
            intent,
            activated: context.activated
        )
        let replayed = try await context.queue.publishApplicationStagedOutput(
            intent,
            activated: context.activated
        )
        XCTAssertEqual(recovered, replayed)
        state = try await context.queue.applicationPublicationState(
            jobID: intent.jobID
        )
        XCTAssertEqual(state?.isPublished, true)
        XCTAssertEqual(try Data(contentsOf: context.outputURL), expected)
    }

    func testPublicationRecoversAtomicOverwriteAndRemovesDisplacedFile()
        async throws {
        let context = try await makeTerminalPublicationContext()
        defer { context.activated.close() }
        let original = Data("original-user-output".utf8)
        try original.write(to: context.outputURL)
        let intent = try await context.queue.prepareApplicationPublication(
            activated: context.activated,
            checkpoint: context.checkpoint
        )
        let stagingURL = try await context.queue
            .applicationPublicationStagingURL(
                intent,
                activated: context.activated
            )
        let replacement = Data("replacement-output".utf8)
        try replacement.write(to: stagingURL)
        _ = try await context.queue.recordApplicationStagedPublication(
            intent,
            finalized: WorkflowApplicationFinalizedOutputV4(
                destinationURL: stagingURL,
                verification: try publicationVerification()
            ),
            activated: context.activated
        )

        await context.queue
            .injectProcessTerminationAfterApplicationPublicationRename()
        do {
            _ = try await context.queue.publishApplicationStagedOutput(
                intent,
                activated: context.activated
            )
            XCTFail("Expected the post-swap qualification fault.")
        } catch WorkflowApplicationQueueErrorV4
            .injectedPublicationTermination {
            // The directory now contains the new final and displaced original.
        }
        XCTAssertEqual(try Data(contentsOf: context.outputURL), replacement)
        XCTAssertEqual(try Data(contentsOf: stagingURL), original)

        _ = try await context.queue.publishApplicationStagedOutput(
            intent,
            activated: context.activated
        )
        XCTAssertEqual(try Data(contentsOf: context.outputURL), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    }

    func testPublicationRejectsTamperedVerifiedStageBeforeFinalRename()
        async throws {
        let context = try await makeTerminalPublicationContext()
        defer { context.activated.close() }
        let intent = try await context.queue.prepareApplicationPublication(
            activated: context.activated,
            checkpoint: context.checkpoint
        )
        let stagingURL = try await context.queue
            .applicationPublicationStagingURL(
                intent,
                activated: context.activated
            )
        try Data("verified".utf8).write(to: stagingURL)
        _ = try await context.queue.recordApplicationStagedPublication(
            intent,
            finalized: WorkflowApplicationFinalizedOutputV4(
                destinationURL: stagingURL,
                verification: try publicationVerification()
            ),
            activated: context.activated
        )
        try Data("tampered".utf8).write(to: stagingURL, options: .atomic)

        do {
            _ = try await context.queue.publishApplicationStagedOutput(
                intent,
                activated: context.activated
            )
            XCTFail("A changed verified stage must not become the final file.")
        } catch let error as WorkflowApplicationQueueErrorV4 {
            switch error {
            case .publicationStageMissing, .publicationStageConflict:
                break
            default:
                XCTFail("Unexpected publication error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: context.outputURL.path)
        )
    }

    func testPublicationReverifiesCompleteSourceSnapshotBeforeFinalRename()
        async throws
    {
        let context = try await makeTerminalPublicationContext()
        defer { context.activated.close() }
        let intent = try await context.queue.prepareApplicationPublication(
            activated: context.activated,
            checkpoint: context.checkpoint
        )
        let stagingURL = try await context.queue
            .applicationPublicationStagingURL(
                intent,
                activated: context.activated
            )
        try Data("verified-publication".utf8).write(to: stagingURL)
        _ = try await context.queue.recordApplicationStagedPublication(
            intent,
            finalized: WorkflowApplicationFinalizedOutputV4(
                destinationURL: stagingURL,
                verification: try publicationVerification()
            ),
            activated: context.activated
        )
        let snapshotURL = context.activated.request.inputURL
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshotURL.path
        )
        try Data("changed-before-publication".utf8).write(to: snapshotURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: snapshotURL.path
        )

        do {
            _ = try await context.queue.publishApplicationStagedOutput(
                intent,
                activated: context.activated
            )
            XCTFail("A changed source snapshot must block final publication")
        } catch WorkflowApplicationQueueErrorV4.sourceSnapshotInvalid {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: context.outputURL.path)
            )
        }
    }

    func testCoordinatorLaunchReconcilesPostRenameProcessTermination()
        async throws {
        let context = try await makeTerminalPublicationContext()
        let jobID = context.activated.specification.jobID
        let sourceSnapshotURL = context.activated.request.inputURL
        let intent = try await context.queue.prepareApplicationPublication(
            activated: context.activated,
            checkpoint: context.checkpoint
        )
        let stagingURL = try await context.queue
            .applicationPublicationStagingURL(
                intent,
                activated: context.activated
            )
        let expected = Data("launch-recovered-output".utf8)
        try expected.write(to: stagingURL)
        _ = try await context.queue.recordApplicationStagedPublication(
            intent,
            finalized: WorkflowApplicationFinalizedOutputV4(
                destinationURL: stagingURL,
                verification: try publicationVerification()
            ),
            activated: context.activated
        )
        await context.queue
            .injectProcessTerminationAfterApplicationPublicationRename()
        do {
            _ = try await context.queue.publishApplicationStagedOutput(
                intent,
                activated: context.activated
            )
            XCTFail("Expected publication termination before its receipt.")
        } catch WorkflowApplicationQueueErrorV4
            .injectedPublicationTermination {
            // The new final file is durable and the receipt is intentionally
            // absent, matching abrupt kernel process termination.
        }
        context.activated.close()
        await context.queue
            .injectProcessTerminationAfterApplicationLeasePersistence()

        let relaunchedQueue = try makeQueue(
            fixture: context.fixture,
            resolver: context.resolver,
            clock: WorkflowApplicationQueueTestClockV4(50_000_000_000),
            workerID: "application-worker-publication-relaunch"
        )
        let engine = WorkflowApplicationPublicationRecoveryEngineV4(
            source: workflowApplicationVideoInfo(
                url: context.fixture.inputURL
            )
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: relaunchedQueue,
            engine: engine
        )
        let launch = try await coordinator.launch()
        XCTAssertEqual(
            launch.queue.items.first { $0.jobID == jobID }?.lifecycle,
            .completed
        )
        XCTAssertEqual(try Data(contentsOf: context.outputURL), expected)
        let publication = try await relaunchedQueue
            .applicationPublicationState(jobID: jobID)
        XCTAssertEqual(publication?.stageIsVerified, true)
        XCTAssertEqual(publication?.isPublished, true)
        let counts = await engine.operationCounts()
        XCTAssertEqual(counts.revalidations, 1)
        XCTAssertEqual(counts.terminalSourceValidations, 1)
        XCTAssertEqual(counts.inspections, 1)
        XCTAssertEqual(counts.finalizations, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sourceSnapshotURL.path)
        )
    }

    func testCoordinatorLaunchRecordsPublicationRecoveryFailureInInjectedDiagnostics()
        async throws {
        let context = try await makeTerminalPublicationContext()
        let jobID = context.activated.specification.jobID
        let intent = try await context.queue.prepareApplicationPublication(
            activated: context.activated,
            checkpoint: context.checkpoint
        )
        let stagingURL = try await context.queue
            .applicationPublicationStagingURL(
                intent,
                activated: context.activated
            )
        try Data("diagnostic-recovery-output".utf8).write(to: stagingURL)
        _ = try await context.queue.recordApplicationStagedPublication(
            intent,
            finalized: WorkflowApplicationFinalizedOutputV4(
                destinationURL: stagingURL,
                verification: try publicationVerification()
            ),
            activated: context.activated
        )
        await context.queue
            .injectProcessTerminationAfterApplicationPublicationRename()
        do {
            _ = try await context.queue.publishApplicationStagedOutput(
                intent,
                activated: context.activated
            )
            XCTFail("Expected publication termination before its receipt.")
        } catch WorkflowApplicationQueueErrorV4
            .injectedPublicationTermination {
        }
        context.activated.close()
        await context.queue
            .injectProcessTerminationAfterApplicationLeasePersistence()

        let relaunchedQueue = try makeQueue(
            fixture: context.fixture,
            resolver: context.resolver,
            clock: WorkflowApplicationQueueTestClockV4(50_000_000_000),
            workerID: "application-worker-publication-diagnostic"
        )
        let dispatchRecorder = WorkflowApplicationDispatchRecorderV4()
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: relaunchedQueue,
            engine: WorkflowApplicationFailingEngineV4(
                recorder: dispatchRecorder
            )
        )
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let diagnosticRecorder = MirmirDiagnosticRecorder(
            store: diagnosticStore
        )

        _ = try await MirmirDiagnosticScope.$recorder.withValue(
            diagnosticRecorder
        ) {
            try await coordinator.launch()
        }
        let snapshot = try await diagnosticStore.snapshot()
        let failures = snapshot.records.filter {
            $0.event.operation.rawValue
                == "recover_interrupted_publication"
        }
        let failure = try XCTUnwrap(failures.first)
        let fields = Dictionary(uniqueKeysWithValues:
            failure.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        let queueSnapshot = try await coordinator.queueSnapshot()

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(
            failure.event.code.rawValue,
            "publication_recovery_failed"
        )
        XCTAssertEqual(fields["job_id_context"], jobID.rawValue)
        XCTAssertNotNil(failure.event.error)
        XCTAssertEqual(
            queueSnapshot.items.first { $0.jobID == jobID }?.lifecycle,
            .contained
        )
    }

    func testCoordinatorLaunchTreatsPublicationRecoveryCancellationAsCancellation()
        async throws {
        for (index, mode) in WorkflowApplicationRecoveryCancellationModeV4
            .allCases.enumerated() {
            let context = try await makeTerminalPublicationContext()
            let jobID = context.activated.specification.jobID
            let intent = try await context.queue.prepareApplicationPublication(
                activated: context.activated,
                checkpoint: context.checkpoint
            )
            let stagingURL = try await context.queue
                .applicationPublicationStagingURL(
                    intent,
                    activated: context.activated
                )
            try Data("cancelled-recovery-output".utf8).write(to: stagingURL)
            _ = try await context.queue.recordApplicationStagedPublication(
                intent,
                finalized: WorkflowApplicationFinalizedOutputV4(
                    destinationURL: stagingURL,
                    verification: try publicationVerification()
                ),
                activated: context.activated
            )
            await context.queue
                .injectProcessTerminationAfterApplicationPublicationRename()
            do {
                _ = try await context.queue.publishApplicationStagedOutput(
                    intent,
                    activated: context.activated
                )
                XCTFail("Expected publication termination before its receipt.")
            } catch WorkflowApplicationQueueErrorV4
                .injectedPublicationTermination {
            }
            context.activated.close()
            await context.queue
                .injectProcessTerminationAfterApplicationLeasePersistence()

            let relaunchedQueue = try makeQueue(
                fixture: context.fixture,
                resolver: context.resolver,
                clock: WorkflowApplicationQueueTestClockV4(50_000_000_000),
                workerID: "application-worker-publication-cancel-\(index)"
            )
            let coordinator = WorkflowApplicationCoordinatorV4(
                queue: relaunchedQueue,
                engine: WorkflowApplicationRecoveryCancellationEngineV4(
                    mode: mode
                )
            )
            let executionRecorder = WorkflowApplicationExecutionRecorderV4()
            await coordinator.installObserver(WorkflowApplicationObserverV4(
                progress: { _, _ in },
                snapshot: { _ in },
                execution: { event in
                    executionRecorder.append(event)
                }
            ))
            let diagnosticStore = MirmirDiagnosticStore(
                inMemoryWith: .production
            )
            let diagnosticRecorder = MirmirDiagnosticRecorder(
                store: diagnosticStore
            )

            _ = try await MirmirDiagnosticScope.$recorder.withValue(
                diagnosticRecorder
            ) {
                try await coordinator.launch()
            }
            let diagnostics = try await diagnosticStore.snapshot()
            let queueSnapshot = try await coordinator.queueSnapshot()

            XCTAssertFalse(diagnostics.records.contains {
                $0.event.code.rawValue == "publication_recovery_failed"
            })
            XCTAssertEqual(executionRecorder.failedCount, 0)
            XCTAssertEqual(
                queueSnapshot.items.first { $0.jobID == jobID }?.lifecycle,
                .cancelled
            )
        }
    }

    func testPublicationRecoveryRetryDiagnosticsAreOncePerOutage()
        async throws {
        let fixture = try makeFixture()
        let dispatchRecorder = WorkflowApplicationDispatchRecorderV4()
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: try makeQueue(fixture: fixture),
            engine: WorkflowApplicationFailingEngineV4(
                recorder: dispatchRecorder
            )
        )
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let recorder = MirmirDiagnosticRecorder(store: diagnosticStore)
        let error = NSError(
            domain: "com.mirmir.tests.publication-retry",
            code: 91
        )

        await coordinator.recordPublicationRecoveryRetryFailureIfNeeded(
            error,
            recorder: recorder
        )
        await coordinator.recordPublicationRecoveryRetryFailureIfNeeded(
            error,
            recorder: recorder
        )
        await coordinator.recordPublicationRecoveryRetryRecoveredIfNeeded(
            recorder: recorder
        )
        await coordinator.recordPublicationRecoveryRetryRecoveredIfNeeded(
            recorder: recorder
        )
        await coordinator.recordPublicationRecoveryRetryFailureIfNeeded(
            error,
            recorder: recorder
        )

        let snapshot = try await diagnosticStore.snapshot()
        let retryRecords = snapshot.records.filter {
            $0.event.operation.rawValue == "retry_publication_recovery"
        }

        XCTAssertEqual(
            retryRecords.map(\.event.code.rawValue),
            [
                "publication_recovery_retry_failed",
                "publication_recovery_retry_recovered",
                "publication_recovery_retry_failed",
            ]
        )
        XCTAssertEqual(
            retryRecords.first?.event.error?.frames.first?.code,
            91
        )
        XCTAssertNil(retryRecords.dropFirst().first?.event.error)
        XCTAssertEqual(
            retryRecords.last?.event.error?.frames.first?.code,
            91
        )
    }

    func testCheckpointBindsCanonicalSourceSnapshotIdentity() async throws {
        let context = try await makeTerminalPublicationContext()
        defer { context.activated.close() }
        XCTAssertEqual(
            context.checkpoint.body.compatibility.sourceSnapshotIdentityID,
            context.activated.sourceSnapshot.identityID
        )
        let loaded = try await context.queue.compatibleApplicationCheckpoint(
            jobID: context.activated.specification.jobID,
            outputContractID:
                context.activated.preparedPlanBinding.outputContractID,
            sourceSnapshotIdentityID:
                context.activated.sourceSnapshot.identityID
        )
        XCTAssertEqual(loaded, context.checkpoint)
        do {
            _ = try await context.queue.compatibleApplicationCheckpoint(
                jobID: context.activated.specification.jobID,
                outputContractID:
                    context.activated.preparedPlanBinding.outputContractID,
                sourceSnapshotIdentityID: WorkflowSourceIdentityID(
                    workflowApplicationDigest(61)
                )
            )
            XCTFail("A different snapshot identity must reject the checkpoint")
        } catch WorkflowDurableCoordinatorErrorV4.checkpointIncompatible(
            let failures
        ) {
            XCTAssertEqual(failures, [.sourceSnapshot])
        }
    }

    func testSourceSnapshotCleanupRequiresSuccessOrCancellation()
        async throws
    {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let tokens = WorkflowApplicationTokenSequenceV4([
            UUID(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")!,
            UUID(uuidString: "bbbbbbbb-1111-2222-3333-444444444444")!,
            UUID(uuidString: "cccccccc-1111-2222-3333-444444444444")!,
        ])
        let queue = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            tokenFactory: { tokens.next() }
        )
        let failed = try await queue.enqueue(
            request: request(fixture: fixture, outputName: "failed.mov"),
            preparedPlanBinding: preparedBinding()
        )
        let cancelled = try await queue.enqueue(
            request: request(fixture: fixture, outputName: "cancelled.mov"),
            preparedPlanBinding: preparedBinding()
        )
        let failedActivation = await queue.activate(
            jobID: failed.specification.jobID
        )
        let cancelledActivation = await queue.activate(
            jobID: cancelled.specification.jobID
        )
        guard case .active(let failedActive) = failedActivation,
              case .active(let cancelledActive) = cancelledActivation else {
            return XCTFail("Expected both source snapshots to activate")
        }
        let failedURL = failedActive.request.inputURL
        let cancelledURL = cancelledActive.request.inputURL
        failedActive.close()
        cancelledActive.close()

        guard case .claimed(let failedDispatch) = try await queue
            .claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4("snapshot-cleanup-failed")
            ) else {
            return XCTFail("Expected failed job dispatch")
        }
        _ = try await queue.transitionApplicationJob(
            failedDispatch,
            expected: .probing,
            target: .failed,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "snapshot-cleanup-failed-transition"
            ),
            stage: "snapshot-cleanup-failed-transition",
            attemptID: nil,
            releaseAfterTransition: true
        )
        guard case .claimed(let cancelledDispatch) = try await queue
            .claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4("snapshot-cleanup-cancelled")
            ) else {
            return XCTFail("Expected cancelled job dispatch")
        }
        _ = try await queue.transitionApplicationJob(
            cancelledDispatch,
            expected: .probing,
            target: .cancelled,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "snapshot-cleanup-cancelled-transition"
            ),
            stage: "snapshot-cleanup-cancelled-transition",
            attemptID: nil,
            releaseAfterTransition: true
        )

        try await queue.cleanupTerminalApplicationSourceSnapshots()
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cancelledURL.path)
        )

        let reenqueued = try await queue.enqueue(
            request: request(
                fixture: fixture,
                outputName: "reenqueued-after-cancel.mov"
            ),
            preparedPlanBinding: preparedBinding()
        )
        let reenqueuedActivation = await queue.activate(
            jobID: reenqueued.specification.jobID
        )
        guard case .active(let reenqueuedActive) = reenqueuedActivation else {
            return XCTFail(
                "A cancelled snapshot must not block re-enqueueing the source"
            )
        }
        defer { reenqueuedActive.close() }
        try reenqueuedActive.revalidateAll()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: reenqueuedActive.request.inputURL.path
            )
        )
    }

    func testOriginalMutationCannotAffectLaterSegmentReaders() async throws {
        let fixture = try makeFixture()
        let admissionBytes = try Data(contentsOf: fixture.inputURL)
        let segmentTemplateURL = fixture.rootURL.appendingPathComponent(
            "source-snapshot-segment-template.mov"
        )
        try await writePublicationSegment(to: segmentTemplateURL)
        let binding = try preparedBinding()
        let engine = WorkflowApplicationSnapshotIsolationEngineV4(
            binding: binding,
            originalURL: fixture.inputURL,
            segmentTemplateURL: segmentTemplateURL
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: try makeQueue(fixture: fixture),
            engine: engine,
            maximumInputFramesPerBoundary: 1
        )

        do {
            _ = try await coordinator.submit(
                request: request(fixture: fixture),
                progress: { _ in },
                snapshot: { _ in }
            )
            XCTFail("Expected the proof engine to stop after its second read")
        } catch WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch {
            // The first segment was durably committed; the second read is the
            // assertion boundary and intentionally terminates the run.
        }

        let observations = await engine.observations()
        XCTAssertEqual(observations.bytes, [admissionBytes, admissionBytes, admissionBytes])
        XCTAssertEqual(Set(observations.urls).count, 1)
        XCTAssertNotEqual(
            observations.urls.first?.standardizedFileURL,
            fixture.inputURL.standardizedFileURL
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.inputURL),
            Data("mutated-original-after-first-segment".utf8)
        )
        XCTAssertEqual(observations.processCallCount, 2)
    }

    func testRecreatedControllerResumesAtAuthenticatedTrueGapBoundary()
        async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let binding = try preparedBinding()
        let initialRequest = request(fixture: fixture)
        let segmentTemplateURL = fixture.rootURL.appendingPathComponent(
            "true-gap-segment-template.mov"
        )
        try await writePublicationSegment(
            to: segmentTemplateURL,
            frameCount: 2
        )
        let recorder = WorkflowApplicationStartTimeRecorderV4()
        let latch = WorkflowApplicationBoundaryLatchV4()
        let firstQueue = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-gap-initial"
        )
        let pausedJobID: WorkflowJobID
        do {
            let firstController = WorkflowApplicationCoordinatorV4(
                queue: firstQueue,
                engine: WorkflowApplicationTrueGapEngineV4(
                    mode: .initial,
                    binding: binding,
                    segmentTemplateURL: segmentTemplateURL,
                    recorder: recorder,
                    latch: latch
                ),
                maximumInputFramesPerBoundary: 2
            )
            let firstRun = Task {
                try await firstController.submit(
                    request: initialRequest,
                    progress: { _ in },
                    snapshot: { _ in }
                )
            }
            guard await latch.waitUntilReached() else {
                await latch.release()
                _ = try? await firstRun.value
                return XCTFail("The first boundary was not dispatched")
            }
            do {
                try await firstController.requestPause()
            } catch {
                await latch.release()
                _ = try? await firstRun.value
                throw error
            }
            await latch.release()
            let outcome = try await firstRun.value
            guard case .paused(let jobID, _) = outcome else {
                return XCTFail("Expected a durable pause after the first boundary")
            }
            pausedJobID = jobID
        }

        let sourceSnapshotIdentityID: WorkflowSourceIdentityID
        do {
            let activation = await firstQueue.activate(jobID: pausedJobID)
            guard case .active(let activated) = activation else {
                return XCTFail("The paused job could not be reactivated")
            }
            defer { activated.close() }
            try activated.revalidateAll()
            sourceSnapshotIdentityID = activated.sourceSnapshot.identityID
        }
        let loadedCheckpoint: WorkflowCheckpointDocumentV4? =
            try await firstQueue.compatibleApplicationCheckpoint(
                jobID: pausedJobID,
                outputContractID: binding.outputContractID,
                sourceSnapshotIdentityID: sourceSnapshotIdentityID
            )
        let persisted = try XCTUnwrap(loadedCheckpoint)
        let expectedStart = try WorkflowMediaTimeV4(
            value: 0,
            timescale: 30
        )
        let expectedEnd = try WorkflowMediaTimeV4(value: 2, timescale: 30)
        let expectedNextStart = try WorkflowMediaTimeV4(
            value: 3,
            timescale: 30
        )
        let persistedTail = try XCTUnwrap(persisted.body.segments.last)
        XCTAssertEqual(persistedTail.startTime, expectedStart)
        XCTAssertEqual(persistedTail.endTimeExclusive, expectedEnd)
        XCTAssertEqual(
            persistedTail.nextStartTime,
            expectedNextStart
        )

        let recreatedQueue = try makeQueue(
            fixture: fixture,
            resolver: resolver,
            workerID: "application-worker-gap-recreated"
        )
        let recreatedController = WorkflowApplicationCoordinatorV4(
            queue: recreatedQueue,
            engine: WorkflowApplicationTrueGapEngineV4(
                mode: .resumed,
                binding: binding,
                segmentTemplateURL: segmentTemplateURL,
                recorder: recorder,
                latch: latch
            ),
            maximumInputFramesPerBoundary: 2
        )
        do {
            _ = try await recreatedController.resume(
                jobID: pausedJobID,
                progress: { _ in },
                snapshot: { _ in }
            )
            XCTFail("The resumed proof engine must stop after dispatch")
        } catch WorkflowApplicationTrueGapEngineErrorV4.stoppedAfterResumedDispatch {
            // The recorded call is the assertion boundary.
        }

        let starts = await recorder.values()
        XCTAssertEqual(starts, [nil, expectedNextStart])
    }

    func testAssemblyTimelineBindsPlanAndExactMediaBoundaryBeforeOpen()
        async throws {
        let context = try await makeTerminalPublicationContext()
        defer { context.activated.close() }
        let jobID = context.activated.specification.jobID
        let planID = context.activated.preparedPlanBinding.planID
        let mediaStart = try XCTUnwrap(
            context.checkpoint.body.segments.first?.startTime
        )
        let outputStart = try WorkflowMediaTimeV4(value: 0, timescale: 1)
        let invalidDescriptors = try [
            WorkflowApplicationAssemblyTimelineDescriptorV4(
                planID: WorkflowPlanID(workflowApplicationDigest(99)),
                mediaTimelineStart: mediaStart,
                outputTimelineStart: outputStart
            ),
            WorkflowApplicationAssemblyTimelineDescriptorV4(
                planID: planID,
                mediaTimelineStart: WorkflowMediaTimeV4(
                    value: 1,
                    timescale: 30
                ),
                outputTimelineStart: outputStart
            )
        ]

        for (index, descriptor) in invalidDescriptors.enumerated() {
            let destination = context.fixture.outputDirectoryURL
                .appendingPathComponent("rejected-assembly-\(index).mov")
            do {
                _ = try await context.queue.assembleApplicationCheckpoint(
                    context.checkpoint,
                    timeline: descriptor,
                    destinationURL: destination,
                    overwriteExistingFile: false
                )
                XCTFail("A mismatched assembly timeline was accepted.")
            } catch let error as WorkflowApplicationQueueErrorV4 {
                XCTAssertEqual(error, .preparedPlanChanged(jobID))
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destination.path)
            )
        }
    }

    func testPublicationCanonicalRecordTamperingFailsClosed() async throws {
        let context = try await makeTerminalPublicationContext()
        defer { context.activated.close() }
        let intent = try await context.queue.prepareApplicationPublication(
            activated: context.activated,
            checkpoint: context.checkpoint
        )
        let stagingURL = try await context.queue
            .applicationPublicationStagingURL(
                intent,
                activated: context.activated
            )
        try Data("canonical-stage".utf8).write(to: stagingURL)
        _ = try await context.queue.recordApplicationStagedPublication(
            intent,
            finalized: WorkflowApplicationFinalizedOutputV4(
                destinationURL: stagingURL,
                verification: try publicationVerification()
            ),
            activated: context.activated
        )
        let stageDocumentURL = context.fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(intent.jobID.rawValue, isDirectory: true)
            .appendingPathComponent(
                "application-request-v4",
                isDirectory: true
            )
            .appendingPathComponent("publication-v4", isDirectory: true)
            .appendingPathComponent("publication-stage-v1.json")
        var tampered = try Data(contentsOf: stageDocumentURL)
        tampered.append(0x0A)
        try tampered.write(to: stageDocumentURL, options: .atomic)

        do {
            _ = try await context.queue.applicationPublicationState(
                jobID: intent.jobID
            )
            XCTFail("Noncanonical publication records must fail closed.")
        } catch let error as WorkflowApplicationQueueErrorV4 {
            XCTAssertEqual(error, .publicationDocumentCorrupt(intent.jobID))
        }
    }

    func testRavenForgeExactClockTerminalCompletenessRejectsMissingFinalSourceSample()
        async throws {
        let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "raven-forge-site057-video-timing",
            withExtension: "mp4"
        ))
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let primaryTrackOrdinal = try XCTUnwrap(
            tracks.firstIndex { $0.mediaType == .video }
        )
        let sourceSampleCount = try await
            WorkflowDeterministicApplicationEngineV4
                .primarySourceSampleCount(
                    sourceURL: sourceURL,
                    primaryTrackOrdinal: primaryTrackOrdinal,
                    cancellation: ProcessingCancellation()
                )

        XCTAssertEqual(sourceSampleCount, 241)
        let exactOneFrameShortEnd = CMTime(
            value: 122_880,
            timescale: 12_288
        )
        let admittedContainerEnd = CMTime(
            value: 123_396,
            timescale: 12_288
        )
        let convertedShortEnd = try
            DeterministicV4MediaProcessingSession.workflowTime(
                exact: exactOneFrameShortEnd,
                admittedBoundary: admittedContainerEnd,
                timescale: 12_288
            )
        XCTAssertEqual(convertedShortEnd.value, 122_880)
        XCTAssertEqual(convertedShortEnd.timescale, 12_288)
        XCTAssertNoThrow(
            try WorkflowDeterministicApplicationEngineV4
                .validateTerminalSourceCompleteness(
                    sourceSampleCount: sourceSampleCount,
                    lastCompletedInputOrdinal: 240
                )
        )
        XCTAssertThrowsError(
            try WorkflowDeterministicApplicationEngineV4
                .validateTerminalSourceCompleteness(
                    sourceSampleCount: sourceSampleCount,
                    lastCompletedInputOrdinal: 239
                )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("decoded 240 of 241")
            )
        }
    }

    func testPrimarySourceSampleInventoryCancelsDuringReaderScan()
        async throws {
        let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "raven-forge-site057-video-timing",
            withExtension: "mp4"
        ))
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let primaryTrackOrdinal = try XCTUnwrap(
            tracks.firstIndex { $0.mediaType == .video }
        )
        let cancellation = ProcessingCancellation()

        do {
            _ = try await WorkflowDeterministicApplicationEngineV4
                .primarySourceSampleCount(
                    sourceURL: sourceURL,
                    primaryTrackOrdinal: primaryTrackOrdinal,
                    cancellation: cancellation,
                    afterReadingSample: {
                        cancellation.cancel()
                    }
                )
            XCTFail("A cancelled source inventory must stop during its scan.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testFreshTerminalSourceCompletenessFailureStopsBeforeFinalization()
        async throws {
        let fixture = try makeFixture()
        let segmentTemplateURL = fixture.rootURL.appendingPathComponent(
            "terminal-completeness-segment-template.mov"
        )
        try await writePublicationSegment(
            to: segmentTemplateURL,
            frameCount: 240
        )
        let engine = WorkflowApplicationTerminalCompletenessRejectingEngineV4(
            binding: try preparedBinding(),
            segmentTemplateURL: segmentTemplateURL
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: try makeQueue(fixture: fixture),
            engine: engine
        )

        do {
            _ = try await coordinator.submit(
                request: request(fixture: fixture),
                progress: { _ in },
                snapshot: { _ in }
            )
            XCTFail("An incomplete terminal source must fail before finalization")
        } catch WorkflowApplicationControllerErrorV4
            .invalidAssembledOutput(let reason) {
            XCTAssertEqual(
                reason,
                "the terminal primary video decoded 240 of 241 source samples"
            )
        }

        let counts = await engine.operationCounts()
        XCTAssertEqual(counts.validations, 1)
        XCTAssertEqual(counts.finalizations, 0)
        let snapshot = try await coordinator.queueSnapshot()
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items.first?.lifecycle, .failed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: request(fixture: fixture).outputURL.path
            )
        )
    }

    func testExternalSourceCompletesProductionDurableWorkflowWhenRequested()
        async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["MIRMIR_REAL_SOURCE_PATH"],
              !sourcePath.isEmpty,
              let evidencePath = environment[
                "MIRMIR_REAL_SOURCE_EVIDENCE_DIR"
              ],
              !evidencePath.isEmpty else {
            throw XCTSkip(
                "Set MIRMIR_REAL_SOURCE_PATH and "
                    + "MIRMIR_REAL_SOURCE_EVIDENCE_DIR to run the "
                    + "production durable-workflow regression."
            )
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return XCTFail("The requested external source does not exist.")
        }
        let evidenceURL = URL(
            fileURLWithPath: evidencePath,
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: evidenceURL,
            withIntermediateDirectories: true
        )
        let runURL = evidenceURL.appendingPathComponent(
            "durable-workflow-run",
            isDirectory: true
        )
        guard !FileManager.default.fileExists(atPath: runURL.path) else {
            return XCTFail(
                "Use an evidence directory without an existing "
                    + "durable-workflow-run subdirectory."
            )
        }
        try FileManager.default.createDirectory(
            at: runURL,
            withIntermediateDirectories: false
        )
        let outputURL = runURL.appendingPathComponent(
            "durable-workflow-output.mov",
            isDirectory: false
        )

        let source = try await VideoProbe().probe(url: sourceURL)
        XCTAssertGreaterThan(source.audioTrackCount, 0)
        XCTAssertGreaterThan(source.videoTrackCount, 0)
        let sourceIdentity = try await AVFoundationSegmentProbeV4()
            .probe(url: sourceURL)
        let sourcePrimary = try XCTUnwrap(
            sourceIdentity.tracks
                .filter { $0.key.mediaType == AVMediaType.video.rawValue }
                .max { $0.sampleCount < $1.sampleCount }
        )
        let sourceDecoded = try await decodedVideoInventory(url: sourceURL)
        XCTAssertEqual(sourceDecoded.sampleCount, sourcePrimary.sampleCount)
        XCTAssertGreaterThanOrEqual(
            CMTimeCompare(
                sourceDecoded.admittedEnd,
                sourceDecoded.exactEnd
            ),
            0
        )
        XCTAssertGreaterThan(sourcePrimary.sampleCount, 60)
        let encodedSize = try XCTUnwrap(source.geometry.encodedSize)
        let sourceWidth = try XCTUnwrap(Int(exactly: encodedSize.width))
        let sourceHeight = try XCTUnwrap(Int(exactly: encodedSize.height))
        let explicitWidth = environment[
            "MIRMIR_REAL_SOURCE_TARGET_WIDTH"
        ]
        let explicitHeight = environment[
            "MIRMIR_REAL_SOURCE_TARGET_HEIGHT"
        ]
        let targetWidth: Int
        let targetHeight: Int
        if explicitWidth != nil || explicitHeight != nil {
            guard let explicitWidth,
                  let explicitHeight,
                  let parsedWidth = Int(explicitWidth),
                  let parsedHeight = Int(explicitHeight),
                  parsedWidth > 0,
                  parsedHeight > 0 else {
                return XCTFail(
                    "Explicit real-source target width and height must both "
                        + "be positive integers."
                )
            }
            targetWidth = parsedWidth
            targetHeight = parsedHeight
        } else {
            let scale = max(
                2,
                Int(environment["MIRMIR_REAL_SOURCE_SCALE"] ?? "2") ?? 2
            )
            let widthProduct = sourceWidth.multipliedReportingOverflow(
                by: scale
            )
            let heightProduct = sourceHeight.multipliedReportingOverflow(
                by: scale
            )
            guard !widthProduct.overflow, !heightProduct.overflow else {
                return XCTFail(
                    "The requested target dimensions overflow Int."
                )
            }
            targetWidth = widthProduct.partialValue
            targetHeight = heightProduct.partialValue
        }
        guard targetWidth >= sourceWidth,
              targetHeight >= sourceHeight,
              targetWidth > sourceWidth || targetHeight > sourceHeight else {
            return XCTFail(
                "The real-source regression requires a genuine upscale."
            )
        }

        let storeURL = runURL.appendingPathComponent(
            "workflow-store",
            isDirectory: true
        )
        let maximumInputFramesPerBoundary = 60
        let queue = try WorkflowApplicationQueueV4(
            trustedRootURL: storeURL,
            workerID: try WorkflowWorkerIDV4(
                "external-source-regression-worker"
            ),
            resolver: WorkflowApplicationBookmarkResolverStubV4()
        )
        let coordinator = WorkflowApplicationCoordinatorV4(
            queue: queue,
            engine: WorkflowDeterministicApplicationEngineV4(
                videoProbe: VideoProbe(),
                backendCatalog: .live(),
                runtimeEnvironment: .current()
            ),
            maximumInputFramesPerBoundary: maximumInputFramesPerBoundary
        )
        let diagnosticStore = MirmirDiagnosticStore(
            inMemoryWith: .production
        )
        let recorder = MirmirDiagnosticRecorder(store: diagnosticStore)
        let outcome = try await MirmirDiagnosticScope.$recorder.withValue(
            recorder
        ) {
            _ = try await coordinator.launch()
            return try await coordinator.submit(
                request: UpscaleRequest(
                    inputURL: sourceURL,
                    outputURL: outputURL,
                    backendID: .mirmirDeterministicMetal,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    outputCodec: .h264,
                    preserveAudio: true,
                    overwriteExistingFile: false
                ),
                progress: { _ in },
                snapshot: { _ in }
            )
        }
        guard case .completed(let completion) = outcome else {
            return XCTFail("The external source run paused unexpectedly.")
        }

        let queueSnapshot = try await coordinator.queueSnapshot()
        let queueItem = try XCTUnwrap(queueSnapshot.items.first)
        XCTAssertEqual(queueSnapshot.items.count, 1)
        XCTAssertEqual(queueItem.lifecycle, .completed)
        let checkpointURL = await queue.applicationCheckpointURL(
            jobID: queueItem.jobID
        )
        let decodedCheckpoint = try WorkflowCanonicalCodec()
            .decodeCanonical(
                WorkflowCheckpointDocumentV4.self,
                from: Data(contentsOf: checkpointURL)
            )
        let compatibleCheckpoint = try await queue
            .compatibleApplicationCheckpoint(
                jobID: queueItem.jobID,
                outputContractID: try XCTUnwrap(
                    decodedCheckpoint.body.segments.last
                ).codecSettingsHash,
                sourceSnapshotIdentityID: decodedCheckpoint.body
                    .compatibility.sourceSnapshotIdentityID
            )
        let checkpoint = try XCTUnwrap(
            compatibleCheckpoint
        )
        XCTAssertEqual(checkpoint, decodedCheckpoint)
        let segments = checkpoint.body.segments
        XCTAssertEqual(
            segments.count,
            Int(
                (sourcePrimary.sampleCount
                    + UInt64(maximumInputFramesPerBoundary) - 1)
                    / UInt64(maximumInputFramesPerBoundary)
            )
        )
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(
            segments.map(\.ordinal),
            segments.indices.map(UInt64.init)
        )
        for index in segments.indices.dropFirst() {
            XCTAssertEqual(
                segments[index - 1].nextStartTime,
                segments[index].startTime
            )
        }
        XCTAssertNil(segments.last?.nextStartTime)
        let terminalSegment = try XCTUnwrap(segments.last)
        XCTAssertEqual(
            terminalSegment.endTimeExclusive,
            try WorkflowMediaTimeV4(
                value: sourceDecoded.exactEnd.value,
                timescale: sourceDecoded.exactEnd.timescale
            )
        )
        let videoProgress = try XCTUnwrap(
            checkpoint.body.trackProgress.first {
                $0.kind == .video && $0.nextOutputSampleIndex > 0
            }
        )
        XCTAssertTrue(videoProgress.isComplete)
        XCTAssertEqual(
            videoProgress.nextInputSampleIndex,
            sourceDecoded.sampleCount
        )
        XCTAssertEqual(
            videoProgress.lastOutputTime,
            terminalSegment.endTimeExclusive
        )

        XCTAssertEqual(
            completion.result.actualBackendID,
            .mirmirDeterministicMetal
        )
        XCTAssertEqual(completion.result.encodedWidth, targetWidth)
        XCTAssertEqual(completion.result.encodedHeight, targetHeight)
        XCTAssertEqual(
            completion.result.processedFrameCount,
            Int(videoProgress.nextOutputSampleIndex)
        )
        XCTAssertEqual(completion.result.audioResult, .preserved)
        let output = try await VideoProbe().probe(url: outputURL)
        XCTAssertEqual(output.audioTrackCount, source.audioTrackCount)
        XCTAssertEqual(output.videoTrackCount, source.videoTrackCount)
        XCTAssertEqual(
            CMTimeCompare(output.duration, source.duration),
            0
        )
        let outputIdentity = try await AVFoundationSegmentProbeV4()
            .probe(url: outputURL)
        let outputPrimary = try XCTUnwrap(
            outputIdentity.tracks
                .filter { $0.key.mediaType == AVMediaType.video.rawValue }
                .max { $0.sampleCount < $1.sampleCount }
        )
        XCTAssertEqual(outputPrimary.sampleCount, sourcePrimary.sampleCount)
        let outputDecoded = try await decodedVideoInventory(url: outputURL)
        XCTAssertEqual(outputDecoded.sampleCount, sourceDecoded.sampleCount)
        XCTAssertEqual(
            CMTimeCompare(outputDecoded.exactEnd, sourceDecoded.exactEnd),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(
                outputDecoded.admittedEnd,
                sourceDecoded.admittedEnd
            ),
            0
        )
        XCTAssertEqual(
            output.geometry.encodedSize,
            CGSize(width: targetWidth, height: targetHeight)
        )
    }
}

private extension WorkflowApplicationQueueV4Tests {
    struct DecodedVideoInventory {
        let sampleCount: UInt64
        let exactEnd: CMTime
        let admittedEnd: CMTime
    }

    struct CacheControlFixture {
        let fixture: Fixture
        let store: WorkflowCacheLocationStoreV4
    }

    struct Fixture {
        let rootURL: URL
        let storeURL: URL
        let inputURL: URL
        let outputDirectoryURL: URL
    }

    struct PublicationContext {
        let fixture: Fixture
        let resolver: WorkflowApplicationBookmarkResolverStubV4
        let queue: WorkflowApplicationQueueV4
        let activated: WorkflowActivatedUpscaleRequestV4
        let checkpoint: WorkflowCheckpointDocumentV4
        let outputURL: URL
    }

    func decodedVideoInventory(
        url: URL
    ) async throws -> DecodedVideoInventory {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let nominalDuration = try await track.load(.minFrameDuration)
        let admittedRange = try await track.load(.timeRange)
        XCTAssertTrue(nominalDuration.isNumeric)
        XCTAssertGreaterThan(nominalDuration.value, 0)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
        )
        guard reader.canAdd(output) else {
            XCTFail("The decoded-video inventory reader rejected its track.")
            throw NSError(
                domain: "MirmirTests.DecodedVideoInventory",
                code: 1
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "MirmirTests.DecodedVideoInventory",
                code: 2
            )
        }

        var sampleCount: UInt64 = 0
        var lastPresentationTime = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 0 { continue }
            XCTAssertEqual(count, 1)
            sampleCount += UInt64(count)
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            XCTAssertTrue(presentation.isNumeric)
            if !lastPresentationTime.isNumeric
                || CMTimeCompare(presentation, lastPresentationTime) > 0 {
                lastPresentationTime = presentation
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertNil(reader.error)
        XCTAssertGreaterThan(sampleCount, 0)
        XCTAssertTrue(lastPresentationTime.isNumeric)
        let exactEnd = CMTimeAdd(
            lastPresentationTime,
            nominalDuration
        )
        XCTAssertTrue(exactEnd.isNumeric)
        return DecodedVideoInventory(
            sampleCount: sampleCount,
            exactEnd: exactEnd,
            admittedEnd: CMTimeRangeGetEnd(admittedRange)
        )
    }

    func makeCacheControlFixture() throws -> CacheControlFixture {
        let base = try makeFixture()
        let applicationIdentifier = "com.mirmir.cache-control-tests"
        let workflowRoot = base.storeURL
            .appendingPathComponent(applicationIdentifier, isDirectory: true)
            .appendingPathComponent("WorkflowV4", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workflowRoot,
            withIntermediateDirectories: true
        )
        let suiteName = "MirmirCacheControlTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = try WorkflowCacheLocationStoreV4(
            applicationIdentifier: applicationIdentifier,
            defaults: defaults,
            bookmarkResolver: WorkflowCacheBookmarkResolverStubV4(),
            defaultApplicationSupportProvider: { base.storeURL }
        )
        return CacheControlFixture(
            fixture: Fixture(
                rootURL: base.rootURL,
                storeURL: workflowRoot,
                inputURL: base.inputURL,
                outputDirectoryURL: base.outputDirectoryURL
            ),
            store: store
        )
    }

    func cacheJobDirectory(
        _ fixture: Fixture,
        _ jobID: WorkflowJobID
    ) -> URL {
        fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(jobID.rawValue, isDirectory: true)
    }

    func seedCacheJob(
        queue: WorkflowApplicationQueueV4,
        fixture: Fixture,
        name: String,
        lifecycle: WorkflowJobLifecycle
    ) async throws -> WorkflowJobID {
        let receipt = try await queue.enqueue(
            request: request(fixture: fixture, outputName: name),
            preparedPlanBinding: preparedBinding()
        )
        let jobID = receipt.specification.jobID
        guard case let .claimed(dispatch) = try await queue
            .claimNextApplicationJob(
                cycleID: WorkflowDispatchCycleIDV4("cache-control-\(name)")
            ) else {
            throw WorkflowApplicationQueueErrorV4.jobNotFound(jobID)
        }
        let commandKey = try WorkflowRecoveryCommandKeyV4(
            "cache-control-\(name)"
        )
        let attemptID = try WorkflowAttemptID("attempt-cache-control-\(name)")
        func advance(
            _ from: WorkflowJobLifecycle,
            _ to: WorkflowJobLifecycle,
            attempt: WorkflowAttemptID? = nil
        ) async throws {
            _ = try await queue.transitionApplicationJob(
                dispatch,
                expected: from,
                target: to,
                commandKey: commandKey,
                stage: "fixture-\(from.rawValue)-\(to.rawValue)",
                attemptID: attempt,
                releaseAfterTransition: to.canDeleteCachedData
            )
        }
        switch lifecycle {
        case .completed:
            try await advance(.probing, .planned)
            try await advance(.planned, .running, attempt: attemptID)
            try await advance(.running, .verifying, attempt: attemptID)
            try await advance(.verifying, .committing)
            try await advance(.committing, .completed)
        case .paused:
            try await advance(.probing, .planned)
            try await advance(.planned, .running, attempt: attemptID)
            try await advance(.running, .pausing, attempt: attemptID)
            try await advance(.pausing, .paused, attempt: attemptID)
        case .contained:
            try await advance(.probing, .contained)
        case .failed:
            try await advance(.probing, .failed)
        case .cancelled:
            try await advance(.probing, .cancelled)
        default:
            throw WorkflowApplicationQueueErrorV4.jobDeletionNotAllowed(
                jobID: jobID,
                lifecycle: lifecycle
            )
        }
        let cachedFile = cacheJobDirectory(fixture, jobID)
            .appendingPathComponent("fixture-cache-file")
        try Data("cached".utf8).write(to: cachedFile)
        return jobID
    }

    func makeFixture(
        inputFileName: String = "original-selected-source.mov"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-workflow-application-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let selected = root.appendingPathComponent("Selected", isDirectory: true)
        let output = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: selected,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        let input = selected.appendingPathComponent(inputFileName)
        try Data("source-media".utf8).write(to: input)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(
            rootURL: root,
            storeURL: store,
            inputURL: input,
            outputDirectoryURL: output
        )
    }

    func makeQueue(
        fixture: Fixture,
        resolver: WorkflowApplicationBookmarkResolverStubV4 =
            WorkflowApplicationBookmarkResolverStubV4(),
        clock: WorkflowApplicationQueueTestClockV4 =
            WorkflowApplicationQueueTestClockV4(9_000_000_000),
        workerID: String = "application-worker-test",
        tokenFactory: @escaping @Sendable () -> UUID = {
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        }
    ) throws -> WorkflowApplicationQueueV4 {
        try WorkflowApplicationQueueV4(
            trustedRootURL: fixture.storeURL,
            workerID: try WorkflowWorkerIDV4(workerID),
            resolver: resolver,
            clock: clock,
            tokenFactory: tokenFactory
        )
    }

    func request(
        fixture: Fixture,
        outputName: String = "upscaled.mov"
    ) -> UpscaleRequest {
        UpscaleRequest(
            inputURL: fixture.inputURL,
            outputURL: fixture.outputDirectoryURL
                .appendingPathComponent(outputName),
            backendID: .mirmirDeterministicCPU,
            targetWidth: 1_920,
            targetHeight: 1_080,
            outputCodec: .hevc,
            preserveAudio: true,
            overwriteExistingFile: true
        )
    }

    func preparedBinding() throws -> WorkflowVerifiedPreparedPlanBindingV4 {
        try WorkflowVerifiedPreparedPlanBindingV4(
            sourceIdentityID: WorkflowSourceIdentityID(
                workflowApplicationDigest(1)
            ),
            outputContractID: WorkflowOutputContractID(
                workflowApplicationDigest(2)
            ),
            runtimeManifestID: WorkflowRuntimeManifestID(
                workflowApplicationDigest(3)
            ),
            planID: WorkflowPlanID(workflowApplicationDigest(4)),
            workflowBackendID: WorkflowBackendID("ash-cpu-v4"),
            backendRevisionID: WorkflowBackendRevisionID("ash-p06-v4"),
            mediaContractID: WorkflowMediaContractID(
                workflowApplicationDigest(5)
            ),
            resolvedBackendID: .mirmirDeterministicCPU
        )
    }

    func makeTerminalPublicationContext() async throws -> PublicationContext {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let queue = try makeQueue(fixture: fixture, resolver: resolver)
        let requested = request(fixture: fixture)
        let binding = try preparedBinding()
        let enqueued = try await queue.enqueue(
            request: requested,
            preparedPlanBinding: binding
        )
        let result = try await queue.claimNextApplicationJob(
            cycleID: WorkflowDispatchCycleIDV4("publication-test-cycle")
        )
        guard case .claimed(let dispatch) = result else {
            throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
        }
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .probing,
            target: .planned,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "publication-test-planned"
            ),
            stage: "publication-test-planned",
            attemptID: nil
        )
        let attemptID = try WorkflowAttemptID("publication-test-attempt")
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .planned,
            target: .running,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "publication-test-running"
            ),
            stage: "publication-test-running",
            attemptID: attemptID
        )

        let segmentURL = fixture.rootURL.appendingPathComponent(
            "publication-terminal-segment.mov"
        )
        try await writePublicationSegment(to: segmentURL)
        let start = try WorkflowMediaTimeV4(value: 0, timescale: 30)
        let end = try WorkflowMediaTimeV4(value: 1, timescale: 30)
        let checkpoint = try await queue.commitApplicationCheckpointBoundary(
            dispatch: dispatch,
            specification: enqueued.specification,
            segment: DeterministicV4MediaSegmentResultV4(
                segmentURL: segmentURL,
                startTime: start,
                endTimeExclusive: end,
                inputSampleCount: 1,
                outputSampleCount: 1,
                lastCompletedInputOrdinal: 0,
                terminal: true,
                processingDurationSeconds: 0.01
            ),
            outputContractID: binding.outputContractID,
            previousCheckpoint: nil,
            trackProgress: [
                try WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: 1,
                    nextOutputSampleIndex: 1,
                    lastInputTime: start,
                    lastOutputTime: start,
                    isComplete: true
                )
            ],
            temporalCheckpoint: Data("terminal-temporal-state".utf8)
        ).checkpoint
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .running,
            target: .verifying,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "publication-test-verifying"
            ),
            stage: "publication-test-verifying",
            attemptID: attemptID
        )
        _ = try await queue.transitionApplicationJob(
            dispatch,
            expected: .verifying,
            target: .committing,
            commandKey: WorkflowRecoveryCommandKeyV4(
                "publication-test-committing"
            ),
            stage: "publication-test-committing",
            attemptID: nil
        )
        let activation = await queue.activate(
            jobID: enqueued.specification.jobID
        )
        guard case .active(let activated) = activation else {
            throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
        }
        return PublicationContext(
            fixture: fixture,
            resolver: resolver,
            queue: queue,
            activated: activated,
            checkpoint: checkpoint,
            outputURL: requested.outputURL
        )
    }

    func publicationVerification()
        throws -> WorkflowApplicationMigrationVerificationV4
    {
        let metadata = try ASHSHA256V4(workflowApplicationDigest(31))
        let chapters = try ASHSHA256V4(workflowApplicationDigest(32))
        return try WorkflowApplicationMigrationVerificationV4(
            sourceGraphSHA256: ASHSHA256V4(workflowApplicationDigest(33)),
            trackPlanSHA256: ASHSHA256V4(workflowApplicationDigest(34)),
            blueprintSHA256: ASHSHA256V4(workflowApplicationDigest(35)),
            sourceAssetMetadataSHA256: metadata,
            outputAssetMetadataSHA256: metadata,
            sourceChapterMetadataSHA256: chapters,
            outputChapterMetadataSHA256: chapters,
            outputGraphSHA256: ASHSHA256V4(workflowApplicationDigest(36)),
            semanticReportSHA256: ASHSHA256V4(
                workflowApplicationDigest(37)
            ),
            trackResults: [
                AVFoundationTrackMigrationTrackResultV4(
                    trackID: try MediaTrackStableIDV4("video-primary"),
                    action: .process,
                    migratedSampleCount: 1,
                    sourceSampleStreamSHA256: nil,
                    outputSampleStreamSHA256: nil
                )
            ]
        )
    }

    func writePublicationSegment(
        to url: URL,
        frameCount: Int = 1
    ) async throws {
        guard frameCount > 0 else {
            throw AVFoundationSegmentV4Error.exportUnavailable
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: 1,
                    AVVideoAverageBitRateKey: 100_000,
                ],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16,
            ]
        )
        guard writer.canAdd(input) else {
            throw AVFoundationSegmentV4Error.exportUnavailable
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: writer.error)
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw AVFoundationSegmentV4Error.exportUnavailable
        }
        for frameIndex in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &buffer
            ) == kCVReturnSuccess, let buffer else {
                throw AVFoundationSegmentV4Error.exportUnavailable
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(
                    base,
                    0x5a,
                    CVPixelBufferGetBytesPerRow(buffer)
                        * CVPixelBufferGetHeight(buffer)
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(
                    value: Int64(frameIndex),
                    timescale: 30
                )
            ) else {
                throw AVFoundationSegmentV4Error.exportFailed(
                    String(describing: writer.error)
                )
            }
        }
        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(value: Int64(frameCount), timescale: 30)
        )
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: writer.error)
            )
        }
    }
}

private final class WorkflowApplicationTokenSequenceV4: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}

private enum WorkflowApplicationFailingEngineErrorV4: Error {
    case injectedAfterDispatch
}

private enum WorkflowApplicationRecoveryCancellationModeV4:
    CaseIterable,
    Sendable
{
    case cancellationError
    case mirmirCancelled
}

private enum WorkflowApplicationTrueGapEngineErrorV4: Error {
    case unexpectedInvocation
    case stoppedAfterResumedDispatch
}

private actor WorkflowApplicationTerminalCompletenessRejectingEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    struct OperationCounts: Sendable {
        let validations: Int
        let finalizations: Int
    }

    let binding: WorkflowVerifiedPreparedPlanBindingV4
    let segmentTemplateURL: URL
    private var validationCount = 0
    private var finalizationCount = 0

    init(
        binding: WorkflowVerifiedPreparedPlanBindingV4,
        segmentTemplateURL: URL
    ) {
        self.binding = binding
        self.segmentTemplateURL = segmentTemplateURL
    }

    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        WorkflowApplicationPreparedSubmissionV4(
            request: request,
            binding: binding
        )
    }

    func revalidateAndPrepare(
        jobID _: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation _: ProcessingCancellation
    ) async throws -> VideoInfo {
        guard expectedBinding == binding else {
            throw WorkflowApplicationTrueGapEngineErrorV4
                .unexpectedInvocation
        }
        return workflowApplicationVideoInfo(url: request.inputURL)
    }

    func processPrepared(
        jobID _: WorkflowJobID,
        request: UpscaleRequest,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames _: Int,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        guard startingInputFrameIndex == 0,
              startTime == nil,
              previousCheckpoint == nil else {
            throw WorkflowApplicationTrueGapEngineErrorV4
                .unexpectedInvocation
        }
        try FileManager.default.copyItem(
            at: segmentTemplateURL,
            to: request.outputURL
        )
        let start = try WorkflowMediaTimeV4(value: 0, timescale: 30)
        let last = try WorkflowMediaTimeV4(value: 239, timescale: 30)
        let end = try WorkflowMediaTimeV4(value: 240, timescale: 30)
        return WorkflowApplicationProcessedSegmentV4(
            source: workflowApplicationVideoInfo(url: request.inputURL),
            segment: DeterministicV4MediaSegmentResultV4(
                segmentURL: request.outputURL,
                startTime: start,
                endTimeExclusive: end,
                inputSampleCount: 240,
                outputSampleCount: 240,
                lastCompletedInputOrdinal: 239,
                terminal: true,
                processingDurationSeconds: 0.01
            ),
            temporalCheckpoint: Data("incomplete-terminal-state".utf8),
            trackProgress: [
                try WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: 240,
                    nextOutputSampleIndex: 240,
                    lastInputTime: last,
                    lastOutputTime: last,
                    isComplete: true
                )
            ]
        )
    }

    func restorePrepared(
        jobID _: WorkflowJobID,
        temporalCheckpoint _: Data,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationTrueGapEngineErrorV4.unexpectedInvocation
    }

    func validateTerminalSourceCompleteness(
        jobID _: WorkflowJobID,
        lastCompletedInputOrdinal: Int64
    ) async throws {
        validationCount += 1
        guard lastCompletedInputOrdinal == 239 else {
            throw WorkflowApplicationTrueGapEngineErrorV4
                .unexpectedInvocation
        }
        throw WorkflowApplicationControllerErrorV4.invalidAssembledOutput(
            "the terminal primary video decoded 240 of 241 source samples"
        )
    }

    func preparedAssemblyTimeline(
        jobID _: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        throw WorkflowApplicationTrueGapEngineErrorV4.unexpectedInvocation
    }

    func finalizePreparedOutput(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        assembledVideoURL _: URL,
        publicationURL _: URL,
        migrationTemporaryURL _: URL,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        finalizationCount += 1
        throw WorkflowApplicationTrueGapEngineErrorV4.unexpectedInvocation
    }

    func inspectCompletion(
        request _: UpscaleRequest,
        checkpoint _: WorkflowCheckpointDocumentV4,
        segmentResult _: UpscaleResult?,
        processingDurationSeconds _: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        throw WorkflowApplicationTrueGapEngineErrorV4.unexpectedInvocation
    }

    func abandonPrepared(jobID _: WorkflowJobID) async {}

    func operationCounts() -> OperationCounts {
        OperationCounts(
            validations: validationCount,
            finalizations: finalizationCount
        )
    }
}

private actor WorkflowApplicationStartTimeRecorderV4 {
    private var startTimes: [WorkflowMediaTimeV4?] = []

    func append(_ startTime: WorkflowMediaTimeV4?) {
        startTimes.append(startTime)
    }

    func values() -> [WorkflowMediaTimeV4?] {
        startTimes
    }
}

private actor WorkflowApplicationBoundaryLatchV4 {
    private var reached = false
    private var released = false

    func reachAndWait() async {
        reached = true
        while !released, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func waitUntilReached() async -> Bool {
        for _ in 0..<1_500 {
            if reached { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return reached
    }

    func release() {
        released = true
    }
}

private actor WorkflowApplicationTrueGapEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    enum Mode: Equatable, Sendable {
        case initial
        case resumed
    }

    let mode: Mode
    let binding: WorkflowVerifiedPreparedPlanBindingV4
    let segmentTemplateURL: URL
    let recorder: WorkflowApplicationStartTimeRecorderV4
    let latch: WorkflowApplicationBoundaryLatchV4

    init(
        mode: Mode,
        binding: WorkflowVerifiedPreparedPlanBindingV4,
        segmentTemplateURL: URL,
        recorder: WorkflowApplicationStartTimeRecorderV4,
        latch: WorkflowApplicationBoundaryLatchV4
    ) {
        self.mode = mode
        self.binding = binding
        self.segmentTemplateURL = segmentTemplateURL
        self.recorder = recorder
        self.latch = latch
    }

    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        guard mode == .initial else {
            throw WorkflowApplicationTrueGapEngineErrorV4
                .unexpectedInvocation
        }
        return WorkflowApplicationPreparedSubmissionV4(
            request: request,
            binding: binding
        )
    }

    func revalidateAndPrepare(
        jobID _: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation _: ProcessingCancellation
    ) async throws -> VideoInfo {
        guard expectedBinding == binding else {
            throw WorkflowApplicationTrueGapEngineErrorV4
                .unexpectedInvocation
        }
        return workflowApplicationVideoInfo(url: request.inputURL)
    }

    func processPrepared(
        jobID _: WorkflowJobID,
        request: UpscaleRequest,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames _: Int,
        previousCheckpoint: WorkflowCheckpointDocumentV4?,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        await recorder.append(startTime)
        switch mode {
        case .initial:
            guard startingInputFrameIndex == 0,
                  startTime == nil,
                  previousCheckpoint == nil else {
                throw WorkflowApplicationTrueGapEngineErrorV4
                    .unexpectedInvocation
            }
            await latch.reachAndWait()
            try FileManager.default.copyItem(
                at: segmentTemplateURL,
                to: request.outputURL
            )
            let start = try WorkflowMediaTimeV4(value: 0, timescale: 30)
            let last = try WorkflowMediaTimeV4(value: 1, timescale: 30)
            let end = try WorkflowMediaTimeV4(value: 2, timescale: 30)
            let next = try WorkflowMediaTimeV4(value: 3, timescale: 30)
            return WorkflowApplicationProcessedSegmentV4(
                source: workflowApplicationVideoInfo(url: request.inputURL),
                segment: DeterministicV4MediaSegmentResultV4(
                    segmentURL: request.outputURL,
                    startTime: start,
                    endTimeExclusive: end,
                    inputSampleCount: 2,
                    outputSampleCount: 2,
                    lastCompletedInputOrdinal: 1,
                    terminal: false,
                    nextStartTime: next,
                    processingDurationSeconds: 0.01
                ),
                temporalCheckpoint: Data("true-gap-temporal-state".utf8),
                trackProgress: [
                    try WorkflowTrackProgressV4(
                        trackID: "video-primary",
                        kind: .video,
                        nextInputSampleIndex: 2,
                        nextOutputSampleIndex: 2,
                        lastInputTime: last,
                        lastOutputTime: last,
                        isComplete: false
                    )
                ]
            )
        case .resumed:
            guard startingInputFrameIndex == 2,
                  previousCheckpoint != nil else {
                throw WorkflowApplicationTrueGapEngineErrorV4
                    .unexpectedInvocation
            }
            throw WorkflowApplicationTrueGapEngineErrorV4
                .stoppedAfterResumedDispatch
        }
    }

    func restorePrepared(
        jobID _: WorkflowJobID,
        temporalCheckpoint: Data,
        lastCompletedInputOrdinal: Int64
    ) async throws {
        guard mode == .resumed,
              temporalCheckpoint == Data("true-gap-temporal-state".utf8),
              lastCompletedInputOrdinal == 1 else {
            throw WorkflowApplicationTrueGapEngineErrorV4
                .unexpectedInvocation
        }
    }

    func validateTerminalSourceCompleteness(
        jobID _: WorkflowJobID,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationTrueGapEngineErrorV4.unexpectedInvocation
    }

    func preparedAssemblyTimeline(
        jobID _: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        WorkflowApplicationAssemblyTimelineDescriptorV4(
            planID: binding.planID,
            mediaTimelineStart: try WorkflowMediaTimeV4(
                value: 0,
                timescale: 30
            ),
            outputTimelineStart: try WorkflowMediaTimeV4(
                value: 2,
                timescale: 30
            )
        )
    }

    func finalizePreparedOutput(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        assembledVideoURL _: URL,
        publicationURL _: URL,
        migrationTemporaryURL _: URL,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        throw WorkflowApplicationTrueGapEngineErrorV4.unexpectedInvocation
    }

    func inspectCompletion(
        request _: UpscaleRequest,
        checkpoint _: WorkflowCheckpointDocumentV4,
        segmentResult _: UpscaleResult?,
        processingDurationSeconds _: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        throw WorkflowApplicationTrueGapEngineErrorV4.unexpectedInvocation
    }

    func abandonPrepared(jobID _: WorkflowJobID) async {}
}

private actor WorkflowApplicationSnapshotIsolationEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    struct Observations: Sendable {
        let urls: [URL]
        let bytes: [Data]
        let processCallCount: Int
    }

    let binding: WorkflowVerifiedPreparedPlanBindingV4
    let originalURL: URL
    let segmentTemplateURL: URL
    private var observedURLs: [URL] = []
    private var observedBytes: [Data] = []
    private var processCalls = 0

    init(
        binding: WorkflowVerifiedPreparedPlanBindingV4,
        originalURL: URL,
        segmentTemplateURL: URL
    ) {
        self.binding = binding
        self.originalURL = originalURL
        self.segmentTemplateURL = segmentTemplateURL
    }

    func prepareSubmission(
        request: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        WorkflowApplicationPreparedSubmissionV4(
            request: request,
            binding: binding
        )
    }

    func revalidateAndPrepare(
        jobID _: WorkflowJobID,
        request: UpscaleRequest,
        expectedBinding: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation _: ProcessingCancellation
    ) async throws -> VideoInfo {
        guard expectedBinding == binding else {
            throw WorkflowApplicationFailingEngineErrorV4
                .injectedAfterDispatch
        }
        try observe(request.inputURL)
        return workflowApplicationVideoInfo(url: request.inputURL)
    }

    func processPrepared(
        jobID _: WorkflowJobID,
        request: UpscaleRequest,
        startingInputFrameIndex _: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames _: Int,
        previousCheckpoint _: WorkflowCheckpointDocumentV4?,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        processCalls += 1
        try observe(request.inputURL)
        guard processCalls == 1 else {
            throw WorkflowApplicationFailingEngineErrorV4
                .injectedAfterDispatch
        }
        try FileManager.default.removeItem(at: originalURL)
        try Data("mutated-original-after-first-segment".utf8).write(
            to: originalURL
        )
        try FileManager.default.copyItem(
            at: segmentTemplateURL,
            to: request.outputURL
        )
        let start = try startTime ?? WorkflowMediaTimeV4(
            value: 0,
            timescale: 30
        )
        let end = try WorkflowMediaTimeV4(
            value: start.value + 1,
            timescale: start.timescale
        )
        return WorkflowApplicationProcessedSegmentV4(
            source: workflowApplicationVideoInfo(url: request.inputURL),
            segment: DeterministicV4MediaSegmentResultV4(
                segmentURL: request.outputURL,
                startTime: start,
                endTimeExclusive: end,
                inputSampleCount: 1,
                outputSampleCount: 1,
                lastCompletedInputOrdinal: 0,
                terminal: false,
                nextStartTime: end,
                processingDurationSeconds: 0.01
            ),
            temporalCheckpoint: Data("snapshot-isolation-state".utf8),
            trackProgress: [
                try WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: 1,
                    nextOutputSampleIndex: 1,
                    lastInputTime: start,
                    lastOutputTime: start,
                    isComplete: false
                )
            ]
        )
    }

    func restorePrepared(
        jobID _: WorkflowJobID,
        temporalCheckpoint _: Data,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func validateTerminalSourceCompleteness(
        jobID _: WorkflowJobID,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func preparedAssemblyTimeline(
        jobID _: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        WorkflowApplicationAssemblyTimelineDescriptorV4(
            planID: binding.planID,
            mediaTimelineStart: try WorkflowMediaTimeV4(
                value: 0,
                timescale: 30
            ),
            outputTimelineStart: try WorkflowMediaTimeV4(
                value: 0,
                timescale: 1
            )
        )
    }

    func finalizePreparedOutput(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        assembledVideoURL _: URL,
        publicationURL _: URL,
        migrationTemporaryURL _: URL,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func inspectCompletion(
        request _: UpscaleRequest,
        checkpoint _: WorkflowCheckpointDocumentV4,
        segmentResult _: UpscaleResult?,
        processingDurationSeconds _: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func abandonPrepared(jobID _: WorkflowJobID) async {}

    func observations() -> Observations {
        Observations(
            urls: observedURLs,
            bytes: observedBytes,
            processCallCount: processCalls
        )
    }

    private func observe(_ url: URL) throws {
        observedURLs.append(url)
        observedBytes.append(try Data(contentsOf: url))
    }
}

private actor WorkflowApplicationDispatchRecorderV4 {
    private var jobIDs: [WorkflowJobID] = []

    func append(_ jobID: WorkflowJobID) {
        jobIDs.append(jobID)
    }

    func values() -> [WorkflowJobID] {
        jobIDs
    }

    func waitForCount(_ count: Int) async -> [WorkflowJobID] {
        for _ in 0..<1_500 {
            if jobIDs.count >= count { return jobIDs }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return jobIDs
    }
}

private actor WorkflowApplicationFailingEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    let recorder: WorkflowApplicationDispatchRecorderV4

    init(recorder: WorkflowApplicationDispatchRecorderV4) {
        self.recorder = recorder
    }

    func prepareSubmission(
        request _: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func revalidateAndPrepare(
        jobID: WorkflowJobID,
        request _: UpscaleRequest,
        expectedBinding _: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation _: ProcessingCancellation
    ) async throws -> VideoInfo {
        await recorder.append(jobID)
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func processPrepared(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        startingInputFrameIndex _: Int,
        startTime _: WorkflowMediaTimeV4?,
        maximumInputFrames _: Int,
        previousCheckpoint _: WorkflowCheckpointDocumentV4?,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func restorePrepared(
        jobID _: WorkflowJobID,
        temporalCheckpoint _: Data,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func validateTerminalSourceCompleteness(
        jobID _: WorkflowJobID,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func preparedAssemblyTimeline(
        jobID _: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func finalizePreparedOutput(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        assembledVideoURL _: URL,
        publicationURL _: URL,
        migrationTemporaryURL _: URL,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func inspectCompletion(
        request _: UpscaleRequest,
        checkpoint _: WorkflowCheckpointDocumentV4,
        segmentResult _: UpscaleResult?,
        processingDurationSeconds _: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func abandonPrepared(jobID _: WorkflowJobID) async {}
}

private actor WorkflowApplicationRecoveryCancellationEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    let mode: WorkflowApplicationRecoveryCancellationModeV4

    init(mode: WorkflowApplicationRecoveryCancellationModeV4) {
        self.mode = mode
    }

    func prepareSubmission(
        request _: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func revalidateAndPrepare(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        expectedBinding _: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation _: ProcessingCancellation
    ) async throws -> VideoInfo {
        switch mode {
        case .cancellationError:
            throw CancellationError()
        case .mirmirCancelled:
            throw MirmirError.cancelled
        }
    }

    func processPrepared(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        startingInputFrameIndex _: Int,
        startTime _: WorkflowMediaTimeV4?,
        maximumInputFrames _: Int,
        previousCheckpoint _: WorkflowCheckpointDocumentV4?,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func restorePrepared(
        jobID _: WorkflowJobID,
        temporalCheckpoint _: Data,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func validateTerminalSourceCompleteness(
        jobID _: WorkflowJobID,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func preparedAssemblyTimeline(
        jobID _: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func finalizePreparedOutput(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        assembledVideoURL _: URL,
        publicationURL _: URL,
        migrationTemporaryURL _: URL,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func inspectCompletion(
        request _: UpscaleRequest,
        checkpoint _: WorkflowCheckpointDocumentV4,
        segmentResult _: UpscaleResult?,
        processingDurationSeconds _: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func abandonPrepared(jobID _: WorkflowJobID) async {}
}

private final class WorkflowApplicationExecutionRecorderV4:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedFailedCount = 0

    var failedCount: Int {
        lock.withLock { recordedFailedCount }
    }

    func append(_ event: WorkflowApplicationExecutionEventV4) {
        guard case .failed = event else { return }
        lock.withLock {
            recordedFailedCount += 1
        }
    }
}

private actor WorkflowApplicationPublicationRecoveryEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    struct OperationCounts: Sendable {
        let revalidations: Int
        let terminalSourceValidations: Int
        let inspections: Int
        let finalizations: Int
    }

    let source: VideoInfo
    private var revalidationCount = 0
    private var terminalSourceValidationCount = 0
    private var inspectionCount = 0
    private var finalizationCount = 0

    init(source: VideoInfo) {
        self.source = source
    }

    func prepareSubmission(
        request _: UpscaleRequest
    ) async throws -> WorkflowApplicationPreparedSubmissionV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func revalidateAndPrepare(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        expectedBinding _: WorkflowVerifiedPreparedPlanBindingV4,
        cancellation _: ProcessingCancellation
    ) async throws -> VideoInfo {
        revalidationCount += 1
        return source
    }

    func processPrepared(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        startingInputFrameIndex _: Int,
        startTime _: WorkflowMediaTimeV4?,
        maximumInputFrames _: Int,
        previousCheckpoint _: WorkflowCheckpointDocumentV4?,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationProcessedSegmentV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func restorePrepared(
        jobID _: WorkflowJobID,
        temporalCheckpoint _: Data,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func validateTerminalSourceCompleteness(
        jobID _: WorkflowJobID,
        lastCompletedInputOrdinal _: Int64
    ) async throws {
        terminalSourceValidationCount += 1
    }

    func preparedAssemblyTimeline(
        jobID _: WorkflowJobID
    ) async throws -> WorkflowApplicationAssemblyTimelineDescriptorV4 {
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func finalizePreparedOutput(
        jobID _: WorkflowJobID,
        request _: UpscaleRequest,
        assembledVideoURL _: URL,
        publicationURL _: URL,
        migrationTemporaryURL _: URL,
        cancellation _: ProcessingCancellation,
        progress _: @escaping @Sendable (UpscaleProgress) -> Void
    ) async throws -> WorkflowApplicationFinalizedOutputV4 {
        finalizationCount += 1
        throw WorkflowApplicationFailingEngineErrorV4.injectedAfterDispatch
    }

    func inspectCompletion(
        request: UpscaleRequest,
        checkpoint _: WorkflowCheckpointDocumentV4,
        segmentResult _: UpscaleResult?,
        processingDurationSeconds: TimeInterval
    ) async throws -> WorkflowApplicationCompletionV4 {
        inspectionCount += 1
        let completion = WorkflowApplicationCompletionV4(
            source: source,
            result: UpscaleResult(
                outputURL: request.outputURL,
                actualBackendID: request.backendID,
                encodedWidth: request.targetWidth,
                encodedHeight: request.targetHeight,
                durationSeconds: source.duration.seconds,
                outputCodec: request.outputCodec,
                audioResult: request.preserveAudio ? .preserved : .omitted,
                processedFrameCount: 1,
                processingDurationSeconds: processingDurationSeconds
            )
        )
        return completion
    }

    func abandonPrepared(jobID _: WorkflowJobID) async {}

    func operationCounts() -> OperationCounts {
        OperationCounts(
            revalidations: revalidationCount,
            terminalSourceValidations: terminalSourceValidationCount,
            inspections: inspectionCount,
            finalizations: finalizationCount
        )
    }
}

private struct WorkflowApplicationQueueTestClockV4: WorkflowWallClockV4 {
    let value: WorkflowWallClockInstantV4

    init(_ nanoseconds: UInt64) {
        value = WorkflowWallClockInstantV4(
            nanosecondsSinceUnixEpoch: nanoseconds
        )
    }

    func now() -> WorkflowWallClockInstantV4 {
        value
    }
}

private enum WorkflowApplicationBookmarkResolverStubErrorV4: Error {
    case malformedBookmark
    case injectedFailure
}

private final class WorkflowApplicationBookmarkResolverStubV4:
    WorkflowSecurityScopedBookmarkResolvingV4,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var state = State()

    var deniedRole: WorkflowScopedResourceRoleV4? {
        get { lock.withLock { state.deniedRole } }
        set { lock.withLock { state.deniedRole = newValue } }
    }

    var failedBookmarkCreationRole: WorkflowScopedResourceRoleV4? {
        get { lock.withLock { state.failedBookmarkCreationRole } }
        set { lock.withLock { state.failedBookmarkCreationRole = newValue } }
    }

    func makeBookmark(
        for url: URL,
        role: WorkflowScopedResourceRoleV4
    ) throws -> Data {
        if lock.withLock({ state.failedBookmarkCreationRole == role }) {
            throw WorkflowApplicationBookmarkResolverStubErrorV4.injectedFailure
        }
        return Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(
        _ data: Data,
        role: WorkflowScopedResourceRoleV4
    ) throws -> WorkflowResolvedScopedResourceV4 {
        guard let path = String(data: data, encoding: .utf8),
              path.hasPrefix("/") else {
            throw WorkflowApplicationBookmarkResolverStubErrorV4
                .malformedBookmark
        }
        let url = URL(fileURLWithPath: path)
        return WorkflowResolvedScopedResourceV4(
            url: url,
            isStale: false,
            startAccessing: { [self] in
                lock.withLock { state.deniedRole != role }
            },
            stopAccessing: {}
        )
    }

    private struct State {
        var deniedRole: WorkflowScopedResourceRoleV4?
        var failedBookmarkCreationRole: WorkflowScopedResourceRoleV4?
    }
}

private func workflowApplicationDigest(_ value: Int) -> String {
    String(format: "%064llx", value)
}

private func workflowApplicationVideoInfo(url: URL) -> VideoInfo {
    let size = CGSize(width: 16, height: 16)
    return VideoInfo(
        url: url,
        duration: CMTime(value: 1, timescale: 30),
        geometry: VideoGeometry(
            encodedSize: size,
            naturalSize: size,
            presentationSize: size,
            displaySize: size,
            preferredTransform: .identity,
            cleanAperture: nil,
            pixelAspectRatio: VideoPixelAspectRatio(
                horizontalSpacing: 1,
                verticalSpacing: 1
            )
        ),
        nominalFrameRate: 30,
        minimumFrameDuration: CMTime(value: 1, timescale: 30),
        estimatedFrameCount: 1,
        estimatedDataRate: nil,
        codecFourCC: kCMVideoCodecType_H264,
        hasAudio: false,
        audioTrackCount: 0,
        videoTrackCount: 1,
        isReadable: true,
        isPlayable: true,
        fileSizeBytes: nil,
        color: .unknown
    )
}

private enum WorkflowApplicationSchemaFixtureErrorV4: Error {
    case invalidRequestDocument
}

private func legacyApplicationRequestDocument(
    from data: Data,
    envelopeSchemaVersion: UInt16
) throws -> Data {
    guard var document = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          var body = document["body"] as? [String: Any] else {
        throw WorkflowApplicationSchemaFixtureErrorV4.invalidRequestDocument
    }
    body["schemaVersion"] = 2
    body.removeValue(forKey: "canonicalSourceFileName")
    let canonicalBody = try JSONSerialization.data(
        withJSONObject: body,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    document["schemaVersion"] = envelopeSchemaVersion
    document["bodyHash"] = WorkflowV4Validation.domainSeparatedSHA256(
        domain: "Mirmir.WorkflowApplication.RequestDocument.v1\u{0}",
        data: canonicalBody
    )
    document["body"] = body
    return try JSONSerialization.data(
        withJSONObject: document,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func canonicalSourceFileName(in data: Data) throws -> String? {
    guard let document = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          let body = document["body"] as? [String: Any] else {
        throw WorkflowApplicationSchemaFixtureErrorV4.invalidRequestDocument
    }
    return body["canonicalSourceFileName"] as? String
}
