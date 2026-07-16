import Foundation
import os.lock
@testable import Mirmir
import XCTest

final class ASHTelemetryTests: XCTestCase {
    @available(macOS 15.4, *)
    func test_sequentialEngineSubmissionsUseDistinctTelemetryRecorders() async throws {
        let capture = TelemetryFactoryCapture()
        let media = TelemetryScopingNoopMediaPipeline(capture: capture)
        let service = DefaultUpscalerEngineService(
            media: media,
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            telemetryFactory: { capture.makeRecorder() }
        )

        let first = try service.submit(makeNoFrameJob(id: "first"))
        _ = try await first.waitForCompletion()
        let second = try service.submit(makeNoFrameJob(id: "second"))
        _ = try await second.waitForCompletion()

        let identities = capture.identities
        XCTAssertEqual(identities.created.count, 2)
        XCTAssertEqual(Set(identities.created).count, 2)
        XCTAssertEqual(identities.scoped, identities.created)
    }

    @available(macOS 15.4, *)
    func test_productionTraceFixtureWhenExplicitlyConfigured() async throws {
        let configurationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-production-trace-config.json")
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw XCTSkip("Production trace fixture is enabled only for the G01 evidence run")
        }
        let configuration = try JSONDecoder().decode(
            ProductionTraceConfiguration.self,
            from: Data(contentsOf: configurationURL)
        )
        let inputURL = URL(fileURLWithPath: configuration.inputPath)
        let outputURL = URL(fileURLWithPath: configuration.outputPath)
        let telemetryURL = URL(fileURLWithPath: configuration.telemetryPath)
        let targetResolution = VideoResolution(
            width: configuration.targetWidth ?? VideoResolution.p2160.width,
            height: configuration.targetHeight ?? VideoResolution.p2160.height
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: inputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(targetResolution == .p1080 || targetResolution == .p2160)

        let telemetry = DefaultASHTelemetryRecorder(
            emitsSignposts: configuration.emitsSignposts ?? true
        )
        let metal = try DefaultMetalRenderingService()
        let media = AVFoundationMediaPipeline(metal: metal, telemetry: telemetry)
        let service = DefaultUpscalerEngineService(
            media: media,
            metal: metal,
            modelAssets: NoopModelAssetsService(),
            telemetryFactory: { telemetry }
        )
        let handle = try service.submit(UpscaleJob(
            inputURL: inputURL,
            outputURL: outputURL,
            targetResolution: targetResolution,
            codec: .hevc,
            preserveAudio: false
        ))

        let completedURL = try await handle.waitForCompletion()
        XCTAssertEqual(completedURL, outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.result.status, .success)
        XCTAssertTrue(snapshot.result.balancedIntervals)
        XCTAssertEqual(snapshot.stages.count, ASHTelemetryStage.allCases.count)
        XCTAssertGreaterThan(snapshot.ash.stateHistogram.reduce(0, +), 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: telemetryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: telemetryURL, options: .atomic)
    }

    func test_catalogMatchesLockedStageAndCounterNames() {
        XCTAssertEqual(ASHTelemetryStage.allCases.map(\.rawValue), [
            "media_probe",
            "reader_setup",
            "frame_read",
            "canonicalize",
            "analyze_luma",
            "analyze_chroma",
            "motion_estimate",
            "state_pack",
            "dispatch_decode",
            "reconstruct_luma",
            "reconstruct_chroma",
            "temporal_fuse",
            "telemetry_reduce",
            "writer_backpressure",
            "writer_append",
            "audio_process",
            "writer_finish",
            "reopen_verify",
            "frame_total",
            "job_total"
        ])
        XCTAssertEqual(ASHTelemetryCounter.allCases.map(\.rawValue), [
            "state_histogram_512",
            "message_histogram_16",
            "operator_histogram_16",
            "decode_exact",
            "decode_corrected",
            "decode_rejected",
            "candidate_one",
            "candidate_two",
            "candidate_more_than_two",
            "runtime_tree_generations",
            "full_frame_cpu_loops",
            "full_frame_gpu_readbacks",
            "full_frame_copies",
            "command_buffer_errors",
            "in_flight_frames",
            "partial_cleanup_failures"
        ])
    }

