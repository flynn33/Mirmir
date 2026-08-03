import Foundation
import XCTest
#if canImport(Mirmir)
@testable import Mirmir
#endif

final class WorkflowDurableCoordinatorV4Tests: XCTestCase {
    func testCrossDispatcherContentionHasExactlyOneOwner() async throws {
        let fixture = try makeFixture()
        let first = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let second = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 1)
        try await enqueue(specification, into: first, index: 1)

        let firstClaim = try await first.acquire(
            acquisition(index: 1, worker: 1)
        )
        XCTAssertEqual(firstClaim.jobID, specification.jobID)

        do {
            _ = try await second.acquire(acquisition(index: 2, worker: 2))
            XCTFail("A second dispatcher acquired an already owned job.")
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            XCTAssertEqual(error, .noClaimableJob(nil))
        }

        let opened = try await second.open()
        XCTAssertEqual(opened.state.job(id: specification.jobID)?.lifecycle, .probing)
        XCTAssertEqual(opened.state.appliedEvents.count, 2)
    }

    func testExpiredLeaseRecoversAfterSimulatedProcessTermination() async throws {
        let fixture = try makeFixture()
        let first = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let second = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 1)
        try await enqueue(specification, into: first, index: 1)
        let initialClaim = try await first.acquire(acquisition(index: 1, worker: 1))
        _ = try await first.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("crash-event-planned"),
                commandID: WorkflowCommandID("crash-command-planned"),
                from: .probing,
                to: .planned,
                attemptID: nil
            ),
            using: initialClaim
        )
        let crashedAttempt = try WorkflowAttemptID("crash-attempt-1")
        _ = try await first.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("crash-event-running"),
                commandID: WorkflowCommandID("crash-command-running"),
                from: .planned,
                to: .running,
                attemptID: crashedAttempt
            ),
            using: initialClaim
        )
        let oldClaim = try await first.currentClaim(for: initialClaim)
        await first.injectProcessTerminationAfterLeasePersistence()

        let beforeExpiry = try await second.inspectRecovery(
            jobID: specification.jobID
        )
        XCTAssertEqual(
            beforeExpiry,
            .awaitingExpiry(
                leaseID: oldClaim.leaseID,
                expiresAt: oldClaim.expiresAt
            )
        )

        fixture.clock.advance(nanoseconds: 2_000_000_000)
        let afterExpiry = try await second.inspectRecovery(
            jobID: specification.jobID
        )
        XCTAssertEqual(
            afterExpiry,
            .recoverableExpired(leaseID: oldClaim.leaseID)
        )
        let recovered = try await second.acquire(
            try WorkflowLeaseAcquisitionRequestV4(
                jobID: specification.jobID,
                leaseID: WorkflowLeaseIDV4("lease-recovery"),
                workerID: WorkflowWorkerIDV4("worker-recovery"),
                eventID: WorkflowEventID("event-recovery"),
                commandID: WorkflowCommandID("command-recovery"),
                expectedLifecycle: .running,
                targetLifecycle: .recovering,
                attemptID: crashedAttempt,
                duration: WorkflowLeaseIntervalV4(
                    nanoseconds: 1_000_000_000
                )
            )
        )
        XCTAssertEqual(recovered.lifecycle, .recovering)
        let recoveredState = try await second.open()
        XCTAssertEqual(
            recoveredState.state.job(id: specification.jobID)?.lifecycle,
            .recovering
        )
    }

    func testAcquisitionAndTransitionCommandsReplayIdempotently() async throws {
        let fixture = try makeFixture()
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 1)
        try await enqueue(specification, into: coordinator, index: 1)
        let request = try acquisition(index: 1, worker: 1)
        let firstClaim = try await coordinator.acquire(request)
        let replayedClaim = try await coordinator.acquire(request)
        XCTAssertEqual(firstClaim, replayedClaim)

        let planned = try WorkflowLifecycleCommandV4(
            eventID: WorkflowEventID("event-planned"),
            commandID: WorkflowCommandID("command-planned"),
            from: .probing,
            to: .planned,
            attemptID: nil
        )
        let committed = try await coordinator.transition(planned, using: firstClaim)
        let replay = try await coordinator.transition(planned, using: firstClaim)
        XCTAssertEqual(committed.disposition, .committed)
        XCTAssertEqual(replay.disposition, .alreadyApplied)
        XCTAssertEqual(replay.state.appliedEvents.count, 3)

        let heartbeat = try await coordinator.heartbeat(
            WorkflowLeaseHeartbeatV4(
                claim: firstClaim,
                interval: WorkflowLeaseIntervalV4(
                    nanoseconds: 1_000_000_000
                )
            )
        )
        XCTAssertEqual(heartbeat.lifecycle, .planned)
        XCTAssertGreaterThan(heartbeat.leaseGeneration, firstClaim.leaseGeneration)
    }

    func testCheckpointCommitIsIdempotentAndCompatibilityIsExact() async throws {
        let fixture = try makeFixture()
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 1)
        try await enqueue(specification, into: coordinator, index: 1)
        let claim = try await coordinator.acquire(acquisition(index: 1, worker: 1))
        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("event-planned"),
                commandID: WorkflowCommandID("command-planned"),
                from: .probing,
                to: .planned,
                attemptID: nil
            ),
            using: claim
        )
        let attemptID = try WorkflowAttemptID("attempt-1")
        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("event-running"),
                commandID: WorkflowCommandID("command-running"),
                from: .planned,
                to: .running,
                attemptID: attemptID
            ),
            using: claim
        )

        let draft = try checkpointDraft(codec: specification.output.contractID)
        let committed = try await coordinator.commitCheckpoint(draft, using: claim)
        let replay = try await coordinator.commitCheckpoint(draft, using: claim)
        XCTAssertEqual(committed.disposition, .committed)
        XCTAssertEqual(replay.disposition, .alreadyCommitted)
        XCTAssertEqual(committed.document, replay.document)

        let compatible = try await coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        XCTAssertEqual(compatible, committed.document)
        do {
            _ = try await coordinator.loadCompatibleCheckpoint(
                jobID: specification.jobID,
                expectedCodecSettingsHash: WorkflowOutputContractID(testDigest(99))
            )
            XCTFail("A checkpoint with different codec settings was accepted.")
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            XCTAssertEqual(error, .checkpointIncompatible([.codecSettings]))
        }

        let changedBookmark = try WorkflowBookmarkReference(
            bookmarkID: specification.source.bookmark.bookmarkID,
            revision: specification.source.bookmark.revision + 1,
            documentHash: specification.source.bookmark.documentHash
        )
        let changedSpecification = WorkflowJobSpecification(
            jobID: specification.jobID,
            requestID: specification.requestID,
            source: WorkflowSourceSpecification(
                identityID: specification.source.identityID,
                bookmark: changedBookmark
            ),
            output: specification.output,
            runtimeBinding: specification.runtimeBinding
        )
        XCTAssertEqual(
            committed.document.body.compatibility.compatibilityFailures(
                with: changedSpecification
            ),
            [.sourceBookmark]
        )
    }

    func testStartupScavengerUsesRegistryAndInodeOwnership() async throws {
        let fixture = try makeFixture()
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 1)
        try await enqueue(specification, into: coordinator, index: 1)
        let claim = try await coordinator.acquire(acquisition(index: 1, worker: 1))

        let registeredURL = fixture.outputURL.appendingPathComponent(
            ".mirmir-11111111-1111-1111-1111-111111111111.partial.mov"
        )
        try Data("registered".utf8).write(to: registeredURL)
        let registration = try await coordinator.registerPartialArtifact(
            artifactID: WorkflowArtifactIDV4("partial-registered"),
            fileURL: registeredURL,
            in: try WorkflowActivatedOutputScopeV4(
                bookmark: specification.output.directoryBookmark,
                activatedDirectoryURL: fixture.outputURL
            ),
            using: claim
        )
        let registered = try await coordinator.registeredPartialArtifacts(
            jobID: specification.jobID
        )
        XCTAssertEqual(registered, [registration])

        let legacyURL = fixture.outputURL.appendingPathComponent(
            ".mirmir-track-v4-22222222-2222-2222-2222-222222222222.partial.mov"
        )
        try Data("legacy".utf8).write(to: legacyURL)
        let foreignURL = fixture.outputURL.appendingPathComponent(
            "editor.partial.mov"
        )
        try Data("foreign".utf8).write(to: foreignURL)

        let scope = try WorkflowActivatedOutputScopeV4(
            bookmark: specification.output.directoryBookmark,
            activatedDirectoryURL: fixture.outputURL
        )
        let reconciler = WorkflowPartialArtifactReconcilerV4()
        let first = try reconciler.reconcile(
            registrations: [registration],
            activatedScopes: [scope]
        )
        XCTAssertEqual(first.containedFailureCount, 0)
        XCTAssertTrue(first.receipts.contains {
            $0.disposition == .registeredQuarantined
        })
        XCTAssertTrue(first.receipts.contains {
            $0.disposition == .legacyQuarantined
        })
        XCTAssertTrue(first.receipts.contains {
            $0.disposition == .foreignIgnored
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: registeredURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignURL.path))

        let replay = try reconciler.reconcile(
            registrations: [registration],
            activatedScopes: [scope]
        )
        XCTAssertTrue(replay.receipts.contains {
            $0.disposition == .alreadyQuarantined
        })

        let mismatchURL = fixture.outputURL.appendingPathComponent(
            ".mirmir-33333333-3333-3333-3333-333333333333.partial.mov"
        )
        try Data("original".utf8).write(to: mismatchURL)
        let mismatchRegistration = try await coordinator.registerPartialArtifact(
            artifactID: WorkflowArtifactIDV4("partial-mismatch"),
            fileURL: mismatchURL,
            in: scope,
            using: claim
        )
        let heldAside = fixture.outputURL.appendingPathComponent("held-aside.mov")
        try FileManager.default.moveItem(at: mismatchURL, to: heldAside)
        try Data("replacement".utf8).write(to: mismatchURL)

        let mismatch = try reconciler.reconcile(
            registrations: [registration, mismatchRegistration],
            activatedScopes: [scope]
        )
        XCTAssertTrue(mismatch.receipts.contains {
            $0.artifactID == mismatchRegistration.artifactID
                && $0.disposition == .ownershipMismatchContained
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatchURL.path))
    }
}

