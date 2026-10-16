import AppKit
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers
import VideoToolbox

typealias SuperResolutionScaleProvider = @Sendable (
    UpscaleBackendID,
    Int,
    Int
) -> [Int]

struct BackendSelectionTargetAdjustment: Equatable, Sendable {
    let backendID: UpscaleBackendID
    let sourceURL: URL?
    let sourceWidth: Int
    let sourceHeight: Int
    let currentTargetWidth: Int
    let currentTargetHeight: Int
    let proposedTargetWidth: Int
    let proposedTargetHeight: Int
    let proposedScaleFactor: Int
    let supportedScaleFactors: [Int]

    var alertTitle: String {
        "Change target for Apple Super Resolution?"
    }

    var confirmationTitle: String {
        sourceURL == nil
            ? "Use \(proposedScaleFactor)× & Select"
            : "Change Target & Select"
    }

    var message: String {
        let supported = supportedScaleFactors
            .map { "\($0)×" }
            .joined(separator: supportedScaleFactors.count == 2 ? " and " : ", ")
        if sourceURL == nil {
            return "This Mac reports \(supported) for VideoToolbox Quality. "
                + "Mirmir normally starts each loaded video at 2×, which this "
                + "method does not support here. Selecting Quality will use a "
                + "\(proposedScaleFactor)× target after you choose a source. "
                + "Apple may also require its quality model to be downloaded "
                + "before processing."
        }
        let currentScale: String
        if currentTargetWidth.isMultiple(of: sourceWidth),
           currentTargetHeight.isMultiple(of: sourceHeight),
           currentTargetWidth / sourceWidth == currentTargetHeight / sourceHeight {
            currentScale = "\(currentTargetWidth / sourceWidth)×"
        } else {
            currentScale = "custom"
        }
        let dimensions = "\(currentTargetWidth) × \(currentTargetHeight) to "
            + "\(proposedTargetWidth) × \(proposedTargetHeight)"

        switch backendID {
        case .videoToolboxSuperResolutionQuality:
            return "This Mac reports \(supported) for VideoToolbox Quality. "
                + "The current \(currentScale) target is not supported. "
                + "Selecting Quality will change the target from \(dimensions). "
                + "Apple may also require its quality model to be downloaded "
                + "before processing."
        case .videoToolboxSuperResolutionLowLatency:
            return "This Mac reports \(supported) for VideoToolbox Low Latency. "
                + "The current \(currentScale) target is not supported. "
                + "Selecting Low Latency will change the target from \(dimensions) "
                + "so VideoToolbox can create an exact output."
        default:
            return "Selecting this method will change the target from \(dimensions)."
        }
    }
}

private extension UpscaleBackendID {
    var isDeterministicV4: Bool {
        self == .mirmirDeterministicCPU
            || self == .mirmirDeterministicMetal
    }
}

