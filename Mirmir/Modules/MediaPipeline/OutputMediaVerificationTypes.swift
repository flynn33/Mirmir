import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

struct OutputMediaVideoColorExpectation: Sendable, Equatable {
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let pixelFormat: OSType
    let chromaLocation: String
    let isFullRangeVideo: Bool

    init(
        colorPrimaries: String,
        transferFunction: String,
        yCbCrMatrix: String,
        pixelFormat: OSType,
        chromaLocation: String,
        isFullRangeVideo: Bool = false
    ) {
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.pixelFormat = pixelFormat
        self.chromaLocation = chromaLocation
        self.isFullRangeVideo = isFullRangeVideo
    }

    static let sdrBT709VideoRangeLeft = OutputMediaVideoColorExpectation(
        colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
        transferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
        yCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        chromaLocation: kCMFormatDescriptionChromaLocation_Left as String,
        isFullRangeVideo: false
    )
}

struct OutputMediaAACSampleIdentity: @unchecked Sendable, Equatable {
    /// One compressed AAC access unit. The source `CMSampleBuffer` batching is
    /// intentionally discarded because passthrough remuxing may legally
    /// regroup access units without changing the compressed audio stream.
    let presentationTime: CMTime
    let decodeTime: CMTime
    let duration: CMTime
    let sampleCount: Int
    let payloadByteCount: Int
    let payloadSHA256: String
}

struct OutputMediaAACChannelDescriptionIdentity: Sendable, Equatable {
    let label: UInt32
    let flags: UInt32
    let coordinateBitPatterns: [UInt32]
}

struct OutputMediaAACChannelLayoutIdentity: Sendable, Equatable {
    let layoutTag: UInt32
    let channelBitmap: UInt32
    let channelDescriptions: [OutputMediaAACChannelDescriptionIdentity]
}

struct OutputMediaAACIdentity: @unchecked Sendable, Equatable {
    let codec: AudioFormatID
    let sampleRate: Double
    let channelCount: UInt32
    let trackTimeRange: CMTimeRange
    let samples: [OutputMediaAACSampleIdentity]
    /// Exact MPEG-4 AAC codec configuration bytes returned by Core Media's
    /// magic-cookie API. For AAC media these bytes carry the AudioSpecificConfig.
    let codecConfigurationMagicCookie: Data
    /// Semantic channel-layout identity. `nil` explicitly records that Core
    /// Media supplied no channel layout; absence is distinct from every layout.
    let channelLayout: OutputMediaAACChannelLayoutIdentity?
    /// SHA-256 over the reader's versioned, big-endian serialization of the
    /// track identity, codec configuration, semantic channel layout, and every
    /// compressed AAC access unit's semantic timing and exact payload bytes in
    /// packet order.
    let canonicalSHA256: String

    init(
        codec: AudioFormatID,
        sampleRate: Double,
        channelCount: UInt32,
        trackTimeRange: CMTimeRange,
        samples: [OutputMediaAACSampleIdentity],
        canonicalSHA256: String,
        codecConfigurationMagicCookie: Data = Data(),
        channelLayout: OutputMediaAACChannelLayoutIdentity? = nil
    ) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.trackTimeRange = trackTimeRange
        self.samples = samples
        self.codecConfigurationMagicCookie = codecConfigurationMagicCookie
        self.channelLayout = channelLayout
        self.canonicalSHA256 = canonicalSHA256
    }
}

struct OutputMediaVerificationExpectation: @unchecked Sendable, Equatable {
    let resolution: VideoResolution
    let codec: OutputCodec
    let timing: FrameTimingLedgerSnapshot
    let timedMetadata: [String: String]
    let videoColor: OutputMediaVideoColorExpectation?
    let compressedAACIdentity: OutputMediaAACIdentity?
    let preferredTransform: CGAffineTransform?

    init(
        resolution: VideoResolution,
        codec: OutputCodec,
        timing: FrameTimingLedgerSnapshot,
        timedMetadata: [String: String] = [:],
        videoColor: OutputMediaVideoColorExpectation? = nil,
        compressedAACIdentity: OutputMediaAACIdentity? = nil,
        preferredTransform: CGAffineTransform? = nil
    ) {
        self.resolution = resolution
        self.codec = codec
        self.timing = timing
        self.timedMetadata = timedMetadata
        self.videoColor = videoColor
        self.compressedAACIdentity = compressedAACIdentity
        self.preferredTransform = preferredTransform
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
    case preferredTransformMismatch(
        expected: CGAffineTransform,
        actual: CGAffineTransform
    )
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
    case videoColorMismatch(field: String, expected: String, actual: String?)
    case compressedAACMismatch(reason: String)

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
        case .preferredTransformMismatch(let expected, let actual):
            return "Output preferred transform \(actual) does not match expected transform \(expected)."
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
        case .videoColorMismatch(let field, let expected, let actual):
            return "Reopened video \(field) \(actual ?? "missing") does not match expected \(expected)."
        case .compressedAACMismatch(let reason):
            return "Reopened compressed AAC identity differs: \(reason)."
        }
    }
}

protocol OutputMediaVerifying: Sendable {
    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaVerificationResult
}

extension OutputMediaVerifying {
    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaVerificationResult {
        try cancellationCheck()
        let result = try await verify(url: url, expectation: expectation)
        try cancellationCheck()
        return result
    }
}
