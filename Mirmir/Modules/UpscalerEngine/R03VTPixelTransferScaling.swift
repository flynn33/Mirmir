import CoreVideo
import Foundation
import VideoToolbox

final class R03VTPixelTransferScaler: R03NV12Scaling, @unchecked Sendable {
    let route: R03ScaleRoute

    private let sourceResolution: VideoResolution
    private let targetResolution: VideoResolution
    private let lock = NSLock()
    private var transferSession: VTPixelTransferSession?

    init(route: R03ScaleRoute) throws {
        self.route = route
        sourceResolution = route.canonicalSourceResolution
        targetResolution = route.canonicalTargetResolution

        var session: VTPixelTransferSession?
        let creationStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        )
        guard creationStatus == noErr, let session else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "vt_pixel_transfer_session_create_\(creationStatus)"
            )
        }

        do {
            try Self.setRequiredProperties(on: session)
            transferSession = session
        } catch {
            VTPixelTransferSessionInvalidate(session)
            throw error
        }
    }

    deinit {
        invalidate()
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

        lock.lock()
        defer { lock.unlock() }
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        guard let transferSession else {
            throw R03NV12ScalingError.runtimeUnavailable(
                "vt_pixel_transfer_session_invalidated"
            )
        }

        let status = VTPixelTransferSessionTransferImage(
            transferSession,
            from: source,
            to: destination
        )
        guard status == noErr else {
            throw R03NV12ScalingError.scalingFailed(
                plane: -1,
                status: Int(status)
            )
        }
        guard !cancellation.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
    }

    func finish() {
        invalidate()
    }

    func cancel() {
        invalidate()
    }

    private func invalidate() {
        lock.lock()
        let session = transferSession
        transferSession = nil
        if let session {
            VTPixelTransferSessionInvalidate(session)
        }
        lock.unlock()
    }

    private static func setRequiredProperties(
        on session: VTPixelTransferSession
    ) throws {
        let properties: [(key: CFString, value: CFTypeRef)] = [
            (kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Normal),
            (
                kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                kCVImageBufferColorPrimaries_ITU_R_709_2
            ),
            (
                kVTPixelTransferPropertyKey_DestinationTransferFunction,
                kCVImageBufferTransferFunction_ITU_R_709_2
            ),
            (
                kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ),
            (kVTPixelTransferPropertyKey_RealTime, kCFBooleanFalse)
        ]
        for property in properties {
            let status = VTSessionSetProperty(
                session,
                key: property.key,
                value: property.value
            )
            guard status == noErr else {
                throw R03NV12ScalingError.runtimeUnavailable(
                    "vt_pixel_transfer_property_\(status)"
                )
            }
        }
    }
}

extension R03DeterministicBackend {
    static func makeVTPixelTransfer(
        route: R03ScaleRoute,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        try R03DeterministicBackend(
            subjectID: .vtPixelTransfer,
            route: route,
            scalerFactory: { _, _ in
                try R03VTPixelTransferScaler(route: route)
            },
            outputReleaseObserver: outputReleaseObserver
        )
    }
}
