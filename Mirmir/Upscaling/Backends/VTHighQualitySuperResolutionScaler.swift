import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct VTHighQualitySuperResolutionBackend: ModelDownloadableBackend {
    let descriptor: BackendDescriptor

    init?(descriptor: BackendDescriptor) {
        guard descriptor.id == .videoToolboxSuperResolutionQuality else { return nil }
        self.descriptor = descriptor
    }

    func availability(for source: VideoInfo, targetSize: CGSize, environment: RuntimeEnvironment) async -> BackendAvailability {
        switch NV12ScalerConfiguration.validate(source: source, targetSize: targetSize, backendID: descriptor.id) {
        case .unavailable(let reason): return .unavailable(reason: reason)
        case .valid: break
        }
        let native = await environment.capabilityProbe.availability(for: descriptor.id, source: source, targetSize: targetSize)
        guard native == .available || native.isSelectable else { return native }
        guard #available(macOS 26.0, *) else { return .unavailable(reason: .operatingSystemTooOld(requiredVersion: "26.0")) }
        do {
            let configuration = try makeConfiguration(source: source, targetSize: targetSize)
            guard configuration.supportedPixelFormats.contains(kCVPixelFormatType_64RGBAHalf) else {
                return .unavailable(reason: .unsupportedPixelFormatOrBitDepth(details: "this quality model does not report 64RGBAHalf as a supported native frame format"))
            }
            switch configuration.configurationModelStatus {
            case .ready: return .available
            case .downloadRequired: return .modelDownloadRequired(progress: nil)
            case .downloading:
                return .modelDownloadRequired(progress: Double(configuration.configurationModelPercentageAvailable))
            @unknown default:
                return .unavailable(reason: .modelUnavailable(details: "unknown model state \(configuration.configurationModelStatus.rawValue)"))
            }
        } catch let reason as BackendUnavailableReasonBox {
            return .unavailable(reason: reason.value)
        } catch {
            return .unavailable(reason: .appleAPIUnsupported(details: error.localizedDescription))
        }
    }

    func prepare(request: BackendPreparationRequest, environment: RuntimeEnvironment) async throws -> any PreparedFrameUpscaler {
        let nv12: NV12ScalerConfiguration
        switch NV12ScalerConfiguration.validate(source: request.source, targetSize: request.targetSize, backendID: descriptor.id) {
        case .valid(let value): nv12 = value
        case .unavailable(let reason): throw BackendPreparationError.unavailable(descriptor.id, reason)
        }
        guard #available(macOS 26.0, *) else {
            throw BackendPreparationError.unavailable(descriptor.id, .operatingSystemTooOld(requiredVersion: "26.0"))
        }
        let configuration: VTSuperResolutionScalerConfiguration
        do { configuration = try makeConfiguration(source: request.source, targetSize: request.targetSize) }
        catch let error as BackendUnavailableReasonBox { throw BackendPreparationError.unavailable(descriptor.id, error.value) }
        guard configuration.configurationModelStatus == .ready else {
            throw BackendPreparationError.unavailable(descriptor.id, .modelUnavailable(details: "download the Apple quality model before processing"))
        }
        return try PreparedVTHighQualitySuperResolutionScaler(nv12: nv12, nativeConfiguration: configuration)
    }

    func downloadModel(request: BackendPreparationRequest, environment: RuntimeEnvironment, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else {
            throw BackendPreparationError.unavailable(descriptor.id, .operatingSystemTooOld(requiredVersion: "26.0"))
        }
        let configuration: VTSuperResolutionScalerConfiguration
        do { configuration = try makeConfiguration(source: request.source, targetSize: request.targetSize) }
        catch let error as BackendUnavailableReasonBox { throw BackendPreparationError.unavailable(descriptor.id, error.value) }
        if configuration.configurationModelStatus == .ready { progress(1); return }
        let polling = Task {
            while !Task.isCancelled {
                progress(Double(configuration.configurationModelPercentageAvailable))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { polling.cancel() }
        do { try await configuration.downloadConfigurationModel() }
        catch { throw BackendPreparationError.unavailable(descriptor.id, .modelUnavailable(details: error.localizedDescription)) }
        guard configuration.configurationModelStatus == .ready else {
            throw BackendPreparationError.unavailable(descriptor.id, .modelUnavailable(details: "the system download completed without reporting Ready"))
        }
        progress(1)
    }

    @available(macOS 26.0, *)
    private func makeConfiguration(source: VideoInfo, targetSize: CGSize) throws -> VTSuperResolutionScalerConfiguration {
        guard let sourceSize = source.geometry.encodedSize,
              let width = Int(exactly: sourceSize.width), let height = Int(exactly: sourceSize.height),
              let targetWidth = Int(exactly: targetSize.width), let targetHeight = Int(exactly: targetSize.height),
              targetWidth % width == 0, targetHeight % height == 0,
              targetWidth / width == targetHeight / height else {
            throw BackendUnavailableReasonBox(.unsupportedScaleFactor(details: "quality VideoToolbox requires one integral uniform scale factor"))
        }
        let scale = targetWidth / width
        guard VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(scale) else {
            throw BackendUnavailableReasonBox(.unsupportedScaleFactor(details: "requested \(scale)×; this Mac reports \(VTSuperResolutionScalerConfiguration.supportedScaleFactors)"))
        }
        let revision = VTSuperResolutionScalerConfiguration.defaultRevision
        guard VTSuperResolutionScalerConfiguration.supportedRevisions.contains(revision.rawValue) else {
            throw BackendUnavailableReasonBox(.appleAPIUnsupported(details: "the default quality revision is not runtime-supported"))
        }
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: width,
            frameHeight: height,
            scaleFactor: scale,
            inputType: .video,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: revision
        ) else {
            throw BackendUnavailableReasonBox(.appleAPIUnsupported(details: "VideoToolbox rejected the quality configuration"))
        }
        return configuration
    }
}

