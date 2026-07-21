import Foundation

#if compiler(>=6.2) && !targetEnvironment(simulator)
import VideoToolbox
#endif

enum VTModelAcquisitionAuthority: Equatable, Sendable {
    case statusOnly
    case systemDownloadAuthorized
}

enum VTModelStagerStatus: Equatable, Sendable {
    case downloadRequired
    case downloading(progress: Double)
    case ready
    case unavailable(reason: String)
}

enum VTModelStagerError: Error, Equatable, Sendable {
    case acquisitionNotAuthorized
    case downloadAlreadyInProgress(progress: Double)
    case downloadCompletedWithoutReady(VTModelStagerStatus)
    case unavailable(reason: String)
}

protocol VTModelConfigurationProviding: AnyObject, Sendable {
    func currentStatus() -> VTModelStagerStatus
    func downloadConfigurationModel() async throws
}

private final class VTUnboundModelConfigurationProvider:
    VTModelConfigurationProviding,
    Sendable {
    func currentStatus() -> VTModelStagerStatus {
        .unavailable(reason: "quality_configuration_not_bound")
    }

    func downloadConfigurationModel() async throws {
        throw VTModelStagerError.unavailable(reason: "quality_configuration_not_bound")
    }
}

/// Reports and, only with explicit authority, acquires the model belonging to
/// one exact quality-super-resolution configuration.
///
/// Model state is configuration-specific. This type therefore never performs a
/// static or target-wide lookup and its default initializer is deliberately
/// unbound and status-only.
final class VTModelStager: @unchecked Sendable {
    typealias NativeStatus = VTModelStagerStatus

    let acquisitionAuthority: VTModelAcquisitionAuthority

    private let configurationProvider: any VTModelConfigurationProviding

    init() {
        acquisitionAuthority = .statusOnly
        configurationProvider = VTUnboundModelConfigurationProvider()
    }

    init(
        configurationProvider: any VTModelConfigurationProviding,
        acquisitionAuthority: VTModelAcquisitionAuthority
    ) {
        self.configurationProvider = configurationProvider
        self.acquisitionAuthority = acquisitionAuthority
    }

    func currentStatus() -> NativeStatus {
        configurationProvider.currentStatus()
    }

    func ensureReady(
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        switch currentStatus() {
        case .ready:
            progressHandler(1.0)
        case .downloadRequired:
            guard acquisitionAuthority == .systemDownloadAuthorized else {
                throw VTModelStagerError.acquisitionNotAuthorized
            }
            try await configurationProvider.downloadConfigurationModel()
            let completedStatus = currentStatus()
            guard completedStatus == .ready else {
                if case .downloading(let progress) = completedStatus {
                    progressHandler(progress)
                }
                throw VTModelStagerError.downloadCompletedWithoutReady(completedStatus)
            }
            progressHandler(1.0)
        case .downloading(let progress):
            progressHandler(progress)
            throw VTModelStagerError.downloadAlreadyInProgress(progress: progress)
        case .unavailable(let reason):
            throw VTModelStagerError.unavailable(reason: reason)
        }
    }
}

#if compiler(>=6.2) && !targetEnvironment(simulator)
@available(macOS 26.0, *)
private final class VTNativeQualityModelProvider:
    VTModelConfigurationProviding,
    @unchecked Sendable {
    private let configuration: VTSuperResolutionScalerConfiguration

    init(configuration: VTSuperResolutionScalerConfiguration) {
        self.configuration = configuration
    }

    func currentStatus() -> VTModelStagerStatus {
        switch configuration.configurationModelStatus {
        case .downloadRequired:
            return .downloadRequired
        case .downloading:
            return .downloading(
                progress: Double(configuration.configurationModelPercentageAvailable)
            )
        case .ready:
            return .ready
        @unknown default:
            return .unavailable(
                reason: "unknown_model_status_\(configuration.configurationModelStatus.rawValue)"
            )
        }
    }

    func downloadConfigurationModel() async throws {
        try await configuration.downloadConfigurationModel()
    }
}

@available(macOS 26.0, *)
extension VTModelStager {
    convenience init(
        configuration: VTSuperResolutionScalerConfiguration,
        acquisitionAuthority: VTModelAcquisitionAuthority
    ) {
        self.init(
            configurationProvider: VTNativeQualityModelProvider(
                configuration: configuration
            ),
            acquisitionAuthority: acquisitionAuthority
        )
    }
}
#endif
