import Foundation

enum WorkflowJobLifecycle: String, CaseIterable, Codable, Hashable, Sendable {
    case queued
    case probing
    case planned
    case running
    case pausing
    case paused
    case verifying
    case committing
    case recovering
    case contained
    case completed
    case failed
    case safeHalt
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .safeHalt, .cancelled:
            true
        case .queued, .probing, .planned, .running, .pausing, .paused,
             .verifying, .committing, .recovering, .contained:
            false
        }
    }

    var canDeleteCachedData: Bool {
        switch self {
        case .queued, .paused, .contained, .completed, .failed, .safeHalt,
             .cancelled:
            true
        case .probing, .planned, .running, .pausing, .verifying, .committing,
             .recovering:
            false
        }
    }

    var allowedTransitions: [WorkflowJobLifecycle] {
        switch self {
        case .queued:
            [.probing, .recovering, .failed, .safeHalt, .cancelled]
        case .probing:
            [.queued, .planned, .recovering, .contained, .failed, .safeHalt,
             .cancelled]
        case .planned:
            [.queued, .running, .recovering, .contained, .failed, .safeHalt,
             .cancelled]
        case .running:
            [.pausing, .verifying, .recovering, .contained, .failed, .safeHalt,
             .cancelled]
        case .pausing:
            [.running, .paused, .recovering, .contained, .failed, .safeHalt,
             .cancelled]
        case .paused:
            [.queued, .running, .recovering, .contained, .failed, .safeHalt,
             .cancelled]
        case .verifying:
            [.committing, .recovering, .contained, .failed, .safeHalt,
             .cancelled]
        case .committing:
            [.completed, .recovering, .contained, .failed, .safeHalt]
        case .recovering:
            [.queued, .probing, .planned, .running, .paused, .verifying,
             .committing, .contained, .completed, .failed, .safeHalt,
             .cancelled]
        case .contained:
            [.failed, .safeHalt, .cancelled]
        case .failed:
            [.recovering]
        case .completed, .safeHalt, .cancelled:
            []
        }
    }

    func allowsTransition(to lifecycle: WorkflowJobLifecycle) -> Bool {
        allowedTransitions.contains(lifecycle)
    }
}

struct WorkflowJobState: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let specification: WorkflowJobSpecification
    let lifecycle: WorkflowJobLifecycle
    let activeAttemptID: WorkflowAttemptID?
    let attemptIDs: [WorkflowAttemptID]
    let lastEventSequence: UInt64
    let lastEventHash: WorkflowEventHash

    fileprivate init(
        specification: WorkflowJobSpecification,
        lifecycle: WorkflowJobLifecycle,
        activeAttemptID: WorkflowAttemptID?,
        attemptIDs: [WorkflowAttemptID],
        lastEventSequence: UInt64,
        lastEventHash: WorkflowEventHash
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.specification = specification
        self.lifecycle = lifecycle
        self.activeAttemptID = activeAttemptID
        self.attemptIDs = attemptIDs
        self.lastEventSequence = lastEventSequence
        self.lastEventHash = lastEventHash
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case specification
        case lifecycle
        case activeAttemptID
        case attemptIDs
        case lastEventSequence
        case lastEventHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowJobState",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }

        self.init(
            specification: try container.decode(
                WorkflowJobSpecification.self,
                forKey: .specification
            ),
            lifecycle: try container.decode(
                WorkflowJobLifecycle.self,
                forKey: .lifecycle
            ),
            activeAttemptID: try container.decodeIfPresent(
                WorkflowAttemptID.self,
                forKey: .activeAttemptID
            ),
            attemptIDs: try container.decode(
                [WorkflowAttemptID].self,
                forKey: .attemptIDs
            ),
            lastEventSequence: try container.decode(
                UInt64.self,
                forKey: .lastEventSequence
            ),
            lastEventHash: try container.decode(
                WorkflowEventHash.self,
                forKey: .lastEventHash
            )
        )
    }
}

