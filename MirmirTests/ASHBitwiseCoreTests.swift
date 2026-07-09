import XCTest
@testable import Mirmir

final class ASHBitwiseCoreTests: XCTestCase {

    func test_stateSerializesCoordinateOneAsMostSignificantBitAndCoordinateNineAsLeastSignificantBit() throws {
        let state = try ASHState(payloadBits: [1, 0, 1, 0, 1, 0, 1, 0])

        XCTAssertEqual(state.bits, [1, 0, 1, 0, 1, 0, 1, 0, 0])
        XCTAssertEqual(state.rawValue, 0b101010100)
        XCTAssertEqual(state.bit(coordinate: 1), 1)
        XCTAssertEqual(state.bit(coordinate: 9), 0)
        XCTAssertTrue(state.hasValidIntegrity)
    }

    func test_generatorRowsMatchCanonicalCodewords() throws {
        let rows = ASHCode.generatorRows.map(\.bits)

        XCTAssertEqual(rows, [
            [1, 1, 1, 1, 0, 0, 0, 0, 0],
            [1, 1, 0, 0, 1, 1, 0, 0, 0],
            [1, 0, 1, 0, 1, 0, 1, 0, 0],
            [1, 0, 0, 1, 1, 0, 0, 0, 1]
        ])
        XCTAssertEqual(ASHCode.codewords.count, 16)
        XCTAssertEqual(Set(ASHCode.codewords).count, 16)
        XCTAssertTrue(ASHCode.codewords.allSatisfy(\.hasValidIntegrity))
    }

    func test_strictDecoderCorrectsOneBitAndRejectsDistanceTwo() throws {
        let codeword = try ASHCode.encode(messageBits: [1, 0, 1, 1])

        let exact = ASHCode.decode(codeword)
        XCTAssertEqual(exact.status, .exact)
        XCTAssertEqual(exact.codeword, codeword)
        XCTAssertEqual(exact.messageBits, [1, 0, 1, 1])

        let oneBit = codeword.toggled(coordinate: 4)
        let corrected = ASHCode.decode(oneBit)
        XCTAssertEqual(corrected.status, .corrected)
        XCTAssertEqual(corrected.codeword, codeword)
        XCTAssertEqual(corrected.distance, 1)

        let twoBits = oneBit.toggled(coordinate: 8)
        let rejected = ASHCode.decode(twoBits)
        XCTAssertEqual(rejected.status, .uncorrectable)
        XCTAssertNil(rejected.codeword)
        XCTAssertNil(rejected.messageBits)
        XCTAssertEqual(rejected.distance, 2)
    }
}
