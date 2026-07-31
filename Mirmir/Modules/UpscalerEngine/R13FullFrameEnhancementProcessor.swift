import CoreVideo
import Foundation

// Spatial and temporal kernels are colocated so their shared integer policy is
// reviewable as one deterministic processing contract.
// swiftlint:disable file_length

enum R13FullFrameEnhancementBufferRole: String, Equatable, Sendable {
    case source
    case output
    case restoredHistory = "restored_history"
}

enum R13FullFrameEnhancementProcessorError: Error, Equatable, Sendable {
    case invalidTargetResolution(VideoResolution)
    case frameSizeOverflow(VideoResolution)
    case unsupportedPixelFormat(
        role: R13FullFrameEnhancementBufferRole,
        actual: OSType
    )
    case resolutionMismatch(
        role: R13FullFrameEnhancementBufferRole,
        expected: VideoResolution,
        actual: VideoResolution
    )
    case invalidPlaneCount(
        role: R13FullFrameEnhancementBufferRole,
        expected: Int,
        actual: Int
    )
    case invalidPlaneGeometry(
        role: R13FullFrameEnhancementBufferRole,
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case invalidPlaneStride(
        role: R13FullFrameEnhancementBufferRole,
        plane: Int,
        minimum: Int,
        actual: Int
    )
    case inaccessiblePlane(
        role: R13FullFrameEnhancementBufferRole,
        plane: Int
    )
    case pixelBufferLockFailed(
        role: R13FullFrameEnhancementBufferRole,
        status: CVReturn
    )
    case outputAllocationFailed(CVReturn)
    case historyStorageCorrupt
    case temporalConsistencyDisabled
    case processingInProgress
    case finished
    case cancelled
}

struct R13FullFrameEnhancementMemoryPlan: Equatable, Sendable {
    let framePixelCount: Int
    /// Maximum tight NV12 payload bytes held by history during processing.
    /// Steady state briefly owns both the prior and newly captured frame.
    let maximumHistoryBytes: Int
    /// Payload bytes for reusable motion masks. Allocator metadata,
    /// pixel buffers, and shared dispatch worker stacks are not included.
    let temporalMaskBytes: Int

    var maximumProcessorOwnedBytes: Int {
        maximumHistoryBytes + temporalMaskBytes
    }
}

private struct R13ReadOnlyBytePlane: @unchecked Sendable {
    let base: UnsafePointer<UInt8>
    let stride: Int
}

private struct R13MutableBytePlane: @unchecked Sendable {
    let base: UnsafeMutablePointer<UInt8>
    let stride: Int
}

private final class R13ParallelProcessingFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: R13FullFrameEnhancementProcessorError?

    func capture(_ error: R13FullFrameEnhancementProcessorError) {
        lock.lock()
        if storedError == nil {
            storedError = error
        }
        lock.unlock()
    }

    var error: R13FullFrameEnhancementProcessorError? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }
}

/// A per-job, stateful post-scaling processor for video-range NV12 frames.
///
/// The processor performs deterministic integer-only luma enhancement. Its
/// opt-in spatial effects clean flat luma/chroma regions, restore source
/// texture, and constrain enhancement halos at strong directional edges.
/// Its independent temporal effects stabilize low-motion luma and chroma
/// against the prior processed frame. Temporal history is a tight, private
/// NV12 copy, so no caller-owned pixel buffer is retained.
final class R13FullFrameEnhancementProcessor: @unchecked Sendable {
    private enum Lifecycle {
        case active
        case finished
        case cancelled
    }

    private struct HistoryFrame: Sendable {
        let resolution: VideoResolution
        let luma: Data
        let chroma: Data
    }

    private struct MutableState {
        var lifecycle: Lifecycle = .active
        var operationInProgress = false
        var history: HistoryFrame?
    }

    private struct Strengths {
        let edgeNumerator: Int
        let edgeOvershoot: Int
        let detailNumerator: Int
        let detailOvershoot: Int
    }

    let targetResolution: VideoResolution
    let temporalConsistencyEnabled: Bool
    let edgeFidelityLevel: MirmirAdjustmentLevel
    let detailRecoveryLevel: MirmirAdjustmentLevel
    let edgePreservationEnabled: Bool
    let compressionCleanupEnabled: Bool
    let textureGrainProtectionEnabled: Bool
    let temporalStabilityEnabled: Bool

    private let pixelCount: Int
    private let chromaByteCount: Int
    private let temporalMaskByteCount: Int
    private let strengths: Strengths
    private var consistencyMotionMask: Data
    private var stabilityMotionMask: Data
    private let stateLock = NSLock()
    private var state = MutableState()

