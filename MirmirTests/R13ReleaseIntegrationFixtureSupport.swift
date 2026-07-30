import Foundation
@testable import Mirmir

struct R13IntegrationWorkspace {
    let directory: URL
    let sourceURL: URL
    let outputURL: URL
    let jobsRootURL: URL

    init(
        outputFileName: String = "output.mov",
        outputOverride: URL? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-r13-integration-\(UUID().uuidString)",
                isDirectory: true
            )
        sourceURL = directory.appendingPathComponent("source.mp4")
        jobsRootURL = directory.appendingPathComponent(
            "Jobs",
            isDirectory: true
        )
        outputURL = outputOverride
            ?? directory.appendingPathComponent(outputFileName)
        try FileManager.default.createDirectory(
            at: jobsRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
    }

    func writeOpaqueSource(_ data: Data) throws {
        try data.write(to: sourceURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

func makeR13IntegrationJob(
    identifier: String,
    workspace: R13IntegrationWorkspace,
    mode: UpscaleMode = .deterministic
) -> UpscaleJob {
    UpscaleJob(
        identifier: identifier,
        inputURL: workspace.sourceURL,
        outputURL: workspace.outputURL,
        targetResolution: .p1080,
        codec: .h264,
        preserveAudio: false,
        mode: mode
    )
}

func makeR13IntegrationService(
    media: MediaPipelineService,
    factory: R13ReleaseTestSessionFactory,
    hardeningRuntime: R13ReleaseHardeningRuntime,
    eventLog: R13ReleaseTestEventLog? = nil
) -> R13ReleaseUpscalerEngineService {
    R13ReleaseUpscalerEngineService(
        media: media,
        sessionFactory: { [factory] route in
            try await factory.make(route: route)
        },
        inputReleaseObserver: { identity in
            eventLog?.record("input.release.\(identity)")
        },
        hardeningRuntime: hardeningRuntime
    )
}

func countR13IntegrationEvents(
    _ event: String,
    in eventLog: R13ReleaseTestEventLog
) -> Int {
    eventLog.events.filter { $0 == event }.count
}
