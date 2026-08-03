import AVFoundation
import CoreMedia
import CryptoKit
import XCTest
@testable import Mirmir

final class AVCanonicalMediaStateAdapterV4Tests: XCTestCase {
    func testExactBinaryRationalDoesNotRoundGeometry() throws {
        XCTAssertEqual(
            try ASHExactBinaryRationalV4.convert(0.5, path: "half"),
            try ExactRationalV4(1, 2)
        )
        XCTAssertEqual(
            try ASHExactBinaryRationalV4.convert(-1.25, path: "negative"),
            try ExactRationalV4(-5, 4)
        )
        XCTAssertEqual(
            try ASHExactBinaryRationalV4.convert(-0.0, path: "negative-zero"),
            .zero
        )
        XCTAssertThrowsError(
            try ASHExactBinaryRationalV4.convert(Double.nan, path: "nan")
        )
        XCTAssertThrowsError(
            try ASHExactBinaryRationalV4.convert(
                Double.leastNonzeroMagnitude,
                path: "subnormal"
            )
        )
    }

    func testExactCMTimeRejectsRoundedAndEpochValues() throws {
        XCTAssertEqual(
            try ASHExactCMTimeV4.convert(
                CMTime(value: 1_001, timescale: 30_000),
                path: "frame"
            ),
            try ExactRationalV4(1_001, 30_000)
        )
        XCTAssertThrowsError(
            try ASHExactCMTimeV4.convert(
                CMTime(
                    value: 1,
                    timescale: 2,
                    flags: [.valid],
                    epoch: 7
                ),
                path: "epoch"
            )
        )
        XCTAssertThrowsError(
            try ASHExactCMTimeV4.convert(
                CMTime(
                    value: 1,
                    timescale: 2,
                    flags: [.valid, .hasBeenRounded],
                    epoch: 0
                ),
                path: "rounded"
            )
        )
    }

    func testCanonicalPropertyIdentityIgnoresDictionaryInsertionOrder()
        throws {
        let first: NSDictionary = [
            "z": Data([0, 1, 2, 3]),
            "a": [NSNumber(value: 3), NSNumber(value: 0.5)]
        ]
        let second = NSMutableDictionary()
        second["a"] = [NSNumber(value: 3), NSNumber(value: 0.5)]
        second["z"] = Data([0, 1, 2, 3])
        XCTAssertEqual(
            try ASHCanonicalPropertyListV4.data(first, path: "first"),
            try ASHCanonicalPropertyListV4.data(second, path: "second")
        )
        second["z"] = Data([0, 1, 2, 4])
        XCTAssertNotEqual(
            try ASHCanonicalPropertyListV4.data(first, path: "first"),
            try ASHCanonicalPropertyListV4.data(second, path: "mutated")
        )
    }

    func testStreamingIdentityIsChunkInvariantAndDetectsMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("identity.bin")
        let bytes = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: url)

        let bytewise = try ASHStreamingFileIdentityV4.read(
            url: url,
            chunkByteCount: 1
        )
        let blocked = try ASHStreamingFileIdentityV4.read(
            url: url,
            chunkByteCount: 4_093
        )
        XCTAssertEqual(bytewise, blocked)
        XCTAssertEqual(bytewise.contentSHA256, ASHSHA256V4(rawData: bytes))
        XCTAssertEqual(bytewise.byteCount, Int64(bytes.count))

        try Data([0xff]).append(to: url)
        XCTAssertThrowsError(try blocked.verifyUnchanged(url: url))
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
