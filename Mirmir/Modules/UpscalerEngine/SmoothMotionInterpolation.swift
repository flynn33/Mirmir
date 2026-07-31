import Accelerate
import CoreMedia
import CoreVideo
import Foundation

enum SmoothMotionInterpolationRoute:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable {
    case videoToolboxLowLatency =
        "videotoolbox_low_latency_frame_interpolation"
    case deterministicFormatBlend =
        "deterministic_format_preserving_blend"
}

enum SmoothMotionInterpolationError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible {
    case cancelled
    case invalidPhase(Float)
    case phaseTimestampCountMismatch
    case unsupportedPixelFormat(OSType)
    case geometryMismatch
    case invalidPlaneCount(Int)
    case inaccessiblePlane(Int)
    case lockFailed(CVReturn)
    case blendFailed(plane: Int, code: Int)
    case sceneAnalysisFailed
    case layoutProcessingFailed(R13PixelLayoutError)

    var description: String {
        switch self {
        case .cancelled:
            return "Smooth Motion interpolation was cancelled."
        case .invalidPhase(let phase):
            return "Smooth Motion received invalid interpolation phase \(phase)."
        case .phaseTimestampCountMismatch:
            return "Smooth Motion phase and timestamp counts differ."
        case .unsupportedPixelFormat(let format):
            return "Smooth Motion cannot process pixel format \(format)."
        case .geometryMismatch:
            return "Smooth Motion input frame geometry differs."
        case .invalidPlaneCount(let count):
            return "Smooth Motion received an invalid plane count: \(count)."
        case .inaccessiblePlane(let plane):
            return "Smooth Motion could not access image plane \(plane)."
        case .lockFailed(let status):
            return "Smooth Motion pixel-buffer locking failed with \(status)."
        case .blendFailed(let plane, let code):
            return "Smooth Motion blending failed on plane \(plane) with \(code)."
        case .sceneAnalysisFailed:
            return "Smooth Motion could not analyze the frame transition."
        case .layoutProcessingFailed(let error):
            return "Smooth Motion layout processing failed: \(error)."
        }
    }
}

struct SmoothMotionSceneAnalysis: Equatable, Sendable {
    let isSceneCut: Bool
    let meanNormalizedLumaDifference: Double
    let changedSampleRatio: Double
}

protocol SmoothMotionSceneCutDetecting: Sendable {
    func analyze(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        sensitivity: SmoothMotionSceneCutSensitivity
    ) throws -> SmoothMotionSceneAnalysis
}

protocol SmoothMotionFrameInterpolating: AnyObject, Sendable {
    var route: SmoothMotionInterpolationRoute { get }

    func interpolate(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        previousTime: CMTime,
        currentTime: CMTime,
        phases: [Float],
        presentationTimes: [CMTime]
    ) async throws -> [CVPixelBuffer]

    func finish()
    func cancel()
}