struct WorkflowAppliedEventReceipt: Codable, Equatable, Sendable {
    let sequence: UInt64
    let eventID: WorkflowEventID
    let commandID: WorkflowCommandID
    let scope: WorkflowEventScope
    let jobBinding: WorkflowJobBinding?
    let attemptID: WorkflowAttemptID?
    let previousEventHash: WorkflowEventHash?
    let payloadHash: WorkflowPayloadHash
    let eventHash: WorkflowEventHash

    fileprivate init(envelope: WorkflowEventEnvelope) {
        sequence = envelope.sequence
        eventID = envelope.eventID
        commandID = envelope.commandID
        scope = envelope.scope
        jobBinding = envelope.jobBinding
        attemptID = envelope.attemptID
        previousEventHash = envelope.previousEventHash
        payloadHash = envelope.payloadHash
        eventHash = envelope.eventHash
    }

    fileprivate func isExactReplay(of envelope: WorkflowEventEnvelope) -> Bool {
        sequence == envelope.sequence
            && eventID == envelope.eventID
            && commandID == envelope.commandID
            && scope == envelope.scope
            && jobBinding == envelope.jobBinding
            && attemptID == envelope.attemptID
            && previousEventHash == envelope.previousEventHash
            && payloadHash == envelope.payloadHash
            && eventHash == envelope.eventHash
    }

    fileprivate func isSameCommand(as envelope: WorkflowEventEnvelope) -> Bool {
        commandID == envelope.commandID
            && scope == envelope.scope
            && jobBinding == envelope.jobBinding
            && attemptID == envelope.attemptID
            && payloadHash == envelope.payloadHash
    }
}

