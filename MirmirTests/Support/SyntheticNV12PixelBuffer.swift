import CoreVideo
import Darwin
import Foundation

enum SyntheticPixelBufferError: Error, Equatable {
    case creationFailed(CVReturn)
    case missingPixelBuffer
    case lockFailed(CVReturn)
    case missingBaseAddress(Int)
    case invalidNV12Geometry(width: Int, height: Int, rowAlignment: Int)
    case unsupportedNV12PixelFormat(OSType)
    case allocationSizeOverflow
    case allocationFailed(byteCount: Int)
}

enum SyntheticNV12PixelBuffer {
    struct SharedBackingPair {
        let source: CVPixelBuffer
        let destination: CVPixelBuffer
    }

    static func make(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        rowAlignment: Int = 64
    ) throws -> CVPixelBuffer {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferBytesPerRowAlignmentKey as String: rowAlignment
        ] as CFDictionary
        var optionalPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes,
            &optionalPixelBuffer
        )
        guard status == kCVReturnSuccess else {
            throw SyntheticPixelBufferError.creationFailed(status)
        }
        guard let pixelBuffer = optionalPixelBuffer else {
            throw SyntheticPixelBufferError.missingPixelBuffer
        }
        return pixelBuffer
    }

    static func makeSharedBackingPair(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        rowAlignment: Int = 64
    ) throws -> SharedBackingPair {
        guard width > 0,
              height > 0,
              width.isMultiple(of: 2),
              height.isMultiple(of: 2),
              rowAlignment > 0 else {
            throw SyntheticPixelBufferError.invalidNV12Geometry(
                width: width,
                height: height,
                rowAlignment: rowAlignment
            )
        }
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw SyntheticPixelBufferError.unsupportedNV12PixelFormat(pixelFormat)
        }
        guard let rowBytes = alignedRowBytes(
            visibleByteCount: width,
            alignment: rowAlignment
        ) else {
            throw SyntheticPixelBufferError.allocationSizeOverflow
        }
        let (lumaByteCount, lumaOverflow) = rowBytes.multipliedReportingOverflow(
            by: height
        )
        let (chromaByteCount, chromaOverflow) = rowBytes
            .multipliedReportingOverflow(by: height / 2)
        guard !lumaOverflow, !chromaOverflow else {
            throw SyntheticPixelBufferError.allocationSizeOverflow
        }

        let storage = try SharedNV12PlaneStorage(
            lumaByteCount: lumaByteCount,
            chromaByteCount: chromaByteCount
        )
        let source = try makePlanarBuffer(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            rowBytes: rowBytes,
            storage: storage
        )
        let destination = try makePlanarBuffer(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            rowBytes: rowBytes,
            storage: storage
        )
        return SharedBackingPair(source: source, destination: destination)
    }

    static func fill(
        _ pixelBuffer: CVPixelBuffer,
        luma: UInt8,
        cb: UInt8,
        cr: UInt8,
        padding: UInt8 = 0xA5
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw SyntheticPixelBufferError.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw SyntheticPixelBufferError.missingBaseAddress(0)
        }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for rowIndex in 0..<lumaHeight {
            let row = lumaBase
                .advanced(by: rowIndex * lumaRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            row.update(repeating: padding, count: lumaRowBytes)
            row.update(repeating: luma, count: lumaWidth)
        }

        guard let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw SyntheticPixelBufferError.missingBaseAddress(1)
        }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for rowIndex in 0..<chromaHeight {
            let row = chromaBase
                .advanced(by: rowIndex * chromaRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            row.update(repeating: padding, count: chromaRowBytes)
            for column in 0..<chromaWidth {
                row[column * 2] = cb
                row[column * 2 + 1] = cr
            }
        }
    }

    static func visibleBytes(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int
    ) throws -> [UInt8] {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw SyntheticPixelBufferError.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            plane
        ) else {
            throw SyntheticPixelBufferError.missingBaseAddress(plane)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let bytesPerElement = plane == 0 ? 1 : 2
        let visibleRowBytes = width * bytesPerElement
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        var result: [UInt8] = []
        result.reserveCapacity(visibleRowBytes * height)
        for rowIndex in 0..<height {
            let row = baseAddress
                .advanced(by: rowIndex * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            result.append(contentsOf: UnsafeBufferPointer(
                start: row,
                count: visibleRowBytes
            ))
        }
        return result
    }

    static func paddingBytes(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int
    ) throws -> [UInt8] {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw SyntheticPixelBufferError.lockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            plane
        ) else {
            throw SyntheticPixelBufferError.missingBaseAddress(plane)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let bytesPerElement = plane == 0 ? 1 : 2
        let visibleRowBytes = width * bytesPerElement
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        var result: [UInt8] = []
        for rowIndex in 0..<height where rowBytes > visibleRowBytes {
            let row = baseAddress
                .advanced(by: rowIndex * rowBytes + visibleRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            result.append(contentsOf: UnsafeBufferPointer(
                start: row,
                count: rowBytes - visibleRowBytes
            ))
        }
        return result
    }

    private static func alignedRowBytes(
        visibleByteCount: Int,
        alignment: Int
    ) -> Int? {
        let (adjustedByteCount, overflow) = visibleByteCount
            .addingReportingOverflow(alignment - 1)
        guard !overflow else {
            return nil
        }
        return adjustedByteCount / alignment * alignment
    }

    private static func makePlanarBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        rowBytes: Int,
        storage: SharedNV12PlaneStorage
    ) throws -> CVPixelBuffer {
        var planeBaseAddresses: [UnsafeMutableRawPointer?] = [
            storage.lumaBaseAddress,
            storage.chromaBaseAddress
        ]
        var planeWidths = [width, width / 2]
        var planeHeights = [height, height / 2]
        var planeBytesPerRow = [rowBytes, rowBytes]
        var optionalPixelBuffer: CVPixelBuffer?

        let retainedStorage = Unmanaged.passRetained(storage)
        let status = CVPixelBufferCreateWithPlanarBytes(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            0,
            planeBaseAddresses.count,
            &planeBaseAddresses,
            &planeWidths,
            &planeHeights,
            &planeBytesPerRow,
            releaseSharedNV12PlaneStorage,
            retainedStorage.toOpaque(),
            nil,
            &optionalPixelBuffer
        )
        guard status == kCVReturnSuccess else {
            retainedStorage.release()
            throw SyntheticPixelBufferError.creationFailed(status)
        }
        guard let pixelBuffer = optionalPixelBuffer else {
            retainedStorage.release()
            throw SyntheticPixelBufferError.missingPixelBuffer
        }
        return pixelBuffer
    }
}