    func test_intervalsAreBalancedOrderedAndUseMonotonicDurations() throws {
        let clock = ManualTelemetryClock()
        let recorder = makeRecorder(clock: clock)
        recorder.beginRun(id: "balanced")

        let job = recorder.beginStage(.jobTotal)
        clock.advance(milliseconds: 1)
        let frame = recorder.beginStage(.frameTotal, frameIndex: 7)
        clock.advance(milliseconds: 2)
        XCTAssertTrue(recorder.endStage(frame))
        clock.advance(milliseconds: 3)
        XCTAssertTrue(recorder.endStage(job))

        let snapshot = recorder.finish(status: .success, message: nil)
        XCTAssertTrue(snapshot.result.balancedIntervals)
        XCTAssertEqual(try stage(.jobTotal, in: snapshot).cpuMilliseconds.total, 6)
        XCTAssertEqual(try stage(.frameTotal, in: snapshot).cpuMilliseconds.total, 2)
        XCTAssertEqual(snapshot.events.map(\.kind), [
            .runStarted,
            .stageBegan,
            .stageBegan,
            .stageEnded,
            .stageEnded,
            .terminal
        ])
        XCTAssertEqual(snapshot.events.map(\.sequence), Array(0...5).map(UInt64.init))
        XCTAssertEqual(snapshot.events[2].frameIndex, 7)
    }

    func test_unbalancedAndDuplicateIntervalsAreReported() {
        let clock = ManualTelemetryClock()
        let recorder = makeRecorder(clock: clock)
        recorder.beginRun(id: "unbalanced")

        let token = recorder.beginStage(.frameRead)
        let first = recorder.finish(status: .failure, message: "injected")

        XCTAssertFalse(first.result.balancedIntervals)
        XCTAssertTrue(first.result.failures.contains("unbalanced_stage_intervals=1"))
        XCTAssertFalse(recorder.endStage(token))
    }

    func test_nearestRankPercentilesAndTotalsAreDeterministic() throws {
        let clock = ManualTelemetryClock()
        let recorder = makeRecorder(clock: clock)
        recorder.beginRun(id: "percentiles")

        for duration in [1, 2, 3, 4] {
            let token = recorder.beginStage(.frameRead)
            clock.advance(milliseconds: UInt64(duration))
            XCTAssertTrue(recorder.endStage(token))
        }
        recorder.recordGPUTime(1.25, for: .reconstructLuma)
        recorder.recordGPUTime(2.50, for: .reconstructLuma)

        let snapshot = recorder.snapshot()
        let cpu = try stage(.frameRead, in: snapshot).cpuMilliseconds
        XCTAssertEqual(cpu.p50, 2)
        XCTAssertEqual(cpu.p95, 4)
        XCTAssertEqual(cpu.p99, 4)
        XCTAssertEqual(cpu.total, 10)
        let gpu = try stage(.reconstructLuma, in: snapshot).gpuMilliseconds
        XCTAssertEqual(gpu.p50, 1.25)
        XCTAssertEqual(gpu.p95, 2.5)
        XCTAssertEqual(gpu.total, 3.75)
    }

    func test_gpuTimingDoesNotDoubleCountACompletedStageInvocation() throws {
        let clock = ManualTelemetryClock()
        let recorder = makeRecorder(clock: clock)
        recorder.beginRun(id: "combined-cpu-gpu")

        let token = recorder.beginStage(.reconstructLuma)
        clock.advance(milliseconds: 3)
        XCTAssertTrue(recorder.endStage(token))
        recorder.recordGPUTime(2, for: .reconstructLuma)

        let timing = try stage(.reconstructLuma, in: recorder.snapshot())
        XCTAssertEqual(timing.count, 1)
        XCTAssertEqual(timing.cpuMilliseconds.total, 3)
        XCTAssertEqual(timing.gpuMilliseconds.total, 2)
    }

