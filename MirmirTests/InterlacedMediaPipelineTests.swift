import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox
import XCTest
@testable import Mirmir

// Real-media acceptance intentionally lives in one isolated test file so the
// encoded fixture, independent pixel oracle, pipeline, and publication checks
// remain auditable as one contract.
// swiftlint:disable file_length
final class InterlacedMediaPipelineTests: XCTestCase {
    private let resolution = VideoResolution(width: 32, height: 8)
    private let frameCount = 2
    private let frameDuration = CMTime(value: 1, timescale: 30)

    func testTopFieldFirstProRes422BecomesProgressiveAtomicOutput()
        async throws {
        try await exercisePipeline(fieldOrder: .topFieldFirst)
    }

    func testBottomFieldFirstProRes422BecomesProgressiveAtomicOutput()
        async throws {
        try await exercisePipeline(fieldOrder: .bottomFieldFirst)
    }

    func testUnspecifiedFieldOrderProRes422BecomesProgressiveAtomicOutput()
        async throws {
        try await exercisePipeline(fieldOrder: .unspecified)
    }

    // This is deliberately an end-to-end assertion chain. Splitting it into
    // independent tests could allow a synthetic fixture to pass one boundary
    // while a different file passes another.
    // swiftlint:disable:next function_body_length
    private func exercisePipeline(
        fieldOrder: InterlacedFixtureFieldOrder
    ) async throws {
        let fixture = try InterlacedPipelineFixture(
            fieldOrder: fieldOrder
        )
        defer { fixture.remove() }

        try await writeInterlacedProRes422Fixture(
            to: fixture.source,
            resolution: resolution,
            frameCount: frameCount,
            frameDuration: frameDuration,
            fieldOrder: fieldOrder
        )

        let sourceDescriptions = try await videoFormatDescriptions(
            at: fixture.source
        )
        XCTAssertFalse(sourceDescriptions.isEmpty)
        XCTAssertEqual(
            try MediaVideoScanStructureResolver.resolve(
                sourceDescriptions
            ),
            fieldOrder.scanStructure
        )
        for description in sourceDescriptions {
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(description),
                kCMVideoCodecType_AppleProRes422
            )
            try assertFieldIdentity(
                description,
                expectedFieldCount: 2,
                expectedFieldDetail: fieldOrder.fieldDetail
            )
        }

        let decodedSourceFrames = try await decodeTenBit422Frames(
            at: fixture.source
        )
        XCTAssertEqual(decodedSourceFrames.count, frameCount)
        for frame in decodedSourceFrames {
            XCTAssertTrue(
                frame.hasDistinctFirstTwoLumaRows,
                "The encoded fixture must retain distinct adjacent fields."
            )
        }

        let pipeline = AVFoundationMediaPipeline(
            metal: InterlacedTestMetalRenderingService()
        )
        let source = try await pipeline.probe(url: fixture.source)
        XCTAssertEqual(
            source.scanStructure,
            fieldOrder.scanStructure,
            "Probe must expose the exact encoded field identity."
        )
        XCTAssertEqual(
            source.videoFormat.pixelStorage,
            .yuv422VideoRange10Bit
        )

