import Foundation

// MARK: - Deterministic queue dispatch

enum WorkflowDispatchCycleIDPurposeV4: WorkflowIdentifierPurpose {}
enum WorkflowRecoveryCommandKeyPurposeV4: WorkflowIdentifierPurpose {}
enum WorkflowRecoveryDecisionDigestPurposeV4: WorkflowDigestPurpose {}
enum WorkflowRecoveryPreparedDecisionDigestPurposeV4: WorkflowDigestPurpose {}
enum WorkflowDispatcherConfigurationDigestPurposeV4: WorkflowDigestPurpose {}

typealias WorkflowDispatchCycleIDV4 =
  WorkflowIdentifier<WorkflowDispatchCycleIDPurposeV4>
typealias WorkflowRecoveryCommandKeyV4 =
  WorkflowIdentifier<WorkflowRecoveryCommandKeyPurposeV4>
typealias WorkflowRecoveryDecisionHashV4 =
  WorkflowDigest<WorkflowRecoveryDecisionDigestPurposeV4>
typealias WorkflowRecoveryPreparedDecisionHashV4 =
  WorkflowDigest<WorkflowRecoveryPreparedDecisionDigestPurposeV4>
typealias WorkflowDispatcherConfigurationHashV4 =
  WorkflowDigest<WorkflowDispatcherConfigurationDigestPurposeV4>

enum WorkflowQueueDispatcherEnvelopeSchemaV4 {
  static let legacy: UInt16 = 1
  static let current: UInt16 = 2
}

private struct WorkflowDispatcherConfigurationBodyV4:
  Codable,
  Equatable,
  Sendable
{
  static let currentSchemaVersion: UInt16 = 1

  let schemaVersion: UInt16
  let maximumConcurrentJobs: Int

  init(maximumConcurrentJobs: Int) {
    schemaVersion = Self.currentSchemaVersion
    self.maximumConcurrentJobs = maximumConcurrentJobs
  }
}

private struct WorkflowDispatcherConfigurationDocumentV4:
  Codable,
  Equatable,
  Sendable
{
  static let currentSchemaVersion =
    WorkflowQueueDispatcherEnvelopeSchemaV4.current

  let schemaVersion: UInt16
  let bodyHash: WorkflowDispatcherConfigurationHashV4
  let body: WorkflowDispatcherConfigurationBodyV4

  init(
    bodyHash: WorkflowDispatcherConfigurationHashV4,
    body: WorkflowDispatcherConfigurationBodyV4
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.bodyHash = bodyHash
    self.body = body
  }
}

private struct WorkflowDispatcherConfigurationDocumentV1:
  Codable,
  Equatable,
  Sendable
{
  static let schemaVersionValue =
    WorkflowQueueDispatcherEnvelopeSchemaV4.legacy

  let schemaVersion: UInt16
  let bodyHash: WorkflowDispatcherConfigurationHashV4
  let body: WorkflowDispatcherConfigurationBodyV4

  init(
    bodyHash: WorkflowDispatcherConfigurationHashV4,
    body: WorkflowDispatcherConfigurationBodyV4
  ) {
    schemaVersion = Self.schemaVersionValue
    self.bodyHash = bodyHash
    self.body = body
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case bodyHash
    case body
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(
      UInt16.self,
      forKey: .schemaVersion
    )
    guard schemaVersion == Self.schemaVersionValue else {
      throw WorkflowQueueDispatcherErrorV4.unsupportedConfigurationSchema(
        actual: schemaVersion,
        current: WorkflowDispatcherConfigurationDocumentV4
          .currentSchemaVersion
      )
    }
    self.init(
      bodyHash: try container.decode(
        WorkflowDispatcherConfigurationHashV4.self,
        forKey: .bodyHash
      ),
      body: try container.decode(
        WorkflowDispatcherConfigurationBodyV4.self,
        forKey: .body
      )
    )
  }
}

struct WorkflowQueuePriorityV4: Equatable, Hashable, Sendable {
  static let minimum: Int32 = -1_000_000
  static let maximum: Int32 = 1_000_000

  let jobID: WorkflowJobID
  let value: Int32

  init(jobID: WorkflowJobID, value: Int32) throws {
    guard value >= Self.minimum, value <= Self.maximum else {
      throw WorkflowQueueDispatcherErrorV4.invalidPriority(value)
    }
    self.jobID = jobID
    self.value = value
  }
}

struct WorkflowQueueDispatchReceiptV4: Equatable, Sendable {
  let claim: WorkflowDispatchClaimV4
  let slot: Int
  let priority: Int32
  let queueOrdinal: Int
  let acquisitionReceipt: WorkflowAppliedEventReceipt
  let preparationReceipts: [WorkflowAppliedEventReceipt]
}

enum WorkflowQueueDispatchResultV4: Equatable, Sendable {
  case claimed(WorkflowQueueDispatchReceiptV4)
  case noEligibleJob
  case capacityExhausted
}

enum WorkflowRecoveryClaimResultV4: Equatable, Sendable {
  case claimed(WorkflowQueueDispatchReceiptV4)
  case deferred(WorkflowLeaseInspectionV4)
  case terminal(WorkflowJobLifecycle)
  case contained
}

struct WorkflowQueueTransitionReceiptV4: Equatable, Sendable {
  let claim: WorkflowDispatchClaimV4
  let reducerReceipt: WorkflowAppliedEventReceipt
  let lifecycle: WorkflowJobLifecycle
}

enum WorkflowQueueDispatcherErrorV4: Error, Equatable, LocalizedError {
  case invalidConcurrency(Int)
  case invalidPriority(Int32)
  case duplicatePriority(WorkflowJobID)
  case claimNotOwned(WorkflowLeaseIDV4)
  case missingAcquisitionReceipt(WorkflowCommandID)
  case noDispatchCapacity
  case corruptConfiguration
  case unsupportedConfigurationSchema(actual: UInt16, current: UInt16)
  case concurrencyConfigurationMismatch(expected: Int, actual: Int)
  case cycleReplayConflict(WorkflowDispatchCycleIDV4)
  case staleClaimLifecycle(
    expected: WorkflowJobLifecycle,
    actual: WorkflowJobLifecycle
  )
  case unsupportedRecoveryLifecycle(WorkflowJobLifecycle)

  var errorDescription: String? {
    switch self {
    case .invalidConcurrency(let value):
      "Dispatcher concurrency must be between 1 and 64; got \(value)."
    case .invalidPriority(let value):
      "Queue priority \(value) is outside the supported range."
    case .duplicatePriority(let jobID):
      "Queue priority for \(jobID) was supplied more than once."
    case .claimNotOwned(let leaseID):
      "This dispatcher does not own lease \(leaseID)."
    case .missingAcquisitionReceipt(let commandID):
      "The reducer receipt for acquisition command \(commandID) is missing."
    case .noDispatchCapacity:
      "No global dispatcher slot is available."
    case .corruptConfiguration:
      "The global dispatcher configuration is noncanonical or hash-invalid."
    case let .unsupportedConfigurationSchema(actual, current):
      "Dispatcher configuration schema \(actual) is unsupported; current is \(current)."
    case .concurrencyConfigurationMismatch(let expected, let actual):
      "Dispatcher concurrency is durably locked to \(expected), not \(actual)."
    case .cycleReplayConflict(let cycleID):
      "Dispatch cycle \(cycleID) was replayed with different priorities."
    case .staleClaimLifecycle(let expected, let actual):
      "Claim lifecycle is \(actual.rawValue), expected \(expected.rawValue)."
    case .unsupportedRecoveryLifecycle(let lifecycle):
      "Lifecycle \(lifecycle.rawValue) cannot enter launch recovery."
    }
  }
}

