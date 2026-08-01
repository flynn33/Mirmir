import Foundation
import CoreVideo
@preconcurrency import Metal
@preconcurrency import MetalFX

// Native adapters and the transactional driver stay together for lifetime auditing.
// swiftlint:disable file_length

// The driver intentionally owns only MetalFX orchestration. An injected color
// converter owns the explicit NV12 <-> linear BT.709 conversion contract.

struct R05MetalFXSpatialDriverDimensions: Equatable, Hashable, Sendable {
    let width: Int
    let height: Int
}

enum R05MetalFXSpatialDriverRoute: String, CaseIterable, Hashable, Sendable {
    case oneAndOneHalf = "a07_spatial_720p_to_1080p"
    case two = "a07_spatial_1080p_to_2160p"
    case four = "a07_spatial_270p_to_1080p"

    var sourceDimensions: R05MetalFXSpatialDriverDimensions {
        switch self {
        case .oneAndOneHalf:
            return R05MetalFXSpatialDriverDimensions(width: 1280, height: 720)
        case .two:
            return R05MetalFXSpatialDriverDimensions(width: 1920, height: 1080)
        case .four:
            return R05MetalFXSpatialDriverDimensions(width: 480, height: 270)
        }
    }

    var targetDimensions: R05MetalFXSpatialDriverDimensions {
        switch self {
        case .oneAndOneHalf:
            return R05MetalFXSpatialDriverDimensions(width: 1920, height: 1080)
        case .two:
            return R05MetalFXSpatialDriverDimensions(width: 3840, height: 2160)
        case .four:
            return R05MetalFXSpatialDriverDimensions(width: 1920, height: 1080)
        }
    }
}

enum R05MetalFXSpatialDriverRejectionReason: String, CaseIterable, Equatable, Sendable {
    case sourceGeometryMismatch = "r05_metalfx_spatial_source_geometry_mismatch"
    case destinationGeometryMismatch = "r05_metalfx_spatial_destination_geometry_mismatch"
}

enum R05MetalFXSpatialDriverUnsupportedReason: String, CaseIterable, Equatable, Sendable {
    case deviceUnsupported = "r05_metalfx_spatial_device_unsupported"
}

enum R05MetalFXSpatialDriverUnavailableReason: String, CaseIterable, Equatable, Sendable {
    case spatialScalerCreationReturnedNil =
        "r05_metalfx_spatial_scaler_creation_returned_nil"
}

enum R05MetalFXSpatialDriverFailureReason: String, CaseIterable, Equatable, Sendable {
    case linearInputTextureAllocationFailed =
        "r05_metalfx_spatial_linear_input_texture_allocation_failed"
    case linearOutputTextureAllocationFailed =
        "r05_metalfx_spatial_linear_output_texture_allocation_failed"
    case commandBufferCreationFailed = "r05_metalfx_spatial_command_buffer_creation_failed"
    case nv12ToLinearEncodingFailed = "r05_metalfx_spatial_nv12_to_linear_encoding_failed"
    case scalerEncodingFailed = "r05_metalfx_spatial_scaler_encoding_failed"
    case linearToNV12EncodingFailed = "r05_metalfx_spatial_linear_to_nv12_encoding_failed"
    case alphaInputTextureAllocationFailed =
        "r05_metalfx_spatial_alpha_input_texture_allocation_failed"
    case alphaOutputTextureAllocationFailed =
        "r05_metalfx_spatial_alpha_output_texture_allocation_failed"
    case alphaToLinearEncodingFailed =
        "r05_metalfx_spatial_alpha_to_linear_encoding_failed"
    case alphaScalerEncodingFailed =
        "r05_metalfx_spatial_alpha_scaler_encoding_failed"
    case linearToAlphaEncodingFailed =
        "r05_metalfx_spatial_linear_to_alpha_encoding_failed"
    case alphaOutputFinalizationFailed =
        "r05_metalfx_spatial_alpha_output_finalization_failed"
    case commandExecutionFailed = "r05_metalfx_spatial_command_execution_failed"
    case outputFinalizationFailed = "r05_metalfx_spatial_output_finalization_failed"
    case publicationFailed = "r05_metalfx_spatial_publication_failed"
}

enum R05MetalFXSpatialCancellationReason: String, CaseIterable, Equatable, Sendable {
    case beforeCommit = "r05_metalfx_spatial_cancelled_before_commit"
    case afterCommit = "r05_metalfx_spatial_cancelled_after_commit"
}

struct R05MetalFXSpatialDriverProcessed: @unchecked Sendable {
    let route: R05MetalFXSpatialDriverRoute
    let destination: any R05MetalFXSpatialNV12Surface
}

enum R05MetalFXSpatialDriverOutcome: Sendable {
    case processed(R05MetalFXSpatialDriverProcessed)
    case rejected(R05MetalFXSpatialDriverRejectionReason)
    case unsupported(R05MetalFXSpatialDriverUnsupportedReason)
    case unavailable(R05MetalFXSpatialDriverUnavailableReason)
    case failed(R05MetalFXSpatialDriverFailureReason)
    case cancelled(R05MetalFXSpatialCancellationReason)
}

struct R05MetalFXSpatialDriverCancellation: Sendable {
    let isCancelled: @Sendable () -> Bool

    static let never = R05MetalFXSpatialDriverCancellation(isCancelled: { false })
}

protocol R05MetalFXSpatialNV12Surface: AnyObject, Sendable {
    var dimensions: R05MetalFXSpatialDriverDimensions { get }
}

private enum R05MetalFXSpatialSurfaceConversionMode: Equatable, Sendable {
    case color
    case alphaGuide
}

final class R05MetalFXSpatialCVPixelBufferSurface: R05MetalFXSpatialNV12Surface,
    @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let videoFormat: MediaVideoFormat
    let dimensions: R05MetalFXSpatialDriverDimensions
    fileprivate let conversionMode: R05MetalFXSpatialSurfaceConversionMode

    init(
        pixelBuffer: CVPixelBuffer,
        videoFormat: MediaVideoFormat = .sdrBT709
    ) {
        self.pixelBuffer = pixelBuffer
        self.videoFormat = videoFormat
        conversionMode = .color
        self.dimensions = R05MetalFXSpatialDriverDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }

    fileprivate init(
        pixelBuffer: CVPixelBuffer,
        videoFormat: MediaVideoFormat,
        conversionMode: R05MetalFXSpatialSurfaceConversionMode
    ) {
        self.pixelBuffer = pixelBuffer
        self.videoFormat = videoFormat
        self.conversionMode = conversionMode
        dimensions = R05MetalFXSpatialDriverDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }
}

struct R05MetalFXSpatialDriverRequest: @unchecked Sendable {
    let route: R05MetalFXSpatialDriverRoute
    let source: any R05MetalFXSpatialNV12Surface
    let destination: any R05MetalFXSpatialNV12Surface
    let retainedResources: [AnyObject]
    let cancellation: R05MetalFXSpatialDriverCancellation
    let publish: @Sendable () throws -> Void

    init(
        route: R05MetalFXSpatialDriverRoute,
        source: any R05MetalFXSpatialNV12Surface,
        destination: any R05MetalFXSpatialNV12Surface,
        retainedResources: [AnyObject] = [],
        cancellation: R05MetalFXSpatialDriverCancellation = .never,
        publish: @escaping @Sendable () throws -> Void
    ) {
        self.route = route
        self.source = source
        self.destination = destination
        self.retainedResources = retainedResources
        self.cancellation = cancellation
        self.publish = publish
    }
}

struct R05MetalFXAdaptiveSpatialDriverProcessed: @unchecked Sendable {
    let sourceDimensions: R05MetalFXSpatialDriverDimensions
    let targetDimensions: R05MetalFXSpatialDriverDimensions
    let destination: any R05MetalFXSpatialNV12Surface
}

enum R05MetalFXAdaptiveSpatialDriverOutcome: Sendable {
    case processed(R05MetalFXAdaptiveSpatialDriverProcessed)
    case rejected(R05MetalFXSpatialDriverRejectionReason)
    case unsupported(R05MetalFXSpatialDriverUnsupportedReason)
    case unavailable(R05MetalFXSpatialDriverUnavailableReason)
    case failed(R05MetalFXSpatialDriverFailureReason)
    case cancelled(R05MetalFXSpatialCancellationReason)
}

struct R05MetalFXAdaptiveSpatialDriverRequest: @unchecked Sendable {
    let sourceDimensions: R05MetalFXSpatialDriverDimensions
    let targetDimensions: R05MetalFXSpatialDriverDimensions
    let source: any R05MetalFXSpatialNV12Surface
    let destination: any R05MetalFXSpatialNV12Surface
    let retainedResources: [AnyObject]
    let cancellation: R05MetalFXSpatialDriverCancellation
    let colorMode: R05MetalFXSpatialDriverColorMode
    let publish: @Sendable () throws -> Void

