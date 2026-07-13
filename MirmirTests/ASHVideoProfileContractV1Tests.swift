import CryptoKit
import XCTest
@testable import Mirmir

final class ASHVideoProfileContractV1Tests: XCTestCase {
    func test_lockedContractLoadsWithExactHashAndTwelveCanonicalInstances() throws {
        let data = try contractData()
        let expected = try ASHLUTHashV2(
            hex: "8c61d53cab158838e559b81a1d0c6b65ecc734a61ade76f84d41c92187214ef3"
        )
        let contract = try ASHVideoProfileContractV1.load(data, expectedSHA256: expected)

        XCTAssertEqual(contract.sha256, expected)
        XCTAssertEqual(contract.immutableBytes, data)
        XCTAssertEqual(contract.canonicalInstances.count, 12)
        XCTAssertEqual(
            contract.canonicalInstances.map { "\($0.pixelFormat.rawValue)/\($0.chromaSiting.rawValue)" },
            [
                "420f/bottom", "420f/bottom_left", "420f/center", "420f/left",
                "420f/top", "420f/top_left", "420v/bottom", "420v/bottom_left",
                "420v/center", "420v/left", "420v/top", "420v/top_left"
            ]
        )
        XCTAssertEqual(
            contract.instanceMatrixSHA256.hex,
            "ccac6db74c9f47438741fc3bd5fd12daf127b1a5bd8debf89455d350cfc0217c"
        )
        XCTAssertEqual(Set(contract.canonicalInstances.map(\.sha256)).count, 12)
    }

    func test_everyDeclaredInstanceRoundTripsThroughStrictObservationValidation() throws {
        let contract = try loadContract()
        for expected in contract.canonicalInstances {
            let observed = try contract.validate(observation(
                pixelFormat: expected.pixelFormat.rawValue,
                range: expected.range.rawValue,
                chromaSiting: expected.chromaSiting.rawValue
            ))
            XCTAssertEqual(observed, expected)
            XCTAssertEqual(observed.canonicalBytes, expected.canonicalBytes)
            XCTAssertEqual(observed.sha256, expected.sha256)
        }
    }

    func test_invalidPixelFormatRangeCrossProductIsRejectedExactly() throws {
        let contract = try loadContract()
        XCTAssertThrowsError(try contract.validate(observation(pixelFormat: "420v", range: "full"))) {
            XCTAssertEqual(
                $0 as? ASHVideoProfileContractV1Error,
                .invalidPixelFormatRangePair(pixelFormat: "420v", range: "full")
            )
        }
        XCTAssertThrowsError(try contract.validate(observation(pixelFormat: "420f", range: "video"))) {
            XCTAssertEqual(
                $0 as? ASHVideoProfileContractV1Error,
                .invalidPixelFormatRangePair(pixelFormat: "420f", range: "video")
            )
        }
    }

    func test_missingAndNonRec709ColorMetadataHaveStableTypedErrors() throws {
        let contract = try loadContract()
        XCTAssertThrowsError(try contract.validate(observation(colorPrimaries: nil))) {
            let error = $0 as? ASHVideoProfileContractV1Error
            XCTAssertEqual(error, .missingColorMetadata(.colorPrimaries))
            XCTAssertEqual(error?.machineCode, "missing_color_primaries")
        }
        XCTAssertThrowsError(try contract.validate(observation(transferFunction: "SMPTE_ST_2084_PQ"))) {
            let error = $0 as? ASHVideoProfileContractV1Error
            XCTAssertEqual(
                error,
                .nonRec709ColorMetadata(
                    field: .transferFunction,
                    observed: "SMPTE_ST_2084_PQ"
                )
            )
            XCTAssertEqual(error?.machineCode, "non_rec709_transfer_function")
        }
        XCTAssertThrowsError(try contract.validate(observation(yCbCrMatrix: "ITU_R_2020"))) {
            XCTAssertEqual(
                $0 as? ASHVideoProfileContractV1Error,
                .nonRec709ColorMetadata(field: .yCbCrMatrix, observed: "ITU_R_2020")
            )
        }
    }

    func testProgressiveGeometryAndSamplingFieldsAreMandatoryAndExact() throws {
        let contract = try loadContract()
        let cases: [(ASHVideoProfileObservationV1, ASHVideoProfileContractV1Error)] = [
            (observation(scanType: nil), .missingScanMetadata),
            (observation(scanType: "interlaced"), .interlacedInput),
            (observation(scanType: "unknown"), .unsupportedScanType("unknown")),
            (observation(bitDepth: nil), .missingBitDepth),
            (observation(bitDepth: 10), .unsupportedBitDepth(10)),
            (observation(subsampling: nil), .missingSubsampling),
            (observation(subsampling: "4:2:2"), .unsupportedSubsampling("4:2:2")),
            (observation(chromaSiting: nil), .missingChromaSiting),
            (observation(chromaSiting: "dv_420"), .unsupportedChromaSiting("dv_420"))
        ]
        for (input, expected) in cases {
            XCTAssertThrowsError(try contract.validate(input)) {
                XCTAssertEqual($0 as? ASHVideoProfileContractV1Error, expected)
            }
        }
    }

    func testContractRejectsHashMismatchNoncanonicalBytesAndSemanticMutation() throws {
        let data = try contractData()
        let wrongHash = try ASHLUTHashV2(hex: String(repeating: "ab", count: 32))
        XCTAssertThrowsError(try ASHVideoProfileContractV1.load(data, expectedSHA256: wrongHash)) {
            XCTAssertEqual($0 as? ASHVideoProfileContractV1Error, .hashMismatch)
        }

        var noncanonical = data
        noncanonical.append(0x20)
        XCTAssertThrowsError(try ASHVideoProfileContractV1.load(noncanonical)) {
            XCTAssertEqual($0 as? ASHVideoProfileContractV1Error, .nonCanonicalEncoding)
        }

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let mutated = Data(
            text.replacingOccurrences(of: "ITU_R_709_2", with: "ITU_R_2020").utf8
        )
        XCTAssertThrowsError(try ASHVideoProfileContractV1.load(mutated)) {
            XCTAssertEqual($0 as? ASHVideoProfileContractV1Error, .invalidContract)
        }
    }

    private func loadContract() throws -> ASHVideoProfileContractV1 {
        try ASHVideoProfileContractV1.load(try contractData())
    }

    private func contractData() throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "validation/calibration_v2/contracts/video-profile-contract-v1.json"
        ))
    }

    private func observation(
        pixelFormat: String? = "420v",
        range: String? = "video",
        colorPrimaries: String? = "ITU_R_709_2",
        transferFunction: String? = "ITU_R_709_2",
        yCbCrMatrix: String? = "ITU_R_709_2",
        scanType: String? = "progressive",
        bitDepth: Int? = 8,
        subsampling: String? = "4:2:0",
        chromaSiting: String? = "left"
    ) -> ASHVideoProfileObservationV1 {
        ASHVideoProfileObservationV1(
            pixelFormat: pixelFormat,
            range: range,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            scanType: scanType,
            bitDepth: bitDepth,
            subsampling: subsampling,
            chromaSiting: chromaSiting
        )
    }
}
