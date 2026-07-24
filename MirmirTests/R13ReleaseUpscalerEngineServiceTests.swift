import Foundation
import XCTest
@testable import Mirmir

final class R13ReleaseUpscalerEngineServiceTests: XCTestCase {
    func testModeAvailabilityKeepsAutoVisibleButUnavailable() {
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
        let service = makeService(media: media, factory: factory)

        XCTAssertEqual(service.availability, .available)
        XCTAssertEqual(
            service.availability(for: .auto),
            .unavailable(reason: R13ReleaseModePolicy.autoUnavailableReason)
        )
        for mode in [UpscaleMode.quality, .fast, .deterministic] {
            XCTAssertEqual(service.availability(for: mode), .available)
        }
    }

    func testAutoRejectsBeforeMediaProbeJobAdmissionOrBackendFactory() async throws {
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
        let service = makeService(media: media, factory: factory)

        XCTAssertThrowsError(
            try service.submit(
                makeJob(
                    identifier: "r13-auto",
                    target: .p1080,
                    mode: .auto
                )
            )
        ) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .modeUnavailable(let mode, let reason) = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(mode, .auto)
            XCTAssertEqual(reason, R13ReleaseModePolicy.autoUnavailableReason)
        }
        XCTAssertEqual(media.probeCount, 0)
        XCTAssertEqual(media.beginSessionCount, 0)
        XCTAssertTrue(factory.routes.isEmpty)
        XCTAssertTrue(eventLog.events.isEmpty)

        let deterministic = try service.submit(
            makeJob(
                identifier: "r13-after-auto",
                target: .p1080,
                mode: .deterministic
            )
        )
        _ = try await deterministic.waitForCompletion()
        XCTAssertEqual(factory.routes, [.scale3Over2])
    }

    func testInvalidJobIdentifierRejectsBeforeMediaOrBackendWork() {
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
        let service = makeService(media: media, factory: factory)

        XCTAssertThrowsError(
            try service.submit(
                makeJob(
                    identifier: "../unsafe",
                    target: .p1080,
                    mode: .quality
                )
            )
        ) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .invalidJobIdentifier(let identifier) = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(identifier, "../unsafe")
        }
        XCTAssertEqual(media.probeCount, 0)
        XCTAssertTrue(factory.routes.isEmpty)
    }

    func testAllEnabledModesUseExactCanonicalA11RoutesAndStableTransactionID() async throws {
        for route in R03ScaleRoute.allCases {
            for mode in [UpscaleMode.quality, .fast, .deterministic] {
                let eventLog = R13ReleaseTestEventLog()
                let media = R13ReleaseTestMediaPipeline(
                    resolution: route.canonicalSourceResolution,
                    frames: [],
                    eventLog: eventLog
                )
                let factory = R13ReleaseTestSessionFactory(
                    behavior: .processed,
                    eventLog: eventLog
                )
                let service = makeService(media: media, factory: factory)
                let identifier = "r13-\(route.rawValue)-\(mode.rawValue)"
                let handle = try service.submit(
                    makeJob(
                        identifier: identifier,
                        target: route.canonicalTargetResolution,
                        mode: mode
                    )
                )

                let result = try await handle.waitForCompletion()

                XCTAssertEqual(result.lastPathComponent, "\(identifier).mp4")
                XCTAssertEqual(factory.routes, [route])
                let mediaSession = try XCTUnwrap(media.lastSession)
                XCTAssertEqual(
                    mediaSession.outputProfile.transactionIdentifier,
                    identifier
                )
                XCTAssertEqual(mediaSession.finishCount, 1)
                XCTAssertEqual(mediaSession.cancelCount, 0)
                let appleSession = try XCTUnwrap(factory.session(for: route))
                let snapshot = await appleSession.snapshot()
                XCTAssertEqual(snapshot.finishCount, 1)
                XCTAssertEqual(snapshot.cancelCount, 0)
            }
        }
    }

    func testFrameLoopPreservesFIFOAndReleasesInputAndOutputLifetimes() async throws {
        let eventLog = R13ReleaseTestEventLog()
        let frames = try [
            R13ReleaseTestFrames.make(resolution: .p720, index: 0),
            R13ReleaseTestFrames.make(resolution: .p720, index: 1)
        ]
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: frames,
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
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
            makeJob(
                identifier: "r13-fifo",
                target: .p1080,
                mode: .fast
            )
        )

        _ = try await handle.waitForCompletion()

        let mediaSession = try XCTUnwrap(media.lastSession)
        XCTAssertEqual(mediaSession.appendedFrameIndices, [0, 1])
        let appleSession = try XCTUnwrap(factory.session(for: .scale3Over2))
        let snapshot = await appleSession.snapshot()
        XCTAssertEqual(snapshot.submittedSequenceNumbers, [0, 1])
        XCTAssertEqual(snapshot.processedFrameCount, 2)
        XCTAssertEqual(snapshot.finishCount, 1)

        let events = eventLog.events
        for index in 0...1 {
            assertOrdered(
                [
                    "apple.submit.\(index)",
                    "input.release.r13.a11.input.fast.\(index)",
                    "media.append.\(index)",
                    "output.release.\(index)"
                ],
                in: events
            )
        }
        XCTAssertFalse(events.contains("media.cancel"))
    }

    func testCancellationCancelsBothSessionsAndReleasesPendingInput() async throws {
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
            makeJob(
                identifier: "r13-cancel",
                target: .p1080,
                mode: .quality
            )
        )
        try await waitForEvent("apple.submit.0", in: eventLog)

        handle.cancel()

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Cancellation must terminate the release job.")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        let mediaSession = try XCTUnwrap(media.lastSession)
        XCTAssertGreaterThanOrEqual(mediaSession.cancelCount, 1)
        XCTAssertTrue(mediaSession.appendedFrameIndices.isEmpty)
        let appleSession = try XCTUnwrap(factory.session(for: .scale3Over2))
        let snapshot = await appleSession.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.cancelCount, 1)
        XCTAssertTrue(
            eventLog.contains("input.release.r13.a11.input.quality.0")
        )
        XCTAssertFalse(eventLog.contains("output.release.0"))
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

    private func makeJob(
        identifier: String,
        target: VideoResolution,
        mode: UpscaleMode
    ) -> UpscaleJob {
        UpscaleJob(
            identifier: identifier,
            inputURL: URL(fileURLWithPath: "/tmp/\(identifier)-input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/\(identifier).mp4"),
            targetResolution: target,
            preserveAudio: false,
            mode: mode
        )
    }

    private func assertOrdered(
        _ orderedEvents: [String],
        in events: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previousIndex = -1
        for event in orderedEvents {
            guard let index = events.firstIndex(of: event) else {
                XCTFail("Missing event \(event): \(events)", file: file, line: line)
                return
            }
            XCTAssertGreaterThan(
                index,
                previousIndex,
                "Out-of-order event \(event): \(events)",
                file: file,
                line: line
            )
            previousIndex = index
        }
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
