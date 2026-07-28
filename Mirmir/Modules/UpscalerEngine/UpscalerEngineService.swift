import Foundation

public enum UpscalerEngineAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

public enum UpscalerEngineError: Error, CustomStringConvertible {
    case backendUnavailable(reason: String)
    case modeUnavailable(mode: UpscaleMode, reason: String)
    case invalidJobIdentifier(String)
    case modelAssetsNotReady
    case unsupportedSourceResolution(VideoResolution)
    case inputOutputCollision
    case jobAlreadyRunning
    case strategyFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .backendUnavailable(let reason):
            return reason
        case .modeUnavailable(_, let reason):
            return reason
        case .invalidJobIdentifier(let identifier):
            return "Upscale job identifier is invalid: \(identifier)"
        case .modelAssetsNotReady:
            return "VTFrameProcessor super-resolution model assets are not ready."
        case .unsupportedSourceResolution(let res):
            return "Source resolution \(res) is not supported by Mirmir (supports 720p and 1080p)."
        case .inputOutputCollision:
            return "The output file must be different from the source video."
        case .jobAlreadyRunning:
            return "An upscale job is already running."
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
    var availability: UpscalerEngineAvailability { get }

    func availability(for mode: UpscaleMode) -> UpscalerEngineAvailability
    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle
    func start()
    func stop()
}

public extension UpscalerEngineService {
    func availability(for _: UpscaleMode) -> UpscalerEngineAvailability {
        availability
    }
}
