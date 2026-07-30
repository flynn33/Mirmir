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
    case invalidTemporaryIdentifier(String)
    case transactionDirectoryBusy(URL)
    case transactionDirectoryUnavailable(URL, reason: String)
    case unsafeTemporaryFile(URL)
    case unownedTemporaryFilePreserved(URL)
    case invalidTransition(from: AtomicMediaOutputState, to: AtomicMediaOutputState)
    case temporaryFileMissing(URL)
    case verifiedTemporaryFileChanged(URL)
    case publishedDestinationCleanupFailed(destination: URL, reason: String)
    case publishFailed(destination: URL, reason: String, cleanupFailure: String?)
    case cleanupFailed(temporary: URL, attempts: Int, reason: String?)

    var description: String {
        switch self {
        case .invalidDestination(let url):
            return "Output destination directory does not exist: \(url.deletingLastPathComponent().path)"
        case .destinationAlreadyExists(let url):
            return "Output destination already exists and will not be replaced: \(url.lastPathComponent)."
        case .invalidTemporaryIdentifier(let identifier):
            return "Output transaction identifier is invalid: \(identifier)"
        case .transactionDirectoryBusy(let url):
            return "Another output transaction is active in: \(url.path)"
        case .transactionDirectoryUnavailable(let url, let reason):
            return "The output transaction directory is unavailable at "
                + "\(url.path): \(reason)"
        case .unsafeTemporaryFile(let url):
            return "The output transaction path is not an owned, single-link "
                + "regular file: \(url.lastPathComponent)."
        case .unownedTemporaryFilePreserved(let url):
            return "An output transaction path not owned by this attempt "
                + "was preserved: \(url.lastPathComponent)."
        case .invalidTransition(let source, let destination):
            return "Invalid output transaction transition: \(source.rawValue) -> \(destination.rawValue)."
        case .temporaryFileMissing(let url):
            return "Output transaction temporary file is missing: \(url.lastPathComponent)."
        case .verifiedTemporaryFileChanged(let url):
            return "Verified temporary output changed before publication: \(url.lastPathComponent)."
        case .publishedDestinationCleanupFailed(let destination, let reason):
            return "Published destination cleanup failed at "
                + "\(destination.lastPathComponent): \(reason)"
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

public struct MediaOutputPublicationIdentity: Equatable, Sendable {
    public let sha256: String
    public let byteCount: UInt64

    public init(sha256: String, byteCount: UInt64) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

protocol AtomicMediaFileSystem: Sendable {
    func directoryExists(at url: URL) -> Bool
    func fileExists(at url: URL) -> Bool
    func pathEntryExists(at url: URL) -> Bool
    func acquireTransactionLease(
        for destinationURL: URL
    ) throws -> AtomicMediaTransactionLease
    @discardableResult
    func reclaimTransactionTemporaryFile(at url: URL) throws -> Bool
    func discardTransactionTemporaryFileReservation(at url: URL) throws
    func removeItem(at url: URL) throws
    func removeItem(
        at url: URL, ifMatchingFile identity: AtomicMediaPinnedFileIdentity
    ) throws
    func removeItem(
        at url: URL, ifMatching identity: AtomicMediaCleanupFileIdentity
    ) throws
    func publishAtomically(from temporaryURL: URL, to destinationURL: URL) throws
}

final class AtomicMediaTransactionLease: @unchecked Sendable {
    private let lock = NSLock()
    private let directoryURL: URL
    private let validationAction: @Sendable (Int32) throws -> Void
    private let releaseAction: @Sendable (Int32) -> Void
    private var descriptor: Int32?

    init(
        directoryURL: URL,
        descriptor: Int32,
        validationAction: @escaping @Sendable (Int32) throws -> Void,
        releaseAction: @escaping @Sendable (Int32) -> Void
    ) {
        self.directoryURL = directoryURL
        self.descriptor = descriptor
        self.validationAction = validationAction
        self.releaseAction = releaseAction
    }

    func validate() throws {
        lock.lock()
        guard let descriptor else {
            lock.unlock()
            throw AtomicMediaOutputError.transactionDirectoryUnavailable(
                directoryURL,
                reason: "transaction lease is no longer active"
            )
        }
        defer { lock.unlock() }
        try validationAction(descriptor)
    }

    func release() {
        lock.lock()
        guard let descriptor else {
            lock.unlock()
            return
        }
        self.descriptor = nil
        lock.unlock()
        releaseAction(descriptor)
    }

    deinit {
        release()
    }
}

final class AtomicMediaOutput: @unchecked Sendable {
    let destinationURL: URL
    let temporaryURL: URL
    let reclaimedStaleTemporaryFile: Bool

    private struct MutableState {
        var state = AtomicMediaOutputState.created
        var cleanup: AtomicMediaOutputCleanupResult?
        var publishedIdentity: MediaOutputPublicationIdentity?
        var telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    }

    private let fileSystem: any AtomicMediaFileSystem
    private let cleanupAttemptLimit: Int
    private let transactionLease: AtomicMediaTransactionLease
    private let lock = NSLock()
    private var mutableState = MutableState()
    private var verifiedTemporaryFile: AtomicMediaVerifiedTemporaryFile?

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
        guard Self.isValidTemporaryIdentifier(temporaryIdentifier) else {
            throw AtomicMediaOutputError.invalidTemporaryIdentifier(temporaryIdentifier)
        }
        precondition(cleanupAttemptLimit > 0, "Cleanup attempt limit must be positive.")

        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        let pathExtension = destinationURL.pathExtension
        let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        let temporaryURL = directory.appendingPathComponent(
            ".\(baseName).mirmir-\(temporaryIdentifier).partial\(extensionSuffix)",
            isDirectory: false
        )
        let transactionLease = try fileSystem.acquireTransactionLease(
            for: destinationURL
        )
        let reclaimedStaleTemporaryFile: Bool
        do {
            try transactionLease.validate()
            reclaimedStaleTemporaryFile = try fileSystem
                .reclaimTransactionTemporaryFile(at: temporaryURL)
        } catch {
            transactionLease.release()
            throw error
        }

        self.destinationURL = destinationURL
        self.temporaryURL = temporaryURL
        self.reclaimedStaleTemporaryFile = reclaimedStaleTemporaryFile
        self.fileSystem = fileSystem
        self.cleanupAttemptLimit = cleanupAttemptLimit
        self.transactionLease = transactionLease
    }

    static func isValidTemporaryIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty,
              identifier.utf8.count <= 160,
              identifier != ".",
              identifier != ".." else {
            return false
        }
        return identifier.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return true
            case 45, 46, 58, 95:
                return true
            default:
                return false
            }
        }
    }

    var snapshot: AtomicMediaOutputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return AtomicMediaOutputSnapshot(
            state: mutableState.state,
            cleanup: mutableState.cleanup
        )
    }

    var publishedOutputIdentity: MediaOutputPublicationIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return mutableState.publishedIdentity
    }

    var fileSystemForSiblingTemporaryFiles:
        any AtomicMediaFileSystem {
        fileSystem
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
                "stale_temporary_reclaimed":
                    String(reclaimedStaleTemporaryFile),
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

    func claimTemporaryFileForVerification() throws {
        lock.lock()
        guard mutableState.state == .finishing,
              verifiedTemporaryFile == nil else {
            let currentState = mutableState.state
            lock.unlock()
            throw AtomicMediaOutputError.invalidTransition(
                from: currentState,
                to: .verifying
            )
        }
        do {
            try transactionLease.validate()
            verifiedTemporaryFile = try AtomicMediaVerifiedTemporaryFile(
                url: temporaryURL
            )
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func beginVerifying() throws {
        lock.lock()
        guard mutableState.state == .finishing else {
            let currentState = mutableState.state
            lock.unlock()
            throw AtomicMediaOutputError.invalidTransition(
                from: currentState,
                to: .verifying
            )
        }
        if let verifiedTemporaryFile {
            do {
                try transactionLease.validate()
                try verifiedTemporaryFile.validatePathAndContents(
                    at: temporaryURL
                )
            } catch {
                lock.unlock()
                throw error
            }
        } else {
            do {
                try transactionLease.validate()
                verifiedTemporaryFile = try AtomicMediaVerifiedTemporaryFile(
                    url: temporaryURL
                )
            } catch {
                lock.unlock()
                throw error
            }
        }
        mutableState.state = .verifying
        let telemetry = mutableState.telemetry
        lock.unlock()
        recordTransition(telemetry: telemetry, from: .finishing, to: .verifying)
    }

    func publish() throws {
        lock.lock()
        guard mutableState.state == .verifying else {
            let currentState = mutableState.state
            lock.unlock()
            throw AtomicMediaOutputError.invalidTransition(from: currentState, to: .published)
        }

        guard fileSystem.fileExists(at: temporaryURL) else {
            let cleanup = cleanupTemporaryLocked()
            mutableState.cleanup = cleanup
            mutableState.state = .failed
            transactionLease.release()
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .failed)
            recordCleanup(
                telemetry: telemetry,
                result: cleanup,
                terminalState: .failed
            )
            throw AtomicMediaOutputError.temporaryFileMissing(temporaryURL)
        }
        guard let verifiedTemporaryFile else {
            mutableState.state = .failed
            transactionLease.release()
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .failed)
            throw AtomicMediaOutputError.verifiedTemporaryFileChanged(
                temporaryURL
            )
        }

        guard !fileSystem.fileExists(at: destinationURL) else {
            let cleanup = cleanupTemporaryLocked()
            mutableState.cleanup = cleanup
            mutableState.state = .failed
            transactionLease.release()
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .failed)
            recordCleanup(telemetry: telemetry, result: cleanup, terminalState: .failed)
            throw AtomicMediaOutputError.destinationAlreadyExists(destinationURL)
        }

        var publicationCompleted = false
        do {
            try transactionLease.validate()
            try verifiedTemporaryFile.validatePathAndContents(
                at: temporaryURL
            )
            try fileSystem.publishAtomically(from: temporaryURL, to: destinationURL)
            publicationCompleted = true
            guard fileSystem.fileExists(at: destinationURL),
                  !fileSystem.fileExists(at: temporaryURL) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: "atomic publish postcondition failed"]
                )
            }
            try verifiedTemporaryFile.validatePathAndContents(
                at: destinationURL
            )
            mutableState.state = .published
            mutableState.publishedIdentity =
                verifiedTemporaryFile.publicationIdentity
            self.verifiedTemporaryFile = nil
            transactionLease.release()
            let telemetry = mutableState.telemetry
            lock.unlock()
            recordTransition(telemetry: telemetry, from: .verifying, to: .published)
            telemetry.recordMedia(ASHMediaObservation(
                kind: "output_published",
                details: ["destination_name": destinationURL.lastPathComponent]
            ))
        } catch {
            throw handlePublicationFailureLocked(
                error,
                publicationCompleted: publicationCompleted,
                verifiedTemporaryFile: verifiedTemporaryFile
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

    func validateActiveTransactionLease() throws {
        lock.lock()
        guard !mutableState.state.isTerminal else {
            let currentState = mutableState.state
            lock.unlock()
            throw AtomicMediaOutputError.invalidTransition(
                from: currentState,
                to: currentState
            )
        }
        do {
            try transactionLease.validate()
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }
}

private extension AtomicMediaOutput {
    func transition(from expected: AtomicMediaOutputState, to target: AtomicMediaOutputState) throws {
        lock.lock()
        guard mutableState.state == expected else {
            let currentState = mutableState.state
            lock.unlock()
            throw AtomicMediaOutputError.invalidTransition(from: currentState, to: target)
        }
        do {
            try transactionLease.validate()
        } catch {
            lock.unlock()
            throw error
        }
        mutableState.state = target
        let telemetry = mutableState.telemetry
        lock.unlock()
        recordTransition(telemetry: telemetry, from: expected, to: target)
    }

    func terminate(as terminalState: AtomicMediaOutputState) -> AtomicMediaOutputCleanupResult {
        precondition(terminalState == .failed || terminalState == .cancelled)
        lock.lock()
        if mutableState.state.isTerminal {
            let existing = mutableState.cleanup ?? AtomicMediaOutputCleanupResult(
                attempts: 0,
                temporaryFileRemoved:
                    !fileSystem.pathEntryExists(at: temporaryURL),
                error: nil
            )
            lock.unlock()
            return existing
        }

        let previousState = mutableState.state
        let cleanup = cleanupTemporaryLocked()
        mutableState.cleanup = cleanup
        mutableState.state = terminalState
        verifiedTemporaryFile = nil
        transactionLease.release()
        let telemetry = mutableState.telemetry
        lock.unlock()

        recordTransition(telemetry: telemetry, from: previousState, to: terminalState)
        recordCleanup(telemetry: telemetry, result: cleanup, terminalState: terminalState)
        return cleanup
    }

    func handlePublicationFailureLocked(
        _ error: Error,
        publicationCompleted: Bool,
        verifiedTemporaryFile: AtomicMediaVerifiedTemporaryFile
    ) -> AtomicMediaOutputError {
        let reason = String(describing: error)
        let fileSystemError = error as NSError
        let destinationWonRace = fileSystemError.domain == NSPOSIXErrorDomain
            && fileSystemError.code == Int(EEXIST)
        var destinationCleanupError: AtomicMediaOutputError?
        if publicationCompleted {
            do {
                let cleanupIdentity = try verifiedTemporaryFile.makeCleanupIdentity()
                try fileSystem.removeItem(
                    at: destinationURL,
                    ifMatching: cleanupIdentity
                )
            } catch {
                if let outputError = error as? AtomicMediaOutputError,
                   case .publishedDestinationCleanupFailed = outputError {
                    destinationCleanupError = outputError
                } else {
                    destinationCleanupError =
                        .publishedDestinationCleanupFailed(
                        destination: destinationURL,
                        reason: String(describing: error)
                    )
                }
            }
        }
        let temporaryCleanup = cleanupTemporaryLocked()
        let cleanup = combinedCleanupResult(
            temporaryCleanup,
            destinationCleanupError: destinationCleanupError
        )
        mutableState.cleanup = cleanup
        mutableState.state = .failed
        self.verifiedTemporaryFile = nil
        transactionLease.release()
        let telemetry = mutableState.telemetry
        lock.unlock()
        recordTransition(telemetry: telemetry, from: .verifying, to: .failed)
        recordCleanup(telemetry: telemetry, result: cleanup, terminalState: .failed)

        if destinationWonRace {
            return .destinationAlreadyExists(destinationURL)
        }
        if let outputError = error as? AtomicMediaOutputError,
           case .verifiedTemporaryFileChanged = outputError {
            if !publicationCompleted || cleanup.error == nil {
                return outputError
            }
        }
        return .publishFailed(
            destination: destinationURL,
            reason: reason,
            cleanupFailure: cleanup.error.map(String.init(describing:))
        )
    }

    func combinedCleanupResult(
        _ temporaryCleanup: AtomicMediaOutputCleanupResult,
        destinationCleanupError: AtomicMediaOutputError?
    ) -> AtomicMediaOutputCleanupResult {
        guard let destinationCleanupError else {
            return temporaryCleanup
        }
        let combinedError: AtomicMediaOutputError
        if let temporaryError = temporaryCleanup.error {
            combinedError = .publishedDestinationCleanupFailed(
                destination: destinationURL,
                reason: String(describing: destinationCleanupError)
                    + "; temporary cleanup also failed: "
                    + String(describing: temporaryError)
            )
        } else {
            combinedError = destinationCleanupError
        }
        return AtomicMediaOutputCleanupResult(
            attempts: temporaryCleanup.attempts,
            temporaryFileRemoved: temporaryCleanup.temporaryFileRemoved,
            error: combinedError
        )
    }

    func cleanupTemporaryLocked() -> AtomicMediaOutputCleanupResult {
        guard fileSystem.pathEntryExists(at: temporaryURL) else {
            do {
                try fileSystem.discardTransactionTemporaryFileReservation(
                    at: temporaryURL
                )
            } catch {
                return AtomicMediaOutputCleanupResult(
                    attempts: 0,
                    temporaryFileRemoved: true,
                    error: .cleanupFailed(
                        temporary: temporaryURL,
                        attempts: 0,
                        reason: "ownership reservation cleanup failed: "
                            + String(describing: error)
                    )
                )
            }
            return AtomicMediaOutputCleanupResult(
                attempts: 0,
                temporaryFileRemoved: true,
                error: nil
            )
        }
        guard let verifiedTemporaryFile else {
            return AtomicMediaOutputCleanupResult(
                attempts: 0,
                temporaryFileRemoved: false,
                error: .unownedTemporaryFilePreserved(temporaryURL)
            )
        }

        let cleanupIdentity: AtomicMediaPinnedFileIdentity
        do {
            cleanupIdentity = try verifiedTemporaryFile
                .makePinnedFileIdentity()
        } catch {
            if let outputError = error as? AtomicMediaOutputError,
               case .verifiedTemporaryFileChanged = outputError {
                return AtomicMediaOutputCleanupResult(
                    attempts: 0,
                    temporaryFileRemoved: false,
                    error: .unownedTemporaryFilePreserved(
                        temporaryURL
                    )
                )
            }
            return AtomicMediaOutputCleanupResult(
                attempts: 0,
                temporaryFileRemoved: false,
                error: .cleanupFailed(
                    temporary: temporaryURL,
                    attempts: 0,
                    reason: String(describing: error)
                )
            )
        }

        var attempts = 0
        var lastFailure: String?
        while attempts < cleanupAttemptLimit,
              fileSystem.pathEntryExists(at: temporaryURL) {
            attempts += 1
            do {
                try fileSystem.removeItem(
                    at: temporaryURL,
                    ifMatchingFile: cleanupIdentity
                )
            } catch {
                lastFailure = String(describing: error)
            }
        }

        let wasRemoved = !fileSystem.pathEntryExists(at: temporaryURL)
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

    func recordTransition(
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

    func recordCleanup(
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

// Atomic state transitions and ownership cleanup are reviewed as one unit.
// swiftlint:disable:this file_length
