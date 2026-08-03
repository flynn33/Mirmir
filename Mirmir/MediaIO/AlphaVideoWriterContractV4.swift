import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum AlphaVideoWriterCodecV4: String, CaseIterable, Hashable, Sendable {
    case proRes4444
    case proRes4444XQ
    case hevcWithAlpha

    var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .proRes4444:
            return .proRes4444
        case .proRes4444XQ:
            return .appleProRes4444XQ
        case .hevcWithAlpha:
            return .hevcWithAlpha
        }
    }

    /// `AVVideoCodecType.hevcWithAlpha` is an encoder-selection token. The
    /// resulting backwards-compatible elementary stream is tagged `hvc1`.
    var encodedMediaSubtype: CMVideoCodecType {
        switch self {
        case .proRes4444:
            return kCMVideoCodecType_AppleProRes4444
        case .proRes4444XQ:
            return kCMVideoCodecType_AppleProRes4444XQ
        case .hevcWithAlpha:
            return kCMVideoCodecType_HEVC
        }
    }
}

enum AlphaVideoWriterContractV4Error: Error, Equatable, Sendable {
    case nonPositiveDimensions(width: Int, height: Int)
    case dimensionsExceedEngineLimit(width: Int, height: Int, limit: Int)
    case unsupportedInputLayout(
        codec: AlphaVideoWriterCodecV4,
        layout: Alpha4444PackedLayoutV4
    )
    case writerRejectedOutputSettings(codec: AlphaVideoWriterCodecV4)
    case writerRejectedInput(codec: AlphaVideoWriterCodecV4)
    case inputPixelFormatMismatch(expected: OSType, actual: OSType)
    case inputDimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case inputAlphaAssociationMissing
    case inputAlphaAssociationMismatch(
        expected: AlphaAssociationV4,
        actual: String
    )
    case encodedMediaTypeMismatch(actual: CMMediaType)
    case encodedCodecMismatch(expected: CMVideoCodecType, actual: CMVideoCodecType)
    case encodedDimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int32,
        actualHeight: Int32
    )
    case encodedAlphaPresenceMissingOrFalse
    case encodedAlphaAssociationMissing
    case encodedAlphaAssociationMismatch(
        expected: AlphaAssociationV4,
        actual: String
    )
    case encodedProResAlphaDepthMismatch(actual: Int?)
}

struct AlphaVideoWriterEndpointV4 {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
}

/// Alpha-specific AVFoundation writer/decoder contract.
///
/// The contract deliberately admits only Core Video layouts publicly
/// recommended for each encoder: BGRA for HEVC-alpha and 8-bit ProRes input,
/// or 64-bit big-endian ARGB for high-bit-depth ProRes 4444. It never asks
/// AVFoundation to scale or color-match a high-bit-depth ProRes source.
struct AlphaVideoWriterContractV4: Hashable, Sendable {
    let codec: AlphaVideoWriterCodecV4
    let association: AlphaAssociationV4
    let width: Int
    let height: Int
    let inputLayout: Alpha4444PackedLayoutV4

    init(
        codec: AlphaVideoWriterCodecV4,
        association: AlphaAssociationV4,
        width: Int,
        height: Int,
        inputLayout: Alpha4444PackedLayoutV4
    ) throws {
        guard width > 0, height > 0 else {
            throw AlphaVideoWriterContractV4Error.nonPositiveDimensions(
                width: width,
                height: height
            )
        }
        let limit = SpatialAxisScalePlanV4.maximumSupportedExtent
        guard width <= limit, height <= limit else {
            throw AlphaVideoWriterContractV4Error.dimensionsExceedEngineLimit(
                width: width,
                height: height,
                limit: limit
            )
        }
        let supported: Set<Alpha4444PackedLayoutV4>
        switch codec {
        case .proRes4444, .proRes4444XQ:
            supported = [.bgra8, .argb16BigEndian]
        case .hevcWithAlpha:
            supported = [.bgra8]
        }
        guard supported.contains(inputLayout) else {
            throw AlphaVideoWriterContractV4Error.unsupportedInputLayout(
                codec: codec,
                layout: inputLayout
            )
        }
        self.codec = codec
        self.association = association
        self.width = width
        self.height = height
        self.inputLayout = inputLayout
    }