struct SmoothMotionLumaSceneCutDetector:
    SmoothMotionSceneCutDetecting,
    Sendable {
    private let sampleColumns = 32
    private let sampleRows = 18
    private let changedSampleThreshold = 32.0 / 255.0
    private let minimumChangedSampleRatio = 0.45

    func analyze(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        sensitivity: SmoothMotionSceneCutSensitivity
    ) throws -> SmoothMotionSceneAnalysis {
        let pixelFormat = try SmoothMotionPixelBufferContract.validatePair(
            previous: previous,
            current: current
        )
        let previousLock = CVPixelBufferLockBaseAddress(
            previous,
            .readOnly
        )
        guard previousLock == kCVReturnSuccess else {
            throw SmoothMotionInterpolationError.lockFailed(previousLock)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }
        let currentLock = CVPixelBufferLockBaseAddress(
            current,
            .readOnly
        )
        guard currentLock == kCVReturnSuccess else {
            throw SmoothMotionInterpolationError.lockFailed(currentLock)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
        }
        let width = CVPixelBufferGetWidth(previous)
        let height = CVPixelBufferGetHeight(previous)
        let columns = min(sampleColumns, width)
        let rows = min(sampleRows, height)
        guard columns > 0, rows > 0 else {
            throw SmoothMotionInterpolationError.sceneAnalysisFailed
        }

        var normalizedDifferenceTotal = 0.0
        var changedSampleCount = 0
        for row in 0..<rows {
            let sourceRow = coordinate(
                ordinal: row,
                sampleCount: rows,
                sourceCount: height
            )
            for column in 0..<columns {
                let sourceColumn = coordinate(
                    ordinal: column,
                    sampleCount: columns,
                    sourceCount: width
                )
                let difference = try normalizedLumaDifference(
                    previous: previous,
                    current: current,
                    pixelFormat: pixelFormat,
                    column: sourceColumn,
                    row: sourceRow
                )
                normalizedDifferenceTotal += difference
                if difference >= changedSampleThreshold {
                    changedSampleCount += 1
                }
            }
        }
        let sampleCount = rows * columns
        let meanDifference =
            normalizedDifferenceTotal / Double(sampleCount)
        let changedRatio =
            Double(changedSampleCount) / Double(sampleCount)
        return SmoothMotionSceneAnalysis(
            isSceneCut:
                meanDifference
                    >= sensitivity.normalizedDifferenceThreshold
                    && changedRatio >= minimumChangedSampleRatio,
            meanNormalizedLumaDifference: meanDifference,
            changedSampleRatio: changedRatio
        )
    }

    private func coordinate(
        ordinal: Int,
        sampleCount: Int,
        sourceCount: Int
    ) -> Int {
        guard sampleCount > 1 else { return 0 }
        return ordinal * (sourceCount - 1) / (sampleCount - 1)
    }

    private func normalizedLumaDifference(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        pixelFormat: OSType,
        column: Int,
        row: Int
    ) throws -> Double {
        let previousLuma = try normalizedLuma(
            previous,
            pixelFormat: pixelFormat,
            column: column,
            row: row
        )
        let currentLuma = try normalizedLuma(
            current,
            pixelFormat: pixelFormat,
            column: column,
            row: row
        )
        return abs(previousLuma - currentLuma)
    }

    private func normalizedLuma(
        _ buffer: CVPixelBuffer,
        pixelFormat: OSType,
        column: Int,
        row: Int
    ) throws -> Double {
        do {
            let layout = try R13PixelLayoutRegistry.layout(
                for: pixelFormat
            )
            return try R13PixelLayoutProcessor
                .normalizedLumaLocked(
                    buffer,
                    column: column,
                    row: row,
                    layout: layout
                )
        } catch let error as R13PixelLayoutError {
            if case .unsupportedPixelFormat = error {
                throw SmoothMotionInterpolationError
                    .unsupportedPixelFormat(pixelFormat)
            }
            throw SmoothMotionInterpolationError
                .layoutProcessingFailed(error)
        }
    }
}