actor WorkflowQueueDispatcherV4 {
  private struct CycleRecord: Sendable {
    let priorities: [WorkflowQueuePriorityV4]
    let receipt: WorkflowQueueDispatchReceiptV4
  }

  private final class HeldDispatch: @unchecked Sendable {
    let slot: Int
    let slotLease: WorkflowExclusiveFileLease
    let priority: Int32
    let queueOrdinal: Int
    let acquisitionReceipt: WorkflowAppliedEventReceipt
    var preparationReceipts: [WorkflowAppliedEventReceipt]
    var claim: WorkflowDispatchClaimV4

    init(
      slot: Int,
      slotLease: WorkflowExclusiveFileLease,
      priority: Int32,
      queueOrdinal: Int,
      acquisitionReceipt: WorkflowAppliedEventReceipt,
      preparationReceipts: [WorkflowAppliedEventReceipt] = [],
      claim: WorkflowDispatchClaimV4
    ) {
      self.slot = slot
      self.slotLease = slotLease
      self.priority = priority
      self.queueOrdinal = queueOrdinal
      self.acquisitionReceipt = acquisitionReceipt
      self.preparationReceipts = preparationReceipts
      self.claim = claim
    }
  }

  let maximumConcurrentJobs: Int
  let workerID: WorkflowWorkerIDV4

  private let coordinator: WorkflowDurableCoordinatorV4
  private let fileSystem: any WorkflowDurableFileSystem
  private let slotDirectoryURL: URL
  private let leaseDuration: WorkflowLeaseIntervalV4
  private var held: [WorkflowLeaseIDV4: HeldDispatch] = [:]
  private var cycleReceipts: [WorkflowDispatchCycleIDV4: CycleRecord] = [:]

  init(
    coordinator: WorkflowDurableCoordinatorV4,
    rootURL: URL,
    workerID: WorkflowWorkerIDV4,
    maximumConcurrentJobs: Int,
    leaseDuration: WorkflowLeaseIntervalV4,
    fileSystem: (any WorkflowDurableFileSystem)? = nil
  ) throws {
    guard (1...64).contains(maximumConcurrentJobs) else {
      throw WorkflowQueueDispatcherErrorV4.invalidConcurrency(
        maximumConcurrentJobs
      )
    }
    let standardized = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedFileSystem =
      try fileSystem
      ?? WorkflowLocalDurableFileSystem(trustedRootURL: standardized)
    let slots =
      standardized
      .appendingPathComponent("dispatcher-v4", isDirectory: true)
      .appendingPathComponent("slots", isDirectory: true)
    try resolvedFileSystem.ensureDirectory(slots)
    try Self.bindGlobalConcurrency(
      maximumConcurrentJobs,
      rootURL: standardized,
      fileSystem: resolvedFileSystem
    )
    self.coordinator = coordinator
    self.fileSystem = resolvedFileSystem
    slotDirectoryURL = slots
    self.workerID = workerID
    self.maximumConcurrentJobs = maximumConcurrentJobs
    self.leaseDuration = leaseDuration
  }

  func claimNext(
    cycleID: WorkflowDispatchCycleIDV4,
    priorities: [WorkflowQueuePriorityV4] = []
  ) async throws -> WorkflowQueueDispatchResultV4 {
    let priorityMap = try Self.priorityMap(priorities)
    let normalizedPriorities = priorities.sorted { $0.jobID < $1.jobID }
    if let existing = cycleReceipts[cycleID] {
      guard existing.priorities == normalizedPriorities else {
        throw WorkflowQueueDispatcherErrorV4.cycleReplayConflict(cycleID)
      }
      return .claimed(existing.receipt)
    }
    guard let slot = try acquireSlot() else { return .capacityExhausted }
    do {
      let opened = try await coordinator.open()
      let candidates = Self.orderedCandidates(
        state: opened.state,
        priorities: priorityMap
      )
      for candidate in candidates {
        let identity = try Self.identity(
          seed: cycleID.rawValue,
          jobID: candidate.jobID,
          stage: "dispatch"
        )
        let request = try WorkflowLeaseAcquisitionRequestV4(
          jobID: candidate.jobID,
          leaseID: identity.leaseID,
          workerID: workerID,
          eventID: identity.eventID,
          commandID: identity.commandID,
          expectedLifecycle: .queued,
          targetLifecycle: .probing,
          attemptID: nil,
          duration: leaseDuration
        )
        do {
          let claim = try await coordinator.acquire(request)
          let receipt = try await acquisitionReceipt(
            commandID: identity.commandID
          )
          let heldDispatch = HeldDispatch(
            slot: slot.index,
            slotLease: slot.lease,
            priority: candidate.priority,
            queueOrdinal: candidate.queueOrdinal,
            acquisitionReceipt: receipt,
            claim: claim
          )
          held[claim.leaseID] = heldDispatch
          let publicReceipt = Self.publicReceipt(heldDispatch)
          cycleReceipts[cycleID] = CycleRecord(
            priorities: normalizedPriorities,
            receipt: publicReceipt
          )
          return .claimed(publicReceipt)
        } catch let error as WorkflowDurableCoordinatorErrorV4 {
          switch error {
          case .noClaimableJob, .activeLeaseMetadata:
            continue
          default:
            throw error
          }
        }
      }
      slot.lease.release()
      return .noEligibleJob
    } catch {
      slot.lease.release()
      throw error
    }
  }

  func resume(
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4,
    attemptID: WorkflowAttemptID
  ) async throws -> WorkflowQueueDispatchReceiptV4 {
    try await acquireSpecific(
      jobID: jobID,
      seed: commandKey.rawValue,
      stage: "resume",
      expected: .paused,
      target: .running,
      attemptID: attemptID
    )
  }

  func beginRecovery(
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) async throws -> WorkflowRecoveryClaimResultV4 {
    let inspection = try await coordinator.inspectRecovery(jobID: jobID)
    switch inspection {
    case .activelyOwned, .awaitingExpiry:
      return .deferred(inspection)
    case .terminal(let lifecycle):
      return .terminal(lifecycle)
    case .idle:
      return .deferred(inspection)
    case .recoverableExpired, .recoverableMissingOrReleased:
      break
    }

    let opened = try await coordinator.open()
    guard let job = opened.state.job(id: jobID) else {
      throw WorkflowReducerError.jobNotFound(jobID)
    }
    guard job.lifecycle != .contained else { return .contained }
    if job.lifecycle == .recovering {
      let reacquired = try await acquireSpecific(
        jobID: jobID,
        seed: commandKey.rawValue,
        stage: "recover-reacquire",
        expected: .recovering,
        target: .queued,
        attemptID: nil
      )
      let reentered = try await transition(
        reacquired,
        expected: .queued,
        target: .recovering,
        commandKey: commandKey,
        stage: "recover-reenter",
        attemptID: nil,
        releaseAfterTransition: false
      )
      guard let owned = held[reacquired.claim.leaseID] else {
        throw WorkflowQueueDispatcherErrorV4.claimNotOwned(
          reacquired.claim.leaseID
        )
      }
      owned.preparationReceipts.append(reentered.reducerReceipt)
      return .claimed(Self.publicReceipt(owned))
    }
    guard job.lifecycle.allowsTransition(to: .recovering) else {
      throw WorkflowQueueDispatcherErrorV4.unsupportedRecoveryLifecycle(
        job.lifecycle
      )
    }
    return .claimed(
      try await acquireSpecific(
        jobID: jobID,
        seed: commandKey.rawValue,
        stage: "recover-enter",
        expected: job.lifecycle,
        target: .recovering,
        attemptID: job.activeAttemptID
      )
    )
  }

  func requestPause(
    _ dispatch: WorkflowQueueDispatchReceiptV4,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) async throws -> WorkflowQueueTransitionReceiptV4 {
    let current = try await refreshedDispatch(dispatch)
    return try await transition(
      current,
      expected: .running,
      target: .pausing,
      commandKey: commandKey,
      stage: "pause-request",
      attemptID: current.claim.attemptID,
      releaseAfterTransition: false
    )
  }

  func completePause(
    _ dispatch: WorkflowQueueDispatchReceiptV4,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) async throws -> WorkflowQueueTransitionReceiptV4 {
    let current = try await refreshedDispatch(dispatch)
    return try await transition(
      current,
      expected: .pausing,
      target: .paused,
      commandKey: commandKey,
      stage: "pause-commit",
      attemptID: current.claim.attemptID,
      releaseAfterTransition: true
    )
  }

  func refreshedDispatch(
    _ dispatch: WorkflowQueueDispatchReceiptV4
  ) async throws -> WorkflowQueueDispatchReceiptV4 {
    guard let owned = held[dispatch.claim.leaseID] else {
      throw WorkflowQueueDispatcherErrorV4.claimNotOwned(
        dispatch.claim.leaseID
      )
    }
    owned.claim = try await coordinator.currentClaim(for: owned.claim)
    return Self.publicReceipt(owned)
  }

  func completeRecovery(
    _ dispatch: WorkflowQueueDispatchReceiptV4,
    target: WorkflowJobLifecycle,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) async throws -> WorkflowQueueTransitionReceiptV4 {
    guard WorkflowJobLifecycle.recovering.allowsTransition(to: target) else {
      throw WorkflowQueueDispatcherErrorV4.unsupportedRecoveryLifecycle(
        target
      )
    }
    return try await transition(
      dispatch,
      expected: .recovering,
      target: target,
      commandKey: commandKey,
      stage: "recover-complete-\(target.rawValue)",
      attemptID: nil,
      releaseAfterTransition: true
    )
  }

  func transition(
    _ dispatch: WorkflowQueueDispatchReceiptV4,
    expected: WorkflowJobLifecycle,
    target: WorkflowJobLifecycle,
    commandKey: WorkflowRecoveryCommandKeyV4,
    stage: String,
    attemptID: WorkflowAttemptID?,
    releaseAfterTransition: Bool
  ) async throws -> WorkflowQueueTransitionReceiptV4 {
    guard let owned = held[dispatch.claim.leaseID] else {
      throw WorkflowQueueDispatcherErrorV4.claimNotOwned(
        dispatch.claim.leaseID
      )
    }
    let current = try await coordinator.currentClaim(for: owned.claim)
    guard current.lifecycle == expected else {
      throw WorkflowQueueDispatcherErrorV4.staleClaimLifecycle(
        expected: expected,
        actual: current.lifecycle
      )
    }
    let identity = try Self.identity(
      seed: commandKey.rawValue,
      jobID: current.jobID,
      stage: stage
    )
    let result = try await coordinator.transition(
      WorkflowLifecycleCommandV4(
        eventID: identity.eventID,
        commandID: identity.commandID,
        from: expected,
        to: target,
        attemptID: attemptID
      ),
      using: current
    )

    let coordinatorReleased =
      target == .paused
      || target == .contained
      || target.isTerminal
    if releaseAfterTransition || coordinatorReleased {
      if !coordinatorReleased {
        let refreshed = try await coordinator.currentClaim(for: current)
        try await coordinator.releaseWithoutTransition(refreshed)
      }
      owned.slotLease.release()
      held.removeValue(forKey: current.leaseID)
      removeCycleReceipt(leaseID: current.leaseID)
    } else {
      owned.claim = try await coordinator.currentClaim(for: current)
    }
    return WorkflowQueueTransitionReceiptV4(
      claim: current,
      reducerReceipt: result.receipt,
      lifecycle: target
    )
  }

  func release(_ dispatch: WorkflowQueueDispatchReceiptV4) async throws {
    guard let owned = held.removeValue(forKey: dispatch.claim.leaseID) else {
      throw WorkflowQueueDispatcherErrorV4.claimNotOwned(
        dispatch.claim.leaseID
      )
    }
    defer { owned.slotLease.release() }
    removeCycleReceipt(leaseID: dispatch.claim.leaseID)
    let current = try await coordinator.currentClaim(for: owned.claim)
    try await coordinator.releaseWithoutTransition(current)
  }

  func activeClaimCount() -> Int {
    held.count
  }

  /// Fault-injection boundary for restart qualification. Real process death
  /// releases these descriptors in the kernel; this produces the same durable
  /// state without inventing a non-production recovery path.
  func injectProcessTerminationAfterLeasePersistence() async {
    for owned in held.values { owned.slotLease.release() }
    held.removeAll(keepingCapacity: false)
    cycleReceipts.removeAll(keepingCapacity: false)
    await coordinator.injectProcessTerminationAfterLeasePersistence()
  }
}

