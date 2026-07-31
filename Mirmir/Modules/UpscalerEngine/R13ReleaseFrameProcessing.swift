import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

// Preview encoding, emission, diagnostics, and frame processing share lifetime
// contracts that are kept in one source file for reviewability.
// swiftlint:disable file_length

protocol R13PreviewFrameEncoding: Sendable {
    func encode(
        source: CVPixelBuffer,
        processed: CVPixelBuffer,
        sourcePresentationResolution: VideoResolution,
        frameIndex: Int,
        presentationSeconds: Double,
        presentationTransform: CGAffineTransform
    ) throws -> UpscalePreviewFrame
}

enum R13PreviewFrameEncodingError: Error, Equatable, Sendable {
    case invalidSourceDimensions
    case invalidProcessedDimensions
    case aspectRatioMismatch
    case invalidPresentationTime
    case invalidPresentationTransform
    case bitmapAllocationFailed
    case payloadConstructionFailed

    var diagnosticCode: String {
        switch self {
        case .invalidSourceDimensions:
            return "invalid_source_dimensions"
        case .invalidProcessedDimensions:
            return "invalid_processed_dimensions"
        case .aspectRatioMismatch:
            return "aspect_ratio_mismatch"
        case .invalidPresentationTime:
            return "invalid_presentation_time"
        case .invalidPresentationTransform:
            return "invalid_presentation_transform"
        case .bitmapAllocationFailed:
            return "bitmap_allocation_failed"
        case .payloadConstructionFailed:
            return "payload_construction_failed"
        }
    }
}

enum R13PreviewFailureStage: String, Equatable, Sendable {
    case sourcePreparation = "source_preparation"
    case frameEncoding = "frame_encoding"
}

private struct R13PreviewUnderlyingErrorSnapshot: Equatable, Sendable {
    // swiftlint:disable:next large_tuple
    typealias Details = (reason: String, status: Int?, plane: Int?)

    let diagnosticTypeCode: String
    let sourcePreparationReasonCode: String
    let domain: String
    let underlyingNSErrorCode: Int
    let statusCode: Int?
    let planeIndex: Int?

    init(_ error: Error) {
        let nsError = error as NSError
        domain = nsError.domain
        underlyingNSErrorCode = nsError.code
        if error is R13PreviewFrameEncodingError {
            diagnosticTypeCode = "preview_frame_encoding_error"
            sourcePreparationReasonCode =
                "preview_source_preparation_failed"
            statusCode = nil
            planeIndex = nil
        } else if let error = error as? PixelBufferBridgeError {
            let details = Self.details(error)
            diagnosticTypeCode = "pixel_buffer_bridge_error"
            sourcePreparationReasonCode = details.reason
            statusCode = details.status
            planeIndex = details.plane
        } else if let error = error as? R03NV12ScalingError {
            let details = Self.details(error)
            diagnosticTypeCode = "nv12_scaling_error"
            sourcePreparationReasonCode = details.reason
            statusCode = details.status
            planeIndex = details.plane
        } else {
            diagnosticTypeCode = "opaque_error"
            sourcePreparationReasonCode =
                "preview_source_preparation_failed"
            statusCode = nil
            planeIndex = nil
        }
    }

    var diagnosticError: Error {
        NSError(domain: domain, code: underlyingNSErrorCode)
    }

