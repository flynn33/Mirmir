import Foundation
import XCTest
@testable import ForsettiCore

final class ManifestLoaderTests: XCTestCase {
    func testStrictDirectoryValidationFailsForInvalidManifest() throws {
        let tempBundle = try TemporaryBundle()
        let manifestDirectory = tempBundle.bundleURL.appendingPathComponent("ForsettiManifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)

        let invalidManifest = makeManifest(moduleID: "com.forsetti.module.invalid", entryPoint: "")
        let invalidManifestURL = manifestDirectory.appendingPathComponent("Invalid.json")
        try writeManifest(invalidManifest, to: invalidManifestURL)

        let loader = ManifestLoader()

        XCTAssertThrowsError(
            try loader.loadManifests(bundle: tempBundle.bundle, subdirectory: "ForsettiManifests")
        ) { error in
            guard case let ManifestLoaderError.validationFailed(file, reason) = error else {
                return XCTFail("Expected ManifestLoaderError.validationFailed, received \(error).")
            }

            XCTAssertEqual(file, "Invalid.json")
            XCTAssertTrue(reason.contains("entryPoint"))
        }
    }

    func testFallbackDiscoveryIgnoresNonManifestJSON() throws {
        let tempBundle = try TemporaryBundle()

        let configURL = tempBundle.bundleURL.appendingPathComponent("config.json")
        try Data("{\"featureFlag\":true}".utf8).write(to: configURL)

        let nestedDirectory = tempBundle.bundleURL.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let manifestURL = nestedDirectory.appendingPathComponent("Example.json")
        try writeManifest(
            makeManifest(moduleID: "com.forsetti.module.example"),
            to: manifestURL
        )

        let manifests = try ManifestLoader().loadManifests(
            bundle: tempBundle.bundle,
            subdirectory: "ForsettiManifests"
        )

        XCTAssertEqual(manifests.count, 1)
        XCTAssertNotNil(manifests["com.forsetti.module.example"])
    }

    func testLoadManifestsDetectsDuplicateModuleIDs() throws {
        let tempRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let firstURL = tempRoot.appendingPathComponent("One.json")
        let secondURL = tempRoot.appendingPathComponent("Two.json")

        try writeManifest(
            makeManifest(moduleID: "com.forsetti.module.duplicate", entryPoint: "One"),
            to: firstURL
        )
        try writeManifest(
            makeManifest(moduleID: "com.forsetti.module.duplicate", entryPoint: "Two"),
            to: secondURL
        )

        XCTAssertThrowsError(
            try ManifestLoader().loadManifests(resourceURLs: [firstURL, secondURL])
        ) { error in
            guard case let ManifestLoaderError.duplicateModuleID(moduleID) = error else {
                return XCTFail("Expected duplicateModuleID error, received \(error).")
            }
            XCTAssertEqual(moduleID, "com.forsetti.module.duplicate")
        }
    }

    private func makeManifest(
        moduleID: String,
        entryPoint: String = "TestModule"
    ) -> ModuleManifest {
        ModuleManifest(
            schemaVersion: ModuleManifest.supportedSchemaVersion,
            moduleID: moduleID,
            displayName: "Test Module",
            moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
            moduleType: .service,
            supportedPlatforms: [.iOS, .macOS],
            minForsettiVersion: ForsettiVersion.current,
            maxForsettiVersion: nil,
            capabilitiesRequested: [],
            iapProductID: nil,
            entryPoint: entryPoint
        )
    }

    private func writeManifest(_ manifest: ModuleManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForsettiManifestLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class TemporaryBundle {
    let rootURL: URL
    let bundleURL: URL
    let bundle: Bundle

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForsettiBundleTests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL.appendingPathComponent("Test.bundle", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Self.writeInfoPlist(at: bundleURL.appendingPathComponent("Info.plist"))

        guard let resolvedBundle = Bundle(url: bundleURL) else {
            throw NSError(
                domain: "ManifestLoaderTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to initialize temporary test bundle."]
            )
        }

        bundle = resolvedBundle
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func writeInfoPlist(at url: URL) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.forsetti.tests.tempbundle",
            "CFBundleName": "TempBundle",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}
