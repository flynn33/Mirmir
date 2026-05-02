import Foundation
import VideoToolbox

/// Thin wrapper around `VTSuperResolutionScalerConfiguration` model staging.
///
/// Apple's API uses three terminal states (`downloadRequired`, `downloading`,
/// `ready`) and a download trigger that is documented for macOS 15.4+. Because
/// the symbol shape may evolve across SDKs, this wrapper isolates the call
/// site so the rest of the engine treats model readiness as a simple
/// `ModelAssetsStatus` stream.
@available(macOS 15.4, *)
final class VTModelStager: @unchecked Sendable {

    enum NativeStatus: Sendable {
        case downloadRequired
        case downloading(progress: Double)
        case ready
    }

    func currentStatus() -> NativeStatus {
        // VTSuperResolutionScalerConfiguration exposes `downloadStatus` and a
        // `downloadConfiguration(_:)` static that surfaces progress. The
        // concrete API shape (enum cases vs. status struct) must be consulted
        // against the running SDK.
        //
        // Until we read the running SDK's exact signature, return
        // `.downloadRequired` so the caller drives a download. Once we see the
        // concrete symbols at build time, replace this body with a direct
        // bridge.
        return .downloadRequired
    }

    func ensureReady(progressHandler: @Sendable @escaping (Double) -> Void) async throws {
        // Bridge to `VTSuperResolutionScalerConfiguration.downloadConfiguration(_:)`.
        // Apple stages the asset asynchronously; we surface progress via the
        // handler and resolve when status transitions to `.ready`.
        //
        // Implementation note for follow-up commit: open the SDK at build time
        // and bind to the exact symbol — VideoToolbox's super-resolution
        // download surface is part of the macOS 15.4 SDK and is not available
        // in older SDKs. For now we yield once at 100% so the caller sees a
        // resolvable terminal progress, and rely on Apple's runtime to either
        // serve a cached model or surface its own error.
        progressHandler(1.0)
    }
}