private enum LiveSuperResolutionScaleSupport {
    static let provider: SuperResolutionScaleProvider = {
        backendID,
        sourceWidth,
        sourceHeight in
        scaleFactors(
            for: backendID,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }

    static func scaleFactors(
        for backendID: UpscaleBackendID,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> [Int] {
        guard #available(macOS 26.0, *) else { return [] }
        let factors: [Int]
        switch backendID {
        case .videoToolboxSuperResolutionQuality:
            factors = VTSuperResolutionScalerConfiguration.supportedScaleFactors
        case .videoToolboxSuperResolutionLowLatency:
            factors = VTLowLatencySuperResolutionScalerConfiguration
                .supportedScaleFactors(
                    frameWidth: sourceWidth,
                    frameHeight: sourceHeight
                )
                .compactMap { value in
                    let rounded = Int(value.rounded())
                    return abs(value - Float(rounded)) <= 0.000_001
                        ? rounded
                        : nil
                }
        default:
            factors = []
        }
        return Array(Set(factors.filter { $0 > 1 })).sorted()
    }
}

@MainActor
@Observable
final class MirmirViewModel {
    private(set) var state: AppState = .empty
    private(set) var currentVideoInfo: VideoInfo?
    private(set) var selectedBackendID: UpscaleBackendID = .automatic
    private(set) var backendSnapshot: BackendCatalogSnapshot?
    private(set) var backendTargetSize: CGSize?
    private(set) var backendAvailabilityMessage: String?
    private(set) var isCheckingBackendAvailability = false
    private(set) var targetWidth = 0
    private(set) var targetHeight = 0
    private(set) var outputURL: URL?
    private(set) var outputCodec: OutputCodec = .hevc
    private(set) var preserveAudio = true
    private(set) var overwriteExistingFile = false
    private(set) var isDownloadingModel = false
    private(set) var modelDownloadProgress: Double?
    private(set) var modelDownloadMessage: String?
    private(set) var workflowQueueSnapshot:
        WorkflowApplicationQueueSnapshotV4?
    private(set) var workflowRecoverySnapshot:
        WorkflowLaunchRecoverySnapshotV4?
    private(set) var workflowErrorMessage: String?
    private(set) var isInitializingWorkflow = false
    private(set) var isWorkflowProcessing = false
    private(set) var isEnqueueingWorkflow = false
    private(set) var cacheLocationPath = "Loading cache location…"
    private(set) var cacheLocationIsCustom = false
    private(set) var cacheLocationErrorMessage: String?
    private(set) var cacheOperationStatusMessage: String?
    private(set) var isManagingCache = false

    @ObservationIgnored private let videoProbe: any VideoProbing
    @ObservationIgnored private let backendCatalog: UpscaleBackendCatalog
    @ObservationIgnored private let runtimeEnvironment: RuntimeEnvironment
    @ObservationIgnored private let coordinator: UpscaleCoordinator
    @ObservationIgnored private let superResolutionScaleProvider:
        SuperResolutionScaleProvider
    @ObservationIgnored private var workflowController:
        (any WorkflowApplicationControllingV4)?
    @ObservationIgnored private var hasInitializedWorkflow = false
    @ObservationIgnored private let cacheLocationStore:
        WorkflowCacheLocationStoreV4?
    @ObservationIgnored private let usesInjectedWorkflowController: Bool
    @ObservationIgnored let diagnosticStore: MirmirDiagnosticStore
    @ObservationIgnored private let diagnosticRecorder:
        MirmirDiagnosticRecorder
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var backendAvailabilityTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var isForegroundWorkflowProcessing = false
    @ObservationIgnored private var modelDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var activeModelDownloadID: UUID?
    @ObservationIgnored private var activeProbeID: UUID?
    @ObservationIgnored private var activeBackendAvailabilityID: UUID?
    @ObservationIgnored private var scopedInputAccess: SecurityScopedAccess?
    @ObservationIgnored private var scopedOutputAccess: SecurityScopedAccess?
    @ObservationIgnored private var sourceAspectRatio: Double?
    @ObservationIgnored private var preferredInitialScaleFactor: Int?

    init(
        videoProbe: any VideoProbing = VideoProbe(),
        backendCatalog: UpscaleBackendCatalog = .live(),
        runtimeEnvironment: RuntimeEnvironment = .current(),
        coordinator: UpscaleCoordinator? = nil,
        superResolutionScaleProvider: SuperResolutionScaleProvider? = nil,
        workflowController:
            (any WorkflowApplicationControllingV4)? = nil,
        cacheLocationStore: WorkflowCacheLocationStoreV4? = nil,
        cacheLocationStoreFactory: (String) throws
            -> WorkflowCacheLocationStoreV4 = {
                try WorkflowCacheLocationStoreV4(
                    applicationIdentifier: $0
                )
            },
        diagnosticStore: MirmirDiagnosticStore = .application
    ) {
        self.videoProbe = videoProbe
        self.diagnosticStore = diagnosticStore
        self.diagnosticRecorder = MirmirDiagnosticRecorder(
            store: diagnosticStore
        )
        self.backendCatalog = backendCatalog
        self.runtimeEnvironment = runtimeEnvironment
        self.superResolutionScaleProvider = superResolutionScaleProvider
            ?? LiveSuperResolutionScaleSupport.provider
        self.coordinator = coordinator ?? UpscaleCoordinator(
            videoProbe: videoProbe,
            backendCatalog: backendCatalog,
            runtimeEnvironment: runtimeEnvironment
        )
        usesInjectedWorkflowController = workflowController != nil
        let resolvedCacheStore: WorkflowCacheLocationStoreV4?
        let cacheStoreInitializationError: Error?
        if let cacheLocationStore {
            resolvedCacheStore = cacheLocationStore
            cacheStoreInitializationError = nil
        } else if workflowController == nil {
            do {
                resolvedCacheStore = try cacheLocationStoreFactory(
                    "com.mirmir.app"
                )
                cacheStoreInitializationError = nil
            } catch {
                resolvedCacheStore = nil
                cacheStoreInitializationError = error
            }
        } else {
            resolvedCacheStore = nil
            cacheStoreInitializationError = nil
        }
        self.cacheLocationStore = resolvedCacheStore

        if let status = resolvedCacheStore?.status() {
            cacheLocationPath = status.path
            cacheLocationIsCustom = status.isCustom
            cacheLocationErrorMessage = status.availabilityError
        }

        if let workflowController {
            self.workflowController = workflowController
        } else if let cacheStoreInitializationError {
            self.workflowController = nil
            workflowErrorMessage =
                cacheStoreInitializationError.localizedDescription
            cacheLocationErrorMessage =
                cacheStoreInitializationError.localizedDescription
            recordBoundaryFailure(
                cacheStoreInitializationError,
                operation: "initialize_cache_store",
                code: "cache_store_initialization_failed"
            )
        } else if let resolvedCacheStore {
            do {
                let configuration = try resolvedCacheStore.configuration()
                self.workflowController = try WorkflowApplicationCoordinatorV4
                    .live(
                        configuration: configuration,
                        videoProbe: videoProbe,
                        backendCatalog: backendCatalog,
                        runtimeEnvironment: runtimeEnvironment
                    )
            } catch {
                self.workflowController = nil
                workflowErrorMessage = error.localizedDescription
                cacheLocationErrorMessage = error.localizedDescription
                recordBoundaryFailure(
                    error,
                    operation: "initialize_workflow_controller",
                    code: "workflow_controller_initialization_failed"
                )
            }
        } else {
            self.workflowController = nil
            workflowErrorMessage =
                "The durable workflow cache could not be initialized."
        }
    }

    var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }

    var selectedBackendAvailability: BackendAvailability? {
        backendSnapshot?.entry(for: selectedBackendID)?.availability
    }

    var canStart: Bool {
        isRequestReady
            && !(selectedBackendID.isDeterministicV4
                && isWorkflowProcessing)
    }

    var canPauseWorkflow: Bool {
        guard isWorkflowProcessing else { return false }
        return workflowQueueSnapshot?.items.contains {
            $0.lifecycle == .running || $0.lifecycle == .pausing
        } == true
    }

    var canEnqueueWorkflow: Bool {
        isRequestReady
            && selectedBackendID.isDeterministicV4
            && !isEnqueueingWorkflow
    }

    var pausedWorkflowItems: [WorkflowApplicationQueueItemV4] {
        workflowQueueSnapshot?.items.filter { $0.lifecycle == .paused } ?? []
    }

    var canChangeCacheLocation: Bool {
        !usesInjectedWorkflowController
            && cacheLocationStore != nil
            && !isManagingCache
            && !isWorkflowProcessing
            && !isEnqueueingWorkflow
            && (workflowController == nil
                || workflowQueueSnapshot?.items.isEmpty == true)
    }

    var cacheLocationChangeGuidance: String {
        if workflowController == nil, cacheLocationErrorMessage != nil {
            return "The current cache could not be opened. Choose another "
                + "location or use internal storage; existing data at the "
                + "unavailable location will not be changed."
        }
        if canChangeCacheLocation {
            return "New durable jobs will use this location."
        }
        return "Delete the jobs in this cache before changing its location."
    }

    var finishedCachedJobCount: Int {
        workflowQueueSnapshot?.items.filter(\.lifecycle.isTerminal).count ?? 0
    }

    var unfinishedCachedJobCount: Int {
        workflowQueueSnapshot?.items.filter { !$0.lifecycle.isTerminal }.count
            ?? 0
    }

    var deletableCachedJobCount: Int {
        workflowQueueSnapshot?.items.filter {
            $0.lifecycle.canDeleteCachedData
        }.count ?? 0
    }

    var canClearCache: Bool {
        workflowController != nil
            && !isManagingCache
            && !isWorkflowProcessing
            && !isEnqueueingWorkflow
    }

    var startValidationMessage: String? {
        if isCompleted {
            return "Choose Process Another to begin a new job."
        }
        guard currentVideoInfo != nil else { return "Choose a source video." }
        guard targetWidth > 0, targetHeight > 0 else {
            return "Enter positive output dimensions."
        }
        guard !outputCodec.requiresEvenEncodedDimensions
                || (targetWidth.isMultiple(of: 2)
                    && targetHeight.isMultiple(of: 2)) else {
            return "4:2:0 output requires even encoded dimensions."
        }
        guard outputURL != nil else { return "Choose an output destination folder." }
        guard let availability = selectedBackendAvailability else {
            return isCheckingBackendAvailability
                ? "Checking backend availability…"
                : "Backend availability has not been established."
        }
        guard availability.isRunnable else { return availability.statusText }
        if selectedBackendID.isDeterministicV4,
           workflowController == nil {
            return workflowErrorMessage
                ?? "The durable v4 workflow could not be initialized."
        }
        if selectedBackendID.isDeterministicV4,
           isWorkflowProcessing {
            return "A durable job is active. Add this request to the queue."
        }
        return nil
    }

    private var isCompleted: Bool {
        if case .completed = state { return true }
        return false
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        selectVideo(selectedURL)
    }

    func selectVideo(_ url: URL) {
        cancelCurrentWork()

        guard url.isFileURL else {
            state = .failed(.invalidRequest("Select a video file stored on this Mac."))
            return
        }

        let probeID = UUID()
        let access = SecurityScopedAccess(url: url)
        activeProbeID = probeID
        scopedInputAccess = access
        currentVideoInfo = nil
        outputURL = nil
        scopedOutputAccess = nil
        state = .probing(url)

        let videoProbe = videoProbe
        probeTask = Task { [weak self, access] in
            _ = access
            do {
                let info = try await videoProbe.probe(url: url)
                try Task.checkCancellation()
                guard let self, self.activeProbeID == probeID else { return }
                self.currentVideoInfo = info
                self.configureInitialTarget(for: info)
                self.state = .ready(info)
                self.probeTask = nil
                self.refreshBackendAvailability(for: info)
            } catch is CancellationError {
                return
            } catch let error as MirmirError where error == .cancelled {
                return
            } catch let error as MirmirError {
                guard let self, self.activeProbeID == probeID else { return }
                self.state = .failed(error)
                self.probeTask = nil
                self.scopedInputAccess = nil
                self.recordBoundaryFailure(
                    error,
                    operation: "probe_source",
                    code: "source_probe_failed"
                )
            } catch {
                guard let self, self.activeProbeID == probeID else { return }
                self.state = .failed(.probeFailed(
                    "Mirmir couldn’t inspect \(url.lastPathComponent): \(error.localizedDescription)"
                ))
                self.probeTask = nil
                self.scopedInputAccess = nil
                self.recordBoundaryFailure(
                    error,
                    operation: "probe_source",
                    code: "source_probe_failed"
                )
            }
        }
    }

    func clear() {
        cancelCurrentWork()
        currentVideoInfo = nil
        targetWidth = 0
        targetHeight = 0
        sourceAspectRatio = nil
        outputURL = nil
        scopedOutputAccess = nil
        state = .empty
    }

    func selectBackend(_ backendID: UpscaleBackendID) {
        preferredInitialScaleFactor = nil
        selectedBackendID = backendID
    }

    func targetAdjustmentForSelecting(
        _ backendID: UpscaleBackendID
    ) -> BackendSelectionTargetAdjustment? {
        guard backendID == .videoToolboxSuperResolutionQuality
                || backendID == .videoToolboxSuperResolutionLowLatency else {
            return nil
        }
        guard let source = currentVideoInfo else {
            guard backendID == .videoToolboxSuperResolutionQuality else {
                return nil
            }
            let supported = superResolutionScaleProvider(backendID, 0, 0)
            guard !supported.isEmpty, !supported.contains(2) else { return nil }
            let proposedScale = supported[0]
            return BackendSelectionTargetAdjustment(
                backendID: backendID,
                sourceURL: nil,
                sourceWidth: 0,
                sourceHeight: 0,
                currentTargetWidth: 0,
                currentTargetHeight: 0,
                proposedTargetWidth: 0,
                proposedTargetHeight: 0,
                proposedScaleFactor: proposedScale,
                supportedScaleFactors: supported
            )
        }
        guard
              let encoded = integralEncodedSize(for: source),
              let availability = backendSnapshot?
                .entry(for: backendID)?.availability,
              case .unavailable(let reason) = availability,
              case .unsupportedScaleFactor = reason else {
            return nil
        }

        let supported = superResolutionScaleProvider(
            backendID,
            encoded.width,
            encoded.height
        )
        guard !supported.isEmpty else { return nil }
        let proposedScale = backendID == .videoToolboxSuperResolutionLowLatency
            && supported.contains(2)
            ? 2
            : supported[0]
        let width = encoded.width.multipliedReportingOverflow(by: proposedScale)
        let height = encoded.height.multipliedReportingOverflow(by: proposedScale)
        guard !width.overflow, !height.overflow,
              width.partialValue != targetWidth
                || height.partialValue != targetHeight else {
            return nil
        }

        return BackendSelectionTargetAdjustment(
            backendID: backendID,
            sourceURL: source.url,
            sourceWidth: encoded.width,
            sourceHeight: encoded.height,
            currentTargetWidth: targetWidth,
            currentTargetHeight: targetHeight,
            proposedTargetWidth: width.partialValue,
            proposedTargetHeight: height.partialValue,
            proposedScaleFactor: proposedScale,
            supportedScaleFactors: supported
        )
    }

    func applyBackendSelectionAdjustment(
        _ adjustment: BackendSelectionTargetAdjustment
    ) {
        if adjustment.sourceURL == nil {
            guard currentVideoInfo == nil else { return }
            selectedBackendID = adjustment.backendID
            preferredInitialScaleFactor = adjustment.proposedScaleFactor
            return
        }
        guard currentVideoInfo?.url == adjustment.sourceURL else { return }
        selectedBackendID = adjustment.backendID
        preferredInitialScaleFactor = nil
        targetWidth = adjustment.proposedTargetWidth
        targetHeight = adjustment.proposedTargetHeight
        targetDidChange()
    }

    func setTargetWidth(_ value: Int, preservingAspectRatio: Bool = false) {
        targetWidth = max(0, value)
        if preservingAspectRatio, let sourceAspectRatio, sourceAspectRatio > 0 {
            targetHeight = evenDimension(Double(targetWidth) / sourceAspectRatio)
        }
        targetDidChange()
    }

    func setTargetHeight(_ value: Int, preservingAspectRatio: Bool = false) {
        targetHeight = max(0, value)
        if preservingAspectRatio, let sourceAspectRatio, sourceAspectRatio > 0 {
            targetWidth = evenDimension(Double(targetHeight) * sourceAspectRatio)
        }
        targetDidChange()
    }

    func applyScale(_ factor: Int) {
        applyScale(numerator: factor, denominator: 1)
    }

    func applyScale(numerator: Int, denominator: Int) {
        guard let info = currentVideoInfo,
              let encoded = integralEncodedSize(for: info),
              numerator > 0,
              denominator > 0 else { return }
        let widthProduct = encoded.width.multipliedReportingOverflow(
            by: numerator
        )
        let heightProduct = encoded.height.multipliedReportingOverflow(
            by: numerator
        )
        guard !widthProduct.overflow,
              !heightProduct.overflow else { return }
        targetWidth = evenDimension(
            Double(widthProduct.partialValue) / Double(denominator)
        )
        targetHeight = evenDimension(
            Double(heightProduct.partialValue) / Double(denominator)
        )
        targetDidChange()
    }

    func setOutputCodec(_ codec: OutputCodec) {
        outputCodec = codec
    }

    func setPreserveAudio(_ value: Bool) {
        preserveAudio = value
    }

    func setOverwriteExistingFile(_ value: Bool) {
        overwriteExistingFile = value
    }

    func chooseOutput() {
        guard let source = currentVideoInfo else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Destination"
        panel.message = "Mirmir will create the upscaled movie in this folder."
        let initialDirectory = outputURL?.deletingLastPathComponent()
            ?? source.url.deletingLastPathComponent()
        panel.directoryURL = initialDirectory
        guard panel.runModal() == .OK, let directoryURL = panel.url else {
            return
        }

        let filename = availableSuggestedOutputFilename(
            for: source,
            in: directoryURL
        )
        scopedOutputAccess = nil
        scopedOutputAccess = SecurityScopedAccess(url: directoryURL)
        outputURL = directoryURL.appendingPathComponent(
            filename,
            isDirectory: false
        )
    }

    func setOutputURL(_ url: URL?) {
        scopedOutputAccess = nil
        outputURL = url
        if let url {
            scopedOutputAccess = SecurityScopedAccess(url: url)
        }
    }

    func initializeWorkflowIfNeeded() async {
        guard !hasInitializedWorkflow else { return }
        await initializeWorkflow()
    }

    func initializeWorkflow() async {
        guard !isInitializingWorkflow,
              let workflowController else { return }
        isInitializingWorkflow = true
        defer { isInitializingWorkflow = false }
        do {
            let launch = try await withDiagnosticRecorder {
                await workflowController.installObserver(workflowObserver)
                return try await workflowController.launch()
            }
            applyWorkflowSnapshot(launch.queue)
            workflowRecoverySnapshot = launch.recovery
            workflowErrorMessage = Self.recoveryErrorMessage(
                launch.recovery
            )
            hasInitializedWorkflow = true
        } catch {
            workflowErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "initialize_workflow",
                code: "workflow_launch_failed"
            )
        }
    }

