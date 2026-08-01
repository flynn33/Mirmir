import CryptoKit
import Darwin
import Foundation

protocol AtomicMediaQuarantineCleanupObserving: Sendable {
    func didQuarantine(
        destinationURL: URL,
        quarantineURL: URL
    ) throws
}

struct NoOpAtomicMediaQuarantineCleanupObserver:
    AtomicMediaQuarantineCleanupObserving {
    func didQuarantine(
        destinationURL _: URL,
        quarantineURL _: URL
    ) throws {}
}

// Descriptor ownership and path mutation remain in one fail-closed syscall
// boundary so no higher-level caller can bypass the identity checks.
// swiftlint:disable:next type_body_length
struct LocalAtomicMediaFileSystem: AtomicMediaFileSystem {
    private static let quarantineAttemptLimit = 3
    private static let digestReadSize = 1_048_576

    private struct QuarantineRestoration {
        let wasDurablyRestored: Bool
        let description: String
    }

    private enum ObservedTemporaryOwnership: Equatable {
        case absent
        case matching
        case changed
    }

    private let cleanupObserver:
        any AtomicMediaQuarantineCleanupObserving

    init(
        cleanupObserver:
            any AtomicMediaQuarantineCleanupObserving =
                NoOpAtomicMediaQuarantineCleanupObserver()
    ) {
        self.cleanupObserver = cleanupObserver
    }

    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func pathEntryExists(at url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    // Lease creation is one descriptor transaction: every failure path closes
    // or unlinks only the exact lease path established during this invocation.
    // swiftlint:disable:next function_body_length
    func acquireTransactionLease(
        for destinationURL: URL
    ) throws -> AtomicMediaTransactionLease {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw AtomicMediaOutputError.transactionDirectoryUnavailable(
                directoryURL,
                reason: String(cString: strerror(errno))
            )
        }
        var leaseOwnsDirectoryDescriptor = false
        defer {
            if !leaseOwnsDirectoryDescriptor {
                close(directoryDescriptor)
            }
        }

        let baseName = destinationURL
            .deletingPathExtension()
            .lastPathComponent
        let leaseName = ".\(baseName).mirmir-output.lock"
        guard Self.isSafeLeafName(leaseName) else {
            throw AtomicMediaOutputError.transactionDirectoryUnavailable(
                directoryURL,
                reason: "transaction lease name is unsafe"
            )
        }
        let createdDescriptor = leaseName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        let descriptor: Int32
        let leaseCreatedByAcquisition: Bool
        if createdDescriptor >= 0 {
            descriptor = createdDescriptor
            leaseCreatedByAcquisition = true
        } else {
            let creationError = errno
            guard creationError == EEXIST else {
                throw AtomicMediaOutputError
                    .transactionDirectoryUnavailable(
                        directoryURL,
                        reason: "transaction lease creation failed: "
                            + String(cString: strerror(creationError))
                    )
            }
            let existingDescriptor = leaseName.withCString {
                openat(
                    directoryDescriptor,
                    $0,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard existingDescriptor >= 0 else {
                let openError = errno
                throw AtomicMediaOutputError
                    .transactionDirectoryUnavailable(
                        directoryURL,
                        reason: "existing transaction lease open failed: "
                            + String(cString: strerror(openError))
                    )
            }
            descriptor = existingDescriptor
            leaseCreatedByAcquisition = false
        }
        do {
            try Self.validateLease(
                descriptor: descriptor,
                name: leaseName,
                directoryDescriptor: directoryDescriptor,
                directoryURL: directoryURL
            )
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                if code == EWOULDBLOCK || code == EAGAIN {
                    throw AtomicMediaOutputError
                        .transactionDirectoryBusy(directoryURL)
                }
                throw AtomicMediaOutputError
                    .transactionDirectoryUnavailable(
                        directoryURL,
                        reason: "transaction lease lock failed: "
                            + String(cString: strerror(code))
                    )
            }
            do {
                try Self.validateLease(
                    descriptor: descriptor,
                    name: leaseName,
                    directoryDescriptor: directoryDescriptor,
                    directoryURL: directoryURL
                )
            } catch {
                _ = flock(descriptor, LOCK_UN)
                throw error
            }
            leaseOwnsDirectoryDescriptor = true
            return AtomicMediaTransactionLease(
                directoryURL: directoryURL,
                descriptor: descriptor,
                validationAction: { lockedDescriptor in
                    try Self.validateLease(
                        descriptor: lockedDescriptor,
                        name: leaseName,
                        directoryDescriptor: directoryDescriptor,
                        directoryURL: directoryURL
                    )
                },
                releaseAction: { lockedDescriptor in
                    Self.releaseTransactionLease(
                        descriptor: lockedDescriptor,
                        name: leaseName,
                        directoryDescriptor: directoryDescriptor,
                        directoryURL: directoryURL,
                        removePathOnRelease:
                            leaseCreatedByAcquisition
                    )
                }
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    @discardableResult
    func reclaimTransactionTemporaryFile(at url: URL) throws -> Bool {
        try reclaimReservedTransactionTemporaryFile(at: url)
    }

    func discardTransactionTemporaryFileReservation(
        at url: URL
    ) throws {
        try discardReservedTransactionTemporaryFileMarker(
            at: url
        )
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func removeItem(
        at url: URL,
        ifMatchingFile identity: AtomicMediaPinnedFileIdentity
    ) throws {
        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 1,
                reason: String(cString: strerror(errno))
            )
        }
        defer { close(directoryDescriptor) }

        let destinationName = url.lastPathComponent
        guard Self.isSafeLeafName(destinationName) else {
            throw AtomicMediaOutputError.unsafeTemporaryFile(url)
        }

        let quarantineName: String
        do {
            guard let isolatedName = try Self.quarantineDestination(
                destinationName: destinationName,
                directoryDescriptor: directoryDescriptor,
                directoryURL: directoryURL
            ) else {
                return
            }
            quarantineName = isolatedName
        } catch {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 1,
                reason: "temporary quarantine failed: \(error)"
            )
        }

        let quarantineURL = directoryURL.appendingPathComponent(
            quarantineName,
            isDirectory: false
        )
        let quarantineDescriptor: Int32
        do {
            try Self.synchronizeDirectory(
                directoryDescriptor,
                url: directoryURL
            )
            try cleanupObserver.didQuarantine(
                destinationURL: url,
                quarantineURL: quarantineURL
            )
            quarantineDescriptor =
                try Self.openValidatedFileQuarantine(
                    named: quarantineName,
                    directoryDescriptor: directoryDescriptor,
                    quarantineURL: quarantineURL,
                    expecting: identity
                )
        } catch {
            let restoration = Self.restoreQuarantine(
                named: quarantineName,
                to: destinationName,
                directoryDescriptor: directoryDescriptor,
                directoryURL: directoryURL
            )
            if let outputError = error as? AtomicMediaOutputError,
               case .verifiedTemporaryFileChanged = outputError,
               restoration.wasDurablyRestored {
                throw AtomicMediaOutputError
                    .verifiedTemporaryFileChanged(url)
            }
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 1,
                reason: "quarantined file identity mismatch: \(error); "
                    + restoration.description
            )
        }
        defer { close(quarantineDescriptor) }

        do {
            try Self.unlinkValidatedFileQuarantine(
                named: quarantineName,
                directoryDescriptor: directoryDescriptor,
                directoryURL: directoryURL,
                quarantineURL: quarantineURL,
                descriptor: quarantineDescriptor,
                expecting: identity
            )
            try discardTransactionTemporaryFileReservation(
                at: url
            )
        } catch {
            if let outputError = error as? AtomicMediaOutputError,
               case .verifiedTemporaryFileChanged(let changedURL) =
                   outputError,
               changedURL == quarantineURL {
                let restoration = Self.restoreQuarantine(
                    named: quarantineName,
                    to: destinationName,
                    directoryDescriptor: directoryDescriptor,
                    directoryURL: directoryURL
                )
                if restoration.wasDurablyRestored {
                    throw AtomicMediaOutputError
                        .verifiedTemporaryFileChanged(url)
                }
                throw AtomicMediaOutputError.cleanupFailed(
                    temporary: url,
                    attempts: 1,
                    reason: "matching temporary changed before cleanup: "
                        + "\(error); \(restoration.description)"
                )
            }
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 1,
                reason: "matching temporary cleanup failed: \(error)"
            )
        }
    }

