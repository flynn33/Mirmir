import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

/// Scales every release video format through the explicitly selected MPS
/// kernel without converting color representation or dropping alpha.
///
/// P010 planes are exposed to Metal as normalized 16-bit textures. MPS may
/// produce intermediate values between valid ten-bit code words, so the
/// destination is requantized to the P010 six-zero-low-bit storage contract
/// before it is returned to the media pipeline.
final class R13FormatPreservingMPSScaler:
    R03NV12Scaling,
    @unchecked Sendable {
    let mode: R03MPSScalingMode
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let videoFormat: MediaVideoFormat

    private enum FailureCode: Int {
        case textureUnavailable = -1
        case commandBufferUnavailable = -2
        case commandBufferFailed = -3
    }

    private struct TexturePlane {
        let planeIndex: Int
        let sourceReference: CVMetalTexture
        let sourceTexture: any MTLTexture
        let destinationReference: CVMetalTexture
        let destinationTexture: any MTLTexture
    }

    private struct PlaneDescriptor {
        let planeIndex: Int
        let pixelFormat: MTLPixelFormat
        let sourceWidth: Int
        let sourceHeight: Int
        let destinationWidth: Int
        let destinationHeight: Int
    }

    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let kernel: MPSImageScale
    private let executionLock = NSLock()

    init(
        mode: R03MPSScalingMode,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              MPSSupportsMTLDevice(device) else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_preserving_mps_device_unavailable"
            )
        }
        try R03MPSScaler.validateTextureDimensions(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            maximumTextureDimension2D:
                R03MPSHardwareLimits.maximumTextureDimension2D(
                    for: device
                )
        )
        guard let commandQueue = device.makeCommandQueue() else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_preserving_mps_queue_unavailable"
            )
        }
        var optionalCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &optionalCache
        )
        guard cacheStatus == kCVReturnSuccess,
              let textureCache = optionalCache else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_preserving_mps_texture_cache_unavailable_"
                    + "\(cacheStatus)"
            )
        }

        self.mode = mode
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.videoFormat = videoFormat
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        kernel = mode.makeKernel(device: device)
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
        executionLock.lock()
        defer { executionLock.unlock() }

        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: sourceResolution,
            format: videoFormat
        )
        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: targetResolution,
            format: videoFormat
        )

        let planes = try planeDescriptors(
            source: source,
            destination: destination
        ).map {
            try makeTexturePlane(
                source: source,
                destination: destination,
                descriptor: $0
            )
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            throw R03NV12ScalingError.scalingFailed(
                plane: -1,
                status:
                    FailureCode.commandBufferUnavailable.rawValue
            )
        }

        for plane in planes {
            var transform = MPSScaleTransform(
                scaleX:
                    Double(plane.destinationTexture.width)
                    / Double(plane.sourceTexture.width),
                scaleY:
                    Double(plane.destinationTexture.height)
                    / Double(plane.sourceTexture.height),
                translateX: 0,
                translateY: 0
            )
            withUnsafePointer(to: &transform) {
                kernel.scaleTransform = $0
            }
            kernel.encode(
                commandBuffer: commandBuffer,
                sourceTexture: plane.sourceTexture,
                destinationTexture: plane.destinationTexture
            )
        }

        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        withExtendedLifetime(planes) {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        guard commandBuffer.status == .completed else {
            throw R03NV12ScalingError.scalingFailed(
                plane: -1,
                status: commandBuffer.error?._code
                    ?? FailureCode.commandBufferFailed.rawValue
            )
        }
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }

        do {
            try R13PixelLayoutProcessor.enforceCodeBounds(
                destination
            )
        } catch let error as R13PixelLayoutError {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_mps_bounds_\(error)"
            )
        }
        CVBufferPropagateAttachments(source, destination)
        R13MediaVideoFormatContract.install(
            videoFormat,
            on: destination,
            resolution: targetResolution
        )
        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: targetResolution,
            format: videoFormat
        )
    }

    func reset() {
        flushTextureCache()
    }

    func finish() {
        flushTextureCache()
    }

    func cancel() {
        flushTextureCache()
    }

    private func flushTextureCache() {
        executionLock.lock()
        CVMetalTextureCacheFlush(textureCache, 0)
        executionLock.unlock()
    }

    private func planeDescriptors(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws -> [PlaneDescriptor] {
        let layout = try R13PixelLayoutRegistry.layout(
            for: videoFormat.pixelStorage.pixelFormat
        )
        try layout.validate(source)
        try layout.validate(destination)
        return try layout.planes.enumerated().map { index, plane in
            PlaneDescriptor(
                planeIndex: index,
                pixelFormat: try metalPixelFormat(
                    plane,
                    storage: videoFormat.pixelStorage
                ),
                sourceWidth: R13PixelBufferAccess.width(
                    of: source,
                    layout: layout,
                    plane: index
                ),
                sourceHeight: R13PixelBufferAccess.height(
                    of: source,
                    layout: layout,
                    plane: index
                ),
                destinationWidth: R13PixelBufferAccess.width(
                    of: destination,
                    layout: layout,
                    plane: index
                ),
                destinationHeight: R13PixelBufferAccess.height(
                    of: destination,
                    layout: layout,
                    plane: index
                )
            )
        }
    }

    private func metalPixelFormat(
        _ plane: R13PixelPlaneLayout,
        storage: MediaVideoPixelStorage
    ) throws -> MTLPixelFormat {
        if plane.role == .packedBGRA {
            return .bgra8Unorm
        }
        switch (
            plane.bytesPerComponent,
            plane.componentsPerElement
        ) {
        case (1, 1):
            return .r8Unorm
        case (1, 2):
            return .rg8Unorm
        case (1, 4):
            return .rgba8Unorm
        case (2, 1):
            return .r16Unorm
        case (2, 2):
            return .rg16Unorm
        case (2, 4):
            return .rgba16Unorm
        default:
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_mps_plane_unsupported_"
                    + storage.rawValue
            )
        }
    }

    private func makeTexturePlane(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        descriptor: PlaneDescriptor
    ) throws -> TexturePlane {
        let sourceResource = try makeTexture(
            pixelBuffer: source,
            planeIndex: descriptor.planeIndex,
            pixelFormat: descriptor.pixelFormat,
            width: descriptor.sourceWidth,
            height: descriptor.sourceHeight,
            usage: .shaderRead
        )
        let destinationResource = try makeTexture(
            pixelBuffer: destination,
            planeIndex: descriptor.planeIndex,
            pixelFormat: descriptor.pixelFormat,
            width: descriptor.destinationWidth,
            height: descriptor.destinationHeight,
            usage: [.shaderRead, .shaderWrite]
        )
        return TexturePlane(
            planeIndex: descriptor.planeIndex,
            sourceReference: sourceResource.reference,
            sourceTexture: sourceResource.texture,
            destinationReference: destinationResource.reference,
            destinationTexture: destinationResource.texture
        )
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) throws -> (
        reference: CVMetalTexture,
        texture: any MTLTexture
    ) {
        let attributes = [
            kCVMetalTextureUsage: NSNumber(value: usage.rawValue)
        ] as CFDictionary
        var optionalReference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            attributes,
            pixelFormat,
            width,
            height,
            planeIndex,
            &optionalReference
        )
        guard status == kCVReturnSuccess else {
            throw R03NV12ScalingError.scalingFailed(
                plane: planeIndex,
                status: Int(status)
            )
        }
        guard let reference = optionalReference,
              let texture = CVMetalTextureGetTexture(reference) else {
            throw R03NV12ScalingError.scalingFailed(
                plane: planeIndex,
                status: FailureCode.textureUnavailable.rawValue
            )
        }
        return (reference, texture)
    }

}
