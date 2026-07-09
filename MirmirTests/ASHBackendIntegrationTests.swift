import Foundation
import os.lock
import XCTest
@testable import Mirmir

final class ASHBackendIntegrationTests: XCTestCase {

    func test_atomicMediaOutputCommitsWithoutDestroyingExistingFileEarly() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("output.mp4")
        try Data("original".utf8).write(to: destination)
        let transaction = try AtomicMediaOutput(destinationURL: destination)
        XCTAssertEqual(
            transaction.temporaryURL.deletingLastPathComponent(),
            destination.deletingLastPathComponent()
        )
        try Data("completed".utf8).write(to: transaction.temporaryURL)

        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        try transaction.commit()

        XCTAssertEqual(try Data(contentsOf: destination), Data("completed".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: transaction.temporaryURL.path))
    }

    func test_atomicMediaOutputDiscardPreservesExistingDestination() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("output.mp4")
        try Data("original".utf8).write(to: destination)
        let transaction = try AtomicMediaOutput(destinationURL: destination)
        try Data("partial".utf8).write(to: transaction.temporaryURL)

        transaction.discard()

        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertFalse(fileManager.fileExists(atPath: transaction.temporaryURL.path))
    }

    @available(macOS 15.4, *)
    func test_defaultUpscalerRejectsInputOutputCollision() throws {
        let service = DefaultUpscalerEngineService(
            media: NoopMediaPipelineService(),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService()
        )
        let fileURL = URL(fileURLWithPath: "/tmp/source.mp4")
        let job = UpscaleJob(
            inputURL: fileURL,
            outputURL: fileURL,
            targetResolution: .p2160,
            preserveAudio: false
        )

        XCTAssertThrowsError(try service.submit(job)) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .inputOutputCollision = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @available(macOS 15.4, *)
    func test_defaultUpscalerUsesASHBackendWithoutStagingModelAssets() async throws {
        let modelAssets = FailingModelAssetsService()
        let service = DefaultUpscalerEngineService(
            media: NoopMediaPipelineService(),
            metal: NoopMetalRenderingService(),
            modelAssets: modelAssets
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
            modelAssets: NoopModelAssetsService()
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
    func test_jobCancellationUnblocksAndTearsDownTheMediaSession() async throws {
        let session = try RecordingMediaSession(behavior: .suspend)
        let service = DefaultUpscalerEngineService(
            media: RecordingMediaPipelineService(session: session),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService()
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

    @MainActor
    func test_viewModelCanStartASHUpscaleWithoutModelReadiness() {
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: FailingModelAssetsService()
        )
        viewModel.ashBackendStatus = .available
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

    init(session: RecordingMediaSession) {
        self.session = session
    }

    func probe(url: URL) async throws -> SourceProfile {
        session.sourceProfile
    }

    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        session
    }

    func start() {}
    func stop() {}
}

private final class RecordingMediaSession: MediaSession, @unchecked Sendable {
    enum Behavior: Sendable {
        case fail
        case suspend
    }

    struct InjectedFailure: Error {}

    private struct State {
        var didRequestFrame = false
        var didCancel = false
        var didFinish = false
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

    func nextSourceFrame() async throws -> FrameRecord? {
        switch behavior {
        case .fail:
            state.withLock { $0.didRequestFrame = true }
            throw InjectedFailure()
        case .suspend:
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

    func appendOutput(pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) async throws {}

    func finish() async throws {
        state.withLock { $0.didFinish = true }
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
