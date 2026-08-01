import Accelerate
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

// swiftlint:disable file_length

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

enum R13PremultipliedAlphaError:
    Error,
    Equatable,
    Sendable {
    case missingComponent(R13PixelPlaneRole, Int)
    case unsupportedStorage(MediaVideoPixelStorage)
}

/// Reconciles an output buffer with its declared premultiplied-alpha
/// contract without changing alpha samples, format identity, or attachments.
/// Straight-alpha and alpha-free formats are intentionally left untouched.
enum R13PremultipliedAlphaOutputPostcondition {
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

    private struct YCbCrLocations {
        let luma: ComponentLocation
        let cb: ComponentLocation
        let cr: ComponentLocation
    }

    private struct MatrixCoefficients {
        let red: Double
        let blue: Double

        var green: Double { 1 - red - blue }
    }

    static func reconcile(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat
    ) throws {
        guard format.alphaMode == .premultiplied else { return }

        try format.validate(pixelBuffer: pixelBuffer)
        let layout = try R13PixelLayoutRegistry.layout(
            for: format.pixelStorage.pixelFormat
        )
        try layout.validate(pixelBuffer)
        try R13PixelLayoutProcessor.validateStoredCodes(pixelBuffer)

        let alpha = try alphaLocation(layout: layout)
        if format.pixelStorage.usesYCbCr {
            _ = try yCbCrLocations(
                layout: layout,
                storage: format.pixelStorage
            )
        } else {
            try validateBGRALayout(layout, format: format)
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R13PixelLayoutError.lockFailed(
                destination: true,
                status: lockStatus
            )
        }
        do {
            if format.pixelStorage.usesYCbCr {
                try reconcileYCbCrLocked(
                    pixelBuffer,
                    layout: layout,
                    format: format,
                    alpha: alpha
                )
            } else {
                try reconcileBGRALocked(
                    pixelBuffer,
                    layout: layout,
                    alpha: alpha
                )
            }
        } catch {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            throw error
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        try R13PixelLayoutProcessor.validateStoredCodes(pixelBuffer)
    }
}

private extension R13PremultipliedAlphaOutputPostcondition {
    private static func reconcileBGRALocked(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        alpha: ComponentLocation
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        for row in 0..<height {
            for column in 0..<width {
                let alphaValue = try normalizedComponent(
                    pixelBuffer,
                    layout: layout,
                    location: alpha,
                    column: column,
                    row: row
                )
                for component in 0..<3 {
                    let location = ComponentLocation(
                        planeIndex: 0,
                        componentIndex: component
                    )
                    let color = try normalizedComponent(
                        pixelBuffer,
                        layout: layout,
                        location: location,
                        column: column,
                        row: row
                    )
                    try writeNormalized(
                        min(color, alphaValue),
                        pixelBuffer: pixelBuffer,
                        layout: layout,
                        location: location,
                        column: column,
                        row: row
                    )
                }
            }
        }
    }

    private static func reconcileYCbCrLocked(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        format: MediaVideoFormat,
        alpha: ComponentLocation
    ) throws {
        let locations = try yCbCrLocations(
            layout: layout,
            storage: format.pixelStorage
        )
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        for row in 0..<height {
            for column in 0..<width {
                let alphaValue = try normalizedComponent(
                    pixelBuffer,
                    layout: layout,
                    location: alpha,
                    column: column,
                    row: row
                )
                let rgb = try encodedRGB(
                    pixelBuffer,
                    layout: layout,
                    format: format,
                    locations: locations,
                    column: column,
                    row: row
                )
                let premultiplied = RGB(
                    red: min(rgb.red, alphaValue),
                    green: min(rgb.green, alphaValue),
                    blue: min(rgb.blue, alphaValue)
                )
                let encoded = yCbCr(
                    premultiplied,
                    primaries: format.colorPrimaries
                )
                try writeNormalized(
                    encoded.luma,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: locations.luma,
                    column: column,
                    row: row
                )
                try writeNormalized(
                    encoded.cb + 0.5,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: locations.cb,
                    column: column,
                    row: row
                )
                try writeNormalized(
                    encoded.cr + 0.5,
                    pixelBuffer: pixelBuffer,
                    layout: layout,
                    location: locations.cr,
                    column: column,
                    row: row
                )
            }
        }
    }

