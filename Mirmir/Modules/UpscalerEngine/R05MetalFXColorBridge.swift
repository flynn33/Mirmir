import CoreVideo
import Foundation

enum R05MetalFXColorBridgeError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case invalidRowBytes(plane: Int, minimum: Int, actual: Int)
    case insufficientPlaneStorage(plane: Int, minimum: Int, actual: Int)
    case invalidLinearRowComponents(minimum: Int, actual: Int)
    case insufficientLinearStorage(minimum: Int, actual: Int)
    case nonFiniteLinearComponent(index: Int)
    case linearComponentOutOfRange(index: Int, value: Float)
    case nonOpaqueAlpha(index: Int, value: Float)
    case invalidPixelFormat(expected: OSType, actual: OSType)
    case invalidPlaneCount(expected: Int, actual: Int)
    case invalidPlaneDimensions(
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case dimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case colorAttachmentMismatch(key: String, expected: String, actual: String?)
    case pixelBufferLockFailed(destination: Bool, status: CVReturn)
    case missingPlaneBaseAddress(plane: Int)
}

/// A byte-exact, row-aware representation of the frozen R05 420v input contract.
struct R05NV12VideoRangeFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let yPlane: [UInt8]
    let yRowBytes: Int
    let cbcrPlane: [UInt8]
    let cbcrRowBytes: Int

    init(
        width: Int,
        height: Int,
        yPlane: [UInt8],
        yRowBytes: Int,
        cbcrPlane: [UInt8],
        cbcrRowBytes: Int
    ) throws {
        try Self.validateDimensions(width: width, height: height)
        guard yRowBytes >= width else {
            throw R05MetalFXColorBridgeError.invalidRowBytes(
                plane: 0,
                minimum: width,
                actual: yRowBytes
            )
        }
        guard cbcrRowBytes >= width else {
            throw R05MetalFXColorBridgeError.invalidRowBytes(
                plane: 1,
                minimum: width,
                actual: cbcrRowBytes
            )
        }
        let requiredY = try Self.requiredStorage(rowBytes: yRowBytes, rows: height)
        let requiredCbCr = try Self.requiredStorage(
            rowBytes: cbcrRowBytes,
            rows: height / 2
        )
        guard yPlane.count >= requiredY else {
            throw R05MetalFXColorBridgeError.insufficientPlaneStorage(
                plane: 0,
                minimum: requiredY,
                actual: yPlane.count
            )
        }
        guard cbcrPlane.count >= requiredCbCr else {
            throw R05MetalFXColorBridgeError.insufficientPlaneStorage(
                plane: 1,
                minimum: requiredCbCr,
                actual: cbcrPlane.count
            )
        }
        self.width = width
        self.height = height
        self.yPlane = yPlane
        self.yRowBytes = yRowBytes
        self.cbcrPlane = cbcrPlane
        self.cbcrRowBytes = cbcrRowBytes
    }

    private static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              width <= Int.max / R05LinearRGBA16FloatFrame.componentCount else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: width,
                height: height
            )
        }
    }

    private static func requiredStorage(rowBytes: Int, rows: Int) throws -> Int {
        let result = rowBytes.multipliedReportingOverflow(by: rows)
        guard !result.overflow else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: rowBytes,
                height: rows
            )
        }
        return result.partialValue
    }
}

/// Linear-light RGBA values in the exact component type used by an RGBA16Float texture.
struct R05LinearRGBA16FloatFrame: Equatable, Sendable {
    static let componentCount = 4

    let width: Int
    let height: Int
    let components: [Float16]
    let componentsPerRow: Int

