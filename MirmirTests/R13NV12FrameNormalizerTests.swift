import CoreVideo
import XCTest
@testable import Mirmir

final class R13NV12FrameNormalizerTests: XCTestCase {
    private let resolution = VideoResolution(width: 16, height: 8)

    func testNormalizerCreatesOwnedCanonicalR03FrameAndCopiesActiveBytes() throws {
        let source = try makeBuffer(
            format: R03NV12Contract.pixelFormat,
            seed: 17
        )
        let normalized = try R13NV12FrameNormalizer().normalize(
            source,
            codedResolution: resolution,
            presentationResolution: resolution,
            pixelAspectRatio: nil
        )

        XCTAssertFalse(source === normalized)
        try R03NV12Contract.validate(
            pixelBuffer: normalized,
            resolution: resolution
        )
        XCTAssertEqual(
            try activeBytes(in: normalized),
            try activeBytes(in: source)
        )

        try fill(source, seed: 99)
        XCTAssertNotEqual(
            try activeBytes(in: normalized),
            try activeBytes(in: source)
        )
    }

    func testNormalizerRejectsNonVideoRangeInputBeforeCopy() throws {
        let source = try makeBuffer(
            format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            seed: 1
        )

        XCTAssertThrowsError(
            try R13NV12FrameNormalizer().normalize(
                source,
                codedResolution: resolution,
                presentationResolution: resolution,
                pixelAspectRatio: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? R03NV12ScalingError,
                .invalidPixelFormat(
                    expected: R03NV12Contract.pixelFormat,
                    actual: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                )
            )
        }
    }

    func testNormalizerRejectsDimensionMismatchBeforePoolAdmission() throws {
        let source = try makeBuffer(
            format: R03NV12Contract.pixelFormat,
            seed: 1
        )
        let expected = VideoResolution(width: 32, height: 16)

        XCTAssertThrowsError(
            try R13NV12FrameNormalizer().normalize(
                source,
                codedResolution: expected,
                presentationResolution: expected,
                pixelAspectRatio: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? R03NV12ScalingError,
                .invalidDimensions(
                    expectedWidth: expected.width,
                    expectedHeight: expected.height,
                    actualWidth: self.resolution.width,
                    actualHeight: self.resolution.height
                )
            )
        }
    }
}

extension R13NV12FrameNormalizerTests {
    func testNormalizerConformsAnamorphicGeometryToSquarePixels() throws {
        let codedResolution = VideoResolution(width: 12, height: 8)
        let presentationResolution = VideoResolution(width: 16, height: 8)
        let pixelAspectRatio = try XCTUnwrap(
            VideoPixelAspectRatio(
                horizontalSpacing: 4,
                verticalSpacing: 3
            )
        )
        let source = try makeBuffer(
            resolution: codedResolution,
            format: R03NV12Contract.pixelFormat,
            seed: 48
        )
        R03NV12Contract.installColorAttachments(on: source)
        installPixelAspectRatio(
            pixelAspectRatio,
            on: source
        )

        let normalized = try R13NV12FrameNormalizer().normalize(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            pixelAspectRatio: pixelAspectRatio
        )

        try R03NV12Contract.validate(
            pixelBuffer: normalized,
            resolution: presentationResolution
        )
        XCTAssertEqual(
            try readPixelAspectRatio(from: normalized),
            try XCTUnwrap(
                VideoPixelAspectRatio(
                    horizontalSpacing: 1,
                    verticalSpacing: 1
                )
            )
        )
        let edgeValues = try lumaEdgeValues(in: normalized)
        XCTAssertTrue(edgeValues.allSatisfy { $0 != 16 })
    }

    func testNormalizerCropsCleanApertureInsteadOfStretchingCodedPadding()
        throws {
        let codedResolution = VideoResolution(width: 16, height: 12)
        let presentationResolution = VideoResolution(width: 16, height: 8)
        let source = try makeBuffer(
            resolution: codedResolution,
            format: R03NV12Contract.pixelFormat,
            seed: 0
        )
        try fillCleanApertureFixture(source)
        R03NV12Contract.installColorAttachments(on: source)
        installCleanAperture(
            presentationResolution,
            on: source
        )

        let normalized = try R13NV12FrameNormalizer().normalize(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            pixelAspectRatio: nil
        )

        try R03NV12Contract.validate(
            pixelBuffer: normalized,
            resolution: presentationResolution
        )
        let outputLuma = try lumaValues(in: normalized)
        XCTAssertTrue(
            outputLuma.allSatisfy { $0 == 100 },
            "Unexpected luma values: \(Set(outputLuma).sorted())"
        )
    }

    func testNormalizerTransfersCompensatedNonSquareGeometry()
        throws {
        let codedResolution = VideoResolution(width: 16, height: 8)
        let cleanAperture = VideoResolution(width: 12, height: 8)
        let pixelAspectRatio = try XCTUnwrap(
            VideoPixelAspectRatio(
                horizontalSpacing: 4,
                verticalSpacing: 3
            )
        )
        let source = try makeBuffer(
            resolution: codedResolution,
            format: R03NV12Contract.pixelFormat,
            seed: 0
        )
        try fillCompensatedAspectFixture(source)
        R03NV12Contract.installColorAttachments(on: source)
        installCleanAperture(cleanAperture, on: source)
        installPixelAspectRatio(pixelAspectRatio, on: source)

        let normalized = try R13NV12FrameNormalizer().normalize(
            source,
            codedResolution: codedResolution,
            presentationResolution: codedResolution,
            pixelAspectRatio: pixelAspectRatio
        )

        try R03NV12Contract.validate(
            pixelBuffer: normalized,
            resolution: codedResolution
        )
        XCTAssertEqual(
            try readPixelAspectRatio(from: normalized),
            try XCTUnwrap(
                VideoPixelAspectRatio(
                    horizontalSpacing: 1,
                    verticalSpacing: 1
                )
            )
        )
        let outputLuma = try lumaValues(in: normalized)
        XCTAssertTrue(
            outputLuma.allSatisfy { $0 == 100 },
            "Unexpected luma values: \(Set(outputLuma).sorted())"
        )
    }
}

