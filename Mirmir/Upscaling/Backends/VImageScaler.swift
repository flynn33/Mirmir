import Accelerate
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import IOSurface

enum VImageScalingMode: CaseIterable, Equatable, Sendable {
    case standard
    case highQuality

    init?(backendID: UpscaleBackendID) {
        switch backendID {
        case .vImageStandard:
            self = .standard
        case .vImageHighQuality:
            self = .highQuality
        default:
            return nil
        }
    }

    var backendID: UpscaleBackendID {
        switch self {
        case .standard:
            return .vImageStandard
        case .highQuality:
            return .vImageHighQuality
        }
    }

    var resamplingFlags: vImage_Flags {
        switch self {
        case .standard:
            return vImage_Flags(kvImageEdgeExtend)
        case .highQuality:
            return vImage_Flags(
                kvImageEdgeExtend | kvImageHighQualityResampling
            )
        }
    }
}

struct VImageBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let mode: VImageScalingMode
    private let functions: any VImageScalingFunctions

    init?(
        descriptor: BackendDescriptor,
        functions: any VImageScalingFunctions = SystemVImageScalingFunctions()
    ) {
        guard let mode = VImageScalingMode(backendID: descriptor.id) else {
            return nil
        }
        self.descriptor = descriptor
        self.mode = mode
        self.functions = functions
    }

    init?(
        mode: VImageScalingMode,
        functions: any VImageScalingFunctions = SystemVImageScalingFunctions()
    ) {
        guard let descriptor = BackendDescriptor.descriptor(for: mode.backendID) else {
            return nil
        }
        self.init(descriptor: descriptor, functions: functions)
    }

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        switch VImagePreparationConfiguration.validate(
            source: source,
            targetSize: targetSize,
            mode: mode
        ) {
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .valid:
            return await environment.capabilityProbe.availability(
                for: descriptor.id,
                source: source,
                targetSize: targetSize
            )
        }
    }

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        let configuration: VImagePreparationConfiguration
        switch VImagePreparationConfiguration.validate(
            source: request.source,
            targetSize: request.targetSize,
            mode: mode
        ) {
        case .valid(let validated):
            configuration = validated
        case .unavailable(let reason):
            throw BackendPreparationError.unavailable(descriptor.id, reason)
        }

        let nativeAvailability = await environment.capabilityProbe.availability(
            for: descriptor.id,
            source: request.source,
            targetSize: request.targetSize
        )
        switch nativeAvailability {
        case .available:
            do {
                return try PreparedVImageScaler(
                    configuration: configuration,
                    functions: functions
                )
            } catch let error as VImageScalerError {
                throw MirmirError.backendProcessingFailed(
                    backendID: descriptor.id,
                    frameIndex: nil,
                    details: error.localizedDescription
                )
            }
        case .unavailable(let reason):
            throw BackendPreparationError.unavailable(descriptor.id, reason)
        case .modelDownloadRequired:
            throw BackendPreparationError.unavailable(
                descriptor.id,
                .modelUnavailable(
                    details: "vImage does not use a downloadable model, but its capability probe returned a model state."
                )
            )
        }
    }
}

