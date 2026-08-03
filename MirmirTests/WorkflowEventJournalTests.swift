import Foundation
import XCTest
@testable import Mirmir

final class WorkflowCanonicalCodecTests: XCTestCase {
    func testCanonicalPayloadAndEventHashesMatchGoldenVector() throws {
        let codec = WorkflowCanonicalCodec()
        let event = WorkflowEvent.queueReordered([
            try WorkflowJobID("job-2"),
            try WorkflowJobID("job-1")
        ])
        let draft = WorkflowEventDraft(
            eventID: try WorkflowEventID("event-1"),
            commandID: try WorkflowCommandID("command-1"),
            scope: .queue,
            jobBinding: nil,
            attemptID: nil,
            event: event
        )
        let envelope = try codec.seal(
            draft,
            sequence: 0,
            previousEventHash: nil
        )

        XCTAssertEqual(
            String(decoding: try codec.canonicalData(event), as: UTF8.self),
            "{\"kind\":\"queueReordered\",\"orderedJobIDs\":[\"job-2\",\"job-1\"]}"
        )
        XCTAssertEqual(
            envelope.payloadHash.rawValue,
            "177001cdf529e10bad2817772b899bceab0ba4a2714d9d14da612128088a0d8a"
        )
        XCTAssertEqual(
            envelope.eventHash.rawValue,
            "97ca33504b76a15ae14529ca133b14b953b95bbbb9847e8cf52718a5439c955b"
        )
        XCTAssertNoThrow(try codec.verify(envelope))
    }

    func testForgedHashesAndNoncanonicalJSONFailVerification() throws {
        let codec = WorkflowCanonicalCodec()
        let draft = try queueDraft(index: 1)
        let valid = try codec.seal(
            draft,
            sequence: 0,
            previousEventHash: nil
        )
        let forgedPayload = try WorkflowEventEnvelope(
            sequence: valid.sequence,
            eventID: valid.eventID,
            commandID: valid.commandID,
            scope: valid.scope,
            jobBinding: valid.jobBinding,
            attemptID: valid.attemptID,
            previousEventHash: valid.previousEventHash,
            payloadHash: WorkflowPayloadHash(journalTestHex: 900),
            eventHash: valid.eventHash,
            event: valid.event
        )
        XCTAssertThrowsError(try codec.verify(forgedPayload)) { error in
            XCTAssertEqual(
                error as? WorkflowCanonicalCodecError,
                .payloadHashMismatch
            )
        }

        let forgedEvent = try WorkflowEventEnvelope(
            sequence: valid.sequence,
            eventID: valid.eventID,
            commandID: valid.commandID,
            scope: valid.scope,
            jobBinding: valid.jobBinding,
            attemptID: valid.attemptID,
            previousEventHash: valid.previousEventHash,
            payloadHash: valid.payloadHash,
            eventHash: WorkflowEventHash(journalTestHex: 901),
            event: valid.event
        )
        XCTAssertThrowsError(try codec.verify(forgedEvent)) { error in
            XCTAssertEqual(
                error as? WorkflowCanonicalCodecError,
                .eventHashMismatch
            )
        }

        var noncanonical = try codec.canonicalData(valid)
        noncanonical.append(0x0A)
        XCTAssertThrowsError(
            try codec.decodeCanonicalEnvelope(noncanonical)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowCanonicalCodecError,
                .nonCanonicalEncoding
            )
        }
    }

    func testEveryTruncationBeforeCommitFooterIsUncommitted() throws {
        let codec = WorkflowCanonicalCodec()
        let frameCodec = WorkflowJournalFrameCodec()
        let specification = try journalSpecification(index: 1)
        let envelope = try codec.seal(
            enqueueDraft(specification, index: 1),
            sequence: 0,
            previousEventHash: nil
        )
        let frame = try frameCodec.makeFrame(
            envelope: envelope,
            codec: codec,
            maximumEventBytes: 1_000_000
        )

        for byteCount in 0 ..< frame.data.count {
            let replay = try frameCodec.replay(
                Data(frame.data.prefix(byteCount)),
                startingAt: 0,
                initialState: WorkflowState(),
                codec: codec,
                maximumEventBytes: 1_000_000
            )
            XCTAssertEqual(replay.validByteCount, 0, "prefix \(byteCount)")
            XCTAssertEqual(replay.state, WorkflowState(), "prefix \(byteCount)")
        }

        let committed = try frameCodec.replay(
            frame.data,
            startingAt: 0,
            initialState: WorkflowState(),
            codec: codec,
            maximumEventBytes: 1_000_000
        )
        XCTAssertEqual(committed.validByteCount, frame.data.count)
        XCTAssertEqual(
            committed.state.job(id: specification.jobID)?.lifecycle,
            .queued
        )
    }

    func testEveryCommittedFrameByteFlipFailsClosed() throws {
        let codec = WorkflowCanonicalCodec()
        let frameCodec = WorkflowJournalFrameCodec()
        let specification = try journalSpecification(index: 1)
        let envelope = try codec.seal(
            enqueueDraft(specification, index: 1),
            sequence: 0,
            previousEventHash: nil
        )
        let frame = try frameCodec.makeFrame(
            envelope: envelope,
            codec: codec,
            maximumEventBytes: 1_000_000
        )

        for offset in frame.data.indices {
            var corrupted = frame.data
            corrupted[offset] ^= 0x01
            XCTAssertThrowsError(
                try frameCodec.replay(
                    corrupted,
                    startingAt: 0,
                    initialState: WorkflowState(),
                    codec: codec,
                    maximumEventBytes: 1_000_000
                ),
                "Committed mutation at byte \(offset) was accepted."
            ) { error in
                guard case WorkflowEventJournalError.corruptJournal = error else {
                    return XCTFail("Unexpected error at byte \(offset): \(error)")
                }
            }
        }
    }
}

