import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os.lock
@testable import Mirmir

final class R13ReleaseTestEventLog: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())

    var events: [String] {
        state.withLock { $0 }
    }

    func record(_ event: String) {
        state.withLock { $0.append(event) }
    }

    func contains(_ event: String) -> Bool {
        state.withLock { $0.contains(event) }
    }
}

final class R13ReleaseSynchronousStartBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    var hasEntered: Bool {
        condition.withLock { entered }
    }

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

enum R13ReleaseTestFrames {
    static func make(
        resolution: VideoResolution,
        index: Int
    ) throws -> FrameRecord {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: R03NV12Contract.pixelFormat,
            capacity: 1
        )
        let buffer = try PixelBufferBridge.dequeue(from: pool)
        R03NV12Contract.installColorAttachments(on: buffer)
        return FrameRecord(
            pixelBuffer: buffer,
            timing: FrameTiming(
                frameIndex: index,
                presentationTime: CMTime(value: Int64(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30)
            )
        )
    }

    static func makeOutput(
        resolution: VideoResolution
    ) throws -> CVPixelBuffer {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: R03NV12Contract.pixelFormat,
            capacity: 1
        )
        let buffer = try PixelBufferBridge.dequeue(from: pool)
        R03NV12Contract.installColorAttachments(on: buffer)
        return buffer
    }
}

final class R13ReleaseTestMediaPipeline: MediaPipelineService,
    @unchecked Sendable {
    private struct State {
        var probeCount = 0
        var beginSessionCount = 0
        var lastSession: R13ReleaseTestMediaSession?
    }

    private let resolution: VideoResolution
    private let frames: [FrameRecord]
    private let videoFormat: MediaVideoFormat
    private let hasAudio: Bool
    private let eventLog: R13ReleaseTestEventLog
    private let terminalCleanupError: MediaPipelineError?
    private let presentationTransform: CGAffineTransform
    private let appendFailureFrameIndex: Int?
    private let captureAppendedFrames: Bool
    private let finishObserver: @Sendable () -> Void
    private let cancelObserver: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        resolution: VideoResolution,
        frames: [FrameRecord],
        eventLog: R13ReleaseTestEventLog,
        videoFormat: MediaVideoFormat = .sdrBT709,
        hasAudio: Bool = false,
        terminalCleanupError: MediaPipelineError? = nil,
        presentationTransform: CGAffineTransform = .identity,
        appendFailureFrameIndex: Int? = nil,
        captureAppendedFrames: Bool = false,
        finishObserver: @escaping @Sendable () -> Void = {},
        cancelObserver: @escaping @Sendable () -> Void = {}
    ) {
        self.resolution = resolution
        self.frames = frames
        self.videoFormat = videoFormat
        self.hasAudio = hasAudio
        self.eventLog = eventLog
        self.terminalCleanupError = terminalCleanupError
        self.presentationTransform = presentationTransform
        self.appendFailureFrameIndex = appendFailureFrameIndex
        self.captureAppendedFrames = captureAppendedFrames
        self.finishObserver = finishObserver
        self.cancelObserver = cancelObserver
    }

    var probeCount: Int {
        state.withLock { $0.probeCount }
    }

    var beginSessionCount: Int {
        state.withLock { $0.beginSessionCount }
    }

    var lastSession: R13ReleaseTestMediaSession? {
        state.withLock { $0.lastSession }
    }

    func probe(url: URL) async throws -> SourceProfile {
        state.withLock { $0.probeCount += 1 }
        eventLog.record("media.probe")
        return SourceProfile(
            url: url,
            resolution: resolution,
            frameRate: 30,
            durationSeconds: Double(frames.count) / 30,
            estimatedFrameCount: frames.count,
            codecHint: "r13-test",
            hasAudio: hasAudio,
            videoFormat: videoFormat
        )
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        let pool = try PixelBufferBridge.makePool(
            width: output.resolution.width,
            height: output.resolution.height,
            format:
                output.videoFormat?.pixelStorage.pixelFormat
                ?? PixelBufferBridge.preferredFormat,
            capacity: 1
        )
        let session = R13ReleaseTestMediaSession(
            sourceProfile: source,
            outputProfile: output,
            outputPixelBufferPool: pool,
            frames: frames,
            eventLog: eventLog,
            terminalCleanupError: terminalCleanupError,
            presentationTransform: presentationTransform,
            appendFailureFrameIndex: appendFailureFrameIndex,
            captureAppendedFrames: captureAppendedFrames,
            finishObserver: finishObserver,
            cancelObserver: cancelObserver
        )
        state.withLock { current in
            current.beginSessionCount += 1
            current.lastSession = session
        }
        eventLog.record("media.begin")
        return session
    }

    func start() {}
    func stop() {}
}

