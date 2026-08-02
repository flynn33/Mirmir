import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct VTLowLatencySuperResolutionBackend: UpscaleBackend {
    let descriptor: BackendDescriptor

    init?(descriptor: BackendDescriptor) {
        guard descriptor.id == .videoToolboxSuperResolutionLowLatency else { return nil }
        self.descriptor = descriptor
    }

    func availability(for source: VideoInfo, targetSize: CGSize, environment: RuntimeEnvironment) async -> BackendAvailability {
        switch NV12ScalerConfiguration.validate(source: source, targetSize: targetSize, backendID: descriptor.id) {
        case .unavailable(let reason): return .unavailable(reason: reason)
        case .valid(let nv12):
            let native = await environment.capabilityProbe.availability(for: descriptor.id, source: source, targetSize: targetSize)
            guard native == .available else { return native }
            guard #available(macOS 26.0, *) else { return .unavailable(reason: .operatingSystemTooOld(requiredVersion: "26.0")) }
            do {
                let configuration = try makeConfiguration(nv12: nv12)
                guard configuration.supportedPixelFormats.contains(nv12.pixelFormat) else {
                    return .unavailable(reason: .unsupportedPixelFormatOrBitDepth(details: "the low-latency processor does not accept the source NV12 range format"))
                }
                return .available
            } catch let error as VTLowLatencyConfigurationError {
                return .unavailable(reason: error.reason)
            } catch {
                return .unavailable(reason: .appleAPIUnsupported(details: error.localizedDescription))
            }
        }
    }

    func prepare(request: BackendPreparationRequest, environment: RuntimeEnvironment) async throws -> any PreparedFrameUpscaler {
        let nv12: NV12ScalerConfiguration
        switch NV12ScalerConfiguration.validate(source: request.source, targetSize: request.targetSize, backendID: descriptor.id) {
        case .valid(let value): nv12 = value
        case .unavailable(let reason): throw BackendPreparationError.unavailable(descriptor.id, reason)
        }
        guard #available(macOS 26.0, *) else {
            throw BackendPreparationError.unavailable(descriptor.id, .operatingSystemTooOld(requiredVersion: "26.0"))
        }
        let configuration: VTLowLatencySuperResolutionScalerConfiguration
        do { configuration = try makeConfiguration(nv12: nv12) }
        catch let error as VTLowLatencyConfigurationError { throw BackendPreparationError.unavailable(descriptor.id, error.reason) }
        guard configuration.supportedPixelFormats.contains(nv12.pixelFormat) else {
            throw BackendPreparationError.unavailable(descriptor.id, .unsupportedPixelFormatOrBitDepth(details: "the low-latency processor rejected the prepared NV12 format"))
        }
        return try PreparedVTLowLatencySuperResolutionScaler(nv12: nv12, nativeConfiguration: configuration)
    }

    @available(macOS 26.0, *)
    private func makeConfiguration(nv12: NV12ScalerConfiguration) throws -> VTLowLatencySuperResolutionScalerConfiguration {
        let horizontal = Float(nv12.targetWidth) / Float(nv12.sourceWidth)
        let vertical = Float(nv12.targetHeight) / Float(nv12.sourceHeight)
        guard horizontal > 1, abs(horizontal - vertical) < 0.000_001 else {
            throw VTLowLatencyConfigurationError(.unsupportedScaleFactor(details: "low-latency VideoToolbox requires a uniform scale factor"))
        }
        let supported = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
            frameWidth: nv12.sourceWidth,
            frameHeight: nv12.sourceHeight
        )
        guard supported.contains(where: { abs($0 - horizontal) < 0.000_001 }) else {
            throw VTLowLatencyConfigurationError(.unsupportedScaleFactor(details: "requested \(horizontal)×; this Mac reports \(supported) for \(nv12.sourceWidth) × \(nv12.sourceHeight)"))
        }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: nv12.sourceWidth,
            frameHeight: nv12.sourceHeight,
            scaleFactor: horizontal
        )
        return configuration
    }
}

private struct VTLowLatencyConfigurationError: Error {
    let reason: BackendUnavailableReason
    init(_ reason: BackendUnavailableReason) { self.reason = reason }
}

@available(macOS 26.0, *)
actor PreparedVTLowLatencySuperResolutionScaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID = .videoToolboxSuperResolutionLowLatency

    private let nv12: NV12ScalerConfiguration
    private let processor = VTFrameProcessor()
    private var finished = false

    init(nv12: NV12ScalerConfiguration, nativeConfiguration: VTLowLatencySuperResolutionScalerConfiguration) throws {
        self.nv12 = nv12
        sourcePixelBufferAttributes = VTRequiredAttributes.merged(
            nativeConfiguration.sourcePixelBufferAttributes,
            exact: nv12.attributes(width: nv12.sourceWidth, height: nv12.sourceHeight).values
        )
        destinationPixelBufferAttributes = VTRequiredAttributes.merged(
            nativeConfiguration.destinationPixelBufferAttributes,
            exact: nv12.attributes(width: nv12.targetWidth, height: nv12.targetHeight).values
        )
        do { try processor.startSession(configuration: nativeConfiguration) }
        catch { throw nv12.processingError("low-latency VTFrameProcessor session start failed: \(error.localizedDescription)") }
    }

    deinit { if !finished { processor.endSession() } }

    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        let source = source.value
        let destination = destination.value
        guard !finished else { throw nv12.processingError("the low-latency processor is already finished", frameIndex: timing.frameIndex) }
        try nv12.validate(source, source: true)
        try nv12.validate(destination, source: false)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: timing.presentationTime),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: timing.presentationTime) else {
            throw nv12.processingError("low-latency VideoToolbox frame creation failed", frameIndex: timing.frameIndex)
        }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        do { _ = try await processor.process(parameters: parameters) }
        catch { throw nv12.processingError("low-latency VideoToolbox processing failed: \(error.localizedDescription)", frameIndex: timing.frameIndex) }
        NV12FrameAttachments.copy(from: source, to: destination)
        try Task.checkCancellation()
    }

    func finish() async throws {
        guard !finished else { return }
        finished = true
        processor.endSession()
    }
}

@available(macOS 26.0, *)
enum VTRequiredAttributes {
    static func merged(_ required: [String: any Sendable], exact: [String: Any]) -> PixelBufferAttributes {
        var values: [String: Any] = [:]
        for (key, value) in required { values[key] = value }
        for (key, value) in exact { values[key] = value }
        return PixelBufferAttributes(values)
    }
}
