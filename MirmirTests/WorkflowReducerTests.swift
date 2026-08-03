import Foundation
import XCTest
@testable import Mirmir

final class WorkflowReducerTests: XCTestCase {
    func testValidatedIdentifiersAndDigestsRejectNoncanonicalValues() throws {
        XCTAssertThrowsError(try WorkflowJobID("../job"))
        XCTAssertThrowsError(try WorkflowJobID("-job"))
        XCTAssertThrowsError(try WorkflowEventHash(String(repeating: "A", count: 64)))
        XCTAssertThrowsError(try WorkflowEventHash("abc"))
        XCTAssertThrowsError(
            try WorkflowBookmarkReference(
                bookmarkID: WorkflowBookmarkID("bookmark"),
                revision: 0,
                documentHash: digest(1)
            )
        )

        XCTAssertEqual(try WorkflowJobID("job-1").rawValue, "job-1")
        XCTAssertEqual(try WorkflowEventHash(hex: 42).rawValue.count, 64)
    }

    func testLifecycleTransitionTableCoversEveryStateExactly() {
        let expected: [WorkflowJobLifecycle: Set<WorkflowJobLifecycle>] = [
            .queued: [.probing, .recovering, .failed, .safeHalt, .cancelled],
            .probing: [
                .queued, .planned, .recovering, .contained, .failed, .safeHalt,
                .cancelled
            ],
            .planned: [
                .queued, .running, .recovering, .contained, .failed, .safeHalt,
                .cancelled
            ],
            .running: [
                .pausing, .verifying, .recovering, .contained, .failed, .safeHalt,
                .cancelled
            ],
            .pausing: [
                .running, .paused, .recovering, .contained, .failed, .safeHalt,
                .cancelled
            ],
            .paused: [
                .queued, .running, .recovering, .contained, .failed, .safeHalt,
                .cancelled
            ],
            .verifying: [
                .committing, .recovering, .contained, .failed, .safeHalt,
                .cancelled
            ],
            .committing: [
                .completed, .recovering, .contained, .failed, .safeHalt
            ],
            .recovering: [
                .queued, .probing, .planned, .running, .paused, .verifying,
                .committing, .contained, .failed, .safeHalt, .cancelled
            ],
            .contained: [.failed, .safeHalt, .cancelled],
            .completed: [],
            .failed: [],
            .safeHalt: [],
            .cancelled: []
        ]

        XCTAssertEqual(Set(expected.keys), Set(WorkflowJobLifecycle.allCases))
        for lifecycle in WorkflowJobLifecycle.allCases {
            XCTAssertEqual(
                Set(lifecycle.allowedTransitions),
                expected[lifecycle],
                "Unexpected transition table for \(lifecycle.rawValue)"
            )
        }
        XCTAssertEqual(
            Set(WorkflowJobLifecycle.allCases.filter(\.isTerminal)),
            [.completed, .failed, .safeHalt, .cancelled]
        )
    }

    func testEnqueueCreatesImmutableQueuedJobAndAdvancesChain() throws {
        let specification = try makeSpecification(index: 1)
        let initial = WorkflowState()
        let envelope = try makeEnvelope(
            state: initial,
            event: .jobEnqueued(specification),
            specification: specification
        )

        let state = try WorkflowReducer.reduce(initial, applying: envelope)

        XCTAssertEqual(state.queueOrder, [specification.jobID])
        XCTAssertEqual(state.job(id: specification.jobID)?.lifecycle, .queued)
        XCTAssertEqual(
            state.job(id: specification.jobID)?.specification,
            specification
        )
        XCTAssertEqual(state.lastEventSequence, 0)
        XCTAssertEqual(state.lastEventHash, envelope.eventHash)
        XCTAssertEqual(state.appliedEvents.count, 1)
    }

    func testQueueReorderRequiresEveryQueuedJobExactlyOnce() throws {
        let specifications = try (1 ... 3).map(makeSpecification(index:))
        var state = WorkflowState()
        for (offset, specification) in specifications.enumerated() {
            state = try apply(
                .jobEnqueued(specification),
                specification: specification,
                to: state,
                salt: UInt64(offset)
            )
        }

        let reordered = specifications.map(\.jobID).reversed()
        state = try apply(
            .queueReordered(Array(reordered)),
            specification: nil,
            to: state
        )
        XCTAssertEqual(state.queueOrder, Array(reordered))

        let missingJob = try makeEnvelope(
            state: state,
            event: .queueReordered(Array(reordered.dropLast())),
            specification: nil,
            salt: 10
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: missingJob)
        ) { error in
            XCTAssertEqual(error as? WorkflowReducerError, .queueMembershipMismatch)
        }

