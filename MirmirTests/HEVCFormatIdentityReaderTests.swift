import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class HEVCFormatIdentityReaderTests: XCTestCase {
    func testReadsMain422TenBitSequenceParameterSetIdentity() throws {
        let identity = try HEVCFormatIdentityReader.read(
            sequenceParameterSetNALUnit: makeSPS(
                chromaFormatIDC: 2,
                lumaBitDepthMinus8: 2,
                chromaBitDepthMinus8: 2
            )
        )

        XCTAssertEqual(identity.chromaSampling, .yuv422)
        XCTAssertEqual(identity.lumaBitDepth, 10)
        XCTAssertEqual(identity.chromaBitDepth, 10)
    }

    func testReadsMain444TwelveBitSequenceParameterSetIdentity() throws {
        let identity = try HEVCFormatIdentityReader.read(
            sequenceParameterSetNALUnit: makeSPS(
                chromaFormatIDC: 3,
                lumaBitDepthMinus8: 4,
                chromaBitDepthMinus8: 4
            )
        )

        XCTAssertEqual(identity.chromaSampling, .yuv444)
        XCTAssertEqual(identity.lumaBitDepth, 12)
        XCTAssertEqual(identity.chromaBitDepth, 12)
    }

    func testRejectsNonSPSNALUnit() throws {
        var nalUnit = makeSPS(
            chromaFormatIDC: 2,
            lumaBitDepthMinus8: 2,
            chromaBitDepthMinus8: 2
        )
        nalUnit[0] = UInt8(32 << 1)

        XCTAssertThrowsError(
            try HEVCFormatIdentityReader.read(
                sequenceParameterSetNALUnit: nalUnit
            )
        ) { error in
            XCTAssertEqual(
                error as? HEVCFormatIdentityReaderError,
                .invalidNALUnit("NAL unit type is not SPS_NUT")
            )
        }
    }

    func testRejectsTruncatedSequenceParameterSet() throws {
        let nalUnit = Data([UInt8(33 << 1), 0x01, 0x00])

        XCTAssertThrowsError(
            try HEVCFormatIdentityReader.read(
                sequenceParameterSetNALUnit: nalUnit
            )
        ) { error in
            XCTAssertEqual(
                error as? HEVCFormatIdentityReaderError,
                .truncatedSequenceParameterSet
            )
        }
    }

    func testRejectsMalformedEmulationPreventionByte() throws {
        let nalUnit = Data([
            UInt8(33 << 1), 0x01,
            0x00, 0x00, 0x03, 0x04
        ])

        XCTAssertThrowsError(
            try HEVCFormatIdentityReader.read(
                sequenceParameterSetNALUnit: nalUnit
            )
        ) { error in
            XCTAssertEqual(
                error as? HEVCFormatIdentityReaderError,
                .invalidNALUnit(
                    "malformed emulation-prevention byte"
                )
            )
        }
    }
}

private func makeSPS(
    chromaFormatIDC: UInt64,
    lumaBitDepthMinus8: UInt64,
    chromaBitDepthMinus8: UInt64
) -> Data {
    var bits = TestHEVCBitWriter()
    bits.append(value: 0, count: 4)
    bits.append(value: 0, count: 3)
    bits.append(value: 1, count: 1)
    bits.append(value: 0, count: 2 + 1 + 5)
    bits.append(value: 0, count: 32)
    bits.append(value: 0, count: 48)
    bits.append(value: 120, count: 8)
    bits.appendUnsignedExpGolomb(0)
    bits.appendUnsignedExpGolomb(chromaFormatIDC)
    if chromaFormatIDC == 3 {
        bits.append(value: 0, count: 1)
    }
    bits.appendUnsignedExpGolomb(64)
    bits.appendUnsignedExpGolomb(64)
    bits.append(value: 0, count: 1)
    bits.appendUnsignedExpGolomb(lumaBitDepthMinus8)
    bits.appendUnsignedExpGolomb(chromaBitDepthMinus8)
    bits.append(value: 1, count: 1)
    bits.padToByteBoundary()
    return Data([UInt8(33 << 1), 0x01]) + bits.data
}

private struct TestHEVCBitWriter {
    private var bits: [UInt8] = []

    var data: Data {
        var result = Data()
        for start in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for offset in 0..<8 where start + offset < bits.count {
                byte |= bits[start + offset] << UInt8(7 - offset)
            }
            result.append(byte)
        }
        return result
    }

    mutating func append(value: UInt64, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            bits.append(UInt8((value >> UInt64(shift)) & 1))
        }
    }

    mutating func appendUnsignedExpGolomb(_ value: UInt64) {
        let codeNumber = value + 1
        let width = 64 - codeNumber.leadingZeroBitCount
        if width > 1 {
            bits.append(contentsOf: repeatElement(0, count: width - 1))
        }
        append(value: codeNumber, count: width)
    }

    mutating func padToByteBoundary() {
        while !bits.count.isMultiple(of: 8) {
            bits.append(0)
        }
    }
}
