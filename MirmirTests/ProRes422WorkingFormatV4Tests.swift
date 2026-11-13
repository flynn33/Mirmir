import AVFoundation
import CoreVideo
import CryptoKit
import XCTest
@testable import Mirmir

@MainActor final class ProRes422WorkingFormatV4Tests: XCTestCase {
    private func policy(height: Int = 8, scan: ProRes422WorkingFormatV4.Scan = .progressive)
        throws -> ProRes422WorkingFormatV4 {
        try .init(width: 8, height: height, scan: scan,
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }
    private func converter(_ policy: ProRes422WorkingFormatV4) throws -> ProRes422WorkingConverterV4 {
        try .init(policy: policy, workingAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: policy.width,
            kCVPixelBufferHeightKey as String: policy.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
    }
    private func packed(height: Int = 8) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, height,
            kCVPixelFormatType_422YpCbCr16, nil, &optional), kCVReturnSuccess)
        let result = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(result, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let stride = CVPixelBufferGetBytesPerRow(result)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result))
        memset(base, 0xa5, stride * height)
        for row in 0..<height {
            let bytes = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            for pair in 0..<4 {
                let words = [UInt16((100 + row * 40 + pair) * 64),
                             UInt16((80 + row + pair * 2) * 64 + 32),
                             UInt16((800 - row * 30 - pair) * 64),
                             UInt16((81 + row + pair * 2) * 64 + 32)]
                for (component, word) in words.enumerated() {
                    bytes[pair * 8 + component * 2] = UInt8(truncatingIfNeeded: word)
                    bytes[pair * 8 + component * 2 + 1] = UInt8(truncatingIfNeeded: word >> 8)
                }
            }
        }
        return result
    }
    private func bytes(_ buffer: CVPixelBuffer) throws -> Data {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        if !CVPixelBufferIsPlanar(buffer) {
            return Data(bytes: try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)),
                        count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        var result = Data()
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 2 : 4)
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                result.append(Data(bytes: base.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)), count: rowBytes))
            }
        }
        return result
    }
    private func uvCodes(_ buffer: CVPixelBuffer) throws -> [UInt16] {
        let raw = try bytes(buffer), yBytes = CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer) * 2
        return stride(from: yBytes, to: raw.count, by: 2).map {
            (UInt16(raw[$0]) | (UInt16(raw[$0 + 1]) << 8)) >> 6
        }
    }
    private func attachments(_ buffer: CVPixelBuffer) -> [NSDictionary] {
        [CVAttachmentMode.shouldPropagate, .shouldNotPropagate].map {
            CVBufferCopyAttachments(buffer, $0) as NSDictionary? ?? [:]
        }
    }

    func testProgressiveAndEachFieldUseAllTheirOwnRows() throws {
        for scan in [ProRes422WorkingFormatV4.Scan.progressive, .topFirst, .bottomFirst] {
            let source = try packed(), before = try bytes(source)
            let result = try converter(policy(scan: scan)).convert(source)
            let cb = scan == .progressive ? [120, 200, 280, 360] : [140, 180, 300, 340]
            let cr = scan == .progressive ? [785, 725, 665, 605] : [770, 740, 650, 620]
            let expected: [UInt16] = (0..<4).flatMap { row in
                (0..<4).flatMap { pair in [UInt16(cb[row] + pair), UInt16(cr[row] - pair)] }
            }
            XCTAssertEqual(try uvCodes(result), expected, scan.rawValue)
            XCTAssertEqual(try bytes(source), before)
            XCTAssertEqual(CVBufferCopyAttachment(result, kCVImageBufferChromaLocationTopFieldKey, nil) as? String, "Left")
            XCTAssertEqual((CVBufferCopyAttachment(result, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue, scan.fieldCount)
            XCTAssertEqual(CVBufferCopyAttachment(result, kCVImageBufferFieldDetailKey, nil) as? String, scan.fieldDetail)
            let raw = try bytes(result)
            XCTAssertTrue(stride(from: 0, to: raw.count, by: 2).allSatisfy { raw[$0] & 63 == 0 })
        }
    }

    func testOddProgressiveHeightUsesTheAvailableFinalRow() throws {
        let result = try converter(policy(height: 5)).convert(packed(height: 5))
        let cb = [120, 200, 260], cr = [785, 725, 680]
        let expected: [UInt16] = (0..<3).flatMap { row in
            (0..<4).flatMap { pair in [UInt16(cb[row] + pair), UInt16(cr[row] - pair)] }
        }
        XCTAssertEqual(try uvCodes(result), expected)
        XCTAssertThrowsError(try policy(height: 6, scan: .topFirst))
        XCTAssertThrowsError(try policy(height: 7, scan: .bottomFirst))
    }

    func testLumaPrecisionUsesNearestTiesEvenWithoutMovingPixels() throws {
        let source = try packed(height: 2)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        let values: [UInt16] = [0, 31, 32, 33, 95, 96, 97, 65535]
        for row in 0..<2 { for (column, value) in values.enumerated() {
            let offset = row * CVPixelBufferGetBytesPerRow(source) + column / 2 * 8 + (column % 2 == 0 ? 2 : 6)
            base[offset] = UInt8(truncatingIfNeeded: value); base[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }}
        CVPixelBufferUnlockBaseAddress(source, [])
        let result = try converter(policy(height: 2)).convert(source)
        let raw = try bytes(result)
        let y = stride(from: 0, to: 32, by: 2).map { (UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8) >> 6 }
        XCTAssertEqual(y, [0, 0, 0, 1, 1, 2, 2, 1023, 0, 0, 0, 1, 1, 2, 2, 1023])
    }

    func testSourceBytesAndBothMetadataModesRemainUnchangedAndPoolTagsDoNotLeak() throws {
        let transform = try converter(policy())
        for frame in 0..<16 {
            let source = try packed()
            if frame % 2 == 0 {
                CVBufferSetAttachment(source, "qa.local" as CFString, "owned" as CFString, .shouldNotPropagate)
            }
            CVBufferSetAttachment(source, "qa.propagated" as CFString, NSNumber(value: frame), .shouldPropagate)
            CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            let before = try bytes(source), metadata = attachments(source)
            let result = try transform.convert(source)
            XCTAssertEqual(try bytes(source), before); XCTAssertEqual(attachments(source), metadata)
            XCTAssertEqual(CVBufferCopyAttachment(result, "qa.local" as CFString, nil) as? String,
                           frame % 2 == 0 ? "owned" : nil)
            XCTAssertEqual((CVBufferCopyAttachment(result, "qa.propagated" as CFString, nil) as? NSNumber)?.intValue, frame)
            XCTAssertEqual(CVBufferCopyAttachment(result, kCVImageBufferYCbCrMatrixKey, nil) as? String, "ITU_R_709_2")
        }
    }

    func testContradictorySurfaceMetadataFailsWithoutTouchingSource() throws {
        let settings: [(CFString, CFTypeRef)] = [
            (kCVImageBufferFieldCountKey, NSNumber(value: 2)),
            (kCVImageBufferFieldDetailKey, kCVImageBufferFieldDetailTemporalTopFirst),
            (kCVImageBufferChromaSubsamplingKey, kCVImageBufferChromaSubsampling_420),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center),
            (kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanTrue)]
        for (key, value) in settings {
            let source = try packed(); CVBufferSetAttachment(source, key, value, .shouldNotPropagate)
            let before = try bytes(source), metadata = attachments(source)
            XCTAssertThrowsError(try converter(policy()).convert(source))
            XCTAssertEqual(try bytes(source), before); XCTAssertEqual(attachments(source), metadata)
        }
    }

    func testDecodedPolicyCannotBypassConstructorAndIdentityCannotCollide() throws {
        let original = try policy()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["width"] = 0
        let decoded = try JSONDecoder().decode(ProRes422WorkingFormatV4.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try converter(decoded))
        let a = try ProRes422WorkingFormatV4(width: 8, height: 8, scan: .progressive,
            primaries: "a|b", transfer: "c", matrix: "d")
        let b = try ProRes422WorkingFormatV4(width: 8, height: 8, scan: .progressive,
            primaries: "a", transfer: "b|c", matrix: "d")
        XCTAssertNotEqual(a.identity, b.identity)
    }

    func testHeaderOwnershipAndScanRejectTruncationConcatenationAndReservedValues() throws {
        var header = Data(repeating: 0, count: 40)
        header[3] = 40; header.replaceSubrange(4..<8, with: Data("icpf".utf8))
        header[9] = 20; header[17] = 8; header[19] = 8; header[20] = 0x80
        header[22] = 1; header[23] = 1; header[24] = 1
        let facts = try ProRes422SourceFactsV4.header(header)
        XCTAssertEqual(facts.scan, .progressive); XCTAssertEqual(facts.width, 8)
        for length in 0..<header.count { XCTAssertThrowsError(try ProRes422SourceFactsV4.header(header.prefix(length))) }
        XCTAssertThrowsError(try ProRes422SourceFactsV4.header(header + header))
        for (offset, value): (Int, UInt8) in [(11, 2), (17, 0), (20, 0xc0), (20, 0x8c), (22, 255), (23, 255), (24, 255), (25, 1)] {
            var wrong = header; wrong[offset] = value
            XCTAssertThrowsError(try ProRes422SourceFactsV4.header(wrong))
        }
        for (mode, scan): (UInt8, ProRes422WorkingFormatV4.Scan) in [(4, .topFirst), (8, .bottomFirst)] {
            var interlaced = header; interlaced[20] |= mode
            XCTAssertEqual(try ProRes422SourceFactsV4.header(interlaced).scan, scan)
        }
    }

    func testChangedDeliveryIdentityRejectsPreparedCheckpointBeforeProcessing() async throws {
        let runtime = try ASHP06RuntimeProviderV4.production(for: .cpu).load()
        func configuration(_ identity: String) -> DeterministicPreparedConfigurationV4 {
            DeterministicPreparedConfigurationV4(backendID: .mirmirDeterministicCPU,
                executionBackend: .cpu, storage: .p010VideoRange10Bit,
                sourceWidth: 16, sourceHeight: 12, targetWidth: 32, targetHeight: 24,
                scanMode: .progressive, chromaGeometry: .init(source: .left, target: .left),
                sourceDeliveryIdentity: identity)
        }
        let first = try PreparedDeterministicV4Upscaler(configuration: configuration("delivery-a"), runtime: runtime)
        let second = try PreparedDeterministicV4Upscaler(configuration: configuration("delivery-b"), runtime: runtime)
        let source = try PixelBufferSignalCodecV4.makeBuffer(storage: .p010VideoRange10Bit,
            width: 16, height: 12, metalCompatible: false)
        let destination = try PixelBufferSignalCodecV4.makeBuffer(storage: .p010VideoRange10Bit,
            width: 32, height: 24, metalCompatible: false)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                let words = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for column in 0..<(CVPixelBufferGetWidthOfPlane(source, plane) * (plane == 0 ? 1 : 2)) {
                    words[column] = 512 << 6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        CVBufferSetAttachment(source, kCVImageBufferFieldCountKey, NSNumber(value: 1), .shouldPropagate)
        CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Left, .shouldPropagate)
        try await first.process(source: FramePixelBuffer(source), destination: FramePixelBuffer(destination),
            timing: FrameTiming(frameIndex: 0, presentationTime: .zero, duration: CMTime(value: 1, timescale: 24)))
        let plan = ASHSHA256V4(rawData: Data("same-plan-different-native-delivery".utf8))
        let checkpoint = try await first.makeTemporalCheckpoint(planSHA256: plan, lastCompletedInputOrdinal: 0)
        do {
            try await second.restoreTemporalCheckpoint(checkpoint, planSHA256: plan)
            XCTFail("A different decoder/working delivery restored the temporal state")
        } catch let error as ASHPreparedTemporalCheckpointV4Error {
            XCTAssertEqual(error, .identityMismatch)
        }
        try await first.finish(); try await second.finish()
    }

    func testActualProgressiveTFFBFFAndMissingColrUseOriginalHeadersAndNative422() async throws {
        for name in ["progressive", "top-first", "bottom-first", "progressive-no-colr"] {
            let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: "mov", subdirectory: "ProRes422WorkingV4"))
            let original = try Data(contentsOf: input), asset = AVURLAsset(url: input)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let facts = try XCTUnwrap(ProRes422SourceFactsV4.resolve(asset: asset, track: track, descriptions: descriptions))
            let scan: ProRes422WorkingFormatV4.Scan = name == "top-first" ? .topFirst
                : name == "bottom-first" ? .bottomFirst : .progressive
            XCTAssertEqual(facts.scan, scan)
            let info = try await VideoProbe().probe(url: input)
            let delivery = try XCTUnwrap(info.proRes422WorkingFormat)
            XCTAssertEqual(delivery.matrix, "ITU_R_709_2")
            XCTAssertEqual(delivery.scan, scan)
            let transform = try converter(delivery)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: delivery.readerOutputSettings)
            reader.add(output); XCTAssertTrue(reader.startReading())
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                let source = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
                let before = try bytes(source), metadata = attachments(source)
                let result = try transform.convert(source)
                XCTAssertEqual(try bytes(source), before); XCTAssertEqual(attachments(source), metadata)
                XCTAssertEqual(CVPixelBufferGetPixelFormatType(result), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                for (kind, data) in [("v216", before), ("p010", try bytes(result))] {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
                    attachment.name = "prores-\(name)-frame\(frames)-\(kind).raw"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
                frames += 1
            }
            XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
            XCTAssertEqual(frames, 4); XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }
}
