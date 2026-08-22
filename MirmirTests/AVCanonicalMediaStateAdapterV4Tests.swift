import AVFoundation
import CoreMedia
import CryptoKit
import XCTest
@testable import Mirmir

final class AVCanonicalMediaStateAdapterV4Tests: XCTestCase {
    func testAmbientViewingEnvironmentDecodesAndSerializesExactly() throws {
        let metadata = try AmbientViewingEnvironmentV4(
            ambientIlluminance: 123_456,
            ambientLight: try HDRChromaticityV4(
                x: 15_635,
                y: 16_450,
                label: "ambient"
            )
        )
        let decoded = try AVCanonicalAmbientViewingEnvironmentCodecV4.decode(
            metadata.payload,
            path: "fixture.color.ambient_viewing_environment"
        )
        XCTAssertEqual(
            decoded.ambientIlluminance,
            try ExactRationalV4(123_456, 10_000)
        )
        XCTAssertEqual(
            decoded.ambientLightX,
            try ExactRationalV4(15_635, 50_000)
        )
        XCTAssertEqual(
            decoded.ambientLightY,
            try ExactRationalV4(16_450, 50_000)
        )

        let color = CanonicalColorStateV4(
            primaries: "itu-r-bt2020",
            transferFunction: "smpte-st-2084-pq",
            matrix: "itu-r-bt2020",
            masteringDisplay: nil,
            contentLightLevel: nil,
            ambientViewingEnvironment: decoded,
            dynamicHDRMetadata: []
        )
        let canonicalJSON = try ASHCanonicalJSONV4.encode(color)
        XCTAssertEqual(
            try ASHCanonicalJSONV4.decode(
                CanonicalColorStateV4.self,
                from: canonicalJSON
            ),
            color
        )
        XCTAssertTrue(
            String(decoding: canonicalJSON, as: UTF8.self)
                .contains("ambientViewingEnvironment")
        )
    }

    func testAmbientViewingEnvironmentDecodeFailsClosed() throws {
        XCTAssertThrowsError(
            try AVCanonicalAmbientViewingEnvironmentCodecV4.decode(
                Data(repeating: 0, count: 7),
                path: "fixture.color.ambient_viewing_environment"
            )
        ) { error in
            guard let adapterError =
                error as? AVCanonicalMediaStateAdapterV4Error,
                  case let .avFoundationLoadFailed(path, reason) =
                    adapterError else {
                return XCTFail("Expected contextual AVFoundation rejection")
            }
            XCTAssertEqual(
                path,
                "fixture.color.ambient_viewing_environment"
            )
            XCTAssertTrue(reason.contains("invalidPayloadLength"))
        }

        XCTAssertThrowsError(
            try AVCanonicalAmbientViewingEnvironmentCodecV4.decode(
                Data([0, 0, 0, 1, 0xC3, 0x50, 0, 1]),
                path: "fixture.color.ambient_viewing_environment"
            )
        )
    }

    func testAmbientViewingEnvironmentPresentWithWrongTypeFailsClosed() {
        let expectedPath =
            "fixture.format_descriptions[0].color.ambient_viewing_environment"

        XCTAssertThrowsError(
            try AVCanonicalAmbientViewingEnvironmentCodecV4
                .decodeExtensionValue(
                    "not-data",
                    path: expectedPath
                )
        ) { error in
            guard let adapterError =
                error as? AVCanonicalMediaStateAdapterV4Error,
                  case let .avFoundationLoadFailed(errorPath, reason) =
                    adapterError else {
                return XCTFail("Expected contextual AVFoundation rejection")
            }
            XCTAssertEqual(errorPath, expectedPath)
            XCTAssertTrue(reason.contains("must be CFData"))
        }

        XCTAssertNil(
            try AVCanonicalAmbientViewingEnvironmentCodecV4
                .decodeExtensionValue(nil, path: expectedPath)
        )
    }

    func testCanonicalScanDescriptionAdmitsDeclaredInterlacedCadence() throws {
        let topFirst: NSDictionary = [
            kCMFormatDescriptionExtension_FieldCount as String: 2,
            kCMFormatDescriptionExtension_FieldDetail as String:
                kCMFormatDescriptionFieldDetail_TemporalTopFirst
        ]
        let bottomFirst: NSDictionary = [
            kCMFormatDescriptionExtension_FieldCount as String: 2,
            kCMFormatDescriptionExtension_FieldDetail as String:
                kCMFormatDescriptionFieldDetail_TemporalBottomFirst
        ]

        XCTAssertEqual(
            try AVCanonicalScanDescriptionV4(
                extensions: topFirst
            ).state,
            CanonicalScanStateV4(
                fieldCount: 2,
                dominance: .topFieldFirst,
                cadence: .interlaced
            )
        )
        XCTAssertEqual(
            try AVCanonicalScanDescriptionV4(
                extensions: bottomFirst
            ).state,
            CanonicalScanStateV4(
                fieldCount: 2,
                dominance: .bottomFieldFirst,
                cadence: .interlaced
            )
        )
    }

    func testCanonicalScanDescriptionMapsSpatialFieldDetailsDeterministically()
        throws {
        let early: NSDictionary = [
            kCMFormatDescriptionExtension_FieldCount as String: 2,
            kCMFormatDescriptionExtension_FieldDetail as String:
                kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly
        ]
        let late: NSDictionary = [
            kCMFormatDescriptionExtension_FieldCount as String: 2,
            kCMFormatDescriptionExtension_FieldDetail as String:
                kCMFormatDescriptionFieldDetail_SpatialFirstLineLate
        ]

        XCTAssertEqual(
            try AVCanonicalScanDescriptionV4(extensions: early)
                .state.dominance,
            .topFieldFirst
        )
        XCTAssertEqual(
            try AVCanonicalScanDescriptionV4(extensions: late)
                .state.dominance,
            .bottomFieldFirst
        )
    }

    func testCanonicalScanDescriptionFailsClosedOnIncompleteDeclarations() {
        XCTAssertThrowsError(
            try AVCanonicalScanDescriptionV4(extensions: [:])
        ) { error in
            XCTAssertEqual(
                error as? AVCanonicalScanDescriptionV4Error,
                .invalidFieldCount(nil)
            )
        }
        XCTAssertThrowsError(
            try AVCanonicalScanDescriptionV4(extensions: [
                kCMFormatDescriptionExtension_FieldCount as String: 2
            ])
        ) { error in
            XCTAssertEqual(
                error as? AVCanonicalScanDescriptionV4Error,
                .unsupportedFieldDetail(nil)
            )
        }
        XCTAssertThrowsError(
            try AVCanonicalScanDescriptionV4(extensions: [
                kCMFormatDescriptionExtension_FieldCount as String: 1,
                kCMFormatDescriptionExtension_FieldDetail as String:
                    kCMFormatDescriptionFieldDetail_TemporalTopFirst
            ])
        )
    }

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
