import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

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
            disabledReason: "This optional effect is not available."
        ),
        MirmirEffectOption(
            id: "compression-cleanup",
            title: "Compression Cleanup",
            disabledReason: "This optional effect is not available."
        ),
        MirmirEffectOption(
            id: "texture-grain-protection",
            title: "Texture / Grain Protection",
            disabledReason: "This optional effect is not available."
        ),
        MirmirEffectOption(
            id: "temporal-stability",
            title: "Temporal Stability",
            disabledReason: "This optional effect is not available."
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
    @Published var selectedMode: UpscaleMode = .deterministic
    @Published var temporalConsistencyEnabled = true
    @Published var edgeFidelityLevel: MirmirAdjustmentLevel = .medium
    @Published var detailRecoveryLevel: MirmirAdjustmentLevel = .medium
    @Published var modelStatus: ModelAssetsStatus = .unknown
    @Published private(set) var engineAvailability: UpscalerEngineAvailability
    @Published var progress: UpscaleProgress?
    @Published var state: JobState = .idle
    @Published var outputURL: URL?
    @Published var outputSelectionError: String?
    @Published var cacheLocationPath =
        "Managed by the configured runtime"
    @Published var cacheLocationIsCustom = false
    @Published var cacheLocationError: String?
    @Published var cacheLocationSelectionError: String?
    @Published var recoverableJobs:
        [R13RecoverableUpscaleJob] = []
    @Published var recoveryRejectedEntryCount = 0
    @Published var recoveryIsProbing = false
    @Published var recoveryError: String?
    @Published var releaseDiagnosticsText =
        "No release events recorded."
    @Published var releaseDiagnosticLines: [String] = []

    let mediaPipeline: MediaPipelineService
    let upscalerEngine: UpscalerEngineService
    let diagnosticStore: MirmirDiagnosticStore
    let diagnosticRecorder: MirmirDiagnosticRecorder
    private let modelAssets: ModelAssetsService

    private var modelStatusTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var recoveryGeneration = 0
    var releaseDiagnosticsTask: Task<Void, Never>?
    private var jobHandle: UpscalerJobHandle?

    var jobIsRunning: Bool {
        if case .running = state { return true }
        return false
    }

    static let supportedVideoExtensions = ["mp4", "mov", "m4v", "qt", "avi", "mpg", "mpeg"]

    init(
        mediaPipeline: MediaPipelineService,
        upscalerEngine: UpscalerEngineService,
        modelAssets: ModelAssetsService,
        diagnostics: MirmirDiagnosticStore? = nil
    ) {
        let diagnosticStore = diagnostics
            ?? MirmirDiagnosticStore(inMemoryWith: .production)
        self.mediaPipeline = mediaPipeline
        self.upscalerEngine = upscalerEngine
        self.modelAssets = modelAssets
        self.diagnosticStore = diagnosticStore
        self.diagnosticRecorder = MirmirDiagnosticRecorder(
            store: diagnosticStore
        )
        self.engineAvailability = upscalerEngine.availability
        startObservingModelStatus()
        refreshCacheLocation()
        loadRecoverableJobs()
        refreshReleaseDiagnostics()
    }

    deinit {
        modelStatusTask?.cancel()
        progressTask?.cancel()
        recoveryTask?.cancel()
        releaseDiagnosticsTask?.cancel()
    }

    var effectOptions: [MirmirEffectOption] {
        MirmirEffectOption.allOptions
    }

    var availableTargets: [VideoResolution] {
        guard let resolution = sourceProfile?.resolution else { return [] }
        return Self.targets(for: resolution)
    }

    var selectedModeAvailability: UpscalerEngineAvailability {
        upscalerEngine.availability(for: selectedMode)
    }

    var canStartFailureReason: String? {
        if let engineAvailabilityReason {
            return engineAvailabilityReason
        }
        if let cacheLocationError {
            return cacheLocationError
        }

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
        let correlationID = UUID()
        let sourceResource = MirmirDiagnosticResourceInput(
            role: "source_video",
            url: url,
            location: .userSelected
        )
        guard !jobIsRunning else {
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "source_probe",
                    code: "source_probe_blocked_active_job",
                    correlationID: correlationID,
                    resources: [sourceResource]
                )
            }
            return
        }
        cancelRecoveryProbe()
        guard Self.supportsVideoFile(url) else {
            sourceProfile = nil
            clearOutputSelection()
            progress = nil
            state = .failed(Self.unsupportedFileMessage)
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "source_selection",
                    code: "source_type_rejected",
                    correlationID: correlationID,
                    resources: [sourceResource]
                )
            }
            return
        }

        sourceProfile = nil
        clearOutputSelection()
        progress = nil
        state = .probing
        Task { [diagnosticRecorder] in
            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "media",
                operation: "source_probe",
                code: "source_probe_started",
                correlationID: correlationID,
                resources: [sourceResource]
            )
            do {
                let profile = try await mediaPipeline.probe(url: url)
                self.sourceProfile = profile
                diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "media",
                    operation: "source_probe",
                    code: "source_probe_succeeded",
                    correlationID: correlationID,
                    source: profile,
                    resources: [sourceResource]
                )
                guard let firstTarget = Self.targets(for: profile.resolution).first else {
                    self.state = .failed(self.unsupportedResolutionMessage(profile.resolution))
                    diagnosticRecorder.enqueue(
                        severity: .warning,
                        subsystem: "workflow",
                        operation: "target_selection",
                        code: "no_upscale_target_available",
                        correlationID: correlationID,
                        source: profile,
                        resources: [sourceResource]
                    )
                    return
                }
                self.targetResolution = firstTarget
                self.state = .ready
            } catch {
                self.state = .failed(self.userFacingProbeError(error))
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "media",
                    operation: "source_probe",
                    code: "source_probe_failed",
                    correlationID: correlationID,
                    resources: [sourceResource],
                    error: error
                )
            }
        }
    }

    func chooseOutputFile() -> URL? {
        guard let source = sourceProfile else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Select a folder for the upscaled video"
        panel.prompt = "Select Folder"
        panel.directoryURL = source.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let directoryURL = panel.url else {
            return nil
        }
        let url = defaultOutputURL(
            for: source,
            target: targetResolution,
            in: directoryURL
        )
        guard acceptOutputURLSelectedByUser(url) else { return nil }
        return url
    }

    @discardableResult
    func acceptOutputURLSelectedByUser(_ url: URL) -> Bool {
        let correlationID = UUID()
        let outputResource = MirmirDiagnosticResourceInput(
            role: "output_video",
            url: url,
            location: .userSelected
        )
        guard let sourceProfile else {
            clearOutputSelection()
            outputSelectionError = "Choose a source video first."
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "select_output",
                    code: "output_selection_rejected_no_source",
                    correlationID: correlationID,
                    resources: [outputResource]
                )
            }
            return false
        }
        guard url.isFileURL else {
            clearOutputSelection()
            outputSelectionError = "Choose a local file-system destination."
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "select_output",
                    code: "output_selection_rejected_non_file_url",
                    correlationID: correlationID,
                    source: sourceProfile,
                    resources: [outputResource]
                )
            }
            return false
        }
        guard !FileURLIdentity.refersToSameFile(sourceProfile.url, url) else {
            clearOutputSelection()
            outputSelectionError = Self.sourceOutputConflictMessage
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "select_output",
                    code: "output_selection_rejected_source_collision",
                    correlationID: correlationID,
                    source: sourceProfile,
                    resources: [outputResource]
                )
            }
            return false
        }

        outputURL = url
        outputSelectionError = nil
        Task { [diagnosticRecorder] in
            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "workflow",
                operation: "select_output",
                code: "output_selection_accepted",
                correlationID: correlationID,
                source: sourceProfile,
                resources: [outputResource]
            )
        }
        return true
    }

    func startUpscale() {
        guard canStart,
              let source = sourceProfile,
              let destination = outputURL else {
            let code = diagnosticBlockedStartCode
            let source = sourceProfile
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "job_start",
                    code: code,
                    source: source
                )
            }
            return
        }

        let job = UpscaleJob(
            inputURL: source.url,
            outputURL: destination,
            targetResolution: targetResolution,
            codec: codec,
            preserveAudio: source.hasAudio,
            mode: selectedMode
        )
        submit(job: job, source: source)
    }

    func submit(job: UpscaleJob, source: SourceProfile) {
        Task { [diagnosticRecorder] in
            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "workflow",
                operation: "job_submit",
                code: "job_submit_requested",
                job: job,
                source: source
            )
        }
        do {
            let handle = try upscalerEngine.submit(job)
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .info,
                    subsystem: "workflow",
                    operation: "job_submit",
                    code: "job_submit_accepted",
                    job: job,
                    source: source
                )
            }
            observeSubmittedJob(job: job, source: source, handle: handle)
        } catch {
            state = .failed(userFacingJobError(error))
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "workflow",
                    operation: "job_submit",
                    code: "job_submit_rejected",
                    job: job,
                    source: source,
                    error: error
                )
            }
        }
    }

    func observeSubmittedJob(
        job: UpscaleJob,
        source: SourceProfile,
        handle: UpscalerJobHandle
    ) {
        jobHandle = handle
        state = .running
        progress = UpscaleProgress(
            framesProcessed: 0,
            totalFrames: source.estimatedFrameCount,
            throughputFPS: 0,
            etaSeconds: nil
        )
        Task { [diagnosticRecorder] in
            diagnosticRecorder.enqueue(
                severity: .info,
                subsystem: "workflow",
                operation: "job_execution",
                code: "job_execution_observed",
                job: job,
                source: source
            )
        }

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
                    self.recoverableJobs.removeAll {
                        $0.id == job.identifier
                    }
                    self.refreshReleaseDiagnostics()
                }
                self.diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "workflow",
                    operation: "job_terminal",
                    code: "job_completed",
                    job: job,
                    source: source,
                    progress: self.progress
                )
            } catch is CancellationError {
                await MainActor.run {
                    self.jobHandle = nil
                    self.progressTask = nil
                    if self.jobIsRunning {
                        self.state = .ready
                    }
                    self.refreshReleaseDiagnostics()
                }
                self.diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "workflow",
                    operation: "job_terminal",
                    code: "job_cancelled",
                    job: job,
                    source: source,
                    progress: self.progress
                )
                return
            } catch let engineError as UpscalerEngineError {
                if case .cancelled = engineError {
                    await MainActor.run {
                        self.jobHandle = nil
                        self.progressTask = nil
                        if self.jobIsRunning {
                            self.state = .ready
                        }
                        self.refreshReleaseDiagnostics()
                    }
                    self.diagnosticRecorder.enqueue(
                        severity: .notice,
                        subsystem: "workflow",
                        operation: "job_terminal",
                        code: "job_cancelled",
                        job: job,
                        source: source,
                        progress: self.progress,
                        error: engineError
                    )
                    return
                }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.jobHandle = nil
                    self.progressTask = nil
                    self.state = .failed(
                        self.userFacingJobError(engineError)
                    )
                    self.refreshReleaseDiagnostics()
                }
                self.diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "workflow",
                    operation: "job_terminal",
                    code: "job_failed",
                    job: job,
                    source: source,
                    progress: self.progress,
                    error: engineError
                )
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.jobHandle = nil
                    self.progressTask = nil
                    self.state = .failed(
                        self.userFacingJobError(error)
                    )
                    self.refreshReleaseDiagnostics()
                }
                self.diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "workflow",
                    operation: "job_terminal",
                    code: "job_failed",
                    job: job,
                    source: source,
                    progress: self.progress,
                    error: error
                )
            }
        }
    }

    func cancelUpscale() {
        if jobHandle != nil {
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "workflow",
                    operation: "job_cancel",
                    code: "job_cancel_requested",
                    source: sourceProfile,
                    progress: progress
                )
            }
        }
        jobHandle?.cancel()
    }

    private var diagnosticBlockedStartCode: String {
        switch state {
        case .running:
            return "job_start_blocked_active_job"
        case .probing:
            return "job_start_blocked_probe_active"
        case .failed:
            return "job_start_blocked_failed_state"
        case .finished:
            return "job_start_blocked_finished_state"
        case .idle, .ready:
            if sourceProfile == nil {
                return "job_start_blocked_no_source"
            }
            if outputURL == nil {
                return "job_start_blocked_no_output"
            }
            return "job_start_blocked_validation"
        }
    }

    func revealOutputInFinder() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func upscaleAnotherVideo() {
        cancelRecoveryProbe()
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
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "model_assets",
                    operation: "ensure_ready",
                    code: "model_assets_preparation_failed",
                    error: error
                )
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
                if case .failed = status, let self {
                    self.diagnosticRecorder.enqueue(
                        severity: .error,
                        subsystem: "model_assets",
                        operation: "observe_status",
                        code: "model_assets_status_failed"
                    )
                }
            }
        }
    }

}