    private static func encodedRGB(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        format: MediaVideoFormat,
        locations: YCbCrLocations,
        column: Int,
        row: Int
    ) throws -> RGB {
        let luma = try normalizedComponent(
            pixelBuffer,
            layout: layout,
            location: locations.luma,
            column: column,
            row: row
        )
        let cb = try normalizedComponent(
            pixelBuffer,
            layout: layout,
            location: locations.cb,
            column: column,
            row: row
        ) - 0.5
        let cr = try normalizedComponent(
            pixelBuffer,
            layout: layout,
            location: locations.cr,
            column: column,
            row: row
        ) - 0.5
        let matrix = coefficients(for: format.colorPrimaries)
        return RGB(
            red: clampUnit(luma + 2 * (1 - matrix.red) * cr),
            green: clampUnit(
                luma
                    - 2 * matrix.blue * (1 - matrix.blue)
                        / matrix.green * cb
                    - 2 * matrix.red * (1 - matrix.red)
                        / matrix.green * cr
            ),
            blue: clampUnit(luma + 2 * (1 - matrix.blue) * cb)
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

    private static func yCbCrLocations(
        layout: R13PixelLayout,
        storage: MediaVideoPixelStorage
    ) throws -> YCbCrLocations {
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
        let chromaPlane = layout.planes[cb.planeIndex]
        guard chromaPlane.widthDivisor == 1,
              chromaPlane.heightDivisor == 1,
              cb.componentIndex + 1 < chromaPlane.componentsPerElement else {
            throw R13PremultipliedAlphaError
                .unsupportedStorage(storage)
        }
        return YCbCrLocations(
            luma: luma,
            cb: cb,
            cr: ComponentLocation(
                planeIndex: cb.planeIndex,
                componentIndex: cb.componentIndex + 1
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
            return ComponentLocation(
                planeIndex: planeIndex,
                componentIndex: 0
            )
        }
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == packedRole }
        ) {
            return ComponentLocation(
                planeIndex: planeIndex,
                componentIndex: packedComponent
            )
        }
        throw R13PremultipliedAlphaError
            .missingComponent(role, 0)
    }

    private static func alphaLocation(
        layout: R13PixelLayout
    ) throws -> ComponentLocation {
        if let planeIndex = layout.planes.firstIndex(where: { $0.role == .alpha }) {
            return ComponentLocation(
                planeIndex: planeIndex,
                componentIndex: 0
            )
        }
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == .packedBGRA }
        ) {
            return ComponentLocation(
                planeIndex: planeIndex,
                componentIndex: 3
            )
        }
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == .packedAYCbCr }
        ) {
            return ComponentLocation(
                planeIndex: planeIndex,
                componentIndex: 0
            )
        }
        throw R13PremultipliedAlphaError
            .missingComponent(.alpha, 0)
    }

    private static func validateBGRALayout(
        _ layout: R13PixelLayout,
        format: MediaVideoFormat
    ) throws {
        guard layout.planes.count == 1,
              layout.planes[0].role == .packedBGRA,
              layout.planes[0].componentsPerElement == 4 else {
            throw R13PremultipliedAlphaError
                .unsupportedStorage(format.pixelStorage)
        }
    }

    private static func normalizedComponent(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        location: ComponentLocation,
        column: Int,
        row: Int
    ) throws -> Double {
        let plane = layout.planes[location.planeIndex]
        guard location.componentIndex < plane.componentsPerElement else {
            throw R13PremultipliedAlphaError
                .missingComponent(plane.role, location.componentIndex)
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
        let planeColumn = column / plane.widthDivisor
        let planeRow = row / plane.heightDivisor
        let offset = planeColumn * plane.componentsPerElement
            + location.componentIndex
        let stored: UInt16
        if plane.bytesPerComponent == 1 {
            stored = UInt16(
                base.advanced(by: planeRow * rowBytes)
                    .assumingMemoryBound(to: UInt8.self)[offset]
            )
        } else {
            stored = base.advanced(by: planeRow * rowBytes)
                .assumingMemoryBound(to: UInt16.self)[offset]
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
        guard location.componentIndex < plane.componentsPerElement else {
            throw R13PremultipliedAlphaError
                .missingComponent(plane.role, location.componentIndex)
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
        let planeColumn = column / plane.widthDivisor
        let planeRow = row / plane.heightDivisor
        let offset = planeColumn * plane.componentsPerElement
            + location.componentIndex
        if plane.bytesPerComponent == 1 {
            base.advanced(by: planeRow * rowBytes)
                .assumingMemoryBound(to: UInt8.self)[offset] = UInt8(code)
        } else {
            base.advanced(by: planeRow * rowBytes)
                .assumingMemoryBound(to: UInt16.self)[offset] =
                code << UInt16(plane.storedCodeShift)
        }
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

    private static func clampUnit(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func clampSignedHalf(_ value: Double) -> Double {
        min(max(value, -0.5), 0.5)
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
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            destination,
            format: videoFormat
        )
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

/// Scales a frame through VideoToolbox while retaining its declared pixel
/// storage, color representation, dynamic-range metadata, and alpha semantics.
/// No alternate scaling framework is invoked by this implementation.
final class R13FormatPreservingVTPixelTransferScaler:
    R03NV12Scaling,
    @unchecked Sendable {
    let sourceResolution: VideoResolution
    let targetResolution: VideoResolution
    let videoFormat: MediaVideoFormat

    private let geometryTransfer = R13VideoFormatGeometryTransfer()

    init(
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat
    ) {
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.videoFormat = videoFormat
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try Self.validateStorageAndGeometry(
            source,
            resolution: sourceResolution,
            format: videoFormat
        )
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: sourceResolution,
            format: videoFormat
        )
        try Self.validateStorageAndGeometry(
            destination,
            resolution: targetResolution,
            format: videoFormat
        )
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }

        try geometryTransfer.transfer(
            from: source,
            to: destination,
            resolution: targetResolution,
            format: videoFormat
        )
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }

        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            destination,
            format: videoFormat
        )
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

    func reset() {
        geometryTransfer.invalidate()
    }

    func finish() {
        geometryTransfer.invalidate()
    }

    func cancel() {
        geometryTransfer.invalidate()
    }

    private static func validateStorageAndGeometry(
        _ pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution,
        format: MediaVideoFormat
    ) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == format.pixelStorage.pixelFormat else {
            throw R03NV12ScalingError.invalidPixelFormat(
                expected: format.pixelStorage.pixelFormat,
                actual: actualFormat
            )
        }
        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard actualWidth == resolution.width,
              actualHeight == resolution.height else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: resolution.width,
                expectedHeight: resolution.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        let actualPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let expectedPlaneCount = format.pixelStorage.expectedPlaneCount
        guard actualPlaneCount == expectedPlaneCount else {
            throw R03NV12ScalingError.invalidPlaneCount(
                expected: expectedPlaneCount,
                actual: actualPlaneCount
            )
        }
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
        invalidate()
    }

    func invalidate() {
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