        let session = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: fixture.destination,
                resolution: resolution,
                codec: .hevc,
                preserveAudio: false,
                transactionIdentifier:
                    "interlaced-\(fieldOrder.rawValue)"
            )
        )
        defer { session.cancel() }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )

        var emittedFrameCount = 0
        while let record = try await session.nextSourceFrame() {
            guard emittedFrameCount < decodedSourceFrames.count else {
                throw InterlacedFixtureError.unexpectedFrameCount(
                    expected: decodedSourceFrames.count,
                    actual: emittedFrameCount + 1
                )
            }
            let expected = decodedSourceFrames[emittedFrameCount]
                .applyingIndependentVerticalFilter()
            let actual = try InterlacedTenBit422Frame(
                pixelBuffer: record.pixelBuffer
            )
            XCTAssertEqual(
                actual,
                expected,
                "Frame \(emittedFrameCount) did not match the independent "
                    + "1/4–1/2–1/4 vertical-filter oracle."
            )
            try assertProgressiveAttachments(on: record.pixelBuffer)
            try await session.appendOutput(
                pixelBuffer: record.pixelBuffer,
                timing: record.timing
            )
            emittedFrameCount += 1
        }
        XCTAssertEqual(emittedFrameCount, decodedSourceFrames.count)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            ),
            "The destination must not exist before verified publication."
        )

        let publication = InterlacedPublicationObservation(
            destination: fixture.destination,
            temporary: session.prepublicationOutputURL
        )
        try await session.finish(
            finalMetadata: [:],
            beforeReopen: {
                await publication.record(.beforeReopen)
            },
            validatingBeforePublish: {
                await publication.record(.afterReopenBeforePublish)
            }
        )

        let snapshots = await publication.snapshots
        XCTAssertEqual(
            snapshots.map(\.phase),
            [.beforeReopen, .afterReopenBeforePublish]
        )
        for snapshot in snapshots {
            XCTAssertFalse(
                snapshot.destinationExists,
                "Destination existed during \(snapshot.phase.rawValue)."
            )
            XCTAssertTrue(
                snapshot.temporaryExists,
                "Verified temporary output was absent during "
                    + "\(snapshot.phase.rawValue)."
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destination.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: session.prepublicationOutputURL.path
            )
        )
        XCTAssertTrue(fixture.partialFiles().isEmpty)

        let publicationIdentity = try XCTUnwrap(
            session.publishedOutputIdentity
        )
        let outputByteCount = try fixture.destination
            .resourceValues(forKeys: [.fileSizeKey])
            .fileSize
        XCTAssertEqual(
            publicationIdentity.byteCount,
            UInt64(try XCTUnwrap(outputByteCount))
        )
        XCTAssertEqual(publicationIdentity.sha256.count, 64)

        let outputDescriptions = try await videoFormatDescriptions(
            at: fixture.destination
        )
        XCTAssertFalse(outputDescriptions.isEmpty)
        XCTAssertEqual(
            try MediaVideoScanStructureResolver.resolve(
                outputDescriptions
            ),
            .progressive
        )
        for description in outputDescriptions {
            XCTAssertEqual(
                CMFormatDescriptionGetMediaSubType(description),
                kCMVideoCodecType_HEVC
            )
            try assertFieldIdentity(
                description,
                expectedFieldCount: 1,
                expectedFieldDetail: nil
            )
        }

        let decodedOutputFrames = try await decodeTenBit422Frames(
            at: fixture.destination
        )
        XCTAssertEqual(decodedOutputFrames.count, frameCount)
    }
}

private enum InterlacedFixtureFieldOrder: String, CaseIterable {
    case topFieldFirst = "top-first"
    case bottomFieldFirst = "bottom-first"
    case unspecified

    var fieldDetail: CFString? {
        switch self {
        case .topFieldFirst:
            return kCMFormatDescriptionFieldDetail_TemporalTopFirst
        case .bottomFieldFirst:
            return kCMFormatDescriptionFieldDetail_TemporalBottomFirst
        case .unspecified:
            return nil
        }
    }

    var scanStructure: MediaVideoScanStructure {
        switch self {
        case .topFieldFirst:
            return .interlacedTopFieldFirst
        case .bottomFieldFirst:
            return .interlacedBottomFieldFirst
        case .unspecified:
            return .interlacedUnspecified
        }
    }
}

private struct InterlacedPipelineFixture {
    let root: URL
    let source: URL
    let destination: URL

