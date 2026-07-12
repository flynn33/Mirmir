import CryptoKit
import XCTest
@testable import Mirmir

final class ASHLUTLockedConfigurationJSONV2Tests: XCTestCase {
    func testSharedLockedInputLoadsAndMatchesIndependentFrozenOutputs() throws {
        let data = try ASHLUTTestSupportV2.sharedLockedInputData()
        XCTAssertEqual(
            hex(SHA256.hash(data: data)),
            "75293d2c18998df82131305fa33e4805f555246632137c3f7ae393a7d700ee7f"
        )
        let canonical = try ASHLUTLockedConfigurationJSONLoaderV2.canonicalHashInput(data)
        XCTAssertEqual(
            hex(SHA256.hash(data: canonical)),
            "63fd1b11387d72e9209e6d833233512b5ddc34315865edfdd30696001de41f9f"
        )

        let configuration = try ASHLUTLockedConfigurationJSONLoaderV2.load(data)
        XCTAssertEqual(configuration.configurationID, "p06-reference-fixture-001")
        XCTAssertEqual(
            configuration.compilerInputsSHA256.hex,
            "63fd1b11387d72e9209e6d833233512b5ddc34315865edfdd30696001de41f9f"
        )
        XCTAssertEqual(configuration.boundaryMode, .mirrorReflect101)
        XCTAssertEqual(configuration.compilerPolicy.penaltyDecayDenominator, 16)
        XCTAssertEqual(configuration.compilerPolicy.confidenceThresholdUNorm16, 16_384)
        XCTAssertEqual(configuration.compilerPolicy.penaltyToWeight.count, 256)
        XCTAssertEqual(
            configuration.compilerPolicy.penaltyToWeight,
            ASHLUTTestSupportV2.exactPenaltyTable(denominator: 16)
        )
        XCTAssertEqual(configuration.routeSelection(for: .direct2x).coordinatePolicy, .sourceAlignedRational)
        XCTAssertEqual(configuration.routeSelection(for: .direct2x).analysisGridSourceStep, 1)
        XCTAssertEqual(configuration.routeSelection(for: .direct3Over2).coordinatePolicy, .halfPixelCenter)
        XCTAssertEqual(configuration.routeSelection(for: .direct3Over2).analysisGridSourceStep, 2)

        let direct2x = try ASHLUTTestSupportV2.sourceDirect2x().artifact
        XCTAssertEqual(direct2x.data.count, 99_968)
        XCTAssertEqual(direct2x.parameterCount, 21)
        XCTAssertEqual(
            direct2x.payloadSHA256.hex,
            "fece24272e5718c2bb22351556a62bb870d0dc9f30a6d0823581607f7603d3b4"
        )
        XCTAssertEqual(
            direct2x.wholeFileSHA256.hex,
            "4ec42ac66f0aa6e34ea65e19ea4f1573c6bbb4d603c954f090c237e84ddc2653"
        )

        let direct3Over2 = try ASHLUTTestSupportV2.halfPixelDirect3Over2().artifact
        XCTAssertEqual(direct3Over2.data.count, 222_784)
        XCTAssertEqual(direct3Over2.parameterCount, 20)
        XCTAssertEqual(
            direct3Over2.payloadSHA256.hex,
            "25130666370718490f4ca66d7cf4ebb6a052c33059c6ad7dd89362db77c350c1"
        )
        XCTAssertEqual(
            direct3Over2.wholeFileSHA256.hex,
            "43a88d21833076ba4d436204689cc98b3d846d1eb40ae4d2018ab485a81c926e"
        )
    }

    func testSwiftBytesEqualIndependentPythonOracleBytes() throws {
        let repository = repositoryURL
        let fixture = repository.appendingPathComponent(
            "validation/calibration_v2/fixtures/locked-compiler-input-shared-v1.json"
        )
        let compiler = repository.appendingPathComponent(
            "validation/calibration_v2/tools/compile_reference_luts.py"
        )
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-p06-oracle-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [compiler.path, fixture.path, output.path]
        process.currentDirectoryURL = repository
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8) ?? "<non-UTF8 stderr>"
        XCTAssertEqual(process.terminationStatus, 0, errorText)
        guard process.terminationStatus == 0 else { return }

        let pythonDirect2x = try Data(contentsOf: output.appendingPathComponent("direct2x.ashlut"))
        let pythonDirect3Over2 = try Data(
            contentsOf: output.appendingPathComponent("direct3over2.ashlut")
        )
        XCTAssertEqual(
            pythonDirect2x,
            try ASHLUTTestSupportV2.sourceDirect2x().artifact.data
        )
        XCTAssertEqual(
            pythonDirect3Over2,
            try ASHLUTTestSupportV2.halfPixelDirect3Over2().artifact.data
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
            "63fd1b11387d72e9209e6d833233512b5ddc34315865edfdd30696001de41f9f",
            with: "73fd1b11387d72e9209e6d833233512b5ddc34315865edfdd30696001de41f9f"
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
