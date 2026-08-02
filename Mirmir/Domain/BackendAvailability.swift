import Foundation

enum BackendUnavailableReason: Error, Equatable, Sendable {
    case operatingSystemTooOld(requiredVersion: String)
    case sdkAdapterNotCompiled(requiredSymbol: String)
    case appleAPIUnsupported(details: String)
    case noMetalDevice
    case unsupportedSourceDimensions(width: Int, height: Int, details: String)
    case unsupportedTargetDimensions(width: Int, height: Int, details: String)
    case unsupportedScaleFactor(details: String)
    case unsupportedPixelFormatOrBitDepth(details: String)
    case hdrPreservationUnavailable
    case modelUnavailable(details: String)
    case deterministicAssetsIncomplete(details: String)
    case processingAdapterNotImplemented(backendID: UpscaleBackendID)
    case noCompatibleAutomaticBackend

    var userFacingDescription: String {
        switch self {
        case .operatingSystemTooOld(let requiredVersion):
            return "Requires macOS \(requiredVersion) or later."
        case .sdkAdapterNotCompiled(let requiredSymbol):
            return "This build was compiled without the required \(requiredSymbol) adapter."
        case .appleAPIUnsupported(let details):
            return "Apple's API reports this path unsupported: \(details)"
        case .noMetalDevice:
            return "No compatible Metal device is available on this Mac."
        case .unsupportedSourceDimensions(let width, let height, let details):
            return "The source size \(width) × \(height) is unsupported: \(details)"
        case .unsupportedTargetDimensions(let width, let height, let details):
            return "The target size \(width) × \(height) is unsupported: \(details)"
        case .unsupportedScaleFactor(let details):
            return "The requested scale factor is unsupported: \(details)"
        case .unsupportedPixelFormatOrBitDepth(let details):
            return "The source pixel format or bit depth is unsupported: \(details)"
        case .hdrPreservationUnavailable:
            return "This backend cannot preserve the source HDR signal for the requested output."
        case .modelUnavailable(let details):
            return "The required Apple model is unavailable: \(details)"
        case .deterministicAssetsIncomplete(let details):
            return "The Deterministic Engine assets are incomplete: \(details)"
        case .processingAdapterNotImplemented(let backendID):
            let title = BackendDescriptor.descriptor(for: backendID)?.title
                ?? backendID.rawValue
            return "This build does not include the \(title) processing adapter."
        case .noCompatibleAutomaticBackend:
            return "No implemented spatial backend can process this source and target."
        }
    }
}

enum BackendAvailability: Equatable, Sendable {
    case available
    case modelDownloadRequired(progress: Double?)
    case unavailable(reason: BackendUnavailableReason)

    var isRunnable: Bool {
        self == .available
    }

    var isSelectable: Bool {
        switch self {
        case .available, .modelDownloadRequired:
            true
        case .unavailable:
            false
        }
    }

    var statusText: String {
        switch self {
        case .available:
            return "Available"
        case .modelDownloadRequired(let progress):
            guard let progress, progress.isFinite else {
                return "Model download required"
            }
            let boundedProgress = min(max(progress, 0), 1)
            return "Model download required (\(Int((boundedProgress * 100).rounded()))%)"
        case .unavailable(let reason):
            return "Unavailable: \(reason.userFacingDescription)"
        }
    }
}
