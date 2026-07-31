import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import Mirmir

struct Non420VideoFixtureFormat: Sendable {
    let pixelFormat: OSType
    let colorPrimaries: String
    let transferFunction: String
    let yCbCrMatrix: String
    let chromaLocation: String?
    let isFullRangeVideo: Bool
    let bitsPerComponent: Int
    let alphaMode: MediaVideoAlphaMode
    let masteringDisplayColorVolume: Data?
    let contentLightLevelInfo: Data?

    init(videoFormat: MediaVideoFormat) {
        pixelFormat = videoFormat.pixelStorage.pixelFormat
        colorPrimaries = videoFormat.colorPrimaries.cmValue
        transferFunction = videoFormat.transferFunction.cmValue
        yCbCrMatrix = videoFormat.cmYCbCrMatrix
        chromaLocation = videoFormat.chromaLocation
        isFullRangeVideo =
            videoFormat.pixelStorage.codeRange == .full
        bitsPerComponent = videoFormat.pixelStorage.bitDepth
        alphaMode = videoFormat.alphaMode
        masteringDisplayColorVolume =
            videoFormat.masteringDisplayColorVolume
        contentLightLevelInfo = videoFormat.contentLightLevelInfo
    }

    private init(
        pixelFormat: OSType,
        colorPrimaries: String,
        transferFunction: String,
        yCbCrMatrix: String,
        chromaLocation: String?,
        isFullRangeVideo: Bool,
        bitsPerComponent: Int,
        alphaMode: MediaVideoAlphaMode,
        masteringDisplayColorVolume: Data?,
        contentLightLevelInfo: Data?
    ) {
        self.pixelFormat = pixelFormat
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.chromaLocation = chromaLocation
        self.isFullRangeVideo = isFullRangeVideo
        self.bitsPerComponent = bitsPerComponent
        self.alphaMode = alphaMode
        self.masteringDisplayColorVolume =
            masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
    }

    static let sdrBT709VideoRange422 = Non420VideoFixtureFormat(
        pixelFormat: kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
        colorPrimaries:
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
        transferFunction:
            kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
        yCbCrMatrix:
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
        chromaLocation:
            kCMFormatDescriptionChromaLocation_Left as String,
        isFullRangeVideo: false,
        bitsPerComponent: 8,
        alphaMode: .none,
        masteringDisplayColorVolume: nil,
        contentLightLevelInfo: nil
    )

    static func hdrBT2020PQFullRange444(
        masteringDisplayColorVolume: Data,
        contentLightLevelInfo: Data
    ) -> Non420VideoFixtureFormat {
        Non420VideoFixtureFormat(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
            colorPrimaries:
                kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
            transferFunction:
                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                    as String,
            yCbCrMatrix:
                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String,
            chromaLocation: nil,
            isFullRangeVideo: true,
            bitsPerComponent: 10,
            alphaMode: .none,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevelInfo: contentLightLevelInfo
        )
    }

    static func sdrBT709HighPrecisionAlpha(
        mode: MediaVideoAlphaMode
    ) -> Non420VideoFixtureFormat {
        precondition(mode != .none)
        return Non420VideoFixtureFormat(
            pixelFormat:
                kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar,
            colorPrimaries:
                kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
            transferFunction:
                kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix:
                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
            chromaLocation: nil,
            isFullRangeVideo: false,
            bitsPerComponent: 16,
            alphaMode: mode,
            masteringDisplayColorVolume: nil,
            contentLightLevelInfo: nil
        )
    }
}

enum Non420VideoFixtureError: Error, Equatable {
    case destinationExists
    case formatDescriptionCreationFailed(OSStatus)
    case pixelBufferCreationFailed(CVReturn)
    case writerCannotAddInput
    case writerStartFailed(String)
    case pixelBufferAppendFailed(String)
    case writerFailed(String)
    case invalidPixelBufferLayout
}

func writeUncompressedNon420VideoFixture(
    to url: URL,
    resolution: VideoResolution = VideoResolution(
        width: 64,
        height: 64
    ),
    format: Non420VideoFixtureFormat,
    frameCount: Int = 2,
    frameDuration: CMTime = CMTime(value: 1, timescale: 30)
) async throws {
    precondition(frameCount > 0)
    let formatDescription = try makeNon420FormatDescription(
        resolution: resolution,
        format: format
    )
    try await writeNon420VideoFixture(
        to: url,
        resolution: resolution,
        format: format,
        frameCount: frameCount,
        frameDuration: frameDuration,
        outputSettings: nil,
        sourceFormatHint: formatDescription
    )
}

