import Foundation

enum MirmirDiagnosticFileSystemError: Error, Sendable {
    case unsafeEntry
    case ioFailure
}
protocol MirmirDiagnosticFileSystem: Sendable {
    func ensureDirectory(_ url: URL) throws
    func exists(_ url: URL) -> Bool
    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data
    func readRegularFileWithRevision(
        _ url: URL, maximumBytes: Int
    ) throws -> (data: Data, revision: WorkflowRegularFileRevision?)
    func regularFileRevision(
        _ url: URL,
        maximumBytes: Int
    ) throws -> WorkflowRegularFileRevision?
    func writeNewAtomically(_ data: Data, to url: URL) throws
    func replaceAtomically(_ data: Data, at url: URL) throws
    func appendLineDurably(
        _ data: Data,
        to url: URL,
        maximumFileBytes: Int
    ) throws
    func appendLineDurablyWithRevision(
        _ data: Data, to url: URL, maximumFileBytes: Int,
        expectedRevision: WorkflowRegularFileRevision?
    ) throws -> WorkflowRegularFileRevision?
    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (any MirmirDiagnosticFileSystem) throws -> T
    ) throws -> T
}

extension MirmirDiagnosticFileSystem {
    func readRegularFileWithRevision(
        _ url: URL, maximumBytes: Int
    ) throws -> (data: Data, revision: WorkflowRegularFileRevision?) {
        (try readRegularFile(url, maximumBytes: maximumBytes), nil)
    }

    func appendLineDurablyWithRevision(
        _ data: Data, to url: URL, maximumFileBytes: Int,
        expectedRevision: WorkflowRegularFileRevision?
    ) throws -> WorkflowRegularFileRevision? {
        try appendLineDurably(data, to: url, maximumFileBytes: maximumFileBytes)
        return nil
    }

    func regularFileRevision(
        _ url: URL,
        maximumBytes: Int
    ) throws -> WorkflowRegularFileRevision? { nil }
}

/// The diagnostics journal shares the application's descriptor-relative,
/// symlink-rejecting durable filesystem implementation. This adapter keeps
/// the diagnostics persistence contract independently testable while avoiding
/// a second persistence implementation.
struct MirmirLocalDiagnosticFileSystem: MirmirDiagnosticFileSystem {
    private let durableFileSystem: any WorkflowDurableFileSystem

    init(rootURL: URL) throws {
        durableFileSystem = try WorkflowLocalDurableFileSystem(
            trustedRootURL: rootURL
        )
    }

    func readRegularFileWithRevision(
        _ url: URL, maximumBytes: Int
    ) throws -> (data: Data, revision: WorkflowRegularFileRevision?) {
        if let local = durableFileSystem as? WorkflowLocalDurableFileSystem {
            let read = try local.readRegularFileWithRevision(
                url, maximumBytes: maximumBytes
            )
            return (read.data, read.revision)
        }
        return (try readRegularFile(url, maximumBytes: maximumBytes), nil)
    }

    private init(durableFileSystem: any WorkflowDurableFileSystem) {
        self.durableFileSystem = durableFileSystem
    }

    func ensureDirectory(_ url: URL) throws {
        try durableFileSystem.ensureDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        (try? durableFileSystem.regularFileExists(url)) == true
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try durableFileSystem.readRegularFile(
            url,
            maximumBytes: maximumBytes
        )
    }

    func regularFileRevision(
        _ url: URL,
        maximumBytes: Int
    ) throws -> WorkflowRegularFileRevision? {
        try (durableFileSystem as? WorkflowLocalDurableFileSystem)?
            .regularFileRevision(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try durableFileSystem.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try durableFileSystem.replaceAtomically(data, at: url)
    }

    func appendLineDurably(
        _ data: Data,
        to url: URL,
        maximumFileBytes: Int
    ) throws {
        guard !data.isEmpty, data.last == 0x0A else {
            throw MirmirDiagnosticFileSystemError.ioFailure
        }
        try durableFileSystem.appendDurably(
            data,
            to: url,
            maximumFileBytes: maximumFileBytes
        )
    }

    func appendLineDurablyWithRevision(
        _ data: Data, to url: URL, maximumFileBytes: Int,
        expectedRevision: WorkflowRegularFileRevision?
    ) throws -> WorkflowRegularFileRevision? {
        guard !data.isEmpty, data.last == 0x0A else {
            throw MirmirDiagnosticFileSystemError.ioFailure
        }
        if let local = durableFileSystem as? WorkflowLocalDurableFileSystem {
            return try local.appendDurablyWithRevision(
                data, to: url, maximumFileBytes: maximumFileBytes,
                expectedRevision: expectedRevision
            )
        }
        try appendLineDurably(data, to: url, maximumFileBytes: maximumFileBytes)
        return nil
    }

    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (any MirmirDiagnosticFileSystem) throws -> T
    ) throws -> T {
        try durableFileSystem.withExclusiveLock(at: url) { transaction in
            try operation(
                MirmirLocalDiagnosticFileSystem(
                    durableFileSystem: transaction
                )
            )
        }
    }
}