    init(
        width: Int,
        height: Int,
        components: [Float16],
        componentsPerRow: Int
    ) throws {
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              width <= Int.max / Self.componentCount else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: width,
                height: height
            )
        }
        let minimumRow = width * Self.componentCount
        guard componentsPerRow >= minimumRow else {
            throw R05MetalFXColorBridgeError.invalidLinearRowComponents(
                minimum: minimumRow,
                actual: componentsPerRow
            )
        }
        let required = componentsPerRow.multipliedReportingOverflow(by: height)
        guard !required.overflow else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: componentsPerRow,
                height: height
            )
        }
        guard components.count >= required.partialValue else {
            throw R05MetalFXColorBridgeError.insufficientLinearStorage(
                minimum: required.partialValue,
                actual: components.count
            )
        }
        self.width = width
        self.height = height
        self.components = components
        self.componentsPerRow = componentsPerRow
    }

    init(width: Int, height: Int, components: [Float16]) throws {
        guard width > 0, width <= Int.max / Self.componentCount else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: width,
                height: height
            )
        }
        try self.init(
            width: width,
            height: height,
            components: components,
            componentsPerRow: width * Self.componentCount
        )
    }
}

// Deterministic CPU reference only. Passing these checks is not a quality claim.
// swiftlint:disable:next type_body_length
enum R05MetalFXColorBridge {
    private struct EncodedRGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    private static let lumaCodeMinimum = 16.0
    private static let lumaCodeScale = 219.0
    private static let chromaCodeCenter = 128.0
    private static let chromaCodeScale = 224.0
    private static let kr = 0.2126
    private static let kb = 0.0722
    private static let kg = 1.0 - kr - kb

    static func decode(
        _ source: R05NV12VideoRangeFrame
    ) throws -> R05LinearRGBA16FloatFrame {
        let rowComponents = try checkedProduct(
            source.width,
            R05LinearRGBA16FloatFrame.componentCount,
            width: source.width,
            height: source.height
        )
        let componentCount = try checkedProduct(
            rowComponents,
            source.height,
            width: source.width,
            height: source.height
        )
        var output = [Float16](
            repeating: 0,
            count: componentCount
        )

        for row in 0..<source.height {
            for column in 0..<source.width {
                let yCode = source.yPlane[row * source.yRowBytes + column]
                let luma = normalizedLuma(yCode)
                let chroma = interpolatedChroma(
                    source,
                    column: column,
                    row: row
                )
                let encodedRed = clampUnit(luma + 2.0 * (1.0 - kr) * chroma.cr)
                let encodedBlue = clampUnit(luma + 2.0 * (1.0 - kb) * chroma.cb)
                let encodedGreen = clampUnit(
                    luma
                        - (2.0 * kb * (1.0 - kb) / kg) * chroma.cb
                        - (2.0 * kr * (1.0 - kr) / kg) * chroma.cr
                )
                let index = row * rowComponents + column * 4
                output[index] = Float16(bt709EOTF(encodedRed))
                output[index + 1] = Float16(bt709EOTF(encodedGreen))
                output[index + 2] = Float16(bt709EOTF(encodedBlue))
                output[index + 3] = 1
            }
        }

        return try R05LinearRGBA16FloatFrame(
            width: source.width,
            height: source.height,
            components: output,
            componentsPerRow: rowComponents
        )
    }

    static func encode(
        _ source: R05LinearRGBA16FloatFrame
    ) throws -> R05NV12VideoRangeFrame {
        try encode(source, clipsFiniteRGB: false)
    }

    /// MetalFX spatial filtering may produce finite half-float ringing just
    /// outside the normalized RGB interval. NV12 cannot represent that extended
    /// range, so this boundary conversion clips finite RGB through the existing
    /// BT.709 transfer clamp while retaining strict non-finite and alpha checks.
    static func encodeClippingFiniteRGB(
        _ source: R05LinearRGBA16FloatFrame
    ) throws -> R05NV12VideoRangeFrame {
        try encode(source, clipsFiniteRGB: true)
    }

