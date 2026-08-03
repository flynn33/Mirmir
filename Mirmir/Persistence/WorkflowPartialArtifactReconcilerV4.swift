import Darwin
import Foundation

/// A capability value whose lifetime is bounded by an already active security
/// scope. Production callers must retain their `startAccessingSecurityScopedResource`
/// access until reconciliation returns; the reconciler never discovers or
/// traverses directories that are not represented by one of these values.
struct WorkflowActivatedOutputScopeV4: Equatable, Hashable, Sendable {
    let bookmark: WorkflowBookmarkReference
    let directoryURL: URL
    fileprivate let directoryIdentity: WorkflowFileIdentityV4

    init(
        bookmark: WorkflowBookmarkReference,
        activatedDirectoryURL: URL
    ) throws {
        var metadata = stat()
        guard activatedDirectoryURL.isFileURL,
              lstat(activatedDirectoryURL.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw WorkflowPartialReconciliationErrorV4.unsafeScope(
                activatedDirectoryURL.path
            )
        }
        self.bookmark = bookmark
        directoryURL = activatedDirectoryURL.standardizedFileURL
        directoryIdentity = WorkflowFileIdentityV4(
            device: UInt64(metadata.st_dev),
            fileID: UInt64(metadata.st_ino)
        )
    }
}

enum WorkflowPartialScavengingPolicyV4: String, Codable, Sendable {
    /// Registered and legacy-recognizable Mirmir partials are atomically moved
    /// into a visible recovery directory. This is the production default.
    case quarantineAllOwned = "quarantine_all_owned"

    /// Exact registry/inode matches may be deleted. Legacy recognizable files
    /// are still quarantined because filename provenance alone is insufficient
    /// authority for deletion.
    case removeRegisteredQuarantineLegacy =
        "remove_registered_quarantine_legacy"
}

enum WorkflowPartialReconciliationDispositionV4:
    String,
    Codable,
    Equatable,
    Sendable
{
    case registeredQuarantined = "registered_quarantined"
    case registeredRemoved = "registered_removed"
    case alreadyQuarantined = "already_quarantined"
    case registeredMissing = "registered_missing"
    case legacyQuarantined = "legacy_quarantined"
    case foreignIgnored = "foreign_ignored"
    case ownershipMismatchContained = "ownership_mismatch_contained"
    case unsafeEntryContained = "unsafe_entry_contained"
    case quarantineConflictContained = "quarantine_conflict_contained"
}

struct WorkflowPartialReconciliationReceiptV4:
    Codable,
    Equatable,
    Sendable
{
    let outputBookmark: WorkflowBookmarkReference
    let artifactID: WorkflowArtifactIDV4?
    let sourceFileName: String
    let disposition: WorkflowPartialReconciliationDispositionV4
    let quarantineFileName: String?
    let observedIdentity: WorkflowFileIdentityV4?
}

struct WorkflowPartialReconciliationReportV4:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let receipts: [WorkflowPartialReconciliationReceiptV4]

    init(receipts: [WorkflowPartialReconciliationReceiptV4]) {
        schemaVersion = Self.currentSchemaVersion
        self.receipts = receipts.sorted(by: Self.receiptOrder)
    }

    var containedFailureCount: Int {
        receipts.filter {
            switch $0.disposition {
            case .ownershipMismatchContained,
                 .unsafeEntryContained,
                 .quarantineConflictContained:
                true
            case .registeredQuarantined,
                 .registeredRemoved,
                 .alreadyQuarantined,
                 .registeredMissing,
                 .legacyQuarantined,
                 .foreignIgnored:
                false
            }
        }.count
    }

    private static func receiptOrder(
        _ lhs: WorkflowPartialReconciliationReceiptV4,
        _ rhs: WorkflowPartialReconciliationReceiptV4
    ) -> Bool {
        if lhs.outputBookmark.bookmarkID != rhs.outputBookmark.bookmarkID {
            return lhs.outputBookmark.bookmarkID < rhs.outputBookmark.bookmarkID
        }
        if lhs.outputBookmark.revision != rhs.outputBookmark.revision {
            return lhs.outputBookmark.revision < rhs.outputBookmark.revision
        }
        if lhs.sourceFileName != rhs.sourceFileName {
            return lhs.sourceFileName < rhs.sourceFileName
        }
        return (lhs.artifactID?.rawValue ?? "")
            < (rhs.artifactID?.rawValue ?? "")
    }
}

