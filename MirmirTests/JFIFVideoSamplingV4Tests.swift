import AVFoundation
import CoreVideo
import XCTest
@testable import Mirmir

final class JFIFVideoSamplingV4Tests: XCTestCase {
    // Marker-framing fixture, not a claim that these synthetic entropy bytes decode.
    private func image(width: Int = 160, height: Int = 96, coding: UInt8 = 0xc0) -> Data {
        func marker(_ code: UInt8, _ payload: [UInt8]) -> [UInt8] {
            let n = payload.count + 2
            return [255, code, UInt8(n >> 8), UInt8(n & 255)] + payload
        }
        return Data([255, 216]
            + marker(0xe0, Array("JFIF\0".utf8) + [1, 2, 0, 0, 1, 0, 1, 0, 0])
            + marker(coding, [8, UInt8(height >> 8), UInt8(height & 255), UInt8(width >> 8), UInt8(width & 255),
                              3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
            + marker(0xda, [3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0])
            + [1, 2, 255, 0, 3, 255, 0xd0, 4, 255, 217])
    }

    private func description(_ extra: [String: Any] = [:], width: Int32 = 160) throws -> CMFormatDescription {
        var values: [String: Any] = [kCMFormatDescriptionExtension_FieldCount as String: 1]
        values.merge(extra, uniquingKeysWith: { _, new in new })
        var result: CMFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_JPEG, width: width, height: 96,
            extensions: values as CFDictionary, formatDescriptionOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    func testCompleteImageOwnershipRejectsTruncationsAndConcatenatedFields() throws {
        let data = image()
        let proof = try XCTUnwrap(JFIFVideoSamplingV4.progressiveDeclaration(from: description()))
        try proof.validatePacket(data)
        for n in 0..<data.count {
            XCTAssertNil(JFIFVideoSamplingV4.fullImageRaster(data.prefix(n)), "prefix \(n)")
        }
        for invalid in [data + data, data + [0], data.dropFirst(2), image(width: 162)] {
            XCTAssertThrowsError(try proof.validatePacket(Data(invalid)))
        }
        var noJFIF = data; noJFIF[6] = 0
        XCTAssertNil(JFIFVideoSamplingV4.fullImageRaster(noJFIF))
        var wrongGrid = data; wrongGrid[31] = 0x21
        XCTAssertNil(JFIFVideoSamplingV4.fullImageRaster(wrongGrid))
        // A JPEG progressive coding marker does not change a movie scan declaration.
        try proof.validatePacket(image(coding: 0xc2))
    }

    func testContainerContradictionsAreNotInferredFromJPEGCodeMode() throws {
        let values: [(CFString, Any)] = [
            (kCMFormatDescriptionExtension_FieldCount, 2),
            (kCMFormatDescriptionExtension_FieldCount, "1"),
            (kCMFormatDescriptionExtension_FieldDetail, kCMFormatDescriptionFieldDetail_TemporalTopFirst),
            (kCMFormatDescriptionExtension_BitsPerComponent, 10),
            (kCMFormatDescriptionExtension_FullRangeVideo, false),
            (kCVImageBufferChromaSubsamplingKey, kCVImageBufferChromaSubsampling_422),
            (kCMFormatDescriptionExtension_ChromaLocationTopField, kCMFormatDescriptionChromaLocation_Left),
            (kCMFormatDescriptionExtension_ChromaLocationBottomField, kCMFormatDescriptionChromaLocation_Left)
        ]
        for (key, value) in values {
            XCTAssertThrowsError(try JFIFVideoSamplingV4.progressiveDeclaration(from: description([key as String: value])))
        }
        let proof = try XCTUnwrap(JFIFVideoSamplingV4.progressiveDeclaration(from: description(width: 162)))
        XCTAssertThrowsError(try proof.validatePacket(image()))
    }

    private func buffer(_ pixel: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, pixel,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let b = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(b, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        for p in 0..<CVPixelBufferGetPlaneCount(b) {
            let n = CVPixelBufferGetHeightOfPlane(b, p) * CVPixelBufferGetBytesPerRowOfPlane(b, p)
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(b, p)), p == 0 ? 37 : 139, n)
        }
        CVBufferSetAttachment(b, "opaque.local" as CFString, Data([4, 5]) as CFData, .shouldNotPropagate)
        CVBufferSetAttachment(b, "opaque.propagated" as CFString, Data([6, 7]) as CFData, .shouldPropagate)
        return b
    }
    private func bytes(_ b: CVPixelBuffer) throws -> Data {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(b, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        var out = Data()
        for p in 0..<CVPixelBufferGetPlaneCount(b) {
            out.append(Data(bytes: try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(b, p)),
                            count: CVPixelBufferGetHeightOfPlane(b, p) * CVPixelBufferGetBytesPerRowOfPlane(b, p)))
        }
        return out
    }
    private func attachments(_ b: CVPixelBuffer) -> [NSDictionary] {
        [.shouldPropagate, .shouldNotPropagate].map {
            CVBufferCopyAttachments(b, $0) as NSDictionary? ?? [:]
        }
    }

    func testNormalizationPreservesEveryByteAndCorrectAttachmentMode() throws {
        let proof = try XCTUnwrap(JFIFVideoSamplingV4.progressiveDeclaration(from: description()))
        for mode: CVAttachmentMode? in [nil, .shouldPropagate, .shouldNotPropagate] {
            let b = try buffer()
            if let mode {
                for k in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
                    CVBufferSetAttachment(b, k, kCVImageBufferChromaLocation_Center, mode)
                }
            }
            let raw = try bytes(b), before = attachments(b)
            try JFIFVideoSamplingV4.normalizeDecodedBuffer(b, source: proof)
            XCTAssertEqual(try bytes(b), raw)
            let expected = before[0].mutableCopy() as! NSMutableDictionary
            if mode == nil { expected[kCVImageBufferChromaLocationTopFieldKey as String] = kCVImageBufferChromaLocation_Center }
            XCTAssertEqual(attachments(b), [expected, before[1]])
            let once = attachments(b)
            try JFIFVideoSamplingV4.normalizeDecodedBuffer(b, source: proof)
            XCTAssertEqual(attachments(b), once)
            XCTAssertEqual(try bytes(b), raw)
        }
    }

    func testDecodedContradictionsFailAtomicallyAndNilProofDoesNothing() throws {
        let proof = try XCTUnwrap(JFIFVideoSamplingV4.progressiveDeclaration(from: description()))
        let values: [(CFString, CFTypeRef)] = [
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, NSNumber(value: 1)),
            (kCVImageBufferFieldCountKey, NSNumber(value: 2)),
            (kCVImageBufferFieldDetailKey, kCVImageBufferFieldDetailTemporalTopFirst),
            (kCVImageBufferChromaSubsamplingKey, kCVImageBufferChromaSubsampling_422),
            (kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanFalse)
        ]
        for (key, value) in values {
            let b = try buffer(); CVBufferSetAttachment(b, key, value, .shouldNotPropagate)
            let before = attachments(b), raw = try bytes(b)
            XCTAssertThrowsError(try JFIFVideoSamplingV4.normalizeDecodedBuffer(b, source: proof))
            XCTAssertEqual(attachments(b), before); XCTAssertEqual(try bytes(b), raw)
            try JFIFVideoSamplingV4.normalizeDecodedBuffer(b, source: nil)
            XCTAssertEqual(attachments(b), before); XCTAssertEqual(try bytes(b), raw)
        }
        let wrongFormat = try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertThrowsError(try JFIFVideoSamplingV4.normalizeDecodedBuffer(wrongFormat, source: proof))
    }

