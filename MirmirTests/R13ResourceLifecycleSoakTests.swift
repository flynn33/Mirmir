import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class R13ResourceLifecycleSoakTests: XCTestCase {
    func testSequentialJobsReleaseEveryFrameAndLeaveServiceReusable()
        async throws {
        let jobCount = 20
        let eventLog = R13ReleaseTestEventLog()
        let scenarios = try makeScenarios(
            jobCount: jobCount,
            eventLog: eventLog
        )

        let media = R13ResourceLifecycleSoakMediaPipeline(
            pipelines: scenarios.map(\.media)
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .processed,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            modeAwareSessionFactory: {
                [factory] route, modeBinding in
                try await factory.make(
                    route: route,
                    modeBinding: modeBinding
                )
            },
            inputReleaseObserver: { [eventLog] identity in
                eventLog.record("input.release.\(identity)")
            }
        )

        for (jobIndex, scenario) in scenarios.enumerated() {
            try await assertCompletedScenario(
                jobIndex: jobIndex,
                scenario: scenario,
                expectedRoutes: scenarios
                    .prefix(jobIndex + 1)
                    .map(\.route),
                media: media,
                factory: factory,
                service: service,
                eventLog: eventLog
            )
        }

        XCTAssertEqual(media.probeCount, jobCount)
        XCTAssertEqual(media.beginSessionCount, jobCount)
        XCTAssertEqual(media.pendingProbeCount, 0)
        XCTAssertEqual(factory.routes, scenarios.map(\.route))
        let diagnostics = await service.releaseDiagnosticsSnapshot()
        XCTAssertNil(diagnostics)
    }

    private func assertCompletedScenario(
        jobIndex: Int,
        scenario: R13ResourceLifecycleSoakScenario,
        expectedRoutes: [R03ScaleRoute],
        media: R13ResourceLifecycleSoakMediaPipeline,
        factory: R13ReleaseTestSessionFactory,
        service: R13ReleaseUpscalerEngineService,
        eventLog: R13ReleaseTestEventLog
    ) async throws {
        let identifier = "r13-lifecycle-soak-\(jobIndex)"
        let sourceFixtureDirectory =
            FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-lifecycle-source-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: sourceFixtureDirectory,
            withIntermediateDirectories: false
        )
        defer {
            try? FileManager.default.removeItem(
                at: sourceFixtureDirectory
            )
        }
        let inputURL = sourceFixtureDirectory.appendingPathComponent(
            "source.mp4",
            isDirectory: false
        )
        try Data(
            "mirmir-r13-lifecycle-source:\(identifier)".utf8
        ).write(
            to: inputURL,
            options: .atomic
        )
        let outputURL = URL(
            fileURLWithPath: "/tmp/\(identifier)-output.mp4"
        )
        let eventStartIndex = eventLog.events.count
        let handle = try service.submit(
            UpscaleJob(
                identifier: identifier,
                inputURL: inputURL,
                outputURL: outputURL,
                targetResolution: scenario.route.canonicalTargetResolution,
                preserveAudio: false,
                mode: scenario.mode
            )
        )

        let result = try await handle.waitForCompletion()
        var progressValues: [UpscaleProgress] = []
        for await progress in handle.progressStream {
            progressValues.append(progress)
        }

        XCTAssertEqual(result, outputURL, identifier)
        XCTAssertEqual(media.probeCount, jobIndex + 1, identifier)
        XCTAssertEqual(media.beginSessionCount, jobIndex + 1, identifier)
        XCTAssertEqual(media.pendingProbeCount, 0, identifier)
        XCTAssertEqual(scenario.media.probeCount, 1, identifier)
        XCTAssertEqual(scenario.media.beginSessionCount, 1, identifier)
        XCTAssertEqual(factory.routes, expectedRoutes, identifier)
        try await assertSessionLifetimes(
            scenario: scenario,
            factory: factory,
            identifier: identifier
        )
        try assertTerminalProgress(
            progressValues,
            frameCount: scenario.frameCount,
            identifier: identifier
        )

        let jobEvents = Array(
            eventLog.events.dropFirst(eventStartIndex)
        )
        XCTAssertEqual(
            jobEvents,
            expectedEvents(for: scenario),
            identifier
        )
    }

    private func assertSessionLifetimes(
        scenario: R13ResourceLifecycleSoakScenario,
        factory: R13ReleaseTestSessionFactory,
        identifier: String
    ) async throws {
        let expectedFrameIndices = Array(0..<scenario.frameCount)
        let mediaSession = try XCTUnwrap(
            scenario.media.lastSession,
            identifier
        )
        XCTAssertEqual(
            mediaSession.appendedFrameIndices,
            expectedFrameIndices,
            identifier
        )
        XCTAssertEqual(mediaSession.finishCount, 1, identifier)
        XCTAssertEqual(mediaSession.cancelCount, 0, identifier)

        let appleSession = try XCTUnwrap(
            factory.session(for: scenario.route),
            identifier
        )
        let appleSnapshot = await appleSession.snapshot()
        XCTAssertEqual(
            appleSnapshot.submittedSequenceNumbers,
            expectedFrameIndices,
            identifier
        )
        XCTAssertEqual(
            appleSnapshot.processedFrameCount,
            scenario.frameCount,
            identifier
        )
        XCTAssertEqual(appleSnapshot.finishCount, 1, identifier)
        XCTAssertEqual(appleSnapshot.cancelCount, 0, identifier)
    }

    private func assertTerminalProgress(
        _ progressValues: [UpscaleProgress],
        frameCount: Int,
        identifier: String
    ) throws {
        XCTAssertEqual(progressValues.count, 1, identifier)
        let terminalProgress = try XCTUnwrap(
            progressValues.first,
            identifier
        )
        XCTAssertEqual(
            terminalProgress.framesProcessed,
            frameCount,
            identifier
        )
        XCTAssertEqual(
            terminalProgress.totalFrames,
            frameCount,
            identifier
        )
        XCTAssertTrue(
            terminalProgress.throughputFPS.isFinite,
            identifier
        )
        XCTAssertGreaterThanOrEqual(
            terminalProgress.throughputFPS,
            0,
            identifier
        )
        XCTAssertEqual(
            try XCTUnwrap(terminalProgress.etaSeconds, identifier),
            0,
            identifier
        )
        XCTAssertEqual(
            terminalProgress.fraction,
            frameCount == 0 ? 0 : 1,
            identifier
        )
    }

    private func makeScenarios(
        jobCount: Int,
        eventLog: R13ReleaseTestEventLog
    ) throws -> [R13ResourceLifecycleSoakScenario] {
        let routes: [R03ScaleRoute] = [.scale3Over2, .scale2x]
        let modes: [UpscaleMode] = [.quality, .fast, .deterministic]
        return try (0..<jobCount).map { jobIndex in
            let route = routes[jobIndex % routes.count]
            let mode = modes[jobIndex % modes.count]
            let frameCount = jobIndex % 4
            let frames = try (0..<frameCount).map { frameIndex in
                try R13ReleaseTestFrames.make(
                    resolution: route.canonicalSourceResolution,
                    index: frameIndex
                )
            }
            return R13ResourceLifecycleSoakScenario(
                route: route,
                mode: mode,
                frameCount: frameCount,
                media: R13ReleaseTestMediaPipeline(
                    resolution: route.canonicalSourceResolution,
                    frames: frames,
                    eventLog: eventLog
                )
            )
        }
    }

    private func expectedEvents(
        for scenario: R13ResourceLifecycleSoakScenario
    ) -> [String] {
        var events = [
            "media.probe",
            "factory.\(scenario.route.rawValue)",
            "media.begin"
        ]
        for frameIndex in 0..<scenario.frameCount {
            let modeBinding = R13ReleaseModePolicy.binding(
                for: scenario.mode
            )
            events.append(contentsOf: [
                "media.next.\(frameIndex)",
                "apple.submit.\(frameIndex)",
                "input.release.r13.release.input."
                    + "\(modeBinding.backendID)."
                    + "\(scenario.mode.rawValue).\(frameIndex)",
                "media.append.\(frameIndex)",
                "output.release.\(frameIndex)"
            ])
        }
        events.append(contentsOf: [
            "media.eof",
            "apple.finish",
            "media.finish"
        ])
        return events
    }
}

