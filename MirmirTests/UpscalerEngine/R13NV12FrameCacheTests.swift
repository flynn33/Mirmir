import CoreVideo
import Darwin
import XCTest
@testable import Mirmir

final class R13NV12FrameCacheTests: XCTestCase {
    func testLZFSERoundTripIsLosslessForCompressibleNV12() throws {
        let frame = try R13NV12Frame(
            width: 64,
            height: 64,
            luma: Data(repeating: 16, count: 64 * 64),
            chroma: Data(repeating: 128, count: 64 * 32)
        )
        let codec = R13LZFSEFrameCacheCodec()

        let artifact = try codec.encode(frame)
        let decoded = try codec.decode(artifact.data)

        XCTAssertEqual(artifact.encoding, .lzfse)
        XCTAssertEqual(decoded, frame)
    }

    func testSmallIncompressibleFrameUsesExactRawFallback() throws {
        let frame = try R13NV12Frame(
            width: 4,
            height: 2,
            luma: Data([0, 37, 74, 111, 148, 185, 222, 3]),
            chroma: Data([40, 77, 114, 151])
        )
        let codec = R13LZFSEFrameCacheCodec()

        let artifact = try codec.encode(frame)

        XCTAssertEqual(artifact.encoding, .raw)
        XCTAssertEqual(try codec.decode(artifact.data), frame)
    }

    func testArtifactMutationCannotReplayAsAFrame() throws {
        let frame = try R13NV12Frame(
            width: 4,
            height: 2,
            luma: Data(repeating: 12, count: 8),
            chroma: Data(repeating: 120, count: 4)
        )
        let codec = R13LZFSEFrameCacheCodec()
        var artifact = try codec.encode(frame).data
        artifact[artifact.index(before: artifact.endIndex)] ^= 0x01

        XCTAssertThrowsError(try codec.decode(artifact))
    }

    func testCachedFrameReconstructsExactVideoRangeNV12ForReplay() throws {
        let frame = try R13NV12Frame(
            width: 6,
            height: 4,
            luma: Data((0..<24).map(UInt8.init)),
            chroma: Data((100..<112).map(UInt8.init))
        )

        let pixelBuffer = try frame.makeVideoRangePixelBuffer()
        let captured = try R13NV12Frame.captureTightActivePlanes(
            from: pixelBuffer
        )

        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(captured, frame)
        XCTAssertEqual(
            CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                nil
            ) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationTopFieldKey,
                nil
            ) as? String,
            kCVImageBufferChromaLocation_Left as String
        )
    }

    func testPixelBufferCaptureExcludesEveryPaddingByte() throws {
        let width = 6
        let height = 4
        let attributes: [CFString: Any] = [
            kCVPixelBufferBytesPerRowAlignmentKey: 64
        ]
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary,
                &optionalBuffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(optionalBuffer)
        try withLockedBaseAddress(of: pixelBuffer) {
            try fillPlane(
                pixelBuffer,
                plane: 0,
                activeBytesPerRow: width,
                activeRows: height,
                firstActiveValue: 10
            )
            try fillPlane(
                pixelBuffer,
                plane: 1,
                activeBytesPerRow: width,
                activeRows: height / 2,
                firstActiveValue: 50
            )
        }

        let frame = try R13NV12Frame.captureTightActivePlanes(
            from: pixelBuffer
        )
        XCTAssertEqual(frame.luma.count, width * height)
        XCTAssertEqual(frame.chroma.count, width * height / 2)
        XCTAssertEqual(
            frame.luma,
            Data(
                (0..<height).flatMap {
                    [UInt8](repeating: UInt8(10 + $0), count: width)
                }
            )
        )
        XCTAssertEqual(
            frame.chroma,
            Data(
                (0..<(height / 2)).flatMap {
                    [UInt8](repeating: UInt8(50 + $0), count: width)
                }
            )
        )
        XCTAssertFalse(frame.tightRawData.contains(0xEE))
    }

    func testCaptureCodecAndReplayPreserveEveryRegisteredLayout()
        throws {
        let codec = R13LZFSEFrameCacheCodec()
        for storage in MediaVideoPixelStorage.allCases {
            let source =
                try R13PixelLayoutTestFixtures.makeGradientBuffer(
                    pixelFormat: storage.pixelFormat,
                    width: 8,
                    height: 8
                )
            let captured =
                try R13NV12Frame.captureTightActivePlanes(
                    from: source
                )
            let decoded = try codec.decode(
                codec.encode(captured).data
            )
            let planes =
                [decoded.luma]
                + (decoded.chroma.isEmpty
                    ? []
                    : [decoded.chroma])
                + decoded.auxiliaryPlanes
            let replay = try R13TightPixelFrame(
                width: decoded.width,
                height: decoded.height,
                pixelFormat: decoded.pixelFormat,
                planes: planes
            ).makePixelBuffer()
            let recaptured =
                try R13NV12Frame.captureTightActivePlanes(
                    from: replay
                )

            XCTAssertEqual(decoded, captured, storage.rawValue)
            XCTAssertEqual(recaptured, captured, storage.rawValue)
        }
    }

    func testCaptureRejectsGenuinelyUnregisteredPixelBuffer()
        throws {
        var optionalBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                4,
                2,
                kCVPixelFormatType_OneComponent8,
                nil,
                &optionalBuffer
            ),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(optionalBuffer)

        XCTAssertThrowsError(
            try R13NV12Frame.captureTightActivePlanes(from: pixelBuffer)
        ) { error in
            XCTAssertEqual(
                error as? R13NV12FrameCacheError,
                .unsupportedPixelFormat(
                    kCVPixelFormatType_OneComponent8
                )
            )
        }
    }

    private func fillPlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        activeBytesPerRow: Int,
        activeRows: Int,
        firstActiveValue: UInt8
    ) throws {
        let baseAddress = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
        )
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            plane
        )
        memset(baseAddress, 0xEE, bytesPerRow * activeRows)
        for row in 0..<activeRows {
            memset(
                baseAddress.advanced(by: row * bytesPerRow),
                Int32(firstActiveValue + UInt8(row)),
                activeBytesPerRow
            )
        }
    }

    private func withLockedBaseAddress(
        of pixelBuffer: CVPixelBuffer,
        operation: () throws -> Void
    ) throws {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        XCTAssertEqual(lockStatus, kCVReturnSuccess)
        guard lockStatus == kCVReturnSuccess else {
            return
        }
        defer {
            XCTAssertEqual(
                CVPixelBufferUnlockBaseAddress(pixelBuffer, []),
                kCVReturnSuccess
            )
        }
        try operation()
    }
}
