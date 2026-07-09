import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MirmirViewModel: ObservableObject {

    enum JobState: Equatable {
        case idle
        case probing
        case ready
        case running
        case finished(URL)
        case failed(String)
    }

    @Published var sourceProfile: SourceProfile?
    @Published var targetResolution: VideoResolution = .p1080
    @Published var codec: OutputCodec = .hevc
    @Published var modelStatus: ModelAssetsStatus = .unknown
    @Published var progress: UpscaleProgress?
    @Published var state: JobState = .idle
    @Published var outputURL: URL?

    private let mediaPipeline: MediaPipelineService
    private let upscalerEngine: UpscalerEngineService
    private let modelAssets: ModelAssetsService

    private var modelStatusTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var jobHandle: UpscalerJobHandle?

    init(
        mediaPipeline: MediaPipelineService,
        upscalerEngine: UpscalerEngineService,
        modelAssets: ModelAssetsService
    ) {
        self.mediaPipeline = mediaPipeline
        self.upscalerEngine = upscalerEngine
        self.modelAssets = modelAssets
        startObservingModelStatus()
    }

    deinit {
        modelStatusTask?.cancel()
        progressTask?.cancel()
    }

    var availableTargets: [VideoResolution] {
        guard let resolution = sourceProfile?.resolution else { return [] }
        switch resolution {
        case .p720: return [.p1080]
        case .p1080: return [.p2160]
        default: return []
        }
    }

    var canStart: Bool {
        guard sourceProfile != nil, !availableTargets.isEmpty else { return false }
        switch state {
        case .running, .probing: return false
        default: break
        }
        return true
    }

    func chooseSourceFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.title = "Select a video to upscale"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSource(url: url)
    }

    func loadSource(url: URL) {
        state = .probing
        Task {
            do {
                let profile = try await mediaPipeline.probe(url: url)
                self.sourceProfile = profile
                if let first = availableTargets.first {
                    self.targetResolution = first
                }
                self.state = .ready
            } catch {
                self.state = .failed(String(describing: error))
            }
        }
    }

    func chooseOutputFile() -> URL? {
        guard let source = sourceProfile else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.title = "Save upscaled video as"
        let baseName = source.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName)_upscaled.mp4"
        panel.directoryURL = source.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        outputURL = url
        return url
    }

    func startUpscale() {
        guard canStart, let source = sourceProfile else { return }
        let destination = outputURL ?? defaultOutputURL(for: source)
        outputURL = destination

        let job = UpscaleJob(
            inputURL: source.url,
            outputURL: destination,
            targetResolution: targetResolution,
            codec: codec,
            preserveAudio: source.hasAudio
        )

        do {
            let handle = try upscalerEngine.submit(job)
            jobHandle = handle
            state = .running
            progress = UpscaleProgress(framesProcessed: 0, totalFrames: source.estimatedFrameCount, throughputFPS: 0, etaSeconds: nil)

            progressTask?.cancel()
            progressTask = Task { [weak self] in
                guard let self else { return }
                for await update in handle.progressStream {
                    await MainActor.run { self.progress = update }
                }
                do {
                    let url = try await handle.waitForCompletion()
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.state = .finished(url)
                    }
                } catch is CancellationError {
                    // User cancelled — `cancelUpscale()` already moved the
                    // state machine back to `.ready`. Don't overwrite it.
                    return
                } catch let engineError as UpscalerEngineError {
                    if case .cancelled = engineError { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.state = .failed(String(describing: engineError))
                    }
                } catch {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.state = .failed(String(describing: error))
                    }
                }
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func cancelUpscale() {
        jobHandle?.cancel()
        jobHandle = nil
        progressTask?.cancel()
        progressTask = nil
        if case .running = state {
            state = .ready
        }
    }

    func ensureModelsReady() {
        Task {
            do {
                try await modelAssets.ensureReady(for: .video)
            } catch {
                modelStatus = .failed(reason: String(describing: error))
            }
        }
    }

    private func startObservingModelStatus() {
        modelStatusTask?.cancel()
        let stream = modelAssets.statusStream(for: .video)
        modelStatusTask = Task { [weak self] in
            for await status in stream {
                await MainActor.run {
                    self?.modelStatus = status
                }
            }
        }
    }

    private func defaultOutputURL(for source: SourceProfile) -> URL {
        let dir = source.url.deletingLastPathComponent()
        let base = source.url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base)_upscaled.mp4")
    }
}
