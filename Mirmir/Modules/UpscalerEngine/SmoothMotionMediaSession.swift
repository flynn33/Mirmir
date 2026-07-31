import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

enum SmoothMotionDiagnosticEventKind:
    String,
    Equatable,
    Sendable {
    case routeSelected = "route_selected"
    case nativeUnavailable = "native_unavailable"
    case nativeProcessingFallback = "native_processing_fallback"
    case sceneCutHold = "scene_cut_hold"
    case sceneAnalysisHold = "scene_analysis_hold"
    case completed
    case cancelled
}

struct SmoothMotionDiagnosticEvent: Equatable, Sendable {
    let kind: SmoothMotionDiagnosticEventKind
    let frameIndex: Int?
    let route: SmoothMotionInterpolationRoute?
    let reason: String?
    let meanNormalizedLumaDifference: Double?
    let changedSampleRatio: Double?
    let generatedFrameCount: Int?
}

struct SmoothMotionProcessingSummary: Equatable, Sendable {
    let cadenceMultiplier: Int
    let sourceFrameCount: Int
    let outputFrameCount: Int
    let generatedFrameCount: Int
    let interpolatedFrameCount: Int
    let heldFrameCount: Int
    let sceneCutCount: Int
    let sceneAnalysisFailureCount: Int
    let nativeRuntimeFallbackCount: Int
    let outputFramesPerSecond: Double
    let route: String
    let fallbackReason: String
}

struct SmoothMotionDecisionMetadata: Equatable, Sendable {
    static let routeKey =
        "com.mirmir.release.smooth-motion-route"
    static let cadenceMultiplierKey =
        "com.mirmir.release.smooth-motion-cadence-multiplier"
    static let sourceFrameCountKey =
        "com.mirmir.release.smooth-motion-source-frame-count"
    static let outputFrameCountKey =
        "com.mirmir.release.smooth-motion-output-frame-count"
    static let generatedFrameCountKey =
        "com.mirmir.release.smooth-motion-generated-frame-count"
    static let interpolatedFrameCountKey =
        "com.mirmir.release.smooth-motion-interpolated-frame-count"
    static let heldFrameCountKey =
        "com.mirmir.release.smooth-motion-held-frame-count"
    static let sceneCutCountKey =
        "com.mirmir.release.smooth-motion-scene-cut-count"
    static let sceneAnalysisFailureCountKey =
        "com.mirmir.release.smooth-motion-scene-analysis-failure-count"
    static let nativeRuntimeFallbackCountKey =
        "com.mirmir.release.smooth-motion-native-runtime-fallback-count"
    static let outputFrameRateKey =
        "com.mirmir.release.smooth-motion-output-frame-rate"
    static let fallbackReasonKey =
        "com.mirmir.release.smooth-motion-fallback-reason"

    static let pendingValues: [String: String] = [
        routeKey: "pending",
        cadenceMultiplierKey: "pending",
        sourceFrameCountKey: "pending",
        outputFrameCountKey: "pending",
        generatedFrameCountKey: "pending",
        interpolatedFrameCountKey: "pending",
        heldFrameCountKey: "pending",
        sceneCutCountKey: "pending",
        sceneAnalysisFailureCountKey: "pending",
        nativeRuntimeFallbackCountKey: "pending",
        outputFrameRateKey: "pending",
        fallbackReasonKey: "pending"
    ]

    let values: [String: String]

    init(summary: SmoothMotionProcessingSummary) {
        values = [
            Self.routeKey: summary.route,
            Self.cadenceMultiplierKey:
                String(summary.cadenceMultiplier),
            Self.sourceFrameCountKey:
                String(summary.sourceFrameCount),
            Self.outputFrameCountKey:
                String(summary.outputFrameCount),
            Self.generatedFrameCountKey:
                String(summary.generatedFrameCount),
            Self.interpolatedFrameCountKey:
                String(summary.interpolatedFrameCount),
            Self.heldFrameCountKey:
                String(summary.heldFrameCount),
            Self.sceneCutCountKey:
                String(summary.sceneCutCount),
            Self.sceneAnalysisFailureCountKey:
                String(summary.sceneAnalysisFailureCount),
            Self.nativeRuntimeFallbackCountKey:
                String(summary.nativeRuntimeFallbackCount),
            Self.outputFrameRateKey:
                String(format: "%.6f", summary.outputFramesPerSecond),
            Self.fallbackReasonKey: summary.fallbackReason
        ]
    }
}