    private static func details(
        _ error: PixelBufferBridgeError
    ) -> Details {
        switch error {
        case .invalidPoolDimensions:
            return ("source_invalid_pool_dimensions", nil, nil)
        case .invalidPoolCapacity:
            return ("source_invalid_pool_capacity", nil, nil)
        case .missingPoolCapacity:
            return ("source_missing_pool_capacity", nil, nil)
        case .poolCreationFailed(let status):
            return ("source_pool_creation_failed", Int(status), nil)
        case .poolDequeueFailed(
            kCVReturnWouldExceedAllocationThreshold
        ):
            return (
                "source_pool_allocation_threshold_exceeded",
                Int(kCVReturnWouldExceedAllocationThreshold),
                nil
            )
        case .poolDequeueFailed(let status):
            return ("source_pool_dequeue_failed", Int(status), nil)
        case .unsupportedPixelBufferFormat:
            return ("source_unsupported_pixel_buffer_format", nil, nil)
        case .invalidPlaneCount:
            return ("source_invalid_plane_count", nil, nil)
        case .invalidPlaneIndex(let index, _):
            return ("source_invalid_plane_index", nil, index)
        case .invalidPlaneDimensions(let index, _, _):
            return ("source_invalid_plane_dimensions", nil, index)
        case .metalTextureCreationFailed(let index, _, let status):
            return (
                "source_metal_texture_creation_failed",
                Int(status),
                index
            )
        case .metalTextureUnavailable(let index, _):
            return ("source_metal_texture_unavailable", nil, index)
        }
    }

    private static func details(
        _ error: R03NV12ScalingError
    ) -> Details {
        switch error {
        case .runtimeUnavailable:
            return ("source_scaling_runtime_unavailable", nil, nil)
        case .invalidPixelFormat:
            return ("source_invalid_pixel_format", nil, nil)
        case .invalidDimensions:
            return ("source_invalid_dimensions", nil, nil)
        case .invalidPlaneCount:
            return ("source_invalid_plane_count", nil, nil)
        case .invalidPlaneDimensions(let plane, _, _, _, _):
            return ("source_invalid_plane_dimensions", nil, plane)
        case .colorDescriptionMismatch:
            return ("source_color_description_mismatch", nil, nil)
        case .colorAttachmentMismatch:
            return ("source_color_attachment_mismatch", nil, nil)
        case .pixelBufferLockFailed(_, let status):
            return ("source_pixel_buffer_lock_failed", Int(status), nil)
        case .missingPlaneBaseAddress(let plane):
            return ("source_missing_plane_base_address", nil, plane)
        case .scalingFailed(let plane, let status):
            return ("source_scaling_failed", status, plane)
        case .operationCancelled:
            return ("source_normalization_cancelled", nil, nil)
        }
    }
}

struct R13PreviewEncodingFailure:
    Error,
    CustomNSError,
    CustomStringConvertible,
    Equatable,
    Sendable {
    let frameIndex: Int
    let stage: R13PreviewFailureStage
    let reasonCode: String
    private let underlyingError: R13PreviewUnderlyingErrorSnapshot

    init(
        frameIndex: Int,
        stage: R13PreviewFailureStage,
        underlyingError: Error
    ) {
        let snapshot = R13PreviewUnderlyingErrorSnapshot(underlyingError)
        self.frameIndex = frameIndex
        self.stage = stage
        self.underlyingError = snapshot
        switch stage {
        case .sourcePreparation:
            reasonCode = snapshot.sourcePreparationReasonCode
        case .frameEncoding:
            reasonCode =
                (underlyingError as? R13PreviewFrameEncodingError)?
                    .diagnosticCode
                ?? "preview_frame_encoding_failed"
        }
    }

    static let errorDomain = "Mirmir.R13PreviewEncodingFailure"

    var errorCode: Int {
        switch stage {
        case .sourcePreparation:
            return 1
        case .frameEncoding:
            return 2
        }
    }

    var errorUserInfo: [String: Any] {
        [
            NSUnderlyingErrorKey:
                underlyingError.diagnosticError as NSError
        ]
    }

    var diagnosticFields: [MirmirDiagnosticField] {
        var fields = [
            Self.field(
                key: "frame_index",
                value: .unsignedInteger(
                    UInt64(max(frameIndex, 0))
                )
            ),
            Self.identifierField(
                key: "preview_failure_stage",
                value: stage.rawValue
            ),
            Self.identifierField(
                key: "preview_failure_reason",
                value: reasonCode
            ),
            Self.identifierField(
                key: "preview_underlying_error_type",
                value: underlyingError.diagnosticTypeCode
            ),
            Self.field(
                key: "preview_underlying_error_code",
                value: .signedInteger(
                    Int64(
                        truncatingIfNeeded:
                            underlyingError.underlyingNSErrorCode
                    )
                )
            )
        ].compactMap { $0 }
        if let statusCode = underlyingError.statusCode,
           let statusField = Self.field(
               key: "preview_status_code",
               value: .signedInteger(
                   Int64(truncatingIfNeeded: statusCode)
                )
           ) {
            fields.append(statusField)
        }
        if let planeIndex = underlyingError.planeIndex,
           let planeField = Self.field(
               key: "preview_plane_index",
               value: .signedInteger(
                   Int64(truncatingIfNeeded: planeIndex)
                )
           ) {
            fields.append(planeField)
        }
        return fields
    }

    var description: String {
        "Preview \(stage.rawValue) failed at frame \(frameIndex): \(reasonCode)"
    }

    private static func field(
        key: String,
        value: MirmirDiagnosticFieldValue
    ) -> MirmirDiagnosticField? {
        try? MirmirDiagnosticField(key: key, value: value)
    }

    private static func identifierField(
        key: String,
        value: String
    ) -> MirmirDiagnosticField? {
        guard let value =
            try? MirmirDiagnosticFieldValue.identifier(value) else {
            return nil
        }
        return field(key: key, value: value)
    }
}

