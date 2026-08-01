import Accelerate
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
    case exactGeometryFinisherRequired = "exact_geometry_finisher_required"
    case frameContractMismatch = "frame_contract_mismatch"
    case outputContractMismatch = "output_contract_mismatch"
    case concurrentFrameSubmission = "concurrent_frame_submission"
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
    case inputPreparation = "input_preparation"
    case frameCreation = "frame_creation"
    case parameterCreation = "parameter_creation"
    case sessionStart = "session_start"
    case processing = "processing"
    case exactGeometryFinish = "exact_geometry_finish"
}

enum VTNativeSuperResolutionError: Error, Equatable, Sendable {
    case unavailable(VTNativeSuperResolutionUnavailableReason)
    case rejected(VTNativeSuperResolutionRejectionReason)
    case failed(VTNativeSuperResolutionFailureReason)
}

enum VTAdaptiveNativePath: String, Equatable, Sendable {
    case quality
    case lowLatency = "low_latency"
}

struct VTAdaptiveNativePlan: Equatable, Sendable {
    let path: VTAdaptiveNativePath
    let videoFormat: MediaVideoFormat
    let presentationSourceResolution: VideoResolution
    let requestedSourceResolution: VideoResolution
    let nativeSourceResolution: VideoResolution
    let requestedTargetResolution: VideoResolution
    let nativeTargetResolution: VideoResolution
    let nativeScaleFactor: Float

    var requiresInputPreparation: Bool {
        requestedSourceResolution != nativeSourceResolution
    }

    var requiresExactGeometryFinish: Bool {
        nativeTargetResolution != requestedTargetResolution
    }

    var formatPreservationPathIdentity: String {
        switch path {
        case .quality:
            return "rgba-half-native-roundtrip-original-storage"
        case .lowLatency:
            return "420v-native-guide-original-storage-detail-composite"
        }
    }

    var stableIdentity: String {
        [
            "vt-adaptive-native-v2",
            path.rawValue,
            "format-\(R13ReleaseVideoFormatBinding(videoFormat).identityComponent)",
            "preservation-\(formatPreservationPathIdentity)",
            "presentation-source-\(presentationSourceResolution.width)x\(presentationSourceResolution.height)",
            "input-source-\(requestedSourceResolution.width)x\(requestedSourceResolution.height)",
            "native-source-\(nativeSourceResolution.width)x\(nativeSourceResolution.height)",
            "native-target-\(nativeTargetResolution.width)x\(nativeTargetResolution.height)",
            "requested-target-\(requestedTargetResolution.width)x\(requestedTargetResolution.height)",
            "scale-bits-\(String(format: "%08x", nativeScaleFactor.bitPattern))"
        ].joined(separator: ".")
    }
}

struct VTAdaptiveNativeQualityRouteResolution: Equatable, Sendable {
    let plan: VTAdaptiveNativePlan
    let binding: R04VideoToolboxNativeRouteBinding
}

enum VTAdaptiveNativeQualityRouteResolver {
    static func resolve(
        videoFormat: MediaVideoFormat,
        presentationSourceResolution: VideoResolution,
        requestedSourceResolution: VideoResolution,
        requestedTargetResolution: VideoResolution,
        runtimeSupportedScaleFactors: [Int]
    ) throws -> VTAdaptiveNativeQualityRouteResolution {
        let nativeSourceResolution =
            try R13VideoToolboxAdaptiveNativeSourceAdmission
                .qualityResolution(
                    requestedSourceResolution:
                        requestedSourceResolution
                )
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            videoFormat: videoFormat,
            presentationSourceResolution:
                presentationSourceResolution,
            requestedSourceResolution:
                requestedSourceResolution,
            nativeSourceResolution: nativeSourceResolution,
            requestedTargetResolution:
                requestedTargetResolution,
            runtimeSupportedScaleFactors:
                runtimeSupportedScaleFactors
        )
        let route = try VTAdaptiveNativeRouteFactory.makeRoute(
            plan: plan
        )
        return VTAdaptiveNativeQualityRouteResolution(
            plan: plan,
            binding: R04VideoToolboxNativeRouteBinding(
                intent: .quality,
                route: route
            )
        )
    }

    #if compiler(>=6.2) && !targetEnvironment(simulator)
    @available(macOS 26.0, *)
    static func resolve(
        videoFormat: MediaVideoFormat,
        presentationSourceResolution: VideoResolution,
        requestedSourceResolution: VideoResolution,
        requestedTargetResolution: VideoResolution
    ) throws -> VTAdaptiveNativeQualityRouteResolution {
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw VTNativeSuperResolutionError.unavailable(
                .nativeProcessorUnsupported
            )
        }
        return try resolve(
            videoFormat: videoFormat,
            presentationSourceResolution:
                presentationSourceResolution,
            requestedSourceResolution:
                requestedSourceResolution,
            requestedTargetResolution:
                requestedTargetResolution,
            runtimeSupportedScaleFactors:
                VTSuperResolutionScalerConfiguration
                    .supportedScaleFactors
        )
    }
    #endif
}

struct R13VideoToolboxQualityJobRouteResolution:
    Equatable,
    Sendable {
    let releaseScalePlan: R13ReleaseScalePlan
    let binding: R04VideoToolboxNativeRouteBinding
    let adaptiveNativePlan: VTAdaptiveNativePlan?

    var requiresAdaptiveNativeExecution: Bool {
        adaptiveNativePlan != nil
    }
}

enum R13VideoToolboxQualityJobRouteResolver {
    static func explicitlyRequiresQuality(
        enginePreference: UpscaleEnginePreference
    ) -> Bool {
        enginePreference == .videoToolboxQuality
    }

    static func requestsQuality(
        mode: UpscaleMode,
        enginePreference: UpscaleEnginePreference
    ) -> Bool {
        if explicitlyRequiresQuality(
            enginePreference: enginePreference
        ) {
            return true
        }
        guard enginePreference == .automatic else {
            return false
        }
        switch mode {
        case .auto, .quality, .smoothMotion:
            return true
        case .fast, .deterministic:
            return false
        }
    }

    static func resolve(
        mode: UpscaleMode,
        enginePreference: UpscaleEnginePreference,
        videoFormat: MediaVideoFormat,
        presentationSourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        strategyPreference: UpscaleStrategyPreference,
        runtimeSupportedScaleFactors: [Int]
    ) throws -> R13VideoToolboxQualityJobRouteResolution? {
        let releaseScalePlan = try R13ReleaseJobContracts.scalePlan(
            source: presentationSourceResolution,
            target: targetResolution,
            strategyPreference: strategyPreference
        )
        return try resolve(
            releaseScalePlan: releaseScalePlan,
            mode: mode,
            enginePreference: enginePreference,
            videoFormat: videoFormat,
            presentationSourceResolution:
                presentationSourceResolution,
            targetResolution: targetResolution,
            runtimeSupportedScaleFactors:
                runtimeSupportedScaleFactors
        )
    }

    static func resolve(
        releaseScalePlan: R13ReleaseScalePlan,
        mode: UpscaleMode,
        enginePreference: UpscaleEnginePreference,
        videoFormat: MediaVideoFormat,
        presentationSourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        runtimeSupportedScaleFactors: [Int]
    ) throws -> R13VideoToolboxQualityJobRouteResolution? {
        guard requestsQuality(
            mode: mode,
            enginePreference: enginePreference
        ) else {
            return nil
        }
        let explicitlyRequiresQuality = explicitlyRequiresQuality(
            enginePreference: enginePreference
        )

        if videoFormat == .sdrBT709,
           case .productQualified = releaseScalePlan,
           let exactBinding =
                R04VideoToolboxNativeRouteSelector.exactBinding(
                    sourceResolution:
                        presentationSourceResolution,
                    targetResolution: targetResolution,
                    intent: .quality
                ) {
            if runtimeSupportedScaleFactors.contains(
                exactBinding.route.scaleFactor.numerator
            ) {
                return R13VideoToolboxQualityJobRouteResolution(
                    releaseScalePlan: releaseScalePlan,
                    binding: exactBinding,
                    adaptiveNativePlan: nil
                )
            }
            guard explicitlyRequiresQuality else {
                return nil
            }
        }

        guard explicitlyRequiresQuality else {
            return nil
        }
        let requestedSourceResolution: VideoResolution
        switch releaseScalePlan {
        case .productQualified(let route):
            requestedSourceResolution =
                route.canonicalSourceResolution
        case .adaptiveMPSLanczos(let plan):
            requestedSourceResolution =
                plan.processingSourceResolution
        }
        let adaptive = try VTAdaptiveNativeQualityRouteResolver
            .resolve(
                videoFormat: videoFormat,
                presentationSourceResolution:
                    presentationSourceResolution,
                requestedSourceResolution:
                    requestedSourceResolution,
                requestedTargetResolution: targetResolution,
                runtimeSupportedScaleFactors:
                    runtimeSupportedScaleFactors
            )
        return R13VideoToolboxQualityJobRouteResolution(
            releaseScalePlan: releaseScalePlan,
            binding: adaptive.binding,
            adaptiveNativePlan: adaptive.plan
        )
    }

    #if compiler(>=6.2) && !targetEnvironment(simulator)
    @available(macOS 26.0, *)
    static func resolve(
        mode: UpscaleMode,
        enginePreference: UpscaleEnginePreference,
        videoFormat: MediaVideoFormat,
        presentationSourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        strategyPreference: UpscaleStrategyPreference
    ) throws -> R13VideoToolboxQualityJobRouteResolution? {
        let releaseScalePlan = try R13ReleaseJobContracts.scalePlan(
            source: presentationSourceResolution,
            target: targetResolution,
            strategyPreference: strategyPreference
        )
        return try resolve(
            releaseScalePlan: releaseScalePlan,
            mode: mode,
            enginePreference: enginePreference,
            videoFormat: videoFormat,
            presentationSourceResolution:
                presentationSourceResolution,
            targetResolution: targetResolution
        )
    }

