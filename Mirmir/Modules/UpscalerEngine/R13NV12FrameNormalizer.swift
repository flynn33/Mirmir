import CoreMedia
import CoreVideo
import Darwin
import Foundation

protocol R13NV12FrameNormalizing: Sendable {
    func normalize(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?
    ) throws -> CVPixelBuffer

    func normalizeForAdaptiveScaling(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        processingResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?
    ) throws -> CVPixelBuffer
}

extension R13NV12FrameNormalizing {
    func normalizeForAdaptiveScaling(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        processingResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?
    ) throws -> CVPixelBuffer {
        guard processingResolution == presentationResolution else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: presentationResolution.width,
                expectedHeight: presentationResolution.height,
                actualWidth: processingResolution.width,
                actualHeight: processingResolution.height
            )
        }
        return try normalize(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            pixelAspectRatio: pixelAspectRatio
        )
    }
}

final class R13NV12FrameNormalizer: R13NV12FrameNormalizing, @unchecked Sendable {
    private let poolLock = NSLock()
    private var pools: [VideoResolution: CVPixelBufferPool] = [:]
    private let geometryTransfer = R13NV12GeometryTransfer()

    func normalize(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?
    ) throws -> CVPixelBuffer {
        try normalize(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            destinationResolution: presentationResolution,
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
        try normalize(
            source,
            codedResolution: codedResolution,
            presentationResolution: presentationResolution,
            destinationResolution: processingResolution,
            pixelAspectRatio: pixelAspectRatio
        )
    }

    private func normalize(
        _ source: CVPixelBuffer,
        codedResolution: VideoResolution,
        presentationResolution: VideoResolution,
        destinationResolution: VideoResolution,
        pixelAspectRatio: VideoPixelAspectRatio?
    ) throws -> CVPixelBuffer {
        try validateSourceLayout(
            source,
            resolution: codedResolution
        )
        try validateSourcePixelAspectRatio(
            source,
            expected: pixelAspectRatio
        )
        try validateSourcePresentationGeometry(
            source,
            expected: presentationResolution
        )
        let destination = try PixelBufferBridge.dequeue(
            from: try pool(for: destinationResolution)
        )
        let hasNonSquarePixels = pixelAspectRatio.map {
            $0.horizontalSpacing != $0.verticalSpacing
        } ?? false
        if codedResolution == presentationResolution,
           presentationResolution == destinationResolution,
           !hasNonSquarePixels {
            try copyActivePlaneBytes(
                from: source,
                to: destination,
                resolution: codedResolution
            )
        } else {
            try geometryTransfer.transfer(
                from: source,
                to: destination,
                resolution: destinationResolution
            )
        }
        R13NV12GeometryTransfer.installCanonicalAttachments(
            on: destination,
            resolution: destinationResolution
        )
        R03NV12Contract.installColorAttachments(on: destination)
        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: destinationResolution
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

    private func validateSourcePixelAspectRatio(
        _ source: CVPixelBuffer,
        expected: VideoPixelAspectRatio?
    ) throws {
        let actual = sourcePixelAspectRatio(source)
        if let expected {
            guard actual == expected else {
                throw R03NV12ScalingError.colorAttachmentMismatch(
                    key: kCVImageBufferPixelAspectRatioKey as String,
                    expected:
                        "\(expected.horizontalSpacing):"
                        + "\(expected.verticalSpacing)",
                    actual: actual.map {
                        "\($0.horizontalSpacing):\($0.verticalSpacing)"
                    }
                )
            }
            return
        }
        guard actual == nil
                || actual == VideoPixelAspectRatio(
                    horizontalSpacing: 1,
                    verticalSpacing: 1
                ) else {
            throw R03NV12ScalingError.colorAttachmentMismatch(
                key: kCVImageBufferPixelAspectRatioKey as String,
                expected: "1:1 or absent",
                actual: actual.map {
                    "\($0.horizontalSpacing):\($0.verticalSpacing)"
                }
            )
        }
    }

    private func sourcePixelAspectRatio(
        _ source: CVPixelBuffer
    ) -> VideoPixelAspectRatio? {
        guard let dictionary = CVBufferCopyAttachment(
            source,
            kCVImageBufferPixelAspectRatioKey,
            nil
        ) as? NSDictionary,
              let horizontal = dictionary[
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey
              ] as? NSNumber,
              let vertical = dictionary[
                kCVImageBufferPixelAspectRatioVerticalSpacingKey
              ] as? NSNumber else {
            return nil
        }
        return VideoPixelAspectRatio(
            horizontalSpacing: horizontal.intValue,
            verticalSpacing: vertical.intValue
        )
    }

    private func validateSourcePresentationGeometry(
        _ source: CVPixelBuffer,
        expected: VideoResolution
    ) throws {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: source,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r13_source_format_description_create_\(status)"
            )
        }
        let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(
            formatDescription,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
        guard dimensions.width.isFinite,
              dimensions.height.isFinite,
              dimensions.width >= 1,
              dimensions.height >= 1 else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: 0,
                actualHeight: 0
            )
        }
        let actual = VideoResolution(
            width: Int(dimensions.width.rounded()),
            height: Int(dimensions.height.rounded())
        )
        guard actual == expected else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: expected.width,
                expectedHeight: expected.height,
                actualWidth: actual.width,
                actualHeight: actual.height
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
