import Foundation
import CoreMedia
import CoreVideo
import os.lock
import XCTest
@testable import Mirmir

final class ASHBackendIntegrationTests: XCTestCase {
    @available(macOS 15.4, *)
    func test_defaultUpscalerUsesASHBackendWithoutStagingModelAssets() async throws {
        let modelAssets = FailingModelAssetsService()
        let service = DefaultUpscalerEngineService(
            media: NoopMediaPipelineService(),
            metal: NoopMetalRenderingService(),
            modelAssets: modelAssets,
            backendFactory: ASHDevelopmentUpscaleBackendFactory()
        )
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirmir-ash-backend-test.mp4")
        let job = UpscaleJob(
            inputURL: URL(fileURLWithPath: "/tmp/source.mov"),
            outputURL: outputURL,
            targetResolution: .p2160,
            codec: .hevc,
            preserveAudio: false
        )

        let handle = try service.submit(job)
        let completedURL = try await handle.waitForCompletion()

        XCTAssertEqual(completedURL, outputURL)
        XCTAssertFalse(modelAssets.didEnsureReady)
    }

    @available(macOS 15.4, *)
    func test_pipelineFailureCancelsTheActiveMediaSession() async throws {
        let session = try RecordingMediaSession(behavior: .fail)
        let service = DefaultUpscalerEngineService(
            media: RecordingMediaPipelineService(session: session),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHDevelopmentUpscaleBackendFactory()
        )
        let handle = try service.submit(makeRecordingJob())

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Expected the injected media-session failure")
        } catch is RecordingMediaSession.InjectedFailure {
            // Expected.
        }