    init(fieldOrder: InterlacedFixtureFieldOrder) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirInterlacedMediaPipelineTests",
                isDirectory: true
            )
            .appendingPathComponent(
                "\(fieldOrder.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        source = root.appendingPathComponent("source.mov")
        destination = root.appendingPathComponent("destination.mov")
    }

    func partialFiles() -> [URL] {
        let contents = (
            try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
        ) ?? []
        return contents.filter {
            $0.lastPathComponent.contains(".partial")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum InterlacedFixtureError:
    Error,
    Equatable,
    CustomStringConvertible {
    case destinationExists(URL)
    case writerCannotAddInput
    case writerStartFailed(String)
    case writerAppendFailed(frameIndex: Int, reason: String)
    case writerFailed(String)
    case formatDescriptionCreationFailed(OSStatus)
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferLockFailed(CVReturn)
    case invalidPixelBufferLayout
    case readerCannotAddOutput
    case readerStartFailed(String)
    case readerFailed(String)
    case videoTrackCount(expected: Int, actual: Int)
    case missingVideoFormatDescription
    case missingCompressedSampleData
    case unexpectedCompressedSampleCount(Int)
    case compressedSampleBufferCreationFailed(OSStatus)
    case unexpectedFrameCount(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .destinationExists(let url):
            return "Fixture destination already exists: \(url.path)."
        case .writerCannotAddInput:
            return "Fixture writer cannot add its video input."
        case .writerStartFailed(let reason):
            return "Fixture writer could not start: \(reason)."
        case .writerAppendFailed(let frameIndex, let reason):
            return "Fixture writer rejected frame \(frameIndex): \(reason)."
        case .writerFailed(let reason):
            return "Fixture writer failed: \(reason)."
        case .formatDescriptionCreationFailed(let status):
            return "Fixture format-description creation failed: \(status)."
        case .pixelBufferCreationFailed(let status):
            return "Fixture pixel-buffer creation failed: \(status)."
        case .pixelBufferLockFailed(let status):
            return "Fixture pixel-buffer lock failed: \(status)."
        case .invalidPixelBufferLayout:
            return "Fixture pixel buffer has an invalid x422 layout."
        case .readerCannotAddOutput:
            return "Fixture reader cannot add its x422 output."
        case .readerStartFailed(let reason):
            return "Fixture reader could not start: \(reason)."
        case .readerFailed(let reason):
            return "Fixture reader failed: \(reason)."
        case .videoTrackCount(let expected, let actual):
            return "Expected \(expected) video track; observed \(actual)."
        case .missingVideoFormatDescription:
            return "Video track contains no format description."
        case .missingCompressedSampleData:
            return "Compressed fixture sample contains no data buffer."
        case .unexpectedCompressedSampleCount(let count):
            return "Compressed fixture buffer contains \(count) samples."
        case .compressedSampleBufferCreationFailed(let status):
            return "Compressed fixture sample rewrite failed: \(status)."
        case .unexpectedFrameCount(let expected, let actual):
            return "Expected \(expected) frames; observed \(actual)."
        }
    }
}

private func writeInterlacedProRes422Fixture(
    to url: URL,
    resolution: VideoResolution,
    frameCount: Int,
    frameDuration: CMTime,
    fieldOrder: InterlacedFixtureFieldOrder
) async throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw InterlacedFixtureError.destinationExists(url)
    }
    if fieldOrder == .unspecified {
        let encodedURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                "specified-\(UUID().uuidString).mov"
            )
        defer { try? FileManager.default.removeItem(at: encodedURL) }
        try await writeEncodedInterlacedProRes422Fixture(
            to: encodedURL,
            resolution: resolution,
            frameCount: frameCount,
            frameDuration: frameDuration,
            fieldOrder: .topFieldFirst
        )
        try await remuxWithoutFieldDetail(
            from: encodedURL,
            to: url
        )
        return
    }
    try await writeEncodedInterlacedProRes422Fixture(
        to: url,
        resolution: resolution,
        frameCount: frameCount,
        frameDuration: frameDuration,
        fieldOrder: fieldOrder
    )
}

