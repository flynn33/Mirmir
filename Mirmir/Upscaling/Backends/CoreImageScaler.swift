import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

enum CoreImageScalingMode: Sendable {
    case lanczos
    case bicubic

    init?(backendID: UpscaleBackendID) {
        switch backendID {
        case .coreImageLanczos: self = .lanczos
        case .coreImageBicubic: self = .bicubic
        default: return nil
        }
    }
}

struct CoreImageBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let mode: CoreImageScalingMode

    init?(descriptor: BackendDescriptor) {
        guard let mode = CoreImageScalingMode(backendID: descriptor.id) else { return nil }
        self.descriptor = descriptor
        self.mode = mode
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
            throw BackendPreparationError.unavailable(descriptor.id, .modelUnavailable(details: "Core Image unexpectedly returned a model state"))
        }
        return PreparedCoreImageScaler(configuration: configuration, mode: mode)
    }
}

actor PreparedCoreImageScaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID

    private let configuration: NV12ScalerConfiguration
    private let mode: CoreImageScalingMode
    private let context: CIContext
    private var finished = false

    init(configuration: NV12ScalerConfiguration, mode: CoreImageScalingMode) {
        self.configuration = configuration
        self.mode = mode
        context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
        actualBackendID = configuration.backendID
        sourcePixelBufferAttributes = configuration.attributes(width: configuration.sourceWidth, height: configuration.sourceHeight)
        destinationPixelBufferAttributes = configuration.attributes(width: configuration.targetWidth, height: configuration.targetHeight)
    }

    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        let source = source.value
        let destination = destination.value
        guard !finished else { throw configuration.processingError("the prepared adapter is already finished", frameIndex: timing.frameIndex) }
        try Task.checkCancellation()
        try configuration.validate(source, source: true)
        try configuration.validate(destination, source: false)

        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else {
            throw configuration.processingError("source pixel-buffer lock failed with Core Video status \(sourceLock)", frameIndex: timing.frameIndex)
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let destinationLock = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else {
            throw configuration.processingError("destination pixel-buffer lock failed with Core Video status \(destinationLock)", frameIndex: timing.frameIndex)
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        for plane in 0..<2 {
            try Task.checkCancellation()
            try renderPlane(
                source: source,
                destination: destination,
                plane: plane,
                frameIndex: timing.frameIndex
            )
        }
        NV12FrameAttachments.copy(from: source, to: destination)
    }

    func finish() async throws {
        guard !finished else { return }
        context.clearCaches()
        finished = true
    }

    private func renderPlane(source: CVPixelBuffer, destination: CVPixelBuffer, plane: Int, frameIndex: Int) throws {
        guard let sourceAddress = CVPixelBufferGetBaseAddressOfPlane(source, plane),
              let destinationAddress = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
            throw configuration.processingError("NV12 plane \(plane) has no accessible base address", frameIndex: frameIndex)
        }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(source, plane)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(source, plane)
        let destinationWidth = CVPixelBufferGetWidthOfPlane(destination, plane)
        let destinationHeight = CVPixelBufferGetHeightOfPlane(destination, plane)
        let sourceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
        let format: CIFormat = plane == 0 ? .L8 : .RG8
        let data = Data(bytes: sourceAddress, count: sourceRowBytes * sourceHeight)
        let sourceImage = CIImage(
            bitmapData: data,
            bytesPerRow: sourceRowBytes,
            size: CGSize(width: sourceWidth, height: sourceHeight),
            format: format,
            colorSpace: nil
        )
        let verticalScale = Float(destinationHeight) / Float(sourceHeight)
        let horizontalScale = Float(destinationWidth) / Float(sourceWidth)
        let output: CIImage?
        switch mode {
        case .lanczos:
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = sourceImage.clampedToExtent()
            filter.scale = verticalScale
            filter.aspectRatio = horizontalScale / verticalScale
            output = filter.outputImage
        case .bicubic:
            let filter = CIFilter.bicubicScaleTransform()
            filter.inputImage = sourceImage.clampedToExtent()
            filter.scale = verticalScale
            filter.aspectRatio = horizontalScale / verticalScale
            filter.parameterB = 0
            filter.parameterC = 0.75
            output = filter.outputImage
        }
        guard let output else {
            throw configuration.processingError("Core Image produced no filtered image for NV12 plane \(plane)", frameIndex: frameIndex)
        }
        let bounds = CGRect(x: 0, y: 0, width: destinationWidth, height: destinationHeight)
        context.render(
            output.cropped(to: bounds),
            toBitmap: destinationAddress,
            rowBytes: destinationRowBytes,
            bounds: bounds,
            format: format,
            colorSpace: nil
        )
    }
}
