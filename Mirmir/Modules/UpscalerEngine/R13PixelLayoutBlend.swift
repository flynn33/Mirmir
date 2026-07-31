import CoreVideo
import Foundation

private struct R13PixelBlendWeight {
    let previous: UInt64
    let current: UInt64
    let denominator: UInt64
}

private struct R13PixelBlendPlaneBuffers {
    let previous: UnsafeMutableRawPointer
    let previousStride: Int
    let current: UnsafeMutableRawPointer
    let currentStride: Int
    let destination: UnsafeMutableRawPointer
    let destinationStride: Int
    let componentCount: Int
    let rowCount: Int
}

extension R13PixelLayoutProcessor {
    static func blend(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        destination: CVPixelBuffer,
        phase: Float
    ) throws {
        let pixelFormat = CVPixelBufferGetPixelFormatType(previous)
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        try layout.validate(previous)
        try layout.validate(current)
        try layout.validate(destination)
        try validateMatchingGeometry(
            [previous, current, destination]
        )
        try lockReadOnly(previous)
        defer {
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }
        try lockReadOnly(current)
        defer {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
        }
        try lockWritable(destination)
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        try blendLocked(
            previous: previous,
            current: current,
            destination: destination,
            phase: phase,
            layout: layout
        )
        copyAttachments(source: previous, destination: destination)
    }

    static func blendLocked(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        destination: CVPixelBuffer,
        phase: Float,
        layout: R13PixelLayout
    ) throws {
        let weight = try blendWeight(for: phase)
        let width = CVPixelBufferGetWidth(previous)
        let height = CVPixelBufferGetHeight(previous)
        for (index, plane) in layout.planes.enumerated() {
            let previousBase = try R13PixelBufferAccess.baseAddress(
                of: previous,
                layout: layout,
                plane: index
            )
            let currentBase = try R13PixelBufferAccess.baseAddress(
                of: current,
                layout: layout,
                plane: index
            )
            let destinationBase = try R13PixelBufferAccess.baseAddress(
                of: destination,
                layout: layout,
                plane: index
            )
            let previousStride = R13PixelBufferAccess.rowBytes(
                of: previous,
                layout: layout,
                plane: index
            )
            let currentStride = R13PixelBufferAccess.rowBytes(
                of: current,
                layout: layout,
                plane: index
            )
            let destinationStride = R13PixelBufferAccess.rowBytes(
                of: destination,
                layout: layout,
                plane: index
            )
            let componentCount =
                plane.width(for: width) * plane.componentsPerElement
            let rowCount = plane.height(for: height)
            let buffers = R13PixelBlendPlaneBuffers(
                previous: previousBase,
                previousStride: previousStride,
                current: currentBase,
                currentStride: currentStride,
                destination: destinationBase,
                destinationStride: destinationStride,
                componentCount: componentCount,
                rowCount: rowCount
            )
            if plane.bytesPerComponent == 1 {
                blend8BitPlane(
                    buffers,
                    plane: plane,
                    weight: weight
                )
            } else {
                blend16BitPlane(
                    buffers,
                    plane: plane,
                    weight: weight
                )
            }
        }
    }

    private static func blendWeight(
        for phase: Float
    ) throws -> R13PixelBlendWeight {
        guard phase > 0, phase < 1 else {
            throw R13PixelLayoutError.invalidPhase(phase)
        }
        let denominator: UInt64 = 65_536
        let current = UInt64(
            (Double(phase) * Double(denominator)).rounded()
        )
        guard current > 0, current < denominator else {
            throw R13PixelLayoutError.invalidPhase(phase)
        }
        return R13PixelBlendWeight(
            previous: denominator - current,
            current: current,
            denominator: denominator
        )
    }

    private static func blend8BitPlane(
        _ buffers: R13PixelBlendPlaneBuffers,
        plane: R13PixelPlaneLayout,
        weight: R13PixelBlendWeight
    ) {
        for row in 0..<buffers.rowCount {
            let previousRow = buffers.previous
                .advanced(by: row * buffers.previousStride)
                .assumingMemoryBound(to: UInt8.self)
            let currentRow = buffers.current
                .advanced(by: row * buffers.currentStride)
                .assumingMemoryBound(to: UInt8.self)
            let destinationRow = buffers.destination
                .advanced(by: row * buffers.destinationStride)
                .assumingMemoryBound(to: UInt8.self)
            for component in 0..<buffers.componentCount {
                let bounds = plane.componentBounds[
                    component % plane.componentsPerElement
                ]
                let blended = blendedCode(
                    previous: UInt64(previousRow[component]),
                    current: UInt64(currentRow[component]),
                    weight: weight
                )
                destinationRow[component] = UInt8(
                    bounded(blended, bounds: bounds)
                )
            }
        }
    }

    private static func blend16BitPlane(
        _ buffers: R13PixelBlendPlaneBuffers,
        plane: R13PixelPlaneLayout,
        weight: R13PixelBlendWeight
    ) {
        for row in 0..<buffers.rowCount {
            let previousRow = buffers.previous
                .advanced(by: row * buffers.previousStride)
                .assumingMemoryBound(to: UInt16.self)
            let currentRow = buffers.current
                .advanced(by: row * buffers.currentStride)
                .assumingMemoryBound(to: UInt16.self)
            let destinationRow = buffers.destination
                .advanced(by: row * buffers.destinationStride)
                .assumingMemoryBound(to: UInt16.self)
            for component in 0..<buffers.componentCount {
                let bounds = plane.componentBounds[
                    component % plane.componentsPerElement
                ]
                let shift = UInt16(plane.storedCodeShift)
                let blended = blendedCode(
                    previous: UInt64(previousRow[component] >> shift),
                    current: UInt64(currentRow[component] >> shift),
                    weight: weight
                )
                destinationRow[component] =
                    UInt16(bounded(blended, bounds: bounds)) << shift
            }
        }
    }

    private static func blendedCode(
        previous: UInt64,
        current: UInt64,
        weight: R13PixelBlendWeight
    ) -> UInt64 {
        (
            previous * weight.previous
                + current * weight.current
                + weight.denominator / 2
        ) / weight.denominator
    }

    private static func bounded(
        _ value: UInt64,
        bounds: R13PixelCodeBounds
    ) -> UInt64 {
        min(
            max(value, UInt64(bounds.minimum)),
            UInt64(bounds.maximum)
        )
    }
}