actor PreparedVImageScaler: PreparedFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID

    private let configuration: VImagePreparationConfiguration
    private let functions: any VImageScalingFunctions
    private var temporaryStorage: VImageTemporaryStorage?
    private var isFinished = false

    init(
        configuration: VImagePreparationConfiguration,
        functions: any VImageScalingFunctions = SystemVImageScalingFunctions()
    ) throws {
        self.configuration = configuration
        self.functions = functions
        actualBackendID = configuration.mode.backendID
        sourcePixelBufferAttributes = PixelBufferAttributes(
            configuration.pixelBufferAttributes(
                width: configuration.sourceWidth,
                height: configuration.sourceHeight
            )
        )
        destinationPixelBufferAttributes = PixelBufferAttributes(
            configuration.pixelBufferAttributes(
                width: configuration.targetWidth,
                height: configuration.targetHeight
            )
        )

        let temporaryByteCount = try Self.requiredTemporaryByteCount(
            configuration: configuration,
            functions: functions
        )
        temporaryStorage = try VImageTemporaryStorage(
            byteCount: temporaryByteCount,
            backendID: configuration.mode.backendID
        )
    }

    nonisolated func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        let source = source.value
        let destination = destination.value
        try await processTransferred(
            source: FramePixelBuffer(source),
            destination: FramePixelBuffer(destination),
            timing: timing
        )
    }

    private func processTransferred(
        source transferredSource: FramePixelBuffer,
        destination transferredDestination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        let source = transferredSource.value
        let destination = transferredDestination.value
        guard !isFinished else {
            throw VImageScalerError.preparedScalerFinished(
                backendID: actualBackendID
            )
        }
        try Task.checkCancellation()
        guard source !== destination else {
            throw VImageScalerError.inPlaceProcessingUnsupported(
                backendID: actualBackendID
            )
        }

        try VImagePixelBufferValidator.validate(
            source,
            role: .source,
            expectedWidth: configuration.sourceWidth,
            expectedHeight: configuration.sourceHeight,
            expectedPixelFormat: configuration.pixelFormat
        )
        try VImagePixelBufferValidator.validate(
            destination,
            role: .destination,
            expectedWidth: configuration.targetWidth,
            expectedHeight: configuration.targetHeight,
            expectedPixelFormat: configuration.pixelFormat
        )
        try VImageColorAttachments.rejectUnsupportedHDRSignal(in: source)
        try VImageGeometryAttachments.validateSupportedGeometry(in: source)

        try scaleLockedBuffers(
            source: source,
            destination: destination,
            timing: timing
        )
        try Task.checkCancellation()
        VImageColorAttachments.copy(from: source, to: destination)
    }

    func finish() async throws {
        guard !isFinished else {
            return
        }
        temporaryStorage = nil
        isFinished = true
    }

    private func scaleLockedBuffers(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        timing: FrameTiming
    ) throws {
        let sourceLockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLockStatus == kCVReturnSuccess else {
            throw VImageScalerError.pixelBufferAccessFailed(
                role: .source,
                operation: .lock,
                status: sourceLockStatus
            )
        }

        let destinationLockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            let sourceUnlockStatus = CVPixelBufferUnlockBaseAddress(
                source,
                .readOnly
            )
            let destinationLockError = VImageScalerError.pixelBufferAccessFailed(
                role: .destination,
                operation: .lock,
                status: destinationLockStatus
            )
            if sourceUnlockStatus != kCVReturnSuccess {
                throw VImageScalerError.processingAndCleanupFailed(
                    primaryDetails: destinationLockError.localizedDescription,
                    destinationUnlockStatus: nil,
                    sourceUnlockStatus: sourceUnlockStatus
                )
            }
            throw destinationLockError
        }

        var processingError: Error?
        do {
            try VImagePixelBufferValidator.validateDistinctStorage(
                source: source,
                destination: destination,
                backendID: actualBackendID
            )
            try scalePlane(
                source: source,
                destination: destination,
                plane: 0,
                function: .planar8,
                timing: timing
            )
            try Task.checkCancellation()
            try scalePlane(
                source: source,
                destination: destination,
                plane: 1,
                function: .cbCr8,
                timing: timing
            )
        } catch {
            processingError = error
        }

        let destinationUnlockStatus = CVPixelBufferUnlockBaseAddress(
            destination,
            []
        )
        let sourceUnlockStatus = CVPixelBufferUnlockBaseAddress(source, .readOnly)

        let destinationUnlockFailure = destinationUnlockStatus == kCVReturnSuccess
            ? nil
            : destinationUnlockStatus
        let sourceUnlockFailure = sourceUnlockStatus == kCVReturnSuccess
            ? nil
            : sourceUnlockStatus

        if let processingError,
           destinationUnlockFailure != nil || sourceUnlockFailure != nil {
            throw VImageScalerError.processingAndCleanupFailed(
                primaryDetails: processingError.localizedDescription,
                destinationUnlockStatus: destinationUnlockFailure,
                sourceUnlockStatus: sourceUnlockFailure
            )
        }
        if let processingError {
            throw processingError
        }
        if let destinationUnlockFailure, let sourceUnlockFailure {
            throw VImageScalerError.processingAndCleanupFailed(
                primaryDetails: "The vImage planes were processed, but both Core Video cleanup operations failed.",
                destinationUnlockStatus: destinationUnlockFailure,
                sourceUnlockStatus: sourceUnlockFailure
            )
        }
        guard destinationUnlockStatus == kCVReturnSuccess else {
            throw VImageScalerError.pixelBufferAccessFailed(
                role: .destination,
                operation: .unlock,
                status: destinationUnlockStatus
            )
        }
        guard sourceUnlockStatus == kCVReturnSuccess else {
            throw VImageScalerError.pixelBufferAccessFailed(
                role: .source,
                operation: .unlock,
                status: sourceUnlockStatus
            )
        }
    }

    private func scalePlane(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        plane: Int,
        function: VImageScaleFunction,
        timing: FrameTiming
    ) throws {
        guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(
            source,
            plane
        ) else {
            throw VImageScalerError.missingPlaneBaseAddress(
                role: .source,
                plane: plane
            )
        }
        guard let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(
            destination,
            plane
        ) else {
            throw VImageScalerError.missingPlaneBaseAddress(
                role: .destination,
                plane: plane
            )
        }

        var sourceBuffer = vImage_Buffer(
            data: sourceBaseAddress,
            height: vImagePixelCount(
                CVPixelBufferGetHeightOfPlane(source, plane)
            ),
            width: vImagePixelCount(
                CVPixelBufferGetWidthOfPlane(source, plane)
            ),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        )
        var destinationBuffer = vImage_Buffer(
            data: destinationBaseAddress,
            height: vImagePixelCount(
                CVPixelBufferGetHeightOfPlane(destination, plane)
            ),
            width: vImagePixelCount(
                CVPixelBufferGetWidthOfPlane(destination, plane)
            ),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
        )

        let status: vImage_Error
        switch function {
        case .planar8:
            status = functions.scalePlanar8(
                source: &sourceBuffer,
                destination: &destinationBuffer,
                temporaryBuffer: temporaryStorage?.pointer,
                flags: configuration.mode.resamplingFlags
            )
        case .cbCr8:
            status = functions.scaleCbCr8(
                source: &sourceBuffer,
                destination: &destinationBuffer,
                temporaryBuffer: temporaryStorage?.pointer,
                flags: configuration.mode.resamplingFlags
            )
        }

        guard status == kvImageNoError else {
            let frameworkError = VImageScalerError.scalingFailed(
                backendID: actualBackendID,
                function: function,
                plane: plane,
                status: status,
                sourceWidth: configuration.sourceWidth,
                sourceHeight: configuration.sourceHeight,
                targetWidth: configuration.targetWidth,
                targetHeight: configuration.targetHeight,
                frameIndex: timing.frameIndex,
                presentationTime: timing.presentationTime
            )
            throw MirmirError.backendProcessingFailed(
                backendID: actualBackendID,
                frameIndex: timing.frameIndex,
                details: frameworkError.localizedDescription
            )
        }
    }

    private static func requiredTemporaryByteCount(
        configuration: VImagePreparationConfiguration,
        functions: any VImageScalingFunctions
    ) throws -> Int {
        let lumaByteCount = try temporaryByteCount(
            configuration: configuration,
            function: .planar8,
            functions: functions
        )
        let chromaByteCount = try temporaryByteCount(
            configuration: configuration,
            function: .cbCr8,
            functions: functions
        )
        return max(lumaByteCount, chromaByteCount)
    }

    private static func temporaryByteCount(
        configuration: VImagePreparationConfiguration,
        function: VImageScaleFunction,
        functions: any VImageScalingFunctions
    ) throws -> Int {
        let plane = function.plane
        let sourcePlaneWidth = plane == 0
            ? configuration.sourceWidth
            : configuration.sourceWidth / 2
        let sourcePlaneHeight = plane == 0
            ? configuration.sourceHeight
            : configuration.sourceHeight / 2
        let targetPlaneWidth = plane == 0
            ? configuration.targetWidth
            : configuration.targetWidth / 2
        let targetPlaneHeight = plane == 0
            ? configuration.targetHeight
            : configuration.targetHeight / 2
        let bytesPerElement = plane == 0 ? 1 : 2

        var sourceBuffer = vImage_Buffer(
            data: nil,
            height: vImagePixelCount(sourcePlaneHeight),
            width: vImagePixelCount(sourcePlaneWidth),
            rowBytes: sourcePlaneWidth * bytesPerElement
        )
        var destinationBuffer = vImage_Buffer(
            data: nil,
            height: vImagePixelCount(targetPlaneHeight),
            width: vImagePixelCount(targetPlaneWidth),
            rowBytes: targetPlaneWidth * bytesPerElement
        )
        let queryFlags = configuration.mode.resamplingFlags
            | vImage_Flags(kvImageGetTempBufferSize)

        let status: vImage_Error
        switch function {
        case .planar8:
            status = functions.scalePlanar8(
                source: &sourceBuffer,
                destination: &destinationBuffer,
                temporaryBuffer: nil,
                flags: queryFlags
            )
        case .cbCr8:
            status = functions.scaleCbCr8(
                source: &sourceBuffer,
                destination: &destinationBuffer,
                temporaryBuffer: nil,
                flags: queryFlags
            )
        }

        guard status >= 0 else {
            throw VImageScalerError.temporaryStorageQueryFailed(
                backendID: configuration.mode.backendID,
                function: function,
                status: status,
                sourceWidth: configuration.sourceWidth,
                sourceHeight: configuration.sourceHeight,
                targetWidth: configuration.targetWidth,
                targetHeight: configuration.targetHeight
            )
        }
        return status
    }
}

