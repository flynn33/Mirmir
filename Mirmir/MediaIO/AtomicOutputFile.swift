import Foundation

struct MirmirAtomicPublicationError: LocalizedError, CustomNSError,
    @unchecked Sendable {
    static let errorDomain = "Mirmir.AtomicPublication"

    let temporaryURL: URL
    let finalURL: URL
    let underlyingError: NSError

    var errorCode: Int { underlyingError.code }

    var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: errorDescription ?? "Atomic publication failed.",
            NSUnderlyingErrorKey: underlyingError,
            "temporary_path": temporaryURL.path,
            "destination_path": finalURL.path
        ]
    }

    var errorDescription: String? {
        "Atomic publication from \(temporaryURL.path) to \(finalURL.path) "
            + "failed: \(underlyingError.domain) \(underlyingError.code)."
    }
}

final class AtomicOutputFile: @unchecked Sendable {
    let finalURL: URL
    let temporaryURL: URL

    private let fileManager: FileManager
    private let overwriteExistingFile: Bool
    private let lock = NSLock()
    private var isPublished = false

    init(
        finalURL: URL,
        overwriteExistingFile: Bool,
        fileManager: FileManager = .default
    ) throws {
        guard finalURL.isFileURL else {
            throw MirmirError.invalidRequest("Choose a local output file.")
        }
        let directory = finalURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw MirmirError.outputAccessDenied
        }
        if fileManager.fileExists(atPath: finalURL.path),
           !overwriteExistingFile {
            throw MirmirError.outputAlreadyExists
        }

        self.finalURL = finalURL
        self.overwriteExistingFile = overwriteExistingFile
        self.fileManager = fileManager
        temporaryURL = directory.appendingPathComponent(
            ".mirmir-\(UUID().uuidString).partial.mov",
            isDirectory: false
        )
    }

    func publish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isPublished else {
            return
        }
        do {
            guard fileManager.fileExists(atPath: temporaryURL.path) else {
                throw MirmirError.outputFinalizeFailed(
                    "the completed temporary movie is missing"
                )
            }
            if fileManager.fileExists(atPath: finalURL.path) {
                guard overwriteExistingFile else {
                    throw MirmirError.outputAlreadyExists
                }
                _ = try fileManager.replaceItemAt(
                    finalURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: finalURL)
            }
            isPublished = true
        } catch {
            let publicationError = MirmirAtomicPublicationError(
                temporaryURL: temporaryURL,
                finalURL: finalURL,
                underlyingError: error as NSError
            )
            do {
                let processing = MirmirDiagnosticScope.processingContext
                var fields = [
                    try MirmirDiagnosticRecorder.textField(
                        "atomic_temporary_path",
                        temporaryURL.path
                    )
                ]
                if processing == nil {
                    fields.append(try MirmirDiagnosticRecorder.textField(
                        "output_path",
                        finalURL.path
                    ))
                }
                MirmirDiagnosticScope.recorder.recordCheckpoint(
                    subsystem: "durable_publication",
                    operation: "publish",
                    executionContext:
                        MirmirDiagnosticScope.executionContext,
                    durable: .init(
                        nextInputSampleIndex: processing?.durable
                            .nextInputSampleIndex,
                        segmentOrdinal: processing?.durable.segmentOrdinal,
                        segmentCount: processing?.durable.segmentCount,
                        isComplete: false,
                        checkpointSchema: processing?.durable
                            .checkpointSchema ?? "atomic-output-v1",
                        publishAttempted: true,
                        atomicPublicationFailed: true,
                        checkpointURL: processing?.durable.checkpointURL
                            ?? temporaryURL.deletingLastPathComponent()
                    ),
                    destinationURL: finalURL,
                    processingContext: processing,
                    fields: fields,
                    error: publicationError
                )
            } catch {
                MirmirDiagnosticStore.logger.error(
                    "Unable to construct atomic publication diagnostics"
                )
            }
            if let mirmirError = error as? MirmirError {
                throw mirmirError
            }
            throw publicationError
        }
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard !isPublished,
              fileManager.fileExists(atPath: temporaryURL.path) else {
            return
        }
        try? fileManager.removeItem(at: temporaryURL)
    }

    deinit {
        discard()
    }
}
