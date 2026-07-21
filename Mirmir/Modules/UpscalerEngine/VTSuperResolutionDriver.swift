import CoreMedia
import CoreVideo
import Foundation
import os.lock

#if compiler(>=6.2) && !targetEnvironment(simulator)
import VideoToolbox
#endif

// swiftlint:disable file_length

enum VTNativeSuperResolutionUnavailableReason: String, Equatable, Sendable {
    case nativeProcessorUnsupported = "native_processor_unsupported"
    case qualityScaleUnsupported = "quality_scale_unsupported"
    case qualityRevisionUnsupported = "quality_revision_unsupported"
    case qualityConfigurationUnavailable = "quality_configuration_unavailable"
    case qualityModelDownloadRequired = "quality_model_download_required"
    case qualityModelDownloading = "quality_model_downloading"
    case qualityModelStatusUnavailable = "quality_model_status_unavailable"
    case sessionEnded = "session_ended"
}

enum VTNativeSuperResolutionRejectionReason: String, Equatable, Sendable {
    case routeContractMismatch = "route_contract_mismatch"
    case exactDimensionScaleUnsupported = "exact_dimension_scale_unsupported"
    case unsupportedPixelFormat = "unsupported_pixel_format"
    case unresolvedPixelBufferAttributes = "unresolved_pixel_buffer_attributes"
    case iosurfaceRequired = "iosurface_required"
    case temporalContractMismatch = "temporal_contract_mismatch"
    case opticalFlowContractMismatch = "optical_flow_contract_mismatch"
    case operationCancelled = "operation_cancelled"
}

enum VTNativeSuperResolutionFailureReason: String, Equatable, Sendable {
    case pixelBufferPoolCreation = "pixel_buffer_pool_creation"
    case pixelBufferAllocation = "pixel_buffer_allocation"
    case pixelBufferCopy = "pixel_buffer_copy"
    case frameCreation = "frame_creation"
    case parameterCreation = "parameter_creation"
    case sessionStart = "session_start"
    case processing = "processing"
}

enum VTNativeSuperResolutionError: Error, Equatable, Sendable {
    case unavailable(VTNativeSuperResolutionUnavailableReason)
    case rejected(VTNativeSuperResolutionRejectionReason)
    case failed(VTNativeSuperResolutionFailureReason)
}

enum VTNativeLowLatencyScaleAdmission {
    static func construct<Configuration>(
        frameWidth: Int,
        frameHeight: Int,
        requestedScale: Float,
        query: () -> [Float],
        construct: () -> Configuration
    ) throws -> Configuration {
        guard frameWidth > 0, frameHeight > 0 else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
        let supportedScales = query()
        guard supportedScales.contains(requestedScale) else {
            throw VTNativeSuperResolutionError.rejected(
                .exactDimensionScaleUnsupported
            )
        }
        return construct()
    }
}

enum VTNativeQualityFlowConfiguration: String, Equatable, Sendable {
    case appleComputed = "apple_computed"
    case precomputed

    var usesPrecomputedFlow: Bool {
        self == .precomputed
    }

    func accepts(_ mode: R04VideoToolboxOpticalFlowMode) -> Bool {
        switch (self, mode) {
        case (.appleComputed, .disabled), (.appleComputed, .appleComputed),
             (.precomputed, .precomputed):
            return true
        default:
            return false
        }
    }
}

enum VTNativeQualityConfigurationAdmission {
    static func construct<Configuration>(
        scaleIsSupported: () -> Bool,
        revisionIsSupported: () -> Bool,
        construct: () -> Configuration?
    ) throws -> Configuration {
        guard scaleIsSupported() else {
            throw VTNativeSuperResolutionError.unavailable(
                .qualityScaleUnsupported
            )
        }
        guard revisionIsSupported() else {
            throw VTNativeSuperResolutionError.unavailable(
                .qualityRevisionUnsupported
            )
        }
        guard let configuration = construct() else {
            throw VTNativeSuperResolutionError.unavailable(
                .qualityConfigurationUnavailable
            )
        }
        return configuration
    }
}

