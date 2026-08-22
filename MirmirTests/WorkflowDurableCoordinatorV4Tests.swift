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

    func testLeaseEnvelopeV1MigratesWithoutChangingLeaseIdentity() async throws {
        let fixture = try makeFixture()
        let first = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 21)
        try await enqueue(specification, into: first, index: 21)
        let claim = try await first.acquire(
            acquisition(index: 21, worker: 21)
        )
        await first.injectProcessTerminationAfterLeasePersistence()

        let leaseURL = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(specification.jobID.rawValue, isDirectory: true)
            .appendingPathComponent("lease-v4.json")
        let codec = WorkflowCanonicalCodec()
        let current = try codec.decodeCanonical(
            WorkflowLeaseDocumentV4.self,
            from: Data(contentsOf: leaseURL)
        )
        let legacy = WorkflowLeaseDocumentV1(
            bodyHash: current.bodyHash,
            body: current.body
        )
        try codec.canonicalData(legacy).write(to: leaseURL, options: .atomic)

        let relaunched = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let inspection = try await relaunched.inspectRecovery(
            jobID: specification.jobID
        )
        XCTAssertEqual(
            inspection,
            .awaitingExpiry(
                leaseID: claim.leaseID,
                expiresAt: claim.expiresAt
            )
        )
        let migratedData = try Data(contentsOf: leaseURL)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: migratedData
            ).schemaVersion,
            WorkflowLeaseDocumentV4.currentSchemaVersion
        )
        XCTAssertEqual(
            try codec.decodeCanonical(
                WorkflowLeaseDocumentV4.self,
                from: migratedData
            ),
            current
        )
    }

    func testCheckpointEnvelopeV1MigratesHeadWithoutRewritingLegacyArchive()
        async throws {
        let fixture = try makeFixture()
        let fault = CheckpointMigrationFaultV4()
        let fileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: fixture.storeURL,
            durabilityLevel: .processCrash,
            operationHook: { [fault] point, url in
                try fault.hook(point, url)
            }
        )
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            fileSystem: fileSystem,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 22)
        try await enqueue(specification, into: coordinator, index: 22)
        let claim = try await coordinator.acquire(
            acquisition(index: 22, worker: 22)
        )
        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("migration-plan-event"),
                commandID: WorkflowCommandID("migration-plan-command"),
                from: .probing,
                to: .planned,
                attemptID: nil
            ),
            using: claim
        )
        let attemptID = try WorkflowAttemptID("migration-attempt")
        _ = try await coordinator.transition(
            WorkflowLifecycleCommandV4(
                eventID: WorkflowEventID("migration-run-event"),
                commandID: WorkflowCommandID("migration-run-command"),
                from: .planned,
                to: .running,
                attemptID: attemptID
            ),
            using: claim
        )
        let committed = try await coordinator.commitCheckpoint(
            checkpointDraft(codec: specification.output.contractID),
            using: claim
        ).document
        let codec = WorkflowCanonicalCodec()
        let legacyBody = legacyCheckpointBody(
            from: committed.body,
            schemaVersion: 1
        )
        let legacyHash = try legacyCheckpointBodyHash(legacyBody)
        let legacy = WorkflowCheckpointDocumentV1(
            bodyHash: legacyHash,
            body: legacyBody
        )
        let legacyData = try codec.canonicalData(legacy)
        let directory = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(specification.jobID.rawValue, isDirectory: true)
            .appendingPathComponent("checkpoints-v4", isDirectory: true)
        let headURL = directory.appendingPathComponent("head-v1.json")
        let legacyArchiveURL = directory.appendingPathComponent(
            String(
                format: "checkpoint-%020llu-%@.json",
                committed.body.ordinal,
                String(legacyHash.rawValue.prefix(16))
            )
        )
        let currentArchiveURL = directory.appendingPathComponent(
            String(
                format: "checkpoint-%020llu-%@.json",
                committed.body.ordinal,
                String(committed.bodyHash.rawValue.prefix(16))
            )
        )
        try FileManager.default.removeItem(at: currentArchiveURL)
        try legacyData.write(to: legacyArchiveURL, options: .atomic)
        try legacyData.write(to: headURL, options: .atomic)

        let currentData = try codec.canonicalData(committed)
        fault.arm(targetName: currentArchiveURL.lastPathComponent)
        do {
            _ = try await coordinator.loadCompatibleCheckpoint(
                jobID: specification.jobID,
                expectedCodecSettingsHash: specification.output.contractID
            )
            XCTFail("The injected archive publication interruption was missed.")
        } catch let error as WorkflowDurableFileSystemError {
            XCTAssertEqual(
                error,
                .indeterminate(
                    operation: "write_new_atomically",
                    path: currentArchiveURL.path
                )
            )
        }
        XCTAssertTrue(fault.didFire)
        XCTAssertEqual(try Data(contentsOf: headURL), legacyData)
        XCTAssertEqual(try Data(contentsOf: legacyArchiveURL), legacyData)
        XCTAssertEqual(try Data(contentsOf: currentArchiveURL), currentData)

        let loaded = try await coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        XCTAssertEqual(loaded, committed)
        XCTAssertEqual(try Data(contentsOf: headURL), currentData)
        XCTAssertEqual(try Data(contentsOf: legacyArchiveURL), legacyData)
        XCTAssertEqual(try Data(contentsOf: currentArchiveURL), currentData)
        let replayed = try await coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        XCTAssertEqual(replayed, committed)
    }

    func testCheckpointEnvelopeV2MigratesTerminalTailToNilBoundary()
        async throws {
        let fixture = try makeFixture()
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 23)
        try await enqueue(specification, into: coordinator, index: 23)
        let body = try checkpointBody(
            specification: specification,
            segments: [
                WorkflowSegmentCheckpointV4(
                    ordinal: 0,
                    artifact: checkpointArtifact(index: 1, kind: .segment),
                    startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
                    endTimeExclusive: WorkflowMediaTimeV4(
                        value: 600,
                        timescale: 600
                    ),
                    nextStartTime: WorkflowMediaTimeV4(
                        value: 600,
                        timescale: 600
                    ),
                    codecSettingsHash: specification.output.contractID,
                    isIndependentlyDecodable: true
                ),
                WorkflowSegmentCheckpointV4(
                    ordinal: 1,
                    artifact: checkpointArtifact(index: 5, kind: .segment),
                    startTime: WorkflowMediaTimeV4(
                        value: 600,
                        timescale: 600
                    ),
                    endTimeExclusive: WorkflowMediaTimeV4(
                        value: 1_200,
                        timescale: 600
                    ),
                    nextStartTime: nil,
                    codecSettingsHash: specification.output.contractID,
                    isIndependentlyDecodable: true
                )
            ],
            videoIsComplete: true
        )
        let expectedPreviousCheckpointHash = try XCTUnwrap(
            body.previousCheckpointHash
        )
        let directory = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(specification.jobID.rawValue, isDirectory: true)
            .appendingPathComponent("checkpoints-v4", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let headURL = directory.appendingPathComponent("head-v1.json")
        for legacyBodySchema in [UInt16(1), UInt16(2)] {
            let legacyBody = legacyCheckpointBody(
                from: body,
                schemaVersion: legacyBodySchema
            )
            let legacy = WorkflowCheckpointDocumentV2(
                bodyHash: try legacyCheckpointBodyHash(legacyBody),
                body: legacyBody
            )
            try WorkflowCanonicalCodec().canonicalData(legacy).write(
                to: headURL,
                options: .atomic
            )

            let loaded = try await coordinator.loadCompatibleCheckpoint(
                jobID: specification.jobID,
                expectedCodecSettingsHash: specification.output.contractID
            )
            let decoded = try XCTUnwrap(loaded)
            XCTAssertEqual(decoded.body, body)
            XCTAssertEqual(decoded.bodyHash, try currentCheckpointBodyHash(body))
            XCTAssertEqual(
                decoded.body.previousCheckpointHash,
                expectedPreviousCheckpointHash
            )
            XCTAssertNil(decoded.body.segments.last?.nextStartTime)
        }
    }

    func testCheckpointBodyBindsTrueGapPairsAndTailStateExactly() throws {
        let specification = try makeSpecification(index: 24)
        let codec = specification.output.contractID
        let first = try WorkflowSegmentCheckpointV4(
            ordinal: 0,
            artifact: checkpointArtifact(index: 1, kind: .segment),
            startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 600, timescale: 600),
            nextStartTime: WorkflowMediaTimeV4(value: 900, timescale: 600),
            codecSettingsHash: codec,
            isIndependentlyDecodable: true
        )
        let pausedTail = try WorkflowSegmentCheckpointV4(
            ordinal: 1,
            artifact: checkpointArtifact(index: 5, kind: .segment),
            startTime: WorkflowMediaTimeV4(value: 900, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 1_200, timescale: 600),
            nextStartTime: WorkflowMediaTimeV4(value: 1_200, timescale: 600),
            codecSettingsHash: codec,
            isIndependentlyDecodable: true
        )
        XCTAssertNoThrow(try checkpointBody(
            specification: specification,
            segments: [first, pausedTail],
            videoIsComplete: false
        ))

        let mismatched = try WorkflowSegmentCheckpointV4(
            ordinal: 1,
            artifact: checkpointArtifact(index: 5, kind: .segment),
            startTime: WorkflowMediaTimeV4(value: 1_000, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 1_200, timescale: 600),
            nextStartTime: WorkflowMediaTimeV4(value: 1_200, timescale: 600),
            codecSettingsHash: codec,
            isIndependentlyDecodable: true
        )
        XCTAssertThrowsError(try checkpointBody(
            specification: specification,
            segments: [first, mismatched],
            videoIsComplete: false
        )) { error in
            XCTAssertEqual(
                error as? WorkflowDurableCoordinatorErrorV4,
                .invalidCheckpoint
            )
        }
        XCTAssertThrowsError(try WorkflowSegmentCheckpointV4(
            ordinal: 0,
            artifact: checkpointArtifact(index: 1, kind: .segment),
            startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 600, timescale: 600),
            nextStartTime: WorkflowMediaTimeV4(value: 500, timescale: 600),
            codecSettingsHash: codec,
            isIndependentlyDecodable: true
        )) { error in
            XCTAssertEqual(
                error as? WorkflowDurableCoordinatorErrorV4,
                .invalidSegmentBoundary
            )
        }

        let pausedWithoutNext = try WorkflowSegmentCheckpointV4(
            ordinal: 0,
            artifact: checkpointArtifact(index: 1, kind: .segment),
            startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 600, timescale: 600),
            nextStartTime: nil,
            codecSettingsHash: codec,
            isIndependentlyDecodable: true
        )
        XCTAssertThrowsError(try checkpointBody(
            specification: specification,
            segments: [pausedWithoutNext],
            videoIsComplete: false
        ))
        let terminalWithNext = try WorkflowSegmentCheckpointV4(
            ordinal: 0,
            artifact: checkpointArtifact(index: 1, kind: .segment),
            startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
            endTimeExclusive: WorkflowMediaTimeV4(value: 600, timescale: 600),
            nextStartTime: WorkflowMediaTimeV4(value: 600, timescale: 600),
            codecSettingsHash: codec,
            isIndependentlyDecodable: true
        )
        XCTAssertThrowsError(try checkpointBody(
            specification: specification,
            segments: [terminalWithNext],
            videoIsComplete: true
        ))
    }

    func testResealedLegacyGapAndHybridSchemaForgeriesAreRejected()
        async throws {
        let fixture = try makeFixture()
        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.storeURL,
            clock: fixture.clock
        )
        let specification = try makeSpecification(index: 25)
        try await enqueue(specification, into: coordinator, index: 25)
        let codec = specification.output.contractID
        let current = try checkpointBody(
            specification: specification,
            segments: [
                WorkflowSegmentCheckpointV4(
                    ordinal: 0,
                    artifact: checkpointArtifact(index: 1, kind: .segment),
                    startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
                    endTimeExclusive: WorkflowMediaTimeV4(
                        value: 600,
                        timescale: 600
                    ),
                    nextStartTime: WorkflowMediaTimeV4(
                        value: 900,
                        timescale: 600
                    ),
                    codecSettingsHash: codec,
                    isIndependentlyDecodable: true
                ),
                WorkflowSegmentCheckpointV4(
                    ordinal: 1,
                    artifact: checkpointArtifact(index: 5, kind: .segment),
                    startTime: WorkflowMediaTimeV4(value: 900, timescale: 600),
                    endTimeExclusive: WorkflowMediaTimeV4(
                        value: 1_200,
                        timescale: 600
                    ),
                    nextStartTime: WorkflowMediaTimeV4(
                        value: 1_200,
                        timescale: 600
                    ),
                    codecSettingsHash: codec,
                    isIndependentlyDecodable: true
                )
            ],
            videoIsComplete: false
        )
        // Removing the v3 next-boundary field creates a legacy body that has
        // an unprovable gap. Refreshing its hash must not make it migratable.
        let forgedBody = legacyCheckpointBody(
            from: current,
            schemaVersion: 2
        )
        let forged = WorkflowCheckpointDocumentV2(
            bodyHash: try legacyCheckpointBodyHash(forgedBody),
            body: forgedBody
        )
        let directory = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(specification.jobID.rawValue, isDirectory: true)
            .appendingPathComponent("checkpoints-v4", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try WorkflowCanonicalCodec().canonicalData(forged).write(
            to: directory.appendingPathComponent("head-v1.json")
        )

        do {
            _ = try await coordinator.loadCompatibleCheckpoint(
                jobID: specification.jobID,
                expectedCodecSettingsHash: codec
            )
            XCTFail("A resealed legacy gap was inferred without evidence.")
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            XCTAssertEqual(error, .corruptCheckpoint)
        }

        let terminal = try checkpointBody(
            specification: specification,
            segments: [
                WorkflowSegmentCheckpointV4(
                    ordinal: 0,
                    artifact: checkpointArtifact(index: 1, kind: .segment),
                    startTime: WorkflowMediaTimeV4(value: 0, timescale: 600),
                    endTimeExclusive: WorkflowMediaTimeV4(
                        value: 600,
                        timescale: 600
                    ),
                    nextStartTime: nil,
                    codecSettingsHash: codec,
                    isIndependentlyDecodable: true
                )
            ],
            videoIsComplete: true
        )
        let authenticBody1 = legacyCheckpointBody(
            from: terminal,
            schemaVersion: 1
        )
        let hybridBody1 = WorkflowCheckpointBodyV2(
            schemaVersion: 1,
            checkpointID: authenticBody1.checkpointID,
            ordinal: authenticBody1.ordinal,
            previousCheckpointHash: authenticBody1.previousCheckpointHash,
            compatibility: WorkflowCheckpointCompatibilityBindingV4(
                specification: specification,
                sourceSnapshotIdentityID: try WorkflowSourceIdentityID(
                    testDigest(90)
                )
            ),
            attemptID: authenticBody1.attemptID,
            committedAt: authenticBody1.committedAt,
            segments: authenticBody1.segments,
            trackProgress: authenticBody1.trackProgress,
            temporalHistory: authenticBody1.temporalHistory,
            measurementHysteresis: authenticBody1.measurementHysteresis,
            auxiliaryState: authenticBody1.auxiliaryState
        )
        let hybrid = WorkflowCheckpointDocumentV1(
            bodyHash: try legacyCheckpointBodyHash(hybridBody1),
            body: hybridBody1
        )
        try WorkflowCanonicalCodec().canonicalData(hybrid).write(
            to: directory.appendingPathComponent("head-v1.json"),
            options: .atomic
        )
        do {
            _ = try await coordinator.loadCompatibleCheckpoint(
                jobID: specification.jobID,
                expectedCodecSettingsHash: codec
            )
            XCTFail("A resealed hybrid body-schema-1 field was accepted.")
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
            XCTAssertEqual(error, .corruptCheckpoint)
        }
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
        let registryURL = fixture.storeURL
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(
                specification.jobID.rawValue,
                isDirectory: true
            )
            .appendingPathComponent("partial-artifacts-v4.json")
        let currentRegistry = try Data(contentsOf: registryURL)
        try replacingCoordinatorTopLevelSchemaVersion(
            in: currentRegistry,
            from: WorkflowPartialRegistryEnvelopeSchemaV4.current,
            to: WorkflowPartialRegistryEnvelopeSchemaV4.legacy
        ).write(to: registryURL, options: .atomic)
        let migratedRegistry = try await coordinator
            .registeredPartialArtifacts(jobID: specification.jobID)
        XCTAssertEqual(migratedRegistry, [registration])
        XCTAssertEqual(try Data(contentsOf: registryURL), currentRegistry)

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

private enum CheckpointMigrationFaultErrorV4: Error {
    case injected
}

private final class CheckpointMigrationFaultV4: @unchecked Sendable {
    private let lock = NSLock()
    private var targetName: String?
    private var fired = false

    func arm(targetName: String) {
        lock.withLock {
            self.targetName = targetName
            fired = false
        }
    }

    var didFire: Bool { lock.withLock { fired } }

    func hook(_ point: WorkflowFileSystemFaultPoint, _ url: URL) throws {
        let shouldFire = lock.withLock { () -> Bool in
            guard !fired,
                  let targetName,
                  point == .afterPublishParentSync,
                  url.lastPathComponent == targetName else {
                return false
            }
            fired = true
            return true
        }
        if shouldFire { throw CheckpointMigrationFaultErrorV4.injected }
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

    func checkpointBody(
        specification: WorkflowJobSpecification,
        segments: [WorkflowSegmentCheckpointV4],
        videoIsComplete: Bool
    ) throws -> WorkflowCheckpointBodyV4 {
        guard let ordinal = UInt64(exactly: segments.count - 1) else {
            throw WorkflowDurableCoordinatorErrorV4.invalidCheckpoint
        }
        return try WorkflowCheckpointBodyV4(
            checkpointID: WorkflowCheckpointIDV4("checkpoint-body"),
            ordinal: ordinal,
            previousCheckpointHash: ordinal == 0
                ? nil
                : WorkflowCheckpointDocumentHashV4(testDigest(88)),
            compatibility: WorkflowCheckpointCompatibilityBindingV4(
                specification: specification
            ),
            attemptID: WorkflowAttemptID("checkpoint-body-attempt"),
            committedAt: WorkflowWallClockInstantV4(
                nanosecondsSinceUnixEpoch: 1_000_000_000
            ),
            segments: segments,
            trackProgress: [
                WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: 30,
                    nextOutputSampleIndex: 30,
                    lastInputTime: WorkflowMediaTimeV4(
                        value: 580,
                        timescale: 600
                    ),
                    lastOutputTime: WorkflowMediaTimeV4(
                        value: 580,
                        timescale: 600
                    ),
                    isComplete: videoIsComplete
                )
            ],
            temporalHistory: checkpointArtifact(
                index: 2,
                kind: .temporalHistory
            ),
            measurementHysteresis: checkpointArtifact(
                index: 3,
                kind: .measurementHysteresis
            ),
            auxiliaryState: [
                checkpointArtifact(index: 4, kind: .trackState)
            ]
        )
    }

    func legacyCheckpointBody(
        from body: WorkflowCheckpointBodyV4,
        schemaVersion: UInt16
    ) -> WorkflowCheckpointBodyV2 {
        WorkflowCheckpointBodyV2(
            schemaVersion: schemaVersion,
            checkpointID: body.checkpointID,
            ordinal: body.ordinal,
            previousCheckpointHash: body.previousCheckpointHash,
            compatibility: body.compatibility,
            attemptID: body.attemptID,
            committedAt: body.committedAt,
            segments: body.segments.map {
                WorkflowSegmentCheckpointV2(
                    ordinal: $0.ordinal,
                    artifact: $0.artifact,
                    startTime: $0.startTime,
                    endTimeExclusive: $0.endTimeExclusive,
                    codecSettingsHash: $0.codecSettingsHash,
                    isIndependentlyDecodable: $0.isIndependentlyDecodable
                )
            },
            trackProgress: body.trackProgress,
            temporalHistory: body.temporalHistory,
            measurementHysteresis: body.measurementHysteresis,
            auxiliaryState: body.auxiliaryState
        )
    }

    func legacyCheckpointBodyHash(
        _ body: WorkflowCheckpointBodyV2
    ) throws -> WorkflowCheckpointDocumentHashV4 {
        try WorkflowCheckpointDocumentHashV4(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowCheckpointV4\u{0}",
                data: WorkflowCanonicalCodec().canonicalData(body)
            )
        )
    }

    func currentCheckpointBodyHash(
        _ body: WorkflowCheckpointBodyV4
    ) throws -> WorkflowCheckpointDocumentHashV4 {
        try WorkflowCheckpointDocumentHashV4(
            WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowCheckpointV4\u{0}",
                data: WorkflowCanonicalCodec().canonicalData(body)
            )
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

private enum WorkflowCoordinatorSchemaFixtureErrorV4: Error {
    case topLevelSchemaNotFound
}

private func replacingCoordinatorTopLevelSchemaVersion(
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
        throw WorkflowCoordinatorSchemaFixtureErrorV4
            .topLevelSchemaNotFound
    }
    text.replaceSubrange(
        range,
        with: "\"schemaVersion\":\(newVersion)"
    )
    return Data(text.utf8)
}
