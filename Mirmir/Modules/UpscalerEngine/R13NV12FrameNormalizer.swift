import CoreVideo
import Darwin
import Foundation

protocol R13NV12FrameNormalizing: Sendable {
    func normalize(
        _ source: CVPixelBuffer,
        resolution: VideoResolution
    ) throws -> CVPixelBuffer
}

final class R13NV12FrameNormalizer: R13NV12FrameNormalizing, @unchecked Sendable {
    private let poolLock = NSLock()
    private var pools: [VideoResolution: CVPixelBufferPool] = [:]

    func normalize(
        _ source: CVPixelBuffer,
        resolution: VideoResolution
    ) throws -> CVPixelBuffer {
        try validateSourceLayout(source, resolution: resolution)
        let destination = try PixelBufferBridge.dequeue(
            from: try pool(for: resolution)
        )
        try copyActivePlaneBytes(
            from: source,
            to: destination,
            resolution: resolution
        )
        R03NV12Contract.installColorAttachments(on: destination)
        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: resolution
        )
        return destination
    }

    private func pool(
        for resolution: VideoResolution
    ) throws -> CVPixelBufferPool {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let existing = pools[resolution] {
            return existing
        }
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: R03NV12Contract.pixelFormat,
            capacity: 3
        )
        pools[resolution] = pool
        return pool
    }

    private func validateSourceLayout(
        _ source: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(source)
        guard actualFormat == R03NV12Contract.pixelFormat else {
            throw R03NV12ScalingError.invalidPixelFormat(
                expected: R03NV12Contract.pixelFormat,
                actual: actualFormat
            )
        }
        let actualWidth = CVPixelBufferGetWidth(source)
        let actualHeight = CVPixelBufferGetHeight(source)
        guard actualWidth == resolution.width,
              actualHeight == resolution.height else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: resolution.width,
                expectedHeight: resolution.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        let planeCount = CVPixelBufferGetPlaneCount(source)
        guard planeCount == 2 else {
            throw R03NV12ScalingError.invalidPlaneCount(
                expected: 2,
                actual: planeCount
            )
        }
        try validatePlane(
            source,
            plane: 0,
            expectedWidth: resolution.width,
            expectedHeight: resolution.height
        )
        try validatePlane(
            source,
            plane: 1,
            expectedWidth: resolution.width / 2,
            expectedHeight: resolution.height / 2
        )
    }

    private func validatePlane(
        _ source: CVPixelBuffer,
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        let actualWidth = CVPixelBufferGetWidthOfPlane(source, plane)
        let actualHeight = CVPixelBufferGetHeightOfPlane(source, plane)
        guard actualWidth == expectedWidth,
              actualHeight == expectedHeight else {
            throw R03NV12ScalingError.invalidPlaneDimensions(
                plane: plane,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
    }

    private func copyActivePlaneBytes(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        let sourceStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: false,
                status: sourceStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let destinationStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: true,
                status: destinationStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        try copyPlane(
            0,
            from: source,
            to: destination,
            activeBytesPerRow: resolution.width,
            rowCount: resolution.height
        )
        try copyPlane(
            1,
            from: source,
            to: destination,
            activeBytesPerRow: resolution.width,
            rowCount: resolution.height / 2
        )
    }

    private func copyPlane(
        _ plane: Int,
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        activeBytesPerRow: Int,
        rowCount: Int
    ) throws {
        guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane) else {
            throw R03NV12ScalingError.missingPlaneBaseAddress(plane: plane)
        }
        guard let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
            destination,
            plane
        ) else {
            throw R03NV12ScalingError.missingPlaneBaseAddress(plane: plane)
        }
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            destination,
            plane
        )
        guard sourceBytesPerRow >= activeBytesPerRow,
              destinationBytesPerRow >= activeBytesPerRow else {
            throw R03NV12ScalingError.invalidPlaneDimensions(
                plane: plane,
                expectedWidth: activeBytesPerRow,
                expectedHeight: rowCount,
                actualWidth: min(sourceBytesPerRow, destinationBytesPerRow),
                actualHeight: rowCount
            )
        }

        for row in 0..<rowCount {
            memcpy(
                destinationBase.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * sourceBytesPerRow),
                activeBytesPerRow
            )
        }
    }
}