    func refreshWorkflowSnapshot() async {
        guard let workflowController else { return }
        do {
            applyWorkflowSnapshot(
                try await withDiagnosticRecorder {
                    try await workflowController.queueSnapshot()
                }
            )
        } catch {
            workflowErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "refresh_workflow_snapshot",
                code: "workflow_snapshot_failed"
            )
        }
    }

    func chooseCacheLocation() {
        guard canChangeCacheLocation else {
            cacheLocationErrorMessage =
                WorkflowCacheLocationErrorV4.jobsMustBeClearedFirst
                    .localizedDescription
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Select Mirmir Cache Location"
        panel.prompt = "Use for Cache"
        panel.message =
            "Mirmir will create a Mirmir/WorkflowV4 folder here."
        if cacheLocationIsCustom {
            let root = URL(
                fileURLWithPath: cacheLocationPath,
                isDirectory: true
            )
            panel.directoryURL = root
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let selected = panel.url else {
            return
        }
        changeCacheLocation(to: selected)
    }

    func useDefaultCacheLocation() {
        guard let cacheLocationStore else {
            let error = Self.unavailableServiceError(
                service: "workflow_cache_location_store",
                code: 1
            )
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "use_default_cache_location",
                code: "cache_location_store_unavailable"
            )
            return
        }
        guard canChangeCacheLocation else {
            cacheLocationErrorMessage =
                WorkflowCacheLocationErrorV4.jobsMustBeClearedFirst
                    .localizedDescription
            return
        }
        isManagingCache = true
        cacheLocationErrorMessage = nil
        cacheOperationStatusMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let preference = cacheLocationStore.preferenceSnapshot()
                let configuration = try cacheLocationStore.useDefault()
                do {
                    try await self.installWorkflowController(
                        configuration: configuration
                    )
                } catch {
                    cacheLocationStore.restorePreference(preference)
                    throw error
                }
                self.applyCacheLocationStatus(cacheLocationStore.status())
                self.cacheOperationStatusMessage =
                    "Using Mirmir’s internal cache."
            } catch {
                self.cacheLocationErrorMessage = error.localizedDescription
                self.recordBoundaryFailure(
                    error,
                    operation: "use_default_cache_location",
                    code: "cache_location_reset_failed"
                )
            }
            self.isManagingCache = false
        }
    }

    func deleteCachedJob(_ jobID: WorkflowJobID) async {
        guard !isManagingCache else { return }
        guard let workflowController else {
            let error = Self.unavailableServiceError(
                service: "workflow_controller",
                code: 2
            )
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "delete_cached_job",
                code: "workflow_controller_unavailable",
                fields: (try? [MirmirDiagnosticRecorder.textField(
                    "job_id_context",
                    jobID.rawValue
                )]) ?? []
            )
            return
        }
        isManagingCache = true
        defer { isManagingCache = false }
        cacheLocationErrorMessage = nil
        cacheOperationStatusMessage = nil
        do {
            let snapshot = try await withDiagnosticRecorder {
                try await workflowController.deleteCachedJob(jobID: jobID)
                return try await workflowController.queueSnapshot()
            }
            applyWorkflowSnapshot(snapshot)
            cacheOperationStatusMessage = "Deleted the cached job."
        } catch {
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "delete_cached_job",
                code: "cache_job_delete_failed",
                fields: (try? [MirmirDiagnosticRecorder.textField(
                    "job_id_context",
                    jobID.rawValue
                )]) ?? []
            )
            await refreshWorkflowSnapshot()
        }
    }

    func deleteCachedJobs(_ selection: WorkflowCachedJobSelectionV4) async {
        guard !isManagingCache else { return }
        guard let workflowController else {
            let error = Self.unavailableServiceError(
                service: "workflow_controller",
                code: 2
            )
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "delete_cached_jobs",
                code: "workflow_controller_unavailable",
                fields: (try? [MirmirDiagnosticRecorder.textField(
                    "cache_job_selection",
                    selection.rawValue
                )]) ?? []
            )
            return
        }
        isManagingCache = true
        defer { isManagingCache = false }
        cacheLocationErrorMessage = nil
        cacheOperationStatusMessage = nil
        do {
            let result = try await withDiagnosticRecorder {
                let count = try await workflowController.deleteCachedJobs(
                    selection: selection
                )
                let snapshot = try await workflowController.queueSnapshot()
                return (count, snapshot)
            }
            let count = result.0
            applyWorkflowSnapshot(result.1)
            cacheOperationStatusMessage = count == 1
                ? "Deleted 1 cached job."
                : "Deleted \(count) cached jobs."
        } catch {
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "delete_cached_jobs",
                code: "cache_jobs_delete_failed",
                fields: (try? [MirmirDiagnosticRecorder.textField(
                    "cache_job_selection",
                    selection.rawValue
                )]) ?? []
            )
            await refreshWorkflowSnapshot()
        }
    }

    func clearCache() async {
        guard let workflowController else {
            let error = Self.unavailableServiceError(
                service: "workflow_controller",
                code: 2
            )
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "clear_cache",
                code: "workflow_controller_unavailable"
            )
            return
        }
        guard canClearCache else {
            cacheLocationErrorMessage =
                "The durable workflow cache is unavailable or busy."
            return
        }
        isManagingCache = true
        defer { isManagingCache = false }
        cacheLocationErrorMessage = nil
        cacheOperationStatusMessage = nil
        do {
            let response = try await withDiagnosticRecorder {
                let result = try await workflowController.clearCache()
                let snapshot = try await workflowController.queueSnapshot()
                return (result, snapshot)
            }
            let result = response.0
            applyWorkflowSnapshot(response.1)
            cacheOperationStatusMessage =
                "Cleared \(result.deletedJobCount) cached job"
                + (result.deletedJobCount == 1 ? "" : "s")
                + " and \(result.deletedArtifactCount) residual cache "
                + "artifact"
                + (result.deletedArtifactCount == 1 ? "." : "s.")
        } catch {
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "clear_cache",
                code: "cache_clear_failed"
            )
            await refreshWorkflowSnapshot()
        }
    }

    func startUpscale() {
        guard canStart,
              let source = currentVideoInfo,
              let outputURL else { return }

        let request = UpscaleRequest(
            inputURL: source.url,
            outputURL: outputURL,
            backendID: selectedBackendID,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            outputCodec: outputCodec,
            preserveAudio: preserveAudio,
            overwriteExistingFile: overwriteExistingFile
        )
        let initialProgress = UpscaleProgress(
            phase: .probing,
            fractionCompleted: nil,
            processedFrameCount: 0,
            processedTime: nil,
            duration: source.duration,
            actualBackendID: nil
        )
        state = .processing(source, initialProgress)

        if selectedBackendID.isDeterministicV4,
           let workflowController {
            startDurableUpscale(
                request: request,
                source: source,
                workflowController: workflowController
            )
            return
        }

        let coordinator = coordinator
        let progressTarget = self
        let diagnosticOperationID = UUID().uuidString.lowercased()
        let diagnosticContext = MirmirDiagnosticExecutionContext(
            jobID: "direct-\(diagnosticOperationID)",
            workflowID: "direct-\(diagnosticOperationID)",
            queueItemID: "not-queued"
        )
        let diagnosticRecorder = diagnosticRecorder
        processingTask = Task { [weak self] in
            do {
                let result = try await MirmirDiagnosticScope
                    .$recorder.withValue(diagnosticRecorder) {
                        try await MirmirDiagnosticScope
                            .$executionContext.withValue(diagnosticContext) {
                                try await coordinator.process(request) { progress in
                                    Task { @MainActor in
                                        guard progressTarget.isProcessing else {
                                            return
                                        }
                                        progressTarget.state = .processing(
                                            source,
                                            progress
                                        )
                                    }
                                }
                            }
                    }
                guard let self else { return }
                self.state = .completed(source, result)
                self.processingTask = nil
            } catch let error as MirmirError {
                guard let self else { return }
                self.processingTask = nil
                if error == .cancelled {
                    self.state = .ready(source)
                } else {
                    self.state = .failed(error)
                    self.recordBoundaryFailure(
                        error,
                        operation: "process_upscale",
                        code: "upscale_processing_failed"
                    )
                }
            } catch is CancellationError {
                guard let self else { return }
                self.processingTask = nil
                self.state = .ready(source)
            } catch {
                guard let self else { return }
                self.processingTask = nil
                self.state = .failed(.outputFinalizeFailed(error.localizedDescription))
                self.recordBoundaryFailure(
                    error,
                    operation: "process_upscale",
                    code: "upscale_processing_failed"
                )
            }
        }
    }

    func enqueueUpscale(priority: Int32 = 0) {
        guard canEnqueueWorkflow,
              let source = currentVideoInfo,
              let outputURL,
              selectedBackendID.isDeterministicV4,
              let workflowController else { return }
        let request = UpscaleRequest(
            inputURL: source.url,
            outputURL: outputURL,
            backendID: selectedBackendID,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            outputCodec: outputCodec,
            preserveAudio: preserveAudio,
            overwriteExistingFile: overwriteExistingFile
        )
        workflowErrorMessage = nil
        isEnqueueingWorkflow = true
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.withDiagnosticRecorder {
                    try await workflowController.enqueue(
                        request: request,
                        priority: priority
                    )
                }
                self.isEnqueueingWorkflow = false
                await self.refreshWorkflowSnapshot()
                if self.draftMatches(request) {
                    self.resetDraftAfterEnqueue()
                }
            } catch {
                self.isEnqueueingWorkflow = false
                self.workflowErrorMessage = error.localizedDescription
                self.recordBoundaryFailure(
                    error,
                    operation: "enqueue_workflow",
                    code: "workflow_enqueue_failed",
                    fields: (try? [MirmirDiagnosticRecorder.field(
                        "queue_priority",
                        .signedInteger(Int64(priority))
                    )]) ?? []
                )
            }
        }
    }

    func setWorkflowPriority(
        _ jobID: WorkflowJobID,
        value: Int32
    ) {
        guard let workflowController else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.withDiagnosticRecorder {
                    try await workflowController.setPriority(
                        jobID: jobID,
                        value: value
                    )
                }
                await self.refreshWorkflowSnapshot()
            } catch {
                self.workflowErrorMessage = error.localizedDescription
                self.recordBoundaryFailure(
                    error,
                    operation: "set_workflow_priority",
                    code: "workflow_priority_update_failed",
                    fields: (try? [
                        MirmirDiagnosticRecorder.textField(
                            "job_id_context",
                            jobID.rawValue
                        ),
                        MirmirDiagnosticRecorder.field(
                            "queue_priority",
                            .signedInteger(Int64(value))
                        )
                    ]) ?? []
                )
            }
        }
    }

    func adjustWorkflowPriority(
        _ jobID: WorkflowJobID,
        delta: Int32
    ) {
        guard let current = workflowQueueSnapshot?.items.first(
            where: { $0.jobID == jobID }
        )?.priority else { return }
        let candidate = Int64(current) + Int64(delta)
        let clamped = min(
            Int64(WorkflowQueuePriorityV4.maximum),
            max(Int64(WorkflowQueuePriorityV4.minimum), candidate)
        )
        setWorkflowPriority(jobID, value: Int32(clamped))
    }

    func moveWorkflowJob(
        _ jobID: WorkflowJobID,
        direction: WorkflowApplicationQueueMoveV4
    ) {
        guard let workflowController else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.withDiagnosticRecorder {
                    try await workflowController.move(
                        jobID: jobID,
                        direction: direction
                    )
                }
                await self.refreshWorkflowSnapshot()
            } catch {
                self.workflowErrorMessage = error.localizedDescription
                let directionValue = switch direction {
                case .earlier: "earlier"
                case .later: "later"
                }
                self.recordBoundaryFailure(
                    error,
                    operation: "move_workflow_job",
                    code: "workflow_move_failed",
                    fields: (try? [
                        MirmirDiagnosticRecorder.textField(
                            "job_id_context",
                            jobID.rawValue
                        ),
                        MirmirDiagnosticRecorder.textField(
                            "queue_move_direction",
                            directionValue
                        )
                    ]) ?? []
                )
            }
        }
    }

    func pauseProcessing() {
        guard isWorkflowProcessing,
              let workflowController else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.withDiagnosticRecorder {
                    try await workflowController.requestPause()
                }
                await self.refreshWorkflowSnapshot()
            } catch {
                self.workflowErrorMessage = error.localizedDescription
                self.recordBoundaryFailure(
                    error,
                    operation: "pause_workflow",
                    code: "workflow_pause_failed"
                )
            }
        }
    }

    func resumeWorkflowJob(_ jobID: WorkflowJobID) {
        guard !isProcessing,
              !isWorkflowProcessing,
              let workflowController else { return }
        isWorkflowProcessing = true
        isForegroundWorkflowProcessing = true
        workflowErrorMessage = nil
        let progressTarget = self
        let diagnosticRecorder = diagnosticRecorder
        processingTask = Task { [weak self] in
            do {
                let outcome = try await MirmirDiagnosticScope
                    .$recorder.withValue(diagnosticRecorder) {
                    try await workflowController.resume(
                        jobID: jobID,
                        progress: { progress in
                            Task { @MainActor in
                                guard let current = progressTarget.currentVideoInfo,
                                      progressTarget.isWorkflowProcessing else {
                                    return
                                }
                                progressTarget.state = .processing(
                                    current,
                                    progress
                                )
                            }
                        },
                        snapshot: { snapshot in
                            Task { @MainActor in
                                progressTarget.applyWorkflowSnapshot(snapshot)
                            }
                        }
                    )
                }
                guard let self else { return }
                self.applyWorkflowOutcome(outcome)
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                await self.refreshWorkflowSnapshot()
            } catch is CancellationError {
                guard let self else { return }
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                if let source = self.currentVideoInfo {
                    self.state = .ready(source)
                }
                await self.refreshWorkflowSnapshot()
            } catch let error as MirmirError where error == .cancelled {
                guard let self else { return }
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                if let source = self.currentVideoInfo {
                    self.state = .ready(source)
                }
                await self.refreshWorkflowSnapshot()
            } catch {
                guard let self else { return }
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                self.workflowErrorMessage = error.localizedDescription
                self.state = .failed(.outputFinalizeFailed(
                    error.localizedDescription
                ))
                self.recordBoundaryFailure(
                    error,
                    operation: "resume_workflow",
                    code: "workflow_resume_failed",
                    fields: (try? [MirmirDiagnosticRecorder.textField(
                        "job_id_context",
                        jobID.rawValue
                    )]) ?? []
                )
                await self.refreshWorkflowSnapshot()
            }
        }
    }

    func downloadSelectedModel() {
        guard !isDownloadingModel,
              let source = currentVideoInfo,
              selectedBackendID == .videoToolboxSuperResolutionQuality,
              targetWidth > 0,
              targetHeight > 0 else { return }
        let downloadID = UUID()
        activeModelDownloadID = downloadID
        isDownloadingModel = true
        modelDownloadProgress = nil
        modelDownloadMessage = "Requesting the Apple model download…"
        let request = BackendPreparationRequest(
            source: source,
            targetSize: CGSize(width: targetWidth, height: targetHeight)
        )
        let backendCatalog = backendCatalog
        let runtimeEnvironment = runtimeEnvironment
        let backendID = selectedBackendID
        let progressTarget = self
        let diagnosticRecorder = diagnosticRecorder
        modelDownloadTask = Task { [weak self] in
            do {
                try await MirmirDiagnosticScope.$recorder.withValue(
                    diagnosticRecorder
                ) {
                    try await backendCatalog.downloadModel(
                        backendID: backendID,
                        request: request,
                        environment: runtimeEnvironment
                    ) { progress in
                        Task { @MainActor in
                            guard progressTarget.activeModelDownloadID
                                    == downloadID else {
                                return
                            }
                            progressTarget.modelDownloadProgress = min(
                                max(progress, 0),
                                1
                            )
                            progressTarget.modelDownloadMessage =
                                "Downloading Apple model…"
                        }
                    }
                }
                guard let self,
                      self.activeModelDownloadID == downloadID else { return }
                self.activeModelDownloadID = nil
                self.isDownloadingModel = false
                self.modelDownloadProgress = 1
                self.modelDownloadMessage = "Apple model is ready."
                self.modelDownloadTask = nil
                self.refreshBackendAvailability(for: source)
            } catch is CancellationError {
                guard let self,
                      self.activeModelDownloadID == downloadID else { return }
                self.activeModelDownloadID = nil
                self.isDownloadingModel = false
                self.modelDownloadProgress = nil
                self.modelDownloadMessage = nil
                self.modelDownloadTask = nil
            } catch {
                guard let self,
                      self.activeModelDownloadID == downloadID else { return }
                self.activeModelDownloadID = nil
                self.isDownloadingModel = false
                self.modelDownloadMessage = error.localizedDescription
                self.modelDownloadTask = nil
                self.recordBoundaryFailure(
                    error,
                    operation: "download_model",
                    code: "model_download_failed",
                    fields: (try? [MirmirDiagnosticRecorder.textField(
                        "backend_id",
                        backendID.rawValue
                    )]) ?? []
                )
                self.refreshBackendAvailability(for: source)
            }
        }
    }

    func cancelProcessing() {
        if isWorkflowProcessing, let workflowController {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.withDiagnosticRecorder {
                        try await workflowController.cancelActive()
                    }
                } catch is CancellationError {
                    return
                } catch let error as MirmirError where error == .cancelled {
                    return
                } catch {
                    self.workflowErrorMessage = error.localizedDescription
                    self.recordBoundaryFailure(
                        error,
                        operation: "cancel_workflow",
                        code: "workflow_cancel_failed"
                    )
                }
            }
            return
        }
        processingTask?.cancel()
        Task { await coordinator.cancel() }
    }

    func returnToReady() {
        guard let currentVideoInfo else { return }
        state = .ready(currentVideoInfo)
    }

    func processAnother() {
        clear()
    }

    func openCompletedOutput() {
        guard case .completed(_, let result) = state else { return }
        NSWorkspace.shared.open(result.outputURL)
    }

    func revealCompletedOutput() {
        guard case .completed(_, let result) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
    }

    func revealSourceInFinder() {
        guard let currentVideoInfo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([currentVideoInfo.url])
    }

    func waitForCurrentProbe() async { await probeTask?.value }
    func waitForBackendAvailability() async { await backendAvailabilityTask?.value }
    func waitForProcessing() async { await processingTask?.value }

    private func cancelCurrentWork() {
        activeProbeID = nil
        probeTask?.cancel()
        probeTask = nil
        if isForegroundWorkflowProcessing, let workflowController {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.withDiagnosticRecorder {
                        try await workflowController.cancelActive()
                    }
                } catch is CancellationError {
                    return
                } catch let error as MirmirError where error == .cancelled {
                    return
                } catch {
                    self.recordBoundaryFailure(
                        error,
                        operation: "cancel_workflow",
                        code: "workflow_cancel_failed"
                    )
                }
            }
        } else {
            processingTask?.cancel()
        }
        processingTask = nil
        isForegroundWorkflowProcessing = false
        activeModelDownloadID = nil
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        isDownloadingModel = false
        modelDownloadProgress = nil
        modelDownloadMessage = nil
        Task { await coordinator.cancel() }
        scopedInputAccess = nil
        cancelBackendAvailability()
    }

    private func startDurableUpscale(
        request: UpscaleRequest,
        source: VideoInfo,
        workflowController: any WorkflowApplicationControllingV4
    ) {
        isWorkflowProcessing = true
        isForegroundWorkflowProcessing = true
        workflowErrorMessage = nil
        let progressTarget = self
        let diagnosticRecorder = diagnosticRecorder
        processingTask = Task { [weak self] in
            do {
                let outcome = try await MirmirDiagnosticScope
                    .$recorder.withValue(diagnosticRecorder) {
                        try await workflowController.submit(
                            request: request,
                            progress: { progress in
                                Task { @MainActor in
                                    guard progressTarget
                                        .isWorkflowProcessing else {
                                        return
                                    }
                                    progressTarget.state = .processing(
                                        source,
                                        progress
                                    )
                                }
                            },
                            snapshot: { snapshot in
                                Task { @MainActor in
                                    progressTarget.applyWorkflowSnapshot(
                                        snapshot
                                    )
                                }
                            }
                        )
                    }
                guard let self else { return }
                self.applyWorkflowOutcome(outcome)
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                await self.refreshWorkflowSnapshot()
            } catch let error as MirmirError {
                guard let self else { return }
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                if error == .cancelled {
                    self.state = .ready(source)
                } else {
                    self.state = .failed(error)
                    self.workflowErrorMessage = error.localizedDescription
                    self.recordBoundaryFailure(
                        error,
                        operation: "submit_workflow",
                        code: "workflow_submit_failed"
                    )
                }
                await self.refreshWorkflowSnapshot()
            } catch is CancellationError {
                guard let self else { return }
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                self.state = .ready(source)
                await self.refreshWorkflowSnapshot()
            } catch {
                guard let self else { return }
                self.processingTask = nil
                self.isForegroundWorkflowProcessing = false
                self.workflowErrorMessage = error.localizedDescription
                self.state = .failed(.outputFinalizeFailed(
                    error.localizedDescription
                ))
                self.recordBoundaryFailure(
                    error,
                    operation: "submit_workflow",
                    code: "workflow_submit_failed"
                )
                await self.refreshWorkflowSnapshot()
            }
        }
    }

    private func applyWorkflowOutcome(
        _ outcome: WorkflowApplicationRunOutcomeV4
    ) {
        switch outcome {
        case .completed(let completion):
            currentVideoInfo = completion.source
            state = .completed(completion.source, completion.result)
        case .paused(_, let source):
            currentVideoInfo = source
            state = .ready(source)
        }
    }

    private var workflowObserver: WorkflowApplicationObserverV4 {
        WorkflowApplicationObserverV4(
            progress: { _, _ in },
            snapshot: { [weak self] snapshot in
                Task { @MainActor in
                    self?.applyWorkflowSnapshot(snapshot)
                }
            },
            execution: { [weak self] event in
                Task { @MainActor in
                    self?.applyWorkflowExecutionEvent(event)
                }
            }
        )
    }

    private func changeCacheLocation(to selectedDirectory: URL) {
        guard let cacheLocationStore else {
            let error = Self.unavailableServiceError(
                service: "workflow_cache_location_store",
                code: 1
            )
            cacheLocationErrorMessage = error.localizedDescription
            recordBoundaryFailure(
                error,
                operation: "change_cache_location",
                code: "cache_location_store_unavailable"
            )
            return
        }
        guard canChangeCacheLocation else {
            cacheLocationErrorMessage =
                WorkflowCacheLocationErrorV4.jobsMustBeClearedFirst
                    .localizedDescription
            return
        }
        isManagingCache = true
        cacheLocationErrorMessage = nil
        cacheOperationStatusMessage = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let preference = cacheLocationStore.preferenceSnapshot()
                let configuration = try cacheLocationStore.select(
                    selectedDirectory
                )
                do {
                    try await self.installWorkflowController(
                        configuration: configuration
                    )
                } catch {
                    cacheLocationStore.restorePreference(preference)
                    throw error
                }
                self.applyCacheLocationStatus(cacheLocationStore.status())
                self.cacheOperationStatusMessage =
                    "The cache location is ready."
            } catch {
                self.cacheLocationErrorMessage = error.localizedDescription
                self.recordBoundaryFailure(
                    error,
                    operation: "change_cache_location",
                    code: "cache_location_change_failed"
                )
            }
            self.isManagingCache = false
        }
    }

    private func installWorkflowController(
        configuration: WorkflowCacheLocationConfigurationV4
    ) async throws {
        let replacement = try WorkflowApplicationCoordinatorV4.live(
            configuration: configuration,
            videoProbe: videoProbe,
            backendCatalog: backendCatalog,
            runtimeEnvironment: runtimeEnvironment
        )
        let launch = try await withDiagnosticRecorder {
            await replacement.installObserver(workflowObserver)
            return try await replacement.launch()
        }
        if let previous = workflowController {
            await previous.installObserver(.none)
        }
        workflowController = replacement
        hasInitializedWorkflow = true
        applyWorkflowSnapshot(launch.queue)
        workflowRecoverySnapshot = launch.recovery
        workflowErrorMessage = Self.recoveryErrorMessage(launch.recovery)
        cacheLocationErrorMessage = nil
    }

    private func applyCacheLocationStatus(
        _ status: WorkflowCacheLocationStatusV4
    ) {
        cacheLocationPath = status.path
        cacheLocationIsCustom = status.isCustom
        cacheLocationErrorMessage = status.availabilityError
    }

    private func applyWorkflowSnapshot(
        _ snapshot: WorkflowApplicationQueueSnapshotV4
    ) {
        workflowQueueSnapshot = snapshot
        isWorkflowProcessing = snapshot.items.contains {
            switch $0.lifecycle {
            case .probing, .planned, .running, .pausing, .verifying,
                 .committing, .recovering:
                return true
            case .queued, .paused, .completed, .cancelled, .contained,
                 .failed, .safeHalt:
                return false
            }
        }
    }

    private func applyWorkflowExecutionEvent(
        _ event: WorkflowApplicationExecutionEventV4
    ) {
        switch event {
        case .finished:
            break
        case .failed(_, let message):
            workflowErrorMessage = message
        }
    }

    private func resetDraftAfterEnqueue() {
        currentVideoInfo = nil
        targetWidth = 0
        targetHeight = 0
        sourceAspectRatio = nil
        outputURL = nil
        scopedInputAccess = nil
        scopedOutputAccess = nil
        state = .empty
        cancelBackendAvailability()
    }

    private var isRequestReady: Bool {
        guard !isProcessing,
              !isCompleted,
              currentVideoInfo != nil,
              outputURL != nil,
              targetWidth > 0,
              targetHeight > 0,
              (!outputCodec.requiresEvenEncodedDimensions
                || (targetWidth.isMultiple(of: 2)
                    && targetHeight.isMultiple(of: 2))),
              selectedBackendAvailability?.isRunnable == true else {
            return false
        }
        if selectedBackendID.isDeterministicV4,
           workflowController == nil {
            return false
        }
        return true
    }

    private func draftMatches(_ request: UpscaleRequest) -> Bool {
        currentVideoInfo?.url == request.inputURL
            && outputURL == request.outputURL
            && selectedBackendID == request.backendID
            && targetWidth == request.targetWidth
            && targetHeight == request.targetHeight
            && outputCodec == request.outputCodec
            && preserveAudio == request.preserveAudio
            && overwriteExistingFile == request.overwriteExistingFile
    }

    private static func recoveryErrorMessage(
        _ snapshot: WorkflowLaunchRecoverySnapshotV4
    ) -> String? {
        let affected = snapshot.items.filter {
            $0.status == .contained
                || $0.status == .bookmarkBlocked
                || $0.status == .decisionRecordCorrupt
                || $0.status == .recoveryFailed
                || $0.containedFailureCount > 0
        }
        guard !affected.isEmpty else { return nil }
        let jobs = affected.map { $0.jobID.rawValue }.joined(separator: ", ")
        return "Launch recovery contained durable workflow errors for: \(jobs)."
    }

    private func configureInitialTarget(for source: VideoInfo) {
        guard let encoded = integralEncodedSize(for: source) else {
            targetWidth = 0
            targetHeight = 0
            sourceAspectRatio = nil
            return
        }
        sourceAspectRatio = Double(encoded.width) / Double(encoded.height)
        let initialScale = preferredInitialScaleFactor ?? 2
        let width = encoded.width.multipliedReportingOverflow(by: initialScale)
        let height = encoded.height.multipliedReportingOverflow(by: initialScale)
        guard !width.overflow, !height.overflow else {
            targetWidth = 0
            targetHeight = 0
            return
        }
        targetWidth = width.partialValue
        targetHeight = height.partialValue
    }

    private func targetDidChange() {
        guard let currentVideoInfo else { return }
        refreshBackendAvailability(for: currentVideoInfo)
    }

    private func refreshBackendAvailability(for source: VideoInfo) {
        cancelBackendAvailability()
        guard targetWidth > 0, targetHeight > 0 else {
            backendAvailabilityMessage =
                "Backend availability requires positive integral encoded dimensions."
            return
        }

        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        let availabilityID = UUID()
        activeBackendAvailabilityID = availabilityID
        backendTargetSize = targetSize
        backendAvailabilityMessage = nil
        isCheckingBackendAvailability = true

        let backendCatalog = backendCatalog
        let runtimeEnvironment = runtimeEnvironment
        backendAvailabilityTask = Task { [weak self] in
            let snapshot = await backendCatalog.snapshot(
                for: source,
                targetSize: targetSize,
                environment: runtimeEnvironment
            )
            guard !Task.isCancelled,
                  let self,
                  self.activeBackendAvailabilityID == availabilityID,
                  self.currentVideoInfo?.url == source.url else { return }
            self.backendSnapshot = snapshot
            self.isCheckingBackendAvailability = false
            self.backendAvailabilityTask = nil
        }
    }

    private func cancelBackendAvailability() {
        activeBackendAvailabilityID = nil
        backendAvailabilityTask?.cancel()
        backendAvailabilityTask = nil
        backendSnapshot = nil
        backendTargetSize = nil
        backendAvailabilityMessage = nil
        isCheckingBackendAvailability = false
    }

    private func integralEncodedSize(for source: VideoInfo) -> (width: Int, height: Int)? {
        guard let encodedSize = source.geometry.encodedSize,
              let width = integralDimension(encodedSize.width),
              let height = integralDimension(encodedSize.height) else { return nil }
        return (width, height)
    }

    private func integralDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite, value > 0 else { return nil }
        let rounded = value.rounded()
        guard abs(value - rounded) <= 0.001,
              let integer = Int(exactly: rounded), integer > 0 else { return nil }
        return integer
    }

    private func evenDimension(_ value: Double) -> Int {
        guard value.isFinite, value > 0,
              value <= Double(Int.max - 1) else { return 0 }
        let rounded = Int(value.rounded())
        return rounded.isMultiple(of: 2) ? rounded : rounded + 1
    }

    private func suggestedOutputFilename(for source: VideoInfo) -> String {
        let stem = sanitizedFilenameComponent(
            source.url.deletingPathExtension().lastPathComponent
        )
        return "\(stem)-\(targetWidth)x\(targetHeight)-\(backendFilenameToken).mov"
    }

    private func availableSuggestedOutputFilename(
        for source: VideoInfo,
        in directory: URL
    ) -> String {
        let filename = suggestedOutputFilename(for: source)
        let base = (filename as NSString).deletingPathExtension
        let pathExtension = (filename as NSString).pathExtension
        var candidate = filename
        var suffix = 2
        while FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(candidate).path
        ) {
            candidate = "\(base)-\(suffix).\(pathExtension)"
            suffix += 1
        }
        return candidate
    }

    private var backendFilenameToken: String {
        switch selectedBackendID {
        case .mirmirDeterministicCPU: "mirmir-cpu"
        case .mirmirDeterministicMetal: "mirmir-metal"
        case .videoToolboxSuperResolutionQuality: "vt-quality"
        case .videoToolboxSuperResolutionLowLatency: "vt-low-latency"
        case .videoToolboxInterpolationWithSpatialScale: "vt-smooth-motion"
        case .metalFXSpatial: "metalfx"
        case .mpsLanczos: "mps-lanczos"
        case .mpsBilinear: "mps-bilinear"
        case .coreImageLanczos: "ci-lanczos"
        case .coreImageBicubic: "ci-bicubic"
        case .vImageHighQuality: "vimage-hq"
        case .vImageStandard: "vimage"
        case .videoToolboxPixelTransfer: "vt-pixel-transfer"
        case .automatic: "automatic"
        }
    }

    private func sanitizedFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_ ")
        )
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Mirmir-output" : sanitized
    }

    private static func unavailableServiceError(
        service: String,
        code: Int
    ) -> NSError {
        let description = service == "workflow_controller"
            ? "The durable workflow cache is unavailable."
            : "The cache location service is unavailable."
        return NSError(
            domain: "com.mirmir.application-view-model",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: description,
                "service": service
            ]
        )
    }

    private func withDiagnosticRecorder<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> Result {
        try await MirmirDiagnosticScope.$recorder.withValue(diagnosticRecorder) {
            try await operation()
        }
    }

    private func recordBoundaryFailure(
        _ error: Error,
        operation: String,
        code: String,
        fields: [MirmirDiagnosticField] = [],
        fileID: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        MirmirDiagnosticStore.logger.error(
            "View model failure; operation=\(operation, privacy: .public) code=\(code, privacy: .public)"
        )
        diagnosticRecorder.enqueue(
            severity: .error,
            subsystem: "application_view_model",
            operation: operation,
            code: code,
            fields: fields,
            error: error,
            fileID: fileID,
            function: function,
            line: line
        )
    }

    deinit {
        probeTask?.cancel()
        backendAvailabilityTask?.cancel()
        processingTask?.cancel()
        modelDownloadTask?.cancel()
    }
}