final class R13ReleaseTestMediaSession: MediaSession, @unchecked Sendable {
    private struct State {
        var nextFrameIndex = 0
        var appendedFrameIndices: [Int] = []
        var appendedTimings: [FrameTiming] = []
        var appendedFrames: [R13NV12Frame] = []
        var finalMetadata: [String: String] = [:]
        var finishCount = 0
        var cancelCount = 0
    }

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let outputPixelBufferPool: CVPixelBufferPool
    let terminalCleanupError: MediaPipelineError?
    let presentationTransform: CGAffineTransform

    private let frames: [FrameRecord]
    private let eventLog: R13ReleaseTestEventLog
    private let appendFailureFrameIndex: Int?
    private let captureAppendedFrames: Bool
    private let finishObserver: @Sendable () -> Void
    private let cancelObserver: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        sourceProfile: SourceProfile,
        outputProfile: OutputProfile,
        outputPixelBufferPool: CVPixelBufferPool,
        frames: [FrameRecord],
        eventLog: R13ReleaseTestEventLog,
        terminalCleanupError: MediaPipelineError?,
        presentationTransform: CGAffineTransform,
        appendFailureFrameIndex: Int?,
        captureAppendedFrames: Bool,
        finishObserver: @escaping @Sendable () -> Void,
        cancelObserver: @escaping @Sendable () -> Void
    ) {
        self.sourceProfile = sourceProfile
        self.outputProfile = outputProfile
        self.outputPixelBufferPool = outputPixelBufferPool
        self.frames = frames
        self.eventLog = eventLog
        self.terminalCleanupError = terminalCleanupError
        self.presentationTransform = presentationTransform
        self.appendFailureFrameIndex = appendFailureFrameIndex
        self.captureAppendedFrames = captureAppendedFrames
        self.finishObserver = finishObserver
        self.cancelObserver = cancelObserver
    }

    var appendedFrameIndices: [Int] {
        state.withLock { $0.appendedFrameIndices }
    }

    var appendedFrames: [R13NV12Frame] {
        state.withLock { $0.appendedFrames }
    }

    var appendedTimings: [FrameTiming] {
        state.withLock { $0.appendedTimings }
    }

    var finalMetadata: [String: String] {
        state.withLock { $0.finalMetadata }
    }

    var finishCount: Int {
        state.withLock { $0.finishCount }
    }

    var cancelCount: Int {
        state.withLock { $0.cancelCount }
    }

    func nextSourceFrame() async throws -> FrameRecord? {
        let frame = state.withLock { current -> FrameRecord? in
            guard current.nextFrameIndex < frames.count else { return nil }
            defer { current.nextFrameIndex += 1 }
            return frames[current.nextFrameIndex]
        }
        eventLog.record(
            frame.map { "media.next.\($0.frameIndex)" } ?? "media.eof"
        )
        return frame
    }

    func appendOutput(
        pixelBuffer: CVPixelBuffer,
        timing: FrameTiming
    ) async throws {
        if timing.frameIndex == appendFailureFrameIndex {
            eventLog.record("media.append.failed.\(timing.frameIndex)")
            throw R13ReleaseTestMediaSessionError.appendFailed(
                frameIndex: timing.frameIndex
            )
        }
        if captureAppendedFrames {
            let captured = try R13NV12Frame.captureTightActivePlanes(
                from: pixelBuffer
            )
            state.withLock {
                $0.appendedFrameIndices.append(timing.frameIndex)
                $0.appendedTimings.append(timing)
                $0.appendedFrames.append(captured)
            }
        } else {
            state.withLock {
                $0.appendedFrameIndices.append(timing.frameIndex)
                $0.appendedTimings.append(timing)
            }
        }
        eventLog.record("media.append.\(timing.frameIndex)")
    }

    func finish() async throws {
        state.withLock { $0.finishCount += 1 }
        eventLog.record("media.finish")
        finishObserver()
    }

    func finish(
        finalMetadata: [String: String]
    ) async throws {
        state.withLock {
            $0.finalMetadata = finalMetadata
        }
        try await finish()
    }

    func cancel() {
        state.withLock { $0.cancelCount += 1 }
        eventLog.record("media.cancel")
        cancelObserver()
    }
}

