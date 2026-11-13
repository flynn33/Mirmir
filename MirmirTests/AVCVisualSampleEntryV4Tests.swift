import AVFoundation
import CoreMedia
import XCTest
@testable import Mirmir

final class AVCVisualSampleEntryV4Tests: XCTestCase {
    func testObservedISOAndMOVWrappersMatchOnlyInStreamProofs() throws {
        for hasUUID in [false, true] {
            let iso = try fixture(iso: true, hasUUID: hasUUID)
            let movie = try fixture(iso: false, hasUUID: hasUUID)
            if !hasUUID {
                XCTAssertEqual(ASHSHA256V4(rawData: iso.raw).rawValue,
                    "3d6785e75b07b3ec1349b620464802107bcbc6757ac04bc4d3316036b4864ca9")
                XCTAssertEqual(ASHSHA256V4(rawData: movie.raw).rawValue,
                    "2526a01a6404ff9201e0f5d8907f1f9f8d84896e22a061f0355959034c442a30")
            }
            let source = try iso.format()
            let output = try movie.format()
            XCTAssertNotEqual(try graph(source), try graph(output))
            XCTAssertEqual(try stream(source), try stream(output))
            XCTAssertEqual(try AVFoundationTrackGraphAdapterV4
                .canonicalSampleStreamFormatDescriptor(source, ordinal: 7).ordinal, 7)
            XCTAssertEqual(try digest(source), try digest(output))
        }
    }

    func testEveryVisualHeaderByteRemainsBound() throws {
        let original = try fixture(iso: true)
        let expected = try stream(original.format())
        for offset in 4..<86 {
            var changed = original
            changed.header[offset] ^= 1
            XCTAssertNotEqual(try stream(changed.format()), expected,
                              "VisualSampleEntry byte \(offset) must remain bound")
        }
    }

    func testDefaultCompressorLabelDoesNotHideOtherNamesOrPadding() throws {
        let iso = try fixture(iso: true, hasUUID: true)
        let movie = try fixture(iso: false, hasUUID: true)
        let expected = try stream(iso.format())
        XCTAssertEqual(try stream(movie.format()), expected)
        for original in [iso, movie] {
            for offset in 50..<82 {
                var changed = original
                changed.header[offset] ^= 1
                XCTAssertNotEqual(try stream(changed.format()), expected,
                                  "Compressor name byte \(offset) must remain bound")
            }
        }
        var otherLogicalName = iso
        otherLogicalName.properties["FormatName"] = "different name"
        XCTAssertNotEqual(try stream(otherLogicalName.format()), expected)
    }

    func testCodecConfigurationAspectColorFieldAndOtherExtensionsRemainBound() throws {
        let original = try fixture(iso: false)
        let expected = try stream(original.format())
        for offset in [12, 40] { // One SPS byte and one PPS byte.
            var changed = original
            var configuration = try XCTUnwrap(changed.opaque["avcC"])
            configuration[offset] ^= 1
            changed.replaceAtom("avcC", payload: configuration)
            XCTAssertNotEqual(try stream(changed.format()), expected)
        }
        var aspect = original
        aspect.replaceAtom("pasp", payload: Data([0, 0, 0, 2, 0, 0, 0, 1]), exposed: false)
        aspect.properties["CVPixelAspectRatio"] = ["HorizontalSpacing": 2, "VerticalSpacing": 1]
        XCTAssertNotEqual(try stream(aspect.format()), expected)
        var color = original
        color.replaceAtom("colr", payload: Data([0x6E, 0x63, 0x6C, 0x63, 0, 2, 0, 2, 0, 6]), exposed: false)
        color.properties["CVImageBufferYCbCrMatrix"] = "ITU_R_601_4"
        XCTAssertNotEqual(try stream(color.format()), expected)
        var field = original
        field.replaceAtom("fiel", payload: Data([2, 1]), exposed: false)
        field.properties["CVFieldCount"] = 2
        field.properties["CVFieldDetail"] = "TemporalTopFirst"
        XCTAssertNotEqual(try stream(field.format()), expected)
        XCTAssertEqual(try stream(field.format()), try graph(field.format()))
        var extensionValue = original
        extensionValue.properties["unrecognized-description-extension"] = Data([1, 2, 3])
        XCTAssertNotEqual(try stream(extensionValue.format()), expected)
    }

