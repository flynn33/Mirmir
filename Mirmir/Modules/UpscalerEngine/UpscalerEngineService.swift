import Foundation

public enum UpscalerEngineError: Error, CustomStringConvertible {
    case modelAssetsNotReady
    case unsupportedSourceResolution(VideoResolution)
    case strategyFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .modelAssetsNotReady:
            return "VTFrameProcessor super-resolution model assets are not ready."
        case .unsupportedSourceResolution(let res):
            return "Source resolution \(res) is not supported by Mirmir (supports 720p and 1080p)."
        case .strategyFailed(let detail):
            return "Upscale strategy failed: \(detail)"
        case .cancelled:
            return "Upscale job was cancelled."
        }
    }
}

public protocol UpscalerJobHandle: AnyObject, Sendable {
    var progressStream: AsyncStream<UpscaleProgress> { get }
    func cancel()
    func waitForCompletion() async throws -> URL
}

public protocol UpscalerEngineService: AnyObject, Sendable {
    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle
    func start()
    func stop()
}
