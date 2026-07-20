import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Metal
import MetalFX
import VideoToolbox

// R01 keeps the native registry and its availability-gated framework adapters
// in one source file so the published implementation binding is auditable.
// swiftlint:disable file_length

struct R01NativeAdapterRegistry {
    func descriptor(
        for definition: R01CapabilityDefinition,
        compileObservation: R01CompileProbeObservation,
        context: R01LiveProbeContext
    ) -> R01RuntimeAdapterDescriptor {
        let metadata = R01CapabilityMetadata.metadata(for: definition.id)
        if definition.id == .a18 {
            return coreAIDescriptor(metadata: metadata, context: context)
        }
        if compileObservation.state == .unavailable {
            return unavailableDescriptor(
                metadata: metadata,
                reason: compileObservation.reason ?? .apiAbsent,
                limitation: "The isolated Swift compiler unit did not typecheck this capability."
            )
        }
        if definition.id == .a06 {
            return .init(
                publicAPIStatus: .public,
                hardwareEligibility: .eligible,
                platformRequirements: metadata.requirements,
                supportQuery: .init(
                    apiOrEquivalentName: metadata.supportName,
                    observed: .supported,
                    reasonCode: nil
                ),
                stateHistory: metadata.stateHistory,
                modelReadiness: .notRequired,
                offlineSuitability: .suitable,
                limitations: [
                    "R01 measures capability and repeatability only, not perceptual quality or product eligibility.",
                    "The exact two primary_scaler_observations execute in every unit."
                ],
                unavailableDisposition: nil,
                unavailableReason: nil,
                sessionFactory: { try R01PixelTransferRuntimeSession(context: context) }
            )
        }
        if definition.id == .a05 {
            return opticalFlowDescriptor(metadata: metadata, context: context)
        }
        if definition.id == .a07 || definition.id == .a08 {
            return metalFXDescriptor(id: definition.id, metadata: metadata)
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            switch definition.id {
            case .a01, .a02, .a03, .a04:
                return videoToolbox26Descriptor(
                    id: definition.id,
                    metadata: metadata,
                    context: context
                )
            case .a09, .a10:
                return metalFX26Descriptor(id: definition.id, metadata: metadata)
            default:
                break
            }
        }
#endif
        if let legacy = R01LegacyCapabilityRuntimeFactory.resolve(
            id: definition.id,
            context: context
        ) {
            switch legacy {
            case .runnable(let factory):
                return .init(
                    publicAPIStatus: .public,
                    hardwareEligibility: .eligible,
                    platformRequirements: metadata.requirements,
                    supportQuery: .init(
                        apiOrEquivalentName: metadata.supportName,
                        observed: .supported,
                        reasonCode: nil
                    ),
                    stateHistory: metadata.stateHistory,
                    modelReadiness: .notRequired,
                    offlineSuitability: .suitable,
                    limitations: [
                        "Every grouped submethod and frozen fixture executes once per measured unit."
                    ],
                    unavailableDisposition: nil,
                    unavailableReason: nil,
                    sessionFactory: factory
                )
            case .incompatible(_, let limitation):
                return contractRestricted(
                    metadata: metadata,
                    supported: true,
                    limitation: limitation
                )
            }
        }
        return unavailableDescriptor(
            metadata: metadata,
            reason: .inputContractUnsatisfied,
            limitation: limitation(for: definition.id)
        )
    }
}

private extension R01NativeAdapterRegistry {
    func contractRestricted(
        metadata: R01CapabilityMetadata,
        supported: Bool,
        limitation: String
    ) -> R01RuntimeAdapterDescriptor {
        guard supported else {
            return .unavailable(
                publicAPIStatus: .public,
                hardwareEligibility: .ineligible,
                platformRequirements: metadata.requirements,
                supportQuery: .init(
                    apiOrEquivalentName: metadata.supportName,
                    observed: .unsupported,
                    reasonCode: .hardwareUnsupported
                ),
                stateHistory: metadata.stateHistory,
                modelReadiness: .notRequired,
                offlineSuitability: .unavailable,
                disposition: .unsupported,
                reason: .hardwareUnsupported,
                limitations: ["The public support query rejected this hardware configuration."]
            )
        }
        return .unavailable(
            publicAPIStatus: .public,
            hardwareEligibility: .eligible,
            platformRequirements: metadata.requirements,
            supportQuery: .init(
                apiOrEquivalentName: metadata.supportName,
                observed: .supported,
                reasonCode: nil
            ),
            stateHistory: metadata.stateHistory,
            modelReadiness: .notRequired,
            offlineSuitability: .suitable,
            disposition: .restricted,
            reason: .inputContractUnsatisfied,
            limitations: [limitation]
        )
    }