enum R13ReleaseTestMediaSessionError: Error, Equatable {
    case appendFailed(frameIndex: Int)
}

enum R13ReleaseTestAppleSessionBehavior: Sendable {
    case processed
    case failed(
        reason: String,
        context: AppleUpscaleBackendFailureContext?
    )
    case suspendUntilCancelled
}

struct R13ReleaseTestAppleSessionSnapshot: Equatable, Sendable {
    let submittedSequenceNumbers: [Int]
    let processedFrameCount: Int
    let finishCount: Int
    let cancelCount: Int
}

actor R13ReleaseTestAppleSession: AppleUpscaleSession {
    typealias OutputFiller =
        @Sendable (CVPixelBuffer, Int) throws -> Void

    nonisolated let identity: AppleUpscaleRouteIdentity

    private typealias PendingSubmit = (
        frame: AppleUpscaleFrame,
        continuation: CheckedContinuation<
            AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
            Never
        >
    )

    private let outputResolution: VideoResolution
    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let cancellationRejection: AppleUpscaleBackendRejected
    private let processingFailure: AppleUpscaleBackendFailed
    private let behavior: R13ReleaseTestAppleSessionBehavior
    private let eventLog: R13ReleaseTestEventLog
    private let outputFiller: OutputFiller
    private var submittedSequenceNumbers: [Int] = []
    private var processedFrameCount = 0
    private var finishCount = 0
    private var cancelCount = 0
    private var terminalizationCount = 0
    private var pendingSubmit: PendingSubmit?

    init(
        identity: AppleUpscaleRouteIdentity,
        outputResolution: VideoResolution,
        behavior: R13ReleaseTestAppleSessionBehavior,
        eventLog: R13ReleaseTestEventLog,
        outputFiller: @escaping OutputFiller
    ) throws {
        self.identity = identity
        self.outputResolution = outputResolution
        processingIdentity = try AppleUpscaleProcessingIdentity(
            route: identity,
            fallbackHistory: []
        )
        cancellationRejection = try AppleUpscaleBackendRejected(
            processingIdentity: processingIdentity,
            reason: "operation_cancelled"
        )
        processingFailure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "r13_test_output_creation_failed"
        )
        self.behavior = behavior
        self.eventLog = eventLog
        self.outputFiller = outputFiller
    }

    func submit(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        submittedSequenceNumbers.append(frame.sequenceNumber)
        eventLog.record("apple.submit.\(frame.sequenceNumber)")
        switch behavior {
        case .processed:
            return makeProcessedOutcome(frame)
        case .failed(let reason, let context):
            frame.resourceLifetimeToken.release()
            let failure = try? AppleUpscaleBackendFailed(
                processingIdentity: processingIdentity,
                reason: reason,
                context: context
            )
            return .failed(failure ?? processingFailure)
        case .suspendUntilCancelled:
            return await withCheckedContinuation { continuation in
                pendingSubmit = (frame, continuation)
            }
        }
    }

    func reset(reason _: AppleUpscaleResetReason) async {}

    func finish() async -> AppleUpscaleSessionSummary {
        finishCount += 1
        if terminalizationCount == 0 {
            terminalizationCount = 1
        }
        eventLog.record("apple.finish")
        return summary
    }

    func cancel() async {
        cancelCount += 1
        if terminalizationCount == 0 {
            terminalizationCount = 1
        }
        if let pendingSubmit {
            self.pendingSubmit = nil
            pendingSubmit.frame.resourceLifetimeToken.release()
            pendingSubmit.continuation.resume(
                returning: .rejected(cancellationRejection)
            )
        }
        eventLog.record("apple.cancel")
    }

    func snapshot() -> R13ReleaseTestAppleSessionSnapshot {
        R13ReleaseTestAppleSessionSnapshot(
            submittedSequenceNumbers: submittedSequenceNumbers,
            processedFrameCount: processedFrameCount,
            finishCount: finishCount,
            cancelCount: cancelCount
        )
    }

    private var summary: AppleUpscaleSessionSummary {
        AppleUpscaleSessionSummary(
            submittedFrameCount: submittedSequenceNumbers.count,
            processedFrameCount: processedFrameCount,
            terminalizationCount: terminalizationCount
        )
    }

    private func makeProcessedOutcome(
        _ frame: AppleUpscaleFrame
    ) -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        do {
            let output = try R13ReleaseTestFrames.makeOutput(
                resolution: outputResolution
            )
            let sequenceNumber = frame.sequenceNumber
            try outputFiller(output, sequenceNumber)
            let outputToken = try AppleUpscaleResourceLifetimeToken(
                identity: "r13.test.output.\(sequenceNumber)",
                releaseAction: { [eventLog] in
                    eventLog.record("output.release.\(sequenceNumber)")
                }
            )
            let processed = try AppleUpscaleProcessedFrame(
                sequenceNumber: sequenceNumber,
                pixelBuffer: output,
                presentationTimestamp: frame.presentationTimestamp,
                duration: frame.duration,
                colorDescription: frame.colorDescription,
                metadataIdentity: frame.metadataIdentity,
                resourceLifetimeToken: outputToken,
                processingIdentity: processingIdentity
            )
            frame.resourceLifetimeToken.release()
            processedFrameCount += 1
            return .processed(processed)
        } catch {
            frame.resourceLifetimeToken.release()
            return .failed(processingFailure)
        }
    }
}

