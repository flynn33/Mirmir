import Foundation
import XCTest
@testable import Mirmir

private enum WorkflowQueueSelfTestFailure: Error, CustomStringConvertible {
  case assertion(String)

  var description: String {
    switch self {
    case .assertion(let message): message
    }
  }
}

private final class QueueSelfTestClock: WorkflowWallClockV4, @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64

  init(_ value: UInt64) { self.value = value }

  func now() -> WorkflowWallClockInstantV4 {
    lock.withLock {
      WorkflowWallClockInstantV4(nanosecondsSinceUnixEpoch: value)
    }
  }

  func advance(_ amount: UInt64) {
    lock.withLock { value += amount }
  }
}

private final class QueueSelfTestResolver:
  WorkflowSecurityScopedBookmarkResolvingV4,
  @unchecked Sendable
{
  private struct Record {
    let url: URL
    let stale: Bool
  }

  private struct State {
    var ordinal = 0
    var records: [Data: Record] = [:]
    var denied: Set<WorkflowScopedResourceRoleV4> = []
    var nextStale: Set<WorkflowScopedResourceRoleV4> = []
    var starts = 0
    var stops = 0
  }

  private let lock = NSLock()
  private var state = State()

  var starts: Int { lock.withLock { state.starts } }
  var stops: Int { lock.withLock { state.stops } }

  func deny(_ role: WorkflowScopedResourceRoleV4) {
    _ = lock.withLock { state.denied.insert(role) }
  }

  func allow(_ role: WorkflowScopedResourceRoleV4) {
    _ = lock.withLock { state.denied.remove(role) }
  }

  func makeNextStale(_ role: WorkflowScopedResourceRoleV4) {
    _ = lock.withLock { state.nextStale.insert(role) }
  }

  func makeBookmark(
    for url: URL,
    role: WorkflowScopedResourceRoleV4
  ) throws -> Data {
    lock.withLock {
      state.ordinal += 1
      let data = Data("\(role.rawValue):\(state.ordinal)".utf8)
      state.records[data] = Record(
        url: url,
        stale: state.nextStale.remove(role) != nil
      )
      return data
    }
  }

  func resolveBookmark(
    _ data: Data,
    role: WorkflowScopedResourceRoleV4
  ) throws -> WorkflowResolvedScopedResourceV4 {
    let record = try lock.withLock { () throws -> Record in
      guard let record = state.records[data] else {
        throw WorkflowQueueSelfTestFailure.assertion(
          "unknown bookmark for \(role.rawValue)"
        )
      }
      return record
    }
    return WorkflowResolvedScopedResourceV4(
      url: record.url,
      isStale: record.stale,
      startAccessing: { [self] in
        lock.withLock {
          guard !state.denied.contains(role) else { return false }
          state.starts += 1
          return true
        }
      },
      stopAccessing: { [self] in
        lock.withLock { state.stops += 1 }
      }
    )
  }
}

private struct QueueSelfTestFixture {
  let root: URL
  let store: URL
  let input: URL
  let output: URL
  let cache: URL
  let clock: QueueSelfTestClock

  static func make(_ name: String) throws -> Self {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workflow-queue-v4-selftest-\(name)-\(UUID().uuidString)",
      isDirectory: true
    )
    let store = root.appendingPathComponent("store", isDirectory: true)
    let output = root.appendingPathComponent("output", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(
      at: store,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: output,
      withIntermediateDirectories: false
    )
    try FileManager.default.createDirectory(
      at: cache,
      withIntermediateDirectories: false
    )
    let input = root.appendingPathComponent("input.mov")
    try Data("input".utf8).write(to: input)
    return Self(
      root: root,
      store: store,
      input: input,
      output: output,
      cache: cache,
      clock: QueueSelfTestClock(1_000_000_000)
    )
  }
}