private final class SharedNV12PlaneStorage {
    let lumaBaseAddress: UnsafeMutableRawPointer
    let chromaBaseAddress: UnsafeMutableRawPointer

    init(lumaByteCount: Int, chromaByteCount: Int) throws {
        guard let lumaBaseAddress = malloc(lumaByteCount) else {
            throw SyntheticPixelBufferError.allocationFailed(
                byteCount: lumaByteCount
            )
        }
        guard let chromaBaseAddress = malloc(chromaByteCount) else {
            free(lumaBaseAddress)
            throw SyntheticPixelBufferError.allocationFailed(
                byteCount: chromaByteCount
            )
        }
        self.lumaBaseAddress = lumaBaseAddress
        self.chromaBaseAddress = chromaBaseAddress
        memset(lumaBaseAddress, 0, lumaByteCount)
        memset(chromaBaseAddress, 0, chromaByteCount)
    }

    deinit {
        free(chromaBaseAddress)
        free(lumaBaseAddress)
    }
}

private func releaseSharedNV12PlaneStorage(
    releaseRefCon: UnsafeMutableRawPointer?,
    dataPtr _: UnsafeRawPointer?,
    dataSize _: Int,
    numberOfPlanes _: Int,
    planeAddresses _: UnsafeMutablePointer<UnsafeRawPointer?>?
) {
    guard let releaseRefCon else {
        return
    }
    Unmanaged<SharedNV12PlaneStorage>
        .fromOpaque(releaseRefCon)
        .release()
}
