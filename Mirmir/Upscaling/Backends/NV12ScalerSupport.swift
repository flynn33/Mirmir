import CoreVideo
import Foundation

enum NV12ScalerConfigurationValidation {
    case valid(NV12ScalerConfiguration)
    case unavailable(BackendUnavailableReason)
}

struct NV12ScalerConfiguration: Equatable, Sendable {
    let backendID: UpscaleBackendID
    let pixelFormat: OSType
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int

    static func validate(
        source: VideoInfo,
        targetSize: CGSize,
        backendID: UpscaleBackendID
    ) -> NV12ScalerConfigurationValidation {
        let sourceSize = source.geometry.encodedSize ?? source.naturalSize
        guard let sourceDimensions = exactEvenDimensions(sourceSize) else {
            return .unavailable(.unsupportedSourceDimensions(
                width: safeDimension(sourceSize.width),
                height: safeDimension(sourceSize.height),
                details: "8-bit NV12 requires positive, integral, even encoded dimensions"
            ))
        }
        guard let targetDimensions = exactEvenDimensions(targetSize) else {
            return .unavailable(.unsupportedTargetDimensions(
                width: safeDimension(targetSize.width),
                height: safeDimension(targetSize.height),
                details: "8-bit NV12 requires positive, integral, even target dimensions"
            ))
        }
        if source.color.dynamicRange == .hdr
            || source.color.hasMasteringDisplayMetadata
            || source.color.hasContentLightLevelMetadata {
            return .unavailable(.hdrPreservationUnavailable)
        }
        guard source.color.dynamicRange == .sdr else {
            return .unavailable(.unsupportedPixelFormatOrBitDepth(
                details: "The source dynamic range is unknown; this adapter requires an explicitly identified SDR source"
            ))
        }
        if let bitDepth = source.color.bitDepth, bitDepth != 8 {
            return .unavailable(.unsupportedPixelFormatOrBitDepth(
                details: "This adapter accepts decoded 8-bit NV12; the source reports \(bitDepth)-bit video"
            ))
        }
        if source.geometry.cleanAperture != nil {
            return .unavailable(.unsupportedSourceDimensions(
                width: sourceDimensions.width,
                height: sourceDimensions.height,
                details: "This adapter does not rescale an explicit clean aperture"
            ))
        }
        if let ratio = source.geometry.pixelAspectRatio,
           ratio.horizontalSpacing != ratio.verticalSpacing {
            return .unavailable(.unsupportedSourceDimensions(
                width: sourceDimensions.width,
                height: sourceDimensions.height,
                details: "This adapter supports square pixels; the source reports \(ratio.horizontalSpacing):\(ratio.verticalSpacing)"
            ))
        }
        guard let isFullRange = source.color.isFullRange else {
            return .unavailable(.unsupportedPixelFormatOrBitDepth(
                details: "The source range is unknown; an explicit video-range (420v) or full-range (420f) decode contract is required"
            ))
        }
        let pixelFormat = isFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if let reported = source.color.pixelFormat, reported != pixelFormat {
            return .unavailable(.unsupportedPixelFormatOrBitDepth(
                details: "The source reports \(FourCC.string(from: reported) ?? String(reported)); its range contract requires \(FourCC.string(from: pixelFormat) ?? String(pixelFormat))"
            ))
        }
        if let fieldCount = source.color.fieldCount, fieldCount != 1 {
            return .unavailable(.unsupportedPixelFormatOrBitDepth(
                details: "This spatial adapter accepts progressive video; the source declares \(fieldCount) fields per frame"
            ))
        }
        return .valid(NV12ScalerConfiguration(
            backendID: backendID,
            pixelFormat: pixelFormat,
            sourceWidth: sourceDimensions.width,
            sourceHeight: sourceDimensions.height,
            targetWidth: targetDimensions.width,
            targetHeight: targetDimensions.height
        ))
    }

    func attributes(width: Int, height: Int, metalCompatible: Bool = false) -> PixelBufferAttributes {
        var values: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        if metalCompatible {
            values[kCVPixelBufferMetalCompatibilityKey as String] = true
        }
        return PixelBufferAttributes(values)
    }

    func validate(_ buffer: CVPixelBuffer, source: Bool) throws {
        let expectedWidth = source ? sourceWidth : targetWidth
        let expectedHeight = source ? sourceHeight : targetHeight
        guard CVPixelBufferGetPixelFormatType(buffer) == pixelFormat else {
            throw processingError("\(source ? "source" : "destination") pixel format is not the prepared 8-bit NV12 range")
        }
        guard CVPixelBufferGetWidth(buffer) == expectedWidth,
              CVPixelBufferGetHeight(buffer) == expectedHeight,
              CVPixelBufferIsPlanar(buffer),
              CVPixelBufferGetPlaneCount(buffer) == 2 else {
            throw processingError("\(source ? "source" : "destination") buffer does not match the prepared \(expectedWidth) × \(expectedHeight) two-plane NV12 layout")
        }
    }

    func processingError(_ details: String, frameIndex: Int? = nil) -> MirmirError {
        .backendProcessingFailed(
            backendID: backendID,
            frameIndex: frameIndex,
            details: details
        )
    }

    private static func exactEvenDimensions(_ size: CGSize) -> (width: Int, height: Int)? {
        guard size.width.isFinite, size.height.isFinite,
              let width = Int(exactly: size.width),
              let height = Int(exactly: size.height),
              width > 0, height > 0,
              width.isMultiple(of: 2), height.isMultiple(of: 2) else { return nil }
        return (width, height)
    }

    private static func safeDimension(_ value: CGFloat) -> Int {
        guard value.isFinite, let result = Int(exactly: value.rounded()) else { return 0 }
        return result
    }
}

enum NV12FrameAttachments {
    static func chromaScaleTranslation(
        from source: CVPixelBuffer, scaleX: Double, scaleY: Double,
        backendID: UpscaleBackendID, frameIndex: Int
    ) throws -> (x: Double, y: Double) {
        let top = CVBufferCopyAttachment(source, kCVImageBufferChromaLocationTopFieldKey, nil)
        let bottom = CVBufferCopyAttachment(source, kCVImageBufferChromaLocationBottomFieldKey, nil)
        // Retain the existing untagged-buffer behavior; this supplies no phase proof.
        guard top != nil || bottom != nil else { return (0, 0) }
        do {
            let siting = try ASHNV12FrameCodec.chromaSiting(for: source)
            if let bottom, (bottom as? String) != (top as? String) {
                throw UpscalerEngineError.strategyFailed("spatial scaling requires one common chroma location")
            }
            // Framework coordinates center each component plane. Translate UV so
            // its physical luma coordinates retain the declared sample location.
            return ((scaleX - 1) * Double(siting.horizontalLumaOffsetNumerator - 1) / 4,
                    (scaleY - 1) * Double(siting.verticalLumaOffsetNumerator - 1) / 4)
        } catch {
            throw MirmirError.backendProcessingFailed(backendID: backendID,
                frameIndex: frameIndex, details: error.localizedDescription)
        }
    }

    static func copy(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        let keys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferGammaLevelKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferCGColorSpaceKey,
            kCVImageBufferPixelAspectRatioKey
        ]
        for key in keys {
            CVBufferRemoveAttachment(destination, key)
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            }
        }
    }
}
