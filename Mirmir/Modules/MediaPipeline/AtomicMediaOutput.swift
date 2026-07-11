import Darwin
import Foundation

enum AtomicMediaOutputState: String, Equatable, Sendable {
    case created
    case writing
    case finishing
    case verifying
    case published
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .published, .failed, .cancelled:
            return true
        case .created, .writing, .finishing, .verifying:
            return false
        }
    }
}

enum AtomicMediaOutputError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidDestination(URL)
    case destinationAlreadyExists(URL)
    case invalidTransition(from: AtomicMediaOutputState, to: AtomicMediaOutputState)
    case temporaryFileMissing(URL)
    case publishFailed(destination: URL, reason: String, cleanupFailure: String?)
    case cleanupFailed(temporary: URL, attempts: Int, reason: String?)

    var description: String {
        switch self {
        case .invalidDestination(let url):
            return "Output destination directory does not exist: \(url.deletingLastPathComponent().path)"
        case .destinationAlreadyExists(let url):
            return "Output destination already exists and will not be replaced: \(url.lastPathComponent)."
        case .invalidTransition(let source, let destination):
            return "Invalid output transaction transition: \(source.rawValue) -> \(destination.rawValue)."
        case .temporaryFileMissing(let url):
            return "Output transaction temporary file is missing: \(url.lastPathComponent)."
        case .publishFailed(let destination, let reason, let cleanupFailure):
            let cleanup = cleanupFailure.map { " Cleanup also failed: \($0)" } ?? ""
            return "Atomic output publication failed at \(destination.lastPathComponent): \(reason).\(cleanup)"
        case .cleanupFailed(let temporary, let attempts, let reason):
            return "Temporary output cleanup failed after \(attempts) attempts for "
                + "\(temporary.lastPathComponent): \(reason ?? "file remained present")."
        }
    }
}

struct AtomicMediaOutputCleanupResult: Equatable, Sendable {
    let attempts: Int
    let temporaryFileRemoved: Bool
    let error: AtomicMediaOutputError?
}

struct AtomicMediaOutputSnapshot: Equatable, Sendable {
    let state: AtomicMediaOutputState
    let cleanup: AtomicMediaOutputCleanupResult?
}

protocol AtomicMediaFileSystem: Sendable {
    func directoryExists(at url: URL) -> Bool
    func fileExists(at url: URL) -> Bool
    func removeItem(at url: URL) throws
    func publishAtomically(from temporaryURL: URL, to destinationURL: URL) throws
}

struct LocalAtomicMediaFileSystem: AtomicMediaFileSystem {
    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func publishAtomically(from temporaryURL: URL, to destinationURL: URL) throws {
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
                    NSLocalizedDescriptionKey: String(cString: strerror(errno))
                ]
            )
        }
    }
}

final class AtomicMediaOutput: @unchecked Sendable {
    let destinationURL: URL
    let temporaryURL: URL

    private struct MutableState {
        var state = AtomicMediaOutputState.created
        var cleanup: AtomicMediaOutputCleanupResult?
        var telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    }

    private let fileSystem: any AtomicMediaFileSystem
    private let cleanupAttemptLimit: Int
    private let lock = NSLock()
    private var mutableState = MutableState()

    init(
        destinationURL: URL,
        fileSystem: any AtomicMediaFileSystem = LocalAtomicMediaFileSystem(),
        cleanupAttemptLimit: Int = 3,
        temporaryIdentifier: String = UUID().uuidString
    ) throws {
        let directory = destinationURL.deletingLastPathComponent()
        guard destinationURL.isFileURL,
              fileSystem.directoryExists(at: directory) else {
            throw AtomicMediaOutputError.invalidDestination(destinationURL)
        }
        guard !fileSystem.fileExists(at: destinationURL) else {
            throw AtomicMediaOutputError.destinationAlreadyExists(destinationURL)
        }
        precondition(cleanupAttemptLimit > 0, "Cleanup attempt limit must be positive.")

        self.destinationURL = destinationURL
        self.fileSystem = fileSystem
        self.cleanupAttemptLimit = cleanupAttemptLimit

        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        let pathExtension = destinationURL.pathExtension
        let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        self.temporaryURL = directory.appendingPathComponent(
            ".\(baseName).mirmir-\(temporaryIdentifier).partial\(extensionSuffix)",
            isDirectory: false
        )
    }

