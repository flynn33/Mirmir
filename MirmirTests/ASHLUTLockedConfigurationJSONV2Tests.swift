import CryptoKit
import XCTest
@testable import Mirmir

final class ASHLUTLockedConfigurationJSONV2Tests: XCTestCase {
    func testSharedLockedInputLoadsAndMatchesIndependentFrozenOutputs() throws {
        let data = try ASHLUTTestSupportV2.sharedLockedInputData()
        XCTAssertEqual(
            hex(SHA256.hash(data: data)),
            "ba5438b47365c92175a6601aa757138648251004f0e4ddeba13969fdaa0428bb"
        )
        let canonical = try ASHLUTLockedConfigurationJSONLoaderV2.canonicalHashInput(data)
        XCTAssertEqual(
            hex(SHA256.hash(data: canonical)),
            "77b5ae88de2735626df508f41777662d71529a65d864b17c6dbc009d23890851"
        )

        let configuration = try ASHLUTLockedConfigurationJSONLoaderV2.load(data)
        XCTAssertEqual(configuration.configurationID, "p06-reference-fixture-001")
        XCTAssertEqual(
            configuration.compilerInputsSHA256.hex,
            "77b5ae88de2735626df508f41777662d71529a65d864b17c6dbc009d23890851"
        )
        XCTAssertEqual(configuration.boundaryMode, .mirrorReflect101)
        XCTAssertEqual(configuration.compilerPolicy.penaltyDecayDenominator, 16)
        XCTAssertEqual(configuration.compilerPolicy.confidenceThresholdUNorm16, 16_384)
        XCTAssertEqual(configuration.compilerPolicy.penaltyToWeight.count, 256)
        XCTAssertEqual(
            configuration.compilerPolicy.penaltyToWeight,
            ASHLUTTestSupportV2.exactPenaltyTable(denominator: 16)
        )
        XCTAssertEqual(
            configuration.routeSelection(for: .direct2x).lumaCoordinatePolicy,
            .sourceAlignedRational
        )
        XCTAssertEqual(
            configuration.routeSelection(for: .direct2x).chromaCoordinatePolicy,
            .halfPixelCenter
        )
        XCTAssertEqual(configuration.routeSelection(for: .direct2x).analysisGridSourceStep, 1)
        XCTAssertEqual(
            configuration.routeSelection(for: .direct3Over2).lumaCoordinatePolicy,
            .halfPixelCenter
        )
        XCTAssertEqual(
            configuration.routeSelection(for: .direct3Over2).chromaCoordinatePolicy,
            .sourceAlignedRational
        )
        XCTAssertEqual(configuration.routeSelection(for: .direct3Over2).analysisGridSourceStep, 2)

        let direct2x = try ASHLUTTestSupportV2.mixedDirect2x().artifact
        XCTAssertEqual(direct2x.data.count, 99_904)
        XCTAssertEqual(direct2x.parameterCount, 20)
        XCTAssertEqual(
            direct2x.payloadSHA256.hex,
            "029a3a1d97a187ba81a4229d6b6a20265a1114f06b65d421c840686d3a7a6636"
        )
        XCTAssertEqual(
            direct2x.wholeFileSHA256.hex,
            "0a129a035eb83bda6849eab344e8f496a21051e16920afae38989b82b1d90c2b"
        )

        let direct3Over2 = try ASHLUTTestSupportV2.mixedDirect3Over2().artifact
        XCTAssertEqual(direct3Over2.data.count, 222_784)
        XCTAssertEqual(direct3Over2.parameterCount, 20)
        XCTAssertEqual(
            direct3Over2.payloadSHA256.hex,
            "578947a902079fe75d78851a2e8778c96a7950ebd1c00218b166658975af2763"
        )
        XCTAssertEqual(
            direct3Over2.wholeFileSHA256.hex,
            "6dd4e01e8ba2a7beec3ddf106f24af7a1aa79ef795c5986f8c93133166e7aa26"
        )
    }

