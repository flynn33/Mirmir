import CoreVideo
import Foundation

enum R03NV12ScalingError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
    case invalidPixelFormat(expected: OSType, actual: OSType)
    case invalidDimensions(
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case invalidPlaneCount(expected: Int, actual: Int)
    case invalidPlaneDimensions(
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case colorDescriptionMismatch(field: String, expected: String, actual: String)
    case colorAttachmentMismatch(key: String, expected: String, actual: String?)
    case pixelBufferLockFailed(destination: Bool, status: CVReturn)
    case missingPlaneBaseAddress(plane: Int)
    case scalingFailed(plane: Int, status: Int)
    case operationCancelled
}

protocol R03NV12Scaling: AnyObject, Sendable {
    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) throws

    func reset()
    func finish()
    func cancel()
}

extension R03NV12Scaling {
    func reset() {}
    func finish() {}
    func cancel() {}
}

typealias R03NV12ScalerFactory = @Sendable (
    _ sourceResolution: VideoResolution,
    _ targetResolution: VideoResolution
) throws -> any R03NV12Scaling

typealias R03OutputReleaseObserver = @Sendable (_ identity: String) -> Void

enum R03NV12Contract {
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    static let colorPrimaries = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
    static let transferFunction = kCVImageBufferTransferFunction_ITU_R_709_2 as String
    static let matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    static let chromaSiting = kCVImageBufferChromaLocation_Left as String

    static func makeColorDescription() throws -> AppleUpscaleColorDescription {
        try AppleUpscaleColorDescription(
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            matrix: matrix,
            chromaSiting: chromaSiting,
            range: .video
        )
    }

    static func validate(
        frame: AppleUpscaleFrame,
        resolution: VideoResolution
    ) throws {
        try validate(colorDescription: frame.colorDescription)
        try validate(pixelBuffer: frame.pixelBuffer, resolution: resolution)
    }

    static func validate(
        colorDescription: AppleUpscaleColorDescription
    ) throws {
        try requireEqual(
            field: "color_primaries",
            expected: colorPrimaries,
            actual: colorDescription.colorPrimaries
        )
        try requireEqual(
            field: "transfer_function",
            expected: transferFunction,
            actual: colorDescription.transferFunction
        )
        try requireEqual(
            field: "matrix",
            expected: matrix,
            actual: colorDescription.matrix
        )
        try requireEqual(
            field: "chroma_siting",
            expected: chromaSiting,
            actual: colorDescription.chromaSiting
        )
        guard colorDescription.range == .video else {
            throw R03NV12ScalingError.colorDescriptionMismatch(
                field: "range",
                expected: AppleUpscaleColorRange.video.rawValue,
                actual: colorDescription.range.rawValue
            )
        }
    }

    static func validate(
        pixelBuffer: CVPixelBuffer,
        resolution: VideoResolution
    ) throws {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == pixelFormat else {
            throw R03NV12ScalingError.invalidPixelFormat(
                expected: pixelFormat,
                actual: actualFormat
            )
        }

        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard actualWidth == resolution.width,
              actualHeight == resolution.height else {
            throw R03NV12ScalingError.invalidDimensions(
                expectedWidth: resolution.width,
                expectedHeight: resolution.height,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount == 2 else {
            throw R03NV12ScalingError.invalidPlaneCount(expected: 2, actual: planeCount)
        }
        try validatePlane(
            pixelBuffer,
            plane: 0,
            expectedWidth: resolution.width,
            expectedHeight: resolution.height
        )
        try validatePlane(
            pixelBuffer,
            plane: 1,
            expectedWidth: resolution.width / 2,
            expectedHeight: resolution.height / 2
        )
        try validateColorAttachments(pixelBuffer)
    }

    static func installColorAttachments(on pixelBuffer: CVPixelBuffer) {
        for (key, value) in expectedAttachments {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
    }

    private static var expectedAttachments: [(key: CFString, value: CFString)] {
        [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
        ]
    }

    private static func validatePlane(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws {
        let actualWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let actualHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        guard actualWidth == expectedWidth, actualHeight == expectedHeight else {
            throw R03NV12ScalingError.invalidPlaneDimensions(
                plane: plane,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }
    }

    private static func validateColorAttachments(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        for (key, expectedValue) in expectedAttachments {
            let actualValue = CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
            let expectedString = expectedValue as String
            guard actualValue == expectedString else {
                throw R03NV12ScalingError.colorAttachmentMismatch(
                    key: key as String,
                    expected: expectedString,
                    actual: actualValue
                )
            }
        }
    }

    private static func requireEqual(
        field: String,
        expected: String,
        actual: String
    ) throws {
        guard expected == actual else {
            throw R03NV12ScalingError.colorDescriptionMismatch(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }
}
