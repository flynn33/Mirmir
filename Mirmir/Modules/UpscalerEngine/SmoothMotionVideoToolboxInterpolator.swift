import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum SmoothMotionNativeAvailabilityReason:
    String,
    Equatable,
    Sendable {
    case operatingSystemUnavailable = "operating_system_unavailable"
    case supportQueryRejected = "support_query_rejected"
    case configurationRejected = "configuration_rejected"
    case pixelFormatRejected = "pixel_format_rejected"
    case sessionStartFailed = "session_start_failed"

    static let allMetadataValues = [
        operatingSystemUnavailable.rawValue,
        supportQueryRejected.rawValue,
        configurationRejected.rawValue,
        pixelFormatRejected.rawValue,
        sessionStartFailed.rawValue
    ]
}

struct SmoothMotionInterpolatorSelection: Sendable {
    let native: (any SmoothMotionFrameInterpolating)?
    let nativeUnavailableReason: SmoothMotionNativeAvailabilityReason?
}

enum SmoothMotionInterpolatorFactory {
    static func makeNativeSelection(
        resolution: VideoResolution,
        pixelFormat: OSType,
        configuration: SmoothMotionConfiguration
    ) -> SmoothMotionInterpolatorSelection {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            guard
                VTLowLatencyFrameInterpolationConfiguration.isSupported
            else {
                return unavailable(.supportQueryRejected)
            }
            do {
                return SmoothMotionInterpolatorSelection(
                    native:
                        try SmoothMotionVideoToolboxInterpolator(
                            resolution: resolution,
                            pixelFormat: pixelFormat,
                            configuration: configuration
                        ),
                    nativeUnavailableReason: nil
                )
            } catch let error as SmoothMotionNativeSetupError {
                return unavailable(error.reason)
            } catch {
                return unavailable(.sessionStartFailed)
            }
        }
#endif
        return unavailable(.operatingSystemUnavailable)
    }

    private static func unavailable(
        _ reason: SmoothMotionNativeAvailabilityReason
    ) -> SmoothMotionInterpolatorSelection {
        SmoothMotionInterpolatorSelection(
            native: nil,
            nativeUnavailableReason: reason
        )
    }
}

private struct SmoothMotionNativeSetupError: Error {
    let reason: SmoothMotionNativeAvailabilityReason
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
final class SmoothMotionVideoToolboxInterpolator:
    SmoothMotionFrameInterpolating,
    @unchecked Sendable {
    let route: SmoothMotionInterpolationRoute =
        .videoToolboxLowLatency

    private let processor: VTFrameProcessor
    private let outputPool: CVPixelBufferPool
    private let resolution: VideoResolution
    private let pixelFormat: OSType
    private let stateLock = NSLock()
    private var isTerminated = false

    init(
        resolution: VideoResolution,
        pixelFormat: OSType,
        configuration: SmoothMotionConfiguration
    ) throws {
        self.resolution = resolution
        self.pixelFormat = pixelFormat
        guard
            let nativeConfiguration =
                VTLowLatencyFrameInterpolationConfiguration(
                    frameWidth: resolution.width,
                    frameHeight: resolution.height,
                    numberOfInterpolatedFrames:
                        configuration.cadence
                            .videoToolboxInterpolationLevel
                )
        else {
            throw SmoothMotionNativeSetupError(
                reason: .configurationRejected
            )
        }
        guard nativeConfiguration.supportedPixelFormats.contains(
            pixelFormat
        ) else {
            throw SmoothMotionNativeSetupError(
                reason: .pixelFormatRejected
            )
        }
        outputPool = try Self.makeOutputPool(
            resolution: resolution,
            pixelFormat: pixelFormat,
            requiredAttributes:
                nativeConfiguration.destinationPixelBufferAttributes,
            capacity: max(6, configuration.cadence.multiplier + 2)
        )
        processor = VTFrameProcessor()
        do {
            try processor.startSession(
                configuration: nativeConfiguration
            )
        } catch {
            throw SmoothMotionNativeSetupError(
                reason: .sessionStartFailed
            )
        }
    }

    deinit {
        terminate()
    }

    func interpolate(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        previousTime: CMTime,
        currentTime: CMTime,
        phases: [Float],
        presentationTimes: [CMTime]
    ) async throws -> [CVPixelBuffer] {
        guard phases.count == presentationTimes.count else {
            throw SmoothMotionInterpolationError
                .phaseTimestampCountMismatch
        }
        let inputFormat =
            try SmoothMotionPixelBufferContract.validatePair(
            previous: previous,
            current: current
        )
        guard inputFormat == pixelFormat else {
            throw SmoothMotionInterpolationError
                .unsupportedPixelFormat(inputFormat)
        }
        guard !stateLock.withLock({ isTerminated }) else {
            throw SmoothMotionInterpolationError.cancelled
        }
        for phase in phases where phase <= 0 || phase >= 1 {
            throw SmoothMotionInterpolationError.invalidPhase(phase)
        }
        guard
            let previousFrame = VTFrameProcessorFrame(
                buffer: previous,
                presentationTimeStamp: previousTime
            ),
            let currentFrame = VTFrameProcessorFrame(
                buffer: current,
                presentationTimeStamp: currentTime
            )
        else {
            throw SmoothMotionNativeSetupError(
                reason: .configurationRejected
            )
        }
        var destinationBuffers: [CVPixelBuffer] = []
        var destinationFrames: [VTFrameProcessorFrame] = []
        destinationBuffers.reserveCapacity(phases.count)
        destinationFrames.reserveCapacity(phases.count)
        for presentationTime in presentationTimes {
            let buffer = try PixelBufferBridge.dequeue(
                from: outputPool
            )
            guard let frame = VTFrameProcessorFrame(
                buffer: buffer,
                presentationTimeStamp: presentationTime
            ) else {
                throw SmoothMotionNativeSetupError(
                    reason: .configurationRejected
                )
            }
            destinationBuffers.append(buffer)
            destinationFrames.append(frame)
        }
        guard
            let parameters =
                VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: currentFrame,
                    previousFrame: previousFrame,
                    interpolationPhase: phases,
                    destinationFrames: destinationFrames
                )
        else {
            throw SmoothMotionNativeSetupError(
                reason: .configurationRejected
            )
        }
        try await process(parameters: parameters)
        for destination in destinationBuffers {
            SmoothMotionPixelBufferAttachments.copy(
                from: previous,
                to: destination
            )
        }
        return destinationBuffers
    }