extension WorkflowQueueDispatcherV4 {
  fileprivate struct Slot {
    let index: Int
    let lease: WorkflowExclusiveFileLease
  }

  fileprivate struct Candidate {
    let jobID: WorkflowJobID
    let priority: Int32
    let queueOrdinal: Int
  }

  fileprivate struct Identity {
    let leaseID: WorkflowLeaseIDV4
    let eventID: WorkflowEventID
    let commandID: WorkflowCommandID
  }

  fileprivate func acquireSpecific(
    jobID: WorkflowJobID,
    seed: String,
    stage: String,
    expected: WorkflowJobLifecycle,
    target: WorkflowJobLifecycle,
    attemptID: WorkflowAttemptID?
  ) async throws -> WorkflowQueueDispatchReceiptV4 {
    guard let slot = try acquireSlot() else {
      throw WorkflowQueueDispatcherErrorV4.noDispatchCapacity
    }
    do {
      let identity = try Self.identity(
        seed: seed,
        jobID: jobID,
        stage: stage
      )
      let claim = try await coordinator.acquire(
        WorkflowLeaseAcquisitionRequestV4(
          jobID: jobID,
          leaseID: identity.leaseID,
          workerID: workerID,
          eventID: identity.eventID,
          commandID: identity.commandID,
          expectedLifecycle: expected,
          targetLifecycle: target,
          attemptID: attemptID,
          duration: leaseDuration
        )
      )
      let receipt = try await acquisitionReceipt(
        commandID: identity.commandID
      )
      let heldDispatch = HeldDispatch(
        slot: slot.index,
        slotLease: slot.lease,
        priority: 0,
        queueOrdinal: 0,
        acquisitionReceipt: receipt,
        claim: claim
      )
      held[claim.leaseID] = heldDispatch
      return Self.publicReceipt(heldDispatch)
    } catch {
      slot.lease.release()
      throw error
    }
  }

  fileprivate func acquisitionReceipt(
    commandID: WorkflowCommandID
  ) async throws -> WorkflowAppliedEventReceipt {
    let state = try await coordinator.open().state
    guard
      let receipt = state.appliedEvents.first(where: {
        $0.commandID == commandID
      })
    else {
      throw WorkflowQueueDispatcherErrorV4.missingAcquisitionReceipt(
        commandID
      )
    }
    return receipt
  }

  fileprivate func acquireSlot() throws -> Slot? {
    for index in 0..<maximumConcurrentJobs {
      let url = slotDirectoryURL.appendingPathComponent("slot-\(index).lock")
      do {
        return Slot(
          index: index,
          lease: try fileSystem.acquireExclusiveLease(
            at: url,
            nonBlocking: true
          )
        )
      } catch WorkflowDurableFileSystemError.lockUnavailable {
        continue
      }
    }
    return nil
  }

  fileprivate func removeCycleReceipt(leaseID: WorkflowLeaseIDV4) {
    cycleReceipts = cycleReceipts.filter {
      $0.value.receipt.claim.leaseID != leaseID
    }
  }

  fileprivate static func priorityMap(
    _ priorities: [WorkflowQueuePriorityV4]
  ) throws -> [WorkflowJobID: Int32] {
    var result: [WorkflowJobID: Int32] = [:]
    for priority in priorities {
      guard result.updateValue(priority.value, forKey: priority.jobID) == nil else {
        throw WorkflowQueueDispatcherErrorV4.duplicatePriority(
          priority.jobID
        )
      }
    }
    return result
  }

  fileprivate static func orderedCandidates(
    state: WorkflowState,
    priorities: [WorkflowJobID: Int32]
  ) -> [Candidate] {
    state.queueOrder.enumerated().map { ordinal, jobID in
      Candidate(
        jobID: jobID,
        priority: priorities[jobID, default: 0],
        queueOrdinal: ordinal
      )
    }.sorted { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
      if lhs.queueOrdinal != rhs.queueOrdinal {
        return lhs.queueOrdinal < rhs.queueOrdinal
      }
      return lhs.jobID < rhs.jobID
    }
  }

  fileprivate static func identity(
    seed: String,
    jobID: WorkflowJobID,
    stage: String
  ) throws -> Identity {
    let material = Data("\(seed)\u{0}\(jobID.rawValue)\u{0}\(stage)".utf8)
    let digest = WorkflowV4Validation.domainSeparatedSHA256(
      domain: "Mirmir.WorkflowDispatcher.Identity.v4\u{0}",
      data: material
    )
    return try Identity(
      leaseID: WorkflowLeaseIDV4("lease-v4-\(digest.prefix(40))"),
      eventID: WorkflowEventID("event-v4-\(digest.prefix(40))"),
      commandID: WorkflowCommandID("command-v4-\(digest.prefix(40))")
    )
  }

  fileprivate static func bindGlobalConcurrency(
    _ maximumConcurrentJobs: Int,
    rootURL: URL,
    fileSystem: any WorkflowDurableFileSystem
  ) throws {
    let directory = rootURL.appendingPathComponent(
      "dispatcher-v4",
      isDirectory: true
    )
    try fileSystem.ensureDirectory(directory)
    let configurationURL = directory.appendingPathComponent(
      "configuration-v1.json"
    )
    let lockURL = directory.appendingPathComponent("configuration.lock")
    let codec = WorkflowCanonicalCodec()
    let body = WorkflowDispatcherConfigurationBodyV4(
      maximumConcurrentJobs: maximumConcurrentJobs
    )
    let expected = try makeConfigurationDocument(body, codec: codec)
    try fileSystem.withExclusiveLock(at: lockURL) { transaction in
      if try transaction.regularFileExists(configurationURL) {
        let existing: WorkflowDispatcherConfigurationDocumentV4
        do {
          let data = try transaction.readRegularFile(
            configurationURL,
            maximumBytes: 4_096
          )
          let schema = try JSONDecoder().decode(
            WorkflowSchemaVersionProbeV4.self,
            from: data
          ).schemaVersion
          switch schema {
          case WorkflowDispatcherConfigurationDocumentV4
            .currentSchemaVersion:
            existing = try codec.decodeCanonical(
              WorkflowDispatcherConfigurationDocumentV4.self,
              from: data
            )
          case WorkflowDispatcherConfigurationDocumentV1
            .schemaVersionValue:
            let legacy = try codec.decodeCanonical(
              WorkflowDispatcherConfigurationDocumentV1.self,
              from: data
            )
            guard
              legacy.body.schemaVersion
                == WorkflowDispatcherConfigurationBodyV4
                .currentSchemaVersion,
              (1...64).contains(legacy.body.maximumConcurrentJobs)
            else {
              throw WorkflowQueueDispatcherErrorV4.corruptConfiguration
            }
            let migrated = try makeConfigurationDocument(
              legacy.body,
              codec: codec
            )
            guard migrated.bodyHash == legacy.bodyHash else {
              throw WorkflowQueueDispatcherErrorV4.corruptConfiguration
            }
            existing = migrated
            try transaction.replaceAtomically(
              codec.canonicalData(migrated),
              at: configurationURL
            )
          default:
            throw WorkflowQueueDispatcherErrorV4
              .unsupportedConfigurationSchema(
                actual: schema,
                current: WorkflowDispatcherConfigurationDocumentV4
                  .currentSchemaVersion
              )
          }
          guard
            existing.schemaVersion
              == WorkflowDispatcherConfigurationDocumentV4
              .currentSchemaVersion,
            existing.body.schemaVersion
              == WorkflowDispatcherConfigurationBodyV4
              .currentSchemaVersion,
            (1...64).contains(
              existing.body.maximumConcurrentJobs
            ),
            try makeConfigurationDocument(
              existing.body,
              codec: codec
            ) == existing
          else {
            throw WorkflowQueueDispatcherErrorV4
              .corruptConfiguration
          }
        } catch let error as WorkflowQueueDispatcherErrorV4 {
          throw error
        } catch {
          throw WorkflowQueueDispatcherErrorV4.corruptConfiguration
        }
        guard
          existing.body.maximumConcurrentJobs
            == maximumConcurrentJobs
        else {
          throw
            WorkflowQueueDispatcherErrorV4
            .concurrencyConfigurationMismatch(
              expected: existing.body.maximumConcurrentJobs,
              actual: maximumConcurrentJobs
            )
        }
        return
      }
      try transaction.writeNewAtomically(
        codec.canonicalData(expected),
        to: configurationURL
      )
    }
  }

