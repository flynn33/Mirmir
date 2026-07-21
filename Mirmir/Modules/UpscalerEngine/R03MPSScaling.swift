import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

enum R03MPSScalingMode: String, CaseIterable, Hashable, Sendable {
    case lanczos = "r03.mps.lanczos"
    case bilinear = "r03.mps.bilinear"

    var subjectID: R03BaselineSubjectID {
        switch self {
        case .lanczos:
            return .mpsLanczos
        case .bilinear:
            return .mpsBilinear
        }
    }

    fileprivate func makeKernel(device: any MTLDevice) -> MPSImageScale {
        switch self {
        case .lanczos:
            return MPSImageLanczosScale(device: device)
        case .bilinear:
            return MPSImageBilinearScale(device: device)
        }
    }
}

extension R03DeterministicBackend {
    static func makeMPS(
        mode: R03MPSScalingMode,
        route: R03ScaleRoute,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        try R03DeterministicBackend(
            subjectID: mode.subjectID,
            route: route,
            scalerFactory: { sourceResolution, targetResolution in
                try requireExactMPSRoute(
                    route,
                    sourceResolution: sourceResolution,
                    targetResolution: targetResolution
                )
                return try R03MPSScaler(mode: mode, route: route)
            },
            outputReleaseObserver: outputReleaseObserver
        )
    }

    private static func requireExactMPSRoute(
        _ route: R03ScaleRoute,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution
    ) throws {
        guard sourceResolution == route.canonicalSourceResolution else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: route.canonicalSourceResolution.width,
                expectedHeight: route.canonicalSourceResolution.height,
                actualWidth: sourceResolution.width,
                actualHeight: sourceResolution.height
            )
        }
        guard targetResolution == route.canonicalTargetResolution else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: route.canonicalTargetResolution.width,
                expectedHeight: route.canonicalTargetResolution.height,
                actualWidth: targetResolution.width,
                actualHeight: targetResolution.height
            )
        }
    }
}

final class R03MPSScaler: R03NV12Scaling, @unchecked Sendable {
    let mode: R03MPSScalingMode
    let route: R03ScaleRoute

    private enum FailureCode: Int {
        case textureUnavailable = -1
        case commandBufferUnavailable = -2
        case commandBufferFailed = -3
    }

    private struct PlaneResources {
        let plane: Int
        let sourceReference: CVMetalTexture
        let sourceTexture: any MTLTexture
        let destinationReference: CVMetalTexture
        let destinationTexture: any MTLTexture
    }

    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let kernel: MPSImageScale
    private let executionLock = NSLock()

    init(mode: R03MPSScalingMode, route: R03ScaleRoute) throws {
        guard let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device) else {
            throw R03NV12ScalingError.runtimeUnavailable("r03_mps_device_unavailable")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw R03NV12ScalingError.runtimeUnavailable("r03_mps_queue_unavailable")
        }
        var unmanagedCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &unmanagedCache
        )
        guard cacheStatus == kCVReturnSuccess, let textureCache = unmanagedCache else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r03_mps_texture_cache_unavailable_\(cacheStatus)"
            )
        }

        self.mode = mode
        self.route = route
        sourceResolution = route.canonicalSourceResolution
        targetResolution = route.canonicalTargetResolution
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
        try R03NV12Contract.validate(
            pixelBuffer: source,
            resolution: sourceResolution
        )
        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: targetResolution
        )

        let resources = try [
            makePlaneResources(
                source: source,
                destination: destination,
                plane: 0,
                format: .r8Unorm
            ),
            makePlaneResources(
                source: source,
                destination: destination,
                plane: 1,
                format: .rg8Unorm
            )
        ]
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw R03NV12ScalingError.scalingFailed(
                plane: -1,
                status: FailureCode.commandBufferUnavailable.rawValue
            )
        }

        for resource in resources {
            var transform = MPSScaleTransform(
                scaleX: Double(resource.destinationTexture.width)
                    / Double(resource.sourceTexture.width),
                scaleY: Double(resource.destinationTexture.height)
                    / Double(resource.sourceTexture.height),
                translateX: 0,
                translateY: 0
            )
            withUnsafePointer(to: &transform) { transformPointer in
                kernel.scaleTransform = transformPointer
            }
            kernel.encode(
                commandBuffer: commandBuffer,
                sourceTexture: resource.sourceTexture,
                destinationTexture: resource.destinationTexture
            )
        }

        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        withExtendedLifetime(resources) {
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
    }

    func reset() {
        flushTextureCache()
    }

    func finish() {
        flushTextureCache()
    }

    private func flushTextureCache() {
        executionLock.lock()
        CVMetalTextureCacheFlush(textureCache, 0)
        executionLock.unlock()
    }

    private func makePlaneResources(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat
    ) throws -> PlaneResources {
        let sourceResource = try makeTexture(
            pixelBuffer: source,
            plane: plane,
            format: format,
            usage: .shaderRead
        )
        let destinationResource = try makeTexture(
            pixelBuffer: destination,
            plane: plane,
            format: format,
            usage: [.shaderRead, .shaderWrite]
        )
        return PlaneResources(
            plane: plane,
            sourceReference: sourceResource.reference,
            sourceTexture: sourceResource.texture,
            destinationReference: destinationResource.reference,
            destinationTexture: destinationResource.texture
        )
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        usage: MTLTextureUsage
    ) throws -> (reference: CVMetalTexture, texture: any MTLTexture) {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let attributes = [
            kCVMetalTextureUsage: NSNumber(value: usage.rawValue)
        ] as CFDictionary
        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            attributes,
            format,
            width,
            height,
            plane,
            &reference
        )
        guard status == kCVReturnSuccess else {
            throw R03NV12ScalingError.scalingFailed(
                plane: plane,
                status: Int(status)
            )
        }
        guard let reference, let texture = CVMetalTextureGetTexture(reference) else {
            throw R03NV12ScalingError.scalingFailed(
                plane: plane,
                status: FailureCode.textureUnavailable.rawValue
            )
        }
        return (reference, texture)
    }
}
