import Foundation

private enum P06RuntimeInputGeneratorError: Error, CustomStringConvertible {
    case usage(String)
    case outputExists(String)
    case outputParentMissing(String)

    var description: String {
        switch self {
        case .usage(let message), .outputExists(let message),
             .outputParentMissing(let message):
            message
        }
    }
}

@main
private enum P06RuntimeInputGeneratorMain {
    static func main() {
        do {
            let options = try Options(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
            try ASHP06CanonicalRuntimeArtifactsV4
                .validateLockedRepositoryInputs(
                    repositoryRoot: options.repositoryRoot
                )
            let metalLibrary = try Data(contentsOf: options.metalLibrary)
            let artifacts = try ASHP06CanonicalRuntimeArtifactsV4.make(
                metalLibrary: metalLibrary,
                toolchain: options.toolchain
            )
            try publish(artifacts, at: options.outputDirectory)
            for artifact in artifacts {
                let hash = ASHSHA256V4(rawData: artifact.data)
                print(
                    "\(hash.rawValue)  "
                        + artifact.role.canonicalRelativePath
                )
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func publish(
        _ artifacts: [ASHP06RuntimeArtifactInputV4],
        at requestedOutput: URL,
        fileManager: FileManager = .default
    ) throws {
        let output = requestedOutput.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !fileManager.fileExists(
            atPath: output.path,
            isDirectory: &isDirectory
        ) else {
            throw P06RuntimeInputGeneratorError.outputExists(output.path)
        }
        let parent = output.deletingLastPathComponent()
        guard fileManager.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw P06RuntimeInputGeneratorError.outputParentMissing(parent.path)
        }
        let staging = parent.appendingPathComponent(
            ".\(output.lastPathComponent).p06-input-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        var removeStaging = true
        defer {
            if removeStaging { try? fileManager.removeItem(at: staging) }
        }
        try fileManager.createDirectory(
            at: staging.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true
        )
        for artifact in artifacts.sorted(by: { $0.role < $1.role }) {
            try artifact.data.write(
                to: staging.appendingPathComponent(
                    artifact.role.canonicalRelativePath,
                    isDirectory: false
                ),
                options: .atomic
            )
        }
        try fileManager.moveItem(at: staging, to: output)
        removeStaging = false
    }
}

private struct Options {
    let repositoryRoot: URL
    let metalLibrary: URL
    let outputDirectory: URL
    let toolchain: ASHRuntimeToolchainV4

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--"), index + 1 < arguments.count,
                  values.updateValue(arguments[index + 1], forKey: key) == nil
            else {
                throw P06RuntimeInputGeneratorError.usage(Self.usage)
            }
            index += 2
        }
        let known = Set([
            "--repository-root", "--metal-library", "--output",
            "--swift-compiler", "--metal-compiler", "--metal-language",
            "--sdk-build", "--deployment-target", "--target-triple"
        ])
        guard Set(values.keys).isSubset(of: known) else {
            throw P06RuntimeInputGeneratorError.usage(Self.usage)
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw P06RuntimeInputGeneratorError.usage(Self.usage)
            }
            return value
        }
        repositoryRoot = URL(
            fileURLWithPath: try required("--repository-root"),
            isDirectory: true
        ).standardizedFileURL
        metalLibrary = URL(
            fileURLWithPath: try required("--metal-library"),
            isDirectory: false
        ).standardizedFileURL
        outputDirectory = URL(
            fileURLWithPath: try required("--output"),
            isDirectory: true
        ).standardizedFileURL
        toolchain = try ASHRuntimeToolchainV4(
            swiftCompilerIdentity: required("--swift-compiler"),
            metalCompilerIdentity: required("--metal-compiler"),
            metalLanguageVersion: required("--metal-language"),
            sdkBuildIdentity: required("--sdk-build"),
            deploymentTarget: required("--deployment-target"),
            targetTriple: required("--target-triple")
        )
    }

    private static let usage = """
    usage: P06RuntimeInputGeneratorMain \
      --repository-root <checkout> --metal-library <metallib> --output <new-dir> \
      --swift-compiler <identity> --metal-compiler <identity> \
      --metal-language <version> --sdk-build <identity> \
      --deployment-target <version> --target-triple <triple>
    """
}