    var snapshot: AtomicMediaOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AtomicMediaOutputSnapshot(
            state: mutableState.state,
            cleanup: mutableState.cleanup
        )
    }

    func attachTelemetry(_ telemetry: any ASHTelemetryRecording) {
        lock.lock()
        mutableState.telemetry = telemetry
        let currentState = mutableState.state
        lock.unlock()

        telemetry.recordMedia(ASHMediaObservation(
            kind: "temporary_output_created",
            details: [
                "temporary_name": temporaryURL.lastPathComponent,
                "transaction_state": currentState.rawValue
            ]
        ))
    }

    func beginWriting() throws {
        try transition(from: .created, to: .writing)
    }

    func beginFinishing() throws {
        try transition(from: .writing, to: .finishing)
    }

    func beginVerifying() throws {
        try transition(from: .finishing, to: .verifying)
    }

    func publish() throws {
        lock.lock()
        guard mutableState.state == .verifying else {
            let currentState = mutableState.state
            lock.unlock()
            throw AtomicMediaOutputError.invalidTransition(from: currentState, to: .published)
        }

        guard fileSystem.fileExists(at: temporaryURL) else {
            mutableState.state = .failed
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .failed)
            throw AtomicMediaOutputError.temporaryFileMissing(temporaryURL)
        }

        guard !fileSystem.fileExists(at: destinationURL) else {
            let cleanup = cleanupTemporaryLocked()
            mutableState.cleanup = cleanup
            mutableState.state = .failed
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .failed)
            recordCleanup(telemetry: telemetry, result: cleanup, terminalState: .failed)
            throw AtomicMediaOutputError.destinationAlreadyExists(destinationURL)
        }

        do {
            try fileSystem.publishAtomically(from: temporaryURL, to: destinationURL)
            guard fileSystem.fileExists(at: destinationURL),
                  !fileSystem.fileExists(at: temporaryURL) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: "atomic publish postcondition failed"]
                )
            }
            mutableState.state = .published
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .published)
            telemetry.recordMedia(ASHMediaObservation(
                kind: "output_published",
                details: ["destination_name": destinationURL.lastPathComponent]
            ))
        } catch {
            let reason = String(describing: error)
            let fileSystemError = error as NSError
            let destinationWonRace = fileSystemError.domain == NSPOSIXErrorDomain
                && fileSystemError.code == Int(EEXIST)
            let cleanup = cleanupTemporaryLocked()
            mutableState.cleanup = cleanup
            mutableState.state = .failed
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .failed)
            recordCleanup(telemetry: telemetry, result: cleanup, terminalState: .failed)
            if destinationWonRace {
                throw AtomicMediaOutputError.destinationAlreadyExists(destinationURL)
            }
            throw AtomicMediaOutputError.publishFailed(
                destination: destinationURL,
                reason: reason,
                cleanupFailure: cleanup.error.map(String.init(describing:))
            )
        }
    }

    @discardableResult
    func fail() -> AtomicMediaOutputCleanupResult {
        terminate(as: .failed)
    }

    @discardableResult
    func cancel() -> AtomicMediaOutputCleanupResult {
        terminate(as: .cancelled)
    }

    deinit {
        _ = fail()
    }

    private func transition(from expected: AtomicMediaOutputState, to target: AtomicMediaOutputState) throws {
        lock.lock()
        guard mutableState.state == expected else {
            let currentState = mutableState.state
            lock.unlock()
            throw AtomicMediaOutputError.invalidTransition(from: currentState, to: target)
        }
        mutableState.state = target
        let telemetry = mutableState.telemetry
        lock.unlock()
        recordTransition(telemetry: telemetry, from: expected, to: target)
    }

    private func terminate(as terminalState: AtomicMediaOutputState) -> AtomicMediaOutputCleanupResult {
        precondition(terminalState == .failed || terminalState == .cancelled)
        lock.lock()
        if mutableState.state.isTerminal {
            let existing = mutableState.cleanup ?? AtomicMediaOutputCleanupResult(
                attempts: 0,
                temporaryFileRemoved: !fileSystem.fileExists(at: temporaryURL),
                error: nil
            )
            lock.unlock()
            return existing
        }

        let previousState = mutableState.state
        let cleanup = cleanupTemporaryLocked()
        mutableState.cleanup = cleanup
        mutableState.state = terminalState
        let telemetry = mutableState.telemetry
        lock.unlock()

        recordTransition(telemetry: telemetry, from: previousState, to: terminalState)
        recordCleanup(telemetry: telemetry, result: cleanup, terminalState: terminalState)
        return cleanup
    }

    private func cleanupTemporaryLocked() -> AtomicMediaOutputCleanupResult {
        guard fileSystem.fileExists(at: temporaryURL) else {
            return AtomicMediaOutputCleanupResult(
                attempts: 0,
                temporaryFileRemoved: true,
                error: nil
            )
        }

        var attempts = 0
        var lastFailure: String?
        while attempts < cleanupAttemptLimit, fileSystem.fileExists(at: temporaryURL) {
            attempts += 1
            do {
                try fileSystem.removeItem(at: temporaryURL)
            } catch {
                lastFailure = String(describing: error)
            }
        }

        let wasRemoved = !fileSystem.fileExists(at: temporaryURL)
        let error = wasRemoved ? nil : AtomicMediaOutputError.cleanupFailed(
            temporary: temporaryURL,
            attempts: attempts,
            reason: lastFailure
        )
        return AtomicMediaOutputCleanupResult(
            attempts: attempts,
            temporaryFileRemoved: wasRemoved,
            error: error
        )
    }

    private func recordTransition(
        telemetry: any ASHTelemetryRecording,
        from source: AtomicMediaOutputState,
        to destination: AtomicMediaOutputState
    ) {
        telemetry.recordMedia(ASHMediaObservation(
            kind: "output_transaction_transition",
            details: [
                "from": source.rawValue,
                "to": destination.rawValue,
                "temporary_name": temporaryURL.lastPathComponent
            ]
        ))
    }

    private func recordCleanup(
        telemetry: any ASHTelemetryRecording,
        result: AtomicMediaOutputCleanupResult,
        terminalState: AtomicMediaOutputState
    ) {
        telemetry.recordMedia(ASHMediaObservation(
            kind: "temporary_output_cleanup",
            details: [
                "attempts": String(result.attempts),
                "temporary_removed": String(result.temporaryFileRemoved),
                "terminal_state": terminalState.rawValue
            ]
        ))
        if let error = result.error {
            telemetry.increment(.partialCleanupFailures)
            telemetry.recordError(error)
        }
    }
}
