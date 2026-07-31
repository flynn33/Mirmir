import CoreVideo
import Foundation

extension R13PixelLayoutProcessor {
    static func enforceCodeBounds(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        try layout.validate(pixelBuffer)
        try lockWritable(pixelBuffer)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        try enforceCodeBoundsLocked(pixelBuffer, layout: layout)
    }

    static func validateStoredCodes(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        try layout.validate(pixelBuffer)
        try lockReadOnly(pixelBuffer)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        try validateStoredCodesLocked(pixelBuffer, layout: layout)
    }

    static func normalizedLumaLocked(
        _ pixelBuffer: CVPixelBuffer,
        column: Int,
        row: Int,
        layout: R13PixelLayout
    ) throws -> Double {
        guard column >= 0,
              column < CVPixelBufferGetWidth(pixelBuffer),
              row >= 0,
              row < CVPixelBufferGetHeight(pixelBuffer) else {
            throw R13PixelLayoutError.invalidGeometry(
                width: column,
                height: row
            )
        }
        if layout.planes[0].role == .packedBGRA {
            return try normalizedBGRALuma(
                pixelBuffer,
                column: column,
                row: row,
                layout: layout
            )
        }
        let plane = layout.planes[0]
        let componentOffset =
            plane.role == .packedAYCbCr ? 1 : 0
        let code = try codeValue(
            pixelBuffer,
            layout: layout,
            planeIndex: 0,
            componentIndex:
                column * plane.componentsPerElement
                    + componentOffset,
            row: row
        )
        let bounds = plane.componentBounds[componentOffset]
        return normalized(code, bounds: bounds)
    }

    static func normalizedChromaEnergyLocked(
        _ pixelBuffer: CVPixelBuffer,
        column: Int,
        row: Int,
        layout: R13PixelLayout
    ) throws -> Double {
        guard let planeIndex = layout.planes.firstIndex(
            where: {
                $0.role == .interleavedChroma
                    || $0.role == .packedAYCbCr
            }
        ) else {
            return 0
        }
        let plane = layout.planes[planeIndex]
        let planeColumn = column / plane.widthDivisor
        let planeRow = row / plane.heightDivisor
        let firstComponent =
            plane.role == .packedAYCbCr ? 2 : 0
        let componentIndex =
            planeColumn * plane.componentsPerElement + firstComponent
        let cb = try codeValue(
            pixelBuffer,
            layout: layout,
            planeIndex: planeIndex,
            componentIndex: componentIndex,
            row: planeRow
        )
        let cr = try codeValue(
            pixelBuffer,
            layout: layout,
            planeIndex: planeIndex,
            componentIndex: componentIndex + 1,
            row: planeRow
        )
        return min(
            normalizedDistanceFromCenter(
                cb,
                bounds: plane.componentBounds[firstComponent]
            ) + normalizedDistanceFromCenter(
                cr,
                bounds: plane.componentBounds[firstComponent + 1]
            ),
            1
        )
    }

    static func enforceCodeBoundsLocked(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        for (index, plane) in layout.planes.enumerated() {
            let base = try R13PixelBufferAccess.baseAddress(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let stride = R13PixelBufferAccess.rowBytes(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let componentCount =
                plane.width(for: width) * plane.componentsPerElement
            let rowCount = plane.height(for: height)
            if plane.bytesPerComponent == 1 {
                enforce8BitBounds(
                    base: base,
                    stride: stride,
                    rowCount: rowCount,
                    componentCount: componentCount,
                    plane: plane
                )
            } else {
                enforce16BitBounds(
                    base: base,
                    stride: stride,
                    rowCount: rowCount,
                    componentCount: componentCount,
                    plane: plane
                )
            }
        }
    }

    private static func normalizedBGRALuma(
        _ pixelBuffer: CVPixelBuffer,
        column: Int,
        row: Int,
        layout: R13PixelLayout
    ) throws -> Double {
        let base = try R13PixelBufferAccess.baseAddress(
            of: pixelBuffer,
            layout: layout,
            plane: 0
        )
        let stride = R13PixelBufferAccess.rowBytes(
            of: pixelBuffer,
            layout: layout,
            plane: 0
        )
        let pixel = base
            .advanced(by: row * stride + column * 4)
            .assumingMemoryBound(to: UInt8.self)
        let blue = Double(pixel[0]) / 255.0
        let green = Double(pixel[1]) / 255.0
        let red = Double(pixel[2]) / 255.0
        return 0.0722 * blue + 0.7152 * green + 0.2126 * red
    }

    private static func codeValue(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        planeIndex: Int,
        componentIndex: Int,
        row: Int
    ) throws -> UInt16 {
        let plane = layout.planes[planeIndex]
        let base = try R13PixelBufferAccess.baseAddress(
            of: pixelBuffer,
            layout: layout,
            plane: planeIndex
        )
        let stride = R13PixelBufferAccess.rowBytes(
            of: pixelBuffer,
            layout: layout,
            plane: planeIndex
        )
        if plane.bytesPerComponent == 1 {
            return UInt16(
                base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)[componentIndex]
            )
        }
        return
            base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt16.self)[componentIndex]
            >> UInt16(plane.storedCodeShift)
    }