private final class WorkflowTestClockV4: WorkflowWallClockV4, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) {
        self.value = value
    }

    func now() -> WorkflowWallClockInstantV4 {
        lock.withLock {
            WorkflowWallClockInstantV4(nanosecondsSinceUnixEpoch: value)
        }
    }

    func advance(nanoseconds: UInt64) {
        lock.withLock { value += nanoseconds }
    }
}

private struct WorkflowCoordinatorFixtureV4 {
    let rootURL: URL
    let storeURL: URL
    let outputURL: URL
    let clock: WorkflowTestClockV4
}

private extension WorkflowDurableCoordinatorV4Tests {
    func makeFixture() throws -> WorkflowCoordinatorFixtureV4 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workflow-v4-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = root.appendingPathComponent("store", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return WorkflowCoordinatorFixtureV4(
            rootURL: root,
            storeURL: store,
            outputURL: output,
            clock: WorkflowTestClockV4(1_000_000_000)
        )
    }

    func enqueue(
        _ specification: WorkflowJobSpecification,
        into coordinator: WorkflowDurableCoordinatorV4,
        index: Int
    ) async throws {
        _ = try await coordinator.append(
            WorkflowEventDraft(
                eventID: try WorkflowEventID("enqueue-event-\(index)"),
                commandID: try WorkflowCommandID("enqueue-command-\(index)"),
                scope: .job(specification.jobID),
                jobBinding: specification.binding,
                attemptID: nil,
                event: .jobEnqueued(specification)
            )
        )
    }

