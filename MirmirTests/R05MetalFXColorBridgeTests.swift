import CoreVideo
import XCTest
@testable import Mirmir

// swiftlint:disable:next type_body_length
final class R05MetalFXColorBridgeTests: XCTestCase {
    private struct PrimaryFixture {
        let color: [Float16]
        let luma: UInt8
        let chroma: [UInt8]
    }

    func testDecodeMapsLegalBlackAndWhiteToLinearEndpoints() throws {
        let source = try R05NV12VideoRangeFrame(
            width: 2,
            height: 2,
            yPlane: [16, 235, 16, 235],
            yRowBytes: 2,
            cbcrPlane: [128, 128],
            cbcrRowBytes: 2
        )

        let decoded = try R05MetalFXColorBridge.decode(source)

        for row in 0..<2 {
            XCTAssertEqual(rgb(decoded, column: 0, row: row), [0, 0, 0])
            XCTAssertEqual(rgb(decoded, column: 1, row: row), [1, 1, 1])
            XCTAssertEqual(alpha(decoded, column: 0, row: row), 1)
            XCTAssertEqual(alpha(decoded, column: 1, row: row), 1)
        }
    }

    func testBT709TransferFunctionsAreInverseAcrossLegalLumaCodes() {
        for code in UInt8(16)...UInt8(235) {
            let encoded = R05MetalFXColorBridge.normalizedLuma(code)
            let linear = R05MetalFXColorBridge.bt709EOTF(encoded)

            XCTAssertEqual(
                R05MetalFXColorBridge.bt709OETF(linear),
                encoded,
                accuracy: 1e-12,
                "BT.709 transfer mismatch at code \(code)"
            )
        }
    }

    func testEncodeUsesBT709VideoRangeCodesForPrimaryColors() throws {
        let fixtures = [
            PrimaryFixture(color: [1, 0, 0], luma: 63, chroma: [102, 240]),
            PrimaryFixture(color: [0, 1, 0], luma: 173, chroma: [42, 26]),
            PrimaryFixture(color: [0, 0, 1], luma: 32, chroma: [240, 118])
        ]

        for fixture in fixtures {
            let encoded = try R05MetalFXColorBridge.encode(
                try solidFrame(width: 2, height: 2, color: fixture.color)
            )

            XCTAssertEqual(encoded.yPlane, Array(repeating: fixture.luma, count: 4))
            XCTAssertEqual(encoded.cbcrPlane, fixture.chroma)
        }
    }

    func testDecodeInterpolatesLeftSitedChromaHorizontally() throws {
        let source = try R05NV12VideoRangeFrame(
            width: 4,
            height: 2,
            yPlane: Array(repeating: 126, count: 8),
            yRowBytes: 4,
            cbcrPlane: [106, 128, 150, 128],
            cbcrRowBytes: 4
        )

        let decoded = try R05MetalFXColorBridge.decode(source)
        let expectedCb = [-22.0 / 224.0, 0, 22.0 / 224.0, 22.0 / 224.0]

        for column in 0..<4 {
            XCTAssertEqual(
                recoveredCb(decoded, column: column, row: 0, yCode: 126),
                expectedCb[column],
                accuracy: 0.001
            )
        }
    }

    func testDecodeInterpolatesCenteredChromaVertically() throws {
        let source = try R05NV12VideoRangeFrame(
            width: 2,
            height: 4,
            yPlane: Array(repeating: 126, count: 8),
            yRowBytes: 2,
            cbcrPlane: [106, 128, 150, 128],
            cbcrRowBytes: 2
        )

        let decoded = try R05MetalFXColorBridge.decode(source)
        let expectedCb = [-22.0 / 224.0, -11.0 / 224.0, 11.0 / 224.0, 22.0 / 224.0]

        for row in 0..<4 {
            XCTAssertEqual(
                recoveredCb(decoded, column: 0, row: row, yCode: 126),
                expectedCb[row],
                accuracy: 0.001
            )
        }
    }

    func testEncodeSamplesEvenColumnsForLeftSitedChroma() throws {
        let blue: [Float16] = [0, 0, 1]
        let red: [Float16] = [1, 0, 0]
        let green: [Float16] = [0, 1, 0]
        let source = try frame(
            width: 4,
            height: 2,
            colors: [blue, red, green, red, blue, red, green, red]
        )

        let encoded = try R05MetalFXColorBridge.encode(source)

        XCTAssertEqual(encoded.cbcrPlane, [240, 118, 42, 26])
    }