    func test_fixedHistogramBoundsAndCounterSaturation() {
        let recorder = makeRecorder(clock: ManualTelemetryClock())
        recorder.beginRun(id: "bounds")

        XCTAssertEqual(recorder.recordState(rawValue: 511), .applied)
        XCTAssertEqual(recorder.recordState(rawValue: 512), .rejectedOutOfBounds)
        XCTAssertEqual(recorder.recordMessage(15), .applied)
        XCTAssertEqual(recorder.recordMessage(16), .rejectedOutOfBounds)
        XCTAssertEqual(recorder.recordOperator(15), .applied)
        XCTAssertEqual(recorder.recordOperator(16), .rejectedOutOfBounds)
        XCTAssertEqual(recorder.increment(.fullFrameCopies, by: UInt64.max), .applied)
        XCTAssertEqual(recorder.increment(.fullFrameCopies, by: 1), .saturated)

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.ash.stateHistogram.count, 512)
        XCTAssertEqual(snapshot.ash.messageHistogram.count, 16)
        XCTAssertEqual(snapshot.ash.operatorHistogram.count, 16)
        XCTAssertEqual(snapshot.ash.stateHistogram[511], 1)
        XCTAssertEqual(snapshot.ash.messageHistogram[15], 1)
        XCTAssertEqual(snapshot.ash.operatorHistogram[15], 1)
        XCTAssertEqual(snapshot.counters[ASHTelemetryCounter.fullFrameCopies.rawValue], UInt64.max)
    }

    func test_decodeCandidateAndRuntimeCountersAreCaptured() {
        let recorder = makeRecorder(clock: ManualTelemetryClock())
        recorder.beginRun(id: "ash-counters")

        recorder.recordDecode(.exact)
        recorder.recordDecode(.corrected)
        recorder.recordDecode(.uncorrectable)
        recorder.recordCandidateCount(1)
        recorder.recordCandidateCount(2)
        recorder.recordCandidateCount(16)
        recorder.increment(.runtimeTreeGenerations)

        let ash = recorder.snapshot().ash
        XCTAssertEqual(ash.decoder, ASHDecoderTelemetrySnapshot(exact: 1, correctedOneBit: 1, rejected: 1))
        XCTAssertEqual(ash.candidateCounts, ASHCandidateTelemetrySnapshot(one: 1, two: 1, moreThanTwo: 1))
        XCTAssertEqual(ash.runtimeTreeGenerations, 1)
    }

    func test_terminalResultIsSingleAndNewRunResetsState() {
        let recorder = makeRecorder(clock: ManualTelemetryClock())
        recorder.beginRun(id: "first")
        let first = recorder.finish(status: .cancelled, message: "cancelled")
        let duplicate = recorder.finish(status: .success, message: nil)

        XCTAssertEqual(first.result.status, .cancelled)
        XCTAssertEqual(duplicate.result.status, .cancelled)
        XCTAssertEqual(recorder.increment(.fullFrameCopies), .ignoredAfterTerminal)

        recorder.beginRun(id: "second")
        XCTAssertEqual(recorder.increment(.fullFrameCopies), .applied)
        let second = recorder.finish(status: .success, message: nil)
        XCTAssertEqual(second.runID, "second")
        XCTAssertEqual(second.result.status, .success)
        XCTAssertEqual(second.counters[ASHTelemetryCounter.fullFrameCopies.rawValue], 1)
    }

    func test_legacyControlledTileReferenceRecordsItsValidationPath() throws {
        let recorder = makeRecorder(clock: ManualTelemetryClock())
        recorder.beginRun(id: "controlled-backend")
        let image = try ASHImage(width: 4, height: 4) { row, column in
            Double((row * 4) + column) / 15.0
        }

        let result = try ASHTileProcessor(
            tileSize: 4,
            scale: 2,
            topK: 1,
            telemetry: recorder
        ).process(luma: image)
        let snapshot = recorder.finish(status: .success, message: nil)

        XCTAssertEqual(result.summary.tileCount, 1)
        XCTAssertEqual(snapshot.ash.stateHistogram.reduce(0, +), 1)
        XCTAssertEqual(snapshot.ash.messageHistogram.reduce(0, +), 1)
        XCTAssertEqual(snapshot.ash.operatorHistogram.reduce(0, +), 1)
        XCTAssertEqual(snapshot.ash.runtimeTreeGenerations, 1)
        XCTAssertEqual(snapshot.ash.candidateCounts.moreThanTwo, 1)
        XCTAssertEqual(try stage(.analyzeLuma, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.statePack, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.dispatchDecode, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.reconstructLuma, in: snapshot).count, 1)
        XCTAssertEqual(try stage(.telemetryReduce, in: snapshot).count, 1)
        XCTAssertTrue(snapshot.result.balancedIntervals)
    }

    func test_observationsEncodeAndCapacityDropsAreExplicit() throws {
        let clock = ManualTelemetryClock()
        let recorder = DefaultASHTelemetryRecorder(
            timestampProvider: { clock.now() },
            eventCapacity: 2,
            timingSampleCapacity: 1,
            observationCapacity: 1,
            emitsSignposts: false
        )
        recorder.beginRun(id: "capacity")
        recorder.recordCommandBuffer(ASHCommandBufferObservation(label: "one", status: "created"))
        recorder.recordCommandBuffer(ASHCommandBufferObservation(label: "two", status: "created"))
        recorder.recordMedia(ASHMediaObservation(kind: "frame", frameIndex: 2))
        recorder.recordError(ASHErrorObservation(domain: "test", code: 4, message: "failure"))
        for _ in 0..<2 {
            let token = recorder.beginStage(.frameRead)
            clock.advance(milliseconds: 1)
            XCTAssertTrue(recorder.endStage(token))
        }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.commandBuffers.count, 1)
        XCTAssertGreaterThan(snapshot.droppedEventCount, 0)
        XCTAssertEqual(snapshot.droppedTimingSampleCount, 1)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(ASHTelemetrySnapshot.self, from: data), snapshot)
    }

    private func makeRecorder(clock: ManualTelemetryClock) -> DefaultASHTelemetryRecorder {
        DefaultASHTelemetryRecorder(
            timestampProvider: { clock.now() },
            emitsSignposts: false
        )
    }

    private func makeNoFrameJob(id: String) -> UpscaleJob {
        UpscaleJob(
            inputURL: URL(fileURLWithPath: "/tmp/mirmir-telemetry-\(id)-source.mov"),
            outputURL: URL(fileURLWithPath: "/tmp/mirmir-telemetry-\(id)-output.mp4"),
            targetResolution: .p2160,
            preserveAudio: false
        )
    }

    private func stage(
        _ name: ASHTelemetryStage,
        in snapshot: ASHTelemetrySnapshot
    ) throws -> ASHStageTimingSnapshot {
        try XCTUnwrap(snapshot.stages.first { $0.name == name })
    }
}

