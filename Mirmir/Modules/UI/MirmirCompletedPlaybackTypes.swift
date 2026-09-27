import AVFoundation
import Foundation
import OSLog

struct MirmirLoadedPlaybackAsset {
    let asset: AVURLAsset
    let durationSeconds: Double
}

struct MirmirPlaybackAssetIdentity: Hashable {
    let sourceURL: URL
    let completedOutputURL: URL

    init(sourceURL: URL, completedOutputURL: URL) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.completedOutputURL =
            completedOutputURL.standardizedFileURL
    }
}

enum MirmirPlaybackAssetRole {
    case source
    case completedOutput

    var displayName: String {
        switch self {
        case .source:
            return "Original video"
        case .completedOutput:
            return "Upscaled video"
        }
    }

    var recoveryGuidance: String {
        "Choose a readable local movie for this side of Compare, then retry "
            + "playback."
    }
}

enum MirmirCompletedPlaybackError: LocalizedError {
    case fileMissing(
        role: MirmirPlaybackAssetRole,
        filename: String
    )
    case notPlayable(role: MirmirPlaybackAssetRole)
    case videoTrackMissing(role: MirmirPlaybackAssetRole)
    case invalidDuration(role: MirmirPlaybackAssetRole)
    case assetLoadFailed(
        role: MirmirPlaybackAssetRole,
        detail: String
    )

    var errorDescription: String? {
        switch self {
        case .fileMissing(let role, let filename):
            return "\(role.displayName) “\(filename)” is no longer available. "
                + role.recoveryGuidance
        case .notPlayable(let role):
            return "\(role.displayName) is not playable. "
                + role.recoveryGuidance
        case .videoTrackMissing(let role):
            return "\(role.displayName) does not contain a video track. "
                + role.recoveryGuidance
        case .invalidDuration(let role):
            return "\(role.displayName) has an invalid duration. "
                + role.recoveryGuidance
        case .assetLoadFailed(let role, let detail):
            return "\(role.displayName) could not load: \(detail). "
                + role.recoveryGuidance
        }
    }
}

final class MirmirPlaybackTimeObserverToken: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

enum MirmirCompletedPlaybackLogging {
    private static let logger = Logger(
        subsystem: "com.mirmir.app",
        category: "completed-playback"
    )

    static func recordReady(durationSeconds: Double) {
        logger.info(
            "Synchronized comparison playback ready; duration: \(durationSeconds, privacy: .public) seconds."
        )
    }

    static func recordFailure(_ message: String) {
        logger.error(
            "Synchronized comparison playback failed: \(message, privacy: .private)"
        )
    }
}
