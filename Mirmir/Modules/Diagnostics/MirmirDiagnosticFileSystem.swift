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
