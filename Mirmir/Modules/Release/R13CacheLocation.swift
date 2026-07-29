import Foundation

struct R13CacheLocationSelection: Equatable, Sendable {
    let displayPath: String
    let isCustom: Bool
}

struct R13CacheLocationStatus: Equatable, Sendable {
    let selection: R13CacheLocationSelection
    let availabilityError: String?

    var isAvailable: Bool {
        availabilityError == nil
    }
}

enum R13CacheLocationError: Error, Equatable, LocalizedError, Sendable {
    case invalidDirectory
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
    case securityScopeDenied
    case locationUnavailable
    case locationNotWritable
    case configurationCorrupt
    case changeWhileJobRunning

    var errorDescription: String? {
        switch self {
        case .invalidDirectory:
            return "Choose a local folder, mounted drive, or mounted network share."
        case .bookmarkCreationFailed:
            return "Mirmir could not save permission for the selected cache location."
        case .bookmarkResolutionFailed:
            return "Mirmir could not reopen the selected cache location. Choose it again."
        case .securityScopeDenied:
            return "macOS denied access to the selected cache location. Choose it again."
        case .locationUnavailable:
            return "The selected cache location is unavailable. Connect or mount it, then retry."
        case .locationNotWritable:
            return "The selected cache location is not writable or does not support the required file operations."
        case .configurationCorrupt:
            return "The saved cache-location setting could not be verified. Choose a cache location again."
        case .changeWhileJobRunning:
            return "The cache location cannot change while an upscale is active."
        }
    }
}

struct R13ResolvedCacheLocationBookmark: Sendable {
    let url: URL
    let isStale: Bool
    let startAccessing: @Sendable () -> Bool
    let stopAccessing: @Sendable () -> Void
}

protocol R13CacheLocationBookmarkResolving: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> R13ResolvedCacheLocationBookmark
}

struct R13CacheBookmarkResolver:
    R13CacheLocationBookmarkResolving {
    func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw R13CacheLocationError.bookmarkCreationFailed
        }
    }

    func resolveBookmark(_ data: Data) throws
        -> R13ResolvedCacheLocationBookmark {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw R13CacheLocationError.bookmarkResolutionFailed
        }
        return R13ResolvedCacheLocationBookmark(
            url: resolvedURL,
            isStale: isStale,
            startAccessing: {
                resolvedURL.startAccessingSecurityScopedResource()
            },
            stopAccessing: {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        )
    }
}

final class R13CacheLocationAccess: @unchecked Sendable {
    let url: URL

    private let stopAccessing: @Sendable () -> Void

    init(resolved: R13ResolvedCacheLocationBookmark) throws {
        guard resolved.startAccessing() else {
            throw R13CacheLocationError.securityScopeDenied
        }
        url = resolved.url.standardizedFileURL
        stopAccessing = resolved.stopAccessing
    }

    deinit {
        stopAccessing()
    }
}

struct R13CacheLocationConfiguration: @unchecked Sendable {
    let trustedRootURL: URL
    let jobsRootURL: URL
    let access: R13CacheLocationAccess?
}

protocol R13CacheLocationConfiguring: Sendable {
    func cacheLocationStatus() -> R13CacheLocationStatus
    func selectCacheLocation(_ url: URL) throws -> R13CacheLocationStatus
    func useDefaultCacheLocation() throws -> R13CacheLocationStatus
}

final class R13CacheLocationStore: @unchecked Sendable {
    static let preferenceKey = "R13CacheLocationDocumentV1"

    static let maximumBookmarkBytes = 16 * 1_024 * 1_024
    static let maximumDisplayPathBytes = 16 * 1_024
    private static let cacheDirectoryName = "Mirmir",
                       jobsDirectoryName = "Jobs"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let preferenceKey: String
    private let bookmarkResolver: any R13CacheLocationBookmarkResolving
    private let defaultRootProvider: () throws -> URL

