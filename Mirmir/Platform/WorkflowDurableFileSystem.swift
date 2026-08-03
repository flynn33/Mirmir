import Darwin
import Foundation

enum WorkflowDurabilityLevel: Sendable {
    /// Survives process termination once the operation returns successfully.
    case processCrash

    /// Additionally requests the macOS full device-flush barrier for file data.
    case powerLoss
}

enum WorkflowFileSystemFaultPoint: String, CaseIterable, Sendable {
    case afterDirectoryCreate
    case afterDirectoryParentSync
    case beforeTemporaryCreate
    case afterTemporaryWriteChunk
    case afterTemporaryWrite
    case afterTemporaryFileSync
    case beforePublishRename
    case afterPublishRename
    case afterPublishParentSync
    case beforeAppend
    case afterAppendChunk
    case afterAppendWrite
    case afterAppendFileSync
    case beforeRegularFileSync
    case afterRegularFileSync
    case beforeTruncate
    case afterTruncate
    case afterTruncateFileSync
    case beforeLockOpen
    case afterLockOpen
    case afterLockAcquired
}

enum WorkflowDurableFileSystemError: Error, Equatable, LocalizedError {
    case unsafePath(String)
    case entryNotFound(String)
    case entryAlreadyExists(String)
    case fileTooLarge(path: String, maximumBytes: Int)
    case lockUnavailable(String)
    case ioFailure(operation: String, path: String, code: Int32)
    case indeterminate(operation: String, path: String)

    var errorDescription: String? {
        switch self {
        case let .unsafePath(path):
            "Unsafe workflow filesystem path: \(path)"
        case let .entryNotFound(path):
            "Workflow filesystem entry does not exist: \(path)"
        case let .entryAlreadyExists(path):
            "Workflow filesystem entry already exists: \(path)"
        case let .fileTooLarge(path, maximumBytes):
            "Workflow file \(path) exceeds \(maximumBytes) bytes."
        case let .lockUnavailable(path):
            "Workflow lease is already held: \(path)"
        case let .ioFailure(operation, path, code):
            "Workflow filesystem operation \(operation) failed for \(path) "
                + "with errno \(code)."
        case let .indeterminate(operation, path):
            "Workflow filesystem operation \(operation) has an indeterminate "
                + "commit status for \(path); reopen before retrying."
        }
    }
}

final class WorkflowExclusiveFileLease: @unchecked Sendable {
    let url: URL

    private let stateLock = NSLock()
    private var descriptor: Int32?

    fileprivate init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    var isHeld: Bool {
        stateLock.withLock { descriptor != nil }
    }

    func release() {
        let descriptorToClose = stateLock.withLock { () -> Int32? in
            defer { descriptor = nil }
            return descriptor
        }
        guard let descriptorToClose else { return }
        _ = flock(descriptorToClose, LOCK_UN)
        close(descriptorToClose)
    }

    deinit {
        release()
    }
}

protocol WorkflowDurableFileSystem: Sendable {
    var trustedRootURL: URL { get }

    func ensureDirectory(_ url: URL) throws
    func regularFileExists(_ url: URL) throws -> Bool
    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data
    func writeNewAtomically(_ data: Data, to url: URL) throws
    func replaceAtomically(_ data: Data, at url: URL) throws
    func appendDurably(
        _ data: Data,
        to url: URL,
        maximumFileBytes: Int
    ) throws
    func synchronizeRegularFileDurably(_ url: URL) throws
    func truncateDurably(_ url: URL, toByteCount byteCount: UInt64) throws
    func withExclusiveLock<Result>(
        at url: URL,
        _ operation: (any WorkflowDurableFileSystem) throws -> Result
    ) throws -> Result
    func acquireExclusiveLease(
        at url: URL,
        nonBlocking: Bool
    ) throws -> WorkflowExclusiveFileLease
}

struct WorkflowLocalDurableFileSystem: WorkflowDurableFileSystem {
    typealias OperationHook =
        @Sendable (WorkflowFileSystemFaultPoint, URL) throws -> Void

    let trustedRootURL: URL

    private let rootDevice: UInt64
    private let rootFileID: UInt64
    private let durabilityLevel: WorkflowDurabilityLevel
    private let maximumWriteChunkBytes: Int
    private let operationHook: OperationHook

