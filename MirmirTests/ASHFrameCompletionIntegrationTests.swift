import CoreMedia
import CoreVideo
import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class ASHFrameCompletionIntegrationTests: XCTestCase {
    @available(macOS 15.4, *)
    func testFrameCompletionRemainsRetainedUntilAppendAcknowledgesSuccess() async throws {
        let fixture = try AppendLeaseFixture(appendBehavior: .succeed)

        _ = try await fixture.service.submit(makeAppendLeaseJob()).waitForCompletion()

        XCTAssertEqual(fixture.session.finishCountObservedAtAppend, 0)
        XCTAssertEqual(fixture.completion.finishCount, 1)
        XCTAssertEqual(
            fixture.backend.lastContext,
            ASHUpscaleFrameContext(
                frameIndex: 0,
                presentationTimestampValue: 0,
                presentationTimestampTimescale: 30
            )
        )
        XCTAssertTrue(fixture.session.didFinish)
    }

    @available(macOS 15.4, *)
    func testFrameCompletionReleasesExactlyOnceWhenAppendFails() async throws {
        let fixture = try AppendLeaseFixture(appendBehavior: .fail)

        do {
            _ = try await fixture.service.submit(makeAppendLeaseJob()).waitForCompletion()
            XCTFail("Expected the injected append failure")
        } catch is AppendLeaseMediaSession.InjectedAppendFailure {
            // Expected.
        }

        XCTAssertEqual(fixture.session.finishCountObservedAtAppend, 0)
        XCTAssertEqual(fixture.completion.finishCount, 1)
        XCTAssertTrue(fixture.session.didCancel)
        XCTAssertFalse(fixture.session.didFinish)
    }

    @available(macOS 15.4, *)
    func testFrameCompletionReleasesExactlyOnceWhenAppendIsCancelled() async throws {
        let fixture = try AppendLeaseFixture(appendBehavior: .suspend)
        let handle = try fixture.service.submit(makeAppendLeaseJob())

        for _ in 0..<10_000 where !fixture.session.didBeginAppend {
            await Task.yield()
        }
        XCTAssertTrue(fixture.session.didBeginAppend)
        XCTAssertEqual(fixture.completion.finishCount, 0)

        handle.cancel()
        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Expected cancellation")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }

        XCTAssertEqual(fixture.session.finishCountObservedAtAppend, 0)
        XCTAssertEqual(fixture.completion.finishCount, 1)
        XCTAssertTrue(fixture.session.didCancel)
        XCTAssertFalse(fixture.session.didFinish)
    }

    @available(macOS 15.4, *)
    func testFinalMetadataDefaultsToOutputMetadata() throws {
        let fixture = try AppendLeaseFixture(appendBehavior: .succeed)

        XCTAssertEqual(
            fixture.backend.finalOutputMetadata,
            ["com.mirmir.ash.identity": "fixture"]
        )
    }

    @available(macOS 15.4, *)
    private func makeAppendLeaseJob() -> UpscaleJob {
        UpscaleJob(
            inputURL: URL(fileURLWithPath: "/tmp/recording-source.mov"),
            outputURL: URL(fileURLWithPath: "/tmp/recording-output.mp4"),
            targetResolution: .p2160,
            preserveAudio: false
        )
    }
}

@available(macOS 15.4, *)
private struct AppendLeaseFixture {
    let service: DefaultUpscalerEngineService
    let session: AppendLeaseMediaSession
    let backend: AppendLeaseBackend
    let completion: AppendLeaseCompletion

    init(appendBehavior: AppendLeaseMediaSession.AppendBehavior) throws {
        let completion = AppendLeaseCompletion()
        let backend = AppendLeaseBackend(completion: completion)
        let session = try AppendLeaseMediaSession(
            appendBehavior: appendBehavior,
            completion: completion
        )
        self.completion = completion
        self.backend = backend
        self.session = session
        self.service = DefaultUpscalerEngineService(
            media: AppendLeaseMediaPipeline(session: session),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: AppendLeaseBackendFactory(backend: backend)
        )
    }
}

@available(macOS 15.4, *)
private final class AppendLeaseCompletion: ASHUpscaleFrameCompletion, @unchecked Sendable {
    private struct State {
        var finishCount = 0
        var released = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var finishCount: Int {
        state.withLock { $0.finishCount }
    }

    func finishAfterAppend() {
        state.withLock { state in
            state.finishCount += 1
            state.released = true
        }
    }
}

@available(macOS 15.4, *)
private final class AppendLeaseBackend: ASHUpscaleBackend, @unchecked Sendable {
    private let completion: AppendLeaseCompletion
    private let context = OSAllocatedUnfairLock<ASHUpscaleFrameContext?>(initialState: nil)

