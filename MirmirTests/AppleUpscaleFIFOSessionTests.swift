import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir
// swiftlint:disable file_length
final class AppleUpscaleFIFOSessionTests: XCTestCase {
    func testConcurrentSubmissionsRemainFIFOAcrossDriverSuspension() async throws {
        let route = try makeFIFOTestRoute("r02.fixture.fifo")
        let driver = try ControlledAppleUpscaleSessionDriver(
            route: route,
            blockedSequences: [0, 1]
        )
        let admissions = AppleUpscaleAdmissionProbe()
        let session = try AppleUpscaleFIFOSession(
            identity: route,
            driver: driver,
            admissionObserver: admissions.observer
        )
        let first = try makeFIFOTestFrame(sequence: 0, pts: 0)
        let second = try makeFIFOTestFrame(sequence: 1, pts: 1)

        let firstTask = Task { await session.submit(first.frame) }
        _ = await driver.waitForEventCount(1)
        let secondTask = Task { await session.submit(second.frame) }
        _ = await admissions.waitForCount(2)

        var snapshot = driver.snapshot()
        XCTAssertEqual(snapshot.events, [.processStarted(sequence: 0, generation: 0)])
        XCTAssertEqual(snapshot.activeProcessCount, 1)
        XCTAssertEqual(snapshot.maximumProcessConcurrency, 1)

        driver.release(sequence: 0)
        let orderedEvents = await driver.waitForEventCount(3)
        XCTAssertEqual(
            orderedEvents,
            [
                .processStarted(sequence: 0, generation: 0),
                .processCompleted(sequence: 0),
                .processStarted(sequence: 1, generation: 0)
            ]
        )
        driver.release(sequence: 1)

        guard case .processed(let firstOutput) = await firstTask.value,
              case .processed(let secondOutput) = await secondTask.value else {
            return XCTFail("Both FIFO submissions must produce processed outcomes")
        }
        snapshot = driver.snapshot()
        XCTAssertEqual(snapshot.maximumProcessConcurrency, 1)
        XCTAssertEqual(firstOutput.sequenceNumber, 0)
        XCTAssertEqual(secondOutput.sequenceNumber, 1)
        XCTAssertEqual(first.counter.value, 0)
        XCTAssertEqual(second.counter.value, 0)

        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 2)
        XCTAssertEqual(summary.processedFrameCount, 2)
        XCTAssertEqual(summary.terminalizationCount, 1)
        XCTAssertEqual(driver.snapshot().finishCount, 1)

