import Foundation
import Metal
import CoreVideo
import os.lock

private final class MirmirMetalResourceBundleToken: NSObject {}

enum MirmirDefaultMetalLibrary {
    static func make(on device: any MTLDevice) -> MTLLibrary? {
        if let library = device.makeDefaultLibrary() {
            return library
        }
        return try? device.makeDefaultLibrary(
            bundle: Bundle(for: MirmirMetalResourceBundleToken.self)
        )
    }
}

final class DefaultMetalRenderingService: MetalRenderingService, @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    private let stateLock = OSAllocatedUnfairLock(initialState: false)

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderingServiceError.noDefaultDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw MetalRenderingServiceError.commandQueueUnavailable
        }

        var unmanagedCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &unmanagedCache
        )
        guard status == kCVReturnSuccess, let cache = unmanagedCache else {
            throw MetalRenderingServiceError.textureCacheCreationFailed(status)
        }

        self.device = device
        self.commandQueue = queue
        self.textureCache = cache
        queue.label = "com.mirmir.metal.queue"
    }

    func start() throws {
        stateLock.withLock { isStarted in
            isStarted = true
        }
    }

    func stop() {
        stateLock.withLock { isStarted in
            isStarted = false
        }
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
