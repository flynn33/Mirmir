import Foundation

private enum P06RuntimeBuilderCLIError: Error, CustomStringConvertible {
    case usage(String)
    case missingArtifact(String)

    var description: String {
        switch self {
        case .usage(let message), .missingArtifact(let message):
            message
        }
    }
}

@main
private enum P06RuntimeBuilderMain {
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let artifacts = try ASHRuntimeArtifactRoleV4.allCases.map { role in
                let url = options.inputDirectory.appendingPathComponent(
                    role.canonicalRelativePath
                )
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw P06RuntimeBuilderCLIError.missingArtifact(
                        "Missing required input artifact: \(url.path)"
                    )
                }
                return ASHP06RuntimeArtifactInputV4(
                    role: role,
                    data: try Data(contentsOf: url)
                )
            }
            let result = try ASHP06RuntimeBundleBuilderV4.build(
                ASHP06RuntimeBuildRequestV4(
                    releaseStatus: options.releaseStatus,
                    provenance: ASHP06RuntimeBuildProvenanceV4(
                        sourceRevision: options.sourceRevision,
                        builderID: options.builderID,
                        builderSourceSHA256: options.builderSourceSHA256,
                        buildParametersSHA256: options.buildParametersSHA256,
                        toolchain: ASHRuntimeToolchainV4(
                            swiftCompilerIdentity: options.swiftCompilerIdentity,
                            metalCompilerIdentity: options.metalCompilerIdentity,
                            metalLanguageVersion: options.metalLanguageVersion,
                            sdkBuildIdentity: options.sdkBuildIdentity,
                            deploymentTarget: options.deploymentTarget,
                            targetTriple: options.targetTriple
                        )
                    ),
                    artifacts: artifacts
                ),
                at: options.outputDirectory,
                metalLibraryValidator: try ASHSystemMetalLibraryValidatorV4()
            )
            FileHandle.standardOutput.write(
                Data(
                    "\(result.manifestSHA256.rawValue)  \(result.bundleURL.path)\n"
                        .utf8
                )
            )
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}

private struct Options {
    let inputDirectory: URL
    let outputDirectory: URL
    let releaseStatus: ASHRuntimeReleaseStatusV4
    let sourceRevision: String
    let builderID: String
    let builderSourceSHA256: ASHSHA256V4
    let buildParametersSHA256: ASHSHA256V4
    let swiftCompilerIdentity: String
    let metalCompilerIdentity: String
    let metalLanguageVersion: String
    let sdkBuildIdentity: String
    let deploymentTarget: String
    let targetTriple: String

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count else {
                throw P06RuntimeBuilderCLIError.usage(Self.usage)
            }
            guard values.updateValue(arguments[index + 1], forKey: key) == nil else {
                throw P06RuntimeBuilderCLIError.usage(
                    "Duplicate option \(key).\n\(Self.usage)"
                )
            }
            index += 2
        }

        func required(_ name: String) throws -> String {
            guard let value = values[name], !value.isEmpty else {
                throw P06RuntimeBuilderCLIError.usage(
                    "Missing \(name).\n\(Self.usage)"
                )
            }
            return value
        }
        let known = Set([
            "--input", "--output", "--status", "--source-revision",
            "--builder-id", "--builder-source-sha256",
            "--build-parameters-sha256", "--swift-compiler",
            "--metal-compiler", "--metal-language", "--sdk-build",
            "--deployment-target", "--target-triple"
        ])
        if let unknown = Set(values.keys).subtracting(known).sorted().first {
            throw P06RuntimeBuilderCLIError.usage(
                "Unknown option \(unknown).\n\(Self.usage)"
            )
        }

        inputDirectory = URL(
            fileURLWithPath: try required("--input"),
            isDirectory: true
        ).standardizedFileURL
        outputDirectory = URL(
            fileURLWithPath: try required("--output"),
            isDirectory: true
        ).standardizedFileURL
        let statusValue = try required("--status")
        guard let parsedStatus = ASHRuntimeReleaseStatusV4(rawValue: statusValue)
        else {
            throw P06RuntimeBuilderCLIError.usage(
                "Invalid --status \(statusValue).\n\(Self.usage)"
            )
        }
        releaseStatus = parsedStatus
        sourceRevision = try required("--source-revision")
        builderID = try required("--builder-id")
        builderSourceSHA256 = try ASHSHA256V4(
            required("--builder-source-sha256")
        )
        buildParametersSHA256 = try ASHSHA256V4(
            required("--build-parameters-sha256")
        )
        swiftCompilerIdentity = try required("--swift-compiler")
        metalCompilerIdentity = try required("--metal-compiler")
        metalLanguageVersion = try required("--metal-language")
        sdkBuildIdentity = try required("--sdk-build")
        deploymentTarget = try required("--deployment-target")
        targetTriple = try required("--target-triple")
    }

    private static let usage = """
    usage: build_p06_runtime.sh \\
      --input <artifact-input-directory> \\
      --output <new-bundle-directory> \\
      --status <semantic_candidate|release_qualified> \\
      --source-revision <40-or-64-character-lowercase-git-hash> \\
      --builder-id <stable-id> \\
      --builder-source-sha256 <sha256> \\
      --build-parameters-sha256 <sha256> \\
      --swift-compiler <identity> \\
      --metal-compiler <identity> \\
      --metal-language <version> \\
      --sdk-build <identity> \\
      --deployment-target <version> \\
      --target-triple <triple>

    The input directory mirrors the bundle's artifacts/ paths. The output path
    must not exist; the builder verifies the completed bundle before publishing.
    """
}