    func testEncodeAveragesVerticallyForCenteredChroma() throws {
        let red: [Float16] = [1, 0, 0]
        let blue: [Float16] = [0, 0, 1]
        let source = try frame(
            width: 2,
            height: 2,
            colors: [red, red, blue, blue]
        )

        let encoded = try R05MetalFXColorBridge.encode(source)

        XCTAssertEqual(encoded.cbcrPlane, [171, 179])
    }

    func testFrameInitializersRejectOddDimensionsAndInvalidRows() {
        XCTAssertThrowsError(
            try R05NV12VideoRangeFrame(
                width: 3,
                height: 2,
                yPlane: Array(repeating: 16, count: 6),
                yRowBytes: 3,
                cbcrPlane: Array(repeating: 128, count: 3),
                cbcrRowBytes: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .invalidDimensions(width: 3, height: 2)
            )
        }
        XCTAssertThrowsError(
            try R05NV12VideoRangeFrame(
                width: 2,
                height: 2,
                yPlane: Array(repeating: 16, count: 4),
                yRowBytes: 1,
                cbcrPlane: [128, 128],
                cbcrRowBytes: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .invalidRowBytes(plane: 0, minimum: 2, actual: 1)
            )
        }
        XCTAssertThrowsError(
            try R05LinearRGBA16FloatFrame(
                width: 2,
                height: 2,
                components: Array(repeating: 0, count: 16),
                componentsPerRow: 7
            )
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .invalidLinearRowComponents(minimum: 8, actual: 7)
            )
        }
    }

    func testFrameInitializersRejectInsufficientStorage() {
        XCTAssertThrowsError(
            try R05NV12VideoRangeFrame(
                width: 2,
                height: 2,
                yPlane: Array(repeating: 16, count: 3),
                yRowBytes: 2,
                cbcrPlane: [128, 128],
                cbcrRowBytes: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .insufficientPlaneStorage(plane: 0, minimum: 4, actual: 3)
            )
        }
        XCTAssertThrowsError(
            try R05LinearRGBA16FloatFrame(
                width: 2,
                height: 2,
                components: Array(repeating: 0, count: 15),
                componentsPerRow: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .insufficientLinearStorage(minimum: 16, actual: 15)
            )
        }
    }

    func testEncodeRejectsNonFiniteOutOfRangeAndNonOpaqueComponents() throws {
        try assertEncodeError(
            components: [.nan, 0, 0, 1],
            expected: .nonFiniteLinearComponent(index: 0)
        )
        try assertEncodeError(
            components: [-0.5, 0, 0, 1],
            expected: .linearComponentOutOfRange(index: 0, value: -0.5)
        )
        try assertEncodeError(
            components: [0, 0, 0, 0.5],
            expected: .nonOpaqueAlpha(index: 3, value: 0.5)
        )
    }

    func testPixelBufferWrappersRequireExactContractAndCopyActiveRows() throws {
        let source = try makeNV12PixelBuffer(width: 4, height: 4)
        installRequiredAttachments(on: source)
        writeNV12(source, luma: 16, cb: 128, cr: 128)

        let decoded = try R05MetalFXColorBridge.decode(pixelBuffer: source)
        XCTAssertEqual(decoded.components, blackComponents(width: 4, height: 4))

        let destination = try makeNV12PixelBuffer(width: 4, height: 4)
        installRequiredAttachments(on: destination)
        writeNV12(destination, luma: 235, cb: 240, cr: 240)
        try R05MetalFXColorBridge.encode(decoded, into: destination)

        XCTAssertEqual(readPlane(destination, plane: 0), Array(repeating: 16, count: 16))
        XCTAssertEqual(readPlane(destination, plane: 1), Array(repeating: 128, count: 8))
    }

    func testPixelBufferWrapperRejectsMissingAttachment() throws {
        let source = try makeNV12PixelBuffer(width: 4, height: 4)
        installRequiredAttachments(on: source)
        CVBufferRemoveAttachment(source, kCVImageBufferTransferFunctionKey)

        XCTAssertThrowsError(try R05MetalFXColorBridge.decode(pixelBuffer: source)) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .colorAttachmentMismatch(
                    key: kCVImageBufferTransferFunctionKey as String,
                    expected: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                    actual: nil
                )
            )
        }
    }

    func testPixelBufferWrapperRejectsWrongFormat() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let source = try XCTUnwrap(pixelBuffer)

        XCTAssertThrowsError(try R05MetalFXColorBridge.decode(pixelBuffer: source)) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .invalidPixelFormat(
                    expected: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    actual: kCVPixelFormatType_32BGRA
                )
            )
        }
    }

    func testPixelBufferEncodeRejectsDimensionMismatch() throws {
        let destination = try makeNV12PixelBuffer(width: 4, height: 4)
        installRequiredAttachments(on: destination)
        let source = try solidFrame(width: 2, height: 2, color: [0, 0, 0])

        XCTAssertThrowsError(
            try R05MetalFXColorBridge.encode(source, into: destination)
        ) { error in
            XCTAssertEqual(
                error as? R05MetalFXColorBridgeError,
                .dimensionMismatch(
                    expectedWidth: 2,
                    expectedHeight: 2,
                    actualWidth: 4,
                    actualHeight: 4
                )
            )
        }
    }

    private func recoveredCb(
        _ frame: R05LinearRGBA16FloatFrame,
        column: Int,
        row: Int,
        yCode: UInt8
    ) -> Double {
        let blue = Double(
            frame.components[row * frame.componentsPerRow + column * 4 + 2]
        )
        let encodedBlue = R05MetalFXColorBridge.bt709OETF(blue)
        return (encodedBlue - R05MetalFXColorBridge.normalizedLuma(yCode)) / 1.8556
    }

    private func rgb(
        _ frame: R05LinearRGBA16FloatFrame,
        column: Int,
        row: Int
    ) -> [Float16] {
        let index = row * frame.componentsPerRow + column * 4
        return Array(frame.components[index..<(index + 3)])
    }

    private func alpha(
        _ frame: R05LinearRGBA16FloatFrame,
        column: Int,
        row: Int
    ) -> Float16 {
        frame.components[row * frame.componentsPerRow + column * 4 + 3]
    }

    private func solidFrame(
        width: Int,
        height: Int,
        color: [Float16]
    ) throws -> R05LinearRGBA16FloatFrame {
        try frame(
            width: width,
            height: height,
            colors: Array(repeating: color, count: width * height)
        )
    }

    private func frame(
        width: Int,
        height: Int,
        colors: [[Float16]]
    ) throws -> R05LinearRGBA16FloatFrame {
        XCTAssertEqual(colors.count, width * height)
        XCTAssertTrue(colors.allSatisfy { $0.count == 3 })
        return try R05LinearRGBA16FloatFrame(
            width: width,
            height: height,
            components: colors.flatMap { $0 + [1] }
        )
    }

    private func assertEncodeError(
        components: [Float16],
        expected: R05MetalFXColorBridgeError
    ) throws {
        let source = try R05LinearRGBA16FloatFrame(
            width: 2,
            height: 2,
            components: Array(repeating: components, count: 4).flatMap { $0 }
        )
        XCTAssertThrowsError(try R05MetalFXColorBridge.encode(source)) { error in
            XCTAssertEqual(error as? R05MetalFXColorBridgeError, expected)
        }
    }

    private func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("Unable to create NV12 pixel buffer")
        }
        return pixelBuffer
    }

    private func installRequiredAttachments(on pixelBuffer: CVPixelBuffer) {
        let attachments: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
        ]
        for (key, value) in attachments {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
    }

    private func writeNV12(
        _ pixelBuffer: CVPixelBuffer,
        luma: UInt8,
        cb: UInt8,
        cr: UInt8
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                yBase[row * yStride + column] = luma
            }
        }
        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                cbcrBase[row * cbcrStride + column * 2] = cb
                cbcrBase[row * cbcrStride + column * 2 + 1] = cr
            }
        }
    }

    private func readPlane(_ pixelBuffer: CVPixelBuffer, plane: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let activeBytes = plane == 0 ? width : width * 2
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)!
            .assumingMemoryBound(to: UInt8.self)
        return (0..<height).flatMap { row in
            (0..<activeBytes).map { offset in base[row * rowBytes + offset] }
        }
    }

    private func blackComponents(width: Int, height: Int) -> [Float16] {
        Array(repeating: [0, 0, 0, 1] as [Float16], count: width * height)
            .flatMap { $0 }
    }
}
