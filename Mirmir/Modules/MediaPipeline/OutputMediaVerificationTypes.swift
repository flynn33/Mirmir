import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

struct OutputMediaVideoColorExpectation: Sendable, Equatable {
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let pixelStorage: MediaVideoPixelStorage
    let chromaLocation: String?
    let compressedFullRangeVideo: Bool?
    let compressedBitsPerComponent: Int?
    let alphaMode: MediaVideoAlphaMode
    let masteringDisplayColorVolume: Data?
    let contentLightLevelInfo: Data?

    init(
        colorPrimaries: String,
        transferFunction: String,
        yCbCrMatrix: String,
        pixelFormat: OSType,
        chromaLocation: String?,
        compressedFullRangeVideo: Bool? = false,
        compressedBitsPerComponent: Int? = nil,
        alphaMode: MediaVideoAlphaMode = .none,
        masteringDisplayColorVolume: Data? = nil,
        contentLightLevelInfo: Data? = nil
    ) {
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        guard let pixelStorage = MediaVideoPixelStorage.allCases.first(
            where: { $0.pixelFormat == pixelFormat }
        ) else {
            preconditionFailure(
                "Unsupported verification pixel format \(pixelFormat)."
            )
        }
        self.pixelStorage = pixelStorage
        self.chromaLocation = chromaLocation
        self.compressedFullRangeVideo = compressedFullRangeVideo
        self.compressedBitsPerComponent = compressedBitsPerComponent
        self.alphaMode = alphaMode
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
    }

    static let sdrBT709VideoRangeLeft = OutputMediaVideoColorExpectation(
        colorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
        transferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
        yCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        chromaLocation: kCMFormatDescriptionChromaLocation_Left as String,
        compressedFullRangeVideo: false
    )

    static func preserving(
        _ format: MediaVideoFormat,
        codec: OutputCodec
    ) -> OutputMediaVideoColorExpectation {
        let compressedFullRangeVideo: Bool? =
            codec.requiresQuickTimeMovieContainer
                || !format.pixelStorage.usesYCbCr
            ? nil
            : format.pixelStorage.codeRange == .full
        let compressedBitsPerComponent: Int?
        switch codec {
        case .h264:
            compressedBitsPerComponent = nil
        case .hevc:
            if format.pixelStorage.chromaSampling == .yuv422 {
                compressedBitsPerComponent = 10
            } else {
                compressedBitsPerComponent =
                    format.pixelStorage.bitDepth
            }
        case .proRes422HQ:
            // Core Media documents BitsPerComponent as optional, and the
            // macOS ProRes 422 HQ writer reports 12 here even though `apch`
            // identifies the ProRes 422 HQ codec. Verify that exact codec and
            // the requested decoded storage instead of treating this
            // non-authoritative extension as encoded bitstream identity.
            compressedBitsPerComponent = nil
        case .proRes4444:
            compressedBitsPerComponent = format.hasAlpha ? 16 : 12
        }
        return OutputMediaVideoColorExpectation(
            colorPrimaries: format.colorPrimaries.cmValue,
            transferFunction: format.transferFunction.cmValue,
            yCbCrMatrix: format.cmYCbCrMatrix,
            pixelFormat: format.pixelStorage.pixelFormat,
            // The ProRes 422 HQ writer does not publish a Core Media chroma
            // location extension. Its exact `apch` codec identity and decoded
            // 4:2:2 plane geometry remain mandatory verification evidence.
            chromaLocation: codec == .proRes422HQ
                ? nil
                : format.chromaLocation,
            compressedFullRangeVideo: compressedFullRangeVideo,
            compressedBitsPerComponent: compressedBitsPerComponent,
            alphaMode: format.alphaMode,
            masteringDisplayColorVolume:
                format.masteringDisplayColorVolume,
            contentLightLevelInfo: format.contentLightLevelInfo
        )
    }

    var pixelFormat: OSType {
        pixelStorage.pixelFormat
    }

    var expectedPlaneCount: Int {
        pixelStorage.expectedPlaneCount
    }

    var chromaSampling: MediaVideoChromaSampling {
        pixelStorage.chromaSampling
    }

    var codeRange: MediaVideoCodeRange {
        pixelStorage.codeRange
    }

    var componentBitDepth: Int {
        pixelStorage.bitDepth
    }

    var alphaBitDepth: Int? {
        pixelStorage.alphaBitDepth
    }