final class SmoothMotionDeterministicInterpolator:
    SmoothMotionFrameInterpolating,
    @unchecked Sendable {
    let route: SmoothMotionInterpolationRoute =
        .deterministicFormatBlend

    private let resolution: VideoResolution
    private let pixelFormat: OSType
    private let outputPool: CVPixelBufferPool
    private let stateLock = NSLock()
    private var isCancelled = false

    init(
        resolution: VideoResolution,
        pixelFormat: OSType =
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        capacity: Int = 6
    ) throws {
        guard SmoothMotionPixelBufferContract.supportedFormats
            .contains(pixelFormat) else {
            throw SmoothMotionInterpolationError
                .unsupportedPixelFormat(pixelFormat)
        }
        self.resolution = resolution
        self.pixelFormat = pixelFormat
        outputPool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: pixelFormat,
            capacity: capacity
        )
    }

    func interpolate(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        previousTime _: CMTime,
        currentTime _: CMTime,
        phases: [Float],
        presentationTimes: [CMTime]
    ) async throws -> [CVPixelBuffer] {
        guard phases.count == presentationTimes.count else {
            throw SmoothMotionInterpolationError
                .phaseTimestampCountMismatch
        }
        let inputFormat =
            try SmoothMotionPixelBufferContract.validatePair(
            previous: previous,
            current: current
        )
        guard inputFormat == pixelFormat,
              CVPixelBufferGetWidth(previous) == resolution.width,
              CVPixelBufferGetHeight(previous) == resolution.height else {
            throw SmoothMotionInterpolationError.geometryMismatch
        }
        try checkCancellation()
        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(phases.count)
        for phase in phases {
            try Task.checkCancellation()
            try checkCancellation()
            guard phase > 0, phase < 1 else {
                throw SmoothMotionInterpolationError.invalidPhase(phase)
            }
            let destination = try PixelBufferBridge.dequeue(
                from: outputPool
            )
            try blend(
                previous: previous,
                current: current,
                destination: destination,
                phase: phase
            )
            SmoothMotionPixelBufferAttachments.copy(
                from: previous,
                to: destination
            )
            frames.append(destination)
        }
        return frames
    }

    func finish() {}

    func cancel() {
        stateLock.withLock {
            isCancelled = true
        }
    }

    private func checkCancellation() throws {
        if stateLock.withLock({ isCancelled }) {
            throw SmoothMotionInterpolationError.cancelled
        }
    }

    private func blend(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        destination: CVPixelBuffer,
        phase: Float
    ) throws {
        let previousLock =
            CVPixelBufferLockBaseAddress(previous, .readOnly)
        guard previousLock == kCVReturnSuccess else {
            throw SmoothMotionInterpolationError.lockFailed(previousLock)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }
        let currentLock =
            CVPixelBufferLockBaseAddress(current, .readOnly)
        guard currentLock == kCVReturnSuccess else {
            throw SmoothMotionInterpolationError.lockFailed(currentLock)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
        }
        let destinationLock =
            CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else {
            throw SmoothMotionInterpolationError.lockFailed(destinationLock)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        let weight = try Self.blendWeight(for: phase)
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            try blendBiPlanar8(
                previous: previous,
                current: current,
                destination: destination,
                weight: weight
            )
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            try blendBiPlanar10(
                previous: previous,
                current: current,
                destination: destination,
                weight: weight
            )
        case kCVPixelFormatType_32BGRA:
            try blendBGRA8(
                previous: previous,
                current: current,
                destination: destination,
                weight: weight
            )
        default:
            do {
                let layout = try R13PixelLayoutRegistry.layout(
                    for: pixelFormat
                )
                try R13PixelLayoutProcessor.blendLocked(
                    previous: previous,
                    current: current,
                    destination: destination,
                    phase: phase,
                    layout: layout
                )
            } catch let error as R13PixelLayoutError {
                if case .unsupportedPixelFormat = error {
                    throw SmoothMotionInterpolationError
                        .unsupportedPixelFormat(pixelFormat)
                }
                throw SmoothMotionInterpolationError
                    .layoutProcessingFailed(error)
            }
        }
    }

    private func blendBiPlanar8(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        destination: CVPixelBuffer,
        weight: BlendWeight
    ) throws {
        for plane in 0..<2 {
            guard
                let previousBase =
                    CVPixelBufferGetBaseAddressOfPlane(previous, plane),
                let currentBase =
                    CVPixelBufferGetBaseAddressOfPlane(current, plane),
                let destinationBase =
                    CVPixelBufferGetBaseAddressOfPlane(
                        destination,
                        plane
                    )
            else {
                throw SmoothMotionInterpolationError
                    .inaccessiblePlane(plane)
            }
            let activeBytes =
                CVPixelBufferGetWidthOfPlane(previous, plane)
                * (plane == 0 ? 1 : 2)
            let height =
                CVPixelBufferGetHeightOfPlane(previous, plane)
            let previousStride =
                CVPixelBufferGetBytesPerRowOfPlane(previous, plane)
            let currentStride =
                CVPixelBufferGetBytesPerRowOfPlane(current, plane)
            let destinationStride =
                CVPixelBufferGetBytesPerRowOfPlane(
                    destination,
                    plane
                )
            try blendUInt8Rows(
                previous: previousBase
                    .assumingMemoryBound(to: UInt8.self),
                previousStride: previousStride,
                current: currentBase
                    .assumingMemoryBound(to: UInt8.self),
                currentStride: currentStride,
                destination: destinationBase
                    .assumingMemoryBound(to: UInt8.self),
                destinationStride: destinationStride,
                activeCount: activeBytes,
                rowCount: height,
                weight: weight
            )
        }
    }

    private func blendBiPlanar10(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        destination: CVPixelBuffer,
        weight: BlendWeight
    ) throws {
        for plane in 0..<2 {
            guard
                let previousBase =
                    CVPixelBufferGetBaseAddressOfPlane(previous, plane),
                let currentBase =
                    CVPixelBufferGetBaseAddressOfPlane(current, plane),
                let destinationBase =
                    CVPixelBufferGetBaseAddressOfPlane(
                        destination,
                        plane
                    )
            else {
                throw SmoothMotionInterpolationError
                    .inaccessiblePlane(plane)
            }
            let activeSamples =
                CVPixelBufferGetWidthOfPlane(previous, plane)
                * (plane == 0 ? 1 : 2)
            let height =
                CVPixelBufferGetHeightOfPlane(previous, plane)
            let elementSize = MemoryLayout<UInt16>.stride
            let previousStride =
                CVPixelBufferGetBytesPerRowOfPlane(previous, plane)
                / elementSize
            let currentStride =
                CVPixelBufferGetBytesPerRowOfPlane(current, plane)
                / elementSize
            let destinationStride =
                CVPixelBufferGetBytesPerRowOfPlane(
                    destination,
                    plane
                ) / elementSize
            try blendP010Rows(
                previous: previousBase
                    .assumingMemoryBound(to: UInt16.self),
                previousStride: previousStride,
                current: currentBase
                    .assumingMemoryBound(to: UInt16.self),
                currentStride: currentStride,
                destination: destinationBase
                    .assumingMemoryBound(to: UInt16.self),
                destinationStride: destinationStride,
                activeCount: activeSamples,
                rowCount: height,
                weight: weight
            )
        }
    }

    private func blendBGRA8(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        destination: CVPixelBuffer,
        weight: BlendWeight
    ) throws {
        guard
            let previousBase = CVPixelBufferGetBaseAddress(previous),
            let currentBase = CVPixelBufferGetBaseAddress(current),
            let destinationBase =
                CVPixelBufferGetBaseAddress(destination)
        else {
            throw SmoothMotionInterpolationError
                .inaccessiblePlane(0)
        }
        try blendUInt8Rows(
            previous: previousBase
                .assumingMemoryBound(to: UInt8.self),
            previousStride: CVPixelBufferGetBytesPerRow(previous),
            current: currentBase
                .assumingMemoryBound(to: UInt8.self),
            currentStride: CVPixelBufferGetBytesPerRow(current),
            destination: destinationBase
                .assumingMemoryBound(to: UInt8.self),
            destinationStride:
                CVPixelBufferGetBytesPerRow(destination),
            activeCount: resolution.width * 4,
            rowCount: resolution.height,
            weight: weight
        )
    }

    private func blendUInt8Rows(
        previous: UnsafePointer<UInt8>,
        previousStride: Int,
        current: UnsafePointer<UInt8>,
        currentStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int,
        activeCount: Int,
        rowCount: Int,
        weight: BlendWeight
    ) throws {
        for row in 0..<rowCount {
            if row.isMultiple(of: 16) {
                try checkCancellation()
            }
            let previousRow =
                previous.advanced(by: row * previousStride)
            let currentRow =
                current.advanced(by: row * currentStride)
            let destinationRow =
                destination.advanced(by: row * destinationStride)
            for column in 0..<activeCount {
                destinationRow[column] = UInt8(
                    Self.blendedCode(
                        previous: UInt64(previousRow[column]),
                        current: UInt64(currentRow[column]),
                        weight: weight
                    )
                )
            }
        }
    }

    private func blendP010Rows(
        previous: UnsafePointer<UInt16>,
        previousStride: Int,
        current: UnsafePointer<UInt16>,
        currentStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int,
        activeCount: Int,
        rowCount: Int,
        weight: BlendWeight
    ) throws {
        for row in 0..<rowCount {
            if row.isMultiple(of: 16) {
                try checkCancellation()
            }
            let previousRow =
                previous.advanced(by: row * previousStride)
            let currentRow =
                current.advanced(by: row * currentStride)
            let destinationRow =
                destination.advanced(by: row * destinationStride)
            for column in 0..<activeCount {
                let previousCode = UInt64(
                    previousRow[column] >> 6
                )
                let currentCode = UInt64(
                    currentRow[column] >> 6
                )
                destinationRow[column] = UInt16(
                    Self.blendedCode(
                        previous: previousCode,
                        current: currentCode,
                        weight: weight
                    ) << 6
                )
            }
        }
    }

    private struct BlendWeight {
        let current: UInt64
        let denominator: UInt64
    }

    private static func blendWeight(
        for phase: Float
    ) throws -> BlendWeight {
        guard phase > 0, phase < 1 else {
            throw SmoothMotionInterpolationError.invalidPhase(phase)
        }
        let denominator: UInt64 = 1_024
        let current = UInt64(
            (Double(phase) * Double(denominator)).rounded()
        )
        guard current > 0, current < denominator else {
            throw SmoothMotionInterpolationError.invalidPhase(phase)
        }
        return BlendWeight(
            current: current,
            denominator: denominator
        )
    }

    private static func blendedCode(
        previous: UInt64,
        current: UInt64,
        weight: BlendWeight
    ) -> UInt64 {
        let previousWeight =
            weight.denominator - weight.current
        return (
            previous * previousWeight
                + current * weight.current
                + weight.denominator / 2
        ) / weight.denominator
    }
}