    func testActualLegacyMOVNV12SurfacesRetainBytesAndUnrelatedMetadata() async throws {
        try await assertActualLegacyNV12Surfaces(ext: "mov")
    }

    func testActualLegacyAVINV12SurfacesRetainBytesAndUnrelatedMetadata() async throws {
        try await assertActualLegacyNV12Surfaces(ext: "avi")
    }

    private func assertActualLegacyNV12Surfaces(ext: String) async throws {
        do {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-mjpeg", withExtension: ext))
            let asset = try await NativeMediaInputAssetResolverV4.asset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first), descriptions = try await track.load(.formatDescriptions)
            let proof = try XCTUnwrap(JFIFVideoSamplingV4.progressiveDeclaration(from: XCTUnwrap(descriptions.first)))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                let b = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample)), raw = try bytes(b), before = attachments(b)
                try JFIFVideoSamplingV4.normalizeDecodedBuffer(b, source: proof)
                let expected = before[0].mutableCopy() as! NSMutableDictionary
                if expected[kCVImageBufferChromaLocationTopFieldKey as String] == nil
                    && before[1][kCVImageBufferChromaLocationTopFieldKey as String] == nil {
                    expected[kCVImageBufferChromaLocationTopFieldKey as String] = kCVImageBufferChromaLocation_Center
                }
                XCTAssertEqual(attachments(b), [expected, before[1]])
                XCTAssertEqual(try bytes(b), raw)
                frames += 1
            }
            XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
            XCTAssertEqual(frames, 72, ext)
        }
    }

    func testActualLegacyMOVAndAVIPacketsHaveOneMatchingJFIFImage() async throws {
        for ext in ["mov", "avi"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "legacy-mjpeg", withExtension: ext))
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            XCTAssertEqual(descriptions.count, 1)
            let proof = try XCTUnwrap(JFIFVideoSamplingV4.progressiveDeclaration(from: XCTUnwrap(descriptions.first)))
            let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                let count = CMSampleBufferGetNumSamples(sample)
                if count == 0 { continue }
                let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample)), n = CMBlockBufferGetDataLength(block)
                var data = Data(count: n)
                XCTAssertEqual(data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!)
                }, noErr)
                var offset = 0
                for index in 0..<count {
                    let size = CMSampleBufferGetSampleSize(sample, at: index)
                    XCTAssertGreaterThan(size, 0); XCTAssertLessThanOrEqual(offset + size, data.count)
                    try proof.validatePacket(data.subdata(in: offset..<(offset + size)))
                    frames += 1; offset += size
                }
                XCTAssertEqual(offset, n)
            }
            XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
            XCTAssertEqual(frames, 72, ext)
        }
    }
}