    private static func encode(
        _ source: R05LinearRGBA16FloatFrame,
        clipsFiniteRGB: Bool
    ) throws -> R05NV12VideoRangeFrame {
        try validateLinearComponents(
            source,
            clipsFiniteRGB: clipsFiniteRGB
        )
        let pixelCount = try checkedProduct(
            source.width,
            source.height,
            width: source.width,
            height: source.height
        )
        var yPlane = [UInt8](repeating: 0, count: pixelCount)
        var cbcrPlane = [UInt8](
            repeating: 0,
            count: pixelCount / 2
        )

        for row in 0..<source.height {
            for column in 0..<source.width {
                let encoded = encodedRGB(source, column: column, row: row)
                let luma = kr * encoded.red + kg * encoded.green + kb * encoded.blue
                yPlane[row * source.width + column] = quantizedLuma(luma)
            }
        }

        // 4:2:0 left siting: each chroma sample is horizontally co-sited with
        // the even luma column and vertically centered between its two rows.
        for chromaY in 0..<(source.height / 2) {
            let topY = chromaY * 2
            for chromaX in 0..<(source.width / 2) {
                let lumaX = chromaX * 2
                let top = encodedChroma(source, column: lumaX, row: topY)
                let bottom = encodedChroma(source, column: lumaX, row: topY + 1)
                let index = chromaY * source.width + chromaX * 2
                cbcrPlane[index] = quantizedChroma((top.cb + bottom.cb) / 2.0)
                cbcrPlane[index + 1] = quantizedChroma((top.cr + bottom.cr) / 2.0)
            }
        }

        return try R05NV12VideoRangeFrame(
            width: source.width,
            height: source.height,
            yPlane: yPlane,
            yRowBytes: source.width,
            cbcrPlane: cbcrPlane,
            cbcrRowBytes: source.width
        )
    }