        let duplicateID = specifications[0].jobID
        let duplicate = try makeEnvelope(
            state: state,
            event: .queueReordered([duplicateID, duplicateID]),
            specification: nil,
            salt: 11
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: duplicate)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .queueContainsDuplicate(duplicateID)
            )
        }
    }

    func testLeavingQueueRemovesJobAndRequeueAppendsAtTail() throws {
        let first = try makeSpecification(index: 1)
        let second = try makeSpecification(index: 2)
        var state = WorkflowState()
        state = try apply(.jobEnqueued(first), specification: first, to: state)
        state = try apply(.jobEnqueued(second), specification: second, to: state)

        state = try transition(
            first,
            from: .queued,
            to: .probing,
            state: state
        )
        XCTAssertEqual(state.queueOrder, [second.jobID])

        state = try transition(
            first,
            from: .probing,
            to: .queued,
            state: state
        )
        XCTAssertEqual(state.queueOrder, [second.jobID, first.jobID])
    }

    func testPauseResumeFlowUsesNewAttemptAndReachesImmutableTerminalState() throws {
        let specification = try makeSpecification(index: 1)
        let firstAttempt = try WorkflowAttemptID("attempt-1")
        let resumedAttempt = try WorkflowAttemptID("attempt-2")
        var state = WorkflowState()
        state = try apply(
            .jobEnqueued(specification),
            specification: specification,
            to: state
        )
        state = try transition(
            specification,
            from: .queued,
            to: .probing,
            state: state
        )
        state = try transition(
            specification,
            from: .probing,
            to: .planned,
            state: state
        )
        state = try transition(
            specification,
            from: .planned,
            to: .running,
            attemptID: firstAttempt,
            state: state
        )
        state = try transition(
            specification,
            from: .running,
            to: .pausing,
            attemptID: firstAttempt,
            state: state
        )
        state = try transition(
            specification,
            from: .pausing,
            to: .paused,
            attemptID: firstAttempt,
            state: state
        )
        state = try transition(
            specification,
            from: .paused,
            to: .running,
            attemptID: resumedAttempt,
            state: state
        )
        state = try transition(
            specification,
            from: .running,
            to: .verifying,
            attemptID: resumedAttempt,
            state: state
        )
        state = try transition(
            specification,
            from: .verifying,
            to: .committing,
            state: state
        )
        state = try transition(
            specification,
            from: .committing,
            to: .completed,
            state: state
        )

        let completed = try XCTUnwrap(state.job(id: specification.jobID))
        XCTAssertEqual(completed.lifecycle, .completed)
        XCTAssertEqual(completed.attemptIDs, [firstAttempt, resumedAttempt])
        XCTAssertNil(completed.activeAttemptID)
        XCTAssertTrue(state.queueOrder.isEmpty)

        let mutation = try makeTransitionEnvelope(
            specification,
            from: .completed,
            to: .recovering,
            state: state
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: mutation)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .terminalStateImmutable(specification.jobID, .completed)
            )
        }
    }

    func testAttemptRulesRejectMissingMismatchedAndReusedAttempts() throws {
        let specification = try makeSpecification(index: 1)
        let attempt = try WorkflowAttemptID("attempt-1")
        let otherAttempt = try WorkflowAttemptID("attempt-2")
        var state = try statePlannedFor(specification)

        let missing = try makeTransitionEnvelope(
            specification,
            from: .planned,
            to: .running,
            state: state
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: missing)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .missingAttemptID(specification.jobID)
            )
        }

        state = try transition(
            specification,
            from: .planned,
            to: .running,
            attemptID: attempt,
            state: state
        )
        let mismatched = try makeTransitionEnvelope(
            specification,
            from: .running,
            to: .pausing,
            attemptID: otherAttempt,
            state: state
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: mismatched)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .activeAttemptMismatch(
                    jobID: specification.jobID,
                    expected: attempt,
                    actual: otherAttempt
                )
            )
        }

        state = try transition(
            specification,
            from: .running,
            to: .pausing,
            attemptID: attempt,
            state: state
        )
        state = try transition(
            specification,
            from: .pausing,
            to: .paused,
            attemptID: attempt,
            state: state
        )
        let reused = try makeTransitionEnvelope(
            specification,
            from: .paused,
            to: .running,
            attemptID: attempt,
            state: state
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: reused)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .attemptAlreadyUsed(specification.jobID, attempt)
            )
        }
    }

    func testIllegalAndStaleLifecycleTransitionsFailClosed() throws {
        let specification = try makeSpecification(index: 1)
        var state = WorkflowState()
        state = try apply(
            .jobEnqueued(specification),
            specification: specification,
            to: state
        )

        let illegal = try makeTransitionEnvelope(
            specification,
            from: .queued,
            to: .running,
            attemptID: WorkflowAttemptID("attempt-1"),
            state: state
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: illegal)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .illegalTransition(
                    jobID: specification.jobID,
                    from: .queued,
                    to: .running
                )
            )
        }

        let stale = try makeTransitionEnvelope(
            specification,
            from: .probing,
            to: .planned,
            state: state,
            salt: 1
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: stale)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .staleLifecycle(
                    jobID: specification.jobID,
                    expected: .probing,
                    actual: .queued
                )
            )
        }
    }

    func testEventAndCommandIdempotencyAreDeterministic() throws {
        let specification = try makeSpecification(index: 1)
        let initial = WorkflowState()
        let enqueue = try makeEnvelope(
            state: initial,
            event: .jobEnqueued(specification),
            specification: specification
        )
        let state = try WorkflowReducer.reduce(initial, applying: enqueue)

        XCTAssertEqual(
            try WorkflowReducer.reduce(state, applying: enqueue),
            state,
            "An exact replay must be a no-op."
        )

        let commandReplay = try WorkflowEventEnvelope(
            sequence: 1,
            eventID: WorkflowEventID("event-command-replay"),
            commandID: enqueue.commandID,
            scope: enqueue.scope,
            jobBinding: enqueue.jobBinding,
            attemptID: nil,
            previousEventHash: state.lastEventHash,
            payloadHash: enqueue.payloadHash,
            eventHash: WorkflowEventHash(hex: 900),
            event: enqueue.event
        )
        XCTAssertEqual(
            try WorkflowReducer.reduce(state, applying: commandReplay),
            state,
            "The same command and payload must not append another event."
        )

        let eventConflict = try WorkflowEventEnvelope(
            sequence: 1,
            eventID: enqueue.eventID,
            commandID: WorkflowCommandID("command-conflict-event"),
            scope: .queue,
            jobBinding: nil,
            attemptID: nil,
            previousEventHash: state.lastEventHash,
            payloadHash: WorkflowPayloadHash(hex: 901),
            eventHash: WorkflowEventHash(hex: 902),
            event: .queueReordered(state.queueOrder)
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: eventConflict)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .duplicateEventIDConflict(enqueue.eventID)
            )
        }

        let commandConflict = try WorkflowEventEnvelope(
            sequence: 1,
            eventID: WorkflowEventID("event-conflict-command"),
            commandID: enqueue.commandID,
            scope: .queue,
            jobBinding: nil,
            attemptID: nil,
            previousEventHash: state.lastEventHash,
            payloadHash: WorkflowPayloadHash(hex: 903),
            eventHash: WorkflowEventHash(hex: 904),
            event: .queueReordered(state.queueOrder)
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: commandConflict)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .duplicateCommandIDConflict(enqueue.commandID)
            )
        }
    }

    func testReducerRejectsSequenceAndPreviousHashDiscontinuities() throws {
        let specification = try makeSpecification(index: 1)
        var state = WorkflowState()
        state = try apply(
            .jobEnqueued(specification),
            specification: specification,
            to: state
        )

        let skippedSequence = try WorkflowEventEnvelope(
            sequence: 2,
            eventID: WorkflowEventID("event-skipped"),
            commandID: WorkflowCommandID("command-skipped"),
            scope: .queue,
            jobBinding: nil,
            attemptID: nil,
            previousEventHash: state.lastEventHash,
            payloadHash: WorkflowPayloadHash(hex: 300),
            eventHash: WorkflowEventHash(hex: 301),
            event: .queueReordered(state.queueOrder)
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: skippedSequence)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .unexpectedSequence(expected: 1, actual: 2)
            )
        }

        let wrongPrevious = try WorkflowEventEnvelope(
            sequence: 1,
            eventID: WorkflowEventID("event-wrong-previous"),
            commandID: WorkflowCommandID("command-wrong-previous"),
            scope: .queue,
            jobBinding: nil,
            attemptID: nil,
            previousEventHash: WorkflowEventHash(hex: 302),
            payloadHash: WorkflowPayloadHash(hex: 303),
            eventHash: WorkflowEventHash(hex: 304),
            event: .queueReordered(state.queueOrder)
        )
        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: wrongPrevious)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .previousEventHashMismatch
            )
        }
    }

    func testLifecycleEventCannotChangeImmutableBinding() throws {
        let specification = try makeSpecification(index: 1)
        let other = try makeSpecification(index: 2)
        var state = WorkflowState()
        state = try apply(
            .jobEnqueued(specification),
            specification: specification,
            to: state
        )
        let mismatchedBinding = WorkflowJobBinding(
            jobID: specification.jobID,
            requestID: other.requestID,
            sourceIdentityID: other.source.identityID,
            outputContractID: other.output.contractID,
            planID: other.runtimeBinding.planID,
            runtimeBindingID: other.runtimeBinding.id
        )
        let event = try WorkflowEventEnvelope(
            sequence: 1,
            eventID: WorkflowEventID("event-binding-mismatch"),
            commandID: WorkflowCommandID("command-binding-mismatch"),
            scope: .job(specification.jobID),
            jobBinding: mismatchedBinding,
            attemptID: nil,
            previousEventHash: state.lastEventHash,
            payloadHash: WorkflowPayloadHash(hex: 400),
            eventHash: WorkflowEventHash(hex: 401),
            event: .lifecycleTransition(
                WorkflowLifecycleTransition(from: .queued, to: .probing)
            )
        )

        XCTAssertThrowsError(
            try WorkflowReducer.reduce(state, applying: event)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowReducerError,
                .immutableBindingMismatch(specification.jobID)
            )
        }
    }

    func testCodableRoundTripsUseExplicitSchemaVersions() throws {
        let specifications = try (1 ... 2).map(makeSpecification(index:))
        var state = WorkflowState()
        var firstEnvelope: WorkflowEventEnvelope?
        for specification in specifications {
            let envelope = try makeEnvelope(
                state: state,
                event: .jobEnqueued(specification),
                specification: specification
            )
            firstEnvelope = firstEnvelope ?? envelope
            state = try WorkflowReducer.reduce(state, applying: envelope)
        }
        state = try apply(
            .queueReordered(specifications.map(\.jobID).reversed()),
            specification: nil,
            to: state
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let stateData = try encoder.encode(state)
        let eventData = try encoder.encode(XCTUnwrap(firstEnvelope))

        XCTAssertEqual(try decoder.decode(WorkflowState.self, from: stateData), state)
        XCTAssertEqual(
            try decoder.decode(WorkflowEventEnvelope.self, from: eventData),
            firstEnvelope
        )
        XCTAssertEqual(stateData, try encoder.encode(state))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: stateData) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try decoder.decode(WorkflowState.self, from: futureData)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowDomainValidationError,
                .unsupportedSchemaVersion(
                    type: "WorkflowState",
                    actual: 99,
                    current: WorkflowState.currentSchemaVersion
                )
            )
        }
    }

    func testSnapshotDecodeRejectsQueueProjectionDrift() throws {
        let first = try makeSpecification(index: 1)
        let second = try makeSpecification(index: 2)
        var state = WorkflowState()
        state = try apply(.jobEnqueued(first), specification: first, to: state)
        state = try apply(.jobEnqueued(second), specification: second, to: state)

        let encoder = JSONEncoder()
        let data = try encoder.encode(state)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["queueOrder"] = [first.jobID.rawValue, first.jobID.rawValue]
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(WorkflowState.self, from: corrupted)
        ) { error in
            XCTAssertEqual(
                error as? WorkflowDomainValidationError,
                .invalidSnapshot("Queue order contains a duplicate job ID.")
            )
        }
    }
}

