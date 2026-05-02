import Foundation
import Metal
import MetalPerformanceShaders
import CoreVideo

/// Lanczos downsample of the SR-produced 2× frame to the user's chosen output
/// resolution. Used for the 720p path: the 1280×720 source becomes a 2560×1440
/// SR frame, and this pass reduces it to 1920×1080.
final class LanczosPolishPass: @unchecked Sendable {

    private let metal: MetalRenderingService
    private let lanczos: MPSImageLanczosScale

    init(metal: MetalRenderingService) {
        self.metal = metal
        self.lanczos = MPSImageLanczosScale(device: metal.device)
    }

    func encode(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) async throws {
        let srcWidth = CVPixelBufferGetWidth(source)
        let srcHeight = CVPixelBufferGetHeight(source)
        let dstWidth = CVPixelBufferGetWidth(destination)
        let dstHeight = CVPixelBufferGetHeight(destination)

        // Lanczos requires a single-plane RGBA-style texture. Source pixel
        // buffers in this pipeline are 4:2:0 biplanar; we run Lanczos on the
        // luma plane and chroma plane separately. (For final-quality polish
        // we'd convert through a linear RGB intermediate; that optimisation is
        // queued as a follow-up to keep this pass focused.)
        try await encodePlane(planeIndex: 0, format: .r8Unorm, source: source, destination: destination)
        if CVPixelBufferGetPlaneCount(source) > 1 && CVPixelBufferGetPlaneCount(destination) > 1 {
            try await encodePlane(planeIndex: 1, format: .rg8Unorm, source: source, destination: destination)
        }
        _ = (srcWidth, srcHeight, dstWidth, dstHeight)
    }

    private func encodePlane(
        planeIndex: Int,
        format: MTLPixelFormat,
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) async throws {
        let (sourceCV, sourceTexture) = try PixelBufferBridge.makeTexture(
            from: source,
            cache: metal.textureCache,
            pixelFormat: format,
            planeIndex: planeIndex
        )
        let (destinationCV, destinationTexture) = try PixelBufferBridge.makeTexture(
            from: destination,
            cache: metal.textureCache,
            pixelFormat: format,
            planeIndex: planeIndex
        )
        _ = (sourceCV, destinationCV)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "LanczosPolishPass", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Could not allocate MTLCommandBuffer"
            ])
        }
        commandBuffer.label = "Mirmir.LanczosPolish.plane\(planeIndex)"

        var transform = MPSScaleTransform(
            scaleX: Double(destinationTexture.width) / Double(sourceTexture.width),
            scaleY: Double(destinationTexture.height) / Double(sourceTexture.height),
            translateX: 0,
            translateY: 0
        )
        withUnsafePointer(to: &transform) { (transformPointer: UnsafePointer<MPSScaleTransform>) in
            lanczos.scaleTransform = transformPointer
            lanczos.encode(
                commandBuffer: commandBuffer,
                sourceTexture: sourceTexture,
                destinationTexture: destinationTexture
            )
            lanczos.scaleTransform = nil
        }

        commandBuffer.commit()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
        }
    }
}
