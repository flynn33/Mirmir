import CoreMedia
import Foundation

enum R13AspectRatioContract {
    private typealias FullWidthProduct = (high: UInt, low: UInt)

    static func preservesWithinOneOutputPixel(
        source: VideoResolution,
        target: VideoResolution
    ) -> Bool {
        guard source.width > 0,
              source.height > 0,
              target.width > 0,
              target.height > 0 else {
            return false
        }

        // Compare the exact rational width projection without an overflowing
        // Int multiplication or a precision-losing floating-point division:
        //
        // |target.width - source.width * target.height / source.height| <= 1
        //
        // Multiplying by the positive source height gives the equivalent
        // integer inequality below. UInt.multipliedFullWidth retains every
        // product bit for every positive Int value supported by this process.
        let actualWidthProduct = UInt(target.width).multipliedFullWidth(
            by: UInt(source.height)
        )
        let projectedWidthProduct = UInt(source.width).multipliedFullWidth(
            by: UInt(target.height)
        )
        let difference = magnitudeDifference(
            actualWidthProduct,
            projectedWidthProduct
        )
        return difference.high == 0
            && difference.low <= UInt(source.height)
    }

    private static func magnitudeDifference(
        _ lhs: FullWidthProduct,
        _ rhs: FullWidthProduct
    ) -> FullWidthProduct {
        isLess(lhs, than: rhs)
            ? subtract(rhs, lhs)
            : subtract(lhs, rhs)
    }

    private static func isLess(
        _ lhs: FullWidthProduct,
        than rhs: FullWidthProduct
    ) -> Bool {
        lhs.high < rhs.high
            || (lhs.high == rhs.high && lhs.low < rhs.low)
    }

    private static func subtract(
        _ larger: FullWidthProduct,
        _ smaller: FullWidthProduct
    ) -> FullWidthProduct {
        let (low, borrowed) = larger.low.subtractingReportingOverflow(
            smaller.low
        )
        let highDifference = larger.high - smaller.high
        let (high, underflow) = highDifference
            .subtractingReportingOverflow(borrowed ? 1 : 0)
        precondition(!underflow)
        return (high, low)
    }
}

struct R13AdaptiveScalePlan: Equatable, Sendable {
    let sourceResolution: VideoResolution
    let processingSourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let configurationIdentity: String

    init(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution
    ) throws {
        guard sourceResolution.width > 0,
              sourceResolution.height > 0,
              targetResolution.width > 0,
              targetResolution.height > 0,
              targetResolution.width.isMultiple(of: 2),
              targetResolution.height.isMultiple(of: 2),
              targetResolution.width >= sourceResolution.width,
              targetResolution.height >= sourceResolution.height,
              targetResolution != sourceResolution,
              R13AspectRatioContract.preservesWithinOneOutputPixel(
                  source: sourceResolution,
                  target: targetResolution
              ) else {
            throw UpscaleStrategyError.unsupportedResolutionPair(
                source: sourceResolution,
                target: targetResolution
            )
        }
        let processingSourceResolution = try VideoResolution(
            width: Self.evenCeiling(sourceResolution.width),
            height: Self.evenCeiling(sourceResolution.height)
        )
        self.sourceResolution = sourceResolution
        self.processingSourceResolution =
            processingSourceResolution
        self.targetResolution = targetResolution
        configurationIdentity =
            "r13.mps.lanczos.adaptive."
            + "\(processingSourceResolution.width)x"
            + "\(processingSourceResolution.height)-to-"
            + "\(targetResolution.width)x"
            + "\(targetResolution.height).420v-bt709-video-left.v1"
    }

    private static func evenCeiling(_ value: Int) throws -> Int {
        guard value > 0 else {
            throw UpscalerEngineError.strategyFailed(
                "Adaptive source dimensions must be positive."
            )
        }
        if value.isMultiple(of: 2) { return value }
        let (result, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw UpscalerEngineError.strategyFailed(
                "Adaptive source dimensions exceed the supported range."
            )
        }
        return result
    }

}

enum R13ReleaseScalePlan: Equatable, Sendable {
    case productQualified(R03ScaleRoute)
    case adaptiveMPSLanczos(R13AdaptiveScalePlan)
}

enum R13ReleaseJobContracts {
    static func scalePlan(
        source: VideoResolution,
        target: VideoResolution
    ) throws -> R13ReleaseScalePlan {
        if let route = try? route(source: source, target: target) {
            return .productQualified(route)
        }
        return .adaptiveMPSLanczos(
            try R13AdaptiveScalePlan(
                sourceResolution: source,
                targetResolution: target
            )
        )
    }

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