    func unavailableDescriptor(
        metadata: R01CapabilityMetadata,
        reason: R01ReasonCode,
        limitation: String
    ) -> R01RuntimeAdapterDescriptor {
        .unavailable(
            publicAPIStatus: reason == .apiAbsent ? .absent : .public,
            hardwareEligibility: .unknown,
            platformRequirements: metadata.requirements,
            supportQuery: .init(
                apiOrEquivalentName: metadata.supportName,
                observed: .notAvailable,
                reasonCode: reason
            ),
            stateHistory: metadata.stateHistory,
            modelReadiness: .notRequired,
            offlineSuitability: .unavailable,
            disposition: reason == .apiAbsent || reason == .sdkTooOld ? .unavailable : .restricted,
            reason: reason,
            limitations: [limitation]
        )
    }

    func coreAIDescriptor(
        metadata: R01CapabilityMetadata,
        context: R01LiveProbeContext
    ) -> R01RuntimeAdapterDescriptor {
        guard context.modelIsPresent else {
            return .unavailable(
                publicAPIStatus: .public,
                hardwareEligibility: .unknown,
                platformRequirements: metadata.requirements,
                supportQuery: .init(
                    apiOrEquivalentName: metadata.supportName,
                    observed: .supported,
                    reasonCode: nil
                ),
                stateHistory: .unavailable,
                modelReadiness: .unavailable,
                offlineSuitability: .requiresAcquisition,
                disposition: .unavailable,
                reason: .modelUnavailable,
                limitations: [
                    "The frozen Core AI model identity and hash exist, but matching ignored local model bytes are absent.",
                    "No acquisition was attempted."
                ]
            )
        }
        return .unavailable(
            publicAPIStatus: .public,
            hardwareEligibility: .unknown,
            platformRequirements: metadata.requirements,
            supportQuery: .init(
                apiOrEquivalentName: metadata.supportName,
                observed: .supported,
                reasonCode: nil
            ),
            stateHistory: .unavailable,
            modelReadiness: .ready,
            offlineSuitability: .suitable,
            disposition: .restricted,
            reason: .inputContractUnsatisfied,
            limitations: [
                "The current implementation has no compile-verified Core AI execution contract; model bytes were not opened."
            ]
        )
    }

