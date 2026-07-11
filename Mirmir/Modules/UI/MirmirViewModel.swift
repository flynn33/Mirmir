import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

enum MirmirQualityMode: String, CaseIterable, Identifiable {
    case balanced
    case quality
    case fastPreview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .quality:
            return "Quality"
        case .fastPreview:
            return "Fast"
        }
    }

    var summary: String {
        switch self {
        case .balanced:
            return "Default deterministic reconstruction profile for this alpha build."
        case .quality:
            return "Prepared for higher-detail processing when that mode is available."
        case .fastPreview:
            return "Prepared for quicker preview passes when preview output is available."
        }
    }
}

enum MirmirAdjustmentLevel: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }
}

struct MirmirEffectOption: Identifiable, Equatable {
    let id: String
    let title: String
    let disabledReason: String

    var isEnabled: Bool { false }

    static let allOptions: [MirmirEffectOption] = [
        MirmirEffectOption(
            id: "edge-preservation",
            title: "Edge Preservation",
            disabledReason: "Not available in the current alpha build."
        ),
        MirmirEffectOption(
            id: "compression-cleanup",
            title: "Compression Cleanup",
            disabledReason: "Not available in the current alpha build."
        ),
        MirmirEffectOption(
            id: "texture-grain-protection",
            title: "Texture / Grain Protection",
            disabledReason: "Not available in the current alpha build."
        ),
        MirmirEffectOption(
            id: "temporal-stability",
            title: "Temporal Stability",
            disabledReason: "Not available in the current alpha build."
        )
    ]
}

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
    @Published var qualityMode: MirmirQualityMode = .balanced
    @Published var temporalConsistencyEnabled = true
    @Published var edgeFidelityLevel: MirmirAdjustmentLevel = .medium
    @Published var detailRecoveryLevel: MirmirAdjustmentLevel = .medium
    @Published var modelStatus: ModelAssetsStatus = .unknown
    @Published var ashBackendStatus: ASHBackendStatus = .validating
    @Published var progress: UpscaleProgress?
    @Published var state: JobState = .idle
    @Published private(set) var outputURL: URL?
    @Published private(set) var outputSelectionError: String?

    private let mediaPipeline: MediaPipelineService
    private let upscalerEngine: UpscalerEngineService
    private let modelAssets: ModelAssetsService

    private var modelStatusTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var jobHandle: UpscalerJobHandle?

    private var jobIsRunning: Bool {
        if case .running = state { return true }
        return false
    }

    static let supportedVideoExtensions = ["mp4", "mov", "m4v", "qt", "avi", "mpg", "mpeg"]

    init(
        mediaPipeline: MediaPipelineService,
        upscalerEngine: UpscalerEngineService,
        modelAssets: ModelAssetsService
    ) {
        self.mediaPipeline = mediaPipeline
        self.upscalerEngine = upscalerEngine
        self.modelAssets = modelAssets
        self.ashBackendStatus = ASHBackendStartupValidator.validate()
        startObservingModelStatus()
    }

    deinit {
        modelStatusTask?.cancel()
        progressTask?.cancel()
    }

    var effectOptions: [MirmirEffectOption] {
        MirmirEffectOption.allOptions
    }

    var availableTargets: [VideoResolution] {
        guard let resolution = sourceProfile?.resolution else { return [] }
        return Self.targets(for: resolution)
    }

    var engineReadinessText: String {
        switch ashBackendStatus {
        case .validating:
            return "Checking Engine"
        case .available:
            return "Engine Ready"
        case .unavailable:
            return "Engine Unavailable"
        }
    }

    var canStartFailureReason: String? {
        switch state {
        case .probing:
            return "Mirmir is reading the source video."
        case .running:
            return "An upscale is already running."
        case .finished:
            return "Upscale another video to start a new job."
        case .failed(let reason):
            return reason
        case .idle, .ready:
            break
        }

        guard let sourceProfile else {
            return "Choose a source video."
        }
        guard !availableTargets.isEmpty else {
            return unsupportedResolutionMessage(sourceProfile.resolution)
        }
        guard availableTargets.contains(targetResolution) else {
            return "Choose a supported target resolution for this source."
        }
        if let outputSelectionError {
            return outputSelectionError
        }
        guard let outputURL else {
            return "Choose an output location."
        }
        guard !FileURLIdentity.refersToSameFile(sourceProfile.url, outputURL) else {
            return Self.sourceOutputConflictMessage
        }
        guard ashBackendStatus == .available else {
            return "Mirmir's processing engine is not ready."
        }
        guard state == .ready else {
            return "Choose a source video and output location before starting."
        }
        return nil
    }

    var canStart: Bool {
        canStartFailureReason == nil
    }

    static func targets(for resolution: VideoResolution) -> [VideoResolution] {
        switch resolution {
        case .p720: return [.p1080]
        case .p1080: return [.p2160]
        default: return []
        }
    }

    static func supportsVideoFile(_ url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    func chooseSourceFile() {
        guard !jobIsRunning else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedContentTypes()
        panel.title = "Select a video to upscale"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSource(url: url)
    }

    func loadSource(url: URL) {
        guard !jobIsRunning else { return }
        guard Self.supportsVideoFile(url) else {
            sourceProfile = nil
            clearOutputSelection()
            progress = nil
            state = .failed(Self.unsupportedFileMessage)
            return
        }

        sourceProfile = nil
        clearOutputSelection()
        progress = nil
        state = .probing
        Task {
            do {
                let profile = try await mediaPipeline.probe(url: url)
                self.sourceProfile = profile
                guard let firstTarget = Self.targets(for: profile.resolution).first else {
                    self.state = .failed(self.unsupportedResolutionMessage(profile.resolution))
                    return
                }
                self.targetResolution = firstTarget
                self.state = .ready
            } catch {
                self.state = .failed(self.userFacingProbeError(error))
            }
        }
    }

    func chooseOutputFile() -> URL? {
        guard let source = sourceProfile else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.title = "Save upscaled video as"
        let defaultURL = defaultOutputURL(for: source, target: targetResolution)
        panel.nameFieldStringValue = defaultURL.lastPathComponent
        panel.directoryURL = source.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard acceptOutputURLSelectedByUser(url) else { return nil }
        return url
    }

    @discardableResult
    func acceptOutputURLSelectedByUser(_ url: URL) -> Bool {
        guard let sourceProfile else {
            clearOutputSelection()
            outputSelectionError = "Choose a source video first."
            return false
        }
        guard url.isFileURL else {
            clearOutputSelection()
            outputSelectionError = "Choose a local file-system destination."
            return false
        }
        guard !FileURLIdentity.refersToSameFile(sourceProfile.url, url) else {
            clearOutputSelection()
            outputSelectionError = Self.sourceOutputConflictMessage
            return false
        }

        outputURL = url
        outputSelectionError = nil
        return true
    }

    func startUpscale() {
        guard canStart, let source = sourceProfile, let destination = outputURL else { return }

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
                        self.jobHandle = nil
                        self.progressTask = nil
                        self.state = .finished(url)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.jobHandle = nil
                        self.progressTask = nil
                        if self.jobIsRunning {
                            self.state = .ready
                        }
                    }
                    return
                } catch let engineError as UpscalerEngineError {
                    if case .cancelled = engineError {
                        await MainActor.run {
                            self.jobHandle = nil
                            self.progressTask = nil
                            if self.jobIsRunning {
                                self.state = .ready
                            }
                        }
                        return
                    }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.jobHandle = nil
                        self.progressTask = nil
                        self.state = .failed(String(describing: engineError))
                    }
                } catch {
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.jobHandle = nil
                        self.progressTask = nil
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
    }

    func revealOutputInFinder() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func upscaleAnotherVideo() {
        jobHandle?.cancel()
        jobHandle = nil
        progressTask?.cancel()
        progressTask = nil
        sourceProfile = nil
        clearOutputSelection()
        progress = nil
        state = .idle
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

    func defaultOutputURL(for source: SourceProfile, target: VideoResolution) -> URL {
        let dir = source.url.deletingLastPathComponent()
        let base = source.url.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base)_mirmir_\(Self.fileLabel(for: target)).mp4")
    }

    static var unsupportedFileMessage: String {
        "Unsupported video format. Choose an MP4, MOV, M4V, QT, AVI, MPG, or MPEG file."
    }

    static func fileLabel(for resolution: VideoResolution) -> String {
        switch resolution {
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        case .p1440:
            return "1440p"
        case .p2160:
            return "2160p"
        default:
            return "\(resolution.width)x\(resolution.height)"
        }
    }

    private static func supportedContentTypes() -> [UTType] {
        let extensionTypes = supportedVideoExtensions.compactMap { UTType(filenameExtension: $0) }
        return Array(Set(extensionTypes + [.movie, .video, .quickTimeMovie, .mpeg4Movie]))
    }

    static var sourceOutputConflictMessage: String {
        "The output file must be different from the source video."
    }

    static func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        FileURLIdentity.refersToSameFile(lhs, rhs)
    }

    private func clearOutputSelection() {
        outputURL = nil
        outputSelectionError = nil
    }

    private func userFacingProbeError(_ error: Error) -> String {
        "Mirmir could not read this video. \(String(describing: error))"
    }

    private func unsupportedResolutionMessage(_ resolution: VideoResolution) -> String {
        "Mirmir supports 720p to 1080p and 1080p to 4K upscaling. This source is \(resolution)."
    }
}
