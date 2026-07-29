import CoreVideo
import Darwin
import Foundation
import VideoToolbox

extension R13NV12Frame {
    static func captureTightActivePlanes(
        from pixelBuffer: CVPixelBuffer
    ) throws -> R13NV12Frame {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw R13NV12FrameCacheError.unsupportedPixelFormat(pixelFormat)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let counts = try expectedPlaneByteCounts(width: width, height: height)
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw R13NV12FrameCacheError.inaccessiblePlane("plane_count")
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw R13NV12FrameCacheError.inaccessiblePlane("lock")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        let luma = try copyActivePlane(
            pixelBuffer,
            plane: 0,
            activeBytesPerRow: width,
            activeRowCount: height,
            outputByteCount: counts.luma,
            role: "luma"
        )
        let chroma = try copyActivePlane(
            pixelBuffer,
            plane: 1,
            activeBytesPerRow: width,
            activeRowCount: height / 2,
            outputByteCount: counts.chroma,
            role: "chroma"
        )
        return try R13NV12Frame(
            width: width,
            height: height,
            luma: luma,
            chroma: chroma
        )
    }

    func makeVideoRangePixelBuffer() throws -> CVPixelBuffer {
        var optionalPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &optionalPixelBuffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer = optionalPixelBuffer else {
            throw R13NV12FrameCacheError.pixelBufferCreationFailed(status)
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R13NV12FrameCacheError.inaccessiblePlane("lock")
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        try Self.copyTightPlane(
            luma,
            to: pixelBuffer,
            plane: 0,
            activeBytesPerRow: width,
            activeRowCount: height,
            role: "luma"
        )
        try Self.copyTightPlane(
            chroma,
            to: pixelBuffer,
            plane: 1,
            activeBytesPerRow: width,
            activeRowCount: height / 2,
            role: "chroma"
        )
        Self.attachCanonicalColorMetadata(to: pixelBuffer)
        return pixelBuffer
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
        let storedBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            plane
        )
        let storedHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
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
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            plane
        )
        let destinationHeight = CVPixelBufferGetHeightOfPlane(
            pixelBuffer,
            plane
        )
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
