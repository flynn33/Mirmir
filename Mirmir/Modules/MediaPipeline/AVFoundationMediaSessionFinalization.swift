import AVFoundation
import CoreMedia
import Foundation

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
            try await finishAudioIfPresent()
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
            var mediaEndTime = sessionEndTime
            if let audioIdentity = expectedCompressedAACIdentity {
                let audioEndTime = CMTimeRangeGetEnd(
                    audioIdentity.trackTimeRange
                )
                if CMTimeCompare(audioEndTime, mediaEndTime) > 0 {
                    mediaEndTime = audioEndTime
                }
            }
            await finishWriter(at: mediaEndTime)

            try checkCancellation()
            guard writer.status == .completed else {
                if writer.status == .cancelled { throw CancellationError() }
                throw MediaPipelineError.writerFailed(writer.error)
            }

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
            retainCleanupError(outputTransaction.cancel())
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
        retainCleanupError(outputTransaction.fail())
        return terminalCleanupError ?? error
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

    private func finishAudioIfPresent() async throws {
        guard audioOutput != nil, let audioInput else { return }
        let audioStage = telemetry.beginStage(.audioProcess)
        defer { telemetry.endStage(audioStage) }
        while !audioInputIsFinished {
            try checkCancellation()
            guard writer.status == .writing else {
                if writer.status == .cancelled {
                    throw CancellationError()
                }
                throw MediaPipelineError.writerFailed(writer.error)
            }
            if audioInput.isReadyForMoreMediaData {
                try pumpAudio(through: nil)
            } else {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    func pumpAudio(through maximumPresentationTime: CMTime?) throws {
        guard let audioOutput,
              let audioInput,
              !audioInputIsFinished else {
            return
        }
        while audioInput.isReadyForMoreMediaData {
            let sample: CMSampleBuffer
            if let pendingAudioSample {
                sample = pendingAudioSample
            } else if let nextSample = audioOutput.copyNextSampleBuffer() {
                sample = nextSample
                pendingAudioSample = nextSample
            } else {
                if let error = reader.error {
                    throw MediaPipelineError.readerFailed(error)
                }
                audioInput.markAsFinished()
                audioInputIsFinished = true
                return
            }

            let presentationTime =
                CMSampleBufferGetPresentationTimeStamp(sample)
            if let maximumPresentationTime,
               presentationTime.isValid,
               presentationTime.isNumeric,
               maximumPresentationTime.isValid,
               maximumPresentationTime.isNumeric,
               CMTimeCompare(
                   presentationTime,
                   maximumPresentationTime
               ) > 0 {
                return
            }

            guard audioInput.append(sample) else {
                throw MediaPipelineError.audioBridgeFailed(
                    writer.error ?? NSError(domain: "Audio", code: -1)
                )
            }
            pendingAudioSample = nil
        }
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
                )
            )
            telemetry.endStage(verificationStage)
            return result
        } catch {
            telemetry.endStage(verificationStage)
            throw MediaPipelineError.outputVerificationFailed(
                outputProfile.url,
                String(describing: error)
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
