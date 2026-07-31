import CoreVideo
import Foundation

protocol R13ReleaseFrameEnhancing: AnyObject, Sendable {
    var temporalConsistencyEnabled: Bool { get }

    func process(_ source: CVPixelBuffer) throws -> CVPixelBuffer
    func restoreTemporalHistory(
        from verifiedCachedOutput: CVPixelBuffer
    ) throws
    func finish() throws
    func cancel()
}

extension R13FullFrameEnhancementProcessor:
    R13ReleaseFrameEnhancing {}

final class R13ReleaseFormatEnhancementProcessor:
    R13ReleaseFrameEnhancing,
    @unchecked Sendable {
    private let implementation: any R13ReleaseFrameEnhancing
    private let restoresTemporalHistory: Bool

    init(
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat,
        temporalConsistencyEnabled: Bool,
        edgeFidelityLevel: MirmirAdjustmentLevel,
        detailRecoveryLevel: MirmirAdjustmentLevel,
        edgePreservationEnabled: Bool,
        compressionCleanupEnabled: Bool,
        textureGrainProtectionEnabled: Bool,
        temporalStabilityEnabled: Bool
    ) throws {
        restoresTemporalHistory =
            temporalConsistencyEnabled || temporalStabilityEnabled
        if videoFormat == .sdrBT709 {
            implementation = try R13FullFrameEnhancementProcessor(
                targetResolution: targetResolution,
                temporalConsistencyEnabled:
                    temporalConsistencyEnabled,
                edgeFidelityLevel: edgeFidelityLevel,
                detailRecoveryLevel: detailRecoveryLevel,
                edgePreservationEnabled:
                    edgePreservationEnabled,
                compressionCleanupEnabled:
                    compressionCleanupEnabled,
                textureGrainProtectionEnabled:
                    textureGrainProtectionEnabled,
                temporalStabilityEnabled:
                    temporalStabilityEnabled
            )
        } else {
            implementation =
                try R13ExtendedFormatEnhancementProcessor(
                    targetResolution: targetResolution,
                    videoFormat: videoFormat,
                    temporalConsistencyEnabled:
                        temporalConsistencyEnabled,
                    edgeFidelityLevel: edgeFidelityLevel,
                    detailRecoveryLevel: detailRecoveryLevel,
                    edgePreservationEnabled:
                        edgePreservationEnabled,
                    compressionCleanupEnabled:
                        compressionCleanupEnabled,
                    textureGrainProtectionEnabled:
                        textureGrainProtectionEnabled,
                    temporalStabilityEnabled:
                        temporalStabilityEnabled
                )
        }
    }

    var temporalConsistencyEnabled: Bool {
        restoresTemporalHistory
    }

    func process(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        try implementation.process(source)
    }

    func restoreTemporalHistory(
        from verifiedCachedOutput: CVPixelBuffer
    ) throws {
        try implementation.restoreTemporalHistory(
            from: verifiedCachedOutput
        )
    }

    func finish() throws {
        try implementation.finish()
    }

    func cancel() {
        implementation.cancel()
    }
}

