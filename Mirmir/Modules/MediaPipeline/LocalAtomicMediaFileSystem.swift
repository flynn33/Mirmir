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

struct LocalAtomicMediaFileSystem: AtomicMediaFileSystem {
    private static let quarantineAttemptLimit = 3
    private static let digestReadSize = 1_048_576

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

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
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
                        + restoration
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
    }
}

private extension LocalAtomicMediaFileSystem {
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

    static func restoreQuarantine(
        named quarantineName: String,
        to destinationName: String,
        directoryDescriptor: Int32,
        directoryURL: URL
    ) -> String {
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
                return "mismatched entry restored without replacement"
            } catch {
                return "mismatched entry restored; directory sync failed: "
                    + String(describing: error)
            }
        }
        let code = errno
        if code == EEXIST {
            return "destination is occupied; mismatched quarantine retained "
                + "as \(quarantineName)"
        }
        return "mismatched quarantine restore failed with errno \(code); "
            + "quarantine retained as \(quarantineName)"
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
