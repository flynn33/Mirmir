import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

enum MPSScalingMode: Sendable {
    case lanczos
    case bilinear

    init?(backendID: UpscaleBackendID) {
        switch backendID {
        case .mpsLanczos: self = .lanczos
        case .mpsBilinear: self = .bilinear
        default: return nil
        }
    }
}

struct MPSBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let mode: MPSScalingMode

    init?(descriptor: BackendDescriptor) {
        guard let mode = MPSScalingMode(backendID: descriptor.id) else { return nil }
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
            throw BackendPreparationError.unavailable(descriptor.id, .modelUnavailable(details: "MPS unexpectedly returned a model state"))
        }
        return try PreparedMPSScaler(configuration: configuration, mode: mode)
    }
}

actor PreparedMPSScaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID

    private let configuration: NV12ScalerConfiguration
    private let queue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let kernel: MPSImageScale
    private var finished = false

    init(configuration: NV12ScalerConfiguration, mode: MPSScalingMode) throws {
        guard let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device),
              let queue = device.makeCommandQueue() else {
            throw configuration.processingError("Metal Performance Shaders could not create its device or command queue")
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw configuration.processingError("Core Video could not create the Metal texture cache (\(status))")
        }
        self.configuration = configuration
        self.queue = queue
        textureCache = cache
        kernel = mode == .lanczos
            ? MPSImageLanczosScale(device: device)
            : MPSImageBilinearScale(device: device)
        kernel.edgeMode = .clamp
        actualBackendID = configuration.backendID
        sourcePixelBufferAttributes = configuration.attributes(width: configuration.sourceWidth, height: configuration.sourceHeight, metalCompatible: true)
        destinationPixelBufferAttributes = configuration.attributes(width: configuration.targetWidth, height: configuration.targetHeight, metalCompatible: true)
    }

    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        let source = source.value
        let destination = destination.value
        guard !finished else { throw configuration.processingError("the prepared adapter is already finished", frameIndex: timing.frameIndex) }
        try Task.checkCancellation()
        try configuration.validate(source, source: true)
        try configuration.validate(destination, source: false)
        let chromaTranslation = try NV12FrameAttachments.chromaScaleTranslation(
            from: source,
            scaleX: Double(configuration.targetWidth) / Double(configuration.sourceWidth),
            scaleY: Double(configuration.targetHeight) / Double(configuration.sourceHeight),
            backendID: actualBackendID, frameIndex: timing.frameIndex)
        let resources = [
            try makePlane(source: source, destination: destination, plane: 0, format: .r8Unorm, frameIndex: timing.frameIndex),
            try makePlane(source: source, destination: destination, plane: 1, format: .rg8Unorm, frameIndex: timing.frameIndex)
        ]
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw configuration.processingError("Metal could not create a command buffer", frameIndex: timing.frameIndex)
        }
        for (plane, resource) in resources.enumerated() {
            var transform = MPSScaleTransform(
                scaleX: Double(resource.destination.width) / Double(resource.source.width),
                scaleY: Double(resource.destination.height) / Double(resource.source.height),
                translateX: plane == 0 ? 0 : chromaTranslation.x,
                translateY: plane == 0 ? 0 : chromaTranslation.y
            )
            withUnsafePointer(to: &transform) { kernel.scaleTransform = $0 }
            kernel.encode(commandBuffer: commandBuffer, sourceTexture: resource.source, destinationTexture: resource.destination)
        }
        commandBuffer.commit()
        await commandBuffer.completed()
        withExtendedLifetime(resources) {}
        guard commandBuffer.status == .completed else {
            throw configuration.processingError(commandBuffer.error?.localizedDescription ?? "the GPU command failed", frameIndex: timing.frameIndex)
        }
        NV12FrameAttachments.copy(from: source, to: destination)
        try Task.checkCancellation()
    }

    func finish() async throws {
        guard !finished else { return }
        CVMetalTextureCacheFlush(textureCache, 0)
        finished = true
    }

    private struct PlaneResources {
        let sourceReference: CVMetalTexture
        let source: any MTLTexture
        let destinationReference: CVMetalTexture
        let destination: any MTLTexture
    }

    private func makePlane(source: CVPixelBuffer, destination: CVPixelBuffer, plane: Int, format: MTLPixelFormat, frameIndex: Int) throws -> PlaneResources {
        let sourceTexture = try makeTexture(buffer: source, plane: plane, format: format, usage: .shaderRead, frameIndex: frameIndex)
        let destinationTexture = try makeTexture(buffer: destination, plane: plane, format: format, usage: [.shaderRead, .shaderWrite], frameIndex: frameIndex)
        return PlaneResources(sourceReference: sourceTexture.reference, source: sourceTexture.texture, destinationReference: destinationTexture.reference, destination: destinationTexture.texture)
    }

    private func makeTexture(buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, usage: MTLTextureUsage, frameIndex: Int) throws -> (reference: CVMetalTexture, texture: any MTLTexture) {
        var reference: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: NSNumber(value: usage.rawValue)] as CFDictionary
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, attributes, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &reference
        )
        guard status == kCVReturnSuccess, let reference,
              let texture = CVMetalTextureGetTexture(reference) else {
            throw configuration.processingError("Metal texture creation failed for NV12 plane \(plane) (\(status))", frameIndex: frameIndex)
        }
        return (reference, texture)
    }
}