final class R13PreviewFrameEncoder: R13PreviewFrameEncoding,
    @unchecked Sendable {
    private let context = CIContext(options: [
        .cacheIntermediates: false
    ])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    func encode(
        source: CVPixelBuffer,
        processed: CVPixelBuffer,
        sourcePresentationResolution: VideoResolution,
        frameIndex: Int,
        presentationSeconds: Double,
        presentationTransform: CGAffineTransform
    ) throws -> UpscalePreviewFrame {
        guard presentationSeconds.isFinite else {
            throw R13PreviewFrameEncodingError.invalidPresentationTime
        }
        guard Self.isValid(presentationTransform) else {
            throw R13PreviewFrameEncodingError.invalidPresentationTransform
        }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard sourceWidth > 0,
              sourceHeight > 0,
              Self.normalizedDimension(
                  sourceWidth,
                  represents: sourcePresentationResolution.width
              ),
              Self.normalizedDimension(
                  sourceHeight,
                  represents: sourcePresentationResolution.height
              ) else {
            throw R13PreviewFrameEncodingError.invalidSourceDimensions
        }
        let processedWidth = CVPixelBufferGetWidth(processed)
        let processedHeight = CVPixelBufferGetHeight(processed)
        guard processedWidth > 0, processedHeight > 0 else {
            throw R13PreviewFrameEncodingError.invalidProcessedDimensions
        }
        let processedResolution = VideoResolution(
            width: processedWidth,
            height: processedHeight
        )
        guard R13AspectRatioContract.preservesWithinOneOutputPixel(
            source: sourcePresentationResolution,
            target: processedResolution
        ) else {
            throw R13PreviewFrameEncodingError.aspectRatioMismatch
        }

        let dimensions = Self.previewDimensions(
            width: sourcePresentationResolution.width,
            height: sourcePresentationResolution.height,
            presentationTransform: presentationTransform
        )
        let sourceImage = try makeImage(
            from: source,
            width: dimensions.width,
            height: dimensions.height,
            presentationTransform: presentationTransform
        )
        let processedImage = try makeImage(
            from: processed,
            width: dimensions.width,
            height: dimensions.height,
            presentationTransform: presentationTransform
        )
        guard let frame = UpscalePreviewFrame(
            frameIndex: frameIndex,
            presentationSeconds: presentationSeconds,
            source: sourceImage,
            processed: processedImage
        ) else {
            throw R13PreviewFrameEncodingError.payloadConstructionFailed
        }
        return frame
    }

    private static func normalizedDimension(
        _ actual: Int,
        represents presentation: Int
    ) -> Bool {
        guard presentation > 0 else { return false }
        if actual == presentation { return true }
        guard !presentation.isMultiple(of: 2) else { return false }
        let (rounded, overflow) = presentation.addingReportingOverflow(1)
        return !overflow && actual == rounded
    }

    static func previewDimensions(
        width: Int,
        height: Int,
        presentationTransform: CGAffineTransform = .identity
    ) -> (width: Int, height: Int) {
        guard width > 0,
              height > 0,
              isValid(presentationTransform) else {
            return (0, 0)
        }
        let presentedExtent = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
        .applying(presentationTransform)
        .standardized
        guard presentedExtent.width.isFinite,
              presentedExtent.height.isFinite,
              presentedExtent.width > 0,
              presentedExtent.height > 0 else {
            return (0, 0)
        }
        let scale = min(
            1,
            min(
                Double(UpscalePreviewImage.maximumWidth)
                    / Double(presentedExtent.width),
                Double(UpscalePreviewImage.maximumHeight)
                    / Double(presentedExtent.height)
            )
        )
        return (
            width: max(
                Int(
                    (Double(presentedExtent.width) * scale)
                        .rounded(.down)
                ),
                1
            ),
            height: max(
                Int(
                    (Double(presentedExtent.height) * scale)
                        .rounded(.down)
                ),
                1
            )
        )
    }

    private static func isValid(_ transform: CGAffineTransform) -> Bool {
        let components = [
            transform.a,
            transform.b,
            transform.c,
            transform.d,
            transform.tx,
            transform.ty
        ]
        let determinant =
            transform.a * transform.d - transform.b * transform.c
        return components.allSatisfy(\.isFinite)
            && determinant.isFinite
            && abs(determinant) > CGFloat.ulpOfOne
    }

    private func makeImage(
        from pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        presentationTransform: CGAffineTransform
    ) throws -> UpscalePreviewImage {
        guard width > 0, height > 0, let colorSpace else {
            throw R13PreviewFrameEncodingError.bitmapAllocationFailed
        }
        let bytesPerRow = width * UpscalePreviewImage.bytesPerPixel
        var data = Data(count: bytesPerRow * height)
        let presentedImage = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: presentationTransform)
        let presentedExtent = presentedImage.extent.standardized
        guard presentedExtent.width.isFinite,
              presentedExtent.height.isFinite,
              presentedExtent.width > 0,
              presentedExtent.height > 0 else {
            throw R13PreviewFrameEncodingError.invalidSourceDimensions
        }
        let translated = presentedImage.transformed(
            by: CGAffineTransform(
                translationX: -presentedExtent.minX,
                y: -presentedExtent.minY
            )
        )
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / presentedExtent.width,
                y: CGFloat(height) / presentedExtent.height
            )
        )
        let rendered = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            context.render(
                scaled,
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: colorSpace
            )
            return true
        }
        guard rendered else {
            throw R13PreviewFrameEncodingError.bitmapAllocationFailed
        }
        guard let image = UpscalePreviewImage(
            width: width,
            height: height,
            rgba8: data
        ) else {
            throw R13PreviewFrameEncodingError.payloadConstructionFailed
        }
        return image
    }
}