struct WorkflowState: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let jobs: [WorkflowJobID: WorkflowJobState]
    let queueOrder: [WorkflowJobID]
    let appliedEvents: [WorkflowAppliedEventReceipt]
    let lastEventSequence: UInt64?
    let lastEventHash: WorkflowEventHash?
    fileprivate let receiptsByEventID:
        [WorkflowEventID: WorkflowAppliedEventReceipt]
    fileprivate let receiptsByCommandID:
        [WorkflowCommandID: WorkflowAppliedEventReceipt]

    init() {
        schemaVersion = Self.currentSchemaVersion
        jobs = [:]
        queueOrder = []
        appliedEvents = []
        lastEventSequence = nil
        lastEventHash = nil
        receiptsByEventID = [:]
        receiptsByCommandID = [:]
    }

    func job(id: WorkflowJobID) -> WorkflowJobState? {
        jobs[id]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case jobs
        case queueOrder
        case appliedEvents
        case lastEventSequence
        case lastEventHash
    }

    fileprivate init(
        validatingJobs jobs: [WorkflowJobID: WorkflowJobState],
        queueOrder: [WorkflowJobID],
        appliedEvents: [WorkflowAppliedEventReceipt],
        lastEventSequence: UInt64?,
        lastEventHash: WorkflowEventHash?
    ) throws {
        try Self.validate(
            jobs: jobs,
            queueOrder: queueOrder,
            appliedEvents: appliedEvents,
            lastEventSequence: lastEventSequence,
            lastEventHash: lastEventHash
        )
        schemaVersion = Self.currentSchemaVersion
        self.jobs = jobs
        self.queueOrder = queueOrder
        self.appliedEvents = appliedEvents
        self.lastEventSequence = lastEventSequence
        self.lastEventHash = lastEventHash
        receiptsByEventID = Dictionary(
            uniqueKeysWithValues: appliedEvents.map { ($0.eventID, $0) }
        )
        receiptsByCommandID = Dictionary(
            uniqueKeysWithValues: appliedEvents.map { ($0.commandID, $0) }
        )
    }

    fileprivate init(
        reducedJobs jobs: [WorkflowJobID: WorkflowJobState],
        queueOrder: [WorkflowJobID],
        appliedEvents: [WorkflowAppliedEventReceipt],
        lastEventSequence: UInt64,
        lastEventHash: WorkflowEventHash,
        receiptsByEventID: [
            WorkflowEventID: WorkflowAppliedEventReceipt
        ],
        receiptsByCommandID: [
            WorkflowCommandID: WorkflowAppliedEventReceipt
        ]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.jobs = jobs
        self.queueOrder = queueOrder
        self.appliedEvents = appliedEvents
        self.lastEventSequence = lastEventSequence
        self.lastEventHash = lastEventHash
        self.receiptsByEventID = receiptsByEventID
        self.receiptsByCommandID = receiptsByCommandID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowState",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }

        let jobValues = try container.decode(
            [WorkflowJobState].self,
            forKey: .jobs
        )
        var jobs: [WorkflowJobID: WorkflowJobState] = [:]
        for job in jobValues {
            let jobID = job.specification.jobID
            guard jobs[jobID] == nil else {
                throw WorkflowDomainValidationError.invalidSnapshot(
                    "Job \(jobID) appears more than once."
                )
            }
            jobs[jobID] = job
        }

        try self.init(
            validatingJobs: jobs,
            queueOrder: container.decode(
                [WorkflowJobID].self,
                forKey: .queueOrder
            ),
            appliedEvents: container.decode(
                [WorkflowAppliedEventReceipt].self,
                forKey: .appliedEvents
            ),
            lastEventSequence: container.decodeIfPresent(
                UInt64.self,
                forKey: .lastEventSequence
            ),
            lastEventHash: container.decodeIfPresent(
                WorkflowEventHash.self,
                forKey: .lastEventHash
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            jobs.values.sorted {
                $0.specification.jobID < $1.specification.jobID
            },
            forKey: .jobs
        )
        try container.encode(queueOrder, forKey: .queueOrder)
        try container.encode(appliedEvents, forKey: .appliedEvents)
        try container.encodeIfPresent(
            lastEventSequence,
            forKey: .lastEventSequence
        )
        try container.encodeIfPresent(lastEventHash, forKey: .lastEventHash)
    }

    private static func validate(
        jobs: [WorkflowJobID: WorkflowJobState],
        queueOrder: [WorkflowJobID],
        appliedEvents: [WorkflowAppliedEventReceipt],
        lastEventSequence: UInt64?,
        lastEventHash: WorkflowEventHash?
    ) throws {
        guard Set(queueOrder).count == queueOrder.count else {
            throw WorkflowDomainValidationError.invalidSnapshot(
                "Queue order contains a duplicate job ID."
            )
        }

        let queuedJobs = Set(
            jobs.compactMap { jobID, state in
                state.lifecycle == .queued ? jobID : nil
            }
        )
        guard queuedJobs == Set(queueOrder) else {
            throw WorkflowDomainValidationError.invalidSnapshot(
                "Queue membership must exactly equal the jobs in queued state."
            )
        }

        for (jobID, job) in jobs {
            guard jobID == job.specification.jobID else {
                throw WorkflowDomainValidationError.invalidSnapshot(
                    "A job dictionary key does not match its specification."
                )
            }
            guard Set(job.attemptIDs).count == job.attemptIDs.count else {
                throw WorkflowDomainValidationError.invalidSnapshot(
                    "Job \(jobID) contains a duplicate attempt ID."
                )
            }
            if let activeAttemptID = job.activeAttemptID {
                guard
                    job.lifecycle == .running || job.lifecycle == .pausing,
                    job.attemptIDs.contains(activeAttemptID)
                else {
                    throw WorkflowDomainValidationError.invalidSnapshot(
                        "Job \(jobID) has an invalid active attempt."
                    )
                }
            } else if job.lifecycle == .running || job.lifecycle == .pausing {
                throw WorkflowDomainValidationError.invalidSnapshot(
                    "Running and pausing jobs require an active attempt."
                )
            }
        }

        guard Set(appliedEvents.map(\.eventID)).count == appliedEvents.count else {
            throw WorkflowDomainValidationError.invalidSnapshot(
                "Applied event IDs must be unique."
            )
        }
        guard Set(appliedEvents.map(\.commandID)).count == appliedEvents.count else {
            throw WorkflowDomainValidationError.invalidSnapshot(
                "Applied command IDs must be unique."
            )
        }

        if appliedEvents.isEmpty {
            guard lastEventSequence == nil, lastEventHash == nil, jobs.isEmpty else {
                throw WorkflowDomainValidationError.invalidSnapshot(
                    "An empty event history cannot have jobs or a chain head."
                )
            }
            return
        }

        for (offset, receipt) in appliedEvents.enumerated() {
            guard receipt.sequence == UInt64(offset) else {
                throw WorkflowDomainValidationError.invalidSnapshot(
                    "Applied event sequences must be contiguous from zero."
                )
            }
            if offset == 0 {
                guard receipt.previousEventHash == nil else {
                    throw WorkflowDomainValidationError.invalidSnapshot(
                        "The first receipt cannot have a previous hash."
                    )
                }
            } else {
                guard
                    receipt.previousEventHash == appliedEvents[offset - 1].eventHash
                else {
                    throw WorkflowDomainValidationError.invalidSnapshot(
                        "Applied event receipts do not form a hash chain."
                    )
                }
            }
        }

        guard
            lastEventSequence == appliedEvents.last?.sequence,
            lastEventHash == appliedEvents.last?.eventHash
        else {
            throw WorkflowDomainValidationError.invalidSnapshot(
                "The snapshot chain head does not match its final receipt."
            )
        }

        let receiptsBySequence = Dictionary(
            uniqueKeysWithValues: appliedEvents.map { ($0.sequence, $0) }
        )
        for (jobID, job) in jobs {
            guard
                let receipt = receiptsBySequence[job.lastEventSequence],
                receipt.scope == .job(jobID),
                receipt.eventHash == job.lastEventHash
            else {
                throw WorkflowDomainValidationError.invalidSnapshot(
                    "Job \(jobID) does not reference its latest scoped event."
                )
            }
        }
    }
}

