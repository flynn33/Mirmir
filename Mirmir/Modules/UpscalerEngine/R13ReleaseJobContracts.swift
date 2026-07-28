import CoreMedia
import Foundation

enum R13ReleaseJobContracts {
    static func validate(
        _ binding: R13ReleaseUpscaleSessionBinding,
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding
    ) throws {
        guard binding.route == route,
              binding.routeIdentity.backend.backendID == modeBinding.backendID,
              binding.routeIdentity.backend.backendRevision
                == modeBinding.backendRevision,
              binding.routeIdentity.policyIdentity == modeBinding.policyIdentity,
              binding.routeIdentity.materialDecisionIdentity
                == modeBinding.materialDecisionIdentity,
              binding.routeIdentity.backend.modelAssetsIdentity == .notRequired,
              binding.routeIdentity.configurationIdentity
                == R03DeterministicBackendCatalog
                    .subject(R03A11ProductAdmission.subjectID)?
                    .configurationIdentity(for: route) else {
            throw UpscalerEngineError.strategyFailed(
                "Release mode did not resolve to the exact product-qualified A11 route."
            )
        }
    }

    static func validate(
        _ processed: AppleUpscaleProcessedFrame,
        source: FrameRecord,
        route: R03ScaleRoute,
        expectedProcessingIdentity: AppleUpscaleProcessingIdentity
    ) throws {
        guard processed.sequenceNumber == source.frameIndex,
              CMTimeCompare(
                  processed.presentationTimestamp,
                  source.presentationTime
              ) == 0,
              CMTimeCompare(processed.duration, source.duration) == 0,
              processed.processingIdentity == expectedProcessingIdentity,
              processed.processingIdentity.fallbackHistory.isEmpty else {
            throw UpscalerEngineError.strategyFailed(
                "A11 returned a frame outside the admitted FIFO identity contract."
            )
        }
        try R03NV12Contract.validate(
            colorDescription: processed.colorDescription
        )
        try R03NV12Contract.validate(
            pixelBuffer: processed.pixelBuffer,
            resolution: route.canonicalTargetResolution
        )
    }

    static func route(
        source: VideoResolution,
        target: VideoResolution
    ) throws -> R03ScaleRoute {
        if R03ScaleRoute.scale3Over2.matches(source: source, target: target) {
            return .scale3Over2
        }
        if R03ScaleRoute.scale2x.matches(source: source, target: target) {
            return .scale2x
        }
        throw UpscaleStrategyError.unsupportedResolutionPair(
            source: source,
            target: target
        )
    }

    static func yieldProgress(
        processedFrameCount: Int,
        estimatedTotalFrames: Int,
        startedAt: Date,
        terminal: Bool,
        continuation: AsyncStream<UpscaleProgress>.Continuation
    ) {
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let throughput = Double(processedFrameCount) / elapsed
        let reportedTotal = max(estimatedTotalFrames, processedFrameCount)
        let remaining = max(reportedTotal - processedFrameCount, 0)
        let eta = terminal
            ? 0
            : (
                estimatedTotalFrames > 0 && throughput > 0
                    ? Double(remaining) / throughput
                    : nil
            )
        continuation.yield(
            UpscaleProgress(
                framesProcessed: processedFrameCount,
                totalFrames: reportedTotal,
                throughputFPS: throughput,
                etaSeconds: eta
            )
        )
    }
}
