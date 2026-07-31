import Accelerate
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

enum R13FormatPreservingScalingQuality: String, Sendable {
    case fast = "fast"
    case highQuality = "high_quality"

    var flags: vImage_Flags {
        switch self {
        case .fast:
            return vImage_Flags(kvImageEdgeExtend)
        case .highQuality:
            return vImage_Flags(
                kvImageEdgeExtend | kvImageHighQualityResampling
            )
        }
    }
}

struct R13ReleaseVideoFormatBinding: Hashable, Sendable {
    let pixelFormat: OSType
    let pixelStorage: String
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let chromaLocation: String
    let alphaMode: String
    let displayVolumeSHA256: String?
    let contentLightLevelSHA256: String?

    init(_ format: MediaVideoFormat) {
        pixelFormat = format.pixelStorage.pixelFormat
        pixelStorage = format.pixelStorage.rawValue
        colorPrimaries = format.colorPrimaries.rawValue
        transferFunction = format.transferFunction.rawValue
        yCbCrMatrix = format.pixelStorage.usesYCbCr
            ? format.cmYCbCrMatrix
            : "none"
        chromaLocation = format.chromaLocation ?? "none"
        alphaMode = format.alphaMode.rawValue
        displayVolumeSHA256 = format.masteringDisplayColorVolume
            .map(Self.sha256)
        contentLightLevelSHA256 = format.contentLightLevelInfo
            .map(Self.sha256)
    }

    static let canonicalNV12 = R13ReleaseVideoFormatBinding(.sdrBT709)

    var isCanonicalNV12: Bool {
        self == .canonicalNV12
    }

    var identityComponent: String {
        [
            pixelStorage,
            colorPrimaries,
            transferFunction,
            alphaMode,
            displayVolumeSHA256 ?? "no-mastering-display",
            contentLightLevelSHA256 ?? "no-content-light-level"
        ].joined(separator: ".")
    }

    var fourCC: String {
        let bytes = [
            UInt8(truncatingIfNeeded: pixelFormat >> 24),
            UInt8(truncatingIfNeeded: pixelFormat >> 16),
            UInt8(truncatingIfNeeded: pixelFormat >> 8),
            UInt8(truncatingIfNeeded: pixelFormat)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
            ?? String(pixelFormat)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum R13MediaVideoFormatContract {
    static func validate(
        _ pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) throws {
        try format.validate(pixelBuffer: pixelBuffer)
        let actual = VideoResolution(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard actual == resolution else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: resolution.width,
                expectedHeight: resolution.height,
                actualWidth: actual.width,
                actualHeight: actual.height
            )
        }
        try validateAttachment(
            pixelBuffer,
            key: kCVImageBufferColorPrimariesKey,
            expected: format.colorPrimaries.cmValue as CFString
        )
        try validateAttachment(
            pixelBuffer,
            key: kCVImageBufferTransferFunctionKey,
            expected: format.transferFunction.cmValue as CFString
        )
        if format.pixelStorage.usesYCbCr {
            try validateAttachment(
                pixelBuffer,
                key: kCVImageBufferYCbCrMatrixKey,
                expected: format.cmYCbCrMatrix as CFString
            )
            if let chromaLocation = format.chromaLocation {
                try validateAttachment(
                    pixelBuffer,
                    key: kCVImageBufferChromaLocationTopFieldKey,
                    expected: chromaLocation as CFString
                )
            }
        } else {
            try validateAbsentAttachment(
                pixelBuffer,
                key: kCVImageBufferYCbCrMatrixKey
            )
        }
        if let alphaMode = format.alphaMode.imageBufferValue {
            try validateAttachment(
                pixelBuffer,
                key: kCVImageBufferAlphaChannelModeKey,
                expected: alphaMode
            )
        } else {
            try validateAbsentAttachment(
                pixelBuffer,
                key: kCVImageBufferAlphaChannelModeKey
            )
        }
        try validateOptionalDataAttachment(
            pixelBuffer,
            key: kCVImageBufferMasteringDisplayColorVolumeKey,
            expected: format.masteringDisplayColorVolume
        )
        try validateOptionalDataAttachment(
            pixelBuffer,
            key: kCVImageBufferContentLightLevelInfoKey,
            expected: format.contentLightLevelInfo
        )
    }

    static func install(
        _ format: MediaVideoFormat,
        on pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution
    ) {
        let formatKeys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferAlphaChannelModeKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey
        ]
        for key in formatKeys {
            CVBufferRemoveAttachment(pixelBuffer, key)
        }
        format.installAttachments(on: pixelBuffer)
        if let chromaLocation = format.chromaLocation {
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferChromaLocationBottomFieldKey,
                chromaLocation as CFString,
                .shouldPropagate
            )
        }
        R13NV12GeometryTransfer.installCanonicalAttachments(
            on: pixelBuffer,
            resolution: resolution
        )
    }