    private static func normalized(
        _ code: UInt16,
        bounds: R13PixelCodeBounds
    ) -> Double {
        let span = Double(bounds.maximum - bounds.minimum)
        guard span > 0 else { return 0 }
        return min(
            max(
                (Double(code) - Double(bounds.minimum)) / span,
                0
            ),
            1
        )
    }

    private static func normalizedDistanceFromCenter(
        _ code: UInt16,
        bounds: R13PixelCodeBounds
    ) -> Double {
        let minimum = UInt32(bounds.minimum)
        let maximum = UInt32(bounds.maximum)
        let neutral = (minimum + maximum + 1) / 2
        let maximumDistance = max(
            neutral - minimum,
            maximum - neutral
        )
        guard maximumDistance > 0 else { return 0 }
        let distance =
            code >= UInt16(neutral)
            ? UInt32(code) - neutral
            : neutral - UInt32(code)
        return min(
            Double(distance) / Double(maximumDistance),
            1
        )
    }

    private static func enforce8BitBounds(
        base: UnsafeMutableRawPointer,
        stride: Int,
        rowCount: Int,
        componentCount: Int,
        plane: R13PixelPlaneLayout
    ) {
        for row in 0..<rowCount {
            let values = base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self)
            for component in 0..<componentCount {
                let bounds = plane.componentBounds[
                    component % plane.componentsPerElement
                ]
                values[component] = UInt8(
                    min(
                        max(
                            UInt16(values[component]),
                            bounds.minimum
                        ),
                        bounds.maximum
                    )
                )
            }
        }
    }

    private static func enforce16BitBounds(
        base: UnsafeMutableRawPointer,
        stride: Int,
        rowCount: Int,
        componentCount: Int,
        plane: R13PixelPlaneLayout
    ) {
        let rounding =
            plane.storedCodeShift == 0
            ? 0
            : 1 << (plane.storedCodeShift - 1)
        for row in 0..<rowCount {
            let values = base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt16.self)
            for component in 0..<componentCount {
                let bounds = plane.componentBounds[
                    component % plane.componentsPerElement
                ]
                let code =
                    (Int(values[component]) + rounding)
                    >> plane.storedCodeShift
                let bounded = min(
                    max(code, Int(bounds.minimum)),
                    Int(bounds.maximum)
                )
                values[component] =
                    UInt16(bounded) << UInt16(plane.storedCodeShift)
            }
        }
    }

    private static func validateStoredCodesLocked(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout
    ) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        for (index, plane) in layout.planes.enumerated() {
            let base = try R13PixelBufferAccess.baseAddress(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let stride = R13PixelBufferAccess.rowBytes(
                of: pixelBuffer,
                layout: layout,
                plane: index
            )
            let componentCount =
                plane.width(for: width) * plane.componentsPerElement
            let rowCount = plane.height(for: height)
            try validateStoredPlane(
                base: base,
                stride: stride,
                rowCount: rowCount,
                componentCount: componentCount,
                plane: plane,
                planeIndex: index
            )
        }
    }

    private static func validateStoredPlane(
        base: UnsafeMutableRawPointer,
        stride: Int,
        rowCount: Int,
        componentCount: Int,
        plane: R13PixelPlaneLayout,
        planeIndex: Int
    ) throws {
        for row in 0..<rowCount {
            for component in 0..<componentCount {
                let stored = storedValue(
                    base: base,
                    stride: stride,
                    row: row,
                    component: component,
                    bytesPerComponent: plane.bytesPerComponent
                )
                try validateAlignment(
                    stored,
                    plane: plane,
                    planeIndex: planeIndex,
                    component: component
                )
                let code =
                    stored >> UInt16(plane.storedCodeShift)
                let bounds = plane.componentBounds[
                    component % plane.componentsPerElement
                ]
                guard code >= bounds.minimum,
                      code <= bounds.maximum else {
                    throw R13PixelLayoutError.codeOutOfRange(
                        plane: planeIndex,
                        component: component,
                        value: code,
                        minimum: bounds.minimum,
                        maximum: bounds.maximum
                    )
                }
            }
        }
    }

    private static func storedValue(
        base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int,
        component: Int,
        bytesPerComponent: Int
    ) -> UInt16 {
        if bytesPerComponent == 1 {
            return UInt16(
                base
                    .advanced(by: row * stride)
                    .assumingMemoryBound(to: UInt8.self)[component]
            )
        }
        return base
            .advanced(by: row * stride)
            .assumingMemoryBound(to: UInt16.self)[component]
    }

    private static func validateAlignment(
        _ stored: UInt16,
        plane: R13PixelPlaneLayout,
        planeIndex: Int,
        component: Int
    ) throws {
        guard plane.storedCodeShift > 0 else { return }
        let lowBitMask =
            UInt16((1 << plane.storedCodeShift) - 1)
        guard stored & lowBitMask == 0 else {
            throw R13PixelLayoutError.invalidCodeAlignment(
                plane: planeIndex,
                component: component,
                value: stored,
                requiredZeroLowBits: plane.storedCodeShift
            )
        }
    }
}