    func opticalFlowDescriptor(
        metadata: R01CapabilityMetadata,
        context: R01LiveProbeContext
    ) -> R01RuntimeAdapterDescriptor {
        guard #available(macOS 15.4, *) else {
            return contractRestricted(
                metadata: metadata,
                supported: false,
                limitation: "The current OS predates the public optical-flow contract."
            )
        }
        guard VTOpticalFlowConfiguration.isSupported else {
            return contractRestricted(
                metadata: metadata,
                supported: false,
                limitation: "The public optical-flow support query rejected this host."
            )
        }
        return .init(
            publicAPIStatus: .public,
            hardwareEligibility: .eligible,
            platformRequirements: metadata.requirements,
            supportQuery: .init(
                apiOrEquivalentName: metadata.supportName,
                observed: .supported,
                reasonCode: nil
            ),
            stateHistory: metadata.stateHistory,
            modelReadiness: .notRequired,
            offlineSuitability: .suitable,
            limitations: [
                "R01 measures forward and backward flow output; the public API exposes no confidence plane."
            ],
            unavailableDisposition: nil,
            unavailableReason: nil,
            sessionFactory: { try R01OpticalFlowRuntimeSession(context: context) }
        )
    }

    func metalFXDescriptor(
        id: R01CapabilityID,
        metadata: R01CapabilityMetadata
    ) -> R01RuntimeAdapterDescriptor {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return contractRestricted(
                metadata: metadata,
                supported: false,
                limitation: "No public Metal device is available."
            )
        }
        let supported = id == .a07
            ? MTLFXSpatialScalerDescriptor.supportsDevice(device)
            : MTLFXTemporalScalerDescriptor.supportsDevice(device)
        let limitation = id == .a07
            ? "MetalFX spatial scaling requires RGB Metal textures; the frozen primary input is 8-bit NV12."
            : "MetalFX temporal scaling requires motion and depth inputs absent from the frozen primary-scaler contract."
        return contractRestricted(metadata: metadata, supported: supported, limitation: limitation)
    }

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    func videoToolbox26Descriptor(
        id: R01CapabilityID,
        metadata: R01CapabilityMetadata,
        context: R01LiveProbeContext
    ) -> R01RuntimeAdapterDescriptor {
        switch id {
        case .a01:
            return contractRestricted(
                metadata: metadata,
                supported: VTSuperResolutionScalerConfiguration.isSupported,
                limitation: "VTSuperResolutionScalerConfiguration accepts an integer scale factor and cannot represent the frozen 1.5x observation."
            )
        case .a02:
            guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
                return contractRestricted(
                    metadata: metadata,
                    supported: false,
                    limitation: "The public low-latency scaler support query rejected this host."
                )
            }
            let first = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: 1280,
                frameHeight: 720
            ).map(Double.init)
            let second = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: 1920,
                frameHeight: 1080
            ).map(Double.init)
            guard first.contains(1.5), second.contains(2.0) else {
                return contractRestricted(
                    metadata: metadata,
                    supported: true,
                    limitation: "The public dimension-specific scale query does not contain both frozen 1.5x and 2.0x observations."
                )
            }
            return .init(
                publicAPIStatus: .public,
                hardwareEligibility: .eligible,
                platformRequirements: metadata.requirements,
                supportQuery: .init(
                    apiOrEquivalentName: metadata.supportName,
                    observed: .supported,
                    reasonCode: nil
                ),
                stateHistory: metadata.stateHistory,
                modelReadiness: .notRequired,
                offlineSuitability: .suitable,
                limitations: [
                    "Both frozen scaler fixtures execute once per measured unit in separate public frame-processor sessions."
                ],
                unavailableDisposition: nil,
                unavailableReason: nil,
                sessionFactory: { try R01LowLatencyScalerRuntimeSession(context: context) }
            )
        case .a03:
            return contractRestricted(
                metadata: metadata,
                supported: VTLowLatencyFrameInterpolationConfiguration.isSupported,
                limitation: "The public spatial interpolation mode produces 2x frames, while the frozen cadence-transform output remains 1920x1080."
            )
        case .a04:
            guard VTTemporalNoiseFilterConfiguration.isSupported else {
                return contractRestricted(
                    metadata: metadata,
                    supported: false,
                    limitation: "The public temporal noise-filter support query rejected this host."
                )
            }
            return .init(
                publicAPIStatus: .public,
                hardwareEligibility: .eligible,
                platformRequirements: metadata.requirements,
                supportQuery: .init(
                    apiOrEquivalentName: metadata.supportName,
                    observed: .supported,
                    reasonCode: nil
                ),
                stateHistory: metadata.stateHistory,
                modelReadiness: .notRequired,
                offlineSuitability: .suitable,
                limitations: [
                    "The frozen support frame and history frame execute once per measured unit; this API requires no guidance plane."
                ],
                unavailableDisposition: nil,
                unavailableReason: nil,
                sessionFactory: { try R01TemporalNoiseFilterRuntimeSession(context: context) }
            )
        default:
            return unavailableDescriptor(
                metadata: metadata,
                reason: .notApplicable,
                limitation: "This capability is not a VideoToolbox 26 scaler/filter."
            )
        }
    }

    @available(macOS 26.0, *)
    func metalFX26Descriptor(
        id: R01CapabilityID,
        metadata: R01CapabilityMetadata
    ) -> R01RuntimeAdapterDescriptor {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return contractRestricted(
                metadata: metadata,
                supported: false,
                limitation: "No public Metal device is available."
            )
        }
        let supported = id == .a09
            ? MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
            : MTLFXFrameInterpolatorDescriptor.supportsDevice(device)
        let limitation = id == .a09
            ? "The public temporal-denoised scaler requires temporal Metal inputs absent from the frozen NV12 primary contract."
            : "The public frame interpolator requires Metal motion inputs absent from the frozen cadence contract."
        return contractRestricted(metadata: metadata, supported: supported, limitation: limitation)
    }