enum WorkflowReducerError: Error, Equatable, LocalizedError {
    case duplicateEventIDConflict(WorkflowEventID)
    case duplicateCommandIDConflict(WorkflowCommandID)
    case eventSequenceExhausted
    case unexpectedSequence(expected: UInt64, actual: UInt64)
    case previousEventHashMismatch
    case jobAlreadyExists(WorkflowJobID)
    case jobNotFound(WorkflowJobID)
    case immutableBindingMismatch(WorkflowJobID)
    case jobDeletionNotAllowed(WorkflowJobID, WorkflowJobLifecycle)
    case queueContainsDuplicate(WorkflowJobID)
    case queueMembershipMismatch
    case staleLifecycle(
        jobID: WorkflowJobID,
        expected: WorkflowJobLifecycle,
        actual: WorkflowJobLifecycle
    )
    case illegalTransition(
        jobID: WorkflowJobID,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle
    )
    case terminalStateImmutable(WorkflowJobID, WorkflowJobLifecycle)
    case missingAttemptID(WorkflowJobID)
    case unexpectedAttemptID(WorkflowJobID, WorkflowAttemptID)
    case activeAttemptMismatch(
        jobID: WorkflowJobID,
        expected: WorkflowAttemptID,
        actual: WorkflowAttemptID?
    )
    case attemptAlreadyUsed(WorkflowJobID, WorkflowAttemptID)

