import Foundation
@testable import Mirmir

private enum ASHV4SemanticSelfTestError: Error {
    case assertion(String)
    case childFailed(Int32, String)
}

@main
private enum ASHV4SemanticSelfTestMain {
    static func main() {
        do {
            if CommandLine.arguments.dropFirst() == ["--plan-hash"] {
                print(try producePlanHash())
                return
            }
            try run()
            print("ASH v4 semantic/artifact self-test: PASS")
        } catch {
            FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let root = try makeTemporaryDirectory(label: "parent")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first")
        let secondURL = root.appendingPathComponent("second")
        let first = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: firstURL)
        let second = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: secondURL)
        try require(
            first.manifestSHA256 == second.manifestSHA256,
            "manifest identity changed between builds"
        )
        let firstFiles = try ASHV4SemanticArtifactTestSupport.bundleFiles(
            at: firstURL
        )
        let secondFiles = try ASHV4SemanticArtifactTestSupport.bundleFiles(
            at: secondURL
        )
        try require(
            firstFiles == secondFiles,
            "bundle bytes changed between builds"
        )
        try require(
            try first.benchmarkCorpusIdentity().routes.count == 4,
            "benchmark corpus contract is not canonical"
        )
        try require(
            try first.qualityCorpusIdentity().caseCount == 40,
            "quality corpus contract is not canonical"
        )
        try require(
            try first.metricContract().minimumQualityIndex == 105,
            "quality metric gate changed"
        )
        try require(
            try first.metricContract().maximumProcessingTimeRatio
                == ExactRationalV4(4, 5),
            "performance metric gate changed"
        )
        try require(
            try first.phaseCoefficientProcedure().kernelContractID
                == FixedPointCoefficientCompilerV4.procedureID,
            "fixed-point kernel contract changed"
        )
        try require(
            try first.verificationContract().cpuMetalByteIdentityRequired,
            "byte-parity verification is not mandatory"
        )
        try require(
            Set(try first.verificationContract().requiredRules.map(\.rawValue))
                == Set(ASHVerificationRuleV4.allCases.map(\.rawValue)),
            "runtime verification rules differ from the execution planner"
        )
        let localHash = try ASHV4SemanticArtifactTestSupport.planHash(runtime: first)
        let secondHash = try ASHV4SemanticArtifactTestSupport.planHash(runtime: second)
        try require(
            localHash == secondHash,
            "plan identity changed between local builds"
        )

        let childOne = try childPlanHash()
        let childTwo = try childPlanHash()
        try require(childOne == childTwo, "plan identity changed across processes")
        try require(childOne == localHash, "child plan identity differs from parent")
        print("plan_sha256=\(localHash)")
        try require(
            localHash == ASHV4SemanticArtifactTestSupport.expectedPlanSHA256,
            "plan identity differs from the locked fixture"
        )

        var incomplete = try ASHV4SemanticArtifactTestSupport.completeRequest()
        incomplete = ASHP06RuntimeBuildRequestV4(
            releaseStatus: incomplete.releaseStatus,
            provenance: incomplete.provenance,
            artifacts: incomplete.artifacts.filter { $0.role != .metricContract }
        )
        do {
            _ = try ASHP06RuntimeBundleBuilderV4.build(
                incomplete,
                at: root.appendingPathComponent("incomplete"),
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
            throw ASHV4SemanticSelfTestError.assertion(
                "incomplete bundle unexpectedly built"
            )
        } catch ASHP06RuntimeBundleV4Error.incompleteBuildInput {
            // Expected.
        }

        let typedTamperCases: [(
            ASHRuntimeArtifactRoleV4,
            String,
            String,
            ASHP06RuntimeBundleV4Error
        )] = [
            (
                .benchmarkCorpusIdentity,
                "\"measuredSampleCount\":10",
                "\"measuredSampleCount\":11",
                .benchmarkCorpusIdentityMismatch
            ),
            (
                .qualityCorpusIdentity,
                "\"caseCount\":40",
                "\"caseCount\":41",
                .qualityCorpusIdentityMismatch
            ),
            (
                .metricContract,
                "\"minimumQualityIndex\":105",
                "\"minimumQualityIndex\":104",
                .metricContractMismatch
            ),
            (
                .phaseCoefficientProcedure,
                "\"fractionalBits\":14",
                "\"fractionalBits\":13",
                .phaseCoefficientProcedureMismatch
            ),
            (
                .verificationContract,
                "\"visiblePixelMismatchAllowance\":0",
                "\"visiblePixelMismatchAllowance\":1",
                .verificationContractMismatch
            )
        ]
        for (index, testCase) in typedTamperCases.enumerated() {
            let original = try ASHV4SemanticArtifactTestSupport
                .completeRequest()
            var replacedRole = false
            let artifacts = original.artifacts.map { artifact in
                guard artifact.role == testCase.0 else { return artifact }
                let text = String(decoding: artifact.data, as: UTF8.self)
                let replaced = text.replacingOccurrences(
                    of: testCase.1,
                    with: testCase.2
                )
                replacedRole = replaced != text
                return ASHP06RuntimeArtifactInputV4(
                    role: artifact.role,
                    data: Data(replaced.utf8)
                )
            }
            try require(replacedRole, "typed tamper fixture did not mutate")
            do {
                _ = try ASHP06RuntimeBundleBuilderV4.build(
                    ASHP06RuntimeBuildRequestV4(
                        releaseStatus: original.releaseStatus,
                        provenance: original.provenance,
                        artifacts: artifacts
                    ),
                    at: root.appendingPathComponent("typed-tamper-\(index)"),
                    metalLibraryValidator: ASHV4FixtureMetalValidator()
                )
                throw ASHV4SemanticSelfTestError.assertion(
                    "typed artifact tamper unexpectedly built"
                )
            } catch let error as ASHP06RuntimeBundleV4Error {
                try require(
                    error == testCase.3,
                    "typed artifact tamper returned the wrong error"
                )
            }
        }

        let operatorURL = firstURL.appendingPathComponent(
            ASHRuntimeArtifactRoleV4.operatorBank.canonicalRelativePath
        )
        var tampered = try Data(contentsOf: operatorURL)
        tampered[tampered.startIndex] ^= 1
        try tampered.write(to: operatorURL)
        let trust = try ASHRuntimeTrustPolicyV4(
            expectedManifestSHA256: first.manifestSHA256,
            allowedSourceRevisions: [ASHV4SemanticArtifactTestSupport.sourceRevision],
            allowedBuilderSourceSHA256: [ASHV4SemanticArtifactTestSupport.builderHash]
        )
        do {
            _ = try ASHP06RuntimeBundleLoaderV4.load(
                at: firstURL,
                trustPolicy: trust,
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
            throw ASHV4SemanticSelfTestError.assertion(
                "tampered bundle unexpectedly loaded"
            )
        } catch ASHP06RuntimeBundleV4Error.artifactHashMismatch {
            // Expected.
        } catch ASHP06RuntimeBundleV4Error.artifactSizeMismatch {
            // Also expected when tamper changes length.
        }
    }

    private static func producePlanHash() throws -> String {
        let root = try makeTemporaryDirectory(label: "child")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: root.appendingPathComponent("runtime")
        )
        return try ASHV4SemanticArtifactTestSupport.planHash(runtime: runtime)
    }

    private static func childPlanHash() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--plan-hash"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ASHV4SemanticSelfTestError.childFailed(
                process.terminationStatus,
                String(
                    decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
            )
        }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeTemporaryDirectory(label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-v4-selftest-\(label)-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw ASHV4SemanticSelfTestError.assertion(message)
        }
    }
}