enum WorkflowPartialReconciliationErrorV4:
    Error,
    Equatable,
    LocalizedError
{
    case unsafeScope(String)
    case duplicateScope(WorkflowBookmarkReference)
    case registrationWithoutScope(WorkflowArtifactIDV4)
    case duplicateRegistration(String)
    case enumerationFailed(String)
    case quarantineDirectoryUnsafe(String)
    case filesystemFailure(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case let .unsafeScope(path):
            "Recovery output scope is unsafe or changed identity: \(path)"
        case let .duplicateScope(bookmark):
            "Output bookmark \(bookmark.bookmarkID) was activated more than once."
        case let .registrationWithoutScope(artifactID):
            "Registered artifact \(artifactID) has no activated output scope."
        case let .duplicateRegistration(name):
            "Partial artifact ownership is ambiguous for \(name)."
        case let .enumerationFailed(path):
            "Could not enumerate activated output scope \(path)."
        case let .quarantineDirectoryUnsafe(path):
            "Recovery quarantine directory is unsafe: \(path)"
        case let .filesystemFailure(operation, path, code):
            "Recovery filesystem operation \(operation) failed for \(path) with errno \(code)."
        }
    }
}

struct WorkflowPartialArtifactReconcilerV4: Sendable {
    static let quarantineDirectoryName = "Mirmir Recovered Partials"

    func reconcile(
        registrations: [WorkflowOwnedPartialArtifactV4],
        activatedScopes: [WorkflowActivatedOutputScopeV4],
        policy: WorkflowPartialScavengingPolicyV4 = .quarantineAllOwned
    ) throws -> WorkflowPartialReconciliationReportV4 {
        let scopeMap = try validatedScopeMap(activatedScopes)
        let registrationMap = try validatedRegistrationMap(
            registrations,
            scopeMap: scopeMap
        )
        var receipts: [WorkflowPartialReconciliationReceiptV4] = []

        for scope in activatedScopes.sorted(by: Self.scopeOrder) {
            try validateScopeIdentity(scope)
            let entries = try directoryEntryNames(scope).sorted()
            let scopedRegistrations = registrations
                .filter { $0.outputBookmark == scope.bookmark }
                .sorted { $0.fileName < $1.fileName }
            let registrationByName = Dictionary(
                uniqueKeysWithValues: scopedRegistrations.map {
                    ($0.fileName, $0)
                }
            )

            for registration in scopedRegistrations {
                receipts.append(
                    try reconcileRegistered(
                        registration,
                        scope: scope,
                        policy: policy
                    )
                )
            }

            for name in entries where registrationByName[name] == nil {
                if WorkflowV4Validation.isMirmirPartialFileName(name) {
                    receipts.append(try reconcileLegacy(name, scope: scope))
                } else if Self.isForeignPartialName(name) {
                    receipts.append(
                        WorkflowPartialReconciliationReceiptV4(
                            outputBookmark: scope.bookmark,
                            artifactID: nil,
                            sourceFileName: name,
                            disposition: .foreignIgnored,
                            quarantineFileName: nil,
                            observedIdentity: observedIdentity(
                                at: scope.directoryURL.appendingPathComponent(name)
                            )
                        )
                    )
                }
            }
            try validateScopeIdentity(scope)
        }

        // Keep the validation values live through the mutation pass. This also
        // makes an accidental removal of the cross-scope checks test-visible.
        precondition(registrationMap.count == registrations.count)
        return WorkflowPartialReconciliationReportV4(receipts: receipts)
    }
}