final class R13ReleaseTestSessionFactory: @unchecked Sendable {
    private struct State {
        var routes: [R03ScaleRoute] = []
        var modeBindings: [R13ReleaseModeBinding] = []
        var sessions: [R03ScaleRoute: R13ReleaseTestAppleSession] = [:]
    }

    private let behavior: R13ReleaseTestAppleSessionBehavior
    private let eventLog: R13ReleaseTestEventLog
    private let outputFiller:
        R13ReleaseTestAppleSession.OutputFiller
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        behavior: R13ReleaseTestAppleSessionBehavior,
        eventLog: R13ReleaseTestEventLog,
        outputFiller:
            @escaping R13ReleaseTestAppleSession.OutputFiller = {
                _, _ in
            }
    ) {
        self.behavior = behavior
        self.eventLog = eventLog
        self.outputFiller = outputFiller
    }

    var routes: [R03ScaleRoute] {
        state.withLock { $0.routes }
    }

    var modeBindings: [R13ReleaseModeBinding] {
        state.withLock { $0.modeBindings }
    }

    func session(
        for route: R03ScaleRoute
    ) -> R13ReleaseTestAppleSession? {
        state.withLock { $0.sessions[route] }
    }

    func make(
        route: R03ScaleRoute
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        try await make(
            route: route,
            modeBinding: R13ReleaseModeBinding(
                requestedMode: .deterministic
            )
        )
    }

    func make(
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        eventLog.record("factory.\(route.rawValue)")
        let routeIdentity = try R13ReleaseIdentity.makeProductRoute(
            for: route,
            modeBinding: modeBinding
        )
        let session = try R13ReleaseTestAppleSession(
            identity: routeIdentity,
            outputResolution: route.canonicalTargetResolution,
            behavior: behavior,
            eventLog: eventLog,
            outputFiller: outputFiller
        )
        state.withLock { current in
            current.routes.append(route)
            current.modeBindings.append(modeBinding)
            current.sessions[route] = session
        }
        return R13ReleaseUpscaleSessionBinding(
            session: session,
            route: route,
            routeIdentity: routeIdentity
        )
    }
}
