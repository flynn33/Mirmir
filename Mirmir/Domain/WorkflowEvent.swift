import Foundation

enum WorkflowEventScope: Equatable, Hashable, Sendable {
    case queue
    case job(WorkflowJobID)
}

extension WorkflowEventScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case jobID
    }

    private enum Kind: String, Codable {
        case queue
        case job
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .queue:
            guard !container.contains(.jobID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .jobID,
                    in: container,
                    debugDescription: "Queue scope cannot carry a job ID."
                )
            }
            self = .queue
        case .job:
            self = .job(
                try container.decode(WorkflowJobID.self, forKey: .jobID)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queue:
            try container.encode(Kind.queue, forKey: .kind)
        case let .job(jobID):
            try container.encode(Kind.job, forKey: .kind)
            try container.encode(jobID, forKey: .jobID)
        }
    }
}

struct WorkflowLifecycleTransition: Codable, Equatable, Hashable, Sendable {
    let from: WorkflowJobLifecycle
    let to: WorkflowJobLifecycle
}

enum WorkflowEvent: Equatable, Hashable, Sendable {
    case jobEnqueued(WorkflowJobSpecification)
    case queueReordered([WorkflowJobID])
    case lifecycleTransition(WorkflowLifecycleTransition)
}

extension WorkflowEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case specification
        case orderedJobIDs
        case transition
    }

    private enum Kind: String, Codable {
        case jobEnqueued
        case queueReordered
        case lifecycleTransition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .jobEnqueued:
            self = .jobEnqueued(
                try container.decode(
                    WorkflowJobSpecification.self,
                    forKey: .specification
                )
            )
        case .queueReordered:
            self = .queueReordered(
                try container.decode(
                    [WorkflowJobID].self,
                    forKey: .orderedJobIDs
                )
            )
        case .lifecycleTransition:
            self = .lifecycleTransition(
                try container.decode(
                    WorkflowLifecycleTransition.self,
                    forKey: .transition
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .jobEnqueued(specification):
            try container.encode(Kind.jobEnqueued, forKey: .kind)
            try container.encode(specification, forKey: .specification)
        case let .queueReordered(orderedJobIDs):
            try container.encode(Kind.queueReordered, forKey: .kind)
            try container.encode(orderedJobIDs, forKey: .orderedJobIDs)
        case let .lifecycleTransition(transition):
            try container.encode(Kind.lifecycleTransition, forKey: .kind)
            try container.encode(transition, forKey: .transition)
        }
    }
}

/// An immutable journal record. The persistence layer is responsible for
/// hashing canonical payload and envelope bytes before constructing this value.
/// The reducer verifies linkage, identity bindings, ordering, and idempotency.
struct WorkflowEventEnvelope: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let sequence: UInt64
    let eventID: WorkflowEventID
    let commandID: WorkflowCommandID
    let scope: WorkflowEventScope
    let jobBinding: WorkflowJobBinding?
    let attemptID: WorkflowAttemptID?
    let previousEventHash: WorkflowEventHash?
    let payloadHash: WorkflowPayloadHash
    let eventHash: WorkflowEventHash
    let event: WorkflowEvent

    init(
        sequence: UInt64,
        eventID: WorkflowEventID,
        commandID: WorkflowCommandID,
        scope: WorkflowEventScope,
        jobBinding: WorkflowJobBinding?,
        attemptID: WorkflowAttemptID?,
        previousEventHash: WorkflowEventHash?,
        payloadHash: WorkflowPayloadHash,
        eventHash: WorkflowEventHash,
        event: WorkflowEvent
    ) throws {
        try Self.validateChainShape(
            sequence: sequence,
            previousEventHash: previousEventHash
        )
        try Self.validateContext(
            scope: scope,
            jobBinding: jobBinding,
            attemptID: attemptID,
            event: event
        )

        schemaVersion = Self.currentSchemaVersion
        self.sequence = sequence
        self.eventID = eventID
        self.commandID = commandID
        self.scope = scope
        self.jobBinding = jobBinding
        self.attemptID = attemptID
        self.previousEventHash = previousEventHash
        self.payloadHash = payloadHash
        self.eventHash = eventHash
        self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sequence
        case eventID
        case commandID
        case scope
        case jobBinding
        case attemptID
        case previousEventHash
        case payloadHash
        case eventHash
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            UInt16.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WorkflowDomainValidationError.unsupportedSchemaVersion(
                type: "WorkflowEventEnvelope",
                actual: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }

        try self.init(
            sequence: container.decode(UInt64.self, forKey: .sequence),
            eventID: container.decode(WorkflowEventID.self, forKey: .eventID),
            commandID: container.decode(
                WorkflowCommandID.self,
                forKey: .commandID
            ),
            scope: container.decode(WorkflowEventScope.self, forKey: .scope),
            jobBinding: container.decodeIfPresent(
                WorkflowJobBinding.self,
                forKey: .jobBinding
            ),
            attemptID: container.decodeIfPresent(
                WorkflowAttemptID.self,
                forKey: .attemptID
            ),
            previousEventHash: container.decodeIfPresent(
                WorkflowEventHash.self,
                forKey: .previousEventHash
            ),
            payloadHash: container.decode(
                WorkflowPayloadHash.self,
                forKey: .payloadHash
            ),
            eventHash: container.decode(
                WorkflowEventHash.self,
                forKey: .eventHash
            ),
            event: container.decode(WorkflowEvent.self, forKey: .event)
        )
    }

    private static func validateChainShape(
        sequence: UInt64,
        previousEventHash: WorkflowEventHash?
    ) throws {
        if sequence == 0, previousEventHash == nil {
            return
        }
        if sequence > 0, previousEventHash != nil {
            return
        }
        if sequence == 0 {
            throw WorkflowDomainValidationError.invalidEventEnvelope(
                "The first event cannot name a previous hash."
            )
        }
        throw WorkflowDomainValidationError.invalidEventEnvelope(
            "Every event after sequence zero must name a previous hash."
        )
    }

    private static func validateContext(
        scope: WorkflowEventScope,
        jobBinding: WorkflowJobBinding?,
        attemptID: WorkflowAttemptID?,
        event: WorkflowEvent
    ) throws {
        switch event {
        case let .jobEnqueued(specification):
            guard scope == .job(specification.jobID) else {
                throw WorkflowDomainValidationError.invalidEventEnvelope(
                    "An enqueue event must be scoped to its specification job."
                )
            }
            guard jobBinding == specification.binding else {
                throw WorkflowDomainValidationError.invalidEventEnvelope(
                    "An enqueue event must carry its immutable job binding."
                )
            }
            guard attemptID == nil else {
                throw WorkflowDomainValidationError.invalidEventEnvelope(
                    "An enqueue event cannot carry an attempt ID."
                )
            }

        case .queueReordered:
            guard scope == .queue else {
                throw WorkflowDomainValidationError.invalidEventEnvelope(
                    "A queue reorder event must use queue scope."
                )
            }
            guard jobBinding == nil, attemptID == nil else {
                throw WorkflowDomainValidationError.invalidEventEnvelope(
                    "A queue reorder event cannot carry job or attempt context."
                )
            }

        case .lifecycleTransition:
            guard case let .job(jobID) = scope else {
                throw WorkflowDomainValidationError.invalidEventEnvelope(
                    "A lifecycle transition must use job scope."
                )
            }
            guard let jobBinding, jobBinding.jobID == jobID else {
                throw WorkflowDomainValidationError.invalidEventEnvelope(
                    "A lifecycle transition must carry a matching job binding."
                )
            }
        }
    }
}
