import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

final class ASHCoreConformanceTests: XCTestCase {
    func test_productionVectorsMatchIndependentLockedFixtureByteForByteAndBySHA256() throws {
        let fixtureURL = generatedFixtureRoot().appendingPathComponent("ash-core-v1.bin")
        let hashURL = generatedFixtureRoot().appendingPathComponent("ash-core-v1.sha256")
        let lockedFixture = try Data(contentsOf: fixtureURL)
        let productionFixture = try ASHCoreConformanceBinary.generate(validatingContractAt: contractURL())
        let hashFields = try String(contentsOf: hashURL, encoding: .ascii)
            .split(whereSeparator: \.isWhitespace)

        XCTAssertNil(Bundle.main.url(forResource: "ash-core-v1.contract", withExtension: "json"))
        XCTAssertEqual(hashFields.count, 2)
        XCTAssertEqual(hashFields.last.map(String.init), fixtureURL.lastPathComponent)
        XCTAssertEqual(lockedFixture.count, Int(ASHCoreConformanceBinary.fileSize))

        guard productionFixture == lockedFixture else {
            XCTFail(
                "Production and independent fixtures first differ at byte "
                    + "\(firstDifferingOffset(productionFixture, lockedFixture))."
            )
            return
        }

        let expectedHash = try XCTUnwrap(hashFields.first.map(String.init))
        XCTAssertEqual(sha256Hex(productionFixture), expectedHash)
        XCTAssertEqual(sha256Hex(lockedFixture), expectedHash)
    }

    func test_sharedCanonicalContractRejectsGeneratorRowAndDecoderRadiusMutations() throws {
        let sourceData = try Data(contentsOf: contractURL())

        var generatorRoot = try contractObject(from: sourceData)
        var generatorCore = try XCTUnwrap(generatorRoot["core"] as? [String: Any])
        var generatorRows = try XCTUnwrap(generatorCore["generator_rows"] as? [String])
        generatorRows[0] = "011100000"
        generatorCore["generator_rows"] = generatorRows
        generatorRoot["core"] = generatorCore
        assertContractMismatch(
            try JSONSerialization.data(withJSONObject: generatorRoot, options: [.sortedKeys]),
            field: "core.generator_rows"
        )

        var radiusRoot = try contractObject(from: sourceData)
        var radiusBinary = try XCTUnwrap(radiusRoot["binary"] as? [String: Any])
        radiusBinary["decoder_radius"] = 2
        radiusRoot["binary"] = radiusBinary
        assertContractMismatch(
            try JSONSerialization.data(withJSONObject: radiusRoot, options: [.sortedKeys]),
            field: "binary.decoder_radius"
        )
    }

    func test_exhaustiveProductionStateAndCodewordSemantics() throws {
        var validAnchors: [ASHState] = []
        var invalidStateCount = 0
        for raw in UInt16(0)..<UInt16(ASHCoreConformanceBinary.rawStateCount) {
            let state = try ASHState(rawValue: raw)
            let payloadParity = Int((raw >> 1).nonzeroBitCount & 1)
            let coordinateNine = Int(raw & 1)
            let expectedValidity = coordinateNine == payloadParity
            guard state.hasValidIntegrity == expectedValidity else {
                XCTFail("Parity classification mismatch for raw state \(raw).")
                return
            }
            if expectedValidity {
                validAnchors.append(state)
            } else {
                invalidStateCount += 1
            }
        }
        XCTAssertEqual(validAnchors.count, Int(ASHCoreConformanceBinary.validAnchorCount))
        XCTAssertEqual(invalidStateCount, 256)
        XCTAssertThrowsError(try ASHState(rawValue: 0x0200))

        let expectedCodewords: [UInt16] = [
            0b000000000,
            0b100110001,
            0b101010100,
            0b001100101,
            0b110011000,
            0b010101001,
            0b011001100,
            0b111111101,
            0b111100000,
            0b011010001,
            0b010110100,
            0b110000101,
            0b001111000,
            0b101001001,
            0b100101100,
            0b000011101
        ]
        var observedCodewords: Set<ASHState> = []
        for rawMessage in UInt8(0)..<UInt8(ASHCoreConformanceBinary.codewordCount) {
            let message = try ASHMessage(rawValue: rawMessage)
            let codeword = ASHCode.encode(message)
            guard codeword.rawValue == expectedCodewords[Int(rawMessage)] else {
                XCTFail("Codeword mismatch for message \(rawMessage).")
                return
            }
            guard codeword.hasValidIntegrity else {
                XCTFail("Codeword violates coordinate-9 parity for message \(rawMessage).")
                return
            }
            observedCodewords.insert(codeword)
        }
        XCTAssertEqual(observedCodewords.count, Int(ASHCoreConformanceBinary.codewordCount))
    }

