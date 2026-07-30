import CoreGraphics
import Foundation

public enum UpscalerEngineAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)

    public var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

public enum UpscalerEngineError: Error, CustomStringConvertible {
    case backendUnavailable(reason: String)
    case modeUnavailable(mode: UpscaleMode, reason: String)
    case invalidJobIdentifier(String)
    case modelAssetsNotReady
    case unsupportedSourceResolution(VideoResolution)
    case inputOutputCollision
    case jobAlreadyRunning
    case strategyFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .backendUnavailable(let reason):
            return reason
        case .modeUnavailable(_, let reason):
            return reason
        case .invalidJobIdentifier(let identifier):
            return "Upscale job identifier is invalid: \(identifier)"
        case .modelAssetsNotReady:
            return "VTFrameProcessor super-resolution model assets are not ready."
        case .unsupportedSourceResolution(let res):
            return "Source geometry \(res) cannot be represented by an available upscale route."
        case .inputOutputCollision:
            return "The output file must be different from the source video."
        case .jobAlreadyRunning:
            return "An upscale job is already running."
        case .strategyFailed(let detail):
            return "Upscale strategy failed: \(detail)"
        case .cancelled:
            return "Upscale job was cancelled."
        }
    }
}

public struct UpscalePreviewImage: Equatable, Sendable {
    public static let maximumWidth = 960
    public static let maximumHeight = 540
    public static let bytesPerPixel = 4

    public let width: Int
    public let height: Int
    public let rgba8: Data

    init?(width: Int, height: Int, rgba8: Data) {
        guard width > 0,
              height > 0,
              width <= Self.maximumWidth,
              height <= Self.maximumHeight else {
            return nil
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(
            by: height
        )
        let (expectedByteCount, byteOverflow) =
            pixelCount.multipliedReportingOverflow(
                by: Self.bytesPerPixel
            )
        guard !pixelOverflow,
              !byteOverflow,
              rgba8.count == expectedByteCount else {
            return nil
        }
        self.width = width
        self.height = height
        self.rgba8 = rgba8
    }

    public func makeCGImage() -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: rgba8 as CFData) else {
            return nil
        }
        let alpha = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: Self.bytesPerPixel * 8,
            bytesPerRow: width * Self.bytesPerPixel,
            space: colorSpace,
            bitmapInfo: [.byteOrder32Big, alpha],
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

public struct UpscalePreviewFrame: Equatable, Sendable {
    public let frameIndex: Int
    public let presentationSeconds: Double
    public let source: UpscalePreviewImage
    public let processed: UpscalePreviewImage

    init?(
        frameIndex: Int,
        presentationSeconds: Double,
        source: UpscalePreviewImage,
        processed: UpscalePreviewImage
    ) {
        guard frameIndex >= 0,
              presentationSeconds.isFinite,
              source.width == processed.width,
              source.height == processed.height else {
            return nil
        }
        self.frameIndex = frameIndex
        self.presentationSeconds = presentationSeconds
        self.source = source
        self.processed = processed
    }
}

public protocol UpscalerJobHandle: AnyObject, Sendable {
    var progressStream: AsyncStream<UpscaleProgress> { get }
    var previewStream: AsyncStream<UpscalePreviewFrame> { get }
    func cancel()
    func waitForCompletion() async throws -> URL
}

public extension UpscalerJobHandle {
    var previewStream: AsyncStream<UpscalePreviewFrame> {
        AsyncStream { $0.finish() }
    }
}

public protocol UpscalerEngineService: AnyObject, Sendable {
    var availability: UpscalerEngineAvailability { get }

    func availability(for mode: UpscaleMode) -> UpscalerEngineAvailability
    func submit(_ job: UpscaleJob) throws -> UpscalerJobHandle
    func start()
    func stop()
}

public extension UpscalerEngineService {
    func availability(for _: UpscaleMode) -> UpscalerEngineAvailability {
        availability
    }
}