private final class VImageTemporaryStorage: @unchecked Sendable {
    // The prepared-scaler actor is the only owner that exposes this mutable
    // allocation to vImage, and it serializes every query, processing call,
    // and release. The unchecked boundary is therefore confined to this
    // allocation owner rather than the actor's isolated state or deinitializer.
    let pointer: UnsafeMutableRawPointer?

    init(byteCount: Int, backendID: UpscaleBackendID) throws {
        guard byteCount > 0 else {
            pointer = nil
            return
        }
        guard let pointer = malloc(byteCount) else {
            throw VImageScalerError.temporaryStorageAllocationFailed(
                backendID: backendID,
                byteCount: byteCount
            )
        }
        self.pointer = pointer
    }

    deinit {
        free(pointer)
    }
}

protocol VImageScalingFunctions: Sendable {
    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error
}

struct SystemVImageScalingFunctions: VImageScalingFunctions {
    func scalePlanar8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        vImageScale_Planar8(
            &source,
            &destination,
            temporaryBuffer,
            flags
        )
    }

    func scaleCbCr8(
        source: inout vImage_Buffer,
        destination: inout vImage_Buffer,
        temporaryBuffer: UnsafeMutableRawPointer?,
        flags: vImage_Flags
    ) -> vImage_Error {
        vImageScale_CbCr8(
            &source,
            &destination,
            temporaryBuffer,
            flags
        )
    }
}

