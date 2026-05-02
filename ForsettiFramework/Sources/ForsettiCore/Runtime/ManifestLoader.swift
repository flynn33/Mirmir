import Foundation

public enum ManifestLoaderError: Error, LocalizedError {
    case manifestsDirectoryNotFound(String)
    case duplicateModuleID(String)
    case validationFailed(file: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .manifestsDirectoryNotFound(path):
            return "No manifests found in resource directory: \(path)."
        case let .duplicateModuleID(moduleID):
            return "Duplicate moduleID in manifest resources: \(moduleID)."
        case let .validationFailed(file, reason):
            return "Manifest \(file) failed validation: \(reason)."
        }
    }
}

public final class ManifestLoader {
    private let decoder: JSONDecoder
    private let manifestRootKeys: Set<String> = [
        "schemaVersion",
        "moduleID",
        "displayName",
        "moduleVersion",
        "moduleType",
        "supportedPlatforms",
        "minForsettiVersion",
        "capabilitiesRequested",
        "entryPoint"
    ]

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func loadManifests(
        bundle: Bundle,
        subdirectory: String = "ForsettiManifests"
    ) throws -> [String: ModuleManifest] {
        if let directURLs = bundle.urls(forResourcesWithExtension: "json", subdirectory: subdirectory), !directURLs.isEmpty {
            return try loadManifests(
                resourceURLs: directURLs,
                strict: true,
                missingDirectoryHint: subdirectory
            )
        }

        // SwiftPM resource processing may flatten directories; fallback to recursive lookup.
        guard let resourceURL = bundle.resourceURL else {
            throw ManifestLoaderError.manifestsDirectoryNotFound(subdirectory)
        }

        let recursiveURLs = try FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).flatMap { url -> [URL] in
            if url.hasDirectoryPath {
                return recursiveJSONURLs(in: url)
            }
            return url.pathExtension.lowercased() == "json" ? [url] : []
        }

        let requestedFolderName = URL(fileURLWithPath: subdirectory).lastPathComponent.lowercased()
        let scopedURLs = recursiveURLs.filter { url in
            !requestedFolderName.isEmpty && url.path.lowercased().contains(requestedFolderName)
        }

        if !scopedURLs.isEmpty {
            return try loadManifests(
                resourceURLs: scopedURLs,
                strict: true,
                missingDirectoryHint: subdirectory
            )
        }

        guard !recursiveURLs.isEmpty else {
            throw ManifestLoaderError.manifestsDirectoryNotFound(subdirectory)
        }

        return try loadManifests(
            resourceURLs: recursiveURLs,
            strict: false,
            missingDirectoryHint: subdirectory
        )
    }

    public func loadManifests(resourceURLs: [URL]) throws -> [String: ModuleManifest] {
        try loadManifests(
            resourceURLs: resourceURLs,
            strict: true,
            missingDirectoryHint: "provided resource URLs"
        )
    }

    private func loadManifests(
        resourceURLs: [URL],
        strict: Bool,
        missingDirectoryHint: String
    ) throws -> [String: ModuleManifest] {
        var manifests: [String: ModuleManifest] = [:]

        for url in resourceURLs {
            let data = try Data(contentsOf: url)

            if !strict, !looksLikeManifestJSON(data) {
                continue
            }

            let manifest: ModuleManifest
            do {
                manifest = try decoder.decode(ModuleManifest.self, from: data)
            } catch {
                throw ManifestLoaderError.validationFailed(
                    file: url.lastPathComponent,
                    reason: "invalid manifest JSON (\(error.localizedDescription))"
                )
            }

            try validate(manifest: manifest, fileName: url.lastPathComponent)

            if manifests[manifest.moduleID] != nil {
                throw ManifestLoaderError.duplicateModuleID(manifest.moduleID)
            }

            manifests[manifest.moduleID] = manifest
        }

        if manifests.isEmpty {
            throw ManifestLoaderError.manifestsDirectoryNotFound(missingDirectoryHint)
        }

        return manifests
    }

    private func validate(manifest: ModuleManifest, fileName: String) throws {
        if manifest.schemaVersion.isEmpty {
            throw ManifestLoaderError.validationFailed(file: fileName, reason: "schemaVersion is required")
        }

        if manifest.moduleID.isEmpty {
            throw ManifestLoaderError.validationFailed(file: fileName, reason: "moduleID is required")
        }

        if manifest.displayName.isEmpty {
            throw ManifestLoaderError.validationFailed(file: fileName, reason: "displayName is required")
        }

        if manifest.entryPoint.isEmpty {
            throw ManifestLoaderError.validationFailed(file: fileName, reason: "entryPoint is required")
        }

        if manifest.supportedPlatforms.isEmpty {
            throw ManifestLoaderError.validationFailed(file: fileName, reason: "supportedPlatforms must include at least one platform")
        }
    }

    private func recursiveJSONURLs(in directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "json" {
                urls.append(fileURL)
            }
        }
        return urls
    }

    private func looksLikeManifestJSON(_ data: Data) -> Bool {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let dictionary = jsonObject as? [String: Any] else {
            return false
        }

        return manifestRootKeys.isSubset(of: Set(dictionary.keys))
    }
}
