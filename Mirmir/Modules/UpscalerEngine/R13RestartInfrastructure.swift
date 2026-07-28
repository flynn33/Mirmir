import CryptoKit
import Darwin
import Foundation

// The path resolver and descriptor-pinned filesystem stay together so no
// persistence call can accidentally reintroduce symlink-following traversal.
// swiftlint:disable file_length

protocol R13RestartDigesting: Sendable {
    func sha256(_ data: Data) -> String
}

struct R13CryptoKitRestartDigest: R13RestartDigesting {
    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

protocol R13RestartFileSystem: Sendable {
    func ensureDirectory(_ url: URL) throws
    func createDirectoryExclusively(_ url: URL) throws
    func validateDirectory(_ url: URL) throws
    func exists(_ url: URL) -> Bool
    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data
    func writeNewAtomically(_ data: Data, to url: URL) throws
    func replaceAtomically(_ data: Data, at url: URL) throws
    func publishDirectoryAtomically(from sourceURL: URL, to destinationURL: URL)
        throws
    func removeFile(_ url: URL) throws
    func removeDirectory(_ url: URL) throws
}

struct R13LocalRestartFileSystem: R13RestartFileSystem {
    private let trustedRootURL: URL?

    init() {
        trustedRootURL = nil
    }

    init(trustedRootURL: URL) throws {
        let resolvedRoot = R13RestartPath.resolvingExistingAncestor(
            of: trustedRootURL
        )
        guard resolvedRoot.isFileURL,
              resolvedRoot.path.hasPrefix("/") else {
            throw R13RestartJobError.unsafeFilesystemEntry(
                trustedRootURL.path
            )
        }
        let descriptor = open(
            resolvedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw R13RestartJobError.unsafeFilesystemEntry(
                trustedRootURL.path
            )
        }
        close(descriptor)
        self.trustedRootURL = resolvedRoot
    }

