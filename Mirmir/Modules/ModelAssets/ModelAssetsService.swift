import Foundation

public enum ModelAssetsTarget: String, Sendable, CaseIterable {
    case video
}

public enum ModelAssetsStatus: Equatable, Sendable {
    case unknown
    case downloadRequired
    case downloading(progress: Double)
    case ready
    case failed(reason: String)
}

/// Stages Apple's super-resolution ML model assets prior to first export.
///
/// Wraps the `VTSuperResolutionScalerConfiguration` model lifecycle introduced
/// in macOS 15.4: `downloadRequired` → `downloading` → `ready`.
///
/// This is its own module because (a) downloads are explicit on macOS, (b) the
/// UI must surface progress, and (c) upscale jobs must block until status is
/// `.ready`.
public protocol ModelAssetsService: AnyObject, Sendable {
    func currentStatus(for target: ModelAssetsTarget) -> ModelAssetsStatus
    func statusStream(for target: ModelAssetsTarget) -> AsyncStream<ModelAssetsStatus>

    /// Returns when the asset is `.ready` or throws if it cannot be staged.
    func ensureReady(for target: ModelAssetsTarget) async throws

    func start()
    func stop()
}

public enum ModelAssetsServiceError: Error, CustomStringConvertible {
    case unsupportedOSVersion
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .unsupportedOSVersion:
            return "VTFrameProcessor super-resolution requires macOS 15.4 or later."
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        }
    }
}
