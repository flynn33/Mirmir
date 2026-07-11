import Foundation
import CoreVideo
import Metal

enum PixelBufferBridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPoolDimensions(width: Int, height: Int)
    case invalidPoolCapacity(Int)
    case missingPoolCapacity
    case poolCreationFailed(CVReturn)
    case poolDequeueFailed(CVReturn)
    case unsupportedPixelBufferFormat(expected: OSType, actual: OSType)
    case invalidPlaneCount(expected: Int, actual: Int)
    case invalidPlaneIndex(index: Int, planeCount: Int)
    case invalidPlaneDimensions(index: Int, width: Int, height: Int)
    case metalTextureCreationFailed(planeIndex: Int, pixelFormatRawValue: UInt, status: CVReturn)
    case metalTextureUnavailable(planeIndex: Int, pixelFormatRawValue: UInt)

    var description: String {
        switch self {
        case .invalidPoolDimensions(let width, let height):
            return "Invalid pixel-buffer pool dimensions: \(width)x\(height)."
        case .invalidPoolCapacity(let capacity):
            return "Invalid pixel-buffer pool capacity: \(capacity)."
        case .missingPoolCapacity:
            return "Pixel-buffer pool is missing its allocation-capacity contract."
        case .poolCreationFailed(let status):
            return "CVPixelBufferPoolCreate failed with status \(status)."
        case .poolDequeueFailed(let status):
            return "CVPixelBufferPoolCreatePixelBuffer failed with status \(status)."
        case .unsupportedPixelBufferFormat(let expected, let actual):
            return "Unsupported pixel-buffer format \(actual); expected \(expected)."
        case .invalidPlaneCount(let expected, let actual):
            return "Invalid pixel-buffer plane count \(actual); expected \(expected)."
        case .invalidPlaneIndex(let index, let planeCount):
            return "Invalid pixel-buffer plane index \(index) for \(planeCount) planes."
        case .invalidPlaneDimensions(let index, let width, let height):
            return "Invalid dimensions \(width)x\(height) for pixel-buffer plane \(index)."
        case .metalTextureCreationFailed(let planeIndex, let pixelFormatRawValue, let status):
            return "Metal texture creation failed for plane \(planeIndex), format \(pixelFormatRawValue), status \(status)."
        case .metalTextureUnavailable(let planeIndex, let pixelFormatRawValue):
            return "Metal texture creation returned no texture for plane \(planeIndex), format \(pixelFormatRawValue)."
        }
    }
}

/// Owns every object required to keep a Core Video plane valid for Metal work.
/// Instances must stay alive until the final command buffer using the texture
/// reaches a terminal state.
final class PixelBufferMetalTexture: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let cvMetalTexture: CVMetalTexture
    let texture: MTLTexture
    let planeIndex: Int

    init(
        pixelBuffer: CVPixelBuffer,
        cvMetalTexture: CVMetalTexture,
        texture: MTLTexture,
        planeIndex: Int
    ) {
        self.pixelBuffer = pixelBuffer
        self.cvMetalTexture = cvMetalTexture
        self.texture = texture
        self.planeIndex = planeIndex
    }
}

struct PixelBufferNV12Textures: Sendable {
    let luma: PixelBufferMetalTexture
    let chroma: PixelBufferMetalTexture

    var all: [PixelBufferMetalTexture] { [luma, chroma] }
}

enum PixelBufferBridge {

    /// Pixel format used end-to-end. `420v` (8-bit 4:2:0 video range) is one of
    /// `VTSuperResolutionScalerConfiguration.supportedPixelFormats` on macOS
    /// and is also the natural ingest format for HEVC/H.264 sources.
    static let preferredFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    static func makePool(width: Int, height: Int, format: OSType = preferredFormat, capacity: Int = 6) throws -> CVPixelBufferPool {
        guard width > 0, height > 0 else {
            throw PixelBufferBridgeError.invalidPoolDimensions(width: width, height: height)
        }
        guard capacity > 0 else {
            throw PixelBufferBridgeError.invalidPoolCapacity(capacity)
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: format),
            kCVPixelBufferWidthKey as String: NSNumber(value: width),
            kCVPixelBufferHeightKey as String: NSNumber(value: height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: NSNumber(value: capacity)
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw PixelBufferBridgeError.poolCreationFailed(status)
        }
        return pool
    }

    static func dequeue(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        guard let poolAttributes = CVPixelBufferPoolGetAttributes(pool) as? [String: Any],
              let capacity = poolAttributes[
                kCVPixelBufferPoolMinimumBufferCountKey as String
              ] as? NSNumber,
              capacity.intValue > 0 else {
            throw PixelBufferBridgeError.missingPoolCapacity
        }
        let allocationAttributes: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: capacity
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            allocationAttributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw PixelBufferBridgeError.poolDequeueFailed(status)
        }
        return buffer
    }

    static func validateNV12(_ pixelBuffer: CVPixelBuffer) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == preferredFormat else {
            throw PixelBufferBridgeError.unsupportedPixelBufferFormat(
                expected: preferredFormat,
                actual: actualFormat
            )
        }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount == 2 else {
            throw PixelBufferBridgeError.invalidPlaneCount(expected: 2, actual: planeCount)
        }
    }

    static func makeNV12Textures(
        from pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache
    ) throws -> PixelBufferNV12Textures {
        try validateNV12(pixelBuffer)
        return PixelBufferNV12Textures(
            luma: try makeTextureResource(
                from: pixelBuffer,
                cache: cache,
                pixelFormat: .r8Unorm,
                planeIndex: 0
            ),
            chroma: try makeTextureResource(
                from: pixelBuffer,
                cache: cache,
                pixelFormat: .rg8Unorm,
                planeIndex: 1
            )
        )
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
        let resource = try makeTextureResource(
            from: pixelBuffer,
            cache: cache,
            pixelFormat: pixelFormat,
            planeIndex: planeIndex
        )
        return (resource.cvMetalTexture, resource.texture)
    }

    static func makeTextureResource(
        from pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        pixelFormat: MTLPixelFormat,
        planeIndex: Int = 0
    ) throws -> PixelBufferMetalTexture {
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeIndex >= 0, planeIndex < planeCount else {
            throw PixelBufferBridgeError.invalidPlaneIndex(index: planeIndex, planeCount: planeCount)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        guard width > 0, height > 0 else {
            throw PixelBufferBridgeError.invalidPlaneDimensions(
                index: planeIndex,
                width: width,
                height: height
            )
        }
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
        guard status == kCVReturnSuccess else {
            throw PixelBufferBridgeError.metalTextureCreationFailed(
                planeIndex: planeIndex,
                pixelFormatRawValue: pixelFormat.rawValue,
                status: status
            )
        }
        guard let cvTexture = unmanaged,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw PixelBufferBridgeError.metalTextureUnavailable(
                planeIndex: planeIndex,
                pixelFormatRawValue: pixelFormat.rawValue
            )
        }
        return PixelBufferMetalTexture(
            pixelBuffer: pixelBuffer,
            cvMetalTexture: cvTexture,
            texture: texture,
            planeIndex: planeIndex
        )
    }
}
