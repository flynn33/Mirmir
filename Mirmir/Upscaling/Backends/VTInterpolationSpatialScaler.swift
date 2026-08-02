import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct VTInterpolationSpatialBackend: UpscaleBackend {
    let descriptor: BackendDescriptor

    init?(descriptor: BackendDescriptor) {
        guard descriptor.id == .videoToolboxInterpolationWithSpatialScale else { return nil }
        self.descriptor = descriptor
    }

    func availability(for source: VideoInfo, targetSize: CGSize, environment: RuntimeEnvironment) async -> BackendAvailability {
        switch NV12ScalerConfiguration.validate(source: source, targetSize: targetSize, backendID: descriptor.id) {
        case .unavailable(let reason): return .unavailable(reason: reason)
        case .valid(let nv12):
            let native = await environment.capabilityProbe.availability(for: descriptor.id, source: source, targetSize: targetSize)
            guard native == .available else { return native }
            guard #available(macOS 26.0, *) else { return .unavailable(reason: .operatingSystemTooOld(requiredVersion: "26.0")) }
            guard let configuration = makeConfiguration(nv12: nv12) else {
                return .unavailable(reason: .appleAPIUnsupported(details: "VideoToolbox rejected the 2× spatial/interpolation configuration"))
            }
            guard configuration.supportedPixelFormats.contains(nv12.pixelFormat) else {
                return .unavailable(reason: .unsupportedPixelFormatOrBitDepth(details: "the spatial interpolation processor does not accept the source NV12 range format"))
            }
            return .available
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
        guard let configuration = makeConfiguration(nv12: nv12) else {
            throw BackendPreparationError.unavailable(descriptor.id, .appleAPIUnsupported(details: "VideoToolbox rejected the 2× spatial/interpolation configuration"))
        }
        guard configuration.supportedPixelFormats.contains(nv12.pixelFormat) else {
            throw BackendPreparationError.unavailable(descriptor.id, .unsupportedPixelFormatOrBitDepth(details: "the spatial interpolation processor rejected the prepared NV12 format"))
        }
        return try PreparedVTInterpolationSpatialScaler(nv12: nv12, nativeConfiguration: configuration)
    }

    @available(macOS 26.0, *)
    private func makeConfiguration(nv12: NV12ScalerConfiguration) -> VTLowLatencyFrameInterpolationConfiguration? {
        guard nv12.targetWidth == nv12.sourceWidth * 2,
              nv12.targetHeight == nv12.sourceHeight * 2 else { return nil }
        return VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: nv12.sourceWidth,
            frameHeight: nv12.sourceHeight,
            spatialScaleFactor: 2
        )
    }
}