  fileprivate static func makeConfigurationDocument(
    _ body: WorkflowDispatcherConfigurationBodyV4,
    codec: WorkflowCanonicalCodec
  ) throws -> WorkflowDispatcherConfigurationDocumentV4 {
    try WorkflowDispatcherConfigurationDocumentV4(
      bodyHash: WorkflowDispatcherConfigurationHashV4(
        WorkflowV4Validation.domainSeparatedSHA256(
          domain: "Mirmir.WorkflowDispatcher.Configuration.v1\u{0}",
          data: codec.canonicalData(body)
        )
      ),
      body: body
    )
  }

  private static func publicReceipt(
    _ held: HeldDispatch
  ) -> WorkflowQueueDispatchReceiptV4 {
    WorkflowQueueDispatchReceiptV4(
      claim: held.claim,
      slot: held.slot,
      priority: held.priority,
      queueOrdinal: held.queueOrdinal,
      acquisitionReceipt: held.acquisitionReceipt,
      preparationReceipts: held.preparationReceipts
    )
  }
}

// MARK: - Canonical recovery decisions

enum WorkflowRecoveryActionV4: String, Codable, Equatable, Sendable {
  case reconciled
  case containedBookmarkFailure = "contained_bookmark_failure"
  case containedReconciliationFailure = "contained_reconciliation_failure"
}

/// Durable intent written before leaving `recovering`. If termination lands
/// between the reducer transition and the completed decision write, launch
/// recovery can prove that transition from the journal receipt and finalize
/// the same decision without repeating filesystem reconciliation.
struct WorkflowRecoveryPreparedDecisionBodyV4: Codable, Equatable, Sendable {
  static let currentSchemaVersion: UInt16 = 1

  let schemaVersion: UInt16
  let commandKey: WorkflowRecoveryCommandKeyV4
  let jobBinding: WorkflowJobBinding
  let observedLifecycle: WorkflowJobLifecycle
  let targetLifecycle: WorkflowJobLifecycle
  let action: WorkflowRecoveryActionV4
  let decidedAt: WorkflowWallClockInstantV4
  let bookmarkReceipts: [WorkflowBookmarkActivationReceiptV4]
  let bookmarkFailures: [WorkflowBookmarkActivationFailureV4]
  let reconciliationReport: WorkflowPartialReconciliationReportV4?
  let acquisitionReceipt: WorkflowAppliedEventReceipt
  let preparationReceipts: [WorkflowAppliedEventReceipt]
  let expectedCompletionEventID: WorkflowEventID
  let expectedCompletionCommandID: WorkflowCommandID

  init(
    commandKey: WorkflowRecoveryCommandKeyV4,
    jobBinding: WorkflowJobBinding,
    observedLifecycle: WorkflowJobLifecycle,
    targetLifecycle: WorkflowJobLifecycle,
    action: WorkflowRecoveryActionV4,
    decidedAt: WorkflowWallClockInstantV4,
    bookmarkReceipts: [WorkflowBookmarkActivationReceiptV4],
    bookmarkFailures: [WorkflowBookmarkActivationFailureV4],
    reconciliationReport: WorkflowPartialReconciliationReportV4?,
    acquisitionReceipt: WorkflowAppliedEventReceipt,
    preparationReceipts: [WorkflowAppliedEventReceipt],
    expectedCompletionEventID: WorkflowEventID,
    expectedCompletionCommandID: WorkflowCommandID
  ) throws {
    let entryCommandIDs =
      [acquisitionReceipt.commandID]
      + preparationReceipts.map(\.commandID)
    guard !observedLifecycle.isTerminal,
      targetLifecycle != .recovering,
      WorkflowJobLifecycle.recovering.allowsTransition(to: targetLifecycle),
      !entryCommandIDs.contains(expectedCompletionCommandID),
      Set(entryCommandIDs).count == entryCommandIDs.count
    else {
      throw WorkflowRecoveryDecisionStoreErrorV4.invalidDocument
    }
    schemaVersion = Self.currentSchemaVersion
    self.commandKey = commandKey
    self.jobBinding = jobBinding
    self.observedLifecycle = observedLifecycle
    self.targetLifecycle = targetLifecycle
    self.action = action
    self.decidedAt = decidedAt
    self.bookmarkReceipts = bookmarkReceipts.sorted { $0.role < $1.role }
    self.bookmarkFailures = bookmarkFailures.sorted {
      ($0.role?.rawValue ?? "") < ($1.role?.rawValue ?? "")
    }
    self.reconciliationReport = reconciliationReport
    self.acquisitionReceipt = acquisitionReceipt
    self.preparationReceipts = preparationReceipts
    self.expectedCompletionEventID = expectedCompletionEventID
    self.expectedCompletionCommandID = expectedCompletionCommandID
  }
}

struct WorkflowRecoveryPreparedDecisionDocumentV4:
  Codable,
  Equatable,
  Sendable
{
  static let currentSchemaVersion =
    WorkflowQueueDispatcherEnvelopeSchemaV4.current

  let schemaVersion: UInt16
  let bodyHash: WorkflowRecoveryPreparedDecisionHashV4
  let body: WorkflowRecoveryPreparedDecisionBodyV4

  fileprivate init(
    bodyHash: WorkflowRecoveryPreparedDecisionHashV4,
    body: WorkflowRecoveryPreparedDecisionBodyV4
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.bodyHash = bodyHash
    self.body = body
  }
}

private struct WorkflowRecoveryPreparedDecisionDocumentV1:
  Codable,
  Equatable,
  Sendable
{
  static let schemaVersionValue =
    WorkflowQueueDispatcherEnvelopeSchemaV4.legacy

  let schemaVersion: UInt16
  let bodyHash: WorkflowRecoveryPreparedDecisionHashV4
  let body: WorkflowRecoveryPreparedDecisionBodyV4

  init(
    bodyHash: WorkflowRecoveryPreparedDecisionHashV4,
    body: WorkflowRecoveryPreparedDecisionBodyV4
  ) {
    schemaVersion = Self.schemaVersionValue
    self.bodyHash = bodyHash
    self.body = body
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case bodyHash
    case body
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(
      UInt16.self,
      forKey: .schemaVersion
    )
    guard schemaVersion == Self.schemaVersionValue else {
      throw WorkflowRecoveryDecisionStoreErrorV4
        .unsupportedSchemaVersion(
          actual: schemaVersion,
          current: WorkflowRecoveryPreparedDecisionDocumentV4
            .currentSchemaVersion
        )
    }
    self.init(
      bodyHash: try container.decode(
        WorkflowRecoveryPreparedDecisionHashV4.self,
        forKey: .bodyHash
      ),
      body: try container.decode(
        WorkflowRecoveryPreparedDecisionBodyV4.self,
        forKey: .body
      )
    )
  }
}

struct WorkflowRecoveryDecisionBodyV4: Codable, Equatable, Sendable {
  static let currentSchemaVersion: UInt16 = 1

  let schemaVersion: UInt16
  let commandKey: WorkflowRecoveryCommandKeyV4
  let jobBinding: WorkflowJobBinding
  let observedLifecycle: WorkflowJobLifecycle
  let targetLifecycle: WorkflowJobLifecycle
  let action: WorkflowRecoveryActionV4
  let decidedAt: WorkflowWallClockInstantV4
  let bookmarkReceipts: [WorkflowBookmarkActivationReceiptV4]
  let bookmarkFailures: [WorkflowBookmarkActivationFailureV4]
  let reconciliationReport: WorkflowPartialReconciliationReportV4?
  let acquisitionReceipt: WorkflowAppliedEventReceipt
  let preparationReceipts: [WorkflowAppliedEventReceipt]
  let completionReceipt: WorkflowAppliedEventReceipt