    func testExplicitNCLXAndNCLCColorCodesRemainBound() throws {
        for fullRange in [false, true] {
            var iso = try fixture(iso: true)
            var movie = try fixture(iso: false)
            for key in ["CVImageBufferColorPrimaries", "CVImageBufferTransferFunction", "CVImageBufferYCbCrMatrix"] {
                iso.properties[key] = "ITU_R_709_2"
                movie.properties[key] = "ITU_R_709_2"
            }
            iso.properties["FullRangeVideo"] = fullRange
            movie.properties["FullRangeVideo"] = fullRange
            let codes = Data([0, 1, 0, 1, 0, 1])
            iso.atoms.append(Atom(type: "colr", payload: Data("nclx".utf8) + codes + [fullRange ? 0x80 : 0]))
            movie.replaceAtom("colr", payload: Data("nclc".utf8) + codes, exposed: false)
            let expected = try stream(iso.format())
            XCTAssertEqual(try stream(movie.format()), expected)
            XCTAssertEqual(try digest(iso.format()), try digest(movie.format()))
            for offset in 4..<11 {
                var inconsistent = iso
                let index = try XCTUnwrap(inconsistent.atoms.firstIndex { $0.type == "colr" })
                inconsistent.atoms[index].payload[offset] ^= 1
                XCTAssertNotEqual(try stream(inconsistent.format()), expected)
                XCTAssertEqual(try stream(inconsistent.format()), try graph(inconsistent.format()))
            }
            var changedColor = movie
            changedColor.replaceAtom("colr", payload: Data("nclc".utf8) + [0, 1, 0, 1, 0, 6], exposed: false)
            changedColor.properties["CVImageBufferYCbCrMatrix"] = "ITU_R_601_4"
            XCTAssertNotEqual(try stream(changedColor.format()), expected)
            var unsupported = movie
            unsupported.replaceAtom("colr", payload: Data("prof".utf8) + codes, exposed: false)
            XCTAssertEqual(try stream(unsupported.format()), try graph(unsupported.format()))
        }
    }

    func testExposedOpaqueAtomsRetainBytesPresenceAndRelativeOrder() throws {
        var iso = try fixture(iso: true, hasUUID: true)
        var movie = try fixture(iso: false, hasUUID: true)
        for atom in [Atom(type: "abcd", payload: Data([1, 2, 3])),
                     Atom(type: "efgh", payload: Data([4, 5, 6]))] {
            iso.atoms.append(atom); iso.opaque[atom.type] = atom.payload
            movie.atoms.append(atom); movie.opaque[atom.type] = atom.payload
        }
        let expected = try stream(iso.format())
        XCTAssertEqual(try stream(movie.format()), expected)
        var changed = movie
        changed.replaceAtom("uuid", payload: Data(repeating: 7, count: 20))
        XCTAssertNotEqual(try stream(changed.format()), expected)
        changed = movie
        changed.atoms.removeAll { $0.type == "abcd" }
        XCTAssertNotEqual(try stream(changed.format()), expected)
        changed = movie
        let a = try XCTUnwrap(changed.atoms.firstIndex { $0.type == "abcd" })
        let b = try XCTUnwrap(changed.atoms.firstIndex { $0.type == "efgh" })
        changed.atoms.swapAt(a, b)
        XCTAssertNotEqual(try stream(changed.format()), expected)
    }

    func testHiddenDuplicateMalformedAndUnsupportedWrappersRemainVerbatim() throws {
        let original = try fixture(iso: false)
        var cases: [Fixture] = []
        var hidden = original
        hidden.atoms.append(Atom(type: "zzzz", payload: Data([1, 2, 3])))
        cases.append(hidden)
        for type in ["avcC", "pasp", "fiel"] {
            var duplicate = original
            duplicate.atoms.append(try XCTUnwrap(duplicate.atoms.first { $0.type == type }))
            cases.append(duplicate)
        }
        var unsupportedVersion = original
        unsupportedVersion.header[17] = 1
        cases.append(unsupportedVersion)
        var reserved = original
        reserved.header[8] = 1
        cases.append(reserved)
        var name = original
        name.header[50] = 32
        cases.append(name)
        var tail = original
        tail.padding = Data([0, 0, 0, 1])
        cases.append(tail)
        var largeBox = original
        var raw = largeBox.raw
        raw.replaceSubrange(86..<90, with: [0, 0, 0, 1])
        largeBox.rawOverride = raw
        cases.append(largeBox)
        for count in 1..<86 {
            var truncated = original
            truncated.rawOverride = original.raw.prefix(count)
            cases.append(truncated)
        }
        var bothWrappers = original
        bothWrappers.properties["VerbatimISOSampleEntry"] = Data([1, 2, 3])
        cases.append(bothWrappers)
        for key in ["VerifiedAVCVisualSampleEntryHeaderV4", "VerifiedAVCOpaqueAtomOrderV4"] {
            var collision = original
            collision.properties[key] = Data([9, 8, 7])
            cases.append(collision)
        }
        for (index, value) in cases.enumerated() {
            let format = try value.format()
            XCTAssertEqual(try stream(format), try graph(format),
                           "Unsupported case \(index) must retain the complete wrapper")
        }
    }

    private struct Atom {
        let type: String
        var payload: Data
    }

    private struct Fixture {
        var header: Data
        var atoms: [Atom]
        var opaque: [String: Data]
        var properties: [String: Any]
        let isISO: Bool
        var padding: Data
        var rawOverride: Data?

        var raw: Data {
            if let rawOverride { return rawOverride }
            var result = header
            for atom in atoms {
                var length = UInt32(atom.payload.count + 8).bigEndian
                withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
                result.append(contentsOf: atom.type.utf8)
                result.append(atom.payload)
            }
            result.append(padding)
            var length = UInt32(result.count).bigEndian
            withUnsafeBytes(of: &length) { result.replaceSubrange(0..<4, with: $0) }
            return result
        }