final class WorkflowEventJournalTests: XCTestCase {
    func testAppendReopenSnapshotAndTailReplay() throws {
        let store = try makeJournalStore()
        let first = try journalSpecification(index: 1)
        let second = try journalSpecification(index: 2)
        let initial = try store.journal.open()
        XCTAssertEqual(initial.state, WorkflowState())
        XCTAssertEqual(initial.recovery.snapshot, .absent)

        let firstResult = try store.journal.append(
            enqueueDraft(first, index: 1)
        )
        let secondResult = try store.journal.append(
            enqueueDraft(second, index: 2)
        )
        XCTAssertEqual(firstResult.disposition, .committed)
        XCTAssertEqual(secondResult.state.queueOrder, [first.jobID, second.jobID])

        let snapshot = try store.journal.writeSnapshot()
        XCTAssertEqual(snapshot.body.generation, 1)
        let transition = try store.journal.append(
            transitionDraft(
                first,
                index: 3,
                from: .queued,
                to: .probing
            )
        )
        XCTAssertEqual(transition.state.queueOrder, [second.jobID])

        let reopened = try WorkflowEventJournal(
            rootURL: store.root,
            fileSystem: store.fileSystem
        ).open()
        XCTAssertEqual(reopened.state, transition.state)
        XCTAssertEqual(reopened.recovery.snapshot, .applied(generation: 1))
        XCTAssertEqual(reopened.recovery.tail, .clean)
        XCTAssertEqual(
            reopened.validJournalByteCount,
            reopened.physicalJournalByteCount
        )
    }

