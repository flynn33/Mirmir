import Foundation

// The live context is a single fail-closed preflight boundary covering the
// repository, preregistration, fixtures, host facts, and optional model.
// swiftlint:disable file_length

struct R01CommandResult: Sendable {
    let status: Int32
    let standardOutput: Data
}

protocol R01CommandRunning {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws -> R01CommandResult
}

struct R01ProcessCommandRunner: R01CommandRunning {
    static let timeoutSeconds: TimeInterval = 30
    static let maximumOutputBytes = R01RawReportWriter.maximumByteCount

    private let processRunner: any R01ChildProcessRunning
    private let timeout: TimeInterval

    init(
        processRunner: any R01ChildProcessRunning = R01FailClosedChildProcessRunner(),
        timeout: TimeInterval = R01ProcessCommandRunner.timeoutSeconds
    ) {
        self.processRunner = processRunner
        self.timeout = timeout
    }

    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws -> R01CommandResult {
        guard executable.hasPrefix("/") else {
            throw R01LiveReportError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent)
        }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("mirmir-r01-command-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("stdout")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw R01LiveReportError.commandFailed("output")
            }
        } catch {
            throw R01LiveReportError.commandFailed("output")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let result: R01ChildProcessResult
        do {
            result = try processRunner.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                environment: R01ClosedSubprocessEnvironment.values,
                currentDirectoryURL: currentDirectory,
                standardOutputURL: outputURL,
                standardErrorURL: nil,
                timeout: timeout
            )
        } catch {
            throw R01LiveReportError.commandFailed(
                URL(fileURLWithPath: executable).lastPathComponent
            )
        }
        guard !result.timedOut else {
            throw R01LiveReportError.commandFailed(
                "\(URL(fileURLWithPath: executable).lastPathComponent)-timeout"
            )
        }
        let handle = try FileHandle(forReadingFrom: outputURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumOutputBytes + 1) ?? Data()
        guard data.count <= Self.maximumOutputBytes else {
            throw R01LiveReportError.commandOutputNotClosed(
                URL(fileURLWithPath: executable).lastPathComponent
            )
        }
        return .init(status: result.terminationStatus, standardOutput: data)
    }
}

struct R01Preregistration: Decodable, Sendable {
    let schemaVersion: String
    let roadmapVersion: String
    let phaseID: String
    let preregistrationState: String
    let anchorAssignments: [R01AnchorAssignment]
    let fixtureCatalog: R01CatalogBinding

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case roadmapVersion = "roadmap_version"
        case phaseID = "phase_id"
        case preregistrationState = "preregistration_state"
        case anchorAssignments = "anchor_assignments"
        case fixtureCatalog = "fixture_catalog"
    }
}

struct R01AnchorAssignment: Decodable, Sendable {
    let anchor: R01Anchor
    let assignmentState: String
    let hostProfile: R01FrozenHostProfile?

    enum CodingKeys: String, CodingKey {
        case anchor
        case assignmentState = "assignment_state"
        case hostProfile = "host_profile"
    }
}

struct R01FrozenHostProfile: Decodable, Sendable {
    let hostID: String
    let modelIdentifier: String
    let hardwareClass: String
    let chip: String
    let memoryBytes: UInt64
    let osVersion: String
    let osBuild: String
    let xcodeVersion: String
    let xcodeBuild: String
    let sdkVersion: String
    let sdkBuild: String

    enum CodingKeys: String, CodingKey {
        case hostID = "host_id"
        case modelIdentifier = "model_identifier"
        case hardwareClass = "hardware_class"
        case chip
        case memoryBytes = "memory_bytes"
        case osVersion = "os_version"
        case osBuild = "os_build"
        case xcodeVersion = "xcode_version"
        case xcodeBuild = "xcode_build"
        case sdkVersion = "sdk_version"
        case sdkBuild = "sdk_build"
    }
}

struct R01CatalogBinding: Decodable, Sendable {
    let path: String
    let sha256: String
}

struct R01AllowlistedHostFacts: Equatable, Sendable {
    let modelIdentifier: String
    let chip: String
    let memoryBytes: UInt64
    let osVersion: String
    let osBuild: String
    let xcodeVersion: String
    let xcodeBuild: String
    let sdkVersion: String
    let sdkBuild: String