    func testSwiftBytesMatchFrozenIndependentPythonOracleEvidence() throws {
        let repository = repositoryURL
        let fixture = repository.appendingPathComponent(
            "validation/calibration_v2/fixtures/locked-compiler-input-shared-v1.json"
        )
        let compiler = repository.appendingPathComponent(
            "validation/calibration_v2/tools/compile_reference_luts.py"
        )
        let oracle = repository.appendingPathComponent(
            "validation/calibration_v2/reference/lut_oracle.py"
        )
        XCTAssertEqual(
            hex(SHA256.hash(data: try Data(contentsOf: fixture))),
            "ba5438b47365c92175a6601aa757138648251004f0e4ddeba13969fdaa0428bb"
        )
        XCTAssertEqual(
            hex(SHA256.hash(data: try Data(contentsOf: compiler))),
            "35aae92379969411779748150ead94e595a1873a269fcd437dd3df5974f3088a"
        )
        XCTAssertEqual(
            hex(SHA256.hash(data: try Data(contentsOf: oracle))),
            "72b6ff321c6fe79a708a8d3775b6ba2c569825ff3c33f87026d47f72d7ceba64"
        )

        let direct2x = try ASHLUTTestSupportV2.mixedDirect2x().artifact.data
        XCTAssertEqual(direct2x.count, 99_904)
        XCTAssertEqual(
            hex(SHA256.hash(data: direct2x)),
            "0a129a035eb83bda6849eab344e8f496a21051e16920afae38989b82b1d90c2b"
        )

        let direct3Over2 = try ASHLUTTestSupportV2.mixedDirect3Over2().artifact.data
        XCTAssertEqual(direct3Over2.count, 222_784)
        XCTAssertEqual(
            hex(SHA256.hash(data: direct3Over2)),
            "6dd4e01e8ba2a7beec3ddf106f24af7a1aa79ef795c5986f8c93133166e7aa26"
        )
    }

    func testLockedInputRejectsSyntaxFieldsDuplicatesPlaceholdersAndSelfHashMutation() throws {
        let original = try ASHLUTTestSupportV2.sharedLockedInputData()
        let text = try XCTUnwrap(String(data: original, encoding: .utf8))

        var unknown = text
        unknown.replaceFirst("{\n", with: "{\n  \"unexpected\": 0,\n")
        assertRejected(Data(unknown.utf8), expected: .fieldSetMismatch)

        var missing = text
        missing.replaceFirst(",\n  \"top_two\": 2\n}", with: "\n}")
        assertRejected(Data(missing.utf8), expected: .fieldSetMismatch)

        var duplicate = text
        duplicate.replaceFirst("{\n", with: "{\n  \"status\": \"locked\",\n")
        assertRejected(Data(duplicate.utf8), expected: .duplicateKey)

        var escapedDuplicate = text
        escapedDuplicate.replaceFirst(
            "{\n",
            with: "{\n  \"\\u0073tatus\": \"locked\",\n"
        )
        assertRejected(Data(escapedDuplicate.utf8), expected: .duplicateKey)

        var selfHash = text
        selfHash.replaceFirst(
            "77b5ae88de2735626df508f41777662d71529a65d864b17c6dbc009d23890851",
            with: "87b5ae88de2735626df508f41777662d71529a65d864b17c6dbc009d23890851"
        )
        assertRejected(Data(selfHash.utf8), expected: .selfHashMismatch)

        var placeholder = text
        placeholder.replaceFirst(
            String(repeating: "1", count: 64),
            with: "<mapping_sha256>"
        )
        assertRejected(Data(placeholder.utf8), expected: .selfHashMismatch)

        var decimal = text
        decimal.replaceFirst("\"top_two\": 2", with: "\"top_two\": 2.0")
        assertRejected(Data(decimal.utf8), expected: .invalidValue)

        var wrongStatus = text
        wrongStatus.replaceFirst("\"status\": \"locked\"", with: "\"status\": \"draft\"")
        assertRejected(Data(wrongStatus.utf8), expected: .invalidValue)

        assertRejected(Data([0xff]), expected: .invalidUTF8)
        assertRejected(Data("{\"status\":".utf8), expected: .invalidSyntax)
    }

    func testLockedInputRejectsRehashedPenaltyTableMutation() throws {
        let original = try ASHLUTTestSupportV2.sharedLockedInputData()
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        var policy = try XCTUnwrap(document["compiler_policy"] as? [String: Any])
        var table = try XCTUnwrap(policy["penalty_to_weight_unorm16"] as? [Int])
        table[127] -= 1
        policy["penalty_to_weight_unorm16"] = table
        document["compiler_policy"] = policy
        var hashes = try XCTUnwrap(document["hash_bindings"] as? [String: Any])
        hashes["compiler_inputs_sha256"] = String(repeating: "1", count: 64)
        document["hash_bindings"] = hashes
        var mutated = try JSONSerialization.data(withJSONObject: document)
        let canonical = try ASHLUTLockedConfigurationJSONLoaderV2.canonicalHashInput(mutated)
        hashes["compiler_inputs_sha256"] = hex(SHA256.hash(data: canonical))
        document["hash_bindings"] = hashes
        mutated = try JSONSerialization.data(withJSONObject: document)
        assertRejected(mutated, expected: .invalidValue)
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertRejected(
        _ data: Data,
        expected: ASHLUTLockedConfigurationJSONErrorV2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ASHLUTLockedConfigurationJSONLoaderV2.load(data),
            file: file,
            line: line
        ) {
            XCTAssertEqual(
                $0 as? ASHLUTLockedConfigurationJSONErrorV2,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func hex<H: Sequence>(_ digest: H) -> String where H.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    mutating func replaceFirst(_ target: String, with replacement: String) {
        guard let range = range(of: target) else { return }
        replaceSubrange(range, with: replacement)
    }
}
