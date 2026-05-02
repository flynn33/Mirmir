import Foundation
import Metal
import CoreVideo

/// Provides shared Metal resources for rendering, GPU compute, and zero-copy
/// `CVPixelBuffer` interop. Owned by `MetalRenderingServiceModule`; consumed by
/// `MediaPipelineService`, `UpscalerEngineService`, and the UI preview view.
public protocol MetalRenderingService: AnyObject, Sendable {
    var device: MTLDevice { get }
    var commandQueue: MTLCommandQueue { get }
    var textureCache: CVMetalTextureCache { get }

    /// Idempotent — safe to call from a module's `start(context:)`.
    func start() throws
    /// Idempotent — safe to call from a module's `stop(context:)`.
    func stop()
}

public enum MetalRenderingServiceError: Error, CustomStringConvertible {
    case noDefaultDevice
    case commandQueueUnavailable
    case textureCacheCreationFailed(CVReturn)

    public var description: String {
        switch self {
        case .noDefaultDevice:
            return "MTLCreateSystemDefaultDevice() returned nil. This Mac does not expose a Metal device."
        case .commandQueueUnavailable:
            return "MTLDevice.makeCommandQueue() returned nil."
        case .textureCacheCreationFailed(let status):
            return "CVMetalTextureCacheCreate failed with status \(status)."
        }
    }
}
