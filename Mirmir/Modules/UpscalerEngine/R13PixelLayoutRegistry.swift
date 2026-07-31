import CoreVideo
import Foundation

enum R13PixelLayoutRegistry {
    static let supportedPixelFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
        kCVPixelFormatType_4444AYpCbCr8,
        kCVPixelFormatType_4444AYpCbCr16,
        kCVPixelFormatType_32BGRA
    ]

    static func layout(for pixelFormat: OSType) throws -> R13PixelLayout {
        if let layout = biPlanar8Layout(for: pixelFormat) {
            return layout
        }
        if let layout = biPlanar10Layout(for: pixelFormat) {
            return layout
        }
        switch pixelFormat {
        case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
            return biPlanar16(
                pixelFormat,
                widthDivisor: 2
            )
        case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
            return biPlanar16(
                pixelFormat,
                widthDivisor: 1
            )
        case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
            return yuv44416Alpha(pixelFormat)
        case kCVPixelFormatType_4444AYpCbCr8:
            return aycbcr8(pixelFormat)
        case kCVPixelFormatType_4444AYpCbCr16:
            return aycbcr16(pixelFormat)
        case kCVPixelFormatType_32BGRA:
            return bgra(pixelFormat)
        default:
            throw R13PixelLayoutError.unsupportedPixelFormat(
                pixelFormat
            )
        }
    }

    private static func biPlanar8Layout(
        for pixelFormat: OSType
    ) -> R13PixelLayout? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return biPlanar8(
                pixelFormat, widthDivisor: 2, heightDivisor: 2,
                luma: videoLuma8, chroma: videoChroma8
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return biPlanar8(
                pixelFormat, widthDivisor: 2, heightDivisor: 2,
                luma: full8, chroma: fullChroma8
            )
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
            return biPlanar8(
                pixelFormat, widthDivisor: 2, heightDivisor: 1,
                luma: videoLuma8, chroma: videoChroma8
            )
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
            return biPlanar8(
                pixelFormat, widthDivisor: 2, heightDivisor: 1,
                luma: full8, chroma: fullChroma8
            )
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
            return biPlanar8(
                pixelFormat, widthDivisor: 1, heightDivisor: 1,
                luma: videoLuma8, chroma: videoChroma8
            )
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return biPlanar8(
                pixelFormat, widthDivisor: 1, heightDivisor: 1,
                luma: full8, chroma: fullChroma8
            )
        default:
            return nil
        }
    }

    private static func biPlanar10Layout(
        for pixelFormat: OSType
    ) -> R13PixelLayout? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return biPlanar10(
                pixelFormat, widthDivisor: 2, heightDivisor: 2,
                luma: videoLuma10, chroma: videoChroma10
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return biPlanar10(
                pixelFormat, widthDivisor: 2, heightDivisor: 2,
                luma: full10, chroma: full10
            )
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
            return biPlanar10(
                pixelFormat, widthDivisor: 2, heightDivisor: 1,
                luma: videoLuma10, chroma: videoChroma10
            )
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return biPlanar10(
                pixelFormat, widthDivisor: 2, heightDivisor: 1,
                luma: full10, chroma: full10
            )
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            return biPlanar10(
                pixelFormat, widthDivisor: 1, heightDivisor: 1,
                luma: videoLuma10, chroma: videoChroma10
            )
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return biPlanar10(
                pixelFormat, widthDivisor: 1, heightDivisor: 1,
                luma: full10, chroma: full10
            )
        default:
            return nil
        }
    }

    private static let full8 = bounds(0, 255)
    private static let fullChroma8 = bounds(1, 255)
    private static let full10 = bounds(0, 1_023)
    private static let full16 = bounds(0, 65_535)
    private static let videoLuma8 = bounds(16, 235)
    private static let videoChroma8 = bounds(16, 240)
    private static let videoLuma10 = bounds(64, 940)
    private static let videoChroma10 = bounds(64, 960)
    private static let videoLuma16 = bounds(4_096, 60_160)
    private static let videoChroma16 = bounds(4_096, 61_440)

    private static func bounds(
        _ minimum: UInt16,
        _ maximum: UInt16
    ) -> R13PixelCodeBounds {
        R13PixelCodeBounds(minimum: minimum, maximum: maximum)
    }

    private static func plane(
        _ role: R13PixelPlaneRole,
        widthDivisor: Int = 1,
        heightDivisor: Int = 1,
        components: Int,
        bytes: Int,
        shift: Int = 0,
        bounds: [R13PixelCodeBounds]
    ) -> R13PixelPlaneLayout {
        R13PixelPlaneLayout(
            role: role,
            widthDivisor: widthDivisor,
            heightDivisor: heightDivisor,
            componentsPerElement: components,
            bytesPerComponent: bytes,
            storedCodeShift: shift,
            componentBounds: bounds
        )
    }

    private static func planar(
        _ pixelFormat: OSType,
        widthMultiple: Int,
        heightMultiple: Int,
        planes: [R13PixelPlaneLayout]
    ) -> R13PixelLayout {
        R13PixelLayout(
            pixelFormat: pixelFormat,
            isPlanar: true,
            requiredWidthMultiple: widthMultiple,
            requiredHeightMultiple: heightMultiple,
            planes: planes
        )
    }

    private static func biPlanar8(
        _ pixelFormat: OSType,
        widthDivisor: Int,
        heightDivisor: Int,
        luma: R13PixelCodeBounds,
        chroma: R13PixelCodeBounds
    ) -> R13PixelLayout {
        planar(
            pixelFormat,
            widthMultiple: widthDivisor,
            heightMultiple: heightDivisor,
            planes: [
                plane(.luma, components: 1, bytes: 1, bounds: [luma]),
                plane(
                    .interleavedChroma,
                    widthDivisor: widthDivisor,
                    heightDivisor: heightDivisor,
                    components: 2,
                    bytes: 1,
                    bounds: [chroma, chroma]
                )
            ]
        )
    }

    private static func biPlanar10(
        _ pixelFormat: OSType,
        widthDivisor: Int,
        heightDivisor: Int,
        luma: R13PixelCodeBounds,
        chroma: R13PixelCodeBounds
    ) -> R13PixelLayout {
        planar(
            pixelFormat,
            widthMultiple: widthDivisor,
            heightMultiple: heightDivisor,
            planes: [
                plane(
                    .luma,
                    components: 1,
                    bytes: 2,
                    shift: 6,
                    bounds: [luma]
                ),
                plane(
                    .interleavedChroma,
                    widthDivisor: widthDivisor,
                    heightDivisor: heightDivisor,
                    components: 2,
                    bytes: 2,
                    shift: 6,
                    bounds: [chroma, chroma]
                )
            ]
        )
    }

    private static func bgra(_ pixelFormat: OSType) -> R13PixelLayout {
        R13PixelLayout(
            pixelFormat: pixelFormat,
            isPlanar: false,
            requiredWidthMultiple: 1,
            requiredHeightMultiple: 1,
            planes: [
                plane(
                    .packedBGRA,
                    components: 4,
                    bytes: 1,
                    bounds: [full8, full8, full8, full8]
                )
            ]
        )
    }

    private static func biPlanar16(
        _ pixelFormat: OSType,
        widthDivisor: Int
    ) -> R13PixelLayout {
        planar(
            pixelFormat,
            widthMultiple: widthDivisor,
            heightMultiple: 1,
            planes: [
                plane(
                    .luma,
                    components: 1,
                    bytes: 2,
                    bounds: [videoLuma16]
                ),
                plane(
                    .interleavedChroma,
                    widthDivisor: widthDivisor,
                    components: 2,
                    bytes: 2,
                    bounds: [videoChroma16, videoChroma16]
                )
            ]
        )
    }

    private static func yuv44416Alpha(
        _ pixelFormat: OSType
    ) -> R13PixelLayout {
        planar(
            pixelFormat,
            widthMultiple: 1,
            heightMultiple: 1,
            planes: [
                plane(.luma, components: 1, bytes: 2, bounds: [videoLuma16]),
                plane(
                    .interleavedChroma,
                    components: 2,
                    bytes: 2,
                    bounds: [videoChroma16, videoChroma16]
                ),
                plane(.alpha, components: 1, bytes: 2, bounds: [full16])
            ]
        )
    }

    private static func aycbcr16(
        _ pixelFormat: OSType
    ) -> R13PixelLayout {
        R13PixelLayout(
            pixelFormat: pixelFormat,
            isPlanar: false,
            requiredWidthMultiple: 1,
            requiredHeightMultiple: 1,
            planes: [
                plane(
                    .packedAYCbCr,
                    components: 4,
                    bytes: 2,
                    bounds: [
                        full16,
                        videoLuma16,
                        videoChroma16,
                        videoChroma16
                    ]
                )
            ]
        )
    }

    private static func aycbcr8(
        _ pixelFormat: OSType
    ) -> R13PixelLayout {
        R13PixelLayout(
            pixelFormat: pixelFormat,
            isPlanar: false,
            requiredWidthMultiple: 1,
            requiredHeightMultiple: 1,
            planes: [
                plane(
                    .packedAYCbCr,
                    components: 4,
                    bytes: 1,
                    bounds: [
                        full8,
                        videoLuma8,
                        videoChroma8,
                        videoChroma8
                    ]
                )
            ]
        )
    }
}