    var errorDescription: String? {
        switch self {
        case let .duplicateEventIDConflict(eventID):
            "Event ID \(eventID) was reused with different content."
        case let .duplicateCommandIDConflict(commandID):
            "Command ID \(commandID) was reused with different content."
        case .eventSequenceExhausted:
            "The workflow event sequence is exhausted."
        case let .unexpectedSequence(expected, actual):
            "Expected workflow event sequence \(expected), received \(actual)."
        case .previousEventHashMismatch:
            "The event does not extend the current workflow hash chain."
        case let .jobAlreadyExists(jobID):
            "Job \(jobID) already exists."
        case let .jobNotFound(jobID):
            "Job \(jobID) does not exist."
        case let .immutableBindingMismatch(jobID):
            "Event binding does not match immutable job \(jobID)."
        case let .jobDeletionNotAllowed(jobID, lifecycle):
            "Job \(jobID) cannot be deleted while it is \(lifecycle.rawValue)."
        case let .queueContainsDuplicate(jobID):
            "Queue order contains job \(jobID) more than once."
        case .queueMembershipMismatch:
            "A reorder must contain every queued job exactly once."
        case let .staleLifecycle(jobID, expected, actual):
            "Job \(jobID) transition expected \(expected.rawValue), "
                + "but state is \(actual.rawValue)."
        case let .illegalTransition(jobID, from, to):
            "Job \(jobID) cannot transition from \(from.rawValue) to \(to.rawValue)."
        case let .terminalStateImmutable(jobID, lifecycle):
            "Terminal job \(jobID) in \(lifecycle.rawValue) is immutable."
        case let .missingAttemptID(jobID):
            "Job \(jobID) requires an attempt ID for this transition."
        case let .unexpectedAttemptID(jobID, attemptID):
            "Job \(jobID) cannot use attempt \(attemptID) for this transition."
        case let .activeAttemptMismatch(jobID, expected, actual):
            "Job \(jobID) expected active attempt \(expected), received "
                + "\(String(describing: actual))."
        case let .attemptAlreadyUsed(jobID, attemptID):
            "Job \(jobID) already used attempt \(attemptID)."
        }
    }
}

enum WorkflowReducer {
    static func reduce(
        _ state: WorkflowState,
        applying envelope: WorkflowEventEnvelope
    ) throws -> WorkflowState {
        if let receipt = state.receiptsByEventID[envelope.eventID] {
            guard receipt.isExactReplay(of: envelope) else {
                throw WorkflowReducerError.duplicateEventIDConflict(
                    envelope.eventID
                )
            }
            return state
        }

        if let receipt = state.receiptsByCommandID[envelope.commandID] {
            guard receipt.isSameCommand(as: envelope) else {
                throw WorkflowReducerError.duplicateCommandIDConflict(
                    envelope.commandID
                )
            }
            return state
        }

        let expectedSequence: UInt64
        if let lastEventSequence = state.lastEventSequence {
            guard lastEventSequence < UInt64.max else {
                throw WorkflowReducerError.eventSequenceExhausted
            }
            expectedSequence = lastEventSequence + 1
        } else {
            expectedSequence = 0
        }
        guard envelope.sequence == expectedSequence else {
            throw WorkflowReducerError.unexpectedSequence(
                expected: expectedSequence,
                actual: envelope.sequence
            )
        }
        guard envelope.previousEventHash == state.lastEventHash else {
            throw WorkflowReducerError.previousEventHashMismatch
        }

        var jobs = state.jobs
        var queueOrder = state.queueOrder

        switch envelope.event {
        case let .jobEnqueued(specification):
            let jobID = specification.jobID
            guard jobs[jobID] == nil else {
                throw WorkflowReducerError.jobAlreadyExists(jobID)
            }
            jobs[jobID] = WorkflowJobState(
                specification: specification,
                lifecycle: .queued,
                activeAttemptID: nil,
                attemptIDs: [],
                lastEventSequence: envelope.sequence,
                lastEventHash: envelope.eventHash
            )
            queueOrder.append(jobID)

        case .jobDeleted:
            guard case let .job(jobID) = envelope.scope else {
                preconditionFailure("Envelope validation guarantees job scope.")
            }
            guard let currentJob = jobs[jobID] else {
                throw WorkflowReducerError.jobNotFound(jobID)
            }
            guard envelope.jobBinding == currentJob.specification.binding else {
                throw WorkflowReducerError.immutableBindingMismatch(jobID)
            }
            guard currentJob.lifecycle.canDeleteCachedData else {
                throw WorkflowReducerError.jobDeletionNotAllowed(
                    jobID,
                    currentJob.lifecycle
                )
            }
            jobs.removeValue(forKey: jobID)
            queueOrder.removeAll { $0 == jobID }

        case let .queueReordered(orderedJobIDs):
            var seen: Set<WorkflowJobID> = []
            for jobID in orderedJobIDs {
                guard seen.insert(jobID).inserted else {
                    throw WorkflowReducerError.queueContainsDuplicate(jobID)
                }
            }
            guard seen == Set(queueOrder) else {
                throw WorkflowReducerError.queueMembershipMismatch
            }
            queueOrder = orderedJobIDs

        case let .lifecycleTransition(transition):
            guard case let .job(jobID) = envelope.scope else {
                preconditionFailure("Envelope validation guarantees job scope.")
            }
            guard let currentJob = jobs[jobID] else {
                throw WorkflowReducerError.jobNotFound(jobID)
            }
            guard envelope.jobBinding == currentJob.specification.binding else {
                throw WorkflowReducerError.immutableBindingMismatch(jobID)
            }
            let isFailedCheckpointRecovery =
                currentJob.lifecycle == .failed
                    && transition.to == .recovering
            if currentJob.lifecycle.isTerminal && !isFailedCheckpointRecovery {
                throw WorkflowReducerError.terminalStateImmutable(
                    jobID,
                    currentJob.lifecycle
                )
            }
            guard currentJob.lifecycle == transition.from else {
                throw WorkflowReducerError.staleLifecycle(
                    jobID: jobID,
                    expected: transition.from,
                    actual: currentJob.lifecycle
                )
            }
            guard transition.from.allowsTransition(to: transition.to) else {
                throw WorkflowReducerError.illegalTransition(
                    jobID: jobID,
                    from: transition.from,
                    to: transition.to
                )
            }

            let attempts = try updateAttempts(
                for: currentJob,
                target: transition.to,
                eventAttemptID: envelope.attemptID
            )

            if currentJob.lifecycle == .queued {
                queueOrder.removeAll { $0 == jobID }
            }
            if transition.to == .queued {
                queueOrder.append(jobID)
            }

            jobs[jobID] = WorkflowJobState(
                specification: currentJob.specification,
                lifecycle: transition.to,
                activeAttemptID: attempts.active,
                attemptIDs: attempts.all,
                lastEventSequence: envelope.sequence,
                lastEventHash: envelope.eventHash
            )
        }

        var appliedEvents = state.appliedEvents
        let receipt = WorkflowAppliedEventReceipt(envelope: envelope)
        appliedEvents.append(receipt)
        var receiptsByEventID = state.receiptsByEventID
        receiptsByEventID[envelope.eventID] = receipt
        var receiptsByCommandID = state.receiptsByCommandID
        receiptsByCommandID[envelope.commandID] = receipt
        return WorkflowState(
            reducedJobs: jobs,
            queueOrder: queueOrder,
            appliedEvents: appliedEvents,
            lastEventSequence: envelope.sequence,
            lastEventHash: envelope.eventHash,
            receiptsByEventID: receiptsByEventID,
            receiptsByCommandID: receiptsByCommandID
        )
    }

