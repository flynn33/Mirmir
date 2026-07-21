import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

enum R03CoreImageScalingMode: String, CaseIterable, Hashable, Sendable {
    case lanczos = "r03.core-image.lanczos"
    case bicubic = "r03.core-image.bicubic"

    var subjectID: R03BaselineSubjectID {
        switch self {
        case .lanczos:
            return .coreImageLanczos
        case .bicubic:
            return .coreImageBicubic
        }
    }
}

extension R03DeterministicBackend {
    static func makeCoreImage(
        mode: R03CoreImageScalingMode,
        route: R03ScaleRoute,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        try R03DeterministicBackend(
            subjectID: mode.subjectID,
            route: route,
            scalerFactory: { sourceResolution, targetResolution in
                try requireExactCoreImageRoute(
                    route,
                    sourceResolution: sourceResolution,
                    targetResolution: targetResolution
                )
                return R03CoreImageScaler(mode: mode, route: route)
            },
            outputReleaseObserver: outputReleaseObserver
        )
    }

    private static func requireExactCoreImageRoute(
        _ route: R03ScaleRoute,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution
    ) throws {
        guard sourceResolution == route.canonicalSourceResolution else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: route.canonicalSourceResolution.width,
                expectedHeight: route.canonicalSourceResolution.height,
                actualWidth: sourceResolution.width,
                actualHeight: sourceResolution.height
            )
        }
        guard targetResolution == route.canonicalTargetResolution else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: route.canonicalTargetResolution.width,
                expectedHeight: route.canonicalTargetResolution.height,
                actualWidth: targetResolution.width,
                actualHeight: targetResolution.height
            )
        }
    }
}

final class R03CoreImageScaler: R03NV12Scaling, @unchecked Sendable {
    let mode: R03CoreImageScalingMode
    let route: R03ScaleRoute

    private enum FailureCode: Int {
        case nonuniformScale = -1
        case filterOutputUnavailable = -2
    }

    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution
    private let context: CIContext
    private let executionLock = NSLock()

    init(mode: R03CoreImageScalingMode, route: R03ScaleRoute) {
        self.mode = mode
        self.route = route
        sourceResolution = route.canonicalSourceResolution
        targetResolution = route.canonicalTargetResolution
        context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false
        ])
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
        executionLock.lock()
        defer { executionLock.unlock() }

        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try R03NV12Contract.validate(
            pixelBuffer: source,
            resolution: sourceResolution
        )
        try R03NV12Contract.validate(
            pixelBuffer: destination,
            resolution: targetResolution
        )

        let sourceLockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: false,
                status: sourceLockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        let destinationLockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            throw R03NV12ScalingError.pixelBufferLockFailed(
                destination: true,
                status: destinationLockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        try scalePlane(
            source: source,
            destination: destination,
            plane: 0,
            format: .L8
        )
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try scalePlane(
            source: source,
            destination: destination,
            plane: 1,
            format: .RG8
        )
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
    }

    func reset() {
        clearCaches()
    }

    func finish() {
        clearCaches()
    }

    private func clearCaches() {
        executionLock.lock()
        context.clearCaches()
        executionLock.unlock()
    }

    private func scalePlane(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        plane: Int,
        format: CIFormat
    ) throws {
        guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(source, plane) else {
            throw R03NV12ScalingError.missingPlaneBaseAddress(plane: plane)
        }
        guard let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(
            destination,
            plane
        ) else {
            throw R03NV12ScalingError.missingPlaneBaseAddress(plane: plane)
        }

        let sourceWidth = CVPixelBufferGetWidthOfPlane(source, plane)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(source, plane)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let destinationWidth = CVPixelBufferGetWidthOfPlane(destination, plane)
        let destinationHeight = CVPixelBufferGetHeightOfPlane(destination, plane)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            destination,
            plane
        )
        guard destinationWidth * sourceHeight == destinationHeight * sourceWidth else {
            throw R03NV12ScalingError.scalingFailed(
                plane: plane,
                status: FailureCode.nonuniformScale.rawValue
            )
        }

        let sourceData = Data(
            bytes: sourceBaseAddress,
            count: sourceBytesPerRow * sourceHeight
        )
        let sourceImage = CIImage(
            bitmapData: sourceData,
            bytesPerRow: sourceBytesPerRow,
            size: CGSize(width: sourceWidth, height: sourceHeight),
            format: format,
            colorSpace: nil
        )
        let scale = Float(destinationHeight) / Float(sourceHeight)
        let filtered: CIImage?
        switch mode {
        case .lanczos:
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = sourceImage
            filter.scale = scale
            filter.aspectRatio = 1
            filtered = filter.outputImage
        case .bicubic:
            let filter = CIFilter.bicubicScaleTransform()
            filter.inputImage = sourceImage
            filter.scale = scale
            filter.aspectRatio = 1
            filter.parameterB = 0
            filter.parameterC = 0.75
            filtered = filter.outputImage
        }
        guard let filtered else {
            throw R03NV12ScalingError.scalingFailed(
                plane: plane,
                status: FailureCode.filterOutputUnavailable.rawValue
            )
        }

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: destinationWidth,
            height: destinationHeight
        )
        context.render(
            filtered.cropped(to: bounds),
            toBitmap: destinationBaseAddress,
            rowBytes: destinationBytesPerRow,
            bounds: bounds,
            format: format,
            colorSpace: nil
        )
    }
}
