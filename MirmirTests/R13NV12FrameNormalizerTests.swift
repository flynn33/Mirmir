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
            resolution: resolution
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
                resolution: resolution
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
                resolution: expected
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

    private func makeBuffer(
        format: OSType,
        seed: UInt8
    ) throws -> CVPixelBuffer {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
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
            let activeBytesPerRow = resolution.width
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
            let base = try XCTUnwrap(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
            )
            for row in 0..<rows {
                let bytes = base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)
                result.append(contentsOf: UnsafeBufferPointer(
                    start: bytes,
                    count: resolution.width
                ))
            }
        }
        return result
    }
}
