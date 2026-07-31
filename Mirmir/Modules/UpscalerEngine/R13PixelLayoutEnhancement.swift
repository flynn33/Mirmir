import CoreVideo
import Foundation

struct R13PixelLayoutEnhancementConfiguration: Sendable {
    let edgeFidelityLevel: MirmirAdjustmentLevel
    let detailRecoveryLevel: MirmirAdjustmentLevel
    let edgePreservationEnabled: Bool
    let compressionCleanupEnabled: Bool
    let textureGrainProtectionEnabled: Bool
    let temporalConsistencyEnabled: Bool
    let temporalStabilityEnabled: Bool

    var retainsHistory: Bool {
        temporalConsistencyEnabled || temporalStabilityEnabled
    }
}

private struct R13PixelEnhancementPlaneBuffers {
    let source: UnsafeMutableRawPointer
    let sourceStride: Int
    let destination: UnsafeMutableRawPointer
    let destinationStride: Int
    let previous: UnsafeMutableRawPointer?
    let previousStride: Int?
    let width: Int
    let height: Int
    let plane: R13PixelPlaneLayout
    let component: Int
    let bounds: R13PixelCodeBounds
}

enum R13PixelLayoutEnhancer {
    static func process(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        previous: CVPixelBuffer?,
        configuration: R13PixelLayoutEnhancementConfiguration,
        checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(source)
        )
        try layout.validate(source)
        try layout.validate(destination)
        try R13PixelLayoutProcessor.validateMatchingGeometry(
            [source, destination]
        )
        if let previous {
            try layout.validate(previous)
            try R13PixelLayoutProcessor.validateMatchingGeometry(
                [source, previous]
            )
        }
        try R13PixelLayoutProcessor.copy(
            source: source,
            destination: destination
        )
        guard let planeIndex = lumaPlaneIndex(layout) else {
            throw R13PixelLayoutError.unsupportedPixelFormat(
                layout.pixelFormat
            )
        }
        try R13PixelLayoutProcessor.lockReadOnly(source)
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if let previous {
            try R13PixelLayoutProcessor.lockReadOnly(previous)
        }
        defer {
            if let previous {
                CVPixelBufferUnlockBaseAddress(previous, .readOnly)
            }
        }
        try R13PixelLayoutProcessor.lockWritable(destination)
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        try processLuma(
            source: source,
            destination: destination,
            previous: previous,
            layout: layout,
            planeIndex: planeIndex,
            configuration: configuration,
            checkCancellation: checkCancellation
        )
        try R13PixelLayoutProcessor.enforceCodeBoundsLocked(
            destination,
            layout: layout
        )
    }

    private static func lumaPlaneIndex(
        _ layout: R13PixelLayout
    ) -> Int? {
        layout.planes.firstIndex {
            $0.role == .luma || $0.role == .packedAYCbCr
        }
    }

    private static func processLuma(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        previous: CVPixelBuffer?,
        layout: R13PixelLayout,
        planeIndex: Int,
        configuration: R13PixelLayoutEnhancementConfiguration,
        checkCancellation: () throws -> Void
    ) throws {
        let plane = layout.planes[planeIndex]
        let component = plane.role == .packedAYCbCr ? 1 : 0
        let bounds = plane.componentBounds[component]
        let sourceBase = try R13PixelBufferAccess.baseAddress(
            of: source,
            layout: layout,
            plane: planeIndex
        )
        let destinationBase = try R13PixelBufferAccess.baseAddress(
            of: destination,
            layout: layout,
            plane: planeIndex
        )
        let previousBase = try previous.map {
            try R13PixelBufferAccess.baseAddress(
                of: $0,
                layout: layout,
                plane: planeIndex
            )
        }
        let sourceStride = R13PixelBufferAccess.rowBytes(
            of: source,
            layout: layout,
            plane: planeIndex
        )
        let destinationStride = R13PixelBufferAccess.rowBytes(
            of: destination,
            layout: layout,
            plane: planeIndex
        )
        let previousStride = previous.map {
            R13PixelBufferAccess.rowBytes(
                of: $0,
                layout: layout,
                plane: planeIndex
            )
        }
        let width = plane.width(
            for: CVPixelBufferGetWidth(source)
        )
        let height = plane.height(
            for: CVPixelBufferGetHeight(source)
        )
        let buffers = R13PixelEnhancementPlaneBuffers(
            source: sourceBase,
            sourceStride: sourceStride,
            destination: destinationBase,
            destinationStride: destinationStride,
            previous: previousBase,
            previousStride: previousStride,
            width: width,
            height: height,
            plane: plane,
            component: component,
            bounds: bounds
        )
        if width > 2, height > 2 {
            try enhanceSpatially(
                buffers,
                configuration: configuration,
                checkCancellation: checkCancellation
            )
        }
        if configuration.retainsHistory,
           previousBase != nil,
           previousStride != nil {
            try stabilizeTemporally(
                buffers,
                configuration: configuration,
                checkCancellation: checkCancellation
            )
        }
    }
}

