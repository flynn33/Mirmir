import Foundation

private enum SelfTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        }
    }
}

private final class SelfTestClock: WorkflowWallClockV4, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) { self.value = value }

    func now() -> WorkflowWallClockInstantV4 {
        lock.withLock {
            WorkflowWallClockInstantV4(nanosecondsSinceUnixEpoch: value)
        }
    }

    func advance(_ nanoseconds: UInt64) {
        lock.withLock { value += nanoseconds }
    }
}

private struct Fixture {
    let root: URL
    let store: URL
    let output: URL
    let clock: SelfTestClock

    static func make(_ name: String) throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workflow-v4-selftest-\(name)-\(UUID().uuidString)",
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
        return Self(
            root: root,
            store: store,
            output: output,
            clock: SelfTestClock(1_000_000_000)
        )
    }
}

@main
private struct WorkflowDurableCoordinatorV4SelfTestMain {
    static func main() async throws {
        var completed: [String] = []
        try await contentionAndIdempotency()
        completed.append("contention_and_idempotency")
        try await crashExpiryRecovery()
        completed.append("crash_expiry_recovery")
        try await pauseResumeCheckpoint()
        completed.append("pause_resume_checkpoint")
        try await orphanPartialOwnership()
        completed.append("orphan_partial_ownership")
        print("workflow-durable-v4 self-test passed: \(completed.joined(separator: ","))")
    }

    private static func contentionAndIdempotency() async throws {
        let fixture = try Fixture.make("contention")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let second = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let specification = try makeSpecification(1)
        try await enqueue(specification, coordinator: first, index: 1)
        let request = try acquisition(1, worker: 1)
        let claim = try await first.acquire(request)
        let replayedClaim = try await first.acquire(request)
        try expect(replayedClaim == claim, "acquisition replay changed claim")

        do {
            _ = try await second.acquire(acquisition(2, worker: 2))
            throw SelfTestFailure.assertion("contending dispatcher acquired the same job")
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            try expect(error == .noClaimableJob(nil), "unexpected contention error: \(error)")
        }

        let planned = try WorkflowLifecycleCommandV4(
            eventID: WorkflowEventID("event-planned"),
            commandID: WorkflowCommandID("command-planned"),
            from: .probing,
            to: .planned,
            attemptID: nil
        )
        let firstTransition = try await first.transition(planned, using: claim)
        let replay = try await first.transition(planned, using: claim)
        try expect(firstTransition.disposition == .committed, "transition did not commit")
        try expect(replay.disposition == .alreadyApplied, "transition replay appended")
        try expect(replay.state.appliedEvents.count == 3, "idempotent replay changed event count")
    }

    private static func crashExpiryRecovery() async throws {
        let fixture = try Fixture.make("crash")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let crashed = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let relaunched = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let specification = try makeSpecification(1)
        try await enqueue(specification, coordinator: crashed, index: 1)
        let initialClaim = try await crashed.acquire(acquisition(1, worker: 1))
        _ = try await crashed.transition(
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
        _ = try await crashed.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("crash-event-running"),
                commandID: WorkflowCommandID("crash-command-running"),
                from: .planned,
                to: .running,
                attemptID: crashedAttempt
            ),
            using: initialClaim
        )
        let oldClaim = try await crashed.currentClaim(for: initialClaim)
        await crashed.injectProcessTerminationAfterLeasePersistence()

