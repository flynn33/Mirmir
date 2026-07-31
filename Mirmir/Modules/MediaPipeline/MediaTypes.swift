import Foundation
import CoreMedia
import CoreVideo
import AVFoundation
import VideoToolbox

public struct VideoResolution: Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let p720 = VideoResolution(width: 1280, height: 720)
    public static let p1080 = VideoResolution(width: 1920, height: 1080)
    public static let p1440 = VideoResolution(width: 2560, height: 1440)
    public static let p2160 = VideoResolution(width: 3840, height: 2160)

    public var description: String { "\(width)x\(height)" }

    public var isP720: Bool { self == .p720 }
    public var isP1080: Bool { self == .p1080 }
    public var isP2160: Bool { self == .p2160 }

    public func scaled(by factor: Int) -> VideoResolution {
        VideoResolution(width: width * factor, height: height * factor)
    }
}

public struct VideoPixelAspectRatio: Equatable, Sendable {
    public let horizontalSpacing: Int
    public let verticalSpacing: Int

    public init?(horizontalSpacing: Int, verticalSpacing: Int) {
        guard horizontalSpacing > 0, verticalSpacing > 0 else {
            return nil
        }
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }
}

public enum MediaVideoChromaSampling: String, Sendable {
    case yuv420 = "4:2:0"
    case yuv422 = "4:2:2"
    case yuv444 = "4:4:4"
    case rgb
}

public enum MediaVideoCodeRange: String, Sendable {
    case video
    case full
}

public enum MediaVideoPixelStorage: String, Sendable, CaseIterable {
    case nv12VideoRange8Bit = "nv12_video_range_8_bit"
    case nv12FullRange8Bit = "nv12_full_range_8_bit"
    case p010VideoRange10Bit = "p010_video_range_10_bit"
    case p010FullRange10Bit = "p010_full_range_10_bit"
    case yuv422VideoRange8Bit = "yuv_422_video_range_8_bit"
    case yuv422FullRange8Bit = "yuv_422_full_range_8_bit"
    case yuv422VideoRange10Bit = "yuv_422_video_range_10_bit"
    case yuv422FullRange10Bit = "yuv_422_full_range_10_bit"
    case yuv422VideoRange16Bit = "yuv_422_video_range_16_bit"
    case yuv444VideoRange8Bit = "yuv_444_video_range_8_bit"
    case yuv444FullRange8Bit = "yuv_444_full_range_8_bit"
    case yuv444VideoRange10Bit = "yuv_444_video_range_10_bit"
    case yuv444FullRange10Bit = "yuv_444_full_range_10_bit"
    case yuv444VideoRange16Bit = "yuv_444_video_range_16_bit"
    case yuv444VideoRange8BitWithAlpha =
        "yuv_444_video_range_8_bit_with_alpha"
    case yuv444VideoRange16BitWithAlpha =
        "yuv_444_video_range_16_bit_with_alpha"
    case yuv444VideoRange16BitWithAlphaTriPlanar =
        "yuv_444_video_range_16_bit_with_alpha_tri_planar"
    case bgra8WithAlpha = "bgra_8_bit_with_alpha"

    public var pixelFormat: OSType {
        switch self {
        case .nv12VideoRange8Bit:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12FullRange8Bit:
            return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case .p010VideoRange10Bit:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .p010FullRange10Bit:
            return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .yuv422VideoRange8Bit:
            return kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
        case .yuv422FullRange8Bit:
            return kCVPixelFormatType_422YpCbCr8BiPlanarFullRange
        case .yuv422VideoRange10Bit:
            return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .yuv422FullRange10Bit:
            return kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        case .yuv422VideoRange16Bit:
            return kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
        case .yuv444VideoRange8Bit:
            return kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        case .yuv444FullRange8Bit:
            return kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
        case .yuv444VideoRange10Bit:
            return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        case .yuv444FullRange10Bit:
            return kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        case .yuv444VideoRange16Bit:
            return kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
        case .yuv444VideoRange8BitWithAlpha:
            return kCVPixelFormatType_4444AYpCbCr8
        case .yuv444VideoRange16BitWithAlpha:
            return kCVPixelFormatType_4444AYpCbCr16
        case .yuv444VideoRange16BitWithAlphaTriPlanar:
            return kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar
        case .bgra8WithAlpha:
            return kCVPixelFormatType_32BGRA
        }
    }

    public var chromaSampling: MediaVideoChromaSampling {
        switch self {
        case .nv12VideoRange8Bit, .nv12FullRange8Bit,
             .p010VideoRange10Bit, .p010FullRange10Bit:
            return .yuv420
        case .yuv422VideoRange8Bit, .yuv422FullRange8Bit,
             .yuv422VideoRange10Bit, .yuv422FullRange10Bit,
             .yuv422VideoRange16Bit:
            return .yuv422
        case .yuv444VideoRange8Bit, .yuv444FullRange8Bit,
             .yuv444VideoRange10Bit, .yuv444FullRange10Bit,
             .yuv444VideoRange16Bit,
             .yuv444VideoRange8BitWithAlpha,
             .yuv444VideoRange16BitWithAlpha,
             .yuv444VideoRange16BitWithAlphaTriPlanar:
            return .yuv444
        case .bgra8WithAlpha:
            return .rgb
        }
    }

    public var codeRange: MediaVideoCodeRange {
        switch self {
        case .nv12FullRange8Bit, .p010FullRange10Bit,
             .yuv422FullRange8Bit, .yuv422FullRange10Bit,
             .yuv444FullRange8Bit, .yuv444FullRange10Bit,
             .bgra8WithAlpha:
            return .full
        case .nv12VideoRange8Bit, .p010VideoRange10Bit,
             .yuv422VideoRange8Bit, .yuv422VideoRange10Bit,
             .yuv422VideoRange16Bit, .yuv444VideoRange8Bit,
             .yuv444VideoRange10Bit, .yuv444VideoRange16Bit,
             .yuv444VideoRange8BitWithAlpha,
             .yuv444VideoRange16BitWithAlpha,
             .yuv444VideoRange16BitWithAlphaTriPlanar:
            return .video
        }
    }