private enum VImageConfigurationValidation {
    case valid(VImagePreparationConfiguration)
    case unavailable(BackendUnavailableReason)
}

struct VImagePreparationConfiguration: Equatable, Sendable {
    let mode: VImageScalingMode
    let pixelFormat: OSType
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int

    fileprivate static func validate(
        source: VideoInfo,
        targetSize: CGSize,
        mode: VImageScalingMode
    ) -> VImageConfigurationValidation {
        guard let sourceDimensions = exactEvenDimensions(
            source.geometry.encodedSize ?? source.naturalSize
        ) else {
            let size = source.geometry.encodedSize ?? source.naturalSize
            return .unavailable(
                .unsupportedSourceDimensions(
                    width: safeDisplayDimension(size.width),
                    height: safeDisplayDimension(size.height),
                    details: "8-bit NV12 requires positive, integral, even encoded dimensions"
                )
            )
        }
        guard let targetDimensions = exactEvenDimensions(targetSize) else {
            return .unavailable(
                .unsupportedTargetDimensions(
                    width: safeDisplayDimension(targetSize.width),
                    height: safeDisplayDimension(targetSize.height),
                    details: "8-bit NV12 requires positive, integral, even target dimensions"
                )
            )
        }
        if source.color.dynamicRange == .hdr
            || source.color.hasMasteringDisplayMetadata
            || source.color.hasContentLightLevelMetadata {
            return .unavailable(.hdrPreservationUnavailable)
        }
        guard source.color.dynamicRange == .sdr else {
            return .unavailable(
                .unsupportedPixelFormatOrBitDepth(
                    details: "The source dynamic range is unknown; the initial vImage path requires an explicitly identified SDR source"
                )
            )
        }
        if let bitDepth = source.color.bitDepth, bitDepth != 8 {
            return .unavailable(
                .unsupportedPixelFormatOrBitDepth(
                    details: "Accelerate/vImage currently accepts decoded 8-bit NV12; the source reports \(bitDepth)-bit video"
                )
            )
        }
        if source.geometry.cleanAperture != nil {
            return .unavailable(
                .unsupportedSourceDimensions(
                    width: sourceDimensions.width,
                    height: sourceDimensions.height,
                    details: "The initial vImage path does not yet preserve an explicit clean aperture"
                )
            )
        }
        if let pixelAspectRatio = source.geometry.pixelAspectRatio,
           pixelAspectRatio.horizontalSpacing
            != pixelAspectRatio.verticalSpacing {
            return .unavailable(
                .unsupportedSourceDimensions(
                    width: sourceDimensions.width,
                    height: sourceDimensions.height,
                    details: "The initial vImage path supports only square pixels; the source reports \(pixelAspectRatio.horizontalSpacing):\(pixelAspectRatio.verticalSpacing)"
                )
            )
        }
        guard let isFullRange = source.color.isFullRange else {
            return .unavailable(
                .unsupportedPixelFormatOrBitDepth(
                    details: "The source range is unknown; vImage requires an explicit video-range (420v) or full-range (420f) decode contract"
                )
            )
        }
        let pixelFormat = isFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if let reportedPixelFormat = source.color.pixelFormat,
           reportedPixelFormat != pixelFormat {
            return .unavailable(
                .unsupportedPixelFormatOrBitDepth(
                    details: "The source reports \(FourCC.string(from: reportedPixelFormat) ?? String(reportedPixelFormat)); the explicit range contract requires \(FourCC.string(from: pixelFormat) ?? String(pixelFormat))"
                )
            )
        }

        return .valid(
            VImagePreparationConfiguration(
                mode: mode,
                pixelFormat: pixelFormat,
                sourceWidth: sourceDimensions.width,
                sourceHeight: sourceDimensions.height,
                targetWidth: targetDimensions.width,
                targetHeight: targetDimensions.height
            )
        )
    }