func writeProRes4444Non420VideoFixture(
    to url: URL,
    resolution: VideoResolution = VideoResolution(
        width: 64,
        height: 64
    ),
    format: Non420VideoFixtureFormat,
    frameCount: Int = 2,
    frameDuration: CMTime = CMTime(value: 1, timescale: 30)
) async throws {
    precondition(frameCount > 0)
    precondition(
        format.pixelFormat
            == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            || format.pixelFormat
                == kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar
    )
    var compressionProperties: [String: Any] = [:]
    if format.transferFunction
        == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            as String
        || format.transferFunction
            == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                as String {
        compressionProperties[
            kVTCompressionPropertyKey_HDRMetadataInsertionMode as String
        ] = kVTHDRMetadataInsertionMode_Auto
    }
    if let mastering = format.masteringDisplayColorVolume {
        compressionProperties[
            kVTCompressionPropertyKey_MasteringDisplayColorVolume as String
        ] = mastering
    }
    if let contentLight = format.contentLightLevelInfo {
        compressionProperties[
            kVTCompressionPropertyKey_ContentLightLevelInfo as String
        ] = contentLight
    }
    if format.alphaMode != .none {
        compressionProperties[
            kVTCompressionPropertyKey_AlphaChannelMode as String
        ] = format.alphaMode == .straight
            ? kVTAlphaChannelMode_StraightAlpha
            : kVTAlphaChannelMode_PremultipliedAlpha
    }
    var outputSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.proRes4444,
        AVVideoWidthKey: resolution.width,
        AVVideoHeightKey: resolution.height
    ]
    if !compressionProperties.isEmpty {
        outputSettings[AVVideoCompressionPropertiesKey] =
            compressionProperties
    }
    let sourceFormatHint = try makeNon420FormatDescription(
        resolution: resolution,
        format: format
    )
    try await writeNon420VideoFixture(
        to: url,
        resolution: resolution,
        format: format,
        frameCount: frameCount,
        frameDuration: frameDuration,
        outputSettings: outputSettings,
        sourceFormatHint: sourceFormatHint
    )
}

func writeCompressedRegisteredVideoFixture(
    to url: URL,
    resolution: VideoResolution = VideoResolution(
        width: 64,
        height: 64
    ),
    videoFormat: MediaVideoFormat,
    codec: OutputCodec,
    frameCount: Int = 2,
    frameDuration: CMTime = CMTime(value: 1, timescale: 30)
) async throws {
    precondition(frameCount > 0)
    precondition(videoFormat.supports(outputCodec: codec))
    let format = Non420VideoFixtureFormat(
        videoFormat: videoFormat
    )
    let sourceFormatHint = try makeNon420FormatDescription(
        resolution: resolution,
        format: format
    )
    try await writeNon420VideoFixture(
        to: url,
        resolution: resolution,
        format: format,
        frameCount: frameCount,
        frameDuration: frameDuration,
        outputSettings: ProductVideoOutputSettings.make(
            resolution: resolution,
            codec: codec,
            videoFormat: videoFormat
        ),
        sourceFormatHint: sourceFormatHint
    )
}

private func writeNon420VideoFixture(
    to url: URL,
    resolution: VideoResolution,
    format: Non420VideoFixtureFormat,
    frameCount: Int,
    frameDuration: CMTime,
    outputSettings: [String: Any]?,
    sourceFormatHint: CMFormatDescription
) async throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw Non420VideoFixtureError.destinationExists
    }
    let writer = try AVAssetWriter(url: url, fileType: .mov)
    writer.movieTimeScale = 600
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: outputSettings,
        sourceFormatHint: sourceFormatHint
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                format.pixelFormat,
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ]
    )
    guard writer.canAdd(input) else {
        throw Non420VideoFixtureError.writerCannotAddInput
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw Non420VideoFixtureError.writerStartFailed(
            writer.error.map(String.init(describing:)) ?? "unknown"
        )
    }
    writer.startSession(atSourceTime: .zero)
    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            if writer.status == .failed || writer.status == .cancelled {
                throw Non420VideoFixtureError.writerFailed(
                    writer.error.map(String.init(describing:))
                        ?? "status \(writer.status.rawValue)"
                )
            }
            await Task.yield()
        }
        let pixelBuffer = try makeNon420FixturePixelBuffer(
            resolution: resolution,
            format: format,
            frameIndex: frameIndex
        )
        let presentationTime = CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameIndex)
        )
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: presentationTime
        ) else {
            throw Non420VideoFixtureError.pixelBufferAppendFailed(
                writer.error.map(String.init(describing:)) ?? "unknown"
            )
        }
    }

    input.markAsFinished()
    let endTime = CMTimeMultiply(
        frameDuration,
        multiplier: Int32(frameCount)
    )
    writer.endSession(atSourceTime: endTime)
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw Non420VideoFixtureError.writerFailed(
            writer.error.map(String.init(describing:))
                ?? "status \(writer.status.rawValue)"
        )
    }
}

