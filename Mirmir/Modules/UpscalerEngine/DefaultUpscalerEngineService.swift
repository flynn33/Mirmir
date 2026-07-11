import Foundation
import CoreMedia
import CoreVideo
import os.lock

@available(macOS 15.4, *)
final class DefaultUpscalerEngineService: UpscalerEngineService, @unchecked Sendable {

    typealias TelemetryFactory = @Sendable () -> any ASHTelemetryRecording

    private let media: MediaPipelineService
    private let metal: MetalRenderingService
    private let telemetryFactory: TelemetryFactory
    private let jobIsActive = OSAllocatedUnfairLock(initialState: false)

    init(
        media: MediaPipelineService,
        metal: MetalRenderingService,
        modelAssets _: ModelAssetsService,
        telemetryFactory: @escaping TelemetryFactory = { ASHNoopTelemetryRecorder.shared }
    ) {
        self.media = media
        self.metal = metal
        self.telemetryFactory = telemetryFactory
    }

    func start() {}
    func stop() {}

    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle {
        guard !FileURLIdentity.refersToSameFile(job.inputURL, job.outputURL) else {
            throw UpscalerEngineError.inputOutputCollision
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
            metal: metal,
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
    private let metal: MetalRenderingService
    private let telemetry: any ASHTelemetryRecording
    private let onTerminal: @Sendable () -> Void

    private var task: Task<URL, Error>?

    init(
        job: UpscaleJob,
        media: MediaPipelineService,
        metal: MetalRenderingService,
        telemetry: any ASHTelemetryRecording,
        onTerminal: @escaping @Sendable () -> Void
    ) {
        self.job = job
        self.media = media
        self.metal = metal
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
        ) { [progressContinuation, job, media, metal, telemetry, onTerminal] in
            defer {
                progressContinuation.finish()
                onTerminal()
            }
            let jobToken = telemetry.beginStage(.jobTotal)
            do {
                let output = try await Self.runJob(
                    job: job,
                    media: media,
                    metal: metal,
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
        metal: MetalRenderingService,
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

        let output = OutputProfile(
            url: job.outputURL,
            resolution: job.targetResolution,
            codec: job.codec,
            preserveAudio: job.preserveAudio
        )
        let session = try await media.beginSession(source: source, output: output)

        do {
            return try await withTaskCancellationHandler {
                let backend = ASHDeterministicUpscaleBackend(scale: 2, telemetry: telemetry)
                backend.reset()

                let lanczos: LanczosPolishPass?
                let srPool: CVPixelBufferPool
                switch strategy {
                case .direct2x:
                    lanczos = nil
                    srPool = session.outputPixelBufferPool
                case .twoXThenLanczosDownsample(let intermediate):
                    lanczos = LanczosPolishPass(metal: metal, telemetry: telemetry)
                    srPool = try PixelBufferBridge.makePool(
                        width: intermediate.width,
                        height: intermediate.height,
                        capacity: 6
                    )
                }

                let estimatedTotalFrames = max(source.estimatedFrameCount, 0)
                var processed = 0
                let startedAt = Date()

                while let record = try await session.nextSourceFrame() {
                    try Task.checkCancellation()
                    let frameToken = telemetry.beginStage(.frameTotal, frameIndex: record.frameIndex)

                    do {
                        let srBuffer = try PixelBufferBridge.dequeue(from: srPool)
                        try await backend.process(source: record.pixelBuffer, into: srBuffer)
                        try Task.checkCancellation()
                        let outputBuffer: CVPixelBuffer
                        if let lanczos {
                            let polished = try PixelBufferBridge.dequeue(from: session.outputPixelBufferPool)
                            try await lanczos.encode(from: srBuffer, to: polished)
                            try Task.checkCancellation()
                            outputBuffer = polished
                        } else {
                            outputBuffer = srBuffer
                        }
                        try await session.appendOutput(
                            pixelBuffer: outputBuffer,
                            at: record.presentationTime
                        )
                        telemetry.endStage(frameToken)
                    } catch {
                        telemetry.endStage(frameToken)
                        throw error
                    }

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

                try await session.finish()
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
            if error is CancellationError || Task.isCancelled {
                throw UpscalerEngineError.cancelled
            }
            throw error
        }
    }
}
