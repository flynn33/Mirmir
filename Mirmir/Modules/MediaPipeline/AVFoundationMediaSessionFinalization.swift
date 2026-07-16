import AVFoundation
import CoreMedia
import Foundation

extension AVFoundationMediaSession {
    func finish() async throws {
        do {
            try checkCancellation()
            try outputTransaction.beginFinishing()
            try await finishAudioIfPresent()

            videoInput.markAsFinished()
            let timing = timingLedgerSnapshot()
            guard let sessionEndTime = timing.sessionEndTime else {
                throw MediaPipelineError.invalidFrameTiming(
                    String(describing: FrameTimingLedgerError.empty)
                )
            }
            writer.endSession(atSourceTime: sessionEndTime)
            await finishWriter(at: sessionEndTime)

            try checkCancellation()
            guard writer.status == .completed else {
                if writer.status == .cancelled { throw CancellationError() }
                throw MediaPipelineError.writerFailed(writer.error)
            }

            try outputTransaction.beginVerifying()
            let verification = try await verifyOutput(timing: timing)
            recordVerification(verification)
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
        guard let audioOutput, let audioInput else { return }
        let audioStage = telemetry.beginStage(.audioProcess)
        defer { telemetry.endStage(audioStage) }
        while let sample = audioOutput.copyNextSampleBuffer() {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
                try checkCancellation()
            }
            try checkCancellation()
            if !audioInput.append(sample) {
                throw MediaPipelineError.audioBridgeFailed(
                    writer.error ?? NSError(domain: "Audio", code: -1)
                )
            }
        }
        audioInput.markAsFinished()
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
        timing: FrameTimingLedgerSnapshot
    ) async throws -> OutputMediaVerificationResult {
        let verificationStage = telemetry.beginStage(.reopenVerify)
        do {
            let result = try await outputVerifier.verify(
                url: outputTransaction.temporaryURL,
                expectation: OutputMediaVerificationExpectation(
                    resolution: outputProfile.resolution,
                    codec: outputProfile.codec,
                    timing: timing
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