#endif

    func limitation(for id: R01CapabilityID) -> String {
        switch id {
        case .a01:
            return "The public configuration accepts an integer scale factor and cannot exercise the frozen 1.5x and 2.0x pair."
        case .a03:
            return "The public spatial interpolation contract produces 2x output, which conflicts with the frozen same-size cadence output contract."
        case .a07:
            return "The public MetalFX spatial scaler requires an RGB Metal texture, which conflicts with the frozen NV12 primary contract."
        case .a08:
            return "The public MetalFX temporal scaler requires motion and depth inputs absent from the frozen temporal contract."
        case .a09:
            return "The public temporal-denoised scaler requires temporal Metal inputs absent from the frozen NV12 primary contract."
        case .a10:
            return "The public frame interpolator requires Metal motion inputs absent from the frozen cadence contract."
        case .a15:
            return "The public edge-preserve filter requires a smaller guidance image, which conflicts with the frozen equal-sized guidance contract."
        case .a02, .a04, .a05, .a06, .a11, .a12, .a13, .a14, .a16, .a17:
            return "The registered runtime constructor could not be entered across its required compiler and OS availability boundary."
        case .a18:
            return "Core AI is handled by the model-specific fail-closed path."
        }
    }
}

private struct R01CapabilityMetadata {
    let supportName: String
    let requirements: R01PlatformRequirements
    let stateHistory: R01StateHistory

    // The switch is exhaustive over the frozen A01-A18 catalog.
    // swiftlint:disable:next cyclomatic_complexity
    static func metadata(for id: R01CapabilityID) -> R01CapabilityMetadata {
        let values: R01CapabilityMetadataValues
        switch id {
        case .a01:
            values = .init("VTSuperResolutionScalerConfiguration.isSupported", "26.0", .stateful)
        case .a02:
            values = .init("VTLowLatencySuperResolutionScalerConfiguration.isSupported", "26.0", .stateless)
        case .a03:
            values = .init("VTLowLatencyFrameInterpolationConfiguration.isSupported", "26.0", .requiresHistory)
        case .a04:
            values = .init("VTTemporalNoiseFilterConfiguration.isSupported", "26.0", .requiresHistory)
        case .a05:
            values = .init("VTOpticalFlowConfiguration.isSupported", "15.4", .requiresHistory)
        case .a06:
            values = .init("VTPixelTransferSessionCreate", "10.8", .stateless)
        case .a07:
            values = .init("MTLFXSpatialScalerDescriptor.supportsDevice", "13.0", .stateless)
        case .a08:
            values = .init("MTLFXTemporalScalerDescriptor.supportsDevice", "13.0", .requiresHistory)
        case .a09:
            values = .init("MTLFXTemporalDenoisedScalerDescriptor.supportsDevice", "26.0", .requiresHistory)
        case .a10:
            values = .init("MTLFXFrameInterpolatorDescriptor.supportsDevice", "26.0", .requiresHistory)
        case .a11:
            values = .init("MPSImageLanczosScale", "10.13", .stateless)
        case .a12:
            values = .init("MPSImageBilinearScale", "10.13", .stateless)
        case .a13:
            values = .init("MPSImageGuidedFilter and support kernels", "10.13.4", .requiresHistory)
        case .a14:
            values = .init("CILanczosScaleTransform and CIBicubicScaleTransform", "10.4", .stateless)
        case .a15:
            values = .init("CIEdgePreserveUpsample", "10.10", .stateless)
        case .a16:
            values = .init("vImageNewResamplingFilter", "10.3", .stateless)
        case .a17:
            values = .init("MTLComputePipelineDescriptor", "10.11", .stateless)
        case .a18:
            values = .init("CoreAI module and frozen model", "27.0", .unavailable)
        }
        return .init(
            supportName: values.supportName,
            requirements: .init(
                minimumOSVersion: values.minimumVersion,
                minimumSDKVersion: values.minimumVersion,
                unavailableReason: nil
            ),
            stateHistory: values.stateHistory
        )
    }
}