private extension WorkflowReducerTests {
    func statePlannedFor(
        _ specification: WorkflowJobSpecification
    ) throws -> WorkflowState {
        var state = WorkflowState()
        state = try apply(
            .jobEnqueued(specification),
            specification: specification,
            to: state
        )
        state = try transition(
            specification,
            from: .queued,
            to: .probing,
            state: state
        )
        return try transition(
            specification,
            from: .probing,
            to: .planned,
            state: state
        )
    }

    func transition(
        _ specification: WorkflowJobSpecification,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle,
        attemptID: WorkflowAttemptID? = nil,
        state: WorkflowState,
        salt: UInt64 = 0
    ) throws -> WorkflowState {
        try WorkflowReducer.reduce(
            state,
            applying: makeTransitionEnvelope(
                specification,
                from: from,
                to: to,
                attemptID: attemptID,
                state: state,
                salt: salt
            )
        )
    }

    func makeTransitionEnvelope(
        _ specification: WorkflowJobSpecification,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle,
        attemptID: WorkflowAttemptID? = nil,
        state: WorkflowState,
        salt: UInt64 = 0
    ) throws -> WorkflowEventEnvelope {
        try makeEnvelope(
            state: state,
            event: .lifecycleTransition(
                WorkflowLifecycleTransition(from: from, to: to)
            ),
            specification: specification,
            attemptID: attemptID,
            salt: salt
        )
    }