extension R13PixelLayoutEnhancer {
    private static func enhanceSpatially(
        _ buffers: R13PixelEnhancementPlaneBuffers,
        configuration: R13PixelLayoutEnhancementConfiguration,
        checkCancellation: () throws -> Void
    ) throws {
        let span = Int(
            buffers.bounds.maximum - buffers.bounds.minimum
        )
        for row in 1..<(buffers.height - 1) {
            if row.isMultiple(of: 16) {
                try checkCancellation()
            }
            for column in 1..<(buffers.width - 1) {
                let center = code(
                    buffers.source,
                    stride: buffers.sourceStride,
                    row: row,
                    column: column,
                    plane: buffers.plane,
                    component: buffers.component
                )
                let neighbors = [
                    code(
                        buffers.source,
                        stride: buffers.sourceStride,
                        row: row - 1,
                        column: column,
                        plane: buffers.plane,
                        component: buffers.component
                    ),
                    code(
                        buffers.source,
                        stride: buffers.sourceStride,
                        row: row + 1,
                        column: column,
                        plane: buffers.plane,
                        component: buffers.component
                    ),
                    code(
                        buffers.source,
                        stride: buffers.sourceStride,
                        row: row,
                        column: column - 1,
                        plane: buffers.plane,
                        component: buffers.component
                    ),
                    code(
                        buffers.source,
                        stride: buffers.sourceStride,
                        row: row,
                        column: column + 1,
                        plane: buffers.plane,
                        component: buffers.component
                    )
                ]
                let localMinimum = min(
                    center,
                    neighbors.min() ?? center
                )
                let localMaximum = max(
                    center,
                    neighbors.max() ?? center
                )
                let localRange = localMaximum - localMinimum
                let average = (neighbors.reduce(0, +) + 2) / 4
                var value = spatialValue(
                    center: center,
                    average: average,
                    localMinimum: localMinimum,
                    localMaximum: localMaximum,
                    localRange: localRange,
                    span: span,
                    bounds: buffers.bounds,
                    configuration: configuration
                )
                if configuration.compressionCleanupEnabled,
                   localRange <= max(1, span / 18) {
                    value = roundedDivide(
                        4 * value + neighbors.reduce(0, +),
                        by: 8
                    )
                }
                setCode(
                    value,
                    buffers.destination,
                    stride: buffers.destinationStride,
                    row: row,
                    column: column,
                    plane: buffers.plane,
                    component: buffers.component,
                    bounds: buffers.bounds
                )
            }
        }
    }

    private static func spatialValue(
        center: Int,
        average: Int,
        localMinimum: Int,
        localMaximum: Int,
        localRange: Int,
        span: Int,
        bounds: R13PixelCodeBounds,
        configuration: R13PixelLayoutEnhancementConfiguration
    ) -> Int {
        let detail = levelNumerator(
            configuration.detailRecoveryLevel
        )
        let edge = levelNumerator(
            configuration.edgeFidelityLevel
        )
        let deviation = center - average
        var value =
            center
            + roundedDivide(deviation * detail, by: 8)
            + roundedDivide(deviation * edge, by: 32)
        if configuration.edgePreservationEnabled {
            let allowance = max(1, span * edge / 1_024)
            value = min(
                max(value, localMinimum - allowance),
                localMaximum + allowance
            )
        }
        if configuration.textureGrainProtectionEnabled,
           localRange >= max(1, span / 32) {
            value = roundedDivide(3 * center + value, by: 4)
        }
        return bounded(value, bounds: bounds)
    }