final class R13UpscalePreviewEmitter: @unchecked Sendable {
    typealias FailureObserver =
        @Sendable (R13PreviewEncodingFailure) -> Void

    private let encoder: any R13PreviewFrameEncoding
    private let continuation: AsyncStream<UpscalePreviewFrame>.Continuation
    private let minimumSampleInterval: Double
    private let minimumWallClockIntervalNanoseconds: UInt64
    private let monotonicTimeNanoseconds: @Sendable () -> UInt64
    private let failureObserver: FailureObserver
    private let lock = NSLock()
    private var isEncoding = false
    private var lastSampleTime: Double?
    private var lastWallClockTimeNanoseconds: UInt64?
    private var didFinish = false

    let stream: AsyncStream<UpscalePreviewFrame>

    init(
        encoder: any R13PreviewFrameEncoding = R13PreviewFrameEncoder(),
        minimumSampleInterval: Double = 0.5,
        minimumWallClockIntervalNanoseconds: UInt64 = 500_000_000,
        monotonicTimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        failureObserver: @escaping FailureObserver = { _ in }
    ) {
        self.encoder = encoder
        self.minimumSampleInterval = max(
            minimumSampleInterval.isFinite ? minimumSampleInterval : 0.5,
            0
        )
        self.minimumWallClockIntervalNanoseconds =
            minimumWallClockIntervalNanoseconds
        self.monotonicTimeNanoseconds = monotonicTimeNanoseconds
        self.failureObserver = failureObserver
        var continuation:
            AsyncStream<UpscalePreviewFrame>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func offer(
        source: () throws -> CVPixelBuffer,
        processed: CVPixelBuffer,
        sourcePresentationResolution: VideoResolution,
        frameIndex: Int,
        presentationTime: CMTime,
        presentationTransform: CGAffineTransform
    ) {
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        guard presentationSeconds.isFinite else { return }
        let wallClockTimeNanoseconds = monotonicTimeNanoseconds()
        let shouldEncode = lock.withLock { () -> Bool in
            guard !didFinish, !isEncoding else { return false }
            if let lastSampleTime,
               presentationSeconds - lastSampleTime
                < minimumSampleInterval {
                return false
            }
            if let lastWallClockTimeNanoseconds {
                guard wallClockTimeNanoseconds
                        >= lastWallClockTimeNanoseconds,
                      wallClockTimeNanoseconds
                        - lastWallClockTimeNanoseconds
                        >= minimumWallClockIntervalNanoseconds else {
                    return false
                }
            }
            isEncoding = true
            return true
        }
        guard shouldEncode else { return }
        defer {
            lock.withLock {
                isEncoding = false
            }
        }
        // The frame loop is asynchronous and does not provide a per-sample
        // autorelease boundary. Keep normalization and Core Image rendering
        // inside one boundary so transient framework references cannot occupy
        // every slot in the normalizer's threshold-bounded pixel-buffer pool.
        let result:
            Result<UpscalePreviewFrame, R13PreviewAttemptFailure> =
            autoreleasepool {
                let preparedSource: CVPixelBuffer
                do {
                    preparedSource = try source()
                } catch {
                    return .failure(.sourcePreparation(error))
                }
                do {
                    return .success(
                        try encoder.encode(
                            source: preparedSource,
                            processed: processed,
                            sourcePresentationResolution:
                                sourcePresentationResolution,
                            frameIndex: frameIndex,
                            presentationSeconds: presentationSeconds,
                            presentationTransform: presentationTransform
                        )
                    )
                } catch {
                    return .failure(.frameEncoding(error))
                }
            }
        switch result {
        case .success(let frame):
            lock.withLock {
                lastSampleTime = presentationSeconds
                lastWallClockTimeNanoseconds = wallClockTimeNanoseconds
            }
            continuation.yield(frame)
        case .failure(let failure):
            failureObserver(
                R13PreviewEncodingFailure(
                    frameIndex: frameIndex,
                    stage: failure.stage,
                    underlyingError: failure.underlyingError
                )
            )
        }
    }

    func finish() {
        let shouldFinish = lock.withLock { () -> Bool in
            guard !didFinish else { return false }
            didFinish = true
            return true
        }
        if shouldFinish {
            continuation.finish()
        }
    }
}

private enum R13PreviewAttemptFailure: Error {
    case sourcePreparation(Error)
    case frameEncoding(Error)