private struct ProductionTraceConfiguration: Decodable {
    let inputPath: String
    let outputPath: String
    let telemetryPath: String
    let emitsSignposts: Bool?
    let targetWidth: Int?
    let targetHeight: Int?
}

private final class ManualTelemetryClock: @unchecked Sendable {
    private let nanoseconds = OSAllocatedUnfairLock(initialState: UInt64(0))

    func now() -> UInt64 {
        nanoseconds.withLock { $0 }
    }

    func advance(milliseconds: UInt64) {
        nanoseconds.withLock { value in
            value += milliseconds * 1_000_000
        }
    }
}

private final class TelemetryFactoryCapture: @unchecked Sendable {
    private struct State {
        var created: [ObjectIdentifier] = []
        var scoped: [ObjectIdentifier] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var identities: (created: [ObjectIdentifier], scoped: [ObjectIdentifier]) {
        state.withLock { ($0.created, $0.scoped) }
    }

    func makeRecorder() -> any ASHTelemetryRecording {
        let recorder = DefaultASHTelemetryRecorder(emitsSignposts: false)
        state.withLock { $0.created.append(ObjectIdentifier(recorder)) }
        return recorder
    }

    func recordScope(_ recorder: any ASHTelemetryRecording) {
        state.withLock { $0.scoped.append(ObjectIdentifier(recorder)) }
    }
}

private final class TelemetryScopingNoopMediaPipeline:
    MediaPipelineService,
    ASHTelemetryMediaPipelineScoping,
    @unchecked Sendable {

    private let capture: TelemetryFactoryCapture

    init(capture: TelemetryFactoryCapture) {
        self.capture = capture
    }

    func scoped(to telemetry: any ASHTelemetryRecording) -> any MediaPipelineService {
        capture.recordScope(telemetry)
        return self
    }

    func probe(url: URL) async throws -> SourceProfile {
        SourceProfile(
            url: url,
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 0,
            estimatedFrameCount: 0,
            codecHint: "test",
            hasAudio: false
        )
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        let pool = try PixelBufferBridge.makePool(width: 16, height: 16)
        return StubMediaSession(
            sourceProfile: source,
            outputProfile: output,
            outputPixelBufferPool: pool
        )
    }

    func start() {}
    func stop() {}
}