private extension WorkflowPartialArtifactReconcilerV4 {
    struct RegistrationKey: Hashable {
        let bookmark: WorkflowBookmarkReference
        let fileName: String
    }

    static func scopeOrder(
        _ lhs: WorkflowActivatedOutputScopeV4,
        _ rhs: WorkflowActivatedOutputScopeV4
    ) -> Bool {
        if lhs.bookmark.bookmarkID != rhs.bookmark.bookmarkID {
            return lhs.bookmark.bookmarkID < rhs.bookmark.bookmarkID
        }
        return lhs.bookmark.revision < rhs.bookmark.revision
    }

    static func isForeignPartialName(_ value: String) -> Bool {
        value.hasSuffix(".partial.mov") || value.contains(".partial.")
    }

    func validatedScopeMap(
        _ scopes: [WorkflowActivatedOutputScopeV4]
    ) throws -> [WorkflowBookmarkReference: WorkflowActivatedOutputScopeV4] {
        var result: [WorkflowBookmarkReference: WorkflowActivatedOutputScopeV4] = [:]
        for scope in scopes {
            guard result.updateValue(scope, forKey: scope.bookmark) == nil else {
                throw WorkflowPartialReconciliationErrorV4.duplicateScope(
                    scope.bookmark
                )
            }
        }
        return result
    }

    func validatedRegistrationMap(
        _ registrations: [WorkflowOwnedPartialArtifactV4],
        scopeMap: [WorkflowBookmarkReference: WorkflowActivatedOutputScopeV4]
    ) throws -> [RegistrationKey: WorkflowOwnedPartialArtifactV4] {
        var result: [RegistrationKey: WorkflowOwnedPartialArtifactV4] = [:]
        var artifactIDs: Set<WorkflowArtifactIDV4> = []
        for registration in registrations {
            guard scopeMap[registration.outputBookmark] != nil else {
                throw WorkflowPartialReconciliationErrorV4
                    .registrationWithoutScope(registration.artifactID)
            }
            let key = RegistrationKey(
                bookmark: registration.outputBookmark,
                fileName: registration.fileName
            )
            guard result.updateValue(registration, forKey: key) == nil,
                  artifactIDs.insert(registration.artifactID).inserted else {
                throw WorkflowPartialReconciliationErrorV4
                    .duplicateRegistration(registration.fileName)
            }
        }
        return result
    }

