import CoreMedia
import CoreVideo
import Foundation

struct OutputMediaVerificationExpectation: @unchecked Sendable, Equatable {
    let resolution: VideoResolution
    let codec: OutputCodec
    let timing: FrameTimingLedgerSnapshot
    let timedMetadata: [String: String]

    init(
        resolution: VideoResolution,
        codec: OutputCodec,
        timing: FrameTimingLedgerSnapshot,
        timedMetadata: [String: String] = [:]
    ) {
        self.resolution = resolution
        self.codec = codec
        self.timing = timing
        self.timedMetadata = timedMetadata
    }
}

struct OutputMediaVerificationResult: @unchecked Sendable, Equatable {
    let codec: String
    let resolution: VideoResolution
    let frameCount: Int
    let duration: CMTime
    let lumaPayloadBytes: Int
    let chromaPayloadBytes: Int
}

enum OutputMediaVerificationError: Error, Equatable, CustomStringConvertible {
    case emptyTimingLedger
    case reopenFailed(String)
    case videoTrackCount(expected: Int, actual: Int)
    case missingVideoFormatDescription
    case codecMismatch(expected: String, actual: String)
    case dimensionsMismatch(expected: VideoResolution, actual: VideoResolution)
    case readerCreationFailed(String)
    case readerStartFailed(String)
    case readerFailed(String)
    case frameCountMismatch(expected: Int, actual: Int)
    case missingDecodedImage(frameIndex: Int)
    case pixelFormatMismatch(frameIndex: Int, expected: OSType, actual: OSType)
    case planeCountMismatch(frameIndex: Int, expected: Int, actual: Int)
    case planeLockFailed(frameIndex: Int, status: CVReturn)
    case emptyPlanePayload(frameIndex: Int, planeIndex: Int)
    case presentationTimeMismatch(frameIndex: Int, expected: CMTime, actual: CMTime)
    case frameDurationMismatch(frameIndex: Int, expected: CMTime, actual: CMTime)
    case mediaDurationMismatch(expected: CMTime, actual: CMTime)
    case trackEndMismatch(expected: CMTime, actual: CMTime)
    case metadataMismatch(scope: String, reason: String)

    var description: String {
        switch self {
        case .emptyTimingLedger:
            return "Output verification requires at least one expected video frame."
        case .reopenFailed(let reason):
            return "Output could not be reopened: \(reason)."
        case .videoTrackCount(let expected, let actual):
            return "Output contains \(actual) video tracks; expected \(expected)."
        case .missingVideoFormatDescription:
            return "Output video track has no format description."
        case .codecMismatch(let expected, let actual):
            return "Output codec \(actual) does not match expected codec \(expected)."
        case .dimensionsMismatch(let expected, let actual):
            return "Output dimensions \(actual) do not match expected dimensions \(expected)."
        case .readerCreationFailed(let reason):
            return "Output verification reader creation failed: \(reason)."
        case .readerStartFailed(let reason):
            return "Output verification reader did not start: \(reason)."
        case .readerFailed(let reason):
            return "Output verification reader failed: \(reason)."
        case .frameCountMismatch(let expected, let actual):
            return "Decoded output frame count \(actual) does not match expected count \(expected)."
        case .missingDecodedImage(let frameIndex):
            return "Decoded output frame \(frameIndex) contains no image buffer."
        case .pixelFormatMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) pixel format \(actual) does not match NV12 format \(expected)."
        case .planeCountMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) has \(actual) planes; expected \(expected)."
        case .planeLockFailed(let frameIndex, let status):
            return "Decoded frame \(frameIndex) could not be locked for plane verification (\(status))."
        case .emptyPlanePayload(let frameIndex, let planeIndex):
            return "Decoded frame \(frameIndex) plane \(planeIndex) has no addressable payload."
        case .presentationTimeMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) PTS \(actual) does not match expected PTS \(expected)."
        case .frameDurationMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) duration \(actual) does not match expected duration \(expected)."
        case .mediaDurationMismatch(let expected, let actual):
            return "Reopened media duration \(actual) does not match expected endpoint \(expected)."
        case .trackEndMismatch(let expected, let actual):
            return "Reopened video track endpoint \(actual) does not match expected endpoint \(expected)."
        case .metadataMismatch(let scope, let reason):
            return "Reopened \(scope) metadata differs: \(reason)."
        }
    }
}

protocol OutputMediaVerifying: Sendable {
    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult
}