func makeNon420FormatDescription(
    resolution: VideoResolution,
    format: Non420VideoFixtureFormat
) throws -> CMFormatDescription {
    var extensions: [String: Any] = [
        kCMFormatDescriptionExtension_ColorPrimaries as String:
            format.colorPrimaries,
        kCMFormatDescriptionExtension_TransferFunction as String:
            format.transferFunction,
        kCMFormatDescriptionExtension_YCbCrMatrix as String:
            format.yCbCrMatrix,
        kCMFormatDescriptionExtension_FullRangeVideo as String:
            format.isFullRangeVideo,
        kCMFormatDescriptionExtension_BitsPerComponent as String:
            format.bitsPerComponent
    ]
    if let chromaLocation = format.chromaLocation {
        extensions[
            kCMFormatDescriptionExtension_ChromaLocationTopField as String
        ] = chromaLocation
        extensions[
            kCMFormatDescriptionExtension_ChromaLocationBottomField
                as String
        ] = chromaLocation
    }
    if format.alphaMode != .none {
        extensions[
            kCMFormatDescriptionExtension_ContainsAlphaChannel as String
        ] = true
        extensions[
            kCMFormatDescriptionExtension_AlphaChannelMode as String
        ] = formatDescriptionAlphaMode(format.alphaMode)
        extensions[kCMFormatDescriptionExtension_Depth as String] = 32
    }
    if let mastering = format.masteringDisplayColorVolume {
        extensions[
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume
                as String
        ] = mastering
    }
    if let contentLight = format.contentLightLevelInfo {
        extensions[
            kCMFormatDescriptionExtension_ContentLightLevelInfo as String
        ] = contentLight
    }
    var description: CMFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: format.pixelFormat,
        width: Int32(resolution.width),
        height: Int32(resolution.height),
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw Non420VideoFixtureError
            .formatDescriptionCreationFailed(status)
    }
    return description
}

private func makeNon420FixturePixelBuffer(
    resolution: VideoResolution,
    format: Non420VideoFixtureFormat,
    frameIndex: Int
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        resolution.width,
        resolution.height,
        format.pixelFormat,
        [
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw Non420VideoFixtureError.pixelBufferCreationFailed(status)
    }
    try fillNon420FixturePixelBuffer(
        pixelBuffer,
        frameIndex: frameIndex
    )
    installNon420FixtureAttachments(
        on: pixelBuffer,
        format: format
    )
    return pixelBuffer
}

private func fillNon420FixturePixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard status == kCVReturnSuccess else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        try fillEightBitPlanes(pixelBuffer, frameIndex: frameIndex)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
        try fillSixteenBitPlanes(
            pixelBuffer,
            frameIndex: frameIndex,
            alphaPlaneIndex: nil
        )
    case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
        try fillSixteenBitPlanes(
            pixelBuffer,
            frameIndex: frameIndex,
            alphaPlaneIndex: 2
        )
    case kCVPixelFormatType_4444AYpCbCr8:
        try fillPackedY408(pixelBuffer, frameIndex: frameIndex)
    case kCVPixelFormatType_4444AYpCbCr16:
        try fillPackedY416(pixelBuffer, frameIndex: frameIndex)
    case kCVPixelFormatType_32BGRA:
        try fillPackedBGRA(pixelBuffer, frameIndex: frameIndex)
    default:
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
}

private func fillPackedY408(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard bytesPerRow >= width * 4 else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    for row in 0..<height {
        let bytes = baseAddress
            .advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let offset = column * 4
            bytes[offset] = UInt8(
                96 + ((row + column + frameIndex * 11) & 0x3f)
            )
            bytes[offset + 1] = UInt8(
                48 + ((row + column + frameIndex * 7) & 0x7f)
            )
            bytes[offset + 2] = 112
            bytes[offset + 3] = 144
        }
    }
}

private func fillPackedY416(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard bytesPerRow >= width * 8 else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    for row in 0..<height {
        let words = baseAddress
            .advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt16.self)
        for column in 0..<width {
            let offset = column * 4
            words[offset] = UInt16(
                24_000 + ((row + column + frameIndex * 257) & 0x1fff)
            )
            words[offset + 1] = 16_384
            words[offset + 2] = 28_672
            words[offset + 3] = 36_864
        }
    }
}

