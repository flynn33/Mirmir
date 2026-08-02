import CoreVideo
import Foundation
import VideoToolbox

struct VTPixelTransferBackend: UpscaleBackend {
    let descriptor: BackendDescriptor

    init?(descriptor: BackendDescriptor) {
        guard descriptor.id == .videoToolboxPixelTransfer else { return nil }
        self.descriptor = descriptor
    }

    func availability(for source: VideoInfo, targetSize: CGSize, environment: RuntimeEnvironment) async -> BackendAvailability {
        switch NV12ScalerConfiguration.validate(source: source, targetSize: targetSize, backendID: descriptor.id) {
        case .unavailable(let reason): return .unavailable(reason: reason)
        case .valid:
            return await environment.capabilityProbe.availability(for: descriptor.id, source: source, targetSize: targetSize)
        }
    }

    func prepare(request: BackendPreparationRequest, environment: RuntimeEnvironment) async throws -> any PreparedFrameUpscaler {
        let configuration: NV12ScalerConfiguration
        switch NV12ScalerConfiguration.validate(source: request.source, targetSize: request.targetSize, backendID: descriptor.id) {
        case .valid(let value): configuration = value
        case .unavailable(let reason): throw BackendPreparationError.unavailable(descriptor.id, reason)
        }
        let availability = await environment.capabilityProbe.availability(for: descriptor.id, source: request.source, targetSize: request.targetSize)
        guard availability == .available else {
            if case .unavailable(let reason) = availability { throw BackendPreparationError.unavailable(descriptor.id, reason) }
            throw BackendPreparationError.unavailable(descriptor.id, .modelUnavailable(details: "pixel transfer unexpectedly returned a model state"))
        }
        return try PreparedVTPixelTransferScaler(configuration: configuration)
    }
}

actor PreparedVTPixelTransferScaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID

    private let configuration: NV12ScalerConfiguration
    private var session: VTPixelTransferSession?

    init(configuration: NV12ScalerConfiguration) throws {
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created)
        guard status == noErr, let created else {
            throw configuration.processingError("VTPixelTransferSessionCreate returned OSStatus \(status)")
        }
        do {
            let properties: [(CFString, CFTypeRef)] = [
                (kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal),
                (kVTPixelTransferPropertyKey_RealTime, kCFBooleanFalse)
            ]
            for (key, value) in properties {
                let propertyStatus = VTSessionSetProperty(created, key: key, value: value)
                guard propertyStatus == noErr else {
                    throw configuration.processingError("VideoToolbox rejected property \(key) with OSStatus \(propertyStatus)")
                }
            }
        } catch {
            VTPixelTransferSessionInvalidate(created)
            throw error
        }
        self.configuration = configuration
        session = created
        actualBackendID = configuration.backendID
        sourcePixelBufferAttributes = configuration.attributes(width: configuration.sourceWidth, height: configuration.sourceHeight)
        destinationPixelBufferAttributes = configuration.attributes(width: configuration.targetWidth, height: configuration.targetHeight)
    }

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        let source = source.value
        let destination = destination.value
        try Task.checkCancellation()
        try configuration.validate(source, source: true)
        try configuration.validate(destination, source: false)
        guard let session else {
            throw configuration.processingError("the pixel-transfer session is already finished", frameIndex: timing.frameIndex)
        }
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else {
            throw configuration.processingError("VTPixelTransferSessionTransferImage returned OSStatus \(status)", frameIndex: timing.frameIndex)
        }
        NV12FrameAttachments.copy(from: source, to: destination)
        try Task.checkCancellation()
    }

    func finish() async throws {
        guard let current = session else { return }
        session = nil
        VTPixelTransferSessionInvalidate(current)
    }
}