    func test_exhaustiveProductionAffineSemantics() throws {
        let validAnchors = (UInt16(0)..<UInt16(ASHCoreConformanceBinary.rawStateCount))
            .map(ASHState.init(validatedRawValue:))
            .filter(\.hasValidIntegrity)
        XCTAssertEqual(validAnchors.count, Int(ASHCoreConformanceBinary.validAnchorCount))

        var exactCount = 0
        var oneBitCount = 0
        var twoBitCount = 0
        for anchor in validAnchors {
            for rawMessage in UInt8(0)..<UInt8(ASHCoreConformanceBinary.codewordCount) {
                let message = try ASHMessage(rawValue: rawMessage)
                let codeword = ASHCode.encode(message)
                let transmitted = anchor.xor(codeword)

                let exact = ASHCode.decodeAffine(received: transmitted, anchor: anchor)
                guard exact.status == .exact,
                      exact.codeword == transmitted,
                      exact.messageBits == message.bits,
                      exact.distance == 0,
                      exact.nearestCount == 1 else {
                    XCTFail("Exact affine recovery mismatch for anchor \(anchor), message \(rawMessage).")
                    return
                }
                exactCount += 1

                for coordinate in 1...ASHState.bitCount {
                    let received = transmitted.toggled(coordinate: coordinate)
                    let corrected = ASHCode.decodeAffine(received: received, anchor: anchor)
                    guard corrected.status == .corrected,
                          corrected.codeword == transmitted,
                          corrected.messageBits == message.bits,
                          corrected.distance == 1,
                          corrected.nearestCount == 1 else {
                        XCTFail(
                            "One-bit affine recovery mismatch for anchor \(anchor), "
                                + "message \(rawMessage), coordinate \(coordinate)."
                        )
                        return
                    }
                    oneBitCount += 1
                }

                for firstCoordinate in 1..<ASHState.bitCount {
                    for secondCoordinate in (firstCoordinate + 1)...ASHState.bitCount {
                        let received = transmitted
                            .toggled(coordinate: firstCoordinate)
                            .toggled(coordinate: secondCoordinate)
                        let rejected = ASHCode.decodeAffine(received: received, anchor: anchor)
                        guard rejected.status == .uncorrectable,
                              rejected.codeword == nil,
                              rejected.messageBits == nil,
                              rejected.distance == 2,
                              rejected.nearestCount == 1 || rejected.nearestCount == 4 else {
                            XCTFail(
                                "Two-bit rejection mismatch for anchor \(anchor), message "
                                    + "\(rawMessage), coordinates \(firstCoordinate),\(secondCoordinate)."
                            )
                            return
                        }
                        twoBitCount += 1
                    }
                }
            }
        }

        XCTAssertEqual(exactCount, Int(ASHCoreConformanceBinary.exactAffineRecordCount))
        XCTAssertEqual(oneBitCount, Int(ASHCoreConformanceBinary.oneBitAffineRecordCount))
        XCTAssertEqual(twoBitCount, Int(ASHCoreConformanceBinary.twoBitAffineRecordCount))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contractURL() -> URL {
        repositoryRoot().appendingPathComponent("validation/reference/ash-core-v1.contract.json")
    }

    private func generatedFixtureRoot() -> URL {
        repositoryRoot()
            .appendingPathComponent("validation/reference/generated", isDirectory: true)
    }

    private func contractObject(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertContractMismatch(_ data: Data, field: String) {
        XCTAssertThrowsError(try ASHCoreConformanceBinary.generate(validatingContractData: data)) { error in
            guard let contractError = error as? ASHCoreConformanceContractError else {
                return XCTFail("Unexpected contract error: \(error)")
            }
            guard case .mismatch(let actualField, _, _) = contractError else {
                return XCTFail("Expected a contract mismatch, received \(contractError).")
            }
            XCTAssertEqual(actualField, field)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func firstDifferingOffset(_ left: Data, _ right: Data) -> Int {
        let commonCount = min(left.count, right.count)
        for index in 0..<commonCount where left[index] != right[index] {
            return index
        }
        return commonCount
    }
}