    func apply(
        _ event: WorkflowEvent,
        specification: WorkflowJobSpecification?,
        to state: WorkflowState,
        salt: UInt64 = 0
    ) throws -> WorkflowState {
        try WorkflowReducer.reduce(
            state,
            applying: makeEnvelope(
                state: state,
                event: event,
                specification: specification,
                salt: salt
            )
        )
    }

    func makeEnvelope(
        state: WorkflowState,
        event: WorkflowEvent,
        specification: WorkflowJobSpecification?,
        attemptID: WorkflowAttemptID? = nil,
        salt: UInt64 = 0
    ) throws -> WorkflowEventEnvelope {
        let sequence = (state.lastEventSequence ?? UInt64.max) &+ 1
        let discriminator = sequence &* 100 &+ salt
        let context: (
            scope: WorkflowEventScope,
            binding: WorkflowJobBinding?
        )
        switch event {
        case let .jobEnqueued(enqueued):
            context = (.job(enqueued.jobID), enqueued.binding)
        case .queueReordered:
            context = (.queue, nil)
        case .lifecycleTransition:
            let specification = try XCTUnwrap(specification)
            context = (.job(specification.jobID), specification.binding)
        }

        return try WorkflowEventEnvelope(
            sequence: sequence,
            eventID: WorkflowEventID("event-\(discriminator)"),
            commandID: WorkflowCommandID("command-\(discriminator)"),
            scope: context.scope,
            jobBinding: context.binding,
            attemptID: attemptID,
            previousEventHash: state.lastEventHash,
            payloadHash: WorkflowPayloadHash(hex: 10_000 &+ discriminator),
            eventHash: WorkflowEventHash(hex: 20_000 &+ discriminator),
            event: event
        )
    }

