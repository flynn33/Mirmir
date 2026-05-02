import Foundation
@testable import ForsettiCore

final class RuntimeTestBundle {
    let rootURL: URL
    let bundleURL: URL
    let bundle: Bundle

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForsettiRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL.appendingPathComponent("RuntimeTests.bundle", isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Self.writeInfoPlist(at: bundleURL.appendingPathComponent("Info.plist"))

        guard let resolvedBundle = Bundle(url: bundleURL) else {
            throw NSError(
                domain: "RuntimeLifecycleTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to initialize temporary runtime test bundle."]
            )
        }

        bundle = resolvedBundle
    }

    func writeManifest(_ manifest: ModuleManifest, fileName: String) throws {
        let manifestsDirectory = bundleURL.appendingPathComponent("ForsettiManifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: manifestsDirectory.appendingPathComponent(fileName),
            options: .atomic
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func writeInfoPlist(at url: URL) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.forsetti.tests.runtimebundle",
            "CFBundleName": "RuntimeTests",
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
