import AVFoundation
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class WorkflowApplicationQueueV4Tests: XCTestCase {
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
        XCTAssertEqual(
            activated.request.inputURL.standardizedFileURL,
            original.inputURL.standardizedFileURL
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
        let legacy = try replacingTopLevelSchemaVersion(
            in: current,
            from: WorkflowApplicationRequestEnvelopeSchemaV4.current,
            to: WorkflowApplicationRequestEnvelopeSchemaV4.legacy
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

    func testBookmarkDenialAndPathReplacementAreContained() async throws {
        let fixture = try makeFixture()
        let resolver = WorkflowApplicationBookmarkResolverStubV4()
        let queue = try makeQueue(fixture: fixture, resolver: resolver)
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
        let replaced = await queue.activate(jobID: receipt.specification.jobID)
        guard case .blocked(.bookmarkBlocked(let replacedFailures)) = replaced else {
            return XCTFail("A replaced source inode must be contained")
        }
        XCTAssertEqual(
            replacedFailures,
            [
                WorkflowBookmarkActivationFailureV4(
                    role: .inputFile,
                    reason: .targetReplaced
                )
            ]
        )
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

    func testCoordinatorLaunchReconcilesPostRenameProcessTermination()
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
        XCTAssertEqual(counts.inspections, 1)
        XCTAssertEqual(counts.finalizations, 0)
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
}

private extension WorkflowApplicationQueueV4Tests {
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

    func makeFixture() throws -> Fixture {
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
        let input = selected.appendingPathComponent("source.mov")
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

    func writePublicationSegment(to url: URL) async throws {
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
        while !input.isReadyForMoreMediaData { await Task.yield() }
        guard let pool = adaptor.pixelBufferPool else {
            throw AVFoundationSegmentV4Error.exportUnavailable
        }
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
        guard adaptor.append(buffer, withPresentationTime: .zero) else {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: writer.error)
            )
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
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
        expectedBinding _: WorkflowVerifiedPreparedPlanBindingV4
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

private actor WorkflowApplicationPublicationRecoveryEngineV4:
    WorkflowApplicationDeterministicExecutingV4
{
    struct OperationCounts: Sendable {
        let revalidations: Int
        let inspections: Int
        let finalizations: Int
    }

    let source: VideoInfo
    private var revalidationCount = 0
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
        expectedBinding _: WorkflowVerifiedPreparedPlanBindingV4
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
    case topLevelSchemaNotFound
}

private func replacingTopLevelSchemaVersion(
    in data: Data,
    from oldVersion: UInt16,
    to newVersion: UInt16
) throws -> Data {
    guard var text = String(data: data, encoding: .utf8),
          let range = text.range(
              of: "\"schemaVersion\":\(oldVersion)",
              options: .backwards
          ),
          text[range.upperBound...] == "}" else {
        throw WorkflowApplicationSchemaFixtureErrorV4.topLevelSchemaNotFound
    }
    text.replaceSubrange(
        range,
        with: "\"schemaVersion\":\(newVersion)"
    )
    return Data(text.utf8)
}
