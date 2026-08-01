import Foundation

enum R13BookmarkRole: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case outputDirectory = "output_directory"
}

struct R13SecurityScopedBookmarkEntry: Codable, Hashable, Sendable {
    static let maximumBookmarkBytes = 16 * 1_024 * 1_024

    let role: R13BookmarkRole
    let bookmarkData: Data

    init(role: R13BookmarkRole, bookmarkData: Data) throws {
        guard !bookmarkData.isEmpty,
              bookmarkData.count <= Self.maximumBookmarkBytes else {
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        self.role = role
        self.bookmarkData = bookmarkData
    }

    func validate() throws {
        _ = try R13SecurityScopedBookmarkEntry(
            role: role,
            bookmarkData: bookmarkData
        )
    }
}

struct R13SecurityScopedAccessDocument: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let jobID: String
    let entries: [R13SecurityScopedBookmarkEntry]

    init(
        jobID: String,
        entries: [R13SecurityScopedBookmarkEntry]
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.jobID = try R13RestartValidation.jobID(jobID)
        self.entries = try Self.validatedEntries(entries)
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw R13RestartJobError.schemaMismatch(
                document: "security_scoped_access"
            )
        }
        _ = try R13RestartValidation.jobID(jobID)
        _ = try Self.validatedEntries(entries)
    }

    private static func validatedEntries(
        _ entries: [R13SecurityScopedBookmarkEntry]
    ) throws -> [R13SecurityScopedBookmarkEntry] {
        guard Set(entries.map(\.role)) == Set(R13BookmarkRole.allCases),
              entries.count == R13BookmarkRole.allCases.count else {
            throw R13RestartJobError.nonCanonicalDocument(
                "security_scoped_access_roles"
            )
        }
        for entry in entries {
            try entry.validate()
        }
        return entries.sorted { $0.role.rawValue < $1.role.rawValue }
    }
}

struct R13ResolvedSecurityScopedBookmark: Sendable {
    let url: URL
    let isStale: Bool
    let startAccessing: @Sendable () -> Bool
    let stopAccessing: @Sendable () -> Void

    init(
        url: URL,
        isStale: Bool,
        startAccessing: @escaping @Sendable () -> Bool,
        stopAccessing: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.isStale = isStale
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }
}

protocol R13SecurityScopedBookmarkResolving: Sendable {
    func makeBookmark(
        for url: URL,
        role: R13BookmarkRole
    ) throws -> Data
    func resolveBookmark(
        _ data: Data,
        role: R13BookmarkRole
    ) throws -> R13ResolvedSecurityScopedBookmark
}

