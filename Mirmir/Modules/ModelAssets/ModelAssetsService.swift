import Foundation

public enum ModelAssetsTarget: String, Sendable, CaseIterable {
    case video
}

public enum ModelAssetsStatus: Equatable, Sendable {
    case unknown
    case notRequired
    case downloadRequired
    case downloading(progress: Double)
    case ready
    case failed(reason: String)
}

/// Reports and, when applicable, stages model assets prior to first export.
///
/// Wraps the configuration-specific `VTSuperResolutionScalerConfiguration`
/// model lifecycle introduced in macOS 26.0: `downloadRequired` →
/// `downloading` → `ready`.
///
/// This is its own module because (a) downloads are explicit on macOS, (b) the
/// UI must surface progress, and (c) jobs using a model-backed route must
/// block until status is `.ready`. Routes without model assets report
/// `.notRequired`.
public protocol ModelAssetsService: AnyObject, Sendable {
    func currentStatus(for target: ModelAssetsTarget) -> ModelAssetsStatus
    func statusStream(for target: ModelAssetsTarget) -> AsyncStream<ModelAssetsStatus>

    /// Returns when the asset is `.ready` or `.notRequired`, or throws if it
    /// cannot be staged.
    func ensureReady(for target: ModelAssetsTarget) async throws

    func start()
    func stop()
}

public enum ModelAssetsServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedOSVersion
    case configurationNotBound
    case acquisitionNotAuthorized
    case downloadAlreadyInProgress(progress: Double)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .unsupportedOSVersion:
            return "VideoToolbox quality super resolution requires macOS 26.0 or later."
        case .configurationNotBound:
            return "No exact VideoToolbox quality configuration is bound for model status."
        case .acquisitionNotAuthorized:
            return "Model download requires explicit acquisition authority."
        case .downloadAlreadyInProgress(let progress):
            return "Model download is already in progress: \(progress)."
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        }
    }
}