private struct WorkflowQueueDispatcherV4SelfTestMain {
  static func main() async throws {
    var completed: [String] = []
    try await bookmarkDenialRefreshMigrationAndReplacement()
    completed.append("bookmark_security_and_migration")
    try await priorityCapacityAndConcurrency()
    completed.append("priority_capacity_and_concurrency")
    try await pauseAndResume()
    completed.append("pause_and_resume")
    try await launchRecoveryAndReplay()
    completed.append("launch_recovery_and_replay")
    try await preparedDecisionCrashReplay()
    completed.append("prepared_decision_crash_replay")
    try await restartInsideRecovery()
    completed.append("restart_inside_recovery")
    try await corruptBookmarkContainment()
    completed.append("corrupt_bookmark_containment")
    print(
      "workflow-queue-dispatcher-v4 self-test passed: "
        + completed.joined(separator: ",")
    )
  }

  private static func bookmarkDenialRefreshMigrationAndReplacement() async throws {
    let fixture = try QueueSelfTestFixture.make("bookmarks")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let specification = try makeSpecification(1)
    let resolver = QueueSelfTestResolver()
    resolver.makeNextStale(.inputFile)
    let store = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.store
    )
    let document = try await register(
      specification,
      fixture: fixture,
      store: store,
      resolver: resolver
    )

    resolver.deny(.outputDirectory)
    let denied = await store.activate(
      specification: specification,
      resolver: resolver
    )
    guard case .blocked(let failures) = denied else {
      throw WorkflowQueueSelfTestFailure.assertion(
        "denied output scope was activated"
      )
    }
    try expect(
      failures.first?.reason == .accessDenied,
      "denial reason was not explicit"
    )
    try expect(resolver.starts == resolver.stops, "denial leaked active scopes")
    resolver.allow(.outputDirectory)

    let legacy = WorkflowBookmarkSetDocumentV1(
      generation: document.body.generation,
      jobBinding: document.body.jobBinding,
      credentials: document.body.credentials.map {
        WorkflowBookmarkCredentialV1(
          role: $0.role,
          authorizationReference: $0.authorizationReference,
          bookmarkData: $0.bookmarkData,
          targetPath: $0.targetPath,
          targetKind: $0.targetKind,
          targetIdentity: $0.targetIdentity
        )
      }
    )
    let recordURL = bookmarkRecordURL(
      root: fixture.store,
      jobID: specification.jobID
    )
    try WorkflowCanonicalCodec().canonicalData(legacy).write(to: recordURL)
    let migrated = await store.activate(
      specification: specification,
      resolver: resolver
    )
    guard case .active(let access) = migrated else {
      throw WorkflowQueueSelfTestFailure.assertion(
        "canonical v1 bookmark set did not migrate"
      )
    }
    let input = try require(
      access.document.body.credentials.first { $0.role == .inputFile },
      "migrated input credential missing"
    )
    try expect(input.credentialRevision == 2, "stale credential was not refreshed")
    try expect(input.previousCredentialHash != nil, "refresh chain is unbound")
    try expect(
      access.receipts.first { $0.role == .inputFile }?.status
        == .migratedAndRefreshed,
      "migration and refresh outcome was not explicit"
    )
    try access.revalidateAll()
    access.close()
    try expect(resolver.starts == resolver.stops, "successful access leaked scopes")