private final class R13ExtendedFormatEnhancementProcessor:
    R13ReleaseFrameEnhancing,
    @unchecked Sendable {
    private enum Lifecycle {
        case active
        case finished
        case cancelled
    }

    private struct State {
        var lifecycle = Lifecycle.active
        var operationInProgress = false
        var history: R13NV12Frame?
    }

    let targetResolution: VideoResolution
    let videoFormat: MediaVideoFormat
    let temporalConsistencyEnabled: Bool
    let edgeFidelityLevel: MirmirAdjustmentLevel
    let detailRecoveryLevel: MirmirAdjustmentLevel
    let edgePreservationEnabled: Bool
    let compressionCleanupEnabled: Bool
    let textureGrainProtectionEnabled: Bool
    let temporalStabilityEnabled: Bool

    private let outputPool: CVPixelBufferPool
    private let stateLock = NSLock()
    private var state = State()

    init(
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat,
        temporalConsistencyEnabled: Bool,
        edgeFidelityLevel: MirmirAdjustmentLevel,
        detailRecoveryLevel: MirmirAdjustmentLevel,
        edgePreservationEnabled: Bool,
        compressionCleanupEnabled: Bool,
        textureGrainProtectionEnabled: Bool,
        temporalStabilityEnabled: Bool
    ) throws {
        guard targetResolution.width >= 2,
              targetResolution.height >= 2 else {
            throw R13FullFrameEnhancementProcessorError
                .invalidTargetResolution(targetResolution)
        }
        guard R13PixelLayoutRegistry.supportedPixelFormats.contains(
            videoFormat.pixelStorage.pixelFormat
        ) else {
            throw R13FullFrameEnhancementProcessorError
                .unsupportedPixelFormat(
                    role: .source,
                    actual: videoFormat.pixelStorage.pixelFormat
                )
        }
        self.targetResolution = targetResolution
        self.videoFormat = videoFormat
        self.temporalConsistencyEnabled =
            temporalConsistencyEnabled
        self.edgeFidelityLevel = edgeFidelityLevel
        self.detailRecoveryLevel = detailRecoveryLevel
        self.edgePreservationEnabled =
            edgePreservationEnabled
        self.compressionCleanupEnabled =
            compressionCleanupEnabled
        self.textureGrainProtectionEnabled =
            textureGrainProtectionEnabled
        self.temporalStabilityEnabled =
            temporalStabilityEnabled
        outputPool = try PixelBufferBridge.makePool(
            width: targetResolution.width,
            height: targetResolution.height,
            format: videoFormat.pixelStorage.pixelFormat,
            capacity: 3
        )
    }

    func process(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let previous = try beginOperation()
        var completed = false
        defer {
            if !completed {
                abandonOperation()
            }
        }
        try R13MediaVideoFormatContract.validate(
            source,
            resolution: targetResolution,
            format: videoFormat
        )
        let output = try PixelBufferBridge.dequeue(from: outputPool)
        CVBufferPropagateAttachments(source, output)
        R13MediaVideoFormatContract.install(
            videoFormat,
            on: output,
            resolution: targetResolution
        )
        switch videoFormat.pixelStorage {
        case .p010VideoRange10Bit:
            try processP010(
                source: source,
                output: output,
                previous: previous
            )
        case .bgra8WithAlpha:
            try processBGRA(
                source: source,
                output: output,
                previous: previous
            )
        case .nv12VideoRange8Bit, .nv12FullRange8Bit,
             .p010FullRange10Bit,
             .yuv422VideoRange8Bit, .yuv422FullRange8Bit,
             .yuv422VideoRange10Bit, .yuv422FullRange10Bit,
             .yuv422VideoRange16Bit,
             .yuv444VideoRange8Bit, .yuv444FullRange8Bit,
             .yuv444VideoRange10Bit, .yuv444FullRange10Bit,
             .yuv444VideoRange16Bit,
             .yuv444VideoRange8BitWithAlpha,
             .yuv444VideoRange16BitWithAlpha,
             .yuv444VideoRange16BitWithAlphaTriPlanar:
            try R13PixelLayoutEnhancer.process(
                source: source,
                destination: output,
                previous: try previous?.makePixelBuffer(
                    videoFormat: videoFormat
                ),
                configuration:
                    R13PixelLayoutEnhancementConfiguration(
                        edgeFidelityLevel: edgeFidelityLevel,
                        detailRecoveryLevel: detailRecoveryLevel,
                        edgePreservationEnabled:
                            edgePreservationEnabled,
                        compressionCleanupEnabled:
                            compressionCleanupEnabled,
                        textureGrainProtectionEnabled:
                            textureGrainProtectionEnabled,
                        temporalConsistencyEnabled:
                            temporalConsistencyEnabled,
                        temporalStabilityEnabled:
                            temporalStabilityEnabled
                    ),
                checkCancellation: checkCancellation
            )
        }
        let history = retainsHistory
            ? try R13NV12Frame.captureTightActivePlanes(from: output)
            : nil
        try completeOperation(history: history)
        completed = true
        return output
    }

    func restoreTemporalHistory(
        from verifiedCachedOutput: CVPixelBuffer
    ) throws {
        guard retainsHistory else {
            throw R13FullFrameEnhancementProcessorError
                .temporalConsistencyDisabled
        }
        _ = try beginOperation()
        var completed = false
        defer {
            if !completed {
                abandonOperation()
            }
        }
        try R13MediaVideoFormatContract.validate(
            verifiedCachedOutput,
            resolution: targetResolution,
            format: videoFormat
        )
        let history = try R13NV12Frame.captureTightActivePlanes(
            from: verifiedCachedOutput
        )
        try completeOperation(history: history)
        completed = true
    }

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
            state.lifecycle = .finished
        case .finished:
            return
        case .cancelled:
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
    }

    func cancel() {
        stateLock.lock()
        if case .active = state.lifecycle {
            state.lifecycle = .cancelled
            state.history = nil
        }
        stateLock.unlock()
    }

    private var retainsHistory: Bool {
        temporalConsistencyEnabled || temporalStabilityEnabled
    }

    private func beginOperation() throws -> R13NV12Frame? {
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

    private func abandonOperation() {
        stateLock.lock()
        state.operationInProgress = false
        stateLock.unlock()
    }

    private func completeOperation(
        history: R13NV12Frame?
    ) throws {
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

    private func checkCancellation() throws {
        if Task.isCancelled {
            cancel()
        }
        stateLock.lock()
        let cancelled = state.lifecycle == .cancelled
        stateLock.unlock()
        if cancelled {
            throw R13FullFrameEnhancementProcessorError.cancelled
        }
    }

    private func processP010(
        source: CVPixelBuffer,
        output: CVPixelBuffer,
        previous: R13NV12Frame?
    ) throws {
        let sourceStatus =
            CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceStatus == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .source,
                    status: sourceStatus
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let outputStatus = CVPixelBufferLockBaseAddress(output, [])
        guard outputStatus == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .output,
                    status: outputStatus
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        guard let sourceLumaRaw =
                CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let sourceChromaRaw =
                CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let outputLumaRaw =
                CVPixelBufferGetBaseAddressOfPlane(output, 0),
              let outputChromaRaw =
                CVPixelBufferGetBaseAddressOfPlane(output, 1) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .source, plane: 0)
        }
        let sourceLuma =
            sourceLumaRaw.assumingMemoryBound(to: UInt16.self)
        let sourceChroma =
            sourceChromaRaw.assumingMemoryBound(to: UInt16.self)
        let outputLuma =
            outputLumaRaw.assumingMemoryBound(to: UInt16.self)
        let outputChroma =
            outputChromaRaw.assumingMemoryBound(to: UInt16.self)
        let sourceLumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(source, 0) / 2
        let sourceChromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(source, 1) / 2
        let outputLumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
        let outputChromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(output, 1) / 2
        let width = targetResolution.width
        let height = targetResolution.height

        for row in 0..<height {
            if row.isMultiple(of: 16) {
                try checkCancellation()
            }
            let sourceRow =
                sourceLuma.advanced(by: row * sourceLumaStride)
            let outputRow =
                outputLuma.advanced(by: row * outputLumaStride)
            for column in 0..<width {
                outputRow[column] = Self.p010Word(
                    Self.p010Code(sourceRow[column]),
                    lower: 64,
                    upper: 940
                )
            }
        }
        for row in 0..<(height / 2) {
            let sourceRow =
                sourceChroma.advanced(by: row * sourceChromaStride)
            let outputRow =
                outputChroma.advanced(by: row * outputChromaStride)
            for column in 0..<width {
                outputRow[column] = Self.p010Word(
                    Self.p010Code(sourceRow[column]),
                    lower: 64,
                    upper: 960
                )
            }
        }
        if width > 2, height > 2 {
            for row in 1..<(height - 1) {
                if row.isMultiple(of: 16) {
                    try checkCancellation()
                }
                let north = sourceLuma.advanced(
                    by: (row - 1) * sourceLumaStride
                )
                let current = sourceLuma.advanced(
                    by: row * sourceLumaStride
                )
                let south = sourceLuma.advanced(
                    by: (row + 1) * sourceLumaStride
                )
                let destination = outputLuma.advanced(
                    by: row * outputLumaStride
                )
                for column in 1..<(width - 1) {
                    let center = Self.p010Code(current[column])
                    let neighbors = [
                        Self.p010Code(north[column]),
                        Self.p010Code(south[column]),
                        Self.p010Code(current[column - 1]),
                        Self.p010Code(current[column + 1])
                    ]
                    let localMinimum =
                        min(center, neighbors.min() ?? center)
                    let localMaximum =
                        max(center, neighbors.max() ?? center)
                    let average =
                        (neighbors.reduce(0, +) + 2) / 4
                    let range = localMaximum - localMinimum
                    var value = spatialValue(
                        center: center,
                        average: average,
                        localMinimum: localMinimum,
                        localMaximum: localMaximum,
                        localRange: range,
                        maximum: 940
                    )
                    if compressionCleanupEnabled, range <= 48 {
                        value = (4 * value + neighbors.reduce(0, +) + 4)
                            / 8
                    }
                    destination[column] = Self.p010Word(
                        value,
                        lower: 64,
                        upper: 940
                    )
                }
            }
        }
        if compressionCleanupEnabled {
            try smoothP010Chroma(
                source: sourceChroma,
                sourceStride: sourceChromaStride,
                destination: outputChroma,
                destinationStride: outputChromaStride
            )
        }
        if let previous, retainsHistory {
            try blendP010Temporal(
                luma: outputLuma,
                lumaStride: outputLumaStride,
                chroma: outputChroma,
                chromaStride: outputChromaStride,
                previous: previous
            )
        }
    }

    private func spatialValue(
        center: Int,
        average: Int,
        localMinimum: Int,
        localMaximum: Int,
        localRange: Int,
        maximum: Int
    ) -> Int {
        let detailNumerator: Int
        switch detailRecoveryLevel {
        case .low: detailNumerator = 1
        case .medium: detailNumerator = 2
        case .high: detailNumerator = 3
        }
        let edgeNumerator: Int
        switch edgeFidelityLevel {
        case .low: edgeNumerator = 1
        case .medium: edgeNumerator = 2
        case .high: edgeNumerator = 3
        }
        let deviation = center - average
        var value =
            center
            + Self.roundedDivide(
                deviation * detailNumerator,
                by: 8
            )
            + Self.roundedDivide(
                deviation * edgeNumerator,
                by: 32
            )
        if edgePreservationEnabled {
            let allowance = max(1, edgeNumerator * 2)
            value = min(
                max(value, localMinimum - allowance),
                localMaximum + allowance
            )
        }
        if textureGrainProtectionEnabled, localRange >= 32 {
            value = (3 * center + value + 2) / 4
        }
        return min(max(value, 0), maximum)
    }

    private func smoothP010Chroma(
        source: UnsafePointer<UInt16>,
        sourceStride: Int,
        destination: UnsafeMutablePointer<UInt16>,
        destinationStride: Int
    ) throws {
        let width = targetResolution.width / 2
        let height = targetResolution.height / 2
        guard width > 2, height > 2 else { return }
        for row in 1..<(height - 1) {
            if row.isMultiple(of: 16) {
                try checkCancellation()
            }
            for column in 1..<(width - 1) {
                for component in 0..<2 {
                    let index = column * 2 + component
                    let center = Self.p010Code(
                        source[row * sourceStride + index]
                    )
                    let values = [
                        Self.p010Code(
                            source[(row - 1) * sourceStride + index]
                        ),
                        Self.p010Code(
                            source[(row + 1) * sourceStride + index]
                        ),
                        Self.p010Code(
                            source[
                                row * sourceStride
                                    + (column - 1) * 2
                                    + component
                            ]
                        ),
                        Self.p010Code(
                            source[
                                row * sourceStride
                                    + (column + 1) * 2
                                    + component
                            ]
                        )
                    ]
                    let range =
                        max(center, values.max() ?? center)
                        - min(center, values.min() ?? center)
                    guard range <= 24 else { continue }
                    let smoothed =
                        (4 * center + values.reduce(0, +) + 4) / 8
                    destination[row * destinationStride + index] =
                        Self.p010Word(
                            smoothed,
                            lower: 64,
                            upper: 960
                        )
                }
            }
        }
    }

    private func blendP010Temporal(
        luma: UnsafeMutablePointer<UInt16>,
        lumaStride: Int,
        chroma: UnsafeMutablePointer<UInt16>,
        chromaStride: Int,
        previous: R13NV12Frame
    ) throws {
        guard previous.pixelFormat
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              previous.width == targetResolution.width,
              previous.height == targetResolution.height else {
            throw R13FullFrameEnhancementProcessorError
                .historyStorageCorrupt
        }
        let width = targetResolution.width
        let height = targetResolution.height
        let sceneCut = try previous.luma.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let prior = base.assumingMemoryBound(to: UInt16.self)
            var difference: UInt64 = 0
            for row in 0..<height {
                let currentRow =
                    luma.advanced(by: row * lumaStride)
                let priorRow = prior.advanced(by: row * width)
                for column in 0..<width {
                    difference += UInt64(
                        abs(
                            Self.p010Code(currentRow[column])
                            - Self.p010Code(priorRow[column])
                        )
                    )
                }
            }
            return difference
                >= UInt64(width * height * 192)
        }
        guard !sceneCut else { return }
        try previous.luma.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let prior = base.assumingMemoryBound(to: UInt16.self)
            let threshold = temporalStabilityEnabled ? 56 : 24
            let currentWeight =
                temporalStabilityEnabled ? 1 : 3
            for row in 0..<height {
                if row.isMultiple(of: 16) {
                    try checkCancellation()
                }
                let currentRow =
                    luma.advanced(by: row * lumaStride)
                let priorRow = prior.advanced(by: row * width)
                for column in 0..<width {
                    let current = Self.p010Code(currentRow[column])
                    let old = Self.p010Code(priorRow[column])
                    guard abs(current - old) <= threshold else {
                        continue
                    }
                    currentRow[column] = Self.p010Word(
                        (currentWeight * current + old
                            + currentWeight / 2)
                            / (currentWeight + 1),
                        lower: 64,
                        upper: 940
                    )
                }
            }
        }
        try previous.chroma.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let prior = base.assumingMemoryBound(to: UInt16.self)
            let currentWeight =
                temporalStabilityEnabled ? 1 : 3
            let threshold = temporalStabilityEnabled ? 48 : 32
            for row in 0..<(height / 2) {
                let currentRow =
                    chroma.advanced(by: row * chromaStride)
                let priorRow = prior.advanced(by: row * width)
                for column in 0..<width {
                    let current = Self.p010Code(currentRow[column])
                    let old = Self.p010Code(priorRow[column])
                    guard abs(current - old) <= threshold else {
                        continue
                    }
                    currentRow[column] = Self.p010Word(
                        (currentWeight * current + old
                            + currentWeight / 2)
                            / (currentWeight + 1),
                        lower: 64,
                        upper: 960
                    )
                }
            }
        }
    }

    private func processBGRA(
        source: CVPixelBuffer,
        output: CVPixelBuffer,
        previous: R13NV12Frame?
    ) throws {
        let sourceStatus =
            CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceStatus == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .source,
                    status: sourceStatus
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let outputStatus = CVPixelBufferLockBaseAddress(output, [])
        guard outputStatus == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .output,
                    status: outputStatus
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let outputBase = CVPixelBufferGetBaseAddress(output)
        else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .source, plane: 0)
        }
        let sourceBytes = sourceBase.assumingMemoryBound(to: UInt8.self)
        let outputBytes = outputBase.assumingMemoryBound(to: UInt8.self)
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let outputStride = CVPixelBufferGetBytesPerRow(output)
        let width = targetResolution.width
        let height = targetResolution.height
        for row in 0..<height {
            outputBytes.advanced(by: row * outputStride).update(
                from: sourceBytes.advanced(by: row * sourceStride),
                count: width * 4
            )
        }
        if width > 2, height > 2 {
            for row in 1..<(height - 1) {
                if row.isMultiple(of: 16) {
                    try checkCancellation()
                }
                for column in 1..<(width - 1) {
                    let offset = row * sourceStride + column * 4
                    for component in 0..<3 {
                        let center = Int(sourceBytes[offset + component])
                        let neighbors = [
                            Int(
                                sourceBytes[
                                    offset - sourceStride + component
                                ]
                            ),
                            Int(
                                sourceBytes[
                                    offset + sourceStride + component
                                ]
                            ),
                            Int(
                                sourceBytes[offset - 4 + component]
                            ),
                            Int(
                                sourceBytes[offset + 4 + component]
                            )
                        ]
                        let localMinimum =
                            min(center, neighbors.min() ?? center)
                        let localMaximum =
                            max(center, neighbors.max() ?? center)
                        let range = localMaximum - localMinimum
                        let average =
                            (neighbors.reduce(0, +) + 2) / 4
                        var value = spatialValue(
                            center: center,
                            average: average,
                            localMinimum: localMinimum,
                            localMaximum: localMaximum,
                            localRange: range,
                            maximum: 255
                        )
                        if compressionCleanupEnabled, range <= 18 {
                            value =
                                (4 * value
                                    + neighbors.reduce(0, +) + 4)
                                / 8
                        }
                        outputBytes[
                            row * outputStride
                                + column * 4
                                + component
                        ] = UInt8(clamping: value)
                    }
                    outputBytes[
                        row * outputStride + column * 4 + 3
                    ] = sourceBytes[offset + 3]
                }
            }
        }
        if let previous, retainsHistory {
            try blendBGRATemporal(
                output: outputBytes,
                stride: outputStride,
                previous: previous
            )
        }
    }

    private func blendBGRATemporal(
        output: UnsafeMutablePointer<UInt8>,
        stride: Int,
        previous: R13NV12Frame
    ) throws {
        guard previous.pixelFormat == kCVPixelFormatType_32BGRA,
              previous.width == targetResolution.width,
              previous.height == targetResolution.height,
              previous.chroma.isEmpty else {
            throw R13FullFrameEnhancementProcessorError
                .historyStorageCorrupt
        }
        let width = targetResolution.width
        let height = targetResolution.height
        try previous.luma.withUnsafeBytes { bytes in
            guard let raw = bytes.baseAddress else {
                throw R13FullFrameEnhancementProcessorError
                    .historyStorageCorrupt
            }
            let prior = raw.assumingMemoryBound(to: UInt8.self)
            var totalDifference: UInt64 = 0
            for row in 0..<height {
                let currentRow = output.advanced(by: row * stride)
                let priorRow = prior.advanced(by: row * width * 4)
                for column in 0..<width {
                    let offset = column * 4
                    totalDifference += UInt64(
                        abs(
                            Self.bgraLuma(currentRow + offset)
                            - Self.bgraLuma(priorRow + offset)
                        )
                    )
                }
            }
            guard totalDifference
                    < UInt64(width * height * 64) else {
                return
            }
            let threshold = temporalStabilityEnabled ? 18 : 10
            let currentWeight =
                temporalStabilityEnabled ? 1 : 3
            for row in 0..<height {
                if row.isMultiple(of: 16) {
                    try checkCancellation()
                }
                let currentRow = output.advanced(by: row * stride)
                let priorRow = prior.advanced(by: row * width * 4)
                for column in 0..<width {
                    let offset = column * 4
                    guard abs(
                        Self.bgraLuma(currentRow + offset)
                            - Self.bgraLuma(priorRow + offset)
                    ) <= threshold else {
                        continue
                    }
                    for component in 0..<3 {
                        currentRow[offset + component] = UInt8(
                            (
                                currentWeight
                                    * Int(
                                        currentRow[
                                            offset + component
                                        ]
                                    )
                                    + Int(
                                        priorRow[
                                            offset + component
                                        ]
                                    )
                                    + currentWeight / 2
                            ) / (currentWeight + 1)
                        )
                    }
                    // Alpha is the current frame's source alpha; temporal
                    // stabilization never modifies it.
                }
            }
        }
    }

    @inline(__always)
    private static func p010Code(_ word: UInt16) -> Int {
        Int(word >> 6)
    }

    @inline(__always)
    private static func p010Word(
        _ code: Int,
        lower: Int,
        upper: Int
    ) -> UInt16 {
        UInt16(min(max(code, lower), upper) << 6)
    }

    @inline(__always)
    private static func bgraLuma(
        _ pixel: UnsafePointer<UInt8>
    ) -> Int {
        (
            Int(pixel[0])
            + 2 * Int(pixel[1])
            + Int(pixel[2])
        ) / 4
    }

    @inline(__always)
    private static func roundedDivide(
        _ numerator: Int,
        by denominator: Int
    ) -> Int {
        precondition(denominator > 0)
        if numerator >= 0 {
            return (numerator + denominator / 2) / denominator
        }
        return -((-numerator + denominator / 2) / denominator)
    }
}