private func writeEncodedInterlacedProRes422Fixture(
    to url: URL,
    resolution: VideoResolution,
    frameCount: Int,
    frameDuration: CMTime,
    fieldOrder: InterlacedFixtureFieldOrder
) async throws {
    let sourceFormatHint = try makeInterlacedSourceFormatDescription(
        resolution: resolution,
        fieldOrder: fieldOrder
    )
    let writer = try AVAssetWriter(url: url, fileType: .mov)
    writer.movieTimeScale = 600
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: interlacedProRes422OutputSettings(
            resolution: resolution,
            fieldOrder: fieldOrder
        ),
        sourceFormatHint: sourceFormatHint
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: resolution.width,
            kCVPixelBufferHeightKey as String: resolution.height,
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ]
    )
    guard writer.canAdd(input) else {
        throw InterlacedFixtureError.writerCannotAddInput
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw InterlacedFixtureError.writerStartFailed(
            writerFailureReason(writer)
        )
    }
    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status != .failed,
                  writer.status != .cancelled else {
                throw InterlacedFixtureError.writerFailed(
                    writerFailureReason(writer)
                )
            }
            await Task.yield()
        }
        let pixelBuffer = try makeInterlacedFixturePixelBuffer(
            resolution: resolution,
            frameIndex: frameIndex,
            fieldOrder: fieldOrder
        )
        let presentationTime = CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameIndex)
        )
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: presentationTime
        ) else {
            throw InterlacedFixtureError.writerAppendFailed(
                frameIndex: frameIndex,
                reason: writerFailureReason(writer)
            )
        }
    }

    input.markAsFinished()
    writer.endSession(
        atSourceTime: CMTimeMultiply(
            frameDuration,
            multiplier: Int32(frameCount)
        )
    )
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw InterlacedFixtureError.writerFailed(
            writerFailureReason(writer)
        )
    }
}

// VideoToolbox requires a concrete field order to encode two-field ProRes.
// The FieldCount-only fixture is therefore encoded once and then remuxed
// without transcoding. Its compressed format description deliberately removes
// both verbatim-description extensions so the new FieldDetail omission reaches
// the file's sample entry instead of being overridden by the original bytes.
// swiftlint:disable:next function_body_length
private func remuxWithoutFieldDetail(
    from sourceURL: URL,
    to destinationURL: URL
) async throws {
    let asset = AVURLAsset(
        url: sourceURL,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first else {
        throw InterlacedFixtureError.videoTrackCount(
            expected: 1,
            actual: tracks.count
        )
    }
    let descriptions = try await track.load(.formatDescriptions)
    guard let sourceDescription = descriptions.first else {
        throw InterlacedFixtureError.missingVideoFormatDescription
    }
    let fieldCountOnlyDescription = try makeFieldCountOnlyDescription(
        from: sourceDescription
    )
    let duration = try await asset.load(.duration)

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: nil
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw InterlacedFixtureError.readerCannotAddOutput
    }
    reader.add(output)

    let writer = try AVAssetWriter(
        url: destinationURL,
        fileType: .mov
    )
    writer.movieTimeScale = 600
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: nil,
        sourceFormatHint: fieldCountOnlyDescription
    )
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 600
    guard writer.canAdd(input) else {
        throw InterlacedFixtureError.writerCannotAddInput
    }
    writer.add(input)
    guard reader.startReading() else {
        throw InterlacedFixtureError.readerStartFailed(
            reader.error.map(String.init(describing:)) ?? "unknown"
        )
    }
    guard writer.startWriting() else {
        throw InterlacedFixtureError.writerStartFailed(
            writerFailureReason(writer)
        )
    }
    writer.startSession(atSourceTime: .zero)

    var frameIndex = 0
    while let sample = output.copyNextSampleBuffer() {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        guard sampleCount > 0 else {
            continue
        }
        guard sampleCount == 1 else {
            throw InterlacedFixtureError
                .unexpectedCompressedSampleCount(sampleCount)
        }
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status != .failed,
                  writer.status != .cancelled else {
                throw InterlacedFixtureError.writerFailed(
                    writerFailureReason(writer)
                )
            }
            await Task.yield()
        }
        let rewritten = try rewriteCompressedSample(
            sample,
            formatDescription: fieldCountOnlyDescription
        )
        guard input.append(rewritten) else {
            throw InterlacedFixtureError.writerAppendFailed(
                frameIndex: frameIndex,
                reason: writerFailureReason(writer)
            )
        }
        frameIndex += 1
    }
    guard reader.status == .completed else {
        throw InterlacedFixtureError.readerFailed(
            reader.error.map(String.init(describing:))
                ?? "status \(reader.status.rawValue)"
        )
    }

    input.markAsFinished()
    writer.endSession(atSourceTime: duration)
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw InterlacedFixtureError.writerFailed(
            writerFailureReason(writer)
        )
    }
}