    var stage: R13PreviewFailureStage {
        switch self {
        case .sourcePreparation:
            return .sourcePreparation
        case .frameEncoding:
            return .frameEncoding
        }
    }

    var underlyingError: Error {
        switch self {
        case .sourcePreparation(let error),
             .frameEncoding(let error):
            return error
        }
    }
}

struct R13BackendFrameProcessingError:
    Error,
    CustomStringConvertible,
    Sendable {
    let frameIndex: Int
    let failure: AppleUpscaleBackendFailed

    var description: String {
        "The release scaler failed frame \(frameIndex): \(failure.reason)"
    }
}

extension R13ReleaseUpscalerJobHandle {
    static func processRecord(
        _ record: FrameRecord,
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile,
        route: R03ScaleRoute,
        mediaSession: MediaSession,
        upscaleBinding: R13ReleaseUpscaleSessionBinding,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws -> Bool {
        let disposition = try await hardeningAttempt?
            .disposition(forFrameAt: record.frameIndex)
        if disposition == .replayVerifiedCache {
            let replay = try await hardeningAttempt?
                .replayFrameWithRoutingDecision(
                    at: record.frameIndex
                )
            guard let replay else {
                throw UpscalerEngineError.strategyFailed(
                    "R13 cache replay did not return its verified frame."
                )
            }
            let normalizedSource = try runtime.normalizer.normalize(
                record.pixelBuffer,
                codedResolution: source.codedResolution,
                presentationResolution: source.resolution,
                pixelAspectRatio: source.pixelAspectRatio
            )
            if let routingDecision = replay.routingDecision {
                guard let replayer =
                    upscaleBinding.session
                        as? any R13ProductASHDecisionReplaying else {
                    throw UpscalerEngineError.strategyFailed(
                        "R13 routed cache replay requires a decision-aware session."
                    )
                }
                let tokenIdentity =
                    "r13.release.replay.input."
                    + "\(runtime.modeBinding.backendID)."
                    + "\(record.frameIndex)"
                let inputToken =
                    try AppleUpscaleResourceLifetimeToken(
                        identity: tokenIdentity,
                        releaseAction: {
                            runtime.inputReleaseObserver(
                                tokenIdentity
                            )
                        }
                    )
                let replayFrame: AppleUpscaleFrame
                do {
                    replayFrame = try AppleUpscaleFrame(
                        sequenceNumber: record.frameIndex,
                        pixelBuffer: normalizedSource,
                        presentationTimestamp:
                            record.presentationTime,
                        duration: record.duration,
                        colorDescription:
                            R03NV12Contract
                                .makeColorDescription(),
                        metadataIdentity:
                            AppleUpscaleMetadataIdentity(
                                "r13.release.replay.frame."
                                    + "\(runtime.modeBinding.backendID)."
                                    + "\(record.frameIndex)"
                            ),
                        resourceLifetimeToken: inputToken
                    )
                } catch {
                    inputToken.release()
                    throw error
                }
                try await replayer.replayCachedDecision(
                    replayFrame,
                    decision: routingDecision,
                    isFinalCachedPrefixFrame:
                        replay.isFinalCachedPrefixFrame,
                    requiresBackendWarmup:
                        replay.requiresBackendWarmup
                )
            }
            let pixelBuffer =
                try replay.frame.makeVideoRangePixelBuffer()
            try R03NV12Contract.validate(
                pixelBuffer: pixelBuffer,
                resolution: route.canonicalTargetResolution
            )
            if enhancementProcessor.temporalConsistencyEnabled {
                try enhancementProcessor.restoreTemporalHistory(
                    from: pixelBuffer
                )
            }
            try await mediaSession.appendOutput(
                pixelBuffer: pixelBuffer,
                timing: record.timing
            )
            runtime.previewEmitter.offer(
                source: { normalizedSource },
                processed: pixelBuffer,
                sourcePresentationResolution: source.resolution,
                frameIndex: record.frameIndex,
                presentationTime: record.presentationTime,
                presentationTransform: mediaSession.presentationTransform
            )
            return false
        }
        try await processWithBackend(
            record,
            source: source,
            route: route,
            runtime: runtime,
            session: upscaleBinding.session,
            upscaleBinding: upscaleBinding,
            mediaSession: mediaSession,
            enhancementProcessor: enhancementProcessor,
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
        upscaleBinding: R13ReleaseUpscaleSessionBinding,
        mediaSession: MediaSession,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
        hardeningAttempt: R13ReleaseHardeningAttempt?
    ) async throws {
        let normalized = try runtime.normalizer.normalize(
            record.pixelBuffer,
            codedResolution: source.codedResolution,
            presentationResolution: source.resolution,
            pixelAspectRatio: source.pixelAspectRatio
        )
        let inputTokenIdentity =
            "r13.release.input."
            + "\(runtime.modeBinding.backendID)."
            + "\(runtime.modeBinding.requestedMode.rawValue)."
            + "\(record.frameIndex)"
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
                "r13.release.frame."
                    + "\(runtime.modeBinding.backendID)."
                    + "\(record.frameIndex)"
            ),
            resourceLifetimeToken: inputToken
        )
        let outcome = await session.submit(frame)
        try await handle(
            outcome,
            source: record,
            normalizedSource: normalized,
            route: route,
            runtime: runtime,
            session: session,
            upscaleBinding: upscaleBinding,
            mediaSession: mediaSession,
            enhancementProcessor: enhancementProcessor,
            hardeningAttempt: hardeningAttempt
        )
    }