    static func decode(pixelBuffer: CVPixelBuffer) throws -> R05LinearRGBA16FloatFrame {
        try validate(pixelBuffer: pixelBuffer)
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw R05MetalFXColorBridgeError.pixelBufferLockFailed(
                destination: false,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let yPlane = try copyActivePlane(
            pixelBuffer,
            plane: 0,
            activeRowBytes: width,
            rows: height
        )
        let cbcrPlane = try copyActivePlane(
            pixelBuffer,
            plane: 1,
            activeRowBytes: width,
            rows: height / 2
        )
        return try decode(
            R05NV12VideoRangeFrame(
                width: width,
                height: height,
                yPlane: yPlane,
                yRowBytes: width,
                cbcrPlane: cbcrPlane,
                cbcrRowBytes: width
            )
        )
    }

    static func encode(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer
    ) throws {
        try encode(
            source,
            into: pixelBuffer,
            clipsFiniteRGB: false
        )
    }

    static func encodeClippingFiniteRGB(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer
    ) throws {
        try encode(
            source,
            into: pixelBuffer,
            clipsFiniteRGB: true
        )
    }

    private static func encode(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer,
        clipsFiniteRGB: Bool
    ) throws {
        try validate(pixelBuffer: pixelBuffer)
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard source.width == actualWidth, source.height == actualHeight else {
            throw R05MetalFXColorBridgeError.dimensionMismatch(
                expectedWidth: source.width,
                expectedHeight: source.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        let encoded = try encode(
            source,
            clipsFiniteRGB: clipsFiniteRGB
        )
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R05MetalFXColorBridgeError.pixelBufferLockFailed(
                destination: true,
                status: status
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        try writeActivePlane(
            encoded.yPlane,
            to: pixelBuffer,
            plane: 0,
            activeRowBytes: source.width,
            rows: source.height
        )
        try writeActivePlane(
            encoded.cbcrPlane,
            to: pixelBuffer,
            plane: 1,
            activeRowBytes: source.width,
            rows: source.height / 2
        )
    }

    static func installRequiredAttachments(on pixelBuffer: CVPixelBuffer) {
        for (key, value) in expectedAttachments {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
    }

    static func bt709OETF(_ linear: Double) -> Double {
        let value = clampUnit(linear)
        if value < 0.018 {
            return 4.5 * value
        }
        return 1.099 * Foundation.pow(value, 0.45) - 0.099
    }

    static func bt709EOTF(_ encoded: Double) -> Double {
        let value = clampUnit(encoded)
        if value < 0.081 {
            return value / 4.5
        }
        return Foundation.pow((value + 0.099) / 1.099, 1.0 / 0.45)
    }

    static func normalizedLuma(_ code: UInt8) -> Double {
        clampUnit((Double(code) - lumaCodeMinimum) / lumaCodeScale)
    }

    static func normalizedChroma(_ code: UInt8) -> Double {
        min(0.5, max(-0.5, (Double(code) - chromaCodeCenter) / chromaCodeScale))
    }

    private static func validateLinearComponents(
        _ source: R05LinearRGBA16FloatFrame,
        clipsFiniteRGB: Bool
    ) throws {
        for row in 0..<source.height {
            for column in 0..<source.width {
                let base = row * source.componentsPerRow + column * 4
                for offset in 0..<3 {
                    let index = base + offset
                    let value = Float(source.components[index])
                    guard value.isFinite else {
                        throw R05MetalFXColorBridgeError.nonFiniteLinearComponent(
                            index: index
                        )
                    }
                    guard clipsFiniteRGB || (0...1).contains(value) else {
                        throw R05MetalFXColorBridgeError.linearComponentOutOfRange(
                            index: index,
                            value: value
                        )
                    }
                }
                let alphaIndex = base + 3
                let alpha = Float(source.components[alphaIndex])
                guard alpha.isFinite else {
                    throw R05MetalFXColorBridgeError.nonFiniteLinearComponent(
                        index: alphaIndex
                    )
                }
                guard alpha == 1 else {
                    throw R05MetalFXColorBridgeError.nonOpaqueAlpha(
                        index: alphaIndex,
                        value: alpha
                    )
                }
            }
        }
    }

    private static func encodedRGB(
        _ source: R05LinearRGBA16FloatFrame,
        column: Int,
        row: Int
    ) -> EncodedRGB {
        let index = row * source.componentsPerRow + column * 4
        return EncodedRGB(
            red: bt709OETF(Double(source.components[index])),
            green: bt709OETF(Double(source.components[index + 1])),
            blue: bt709OETF(Double(source.components[index + 2]))
        )
    }

    private static func encodedChroma(
        _ source: R05LinearRGBA16FloatFrame,
        column: Int,
        row: Int
    ) -> (cb: Double, cr: Double) {
        let encoded = encodedRGB(source, column: column, row: row)
        let luma = kr * encoded.red + kg * encoded.green + kb * encoded.blue
        return (
            (encoded.blue - luma) / (2.0 * (1.0 - kb)),
            (encoded.red - luma) / (2.0 * (1.0 - kr))
        )
    }

    private static func interpolatedChroma(
        _ source: R05NV12VideoRangeFrame,
        column: Int,
        row: Int
    ) -> (cb: Double, cr: Double) {
        let chromaWidth = source.width / 2
        let chromaHeight = source.height / 2
        let sampleX = Double(column) / 2.0
        let sampleY = (Double(row) - 0.5) / 2.0
        let x0 = min(chromaWidth - 1, max(0, Int(floor(sampleX))))
        let x1 = min(chromaWidth - 1, x0 + 1)
        let y0 = min(chromaHeight - 1, max(0, Int(floor(sampleY))))
        let y1 = min(chromaHeight - 1, y0 + 1)
        let xWeight = sampleX <= 0 ? 0 : min(1, sampleX - floor(sampleX))
        let yWeight = sampleY <= 0 ? 0 : min(1, sampleY - floor(sampleY))
        let top = mix(
            chroma(source, column: x0, row: y0),
            chroma(source, column: x1, row: y0),
            weight: xWeight
        )
        let bottom = mix(
            chroma(source, column: x0, row: y1),
            chroma(source, column: x1, row: y1),
            weight: xWeight
        )
        return mix(top, bottom, weight: yWeight)
    }

    private static func chroma(
        _ source: R05NV12VideoRangeFrame,
        column: Int,
        row: Int
    ) -> (cb: Double, cr: Double) {
        let index = row * source.cbcrRowBytes + column * 2
        return (
            normalizedChroma(source.cbcrPlane[index]),
            normalizedChroma(source.cbcrPlane[index + 1])
        )
    }

    private static func mix(
        _ left: (cb: Double, cr: Double),
        _ right: (cb: Double, cr: Double),
        weight: Double
    ) -> (cb: Double, cr: Double) {
        (
            left.cb + (right.cb - left.cb) * weight,
            left.cr + (right.cr - left.cr) * weight
        )
    }

    private static func quantizedLuma(_ value: Double) -> UInt8 {
        UInt8((lumaCodeMinimum + lumaCodeScale * clampUnit(value)).rounded())
    }

    private static func quantizedChroma(_ value: Double) -> UInt8 {
        let clamped = min(0.5, max(-0.5, value))
        return UInt8((chromaCodeCenter + chromaCodeScale * clamped).rounded())
    }

    private static func clampUnit(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func checkedProduct(
        _ left: Int,
        _ right: Int,
        width: Int,
        height: Int
    ) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: width,
                height: height
            )
        }
        return result.partialValue
    }

    static func validate(pixelBuffer: CVPixelBuffer) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == pixelFormat else {
            throw R05MetalFXColorBridgeError.invalidPixelFormat(
                expected: pixelFormat,
                actual: format
            )
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2) else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: width,
                height: height
            )
        }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount == 2 else {
            throw R05MetalFXColorBridgeError.invalidPlaneCount(
                expected: 2,
                actual: planeCount
            )
        }
        try validatePlane(pixelBuffer, plane: 0, width: width, height: height)
        try validatePlane(
            pixelBuffer,
            plane: 1,
            width: width / 2,
            height: height / 2
        )
        for (key, expected) in expectedAttachments {
            let actual = CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
            guard actual == expected as String else {
                throw R05MetalFXColorBridgeError.colorAttachmentMismatch(
                    key: key as String,
                    expected: expected as String,
                    actual: actual
                )
            }
        }
    }

