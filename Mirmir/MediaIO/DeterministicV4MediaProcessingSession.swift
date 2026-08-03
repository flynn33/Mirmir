import AVFoundation
import CoreMedia
import Foundation

/// Executes the deterministic v4 whole-asset plan. AVFoundation policy is
/// fixed before migration, the processed track is the only decoded stream,
/// and every pass-through stream is verified by encoded-sample digest.
struct DeterministicV4MediaProcessingSession: Sendable {
    typealias ProgressHandler = @Sendable (UpscaleProgress) -> Void

    private let planner: DeterministicV4WholeAssetPlanner
    private let executor: AVFoundationTrackMigrationExecutorV4
    private let outputValidator: OutputMediaValidator

    init(
        planner: DeterministicV4WholeAssetPlanner = .init(),
        executor: AVFoundationTrackMigrationExecutorV4 = .init(),
        outputValidator: OutputMediaValidator = .init()
    ) {
        self.planner = planner
        self.executor = executor
        self.outputValidator = outputValidator
    }

    func process(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend: any PreparedDeterministicV4PlanningBackend,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> UpscaleResult {
        let startedAt = Date()
        do {
            try cancellation.check()
            progress(event(
                phase: .preparingReaderWriter,
                source: source,
                backendID: preparedBackend.actualBackendID
            ))
            let preparedPlan = try await planner.prepare(
                request: request,
                source: source,
                backend: preparedBackend
            )
            try cancellation.check()
            let hook = try preparedPlan.makeProcessingHook(
                backend: preparedBackend
            )
            let migrationCancellation =
                AVFoundationTrackMigrationCancellationV4()
            let cancellationMonitor = Task {
                while !Task.isCancelled {
                    do {
                        try cancellation.check()
                    } catch {
                        migrationCancellation.cancel()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            defer { cancellationMonitor.cancel() }

            let migration: AVFoundationTrackMigrationExecutionResultV4
            do {
                migration = try await executor.execute(
                    .init(
                        sourceURL: request.inputURL,
                        destinationURL: request.outputURL,
                        outputFileType: .mov,
                        overwriteExistingFile:
                            request.overwriteExistingFile,
                        sourceGraph: preparedPlan.sourceGraph,
                        identifiedPlan: preparedPlan.trackPlan,
                        blueprint: preparedPlan.migrationBlueprint,
                        videoProcessingHooks: [hook]
                    ),
                    cancellation: migrationCancellation,
                    progress: { state in
                        progress(self.event(
                            phase: self.phase(for: state.stage),
                            source: source,
                            backendID: preparedBackend.actualBackendID,
                            frameCount: Int(clamping: state.migratedSampleCount)
                        ))
                    }
                )
            } catch AVFoundationTrackMigrationExecutorV4Error.cancelled {
                throw MirmirError.cancelled
            }
            try cancellation.check()
            progress(event(
                phase: .validatingOutput,
                source: source,
                backendID: preparedBackend.actualBackendID
            ))
            let facts = try await outputValidator.validate(
                url: request.outputURL,
                expectedWidth: request.targetWidth,
                expectedHeight: request.targetHeight,
                requiresAudio: request.preserveAudio && source.hasAudio
            )
            let primaryResult = migration.trackResults.first {
                $0.trackID == preparedPlan.primaryGraphTrack.identity.stableID
            }
            let frameCount = Int(clamping:
                primaryResult?.migratedSampleCount ?? 0
            )
            progress(event(
                phase: .completed,
                source: source,
                backendID: preparedBackend.actualBackendID,
                fraction: 1,
                frameCount: frameCount,
                processedTime: facts.duration
            ))
            return UpscaleResult(
                outputURL: request.outputURL,
                actualBackendID: preparedBackend.actualBackendID,
                encodedWidth: facts.encodedWidth,
                encodedHeight: facts.encodedHeight,
                durationSeconds: CMTimeGetSeconds(facts.duration),
                outputCodec: request.outputCodec,
                audioResult: audioResult(
                    request: request,
                    sourceGraph: preparedPlan.sourceGraph
                ),
                processedFrameCount: frameCount,
                processingDurationSeconds: Date().timeIntervalSince(startedAt)
            )
        } catch {
            try? await preparedBackend.finish()
            throw error
        }
    }
}

private extension DeterministicV4MediaProcessingSession {
    func phase(
        for stage: AVFoundationTrackMigrationExecutionStageV4
    ) -> UpscalePhase {
        switch stage {
        case .validating, .preparingReaderWriter:
            .preparingReaderWriter
        case .migrating:
            .processingVideo
        case .finalizing:
            .finalizing
        case .verifying, .publishing:
            .validatingOutput
        case .completed:
            .completed
        }
    }

    func audioResult(
        request: UpscaleRequest,
        sourceGraph: MediaTrackGraphV4
    ) -> AudioOutputResult {
        guard request.preserveAudio else { return .omitted }
        return sourceGraph.tracks.contains { $0.kind == .audio }
            ? .preserved
            : .absent
    }

    func event(
        phase: UpscalePhase,
        source: VideoInfo,
        backendID: UpscaleBackendID,
        fraction: Double? = nil,
        frameCount: Int = 0,
        processedTime: CMTime? = nil
    ) -> UpscaleProgress {
        UpscaleProgress(
            phase: phase,
            fractionCompleted: fraction,
            processedFrameCount: frameCount,
            processedTime: processedTime,
            duration: source.duration,
            actualBackendID: backendID
        )
    }
}
