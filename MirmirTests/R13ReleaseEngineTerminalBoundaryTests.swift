import Foundation
import XCTest
@testable import Mirmir

final class R13ReleaseEngineTerminalBoundaryTests: XCTestCase {
    func testHandleCancellationReturnsWhileMediaCleanupIsBlocked()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let finishBarrier = R13ReleaseSynchronousStartBarrier()
        let cleanupBarrier = R13ReleaseSynchronousStartBarrier()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog,
            finishObserver: {
                finishBarrier.enterAndWait()
            },
            cancelObserver: {
                cleanupBarrier.enterAndWait()
            }
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(media: media, factory: factory)
        let handle = try service.submit(
            makeJob(identifier: "r13-nonblocking-cancel")
        )
        defer {
            cleanupBarrier.release()
            finishBarrier.release()
        }
        try await waitForBarrier(finishBarrier)

        let cancelReturned = expectation(
            description: "The job handle returns before cleanup completes."
        )
        Task.detached {
            handle.cancel()
            cancelReturned.fulfill()
        }
        await fulfillment(of: [cancelReturned], timeout: 0.5)
        try await waitForBarrier(cleanupBarrier)

        cleanupBarrier.release()
        finishBarrier.release()
        _ = try? await handle.waitForCompletion()
    }

    func testCancellationAndCleanupErrorAfterPublishDoNotReportJobFailure()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let finishBarrier = R13ReleaseSynchronousStartBarrier()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog,
            terminalCleanupError: .partialCleanupFailed(
                URL(fileURLWithPath: "/tmp/r13-published-cleanup.tmp"),
                "injected_postpublication_cleanup_failure"
            ),
            finishObserver: {
                finishBarrier.enterAndWait()
            }
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = makeService(media: media, factory: factory)
        let handle = try service.submit(
            makeJob(identifier: "r13-published-success-boundary")
        )
        defer { finishBarrier.release() }
        try await waitForBarrier(finishBarrier)

        handle.cancel()
        finishBarrier.release()
        let output = try await handle.waitForCompletion()

        XCTAssertEqual(
            output.lastPathComponent,
            "r13-published-success-boundary.mp4"
        )
        let session = try XCTUnwrap(media.lastSession)
        XCTAssertEqual(session.finishCount, 1)
        XCTAssertGreaterThanOrEqual(session.cancelCount, 1)
    }

    func testStopBeforeHandleStartCancelsWithoutBeginningProductWork()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let startBarrier = R13ReleaseSynchronousStartBarrier()
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            beforeHandleStart: {
                startBarrier.enterAndWait()
            }
        )
        let job = makeJob(identifier: "r13-stop-before-start")
        let submission = Task.detached {
            try service.submit(job)
        }
        defer { startBarrier.release() }
        try await waitForBarrier(startBarrier)

        service.stop()
        startBarrier.release()
        let handle = try await submission.value

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("A stop received before start must cancel the job.")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        XCTAssertEqual(media.probeCount, 0)
        XCTAssertEqual(media.beginSessionCount, 0)
        XCTAssertTrue(factory.routes.isEmpty)
        XCTAssertTrue(eventLog.events.isEmpty)
    }

    func testStopCancelsTheActiveJobAndBothOwnedSessions() async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(resolution: .p720, index: 0)
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .suspendUntilCancelled,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            inputReleaseObserver: { [eventLog] identity in
                eventLog.record("input.release.\(identity)")
            }
        )
        let handle = try service.submit(
            makeJob(identifier: "r13-service-stop")
        )
        try await waitForEvent("apple.submit.0", in: eventLog)

        service.stop()

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Stopping the service must cancel its active job.")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        let mediaSession = try XCTUnwrap(media.lastSession)
        XCTAssertGreaterThanOrEqual(mediaSession.cancelCount, 1)
        let appleSession = try XCTUnwrap(
            factory.session(for: .scale3Over2)
        )
        let snapshot = await appleSession.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.cancelCount, 1)
        let modeBinding = R13ReleaseModePolicy.binding(
            for: .deterministic
        )
        XCTAssertTrue(
            eventLog.contains(
                "input.release.r13.release.input."
                    + "\(modeBinding.backendID).deterministic.0"
            )
        )
    }

    private func makeService(
        media: R13ReleaseTestMediaPipeline,
        factory: R13ReleaseTestSessionFactory
    ) -> R13ReleaseUpscalerEngineService {
        R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            }
        )
    }

    private func makeJob(identifier: String) -> UpscaleJob {
        UpscaleJob(
            identifier: identifier,
            inputURL: URL(fileURLWithPath: "/tmp/\(identifier)-input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/\(identifier).mp4"),
            targetResolution: .p1080,
            preserveAudio: false,
            mode: .deterministic
        )
    }

    private func waitForBarrier(
        _ barrier: R13ReleaseSynchronousStartBarrier
    ) async throws {
        for _ in 0..<200 where !barrier.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(barrier.hasEntered)
    }

    private func waitForEvent(
        _ event: String,
        in eventLog: R13ReleaseTestEventLog
    ) async throws {
        for _ in 0..<200 {
            if eventLog.contains(event) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(event). Events: \(eventLog.events)")
    }
}