    private static func validateAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString,
        expected: CFTypeRef
    ) throws {
        let actual = CVBufferCopyAttachment(pixelBuffer, key, nil)
        guard let actual, CFEqual(actual, expected) else {
            throw R03NV12ScalingError.colorAttachmentMismatch(
                key: key as String,
                expected: String(describing: expected),
                actual: actual.map(String.init(describing:))
            )
        }
    }

    private static func validateAbsentAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString
    ) throws {
        let actual = CVBufferCopyAttachment(pixelBuffer, key, nil)
        guard actual == nil else {
            throw R03NV12ScalingError.colorAttachmentMismatch(
                key: key as String,
                expected: "absent",
                actual: actual.map(String.init(describing:))
            )
        }
    }

    private static func validateOptionalDataAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString,
        expected: Data?
    ) throws {
        guard let expected else {
            try validateAbsentAttachment(pixelBuffer, key: key)
            return
        }
        try validateAttachment(
            pixelBuffer,
            key: key,
            expected: expected as CFData
        )
    }
}

final class R13FormatPreservingVImageScaler:
    R03NV12Scaling,
    @unchecked Sendable {
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let videoFormat: MediaVideoFormat
    let quality: R13FormatPreservingScalingQuality

    init(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat,
        quality: R13FormatPreservingScalingQuality
    ) {
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.videoFormat = videoFormat
        self.quality = quality
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: sourceResolution,
            format: videoFormat
        )
        guard CVPixelBufferGetPixelFormatType(destination)
                == videoFormat.pixelStorage.pixelFormat,
              CVPixelBufferGetWidth(destination)
                == targetResolution.width,
              CVPixelBufferGetHeight(destination)
                == targetResolution.height else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: targetResolution.width,
                expectedHeight: targetResolution.height,
                actualWidth: CVPixelBufferGetWidth(destination),
                actualHeight: CVPixelBufferGetHeight(destination)
            )
        }

        do {
            try R13PixelLayoutProcessor.scaleVImage(
                source: source,
                destination: destination,
                flags: quality.flags
            )
        } catch let error as R13PixelLayoutError {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_vimage_\(error)"
            )
        }
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        CVBufferPropagateAttachments(source, destination)
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
    }
}

final class R13ReleaseVideoFrameNormalizer: @unchecked Sendable {
    private struct PoolKey: Hashable {
        let resolution: VideoResolution
        let pixelFormat: OSType
    }

    private let nv12: any R13NV12FrameNormalizing
    private let poolLock = NSLock()
    private var pools: [PoolKey: CVPixelBufferPool] = [:]
    private let geometryTransfer = R13VideoFormatGeometryTransfer()

    init(nv12: any R13NV12FrameNormalizing) {
        self.nv12 = nv12
    }

    func normalize(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?
    ) throws -> CVPixelBuffer {
        try nv12.normalize(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            pixelAspectRatio: pixelAspectRatio
        )
    }

    func normalizeForAdaptiveScaling(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        processingResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?
    ) throws -> CVPixelBuffer {
        try nv12.normalizeForAdaptiveScaling(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            processingResolution: processingResolution,
            pixelAspectRatio: pixelAspectRatio
        )
    }

    func normalize(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?,
        videoFormat: MediaVideoFormat
    ) throws -> CVPixelBuffer {
        if videoFormat == .sdrBT709 {
            return try nv12.normalize(
                source,
                codedResolution: codedResolution,
                presentationResolution: presentationResolution,
                pixelAspectRatio: pixelAspectRatio
            )
        }
        return try normalizePreservingFormat(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            destinationResolution: presentationResolution,
            pixelAspectRatio: pixelAspectRatio,
            videoFormat: videoFormat
        )
    }

