import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

extension MirmirAdjustmentLevel {
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
    let summary: String

    static let allOptions: [MirmirEffectOption] = [
        MirmirEffectOption(
            id: "edge-preservation",
            title: "Edge Preservation",
            summary: "Protects true local edges while cleanup and "
                + "enhancement are applied."
        ),
        MirmirEffectOption(
            id: "compression-cleanup",
            title: "Compression Cleanup",
            summary: "Reduces flat-area noise and visible block boundaries "
                + "without smoothing strong edges."
        ),
        MirmirEffectOption(
            id: "texture-grain-protection",
            title: "Texture / Grain Protection",
            summary: "Retains fine texture and source grain in detailed "
                + "regions."
        ),
        MirmirEffectOption(
            id: "temporal-stability",
            title: "Temporal Stability",
            summary: "Reduces frame-to-frame flicker in stable regions."
        )
    ]
}

struct MirmirPersistedJobDefaults: Equatable, Sendable {
    var mode: UpscaleMode
    var outputCodec: OutputCodec
    var enginePreference: UpscaleEnginePreference
    var strategyPreference: UpscaleStrategyPreference
    var temporalConsistencyEnabled: Bool
    var edgeFidelityLevel: MirmirAdjustmentLevel
    var detailRecoveryLevel: MirmirAdjustmentLevel
    var effects: UpscaleEffectConfiguration
    var smoothMotion: SmoothMotionConfiguration

    init(
        mode: UpscaleMode = .deterministic,
        outputCodec: OutputCodec = .hevc,
        enginePreference: UpscaleEnginePreference = .automatic,
        strategyPreference: UpscaleStrategyPreference = .automatic,
        temporalConsistencyEnabled: Bool = true,
        edgeFidelityLevel: MirmirAdjustmentLevel = .medium,
        detailRecoveryLevel: MirmirAdjustmentLevel = .medium,
        effects: UpscaleEffectConfiguration = .default,
        smoothMotion: SmoothMotionConfiguration = .default
    ) {
        self.mode = mode
        self.outputCodec = outputCodec
        self.enginePreference = enginePreference
        self.strategyPreference = strategyPreference
        self.temporalConsistencyEnabled = temporalConsistencyEnabled
        self.edgeFidelityLevel = edgeFidelityLevel
        self.detailRecoveryLevel = detailRecoveryLevel
        self.effects = effects
        self.smoothMotion = smoothMotion
    }

    init(preferences: MirmirPreferencesSnapshot) {
        self.init(
            mode: preferences.defaultUpscaleMode,
            outputCodec: preferences.defaultOutputCodec,
            enginePreference: preferences.enginePreference,
            strategyPreference: preferences.strategyPreference,
            temporalConsistencyEnabled:
                preferences.temporalConsistencyEnabled,
            edgeFidelityLevel: preferences.edgeFidelityLevel,
            detailRecoveryLevel: preferences.detailRecoveryLevel,
            effects: UpscaleEffectConfiguration(
                edgePreservationEnabled:
                    preferences.edgePreservationEnabled,
                compressionCleanupEnabled:
                    preferences.compressionCleanupEnabled,
                textureGrainProtectionEnabled:
                    preferences.textureGrainProtectionEnabled,
                temporalStabilityEnabled:
                    preferences.temporalStabilityEnabled
            ),
            smoothMotion: SmoothMotionConfiguration(
                cadence: preferences.smoothMotionCadence,
                sceneCutSensitivity:
                    preferences.smoothMotionSceneCutSensitivity
            )
        )
    }

    var processingConfiguration: UpscaleProcessingConfiguration {
        UpscaleProcessingConfiguration(
            enginePreference: enginePreference,
            strategyPreference: strategyPreference,
            temporalConsistencyEnabled: temporalConsistencyEnabled,
            edgeFidelityLevel: edgeFidelityLevel,
            detailRecoveryLevel: detailRecoveryLevel,
            effects: effects,
            smoothMotion: smoothMotion
        )
    }
}

struct MirmirDraftJobConfiguration: Equatable, Sendable {
    let mode: UpscaleMode
    let outputCodec: OutputCodec
    let processingConfiguration: UpscaleProcessingConfiguration

    init(defaults: MirmirPersistedJobDefaults) {
        mode = defaults.mode
        outputCodec = defaults.outputCodec
        processingConfiguration = defaults.processingConfiguration
    }

    init(
        mode: UpscaleMode,
        outputCodec: OutputCodec,
        processingConfiguration: UpscaleProcessingConfiguration
    ) {
        self.mode = mode
        self.outputCodec = outputCodec
        self.processingConfiguration = processingConfiguration
    }
}

struct MirmirSecurityScopedResourceAccess: Sendable {
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void
    let canCreateBookmark: @Sendable (URL) -> Bool

    static let foundation = MirmirSecurityScopedResourceAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() },
        canCreateBookmark: { url in
            do {
                _ = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                return true
            } catch {
                return false
            }
        }
    )
}

final class MirmirSecurityScopedSelectionLease: @unchecked Sendable {
    enum Acquisition {
        case adoptedSystemGrant
        case explicitStart
    }

    let url: URL
    let hasActiveAccess: Bool

    private let stopAccessing: @Sendable (URL) -> Void

    init(
        url: URL,
        access: MirmirSecurityScopedResourceAccess,
        acquisition: Acquisition
    ) {
        self.url = url
        self.stopAccessing = access.stopAccessing
        switch acquisition {
        case .adoptedSystemGrant:
            hasActiveAccess = true
        case .explicitStart:
            hasActiveAccess = access.startAccessing(url)
        }
    }

    deinit {
        if hasActiveAccess {
            stopAccessing(url)
        }
    }
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

        let retainedSecurityAccess:
            RetainedJobSecurityAccess

        init(job: UpscaleJob, source: SourceProfile) {
            self.init(
                job: job,
                source: source,
                retainedSecurityAccess: RetainedJobSecurityAccess()
            )
        }

