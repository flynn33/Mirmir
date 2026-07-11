import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fourCC(_ value: OSType) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
}

private func cfString(_ value: CFTypeRef?) -> String? {
    guard let value else { return nil }
    if CFGetTypeID(value) == CFStringGetTypeID() {
        return value as? String
    }
    return String(describing: value)
}

private func pixelAttachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
    guard let value = CVBufferCopyAttachment(buffer, key, nil) else {
        return nil
    }
    return cfString(value)
}

private func formatAttachment(_ format: CMFormatDescription, _ key: CFString) -> String? {
    cfString(CMFormatDescriptionGetExtension(format, extensionKey: key))
}

private func pixelAttachments(_ buffer: CVPixelBuffer) -> AttachmentEvidence {
    AttachmentEvidence(
        colorPrimaries: pixelAttachment(buffer, kCVImageBufferColorPrimariesKey),
        transferFunction: pixelAttachment(buffer, kCVImageBufferTransferFunctionKey),
        yCbCrMatrix: pixelAttachment(buffer, kCVImageBufferYCbCrMatrixKey),
        chromaLocationTopField: pixelAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey),
        chromaLocationBottomField: pixelAttachment(
            buffer,
            kCVImageBufferChromaLocationBottomFieldKey
        ),
        range: CVPixelBufferGetPixelFormatType(buffer) == expectedPixelFormat ? "video" : "unknown"
    )
}

func formatAttachments(_ format: CMFormatDescription) -> AttachmentEvidence {
    let fullRange = CMFormatDescriptionGetExtension(
        format,
        extensionKey: kCMFormatDescriptionExtension_FullRangeVideo
    )
    let range = (fullRange as? Bool) == true ? "full" : "video"
    return AttachmentEvidence(
        colorPrimaries: formatAttachment(format, kCMFormatDescriptionExtension_ColorPrimaries),
        transferFunction: formatAttachment(format, kCMFormatDescriptionExtension_TransferFunction),
        yCbCrMatrix: formatAttachment(format, kCMFormatDescriptionExtension_YCbCrMatrix),
        chromaLocationTopField: formatAttachment(
            format,
            kCMFormatDescriptionExtension_ChromaLocationTopField
        ),
        chromaLocationBottomField: formatAttachment(
            format,
            kCMFormatDescriptionExtension_ChromaLocationBottomField
        ),
        range: range
    )
}

func decodedFrameEvidence(
    pixelBuffer: CVPixelBuffer,
    index: Int,
    presentationTime: CMTime,
    duration: CMTime
) throws -> DecodedFrameEvidence {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard format == expectedPixelFormat else {
        throw FixtureError.invalidFixture(
            "decoded pixel format \(fourCC(format)) is not video-range NV12"
        )
    }
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw FixtureError.invalidFixture("decoded NV12 buffer does not have two planes")
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard lockStatus == kCVReturnSuccess else {
        throw FixtureError.operation("CVPixelBufferLockBaseAddress", lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
        throw FixtureError.invalidFixture("decoded NV12 plane base address is absent")
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
    guard CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == width,
          CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == height,
          CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) * 2 == width,
          uvHeight * 2 == height,
          yStride >= width,
          uvStride >= width else {
        throw FixtureError.invalidFixture("decoded NV12 plane geometry is inconsistent")
    }

    var luma = Data()
    var cb = Data()
    var cr = Data()
    luma.reserveCapacity(width * height)
    cb.reserveCapacity(width * height / 4)
    cr.reserveCapacity(width * height / 4)
    for row in 0..<height {
        luma.append(Data(bytes: yBase.advanced(by: row * yStride), count: width))
    }
    for row in 0..<uvHeight {
        let source = uvBase.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
        for column in stride(from: 0, to: width, by: 2) {
            cb.append(source[column])
            cr.append(source[column + 1])
        }
    }
    return DecodedFrameEvidence(
        index: index,
        presentationTime: ExactTime(presentationTime),
        duration: ExactTime(duration),
        width: width,
        height: height,
        pixelFormat: fourCC(format),
        activeRowSha256: PlaneHashes(
            luma: sha256(luma),
            chromaBlue: sha256(cb),
            chromaRed: sha256(cr)
        ),
        attachments: pixelAttachments(pixelBuffer)
    )
}

func makeSourcePixelBuffer(
    payload: Data,
    offset: Int,
    width: Int,
    height: Int
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: expectedPixelFormat),
        kCVPixelBufferWidthKey as String: NSNumber(value: width),
        kCVPixelBufferHeightKey as String: NSNumber(value: height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
    ]
    let createStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        expectedPixelFormat,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard createStatus == kCVReturnSuccess, let pixelBuffer else {
        throw FixtureError.operation("CVPixelBufferCreate", createStatus)
    }
    let frameSize = width * height * 3 / 2
    guard offset >= 0, offset + frameSize <= payload.count else {
        throw FixtureError.invalidFixture("source NV12 payload is truncated")
    }
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else {
        throw FixtureError.operation("CVPixelBufferLockBaseAddress", lockStatus)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
        throw FixtureError.invalidFixture("source NV12 plane base address is absent")
    }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
    payload.withUnsafeBytes { source in
        guard let sourceBase = source.baseAddress else { return }
        for row in 0..<height {
            memcpy(yBase.advanced(by: row * yStride), sourceBase.advanced(by: offset + row * width), width)
        }
        let uvOffset = offset + width * height
        for row in 0..<(height / 2) {
            memcpy(
                uvBase.advanced(by: row * uvStride),
                sourceBase.advanced(by: uvOffset + row * width),
                width
            )
        }
    }
    setLockedAttachments(pixelBuffer)
    return pixelBuffer
}

private func setLockedAttachments(_ pixelBuffer: CVPixelBuffer) {
    let attachments: [(CFString, CFString)] = [
        (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
        (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
        (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
        (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
    ]
    for (key, value) in attachments {
        CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
    }
}