    init(
        targetResolution: VideoResolution,
        temporalConsistencyEnabled: Bool,
        edgeFidelityLevel: MirmirAdjustmentLevel,
        detailRecoveryLevel: MirmirAdjustmentLevel,
        edgePreservationEnabled: Bool = false,
        compressionCleanupEnabled: Bool = false,
        textureGrainProtectionEnabled: Bool = false,
        temporalStabilityEnabled: Bool = false
    ) throws {
        guard targetResolution.width >= 2,
              targetResolution.height >= 2,
              targetResolution.width.isMultiple(of: 2),
              targetResolution.height.isMultiple(of: 2) else {
            throw R13FullFrameEnhancementProcessorError
                .invalidTargetResolution(targetResolution)
        }
        let (pixelCount, pixelCountOverflow) =
            targetResolution.width.multipliedReportingOverflow(
                by: targetResolution.height
            )
        guard !pixelCountOverflow,
              pixelCount <= Int(UInt64.max / 255) else {
            throw R13FullFrameEnhancementProcessorError
                .frameSizeOverflow(targetResolution)
        }
        let chromaByteCount = pixelCount / 2
        guard chromaByteCount >= 2 else {
            throw R13FullFrameEnhancementProcessorError
                .frameSizeOverflow(targetResolution)
        }

        self.targetResolution = targetResolution
        self.temporalConsistencyEnabled = temporalConsistencyEnabled
        self.edgeFidelityLevel = edgeFidelityLevel
        self.detailRecoveryLevel = detailRecoveryLevel
        self.edgePreservationEnabled = edgePreservationEnabled
        self.compressionCleanupEnabled = compressionCleanupEnabled
        self.textureGrainProtectionEnabled =
            textureGrainProtectionEnabled
        self.temporalStabilityEnabled = temporalStabilityEnabled
        self.pixelCount = pixelCount
        self.chromaByteCount = chromaByteCount
        self.temporalMaskByteCount =
            (temporalConsistencyEnabled ? pixelCount : 0)
            + (temporalStabilityEnabled ? pixelCount : 0)
        self.consistencyMotionMask = Data(
            count: temporalConsistencyEnabled ? pixelCount : 0
        )
        self.stabilityMotionMask = Data(
            count: temporalStabilityEnabled ? pixelCount : 0
        )
        self.strengths = Strengths(
            edgeNumerator: Self.edgeNumerator(edgeFidelityLevel),
            edgeOvershoot: Self.edgeOvershoot(edgeFidelityLevel),
            detailNumerator: Self.detailNumerator(detailRecoveryLevel),
            detailOvershoot: Self.detailOvershoot(detailRecoveryLevel)
        )
    }

    var memoryPlan: R13FullFrameEnhancementMemoryPlan {
        R13FullFrameEnhancementMemoryPlan(
            framePixelCount: pixelCount,
            maximumHistoryBytes:
                retainsTemporalHistory
                    ? 2 * (pixelCount + chromaByteCount)
                    : 0,
            temporalMaskBytes: temporalMaskByteCount
        )
    }

    func process(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let previousHistory = try beginOperation()
        var operationCompleted = false
        defer {
            if !operationCompleted {
                abandonOperation()
            }
        }

        try checkCancellation()
        try validate(source, role: .source)
        let output = try makeOutputBuffer(propagatingAttachmentsFrom: source)
        try applySpatialEnhancement(source: source, output: output)
        if retainsTemporalHistory, let previousHistory {
            try applyTemporalStabilization(
                to: output,
                previous: previousHistory
            )
        }
        try checkCancellation()
        let nextHistory: HistoryFrame?
        if retainsTemporalHistory {
            nextHistory = try captureHistory(
                from: output,
                role: .output
            )
        } else {
            nextHistory = nil
        }
        try commitOperation(history: nextHistory)
        operationCompleted = true
        return output
    }

    /// Restores state from an output whose cache identity and integrity were
    /// verified by the caller. This method additionally validates and copies
    /// the frame geometry and NV12 representation before accepting it.
    func restoreTemporalHistory(
        from verifiedCachedOutput: CVPixelBuffer
    ) throws {
        guard retainsTemporalHistory else {
            throw R13FullFrameEnhancementProcessorError
                .temporalConsistencyDisabled
        }
        _ = try beginOperation()
        var operationCompleted = false
        defer {
            if !operationCompleted {
                abandonOperation()
            }
        }

        try checkCancellation()
        try validate(
            verifiedCachedOutput,
            role: .restoredHistory
        )
        let restored = try captureHistory(
            from: verifiedCachedOutput,
            role: .restoredHistory
        )
        try checkCancellation()
        try commitOperation(history: restored)
        operationCompleted = true
    }

    /// Clears prior-frame state at a discontinuity while keeping the processor
    /// available for subsequent frames in the same job.
    func reset() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state.lifecycle {
        case .active:
            guard !state.operationInProgress else {
                throw R13FullFrameEnhancementProcessorError
                    .processingInProgress
            }
            state.history = nil
        case .finished:
            throw R13FullFrameEnhancementProcessorError.finished
        case .cancelled:
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
    }

    /// Releases history and terminalizes successful processing. Repeated calls
    /// after successful terminalization are harmless.
    func finish() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state.lifecycle {
        case .active:
            guard !state.operationInProgress else {
                throw R13FullFrameEnhancementProcessorError
                    .processingInProgress
            }
            state.history = nil
            releaseTemporalWorkspace()
            state.lifecycle = .finished
        case .finished:
            return
        case .cancelled:
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
    }

    /// Requests terminal cancellation. Row-level checks bound the amount of
    /// additional scalar work performed by an in-flight operation.
    func cancel() {
        stateLock.lock()
        if case .active = state.lifecycle {
            state.lifecycle = .cancelled
            state.history = nil
            if !state.operationInProgress {
                releaseTemporalWorkspace()
            }
        }
        stateLock.unlock()
    }
}

private extension R13FullFrameEnhancementProcessor {
    static let temporalPixelDifferenceThreshold = 6
    static let temporalNeighborDifferenceThreshold = 10
    static let temporalChromaDifferenceThreshold = 8
    static let stabilityPixelDifferenceThreshold = 14
    static let stabilityNeighborDifferenceThreshold = 18
    static let stabilityChromaDifferenceThreshold = 12
    static let sceneMeanDifferenceThreshold = 48
    static let sceneLargeDifferenceThreshold = 32
    static let sceneLargeDifferencePercentage = 65
    static let cancellationRowInterval = 16
    static let strongEdgeRangeThreshold = 32
    static let flatCleanupRangeThreshold = 18
    static let chromaCleanupRangeThreshold = 12
    static let blockBoundarySize = 8
    static let parallelRowThreshold = 64
    static let parallelRowChunkSize = 16

    var retainsTemporalHistory: Bool {
        temporalConsistencyEnabled || temporalStabilityEnabled
    }