        init(
            job: UpscaleJob,
            source: SourceProfile,
            retainedSecurityAccess: RetainedJobSecurityAccess
        ) {
            self.job = job
            self.source = source
            self.retainedSecurityAccess = retainedSecurityAccess
        }
    }

    struct RetainedJobSecurityAccess: Sendable {
        let recovery: R13SecurityScopedAccessSet?
        let pendingQueue: PendingQueueSecurityAccess?

        init(
            recovery: R13SecurityScopedAccessSet? = nil,
            pendingQueue: PendingQueueSecurityAccess? = nil
        ) {
            self.recovery = recovery
            self.pendingQueue = pendingQueue
        }

        func releaseOutputDirectory() {
            recovery?.releaseOutputDirectory()
            pendingQueue?.releaseOutputDirectory()
        }
    }

    private struct CancelledReadyJobSecurityAccess {
        let sourceURL: URL
        let outputDirectoryURL: URL
        let retainedAccess: RetainedJobSecurityAccess

        func retainedAccess(for job: UpscaleJob)
            -> RetainedJobSecurityAccess? {
            guard sourceURL.standardizedFileURL
                    == job.inputURL.standardizedFileURL else {
                return nil
            }
            return retainedAccess
        }

        func releaseOutputDirectoryIfReplaced(
            by selectedDirectoryURL: URL
        ) {
            guard outputDirectoryURL.standardizedFileURL
                    != selectedDirectoryURL.standardizedFileURL else {
                return
            }
            retainedAccess.releaseOutputDirectory()
        }
    }

    private struct PendingHistoryReprocess {
        let sourceURL: URL
        let outputDirectoryURL: URL
        let outputDirectoryAccess: MirmirSecurityScopedSelectionLease
        let record: MirmirWorkHistoryRecord
    }

    final class PendingQueueSecurityAccess: @unchecked Sendable {
        private let lock = NSLock()
        private let sourceURL: URL
        private let outputDirectoryURL: URL
        private let stopAccessing: @Sendable (URL) -> Void
        private let sourceAccessStarted: Bool
        private let outputAccessStarted: Bool
        private var sourceIsStopped = false
        private var outputIsStopped = false

        init(
            sourceURL: URL,
            outputDirectoryURL: URL,
            access: MirmirSecurityScopedResourceAccess
        ) {
            self.sourceURL = sourceURL
            self.outputDirectoryURL = outputDirectoryURL
            stopAccessing = access.stopAccessing
            sourceAccessStarted = access.startAccessing(sourceURL)
            outputAccessStarted = access.startAccessing(outputDirectoryURL)
        }

        var authorizationFailureRole: MirmirWorkHistoryBookmarkRole? {
            if !sourceAccessStarted { return .source }
            if !outputAccessStarted { return .output }
            return nil
        }

        func releaseOutputDirectory() {
            let shouldStopOutput = lock.withLock {
                guard !outputIsStopped else { return false }
                outputIsStopped = true
                return outputAccessStarted
            }
            if shouldStopOutput {
                stopAccessing(outputDirectoryURL)
            }
        }

        func stop() {
            let rolesToStop = lock.withLock {
                let stopOutput = !outputIsStopped && outputAccessStarted
                let stopSource = !sourceIsStopped && sourceAccessStarted
                outputIsStopped = true
                sourceIsStopped = true
                return (output: stopOutput, source: stopSource)
            }
            if rolesToStop.output {
                stopAccessing(outputDirectoryURL)
            }
            if rolesToStop.source {
                stopAccessing(sourceURL)
            }
        }

        deinit {
            stop()
        }
    }

    @Published var sourceProfile: SourceProfile? {
        didSet {
            synchronizeModelAssetsRoute()
        }
    }
    @Published var appearanceMode: MirmirAppearanceMode = .system
    @Published private(set) var persistedDefaults:
        MirmirPersistedJobDefaults
    @Published var targetResolution: VideoResolution = .p1080 {
        didSet {
            synchronizeModelAssetsRoute()
        }
    }
    @Published var preserveAudio = false
    @Published var codec: OutputCodec = .hevc
    @Published var selectedMode: UpscaleMode = .deterministic {
        didSet {
            synchronizeModelAssetsRoute()
        }
    }
    @Published var enginePreference: UpscaleEnginePreference = .automatic {
        didSet {
            synchronizeModelAssetsRoute()
        }
    }
    @Published private(set) var selectedEnginePreferences:
        [UpscaleEnginePreference] = [.automatic]
    @Published var strategyPreference:
        UpscaleStrategyPreference = .automatic
    @Published var temporalConsistencyEnabled = true
    @Published var edgeFidelityLevel: MirmirAdjustmentLevel = .medium
    @Published var detailRecoveryLevel: MirmirAdjustmentLevel = .medium
    @Published var edgePreservationEnabled = false
    @Published var compressionCleanupEnabled = false
    @Published var textureGrainProtectionEnabled = false
    @Published var temporalStabilityEnabled = false
    @Published var smoothMotionCadence: SmoothMotionCadence = .double
    @Published var smoothMotionSceneCutSensitivity:
        SmoothMotionSceneCutSensitivity = .standard
    @Published var modelStatus: ModelAssetsStatus = .unknown
    @Published private(set) var modelAssetsBinding:
        ModelAssetsRouteBinding = .unresolved
    @Published private(set) var engineAvailability: UpscalerEngineAvailability
    @Published var progress: UpscaleProgress?
    @Published private(set) var latestPreviewFrame: UpscalePreviewFrame?
    @Published var state: JobState = .idle
    @Published var outputURL: URL?
    @Published var outputSelectionError: String?
    @Published private(set) var completedOutputRevealError: String?
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
    @Published private(set) var workHistoryRecords:
        [MirmirWorkHistoryRecord] = []
    @Published private(set) var workHistoryLocationStates:
        [String: MirmirWorkHistoryBookmarkStates] = [:]
    @Published private(set) var workHistoryIsLoading = false
    @Published private(set) var workHistoryError: String?
    @Published private(set) var workHistoryRecoveryNotice: String?
    @Published private(set) var workHistoryReprocessInProgressID: String?
    @Published private(set) var workHistoryReauthorizationRequiredIDs:
        Set<String> = []
    @Published private(set) var historyReprocessNavigationRequest: UUID?
    @Published private(set) var pendingWorkRecords:
        [MirmirPendingWorkRecord] = []
    @Published private(set) var processingPathBatchSummary:
        MirmirProcessingPathBatchSummary?
    @Published private(set) var pendingQueueIsLoading = false
    @Published private(set) var pendingQueueMutationIsInProgress = false
    @Published private(set) var pendingQueueError: String?
    @Published private(set) var pendingQueueRecoveryNotice: String?

    let mediaPipeline: MediaPipelineService
    let upscalerEngine: UpscalerEngineService
    let diagnosticStore: MirmirDiagnosticStore
    let diagnosticRecorder: MirmirDiagnosticRecorder
    private let modelAssets: ModelAssetsService
    private let revealFileInFinder: (URL) -> Void
    private let preferencesStore: MirmirPreferencesStore?
    private var persistedEnginePreferences:
        [UpscaleEnginePreference] = [.automatic]
    private let workHistoryStore: MirmirWorkHistoryStore?
    private let pendingWorkQueue: MirmirPendingWorkQueue?
    private var draftJobConfiguration: MirmirDraftJobConfiguration
    private let workHistoryBookmarkResolver:
        any MirmirWorkHistoryBookmarkResolving
    private let workHistoryOutputIdentityMeasurer:
        any R13RestartSourceMeasuring
    private let securityScopedResourceAccess:
        MirmirSecurityScopedResourceAccess

    private var modelStatusTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var sourceProbeTask: Task<Void, Never>?
    private var sourceProbeGeneration = 0
    private var progressTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    var recoveryTask: Task<Void, Never>?
    var recoveryMutationTask: Task<Void, Never>?
    var recoveryGeneration = 0
    var releaseDiagnosticsTask: Task<Void, Never>?
    private var workHistoryLoadTask: Task<Void, Never>?
    private var pendingQueueTask: Task<Void, Never>?
    private var pendingQueueMutationDepth = 0
    private var jobHandle: UpscalerJobHandle?
    var retryableFailedJob: RetryableFailedJob?
    private var terminalJobSecurityAccess: RetainedJobSecurityAccess?
    private var cancelledReadyJobSecurityAccess:
        CancelledReadyJobSecurityAccess?
    private var jobTimingByIdentifier:
        [String: (createdAt: Date, startedAt: Date?)] = [:]
    private var pendingHistoryReprocess: PendingHistoryReprocess?
    private var activePendingQueueJobID: String?
    private var activePendingQueueSecurityAccess:
        PendingQueueSecurityAccess?
    private var selectedSourceAccess:
        MirmirSecurityScopedSelectionLease?
    var selectedOutputDirectoryAccess:
        MirmirSecurityScopedSelectionLease?

    var jobIsRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var jobConfigurationIsEditable: Bool {
        !jobIsRunning
    }

    var completedOutputURL: URL? {
        guard case .finished(let url) = state else { return nil }
        return url
    }

    init(
        mediaPipeline: MediaPipelineService,
        upscalerEngine: UpscalerEngineService,
        modelAssets: ModelAssetsService,
        diagnostics: MirmirDiagnosticStore? = nil,
        preferencesStore: MirmirPreferencesStore? = nil,
        workHistoryStore: MirmirWorkHistoryStore? = nil,
        pendingWorkQueue: MirmirPendingWorkQueue? = nil,
        workHistoryBookmarkResolver:
            any MirmirWorkHistoryBookmarkResolving =
                MirmirFoundationWorkBookmarkResolver(),
        workHistoryOutputIdentityMeasurer:
            any R13RestartSourceMeasuring =
                R13LocalRestartSourceMeasurer(),
        securityScopedResourceAccess:
            MirmirSecurityScopedResourceAccess = .foundation,
        revealFileInFinder: @escaping (URL) -> Void = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    ) {
        let preferences =
            preferencesStore?.load() ?? MirmirPreferencesSnapshot.default
        let persistedDefaults = MirmirPersistedJobDefaults(
            preferences: preferences
        )
        let draftJobConfiguration = MirmirDraftJobConfiguration(
            defaults: persistedDefaults
        )
        let diagnosticStore = diagnostics
            ?? MirmirDiagnosticStore(inMemoryWith: .production)
        self.mediaPipeline = mediaPipeline
        self.upscalerEngine = upscalerEngine
        self.modelAssets = modelAssets
        self.revealFileInFinder = revealFileInFinder
        self.preferencesStore = preferencesStore
        self.persistedEnginePreferences = preferences.enginePreferences
        self.workHistoryStore = workHistoryStore
        self.pendingWorkQueue = pendingWorkQueue
        self.draftJobConfiguration = draftJobConfiguration
        self.workHistoryBookmarkResolver =
            workHistoryBookmarkResolver
        self.workHistoryOutputIdentityMeasurer =
            workHistoryOutputIdentityMeasurer
        self.securityScopedResourceAccess =
            securityScopedResourceAccess
        self.persistedDefaults = persistedDefaults
        self.diagnosticStore = diagnosticStore
        self.diagnosticRecorder = MirmirDiagnosticRecorder(
            store: diagnosticStore
        )
        self.engineAvailability = upscalerEngine.availability
        self.appearanceMode = preferences.appearanceMode
        self.selectedMode = draftJobConfiguration.mode
        self.codec = draftJobConfiguration.outputCodec
        self.selectedEnginePreferences = UpscaleEnginePreference
            .normalizedProcessingPaths(
                preferences.enginePreferences,
                fallback: draftJobConfiguration.processingConfiguration
                    .enginePreference
            )
        self.enginePreference = self.selectedEnginePreferences[0]
        self.strategyPreference =
            draftJobConfiguration.processingConfiguration.strategyPreference
        self.temporalConsistencyEnabled =
            draftJobConfiguration.processingConfiguration
                .temporalConsistencyEnabled
        self.edgeFidelityLevel =
            draftJobConfiguration.processingConfiguration.edgeFidelityLevel
        self.detailRecoveryLevel =
            draftJobConfiguration.processingConfiguration
                .detailRecoveryLevel
        self.edgePreservationEnabled =
            draftJobConfiguration.processingConfiguration.effects
                .edgePreservationEnabled
        self.compressionCleanupEnabled =
            draftJobConfiguration.processingConfiguration.effects
                .compressionCleanupEnabled
        self.textureGrainProtectionEnabled =
            draftJobConfiguration.processingConfiguration.effects
                .textureGrainProtectionEnabled
        self.temporalStabilityEnabled =
            draftJobConfiguration.processingConfiguration.effects
                .temporalStabilityEnabled
        self.smoothMotionCadence =
            draftJobConfiguration.processingConfiguration.smoothMotion
                .cadence
        self.smoothMotionSceneCutSensitivity =
            draftJobConfiguration.processingConfiguration.smoothMotion
                .sceneCutSensitivity
        updateDraftJobConfigurationFromCurrentSelections()
        startObservingModelStatus()
        synchronizeModelAssetsRoute()
        refreshCacheLocation()
        loadRecoverableJobs()
        refreshReleaseDiagnostics()
        refreshWorkHistory()
        refreshPendingQueue()
    }

    deinit {
        modelStatusTask?.cancel()
        modelPreparationTask?.cancel()
        sourceProbeTask?.cancel()
        progressTask?.cancel()
        previewTask?.cancel()
        recoveryTask?.cancel()
        recoveryMutationTask?.cancel()
        releaseDiagnosticsTask?.cancel()
        workHistoryLoadTask?.cancel()
        pendingQueueTask?.cancel()
        activePendingQueueSecurityAccess?.stop()
    }

    var effectOptions: [MirmirEffectOption] {
        MirmirEffectOption.allOptions
    }

    var currentEffects: UpscaleEffectConfiguration {
        UpscaleEffectConfiguration(
            edgePreservationEnabled: edgePreservationEnabled,
            compressionCleanupEnabled: compressionCleanupEnabled,
            textureGrainProtectionEnabled:
                textureGrainProtectionEnabled,
            temporalStabilityEnabled: temporalStabilityEnabled
        )
    }

    private var currentProcessingConfiguration:
        UpscaleProcessingConfiguration {
        processingConfiguration(for: enginePreference)
    }

    private func processingConfiguration(
        for path: UpscaleEnginePreference
    ) -> UpscaleProcessingConfiguration {
        UpscaleProcessingConfiguration(
            enginePreference: path,
            strategyPreference: strategyPreference,
            temporalConsistencyEnabled: temporalConsistencyEnabled,
            edgeFidelityLevel: edgeFidelityLevel,
            detailRecoveryLevel: detailRecoveryLevel,
            effects: currentEffects,
            smoothMotion: SmoothMotionConfiguration(
                cadence: smoothMotionCadence,
                sceneCutSensitivity:
                    smoothMotionSceneCutSensitivity
            )
        )
    }

    func refreshWorkHistory() {
        workHistoryLoadTask?.cancel()
        guard let workHistoryStore else {
            workHistoryRecords = []
            workHistoryLocationStates = [:]
            workHistoryReauthorizationRequiredIDs = []
            workHistoryIsLoading = false
            workHistoryError = nil
            workHistoryRecoveryNotice = nil
            return
        }
        workHistoryIsLoading = true
        let resolver = workHistoryBookmarkResolver
        let securityAccess = securityScopedResourceAccess
        workHistoryLoadTask = Task { [weak self] in
            do {
                let snapshot = try await workHistoryStore.snapshot()
                let locationStates = await workHistoryStore.bookmarkStates(
                    records: snapshot.records,
                    resolver: resolver,
                    securityScopedResourceAccess:
                        securityAccess
                )
                guard let self, !Task.isCancelled else { return }
                applyWorkHistorySnapshot(
                    snapshot,
                    locationStates: locationStates
                )
                workHistoryError = nil
                workHistoryIsLoading = false
                workHistoryLoadTask = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                workHistoryError = Self.historyErrorDescription(error)
                workHistoryIsLoading = false
                workHistoryLoadTask = nil
            }
        }
    }

    func workHistoryLocationStatusText(id: String) -> String {
        guard let states = workHistoryLocationStates[id] else {
            return "Checking saved source and output access…"
        }
        return "Source \(Self.workHistoryLocationStateText(states.source))"
            + " · Output "
            + Self.workHistoryLocationStateText(states.output)
    }

    func workHistoryRevealFailureReason(id: String) -> String? {
        guard let record = workHistoryRecords.first(
            where: { $0.id == id }
        ) else {
            return "This history record is no longer available. Refresh the "
                + "Library before trying again."
        }
        guard record.terminalResult == .completed else {
            return "Only completed history items have an output to reveal."
        }
        guard let outputState =
                workHistoryLocationStates[id]?.output else {
            return "Wait for the Library to finish checking the saved output."
        }
        switch outputState {
        case .available:
            return nil
        case .missing:
            return "The completed output “\(record.outputDisplayName)” is no "
                + "longer at its saved location. Select Reauthorize and "
                + "choose the source plus the folder that contains it."
        case .reauthorizationRequired:
            return "Mirmir no longer has permission to reveal this completed "
                + "output. Select Reauthorize and choose the source and "
                + "output folder again."
        }
    }

    func revealWorkHistoryOutput(id: String) {
        guard let workHistoryStore else {
            workHistoryError = "Work history is unavailable. Restart Mirmir, "
                + "then try again."
            return
        }
        if let failureReason = workHistoryRevealFailureReason(id: id) {
            workHistoryError = failureReason
            return
        }
        guard let record = workHistoryRecords.first(
            where: { $0.id == id }
        ) else {
            workHistoryError = "This history record is no longer available."
            return
        }
        let resolver = workHistoryBookmarkResolver
        let securityAccess = securityScopedResourceAccess
        Task { [weak self] in
            do {
                let locations = try await workHistoryStore
                    .resolveLocations(id: id, resolver: resolver)
                guard !locations.outputBookmarkIsStale else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .output)
                }
                let scopedURL = record.outputBookmarkScope == .directory
                    ? locations.outputDirectoryURL
                    : locations.outputFileURL
                let outputAccess = MirmirSecurityScopedSelectionLease(
                    url: scopedURL,
                    access: securityAccess,
                    acquisition: .explicitStart
                )
                defer {
                    withExtendedLifetime(outputAccess) {}
                }
                guard outputAccess.hasActiveAccess else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .output)
                }
                guard FileManager.default.fileExists(
                          atPath: locations.outputFileURL.path
                      ) else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .output)
                }
                guard let self else { return }
                revealFileInFinder(locations.outputFileURL)
                workHistoryError = nil
            } catch {
                guard let self else { return }
                if let states = try? await workHistoryStore.bookmarkStates(
                    id: id,
                    resolver: resolver,
                    securityScopedResourceAccess:
                        securityAccess
                ) {
                    applyWorkHistoryLocationState(states, id: id)
                }
                workHistoryError =
                    workHistoryRevealFailureReason(id: id)
                    ?? Self.historyErrorDescription(error)
            }
        }
    }

    func removeWorkHistoryRecord(id: String) {
        guard let workHistoryStore else { return }
        let resolver = workHistoryBookmarkResolver
        let securityAccess = securityScopedResourceAccess
        Task { [weak self] in
            do {
                _ = try await workHistoryStore.remove(id: id)
                let snapshot = try await workHistoryStore.snapshot()
                let locationStates = await workHistoryStore.bookmarkStates(
                    records: snapshot.records,
                    resolver: resolver,
                    securityScopedResourceAccess:
                        securityAccess
                )
                guard let self else { return }
                applyWorkHistorySnapshot(
                    snapshot,
                    locationStates: locationStates
                )
                workHistoryError = nil
            } catch {
                guard let self else { return }
                workHistoryError = Self.historyErrorDescription(error)
            }
        }
    }

    func reprocessWorkHistoryRecord(id: String) {
        guard workHistoryReprocessFailureReason(id: id) == nil,
              let workHistoryStore,
              let record = workHistoryRecords.first(
                  where: { $0.id == id }
              ) else {
            return
        }
        workHistoryReprocessInProgressID = id
        workHistoryError = nil
        let resolver = workHistoryBookmarkResolver
        let securityAccess = securityScopedResourceAccess
        Task { [weak self] in
            guard let self else { return }
            defer {
                workHistoryReprocessInProgressID = nil
            }
            do {
                let locations = try await workHistoryStore
                    .resolveLocations(id: id, resolver: resolver)
                guard !locations.sourceBookmarkIsStale else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .source)
                }
                guard !locations.outputBookmarkIsStale else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .output)
                }
                guard record.outputBookmarkScope == .directory else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .output)
                }
                let sourceAccess = MirmirSecurityScopedSelectionLease(
                    url: locations.sourceURL,
                    access: securityAccess,
                    acquisition: .explicitStart
                )
                guard sourceAccess.hasActiveAccess else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .source)
                }
                guard FileManager.default.fileExists(
                    atPath: locations.sourceURL.path
                ) else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .source)
                }
                let outputDirectoryAccess =
                    MirmirSecurityScopedSelectionLease(
                        url: locations.outputDirectoryURL,
                        access: securityAccess,
                        acquisition: .explicitStart
                    )
                guard outputDirectoryAccess.hasActiveAccess else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .output)
                }
                var outputIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: locations.outputDirectoryURL.path,
                    isDirectory: &outputIsDirectory
                ),
                outputIsDirectory.boolValue else {
                    throw MirmirWorkHistoryBookmarkError
                        .resolutionFailed(role: .output)
                }
                pendingHistoryReprocess = PendingHistoryReprocess(
                    sourceURL: locations.sourceURL,
                    outputDirectoryURL:
                        locations.outputDirectoryURL,
                    outputDirectoryAccess: outputDirectoryAccess,
                    record: record
                )
                workHistoryReauthorizationRequiredIDs.remove(id)
                workHistoryError = nil
                loadSource(
                    url: locations.sourceURL,
                    retaining: sourceAccess
                )
                historyReprocessNavigationRequest = UUID()
            } catch {
                if let states = try? await workHistoryStore.bookmarkStates(
                    id: id,
                    resolver: resolver,
                    securityScopedResourceAccess:
                        securityAccess
                ) {
                    applyWorkHistoryLocationState(states, id: id)
                }
                if error is MirmirWorkHistoryBookmarkError {
                    workHistoryReauthorizationRequiredIDs.insert(id)
                }
                workHistoryError =
                    workHistoryReprocessFailureReason(id: id)
                    ?? Self.historyErrorDescription(error)
            }
        }
    }

    func workHistoryReprocessFailureReason(id: String) -> String? {
        guard workHistoryStore != nil else {
            return "Work history is unavailable. Restart Mirmir, then try "
                + "again."
        }
        guard let record = workHistoryRecords.first(
            where: { $0.id == id }
        ) else {
            return "This history record is no longer available. Refresh the "
                + "Library before trying again."
        }
        guard record.outputBookmarkScope == .directory else {
            return "This older history item retained permission only for its "
                + "completed output file. Select Reauthorize and choose the "
                + "source and output folder before reprocessing."
        }
        if let states = workHistoryLocationStates[id] {
            switch states.source {
            case .available:
                break
            case .missing:
                return "The saved source “\(record.sourceDisplayName)” is no "
                    + "longer at its recorded location. Select Reauthorize "
                    + "and choose the source and output folder again."
            case .reauthorizationRequired:
                return "Mirmir no longer has permission to reopen the saved "
                    + "source. Select Reauthorize and choose the source and "
                    + "output folder again."
            }
            if states.output == .missing,
               record.terminalResult != .completed {
                return "The saved output folder is no longer available. "
                    + "Select Reauthorize and choose the source and output "
                    + "folder again."
            }
            if states.output == .reauthorizationRequired {
                return "Mirmir no longer has permission to use the saved "
                    + "output folder. Select Reauthorize and choose the "
                    + "source and output folder again."
            }
        } else {
            return "Wait for the Library to finish checking saved access, "
                + "then reprocess."
        }
        if workHistoryReauthorizationRequiredIDs.contains(id) {
            return "Mirmir can no longer access this history source or "
                + "output folder. Select Reauthorize, choose both locations "
                + "again, then reprocess."
        }
        if jobIsRunning {
            return "Wait for the active upscale to finish, then reprocess "
                + "this history item."
        }
        if workHistoryReprocessInProgressID != nil {
            return "Wait for the current history item to finish preparing, "
                + "then reprocess."
        }
        return nil
    }

    func reauthorizeWorkHistoryRecord(id: String) {
        guard !jobIsRunning,
              let workHistoryStore,
              let record = workHistoryRecords.first(
                  where: { $0.id == id }
              ) else {
            return
        }

        let sourcePanel = NSOpenPanel()
        sourcePanel.title = "Reauthorize Source Video"
        sourcePanel.prompt = "Select Source"
        sourcePanel.allowsMultipleSelection = false
        sourcePanel.canChooseDirectories = false
        sourcePanel.canChooseFiles = true
        guard sourcePanel.runModal() == .OK,
              let sourceURL = sourcePanel.url else {
            return
        }
        let sourceAccess = adoptSystemSelectedSecurityScope(for: sourceURL)

        let outputPanel = NSOpenPanel()
        outputPanel.title = "Reauthorize Output Folder"
        outputPanel.prompt = "Select Folder"
        outputPanel.allowsMultipleSelection = false
        outputPanel.canChooseDirectories = true
        outputPanel.canChooseFiles = false
        outputPanel.canCreateDirectories = true
        guard outputPanel.runModal() == .OK,
              let outputDirectoryURL = outputPanel.url else {
            return
        }
        let outputDirectoryAccess = adoptSystemSelectedSecurityScope(
            for: outputDirectoryURL
        )

        let resolver = workHistoryBookmarkResolver
        let securityAccess = securityScopedResourceAccess
        Task { [weak self, sourceAccess, outputDirectoryAccess] in
            defer {
                withExtendedLifetime(sourceAccess) {}
                withExtendedLifetime(outputDirectoryAccess) {}
            }
            do {
                let updated = try await Task.detached {
                    MirmirWorkHistoryRecord(
                        id: record.id,
                        sourceBookmark: try resolver.makeBookmark(
                            for: sourceURL,
                            role: .source
                        ),
                        outputBookmark: try resolver.makeBookmark(
                            for: outputDirectoryURL,
                            role: .output
                        ),
                        outputBookmarkScope: .directory,
                        sourceDisplayName: sourceURL.lastPathComponent,
                        outputDisplayName: record.outputDisplayName,
                        sourceResolution: record.sourceResolution,
                        targetResolution: record.targetResolution,
                        codec: record.codec,
                        sourceAudioTrackCount:
                            record.sourceAudioTrackCount,
                        sourceScanStructure:
                            record.sourceScanStructure,
                        preserveAudio: record.preserveAudio,
                        requestedMode: record.requestedMode,
                        processingConfiguration:
                            record.processingConfiguration,
                        createdAt: record.createdAt,
                        startedAt: record.startedAt,
                        completedAt: record.completedAt,
                        terminalResult: record.terminalResult,
                        outputVerification: record.outputVerification
                    )
                }.value
                let snapshot = try await workHistoryStore.update(updated)
                let locationStates = await workHistoryStore.bookmarkStates(
                    records: snapshot.records,
                    resolver: resolver,
                    securityScopedResourceAccess:
                        securityAccess
                )
                guard let self else { return }
                applyWorkHistorySnapshot(
                    snapshot,
                    locationStates: locationStates
                )
                workHistoryError = nil
            } catch {
                guard let self else { return }
                workHistoryError = Self.historyErrorDescription(error)
            }
        }
    }

    private func applyWorkHistorySnapshot(
        _ snapshot: MirmirWorkHistorySnapshot,
        locationStates:
            [String: MirmirWorkHistoryBookmarkStates]
    ) {
        workHistoryLocationStates = locationStates
        workHistoryRecords = snapshot.records
        workHistoryReauthorizationRequiredIDs = Set(
            locationStates.compactMap { id, states in
                Self.workHistoryNeedsReauthorization(states)
                    ? id
                    : nil
            }
        )
        workHistoryRecoveryNotice = snapshot.recovery.map {
            "Mirmir recovered a damaged history document and preserved it "
                + "as \($0.quarantineFileName)."
        }
    }

    private func applyWorkHistoryLocationState(
        _ states: MirmirWorkHistoryBookmarkStates,
        id: String
    ) {
        workHistoryLocationStates[id] = states
        if Self.workHistoryNeedsReauthorization(states) {
            workHistoryReauthorizationRequiredIDs.insert(id)
        } else {
            workHistoryReauthorizationRequiredIDs.remove(id)
        }
    }

    private static func workHistoryNeedsReauthorization(
        _ states: MirmirWorkHistoryBookmarkStates
    ) -> Bool {
        states.source == .reauthorizationRequired
            || states.output == .reauthorizationRequired
    }

    private static func workHistoryLocationStateText(
        _ state: MirmirWorkHistoryBookmarkState
    ) -> String {
        switch state {
        case .available:
            return "available"
        case .missing:
            return "missing"
        case .reauthorizationRequired:
            return "permission required"
        }
    }

    func refreshPendingQueue() {
        pendingQueueTask?.cancel()
        guard let pendingWorkQueue else {
            pendingWorkRecords = []
            pendingQueueIsLoading = false
            pendingQueueError = nil
            pendingQueueRecoveryNotice = nil
            return
        }
        pendingQueueIsLoading = true
        pendingQueueTask = Task { [weak self] in
            do {
                let snapshot = try await pendingWorkQueue.load()
                guard let self, !Task.isCancelled else { return }
                applyPendingQueueSnapshot(snapshot)
                pendingQueueError = nil
                pendingQueueIsLoading = false
                pendingQueueTask = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                pendingQueueError = Self.historyErrorDescription(error)
                pendingQueueIsLoading = false
                pendingQueueTask = nil
            }
        }
    }

    func chooseVideosForQueue() {
        guard !pendingQueueMutationIsInProgress else { return }
        let panel = NSOpenPanel()
        panel.title = "Add Videos to Queue"
        panel.prompt = "Add to Queue"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        let sourceURLs = panel.urls
        let sourceAccesses = sourceURLs.map {
            adoptSystemSelectedSecurityScope(for: $0)
        }
        let outputPanel = NSOpenPanel()
        outputPanel.title = "Select an Output Folder for Queued Videos"
        outputPanel.prompt = "Select Output Folder"
        outputPanel.allowsMultipleSelection = false
        outputPanel.canChooseDirectories = true
        outputPanel.canChooseFiles = false
        outputPanel.canCreateDirectories = true
        outputPanel.directoryURL =
            sourceURLs.first?.deletingLastPathComponent()
        guard outputPanel.runModal() == .OK,
              let outputDirectoryURL = outputPanel.url else {
            return
        }
        let outputDirectoryAccess = adoptSystemSelectedSecurityScope(
            for: outputDirectoryURL
        )
        enqueueSourceURLs(
            sourceURLs,
            outputDirectoryURL: outputDirectoryURL,
            retainingSystemSelectionAccesses:
                sourceAccesses + [outputDirectoryAccess]
        )
    }

    func enqueueSourceURLs(
        _ urls: [URL],
        outputDirectoryURL selectedOutputDirectoryURL: URL? = nil,
        retainingSystemSelectionAccesses:
            [MirmirSecurityScopedSelectionLease] = []
    ) {
        guard let pendingWorkQueue,
              !urls.isEmpty,
              !pendingQueueMutationIsInProgress else {
            return
        }
        beginPendingQueueMutation()
        pendingQueueError = nil
        let defaults = persistedDefaults
        let resolver = workHistoryBookmarkResolver

        Task { [weak self, retainingSystemSelectionAccesses] in
            guard let self else { return }
            defer {
                withExtendedLifetime(retainingSystemSelectionAccesses) {}
                endPendingQueueMutation()
            }
            do {
                if let selectedOutputDirectoryURL {
                    var isDirectory: ObjCBool = false
                    guard selectedOutputDirectoryURL.isFileURL,
                          FileManager.default.fileExists(
                              atPath: selectedOutputDirectoryURL.path,
                              isDirectory: &isDirectory
                          ),
                          isDirectory.boolValue else {
                        throw MirmirWorkHistoryBookmarkError
                            .resolutionFailed(role: .output)
                    }
                }
                var records: [MirmirPendingWorkRecord] = []
                records.reserveCapacity(urls.count)
                for (index, url) in urls.enumerated() {
                    guard Self.supportsVideoFile(url) else {
                        throw MirmirPendingQueueError.invalidRecord(
                            field: .sourceDisplayName
                        )
                    }
                    let profile = try await mediaPipeline.probe(url: url)
                    if let reason =
                            Self.mediaPreservationFailureReason(
                                profile,
                                preserveAudio: profile.hasAudio
                            ) {
                        throw MediaPipelineError
                            .mediaPreservationPreflightFailed(reason)
                    }
                    guard let target = Self.targets(
                        for: profile.resolution
                    ).first else {
                        throw MirmirPendingQueueError.invalidRecord(
                            field: .targetResolution
                        )
                    }
                    _ = try R13ReleaseJobContracts.scalePlan(
                        source: profile.resolution,
                        target: target,
                        strategyPreference:
                            defaults.strategyPreference
                    )
                    let outputCodec = try Self.compatibleOutputCodec(
                        preferred: defaults.outputCodec,
                        for: profile.videoFormat
                    )
                    let identifier = UUID().uuidString
                    let outputDirectory =
                        selectedOutputDirectoryURL
                        ?? url.deletingLastPathComponent()
                    let outputName = queuedOutputFilename(
                        source: profile,
                        target: target,
                        codec: outputCodec,
                        identifier: identifier
                    )
                    let bookmarks = MirmirPendingWorkBookmarks(
                        sourceBookmark: try resolver.makeBookmark(
                            for: url,
                            role: .source
                        ),
                        outputBookmark: try resolver.makeBookmark(
                            for: outputDirectory,
                            role: .output
                        ),
                        sourceDisplayName: url.lastPathComponent,
                        outputDisplayName: outputName
                    )
                    records.append(
                        MirmirPendingWorkRecord(
                            id: identifier,
                            bookmarks: bookmarks,
                            settings: MirmirPendingWorkSettings(
                                targetResolution: target,
                                codec: outputCodec,
                                preserveAudio: profile.hasAudio,
                                requestedMode: defaults.mode,
                                processingConfiguration:
                                    defaults.processingConfiguration
                            ),
                            createdAt: Date(),
                            order: index
                        )
                    )
                }
                let snapshot = try await pendingWorkQueue.enqueueMany(
                    records
                )
                applyPendingQueueSnapshot(snapshot)
            } catch {
                pendingQueueError = Self.historyErrorDescription(error)
            }
        }
    }

    func startNextPendingWork() {
        guard let pendingWorkQueue,
              !jobIsRunning,
              !pendingQueueMutationIsInProgress else {
            return
        }
        if case .probing = state { return }
        if case .finished = state {
            upscaleAnotherVideo()
        } else if case .failed = state {
            upscaleAnotherVideo()
        }

        beginPendingQueueMutation()
        pendingQueueError = nil
        let resolver = workHistoryBookmarkResolver
        Task { [weak self] in
            guard let self else { return }
            defer {
                endPendingQueueMutation()
            }
            var claimedID: String?
            do {
                let claim = try await pendingWorkQueue
                    .markStartedOrReturnHead()
                guard let record = claim.record else {
                    applyPendingQueueSnapshot(
                        MirmirPendingQueueSnapshot(
                            records: [],
                            processingPathBatchResults:
                                claim.processingPathBatchResults,
                            recovery: claim.recovery
                        )
                    )
                    return
                }
                claimedID = record.id
                try await beginClaimedPendingWork(
                    record,
                    resolver: resolver
                )
                if jobIsRunning {
                    do {
                        let snapshot = try await pendingWorkQueue.load()
                        applyPendingQueueSnapshot(snapshot)
                    } catch {
                        pendingQueueError =
                            Self.historyErrorDescription(error)
                    }
                }
            } catch {
                if let claimedID {
                    _ = try? await pendingWorkQueue
                        .returnStartedHeadToPending(id: claimedID)
                }
                activePendingQueueSecurityAccess?.stop()
                activePendingQueueSecurityAccess = nil
                activePendingQueueJobID = nil
                pendingQueueError = Self.historyErrorDescription(error)
                if let snapshot = try? await pendingWorkQueue.load() {
                    applyPendingQueueSnapshot(snapshot)
                }
            }
        }
    }

    private func beginClaimedPendingWork(
        _ record: MirmirPendingWorkRecord,
        resolver: any MirmirWorkHistoryBookmarkResolving
    ) async throws {
        let locations = try resolvePendingQueueLocations(
            record,
            resolver: resolver
        )
        let access = PendingQueueSecurityAccess(
            sourceURL: locations.source,
            outputDirectoryURL: locations.outputDirectory,
            access: securityScopedResourceAccess
        )
        if let role = access.authorizationFailureRole {
            access.stop()
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: role)
        }
        guard FileManager.default.fileExists(
            atPath: locations.source.path
        ) else {
            access.stop()
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: .source)
        }
        var outputIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: locations.outputDirectory.path,
            isDirectory: &outputIsDirectory
        ), outputIsDirectory.boolValue else {
            access.stop()
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: .output)
        }
        let profile: SourceProfile
        do {
            profile = try await mediaPipeline.probe(
                url: locations.source
            )
        } catch {
            access.stop()
            throw error
        }
        if let reason = Self.mediaPreservationFailureReason(
            profile,
            preserveAudio:
                profile.hasAudio
                    && record.settings.preserveAudio
        ) {
            access.stop()
            throw MediaPipelineError
                .mediaPreservationPreflightFailed(reason)
        }
        guard Self.targets(for: profile.resolution).contains(
            record.settings.targetResolution
        ) else {
            access.stop()
            throw MirmirPendingQueueError.invalidRecord(
                field: .targetResolution
            )
        }
        _ = try R13ReleaseJobContracts.scalePlan(
            source: profile.resolution,
            target: record.settings.targetResolution,
            strategyPreference:
                record.settings.processingConfiguration
                    .strategyPreference
        )
        let outputURL = locations.outputDirectory
            .appendingPathComponent(
                record.bookmarks.outputDisplayName,
                isDirectory: false
            )
        if let containerError =
                MediaOutputContainerPolicy.validationError(
                    pathExtension: outputURL.pathExtension,
                    codec: record.settings.codec,
                    videoFormat: profile.videoFormat,
                    preservationCapability:
                        profile.mediaPreservationCapability,
                    preserveAudio:
                        profile.hasAudio
                            && record.settings.preserveAudio,
                    preserveSubtitles: true,
                    preserveMetadata: true
                ) {
            access.stop()
            throw containerError
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            access.stop()
            throw UpscalerEngineError.outputAlreadyExists
        }
        sourceProfile = profile
        targetResolution = record.settings.targetResolution
        codec = record.settings.codec
        preserveAudio =
            profile.hasAudio && record.settings.preserveAudio
        selectedMode = record.settings.requestedMode
        applyProcessingConfiguration(
            record.settings.processingConfiguration
        )
        self.outputURL = outputURL
        outputSelectionError = nil
        progress = nil
        state = .ready
        activePendingQueueJobID = record.id
        activePendingQueueSecurityAccess = access
        let job = UpscaleJob(
            identifier: record.id,
            inputURL: profile.url,
            outputURL: outputURL,
            targetResolution: record.settings.targetResolution,
            codec: record.settings.codec,
            preserveAudio:
                profile.hasAudio && record.settings.preserveAudio,
            mode: record.settings.requestedMode,
            processingConfiguration:
                record.settings.processingConfiguration
        )
        submit(job: job, source: profile)
        if !jobIsRunning {
            completeActivePendingQueueJob(
                id: record.id,
                shouldAdvance: false
            )
        }
    }

    func movePendingWork(id: String, offset: Int) {
        guard let pendingWorkQueue,
              !pendingQueueMutationIsInProgress,
              let currentIndex = pendingWorkRecords.firstIndex(
                  where: { $0.id == id }
              ) else {
            return
        }
        let destinationIndex = currentIndex + offset
        guard pendingWorkRecords.indices.contains(destinationIndex)
        else {
            return
        }
        var identifiers = pendingWorkRecords.map(\.id)
        identifiers.swapAt(currentIndex, destinationIndex)
        beginPendingQueueMutation()
        Task { [weak self] in
            guard let self else { return }
            defer {
                endPendingQueueMutation()
            }
            do {
                let snapshot = try await pendingWorkQueue.reorder(
                    ids: identifiers
                )
                applyPendingQueueSnapshot(snapshot)
                pendingQueueError = nil
            } catch {
                pendingQueueError = Self.historyErrorDescription(error)
            }
        }
    }

    func removePendingWork(id: String) {
        guard let pendingWorkQueue,
              id != activePendingQueueJobID,
              !pendingQueueMutationIsInProgress else {
            return
        }
        beginPendingQueueMutation()
        Task { [weak self] in
            guard let self else { return }
            defer {
                endPendingQueueMutation()
            }
            do {
                _ = try await pendingWorkQueue.remove(id: id)
                let snapshot = try await pendingWorkQueue.load()
                applyPendingQueueSnapshot(snapshot)
                pendingQueueError = nil
            } catch {
                pendingQueueError = Self.historyErrorDescription(error)
            }
        }
    }

    func clearPendingWork() {
        guard let pendingWorkQueue,
              activePendingQueueJobID == nil,
              !pendingQueueMutationIsInProgress else {
            return
        }
        beginPendingQueueMutation()
        Task { [weak self] in
            guard let self else { return }
            defer {
                endPendingQueueMutation()
            }
            do {
                let snapshot = try await pendingWorkQueue.clear()
                applyPendingQueueSnapshot(snapshot)
                pendingQueueError = nil
            } catch {
                pendingQueueError = Self.historyErrorDescription(error)
            }
        }
    }

    func reauthorizePendingWork(id: String) {
        guard let pendingWorkQueue,
              !jobIsRunning,
              !pendingQueueMutationIsInProgress,
              let record = pendingWorkRecords.first(
                  where: { $0.id == id }
              ),
              record.state == .pending else {
            return
        }
        let sourcePanel = NSOpenPanel()
        sourcePanel.title = "Reauthorize Queued Source"
        sourcePanel.prompt = "Select Source"
        sourcePanel.canChooseFiles = true
        sourcePanel.canChooseDirectories = false
        guard sourcePanel.runModal() == .OK,
              let sourceURL = sourcePanel.url else {
            return
        }
        let sourceAccess = adoptSystemSelectedSecurityScope(for: sourceURL)
        let outputPanel = NSOpenPanel()
        outputPanel.title = "Reauthorize Queued Output Folder"
        outputPanel.prompt = "Select Folder"
        outputPanel.canChooseFiles = false
        outputPanel.canChooseDirectories = true
        outputPanel.canCreateDirectories = true
        guard outputPanel.runModal() == .OK,
              let outputDirectory = outputPanel.url else {
            return
        }
        let outputDirectoryAccess = adoptSystemSelectedSecurityScope(
            for: outputDirectory
        )
        beginPendingQueueMutation()
        let resolver = workHistoryBookmarkResolver
        Task { [weak self, sourceAccess, outputDirectoryAccess] in
            guard let self else { return }
            defer {
                withExtendedLifetime(sourceAccess) {}
                withExtendedLifetime(outputDirectoryAccess) {}
                endPendingQueueMutation()
            }
            do {
                let updated = MirmirPendingWorkRecord(
                    id: record.id,
                    bookmarks: MirmirPendingWorkBookmarks(
                        sourceBookmark: try resolver.makeBookmark(
                            for: sourceURL,
                            role: .source
                        ),
                        outputBookmark: try resolver.makeBookmark(
                            for: outputDirectory,
                            role: .output
                        ),
                        sourceDisplayName:
                            sourceURL.lastPathComponent,
                        outputDisplayName:
                            record.bookmarks.outputDisplayName
                    ),
                    settings: record.settings,
                    createdAt: record.createdAt,
                    order: record.order
                )
                let snapshot = try await pendingWorkQueue.update(updated)
                applyPendingQueueSnapshot(snapshot)
                pendingQueueError = nil
            } catch {
                pendingQueueError = Self.historyErrorDescription(error)
            }
        }
    }

    private func applyPendingQueueSnapshot(
        _ snapshot: MirmirPendingQueueSnapshot
    ) {
        pendingWorkRecords = snapshot.records
        if let activeBatchID = snapshot.records.compactMap({
            $0.settings.processingPathBatch?.id
        }).first {
            processingPathBatchSummary =
                MirmirProcessingPathBatchSummary(
                    batchID: activeBatchID,
                    results: snapshot.processingPathBatchResults
                )
        } else {
            processingPathBatchSummary =
                MirmirProcessingPathBatchSummary.latest(
                    in: snapshot.processingPathBatchResults
                )
        }
        pendingQueueRecoveryNotice = snapshot.recovery.map {
            "Mirmir recovered a damaged pending queue and preserved it "
                + "as \($0.quarantineFileName)."
        }
    }

    func persistedPendingQueueJobIsStarted(
        id: String
    ) async throws -> Bool {
        guard let pendingWorkQueue else { return false }
        let snapshot = try await pendingWorkQueue.load()
        return snapshot.records.contains {
            $0.id == id && $0.state == .started
        }
    }

    private func beginPendingQueueMutation() {
        pendingQueueMutationDepth += 1
        pendingQueueMutationIsInProgress = true
    }

    private func endPendingQueueMutation() {
        guard pendingQueueMutationDepth > 0 else {
            assertionFailure("Pending-queue mutation accounting underflow.")
            pendingQueueMutationIsInProgress = false
            return
        }
        pendingQueueMutationDepth -= 1
        pendingQueueMutationIsInProgress = pendingQueueMutationDepth > 0
    }

    private func resolvePendingQueueLocations(
        _ record: MirmirPendingWorkRecord,
        resolver: any MirmirWorkHistoryBookmarkResolving
    ) throws -> (source: URL, outputDirectory: URL) {
        let source = try resolver.resolveBookmark(
            record.bookmarks.sourceBookmark,
            role: .source
        )
        let outputDirectory = try resolver.resolveBookmark(
            record.bookmarks.outputBookmark,
            role: .output
        )
        guard !source.isStale,
              source.url.isFileURL else {
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: .source)
        }
        guard !outputDirectory.isStale,
              outputDirectory.url.isFileURL else {
            throw MirmirWorkHistoryBookmarkError
                .resolutionFailed(role: .output)
        }
        return (source.url, outputDirectory.url)
    }

    private func applyProcessingConfiguration(
        _ configuration: UpscaleProcessingConfiguration
    ) {
        selectedEnginePreferences = [configuration.enginePreference]
        enginePreference = configuration.enginePreference
        strategyPreference = configuration.strategyPreference
        temporalConsistencyEnabled =
            configuration.temporalConsistencyEnabled
        edgeFidelityLevel = configuration.edgeFidelityLevel
        detailRecoveryLevel = configuration.detailRecoveryLevel
        edgePreservationEnabled =
            configuration.effects.edgePreservationEnabled
        compressionCleanupEnabled =
            configuration.effects.compressionCleanupEnabled
        textureGrainProtectionEnabled =
            configuration.effects.textureGrainProtectionEnabled
        temporalStabilityEnabled =
            configuration.effects.temporalStabilityEnabled
        smoothMotionCadence = configuration.smoothMotion.cadence
        smoothMotionSceneCutSensitivity =
            configuration.smoothMotion.sceneCutSensitivity
    }

    private func queuedOutputFilename(
        source: SourceProfile,
        target: VideoResolution,
        codec: OutputCodec,
        identifier: String
    ) -> String {
        let defaultName = defaultOutputURL(
            for: source,
            target: target,
            codec: codec
        )
        let defaultFile = URL(fileURLWithPath: defaultName.lastPathComponent)
        let stem = defaultFile.deletingPathExtension().lastPathComponent
        let pathExtension = defaultFile.pathExtension.isEmpty
            ? "mp4"
            : defaultFile.pathExtension
        return "\(stem)_queue_"
            + "\(identifier.prefix(8).lowercased()).\(pathExtension)"
    }

    private func completeActivePendingQueueJob(
        id: String,
        status: MirmirProcessingPathTerminalStatus = .cancelled,
        reason: String? = nil,
        shouldAdvance: Bool
    ) {
        guard activePendingQueueJobID == id,
              let pendingWorkQueue else {
            return
        }
        beginPendingQueueMutation()
        activePendingQueueSecurityAccess = nil
        activePendingQueueJobID = nil
        pendingWorkRecords.removeAll { $0.id == id }

        Task { [weak self] in
            guard let self else { return }
            var shouldStartNext = false
            do {
                let snapshot = try await pendingWorkQueue
                    .recordTerminalResultAndRemove(
                        id: id,
                        status: status,
                        reason: reason
                    )
                applyPendingQueueSnapshot(snapshot)
                applyCompletedProcessingPathBatchState()
                pendingQueueError = nil
                shouldStartNext = shouldAdvance && snapshot.head != nil
            } catch {
                pendingQueueError = Self.historyErrorDescription(error)
                if let snapshot = try? await pendingWorkQueue.load() {
                    applyPendingQueueSnapshot(snapshot)
                }
            }
            endPendingQueueMutation()
            guard shouldStartNext else { return }
            upscaleAnotherVideo()
            startNextPendingWork()
        }
    }

    private func applyCompletedProcessingPathBatchState() {
        guard let summary = processingPathBatchSummary,
              summary.isComplete else {
            return
        }
        if summary.allSucceeded {
            if let outputURL {
                state = .finished(outputURL)
            }
            return
        }
        state = .failed(Self.processingPathBatchFailureText(summary))
    }

    private static func processingPathBatchFailureText(
        _ summary: MirmirProcessingPathBatchSummary
    ) -> String {
        "Selected processing paths completed with "
            + "\(summary.completedCount) of \(summary.totalCount) "
            + "successful, \(summary.failedCount) failed, and "
            + "\(summary.cancelledCount) cancelled."
    }

    private static func historyErrorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
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
        if selectedEnginePreferences.count > 1,
           pendingQueueMutationIsInProgress {
            return "Mirmir is updating pending work."
        }
        if selectedEnginePreferences.count > 1,
           pendingWorkQueue == nil {
            return "Multi-path processing requires the persisted work "
                + "queue, which is unavailable in this session."
        }
        if selectedEnginePreferences.contains(.videoToolboxQuality),
           modelAssetsBinding.requiresConfigurationModel,
           modelStatus != .ready {
            return modelAssetsDetailText
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
        if let reason = Self.mediaPreservationFailureReason(
            sourceProfile,
            preserveAudio:
                sourceProfile.hasAudio && preserveAudio
        ) {
            return reason
        }
        guard !availableTargets.isEmpty else {
            return unsupportedResolutionMessage(sourceProfile.resolution)
        }
        guard availableTargets.contains(targetResolution) else {
            return "Choose a supported target resolution for this source."
        }
        do {
            _ = try R13ReleaseJobContracts.scalePlan(
                source: sourceProfile.resolution,
                target: targetResolution,
                strategyPreference: strategyPreference
            )
        } catch {
            return "The selected strategy cannot process this source and "
                + "target geometry."
        }
        do {
            try R13ReleaseJobContracts.validateOutputCodec(
                codec,
                for: sourceProfile.videoFormat
            )
        } catch {
            return String(describing: error)
        }
        if let outputSelectionError {
            return outputSelectionError
        }
        guard let outputURL else {
            return "Choose an output location."
        }
        if let reason = Self.outputContainerFailureReason(
            outputURL,
            codec: codec,
            source: sourceProfile,
            preserveAudio:
                sourceProfile.hasAudio && preserveAudio
        ) {
            return reason
        }
        guard !FileURLIdentity.refersToSameFile(sourceProfile.url, outputURL) else {
            return Self.sourceOutputConflictMessage
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            return Self.existingOutputConflictMessage
        }
        if selectedEnginePreferences.count > 1 {
            let pathOutputs = selectedEnginePreferences.map {
                Self.processingPathOutputURL(
                    basedOn: outputURL,
                    path: $0
                )
            }
            guard Set(pathOutputs.map(\.standardizedFileURL)).count
                    == pathOutputs.count else {
                return "The selected processing paths do not resolve to "
                    + "distinct output files."
            }
            if pathOutputs.contains(where: {
                FileURLIdentity.refersToSameFile(
                    sourceProfile.url,
                    $0
                )
            }) {
                return Self.sourceOutputConflictMessage
            }
            if pathOutputs.contains(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                return "One or more selected processing-path outputs "
                    + "already exist. Choose another destination name or "
                    + "remove the existing outputs."
            }
        }
        guard state == .ready else {
            return "Choose a source video and output location before starting."
        }
        return nil
    }

    var canStart: Bool {
        canStartFailureReason == nil
    }

    @discardableResult
    func selectTargetForPendingJob(
        _ resolution: VideoResolution
    ) -> Bool {
        guard jobConfigurationIsEditable,
              availableTargets.contains(resolution) else {
            return false
        }
        targetResolution = resolution
        if let sourceProfile, let outputURL {
            self.outputURL = availableDefaultOutputURL(
                for: sourceProfile,
                target: resolution,
                in: outputURL.deletingLastPathComponent()
            )
            outputSelectionError = nil
        }
        return true
    }

    @discardableResult
    func setPreserveAudioForPendingJob(_ enabled: Bool) -> Bool {
        guard jobConfigurationIsEditable,
              let sourceProfile,
              sourceProfile.hasAudio else {
            return false
        }
        preserveAudio = enabled
        if enabled,
           let outputURL,
           MediaOutputContainerPolicy.preferredPathExtension(
               codec: codec,
               videoFormat: sourceProfile.videoFormat,
               preservationCapability:
                   sourceProfile.mediaPreservationCapability,
               preserveAudio: true,
               preserveSubtitles: true,
               preserveMetadata: true
           ) == "mov",
           outputURL.pathExtension.lowercased() != "mov" {
            self.outputURL = availableOutputURL(
                outputURL.deletingPathExtension()
                    .appendingPathExtension("mov")
            )
        }
        if let outputURL {
            outputSelectionError =
                Self.outputContainerFailureReason(
                    outputURL,
                    codec: codec,
                    source: sourceProfile,
                    preserveAudio:
                        sourceProfile.hasAudio && enabled
                )
        }
        return true
    }

    @discardableResult
    func selectAppearanceMode(_ mode: MirmirAppearanceMode) -> Bool {
        appearanceMode = mode
        preferencesStore?.saveAppearanceMode(mode)
        return true
    }

    @discardableResult
    func selectDefaultMode(_ mode: UpscaleMode) -> Bool {
        var updated = persistedDefaults
        updated.mode = mode
        persistedDefaults = updated
        preferencesStore?.saveDefaultUpscaleMode(mode)
        return true
    }

    @discardableResult
    func selectDefaultOutputCodec(_ codec: OutputCodec) -> Bool {
        var updated = persistedDefaults
        updated.outputCodec = codec
        persistedDefaults = updated
        preferencesStore?.saveDefaultOutputCodec(codec)
        return true
    }

    @discardableResult
    func selectDefaultEngine(
        _ preference: UpscaleEnginePreference
    ) -> Bool {
        var updated = persistedDefaults
        updated.enginePreference = preference
        persistedDefaults = updated
        persistedEnginePreferences = [preference]
        preferencesStore?.saveEnginePreference(preference)
        return true
    }

    @discardableResult
    func selectDefaultStrategy(
        _ preference: UpscaleStrategyPreference
    ) -> Bool {
        var updated = persistedDefaults
        updated.strategyPreference = preference
        persistedDefaults = updated
        preferencesStore?.saveStrategyPreference(preference)
        return true
    }

    @discardableResult
    func setDefaultTemporalConsistency(_ enabled: Bool) -> Bool {
        var updated = persistedDefaults
        updated.temporalConsistencyEnabled = enabled
        persistedDefaults = updated
        preferencesStore?.saveTemporalConsistencyEnabled(enabled)
        return true
    }

    @discardableResult
    func selectDefaultEdgeFidelity(
        _ level: MirmirAdjustmentLevel
    ) -> Bool {
        var updated = persistedDefaults
        updated.edgeFidelityLevel = level
        persistedDefaults = updated
        preferencesStore?.saveEdgeFidelityLevel(level)
        return true
    }

    @discardableResult
    func selectDefaultDetailRecovery(
        _ level: MirmirAdjustmentLevel
    ) -> Bool {
        var updated = persistedDefaults
        updated.detailRecoveryLevel = level
        persistedDefaults = updated
        preferencesStore?.saveDetailRecoveryLevel(level)
        return true
    }

    @discardableResult
    func selectDefaultSmoothMotionCadence(
        _ cadence: SmoothMotionCadence
    ) -> Bool {
        var updated = persistedDefaults
        updated.smoothMotion = SmoothMotionConfiguration(
            cadence: cadence,
            sceneCutSensitivity:
                updated.smoothMotion.sceneCutSensitivity
        )
        persistedDefaults = updated
        preferencesStore?.saveSmoothMotionCadence(cadence)
        return true
    }

    @discardableResult
    func selectDefaultSmoothMotionSceneCutSensitivity(
        _ sensitivity: SmoothMotionSceneCutSensitivity
    ) -> Bool {
        var updated = persistedDefaults
        updated.smoothMotion = SmoothMotionConfiguration(
            cadence: updated.smoothMotion.cadence,
            sceneCutSensitivity: sensitivity
        )
        persistedDefaults = updated
        preferencesStore?.saveSmoothMotionSceneCutSensitivity(
            sensitivity
        )
        return true
    }

    @discardableResult
    func setDefaultEdgePreservation(_ enabled: Bool) -> Bool {
        var updated = persistedDefaults
        updated.effects = UpscaleEffectConfiguration(
            edgePreservationEnabled: enabled,
            compressionCleanupEnabled:
                updated.effects.compressionCleanupEnabled,
            textureGrainProtectionEnabled:
                updated.effects.textureGrainProtectionEnabled,
            temporalStabilityEnabled:
                updated.effects.temporalStabilityEnabled
        )
        persistedDefaults = updated
        preferencesStore?.saveEdgePreservationEnabled(enabled)
        return true
    }

    @discardableResult
    func setDefaultCompressionCleanup(_ enabled: Bool) -> Bool {
        var updated = persistedDefaults
        updated.effects = UpscaleEffectConfiguration(
            edgePreservationEnabled:
                updated.effects.edgePreservationEnabled,
            compressionCleanupEnabled: enabled,
            textureGrainProtectionEnabled:
                updated.effects.textureGrainProtectionEnabled,
            temporalStabilityEnabled:
                updated.effects.temporalStabilityEnabled
        )
        persistedDefaults = updated
        preferencesStore?.saveCompressionCleanupEnabled(enabled)
        return true
    }

    @discardableResult
    func setDefaultTextureGrainProtection(_ enabled: Bool) -> Bool {
        var updated = persistedDefaults
        updated.effects = UpscaleEffectConfiguration(
            edgePreservationEnabled:
                updated.effects.edgePreservationEnabled,
            compressionCleanupEnabled:
                updated.effects.compressionCleanupEnabled,
            textureGrainProtectionEnabled: enabled,
            temporalStabilityEnabled:
                updated.effects.temporalStabilityEnabled
        )
        persistedDefaults = updated
        preferencesStore?.saveTextureGrainProtectionEnabled(enabled)
        return true
    }

    @discardableResult
    func setDefaultTemporalStability(_ enabled: Bool) -> Bool {
        var updated = persistedDefaults
        updated.effects = UpscaleEffectConfiguration(
            edgePreservationEnabled:
                updated.effects.edgePreservationEnabled,
            compressionCleanupEnabled:
                updated.effects.compressionCleanupEnabled,
            textureGrainProtectionEnabled:
                updated.effects.textureGrainProtectionEnabled,
            temporalStabilityEnabled: enabled
        )
        persistedDefaults = updated
        preferencesStore?.saveTemporalStabilityEnabled(enabled)
        return true
    }

    @discardableResult
    func selectModeForPendingJob(_ mode: UpscaleMode) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        selectedMode = mode
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func selectEngineForPendingJob(
        _ preference: UpscaleEnginePreference
    ) -> Bool {
        setSelectedEnginePreferences(
            [preference],
            persistsForFutureJobs: false
        )
    }

    @discardableResult
    func selectAutomaticRoutingForPendingJob() -> Bool {
        setSelectedEnginePreferences(
            [.automatic],
            persistsForFutureJobs: true
        )
    }

    @discardableResult
    func selectAllProcessingPathsForPendingJob() -> Bool {
        setSelectedEnginePreferences(
            UpscaleEnginePreference.concreteProcessingPaths,
            persistsForFutureJobs: true
        )
    }

    @discardableResult
    func toggleProcessingPathForPendingJob(
        _ path: UpscaleEnginePreference
    ) -> Bool {
        guard path != .automatic else {
            return selectAutomaticRoutingForPendingJob()
        }
        var requested = Set(selectedEnginePreferences)
        requested.remove(.automatic)
        if requested.contains(path) {
            guard requested.count > 1 else { return false }
            requested.remove(path)
        } else {
            requested.insert(path)
        }
        return setSelectedEnginePreferences(
            Array(requested),
            persistsForFutureJobs: true
        )
    }

    func processingPathIsSelected(
        _ path: UpscaleEnginePreference
    ) -> Bool {
        selectedEnginePreferences.contains(path)
    }

    private func setSelectedEnginePreferences(
        _ preferences: [UpscaleEnginePreference],
        persistsForFutureJobs: Bool
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        let normalized = UpscaleEnginePreference
            .normalizedProcessingPaths(
                preferences,
                fallback: enginePreference
            )
        selectedEnginePreferences = normalized
        enginePreference = normalized[0]
        updateDraftJobConfigurationFromCurrentSelections()
        if persistsForFutureJobs {
            persistedEnginePreferences = normalized
            preferencesStore?.saveEnginePreferences(normalized)
        }
        return true
    }

    @discardableResult
    func selectStrategyForPendingJob(
        _ preference: UpscaleStrategyPreference
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        strategyPreference = preference
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func setTemporalConsistencyForPendingJob(
        _ enabled: Bool
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        temporalConsistencyEnabled = enabled
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func selectEdgeFidelityForPendingJob(
        _ level: MirmirAdjustmentLevel
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        edgeFidelityLevel = level
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func selectDetailRecoveryForPendingJob(
        _ level: MirmirAdjustmentLevel
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        detailRecoveryLevel = level
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func selectSmoothMotionCadenceForPendingJob(
        _ cadence: SmoothMotionCadence
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        smoothMotionCadence = cadence
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func selectSmoothMotionSceneCutSensitivityForPendingJob(
        _ sensitivity: SmoothMotionSceneCutSensitivity
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        smoothMotionSceneCutSensitivity = sensitivity
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func setEdgePreservationForPendingJob(_ enabled: Bool) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        edgePreservationEnabled = enabled
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func setCompressionCleanupForPendingJob(_ enabled: Bool) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        compressionCleanupEnabled = enabled
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func setTextureGrainProtectionForPendingJob(
        _ enabled: Bool
    ) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        textureGrainProtectionEnabled = enabled
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func setTemporalStabilityForPendingJob(_ enabled: Bool) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        temporalStabilityEnabled = enabled
        updateDraftJobConfigurationFromCurrentSelections()
        return true
    }

    @discardableResult
    func selectCodecForPendingJob(_ outputCodec: OutputCodec) -> Bool {
        guard jobConfigurationIsEditable else { return false }
        codec = outputCodec
        updateDraftJobConfigurationFromCurrentSelections()
        let requiresQuickTimeMovie =
            sourceProfile.map {
                MediaOutputContainerPolicy
                    .preferredPathExtension(
                        codec: outputCodec,
                        videoFormat: $0.videoFormat,
                        preservationCapability:
                            $0.mediaPreservationCapability,
                        preserveAudio:
                            $0.hasAudio && preserveAudio,
                        preserveSubtitles: true,
                        preserveMetadata: true
                    ) == "mov"
            } ?? outputCodec.requiresQuickTimeMovieContainer
        if let outputURL,
           requiresQuickTimeMovie,
           outputURL.pathExtension.lowercased() != "mov" {
            let quickTimeURL = outputURL
                .deletingPathExtension()
                .appendingPathExtension("mov")
            self.outputURL = availableOutputURL(quickTimeURL)
        }
        if let outputURL {
            outputSelectionError = Self.outputContainerFailureReason(
                outputURL,
                codec: outputCodec,
                source: sourceProfile,
                preserveAudio:
                    sourceProfile?.hasAudio == true
                        && preserveAudio
            )
        }
        return true
    }

    var retrySameSettingsFailureReason: String? {
        guard case .failed = state else {
            return "Retry Same Settings is available after an upscale "
                + "attempt fails."
        }
        guard let retryableFailedJob else {
            if !recoveryReauthorizationRequiredIDs.isEmpty {
                return "Mirmir no longer has permission to reopen the "
                    + "interrupted source or output folder. Select "
                    + "Reauthorize for that interrupted job, choose both "
                    + "locations again, then resume it."
            }
            return "This failure has no restartable job. Dismiss it, choose "
                + "a source, and start a new upscale."
        }
        if recoveryIsProbing {
            return "Wait for interrupted-job recovery to finish, then retry."
        }
        if recoveryMutationIsInProgress {
            return "Wait for the interrupted-job update to finish, then "
                + "retry."
        }
        if let cacheLocationError {
            return "The cache location is unavailable: "
                + "\(cacheLocationError) Open Settings, choose an available "
                + "cache location, then retry."
        }

        let job = retryableFailedJob.job
        let source = retryableFailedJob.source
        if FileManager.default.fileExists(atPath: job.outputURL.path) {
            return Self.existingOutputConflictMessage
                + " Move or remove that file, then retry the same settings."
        }
        if FileURLIdentity.refersToSameFile(
            source.url,
            job.outputURL
        ) {
            return Self.sourceOutputConflictMessage
                + " Use Retry with Current Settings after choosing a "
                + "different destination."
        }
        if let reason = Self.outputContainerFailureReason(
            job.outputURL,
            codec: job.codec,
            source: source,
            preserveAudio:
                source.hasAudio && job.preserveAudio
        ) {
            return reason
                + " Choose a compatible destination and use Retry with "
                + "Current Settings."
        }
        if let reason = upscalerEngine.availability(
            for: job.mode
        ).unavailableReason {
            return "The saved \(job.mode.title) mode is unavailable: "
                + "\(reason) Choose an available mode or engine, then use "
                + "Retry with Current Settings."
        }
        guard Self.targets(for: source.resolution).contains(
            job.targetResolution
        ) else {
            return Self.retryGeometryFailureReason(
                source: source.resolution,
                target: job.targetResolution
            )
        }
        do {
            _ = try R13ReleaseJobContracts.scalePlan(
                source: source.resolution,
                target: job.targetResolution,
                strategyPreference:
                    job.processingConfiguration.strategyPreference
            )
        } catch {
            return Self.retryStrategyGeometryFailureReason
        }
        do {
            try R13ReleaseJobContracts.validateOutputCodec(
                job.codec,
                for: source.videoFormat
            )
        } catch {
            return "\(error) Choose a preserving codec, then use Retry "
                + "with Current Settings."
        }
        return nil
    }

    var canRetryFailedUpscale: Bool {
        retrySameSettingsFailureReason == nil
    }

    var retryWithCurrentSettingsFailureReason: String? {
        guard case .failed = state else {
            return "Retry with Current Settings is available after an "
                + "upscale attempt fails."
        }
        guard let failed = retryableFailedJob else {
            if !recoveryReauthorizationRequiredIDs.isEmpty {
                return "Mirmir no longer has permission to reopen the "
                    + "interrupted source or output folder. Select "
                    + "Reauthorize for that interrupted job, choose both "
                    + "locations again, then resume it."
            }
            return "This failure has no restartable job. Dismiss it, choose "
                + "a source, and start a new upscale."
        }
        if recoveryIsProbing {
            return "Wait for interrupted-job recovery to finish, then retry."
        }
        if recoveryMutationIsInProgress {
            return "Wait for the interrupted-job update to finish, then "
                + "retry."
        }
        if let cacheLocationError {
            return "The cache location is unavailable: "
                + "\(cacheLocationError) Open Settings, choose an available "
                + "cache location, then retry."
        }
        if let outputSelectionError {
            return "\(outputSelectionError) Choose a valid output "
                + "destination, then retry."
        }
        guard let destination = outputURL else {
            return "Choose an output destination, then retry."
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            return Self.existingOutputConflictMessage
        }
        if FileURLIdentity.refersToSameFile(
            failed.source.url,
            destination
        ) {
            return Self.sourceOutputConflictMessage
        }
        if let reason = Self.outputContainerFailureReason(
            destination,
            codec: codec,
            source: failed.source,
            preserveAudio:
                failed.source.hasAudio && preserveAudio
        ) {
            return reason
        }
        if let reason = upscalerEngine.availability(
            for: selectedMode
        ).unavailableReason {
            return "The selected \(selectedMode.title) mode is unavailable: "
                + "\(reason) Choose an available mode or engine, then retry."
        }
        guard Self.targets(for: failed.source.resolution).contains(
            targetResolution
        ) else {
            return Self.retryGeometryFailureReason(
                source: failed.source.resolution,
                target: targetResolution
            )
        }
        do {
            _ = try R13ReleaseJobContracts.scalePlan(
                source: failed.source.resolution,
                target: targetResolution,
                strategyPreference: strategyPreference
            )
        } catch {
            return Self.retryStrategyGeometryFailureReason
        }
        do {
            try R13ReleaseJobContracts.validateOutputCodec(
                codec,
                for: failed.source.videoFormat
            )
        } catch {
            return "\(error) Choose a preserving codec, then retry."
        }
        return nil
    }

    var canRetryFailedUpscaleWithCurrentSettings: Bool {
        retryWithCurrentSettingsFailureReason == nil
    }

    var retryCorrectiveActionText: String? {
        let sameSettings = retrySameSettingsFailureReason
        let currentSettings = retryWithCurrentSettingsFailureReason
        switch (sameSettings, currentSettings) {
        case (nil, nil):
            return nil
        case (let same?, let current?) where same == current:
            return same
        case (let same?, let current?):
            return "Retry Same Settings: \(same) Retry with Current "
                + "Settings: \(current)"
        case (let same?, nil):
            return "Retry Same Settings: \(same)"
        case (nil, let current?):
            return "Retry with Current Settings: \(current)"
        }
    }

    private static func retryGeometryFailureReason(
        source: VideoResolution,
        target: VideoResolution
    ) -> String {
        "The selected target \(fileLabel(for: target)) is not supported "
            + "for the \(fileLabel(for: source)) source. Choose a larger "
            + "supported target resolution, then retry."
    }

    private static var retryStrategyGeometryFailureReason: String {
        "The selected strategy cannot process this source and target "
            + "geometry. Choose Automatic or Adaptive strategy, or choose "
            + "a supported target resolution, then retry."
    }

    func recoveryRequiresReauthorization(id: String) -> Bool {
        recoveryReauthorizationRequiredIDs.contains(id)
    }

    func recoverableJobResumeFailureReason(id: String) -> String? {
        guard recoverableJobs.contains(where: { $0.id == id }) else {
            return "This interrupted job is no longer available. Refresh "
                + "the queue before trying again."
        }
        guard upscalerEngine is any R13RecoverableUpscalerEngine else {
            return "This engine cannot resume interrupted jobs. Start a new "
                + "upscale with an available release engine."
        }
        if recoveryRequiresReauthorization(id: id) {
            return "Mirmir no longer has permission to reopen this source "
                + "or output folder. Select Reauthorize, choose both "
                + "locations again, then resume."
        }
        if jobIsRunning {
            return "Wait for the active upscale to finish, then resume this "
                + "interrupted job."
        }
        if recoveryIsProbing {
            return "Wait for the current interrupted job to finish "
                + "reopening, then resume."
        }
        if recoveryMutationIsInProgress {
            return "Wait for the interrupted-job update to finish, then "
                + "resume."
        }
        return nil
    }

    static func targets(for resolution: VideoResolution) -> [VideoResolution] {
        guard resolution.width > 0,
              resolution.height > 0,
              resolution.height < 2_160 else {
            return []
        }
        return [720, 1_080, 1_440, 2_160].compactMap { targetHeight in
            guard targetHeight > resolution.height else { return nil }
            let halfWidth =
                Double(resolution.width) * Double(targetHeight)
                    / Double(resolution.height) / 2
            guard halfWidth.isFinite,
                  halfWidth >= 1,
                  halfWidth <= Double(Int.max / 2) else {
                return nil
            }
            return VideoResolution(
                width: Int(halfWidth.rounded()) * 2,
                height: targetHeight
            )
        }
    }

    static func supportsVideoFile(_ url: URL) -> Bool {
        url.isFileURL && !url.lastPathComponent.isEmpty
    }

    func adoptSystemSelectedSecurityScope(
        for url: URL
    ) -> MirmirSecurityScopedSelectionLease {
        MirmirSecurityScopedSelectionLease(
            url: url,
            access: securityScopedResourceAccess,
            acquisition: .adoptedSystemGrant
        )
    }

    func chooseSourceFile() {
        guard !jobIsRunning else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Select a video to upscale"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        acceptSourceURLSelectedByUser(url)
    }

    func acceptSourceURLSelectedByUser(_ url: URL) {
        loadSource(
            url: url,
            retaining: MirmirSecurityScopedSelectionLease(
                url: url,
                access: securityScopedResourceAccess,
                acquisition: .adoptedSystemGrant
            )
        )
    }

    func handleSourceDropProviderResult(
        url: URL?,
        errorDescription: String?
    ) {
        if let url {
            loadSource(url: url)
            return
        }

        guard !jobIsRunning,
              sourceProfile == nil,
              state != .probing else {
            return
        }

        let providerDetail = errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedProviderDetail = providerDetail.flatMap { detail in
            detail.isEmpty ? nil : String(detail.prefix(300))
        }
        var message =
            "Mirmir could not open the dropped video. Drop it again, or "
            + "select Choose Source and pick the file directly."
        if let boundedProviderDetail {
            message += " \(boundedProviderDetail)"
        }
        state = .failed(message)

        Task { [diagnosticRecorder] in
            diagnosticRecorder.enqueue(
                severity: .warning,
                subsystem: "workflow",
                operation: "source_drop",
                code: "source_drop_provider_failed"
            )
        }
    }

    func loadSource(url: URL) {
        loadSource(
            url: url,
            retaining: MirmirSecurityScopedSelectionLease(
                url: url,
                access: securityScopedResourceAccess,
                acquisition: .explicitStart
            )
        )
    }

    private func loadSource(
        url: URL,
        retaining sourceAccess: MirmirSecurityScopedSelectionLease
    ) {
        if let cancelledReadyJobSecurityAccess,
           cancelledReadyJobSecurityAccess.sourceURL.standardizedFileURL
            != url.standardizedFileURL {
            self.cancelledReadyJobSecurityAccess = nil
        }
        if pendingHistoryReprocess?.sourceURL != url {
            pendingHistoryReprocess = nil
        }
        let correlationID = UUID()
        let sourceResource = MirmirDiagnosticResourceInput(
            role: "source_video",
            url: url,
            location: .userSelected
        )
        guard !jobIsRunning else {
            pendingHistoryReprocess = nil
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
        sourceProbeGeneration &+= 1
        let probeGeneration = sourceProbeGeneration
        sourceProbeTask?.cancel()
        sourceProbeTask = nil
        cancelRecoveryProbe()
        resetPreview()
        retryableFailedJob = nil
        guard Self.supportsVideoFile(url) else {
            pendingHistoryReprocess = nil
            selectedSourceAccess = nil
            sourceProfile = nil
            preserveAudio = false
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

        selectedSourceAccess = sourceAccess
        applyDraftJobConfiguration()
        sourceProfile = nil
        preserveAudio = false
        clearOutputSelection()
        progress = nil
        state = .probing
        sourceProbeTask = Task {
            [weak self, diagnosticRecorder, sourceAccess] in
            defer {
                withExtendedLifetime(sourceAccess) {}
            }
            guard let self else { return }
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
                guard !Task.isCancelled,
                      sourceProbeGeneration == probeGeneration else {
                    return
                }
                sourceProfile = profile
                preserveAudio = profile.hasAudio
                codec = try Self.compatibleOutputCodec(
                    preferred: codec,
                    for: profile.videoFormat
                )
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
                    state = .failed(
                        unsupportedResolutionMessage(profile.resolution)
                    )
                    sourceProbeTask = nil
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
                if let pending = pendingHistoryReprocess,
                   pending.sourceURL == url {
                    guard Self.targets(for: profile.resolution).contains(
                        pending.record.targetResolution
                    ) else {
                        pendingHistoryReprocess = nil
                        state = .failed(
                            "The saved target is no longer supported for "
                                + "this source."
                        )
                        sourceProbeTask = nil
                        return
                    }
                    guard profile.videoFormat.supports(
                        outputCodec: pending.record.codec
                    ) else {
                        pendingHistoryReprocess = nil
                        state = .failed(
                            MediaPipelineError
                                .outputCodecCannotPreserveVideoFormat(
                                    codec: pending.record.codec,
                                    format: profile.videoFormat
                                )
                                .description
                        )
                        sourceProbeTask = nil
                        return
                    }
                    applyHistoryConfiguration(
                        pending.record,
                        source: profile,
                        outputDirectory:
                            pending.outputDirectoryURL,
                        outputDirectoryAccess:
                            pending.outputDirectoryAccess
                    )
                    pendingHistoryReprocess = nil
                } else {
                    targetResolution = firstTarget
                }
                state = .ready
                sourceProbeTask = nil
            } catch {
                guard !Task.isCancelled,
                      sourceProbeGeneration == probeGeneration else {
                    return
                }
                pendingHistoryReprocess = nil
                if selectedSourceAccess === sourceAccess {
                    selectedSourceAccess = nil
                }
                state = .failed(userFacingProbeError(error))
                sourceProbeTask = nil
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
        guard jobConfigurationIsEditable else { return nil }
        guard let source = sourceProfile else { return nil }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose Output Folder"
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder that Mirmir can use for atomic "
            + "output, recovery, and work history."
        panel.directoryURL = source.url.deletingLastPathComponent()
        let preferredExtension =
            MediaOutputContainerPolicy.preferredPathExtension(
                codec: codec,
                videoFormat: source.videoFormat,
                preservationCapability:
                    source.mediaPreservationCapability,
                preserveAudio:
                    source.hasAudio && preserveAudio,
                preserveSubtitles: true,
                preserveMetadata: true
            )
        let defaultFilename = availableDefaultOutputURL(
            for: source,
            target: targetResolution,
            in: panel.directoryURL
                ?? source.url.deletingLastPathComponent()
        ).lastPathComponent
        let filenameLabel = NSTextField(
            labelWithString: "Output file name"
        )
        let filenameField = NSTextField(string: defaultFilename)
        filenameField.placeholderString = defaultFilename
        filenameField.setAccessibilityLabel("Output file name")
        filenameField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 360
        ).isActive = true
        let accessory = NSStackView(
            views: [filenameLabel, filenameField]
        )
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK,
              let directoryURL = panel.url else {
            return nil
        }
        return acceptOutputDirectorySelectedByUser(
            directoryURL,
            requestedFilename: filenameField.stringValue,
            preferredPathExtension: preferredExtension
        )
    }

    @discardableResult
    func acceptOutputDirectorySelectedByUser(
        _ directoryURL: URL,
        requestedFilename: String,
        preferredPathExtension: String
    ) -> URL? {
        let access = MirmirSecurityScopedSelectionLease(
            url: directoryURL,
            access: securityScopedResourceAccess,
            acquisition: .adoptedSystemGrant
        )
        guard jobConfigurationIsEditable,
              let sourceProfile else {
            return nil
        }
        guard let url = Self.outputURL(
            in: directoryURL,
            requestedFilename: requestedFilename,
            preferredPathExtension: preferredPathExtension
        ) else {
            clearOutputSelection()
            outputSelectionError = "Enter one valid output file name."
            diagnosticRecorder.enqueue(
                severity: .warning,
                subsystem: "workflow",
                operation: "select_output",
                code: "output_selection_rejected_invalid_filename",
                source: sourceProfile
            )
            return nil
        }

        guard securityScopedResourceAccess.canCreateBookmark(
                  directoryURL
              ) else {
            clearOutputSelection()
            outputSelectionError = "Mirmir could not retain permission to "
                + "the selected output folder. Choose the folder again."
            diagnosticRecorder.enqueue(
                severity: .error,
                subsystem: "workflow",
                operation: "select_output",
                code: "output_directory_authorization_failed",
                source: sourceProfile,
                resources: [
                    MirmirDiagnosticResourceInput(
                        role: "output_directory",
                        url: directoryURL,
                        location: .userSelected
                    )
                ]
            )
            return nil
        }
        guard acceptOutputURLSelectedByUser(
            url,
            retaining: access
        ) else {
            return nil
        }
        return url
    }

    @discardableResult
    func acceptOutputURLSelectedByUser(_ url: URL) -> Bool {
        acceptOutputURLSelectedByUser(url, retaining: nil)
    }

    private func acceptOutputURLSelectedByUser(
        _ url: URL,
        retaining outputDirectoryAccess:
            MirmirSecurityScopedSelectionLease?
    ) -> Bool {
        let correlationID = UUID()
        let outputResource = MirmirDiagnosticResourceInput(
            role: "output_video",
            url: url,
            location: .userSelected
        )
        guard jobConfigurationIsEditable else {
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "select_output",
                    code: "output_selection_rejected_active_job",
                    correlationID: correlationID,
                    source: sourceProfile,
                    resources: [outputResource]
                )
            }
            return false
        }
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
        if let reason = Self.outputContainerFailureReason(
            url,
            codec: codec,
            source: sourceProfile,
            preserveAudio:
                sourceProfile.hasAudio && preserveAudio
        ) {
            clearOutputSelection()
            outputSelectionError = reason
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "select_output",
                    code:
                        "output_selection_rejected_unsupported_container",
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
        guard !FileManager.default.fileExists(atPath: url.path) else {
            clearOutputSelection()
            outputSelectionError = Self.existingOutputConflictMessage
            Task { [diagnosticRecorder] in
                diagnosticRecorder.enqueue(
                    severity: .warning,
                    subsystem: "workflow",
                    operation: "select_output",
                    code: "output_selection_rejected_existing_file",
                    correlationID: correlationID,
                    source: sourceProfile,
                    resources: [outputResource]
                )
            }
            return false
        }

        if let cancelledReadyJobSecurityAccess {
            cancelledReadyJobSecurityAccess
                .releaseOutputDirectoryIfReplaced(
                    by: url.deletingLastPathComponent()
                )
        }
        selectedOutputDirectoryAccess = outputDirectoryAccess
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

    static func outputURL(
        in directoryURL: URL,
        requestedFilename: String,
        preferredPathExtension: String
    ) -> URL? {
        guard directoryURL.isFileURL else { return nil }
        let filename = requestedFilename.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\0") else {
            return nil
        }
        let preferredExtension = preferredPathExtension.lowercased()
        guard preferredExtension == "mp4"
                || preferredExtension == "mov" else {
            return nil
        }
        let candidate = URL(
            fileURLWithPath: filename,
            isDirectory: false
        )
        let resolvedFilename = candidate.pathExtension.isEmpty
            ? filename + "." + preferredExtension
            : filename
        guard resolvedFilename.utf8.count <= 255,
              URL(fileURLWithPath: resolvedFilename)
                .lastPathComponent == resolvedFilename else {
            return nil
        }
        let outputURL = directoryURL.appendingPathComponent(
            resolvedFilename,
            isDirectory: false
        )
        guard outputURL.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL else {
            return nil
        }
        return outputURL
    }

    static func processingPathOutputURL(
        basedOn baseURL: URL,
        path: UpscaleEnginePreference
    ) -> URL {
        let directoryURL = baseURL.deletingLastPathComponent()
        let pathExtension = baseURL.pathExtension
        let extensionComponent = pathExtension.isEmpty
            ? ""
            : ".\(pathExtension)"
        let suffix = "_\(path.outputFilenameSuffix)"
        let maximumStemBytes = max(
            1,
            255 - suffix.utf8.count - extensionComponent.utf8.count
        )
        var stem = baseURL.deletingPathExtension().lastPathComponent
        while stem.utf8.count > maximumStemBytes, !stem.isEmpty {
            stem.removeLast()
        }
        if stem.isEmpty {
            stem = "mirmir"
        }
        return directoryURL.appendingPathComponent(
            stem + suffix + extensionComponent,
            isDirectory: false
        )
    }

    private static func outputContainerFailureReason(
        _ url: URL,
        codec: OutputCodec,
        source: SourceProfile?,
        preserveAudio: Bool
    ) -> String? {
        guard let source else {
            let pathExtension = url.pathExtension.lowercased()
            guard pathExtension == "mp4"
                    || pathExtension == "mov" else {
                return MediaPipelineError
                    .unsupportedOutputContainer(pathExtension)
                    .description
            }
            guard !codec.requiresQuickTimeMovieContainer
                    || pathExtension == "mov" else {
                return MediaPipelineError
                    .outputContainerCannotPreserveCodec(
                        pathExtension: pathExtension,
                        codec: codec
                    )
                    .description
            }
            return nil
        }
        return MediaOutputContainerPolicy.validationError(
            pathExtension: url.pathExtension,
            codec: codec,
            videoFormat: source.videoFormat,
            preservationCapability:
                source.mediaPreservationCapability,
            preserveAudio: preserveAudio,
            preserveSubtitles: true,
            preserveMetadata: true
        )?.description
    }

    private static func mediaPreservationFailureReason(
        _ source: SourceProfile,
        preserveAudio: Bool
    ) -> String? {
        source.mediaPreservationCapability.failureReason(
            preserveAudio: preserveAudio,
            preserveSubtitles: true,
            preserveMetadata: true
        )
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

        if selectedEnginePreferences.count > 1 {
            enqueueSelectedProcessingPathsAndStart(
                source: source,
                baseDestination: destination
            )
            return
        }

        let job = makeJob(
            source: source,
            destination: destination
        )
        submit(job: job, source: source)
    }

    private func enqueueSelectedProcessingPathsAndStart(
        source: SourceProfile,
        baseDestination: URL
    ) {
        guard let pendingWorkQueue else {
            pendingQueueError = "The persisted work queue is unavailable."
            return
        }
        let paths = UpscaleEnginePreference.normalizedProcessingPaths(
            selectedEnginePreferences,
            fallback: enginePreference
        )
        guard paths.count > 1,
              !paths.contains(.automatic) else {
            return
        }
        let configuredPaths = paths.map {
            (path: $0, configuration: processingConfiguration(for: $0))
        }
        beginPendingQueueMutation()
        pendingQueueError = nil
        let resolver = workHistoryBookmarkResolver
        let settings = (
            targetResolution: targetResolution,
            codec: codec,
            preserveAudio: source.hasAudio && preserveAudio,
            requestedMode: selectedMode
        )
        let outputDirectory = baseDestination.deletingLastPathComponent()
        let retainedSelectionAccesses = [
            selectedSourceAccess,
            selectedOutputDirectoryAccess
        ].compactMap { $0 }

        Task { [weak self, retainedSelectionAccesses] in
            guard let self else { return }
            var shouldStartQueue = false
            defer {
                withExtendedLifetime(retainedSelectionAccesses) {}
                endPendingQueueMutation()
                if shouldStartQueue {
                    Task { @MainActor [weak self] in
                        self?.startNextPendingWork()
                    }
                }
            }
            do {
                let sourceBookmark = try resolver.makeBookmark(
                    for: source.url,
                    role: .source
                )
                let outputBookmark = try resolver.makeBookmark(
                    for: outputDirectory,
                    role: .output
                )
                let createdAt = Date()
                let batchID = UUID().uuidString
                let records = configuredPaths.enumerated().map {
                    index, configuredPath in
                    let path = configuredPath.path
                    let identifier = UUID().uuidString
                    let output = Self.processingPathOutputURL(
                        basedOn: baseDestination,
                        path: path
                    )
                    return MirmirPendingWorkRecord(
                        id: identifier,
                        bookmarks: MirmirPendingWorkBookmarks(
                            sourceBookmark: sourceBookmark,
                            outputBookmark: outputBookmark,
                            sourceDisplayName:
                                source.url.lastPathComponent,
                            outputDisplayName:
                                output.lastPathComponent
                        ),
                        settings: MirmirPendingWorkSettings(
                            targetResolution: settings.targetResolution,
                            codec: settings.codec,
                            preserveAudio: settings.preserveAudio,
                            requestedMode: settings.requestedMode,
                            processingConfiguration:
                                configuredPath.configuration,
                            continuesAfterFailure: true,
                            processingPathBatch:
                                MirmirProcessingPathBatchContext(
                                    id: batchID,
                                    path: path,
                                    ordinal: index,
                                    totalCount: configuredPaths.count
                                )
                        ),
                        createdAt: createdAt,
                        order: index
                    )
                }
                let snapshot = try await pendingWorkQueue.enqueueMany(
                    records
                )
                applyPendingQueueSnapshot(snapshot)
                shouldStartQueue = true
            } catch {
                pendingQueueError = Self.historyErrorDescription(error)
            }
        }
    }

    func submit(
        job: UpscaleJob,
        source: SourceProfile,
        retainedSecurityAccess explicitRetainedSecurityAccess:
            RetainedJobSecurityAccess? = nil
    ) {
        let cancelledReadyRetainedAccess =
            cancelledReadyJobSecurityAccess?
                .retainedAccess(for: job)
        let activeQueueRetainedAccess =
            activePendingQueueJobID == job.identifier
            ? activePendingQueueSecurityAccess.map {
                RetainedJobSecurityAccess(pendingQueue: $0)
            }
            : nil
        let effectiveRetainedSecurityAccess =
            explicitRetainedSecurityAccess
            ?? activeQueueRetainedAccess
            ?? cancelledReadyRetainedAccess
            ?? RetainedJobSecurityAccess()
        resetPreview()
        retryableFailedJob = nil
        terminalJobSecurityAccess = nil
        cancelledReadyJobSecurityAccess = nil
        pendingHistoryReprocess = nil
        completedOutputRevealError = nil
        jobTimingByIdentifier[job.identifier] = (
            createdAt: Date(),
            startedAt: nil
        )
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
            if let timing = jobTimingByIdentifier[job.identifier] {
                jobTimingByIdentifier[job.identifier] = (
                    createdAt: timing.createdAt,
                    startedAt: Date()
                )
            }
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
            observeSubmittedJob(
                job: job,
                source: source,
                handle: handle,
                retainedSecurityAccess: effectiveRetainedSecurityAccess
            )
        } catch {
            let failureReason = userFacingJobError(error)
            retryableFailedJob = RetryableFailedJob(
                job: job,
                source: source,
                retainedSecurityAccess: effectiveRetainedSecurityAccess
            )
            state = .failed(failureReason)
            persistWorkHistory(
                job: job,
                source: source,
                terminalResult: .failed,
                retainedSecurityAccess: effectiveRetainedSecurityAccess
            )
            completeActivePendingQueueJob(
                id: job.identifier,
                status: .failed,
                reason: failureReason,
                shouldAdvance:
                    shouldAdvancePendingQueueAfterFailure(
                        jobID: job.identifier
                    )
            )
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
        handle: UpscalerJobHandle,
        retainedSecurityAccess: RetainedJobSecurityAccess =
            RetainedJobSecurityAccess(),
        restoringPendingQueueOwnership: Bool = false
    ) {
        cancelledReadyJobSecurityAccess = nil
        if restoringPendingQueueOwnership {
            activePendingQueueJobID = job.identifier
        }
        let retainedSourceAccess = selectedSourceAccess.flatMap { access in
            access.url.standardizedFileURL
                == job.inputURL.standardizedFileURL ? access : nil
        }
        let retainedOutputDirectoryAccess =
            selectedOutputDirectoryAccess.flatMap { access in
                access.url.standardizedFileURL
                    == job.outputURL.deletingLastPathComponent()
                        .standardizedFileURL ? access : nil
            }
        jobHandle = handle
        retryableFailedJob = nil
        terminalJobSecurityAccess = nil
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
        progressTask = Task {
            [
                weak self,
                retainedSourceAccess,
                retainedOutputDirectoryAccess,
                retainedSecurityAccess
            ] in
            defer {
                withExtendedLifetime(retainedSourceAccess) {}
                withExtendedLifetime(retainedOutputDirectoryAccess) {}
                withExtendedLifetime(retainedSecurityAccess) {}
            }
            guard let self else { return }
            await self.observeJobCompletion(
                job: job,
                source: source,
                handle: handle,
                retainedOutputDirectoryAccess:
                    retainedOutputDirectoryAccess,
                retainedSecurityAccess: retainedSecurityAccess
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
        handle: UpscalerJobHandle,
        retainedOutputDirectoryAccess:
            MirmirSecurityScopedSelectionLease?,
        retainedSecurityAccess: RetainedJobSecurityAccess
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
            terminalJobSecurityAccess = retainedSecurityAccess
            outputURL = url
            outputSelectionError = nil
            completedOutputRevealError = nil
            state = .finished(url)
            persistWorkHistory(
                job: job,
                source: source,
                terminalResult: .completed,
                retaining: retainedOutputDirectoryAccess,
                retainedSecurityAccess: retainedSecurityAccess
            )
            completeActivePendingQueueJob(
                id: job.identifier,
                status: .completed,
                shouldAdvance: true
            )
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
            applyCancelledJobTerminalState(
                job: job,
                source: source,
                retaining: retainedOutputDirectoryAccess,
                retainedSecurityAccess: retainedSecurityAccess
            )
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
                applyCancelledJobTerminalState(
                    job: job,
                    source: source,
                    retaining: retainedOutputDirectoryAccess,
                    retainedSecurityAccess: retainedSecurityAccess
                )
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
                error: engineError,
                retaining: retainedOutputDirectoryAccess,
                retainedSecurityAccess: retainedSecurityAccess
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
                error: error,
                retaining: retainedOutputDirectoryAccess,
                retainedSecurityAccess: retainedSecurityAccess
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

    private func applyCancelledJobTerminalState(
        job: UpscaleJob,
        source: SourceProfile,
        retaining outputDirectoryAccess:
            MirmirSecurityScopedSelectionLease?,
        retainedSecurityAccess: RetainedJobSecurityAccess
    ) {
        let shouldRemainReady = jobIsRunning
        jobHandle = nil
        progressTask = nil
        retryableFailedJob = nil
        terminalJobSecurityAccess = nil
        if shouldRemainReady {
            cancelledReadyJobSecurityAccess =
                CancelledReadyJobSecurityAccess(
                    sourceURL: job.inputURL,
                    outputDirectoryURL:
                        job.outputURL.deletingLastPathComponent(),
                    retainedAccess: retainedSecurityAccess
                )
            state = .ready
        } else {
            cancelledReadyJobSecurityAccess = nil
        }
        loadRecoverableJobs()
        refreshReleaseDiagnostics()
        persistWorkHistory(
            job: job,
            source: source,
            terminalResult: .cancelled,
            retaining: outputDirectoryAccess,
            retainedSecurityAccess: retainedSecurityAccess
        )
        completeActivePendingQueueJob(
            id: job.identifier,
            status: .cancelled,
            shouldAdvance: false
        )
    }

    private func shouldAdvancePendingQueueAfterFailure(
        jobID: String
    ) -> Bool {
        pendingWorkRecords.first { $0.id == jobID }?
            .settings.continuesAfterFailure == true
    }

    private func applyFailedJobTerminalState(
        job: UpscaleJob,
        source: SourceProfile,
        error: Error,
        retaining outputDirectoryAccess:
            MirmirSecurityScopedSelectionLease?,
        retainedSecurityAccess: RetainedJobSecurityAccess
    ) {
        guard !Task.isCancelled else { return }
        jobHandle = nil
        progressTask = nil
        terminalJobSecurityAccess = nil
        retryableFailedJob = RetryableFailedJob(
            job: job,
            source: source,
            retainedSecurityAccess: retainedSecurityAccess
        )
        let failureReason = userFacingJobError(error)
        state = .failed(failureReason)
        persistWorkHistory(
            job: job,
            source: source,
            terminalResult: .failed,
            retaining: outputDirectoryAccess,
            retainedSecurityAccess: retainedSecurityAccess
        )
        completeActivePendingQueueJob(
            id: job.identifier,
            status: .failed,
            reason: failureReason,
            shouldAdvance:
                shouldAdvancePendingQueueAfterFailure(
                    jobID: job.identifier
                )
        )
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
        restoreCurrentConfiguration(from: retryableFailedJob.job)
        progress = nil
        state = .ready
        submit(
            job: retryableFailedJob.job,
            source: retryableFailedJob.source,
            retainedSecurityAccess:
                retryableFailedJob.retainedSecurityAccess
        )
    }

    func retryFailedUpscaleWithCurrentSettings() {
        guard canRetryFailedUpscaleWithCurrentSettings,
              let failed = retryableFailedJob,
              let destination = outputURL else {
            return
        }
        let job = makeJob(
            source: failed.source,
            destination: destination
        )
        sourceProfile = failed.source
        progress = nil
        state = .ready
        submit(
            job: job,
            source: failed.source,
            retainedSecurityAccess: failed.retainedSecurityAccess
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

    private func makeJob(
        source: SourceProfile,
        destination: URL
    ) -> UpscaleJob {
        UpscaleJob(
            inputURL: source.url,
            outputURL: destination,
            targetResolution: targetResolution,
            codec: codec,
            preserveAudio: source.hasAudio && preserveAudio,
            mode: selectedMode,
            processingConfiguration: currentProcessingConfiguration
        )
    }

    private func persistWorkHistory(
        job: UpscaleJob,
        source: SourceProfile,
        terminalResult: MirmirWorkTerminalResult,
        retaining outputDirectoryAccess:
            MirmirSecurityScopedSelectionLease? = nil,
        retainedSecurityAccess: RetainedJobSecurityAccess =
            RetainedJobSecurityAccess()
    ) {
        guard let workHistoryStore else { return }
        let completedAt = Date()
        let timing = jobTimingByIdentifier.removeValue(
            forKey: job.identifier
        ) ?? (createdAt: completedAt, startedAt: nil)
        let resolver = workHistoryBookmarkResolver
        let measurer = workHistoryOutputIdentityMeasurer
        let diagnosticRecorder = diagnosticRecorder
        let securityAccess = securityScopedResourceAccess
        let sourceBookmark: Data
        let outputDirectoryBookmark: Data
        do {
            sourceBookmark = try resolver.makeBookmark(
                for: job.inputURL,
                role: .source
            )
            outputDirectoryBookmark = try resolver.makeBookmark(
                for: job.outputURL.deletingLastPathComponent(),
                role: .output
            )
            withExtendedLifetime(retainedSecurityAccess) {}
        } catch {
            workHistoryError = Self.historyErrorDescription(error)
            diagnosticRecorder.enqueue(
                severity: .error,
                subsystem: "work_history",
                operation: "capture_terminal_permissions",
                code: "work_history_bookmark_capture_failed",
                job: job,
                source: source,
                error: error
            )
            return
        }

        let asynchronouslyRetainedOutputDirectoryAccess =
            terminalResult == .cancelled
            ? nil
            : outputDirectoryAccess
        let asynchronouslyRetainedSecurityAccess =
            terminalResult == .cancelled
            ? RetainedJobSecurityAccess()
            : retainedSecurityAccess

        Task {
            [
                weak self,
                outputDirectoryAccess =
                    asynchronouslyRetainedOutputDirectoryAccess,
                retainedSecurityAccess =
                    asynchronouslyRetainedSecurityAccess,
                securityAccess
            ] in
            defer {
                withExtendedLifetime(outputDirectoryAccess) {}
                withExtendedLifetime(retainedSecurityAccess) {}
            }
            do {
                let snapshot = try await Task.detached {
                    let verification: MirmirWorkOutputVerification
                    if terminalResult == .completed {
                        let outputIdentity = try measurer.measureSource(
                            at: job.outputURL
                        )
                        verification = .available(
                            identity: outputIdentity.sha256
                        )
                    } else {
                        verification = .unavailable
                    }
                    let record = MirmirWorkHistoryRecord(
                        id: job.identifier,
                        sourceBookmark: sourceBookmark,
                        outputBookmark: outputDirectoryBookmark,
                        outputBookmarkScope: .directory,
                        sourceDisplayName:
                            job.inputURL.lastPathComponent,
                        outputDisplayName:
                            job.outputURL.lastPathComponent,
                        sourceResolution: source.resolution,
                        targetResolution: job.targetResolution,
                        codec: job.codec,
                        sourceAudioTrackCount:
                            source.audioTrackCount,
                        sourceScanStructure:
                            source.scanStructure,
                        preserveAudio: job.preserveAudio,
                        requestedMode: job.mode,
                        processingConfiguration:
                            job.processingConfiguration,
                        createdAt: timing.createdAt,
                        startedAt: timing.startedAt,
                        completedAt: completedAt,
                        terminalResult: terminalResult,
                        outputVerification: verification
                    )
                    return try await workHistoryStore.upsert(record)
                }.value
                let locationStates = await workHistoryStore.bookmarkStates(
                    records: snapshot.records,
                    resolver: resolver,
                    securityScopedResourceAccess:
                        securityAccess
                )
                guard let self else { return }
                applyWorkHistorySnapshot(
                    snapshot,
                    locationStates: locationStates
                )
                workHistoryError = nil
            } catch {
                guard let self else { return }
                workHistoryError = Self.historyErrorDescription(error)
                diagnosticRecorder.enqueue(
                    severity: .error,
                    subsystem: "work_history",
                    operation: "persist_terminal_job",
                    code: "work_history_persistence_failed",
                    job: job,
                    source: source,
                    error: error
                )
            }
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
        guard let completedOutputURL else {
            completedOutputRevealError =
                "No completed output is available to reveal."
            return
        }
        let isRegularFile =
            (
                try? completedOutputURL.resourceValues(
                    forKeys: [.isRegularFileKey]
                ).isRegularFile
            ) == true
        guard completedOutputURL.isFileURL,
              isRegularFile else {
            completedOutputRevealError =
                "The completed output “"
                + completedOutputURL.lastPathComponent
                + "” is no longer available at its published location. "
                + "Restore it there and choose Reveal Output again, or "
                + "open Library to reauthorize or reprocess the job."
            diagnosticRecorder.enqueue(
                severity: .warning,
                subsystem: "workflow",
                operation: "reveal_output",
                code: "completed_output_unavailable",
                resources: [
                    MirmirDiagnosticResourceInput(
                        role: "completed_output",
                        url: completedOutputURL,
                        location: .userSelected
                    )
                ]
            )
            return
        }
        completedOutputRevealError = nil
        revealFileInFinder(completedOutputURL)
    }

    func upscaleAnotherVideo() {
        cancelRecoveryProbe()
        sourceProbeGeneration &+= 1
        sourceProbeTask?.cancel()
        sourceProbeTask = nil
        jobHandle?.cancel()
        jobHandle = nil
        progressTask?.cancel()
        progressTask = nil
        resetPreview()
        retryableFailedJob = nil
        terminalJobSecurityAccess = nil
        cancelledReadyJobSecurityAccess = nil
        pendingHistoryReprocess = nil
        completedOutputRevealError = nil
        selectedSourceAccess = nil
        sourceProfile = nil
        preserveAudio = false
        seedFreshDraftFromPersistedDefaults()
        clearOutputSelection()
        progress = nil
        state = .idle
    }

    func restoreCurrentConfiguration(from job: UpscaleJob) {
        targetResolution = job.targetResolution
        codec = job.codec
        preserveAudio = job.preserveAudio
        selectedMode = job.mode
        selectedEnginePreferences = [
            job.processingConfiguration.enginePreference
        ]
        enginePreference =
            job.processingConfiguration.enginePreference
        strategyPreference =
            job.processingConfiguration.strategyPreference
        temporalConsistencyEnabled =
            job.processingConfiguration.temporalConsistencyEnabled
        edgeFidelityLevel =
            job.processingConfiguration.edgeFidelityLevel
        detailRecoveryLevel =
            job.processingConfiguration.detailRecoveryLevel
        edgePreservationEnabled =
            job.processingConfiguration.effects.edgePreservationEnabled
        compressionCleanupEnabled =
            job.processingConfiguration.effects.compressionCleanupEnabled
        textureGrainProtectionEnabled =
            job.processingConfiguration.effects
                .textureGrainProtectionEnabled
        temporalStabilityEnabled =
            job.processingConfiguration.effects.temporalStabilityEnabled
        smoothMotionCadence =
            job.processingConfiguration.smoothMotion.cadence
        smoothMotionSceneCutSensitivity =
            job.processingConfiguration.smoothMotion
                .sceneCutSensitivity
        outputURL = job.outputURL
        outputSelectionError = nil
    }

    private func updateDraftJobConfigurationFromCurrentSelections() {
        draftJobConfiguration = MirmirDraftJobConfiguration(
            mode: selectedMode,
            outputCodec: codec,
            processingConfiguration: currentProcessingConfiguration
        )
    }

    private func applyDraftJobConfiguration() {
        selectedMode = draftJobConfiguration.mode
        codec = draftJobConfiguration.outputCodec
        applyProcessingConfiguration(
            draftJobConfiguration.processingConfiguration
        )
    }

    private func seedFreshDraftFromPersistedDefaults() {
        draftJobConfiguration = MirmirDraftJobConfiguration(
            defaults: persistedDefaults
        )
        applyDraftJobConfiguration()
        selectedEnginePreferences = UpscaleEnginePreference
            .normalizedProcessingPaths(
                persistedEnginePreferences,
                fallback: persistedDefaults.enginePreference
            )
        enginePreference = selectedEnginePreferences[0]
        updateDraftJobConfigurationFromCurrentSelections()
    }

    private func applyHistoryConfiguration(
        _ record: MirmirWorkHistoryRecord,
        source: SourceProfile,
        outputDirectory: URL,
        outputDirectoryAccess:
            MirmirSecurityScopedSelectionLease
    ) {
        targetResolution = record.targetResolution
        codec = record.codec
        preserveAudio = source.hasAudio && record.preserveAudio
        selectedMode = record.requestedMode
        selectedEnginePreferences = [
            record.processingConfiguration.enginePreference
        ]
        enginePreference =
            record.processingConfiguration.enginePreference
        strategyPreference =
            record.processingConfiguration.strategyPreference
        temporalConsistencyEnabled =
            record.processingConfiguration.temporalConsistencyEnabled
        edgeFidelityLevel =
            record.processingConfiguration.edgeFidelityLevel
        detailRecoveryLevel =
            record.processingConfiguration.detailRecoveryLevel
        edgePreservationEnabled =
            record.processingConfiguration.effects
                .edgePreservationEnabled
        compressionCleanupEnabled =
            record.processingConfiguration.effects
                .compressionCleanupEnabled
        textureGrainProtectionEnabled =
            record.processingConfiguration.effects
                .textureGrainProtectionEnabled
        temporalStabilityEnabled =
            record.processingConfiguration.effects
                .temporalStabilityEnabled
        smoothMotionCadence =
            record.processingConfiguration.smoothMotion.cadence
        smoothMotionSceneCutSensitivity =
            record.processingConfiguration.smoothMotion
                .sceneCutSensitivity
        outputURL = reprocessedOutputURL(
            originalName: record.outputDisplayName,
            directory: outputDirectory,
            codec: record.codec,
            source: source,
            preserveAudio:
                source.hasAudio && record.preserveAudio
        )
        selectedOutputDirectoryAccess = outputDirectoryAccess
        outputSelectionError = nil
    }

    private func reprocessedOutputURL(
        originalName: String,
        directory: URL,
        codec: OutputCodec,
        source: SourceProfile,
        preserveAudio: Bool
    ) -> URL {
        let original = URL(fileURLWithPath: originalName)
        let originalExtension = original.pathExtension.lowercased()
        let preferredExtension =
            MediaOutputContainerPolicy.preferredPathExtension(
                codec: codec,
                videoFormat: source.videoFormat,
                preservationCapability:
                    source.mediaPreservationCapability,
                preserveAudio: preserveAudio,
                preserveSubtitles: true,
                preserveMetadata: true
            )
        let pathExtension: String
        if preferredExtension == "mov" {
            pathExtension = "mov"
        } else if originalExtension == "mp4"
                    || originalExtension == "mov" {
            pathExtension = originalExtension
        } else {
            pathExtension = "mp4"
        }
        let stem = original.deletingPathExtension().lastPathComponent
        let suffix = UUID().uuidString
            .prefix(8)
            .lowercased()
        return directory.appendingPathComponent(
            "\(stem)_reprocessed_\(suffix).\(pathExtension)",
            isDirectory: false
        )
    }

    private static func compatibleOutputCodec(
        preferred: OutputCodec,
        for videoFormat: MediaVideoFormat
    ) throws -> OutputCodec {
        if videoFormat.supports(outputCodec: preferred) {
            return preferred
        }
        guard let fallback = videoFormat.supportedOutputCodecs.first else {
            throw MediaPipelineError.unsupportedVideoFormat(
                "the source format has no preserving output codec"
            )
        }
        return fallback
    }

    func ensureModelsReady() {
        guard modelAssetsBinding.requiresConfigurationModel else {
            return
        }
        switch modelStatus {
        case .downloadRequired, .failed:
            break
        case .unknown, .notRequired, .downloading, .ready:
            return
        }

        let requestedBinding = modelAssetsBinding
        modelPreparationTask?.cancel()
        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if modelAssetsBinding == requestedBinding {
                    modelPreparationTask = nil
                }
            }
            do {
                try await modelAssets.ensureReady(for: .video)
            } catch is CancellationError {
                return
            } catch ModelAssetsServiceError.configurationChanged {
                return
            } catch {
                guard modelAssetsBinding == requestedBinding else {
                    return
                }
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

    private func synchronizeModelAssetsRoute() {
        modelPreparationTask?.cancel()
        modelPreparationTask = nil

        let binding: ModelAssetsRouteBinding
        guard let sourceProfile,
              availableTargets.contains(targetResolution) else {
            binding = .unresolved
            modelAssetsBinding = binding
            (modelAssets as? any ModelAssetsRouteBindingService)?
                .bind(binding, for: .video)
            return
        }
        let sourceResolution = sourceProfile.resolution
        let modelBindingEnginePreference =
            selectedEnginePreferences.contains(.videoToolboxQuality)
                ? UpscaleEnginePreference.videoToolboxQuality
                : enginePreference

        if sourceProfile.videoFormat == .sdrBT709,
           #available(macOS 26.0, *),
           let nativeBinding =
                R13ReleaseModePolicy.nativeVideoToolboxBinding(
                    for: selectedMode,
                    enginePreference: modelBindingEnginePreference,
                    sourceResolution: sourceResolution,
                    targetResolution: targetResolution
                ) {
            if nativeBinding.requiresConfigurationModel {
                binding = .videoToolboxQuality(nativeBinding)
            } else {
                binding = .notRequired(
                    routeID: nativeBinding.subjectID.rawValue
                )
            }
        } else {
            let policy = R13ReleaseModePolicy.binding(
                for: selectedMode,
                enginePreference: enginePreference
            ).resolving(videoFormat: sourceProfile.videoFormat)
            let routeID =
                "\(policy.backendID)."
                + "\(sourceResolution.width)x"
                + "\(sourceResolution.height)-to-"
                + "\(targetResolution.width)x"
                + "\(targetResolution.height)."
                + "\(policy.executionFormat.identityComponent)"
            binding = .notRequired(routeID: routeID)
        }

        modelAssetsBinding = binding
        (modelAssets as? any ModelAssetsRouteBindingService)?
            .bind(binding, for: .video)
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