        XCTAssertTrue(session.didRequestFrame)
        XCTAssertTrue(session.didCancel)
        XCTAssertFalse(session.didFinish)
    }

    @available(macOS 15.4, *)
    func test_lockedArtifactFailureRejectsBeforeMediaSessionCreation() async throws {
        let session = try RecordingMediaSession(behavior: .fail)
        let media = RecordingMediaPipelineService(session: session)
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-missing-v3-\(UUID().uuidString)")
        let service = DefaultUpscalerEngineService(
            media: media,
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHLockedUpscaleBackendFactoryV3(
                resourceRoot: missingRoot
            )
        )
        let handle = try service.submit(makeRecordingJob())

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Expected locked artifact loading to fail")
        } catch let error as ASHLockedArtifactStoreErrorV3 {
            XCTAssertEqual(error, .invalidResourceRoot)
        }

        XCTAssertFalse(media.didBeginSession)
        XCTAssertFalse(session.didRequestFrame)
        XCTAssertFalse(session.didCancel)
        XCTAssertFalse(session.didFinish)
    }

    @available(macOS 15.4, *)
    func testLockedReleaseIdentityReachesTimedMetadataBeforeSessionCreation() async throws {
        let fixture = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifacts = try await ASHLockedArtifactStoreV3(resourceRoot: fixture.root).artifacts()
        let session = try RecordingMediaSession(behavior: .fail)
        let media = RecordingMediaPipelineService(session: session)
        let service = DefaultUpscalerEngineService(
            media: media,
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHLockedUpscaleBackendFactoryV3(resourceRoot: fixture.root)
        )

        let handle = try service.submit(makeRecordingJob())
        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Expected the injected media-session failure")
        } catch is RecordingMediaSession.InjectedFailure {
            // Expected after the output profile has been captured.
        }

        XCTAssertEqual(
            media.outputTimedMetadataTemplate?["com.mirmir.ash.configuration-id"],
            artifacts.configuration.configurationID
        )
        XCTAssertEqual(
            media.outputTimedMetadataTemplate?["com.mirmir.ash.release-manifest-sha256"],
            artifacts.manifest.manifestSHA256.hex
        )
        XCTAssertEqual(
            media.outputTimedMetadataTemplate?["com.mirmir.ash.spatial-only"],
            "true"
        )
        XCTAssertEqual(
            media.outputTimedMetadataTemplate?[
                "com.mirmir.ash.numerical-fallback-count"
            ],
            "0"
        )
    }

    @available(macOS 15.4, *)
    func testLockedReleaseFinalIdentityReachesSessionFinalization() async throws {
        let fixture = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifacts = try await ASHLockedArtifactStoreV3(
            resourceRoot: fixture.root
        ).artifacts()
        let session = try RecordingMediaSession(behavior: .complete)
        let service = DefaultUpscalerEngineService(
            media: RecordingMediaPipelineService(session: session),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHLockedUpscaleBackendFactoryV3(resourceRoot: fixture.root)
        )

        _ = try await service.submit(makeRecordingJob()).waitForCompletion()

        XCTAssertTrue(session.didFinish)
        XCTAssertEqual(
            session.finalMetadata?["com.mirmir.ash.configuration-id"],
            artifacts.configuration.configurationID
        )
        XCTAssertEqual(
            session.finalMetadata?["com.mirmir.ash.release-manifest-sha256"],
            artifacts.manifest.manifestSHA256.hex
        )
        XCTAssertEqual(
            session.finalMetadata?["com.mirmir.ash.numerical-fallback-count"],
            "0"
        )
    }

    @available(macOS 15.4, *)
    func test_jobCancellationUnblocksAndTearsDownTheMediaSession() async throws {
        let session = try RecordingMediaSession(behavior: .suspend)
        let service = DefaultUpscalerEngineService(
            media: RecordingMediaPipelineService(session: session),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHDevelopmentUpscaleBackendFactory()
        )
        let handle = try service.submit(makeRecordingJob())

        for _ in 0..<10_000 where !session.didRequestFrame {
            await Task.yield()
        }
        XCTAssertTrue(session.didRequestFrame)

        handle.cancel()
        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Expected cancellation")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }

        XCTAssertTrue(session.didCancel)
        XCTAssertFalse(session.didFinish)
    }

    @available(macOS 15.4, *)
    func test_jobCancellationPropagatesTerminalCleanupFailure() async throws {
        let session = try RecordingMediaSession(behavior: .suspendWithCleanupFailure)
        let service = DefaultUpscalerEngineService(
            media: RecordingMediaPipelineService(session: session),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHDevelopmentUpscaleBackendFactory()
        )
        let handle = try service.submit(makeRecordingJob())

        for _ in 0..<10_000 where !session.didRequestFrame {
            await Task.yield()
        }
        XCTAssertTrue(session.didRequestFrame)
        handle.cancel()

        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Expected terminal cleanup failure.")
        } catch let error as MediaPipelineError {
            guard case .partialCleanupFailed(let url, let reason) = error else {
                return XCTFail("Unexpected media error: \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "injected.partial.mp4")
            XCTAssertEqual(reason, "injected cleanup failure")
        }
        XCTAssertTrue(session.didCancel)
        XCTAssertFalse(session.didFinish)
    }

    @available(macOS 15.4, *)
    func test_serviceRejectsOverlapUntilCancelledJobTerminates() async throws {
        let session = try RecordingMediaSession(behavior: .suspend)
        let telemetry = DefaultASHTelemetryRecorder(emitsSignposts: false)
        let service = DefaultUpscalerEngineService(
            media: RecordingMediaPipelineService(session: session),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHDevelopmentUpscaleBackendFactory(),
            telemetryFactory: { telemetry }
        )
        let first = try service.submit(makeRecordingJob())

        for _ in 0..<10_000 where !session.didRequestFrame {
            await Task.yield()
        }
        XCTAssertTrue(session.didRequestFrame)
        let firstRunID = telemetry.snapshot().runID

        XCTAssertThrowsError(try service.submit(makeRecordingJob())) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .jobAlreadyRunning = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(telemetry.snapshot().runID, firstRunID)

        first.cancel()
        do {
            _ = try await first.waitForCompletion()
            XCTFail("Expected cancellation")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        XCTAssertEqual(telemetry.snapshot().result.status, .cancelled)

        let next = try service.submit(makeRecordingJob())
        next.cancel()
        _ = try? await next.waitForCompletion()
    }

    @available(macOS 15.4, *)
    func testProductionLockedFactoryConstructsMetalBackend() async throws {
        let fixture = try ASHLockedReleaseTestSupportV3.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ASHLockedArtifactStoreV3(resourceRoot: fixture.root)
        let artifacts = try await store.artifacts()
        let factory = ASHLockedUpscaleBackendFactoryV3(
            artifactStore: store,
            metal: NoopMetalRenderingService()
        )
        let backend = try await factory.makeBackend(
            route: .direct2x,
            telemetry: ASHNoopTelemetryRecorder.shared
        )

        XCTAssertTrue(backend is ASHMetalUpscaleBackendV3)
        XCTAssertEqual(
            backend.outputMetadata["com.mirmir.ash.configuration-id"],
            artifacts.configuration.configurationID
        )
    }

    @MainActor
    func test_viewModelCanStartASHUpscaleWithoutModelReadiness() {
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: FailingModelAssetsService()
        )
        let sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/source.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: false
        )
        viewModel.sourceProfile = sourceProfile
        viewModel.targetResolution = .p2160
        XCTAssertTrue(viewModel.acceptOutputURLSelectedByUser(
            viewModel.defaultOutputURL(for: sourceProfile, target: .p2160)
        ))
        viewModel.state = .ready

        XCTAssertTrue(viewModel.canStart)
    }

    @available(macOS 15.4, *)
    private func makeRecordingJob() -> UpscaleJob {
        UpscaleJob(
            inputURL: URL(fileURLWithPath: "/tmp/recording-source.mov"),
            outputURL: URL(fileURLWithPath: "/tmp/recording-output.mp4"),
            targetResolution: .p2160,
            preserveAudio: false
        )
    }
}