    var usesYCbCr: Bool {
        pixelStorage.usesYCbCr
    }
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

struct OutputMediaTrackReference: Hashable, Sendable {
    let mediaType: String
    let ordinal: Int
}

struct OutputMediaMetadataIdentity: Sendable, Equatable {
    let canonicalItems: [Data]
}

struct OutputMediaTrackSampleIdentity: Sendable, Equatable {
    let sampleCount: Int
    let totalPayloadByteCount: Int64
    let canonicalSHA256: String
}

struct OutputMediaLinearPCMFormatIdentity: Sendable, Equatable {
    let mediaSubtype: FourCharCode
    let sampleRateBitPattern: UInt64
    let formatFlags: AudioFormatFlags
    let bytesPerPacket: UInt32
    let framesPerPacket: UInt32
    let bytesPerFrame: UInt32
    let channelsPerFrame: UInt32
    let bitsPerChannel: UInt32
    let channelLayout: OutputMediaAACChannelLayoutIdentity?

    var sampleRate: Double {
        Double(bitPattern: sampleRateBitPattern)
    }
}

struct OutputMediaLinearPCMTimingRunIdentity:
    Sendable,
    Equatable {
    let presentationStart: OutputMediaSemanticTimeIdentity
    let decodeStart: OutputMediaSemanticTimeIdentity
    let frameDuration: OutputMediaSemanticTimeIdentity
    let frameCount: Int64
}

struct OutputMediaSemanticTimeIdentity: Sendable, Equatable {
    enum Kind: UInt8, Sendable {
        case invalid
        case positiveInfinity
        case negativeInfinity
        case indefinite
        case numeric
        case other
    }

    let kind: Kind
    let value: Int64
    let timescale: UInt32
    let flags: UInt32
    let epoch: Int64
}

struct OutputMediaLinearPCMTrackIdentity:
    Sendable,
    Equatable {
    let formats: [OutputMediaLinearPCMFormatIdentity]
    let timingRuns: [OutputMediaLinearPCMTimingRunIdentity]
    let audioFrameCount: Int64
    let totalPayloadByteCount: Int64
    let payloadSHA256: String
    let canonicalSHA256: String
}

struct OutputMediaTrackSegmentIdentity:
    @unchecked Sendable,
    Equatable {
    let isEmpty: Bool
    let source: CMTimeRange
    let target: CMTimeRange
}

struct OutputMediaTrackPreservationExpectation:
    @unchecked Sendable,
    Equatable {
    let reference: OutputMediaTrackReference
    let timeRange: CMTimeRange
    let naturalTimeScale: CMTimeScale
    let formatSubtypes: [FourCharCode]
    let totalSampleDataLength: Int64
    let sampleIdentity: OutputMediaTrackSampleIdentity?
    let linearPCMIdentity: OutputMediaLinearPCMTrackIdentity?
    let appleLosslessIdentity:
        OutputMediaAppleLosslessTrackIdentity?
    let segmentIdentity: [OutputMediaTrackSegmentIdentity]?
    let isEnabled: Bool
    let languageCode: String?
    let extendedLanguageTag: String?
    let metadata: OutputMediaMetadataIdentity
}

struct OutputMediaTrackAssociationExpectation: Sendable, Equatable {
    let source: OutputMediaTrackReference
    let target: OutputMediaTrackReference
    let associationType: String
}

struct OutputMediaPreservationExpectation:
    @unchecked Sendable,
    Equatable {
    let containerMetadata: OutputMediaMetadataIdentity
    let tracks: [OutputMediaTrackPreservationExpectation]
    let associations: [OutputMediaTrackAssociationExpectation]
    let expectedTrackCounts: [String: Int]
}

struct SourceMediaTrackPreservationPlan: @unchecked Sendable {
    let track: AVAssetTrack
    let metadata: [AVMetadataItem]
    let expectation: OutputMediaTrackPreservationExpectation
}

struct SourceMediaPreservationPlan: @unchecked Sendable {
    let containerMetadata: [AVMetadataItem]
    let tracks: [SourceMediaTrackPreservationPlan]
    let associations: [OutputMediaTrackAssociationExpectation]
    let expectation: OutputMediaPreservationExpectation

