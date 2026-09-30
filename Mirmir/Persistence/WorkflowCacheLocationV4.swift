import Darwin
import Foundation

struct WorkflowCacheLocationStatusV4: Equatable, Sendable {
    let path: String
    let isCustom: Bool
    let availabilityError: String?

    var isAvailable: Bool { availabilityError == nil }
}

enum WorkflowCacheLocationErrorV4: Error, Equatable, LocalizedError {
    case invalidApplicationIdentifier
    case invalidDirectory
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
    case securityScopeDenied
    case locationUnavailable
    case locationNotWritable
    case configurationCorrupt
    case jobsMustBeClearedFirst

    var errorDescription: String? {
        switch self {
        case .invalidApplicationIdentifier:
            "The application cache identifier is invalid."
        case .invalidDirectory:
            "Choose a local folder, mounted drive, or mounted network share."
        case .bookmarkCreationFailed:
            "Mirmir could not save permission for the selected cache location."
        case .bookmarkResolutionFailed:
            "Mirmir could not reopen the selected cache location. Choose it again."
        case .securityScopeDenied:
            "macOS denied access to the selected cache location. Choose it again."
        case .locationUnavailable:
            "The selected cache location is unavailable. Connect or mount it, then retry."
        case .locationNotWritable:
            "The selected cache location is not writable or does not support the required atomic file operations."
        case .configurationCorrupt:
            "The saved cache-location setting could not be verified. Choose a cache location again."
        case .jobsMustBeClearedFirst:
            "Delete the jobs stored in the current cache before changing its location."
        }
    }
}

struct WorkflowResolvedCacheBookmarkV4: Sendable {
    let url: URL
    let isStale: Bool
    let startAccessing: @Sendable () -> Bool
    let stopAccessing: @Sendable () -> Void
}

protocol WorkflowCacheBookmarkResolvingV4: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> WorkflowResolvedCacheBookmarkV4
}

struct WorkflowFoundationCacheBookmarkResolverV4:
    WorkflowCacheBookmarkResolvingV4 {
    func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw WorkflowCacheLocationErrorV4.bookmarkCreationFailed
        }
    }

    func resolveBookmark(
        _ data: Data
    ) throws -> WorkflowResolvedCacheBookmarkV4 {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw WorkflowCacheLocationErrorV4.bookmarkResolutionFailed
        }
        return WorkflowResolvedCacheBookmarkV4(
            url: url,
            isStale: isStale,
            startAccessing: {
                url.startAccessingSecurityScopedResource()
            },
            stopAccessing: {
                url.stopAccessingSecurityScopedResource()
            }
        )
    }
}

final class WorkflowCacheLocationAccessV4: @unchecked Sendable {
    let selectedDirectoryURL: URL

    private let stopAccessing: @Sendable () -> Void

    init(resolved: WorkflowResolvedCacheBookmarkV4) throws {
        guard resolved.startAccessing() else {
            throw WorkflowCacheLocationErrorV4.securityScopeDenied
        }
        selectedDirectoryURL = resolved.url.standardizedFileURL
        stopAccessing = resolved.stopAccessing
    }

    deinit {
        stopAccessing()
    }
}

struct WorkflowCacheLocationConfigurationV4: @unchecked Sendable {
    let workflowRootURL: URL
    let isCustom: Bool
    let access: WorkflowCacheLocationAccessV4?
}

struct WorkflowCacheLocationPreferenceSnapshotV4: Sendable {
    fileprivate let data: Data?
}

final class WorkflowCacheLocationStoreV4: @unchecked Sendable {
    static let preferenceKey = "Mirmir.WorkflowCacheLocation.v1"

    fileprivate static let maximumBookmarkBytes = 16 * 1_024 * 1_024
    fileprivate static let maximumPathBytes = 16 * 1_024

    private let lock = NSLock()
    private let applicationIdentifier: String
    private let defaults: UserDefaults
    private let preferenceKey: String
    private let bookmarkResolver: any WorkflowCacheBookmarkResolvingV4
    private let defaultApplicationSupportProvider: @Sendable () throws -> URL

