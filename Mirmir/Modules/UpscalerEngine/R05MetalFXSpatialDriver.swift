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

final class R05MetalFXSpatialCVPixelBufferSurface: R05MetalFXSpatialNV12Surface,
    @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let dimensions: R05MetalFXSpatialDriverDimensions

    init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        self.dimensions = R05MetalFXSpatialDriverDimensions(
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

enum R05MetalFXSpatialDriverColorMode: String, Equatable, Sendable {
    case linear
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
              configuration.outputTextureFormat == .rgba16Float,
              configuration.colorMode == .linear else {
            return nil
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.colorTextureFormat = configuration.colorTextureFormat
        descriptor.outputTextureFormat = configuration.outputTextureFormat
        descriptor.inputWidth = configuration.inputDimensions.width
        descriptor.inputHeight = configuration.inputDimensions.height
        descriptor.outputWidth = configuration.outputDimensions.width
        descriptor.outputHeight = configuration.outputDimensions.height
        descriptor.colorProcessingMode = .linear
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
        let linear = try R05MetalFXColorBridge.decode(
            pixelBuffer: source.pixelBuffer
        )
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
                try R05MetalFXColorBridge.encodeClippingFiniteRGB(
                    linear,
                    into: destination.pixelBuffer
                )
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
        await serializationGate.acquire()
        let outcome = await processSerially(request)
        await serializationGate.release()
        return outcome
    }

    // This is one fail-closed GPU transaction; keeping its ordered guards in one
    // function makes pre-commit versus post-commit terminal behavior auditable.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func processSerially(
        _ request: R05MetalFXSpatialDriverRequest
    ) async -> R05MetalFXSpatialDriverOutcome {
        let route = request.route
        guard request.source.dimensions == route.sourceDimensions else {
            return .rejected(.sourceGeometryMismatch)
        }
        guard request.destination.dimensions == route.targetDimensions else {
            return .rejected(.destinationGeometryMismatch)
        }
        guard !isCancelled(request) else {
            return .cancelled(.beforeCommit)
        }
        guard scalerFactory.supportsDevice() else {
            return .unsupported(.deviceUnsupported)
        }

        let configuration = R05MetalFXSpatialScalerConfiguration(
            inputDimensions: route.sourceDimensions,
            outputDimensions: route.targetDimensions,
            colorTextureFormat: .rgba16Float,
            outputTextureFormat: .rgba16Float,
            colorMode: .linear
        )
        guard let scaler = scalerFactory.makeScaler(configuration: configuration) else {
            return .unavailable(.spatialScalerCreationReturnedNil)
        }

        let linearInputDescriptor = R05MetalFXSpatialTextureDescriptor(
            dimensions: route.sourceDimensions,
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
            dimensions: route.targetDimensions,
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
            label: "r05.metalfx.spatial.\(route.rawValue)"
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
                inputContentDimensions: route.sourceDimensions,
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

        guard !isCancelled(request) else {
            return .cancelled(.beforeCommit)
        }
        let retainedResources = R05MetalFXSpatialRetainedResources(
            request.retainedResources
                + decodeResources
                + pendingOutput.retainedResources
                + [
                    request.source as AnyObject,
                    request.destination as AnyObject,
                    linearInput as AnyObject,
                    linearOutput as AnyObject,
                    scaler as AnyObject,
                    commandBuffer as AnyObject
                ]
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
        guard !isCancelled(request) else {
            return .cancelled(.afterCommit)
        }
        do {
            try pendingOutput.finalize()
        } catch {
            return .failed(.outputFinalizationFailed)
        }
        guard !isCancelled(request) else {
            return .cancelled(.afterCommit)
        }
        do {
            try request.publish()
        } catch {
            return .failed(.publicationFailed)
        }
        return .processed(
            R05MetalFXSpatialDriverProcessed(
                route: route,
                destination: request.destination
            )
        )
    }

    private func isCancelled(_ request: R05MetalFXSpatialDriverRequest) -> Bool {
        request.cancellation.isCancelled() || Task.isCancelled
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