    func normalizeForAdaptiveScaling(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        processingResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?,
        videoFormat: MediaVideoFormat
    ) throws -> CVPixelBuffer {
        if videoFormat == .sdrBT709 {
            return try nv12.normalizeForAdaptiveScaling(
                source,
                codedResolution: codedResolution,
                presentationResolution: presentationResolution,
                processingResolution: processingResolution,
                pixelAspectRatio: pixelAspectRatio
            )
        }
        return try normalizePreservingFormat(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            destinationResolution: processingResolution,
            pixelAspectRatio: pixelAspectRatio,
            videoFormat: videoFormat
        )
    }

    private func normalizePreservingFormat(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        destinationResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?,
        videoFormat: MediaVideoFormat
    ) throws -> CVPixelBuffer {
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: codedResolution,
            format: videoFormat
        )
        try validatePresentationGeometry(
            source,
            expected: presentationResolution
        )
        try validatePixelAspectRatio(
            source,
            expected: pixelAspectRatio
        )
        let destination = try PixelBufferBridge.dequeue(
            from: try pool(
                resolution: destinationResolution,
                format: videoFormat
            )
        )
        let nonSquarePixels = pixelAspectRatio.map {
            $0.horizontalSpacing != $0.verticalSpacing
        } ?? false
        if codedResolution == presentationResolution,
           presentationResolution == destinationResolution,
           !nonSquarePixels {
            try copyActiveStorage(
                from: source,
                to: destination,
                format: videoFormat
            )
        } else {
            try geometryTransfer.transfer(
                from: source,
                to: destination,
                resolution: destinationResolution,
                format: videoFormat
            )
        }
        R13MediaVideoFormatContract.install(
            videoFormat,
            on: destination,
            resolution: destinationResolution
        )
        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: destinationResolution,
            format: videoFormat
        )
        return destination
    }

    private func pool(
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) throws -> CVPixelBufferPool {
        let key = PoolKey(
            resolution: resolution,
            pixelFormat: format.pixelStorage.pixelFormat
        )
        poolLock.lock()
        defer { poolLock.unlock() }
        if let existing = pools[key] {
            return existing
        }
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: format.pixelStorage.pixelFormat,
            capacity: 3
        )
        pools[key] = pool
        return pool
    }

    private func validatePresentationGeometry(
        _ source: CVPixelBuffer,
        expected: VideoResolution
    ) throws {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: source,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_source_description_\(status)"
            )
        }
        let dimensions =
            CMVideoFormatDescriptionGetPresentationDimensions(
                description,
                usePixelAspectRatio: true,
                useCleanAperture: true
            )
        let actual = VideoResolution(
            width: Int(dimensions.width.rounded()),
            height: Int(dimensions.height.rounded())
        )
        guard dimensions.width.isFinite,
              dimensions.height.isFinite,
              actual == expected else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: actual.width,
                actualHeight: actual.height
            )
        }
    }

    private func validatePixelAspectRatio(
        _ source: CVPixelBuffer,
        expected: VideoPixelAspectRatio?
    ) throws {
        let attachment = CVBufferCopyAttachment(
            source,
            kCVImageBufferPixelAspectRatioKey,
            nil
        ) as? NSDictionary
        let observed: VideoPixelAspectRatio?
        if let horizontal = attachment?[
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey
        ] as? NSNumber,
           let vertical = attachment?[
               kCVImageBufferPixelAspectRatioVerticalSpacingKey
           ] as? NSNumber {
            observed = VideoPixelAspectRatio(
                horizontalSpacing: horizontal.intValue,
                verticalSpacing: vertical.intValue
            )
        } else {
            observed = nil
        }
        if let expected {
            guard observed == expected else {
                throw R03NV12ScalingError.colorAttachmentMismatch(
                    key: kCVImageBufferPixelAspectRatioKey as String,
                    expected:
                        "\(expected.horizontalSpacing):"
                        + "\(expected.verticalSpacing)",
                    actual: observed.map {
                        "\($0.horizontalSpacing):\($0.verticalSpacing)"
                    }
                )
            }
        } else if let observed,
                  observed != VideoPixelAspectRatio(
                      horizontalSpacing: 1,
                      verticalSpacing: 1
                  ) {
            throw R03NV12ScalingError.colorAttachmentMismatch(
                key: kCVImageBufferPixelAspectRatioKey as String,
                expected: "1:1 or absent",
                actual:
                    "\(observed.horizontalSpacing):"
                    + "\(observed.verticalSpacing)"
            )
        }
    }

    private func copyActiveStorage(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        format _: MediaVideoFormat
    ) throws {
        do {
            try R13PixelLayoutProcessor.copy(
                source: source,
                destination: destination
            )
        } catch let error as R13PixelLayoutError {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_copy_\(error)"
            )
        }
    }
}

