import Foundation

public enum UpscaleStrategy: Sendable, Equatable, CustomStringConvertible {
    /// Direct integer 2× super-resolution. Used for 1080p → 4K.
    case direct2x

    /// 2× super-resolution to an intermediate resolution, then a controlled
    /// Lanczos downsample to the target. Used for 720p → 1080p (the
    /// reconstruction pass is real ML SR; only the polish is a resize).
    case twoXThenLanczosDownsample(intermediate: VideoResolution)

    public var description: String {
        switch self {
        case .direct2x:
            return "direct2x"
        case .twoXThenLanczosDownsample(let intermediate):
            return "twoXThenLanczosDownsample(intermediate: \(intermediate))"
        }
    }

    /// Resolution that the SR pass produces (always source × 2 in v1).
    public func srOutputResolution(forSource source: VideoResolution) -> VideoResolution {
        source.scaled(by: 2)
    }
}

public enum UpscaleStrategyError: Error, CustomStringConvertible {
    case unsupportedResolutionPair(source: VideoResolution, target: VideoResolution)

    public var description: String {
        switch self {
        case .unsupportedResolutionPair(let source, let target):
            return "Mirmir does not support upscaling \(source) → \(target). Supported pairs: 720p→1080p, 1080p→4K."
        }
    }
}

public enum StrategySelector {
    /// Returns the upscale strategy for the given resolution pair, or throws
    /// if Mirmir does not support it.
    public static func choose(source: VideoResolution, target: VideoResolution) throws -> UpscaleStrategy {
        if source == .p1080 && target == .p2160 {
            return .direct2x
        }
        if source == .p720 && target == .p1080 {
            return .twoXThenLanczosDownsample(intermediate: .p1440)
        }
        throw UpscaleStrategyError.unsupportedResolutionPair(source: source, target: target)
    }
}