enum VTNativeTemporalContinuity {
    static func isContiguous(
        previousSequenceNumber: Int,
        previousPresentationTimestamp: CMTime,
        previousDuration: CMTime,
        currentSequenceNumber: Int,
        currentPresentationTimestamp: CMTime,
        currentDuration: CMTime
    ) -> Bool {
        guard previousSequenceNumber < Int.max,
              currentSequenceNumber == previousSequenceNumber + 1,
              CMTimeCompare(currentDuration, previousDuration) == 0 else {
            return false
        }
        return CMTimeCompare(
            currentPresentationTimestamp,
            CMTimeAdd(previousPresentationTimestamp, previousDuration)
        ) == 0
    }
}

enum VTNativeConfigurationDiagnosticsFactory {
    static func quality(
        frameWidth: Int,
        frameHeight: Int,
        integerScaleFactor: Int,
        usesPrecomputedFlow: Bool,
        revision: Int,
        supportedPixelFormats: [OSType],
        modelStatus: R04VideoToolboxObservedModelStatus
    ) -> R04VideoToolboxConfigurationDiagnostics {
        R04VideoToolboxConfigurationDiagnostics(
            nativeIdentity: .quality(
                R04ObservedQualityConfiguration(
                    frameWidth: frameWidth,
                    frameHeight: frameHeight,
                    integerScaleFactor: integerScaleFactor,
                    inputType: .video,
                    usesPrecomputedFlow: usesPrecomputedFlow,
                    qualityPriority: .normal,
                    revision: revision
                )
            ),
            supportedPixelFormats: supportedPixelFormats,
            modelStatus: modelStatus,
            processingMode: .quality
        )
    }

    static func lowLatency(
        frameWidth: Int,
        frameHeight: Int,
        scaleFactor: Float,
        supportedPixelFormats: [OSType]
    ) -> R04VideoToolboxConfigurationDiagnostics {
        R04VideoToolboxConfigurationDiagnostics(
            nativeIdentity: .lowLatency(
                R04ObservedLowLatencyConfiguration(
                    frameWidth: frameWidth,
                    frameHeight: frameHeight,
                    scaleFactor: scaleFactor
                )
            ),
            supportedPixelFormats: supportedPixelFormats,
            modelStatus: .notRequired,
            processingMode: .lowLatency
        )
    }
}