    private static func validatePlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        width: Int,
        height: Int
    ) throws {
        let actualWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let actualHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        guard actualWidth == width, actualHeight == height else {
            throw R05MetalFXColorBridgeError.invalidPlaneDimensions(
                plane: plane,
                expectedWidth: width,
                expectedHeight: height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        let activeBytes = plane == 0 ? width : width * 2
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        guard rowBytes >= activeBytes else {
            throw R05MetalFXColorBridgeError.invalidRowBytes(
                plane: plane,
                minimum: activeBytes,
                actual: rowBytes
            )
        }
    }

    private static func copyActivePlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        activeRowBytes: Int,
        rows: Int
    ) throws -> [UInt8] {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            throw R05MetalFXColorBridgeError.missingPlaneBaseAddress(plane: plane)
        }
        let sourceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let source = base.assumingMemoryBound(to: UInt8.self)
        let outputCount = try checkedProduct(
            activeRowBytes,
            rows,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        var output = [UInt8](repeating: 0, count: outputCount)
        output.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<rows {
                destinationBase
                    .advanced(by: row * activeRowBytes)
                    .copyMemory(
                        from: source.advanced(by: row * sourceRowBytes),
                        byteCount: activeRowBytes
                    )
            }
        }
        return output
    }

    private static func writeActivePlane(
        _ source: [UInt8],
        to pixelBuffer: CVPixelBuffer,
        plane: Int,
        activeRowBytes: Int,
        rows: Int
    ) throws {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            throw R05MetalFXColorBridgeError.missingPlaneBaseAddress(plane: plane)
        }
        let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let destination = base.assumingMemoryBound(to: UInt8.self)
        source.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress else { return }
            for row in 0..<rows {
                destination
                    .advanced(by: row * destinationRowBytes)
                    .update(
                        from: sourceBase
                            .advanced(by: row * activeRowBytes)
                            .assumingMemoryBound(to: UInt8.self),
                        count: activeRowBytes
                    )
            }
        }
    }

    private static var expectedAttachments: [(CFString, CFString)] {
        [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
        ]
    }
}
// swiftlint:disable:this file_length
