import Foundation
import CoreMedia
import CoreVideo
import os.lock

@available(macOS 15.4, *)
final class DefaultUpscalerEngineService: UpscalerEngineService, @unchecked Sendable {

    typealias TelemetryFactory = @Sendable () -> any ASHTelemetryRecording

    private let media: MediaPipelineService
    private let backendFactory: any ASHUpscaleBackendFactory
    private let telemetryFactory: TelemetryFactory
    private let jobIsActive = OSAllocatedUnfairLock(initialState: false)

    var availability: UpscalerEngineAvailability { .available }

    init(
        media: MediaPipelineService,
        metal _: MetalRenderingService,
        modelAssets _: ModelAssetsService,
        backendFactory: any ASHUpscaleBackendFactory,
        telemetryFactory: @escaping TelemetryFactory = { ASHNoopTelemetryRecorder.shared }
    ) {
        self.media = media
        self.backendFactory = backendFactory
        self.telemetryFactory = telemetryFactory
    }

    func start() {}
    func stop() {}

    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle {
        guard !FileURLIdentity.refersToSameFile(job.inputURL, job.outputURL) else {
            throw UpscalerEngineError.inputOutputCollision
        }
        guard !FileManager.default.fileExists(
            atPath: job.outputURL.path
        ) else {
            throw UpscalerEngineError.outputAlreadyExists
        }
        let reserved = jobIsActive.withLock { active in
            guard !active else { return false }
            active = true
            return true
        }
        guard reserved else {
            throw UpscalerEngineError.jobAlreadyRunning
        }
        let telemetry = telemetryFactory()
        let scopedMedia = (media as? any ASHTelemetryMediaPipelineScoping)?
            .scoped(to: telemetry) ?? media
        let handle = DefaultUpscalerJobHandle(
            job: job,
            media: scopedMedia,
            backendFactory: backendFactory,
            telemetry: telemetry,
            onTerminal: { [weak self] in
                self?.jobIsActive.withLock { $0 = false }
            }
        )
        handle.start()
        return handle
    }
}

@available(macOS 15.4, *)
final class DefaultUpscalerJobHandle: UpscalerJobHandle, @unchecked Sendable {

    let progressStream: AsyncStream<UpscaleProgress>
    private let progressContinuation: AsyncStream<UpscaleProgress>.Continuation

    private let job: UpscaleJob
    private let media: MediaPipelineService
    private let backendFactory: any ASHUpscaleBackendFactory
    private let telemetry: any ASHTelemetryRecording
    private let onTerminal: @Sendable () -> Void

    private var task: Task<URL, Error>?

    init(
        job: UpscaleJob,
        media: MediaPipelineService,
        backendFactory: any ASHUpscaleBackendFactory,
        telemetry: any ASHTelemetryRecording,
        onTerminal: @escaping @Sendable () -> Void
    ) {
        self.job = job
        self.media = media
        self.backendFactory = backendFactory
        self.telemetry = telemetry
        self.onTerminal = onTerminal
        var continuation: AsyncStream<UpscaleProgress>.Continuation!
        self.progressStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.progressContinuation = continuation
    }