    func pixelBufferAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
    }

    private static func exactEvenDimensions(
        _ size: CGSize
    ) -> (width: Int, height: Int)? {
        guard size.width.isFinite,
              size.height.isFinite,
              let width = Int(exactly: size.width),
              let height = Int(exactly: size.height),
              width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2) else {
            return nil
        }
        return (width, height)
    }

    private static func safeDisplayDimension(_ value: CGFloat) -> Int {
        guard value.isFinite,
              let result = Int(exactly: value.rounded()) else {
            return 0
        }
        return result
    }
}

enum VImagePixelBufferValidator {
    static func validate(
        _ pixelBuffer: CVPixelBuffer,
        role: VImagePixelBufferRole,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedPixelFormat: OSType
    ) throws {
        let actualPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualPixelFormat == expectedPixelFormat else {
            throw VImageScalerError.invalidPixelFormat(
                role: role,
                expected: expectedPixelFormat,
                actual: actualPixelFormat
            )
        }

        let actualWidth = CVPixelBufferGetWidth(pixelBuffer)
        let actualHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard actualWidth == expectedWidth, actualHeight == expectedHeight else {
            throw VImageScalerError.invalidDimensions(
                role: role,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        try validatePlaneCount(role: role, actual: planeCount)
        try validatePlaneLayout(
            role: role,
            plane: 0,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            actualWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            actualHeight: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            bytesPerElement: 1,
            actualBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                0
            )
        )
        try validatePlaneLayout(
            role: role,
            plane: 1,
            expectedWidth: expectedWidth / 2,
            expectedHeight: expectedHeight / 2,
            actualWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            actualHeight: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            bytesPerElement: 2,
            actualBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                1
            )
        )
    }

    static func validatePlaneCount(
        role: VImagePixelBufferRole,
        actual: Int
    ) throws {
        guard actual == 2 else {
            throw VImageScalerError.invalidPlaneCount(
                role: role,
                expected: 2,
                actual: actual
            )
        }
    }

    static func validatePlaneLayout(
        role: VImagePixelBufferRole,
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int,
        bytesPerElement: Int,
        actualBytesPerRow: Int
    ) throws {
        guard actualWidth == expectedWidth, actualHeight == expectedHeight else {
            throw VImageScalerError.invalidPlaneDimensions(
                role: role,
                plane: plane,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: actualWidth,
                actualHeight: actualHeight
            )
        }

        let minimumBytesPerRow = expectedWidth * bytesPerElement
        guard actualBytesPerRow >= minimumBytesPerRow else {
            throw VImageScalerError.invalidBytesPerRow(
                role: role,
                plane: plane,
                minimum: minimumBytesPerRow,
                actual: actualBytesPerRow
            )
        }
    }