private struct R01CapabilityMetadataValues {
    let supportName: String
    let minimumVersion: String
    let stateHistory: R01StateHistory

    init(_ supportName: String, _ minimumVersion: String, _ stateHistory: R01StateHistory) {
        self.supportName = supportName
        self.minimumVersion = minimumVersion
        self.stateHistory = stateHistory
    }
}

enum R01NV12PixelBufferFactory {
    static func make(dimensions: R01Dimensions) throws -> CVPixelBuffer {
        try make(dimensions: dimensions, requiredAttributes: [:])
    }

    static func make(
        dimensions: R01Dimensions,
        requiredAttributes: [String: Any]
    ) throws -> CVPixelBuffer {
        var attributes = requiredAttributes
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            dimensions.width,
            dimensions.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw R01ExecutionFailure.resource
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        return buffer
    }
}

private final class R01PixelTransferRuntimeSession: R01CapabilityRuntimeSession {
    private let transferSession: VTPixelTransferSession
    private let pairs: [(source: CVPixelBuffer, destination: CVPixelBuffer)]

    init(context: R01LiveProbeContext) throws {
        let first = try Self.makePair(context: context, fixtureID: "scaler-720p")
        let second = try Self.makePair(context: context, fixtureID: "scaler-1080p")
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        ) == noErr,
              let session else {
            throw R01ExecutionFailure.setup
        }
        transferSession = session
        pairs = [first, second]
    }

    deinit {
        VTPixelTransferSessionInvalidate(transferSession)
    }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        let clock = ContinuousClock()
        guard clock.now < deadline else { throw R01ExecutionFailure.timeout }
        var hashes: [String] = []
        for pair in pairs {
            let status = VTPixelTransferSessionTransferImage(
                transferSession,
                from: pair.source,
                to: pair.destination
            )
            guard status == noErr else { throw R01ExecutionFailure.processing }
            hashes.append(try Self.activePlaneHash(pair.destination))
            guard clock.now < deadline else { throw R01ExecutionFailure.timeout }
        }
        return .init(
            outputSHA256: R01SHA256.hexDigest(Data(hashes.joined(separator: "\n").utf8)),
            classMetrics: [:],
            primaryScalerObservations: R01PrimaryScalerObservation.frozen
        )
    }
}

private extension R01PixelTransferRuntimeSession {
    static func makePair(
        context: R01LiveProbeContext,
        fixtureID: String
    ) throws -> (source: CVPixelBuffer, destination: CVPixelBuffer) {
        guard let payload = context.fixtures[fixtureID],
              let input = payload.record.dimensions,
              let output = payload.record.scaleOutput else {
            throw R01ExecutionFailure.setup
        }
        let source = try R01NV12PixelBufferFactory.make(dimensions: input)
        let destination = try R01NV12PixelBufferFactory.make(dimensions: output)
        try copyNV12(payload.data, dimensions: input, to: source)
        return (source, destination)
    }

