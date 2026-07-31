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

enum ModelAssetsRouteBinding: Hashable, Sendable {
    case unresolved
    case notRequired(routeID: String)
    case videoToolboxQuality(R04VideoToolboxNativeRouteBinding)

    var routeID: String? {
        switch self {
        case .unresolved:
            return nil
        case .notRequired(let routeID):
            return routeID
        case .videoToolboxQuality(let binding):
            return binding.subjectID.rawValue
        }
    }

    var requiresConfigurationModel: Bool {
        switch self {
        case .unresolved, .notRequired:
            return false
        case .videoToolboxQuality(let binding):
            return binding.requiresConfigurationModel
        }
    }
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

/// Binds model state to the exact route selected for the pending job.
///
/// The binding is separate from `ModelAssetsTarget`: a single video target can
/// move between model-free and configuration-model-backed routes as the user
/// changes source geometry, destination geometry, or processing policy.
protocol ModelAssetsRouteBindingService: ModelAssetsService {
    func bind(
        _ binding: ModelAssetsRouteBinding,
        for target: ModelAssetsTarget
    )
    func currentBinding(
        for target: ModelAssetsTarget
    ) -> ModelAssetsRouteBinding
}

public enum ModelAssetsServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedOSVersion
    case configurationNotBound
    case configurationChanged
    case serviceStopped
    case acquisitionNotAuthorized
    case downloadAlreadyInProgress(progress: Double)
    case downloadFailed(String)

    public var description: String {
        switch self {
        case .unsupportedOSVersion:
            return "VideoToolbox quality super resolution requires macOS 26.0 or later."
        case .configurationNotBound:
            return "No exact VideoToolbox quality configuration is bound for model status."
        case .configurationChanged:
            return "The selected upscaling route changed while its model was being prepared."
        case .serviceStopped:
            return "Model preparation stopped because the model asset service stopped."
        case .acquisitionNotAuthorized:
            return "Model download requires explicit acquisition authority."
        case .downloadAlreadyInProgress(let progress):
            return "Model download is already in progress: \(progress)."
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        }
    }
}