    func testIdempotentRetryDoesNotGrowJournalAndConflictsFail() throws {
        let store = try makeJournalStore()
        let specification = try journalSpecification(index: 1)
        let draft = try enqueueDraft(specification, index: 1)
        let committed = try store.journal.append(draft)
        let journalURL = store.root.appendingPathComponent("events-v1.bin")
        let before = try store.fileSystem.readRegularFile(
            journalURL,
            maximumBytes: WorkflowJournalConfiguration.default.maximumJournalBytes
        )

        let duplicate = try store.journal.append(draft)
        let after = try store.fileSystem.readRegularFile(
            journalURL,
            maximumBytes: WorkflowJournalConfiguration.default.maximumJournalBytes
        )
        XCTAssertEqual(committed.disposition, .committed)
        XCTAssertEqual(duplicate.disposition, .alreadyApplied)
        XCTAssertEqual(before, after)
        XCTAssertEqual(duplicate.receipt, committed.receipt)

        let conflict = WorkflowEventDraft(
            eventID: try WorkflowEventID("event-conflict"),
            commandID: draft.commandID,
            scope: .queue,
            jobBinding: nil,
            attemptID: nil,
            event: .queueReordered([specification.jobID])
        )
        XCTAssertThrowsError(try store.journal.append(conflict)) { error in
            XCTAssertEqual(
                error as? WorkflowEventJournalError,
                .idempotencyConflict
            )
        }
        let unchanged = try store.fileSystem.readRegularFile(
            journalURL,
            maximumBytes: WorkflowJournalConfiguration.default.maximumJournalBytes
        )
        XCTAssertEqual(unchanged, after)
    }

    func testTornBodyIsQuarantinedAndRetryCommitsOnce() throws {
        let store = try makeJournalStore()
        let first = try journalSpecification(index: 1)
        let second = try journalSpecification(index: 2)
        let firstResult = try store.journal.append(
            enqueueDraft(first, index: 1)
        )
        let secondDraft = try enqueueDraft(second, index: 2)
        let candidate = try WorkflowCanonicalCodec().seal(
            secondDraft,
            sequence: 1,
            previousEventHash: firstResult.state.lastEventHash
        )
        let frame = try WorkflowJournalFrameCodec().makeFrame(
            envelope: candidate,
            codec: WorkflowCanonicalCodec(),
            maximumEventBytes: WorkflowJournalConfiguration.default.maximumEventBytes
        )
        let journalURL = store.root.appendingPathComponent("events-v1.bin")
        try store.fileSystem.appendDurably(
            frame.body,
            to: journalURL,
            maximumFileBytes: WorkflowJournalConfiguration.default.maximumJournalBytes
        )

        let detected = try store.journal.open(repairTornTail: false)
        XCTAssertEqual(
            detected.recovery.tail,
            .detected(discardableBytes: frame.body.count)
        )
        XCTAssertEqual(detected.state, firstResult.state)

        let repaired = try store.journal.open(repairTornTail: true)
        guard case let .repaired(discardedBytes, quarantineName) =
            repaired.recovery.tail
        else {
            return XCTFail("Expected a repaired tail.")
        }
        XCTAssertEqual(discardedBytes, frame.body.count)
        let quarantined = try store.fileSystem.readRegularFile(
            store.root
                .appendingPathComponent("quarantine", isDirectory: true)
                .appendingPathComponent(quarantineName),
            maximumBytes: frame.body.count
        )
        XCTAssertEqual(quarantined, frame.body)
        XCTAssertEqual(repaired.state, firstResult.state)

        let retried = try store.journal.append(secondDraft)
        XCTAssertEqual(retried.disposition, .committed)
        XCTAssertEqual(retried.state.appliedEvents.count, 2)
        XCTAssertEqual(
            try store.journal.append(secondDraft).disposition,
            .alreadyApplied
        )
    }