    static func collect(
        repositoryRoot: URL,
        runner: any R01CommandRunning
    ) throws -> R01AllowlistedHostFacts {
        func line(_ executable: String, _ arguments: [String], _ label: String) throws -> String {
            let result = try runner.run(
                executable: executable,
                arguments: arguments,
                currentDirectory: repositoryRoot
            )
            guard result.status == 0,
                  let string = String(data: result.standardOutput, encoding: .utf8) else {
                throw R01LiveReportError.commandFailed(label)
            }
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
                throw R01LiveReportError.commandOutputNotClosed(label)
            }
            return value
        }

        let xcodeResult = try runner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            currentDirectory: repositoryRoot
        )
        guard xcodeResult.status == 0,
              let xcodeText = String(data: xcodeResult.standardOutput, encoding: .utf8) else {
            throw R01LiveReportError.commandFailed("xcode-version")
        }
        let xcodeLines = xcodeText.split(whereSeparator: \.isNewline).map(String.init)
        guard xcodeLines.count == 2,
              xcodeLines[0].hasPrefix("Xcode "),
              xcodeLines[1].hasPrefix("Build version ") else {
            throw R01LiveReportError.commandOutputNotClosed("xcode-version")
        }
        let memoryString = try line("/usr/sbin/sysctl", ["-n", "hw.memsize"], "memory")
        guard let memory = UInt64(memoryString), memory > 0 else {
            throw R01LiveReportError.commandOutputNotClosed("memory")
        }
        return .init(
            modelIdentifier: try line("/usr/sbin/sysctl", ["-n", "hw.model"], "model"),
            chip: try line(
                "/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"], "chip"
            ),
            memoryBytes: memory,
            osVersion: try line("/usr/bin/sw_vers", ["-productVersion"], "os-version"),
            osBuild: try line("/usr/bin/sw_vers", ["-buildVersion"], "os-build"),
            xcodeVersion: String(xcodeLines[0].dropFirst("Xcode ".count)),
            xcodeBuild: String(xcodeLines[1].dropFirst("Build version ".count)),
            sdkVersion: try line(
                "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"], "sdk-version"
            ),
            sdkBuild: try line(
                "/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-build-version"], "sdk-build"
            )
        )
    }

    func hostRecord(profile: R01FrozenHostProfile) throws -> R01HostRecord {
        let comparisons: [(String, Bool)] = [
            ("model_identifier", modelIdentifier == profile.modelIdentifier),
            ("chip", chip == profile.chip),
            ("memory_bytes", memoryBytes == profile.memoryBytes),
            ("os_version", osVersion == profile.osVersion),
            ("os_build", osBuild == profile.osBuild),
            ("xcode_version", xcodeVersion == profile.xcodeVersion),
            ("xcode_build", xcodeBuild == profile.xcodeBuild),
            ("sdk_version", sdkVersion == profile.sdkVersion),
            ("sdk_build", sdkBuild == profile.sdkBuild)
        ]
        if let mismatch = comparisons.first(where: { !$0.1 }) {
            throw R01LiveReportError.hostAssignmentMismatch(mismatch.0)
        }
        var classes: [String] = []
        if chip.hasPrefix("Apple M") { classes.append("apple_silicon") }
        if !classes.contains(profile.hardwareClass) { classes.append(profile.hardwareClass) }
        return .init(
            hostID: profile.hostID,
            modelIdentifier: modelIdentifier,
            chip: chip,
            memoryBytes: memoryBytes,
            osVersion: osVersion,
            osBuild: osBuild,
            xcodeVersion: xcodeVersion,
            xcodeBuild: xcodeBuild,
            sdkVersion: sdkVersion,
            sdkBuild: sdkBuild,
            hardwareClasses: classes
        )
    }
}

struct R01FixturePayload: Sendable {
    let record: R01FixtureRecord
    let data: Data
}

struct R01PublishedSourceBinding: Sendable {
    let commit: String
    let tree: String
}