    /// The trusted root must already exist. Its symlinks are resolved once at
    /// construction; every descendant traversal after that is descriptor based
    /// and rejects symlinks.
    init(
        trustedRootURL: URL,
        durabilityLevel: WorkflowDurabilityLevel = .powerLoss,
        maximumWriteChunkBytes: Int = Int.max,
        operationHook: OperationHook? = nil
    ) throws {
        guard maximumWriteChunkBytes > 0 else {
            throw WorkflowDurableFileSystemError.ioFailure(
                operation: "initialize",
                path: trustedRootURL.path,
                code: EINVAL
            )
        }
        let root = trustedRootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL, root.path.hasPrefix("/") else {
            throw WorkflowDurableFileSystemError.unsafePath(
                trustedRootURL.path
            )
        }
        let descriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw WorkflowDurableFileSystemError.unsafePath(root.path)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard
            fstat(descriptor, &metadata) == 0,
            Self.isDirectory(metadata)
        else {
            throw WorkflowDurableFileSystemError.unsafePath(root.path)
        }

        self.trustedRootURL = root
        rootDevice = UInt64(metadata.st_dev)
        rootFileID = UInt64(metadata.st_ino)
        self.durabilityLevel = durabilityLevel
        self.maximumWriteChunkBytes = maximumWriteChunkBytes
        self.operationHook = operationHook ?? { _, _ in }
    }

    func ensureDirectory(_ url: URL) throws {
        let components = try relativeComponents(for: url)
        var descriptor = try openTrustedRoot()
        defer { close(descriptor) }
        var currentURL = trustedRootURL

        for component in components {
            var nextDescriptor = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if nextDescriptor < 0, errno == ENOENT {
                let creationResult = mkdirat(descriptor, component, S_IRWXU)
                if creationResult != 0, errno != EEXIST {
                    throw ioError(operation: "mkdir", url: url)
                }
                if creationResult == 0 {
                    try operationHook(.afterDirectoryCreate, url)
                    try synchronizeDirectory(descriptor, url: currentURL)
                    try operationHook(.afterDirectoryParentSync, url)
                }
                nextDescriptor = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }
            close(descriptor)
            descriptor = nextDescriptor
            currentURL.appendPathComponent(component, isDirectory: true)
        }
        try validateTrustedRoot()
    }

