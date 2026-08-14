import CoreVideo
import XCTest
@testable import Mirmir

final class PixelLayoutV4Tests: XCTestCase {
    func testCanonicalFormatsBindStorageSignalDepthAndComponentOrder() throws {
        XCTAssertEqual(
            PixelLayoutV4.canonicalSupportedPixelFormats,
            [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            ]
        )

        let nv12 = PixelLayoutV4(storage: .nv12VideoRange8Bit)
        XCTAssertEqual(nv12.signalBitDepth, 8)
        XCTAssertEqual(nv12.storageBitDepth, 8)
        XCTAssertEqual(nv12.storedCodeShift, 0)
        XCTAssertEqual(nv12.planes[0].componentRoles, [.luma])
        XCTAssertEqual(nv12.planes[1].componentRoles, [.cb, .cr])
        XCTAssertEqual(nv12.planes[0].elementByteOrder, .scalar8)

        let p010 = try PixelLayoutV4(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(p010.storage, .p010VideoRange10Bit)
        XCTAssertEqual(p010.signalBitDepth, 10)
        XCTAssertEqual(p010.storageBitDepth, 16)
        XCTAssertEqual(p010.storedCodeShift, 6)
        XCTAssertEqual(p010.planes[1].componentRoles, [.cb, .cr])
        XCTAssertEqual(p010.planes[0].elementByteOrder, .littleEndianUInt16)
    }

    func testFourTwoZeroUsesCheckedCeilingGeometryForOddRasters() throws {
        let nv12 = PixelLayoutV4(storage: .nv12VideoRange8Bit)
        let p010 = PixelLayoutV4(storage: .p010VideoRange10Bit)

        XCTAssertEqual(try nv12.activePlaneByteCounts(width: 1, height: 1), [1, 2])
        XCTAssertEqual(try nv12.activePlaneByteCounts(width: 3, height: 3), [9, 8])
        XCTAssertEqual(try nv12.activePlaneByteCounts(width: 5, height: 4), [20, 12])
        XCTAssertEqual(try nv12.activePlaneByteCounts(width: 4, height: 5), [20, 12])

        XCTAssertEqual(try p010.activePlaneByteCounts(width: 1, height: 1), [2, 4])
        XCTAssertEqual(try p010.activePlaneByteCounts(width: 3, height: 3), [18, 16])
        XCTAssertEqual(try p010.activePlaneByteCounts(width: 5, height: 4), [40, 24])
        XCTAssertEqual(try p010.activePlaneByteCounts(width: 4, height: 5), [40, 24])
    }

    func testCoreVideoOddRasterStructuresMatchTheCanonicalLayout() throws {
        let formats = [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ]
        let dimensions = [(1, 1), (3, 3), (5, 4), (4, 5)]

        for format in formats {
            let layout = try PixelLayoutV4(pixelFormat: format)
            for (width, height) in dimensions {
                let buffer = try makePixelBuffer(
                    width: width,
                    height: height,
                    pixelFormat: format
                )
                XCTAssertNoThrow(try layout.validateStructure(of: buffer))
                XCTAssertEqual(CVPixelBufferGetWidthOfPlane(buffer, 0), width)
                XCTAssertEqual(CVPixelBufferGetHeightOfPlane(buffer, 0), height)
                XCTAssertEqual(
                    CVPixelBufferGetWidthOfPlane(buffer, 1),
                    (width / 2) + (width.isMultiple(of: 2) ? 0 : 1)
                )
                XCTAssertEqual(
                    CVPixelBufferGetHeightOfPlane(buffer, 1),
                    (height / 2) + (height.isMultiple(of: 2) ? 0 : 1)
                )
            }
        }
    }

    func testNV12VideoAndFullRangeBoundsFailClosed() throws {
        let video = PixelLayoutV4(storage: .nv12VideoRange8Bit)
        XCTAssertEqual(try video.validateStoredCode(16, plane: 0, component: 0), 16)
        XCTAssertEqual(try video.validateStoredCode(235, plane: 0, component: 0), 235)
        XCTAssertEqual(try video.validateStoredCode(16, plane: 1, component: 0), 16)
        XCTAssertEqual(try video.validateStoredCode(240, plane: 1, component: 1), 240)
        XCTAssertThrowsError(try video.validateStoredCode(15, plane: 0, component: 0))
        XCTAssertThrowsError(try video.validateStoredCode(241, plane: 1, component: 0))

        let full = PixelLayoutV4(storage: .nv12FullRange8Bit)
        XCTAssertEqual(try full.signalBounds(plane: 0, component: 0).minimum, 0)
        XCTAssertEqual(try full.signalBounds(plane: 1, component: 0).minimum, 1)
        XCTAssertEqual(try full.validateStoredCode(255, plane: 1, component: 1), 255)
        XCTAssertThrowsError(try full.validateStoredCode(0, plane: 1, component: 0))
    }

    func testP010VideoRangeEnforcesSignalBoundsAndSixZeroLowBits() throws {
        let layout = PixelLayoutV4(storage: .p010VideoRange10Bit)
        let minimum = UInt16(64 << 6)
        let maximumLuma = UInt16(940 << 6)
        let maximumChroma = UInt16(960 << 6)

        XCTAssertEqual(try layout.validateStoredCode(minimum, plane: 0, component: 0), 64)
        XCTAssertEqual(try layout.validateStoredCode(maximumLuma, plane: 0, component: 0), 940)
        XCTAssertEqual(try layout.validateStoredCode(maximumChroma, plane: 1, component: 1), 960)
        XCTAssertEqual(try layout.storedCode(forSignalCode: 940, plane: 0, component: 0), maximumLuma)
        let chromaStoredBounds = try layout.storedBounds(
            plane: 1,
            component: 0
        )
        XCTAssertEqual(chromaStoredBounds.minimum, minimum)
        XCTAssertEqual(chromaStoredBounds.maximum, maximumChroma)

        XCTAssertThrowsError(
            try layout.validateStoredCode(minimum | 1, plane: 0, component: 0)
        ) { error in
            XCTAssertEqual(
                error as? PixelLayoutV4Error,
                .invalidStoredCodeAlignment(
                    plane: 0,
                    component: 0,
                    value: minimum | 1,
                    requiredZeroLowBits: 6
                )
            )
        }
        XCTAssertThrowsError(
            try layout.storedCode(forSignalCode: 941, plane: 0, component: 0)
        )
        XCTAssertThrowsError(
            try layout.storedCode(forSignalCode: 961, plane: 1, component: 0)
        )
    }

    func testP010FullRangeIncludesEveryTenBitCodeAndRejectsPaddingBits() throws {
        let layout = PixelLayoutV4(storage: .p010FullRange10Bit)
        XCTAssertEqual(try layout.storedCode(forSignalCode: 0, plane: 0, component: 0), 0)
        XCTAssertEqual(
            try layout.storedCode(forSignalCode: 1_023, plane: 1, component: 1),
            UInt16(1_023 << 6)
        )
        XCTAssertEqual(
            try layout.validateStoredCode(UInt16(1_023 << 6), plane: 1, component: 0),
            1_023
        )
        XCTAssertThrowsError(
            try layout.validateStoredCode(UInt16((1_023 << 6) | 32), plane: 1, component: 0)
        )
    }

    func testInvalidIndicesFormatsGeometryAndArithmeticAreRejected() throws {
        let layout = PixelLayoutV4(storage: .p010VideoRange10Bit)
        XCTAssertThrowsError(try PixelLayoutV4(pixelFormat: OSType(0xDEAD_BEEF)))
        XCTAssertThrowsError(try layout.validateGeometry(width: 0, height: 1))
        XCTAssertThrowsError(try layout.plane(at: 2))
        XCTAssertThrowsError(try layout.signalBounds(plane: 1, component: 2))
        XCTAssertThrowsError(
            try layout.activePlaneByteCounts(width: Int.max, height: Int.max)
        )

        let fullRangeBuffer = try makePixelBuffer(
            width: 3,
            height: 3,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        let videoLayout = PixelLayoutV4(storage: .nv12VideoRange8Bit)
        XCTAssertThrowsError(try videoLayout.validateStructure(of: fullRangeBuffer)) {
            error in
            XCTAssertEqual(
                error as? PixelLayoutV4Error,
                .pixelFormatMismatch(
                    expected: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    actual: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                )
            )
        }
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