    static func validateDistinctStorage(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        backendID: UpscaleBackendID
    ) throws {
        if let sourceSurface = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue(),
           let destinationSurface = CVPixelBufferGetIOSurface(destination)?.takeUnretainedValue(),
           sourceSurface === destinationSurface {
            throw VImageScalerError.sharedStorageUnsupported(
                backendID: backendID,
                details: "the source and destination use the same IOSurface"
            )
        }

        let sourceRanges = try planeMemoryRanges(
            for: source,
            role: .source
        )
        let destinationRanges = try planeMemoryRanges(
            for: destination,
            role: .destination
        )
        for sourceRange in sourceRanges {
            for destinationRange in destinationRanges
            where sourceRange.range.overlaps(destinationRange.range) {
                throw VImageScalerError.sharedStorageUnsupported(
                    backendID: backendID,
                    details: "source plane \(sourceRange.plane) overlaps destination plane \(destinationRange.plane)"
                )
            }
        }
    }

    private static func planeMemoryRanges(
        for pixelBuffer: CVPixelBuffer,
        role: VImagePixelBufferRole
    ) throws -> [(plane: Int, range: Range<UInt>)] {
        try (0..<CVPixelBufferGetPlaneCount(pixelBuffer)).map { plane in
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                plane
            ) else {
                throw VImageScalerError.missingPlaneBaseAddress(
                    role: role,
                    plane: plane
                )
            }
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            let bytesPerElement = plane == 0 ? 1 : 2
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                plane
            )
            let (visibleRowBytes, visibleOverflow) = width
                .multipliedReportingOverflow(by: bytesPerElement)
            let rowCount = max(height - 1, 0)
            let (rowOffset, rowOverflow) = rowCount
                .multipliedReportingOverflow(by: rowBytes)
            let (span, spanOverflow) = rowOffset.addingReportingOverflow(
                visibleRowBytes
            )
            let start = UInt(bitPattern: baseAddress)
            guard !visibleOverflow,
                  !rowOverflow,
                  !spanOverflow,
                  span > 0 else {
                throw VImageScalerError.invalidPlaneMemoryRange(
                    role: role,
                    plane: plane
                )
            }
            let (end, addressOverflow) = start.addingReportingOverflow(
                UInt(span)
            )
            guard !addressOverflow else {
                throw VImageScalerError.invalidPlaneMemoryRange(
                    role: role,
                    plane: plane
                )
            }
            return (plane: plane, range: start..<end)
        }
    }
}

private enum VImageColorAttachments {
    static func rejectUnsupportedHDRSignal(in source: CVPixelBuffer) throws {
        var mode = CVAttachmentMode.shouldPropagate
        let transfer = CVBufferCopyAttachment(
            source,
            kCVImageBufferTransferFunctionKey,
            &mode
        ) as? String
        let hdrTransferFunctions: Set<String> = [
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        ]
        if let transfer, hdrTransferFunctions.contains(transfer) {
            throw VImageScalerError.unsupportedHDRSignal(
                details: "the decoded frame carries transfer function \(transfer)"
            )
        }

        if CVBufferCopyAttachment(
            source,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            nil
        ) != nil {
            throw VImageScalerError.unsupportedHDRSignal(
                details: "the decoded frame carries mastering-display metadata"
            )
        }
        if CVBufferCopyAttachment(
            source,
            kCVImageBufferContentLightLevelInfoKey,
            nil
        ) != nil {
            throw VImageScalerError.unsupportedHDRSignal(
                details: "the decoded frame carries content-light metadata"
            )
        }
        if CVBufferCopyAttachment(
            source,
            kCVImageBufferLogTransferFunctionKey,
            nil
        ) != nil {
            throw VImageScalerError.unsupportedHDRSignal(
                details: "the decoded frame carries a log transfer function"
            )
        }
    }

    static func copy(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        let keys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferGammaLevelKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferCGColorSpaceKey,
            kCVImageBufferPixelAspectRatioKey,
            kCVImageBufferCleanApertureKey,
            kCVImageBufferPreferredCleanApertureKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey,
            kCVImageBufferLogTransferFunctionKey
        ]

