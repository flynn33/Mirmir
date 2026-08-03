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
        try require(
            localHash == ASHV4SemanticArtifactTestSupport.expectedPlanSHA256,
            "plan identity differs from the locked fixture"
        )
        print("plan_sha256=\(localHash)")

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

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw ASHV4SemanticSelfTestError.assertion(message)
        }
    }
}