    func acquisition(
        index: Int,
        worker: Int
    ) throws -> WorkflowLeaseAcquisitionRequestV4 {
        try WorkflowLeaseAcquisitionRequestV4(
            leaseID: WorkflowLeaseIDV4("lease-\(index)"),
            workerID: WorkflowWorkerIDV4("worker-\(worker)"),
            eventID: WorkflowEventID("claim-event-\(index)"),
            commandID: WorkflowCommandID("claim-command-\(index)"),
            duration: WorkflowLeaseIntervalV4(
                nanoseconds: 1_000_000_000
            )
        )
    }

    func makeSpecification(index: Int) throws -> WorkflowJobSpecification {
        let sourceBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("source-bookmark-\(index)"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(testDigest(index + 1))
        )
        let outputBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("output-bookmark-\(index)"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(testDigest(index + 2))
        )
        let runtime = WorkflowRuntimeBinding(
            id: try WorkflowRuntimeBindingID(testDigest(index + 3)),
            runtimeManifestID: try WorkflowRuntimeManifestID(testDigest(index + 4)),
            planID: try WorkflowPlanID(testDigest(index + 5)),
            backendID: try WorkflowBackendID("backend-v4"),
            backendRevisionID: try WorkflowBackendRevisionID("backend-v4-p06"),
            mediaContractID: try WorkflowMediaContractID(testDigest(index + 6))
        )
        return WorkflowJobSpecification(
            jobID: try WorkflowJobID("job-\(index)"),
            requestID: try WorkflowRequestID(testDigest(index + 7)),
            source: WorkflowSourceSpecification(
                identityID: try WorkflowSourceIdentityID(testDigest(index + 8)),
                bookmark: sourceBookmark
            ),
            output: WorkflowOutputSpecification(
                contractID: try WorkflowOutputContractID(testDigest(index + 9)),
                directoryBookmark: outputBookmark,
                fileName: try WorkflowOutputFileName("output-\(index).mov")
            ),
            runtimeBinding: runtime
        )
    }

