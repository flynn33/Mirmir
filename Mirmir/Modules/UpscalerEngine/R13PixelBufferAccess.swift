import CoreVideo
import Foundation

enum R13PixelBufferAccess {
    static func baseAddress(
        of pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        plane: Int
    ) throws -> UnsafeMutableRawPointer {
        let base = layout.isPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBaseAddress(pixelBuffer)
        guard let base else {
            throw R13PixelLayoutError.inaccessiblePlane(plane)
        }
        return base
    }

    static func rowBytes(
        of pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        plane: Int
    ) -> Int {
        layout.isPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
    }

    static func width(
        of pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        plane: Int
    ) -> Int {
        layout.isPlanar
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetWidth(pixelBuffer)
    }

    static func height(
        of pixelBuffer: CVPixelBuffer,
        layout: R13PixelLayout,
        plane: Int
    ) -> Int {
        layout.isPlanar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetHeight(pixelBuffer)
    }
}

extension R13PixelLayoutProcessor {
    static func copyAttachments(
        source: CVPixelBuffer,
        destination: CVPixelBuffer
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

    static func lockReadOnly(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
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
    }

    static func lockWritable(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R13PixelLayoutError.lockFailed(
                destination: true,
                status: status
            )
        }
    }

    static func validateMatchingGeometry(
        _ buffers: [CVPixelBuffer]
    ) throws {
        guard let first = buffers.first else { return }
        let width = CVPixelBufferGetWidth(first)
        let height = CVPixelBufferGetHeight(first)
        guard buffers.allSatisfy({
            CVPixelBufferGetWidth($0) == width
                && CVPixelBufferGetHeight($0) == height
        }) else {
            throw R13PixelLayoutError.invalidGeometry(
                width: width,
                height: height
            )
        }
    }
}