enum SmoothMotionPixelBufferContract {
    static let supportedFormats =
        R13PixelLayoutRegistry.supportedPixelFormats

    static func validatePair(
        previous: CVPixelBuffer,
        current: CVPixelBuffer
    ) throws -> OSType {
        let expectedFormat =
            CVPixelBufferGetPixelFormatType(previous)
        guard supportedFormats.contains(expectedFormat) else {
            throw SmoothMotionInterpolationError
                .unsupportedPixelFormat(expectedFormat)
        }
        for buffer in [previous, current] {
            let format = CVPixelBufferGetPixelFormatType(buffer)
            guard format == expectedFormat else {
                throw SmoothMotionInterpolationError
                    .unsupportedPixelFormat(format)
            }
            do {
                let layout = try R13PixelLayoutRegistry.layout(
                    for: format
                )
                try layout.validate(buffer)
            } catch let error as R13PixelLayoutError {
                if case .planeCountMismatch(_, let actual) = error {
                    throw SmoothMotionInterpolationError
                        .invalidPlaneCount(actual)
                }
                throw SmoothMotionInterpolationError
                    .layoutProcessingFailed(error)
            }
        }
        guard
            CVPixelBufferGetWidth(previous)
                == CVPixelBufferGetWidth(current),
            CVPixelBufferGetHeight(previous)
                == CVPixelBufferGetHeight(current)
        else {
            throw SmoothMotionInterpolationError.geometryMismatch
        }
        return expectedFormat
    }
}

enum SmoothMotionPixelBufferAttachments {
    static func copy(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) {
        CVBufferRemoveAllAttachments(destination)
        if let propagated = CVBufferCopyAttachments(
            source,
            .shouldPropagate
        ) {
            CVBufferSetAttachments(
                destination,
                propagated,
                .shouldPropagate
            )
        }
        if let local = CVBufferCopyAttachments(
            source,
            .shouldNotPropagate
        ) {
            CVBufferSetAttachments(
                destination,
                local,
                .shouldNotPropagate
            )
        }
    }
}