final class SmoothMotionMediaSession:
    MediaSession,
    @unchecked Sendable {
    typealias DiagnosticObserver =
        @Sendable (SmoothMotionDiagnosticEvent) -> Void

    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let timing: FrameTiming
    }

    private let base: MediaSession
    private let configuration: SmoothMotionConfiguration
    private let planner: SmoothMotionCadencePlanner
    private let sceneCutDetector: any SmoothMotionSceneCutDetecting
    private let fallback: any SmoothMotionFrameInterpolating
    private let diagnosticObserver: DiagnosticObserver
    private let stateLock = NSLock()
    private var native: (any SmoothMotionFrameInterpolating)?
    private var nativeUnavailableReason:
        SmoothMotionNativeAvailabilityReason?
    private var pending: PendingFrame?
    private var expectedSourceFrameIndex = 0
    private var outputFrameIndex = 0
    private var generatedFrameCount = 0
    private var interpolatedFrameCount = 0
    private var heldFrameCount = 0
    private var sceneCutCount = 0
    private var sceneAnalysisFailureCount = 0
    private var nativeRuntimeFallbackCount = 0
    private var usedRoutes: Set<SmoothMotionInterpolationRoute> = []
    private var firstOutputPresentationTime: CMTime?
    private var lastOutputEndTime: CMTime?
    private var didFlush = false
    private var isCancelled = false

    var sourceProfile: SourceProfile { base.sourceProfile }
    var outputProfile: OutputProfile { base.outputProfile }
    var videoFormat: MediaVideoFormat { base.videoFormat }
    var outputPixelBufferPool: CVPixelBufferPool {
        base.outputPixelBufferPool
    }
    var presentationTransform: CGAffineTransform {
        base.presentationTransform
    }
    var prepublicationOutputURL: URL {
        base.prepublicationOutputURL
    }
    var publishedOutputIdentity: MediaOutputPublicationIdentity? {
        base.publishedOutputIdentity
    }
    var terminalCleanupError: MediaPipelineError? {
        base.terminalCleanupError
    }

    static func make(
        base: MediaSession,
        configuration: SmoothMotionConfiguration,
        diagnosticObserver: @escaping DiagnosticObserver = { _ in }
    ) throws -> SmoothMotionMediaSession {
        let selection =
            SmoothMotionInterpolatorFactory.makeNativeSelection(
                resolution: base.outputProfile.resolution,
                pixelFormat: base.videoFormat.pixelStorage.pixelFormat,
                configuration: configuration
            )
        let fallback = try SmoothMotionDeterministicInterpolator(
            resolution: base.outputProfile.resolution,
            pixelFormat: base.videoFormat.pixelStorage.pixelFormat,
            capacity: max(6, configuration.cadence.multiplier + 2)
        )
        return SmoothMotionMediaSession(
            base: base,
            configuration: configuration,
            native: selection.native,
            nativeUnavailableReason:
                selection.nativeUnavailableReason,
            fallback: fallback,
            sceneCutDetector: SmoothMotionLumaSceneCutDetector(),
            diagnosticObserver: diagnosticObserver
        )
    }

    init(
        base: MediaSession,
        configuration: SmoothMotionConfiguration,
        native: (any SmoothMotionFrameInterpolating)?,
        nativeUnavailableReason:
            SmoothMotionNativeAvailabilityReason?,
        fallback: any SmoothMotionFrameInterpolating,
        sceneCutDetector: any SmoothMotionSceneCutDetecting,
        diagnosticObserver: @escaping DiagnosticObserver = { _ in }
    ) {
        self.base = base
        self.configuration = configuration
        self.native = native
        self.nativeUnavailableReason = nativeUnavailableReason
        self.fallback = fallback
        self.sceneCutDetector = sceneCutDetector
        self.diagnosticObserver = diagnosticObserver
        planner = SmoothMotionCadencePlanner(
            cadence: configuration.cadence
        )
        if let native {
            diagnosticObserver(
                SmoothMotionDiagnosticEvent(
                    kind: .routeSelected,
                    frameIndex: nil,
                    route: native.route,
                    reason: nil,
                    meanNormalizedLumaDifference: nil,
                    changedSampleRatio: nil,
                    generatedFrameCount: nil
                )
            )
        } else {
            diagnosticObserver(
                SmoothMotionDiagnosticEvent(
                    kind: .nativeUnavailable,
                    frameIndex: nil,
                    route: fallback.route,
                    reason: nativeUnavailableReason?.rawValue,
                    meanNormalizedLumaDifference: nil,
                    changedSampleRatio: nil,
                    generatedFrameCount: nil
                )
            )
        }
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        try await base.nextSourceFrame()
    }

    func appendOutput(
        pixelBuffer: CVPixelBuffer,
        timing: FrameTiming
    ) async throws {
        try checkCancellation()
        guard timing.frameIndex == expectedSourceFrameIndex else {
            throw FrameTimingLedgerError.unexpectedFrameIndex(
                expected: expectedSourceFrameIndex,
                actual: timing.frameIndex
            )
        }
        guard !didFlush else {
            throw SmoothMotionTimingError.nonMonotonicSubdivision
        }
        expectedSourceFrameIndex += 1
        let current = PendingFrame(
            pixelBuffer: pixelBuffer,
            timing: timing
        )
        if let previous = pending {
            try await emitSegment(
                previous: previous,
                current: current
            )
        }
        pending = current
    }

    func finish() async throws {
        try await flushPendingFrame()
        try await base.finish()
    }

    func finish(finalMetadata: [String: String]) async throws {
        try await flushPendingFrame()
        try await base.finish(finalMetadata: finalMetadata)
    }

    func finish(
        finalMetadata: [String: String],
        validatingBeforePublish:
            @escaping @Sendable () async throws -> Void
    ) async throws {
        try await flushPendingFrame()
        try await base.finish(
            finalMetadata: finalMetadata,
            validatingBeforePublish: validatingBeforePublish
        )
    }

    func finish(
        finalMetadata: [String: String],
        beforeReopen:
            @escaping @Sendable () async throws -> Void,
        validatingBeforePublish:
            @escaping @Sendable () async throws -> Void
    ) async throws {
        try await flushPendingFrame()
        try await base.finish(
            finalMetadata: finalMetadata,
            beforeReopen: beforeReopen,
            validatingBeforePublish: validatingBeforePublish
        )
    }

    func finalizedMetadata(
        base metadata: [String: String]
    ) async throws -> [String: String] {
        try await flushPendingFrame()
        var result = metadata
        result.merge(
            SmoothMotionDecisionMetadata(summary: summary).values
        ) { _, finalized in finalized }
        return result
    }

    func cancel() {
        let shouldCancel = stateLock.withLock { () -> Bool in
            guard !isCancelled else { return false }
            isCancelled = true
            return true
        }
        guard shouldCancel else { return }
        native?.cancel()
        fallback.cancel()
        base.cancel()
        diagnosticObserver(
            SmoothMotionDiagnosticEvent(
                kind: .cancelled,
                frameIndex: nil,
                route: nil,
                reason: nil,
                meanNormalizedLumaDifference: nil,
                changedSampleRatio: nil,
                generatedFrameCount: generatedFrameCount
            )
        )
    }

    var summary: SmoothMotionProcessingSummary {
        let initialReason =
            nativeUnavailableReason?.rawValue ?? "none"
        let fallbackReason =
            nativeRuntimeFallbackCount > 0
                ? "native_processing_failed"
                : initialReason
        return SmoothMotionProcessingSummary(
            cadenceMultiplier: configuration.cadence.multiplier,
            sourceFrameCount: expectedSourceFrameIndex,
            outputFrameCount: outputFrameIndex,
            generatedFrameCount: generatedFrameCount,
            interpolatedFrameCount: interpolatedFrameCount,
            heldFrameCount: heldFrameCount,
            sceneCutCount: sceneCutCount,
            sceneAnalysisFailureCount:
                sceneAnalysisFailureCount,
            nativeRuntimeFallbackCount:
                nativeRuntimeFallbackCount,
            outputFramesPerSecond: measuredOutputFramesPerSecond,
            route: routeSummary,
            fallbackReason: fallbackReason
        )
    }

    private func emitSegment(
        previous: PendingFrame,
        current: PendingFrame
    ) async throws {
        let timings = try planner.timings(
            for: previous.timing,
            endingAt: current.timing.presentationTime,
            outputStartIndex: outputFrameIndex
        )
        try await append(
            previous.pixelBuffer,
            timing: timings[0],
            generated: false,
            held: false
        )
        let generatedTimings = Array(timings.dropFirst())
        let sceneAnalysis: SmoothMotionSceneAnalysis
        do {
            sceneAnalysis = try sceneCutDetector.analyze(
                previous: previous.pixelBuffer,
                current: current.pixelBuffer,
                sensitivity:
                    configuration.sceneCutSensitivity
            )
        } catch {
            sceneAnalysisFailureCount += 1
            diagnosticObserver(
                SmoothMotionDiagnosticEvent(
                    kind: .sceneAnalysisHold,
                    frameIndex: previous.timing.frameIndex,
                    route: nil,
                    reason: String(describing: error),
                    meanNormalizedLumaDifference: nil,
                    changedSampleRatio: nil,
                    generatedFrameCount:
                        generatedTimings.count
                )
            )
            try await appendHeldFrames(
                previous.pixelBuffer,
                timings: generatedTimings
            )
            return
        }
        if sceneAnalysis.isSceneCut {
            sceneCutCount += 1
            diagnosticObserver(
                SmoothMotionDiagnosticEvent(
                    kind: .sceneCutHold,
                    frameIndex: previous.timing.frameIndex,
                    route: nil,
                    reason: nil,
                    meanNormalizedLumaDifference:
                        sceneAnalysis
                            .meanNormalizedLumaDifference,
                    changedSampleRatio:
                        sceneAnalysis.changedSampleRatio,
                    generatedFrameCount:
                        generatedTimings.count
                )
            )
            try await appendHeldFrames(
                previous.pixelBuffer,
                timings: generatedTimings
            )
            return
        }
        let phases = configuration.cadence.interpolationPhases
        let presentationTimes =
            generatedTimings.map(\.presentationTime)
        let frames = try await interpolatedFrames(
            previous: previous,
            current: current,
            phases: phases,
            presentationTimes: presentationTimes
        )
        guard frames.count == generatedTimings.count else {
            throw SmoothMotionInterpolationError
                .phaseTimestampCountMismatch
        }
        for (frame, timing) in zip(frames, generatedTimings) {
            try await append(
                frame,
                timing: timing,
                generated: true,
                held: false
            )
            interpolatedFrameCount += 1
        }
    }

    private func interpolatedFrames(
        previous: PendingFrame,
        current: PendingFrame,
        phases: [Float],
        presentationTimes: [CMTime]
    ) async throws -> [CVPixelBuffer] {
        if let native {
            do {
                let frames = try await native.interpolate(
                    previous: previous.pixelBuffer,
                    current: current.pixelBuffer,
                    previousTime:
                        previous.timing.presentationTime,
                    currentTime:
                        current.timing.presentationTime,
                    phases: phases,
                    presentationTimes: presentationTimes
                )
                usedRoutes.insert(native.route)
                return frames
            } catch {
                if Task.isCancelled
                    || error as? SmoothMotionInterpolationError
                        == .cancelled {
                    throw error
                }
                native.cancel()
                self.native = nil
                nativeUnavailableReason = nil
                nativeRuntimeFallbackCount += 1
                diagnosticObserver(
                    SmoothMotionDiagnosticEvent(
                        kind: .nativeProcessingFallback,
                        frameIndex: previous.timing.frameIndex,
                        route: fallback.route,
                        reason: String(describing: error),
                        meanNormalizedLumaDifference: nil,
                        changedSampleRatio: nil,
                        generatedFrameCount: phases.count
                    )
                )
            }
        }
        let frames = try await fallback.interpolate(
            previous: previous.pixelBuffer,
            current: current.pixelBuffer,
            previousTime: previous.timing.presentationTime,
            currentTime: current.timing.presentationTime,
            phases: phases,
            presentationTimes: presentationTimes
        )
        usedRoutes.insert(fallback.route)
        return frames
    }

    private func appendHeldFrames(
        _ pixelBuffer: CVPixelBuffer,
        timings: [FrameTiming]
    ) async throws {
        for timing in timings {
            try await append(
                pixelBuffer,
                timing: timing,
                generated: true,
                held: true
            )
        }
    }

    private func append(
        _ pixelBuffer: CVPixelBuffer,
        timing: FrameTiming,
        generated: Bool,
        held: Bool
    ) async throws {
        try checkCancellation()
        try await base.appendOutput(
            pixelBuffer: pixelBuffer,
            timing: timing
        )
        if firstOutputPresentationTime == nil {
            firstOutputPresentationTime = timing.presentationTime
        }
        lastOutputEndTime = CMTimeAdd(
            timing.presentationTime,
            timing.duration
        )
        outputFrameIndex += 1
        if generated {
            generatedFrameCount += 1
        }
        if held {
            heldFrameCount += 1
        }
    }

    private func flushPendingFrame() async throws {
        guard !didFlush else { return }
        try checkCancellation()
        didFlush = true
        guard let pending else { return }
        let timings = try planner.finalTimings(
            for: pending.timing,
            outputStartIndex: outputFrameIndex
        )
        for (offset, timing) in timings.enumerated() {
            try await append(
                pending.pixelBuffer,
                timing: timing,
                generated: offset > 0,
                held: offset > 0
            )
        }
        self.pending = nil
        native?.finish()
        fallback.finish()
        diagnosticObserver(
            SmoothMotionDiagnosticEvent(
                kind: .completed,
                frameIndex: pending.timing.frameIndex,
                route: nil,
                reason: routeSummary,
                meanNormalizedLumaDifference: nil,
                changedSampleRatio: nil,
                generatedFrameCount: generatedFrameCount
            )
        )
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if stateLock.withLock({ isCancelled }) {
            throw SmoothMotionInterpolationError.cancelled
        }
    }

    private var routeSummary: String {
        let routes = usedRoutes.map(\.rawValue).sorted()
        if routes.isEmpty {
            return "frame_hold_only"
        }
        return routes.joined(separator: "+")
    }

    private var measuredOutputFramesPerSecond: Double {
        guard outputFrameIndex > 0,
              let firstOutputPresentationTime,
              let lastOutputEndTime else {
            return 0
        }
        let duration = CMTimeGetSeconds(
            CMTimeSubtract(
                lastOutputEndTime,
                firstOutputPresentationTime
            )
        )
        guard duration.isFinite, duration > 0 else {
            return 0
        }
        return Double(outputFrameIndex) / duration
    }
}

func finalizedSmoothMotionMetadata(
    _ metadata: [String: String],
    mediaSession: MediaSession
) async throws -> [String: String] {
    guard
        let smoothMotionSession =
            mediaSession as? SmoothMotionMediaSession
    else {
        return metadata
    }
    return try await smoothMotionSession.finalizedMetadata(
        base: metadata
    )
}
