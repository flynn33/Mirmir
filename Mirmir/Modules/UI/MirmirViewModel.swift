import Foundation
import SwiftUI
import Combine
import AppKit

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

    struct RetryableFailedJob {
        let job: UpscaleJob
        let source: SourceProfile
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
    @Published private(set) var latestPreviewFrame: UpscalePreviewFrame?
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
    @Published var recoveryMutationIsInProgress = false
    @Published var recoveryReauthorizationRequiredIDs:
        Set<String> = []
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
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    var recoveryTask: Task<Void, Never>?
    var recoveryMutationTask: Task<Void, Never>?
    var recoveryGeneration = 0
    var releaseDiagnosticsTask: Task<Void, Never>?
    private var jobHandle: UpscalerJobHandle?
    var retryableFailedJob: RetryableFailedJob?

    var jobIsRunning: Bool {
        if case .running = state { return true }
        return false
    }

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
        previewTask?.cancel()
        recoveryTask?.cancel()
        recoveryMutationTask?.cancel()
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
        if recoveryMutationIsInProgress {
            return "Mirmir is updating interrupted jobs."
        }

        switch state {
        case .probing:
            return "Mirmir is reading the source video."
        case .running:
            return "Upscale in progress."
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

    var canRetryFailedUpscale: Bool {
        guard case .failed = state,
              let retryableFailedJob,
              !recoveryIsProbing,
              !recoveryMutationIsInProgress,
              cacheLocationError == nil,
              upscalerEngine.availability(
                  for: retryableFailedJob.job.mode
              ) == .available else {
            return false
        }
        return true
    }

    func recoveryRequiresReauthorization(id: String) -> Bool {
        recoveryReauthorizationRequiredIDs.contains(id)
    }

    static func targets(for resolution: VideoResolution) -> [VideoResolution] {
        switch resolution {
        case .p720: return [.p1080]
        case .p1080: return [.p2160]
        default:
            break
        }
        guard resolution.width > 0,
              resolution.height > 0,
              let targetHeight = [720, 1_080, 1_440, 2_160]
                .first(where: { $0 > resolution.height }) else {
            return []
        }
        let halfWidth =
            Double(resolution.width) * Double(targetHeight)
                / Double(resolution.height) / 2
        guard halfWidth.isFinite,
              halfWidth >= 1,
              halfWidth <= Double(Int.max / 2) else {
            return []
        }
        let targetWidth = Int(halfWidth.rounded()) * 2
        return [
            VideoResolution(
                width: targetWidth,
                height: targetHeight
            )
        ]
    }

    static func supportsVideoFile(_ url: URL) -> Bool {
        url.isFileURL && !url.lastPathComponent.isEmpty
    }

    func chooseSourceFile() {
        guard !jobIsRunning else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
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
        resetPreview()
        retryableFailedJob = nil
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
        resetPreview()
        retryableFailedJob = nil
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
            retryableFailedJob = RetryableFailedJob(
                job: job,
                source: source
            )
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
        retryableFailedJob = nil
        state = .running
        progress = UpscaleProgress(
            framesProcessed: 0,
            totalFrames: source.estimatedFrameCount,
            throughputFPS: 0,
            etaSeconds: nil
        )
        observePreviewFrames(from: handle)
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
            await self.observeJobCompletion(
                job: job,
                source: source,
                handle: handle
            )
        }
    }

    private func observePreviewFrames(from handle: UpscalerJobHandle) {
        resetPreview()
        let generation = previewGeneration
        previewTask = Task { [weak self] in
            for await frame in handle.previewStream {
                guard let self,
                      !Task.isCancelled,
                      previewGeneration == generation else {
                    return
                }
                latestPreviewFrame = frame
            }
            guard let self,
                  !Task.isCancelled,
                  previewGeneration == generation else {
                return
            }
            previewTask = nil
        }
    }

    func resetPreview() {
        previewGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        latestPreviewFrame = nil
    }

    private func observeJobCompletion(
        job: UpscaleJob,
        source: SourceProfile,
        handle: UpscalerJobHandle
    ) async {
        for await update in handle.progressStream {
            progress = update
        }
        do {
            let url = try await handle.waitForCompletion()
            guard !Task.isCancelled else { return }
            jobHandle = nil
            progressTask = nil
            retryableFailedJob = nil
            state = .finished(url)
            recoverableJobs.removeAll { $0.id == job.identifier }
            recoveryReauthorizationRequiredIDs.remove(job.identifier)
            refreshReleaseDiagnostics()
            diagnosticRecorder.enqueue(
                severity: .notice,
                subsystem: "workflow",
                operation: "job_terminal",
                code: "job_completed",
                job: job,
                source: source,
                progress: progress
            )
        } catch is CancellationError {
            applyCancelledJobTerminalState()
            diagnosticRecorder.enqueue(
                severity: .notice,
                subsystem: "workflow",
                operation: "job_terminal",
                code: "job_cancelled",
                job: job,
                source: source,
                progress: progress
            )
        } catch let engineError as UpscalerEngineError {
            if case .cancelled = engineError {
                applyCancelledJobTerminalState()
                diagnosticRecorder.enqueue(
                    severity: .notice,
                    subsystem: "workflow",
                    operation: "job_terminal",
                    code: "job_cancelled",
                    job: job,
                    source: source,
                    progress: progress,
                    error: engineError
                )
                return
            }
            applyFailedJobTerminalState(
                job: job,
                source: source,
                error: engineError
            )
            diagnosticRecorder.enqueue(
                severity: .error,
                subsystem: "workflow",
                operation: "job_terminal",
                code: "job_failed",
                job: job,
                source: source,
                progress: progress,
                error: engineError
            )
        } catch {
            applyFailedJobTerminalState(
                job: job,
                source: source,
                error: error
            )
            diagnosticRecorder.enqueue(
                severity: .error,
                subsystem: "workflow",
                operation: "job_terminal",
                code: "job_failed",
                job: job,
                source: source,
                progress: progress,
                error: error
            )
        }
    }

    private func applyCancelledJobTerminalState() {
        jobHandle = nil
        progressTask = nil
        retryableFailedJob = nil
        if jobIsRunning {
            state = .ready
        }
        loadRecoverableJobs()
        refreshReleaseDiagnostics()
    }

    private func applyFailedJobTerminalState(
        job: UpscaleJob,
        source: SourceProfile,
        error: Error
    ) {
        guard !Task.isCancelled else { return }
        jobHandle = nil
        progressTask = nil
        retryableFailedJob = RetryableFailedJob(
            job: job,
            source: source
        )
        state = .failed(userFacingJobError(error))
        loadRecoverableJobs()
        refreshReleaseDiagnostics()
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

    func retryFailedUpscale() {
        guard canRetryFailedUpscale,
              let retryableFailedJob else {
            return
        }
        sourceProfile = retryableFailedJob.source
        targetResolution = retryableFailedJob.job.targetResolution
        codec = retryableFailedJob.job.codec
        selectedMode = retryableFailedJob.job.mode
        outputURL = retryableFailedJob.job.outputURL
        outputSelectionError = nil
        progress = nil
        state = .ready
        submit(
            job: retryableFailedJob.job,
            source: retryableFailedJob.source
        )
    }

    func dismissTerminalJob() {
        switch state {
        case .finished, .failed:
            upscaleAnotherVideo()
            loadRecoverableJobs()
        case .idle, .probing, .ready, .running:
            return
        }
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
        resetPreview()
        retryableFailedJob = nil
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
