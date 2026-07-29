import Darwin
import Foundation

enum MirmirDiagnosticFileSystemError: Error, Sendable {
    case unsafeEntry
    case ioFailure
}

protocol MirmirDiagnosticFileSystem: Sendable {
    func ensureDirectory(_ url: URL) throws
    func exists(_ url: URL) -> Bool
    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data
    func writeNewAtomically(_ data: Data, to url: URL) throws
    func replaceAtomically(_ data: Data, at url: URL) throws
    func appendLineDurably(
        _ data: Data,
        to url: URL,
        maximumFileBytes: Int
    ) throws
    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (any MirmirDiagnosticFileSystem) throws -> T
    ) throws -> T
}

struct MirmirLocalDiagnosticFileSystem: MirmirDiagnosticFileSystem {
    private let checkpointFileSystem: any R12CheckpointFileSystem

    init(
        checkpointFileSystem: any R12CheckpointFileSystem =
            R12LocalCheckpointFileSystem()
    ) {
        self.checkpointFileSystem = checkpointFileSystem
    }

    func ensureDirectory(_ url: URL) throws {
        try checkpointFileSystem.ensureDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        checkpointFileSystem.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try checkpointFileSystem.readRegularFile(
            url,
            maximumBytes: maximumBytes
        )
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try checkpointFileSystem.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try checkpointFileSystem.replaceAtomically(data, at: url)
    }

    func appendLineDurably(
        _ data: Data,
        to url: URL,
        maximumFileBytes: Int
    ) throws {
        guard !data.isEmpty, data.last == 0x0A else {
            throw MirmirDiagnosticFileSystemError.ioFailure
        }
        let parentURL = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains("/") else {
            throw MirmirDiagnosticFileSystemError.unsafeEntry
        }
        try checkpointFileSystem.validateDirectory(parentURL)
        let parentDescriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw MirmirDiagnosticFileSystemError.unsafeEntry
        }
        defer { close(parentDescriptor) }

        var openedParent = stat()
        var parentPathBefore = stat()
        guard fstat(parentDescriptor, &openedParent) == 0,
              lstat(parentURL.path, &parentPathBefore) == 0,
              Self.sameDirectory(openedParent, parentPathBefore) else {
            throw MirmirDiagnosticFileSystemError.unsafeEntry
        }
        var before = stat()
        guard fstatat(
            parentDescriptor,
            name,
            &before,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              Self.isSingleLinkRegularFile(before),
              before.st_size >= 0,
              before.st_size <= Int64(maximumFileBytes),
              Int64(data.count) <= Int64(maximumFileBytes) - before.st_size else {
            throw MirmirDiagnosticFileSystemError.unsafeEntry
        }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw MirmirDiagnosticFileSystemError.unsafeEntry
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              Self.sameFile(before, opened) else {
            throw MirmirDiagnosticFileSystemError.unsafeEntry
        }
        try Self.writeExactly(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else {
            throw MirmirDiagnosticFileSystemError.ioFailure
        }

        var after = stat()
        var pathAfter = stat()
        var parentPathAfter = stat()
        guard fstat(descriptor, &after) == 0,
              fstatat(
                  parentDescriptor,
                  name,
                  &pathAfter,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              Self.sameIdentity(after, pathAfter),
              after.st_size == opened.st_size + Int64(data.count),
              lstat(parentURL.path, &parentPathAfter) == 0,
              Self.sameDirectory(openedParent, parentPathAfter) else {
            throw MirmirDiagnosticFileSystemError.ioFailure
        }
        try checkpointFileSystem.validateDirectory(parentURL)
    }

    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (any MirmirDiagnosticFileSystem) throws -> T
    ) throws -> T {
        try checkpointFileSystem.withExclusiveLock(at: url) { transaction in
            try operation(
                MirmirLocalDiagnosticFileSystem(
                    checkpointFileSystem: transaction
                )
            )
        }
    }

    private static func writeExactly(
        _ data: Data,
        descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard amount > 0 else {
                    throw MirmirDiagnosticFileSystemError.ioFailure
                }
                offset += amount
            }
        }
    }

    private static func isSingleLinkRegularFile(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG && value.st_nlink == 1
    }

    private static func sameDirectory(_ lhs: stat, _ rhs: stat) -> Bool {
        (lhs.st_mode & S_IFMT) == S_IFDIR
            && (rhs.st_mode & S_IFMT) == S_IFDIR
            && sameIdentity(lhs, rhs)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameIdentity(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