    static func copyNV12(
        _ data: Data,
        dimensions: R01Dimensions,
        to buffer: CVPixelBuffer
    ) throws {
        let lumaCount = dimensions.width * dimensions.height
        guard data.count == lumaCount + lumaCount / 2,
              CVPixelBufferGetPlaneCount(buffer) == 2 else {
            throw R01ExecutionFailure.setup
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        try data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress,
                  let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
                throw R01ExecutionFailure.resource
            }
            for row in 0..<dimensions.height {
                memcpy(
                    luma.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
                    source.advanced(by: row * dimensions.width),
                    dimensions.width
                )
            }
            for row in 0..<(dimensions.height / 2) {
                memcpy(
                    chroma.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)),
                    source.advanced(by: lumaCount + row * dimensions.width),
                    dimensions.width
                )
            }
        }
    }

    static func activePlaneHash(_ buffer: CVPixelBuffer) throws -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var data = Data()
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        if planeCount == 0 {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw R01ExecutionFailure.resource
            }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<CVPixelBufferGetHeight(buffer) {
                data.append(
                    base.assumingMemoryBound(to: UInt8.self).advanced(by: row * stride),
                    count: stride
                )
            }
        }
        for plane in 0..<planeCount {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
                throw R01ExecutionFailure.resource
            }
            let activeBytes = CVPixelBufferGetWidthOfPlane(buffer, plane)
                * (plane == 0 ? 1 : 2)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<height {
                data.append(base.assumingMemoryBound(to: UInt8.self).advanced(by: row * stride), count: activeBytes)
            }
        }
        return R01SHA256.hexDigest(data)
    }
}

private final class R01VTProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private let semaphore = DispatchSemaphore(value: 0)

    func complete(error: Error?) {
        lock.lock()
        storedError = error
        lock.unlock()
        semaphore.signal()
    }

    func wait(deadline: ContinuousClock.Instant) throws {
        let clock = ContinuousClock()
        while semaphore.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
            guard clock.now < deadline else { throw R01ExecutionFailure.timeout }
        }
        lock.lock()
        let error = storedError
        lock.unlock()
        guard error == nil else { throw R01ExecutionFailure.processing }
    }
}

private enum R01VTFrameProcessing {
    static func process(
        _ processor: VTFrameProcessor,
        parameters: any VTFrameProcessorParameters,
        deadline: ContinuousClock.Instant
    ) throws {
        let completion = R01VTProcessCompletion()
        processor.process(parameters: parameters) { _, error in
            completion.complete(error: error)
        }
        try completion.wait(deadline: deadline)
    }

    static func frame(
        buffer: CVPixelBuffer,
        time: CMTime
    ) throws -> VTFrameProcessorFrame {
        guard let frame = VTFrameProcessorFrame(
            buffer: buffer,
            presentationTimeStamp: time
        ) else {
            throw R01ExecutionFailure.setup
        }
        return frame
    }

    static func destinationBuffer(attributes: [String: Any]) throws -> CVPixelBuffer {
        var closedAttributes = attributes
        closedAttributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        closedAttributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            closedAttributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else {
            throw R01ExecutionFailure.setup
        }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            throw R01ExecutionFailure.resource
        }
        return buffer
    }

    static func pixelFormatName(_ buffer: CVPixelBuffer) -> String {
        let value = CVPixelBufferGetPixelFormatType(buffer)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ (32...126).contains($0) }) {
            return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
        }
        return String(format: "0x%08x", value)
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private final class R01LowLatencyScalerRuntimeSession: R01CapabilityRuntimeSession {
    private struct Pair {
        let processor: VTFrameProcessor
        let parameters: VTLowLatencySuperResolutionScalerParameters
        let destination: CVPixelBuffer
    }

    private let pairs: [Pair]

    init(context: R01LiveProbeContext) throws {
        pairs = try [
            Self.makePair(
                context: context,
                fixtureID: "scaler-720p",
                scale: 1.5,
                timestamp: CMTime(value: 0, timescale: 600)
            ),
            Self.makePair(
                context: context,
                fixtureID: "scaler-1080p",
                scale: 2.0,
                timestamp: CMTime(value: 20, timescale: 600)
            )
        ]
    }

    deinit {
        for pair in pairs { pair.processor.endSession() }
    }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        var hashes: [String] = []
        for pair in pairs {
            try R01VTFrameProcessing.process(
                pair.processor,
                parameters: pair.parameters,
                deadline: deadline
            )
            hashes.append(try R01PixelTransferRuntimeSession.activePlaneHash(pair.destination))
        }
        return .init(
            outputSHA256: R01SHA256.hexDigest(Data(hashes.joined(separator: "\n").utf8)),
            classMetrics: [:],
            primaryScalerObservations: R01PrimaryScalerObservation.frozen
        )
    }

    private static func makePair(
        context: R01LiveProbeContext,
        fixtureID: String,
        scale: Float,
        timestamp: CMTime
    ) throws -> Pair {
        guard let payload = context.fixtures[fixtureID],
              let input = payload.record.dimensions,
              let output = payload.record.scaleOutput else {
            throw R01ExecutionFailure.setup
        }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: input.width,
            frameHeight: input.height,
            scaleFactor: scale
        )
        guard configuration.__frameSupportedPixelFormats.contains(
            NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ) else {
            throw R01ExecutionFailure.setup
        }
        let source = try R01NV12PixelBufferFactory.make(
            dimensions: input,
            requiredAttributes: configuration.sourcePixelBufferAttributes
        )
        let destination = try R01NV12PixelBufferFactory.make(
            dimensions: output,
            requiredAttributes: configuration.destinationPixelBufferAttributes
        )
        try R01PixelTransferRuntimeSession.copyNV12(payload.data, dimensions: input, to: source)
        let sourceFrame = try R01VTFrameProcessing.frame(buffer: source, time: timestamp)
        let destinationFrame = try R01VTFrameProcessing.frame(
            buffer: destination,
            time: timestamp
        )
        let parameters = VTLowLatencySuperResolutionScalerParameters(
            sourceFrame: sourceFrame,
            destinationFrame: destinationFrame
        )
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw R01ExecutionFailure.setup
        }
        return .init(
            processor: processor,
            parameters: parameters,
            destination: destination
        )
    }
}