    func removeItem(
        at url: URL,
        ifMatching identity: AtomicMediaCleanupFileIdentity
    ) throws {
        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw Self.posixError(path: directoryURL, code: errno)
        }
        defer { close(directoryDescriptor) }

        let destinationName = url.lastPathComponent
        guard Self.isSafeLeafName(destinationName) else {
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: url,
                    reason: "destination leaf name is unsafe"
                )
        }

        let quarantineName: String
        do {
            guard let isolatedName = try Self.quarantineDestination(
                destinationName: destinationName,
                directoryDescriptor: directoryDescriptor,
                directoryURL: directoryURL
            ) else {
                return
            }
            quarantineName = isolatedName
        } catch {
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: url,
                    reason: "destination quarantine failed: \(error)"
                )
        }

        let quarantineURL = directoryURL.appendingPathComponent(
            quarantineName,
            isDirectory: false
        )
        let quarantineDescriptor: Int32
        do {
            try Self.synchronizeDirectory(
                directoryDescriptor,
                url: directoryURL
            )
            try cleanupObserver.didQuarantine(
                destinationURL: url,
                quarantineURL: quarantineURL
            )
            quarantineDescriptor = try Self.openValidatedQuarantine(
                named: quarantineName,
                directoryDescriptor: directoryDescriptor,
                quarantineURL: quarantineURL,
                expecting: identity
            )
        } catch {
            let restoration = Self.restoreQuarantine(
                named: quarantineName,
                to: destinationName,
                directoryDescriptor: directoryDescriptor,
                directoryURL: directoryURL
            )
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: url,
                    reason: "quarantined identity mismatch: \(error); "
                        + restoration.description
                )
        }
        defer { close(quarantineDescriptor) }

        do {
            try Self.unlinkValidatedQuarantine(
                named: quarantineName,
                directoryDescriptor: directoryDescriptor,
                directoryURL: directoryURL,
                quarantineURL: quarantineURL,
                descriptor: quarantineDescriptor,
                expecting: identity
            )
        } catch {
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: url,
                    reason: "matching quarantine cleanup did not reach "
                        + "durable success: \(error)"
                )
        }
    }

    func publishAtomically(
        from temporaryURL: URL,
        to destinationURL: URL
    ) throws {
        let result = temporaryURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    temporaryPath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [
                    NSFilePathErrorKey: destinationURL.path,
                    NSLocalizedDescriptionKey:
                        String(cString: strerror(errno))
                ]
            )
        }
        try? discardTransactionTemporaryFileReservation(
            at: temporaryURL
        )
    }
}