private final class R13VideoFormatGeometryTransfer:
    @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [R13ReleaseVideoFormatBinding:
        VTPixelTransferSession] = [:]

    deinit {
        lock.lock()
        for session in sessions.values {
            VTPixelTransferSessionInvalidate(session)
        }
        sessions.removeAll()
        lock.unlock()
    }

    func transfer(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let binding = R13ReleaseVideoFormatBinding(format)
        let session: VTPixelTransferSession
        if let existing = sessions[binding] {
            session = existing
        } else {
            session = try makeSession(format: format)
            sessions[binding] = session
        }
        try setDestinationCleanAperture(
            session,
            resolution: resolution
        )
        let status = VTPixelTransferSessionTransferImage(
            session,
            from: source,
            to: destination
        )
        guard status == noErr else {
            throw R03NV12ScalingError.scalingFailed(
                plane: -1,
                status: Int(status)
            )
        }
    }

    private func makeSession(
        format: MediaVideoFormat
    ) throws -> VTPixelTransferSession {
        var optionalSession: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &optionalSession
        )
        guard status == noErr, let session = optionalSession else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_transfer_create_\(status)"
            )
        }
        do {
            let squarePixels = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey
                    as String: NSNumber(value: 1),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey
                    as String: NSNumber(value: 1)
            ] as CFDictionary
            try set(
                session,
                key: kVTPixelTransferPropertyKey_ScalingMode,
                value: kVTScalingMode_Letterbox
            )
            try set(
                session,
                key:
                    kVTPixelTransferPropertyKey_DestinationPixelAspectRatio,
                value: squarePixels
            )
            try set(
                session,
                key:
                    kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                value: format.colorPrimaries.cmValue as CFString
            )
            try set(
                session,
                key:
                    kVTPixelTransferPropertyKey_DestinationTransferFunction,
                value: format.transferFunction.cmValue as CFString
            )
            if format.pixelStorage.usesYCbCr {
                try set(
                    session,
                    key:
                        kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                    value: format.cmYCbCrMatrix as CFString
                )
            }
            try set(
                session,
                key: kVTPixelTransferPropertyKey_RealTime,
                value: kCFBooleanFalse
            )
            return session
        } catch {
            VTPixelTransferSessionInvalidate(session)
            throw error
        }
    }

    private func setDestinationCleanAperture(
        _ session: VTPixelTransferSession,
        resolution: VideoResolution
    ) throws {
        let aperture = [
            kCVImageBufferCleanApertureWidthKey as String:
                NSNumber(value: resolution.width),
            kCVImageBufferCleanApertureHeightKey as String:
                NSNumber(value: resolution.height),
            kCVImageBufferCleanApertureHorizontalOffsetKey as String:
                NSNumber(value: 0),
            kCVImageBufferCleanApertureVerticalOffsetKey as String:
                NSNumber(value: 0)
        ] as CFDictionary
        try set(
            session,
            key: kVTPixelTransferPropertyKey_DestinationCleanAperture,
            value: aperture
        )
    }

    private func set(
        _ session: VTPixelTransferSession,
        key: CFString,
        value: CFTypeRef
    ) throws {
        let status = VTSessionSetProperty(
            session,
            key: key,
            value: value
        )
        guard status == noErr else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_format_transfer_property_\(status)"
            )
        }
    }
}
