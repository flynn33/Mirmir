import Foundation
import CoreVideo

@available(macOS 15.4, *)
final class ASHDeterministicUpscaleBackend: @unchecked Sendable {
    private let scale: Int
    private var previousSource: ASHImage?
    private var previousState: ASHState?
    private var previousReconstruction: ASHImage?

    init(scale: Int = ASHReconstruction.defaultScale) {
        self.scale = scale
    }

    func reset() {
        previousSource = nil
        previousState = nil
        previousReconstruction = nil
    }

    func process(source: CVPixelBuffer, into destination: CVPixelBuffer) async throws {
        try Task.checkCancellation()

        let current = try Self.extractLumaImage(from: source)
        let result = try ASHReferencePipeline.mapPatch(
            current: current,
            previous: previousSource,
            previousState: previousState,
            previousReconstruction: previousReconstruction,
            scale: scale,
            topK: 1
        )
        guard let selected = result.selected.first else {
            throw UpscalerEngineError.strategyFailed("ASH reconstruction produced no selected candidate")
        }

        try Self.write(reconstruction: selected.reconstruction, sourceChroma: source, to: destination)
        previousSource = current
        previousState = result.sourceState
        previousReconstruction = selected.reconstruction
    }

    private static func extractLumaImage(from pixelBuffer: CVPixelBuffer) throws -> ASHImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let width = planeCount > 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planeCount > 0 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let stride = planeCount > 0 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = planeCount > 0
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)

        guard let baseAddress else {
            throw UpscalerEngineError.strategyFailed("ASH backend could not access source luma plane")
        }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var values: [Double] = []
        values.reserveCapacity(width * height)
        for row in 0..<height {
            let rowBase = bytes.advanced(by: row * stride)
            for column in 0..<width {
                values.append(Double(rowBase[column]) / 255.0)
            }
        }
        return try ASHImage(width: width, height: height, channels: 1, values: values)
    }

    private static func write(reconstruction: ASHImage, sourceChroma source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        try writeLuma(reconstruction, to: destination)
        writeChroma(from: source, to: destination)
    }

    private static func writeLuma(_ image: ASHImage, to destination: CVPixelBuffer) throws {
        let planeCount = CVPixelBufferGetPlaneCount(destination)
        let width = planeCount > 0 ? CVPixelBufferGetWidthOfPlane(destination, 0) : CVPixelBufferGetWidth(destination)
        let height = planeCount > 0 ? CVPixelBufferGetHeightOfPlane(destination, 0) : CVPixelBufferGetHeight(destination)
        let stride = planeCount > 0 ? CVPixelBufferGetBytesPerRowOfPlane(destination, 0) : CVPixelBufferGetBytesPerRow(destination)
        let baseAddress = planeCount > 0
            ? CVPixelBufferGetBaseAddressOfPlane(destination, 0)
            : CVPixelBufferGetBaseAddress(destination)

        guard let baseAddress else {
            throw UpscalerEngineError.strategyFailed("ASH backend could not access destination luma plane")
        }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let imageRow = min(row, image.height - 1)
            let rowBase = bytes.advanced(by: row * stride)
            for column in 0..<width {
                let imageColumn = min(column, image.width - 1)
                let value = image.value(row: imageRow, column: imageColumn)
                rowBase[column] = UInt8(min(255.0, max(0.0, (value * 255.0).rounded())))
            }
        }
    }

    private static func writeChroma(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        let sourcePlanes = CVPixelBufferGetPlaneCount(source)
        let destinationPlanes = CVPixelBufferGetPlaneCount(destination)
        guard sourcePlanes > 1, destinationPlanes > 1,
              let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            fillNeutralChroma(destination)
            return
        }

        let sourceWidth = CVPixelBufferGetWidthOfPlane(source, 1)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(source, 1)
        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let destinationWidth = CVPixelBufferGetWidthOfPlane(destination, 1)
        let destinationHeight = CVPixelBufferGetHeightOfPlane(destination, 1)
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        let sourceBytes = sourceBase.assumingMemoryBound(to: UInt8.self)
        let destinationBytes = destinationBase.assumingMemoryBound(to: UInt8.self)
        let bytesPerPixel = 2

        for row in 0..<destinationHeight {
            let sourceRow = min(sourceHeight - 1, row * sourceHeight / max(destinationHeight, 1))
            let sourceRowBase = sourceBytes.advanced(by: sourceRow * sourceStride)
            let destinationRowBase = destinationBytes.advanced(by: row * destinationStride)
            for column in 0..<destinationWidth {
                let sourceColumn = min(sourceWidth - 1, column * sourceWidth / max(destinationWidth, 1))
                let sourceOffset = sourceColumn * bytesPerPixel
                let destinationOffset = column * bytesPerPixel
                destinationRowBase[destinationOffset] = sourceRowBase[sourceOffset]
                destinationRowBase[destinationOffset + 1] = sourceRowBase[sourceOffset + 1]
            }
        }
    }

    private static func fillNeutralChroma(_ destination: CVPixelBuffer) {
        let destinationPlanes = CVPixelBufferGetPlaneCount(destination)
        guard destinationPlanes > 1,
              let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            return
        }
        let destinationHeight = CVPixelBufferGetHeightOfPlane(destination, 1)
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        memset(destinationBase, 128, destinationHeight * destinationStride)
    }
}