private extension LocalAtomicMediaFileSystem {
    func reclaimReservedTransactionTemporaryFile(
        at url: URL
    ) throws -> Bool {
        let markerURL = Self.transactionOwnershipMarkerURL(
            for: url
        )
        let temporaryIdentity = try Self.ownedRegularFileIdentity(
            at: url
        )
        let markerIdentity = try Self
            .validatedTransactionOwnershipMarkerIdentity(
                at: markerURL,
                temporaryURL: url
            )

        guard let temporaryIdentity else {
            if let markerIdentity {
                try removeItem(
                    at: markerURL,
                    ifMatchingFile: markerIdentity
                )
            }
            try Self.createTransactionOwnershipMarker(
                at: markerURL,
                temporaryURL: url
            )
            return false
        }
        guard markerIdentity != nil else {
            throw AtomicMediaOutputError
                .unownedTemporaryFilePreserved(url)
        }

        do {
            try removeItem(
                at: url,
                ifMatchingFile: temporaryIdentity
            )
        } catch {
            let removalError = error
            let ownershipMismatch: Bool
            if let outputError = error as? AtomicMediaOutputError,
               case .verifiedTemporaryFileChanged = outputError {
                ownershipMismatch = true
            } else {
                ownershipMismatch = false
            }
            let observedOwnership: ObservedTemporaryOwnership
            do {
                if let observedIdentity = try Self
                    .ownedRegularFileIdentity(at: url) {
                    observedOwnership = observedIdentity
                        == temporaryIdentity ? .matching : .changed
                } else {
                    observedOwnership = .absent
                }
            } catch {
                observedOwnership = .changed
            }

            if !ownershipMismatch,
               observedOwnership == .matching {
                throw removalError
            }
            if !ownershipMismatch,
               observedOwnership == .absent {
                do {
                    try discardReservedTransactionTemporaryFileMarker(
                        at: url
                    )
                    try Self.createTransactionOwnershipMarker(
                        at: markerURL,
                        temporaryURL: url
                    )
                    return true
                } catch {
                    throw AtomicMediaOutputError.cleanupFailed(
                        temporary: url,
                        attempts: 1,
                        reason: "owned temporary removal reported "
                            + "\(removalError); reservation recovery "
                            + "failed: \(error)"
                    )
                }
            }
            do {
                try discardReservedTransactionTemporaryFileMarker(
                    at: url
                )
            } catch {
                throw AtomicMediaOutputError.cleanupFailed(
                    temporary: url,
                    attempts: 1,
                    reason: "temporary ownership changed during "
                        + "reclamation: \(removalError); ownership "
                        + "reservation cleanup failed: \(error)"
                )
            }
            throw AtomicMediaOutputError
                .unownedTemporaryFilePreserved(url)
        }
        guard !pathEntryExists(at: url) else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 1,
                reason: "owned temporary path remained after reclamation"
            )
        }
        try Self.createTransactionOwnershipMarker(
            at: markerURL,
            temporaryURL: url
        )
        return true
    }

    func discardReservedTransactionTemporaryFileMarker(
        at url: URL
    ) throws {
        let markerURL = Self.transactionOwnershipMarkerURL(
            for: url
        )
        guard let identity = try Self
            .validatedTransactionOwnershipMarkerIdentity(
                at: markerURL,
                temporaryURL: url
            ) else {
            return
        }
        try removeItem(
            at: markerURL,
            ifMatchingFile: identity
        )
    }
    static func releaseTransactionLease(
        descriptor: Int32,
        name: String,
        directoryDescriptor: Int32,
        directoryURL: URL,
        removePathOnRelease: Bool
    ) {
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
            close(directoryDescriptor)
        }

        guard removePathOnRelease else { return }
        guard (try? validateLease(
            descriptor: descriptor,
            name: name,
            directoryDescriptor: directoryDescriptor,
            directoryURL: directoryURL
        )) != nil else {
            return
        }
        let unlinkStatus = name.withCString {
            unlinkat(directoryDescriptor, $0, 0)
        }
        guard unlinkStatus == 0 else { return }
        try? synchronizeDirectory(
            directoryDescriptor,
            url: directoryURL
        )
    }

    static func validateLease(
        descriptor: Int32,
        name: String,
        directoryDescriptor: Int32,
        directoryURL: URL
    ) throws {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let pathStatus = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(descriptor, &descriptorMetadata) == 0,
              pathStatus == 0,
              let descriptorIdentity = AtomicMediaPinnedFileIdentity(
                descriptorMetadata,
                requirePopulatedFile: false
              ),
              let pathIdentity = AtomicMediaPinnedFileIdentity(
                pathMetadata,
                requirePopulatedFile: false
              ),
              descriptorIdentity == pathIdentity,
              descriptorMetadata.st_size == 0,
              descriptorMetadata.st_mode & mode_t(0o077) == 0 else {
            throw AtomicMediaOutputError.transactionDirectoryUnavailable(
                directoryURL,
                reason: "transaction lease identity is unsafe"
            )
        }
    }

    static func ownedRegularFileIdentity(
        at url: URL
    ) throws -> AtomicMediaPinnedFileIdentity? {
        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 0,
                reason: String(cString: strerror(errno))
            )
        }
        defer { close(directoryDescriptor) }

        let name = url.lastPathComponent
        guard isSafeLeafName(name) else {
            throw AtomicMediaOutputError.unsafeTemporaryFile(url)
        }
        let descriptor = name.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            if code == ELOOP || code == EISDIR {
                throw AtomicMediaOutputError.unsafeTemporaryFile(url)
            }
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 0,
                reason: String(cString: strerror(code))
            )
        }
        defer { close(descriptor) }

        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let pathStatus = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(descriptor, &descriptorMetadata) == 0,
              pathStatus == 0,
              let descriptorIdentity = AtomicMediaPinnedFileIdentity(
                descriptorMetadata,
                requirePopulatedFile: false
              ),
              let pathIdentity = AtomicMediaPinnedFileIdentity(
                pathMetadata,
                requirePopulatedFile: false
              ),
              descriptorIdentity == pathIdentity else {
            throw AtomicMediaOutputError.unsafeTemporaryFile(url)
        }
        return descriptorIdentity
    }

    static func transactionOwnershipMarkerURL(
        for temporaryURL: URL
    ) -> URL {
        let leafDigest = SHA256.hash(
            data: Data(temporaryURL.lastPathComponent.utf8)
        ).map {
            String(format: "%02x", $0)
        }.joined()
        return temporaryURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".mirmir-temporary-owner-\(leafDigest).marker",
                isDirectory: false
            )
    }

    static func transactionOwnershipMarkerPayload(
        for temporaryURL: URL
    ) -> Data {
        let pathDigest = SHA256.hash(
            data: Data(
                temporaryURL.standardizedFileURL.path.utf8
            )
        ).map {
            String(format: "%02x", $0)
        }.joined()
        return Data(
            (
                "mirmir-temporary-ownership-v1\n"
                    + pathDigest
                    + "\n"
            ).utf8
        )
    }

    static func validatedTransactionOwnershipMarkerIdentity(
        at markerURL: URL,
        temporaryURL: URL
    ) throws -> AtomicMediaPinnedFileIdentity? {
        guard pathEntryExistsWithoutFollowingSymlinks(
            at: markerURL
        ) else {
            return nil
        }
        let expectedPayload = transactionOwnershipMarkerPayload(
            for: temporaryURL
        )
        do {
            let marker = try AtomicMediaVerifiedTemporaryFile(
                url: markerURL
            )
            try marker.validatePathAndContents(at: markerURL)
            let identity = try marker.makePinnedFileIdentity()
            let expectedDigest = SHA256.hash(
                data: expectedPayload
            ).map {
                String(format: "%02x", $0)
            }.joined()
            guard identity.byteCount
                    == UInt64(expectedPayload.count),
                  identity.mode & UInt32(0o077) == 0,
                  marker.publicationIdentity.byteCount
                    == UInt64(expectedPayload.count),
                  marker.publicationIdentity.sha256
                    == expectedDigest else {
                throw AtomicMediaOutputError
                    .unsafeTemporaryFile(markerURL)
            }
            return identity
        } catch {
            throw AtomicMediaOutputError
                .unsafeTemporaryFile(markerURL)
        }
    }

    static func createTransactionOwnershipMarker(
        at markerURL: URL,
        temporaryURL: URL
    ) throws {
        let directoryURL = markerURL.deletingLastPathComponent()
        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: temporaryURL,
                attempts: 0,
                reason: "ownership marker directory unavailable: "
                    + String(cString: strerror(errno))
            )
        }
        defer { close(directoryDescriptor) }

        let markerName = markerURL.lastPathComponent
        guard isSafeLeafName(markerName) else {
            throw AtomicMediaOutputError.unsafeTemporaryFile(
                markerURL
            )
        }
        let descriptor = markerName.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
                    | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: temporaryURL,
                attempts: 0,
                reason: "ownership marker creation failed: "
                    + String(cString: strerror(errno))
            )
        }

        var completed = false
        defer {
            if !completed {
                unlinkCreatedMarkerIfUnchanged(
                    descriptor: descriptor,
                    name: markerName,
                    directoryDescriptor: directoryDescriptor
                )
            }
            close(descriptor)
        }

        let payload = transactionOwnershipMarkerPayload(
            for: temporaryURL
        )
        try writeAll(
            payload,
            descriptor: descriptor,
            markerURL: markerURL,
            temporaryURL: temporaryURL
        )
        guard fsync(descriptor) == 0 else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: temporaryURL,
                attempts: 0,
                reason: "ownership marker synchronization failed: "
                    + String(cString: strerror(errno))
            )
        }
        try validateCreatedMarker(
            descriptor: descriptor,
            name: markerName,
            directoryDescriptor: directoryDescriptor,
            markerURL: markerURL,
            temporaryURL: temporaryURL,
            expectedByteCount: payload.count
        )
        try synchronizeDirectory(
            directoryDescriptor,
            url: directoryURL
        )
        completed = true
    }

    static func validateCreatedMarker(
        descriptor: Int32,
        name: String,
        directoryDescriptor: Int32,
        markerURL: URL,
        temporaryURL: URL,
        expectedByteCount: Int
    ) throws {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let pathStatus = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(descriptor, &descriptorMetadata) == 0,
              pathStatus == 0,
              let descriptorIdentity = AtomicMediaPinnedFileIdentity(
                descriptorMetadata,
                requirePopulatedFile: true
              ),
              let pathIdentity = AtomicMediaPinnedFileIdentity(
                pathMetadata,
                requirePopulatedFile: true
              ),
              descriptorIdentity == pathIdentity,
              descriptorIdentity.byteCount
                == UInt64(expectedByteCount),
              descriptorIdentity.mode & UInt32(0o077) == 0 else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: temporaryURL,
                attempts: 0,
                reason: "ownership marker identity is unsafe at "
                    + markerURL.lastPathComponent
            )
        }
    }

    static func writeAll(
        _ data: Data,
        descriptor: Int32,
        markerURL: URL,
        temporaryURL: URL
    ) throws {
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
            }
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw AtomicMediaOutputError.cleanupFailed(
                    temporary: temporaryURL,
                    attempts: 0,
                    reason: "ownership marker write failed at "
                        + "\(markerURL.lastPathComponent): "
                        + String(cString: strerror(errno))
                )
            }
            written += result
        }
    }

    static func unlinkCreatedMarkerIfUnchanged(
        descriptor: Int32,
        name: String,
        directoryDescriptor: Int32
    ) {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let pathStatus = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(descriptor, &descriptorMetadata) == 0,
              pathStatus == 0,
              descriptorMetadata.st_dev == pathMetadata.st_dev,
              descriptorMetadata.st_ino == pathMetadata.st_ino,
              descriptorMetadata.st_uid == geteuid(),
              descriptorMetadata.st_nlink == 1,
              (descriptorMetadata.st_mode & S_IFMT) == S_IFREG else {
            return
        }
        _ = name.withCString {
            unlinkat(directoryDescriptor, $0, 0)
        }
    }

    static func pathEntryExistsWithoutFollowingSymlinks(
        at url: URL
    ) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    static func openValidatedFileQuarantine(
        named name: String,
        directoryDescriptor: Int32,
        quarantineURL: URL,
        expecting expected: AtomicMediaPinnedFileIdentity
    ) throws -> Int32 {
        let descriptor = name.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw posixError(path: quarantineURL, code: errno)
        }
        do {
            var descriptorMetadata = stat()
            var pathMetadata = stat()
            let pathStatus = name.withCString {
                fstatat(
                    directoryDescriptor,
                    $0,
                    &pathMetadata,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard fstat(descriptor, &descriptorMetadata) == 0,
                  pathStatus == 0,
                  let descriptorIdentity =
                    AtomicMediaPinnedFileIdentity(
                        descriptorMetadata,
                        requirePopulatedFile: false
                    ),
                  let pathIdentity = AtomicMediaPinnedFileIdentity(
                    pathMetadata,
                    requirePopulatedFile: false
                  ),
                  descriptorIdentity == expected,
                  pathIdentity == expected else {
                throw AtomicMediaOutputError
                    .verifiedTemporaryFileChanged(quarantineURL)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func unlinkValidatedFileQuarantine(
        named name: String,
        directoryDescriptor: Int32,
        directoryURL: URL,
        quarantineURL: URL,
        descriptor: Int32,
        expecting expected: AtomicMediaPinnedFileIdentity
    ) throws {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        let pathStatus = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(descriptor, &descriptorMetadata) == 0,
              pathStatus == 0,
              let descriptorIdentity = AtomicMediaPinnedFileIdentity(
                descriptorMetadata,
                requirePopulatedFile: false
              ),
              let pathIdentity = AtomicMediaPinnedFileIdentity(
                pathMetadata,
                requirePopulatedFile: false
              ),
              descriptorIdentity == expected,
              pathIdentity == expected else {
            throw AtomicMediaOutputError
                .verifiedTemporaryFileChanged(quarantineURL)
        }

        let unlinkResult = name.withCString {
            unlinkat(directoryDescriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            throw posixError(path: quarantineURL, code: errno)
        }
        try synchronizeDirectory(
            directoryDescriptor,
            url: directoryURL
        )

        var pathAfter = stat()
        let pathResult = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let pathError = errno
        var descriptorAfter = stat()
        guard pathResult != 0,
              pathError == ENOENT,
              fstat(descriptor, &descriptorAfter) == 0,
              descriptorAfter.st_nlink == 0 else {
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: quarantineURL,
                attempts: 1,
                reason: "temporary unlink postcondition failed"
            )
        }
    }

    static func quarantineDestination(
        destinationName: String,
        directoryDescriptor: Int32,
        directoryURL: URL
    ) throws -> String? {
        for _ in 0..<quarantineAttemptLimit {
            let quarantineName =
                ".mirmir-cleanup-\(UUID().uuidString).quarantine"
            let result = renameExclusively(
                from: destinationName,
                to: quarantineName,
                directoryDescriptor: directoryDescriptor
            )
            if result == 0 {
                return quarantineName
            }
            let code = errno
            if code == ENOENT {
                try synchronizeDirectory(
                    directoryDescriptor,
                    url: directoryURL
                )
                return nil
            }
            if code != EEXIST {
                throw posixError(path: directoryURL, code: code)
            }
        }
        throw AtomicMediaOutputError
            .publishedDestinationCleanupFailed(
                destination: directoryURL,
                reason: "unique quarantine name attempts exhausted"
            )
    }

    static func openValidatedQuarantine(
        named name: String,
        directoryDescriptor: Int32,
        quarantineURL: URL,
        expecting expected: AtomicMediaCleanupFileIdentity
    ) throws -> Int32 {
        let descriptor = name.withCString {
            openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw posixError(path: quarantineURL, code: errno)
        }
        do {
            let observed = try cleanupIdentity(
                descriptor: descriptor,
                named: name,
                directoryDescriptor: directoryDescriptor,
                url: quarantineURL
            )
            guard observed == expected else {
                throw AtomicMediaOutputError
                    .publishedDestinationCleanupFailed(
                        destination: quarantineURL,
                        reason: "isolated inode or content identity differs"
                    )
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func unlinkValidatedQuarantine(
        named name: String,
        directoryDescriptor: Int32,
        directoryURL: URL,
        quarantineURL: URL,
        descriptor: Int32,
        expecting expected: AtomicMediaCleanupFileIdentity
    ) throws {
        let observed = try cleanupIdentity(
            descriptor: descriptor,
            named: name,
            directoryDescriptor: directoryDescriptor,
            url: quarantineURL
        )
        guard observed == expected else {
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: quarantineURL,
                    reason: "quarantine changed before unlink"
                )
        }

        // Darwin has no unlink-by-descriptor or atomic compare-and-unlink.
        // The exclusive same-directory rename is the ownership boundary:
        // cleanup never unlinks the public destination name. The unique,
        // transaction-owned quarantine is revalidated immediately before
        // this path unlink; any observed mismatch is restored or retained.
        let unlinkResult = name.withCString {
            unlinkat(directoryDescriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            throw posixError(path: quarantineURL, code: errno)
        }
        try synchronizeDirectory(
            directoryDescriptor,
            url: directoryURL
        )

        var pathAfter = stat()
        let pathResult = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let pathError = errno
        var descriptorAfter = stat()
        guard pathResult != 0,
              pathError == ENOENT,
              fstat(descriptor, &descriptorAfter) == 0,
              descriptorAfter.st_nlink == 0 else {
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: quarantineURL,
                    reason: "quarantine unlink postcondition failed"
                )
        }
    }

    static func cleanupIdentity(
        descriptor: Int32,
        named name: String,
        directoryDescriptor: Int32,
        url: URL
    ) throws -> AtomicMediaCleanupFileIdentity {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              let fileBefore = AtomicMediaPinnedFileIdentity(
                before,
                requirePopulatedFile: false
              ) else {
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: url,
                    reason: "quarantine descriptor identity is invalid"
                )
        }
        let digest = try sha256(descriptor: descriptor, url: url)
        var after = stat()
        var pathAfter = stat()
        let pathResult = name.withCString {
            fstatat(
                directoryDescriptor,
                $0,
                &pathAfter,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(descriptor, &after) == 0,
              pathResult == 0,
              let fileAfter = AtomicMediaPinnedFileIdentity(
                after,
                requirePopulatedFile: false
              ),
              let pathIdentity = AtomicMediaPinnedFileIdentity(
                pathAfter,
                requirePopulatedFile: false
              ),
              fileBefore == fileAfter,
              fileAfter == pathIdentity else {
            throw AtomicMediaOutputError
                .publishedDestinationCleanupFailed(
                    destination: url,
                    reason: "quarantine identity was not stable"
                )
        }
        return AtomicMediaCleanupFileIdentity(
            file: fileAfter,
            contents: MediaOutputPublicationIdentity(
                sha256: digest,
                byteCount: fileAfter.byteCount
            )
        )
    }

    static func sha256(
        descriptor: Int32,
        url: URL
    ) throws -> String {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](
            repeating: 0,
            count: digestReadSize
        )
        while true {
            let count = pread(
                descriptor,
                &buffer,
                buffer.count,
                offset
            )
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw posixError(path: url, code: errno)
            }
            guard count > 0 else { break }
            hasher.update(data: Data(buffer.prefix(Int(count))))
            offset += off_t(count)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func restoreQuarantine(
        named quarantineName: String,
        to destinationName: String,
        directoryDescriptor: Int32,
        directoryURL: URL
    ) -> QuarantineRestoration {
        let result = renameExclusively(
            from: quarantineName,
            to: destinationName,
            directoryDescriptor: directoryDescriptor
        )
        if result == 0 {
            do {
                try synchronizeDirectory(
                    directoryDescriptor,
                    url: directoryURL
                )
                return QuarantineRestoration(
                    wasDurablyRestored: true,
                    description:
                        "mismatched entry restored without replacement"
                )
            } catch {
                return QuarantineRestoration(
                    wasDurablyRestored: false,
                    description: "mismatched entry restored; "
                        + "directory sync failed: "
                        + String(describing: error)
                )
            }
        }
        let code = errno
        if code == EEXIST {
            return QuarantineRestoration(
                wasDurablyRestored: false,
                description: "destination is occupied; mismatched "
                    + "quarantine retained as \(quarantineName)"
            )
        }
        return QuarantineRestoration(
            wasDurablyRestored: false,
            description: "mismatched quarantine restore failed with "
                + "errno \(code); quarantine retained as "
                + quarantineName
        )
    }

    static func renameExclusively(
        from sourceName: String,
        to destinationName: String,
        directoryDescriptor: Int32
    ) -> Int32 {
        sourceName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(
                    directoryDescriptor,
                    source,
                    directoryDescriptor,
                    destination,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
    }

    static func isSafeLeafName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
    }

    static func synchronizeDirectory(
        _ descriptor: Int32,
        url: URL
    ) throws {
        guard fsync(descriptor) == 0 else {
            throw posixError(path: url, code: errno)
        }
    }

    static func posixError(path: URL, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path.path,
                NSLocalizedDescriptionKey:
                    String(cString: strerror(code))
            ]
        )
    }
}

// Secure path validation and quarantine operations share one syscall boundary.
// swiftlint:disable:this file_length