    func testCommittedMiddleCorruptionIsNeverTruncated() throws {
        let store = try makeJournalStore()
        let first = try journalSpecification(index: 1)
        let second = try journalSpecification(index: 2)
        let firstResult = try store.journal.append(
            enqueueDraft(first, index: 1)
        )
        _ = try store.journal.append(enqueueDraft(second, index: 2))
        let firstFrame = try WorkflowJournalFrameCodec().makeFrame(
            envelope: try XCTUnwrap(firstResult.envelope),
            codec: WorkflowCanonicalCodec(),
            maximumEventBytes: WorkflowJournalConfiguration.default.maximumEventBytes
        )
        let journalURL = store.root.appendingPathComponent("events-v1.bin")
        var bytes = try store.fileSystem.readRegularFile(
            journalURL,
            maximumBytes: WorkflowJournalConfiguration.default.maximumJournalBytes
        )
        bytes[WorkflowJournalFrameCodec.headerByteCount + 7] ^= 0x01
        try store.fileSystem.replaceAtomically(bytes, at: journalURL)
        let corruptedByteCount = bytes.count

        XCTAssertThrowsError(
            try store.journal.open(repairTornTail: true)
        ) { error in
            guard case let WorkflowEventJournalError.corruptJournal(offset, _) =
                error
            else {
                return XCTFail("Unexpected corruption error: \(error)")
            }
            XCTAssertEqual(offset, 0)
        }
        XCTAssertEqual(
            try store.fileSystem.readRegularFile(
                journalURL,
                maximumBytes: WorkflowJournalConfiguration.default
                    .maximumJournalBytes
            ).count,
            corruptedByteCount
        )
        XCTAssertGreaterThan(firstFrame.data.count, 0)
    }