    func processRows(
        _ rows: Range<Int>,
        body: @escaping @Sendable (Int) -> Void
    ) throws {
        guard !rows.isEmpty else {
            return
        }
        guard rows.count >= Self.parallelRowThreshold,
              ProcessInfo.processInfo.activeProcessorCount > 1 else {
            for row in rows {
                if row.isMultiple(of: Self.cancellationRowInterval) {
                    try checkCancellation()
                }
                body(row)
            }
            return
        }

        try checkCancellation()
        let chunkSize = Self.parallelRowChunkSize
        let chunkCount =
            (rows.count + chunkSize - 1) / chunkSize
        let failure = R13ParallelProcessingFailure()
        DispatchQueue.concurrentPerform(iterations: chunkCount) {
            chunkIndex in
            guard failure.error == nil else {
                return
            }
            do {
                try checkCancellation()
            } catch let error as
                    R13FullFrameEnhancementProcessorError {
                failure.capture(error)
                return
            } catch {
                failure.capture(.cancelled)
                return
            }
            let lowerBound =
                rows.lowerBound + chunkIndex * chunkSize
            let upperBound = min(
                rows.upperBound,
                lowerBound + chunkSize
            )
            for row in lowerBound..<upperBound {
                body(row)
            }
        }
        if let error = failure.error {
            throw error
        }
        try checkCancellation()
    }

    static func edgeNumerator(
        _ level: MirmirAdjustmentLevel
    ) -> Int {
        switch level {
        case .low:
            return 1
        case .medium:
            return 2
        case .high:
            return 4
        }
    }

    static func edgeOvershoot(
        _ level: MirmirAdjustmentLevel
    ) -> Int {
        switch level {
        case .low:
            return 2
        case .medium:
            return 6
        case .high:
            return 12
        }
    }

    static func detailNumerator(
        _ level: MirmirAdjustmentLevel
    ) -> Int {
        switch level {
        case .low:
            return 1
        case .medium:
            return 3
        case .high:
            return 5
        }
    }

    static func detailOvershoot(
        _ level: MirmirAdjustmentLevel
    ) -> Int {
        switch level {
        case .low:
            return 1
        case .medium:
            return 4
        case .high:
            return 8
        }
    }

    private func beginOperation() throws -> HistoryFrame? {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state.lifecycle {
        case .active:
            guard !state.operationInProgress else {
                throw R13FullFrameEnhancementProcessorError
                    .processingInProgress
            }
            state.operationInProgress = true
            return state.history
        case .finished:
            throw R13FullFrameEnhancementProcessorError.finished
        case .cancelled:
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
    }

    func abandonOperation() {
        stateLock.lock()
        state.operationInProgress = false
        if case .cancelled = state.lifecycle {
            releaseTemporalWorkspace()
        }
        stateLock.unlock()
    }

    func releaseTemporalWorkspace() {
        consistencyMotionMask.removeAll(keepingCapacity: false)
        stabilityMotionMask.removeAll(keepingCapacity: false)
    }

    private func commitOperation(history: HistoryFrame?) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        state.operationInProgress = false
        switch state.lifecycle {
        case .active:
            state.history = history
        case .finished:
            throw R13FullFrameEnhancementProcessorError.finished
        case .cancelled:
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
    }

    func checkCancellation() throws {
        if Task.isCancelled {
            cancel()
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
        stateLock.lock()
        let isCancelled: Bool
        switch state.lifecycle {
        case .cancelled:
            isCancelled = true
        case .active, .finished:
            isCancelled = false
        }
        stateLock.unlock()
        if isCancelled {
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
    }

    func validate(
        _ pixelBuffer: CVPixelBuffer,
        role: R13FullFrameEnhancementBufferRole
    ) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format ==
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw R13FullFrameEnhancementProcessorError
                .unsupportedPixelFormat(role: role, actual: format)
        }
        let actualResolution = VideoResolution(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard actualResolution == targetResolution else {
            throw R13FullFrameEnhancementProcessorError
                .resolutionMismatch(
                    role: role,
                    expected: targetResolution,
                    actual: actualResolution
                )
        }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount == 2 else {
            throw R13FullFrameEnhancementProcessorError
                .invalidPlaneCount(
                    role: role,
                    expected: 2,
                    actual: planeCount
                )
        }
        try validatePlane(
            pixelBuffer,
            role: role,
            plane: 0,
            expectedWidth: targetResolution.width,
            expectedHeight: targetResolution.height,
            minimumStride: targetResolution.width
        )
        try validatePlane(
            pixelBuffer,
            role: role,
            plane: 1,
            expectedWidth: targetResolution.width / 2,
            expectedHeight: targetResolution.height / 2,
            minimumStride: targetResolution.width
        )
    }

    func validatePlane(
        _ pixelBuffer: CVPixelBuffer,
        role: R13FullFrameEnhancementBufferRole,
        plane: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        minimumStride: Int
    ) throws {
        let actualWidth = CVPixelBufferGetWidthOfPlane(
            pixelBuffer,
            plane
        )
        let actualHeight = CVPixelBufferGetHeightOfPlane(
            pixelBuffer,
            plane
        )
        guard actualWidth == expectedWidth,
              actualHeight == expectedHeight else {
            throw R13FullFrameEnhancementProcessorError
                .invalidPlaneGeometry(
                    role: role,
                    plane: plane,
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight,
                    actualWidth: actualWidth,
                    actualHeight: actualHeight
                )
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            plane
        )
        guard stride >= minimumStride else {
            throw R13FullFrameEnhancementProcessorError
                .invalidPlaneStride(
                    role: role,
                    plane: plane,
                    minimum: minimumStride,
                    actual: stride
                )
        }
    }

    func makeOutputBuffer(
        propagatingAttachmentsFrom source: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ] as CFDictionary
        var optionalOutput: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetResolution.width,
            targetResolution.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &optionalOutput
        )
        guard status == kCVReturnSuccess,
              let output = optionalOutput else {
            throw R13FullFrameEnhancementProcessorError
                .outputAllocationFailed(status)
        }
        CVBufferPropagateAttachments(source, output)
        copyColorAttachments(from: source, to: output)
        try validate(output, role: .output)
        return output
    }

