import Foundation
import CoreVideo
import Metal

enum PixelBufferBridge {

    /// Pixel format used end-to-end. `420v` (8-bit 4:2:0 video range) is one of
    /// `VTSuperResolutionScalerConfiguration.supportedPixelFormats` on macOS
    /// and is also the natural ingest format for HEVC/H.264 sources.
    static let preferredFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    static func makePool(width: Int, height: Int, format: OSType = preferredFormat, capacity: Int = 6) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: format),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let auxAttrs: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: NSNumber(value: capacity)
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            auxAttrs as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: "PixelBufferBridge", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "CVPixelBufferPoolCreate failed: \(status)"
            ])
        }
        return pool
    }

    static func dequeue(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw NSError(domain: "PixelBufferBridge", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "CVPixelBufferPoolCreatePixelBuffer failed: \(status)"
            ])
        }
        return buffer
    }

    /// Bridges a `CVPixelBuffer` plane into a Metal texture via the supplied
    /// texture cache. The returned `CVMetalTexture` keeps a strong hold on the
    /// underlying Metal texture; callers must retain it for as long as the
    /// `MTLTexture` is in use.
    static func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int = 0
    ) throws -> (CVMetalTexture, MTLTexture) {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        var unmanaged: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &unmanaged
        )
        guard status == kCVReturnSuccess,
              let cvTexture = unmanaged,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw NSError(domain: "PixelBufferBridge", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "CVMetalTextureCacheCreateTextureFromImage failed: \(status)"
            ])
        }
        return (cvTexture, texture)
    }
}