@available(macOS 26.0, *)
actor PreparedVTInterpolationSpatialScaler: PreparedTemporalFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID = .videoToolboxInterpolationWithSpatialScale
    nonisolated let maximumOutputFramesPerInput = 2

    private let nv12: NV12ScalerConfiguration
    private let processor = VTFrameProcessor()
    private var boundaryTransfer: VTPixelTransferSession?
    private var previousBuffer: CVPixelBuffer?
    private var previousFrame: VTFrameProcessorFrame?
    private var previousPTS: CMTime?
    private var finished = false

    init(nv12: NV12ScalerConfiguration, nativeConfiguration: VTLowLatencyFrameInterpolationConfiguration) throws {
        self.nv12 = nv12
        sourcePixelBufferAttributes = VTRequiredAttributes.merged(
            nativeConfiguration.sourcePixelBufferAttributes,
            exact: nv12.attributes(width: nv12.sourceWidth, height: nv12.sourceHeight).values
        )
        destinationPixelBufferAttributes = VTRequiredAttributes.merged(
            nativeConfiguration.destinationPixelBufferAttributes,
            exact: nv12.attributes(width: nv12.targetWidth, height: nv12.targetHeight).values
        )
        var transfer: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
        guard status == noErr, let transfer else {
            throw nv12.processingError("first-reference boundary pixel-transfer creation failed (\(status))")
        }
        let propertyStatus = VTSessionSetProperty(
            transfer,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Normal
        )
        guard propertyStatus == noErr else {
            VTPixelTransferSessionInvalidate(transfer)
            throw nv12.processingError("first-reference boundary scaling mode was rejected (\(propertyStatus))")
        }
        boundaryTransfer = transfer
        do { try processor.startSession(configuration: nativeConfiguration) }
        catch {
            VTPixelTransferSessionInvalidate(transfer)
            boundaryTransfer = nil
            throw nv12.processingError("spatial interpolation VTFrameProcessor session start failed: \(error.localizedDescription)")
        }
    }

    deinit {
        if !finished { processor.endSession() }
        if let boundaryTransfer { VTPixelTransferSessionInvalidate(boundaryTransfer) }
    }

    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        throw nv12.processingError("the cadence-changing backend requires the temporal media-loop contract", frameIndex: timing.frameIndex)
    }

    func processTemporal(source: FramePixelBuffer, destinations: [FramePixelBuffer], timing: FrameTiming) async throws -> [TemporalOutputFrame] {
        let source = source.value
        let destinations = destinations.map(\.value)
        guard !finished else { throw nv12.processingError("the spatial interpolation processor is already finished", frameIndex: timing.frameIndex) }
        guard destinations.count >= maximumOutputFramesPerInput else {
            throw nv12.processingError("the media loop did not supply two interpolation destination buffers", frameIndex: timing.frameIndex)
        }
        try nv12.validate(source, source: true)
        try destinations.forEach { try nv12.validate($0, source: false) }
        guard let currentFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: timing.presentationTime) else {
            throw nv12.processingError("VideoToolbox could not wrap the current reference frame", frameIndex: timing.frameIndex)
        }

        guard let previousFrame, let previousPTS else {
            guard let boundaryTransfer else {
                throw nv12.processingError("the first-reference boundary scaler is unavailable", frameIndex: timing.frameIndex)
            }
            let status = VTPixelTransferSessionTransferImage(
                boundaryTransfer,
                from: source,
                to: destinations[0]
            )
            guard status == noErr else {
                throw nv12.processingError("first-reference boundary scaling failed with OSStatus \(status)", frameIndex: timing.frameIndex)
            }
            NV12FrameAttachments.copy(from: source, to: destinations[0])
            previousBuffer = source
            self.previousFrame = currentFrame
            self.previousPTS = timing.presentationTime
            return [TemporalOutputFrame(
                pixelBuffer: FramePixelBuffer(destinations[0]),
                presentationTime: timing.presentationTime
            )]
        }

        let delta = CMTimeSubtract(timing.presentationTime, previousPTS)
        guard delta.isNumeric, CMTimeCompare(delta, .zero) > 0 else {
            throw nv12.processingError("reference-frame timing does not permit a midpoint", frameIndex: timing.frameIndex)
        }
        let midpoint = CMTimeAdd(
            previousPTS,
            CMTimeMultiplyByRatio(delta, multiplier: 1, divisor: 2)
        )
        guard let midpointFrame = VTFrameProcessorFrame(buffer: destinations[0], presentationTimeStamp: midpoint),
              let scaledCurrentFrame = VTFrameProcessorFrame(buffer: destinations[1], presentationTimeStamp: timing.presentationTime),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: currentFrame,
                previousFrame: previousFrame,
                interpolationPhase: [0.5],
                destinationFrames: [midpointFrame, scaledCurrentFrame]
              ) else {
            throw nv12.processingError("spatial interpolation parameters could not be created", frameIndex: timing.frameIndex)
        }
        do { _ = try await processor.process(parameters: parameters) }
        catch { throw nv12.processingError("spatial interpolation failed: \(error.localizedDescription)", frameIndex: timing.frameIndex) }
        NV12FrameAttachments.copy(from: source, to: destinations[0])
        NV12FrameAttachments.copy(from: source, to: destinations[1])
        previousBuffer = source
        self.previousFrame = currentFrame
        self.previousPTS = timing.presentationTime
        try Task.checkCancellation()
        return [
            TemporalOutputFrame(pixelBuffer: FramePixelBuffer(destinations[0]), presentationTime: midpoint),
            TemporalOutputFrame(pixelBuffer: FramePixelBuffer(destinations[1]), presentationTime: timing.presentationTime)
        ]
    }

    func finish() async throws {
        guard !finished else { return }
        finished = true
        previousBuffer = nil
        previousFrame = nil
        previousPTS = nil
        processor.endSession()
        if let transfer = boundaryTransfer {
            boundaryTransfer = nil
            VTPixelTransferSessionInvalidate(transfer)
        }
    }
}
