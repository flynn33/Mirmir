import Foundation

public enum UpscaleStrategy: Sendable, Equatable, CustomStringConvertible {
    /// Direct integer 2× super-resolution. Used for 1080p → 4K.
    case direct2x

    /// Direct rational 3/2 super-resolution. Used for 720p → 1080p.
    case direct3Over2

    public var description: String {
        switch self {
        case .direct2x:
            return "direct2x"
        case .direct3Over2:
            return "direct3Over2"
        }
    }

    /// Resolution produced directly by the spatial reconstruction pass.
    public func srOutputResolution(forSource source: VideoResolution) -> VideoResolution {
        switch self {
        case .direct2x:
            return source.scaled(by: 2)
        case .direct3Over2:
            precondition(source.width.isMultiple(of: 2) && source.height.isMultiple(of: 2))
            return VideoResolution(
                width: (source.width / 2) * 3,
                height: (source.height / 2) * 3
            )
        }
    }

    var spatialRoute: ASHSpatialRouteV2 {
        switch self {
        case .direct2x:
            return .direct2x
        case .direct3Over2:
            return .direct3Over2
        }
    }
}

public enum UpscaleStrategyError: Error, CustomStringConvertible {
    case unsupportedResolutionPair(source: VideoResolution, target: VideoResolution)

    public var description: String {
        switch self {
        case .unsupportedResolutionPair(let source, let target):
            return "Mirmir cannot use the requested upscale geometry "
                + "\(source) → \(target). The target must be larger, "
                + "positive, even-sized, and preserve the source aspect "
                + "ratio within one output pixel. Direct strategy is "
                + "limited to 720p→1080p and 1080p→4K; Automatic and "
                + "Adaptive support other valid geometries."
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
            return .direct3Over2
        }
        throw UpscaleStrategyError.unsupportedResolutionPair(source: source, target: target)
    }
}