@available(macOS 26.0, *)
private final class R01TemporalNoiseFilterRuntimeSession: R01CapabilityRuntimeSession {
    private let processor: VTFrameProcessor
    private let parameters: VTTemporalNoiseFilterParameters
    private let destination: CVPixelBuffer

    init(context: R01LiveProbeContext) throws {
        guard let sourcePayload = context.fixtures["support-frame"],
              let historyPayload = context.fixtures["support-history"],
              let dimensions = sourcePayload.record.dimensions,
              historyPayload.record.dimensions == dimensions,
              let configuration = VTTemporalNoiseFilterConfiguration(
                  frameWidth: dimensions.width,
                  frameHeight: dimensions.height,
                  sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
              ),
              configuration.__frameSupportedPixelFormats.contains(
                  NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
              ) else {
            throw R01ExecutionFailure.setup
        }
        let source = try R01NV12PixelBufferFactory.make(
            dimensions: dimensions,
            requiredAttributes: configuration.sourcePixelBufferAttributes
        )
        let history = try R01NV12PixelBufferFactory.make(
            dimensions: dimensions,
            requiredAttributes: configuration.sourcePixelBufferAttributes
        )
        destination = try R01NV12PixelBufferFactory.make(
            dimensions: dimensions,
            requiredAttributes: configuration.destinationPixelBufferAttributes
        )
        try R01PixelTransferRuntimeSession.copyNV12(
            sourcePayload.data,
            dimensions: dimensions,
            to: source
        )
        try R01PixelTransferRuntimeSession.copyNV12(
            historyPayload.data,
            dimensions: dimensions,
            to: history
        )
        let sourceFrame = try R01VTFrameProcessing.frame(
            buffer: source,
            time: CMTime(value: 20, timescale: 600)
        )
        let historyFrame = try R01VTFrameProcessing.frame(
            buffer: history,
            time: CMTime(value: 0, timescale: 600)
        )
        let destinationFrame = try R01VTFrameProcessing.frame(
            buffer: destination,
            time: CMTime(value: 20, timescale: 600)
        )
        guard let parameters = VTTemporalNoiseFilterParameters(
            sourceFrame: sourceFrame,
            nextFrames: [],
            previousFrames: [historyFrame],
            destinationFrame: destinationFrame,
            filterStrength: 0.5,
            hasDiscontinuity: true
        ) else {
            throw R01ExecutionFailure.setup
        }
        self.parameters = parameters
        processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw R01ExecutionFailure.setup
        }
    }

    deinit { processor.endSession() }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        try R01VTFrameProcessing.process(
            processor,
            parameters: parameters,
            deadline: deadline
        )
        return .init(
            outputSHA256: try R01PixelTransferRuntimeSession.activePlaneHash(destination),
            classMetrics: [
                .preservedDimensions: .string(
                    "\(CVPixelBufferGetWidth(destination))x\(CVPixelBufferGetHeight(destination))"
                ),
                .preservedFormat: .string("420v"),
                .requiredGuidance: .boolean(false)
            ]
        )
    }
}
#endif