    init(
        applicationIdentifier: String,
        defaults: UserDefaults = .standard,
        preferenceKey: String = WorkflowCacheLocationStoreV4.preferenceKey,
        bookmarkResolver: any WorkflowCacheBookmarkResolvingV4 =
            WorkflowFoundationCacheBookmarkResolverV4(),
        defaultApplicationSupportProvider:
            @escaping @Sendable () throws -> URL = {
                try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            }
    ) throws {
        guard WorkflowV4Validation.isIdentifier(applicationIdentifier),
              !applicationIdentifier.contains(":"),
              !applicationIdentifier.contains("/") else {
            throw WorkflowCacheLocationErrorV4.invalidApplicationIdentifier
        }
        self.applicationIdentifier = applicationIdentifier
        self.defaults = defaults
        self.preferenceKey = preferenceKey
        self.bookmarkResolver = bookmarkResolver
        self.defaultApplicationSupportProvider =
            defaultApplicationSupportProvider
    }

    func status() -> WorkflowCacheLocationStatusV4 {
        do {
            let configuration = try configuration()
            defer { withExtendedLifetime(configuration.access) {} }
            return WorkflowCacheLocationStatusV4(
                path: configuration.workflowRootURL.path,
                isCustom: configuration.isCustom,
                availabilityError: nil
            )
        } catch {
            let document = try? loadDocument()
            return WorkflowCacheLocationStatusV4(
                path: document?.selectedDirectoryPath
                    ?? "Configured cache location",
                isCustom: document != nil,
                availabilityError: Self.userFacingDescription(error)
            )
        }
    }

    func preferenceSnapshot() -> WorkflowCacheLocationPreferenceSnapshotV4 {
        WorkflowCacheLocationPreferenceSnapshotV4(
            data: lock.withLock { defaults.data(forKey: preferenceKey) }
        )
    }