        for key in keys {
            CVBufferRemoveAttachment(destination, key)
            guard let value = CVBufferCopyAttachment(source, key, nil) else {
                continue
            }
            CVBufferSetAttachment(
                destination,
                key,
                value,
                .shouldPropagate
            )
        }
    }
}

private enum VImageGeometryAttachments {
    static func validateSupportedGeometry(in source: CVPixelBuffer) throws {
        if CVBufferCopyAttachment(
            source,
            kCVImageBufferCleanApertureKey,
            nil
        ) != nil || CVBufferCopyAttachment(
            source,
            kCVImageBufferPreferredCleanApertureKey,
            nil
        ) != nil {
            throw VImageScalerError.unsupportedGeometrySignal(
                details: "the decoded frame carries an explicit clean aperture"
            )
        }

        guard let attachment = CVBufferCopyAttachment(
            source,
            kCVImageBufferPixelAspectRatioKey,
            nil
        ) else {
            return
        }
        guard let dictionary = attachment as? NSDictionary,
              let horizontal = dictionary[
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey
              ] as? NSNumber,
              let vertical = dictionary[
                kCVImageBufferPixelAspectRatioVerticalSpacingKey
              ] as? NSNumber,
              horizontal.doubleValue.isFinite,
              vertical.doubleValue.isFinite,
              horizontal.doubleValue > 0,
              vertical.doubleValue > 0,
              horizontal.doubleValue == vertical.doubleValue else {
            throw VImageScalerError.unsupportedGeometrySignal(
                details: "the decoded frame does not carry a valid square-pixel aspect ratio"
            )
        }
    }
}

enum VImagePixelBufferRole: String, Equatable, Sendable {
    case source
    case destination
}

enum VImagePixelBufferAccessOperation: String, Equatable, Sendable {
    case lock
    case unlock
}

enum VImageScaleFunction: String, Equatable, Sendable {
    case planar8 = "vImageScale_Planar8"
    case cbCr8 = "vImageScale_CbCr8"

    var plane: Int {
        switch self {
        case .planar8:
            return 0
        case .cbCr8:
            return 1
        }
    }
}

