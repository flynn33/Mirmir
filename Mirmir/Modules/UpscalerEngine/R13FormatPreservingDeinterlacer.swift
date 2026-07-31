import CoreVideo
import Foundation

enum R13VideoDeinterlacingError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible {
    case unsupportedPixelFormat(OSType)
    case invalidDimensions(width: Int, height: Int)
    case sourceFormatMismatch(expected: OSType, actual: OSType)
    case destinationFormatMismatch(expected: OSType, actual: OSType)
    case destinationDimensionsMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case planeCountMismatch(expected: Int, actual: Int)
    case missingBaseAddress(plane: Int)
    case lockFailed(destination: Bool, status: CVReturn)

    var description: String {
        switch self {
        case .unsupportedPixelFormat(let format):
            return "Deinterlacing does not support pixel format \(format)."
        case .invalidDimensions(let width, let height):
            return "Deinterlacing requires positive dimensions; observed "
                + "\(width)x\(height)."
        case .sourceFormatMismatch(let expected, let actual):
            return "Deinterlacing source format \(actual) does not match "
                + "configured format \(expected)."
        case .destinationFormatMismatch(let expected, let actual):
            return "Deinterlacing destination format \(actual) does not "
                + "match configured format \(expected)."
        case .destinationDimensionsMismatch(
            let expectedWidth,
            let expectedHeight,
            let actualWidth,
            let actualHeight
        ):
            return "Deinterlacing destination dimensions "
                + "\(actualWidth)x\(actualHeight) do not match "
                + "\(expectedWidth)x\(expectedHeight)."
        case .planeCountMismatch(let expected, let actual):
            return "Deinterlacing destination has \(actual) planes; "
                + "expected \(expected)."
        case .missingBaseAddress(let plane):
            return "Deinterlacing could not access plane \(plane)."
        case .lockFailed(let destination, let status):
            return "Deinterlacing could not lock the "
                + (destination ? "destination" : "source")
                + " pixel buffer: \(status)."
        }
    }
}

/// Converts a decoded two-field frame into one progressive frame using the
/// documented VideoToolbox 1/4–1/2–1/4 vertical-filter behavior. The filter is
/// implemented here because requesting decoder deinterlacing is not sufficient
/// evidence that a decoder actually applied it.
final class R13FormatPreservingDeinterlacer: @unchecked Sendable {
    static let algorithmIdentity =
        "vertical_filter_1_2_1.edge_extension.v2"

    private enum ComponentStorage {
        case eightBit
        case tenBitMSB
        case sixteenBit
    }

    private struct PlaneLayout {
        let storage: ComponentStorage
        let componentCountPerPixel: Int
        let lowerCode: (Int) -> UInt16
        let upperCode: (Int) -> UInt16
    }

    let resolution: VideoResolution
    let pixelFormat: OSType

    private let outputPool: CVPixelBufferPool