    func testCommittedLengthCorruptionCannotMasqueradeAsTornTail() throws {
        let store = try makeJournalStore()
        let specification = try journalSpecification(index: 1)
        _ = try store.journal.append(
            enqueueDraft(specification, index: 1)
        )
        let journalURL = store.root.appendingPathComponent("events-v1.bin")
        var bytes = try store.fileSystem.readRegularFile(
            journalURL,
            maximumBytes: WorkflowJournalConfiguration.default.maximumJournalBytes
        )
        bytes[21] ^= 0x01
        try store.fileSystem.replaceAtomically(bytes, at: journalURL)

        XCTAssertThrowsError(
            try store.journal.open(repairTornTail: true)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowEventJournalError,
                .corruptJournal(offset: 0, reason: .headerHashMismatch)
            )
        }
        XCTAssertEqual(
            try store.fileSystem.readRegularFile(
                journalURL,
                maximumBytes: WorkflowJournalConfiguration.default
                    .maximumJournalBytes
            ),
            bytes
        )
    }

    func testCorruptSnapshotFallsBackToAuthoritativeJournal() throws {
        let store = try makeJournalStore()
        let specification = try journalSpecification(index: 1)
        let committed = try store.journal.append(
            enqueueDraft(specification, index: 1)
        )
        _ = try store.journal.writeSnapshot()
        let snapshotURL = store.root.appendingPathComponent("snapshot-v1.json")
        try store.fileSystem.replaceAtomically(
            Data("{\"broken\":true}".utf8),
            at: snapshotURL
        )

        let reopened = try store.journal.open()
        XCTAssertEqual(reopened.state, committed.state)
        XCTAssertEqual(reopened.recovery.snapshot, .rejected(.unreadable))
        XCTAssertEqual(reopened.recovery.tail, .clean)
    }

    func testConcurrentSameCommandRaceWritesOnePhysicalFrame() async throws {
        let store = try makeJournalStore()
        let specification = try journalSpecification(index: 1)
        let draft = try enqueueDraft(specification, index: 1)
        let dispositions = try await withThrowingTaskGroup(
            of: WorkflowJournalAppendDisposition.self
        ) { group in
            for _ in 0 ..< 24 {
                group.addTask {
                    try store.journal.append(draft).disposition
                }
            }
            var values: [WorkflowJournalAppendDisposition] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(dispositions.filter { $0 == .committed }.count, 1)
        XCTAssertEqual(dispositions.filter { $0 == .alreadyApplied }.count, 23)
        let reopened = try store.journal.open()
        XCTAssertEqual(reopened.state.appliedEvents.count, 1)
        XCTAssertEqual(reopened.state.queueOrder, [specification.jobID])
    }

    func testAppendFaultAtEveryBodyAndFooterBoundaryRecoversExactlyOnce() throws {
        let points: [WorkflowFileSystemFaultPoint] = [
            .beforeAppend,
            .afterAppendChunk,
            .afterAppendWrite,
            .afterAppendFileSync
        ]
        for point in points {
            for occurrence in 1 ... 2 {
                let controller = WorkflowFaultController()
                let store = try makeJournalStore(controller: controller)
                let specification = try journalSpecification(index: 1)
                let draft = try enqueueDraft(specification, index: 1)
                _ = try store.journal.open()
                controller.arm(point, occurrence: occurrence)

                XCTAssertThrowsError(
                    try store.journal.append(draft),
                    "\(point.rawValue), occurrence \(occurrence)"
                )
                let retry = try store.journal.append(draft)
                XCTAssertTrue(
                    retry.disposition == .committed
                        || retry.disposition == .alreadyApplied
                )
                let reopened = try store.journal.open()
                XCTAssertEqual(reopened.state.appliedEvents.count, 1)
                XCTAssertEqual(reopened.state.queueOrder, [specification.jobID])
            }
        }
    }

    func testPartialAppendChunkIsDetectedAsTornWrite() throws {
        let controller = WorkflowFaultController()
        let store = try makeJournalStore(
            controller: controller,
            maximumWriteChunkBytes: 7
        )
        let specification = try journalSpecification(index: 1)
        let draft = try enqueueDraft(specification, index: 1)
        _ = try store.journal.open()
        controller.arm(.afterAppendChunk, occurrence: 1)

        XCTAssertThrowsError(try store.journal.append(draft))
        let detected = try store.journal.open(repairTornTail: false)
        guard case let .detected(discardableBytes) = detected.recovery.tail else {
            return XCTFail("Expected a detected partial append.")
        }
        XCTAssertEqual(discardableBytes, 7)
        XCTAssertEqual(detected.state, WorkflowState())
        _ = try store.journal.open(repairTornTail: true)
        XCTAssertEqual(try store.journal.append(draft).disposition, .committed)
    }

    func testSnapshotFaultAtEveryAtomicBoundaryLeavesOldOrNewSnapshot() throws {
        let points: [WorkflowFileSystemFaultPoint] = [
            .beforeTemporaryCreate,
            .afterTemporaryWriteChunk,
            .afterTemporaryWrite,
            .afterTemporaryFileSync,
            .beforePublishRename,
            .afterPublishRename,
            .afterPublishParentSync
        ]
        for point in points {
            let controller = WorkflowFaultController()
            let store = try makeJournalStore(controller: controller)
            let specification = try journalSpecification(index: 1)
            let committed = try store.journal.append(
                enqueueDraft(specification, index: 1)
            )
            XCTAssertEqual(try store.journal.writeSnapshot().body.generation, 1)
            controller.arm(point)

            XCTAssertThrowsError(
                try store.journal.writeSnapshot(),
                point.rawValue
            )
            let reopened = try store.journal.open()
            XCTAssertEqual(reopened.state, committed.state)
            switch reopened.recovery.snapshot {
            case .applied(generation: 1), .applied(generation: 2):
                break
            default:
                XCTFail(
                    "\(point.rawValue) left no valid old/new snapshot: "
                        + "\(reopened.recovery.snapshot)"
                )
            }
        }
    }

    func testInitialSnapshotFaultLeavesAbsentOrValidSnapshot() throws {
        let points: [WorkflowFileSystemFaultPoint] = [
            .beforeTemporaryCreate,
            .afterTemporaryWriteChunk,
            .afterTemporaryWrite,
            .afterTemporaryFileSync,
            .beforePublishRename,
            .afterPublishRename,
            .afterPublishParentSync
        ]
        for point in points {
            let controller = WorkflowFaultController()
            let store = try makeJournalStore(controller: controller)
            let specification = try journalSpecification(index: 1)
            let committed = try store.journal.append(
                enqueueDraft(specification, index: 1)
            )
            controller.arm(point)

            XCTAssertThrowsError(
                try store.journal.writeSnapshot(),
                point.rawValue
            )
            let reopened = try store.journal.open()
            XCTAssertEqual(reopened.state, committed.state)
            switch reopened.recovery.snapshot {
            case .absent, .applied(generation: 1):
                break
            default:
                XCTFail(
                    "\(point.rawValue) left a malformed initial snapshot: "
                        + "\(reopened.recovery.snapshot)"
                )
            }
        }
    }

    func testTruncateFaultsRemainRetryable() throws {
        let points: [WorkflowFileSystemFaultPoint] = [
            .beforeTruncate,
            .afterTruncate,
            .afterTruncateFileSync
        ]
        for point in points {
            let controller = WorkflowFaultController()
            let store = try makeJournalStore(controller: controller)
            let specification = try journalSpecification(index: 1)
            let committed = try store.journal.append(
                enqueueDraft(specification, index: 1)
            )
            let journalURL = store.root.appendingPathComponent("events-v1.bin")
            try store.fileSystem.appendDurably(
                Data("MIR".utf8),
                to: journalURL,
                maximumFileBytes: WorkflowJournalConfiguration.default
                    .maximumJournalBytes
            )
            controller.arm(point)

            XCTAssertThrowsError(
                try store.journal.open(repairTornTail: true),
                point.rawValue
            )
            let recovered = try store.journal.open(repairTornTail: true)
            XCTAssertEqual(recovered.state, committed.state)
            XCTAssertEqual(try store.journal.open().recovery.tail, .clean)
        }
    }

    func testRegularFileResyncFaultsAreExplicitAndRetryable() throws {
        for point in [
            WorkflowFileSystemFaultPoint.beforeRegularFileSync,
            .afterRegularFileSync
        ] {
            let controller = WorkflowFaultController()
            let store = try makeJournalStore(controller: controller)
            _ = try store.journal.open()
            controller.arm(point)
            XCTAssertThrowsError(try store.journal.open(), point.rawValue)
            XCTAssertNoThrow(try store.journal.open())
        }
    }
}