    public var bitDepth: Int {
        switch self {
        case .nv12VideoRange8Bit, .nv12FullRange8Bit,
             .yuv422VideoRange8Bit, .yuv422FullRange8Bit,
             .yuv444VideoRange8Bit, .yuv444FullRange8Bit,
             .yuv444VideoRange8BitWithAlpha, .bgra8WithAlpha:
            return 8
        case .p010VideoRange10Bit, .p010FullRange10Bit,
             .yuv422VideoRange10Bit, .yuv422FullRange10Bit,
             .yuv444VideoRange10Bit, .yuv444FullRange10Bit:
            return 10
        case .yuv422VideoRange16Bit, .yuv444VideoRange16Bit,
             .yuv444VideoRange16BitWithAlpha,
             .yuv444VideoRange16BitWithAlphaTriPlanar:
            return 16
        }
    }

    public var storedCodeShift: Int {
        bitDepth == 10 ? 6 : 0
    }

    public var bytesPerComponent: Int {
        bitDepth > 8 ? 2 : 1
    }

    public var expectedPlaneCount: Int {
        switch self {
        case .nv12VideoRange8Bit, .nv12FullRange8Bit,
             .p010VideoRange10Bit, .p010FullRange10Bit,
             .yuv422VideoRange8Bit, .yuv422FullRange8Bit,
             .yuv422VideoRange10Bit, .yuv422FullRange10Bit,
             .yuv422VideoRange16Bit, .yuv444VideoRange8Bit,
             .yuv444FullRange8Bit, .yuv444VideoRange10Bit,
             .yuv444FullRange10Bit, .yuv444VideoRange16Bit:
            return 2
        case .yuv444VideoRange16BitWithAlphaTriPlanar:
            return 3
        case .yuv444VideoRange8BitWithAlpha,
             .yuv444VideoRange16BitWithAlpha, .bgra8WithAlpha:
            return 0
        }
    }

    public var alphaBitDepth: Int? {
        switch self {
        case .yuv444VideoRange8BitWithAlpha, .bgra8WithAlpha:
            return 8
        case .yuv444VideoRange16BitWithAlpha,
             .yuv444VideoRange16BitWithAlphaTriPlanar:
            return 16
        default:
            return nil
        }
    }

    public var hasAlpha: Bool {
        alphaBitDepth != nil
    }

    public var usesYCbCr: Bool {
        chromaSampling != .rgb
    }

    public var isBiPlanar: Bool {
        expectedPlaneCount == 2
    }

    public var isTriPlanar: Bool {
        expectedPlaneCount == 3
    }

    public var isPacked: Bool {
        expectedPlaneCount == 0
    }
}

public enum MediaVideoTransferFunction: String, Sendable {
    case bt709 = "bt_709"
    case pq
    case hlg

    public var isHDR: Bool {
        self == .pq || self == .hlg
    }

    var avValue: String {
        switch self {
        case .bt709:
            return AVVideoTransferFunction_ITU_R_709_2
        case .pq:
            return AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case .hlg:
            return AVVideoTransferFunction_ITU_R_2100_HLG
        }
    }

    var cmValue: String {
        switch self {
        case .bt709:
            return kCMFormatDescriptionTransferFunction_ITU_R_709_2
                as String
        case .pq:
            return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                as String
        case .hlg:
            return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                as String
        }
    }
}

public enum MediaVideoColorPrimaries: String, Sendable {
    case bt709 = "bt_709"
    case bt2020 = "bt_2020"

    var avValue: String {
        switch self {
        case .bt709:
            return AVVideoColorPrimaries_ITU_R_709_2
        case .bt2020:
            return AVVideoColorPrimaries_ITU_R_2020
        }
    }

    var cmValue: String {
        switch self {
        case .bt709:
            return kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        case .bt2020:
            return kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        }
    }
}

public enum MediaVideoAlphaMode: String, Sendable {
    case none
    case straight
    case premultiplied

    var compressionValue: CFString? {
        switch self {
        case .none:
            return nil
        case .straight:
            return kVTAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kVTAlphaChannelMode_PremultipliedAlpha
        }
    }

    var imageBufferValue: CFString? {
        switch self {
        case .none:
            return nil
        case .straight:
            return kCVImageBufferAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kCVImageBufferAlphaChannelMode_PremultipliedAlpha
        }
    }
}

public struct MediaVideoFormat: Equatable, Sendable, CustomStringConvertible {
    public let pixelStorage: MediaVideoPixelStorage
    public let colorPrimaries: MediaVideoColorPrimaries
    public let transferFunction: MediaVideoTransferFunction
    public let alphaMode: MediaVideoAlphaMode
    public let masteringDisplayColorVolume: Data?
    public let contentLightLevelInfo: Data?

    public var isHDR: Bool {
        transferFunction.isHDR
    }

    public var hasAlpha: Bool {
        pixelStorage.hasAlpha
    }

    public var supportedOutputCodecs: [OutputCodec] {
        switch pixelStorage.chromaSampling {
        case .yuv420:
            return pixelStorage.bitDepth == 8
                ? [.hevc, .h264]
                : [.hevc]
        case .yuv422:
            return pixelStorage.bitDepth == 16
                ? [.proRes422HQ]
                : [.hevc]
        case .yuv444:
            return [.proRes4444]
        case .rgb:
            return [.hevc]
        }
    }

    public func supports(outputCodec: OutputCodec) -> Bool {
        supportedOutputCodecs.contains(outputCodec)
    }

    public var requiresQuickTimeMovieOutput: Bool {
        supportedOutputCodecs.allSatisfy(
            \.requiresQuickTimeMovieContainer
        )
    }

    public var description: String {
        [
            pixelStorage.rawValue,
            colorPrimaries.rawValue,
            transferFunction.rawValue,
            alphaMode.rawValue
        ].joined(separator: "/")
    }

    init(
        pixelStorage: MediaVideoPixelStorage,
        colorPrimaries: MediaVideoColorPrimaries,
        transferFunction: MediaVideoTransferFunction,
        alphaMode: MediaVideoAlphaMode = .none,
        masteringDisplayColorVolume: Data? = nil,
        contentLightLevelInfo: Data? = nil
    ) {
        precondition(
            pixelStorage.hasAlpha == (alphaMode != .none),
            "Alpha storage and alpha semantics must be declared together."
        )
        self.pixelStorage = pixelStorage
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.alphaMode = alphaMode
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
    }

