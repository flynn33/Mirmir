import CoreVideo
import Foundation
import Metal
import MetalPerformanceShaders

struct R03MPSTextureDimensionLimitError:
    Error,
    CustomNSError,
    CustomStringConvertible,
    Equatable,
    Sendable {
    let maximumTextureDimension2D: Int
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution

    static var errorDomain: String {
        "com.mirmir.upscaler.mps-texture-dimension-limit"
    }

    var errorCode: Int { 1 }

    var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: description,
            "maximum_texture_dimension_2d": maximumTextureDimension2D,
            "source_width": sourceResolution.width,
            "source_height": sourceResolution.height,
            "target_width": targetResolution.width,
            "target_height": targetResolution.height
        ]
    }

    var description: String {
        "Metal maxTextureDimension2D "
            + "\(maximumTextureDimension2D) cannot represent adaptive "
            + "source \(sourceResolution) and target \(targetResolution)."
    }
}

enum R03MPSHardwareLimits {
    static func maximumTextureDimension2D(
        for device: any MTLDevice
    ) -> Int {
        // Metal exposes GPU-family membership, while the 2D texture limit is
        // published in Apple's Metal Feature Set Tables rather than as an
        // MTLDevice property. Apple10 raises the limit to 32768; Apple3 and
        // later, Mac2, and Metal3 use 16384; Apple1/Apple2 use 8192.
        if device.supportsFamily(.apple10) {
            return 32_768
        }
        if device.supportsFamily(.apple3)
            || device.supportsFamily(.mac2)
            || device.supportsFamily(.metal3) {
            return 16_384
        }
        return 8_192
    }
}

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

    func makeKernel(device: any MTLDevice) -> MPSImageScale {
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

    static func makeProductQualifiedMPSBilinear(
        route: R03ScaleRoute,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        let kind = R13ReleaseScalerKind.fastMPSBilinear
        return try R03DeterministicBackend(
            subjectID: kind.subjectID,
            route: route,
            admissionProfile: .productQualifiedReleaseScaler(kind),
            productAdmissionAuthorization:
                R03A11ProductAdmissionAuthorization(),
            scalerFactory: { sourceResolution, targetResolution in
                try requireExactMPSRoute(
                    route,
                    sourceResolution: sourceResolution,
                    targetResolution: targetResolution
                )
                return try R03MPSScaler(
                    mode: .bilinear,
                    route: route
                )
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
    let route: R03ScaleRoute?

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

    convenience init(
        mode: R03MPSScalingMode,
        route: R03ScaleRoute
    ) throws {
        try self.init(
            mode: mode,
            route: route,
            sourceResolution: route.canonicalSourceResolution,
            targetResolution: route.canonicalTargetResolution
        )
    }

    convenience init(
        mode: R03MPSScalingMode,
        adaptivePlan: R13AdaptiveScalePlan
    ) throws {
        try self.init(
            mode: mode,
            route: nil,
            sourceResolution:
                adaptivePlan.processingSourceResolution,
            targetResolution: adaptivePlan.targetResolution
        )
    }

    private init(
        mode: R03MPSScalingMode,
        route: R03ScaleRoute?,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(), MPSSupportsMTLDevice(device) else {
            throw R03NV12ScalingError.runtimeUnavailable("r03_mps_device_unavailable")
        }
        try Self.validateTextureDimensions(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            maximumTextureDimension2D:
                R03MPSHardwareLimits.maximumTextureDimension2D(
                    for: device
                )
        )
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
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        kernel = mode.makeKernel(device: device)
    }

    static func validateTextureDimensions(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        maximumTextureDimension2D: Int
    ) throws {
        guard maximumTextureDimension2D > 0,
              sourceResolution.width <= maximumTextureDimension2D,
              sourceResolution.height <= maximumTextureDimension2D,
              targetResolution.width <= maximumTextureDimension2D,
              targetResolution.height <= maximumTextureDimension2D else {
            throw R03MPSTextureDimensionLimitError(
                maximumTextureDimension2D:
                    maximumTextureDimension2D,
                sourceResolution: sourceResolution,
                targetResolution: targetResolution
            )
        }
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