    private static func stabilizeTemporally(
        _ buffers: R13PixelEnhancementPlaneBuffers,
        configuration: R13PixelLayoutEnhancementConfiguration,
        checkCancellation: () throws -> Void
    ) throws {
        guard let previous = buffers.previous,
              let previousStride = buffers.previousStride else {
            return
        }
        let span = max(
            1,
            Int(buffers.bounds.maximum - buffers.bounds.minimum)
        )
        var totalDifference: UInt64 = 0
        for row in 0..<buffers.height {
            for column in 0..<buffers.width {
                let current = code(
                    buffers.destination,
                    stride: buffers.destinationStride,
                    row: row,
                    column: column,
                    plane: buffers.plane,
                    component: buffers.component
                )
                let old = code(
                    previous,
                    stride: previousStride,
                    row: row,
                    column: column,
                    plane: buffers.plane,
                    component: buffers.component
                )
                totalDifference += UInt64(abs(current - old))
            }
        }
        let sampleCount = UInt64(buffers.width * buffers.height)
        let sceneCutThreshold =
            UInt64(max(1, span * 3 / 16)) * sampleCount
        guard totalDifference < sceneCutThreshold else { return }
        let stability = configuration.temporalStabilityEnabled
        let motionThreshold = max(
            1,
            span * (stability ? 64 : 28) / 1_024
        )
        let currentWeight = stability ? 1 : 3
        for row in 0..<buffers.height {
            if row.isMultiple(of: 16) {
                try checkCancellation()
            }
            for column in 0..<buffers.width {
                let current = code(
                    buffers.destination,
                    stride: buffers.destinationStride,
                    row: row,
                    column: column,
                    plane: buffers.plane,
                    component: buffers.component
                )
                let old = code(
                    previous,
                    stride: previousStride,
                    row: row,
                    column: column,
                    plane: buffers.plane,
                    component: buffers.component
                )
                guard abs(current - old) <= motionThreshold else {
                    continue
                }
                let stabilized = roundedDivide(
                    currentWeight * current + old,
                    by: currentWeight + 1
                )
                setCode(
                    stabilized,
                    buffers.destination,
                    stride: buffers.destinationStride,
                    row: row,
                    column: column,
                    plane: buffers.plane,
                    component: buffers.component,
                    bounds: buffers.bounds
                )
            }
        }
    }

    private static func levelNumerator(
        _ level: MirmirAdjustmentLevel
    ) -> Int {
        switch level {
        case .low:
            return 1
        case .medium:
            return 2
        case .high:
            return 3
        }
    }

    private static func code(
        _ base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int,
        column: Int,
        plane: R13PixelPlaneLayout,
        component: Int
    ) -> Int {
        let index =
            column * plane.componentsPerElement + component
        if plane.bytesPerComponent == 1 {
            return Int(
                base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)[index]
            )
        }
        return Int(
            base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt16.self)[index]
                >> UInt16(plane.storedCodeShift)
        )
    }

    private static func setCode(
        _ value: Int,
        _ base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int,
        column: Int,
        plane: R13PixelPlaneLayout,
        component: Int,
        bounds: R13PixelCodeBounds
    ) {
        let index =
            column * plane.componentsPerElement + component
        let result = bounded(value, bounds: bounds)
        if plane.bytesPerComponent == 1 {
            base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self)[index] =
                UInt8(result)
        } else {
            base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt16.self)[index] =
                UInt16(result) << UInt16(plane.storedCodeShift)
        }
    }

    private static func bounded(
        _ value: Int,
        bounds: R13PixelCodeBounds
    ) -> Int {
        min(
            max(value, Int(bounds.minimum)),
            Int(bounds.maximum)
        )
    }

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