    @available(macOS 26.0, *)
    static func resolve(
        releaseScalePlan: R13ReleaseScalePlan,
        mode: UpscaleMode,
        enginePreference: UpscaleEnginePreference,
        videoFormat: MediaVideoFormat,
        presentationSourceResolution: VideoResolution,
        targetResolution: VideoResolution
    ) throws -> R13VideoToolboxQualityJobRouteResolution? {
        guard requestsQuality(
            mode: mode,
            enginePreference: enginePreference
        ) else {
            return nil
        }
        if enginePreference == .automatic {
            guard VTSuperResolutionScalerConfiguration.isSupported else {
                return nil
            }
            return try resolve(
                releaseScalePlan: releaseScalePlan,
                mode: mode,
                enginePreference: enginePreference,
                videoFormat: videoFormat,
                presentationSourceResolution:
                    presentationSourceResolution,
                targetResolution: targetResolution,
                runtimeSupportedScaleFactors:
                    VTSuperResolutionScalerConfiguration
                        .supportedScaleFactors
            )
        }
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw VTNativeSuperResolutionError.unavailable(
                .nativeProcessorUnsupported
            )
        }
        return try resolve(
            releaseScalePlan: releaseScalePlan,
            mode: mode,
            enginePreference: enginePreference,
            videoFormat: videoFormat,
            presentationSourceResolution:
                presentationSourceResolution,
            targetResolution: targetResolution,
            runtimeSupportedScaleFactors:
                VTSuperResolutionScalerConfiguration
                    .supportedScaleFactors
        )
    }
    #endif
}

struct VTAdaptiveNativeFrameOutput: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sequenceNumber: Int
    let presentationTimestamp: CMTime
    let duration: CMTime
    let path: VTAdaptiveNativePath
    let videoFormat: MediaVideoFormat
    let nativeSourceResolution: VideoResolution
    let nativeOutputResolution: VideoResolution
    let requestedTargetResolution: VideoResolution
    let usedExactGeometryFinisher: Bool
    let planIdentity: String
}

typealias VTAdaptiveExactGeometryFinisher = @Sendable (
    _ nativeOutput: CVPixelBuffer,
    _ nativeResolution: VideoResolution,
    _ requestedTarget: VideoResolution,
    _ cancellation: AppleUpscaleOperationCancellationSignal
) async throws -> CVPixelBuffer

enum VTAdaptiveNativePlanAdmission {
    static func nativeTargetResolution(
        sourceResolution: VideoResolution,
        scaleFactor: Float
    ) -> VideoResolution? {
        scaledResolution(sourceResolution, factor: scaleFactor)
    }

    static func makeQualityPlan(
        videoFormat: MediaVideoFormat = .sdrBT709,
        presentationSourceResolution: VideoResolution,
        requestedSourceResolution: VideoResolution,
        nativeSourceResolution: VideoResolution,
        requestedTargetResolution: VideoResolution,
        runtimeSupportedScaleFactors: [Int]
    ) throws -> VTAdaptiveNativePlan {
        let supported = runtimeSupportedScaleFactors
            .filter { $0 == 2 || $0 == 4 }
            .map(Float.init)
        guard !supported.isEmpty else {
            throw VTNativeSuperResolutionError.unavailable(
                .qualityScaleUnsupported
            )
        }
        return try makePlan(
            path: .quality,
            videoFormat: videoFormat,
            presentationSourceResolution: presentationSourceResolution,
            requestedSourceResolution: requestedSourceResolution,
            nativeSourceResolution: nativeSourceResolution,
            requestedTargetResolution: requestedTargetResolution,
            runtimeSupportedScaleFactors: supported
        )
    }

    static func makeLowLatencyPlan(
        videoFormat: MediaVideoFormat = .sdrBT709,
        presentationSourceResolution: VideoResolution,
        requestedSourceResolution: VideoResolution,
        nativeSourceResolution: VideoResolution,
        requestedTargetResolution: VideoResolution,
        runtimeSupportedScaleFactors: [Float]
    ) throws -> VTAdaptiveNativePlan {
        try makePlan(
            path: .lowLatency,
            videoFormat: videoFormat,
            presentationSourceResolution: presentationSourceResolution,
            requestedSourceResolution: requestedSourceResolution,
            nativeSourceResolution: nativeSourceResolution,
            requestedTargetResolution: requestedTargetResolution,
            runtimeSupportedScaleFactors: runtimeSupportedScaleFactors
        )
    }

    private struct AdmittedScale {
        let factor: Float
        let target: VideoResolution
    }

