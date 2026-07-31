import Accelerate
import CoreVideo
import Foundation

enum R03VImageScalingMode: String, CaseIterable, Hashable, Sendable {
    case lanczos3 = "r03.vimage.lanczos-3"
    case lanczos5 = "r03.vimage.lanczos-5"

    var subjectID: R03BaselineSubjectID {
        switch self {
        case .lanczos3:
            return .vImageLanczos3
        case .lanczos5:
            return .vImageLanczos5
        }
    }

    var flags: vImage_Flags {
        switch self {
        case .lanczos3:
            return vImage_Flags(kvImageEdgeExtend)
        case .lanczos5:
            return vImage_Flags(kvImageEdgeExtend | kvImageHighQualityResampling)
        }
    }
}

final class R03VImageScaler: R03NV12Scaling, @unchecked Sendable {
    let mode: R03VImageScalingMode
    let route: R03ScaleRoute?

    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution

    init(mode: R03VImageScalingMode, route: R03ScaleRoute) {
        self.mode = mode
        self.route = route
        sourceResolution = route.canonicalSourceResolution
        targetResolution = route.canonicalTargetResolution
    }

    init(
        mode: R03VImageScalingMode,
        adaptivePlan: R13AdaptiveScalePlan
    ) {
        self.mode = mode
        route = nil
        sourceResolution = adaptivePlan.processingSourceResolution
        targetResolution = adaptivePlan.targetResolution
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws {
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
            plane: 0
        )
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        try scalePlane(
            source: source,
            destination: destination,
            plane: 1
        )
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
    }

    private func scalePlane(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        plane: Int
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

        var sourceBuffer = vImage_Buffer(
            data: sourceBaseAddress,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, plane)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, plane)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        )
        var destinationBuffer = vImage_Buffer(
            data: destinationBaseAddress,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(destination, plane)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(destination, plane)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
        )
        let status: vImage_Error
        if plane == 0 {
            status = vImageScale_Planar8(
                &sourceBuffer,
                &destinationBuffer,
                nil,
                mode.flags
            )
        } else {
            status = vImageScale_CbCr8(
                &sourceBuffer,
                &destinationBuffer,
                nil,
                mode.flags
            )
        }
        guard status == kvImageNoError else {
            throw R03NV12ScalingError.scalingFailed(
                plane: plane,
                status: Int(status)
            )
        }
    }
}
