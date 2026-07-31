import CoreVideo
import Darwin
import Foundation
import VideoToolbox

extension R13NV12Frame {
    static func captureTightActivePlanes(
        from pixelBuffer: CVPixelBuffer
    ) throws -> R13NV12Frame {
        let tight: R13TightPixelFrame
        do {
            tight = try R13TightPixelFrame(capturing: pixelBuffer)
        } catch let error as R13PixelLayoutError {
            switch error {
            case .unsupportedPixelFormat(let pixelFormat):
                throw R13NV12FrameCacheError
                    .unsupportedPixelFormat(pixelFormat)
            default:
                throw R13NV12FrameCacheError
                    .inaccessiblePlane(String(describing: error))
            }
        }
        let chroma =
            tight.planes.count > 1 ? tight.planes[1] : Data()
        let auxiliary =
            tight.planes.count > 2
            ? Array(tight.planes.dropFirst(2))
            : []
        return try R13NV12Frame(
            width: tight.width,
            height: tight.height,
            pixelFormat: tight.pixelFormat,
            luma: tight.planes[0],
            chroma: chroma,
            auxiliaryPlanes: auxiliary
        )
    }

    func makeVideoRangePixelBuffer() throws -> CVPixelBuffer {
        guard pixelFormat
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw R13NV12FrameCacheError.unsupportedPixelFormat(
                pixelFormat
            )
        }
        let pixelBuffer = try makePixelBuffer()
        Self.attachCanonicalColorMetadata(to: pixelBuffer)
        return pixelBuffer
    }

    func makePixelBuffer(
        videoFormat: MediaVideoFormat
    ) throws -> CVPixelBuffer {
        guard videoFormat.pixelStorage.pixelFormat == pixelFormat else {
            throw R13NV12FrameCacheError.unsupportedPixelFormat(
                pixelFormat
            )
        }
        let pixelBuffer = try makePixelBuffer()
        videoFormat.installAttachments(on: pixelBuffer)
        try videoFormat.validate(pixelBuffer: pixelBuffer)
        return pixelBuffer
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        let planes =
            [luma]
            + (chroma.isEmpty ? [] : [chroma])
            + auxiliaryPlanes
        do {
            return try R13TightPixelFrame(
                width: width,
                height: height,
                pixelFormat: pixelFormat,
                planes: planes
            ).makePixelBuffer()
        } catch let error as R13PixelLayoutError {
            switch error {
            case .pixelBufferCreationFailed(let status):
                throw R13NV12FrameCacheError
                    .pixelBufferCreationFailed(status)
            case .unsupportedPixelFormat(let format):
                throw R13NV12FrameCacheError
                    .unsupportedPixelFormat(format)
            default:
                throw R13NV12FrameCacheError
                    .inaccessiblePlane(String(describing: error))
            }
        }
    }

    private static func copyActivePackedBuffer(
        _ pixelBuffer: CVPixelBuffer,
        activeBytesPerRow: Int,
        activeRowCount: Int,
        outputByteCount: Int
    ) throws -> Data {
        guard let baseAddress =
                CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R13NV12FrameCacheError.inaccessiblePlane("packed")
        }
        return try copyRows(
            baseAddress,
            storedBytesPerRow:
                CVPixelBufferGetBytesPerRow(pixelBuffer),
            storedHeight: CVPixelBufferGetHeight(pixelBuffer),
            activeBytesPerRow: activeBytesPerRow,
            activeRowCount: activeRowCount,
            outputByteCount: outputByteCount,
            role: "packed"
        )
    }

    private static func copyActivePlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        activeBytesPerRow: Int,
        activeRowCount: Int,
        outputByteCount: Int,
        role: String
    ) throws -> Data {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            plane
        ) else {
            throw R13NV12FrameCacheError.inaccessiblePlane(role)
        }
        return try copyRows(
            baseAddress,
            storedBytesPerRow:
                CVPixelBufferGetBytesPerRowOfPlane(
                    pixelBuffer,
                    plane
                ),
            storedHeight:
                CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
            activeBytesPerRow: activeBytesPerRow,
            activeRowCount: activeRowCount,
            outputByteCount: outputByteCount,
            role: role
        )
    }

    private static func copyRows(
        _ baseAddress: UnsafeMutableRawPointer,
        storedBytesPerRow: Int,
        storedHeight: Int,
        activeBytesPerRow: Int,
        activeRowCount: Int,
        outputByteCount: Int,
        role: String
    ) throws -> Data {
        guard storedBytesPerRow >= activeBytesPerRow,
              storedHeight >= activeRowCount else {
            throw R13NV12FrameCacheError.inaccessiblePlane(role)
        }
        var output = Data(count: outputByteCount)
        output.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else {
                return
            }
            for row in 0..<activeRowCount {
                destinationBase
                    .advanced(by: row * activeBytesPerRow)
                    .copyMemory(
                        from: baseAddress.advanced(
                            by: row * storedBytesPerRow
                        ),
                        byteCount: activeBytesPerRow
                    )
            }
        }
        return output
    }

    private static func copyTightPackedBuffer(
        _ source: Data,
        to pixelBuffer: CVPixelBuffer,
        activeBytesPerRow: Int,
        activeRowCount: Int
    ) throws {
        guard let destination =
                CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R13NV12FrameCacheError.inaccessiblePlane("packed")
        }
        try copyTightRows(
            source,
            to: destination,
            destinationBytesPerRow:
                CVPixelBufferGetBytesPerRow(pixelBuffer),
            destinationHeight: CVPixelBufferGetHeight(pixelBuffer),
            activeBytesPerRow: activeBytesPerRow,
            activeRowCount: activeRowCount,
            role: "packed"
        )
    }

    private static func copyTightPlane(
        _ source: Data,
        to pixelBuffer: CVPixelBuffer,
        plane: Int,
        activeBytesPerRow: Int,
        activeRowCount: Int,
        role: String
    ) throws {
        guard let destination = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            plane
        ) else {
            throw R13NV12FrameCacheError.inaccessiblePlane(role)
        }
        try copyTightRows(
            source,
            to: destination,
            destinationBytesPerRow:
                CVPixelBufferGetBytesPerRowOfPlane(
                    pixelBuffer,
                    plane
                ),
            destinationHeight:
                CVPixelBufferGetHeightOfPlane(pixelBuffer, plane),
            activeBytesPerRow: activeBytesPerRow,
            activeRowCount: activeRowCount,
            role: role
        )
    }

    private static func copyTightRows(
        _ source: Data,
        to destination: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        destinationHeight: Int,
        activeBytesPerRow: Int,
        activeRowCount: Int,
        role: String
    ) throws {
        guard destinationBytesPerRow >= activeBytesPerRow,
              destinationHeight >= activeRowCount else {
            throw R13NV12FrameCacheError.inaccessiblePlane(role)
        }
        memset(
            destination,
            0,
            destinationBytesPerRow * destinationHeight
        )
        try source.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress else {
                throw R13NV12FrameCacheError.inaccessiblePlane(role)
            }
            for row in 0..<activeRowCount {
                destination
                    .advanced(by: row * destinationBytesPerRow)
                    .copyMemory(
                        from: sourceBase.advanced(
                            by: row * activeBytesPerRow
                        ),
                        byteCount: activeBytesPerRow
                    )
            }
        }
    }

    private static func attachCanonicalColorMetadata(
        to pixelBuffer: CVPixelBuffer
    ) {
        let attachments: [(CFString, CFTypeRef)] = [
            (
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2
            ),
            (
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2
            ),
            (
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ),
            (
                kCVImageBufferChromaLocationTopFieldKey,
                kCVImageBufferChromaLocation_Left
            ),
            (
                kCVImageBufferChromaLocationBottomFieldKey,
                kCVImageBufferChromaLocation_Left
            )
        ]
        for (key, value) in attachments {
            CVBufferSetAttachment(
                pixelBuffer,
                key,
                value,
                .shouldPropagate
            )
        }
    }
}

