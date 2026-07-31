import CoreVideo
import Foundation
@testable import Mirmir

enum R13PixelLayoutTestFixtures {
    static var allMediaVideoFormats: [MediaVideoFormat] {
        MediaVideoPixelStorage.allCases.map { storage in
            MediaVideoFormat(
                pixelStorage: storage,
                colorPrimaries: .bt709,
                transferFunction: .bt709,
                alphaMode: storage.hasAlpha ? .straight : .none
            )
        }
    }

    static func makeGradientBuffer(
        pixelFormat: OSType,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        let planes = try layout.planes.enumerated().map { planeIndex, plane in
            try makePlaneData(
                planeIndex: planeIndex,
                plane: plane,
                width: width,
                height: height
            )
        }
        return try R13TightPixelFrame(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            planes: planes
        ).makePixelBuffer()
    }

    static func makeUniformBuffer(
        pixelFormat: OSType,
        width: Int,
        height: Int,
        maximumLuma: Bool,
        extremeChroma: Bool = false
    ) throws -> CVPixelBuffer {
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        let planes = try layout.planes.map { plane in
            try makeUniformPlaneData(
                plane,
                width: width,
                height: height,
                maximumLuma: maximumLuma,
                extremeChroma: extremeChroma
            )
        }
        return try R13TightPixelFrame(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            planes: planes
        ).makePixelBuffer()
    }
}

extension R13PixelLayoutTestFixtures {
    static func makeEffectBuffer(
        pixelFormat: OSType,
        width: Int,
        height: Int,
        offset: Int = 0
    ) throws -> CVPixelBuffer {
        let pixelBuffer = try makeGradientBuffer(
            pixelFormat: pixelFormat,
            width: width,
            height: height
        )
        let layout = try R13PixelLayoutRegistry.layout(
            for: pixelFormat
        )
        let planeIndex = try effectPlaneIndex(layout)
        let plane = layout.planes[planeIndex]
        let lumaComponents: [Int]
        switch plane.role {
        case .luma:
            lumaComponents = [0]
        case .packedBGRA:
            lumaComponents = [0, 1, 2]
        case .packedAYCbCr:
            lumaComponents = [1]
        default:
            throw R13PixelLayoutError.unsupportedPixelFormat(
                pixelFormat
            )
        }
        try R13PixelLayoutProcessor.lockWritable(pixelBuffer)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
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
        for row in 0..<height {
            for column in 0..<width {
                for component in lumaComponents {
                    let bounds = plane.componentBounds[component]
                    let code = effectCode(
                        row: row,
                        column: column,
                        width: width,
                        height: height,
                        offset: offset,
                        bounds: bounds
                    )
                    writeCode(
                        code,
                        base: base,
                        stride: stride,
                        row: row,
                        column: column,
                        component: component,
                        plane: plane
                    )
                }
            }
        }
        return pixelBuffer
    }

    static func lumaCodes(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> [UInt16] {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        let planeIndex = try effectPlaneIndex(layout)
        let plane = layout.planes[planeIndex]
        let component = plane.role == .packedAYCbCr ? 1 : 0
        return try componentCodes(
            pixelBuffer,
            layout: layout,
            planeIndex: planeIndex,
            component: component
        )
    }

    static func alphaCodes(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> [UInt16] {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        let planeIndex: Int
        let component: Int
        if let alphaIndex = layout.planes.firstIndex(
            where: { $0.role == .alpha }
        ) {
            planeIndex = alphaIndex
            component = 0
        } else {
            planeIndex = 0
            switch layout.planes[0].role {
            case .packedBGRA:
                component = 3
            case .packedAYCbCr:
                component = 0
            default:
                return []
            }
        }
        return try componentCodes(
            pixelBuffer,
            layout: layout,
            planeIndex: planeIndex,
            component: component
        )
    }

    private static func effectPlaneIndex(
        _ layout: R13PixelLayout
    ) throws -> Int {
        guard let index = layout.planes.firstIndex(
            where: {
                $0.role == .luma
                    || $0.role == .packedBGRA
                    || $0.role == .packedAYCbCr
            }
        ) else {
            throw R13PixelLayoutError.unsupportedPixelFormat(
                layout.pixelFormat
            )
        }
        return index
    }

    private static func effectCode(
        row: Int,
        column: Int,
        width: Int,
        height: Int,
        offset: Int,
        bounds: R13PixelCodeBounds
    ) -> Int {
        let minimum = Int(bounds.minimum)
        let maximum = Int(bounds.maximum)
        let span = max(1, maximum - minimum)
        let base = minimum + span * 3 / 8
        let motion = offset * max(1, span / 128)
        let value: Int
        if row < height / 2, column < width / 2 {
            let blockNoise =
                ((row + column + offset) % 3 - 1)
                * max(1, span / 128)
            value = base + motion + blockNoise
        } else {
            let edge = column >= width / 2 ? span * 5 / 16 : 0
            let texture =
                (row + column + offset).isMultiple(of: 2)
                ? span / 20
                : -(span / 20)
            value = base + edge + texture + motion
        }
        return min(max(value, minimum), maximum)
    }

    private static func writeCode(
        _ code: Int,
        base: UnsafeMutableRawPointer,
        stride: Int,
        row: Int,
        column: Int,
        component: Int,
        plane: R13PixelPlaneLayout
    ) {
        let index =
            column * plane.componentsPerElement + component
        if plane.bytesPerComponent == 1 {
            base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self)[index] =
                UInt8(code)
        } else {
            base
                .advanced(by: row * stride)
                .assumingMemoryBound(to: UInt16.self)[index] =
                UInt16(code) << UInt16(plane.storedCodeShift)
        }
    }

    private static func componentCodes(
        _ pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        planeIndex: Int,
        component: Int
    ) throws -> [UInt16] {
        try R13PixelLayoutProcessor.lockReadOnly(pixelBuffer)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
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
        let width = plane.width(
            for: CVPixelBufferGetWidth(pixelBuffer)
        )
        let height = plane.height(
            for: CVPixelBufferGetHeight(pixelBuffer)
        )
        var values: [UInt16] = []
        values.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                let index =
                    column * plane.componentsPerElement + component
                if plane.bytesPerComponent == 1 {
                    values.append(
                        UInt16(
                            base
                                .advanced(by: row * stride)
                                .assumingMemoryBound(to: UInt8.self)[index]
                        )
                    )
                } else {
                    values.append(
                        base
                            .advanced(by: row * stride)
                            .assumingMemoryBound(to: UInt16.self)[index]
                            >> UInt16(plane.storedCodeShift)
                    )
                }
            }
        }
        return values
    }
}

