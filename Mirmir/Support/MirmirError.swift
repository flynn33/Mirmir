import Foundation

enum MirmirError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case unreadableAsset
    case unplayableAsset
    case protectedAsset
    case noVideoTrack
    case noEnabledVideoTrack
    case multipleEnabledVideoTracks(Int)
    case undecodableVideoTrack
    case invalidVideoGeometry
    case unsupportedVideo(String)
    case probeFailed(String)
    case backendUnavailable(UpscaleBackendID, String)
    case outputAlreadyExists
    case inputAccessDenied
    case outputAccessDenied
    case readerFailed(String)
    case writerFailed(String)
    case outputFinalizeFailed(String)
    case cancelled
    case backendProcessingFailed(
        backendID: UpscaleBackendID,
        frameIndex: Int?,
        details: String
    )

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason):
            return reason
        case .unreadableAsset:
            return "Mirmir cannot read this asset. Check the file permissions or choose another local video."
        case .unplayableAsset:
            return "AVFoundation cannot play this asset. Choose a supported local video file."
        case .protectedAsset:
            return "Protected video cannot be processed. Choose an unprotected local copy."
        case .noVideoTrack:
            return "The selected asset contains no video track. Choose a video file."
        case .noEnabledVideoTrack:
            return "The asset has video tracks, but none are enabled. Enable one video track before processing."
        case .multipleEnabledVideoTracks(let count):
            return "The asset has \(count) enabled video tracks. This version requires exactly one enabled video track."
        case .undecodableVideoTrack:
            return "AVFoundation cannot decode the enabled video track. Choose a video with a supported codec."
        case .invalidVideoGeometry:
            return "The video does not report valid display dimensions. Choose another video file."
        case .unsupportedVideo(let reason):
            return "This video is not supported: \(reason)"
        case .probeFailed(let reason):
            return reason
        case .backendUnavailable(let backendID, let reason):
            let title = BackendDescriptor.descriptor(for: backendID)?.title
                ?? backendID.rawValue
            return "\(title) is unavailable: \(reason)"
        case .outputAlreadyExists:
            return "The selected output already exists. Confirm replacement or choose a different filename."
        case .inputAccessDenied:
            return "Mirmir could not retain permission to read the selected input. Choose the video again."
        case .outputAccessDenied:
            return "Mirmir could not write in the selected output location. Choose another destination."
        case .readerFailed(let reason):
            return "AVFoundation could not read the video: \(reason)"
        case .writerFailed(let reason):
            return "AVFoundation could not write the output: \(reason)"
        case .outputFinalizeFailed(let reason):
            return "The output could not be finalized safely: \(reason)"
        case .cancelled:
            return "Processing was cancelled; no output file was kept."
        case .backendProcessingFailed(
            let backendID,
            let frameIndex,
            let details
        ):
            let backendTitle = BackendDescriptor.descriptor(for: backendID)?.title
                ?? backendID.rawValue
            let frameContext = frameIndex.map { " while processing frame \($0)" }
                ?? " during processing"
            return "\(backendTitle) failed\(frameContext): \(details) Choose another available backend or verify that the source format is supported."
        }
    }
}