    var outputSettings: [String: Any] {
        [
            AVVideoCodecKey: codec.avVideoCodecType,
            AVVideoWidthKey: NSNumber(value: width),
            AVVideoHeightKey: NSNumber(value: height),
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
    }

    var sourcePixelBufferAttributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: inputLayout.pixelFormat),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
    }

    /// Decode at the encoded raster size. In particular, AVAssetReader does
    /// not support width/height scaling for 64ARGB ProRes output.
    var decoderOutputSettings: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String:
                NSNumber(value: inputLayout.pixelFormat)
        ]
    }

    var compressionProperties: [String: Any] {
        var properties: [String: Any] = [
            kVTCompressionPropertyKey_AlphaChannelMode as String:
                compressionAlphaMode
        ]
        switch codec {
        case .proRes4444, .proRes4444XQ:
            // This property is supported by ProRes and makes preservation an
            // explicit contract rather than relying on its default value.
            properties[
                kVTCompressionPropertyKey_PreserveAlphaChannel as String
            ] = kCFBooleanTrue
        case .hevcWithAlpha:
            // PreserveAlphaChannel is not supported by every HEVC-alpha
            // encoder. The muxed-alpha codec selector itself is the required
            // preservation contract; quality 1 requests its highest alpha
            // fidelity without falsely promising mathematical losslessness.
            properties[
                kVTCompressionPropertyKey_TargetQualityForAlpha as String
            ] = NSNumber(value: 1.0)
        }
        return properties
    }

    func preflight(writer: AVAssetWriter) throws {
        guard writer.canApply(
            outputSettings: outputSettings,
            forMediaType: .video
        ) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedOutputSettings(codec: codec)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        guard writer.canAdd(input) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedInput(codec: codec)
        }
    }

    func makeEndpoint(writer: AVAssetWriter) throws -> AlphaVideoWriterEndpointV4 {
        guard writer.canApply(
            outputSettings: outputSettings,
            forMediaType: .video
        ) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedOutputSettings(codec: codec)
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: outputSettings
        )
        guard writer.canAdd(input) else {
            throw AlphaVideoWriterContractV4Error
                .writerRejectedInput(codec: codec)
        }
        writer.add(input)
        return AlphaVideoWriterEndpointV4(
            input: input,
            adaptor: AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )
        )
    }

    func validateInputPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == inputLayout.pixelFormat else {
            throw AlphaVideoWriterContractV4Error.inputPixelFormatMismatch(
                expected: inputLayout.pixelFormat,
                actual: actualFormat
            )
        }
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard actualWidth == width, actualHeight == height else {
            throw AlphaVideoWriterContractV4Error.inputDimensionMismatch(
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        guard let actual = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferAlphaChannelModeKey,
            nil
        ) as? String else {
            throw AlphaVideoWriterContractV4Error.inputAlphaAssociationMissing
        }
        let expected = imageBufferAlphaMode as String
        guard actual == expected else {
            throw AlphaVideoWriterContractV4Error
                .inputAlphaAssociationMismatch(
                    expected: association,
                    actual: actual
                )
        }
    }

    func validateEncodedFormatDescription(
        _ description: CMFormatDescription
    ) throws {
        let mediaType = CMFormatDescriptionGetMediaType(description)
        guard mediaType == kCMMediaType_Video else {
            throw AlphaVideoWriterContractV4Error
                .encodedMediaTypeMismatch(actual: mediaType)
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        guard subtype == codec.encodedMediaSubtype else {
            throw AlphaVideoWriterContractV4Error.encodedCodecMismatch(
                expected: codec.encodedMediaSubtype,
                actual: subtype
            )
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width == Int32(width),
              dimensions.height == Int32(height) else {
            throw AlphaVideoWriterContractV4Error.encodedDimensionMismatch(
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: dimensions.width,
                actualHeight: dimensions.height
            )
        }

        let extensions = CMFormatDescriptionGetExtensions(description)
            as NSDictionary?
        let containsAlpha = extensions?[
            kCMFormatDescriptionExtension_ContainsAlphaChannel as String
        ]
        guard let alphaNumber = containsAlpha as? NSNumber,
              CFGetTypeID(alphaNumber) == CFBooleanGetTypeID(),
              alphaNumber.boolValue else {
            throw AlphaVideoWriterContractV4Error
                .encodedAlphaPresenceMissingOrFalse
        }
        guard let actualMode = extensions?[
            kCMFormatDescriptionExtension_AlphaChannelMode as String
        ] as? String else {
            throw AlphaVideoWriterContractV4Error
                .encodedAlphaAssociationMissing
        }
        let expectedMode = formatDescriptionAlphaMode as String
        guard actualMode == expectedMode else {
            throw AlphaVideoWriterContractV4Error
                .encodedAlphaAssociationMismatch(
                    expected: association,
                    actual: actualMode
                )
        }

        if codec == .proRes4444 || codec == .proRes4444XQ {
            let depth = (extensions?[
                kCMFormatDescriptionExtension_Depth as String
            ] as? NSNumber)?.intValue
            guard depth == 32 else {
                throw AlphaVideoWriterContractV4Error
                    .encodedProResAlphaDepthMismatch(actual: depth)
            }
        }
    }

    private var compressionAlphaMode: CFString {
        switch association {
        case .straight:
            return kVTAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kVTAlphaChannelMode_PremultipliedAlpha
        }
    }

    private var imageBufferAlphaMode: CFString {
        switch association {
        case .straight:
            return kCVImageBufferAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kCVImageBufferAlphaChannelMode_PremultipliedAlpha
        }
    }

    private var formatDescriptionAlphaMode: CFString {
        switch association {
        case .straight:
            return kCMFormatDescriptionAlphaChannelMode_StraightAlpha
        case .premultiplied:
            return kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha
        }
    }
}