struct R01LiveProbeContext: Sendable {
    static let preregistrationPath = "docs/roadmaps/evidence/r01/records/preregistration.json"
    static let implementationSourcePaths = [
        "Scripts/r01_capabilities.py",
        "Scripts/r01_preregistration.py",
        "Scripts/phase_evidence.py",
        "Scripts/run-r01-capability-probe.sh",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityProbe.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilitySupportProbe.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityCompileProbe.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityExecutor.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityFixtureContract.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveContext.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveErrors.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityNativeAdapters.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityRawReport.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportModels.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLegacyAdapters.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityReportWriter.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityLiveProducer.swift",
        "Mirmir/Modules/UpscalerEngine/AppleUpscaleCapabilityWorker.swift",
        "MirmirTests/AppleUpscaleCapabilityProbeTests.swift",
        "MirmirTests/AppleUpscaleCapabilityLiveProbeTests.swift",
        "project.yml",
        "Mirmir.xcodeproj/project.pbxproj",
        "docs/roadmaps/evidence/schema/r01-host-report-v1.json",
        "docs/roadmaps/evidence/schema/r01-capability-aggregate-v1.json",
        "docs/roadmaps/evidence/schema/r01-preregistration-v1.json",
        "docs/roadmaps/evidence/schema/r01-fixture-catalog-v1.json"
    ]

    let request: R01LiveProbeRequest
    let repositoryRoot: URL
    let source: R01PublishedSourceBinding
    let host: R01HostRecord
    let implementationBindings: [R01RepositoryBinding]
    let preregistrationBinding: R01RepositoryBinding
    let fixtureBindings: [R01FixtureBinding]
    let fixtures: [String: R01FixturePayload]
    let modelRecord: R01FixtureRecord

    var modelIsPresent: Bool {
        guard let path = modelRecord.materializationPath else { return false }
        return FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent(path).path
        )
    }

    static func prepare(
        request: R01LiveProbeRequest,
        repositoryRoot: URL,
        runner: any R01CommandRunning = R01ProcessCommandRunner(),
        expectedSource: R01PublishedSourceBinding? = nil
    ) throws -> R01LiveProbeContext {
        let paths = R01RepositoryPaths(root: repositoryRoot)
        let preregistrationData = try paths.readRegularFile(relative: preregistrationPath)
        let preregistration = try JSONDecoder().decode(
            R01Preregistration.self,
            from: preregistrationData
        )
        guard preregistration.schemaVersion == "1.0.0",
              preregistration.roadmapVersion == "1.0.1",
              preregistration.phaseID == "R01",
              preregistration.preregistrationState == "live_assignments_frozen",
              preregistration.anchorAssignments.map(\.anchor) == R01Anchor.allCases,
              preregistration.anchorAssignments.allSatisfy({
                $0.assignmentState == "assigned" && $0.hostProfile != nil
              }) else {
            throw R01LiveReportError.preregistrationNotFrozen
        }
        guard let assignment = preregistration.anchorAssignments.first(where: {
            $0.anchor == request.anchor
        }), let profile = assignment.hostProfile else {
            throw R01LiveReportError.anchorAssignmentMissing(request.anchor.rawValue)
        }

        let catalogData = try paths.readRegularFile(relative: preregistration.fixtureCatalog.path)
        guard R01SHA256.hexDigest(catalogData) == preregistration.fixtureCatalog.sha256 else {
            throw R01LiveReportError.repositoryBindingDrift(preregistration.fixtureCatalog.path)
        }
        let catalog = try JSONDecoder().decode(R01FixtureCatalog.self, from: catalogData).validated()
        let source = try verifyPublishedSource(
            repositoryRoot: repositoryRoot,
            runner: runner,
            requiredPaths: [preregistrationPath, preregistration.fixtureCatalog.path]
                + catalog.fixtures.dropLast().compactMap(\.materializationPath)
                + implementationSourcePaths
        )
        if let expectedSource,
           source.commit != expectedSource.commit || source.tree != expectedSource.tree {
            throw R01LiveReportError.sourceTreeDirty
        }
        try verifySourceBytes(
            preregistrationData,
            relativePath: preregistrationPath,
            source: source,
            repositoryRoot: repositoryRoot,
            runner: runner
        )
        try verifySourceBytes(
            catalogData,
            relativePath: preregistration.fixtureCatalog.path,
            source: source,
            repositoryRoot: repositoryRoot,
            runner: runner
        )
        var implementationBindings: [R01RepositoryBinding] = []
        for sourcePath in implementationSourcePaths {
            let sourceData = try paths.readRegularFile(relative: sourcePath)
            try verifySourceBytes(
                sourceData,
                relativePath: sourcePath,
                source: source,
                repositoryRoot: repositoryRoot,
                runner: runner
            )
            implementationBindings.append(.init(
                path: sourcePath,
                sizeBytes: sourceData.count,
                sha256: R01SHA256.hexDigest(sourceData)
            ))
        }

        let hostFacts = try R01AllowlistedHostFacts.collect(
            repositoryRoot: repositoryRoot,
            runner: runner
        )
        let host = try hostFacts.hostRecord(profile: profile)
        let fixtureResult = try verifyFixtures(
            catalog: catalog,
            paths: paths,
            source: source,
            runner: runner
        )
        let model = try catalog.fixture(id: "analysis-probe-model")
        try verifyModelIfPresent(model, paths: paths)
        return .init(
            request: request,
            repositoryRoot: repositoryRoot,
            source: source,
            host: host,
            implementationBindings: implementationBindings,
            preregistrationBinding: .init(
                path: preregistrationPath,
                sizeBytes: preregistrationData.count,
                sha256: R01SHA256.hexDigest(preregistrationData)
            ),
            fixtureBindings: fixtureResult.bindings + [try modelBinding(model)],
            fixtures: fixtureResult.payloads,
            modelRecord: model
        )
    }

    func reverify(runner: any R01CommandRunning = R01ProcessCommandRunner()) throws {
        let observedSource = try Self.verifyPublishedSource(
            repositoryRoot: repositoryRoot,
            runner: runner,
            requiredPaths: []
        )
        guard observedSource.commit == source.commit, observedSource.tree == source.tree else {
            throw R01LiveReportError.sourceTreeDirty
        }
        let paths = R01RepositoryPaths(root: repositoryRoot)
        for binding in fixtureBindings where binding.kind == "repository_fixture" {
            guard let path = binding.path else { throw R01LiveReportError.reportNotClosed }
            let data = try paths.readRegularFile(relative: path)
            guard data.count == binding.sizeBytes, R01SHA256.hexDigest(data) == binding.sha256 else {
                throw R01LiveReportError.repositoryBindingDrift(path)
            }
        }
        try Self.verifyModelIfPresent(modelRecord, paths: paths)
    }
}