final class WorkflowDurableFileSystemTests: XCTestCase {
    func testJobLeaseIsExclusiveUntilExplicitRelease() throws {
        let store = try makeJournalStore()
        let firstJob = try WorkflowJobID("job-1")
        let secondJob = try WorkflowJobID("job-2")
        let firstLease = try store.journal.acquireJobLease(for: firstJob)
        XCTAssertTrue(firstLease.isHeld)
        XCTAssertThrowsError(
            try store.journal.acquireJobLease(for: firstJob)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowDurableFileSystemError,
                .lockUnavailable(
                    store.root
                        .appendingPathComponent("jobs/job-1/worker.lock")
                        .path
                )
            )
        }

        let independentLease = try store.journal.acquireJobLease(for: secondJob)
        XCTAssertTrue(independentLease.isHeld)
        firstLease.release()
        XCTAssertFalse(firstLease.isHeld)
        firstLease.release()
        let reacquired = try store.journal.acquireJobLease(for: firstJob)
        XCTAssertTrue(reacquired.isHeld)
        reacquired.release()
        independentLease.release()
    }

    func testDirectoryAndLockFaultsReleaseOrRemainRetryable() throws {
        for point in [
            WorkflowFileSystemFaultPoint.afterDirectoryCreate,
            .afterDirectoryParentSync
        ] {
            let controller = WorkflowFaultController()
            let root = try makeTemporaryRoot()
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let fileSystem = try WorkflowLocalDurableFileSystem(
                trustedRootURL: root,
                durabilityLevel: .processCrash,
                operationHook: { [controller] point, url in
                    try controller.hook(point, url)
                }
            )
            let child = root.appendingPathComponent("child", isDirectory: true)
            controller.arm(point)
            XCTAssertThrowsError(try fileSystem.ensureDirectory(child))
            XCTAssertNoThrow(try fileSystem.ensureDirectory(child))
        }

        for point in [
            WorkflowFileSystemFaultPoint.beforeLockOpen,
            .afterLockOpen,
            .afterLockAcquired
        ] {
            let controller = WorkflowFaultController()
            let root = try makeTemporaryRoot()
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let fileSystem = try WorkflowLocalDurableFileSystem(
                trustedRootURL: root,
                durabilityLevel: .processCrash,
                operationHook: { [controller] point, url in
                    try controller.hook(point, url)
                }
            )
            let lockURL = root.appendingPathComponent("lease.lock")
            controller.arm(point)
            XCTAssertThrowsError(
                try fileSystem.acquireExclusiveLease(
                    at: lockURL,
                    nonBlocking: true
                )
            )
            let lease = try fileSystem.acquireExclusiveLease(
                at: lockURL,
                nonBlocking: true
            )
            lease.release()
        }
    }

    func testSymlinkAndPathsOutsideTrustedRootAreRejected() throws {
        let root = try makeTemporaryRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let outside = try makeTemporaryRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: root,
            durabilityLevel: .processCrash
        )
        let outsideFile = outside.appendingPathComponent("outside.bin")
        try Data("outside".utf8).write(to: outsideFile)
        let symlink = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: outsideFile
        )

        XCTAssertThrowsError(
            try fileSystem.readRegularFile(symlink, maximumBytes: 100)
        )
        XCTAssertThrowsError(
            try fileSystem.readRegularFile(outsideFile, maximumBytes: 100)
        )
        XCTAssertThrowsError(
            try fileSystem.acquireExclusiveLease(
                at: symlink,
                nonBlocking: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))
    }

    func testFaultCoverageNamesEveryFilesystemBoundary() {
        let covered: Set<WorkflowFileSystemFaultPoint> = [
            .afterDirectoryCreate,
            .afterDirectoryParentSync,
            .beforeTemporaryCreate,
            .afterTemporaryWriteChunk,
            .afterTemporaryWrite,
            .afterTemporaryFileSync,
            .beforePublishRename,
            .afterPublishRename,
            .afterPublishParentSync,
            .beforeAppend,
            .afterAppendChunk,
            .afterAppendWrite,
            .afterAppendFileSync,
            .beforeRegularFileSync,
            .afterRegularFileSync,
            .beforeTruncate,
            .afterTruncate,
            .afterTruncateFileSync,
            .beforeLockOpen,
            .afterLockOpen,
            .afterLockAcquired
        ]
        XCTAssertEqual(covered, Set(WorkflowFileSystemFaultPoint.allCases))
    }
}