private func makeFieldCountOnlyDescription(
    from source: CMVideoFormatDescription
) throws -> CMVideoFormatDescription {
    guard let sourceExtensions = CMFormatDescriptionGetExtensions(
        source
    ) else {
        throw InterlacedFixtureError.missingVideoFormatDescription
    }
    let extensions = (sourceExtensions as NSDictionary)
        .mutableCopy() as? NSMutableDictionary
    guard let extensions else {
        throw InterlacedFixtureError.missingVideoFormatDescription
    }
    extensions.removeObject(
        forKey: kCMFormatDescriptionExtension_FieldDetail as String
    )
    extensions.removeObject(
        forKey:
            kCMFormatDescriptionExtension_VerbatimSampleDescription
                as String
    )
    extensions.removeObject(
        forKey:
            kCMFormatDescriptionExtension_VerbatimISOSampleEntry
                as String
    )
    extensions[
        kCMFormatDescriptionExtension_FieldCount as String
    ] = NSNumber(value: 2)

    let dimensions = CMVideoFormatDescriptionGetDimensions(source)
    var result: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: CMFormatDescriptionGetMediaSubType(source),
        width: dimensions.width,
        height: dimensions.height,
        extensions: extensions,
        formatDescriptionOut: &result
    )
    guard status == noErr, let result else {
        throw InterlacedFixtureError
            .formatDescriptionCreationFailed(status)
    }
    return result
}

private func rewriteCompressedSample(
    _ source: CMSampleBuffer,
    formatDescription: CMVideoFormatDescription
) throws -> CMSampleBuffer {
    guard let dataBuffer = CMSampleBufferGetDataBuffer(source) else {
        throw InterlacedFixtureError.missingCompressedSampleData
    }
    var timing = CMSampleTimingInfo(
        duration: CMSampleBufferGetDuration(source),
        presentationTimeStamp:
            CMSampleBufferGetPresentationTimeStamp(source),
        decodeTimeStamp:
            CMSampleBufferGetDecodeTimeStamp(source)
    )
    var sampleSize = CMSampleBufferGetTotalSampleSize(source)
    var result: CMSampleBuffer?
    let status = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: dataBuffer,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &result
    )
    guard status == noErr, let result else {
        throw InterlacedFixtureError
            .compressedSampleBufferCreationFailed(status)
    }
    return result
}

private func interlacedProRes422OutputSettings(
    resolution: VideoResolution,
    fieldOrder: InterlacedFixtureFieldOrder
) -> [String: Any] {
    var compressionProperties: [String: Any] = [
        kVTCompressionPropertyKey_FieldCount as String:
            NSNumber(value: 2)
    ]
    if let fieldDetail = fieldOrder.fieldDetail {
        compressionProperties[
            kVTCompressionPropertyKey_FieldDetail as String
        ] = fieldDetail
    }
    return [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoWidthKey: resolution.width,
        AVVideoHeightKey: resolution.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey:
                AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey:
                AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey:
                AVVideoYCbCrMatrix_ITU_R_709_2
        ],
        AVVideoCompressionPropertiesKey: compressionProperties
    ]
}