    init(
        defaults: UserDefaults = .standard,
        preferenceKey: String = R13CacheLocationStore.preferenceKey,
        bookmarkResolver: any R13CacheLocationBookmarkResolving =
            R13CacheBookmarkResolver(),
        defaultRootProvider: @escaping () throws -> URL = {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
    ) {
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        self.bookmarkResolver = bookmarkResolver
        self.defaultRootProvider = defaultRootProvider
    }

    func cacheLocationStatus() -> R13CacheLocationStatus {
        let selection: R13CacheLocationSelection
        do {
            selection = try currentSelection()
        } catch {
            return R13CacheLocationStatus(
                selection: R13CacheLocationSelection(
                    displayPath: "Configured cache location",
                    isCustom: true
                ),
                availabilityError: userFacingDescription(error)
            )
        }

        do {
            let configuration = try configuration()
            withExtendedLifetime(configuration.access) {}
            return R13CacheLocationStatus(
                selection: selection,
                availabilityError: nil
            )
        } catch {
            return R13CacheLocationStatus(
                selection: selection,
                availabilityError: userFacingDescription(error)
            )
        }
    }

    func selectCacheLocation(_ url: URL) throws
        -> R13CacheLocationStatus {
        guard url.isFileURL else {
            throw R13CacheLocationError.invalidDirectory
        }
        let selectedURL = url.standardizedFileURL
        let bookmarkData = try bookmarkResolver.makeBookmark(
            for: selectedURL
        )
        let document = try R13CacheLocationDocument(
            displayPath: selectedURL.path,
            bookmarkData: bookmarkData
        )
        let configuration = try customConfiguration(
            document,
            refreshStaleBookmark: false
        )
        try verifyWritable(configuration)
        try save(document)
        withExtendedLifetime(configuration.access) {}
        return cacheLocationStatus()
    }

    func useDefaultCacheLocation() -> R13CacheLocationStatus {
        lock.withLock {
            defaults.removeObject(forKey: preferenceKey)
        }
        return cacheLocationStatus()
    }

    func configuration() throws -> R13CacheLocationConfiguration {
        guard let document = try loadDocument() else {
            return try defaultConfiguration()
        }
        return try customConfiguration(
            document,
            refreshStaleBookmark: true
        )
    }

    private func currentSelection() throws
        -> R13CacheLocationSelection {
        if let document = try loadDocument() {
            return R13CacheLocationSelection(
                displayPath: document.displayPath,
                isCustom: true
            )
        }
        return R13CacheLocationSelection(
            displayPath: try defaultConfiguration().jobsRootURL.path,
            isCustom: false
        )
    }

    private func defaultConfiguration() throws
        -> R13CacheLocationConfiguration {
        let trustedRoot = R13RestartPath.resolvingExistingAncestor(
            of: try defaultRootProvider()
        )
        guard trustedRoot.isFileURL else {
            throw R13CacheLocationError.locationUnavailable
        }
        let jobsRoot = Self.jobsRoot(in: trustedRoot)
        let fileSystem = try makeFileSystem(trustedRoot: trustedRoot)
        try ensureJobsRoot(jobsRoot, using: fileSystem)
        return R13CacheLocationConfiguration(
            trustedRootURL: trustedRoot,
            jobsRootURL: jobsRoot,
            access: nil
        )
    }

    private func customConfiguration(
        _ document: R13CacheLocationDocument,
        refreshStaleBookmark: Bool
    ) throws -> R13CacheLocationConfiguration {
        let resolved = try bookmarkResolver.resolveBookmark(
            document.bookmarkData
        )
        let access = try R13CacheLocationAccess(resolved: resolved)
        let trustedRoot = R13RestartPath.resolvingExistingAncestor(
            of: access.url
        )
        guard isExistingDirectory(trustedRoot) else {
            throw R13CacheLocationError.locationUnavailable
        }
        let jobsRoot = Self.jobsRoot(in: trustedRoot)
        let fileSystem = try makeFileSystem(trustedRoot: trustedRoot)
        try ensureJobsRoot(jobsRoot, using: fileSystem)
        if refreshStaleBookmark, resolved.isStale {
            let refreshed = try R13CacheLocationDocument(
                displayPath: trustedRoot.path,
                bookmarkData: bookmarkResolver.makeBookmark(
                    for: trustedRoot
                )
            )
            try save(refreshed)
        }
        return R13CacheLocationConfiguration(
            trustedRootURL: trustedRoot,
            jobsRootURL: jobsRoot,
            access: access
        )
    }

    private func verifyWritable(
        _ configuration: R13CacheLocationConfiguration
    ) throws {
        let fileSystem = try makeFileSystem(
            trustedRoot: configuration.trustedRootURL
        )
        let probeURL = configuration.jobsRootURL.appendingPathComponent(
            ".write-probe-\(UUID().uuidString)"
        )
        do {
            try fileSystem.writeNewAtomically(
                Data([0]),
                to: probeURL
            )
            try fileSystem.removeFile(probeURL)
        } catch {
            try? fileSystem.removeFile(probeURL)
            throw R13CacheLocationError.locationNotWritable
        }
    }

    private func makeFileSystem(trustedRoot: URL) throws
        -> R13LocalRestartFileSystem {
        do {
            return try R13LocalRestartFileSystem(
                trustedRootURL: trustedRoot
            )
        } catch {
            throw R13CacheLocationError.locationUnavailable
        }
    }

    private func ensureJobsRoot(
        _ jobsRoot: URL,
        using fileSystem: R13LocalRestartFileSystem
    ) throws {
        do {
            try fileSystem.ensureDirectory(jobsRoot)
        } catch {
            throw R13CacheLocationError.locationNotWritable
        }
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func loadDocument() throws
        -> R13CacheLocationDocument? {
        let data = lock.withLock {
            defaults.data(forKey: preferenceKey)
        }
        guard let data else { return nil }
        do {
            let document = try JSONDecoder().decode(
                R13CacheLocationDocument.self,
                from: data
            )
            try document.validate()
            guard try R13RestartCanonical.data(document) == data else {
                throw R13CacheLocationError.configurationCorrupt
            }
            return document
        } catch let error as R13CacheLocationError {
            throw error
        } catch {
            throw R13CacheLocationError.configurationCorrupt
        }
    }

    private func save(_ document: R13CacheLocationDocument) throws {
        try document.validate()
        let data: Data
        do {
            data = try R13RestartCanonical.data(document)
        } catch {
            throw R13CacheLocationError.configurationCorrupt
        }
        lock.withLock {
            defaults.set(data, forKey: preferenceKey)
        }
    }

    private static func jobsRoot(in root: URL) -> URL {
        root.appendingPathComponent(
            cacheDirectoryName,
            isDirectory: true
        )
        .appendingPathComponent(
            jobsDirectoryName,
            isDirectory: true
        )
    }

    private func userFacingDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return R13CacheLocationError.locationUnavailable
            .localizedDescription
    }
}

private struct R13CacheLocationDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let displayPath: String
    let bookmarkData: Data

    init(displayPath: String, bookmarkData: Data) throws {
        schemaVersion = Self.currentSchemaVersion
        self.displayPath = displayPath
        self.bookmarkData = bookmarkData
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !displayPath.isEmpty,
              displayPath.utf8.count
                <= R13CacheLocationStore.maximumDisplayPathBytes,
              !bookmarkData.isEmpty,
              bookmarkData.count
                <= R13CacheLocationStore.maximumBookmarkBytes else {
            throw R13CacheLocationError.configurationCorrupt
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case displayPath = "display_path"
        case bookmarkData = "bookmark_data"
    }
}