private final class RecordingMediaPipelineService: MediaPipelineService, @unchecked Sendable {
    private let session: RecordingMediaSession
    private let beganSession = OSAllocatedUnfairLock(initialState: false)
    private let capturedOutputTimedMetadata = OSAllocatedUnfairLock<[String: String]?>(
        initialState: nil
    )

    init(session: RecordingMediaSession) {
        self.session = session
    }

    func probe(url: URL) async throws -> SourceProfile {
        session.sourceProfile
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        beganSession.withLock { $0 = true }
        capturedOutputTimedMetadata.withLock { $0 = output.timedMetadataTemplate }
        return session
    }

    var didBeginSession: Bool {
        beganSession.withLock { $0 }
    }

    var outputTimedMetadataTemplate: [String: String]? {
        capturedOutputTimedMetadata.withLock { $0 }
    }

    func start() {}
    func stop() {}
}

private final class RecordingMediaSession: MediaSession, @unchecked Sendable {
    enum Behavior: Sendable, Equatable {
        case complete
        case fail
        case suspend
        case suspendWithCleanupFailure
    }

    struct InjectedFailure: Error {}

    private struct State {
        var didRequestFrame = false
        var didCancel = false
        var didFinish = false
        var finalMetadata: [String: String]?
        var continuation: CheckedContinuation<FrameRecord?, Error>?
    }

    let sourceProfile = SourceProfile(
        url: URL(fileURLWithPath: "/tmp/recording-source.mov"),
        resolution: .p1080,
        frameRate: 30,
        durationSeconds: 1,
        estimatedFrameCount: 1,
        codecHint: "test",
        hasAudio: false
    )
    let outputProfile = OutputProfile(
        url: URL(fileURLWithPath: "/tmp/recording-output.mp4"),
        resolution: .p2160,
        codec: .hevc,
        preserveAudio: false
    )
    let outputPixelBufferPool: CVPixelBufferPool
    var terminalCleanupError: MediaPipelineError? {
        guard behavior == .suspendWithCleanupFailure, didCancel else { return nil }
        return .partialCleanupFailed(
            URL(fileURLWithPath: "/tmp/injected.partial.mp4"),
            "injected cleanup failure"
        )
    }

    private let behavior: Behavior
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(behavior: Behavior) throws {
        self.behavior = behavior
        self.outputPixelBufferPool = try PixelBufferBridge.makePool(width: 32, height: 32)
    }

    var didRequestFrame: Bool {
        state.withLock { $0.didRequestFrame }
    }

    var didCancel: Bool {
        state.withLock { $0.didCancel }
    }

    var didFinish: Bool {
        state.withLock { $0.didFinish }
    }

    var finalMetadata: [String: String]? {
        state.withLock { $0.finalMetadata }
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        switch behavior {
        case .complete:
            state.withLock { $0.didRequestFrame = true }
            return nil
        case .fail:
            state.withLock { $0.didRequestFrame = true }
            throw InjectedFailure()
        case .suspend, .suspendWithCleanupFailure:
            return try await withCheckedThrowingContinuation { continuation in
                let wasAlreadyCancelled = state.withLock { state in
                    state.didRequestFrame = true
                    if state.didCancel {
                        return true
                    }
                    state.continuation = continuation
                    return false
                }
                if wasAlreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func appendOutput(pixelBuffer: CVPixelBuffer, timing: FrameTiming) async throws {}

    func finish() async throws {
        state.withLock { $0.didFinish = true }
    }

    func finish(finalMetadata: [String: String]) async throws {
        state.withLock { state in
            state.didFinish = true
            state.finalMetadata = finalMetadata
        }
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<FrameRecord?, Error>? in
            state.didCancel = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class FailingModelAssetsService: ModelAssetsService, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var didEnsureReady: Bool {
        lock.withLock { $0 }
    }

    func currentStatus(for target: ModelAssetsTarget) -> ModelAssetsStatus {
        .unknown
    }

    func statusStream(for target: ModelAssetsTarget) -> AsyncStream<ModelAssetsStatus> {
        AsyncStream { continuation in
            continuation.yield(.unknown)
            continuation.finish()
        }
    }

    func ensureReady(for target: ModelAssetsTarget) async throws {
        lock.withLock { $0 = true }
        throw ModelAssetsServiceError.downloadFailed("model staging must not run for the ASH backend")
    }

    func start() {}
    func stop() {}
}