private func fillPackedBGRA(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 0,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard bytesPerRow >= width * 4 else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    for row in 0..<height {
        let bytes = baseAddress
            .advanced(by: row * bytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
        for column in 0..<width {
            let offset = column * 4
            bytes[offset] = UInt8(
                (48 + column + frameIndex * 3) & 0xff
            )
            bytes[offset + 1] = UInt8(
                (64 + row + frameIndex * 5) & 0xff
            )
            bytes[offset + 2] = 128
            bytes[offset + 3] = UInt8(
                96 + ((row + column) & 0x7f)
            )
        }
    }
}

private func fillEightBitPlanes(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    for planeIndex in 0..<2 {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            planeIndex
        ) else {
            throw Non420VideoFixtureError.invalidPixelBufferLayout
        }
        let height = CVPixelBufferGetHeightOfPlane(
            pixelBuffer,
            planeIndex
        )
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            planeIndex
        )
        for row in 0..<height {
            let bytes = baseAddress
                .advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<bytesPerRow {
                let base = planeIndex == 0 ? 48 : 112
                bytes[column] = UInt8(
                    (base + row + column + frameIndex * 7) & 0xff
                )
            }
        }
    }
}

private func fillSixteenBitPlanes(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int,
    alphaPlaneIndex: Int?
) throws {
    let expectedPlaneCount = alphaPlaneIndex == nil ? 2 : 3
    guard CVPixelBufferGetPlaneCount(pixelBuffer) == expectedPlaneCount else {
        throw Non420VideoFixtureError.invalidPixelBufferLayout
    }
    for planeIndex in 0..<expectedPlaneCount {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            planeIndex
        ) else {
            throw Non420VideoFixtureError.invalidPixelBufferLayout
        }
        let height = CVPixelBufferGetHeightOfPlane(
            pixelBuffer,
            planeIndex
        )
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(
            pixelBuffer,
            planeIndex
        )
        guard bytesPerRow.isMultiple(of: MemoryLayout<UInt16>.size) else {
            throw Non420VideoFixtureError.invalidPixelBufferLayout
        }
        let wordsPerRow = bytesPerRow / MemoryLayout<UInt16>.size
        for row in 0..<height {
            let words = baseAddress
                .advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            for column in 0..<wordsPerRow {
                if planeIndex == alphaPlaneIndex {
                    words[column] = UInt16(
                        0x4000
                            + ((row + column + frameIndex * 257) & 0x3fff)
                    )
                } else {
                    let tenBitCode = UInt16(
                        (128 + row + column + frameIndex * 13) & 0x03ff
                    )
                    words[column] = tenBitCode << 6
                }
            }
        }
    }
}

private func installNon420FixtureAttachments(
    on pixelBuffer: CVPixelBuffer,
    format: Non420VideoFixtureFormat
) {
    let attachments: [(CFString, Any)] = [
        (kCVImageBufferColorPrimariesKey, format.colorPrimaries),
        (kCVImageBufferTransferFunctionKey, format.transferFunction),
        (kCVImageBufferYCbCrMatrixKey, format.yCbCrMatrix)
    ]
    for (key, value) in attachments {
        CVBufferSetAttachment(
            pixelBuffer,
            key,
            value as CFTypeRef,
            .shouldPropagate
        )
    }
    if let chromaLocation = format.chromaLocation {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            chromaLocation as CFString,
            .shouldPropagate
        )
    }
    if format.alphaMode != .none {
        let alphaMode: CFString = format.alphaMode == .straight
            ? kCVImageBufferAlphaChannelMode_StraightAlpha
            : kCVImageBufferAlphaChannelMode_PremultipliedAlpha
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferAlphaChannelModeKey,
            alphaMode,
            .shouldPropagate
        )
    }
    if let mastering = format.masteringDisplayColorVolume {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            mastering as CFData,
            .shouldPropagate
        )
    }
    if let contentLight = format.contentLightLevelInfo {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferContentLightLevelInfoKey,
            contentLight as CFData,
            .shouldPropagate
        )
    }
}

private func formatDescriptionAlphaMode(
    _ mode: MediaVideoAlphaMode
) -> CFString {
    switch mode {
    case .none:
        preconditionFailure("Alpha mode must be declared.")
    case .straight:
        return kCMFormatDescriptionAlphaChannelMode_StraightAlpha
    case .premultiplied:
        return kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha
    }
}