private extension R13NV12FrameNormalizerTests {
    private func makeBuffer(
        resolution bufferResolution: VideoResolution? = nil,
        format: OSType,
        seed: UInt8
    ) throws -> CVPixelBuffer {
        let bufferResolution = bufferResolution ?? resolution
        let pool = try PixelBufferBridge.makePool(
            width: bufferResolution.width,
            height: bufferResolution.height,
            format: format,
            capacity: 1
        )
        let buffer = try PixelBufferBridge.dequeue(from: pool)
        try fill(buffer, seed: seed)
        return buffer
    }

    private func fill(
        _ buffer: CVPixelBuffer,
        seed: UInt8
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let activeBytesPerRow = CVPixelBufferGetWidth(buffer)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            for row in 0..<rows {
                let bytes = base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)
                for column in 0..<activeBytesPerRow {
                    bytes[column] = seed
                        &+ UInt8(plane * 31)
                        &+ UInt8((row + column) % 251)
                }
            }
        }
    }

    private func fillCleanApertureFixture(
        _ buffer: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            for row in 0..<rows {
                let value: UInt8
                if plane == 0 {
                    // Keep the clean-aperture boundary aligned for 4:2:0.
                    value = row < 2 || row >= rows - 2 ? 16 : 100
                } else {
                    value = 128
                }
                memset(
                    base.advanced(by: row * stride),
                    Int32(value),
                    width
                )
            }
        }
    }

    private func fillCompensatedAspectFixture(
        _ buffer: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidth(buffer)
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            for row in 0..<rows {
                let bytes = base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)
                for column in 0..<width {
                    if plane == 0 {
                        bytes[column] =
                            column < 2 || column >= width - 2 ? 16 : 100
                    } else {
                        bytes[column] = 128
                    }
                }
            }
        }
    }

    private func installPixelAspectRatio(
        _ ratio: VideoPixelAspectRatio,
        on buffer: CVPixelBuffer
    ) {
        let attachment = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String:
                NSNumber(value: ratio.horizontalSpacing),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String:
                NSNumber(value: ratio.verticalSpacing)
        ] as CFDictionary
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferPixelAspectRatioKey,
            attachment,
            .shouldPropagate
        )
    }

    private func installCleanAperture(
        _ aperture: VideoResolution,
        on buffer: CVPixelBuffer
    ) {
        let attachment = [
            kCVImageBufferCleanApertureWidthKey as String:
                NSNumber(value: aperture.width),
            kCVImageBufferCleanApertureHeightKey as String:
                NSNumber(value: aperture.height),
            kCVImageBufferCleanApertureHorizontalOffsetKey as String:
                NSNumber(value: 0),
            kCVImageBufferCleanApertureVerticalOffsetKey as String:
                NSNumber(value: 0)
        ] as CFDictionary
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferCleanApertureKey,
            attachment,
            .shouldPropagate
        )
    }

    private func readPixelAspectRatio(
        from buffer: CVPixelBuffer
    ) throws -> VideoPixelAspectRatio {
        let attachment = try XCTUnwrap(
            CVBufferCopyAttachment(
                buffer,
                kCVImageBufferPixelAspectRatioKey,
                nil
            ) as? NSDictionary
        )
        let horizontal = try XCTUnwrap(
            attachment[
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey
            ] as? NSNumber
        )
        let vertical = try XCTUnwrap(
            attachment[
                kCVImageBufferPixelAspectRatioVerticalSpacingKey
            ] as? NSNumber
        )
        return try XCTUnwrap(
            VideoPixelAspectRatio(
                horizontalSpacing: horizontal.intValue,
                verticalSpacing: vertical.intValue
            )
        )
    }

    private func lumaEdgeValues(
        in buffer: CVPixelBuffer
    ) throws -> [UInt8] {
        let values = try lumaValues(in: buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        return [
            values[0],
            values[width - 1],
            values[(height - 1) * width],
            values[(height * width) - 1]
        ]
    }

    private func lumaValues(
        in buffer: CVPixelBuffer
    ) throws -> [UInt8] {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        )
        var result: [UInt8] = []
        result.reserveCapacity(width * height)
        for row in 0..<height {
            result.append(contentsOf: UnsafeBufferPointer(
                start: base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self),
                count: width
            ))
        }
        return result
    }

    private func activeBytes(
        in buffer: CVPixelBuffer
    ) throws -> [UInt8] {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        XCTAssertEqual(status, kCVReturnSuccess)
        guard status == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        var result: [UInt8] = []
        for plane in 0..<2 {
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let activeBytesPerRow = CVPixelBufferGetWidth(buffer)
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            for row in 0..<rows {
                let bytes = base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)
                result.append(contentsOf: UnsafeBufferPointer(
                    start: bytes,
                    count: activeBytesPerRow
                ))
            }
        }
        return result
    }
}