private func makeInterlacedSourceFormatDescription(
    resolution: VideoResolution,
    fieldOrder: InterlacedFixtureFieldOrder
) throws -> CMVideoFormatDescription {
    var extensions: [String: Any] = [
        kCMFormatDescriptionExtension_ColorPrimaries as String:
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        kCMFormatDescriptionExtension_TransferFunction as String:
            kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        kCMFormatDescriptionExtension_YCbCrMatrix as String:
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        kCMFormatDescriptionExtension_FullRangeVideo as String: false,
        kCMFormatDescriptionExtension_BitsPerComponent as String:
            NSNumber(value: 10),
        kCMFormatDescriptionExtension_ChromaLocationTopField as String:
            kCMFormatDescriptionChromaLocation_Left,
        kCMFormatDescriptionExtension_ChromaLocationBottomField as String:
            kCMFormatDescriptionChromaLocation_Left,
        kCMFormatDescriptionExtension_FieldCount as String:
            NSNumber(value: 2)
    ]
    if let fieldDetail = fieldOrder.fieldDetail {
        extensions[
            kCMFormatDescriptionExtension_FieldDetail as String
        ] = fieldDetail
    }
    var description: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType:
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        width: Int32(resolution.width),
        height: Int32(resolution.height),
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &description
    )
    guard status == noErr, let description else {
        throw InterlacedFixtureError
            .formatDescriptionCreationFailed(status)
    }
    return description
}

private func makeInterlacedFixturePixelBuffer(
    resolution: VideoResolution,
    frameIndex: Int,
    fieldOrder: InterlacedFixtureFieldOrder
) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        resolution.width,
        resolution.height,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        [
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw InterlacedFixtureError.pixelBufferCreationFailed(
            status
        )
    }
    try fillInterlacedFixturePixelBuffer(
        pixelBuffer,
        frameIndex: frameIndex
    )
    installInterlacedFixtureAttachments(
        on: pixelBuffer,
        fieldOrder: fieldOrder
    )
    return pixelBuffer
}

private func fillInterlacedFixturePixelBuffer(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    let lockStatus = CVPixelBufferLockBaseAddress(
        pixelBuffer,
        []
    )
    guard lockStatus == kCVReturnSuccess else {
        throw InterlacedFixtureError.pixelBufferLockFailed(
            lockStatus
        )
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
        throw InterlacedFixtureError.invalidPixelBufferLayout
    }
    try fillInterlacedLuma(
        pixelBuffer,
        frameIndex: frameIndex
    )
    try fillInterlacedChroma(
        pixelBuffer,
        frameIndex: frameIndex
    )
}

private func fillInterlacedLuma(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard let base = CVPixelBufferGetBaseAddressOfPlane(
        pixelBuffer,
        0
    ) else {
        throw InterlacedFixtureError.invalidPixelBufferLayout
    }
    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(
        pixelBuffer,
        0
    ) / MemoryLayout<UInt16>.size
    for row in 0..<height {
        let output = base.assumingMemoryBound(to: UInt16.self)
            .advanced(by: row * stride)
        for column in 0..<width {
            let baseCode = row.isMultiple(of: 2) ? 144 : 824
            let code = baseCode + frameIndex * 9 + column % 17
            output[column] = UInt16(code << 6)
        }
    }
}

private func fillInterlacedChroma(
    _ pixelBuffer: CVPixelBuffer,
    frameIndex: Int
) throws {
    guard let base = CVPixelBufferGetBaseAddressOfPlane(
        pixelBuffer,
        1
    ) else {
        throw InterlacedFixtureError.invalidPixelBufferLayout
    }
    let sampleWidth = CVPixelBufferGetWidthOfPlane(
        pixelBuffer,
        1
    )
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(
        pixelBuffer,
        1
    ) / MemoryLayout<UInt16>.size
    for row in 0..<height {
        let output = base.assumingMemoryBound(to: UInt16.self)
            .advanced(by: row * stride)
        for sample in 0..<sampleWidth {
            let evenField = row.isMultiple(of: 2)
            let cbBase = evenField ? 224 : 784
            let crBase = evenField ? 304 : 704
            output[sample * 2] = UInt16(
                (cbBase + frameIndex * 7 + sample % 11) << 6
            )
            output[sample * 2 + 1] = UInt16(
                (crBase + frameIndex * 5 + sample % 13) << 6
            )
        }
    }
}