#if compiler(>=6.2) && !targetEnvironment(simulator)
@available(macOS 26.0, *)
actor VTSuperResolutionDriver: R04VideoToolboxRuntime {
    private struct SessionKey: Hashable {
        let routeID: R04VideoToolboxRouteID
    }

    private let qualityFlowConfiguration: VTNativeQualityFlowConfiguration
    private var sessions: [SessionKey: any VTNativeSuperResolutionSession] = [:]
    private var activeProcessCount = 0
    private var endRequested = false

    init(
        qualityFlowConfiguration: VTNativeQualityFlowConfiguration = .appleComputed
    ) {
        self.qualityFlowConfiguration = qualityFlowConfiguration
    }

    func quality2xSupport(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Bool> {
        guard let configuration = try? VTNativeSRConfigurationBuilder
            .quality(
                sourceResolution: sourceResolution,
                flowConfiguration: qualityFlowConfiguration
            ) else {
            return .observed(false)
        }
        return .observed(
            configuration.supportedPixelFormats.contains(
                R04VideoToolboxRouteCatalog.pixelFormat
            )
        )
    }

    func lowLatencySupportedScaleFactors(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Set<R04VideoToolboxScaleFactor>> {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            return .observed([])
        }
        let values = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
            frameWidth: sourceResolution.width,
            frameHeight: sourceResolution.height
        )
        var scales = Set<R04VideoToolboxScaleFactor>()
        if values.contains(1.5) { scales.insert(.oneAndOneHalf) }
        if values.contains(2.0) { scales.insert(.two) }
        return .observed(scales)
    }

    func opticalFlowSupport(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Bool> {
        let revision = VTOpticalFlowConfiguration.defaultRevision
        guard VTOpticalFlowConfiguration.isSupported,
              VTOpticalFlowConfiguration.supportedRevisions.contains(
                  revision.rawValue
              ),
              let configuration = VTOpticalFlowConfiguration(
                  frameWidth: sourceResolution.width,
                  frameHeight: sourceResolution.height,
                  qualityPrioritization: .normal,
                  revision: revision
              ),
              configuration.frameWidth == sourceResolution.width,
              configuration.frameHeight == sourceResolution.height,
              configuration.qualityPrioritization == .normal,
              configuration.revision == revision else {
            return .observed(false)
        }
        return .observed(
            configuration.supportedPixelFormats.contains(
                R04VideoToolboxRouteCatalog.pixelFormat
            )
        )
    }

    func configurationDiagnostics(
        for route: R04VideoToolboxRouteDescriptor
    ) async -> R04VideoToolboxSupportObservation<
        R04VideoToolboxConfigurationDiagnostics
    > {
        guard !endRequested,
              R04VideoToolboxRouteCatalog.route(route.routeID) == route else {
            return .notObserved
        }
        do {
            switch route.backendKind {
            case .quality:
                let configuration = try VTNativeSRConfigurationBuilder
                    .quality(
                        sourceResolution: route.sourceResolution,
                        flowConfiguration: qualityFlowConfiguration
                    )
                guard configuration.frameWidth == route.sourceResolution.width,
                      configuration.frameHeight == route.sourceResolution.height,
                      route.scaleFactor.denominator == 1,
                      configuration.scaleFactor == route.scaleFactor.numerator,
                      configuration.inputType == .video,
                      configuration.usesPrecomputedFlow
                        == qualityFlowConfiguration.usesPrecomputedFlow,
                      configuration.qualityPrioritization == .normal else {
                    return .notObserved
                }
                let modelStatus = Self.observedModelStatus(
                    VTModelStager(
                        configuration: configuration,
                        acquisitionAuthority: .statusOnly
                    ).currentStatus()
                )
                return .observed(
                    VTNativeConfigurationDiagnosticsFactory.quality(
                        frameWidth: configuration.frameWidth,
                        frameHeight: configuration.frameHeight,
                        integerScaleFactor: configuration.scaleFactor,
                        usesPrecomputedFlow: configuration.usesPrecomputedFlow,
                        revision: configuration.revision.rawValue,
                        supportedPixelFormats: configuration.supportedPixelFormats,
                        modelStatus: modelStatus
                    )
                )
            case .lowLatency:
                let configuration = try VTNativeSRConfigurationBuilder
                    .lowLatency(route: route)
                guard configuration.frameWidth == route.sourceResolution.width,
                      configuration.frameHeight == route.sourceResolution.height else {
                    return .notObserved
                }
                return .observed(
                    VTNativeConfigurationDiagnosticsFactory.lowLatency(
                        frameWidth: configuration.frameWidth,
                        frameHeight: configuration.frameHeight,
                        scaleFactor: configuration.scaleFactor,
                        supportedPixelFormats: configuration.supportedPixelFormats
                    )
                )
            case .optionalFlowSupport:
                return .notObserved
            }
        } catch {
            return .notObserved
        }
    }

    func process(
        _ request: R04VideoToolboxProcessingRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> R04VideoToolboxRuntimeOutcome {
        guard !endRequested else {
            return .unavailable(.runtimeUnavailable)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .rejected(.operationCancelled)
        }

        do {
            let session = try session(for: request)
            activeProcessCount += 1
            defer {
                activeProcessCount -= 1
                endSessionsIfRequested()
            }
            let output = try await session.process(
                request,
                cancellation: cancellation
            )
            guard !cancellation.isCancelled, !Task.isCancelled else {
                return .rejected(.operationCancelled)
            }
            let retention = VTNativeOutputRetention(pixelBuffer: output)
            return .processed(
                R04VideoToolboxRuntimeOutput(
                    pixelBuffer: output,
                    releaseAction: { retention.release() }
                )
            )
        } catch let error as VTNativeSuperResolutionError {
            return Self.runtimeOutcome(for: error)
        } catch is CancellationError {
            return .rejected(.operationCancelled)
        } catch {
            return .failed(.runtimeProcessingFailed)
        }
    }

    func reset(
        _ request: R04VideoToolboxResetRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async {
        guard !cancellation.isCancelled else { return }
        let matchingKeys = sessions.keys.filter { $0.routeID == request.route.routeID }
        for key in matchingKeys {
            sessions.removeValue(forKey: key)?.end()
        }
    }

    func finish() async {
        endRequested = true
        endSessionsIfRequested()
    }

    func cancel() async {
        endRequested = true
        endSessionsIfRequested()
    }

    private func session(
        for request: R04VideoToolboxProcessingRequest
    ) throws -> any VTNativeSuperResolutionSession {
        guard R04VideoToolboxRouteCatalog.route(request.route.routeID)
                == request.route else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
        if request.route.backendKind == .quality,
           !qualityFlowConfiguration.accepts(request.opticalFlowMode) {
            throw VTNativeSuperResolutionError.rejected(
                .opticalFlowContractMismatch
            )
        }
        let key = SessionKey(routeID: request.route.routeID)
        if let session = sessions[key] { return session }

        let created: any VTNativeSuperResolutionSession
        switch request.route.backendKind {
        case .quality:
            guard request.route.routeID == .quality2x,
                  request.route.scaleFactor == .two else {
                throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
            }
            created = try VTNativeQualitySuperResolutionSession(
                route: request.route,
                flowConfiguration: qualityFlowConfiguration
            )
        case .lowLatency:
            created = try VTNativeLowLatencySuperResolutionSession(
                route: request.route
            )
        case .optionalFlowSupport:
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
        sessions[key] = created
        return created
    }

    private func endSessionsIfRequested() {
        guard endRequested, activeProcessCount == 0 else { return }
        let currentSessions = Array(sessions.values)
        sessions.removeAll(keepingCapacity: false)
        for session in currentSessions { session.end() }
    }

    private static func observedModelStatus(
        _ status: VTModelStagerStatus
    ) -> R04VideoToolboxObservedModelStatus {
        switch status {
        case .downloadRequired:
            return .downloadRequired
        case .downloading:
            return .downloading
        case .ready:
            return .ready
        case .unavailable:
            return .failed
        }
    }

    private static func runtimeOutcome(
        for error: VTNativeSuperResolutionError
    ) -> R04VideoToolboxRuntimeOutcome {
        switch error {
        case .unavailable:
            return .unavailable(.runtimeUnavailable)
        case .rejected(let reason):
            if reason == .operationCancelled {
                return .rejected(.operationCancelled)
            }
            if reason == .exactDimensionScaleUnsupported {
                return .rejected(.exactDimensionQueryRejected)
            }
            return .rejected(.runtimeRejected)
        case .failed:
            return .failed(.runtimeProcessingFailed)
        }
    }
}

@available(macOS 26.0, *)
private enum VTNativeSRConfigurationBuilder {
    static func quality(
        sourceResolution: VideoResolution,
        flowConfiguration: VTNativeQualityFlowConfiguration
    ) throws -> VTSuperResolutionScalerConfiguration {
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw VTNativeSuperResolutionError.unavailable(
                .nativeProcessorUnsupported
            )
        }
        let revision = VTSuperResolutionScalerConfiguration.defaultRevision
        return try VTNativeQualityConfigurationAdmission.construct(
            scaleIsSupported: {
                VTSuperResolutionScalerConfiguration.supportedScaleFactors
                    .contains(2)
            },
            revisionIsSupported: {
                VTSuperResolutionScalerConfiguration.supportedRevisions
                    .contains(revision.rawValue)
            },
            construct: {
                VTSuperResolutionScalerConfiguration(
                    frameWidth: sourceResolution.width,
                    frameHeight: sourceResolution.height,
                    scaleFactor: 2,
                    inputType: .video,
                    usePrecomputedFlow: flowConfiguration.usesPrecomputedFlow,
                    qualityPrioritization: .normal,
                    revision: revision
                )
            }
        )
    }

    static func lowLatency(
        route: R04VideoToolboxRouteDescriptor
    ) throws -> VTLowLatencySuperResolutionScalerConfiguration {
        guard route.backendKind == .lowLatency,
              VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              let scale = floatScale(for: route.scaleFactor) else {
            throw VTNativeSuperResolutionError.unavailable(
                .nativeProcessorUnsupported
            )
        }
        return try VTNativeLowLatencyScaleAdmission.construct(
            frameWidth: route.sourceResolution.width,
            frameHeight: route.sourceResolution.height,
            requestedScale: scale,
            query: {
                VTLowLatencySuperResolutionScalerConfiguration
                    .supportedScaleFactors(
                        frameWidth: route.sourceResolution.width,
                        frameHeight: route.sourceResolution.height
                    )
            },
            construct: {
                VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: route.sourceResolution.width,
                    frameHeight: route.sourceResolution.height,
                    scaleFactor: scale
                )
            }
        )
    }

    private static func floatScale(
        for value: R04VideoToolboxScaleFactor
    ) -> Float? {
        switch value {
        case .oneAndOneHalf:
            return 1.5
        case .two:
            return 2.0
        default:
            return nil
        }
    }
}

@available(macOS 26.0, *)
private protocol VTNativeSuperResolutionSession: AnyObject, Sendable {
    func process(
        _ request: R04VideoToolboxProcessingRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer
    func end()
}

@available(macOS 26.0, *)
private final class VTNativeQualitySuperResolutionSession:
    VTNativeSuperResolutionSession,
    @unchecked Sendable {
    private let route: R04VideoToolboxRouteDescriptor
    private let usesPrecomputedFlow: Bool
    private let processor: VTFrameProcessor
    private let sourcePool: VTNativePixelBufferPool
    private let destinationPool: VTNativePixelBufferPool

    private var previousSourceFrame: VTFrameProcessorFrame?
    private var previousOutputFrame: VTFrameProcessorFrame?
    private var previousSequenceNumber: Int?
    private var previousPresentationTimestamp: CMTime?
    private var previousDuration: CMTime?
    private var acceptedHistoryGeneration: UInt64?
    private var ended = false

    init(
        route: R04VideoToolboxRouteDescriptor,
        flowConfiguration: VTNativeQualityFlowConfiguration
    ) throws {
        let configuration = try VTNativeSRConfigurationBuilder
            .quality(
                sourceResolution: route.sourceResolution,
                flowConfiguration: flowConfiguration
            )
        guard configuration.supportedPixelFormats.contains(
            R04VideoToolboxRouteCatalog.pixelFormat
        ) else {
            throw VTNativeSuperResolutionError.rejected(.unsupportedPixelFormat)
        }

        switch VTModelStager(
            configuration: configuration,
            acquisitionAuthority: .statusOnly
        ).currentStatus() {
        case .ready:
            break
        case .downloadRequired:
            throw VTNativeSuperResolutionError.unavailable(
                .qualityModelDownloadRequired
            )
        case .downloading:
            throw VTNativeSuperResolutionError.unavailable(
                .qualityModelDownloading
            )
        case .unavailable:
            throw VTNativeSuperResolutionError.unavailable(
                .qualityModelStatusUnavailable
            )
        }

        self.route = route
        usesPrecomputedFlow = flowConfiguration.usesPrecomputedFlow
        sourcePool = try VTNativePixelBufferPool(
            requiredAttributes: configuration.sourcePixelBufferAttributes,
            resolution: route.sourceResolution,
            pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat
        )
        destinationPool = try VTNativePixelBufferPool(
            requiredAttributes: configuration.destinationPixelBufferAttributes,
            resolution: route.targetResolution,
            pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat
        )
        processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw VTNativeSuperResolutionError.failed(.sessionStart)
        }
    }

    deinit {
        if !ended { processor.endSession() }
    }

    func process(
        _ request: R04VideoToolboxProcessingRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer {
        guard !ended else {
            throw VTNativeSuperResolutionError.unavailable(.sessionEnded)
        }
        try validateTemporalContract(request)
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }

        let sourceBuffer = try sourcePool.stage(request.sourceFrame.pixelBuffer)
        let destinationBuffer = try destinationPool.makePixelBuffer()
        let sourceFrame = try Self.frame(
            sourceBuffer,
            timestamp: request.sourceFrame.presentationTimestamp
        )
        let destinationFrame = try Self.frame(
            destinationBuffer,
            timestamp: request.sourceFrame.presentationTimestamp
        )
        let opticalFlow = try makeOpticalFlow(for: request)
        let submissionMode: VTSuperResolutionScalerParameters.SubmissionMode =
            request.submissionMode == .sequential ? .sequential : .random
        guard let parameters = VTSuperResolutionScalerParameters(
            sourceFrame: sourceFrame,
            previousFrame: previousSourceFrame,
            previousOutputFrame: previousOutputFrame,
            opticalFlow: opticalFlow,
            submissionMode: submissionMode,
            destinationFrame: destinationFrame
        ) else {
            throw VTNativeSuperResolutionError.failed(.parameterCreation)
        }

        do {
            _ = try await processor.process(parameters: parameters)
        } catch {
            throw VTNativeSuperResolutionError.failed(.processing)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
        CVBufferPropagateAttachments(request.sourceFrame.pixelBuffer, destinationBuffer)
        previousSourceFrame = sourceFrame
        previousOutputFrame = destinationFrame
        previousSequenceNumber = request.sourceFrame.sequenceNumber
        previousPresentationTimestamp = request.sourceFrame.presentationTimestamp
        previousDuration = request.sourceFrame.duration
        acceptedHistoryGeneration = request.historyGeneration
        return destinationBuffer
    }

    func end() {
        guard !ended else { return }
        ended = true
        clearHistory()
        processor.endSession()
    }

    private func validateTemporalContract(
        _ request: R04VideoToolboxProcessingRequest
    ) throws {
        guard request.route == route else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
        switch request.historyBoundary {
        case .firstFrame:
            guard request.submissionMode == .random,
                  request.previousSource == nil,
                  request.previousOutput == nil else {
                throw VTNativeSuperResolutionError.rejected(
                    .temporalContractMismatch
                )
            }
            clearHistory()
        case .continuing:
            guard request.submissionMode == .sequential,
                  let suppliedPreviousSource = request.previousSource,
                  let suppliedPreviousOutput = request.previousOutput,
                  acceptedHistoryGeneration == request.historyGeneration,
                  let previousSequenceNumber,
                  suppliedPreviousSource.sequenceNumber == previousSequenceNumber,
                  suppliedPreviousOutput.sequenceNumber == previousSequenceNumber,
                  let previousPresentationTimestamp,
                  let previousDuration,
                  VTNativeTemporalContinuity.isContiguous(
                      previousSequenceNumber: previousSequenceNumber,
                      previousPresentationTimestamp: previousPresentationTimestamp,
                      previousDuration: previousDuration,
                      currentSequenceNumber: request.sourceFrame.sequenceNumber,
                      currentPresentationTimestamp: request.sourceFrame
                        .presentationTimestamp,
                      currentDuration: request.sourceFrame.duration
                  ),
                  CMTimeCompare(
                      suppliedPreviousSource.presentationTimestamp,
                      previousPresentationTimestamp
                  ) == 0,
                  CMTimeCompare(
                      suppliedPreviousOutput.presentationTimestamp,
                      previousPresentationTimestamp
                  ) == 0,
                  CMTimeCompare(
                      suppliedPreviousSource.duration,
                      previousDuration
                  ) == 0,
                  CMTimeCompare(
                      suppliedPreviousOutput.duration,
                      previousDuration
                  ) == 0,
                  previousSourceFrame != nil,
                  previousOutputFrame != nil else {
                throw VTNativeSuperResolutionError.rejected(
                    .temporalContractMismatch
                )
            }
        case .notApplicable:
            throw VTNativeSuperResolutionError.rejected(.temporalContractMismatch)
        }
    }

    private func makeOpticalFlow(
        for request: R04VideoToolboxProcessingRequest
    ) throws -> VTFrameProcessorOpticalFlow? {
        switch request.opticalFlowMode {
        case .disabled, .appleComputed:
            guard !usesPrecomputedFlow else {
                throw VTNativeSuperResolutionError.rejected(
                    .opticalFlowContractMismatch
                )
            }
            return nil
        case .precomputed(let flow):
            guard usesPrecomputedFlow else {
                throw VTNativeSuperResolutionError.rejected(
                    .opticalFlowContractMismatch
                )
            }
            if request.historyBoundary == .firstFrame { return nil }
            guard let wrapped = VTFrameProcessorOpticalFlow(
                forwardFlow: flow.forward,
                backwardFlow: flow.backward
            ) else {
                throw VTNativeSuperResolutionError.rejected(.iosurfaceRequired)
            }
            return wrapped
        }
    }

    private func clearHistory() {
        previousSourceFrame = nil
        previousOutputFrame = nil
        previousSequenceNumber = nil
        previousPresentationTimestamp = nil
        previousDuration = nil
        acceptedHistoryGeneration = nil
    }

    private static func frame(
        _ buffer: CVPixelBuffer,
        timestamp: CMTime
    ) throws -> VTFrameProcessorFrame {
        guard let frame = VTFrameProcessorFrame(
            buffer: buffer,
            presentationTimeStamp: timestamp
        ) else {
            throw VTNativeSuperResolutionError.failed(.frameCreation)
        }
        return frame
    }
}

@available(macOS 26.0, *)
private final class VTNativeLowLatencySuperResolutionSession:
    VTNativeSuperResolutionSession,
    @unchecked Sendable {
    private let route: R04VideoToolboxRouteDescriptor
    private let processor: VTFrameProcessor
    private let sourcePool: VTNativePixelBufferPool
    private let destinationPool: VTNativePixelBufferPool
    private var ended = false

    init(route: R04VideoToolboxRouteDescriptor) throws {
        let configuration = try VTNativeSRConfigurationBuilder
            .lowLatency(route: route)
        guard configuration.supportedPixelFormats.contains(
            R04VideoToolboxRouteCatalog.pixelFormat
        ) else {
            throw VTNativeSuperResolutionError.rejected(.unsupportedPixelFormat)
        }

        self.route = route
        sourcePool = try VTNativePixelBufferPool(
            requiredAttributes: configuration.sourcePixelBufferAttributes,
            resolution: route.sourceResolution,
            pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat
        )
        destinationPool = try VTNativePixelBufferPool(
            requiredAttributes: configuration.destinationPixelBufferAttributes,
            resolution: route.targetResolution,
            pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat
        )
        processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw VTNativeSuperResolutionError.failed(.sessionStart)
        }
    }

    deinit {
        if !ended { processor.endSession() }
    }

    func process(
        _ request: R04VideoToolboxProcessingRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer {
        guard !ended else {
            throw VTNativeSuperResolutionError.unavailable(.sessionEnded)
        }
        guard request.route == route,
              request.historyBoundary == .notApplicable,
              request.submissionMode == .random,
              request.previousSource == nil,
              request.previousOutput == nil else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
        guard case .disabled = request.opticalFlowMode else {
            throw VTNativeSuperResolutionError.rejected(
                .opticalFlowContractMismatch
            )
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }

        let sourceBuffer = try sourcePool.stage(request.sourceFrame.pixelBuffer)
        let destinationBuffer = try destinationPool.makePixelBuffer()
        guard let sourceFrame = VTFrameProcessorFrame(
            buffer: sourceBuffer,
            presentationTimeStamp: request.sourceFrame.presentationTimestamp
        ), let destinationFrame = VTFrameProcessorFrame(
            buffer: destinationBuffer,
            presentationTimeStamp: request.sourceFrame.presentationTimestamp
        ) else {
            throw VTNativeSuperResolutionError.failed(.frameCreation)
        }
        let parameters = VTLowLatencySuperResolutionScalerParameters(
            sourceFrame: sourceFrame,
            destinationFrame: destinationFrame
        )
        do {
            _ = try await processor.process(parameters: parameters)
        } catch {
            throw VTNativeSuperResolutionError.failed(.processing)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
        CVBufferPropagateAttachments(request.sourceFrame.pixelBuffer, destinationBuffer)
        return destinationBuffer
    }

    func end() {
        guard !ended else { return }
        ended = true
        processor.endSession()
    }

}

@available(macOS 26.0, *)
private final class VTNativePixelBufferPool: @unchecked Sendable {
    private let pool: CVPixelBufferPool
    private let resolution: VideoResolution
    private let pixelFormat: OSType

    init(
        requiredAttributes: [String: any Sendable],
        resolution: VideoResolution,
        pixelFormat: OSType
    ) throws {
        let clientAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var resolvedAttributes: CFDictionary?
        let resolveStatus = CVPixelBufferCreateResolvedAttributesDictionary(
            kCFAllocatorDefault,
            [
                requiredAttributes as CFDictionary,
                clientAttributes as CFDictionary
            ] as CFArray,
            &resolvedAttributes
        )
        guard resolveStatus == kCVReturnSuccess, let resolvedAttributes else {
            throw VTNativeSuperResolutionError.rejected(
                .unresolvedPixelBufferAttributes
            )
        }
        var createdPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            resolvedAttributes,
            &createdPool
        )
        guard poolStatus == kCVReturnSuccess, let createdPool else {
            throw VTNativeSuperResolutionError.failed(.pixelBufferPoolCreation)
        }
        pool = createdPool
        self.resolution = resolution
        self.pixelFormat = pixelFormat
    }

    func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VTNativeSuperResolutionError.failed(.pixelBufferAllocation)
        }
        guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            throw VTNativeSuperResolutionError.rejected(.iosurfaceRequired)
        }
        try validate(pixelBuffer)
        return pixelBuffer
    }

    func stage(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        try validate(source)
        let destination = try makePixelBuffer()
        try Self.copy(source: source, destination: destination)
        return destination
    }

    private func validate(_ pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetWidth(pixelBuffer) == resolution.width,
              CVPixelBufferGetHeight(pixelBuffer) == resolution.height,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == pixelFormat,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
    }

    private static func copy(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw VTNativeSuperResolutionError.failed(.pixelBufferCopy)
        }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            throw VTNativeSuperResolutionError.failed(.pixelBufferCopy)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard CVPixelBufferGetPlaneCount(source)
                == CVPixelBufferGetPlaneCount(destination) else {
            throw VTNativeSuperResolutionError.failed(.pixelBufferCopy)
        }
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard CVPixelBufferGetHeightOfPlane(source, plane)
                    == CVPixelBufferGetHeightOfPlane(destination, plane),
                  let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                      destination,
                      plane
                  ) else {
                throw VTNativeSuperResolutionError.failed(.pixelBufferCopy)
            }
            let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(
                destination,
                plane
            )
            let copiedBytes = min(sourceStride, destinationStride)
            for row in 0..<CVPixelBufferGetHeightOfPlane(source, plane) {
                memcpy(
                    destinationBase.advanced(by: row * destinationStride),
                    sourceBase.advanced(by: row * sourceStride),
                    copiedBytes
                )
            }
        }
        CVBufferPropagateAttachments(source, destination)
    }
}

private final class VTNativeOutputRetention: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var pixelBuffer: CVPixelBuffer?
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(pixelBuffer: CVPixelBuffer) {
        lock = OSAllocatedUnfairLock(
            initialState: State(pixelBuffer: pixelBuffer)
        )
    }

    func release() {
        lock.withLock { $0.pixelBuffer = nil }
    }
}
#endif

// swiftlint:enable file_length