    func ensureDirectory(_ url: URL) throws {
        let traversal = try directoryTraversal(for: url)
        var descriptor = open(
            traversal.startingPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
        defer { close(descriptor) }
        for component in traversal.components {
            var nextDescriptor = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if nextDescriptor < 0 && errno == ENOENT {
                guard mkdirat(descriptor, component, S_IRWXU) == 0,
                      fsync(descriptor) == 0 else {
                    throw R13RestartJobError.ioFailure(
                        operation: "ensure_directory"
                    )
                }
                nextDescriptor = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            close(descriptor)
            descriptor = nextDescriptor
        }
    }

    func validateDirectory(_ url: URL) throws {
        let descriptor = try openDirectory(url)
        close(descriptor)
    }

    func exists(_ url: URL) -> Bool {
        let observed = try? withParentDirectory(of: url) { descriptor, name in
            var metadata = stat()
            return fstatat(
                descriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        }
        return observed ?? false
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw R13RestartJobError.fileTooLarge(
                path: url.path,
                maximumBytes: maximumBytes
            )
        }
        return try withParentDirectory(of: url) { parent, name in
            var before = stat()
            guard fstatat(
                parent,
                name,
                &before,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            isBoundedRegularFile(before, maximumBytes: maximumBytes) else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            let descriptor = openat(
                parent,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  sameSnapshot(before, opened) else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            var data = Data(count: Int(opened.st_size))
            try readExactly(data: &data, descriptor: descriptor, url: url)
            var after = stat()
            var pathAfter = stat()
            guard fstat(descriptor, &after) == 0,
                  sameSnapshot(opened, after),
                  fstatat(
                      parent,
                      name,
                      &pathAfter,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sameSnapshot(after, pathAfter) else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            return data
        }
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try withParentDirectory(of: url) { parent, name in
            var metadata = stat()
            guard fstatat(
                parent,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) != 0,
            errno == ENOENT else {
                throw R13RestartJobError.ioFailure(operation: "write_new")
            }
            let temporaryName = try writeTemporary(
                data,
                parent: parent,
                destinationName: name
            )
            var published = false
            defer {
                if !published {
                    _ = unlinkat(parent, temporaryName, 0)
                }
            }
            guard linkat(
                parent,
                temporaryName,
                parent,
                name,
                0
            ) == 0,
            unlinkat(parent, temporaryName, 0) == 0,
            fsync(parent) == 0 else {
                throw R13RestartJobError.ioFailure(operation: "write_new")
            }
            published = true
        }
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try withParentDirectory(of: url) { parent, name in
            var metadata = stat()
            guard fstatat(
                parent,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            isSingleLinkRegularFile(metadata) else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            let temporaryName = try writeTemporary(
                data,
                parent: parent,
                destinationName: name
            )
            var published = false
            defer {
                if !published {
                    _ = unlinkat(parent, temporaryName, 0)
                }
            }
            guard renameat(
                parent,
                temporaryName,
                parent,
                name
            ) == 0,
            fsync(parent) == 0 else {
                throw R13RestartJobError.ioFailure(operation: "replace")
            }
            published = true
        }
    }

    func removeDirectory(_ url: URL) throws {
        do {
            try validateDirectory(url)
            try FileManager.default.removeItem(at: url)
        } catch let error as R13RestartJobError {
            throw error
        } catch {
            throw R13RestartJobError.ioFailure(operation: "remove_directory")
        }
    }

    func removeFile(_ url: URL) throws {
        try withParentDirectory(of: url) { parent, name in
            var metadata = stat()
            guard fstatat(
                parent,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            (metadata.st_mode & S_IFMT) == S_IFREG,
            metadata.st_nlink == 1,
            unlinkat(parent, name, 0) == 0,
            fsync(parent) == 0 else {
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
        }
    }
}

private extension R13LocalRestartFileSystem {
    private struct DirectoryTraversal {
        let startingPath: String
        let components: [String]
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let traversal = try directoryTraversal(for: url)
        var descriptor = open(
            traversal.startingPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
        for component in traversal.components {
            let nextDescriptor = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard nextDescriptor >= 0 else {
                close(descriptor)
                throw R13RestartJobError.unsafeFilesystemEntry(url.path)
            }
            close(descriptor)
            descriptor = nextDescriptor
        }
        return descriptor
    }

    private func directoryTraversal(
        for url: URL
    ) throws -> DirectoryTraversal {
        let components = try pathComponents(url)
        guard let trustedRootURL else {
            return DirectoryTraversal(
                startingPath: "/",
                components: components
            )
        }
        let trustedComponents = try pathComponents(trustedRootURL)
        guard components.starts(with: trustedComponents) else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
        return DirectoryTraversal(
            startingPath: trustedRootURL.path,
            components: Array(
                components.dropFirst(trustedComponents.count)
            )
        )
    }

    private func withParentDirectory<T>(
        of url: URL,
        _ operation: (_ descriptor: Int32, _ name: String) throws -> T
    ) throws -> T {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
        let descriptor = try openDirectory(
            url.deletingLastPathComponent()
        )
        defer { close(descriptor) }
        return try operation(descriptor, name)
    }

    private func pathComponents(_ url: URL) throws -> [String] {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
        let components = url.path.split(separator: "/").map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
        return components
    }

    private func writeTemporary(
        _ data: Data,
        parent: Int32,
        destinationName: String
    ) throws -> String {
        let temporaryName =
            ".\(destinationName).\(UUID().uuidString).tmp"
        let descriptor = openat(
            parent,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw R13RestartJobError.ioFailure(operation: "write_temporary")
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded {
                _ = unlinkat(parent, temporaryName, 0)
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw R13RestartJobError.ioFailure(
                        operation: "write_temporary"
                    )
                }
                let amount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard amount > 0 else {
                    throw R13RestartJobError.ioFailure(
                        operation: "write_temporary"
                    )
                }
                offset += amount
            }
        }
        guard fsync(descriptor) == 0 else {
            throw R13RestartJobError.ioFailure(operation: "write_temporary")
        }
        succeeded = true
        return temporaryName
    }

    private func readExactly(
        data: inout Data,
        descriptor: Int32,
        url: URL
    ) throws {
        let expectedByteCount = data.count
        let actualByteCount: Int = try data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard amount > 0 else {
                    throw R13RestartJobError.unsafeFilesystemEntry(url.path)
                }
                offset += amount
            }
            return offset
        }
        guard actualByteCount == expectedByteCount else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
    }

    private func isBoundedRegularFile(
        _ metadata: stat,
        maximumBytes: Int
    ) -> Bool {
        isSingleLinkRegularFile(metadata)
            && metadata.st_size > 0
            && metadata.st_size <= maximumBytes
    }

    private func isSingleLinkRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
    }

    private func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func sameDirectoryObject(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        (lhs.st_mode & S_IFMT) == S_IFDIR
            && (rhs.st_mode & S_IFMT) == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func posixError(path: URL, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSFilePathErrorKey: path.path,
                NSLocalizedDescriptionKey: String(cString: strerror(code))
            ]
        )
    }
}

extension R13LocalRestartFileSystem {
    func createDirectoryExclusively(_ url: URL) throws {
        try withParentDirectory(of: url) { parent, name in
            guard mkdirat(parent, name, S_IRWXU) == 0 else {
                throw Self.posixError(path: url, code: errno)
            }
            guard fsync(parent) == 0 else {
                let synchronizationError = Self.posixError(
                    path: url.deletingLastPathComponent(),
                    code: errno
                )
                _ = unlinkat(parent, name, AT_REMOVEDIR)
                throw synchronizationError
            }
        }
    }

    // The pre/post identity checks and rename must remain one visible syscall
    // transaction, so splitting this body would obscure its failure boundary.
    // swiftlint:disable:next function_body_length
    func publishDirectoryAtomically(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let sourceParent = sourceURL.deletingLastPathComponent()
            .standardizedFileURL
        let destinationParent = destinationURL.deletingLastPathComponent()
            .standardizedFileURL
        guard sourceParent == destinationParent else {
            throw R13RestartJobError.unsafeFilesystemEntry(
                destinationURL.path
            )
        }
        try withParentDirectory(of: sourceURL) { parent, sourceName in
            let destinationName = destinationURL.lastPathComponent
            guard !destinationName.isEmpty,
                  destinationName != ".",
                  destinationName != ".." else {
                throw R13RestartJobError.unsafeFilesystemEntry(
                    destinationURL.path
                )
            }
            let descriptor = openat(
                parent,
                sourceName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw R13RestartJobError.unsafeFilesystemEntry(
                    sourceURL.path
                )
            }
            defer { close(descriptor) }

            var descriptorBefore = stat()
            var pathBefore = stat()
            guard fstat(descriptor, &descriptorBefore) == 0,
                  fstatat(
                      parent,
                      sourceName,
                      &pathBefore,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  Self.sameDirectoryObject(
                      descriptorBefore,
                      pathBefore
                  ),
                  fsync(descriptor) == 0 else {
                throw R13RestartJobError.unsafeFilesystemEntry(
                    sourceURL.path
                )
            }

            var destinationBefore = stat()
            let destinationStatus = fstatat(
                parent,
                destinationName,
                &destinationBefore,
                AT_SYMLINK_NOFOLLOW
            )
            let destinationErrno = errno
            guard destinationStatus != 0 else {
                throw Self.posixError(
                    path: destinationURL,
                    code: EEXIST
                )
            }
            guard destinationErrno == ENOENT else {
                throw Self.posixError(
                    path: destinationURL,
                    code: destinationErrno
                )
            }

            guard renameatx_np(
                parent,
                sourceName,
                parent,
                destinationName,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw Self.posixError(
                    path: destinationURL,
                    code: errno
                )
            }

            var descriptorAfter = stat()
            var destinationAfter = stat()
            let sourceStatus = fstatat(
                parent,
                sourceName,
                &pathBefore,
                AT_SYMLINK_NOFOLLOW
            )
            let sourceErrno = errno
            guard fstat(descriptor, &descriptorAfter) == 0,
                  fstatat(
                      parent,
                      destinationName,
                      &destinationAfter,
                      AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  Self.sameDirectoryObject(
                      descriptorBefore,
                      descriptorAfter
                  ),
                  Self.sameDirectoryObject(
                      descriptorAfter,
                      destinationAfter
                  ),
                  sourceStatus != 0,
                  sourceErrno == ENOENT,
                  fsync(parent) == 0 else {
                throw R13RestartJobError.ioFailure(
                    operation: "publish_job_directory_postcondition"
                )
            }
        }
    }
}

protocol R13RestartSourceMeasuring: Sendable {
    func measureSource(at url: URL) throws -> R13RestartSourceIdentity
}

struct R13LocalRestartSourceMeasurer: R13RestartSourceMeasuring {
    private let readSize = 1_048_576

    func measureSource(at url: URL) throws -> R13RestartSourceIdentity {
        let resolvedURL = R13RestartPath.resolvingExistingAncestor(of: url)
        let descriptor = open(
            resolvedURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw R13RestartJobError.ioFailure(operation: "open_source")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0 else {
            throw R13RestartJobError.unsafeFilesystemEntry(url.path)
        }
        var hasher = SHA256()
        var observedByteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: readSize)
        while true {
            let amount = Darwin.read(descriptor, &buffer, buffer.count)
            guard amount >= 0 else {
                throw R13RestartJobError.ioFailure(operation: "read_source")
            }
            guard amount > 0 else { break }
            hasher.update(data: Data(buffer.prefix(amount)))
            observedByteCount += UInt64(amount)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameSourceSnapshot(before, after),
              observedByteCount == UInt64(before.st_size) else {
            throw R13RestartJobError.ioFailure(operation: "source_changed")
        }
        return try R13RestartSourceIdentity(
            sha256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined(),
            byteCount: observedByteCount
        )
    }

    private func sameSourceSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

enum R13RestartCanonical {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

enum R13RestartPath {
    static func resolvingExistingAncestor(of url: URL) -> URL {
        var existingAncestor = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(
            atPath: existingAncestor.path
        ) {
            let component = existingAncestor.lastPathComponent
            let parent = existingAncestor.deletingLastPathComponent()
            guard !component.isEmpty,
                  parent.path != existingAncestor.path else {
                break
            }
            missingComponents.append(component)
            existingAncestor = parent
        }
        let resolvedAncestor: URL
        if let resolvedPath = realpath(existingAncestor.path, nil) {
            defer { free(resolvedPath) }
            resolvedAncestor = URL(
                fileURLWithPath: String(cString: resolvedPath),
                isDirectory: true
            )
        } else {
            resolvedAncestor = existingAncestor.resolvingSymlinksInPath()
        }
        var resolved = resolvedAncestor
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: true)
        }
        return resolved
    }
}

enum R13RestartValidation {
    static func jobID(_ value: String) throws -> String {
        try identity(value, field: "job_id")
    }

    static func identity(_ value: String, field: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 192,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || $0 == "."
                      || $0 == "_"
                      || $0 == "-"
                      || $0 == ":"
              }) else {
            throw R13RestartJobError.invalidIdentity(field: field)
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x61 && $0.value <= 0x66)
              }) else {
            throw R13RestartJobError.invalidSHA256(field: field)
        }
        return value
    }

    static func relativePath(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 512,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\u{0}") else {
            throw R13RestartJobError.invalidRelativePath(value)
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        }) else {
            throw R13RestartJobError.invalidRelativePath(value)
        }
        return value
    }
}

// swiftlint:enable file_length