    init(
        sourceDimensions: R05MetalFXSpatialDriverDimensions,
        targetDimensions: R05MetalFXSpatialDriverDimensions,
        source: any R05MetalFXSpatialNV12Surface,
        destination: any R05MetalFXSpatialNV12Surface,
        retainedResources: [AnyObject] = [],
        cancellation: R05MetalFXSpatialDriverCancellation = .never,
        colorMode: R05MetalFXSpatialDriverColorMode = .linear,
        publish: @escaping @Sendable () throws -> Void
    ) {
        self.sourceDimensions = sourceDimensions
        self.targetDimensions = targetDimensions
        self.source = source
        self.destination = destination
        self.retainedResources = retainedResources
        self.cancellation = cancellation
        self.colorMode = colorMode
        self.publish = publish
    }
}

protocol R05MetalFXAdaptiveSpatialDriving: AnyObject, Sendable {
    func process(
        _ request: R05MetalFXAdaptiveSpatialDriverRequest
    ) async -> R05MetalFXAdaptiveSpatialDriverOutcome
}

enum R05MetalFXSpatialDriverColorMode: String, Equatable, Sendable {
    case linear
    case hdr
}

struct R05MetalFXSpatialScalerConfiguration: Equatable, Sendable {
    let inputDimensions: R05MetalFXSpatialDriverDimensions
    let outputDimensions: R05MetalFXSpatialDriverDimensions
    let colorTextureFormat: MTLPixelFormat
    let outputTextureFormat: MTLPixelFormat
    let colorMode: R05MetalFXSpatialDriverColorMode
}

struct R05MetalFXSpatialTextureDescriptor: Equatable, Sendable {
    let dimensions: R05MetalFXSpatialDriverDimensions
    let pixelFormat: MTLPixelFormat
    let usage: MTLTextureUsage
    let storageMode: MTLStorageMode
}

protocol R05MetalFXSpatialTexture: AnyObject, Sendable {
    var descriptor: R05MetalFXSpatialTextureDescriptor { get }
}

protocol R05MetalFXSpatialCommandBuffer: AnyObject, Sendable {}

protocol R05MetalFXSpatialScaler: AnyObject, Sendable {
    var colorTextureUsage: MTLTextureUsage { get }
    var outputTextureUsage: MTLTextureUsage { get }

    func encode(
        colorTexture: any R05MetalFXSpatialTexture,
        outputTexture: any R05MetalFXSpatialTexture,
        inputContentDimensions: R05MetalFXSpatialDriverDimensions,
        commandBuffer: any R05MetalFXSpatialCommandBuffer
    ) throws
}

protocol R05MetalFXSpatialScalerCreating: Sendable {
    func supportsDevice() -> Bool
    func makeScaler(
        configuration: R05MetalFXSpatialScalerConfiguration
    ) -> (any R05MetalFXSpatialScaler)?
}

protocol R05MetalFXSpatialTextureAllocating: Sendable {
    func makeTexture(
        descriptor: R05MetalFXSpatialTextureDescriptor
    ) -> (any R05MetalFXSpatialTexture)?
}

protocol R05MetalFXSpatialCommandBufferCreating: Sendable {
    func makeCommandBuffer(label: String) -> (any R05MetalFXSpatialCommandBuffer)?
}

protocol R05MetalFXSpatialColorConverting: Sendable {
    func encodeNV12ToLinear(
        source: any R05MetalFXSpatialNV12Surface,
        destination: any R05MetalFXSpatialTexture,
        commandBuffer: any R05MetalFXSpatialCommandBuffer
    ) throws -> [AnyObject]

    func encodeLinearToNV12(
        source: any R05MetalFXSpatialTexture,
        destination: any R05MetalFXSpatialNV12Surface,
        commandBuffer: any R05MetalFXSpatialCommandBuffer
    ) throws -> R05MetalFXSpatialPendingOutputConversion
}

struct R05MetalFXSpatialPendingOutputConversion: @unchecked Sendable {
    let retainedResources: [AnyObject]
    let finalize: @Sendable () throws -> Void

    init(
        retainedResources: [AnyObject],
        finalize: @escaping @Sendable () throws -> Void
    ) {
        self.retainedResources = retainedResources
        self.finalize = finalize
    }
}

final class R05MetalFXSpatialRetainedResources: @unchecked Sendable {
    let objects: [AnyObject]

    init(_ objects: [AnyObject]) {
        self.objects = objects
    }

    var count: Int { objects.count }
}

protocol R05MetalFXSpatialCommandCompleting: Sendable {
    func commitAndWait(
        commandBuffer: any R05MetalFXSpatialCommandBuffer,
        retaining resources: R05MetalFXSpatialRetainedResources
    ) async throws
}

private enum R05MetalFXSpatialAdapterError: Error {
    case incompatibleResource
    case commandExecutionFailed
}

final class R05DefaultMetalFXSpatialScalerFactory: R05MetalFXSpatialScalerCreating,
    @unchecked Sendable {
    private let device: any MTLDevice

    init(device: any MTLDevice) {
        self.device = device
    }

    func supportsDevice() -> Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    func makeScaler(
        configuration: R05MetalFXSpatialScalerConfiguration
    ) -> (any R05MetalFXSpatialScaler)? {
        guard configuration.colorTextureFormat == .rgba16Float,
              configuration.outputTextureFormat == .rgba16Float else {
            return nil
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = configuration.colorTextureFormat
        descriptor.outputTextureFormat = configuration.outputTextureFormat
        descriptor.inputWidth = configuration.inputDimensions.width
        descriptor.inputHeight = configuration.inputDimensions.height
        descriptor.outputWidth = configuration.outputDimensions.width
        descriptor.outputHeight = configuration.outputDimensions.height
        switch configuration.colorMode {
        case .linear:
            descriptor.colorProcessingMode = .linear
        case .hdr:
            descriptor.colorProcessingMode = .hdr
        }
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            return nil
        }
        return R05DefaultMetalFXSpatialScaler(
            scaler: scaler,
            configuration: configuration
        )
    }
}

private final class R05DefaultMetalFXSpatialScaler: R05MetalFXSpatialScaler,
    @unchecked Sendable {
    private let scaler: any MTLFXSpatialScaler
    private let configuration: R05MetalFXSpatialScalerConfiguration

    init(
        scaler: any MTLFXSpatialScaler,
        configuration: R05MetalFXSpatialScalerConfiguration
    ) {
        self.scaler = scaler
        self.configuration = configuration
    }

    var colorTextureUsage: MTLTextureUsage { scaler.colorTextureUsage }
    var outputTextureUsage: MTLTextureUsage { scaler.outputTextureUsage }

    func encode(
        colorTexture: any R05MetalFXSpatialTexture,
        outputTexture: any R05MetalFXSpatialTexture,
        inputContentDimensions: R05MetalFXSpatialDriverDimensions,
        commandBuffer: any R05MetalFXSpatialCommandBuffer
    ) throws {
        guard let colorTexture = colorTexture as? R05MetalFXSpatialMetalTexture,
              let outputTexture = outputTexture as? R05MetalFXSpatialMetalTexture,
              let commandBuffer = commandBuffer as? R05MetalFXSpatialMetalCommandBuffer,
              inputContentDimensions == configuration.inputDimensions,
              colorTexture.descriptor.dimensions == configuration.inputDimensions,
              outputTexture.descriptor.dimensions == configuration.outputDimensions,
              colorTexture.descriptor.pixelFormat == configuration.colorTextureFormat,
              outputTexture.descriptor.pixelFormat == configuration.outputTextureFormat,
              outputTexture.descriptor.storageMode == .private,
              colorTexture.descriptor.usage.containsAll(colorTextureUsage),
              outputTexture.descriptor.usage.containsAll(outputTextureUsage) else {
            throw R05MetalFXSpatialAdapterError.incompatibleResource
        }
        scaler.inputContentWidth = inputContentDimensions.width
        scaler.inputContentHeight = inputContentDimensions.height
        scaler.colorTexture = colorTexture.texture
        scaler.outputTexture = outputTexture.texture
        scaler.encode(commandBuffer: commandBuffer.commandBuffer)
    }
}

final class R05DefaultMetalFXSpatialTextureAllocator: R05MetalFXSpatialTextureAllocating,
    @unchecked Sendable {
    private let device: any MTLDevice

    init(device: any MTLDevice) {
        self.device = device
    }

    func makeTexture(
        descriptor: R05MetalFXSpatialTextureDescriptor
    ) -> (any R05MetalFXSpatialTexture)? {
        let metalDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: descriptor.pixelFormat,
            width: descriptor.dimensions.width,
            height: descriptor.dimensions.height,
            mipmapped: false
        )
        metalDescriptor.usage = descriptor.usage
        metalDescriptor.storageMode = descriptor.storageMode
        guard let texture = device.makeTexture(descriptor: metalDescriptor) else {
            return nil
        }
        return R05MetalFXSpatialMetalTexture(
            texture: texture,
            descriptor: descriptor
        )
    }
}

