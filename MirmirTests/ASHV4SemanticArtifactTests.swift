import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

final class ASHV4SemanticArtifactTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-v4-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testHistoricalLockedCaptureKeepsCurrentProductionSource() throws {
        let original = Data("original capture bytes".utf8)
        let fixture = try historicalCaptureFixture(original)
        let identity = lockedCaptureIdentity(original)
        let updated = Data("current production capture with a new strict guard".utf8)
        try updated.write(to: fixture.source)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: fixture.source))
        let historical = try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: fixture.repository, revision: fixture.revision,
            gitExecutable: fixtureGitExecutable()
        )
        XCTAssertEqual(historical, original)
        try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: fixture.source, historical: historical)
        XCTAssertEqual(try Data(contentsOf: fixture.source), updated)
        XCTAssertNotEqual(ASHSHA256V4(rawData: updated), identity.contentSHA256)
        let locked = try ASHP06LockedNaturalQualityEvidenceV4.captureImplementation()
        XCTAssertEqual(locked.repositoryRelativePath, "Mirmir/App/MirmirApp.swift")
        XCTAssertEqual(locked.byteCount, 343_095)
        XCTAssertEqual(locked.contentSHA256.rawValue,
                       "46654baec4279f4945051102c60b2f9638b1339213b638bed6c41706c30eb3dc")
    }

    func testHistoricalLockedCaptureRejectsWrongLengthHashAndFileMode() throws {
        let original = Data("original capture bytes".utf8)
        let identity = lockedCaptureIdentity(original)
        for bytes in [original + [0], Data("changed! capture bytes".utf8)] {
            let fixture = try historicalCaptureFixture(bytes)
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                identity, repositoryRoot: fixture.repository, revision: fixture.revision,
                gitExecutable: fixtureGitExecutable()
            ))
        }
        let symbolic = try historicalCaptureFixture(original, symbolic: true)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: symbolic.repository, revision: symbolic.revision,
            gitExecutable: fixtureGitExecutable()
        ))
        let fixture = try historicalCaptureFixture(original)
        for bytes in [original + [0], Data("changed! capture bytes".utf8)] {
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(
                identity, at: fixture.source, historical: bytes
            ))
        }
        try FileManager.default.removeItem(at: fixture.source)
        try FileManager.default.createSymbolicLink(atPath: fixture.source.path,
                                                  withDestinationPath: String(decoding: original, as: UTF8.self))
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(
            identity, at: fixture.source, historical: original
        ))
    }

    func testHistoricalLockedCaptureRequiresAvailableImmutableRevision() throws {
        let original = Data("original capture bytes".utf8)
        let fixture = try historicalCaptureFixture(original)
        for revision in ["HEAD", "main", String(repeating: "f", count: 40)] {
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                lockedCaptureIdentity(original), repositoryRoot: fixture.repository, revision: revision,
                gitExecutable: fixtureGitExecutable()
            ))
        }
    }

    func testHistoricalLockedCaptureIgnoresGitReplacementObjects() throws {
        let original = Data("original capture bytes".utf8)
        let fixture = try historicalCaptureFixture(original)
        let originalBlob = try fixtureGit(["rev-parse", "\(fixture.revision):Capture.swift"], in: fixture.repository)
        let replacement = fixture.repository.appendingPathComponent("replacement")
        try Data("changed! capture bytes".utf8).write(to: replacement)
        let replacementBlob = try fixtureGit(["hash-object", "-w", replacement.path], in: fixture.repository)
        _ = try fixtureGit(["replace", originalBlob, replacementBlob], in: fixture.repository)
        XCTAssertEqual(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            lockedCaptureIdentity(original), repositoryRoot: fixture.repository, revision: fixture.revision,
            gitExecutable: fixtureGitExecutable()
        ), original)
    }

    func testHistoricalExecutableMetricKeepsCurrentReaderAndExactMode() throws {
        let original = Data("original metric implementation".utf8)
        let fixture = try historicalCaptureFixture(original, executable: true)
        let identity = lockedCaptureIdentity(original)
        XCTAssertTrue(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: fixture.source))
        let current = Data("current metric reader with the new versioned contract".utf8)
        try current.write(to: fixture.source)
        XCTAssertFalse(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: fixture.source))
        let historical = try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: fixture.repository, revision: fixture.revision,
            gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
        )
        XCTAssertEqual(historical, original)
        try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: fixture.source, historical: historical)
        XCTAssertEqual(try Data(contentsOf: fixture.source), current)
        let metric = try ASHP06LockedNaturalQualityEvidenceV4.metricImplementation()
        XCTAssertEqual(metric.repositoryRelativePath, "script/v4/quality_gate_v4.py")
        XCTAssertEqual(metric.byteCount, 81_481)
        XCTAssertEqual(metric.contentSHA256.rawValue,
                       "2c5b0e5a40adc4f016d9346805f2db247ed1cd8a22e3abf26a2c87d3309ac4c8")
    }

    func testHistoricalExecutableMetricRejectsWrongBlobModeTypeAndIdentity() throws {
        let original = Data("original metric implementation".utf8)
        let identity = lockedCaptureIdentity(original)
        let wrongHash = Data("changed! metric implementation".utf8)
        XCTAssertEqual(wrongHash.count, original.count)
        for bytes in [original + [0], wrongHash] {
            let fixture = try historicalCaptureFixture(bytes, executable: true)
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                identity, repositoryRoot: fixture.repository, revision: fixture.revision,
                gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
            ))
        }
        let wrongMode = try historicalCaptureFixture(original)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: wrongMode.repository, revision: wrongMode.revision,
            gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
        ))
        let symbolic = try historicalCaptureFixture(original, symbolic: true)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: symbolic.repository, revision: symbolic.revision,
            gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
        ))
        let valid = try historicalCaptureFixture(original, executable: true)
        let tree = try historicalCaptureFixture(original, executable: true)
        try FileManager.default.removeItem(at: tree.source)
        try FileManager.default.createDirectory(at: tree.source, withIntermediateDirectories: false)
        try original.write(to: tree.source.appendingPathComponent("child"))
        _ = try fixtureGit(["add", "-A"], in: tree.repository)
        _ = try fixtureGit(["-c", "user.name=Mirmir QA", "-c", "user.email=qa@example.invalid",
                            "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
                            "commit", "-q", "-m", "bounded wrong object type"], in: tree.repository)
        let treeRevision = try fixtureGit(["rev-parse", "HEAD"], in: tree.repository)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: tree.repository, revision: treeRevision,
            gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
        ))
        for bytes in [original + [0], wrongHash] {
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(
                identity, at: valid.source, historical: bytes
            ))
        }
        try FileManager.default.removeItem(at: valid.source)
        try FileManager.default.createSymbolicLink(at: valid.source, withDestinationURL: wrongMode.source)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: valid.source))
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: valid.source, historical: original))
    }

    func testHistoricalMetricRequiresHistoryOnlyForChangedCurrentSource() throws {
        let original = Data("original metric implementation".utf8)
        let identity = lockedCaptureIdentity(original)
        let directory = temporaryDirectory.appendingPathComponent("source-only")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent(identity.repositoryRelativePath)
        try original.write(to: source)
        XCTAssertTrue(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: source))
        try Data("current new metric".utf8).write(to: source)
        XCTAssertFalse(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: source))
        for revision in ["HEAD", "main", String(repeating: "f", count: 40)] {
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                identity, repositoryRoot: directory, revision: revision,
                gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
            ))
        }
    }

    func testHistoricalExecutableRunnerKeepsCurrentRunnerAndLiteralPin() throws {
        let original = Data("original quality runner implementation".utf8)
        let fixture = try historicalCaptureFixture(original, executable: true)
        let identity = lockedCaptureIdentity(original)
        let current = Data("current runner with explicit versioned capture flags".utf8)
        try current.write(to: fixture.source)
        XCTAssertFalse(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: fixture.source))
        let historical = try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: fixture.repository, revision: fixture.revision,
            gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
        )
        XCTAssertEqual(historical, original)
        try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: fixture.source, historical: historical)
        XCTAssertEqual(try Data(contentsOf: fixture.source), current)
        let runner = try ASHP06LockedNaturalQualityEvidenceV4.runnerImplementation()
        XCTAssertEqual(runner.repositoryRelativePath, "script/v4/run_quality_gate_v4.sh")
        XCTAssertEqual(runner.byteCount, 14_630)
        XCTAssertEqual(runner.contentSHA256.rawValue,
                       "d4d06e4a72a506421307a6f0963a44abc157c1cf1bc80101536a13b25600e3cb")
    }

    func testHistoricalExecutableRunnerRejectsWrongModeBlobAndUnavailableHistory() throws {
        let original = Data("original quality runner implementation".utf8)
        let identity = lockedCaptureIdentity(original)
        for (bytes, executable) in [(original, false), (original + [0], true),
                                     (Data("changed! quality runner implementation".utf8), true)] {
            let fixture = try historicalCaptureFixture(bytes, executable: executable)
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                identity, repositoryRoot: fixture.repository, revision: fixture.revision,
                gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
            ))
        }
        let fixture = try historicalCaptureFixture(original, executable: true)
        for revision in ["HEAD", String(repeating: "f", count: 40)] {
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                identity, repositoryRoot: fixture.repository, revision: revision,
                gitExecutable: fixtureGitExecutable(), expectedGitMode: "100755"
            ))
        }
        try FileManager.default.removeItem(at: fixture.source)
        try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: fixture.source))
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: fixture.source, historical: original))
    }

    func testHistoricalCorpusBuilderKeepsCurrentBuilderAndLiteralPin() throws {
        let original = Data("original natural corpus builder".utf8)
        let identity = lockedCaptureIdentity(original)
        let fixture = try historicalCaptureFixture(original)
        let current = Data("current corpus builder with versioned phase admission".utf8)
        try current.write(to: fixture.source)
        XCTAssertFalse(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: fixture.source))
        let historical = try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: fixture.repository, revision: fixture.revision,
            gitExecutable: fixtureGitExecutable(), expectedGitMode: "100644"
        )
        XCTAssertEqual(historical, original)
        try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: fixture.source, historical: historical)
        XCTAssertEqual(try Data(contentsOf: fixture.source), current)
        let builder = try ASHP06LockedNaturalQualityEvidenceV4.corpusBuilder()
        XCTAssertEqual(builder.repositoryRelativePath, "script/v4/build_natural_quality_corpus.py")
        XCTAssertEqual(builder.byteCount, 19_178)
        XCTAssertEqual(builder.contentSHA256.rawValue,
                       "0150955cfa206bf9e4b3f3ca7b74971543e70d4ec47d4f174eb87b1e33790aa8")
    }

    func testHistoricalCorpusBuilderRejectsWrongModeBlobSizeHashAndObjectType() throws {
        let original = Data("original natural corpus builder".utf8)
        let identity = lockedCaptureIdentity(original)
        var changed = original
        changed[0] ^= 1
        for (bytes, executable, symbolic) in [
            (original, true, false), (original + [0], false, false),
            (changed, false, false), (original, false, true)
        ] {
            let fixture = try historicalCaptureFixture(bytes, symbolic: symbolic, executable: executable)
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                identity, repositoryRoot: fixture.repository, revision: fixture.revision,
                gitExecutable: fixtureGitExecutable(), expectedGitMode: "100644"
            ))
        }
        let tree = try historicalCaptureFixture(original)
        try FileManager.default.removeItem(at: tree.source)
        try FileManager.default.createDirectory(at: tree.source, withIntermediateDirectories: false)
        try original.write(to: tree.source.appendingPathComponent("child"))
        _ = try fixtureGit(["add", "-A"], in: tree.repository)
        _ = try fixtureGit(["-c", "user.name=Mirmir QA", "-c", "user.email=qa@example.invalid",
                            "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
                            "commit", "-q", "-m", "bounded wrong corpus-builder object type"], in: tree.repository)
        let revision = try fixtureGit(["rev-parse", "HEAD"], in: tree.repository)
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
            identity, repositoryRoot: tree.repository, revision: revision,
            gitExecutable: fixtureGitExecutable(), expectedGitMode: "100644"
        ))
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: tree.source))
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: tree.source, historical: original))
    }

    func testHistoricalCorpusBuilderSourceOnlyMatchingWorksAndChangedRequiresHistory() throws {
        let original = Data("original natural corpus builder".utf8)
        let identity = lockedCaptureIdentity(original)
        let directory = temporaryDirectory.appendingPathComponent("source-only-corpus-builder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent(identity.repositoryRelativePath)
        try original.write(to: source)
        XCTAssertTrue(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: source))
        try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: source)
        try Data("current new corpus builder".utf8).write(to: source)
        XCTAssertFalse(try ASHP06CanonicalRuntimeArtifactsV4.lockedRepositoryInputMatches(identity, at: source))
        XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.validateLockedRepositoryInput(identity, at: source))
        for revision in ["HEAD", "main", String(repeating: "f", count: 40)] {
            XCTAssertThrowsError(try ASHP06CanonicalRuntimeArtifactsV4.historicalLockedRepositoryInput(
                identity, repositoryRoot: directory, revision: revision,
                gitExecutable: fixtureGitExecutable(), expectedGitMode: "100644"
            ))
        }
    }

    private func lockedCaptureIdentity(_ bytes: Data) -> ASHP06LockedFileIdentityV4 {
        ASHP06LockedFileIdentityV4(repositoryRelativePath: "Capture.swift", byteCount: Int64(bytes.count),
                                  contentSHA256: ASHSHA256V4(rawData: bytes))
    }

    private func historicalCaptureFixture(_ bytes: Data, symbolic: Bool = false, executable: Bool = false) throws
        -> (repository: URL, source: URL, revision: String) {
        let repository = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false)
        _ = try fixtureGit(["init", "-q", "--object-format=sha1"], in: repository)
        let source = repository.appendingPathComponent("Capture.swift")
        if symbolic {
            try FileManager.default.createSymbolicLink(atPath: source.path,
                withDestinationPath: String(decoding: bytes, as: UTF8.self))
        } else {
            try bytes.write(to: source)
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
            }
        }
        _ = try fixtureGit(["add", "--", "Capture.swift"], in: repository)
        _ = try fixtureGit(["-c", "user.name=Mirmir QA", "-c", "user.email=qa@example.invalid",
                            "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
                            "commit", "-q", "-m", "bounded historical capture fixture"], in: repository)
        return (repository, source, try fixtureGit(["rev-parse", "HEAD"], in: repository))
    }

    @discardableResult
    private func fixtureGit(_ arguments: [String], in repository: URL) throws -> String {
        let process = Process()
        process.executableURL = try fixtureGitExecutable()
        process.currentDirectoryURL = repository
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        let errorOutput = Pipe()
        process.standardError = errorOutput
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorBytes = errorOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ASHP06RuntimeBundleV4Error.invalidBuildInput(
                "test Git fixture command failed: argv=\(arguments) status=\(process.terminationStatus) "
                    + "reason=\(process.terminationReason.rawValue) stderr=\(String(decoding: errorBytes, as: UTF8.self)) "
                    + "stdout=\(String(decoding: bytes, as: UTF8.self))"
            )
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fixtureGitExecutable() throws -> URL {
        var candidates: [URL] = []
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            candidates.append(URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/git"))
        }
        var ancestor = Bundle(for: XCTestCase.self).bundleURL
        while ancestor.path != "/" {
            candidates.append(ancestor.appendingPathComponent("usr/bin/git"))
            candidates.append(ancestor.appendingPathComponent("Developer/usr/bin/git"))
            ancestor.deleteLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/git"))
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath()
            if resolved.path != "/usr/bin/git", FileManager.default.isExecutableFile(atPath: resolved.path) {
                return resolved
            }
        }
        throw ASHP06RuntimeBundleV4Error.invalidBuildInput("actual developer Git executable unavailable for historical capture tests")
    }

    func testSHA256EncodingMatchesPublishedVectors() {
        for (input, expected) in [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (String(repeating: "a", count: 1_000_000),
             "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        ] {
            XCTAssertEqual(ASHSHA256V4(rawData: Data(input.utf8)).rawValue, expected)
        }
    }

    func testSHA256EncodingMatchesEveryTwoBytePCMPayload() {
        var combined = SHA256()
        for value in UInt32(0)...UInt32(UInt16.max) {
            let payload = Data([UInt8(value >> 8), UInt8(value & 0xff)])
            combined.update(data: Data(ASHSHA256V4(rawData: payload).rawValue.utf8))
        }
        // Independent Python hashlib reference over all 65,536 lowercase
        // payload digests, in unsigned big-endian payload order.
        XCTAssertEqual(
            combined.finalize().map { String(format: "%02x", $0) }.joined(),
            "f08b75e978ea60ad5c8b73e6d266d9d5078c6173dca8fd6d8ba9f7b3f0c476cf"
        )
    }

    func testCanonicalJSONIsStrictAndHashDomainSeparated() throws {
        struct Value: Codable, Equatable {
            let z: Int
            let a: String
        }
        let value = Value(z: 7, a: "slash/value")
        let bytes = try ASHCanonicalJSONV4.encode(value)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "{\"a\":\"slash/value\",\"z\":7}")
        XCTAssertEqual(
            try ASHCanonicalJSONV4.decode(Value.self, from: bytes),
            value
        )
        XCTAssertThrowsError(
            try ASHCanonicalJSONV4.decode(
                Value.self,
                from: Data("{\"z\":7,\"a\":\"slash/value\"}".utf8)
            )
        )
        XCTAssertThrowsError(
            try ASHCanonicalJSONV4.parse(Data("{\"a\":1,\"a\":2}".utf8))
        )
        XCTAssertThrowsError(
            try ASHCanonicalJSONV4.parse(Data("{\"a\":1.0}".utf8))
        )
        XCTAssertNotEqual(
            try ASHCanonicalJSONV4.hash(value, domain: "domain-a"),
            try ASHCanonicalJSONV4.hash(value, domain: "domain-b")
        )
    }

    func testBundleBuildIsByteReproducibleAndPlanIdentityIsStable() throws {
        let firstURL = temporaryDirectory.appendingPathComponent("first")
        let secondURL = temporaryDirectory.appendingPathComponent("second")
        let first = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: firstURL)
        let second = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: secondURL)

        XCTAssertEqual(
            try ASHV4SemanticArtifactTestSupport.bundleFiles(at: firstURL),
            try ASHV4SemanticArtifactTestSupport.bundleFiles(at: secondURL)
        )
        XCTAssertEqual(first.manifestSHA256, second.manifestSHA256)
        XCTAssertEqual(
            try first.measurementContract(),
            ASHMeasurementContractV4.canonicalP06
        )
        XCTAssertEqual(
            try first.branchProgram(),
            try ASHDepthFourBranchCompilerV4.compileCanonical()
        )
        XCTAssertEqual(
            try first.benchmarkCorpusIdentity().routes.count,
            4
        )
        XCTAssertEqual(
            try first.qualityCorpusIdentity().caseCount,
            168
        )
        XCTAssertEqual(
            try first.metricContract().minimumQualityIndex,
            105
        )
        XCTAssertEqual(
            try first.metricContract().maximumProcessingTimeRatio,
            try ExactRationalV4(4, 5)
        )
        let phaseProcedure = try first.phaseCoefficientProcedure()
        XCTAssertEqual(phaseProcedure.kernelContractID,
                       "ash-p06-catmull-rom-q14-subsampled-physical-siting-v2")
        XCTAssertEqual(phaseProcedure.coordinateProcedureID,
                       "pixel-center-luma-authenticated-subsampled-siting-v2")
        XCTAssertEqual(phaseProcedure.coefficientProcedureID,
                       "ash-p06-catmull-rom-q14-largest-remainder-v1")
        XCTAssertNotEqual(phaseProcedure.kernelContractID, phaseProcedure.coefficientProcedureID)
        XCTAssertTrue(
            try first.verificationContract().cpuMetalByteIdentityRequired
        )
        XCTAssertEqual(
            Set(try first.verificationContract().requiredRules.map(\.rawValue)),
            Set(ASHVerificationRuleV4.allCases.map(\.rawValue))
        )
        let firstPlanHash = try ASHV4SemanticArtifactTestSupport.planHash(runtime: first)
        let secondPlanHash = try ASHV4SemanticArtifactTestSupport.planHash(runtime: second)
        XCTAssertEqual(firstPlanHash, secondPlanHash)
        XCTAssertEqual(
            firstPlanHash,
            ASHV4SemanticArtifactTestSupport.expectedPlanSHA256
        )
        XCTAssertNotEqual(firstPlanHash,
                          ASHV4SemanticArtifactTestSupport.historicalGenericPlanSHA256)
        XCTAssertEqual(ASHSHA256V4(rawData: try ASHCanonicalJSONV4.encode(
            ASHV4SemanticArtifactTestSupport.mediaState()
        )).rawValue, ASHV4SemanticArtifactTestSupport.historicalCommonPhaseMediaSHA256)

        let plan = try ASHExecutionPlannerV4.makePlan(
            media: ASHV4SemanticArtifactTestSupport.mediaState(),
            request: ASHV4SemanticArtifactTestSupport.executionRequest(),
            runtime: first
        )
        try plan.verify()
        XCTAssertEqual(
            plan.plan.reconstructionOutputRule,
            .conditionedFixedPointBlend
        )
        XCTAssertEqual(plan.plan.tracks.count, 4)
        XCTAssertEqual(
            plan.plan.tracks.map(\.sourceIdentity.persistentID),
            ["video-main", "video-angle-b", "audio-en", "captions-en"]
        )
        XCTAssertEqual(
            plan.plan.tracks[0].videoScale?.horizontalScale,
            try ExactRationalV4(1_001, 640)
        )
        XCTAssertEqual(
            plan.plan.tracks[0].videoScale?.verticalScale,
            try ExactRationalV4(563, 360)
        )
    }

    func testProRes422SubtypeIsBoundIntoVerifiedPlanIdentity() throws {
        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: temporaryDirectory.appendingPathComponent("prores-plan-runtime")
        )
        let original = ASHV4SemanticArtifactTestSupport.executionRequest()
        let raster = CanonicalRasterV4(width: 1_000, height: 562)
        let proResOutput = ASHVideoOutputContractV4(
            raster: raster,
            codecID: OutputCodec.proRes422.rawValue,
            encodedFormatDescriptor: try MediaTrackFormatDescriptorV4(
                ordinal: 0,
                mediaTypeID: "fourcc_76696465",
                mediaSubtypeID: "fourcc_6170636e",
                canonicalFingerprint: ASHSHA256V4(
                    rawData: Data("semantic-prores422-format".utf8)
                ),
                completeness: .complete,
                videoRaster: raster
            ),
            pixelFormatID: PixelStorageV4.nv12VideoRange8Bit.rawValue,
            bitDepth: 8,
            range: .video,
            chromaSubsampling: .yuv420,
            chromaSiting: .left,
            alphaModel: .none,
            color: try ASHV4SemanticArtifactTestSupport.mediaState()
                .tracks[0].video!.color
        )
        let request = ASHExecutionRequestV4(
            executor: original.executor,
            measurementContractID: original.measurementContractID,
            kernelContractID: original.kernelContractID,
            directives: original.directives.map { directive in
                guard directive.trackID == "video-main" else {
                    return directive
                }
                return ASHTrackDirectiveV4(
                    trackID: directive.trackID,
                    action: .processVideo,
                    videoOutput: proResOutput,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                )
            }
        )

        let plan = try ASHExecutionPlannerV4.makePlan(
            media: ASHV4SemanticArtifactTestSupport.mediaState(),
            request: request,
            runtime: runtime
        )
        try plan.verify()
        let processed = try XCTUnwrap(plan.plan.tracks.first {
            $0.sourceIdentity.persistentID == "video-main"
        })
        XCTAssertEqual(processed.outputCodecID, "proRes422")
        XCTAssertEqual(
            processed.videoOutput?.encodedFormatDescriptor.mediaSubtypeID,
            "fourcc_6170636e"
        )
        XCTAssertNotEqual(
            plan.planSHA256,
            try ASHExecutionPlannerV4.makePlan(
                media: ASHV4SemanticArtifactTestSupport.mediaState(),
                request: original,
                runtime: runtime
            ).planSHA256
        )

        let mismatchedOutput = ASHVideoOutputContractV4(
            raster: raster,
            codecID: proResOutput.codecID,
            encodedFormatDescriptor: try MediaTrackFormatDescriptorV4(
                ordinal: 0,
                mediaTypeID: "fourcc_76696465",
                mediaSubtypeID: "fourcc_68766331",
                canonicalFingerprint:
                    proResOutput.encodedFormatDescriptor.canonicalFingerprint,
                completeness: .complete,
                videoRaster: raster
            ),
            pixelFormatID: proResOutput.pixelFormatID,
            bitDepth: proResOutput.bitDepth,
            range: proResOutput.range,
            chromaSubsampling: proResOutput.chromaSubsampling,
            chromaSiting: proResOutput.chromaSiting,
            alphaModel: proResOutput.alphaModel,
            color: proResOutput.color
        )
        let mismatchedRequest = ASHExecutionRequestV4(
            executor: request.executor,
            measurementContractID: request.measurementContractID,
            kernelContractID: request.kernelContractID,
            directives: request.directives.map { directive in
                guard directive.trackID == "video-main" else {
                    return directive
                }
                return ASHTrackDirectiveV4(
                    trackID: directive.trackID,
                    action: directive.action,
                    videoOutput: mismatchedOutput,
                    outputCodecID: nil,
                    dropReasonID: nil,
                    dropApprovalSHA256: nil
                )
            }
        )
        XCTAssertThrowsError(try ASHExecutionPlannerV4.makePlan(
            media: ASHV4SemanticArtifactTestSupport.mediaState(),
            request: mismatchedRequest,
            runtime: runtime
        ))
    }

    func testIncompleteBuildAndUnplannedTrackFailClosed() throws {
        var request = try ASHV4SemanticArtifactTestSupport.completeRequest()
        request = ASHP06RuntimeBuildRequestV4(
            releaseStatus: request.releaseStatus,
            provenance: request.provenance,
            artifacts: request.artifacts.filter { $0.role != .metricContract }
        )
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleBuilderV4.build(
                request,
                at: temporaryDirectory.appendingPathComponent("incomplete"),
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        ) { error in
            guard case ASHP06RuntimeBundleV4Error.incompleteBuildInput(let missing) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(missing, [.metricContract])
        }

        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: temporaryDirectory.appendingPathComponent("complete")
        )
        let original = ASHV4SemanticArtifactTestSupport.executionRequest()
        let missingTrack = ASHExecutionRequestV4(
            executor: original.executor,
            measurementContractID: original.measurementContractID,
            kernelContractID: original.kernelContractID,
            directives: original.directives.filter { $0.trackID != "captions-en" }
        )
        XCTAssertThrowsError(
            try ASHExecutionPlannerV4.makePlan(
                media: ASHV4SemanticArtifactTestSupport.mediaState(),
                request: missingTrack,
                runtime: runtime
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHExecutionPlanV4Error,
                .missingTrackDirective("captions-en")
            )
        }
    }

    func testSemanticArtifactsAndContractIdentitiesFailClosed() throws {
        let canonical = try ASHP06MeasurementContractArtifactV4.canonical()
        let replacement = String(
            canonical.canonicalBinaryHex.dropLast(2)
        ) + "00"
        let tampered = ASHP06MeasurementContractArtifactV4(
            schemaID: canonical.schemaID,
            artifactRole: canonical.artifactRole,
            contractID: canonical.contractID,
            canonicalBinarySHA256: canonical.canonicalBinarySHA256,
            canonicalBinaryHex: replacement
        )
        let original = try ASHV4SemanticArtifactTestSupport.completeRequest()
        let request = ASHP06RuntimeBuildRequestV4(
            releaseStatus: original.releaseStatus,
            provenance: original.provenance,
            artifacts: try original.artifacts.map { artifact in
                guard artifact.role == .measurementContract else {
                    return artifact
                }
                return ASHP06RuntimeArtifactInputV4(
                    role: artifact.role,
                    data: try ASHCanonicalJSONV4.encode(tampered)
                )
            }
        )
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleBuilderV4.build(
                request,
                at: temporaryDirectory.appendingPathComponent("semantic-tamper"),
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHP06RuntimeBundleV4Error,
                .measurementContractMismatch
            )
        }

        let runtime = try ASHV4SemanticArtifactTestSupport.buildAndLoad(
            at: temporaryDirectory.appendingPathComponent("identity-runtime")
        )
        let valid = ASHV4SemanticArtifactTestSupport.executionRequest()
        for invalid in [
            ASHExecutionRequestV4(
                executor: valid.executor,
                measurementContractID: valid.measurementContractID + ".wrong",
                kernelContractID: valid.kernelContractID,
                directives: valid.directives
            ),
            ASHExecutionRequestV4(
                executor: valid.executor,
                measurementContractID: valid.measurementContractID,
                kernelContractID: valid.kernelContractID + ".wrong",
                directives: valid.directives
            )
        ] {
            XCTAssertThrowsError(
                try ASHExecutionPlannerV4.makePlan(
                    media: ASHV4SemanticArtifactTestSupport.mediaState(),
                    request: invalid,
                    runtime: runtime
                )
            ) { error in
                XCTAssertEqual(
                    error as? ASHExecutionPlanV4Error,
                    .runtimeIdentityMismatch
                )
            }
        }
    }

    func testTypedCorpusMetricKernelAndVerificationTamperFailClosed() throws {
        let cases: [(
            role: ASHRuntimeArtifactRoleV4,
            original: String,
            replacement: String,
            expected: ASHP06RuntimeBundleV4Error
        )] = [
            (
                .benchmarkCorpusIdentity,
                "\"measuredSampleCount\":10",
                "\"measuredSampleCount\":11",
                .benchmarkCorpusIdentityMismatch
            ),
            (
                .qualityCorpusIdentity,
                "\"caseCount\":168",
                "\"caseCount\":169",
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
        for (index, testCase) in cases.enumerated() {
            let original = try ASHV4SemanticArtifactTestSupport
                .completeRequest()
            let artifacts = original.artifacts.map { artifact in
                guard artifact.role == testCase.role else { return artifact }
                let text = String(decoding: artifact.data, as: UTF8.self)
                let replaced = text.replacingOccurrences(
                    of: testCase.original,
                    with: testCase.replacement
                )
                XCTAssertNotEqual(text, replaced)
                return ASHP06RuntimeArtifactInputV4(
                    role: artifact.role,
                    data: Data(replaced.utf8)
                )
            }
            let request = ASHP06RuntimeBuildRequestV4(
                releaseStatus: original.releaseStatus,
                provenance: original.provenance,
                artifacts: artifacts
            )
            XCTAssertThrowsError(
                try ASHP06RuntimeBundleBuilderV4.build(
                    request,
                    at: temporaryDirectory.appendingPathComponent(
                        "typed-tamper-\(index)"
                    ),
                    metalLibraryValidator: ASHV4FixtureMetalValidator()
                )
            ) { error in
                XCTAssertEqual(
                    error as? ASHP06RuntimeBundleV4Error,
                    testCase.expected
                )
            }
        }
    }

    func testTamperUnexpectedEntryAndProvenanceTrustFailClosed() throws {
        let bundle = temporaryDirectory.appendingPathComponent("runtime")
        let verified = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: bundle)
        let trusted = try ASHRuntimeTrustPolicyV4(
            expectedManifestSHA256: verified.manifestSHA256,
            allowedSourceRevisions: [ASHV4SemanticArtifactTestSupport.sourceRevision],
            allowedBuilderSourceSHA256: [ASHV4SemanticArtifactTestSupport.builderHash]
        )

        let unexpected = bundle.appendingPathComponent("artifacts/unowned.bin")
        try Data("unowned".utf8).write(to: unexpected)
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleLoaderV4.load(
                at: bundle,
                trustPolicy: trusted,
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        )
        try FileManager.default.removeItem(at: unexpected)

        let operatorURL = bundle.appendingPathComponent(
            ASHRuntimeArtifactRoleV4.operatorBank.canonicalRelativePath
        )
        var altered = try Data(contentsOf: operatorURL)
        altered[altered.startIndex] ^= 1
        try altered.write(to: operatorURL)
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleLoaderV4.load(
                at: bundle,
                trustPolicy: trusted,
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        )

        let cleanBundle = temporaryDirectory.appendingPathComponent("clean")
        let clean = try ASHV4SemanticArtifactTestSupport.buildAndLoad(at: cleanBundle)
        let wrongProvenance = try ASHRuntimeTrustPolicyV4(
            expectedManifestSHA256: clean.manifestSHA256,
            allowedSourceRevisions: [String(repeating: "b", count: 40)],
            allowedBuilderSourceSHA256: [ASHV4SemanticArtifactTestSupport.builderHash]
        )
        XCTAssertThrowsError(
            try ASHP06RuntimeBundleLoaderV4.load(
                at: cleanBundle,
                trustPolicy: wrongProvenance,
                metalLibraryValidator: ASHV4FixtureMetalValidator()
            )
        ) { error in
            XCTAssertEqual(
                error as? ASHP06RuntimeBundleV4Error,
                .untrustedSourceRevision(
                    ASHV4SemanticArtifactTestSupport.sourceRevision
                )
            )
        }
    }

    func testCanonicalEventEnvelopeRejectsUnstableOrdering() throws {
        let first = ASHSHA256V4(rawData: Data("first".utf8))
        let second = ASHSHA256V4(rawData: Data("second".utf8))
        XCTAssertThrowsError(
            try ASHRuntimeEventEnvelopeV4(
                attemptID: "attempt-1",
                ordinal: 7,
                kind: .verification,
                severity: .error,
                code: "pixel-mismatch",
                recoveryDisposition: .failJob,
                parentEventSHA256: Array([second, first].sorted().reversed()),
                planSHA256: first,
                runtimeManifestSHA256: second,
                trackID: "video-main",
                frameIndex: 42,
                presentationTime: try ExactRationalV4(7, 5),
                fields: []
            )
        )
    }
}
