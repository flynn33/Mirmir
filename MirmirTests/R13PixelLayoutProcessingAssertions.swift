import CoreVideo
import Foundation
@testable import Mirmir

extension R13PixelLayoutProcessingTests {
    func chromaEnergy(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> Double {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        let status = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard status == kCVReturnSuccess else {
            throw R13PixelLayoutError.lockFailed(
                destination: false,
                status: status
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        return try R13PixelLayoutProcessor
            .normalizedChromaEnergyLocked(
                pixelBuffer,
                column: 0,
                row: 0,
                layout: layout
            )
    }

    func wordCode(
        _ frame: R13TightPixelFrame,
        plane: Int,
        row: Int,
        component: Int
    ) throws -> UInt16 {
        let layout = try R13PixelLayoutRegistry.layout(
            for: frame.pixelFormat
        )
        let planeLayout = layout.planes[plane]
        let componentCount =
            planeLayout.width(for: frame.width)
                * planeLayout.componentsPerElement
        return frame.planes[plane].withUnsafeBytes {
            $0.bindMemory(to: UInt16.self)[
                row * componentCount + component
            ] >> UInt16(planeLayout.storedCodeShift)
        }
    }

    func data(_ words: [UInt16]) -> Data {
        words.withUnsafeBytes { rawBytes in
            Data(rawBytes)
        }
    }

    func weighted(
        _ north: UInt16,
        _ center: UInt16,
        _ south: UInt16
    ) -> UInt16 {
        UInt16(
            (
                UInt64(north)
                + UInt64(center) * 2
                + UInt64(south)
                + 2
            ) / 4
        )
    }

    func phaseQuarter(
        previous: UInt16,
        current: UInt16
    ) -> UInt16 {
        UInt16(
            (
                UInt64(previous) * 3
                + UInt64(current)
                + 2
            ) / 4
        )
    }
}
