import Foundation

#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(CoreAI)
import CoreAI
#endif
#if canImport(CoreImage)
import CoreImage
#if canImport(CoreImage.CIFilterBuiltins)
import CoreImage.CIFilterBuiltins
#endif
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalFX)
import MetalFX
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(VideoToolbox)
import VideoToolbox
#endif

/// Queries only framework and device support. It never creates a processing
/// session, reads a fixture, writes a report, or acquires a model. A positive
/// support result is diagnostic evidence, not a runnable result or product
/// qualification.
struct R01CurrentHostSupportProbe: R01CapabilityProbing {
    func probe(
        _ definition: R01CapabilityDefinition,
        request _: R01LiveProbeRequest
    ) async throws -> R01CapabilityProbeObservation {
        let compileState = compileState(for: definition)
        guard compileState != .unavailable else {
            return .init(
                id: definition.id,
                compileState: .unavailable,
                runtimeDisposition: .unavailable,
                reasonCode: compileUnavailabilityReason(for: definition),
                limitations: ["The capability API is absent from this build toolchain."]
            )
        }

        switch support(for: definition.id) {
        case .supported:
            return .init(
                id: definition.id,
                compileState: compileState,
                runtimeDisposition: .diagnosticOnly,
                reasonCode: .inputContractUnsatisfied,
                limitations: [
                    "A side-effect-free support query passed; fixture execution and class measurements were not performed."
                ]
            )
        case .unsupported(let reason):
            return .init(
                id: definition.id,
                compileState: compileState,
                runtimeDisposition: .unsupported,
                reasonCode: reason,
                limitations: ["The current host support query returned unavailable."]
            )
        }
    }

    private func compileState(for definition: R01CapabilityDefinition) -> R01CompileState {
        switch definition.id {
        case .a01, .a02, .a03, .a04:
            // Xcode 26 introduces these declarations. Xcode 16-era SDK builds
            // discard this branch before symbol lookup, preserving the 15.4 anchor.
            #if compiler(>=6.2) && canImport(VideoToolbox)
            return .available
            #else
            return .unavailable
            #endif
        case .a05, .a06:
            #if canImport(VideoToolbox)
            return .available
            #else
            return .unavailable
            #endif
        case .a07, .a08:
            #if canImport(MetalFX)
            return .available
            #else
            return .unavailable
            #endif
        case .a09, .a10:
            #if compiler(>=6.2) && canImport(MetalFX)
            return .available
            #else
            return .unavailable
            #endif
        case .a11, .a12, .a13:
            #if canImport(MetalPerformanceShaders)
            return .available
            #else
            return .unavailable
            #endif
        case .a14, .a15:
            #if canImport(CoreImage)
            return .available
            #else
            return .unavailable
            #endif
        case .a16:
            #if canImport(Accelerate)
            return .available
            #else
            return .unavailable
            #endif
        case .a17:
            #if canImport(Metal)
            return .available
            #else
            return .unavailable
            #endif
        case .a18:
            #if canImport(CoreAI)
            return .conditional
            #else
            return .unavailable
            #endif
        }
    }

    private func compileUnavailabilityReason(
        for definition: R01CapabilityDefinition
    ) -> R01ReasonCode {
        switch definition.id {
        case .a01, .a02, .a03, .a04, .a09, .a10:
            return .sdkTooOld
        default:
            return .apiAbsent
        }
    }

    private enum SupportResult {
        case supported
        case unsupported(R01ReasonCode)
    }

    private func support(for id: R01CapabilityID) -> SupportResult {
        switch id {
        case .a01, .a02, .a03, .a04, .a05, .a06:
            return videoToolboxSupport(for: id)
        case .a07, .a08, .a09, .a10:
            return metalFXSupport(for: id)
        case .a11, .a12, .a13:
            return metalPerformanceShadersSupport(for: id)
        case .a14, .a15:
            return coreImageSupport(for: id)
        case .a16:
            return accelerateSupport()
        case .a17:
            return metalSupport()
        case .a18:
            return coreAISupport()
        }
    }