enum VImageScalerError: LocalizedError, Equatable, Sendable {
    case preparedScalerFinished(backendID: UpscaleBackendID)
    case inPlaceProcessingUnsupported(backendID: UpscaleBackendID)
    case invalidPixelFormat(
        role: VImagePixelBufferRole,
        expected: OSType,
        actual: OSType
    )
    case invalidDimensions(
        role: VImagePixelBufferRole,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case invalidPlaneCount(
        role: VImagePixelBufferRole,
        expected: Int,
        actual: Int
    )
    case invalidPlaneDimensions(
        role: VImagePixelBufferRole,
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case invalidBytesPerRow(
        role: VImagePixelBufferRole,
        plane: Int,
        minimum: Int,
        actual: Int
    )
    case invalidPlaneMemoryRange(role: VImagePixelBufferRole, plane: Int)
    case sharedStorageUnsupported(
        backendID: UpscaleBackendID,
        details: String
    )
    case pixelBufferAccessFailed(
        role: VImagePixelBufferRole,
        operation: VImagePixelBufferAccessOperation,
        status: CVReturn
    )
    case processingAndCleanupFailed(
        primaryDetails: String,
        destinationUnlockStatus: CVReturn?,
        sourceUnlockStatus: CVReturn?
    )
    case missingPlaneBaseAddress(role: VImagePixelBufferRole, plane: Int)
    case unsupportedHDRSignal(details: String)
    case unsupportedGeometrySignal(details: String)
    case temporaryStorageQueryFailed(
        backendID: UpscaleBackendID,
        function: VImageScaleFunction,
        status: vImage_Error,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    )
    case temporaryStorageAllocationFailed(
        backendID: UpscaleBackendID,
        byteCount: Int
    )
    case scalingFailed(
        backendID: UpscaleBackendID,
        function: VImageScaleFunction,
        plane: Int,
        status: vImage_Error,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        frameIndex: Int,
        presentationTime: CMTime
    )

    var errorDescription: String? {
        switch self {
        case .preparedScalerFinished(let backendID):
            return "\(backendTitle(backendID)) has already finished this job. Start a new job before processing another frame."
        case .inPlaceProcessingUnsupported(let backendID):
            return "\(backendTitle(backendID)) requires distinct source and destination pixel buffers."
        case .invalidPixelFormat(let role, let expected, let actual):
            return "The \(role.rawValue) pixel buffer uses \(fourCC(actual)); expected \(fourCC(expected)) for this vImage job."
        case .invalidDimensions(
            let role,
            let expectedWidth,
            let expectedHeight,
            let actualWidth,
            let actualHeight
        ):
            return "The \(role.rawValue) pixel buffer is \(actualWidth) × \(actualHeight); expected \(expectedWidth) × \(expectedHeight)."
        case .invalidPlaneCount(let role, let expected, let actual):
            return "The \(role.rawValue) pixel buffer has \(actual) planes; expected \(expected) for NV12."
        case .invalidPlaneDimensions(
            let role,
            let plane,
            let expectedWidth,
            let expectedHeight,
            let actualWidth,
            let actualHeight
        ):
            return "The \(role.rawValue) NV12 plane \(plane) is \(actualWidth) × \(actualHeight); expected \(expectedWidth) × \(expectedHeight)."
        case .invalidBytesPerRow(let role, let plane, let minimum, let actual):
            return "The \(role.rawValue) NV12 plane \(plane) has \(actual) bytes per row; at least \(minimum) are required."
        case .invalidPlaneMemoryRange(let role, let plane):
            return "The \(role.rawValue) NV12 plane \(plane) exposes an invalid or overflowing memory range."
        case .sharedStorageUnsupported(let backendID, let details):
            return "\(backendTitle(backendID)) requires out-of-place scaling, but \(details)."
        case .pixelBufferAccessFailed(let role, let operation, let status):
            return "Core Video could not \(operation.rawValue) the \(role.rawValue) pixel buffer (CVReturn \(status))."
        case .processingAndCleanupFailed(
            let primaryDetails,
            let destinationUnlockStatus,
            let sourceUnlockStatus
        ):
            var cleanupDetails: [String] = []
            if let destinationUnlockStatus {
                cleanupDetails.append(
                    "destination unlock CVReturn \(destinationUnlockStatus)"
                )
            }
            if let sourceUnlockStatus {
                cleanupDetails.append(
                    "source unlock CVReturn \(sourceUnlockStatus)"
                )
            }
            return "\(primaryDetails) Cleanup also failed: \(cleanupDetails.joined(separator: ", "))."
        case .missingPlaneBaseAddress(let role, let plane):
            return "Core Video did not expose a base address for \(role.rawValue) NV12 plane \(plane) after a successful lock."
        case .unsupportedHDRSignal(let details):
            return "The initial 8-bit vImage backend cannot preserve this HDR signal: \(details). Choose a backend that explicitly supports HDR."
        case .unsupportedGeometrySignal(let details):
            return "The initial vImage backend cannot preserve this source geometry: \(details)."
        case .temporaryStorageQueryFailed(
            let backendID,
            let function,
            let status,
            let sourceWidth,
            let sourceHeight,
            let targetWidth,
            let targetHeight
        ):
            return "\(function.rawValue) could not size reusable storage for \(backendTitle(backendID)), \(sourceWidth) × \(sourceHeight) to \(targetWidth) × \(targetHeight) (vImage_Error \(status))."
        case .temporaryStorageAllocationFailed(let backendID, let byteCount):
            return "\(backendTitle(backendID)) could not allocate \(byteCount) bytes of reusable vImage storage. Close other applications and try again."
        case .scalingFailed(
            let backendID,
            let function,
            let plane,
            let status,
            let sourceWidth,
            let sourceHeight,
            let targetWidth,
            let targetHeight,
            let frameIndex,
            let presentationTime
        ):
            return "\(function.rawValue) failed for \(backendTitle(backendID)) on plane \(plane), frame \(frameIndex) at \(CMTimeGetSeconds(presentationTime)) seconds, \(sourceWidth) × \(sourceHeight) to \(targetWidth) × \(targetHeight) (vImage_Error \(status))."
        }
    }

    private func backendTitle(_ id: UpscaleBackendID) -> String {
        BackendDescriptor.descriptor(for: id)?.title ?? id.rawValue
    }

    private func fourCC(_ value: OSType) -> String {
        FourCC.string(from: value) ?? String(value)
    }
}
