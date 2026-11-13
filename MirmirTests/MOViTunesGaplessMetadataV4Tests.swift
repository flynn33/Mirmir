import Foundation
import XCTest
@testable import Mirmir

final class MOViTunesGaplessMetadataV4Tests: XCTestCase {
    func testBoundedPacketTablesAndPayloadHashes() throws {
        try withDirectory { directory in
            for wideOffsets in [false, true] {
                var fixture = AudioFixture()
                fixture.wideOffsets = wideOffsets
                let url = try write(fixture.bytes, named: wideOffsets ? "wide" : "normal", in: directory)
                let table = try MOViTunesGaplessMetadataV4.audioPacketTable(in: url, trackOrdinal: 0)
                XCTAssertEqual(table.packetCount, 3)
                XCTAssertEqual(table.movieTimescale, 1_000)
                XCTAssertEqual(table.mediaTimescale, 48_000)
                XCTAssertEqual(table.mediaDuration, 3_072)
                XCTAssertEqual(table.timingRuns, [.init(packetCount: 3, duration: 1_024)])
                XCTAssertEqual(try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: url, trackOrdinal: 0),
                    "3f990ba77759cfb9f09806e58b24d38782ebff939c554903ee2a36f2b383ce84")
            }
            var edits = AudioFixture()
            edits.edits = [(2, -1, 65_536), (62, 1_024, 65_536)]
            let edited = try write(edits.bytes, named: "edits", in: directory)
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.audioPacketTable(in: edited, trackOrdinal: 0).edits,
                [.init(movieDuration: 2, mediaTime: -1, mediaRate: 65_536),
                 .init(movieDuration: 62, mediaTime: 1_024, mediaRate: 65_536)])
            var constant = AudioFixture()
            constant.fixedSize = 4
            constant.mapping = [(1, 3, 1)]
            constant.offsets = [8]
            let constantURL = try write(constant.bytes, named: "constant", in: directory)
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.audioPacketTable(in: constantURL, trackOrdinal: 0).packetCount, 3)
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: constantURL, trackOrdinal: 0),
                "e253a719ee4a8058bd8954e6dd999c93e2a4107d68c7ee2463cdae38a68c350c")
            var alteredBytes = AudioFixture().bytes
            alteredBytes[8] ^= 1
            let altered = try write(alteredBytes, named: "changed-payload", in: directory)
            XCTAssertNotEqual(try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: altered, trackOrdinal: 0),
                try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: edited, trackOrdinal: 0))
        }
    }

    func testPacketSizeAndChunkMappingsRejectUnownedOrInconsistentBytes() throws {
        let cases: [(String, (inout AudioFixture) -> Void)] = [
            ("wrong-count", { $0.packetCount = 4 }),
            ("zero-size", { $0.sizes = [0, 4, 8] }),
            ("oversize", { $0.sizes = [3, 4, .max] }),
            ("first-zero", { $0.mapping = [(0, 2, 1), (2, 1, 1)] }),
            ("first-late", { $0.mapping = [(2, 3, 1)] }),
            ("duplicate-mapping", { $0.mapping = [(1, 2, 1), (1, 1, 1)] }),
            ("decreasing-mapping", { $0.mapping = [(2, 2, 1), (1, 1, 1)] }),
            ("mapping-past-chunks", { $0.mapping = [(1, 2, 1), (3, 1, 1)] }),
            ("zero-packets", { $0.mapping = [(1, 0, 1)] }),
            ("other-description", { $0.mapping = [(1, 2, 2), (2, 1, 1)] }),
            ("too-many-packets", { $0.mapping = [(1, .max, 1)] }),
            ("too-few-packets", { $0.mapping = [(1, 1, 1)] }),
            ("zero-offset", { $0.offsets = [0, 15] }),
            ("header-offset", { $0.offsets = [4, 15] }),
            ("past-mdat", { $0.offsets = [20, 15] }),
            ("unsigned-overflow", { $0.offsets = [.max, 15]; $0.wideOffsets = true }),
            ("signed-limit", { $0.offsets = [UInt64(Int64.max), 15]; $0.wideOffsets = true }),
            ("duplicate-offsets", { $0.duplicateOffsets = true }),
            ("video-handler", { $0.handler = "vide" })
        ]
        try withDirectory { directory in
            for (name, mutate) in cases {
                var fixture = AudioFixture()
                mutate(&fixture)
                let url = try write(fixture.bytes, named: name, in: directory)
                XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: url, trackOrdinal: 0), name)
            }
        }
    }

    func testPacketTableRequiresExactTimingCountDurationAndAudioClock() throws {
        let cases: [(String, (inout AudioFixture) -> Void)] = [
            ("wrong-count", { $0.packetCount = 4 }),
            ("timing-count", { $0.timing = [(2, 1_024)] }),
            ("timing-ticks", { $0.timing = [(3, 1_023)] }),
            ("zero-run", { $0.timing = [(0, 1_024)] }),
            ("zero-duration", { $0.timing = [(3, 0)] }),
            ("zero-clock", { $0.scale = 0 }),
            ("video-handler", { $0.handler = "vide" })
        ]
        try withDirectory { directory in
            for (name, mutate) in cases {
                var fixture = AudioFixture()
                mutate(&fixture)
                let url = try write(fixture.bytes, named: name, in: directory)
                XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.audioPacketTable(in: url, trackOrdinal: 0), name)
            }
            let valid = try write(AudioFixture().bytes, named: "valid", in: directory)
            for ordinal in [-1, 1, Int.max] {
                XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.audioPacketTable(in: valid, trackOrdinal: ordinal))
                XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: valid, trackOrdinal: ordinal))
            }
            XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: valid, trackOrdinal: 0,
                cancellation: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        }
    }

    func testUTF8ReplacementPreservesUnknownChildrenLocaleAndAtomWidths() throws {
        try withDirectory { directory in
            for extended in [false, true] {
                for zeroDataSize in [false, true] {
                    let original = metadataEntry(value: Data("old value".utf8), extended: extended,
                                                 zeroDataSize: zeroDataSize)
                    let url = try write(metadataMovie(original), named: "metadata-\(extended)-\(zeroDataSize)", in: directory)
                    let entry = try XCTUnwrap(MOViTunesGaplessMetadataV4.originalEntries(in: url).first)
                    XCTAssertEqual(try MOViTunesGaplessMetadataV4.utf8Value(of: entry), "old value")
                    let replaced = try MOViTunesGaplessMetadataV4.entry(replacingUTF8Value: "新 value", in: entry)
                    XCTAssertEqual(try MOViTunesGaplessMetadataV4.utf8Value(of: replaced), "新 value")
                    XCTAssertEqual(MOViTunesGaplessMetadataV4.encodedBytes(of: replaced),
                        metadataEntry(value: Data("新 value".utf8), extended: extended, zeroDataSize: zeroDataSize))
                    XCTAssertEqual(MOViTunesGaplessMetadataV4.encodedBytes(of: entry), original)
                }
            }
        }
    }

    func testUTF8ReplacementRejectsDuplicateOrOtherDataTypes() throws {
        try withDirectory { directory in
            for (name, raw) in [
                ("duplicate", metadataEntry(value: Data("old".utf8), duplicateData: true)),
                ("other-type", metadataEntry(value: Data("old".utf8), dataType: 2))
            ] {
                let url = try write(metadataMovie(raw), named: name, in: directory)
                let entry = try XCTUnwrap(MOViTunesGaplessMetadataV4.originalEntries(in: url).first)
                XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.utf8Value(of: entry))
                XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.entry(replacingUTF8Value: "new", in: entry))
                XCTAssertEqual(MOViTunesGaplessMetadataV4.encodedBytes(of: entry), raw)
            }
            let invalid = metadataEntry(value: Data([0xFF]))
            let url = try write(metadataMovie(invalid), named: "invalid-utf8", in: directory)
            let entry = try XCTUnwrap(MOViTunesGaplessMetadataV4.originalEntries(in: url).first)
            XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.utf8Value(of: entry))
        }
    }

    func testAllFreeformMergeRetainsLargeUserValuesAndRollsBackEveryCancellation() throws {
        try withDirectory { directory in
            func entry(_ namespace: String, _ name: String, _ value: Data) -> Data {
                box("----", full("mean", Data(namespace.utf8))
                    + full("name", Data(name.utf8))
                    + full("data", be(UInt32(0)) + value, flags: 1))
            }
            let original = metadataEntry(value: Data("original packet hint".utf8))
            let large = entry("com.example.qualification", "LargeUserNote", Data(repeating: 88, count: 1_200_000))
            let unicode = entry("com.example.qualification", "記録", Data("Retain 💫 exactly".utf8))
            let source = try write(metadataMovie(original + large + unicode), named: "all-source", in: directory)
            let desired = try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: source)
            XCTAssertEqual(desired.count, 3)
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.originalEntries(in: source).count, 1)
            let unrelated = entry("com.example.existing", "Other", Data("existing".utf8))
            let baseline = metadataMovie(unrelated)
            let target = try write(baseline, named: "all-target", in: directory)
            var checkpoints = 0
            XCTAssertTrue(try MOViTunesGaplessMetadataV4.insertIfMissing(desired, into: target,
                cancellation: { checkpoints += 1 }))
            let completed = try Data(contentsOf: target)
            let found = try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: target)
            XCTAssertEqual(found.map(MOViTunesGaplessMetadataV4.encodedBytes), [unrelated, original, large, unicode])
            XCTAssertEqual(try found.map(MOViTunesGaplessMetadataV4.metadataIdentifier), [
                "itlk/com.example.existing.Other", "itlk/com.apple.iTunes.iTunSMPB",
                "itlk/com.example.qualification.LargeUserNote", "itlk/com.example.qualification.記録"])
            XCTAssertFalse(try MOViTunesGaplessMetadataV4.insertIfMissing(desired, into: target))
            XCTAssertEqual(try Data(contentsOf: target), completed)
            XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.insertIfMissing([
                MOViTunesGaplessMetadataV4.entry(utf8Value: "conflicting packet hint")], into: target))
            XCTAssertEqual(try Data(contentsOf: target), completed)
            XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.insertIfMissing(desired + desired, into: target))
            XCTAssertEqual(try Data(contentsOf: target), completed)
            XCTAssertGreaterThan(checkpoints, 3)
            for failAt in 1...checkpoints {
                let cancelled = try write(baseline, named: "all-cancel-\(failAt)", in: directory)
                var count = 0
                XCTAssertThrowsError(try MOViTunesGaplessMetadataV4.insertIfMissing(desired, into: cancelled,
                    cancellation: {
                        count += 1
                        if count == failAt { throw CancellationError() }
                    })) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertEqual(try Data(contentsOf: cancelled), baseline)
            }
        }
    }

    private struct AudioFixture {
        var sizes: [UInt32] = [3, 4, 5]
        var packetCount: UInt32 = 3
        var fixedSize: UInt32 = 0
        var timing: [(UInt32, UInt32)] = [(3, 1_024)]
        var mapping: [(UInt32, UInt32, UInt32)] = [(1, 2, 1), (2, 1, 1)]
        var offsets: [UInt64] = [8, 15]
        var wideOffsets = false
        var duplicateOffsets = false
        var scale: UInt32 = 48_000
        var handler = "soun"
        var edits: [(UInt32, Int32, Int32)]?

        var bytes: Data {
            let sampleSizes = full("stsz", be(fixedSize) + be(packetCount)
                + (fixedSize == 0 ? sizes.reduce(into: Data()) { $0.append(be($1)) } : Data()))
            let times = full("stts", be(UInt32(timing.count))
                + timing.reduce(into: Data()) { $0.append(be($1.0) + be($1.1)) })
            let chunks = full("stsc", be(UInt32(mapping.count))
                + mapping.reduce(into: Data()) { $0.append(be($1.0) + be($1.1) + be($1.2)) })
            let offsetTable = full(wideOffsets ? "co64" : "stco", be(UInt32(offsets.count))
                + offsets.reduce(into: Data()) { $0.append(wideOffsets ? be($1) : be(UInt32($1))) })
            let table = box("stbl", sampleSizes + times + chunks + offsetTable
                + (duplicateOffsets ? offsetTable : Data()))
            let mediaClock = full("mdhd", Data(repeating: 0, count: 8) + be(scale) + be(UInt32(3_072)))
            let media = box("mdia", mediaClock + full("hdlr", be(UInt32(0)) + Data(handler.utf8))
                + box("minf", table))
            let editList = edits.map { edits in
                box("edts", full("elst", be(UInt32(edits.count)) + edits.reduce(into: Data()) {
                    $0.append(be($1.0) + be($1.1) + be($1.2))
                }))
            } ?? Data()
            let movieClock = full("mvhd", Data(repeating: 0, count: 8) + be(UInt32(1_000)) + be(UInt32(64)))
            return box("mdat", Data("abcDEFG12345".utf8)) + box("moov", movieClock + box("trak", media + editList))
        }
    }

    private func metadataEntry(value: Data, extended: Bool = false, zeroDataSize: Bool = false,
                               duplicateData: Bool = false, dataType: UInt32 = 1) -> Data {
        let mean = full("mean", Data("com.apple.iTunes".utf8), flags: 0x00010203)
        let name = full("name", Data("iTunSMPB".utf8), flags: 0x00040506)
        let unknown = box("junk", Data([1, 2, 3, 4, 5]), extended: extended)
        let data = box("data", be(dataType) + Data([0, 1, 2, 3]) + value,
                       extended: extended, zeroSize: zeroDataSize)
        return box("----", mean + unknown + name + data + (duplicateData ? data : Data()), extended: extended)
    }

    private func metadataMovie(_ entry: Data) -> Data {
        box("moov", box("udta", full("meta",
            full("hdlr", be(UInt32(0)) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9))
                + box("ilst", entry))))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name + ".mov")
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}

private func be<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func box(_ type: String, _ body: Data, extended: Bool = false, zeroSize: Bool = false) -> Data {
    if extended { return be(UInt32(1)) + Data(type.utf8) + be(UInt64(body.count + 16)) + body }
    return be(zeroSize ? UInt32(0) : UInt32(body.count + 8)) + Data(type.utf8) + body
}

private func full(_ type: String, _ body: Data, flags: UInt32 = 0) -> Data {
    box(type, be(flags) + body)
}
