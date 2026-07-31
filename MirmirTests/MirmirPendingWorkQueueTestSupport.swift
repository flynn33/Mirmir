import Foundation
import XCTest
@testable import Mirmir

extension XCTestCase {
    func makePendingQueueTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirPendingQueueTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

func makePendingQueueBookmarks(
    sourceBookmark: Data = Data("source-bookmark".utf8),
    outputBookmark: Data = Data("output-bookmark".utf8),
    sourceDisplayName: String = "source.mov",
    outputDisplayName: String = "output.mov"
) -> MirmirPendingWorkBookmarks {
    MirmirPendingWorkBookmarks(
        sourceBookmark: sourceBookmark,
        outputBookmark: outputBookmark,
        sourceDisplayName: sourceDisplayName,
        outputDisplayName: outputDisplayName
    )
}

func makePendingQueueSettings(
    targetResolution: VideoResolution = .p2160,
    codec: OutputCodec = .hevc,
    preserveAudio: Bool = true,
    requestedMode: UpscaleMode = .quality,
    processingConfiguration: UpscaleProcessingConfiguration = .default
) -> MirmirPendingWorkSettings {
    MirmirPendingWorkSettings(
        targetResolution: targetResolution,
        codec: codec,
        preserveAudio: preserveAudio,
        requestedMode: requestedMode,
        processingConfiguration: processingConfiguration
    )
}

func makePendingQueueRecord(
    id: String,
    order: Int,
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 100),
    bookmarks: MirmirPendingWorkBookmarks = makePendingQueueBookmarks(),
    settings: MirmirPendingWorkSettings = makePendingQueueSettings(),
    state: MirmirPendingWorkState = .pending,
    startedAt: Date? = nil
) -> MirmirPendingWorkRecord {
    MirmirPendingWorkRecord(
        id: id,
        bookmarks: bookmarks,
        settings: settings,
        createdAt: createdAt,
        order: order,
        state: state,
        startedAt: startedAt
    )
}

func pendingQueueDocumentURL(in directory: URL) -> URL {
    directory.appendingPathComponent(
        MirmirPendingWorkQueue.documentFileName,
        isDirectory: false
    )
}