  init(
    commandKey: WorkflowRecoveryCommandKeyV4,
    jobBinding: WorkflowJobBinding,
    observedLifecycle: WorkflowJobLifecycle,
    targetLifecycle: WorkflowJobLifecycle,
    action: WorkflowRecoveryActionV4,
    decidedAt: WorkflowWallClockInstantV4,
    bookmarkReceipts: [WorkflowBookmarkActivationReceiptV4],
    bookmarkFailures: [WorkflowBookmarkActivationFailureV4],
    reconciliationReport: WorkflowPartialReconciliationReportV4?,
    acquisitionReceipt: WorkflowAppliedEventReceipt,
    preparationReceipts: [WorkflowAppliedEventReceipt] = [],
    completionReceipt: WorkflowAppliedEventReceipt
  ) throws {
    guard !observedLifecycle.isTerminal,
      targetLifecycle != .recovering,
      completionReceipt.commandID != acquisitionReceipt.commandID,
      !preparationReceipts.contains(where: {
        $0.commandID == acquisitionReceipt.commandID
          || $0.commandID == completionReceipt.commandID
      }),
      Set(preparationReceipts.map(\.commandID)).count
        == preparationReceipts.count
    else {
      throw WorkflowRecoveryDecisionStoreErrorV4.invalidDocument
    }
    schemaVersion = Self.currentSchemaVersion
    self.commandKey = commandKey
    self.jobBinding = jobBinding
    self.observedLifecycle = observedLifecycle
    self.targetLifecycle = targetLifecycle
    self.action = action
    self.decidedAt = decidedAt
    self.bookmarkReceipts = bookmarkReceipts.sorted { $0.role < $1.role }
    self.bookmarkFailures = bookmarkFailures.sorted {
      ($0.role?.rawValue ?? "") < ($1.role?.rawValue ?? "")
    }
    self.reconciliationReport = reconciliationReport
    self.acquisitionReceipt = acquisitionReceipt
    self.preparationReceipts = preparationReceipts
    self.completionReceipt = completionReceipt
  }

  init(
    prepared: WorkflowRecoveryPreparedDecisionBodyV4,
    completionReceipt: WorkflowAppliedEventReceipt,
    additionalPreparationReceipts: [WorkflowAppliedEventReceipt] = []
  ) throws {
    guard completionReceipt.eventID == prepared.expectedCompletionEventID,
      completionReceipt.commandID == prepared.expectedCompletionCommandID
    else {
      throw WorkflowRecoveryDecisionStoreErrorV4.invalidDocument
    }
    try self.init(
      commandKey: prepared.commandKey,
      jobBinding: prepared.jobBinding,
      observedLifecycle: prepared.observedLifecycle,
      targetLifecycle: prepared.targetLifecycle,
      action: prepared.action,
      decidedAt: prepared.decidedAt,
      bookmarkReceipts: prepared.bookmarkReceipts,
      bookmarkFailures: prepared.bookmarkFailures,
      reconciliationReport: prepared.reconciliationReport,
      acquisitionReceipt: prepared.acquisitionReceipt,
      preparationReceipts:
        prepared.preparationReceipts + additionalPreparationReceipts,
      completionReceipt: completionReceipt
    )
  }
}

struct WorkflowRecoveryDecisionDocumentV4: Codable, Equatable, Sendable {
  static let currentSchemaVersion =
    WorkflowQueueDispatcherEnvelopeSchemaV4.current

  let schemaVersion: UInt16
  let bodyHash: WorkflowRecoveryDecisionHashV4
  let body: WorkflowRecoveryDecisionBodyV4

  fileprivate init(
    bodyHash: WorkflowRecoveryDecisionHashV4,
    body: WorkflowRecoveryDecisionBodyV4
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.bodyHash = bodyHash
    self.body = body
  }
}

private struct WorkflowRecoveryDecisionDocumentV1:
  Codable,
  Equatable,
  Sendable
{
  static let schemaVersionValue =
    WorkflowQueueDispatcherEnvelopeSchemaV4.legacy

  let schemaVersion: UInt16
  let bodyHash: WorkflowRecoveryDecisionHashV4
  let body: WorkflowRecoveryDecisionBodyV4

  init(
    bodyHash: WorkflowRecoveryDecisionHashV4,
    body: WorkflowRecoveryDecisionBodyV4
  ) {
    schemaVersion = Self.schemaVersionValue
    self.bodyHash = bodyHash
    self.body = body
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case bodyHash
    case body
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(
      UInt16.self,
      forKey: .schemaVersion
    )
    guard schemaVersion == Self.schemaVersionValue else {
      throw WorkflowRecoveryDecisionStoreErrorV4
        .unsupportedSchemaVersion(
          actual: schemaVersion,
          current: WorkflowRecoveryDecisionDocumentV4
            .currentSchemaVersion
        )
    }
    self.init(
      bodyHash: try container.decode(
        WorkflowRecoveryDecisionHashV4.self,
        forKey: .bodyHash
      ),
      body: try container.decode(
        WorkflowRecoveryDecisionBodyV4.self,
        forKey: .body
      )
    )
  }
}

enum WorkflowRecoveryDecisionStoreErrorV4: Error, Equatable, LocalizedError {
  case invalidDocument
  case corruptDocument
  case unsupportedSchemaVersion(actual: UInt16, current: UInt16)
  case conflict

  var errorDescription: String? {
    switch self {
    case .invalidDocument:
      "The recovery decision violates its canonical contract."
    case .corruptDocument:
      "The recovery decision is noncanonical or hash-invalid."
    case let .unsupportedSchemaVersion(actual, current):
      "Recovery decision schema \(actual) is unsupported; current is \(current)."
    case .conflict:
      "A different recovery decision already uses this command key."
    }
  }
}

actor WorkflowRecoveryDecisionStoreV4 {
  private static let maximumDocumentByteCount = 16 * 1_024 * 1_024

  private let rootURL: URL
  private let fileSystem: any WorkflowDurableFileSystem
  private let codec = WorkflowCanonicalCodec()

  init(
    rootURL: URL,
    fileSystem: (any WorkflowDurableFileSystem)? = nil
  ) throws {
    let standardized = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    self.rootURL = standardized
    self.fileSystem =
      try fileSystem
      ?? WorkflowLocalDurableFileSystem(trustedRootURL: standardized)
  }

  func load(
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) throws -> WorkflowRecoveryDecisionDocumentV4? {
    let directory = decisionDirectoryURL(jobID: jobID)
    try fileSystem.ensureDirectory(directory)
    return try fileSystem.withExclusiveLock(
      at: decisionLockURL(jobID: jobID)
    ) { transaction in
      let url = decisionURL(jobID: jobID, commandKey: commandKey)
      guard try transaction.regularFileExists(url) else { return nil }
      do {
        let data = try transaction.readRegularFile(
          url,
          maximumBytes: Self.maximumDocumentByteCount
        )
        let decoded = try decodeDecisionMigrating(data)
        let document = decoded.document
        try verify(document, jobID: jobID, commandKey: commandKey)
        if decoded.migrated {
          try transaction.replaceAtomically(
            codec.canonicalData(document),
            at: url
          )
        }
        return document
      } catch let error as WorkflowRecoveryDecisionStoreErrorV4 {
        throw error
      } catch {
        throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
      }
    }
  }

  func loadPrepared(
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) throws -> WorkflowRecoveryPreparedDecisionDocumentV4? {
    let directory = decisionDirectoryURL(jobID: jobID)
    try fileSystem.ensureDirectory(directory)
    return try fileSystem.withExclusiveLock(
      at: decisionLockURL(jobID: jobID)
    ) { transaction in
      let url = preparedDecisionURL(jobID: jobID, commandKey: commandKey)
      guard try transaction.regularFileExists(url) else { return nil }
      do {
        let data = try transaction.readRegularFile(
          url,
          maximumBytes: Self.maximumDocumentByteCount
        )
        let decoded = try decodePreparedDecisionMigrating(data)
        let document = decoded.document
        try verifyPrepared(
          document,
          jobID: jobID,
          commandKey: commandKey
        )
        if decoded.migrated {
          try transaction.replaceAtomically(
            codec.canonicalData(document),
            at: url
          )
        }
        return document
      } catch let error as WorkflowRecoveryDecisionStoreErrorV4 {
        throw error
      } catch {
        throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
      }
    }
  }

  @discardableResult
  func save(
    _ body: WorkflowRecoveryDecisionBodyV4
  ) throws -> WorkflowRecoveryDecisionDocumentV4 {
    let document = try makeDocument(body)
    let jobID = body.jobBinding.jobID
    let directory = decisionDirectoryURL(jobID: jobID)
    try fileSystem.ensureDirectory(directory)
    return try fileSystem.withExclusiveLock(
      at: decisionLockURL(jobID: jobID)
    ) { transaction in
      let url = decisionURL(jobID: jobID, commandKey: body.commandKey)
      if try transaction.regularFileExists(url) {
        let data = try transaction.readRegularFile(
          url,
          maximumBytes: Self.maximumDocumentByteCount
        )
        let existing: WorkflowRecoveryDecisionDocumentV4
        do {
          let decoded = try decodeDecisionMigrating(data)
          existing = decoded.document
          try verify(
            existing,
            jobID: jobID,
            commandKey: body.commandKey
          )
          if decoded.migrated {
            try transaction.replaceAtomically(
              codec.canonicalData(existing),
              at: url
            )
          }
        } catch let error as WorkflowRecoveryDecisionStoreErrorV4 {
          throw error
        } catch {
          throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
        }
        guard existing == document else {
          throw WorkflowRecoveryDecisionStoreErrorV4.conflict
        }
        return existing
      }
      try transaction.writeNewAtomically(
        codec.canonicalData(document),
        to: url
      )
      return document
    }
  }

  @discardableResult
  func savePrepared(
    _ body: WorkflowRecoveryPreparedDecisionBodyV4
  ) throws -> WorkflowRecoveryPreparedDecisionDocumentV4 {
    let document = try makePreparedDocument(body)
    let jobID = body.jobBinding.jobID
    let directory = decisionDirectoryURL(jobID: jobID)
    try fileSystem.ensureDirectory(directory)
    return try fileSystem.withExclusiveLock(
      at: decisionLockURL(jobID: jobID)
    ) { transaction in
      let url = preparedDecisionURL(
        jobID: jobID,
        commandKey: body.commandKey
      )
      if try transaction.regularFileExists(url) {
        let existing: WorkflowRecoveryPreparedDecisionDocumentV4
        do {
          let decoded = try decodePreparedDecisionMigrating(
            transaction.readRegularFile(
              url,
              maximumBytes: Self.maximumDocumentByteCount
            )
          )
          existing = decoded.document
          try verifyPrepared(
            existing,
            jobID: jobID,
            commandKey: body.commandKey
          )
          if decoded.migrated {
            try transaction.replaceAtomically(
              codec.canonicalData(existing),
              at: url
            )
          }
        } catch let error as WorkflowRecoveryDecisionStoreErrorV4 {
          throw error
        } catch {
          throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
        }
        guard existing == document else {
          throw WorkflowRecoveryDecisionStoreErrorV4.conflict
        }
        return existing
      }
      try transaction.writeNewAtomically(
        codec.canonicalData(document),
        to: url
      )
      return document
    }
  }
}

