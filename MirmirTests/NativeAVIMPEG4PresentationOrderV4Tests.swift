import AVFoundation
import XCTest
@testable import Mirmir

final class NativeAVIMPEG4PresentationOrderV4Tests: XCTestCase {
    func testNoBFramesCoverExactClockAcrossSecondBoundaries() async throws {
        let source = try await packets()
        var order = try NativeAVIMPEG4PresentationOrderV4(format: source.format)
        XCTAssertEqual(source.packets.count, 72)
        for (index, packet) in source.packets.enumerated() {
            XCTAssertEqual(try order.displayOrdinal(
                packet: packet.data, decodeOrdinal: Int64(index), duration: packet.duration
            ), Int64(index))
        }
        try order.finish()
    }

    func testBAndSpriteVOPsAreExplicitlyOutsideQualifiedNativeDecoder() async throws {
        let source = try await packets()
        for type in [2, 3] {
            let packet = vop(type: type)
            XCTAssertTrue(NativeAVIMPEG4PresentationOrderV4.containsBSVOP(packet))
            var order = try NativeAVIMPEG4PresentationOrderV4(format: source.format)
            XCTAssertThrowsError(try order.displayOrdinal(
                packet: packet, decodeOrdinal: 0, duration: step
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("B/S-VOP"))
            }
        }
        XCTAssertFalse(NativeAVIMPEG4PresentationOrderV4.containsBSVOP(vop(type: 0)))
        XCTAssertFalse(NativeAVIMPEG4PresentationOrderV4.containsBSVOP(vop(type: 1)))
    }

    func testGapInEncodedVOPClockIsRejected() async throws {
        let source = try await packets()
        var order = try NativeAVIMPEG4PresentationOrderV4(format: source.format)
        _ = try order.displayOrdinal(packet: vop(type: 0), decodeOrdinal: 0, duration: step)
        XCTAssertThrowsError(try order.displayOrdinal(
            packet: vop(type: 1, increment: 2), decodeOrdinal: 1, duration: step
        ))
    }

    func testMalformedAndUncodedVOPHeadersAreRejected() async throws {
        let source = try await packets()
        for data in [vop(type: 0, marker: 0), vop(type: 0, coded: 0), Data([0, 0, 1, 0xb6])] {
            var order = try NativeAVIMPEG4PresentationOrderV4(format: source.format)
            XCTAssertThrowsError(try order.displayOrdinal(packet: data, decodeOrdinal: 0, duration: step))
        }
    }

    func testMultiplePicturesCannotShareOneAVIPacket() async throws {
        let source = try await packets()
        var order = try NativeAVIMPEG4PresentationOrderV4(format: source.format)
        XCTAssertThrowsError(try order.displayOrdinal(
            packet: vop(type: 0) + vop(type: 1, increment: 1), decodeOrdinal: 0, duration: step
        ))
    }

    func testTrailingConfigurationAndGOVHeadersCannotEvadePrefixVerification() async throws {
        let source = try await packets()
        let first = try XCTUnwrap(source.packets.first)
        let changedDimensions = vol(width: 176, resolution: 24)
        let changedClock = vol(width: 176, resolution: 25)
        let gov = startCode(0xb3, fields: [(0, 5), (0, 6), (1, 1), (1, 6), (0, 2)])
        let suffixes = [
            changedDimensions, changedClock, gov,
            changedDimensions + gov, gov + changedClock,
            Data([0, 0, 1, 0xb0, 1]),
            Data([0, 0, 1, 0xb5, 8]),
            Data([0, 0, 1, 1])
        ]
        for suffix in suffixes {
            let packet = first.data + suffix
            var clock = try NativeAVICompressedPresentationClockV4(strategy: .aviMPEG4, format: source.format)
            let timing = CMSampleTimingInfo(duration: first.duration,
                presentationTimeStamp: .zero, decodeTimeStamp: .zero)
            XCTAssertThrowsError(try clock.presentationTime(packet: packet, timing: timing)) { error in
                XCTAssertTrue(error.localizedDescription.contains("after its coded VOP"))
            }
        }
    }

