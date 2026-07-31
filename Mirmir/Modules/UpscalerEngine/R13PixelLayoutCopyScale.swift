import Accelerate
import CoreVideo
import Foundation

extension R13PixelLayoutProcessor {
    static func copy(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
    ) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        try layout.validate(source)
        try layout.validate(destination)
        try validateMatchingGeometry([source, destination])
        try lockReadOnly(source)
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        try lockWritable(destination)
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        try copyLocked(
            source: source,
            destination: destination,
            layout: layout
        )
        copyAttachments(source: source, destination: destination)
    }

    static func scaleVImage(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        flags: vImage_Flags
    ) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        try layout.validate(source)
        try layout.validate(destination)
        try lockReadOnly(source)
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        try lockWritable(destination)
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        for (index, plane) in layout.planes.enumerated() {
            try scalePlaneVImage(
                source: source,
                destination: destination,
                layout: layout,
                plane: plane,
                planeIndex: index,
                flags: flags
            )
        }
        try enforceCodeBoundsLocked(
            destination,
            layout: layout
        )
        copyAttachments(source: source, destination: destination)
    }

    private static func copyLocked(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        layout: R13PixelLayout
    ) throws {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        for (index, plane) in layout.planes.enumerated() {
            let sourceBase = try R13PixelBufferAccess.baseAddress(
                of: source,
                layout: layout,
                plane: index
            )
            let destinationBase = try R13PixelBufferAccess.baseAddress(
                of: destination,
                layout: layout,
                plane: index
            )
            let sourceStride = R13PixelBufferAccess.rowBytes(
                of: source,
                layout: layout,
                plane: index
            )
            let destinationStride = R13PixelBufferAccess.rowBytes(
                of: destination,
                layout: layout,
                plane: index
            )
            let activeRowBytes = try plane.activeBytesPerRow(
                frameWidth: width
            )
            let rowCount = plane.height(for: height)
            for row in 0..<rowCount {
                destinationBase
                    .advanced(by: row * destinationStride)
                    .copyMemory(
                        from: sourceBase.advanced(
                            by: row * sourceStride
                        ),
                        byteCount: activeRowBytes
                    )
            }
        }
    }

    private static func scalePlaneVImage(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        layout: R13PixelLayout,
        plane: R13PixelPlaneLayout,
        planeIndex: Int,
        flags: vImage_Flags
    ) throws {
        var sourceBuffer = try vImageBuffer(
            source,
            layout: layout,
            planeIndex: planeIndex
        )
        var destinationBuffer = try vImageBuffer(
            destination,
            layout: layout,
            planeIndex: planeIndex
        )
        let status = scaleVImageBuffer(
            source: &sourceBuffer,
            destination: &destinationBuffer,
            plane: plane,
            flags: flags
        )
        guard status == kvImageNoError else {
            throw R13PixelLayoutError.scalingFailed(
                plane: planeIndex,
                status: Int(status)
            )
        }
    }

    private static func vImageBuffer(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        planeIndex: Int
    ) throws -> vImage_Buffer {
        vImage_Buffer(
            data: try R13PixelBufferAccess.baseAddress(
                of: pixelBuffer,
                layout: layout,
                plane: planeIndex
            ),
            height: vImagePixelCount(
                R13PixelBufferAccess.height(
                    of: pixelBuffer,
                    layout: layout,
                    plane: planeIndex
                )
            ),
            width: vImagePixelCount(
                R13PixelBufferAccess.width(
                    of: pixelBuffer,
                    layout: layout,
                    plane: planeIndex
                )
            ),
            rowBytes: R13PixelBufferAccess.rowBytes(
                of: pixelBuffer,
                layout: layout,
                plane: planeIndex
            )
        )
    }

    private static func scaleVImageBuffer(
        source: UnsafePointer<vImage_Buffer>,
        destination: UnsafePointer<vImage_Buffer>,
        plane: R13PixelPlaneLayout,
        flags: vImage_Flags
    ) -> vImage_Error {
        switch (
            plane.bytesPerComponent,
            plane.componentsPerElement
        ) {
        case (1, 1):
            return vImageScale_Planar8(
                source,
                destination,
                nil,
                flags
            )
        case (1, 2):
            return vImageScale_CbCr8(
                source,
                destination,
                nil,
                flags
            )
        case (1, 4):
            return vImageScale_ARGB8888(
                source,
                destination,
                nil,
                flags
            )
        case (2, 1):
            return vImageScale_Planar16U(
                source,
                destination,
                nil,
                flags
            )
        case (2, 2):
            return vImageScale_CbCr16U(
                source,
                destination,
                nil,
                flags
            )
        case (2, 4):
            return vImageScale_ARGB16U(
                source,
                destination,
                nil,
                flags
            )
        default:
            return kvImageInvalidParameter
        }
    }
}