private struct BackendUnavailableReasonBox: Error {
    let value: BackendUnavailableReason
    init(_ value: BackendUnavailableReason) { self.value = value }
}

@available(macOS 26.0, *)
actor PreparedVTHighQualitySuperResolutionScaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID = .videoToolboxSuperResolutionQuality

    private let nv12: NV12ScalerConfiguration
    private let processor = VTFrameProcessor()
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private let bridge: VTQualityColorBridge
    private var previousSource: VTFrameProcessorFrame?
    private var previousOutput: VTFrameProcessorFrame?
    private var finished = false

    init(nv12: NV12ScalerConfiguration, nativeConfiguration: VTSuperResolutionScalerConfiguration) throws {
        self.nv12 = nv12
        sourcePixelBufferAttributes = nv12.attributes(width: nv12.sourceWidth, height: nv12.sourceHeight)
        destinationPixelBufferAttributes = nv12.attributes(width: nv12.targetWidth, height: nv12.targetHeight)
        sourcePool = try VTFrameBufferPool.make(
            required: nativeConfiguration.sourcePixelBufferAttributes,
            width: nv12.sourceWidth,
            height: nv12.sourceHeight,
            pixelFormat: kCVPixelFormatType_64RGBAHalf
        )
        destinationPool = try VTFrameBufferPool.make(
            required: nativeConfiguration.destinationPixelBufferAttributes,
            width: nv12.targetWidth,
            height: nv12.targetHeight,
            pixelFormat: kCVPixelFormatType_64RGBAHalf
        )
        bridge = try VTQualityColorBridge()
        do { try processor.startSession(configuration: nativeConfiguration) }
        catch { throw nv12.processingError("quality VTFrameProcessor session start failed: \(error.localizedDescription)") }
    }

    deinit { if !finished { processor.endSession() } }

    func process(source: FramePixelBuffer, destination: FramePixelBuffer, timing: FrameTiming) async throws {
        let source = source.value
        let destination = destination.value
        guard !finished else { throw nv12.processingError("the quality processor is already finished", frameIndex: timing.frameIndex) }
        try nv12.validate(source, source: true)
        try nv12.validate(destination, source: false)
        let nativeSource = try VTFrameBufferPool.makeBuffer(from: sourcePool, backendID: actualBackendID)
        let nativeDestination = try VTFrameBufferPool.makeBuffer(from: destinationPool, backendID: actualBackendID)
        try bridge.toNative(source, destination: nativeSource)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: nativeSource, presentationTimeStamp: timing.presentationTime),
              let destinationFrame = VTFrameProcessorFrame(buffer: nativeDestination, presentationTimeStamp: timing.presentationTime),
              let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: sourceFrame,
                previousFrame: previousSource,
                previousOutputFrame: previousOutput,
                opticalFlow: nil,
                submissionMode: timing.frameIndex == 0 ? .random : .sequential,
                destinationFrame: destinationFrame
              ) else {
            throw nv12.processingError("quality VideoToolbox frame parameter creation failed", frameIndex: timing.frameIndex)
        }
        do { _ = try await processor.process(parameters: parameters) }
        catch { throw nv12.processingError("quality VideoToolbox processing failed: \(error.localizedDescription)", frameIndex: timing.frameIndex) }
        try bridge.fromNative(nativeDestination, destination: destination)
        NV12FrameAttachments.copy(from: source, to: destination)
        previousSource = sourceFrame
        previousOutput = destinationFrame
        try Task.checkCancellation()
    }

    func finish() async throws {
        guard !finished else { return }
        finished = true
        previousSource = nil
        previousOutput = nil
        processor.endSession()
    }
}

