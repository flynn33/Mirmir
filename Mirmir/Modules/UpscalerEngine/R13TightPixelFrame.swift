import CoreVideo
import Foundation

struct R13TightPixelFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let planes: [Data]

    init(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        planes: [Data]
    ) throws {
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        let expected = try layout.activePlaneByteCounts(
            width: width,
            height: height
        )
        guard planes.count == expected.count else {
            throw R13PixelLayoutError.planePayloadCountMismatch(
                expected: expected.count,
                actual: planes.count
            )
        }
        for index in planes.indices
        where planes[index].count != expected[index] {
            throw R13PixelLayoutError.planePayloadByteCountMismatch(
                plane: index,
                expected: expected[index],
                actual: planes[index].count
            )
        }
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.planes = planes
    }

    init(capturing pixelBuffer: CVPixelBuffer) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        try layout.validate(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard status == kCVReturnSuccess else {
            throw R13PixelLayoutError.lockFailed(
                destination: false,
                status: status
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        var payloads: [Data] = []
        payloads.reserveCapacity(layout.planes.count)
        for (index, plane) in layout.planes.enumerated() {
            let base = try R13PixelBufferAccess.baseAddress(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let sourceRowBytes = R13PixelBufferAccess.rowBytes(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let activeRowBytes = try plane.activeBytesPerRow(
                frameWidth: width
            )
            let rowCount = plane.height(for: height)
            var data = Data(count: activeRowBytes * rowCount)
            data.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.baseAddress else {
                    return
                }
                for row in 0..<rowCount {
                    destinationBase
                        .advanced(by: row * activeRowBytes)
                        .copyMemory(
                            from: base.advanced(
                                by: row * sourceRowBytes
                            ),
                            byteCount: activeRowBytes
                        )
                }
            }
            payloads.append(data)
        }
        try self.init(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            planes: payloads
        )
    }

    var tightRawData: Data {
        var result = Data(
            capacity: planes.reduce(0) { $0 + $1.count }
        )
        for plane in planes {
            result.append(plane)
        }
        return result
    }

    func makePixelBuffer(
        attributes: CFDictionary? = nil
    ) throws -> CVPixelBuffer {
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer = optionalBuffer else {
            throw R13PixelLayoutError.pixelBufferCreationFailed(status)
        }
        try layout.validate(pixelBuffer)
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R13PixelLayoutError.lockFailed(
                destination: true,
                status: lockStatus
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        for (index, plane) in layout.planes.enumerated() {
            let destination = try R13PixelBufferAccess.baseAddress(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let destinationRowBytes = R13PixelBufferAccess.rowBytes(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let activeRowBytes = try plane.activeBytesPerRow(
                frameWidth: width
            )
            let rowCount = plane.height(for: height)
            memset(destination, 0, destinationRowBytes * rowCount)
            planes[index].withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress else {
                    return
                }
                for row in 0..<rowCount {
                    destination
                        .advanced(by: row * destinationRowBytes)
                        .copyMemory(
                            from: sourceBase.advanced(
                                by: row * activeRowBytes
                            ),
                            byteCount: activeRowBytes
                        )
                }
            }
        }
        return pixelBuffer
    }
}
