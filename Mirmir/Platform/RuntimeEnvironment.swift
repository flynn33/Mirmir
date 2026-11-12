import Accelerate
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Metal
import MetalFX
import MetalPerformanceShaders
import VideoToolbox

struct RuntimeOperatingSystem: Equatable, Sendable {
    let majorVersion: Int
    let minorVersion: Int
    let patchVersion: Int

    init(_ version: OperatingSystemVersion) {
        majorVersion = version.majorVersion
        minorVersion = version.minorVersion
        patchVersion = version.patchVersion
    }
}

protocol BackendCapabilityProbing: Sendable {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability
}

struct RuntimeEnvironment: Sendable {
    let operatingSystem: RuntimeOperatingSystem
    let capabilityProbe: any BackendCapabilityProbing

    static func current() -> RuntimeEnvironment {
        RuntimeEnvironment(
            operatingSystem: RuntimeOperatingSystem(
                ProcessInfo.processInfo.operatingSystemVersion
            ),
            capabilityProbe: SystemBackendCapabilityProbe()
        )
    }
}

enum VTInterpolationSpatialGeometrySupport {
    static func unavailableReason(
        width: Int,
        height: Int
    ) -> BackendUnavailableReason? {
        guard #available(macOS 27.0, *) else { return nil }
        guard
            let maximumDimension = VTLowLatencyFrameInterpolationConfiguration
                .maximumDimension(forSpatialScaleFactor: 2),
            let maximumPixelCount = VTLowLatencyFrameInterpolationConfiguration
                .maximumPixelCount(forSpatialScaleFactor: 2)
        else {
            return .appleAPIUnsupported(
                details: "VideoToolbox did not report 2× Smooth Motion geometry limits"
            )
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(
            by: height
        )
        guard
            !overflow,
            width <= maximumDimension,
            height <= maximumDimension,
            pixelCount <= maximumPixelCount
        else {
            return .unsupportedSourceDimensions(
                width: width,
                height: height,
                details: "this Mac reports a maximum dimension of "
                    + "\(maximumDimension) and a maximum source pixel count "
                    + "of \(maximumPixelCount) for 2× Smooth Motion"
            )
        }
        return nil
    }
}

struct SystemBackendCapabilityProbe: BackendCapabilityProbing {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability {
        guard backendID.isConcreteBackend else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "Automatic is a selection policy, not a processing backend."
                )
            )
        }

        guard let sourceDimensions = integerDimensions(
            source.geometry.encodedSize ?? source.naturalSize
        ) else {
            return .unavailable(
                reason: .unsupportedSourceDimensions(
                    width: 0,
                    height: 0,
                    details: "AVFoundation did not expose a positive integral encoded raster."
                )
            )
        }
        guard let targetDimensions = integerDimensions(targetSize) else {
            return .unavailable(
                reason: .unsupportedTargetDimensions(
                    width: 0,
                    height: 0,
                    details: "The target must have positive integral dimensions."
                )
            )
        }

        switch backendID {
        case .automatic:
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "Automatic is a selection policy, not a processing backend."
                )
            )
        case .mirmirDeterministicCPU:
            return .available
        case .mirmirDeterministicMetal:
            return deterministicMetalAvailability()
        case .videoToolboxSuperResolutionQuality:
            return qualitySuperResolutionAvailability(
                source: sourceDimensions,
                target: targetDimensions
            )
        case .videoToolboxSuperResolutionLowLatency:
            return lowLatencySuperResolutionAvailability(
                source: sourceDimensions,
                target: targetDimensions
            )
        case .videoToolboxInterpolationWithSpatialScale:
            return interpolationAvailability(
                source: sourceDimensions,
                target: targetDimensions
            )
        case .metalFXSpatial:
            return metalFXAvailability(
                source: sourceDimensions,
                target: targetDimensions
            )
        case .mpsLanczos:
            return mpsAvailability(
                backendID: backendID,
                target: targetDimensions
            )
        case .mpsBilinear:
            return mpsAvailability(
                backendID: backendID,
                target: targetDimensions
            )
        case .coreImageLanczos:
            _ = CIFilter.lanczosScaleTransform()
            return .available
        case .coreImageBicubic:
            _ = CIFilter.bicubicScaleTransform()
            return .available
        case .vImageHighQuality, .vImageStandard:
            // vImage has no hardware support query. Successful compilation of
            // the active Accelerate API plus exact buffer validation during
            // preparation is the applicable capability boundary.
            return .available
        case .videoToolboxPixelTransfer:
            return pixelTransferAvailability()
        }
    }

    private func deterministicMetalAvailability() -> BackendAvailability {
        guard MTLCreateSystemDefaultDevice() != nil else {
            return .unavailable(reason: .noMetalDevice)
        }
        return .available
    }

    private func qualitySuperResolutionAvailability(
        source: IntegerDimensions,
        target: IntegerDimensions
    ) -> BackendAvailability {
        guard #available(macOS 26.0, *) else {
            return .unavailable(
                reason: .operatingSystemTooOld(requiredVersion: "26.0")
            )
        }
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "VTSuperResolutionScalerConfiguration.isSupported is false"
                )
            )
        }
        guard source.width <= 1_920, source.height <= 1_080 else {
            return .unavailable(
                reason: .unsupportedSourceDimensions(
                    width: source.width,
                    height: source.height,
                    details: "Apple's macOS video initializer accepts at most 1920 × 1080"
                )
            )
        }
        guard let scaleFactor = integerUniformScale(
            source: source,
            target: target
        ) else {
            return .unavailable(
                reason: .unsupportedScaleFactor(
                    details: "quality VideoToolbox super resolution requires one integral uniform factor"
                )
            )
        }
        let supportedScales = VTSuperResolutionScalerConfiguration
            .supportedScaleFactors
        guard supportedScales.contains(scaleFactor) else {
            return .unavailable(
                reason: .unsupportedScaleFactor(
                    details: "requested \(scaleFactor)×; this Mac reports \(supportedScales)"
                )
            )
        }
        let revision = VTSuperResolutionScalerConfiguration.defaultRevision
        guard VTSuperResolutionScalerConfiguration.supportedRevisions
            .contains(revision.rawValue) else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "the default VideoToolbox revision is not in the runtime-supported revision set"
                )
            )
        }
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: source.width,
            frameHeight: source.height,
            scaleFactor: scaleFactor,
            inputType: .video,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: revision
        ) else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "VideoToolbox rejected the source dimensions, scale, or revision"
                )
            )
        }

        switch configuration.configurationModelStatus {
        case .ready:
            // Model Ready is not enough: guests with Ready models still fail
            // VTFrameProcessor.startSession with VTFrameProcessorErrorDomain/-19730
            // and produce zero processed frames. Probe the session before advertising
            // availability so covered hosts fail closed instead of failing mid-job.
            if let reason = VTQualitySessionAdmissionV4.startSessionFailure(configuration) {
                return .unavailable(reason: reason)
            }
            return .available
        case .downloadRequired:
            return .modelDownloadRequired(progress: nil)
        case .downloading:
            return .modelDownloadRequired(
                progress: Double(configuration.configurationModelPercentageAvailable)
            )
        @unknown default:
            return .unavailable(
                reason: .modelUnavailable(
                    details: "VideoToolbox returned model status raw value \(configuration.configurationModelStatus.rawValue)"
                )
            )
        }
    }

    private func lowLatencySuperResolutionAvailability(
        source: IntegerDimensions,
        target: IntegerDimensions
    ) -> BackendAvailability {
        guard #available(macOS 26.0, *) else {
            return .unavailable(
                reason: .operatingSystemTooOld(requiredVersion: "26.0")
            )
        }
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "VTLowLatencySuperResolutionScalerConfiguration.isSupported is false"
                )
            )
        }
        guard let scaleFactor = uniformScale(source: source, target: target) else {
            return .unavailable(
                reason: .unsupportedScaleFactor(
                    details: "low-latency VideoToolbox super resolution requires one uniform factor"
                )
            )
        }
        let supportedScales = VTLowLatencySuperResolutionScalerConfiguration
            .supportedScaleFactors(
                frameWidth: source.width,
                frameHeight: source.height
            )
        let requestedScale = Float(scaleFactor)
        guard supportedScales.contains(where: {
            abs($0 - requestedScale) <= 0.000_001
        }) else {
            return .unavailable(
                reason: .unsupportedScaleFactor(
                    details: "requested \(requestedScale)×; this Mac reports \(supportedScales) for \(source.width) × \(source.height)"
                )
            )
        }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: source.width,
            frameHeight: source.height,
            scaleFactor: requestedScale
        )
        guard destinationDimensions(
            from: configuration.destinationPixelBufferAttributes
        ) == target else {
            return .unavailable(
                reason: .unsupportedTargetDimensions(
                    width: target.width,
                    height: target.height,
                    details: "VideoToolbox's destination attributes do not match the exact requested target"
                )
            )
        }
        return .available
    }

    private func interpolationAvailability(
        source: IntegerDimensions,
        target: IntegerDimensions
    ) -> BackendAvailability {
        guard #available(macOS 26.0, *) else {
            return .unavailable(
                reason: .operatingSystemTooOld(requiredVersion: "26.0")
            )
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "VTLowLatencyFrameInterpolationConfiguration.isSupported is false"
                )
            )
        }
        guard integerUniformScale(source: source, target: target) == 2 else {
            return .unavailable(
                reason: .unsupportedScaleFactor(
                    details: "the installed SDK documents only 2× spatial scaling for this combined effect"
                )
            )
        }
        if let reason = VTInterpolationSpatialGeometrySupport
            .unavailableReason(width: source.width, height: source.height) {
            return .unavailable(reason: reason)
        }
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: source.width,
            frameHeight: source.height,
            spatialScaleFactor: 2
        ) else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "VideoToolbox rejected the combined interpolation and spatial configuration"
                )
            )
        }
        guard destinationDimensions(
            from: configuration.destinationPixelBufferAttributes
        ) == target else {
            return .unavailable(
                reason: .unsupportedTargetDimensions(
                    width: target.width,
                    height: target.height,
                    details: "VideoToolbox's destination attributes do not match the exact requested target"
                )
            )
        }
        return .available
    }

    private func metalFXAvailability(
        source: IntegerDimensions,
        target: IntegerDimensions
    ) -> BackendAvailability {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .unavailable(reason: .noMetalDevice)
        }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "MTLFXSpatialScalerDescriptor.supportsDevice is false for \(device.name)"
                )
            )
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.inputWidth = source.width
        descriptor.inputHeight = source.height
        descriptor.outputWidth = target.width
        descriptor.outputHeight = target.height
        descriptor.colorProcessingMode = .linear
        guard descriptor.makeSpatialScaler(device: device) != nil else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "MetalFX rejected representative linear-RGB textures at the requested dimensions"
                )
            )
        }
        return .available
    }

    private func mpsAvailability(
        backendID: UpscaleBackendID,
        target: IntegerDimensions
    ) -> BackendAvailability {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .unavailable(reason: .noMetalDevice)
        }
        guard MPSSupportsMTLDevice(device) else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "MPSSupportsMTLDevice is false for \(device.name)"
                )
            )
        }
        guard device.makeCommandQueue() != nil else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "Metal could not create a command queue"
                )
            )
        }
        var textureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
        guard cacheStatus == kCVReturnSuccess, textureCache != nil else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "Core Video could not create a Metal texture cache (\(cacheStatus))"
                )
            )
        }
        if backendID == .mpsLanczos {
            _ = MPSImageLanczosScale(device: device)
        } else {
            _ = MPSImageBilinearScale(device: device)
        }
        return .available
    }

    private func pixelTransferAvailability() -> BackendAvailability {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        )
        guard status == noErr, let session else {
            return .unavailable(
                reason: .appleAPIUnsupported(
                    details: "VTPixelTransferSessionCreate returned OSStatus \(status)"
                )
            )
        }
        VTPixelTransferSessionInvalidate(session)
        return .available
    }

    private func integerDimensions(_ size: CGSize) -> IntegerDimensions? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        let roundedWidth = size.width.rounded()
        let roundedHeight = size.height.rounded()
        guard abs(size.width - roundedWidth) <= 0.001,
              abs(size.height - roundedHeight) <= 0.001,
              let width = Int(exactly: roundedWidth),
              let height = Int(exactly: roundedHeight),
              width > 0,
              height > 0 else {
            return nil
        }
        return IntegerDimensions(width: width, height: height)
    }

    private func uniformScale(
        source: IntegerDimensions,
        target: IntegerDimensions
    ) -> Double? {
        let horizontal = Double(target.width) / Double(source.width)
        let vertical = Double(target.height) / Double(source.height)
        guard horizontal.isFinite,
              vertical.isFinite,
              horizontal > 1,
              abs(horizontal - vertical) <= 0.000_001 else {
            return nil
        }
        return horizontal
    }

    private func integerUniformScale(
        source: IntegerDimensions,
        target: IntegerDimensions
    ) -> Int? {
        guard let scale = uniformScale(source: source, target: target) else {
            return nil
        }
        let rounded = scale.rounded()
        guard abs(scale - rounded) <= 0.000_001,
              let integer = Int(exactly: rounded) else {
            return nil
        }
        return integer
    }

    private func destinationDimensions(
        from attributes: [String: Any]
    ) -> IntegerDimensions? {
        guard let width = integerAttribute(
            attributes[kCVPixelBufferWidthKey as String]
        ),
        let height = integerAttribute(
            attributes[kCVPixelBufferHeightKey as String]
        ) else {
            return nil
        }
        return IntegerDimensions(width: width, height: height)
    }

    private func integerAttribute(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            return value.intValue
        }
        return value as? Int
    }
}

private struct IntegerDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}
