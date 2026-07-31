import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class R13FormatPreservingDeinterlacerTests: XCTestCase {
    private let resolution = VideoResolution(width: 8, height: 8)

    func testNV12VerticalFilterProducesProgressiveFieldIdentity()
        throws {
        let source = try makePixelBuffer(
            format:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        try withLockedBuffer(source) {
            fillEightBitPlane(
                source,
                plane: 0,
                even: 16,
                odd: 235
            )
            fillEightBitPlane(
                source,
                plane: 1,
                even: 16,
                odd: 240
            )
        }
        let markerKey = "com.mirmir.test.deinterlace-marker" as CFString
        CVBufferSetAttachment(
            source,
            markerKey,
            "preserved" as CFString,
            .shouldPropagate
        )
        installInterlacedAttachments(on: source)

        let deinterlacer = try R13FormatPreservingDeinterlacer(
            resolution: resolution,
            pixelFormat:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let output = try deinterlacer.makeProgressiveFrame(
            from: source
        )

        XCTAssertEqual(
            R13FormatPreservingDeinterlacer.algorithmIdentity,
            "vertical_filter_1_2_1.edge_extension.v2"
        )
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(output),
            CVPixelBufferGetPixelFormatType(source)
        )
        try assertEightBitPlane(
            output,
            plane: 0,
            expectedRows: [71, 126, 126, 126, 126, 126, 126, 180]
        )
        try assertEightBitPlane(
            output,
            plane: 1,
            expectedRows: [72, 128, 128, 184]
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(
                output,
                kCVImageBufferFieldCountKey,
                nil
            ) as? NSNumber,
            NSNumber(value: 1)
        )
        XCTAssertNil(
            CVBufferCopyAttachment(
                output,
                kCVImageBufferFieldDetailKey,
                nil
            )
        )
        XCTAssertNil(
            CVBufferCopyAttachment(
                output,
                kCVImageBufferChromaLocationBottomFieldKey,
                nil
            )
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(output, markerKey, nil)
                as? String,
            "preserved"
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(
                source,
                kCVImageBufferFieldCountKey,
                nil
            ) as? NSNumber,
            NSNumber(value: 2)
        )
        try assertEightBitPlane(
            source,
            plane: 0,
            expectedRows: [16, 235, 16, 235, 16, 235, 16, 235]
        )
    }

    func testP010VerticalFilterKeepsCanonicalTenBitWords()
        throws {
        let format =
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let source = try makePixelBuffer(format: format)
        try withLockedBuffer(source) {
            fillSixteenBitPlane(
                source,
                plane: 0,
                even: UInt16(64 << 6),
                odd: UInt16(940 << 6)
            )
            fillSixteenBitPlane(
                source,
                plane: 1,
                even: UInt16(64 << 6),
                odd: UInt16(960 << 6)
            )
        }
        installInterlacedAttachments(on: source)

        let output = try R13FormatPreservingDeinterlacer(
            resolution: resolution,
            pixelFormat: format
        ).makeProgressiveFrame(from: source)

        try withLockedBuffer(output, readOnly: true) {
            XCTAssertEqual(
                sixteenBitValue(output, plane: 0, row: 0),
                UInt16(283 << 6)
            )
            for row in 1..<7 {
                let value = sixteenBitValue(
                    output,
                    plane: 0,
                    row: row
                )
                XCTAssertEqual(value, UInt16(502 << 6))
                XCTAssertEqual(value & 0x003f, 0)
            }
            XCTAssertEqual(
                sixteenBitValue(output, plane: 0, row: 7),
                UInt16(721 << 6)
            )
            XCTAssertEqual(
                sixteenBitValue(output, plane: 1, row: 0),
                UInt16(288 << 6)
            )
            for row in 1..<3 {
                let value = sixteenBitValue(
                    output,
                    plane: 1,
                    row: row
                )
                XCTAssertEqual(value, UInt16(512 << 6))
                XCTAssertEqual(value & 0x003f, 0)
            }
            XCTAssertEqual(
                sixteenBitValue(output, plane: 1, row: 3),
                UInt16(736 << 6)
            )
        }
    }

    func testBGRAFilterPreservesFractionalAlpha() throws {
        let source = try makePixelBuffer(
            format: kCVPixelFormatType_32BGRA
        )
        try withLockedBuffer(source) {
            guard let base = CVPixelBufferGetBaseAddress(source) else {
                return XCTFail("Missing packed base address.")
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(source)
            for row in 0..<resolution.height {
                let pixel: [UInt8] = row.isMultiple(of: 2)
                    ? [10, 20, 30, 0]
                    : [200, 180, 160, 255]
                for column in 0..<resolution.width {
                    for component in 0..<4 {
                        bytes[
                            row * stride + column * 4 + component
                        ] = pixel[component]
                    }
                }
            }
        }
        installInterlacedAttachments(on: source)

        let output = try R13FormatPreservingDeinterlacer(
            resolution: resolution,
            pixelFormat: kCVPixelFormatType_32BGRA
        ).makeProgressiveFrame(from: source)

        try withLockedBuffer(output, readOnly: true) {
            guard let base = CVPixelBufferGetBaseAddress(output) else {
                return XCTFail("Missing packed base address.")
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(output)
            XCTAssertEqual(bytes[stride + 0], 105)
            XCTAssertEqual(bytes[stride + 1], 100)
            XCTAssertEqual(bytes[stride + 2], 95)
            XCTAssertEqual(bytes[stride + 3], 128)
            XCTAssertGreaterThan(bytes[stride + 3], 0)
            XCTAssertLessThan(bytes[stride + 3], 255)
        }
    }

    func testHighPrecisionTriPlanarAlphaIsFilteredWithoutCollapse()
        throws {
        let format =
            kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar
        let source = try makePixelBuffer(format: format)
        try withLockedBuffer(source) {
            fillSixteenBitPlane(
                source,
                plane: 0,
                even: 4_096,
                odd: 60_160
            )
            fillSixteenBitPlane(
                source,
                plane: 1,
                even: 4_096,
                odd: 61_440
            )
            fillSixteenBitPlane(
                source,
                plane: 2,
                even: 0,
                odd: UInt16.max
            )
        }
        installInterlacedAttachments(on: source)

        let output = try R13FormatPreservingDeinterlacer(
            resolution: resolution,
            pixelFormat: format
        ).makeProgressiveFrame(from: source)

        try withLockedBuffer(output, readOnly: true) {
            XCTAssertEqual(
                sixteenBitValue(output, plane: 0, row: 1),
                32_128
            )
            XCTAssertEqual(
                sixteenBitValue(output, plane: 1, row: 1),
                32_768
            )
            XCTAssertEqual(
                sixteenBitValue(output, plane: 2, row: 1),
                32_768
            )
            XCTAssertGreaterThan(
                sixteenBitValue(output, plane: 2, row: 1),
                UInt16(UInt8.max)
            )
        }
    }

    func testEveryRegisteredFormatProducesProgressiveValidOutput()
        throws {
        let markerKey =
            "com.mirmir.test.registered-deinterlace" as CFString
        for pixelFormat in R13PixelLayoutRegistry
            .supportedPixelFormats.sorted() {
            let source = try R13PixelLayoutTestFixtures
                .makeGradientBuffer(
                    pixelFormat: pixelFormat,
                    width: resolution.width,
                    height: resolution.height
                )
            let sourcePixels = try R13TightPixelFrame(
                capturing: source
            )
            CVBufferSetAttachment(
                source,
                markerKey,
                "preserved" as CFString,
                .shouldPropagate
            )
            installInterlacedAttachments(on: source)

            XCTAssertTrue(
                R13FormatPreservingDeinterlacer.supports(
                    pixelFormat
                )
            )
            let output = try R13FormatPreservingDeinterlacer(
                resolution: resolution,
                pixelFormat: pixelFormat
            ).makeProgressiveFrame(from: source)

            try R13PixelLayoutRegistry.layout(
                for: pixelFormat
            ).validate(output)
            try R13PixelLayoutProcessor.validateStoredCodes(output)
            XCTAssertEqual(
                CVBufferCopyAttachment(
                    output,
                    kCVImageBufferFieldCountKey,
                    nil
                ) as? NSNumber,
                NSNumber(value: 1)
            )
            XCTAssertNil(
                CVBufferCopyAttachment(
                    output,
                    kCVImageBufferFieldDetailKey,
                    nil
                )
            )
            XCTAssertNil(
                CVBufferCopyAttachment(
                    output,
                    kCVImageBufferChromaLocationBottomFieldKey,
                    nil
                )
            )
            XCTAssertEqual(
                CVBufferCopyAttachment(output, markerKey, nil)
                    as? String,
                "preserved"
            )
            XCTAssertEqual(
                try R13TightPixelFrame(capturing: source),
                sourcePixels,
                "Source pixels changed for \(pixelFormat)."
            )
        }
    }

    func testPackedV210IsRejectedInsteadOfSilentlyConverted()
        throws {
        XCTAssertThrowsError(
            try R13FormatPreservingDeinterlacer(
                resolution: resolution,
                pixelFormat: kCVPixelFormatType_422YpCbCr10
            )
        ) { error in
            XCTAssertEqual(
                error as? R13VideoDeinterlacingError,
                .unsupportedPixelFormat(
                    kCVPixelFormatType_422YpCbCr10
                )
            )
        }
    }
}

private extension R13FormatPreservingDeinterlacerTests {
    func makePixelBuffer(format: OSType) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            resolution.width,
            resolution.height,
            format,
            [
                kCVPixelBufferIOSurfacePropertiesKey as String:
                    [String: Any]()
            ] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw PixelBufferBridgeError.poolCreationFailed(status)
        }
        return buffer
    }

    func installInterlacedAttachments(on buffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 2),
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldDetailKey,
            kCVImageBufferFieldDetailTemporalTopFirst,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
    }

    func fillEightBitPlane(
        _ buffer: CVPixelBuffer,
        plane: Int,
        even: UInt8,
        odd: UInt8
    ) {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let activeBytes = CVPixelBufferGetWidthOfPlane(buffer, plane)
            * (plane == 0 ? 1 : 2)
        for row in 0..<height {
            memset(
                base.advanced(by: row * stride),
                Int32(row.isMultiple(of: 2) ? even : odd),
                activeBytes
            )
        }
    }

    func fillSixteenBitPlane(
        _ buffer: CVPixelBuffer,
        plane: Int,
        even: UInt16,
        odd: UInt16
    ) {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            .assumingMemoryBound(to: UInt16.self)
        let stride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let componentCount =
            CVPixelBufferGetWidthOfPlane(buffer, plane)
            * (plane == 1 ? 2 : 1)
        for row in 0..<height {
            let value = row.isMultiple(of: 2) ? even : odd
            let rowBase = base.advanced(by: row * stride)
            for component in 0..<componentCount {
                rowBase[component] = value
            }
        }
    }

    func assertEightBitPlane(
        _ buffer: CVPixelBuffer,
        plane: Int,
        expectedRows: [UInt8]
    ) throws {
        try withLockedBuffer(buffer, readOnly: true) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                .assumingMemoryBound(to: UInt8.self)
            let stride =
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            XCTAssertEqual(
                CVPixelBufferGetHeightOfPlane(buffer, plane),
                expectedRows.count
            )
            for (row, expected) in expectedRows.enumerated() {
                XCTAssertEqual(
                    base[row * stride],
                    expected,
                    "plane \(plane), row \(row)"
                )
            }
        }
    }

    func sixteenBitValue(
        _ buffer: CVPixelBuffer,
        plane: Int,
        row: Int
    ) -> UInt16 {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            .assumingMemoryBound(to: UInt16.self)
        let stride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
        return base[row * stride]
    }

    func withLockedBuffer(
        _ buffer: CVPixelBuffer,
        readOnly: Bool = false,
        _ body: () throws -> Void
    ) throws {
        let flags: CVPixelBufferLockFlags = readOnly ? .readOnly : []
        let status = CVPixelBufferLockBaseAddress(buffer, flags)
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else {
            throw R13VideoDeinterlacingError.lockFailed(
                destination: !readOnly,
                status: status
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, flags)
        }
        try body()
    }
}
