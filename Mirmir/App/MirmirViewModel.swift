import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

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

    @ObservationIgnored private let videoProbe: any VideoProbing
    @ObservationIgnored private let backendCatalog: UpscaleBackendCatalog
    @ObservationIgnored private let runtimeEnvironment: RuntimeEnvironment
    @ObservationIgnored private let coordinator: UpscaleCoordinator
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var backendAvailabilityTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var modelDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var activeProbeID: UUID?
    @ObservationIgnored private var activeBackendAvailabilityID: UUID?
    @ObservationIgnored private var scopedInputAccess: SecurityScopedAccess?
    @ObservationIgnored private var scopedOutputAccess: SecurityScopedAccess?
    @ObservationIgnored private var sourceAspectRatio: Double?

    init(
        videoProbe: any VideoProbing = VideoProbe(),
        backendCatalog: UpscaleBackendCatalog = .live(),
        runtimeEnvironment: RuntimeEnvironment = .current(),
        coordinator: UpscaleCoordinator? = nil
    ) {
        self.videoProbe = videoProbe
        self.backendCatalog = backendCatalog
        self.runtimeEnvironment = runtimeEnvironment
        self.coordinator = coordinator ?? UpscaleCoordinator(
            videoProbe: videoProbe,
            backendCatalog: backendCatalog,
            runtimeEnvironment: runtimeEnvironment
        )
    }

    var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }

    var selectedBackendAvailability: BackendAvailability? {
        backendSnapshot?.entry(for: selectedBackendID)?.availability
    }

    var canStart: Bool {
        guard !isProcessing,
              !isCompleted,
              currentVideoInfo != nil,
              outputURL != nil,
              targetWidth > 0,
              targetHeight > 0,
              targetWidth.isMultiple(of: 2),
              targetHeight.isMultiple(of: 2),
              selectedBackendAvailability?.isRunnable == true else {
            return false
        }
        return true
    }

    var startValidationMessage: String? {
        if isCompleted {
            return "Choose Process Another to begin a new job."
        }
        guard currentVideoInfo != nil else { return "Choose a source video." }
        guard targetWidth > 0, targetHeight > 0 else {
            return "Enter positive output dimensions."
        }
        guard targetWidth.isMultiple(of: 2), targetHeight.isMultiple(of: 2) else {
            return "4:2:0 output requires even encoded dimensions."
        }
        guard outputURL != nil else { return "Choose an output destination folder." }
        guard let availability = selectedBackendAvailability else {
            return isCheckingBackendAvailability
                ? "Checking backend availability…"
                : "Backend availability has not been established."
        }
        guard availability.isRunnable else { return availability.statusText }
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
            } catch let error as MirmirError {
                guard let self, self.activeProbeID == probeID else { return }
                self.state = .failed(error)
                self.probeTask = nil
                self.scopedInputAccess = nil
            } catch {
                guard let self, self.activeProbeID == probeID else { return }
                self.state = .failed(.probeFailed(
                    "Mirmir couldn’t inspect \(url.lastPathComponent): \(error.localizedDescription)"
                ))
                self.probeTask = nil
                self.scopedInputAccess = nil
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
        selectedBackendID = backendID
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

        let coordinator = coordinator
        let progressTarget = self
        processingTask = Task { [weak self] in
            do {
                let result = try await coordinator.process(request) { progress in
                    Task { @MainActor in
                        guard progressTarget.isProcessing else { return }
                        progressTarget.state = .processing(source, progress)
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
                }
            } catch is CancellationError {
                guard let self else { return }
                self.processingTask = nil
                self.state = .ready(source)
            } catch {
                guard let self else { return }
                self.processingTask = nil
                self.state = .failed(.outputFinalizeFailed(error.localizedDescription))
            }
        }
    }

    func downloadSelectedModel() {
        guard !isDownloadingModel,
              let source = currentVideoInfo,
              selectedBackendID == .videoToolboxSuperResolutionQuality,
              targetWidth > 0,
              targetHeight > 0 else { return }
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
        modelDownloadTask = Task { [weak self] in
            do {
                try await backendCatalog.downloadModel(
                    backendID: backendID,
                    request: request,
                    environment: runtimeEnvironment
                ) { progress in
                    Task { @MainActor in
                        progressTarget.modelDownloadProgress = min(max(progress, 0), 1)
                        progressTarget.modelDownloadMessage = "Downloading Apple model…"
                    }
                }
                guard let self else { return }
                self.isDownloadingModel = false
                self.modelDownloadProgress = 1
                self.modelDownloadMessage = "Apple model is ready."
                self.modelDownloadTask = nil
                self.refreshBackendAvailability(for: source)
            } catch {
                guard let self else { return }
                self.isDownloadingModel = false
                self.modelDownloadMessage = error.localizedDescription
                self.modelDownloadTask = nil
                self.refreshBackendAvailability(for: source)
            }
        }
    }

    func cancelProcessing() {
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
        processingTask?.cancel()
        processingTask = nil
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        isDownloadingModel = false
        modelDownloadProgress = nil
        modelDownloadMessage = nil
        Task { await coordinator.cancel() }
        scopedInputAccess = nil
        cancelBackendAvailability()
    }

    private func configureInitialTarget(for source: VideoInfo) {
        guard let encoded = integralEncodedSize(for: source) else {
            targetWidth = 0
            targetHeight = 0
            sourceAspectRatio = nil
            return
        }
        sourceAspectRatio = Double(encoded.width) / Double(encoded.height)
        let width = encoded.width.multipliedReportingOverflow(by: 2)
        let height = encoded.height.multipliedReportingOverflow(by: 2)
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

    deinit {
        probeTask?.cancel()
        backendAvailabilityTask?.cancel()
        processingTask?.cancel()
        modelDownloadTask?.cancel()
    }
}