    func track(
        withID trackID: CMPersistentTrackID
    ) -> SourceMediaTrackPreservationPlan? {
        tracks.first { $0.track.trackID == trackID }
    }
}

struct OutputMediaVerificationExpectation: @unchecked Sendable, Equatable {
    let resolution: VideoResolution
    let codec: OutputCodec
    let timing: FrameTimingLedgerSnapshot
    let timedMetadata: [String: String]
    let videoColor: OutputMediaVideoColorExpectation?
    let compressedAACIdentity: OutputMediaAACIdentity?
    let compressedAACTrackIdentities:
        [OutputMediaAACTrackIdentity]?
    let preferredTransform: CGAffineTransform?
    let mediaPreservation: OutputMediaPreservationExpectation?
    let scanStructure: MediaVideoScanStructure
    let requiresExplicitScanStructure: Bool

    init(
        resolution: VideoResolution,
        codec: OutputCodec,
        timing: FrameTimingLedgerSnapshot,
        timedMetadata: [String: String] = [:],
        videoColor: OutputMediaVideoColorExpectation? = nil,
        compressedAACIdentity: OutputMediaAACIdentity? = nil,
        compressedAACTrackIdentities:
            [OutputMediaAACTrackIdentity]? = nil,
        preferredTransform: CGAffineTransform? = nil,
        mediaPreservation: OutputMediaPreservationExpectation? = nil,
        scanStructure: MediaVideoScanStructure = .progressive,
        requiresExplicitScanStructure: Bool = false
    ) {
        self.resolution = resolution
        self.codec = codec
        self.timing = timing
        self.timedMetadata = timedMetadata
        self.videoColor = videoColor
        self.compressedAACIdentity = compressedAACIdentity
        self.compressedAACTrackIdentities =
            compressedAACTrackIdentities
        self.preferredTransform = preferredTransform
        self.mediaPreservation = mediaPreservation
        self.scanStructure = scanStructure
        self.requiresExplicitScanStructure =
            requiresExplicitScanStructure
    }
}

struct OutputMediaVerificationResult: @unchecked Sendable, Equatable {
    let codec: String
    let resolution: VideoResolution
    let scanStructure: MediaVideoScanStructure
    let frameCount: Int
    let duration: CMTime
    let lumaPayloadBytes: Int
    let chromaPayloadBytes: Int
    let alphaPayloadBytes: Int
}

enum OutputMediaVerificationError: Error, Equatable, CustomStringConvertible {
    case emptyTimingLedger
    case reopenFailed(String)
    case videoTrackCount(expected: Int, actual: Int)
    case missingVideoFormatDescription
    case codecMismatch(expected: String, actual: String)
    case dimensionsMismatch(expected: VideoResolution, actual: VideoResolution)
    case scanStructureMismatch(
        expected: MediaVideoScanStructure,
        actual: MediaVideoScanStructure
    )
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
    case planeDimensionsMismatch(
        frameIndex: Int,
        planeIndex: Int,
        expected: VideoResolution,
        actual: VideoResolution
    )
    case planeLockFailed(frameIndex: Int, status: CVReturn)
    case emptyPlanePayload(frameIndex: Int, planeIndex: Int)
    case presentationTimeMismatch(frameIndex: Int, expected: CMTime, actual: CMTime)
    case frameDurationMismatch(frameIndex: Int, expected: CMTime, actual: CMTime)
    case mediaDurationMismatch(expected: CMTime, actual: CMTime)
    case trackEndMismatch(expected: CMTime, actual: CMTime)
    case metadataMismatch(scope: String, reason: String)
    case videoColorMismatch(field: String, expected: String, actual: String?)
    case compressedAACMismatch(reason: String)
    case mediaPreservationMismatch(reason: String)

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
        case .scanStructureMismatch(let expected, let actual):
            return "Output scan structure \(actual.rawValue) does not match "
                + "expected \(expected.rawValue)."
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
            return "Decoded frame \(frameIndex) pixel format \(actual) does not match expected format \(expected)."
        case .planeCountMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) has \(actual) planes; expected \(expected)."
        case .planeDimensionsMismatch(
            let frameIndex,
            let planeIndex,
            let expected,
            let actual
        ):
            return "Decoded frame \(frameIndex) plane \(planeIndex) dimensions "
                + "\(actual) do not match expected dimensions \(expected)."
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
        case .mediaPreservationMismatch(let reason):
            return "Reopened source-media preservation differs: \(reason)."
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