extension WorkflowRecoveryDecisionStoreV4 {
  fileprivate func decodeDecisionMigrating(
    _ data: Data
  ) throws -> (
    document: WorkflowRecoveryDecisionDocumentV4,
    migrated: Bool
  ) {
    let schema = try JSONDecoder().decode(
      WorkflowSchemaVersionProbeV4.self,
      from: data
    ).schemaVersion
    switch schema {
    case WorkflowRecoveryDecisionDocumentV4.currentSchemaVersion:
      return (
        try codec.decodeCanonical(
          WorkflowRecoveryDecisionDocumentV4.self,
          from: data
        ),
        false
      )
    case WorkflowRecoveryDecisionDocumentV1.schemaVersionValue:
      let legacy = try codec.decodeCanonical(
        WorkflowRecoveryDecisionDocumentV1.self,
        from: data
      )
      let migrated = try makeDocument(legacy.body)
      guard migrated.bodyHash == legacy.bodyHash else {
        throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
      }
      return (migrated, true)
    default:
      throw WorkflowRecoveryDecisionStoreErrorV4.unsupportedSchemaVersion(
        actual: schema,
        current: WorkflowRecoveryDecisionDocumentV4.currentSchemaVersion
      )
    }
  }

  fileprivate func decodePreparedDecisionMigrating(
    _ data: Data
  ) throws -> (
    document: WorkflowRecoveryPreparedDecisionDocumentV4,
    migrated: Bool
  ) {
    let schema = try JSONDecoder().decode(
      WorkflowSchemaVersionProbeV4.self,
      from: data
    ).schemaVersion
    switch schema {
    case WorkflowRecoveryPreparedDecisionDocumentV4.currentSchemaVersion:
      return (
        try codec.decodeCanonical(
          WorkflowRecoveryPreparedDecisionDocumentV4.self,
          from: data
        ),
        false
      )
    case WorkflowRecoveryPreparedDecisionDocumentV1.schemaVersionValue:
      let legacy = try codec.decodeCanonical(
        WorkflowRecoveryPreparedDecisionDocumentV1.self,
        from: data
      )
      let migrated = try makePreparedDocument(legacy.body)
      guard migrated.bodyHash == legacy.bodyHash else {
        throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
      }
      return (migrated, true)
    default:
      throw WorkflowRecoveryDecisionStoreErrorV4.unsupportedSchemaVersion(
        actual: schema,
        current: WorkflowRecoveryPreparedDecisionDocumentV4
          .currentSchemaVersion
      )
    }
  }

  fileprivate func makeDocument(
    _ body: WorkflowRecoveryDecisionBodyV4
  ) throws -> WorkflowRecoveryDecisionDocumentV4 {
    let hash = try WorkflowRecoveryDecisionHashV4(
      WorkflowV4Validation.domainSeparatedSHA256(
        domain: "Mirmir.WorkflowRecovery.Decision.v1\u{0}",
        data: codec.canonicalData(body)
      )
    )
    return WorkflowRecoveryDecisionDocumentV4(bodyHash: hash, body: body)
  }

  fileprivate func makePreparedDocument(
    _ body: WorkflowRecoveryPreparedDecisionBodyV4
  ) throws -> WorkflowRecoveryPreparedDecisionDocumentV4 {
    let hash = try WorkflowRecoveryPreparedDecisionHashV4(
      WorkflowV4Validation.domainSeparatedSHA256(
        domain: "Mirmir.WorkflowRecovery.PreparedDecision.v1\u{0}",
        data: codec.canonicalData(body)
      )
    )
    return WorkflowRecoveryPreparedDecisionDocumentV4(
      bodyHash: hash,
      body: body
    )
  }

  fileprivate func verify(
    _ document: WorkflowRecoveryDecisionDocumentV4,
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) throws {
    guard
      document.schemaVersion
        == WorkflowRecoveryDecisionDocumentV4.currentSchemaVersion,
      document.body.jobBinding.jobID == jobID,
      document.body.commandKey == commandKey,
      try makeDocument(document.body) == document
    else {
      throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
    }
  }

  fileprivate func verifyPrepared(
    _ document: WorkflowRecoveryPreparedDecisionDocumentV4,
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) throws {
    guard
      document.schemaVersion
        == WorkflowRecoveryPreparedDecisionDocumentV4.currentSchemaVersion,
      document.body.jobBinding.jobID == jobID,
      document.body.commandKey == commandKey,
      try makePreparedDocument(document.body) == document
    else {
      throw WorkflowRecoveryDecisionStoreErrorV4.corruptDocument
    }
  }

  fileprivate func decisionDirectoryURL(jobID: WorkflowJobID) -> URL {
    rootURL
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID.rawValue, isDirectory: true)
      .appendingPathComponent("recovery-v4", isDirectory: true)
  }

  fileprivate func decisionLockURL(jobID: WorkflowJobID) -> URL {
    decisionDirectoryURL(jobID: jobID).appendingPathComponent("decision.lock")
  }

  fileprivate func decisionURL(
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) -> URL {
    decisionDirectoryURL(jobID: jobID).appendingPathComponent(
      "decision-\(commandKey.rawValue).json"
    )
  }

  fileprivate func preparedDecisionURL(
    jobID: WorkflowJobID,
    commandKey: WorkflowRecoveryCommandKeyV4
  ) -> URL {
    decisionDirectoryURL(jobID: jobID).appendingPathComponent(
      "prepared-\(commandKey.rawValue).json"
    )
  }
}

// MARK: - Immutable launch-recovery presentation

enum WorkflowRecoveryPresentationStatusV4:
  String,
  Codable,
  Equatable,
  Sendable
{
  case recovered
  case replayed
  case idle
  case activelyOwned = "actively_owned"
  case awaitingExpiry = "awaiting_expiry"
  case terminal
  case contained
  case bookmarkBlocked = "bookmark_blocked"
  case decisionRecordCorrupt = "decision_record_corrupt"
  case recoveryFailed = "recovery_failed"
}

private enum WorkflowLaunchRecoveryFaultV4: Error {
  case injectedProcessTermination
}

struct WorkflowRecoveryEventSummaryV4: Codable, Equatable, Sendable {
  let sequence: UInt64
  let eventID: WorkflowEventID
  let commandID: WorkflowCommandID

  init(_ receipt: WorkflowAppliedEventReceipt) {
    sequence = receipt.sequence
    eventID = receipt.eventID
    commandID = receipt.commandID
  }
}

struct WorkflowRecoveryResourceSummaryV4: Codable, Equatable, Sendable {
  let role: WorkflowScopedResourceRoleV4?
  let activationStatus: WorkflowBookmarkActivationStatusV4?
  let failureReason: WorkflowBookmarkActivationFailureReasonV4?
  let credentialRevision: UInt64?
}

struct WorkflowLaunchRecoveryItemV4: Codable, Equatable, Sendable {
  let jobID: WorkflowJobID
  let observedLifecycle: WorkflowJobLifecycle
  let presentedLifecycle: WorkflowJobLifecycle
  let status: WorkflowRecoveryPresentationStatusV4
  let resourceSummaries: [WorkflowRecoveryResourceSummaryV4]
  let partialDispositionCounts: [String: Int]
  let containedFailureCount: Int
  let reducerEvents: [WorkflowRecoveryEventSummaryV4]
  let resumable: Bool
}

