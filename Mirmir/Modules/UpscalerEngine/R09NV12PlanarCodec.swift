import CoreVideo
import Foundation

enum R09NV12PlanarCodecError: Error, Equatable, Sendable {
    case unsupportedPixelFormat(OSType)
    case invalidPlaneCount(Int)
    case inaccessiblePlane(Int)
    case invalidPlaneStride(plane: Int, minimum: Int, actual: Int)
    case lockFailed(CVReturn)
    case allocationFailed(CVReturn)
    case geometryMismatch(
        plane: R09ResidualPlaneID,
        expectedWidth: Int,
        expectedHeight: Int,
        actualWidth: Int,
        actualHeight: Int
    )
    case sampleNotExactlyRepresentable(
        plane: R09ResidualPlaneID,
        index: Int,
        expectedQ16: Int64,
        materializedQ16: Int64
    )
}

enum R09NV12PlanarCodec {
    static func decode(_ pixelBuffer: CVPixelBuffer) throws -> R09PlanarFrameQ16 {
        try validateNV12(pixelBuffer)
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw R09NV12PlanarCodecError.lockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let luma = try readLuma(
            pixelBuffer,
            width: lumaWidth,
            height: lumaHeight
        )
        let chroma = try readChroma(
            pixelBuffer,
            width: chromaWidth,
            height: chromaHeight
        )
        return try R09PlanarFrameQ16(
            luma: R09UnsignedPlaneQ16(
                id: .luma,
                width: lumaWidth,
                height: lumaHeight,
                samplesQ16: luma
            ),
            chromaCb: R09UnsignedPlaneQ16(
                id: .chromaCb,
                width: chromaWidth,
                height: chromaHeight,
                samplesQ16: chroma.cb
            ),
            chromaCr: R09UnsignedPlaneQ16(
                id: .chromaCr,
                width: chromaWidth,
                height: chromaHeight,
                samplesQ16: chroma.cr
            )
        )
    }

    static func encode(
        _ frame: R09PlanarFrameQ16,
        matching source: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        try validateNV12(source)
        try validateGeometry(frame, matching: source)
        var destination: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            attributes,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else {
            throw R09NV12PlanarCodecError.allocationFailed(status)
        }
        CVBufferPropagateAttachments(source, destination)

        let lockStatus = CVPixelBufferLockBaseAddress(destination, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R09NV12PlanarCodecError.lockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        try writeLuma(frame.luma, to: destination)
        try writeChroma(cb: frame.chromaCb, cr: frame.chromaCr, to: destination)
        return destination
    }

    static func requireExactRepresentation(
        _ expected: R09PlanarFrameQ16,
        materialized: R09PlanarFrameQ16
    ) throws {
        for planeID in R09ResidualPlaneID.allCases {
            let expectedSamples = expected[planeID].samplesQ16
            let materializedSamples = materialized[planeID].samplesQ16
            for index in expectedSamples.indices
            where expectedSamples[index] != materializedSamples[index] {
                throw R09NV12PlanarCodecError.sampleNotExactlyRepresentable(
                    plane: planeID,
                    index: index,
                    expectedQ16: expectedSamples[index],
                    materializedQ16: materializedSamples[index]
                )
            }
        }
    }
}

private extension R09NV12PlanarCodec {
    static func validateNV12(_ pixelBuffer: CVPixelBuffer) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw R09NV12PlanarCodecError.unsupportedPixelFormat(format)
        }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard planeCount == 2 else {
            throw R09NV12PlanarCodecError.invalidPlaneCount(planeCount)
        }
    }

    static func validateGeometry(
        _ frame: R09PlanarFrameQ16,
        matching pixelBuffer: CVPixelBuffer
    ) throws {
        let expected: [(R09UnsignedPlaneQ16, Int)] = [
            (frame.luma, 0),
            (frame.chromaCb, 1),
            (frame.chromaCr, 1)
        ]
        for (plane, index) in expected {
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, index)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, index)
            guard plane.width == width, plane.height == height else {
                throw R09NV12PlanarCodecError.geometryMismatch(
                    plane: plane.id,
                    expectedWidth: width,
                    expectedHeight: height,
                    actualWidth: plane.width,
                    actualHeight: plane.height
                )
            }
        }
    }

    static func readLuma(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws -> [Int64] {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard stride >= width else {
            throw R09NV12PlanarCodecError.invalidPlaneStride(
                plane: 0,
                minimum: width,
                actual: stride
            )
        }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw R09NV12PlanarCodecError.inaccessiblePlane(0)
        }
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        return (0..<height).flatMap { row in
            let rowAddress = pointer.advanced(by: row * stride)
            return (0..<width).map { q16(rowAddress[$0]) }
        }
    }

    static func readChroma(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws -> (cb: [Int64], cr: [Int64]) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let minimumStride = width * 2
        guard stride >= minimumStride else {
            throw R09NV12PlanarCodecError.invalidPlaneStride(
                plane: 1,
                minimum: minimumStride,
                actual: stride
            )
        }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw R09NV12PlanarCodecError.inaccessiblePlane(1)
        }
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        var cb: [Int64] = []
        var cr: [Int64] = []
        cb.reserveCapacity(width * height)
        cr.reserveCapacity(width * height)
        for row in 0..<height {
            let rowAddress = pointer.advanced(by: row * stride)
            for column in 0..<width {
                cb.append(q16(rowAddress[column * 2]))
                cr.append(q16(rowAddress[column * 2 + 1]))
            }
        }
        return (cb, cr)
    }

    static func writeLuma(
        _ plane: R09UnsignedPlaneQ16,
        to pixelBuffer: CVPixelBuffer
    ) throws {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard stride >= plane.width else {
            throw R09NV12PlanarCodecError.invalidPlaneStride(
                plane: 0,
                minimum: plane.width,
                actual: stride
            )
        }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw R09NV12PlanarCodecError.inaccessiblePlane(0)
        }
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<plane.height {
            let rowAddress = pointer.advanced(by: row * stride)
            for column in 0..<plane.width {
                rowAddress[column] = byte(plane.samplesQ16[row * plane.width + column])
            }
        }
    }

    static func writeChroma(
        cb: R09UnsignedPlaneQ16,
        cr: R09UnsignedPlaneQ16,
        to pixelBuffer: CVPixelBuffer
    ) throws {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let minimumStride = cb.width * 2
        guard stride >= minimumStride else {
            throw R09NV12PlanarCodecError.invalidPlaneStride(
                plane: 1,
                minimum: minimumStride,
                actual: stride
            )
        }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw R09NV12PlanarCodecError.inaccessiblePlane(1)
        }
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<cb.height {
            let rowAddress = pointer.advanced(by: row * stride)
            for column in 0..<cb.width {
                let index = row * cb.width + column
                rowAddress[column * 2] = byte(cb.samplesQ16[index])
                rowAddress[column * 2 + 1] = byte(cr.samplesQ16[index])
            }
        }
    }

    static func q16(_ byte: UInt8) -> Int64 {
        Int64(byte) * 257
    }

    static func byte(_ q16: Int64) -> UInt8 {
        UInt8(min(255, max(0, (q16 + 128) / 257)))
    }
}