private final class R05MetalFXSpatialMetalTexture: R05MetalFXSpatialTexture,
    @unchecked Sendable {
    let texture: any MTLTexture
    let descriptor: R05MetalFXSpatialTextureDescriptor

    init(
        texture: any MTLTexture,
        descriptor: R05MetalFXSpatialTextureDescriptor
    ) {
        self.texture = texture
        self.descriptor = descriptor
    }
}

final class R05MetalFXCommandBufferFactory:
    R05MetalFXSpatialCommandBufferCreating, @unchecked Sendable {
    private let commandQueue: any MTLCommandQueue

    init(commandQueue: any MTLCommandQueue) {
        self.commandQueue = commandQueue
    }

    func makeCommandBuffer(label: String) -> (any R05MetalFXSpatialCommandBuffer)? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        commandBuffer.label = label
        return R05MetalFXSpatialMetalCommandBuffer(commandBuffer: commandBuffer)
    }
}

private final class R05MetalFXSpatialMetalCommandBuffer: R05MetalFXSpatialCommandBuffer,
    @unchecked Sendable {
    let commandBuffer: any MTLCommandBuffer

    init(commandBuffer: any MTLCommandBuffer) {
        self.commandBuffer = commandBuffer
    }
}

enum R05MetalFXNativeColorError: Error, Equatable, Sendable {
    case incompatibleResource
    case stagingTextureAllocationFailed
    case blitEncoderCreationFailed
    case arithmeticOverflow
    case emptyLinearStorage
}

/// The production conversion bridge uses CPU-visible shared staging textures.
/// It never reads or writes a private texture from the CPU. The output staging
/// texture is read only by the pending finalizer after command completion.
final class R05DefaultMetalFXSpatialColorConverter: R05MetalFXSpatialColorConverting,
    @unchecked Sendable {
    private static let componentCount = 4

    private let device: any MTLDevice

    init(device: any MTLDevice) {
        self.device = device
    }

    func encodeNV12ToLinear(
        source: any R05MetalFXSpatialNV12Surface,
        destination: any R05MetalFXSpatialTexture,
        commandBuffer: any R05MetalFXSpatialCommandBuffer
    ) throws -> [AnyObject] {
        guard let source = source as? R05MetalFXSpatialCVPixelBufferSurface,
              let destination = destination as? R05MetalFXSpatialMetalTexture,
              let commandBuffer = commandBuffer as? R05MetalFXSpatialMetalCommandBuffer,
              source.dimensions == destination.descriptor.dimensions,
              destination.descriptor.pixelFormat == .rgba16Float,
              destination.descriptor.storageMode == .private else {
            throw R05MetalFXNativeColorError.incompatibleResource
        }
        let linear: R05LinearRGBA16FloatFrame
        if source.conversionMode == .alphaGuide {
            linear = try R05MetalFXFormatColorBridge.decodeAlphaGuide(
                pixelBuffer: source.pixelBuffer,
                format: source.videoFormat
            )
        } else if source.videoFormat == .sdrBT709 {
            linear = try R05MetalFXColorBridge.decode(
                pixelBuffer: source.pixelBuffer
            )
        } else {
            linear = try R05MetalFXFormatColorBridge.decode(
                pixelBuffer: source.pixelBuffer,
                format: source.videoFormat
            )
        }
        let staging = try makeSharedStagingTexture(
            dimensions: source.dimensions,
            cpuCacheMode: .writeCombined
        )
        let bytesPerRow = try Self.rgba16FloatBytesPerRow(
            width: source.dimensions.width
        )
        guard !linear.components.isEmpty else {
            throw R05MetalFXNativeColorError.emptyLinearStorage
        }
        linear.components.withUnsafeBytes { bytes in
            staging.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    source.dimensions.width,
                    source.dimensions.height
                ),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        guard let blit = commandBuffer.commandBuffer.makeBlitCommandEncoder() else {
            throw R05MetalFXNativeColorError.blitEncoderCreationFailed
        }
        blit.label = "r05.metalfx.nv12-to-linear.upload"
        blit.copy(
            from: staging,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: source.dimensions.width,
                height: source.dimensions.height,
                depth: 1
            ),
            to: destination.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        return [staging as AnyObject]
    }

    func encodeLinearToNV12(
        source: any R05MetalFXSpatialTexture,
        destination: any R05MetalFXSpatialNV12Surface,
        commandBuffer: any R05MetalFXSpatialCommandBuffer
    ) throws -> R05MetalFXSpatialPendingOutputConversion {
        guard let source = source as? R05MetalFXSpatialMetalTexture,
              let destination = destination as? R05MetalFXSpatialCVPixelBufferSurface,
              let commandBuffer = commandBuffer as? R05MetalFXSpatialMetalCommandBuffer,
              source.descriptor.dimensions == destination.dimensions,
              source.descriptor.pixelFormat == .rgba16Float,
              source.descriptor.storageMode == .private else {
            throw R05MetalFXNativeColorError.incompatibleResource
        }
        let dimensions = destination.dimensions
        let staging = try makeSharedStagingTexture(
            dimensions: dimensions,
            cpuCacheMode: .defaultCache
        )
        guard let blit = commandBuffer.commandBuffer.makeBlitCommandEncoder() else {
            throw R05MetalFXNativeColorError.blitEncoderCreationFailed
        }
        blit.label = "r05.metalfx.linear-to-nv12.readback"
        blit.copy(
            from: source.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: dimensions.width,
                height: dimensions.height,
                depth: 1
            ),
            to: staging,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        return R05MetalFXSpatialPendingOutputConversion(
            retainedResources: [staging as AnyObject],
            finalize: {
                let bytesPerRow = try Self.rgba16FloatBytesPerRow(
                    width: dimensions.width
                )
                let componentCount = try Self.rgba16FloatComponentCount(
                    dimensions: dimensions
                )
                var components = [Float16](repeating: 0, count: componentCount)
                components.withUnsafeMutableBytes { bytes in
                    staging.getBytes(
                        bytes.baseAddress!,
                        bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(
                            0,
                            0,
                            dimensions.width,
                            dimensions.height
                        ),
                        mipmapLevel: 0
                    )
                }
                let linear = try R05LinearRGBA16FloatFrame(
                    width: dimensions.width,
                    height: dimensions.height,
                    components: components,
                    componentsPerRow: bytesPerRow / MemoryLayout<Float16>.stride
                )
                if destination.conversionMode == .alphaGuide {
                    try R05MetalFXFormatColorBridge.encodeAlphaGuide(
                        linear,
                        into: destination.pixelBuffer,
                        format: destination.videoFormat
                    )
                } else if destination.videoFormat == .sdrBT709 {
                    try R05MetalFXColorBridge.encodeClippingFiniteRGB(
                        linear,
                        into: destination.pixelBuffer
                    )
                } else {
                    try R05MetalFXFormatColorBridge.encodeClippingFiniteRGB(
                        linear,
                        into: destination.pixelBuffer,
                        format: destination.videoFormat
                    )
                }
            }
        )
    }

    private func makeSharedStagingTexture(
        dimensions: R05MetalFXSpatialDriverDimensions,
        cpuCacheMode: MTLCPUCacheMode
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: dimensions.width,
            height: dimensions.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.cpuCacheMode = cpuCacheMode
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw R05MetalFXNativeColorError
                .stagingTextureAllocationFailed
        }
        return texture
    }

    private static func rgba16FloatBytesPerRow(width: Int) throws -> Int {
        let components = width.multipliedReportingOverflow(by: componentCount)
        let bytes = components.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<Float16>.stride
        )
        guard !components.overflow, !bytes.overflow else {
            throw R05MetalFXNativeColorError.arithmeticOverflow
        }
        return bytes.partialValue
    }

    private static func rgba16FloatComponentCount(
        dimensions: R05MetalFXSpatialDriverDimensions
    ) throws -> Int {
        let pixels = dimensions.width.multipliedReportingOverflow(
            by: dimensions.height
        )
        let components = pixels.partialValue.multipliedReportingOverflow(
            by: componentCount
        )
        guard !pixels.overflow, !components.overflow else {
            throw R05MetalFXNativeColorError.arithmeticOverflow
        }
        return components.partialValue
    }
}

enum R05MetalFXFormatColorBridgeError: Error, Equatable, Sendable {
    case unsupportedStorage(MediaVideoPixelStorage)
    case missingComponent(R13PixelPlaneRole, Int)
    case pixelBufferLockFailed(destination: Bool, status: CVReturn)
    case dimensionMismatch(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case nonFiniteLinearComponent(Int)
}

// Converts every registered media storage contract to and from the RGBA16F
// texture contract accepted by MetalFX Spatial. RGB is linearized according
// to the declared transfer function; BT.709 and BT.2020 YCbCr retain their
// own matrix coefficients; alpha is carried in the fourth texture channel.
// Destination samples are requantized directly into the original layout and
// legal code range. No secondary scaling implementation participates.
// The conversion operations are co-located so every storage representation
// shares one auditable transfer, range, and alpha contract.
// swiftlint:disable:next type_body_length
enum R05MetalFXFormatColorBridge {
    private struct ComponentLocation {
        let planeIndex: Int
        let componentIndex: Int
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    private struct YCbCr {
        let luma: Double
        let cb: Double
        let cr: Double
    }