    let originalOutput = fixture.root.appendingPathComponent(
      "old-output",
      isDirectory: true
    )
    try FileManager.default.moveItem(at: fixture.output, to: originalOutput)
    try FileManager.default.createDirectory(
      at: fixture.output,
      withIntermediateDirectories: false
    )
    let replaced = await store.activate(
      specification: specification,
      resolver: resolver
    )
    guard case .blocked(let replacementFailures) = replaced else {
      throw WorkflowQueueSelfTestFailure.assertion(
        "replacement output directory was accepted"
      )
    }
    try expect(
      replacementFailures.first?.reason == .targetReplaced,
      "path replacement did not fail TOCTOU revalidation"
    )
    try expect(resolver.starts == resolver.stops, "replacement leaked scopes")
  }

  private static func priorityCapacityAndConcurrency() async throws {
    let fixture = try QueueSelfTestFixture.make("dispatch")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinatorA = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let coordinatorB = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let first = try makeSpecification(1)
    let second = try makeSpecification(2)
    let third = try makeSpecification(3)
    try await enqueue(first, coordinator: coordinatorA, index: 1)
    try await enqueue(second, coordinator: coordinatorA, index: 2)
    try await enqueue(third, coordinator: coordinatorA, index: 3)
    let duration = try WorkflowLeaseIntervalV4(nanoseconds: 30_000_000_000)
    let dispatcherA = try WorkflowQueueDispatcherV4(
      coordinator: coordinatorA,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("worker-a"),
      maximumConcurrentJobs: 1,
      leaseDuration: duration
    )
    let dispatcherB = try WorkflowQueueDispatcherV4(
      coordinator: coordinatorB,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("worker-b"),
      maximumConcurrentJobs: 1,
      leaseDuration: duration
    )
    let firstResult = try await dispatcherA.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("priority-cycle"),
      priorities: [
        WorkflowQueuePriorityV4(jobID: second.jobID, value: 10),
        WorkflowQueuePriorityV4(jobID: third.jobID, value: 10),
      ]
    )
    guard case .claimed(let priorityClaim) = firstResult else {
      throw WorkflowQueueSelfTestFailure.assertion("priority claim failed")
    }
    try expect(priorityClaim.claim.jobID == second.jobID, "priority/order changed")
    try expect(priorityClaim.queueOrdinal == 1, "queue ordinal receipt is wrong")
    let replay = try await dispatcherA.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("priority-cycle"),
      priorities: [
        WorkflowQueuePriorityV4(jobID: third.jobID, value: 10),
        WorkflowQueuePriorityV4(jobID: second.jobID, value: 10),
      ]
    )
    try expect(replay == firstResult, "exact dispatch replay changed its receipt")
    do {
      _ = try await dispatcherA.claimNext(
        cycleID: WorkflowDispatchCycleIDV4("priority-cycle"),
        priorities: [
          WorkflowQueuePriorityV4(jobID: second.jobID, value: 11),
          WorkflowQueuePriorityV4(jobID: third.jobID, value: 10),
        ]
      )
      throw WorkflowQueueSelfTestFailure.assertion(
        "dispatch cycle accepted conflicting priorities"
      )
    } catch let error as WorkflowQueueDispatcherErrorV4 {
      let expectedCycle = try WorkflowDispatchCycleIDV4("priority-cycle")
      try expect(
        error == .cycleReplayConflict(expectedCycle),
        "unexpected cycle replay error"
      )
    }
    let blocked = try await dispatcherB.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("capacity-cycle")
    )
    try expect(blocked == .capacityExhausted, "global concurrency was not bounded")
    do {
      _ = try WorkflowQueueDispatcherV4(
        coordinator: coordinatorB,
        rootURL: fixture.store,
        workerID: WorkflowWorkerIDV4("worker-misconfigured"),
        maximumConcurrentJobs: 2,
        leaseDuration: duration
      )
      throw WorkflowQueueSelfTestFailure.assertion(
        "a process changed the durable global concurrency"
      )
    } catch let error as WorkflowQueueDispatcherErrorV4 {
      try expect(
        error
          == .concurrencyConfigurationMismatch(
            expected: 1,
            actual: 2
          ),
        "unexpected concurrency configuration error"
      )
    }
    _ = try await dispatcherA.transition(
      priorityClaim,
      expected: .probing,
      target: .planned,
      commandKey: WorkflowRecoveryCommandKeyV4("priority-release"),
      stage: "planned",
      attemptID: nil,
      releaseAfterTransition: true
    )

    let concurrentFixture = try QueueSelfTestFixture.make("concurrent")
    defer { try? FileManager.default.removeItem(at: concurrentFixture.root) }
    let concurrentCoordinatorA = try WorkflowDurableCoordinatorV4(
      rootURL: concurrentFixture.store,
      clock: concurrentFixture.clock
    )
    let concurrentCoordinatorB = try WorkflowDurableCoordinatorV4(
      rootURL: concurrentFixture.store,
      clock: concurrentFixture.clock
    )
    try await enqueue(first, coordinator: concurrentCoordinatorA, index: 1)
    try await enqueue(third, coordinator: concurrentCoordinatorA, index: 3)
    let concurrentA = try WorkflowQueueDispatcherV4(
      coordinator: concurrentCoordinatorA,
      rootURL: concurrentFixture.store,
      workerID: WorkflowWorkerIDV4("worker-concurrent-a"),
      maximumConcurrentJobs: 2,
      leaseDuration: duration
    )
    let concurrentB = try WorkflowQueueDispatcherV4(
      coordinator: concurrentCoordinatorB,
      rootURL: concurrentFixture.store,
      workerID: WorkflowWorkerIDV4("worker-concurrent-b"),
      maximumConcurrentJobs: 2,
      leaseDuration: duration
    )
    async let resultA = concurrentA.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("concurrent-a"),
      priorities: [WorkflowQueuePriorityV4(jobID: first.jobID, value: 100)]
    )
    async let resultB = concurrentB.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("concurrent-b"),
      priorities: [WorkflowQueuePriorityV4(jobID: first.jobID, value: 100)]
    )
    let results = try await [resultA, resultB]
    let claims = results.compactMap { result -> WorkflowQueueDispatchReceiptV4? in
      if case .claimed(let receipt) = result { return receipt }
      return nil
    }
    // Two jobs remain queued, so both workers can own different jobs, but
    // the high-priority job itself must have exactly one owner.
    try expect(claims.count == 2, "two global slots were not independently usable")
    try expect(
      claims.filter { $0.claim.jobID == first.jobID }.count == 1,
      "one job acquired multiple owners"
    )
    for claim in claims {
      if claim.claim.workerID.rawValue == "worker-concurrent-a" {
        try await concurrentA.release(claim)
      } else {
        try await concurrentB.release(claim)
      }
    }
  }

  private static func pauseAndResume() async throws {
    let fixture = try QueueSelfTestFixture.make("pause")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let coordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let specification = try makeSpecification(1)
    try await enqueue(specification, coordinator: coordinator, index: 1)
    let dispatcher = try WorkflowQueueDispatcherV4(
      coordinator: coordinator,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("worker-pause"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    let result = try await dispatcher.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("pause-cycle")
    )
    guard case .claimed(let initial) = result else {
      throw WorkflowQueueSelfTestFailure.assertion("pause job not claimed")
    }
    _ = try await dispatcher.transition(
      initial,
      expected: .probing,
      target: .planned,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-plan"),
      stage: "planned",
      attemptID: nil,
      releaseAfterTransition: false
    )
    let planned = try await dispatcher.refreshedDispatch(initial)
    _ = try await dispatcher.transition(
      planned,
      expected: .planned,
      target: .running,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-run"),
      stage: "running",
      attemptID: WorkflowAttemptID("attempt-one"),
      releaseAfterTransition: false
    )
    let running = try await dispatcher.refreshedDispatch(initial)
    _ = try await dispatcher.requestPause(
      running,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-request")
    )
    _ = try await dispatcher.completePause(
      running,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-complete")
    )
    let pausedState = try await coordinator.open().state
    try expect(
      pausedState.job(id: specification.jobID)?.lifecycle == .paused,
      "pause did not reach a durable paused state"
    )
    let resumed = try await dispatcher.resume(
      jobID: specification.jobID,
      commandKey: WorkflowRecoveryCommandKeyV4("resume"),
      attemptID: WorkflowAttemptID("attempt-two")
    )
    try expect(resumed.claim.lifecycle == .running, "resume did not run")
    try expect(
      resumed.claim.attemptID?.rawValue == "attempt-two",
      "resume reused the previous attempt"
    )
    try await dispatcher.release(resumed)
  }

  private static func launchRecoveryAndReplay() async throws {
    let fixture = try QueueSelfTestFixture.make("recovery")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let resolver = QueueSelfTestResolver()
    let specification = try makeSpecification(1)
    let crashed = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let bookmarkStore = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.store
    )
    _ = try await register(
      specification,
      fixture: fixture,
      store: bookmarkStore,
      resolver: resolver
    )
    try await enqueue(specification, coordinator: crashed, index: 1)
    let claim = try await makeRunningClaim(
      coordinator: crashed,
      specification: specification
    )
    let activation = await bookmarkStore.activate(
      specification: specification,
      resolver: resolver
    )
    guard case .active(let access) = activation else {
      throw WorkflowQueueSelfTestFailure.assertion("bookmark activation failed")
    }
    let partial = fixture.output.appendingPathComponent(
      ".mirmir-launch-11111111-1111-1111-1111-111111111111.partial.mov"
    )
    try Data("partial".utf8).write(to: partial)
    _ = try await crashed.registerPartialArtifact(
      artifactID: WorkflowArtifactIDV4("launch-partial"),
      fileURL: partial,
      in: access.activatedOutputScope(),
      using: claim
    )
    access.close()
    await crashed.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(2_000_000_000)

    let relaunched = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let dispatcher = try WorkflowQueueDispatcherV4(
      coordinator: relaunched,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("worker-recovery"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    let presenter = WorkflowLaunchRecoveryPresenterV4(
      coordinator: relaunched,
      bookmarkStore: bookmarkStore,
      dispatcher: dispatcher,
      decisionStore: try WorkflowRecoveryDecisionStoreV4(
        rootURL: fixture.store
      ),
      clock: fixture.clock
    )
    let command = try WorkflowRecoveryCommandKeyV4("launch")
    let first = await presenter.recoverAtLaunch(
      commandKey: command,
      resolver: resolver
    )
    let item = try require(first.items.first, "recovery item missing")
    try expect(item.status == .recovered, "crashed job was not recovered")
    try expect(item.presentedLifecycle == .paused, "recovery was not resumable")
    try expect(item.reducerEvents.count == 2, "reducer receipts were not recorded")
    try expect(
      item.partialDispositionCounts["registered_quarantined"] == 1,
      "registered partial was not reconciled"
    )
    try expect(
      !FileManager.default.fileExists(atPath: partial.path),
      "partial remained at its active output path"
    )
    try expect(resolver.starts == resolver.stops, "recovery leaked access scopes")

    let eventCount = try await relaunched.open().state.appliedEvents.count
    let replay = await presenter.recoverAtLaunch(
      commandKey: command,
      resolver: resolver
    )
    try expect(replay.items.first?.status == .replayed, "decision did not replay")
    let replayEventCount = try await relaunched.open().state.appliedEvents.count
    try expect(
      replayEventCount == eventCount,
      "idempotent replay appended another reducer event"
    )
  }

  private static func corruptBookmarkContainment() async throws {
    let fixture = try QueueSelfTestFixture.make("corrupt")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let resolver = QueueSelfTestResolver()
    let specification = try makeSpecification(1)
    let crashed = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let bookmarks = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.store
    )
    _ = try await register(
      specification,
      fixture: fixture,
      store: bookmarks,
      resolver: resolver
    )
    try await enqueue(specification, coordinator: crashed, index: 1)
    _ = try await makeRunningClaim(
      coordinator: crashed,
      specification: specification
    )
    await crashed.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(2_000_000_000)
    let record = bookmarkRecordURL(
      root: fixture.store,
      jobID: specification.jobID
    )
    var corrupt = try Data(contentsOf: record)
    corrupt[corrupt.startIndex] ^= 0xff
    try corrupt.write(to: record)
    let unrelated = fixture.root.appendingPathComponent(
      "unrelated",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: unrelated,
      withIntermediateDirectories: false
    )
    let sentinel = unrelated.appendingPathComponent("sentinel")
    try Data("safe".utf8).write(to: sentinel)

    let relaunched = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let dispatcher = try WorkflowQueueDispatcherV4(
      coordinator: relaunched,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("worker-corrupt"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    let presenter = WorkflowLaunchRecoveryPresenterV4(
      coordinator: relaunched,
      bookmarkStore: bookmarks,
      dispatcher: dispatcher,
      decisionStore: try WorkflowRecoveryDecisionStoreV4(
        rootURL: fixture.store
      ),
      clock: fixture.clock
    )
    let snapshot = await presenter.recoverAtLaunch(
      commandKey: try WorkflowRecoveryCommandKeyV4("corrupt-launch"),
      resolver: resolver
    )
    let item = try require(snapshot.items.first, "corrupt recovery item missing")
    try expect(item.status == .bookmarkBlocked, "corruption was not explicit")
    try expect(item.presentedLifecycle == .contained, "corrupt job was not contained")
    try expect(
      item.resourceSummaries.first?.failureReason == .corruptRecord,
      "corruption reason was lost"
    )
    try expect(
      FileManager.default.fileExists(atPath: sentinel.path),
      "recovery scanned or mutated an unrelated directory"
    )
  }

  private static func preparedDecisionCrashReplay() async throws {
    let fixture = try QueueSelfTestFixture.make("prepared-crash")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let resolver = QueueSelfTestResolver()
    let specification = try makeSpecification(1)
    let crashed = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let bookmarkStore = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.store
    )
    _ = try await register(
      specification,
      fixture: fixture,
      store: bookmarkStore,
      resolver: resolver
    )
    try await enqueue(specification, coordinator: crashed, index: 1)
    _ = try await makeRunningClaim(
      coordinator: crashed,
      specification: specification
    )
    await crashed.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(2_000_000_000)

    let firstCoordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let firstDispatcher = try WorkflowQueueDispatcherV4(
      coordinator: firstCoordinator,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("prepared-first"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    let decisionStore = try WorkflowRecoveryDecisionStoreV4(
      rootURL: fixture.store
    )
    let firstPresenter = WorkflowLaunchRecoveryPresenterV4(
      coordinator: firstCoordinator,
      bookmarkStore: bookmarkStore,
      dispatcher: firstDispatcher,
      decisionStore: decisionStore,
      clock: fixture.clock
    )
    await firstPresenter.injectProcessTerminationAfterPreparedDecision()
    let command = try WorkflowRecoveryCommandKeyV4("prepared-launch")
    let interrupted = await firstPresenter.recoverAtLaunch(
      commandKey: command,
      resolver: resolver
    )
    try expect(
      interrupted.items.first?.status == .recoveryFailed,
      "prepared-decision fault was not injected"
    )
    let interruptedState = try await firstCoordinator.open().state
    try expect(
      interruptedState.job(id: specification.jobID)?.lifecycle == .recovering,
      "prepared-decision crash left the wrong lifecycle"
    )
    let startsAfterPreparation = resolver.starts
    let latePartial = fixture.output.appendingPathComponent(
      ".mirmir-late-33333333-3333-3333-3333-333333333333.partial.mov"
    )
    try Data("late".utf8).write(to: latePartial)
    fixture.clock.advance(31_000_000_000)

    let secondCoordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let secondDispatcher = try WorkflowQueueDispatcherV4(
      coordinator: secondCoordinator,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("prepared-second"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    let secondPresenter = WorkflowLaunchRecoveryPresenterV4(
      coordinator: secondCoordinator,
      bookmarkStore: bookmarkStore,
      dispatcher: secondDispatcher,
      decisionStore: decisionStore,
      clock: fixture.clock
    )
    let resumed = await secondPresenter.recoverAtLaunch(
      commandKey: command,
      resolver: resolver
    )
    let item = try require(resumed.items.first, "prepared replay item missing")
    try expect(item.status == .recovered, "prepared decision did not finish")
    try expect(item.presentedLifecycle == .paused, "prepared replay was not resumable")
    try expect(item.reducerEvents.count == 4, "prepared replay lost reducer receipts")
    try expect(
      resolver.starts == startsAfterPreparation,
      "prepared replay activated and rescanned bookmark scopes"
    )
    try expect(
      FileManager.default.fileExists(atPath: latePartial.path),
      "prepared replay repeated output-directory reconciliation"
    )
  }

  private static func restartInsideRecovery() async throws {
    let fixture = try QueueSelfTestFixture.make("recovery-restart")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let specification = try makeSpecification(1)
    let crashedJob = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    try await enqueue(specification, coordinator: crashedJob, index: 1)
    _ = try await makeRunningClaim(
      coordinator: crashedJob,
      specification: specification
    )
    await crashedJob.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(2_000_000_000)

    let firstRecoveryCoordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let firstRecovery = try WorkflowQueueDispatcherV4(
      coordinator: firstRecoveryCoordinator,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("recovery-first"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    let command = try WorkflowRecoveryCommandKeyV4("recovery-restart")
    guard
      case .claimed = try await firstRecovery.beginRecovery(
        jobID: specification.jobID,
        commandKey: command
      )
    else {
      throw WorkflowQueueSelfTestFailure.assertion(
        "first recovery did not enter recovering"
      )
    }
    await firstRecovery.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(31_000_000_000)

    let secondRecoveryCoordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.store,
      clock: fixture.clock
    )
    let secondRecovery = try WorkflowQueueDispatcherV4(
      coordinator: secondRecoveryCoordinator,
      rootURL: fixture.store,
      workerID: WorkflowWorkerIDV4("recovery-second"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    let restarted = try await secondRecovery.beginRecovery(
      jobID: specification.jobID,
      commandKey: WorkflowRecoveryCommandKeyV4("recovery-restart-2")
    )
    guard case .claimed(let restartedClaim) = restarted else {
      throw WorkflowQueueSelfTestFailure.assertion(
        "recovery could not reacquire a crashed recovering state"
      )
    }
    try expect(
      restartedClaim.preparationReceipts.count == 1,
      "recovery reentry reducer receipt was not retained"
    )
    let completion = try await secondRecovery.completeRecovery(
      restartedClaim,
      target: .paused,
      commandKey: WorkflowRecoveryCommandKeyV4("recovery-restart-2")
    )
    try expect(completion.lifecycle == .paused, "reentered recovery did not finish")
  }
}

extension WorkflowQueueDispatcherV4SelfTestMain {
  fileprivate static func register(
    _ specification: WorkflowJobSpecification,
    fixture: QueueSelfTestFixture,
    store: WorkflowSecurityScopedBookmarkStoreV4,
    resolver: QueueSelfTestResolver
  ) async throws -> WorkflowBookmarkSetDocumentV4 {
    try await store.register(
      specification: specification,
      registrations: [
        WorkflowBookmarkRegistrationV4(
          role: .inputFile,
          authorizationReference: specification.source.bookmark,
          url: fixture.input
        ),
        WorkflowBookmarkRegistrationV4(
          role: .outputDirectory,
          authorizationReference:
            specification.output.directoryBookmark,
          url: fixture.output
        ),
        WorkflowBookmarkRegistrationV4(
          role: .cacheDirectory,
          authorizationReference: WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("cache-bookmark"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(80))
          ),
          url: fixture.cache
        ),
      ],
      resolver: resolver
    )
  }

  fileprivate static func enqueue(
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

  fileprivate static func makeRunningClaim(
    coordinator: WorkflowDurableCoordinatorV4,
    specification: WorkflowJobSpecification
  ) async throws -> WorkflowDispatchClaimV4 {
    let claim = try await coordinator.acquire(
      WorkflowLeaseAcquisitionRequestV4(
        jobID: specification.jobID,
        leaseID: WorkflowLeaseIDV4("crashed-lease"),
        workerID: WorkflowWorkerIDV4("crashed-worker"),
        eventID: WorkflowEventID("crashed-probe-event"),
        commandID: WorkflowCommandID("crashed-probe-command"),
        expectedLifecycle: .queued,
        targetLifecycle: .probing,
        attemptID: nil,
        duration: WorkflowLeaseIntervalV4(
          nanoseconds: 1_000_000_000
        )
      )
    )
    _ = try await coordinator.transition(
      WorkflowLifecycleCommandV4(
        eventID: WorkflowEventID("crashed-plan-event"),
        commandID: WorkflowCommandID("crashed-plan-command"),
        from: .probing,
        to: .planned,
        attemptID: nil
      ),
      using: claim
    )
    _ = try await coordinator.transition(
      WorkflowLifecycleCommandV4(
        eventID: WorkflowEventID("crashed-run-event"),
        commandID: WorkflowCommandID("crashed-run-command"),
        from: .planned,
        to: .running,
        attemptID: WorkflowAttemptID("crashed-attempt")
      ),
      using: claim
    )
    return try await coordinator.currentClaim(for: claim)
  }

  fileprivate static func makeSpecification(_ index: Int) throws -> WorkflowJobSpecification {
    let source = try WorkflowBookmarkReference(
      bookmarkID: WorkflowBookmarkID("source-bookmark-\(index)"),
      revision: 1,
      documentHash: WorkflowBookmarkDocumentHash(digest(index + 1))
    )
    let output = try WorkflowBookmarkReference(
      bookmarkID: WorkflowBookmarkID("output-bookmark-\(index)"),
      revision: 1,
      documentHash: WorkflowBookmarkDocumentHash(digest(index + 2))
    )
    return WorkflowJobSpecification(
      jobID: try WorkflowJobID("job-\(index)"),
      requestID: try WorkflowRequestID(digest(index + 3)),
      source: WorkflowSourceSpecification(
        identityID: try WorkflowSourceIdentityID(digest(index + 4)),
        bookmark: source
      ),
      output: WorkflowOutputSpecification(
        contractID: try WorkflowOutputContractID(digest(index + 5)),
        directoryBookmark: output,
        fileName: try WorkflowOutputFileName("output-\(index).mov")
      ),
      runtimeBinding: WorkflowRuntimeBinding(
        id: try WorkflowRuntimeBindingID(digest(index + 6)),
        runtimeManifestID: try WorkflowRuntimeManifestID(
          digest(index + 7)
        ),
        planID: try WorkflowPlanID(digest(index + 8)),
        backendID: try WorkflowBackendID("backend-v4"),
        backendRevisionID: try WorkflowBackendRevisionID("p06-v4"),
        mediaContractID: try WorkflowMediaContractID(digest(index + 9))
      )
    )
  }

  fileprivate static func bookmarkRecordURL(root: URL, jobID: WorkflowJobID) -> URL {
    root.appendingPathComponent("jobs")
      .appendingPathComponent(jobID.rawValue)
      .appendingPathComponent("bookmarks-v4")
      .appendingPathComponent("access-v2.json")
  }

  fileprivate static func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    guard condition() else {
      throw WorkflowQueueSelfTestFailure.assertion(message)
    }
  }

  fileprivate static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else {
      throw WorkflowQueueSelfTestFailure.assertion(message)
    }
    return value
  }

  fileprivate static func digest(_ value: Int) -> String {
    String(format: "%064llx", value)
  }
}

final class WorkflowQueueDispatcherV4SelfTests: XCTestCase {
    func testStandaloneScenarios() async throws {
        try await WorkflowQueueDispatcherV4SelfTestMain.main()
    }
}