    let outputMetadata = ["com.mirmir.ash.identity": "fixture"]

    var lastContext: ASHUpscaleFrameContext? {
        context.withLock { $0 }
    }

    init(completion: AppendLeaseCompletion) {
        self.completion = completion
    }

    func reset() {
        context.withLock { $0 = nil }
    }

    func process(
        source _: CVPixelBuffer,
        into _: CVPixelBuffer,
        context: ASHUpscaleFrameContext
    ) async throws -> any ASHUpscaleFrameCompletion {
        self.context.withLock { $0 = context }
        return completion
    }
}

@available(macOS 15.4, *)
private struct AppendLeaseBackendFactory: ASHUpscaleBackendFactory {
    let backend: AppendLeaseBackend

    func makeBackend(
        route _: ASHSpatialRouteV2,
        telemetry _: any ASHTelemetryRecording
    ) async throws -> any ASHUpscaleBackend {
        backend
    }
}

private final class AppendLeaseMediaPipeline: MediaPipelineService, @unchecked Sendable {
    private let session: AppendLeaseMediaSession

    init(session: AppendLeaseMediaSession) {
        self.session = session
    }

    func probe(url _: URL) async throws -> SourceProfile {
        session.sourceProfile
    }

    func beginSession(source _: SourceProfile, output _: OutputProfile) async throws -> MediaSession {
        session
    }

    func start() {}
    func stop() {}
}

private final class AppendLeaseMediaSession: MediaSession, @unchecked Sendable {
    enum AppendBehavior: Sendable {
        case succeed
        case fail
        case suspend
    }

    struct InjectedAppendFailure: Error {}

    private struct State {
        var didReturnSource = false
        var didBeginAppend = false
        var didCancel = false
        var didFinish = false
        var finishCountObservedAtAppend: Int?
        var continuation: CheckedContinuation<Void, Error>?
    }

    let sourceProfile = SourceProfile(
        url: URL(fileURLWithPath: "/tmp/append-lease-source.mov"),
        resolution: .p1080,
        frameRate: 30,
        durationSeconds: 1.0 / 30.0,
        estimatedFrameCount: 1,
        codecHint: "fixture",
        hasAudio: false
    )
    let outputProfile = OutputProfile(
        url: URL(fileURLWithPath: "/tmp/append-lease-output.mp4"),
        resolution: .p2160,
        codec: .hevc,
        preserveAudio: false
    )
    let outputPixelBufferPool: CVPixelBufferPool
    let terminalCleanupError: MediaPipelineError? = nil

    private let sourcePixelBuffer: CVPixelBuffer
    private let appendBehavior: AppendBehavior
    private let completion: AppendLeaseCompletion
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(appendBehavior: AppendBehavior, completion: AppendLeaseCompletion) throws {
        self.appendBehavior = appendBehavior
        self.completion = completion
        self.outputPixelBufferPool = try PixelBufferBridge.makePool(width: 32, height: 32)
        let sourcePool = try PixelBufferBridge.makePool(width: 16, height: 16)
        self.sourcePixelBuffer = try PixelBufferBridge.dequeue(from: sourcePool)
    }

    var didBeginAppend: Bool {
        state.withLock { $0.didBeginAppend }
    }

    var didCancel: Bool {
        state.withLock { $0.didCancel }
    }

    var didFinish: Bool {
        state.withLock { $0.didFinish }
    }

    var finishCountObservedAtAppend: Int? {
        state.withLock { $0.finishCountObservedAtAppend }
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        let returnsFrame = state.withLock { state in
            guard !state.didReturnSource else { return false }
            state.didReturnSource = true
            return true
        }
        guard returnsFrame else { return nil }
        return FrameRecord(
            pixelBuffer: sourcePixelBuffer,
            timing: FrameTiming(
                frameIndex: 0,
                presentationTime: CMTime(value: 0, timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
        )
    }

    func appendOutput(pixelBuffer _: CVPixelBuffer, timing _: FrameTiming) async throws {
        state.withLock { state in
            state.didBeginAppend = true
            state.finishCountObservedAtAppend = completion.finishCount
        }
        switch appendBehavior {
        case .succeed:
            return
        case .fail:
            throw InjectedAppendFailure()
        case .suspend:
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = state.withLock { state in
                    guard !state.didCancel else { return true }
                    state.continuation = continuation
                    return false
                }
                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func finish() async throws {
        state.withLock { $0.didFinish = true }
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.didCancel = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