    func testChangedDimensionsAndClockBeforeVOPStillFailConfigurationVerification() async throws {
        let source = try await packets()
        let first = try XCTUnwrap(source.packets.first)
        let bytes = [UInt8](first.data)
        let starts = (0..<(bytes.count - 3)).filter {
            bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 1
        }
        let index = try XCTUnwrap(starts.firstIndex { (0x20...0x2f).contains(bytes[$0 + 3]) })
        let begin = starts[index]
        let end = index + 1 < starts.count ? starts[index + 1] : bytes.count
        for changed in [vol(width: 176, resolution: 24), vol(width: 160, resolution: 25)] {
            let packet = Data(bytes[..<begin]) + changed + Data(bytes[end...])
            XCTAssertThrowsError(try NativeMediaInputAssetResolverV4.verifyStableConfiguration(
                packet, format: source.format, strategy: .aviMPEG4
            ))
        }
    }

    func testContainerDurationCannotRelabelEncodedVOPClock() async throws {
        let source = try await packets()
        var order = try NativeAVIMPEG4PresentationOrderV4(format: source.format)
        _ = try order.displayOrdinal(packet: vop(type: 0), decodeOrdinal: 0, duration: step)
        XCTAssertThrowsError(try order.displayOrdinal(
            packet: vop(type: 1, increment: 1), decodeOrdinal: 1,
            duration: CMTime(value: 1, timescale: 12)
        ))
    }

    func testIncompleteOrNonconsecutiveInputClockIsRejected() async throws {
        let source = try await packets()
        var order = try NativeAVIMPEG4PresentationOrderV4(format: source.format)
        XCTAssertThrowsError(try order.finish())
        XCTAssertThrowsError(try order.displayOrdinal(
            packet: vop(type: 0), decodeOrdinal: 1, duration: step
        ))
    }

    private var step: CMTime { CMTime(value: 1, timescale: 24) }

    private func vol(width: Int, resolution: Int) -> Data {
        startCode(0x20, fields: [
            (0, 1), (1, 8), (0, 1), (1, 4), // Simple VOL, square pixels
            (1, 1), (1, 2), (1, 1), (0, 1), // 4:2:0, low delay, no VBV
            (0, 2), (1, 1), (resolution, 16), (1, 1), (0, 1),
            (1, 1), (width, 13), (1, 1), (96, 13), (1, 1),
            (0, 1), (1, 1), (0, 1), (0, 1), (0, 1), // progressive, no sprite/quant matrix
            (1, 1), (1, 1), (0, 1), (0, 1) // complexity/resync disabled, no partition/scalability
        ])
    }

    private func startCode(_ code: UInt8, fields: [(Int, Int)]) -> Data {
        var bits: [Int] = []
        for (value, width) in fields {
            for offset in (0..<width).reversed() { bits.append((value >> offset) & 1) }
        }
        while bits.count % 8 != 0 { bits.append(0) }
        var result = Data([0, 0, 1, code])
        for index in stride(from: 0, to: bits.count, by: 8) {
            result.append(UInt8(bits[index..<(index + 8)].reduce(0) { ($0 << 1) | $1 }))
        }
        return result
    }

    private func vop(type: Int, increment: Int = 0, marker: Int = 1, coded: Int = 1) -> Data {
        var bits: [Int] = []
        func append(_ value: Int, width: Int) {
            for offset in (0..<width).reversed() { bits.append((value >> offset) & 1) }
        }
        append(type, width: 2)
        append(0, width: 1) // modulo_time_base
        append(marker, width: 1)
        append(increment, width: 5) // Fixture VOL resolution is 24.
        append(1, width: 1)
        append(coded, width: 1)
        while bits.count % 8 != 0 { bits.append(0) }
        var result = Data([0, 0, 1, 0xb6])
        for index in stride(from: 0, to: bits.count, by: 8) {
            result.append(UInt8(bits[index..<(index + 8)].reduce(0) { ($0 << 1) | $1 }))
        }
        return result
    }

    private func packets() async throws -> (
        format: CMVideoFormatDescription, packets: [(data: Data, duration: CMTime)]
    ) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "native-avi-mpeg4", withExtension: "avi"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        var result: [(data: Data, duration: CMTime)] = []
        var original: CMFormatDescription?
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            XCTAssertEqual(data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }, noErr)
            original = original ?? CMSampleBufferGetFormatDescription(sample)
            result.append((data, CMSampleBufferGetDuration(sample)))
        }
        XCTAssertEqual(reader.status, .completed)
        let format = try NativeMediaInputAssetResolverV4.canonicalFormat(
            description: XCTUnwrap(original), firstPacket: XCTUnwrap(result.first).data, strategy: .aviMPEG4
        )
        return (format, result)
    }
}
