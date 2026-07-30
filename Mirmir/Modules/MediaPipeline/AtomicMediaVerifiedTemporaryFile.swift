import CryptoKit
import Darwin
import Foundation

struct AtomicMediaPinnedFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let ownerUserID: UInt32
    let mode: UInt32
    let linkCount: UInt64
    let byteCount: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    init?(
        _ metadata: stat,
        requirePopulatedFile: Bool = true
    ) {
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              !requirePopulatedFile || metadata.st_size > 0 else {
            return nil
        }
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        ownerUserID = UInt32(metadata.st_uid)
        mode = UInt32(metadata.st_mode)
        linkCount = UInt64(metadata.st_nlink)
        byteCount = UInt64(metadata.st_size)
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    }

    func refersToSameFileObject(
        as other: AtomicMediaPinnedFileIdentity
    ) -> Bool {
        device == other.device
            && inode == other.inode
            && ownerUserID == other.ownerUserID
            && (mode & UInt32(S_IFMT)) == (other.mode & UInt32(S_IFMT))
            && linkCount == 1
            && other.linkCount == 1
    }
}

struct AtomicMediaCleanupFileIdentity: Equatable, Sendable {
    let file: AtomicMediaPinnedFileIdentity
    let contents: MediaOutputPublicationIdentity
}

final class AtomicMediaVerifiedTemporaryFile {
    let publicationIdentity: MediaOutputPublicationIdentity

    private let sourceURL: URL
    private let descriptor: Int32
    private let pinnedIdentity: AtomicMediaPinnedFileIdentity

    init(
        url: URL,
        requirePopulatedFile: Bool = true
    ) throws {
        let descriptor = open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw AtomicMediaOutputError.verifiedTemporaryFileChanged(url)
        }
        do {
            let descriptorIdentity = try Self.identity(
                descriptor: descriptor,
                url: url,
                requirePopulatedFile: requirePopulatedFile
            )
            guard descriptorIdentity == (try Self.identity(
                path: url,
                requirePopulatedFile: requirePopulatedFile
            )) else {
                throw AtomicMediaOutputError.verifiedTemporaryFileChanged(url)
            }
            sourceURL = url
            self.descriptor = descriptor
            pinnedIdentity = descriptorIdentity
            publicationIdentity = MediaOutputPublicationIdentity(
                sha256: try Self.sha256(descriptor: descriptor, url: url),
                byteCount: descriptorIdentity.byteCount
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit {
        close(descriptor)
    }

    func makeCleanupIdentity() throws
        -> AtomicMediaCleanupFileIdentity {
        let before = try Self.identity(
            descriptor: descriptor,
            url: sourceURL,
            requirePopulatedFile: false
        )
        guard before.refersToSameFileObject(as: pinnedIdentity) else {
            throw AtomicMediaOutputError
                .verifiedTemporaryFileChanged(sourceURL)
        }
        let digest = try Self.sha256(
            descriptor: descriptor,
            url: sourceURL
        )
        let after = try Self.identity(
            descriptor: descriptor,
            url: sourceURL,
            requirePopulatedFile: false
        )
        guard before == after else {
            throw AtomicMediaOutputError
                .verifiedTemporaryFileChanged(sourceURL)
        }
        return AtomicMediaCleanupFileIdentity(
            file: after,
            contents: MediaOutputPublicationIdentity(
                sha256: digest,
                byteCount: after.byteCount
            )
        )
    }

    func makePinnedFileIdentity() throws
        -> AtomicMediaPinnedFileIdentity {
        let descriptorIdentity = try Self.identity(
            descriptor: descriptor,
            url: sourceURL,
            requirePopulatedFile: false
        )
        let pathIdentity = try Self.identity(
            path: sourceURL,
            requirePopulatedFile: false
        )
        guard descriptorIdentity == pathIdentity,
              descriptorIdentity.refersToSameFileObject(
                as: pinnedIdentity
              ) else {
            throw AtomicMediaOutputError
                .verifiedTemporaryFileChanged(sourceURL)
        }
        return descriptorIdentity
    }

    func validatePathAndContents(at path: URL) throws {
        let descriptorIdentityBeforeHash = try Self.identity(
            descriptor: descriptor,
            url: sourceURL
        )
        let pathIdentityBeforeHash = try Self.identity(path: path)
        let digest = try Self.sha256(
            descriptor: descriptor,
            url: sourceURL
        )
        let descriptorIdentityAfterHash = try Self.identity(
            descriptor: descriptor,
            url: sourceURL
        )
        let pathIdentityAfterHash = try Self.identity(path: path)
        guard descriptorIdentityBeforeHash == pinnedIdentity,
              pathIdentityBeforeHash == pinnedIdentity,
              descriptorIdentityAfterHash == pinnedIdentity,
              pathIdentityAfterHash == pinnedIdentity,
              digest == publicationIdentity.sha256 else {
            throw AtomicMediaOutputError
                .verifiedTemporaryFileChanged(sourceURL)
        }
    }

    private static func identity(
        descriptor: Int32,
        url: URL,
        requirePopulatedFile: Bool = true
    ) throws -> AtomicMediaPinnedFileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              let identity = AtomicMediaPinnedFileIdentity(
                metadata,
                requirePopulatedFile: requirePopulatedFile
              ) else {
            throw AtomicMediaOutputError.verifiedTemporaryFileChanged(url)
        }
        return identity
    }

    private static func identity(
        path: URL,
        requirePopulatedFile: Bool = true
    ) throws -> AtomicMediaPinnedFileIdentity {
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0,
              let identity = AtomicMediaPinnedFileIdentity(
                metadata,
                requirePopulatedFile: requirePopulatedFile
              ) else {
            throw AtomicMediaOutputError.verifiedTemporaryFileChanged(path)
        }
        return identity
    }

    private static func sha256(
        descriptor: Int32,
        url: URL
    ) throws -> String {
        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = pread(descriptor, &buffer, buffer.count, offset)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw AtomicMediaOutputError.verifiedTemporaryFileChanged(url)
            }
            guard count > 0 else { break }
            hasher.update(data: Data(buffer.prefix(Int(count))))
            offset += off_t(count)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}
