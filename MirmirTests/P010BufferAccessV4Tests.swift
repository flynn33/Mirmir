import CoreVideo
import XCTest
@testable import Mirmir

final class P010BufferAccessV4Tests: XCTestCase {
    func testNativeCopyPreservesEveryTenBitCodeAndBothAttachmentClasses() throws {
        let source = try makePixelBuffer(width: 3, height: 3)
        let destination = try makePixelBuffer(width: 3, height: 3)
        try fill(source, base: 64)
        try fill(destination, base: 128)

        CVBufferSetAttachment(
            source,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            source,
            kCVImageBufferGammaLevelKey,
            NSNumber(value: 2.4),
            .shouldNotPropagate
        )

        try P010BufferAccessV4.copyActiveImage(
            from: source,
            to: destination,
            storage: .p010VideoRange10Bit
        )

        for y in 0..<3 {
            for x in 0..<3 {
                XCTAssertEqual(
                    try P010BufferAccessV4.signalCode(
                        in: destination,
                        storage: .p010VideoRange10Bit,
                        component: .luma,
                        x: x,
                        y: y
                    ),
                    UInt16(64 + y * 3 + x)
                )
            }
        }
        XCTAssertEqual(
            try P010BufferAccessV4.signalCode(
                in: destination,
                storage: .p010VideoRange10Bit,
                component: .cb,
                x: 1,
                y: 1
            ),
            515
        )
        XCTAssertEqual(
            try P010BufferAccessV4.signalCode(
                in: destination,
                storage: .p010VideoRange10Bit,
                component: .cr,
                x: 1,
                y: 1
            ),
            771
        )

        var primariesMode = CVAttachmentMode.shouldNotPropagate
        XCTAssertEqual(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferColorPrimariesKey,
                &primariesMode
            ) as? String,
            kCVImageBufferColorPrimaries_ITU_R_2020 as String
        )
        XCTAssertEqual(primariesMode, .shouldPropagate)
        var gammaMode = CVAttachmentMode.shouldPropagate
        XCTAssertEqual(
            CVBufferCopyAttachment(
                destination,
                kCVImageBufferGammaLevelKey,
                &gammaMode
            ) as? NSNumber,
            NSNumber(value: 2.4)
        )
        XCTAssertEqual(gammaMode, .shouldNotPropagate)
        XCTAssertNoThrow(
            try P010BufferAccessV4.validateCodeValues(
                in: destination,
                storage: .p010VideoRange10Bit
            )
        )
    }

    func testCopyTouchesActiveImageBytesOnly() throws {
        let source = try makePixelBuffer(width: 3, height: 3)
        let destination = try makePixelBuffer(width: 3, height: 3)
        try fill(source, base: 64)
        try fill(destination, base: 100)
        try fillPadding(source, byte: 0x5A)
        try fillPadding(destination, byte: 0xA5)

        try P010BufferAccessV4.copyActiveImage(
            from: source,
            to: destination,
            storage: .p010VideoRange10Bit,
            attachmentPolicy: .none
        )

        try assertPadding(destination, equals: 0xA5)
    }

    func testP010ValidationRejectsLowPaddingBitsAndAlignedOutOfRangeCodes() throws {
        let buffer = try makePixelBuffer(width: 2, height: 2)
        try fill(buffer, base: 64)
        try writeRawStoredCode(
            UInt16((64 << 6) | 1),
            to: buffer,
            plane: 0,
            x: 0,
            y: 0,
            component: 0
        )
        XCTAssertThrowsError(
            try P010BufferAccessV4.validateCodeValues(
                in: buffer,
                storage: .p010VideoRange10Bit
            )
        ) { error in
            XCTAssertEqual(
                error as? PixelLayoutV4Error,
                .invalidStoredCodeAlignment(
                    plane: 0,
                    component: 0,
                    value: UInt16((64 << 6) | 1),
                    requiredZeroLowBits: 6
                )
            )
        }

        try writeRawStoredCode(
            UInt16(941 << 6),
            to: buffer,
            plane: 0,
            x: 0,
            y: 0,
            component: 0
        )
        XCTAssertThrowsError(
            try P010BufferAccessV4.validateCodeValues(
                in: buffer,
                storage: .p010VideoRange10Bit
            )
        ) { error in
            XCTAssertEqual(
                error as? PixelLayoutV4Error,
                .signalCodeOutOfRange(
                    plane: 0,
                    component: 0,
                    value: 941,
                    minimum: 64,
                    maximum: 940
                )
            )
        }
    }

    func testFullRangeRetainsZeroAndMaximumWithoutQuantization() throws {
        let buffer = try makePixelBuffer(
            width: 1,
            height: 1,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
        try P010BufferAccessV4.writeSignalCode(
            0,
            to: buffer,
            storage: .p010FullRange10Bit,
            component: .luma,
            x: 0,
            y: 0
        )
        try P010BufferAccessV4.writeSignalCode(
            1_023,
            to: buffer,
            storage: .p010FullRange10Bit,
            component: .cb,
            x: 0,
            y: 0
        )
        try P010BufferAccessV4.writeSignalCode(
            777,
            to: buffer,
            storage: .p010FullRange10Bit,
            component: .cr,
            x: 0,
            y: 0
        )

        XCTAssertNoThrow(
            try P010BufferAccessV4.validateCodeValues(
                in: buffer,
                storage: .p010FullRange10Bit
            )
        )
        XCTAssertEqual(
            try P010BufferAccessV4.signalCode(
                in: buffer,
                storage: .p010FullRange10Bit,
                component: .luma,
                x: 0,
                y: 0
            ),
            0
        )
        XCTAssertEqual(
            try P010BufferAccessV4.signalCode(
                in: buffer,
                storage: .p010FullRange10Bit,
                component: .cb,
                x: 0,
                y: 0
            ),
            1_023
        )
        XCTAssertEqual(
            try P010BufferAccessV4.signalCode(
                in: buffer,
                storage: .p010FullRange10Bit,
                component: .cr,
                x: 0,
                y: 0
            ),
            777
        )
    }

    func testUnsupportedStorageCoordinatesAndCopyGeometryFailClosed() throws {
        let source = try makePixelBuffer(width: 2, height: 2)
        let destination = try makePixelBuffer(width: 3, height: 3)
        try fill(source, base: 64)
        try fill(destination, base: 64)

        XCTAssertThrowsError(
            try P010BufferAccessV4.validateCodeValues(
                in: source,
                storage: .nv12VideoRange8Bit
            )
        )
        XCTAssertThrowsError(
            try P010BufferAccessV4.signalCode(
                in: source,
                storage: .p010VideoRange10Bit,
                component: .cb,
                x: 1,
                y: 0
            )
        )
        XCTAssertThrowsError(
            try P010BufferAccessV4.copyActiveImage(
                from: source,
                to: destination,
                storage: .p010VideoRange10Bit
            )
        )
    }

    private func makePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
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

    private func fill(_ buffer: CVPixelBuffer, base: UInt16) throws {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        for y in 0..<height {
            for x in 0..<width {
                try P010BufferAccessV4.writeSignalCode(
                    base + UInt16(y * width + x),
                    to: buffer,
                    storage: .p010VideoRange10Bit,
                    component: .luma,
                    x: x,
                    y: y
                )
            }
        }
        let chromaWidth = (width / 2) + (width.isMultiple(of: 2) ? 0 : 1)
        let chromaHeight = (height / 2) + (height.isMultiple(of: 2) ? 0 : 1)
        for y in 0..<chromaHeight {
            for x in 0..<chromaWidth {
                let offset = UInt16(y * chromaWidth + x)
                try P010BufferAccessV4.writeSignalCode(
                    512 + offset,
                    to: buffer,
                    storage: .p010VideoRange10Bit,
                    component: .cb,
                    x: x,
                    y: y
                )
                try P010BufferAccessV4.writeSignalCode(
                    768 + offset,
                    to: buffer,
                    storage: .p010VideoRange10Bit,
                    component: .cr,
                    x: x,
                    y: y
                )
            }
        }
    }

    private func writeRawStoredCode(
        _ value: UInt16,
        to buffer: CVPixelBuffer,
        plane: Int,
        x: Int,
        y: Int,
        component: Int
    ) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let components = plane == 0 ? 1 : 2
        let offset = y * stride + (x * components + component) * 2
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func fillPadding(_ buffer: CVPixelBuffer, byte: UInt8) throws {
        let layout = PixelLayoutV4(storage: .p010VideoRange10Bit)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (planeIndex, plane) in layout.planes.enumerated() {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
            ).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let active = try plane.activeBytesPerRow(
                frameWidth: CVPixelBufferGetWidth(buffer)
            )
            let rows = try plane.height(
                forFrameHeight: CVPixelBufferGetHeight(buffer)
            )
            for row in 0..<rows where active < stride {
                for offset in active..<stride {
                    base[row * stride + offset] = byte
                }
            }
        }
    }

    private func assertPadding(
        _ buffer: CVPixelBuffer,
        equals expected: UInt8
    ) throws {
        let layout = PixelLayoutV4(storage: .p010VideoRange10Bit)
        XCTAssertEqual(
            CVPixelBufferLockBaseAddress(buffer, .readOnly),
            kCVReturnSuccess
        )
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        for (planeIndex, plane) in layout.planes.enumerated() {
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)
            ).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let active = try plane.activeBytesPerRow(
                frameWidth: CVPixelBufferGetWidth(buffer)
            )
            let rows = try plane.height(
                forFrameHeight: CVPixelBufferGetHeight(buffer)
            )
            for row in 0..<rows where active < stride {
                for offset in active..<stride {
                    XCTAssertEqual(base[row * stride + offset], expected)
                }
            }
        }
    }
}
