import Darwin
import Foundation
import os.lock
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

    func testGeometryFailureDiagnosticCapturesActualAndExpectedDimensions()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let decodedResolution = VideoResolution(
            width: 1_440,
            height: 1_080
        )
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p1080,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: decodedResolution,
                    index: 0
                )
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let diagnostics = MirmirDiagnosticStore()
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            diagnostics: diagnostics
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-decoded-geometry-mismatch",
                target: .p2160,
                mode: .deterministic
            )
        )

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Decoded geometry mismatch must fail normalization.")
        } catch let error as R03NV12ScalingError {
            XCTAssertEqual(
                error,
                .invalidDimensions(
                    expectedWidth: 1_920,
                    expectedHeight: 1_080,
                    actualWidth: 1_440,
                    actualHeight: 1_080
                )
            )
        } catch {
            XCTFail("Unexpected engine error: \(error)")
        }

        let mismatch = try await waitForDiagnostic(
            code: "release_first_decoded_frame_geometry_mismatch",
            in: diagnostics
        )
        let frameFailure = try await waitForDiagnostic(
            code: "release_frame_processing_failed",
            in: diagnostics
        )
        let mismatchFields = Dictionary(
            uniqueKeysWithValues: mismatch.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        let failureFields = Dictionary(
            uniqueKeysWithValues: frameFailure.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )

        XCTAssertEqual(
            mismatchFields["actual_decoded_dimensions"],
            "1440x1080"
        )
        XCTAssertEqual(
            mismatchFields["expected_normalized_dimensions"],
            "1920x1080"
        )
        XCTAssertEqual(
            failureFields["actual_decoded_dimensions"],
            "1440x1080"
        )
        XCTAssertEqual(
            failureFields["expected_normalized_dimensions"],
            "1920x1080"
        )
        XCTAssertEqual(
            failureFields["error_actual_dimensions"],
            "1440x1080"
        )
        XCTAssertEqual(
            failureFields["error_expected_dimensions"],
            "1920x1080"
        )
        XCTAssertEqual(failureFields["failure_category"], "invalid_dimensions")

        let snapshot = try await diagnostics.snapshot()
        let terminalCodes = snapshot.records.map(\.event.code.rawValue).filter {
            [
                "release_job_completed",
                "release_job_cancelled",
                "release_job_failed"
            ].contains($0)
        }
        XCTAssertEqual(terminalCodes, ["release_job_failed"])
        let appleSession = try XCTUnwrap(factory.session(for: .scale2x))
        let appleSnapshot = await appleSession.snapshot()
        XCTAssertEqual(appleSnapshot.submittedSequenceNumbers, [])
        XCTAssertGreaterThanOrEqual(appleSnapshot.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(media.lastSession).cancelCount,
            1
        )
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

    func testConcurrentSubmissionDiagnosticCapturesActiveState() async throws {
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
        let diagnostics = MirmirDiagnosticStore()
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            diagnostics: diagnostics
        )
        let activeHandle = try service.submit(
            makeJob(
                identifier: "r13-active-diagnostic",
                target: .p1080,
                mode: .quality
            )
        )
        try await waitForEvent("apple.submit.0", in: eventLog)

        XCTAssertThrowsError(
            try service.submit(
                makeJob(
                    identifier: "r13-rejected-diagnostic",
                    target: .p1080,
                    mode: .fast
                )
            )
        ) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .jobAlreadyRunning = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let rejected = try await waitForDiagnostic(
            code: "release_job_submit_rejected_already_running",
            in: diagnostics
        )
        let expectedStateField = try MirmirDiagnosticField(
            key: "active_job_state",
            value: MirmirDiagnosticFieldValue.identifier("active")
        )
        XCTAssertEqual(rejected.event.severity, .warning)
        XCTAssertTrue(rejected.event.fields.contains(expectedStateField))

        activeHandle.cancel()
        do {
            _ = try await activeHandle.waitForCompletion()
            XCTFail("Cancellation must terminate the release job.")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        let snapshot = try await diagnostics.snapshot()
        let terminalCodes = snapshot.records.map(\.event.code.rawValue).filter {
            [
                "release_job_completed",
                "release_job_cancelled",
                "release_job_failed"
            ].contains($0)
        }
        XCTAssertEqual(terminalCodes, ["release_job_cancelled"])
    }

    func testHeldDiagnosticJournalLockDoesNotStallJobOrRetainActiveState()
        async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-diagnostic-lock-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let diagnostics = try MirmirDiagnosticStore(
            persistentDirectoryURL: directoryURL
        )
        let lockURL = directoryURL.appendingPathComponent(
            MirmirDiagnosticStore.lockFileName,
            isDirectory: false
        )
        var lockDescriptor = open(
            lockURL.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard lockDescriptor >= 0 else {
            return XCTFail("Unable to open the diagnostic journal lock.")
        }
        defer {
            if lockDescriptor >= 0 {
                _ = flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)
            }
        }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            return XCTFail("Unable to acquire the diagnostic journal lock.")
        }

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
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            },
            diagnostics: diagnostics
        )
        let handle = try service.submit(
            makeJob(
                identifier: "r13-diagnostic-lock-independence",
                target: .p1080,
                mode: .deterministic
            )
        )
        let completionState = OSAllocatedUnfairLock(
            initialState: R13BoundedJobCompletion.pending
        )
        let completed = expectation(
            description: "Job completes while diagnostic flock remains held."
        )
        let completionTask = Task {
            do {
                let outputURL = try await handle.waitForCompletion()
                completionState.withLock {
                    $0 = .success(outputURL)
                }
            } catch {
                let identity = error as NSError
                completionState.withLock {
                    $0 = .failure(
                        domain: identity.domain,
                        code: identity.code
                    )
                }
            }
            completed.fulfill()
        }
        defer { completionTask.cancel() }

        await fulfillment(of: [completed], timeout: 2)

        switch completionState.withLock({ $0 }) {
        case .pending:
            XCTFail("The job did not terminate before the diagnostic timeout.")
        case .failure(let domain, let code):
            XCTFail("The job failed with \(domain) error \(code).")
        case .success(let outputURL):
            XCTAssertEqual(
                outputURL.lastPathComponent,
                "r13-diagnostic-lock-independence.mp4"
            )
        }
        let activeStateIsIdle = service.activeJobState.withLock { state in
            if case .idle = state {
                return true
            }
            return false
        }
        XCTAssertTrue(
            activeStateIsIdle,
            "Diagnostic persistence retained the active-job reservation."
        )

        XCTAssertEqual(flock(lockDescriptor, LOCK_UN), 0)
        close(lockDescriptor)
        lockDescriptor = -1
        await diagnostics.diagnosticSubmissionQueue.flush()
        let snapshot = try await diagnostics.snapshot()
        XCTAssertEqual(
            snapshot.records.filter {
                $0.event.code.rawValue == "release_job_completed"
            }.count,
            1
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

    private func waitForDiagnostic(
        code: String,
        in store: MirmirDiagnosticStore
    ) async throws -> MirmirDiagnosticRecord {
        for _ in 0..<200 {
            let snapshot = try await store.snapshot()
            if let record = snapshot.records.first(
                where: { $0.event.code.rawValue == code }
            ) {
                return record
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let snapshot = try await store.snapshot()
        return try XCTUnwrap(
            snapshot.records.first {
                $0.event.code.rawValue == code
            },
            "Timed out waiting for diagnostic \(code)."
        )
    }
}

private enum R13BoundedJobCompletion: Sendable {
    case pending
    case success(URL)
    case failure(domain: String, code: Int)
}