        let waiting = try await relaunched.inspectRecovery(jobID: specification.jobID)
        try expect(
            waiting == .awaitingExpiry(
                leaseID: oldClaim.leaseID,
                expiresAt: oldClaim.expiresAt
            ),
            "relaunch stole an unexpired lease"
        )
        fixture.clock.advance(2_000_000_000)
        let expired = try await relaunched.inspectRecovery(
            jobID: specification.jobID
        )
        try expect(
            expired == .recoverableExpired(leaseID: oldClaim.leaseID),
            "expired lease was not classified recoverable"
        )
        let recovered = try await relaunched.acquire(
            WorkflowLeaseAcquisitionRequestV4(
                jobID: specification.jobID,
                leaseID: WorkflowLeaseIDV4("lease-recovered"),
                workerID: WorkflowWorkerIDV4("worker-recovered"),
                eventID: WorkflowEventID("event-recovered"),
                commandID: WorkflowCommandID("command-recovered"),
                expectedLifecycle: .running,
                targetLifecycle: .recovering,
                attemptID: crashedAttempt,
                duration: WorkflowLeaseIntervalV4(
                    nanoseconds: 1_000_000_000
                )
            )
        )
        try expect(recovered.lifecycle == .recovering, "recovery transition did not commit")
    }

    private static func pauseResumeCheckpoint() async throws {
        let fixture = try Fixture.make("checkpoint")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let specification = try makeSpecification(1)
        try await enqueue(specification, coordinator: coordinator, index: 1)
        let initialClaim = try await coordinator.acquire(acquisition(1, worker: 1))
        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("event-planned"),
                commandID: WorkflowCommandID("command-planned"),
                from: .probing,
                to: .planned,
                attemptID: nil
            ),
            using: initialClaim
        )
        let firstAttempt = try WorkflowAttemptID("attempt-1")
        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("event-running"),
                commandID: WorkflowCommandID("command-running"),
                from: .planned,
                to: .running,
                attemptID: firstAttempt
            ),
            using: initialClaim
        )
        let runningClaim = try await coordinator.currentClaim(for: initialClaim)
        let draft = try checkpointDraft(codec: specification.output.contractID)
        let committed = try await coordinator.commitCheckpoint(
            draft,
            using: runningClaim
        )
        let replay = try await coordinator.commitCheckpoint(
            draft,
            using: runningClaim
        )
        try expect(committed.disposition == .committed, "checkpoint did not commit")
        try expect(replay.disposition == .alreadyCommitted, "checkpoint replay was not idempotent")
        try expect(committed.document == replay.document, "checkpoint replay identity changed")

        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("event-pausing"),
                commandID: WorkflowCommandID("command-pausing"),
                from: .running,
                to: .pausing,
                attemptID: firstAttempt
            ),
            using: runningClaim
        )
        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("event-paused"),
                commandID: WorkflowCommandID("command-paused"),
                from: .pausing,
                to: .paused,
                attemptID: firstAttempt
            ),
            using: runningClaim
        )
        let resumed = try await coordinator.acquire(
            WorkflowLeaseAcquisitionRequestV4(
                jobID: specification.jobID,
                leaseID: WorkflowLeaseIDV4("lease-resume"),
                workerID: WorkflowWorkerIDV4("worker-resume"),
                eventID: WorkflowEventID("event-resume"),
                commandID: WorkflowCommandID("command-resume"),
                expectedLifecycle: .paused,
                targetLifecycle: .running,
                attemptID: WorkflowAttemptID("attempt-2"),
                duration: WorkflowLeaseIntervalV4(
                    nanoseconds: 1_000_000_000
                )
            )
        )
        try expect(resumed.lifecycle == .running, "paused job did not resume")
        let restored = try await coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        try expect(
            restored == committed.document,
            "resume did not recover the exact checkpoint head"
        )
        do {
            _ = try await coordinator.loadCompatibleCheckpoint(
                jobID: specification.jobID,
                expectedCodecSettingsHash: WorkflowOutputContractID(digest(99))
            )
            throw SelfTestFailure.assertion("incompatible codec checkpoint was accepted")
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            try expect(
                error == .checkpointIncompatible([.codecSettings]),
                "wrong checkpoint incompatibility: \(error)"
            )
        }
    }

    private static func orphanPartialOwnership() async throws {
        let fixture = try Fixture.make("partial")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store,
            clock: fixture.clock
        )
        let specification = try makeSpecification(1)
        try await enqueue(specification, coordinator: coordinator, index: 1)
        let claim = try await coordinator.acquire(acquisition(1, worker: 1))

        let registeredURL = fixture.output.appendingPathComponent(
            ".mirmir-11111111-1111-1111-1111-111111111111.partial.mov"
        )
        try Data("registered".utf8).write(to: registeredURL)
        let registration = try await coordinator.registerPartialArtifact(
            artifactID: WorkflowArtifactIDV4("registered-partial"),
            fileURL: registeredURL,
            in: try WorkflowActivatedOutputScopeV4(
                bookmark: specification.output.directoryBookmark,
                activatedDirectoryURL: fixture.output
            ),
            using: claim
        )
        let legacyURL = fixture.output.appendingPathComponent(
            ".mirmir-track-v4-22222222-2222-2222-2222-222222222222.partial.mov"
        )
        try Data("legacy".utf8).write(to: legacyURL)
        let foreignURL = fixture.output.appendingPathComponent("editor.partial.mov")
        try Data("foreign".utf8).write(to: foreignURL)

        let scope = try WorkflowActivatedOutputScopeV4(
            bookmark: specification.output.directoryBookmark,
            activatedDirectoryURL: fixture.output
        )
        let reconciler = WorkflowPartialArtifactReconcilerV4()
        let report = try reconciler.reconcile(
            registrations: [registration],
            activatedScopes: [scope]
        )
        try expect(report.containedFailureCount == 0, "valid partials were contained")
        try expect(
            report.receipts.contains { $0.disposition == .registeredQuarantined },
            "registered partial was not quarantined"
        )
        try expect(
            report.receipts.contains { $0.disposition == .legacyQuarantined },
            "legacy recognizable partial was not quarantined"
        )
        try expect(
            report.receipts.contains { $0.disposition == .foreignIgnored },
            "foreign partial was not explicitly ignored"
        )
        try expect(!FileManager.default.fileExists(atPath: registeredURL.path), "registered partial remained")
        try expect(!FileManager.default.fileExists(atPath: legacyURL.path), "legacy partial remained")
        try expect(FileManager.default.fileExists(atPath: foreignURL.path), "foreign partial was changed")

        let replay = try reconciler.reconcile(
            registrations: [registration],
            activatedScopes: [scope]
        )
        try expect(
            replay.receipts.contains { $0.disposition == .alreadyQuarantined },
            "scavenger replay did not recognize prior quarantine"
        )

        let mismatchURL = fixture.output.appendingPathComponent(
            ".mirmir-33333333-3333-3333-3333-333333333333.partial.mov"
        )
        try Data("owned".utf8).write(to: mismatchURL)
        let mismatchRegistration = try await coordinator.registerPartialArtifact(
            artifactID: WorkflowArtifactIDV4("mismatch-partial"),
            fileURL: mismatchURL,
            in: scope,
            using: claim
        )
        try FileManager.default.moveItem(
            at: mismatchURL,
            to: fixture.output.appendingPathComponent("held-original.mov")
        )
        try Data("foreign-replacement".utf8).write(to: mismatchURL)
        let mismatchReport = try reconciler.reconcile(
            registrations: [registration, mismatchRegistration],
            activatedScopes: [scope]
        )
        try expect(
            mismatchReport.receipts.contains {
                $0.artifactID == mismatchRegistration.artifactID
                    && $0.disposition == .ownershipMismatchContained
            },
            "inode replacement was not contained"
        )
        try expect(
            FileManager.default.fileExists(atPath: mismatchURL.path),
            "ownership mismatch was destructively changed"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw SelfTestFailure.assertion(message) }
    }

    private static func enqueue(
        _ specification: WorkflowJobSpecification,
        coordinator: WorkflowDurableCoordinatorV4,
        index: Int
    ) async throws {
        _ = try await coordinator.append(
            WorkflowEventDraft(
                eventID: WorkflowEventID("enqueue-event-\(index)"),
                commandID: WorkflowCommandID("enqueue-command-\(index)"),
                scope: .job(specification.jobID),
                jobBinding: specification.binding,
                attemptID: nil,
                event: .jobEnqueued(specification)
            )
        )
    }

    private static func acquisition(
        _ index: Int,
        worker: Int
    ) throws -> WorkflowLeaseAcquisitionRequestV4 {
        try WorkflowLeaseAcquisitionRequestV4(
            leaseID: WorkflowLeaseIDV4("lease-\(index)"),
            workerID: WorkflowWorkerIDV4("worker-\(worker)"),
            eventID: WorkflowEventID("claim-event-\(index)"),
            commandID: WorkflowCommandID("claim-command-\(index)"),
            duration: WorkflowLeaseIntervalV4(nanoseconds: 1_000_000_000)
        )
    }

    private static func makeSpecification(
        _ index: Int
    ) throws -> WorkflowJobSpecification {
        let sourceBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("source-bookmark-\(index)"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(index + 1))
        )
        let outputBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("output-bookmark-\(index)"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(index + 2))
        )
        let runtime = WorkflowRuntimeBinding(
            id: try WorkflowRuntimeBindingID(digest(index + 3)),
            runtimeManifestID: try WorkflowRuntimeManifestID(digest(index + 4)),
            planID: try WorkflowPlanID(digest(index + 5)),
            backendID: try WorkflowBackendID("backend-v4"),
            backendRevisionID: try WorkflowBackendRevisionID("backend-v4-p06"),
            mediaContractID: try WorkflowMediaContractID(digest(index + 6))
        )
        return WorkflowJobSpecification(
            jobID: try WorkflowJobID("job-\(index)"),
            requestID: try WorkflowRequestID(digest(index + 7)),
            source: WorkflowSourceSpecification(
                identityID: try WorkflowSourceIdentityID(digest(index + 8)),
                bookmark: sourceBookmark
            ),
            output: WorkflowOutputSpecification(
                contractID: try WorkflowOutputContractID(digest(index + 9)),
                directoryBookmark: outputBookmark,
                fileName: try WorkflowOutputFileName("output-\(index).mov")
            ),
            runtimeBinding: runtime
        )
    }

    private static func checkpointDraft(
        codec: WorkflowOutputContractID
    ) throws -> WorkflowCheckpointDraftV4 {
        let segment = try WorkflowSegmentCheckpointV4(
            ordinal: 0,
            artifact: artifact(1, .segment),
            startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 600, timescale: 600),
            nextStartTime: WorkflowMediaTimeV4(value: 600, timescale: 600),
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
            temporalHistory: try artifact(2, .temporalHistory),
            measurementHysteresis: try artifact(3, .measurementHysteresis),
            auxiliaryState: [try artifact(4, .trackState)]
        )
    }

    private static func artifact(
        _ index: Int,
        _ kind: WorkflowCheckpointArtifactKindV4
    ) throws -> WorkflowCheckpointArtifactV4 {
        try WorkflowCheckpointArtifactV4(
            artifactID: WorkflowArtifactIDV4("artifact-\(index)"),
            kind: kind,
            relativePath: "artifacts/artifact-\(index).bin",
            byteCount: UInt64(index * 100),
            sha256: WorkflowCheckpointArtifactHashV4(digest(index + 20)),
            reopenReceiptSHA256: WorkflowCheckpointArtifactHashV4(
                digest(index + 30)
            )
        )
    }

    private static func digest(_ value: Int) -> String {
        String(format: "%064llx", value)
    }
}
