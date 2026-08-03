import Foundation

private enum P06RuntimeLoadCheckError: Error, CustomStringConvertible {
    case usage
    case assertion(String)
    case unexpectedTamperError(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: p06-runtime-load-check <bundle> <manifest-sha256> <source-revision> <builder-sha256>"
        case .assertion(let message):
            return message
        case .unexpectedTamperError(let description):
            return "tamper check returned an unexpected error: \(description)"
        }
    }
}

@main
private enum P06RuntimeLoadCheckMain {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("P06 runtime load check failed: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4 else {
            throw P06RuntimeLoadCheckError.usage
        }
        let bundleURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
            .standardizedFileURL
        let expectedManifest = try ASHSHA256V4(arguments[1])
        let expectedBuilder = try ASHSHA256V4(arguments[3])
        let policy = try ASHRuntimeTrustPolicyV4(
            expectedManifestSHA256: expectedManifest,
            allowedSourceRevisions: [arguments[2]],
            allowedBuilderSourceSHA256: [expectedBuilder]
        )
        let validator = try ASHSystemMetalLibraryValidatorV4()
        let runtime = try ASHP06RuntimeBundleLoaderV4.load(
            at: bundleURL,
            trustPolicy: policy,
            metalLibraryValidator: validator
        )
        try runtime.verifyBinding()
        guard runtime.manifest.runtimeID == "ash-p06-deterministic-v4",
              runtime.manifest.releaseStatus == .releaseQualified,
              runtime.manifestSHA256 == expectedManifest,
              runtime.manifest.provenance.sourceRevision == arguments[2],
              runtime.manifest.provenance.builderSourceSHA256 == expectedBuilder else {
            throw P06RuntimeLoadCheckError.assertion(
                "verified runtime does not match the declared release trust roots"
            )
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-p06-load-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.copyItem(at: bundleURL, to: temporaryRoot)
        let operatorURL = temporaryRoot.appendingPathComponent(
            ASHRuntimeArtifactRoleV4.operatorBank.canonicalRelativePath
        )
        var bytes = try Data(contentsOf: operatorURL)
        guard !bytes.isEmpty else {
            throw P06RuntimeLoadCheckError.assertion("operator bank is empty")
        }
        bytes[bytes.startIndex] ^= 1
        try bytes.write(to: operatorURL, options: .atomic)
        do {
            _ = try ASHP06RuntimeBundleLoaderV4.load(
                at: temporaryRoot,
                trustPolicy: policy,
                metalLibraryValidator: validator
            )
            throw P06RuntimeLoadCheckError.assertion(
                "a same-length artifact mutation was accepted"
            )
        } catch ASHP06RuntimeBundleV4Error.artifactHashMismatch(
            role: .operatorBank,
            expected: _,
            actual: _
        ) {
            // Required fail-closed result.
        } catch {
            throw P06RuntimeLoadCheckError.unexpectedTamperError(
                String(describing: error)
            )
        }

        print("runtime_id=\(runtime.manifest.runtimeID)")
        print("manifest_sha256=\(runtime.manifestSHA256.rawValue)")
        print("source_revision=\(runtime.manifest.provenance.sourceRevision)")
        print("builder_source_sha256=\(runtime.manifest.provenance.builderSourceSHA256.rawValue)")
        print("artifact_count=\(runtime.manifest.artifacts.count)")
        print("production_loader_acceptance=pass")
        print("same_length_artifact_tamper_rejection=pass")
    }
}
