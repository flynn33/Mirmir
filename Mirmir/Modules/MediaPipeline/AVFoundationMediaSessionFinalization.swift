import AVFoundation
import CoreMedia
import Foundation

private struct FinalMuxSourceTrack {
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let exactTimeScale: CMTimeScale
}

extension AVFoundationMediaSession {
    func finish() async throws {
        try await finish(
            finalMetadata: outputProfile.timedMetadataTemplate,
            validatingBeforePublish: {}
        )
    }

    func finish(finalMetadata: [String: String]) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            validatingBeforePublish: {}
        )
    }

    func finish(
        finalMetadata: [String: String],
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await finish(
            finalMetadata: finalMetadata,
            beforeReopen: {},
            validatingBeforePublish: validatingBeforePublish
        )
    }

    func finish(
        finalMetadata: [String: String],
        beforeReopen: @escaping @Sendable () async throws -> Void,
        validatingBeforePublish: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try checkCancellation()
            try outputTransaction.beginFinishing()
            videoInput.markAsFinished()
            let timing = timingLedgerSnapshot()
            guard let sessionEndTime = timing.sessionEndTime else {
                throw MediaPipelineError.invalidFrameTiming(
                    String(describing: FrameTimingLedgerError.empty)
                )
            }
            try await finishTimedMetadata(
                finalMetadata,
                sessionEndTime: sessionEndTime
            )
            await finishWriter(at: sessionEndTime)

            try checkCancellation()
            guard writer.status == .completed else {
                if writer.status == .cancelled { throw CancellationError() }
                throw MediaPipelineError.writerFailed(writer.error)
            }
            try await assembleFinalOutput()
            removeStagingFileAfterAssembly()

            try await beforeReopen()
            try checkCancellation()
            try outputTransaction.beginVerifying()
            let verification = try await verifyOutput(
                timing: timing,
                finalMetadata: finalMetadata
            )
            recordVerification(verification)
            try checkCancellation()
            try await validatingBeforePublish()
            try checkCancellation()
            try publishOutput()
        } catch {
            if error is CancellationError || sessionIsCancelled() {
                cancel()
                throw CancellationError()
            }
            throw failureAfterCleanup(error)
        }
    }

    func cancel() {
        var shouldCancelResources = false
        var shouldDiscardOutput = false

        lifecycleLock.lock()
        switch lifecycleState {
        case .active:
            lifecycleState = .cancelled
            shouldCancelResources = true
            shouldDiscardOutput = true
        case .cancelled, .failed:
            shouldDiscardOutput = true
        case .committed:
            break
        }
        lifecycleLock.unlock()

        if shouldCancelResources {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        if shouldDiscardOutput {
            var stagingError: Error?
            var outputCleanup: AtomicMediaOutputCleanupResult?
            finalizationResourceLock.withLock {
                stagingError = stagingFile.cleanup()
                outputCleanup = outputTransaction.cancel()
            }
            if let stagingError {
                retainStagingCleanupError(stagingError)
            }
            if let outputCleanup {
                retainCleanupError(outputCleanup)
            }
        }
    }

    func failureAfterCleanup(_ error: Error) -> Error {
        lifecycleLock.lock()
        if case .committed = lifecycleState {
            lifecycleLock.unlock()
            return error
        }
        lifecycleState = .failed
        lifecycleLock.unlock()

        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        var stagingError: Error?
        var outputCleanup: AtomicMediaOutputCleanupResult?
        finalizationResourceLock.withLock {
            stagingError = stagingFile.cleanup()
            outputCleanup = outputTransaction.fail()
        }
        if let stagingError {
            retainStagingCleanupError(stagingError)
        }
        if let outputCleanup {
            retainCleanupError(outputCleanup)
        }
        return error
    }

    func retainCleanupError(_ cleanup: AtomicMediaOutputCleanupResult) {
        guard let cleanupError = cleanup.error else { return }
        lifecycleLock.lock()
        if storedTerminalCleanupError == nil {
            storedTerminalCleanupError = MediaPipelineError.partialCleanupFailed(
                outputTransaction.temporaryURL,
                String(describing: cleanupError)
            )
        }
        lifecycleLock.unlock()
    }

    func retainStagingCleanupError(_ error: Error) {
        lifecycleLock.lock()
        if storedTerminalCleanupError == nil {
            storedTerminalCleanupError = MediaPipelineError.partialCleanupFailed(
                stagingFile.url,
                String(describing: error)
            )
        }
        lifecycleLock.unlock()
    }

    private func removeStagingFileAfterAssembly() {
        if let error = finalizationResourceLock.withLock({
            stagingFile.cleanup()
        }) {
            retainStagingCleanupError(error)
            telemetry.recordMedia(ASHMediaObservation(
                kind: "staging_cleanup_deferred",
                details: [
                    "reason": "owned_stage_removal_failed"
                ]
            ))
        } else {
            telemetry.recordMedia(ASHMediaObservation(
                kind: "staging_cleanup_completed",
                details: [:]
            ))
        }
    }

    private func assembleFinalOutput() async throws {
        do {
            try await assembleFinalOutputContents()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MediaPipelineError {
            if case .finalMuxFailed = error {
                throw error
            }
            throw MediaPipelineError.finalMuxFailed(
                outputProfile.url,
                error
            )
        } catch {
            throw MediaPipelineError.finalMuxFailed(
                outputProfile.url,
                error
            )
        }
    }

    // Preserve the ordered inspection, cancellation, sample-copy, and header gates.
    // swiftlint:disable:next function_body_length
    private func assembleFinalOutputContents() async throws {
        let stagingAsset = AVURLAsset(
            url: stagingFile.url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let stagingVideoTracks = try await stagingAsset.loadTracks(
            withMediaType: .video
        )
        guard stagingVideoTracks.count == 1,
              let stagingVideoTrack = stagingVideoTracks.first else {
            throw finalMuxError(
                .stagingVideoTrackCount(
                    expected: 1,
                    actual: stagingVideoTracks.count
                )
            )
        }
        let stagingMetadataTracks = try await stagingAsset.loadTracks(
            withMediaType: .metadata
        )
        let expectedMetadataTrackCount = outputProfile
            .timedMetadataTemplate
            .isEmpty ? 0 : 1
        guard stagingMetadataTracks.count == expectedMetadataTrackCount else {
            throw finalMuxError(
                .stagingMetadataTrackCount(
                    expected: expectedMetadataTrackCount,
                    actual: stagingMetadataTracks.count
                )
            )
        }

        var sourceTracks = try await makeFinalMuxSourceTracks(
            [stagingVideoTrack] + stagingMetadataTracks
        )
        if let sourceAudioTrack {
            let audioStage = telemetry.beginStage(.audioProcess)
            do {
                sourceTracks.append(
                    try await makeFinalMuxSourceTrack(sourceAudioTrack)
                )
                telemetry.endStage(audioStage)
            } catch {
                telemetry.endStage(audioStage)
                throw error
            }
        }
        let movieTimeScale = try ExactVideoWriterTimeScale
            .commonBoundaryScale(
                sourceTracks.map(\.timeRange)
            )
        let fileType = try Self.writerFileType(for: outputProfile.url)
        telemetry.recordMedia(ASHMediaObservation(
            kind: "final_sample_copy_mux_started",
            details: [
                "track_count": String(sourceTracks.count),
                "movie_timescale": String(movieTimeScale),
                "preserved_audio": String(sourceAudioTrack != nil)
            ]
        ))

        do {
            try finalizationResourceLock.withLock {
                try checkCancellation()
                try outputTransaction
                    .validateActiveTransactionLease()
                guard !FileManager.default.fileExists(
                    atPath: outputTransaction.temporaryURL.path
                ) else {
                    throw finalMuxError(
                        .temporaryOutputAlreadyExists
                    )
                }

                let movie = AVMutableMovie()
                movie.timescale = movieTimeScale
                movie.defaultMediaDataStorage = AVMediaDataStorage(
                    url: outputTransaction.temporaryURL,
                    options: nil
                )
                for sourceTrack in sourceTracks {
                    try checkCancellation()
                    guard let destinationTrack = movie.addMutableTrack(
                        withMediaType: sourceTrack.track.mediaType,
                        copySettingsFrom: sourceTrack.track,
                        options: nil
                    ) else {
                        throw finalMuxError(
                            .destinationTrackCreationFailed(
                                trackKind: FinalMuxGuardError.TrackKind(
                                    mediaType: sourceTrack.track.mediaType
                                )
                            )
                        )
                    }
                    destinationTrack.timescale = sourceTrack.exactTimeScale
                    try destinationTrack.insertTimeRange(
                        sourceTrack.timeRange,
                        of: sourceTrack.track,
                        at: sourceTrack.timeRange.start,
                        copySampleData: true
                    )
                }
                try checkCancellation()
                try movie.writeHeader(
                    to: outputTransaction.temporaryURL,
                    fileType: fileType,
                    options: .addMovieHeaderToDestination
                )
                try outputTransaction
                    .claimTemporaryFileForVerification()
                try checkCancellation()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MediaPipelineError {
            throw error
        } catch {
            throw MediaPipelineError.finalMuxFailed(
                outputProfile.url,
                error
            )
        }
        telemetry.recordMedia(ASHMediaObservation(
            kind: "final_sample_copy_mux_completed",
            details: [
                "track_count": String(sourceTracks.count),
                "movie_timescale": String(movieTimeScale),
                "preserved_audio": String(sourceAudioTrack != nil)
            ]
        ))
    }

    private func makeFinalMuxSourceTracks(
        _ tracks: [AVAssetTrack]
    ) async throws -> [FinalMuxSourceTrack] {
        var result: [FinalMuxSourceTrack] = []
        result.reserveCapacity(tracks.count)
        for track in tracks {
            try checkCancellation()
            result.append(try await makeFinalMuxSourceTrack(track))
        }
        return result
    }

    private func makeFinalMuxSourceTrack(
        _ track: AVAssetTrack
    ) async throws -> FinalMuxSourceTrack {
        let timeRange = try await track.load(.timeRange)
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        let exactTimeScale = try ExactVideoWriterTimeScale.resolve(
            naturalTimeScale: naturalTimeScale,
            trackTimeRange: timeRange
        )
        return FinalMuxSourceTrack(
            track: track,
            timeRange: timeRange,
            exactTimeScale: exactTimeScale
        )
    }

    private func finalMuxError(
        _ guardError: FinalMuxGuardError
    ) -> MediaPipelineError {
        MediaPipelineError.finalMuxFailed(
            outputProfile.url,
            guardError
        )
    }

    private func finishTimedMetadata(
        _ finalMetadata: [String: String],
        sessionEndTime: CMTime
    ) async throws {
        guard let timedMetadataWriter else {
            guard finalMetadata.isEmpty else {
                throw MediaPipelineError.outputMetadataMismatch(
                    "final metadata was supplied without a configured writer input"
                )
            }
            return
        }
        guard Set(finalMetadata.keys) == timedMetadataWriter.expectedKeys,
              finalMetadata.values.allSatisfy({ !$0.isEmpty }) else {
            throw MediaPipelineError.outputMetadataMismatch(
                "final metadata keys or values differ from the preflight template"
            )
        }
        while !timedMetadataWriter.input.isReadyForMoreMediaData {
            try checkCancellation()
            guard writer.status == .writing else {
                if writer.status == .cancelled {
                    throw CancellationError()
                }
                throw MediaPipelineError.writerFailed(writer.error)
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let group = Self.makeASHMetadataGroup(
            finalMetadata,
            timeRange: CMTimeRange(start: .zero, duration: sessionEndTime)
        )
        guard timedMetadataWriter.adaptor.append(group) else {
            throw MediaPipelineError.writerFailed(writer.error)
        }
        timedMetadataWriter.input.markAsFinished()
        telemetry.recordMedia(ASHMediaObservation(
            kind: "ash_output_identity_finalized",
            details: [
                "metadata_key_count": String(finalMetadata.count),
                "numerical_fallback_count": finalMetadata[
                    "com.mirmir.ash.numerical-fallback-count"
                ] ?? "not_applicable"
            ]
        ))
    }

    private func finishWriter(at sessionEndTime: CMTime) async {
        let finishStage = telemetry.beginStage(.writerFinish)
        writer.endSession(atSourceTime: sessionEndTime)
        await writer.finishWriting()
        telemetry.endStage(finishStage)
        telemetry.recordMedia(ASHMediaObservation(
            kind: "writer_finished",
            details: [
                "status": String(writer.status.rawValue),
                "session_end_value": String(sessionEndTime.value),
                "session_end_timescale": String(sessionEndTime.timescale)
            ]
        ))
    }

    private func verifyOutput(
        timing: FrameTimingLedgerSnapshot,
        finalMetadata: [String: String]
    ) async throws -> OutputMediaVerificationResult {
        let verificationStage = telemetry.beginStage(.reopenVerify)
        do {
            let result = try await outputVerifier.verify(
                url: outputTransaction.temporaryURL,
                expectation: OutputMediaVerificationExpectation(
                    resolution: outputProfile.resolution,
                    codec: outputProfile.codec,
                    timing: timing,
                    timedMetadata: finalMetadata,
                    videoColor: .sdrBT709VideoRangeLeft,
                    compressedAACIdentity: expectedCompressedAACIdentity,
                    preferredTransform: expectedVideoTransform
                ),
                cancellationCheck: {
                    try self.checkCancellation()
                }
            )
            telemetry.endStage(verificationStage)
            return result
        } catch is CancellationError {
            telemetry.endStage(verificationStage)
            throw CancellationError()
        } catch {
            telemetry.endStage(verificationStage)
            throw MediaPipelineError.outputVerificationFailed(
                outputProfile.url,
                error
            )
        }
    }

    private func recordVerification(_ verification: OutputMediaVerificationResult) {
        telemetry.recordMedia(ASHMediaObservation(
            kind: "output_reopen_verified",
            details: [
                "codec": verification.codec,
                "dimensions": verification.resolution.description,
                "frame_count": String(verification.frameCount),
                "duration_value": String(verification.duration.value),
                "duration_timescale": String(verification.duration.timescale),
                "luma_payload_bytes": String(verification.lumaPayloadBytes),
                "chroma_payload_bytes": String(verification.chromaPayloadBytes)
            ]
        ))
    }

    private func publishOutput() throws {
        guard !Task.isCancelled else { throw CancellationError() }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard case .active = lifecycleState,
              !Task.isCancelled else {
            throw CancellationError()
        }
        do {
            try outputTransaction.publish()
            lifecycleState = .committed
        } catch {
            lifecycleState = .failed
            if let cleanupError = outputTransaction.snapshot.cleanup?.error {
                storedTerminalCleanupError = MediaPipelineError.partialCleanupFailed(
                    outputTransaction.temporaryURL,
                    String(describing: cleanupError)
                )
                throw storedTerminalCleanupError ?? error
            }
            throw error
        }
    }

    private func timingLedgerSnapshot() -> FrameTimingLedgerSnapshot {
        timingLock.lock()
        defer { timingLock.unlock() }
        return timingLedger.snapshot
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if sessionIsCancelled() { throw CancellationError() }
    }

    func sessionIsCancelled() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard case .cancelled = lifecycleState else { return false }
        return true
    }
}

// Finalization and the final sample-copy mux are reviewed as one lifecycle.
// swiftlint:disable:this file_length
