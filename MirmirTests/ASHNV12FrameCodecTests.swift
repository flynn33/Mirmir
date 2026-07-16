import CoreVideo
import XCTest
@testable import Mirmir

final class ASHNV12FrameCodecTests: XCTestCase {
    private struct ExtractionFixture {
        let format: OSType
        let range: ASHVideoCodeRange8Bit
        let luma: [UInt8]
        let cb: [UInt8]
        let cr: [UInt8]
    }

    private struct EncodingFixture {
        let format: OSType
        let lumaCodes: [UInt8]
        let cbCodes: [UInt8]
        let crCodes: [UInt8]
    }

    func testExtractPreservesActiveCodesRangeAndChromaSiting() throws {
        for fixture in extractionFixtures() {
            let source = try makePixelBuffer(format: fixture.format)
            write(
                luma: fixture.luma,
                cb: fixture.cb,
                cr: fixture.cr,
                to: source
            )
            CVBufferSetAttachment(
                source,
                kCVImageBufferChromaLocationTopFieldKey,
                kCVImageBufferChromaLocation_BottomLeft,
                .shouldPropagate
            )

            let frame = try ASHNV12FrameCodec.extract(from: source)

            XCTAssertEqual(frame.luma.codes, fixture.luma)
            XCTAssertEqual(frame.cb.codes, fixture.cb)
            XCTAssertEqual(frame.cr.codes, fixture.cr)
            XCTAssertEqual(frame.luma.range, fixture.range)
            XCTAssertEqual(frame.cb.range, fixture.range)
            XCTAssertEqual(frame.cr.range, fixture.range)
            XCTAssertEqual(frame.chromaSiting, .bottomLeft)
        }
    }

    func testNormalizedConversionClampsExcursionsWithExistingArithmetic() throws {
        let luma = try ASHVideoAnalyzerV2CodePlane(
            width: 4,
            height: 1,
            bytesPerRow: 4,
            codes: [0, 16, 235, 255],
            range: .video
        )
        let chroma = try ASHVideoAnalyzerV2CodePlane(
            width: 4,
            height: 1,
            bytesPerRow: 4,
            codes: [0, 16, 240, 255],
            range: .video
        )

        XCTAssertEqual(
            try ASHNV12FrameCodec.normalizedPlane(luma, channel: .luma).samples,
            [0.0, 0.0, 1.0, 1.0]
        )
        XCTAssertEqual(
            try ASHNV12FrameCodec.normalizedPlane(chroma, channel: .chroma).samples,
            [0.0, 0.0, 1.0, 1.0]
        )
    }

    func testWriteUsesExactVideoAndFullRangeCodesAndPropagatesSiting() throws {
        for fixture in encodingFixtures() {
            let destination = try makePixelBuffer(format: fixture.format)
            let lumaSamples = [0.0, 0.25, 0.5, 0.75]
            let cbSamples = [0.0, 0.25, 0.75, 1.0]
            let crSamples = [1.0, 0.75, 0.25, 0.0]

            try ASHNV12FrameCodec.write(
                luma: ASHSpatialReferencePlaneOutputV2(
                    width: 4,
                    height: 4,
                    normalizedSamples: Array(repeating: lumaSamples, count: 4).flatMap { $0 }
                ),
                cb: ASHSpatialReferencePlaneOutputV2(
                    width: 2,
                    height: 2,
                    normalizedSamples: cbSamples
                ),
                cr: ASHSpatialReferencePlaneOutputV2(
                    width: 2,
                    height: 2,
                    normalizedSamples: crSamples
                ),
                chromaSiting: .top,
                to: destination
            )

            XCTAssertEqual(
                readLuma(destination),
                Array(repeating: fixture.lumaCodes, count: 4).flatMap { $0 }
            )
            XCTAssertEqual(readChroma(destination).cb, fixture.cbCodes)
            XCTAssertEqual(readChroma(destination).cr, fixture.crCodes)
            XCTAssertEqual(
                CVBufferCopyAttachment(
                    destination,
                    kCVImageBufferChromaLocationTopFieldKey,
                    nil
                ) as? String,
                kCVImageBufferChromaLocation_Top as String
            )
        }
    }

    private func extractionFixtures() -> [ExtractionFixture] {
        let luma = Array(UInt8(0)..<UInt8(16))
        return [
            ExtractionFixture(
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                range: .video,
                luma: luma,
                cb: [16, 80, 144, 208],
                cr: [32, 96, 160, 224]
            ),
            ExtractionFixture(
                format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                range: .full,
                luma: luma,
                cb: [0, 64, 128, 192],
                cr: [32, 96, 160, 255]
            )
        ]
    }

    private func encodingFixtures() -> [EncodingFixture] {
        [
            EncodingFixture(
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                lumaCodes: [16, 71, 126, 180],
                cbCodes: [16, 72, 184, 240],
                crCodes: [240, 184, 72, 16]
            ),
            EncodingFixture(
                format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                lumaCodes: [0, 64, 128, 191],
                cbCodes: [0, 64, 191, 255],
                crCodes: [255, 191, 64, 0]
            )
        ]
    }

    private func makePixelBuffer(format: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            format,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("Unable to create NV12 pixel buffer")
        }
        return pixelBuffer
    }

    private func write(
        luma: [UInt8],
        cb: [UInt8],
        cr: [UInt8],
        to pixelBuffer: CVPixelBuffer
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<4 {
            for column in 0..<4 {
                lumaBase[(row * lumaStride) + column] = luma[(row * 4) + column]
            }
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<2 {
            for column in 0..<2 {
                let index = (row * 2) + column
                chromaBase[(row * chromaStride) + (column * 2)] = cb[index]
                chromaBase[(row * chromaStride) + (column * 2) + 1] = cr[index]
            }
        }
    }

    private func readLuma(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        return (0..<4).flatMap { row in
            (0..<4).map { column in base[(row * stride) + column] }
        }
    }

    private func readChroma(_ pixelBuffer: CVPixelBuffer) -> (cb: [UInt8], cr: [UInt8]) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        var cb: [UInt8] = []
        var cr: [UInt8] = []
        for row in 0..<2 {
            for column in 0..<2 {
                cb.append(base[(row * stride) + (column * 2)])
                cr.append(base[(row * stride) + (column * 2) + 1])
            }
        }
        return (cb, cr)
    }
}
