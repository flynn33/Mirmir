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
    private let eventLog: R13ReleaseTestEventLog
    private let terminalCleanupError: MediaPipelineError?
    private let finishObserver: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        resolution: VideoResolution,
        frames: [FrameRecord],
        eventLog: R13ReleaseTestEventLog,
        terminalCleanupError: MediaPipelineError? = nil,
        finishObserver: @escaping @Sendable () -> Void = {}
    ) {
        self.resolution = resolution
        self.frames = frames
        self.eventLog = eventLog
        self.terminalCleanupError = terminalCleanupError
        self.finishObserver = finishObserver
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
            hasAudio: false
        )
    }

    func beginSession(
        source: SourceProfile,
        output: OutputProfile
    ) async throws -> MediaSession {
        let pool = try PixelBufferBridge.makePool(
            width: output.resolution.width,
            height: output.resolution.height,
            capacity: 1
        )
        let session = R13ReleaseTestMediaSession(
            sourceProfile: source,
            outputProfile: output,
            outputPixelBufferPool: pool,
            frames: frames,
            eventLog: eventLog,
            terminalCleanupError: terminalCleanupError,
            finishObserver: finishObserver
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
        var finishCount = 0
        var cancelCount = 0
    }

    let sourceProfile: SourceProfile
    let outputProfile: OutputProfile
    let outputPixelBufferPool: CVPixelBufferPool
    let terminalCleanupError: MediaPipelineError?

    private let frames: [FrameRecord]
    private let eventLog: R13ReleaseTestEventLog
    private let finishObserver: @Sendable () -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        sourceProfile: SourceProfile,
        outputProfile: OutputProfile,
        outputPixelBufferPool: CVPixelBufferPool,
        frames: [FrameRecord],
        eventLog: R13ReleaseTestEventLog,
        terminalCleanupError: MediaPipelineError?,
        finishObserver: @escaping @Sendable () -> Void
    ) {
        self.sourceProfile = sourceProfile
        self.outputProfile = outputProfile
        self.outputPixelBufferPool = outputPixelBufferPool
        self.frames = frames
        self.eventLog = eventLog
        self.terminalCleanupError = terminalCleanupError
        self.finishObserver = finishObserver
    }

    var appendedFrameIndices: [Int] {
        state.withLock { $0.appendedFrameIndices }
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
        pixelBuffer _: CVPixelBuffer,
        timing: FrameTiming
    ) async throws {
        state.withLock { $0.appendedFrameIndices.append(timing.frameIndex) }
        eventLog.record("media.append.\(timing.frameIndex)")
    }

    func finish() async throws {
        state.withLock { $0.finishCount += 1 }
        eventLog.record("media.finish")
        finishObserver()
    }

    func cancel() {
        state.withLock { $0.cancelCount += 1 }
        eventLog.record("media.cancel")
    }
}

enum R13ReleaseTestAppleSessionBehavior: Sendable {
    case processed
    case suspendUntilCancelled
}

struct R13ReleaseTestAppleSessionSnapshot: Equatable, Sendable {
    let submittedSequenceNumbers: [Int]
    let processedFrameCount: Int
    let finishCount: Int
    let cancelCount: Int
}

actor R13ReleaseTestAppleSession: AppleUpscaleSession {
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
        eventLog: R13ReleaseTestEventLog
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
    }

    func submit(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        submittedSequenceNumbers.append(frame.sequenceNumber)
        eventLog.record("apple.submit.\(frame.sequenceNumber)")
        switch behavior {
        case .processed:
            return makeProcessedOutcome(frame)
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
        var sessions: [R03ScaleRoute: R13ReleaseTestAppleSession] = [:]
    }

    private let behavior: R13ReleaseTestAppleSessionBehavior
    private let eventLog: R13ReleaseTestEventLog
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        behavior: R13ReleaseTestAppleSessionBehavior,
        eventLog: R13ReleaseTestEventLog
    ) {
        self.behavior = behavior
        self.eventLog = eventLog
    }

    var routes: [R03ScaleRoute] {
        state.withLock { $0.routes }
    }

    func session(
        for route: R03ScaleRoute
    ) -> R13ReleaseTestAppleSession? {
        state.withLock { $0.sessions[route] }
    }

    func make(
        route: R03ScaleRoute
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        eventLog.record("factory.\(route.rawValue)")
        let backend = try R03DeterministicBackend
            .makeProductQualifiedMPSLanczos(route: route)
        let session = try R13ReleaseTestAppleSession(
            identity: backend.routeIdentity,
            outputResolution: route.canonicalTargetResolution,
            behavior: behavior,
            eventLog: eventLog
        )
        state.withLock { current in
            current.routes.append(route)
            current.sessions[route] = session
        }
        return R13ReleaseUpscaleSessionBinding(
            session: session,
            route: route,
            routeIdentity: backend.routeIdentity
        )
    }
}
