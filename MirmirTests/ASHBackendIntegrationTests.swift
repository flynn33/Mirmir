import Foundation
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

    @MainActor
    func test_viewModelCanStartASHUpscaleWithoutModelReadiness() {
        let viewModel = MirmirViewModel(
            mediaPipeline: NoopMediaPipelineService(),
            upscalerEngine: NoopUpscalerEngineService(),
            modelAssets: FailingModelAssetsService()
        )
        viewModel.ashBackendStatus = .available
        viewModel.sourceProfile = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/source.mov"),
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: nil,
            hasAudio: false
        )
        viewModel.targetResolution = .p2160
        viewModel.state = .ready

        XCTAssertTrue(viewModel.canStart)
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