    func makeSpecification(index: Int) throws -> WorkflowJobSpecification {
        let seed = UInt64(index) * 100
        let sourceBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("source-bookmark-\(index)"),
            revision: 1,
            documentHash: digest(seed + 1)
        )
        let outputBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("output-bookmark-\(index)"),
            revision: 1,
            documentHash: digest(seed + 2)
        )
        let runtime = WorkflowRuntimeBinding(
            id: try digest(seed + 3),
            runtimeManifestID: try digest(seed + 4),
            planID: try digest(seed + 5),
            backendID: try WorkflowBackendID("deterministic-v4"),
            backendRevisionID: try WorkflowBackendRevisionID("revision-1"),
            mediaContractID: try digest(seed + 6)
        )
        return WorkflowJobSpecification(
            jobID: try WorkflowJobID("job-\(index)"),
            requestID: try digest(seed + 7),
            source: WorkflowSourceSpecification(
                identityID: try digest(seed + 8),
                bookmark: sourceBookmark
            ),
            output: WorkflowOutputSpecification(
                contractID: try digest(seed + 9),
                directoryBookmark: outputBookmark,
                fileName: try WorkflowOutputFileName("output-\(index).mov")
            ),
            runtimeBinding: runtime
        )
    }
}

private extension WorkflowDigest {
    init(hex value: UInt64) throws {
        let suffix = String(value, radix: 16)
        try self.init(String(repeating: "0", count: 64 - suffix.count) + suffix)
    }
}

private func digest<Purpose: WorkflowDigestPurpose>(
    _ value: UInt64
) throws -> WorkflowDigest<Purpose> {
    try WorkflowDigest(hex: value)
}