private extension R01LiveProbeContext {
    static func verifyPublishedSource(
        repositoryRoot: URL,
        runner: any R01CommandRunning,
        requiredPaths: [String]
    ) throws -> R01PublishedSourceBinding {
        let commit = try gitLine(
            ["rev-parse", "HEAD"],
            label: "git-head",
            repositoryRoot: repositoryRoot,
            runner: runner
        )
        let tree = try gitLine(
            ["rev-parse", "HEAD^{tree}"],
            label: "git-tree",
            repositoryRoot: repositoryRoot,
            runner: runner
        )
        guard R01Validation.isGitObjectID(commit), R01Validation.isGitObjectID(tree) else {
            throw R01LiveReportError.sourceTreeDirty
        }
        let dirty = try runner.run(
            executable: "/usr/bin/git",
            arguments: ["diff-index", "--quiet", "HEAD", "--"],
            currentDirectory: repositoryRoot
        )
        guard dirty.status == 0 else { throw R01LiveReportError.sourceTreeDirty }
        if !requiredPaths.isEmpty {
            let tracking = try runner.run(
                executable: "/usr/bin/git",
                arguments: ["ls-files", "--error-unmatch"] + requiredPaths,
                currentDirectory: repositoryRoot
            )
            guard tracking.status == 0 else { throw R01LiveReportError.sourceTreeDirty }
        }
        let published = try runner.run(
            executable: "/usr/bin/git",
            arguments: [
                "for-each-ref", "--format=%(refname)", "--contains", commit,
                "refs/remotes/origin"
            ],
            currentDirectory: repositoryRoot
        )
        guard published.status == 0,
              let references = String(data: published.standardOutput, encoding: .utf8),
              references.split(whereSeparator: \.isNewline).contains(where: {
                $0.hasPrefix("refs/remotes/origin/")
              }) else {
            throw R01LiveReportError.sourceNotPublished
        }
        return .init(commit: commit, tree: tree)
    }