    func directoryEntryNames(
        _ scope: WorkflowActivatedOutputScopeV4
    ) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(
                atPath: scope.directoryURL.path
            ).filter { $0 != Self.quarantineDirectoryName }
        } catch {
            throw WorkflowPartialReconciliationErrorV4.enumerationFailed(
                scope.directoryURL.path
            )
        }
    }

    func validateScopeIdentity(
        _ scope: WorkflowActivatedOutputScopeV4
    ) throws {
        var metadata = stat()
        guard lstat(scope.directoryURL.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              WorkflowFileIdentityV4(
                  device: UInt64(metadata.st_dev),
                  fileID: UInt64(metadata.st_ino)
              ) == scope.directoryIdentity else {
            throw WorkflowPartialReconciliationErrorV4.unsafeScope(
                scope.directoryURL.path
            )
        }
    }

    func reconcileRegistered(
        _ registration: WorkflowOwnedPartialArtifactV4,
        scope: WorkflowActivatedOutputScopeV4,
        policy: WorkflowPartialScavengingPolicyV4
    ) throws -> WorkflowPartialReconciliationReceiptV4 {
        let sourceURL = scope.directoryURL.appendingPathComponent(
            registration.fileName
        )
        let quarantineName = registeredQuarantineName(registration)
        let quarantineURL = scope.directoryURL
            .appendingPathComponent(Self.quarantineDirectoryName, isDirectory: true)
            .appendingPathComponent(quarantineName)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            if observedIdentity(at: quarantineURL) == registration.fileIdentity {
                return WorkflowPartialReconciliationReceiptV4(
                    outputBookmark: scope.bookmark,
                    artifactID: registration.artifactID,
                    sourceFileName: registration.fileName,
                    disposition: .alreadyQuarantined,
                    quarantineFileName: quarantineName,
                    observedIdentity: registration.fileIdentity
                )
            }
            return WorkflowPartialReconciliationReceiptV4(
                outputBookmark: scope.bookmark,
                artifactID: registration.artifactID,
                sourceFileName: registration.fileName,
                disposition: .registeredMissing,
                quarantineFileName: nil,
                observedIdentity: nil
            )
        }

        guard let identity = observedIdentity(at: sourceURL) else {
            return WorkflowPartialReconciliationReceiptV4(
                outputBookmark: scope.bookmark,
                artifactID: registration.artifactID,
                sourceFileName: registration.fileName,
                disposition: .unsafeEntryContained,
                quarantineFileName: nil,
                observedIdentity: nil
            )
        }
        guard identity == registration.fileIdentity else {
            return WorkflowPartialReconciliationReceiptV4(
                outputBookmark: scope.bookmark,
                artifactID: registration.artifactID,
                sourceFileName: registration.fileName,
                disposition: .ownershipMismatchContained,
                quarantineFileName: nil,
                observedIdentity: identity
            )
        }

        switch policy {
        case .quarantineAllOwned:
            let disposition = try quarantine(
                sourceURL: sourceURL,
                sourceName: registration.fileName,
                expectedIdentity: identity,
                quarantineName: quarantineName,
                scope: scope
            )
            return WorkflowPartialReconciliationReceiptV4(
                outputBookmark: scope.bookmark,
                artifactID: registration.artifactID,
                sourceFileName: registration.fileName,
                disposition: disposition,
                quarantineFileName:
                    disposition == .quarantineConflictContained
                        ? nil
                        : quarantineName,
                observedIdentity: identity
            )
        case .removeRegisteredQuarantineLegacy:
            try remove(
                sourceURL: sourceURL,
                expectedIdentity: identity,
                scope: scope
            )
            return WorkflowPartialReconciliationReceiptV4(
                outputBookmark: scope.bookmark,
                artifactID: registration.artifactID,
                sourceFileName: registration.fileName,
                disposition: .registeredRemoved,
                quarantineFileName: nil,
                observedIdentity: identity
            )
        }
    }

    func reconcileLegacy(
        _ fileName: String,
        scope: WorkflowActivatedOutputScopeV4
    ) throws -> WorkflowPartialReconciliationReceiptV4 {
        let sourceURL = scope.directoryURL.appendingPathComponent(fileName)
        guard let identity = observedIdentity(at: sourceURL) else {
            return WorkflowPartialReconciliationReceiptV4(
                outputBookmark: scope.bookmark,
                artifactID: nil,
                sourceFileName: fileName,
                disposition: .unsafeEntryContained,
                quarantineFileName: nil,
                observedIdentity: nil
            )
        }
        let quarantineName = legacyQuarantineName(
            fileName: fileName,
            identity: identity
        )
        let disposition = try quarantine(
            sourceURL: sourceURL,
            sourceName: fileName,
            expectedIdentity: identity,
            quarantineName: quarantineName,
            scope: scope
        )
        return WorkflowPartialReconciliationReceiptV4(
            outputBookmark: scope.bookmark,
            artifactID: nil,
            sourceFileName: fileName,
            disposition:
                disposition == .registeredQuarantined
                    ? .legacyQuarantined
                    : disposition,
            quarantineFileName:
                disposition == .quarantineConflictContained
                    ? nil
                    : quarantineName,
            observedIdentity: identity
        )
    }

    func quarantine(
        sourceURL: URL,
        sourceName: String,
        expectedIdentity: WorkflowFileIdentityV4,
        quarantineName: String,
        scope: WorkflowActivatedOutputScopeV4
    ) throws -> WorkflowPartialReconciliationDispositionV4 {
        let quarantineDirectory = scope.directoryURL.appendingPathComponent(
            Self.quarantineDirectoryName,
            isDirectory: true
        )
        try ensureQuarantineDirectory(quarantineDirectory, scope: scope)
        let destinationURL = quarantineDirectory.appendingPathComponent(
            quarantineName
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            if observedIdentity(at: destinationURL) == expectedIdentity,
               !FileManager.default.fileExists(atPath: sourceURL.path) {
                return .alreadyQuarantined
            }
            return .quarantineConflictContained
        }

        guard observedIdentity(at: sourceURL) == expectedIdentity else {
            return .ownershipMismatchContained
        }
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            return .quarantineConflictContained
        }
        guard observedIdentity(at: destinationURL) == expectedIdentity,
              !FileManager.default.fileExists(atPath: sourceURL.path) else {
            return .quarantineConflictContained
        }
        try synchronizeDirectory(quarantineDirectory)
        try synchronizeDirectory(scope.directoryURL)
        _ = sourceName
        return .registeredQuarantined
    }

    func remove(
        sourceURL: URL,
        expectedIdentity: WorkflowFileIdentityV4,
        scope: WorkflowActivatedOutputScopeV4
    ) throws {
        guard observedIdentity(at: sourceURL) == expectedIdentity else {
            throw WorkflowPartialReconciliationErrorV4.filesystemFailure(
                operation: "remove_identity_check",
                path: sourceURL.path,
                code: ESTALE
            )
        }
        do {
            try FileManager.default.removeItem(at: sourceURL)
        } catch {
            throw WorkflowPartialReconciliationErrorV4.filesystemFailure(
                operation: "remove",
                path: sourceURL.path,
                code: errno
            )
        }
        try synchronizeDirectory(scope.directoryURL)
    }

    func ensureQuarantineDirectory(
        _ url: URL,
        scope: WorkflowActivatedOutputScopeV4
    ) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw WorkflowPartialReconciliationErrorV4
                    .quarantineDirectoryUnsafe(url.path)
            }
            return
        }
        guard errno == ENOENT else {
            throw WorkflowPartialReconciliationErrorV4
                .quarantineDirectoryUnsafe(url.path)
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WorkflowPartialReconciliationErrorV4
                .quarantineDirectoryUnsafe(url.path)
        }
        try synchronizeDirectory(scope.directoryURL)
    }

    func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WorkflowPartialReconciliationErrorV4.filesystemFailure(
                operation: "directory_open",
                path: url.path,
                code: errno
            )
        }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw WorkflowPartialReconciliationErrorV4.filesystemFailure(
                operation: "directory_sync",
                path: url.path,
                code: errno
            )
        }
    }

    func registeredQuarantineName(
        _ registration: WorkflowOwnedPartialArtifactV4
    ) -> String {
        "registered-\(registration.artifactID.rawValue).recovered.mov"
    }

    func legacyQuarantineName(
        fileName: String,
        identity: WorkflowFileIdentityV4
    ) -> String {
        let material = Data(
            "\(identity.device):\(identity.fileID):\(fileName)".utf8
        )
        let digest = WorkflowV4Validation.domainSeparatedSHA256(
            domain: "Mirmir.LegacyPartialNameV4\u{0}",
            data: material
        )
        return "legacy-\(digest.prefix(24)).recovered.mov"
    }

    func observedIdentity(at url: URL) -> WorkflowFileIdentityV4? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            return nil
        }
        return WorkflowFileIdentityV4(
            device: UInt64(metadata.st_dev),
            fileID: UInt64(metadata.st_ino)
        )
    }
}
