import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

// swiftlint:disable file_length

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

    static func makeProductQualifiedCoreImage(
        mode: R03CoreImageScalingMode,
        route: R03ScaleRoute,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        let kind: R13ReleaseScalerKind = mode == .lanczos
            ? .coreImageLanczos
            : .coreImageBicubic
        return try R03DeterministicBackend(
            subjectID: kind.subjectID,
            route: route,
            admissionProfile: .productQualifiedReleaseScaler(kind),
            productAdmissionAuthorization:
                R03A11ProductAdmissionAuthorization(),
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

// swiftlint:disable:next type_body_length
final class R03CoreImageScaler: R03NV12Scaling, @unchecked Sendable {
    let mode: R03CoreImageScalingMode
    let route: R03ScaleRoute?
    let videoFormat: MediaVideoFormat

    private enum FailureCode: Int {
        case filterOutputUnavailable = -1
        case componentBufferUnavailable = -2
        case componentBufferSizeMismatch = -3
    }

    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution
    private let context: CIContext
    private let executionLock = NSLock()

    init(mode: R03CoreImageScalingMode, route: R03ScaleRoute) {
        self.mode = mode
        self.route = route
        videoFormat = .sdrBT709
        sourceResolution = route.canonicalSourceResolution
        targetResolution = route.canonicalTargetResolution
        context = Self.makeContext()
    }

    init(
        mode: R03CoreImageScalingMode,
        adaptivePlan: R13AdaptiveScalePlan
    ) {
        self.mode = mode
        route = nil
        videoFormat = .sdrBT709
        sourceResolution = adaptivePlan.processingSourceResolution
        targetResolution = adaptivePlan.targetResolution
        context = Self.makeContext()
    }

    init(
        mode: R03CoreImageScalingMode,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat
    ) throws {
        let layout = try Self.requireRepresentableLayout(
            for: videoFormat
        )
        try layout.validateGeometry(
            width: sourceResolution.width,
            height: sourceResolution.height
        )
        try layout.validateGeometry(
            width: targetResolution.width,
            height: targetResolution.height
        )
        self.mode = mode
        route = nil
        self.videoFormat = videoFormat
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        context = Self.makeContext()
    }

    private static func makeContext() -> CIContext {
        CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .workingFormat: CIFormat.RGBAf,
            .cacheIntermediates: false
        ])
    }

    private static func requireRepresentableLayout(
        for videoFormat: MediaVideoFormat
    ) throws -> R13PixelLayout {
        let layout: R13PixelLayout
        do {
            layout = try R13PixelLayoutRegistry.layout(
                for: videoFormat.pixelStorage.pixelFormat
            )
        } catch {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r03_core_image_unrepresentable_storage_"
                    + videoFormat.pixelStorage.rawValue
            )
        }
        guard layout.planes.allSatisfy({
            $0.componentsPerElement > 0
                && ($0.bytesPerComponent == 1
                    || $0.bytesPerComponent == 2)
        }) else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "r03_core_image_unrepresentable_plane_"
                    + videoFormat.pixelStorage.rawValue
            )
        }
        return layout
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
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: sourceResolution,
            format: videoFormat
        )
        try validateDestination(destination)

        let layout = try Self.requireRepresentableLayout(
            for: videoFormat
        )
        try layout.validate(source)
        try layout.validate(destination)
        try scaleLocked(
            source: source,
            destination: destination,
            layout: layout,
            cancellation: cancellation
        )
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            destination,
            format: videoFormat
        )

        R13PixelLayoutProcessor.copyAttachments(
            source: source,
            destination: destination
        )
        R13MediaVideoFormatContract.install(
            videoFormat,
            on: destination,
            resolution: targetResolution
        )
        try R13MediaVideoFormatContract.validate(
            destination,
            resolution: targetResolution,
            format: videoFormat
        )
    }

    func reset() {
        clearCaches()
    }

    func finish() {
        clearCaches()
    }

    func cancel() {
        clearCaches()
    }

    private func clearCaches() {
        executionLock.lock()
        context.clearCaches()
        executionLock.unlock()
    }

    private func validateDestination(
        _ destination: CVPixelBuffer
    ) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(destination)
        guard actualFormat == videoFormat.pixelStorage.pixelFormat else {
            throw R03NV12ScalingError.invalidPixelFormat(
                expected: videoFormat.pixelStorage.pixelFormat,
                actual: actualFormat
            )
        }
        let actualWidth = CVPixelBufferGetWidth(destination)
        let actualHeight = CVPixelBufferGetHeight(destination)
        guard actualWidth == targetResolution.width,
              actualHeight == targetResolution.height else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: targetResolution.width,
                expectedHeight: targetResolution.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
        try videoFormat.validate(pixelBuffer: destination)
    }

    private func scaleLocked(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        layout: R13PixelLayout,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
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

        try scalePlanes(
            source: source,
            destination: destination,
            layout: layout,
            cancellation: cancellation
        )
        try R13PixelLayoutProcessor.enforceCodeBoundsLocked(
            destination,
            layout: layout
        )
    }

    private func scalePlanes(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        layout: R13PixelLayout,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
        for (planeIndex, plane) in layout.planes.enumerated() {
            let sourceBaseAddress = try R13PixelBufferAccess.baseAddress(
                of: source,
                layout: layout,
                plane: planeIndex
            )
            let destinationBaseAddress = try R13PixelBufferAccess.baseAddress(
                of: destination,
                layout: layout,
                plane: planeIndex
            )
            let sourceWidth = R13PixelBufferAccess.width(
                of: source,
                layout: layout,
                plane: planeIndex
            )
            let sourceHeight = R13PixelBufferAccess.height(
                of: source,
                layout: layout,
                plane: planeIndex
            )
            let sourceBytesPerRow = R13PixelBufferAccess.rowBytes(
                of: source,
                layout: layout,
                plane: planeIndex
            )
            let destinationWidth = R13PixelBufferAccess.width(
                of: destination,
                layout: layout,
                plane: planeIndex
            )
            let destinationHeight = R13PixelBufferAccess.height(
                of: destination,
                layout: layout,
                plane: planeIndex
            )
            let destinationBytesPerRow = R13PixelBufferAccess.rowBytes(
                of: destination,
                layout: layout,
                plane: planeIndex
            )

            for component in 0..<plane.componentsPerElement {
                guard !cancellation.isCancelled else {
                    throw R03NV12ScalingError.operationCancelled
                }
                let sourceData = try componentData(
                    baseAddress: sourceBaseAddress,
                    rowBytes: sourceBytesPerRow,
                    width: sourceWidth,
                    height: sourceHeight,
                    plane: plane,
                    planeIndex: planeIndex,
                    component: component
                )
                let outputData = try renderComponent(
                    sourceData,
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    destinationWidth: destinationWidth,
                    destinationHeight: destinationHeight,
                    bytesPerComponent: plane.bytesPerComponent,
                    planeIndex: planeIndex
                )
                try writeComponentData(
                    outputData,
                    baseAddress: destinationBaseAddress,
                    rowBytes: destinationBytesPerRow,
                    width: destinationWidth,
                    height: destinationHeight,
                    plane: plane,
                    planeIndex: planeIndex,
                    component: component
                )
            }
        }
    }

    private func componentData(
        baseAddress: UnsafeMutableRawPointer,
        rowBytes: Int,
        width: Int,
        height: Int,
        plane: R13PixelPlaneLayout,
        planeIndex: Int,
        component: Int
    ) throws -> Data {
        let byteCount = try componentByteCount(
            width: width,
            height: height,
            bytesPerComponent: plane.bytesPerComponent
        )
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                throw R03NV12ScalingError.scalingFailed(
                    plane: planeIndex,
                    status: FailureCode.componentBufferUnavailable.rawValue
                )
            }
            let componentBytes = plane.bytesPerComponent
            let elementBytes =
                plane.componentsPerElement * componentBytes
            for row in 0..<height {
                let sourceRow = baseAddress.advanced(
                    by: row * rowBytes
                )
                let destinationRow = destination.advanced(
                    by: row * width * componentBytes
                )
                for column in 0..<width {
                    destinationRow
                        .advanced(by: column * componentBytes)
                        .copyMemory(
                            from: sourceRow.advanced(
                                by: column * elementBytes
                                    + component * componentBytes
                            ),
                            byteCount: componentBytes
                        )
                }
            }
        }
        return data
    }

    private func renderComponent(
        _ sourceData: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int,
        bytesPerComponent: Int,
        planeIndex: Int
    ) throws -> Data {
        let format: CIFormat = bytesPerComponent == 1
            ? .L8
            : .L16
        let sourceRowBytes = try componentByteCount(
            width: sourceWidth,
            height: 1,
            bytesPerComponent: bytesPerComponent
        )
        let sourceImage = CIImage(
            bitmapData: sourceData,
            bytesPerRow: sourceRowBytes,
            size: CGSize(width: sourceWidth, height: sourceHeight),
            format: format,
            colorSpace: nil
        )
        let verticalScale =
            Float(destinationHeight) / Float(sourceHeight)
        let horizontalScale =
            Float(destinationWidth) / Float(sourceWidth)
        let aspectRatio = horizontalScale / verticalScale
        let filtered: CIImage?
        switch mode {
        case .lanczos:
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = sourceImage.clampedToExtent()
            filter.scale = verticalScale
            filter.aspectRatio = aspectRatio
            filtered = filter.outputImage
        case .bicubic:
            let filter = CIFilter.bicubicScaleTransform()
            filter.inputImage = sourceImage.clampedToExtent()
            filter.scale = verticalScale
            filter.aspectRatio = aspectRatio
            filter.parameterB = 0
            filter.parameterC = 0.75
            filtered = filter.outputImage
        }
        guard let filtered else {
            throw R03NV12ScalingError.scalingFailed(
                plane: planeIndex,
                status: FailureCode.filterOutputUnavailable.rawValue
            )
        }

        let destinationRowBytes = try componentByteCount(
            width: destinationWidth,
            height: 1,
            bytesPerComponent: bytesPerComponent
        )
        let outputByteCount = try componentByteCount(
            width: destinationWidth,
            height: destinationHeight,
            bytesPerComponent: bytesPerComponent
        )
        let renderBounds = CGRect(
            x: 0,
            y: 0,
            width: destinationWidth,
            height: destinationHeight
        )
        var output = Data(count: outputByteCount)
        try output.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw R03NV12ScalingError.scalingFailed(
                    plane: planeIndex,
                    status: FailureCode.componentBufferUnavailable.rawValue
                )
            }
            let destination = CIRenderDestination(
                bitmapData: baseAddress,
                width: destinationWidth,
                height: destinationHeight,
                bytesPerRow: destinationRowBytes,
                format: format
            )
            destination.colorSpace = nil
            destination.alphaMode = .none
            destination.isDithered = false
            destination.isClamped = false
            destination.isFlipped = false
            do {
                let task = try context.startTask(
                    toRender: filtered.cropped(to: renderBounds),
                    to: destination
                )
                _ = try task.waitUntilCompleted()
            } catch {
                throw R03NV12ScalingError.scalingFailed(
                    plane: planeIndex,
                    status: (error as NSError).code
                )
            }
        }
        return output
    }

    private func writeComponentData(
        _ data: Data,
        baseAddress: UnsafeMutableRawPointer,
        rowBytes: Int,
        width: Int,
        height: Int,
        plane: R13PixelPlaneLayout,
        planeIndex: Int,
        component: Int
    ) throws {
        let expectedByteCount = try componentByteCount(
            width: width,
            height: height,
            bytesPerComponent: plane.bytesPerComponent
        )
        guard data.count == expectedByteCount else {
            throw R03NV12ScalingError.scalingFailed(
                plane: planeIndex,
                status: FailureCode.componentBufferSizeMismatch.rawValue
            )
        }
        try data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else {
                throw R03NV12ScalingError.scalingFailed(
                    plane: planeIndex,
                    status: FailureCode.componentBufferUnavailable.rawValue
                )
            }
            let componentBytes = plane.bytesPerComponent
            let elementBytes =
                plane.componentsPerElement * componentBytes
            for row in 0..<height {
                let sourceRow = source.advanced(
                    by: row * width * componentBytes
                )
                let destinationRow = baseAddress.advanced(
                    by: row * rowBytes
                )
                for column in 0..<width {
                    destinationRow
                        .advanced(
                            by: column * elementBytes
                                + component * componentBytes
                        )
                        .copyMemory(
                            from: sourceRow.advanced(
                                by: column * componentBytes
                            ),
                            byteCount: componentBytes
                        )
                }
            }
        }
    }

    private func componentByteCount(
        width: Int,
        height: Int,
        bytesPerComponent: Int
    ) throws -> Int {
        let (pixelCount, pixelOverflow) =
            width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) =
            pixelCount.multipliedReportingOverflow(
                by: bytesPerComponent
            )
        guard width > 0,
              height > 0,
              !pixelOverflow,
              !byteOverflow else {
            throw R13PixelLayoutError.arithmeticOverflow
        }
        return byteCount
    }
}