struct WorkflowLaunchRecoverySnapshotV4: Codable, Equatable, Sendable {
  static let currentSchemaVersion: UInt16 = 1

  let schemaVersion: UInt16
  let generatedAt: WorkflowWallClockInstantV4
  let items: [WorkflowLaunchRecoveryItemV4]

  init(
    generatedAt: WorkflowWallClockInstantV4,
    items: [WorkflowLaunchRecoveryItemV4]
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.generatedAt = generatedAt
    self.items = items.sorted { $0.jobID < $1.jobID }
  }
}

actor WorkflowLaunchRecoveryPresenterV4 {
  private let coordinator: WorkflowDurableCoordinatorV4
  private let bookmarkStore: WorkflowSecurityScopedBookmarkStoreV4
  private let dispatcher: WorkflowQueueDispatcherV4
  private let decisionStore: WorkflowRecoveryDecisionStoreV4
  private let reconciler: WorkflowPartialArtifactReconcilerV4
  private let clock: any WorkflowWallClockV4
  private var terminateAfterPreparedDecision = false

  init(
    coordinator: WorkflowDurableCoordinatorV4,
    bookmarkStore: WorkflowSecurityScopedBookmarkStoreV4,
    dispatcher: WorkflowQueueDispatcherV4,
    decisionStore: WorkflowRecoveryDecisionStoreV4,
    reconciler: WorkflowPartialArtifactReconcilerV4 =
      WorkflowPartialArtifactReconcilerV4(),
    clock: any WorkflowWallClockV4 = WorkflowSystemWallClockV4()
  ) {
    self.coordinator = coordinator
    self.bookmarkStore = bookmarkStore
    self.dispatcher = dispatcher
    self.decisionStore = decisionStore
    self.reconciler = reconciler
    self.clock = clock
  }

  /// Fault boundary for qualification of the prepared-decision transaction.
  /// Kernel process death releases the same dispatcher leases modeled here.
  func injectProcessTerminationAfterPreparedDecision() {
    terminateAfterPreparedDecision = true
  }

  func recoverAtLaunch(
    commandKey: WorkflowRecoveryCommandKeyV4,
    policy: WorkflowPartialScavengingPolicyV4 = .quarantineAllOwned,
    resolver: any WorkflowSecurityScopedBookmarkResolvingV4 =
      WorkflowFoundationSecurityScopedBookmarkResolverV4()
  ) async -> WorkflowLaunchRecoverySnapshotV4 {
    let generatedAt = clock.now()
    let opened: WorkflowJournalOpenResult
    do {
      opened = try await coordinator.open()
    } catch {
      return WorkflowLaunchRecoverySnapshotV4(
        generatedAt: generatedAt,
        items: []
      )
    }
    var items: [WorkflowLaunchRecoveryItemV4] = []
    for job in opened.state.jobs.values.sorted(by: {
      $0.specification.jobID < $1.specification.jobID
    }) {
      let jobKey: WorkflowRecoveryCommandKeyV4
      do {
        jobKey = try Self.jobCommandKey(
          base: commandKey,
          jobID: job.specification.jobID
        )
      } catch {
        items.append(Self.failedItem(job: job, status: .recoveryFailed))
        continue
      }
      do {
        if let decision = try await decisionStore.load(
          jobID: job.specification.jobID,
          commandKey: jobKey
        ) {
          items.append(Self.item(decision: decision, status: .replayed))
          continue
        }
      } catch {
        items.append(
          Self.failedItem(job: job, status: .decisionRecordCorrupt)
        )
        continue
      }
      let prepared: WorkflowRecoveryPreparedDecisionDocumentV4?
      do {
        prepared = try await decisionStore.loadPrepared(
          jobID: job.specification.jobID,
          commandKey: jobKey
        )
      } catch {
        items.append(
          Self.failedItem(job: job, status: .decisionRecordCorrupt)
        )
        continue
      }
      if let prepared {
        do {
          items.append(
            try await resumePreparedDecision(
              prepared,
              job: job
            )
          )
        } catch {
          items.append(Self.failedItem(job: job, status: .recoveryFailed))
        }
        continue
      }

      let inspection: WorkflowLeaseInspectionV4
      do {
        inspection = try await coordinator.inspectRecovery(
          jobID: job.specification.jobID
        )
      } catch {
        items.append(Self.failedItem(job: job, status: .recoveryFailed))
        continue
      }
      switch inspection {
      case .activelyOwned:
        items.append(Self.deferredItem(job: job, status: .activelyOwned))
        continue
      case .awaitingExpiry:
        items.append(Self.deferredItem(job: job, status: .awaitingExpiry))
        continue
      case .idle:
        items.append(Self.deferredItem(job: job, status: .idle))
        continue
      case .terminal:
        items.append(Self.deferredItem(job: job, status: .terminal))
        continue
      case .recoverableExpired, .recoverableMissingOrReleased:
        break
      }

      do {
        let result = try await recoverOne(
          job: job,
          commandKey: jobKey,
          generatedAt: generatedAt,
          policy: policy,
          resolver: resolver
        )
        items.append(result)
      } catch {
        items.append(Self.failedItem(job: job, status: .recoveryFailed))
      }
    }
    return WorkflowLaunchRecoverySnapshotV4(
      generatedAt: generatedAt,
      items: items
    )
  }
}

extension WorkflowLaunchRecoveryPresenterV4 {
  fileprivate func recoverOne(
    job: WorkflowJobState,
    commandKey: WorkflowRecoveryCommandKeyV4,
    generatedAt: WorkflowWallClockInstantV4,
    policy: WorkflowPartialScavengingPolicyV4,
    resolver: any WorkflowSecurityScopedBookmarkResolvingV4
  ) async throws -> WorkflowLaunchRecoveryItemV4 {
    let claimResult = try await dispatcher.beginRecovery(
      jobID: job.specification.jobID,
      commandKey: commandKey
    )
    let dispatch: WorkflowQueueDispatchReceiptV4
    switch claimResult {
    case .claimed(let receipt):
      dispatch = receipt
    case .deferred(.activelyOwned):
      return Self.deferredItem(job: job, status: .activelyOwned)
    case .deferred(.awaitingExpiry):
      return Self.deferredItem(job: job, status: .awaitingExpiry)
    case .deferred:
      return Self.deferredItem(job: job, status: .idle)
    case .terminal:
      return Self.deferredItem(job: job, status: .terminal)
    case .contained:
      return Self.deferredItem(job: job, status: .contained)
    }

    let activation = await bookmarkStore.activate(
      specification: job.specification,
      resolver: resolver
    )
    switch activation {
    case .blocked(let failures):
      return try await prepareAndComplete(
        dispatch: dispatch,
        commandKey: commandKey,
        jobBinding: job.specification.binding,
        observedLifecycle: job.lifecycle,
        targetLifecycle: .contained,
        action: .containedBookmarkFailure,
        decidedAt: generatedAt,
        bookmarkReceipts: [],
        bookmarkFailures: failures,
        reconciliationReport: nil,
        presentationStatus: .bookmarkBlocked
      )
    case .active(let access):
      defer { access.close() }
      let report: WorkflowPartialReconciliationReportV4
      do {
        // Access remains live across both identity checks and every
        // filesystem operation performed by the reconciler.
        try access.revalidateAll()
        let registrations =
          try await coordinator
          .registeredPartialArtifacts(jobID: job.specification.jobID)
        let scope = try access.activatedOutputScope()
        report = try reconciler.reconcile(
          registrations: registrations,
          activatedScopes: [scope],
          policy: policy
        )
        try access.revalidateAll()
      } catch {
        let failureReason: WorkflowBookmarkActivationFailureReasonV4
        if case WorkflowBookmarkStoreErrorV4.targetReplaced = error {
          failureReason = .targetReplaced
        } else {
          failureReason = .reconciliationFailed
        }
        let failure = WorkflowBookmarkActivationFailureV4(
          role: nil,
          reason: failureReason
        )
        return try await prepareAndComplete(
          dispatch: dispatch,
          commandKey: commandKey,
          jobBinding: job.specification.binding,
          observedLifecycle: job.lifecycle,
          targetLifecycle: .contained,
          action: .containedReconciliationFailure,
          decidedAt: generatedAt,
          bookmarkReceipts: access.receipts,
          bookmarkFailures: [failure],
          reconciliationReport: nil,
          presentationStatus: .contained
        )
      }
      let target = Self.recoveryTarget(
        observed: job.lifecycle,
        report: report
      )
      let action: WorkflowRecoveryActionV4 =
        report.containedFailureCount == 0
        ? .reconciled
        : .containedReconciliationFailure
      return try await prepareAndComplete(
        dispatch: dispatch,
        commandKey: commandKey,
        jobBinding: job.specification.binding,
        observedLifecycle: job.lifecycle,
        targetLifecycle: target,
        action: action,
        decidedAt: generatedAt,
        bookmarkReceipts: access.receipts,
        bookmarkFailures: [],
        reconciliationReport: report,
        presentationStatus: .recovered
      )
    }
  }