private struct WorkflowJournalTestStore: Sendable {
    let root: URL
    let fileSystem: WorkflowLocalDurableFileSystem
    let journal: WorkflowEventJournal
}

private extension XCTestCase {
    func makeJournalStore(
        controller: WorkflowFaultController? = nil,
        maximumWriteChunkBytes: Int = Int.max
    ) throws -> WorkflowJournalTestStore {
        let root = try makeTemporaryRoot()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let operationHook: WorkflowLocalDurableFileSystem.OperationHook?
        if let controller {
            operationHook = { @Sendable [controller] point, url in
                try controller.hook(point, url)
            }
        } else {
            operationHook = nil
        }
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: root,
            durabilityLevel: .processCrash,
            maximumWriteChunkBytes: maximumWriteChunkBytes,
            operationHook: operationHook
        )
        return WorkflowJournalTestStore(
            root: root,
            fileSystem: fileSystem,
            journal: try WorkflowEventJournal(
                rootURL: root,
                fileSystem: fileSystem
            )
        )
    }

    func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-workflow-journal-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }
}

private final class WorkflowFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var target: WorkflowFileSystemFaultPoint?
    private var targetOccurrence = 1
    private var observedOccurrences = 0

    func arm(
        _ point: WorkflowFileSystemFaultPoint,
        occurrence: Int = 1
    ) {
        lock.withLock {
            target = point
            targetOccurrence = occurrence
            observedOccurrences = 0
        }
    }

    func hook(_ point: WorkflowFileSystemFaultPoint, _: URL) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard target == point else { return false }
            observedOccurrences += 1
            guard observedOccurrences == targetOccurrence else { return false }
            target = nil
            return true
        }
        if shouldThrow {
            throw WorkflowInjectedFault(point: point)
        }
    }
}