private func installInterlacedFixtureAttachments(
    on pixelBuffer: CVPixelBuffer,
    fieldOrder: InterlacedFixtureFieldOrder
) {
    var attachments: [(CFString, Any)] = [
        (
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2
        ),
        (
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2
        ),
        (
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ),
        (
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left
        ),
        (
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Left
        ),
        (kCVImageBufferFieldCountKey, NSNumber(value: 2))
    ]
    if let fieldDetail = fieldOrder.fieldDetail {
        attachments.append(
            (kCVImageBufferFieldDetailKey, fieldDetail)
        )
    }
    for (key, value) in attachments {
        CVBufferSetAttachment(
            pixelBuffer,
            key,
            value as CFTypeRef,
            .shouldPropagate
        )
    }
}

private struct InterlacedTenBit422Frame: Equatable {
    struct Plane: Equatable {
        let componentCount: Int
        let rows: [[UInt16]]
    }

    let width: Int
    let height: Int
    let planes: [Plane]

    init(pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw InterlacedFixtureError.invalidPixelBufferLayout
        }
        let lockStatus = CVPixelBufferLockBaseAddress(
            pixelBuffer,
            .readOnly
        )
        guard lockStatus == kCVReturnSuccess else {
            throw InterlacedFixtureError.pixelBufferLockFailed(
                lockStatus
            )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        var capturedPlanes: [Plane] = []
        for planeIndex in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                planeIndex
            ) else {
                throw InterlacedFixtureError.invalidPixelBufferLayout
            }
            let sampleWidth = CVPixelBufferGetWidthOfPlane(
                pixelBuffer,
                planeIndex
            )
            let componentCount = sampleWidth
                * (planeIndex == 0 ? 1 : 2)
            let rowCount = CVPixelBufferGetHeightOfPlane(
                pixelBuffer,
                planeIndex
            )
            let stride = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                planeIndex
            ) / MemoryLayout<UInt16>.size
            var rows: [[UInt16]] = []
            for row in 0..<rowCount {
                let source = base.assumingMemoryBound(
                    to: UInt16.self
                ).advanced(by: row * stride)
                rows.append(
                    (0..<componentCount).map { source[$0] }
                )
            }
            capturedPlanes.append(
                Plane(
                    componentCount: componentCount,
                    rows: rows
                )
            )
        }
        planes = capturedPlanes
    }

    private init(
        width: Int,
        height: Int,
        planes: [Plane]
    ) {
        self.width = width
        self.height = height
        self.planes = planes
    }

    var hasDistinctFirstTwoLumaRows: Bool {
        guard let luma = planes.first,
              luma.rows.count >= 2 else {
            return false
        }
        return luma.rows[0] != luma.rows[1]
    }

    func applyingIndependentVerticalFilter()
        -> InterlacedTenBit422Frame {
        let filteredPlanes = planes.enumerated().map { planeIndex, plane in
            let minimum = UInt64(64)
            let maximum = UInt64(
                planeIndex == 0 ? 940 : 960
            )
            let filteredRows = plane.rows.indices.map { row in
                let north = plane.rows[max(row - 1, 0)]
                let center = plane.rows[row]
                let south = plane.rows[
                    min(row + 1, plane.rows.count - 1)
                ]
                return (0..<plane.componentCount).map { component in
                    let northCode = UInt64(
                        north[component] >> 6
                    )
                    let centerCode = UInt64(
                        center[component] >> 6
                    )
                    let southCode = UInt64(
                        south[component] >> 6
                    )
                    let filtered = (
                        northCode
                            + centerCode * 2
                            + southCode
                            + 2
                    ) / 4
                    let bounded = min(
                        max(filtered, minimum),
                        maximum
                    )
                    return UInt16(bounded) << 6
                }
            }
            return Plane(
                componentCount: plane.componentCount,
                rows: filteredRows
            )
        }
        return InterlacedTenBit422Frame(
            width: width,
            height: height,
            planes: filteredPlanes
        )
    }
}

