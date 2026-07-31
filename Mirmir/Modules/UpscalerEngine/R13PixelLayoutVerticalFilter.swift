import CoreVideo
import Foundation

private struct R13PixelVerticalPlaneBuffers {
    let source: UnsafeMutableRawPointer
    let sourceStride: Int
    let destination: UnsafeMutableRawPointer
    let destinationStride: Int
    let componentCount: Int
    let rowCount: Int
}

extension R13PixelLayoutProcessor {
    /// Applies a deterministic vertical 1/4–1/2–1/4 filter to every stored
    /// component. Edge rows use edge extension. Ten-bit MSB-aligned formats
    /// are decoded before filtering and requantized on output.
    static func verticalFilter(
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
        for (index, plane) in layout.planes.enumerated() {
            try filterPlane(
                source: source,
                destination: destination,
                layout: layout,
                plane: plane,
                planeIndex: index
            )
        }
        copyAttachments(source: source, destination: destination)
    }

    private static func filterPlane(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        layout: R13PixelLayout,
        plane: R13PixelPlaneLayout,
        planeIndex: Int
    ) throws {
        let buffers = R13PixelVerticalPlaneBuffers(
            source: try R13PixelBufferAccess.baseAddress(
                of: source,
                layout: layout,
                plane: planeIndex
            ),
            sourceStride: R13PixelBufferAccess.rowBytes(
                of: source,
                layout: layout,
                plane: planeIndex
            ),
            destination: try R13PixelBufferAccess.baseAddress(
                of: destination,
                layout: layout,
                plane: planeIndex
            ),
            destinationStride: R13PixelBufferAccess.rowBytes(
                of: destination,
                layout: layout,
                plane: planeIndex
            ),
            componentCount:
                plane.width(for: CVPixelBufferGetWidth(source))
                    * plane.componentsPerElement,
            rowCount:
                plane.height(for: CVPixelBufferGetHeight(source))
        )
        if plane.bytesPerComponent == 1 {
            filter8BitPlane(buffers, plane: plane)
        } else {
            filter16BitPlane(buffers, plane: plane)
        }
    }

    private static func filter8BitPlane(
        _ buffers: R13PixelVerticalPlaneBuffers,
        plane: R13PixelPlaneLayout
    ) {
        for row in 0..<buffers.rowCount {
            let north = row8(
                buffers.source,
                stride: buffers.sourceStride,
                row: max(row - 1, 0)
            )
            let center = row8(
                buffers.source,
                stride: buffers.sourceStride,
                row: row
            )
            let south = row8(
                buffers.source,
                stride: buffers.sourceStride,
                row: min(row + 1, buffers.rowCount - 1)
            )
            let output = row8(
                buffers.destination,
                stride: buffers.destinationStride,
                row: row
            )
            for component in 0..<buffers.componentCount {
                let bounds = plane.componentBounds[
                    component % plane.componentsPerElement
                ]
                let filtered =
                    (
                        UInt64(north[component])
                        + UInt64(center[component]) * 2
                        + UInt64(south[component])
                        + 2
                    ) / 4
                output[component] = UInt8(
                    min(
                        max(filtered, UInt64(bounds.minimum)),
                        UInt64(bounds.maximum)
                    )
                )
            }
        }
    }

    private static func filter16BitPlane(
        _ buffers: R13PixelVerticalPlaneBuffers,
        plane: R13PixelPlaneLayout
    ) {
        let shift = UInt16(plane.storedCodeShift)
        for row in 0..<buffers.rowCount {
            let north = row16(
                buffers.source,
                stride: buffers.sourceStride,
                row: max(row - 1, 0)
            )
            let center = row16(
                buffers.source,
                stride: buffers.sourceStride,
                row: row
            )
            let south = row16(
                buffers.source,
                stride: buffers.sourceStride,
                row: min(row + 1, buffers.rowCount - 1)
            )
            let output = row16(
                buffers.destination,
                stride: buffers.destinationStride,
                row: row
            )
            for component in 0..<buffers.componentCount {
                let bounds = plane.componentBounds[
                    component % plane.componentsPerElement
                ]
                let northCode =
                    UInt64(north[component] >> shift)
                let centerCode =
                    UInt64(center[component] >> shift)
                let southCode =
                    UInt64(south[component] >> shift)
                let weightedSum =
                    northCode + centerCode * 2 + southCode + 2
                let filtered = weightedSum / 4
                let bounded = min(
                    max(filtered, UInt64(bounds.minimum)),
                    UInt64(bounds.maximum)
                )
                output[component] = UInt16(bounded) << shift
            }
        }
    }

    private static func row8(
        _ base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int
    ) -> UnsafeMutablePointer<UInt8> {
        base.advanced(by: row * stride)
            .assumingMemoryBound(to: UInt8.self)
    }

    private static func row16(
        _ base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int
    ) -> UnsafeMutablePointer<UInt16> {
        base.advanced(by: row * stride)
            .assumingMemoryBound(to: UInt16.self)
    }
}