        mutating func replaceAtom(_ type: String, payload: Data, exposed: Bool = true) {
            let index = atoms.firstIndex { $0.type == type }!
            atoms[index].payload = payload
            if exposed { opaque[type] = payload }
        }

        func format() throws -> CMFormatDescription {
            var extensions = properties
            extensions["SampleDescriptionExtensionAtoms"] = opaque
            extensions[isISO ? "VerbatimISOSampleEntry" : "VerbatimSampleDescription"] = raw
            var result: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_H264, width: 160, height: 96,
                extensions: extensions as CFDictionary, formatDescriptionOut: &result)
            XCTAssertEqual(status, noErr)
            return try XCTUnwrap(result)
        }
    }

    private func fixture(iso: Bool, hasUUID: Bool = false) throws -> Fixture {
        let configuration = try bytes("0164000affe1001c6764000aacb2051b602d4080805000000300100000030300f122648001000668ebc3cb22c0fdf8f800")
        let rate = try bytes("000000000001eda200000000")
        let uuid = try bytes("6b6840f25f244fc5ba39a51bcf0323f300000000")
        var header = Data(repeating: 0, count: 86)
        header.replaceSubrange(4..<8, with: "avc1".utf8)
        func put(_ value: UInt32, at offset: Int, bytes: Int) {
            for index in 0..<bytes {
                header[offset + index] = UInt8(truncatingIfNeeded: value >> ((bytes - 1 - index) * 8))
            }
        }
        put(1, at: 14, bytes: 2)
        put(160, at: 32, bytes: 2); put(96, at: 34, bytes: 2)
        put(72 << 16, at: 36, bytes: 4); put(72 << 16, at: 40, bytes: 4)
        put(1, at: 48, bytes: 2); put(24, at: 82, bytes: 2); put(65_535, at: 84, bytes: 2)
        let name = hasUUID ? (iso ? "" : "'avc1'") : "Lavc62.28.102 libx264"
        header[50] = UInt8(name.utf8.count)
        header.replaceSubrange(51..<(51 + name.utf8.count), with: name.utf8)
        let avc = Atom(type: "avcC", payload: configuration)
        let auxiliary = Atom(type: hasUUID ? "uuid" : "btrt", payload: hasUUID ? uuid : rate)
        let aspect = Atom(type: "pasp", payload: Data([0, 0, 0, 1, 0, 0, 0, 1]))
        let materialized = [
            Atom(type: "colr", payload: Data([0x6E, 0x63, 0x6C, 0x63, 0, 2, 0, 2, 0, 1])),
            Atom(type: "fiel", payload: Data([1, 0])), Atom(type: "chrm", payload: Data([0, 0]))
        ]
        let atoms = iso ? (hasUUID ? [avc, auxiliary, aspect] : [avc, aspect, auxiliary])
            : (hasUUID ? [avc, auxiliary] : [auxiliary, avc]) + materialized + [aspect]
        return Fixture(header: header, atoms: atoms,
            opaque: ["avcC": configuration, auxiliary.type: auxiliary.payload],
            properties: ["CVFieldCount": 1, "CVImageBufferChromaLocationBottomField": "Left",
                "CVImageBufferChromaLocationTopField": "Left", "CVImageBufferYCbCrMatrix": "ITU_R_709_2",
                "CVPixelAspectRatio": ["HorizontalSpacing": 1, "VerticalSpacing": 1], "Depth": 24,
                "FormatName": hasUUID ? "'avc1'" : name, "FullRangeVideo": false,
                "RevisionLevel": 0, "SpatialQuality": 0, "TemporalQuality": 0, "Version": 0],
            isISO: iso, padding: iso ? Data() : Data(repeating: 0, count: 4))
    }

    private func bytes(_ hex: String) throws -> Data {
        let values = Array(hex.utf8)
        var data = Data()
        for offset in stride(from: 0, to: values.count, by: 2) {
            data.append(try XCTUnwrap(UInt8(String(decoding: values[offset..<(offset + 2)], as: UTF8.self), radix: 16)))
        }
        return data
    }

    private func graph(_ format: CMFormatDescription) throws -> MediaTrackFormatDescriptorV4 {
        try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(format)
    }

    private func stream(_ format: CMFormatDescription) throws -> MediaTrackFormatDescriptorV4 {
        try AVFoundationTrackGraphAdapterV4.canonicalSampleStreamFormatDescriptor(format)
    }

    private func digest(_ format: CMFormatDescription) throws -> ASHSHA256V4 {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: 4, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: 4, flags: 0,
            blockBufferOut: &block), noErr)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 7, blockBuffer: try XCTUnwrap(block),
                                               offsetIntoDestination: 0, dataLength: 4), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: .zero, decodeTimeStamp: .zero)
        var size = 4
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        var accumulator = SampleStreamAccumulatorV4()
        try accumulator.append(try XCTUnwrap(sample))
        return accumulator.digest
    }
}