    static func gitLine(
        _ arguments: [String],
        label: String,
        repositoryRoot: URL,
        runner: any R01CommandRunning
    ) throws -> String {
        let result = try runner.run(
            executable: "/usr/bin/git",
            arguments: arguments,
            currentDirectory: repositoryRoot
        )
        guard result.status == 0,
              let string = String(data: result.standardOutput, encoding: .utf8) else {
            throw R01LiveReportError.commandFailed(label)
        }
        let line = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("\n"), !line.contains("\r") else {
            throw R01LiveReportError.commandOutputNotClosed(label)
        }
        return line
    }

    static func verifySourceBytes(
        _ workingData: Data,
        relativePath: String,
        source: R01PublishedSourceBinding,
        repositoryRoot: URL,
        runner: any R01CommandRunning
    ) throws {
        let result = try runner.run(
            executable: "/usr/bin/git",
            arguments: ["show", "\(source.commit):\(relativePath)"],
            currentDirectory: repositoryRoot
        )
        guard result.status == 0, result.standardOutput == workingData else {
            throw R01LiveReportError.repositoryBindingDrift(relativePath)
        }
    }

    static func verifyFixtures(
        catalog: R01FixtureCatalog,
        paths: R01RepositoryPaths,
        source: R01PublishedSourceBinding,
        runner: any R01CommandRunning
    ) throws -> (bindings: [R01FixtureBinding], payloads: [String: R01FixturePayload]) {
        var bindings: [R01FixtureBinding] = []
        var payloads: [String: R01FixturePayload] = [:]
        for fixture in catalog.fixtures.dropLast() {
            guard let relativePath = fixture.materializationPath,
                  let expectedSize = fixture.byteCount,
                  let expectedHash = fixture.contentSHA256 else {
                throw R01LiveReportError.fixtureCatalogNotClosed
            }
            let data = try paths.readRegularFile(relative: relativePath)
            let generated = try R01DeterministicFixtureGenerator.materialize(fixture)
            guard data == generated, data.count == expectedSize,
                  R01SHA256.hexDigest(data) == expectedHash else {
                throw R01LiveReportError.fixtureGeneratorDrift(fixture.id)
            }
            try verifySourceBytes(
                data,
                relativePath: relativePath,
                source: source,
                repositoryRoot: paths.root,
                runner: runner
            )
            bindings.append(.init(
                id: fixture.id,
                kind: "repository_fixture",
                identity: fixture.role,
                path: relativePath,
                sizeBytes: data.count,
                sha256: expectedHash
            ))
            payloads[fixture.id] = .init(record: fixture, data: data)
        }
        return (bindings, payloads)
    }

    static func verifyModelIfPresent(
        _ model: R01FixtureRecord,
        paths: R01RepositoryPaths
    ) throws {
        guard model.id == "analysis-probe-model", model.status == "frozen",
              let path = model.materializationPath,
              path.hasPrefix(".r01-local-assets/"),
              let byteCount = model.byteCount, byteCount > 0,
              let digest = model.contentSHA256, R01Validation.isSHA256(digest),
              model.modelIdentity?.isEmpty == false else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        let url = try paths.safeURL(relative: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try paths.readRegularFile(relative: path)
        guard data.count == byteCount, R01SHA256.hexDigest(data) == digest else {
            throw R01LiveReportError.repositoryBindingDrift("analysis-probe-model")
        }
    }

    static func modelBinding(_ model: R01FixtureRecord) throws -> R01FixtureBinding {
        guard let identity = model.modelIdentity,
              let sha256 = model.contentSHA256,
              R01Validation.isSHA256(sha256) else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        return .init(
            id: model.id,
            kind: "system_asset",
            identity: identity,
            path: nil,
            sizeBytes: nil,
            sha256: sha256
        )
    }
}

struct R01RepositoryPaths {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    func safeURL(relative: String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\") else {
            throw R01LiveReportError.unsafeRepositoryPath(relative)
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw R01LiveReportError.unsafeRepositoryPath(relative)
        }
        var current = root
        for component in components {
            current.appendPathComponent(String(component))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw R01LiveReportError.unsafeRepositoryPath(relative)
            }
        }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard current.standardizedFileURL.path.hasPrefix(rootPrefix) else {
            throw R01LiveReportError.unsafeRepositoryPath(relative)
        }
        return current
    }

    func readRegularFile(relative: String) throws -> Data {
        let url = try safeURL(relative: relative)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw R01LiveReportError.repositoryBindingDrift(relative)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