        firstOutput.resourceLifetimeToken.release()
        secondOutput.resourceLifetimeToken.release()
        XCTAssertEqual(first.counter.value, 1)
        XCTAssertEqual(second.counter.value, 1)
    }

    func testResetOrdersBetweenSubmissionsAndAdvancesOnlyHistoryGeneration() async throws {
        let route = try makeFIFOTestRoute("r02.fixture.reset")
        let driver = try ControlledAppleUpscaleSessionDriver(
            route: route,
            blockedSequences: [0, 1]
        )
        let admissions = AppleUpscaleAdmissionProbe()
        let session = try AppleUpscaleFIFOSession(
            identity: route,
            driver: driver,
            admissionObserver: admissions.observer
        )
        let first = try makeFIFOTestFrame(sequence: 0, pts: 0)
        let second = try makeFIFOTestFrame(sequence: 1, pts: 1)

        let firstTask = Task { await session.submit(first.frame) }
        _ = await driver.waitForEventCount(1)
        let resetTask = Task { await session.reset(reason: .sceneCut) }
        _ = await admissions.waitForCount(2)
        let secondTask = Task { await session.submit(second.frame) }
        _ = await admissions.waitForCount(3)

        driver.release(sequence: 0)
        let orderedEvents = await driver.waitForEventCount(4)
        XCTAssertEqual(
            orderedEvents,
            [
                .processStarted(sequence: 0, generation: 0),
                .processCompleted(sequence: 0),
                .reset(reason: .sceneCut, nextGeneration: 1),
                .processStarted(sequence: 1, generation: 1)
            ]
        )
        driver.release(sequence: 1)
        _ = await firstTask.value
        await resetTask.value
        _ = await secondTask.value

        let duplicate = try makeFIFOTestFrame(sequence: 1, pts: 2)
        let duplicateOutcome = await session.submit(duplicate.frame)
        assertFIFORejected(
            duplicateOutcome,
            reason: .duplicateOrNonIncreasingSequence,
            route: route
        )
        XCTAssertEqual(duplicate.counter.value, 1)
        XCTAssertEqual(driver.snapshot().processStartSequences, [0, 1])

        _ = await session.finish()
        first.frame.resourceLifetimeToken.release()
        second.frame.resourceLifetimeToken.release()
    }

    func testFinishFencesAdmissionDrainsAndCachesOneFinalization() async throws {
        let route = try makeFIFOTestRoute("r02.fixture.finish")
        let driver = try ControlledAppleUpscaleSessionDriver(
            route: route,
            blockedSequences: [0]
        )
        let admissions = AppleUpscaleAdmissionProbe()
        let session = try AppleUpscaleFIFOSession(
            identity: route,
            driver: driver,
            admissionObserver: admissions.observer
        )
        let admitted = try makeFIFOTestFrame(sequence: 0, pts: 0)
        let fenced = try makeFIFOTestFrame(sequence: 1, pts: 1)

        let submitTask = Task { await session.submit(admitted.frame) }
        _ = await driver.waitForEventCount(1)
        let firstFinish = Task { await session.finish() }
        _ = await admissions.waitForCount(2)
        let cancelAfterFinishFence = Task { await session.cancel() }
        _ = await admissions.waitForCount(3)

        let fencedOutcome = await session.submit(fenced.frame)
        assertFIFORejected(fencedOutcome, reason: .admissionClosed, route: route)
        XCTAssertEqual(fenced.counter.value, 1)
        let secondFinish = Task { await session.finish() }
        _ = await admissions.waitForCount(5)
        XCTAssertEqual(driver.snapshot().finishCount, 0)
        XCTAssertEqual(driver.snapshot().cancelCount, 0)

        driver.release(sequence: 0)
        guard case .processed(let output) = await submitTask.value else {
            return XCTFail("The pre-fence submission must drain")
        }
        let firstSummary = await firstFinish.value
        let secondSummary = await secondFinish.value
        await cancelAfterFinishFence.value
        let cachedSummary = await session.finish()

        XCTAssertEqual(firstSummary, secondSummary)
        XCTAssertEqual(firstSummary, cachedSummary)
        XCTAssertEqual(firstSummary.submittedFrameCount, 1)
        XCTAssertEqual(firstSummary.processedFrameCount, 1)
        XCTAssertEqual(firstSummary.terminalizationCount, 1)
        XCTAssertEqual(driver.snapshot().finishCount, 1)
        XCTAssertEqual(driver.snapshot().cancelCount, 0)

        output.resourceLifetimeToken.release()
        XCTAssertEqual(admitted.counter.value, 1)
    }

    func testCancelUnblocksActiveDriverRejectsQueueAndDiscardsLateSuccess() async throws {
        let route = try makeFIFOTestRoute("r02.fixture.cancel")
        let lateOutputCounter = AppleUpscaleReleaseCounter()
        let lateOutputToken = try AppleUpscaleResourceLifetimeToken(
            identity: "fifo.cancel.output-token",
            releaseAction: { lateOutputCounter.increment() }
        )
        let driver = try ControlledAppleUpscaleSessionDriver(
            route: route,
            blockedSequences: [0],
            modes: [0: .processed(token: lateOutputToken, identity: nil)]
        )
        let admissions = AppleUpscaleAdmissionProbe()
        let session = try AppleUpscaleFIFOSession(
            identity: route,
            driver: driver,
            admissionObserver: admissions.observer
        )
        let active = try makeFIFOTestFrame(sequence: 0, pts: 0)
        let queued = try makeFIFOTestFrame(sequence: 1, pts: 1)

        let activeTask = Task { await session.submit(active.frame) }
        _ = await driver.waitForEventCount(1)
        let queuedTask = Task { await session.submit(queued.frame) }
        _ = await admissions.waitForCount(2)
        let resetTask = Task { await session.reset(reason: .discontinuity) }
        _ = await admissions.waitForCount(3)
        let cancelCompletion = AppleUpscaleCompletionProbe()
        let cancelTask = Task {
            await session.cancel()
            cancelCompletion.markCompleted()
            driver.recordSessionCancellationCompleted()
        }
        _ = await admissions.waitForCount(4)

        let queuedOutcome = await queuedTask.value
        assertFIFORejected(queuedOutcome, reason: .operationCancelled, route: route)
        await resetTask.value
        XCTAssertEqual(queued.counter.value, 1)
        XCTAssertTrue(try XCTUnwrap(driver.snapshot().signals[0]).isCancelled)
        XCTAssertFalse(driver.snapshot().events.contains(.reset(
            reason: .discontinuity,
            nextGeneration: 1
        )))

        let cancellationEvents = await driver.waitForEventCount(4)
        XCTAssertEqual(
            cancellationEvents,
            [
                .processStarted(sequence: 0, generation: 0),
                .cancel,
                .processCompleted(sequence: 0),
                .sessionCancellationCompleted
            ]
        )
        let activeOutcome = await activeTask.value
        assertFIFORejected(activeOutcome, reason: .operationCancelled, route: route)
        await cancelTask.value

        XCTAssertTrue(cancelCompletion.isCompleted)
        XCTAssertEqual(driver.snapshot().activeProcessCount, 0)
        XCTAssertEqual(active.counter.value, 1)
        XCTAssertEqual(lateOutputCounter.value, 1)
        XCTAssertEqual(driver.snapshot().cancelCount, 1)
        XCTAssertEqual(driver.snapshot().finishCount, 0)

        await session.cancel()
        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 0)
        XCTAssertEqual(summary.terminalizationCount, 1)
        XCTAssertEqual(driver.snapshot().cancelCount, 1)
    }

    func testSequenceAndTimingValidationRejectBeforeDriverInvocation() async throws {
        let route = try makeFIFOTestRoute("r02.fixture.validation")
        let driver = try ControlledAppleUpscaleSessionDriver(route: route)
        let session = try AppleUpscaleFIFOSession(identity: route, driver: driver)
        let first = try makeFIFOTestFrame(sequence: 0, pts: 0)
        let duplicate = try makeFIFOTestFrame(sequence: 0, pts: 1)
        let nonmonotonicPTS = try makeFIFOTestFrame(sequence: 1, pts: 0)
        let second = try makeFIFOTestFrame(sequence: 1, pts: 2)

        guard case .processed(let firstOutput) = await session.submit(first.frame) else {
            return XCTFail("The first frame must be processed")
        }
        let duplicateOutcome = await session.submit(duplicate.frame)
        assertFIFORejected(
            duplicateOutcome,
            reason: .duplicateOrNonIncreasingSequence,
            route: route
        )
        let timingOutcome = await session.submit(nonmonotonicPTS.frame)
        assertFIFORejected(
            timingOutcome,
            reason: .nonIncreasingPresentationTimestamp,
            route: route
        )
        guard case .processed(let secondOutput) = await session.submit(second.frame) else {
            return XCTFail("Validation rejection must not consume the next sequence")
        }

        XCTAssertEqual(driver.snapshot().processStartSequences, [0, 1])
        XCTAssertEqual(duplicate.counter.value, 1)
        XCTAssertEqual(nonmonotonicPTS.counter.value, 1)

        let invalidCounter = AppleUpscaleReleaseCounter()
        let invalidToken = try AppleUpscaleResourceLifetimeToken(
            identity: "fifo.invalid-duration-token",
            releaseAction: { invalidCounter.increment() }
        )
        XCTAssertThrowsError(
            try makeFIFOTestFrame(
                sequence: 2,
                pts: 3,
                duration: .zero,
                token: invalidToken,
                counter: invalidCounter
            )
        ) { error in
            XCTAssertEqual(error as? AppleUpscaleContractError, .invalidDuration)
        }
        XCTAssertEqual(driver.snapshot().processStartSequences, [0, 1])

        _ = await session.finish()
        firstOutput.resourceLifetimeToken.release()
        secondOutput.resourceLifetimeToken.release()
        invalidToken.release()
        XCTAssertEqual(invalidCounter.value, 1)
    }

    func testFailureAndRejectionReleaseInputOwnershipExactlyOnce() async throws {
        let route = try makeFIFOTestRoute("r02.fixture.outcomes")
        let driver = try ControlledAppleUpscaleSessionDriver(
            route: route,
            modes: [0: .failed, 1: .rejected, 2: .unavailable]
        )
        let session = try AppleUpscaleFIFOSession(identity: route, driver: driver)
        let failed = try makeFIFOTestFrame(sequence: 0, pts: 0)
        let rejected = try makeFIFOTestFrame(sequence: 1, pts: 1)
        let unavailable = try makeFIFOTestFrame(sequence: 2, pts: 2)

        guard case .failed = await session.submit(failed.frame) else {
            return XCTFail("Expected injected failure")
        }
        guard case .rejected = await session.submit(rejected.frame) else {
            return XCTFail("Expected injected rejection")
        }
        guard case .unavailable = await session.submit(unavailable.frame) else {
            return XCTFail("Expected injected unavailability")
        }

        XCTAssertEqual(failed.counter.value, 1)
        XCTAssertEqual(rejected.counter.value, 1)
        XCTAssertEqual(unavailable.counter.value, 1)
        failed.frame.resourceLifetimeToken.release()
        rejected.frame.resourceLifetimeToken.release()
        unavailable.frame.resourceLifetimeToken.release()
        XCTAssertEqual(failed.counter.value, 1)
        XCTAssertEqual(rejected.counter.value, 1)
        XCTAssertEqual(unavailable.counter.value, 1)
        _ = await session.finish()
    }

    func testDriverRouteAndFallbackIdentityMismatchFailClosed() async throws {
        let route = try makeFIFOTestRoute("r02.fixture.identity")
        let otherRoute = try makeFIFOTestRoute("r02.fixture.identity-other")
        let mismatchedIdentity = try AppleUpscaleProcessingIdentity(
            route: otherRoute,
            fallbackHistory: []
        )
        let fallbackLink = try AppleUpscaleFallbackLink(
            failedRoute: otherRoute,
            selectedRoute: route,
            reasonCode: .backendFailed,
            selectedFallbackOrdinal: 0
        )
        let silentFallbackIdentity = try AppleUpscaleProcessingIdentity(
            route: route,
            fallbackHistory: [fallbackLink]
        )
        let mismatchedOutputCounter = AppleUpscaleReleaseCounter()
        let mismatchedOutputToken = try AppleUpscaleResourceLifetimeToken(
            identity: "fifo.identity.mismatched-output",
            releaseAction: { mismatchedOutputCounter.increment() }
        )
        let fallbackOutputCounter = AppleUpscaleReleaseCounter()
        let fallbackOutputToken = try AppleUpscaleResourceLifetimeToken(
            identity: "fifo.identity.fallback-output",
            releaseAction: { fallbackOutputCounter.increment() }
        )
        let driver = try ControlledAppleUpscaleSessionDriver(
            route: route,
            modes: [
                0: .processed(
                    token: mismatchedOutputToken,
                    identity: mismatchedIdentity
                ),
                1: .processed(
                    token: fallbackOutputToken,
                    identity: silentFallbackIdentity
                )
            ]
        )
        let session = try AppleUpscaleFIFOSession(identity: route, driver: driver)
        let first = try makeFIFOTestFrame(sequence: 0, pts: 0)
        let second = try makeFIFOTestFrame(sequence: 1, pts: 1)

        assertFIFOIdentityMismatch(await session.submit(first.frame), route: route)
        assertFIFOIdentityMismatch(await session.submit(second.frame), route: route)
        XCTAssertEqual(first.counter.value, 1)
        XCTAssertEqual(second.counter.value, 1)
        XCTAssertEqual(mismatchedOutputCounter.value, 1)
        XCTAssertEqual(fallbackOutputCounter.value, 1)

        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 2)
        XCTAssertEqual(summary.processedFrameCount, 0)
    }

}