  fileprivate func prepareAndComplete(
    dispatch: WorkflowQueueDispatchReceiptV4,
    commandKey: WorkflowRecoveryCommandKeyV4,
    jobBinding: WorkflowJobBinding,
    observedLifecycle: WorkflowJobLifecycle,
    targetLifecycle: WorkflowJobLifecycle,
    action: WorkflowRecoveryActionV4,
    decidedAt: WorkflowWallClockInstantV4,
    bookmarkReceipts: [WorkflowBookmarkActivationReceiptV4],
    bookmarkFailures: [WorkflowBookmarkActivationFailureV4],
    reconciliationReport: WorkflowPartialReconciliationReportV4?,
    presentationStatus: WorkflowRecoveryPresentationStatusV4
  ) async throws -> WorkflowLaunchRecoveryItemV4 {
    let completionIdentity = try WorkflowQueueDispatcherV4.identity(
      seed: commandKey.rawValue,
      jobID: jobBinding.jobID,
      stage: "recover-complete-\(targetLifecycle.rawValue)"
    )
    let preparedBody = try WorkflowRecoveryPreparedDecisionBodyV4(
      commandKey: commandKey,
      jobBinding: jobBinding,
      observedLifecycle: observedLifecycle,
      targetLifecycle: targetLifecycle,
      action: action,
      decidedAt: decidedAt,
      bookmarkReceipts: bookmarkReceipts,
      bookmarkFailures: bookmarkFailures,
      reconciliationReport: reconciliationReport,
      acquisitionReceipt: dispatch.acquisitionReceipt,
      preparationReceipts: dispatch.preparationReceipts,
      expectedCompletionEventID: completionIdentity.eventID,
      expectedCompletionCommandID: completionIdentity.commandID
    )
    let prepared: WorkflowRecoveryPreparedDecisionDocumentV4
    do {
      prepared = try await decisionStore.savePrepared(preparedBody)
    } catch {
      // Without a durable intent, leaving `recovering` would create an audit
      // gap. Containment is safer and also releases the global dispatch slot.
      let containmentDigest = WorkflowV4Validation.domainSeparatedSHA256(
        domain: "Mirmir.WorkflowRecovery.IntentFailure.v1\u{0}",
        data: Data(commandKey.rawValue.utf8)
      )
      if let containmentKey = try? WorkflowRecoveryCommandKeyV4(
        "intent-failure-\(containmentDigest.prefix(40))"
      ) {
        _ = try? await dispatcher.completeRecovery(
          dispatch,
          target: .contained,
          commandKey: containmentKey
        )
      } else {
        try? await dispatcher.release(dispatch)
      }
      throw error
    }
    if terminateAfterPreparedDecision {
      terminateAfterPreparedDecision = false
      await dispatcher.injectProcessTerminationAfterLeasePersistence()
      throw WorkflowLaunchRecoveryFaultV4.injectedProcessTermination
    }
    let completion = try await dispatcher.completeRecovery(
      dispatch,
      target: targetLifecycle,
      commandKey: commandKey
    )
    let completedBody = try WorkflowRecoveryDecisionBodyV4(
      prepared: prepared.body,
      completionReceipt: completion.reducerReceipt
    )
    let decision = try await decisionStore.save(completedBody)
    return Self.item(decision: decision, status: presentationStatus)
  }

  fileprivate func resumePreparedDecision(
    _ prepared: WorkflowRecoveryPreparedDecisionDocumentV4,
    job: WorkflowJobState
  ) async throws -> WorkflowLaunchRecoveryItemV4 {
    let state = try await coordinator.open().state
    if let completion = state.appliedEvents.first(where: {
      $0.commandID == prepared.body.expectedCompletionCommandID
    }) {
      let body = try WorkflowRecoveryDecisionBodyV4(
        prepared: prepared.body,
        completionReceipt: completion
      )
      let decision = try await decisionStore.save(body)
      return Self.item(decision: decision, status: .replayed)
    }

    let claimResult = try await dispatcher.beginRecovery(
      jobID: prepared.body.jobBinding.jobID,
      commandKey: prepared.body.commandKey
    )
    let dispatch: WorkflowQueueDispatchReceiptV4
    switch claimResult {
    case .claimed(let receipt):
      dispatch = receipt
    case .deferred(.activelyOwned):
      return Self.deferredItem(job: job, status: .activelyOwned)
    case .deferred(.awaitingExpiry):
      return Self.deferredItem(job: job, status: .awaitingExpiry)
    case .deferred:
      return Self.deferredItem(job: job, status: .idle)
    case .terminal:
      return Self.deferredItem(job: job, status: .terminal)
    case .contained:
      return Self.deferredItem(job: job, status: .contained)
    }
    let completion = try await dispatcher.completeRecovery(
      dispatch,
      target: prepared.body.targetLifecycle,
      commandKey: prepared.body.commandKey
    )
    let existingCommands = Set(
      [prepared.body.acquisitionReceipt.commandID]
        + prepared.body.preparationReceipts.map(\.commandID)
    )
    let additional =
      [dispatch.acquisitionReceipt] + dispatch.preparationReceipts
    let newReceipts = additional.filter {
      !existingCommands.contains($0.commandID)
    }
    let body = try WorkflowRecoveryDecisionBodyV4(
      prepared: prepared.body,
      completionReceipt: completion.reducerReceipt,
      additionalPreparationReceipts: newReceipts
    )
    let decision = try await decisionStore.save(body)
    return Self.item(decision: decision, status: .recovered)
  }

  fileprivate static func recoveryTarget(
    observed: WorkflowJobLifecycle,
    report: WorkflowPartialReconciliationReportV4
  ) -> WorkflowJobLifecycle {
    if report.containedFailureCount > 0 { return .contained }
    switch observed {
    case .running, .pausing, .paused, .recovering:
      return .paused
    case .probing, .queued:
      return .queued
    case .planned:
      return .planned
    case .verifying, .committing, .contained:
      return .contained
    case .completed, .failed, .safeHalt, .cancelled:
      return observed
    }
  }

  fileprivate static func item(
    decision: WorkflowRecoveryDecisionDocumentV4,
    status: WorkflowRecoveryPresentationStatusV4
  ) -> WorkflowLaunchRecoveryItemV4 {
    let body = decision.body
    let resources =
      body.bookmarkReceipts.map {
        WorkflowRecoveryResourceSummaryV4(
          role: $0.role,
          activationStatus: $0.status,
          failureReason: nil,
          credentialRevision: $0.activeCredentialRevision
        )
      }
      + body.bookmarkFailures.map {
        WorkflowRecoveryResourceSummaryV4(
          role: $0.role,
          activationStatus: nil,
          failureReason: $0.reason,
          credentialRevision: nil
        )
      }
    var counts: [String: Int] = [:]
    for receipt in body.reconciliationReport?.receipts ?? [] {
      counts[receipt.disposition.rawValue, default: 0] += 1
    }
    return WorkflowLaunchRecoveryItemV4(
      jobID: body.jobBinding.jobID,
      observedLifecycle: body.observedLifecycle,
      presentedLifecycle: body.targetLifecycle,
      status: status,
      resourceSummaries: resources.sorted {
        ($0.role?.rawValue ?? "") < ($1.role?.rawValue ?? "")
      },
      partialDispositionCounts: counts,
      containedFailureCount:
        body.reconciliationReport?.containedFailureCount ?? 0,
      reducerEvents: [WorkflowRecoveryEventSummaryV4(body.acquisitionReceipt)]
        + body.preparationReceipts.map(WorkflowRecoveryEventSummaryV4.init)
        + [WorkflowRecoveryEventSummaryV4(body.completionReceipt)],
      resumable: body.targetLifecycle == .paused
    )
  }

  fileprivate static func deferredItem(
    job: WorkflowJobState,
    status: WorkflowRecoveryPresentationStatusV4
  ) -> WorkflowLaunchRecoveryItemV4 {
    WorkflowLaunchRecoveryItemV4(
      jobID: job.specification.jobID,
      observedLifecycle: job.lifecycle,
      presentedLifecycle: job.lifecycle,
      status: status,
      resourceSummaries: [],
      partialDispositionCounts: [:],
      containedFailureCount: 0,
      reducerEvents: [],
      resumable: job.lifecycle == .paused
    )
  }

  fileprivate static func failedItem(
    job: WorkflowJobState,
    status: WorkflowRecoveryPresentationStatusV4
  ) -> WorkflowLaunchRecoveryItemV4 {
    deferredItem(job: job, status: status)
  }

  fileprivate static func jobCommandKey(
    base: WorkflowRecoveryCommandKeyV4,
    jobID: WorkflowJobID
  ) throws -> WorkflowRecoveryCommandKeyV4 {
    let hash = WorkflowV4Validation.domainSeparatedSHA256(
      domain: "Mirmir.WorkflowRecovery.JobCommand.v1\u{0}",
      data: Data("\(base.rawValue)\u{0}\(jobID.rawValue)".utf8)
    )
    return try WorkflowRecoveryCommandKeyV4("recovery-v4-\(hash.prefix(40))")
  }
}
