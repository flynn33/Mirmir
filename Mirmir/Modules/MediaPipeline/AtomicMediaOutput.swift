import Foundation

final class AtomicMediaOutput: @unchecked Sendable {
    let destinationURL: URL
    let temporaryURL: URL
    private var telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared

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

    func attachTelemetry(_ telemetry: any ASHTelemetryRecording) {
        self.telemetry = telemetry
        telemetry.recordMedia(ASHMediaObservation(
            kind: "temporary_output_created",
            details: ["temporary_name": temporaryURL.lastPathComponent]
        ))
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
        telemetry.recordMedia(ASHMediaObservation(
            kind: "output_published",
            details: ["destination_name": destinationURL.lastPathComponent]
        ))
    }

    func discard(fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: temporaryURL.path) else { return }
        do {
            try fileManager.removeItem(at: temporaryURL)
            telemetry.recordMedia(ASHMediaObservation(
                kind: "temporary_output_discarded",
                details: ["temporary_name": temporaryURL.lastPathComponent]
            ))
        } catch {
            telemetry.increment(.partialCleanupFailures)
            telemetry.recordError(error)
        }
    }

    deinit {
        discard()
    }
}
