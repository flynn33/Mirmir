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
    private let pollingIntervalNanoseconds: UInt64

    init() {
        acquisitionAuthority = .statusOnly
        configurationProvider = VTUnboundModelConfigurationProvider()
        pollingIntervalNanoseconds = 100_000_000
    }

    init(
        configurationProvider: any VTModelConfigurationProviding,
        acquisitionAuthority: VTModelAcquisitionAuthority,
        pollingIntervalNanoseconds: UInt64 = 100_000_000
    ) {
        self.configurationProvider = configurationProvider
        self.acquisitionAuthority = acquisitionAuthority
        self.pollingIntervalNanoseconds = max(
            pollingIntervalNanoseconds,
            1
        )
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
            let progressTask = makeProgressTask(
                progressHandler: progressHandler
            )
            do {
                try await configurationProvider
                    .downloadConfigurationModel()
            } catch {
                progressTask.cancel()
                await progressTask.value
                throw error
            }
            progressTask.cancel()
            await progressTask.value
            try Task.checkCancellation()
            let completedStatus = currentStatus()
            guard completedStatus == .ready else {
                if case .downloading(let progress) = completedStatus {
                    progressHandler(Self.normalized(progress))
                }
                throw VTModelStagerError.downloadCompletedWithoutReady(completedStatus)
            }
            progressHandler(1.0)
        case .downloading(let progress):
            progressHandler(Self.normalized(progress))
            try await waitForExistingDownload(
                progressHandler: progressHandler
            )
        case .unavailable(let reason):
            throw VTModelStagerError.unavailable(reason: reason)
        }
    }

    private func makeProgressTask(
        progressHandler: @Sendable @escaping (Double) -> Void
    ) -> Task<Void, Never> {
        Task { [configurationProvider, pollingIntervalNanoseconds] in
            while !Task.isCancelled {
                if case .downloading(let progress) =
                    configurationProvider.currentStatus() {
                    progressHandler(Self.normalized(progress))
                }
                do {
                    try await Task.sleep(
                        nanoseconds: pollingIntervalNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func waitForExistingDownload(
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch currentStatus() {
            case .ready:
                progressHandler(1.0)
                return
            case .downloading(let progress):
                progressHandler(Self.normalized(progress))
            case .downloadRequired:
                throw VTModelStagerError.downloadCompletedWithoutReady(
                    .downloadRequired
                )
            case .unavailable(let reason):
                throw VTModelStagerError.unavailable(reason: reason)
            }
            try await Task.sleep(
                nanoseconds: pollingIntervalNanoseconds
            )
        }
    }

    private static func normalized(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
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
        acquisitionAuthority: VTModelAcquisitionAuthority,
        pollingIntervalNanoseconds: UInt64 = 100_000_000
    ) {
        self.init(
            configurationProvider: VTNativeQualityModelProvider(
                configuration: configuration
            ),
            acquisitionAuthority: acquisitionAuthority,
            pollingIntervalNanoseconds: pollingIntervalNanoseconds
        )
    }
}
#endif