    func finish() {
        terminate()
    }

    func cancel() {
        terminate()
    }

    private func process(
        parameters: VTLowLatencyFrameInterpolationParameters
    ) async throws {
        let completion = SmoothMotionVTCompletion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard completion.install(continuation) else {
                    return
                }
                processor.process(parameters: parameters) {
                    _, error in
                    completion.resolve(error)
                }
            }
        } onCancel: {
            completion.cancel()
            self.cancel()
        }
    }

    private func terminate() {
        let shouldEnd = stateLock.withLock { () -> Bool in
            guard !isTerminated else { return false }
            isTerminated = true
            return true
        }
        if shouldEnd {
            processor.endSession()
        }
    }

    private static func makeOutputPool(
        resolution: VideoResolution,
        pixelFormat: OSType,
        requiredAttributes: [String: Any],
        capacity: Int
    ) throws -> CVPixelBufferPool {
        var attributes = requiredAttributes
        attributes[kCVPixelBufferWidthKey as String] =
            NSNumber(value: resolution.width)
        attributes[kCVPixelBufferHeightKey as String] =
            NSNumber(value: resolution.height)
        attributes[kCVPixelBufferPixelFormatTypeKey as String] =
            NSNumber(value: pixelFormat)
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] =
            [String: Any]()
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String:
                NSNumber(value: capacity)
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw PixelBufferBridgeError.poolCreationFailed(status)
        }
        return pool
    }
}

@available(macOS 26.0, *)
private final class SmoothMotionVTCompletion:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(
        _ continuation: CheckedContinuation<Void, Error>
    ) -> Bool {
        let pendingResult = lock.withLock {
            () -> Result<Void, Error>? in
            if let result {
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let pendingResult {
            continuation.resume(with: pendingResult)
            return false
        }
        return true
    }

    func resolve(_ error: Error?) {
        complete(
            error.map(Result.failure) ?? .success(())
        )
    }

    func cancel() {
        complete(
            .failure(SmoothMotionInterpolationError.cancelled)
        )
    }

    private func complete(_ result: Result<Void, Error>) {
        let pendingContinuation = lock.withLock {
            () -> CheckedContinuation<Void, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        pendingContinuation?.resume(with: result)
    }
}
#endif