@available(macOS 26.0, *)
enum VTFrameBufferPool {
    static func make(required: [String: any Sendable], width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBufferPool {
        var attributes: [String: Any] = [:]
        for (key, value) in required { attributes[key] = value }
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as CFDictionary
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw MirmirError.writerFailed("VideoToolbox pixel-buffer pool creation failed (\(status))")
        }
        return pool
    }

    static func makeBuffer(from pool: CVPixelBufferPool, backendID: UpscaleBackendID) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw MirmirError.backendProcessingFailed(backendID: backendID, frameIndex: nil, details: "native pixel-buffer allocation failed (\(status))")
        }
        return buffer
    }
}

@available(macOS 26.0, *)
private final class VTQualityColorBridge: @unchecked Sendable {
    private let toNative: VTPixelTransferSession
    private let fromNative: VTPixelTransferSession

    init() throws {
        toNative = try Self.makeSession(destinationUsesYCbCr: false)
        do { fromNative = try Self.makeSession(destinationUsesYCbCr: true) }
        catch { VTPixelTransferSessionInvalidate(toNative); throw error }
    }
    deinit { VTPixelTransferSessionInvalidate(toNative); VTPixelTransferSessionInvalidate(fromNative) }

    func toNative(_ source: CVPixelBuffer, destination: CVPixelBuffer) throws {
        try transfer(toNative, source: source, destination: destination)
    }
    func fromNative(_ source: CVPixelBuffer, destination: CVPixelBuffer) throws {
        try transfer(fromNative, source: source, destination: destination)
    }
    private func transfer(_ session: VTPixelTransferSession, source: CVPixelBuffer, destination: CVPixelBuffer) throws {
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else { throw MirmirError.backendProcessingFailed(backendID: .videoToolboxSuperResolutionQuality, frameIndex: nil, details: "quality color bridge returned OSStatus \(status)") }
    }
    private static func makeSession(destinationUsesYCbCr: Bool) throws -> VTPixelTransferSession {
        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        guard status == noErr, let session else { throw MirmirError.backendProcessingFailed(backendID: .videoToolboxSuperResolutionQuality, frameIndex: nil, details: "quality color bridge session creation failed (\(status))") }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal),
            (kVTPixelTransferPropertyKey_DestinationColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_DestinationTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTPixelTransferPropertyKey_RealTime, kCFBooleanFalse)
        ] + (destinationUsesYCbCr ? [(kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] : [])
        for (key, value) in properties where VTSessionSetProperty(session, key: key, value: value) != noErr {
            VTPixelTransferSessionInvalidate(session)
            throw MirmirError.backendProcessingFailed(backendID: .videoToolboxSuperResolutionQuality, frameIndex: nil, details: "quality color bridge rejected property \(key)")
        }
        return session
    }
}