    private struct MatrixCoefficients {
        let red: Double
        let blue: Double

        var green: Double { 1 - red - blue }
    }

    private static let hlgA = 0.178_832_77
    private static let hlgB = 1 - 4 * hlgA
    private static let hlgC = 0.5 - hlgA * log(4 * hlgA)

    static func decode(
        pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws -> R05LinearRGBA16FloatFrame {
        try format.validate(pixelBuffer: pixelBuffer)
        let layout = try R13PixelLayoutRegistry.layout(
            for: format.pixelStorage.pixelFormat
        )
        try layout.validate(pixelBuffer)
        try R13PixelLayoutProcessor.validateStoredCodes(pixelBuffer)

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw R05MetalFXFormatColorBridgeError.pixelBufferLockFailed(
                destination: false,
                status: lockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let componentCount = try checkedComponentCount(
            width: width,
            height: height
        )
        var components = [Float16](repeating: 0, count: componentCount)
        let alphaLocation = try alphaLocation(
            layout: layout,
            required: format.hasAlpha
        )

        for row in 0..<height {
            for column in 0..<width {
                let encoded = try encodedRGB(
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    format: format,
                    column: column,
                    row: row
                )
                let alpha = try alphaLocation.map {
                    try normalizedComponent(
                        pixelBuffer: pixelBuffer,
                        layout: layout,
                        location: $0,
                        column: column,
                        row: row
                    )
                } ?? 1
                let index = (row * width + column) * 4
                components[index] = Float16(
                    linearized(encoded.red, transfer: format.transferFunction)
                )
                components[index + 1] = Float16(
                    linearized(encoded.green, transfer: format.transferFunction)
                )
                components[index + 2] = Float16(
                    linearized(encoded.blue, transfer: format.transferFunction)
                )
                components[index + 3] = Float16(clampUnit(alpha))
            }
        }
        return try R05LinearRGBA16FloatFrame(
            width: width,
            height: height,
            components: components
        )
    }

    static func decodeAlphaGuide(
        pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws -> R05LinearRGBA16FloatFrame {
        try format.validate(pixelBuffer: pixelBuffer)
        let layout = try R13PixelLayoutRegistry.layout(
            for: format.pixelStorage.pixelFormat
        )
        try layout.validate(pixelBuffer)
        try R13PixelLayoutProcessor.validateStoredCodes(pixelBuffer)
        let alpha = try alphaLocation(layout: layout, required: true)
        guard let alpha else {
            throw R05MetalFXFormatColorBridgeError.missingComponent(.alpha, 0)
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw R05MetalFXFormatColorBridgeError.pixelBufferLockFailed(
                destination: false,
                status: lockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var components = [Float16](
            repeating: 0,
            count: try checkedComponentCount(width: width, height: height)
        )
        for row in 0..<height {
            for column in 0..<width {
                let value = try normalizedComponent(
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: alpha,
                    column: column,
                    row: row
                )
                let index = (row * width + column) * 4
                let half = Float16(value)
                components[index] = half
                components[index + 1] = half
                components[index + 2] = half
                components[index + 3] = 1
            }
        }
        return try R05LinearRGBA16FloatFrame(
            width: width,
            height: height,
            components: components
        )
    }

    static func encodeClippingFiniteRGB(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws {
        try format.validate(pixelBuffer: pixelBuffer)
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard source.width == actualWidth,
              source.height == actualHeight else {
            throw R05MetalFXFormatColorBridgeError.dimensionMismatch(
                expectedWidth: source.width,
                expectedHeight: source.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        let layout = try R13PixelLayoutRegistry.layout(
            for: format.pixelStorage.pixelFormat
        )
        try layout.validate(pixelBuffer)
        try validateFinite(source)

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R05MetalFXFormatColorBridgeError.pixelBufferLockFailed(
                destination: true,
                status: lockStatus
            )
        }
        do {
            if format.pixelStorage.usesYCbCr {
                try encodeYCbCrLocked(
                    source,
                    into: pixelBuffer,
                    layout: layout,
                    format: format
                )
            } else {
                try encodeRGBLocked(
                    source,
                    into: pixelBuffer,
                    layout: layout,
                    format: format
                )
            }
        } catch {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw error
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        try R13PixelLayoutProcessor.enforceCodeBounds(pixelBuffer)
        try R13PixelLayoutProcessor.validateStoredCodes(pixelBuffer)
    }

    static func encodeAlphaGuide(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws {
        try format.validate(pixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard source.width == width, source.height == height else {
            throw R05MetalFXFormatColorBridgeError.dimensionMismatch(
                expectedWidth: source.width,
                expectedHeight: source.height,
                actualWidth: width,
                actualHeight: height
            )
        }
        try validateFinite(source)
        let layout = try R13PixelLayoutRegistry.layout(
            for: format.pixelStorage.pixelFormat
        )
        try layout.validate(pixelBuffer)
        let alpha = try alphaLocation(layout: layout, required: true)
        guard let alpha else {
            throw R05MetalFXFormatColorBridgeError.missingComponent(.alpha, 0)
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R05MetalFXFormatColorBridgeError.pixelBufferLockFailed(
                destination: true,
                status: lockStatus
            )
        }
        do {
            for row in 0..<height {
                for column in 0..<width {
                    let index = row * source.componentsPerRow + column * 4
                    let value = (
                        Double(source.components[index])
                            + Double(source.components[index + 1])
                            + Double(source.components[index + 2])
                    ) / 3
                    try writeNormalized(
                        value,
                        pixelBuffer: pixelBuffer,
                        layout: layout,
                        location: alpha,
                        column: column,
                        row: row
                    )
                }
            }
        } catch {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw error
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            pixelBuffer,
            format: format
        )
        try R13PixelLayoutProcessor.enforceCodeBounds(pixelBuffer)
        try R13PixelLayoutProcessor.validateStoredCodes(pixelBuffer)
    }

    private static func encodedRGB(
        pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        format: MediaVideoFormat,
        column: Int,
        row: Int
    ) throws -> RGB {
        if !format.pixelStorage.usesYCbCr {
            guard layout.planes.count == 1,
                  layout.planes[0].role == .packedBGRA else {
                throw R05MetalFXFormatColorBridgeError.unsupportedStorage(
                    format.pixelStorage
                )
            }
            return RGB(
                red: try normalizedComponent(
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: ComponentLocation(planeIndex: 0, componentIndex: 2),
                    column: column,
                    row: row
                ),
                green: try normalizedComponent(
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: ComponentLocation(planeIndex: 0, componentIndex: 1),
                    column: column,
                    row: row
                ),
                blue: try normalizedComponent(
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: ComponentLocation(planeIndex: 0, componentIndex: 0),
                    column: column,
                    row: row
                )
            )
        }

        let luma = try requiredLocation(
            layout: layout,
            role: .luma,
            packedRole: .packedAYCbCr,
            packedComponent: 1
        )
        let cb = try requiredLocation(
            layout: layout,
            role: .interleavedChroma,
            packedRole: .packedAYCbCr,
            packedComponent: 2
        )
        let cr = ComponentLocation(
            planeIndex: cb.planeIndex,
            componentIndex: cb.componentIndex + 1
        )
        let lumaValue = try normalizedComponent(
            pixelBuffer: pixelBuffer,
            layout: layout,
            location: luma,
            column: column,
            row: row
        )
        let normalizedCb = try normalizedComponent(
            pixelBuffer: pixelBuffer,
            layout: layout,
            location: cb,
            column: column,
            row: row
        ) - 0.5
        let normalizedCr = try normalizedComponent(
            pixelBuffer: pixelBuffer,
            layout: layout,
            location: cr,
            column: column,
            row: row
        ) - 0.5
        let matrix = coefficients(for: format.colorPrimaries)
        return RGB(
            red: clampUnit(
                lumaValue + 2 * (1 - matrix.red) * normalizedCr
            ),
            green: clampUnit(
                lumaValue
                    - 2 * matrix.blue * (1 - matrix.blue)
                        / matrix.green * normalizedCb
                    - 2 * matrix.red * (1 - matrix.red)
                        / matrix.green * normalizedCr
            ),
            blue: clampUnit(
                lumaValue + 2 * (1 - matrix.blue) * normalizedCb
            )
        )
    }

    private static func encodeRGBLocked(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        format: MediaVideoFormat
    ) throws {
        guard layout.planes.count == 1,
              layout.planes[0].role == .packedBGRA else {
            throw R05MetalFXFormatColorBridgeError.unsupportedStorage(
                format.pixelStorage
            )
        }
        for row in 0..<source.height {
            for column in 0..<source.width {
                let pixel = try encodedPixel(
                    source,
                    format: format,
                    column: column,
                    row: row
                )
                try writeNormalized(
                    pixel.rgb.blue,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: ComponentLocation(planeIndex: 0, componentIndex: 0),
                    column: column,
                    row: row
                )
                try writeNormalized(
                    pixel.rgb.green,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: ComponentLocation(planeIndex: 0, componentIndex: 1),
                    column: column,
                    row: row
                )
                try writeNormalized(
                    pixel.rgb.red,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: ComponentLocation(planeIndex: 0, componentIndex: 2),
                    column: column,
                    row: row
                )
                try writeNormalized(
                    pixel.alpha,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: ComponentLocation(planeIndex: 0, componentIndex: 3),
                    column: column,
                    row: row
                )
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private static func encodeYCbCrLocked(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        format: MediaVideoFormat
    ) throws {
        if layout.planes.count == 1,
           layout.planes[0].role == .packedAYCbCr {
            try encodePackedAYCbCrLocked(
                source,
                into: pixelBuffer,
                layout: layout,
                format: format
            )
            return
        }

        let luma = try requiredLocation(
            layout: layout,
            role: .luma,
            packedRole: .packedAYCbCr,
            packedComponent: 1
        )
        let cb = try requiredLocation(
            layout: layout,
            role: .interleavedChroma,
            packedRole: .packedAYCbCr,
            packedComponent: 2
        )
        let cr = ComponentLocation(
            planeIndex: cb.planeIndex,
            componentIndex: cb.componentIndex + 1
        )
        for row in 0..<source.height {
            for column in 0..<source.width {
                let pixel = try encodedPixel(
                    source,
                    format: format,
                    column: column,
                    row: row
                )
                let ycbcr = yCbCr(
                    pixel.rgb,
                    primaries: format.colorPrimaries
                )
                try writeNormalized(
                    ycbcr.luma,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: luma,
                    column: column,
                    row: row
                )
            }
        }

        let chromaPlane = layout.planes[cb.planeIndex]
        let chromaWidth = chromaPlane.width(for: source.width)
        let chromaHeight = chromaPlane.height(for: source.height)
        for chromaRow in 0..<chromaHeight {
            for chromaColumn in 0..<chromaWidth {
                var cbSum = 0.0
                var crSum = 0.0
                var count = 0
                let firstRow = chromaRow * chromaPlane.heightDivisor
                let firstColumn = chromaColumn * chromaPlane.widthDivisor
                for row in firstRow..<min(
                    firstRow + chromaPlane.heightDivisor,
                    source.height
                ) {
                    for column in firstColumn..<min(
                        firstColumn + chromaPlane.widthDivisor,
                        source.width
                    ) {
                        let pixel = try encodedPixel(
                            source,
                            format: format,
                            column: column,
                            row: row
                        )
                        let ycbcr = yCbCr(
                            pixel.rgb,
                            primaries: format.colorPrimaries
                        )
                        cbSum += ycbcr.cb
                        crSum += ycbcr.cr
                        count += 1
                    }
                }
                let sampleCount = Double(count)
                try writeNormalizedAtPlaneCoordinate(
                    cbSum / sampleCount + 0.5,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: cb,
                    planeColumn: chromaColumn,
                    planeRow: chromaRow
                )
                try writeNormalizedAtPlaneCoordinate(
                    crSum / sampleCount + 0.5,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: cr,
                    planeColumn: chromaColumn,
                    planeRow: chromaRow
                )
            }
        }

        if let alpha = try alphaLocation(layout: layout, required: format.hasAlpha) {
            for row in 0..<source.height {
                for column in 0..<source.width {
                    let pixel = try encodedPixel(
                        source,
                        format: format,
                        column: column,
                        row: row
                    )
                    try writeNormalized(
                        pixel.alpha,
                        pixelBuffer: pixelBuffer,
                        layout: layout,
                        location: alpha,
                        column: column,
                        row: row
                    )
                }
            }
        }
    }

    private static func encodePackedAYCbCrLocked(
        _ source: R05LinearRGBA16FloatFrame,
        into pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        format: MediaVideoFormat
    ) throws {
        let locations = (0..<4).map {
            ComponentLocation(planeIndex: 0, componentIndex: $0)
        }
        for row in 0..<source.height {
            for column in 0..<source.width {
                let pixel = try encodedPixel(
                    source,
                    format: format,
                    column: column,
                    row: row
                )
                let value = yCbCr(
                    pixel.rgb,
                    primaries: format.colorPrimaries
                )
                let normalized = [
                    pixel.alpha,
                    value.luma,
                    value.cb + 0.5,
                    value.cr + 0.5
                ]
                for component in 0..<4 {
                    try writeNormalized(
                        normalized[component],
                        pixelBuffer: pixelBuffer,
                        layout: layout,
                        location: locations[component],
                        column: column,
                        row: row
                    )
                }
            }
        }
    }

    private static func encodedPixel(
        _ source: R05LinearRGBA16FloatFrame,
        format: MediaVideoFormat,
        column: Int,
        row: Int
    ) throws -> (rgb: RGB, alpha: Double) {
        let index = row * source.componentsPerRow + column * 4
        let red = Double(source.components[index])
        let green = Double(source.components[index + 1])
        let blue = Double(source.components[index + 2])
        let alpha = Double(source.components[index + 3])
        for (offset, value) in [red, green, blue, alpha].enumerated()
        where !value.isFinite {
            throw R05MetalFXFormatColorBridgeError
                .nonFiniteLinearComponent(index + offset)
        }
        return (
            RGB(
                red: encoded(clampUnit(red), transfer: format.transferFunction),
                green: encoded(clampUnit(green), transfer: format.transferFunction),
                blue: encoded(clampUnit(blue), transfer: format.transferFunction)
            ),
            format.hasAlpha ? clampUnit(alpha) : 1
        )
    }

    private static func yCbCr(
        _ rgb: RGB,
        primaries: MediaVideoColorPrimaries
    ) -> YCbCr {
        let matrix = coefficients(for: primaries)
        let luma = matrix.red * rgb.red
            + matrix.green * rgb.green
            + matrix.blue * rgb.blue
        return YCbCr(
            luma: clampUnit(luma),
            cb: clampSignedHalf(
                (rgb.blue - luma) / (2 * (1 - matrix.blue))
            ),
            cr: clampSignedHalf(
                (rgb.red - luma) / (2 * (1 - matrix.red))
            )
        )
    }

    private static func requiredLocation(
        layout: R13PixelLayout,
        role: R13PixelPlaneRole,
        packedRole: R13PixelPlaneRole,
        packedComponent: Int
    ) throws -> ComponentLocation {
        if let planeIndex = layout.planes.firstIndex(where: { $0.role == role }) {
            return ComponentLocation(planeIndex: planeIndex, componentIndex: 0)
        }
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == packedRole }
        ) {
            return ComponentLocation(
                planeIndex: planeIndex,
                componentIndex: packedComponent
            )
        }
        throw R05MetalFXFormatColorBridgeError.missingComponent(role, 0)
    }

    private static func alphaLocation(
        layout: R13PixelLayout,
        required: Bool
    ) throws -> ComponentLocation? {
        guard required else { return nil }
        if let planeIndex = layout.planes.firstIndex(where: { $0.role == .alpha }) {
            return ComponentLocation(planeIndex: planeIndex, componentIndex: 0)
        }
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == .packedBGRA }
        ) {
            return ComponentLocation(planeIndex: planeIndex, componentIndex: 3)
        }
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == .packedAYCbCr }
        ) {
            return ComponentLocation(planeIndex: planeIndex, componentIndex: 0)
        }
        throw R05MetalFXFormatColorBridgeError.missingComponent(.alpha, 0)
    }

    private static func normalizedComponent(
        pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        location: ComponentLocation,
        column: Int,
        row: Int
    ) throws -> Double {
        let plane = layout.planes[location.planeIndex]
        return try normalizedComponentAtPlaneCoordinate(
            pixelBuffer: pixelBuffer,
            layout: layout,
            location: location,
            planeColumn: column / plane.widthDivisor,
            planeRow: row / plane.heightDivisor
        )
    }

    private static func normalizedComponentAtPlaneCoordinate(
        pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        location: ComponentLocation,
        planeColumn: Int,
        planeRow: Int
    ) throws -> Double {
        let plane = layout.planes[location.planeIndex]
        guard location.componentIndex < plane.componentsPerElement else {
            throw R05MetalFXFormatColorBridgeError.missingComponent(
                plane.role,
                location.componentIndex
            )
        }
        let base = try R13PixelBufferAccess.baseAddress(
            of: pixelBuffer,
            layout: layout,
            plane: location.planeIndex
        )
        let rowBytes = R13PixelBufferAccess.rowBytes(
            of: pixelBuffer,
            layout: layout,
            plane: location.planeIndex
        )
        let componentOffset =
            planeColumn * plane.componentsPerElement + location.componentIndex
        let stored: UInt16
        if plane.bytesPerComponent == 1 {
            stored = UInt16(
                base.advanced(by: planeRow * rowBytes)
                    .assumingMemoryBound(to: UInt8.self)[componentOffset]
            )
        } else {
            stored = base.advanced(by: planeRow * rowBytes)
                .assumingMemoryBound(to: UInt16.self)[componentOffset]
                >> UInt16(plane.storedCodeShift)
        }
        let bounds = plane.componentBounds[location.componentIndex]
        let span = Double(bounds.maximum - bounds.minimum)
        guard span > 0 else { return 0 }
        return clampUnit(
            (Double(stored) - Double(bounds.minimum)) / span
        )
    }

    private static func writeNormalized(
        _ normalized: Double,
        pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        location: ComponentLocation,
        column: Int,
        row: Int
    ) throws {
        let plane = layout.planes[location.planeIndex]
        try writeNormalizedAtPlaneCoordinate(
            normalized,
            pixelBuffer: pixelBuffer,
            layout: layout,
            location: location,
            planeColumn: column / plane.widthDivisor,
            planeRow: row / plane.heightDivisor
        )
    }

    private static func writeNormalizedAtPlaneCoordinate(
        _ normalized: Double,
        pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        location: ComponentLocation,
        planeColumn: Int,
        planeRow: Int
    ) throws {
        let plane = layout.planes[location.planeIndex]
        guard location.componentIndex < plane.componentsPerElement else {
            throw R05MetalFXFormatColorBridgeError.missingComponent(
                plane.role,
                location.componentIndex
            )
        }
        let bounds = plane.componentBounds[location.componentIndex]
        let span = Double(bounds.maximum - bounds.minimum)
        let code = UInt16(
            min(
                max(
                    Double(bounds.minimum) + clampUnit(normalized) * span,
                    Double(bounds.minimum)
                ),
                Double(bounds.maximum)
            ).rounded()
        )
        let stored = code << UInt16(plane.storedCodeShift)
        let base = try R13PixelBufferAccess.baseAddress(
            of: pixelBuffer,
            layout: layout,
            plane: location.planeIndex
        )
        let rowBytes = R13PixelBufferAccess.rowBytes(
            of: pixelBuffer,
            layout: layout,
            plane: location.planeIndex
        )
        let componentOffset =
            planeColumn * plane.componentsPerElement + location.componentIndex
        if plane.bytesPerComponent == 1 {
            base.advanced(by: planeRow * rowBytes)
                .assumingMemoryBound(to: UInt8.self)[componentOffset] = UInt8(code)
        } else {
            base.advanced(by: planeRow * rowBytes)
                .assumingMemoryBound(to: UInt16.self)[componentOffset] = stored
        }
    }

    private static func validateFinite(
        _ frame: R05LinearRGBA16FloatFrame
    ) throws {
        for row in 0..<frame.height {
            let first = row * frame.componentsPerRow
            let end = first + frame.width * 4
            for index in first..<end where !Double(frame.components[index]).isFinite {
                throw R05MetalFXFormatColorBridgeError
                    .nonFiniteLinearComponent(index)
            }
        }
    }

    private static func checkedComponentCount(
        width: Int,
        height: Int
    ) throws -> Int {
        let pixels = width.multipliedReportingOverflow(by: height)
        let components = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard width > 0,
              height > 0,
              !pixels.overflow,
              !components.overflow else {
            throw R05MetalFXColorBridgeError.invalidDimensions(
                width: width,
                height: height
            )
        }
        return components.partialValue
    }

    private static func coefficients(
        for primaries: MediaVideoColorPrimaries
    ) -> MatrixCoefficients {
        switch primaries {
        case .bt709:
            return MatrixCoefficients(red: 0.2126, blue: 0.0722)
        case .bt2020:
            return MatrixCoefficients(red: 0.2627, blue: 0.0593)
        }
    }

    private static func linearized(
        _ encoded: Double,
        transfer: MediaVideoTransferFunction
    ) -> Double {
        let value = clampUnit(encoded)
        switch transfer {
        case .bt709:
            return value < 0.081
                ? value / 4.5
                : pow((value + 0.099) / 1.099, 1 / 0.45)
        case .pq:
            let m1 = 2_610.0 / 16_384.0
            let m2 = 2_523.0 / 32.0
            let c1 = 3_424.0 / 4_096.0
            let c2 = 2_413.0 / 128.0
            let c3 = 2_392.0 / 128.0
            let power = pow(value, 1 / m2)
            return pow(
                max(power - c1, 0) / max(c2 - c3 * power, .leastNonzeroMagnitude),
                1 / m1
            )
        case .hlg:
            return value <= 0.5
                ? value * value / 3
                : (exp((value - hlgC) / hlgA) + hlgB) / 12
        }
    }

    private static func encoded(
        _ linear: Double,
        transfer: MediaVideoTransferFunction
    ) -> Double {
        let value = clampUnit(linear)
        switch transfer {
        case .bt709:
            return value < 0.018
                ? 4.5 * value
                : 1.099 * pow(value, 0.45) - 0.099
        case .pq:
            let m1 = 2_610.0 / 16_384.0
            let m2 = 2_523.0 / 32.0
            let c1 = 3_424.0 / 4_096.0
            let c2 = 2_413.0 / 128.0
            let c3 = 2_392.0 / 128.0
            let power = pow(value, m1)
            return pow((c1 + c2 * power) / (1 + c3 * power), m2)
        case .hlg:
            return value <= 1.0 / 12.0
                ? sqrt(3 * value)
                : hlgA * log(12 * value - hlgB) + hlgC
        }
    }

    private static func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func clampSignedHalf(_ value: Double) -> Double {
        min(max(value, -0.5), 0.5)
    }
}

struct R05DefaultMetalFXSpatialCommandCompleter: R05MetalFXSpatialCommandCompleting {
    func commitAndWait(
        commandBuffer: any R05MetalFXSpatialCommandBuffer,
        retaining resources: R05MetalFXSpatialRetainedResources
    ) async throws {
        guard let commandBuffer = commandBuffer as? R05MetalFXSpatialMetalCommandBuffer else {
            throw R05MetalFXSpatialAdapterError.incompatibleResource
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandBuffer.commandBuffer.addCompletedHandler { completed in
                _ = resources.count
                guard completed.status == .completed, completed.error == nil else {
                    continuation.resume(
                        throwing: R05MetalFXSpatialAdapterError.commandExecutionFailed
                    )
                    return
                }
                continuation.resume(returning: ())
            }
            commandBuffer.commandBuffer.commit()
        }
    }
}

private struct R05MetalFXSpatialTransactionRequest: @unchecked Sendable {
    let sourceDimensions: R05MetalFXSpatialDriverDimensions
    let targetDimensions: R05MetalFXSpatialDriverDimensions
    let commandLabel: String
    let source: any R05MetalFXSpatialNV12Surface
    let destination: any R05MetalFXSpatialNV12Surface
    let retainedResources: [AnyObject]
    let cancellation: R05MetalFXSpatialDriverCancellation
    let colorMode: R05MetalFXSpatialDriverColorMode
    let publish: @Sendable () throws -> Void
}

private enum R05MetalFXSpatialTransactionOutcome: Sendable {
    case processed(any R05MetalFXSpatialNV12Surface)
    case rejected(R05MetalFXSpatialDriverRejectionReason)
    case unsupported(R05MetalFXSpatialDriverUnsupportedReason)
    case unavailable(R05MetalFXSpatialDriverUnavailableReason)
    case failed(R05MetalFXSpatialDriverFailureReason)
    case cancelled(R05MetalFXSpatialCancellationReason)
}

final class R05MetalFXSpatialDriver: @unchecked Sendable {
    private let scalerFactory: any R05MetalFXSpatialScalerCreating
    private let textureAllocator: any R05MetalFXSpatialTextureAllocating
    private let commandBufferFactory: any R05MetalFXSpatialCommandBufferCreating
    private let colorConverter: any R05MetalFXSpatialColorConverting
    private let commandCompleter: any R05MetalFXSpatialCommandCompleting
    private let serializationGate = R05MetalFXSpatialSerializationGate()

    init(
        scalerFactory: any R05MetalFXSpatialScalerCreating,
        textureAllocator: any R05MetalFXSpatialTextureAllocating,
        commandBufferFactory: any R05MetalFXSpatialCommandBufferCreating,
        colorConverter: any R05MetalFXSpatialColorConverting,
        commandCompleter: any R05MetalFXSpatialCommandCompleting
    ) {
        self.scalerFactory = scalerFactory
        self.textureAllocator = textureAllocator
        self.commandBufferFactory = commandBufferFactory
        self.colorConverter = colorConverter
        self.commandCompleter = commandCompleter
    }

    convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        colorConverter: any R05MetalFXSpatialColorConverting
    ) {
        self.init(
            scalerFactory: R05DefaultMetalFXSpatialScalerFactory(device: device),
            textureAllocator: R05DefaultMetalFXSpatialTextureAllocator(device: device),
            commandBufferFactory: R05MetalFXCommandBufferFactory(
                commandQueue: commandQueue
            ),
            colorConverter: colorConverter,
            commandCompleter: R05DefaultMetalFXSpatialCommandCompleter()
        )
    }

    convenience init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue
    ) {
        self.init(
            device: device,
            commandQueue: commandQueue,
            colorConverter: R05DefaultMetalFXSpatialColorConverter(device: device)
        )
    }

    func process(
        _ request: R05MetalFXSpatialDriverRequest
    ) async -> R05MetalFXSpatialDriverOutcome {
        let transaction = R05MetalFXSpatialTransactionRequest(
            sourceDimensions: request.route.sourceDimensions,
            targetDimensions: request.route.targetDimensions,
            commandLabel: "r05.metalfx.spatial.\(request.route.rawValue)",
            source: request.source,
            destination: request.destination,
            retainedResources: request.retainedResources,
            cancellation: request.cancellation,
            colorMode: .linear,
            publish: request.publish
        )
        switch await processTransactionSerially(transaction) {
        case .processed(let destination):
            return .processed(
                R05MetalFXSpatialDriverProcessed(
                    route: request.route,
                    destination: destination
                )
            )
        case .rejected(let reason):
            return .rejected(reason)
        case .unsupported(let reason):
            return .unsupported(reason)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .failed(let reason):
            return .failed(reason)
        case .cancelled(let reason):
            return .cancelled(reason)
        }
    }

    func process(
        _ request: R05MetalFXAdaptiveSpatialDriverRequest
    ) async -> R05MetalFXAdaptiveSpatialDriverOutcome {
        let transaction = R05MetalFXSpatialTransactionRequest(
            sourceDimensions: request.sourceDimensions,
            targetDimensions: request.targetDimensions,
            commandLabel: [
                "r05.metalfx.spatial.adaptive",
                "\(request.sourceDimensions.width)x\(request.sourceDimensions.height)",
                "to",
                "\(request.targetDimensions.width)x\(request.targetDimensions.height)"
            ].joined(separator: "."),
            source: request.source,
            destination: request.destination,
            retainedResources: request.retainedResources,
            cancellation: request.cancellation,
            colorMode: request.colorMode,
            publish: request.publish
        )
        switch await processTransactionSerially(transaction) {
        case .processed(let destination):
            return .processed(
                R05MetalFXAdaptiveSpatialDriverProcessed(
                    sourceDimensions: request.sourceDimensions,
                    targetDimensions: request.targetDimensions,
                    destination: destination
                )
            )
        case .rejected(let reason):
            return .rejected(reason)
        case .unsupported(let reason):
            return .unsupported(reason)
        case .unavailable(let reason):
            return .unavailable(reason)
        case .failed(let reason):
            return .failed(reason)
        case .cancelled(let reason):
            return .cancelled(reason)
        }
    }

    private func processTransactionSerially(
        _ request: R05MetalFXSpatialTransactionRequest
    ) async -> R05MetalFXSpatialTransactionOutcome {
        await serializationGate.acquire()
        let outcome = await processTransaction(request)
        await serializationGate.release()
        return outcome
    }

    // This is one fail-closed GPU transaction; keeping its ordered guards in one
    // function makes pre-commit versus post-commit terminal behavior auditable.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func processTransaction(
        _ request: R05MetalFXSpatialTransactionRequest
    ) async -> R05MetalFXSpatialTransactionOutcome {
        guard request.source.dimensions == request.sourceDimensions else {
            return .rejected(.sourceGeometryMismatch)
        }
        guard request.destination.dimensions == request.targetDimensions else {
            return .rejected(.destinationGeometryMismatch)
        }
        guard !isCancelled(request.cancellation) else {
            return .cancelled(.beforeCommit)
        }
        guard scalerFactory.supportsDevice() else {
            return .unsupported(.deviceUnsupported)
        }

        let configuration = R05MetalFXSpatialScalerConfiguration(
            inputDimensions: request.sourceDimensions,
            outputDimensions: request.targetDimensions,
            colorTextureFormat: .rgba16Float,
            outputTextureFormat: .rgba16Float,
            colorMode: request.colorMode
        )
        guard let scaler = scalerFactory.makeScaler(configuration: configuration) else {
            return .unavailable(.spatialScalerCreationReturnedNil)
        }

        let linearInputDescriptor = R05MetalFXSpatialTextureDescriptor(
            dimensions: request.sourceDimensions,
            pixelFormat: .rgba16Float,
            usage: scaler.colorTextureUsage.union(.shaderWrite),
            storageMode: .private
        )
        guard let linearInput = textureAllocator.makeTexture(
            descriptor: linearInputDescriptor
        ) else {
            return .failed(.linearInputTextureAllocationFailed)
        }
        let linearOutputDescriptor = R05MetalFXSpatialTextureDescriptor(
            dimensions: request.targetDimensions,
            pixelFormat: .rgba16Float,
            usage: scaler.outputTextureUsage.union(.shaderRead),
            storageMode: .private
        )
        guard let linearOutput = textureAllocator.makeTexture(
            descriptor: linearOutputDescriptor
        ) else {
            return .failed(.linearOutputTextureAllocationFailed)
        }
        guard let commandBuffer = commandBufferFactory.makeCommandBuffer(
            label: request.commandLabel
        ) else {
            return .failed(.commandBufferCreationFailed)
        }

        let decodeResources: [AnyObject]
        do {
            decodeResources = try colorConverter.encodeNV12ToLinear(
                source: request.source,
                destination: linearInput,
                commandBuffer: commandBuffer
            )
        } catch {
            return .failed(.nv12ToLinearEncodingFailed)
        }
        do {
            try scaler.encode(
                colorTexture: linearInput,
                outputTexture: linearOutput,
                inputContentDimensions: request.sourceDimensions,
                commandBuffer: commandBuffer
            )
        } catch {
            return .failed(.scalerEncodingFailed)
        }
        let pendingOutput: R05MetalFXSpatialPendingOutputConversion
        do {
            pendingOutput = try colorConverter.encodeLinearToNV12(
                source: linearOutput,
                destination: request.destination,
                commandBuffer: commandBuffer
            )
        } catch {
            return .failed(.linearToNV12EncodingFailed)
        }

        var alphaDecodeResources: [AnyObject] = []
        var alphaRetainedObjects: [AnyObject] = []
        var pendingAlphaOutput: R05MetalFXSpatialPendingOutputConversion?
        if let source = request.source
            as? R05MetalFXSpatialCVPixelBufferSurface,
           let destination = request.destination
            as? R05MetalFXSpatialCVPixelBufferSurface,
           source.videoFormat.hasAlpha {
            guard source.videoFormat == destination.videoFormat else {
                return .failed(.linearToAlphaEncodingFailed)
            }
            guard let alphaInput = textureAllocator.makeTexture(
                descriptor: linearInputDescriptor
            ) else {
                return .failed(.alphaInputTextureAllocationFailed)
            }
            guard let alphaOutput = textureAllocator.makeTexture(
                descriptor: linearOutputDescriptor
            ) else {
                return .failed(.alphaOutputTextureAllocationFailed)
            }
            let alphaSource = R05MetalFXSpatialCVPixelBufferSurface(
                pixelBuffer: source.pixelBuffer,
                videoFormat: source.videoFormat,
                conversionMode: .alphaGuide
            )
            let alphaDestination = R05MetalFXSpatialCVPixelBufferSurface(
                pixelBuffer: destination.pixelBuffer,
                videoFormat: destination.videoFormat,
                conversionMode: .alphaGuide
            )
            do {
                alphaDecodeResources = try colorConverter.encodeNV12ToLinear(
                    source: alphaSource,
                    destination: alphaInput,
                    commandBuffer: commandBuffer
                )
            } catch {
                return .failed(.alphaToLinearEncodingFailed)
            }
            do {
                try scaler.encode(
                    colorTexture: alphaInput,
                    outputTexture: alphaOutput,
                    inputContentDimensions: request.sourceDimensions,
                    commandBuffer: commandBuffer
                )
            } catch {
                return .failed(.alphaScalerEncodingFailed)
            }
            do {
                pendingAlphaOutput = try colorConverter.encodeLinearToNV12(
                    source: alphaOutput,
                    destination: alphaDestination,
                    commandBuffer: commandBuffer
                )
            } catch {
                return .failed(.linearToAlphaEncodingFailed)
            }
            alphaRetainedObjects = [
                alphaSource,
                alphaDestination,
                alphaInput as AnyObject,
                alphaOutput as AnyObject
            ]
        }

        guard !isCancelled(request.cancellation) else {
            return .cancelled(.beforeCommit)
        }
        var retainedObjects = request.retainedResources
        retainedObjects.append(contentsOf: decodeResources)
        retainedObjects.append(contentsOf: pendingOutput.retainedResources)
        retainedObjects.append(contentsOf: alphaDecodeResources)
        retainedObjects.append(
            contentsOf: pendingAlphaOutput?.retainedResources ?? []
        )
        retainedObjects.append(contentsOf: alphaRetainedObjects)
        retainedObjects.append(contentsOf: [
            request.source as AnyObject,
            request.destination as AnyObject,
            linearInput as AnyObject,
            linearOutput as AnyObject,
            scaler as AnyObject,
            commandBuffer as AnyObject
        ])
        let retainedResources = R05MetalFXSpatialRetainedResources(
            retainedObjects
        )
        do {
            try await commandCompleter.commitAndWait(
                commandBuffer: commandBuffer,
                retaining: retainedResources
            )
        } catch is CancellationError {
            return .cancelled(.afterCommit)
        } catch {
            return .failed(.commandExecutionFailed)
        }
        guard !isCancelled(request.cancellation) else {
            return .cancelled(.afterCommit)
        }
        do {
            try pendingOutput.finalize()
        } catch {
            return .failed(.outputFinalizationFailed)
        }
        do {
            try pendingAlphaOutput?.finalize()
        } catch {
            return .failed(.alphaOutputFinalizationFailed)
        }
        guard !isCancelled(request.cancellation) else {
            return .cancelled(.afterCommit)
        }
        do {
            try request.publish()
        } catch {
            return .failed(.publicationFailed)
        }
        return .processed(request.destination)
    }

    private func isCancelled(
        _ cancellation: R05MetalFXSpatialDriverCancellation
    ) -> Bool {
        cancellation.isCancelled() || Task.isCancelled
    }
}

extension R05MetalFXSpatialDriver: R05MetalFXAdaptiveSpatialDriving {}

enum R05MetalFXAdaptiveSpatialScalerError: Error, Equatable, Sendable {
    case invalidConfiguration(
        source: R05MetalFXSpatialDriverDimensions,
        target: R05MetalFXSpatialDriverDimensions
    )
    case deviceUnavailable
    case commandQueueCreationFailed
    case rejected(R05MetalFXSpatialDriverRejectionReason)
    case unsupported(R05MetalFXSpatialDriverUnsupportedReason)
    case unavailable(R05MetalFXSpatialDriverUnavailableReason)
    case failed(R05MetalFXSpatialDriverFailureReason)
    case outputContractMismatch
}

/// Executes one exact MetalFX spatial transaction at the configured adaptive
/// geometry. It has no fallback path: every non-processed native outcome is
/// returned to the caller as a typed error.
final class R05MetalFXAdaptiveSpatialScaler: @unchecked Sendable {
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let videoFormat: MediaVideoFormat

    private let driver: any R05MetalFXAdaptiveSpatialDriving

    init(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat = .sdrBT709
    ) throws {
        try Self.validateConfiguration(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            videoFormat: videoFormat
        )
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw R05MetalFXAdaptiveSpatialScalerError.deviceUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw R05MetalFXAdaptiveSpatialScalerError.commandQueueCreationFailed
        }
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.videoFormat = videoFormat
        driver = R05MetalFXSpatialDriver(
            device: device,
            commandQueue: commandQueue
        )
    }

    init(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat = .sdrBT709,
        driver: any R05MetalFXAdaptiveSpatialDriving
    ) throws {
        try Self.validateConfiguration(
            sourceResolution: sourceResolution,
            targetResolution: targetResolution,
            videoFormat: videoFormat
        )
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.videoFormat = videoFormat
        self.driver = driver
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws {
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: sourceResolution,
            format: videoFormat
        )
        try R13PixelLayoutProcessor.validateStoredCodes(source)

        try videoFormat.validate(pixelBuffer: destination)
        let destinationResolution = VideoResolution(
            width: CVPixelBufferGetWidth(destination),
            height: CVPixelBufferGetHeight(destination)
        )
        guard destinationResolution == targetResolution else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: targetResolution.width,
                expectedHeight: targetResolution.height,
                actualWidth: destinationResolution.width,
                actualHeight: destinationResolution.height
            )
        }
        R13PixelLayoutProcessor.copyAttachments(
            source: source,
            destination: destination
        )
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

        let sourceSurface = R05MetalFXSpatialCVPixelBufferSurface(
            pixelBuffer: source,
            videoFormat: videoFormat
        )
        let destinationSurface = R05MetalFXSpatialCVPixelBufferSurface(
            pixelBuffer: destination,
            videoFormat: videoFormat
        )
        let publication = R05MetalFXAdaptiveSpatialPublication(
            validate: { [destinationSurface, targetResolution, videoFormat] in
                try R13MediaVideoFormatContract.validate(
                    destinationSurface.pixelBuffer,
                    resolution: targetResolution,
                    format: videoFormat
                )
                try R13PixelLayoutProcessor.validateStoredCodes(
                    destinationSurface.pixelBuffer
                )
            }
        )
        let outcome = await driver.process(
            R05MetalFXAdaptiveSpatialDriverRequest(
                sourceDimensions: Self.dimensions(sourceResolution),
                targetDimensions: Self.dimensions(targetResolution),
                source: sourceSurface,
                destination: destinationSurface,
                cancellation: R05MetalFXSpatialDriverCancellation(
                    isCancelled: { cancellation.isCancelled }
                ),
                colorMode: videoFormat.isHDR ? .hdr : .linear,
                publish: { try publication.publish() }
            )
        )

        switch outcome {
        case .processed(let processed):
            guard processed.sourceDimensions == Self.dimensions(sourceResolution),
                  processed.targetDimensions == Self.dimensions(targetResolution),
                  let returned = processed.destination
                    as? R05MetalFXSpatialCVPixelBufferSurface,
                  returned === destinationSurface,
                  publication.wasPublishedExactlyOnce else {
                throw R05MetalFXAdaptiveSpatialScalerError.outputContractMismatch
            }
        case .rejected(let reason):
            throw R05MetalFXAdaptiveSpatialScalerError.rejected(reason)
        case .unsupported(let reason):
            throw R05MetalFXAdaptiveSpatialScalerError.unsupported(reason)
        case .unavailable(let reason):
            throw R05MetalFXAdaptiveSpatialScalerError.unavailable(reason)
        case .failed(let reason):
            throw R05MetalFXAdaptiveSpatialScalerError.failed(reason)
        case .cancelled:
            throw R03NV12ScalingError.operationCancelled
        }

        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: targetResolution,
            format: videoFormat
        )
        try R13PixelLayoutProcessor.validateStoredCodes(destination)
    }