    func restorePreference(
        _ snapshot: WorkflowCacheLocationPreferenceSnapshotV4
    ) {
        lock.withLock {
            if let data = snapshot.data {
                defaults.set(data, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }
    }

    func select(_ selectedDirectoryURL: URL) throws
        -> WorkflowCacheLocationConfigurationV4 {
        guard selectedDirectoryURL.isFileURL else {
            throw WorkflowCacheLocationErrorV4.invalidDirectory
        }
        let selected = selectedDirectoryURL.standardizedFileURL
        guard Self.isExistingDirectory(selected) else {
            throw WorkflowCacheLocationErrorV4.invalidDirectory
        }
        let bookmark = try bookmarkResolver.makeBookmark(for: selected)
        let document = try WorkflowCacheLocationDocumentV4(
            selectedDirectoryPath: selected.path,
            bookmarkData: bookmark
        )
        let configuration = try customConfiguration(
            document,
            refreshStaleBookmark: false
        )
        try verifyWritable(configuration.workflowRootURL)
        try save(document)
        return configuration
    }

    func useDefault() throws -> WorkflowCacheLocationConfigurationV4 {
        let configuration = try defaultConfiguration()
        try verifyWritable(configuration.workflowRootURL)
        lock.withLock {
            defaults.removeObject(forKey: preferenceKey)
        }
        return configuration
    }

    func configuration() throws -> WorkflowCacheLocationConfigurationV4 {
        guard let document = try loadDocument() else {
            return try defaultConfiguration()
        }
        return try customConfiguration(
            document,
            refreshStaleBookmark: true
        )
    }

    private func defaultConfiguration() throws
        -> WorkflowCacheLocationConfigurationV4 {
        let base: URL
        do {
            base = try defaultApplicationSupportProvider()
        } catch {
            throw WorkflowCacheLocationErrorV4.locationUnavailable
        }
        let root = base.standardizedFileURL
            .appendingPathComponent(applicationIdentifier, isDirectory: true)
            .appendingPathComponent("WorkflowV4", isDirectory: true)
        let prepared: URL
        do {
            prepared = try Self.prepareRoot(root)
        } catch {
            throw WorkflowCacheLocationErrorV4.locationNotWritable
        }
        return WorkflowCacheLocationConfigurationV4(
            workflowRootURL: prepared,
            isCustom: false,
            access: nil
        )
    }

    private func customConfiguration(
        _ document: WorkflowCacheLocationDocumentV4,
        refreshStaleBookmark: Bool
    ) throws -> WorkflowCacheLocationConfigurationV4 {
        let resolved = try bookmarkResolver.resolveBookmark(
            document.bookmarkData
        )
        let access = try WorkflowCacheLocationAccessV4(resolved: resolved)
        let selected = access.selectedDirectoryURL
        guard Self.isExistingDirectory(selected) else {
            throw WorkflowCacheLocationErrorV4.locationUnavailable
        }
        let root = selected
            .appendingPathComponent("Mirmir", isDirectory: true)
            .appendingPathComponent("WorkflowV4", isDirectory: true)
        let prepared: URL
        do {
            prepared = try Self.prepareRoot(root)
        } catch {
            throw WorkflowCacheLocationErrorV4.locationNotWritable
        }
        if refreshStaleBookmark, resolved.isStale {
            let refreshed = try WorkflowCacheLocationDocumentV4(
                selectedDirectoryPath: selected.path,
                bookmarkData: bookmarkResolver.makeBookmark(for: selected)
            )
            try save(refreshed)
        }
        return WorkflowCacheLocationConfigurationV4(
            workflowRootURL: prepared,
            isCustom: true,
            access: access
        )
    }

    private func verifyWritable(_ root: URL) throws {
        let fileSystem: WorkflowLocalDurableFileSystem
        do {
            fileSystem = try WorkflowLocalDurableFileSystem(
                trustedRootURL: root
            )
        } catch {
            throw WorkflowCacheLocationErrorV4.locationNotWritable
        }
        let probe = root.appendingPathComponent(
            ".cache-location-write-probe-\(UUID().uuidString.lowercased())"
        )
        do {
            try fileSystem.writeNewAtomically(Data([0]), to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw WorkflowCacheLocationErrorV4.locationNotWritable
        }
    }

    private func loadDocument() throws -> WorkflowCacheLocationDocumentV4? {
        let data = lock.withLock { defaults.data(forKey: preferenceKey) }
        guard let data else { return nil }
        do {
            let document = try JSONDecoder().decode(
                WorkflowCacheLocationDocumentV4.self,
                from: data
            )
            try document.validate()
            guard try Self.canonicalData(document) == data else {
                throw WorkflowCacheLocationErrorV4.configurationCorrupt
            }
            return document
        } catch let error as WorkflowCacheLocationErrorV4 {
            throw error
        } catch {
            throw WorkflowCacheLocationErrorV4.configurationCorrupt
        }
    }

    private func save(_ document: WorkflowCacheLocationDocumentV4) throws {
        try document.validate()
        let data: Data
        do {
            data = try Self.canonicalData(document)
        } catch {
            throw WorkflowCacheLocationErrorV4.configurationCorrupt
        }
        lock.withLock {
            defaults.set(data, forKey: preferenceKey)
        }
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func prepareRoot(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw WorkflowCacheLocationErrorV4.invalidDirectory
        }
        var before = stat()
        if lstat(candidate.path, &before) == 0 {
            guard (before.st_mode & S_IFMT) == S_IFDIR,
                  (before.st_mode & S_IFMT) != S_IFLNK else {
                throw WorkflowCacheLocationErrorV4.locationNotWritable
            }
        } else {
            guard errno == ENOENT else {
                throw WorkflowCacheLocationErrorV4.locationNotWritable
            }
            do {
                try FileManager.default.createDirectory(
                    at: candidate,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw WorkflowCacheLocationErrorV4.locationNotWritable
            }
        }
        let resolved = candidate.resolvingSymlinksInPath()
        var after = stat()
        guard lstat(resolved.path, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFDIR,
              (after.st_mode & S_IFMT) != S_IFLNK else {
            throw WorkflowCacheLocationErrorV4.locationNotWritable
        }
        return resolved
    }

    private static func userFacingDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return WorkflowCacheLocationErrorV4.locationUnavailable
            .localizedDescription
    }
}

private struct WorkflowCacheLocationDocumentV4: Codable, Equatable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let selectedDirectoryPath: String
    let bookmarkData: Data

    init(selectedDirectoryPath: String, bookmarkData: Data) throws {
        schemaVersion = Self.currentSchemaVersion
        self.selectedDirectoryPath = selectedDirectoryPath
        self.bookmarkData = bookmarkData
        try validate()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              selectedDirectoryPath.hasPrefix("/"),
              selectedDirectoryPath.utf8.count
                <= WorkflowCacheLocationStoreV4.maximumPathBytes,
              !bookmarkData.isEmpty,
              bookmarkData.count
                <= WorkflowCacheLocationStoreV4.maximumBookmarkBytes else {
            throw WorkflowCacheLocationErrorV4.configurationCorrupt
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case selectedDirectoryPath = "selected_directory_path"
        case bookmarkData = "bookmark_data"
    }
}
