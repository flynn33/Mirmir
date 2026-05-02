import Foundation
import Metal
import CoreVideo
import CoreMedia
@testable import Mirmir

final class NoopMetalRenderingService: MetalRenderingService, @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Test host requires a Metal-capable Mac")
        }
        self.device = device
        self.commandQueue = queue
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache ?? {
            fatalError("Could not create CVMetalTextureCache")
        }()
    }

    func start() throws {}
    func stop() {}
}

final class NoopModelAssetsService: ModelAssetsService, @unchecked Sendable {
    func currentStatus(for target: ModelAssetsTarget) -> ModelAssetsStatus { .ready }
    func statusStream(for target: ModelAssetsTarget) -> AsyncStream<ModelAssetsStatus> {
        AsyncStream { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
    }
    func ensureReady(for target: ModelAssetsTarget) async throws {}
    func start() {}
    func stop() {}
}

final class NoopMediaPipelineService: MediaPipelineService, @unchecked Sendable {
    func probe(url: URL) async throws -> SourceProfile {
        SourceProfile(
            url: url,
            resolution: .p1080,
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "test",
            hasAudio: false
        )
    }
    func beginSession(source: SourceProfile, output: OutputProfile) async throws -> MediaSession {
        let pool = try PixelBufferBridge.makePool(width: 16, height: 16)
        return StubMediaSession(sourceProfile: source, outputProfile: output, outputPixelBufferPool: pool)
    }
    func start() {}
    func stop() {}
}

final class StubMediaSession: MediaSession, @unchecked Sendable {
    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let outputPixelBufferPool: CVPixelBufferPool
    init(sourceProfile: SourceProfile, outputProfile: OutputProfile, outputPixelBufferPool: CVPixelBufferPool) {
        self.sourceProfile = sourceProfile
        self.outputProfile = outputProfile
        self.outputPixelBufferPool = outputPixelBufferPool
    }
    func nextSourceFrame() async throws -> FrameRecord? { nil }
    func appendOutput(pixelBuffer: CVPixelBuffer, at presentationTime: CMTime) async throws {}
    func finish() async throws {}
    func cancel() {}
}

final class NoopUpscalerEngineService: UpscalerEngineService, @unchecked Sendable {
    final class Handle: UpscalerJobHandle, @unchecked Sendable {
        let progressStream: AsyncStream<UpscaleProgress>
        let outputURL: URL
        init(outputURL: URL) {
            self.outputURL = outputURL
            self.progressStream = AsyncStream { $0.finish() }
        }
        func cancel() {}
        func waitForCompletion() async throws -> URL { outputURL }
    }
    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle { Handle(outputURL: job.outputURL) }
    func start() {}
    func stop() {}
}