    func checkpointDraft(
        codec: WorkflowOutputContractID
    ) throws -> WorkflowCheckpointDraftV4 {
        let segment = try WorkflowSegmentCheckpointV4(
            ordinal: 0,
            artifact: checkpointArtifact(index: 1, kind: .segment),
            startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 600, timescale: 600),
            codecSettingsHash: codec,
            isIndependentlyDecodable: true
        )
        return WorkflowCheckpointDraftV4(
            checkpointID: try WorkflowCheckpointIDV4("checkpoint-1"),
            committedAt: WorkflowWallClockInstantV4(
                nanosecondsSinceUnixEpoch: 1_000_000_000
            ),
            segments: [segment],
            trackProgress: [
                try WorkflowTrackProgressV4(
                    trackID: "video-1",
                    kind: .video,
                    nextInputSampleIndex: 30,
                    nextOutputSampleIndex: 30,
                    lastInputTime: WorkflowMediaTimeV4(value: 580, timescale: 600),
                    lastOutputTime: WorkflowMediaTimeV4(value: 580, timescale: 600),
                    isComplete: false
                ),
                try WorkflowTrackProgressV4(
                    trackID: "audio-1",
                    kind: .audio,
                    nextInputSampleIndex: 48_000,
                    nextOutputSampleIndex: 48_000,
                    lastInputTime: WorkflowMediaTimeV4(value: 47_999, timescale: 48_000),
                    lastOutputTime: WorkflowMediaTimeV4(value: 47_999, timescale: 48_000),
                    isComplete: false
                )
            ],
            temporalHistory: try checkpointArtifact(
                index: 2,
                kind: .temporalHistory
            ),
            measurementHysteresis: try checkpointArtifact(
                index: 3,
                kind: .measurementHysteresis
            ),
            auxiliaryState: [
                try checkpointArtifact(index: 4, kind: .trackState)
            ]
        )
    }

    func checkpointArtifact(
        index: Int,
        kind: WorkflowCheckpointArtifactKindV4
    ) throws -> WorkflowCheckpointArtifactV4 {
        try WorkflowCheckpointArtifactV4(
            artifactID: WorkflowArtifactIDV4("checkpoint-artifact-\(index)"),
            kind: kind,
            relativePath: "artifacts/artifact-\(index).bin",
            byteCount: UInt64(index * 100),
            sha256: WorkflowCheckpointArtifactHashV4(testDigest(index + 20)),
            reopenReceiptSHA256: WorkflowCheckpointArtifactHashV4(
                testDigest(index + 30)
            )
        )
    }
}

private func testDigest(_ value: Int) -> String {
    String(format: "%064llx", value)
}