    private static func validateConfiguration(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat
    ) throws {
        let source = dimensions(sourceResolution)
        let target = dimensions(targetResolution)
        let layout: R13PixelLayout
        do {
            layout = try R13PixelLayoutRegistry.layout(
                for: videoFormat.pixelStorage.pixelFormat
            )
            try layout.validateGeometry(
                width: source.width,
                height: source.height
            )
            try layout.validateGeometry(
                width: target.width,
                height: target.height
            )
        } catch {
            throw R05MetalFXAdaptiveSpatialScalerError.invalidConfiguration(
                source: source,
                target: target
            )
        }
        guard source.width.isMultiple(of: 2),
              source.height.isMultiple(of: 2),
              target.width.isMultiple(of: 2),
              target.height.isMultiple(of: 2),
              target.width >= source.width,
              target.height >= source.height,
              target != source else {
            throw R05MetalFXAdaptiveSpatialScalerError.invalidConfiguration(
                source: source,
                target: target
            )
        }
    }

    private static func dimensions(
        _ resolution: VideoResolution
    ) -> R05MetalFXSpatialDriverDimensions {
        R05MetalFXSpatialDriverDimensions(
            width: resolution.width,
            height: resolution.height
        )
    }
}

private final class R05MetalFXAdaptiveSpatialPublication: @unchecked Sendable {
    private let lock = NSLock()
    private let validate: @Sendable () throws -> Void
    private var publicationCount = 0

    init(validate: @escaping @Sendable () throws -> Void) {
        self.validate = validate
    }

    var wasPublishedExactlyOnce: Bool {
        lock.lock()
        defer { lock.unlock() }
        return publicationCount == 1
    }

    func publish() throws {
        lock.lock()
        publicationCount += 1
        let count = publicationCount
        lock.unlock()
        guard count == 1 else {
            throw R05MetalFXAdaptiveSpatialScalerError.outputContractMismatch
        }
        try validate()
    }
}

private actor R05MetalFXSpatialSerializationGate {
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isAcquired else {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private extension MTLTextureUsage {
    func containsAll(_ required: MTLTextureUsage) -> Bool {
        intersection(required) == required
    }
}