    func regularFileExists(_ url: URL) throws -> Bool {
        try withParentDirectory(of: url) { parent, name, _ in
            var metadata = stat()
            if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                guard Self.isSingleLinkRegularFile(metadata) else {
                    throw WorkflowDurableFileSystemError.unsafePath(url.path)
                }
                return true
            }
            guard errno == ENOENT else {
                throw ioError(operation: "exists", url: url)
            }
            return false
        }
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else {
            throw WorkflowDurableFileSystemError.fileTooLarge(
                path: url.path,
                maximumBytes: maximumBytes
            )
        }
        return try withParentDirectory(of: url) { parent, name, _ in
            var pathBefore = stat()
            guard
                fstatat(parent, name, &pathBefore, AT_SYMLINK_NOFOLLOW) == 0
            else {
                if errno == ENOENT {
                    throw WorkflowDurableFileSystemError.entryNotFound(url.path)
                }
                throw ioError(operation: "read_stat", url: url)
            }
            guard
                Self.isSingleLinkRegularFile(pathBefore),
                pathBefore.st_size >= 0,
                pathBefore.st_size <= Int64(maximumBytes)
            else {
                throw WorkflowDurableFileSystemError.fileTooLarge(
                    path: url.path,
                    maximumBytes: maximumBytes
                )
            }
            let descriptor = openat(
                parent,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw ioError(operation: "read_open", url: url)
            }
            defer { close(descriptor) }
            var opened = stat()
            guard
                fstat(descriptor, &opened) == 0,
                Self.sameFile(pathBefore, opened)
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }
            var data = Data(count: Int(opened.st_size))
            try Self.readExactly(data: &data, descriptor: descriptor, url: url)
            var after = stat()
            var pathAfter = stat()
            guard
                fstat(descriptor, &after) == 0,
                fstatat(parent, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
                Self.sameFile(opened, after),
                Self.sameFile(after, pathAfter),
                after.st_size == opened.st_size
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }
            try validateTrustedRoot()
            return data
        }
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try writeAtomically(data, to: url, replacingExisting: false)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try writeAtomically(data, to: url, replacingExisting: true)
    }

    func appendDurably(
        _ data: Data,
        to url: URL,
        maximumFileBytes: Int
    ) throws {
        guard !data.isEmpty, maximumFileBytes >= 0 else {
            throw WorkflowDurableFileSystemError.ioFailure(
                operation: "append",
                path: url.path,
                code: EINVAL
            )
        }
        try withParentDirectory(of: url) { parent, name, _ in
            var before = stat()
            guard
                fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                Self.isSingleLinkRegularFile(before),
                before.st_size >= 0,
                before.st_size <= Int64(maximumFileBytes),
                data.count <= maximumFileBytes - Int(before.st_size)
            else {
                throw WorkflowDurableFileSystemError.fileTooLarge(
                    path: url.path,
                    maximumBytes: maximumFileBytes
                )
            }
            try operationHook(.beforeAppend, url)
            let descriptor = openat(
                parent,
                name,
                O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw ioError(operation: "append_open", url: url)
            }
            defer { close(descriptor) }
            var opened = stat()
            guard
                fstat(descriptor, &opened) == 0,
                Self.sameFile(before, opened)
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }

            var wroteAnyBytes = false
            do {
                try writeExactly(
                    data,
                    descriptor: descriptor,
                    url: url,
                    afterChunk: {
                        wroteAnyBytes = true
                        try operationHook(.afterAppendChunk, url)
                    }
                )
                try operationHook(.afterAppendWrite, url)
                try synchronizeFile(descriptor, url: url)
                try operationHook(.afterAppendFileSync, url)
                var after = stat()
                var pathAfter = stat()
                guard
                    fstat(descriptor, &after) == 0,
                    fstatat(parent, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
                    Self.sameFile(opened, after),
                    Self.sameFile(after, pathAfter),
                    after.st_size == opened.st_size + Int64(data.count)
                else {
                    throw WorkflowDurableFileSystemError.unsafePath(url.path)
                }
                try validateTrustedRoot()
            } catch {
                if wroteAnyBytes {
                    throw WorkflowDurableFileSystemError.indeterminate(
                        operation: "append",
                        path: url.path
                    )
                }
                throw error
            }
        }
    }

    func truncateDurably(_ url: URL, toByteCount byteCount: UInt64) throws {
        guard byteCount <= UInt64(Int64.max) else {
            throw WorkflowDurableFileSystemError.ioFailure(
                operation: "truncate",
                path: url.path,
                code: EOVERFLOW
            )
        }
        try withParentDirectory(of: url) { parent, name, _ in
            var before = stat()
            guard
                fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                Self.isSingleLinkRegularFile(before),
                before.st_size >= 0,
                byteCount <= UInt64(before.st_size)
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }
            try operationHook(.beforeTruncate, url)
            let descriptor = openat(
                parent,
                name,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw ioError(operation: "truncate_open", url: url)
            }
            defer { close(descriptor) }
            var opened = stat()
            guard
                fstat(descriptor, &opened) == 0,
                Self.sameFile(before, opened)
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }

            var changed = false
            do {
                try Self.truncate(
                    descriptor: descriptor,
                    byteCount: off_t(byteCount),
                    url: url
                )
                changed = true
                try operationHook(.afterTruncate, url)
                try synchronizeFile(descriptor, url: url)
                try operationHook(.afterTruncateFileSync, url)
                var after = stat()
                guard fstat(descriptor, &after) == 0,
                      after.st_size == off_t(byteCount) else {
                    throw WorkflowDurableFileSystemError.unsafePath(url.path)
                }
            } catch {
                if changed {
                    throw WorkflowDurableFileSystemError.indeterminate(
                        operation: "truncate",
                        path: url.path
                    )
                }
                throw error
            }
        }
    }

    func synchronizeRegularFileDurably(_ url: URL) throws {
        try operationHook(.beforeRegularFileSync, url)
        try withParentDirectory(of: url) { parent, name, _ in
            var before = stat()
            guard
                fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                Self.isSingleLinkRegularFile(before)
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }
            let descriptor = openat(
                parent,
                name,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw ioError(operation: "sync_open", url: url)
            }
            defer { close(descriptor) }
            var opened = stat()
            guard
                fstat(descriptor, &opened) == 0,
                Self.sameFile(before, opened)
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }
            try synchronizeFile(descriptor, url: url)
            do {
                try operationHook(.afterRegularFileSync, url)
            } catch {
                throw WorkflowDurableFileSystemError.indeterminate(
                    operation: "synchronize_regular_file",
                    path: url.path
                )
            }
        }
    }

    func withExclusiveLock<Result>(
        at url: URL,
        _ operation: (any WorkflowDurableFileSystem) throws -> Result
    ) throws -> Result {
        let lease = try acquireExclusiveLease(at: url, nonBlocking: false)
        defer { lease.release() }
        return try operation(self)
    }

    func acquireExclusiveLease(
        at url: URL,
        nonBlocking: Bool
    ) throws -> WorkflowExclusiveFileLease {
        try operationHook(.beforeLockOpen, url)
        return try withParentDirectory(of: url) { parent, name, parentURL in
            var pathBefore = stat()
            let existed = fstatat(
                parent,
                name,
                &pathBefore,
                AT_SYMLINK_NOFOLLOW
            ) == 0
            if !existed, errno != ENOENT {
                throw ioError(operation: "lock_stat", url: url)
            }
            if existed, !Self.isSingleLinkRegularFile(pathBefore) {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }

            let descriptor: Int32
            if existed {
                // Never recreate a lock path that vanished after inspection:
                // doing so could split contenders across two inodes.
                descriptor = openat(
                    parent,
                    name,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC
                )
            } else {
                var candidate = openat(
                    parent,
                    name,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
                if candidate < 0, errno == EEXIST {
                    // A cooperating contender won first creation. Open that
                    // permanent inode without ever replacing it.
                    candidate = openat(
                        parent,
                        name,
                        O_RDWR | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                descriptor = candidate
            }
            guard descriptor >= 0 else {
                throw ioError(operation: "lock_open", url: url)
            }
            var leaseOwnsDescriptor = false
            defer {
                if !leaseOwnsDescriptor {
                    close(descriptor)
                }
            }
            if !existed {
                try synchronizeFile(descriptor, url: url)
                try synchronizeDirectory(parent, url: parentURL)
            }
            try operationHook(.afterLockOpen, url)

            var opened = stat()
            var pathAfter = stat()
            guard
                fstat(descriptor, &opened) == 0,
                fstatat(parent, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
                Self.isSingleLinkRegularFile(opened),
                Self.sameFile(opened, pathAfter),
                !existed || Self.sameFile(pathBefore, opened)
            else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }

            let lockFlags = nonBlocking ? LOCK_EX | LOCK_NB : LOCK_EX
            while flock(descriptor, lockFlags) != 0 {
                if errno == EINTR { continue }
                if nonBlocking, errno == EWOULDBLOCK {
                    throw WorkflowDurableFileSystemError.lockUnavailable(
                        url.path
                    )
                }
                throw ioError(operation: "flock", url: url)
            }
            do {
                try operationHook(.afterLockAcquired, url)
                var lockedPath = stat()
                guard
                    fstatat(
                        parent,
                        name,
                        &lockedPath,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0,
                    Self.sameFile(opened, lockedPath)
                else {
                    throw WorkflowDurableFileSystemError.unsafePath(url.path)
                }
                try validateTrustedRoot()
            } catch {
                _ = flock(descriptor, LOCK_UN)
                throw error
            }
            leaseOwnsDescriptor = true
            return WorkflowExclusiveFileLease(
                url: url,
                descriptor: descriptor
            )
        }
    }
}

struct WorkflowJobLeaseManager: Sendable {
    private let fileSystem: any WorkflowDurableFileSystem
    private let jobsURL: URL

    init(
        rootURL: URL,
        fileSystem: any WorkflowDurableFileSystem
    ) throws {
        self.fileSystem = fileSystem
        jobsURL = rootURL.appendingPathComponent("jobs", isDirectory: true)
        try fileSystem.ensureDirectory(jobsURL)
    }

    /// Job leases are acquired without holding the global journal lock. This
    /// fixed lock order prevents a worker/reconciler deadlock.
    func acquireLease(for jobID: WorkflowJobID) throws -> WorkflowExclusiveFileLease {
        let jobURL = jobsURL.appendingPathComponent(
            jobID.rawValue,
            isDirectory: true
        )
        try fileSystem.ensureDirectory(jobURL)
        return try fileSystem.acquireExclusiveLease(
            at: jobURL.appendingPathComponent("worker.lock"),
            nonBlocking: true
        )
    }
}

private extension WorkflowLocalDurableFileSystem {
    func writeAtomically(
        _ data: Data,
        to url: URL,
        replacingExisting: Bool
    ) throws {
        try withParentDirectory(of: url) { parent, name, parentURL in
            var destinationBefore = stat()
            let destinationExists = fstatat(
                parent,
                name,
                &destinationBefore,
                AT_SYMLINK_NOFOLLOW
            ) == 0
            if !destinationExists, errno != ENOENT {
                throw ioError(operation: "atomic_stat", url: url)
            }
            if replacingExisting {
                guard
                    destinationExists,
                    Self.isSingleLinkRegularFile(destinationBefore)
                else {
                    throw WorkflowDurableFileSystemError.entryNotFound(url.path)
                }
            } else if destinationExists {
                throw WorkflowDurableFileSystemError.entryAlreadyExists(url.path)
            }

            try operationHook(.beforeTemporaryCreate, url)
            let temporaryName = ".\(name).workflow-tmp-\(UUID().uuidString)"
            let descriptor = openat(
                parent,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else {
                throw ioError(operation: "temporary_create", url: url)
            }
            defer { close(descriptor) }
            var temporaryExists = true
            var published = false
            defer {
                if temporaryExists {
                    _ = unlinkat(parent, temporaryName, 0)
                }
            }

            do {
                try writeExactly(
                    data,
                    descriptor: descriptor,
                    url: url,
                    afterChunk: {
                        try operationHook(.afterTemporaryWriteChunk, url)
                    }
                )
                try operationHook(.afterTemporaryWrite, url)
                try synchronizeFile(descriptor, url: url)
                try operationHook(.afterTemporaryFileSync, url)
                var temporaryMetadata = stat()
                guard
                    fstat(descriptor, &temporaryMetadata) == 0,
                    Self.isSingleLinkRegularFile(temporaryMetadata),
                    temporaryMetadata.st_size == Int64(data.count)
                else {
                    throw WorkflowDurableFileSystemError.unsafePath(url.path)
                }

                try operationHook(.beforePublishRename, url)
                if replacingExisting {
                    var destinationNow = stat()
                    guard
                        fstatat(
                            parent,
                            name,
                            &destinationNow,
                            AT_SYMLINK_NOFOLLOW
                        ) == 0,
                        Self.sameFile(destinationBefore, destinationNow)
                    else {
                        throw WorkflowDurableFileSystemError.unsafePath(url.path)
                    }
                    let flags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
                    guard
                        renameatx_np(
                            parent,
                            temporaryName,
                            parent,
                            name,
                            flags
                        ) == 0
                    else {
                        throw ioError(operation: "replace_rename", url: url)
                    }
                } else {
                    let flags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    guard
                        renameatx_np(
                            parent,
                            temporaryName,
                            parent,
                            name,
                            flags
                        ) == 0
                    else {
                        throw ioError(operation: "create_rename", url: url)
                    }
                    temporaryExists = false
                }
                published = true
                try operationHook(.afterPublishRename, url)

                var publishedMetadata = stat()
                guard
                    fstatat(
                        parent,
                        name,
                        &publishedMetadata,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0,
                    Self.sameFile(temporaryMetadata, publishedMetadata)
                else {
                    throw WorkflowDurableFileSystemError.unsafePath(url.path)
                }
                try synchronizeDirectory(parent, url: parentURL)
                try operationHook(.afterPublishParentSync, url)
                try validateTrustedRoot()
            } catch {
                if published {
                    temporaryExists = false
                    throw WorkflowDurableFileSystemError.indeterminate(
                        operation: replacingExisting
                            ? "replace_atomically"
                            : "write_new_atomically",
                        path: url.path
                    )
                }
                throw error
            }

            if replacingExisting {
                // After the swap and parent sync, the temporary name contains
                // the old snapshot. Its cleanup cannot invalidate the new one.
                if unlinkat(parent, temporaryName, 0) == 0 {
                    temporaryExists = false
                    try? synchronizeDirectory(parent, url: parentURL)
                }
            }
        }
    }

    func relativeComponents(for url: URL) throws -> [String] {
        guard url.isFileURL else {
            throw WorkflowDurableFileSystemError.unsafePath(url.path)
        }
        let standardized = url.standardizedFileURL
        let rootPath = trustedRootURL.path
        let path = standardized.path
        if path == rootPath { return [] }
        guard path.hasPrefix(rootPath + "/") else {
            throw WorkflowDurableFileSystemError.unsafePath(path)
        }
        let suffix = path.dropFirst(rootPath.count + 1)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.allSatisfy(Self.isSafeComponent) else {
            throw WorkflowDurableFileSystemError.unsafePath(path)
        }
        return components
    }

    func withParentDirectory<Result>(
        of url: URL,
        _ operation: (Int32, String, URL) throws -> Result
    ) throws -> Result {
        let components = try relativeComponents(for: url)
        guard let name = components.last else {
            throw WorkflowDurableFileSystemError.unsafePath(url.path)
        }
        var descriptor = try openTrustedRoot()
        defer { close(descriptor) }
        var parentURL = trustedRootURL
        for component in components.dropLast() {
            let nextDescriptor = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextDescriptor >= 0 else {
                throw WorkflowDurableFileSystemError.unsafePath(url.path)
            }
            close(descriptor)
            descriptor = nextDescriptor
            parentURL.appendPathComponent(component, isDirectory: true)
        }
        let result = try operation(descriptor, name, parentURL)
        try validateTrustedRoot()
        return result
    }

    func openTrustedRoot() throws -> Int32 {
        let descriptor = open(
            trustedRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw WorkflowDurableFileSystemError.unsafePath(
                trustedRootURL.path
            )
        }
        var metadata = stat()
        guard
            fstat(descriptor, &metadata) == 0,
            Self.isDirectory(metadata),
            UInt64(metadata.st_dev) == rootDevice,
            UInt64(metadata.st_ino) == rootFileID
        else {
            close(descriptor)
            throw WorkflowDurableFileSystemError.unsafePath(
                trustedRootURL.path
            )
        }
        return descriptor
    }

    func validateTrustedRoot() throws {
        let descriptor = try openTrustedRoot()
        close(descriptor)
    }

    func writeExactly(
        _ data: Data,
        descriptor: Int32,
        url: URL,
        afterChunk: () throws -> Void
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let requested = min(
                    maximumWriteChunkBytes,
                    bytes.count - offset
                )
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    requested
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw ioError(operation: "write", url: url)
                }
                offset += amount
                try afterChunk()
            }
        }
    }

    func synchronizeFile(_ descriptor: Int32, url: URL) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw ioError(operation: "file_fsync", url: url)
        }
        if durabilityLevel == .powerLoss {
            while fcntl(descriptor, F_FULLFSYNC) != 0 {
                if errno == EINTR { continue }
                throw ioError(operation: "file_fullfsync", url: url)
            }
        }
    }

    func synchronizeDirectory(_ descriptor: Int32, url: URL) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw ioError(operation: "directory_fsync", url: url)
        }
    }

    func ioError(operation: String, url: URL) -> Error {
        WorkflowDurableFileSystemError.ioFailure(
            operation: operation,
            path: url.path,
            code: errno
        )
    }

    static func readExactly(
        data: inout Data,
        descriptor: Int32,
        url: URL
    ) throws {
        try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw WorkflowDurableFileSystemError.ioFailure(
                        operation: "read",
                        path: url.path,
                        code: amount == 0 ? EIO : errno
                    )
                }
                offset += amount
            }
        }
    }

    static func truncate(
        descriptor: Int32,
        byteCount: off_t,
        url: URL
    ) throws {
        while ftruncate(descriptor, byteCount) != 0 {
            if errno == EINTR { continue }
            throw WorkflowDurableFileSystemError.ioFailure(
                operation: "ftruncate",
                path: url.path,
                code: errno
            )
        }
    }

    static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && !component.unicodeScalars.contains(where: { $0.value == 0 })
    }

    static func isDirectory(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    static func isSingleLinkRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG && metadata.st_nlink == 1
    }

    static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
            && lhs.st_nlink == rhs.st_nlink
    }
}