    init(
        resolution: VideoResolution,
        pixelFormat: OSType
    ) throws {
        guard resolution.width > 0, resolution.height > 0 else {
            throw R13VideoDeinterlacingError.invalidDimensions(
                width: resolution.width,
                height: resolution.height
            )
        }
        guard Self.supports(pixelFormat) else {
            throw R13VideoDeinterlacingError.unsupportedPixelFormat(
                pixelFormat
            )
        }
        self.resolution = resolution
        self.pixelFormat = pixelFormat
        outputPool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: pixelFormat,
            capacity: 3
        )
    }

    static func supports(_ pixelFormat: OSType) -> Bool {
        R13PixelLayoutRegistry.supportedPixelFormats.contains(
            pixelFormat
        )
    }

    func makeProgressiveFrame(
        from source: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        try validateSource(source)
        let destination = try PixelBufferBridge.dequeue(from: outputPool)
        try deinterlace(source: source, destination: destination)
        return destination
    }

    func deinterlace(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws {
        try validateSource(source)
        try validateDestination(
            destination,
            expectedPlaneCount: CVPixelBufferGetPlaneCount(source)
        )
        try R13PixelLayoutProcessor.verticalFilter(
            source: source,
            destination: destination
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 1),
            .shouldPropagate
        )
        CVBufferRemoveAttachment(
            destination,
            kCVImageBufferFieldDetailKey
        )
        CVBufferRemoveAttachment(
            destination,
            kCVImageBufferChromaLocationBottomFieldKey
        )
    }

    private func validateSource(_ source: CVPixelBuffer) throws {
        let actual = CVPixelBufferGetPixelFormatType(source)
        guard actual == pixelFormat else {
            throw R13VideoDeinterlacingError.sourceFormatMismatch(
                expected: pixelFormat,
                actual: actual
            )
        }
        try validateDimensions(source)
    }

    private func validateDestination(
        _ destination: CVPixelBuffer,
        expectedPlaneCount: Int
    ) throws {
        let actualFormat =
            CVPixelBufferGetPixelFormatType(destination)
        guard actualFormat == pixelFormat else {
            throw R13VideoDeinterlacingError
                .destinationFormatMismatch(
                    expected: pixelFormat,
                    actual: actualFormat
                )
        }
        try validateDimensions(destination)
        let actualPlanes = CVPixelBufferGetPlaneCount(destination)
        guard actualPlanes == expectedPlaneCount else {
            throw R13VideoDeinterlacingError.planeCountMismatch(
                expected: expectedPlaneCount,
                actual: actualPlanes
            )
        }
    }

    private func validateDimensions(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard actualWidth == resolution.width,
              actualHeight == resolution.height else {
            throw R13VideoDeinterlacingError
                .destinationDimensionsMismatch(
                    expectedWidth: resolution.width,
                    expectedHeight: resolution.height,
                    actualWidth: actualWidth,
                    actualHeight: actualHeight
                )
        }
    }

    private func filterPacked(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws {
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase =
                CVPixelBufferGetBaseAddress(destination) else {
            throw R13VideoDeinterlacingError.missingBaseAddress(
                plane: 0
            )
        }
        let layout = try planeLayout(plane: 0)
        try filterRows(
            sourceBase: sourceBase,
            sourceStride: CVPixelBufferGetBytesPerRow(source),
            destinationBase: destinationBase,
            destinationStride: CVPixelBufferGetBytesPerRow(
                destination
            ),
            width: resolution.width,
            height: resolution.height,
            layout: layout
        )
    }

    private func filterPlane(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        plane: Int
    ) throws {
        guard let sourceBase =
                CVPixelBufferGetBaseAddressOfPlane(source, plane),
              let destinationBase =
                CVPixelBufferGetBaseAddressOfPlane(
                    destination,
                    plane
                ) else {
            throw R13VideoDeinterlacingError.missingBaseAddress(
                plane: plane
            )
        }
        try filterRows(
            sourceBase: sourceBase,
            sourceStride:
                CVPixelBufferGetBytesPerRowOfPlane(source, plane),
            destinationBase: destinationBase,
            destinationStride:
                CVPixelBufferGetBytesPerRowOfPlane(
                    destination,
                    plane
                ),
            width: CVPixelBufferGetWidthOfPlane(source, plane),
            height:
                CVPixelBufferGetHeightOfPlane(source, plane),
            layout: try planeLayout(plane: plane)
        )
    }

    private func filterRows(
        sourceBase: UnsafeMutableRawPointer,
        sourceStride: Int,
        destinationBase: UnsafeMutableRawPointer,
        destinationStride: Int,
        width: Int,
        height: Int,
        layout: PlaneLayout
    ) throws {
        let componentCount = width * layout.componentCountPerPixel
        guard height > 1 else {
            let componentBytes: Int
            switch layout.storage {
            case .eightBit:
                componentBytes = 1
            case .tenBitMSB, .sixteenBit:
                componentBytes = 2
            }
            memcpy(
                destinationBase,
                sourceBase,
                componentCount * componentBytes
            )
            return
        }

        switch layout.storage {
        case .eightBit:
            filterEightBitRows(
                sourceBase: sourceBase,
                sourceStride: sourceStride,
                destinationBase: destinationBase,
                destinationStride: destinationStride,
                componentCount: componentCount,
                height: height,
                layout: layout
            )
        case .tenBitMSB:
            filterTenBitRows(
                sourceBase: sourceBase,
                sourceStride: sourceStride,
                destinationBase: destinationBase,
                destinationStride: destinationStride,
                componentCount: componentCount,
                height: height,
                layout: layout
            )
        case .sixteenBit:
            filterSixteenBitRows(
                sourceBase: sourceBase,
                sourceStride: sourceStride,
                destinationBase: destinationBase,
                destinationStride: destinationStride,
                componentCount: componentCount,
                height: height,
                layout: layout
            )
        }
    }

    private func filterEightBitRows(
        sourceBase: UnsafeMutableRawPointer,
        sourceStride: Int,
        destinationBase: UnsafeMutableRawPointer,
        destinationStride: Int,
        componentCount: Int,
        height: Int,
        layout: PlaneLayout
    ) {
        let sourceBytes = sourceBase.assumingMemoryBound(to: UInt8.self)
        let destinationBytes =
            destinationBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let destinationRow = destinationBytes.advanced(
                by: row * destinationStride
            )
            let currentRow = sourceBytes.advanced(
                by: row * sourceStride
            )
            guard row > 0, row + 1 < height else {
                memcpy(
                    destinationRow,
                    currentRow,
                    componentCount
                )
                continue
            }
            let previousRow = currentRow.advanced(by: -sourceStride)
            let nextRow = currentRow.advanced(by: sourceStride)
            for component in 0..<componentCount {
                let filtered = (
                    Int(previousRow[component])
                    + 2 * Int(currentRow[component])
                    + Int(nextRow[component])
                    + 2
                ) / 4
                destinationRow[component] = UInt8(
                    min(
                        max(
                            filtered,
                            Int(layout.lowerCode(component))
                        ),
                        Int(layout.upperCode(component))
                    )
                )
            }
        }
    }

    private func filterTenBitRows(
        sourceBase: UnsafeMutableRawPointer,
        sourceStride: Int,
        destinationBase: UnsafeMutableRawPointer,
        destinationStride: Int,
        componentCount: Int,
        height: Int,
        layout: PlaneLayout
    ) {
        let sourceWords = sourceBase.assumingMemoryBound(to: UInt16.self)
        let destinationWords =
            destinationBase.assumingMemoryBound(to: UInt16.self)
        let sourceWordStride = sourceStride / 2
        let destinationWordStride = destinationStride / 2
        for row in 0..<height {
            let destinationRow = destinationWords.advanced(
                by: row * destinationWordStride
            )
            let currentRow = sourceWords.advanced(
                by: row * sourceWordStride
            )
            guard row > 0, row + 1 < height else {
                memcpy(
                    destinationRow,
                    currentRow,
                    componentCount * 2
                )
                continue
            }
            let previousRow = currentRow.advanced(
                by: -sourceWordStride
            )
            let nextRow = currentRow.advanced(
                by: sourceWordStride
            )
            for component in 0..<componentCount {
                let filteredCode = (
                    Int(previousRow[component] >> 6)
                    + 2 * Int(currentRow[component] >> 6)
                    + Int(nextRow[component] >> 6)
                    + 2
                ) / 4
                let bounded = min(
                    max(
                        filteredCode,
                        Int(layout.lowerCode(component))
                    ),
                    Int(layout.upperCode(component))
                )
                destinationRow[component] = UInt16(bounded << 6)
            }
        }
    }

    private func filterSixteenBitRows(
        sourceBase: UnsafeMutableRawPointer,
        sourceStride: Int,
        destinationBase: UnsafeMutableRawPointer,
        destinationStride: Int,
        componentCount: Int,
        height: Int,
        layout: PlaneLayout
    ) {
        let sourceWords = sourceBase.assumingMemoryBound(to: UInt16.self)
        let destinationWords =
            destinationBase.assumingMemoryBound(to: UInt16.self)
        let sourceWordStride = sourceStride / 2
        let destinationWordStride = destinationStride / 2
        for row in 0..<height {
            let destinationRow = destinationWords.advanced(
                by: row * destinationWordStride
            )
            let currentRow = sourceWords.advanced(
                by: row * sourceWordStride
            )
            guard row > 0, row + 1 < height else {
                memcpy(
                    destinationRow,
                    currentRow,
                    componentCount * 2
                )
                continue
            }
            let previousRow = currentRow.advanced(
                by: -sourceWordStride
            )
            let nextRow = currentRow.advanced(
                by: sourceWordStride
            )
            for component in 0..<componentCount {
                let filtered = (
                    UInt32(previousRow[component])
                    + 2 * UInt32(currentRow[component])
                    + UInt32(nextRow[component])
                    + 2
                ) / 4
                destinationRow[component] = UInt16(
                    min(
                        max(
                            filtered,
                            UInt32(layout.lowerCode(component))
                        ),
                        UInt32(layout.upperCode(component))
                    )
                )
            }
        }
    }

    private func planeLayout(plane: Int) throws -> PlaneLayout {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
            return eightBitBiPlanarLayout(
                plane: plane,
                fullRange: false
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return eightBitBiPlanarLayout(
                plane: plane,
                fullRange: true
            )
        case kCVPixelFormatType_32BGRA:
            return fullRangePackedLayout(
                storage: .eightBit,
                componentCountPerPixel: 4,
                upperCode: 255
            )
        case kCVPixelFormatType_4444AYpCbCr8:
            return PlaneLayout(
                storage: .eightBit,
                componentCountPerPixel: 4,
                lowerCode: { component in
                    component.isMultiple(of: 4) ? 0 : 16
                },
                upperCode: { component in
                    switch component % 4 {
                    case 0:
                        return 255
                    case 1:
                        return 235
                    default:
                        return 240
                    }
                }
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            return tenBitBiPlanarLayout(
                plane: plane,
                fullRange: false
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return tenBitBiPlanarLayout(
                plane: plane,
                fullRange: true
            )
        case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
            return sixteenBitBiPlanarLayout(plane: plane)
        case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
            switch plane {
            case 0:
                return constantLayout(
                    storage: .sixteenBit,
                    componentCountPerPixel: 1,
                    lowerCode: 4_096,
                    upperCode: 60_160
                )
            case 1:
                return constantLayout(
                    storage: .sixteenBit,
                    componentCountPerPixel: 2,
                    lowerCode: 4_096,
                    upperCode: 61_440
                )
            case 2:
                return constantLayout(
                    storage: .sixteenBit,
                    componentCountPerPixel: 1,
                    lowerCode: 0,
                    upperCode: UInt16.max
                )
            default:
                throw R13VideoDeinterlacingError
                    .missingBaseAddress(plane: plane)
            }
        case kCVPixelFormatType_4444AYpCbCr16:
            return PlaneLayout(
                storage: .sixteenBit,
                componentCountPerPixel: 4,
                lowerCode: { component in
                    component.isMultiple(of: 4) ? 0 : 4_096
                },
                upperCode: { component in
                    switch component % 4 {
                    case 0:
                        return UInt16.max
                    case 1:
                        return 60_160
                    default:
                        return 61_440
                    }
                }
            )
        default:
            throw R13VideoDeinterlacingError
                .unsupportedPixelFormat(pixelFormat)
        }
    }

    private func eightBitBiPlanarLayout(
        plane: Int,
        fullRange: Bool
    ) -> PlaneLayout {
        constantLayout(
            storage: .eightBit,
            componentCountPerPixel: plane == 0 ? 1 : 2,
            lowerCode: fullRange ? 0 : 16,
            upperCode: fullRange ? 255 : (plane == 0 ? 235 : 240)
        )
    }

    private func tenBitBiPlanarLayout(
        plane: Int,
        fullRange: Bool
    ) -> PlaneLayout {
        constantLayout(
            storage: .tenBitMSB,
            componentCountPerPixel: plane == 0 ? 1 : 2,
            lowerCode: fullRange ? 0 : 64,
            upperCode: fullRange ? 1_023 : (plane == 0 ? 940 : 960)
        )
    }

    private func sixteenBitBiPlanarLayout(
        plane: Int
    ) -> PlaneLayout {
        constantLayout(
            storage: .sixteenBit,
            componentCountPerPixel: plane == 0 ? 1 : 2,
            lowerCode: 4_096,
            upperCode: plane == 0 ? 60_160 : 61_440
        )
    }

    private func fullRangePackedLayout(
        storage: ComponentStorage,
        componentCountPerPixel: Int,
        upperCode: UInt16
    ) -> PlaneLayout {
        constantLayout(
            storage: storage,
            componentCountPerPixel: componentCountPerPixel,
            lowerCode: 0,
            upperCode: upperCode
        )
    }

    private func constantLayout(
        storage: ComponentStorage,
        componentCountPerPixel: Int,
        lowerCode: UInt16,
        upperCode: UInt16
    ) -> PlaneLayout {
        PlaneLayout(
            storage: storage,
            componentCountPerPixel: componentCountPerPixel,
            lowerCode: { _ in lowerCode },
            upperCode: { _ in upperCode }
        )
    }
}