private func decodeTenBit422Frames(
    at url: URL
) async throws -> [InterlacedTenBit422Frame] {
    let asset = AVURLAsset(
        url: url,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first else {
        throw InterlacedFixtureError.videoTrackCount(
            expected: 1,
            actual: tracks.count
        )
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw InterlacedFixtureError.readerCannotAddOutput
    }
    reader.add(output)
    guard reader.startReading() else {
        throw InterlacedFixtureError.readerStartFailed(
            reader.error.map(String.init(describing:)) ?? "unknown"
        )
    }
    var frames: [InterlacedTenBit422Frame] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(
            sample
        ) else {
            continue
        }
        frames.append(
            try InterlacedTenBit422Frame(
                pixelBuffer: imageBuffer
            )
        )
    }
    guard reader.status == .completed else {
        throw InterlacedFixtureError.readerFailed(
            reader.error.map(String.init(describing:))
                ?? "status \(reader.status.rawValue)"
        )
    }
    return frames
}

private func videoFormatDescriptions(
    at url: URL
) async throws -> [CMFormatDescription] {
    let asset = AVURLAsset(
        url: url,
        options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ]
    )
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard tracks.count == 1, let track = tracks.first else {
        throw InterlacedFixtureError.videoTrackCount(
            expected: 1,
            actual: tracks.count
        )
    }
    let descriptions = try await track.load(.formatDescriptions)
    guard !descriptions.isEmpty else {
        throw InterlacedFixtureError.missingVideoFormatDescription
    }
    return descriptions
}

private func assertFieldIdentity(
    _ description: CMFormatDescription,
    expectedFieldCount: Int,
    expectedFieldDetail: CFString?
) throws {
    let extensions = (
        CMFormatDescriptionGetExtensions(description)
            as NSDictionary?
    ) ?? [:]
    XCTAssertEqual(
        (
            extensions[
                kCMFormatDescriptionExtension_FieldCount as String
            ] as? NSNumber
        )?.intValue,
        expectedFieldCount
    )
    let actualDetail = extensions[
        kCMFormatDescriptionExtension_FieldDetail as String
    ] as? String
    XCTAssertEqual(
        actualDetail,
        expectedFieldDetail.map { $0 as String }
    )
}

private func assertProgressiveAttachments(
    on pixelBuffer: CVPixelBuffer
) throws {
    XCTAssertEqual(
        CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferFieldCountKey,
            nil
        ) as? NSNumber,
        NSNumber(value: 1)
    )
    XCTAssertNil(
        CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferFieldDetailKey,
            nil
        )
    )
    XCTAssertNil(
        CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationBottomFieldKey,
            nil
        )
    )
}

private func writerFailureReason(
    _ writer: AVAssetWriter
) -> String {
    writer.error.map(String.init(describing:))
        ?? "status \(writer.status.rawValue)"
}

private actor InterlacedPublicationObservation {
    enum Phase: String, Equatable, Sendable {
        case beforeReopen = "before-reopen"
        case afterReopenBeforePublish =
            "after-reopen-before-publish"
    }

    struct Snapshot: Equatable, Sendable {
        let phase: Phase
        let destinationExists: Bool
        let temporaryExists: Bool
    }

    let destination: URL
    let temporary: URL
    private(set) var snapshots: [Snapshot] = []

    init(destination: URL, temporary: URL) {
        self.destination = destination
        self.temporary = temporary
    }

    func record(_ phase: Phase) {
        snapshots.append(
            Snapshot(
                phase: phase,
                destinationExists:
                    FileManager.default.fileExists(
                        atPath: destination.path
                    ),
                temporaryExists:
                    FileManager.default.fileExists(
                        atPath: temporary.path
                    )
            )
        )
    }
}

private final class InterlacedTestMetalRenderingService:
    MetalRenderingService,
    @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Interlaced media tests require a Metal-capable Mac.")
        }
        var optionalCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &optionalCache
        )
        guard status == kCVReturnSuccess,
              let textureCache = optionalCache else {
            fatalError(
                "Interlaced media test Metal cache creation failed: "
                    + "\(status)."
            )
        }
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
    }

    func start() throws {}
    func stop() {}
}