    private static func handle(
        _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
        source: FrameRecord,
        normalizedSource: CVPixelBuffer,
        route: R03ScaleRoute,
        runtime: R13ReleaseJobRuntime,
        session: any AppleUpscaleSession,
        upscaleBinding: R13ReleaseUpscaleSessionBinding,
        mediaSession: MediaSession,
        enhancementProcessor: R13ReleaseFormatEnhancementProcessor,
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
                ),
                admittedFrameRouteIdentities:
                    upscaleBinding.admittedFrameRouteIdentities
            )
            try Task.checkCancellation()
            let enhanced = try enhancementProcessor.process(
                processed.pixelBuffer
            )
            let cacheFrame = try R13NV12Frame.captureTightActivePlanes(
                from: enhanced
            )
            let routingDecision =
                try await routingDecisionEvent(
                    forFrameAt: source.frameIndex,
                    session: session
                )
            try await hardeningAttempt?.commit(
                frame: cacheFrame,
                routingDecision: routingDecision,
                at: source.frameIndex
            )
            try await mediaSession.appendOutput(
                pixelBuffer: enhanced,
                timing: source.timing
            )
            runtime.previewEmitter.offer(
                source: { normalizedSource },
                processed: enhanced,
                sourcePresentationResolution:
                    route.canonicalSourceResolution,
                frameIndex: source.frameIndex,
                presentationTime: source.presentationTime,
                presentationTransform: mediaSession.presentationTransform
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
                "The release scaler rejected frame "
                    + "\(source.frameIndex): \(rejected.reason)"
            )
        case .failed(let failure):
            throw R13BackendFrameProcessingError(
                frameIndex: source.frameIndex,
                failure: failure
            )
        }
    }

    private static func routingDecisionEvent(
        forFrameAt frameIndex: Int,
        session: any AppleUpscaleSession
    ) async throws -> R13ProductASHDecisionEvent? {
        guard let reporter =
            session as? any R13ProductASHDecisionReporting else {
            return nil
        }
        let matches = await reporter.decisionSummary()
            .events.filter {
                $0.sequenceNumber == frameIndex
            }
        guard matches.count == 1 else {
            throw UpscalerEngineError.strategyFailed(
                "R13 routed frame did not publish one exact decision event."
            )
        }
        return matches[0]
    }
}

// swiftlint:enable file_length
