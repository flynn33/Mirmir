import Foundation

final class AtomicMediaOutput: @unchecked Sendable {
    let destinationURL: URL
    let temporaryURL: URL

    init(destinationURL: URL, fileManager: FileManager = .default) throws {
        self.destinationURL = destinationURL
        let directory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard destinationURL.isFileURL,
              fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }

        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        let pathExtension = destinationURL.pathExtension
        let extensionSuffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        self.temporaryURL = directory.appendingPathComponent(
            ".\(baseName).mirmir-\(UUID().uuidString).partial\(extensionSuffix)",
            isDirectory: false
        )
    }

    func commit(fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func discard(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: temporaryURL)
    }

    deinit {
        discard()
    }
}