    public static let sdrBT709 = MediaVideoFormat(
        pixelStorage: .nv12VideoRange8Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709TenBit = MediaVideoFormat(
        pixelStorage: .p010VideoRange10Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT2020TenBit = MediaVideoFormat(
        pixelStorage: .p010VideoRange10Bit,
        colorPrimaries: .bt2020,
        transferFunction: .bt709
    )

    public static let sdrBT709FullRange = MediaVideoFormat(
        pixelStorage: .nv12FullRange8Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709TenBitFullRange = MediaVideoFormat(
        pixelStorage: .p010FullRange10Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV422 = MediaVideoFormat(
        pixelStorage: .yuv422VideoRange8Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV422FullRange = MediaVideoFormat(
        pixelStorage: .yuv422FullRange8Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV422TenBit = MediaVideoFormat(
        pixelStorage: .yuv422VideoRange10Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV422TenBitFullRange = MediaVideoFormat(
        pixelStorage: .yuv422FullRange10Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV422SixteenBit = MediaVideoFormat(
        pixelStorage: .yuv422VideoRange16Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV444 = MediaVideoFormat(
        pixelStorage: .yuv444VideoRange8Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV444FullRange = MediaVideoFormat(
        pixelStorage: .yuv444FullRange8Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV444TenBit = MediaVideoFormat(
        pixelStorage: .yuv444VideoRange10Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV444TenBitFullRange = MediaVideoFormat(
        pixelStorage: .yuv444FullRange10Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static let sdrBT709YUV444SixteenBit = MediaVideoFormat(
        pixelStorage: .yuv444VideoRange16Bit,
        colorPrimaries: .bt709,
        transferFunction: .bt709
    )

    public static func hdrBT2020PQ(
        masteringDisplayColorVolume: Data? = nil,
        contentLightLevelInfo: Data? = nil
    ) -> MediaVideoFormat {
        MediaVideoFormat(
            pixelStorage: .p010VideoRange10Bit,
            colorPrimaries: .bt2020,
            transferFunction: .pq,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevelInfo: contentLightLevelInfo
        )
    }

    public static func hdrBT2020HLG(
        masteringDisplayColorVolume: Data? = nil,
        contentLightLevelInfo: Data? = nil
    ) -> MediaVideoFormat {
        MediaVideoFormat(
            pixelStorage: .p010VideoRange10Bit,
            colorPrimaries: .bt2020,
            transferFunction: .hlg,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevelInfo: contentLightLevelInfo
        )
    }

    public static func hdrBT2020PQYUV444FullRange(
        masteringDisplayColorVolume: Data? = nil,
        contentLightLevelInfo: Data? = nil
    ) -> MediaVideoFormat {
        MediaVideoFormat(
            pixelStorage: .yuv444FullRange10Bit,
            colorPrimaries: .bt2020,
            transferFunction: .pq,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevelInfo: contentLightLevelInfo
        )
    }

    public static func hdrBT2020HLGYUV444FullRange(
        masteringDisplayColorVolume: Data? = nil,
        contentLightLevelInfo: Data? = nil
    ) -> MediaVideoFormat {
        MediaVideoFormat(
            pixelStorage: .yuv444FullRange10Bit,
            colorPrimaries: .bt2020,
            transferFunction: .hlg,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevelInfo: contentLightLevelInfo
        )
    }

    static func sdrBT709WithAlpha(
        mode: MediaVideoAlphaMode
    ) -> MediaVideoFormat {
        precondition(mode != .none)
        return MediaVideoFormat(
            pixelStorage: .bgra8WithAlpha,
            colorPrimaries: .bt709,
            transferFunction: .bt709,
            alphaMode: mode
        )
    }

    public static func sdrBT709YUV444WithAlpha(
        mode: MediaVideoAlphaMode
    ) -> MediaVideoFormat {
        precondition(mode != .none)
        return MediaVideoFormat(
            pixelStorage: .yuv444VideoRange8BitWithAlpha,
            colorPrimaries: .bt709,
            transferFunction: .bt709,
            alphaMode: mode
        )
    }

    public static func sdrBT709HighPrecisionPackedAlpha(
        mode: MediaVideoAlphaMode
    ) -> MediaVideoFormat {
        precondition(mode != .none)
        return MediaVideoFormat(
            pixelStorage: .yuv444VideoRange16BitWithAlpha,
            colorPrimaries: .bt709,
            transferFunction: .bt709,
            alphaMode: mode
        )
    }

    public static func sdrBT709HighPrecisionAlpha(
        mode: MediaVideoAlphaMode
    ) -> MediaVideoFormat {
        precondition(mode != .none)
        return MediaVideoFormat(
            pixelStorage:
                .yuv444VideoRange16BitWithAlphaTriPlanar,
            colorPrimaries: .bt709,
            transferFunction: .bt709,
            alphaMode: mode
        )
    }

    var yCbCrMatrix: String {
        switch colorPrimaries {
        case .bt709:
            return AVVideoYCbCrMatrix_ITU_R_709_2
        case .bt2020:
            return AVVideoYCbCrMatrix_ITU_R_2020
        }
    }

    var cmYCbCrMatrix: String {
        switch colorPrimaries {
        case .bt709:
            return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        case .bt2020:
            return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
        }
    }

    var chromaLocation: String? {
        switch pixelStorage.chromaSampling {
        case .yuv420, .yuv422:
            return kCMFormatDescriptionChromaLocation_Left as String
        case .yuv444, .rgb:
            return nil
        }
    }

    func validate(pixelBuffer: CVPixelBuffer) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == pixelStorage.pixelFormat else {
            throw MediaPipelineError.outputPixelFormatMismatch(
                expected: pixelStorage.pixelFormat,
                actual: actualFormat
            )
        }
        let actualPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard actualPlaneCount == pixelStorage.expectedPlaneCount else {
            throw PixelBufferBridgeError.invalidPlaneCount(
                expected: pixelStorage.expectedPlaneCount,
                actual: actualPlaneCount
            )
        }
    }

    func installAttachments(on pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            colorPrimaries.cmValue as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            transferFunction.cmValue as CFString,
            .shouldPropagate
        )
        if pixelStorage.usesYCbCr {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                cmYCbCrMatrix as CFString,
                .shouldPropagate
            )
            if let chromaLocation {
                CVBufferSetAttachment(
                    pixelBuffer,
                    kCVImageBufferChromaLocationTopFieldKey,
                    chromaLocation as CFString,
                    .shouldPropagate
                )
            }
        }
        if let alphaMode = alphaMode.imageBufferValue {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferAlphaChannelModeKey,
                alphaMode,
                .shouldPropagate
            )
        }
        if let masteringDisplayColorVolume {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                masteringDisplayColorVolume as CFData,
                .shouldPropagate
            )
        }
        if let contentLightLevelInfo {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferContentLightLevelInfoKey,
                contentLightLevelInfo as CFData,
                .shouldPropagate
            )
        }
    }
}

public enum SourceProfileValidationError:
    Error,
    Equatable,
    Sendable {
    case invalidAudioTrackCount(Int)
}

public enum SourceMediaPreservationVerificationLevel:
    String,
    Sendable,
    Equatable {
    case exactProbe = "exact_probe"
    case sourceCompatibleDefault = "source_compatible_default"
}

public enum SourceMediaPreservationGap:
    String,
    Sendable,
    Equatable {
    case nonAACAudioCodec = "non_aac_audio_codec"
    case aacIdentityUnavailable = "aac_identity_unavailable"
    case appleLosslessIdentityUnavailable =
        "apple_lossless_identity_unavailable"
    case unsupportedLinearPCMVariant =
        "unsupported_linear_pcm_variant"
    case linearPCMIdentityUnavailable =
        "linear_pcm_identity_unavailable"
    case trackIdentityUnavailable = "track_identity_unavailable"
    case metadataIdentityUnavailable = "metadata_identity_unavailable"
    case unsupportedAssociation = "unsupported_track_association"
}

public enum SourceMediaPreservationSupport: Sendable, Equatable {
    case exact
    case sourceCompatibleDefault
    case unavailable(
        gap: SourceMediaPreservationGap,
        reason: String,
        missingCapability: String
    )

    public var isCompatible: Bool {
        switch self {
        case .exact, .sourceCompatibleDefault:
            return true
        case .unavailable:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .exact:
            return "Exact passthrough verified"
        case .sourceCompatibleDefault:
            return "Source-compatible"
        case .unavailable(_, _, let missingCapability):
            return "Needs \(missingCapability)"
        }
    }

    public var failureReason: String? {
        guard case .unavailable(_, let reason, _) = self else {
            return nil
        }
        return reason
    }

    public var missingCapability: String? {
        guard case .unavailable(_, _, let missingCapability) = self else {
            return nil
        }
        return missingCapability
    }
}

public struct SourceMediaTrackCapability:
    Sendable,
    Equatable,
    Identifiable {
    public let mediaType: String
    public let ordinal: Int
    public let formatSubtypes: [String]
    public let isEnabled: Bool?
    public let languageCode: String?
    public let extendedLanguageTag: String?
    public let sampleRate: Double?
    public let channelCount: UInt32?
    public let compressedAudioIdentitySHA256: String?
    public let linearPCMAudioIdentitySHA256: String?
    public let exactTrackIdentitySHA256: String?
    public let support: SourceMediaPreservationSupport

    public var id: String {
        "\(mediaType):\(ordinal)"
    }

    public var displayName: String {
        "\(Self.mediaTypeDisplayName(mediaType)) track \(ordinal + 1)"
    }

    public var formatSummary: String {
        guard !formatSubtypes.isEmpty else {
            return "Format supplied by source"
        }
        return formatSubtypes.map(Self.formatDisplayName)
            .joined(separator: ", ")
    }

    public var displaySummary: String {
        var components = [formatSummary]
        if let sampleRate {
            components.append(
                sampleRate.formatted(
                    .number.precision(.fractionLength(0...2))
                ) + " Hz"
            )
        }
        if let channelCount {
            components.append(
                channelCount == 1
                    ? "1 channel"
                    : "\(channelCount) channels"
            )
        }
        if let language = extendedLanguageTag ?? languageCode {
            components.append(language)
        }
        components.append(support.displayName)
        return components.joined(separator: " · ")
    }

    public static func mediaTypeDisplayName(_ mediaType: String) -> String {
        switch mediaType {
        case AVMediaType.audio.rawValue:
            return "Audio"
        case AVMediaType.subtitle.rawValue:
            return "Subtitle"
        case AVMediaType.text.rawValue:
            return "Text"
        case AVMediaType.closedCaption.rawValue:
            return "Closed caption"
        case AVMediaType.metadata.rawValue:
            return "Metadata"
        case AVMediaType.timecode.rawValue:
            return "Timecode"
        case AVMediaType.video.rawValue:
            return "Video"
        default:
            return "Media \(mediaType)"
        }
    }

    public static func formatDisplayName(_ subtype: String) -> String {
        switch subtype {
        case "aac ":
            return "AAC (aac )"
        case "lpcm":
            return "Linear PCM (lpcm)"
        case "alac":
            return "Apple Lossless (alac)"
        case "ac-3":
            return "Dolby Digital (ac-3)"
        case "ec-3":
            return "Dolby Digital Plus (ec-3)"
        case "Opus", "opus":
            return "Opus (\(subtype))"
        case "tx3g":
            return "Timed Text (tx3g)"
        case "text":
            return "QuickTime Text (text)"
        case "c608":
            return "CEA-608 (c608)"
        case "tmcd":
            return "Timecode (tmcd)"
        default:
            return "\(subtype) (\(subtype.utf8.count == 4 ? "FourCC" : "format"))"
        }
    }
}

public struct SourceMediaTrackAssociationCapability:
    Sendable,
    Equatable,
    Identifiable {
    public let sourceMediaType: String
    public let sourceOrdinal: Int
    public let targetMediaType: String
    public let targetOrdinal: Int?
    public let associationType: String
    public let support: SourceMediaPreservationSupport

    public var id: String {
        "\(sourceMediaType):\(sourceOrdinal):\(associationType):"
            + "\(targetMediaType):"
            + "\(targetOrdinal.map { String($0) } ?? "?")"
    }

    public var displaySummary: String {
        let source = SourceMediaTrackCapability.mediaTypeDisplayName(
            sourceMediaType
        )
        let target = SourceMediaTrackCapability.mediaTypeDisplayName(
            targetMediaType
        )
        let targetIndex = targetOrdinal.map { " \($0 + 1)" } ?? ""
        return "\(source) \(sourceOrdinal + 1) → \(target)\(targetIndex) "
            + "(\(associationType)) · \(support.displayName)"
    }
}

public struct SourceMediaPreservationCapability:
    Sendable,
    Equatable {
    public let verificationLevel:
        SourceMediaPreservationVerificationLevel
    public let tracks: [SourceMediaTrackCapability]
    public let associations:
        [SourceMediaTrackAssociationCapability]
    public let hasContainerMetadata: Bool
    public let containerMetadataIdentitySHA256: String?
    public let support: SourceMediaPreservationSupport

    public var audioTracks: [SourceMediaTrackCapability] {
        tracks.filter {
            $0.mediaType == AVMediaType.audio.rawValue
        }
    }

    public var auxiliaryTracks: [SourceMediaTrackCapability] {
        tracks.filter {
            $0.mediaType != AVMediaType.audio.rawValue
        }
    }

    public var hasLinearPCMAudioTracks: Bool {
        audioTracks.contains {
            $0.formatSubtypes.contains("lpcm")
        }
    }

    public var hasQuickTimeOnlyTrackAssociations: Bool {
        associations.contains {
            $0.associationType == "auxl"
                && $0.support.isCompatible
        }
    }

    public func requiresQuickTimeMovieContainer(
        preserveAudio: Bool
    ) -> Bool {
        let preservesLinearPCM =
            preserveAudio && hasLinearPCMAudioTracks
        return preservesLinearPCM
            || hasQuickTimeOnlyTrackAssociations
    }

    public var inventorySummary: String {
        let audio = countDescription(
            audioTracks.count,
            singular: "audio track",
            plural: "audio tracks"
        )
        let auxiliary = countDescription(
            auxiliaryTracks.count,
            singular: "auxiliary track",
            plural: "auxiliary tracks"
        )
        let association = countDescription(
            associations.count,
            singular: "association",
            plural: "associations"
        )
        let container = hasContainerMetadata
            ? "container metadata"
            : "no container metadata"
        return "\(audio), \(auxiliary), \(association), \(container)"
    }

    public var displaySummary: String {
        if let failure = failureReason(
            preserveAudio: !audioTracks.isEmpty,
            preserveSubtitles: true,
            preserveMetadata: true
        ) {
            return failure
        }
        return verificationSummary
    }

    public var verificationSummary: String {
        switch verificationLevel {
        case .exactProbe:
            return "All selected source media has an exact passthrough path."
        case .sourceCompatibleDefault:
            return "The source declares compatible media preservation."
        }
    }

    public func failureReason(
        preserveAudio: Bool,
        preserveSubtitles: Bool,
        preserveMetadata: Bool
    ) -> String? {
        for track in tracks where isSelected(
            mediaType: track.mediaType,
            preserveAudio: preserveAudio,
            preserveSubtitles: preserveSubtitles,
            preserveMetadata: preserveMetadata
        ) {
            if let reason = track.support.failureReason {
                return reason
            }
        }

        for association in associations where isSelected(
            mediaType: association.sourceMediaType,
            preserveAudio: preserveAudio,
            preserveSubtitles: preserveSubtitles,
            preserveMetadata: preserveMetadata
        ) {
            if let reason = association.support.failureReason {
                return reason
            }
            guard isSelected(
                mediaType: association.targetMediaType,
                preserveAudio: preserveAudio,
                preserveSubtitles: preserveSubtitles,
                preserveMetadata: preserveMetadata
            ) else {
                return disabledAssociationFailureReason(association)
            }
        }

        if preserveMetadata,
           let reason = support.failureReason {
            return reason
        }
        return nil
    }

    public static func sourceCompatible(
        audioTrackCount: Int,
        subtitleTrackCount: Int,
        metadataTrackCount: Int,
        hasContainerMetadata: Bool
    ) -> SourceMediaPreservationCapability {
        var tracks: [SourceMediaTrackCapability] = []
        tracks.reserveCapacity(
            audioTrackCount + subtitleTrackCount + metadataTrackCount
        )
        for ordinal in 0..<audioTrackCount {
            tracks.append(sourceCompatibleTrack(
                mediaType: AVMediaType.audio.rawValue,
                ordinal: ordinal
            ))
        }
        for ordinal in 0..<subtitleTrackCount {
            tracks.append(sourceCompatibleTrack(
                mediaType: AVMediaType.subtitle.rawValue,
                ordinal: ordinal
            ))
        }
        for ordinal in 0..<metadataTrackCount {
            tracks.append(sourceCompatibleTrack(
                mediaType: AVMediaType.metadata.rawValue,
                ordinal: ordinal
            ))
        }
        return SourceMediaPreservationCapability(
            verificationLevel: .sourceCompatibleDefault,
            tracks: tracks,
            associations: [],
            hasContainerMetadata: hasContainerMetadata,
            containerMetadataIdentitySHA256: nil,
            support: .sourceCompatibleDefault
        )
    }

    private static func sourceCompatibleTrack(
        mediaType: String,
        ordinal: Int
    ) -> SourceMediaTrackCapability {
        SourceMediaTrackCapability(
            mediaType: mediaType,
            ordinal: ordinal,
            formatSubtypes: [],
            isEnabled: nil,
            languageCode: nil,
            extendedLanguageTag: nil,
            sampleRate: nil,
            channelCount: nil,
            compressedAudioIdentitySHA256: nil,
            linearPCMAudioIdentitySHA256: nil,
            exactTrackIdentitySHA256: nil,
            support: .sourceCompatibleDefault
        )
    }

    private func isSelected(
        mediaType: String,
        preserveAudio: Bool,
        preserveSubtitles: Bool,
        preserveMetadata: Bool
    ) -> Bool {
        switch mediaType {
        case AVMediaType.video.rawValue:
            return true
        case AVMediaType.audio.rawValue:
            return preserveAudio
        case AVMediaType.subtitle.rawValue,
             AVMediaType.text.rawValue,
             AVMediaType.closedCaption.rawValue:
            return preserveSubtitles
        case AVMediaType.metadata.rawValue,
             AVMediaType.timecode.rawValue:
            return preserveMetadata
        default:
            return false
        }
    }

    private func disabledAssociationFailureReason(
        _ association: SourceMediaTrackAssociationCapability
    ) -> String {
        let source = SourceMediaTrackCapability.mediaTypeDisplayName(
            association.sourceMediaType
        )
        let target = SourceMediaTrackCapability.mediaTypeDisplayName(
            association.targetMediaType
        )
        let targetIndex = association.targetOrdinal.map {
            " \($0 + 1)"
        } ?? ""
        let action: String
        switch association.targetMediaType {
        case AVMediaType.audio.rawValue:
            action = "Enable Preserve Source Audio Tracks."
        case AVMediaType.subtitle.rawValue,
             AVMediaType.text.rawValue,
             AVMediaType.closedCaption.rawValue:
            action = "Enable source subtitle and caption preservation."
        case AVMediaType.metadata.rawValue,
             AVMediaType.timecode.rawValue:
            action = "Enable source metadata and timecode preservation."
        default:
            action = "Preserve the associated target track."
        }
        return "\(source) track \(association.sourceOrdinal + 1) has "
            + "association \(association.associationType) to \(target)"
            + "\(targetIndex), but that target is not selected. \(action)"
    }

    private func countDescription(
        _ count: Int,
        singular: String,
        plural: String
    ) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(plural)"
    }
}

public struct SourceProfile: Sendable {
    public let url: URL
    public let resolution: VideoResolution
    public let codedResolution: VideoResolution
    public let pixelAspectRatio: VideoPixelAspectRatio?
    public let frameRate: Double
    public let durationSeconds: Double
    public let estimatedFrameCount: Int
    public let codecHint: String?
    public let hasAudio: Bool
    public let audioTrackCount: Int
    public let videoFormat: MediaVideoFormat
    public let scanStructure: MediaVideoScanStructure
    public let subtitleTrackCount: Int
    public let metadataTrackCount: Int
    public let hasContainerMetadata: Bool
    public let mediaPreservationCapability:
        SourceMediaPreservationCapability

    public var audioTrackDescription: String {
        switch audioTrackCount {
        case 0:
            return "No audio tracks"
        case 1:
            return "1 audio track"
        default:
            return "\(audioTrackCount) audio tracks"
        }
    }

    public init(
        url: URL,
        resolution: VideoResolution,
        codedResolution: VideoResolution? = nil,
        pixelAspectRatio: VideoPixelAspectRatio? = nil,
        frameRate: Double,
        durationSeconds: Double,
        estimatedFrameCount: Int,
        codecHint: String?,
        hasAudio: Bool,
        videoFormat: MediaVideoFormat = .sdrBT709,
        scanStructure: MediaVideoScanStructure = .progressive,
        subtitleTrackCount: Int = 0,
        metadataTrackCount: Int = 0,
        hasContainerMetadata: Bool = false,
        mediaPreservationCapability:
            SourceMediaPreservationCapability? = nil
    ) {
        self.url = url
        self.resolution = resolution
        self.codedResolution = codedResolution ?? resolution
        self.pixelAspectRatio = pixelAspectRatio
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.estimatedFrameCount = estimatedFrameCount
        self.codecHint = codecHint
        self.hasAudio = hasAudio
        self.audioTrackCount = hasAudio ? 1 : 0
        self.videoFormat = videoFormat
        self.scanStructure = scanStructure
        self.subtitleTrackCount = subtitleTrackCount
        self.metadataTrackCount = metadataTrackCount
        self.hasContainerMetadata = hasContainerMetadata
        self.mediaPreservationCapability =
            mediaPreservationCapability
            ?? .sourceCompatible(
                audioTrackCount: hasAudio ? 1 : 0,
                subtitleTrackCount: subtitleTrackCount,
                metadataTrackCount: metadataTrackCount,
                hasContainerMetadata: hasContainerMetadata
            )
    }

    public init(
        url: URL,
        resolution: VideoResolution,
        codedResolution: VideoResolution? = nil,
        pixelAspectRatio: VideoPixelAspectRatio? = nil,
        frameRate: Double,
        durationSeconds: Double,
        estimatedFrameCount: Int,
        codecHint: String?,
        audioTrackCount: Int,
        videoFormat: MediaVideoFormat = .sdrBT709,
        scanStructure: MediaVideoScanStructure = .progressive,
        subtitleTrackCount: Int = 0,
        metadataTrackCount: Int = 0,
        hasContainerMetadata: Bool = false,
        mediaPreservationCapability:
            SourceMediaPreservationCapability? = nil
    ) throws {
        guard audioTrackCount >= 0 else {
            throw SourceProfileValidationError
                .invalidAudioTrackCount(audioTrackCount)
        }
        self.url = url
        self.resolution = resolution
        self.codedResolution = codedResolution ?? resolution
        self.pixelAspectRatio = pixelAspectRatio
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.estimatedFrameCount = estimatedFrameCount
        self.codecHint = codecHint
        self.hasAudio = audioTrackCount > 0
        self.audioTrackCount = audioTrackCount
        self.videoFormat = videoFormat
        self.scanStructure = scanStructure
        self.subtitleTrackCount = subtitleTrackCount
        self.metadataTrackCount = metadataTrackCount
        self.hasContainerMetadata = hasContainerMetadata
        self.mediaPreservationCapability =
            mediaPreservationCapability
            ?? .sourceCompatible(
                audioTrackCount: audioTrackCount,
                subtitleTrackCount: subtitleTrackCount,
                metadataTrackCount: metadataTrackCount,
                hasContainerMetadata: hasContainerMetadata
            )
    }
}

public enum OutputCodec: String, Sendable, CaseIterable, Identifiable {
    case hevc
    case h264
    case proRes422HQ = "prores_422_hq"
    case proRes4444 = "prores_4444"

    public var id: String { rawValue }

    public var avCodecKey: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        }
    }

    public var requiresQuickTimeMovieContainer: Bool {
        self == .proRes422HQ || self == .proRes4444
    }

    public var displayName: String {
        switch self {
        case .hevc:
            return "HEVC"
        case .h264:
            return "H.264"
        case .proRes422HQ:
            return "ProRes 422 HQ"
        case .proRes4444:
            return "ProRes 4444"
        }
    }
}

enum MediaOutputContainerPolicy {
    static func preferredPathExtension(
        codec: OutputCodec,
        videoFormat: MediaVideoFormat,
        preservationCapability:
            SourceMediaPreservationCapability,
        preserveAudio: Bool
    ) -> String {
        requiresQuickTimeMovie(
            codec: codec,
            videoFormat: videoFormat,
            preservationCapability: preservationCapability,
            preserveAudio: preserveAudio
        ) ? "mov" : "mp4"
    }

    static func validationError(
        pathExtension: String,
        codec: OutputCodec,
        videoFormat: MediaVideoFormat,
        preservationCapability:
            SourceMediaPreservationCapability,
        preserveAudio: Bool
    ) -> MediaPipelineError? {
        let normalizedExtension = pathExtension.lowercased()
        guard normalizedExtension == "mp4"
                || normalizedExtension == "mov" else {
            return .unsupportedOutputContainer(
                normalizedExtension
            )
        }
        guard normalizedExtension != "mov" else {
            return nil
        }
        if codec.requiresQuickTimeMovieContainer {
            return .outputContainerCannotPreserveCodec(
                pathExtension: normalizedExtension,
                codec: codec
            )
        }
        if videoFormat.hasAlpha
            || videoFormat.requiresQuickTimeMovieOutput {
            return .outputContainerCannotPreserveVideoFormat(
                pathExtension: normalizedExtension,
                format: videoFormat
            )
        }
        if preservationCapability
            .requiresQuickTimeMovieContainer(
                preserveAudio: preserveAudio
            ) {
            if preserveAudio,
               preservationCapability.hasLinearPCMAudioTracks {
                return .outputContainerCannotPreserveLinearPCM(
                    pathExtension: normalizedExtension
                )
            }
            if preservationCapability
                .hasQuickTimeOnlyTrackAssociations {
                return
                    .outputContainerCannotPreserveTrackAssociations(
                        pathExtension: normalizedExtension
                    )
            }
        }
        return nil
    }

    private static func requiresQuickTimeMovie(
        codec: OutputCodec,
        videoFormat: MediaVideoFormat,
        preservationCapability:
            SourceMediaPreservationCapability,
        preserveAudio: Bool
    ) -> Bool {
        codec.requiresQuickTimeMovieContainer
            || videoFormat.hasAlpha
            || videoFormat.requiresQuickTimeMovieOutput
            || preservationCapability
                .requiresQuickTimeMovieContainer(
                    preserveAudio: preserveAudio
                )
    }
}

enum ProductVideoOutputSettings {
    static let expectedFrameRate = 30
    static let minimumBitRate = 2_000_000
    private static let proResReferencePixelsPerSecond =
        1_920.0 * 1_080.0 * 29.97
    private static let proRes422HQBitsPerPixel =
        220_000_000.0 / proResReferencePixelsPerSecond
    private static let proRes4444BitsPerPixel =
        330_000_000.0 / proResReferencePixelsPerSecond

    static func estimatedBitRate(
        width: Int,
        height: Int,
        codec: OutputCodec
    ) -> Int {
        let bitsPerPixel: Double
        switch codec {
        case .hevc: bitsPerPixel = 0.10
        case .h264: bitsPerPixel = 0.15
        case .proRes422HQ:
            bitsPerPixel = proRes422HQBitsPerPixel
        case .proRes4444:
            bitsPerPixel = proRes4444BitsPerPixel
        }
        return max(
            minimumBitRate,
            Int(Double(width * height * expectedFrameRate) * bitsPerPixel)
        )
    }

    static func make(
        resolution: VideoResolution,
        codec: OutputCodec,
        videoFormat: MediaVideoFormat = .sdrBT709
    ) -> [String: Any] {
        var compressionProperties: [String: Any] = [
            kVTCompressionPropertyKey_FieldCount as String:
                NSNumber(value: 1)
        ]
        if codec == .hevc || codec == .h264 {
            let bitRate = estimatedBitRate(
                width: resolution.width,
                height: resolution.height,
                codec: codec
            )
            compressionProperties[AVVideoAverageBitRateKey] =
                NSNumber(value: bitRate)
        }
        if codec == .hevc,
           videoFormat.pixelStorage.chromaSampling == .yuv420,
           videoFormat.pixelStorage.bitDepth == 10 {
            compressionProperties[AVVideoProfileLevelKey] =
                kVTProfileLevel_HEVC_Main10_AutoLevel
        }
        if codec == .hevc,
           videoFormat.pixelStorage.chromaSampling == .yuv422 {
            compressionProperties[AVVideoProfileLevelKey] =
                kVTProfileLevel_HEVC_Main42210_AutoLevel
        }
        if videoFormat.isHDR {
            compressionProperties[
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String
            ] = kVTHDRMetadataInsertionMode_Auto
            if let mastering = videoFormat.masteringDisplayColorVolume {
                compressionProperties[
                    kVTCompressionPropertyKey_MasteringDisplayColorVolume
                        as String
                ] = mastering
            }
            if let contentLight = videoFormat.contentLightLevelInfo {
                compressionProperties[
                    kVTCompressionPropertyKey_ContentLightLevelInfo as String
                ] = contentLight
            }
        }
        if let alphaMode = videoFormat.alphaMode.compressionValue {
            compressionProperties[
                kVTCompressionPropertyKey_AlphaChannelMode as String
            ] = alphaMode
        }
        let codecKey: AVVideoCodecType =
            codec == .hevc && videoFormat.hasAlpha
            ? .hevcWithAlpha
            : codec.avCodecKey
        var settings: [String: Any] = [
            AVVideoCodecKey: codecKey,
            AVVideoWidthKey: NSNumber(value: resolution.width),
            AVVideoHeightKey: NSNumber(value: resolution.height),
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        if !codec.requiresQuickTimeMovieContainer {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: videoFormat.colorPrimaries.avValue,
                AVVideoTransferFunctionKey: videoFormat.transferFunction.avValue,
                AVVideoYCbCrMatrixKey: videoFormat.yCbCrMatrix
            ]
        }
        return settings
    }
}

public struct OutputProfile: Sendable {
    public let url: URL
    public let resolution: VideoResolution
    public let codec: OutputCodec
    public let preserveAudio: Bool
    public let preserveSubtitles: Bool
    public let preserveMetadata: Bool
    public let videoFormat: MediaVideoFormat?
    public let timedMetadataTemplate: [String: String]
    public let transactionIdentifier: String

    public init(
        url: URL,
        resolution: VideoResolution,
        codec: OutputCodec,
        preserveAudio: Bool,
        preserveSubtitles: Bool = true,
        preserveMetadata: Bool = true,
        videoFormat: MediaVideoFormat? = nil,
        timedMetadataTemplate: [String: String] = [:],
        transactionIdentifier: String = UUID().uuidString
    ) {
        self.url = url
        self.resolution = resolution
        self.codec = codec
        self.preserveAudio = preserveAudio
        self.preserveSubtitles = preserveSubtitles
        self.preserveMetadata = preserveMetadata
        self.videoFormat = videoFormat
        self.timedMetadataTemplate = timedMetadataTemplate
        self.transactionIdentifier = transactionIdentifier
    }
}

public struct FrameTiming: @unchecked Sendable, Equatable {
    public let frameIndex: Int
    public let presentationTime: CMTime
    public let duration: CMTime

    public init(frameIndex: Int, presentationTime: CMTime, duration: CMTime) {
        self.frameIndex = frameIndex
        self.presentationTime = presentationTime
        self.duration = duration
    }

    static func resolveDuration(
        sampleDuration: CMTime,
        presentationTime: CMTime,
        nextPresentationTime: CMTime?,
        timelineEnd: CMTime
    ) -> CMTime {
        if sampleDuration.isValid,
           sampleDuration.isNumeric,
           CMTimeCompare(sampleDuration, .zero) > 0 {
            return sampleDuration
        }
        if let nextPresentationTime {
            let inferred = CMTimeSubtract(nextPresentationTime, presentationTime)
            if inferred.isValid,
               inferred.isNumeric,
               CMTimeCompare(inferred, .zero) > 0 {
                return inferred
            }
        }
        let trailing = CMTimeSubtract(timelineEnd, presentationTime)
        guard trailing.isValid,
              trailing.isNumeric,
              CMTimeCompare(trailing, .zero) > 0 else {
            return .invalid
        }
        return trailing
    }
}

enum FrameTimingLedgerError: Error, Equatable, Sendable, CustomStringConvertible {
    case unexpectedFrameIndex(expected: Int, actual: Int)
    case invalidPresentationTime(frameIndex: Int)
    case nonMonotonicPresentationTime(previousFrameIndex: Int, frameIndex: Int)
    case invalidDuration(frameIndex: Int)
    case empty

    var description: String {
        switch self {
        case .unexpectedFrameIndex(let expected, let actual):
            return "Expected output frame index \(expected), received \(actual)."
        case .invalidPresentationTime(let frameIndex):
            return "Frame \(frameIndex) has an invalid presentation timestamp."
        case .nonMonotonicPresentationTime(let previousFrameIndex, let frameIndex):
            return "Frame \(frameIndex) does not follow frame \(previousFrameIndex) in presentation order."
        case .invalidDuration(let frameIndex):
            return "Frame \(frameIndex) has a nonpositive or invalid duration."
        case .empty:
            return "The output timing ledger contains no video frames."
        }
    }
}

struct FrameTimingLedgerSnapshot: @unchecked Sendable, Equatable {
    let frames: [FrameTiming]

    var frameCount: Int { frames.count }

    var sessionEndTime: CMTime? {
        guard let last = frames.last else { return nil }
        return CMTimeAdd(last.presentationTime, last.duration)
    }

    var duration: CMTime? {
        guard let first = frames.first,
              let sessionEndTime else { return nil }
        return CMTimeSubtract(sessionEndTime, first.presentationTime)
    }
}

struct FrameTimingLedger: @unchecked Sendable {
    private(set) var frames: [FrameTiming] = []

    var snapshot: FrameTimingLedgerSnapshot {
        FrameTimingLedgerSnapshot(frames: frames)
    }

    mutating func append(_ timing: FrameTiming) throws {
        try append(timing, afterValidation: {})
    }

    mutating func append(
        _ timing: FrameTiming,
        afterValidation operation: () throws -> Void
    ) throws {
        try validateAppend(timing)
        try operation()
        frames.append(timing)
    }

    private func validateAppend(_ timing: FrameTiming) throws {
        let expectedIndex = frames.count
        guard timing.frameIndex == expectedIndex else {
            throw FrameTimingLedgerError.unexpectedFrameIndex(
                expected: expectedIndex,
                actual: timing.frameIndex
            )
        }
        guard timing.presentationTime.isValid,
              timing.presentationTime.isNumeric else {
            throw FrameTimingLedgerError.invalidPresentationTime(frameIndex: timing.frameIndex)
        }
        guard timing.duration.isValid,
              timing.duration.isNumeric,
              CMTimeCompare(timing.duration, .zero) > 0 else {
            throw FrameTimingLedgerError.invalidDuration(frameIndex: timing.frameIndex)
        }
        if let previous = frames.last,
           CMTimeCompare(timing.presentationTime, previous.presentationTime) <= 0 {
            throw FrameTimingLedgerError.nonMonotonicPresentationTime(
                previousFrameIndex: previous.frameIndex,
                frameIndex: timing.frameIndex
            )
        }
    }
}

public struct FrameRecord: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let timing: FrameTiming

    public var presentationTime: CMTime { timing.presentationTime }
    public var duration: CMTime { timing.duration }
    public var frameIndex: Int { timing.frameIndex }

    public init(pixelBuffer: CVPixelBuffer, timing: FrameTiming) {
        self.pixelBuffer = pixelBuffer
        self.timing = timing
    }
}