    func copyColorAttachments(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer
    ) {
        let keys: [CFString] = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferGammaLevelKey,
            kCVImageBufferICCProfileKey,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey
        ]
        for key in keys {
            var mode = CVAttachmentMode.shouldPropagate
            guard let value = CVBufferCopyAttachment(
                source,
                key,
                &mode
            ) else {
                continue
            }
            CVBufferSetAttachment(destination, key, value, mode)
        }
    }

    // swiftlint:disable:next function_body_length
    func applySpatialEnhancement(
        source: CVPixelBuffer,
        output: CVPixelBuffer
    ) throws {
        let sourceLock = CVPixelBufferLockBaseAddress(
            source,
            .readOnly
        )
        guard sourceLock == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .source,
                    status: sourceLock
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let outputLock = CVPixelBufferLockBaseAddress(output, [])
        guard outputLock == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .output,
                    status: outputLock
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let sourceLumaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(source, 0) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .source, plane: 0)
        }
        guard let sourceChromaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(source, 1) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .source, plane: 1)
        }
        guard let outputLumaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(output, 0) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .output, plane: 0)
        }
        guard let outputChromaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(output, 1) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .output, plane: 1)
        }

        let sourceLuma = sourceLumaAddress
            .assumingMemoryBound(to: UInt8.self)
        let sourceChroma = sourceChromaAddress
            .assumingMemoryBound(to: UInt8.self)
        let outputLuma = outputLumaAddress
            .assumingMemoryBound(to: UInt8.self)
        let outputChroma = outputChromaAddress
            .assumingMemoryBound(to: UInt8.self)
        let sourceLumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let sourceChromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let outputLumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let outputChromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        let width = targetResolution.width
        let height = targetResolution.height

        for row in 0..<height {
            if row.isMultiple(of: Self.cancellationRowInterval) {
                try checkCancellation()
            }
            outputLuma
                .advanced(by: row * outputLumaStride)
                .update(
                    from: sourceLuma.advanced(
                        by: row * sourceLumaStride
                    ),
                    count: width
                )
        }
        for row in 0..<(height / 2) {
            if row.isMultiple(of: Self.cancellationRowInterval) {
                try checkCancellation()
            }
            outputChroma
                .advanced(by: row * outputChromaStride)
                .update(
                    from: sourceChroma.advanced(
                        by: row * sourceChromaStride
                    ),
                    count: width
                )
        }

        guard width > 2, height > 2 else {
            return
        }
        let sourceLumaPlane = R13ReadOnlyBytePlane(
            base: sourceLuma,
            stride: sourceLumaStride
        )
        let outputLumaPlane = R13MutableBytePlane(
            base: outputLuma,
            stride: outputLumaStride
        )
        try processRows(1..<(height - 1)) { [self] row in
            let prior = sourceLumaPlane.base.advanced(
                by: (row - 1) * sourceLumaPlane.stride
            )
            let current = sourceLumaPlane.base.advanced(
                by: row * sourceLumaPlane.stride
            )
            let next = sourceLumaPlane.base.advanced(
                by: (row + 1) * sourceLumaPlane.stride
            )
            let destination = outputLumaPlane.base.advanced(
                by: row * outputLumaPlane.stride
            )
            for column in 1..<(width - 1) {
                destination[column] = enhancedLuma(
                    prior: prior,
                    current: current,
                    next: next,
                    row: row,
                    column: column
                )
            }
        }
        // Cleanup runs before restoration/limiting so later effects can
        // recover source texture and strong-edge shape from this pass.
        if compressionCleanupEnabled {
            try applyChromaCompressionCleanup(
                source: sourceChroma,
                sourceStride: sourceChromaStride,
                destination: outputChroma,
                destinationStride: outputChromaStride
            )
        }
    }

    @inline(__always)
    func enhancedLuma(
        prior: UnsafePointer<UInt8>,
        current: UnsafePointer<UInt8>,
        next: UnsafePointer<UInt8>,
        row: Int,
        column: Int
    ) -> UInt8 {
        let center = Int(current[column])
        let north = Int(prior[column])
        let south = Int(next[column])
        let west = Int(current[column - 1])
        let east = Int(current[column + 1])
        let northWest = Int(prior[column - 1])
        let northEast = Int(prior[column + 1])
        let southWest = Int(next[column - 1])
        let southEast = Int(next[column + 1])

        let cardinalSum = north + south + west + east
        let boxSum = center + cardinalSum
            + northWest + northEast + southWest + southEast
        let cardinalMean = (cardinalSum + 2) / 4
        let boxMean = (boxSum + 4) / 9
        let localMinimum = min(
            min(center, north),
            min(
                min(south, west),
                min(
                    min(east, northWest),
                    min(northEast, min(southWest, southEast))
                )
            )
        )
        let localMaximum = max(
            max(center, north),
            max(
                max(south, west),
                max(
                    max(east, northWest),
                    max(northEast, max(southWest, southEast))
                )
            )
        )
        let localRange = localMaximum - localMinimum

        var adjustment = 0
        if localRange >= 6 {
            adjustment += Self.roundedDivide(
                (center - cardinalMean)
                    * strengths.edgeNumerator,
                by: 8
            )
        }
        if (2...80).contains(localRange) {
            adjustment += Self.roundedDivide(
                (center - boxMean)
                    * strengths.detailNumerator,
                by: 16
            )
        }

        let overshoot =
            strengths.edgeOvershoot + strengths.detailOvershoot
        let lowerBound = max(0, localMinimum - overshoot)
        let upperBound = min(255, localMaximum + overshoot)
        var processed = min(
            upperBound,
            max(lowerBound, center + adjustment)
        )
        if compressionCleanupEnabled {
            processed = compressionCleanedLuma(
                processed: processed,
                center: center,
                north: north,
                south: south,
                west: west,
                east: east,
                cardinalMean: cardinalMean,
                localRange: localRange,
                row: row,
                column: column
            )
        }
        if textureGrainProtectionEnabled,
           isHighFrequencyTexture(
               center: center,
               north: north,
               south: south,
               west: west,
               east: east,
               northWest: northWest,
               northEast: northEast,
               southWest: southWest,
               southEast: southEast,
               localRange: localRange
           ) {
            processed = Self.roundedDivide(
                3 * center + processed,
                by: 4
            )
        }
        if edgePreservationEnabled,
           isStrongDirectionalEdge(
               north: north,
               south: south,
               west: west,
               east: east,
               localRange: localRange
           ) {
            processed = min(
                center + 2,
                max(center - 2, processed)
            )
        }
        return UInt8(min(255, max(0, processed)))
    }

    @inline(__always)
    func compressionCleanedLuma(
        processed: Int,
        center: Int,
        north: Int,
        south: Int,
        west: Int,
        east: Int,
        cardinalMean: Int,
        localRange: Int,
        row: Int,
        column: Int
    ) -> Int {
        // A hard local-range gate keeps deblocking out of strong edges.
        guard localRange <= Self.flatCleanupRangeThreshold else {
            return processed
        }
        let flatRegionValue = Self.roundedDivide(
            processed + cardinalMean,
            by: 2
        )
        var accumulated = flatRegionValue
        var boundaryContributionCount = 1

        if let horizontalBoundaryValue = blockBoundaryCleanupValue(
            center: center,
            negativeNeighbor: west,
            positiveNeighbor: east,
            coordinate: column
        ) {
            accumulated += horizontalBoundaryValue
            boundaryContributionCount += 1
        }
        if let verticalBoundaryValue = blockBoundaryCleanupValue(
            center: center,
            negativeNeighbor: north,
            positiveNeighbor: south,
            coordinate: row
        ) {
            accumulated += verticalBoundaryValue
            boundaryContributionCount += 1
        }
        return Self.roundedDivide(
            accumulated,
            by: boundaryContributionCount
        )
    }

    @inline(__always)
    func blockBoundaryCleanupValue(
        center: Int,
        negativeNeighbor: Int,
        positiveNeighbor: Int,
        coordinate: Int
    ) -> Int? {
        // This pass examines a fixed eight-sample boundary grid. Only a
        // modest discontinuity with a flat same-side neighbor is eligible,
        // preventing this path from treating a strong scene edge as a
        // compression boundary.
        let boundaryRemainder =
            coordinate % Self.blockBoundarySize
        let opposite: Int
        let sameSide: Int
        if boundaryRemainder == 0 {
            opposite = negativeNeighbor
            sameSide = positiveNeighbor
        } else if boundaryRemainder ==
                    Self.blockBoundarySize - 1 {
            opposite = positiveNeighbor
            sameSide = negativeNeighbor
        } else {
            return nil
        }
        let boundaryDifference = abs(center - opposite)
        guard (3...Self.flatCleanupRangeThreshold)
                .contains(boundaryDifference),
              abs(center - sameSide) <= 4 else {
            return nil
        }
        return Self.roundedDivide(
            3 * center + opposite,
            by: 4
        )
    }

    @inline(__always)
    func isStrongDirectionalEdge(
        north: Int,
        south: Int,
        west: Int,
        east: Int,
        localRange: Int
    ) -> Bool {
        guard localRange >= Self.strongEdgeRangeThreshold else {
            return false
        }
        let horizontalContrast = abs(east - west)
        let verticalContrast = abs(south - north)
        return max(horizontalContrast, verticalContrast) >=
            Self.strongEdgeRangeThreshold
    }

    @inline(__always)
    func isHighFrequencyTexture(
        center: Int,
        north: Int,
        south: Int,
        west: Int,
        east: Int,
        northWest: Int,
        northEast: Int,
        southWest: Int,
        southEast: Int,
        localRange: Int
    ) -> Bool {
        guard (6...64).contains(localRange) else {
            return false
        }
        // Alternating samples with matching diagonals identify grid-like
        // texture; signed neighbor counts also retain irregular grain.
        let cardinalContrastCount =
            (abs(north - center) >= 6 ? 1 : 0)
            + (abs(south - center) >= 6 ? 1 : 0)
            + (abs(west - center) >= 6 ? 1 : 0)
            + (abs(east - center) >= 6 ? 1 : 0)
        let diagonalSimilarityCount =
            (abs(northWest - center) <= 3 ? 1 : 0)
            + (abs(northEast - center) <= 3 ? 1 : 0)
            + (abs(southWest - center) <= 3 ? 1 : 0)
            + (abs(southEast - center) <= 3 ? 1 : 0)
        let positiveNeighborCount =
            (north - center >= 5 ? 1 : 0)
            + (south - center >= 5 ? 1 : 0)
            + (west - center >= 5 ? 1 : 0)
            + (east - center >= 5 ? 1 : 0)
            + (northWest - center >= 5 ? 1 : 0)
            + (northEast - center >= 5 ? 1 : 0)
            + (southWest - center >= 5 ? 1 : 0)
            + (southEast - center >= 5 ? 1 : 0)
        let negativeNeighborCount =
            (center - north >= 5 ? 1 : 0)
            + (center - south >= 5 ? 1 : 0)
            + (center - west >= 5 ? 1 : 0)
            + (center - east >= 5 ? 1 : 0)
            + (center - northWest >= 5 ? 1 : 0)
            + (center - northEast >= 5 ? 1 : 0)
            + (center - southWest >= 5 ? 1 : 0)
            + (center - southEast >= 5 ? 1 : 0)
        return (
            cardinalContrastCount >= 3
                && diagonalSimilarityCount >= 2
        ) || (
            positiveNeighborCount >= 2
                && negativeNeighborCount >= 2
        )
    }

    func applyChromaCompressionCleanup(
        source: UnsafePointer<UInt8>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt8>,
        destinationStride: Int
    ) throws {
        let chromaWidth = targetResolution.width / 2
        let chromaHeight = targetResolution.height / 2
        guard chromaWidth > 2, chromaHeight > 2 else {
            return
        }
        let sourcePlane = R13ReadOnlyBytePlane(
            base: source,
            stride: sourceStride
        )
        let destinationPlane = R13MutableBytePlane(
            base: destination,
            stride: destinationStride
        )
        let rows = 1..<(chromaHeight - 1)
        try processRows(rows) { [self] row in
            processChromaCleanupRow(
                row,
                chromaWidth: chromaWidth,
                source: sourcePlane,
                destination: destinationPlane
            )
        }
    }

    func processChromaCleanupRow(
        _ row: Int,
        chromaWidth: Int,
        source: R13ReadOnlyBytePlane,
        destination: R13MutableBytePlane
    ) {
        for column in 1..<(chromaWidth - 1) {
            for component in 0..<2 {
                processChromaCleanupSample(
                    row: row,
                    column: column,
                    component: component,
                    source: source,
                    destination: destination
                )
            }
        }
    }

    @inline(__always)
    func processChromaCleanupSample(
        row: Int,
        column: Int,
        component: Int,
        source: R13ReadOnlyBytePlane,
        destination: R13MutableBytePlane
    ) {
        let byteOffset = column * 2 + component
        let center = Int(
            source.base[row * source.stride + byteOffset]
        )
        let north = Int(
            source.base[
                (row - 1) * source.stride + byteOffset
            ]
        )
        let south = Int(
            source.base[
                (row + 1) * source.stride + byteOffset
            ]
        )
        let west = Int(
            source.base[
                row * source.stride
                    + (column - 1) * 2
                    + component
            ]
        )
        let east = Int(
            source.base[
                row * source.stride
                    + (column + 1) * 2
                    + component
            ]
        )
        let localMinimum = min(
            center,
            min(min(north, south), min(west, east))
        )
        let localMaximum = max(
            center,
            max(max(north, south), max(west, east))
        )
        guard localMaximum - localMinimum <=
                Self.chromaCleanupRangeThreshold else {
            return
        }
        destination.base[
            row * destination.stride + byteOffset
        ] = UInt8(
            (
                4 * center
                    + north
                    + south
                    + west
                    + east
                    + 4
            ) / 8
        )
    }

    @inline(__always)
    static func roundedDivide(
        _ numerator: Int,
        by denominator: Int
    ) -> Int {
        if numerator >= 0 {
            return (numerator + denominator / 2) / denominator
        }
        return -((-numerator + denominator / 2) / denominator)
    }

    private func applyTemporalStabilization(
        to output: CVPixelBuffer,
        previous: HistoryFrame
    ) throws {
        guard previous.resolution == targetResolution,
              previous.luma.count == pixelCount,
              previous.chroma.count == chromaByteCount else {
            throw R13FullFrameEnhancementProcessorError
                .historyStorageCorrupt
        }
        let lockStatus = CVPixelBufferLockBaseAddress(output, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .output,
                    status: lockStatus
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        guard let lumaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(output, 0) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .output, plane: 0)
        }
        guard let chromaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(output, 1) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .output, plane: 1)
        }

        let currentLuma = lumaAddress
            .assumingMemoryBound(to: UInt8.self)
        let currentChroma = chromaAddress
            .assumingMemoryBound(to: UInt8.self)
        let lumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let chromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        var sceneTransitionDetected = false

        try previous.luma.withUnsafeBytes { historyBytes in
            guard let historyBase = historyBytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let historyLuma = historyBase
                .assumingMemoryBound(to: UInt8.self)
            sceneTransitionDetected = try isSceneTransition(
                currentLuma: currentLuma,
                currentStride: lumaStride,
                previousLuma: historyLuma
            )
            guard !sceneTransitionDetected else {
                return
            }
            if temporalConsistencyEnabled {
                try populateMotionMask(
                    &consistencyMotionMask,
                    currentLuma: currentLuma,
                    currentStride: lumaStride,
                    previousLuma: historyLuma,
                    pixelDifferenceThreshold:
                        Self.temporalPixelDifferenceThreshold,
                    neighborDifferenceThreshold:
                        Self.temporalNeighborDifferenceThreshold
                )
            }
            if temporalStabilityEnabled {
                try populateMotionMask(
                    &stabilityMotionMask,
                    currentLuma: currentLuma,
                    currentStride: lumaStride,
                    previousLuma: historyLuma,
                    pixelDifferenceThreshold:
                        Self.stabilityPixelDifferenceThreshold,
                    neighborDifferenceThreshold:
                        Self.stabilityNeighborDifferenceThreshold
                )
            }
            if temporalConsistencyEnabled {
                try blendLuma(
                    currentLuma,
                    stride: lumaStride,
                    previousLuma: historyLuma,
                    motionMask: consistencyMotionMask,
                    currentWeight: 3,
                    previousWeight: 1
                )
            }
            if temporalStabilityEnabled {
                try blendLuma(
                    currentLuma,
                    stride: lumaStride,
                    previousLuma: historyLuma,
                    motionMask: stabilityMotionMask,
                    currentWeight: 1,
                    previousWeight: 1
                )
            }
        }
        guard !sceneTransitionDetected else {
            return
        }
        try previous.chroma.withUnsafeBytes { historyBytes in
            guard let historyBase = historyBytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let historyChroma = historyBase
                .assumingMemoryBound(to: UInt8.self)
            if temporalConsistencyEnabled {
                try blendChroma(
                    currentChroma,
                    stride: chromaStride,
                    previousChroma: historyChroma,
                    motionMask: consistencyMotionMask,
                    differenceThreshold:
                        Self.temporalChromaDifferenceThreshold,
                    currentWeight: 3,
                    previousWeight: 1
                )
            }
            if temporalStabilityEnabled {
                try blendChroma(
                    currentChroma,
                    stride: chromaStride,
                    previousChroma: historyChroma,
                    motionMask: stabilityMotionMask,
                    differenceThreshold:
                        Self.stabilityChromaDifferenceThreshold,
                    currentWeight: 1,
                    previousWeight: 1
                )
            }
        }
    }

    func isSceneTransition(
        currentLuma: UnsafePointer<UInt8>,
        currentStride: Int,
        previousLuma: UnsafePointer<UInt8>
    ) throws -> Bool {
        var totalDifference: UInt64 = 0
        var largeDifferenceCount: UInt64 = 0
        let width = targetResolution.width
        let height = targetResolution.height
        for row in 0..<height {
            if row.isMultiple(of: Self.cancellationRowInterval) {
                try checkCancellation()
            }
            let currentRow = currentLuma.advanced(
                by: row * currentStride
            )
            let previousRow = previousLuma.advanced(
                by: row * width
            )
            for column in 0..<width {
                let difference = abs(
                    Int(currentRow[column])
                        - Int(previousRow[column])
                )
                totalDifference += UInt64(difference)
                if difference >= Self.sceneLargeDifferenceThreshold {
                    largeDifferenceCount += 1
                }
            }
        }
        let count = UInt64(pixelCount)
        return totalDifference >=
                count * UInt64(Self.sceneMeanDifferenceThreshold)
            || largeDifferenceCount * 100 >=
                count * UInt64(Self.sceneLargeDifferencePercentage)
    }

    func populateMotionMask(
        _ motionMask: inout Data,
        currentLuma: UnsafePointer<UInt8>,
        currentStride: Int,
        previousLuma: UnsafePointer<UInt8>,
        pixelDifferenceThreshold: Int,
        neighborDifferenceThreshold: Int
    ) throws {
        guard motionMask.count == pixelCount else {
            throw R13FullFrameEnhancementProcessorError
                .historyStorageCorrupt
        }
        let width = targetResolution.width
        let height = targetResolution.height
        try motionMask.withUnsafeMutableBytes { maskBytes in
            guard let maskBase = maskBytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let mask = maskBase.assumingMemoryBound(to: UInt8.self)
            mask.initialize(repeating: 0, count: pixelCount)
            let currentPlane = R13ReadOnlyBytePlane(
                base: currentLuma,
                stride: currentStride
            )
            let previousPlane = R13ReadOnlyBytePlane(
                base: previousLuma,
                stride: width
            )
            let maskPlane = R13MutableBytePlane(
                base: mask,
                stride: width
            )
            try processRows(0..<height) { row in
                let currentRow = currentPlane.base.advanced(
                    by: row * currentPlane.stride
                )
                let previousRow = previousPlane.base.advanced(
                    by: row * previousPlane.stride
                )
                for column in 0..<width {
                    let difference = abs(
                        Int(currentRow[column])
                            - Int(previousRow[column])
                    )
                    guard difference <=
                            pixelDifferenceThreshold else {
                        continue
                    }
                    let northRow = max(row - 1, 0)
                    let southRow = min(row + 1, height - 1)
                    let westColumn = max(column - 1, 0)
                    let eastColumn = min(column + 1, width - 1)
                    let northIsStable = Self.samplesAreClose(
                        currentPlane.base[
                            northRow * currentPlane.stride + column
                        ],
                        previousPlane.base[
                            northRow * previousPlane.stride + column
                        ],
                        threshold: neighborDifferenceThreshold
                    )
                    let southIsStable = Self.samplesAreClose(
                        currentPlane.base[
                            southRow * currentPlane.stride + column
                        ],
                        previousPlane.base[
                            southRow * previousPlane.stride + column
                        ],
                        threshold: neighborDifferenceThreshold
                    )
                    let westIsStable = Self.samplesAreClose(
                        currentPlane.base[
                            row * currentPlane.stride + westColumn
                        ],
                        previousPlane.base[
                            row * previousPlane.stride + westColumn
                        ],
                        threshold: neighborDifferenceThreshold
                    )
                    let eastIsStable = Self.samplesAreClose(
                        currentPlane.base[
                            row * currentPlane.stride + eastColumn
                        ],
                        previousPlane.base[
                            row * previousPlane.stride + eastColumn
                        ],
                        threshold: neighborDifferenceThreshold
                    )
                    let neighborhoodIsStable =
                        northIsStable
                        && southIsStable
                        && westIsStable
                        && eastIsStable
                    if neighborhoodIsStable {
                        maskPlane.base[
                            row * maskPlane.stride + column
                        ] = 1
                    }
                }
            }
        }
    }

    func blendLuma(
        _ currentLuma: UnsafeMutablePointer<UInt8>,
        stride: Int,
        previousLuma: UnsafePointer<UInt8>,
        motionMask: Data,
        currentWeight: Int,
        previousWeight: Int
    ) throws {
        let width = targetResolution.width
        let height = targetResolution.height
        try motionMask.withUnsafeBytes { maskBytes in
            guard let maskBase = maskBytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let mask = maskBase.assumingMemoryBound(to: UInt8.self)
            let currentPlane = R13MutableBytePlane(
                base: currentLuma,
                stride: stride
            )
            let previousPlane = R13ReadOnlyBytePlane(
                base: previousLuma,
                stride: width
            )
            let maskPlane = R13ReadOnlyBytePlane(
                base: mask,
                stride: width
            )
            try processRows(0..<height) { row in
                let currentRow = currentPlane.base.advanced(
                    by: row * currentPlane.stride
                )
                let previousRow = previousPlane.base.advanced(
                    by: row * previousPlane.stride
                )
                let maskRow = maskPlane.base.advanced(
                    by: row * maskPlane.stride
                )
                for column in 0..<width where maskRow[column] == 1 {
                    currentRow[column] = Self.weightedBlend(
                        current: currentRow[column],
                        previous: previousRow[column],
                        currentWeight: currentWeight,
                        previousWeight: previousWeight
                    )
                }
            }
        }
    }

    func blendChroma(
        _ currentChroma: UnsafeMutablePointer<UInt8>,
        stride: Int,
        previousChroma: UnsafePointer<UInt8>,
        motionMask: Data,
        differenceThreshold: Int,
        currentWeight: Int,
        previousWeight: Int
    ) throws {
        let width = targetResolution.width
        let chromaWidth = width / 2
        let chromaHeight = targetResolution.height / 2
        try motionMask.withUnsafeBytes { maskBytes in
            guard let maskBase = maskBytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let mask = maskBase.assumingMemoryBound(to: UInt8.self)
            let currentPlane = R13MutableBytePlane(
                base: currentChroma,
                stride: stride
            )
            let previousPlane = R13ReadOnlyBytePlane(
                base: previousChroma,
                stride: width
            )
            let maskPlane = R13ReadOnlyBytePlane(
                base: mask,
                stride: width
            )
            try processRows(0..<chromaHeight) { row in
                let currentRow = currentPlane.base.advanced(
                    by: row * currentPlane.stride
                )
                let previousRow = previousPlane.base.advanced(
                    by: row * previousPlane.stride
                )
                for column in 0..<chromaWidth {
                    let lumaRow = row * 2
                    let lumaColumn = column * 2
                    let topLeftMaskIndex =
                        lumaRow * width + lumaColumn
                    let bottomLeftMaskIndex =
                        (lumaRow + 1) * width + lumaColumn
                    guard maskPlane.base[topLeftMaskIndex] == 1,
                          maskPlane.base[topLeftMaskIndex + 1] == 1,
                          maskPlane.base[bottomLeftMaskIndex] == 1,
                          maskPlane.base[bottomLeftMaskIndex + 1] == 1 else {
                        continue
                    }
                    let byteOffset = column * 2
                    for component in 0..<2 {
                        let index = byteOffset + component
                        let difference = abs(
                            Int(currentRow[index])
                                - Int(previousRow[index])
                        )
                        guard difference <= differenceThreshold else {
                            continue
                        }
                        currentRow[index] = Self.weightedBlend(
                            current: currentRow[index],
                            previous: previousRow[index],
                            currentWeight: currentWeight,
                            previousWeight: previousWeight
                        )
                    }
                }
            }
        }
    }

    @inline(__always)
    static func samplesAreClose(
        _ lhs: UInt8,
        _ rhs: UInt8,
        threshold: Int
    ) -> Bool {
        abs(Int(lhs) - Int(rhs)) <= threshold
    }

    @inline(__always)
    static func weightedBlend(
        current: UInt8,
        previous: UInt8,
        currentWeight: Int,
        previousWeight: Int
    ) -> UInt8 {
        let denominator = currentWeight + previousWeight
        return UInt8(
            (
                currentWeight * Int(current)
                    + previousWeight * Int(previous)
                    + denominator / 2
            ) / denominator
        )
    }

    private func captureHistory(
        from pixelBuffer: CVPixelBuffer,
        role: R13FullFrameEnhancementBufferRole
    ) throws -> HistoryFrame {
        let lockStatus = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard lockStatus == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: role,
                    status: lockStatus
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let lumaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: role, plane: 0)
        }
        guard let chromaAddress =
                  CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: role, plane: 1)
        }
        let lumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let luma = try copyTightPlane(
            lumaAddress,
            sourceStride: lumaStride,
            activeBytesPerRow: targetResolution.width,
            rowCount: targetResolution.height
        )
        let chroma = try copyTightPlane(
            chromaAddress,
            sourceStride: chromaStride,
            activeBytesPerRow: targetResolution.width,
            rowCount: targetResolution.height / 2
        )
        return HistoryFrame(
            resolution: targetResolution,
            luma: luma,
            chroma: chroma
        )
    }

    func copyTightPlane(
        _ source: UnsafeRawPointer,
        sourceStride: Int,
        activeBytesPerRow: Int,
        rowCount: Int
    ) throws -> Data {
        var data = Data(count: activeBytesPerRow * rowCount)
        try data.withUnsafeMutableBytes { destinationBytes in
            guard let destination = destinationBytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            for row in 0..<rowCount {
                if row.isMultiple(of: Self.cancellationRowInterval) {
                    try checkCancellation()
                }
                destination
                    .advanced(by: row * activeBytesPerRow)
                    .copyMemory(
                        from: source.advanced(
                            by: row * sourceStride
                        ),
                        byteCount: activeBytesPerRow
                    )
            }
        }
        return data
    }
}
