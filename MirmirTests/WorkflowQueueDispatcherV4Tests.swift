import Darwin
import Foundation
import XCTest

#if canImport(Mirmir)
  @testable import Mirmir
#endif

final class WorkflowQueueDispatcherV4Tests: XCTestCase {
  func testBookmarkDenialReleasesEveryPreviouslyActivatedScope() async throws {
    let fixture = try makeFixture("denial")
    let specification = try makeSpecification(1)
    let resolver = WorkflowBookmarkResolverStubV4()
    let store = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.storeURL
    )
    try await register(
      specification,
      fixture: fixture,
      store: store,
      resolver: resolver
    )
    resolver.deny(.outputDirectory)

    let result = await store.activate(
      specification: specification,
      resolver: resolver
    )
    guard case .blocked(let failures) = result else {
      return XCTFail("Denied output scope was activated.")
    }
    XCTAssertEqual(
      failures,
      [
        WorkflowBookmarkActivationFailureV4(
          role: .outputDirectory,
          reason: .accessDenied
        )
      ]
    )
    XCTAssertEqual(resolver.activeAccessCount, 0)
    XCTAssertEqual(resolver.startCount, resolver.stopCount)
  }

  func testStaleBookmarkRefreshIsHashChainedAndSurvivesRestart() async throws {
    let fixture = try makeFixture("stale")
    let specification = try makeSpecification(1)
    let resolver = WorkflowBookmarkResolverStubV4()
    resolver.makeNextBookmarkStale(.inputFile)
    let firstStore = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.storeURL
    )
    try await register(
      specification,
      fixture: fixture,
      store: firstStore,
      resolver: resolver
    )

    let result = await firstStore.activate(
      specification: specification,
      resolver: resolver
    )
    guard case .active(let access) = result else {
      return XCTFail("Stale bookmark did not refresh.")
    }
    let inputReceipt = try XCTUnwrap(
      access.receipts.first { $0.role == .inputFile }
    )
    XCTAssertEqual(inputReceipt.status, .refreshed)
    XCTAssertEqual(inputReceipt.previousCredentialRevision, 1)
    XCTAssertEqual(inputReceipt.activeCredentialRevision, 2)
    access.close()
    XCTAssertEqual(resolver.activeAccessCount, 0)

    let relaunchedStore = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.storeURL
    )
    let document = try await relaunchedStore.load(
      specification: specification
    )
    let input = try XCTUnwrap(
      document.body.credentials.first { $0.role == .inputFile }
    )
    XCTAssertEqual(document.body.generation, 2)
    XCTAssertEqual(input.credentialRevision, 2)
    XCTAssertNotNil(input.previousCredentialHash)
  }

  func testPathReplacementIsRejectedAfterScopeActivation() async throws {
    let fixture = try makeFixture("replacement")
    let specification = try makeSpecification(1)
    let resolver = WorkflowBookmarkResolverStubV4()
    let store = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.storeURL
    )
    try await register(
      specification,
      fixture: fixture,
      store: store,
      resolver: resolver
    )

    let original = fixture.outputURL.deletingLastPathComponent()
      .appendingPathComponent("output-original", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.outputURL, to: original)
    try FileManager.default.createDirectory(
      at: fixture.outputURL,
      withIntermediateDirectories: false
    )

    let result = await store.activate(
      specification: specification,
      resolver: resolver
    )
    guard case .blocked(let failures) = result else {
      return XCTFail("A replacement output directory was accepted.")
    }
    XCTAssertEqual(failures.first?.role, .outputDirectory)
    XCTAssertEqual(failures.first?.reason, .targetReplaced)
    XCTAssertEqual(resolver.activeAccessCount, 0)
  }

  func testDispatcherUsesPriorityThenQueueOrderAndGlobalCapacity() async throws {
    let fixture = try makeFixture("dispatch")
    let coordinatorA = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let coordinatorB = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let first = try makeSpecification(1)
    let second = try makeSpecification(2)
    let third = try makeSpecification(3)
    try await enqueue(first, into: coordinatorA, index: 1)
    try await enqueue(second, into: coordinatorA, index: 2)
    try await enqueue(third, into: coordinatorA, index: 3)

    let duration = try WorkflowLeaseIntervalV4(nanoseconds: 10_000_000_000)
    let dispatcherA = try WorkflowQueueDispatcherV4(
      coordinator: coordinatorA,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("worker-a"),
      maximumConcurrentJobs: 1,
      leaseDuration: duration
    )
    let dispatcherB = try WorkflowQueueDispatcherV4(
      coordinator: coordinatorB,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("worker-b"),
      maximumConcurrentJobs: 1,
      leaseDuration: duration
    )
    let claimed = try await dispatcherA.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("cycle-a"),
      priorities: [
        try WorkflowQueuePriorityV4(jobID: second.jobID, value: 20),
        try WorkflowQueuePriorityV4(jobID: third.jobID, value: 20),
      ]
    )
    guard case .claimed(let receipt) = claimed else {
      return XCTFail("No prioritized job was claimed.")
    }
    XCTAssertEqual(receipt.claim.jobID, second.jobID)
    XCTAssertEqual(receipt.queueOrdinal, 1)
    XCTAssertEqual(receipt.priority, 20)

    let saturated = try await dispatcherB.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("cycle-b")
    )
    XCTAssertEqual(saturated, .capacityExhausted)

    _ = try await dispatcherA.transition(
      receipt,
      expected: .probing,
      target: .planned,
      commandKey: WorkflowRecoveryCommandKeyV4("dispatch-release"),
      stage: "planned",
      attemptID: nil,
      releaseAfterTransition: true
    )
    let next = try await dispatcherB.claimNext(
      cycleID: WorkflowDispatchCycleIDV4("cycle-c")
    )
    guard case .claimed(let nextReceipt) = next else {
      return XCTFail("Global slot was not released.")
    }
    XCTAssertEqual(nextReceipt.claim.jobID, first.jobID)
  }

  func testDispatcherConfigurationV1MigratesAtomicallyOnRelaunch() async throws {
    let fixture = try makeFixture("dispatcher-configuration-migration")
    let coordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let duration = try WorkflowLeaseIntervalV4(
      nanoseconds: 10_000_000_000
    )
    _ = try WorkflowQueueDispatcherV4(
      coordinator: coordinator,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("configuration-first"),
      maximumConcurrentJobs: 2,
      leaseDuration: duration
    )
    let configurationURL = fixture.storeURL
      .appendingPathComponent("dispatcher-v4", isDirectory: true)
      .appendingPathComponent("configuration-v1.json")
    let current = try Data(contentsOf: configurationURL)
    let legacy = try replacingQueueTopLevelSchemaVersion(
      in: current,
      from: WorkflowQueueDispatcherEnvelopeSchemaV4.current,
      to: WorkflowQueueDispatcherEnvelopeSchemaV4.legacy
    )
    try legacy.write(to: configurationURL, options: .atomic)

    let relaunched = try WorkflowQueueDispatcherV4(
      coordinator: coordinator,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("configuration-relaunch"),
      maximumConcurrentJobs: 2,
      leaseDuration: duration
    )
    let migratedMaximumConcurrentJobs = await relaunched.maximumConcurrentJobs
    XCTAssertEqual(migratedMaximumConcurrentJobs, 2)
    XCTAssertEqual(try Data(contentsOf: configurationURL), current)
  }

  func testPauseResumeCommandsRetainCheckpointLifecycleSemantics() async throws {
    let fixture = try makeFixture("pause")
    let coordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let specification = try makeSpecification(1)
    try await enqueue(specification, into: coordinator, index: 1)
    let dispatcher = try WorkflowQueueDispatcherV4(
      coordinator: coordinator,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("worker-pause"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 10_000_000_000
      )
    )
    guard
      case .claimed(let initial) = try await dispatcher.claimNext(
        cycleID: WorkflowDispatchCycleIDV4("pause-cycle")
      )
    else {
      return XCTFail("Job was not claimed.")
    }
    _ = try await dispatcher.transition(
      initial,
      expected: .probing,
      target: .planned,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-planned"),
      stage: "planned",
      attemptID: nil,
      releaseAfterTransition: false
    )
    let planned = try await dispatcher.refreshedDispatch(initial)
    let attempt = try WorkflowAttemptID("attempt-pause-1")
    _ = try await dispatcher.transition(
      planned,
      expected: .planned,
      target: .running,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-running"),
      stage: "running",
      attemptID: attempt,
      releaseAfterTransition: false
    )
    let running = try await dispatcher.refreshedDispatch(initial)
    XCTAssertEqual(running.claim.attemptID, attempt)
    _ = try await dispatcher.requestPause(
      running,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-request")
    )
    _ = try await dispatcher.completePause(
      running,
      commandKey: WorkflowRecoveryCommandKeyV4("pause-complete")
    )
    let pausedState = try await coordinator.open().state
    XCTAssertEqual(pausedState.job(id: specification.jobID)?.lifecycle, .paused)

    let resumed = try await dispatcher.resume(
      jobID: specification.jobID,
      commandKey: WorkflowRecoveryCommandKeyV4("resume-command"),
      attemptID: WorkflowAttemptID("attempt-pause-2")
    )
    XCTAssertEqual(resumed.claim.lifecycle, .running)
    XCTAssertEqual(resumed.claim.attemptID?.rawValue, "attempt-pause-2")
  }

  func testLaunchRecoveryReconcilesOnceAndReplaysReducerReceipts() async throws {
    let fixture = try makeFixture("recovery")
    let resolver = WorkflowBookmarkResolverStubV4()
    let specification = try makeSpecification(1)
    let crashed = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let bookmarkStore = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.storeURL
    )
    try await register(
      specification,
      fixture: fixture,
      store: bookmarkStore,
      resolver: resolver
    )
    try await enqueue(specification, into: crashed, index: 1)
    let claim = try await makeRunningClaim(
      coordinator: crashed,
      specification: specification
    )

    guard
      case .active(let access) = await bookmarkStore.activate(
        specification: specification,
        resolver: resolver
      )
    else {
      return XCTFail("Could not activate registered bookmarks.")
    }
    let partialURL = fixture.outputURL.appendingPathComponent(
      ".mirmir-launch-11111111-1111-1111-1111-111111111111.partial.mov"
    )
    try Data("partial".utf8).write(to: partialURL)
    _ = try await crashed.registerPartialArtifact(
      artifactID: WorkflowArtifactIDV4("launch-partial-1"),
      fileURL: partialURL,
      in: access.activatedOutputScope(),
      using: claim
    )
    access.close()
    await crashed.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(nanoseconds: 2_000_000_000)

    let relaunched = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let dispatcher = try WorkflowQueueDispatcherV4(
      coordinator: relaunched,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("worker-recovery"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 10_000_000_000
      )
    )
    let decisionStore = try WorkflowRecoveryDecisionStoreV4(
      rootURL: fixture.storeURL
    )
    let presenter = WorkflowLaunchRecoveryPresenterV4(
      coordinator: relaunched,
      bookmarkStore: bookmarkStore,
      dispatcher: dispatcher,
      decisionStore: decisionStore,
      clock: fixture.clock
    )
    let command = try WorkflowRecoveryCommandKeyV4("launch-1")
    let first = await presenter.recoverAtLaunch(
      commandKey: command,
      resolver: resolver
    )
    XCTAssertEqual(first.items.count, 1)
    XCTAssertEqual(first.items[0].status, .recovered)
    XCTAssertEqual(first.items[0].presentedLifecycle, .paused)
    XCTAssertEqual(first.items[0].reducerEvents.count, 2)
    XCTAssertEqual(
      first.items[0].partialDispositionCounts["registered_quarantined"],
      1
    )
    XCTAssertTrue(first.items[0].resumable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))

    let recoveryDirectory = fixture.storeURL
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(specification.jobID.rawValue, isDirectory: true)
      .appendingPathComponent("recovery-v4", isDirectory: true)
    let recoveryURLs = try FileManager.default.contentsOfDirectory(
      at: recoveryDirectory,
      includingPropertiesForKeys: nil
    )
    let decisionURL = try XCTUnwrap(
      recoveryURLs.first {
        $0.lastPathComponent.hasPrefix("decision-")
          && $0.pathExtension == "json"
      }
    )
    let preparedURL = try XCTUnwrap(
      recoveryURLs.first {
        $0.lastPathComponent.hasPrefix("prepared-")
          && $0.pathExtension == "json"
      }
    )
    let currentDecision = try Data(contentsOf: decisionURL)
    let currentPrepared = try Data(contentsOf: preparedURL)
    let preparedDocument = try WorkflowCanonicalCodec().decodeCanonical(
      WorkflowRecoveryPreparedDecisionDocumentV4.self,
      from: currentPrepared
    )
    try replacingQueueTopLevelSchemaVersion(
      in: currentDecision,
      from: WorkflowQueueDispatcherEnvelopeSchemaV4.current,
      to: WorkflowQueueDispatcherEnvelopeSchemaV4.legacy
    ).write(to: decisionURL, options: .atomic)
    try replacingQueueTopLevelSchemaVersion(
      in: currentPrepared,
      from: WorkflowQueueDispatcherEnvelopeSchemaV4.current,
      to: WorkflowQueueDispatcherEnvelopeSchemaV4.legacy
    ).write(to: preparedURL, options: .atomic)
    let migratedPrepared = try await decisionStore.loadPrepared(
      jobID: specification.jobID,
      commandKey: preparedDocument.body.commandKey
    )
    XCTAssertEqual(migratedPrepared, preparedDocument)

    let eventCount = try await relaunched.open().state.appliedEvents.count
    let replay = await presenter.recoverAtLaunch(
      commandKey: command,
      resolver: resolver
    )
    XCTAssertEqual(replay.items[0].status, .replayed)
    XCTAssertEqual(replay.items[0].reducerEvents, first.items[0].reducerEvents)
    let replayEventCount = try await relaunched.open().state.appliedEvents.count
    XCTAssertEqual(replayEventCount, eventCount)
    XCTAssertEqual(try Data(contentsOf: decisionURL), currentDecision)
    XCTAssertEqual(try Data(contentsOf: preparedURL), currentPrepared)
  }

  func testCorruptBookmarkRecordIsContainedWithoutDirectoryDiscovery() async throws {
    let fixture = try makeFixture("corrupt")
    let resolver = WorkflowBookmarkResolverStubV4()
    let specification = try makeSpecification(1)
    let crashed = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let bookmarkStore = try WorkflowSecurityScopedBookmarkStoreV4(
      rootURL: fixture.storeURL
    )
    try await register(
      specification,
      fixture: fixture,
      store: bookmarkStore,
      resolver: resolver
    )
    try await enqueue(specification, into: crashed, index: 1)
    _ = try await makeRunningClaim(
      coordinator: crashed,
      specification: specification
    )
    await crashed.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(nanoseconds: 2_000_000_000)

    let recordURL = fixture.storeURL
      .appendingPathComponent("jobs")
      .appendingPathComponent(specification.jobID.rawValue)
      .appendingPathComponent("bookmarks-v4")
      .appendingPathComponent("access-v2.json")
    var bytes = try Data(contentsOf: recordURL)
    bytes[bytes.startIndex] ^= 0xff
    try bytes.write(to: recordURL)
    let foreignDirectory = fixture.rootURL.appendingPathComponent(
      "must-not-scan",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: foreignDirectory,
      withIntermediateDirectories: false
    )
    let sentinel = foreignDirectory.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)

    let relaunched = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let dispatcher = try WorkflowQueueDispatcherV4(
      coordinator: relaunched,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("worker-corrupt"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 10_000_000_000
      )
    )
    let presenter = WorkflowLaunchRecoveryPresenterV4(
      coordinator: relaunched,
      bookmarkStore: bookmarkStore,
      dispatcher: dispatcher,
      decisionStore: try WorkflowRecoveryDecisionStoreV4(
        rootURL: fixture.storeURL
      ),
      clock: fixture.clock
    )
    let snapshot = await presenter.recoverAtLaunch(
      commandKey: try WorkflowRecoveryCommandKeyV4("launch-corrupt"),
      resolver: resolver
    )
    XCTAssertEqual(snapshot.items[0].status, .bookmarkBlocked)
    XCTAssertEqual(snapshot.items[0].presentedLifecycle, .contained)
    XCTAssertEqual(
      snapshot.items[0].resourceSummaries.first?.failureReason,
      .corruptRecord
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
  }

  func testRecoveryCanRestartAfterCrashingInRecoveringState() async throws {
    let fixture = try makeFixture("recovery-restart")
    let specification = try makeSpecification(1)
    let initial = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    try await enqueue(specification, into: initial, index: 1)
    _ = try await makeRunningClaim(
      coordinator: initial,
      specification: specification
    )
    await initial.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(nanoseconds: 2_000_000_000)

    let firstCoordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let first = try WorkflowQueueDispatcherV4(
      coordinator: firstCoordinator,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("recovery-first"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    guard
      case .claimed = try await first.beginRecovery(
        jobID: specification.jobID,
        commandKey: WorkflowRecoveryCommandKeyV4("restart-first")
      )
    else {
      return XCTFail("First recovery did not acquire the job.")
    }
    await first.injectProcessTerminationAfterLeasePersistence()
    fixture.clock.advance(nanoseconds: 31_000_000_000)

    let secondCoordinator = try WorkflowDurableCoordinatorV4(
      rootURL: fixture.storeURL,
      clock: fixture.clock
    )
    let second = try WorkflowQueueDispatcherV4(
      coordinator: secondCoordinator,
      rootURL: fixture.storeURL,
      workerID: WorkflowWorkerIDV4("recovery-second"),
      maximumConcurrentJobs: 1,
      leaseDuration: WorkflowLeaseIntervalV4(
        nanoseconds: 30_000_000_000
      )
    )
    guard
      case .claimed(let restarted) = try await second.beginRecovery(
        jobID: specification.jobID,
        commandKey: WorkflowRecoveryCommandKeyV4("restart-second")
      )
    else {
      return XCTFail("A job stranded in recovering was not reacquired.")
    }
    XCTAssertEqual(restarted.preparationReceipts.count, 1)
    let completed = try await second.completeRecovery(
      restarted,
      target: .paused,
      commandKey: WorkflowRecoveryCommandKeyV4("restart-second")
    )
    XCTAssertEqual(completed.lifecycle, .paused)
  }
}

private final class WorkflowBookmarkResolverStubV4:
  WorkflowSecurityScopedBookmarkResolvingV4,
  @unchecked Sendable
{
  private struct Record {
    let url: URL
    let stale: Bool
  }

  private struct State {
    var nextOrdinal = 0
    var records: [Data: Record] = [:]
    var denied: Set<WorkflowScopedResourceRoleV4> = []
    var nextStale: Set<WorkflowScopedResourceRoleV4> = []
    var starts = 0
    var stops = 0
  }

  private let lock = NSLock()
  private var state = State()

  var startCount: Int { lock.withLock { state.starts } }
  var stopCount: Int { lock.withLock { state.stops } }
  var activeAccessCount: Int { startCount - stopCount }

  func deny(_ role: WorkflowScopedResourceRoleV4) {
    _ = lock.withLock { state.denied.insert(role) }
  }

  func makeNextBookmarkStale(_ role: WorkflowScopedResourceRoleV4) {
    _ = lock.withLock { state.nextStale.insert(role) }
  }

  func makeBookmark(
    for url: URL,
    role: WorkflowScopedResourceRoleV4
  ) throws -> Data {
    lock.withLock {
      state.nextOrdinal += 1
      let data = Data("\(role.rawValue):\(state.nextOrdinal)".utf8)
      let stale = state.nextStale.remove(role) != nil
      state.records[data] = Record(url: url, stale: stale)
      return data
    }
  }

  func resolveBookmark(
    _ data: Data,
    role: WorkflowScopedResourceRoleV4
  ) throws -> WorkflowResolvedScopedResourceV4 {
    let record = try lock.withLock { () throws -> Record in
      guard let record = state.records[data] else {
        throw WorkflowBookmarkStoreErrorV4.invalidCredential(role)
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

private final class WorkflowQueueTestClockV4:
  WorkflowWallClockV4,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var value: UInt64

  init(_ value: UInt64) { self.value = value }

  func now() -> WorkflowWallClockInstantV4 {
    lock.withLock {
      WorkflowWallClockInstantV4(nanosecondsSinceUnixEpoch: value)
    }
  }

  func advance(nanoseconds: UInt64) {
    lock.withLock { value += nanoseconds }
  }
}

private struct WorkflowQueueFixtureV4 {
  let rootURL: URL
  let storeURL: URL
  let inputURL: URL
  let outputURL: URL
  let cacheURL: URL
  let clock: WorkflowQueueTestClockV4
}

extension WorkflowQueueDispatcherV4Tests {
  fileprivate func makeFixture(_ name: String) throws -> WorkflowQueueFixtureV4 {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workflow-queue-v4-\(name)-\(UUID().uuidString)",
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
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return WorkflowQueueFixtureV4(
      rootURL: root,
      storeURL: store,
      inputURL: input,
      outputURL: output,
      cacheURL: cache,
      clock: WorkflowQueueTestClockV4(1_000_000_000)
    )
  }

  fileprivate func register(
    _ specification: WorkflowJobSpecification,
    fixture: WorkflowQueueFixtureV4,
    store: WorkflowSecurityScopedBookmarkStoreV4,
    resolver: WorkflowBookmarkResolverStubV4
  ) async throws {
    _ = try await store.register(
      specification: specification,
      registrations: [
        WorkflowBookmarkRegistrationV4(
          role: .inputFile,
          authorizationReference: specification.source.bookmark,
          url: fixture.inputURL
        ),
        WorkflowBookmarkRegistrationV4(
          role: .outputDirectory,
          authorizationReference:
            specification.output.directoryBookmark,
          url: fixture.outputURL
        ),
        WorkflowBookmarkRegistrationV4(
          role: .cacheDirectory,
          authorizationReference: try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("cache-bookmark-1"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(
              workflowQueueDigest(60)
            )
          ),
          url: fixture.cacheURL
        ),
      ],
      resolver: resolver
    )
  }

  fileprivate func enqueue(
    _ specification: WorkflowJobSpecification,
    into coordinator: WorkflowDurableCoordinatorV4,
    index: Int
  ) async throws {
    _ = try await coordinator.append(
      WorkflowEventDraft(
        eventID: WorkflowEventID("queue-event-\(index)"),
        commandID: WorkflowCommandID("queue-command-\(index)"),
        scope: .job(specification.jobID),
        jobBinding: specification.binding,
        attemptID: nil,
        event: .jobEnqueued(specification)
      )
    )
  }

  fileprivate func makeRunningClaim(
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

  fileprivate func makeSpecification(_ index: Int) throws -> WorkflowJobSpecification {
    let source = try WorkflowBookmarkReference(
      bookmarkID: WorkflowBookmarkID("source-bookmark-\(index)"),
      revision: 1,
      documentHash: WorkflowBookmarkDocumentHash(
        workflowQueueDigest(index + 1)
      )
    )
    let output = try WorkflowBookmarkReference(
      bookmarkID: WorkflowBookmarkID("output-bookmark-\(index)"),
      revision: 1,
      documentHash: WorkflowBookmarkDocumentHash(
        workflowQueueDigest(index + 2)
      )
    )
    let runtime = WorkflowRuntimeBinding(
      id: try WorkflowRuntimeBindingID(workflowQueueDigest(index + 3)),
      runtimeManifestID: try WorkflowRuntimeManifestID(
        workflowQueueDigest(index + 4)
      ),
      planID: try WorkflowPlanID(workflowQueueDigest(index + 5)),
      backendID: try WorkflowBackendID("backend-v4"),
      backendRevisionID: try WorkflowBackendRevisionID("p06-v4"),
      mediaContractID: try WorkflowMediaContractID(
        workflowQueueDigest(index + 6)
      )
    )
    return WorkflowJobSpecification(
      jobID: try WorkflowJobID("job-\(index)"),
      requestID: try WorkflowRequestID(workflowQueueDigest(index + 7)),
      source: WorkflowSourceSpecification(
        identityID: try WorkflowSourceIdentityID(
          workflowQueueDigest(index + 8)
        ),
        bookmark: source
      ),
      output: WorkflowOutputSpecification(
        contractID: try WorkflowOutputContractID(
          workflowQueueDigest(index + 9)
        ),
        directoryBookmark: output,
        fileName: try WorkflowOutputFileName("output-\(index).mov")
      ),
      runtimeBinding: runtime
    )
  }
}

private func workflowQueueDigest(_ value: Int) -> String {
  String(format: "%064llx", value)
}

private enum WorkflowQueueSchemaFixtureErrorV4: Error {
  case topLevelSchemaNotFound
}

private func replacingQueueTopLevelSchemaVersion(
  in data: Data,
  from oldVersion: UInt16,
  to newVersion: UInt16
) throws -> Data {
  guard var text = String(data: data, encoding: .utf8),
    let range = text.range(
      of: "\"schemaVersion\":\(oldVersion)",
      options: .backwards
    ),
    text[range.upperBound...] == "}"
  else {
    throw WorkflowQueueSchemaFixtureErrorV4.topLevelSchemaNotFound
  }
  text.replaceSubrange(
    range,
    with: "\"schemaVersion\":\(newVersion)"
  )
  return Data(text.utf8)
}