final class R13NV12GeometryTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var transferSession: VTPixelTransferSession?

    deinit {
        lock.lock()
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
        transferSession = nil
        lock.unlock()
    }

    func transfer(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let session = try transferSessionLocked()
        try Self.setDestinationCleanAperture(
            on: session,
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

    static func installCanonicalAttachments(
        on pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution
    ) {
        let pixelAspectRatio = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String:
                NSNumber(value: 1),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String:
                NSNumber(value: 1)
        ] as CFDictionary
        let cleanAperture = [
            kCVImageBufferCleanApertureWidthKey as String:
                NSNumber(value: resolution.width),
            kCVImageBufferCleanApertureHeightKey as String:
                NSNumber(value: resolution.height),
            kCVImageBufferCleanApertureHorizontalOffsetKey as String:
                NSNumber(value: 0),
            kCVImageBufferCleanApertureVerticalOffsetKey as String:
                NSNumber(value: 0)
        ] as CFDictionary
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferPixelAspectRatioKey,
            pixelAspectRatio,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCleanApertureKey,
            cleanAperture,
            .shouldPropagate
        )
        CVBufferRemoveAttachment(
            pixelBuffer,
            kCVImageBufferPreferredCleanApertureKey
        )
        CVBufferRemoveAttachment(
            pixelBuffer,
            kCVImageBufferDisplayDimensionsKey
        )
    }

    private func transferSessionLocked() throws -> VTPixelTransferSession {
        if let transferSession {
            return transferSession
        }
        var candidate: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &candidate
        )
        guard status == noErr, let candidate else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_pixel_transfer_session_create_\(status)"
            )
        }
        do {
            try Self.configureTransferSession(candidate)
            transferSession = candidate
            return candidate
        } catch {
            VTPixelTransferSessionInvalidate(candidate)
            throw error
        }
    }

    private static func configureTransferSession(
        _ session: VTPixelTransferSession
    ) throws {
        let squarePixelAspectRatio = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String:
                NSNumber(value: 1),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String:
                NSNumber(value: 1)
        ] as CFDictionary
        let properties: [(key: CFString, value: CFTypeRef)] = [
            (
                kVTPixelTransferPropertyKey_ScalingMode,
                kVTScalingMode_Letterbox
            ),
            (
                kVTPixelTransferPropertyKey_DestinationPixelAspectRatio,
                squarePixelAspectRatio
            ),
            (
                kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                kCVImageBufferColorPrimaries_ITU_R_709_2
            ),
            (
                kVTPixelTransferPropertyKey_DestinationTransferFunction,
                kCVImageBufferTransferFunction_ITU_R_709_2
            ),
            (
                kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ),
            (
                kVTPixelTransferPropertyKey_RealTime,
                kCFBooleanFalse
            )
        ]
        for property in properties {
            try setProperty(
                on: session,
                key: property.key,
                value: property.value
            )
        }
    }

    private static func setDestinationCleanAperture(
        on session: VTPixelTransferSession,
        resolution: VideoResolution
    ) throws {
        let cleanAperture = [
            kCVImageBufferCleanApertureWidthKey as String:
                NSNumber(value: resolution.width),
            kCVImageBufferCleanApertureHeightKey as String:
                NSNumber(value: resolution.height),
            kCVImageBufferCleanApertureHorizontalOffsetKey as String:
                NSNumber(value: 0),
            kCVImageBufferCleanApertureVerticalOffsetKey as String:
                NSNumber(value: 0)
        ] as CFDictionary
        try setProperty(
            on: session,
            key: kVTPixelTransferPropertyKey_DestinationCleanAperture,
            value: cleanAperture
        )
    }

    private static func setProperty(
        on session: VTPixelTransferSession,
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
                "r13_pixel_transfer_property_\(status)"
            )
        }
    }
}