private func assertFIFORejected(
    _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
    reason: AppleUpscaleFIFOSubmitRejectionReason,
    route: AppleUpscaleRouteIdentity,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .rejected(let rejection) = outcome else {
        return XCTFail("Expected rejected outcome", file: file, line: line)
    }
    XCTAssertEqual(rejection.reason, reason.rawValue, file: file, line: line)
    XCTAssertEqual(rejection.processingIdentity.route, route, file: file, line: line)
    XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
}

private func assertFIFOIdentityMismatch(
    _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
    route: AppleUpscaleRouteIdentity,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failed(let failure) = outcome else {
        return XCTFail("Expected failed-closed identity outcome", file: file, line: line)
    }
    XCTAssertEqual(failure.reason, "driver_identity_mismatch", file: file, line: line)
    XCTAssertEqual(failure.processingIdentity.route, route, file: file, line: line)
    XCTAssertTrue(failure.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
}

private enum ControlledAppleUpscaleDriverEvent: Equatable, Sendable {
    case processStarted(sequence: Int, generation: UInt64)
    case processCompleted(sequence: Int)
    case reset(reason: AppleUpscaleResetReason, nextGeneration: UInt64)
    case finish
    case cancel
    case sessionCancellationCompleted
}

private enum ControlledAppleUpscaleOutcomeMode: Sendable {
    case processedSameToken
    case processed(
        token: AppleUpscaleResourceLifetimeToken,
        identity: AppleUpscaleProcessingIdentity?
    )
    case unavailable
    case rejected
    case failed
}

private final class ControlledAppleUpscaleSessionDriver: AppleUpscaleSessionDriver,
    @unchecked Sendable {
    private struct EventWaiter {
        let count: Int
        let continuation: CheckedContinuation<[ControlledAppleUpscaleDriverEvent], Never>
    }

    private struct State {
        var events: [ControlledAppleUpscaleDriverEvent] = []
        var eventWaiters: [EventWaiter] = []
        var activeProcessCount = 0
        var maximumProcessConcurrency = 0
        var releasedSequences: Set<Int> = []
        var processContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
        var signals: [Int: AppleUpscaleOperationCancellationSignal] = [:]
        var cancellationRequested = false
        var finishCount = 0
        var cancelCount = 0
    }

    struct Snapshot {
        let events: [ControlledAppleUpscaleDriverEvent]
        let activeProcessCount: Int
        let maximumProcessConcurrency: Int
        let signals: [Int: AppleUpscaleOperationCancellationSignal]
        let finishCount: Int
        let cancelCount: Int

        var processStartSequences: [Int] {
            events.compactMap { event in
                guard case .processStarted(let sequence, _) = event else { return nil }
                return sequence
            }
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let blockedSequences: Set<Int>
    private let modes: [Int: ControlledAppleUpscaleOutcomeMode]

    init(
        route: AppleUpscaleRouteIdentity,
        blockedSequences: Set<Int> = [],
        modes: [Int: ControlledAppleUpscaleOutcomeMode] = [:]
    ) throws {
        processingIdentity = try AppleUpscaleProcessingIdentity(
            route: route,
            fallbackHistory: []
        )
        self.blockedSequences = blockedSequences
        self.modes = modes
    }

    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        state.withLock { state in
            state.activeProcessCount += 1
            state.maximumProcessConcurrency = max(
                state.maximumProcessConcurrency,
                state.activeProcessCount
            )
            state.signals[frame.sequenceNumber] = cancellation
        }
        record(.processStarted(
            sequence: frame.sequenceNumber,
            generation: historyGeneration
        ))
        await waitForReleaseIfNeeded(sequence: frame.sequenceNumber)
        state.withLock { $0.activeProcessCount -= 1 }
        record(.processCompleted(sequence: frame.sequenceNumber))

        return makeOutcome(
            mode: modes[frame.sequenceNumber] ?? .processedSameToken,
            frame: frame
        )
    }

    func reset(
        reason: AppleUpscaleResetReason,
        nextHistoryGeneration: UInt64,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) async {
        record(.reset(reason: reason, nextGeneration: nextHistoryGeneration))
    }

    func finish() async {
        state.withLock { $0.finishCount += 1 }
        record(.finish)
    }

    func cancel() async {
        let processContinuations = state.withLock { state -> [
            CheckedContinuation<Void, Never>
        ] in
            state.cancelCount += 1
            state.cancellationRequested = true
            let continuations = Array(state.processContinuations.values)
            state.processContinuations.removeAll(keepingCapacity: false)
            return continuations
        }
        record(.cancel)
        for continuation in processContinuations {
            continuation.resume()
        }
    }

    func waitForEventCount(_ count: Int) async -> [ControlledAppleUpscaleDriverEvent] {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> [ControlledAppleUpscaleDriverEvent]? in
                if state.events.count >= count { return state.events }
                state.eventWaiters.append(EventWaiter(
                    count: count,
                    continuation: continuation
                ))
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    func release(sequence: Int) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.releasedSequences.insert(sequence)
            return state.processContinuations.removeValue(forKey: sequence)
        }
        continuation?.resume()
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(
                events: state.events,
                activeProcessCount: state.activeProcessCount,
                maximumProcessConcurrency: state.maximumProcessConcurrency,
                signals: state.signals,
                finishCount: state.finishCount,
                cancelCount: state.cancelCount
            )
        }
    }

    func recordSessionCancellationCompleted() {
        record(.sessionCancellationCompleted)
    }

    private func waitForReleaseIfNeeded(sequence: Int) async {
        guard blockedSequences.contains(sequence) else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = state.withLock { state -> Bool in
                if state.releasedSequences.contains(sequence)
                    || state.cancellationRequested {
                    return true
                }
                state.processContinuations[sequence] = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func record(_ event: ControlledAppleUpscaleDriverEvent) {
        let deliveries = state.withLock { state -> [(
            CheckedContinuation<[ControlledAppleUpscaleDriverEvent], Never>,
            [ControlledAppleUpscaleDriverEvent]
        )] in
            state.events.append(event)
            var waiting: [EventWaiter] = []
            var ready: [(
                CheckedContinuation<[ControlledAppleUpscaleDriverEvent], Never>,
                [ControlledAppleUpscaleDriverEvent]
            )] = []
            for waiter in state.eventWaiters {
                if state.events.count >= waiter.count {
                    ready.append((waiter.continuation, state.events))
                } else {
                    waiting.append(waiter)
                }
            }
            state.eventWaiters = waiting
            return ready
        }
        for (continuation, events) in deliveries {
            continuation.resume(returning: events)
        }
    }

    private func makeOutcome(
        mode: ControlledAppleUpscaleOutcomeMode,
        frame: AppleUpscaleFrame
    ) -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        do {
            switch mode {
            case .processedSameToken:
                return .processed(try makeProcessedFrame(
                    from: frame,
                    token: frame.resourceLifetimeToken,
                    identity: processingIdentity
                ))
            case .processed(let token, let identity):
                return .processed(try makeProcessedFrame(
                    from: frame,
                    token: token,
                    identity: identity ?? processingIdentity
                ))
            case .unavailable:
                return .unavailable(try AppleUpscaleBackendUnavailable(
                    processingIdentity: processingIdentity,
                    reason: "injected_unavailable"
                ))
            case .rejected:
                return .rejected(try AppleUpscaleBackendRejected(
                    processingIdentity: processingIdentity,
                    reason: "injected_rejection"
                ))
            case .failed:
                return .failed(try AppleUpscaleBackendFailed(
                    processingIdentity: processingIdentity,
                    reason: "injected_failure"
                ))
            }
        } catch {
            preconditionFailure("Controlled driver fixture is invalid: \(error)")
        }
    }

    private func makeProcessedFrame(
        from frame: AppleUpscaleFrame,
        token: AppleUpscaleResourceLifetimeToken,
        identity: AppleUpscaleProcessingIdentity
    ) throws -> AppleUpscaleProcessedFrame {
        try AppleUpscaleProcessedFrame(
            sequenceNumber: frame.sequenceNumber,
            pixelBuffer: frame.pixelBuffer,
            presentationTimestamp: frame.presentationTimestamp,
            duration: frame.duration,
            colorDescription: frame.colorDescription,
            metadataIdentity: frame.metadataIdentity,
            resourceLifetimeToken: token,
            processingIdentity: identity
        )
    }
}

private final class AppleUpscaleAdmissionProbe: @unchecked Sendable {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<[AppleUpscaleFIFOSessionAdmission], Never>
    }

    private struct State {
        var admissions: [AppleUpscaleFIFOSessionAdmission] = []
        var waiters: [Waiter] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var observer: AppleUpscaleFIFOSessionAdmissionObserver {
        { [weak self] admission in self?.record(admission) }
    }

    func record(_ admission: AppleUpscaleFIFOSessionAdmission) {
        let deliveries = state.withLock { state -> [(
            CheckedContinuation<[AppleUpscaleFIFOSessionAdmission], Never>,
            [AppleUpscaleFIFOSessionAdmission]
        )] in
            state.admissions.append(admission)
            var waiting: [Waiter] = []
            var ready: [(
                CheckedContinuation<[AppleUpscaleFIFOSessionAdmission], Never>,
                [AppleUpscaleFIFOSessionAdmission]
            )] = []
            for waiter in state.waiters {
                if state.admissions.count >= waiter.count {
                    ready.append((waiter.continuation, state.admissions))
                } else {
                    waiting.append(waiter)
                }
            }
            state.waiters = waiting
            return ready
        }
        for (continuation, admissions) in deliveries {
            continuation.resume(returning: admissions)
        }
    }

    func waitForCount(_ count: Int) async -> [AppleUpscaleFIFOSessionAdmission] {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> [AppleUpscaleFIFOSessionAdmission]? in
                if state.admissions.count >= count { return state.admissions }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

private final class AppleUpscaleCompletionProbe: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isCompleted: Bool { state.withLock { $0 } }

    func markCompleted() {
        state.withLock { $0 = true }
    }
}

private final class AppleUpscaleReleaseCounter: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { state.withLock { $0 } }

    func increment() {
        state.withLock { $0 += 1 }
    }
}

private struct AppleUpscaleFrameFixture {
    let frame: AppleUpscaleFrame
    let counter: AppleUpscaleReleaseCounter
}
private func makeFIFOTestFrame(
    sequence: Int,
    pts: Int64,
    duration: CMTime = CMTime(value: 1, timescale: 30),
    token: AppleUpscaleResourceLifetimeToken? = nil,
    counter: AppleUpscaleReleaseCounter? = nil
) throws -> AppleUpscaleFrameFixture {
    let counter = counter ?? AppleUpscaleReleaseCounter()
    let token = try token ?? AppleUpscaleResourceLifetimeToken(
        identity: "fifo.frame-\(sequence).pts-\(pts).token",
        releaseAction: { counter.increment() }
    )
    return AppleUpscaleFrameFixture(
        frame: try AppleUpscaleFrame(
            sequenceNumber: sequence,
            pixelBuffer: makeFIFOTestPixelBuffer(),
            presentationTimestamp: CMTime(value: pts, timescale: 30),
            duration: duration,
            colorDescription: AppleUpscaleColorDescription(
                colorPrimaries: "ITU_R_709_2",
                transferFunction: "ITU_R_709_2",
                matrix: "ITU_R_709_2",
                chromaSiting: "left",
                range: .video
            ),
            metadataIdentity: AppleUpscaleMetadataIdentity(
                "fifo.frame-\(sequence).pts-\(pts)"
            ),
            resourceLifetimeToken: token
        ),
        counter: counter
    )
}

private func makeFIFOTestPixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        8,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return pixelBuffer
}

private func makeFIFOTestRoute(_ backendID: String) throws -> AppleUpscaleRouteIdentity {
    try AppleUpscaleRouteIdentity(
        backend: AppleUpscaleBackendIdentity(
            backendID: backendID,
            backendRevision: "1",
            modelAssetsIdentity: .notRequired
        ),
        configurationIdentity: "r02-fifo-session-v1",
        policyIdentity: "r02-fixture-only-v1",
        materialDecisionIdentity: "r02-fifo-session-decision-v1"
    )
}
// swiftlint:enable file_length