    private static func updateAttempts(
        for job: WorkflowJobState,
        target: WorkflowJobLifecycle,
        eventAttemptID: WorkflowAttemptID?
    ) throws -> (active: WorkflowAttemptID?, all: [WorkflowAttemptID]) {
        let jobID = job.specification.jobID
        var attemptIDs = job.attemptIDs
        var activeAttemptID = job.activeAttemptID

        if let expectedAttemptID = activeAttemptID {
            guard eventAttemptID == expectedAttemptID else {
                throw WorkflowReducerError.activeAttemptMismatch(
                    jobID: jobID,
                    expected: expectedAttemptID,
                    actual: eventAttemptID
                )
            }
        } else if target == .running {
            guard let eventAttemptID else {
                throw WorkflowReducerError.missingAttemptID(jobID)
            }
            guard !attemptIDs.contains(eventAttemptID) else {
                throw WorkflowReducerError.attemptAlreadyUsed(
                    jobID,
                    eventAttemptID
                )
            }
            attemptIDs.append(eventAttemptID)
            activeAttemptID = eventAttemptID
        } else if let eventAttemptID {
            throw WorkflowReducerError.unexpectedAttemptID(jobID, eventAttemptID)
        }

        if target != .running, target != .pausing {
            activeAttemptID = nil
        }
        return (activeAttemptID, attemptIDs)
    }
}