private struct R13ResourceLifecycleSoakScenario {
    let route: R03ScaleRoute
    let mode: UpscaleMode
    let frameCount: Int
    let media: R13ReleaseTestMediaPipeline
}

private final class R13ResourceLifecycleSoakMediaPipeline:
    MediaPipelineService,
    @unchecked Sendable {
    private struct State {
        var nextProbeIndex = 0
        var pipelineBySourceURL: [URL: R13ReleaseTestMediaPipeline] = [:]
        var probeCount = 0
        var beginSessionCount = 0
    }

    private let pipelines: [R13ReleaseTestMediaPipeline]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(pipelines: [R13ReleaseTestMediaPipeline]) {
        self.pipelines = pipelines
    }

    var probeCount: Int {
        state.withLock { $0.probeCount }
    }

    var beginSessionCount: Int {
        state.withLock { $0.beginSessionCount }
    }

    var pendingProbeCount: Int {
        state.withLock { $0.pipelineBySourceURL.count }
    }

    func probe(url: URL) async throws -> SourceProfile {
        let pipeline = state.withLock { current
            -> R13ReleaseTestMediaPipeline? in
            guard current.nextProbeIndex < pipelines.count else {
                return nil
            }
            let pipeline = pipelines[current.nextProbeIndex]
            current.nextProbeIndex += 1
            current.probeCount += 1
            current.pipelineBySourceURL[url.standardizedFileURL] = pipeline
            return pipeline
        }
        guard let pipeline else {
            throw R13ResourceLifecycleSoakTestError.unexpectedProbe
        }
        return try await pipeline.probe(url: url)
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        let pipeline = state.withLock { current
            -> R13ReleaseTestMediaPipeline? in
            let pipeline = current.pipelineBySourceURL.removeValue(
                forKey: source.url.standardizedFileURL
            )
            if pipeline != nil {
                current.beginSessionCount += 1
            }
            return pipeline
        }
        guard let pipeline else {
            throw R13ResourceLifecycleSoakTestError.missingProbe
        }
        return try await pipeline.beginSession(
            source: source,
            output: output
        )
    }

    func start() {}
    func stop() {}
}

private enum R13ResourceLifecycleSoakTestError: Error {
    case unexpectedProbe
    case missingProbe
}
