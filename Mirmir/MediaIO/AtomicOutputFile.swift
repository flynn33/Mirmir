import Foundation

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
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw MirmirError.outputFinalizeFailed(
                "the completed temporary movie is missing"
            )
        }

        do {
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
        } catch let error as MirmirError {
            throw error
        } catch {
            throw MirmirError.outputFinalizeFailed(error.localizedDescription)
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