    func start() {
        let runID = UUID().uuidString
        telemetry.beginRun(id: runID)
        task = Task.detached(
            priority: .userInitiated
        ) { [progressContinuation, job, media, backendFactory, telemetry, onTerminal] in
            defer {
                progressContinuation.finish()
                onTerminal()
            }
            let jobToken = telemetry.beginStage(.jobTotal)
            do {
                let output = try await Self.runJob(
                    job: job,
                    media: media,
                    backendFactory: backendFactory,
                    telemetry: telemetry,
                    progressContinuation: progressContinuation
                )
                telemetry.endStage(jobToken)
                telemetry.finish(status: .success, message: nil)
                return output
            } catch is CancellationError {
                telemetry.endStage(jobToken)
                telemetry.finish(status: .cancelled, message: "Task cancellation")
                throw UpscalerEngineError.cancelled
            } catch let error as UpscalerEngineError {
                telemetry.recordError(error)
                telemetry.endStage(jobToken)
                if case .cancelled = error {
                    telemetry.finish(status: .cancelled, message: String(describing: error))
                } else {
                    telemetry.finish(status: .failure, message: String(describing: error))
                }
                throw error
            } catch {
                telemetry.recordError(error)
                telemetry.endStage(jobToken)
                telemetry.finish(status: .failure, message: String(describing: error))
                throw error
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    func waitForCompletion() async throws -> URL {
        guard let task else {
            throw UpscalerEngineError.strategyFailed("job was never started")
        }
        return try await task.value
    }

    private static func runJob(
        job: UpscaleJob,
        media: MediaPipelineService,
        backendFactory: any ASHUpscaleBackendFactory,
        telemetry: any ASHTelemetryRecording,
        progressContinuation: AsyncStream<UpscaleProgress>.Continuation
    ) async throws -> URL {
        let isAccessingInput = job.inputURL.startAccessingSecurityScopedResource()
        let isAccessingOutput = job.outputURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingOutput {
                job.outputURL.stopAccessingSecurityScopedResource()
            }
            if isAccessingInput {
                job.inputURL.stopAccessingSecurityScopedResource()
            }
        }

        let source = try await media.probe(url: job.inputURL)
        let strategy = try StrategySelector.choose(source: source.resolution, target: job.targetResolution)

        let backend = try await backendFactory.makeBackend(
            route: strategy.spatialRoute,
            telemetry: telemetry
        )
        backend.reset()
        let output = OutputProfile(
            url: job.outputURL,
            resolution: job.targetResolution,
            codec: job.codec,
            preserveAudio: job.preserveAudio,
            timedMetadataTemplate: backend.finalOutputMetadata
        )
        let session = try await media.beginSession(source: source, output: output)

        do {
            return try await withTaskCancellationHandler {
                let estimatedTotalFrames = max(source.estimatedFrameCount, 0)
                var processed = 0
                let startedAt = Date()

                while let record = try await session.nextSourceFrame() {
                    try Task.checkCancellation()
                    try await processFrame(
                        record,
                        backend: backend,
                        outputPool: session.outputPixelBufferPool,
                        session: session,
                        telemetry: telemetry
                    )

                    processed += 1
                    let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                    let throughput = Double(processed) / elapsed
                    let reportedTotal = max(estimatedTotalFrames, processed)
                    let remaining = max(reportedTotal - processed, 0)
                    let eta = estimatedTotalFrames > 0 && throughput > 0
                        ? Double(remaining) / throughput
                        : nil
                    progressContinuation.yield(UpscaleProgress(
                        framesProcessed: processed,
                        totalFrames: reportedTotal,
                        throughputFPS: throughput,
                        etaSeconds: eta
                    ))
                }

                try Task.checkCancellation()

                try await session.finish(finalMetadata: backend.finalOutputMetadata)
                try Task.checkCancellation()
                if let cleanupError = session.terminalCleanupError {
                    throw cleanupError
                }
                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                progressContinuation.yield(UpscaleProgress(
                    framesProcessed: processed,
                    totalFrames: max(estimatedTotalFrames, processed),
                    throughputFPS: Double(processed) / elapsed,
                    etaSeconds: 0
                ))
                return job.outputURL
            } onCancel: {
                session.cancel()
            }
        } catch {
            session.cancel()
            if let cleanupError = session.terminalCleanupError {
                throw cleanupError
            }
            if error is CancellationError || Task.isCancelled {
                throw UpscalerEngineError.cancelled
            }
            throw error
        }
    }

    private static func processFrame(
        _ record: FrameRecord,
        backend: any ASHUpscaleBackend,
        outputPool: CVPixelBufferPool,
        session: MediaSession,
        telemetry: any ASHTelemetryRecording
    ) async throws {
        let frameToken = telemetry.beginStage(.frameTotal, frameIndex: record.frameIndex)
        do {
            let outputBuffer = try PixelBufferBridge.dequeue(from: outputPool)
            let completion = try await backend.process(
                source: record.pixelBuffer,
                into: outputBuffer,
                context: ASHUpscaleFrameContext(
                    frameIndex: record.frameIndex,
                    presentationTimestampValue: record.presentationTime.value,
                    presentationTimestampTimescale: record.presentationTime.timescale
                )
            )
            defer { completion.finishAfterAppend() }
            try Task.checkCancellation()
            try await session.appendOutput(
                pixelBuffer: outputBuffer,
                timing: record.timing
            )
            telemetry.endStage(frameToken)
        } catch {
            telemetry.endStage(frameToken)
            throw error
        }
    }
}
