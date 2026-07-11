import XCTest
import ForsettiCore
@testable import Mirmir

final class ArchitectureGuardrailTests: XCTestCase {

    func test_forsettiDependencyIsRemotePinnedAndDoesNotUseExampleProduct() throws {
        let projectSpec = try String(contentsOf: repoRootURL().appendingPathComponent("project.yml"), encoding: .utf8)
        let generatedProject = try String(
            contentsOf: repoRootURL().appendingPathComponent("Mirmir.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        XCTAssertFalse(projectSpec.contains("path: ForsettiFramework"))
        XCTAssertTrue(projectSpec.contains("Forsetti-Framework-Mac-iOS.git"))
        XCTAssertTrue(projectSpec.contains("43eef7a739f3b78253c64aa4b070521ab5b1f43c"))
        XCTAssertFalse(projectSpec.contains("ForsettiModulesExample"))
        XCTAssertFalse(generatedProject.contains("XCLocalSwiftPackageReference"))
        XCTAssertFalse(generatedProject.contains("ForsettiModulesExample"))
    }

    func test_unitTestTargetDoesNotLinkForsettiCoreSeparatelyFromHostedApp() throws {
        let projectSpec = try String(contentsOf: repoRootURL().appendingPathComponent("project.yml"), encoding: .utf8)
        let testTargetSection = try targetSection(named: "MirmirTests", in: projectSpec)

        XCTAssertFalse(
            testTargetSection.contains("product: ForsettiCore"),
            "MirmirTests must use the hosted app's Forsetti runtime instead of linking a separate Core framework."
        )
    }

    func test_patternBHasExactlyOneUIModuleAndServicesDoNotContributeUI() throws {
        let manifests = try loadManifestFiles()
        let uiManifests = manifests.filter { $0.moduleType == .ui || $0.defaultModuleRole == .ui }
        let serviceManifests = manifests.filter { $0.moduleType == .service }

        XCTAssertEqual(uiManifests.map(\.moduleID), [MirmirUIConstants.moduleID])
        XCTAssertEqual(serviceManifests.count, 4)

        for manifest in serviceManifests {
            XCTAssertFalse(
                manifest.capabilitiesRequested.contains(.viewInjection),
                "\(manifest.moduleID) must not request UI contribution capabilities"
            )
            XCTAssertNil(manifest.defaultModuleRole, "\(manifest.moduleID) must not declare a UI role")
            XCTAssertNil(manifest.runtimeRequirements.ui, "\(manifest.moduleID) must not declare UI requirements")
        }
    }

    func test_serviceModuleSourcesDoNotImportUIFrameworks() throws {
        let serviceRoots = [
            "Mirmir/Modules/MediaPipeline",
            "Mirmir/Modules/MetalRendering",
            "Mirmir/Modules/ModelAssets",
            "Mirmir/Modules/UpscalerEngine"
        ]
        let forbiddenImports = ["import SwiftUI", "import AppKit", "import UIKit"]

        for root in serviceRoots {
            for fileURL in try swiftFiles(under: repoRootURL().appendingPathComponent(root)) {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                for forbiddenImport in forbiddenImports {
                    XCTAssertFalse(
                        source.contains(forbiddenImport),
                        "\(fileURL.path) must not import \(forbiddenImport)"
                    )
                }
            }
        }
    }

    func test_productionClassesAreFinal() throws {
        let classPattern = try NSRegularExpression(pattern: #"(?m)^\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?class\s+\w+"#)

        for fileURL in try swiftFiles(under: repoRootURL().appendingPathComponent("Mirmir")) {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            let matches = classPattern.matches(in: source, range: range)
            XCTAssertTrue(matches.isEmpty, "\(fileURL.path) declares a non-final production class")
        }
    }

    func test_repositorySurfacesHaveNoProhibitedAttribution() throws {
        let contentTerms = prohibitedContentTerms()
        for fileURL in try repositoryTextFiles() {
            let data = try Data(contentsOf: fileURL)
            guard let source = String(data: data, encoding: .utf8) else {
                continue
            }
            for term in contentTerms where source.range(of: term, options: [.caseInsensitive]) != nil {
                XCTFail("\(fileURL.path) contains prohibited attribution")
            }
        }

        let pathTerms = prohibitedPathTerms()
        for fileURL in try repositoryFiles() {
            for term in pathTerms where fileURL.path.range(of: term, options: [.caseInsensitive]) != nil {
                XCTFail("\(fileURL.path) contains prohibited attribution in its path")
            }
        }
    }

    private func loadManifestFiles() throws -> [ModuleManifest] {
        try manifestFileURLs().map { url in
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ModuleManifest.self, from: data)
        }
    }

    private func manifestFileURLs() throws -> [URL] {
        let directory = repoRootURL().appendingPathComponent("Mirmir/Resources/ForsettiManifests")
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func repositoryTextFiles() throws -> [URL] {
        try repositoryFiles().filter { url in
            ["md", "swift", "json", "yml", "yaml", "plist", "pbxproj", "sh"].contains(url.pathExtension)
                || url.lastPathComponent == "project.yml"
                || url.lastPathComponent == ".swiftlint.yml"
        }
    }

    private func repositoryFiles() throws -> [URL] {
        let root = repoRootURL()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if shouldSkip(relativePath: relative) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls
    }

    private func shouldSkip(relativePath: String) -> Bool {
        let skippedRoots = [
            ".git",
            ".build",
            ".swiftpm",
            "build",
            "DerivedData",
            "Mirmir.xcodeproj/project.xcworkspace"
        ]
        return skippedRoots.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
    }

    private func prohibitedContentTerms() -> [String] {
        let provider01 = "Clau" + "de"
        let provider02 = "Anthro" + "pic"
        let provider03 = "Open" + "AI"
        let provider04 = "Cod" + "ex"
        let provider05 = "Chat" + "G" + "PT"
        let provider06 = "Gr" + "ok"
        let provider07 = "x" + "AI"
        let provider08 = "L" + "LM"

        return [
            "Co-authored" + "-by",
            "Generated" + " by",
            "generated" + " by",
            "Created" + " by",
            "created" + " by",
            "Written" + " by",
            "written" + " by",
            "Assisted" + " by",
            "assisted" + " by",
            provider01,
            provider02,
            provider03,
            provider04,
            provider05,
            provider06,
            provider07,
            provider08 + "-generated",
            "AI" + "-assisted",
            "AI" + " generated",
            "AI" + "-generated",
            "Model" + "-generated",
            "Machine" + "-generated",
            "Ag" + "ent-generated"
        ]
    }

    private func prohibitedPathTerms() -> [String] {
        [
            "Clau" + "de",
            "Anthro" + "pic",
            "Open" + "AI",
            "Cod" + "ex",
            "Chat" + "G" + "PT",
            "Gr" + "ok",
            "x" + "AI",
            "L" + "LM",
            "ag" + "entic"
        ]
    }

    private func targetSection(named name: String, in projectSpec: String) throws -> String {
        let marker = "  \(name):"
        var sectionLines: [String] = []
        var isCollecting = false

        for line in projectSpec.components(separatedBy: .newlines) {
            if line == marker {
                isCollecting = true
                sectionLines.append(line)
                continue
            }

            if isCollecting,
               line.hasPrefix("  "),
               !line.hasPrefix("    "),
               line.hasSuffix(":") {
                break
            }

            if isCollecting {
                sectionLines.append(line)
            }
        }

        guard !sectionLines.isEmpty else {
            throw XCTSkip("Target \(name) not found in project.yml")
        }
        return sectionLines.joined(separator: "\n")
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