    private static func makePlan(
        path: VTAdaptiveNativePath,
        videoFormat: MediaVideoFormat,
        presentationSourceResolution: VideoResolution,
        requestedSourceResolution: VideoResolution,
        nativeSourceResolution: VideoResolution,
        requestedTargetResolution: VideoResolution,
        runtimeSupportedScaleFactors: [Float]
    ) throws -> VTAdaptiveNativePlan {
        guard validPresentationResolution(presentationSourceResolution),
              validCanonicalResolution(requestedSourceResolution),
              validCanonicalResolution(nativeSourceResolution),
              validCanonicalResolution(requestedTargetResolution),
              matchesEvenCeilingNormalization(
                  presentation: presentationSourceResolution,
                  processing: requestedSourceResolution
              ),
              requestedTargetResolution.width
                  >= presentationSourceResolution.width,
              requestedTargetResolution.height
                  >= presentationSourceResolution.height,
              requestedTargetResolution != presentationSourceResolution,
              R13AspectRatioContract.preservesWithinOneOutputPixel(
                  source: requestedSourceResolution,
                  target: nativeSourceResolution
              ),
              R13AspectRatioContract.preservesWithinOneOutputPixel(
                  source: presentationSourceResolution,
                  target: requestedTargetResolution
              ),
              formatSupports(
                  videoFormat,
                  resolutions: [
                      requestedSourceResolution,
                      nativeSourceResolution,
                      requestedTargetResolution
                  ]
              ) else {
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }

        let admittedByBits: [UInt32: AdmittedScale] = Dictionary(
            runtimeSupportedScaleFactors.compactMap { factor in
                guard let target = scaledResolution(
                    nativeSourceResolution,
                    factor: factor
                ) else {
                    return nil
                }
                return (factor.bitPattern, AdmittedScale(
                    factor: factor,
                    target: target
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let admitted = admittedByBits.values.sorted {
            $0.factor < $1.factor
        }

        guard !admitted.isEmpty else {
            switch path {
            case .quality:
                throw VTNativeSuperResolutionError.unavailable(
                    .qualityScaleUnsupported
                )
            case .lowLatency:
                throw VTNativeSuperResolutionError.rejected(
                    .exactDimensionScaleUnsupported
                )
            }
        }

        let selected = admitted.first {
            $0.target.width >= requestedTargetResolution.width
                && $0.target.height >= requestedTargetResolution.height
        } ?? admitted[admitted.index(before: admitted.endIndex)]

        return VTAdaptiveNativePlan(
            path: path,
            videoFormat: videoFormat,
            presentationSourceResolution: presentationSourceResolution,
            requestedSourceResolution: requestedSourceResolution,
            nativeSourceResolution: nativeSourceResolution,
            requestedTargetResolution: requestedTargetResolution,
            nativeTargetResolution: selected.target,
            nativeScaleFactor: selected.factor
        )
    }

    private static func validCanonicalResolution(
        _ resolution: VideoResolution
    ) -> Bool {
        resolution.width > 0
            && resolution.height > 0
            && resolution.width.isMultiple(of: 2)
            && resolution.height.isMultiple(of: 2)
    }

    private static func formatSupports(
        _ format: MediaVideoFormat,
        resolutions: [VideoResolution]
    ) -> Bool {
        do {
            let layout = try R13PixelLayoutRegistry.layout(
                for: format.pixelStorage.pixelFormat
            )
            for resolution in resolutions {
                try layout.validateGeometry(
                    width: resolution.width,
                    height: resolution.height
                )
            }
            return true
        } catch {
            return false
        }
    }

    private static func validPresentationResolution(
        _ resolution: VideoResolution
    ) -> Bool {
        resolution.width > 0 && resolution.height > 0
    }

    private static func matchesEvenCeilingNormalization(
        presentation: VideoResolution,
        processing: VideoResolution
    ) -> Bool {
        guard let expectedWidth = evenCeiling(presentation.width),
              let expectedHeight = evenCeiling(presentation.height) else {
            return false
        }
        return processing.width == expectedWidth
            && processing.height == expectedHeight
    }

    private static func evenCeiling(_ value: Int) -> Int? {
        guard value > 0 else { return nil }
        if value.isMultiple(of: 2) { return value }
        let (result, overflow) = value.addingReportingOverflow(1)
        return overflow ? nil : result
    }

    private static func sameAspect(
        _ lhs: VideoResolution,
        _ rhs: VideoResolution
    ) -> Bool {
        let left = lhs.width.multipliedReportingOverflow(by: rhs.height)
        let right = rhs.width.multipliedReportingOverflow(by: lhs.height)
        return !left.overflow
            && !right.overflow
            && left.partialValue == right.partialValue
    }

    private static func scaledResolution(
        _ source: VideoResolution,
        factor: Float
    ) -> VideoResolution? {
        guard factor.isFinite, factor > 1 else { return nil }
        let scaledWidth = Double(source.width) * Double(factor)
        let scaledHeight = Double(source.height) * Double(factor)
        guard scaledWidth.isFinite,
              scaledHeight.isFinite,
              scaledWidth <= Double(Int.max),
              scaledHeight <= Double(Int.max) else {
            return nil
        }
        let width = Int(scaledWidth.rounded())
        let height = Int(scaledHeight.rounded())
        let tolerance = 0.001
        guard abs(scaledWidth - Double(width)) <= tolerance,
              abs(scaledHeight - Double(height)) <= tolerance else {
            return nil
        }
        let target = VideoResolution(width: width, height: height)
        guard validCanonicalResolution(target), sameAspect(source, target) else {
            return nil
        }
        return target
    }
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

    func qualitySupport(
        sourceResolution: VideoResolution,
        scaleFactor: R04VideoToolboxScaleFactor
    ) async -> R04VideoToolboxSupportObservation<Bool> {
        guard let configuration = try? VTNativeSRConfigurationBuilder
            .quality(
                sourceResolution: sourceResolution,
                scaleFactor: scaleFactor,
                flowConfiguration: qualityFlowConfiguration
            ) else {
            return .observed(false)
        }
        return .observed(
            configuration.supportedPixelFormats.contains(
                VTNativeQualityPixelBufferBridge.nativePixelFormat
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
        for value in values {
            guard let target = VTAdaptiveNativePlanAdmission
                .nativeTargetResolution(
                    sourceResolution: sourceResolution,
                    scaleFactor: value
                ),
                let scale = try? R04VideoToolboxScaleFactor(
                    numerator: target.width,
                    denominator: sourceResolution.width
                ),
                scale.matches(source: sourceResolution, target: target) else {
                continue
            }
            scales.insert(scale)
        }
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
                        scaleFactor: route.scaleFactor,
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
                      configuration.frameHeight == route.sourceResolution.height,
                      Self.pixelBufferAttributes(
                          configuration.sourcePixelBufferAttributes,
                          match: route.sourceResolution,
                          pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat
                      ),
                      Self.pixelBufferAttributes(
                          configuration.destinationPixelBufferAttributes,
                          match: route.targetResolution,
                          pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat
                      ) else {
                    return .notObserved
                }
                let admittedScale = Float(route.scaleFactor.numerator)
                    / Float(route.scaleFactor.denominator)
                return .observed(
                    VTNativeConfigurationDiagnosticsFactory.lowLatency(
                        frameWidth: configuration.frameWidth,
                        frameHeight: configuration.frameHeight,
                        scaleFactor: admittedScale,
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
            guard request.route.backendKind == .quality,
                  request.route.gate == .runtimeSupportRequired,
                  request.route.scaleFactor.denominator == 1 else {
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

    private static func pixelBufferAttributes(
        _ attributes: [String: any Sendable],
        match resolution: VideoResolution,
        pixelFormat: OSType
    ) -> Bool {
        integerValue(attributes[kCVPixelBufferWidthKey as String])
            == resolution.width
            && integerValue(attributes[kCVPixelBufferHeightKey as String])
                == resolution.height
            && unsignedIntegerValue(
                attributes[kCVPixelBufferPixelFormatTypeKey as String]
            ) == pixelFormat
    }

    private static func integerValue(_ value: (any Sendable)?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func unsignedIntegerValue(
        _ value: (any Sendable)?
    ) -> UInt32? {
        if let value = value as? UInt32 { return value }
        return (value as? NSNumber)?.uint32Value
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
enum VTNativeSRConfigurationBuilder {
    static func quality(
        sourceResolution: VideoResolution,
        scaleFactor: R04VideoToolboxScaleFactor,
        flowConfiguration: VTNativeQualityFlowConfiguration
    ) throws -> VTSuperResolutionScalerConfiguration {
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw VTNativeSuperResolutionError.unavailable(
                .nativeProcessorUnsupported
            )
        }
        guard scaleFactor.denominator == 1 else {
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }
        let integerScaleFactor = scaleFactor.numerator
        let revision = VTSuperResolutionScalerConfiguration.defaultRevision
        return try VTNativeQualityConfigurationAdmission.construct(
            scaleIsSupported: {
                VTSuperResolutionScalerConfiguration.supportedScaleFactors
                    .contains(integerScaleFactor)
            },
            revisionIsSupported: {
                VTSuperResolutionScalerConfiguration.supportedRevisions
                    .contains(revision.rawValue)
            },
            construct: {
                VTSuperResolutionScalerConfiguration(
                    frameWidth: sourceResolution.width,
                    frameHeight: sourceResolution.height,
                    scaleFactor: integerScaleFactor,
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
        guard route.backendKind == .lowLatency else {
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }
        let scale = Float(route.scaleFactor.numerator)
            / Float(route.scaleFactor.denominator)
        return try lowLatency(
            sourceResolution: route.sourceResolution,
            targetResolution: route.targetResolution,
            requestedScale: scale
        )
    }

    static func lowLatency(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        requestedScale: Float
    ) throws -> VTLowLatencySuperResolutionScalerConfiguration {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            throw VTNativeSuperResolutionError.unavailable(
                .nativeProcessorUnsupported
            )
        }
        let configuration = try VTNativeLowLatencyScaleAdmission.construct(
            frameWidth: sourceResolution.width,
            frameHeight: sourceResolution.height,
            requestedScale: requestedScale,
            query: {
                VTLowLatencySuperResolutionScalerConfiguration
                    .supportedScaleFactors(
                        frameWidth: sourceResolution.width,
                        frameHeight: sourceResolution.height
                    )
            },
            construct: {
                VTLowLatencySuperResolutionScalerConfiguration(
                    frameWidth: sourceResolution.width,
                    frameHeight: sourceResolution.height,
                    scaleFactor: requestedScale
                )
            }
        )
        guard integerValue(
            configuration.destinationPixelBufferAttributes[
                kCVPixelBufferWidthKey as String
            ]
        ) == targetResolution.width,
        integerValue(
            configuration.destinationPixelBufferAttributes[
                kCVPixelBufferHeightKey as String
            ]
        ) == targetResolution.height else {
            throw VTNativeSuperResolutionError.rejected(
                .exactDimensionScaleUnsupported
            )
        }
        return configuration
    }

    private static func integerValue(_ value: (any Sendable)?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

enum R04VTNativeQualityRouteAdmission {
    static func validate(
        _ binding: R04VideoToolboxNativeRouteBinding
    ) throws {
        let route = binding.route
        let expectedSubjectID: R04VideoToolboxSubjectID
        let expectedRouteID: R04VideoToolboxRouteID
        switch route.scaleFactor {
        case .two:
            expectedSubjectID = .quality2x
            expectedRouteID = .quality2x
        case .four:
            expectedSubjectID = .quality4x
            expectedRouteID = .quality4x
        default:
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }
        let scaleIdentities = Set([
            String(route.scaleFactor.numerator),
            String(
                format: "%08x",
                Float(route.scaleFactor.numerator).bitPattern
            )
        ])
        let configuration = route.configurationContract
        guard binding.intent == .quality,
              route.subjectID == expectedSubjectID,
              route.routeID == expectedRouteID,
              route.capabilityID == "A01",
              route.backendKind == .quality,
              route.sourceResolution.width > 0,
              route.sourceResolution.height > 0,
              route.gate == .runtimeSupportRequired,
              configuration.frameWidth
                == route.sourceResolution.width,
              configuration.frameHeight
                == route.sourceResolution.height,
              scaleIdentities.contains(
                configuration.scaleFactorIdentity
              ),
              configuration.inputType == .video,
              configuration.precomputedFlowChoice
                == .optionalPerRequest,
              configuration.qualityPriority == .quality,
              configuration.revision
                == .runtimeSelectedNotObserved,
              configuration.supportedFormats == .notObserved,
              configuration.modelStatus == .notObserved,
              configuration.processingMode == .qualityTemporal,
              !configuration.exactDimensionQueryRequired,
              route.temporalPolicy == .qualitySequential,
              route.opticalFlowRole == .optionalQualityInput,
              route.productDefaultEligibility
                == .candidateAfterObservedQualification,
              route.productQualification == .notClaimed else {
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }
    }
}

@available(macOS 26.0, *)
enum R04VTNativeConfigurationFactory {
    static func makeQualityConfiguration(
        binding: R04VideoToolboxNativeRouteBinding,
        flowConfiguration: VTNativeQualityFlowConfiguration = .appleComputed
    ) throws -> VTSuperResolutionScalerConfiguration {
        try R04VTNativeQualityRouteAdmission.validate(binding)
        return try VTNativeSRConfigurationBuilder.quality(
            sourceResolution: binding.route.sourceResolution,
            scaleFactor: binding.route.scaleFactor,
            flowConfiguration: flowConfiguration
        )
    }
}

@available(macOS 26.0, *)
protocol VTAdaptiveNativeFrameProcessing: AnyObject, Sendable {
    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer
    func reset()
    func finish()
    func cancel()
}

@available(macOS 26.0, *)
actor VTAdaptiveNativeUpscaleSession {
    private enum Lifecycle {
        case open
        case finishing
        case cancelling
        case terminal
    }

    nonisolated let plan: VTAdaptiveNativePlan

    private let nativeProcessor: any VTAdaptiveNativeFrameProcessing
    private let exactGeometryFinisher: VTAdaptiveExactGeometryFinisher?
    private var lifecycle = Lifecycle.open
    private var historyGeneration: UInt64 = 0
    private var activeCancellation: AppleUpscaleOperationCancellationSignal?
    private var activeProcessCount = 0
    private var lastSequenceNumber: Int?
    private var lastPresentationTimestamp: CMTime?
    private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

    static func make(
        path: VTAdaptiveNativePath,
        videoFormat: MediaVideoFormat = .sdrBT709,
        presentationSourceResolution: VideoResolution,
        requestedSourceResolution: VideoResolution,
        nativeSourceResolution: VideoResolution? = nil,
        requestedTargetResolution: VideoResolution,
        exactGeometryFinisher: VTAdaptiveExactGeometryFinisher? = nil
    ) throws -> VTAdaptiveNativeUpscaleSession {
        let admittedNativeSource = nativeSourceResolution
            ?? requestedSourceResolution
        let plan: VTAdaptiveNativePlan
        switch path {
        case .quality:
            guard VTSuperResolutionScalerConfiguration.isSupported else {
                throw VTNativeSuperResolutionError.unavailable(
                    .nativeProcessorUnsupported
                )
            }
            plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
                videoFormat: videoFormat,
                presentationSourceResolution: presentationSourceResolution,
                requestedSourceResolution: requestedSourceResolution,
                nativeSourceResolution: admittedNativeSource,
                requestedTargetResolution: requestedTargetResolution,
                runtimeSupportedScaleFactors: VTSuperResolutionScalerConfiguration
                    .supportedScaleFactors
            )
        case .lowLatency:
            guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
                throw VTNativeSuperResolutionError.unavailable(
                    .nativeProcessorUnsupported
                )
            }
            plan = try VTAdaptiveNativePlanAdmission.makeLowLatencyPlan(
                videoFormat: videoFormat,
                presentationSourceResolution: presentationSourceResolution,
                requestedSourceResolution: requestedSourceResolution,
                nativeSourceResolution: admittedNativeSource,
                requestedTargetResolution: requestedTargetResolution,
                runtimeSupportedScaleFactors:
                    VTLowLatencySuperResolutionScalerConfiguration
                    .supportedScaleFactors(
                        frameWidth: admittedNativeSource.width,
                        frameHeight: admittedNativeSource.height
                    )
            )
        }
        guard !plan.requiresExactGeometryFinish
                || exactGeometryFinisher != nil else {
            throw VTNativeSuperResolutionError.rejected(
                .exactGeometryFinisherRequired
            )
        }
        return try make(
            plan: plan,
            exactGeometryFinisher: exactGeometryFinisher
        )
    }

    static func make(
        plan: VTAdaptiveNativePlan,
        exactGeometryFinisher: VTAdaptiveExactGeometryFinisher? = nil
    ) throws -> VTAdaptiveNativeUpscaleSession {
        guard !plan.requiresExactGeometryFinish
                || exactGeometryFinisher != nil else {
            throw VTNativeSuperResolutionError.rejected(
                .exactGeometryFinisherRequired
            )
        }
        return try VTAdaptiveNativeUpscaleSession(
            plan: plan,
            nativeProcessor: VTAdaptiveNativeVideoToolboxProcessor(plan: plan),
            exactGeometryFinisher: exactGeometryFinisher
        )
    }

    init(
        plan: VTAdaptiveNativePlan,
        nativeProcessor: any VTAdaptiveNativeFrameProcessing,
        exactGeometryFinisher: VTAdaptiveExactGeometryFinisher? = nil
    ) throws {
        guard !plan.requiresExactGeometryFinish
                || exactGeometryFinisher != nil else {
            throw VTNativeSuperResolutionError.rejected(
                .exactGeometryFinisherRequired
            )
        }
        self.plan = plan
        self.nativeProcessor = nativeProcessor
        self.exactGeometryFinisher = exactGeometryFinisher
    }

    func process(
        _ frame: AppleUpscaleFrame,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> VTAdaptiveNativeFrameOutput {
        guard case .open = lifecycle else {
            throw VTNativeSuperResolutionError.unavailable(.sessionEnded)
        }
        guard activeProcessCount == 0 else {
            throw VTNativeSuperResolutionError.rejected(
                .concurrentFrameSubmission
            )
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
        guard VTAdaptiveMediaVideoFormatContract.matches(
            frame: frame,
            resolution: plan.nativeSourceResolution,
            format: plan.videoFormat
        ) else {
            throw VTNativeSuperResolutionError.rejected(
                .frameContractMismatch
            )
        }
        if let lastSequenceNumber,
           frame.sequenceNumber <= lastSequenceNumber {
            throw VTNativeSuperResolutionError.rejected(
                .temporalContractMismatch
            )
        }
        if let lastPresentationTimestamp,
           CMTimeCompare(
               frame.presentationTimestamp,
               lastPresentationTimestamp
           ) <= 0 {
            throw VTNativeSuperResolutionError.rejected(
                .temporalContractMismatch
            )
        }

        activeProcessCount = 1
        activeCancellation = cancellation
        defer {
            activeProcessCount = 0
            activeCancellation = nil
            finalizeTerminationIfPossible()
        }

        let nativeOutput: CVPixelBuffer
        do {
            nativeOutput = try await nativeProcessor.process(
                frame,
                historyGeneration: historyGeneration,
                cancellation: cancellation
            )
        } catch let error as VTNativeSuperResolutionError {
            throw error
        } catch is CancellationError {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        } catch {
            throw VTNativeSuperResolutionError.failed(.processing)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
        guard VTAdaptiveMediaVideoFormatContract.matches(
            pixelBuffer: nativeOutput,
            resolution: plan.nativeTargetResolution,
            format: plan.videoFormat
        ) else {
            throw VTNativeSuperResolutionError.rejected(
                .outputContractMismatch
            )
        }

        let finalOutput: CVPixelBuffer
        if plan.requiresExactGeometryFinish {
            guard let exactGeometryFinisher else {
                throw VTNativeSuperResolutionError.rejected(
                    .exactGeometryFinisherRequired
                )
            }
            do {
                finalOutput = try await exactGeometryFinisher(
                    nativeOutput,
                    plan.nativeTargetResolution,
                    plan.requestedTargetResolution,
                    cancellation
                )
            } catch let error as VTNativeSuperResolutionError {
                throw error
            } catch is CancellationError {
                throw VTNativeSuperResolutionError.rejected(
                    .operationCancelled
                )
            } catch {
                throw VTNativeSuperResolutionError.failed(
                    .exactGeometryFinish
                )
            }
        } else {
            finalOutput = nativeOutput
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
        guard VTAdaptiveMediaVideoFormatContract.matches(
            pixelBuffer: finalOutput,
            resolution: plan.requestedTargetResolution,
            format: plan.videoFormat
        ) else {
            throw VTNativeSuperResolutionError.rejected(
                .outputContractMismatch
            )
        }

        lastSequenceNumber = frame.sequenceNumber
        lastPresentationTimestamp = frame.presentationTimestamp
        return VTAdaptiveNativeFrameOutput(
            pixelBuffer: finalOutput,
            sequenceNumber: frame.sequenceNumber,
            presentationTimestamp: frame.presentationTimestamp,
            duration: frame.duration,
            path: plan.path,
            videoFormat: plan.videoFormat,
            nativeSourceResolution: plan.nativeSourceResolution,
            nativeOutputResolution: plan.nativeTargetResolution,
            requestedTargetResolution: plan.requestedTargetResolution,
            usedExactGeometryFinisher: plan.requiresExactGeometryFinish,
            planIdentity: plan.stableIdentity
        )
    }

    func reset() throws {
        guard case .open = lifecycle else {
            throw VTNativeSuperResolutionError.unavailable(.sessionEnded)
        }
        guard activeProcessCount == 0 else {
            throw VTNativeSuperResolutionError.rejected(
                .concurrentFrameSubmission
            )
        }
        guard historyGeneration < UInt64.max else {
            throw VTNativeSuperResolutionError.rejected(
                .temporalContractMismatch
            )
        }
        historyGeneration += 1
        lastSequenceNumber = nil
        lastPresentationTimestamp = nil
        nativeProcessor.reset()
    }

    func finish() async {
        switch lifecycle {
        case .open:
            lifecycle = .finishing
        case .finishing, .cancelling:
            break
        case .terminal:
            return
        }
        if activeProcessCount == 0 {
            finalizeTerminationIfPossible()
            return
        }
        await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }

    func cancel() async {
        switch lifecycle {
        case .open, .finishing:
            lifecycle = .cancelling
            activeCancellation?.cancel()
        case .cancelling:
            break
        case .terminal:
            return
        }
        if activeProcessCount == 0 {
            finalizeTerminationIfPossible()
            return
        }
        await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }

    private func finalizeTerminationIfPossible() {
        guard activeProcessCount == 0 else { return }
        switch lifecycle {
        case .finishing:
            nativeProcessor.finish()
        case .cancelling:
            nativeProcessor.cancel()
        case .open, .terminal:
            return
        }
        lifecycle = .terminal
        let waiters = terminationWaiters
        terminationWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }
}

@available(macOS 26.0, *)
private final class VTAdaptiveNativeVideoToolboxProcessor:
    VTAdaptiveNativeFrameProcessing,
    @unchecked Sendable {
    private enum Storage {
        case quality(VTNativeQualitySuperResolutionSession)
        case lowLatency(VTNativeLowLatencySuperResolutionSession)
    }

    private let storage: Storage

    init(plan: VTAdaptiveNativePlan) throws {
        let route = try VTAdaptiveNativeRouteFactory.makeRoute(plan: plan)
        switch plan.path {
        case .quality:
            storage = .quality(
                try VTNativeQualitySuperResolutionSession(
                    route: route,
                    flowConfiguration: .appleComputed,
                    videoFormat: plan.videoFormat
                )
            )
        case .lowLatency:
            storage = .lowLatency(
                try VTNativeLowLatencySuperResolutionSession(
                    adaptiveRoute: route,
                    requestedScale: plan.nativeScaleFactor,
                    videoFormat: plan.videoFormat
                )
            )
        }
    }

    func process(
        _ frame: AppleUpscaleFrame,
        historyGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer {
        switch storage {
        case .quality(let session):
            return try await session.processAdaptive(
                frame,
                historyGeneration: historyGeneration,
                cancellation: cancellation
            )
        case .lowLatency(let session):
            return try await session.processAdaptive(
                frame,
                cancellation: cancellation
            )
        }
    }

    func reset() {
        if case .quality(let session) = storage {
            session.resetAdaptiveHistory()
        }
    }

    func finish() {
        end()
    }

    func cancel() {
        end()
    }

    private func end() {
        switch storage {
        case .quality(let session):
            session.end()
        case .lowLatency(let session):
            session.end()
        }
    }
}

enum VTAdaptiveNativeRouteFactory {
    static func makeRoute(
        plan: VTAdaptiveNativePlan
    ) throws -> R04VideoToolboxRouteDescriptor {
        let scale = try R04VideoToolboxScaleFactor(
            numerator: plan.nativeTargetResolution.width,
            denominator: plan.nativeSourceResolution.width
        )
        let identity = String(
            format: "%08x",
            plan.nativeScaleFactor.bitPattern
        )
        let subjectID: R04VideoToolboxSubjectID
        let routeID: R04VideoToolboxRouteID
        let backendKind: R04VideoToolboxBackendKind
        let gate: R04VideoToolboxRouteGate
        let temporalPolicy: R04VideoToolboxTemporalPolicy
        let opticalFlowRole: R04VideoToolboxOpticalFlowRole
        let precomputedFlowChoice: R04VideoToolboxPrecomputedFlowChoice
        let qualityPriority: R04VideoToolboxQualityPriorityIdentity
        let modelStatus: R04VideoToolboxModelStatusIdentity
        let processingMode: R04VideoToolboxProcessingModeIdentity
        switch plan.path {
        case .quality:
            guard scale.denominator == 1,
                  scale.numerator == 2 || scale.numerator == 4 else {
                throw VTNativeSuperResolutionError.rejected(
                    .routeContractMismatch
                )
            }
            subjectID = scale.numerator == 2 ? .quality2x : .quality4x
            routeID = scale.numerator == 2 ? .quality2x : .quality4x
            backendKind = .quality
            gate = .runtimeSupportRequired
            temporalPolicy = .qualitySequential
            opticalFlowRole = .optionalQualityInput
            precomputedFlowChoice = .optionalPerRequest
            qualityPriority = .quality
            modelStatus = .notObserved
            processingMode = .qualityTemporal
        case .lowLatency:
            (subjectID, routeID) = lowLatencyIdentity(
                scaleFactor: plan.nativeScaleFactor
            )
            backendKind = .lowLatency
            gate = .exactDimensionQueryRequired
            temporalPolicy = .statelessRandom
            opticalFlowRole = .notApplicable
            precomputedFlowChoice = .notApplicable
            qualityPriority = .notApplicable
            modelStatus = .notRequired
            processingMode = .lowLatencyStateless
        }
        return try R04VideoToolboxRouteDescriptor(
            subjectID: subjectID,
            routeID: routeID,
            capabilityID: plan.path == .quality ? "A01" : "A02",
            backendKind: backendKind,
            sourceResolution: plan.nativeSourceResolution,
            targetResolution: plan.nativeTargetResolution,
            scaleFactor: scale,
            gate: gate,
            configurationContract: R04VideoToolboxConfigurationContract(
                frameWidth: plan.nativeSourceResolution.width,
                frameHeight: plan.nativeSourceResolution.height,
                scaleFactorIdentity: identity,
                inputType: .video,
                precomputedFlowChoice: precomputedFlowChoice,
                qualityPriority: qualityPriority,
                revision: .runtimeSelectedNotObserved,
                supportedFormats: .notObserved,
                modelStatus: modelStatus,
                processingMode: processingMode,
                exactDimensionQueryRequired: plan.path == .lowLatency
            ),
            temporalPolicy: temporalPolicy,
            opticalFlowRole: opticalFlowRole,
            productDefaultEligibility: .candidateAfterObservedQualification
        )
    }

    private static func lowLatencyIdentity(
        scaleFactor: Float
    ) -> (R04VideoToolboxSubjectID, R04VideoToolboxRouteID) {
        switch scaleFactor {
        case 1.5:
            return (.lowLatency1p5x, .lowLatency1p5x)
        case 4:
            return (.lowLatency4x, .lowLatency4x)
        default:
            return (.lowLatency2x, .lowLatency2x)
        }
    }
}

enum VTAdaptiveMediaVideoFormatContract {
    static func makeColorDescription(
        for format: MediaVideoFormat
    ) throws -> AppleUpscaleColorDescription {
        try AppleUpscaleColorDescription(
            colorPrimaries: format.colorPrimaries.cmValue,
            transferFunction: format.transferFunction.cmValue,
            matrix: format.pixelStorage.usesYCbCr
                ? format.cmYCbCrMatrix
                : "identity",
            chromaSiting: format.chromaLocation ?? "not_applicable",
            range: format.pixelStorage.codeRange == .video ? .video : .full
        )
    }

    static func matches(
        frame: AppleUpscaleFrame,
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) -> Bool {
        guard let expected = try? makeColorDescription(for: format) else {
            return false
        }
        return frame.colorDescription == expected
            && matches(
                pixelBuffer: frame.pixelBuffer,
                resolution: resolution,
                format: format
            )
    }

    static func matches(
        pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) -> Bool {
        do {
            try R13MediaVideoFormatContract.validate(
                pixelBuffer,
                resolution: resolution,
                format: format
            )
            return true
        } catch {
            return false
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
    private let videoFormat: MediaVideoFormat
    private let usesPrecomputedFlow: Bool
    private let processor: VTFrameProcessor
    private let sourcePool: VTNativePixelBufferPool
    private let destinationPool: VTNativePixelBufferPool
    private let formatOutputPool: VTNativePixelBufferPool
    private let colorBridge: VTNativeQualityPixelBufferBridge

    private var previousSourceFrame: VTFrameProcessorFrame?
    private var previousOutputFrame: VTFrameProcessorFrame?
    private var previousSequenceNumber: Int?
    private var previousPresentationTimestamp: CMTime?
    private var previousDuration: CMTime?
    private var acceptedHistoryGeneration: UInt64?
    private var adaptivePreviousSource: R04VideoToolboxHistoryFrame?
    private var adaptivePreviousOutput: R04VideoToolboxHistoryFrame?
    private var ended = false

    init(
        route: R04VideoToolboxRouteDescriptor,
        flowConfiguration: VTNativeQualityFlowConfiguration,
        videoFormat: MediaVideoFormat = .sdrBT709
    ) throws {
        let configuration = try VTNativeSRConfigurationBuilder
            .quality(
                sourceResolution: route.sourceResolution,
                scaleFactor: route.scaleFactor,
                flowConfiguration: flowConfiguration
            )
        guard configuration.supportedPixelFormats.contains(
            VTNativeQualityPixelBufferBridge.nativePixelFormat
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
        self.videoFormat = videoFormat
        usesPrecomputedFlow = flowConfiguration.usesPrecomputedFlow
        sourcePool = try VTNativePixelBufferPool(
            requiredAttributes: configuration.sourcePixelBufferAttributes,
            resolution: route.sourceResolution,
            pixelFormat: VTNativeQualityPixelBufferBridge.nativePixelFormat,
            expectedPlaneCount: 0
        )
        destinationPool = try VTNativePixelBufferPool(
            requiredAttributes: configuration.destinationPixelBufferAttributes,
            resolution: route.targetResolution,
            pixelFormat: VTNativeQualityPixelBufferBridge.nativePixelFormat,
            expectedPlaneCount: 0
        )
        formatOutputPool = try VTNativePixelBufferPool(
            requiredAttributes: [:],
            resolution: route.targetResolution,
            pixelFormat: videoFormat.pixelStorage.pixelFormat,
            expectedPlaneCount: videoFormat.pixelStorage.expectedPlaneCount,
            requiresMetalCompatibility: false
        )
        colorBridge = try VTNativeQualityPixelBufferBridge(
            videoFormat: videoFormat
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

        let sourceBuffer = try sourcePool.makePixelBuffer()
        try colorBridge.convertVideoFormat(
            request.sourceFrame.pixelBuffer,
            toNativeRGBAHalf: sourceBuffer,
            resolution: route.sourceResolution
        )
        let destinationBuffer = try destinationPool.makePixelBuffer()
        CVBufferPropagateAttachments(sourceBuffer, destinationBuffer)
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
        let formatOutput = try formatOutputPool.makePixelBuffer()
        try colorBridge.convertNativeRGBAHalf(
            destinationBuffer,
            toVideoFormat: formatOutput,
            resolution: route.targetResolution,
            metadataSource: request.sourceFrame.pixelBuffer
        )
        if videoFormat.hasAlpha {
            let alphaCarrier = try formatOutputPool.makePixelBuffer()
            try R13PixelLayoutProcessor.scaleVImage(
                source: request.sourceFrame.pixelBuffer,
                destination: alphaCarrier,
                flags: vImage_Flags(
                    kvImageEdgeExtend | kvImageHighQualityResampling
                )
            )
            try VTNativeAlphaStoragePreserver.restoreAlpha(
                from: alphaCarrier,
                to: formatOutput
            )
        }
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            formatOutput,
            format: videoFormat
        )
        R13PixelLayoutProcessor.copyAttachments(
            source: request.sourceFrame.pixelBuffer,
            destination: formatOutput
        )
        R13MediaVideoFormatContract.install(
            videoFormat,
            on: formatOutput,
            resolution: route.targetResolution
        )
        try R13PixelLayoutProcessor.enforceCodeBounds(formatOutput)
        try R13MediaVideoFormatContract.validate(
            formatOutput,
            resolution: route.targetResolution,
            format: videoFormat
        )
        previousSourceFrame = sourceFrame
        previousOutputFrame = destinationFrame
        previousSequenceNumber = request.sourceFrame.sequenceNumber
        previousPresentationTimestamp = request.sourceFrame.presentationTimestamp
        previousDuration = request.sourceFrame.duration
        acceptedHistoryGeneration = request.historyGeneration
        return formatOutput
    }

    func processAdaptive(
        _ frame: AppleUpscaleFrame,
        historyGeneration: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer {
        let continuing = acceptedHistoryGeneration == historyGeneration
            && adaptivePreviousSource != nil
            && adaptivePreviousOutput != nil
            && previousSequenceNumber != nil
            && previousPresentationTimestamp != nil
            && previousDuration != nil
            && VTNativeTemporalContinuity.isContiguous(
                previousSequenceNumber: previousSequenceNumber ?? -1,
                previousPresentationTimestamp: previousPresentationTimestamp
                    ?? .invalid,
                previousDuration: previousDuration ?? .invalid,
                currentSequenceNumber: frame.sequenceNumber,
                currentPresentationTimestamp: frame.presentationTimestamp,
                currentDuration: frame.duration
            )
        let boundary: R04VideoToolboxHistoryBoundary = continuing
            ? .continuing
            : .firstFrame
        let request = R04VideoToolboxProcessingRequest(
            route: route,
            sourceFrame: frame,
            previousSource: continuing ? adaptivePreviousSource : nil,
            previousOutput: continuing ? adaptivePreviousOutput : nil,
            historyGeneration: historyGeneration,
            historyBoundary: boundary,
            submissionMode: route.temporalPolicy.submissionMode(for: boundary),
            opticalFlowMode: .appleComputed
        )
        let output = try await process(request, cancellation: cancellation)
        adaptivePreviousSource = R04VideoToolboxHistoryFrame(
            sequenceNumber: frame.sequenceNumber,
            pixelBuffer: frame.pixelBuffer,
            presentationTimestamp: frame.presentationTimestamp,
            duration: frame.duration
        )
        adaptivePreviousOutput = R04VideoToolboxHistoryFrame(
            sequenceNumber: frame.sequenceNumber,
            pixelBuffer: output,
            presentationTimestamp: frame.presentationTimestamp,
            duration: frame.duration
        )
        return output
    }

    func resetAdaptiveHistory() {
        clearHistory()
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
        adaptivePreviousSource = nil
        adaptivePreviousOutput = nil
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
final class VTNativeLowLatencySuperResolutionSession:
    VTNativeSuperResolutionSession,
    @unchecked Sendable {
    private let route: R04VideoToolboxRouteDescriptor
    private let videoFormat: MediaVideoFormat
    private let processor: VTFrameProcessor
    private let sourcePool: VTNativePixelBufferPool
    private let destinationPool: VTNativePixelBufferPool
    private let baselineGuidePool: VTNativePixelBufferPool
    private let formatOutputPool: VTNativePixelBufferPool
    private let guideBridge: VTNativeLowLatencyGuideBridge
    private let evidenceState = OSAllocatedUnfairLock<
        VTNativeLowLatencyCompositeEvidence?
    >(initialState: nil)
    private var ended = false

    var lastCompositeEvidence: VTNativeLowLatencyCompositeEvidence? {
        evidenceState.withLock { $0 }
    }

    convenience init(route: R04VideoToolboxRouteDescriptor) throws {
        let configuration = try VTNativeSRConfigurationBuilder
            .lowLatency(route: route)
        try self.init(
            route: route,
            configuration: configuration,
            videoFormat: .sdrBT709
        )
    }

    convenience init(
        adaptiveRoute route: R04VideoToolboxRouteDescriptor,
        requestedScale: Float,
        videoFormat: MediaVideoFormat = .sdrBT709
    ) throws {
        let configuration = try VTNativeSRConfigurationBuilder.lowLatency(
            sourceResolution: route.sourceResolution,
            targetResolution: route.targetResolution,
            requestedScale: requestedScale
        )
        try self.init(
            route: route,
            configuration: configuration,
            videoFormat: videoFormat
        )
    }

    private init(
        route: R04VideoToolboxRouteDescriptor,
        configuration: VTLowLatencySuperResolutionScalerConfiguration,
        videoFormat: MediaVideoFormat
    ) throws {
        guard configuration.supportedPixelFormats.contains(
            R04VideoToolboxRouteCatalog.pixelFormat
        ) else {
            throw VTNativeSuperResolutionError.rejected(.unsupportedPixelFormat)
        }

        self.route = route
        self.videoFormat = videoFormat
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
        baselineGuidePool = try VTNativePixelBufferPool(
            requiredAttributes: [:],
            resolution: route.targetResolution,
            pixelFormat: R04VideoToolboxRouteCatalog.pixelFormat
        )
        formatOutputPool = try VTNativePixelBufferPool(
            requiredAttributes: [:],
            resolution: route.targetResolution,
            pixelFormat: videoFormat.pixelStorage.pixelFormat,
            expectedPlaneCount: videoFormat.pixelStorage.expectedPlaneCount,
            requiresMetalCompatibility: false
        )
        guideBridge = try VTNativeLowLatencyGuideBridge(
            videoFormat: videoFormat
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

        try R13MediaVideoFormatContract.validate(
            request.sourceFrame.pixelBuffer,
            resolution: route.sourceResolution,
            format: videoFormat
        )
        let sourceBuffer: CVPixelBuffer
        if videoFormat.pixelStorage.pixelFormat
            == R04VideoToolboxRouteCatalog.pixelFormat {
            sourceBuffer = try sourcePool.stage(
                request.sourceFrame.pixelBuffer
            )
        } else {
            sourceBuffer = try sourcePool.makePixelBuffer()
            try guideBridge.convertToNativeGuide(
                request.sourceFrame.pixelBuffer,
                destination: sourceBuffer,
                resolution: route.sourceResolution
            )
        }
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
        let baselineGuide = try baselineGuidePool.makePixelBuffer()
        try R13PixelLayoutProcessor.scaleVImage(
            source: sourceBuffer,
            destination: baselineGuide,
            flags: vImage_Flags(
                kvImageEdgeExtend | kvImageHighQualityResampling
            )
        )

        let output: CVPixelBuffer
        let evidence: VTNativeLowLatencyCompositeEvidence
        if videoFormat.pixelStorage.pixelFormat
            == R04VideoToolboxRouteCatalog.pixelFormat {
            output = destinationBuffer
            evidence = try VTNativeLowLatencyGuideComposite.analyze(
                nativeGuide: destinationBuffer,
                baselineGuide: baselineGuide,
                resolution: route.targetResolution
            )
        } else {
            let carrier = try formatOutputPool.makePixelBuffer()
            // This pass establishes output geometry in the original storage.
            // It is not the selected upscale result: the native guide delta is
            // applied below and is required to affect textured output.
            try R13PixelLayoutProcessor.scaleVImage(
                source: request.sourceFrame.pixelBuffer,
                destination: carrier,
                flags: vImage_Flags(
                    kvImageEdgeExtend | kvImageHighQualityResampling
                )
            )
            evidence = try VTNativeLowLatencyGuideComposite.apply(
                nativeGuide: destinationBuffer,
                baselineGuide: baselineGuide,
                to: carrier,
                resolution: route.targetResolution,
                format: videoFormat
            )
            output = carrier
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
        R13PixelLayoutProcessor.copyAttachments(
            source: request.sourceFrame.pixelBuffer,
            destination: output
        )
        R13MediaVideoFormatContract.install(
            videoFormat,
            on: output,
            resolution: route.targetResolution
        )
        try R13PixelLayoutProcessor.enforceCodeBounds(output)
        try R13MediaVideoFormatContract.validate(
            output,
            resolution: route.targetResolution,
            format: videoFormat
        )
        evidenceState.withLock { $0 = evidence }
        return output
    }

    func processAdaptive(
        _ frame: AppleUpscaleFrame,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer {
        try await process(
            R04VideoToolboxProcessingRequest(
                route: route,
                sourceFrame: frame,
                previousSource: nil,
                previousOutput: nil,
                historyGeneration: 0,
                historyBoundary: .notApplicable,
                submissionMode: .random,
                opticalFlowMode: .disabled
            ),
            cancellation: cancellation
        )
    }

    func end() {
        guard !ended else { return }
        ended = true
        processor.endSession()
    }

}

@available(macOS 26.0, *)
struct VTNativeLowLatencyCompositeEvidence: Equatable, Sendable {
    let nativeGuideChangedSampleCount: Int
    let guideApplicationChangedSampleCount: Int
    let maximumAbsoluteNormalizedGuideDelta: Double
}

@available(macOS 26.0, *)
final class VTNativeLowLatencyGuideBridge: @unchecked Sendable {
    private let videoFormat: MediaVideoFormat
    private let transferSession: VTPixelTransferSession
    private let executionLock = NSLock()

    init(videoFormat: MediaVideoFormat) throws {
        self.videoFormat = videoFormat
        var optionalSession: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &optionalSession
        )
        guard status == noErr, let session = optionalSession else {
            throw VTNativeSuperResolutionError.failed(.inputPreparation)
        }
        do {
            try Self.set(
                session,
                key: kVTPixelTransferPropertyKey_ScalingMode,
                value: kVTScalingMode_Normal
            )
            try Self.set(
                session,
                key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                value: videoFormat.colorPrimaries.cmValue as CFString
            )
            try Self.set(
                session,
                key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                value: videoFormat.transferFunction.cmValue as CFString
            )
            try Self.set(
                session,
                key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                value: videoFormat.cmYCbCrMatrix as CFString
            )
            try Self.set(
                session,
                key: kVTPixelTransferPropertyKey_DownsamplingMode,
                value: kVTDownsamplingMode_Average
            )
            try Self.set(
                session,
                key: kVTPixelTransferPropertyKey_RealTime,
                value: kCFBooleanFalse
            )
            transferSession = session
        } catch {
            VTPixelTransferSessionInvalidate(session)
            throw error
        }
    }

    deinit {
        VTPixelTransferSessionInvalidate(transferSession)
    }

    func convertToNativeGuide(
        _ source: CVPixelBuffer,
        destination: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: resolution,
            format: videoFormat
        )
        try VTNativeLowLatencyGuideContract.validate(
            destination,
            resolution: resolution
        )
        executionLock.lock()
        let status = VTPixelTransferSessionTransferImage(
            transferSession,
            from: source,
            to: destination
        )
        executionLock.unlock()
        guard status == noErr else {
            throw VTNativeSuperResolutionError.failed(.inputPreparation)
        }
        R13PixelLayoutProcessor.copyAttachments(
            source: source,
            destination: destination
        )
        CVBufferRemoveAttachment(
            destination,
            kCVImageBufferAlphaChannelModeKey
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferColorPrimariesKey,
            videoFormat.colorPrimaries.cmValue as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferTransferFunctionKey,
            videoFormat.transferFunction.cmValue as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferYCbCrMatrixKey,
            videoFormat.cmYCbCrMatrix as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            destination,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        R13NV12GeometryTransfer.installCanonicalAttachments(
            on: destination,
            resolution: resolution
        )
    }

    private static func set(
        _ session: VTPixelTransferSession,
        key: CFString,
        value: CFTypeRef
    ) throws {
        guard VTSessionSetProperty(
            session,
            key: key,
            value: value
        ) == noErr else {
            throw VTNativeSuperResolutionError.failed(.inputPreparation)
        }
    }
}

@available(macOS 26.0, *)
enum VTNativeLowLatencyGuideComposite {
    static func analyze(
        nativeGuide: CVPixelBuffer,
        baselineGuide: CVPixelBuffer,
        resolution: VideoResolution
    ) throws -> VTNativeLowLatencyCompositeEvidence {
        try VTNativeLowLatencyGuideContract.validate(
            nativeGuide,
            resolution: resolution
        )
        try VTNativeLowLatencyGuideContract.validate(
            baselineGuide,
            resolution: resolution
        )
        try R13PixelLayoutProcessor.lockReadOnly(nativeGuide)
        defer { CVPixelBufferUnlockBaseAddress(nativeGuide, .readOnly) }
        try R13PixelLayoutProcessor.lockReadOnly(baselineGuide)
        defer { CVPixelBufferUnlockBaseAddress(baselineGuide, .readOnly) }
        let result = try guideDifferenceLocked(
            nativeGuide: nativeGuide,
            baselineGuide: baselineGuide,
            resolution: resolution
        )
        return VTNativeLowLatencyCompositeEvidence(
            nativeGuideChangedSampleCount: result.changedCount,
            guideApplicationChangedSampleCount: result.changedCount,
            maximumAbsoluteNormalizedGuideDelta: result.maximumDelta
        )
    }

    static func apply(
        nativeGuide: CVPixelBuffer,
        baselineGuide: CVPixelBuffer,
        to carrier: CVPixelBuffer,
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) throws -> VTNativeLowLatencyCompositeEvidence {
        try VTNativeLowLatencyGuideContract.validate(
            nativeGuide,
            resolution: resolution
        )
        try VTNativeLowLatencyGuideContract.validate(
            baselineGuide,
            resolution: resolution
        )
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(carrier)
        )
        try layout.validate(carrier)
        guard format.pixelStorage.pixelFormat == layout.pixelFormat,
              CVPixelBufferGetWidth(carrier) == resolution.width,
              CVPixelBufferGetHeight(carrier) == resolution.height,
              let effect = effectComponents(in: layout) else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }

        // Establish a valid baseline before the native guide changes color.
        // The second pass below repairs any premultiplied-alpha violation
        // introduced by those changes. Straight and opaque formats are no-ops.
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            carrier,
            format: format
        )

        try R13PixelLayoutProcessor.lockReadOnly(nativeGuide)
        defer { CVPixelBufferUnlockBaseAddress(nativeGuide, .readOnly) }
        try R13PixelLayoutProcessor.lockReadOnly(baselineGuide)
        defer { CVPixelBufferUnlockBaseAddress(baselineGuide, .readOnly) }
        let evidence: VTNativeLowLatencyCompositeEvidence = try {
            try R13PixelLayoutProcessor.lockWritable(carrier)
            defer { CVPixelBufferUnlockBaseAddress(carrier, []) }

            let nativeBase = try guideLumaBase(nativeGuide)
            let baselineBase = try guideLumaBase(baselineGuide)
            let nativeStride = CVPixelBufferGetBytesPerRowOfPlane(nativeGuide, 0)
            let baselineStride = CVPixelBufferGetBytesPerRowOfPlane(
                baselineGuide,
                0
            )
            let carrierBase = try R13PixelBufferAccess.baseAddress(
                of: carrier,
                layout: layout,
                plane: effect.planeIndex
            )
            let carrierStride = R13PixelBufferAccess.rowBytes(
                of: carrier,
                layout: layout,
                plane: effect.planeIndex
            )
            let plane = layout.planes[effect.planeIndex]
            var nativeChangedCount = 0
            var outputChangedCount = 0
            var maximumDelta = 0.0
            for row in 0..<resolution.height {
                let nativeRow = nativeBase
                    .advanced(by: row * nativeStride)
                    .assumingMemoryBound(to: UInt8.self)
                let baselineRow = baselineBase
                    .advanced(by: row * baselineStride)
                    .assumingMemoryBound(to: UInt8.self)
                for column in 0..<resolution.width {
                    let codeDelta = Int(nativeRow[column])
                        - Int(baselineRow[column])
                    guard codeDelta != 0 else { continue }
                    nativeChangedCount += 1
                    let normalizedDelta = Double(codeDelta) / 219.0
                    maximumDelta = max(maximumDelta, abs(normalizedDelta))
                    if apply(
                        normalizedDelta: normalizedDelta,
                        column: column,
                        row: row,
                        components: effect.componentIndices,
                        plane: plane,
                        base: carrierBase,
                        stride: carrierStride
                    ) {
                        outputChangedCount += 1
                    }
                }
            }
            try R13PixelLayoutProcessor.enforceCodeBoundsLocked(
                carrier,
                layout: layout
            )
            return VTNativeLowLatencyCompositeEvidence(
                nativeGuideChangedSampleCount: nativeChangedCount,
                guideApplicationChangedSampleCount: outputChangedCount,
                maximumAbsoluteNormalizedGuideDelta: maximumDelta
            )
        }()
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            carrier,
            format: format
        )
        return evidence
    }

    private static func guideDifferenceLocked(
        nativeGuide: CVPixelBuffer,
        baselineGuide: CVPixelBuffer,
        resolution: VideoResolution
    ) throws -> (changedCount: Int, maximumDelta: Double) {
        let nativeBase = try guideLumaBase(nativeGuide)
        let baselineBase = try guideLumaBase(baselineGuide)
        let nativeStride = CVPixelBufferGetBytesPerRowOfPlane(nativeGuide, 0)
        let baselineStride = CVPixelBufferGetBytesPerRowOfPlane(
            baselineGuide,
            0
        )
        var changedCount = 0
        var maximumDelta = 0.0
        for row in 0..<resolution.height {
            let nativeRow = nativeBase
                .advanced(by: row * nativeStride)
                .assumingMemoryBound(to: UInt8.self)
            let baselineRow = baselineBase
                .advanced(by: row * baselineStride)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<resolution.width {
                let delta = Int(nativeRow[column]) - Int(baselineRow[column])
                guard delta != 0 else { continue }
                changedCount += 1
                maximumDelta = max(
                    maximumDelta,
                    abs(Double(delta) / 219.0)
                )
            }
        }
        return (changedCount, maximumDelta)
    }

    private static func effectComponents(
        in layout: R13PixelLayout
    ) -> (planeIndex: Int, componentIndices: [Int])? {
        guard let planeIndex = layout.planes.firstIndex(where: {
            $0.role == .luma
                || $0.role == .packedAYCbCr
                || $0.role == .packedBGRA
        }) else {
            return nil
        }
        switch layout.planes[planeIndex].role {
        case .luma:
            return (planeIndex, [0])
        case .packedAYCbCr:
            return (planeIndex, [1])
        case .packedBGRA:
            return (planeIndex, [0, 1, 2])
        default:
            return nil
        }
    }

    private static func guideLumaBase(
        _ guide: CVPixelBuffer
    ) throws -> UnsafeMutableRawPointer {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(guide, 0) else {
            throw VTNativeSuperResolutionError.failed(.pixelBufferCopy)
        }
        return base
    }

    private static func apply(
        normalizedDelta: Double,
        column: Int,
        row: Int,
        components: [Int],
        plane: R13PixelPlaneLayout,
        base: UnsafeMutableRawPointer,
        stride: Int
    ) -> Bool {
        var changed = false
        for component in components {
            let componentIndex =
                column * plane.componentsPerElement + component
            let bounds = plane.componentBounds[component]
            let span = Int(bounds.maximum - bounds.minimum)
            let delta = Int((normalizedDelta * Double(span)).rounded())
            let original: Int
            if plane.bytesPerComponent == 1 {
                original = Int(
                    base.advanced(by: row * stride)
                        .assumingMemoryBound(to: UInt8.self)[componentIndex]
                )
            } else {
                original = Int(
                    base.advanced(by: row * stride)
                        .assumingMemoryBound(to: UInt16.self)[componentIndex]
                        >> UInt16(plane.storedCodeShift)
                )
            }
            let updated = min(
                max(original + delta, Int(bounds.minimum)),
                Int(bounds.maximum)
            )
            guard updated != original else { continue }
            changed = true
            if plane.bytesPerComponent == 1 {
                base.advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)[componentIndex] =
                    UInt8(updated)
            } else {
                base.advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt16.self)[componentIndex] =
                    UInt16(updated) << UInt16(plane.storedCodeShift)
            }
        }
        return changed
    }
}

@available(macOS 26.0, *)
private enum VTNativeLowLatencyGuideContract {
    static func validate(
        _ pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == R04VideoToolboxRouteCatalog.pixelFormat,
              CVPixelBufferGetWidth(pixelBuffer) == resolution.width,
              CVPixelBufferGetHeight(pixelBuffer) == resolution.height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == resolution.width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == resolution.height,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) == resolution.width / 2,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) == resolution.height / 2,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
    }
}

@available(macOS 26.0, *)
final class VTNativeQualityPixelBufferBridge: @unchecked Sendable {
    static let nativePixelFormat = kCVPixelFormatType_64RGBAHalf

    private enum TransferDirection {
        case toNative
        case fromNative
    }

    let videoFormat: MediaVideoFormat

    private var toNativeSession: VTPixelTransferSession?
    private var fromNativeSession: VTPixelTransferSession?
    private let executionLock = NSLock()

    init() {
        videoFormat = .sdrBT709
        toNativeSession = nil
        fromNativeSession = nil
    }

    init(videoFormat: MediaVideoFormat) throws {
        let createdToNative = try Self.makeTransferSession(
            videoFormat: videoFormat,
            destinationUsesYCbCr: false
        )
        do {
            let createdFromNative = try Self.makeTransferSession(
                videoFormat: videoFormat,
                destinationUsesYCbCr: videoFormat.pixelStorage.usesYCbCr
            )
            self.videoFormat = videoFormat
            toNativeSession = createdToNative
            fromNativeSession = createdFromNative
        } catch {
            VTPixelTransferSessionInvalidate(createdToNative)
            throw error
        }
    }

    deinit {
        if let toNativeSession {
            VTPixelTransferSessionInvalidate(toNativeSession)
        }
        if let fromNativeSession {
            VTPixelTransferSessionInvalidate(fromNativeSession)
        }
    }

    func convertVideoFormat(
        _ source: CVPixelBuffer,
        toNativeRGBAHalf destination: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: resolution,
            format: videoFormat
        )
        try Self.validateNativeRGBAHalf(
            destination,
            resolution: resolution
        )
        try transfer(
            direction: .toNative,
            source: source,
            destination: destination,
            failure: .inputPreparation
        )
        R13PixelLayoutProcessor.copyAttachments(
            source: source,
            destination: destination
        )
        R13NV12GeometryTransfer.installCanonicalAttachments(
            on: destination,
            resolution: resolution
        )
    }

    func convertCanonicalNV12(
        _ source: CVPixelBuffer,
        toNativeRGBAHalf destination: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        guard videoFormat == .sdrBT709 else {
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }
        try convertVideoFormat(
            source,
            toNativeRGBAHalf: destination,
            resolution: resolution
        )
    }

    func convertNativeRGBAHalf(
        _ source: CVPixelBuffer,
        toVideoFormat destination: CVPixelBuffer,
        resolution: VideoResolution,
        metadataSource: CVPixelBuffer
    ) throws {
        try Self.validateNativeRGBAHalf(
            source,
            resolution: resolution
        )
        try videoFormat.validate(pixelBuffer: destination)
        guard CVPixelBufferGetWidth(destination) == resolution.width,
              CVPixelBufferGetHeight(destination) == resolution.height else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
        try transfer(
            direction: .fromNative,
            source: source,
            destination: destination,
            failure: .processing
        )
        R13PixelLayoutProcessor.copyAttachments(
            source: metadataSource,
            destination: destination
        )
        R13MediaVideoFormatContract.install(
            videoFormat,
            on: destination,
            resolution: resolution
        )
        try R13PixelLayoutProcessor.enforceCodeBounds(destination)
        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: resolution,
            format: videoFormat
        )
    }

    func convertNativeRGBAHalf(
        _ source: CVPixelBuffer,
        toCanonicalNV12 destination: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        guard videoFormat == .sdrBT709 else {
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }
        try convertNativeRGBAHalf(
            source,
            toVideoFormat: destination,
            resolution: resolution,
            metadataSource: source
        )
    }

    private func transfer(
        direction: TransferDirection,
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        failure: VTNativeSuperResolutionFailureReason
    ) throws {
        executionLock.lock()
        defer { executionLock.unlock() }
        let session: VTPixelTransferSession
        switch direction {
        case .toNative:
            if let toNativeSession {
                session = toNativeSession
            } else {
                session = try Self.makeTransferSession(
                    videoFormat: videoFormat,
                    destinationUsesYCbCr: false
                )
                toNativeSession = session
            }
        case .fromNative:
            if let fromNativeSession {
                session = fromNativeSession
            } else {
                session = try Self.makeTransferSession(
                    videoFormat: videoFormat,
                    destinationUsesYCbCr:
                        videoFormat.pixelStorage.usesYCbCr
                )
                fromNativeSession = session
            }
        }
        let status = VTPixelTransferSessionTransferImage(
            session,
            from: source,
            to: destination
        )
        guard status == noErr else {
            throw VTNativeSuperResolutionError.failed(failure)
        }
    }

    private static func validateNativeRGBAHalf(
        _ pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        guard CVPixelBufferGetWidth(pixelBuffer) == resolution.width,
              CVPixelBufferGetHeight(pixelBuffer) == resolution.height,
              CVPixelBufferGetPixelFormatType(pixelBuffer)
                == nativePixelFormat,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            throw VTNativeSuperResolutionError.rejected(
                .routeContractMismatch
            )
        }
    }

    private static func makeTransferSession(
        videoFormat: MediaVideoFormat,
        destinationUsesYCbCr: Bool
    ) throws -> VTPixelTransferSession {
        var optionalSession: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &optionalSession
        )
        guard status == noErr, let session = optionalSession else {
            throw VTNativeSuperResolutionError.failed(.inputPreparation)
        }
        do {
            try set(
                session,
                key: kVTPixelTransferPropertyKey_ScalingMode,
                value: kVTScalingMode_Normal
            )
            try set(
                session,
                key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                value: videoFormat.colorPrimaries.cmValue as CFString
            )
            try set(
                session,
                key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                value: videoFormat.transferFunction.cmValue as CFString
            )
            if destinationUsesYCbCr {
                try set(
                    session,
                    key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                    value: videoFormat.cmYCbCrMatrix as CFString
                )
                try set(
                    session,
                    key: kVTPixelTransferPropertyKey_DownsamplingMode,
                    value: kVTDownsamplingMode_Average
                )
            }
            try set(
                session,
                key: kVTPixelTransferPropertyKey_RealTime,
                value: kCFBooleanFalse
            )
            return session
        } catch {
            VTPixelTransferSessionInvalidate(session)
            throw error
        }
    }

    private static func set(
        _ session: VTPixelTransferSession,
        key: CFString,
        value: CFTypeRef
    ) throws {
        guard VTSessionSetProperty(
            session,
            key: key,
            value: value
        ) == noErr else {
            throw VTNativeSuperResolutionError.failed(.inputPreparation)
        }
    }
}

@available(macOS 26.0, *)
enum VTNativeAlphaStoragePreserver {
    static func restoreAlpha(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        guard pixelFormat == CVPixelBufferGetPixelFormatType(destination),
              CVPixelBufferGetWidth(source) == CVPixelBufferGetWidth(destination),
              CVPixelBufferGetHeight(source) == CVPixelBufferGetHeight(destination)
        else {
            throw VTNativeSuperResolutionError.rejected(.routeContractMismatch)
        }
        let layout = try R13PixelLayoutRegistry.layout(for: pixelFormat)
        try layout.validate(source)
        try layout.validate(destination)
        guard let alpha = alphaComponent(in: layout) else { return }

        try R13PixelLayoutProcessor.lockReadOnly(source)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        try R13PixelLayoutProcessor.lockWritable(destination)
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let plane = layout.planes[alpha.planeIndex]
        let width = plane.width(for: CVPixelBufferGetWidth(source))
        let height = plane.height(for: CVPixelBufferGetHeight(source))
        let sourceBase = try R13PixelBufferAccess.baseAddress(
            of: source,
            layout: layout,
            plane: alpha.planeIndex
        )
        let destinationBase = try R13PixelBufferAccess.baseAddress(
            of: destination,
            layout: layout,
            plane: alpha.planeIndex
        )
        let sourceStride = R13PixelBufferAccess.rowBytes(
            of: source,
            layout: layout,
            plane: alpha.planeIndex
        )
        let destinationStride = R13PixelBufferAccess.rowBytes(
            of: destination,
            layout: layout,
            plane: alpha.planeIndex
        )
        for row in 0..<height {
            for column in 0..<width {
                let componentIndex =
                    column * plane.componentsPerElement + alpha.componentIndex
                if plane.bytesPerComponent == 1 {
                    destinationBase
                        .advanced(by: row * destinationStride)
                        .assumingMemoryBound(to: UInt8.self)[componentIndex] =
                        sourceBase
                        .advanced(by: row * sourceStride)
                        .assumingMemoryBound(to: UInt8.self)[componentIndex]
                } else {
                    destinationBase
                        .advanced(by: row * destinationStride)
                        .assumingMemoryBound(to: UInt16.self)[componentIndex] =
                        sourceBase
                        .advanced(by: row * sourceStride)
                        .assumingMemoryBound(to: UInt16.self)[componentIndex]
                }
            }
        }
    }

    private static func alphaComponent(
        in layout: R13PixelLayout
    ) -> (planeIndex: Int, componentIndex: Int)? {
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == .alpha }
        ) {
            return (planeIndex, 0)
        }
        guard let plane = layout.planes.first else { return nil }
        switch plane.role {
        case .packedAYCbCr:
            return (0, 0)
        case .packedBGRA:
            return (0, 3)
        default:
            return nil
        }
    }
}

@available(macOS 26.0, *)
private final class VTNativePixelBufferPool: @unchecked Sendable {
    private let pool: CVPixelBufferPool
    private let resolution: VideoResolution
    private let pixelFormat: OSType
    private let expectedPlaneCount: Int

    init(
        requiredAttributes: [String: any Sendable],
        resolution: VideoResolution,
        pixelFormat: OSType,
        expectedPlaneCount: Int = 2,
        requiresMetalCompatibility: Bool = true
    ) throws {
        var clientAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        if requiresMetalCompatibility {
            clientAttributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        }
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
        self.expectedPlaneCount = expectedPlaneCount
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
              CVPixelBufferGetPlaneCount(pixelBuffer)
                == expectedPlaneCount else {
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