struct R13FoundationBookmarkResolver:
    R13SecurityScopedBookmarkResolving {
    func makeBookmark(
        for url: URL,
        role: R13BookmarkRole
    ) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw R13RestartJobError.bookmarkCreationFailed(role: role)
        }
    }

    func resolveBookmark(
        _ data: Data,
        role: R13BookmarkRole
    ) throws -> R13ResolvedSecurityScopedBookmark {
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
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        return R13ResolvedSecurityScopedBookmark(
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

final class R13SecurityScopeLease: @unchecked Sendable {
    let role: R13BookmarkRole
    let url: URL

    private let stopAccessing: @Sendable () -> Void

    init(
        role: R13BookmarkRole,
        resolved: R13ResolvedSecurityScopedBookmark
    ) throws {
        guard resolved.startAccessing() else {
            throw R13RestartJobError.securityScopeDenied(role: role)
        }
        self.role = role
        self.url = resolved.url
        self.stopAccessing = resolved.stopAccessing
    }

    deinit {
        stopAccessing()
    }
}

final class R13SecurityScopedAccessSet: @unchecked Sendable {
    private let lock = NSLock()
    private var leases: [R13SecurityScopeLease]

    init(leases: [R13SecurityScopeLease]) {
        self.leases = leases
    }

    func releaseOutputDirectory() {
        let releasedLease = lock.withLock {
            guard let index = leases.firstIndex(
                where: { $0.role == .outputDirectory }
            ) else {
                return nil as R13SecurityScopeLease?
            }
            return leases.remove(at: index)
        }
        withExtendedLifetime(releasedLease) {}
    }

    func url(for role: R13BookmarkRole) -> URL {
        lock.withLock {
            guard let lease = leases.first(where: { $0.role == role }) else {
                preconditionFailure(
                    "Active R13 access sets contain the requested role."
                )
            }
            return lease.url
        }
    }
}

actor R13SecurityScopedBookmarkStore {
    private static let maximumDocumentBytes =
        2 * R13SecurityScopedBookmarkEntry.maximumBookmarkBytes + 4_096

    private let jobsRootURL: URL
    private let fileSystem: any R13RestartFileSystem

    init(
        jobsRootURL: URL,
        fileSystem: any R13RestartFileSystem = R13LocalRestartFileSystem()
    ) {
        self.jobsRootURL = R13RestartPath.resolvingExistingAncestor(
            of: jobsRootURL
        )
        self.fileSystem = fileSystem
    }

    func save(
        jobID: String,
        sourceURL: URL,
        outputDirectoryURL: URL,
        resolver: any R13SecurityScopedBookmarkResolving =
            R13FoundationBookmarkResolver()
    ) throws {
        let entries = try [
            R13SecurityScopedBookmarkEntry(
                role: .source,
                bookmarkData: resolver.makeBookmark(
                    for: sourceURL,
                    role: .source
                )
            ),
            R13SecurityScopedBookmarkEntry(
                role: .outputDirectory,
                bookmarkData: resolver.makeBookmark(
                    for: outputDirectoryURL,
                    role: .outputDirectory
                )
            )
        ]
        try save(
            R13SecurityScopedAccessDocument(jobID: jobID, entries: entries)
        )
    }

    func save(_ document: R13SecurityScopedAccessDocument) throws {
        try document.validate()
        let jobDirectoryURL = try jobDirectory(for: document.jobID)
        try fileSystem.validateDirectory(jobDirectoryURL)
        let accessDirectoryURL = jobDirectoryURL.appendingPathComponent(
            "access",
            isDirectory: true
        )
        try fileSystem.ensureDirectory(accessDirectoryURL)
        let documentURL = accessDirectoryURL.appendingPathComponent(
            "access-v1.json"
        )
        let data = try R13RestartCanonical.data(document)
        if fileSystem.exists(documentURL) {
            try fileSystem.replaceAtomically(data, at: documentURL)
        } else {
            try fileSystem.writeNewAtomically(data, to: documentURL)
        }
    }

    func resolveAccess(
        jobID: String,
        resolver: any R13SecurityScopedBookmarkResolving =
            R13FoundationBookmarkResolver()
    ) throws -> R13SecurityScopedAccessSet {
        let document = try loadDocument(jobID: jobID)
        var leases: [R13SecurityScopeLease] = []
        var resolutions: [
            (
                entry: R13SecurityScopedBookmarkEntry,
                resolved: R13ResolvedSecurityScopedBookmark
            )
        ] = []
        for entry in document.entries {
            let resolved = try resolver.resolveBookmark(
                entry.bookmarkData,
                role: entry.role
            )
            leases.append(
                try R13SecurityScopeLease(
                    role: entry.role,
                    resolved: resolved
                )
            )
            resolutions.append((entry: entry, resolved: resolved))
        }

        var didRefreshBookmark = false
        let refreshedEntries = try resolutions.map { resolution in
            guard resolution.resolved.isStale else {
                return resolution.entry
            }
            didRefreshBookmark = true
            return try R13SecurityScopedBookmarkEntry(
                role: resolution.entry.role,
                bookmarkData: resolver.makeBookmark(
                    for: resolution.resolved.url,
                    role: resolution.entry.role
                )
            )
        }
        if didRefreshBookmark {
            try save(
                R13SecurityScopedAccessDocument(
                    jobID: document.jobID,
                    entries: refreshedEntries
                )
            )
        }
        return R13SecurityScopedAccessSet(leases: leases)
    }

    func validateAccessDocument(jobID: String) throws {
        _ = try loadDocument(jobID: jobID)
    }

    private func jobDirectory(for jobID: String) throws -> URL {
        let validatedJobID = try R13RestartValidation.jobID(jobID)
        return jobsRootURL.appendingPathComponent(
            validatedJobID,
            isDirectory: true
        )
    }

    private func loadDocument(
        jobID: String
    ) throws -> R13SecurityScopedAccessDocument {
        let validatedJobID = try R13RestartValidation.jobID(jobID)
        let documentURL = try jobDirectory(for: validatedJobID)
            .appendingPathComponent("access", isDirectory: true)
            .appendingPathComponent("access-v1.json")
        let data = try fileSystem.readRegularFile(
            documentURL,
            maximumBytes: Self.maximumDocumentBytes
        )
        let document: R13SecurityScopedAccessDocument
        do {
            document = try JSONDecoder().decode(
                R13SecurityScopedAccessDocument.self,
                from: data
            )
        } catch {
            throw R13RestartJobError.nonCanonicalDocument(
                "security_scoped_access"
            )
        }
        guard try R13RestartCanonical.data(document) == data else {
            throw R13RestartJobError.nonCanonicalDocument(
                "security_scoped_access"
            )
        }
        try document.validate()
        guard document.jobID == validatedJobID else {
            throw R13RestartJobError.immutableCoreMismatch
        }
        return document
    }
}