private struct WorkflowInjectedFault: Error, Equatable {
    let point: WorkflowFileSystemFaultPoint
}

private func journalSpecification(
    index: Int
) throws -> WorkflowJobSpecification {
    let seed = UInt64(index) * 100
    let sourceBookmark = try WorkflowBookmarkReference(
        bookmarkID: WorkflowBookmarkID("journal-source-\(index)"),
        revision: 1,
        documentHash: journalDigest(seed + 1)
    )
    let outputBookmark = try WorkflowBookmarkReference(
        bookmarkID: WorkflowBookmarkID("journal-output-\(index)"),
        revision: 1,
        documentHash: journalDigest(seed + 2)
    )
    return WorkflowJobSpecification(
        jobID: try WorkflowJobID("journal-job-\(index)"),
        requestID: try journalDigest(seed + 3),
        source: WorkflowSourceSpecification(
            identityID: try journalDigest(seed + 4),
            bookmark: sourceBookmark
        ),
        output: WorkflowOutputSpecification(
            contractID: try journalDigest(seed + 5),
            directoryBookmark: outputBookmark,
            fileName: try WorkflowOutputFileName("journal-output-\(index).mov")
        ),
        runtimeBinding: WorkflowRuntimeBinding(
            id: try journalDigest(seed + 6),
            runtimeManifestID: try journalDigest(seed + 7),
            planID: try journalDigest(seed + 8),
            backendID: try WorkflowBackendID("deterministic-v4"),
            backendRevisionID: try WorkflowBackendRevisionID("revision-1"),
            mediaContractID: try journalDigest(seed + 9)
        )
    )
}

private func enqueueDraft(
    _ specification: WorkflowJobSpecification,
    index: Int
) throws -> WorkflowEventDraft {
    WorkflowEventDraft(
        eventID: try WorkflowEventID("journal-event-\(index)"),
        commandID: try WorkflowCommandID("journal-command-\(index)"),
        scope: .job(specification.jobID),
        jobBinding: specification.binding,
        attemptID: nil,
        event: .jobEnqueued(specification)
    )
}

private func transitionDraft(
    _ specification: WorkflowJobSpecification,
    index: Int,
    from: WorkflowJobLifecycle,
    to: WorkflowJobLifecycle,
    attemptID: WorkflowAttemptID? = nil
) throws -> WorkflowEventDraft {
    WorkflowEventDraft(
        eventID: try WorkflowEventID("journal-event-\(index)"),
        commandID: try WorkflowCommandID("journal-command-\(index)"),
        scope: .job(specification.jobID),
        jobBinding: specification.binding,
        attemptID: attemptID,
        event: .lifecycleTransition(.init(from: from, to: to))
    )
}

private func queueDraft(index: Int) throws -> WorkflowEventDraft {
    WorkflowEventDraft(
        eventID: try WorkflowEventID("queue-event-\(index)"),
        commandID: try WorkflowCommandID("queue-command-\(index)"),
        scope: .queue,
        jobBinding: nil,
        attemptID: nil,
        event: .queueReordered([])
    )
}

private extension WorkflowDigest {
    init(journalTestHex value: UInt64) throws {
        let suffix = String(value, radix: 16)
        try self.init(String(repeating: "0", count: 64 - suffix.count) + suffix)
    }
}

private func journalDigest<Purpose: WorkflowDigestPurpose>(
    _ value: UInt64
) throws -> WorkflowDigest<Purpose> {
    try WorkflowDigest(journalTestHex: value)
}