    private func videoToolboxSupport(for id: R01CapabilityID) -> SupportResult {
        #if canImport(VideoToolbox)
        switch id {
        case .a01:
            #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { return .unsupported(.osTooOld) }
            _ = VTSuperResolutionScalerConfiguration.self
            return VTSuperResolutionScalerConfiguration.isSupported
                ? .supported : .unsupported(.hardwareUnsupported)
            #else
            return .unsupported(.sdkTooOld)
            #endif
        case .a02:
            #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { return .unsupported(.osTooOld) }
            _ = VTLowLatencySuperResolutionScalerConfiguration.self
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
                ? .supported : .unsupported(.hardwareUnsupported)
            #else
            return .unsupported(.sdkTooOld)
            #endif
        case .a03:
            #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { return .unsupported(.osTooOld) }
            _ = VTLowLatencyFrameInterpolationConfiguration.self
            return VTLowLatencyFrameInterpolationConfiguration.isSupported
                ? .supported : .unsupported(.hardwareUnsupported)
            #else
            return .unsupported(.sdkTooOld)
            #endif
        case .a04:
            #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { return .unsupported(.osTooOld) }
            _ = VTTemporalNoiseFilterConfiguration.self
            return VTTemporalNoiseFilterConfiguration.isSupported
                ? .supported : .unsupported(.hardwareUnsupported)
            #else
            return .unsupported(.sdkTooOld)
            #endif
        case .a05:
            guard #available(macOS 15.4, *) else { return .unsupported(.osTooOld) }
            _ = VTOpticalFlowConfiguration.self
            return VTOpticalFlowConfiguration.isSupported
                ? .supported : .unsupported(.hardwareUnsupported)
        case .a06:
            _ = VTPixelTransferSessionCreate
            return .supported
        default:
            return .unsupported(.notApplicable)
        }
        #else
        return .unsupported(.apiAbsent)
        #endif
    }

    private func metalFXSupport(for id: R01CapabilityID) -> SupportResult {
        #if canImport(MetalFX) && canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .unsupported(.hardwareUnsupported)
        }
        switch id {
        case .a07:
            _ = MTLFXSpatialScalerDescriptor.self
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
                ? .supported : .unsupported(.hardwareUnsupported)
        case .a08:
            _ = MTLFXTemporalScalerDescriptor.self
            return MTLFXTemporalScalerDescriptor.supportsDevice(device)
                ? .supported : .unsupported(.hardwareUnsupported)
        case .a09:
            #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { return .unsupported(.osTooOld) }
            _ = MTLFXTemporalDenoisedScalerDescriptor.self
            return MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
                ? .supported : .unsupported(.hardwareUnsupported)
            #else
            return .unsupported(.sdkTooOld)
            #endif
        case .a10:
            #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { return .unsupported(.osTooOld) }
            _ = MTLFXFrameInterpolatorDescriptor.self
            return MTLFXFrameInterpolatorDescriptor.supportsDevice(device)
                ? .supported : .unsupported(.hardwareUnsupported)
            #else
            return .unsupported(.sdkTooOld)
            #endif
        default:
            return .unsupported(.notApplicable)
        }
        #else
        return .unsupported(.apiAbsent)
        #endif
    }

    private func metalPerformanceShadersSupport(for id: R01CapabilityID) -> SupportResult {
        #if canImport(MetalPerformanceShaders) && canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else {
            return .unsupported(.hardwareUnsupported)
        }
        switch id {
        case .a11:
            _ = MPSImageLanczosScale.self
        case .a12:
            _ = MPSImageBilinearScale.self
        case .a13:
            _ = MPSImageGuidedFilter.self
            _ = MPSImageLaplacian.self
            _ = MPSImageSobel.self
        default:
            return .unsupported(.notApplicable)
        }
        return .supported
        #else
        return .unsupported(.apiAbsent)
        #endif
    }

    private func coreImageSupport(for id: R01CapabilityID) -> SupportResult {
        #if canImport(CoreImage)
        switch id {
        case .a14:
            _ = CIFilter.lanczosScaleTransform()
            _ = CIFilter.bicubicScaleTransform()
        case .a15:
            _ = CIFilter.edgePreserveUpsample()
        default:
            return .unsupported(.notApplicable)
        }
        return .supported
        #else
        return .unsupported(.apiAbsent)
        #endif
    }

    private func accelerateSupport() -> SupportResult {
        #if canImport(Accelerate)
        _ = vImageScale_ARGB8888
        _ = vImageNewResamplingFilter
        return .supported
        #else
        return .unsupported(.apiAbsent)
        #endif
    }

    private func metalSupport() -> SupportResult {
        #if canImport(Metal)
        _ = MTLComputePipelineDescriptor.self
        return MTLCreateSystemDefaultDevice() == nil
            ? .unsupported(.hardwareUnsupported) : .supported
        #else
        return .unsupported(.apiAbsent)
        #endif
    }

    private func coreAISupport() -> SupportResult {
        #if canImport(CoreAI)
        return .supported
        #else
        return .unsupported(.apiAbsent)
        #endif
    }
}
