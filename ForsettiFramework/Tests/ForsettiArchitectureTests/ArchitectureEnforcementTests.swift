import Foundation
import XCTest

final class ArchitectureEnforcementTests: XCTestCase {
    private static let guardedTargets: Set<String> = [
        "ForsettiCore",
        "ForsettiPlatform",
        "ForsettiModulesExample",
        "ForsettiHostTemplate"
    ]

    private static let expectedTargetDependencies: [String: Set<String>] = [
        "ForsettiCore": [],
        "ForsettiPlatform": ["ForsettiCore"],
        "ForsettiModulesExample": ["ForsettiCore"],
        "ForsettiHostTemplate": ["ForsettiCore", "ForsettiPlatform"]
    ]

    private static let expectedInternalImports: [String: Set<String>] = [
        "ForsettiCore": [],
        "ForsettiPlatform": ["ForsettiCore"],
        "ForsettiModulesExample": ["ForsettiCore"],
        "ForsettiHostTemplate": ["ForsettiCore", "ForsettiPlatform"]
    ]

    private static let disallowedFrameworkImports: [String: Set<String>] = [
        "ForsettiCore": ["SwiftUI", "UIKit", "AppKit", "StoreKit"],
        "ForsettiPlatform": ["SwiftUI", "UIKit", "AppKit"],
        "ForsettiModulesExample": ["SwiftUI", "UIKit", "AppKit", "StoreKit"]
    ]

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackageDependencyGraphMatchesExpectedLayering() throws {
        let actualDependencies = try loadRegularTargetDependenciesFromManifest()

        XCTAssertEqual(Set(actualDependencies.keys), Self.guardedTargets)

        for (target, expectedDependencies) in Self.expectedTargetDependencies.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(
                actualDependencies[target, default: []],
                expectedDependencies,
                "Unexpected module dependencies for \(target)."
            )
        }
    }

    func testInternalImportsRespectLayerBoundaries() throws {
        let internalModules = Self.guardedTargets

        for (target, allowedImports) in Self.expectedInternalImports.sorted(by: { $0.key < $1.key }) {
            for fileURL in try swiftSourceFiles(inTarget: target) {
                for importedModule in try parseImports(in: fileURL) where internalModules.contains(importedModule) {
                    XCTAssertTrue(
                        allowedImports.contains(importedModule),
                        "\(target) cannot import \(importedModule) in \(relativePath(for: fileURL))."
                    )
                }
            }
        }
    }

    func testFrameworkImportsRespectTargetRole() throws {
        for (target, disallowedImports) in Self.disallowedFrameworkImports.sorted(by: { $0.key < $1.key }) {
            for fileURL in try swiftSourceFiles(inTarget: target) {
                for importedModule in try parseImports(in: fileURL) where disallowedImports.contains(importedModule) {
                    XCTFail(
                        "\(target) cannot import \(importedModule) in \(relativePath(for: fileURL))."
                    )
                }
            }
        }
    }

    func testAllProductionClassesAreFinal() throws {
        let classDeclarationRegex = try NSRegularExpression(
            pattern: #"(?m)^\s*(?:@\w+(?:\([^)\n]*\))?\s*)*(?:public|internal|private|fileprivate|open)?\s*(?:final\s+)?class\s+[A-Za-z_][A-Za-z0-9_]*\b"#
        )
        var nonFinalClasses: [String] = []

        for fileURL in try swiftSourceFiles(in: packageRootURL.appendingPathComponent("Sources")) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let nsSource = source as NSString

            for match in classDeclarationRegex.matches(
                in: source,
                range: NSRange(location: 0, length: nsSource.length)
            ) {
                let declaration = nsSource.substring(with: match.range)
                if !declaration.contains("final class") {
                    nonFinalClasses.append("\(relativePath(for: fileURL)): \(declaration)")
                }
            }
        }

        XCTAssertTrue(
            nonFinalClasses.isEmpty,
            """
            All source classes must be `final` to preserve Forsetti OOP boundaries.
            Violations:
            \(nonFinalClasses.joined(separator: "\n"))
            """
        )
    }

    private func parseImports(in fileURL: URL) throws -> [String] {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let nsSource = source as NSString
        let importRegex = try NSRegularExpression(pattern: #"(?m)^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)\b"#)

        return importRegex.matches(in: source, range: NSRange(location: 0, length: nsSource.length)).compactMap {
            guard $0.numberOfRanges > 1 else {
                return nil
            }
            return nsSource.substring(with: $0.range(at: 1))
        }
    }

    private func swiftSourceFiles(inTarget targetName: String) throws -> [URL] {
        let targetURL = packageRootURL
            .appendingPathComponent("Sources")
            .appendingPathComponent(targetName)
        return try swiftSourceFiles(in: targetURL)
    }

    private func swiftSourceFiles(in directoryURL: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            throw architectureError("Missing source directory at \(directoryURL.path).")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw architectureError("Could not enumerate \(directoryURL.path).")
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            files.append(fileURL)
        }

        return files.sorted(by: { $0.path < $1.path })
    }

    private func loadRegularTargetDependenciesFromManifest() throws -> [String: Set<String>] {
        let manifestURL = packageRootURL.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let nsManifest = manifest as NSString
        let targetRegex = try NSRegularExpression(
            pattern: #"(?s)\.target\(\s*name:\s*"([^"]+)"\s*,\s*dependencies:\s*\[([^\]]*)\]"#
        )
        let dependencyRegex = try NSRegularExpression(pattern: #""([^"]+)""#)

        var dependenciesByTarget: [String: Set<String>] = [:]
        for match in targetRegex.matches(
            in: manifest,
            range: NSRange(location: 0, length: nsManifest.length)
        ) {
            guard match.numberOfRanges > 2 else {
                continue
            }

            let targetName = nsManifest.substring(with: match.range(at: 1))
            guard Self.guardedTargets.contains(targetName) else {
                continue
            }

            let dependencySlice = nsManifest.substring(with: match.range(at: 2))
            let nsDependencySlice = dependencySlice as NSString
            let dependencies = dependencyRegex.matches(
                in: dependencySlice,
                range: NSRange(location: 0, length: nsDependencySlice.length)
            ).map {
                nsDependencySlice.substring(with: $0.range(at: 1))
            }

            dependenciesByTarget[targetName] = Set(dependencies)
        }

        return dependenciesByTarget
    }

    private func relativePath(for url: URL) -> String {
        let rootPathWithSlash = packageRootURL.path + "/"
        return url.path.replacingOccurrences(of: rootPathWithSlash, with: "")
    }

    private func architectureError(_ message: String) -> NSError {
        NSError(
            domain: "ForsettiArchitectureTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
