import Foundation

extension R13ReleaseUpscalerJobHandle {
    static func processRecord(
        _ record: FrameRecord,
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        route: R03ScaleRoute,
        mediaSession: MediaSession,
        upscaleBinding: R13ReleaseUpscaleSessionBinding,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws -> Bool {
        let disposition = try await hardeningAttempt?
            .disposition(forFrameAt: record.frameIndex)
        if disposition == .replayVerifiedCache {
            let cachedFrame = try await hardeningAttempt?
                .replayFrame(at: record.frameIndex)
            guard let cachedFrame else {
                throw UpscalerEngineError.strategyFailed(
                    "R13 cache replay did not return its verified frame."
                )
            }
            let pixelBuffer = try cachedFrame.makeVideoRangePixelBuffer()
            try R03NV12Contract.validate(
                pixelBuffer: pixelBuffer,
                resolution: route.canonicalTargetResolution
            )
            try await mediaSession.appendOutput(
                pixelBuffer: pixelBuffer,
                timing: record.timing
            )
            return false
        }
        try await processWithBackend(
            record,
            source: source,
            route: route,
            runtime: runtime,
            session: upscaleBinding.session,
            mediaSession: mediaSession,
            hardeningAttempt: hardeningAttempt
        )
        return true
    }

    private static func processWithBackend(
        _ record: FrameRecord,
        source: SourceProfile,
        route: R03ScaleRoute,
        runtime: R13ReleaseJobRuntime,
        session: any AppleUpscaleSession,
        mediaSession: MediaSession,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws {
        let normalized = try runtime.normalizer.normalize(
            record.pixelBuffer,
            codedResolution: source.codedResolution,
            presentationResolution: source.resolution,
            pixelAspectRatio: source.pixelAspectRatio
        )
        let inputTokenIdentity =
            "r13.a11.input.\(runtime.modeBinding.requestedMode.rawValue).\(record.frameIndex)"
        let inputToken = try AppleUpscaleResourceLifetimeToken(
            identity: inputTokenIdentity,
            releaseAction: {
                runtime.inputReleaseObserver(inputTokenIdentity)
            }
        )
        let frame = try AppleUpscaleFrame(
            sequenceNumber: record.frameIndex,
            pixelBuffer: normalized,
            presentationTimestamp: record.presentationTime,
            duration: record.duration,
            colorDescription: R03NV12Contract.makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity(
                "r13.a11.frame.\(record.frameIndex)"
            ),
            resourceLifetimeToken: inputToken
        )
        let outcome = await session.submit(frame)
        try await handle(
            outcome,
            source: record,
            route: route,
            session: session,
            mediaSession: mediaSession,
            hardeningAttempt: hardeningAttempt
        )
    }

    private static func handle(
        _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
        source: FrameRecord,
        route: R03ScaleRoute,
        session: any AppleUpscaleSession,
        mediaSession: MediaSession,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws {
        switch outcome {
        case .processed(let processed):
            defer { processed.resourceLifetimeToken.release() }
            try R13ReleaseJobContracts.validate(
                processed,
                source: source,
                route: route,
                expectedProcessingIdentity: try AppleUpscaleProcessingIdentity(
                    route: await session.identity,
                    fallbackHistory: []
                )
            )
            try Task.checkCancellation()
            try await hardeningAttempt?.commit(
                pixelBuffer: processed.pixelBuffer,
                at: source.frameIndex
            )
            try await mediaSession.appendOutput(
                pixelBuffer: processed.pixelBuffer,
                timing: source.timing
            )
        case .unavailable(let unavailable):
            throw UpscalerEngineError.backendUnavailable(
                reason: unavailable.reason
            )
        case .rejected(let rejected):
            if Task.isCancelled || rejected.reason == "operation_cancelled" {
                throw UpscalerEngineError.cancelled
            }
            throw UpscalerEngineError.strategyFailed(
                "A11 rejected frame \(source.frameIndex): \(rejected.reason)"
            )
        case .failed(let failure):
            throw UpscalerEngineError.strategyFailed(
                "A11 failed frame \(source.frameIndex): \(failure.reason)"
            )
        }
    }
}
