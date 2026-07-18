import CryptoKit
import Darwin
import Foundation
import XCTest

final class ASHP08LauncherTests: XCTestCase {
    private static let launchArgument = "--mirmir-p08-native-evidence"

    func testOrdinaryReleaseAppHasNoHostedPlugInsAndIsTreeBindable() throws {
        let app = try productionAppURL()
        let first = try treeSHA256(app)
        let second = try treeSHA256(app)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.allSatisfy { $0 == "0" })
    }

    func testMetalParityProducer() throws {
        try requireEvidenceExecution()
        try launch(
            mode: "metal-parity",
            outputEnvironment: "MIRMIR_P08_METAL_PARITY_FRAGMENT"
        )
    }

    func testPerformanceProducer() throws {
        try requireEvidenceExecution()
        try launch(
            mode: "performance",
            outputEnvironment: "MIRMIR_P08_PERFORMANCE_FRAGMENT"
        )
    }

    func testResourceRingProducer() throws {
        try requireEvidenceExecution()
        try launch(
            mode: "resource-ring",
            outputEnvironment: "MIRMIR_P08_RESOURCE_RING_FRAGMENT"
        )
    }

    private func requireEvidenceExecution() throws {
        guard ProcessInfo.processInfo.environment["MIRMIR_P08_ENABLE_EXECUTION"] == "1"
        else {
            throw XCTSkip(
                "Set MIRMIR_P08_ENABLE_EXECUTION=1 with the exact authorized P06 and fixture inputs"
            )
        }
    }

    private func launch(mode: String, outputEnvironment: String) throws {
        let app = try productionAppURL()
        let executable = app.appendingPathComponent("Contents/MacOS/Mirmir")
        try requireRegularUnlinkedFile(executable)
        let outputPath = try requiredEnvironment(outputEnvironment)
        let output = URL(fileURLWithPath: outputPath)
        guard output.path == outputPath,
              output.path.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw launcherError("slice output must be an absent absolute normalized path")
        }
        let before = try treeSHA256(app)
        var environment = ProcessInfo.processInfo.environment
        environment["MIRMIR_P08_APP_MODE"] = mode
        environment["MIRMIR_P08_PRODUCTION_APP_TREE_SHA256"] = before
        environment["MIRMIR_P08_SLICE_OUTPUT"] = outputPath

        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.launchArgument]
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            let afterFailure = try treeSHA256(app)
            XCTAssertEqual(before, afterFailure, "app tree changed after launch failure")
            throw error
        }
        let standardOutput = stdout.fileHandleForReading.readDataToEndOfFile()
        let standardError = stderr.fileHandleForReading.readDataToEndOfFile()
        let after = try treeSHA256(app)
        XCTAssertEqual(before, after, "ordinary app tree changed across P08 execution")
        guard process.terminationReason == .exit,
              process.terminationStatus == EXIT_SUCCESS else {
            throw launcherError(
                "app exited \(process.terminationStatus); stdout=\(render(standardOutput)); stderr=\(render(standardError))"
            )
        }
        try verifyCanonicalSelfHashedOutput(output)
    }

    private func productionAppURL() throws -> URL {
        let candidate: URL
        if let configured = ProcessInfo.processInfo.environment["MIRMIR_P08_APP_BUNDLE"],
           !configured.isEmpty {
            candidate = URL(fileURLWithPath: configured)
            guard candidate.path == configured else {
                throw launcherError("MIRMIR_P08_APP_BUNDLE is not normalized")
            }
        } else {
            candidate = Bundle(for: Self.self).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Mirmir.app", isDirectory: true)
        }
        guard candidate.path.hasPrefix("/"),
              candidate.standardizedFileURL.path == candidate.path,
              candidate.lastPathComponent == "Mirmir.app" else {
            throw launcherError("production app path is not the ordinary Mirmir.app")
        }
        let values = try candidate.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true else {
            throw launcherError("production app is absent, linked, or aliased")
        }
        let plugins = candidate.appendingPathComponent("Contents/PlugIns")
        var metadata = stat()
        guard lstat(plugins.path, &metadata) != 0, errno == ENOENT else {
            throw launcherError("ordinary app contains a hosted test PlugIns tree")
        }
        return candidate
    }

    private func treeSHA256(_ root: URL) throws -> String {
        _ = try productionAppURLIdentityCheck(root)
        var records: [[String: Any]] = []
        var fileCount = 0
        var totalSize = 0
        try appendInventory(
            directory: root,
            root: root,
            records: &records,
            fileCount: &fileCount,
            totalSize: &totalSize
        )
        guard fileCount > 0, totalSize > 0 else {
            throw launcherError("ordinary app has no nonempty file evidence")
        }
        guard records.allSatisfy({
            $0["path"] is String && $0["kind"] is String
        }) else {
            throw launcherError("ordinary app inventory contains an untyped record")
        }
        records.sort {
            let lhsPath = $0["path"] as? String ?? ""
            let rhsPath = $1["path"] as? String ?? ""
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            return ($0["kind"] as? String ?? "") < ($1["kind"] as? String ?? "")
        }
        return sha256(try canonicalData(records))
    }

    private func productionAppURLIdentityCheck(_ root: URL) throws -> Bool {
        guard root.lastPathComponent == "Mirmir.app" else {
            throw launcherError("tree root is not Mirmir.app")
        }
        let plugins = root.appendingPathComponent("Contents/PlugIns")
        var metadata = stat()
        guard lstat(plugins.path, &metadata) != 0, errno == ENOENT else {
            throw launcherError("tree root contains Contents/PlugIns")
        }
        return true
    }

    private func appendInventory(
        directory: URL,
        root: URL,
        records: inout [[String: Any]],
        fileCount: inout Int,
        totalSize: inout Int
    ) throws {
        let entries = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else {
                throw launcherError("app member could not be reopened: \(entry.path)")
            }
            let relative = String(entry.path.dropFirst(root.path.count + 1))
            let kind = metadata.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                records.append(["kind": "directory", "path": relative])
                try appendInventory(
                    directory: entry,
                    root: root,
                    records: &records,
                    fileCount: &fileCount,
                    totalSize: &totalSize
                )
            } else if kind == mode_t(S_IFREG), metadata.st_nlink == 1 {
                let payload = try Data(contentsOf: entry, options: .mappedIfSafe)
                guard payload.count == Int(metadata.st_size) else {
                    throw launcherError("app member changed while hashing: \(relative)")
                }
                records.append([
                    "kind": "file",
                    "path": relative,
                    "sha256": sha256(payload),
                    "size_bytes": payload.count
                ])
                fileCount += 1
                totalSize += payload.count
            } else {
                throw launcherError("app contains a linked or special member: \(relative)")
            }
        }
    }

    private func requireRegularUnlinkedFile(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1 else {
            throw launcherError("production executable is linked, special, or absent")
        }
    }

    private func verifyCanonicalSelfHashedOutput(_ url: URL) throws {
        try requireRegularUnlinkedFile(url)
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let document = try JSONSerialization.jsonObject(with: bytes)
                as? [String: Any],
              let declared = document["artifact_sha256"] as? String else {
            throw launcherError("slice output is not a self-hashed JSON object")
        }
        var hashInput = document
        hashInput.removeValue(forKey: "artifact_sha256")
        guard declared == sha256(try canonicalData(hashInput)) else {
            throw launcherError("slice output self-hash differs")
        }
        var expected = try canonicalData(document)
        expected.append(0x0a)
        guard bytes == expected else {
            throw launcherError("slice output is not canonical one-LF JSON")
        }
    }

    private func canonicalData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw launcherError("value is outside the JSON domain")
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func requiredEnvironment(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw launcherError("required environment variable is absent: \(name)")
        }
        return value
    }

    private func render(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<non-UTF-8>"
    }

    private func launcherError(_ message: String) -> NSError {
        NSError(
            domain: "ASHP08LauncherTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
