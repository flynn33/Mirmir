import CoreVideo
import Darwin
import Foundation

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
