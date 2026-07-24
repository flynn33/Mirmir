import XCTest
@testable import Mirmir

final class ArchitectureGuardrailTests: XCTestCase {

    func test_projectHasNoForsettiDependencyOrP06InjectionPhase() throws {
        let projectSpec = try String(contentsOf: repoRootURL().appendingPathComponent("project.yml"), encoding: .utf8)
        let generatedProject = try String(
            contentsOf: repoRootURL().appendingPathComponent("Mirmir.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        let forbiddenValues = [
            "ForsettiFramework",
            "Forsetti-Framework-Mac-iOS",
            "ForsettiCore",
            "ForsettiPlatform",
            "ForsettiHostTemplate",
            "Inject Exact P06 ASH Release",
            "inject-ash-p06-release.sh"
        ]
        for value in forbiddenValues {
            XCTAssertFalse(projectSpec.contains(value), "project.yml contains \(value)")
            XCTAssertFalse(generatedProject.contains(value), "generated project contains \(value)")
        }
    }

    func test_unitTestTargetLinksOnlyTheHostedApplication() throws {
        let projectSpec = try String(contentsOf: repoRootURL().appendingPathComponent("project.yml"), encoding: .utf8)
        let testTargetSection = try targetSection(named: "MirmirTests", in: projectSpec)

        XCTAssertTrue(testTargetSection.contains("- target: Mirmir"))
        XCTAssertFalse(testTargetSection.contains("package:"))
        XCTAssertFalse(testTargetSection.contains("product:"))
    }

    func test_patternBHasExactlyOneUIModuleAndServicesDoNotContributeUI() throws {
        let descriptors = MirmirModuleCatalog.activationOrder
        XCTAssertEqual(descriptors.count, 5)
        XCTAssertEqual(descriptors.filter { $0.kind == .service }.count, 4)
        XCTAssertEqual(descriptors.filter { $0.kind == .ui }.map(\.moduleID), [MirmirUIConstants.moduleID])
        XCTAssertEqual(descriptors.last?.moduleID, MirmirUIConstants.moduleID)
        XCTAssertEqual(
            descriptors.map(\.moduleID),
            [
                "com.mirmir.app.metal",
                "com.mirmir.app.model-assets",
                "com.mirmir.app.media-pipeline",
                "com.mirmir.app.upscaler-engine",
                "com.mirmir.app.ui"
            ]
        )
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

    func test_productionCompositionUsesNoRetainedReferenceBackendOrVTStager() throws {
        let root = repoRootURL()
        let developmentBackend = try String(
            contentsOf: root.appendingPathComponent(
                "Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift"
            ),
            encoding: .utf8
        )
        let lockedBackend = try String(
            contentsOf: root.appendingPathComponent(
                "Mirmir/Modules/UpscalerEngine/ASH/ASHLockedUpscaleBackendV3.swift"
            ),
            encoding: .utf8
        )
        let service = try String(
            contentsOf: root.appendingPathComponent(
                "Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift"
            ),
            encoding: .utf8
        )
        let strategy = try String(
            contentsOf: root.appendingPathComponent(
                "Mirmir/Modules/UpscalerEngine/UpscaleStrategy.swift"
            ),
            encoding: .utf8
        )
        let bootstrap = try String(
            contentsOf: root.appendingPathComponent(
                "Mirmir/App/MirmirAppBootstrap.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(developmentBackend.contains("ASHTileProcessor"))
        XCTAssertFalse(developmentBackend.contains("nearestUpsample"))
        XCTAssertFalse(lockedBackend.contains("ASHLUTLeafCompilerV3"))
        XCTAssertFalse(lockedBackend.contains("ASHLUTStrictJSONParserV3"))
        XCTAssertFalse(lockedBackend.contains("makeDisposableP05Reference"))
        XCTAssertFalse(service.contains("LanczosPolishPass"))
        XCTAssertFalse(service.contains("twoXThenLanczosDownsample"))
        XCTAssertFalse(service.contains("ASHDeterministicUpscaleBackend"))
        XCTAssertTrue(service.contains("backendFactory.makeBackend"))
        XCTAssertFalse(bootstrap.contains("ASHLockedUpscaleBackendFactoryV3"))
        XCTAssertFalse(bootstrap.contains("DefaultUpscalerEngineService"))
        XCTAssertFalse(bootstrap.contains("DefaultModelAssetsService"))
        XCTAssertFalse(bootstrap.contains("VTModelStager"))
        XCTAssertFalse(bootstrap.contains("ASHBackendStartupValidator"))
        XCTAssertFalse(bootstrap.contains("ASHDevelopmentUpscaleBackendFactory"))
        XCTAssertFalse(bootstrap.contains("UnavailableUpscalerEngineService"))
        XCTAssertFalse(bootstrap.contains("RoadmapTransitionModelAssetsService"))
        XCTAssertTrue(bootstrap.contains("R13ReleaseUpscalerEngineService"))
        XCTAssertTrue(bootstrap.contains("NotRequiredModelAssetsService"))
        XCTAssertTrue(strategy.contains("case direct3Over2"))
    }

    func test_repositorySurfacesHaveNoProhibitedAttribution() throws {
        let contentTerms = prohibitedContentTerms()
        for fileURL in try repositoryTextFiles() {
            let data = try Data(contentsOf: fileURL)
            guard let source = String(data: data, encoding: .utf8) else {
                continue
            }
            let normalizedSource = source.lowercased()
            for term in contentTerms where normalizedSource.contains(term.lowercased()) {
                XCTFail("\(fileURL.path) contains prohibited attribution")
            }
        }

        let pathTerms = prohibitedPathTerms()
        for fileURL in try repositoryFiles() {
            let normalizedPath = fileURL.path.lowercased()
            for term in pathTerms where normalizedPath.contains(term.lowercased()) {
                XCTFail("\(fileURL.path) contains prohibited attribution in its path")
            }
        }
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
        if relativePath.split(separator: "/").contains(where: { $0.hasSuffix(".xcresult") }) {
            return true
        }
        let skippedRoots = [
            ".git",
            ".build",
            ".swiftpm",
            "Artifacts",
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