extension R13PixelLayoutTestFixtures {
    private static func makePlaneData(
        planeIndex: Int,
        plane: R13PixelPlaneLayout,
        width: Int,
        height: Int
    ) throws -> Data {
        let componentCount =
            plane.width(for: width) * plane.componentsPerElement
        let rowCount = plane.height(for: height)
        var data = Data(
            count: try plane.activeByteCount(
                frameWidth: width,
                frameHeight: height
            )
        )
        data.withUnsafeMutableBytes { rawBytes in
            for row in 0..<rowCount {
                for component in 0..<componentCount {
                    let bounds = plane.componentBounds[
                        component % plane.componentsPerElement
                    ]
                    let span = Int(
                        bounds.maximum - bounds.minimum
                    )
                    let ordinal =
                        row * componentCount
                        + component
                        + planeIndex
                    let code =
                        Int(bounds.minimum)
                        + (ordinal * 37) % max(span + 1, 1)
                    write(
                        code,
                        row: row,
                        component: component,
                        componentCount: componentCount,
                        plane: plane,
                        rawBytes: rawBytes
                    )
                }
            }
        }
        return data
    }

    private static func write(
        _ code: Int,
        row: Int,
        component: Int,
        componentCount: Int,
        plane: R13PixelPlaneLayout,
        rawBytes: UnsafeMutableRawBufferPointer
    ) {
        let index = row * componentCount + component
        if plane.bytesPerComponent == 1 {
            rawBytes.bindMemory(to: UInt8.self)[index] =
                UInt8(code)
        } else {
            rawBytes.bindMemory(to: UInt16.self)[index] =
                UInt16(code) << UInt16(plane.storedCodeShift)
        }
    }

    private static func makeUniformPlaneData(
        _ plane: R13PixelPlaneLayout,
        width: Int,
        height: Int,
        maximumLuma: Bool,
        extremeChroma: Bool
    ) throws -> Data {
        let componentCount =
            plane.width(for: width) * plane.componentsPerElement
        let rowCount = plane.height(for: height)
        var data = Data(
            count: try plane.activeByteCount(
                frameWidth: width,
                frameHeight: height
            )
        )
        data.withUnsafeMutableBytes { rawBytes in
            for row in 0..<rowCount {
                for component in 0..<componentCount {
                    let componentOrdinal =
                        component % plane.componentsPerElement
                    let code = uniformCode(
                        plane: plane,
                        component: componentOrdinal,
                        maximumLuma: maximumLuma,
                        extremeChroma: extremeChroma
                    )
                    write(
                        code,
                        row: row,
                        component: component,
                        componentCount: componentCount,
                        plane: plane,
                        rawBytes: rawBytes
                    )
                }
            }
        }
        return data
    }

    private static func uniformCode(
        plane: R13PixelPlaneLayout,
        component: Int,
        maximumLuma: Bool,
        extremeChroma: Bool
    ) -> Int {
        let bounds = plane.componentBounds[component]
        let neutral =
            (
                Int(bounds.minimum)
                + Int(bounds.maximum)
                + 1
            ) / 2
        switch plane.role {
        case .luma:
            return maximumLuma
                ? Int(bounds.maximum)
                : Int(bounds.minimum)
        case .interleavedChroma:
            return extremeChroma ? Int(bounds.minimum) : neutral
        case .alpha:
            return neutral
        case .packedBGRA:
            return component == 3
                ? Int(bounds.maximum)
                : (
                    maximumLuma
                    ? Int(bounds.maximum)
                    : Int(bounds.minimum)
                )
        case .packedAYCbCr:
            if component == 0 {
                return neutral
            }
            if component == 1 {
                return maximumLuma
                    ? Int(bounds.maximum)
                    : Int(bounds.minimum)
            }
            return extremeChroma ? Int(bounds.minimum) : neutral
        }
    }
}