@available(macOS 15.4, *)
private final class R01OpticalFlowRuntimeSession: R01CapabilityRuntimeSession {
    private let processor: VTFrameProcessor
    private let parameters: VTOpticalFlowParameters
    private let forwardFlow: CVPixelBuffer
    private let backwardFlow: CVPixelBuffer

    init(context: R01LiveProbeContext) throws {
        guard let firstPayload = context.fixtures["temporal-frame-0"],
              let secondPayload = context.fixtures["temporal-frame-1"],
              let dimensions = firstPayload.record.dimensions,
              secondPayload.record.dimensions == dimensions else {
            throw R01ExecutionFailure.setup
        }
        guard let configuration = VTOpticalFlowConfiguration(
            frameWidth: dimensions.width,
            frameHeight: dimensions.height,
            qualityPrioritization: .normal,
            revision: VTOpticalFlowConfiguration.defaultRevision
        ) else {
            throw R01ExecutionFailure.setup
        }
        let first = try R01NV12PixelBufferFactory.make(
            dimensions: dimensions,
            requiredAttributes: configuration.sourcePixelBufferAttributes
        )
        let second = try R01NV12PixelBufferFactory.make(
            dimensions: dimensions,
            requiredAttributes: configuration.sourcePixelBufferAttributes
        )
        try R01PixelTransferRuntimeSession.copyNV12(
            firstPayload.data,
            dimensions: dimensions,
            to: first
        )
        try R01PixelTransferRuntimeSession.copyNV12(
            secondPayload.data,
            dimensions: dimensions,
            to: second
        )
        forwardFlow = try R01VTFrameProcessing.destinationBuffer(
            attributes: configuration.destinationPixelBufferAttributes
        )
        backwardFlow = try R01VTFrameProcessing.destinationBuffer(
            attributes: configuration.destinationPixelBufferAttributes
        )
        let firstFrame = try R01VTFrameProcessing.frame(
            buffer: first,
            time: CMTime(value: 0, timescale: 600)
        )
        let secondFrame = try R01VTFrameProcessing.frame(
            buffer: second,
            time: CMTime(value: 20, timescale: 600)
        )
        guard let flow = VTFrameProcessorOpticalFlow(
            forwardFlow: forwardFlow,
            backwardFlow: backwardFlow
        ), let parameters = VTOpticalFlowParameters(
            sourceFrame: firstFrame,
            nextFrame: secondFrame,
            submissionMode: .random,
            destinationOpticalFlow: flow
        ) else {
            throw R01ExecutionFailure.setup
        }
        self.parameters = parameters
        processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw R01ExecutionFailure.setup
        }
    }

    deinit { processor.endSession() }

    func runUnit(deadline: ContinuousClock.Instant) throws -> R01RuntimeUnitResult {
        try R01VTFrameProcessing.process(
            processor,
            parameters: parameters,
            deadline: deadline
        )
        let hashes = try [forwardFlow, backwardFlow].map {
            try R01PixelTransferRuntimeSession.activePlaneHash($0)
        }
        let dimensions = "\(CVPixelBufferGetWidth(forwardFlow))x\(CVPixelBufferGetHeight(forwardFlow))"
        return .init(
            outputSHA256: R01SHA256.hexDigest(Data(hashes.joined(separator: "\n").utf8)),
            classMetrics: [
                .flowDimensions: .string(dimensions),
                .flowFormat: .string(R01VTFrameProcessing.pixelFormatName(forwardFlow)),
                .confidenceAvailable: .boolean(false)
            ]
        )
    }
}
