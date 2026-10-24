import Foundation

final class ProcessingCancellation: NativeMediaInputCancellationV4, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }
}

actor UpscaleCoordinator {
    typealias ProgressHandler = VideoProcessingSession.ProgressHandler

    private let videoProbe: any VideoProbing
    private let backendCatalog: UpscaleBackendCatalog
    private let runtimeEnvironment: RuntimeEnvironment
    private let processingSession: VideoProcessingSession
    private let processingActivityFactory: MirmirProcessingActivityFactory
    private var activeCancellation: ProcessingCancellation?

    init(
        videoProbe: any VideoProbing = VideoProbe(),
        backendCatalog: UpscaleBackendCatalog = .live(),
        runtimeEnvironment: RuntimeEnvironment = .current(),
        processingSession: VideoProcessingSession = VideoProcessingSession(),
        processingActivityFactory: @escaping MirmirProcessingActivityFactory =
            MirmirProcessingActivity.begin
    ) {
        self.videoProbe = videoProbe
        self.backendCatalog = backendCatalog
        self.runtimeEnvironment = runtimeEnvironment
        self.processingSession = processingSession
        self.processingActivityFactory = processingActivityFactory
    }

    func process(
        _ request: UpscaleRequest,
        progress: @escaping ProgressHandler
    ) async throws -> UpscaleResult {
        guard activeCancellation == nil else {
            throw MirmirError.invalidRequest(
                "Wait for the active job to finish or cancel it before starting another."
            )
        }
        try validate(request)

        let processingActivity = processingActivityFactory(
            "Processing an upscale job"
        )
        defer { processingActivity.end() }
        let cancellation = ProcessingCancellation()
        activeCancellation = cancellation
        defer {
            if activeCancellation === cancellation {
                activeCancellation = nil
            }
        }

        let inputAccess = SecurityScopedAccess(url: request.inputURL)
        let outputAccess = SecurityScopedAccess(url: request.outputURL)
        defer {
            inputAccess.stop()
            outputAccess.stop()
        }

        progress(UpscaleProgress(
            phase: .probing,
            fractionCompleted: nil,
            processedFrameCount: 0,
            processedTime: nil,
            duration: nil,
            actualBackendID: nil
        ))
        try cancellation.check()
        let source = try await videoProbe.probe(url: request.inputURL)
        try cancellation.check()

        let snapshot = await backendCatalog.snapshot(
            for: source,
            targetSize: request.targetSize,
            environment: runtimeEnvironment
        )
        let resolution = snapshot.resolution(for: request.backendID)
        guard resolution.availability == .available,
              let actualBackendID = resolution.actualBackendID else {
            throw unavailableError(
                requestedBackendID: request.backendID,
                availability: resolution.availability
            )
        }

        progress(UpscaleProgress(
            phase: .preparingBackend,
            fractionCompleted: nil,
            processedFrameCount: 0,
            processedTime: nil,
            duration: source.duration,
            actualBackendID: actualBackendID
        ))
        let prepared = try await backendCatalog.prepare(
            backendID: actualBackendID,
            request: BackendPreparationRequest(
                source: source,
                targetSize: request.targetSize
            ),
            environment: runtimeEnvironment
        )
        guard prepared.actualBackendID == actualBackendID else {
            try? await prepared.finish()
            throw MirmirError.backendProcessingFailed(
                backendID: actualBackendID,
                frameIndex: nil,
                details: "the prepared adapter reported \(prepared.actualBackendID.rawValue), so the explicit job was stopped instead of falling back"
            )
        }
        do {
            try cancellation.check()
        } catch {
            try? await prepared.finish()
            throw error
        }

        return try await processingSession.process(
            request: request,
            source: source,
            preparedBackend: prepared,
            cancellation: cancellation,
            progress: progress
        )
    }

    func cancel() {
        activeCancellation?.cancel()
    }
}

private extension UpscaleCoordinator {
    func validate(_ request: UpscaleRequest) throws {
        guard request.inputURL.isFileURL, request.outputURL.isFileURL else {
            throw MirmirError.invalidRequest(
                "Input and output must be local files selected by the user."
            )
        }
        guard request.inputURL.standardizedFileURL
            != request.outputURL.standardizedFileURL else {
            throw MirmirError.invalidRequest(
                "The output must not replace the selected input video."
            )
        }
        guard request.targetWidth > 0,
              request.targetHeight > 0 else {
            throw MirmirError.invalidRequest(
                "Output dimensions must be positive."
            )
        }
        if request.outputCodec.requiresEvenEncodedDimensions,
           (!request.targetWidth.isMultiple(of: 2)
            || !request.targetHeight.isMultiple(of: 2)) {
            throw MirmirError.invalidRequest(
                "4:2:0 output requires even encoded dimensions."
            )
        }
    }

    func unavailableError(
        requestedBackendID: UpscaleBackendID,
        availability: BackendAvailability
    ) -> MirmirError {
        switch availability {
        case .available:
            return .backendUnavailable(
                requestedBackendID,
                "the backend did not resolve to a concrete adapter"
            )
        case .modelDownloadRequired:
            return .backendUnavailable(
                requestedBackendID,
                "the required Apple model must be downloaded before processing"
            )
        case .unavailable(let reason):
            return .backendUnavailable(
                requestedBackendID,
                reason.userFacingDescription
            )
        }
    }
}
