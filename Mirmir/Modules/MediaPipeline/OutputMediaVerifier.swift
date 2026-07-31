import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

private final class OutputMediaReaderCancellation: @unchecked Sendable {
    private let reader: AVAssetReader

    init(reader: AVAssetReader) {
        self.reader = reader
    }

    func cancel() {
        reader.cancelReading()
    }
}

struct OutputMediaVerifier: OutputMediaVerifying {
    private struct ReopenedOutput {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let duration: CMTime
        let trackTimeRange: CMTimeRange
        let codec: String
        let resolution: VideoResolution
        let scanStructure: MediaVideoScanStructure
    }

    private struct DecodedOutput {
        private(set) var frameCount = 0
        private(set) var lumaPayloadBytes = 0
        private(set) var chromaPayloadBytes = 0
        private(set) var alphaPayloadBytes = 0

        mutating func record(
            sample: CMSampleBuffer,
            actualDuration: CMTime,
            expectation: OutputMediaVerificationExpectation
        ) throws {
            guard frameCount < expectation.timing.frames.count else {
                throw OutputMediaVerificationError.frameCountMismatch(
                    expected: expectation.timing.frames.count,
                    actual: frameCount + 1
                )
            }
            try OutputMediaVerifier.verifyTiming(
                sample: sample,
                actualDuration: actualDuration,
                expected: expectation.timing.frames[frameCount]
            )
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw OutputMediaVerificationError.missingDecodedImage(frameIndex: frameCount)
            }
            let payload = try OutputMediaVerifier.verifyPlanes(
                pixelBuffer: pixelBuffer,
                frameIndex: frameCount,
                resolution: expectation.resolution,
                colorExpectation: expectation.videoColor
            )
            lumaPayloadBytes += payload.luma
            chromaPayloadBytes += payload.chroma
            alphaPayloadBytes += payload.alpha
            frameCount += 1
        }
    }

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        try await verify(
            url: url,
            expectation: expectation,
            cancellationCheck: {
                try Task.checkCancellation()
            }
        )
    }

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaVerificationResult {
        try cancellationCheck()
        guard expectation.timing.frameCount > 0,
              let expectedVideoEndTime = expectation.timing.sessionEndTime else {
            throw OutputMediaVerificationError.emptyTimingLedger
        }
        guard expectation.compressedAACIdentity == nil
                || expectation.compressedAACTrackIdentities == nil else {
            throw OutputMediaVerificationError.compressedAACMismatch(
                reason: "verification expectation combines legacy "
                    + "single-track and ordered multi-track AAC identities"
            )
        }
        var expectedMediaEndTime = expectedVideoEndTime
        if let expectedTracks =
                expectation.compressedAACTrackIdentities {
            for track in expectedTracks {
                let audioEndTime = CMTimeRangeGetEnd(
                    track.compressedIdentity.trackTimeRange
                )
                if CMTimeCompare(
                    audioEndTime,
                    expectedMediaEndTime
                ) > 0 {
                    expectedMediaEndTime = audioEndTime
                }
            }
        } else if let expectedAAC =
                    expectation.compressedAACIdentity {
            let audioEndTime = CMTimeRangeGetEnd(expectedAAC.trackTimeRange)
            if CMTimeCompare(audioEndTime, expectedMediaEndTime) > 0 {
                expectedMediaEndTime = audioEndTime
            }
        }
        if let mediaPreservation = expectation.mediaPreservation {
            for track in mediaPreservation.tracks {
                let trackEndTime = CMTimeRangeGetEnd(track.timeRange)
                if CMTimeCompare(
                    trackEndTime,
                    expectedMediaEndTime
                ) > 0 {
                    expectedMediaEndTime = trackEndTime
                }
            }
        }
        let reopened = try await Self.reopen(
            url: url,
            expectation: expectation,
            cancellationCheck: cancellationCheck
        )
        let decoded = try await Self.decodeFrames(
            reopened: reopened,
            expectation: expectation,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        try Self.verifyDurations(
            reopened: reopened,
            expectedVideoEndTime: expectedVideoEndTime,
            expectedMediaEndTime: expectedMediaEndTime
        )
        let mirmirMetadataTrackID = try await Self.verifyTimedMetadata(
            asset: reopened.asset,
            expected: expectation.timedMetadata,
            expectedEndTime: expectedVideoEndTime,
            cancellationCheck: cancellationCheck
        )
        if let mediaPreservation = expectation.mediaPreservation {
            try await Self.verifyMediaPreservation(
                asset: reopened.asset,
                expected: mediaPreservation,
                mirmirMetadataTrackID: mirmirMetadataTrackID,
                cancellationCheck: cancellationCheck
            )
        }
        if let expectedTracks =
                expectation.compressedAACTrackIdentities {
            try cancellationCheck()
            let actualTracks =
                try await OutputMediaAACIdentityReader.readTracks(
                    asset: reopened.asset,
                    references: expectedTracks.map(\.reference),
                    cancellationCheck: cancellationCheck
                )
            try cancellationCheck()
            try Self.verifyCompressedAACTracks(
                actualTracks,
                expected: expectedTracks
            )
        } else if let expectedAAC =
                    expectation.compressedAACIdentity {
            try cancellationCheck()
            let actualAAC = try await OutputMediaAACIdentityReader.read(
                asset: reopened.asset,
                cancellationCheck: cancellationCheck
            )
            try cancellationCheck()
            try Self.verifyCompressedAAC(actualAAC, expected: expectedAAC)
        }
        try cancellationCheck()

        return OutputMediaVerificationResult(
            codec: reopened.codec,
            resolution: reopened.resolution,
            scanStructure: reopened.scanStructure,
            frameCount: decoded.frameCount,
            duration: reopened.duration,
            lumaPayloadBytes: decoded.lumaPayloadBytes,
            chromaPayloadBytes: decoded.chromaPayloadBytes,
            alphaPayloadBytes: decoded.alphaPayloadBytes
        )
    }
}

private extension OutputMediaVerifier {
    private static func reopen(
        url: URL,
        expectation: OutputMediaVerificationExpectation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> ReopenedOutput {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        do {
            try cancellationCheck()
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            try cancellationCheck()
            let expectedVideoTrackCount =
                expectation.mediaPreservation?.expectedTrackCounts[
                    AVMediaType.video.rawValue,
                    default: 1
                ] ?? 1
            guard videoTracks.count == expectedVideoTrackCount,
                  let videoTrack = videoTracks.first else {
                throw OutputMediaVerificationError.videoTrackCount(
                    expected: expectedVideoTrackCount,
                    actual: videoTracks.count
                )
            }
            let trackFormats = try await videoTrack.load(.formatDescriptions)
            try cancellationCheck()
            guard let videoFormat = trackFormats.first else {
                throw OutputMediaVerificationError.missingVideoFormatDescription
            }
            let scanStructure: MediaVideoScanStructure
            do {
                scanStructure =
                    try MediaVideoScanStructureResolver.resolve(
                        trackFormats
                    )
            } catch {
                throw OutputMediaVerificationError.reopenFailed(
                    "output scan structure is invalid: "
                        + String(describing: error)
                )
            }
            guard scanStructure == expectation.scanStructure else {
                throw OutputMediaVerificationError
                    .scanStructureMismatch(
                        expected: expectation.scanStructure,
                        actual: scanStructure
                    )
            }
            if expectation.requiresExplicitScanStructure {
                try verifyExplicitScanStructure(
                    trackFormats,
                    expected: expectation.scanStructure
                )
            }
            let codec = fourCCString(CMFormatDescriptionGetMediaSubType(videoFormat))
            let expectedCodec = codecIdentifier(expectation.codec)
            guard codec == expectedCodec else {
                throw OutputMediaVerificationError.codecMismatch(
                    expected: expectedCodec,
                    actual: codec
                )
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormat)
            let resolution = VideoResolution(
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
            guard resolution == expectation.resolution else {
                throw OutputMediaVerificationError.dimensionsMismatch(
                    expected: expectation.resolution,
                    actual: resolution
                )
            }
            if let expectedTransform = expectation.preferredTransform {
                let actualTransform = try await videoTrack.load(
                    .preferredTransform
                )
                try cancellationCheck()
                guard transformsMatch(
                    expectedTransform,
                    actualTransform
                ) else {
                    throw OutputMediaVerificationError
                        .preferredTransformMismatch(
                            expected: expectedTransform,
                            actual: actualTransform
                        )
                }
            }
            if let expectedColor = expectation.videoColor {
                try verifyVideoColor(
                    formatDescription: videoFormat,
                    expected: expectedColor
                )
            }
            let duration = try await asset.load(.duration)
            try cancellationCheck()
            let trackTimeRange = try await videoTrack.load(.timeRange)
            try cancellationCheck()
            return ReopenedOutput(
                asset: asset,
                videoTrack: videoTrack,
                duration: duration,
                trackTimeRange: trackTimeRange,
                codec: codec,
                resolution: resolution,
                scanStructure: scanStructure
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OutputMediaVerificationError {
            throw error
        } catch {
            throw OutputMediaVerificationError.reopenFailed(String(describing: error))
        }
    }

    private static func verifyExplicitScanStructure(
        _ formatDescriptions: [CMFormatDescription],
        expected: MediaVideoScanStructure
    ) throws {
        for description in formatDescriptions {
            let extensions = (
                CMFormatDescriptionGetExtensions(description)
                    as NSDictionary?
            ) ?? [:]
            guard let fieldCount = extensions[
                kCMFormatDescriptionExtension_FieldCount as String
            ] as? NSNumber else {
                throw OutputMediaVerificationError.reopenFailed(
                    "output format description omits required explicit "
                        + "FieldCount"
                )
            }
            let expectedFieldCount =
                expected == .progressive ? 1 : 2
            guard fieldCount.intValue == expectedFieldCount else {
                throw OutputMediaVerificationError.reopenFailed(
                    "output format description FieldCount "
                        + "\(fieldCount.intValue) differs from required "
                        + "\(expectedFieldCount)"
                )
            }
            let actualDetail = extensions[
                kCMFormatDescriptionExtension_FieldDetail as String
            ] as? String
            let expectedDetail: String?
            switch expected {
            case .progressive, .interlacedUnspecified:
                expectedDetail = nil
            case .interlacedTopFieldFirst:
                expectedDetail =
                    kCMFormatDescriptionFieldDetail_TemporalTopFirst
                        as String
            case .interlacedBottomFieldFirst:
                expectedDetail =
                    kCMFormatDescriptionFieldDetail_TemporalBottomFirst
                        as String
            case .interlacedSpatialFirstLineEarly:
                expectedDetail =
                    kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly
                        as String
            case .interlacedSpatialFirstLineLate:
                expectedDetail =
                    kCMFormatDescriptionFieldDetail_SpatialFirstLineLate
                        as String
            }
            guard actualDetail == expectedDetail else {
                throw OutputMediaVerificationError.reopenFailed(
                    "output format description FieldDetail "
                        + "\(actualDetail ?? "missing") differs from "
                        + "\(expectedDetail ?? "required absence")"
                )
            }
        }
    }

    private static func decodeFrames(
        reopened: ReopenedOutput,
        expectation: OutputMediaVerificationExpectation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> DecodedOutput {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: reopened.asset)
        } catch {
            throw OutputMediaVerificationError.readerCreationFailed(String(describing: error))
        }
        let requestedPixelFormat = expectation.videoColor?.pixelFormat
            ?? PixelBufferBridge.preferredFormat
        let output = AVAssetReaderTrackOutput(
            track: reopened.videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    requestedPixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OutputMediaVerificationError.readerCreationFailed(
                "reader rejected decoded pixel format "
                    + "\(requestedPixelFormat)"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OutputMediaVerificationError.readerStartFailed(
                reader.error.map(String.init(describing:)) ?? "unknown"
            )
        }

        let cancellation = OutputMediaReaderCancellation(reader: reader)
        return try await withTaskCancellationHandler {
            do {
                try cancellationCheck()
                var result = DecodedOutput()
                var currentSample = output.copyNextSampleBuffer()
                try cancellationCheck()
                let trackEnd = CMTimeRangeGetEnd(reopened.trackTimeRange)
                while let sample = currentSample {
                    try cancellationCheck()
                    currentSample = try autoreleasepool {
                        let nextSample = output.copyNextSampleBuffer()
                        try cancellationCheck()
                        let actualDuration = FrameTiming.resolveDuration(
                            sampleDuration: CMSampleBufferGetDuration(sample),
                            presentationTime: CMSampleBufferGetPresentationTimeStamp(
                                sample
                            ),
                            nextPresentationTime: nextSample.map {
                                CMSampleBufferGetPresentationTimeStamp($0)
                            },
                            timelineEnd: trackEnd
                        )
                        try result.record(
                            sample: sample,
                            actualDuration: actualDuration,
                            expectation: expectation
                        )
                        return nextSample
                    }
                }
                try cancellationCheck()
                guard reader.status == .completed else {
                    throw OutputMediaVerificationError.readerFailed(
                        reader.error.map(String.init(describing:))
                            ?? "status \(reader.status.rawValue)"
                    )
                }
                guard result.frameCount == expectation.timing.frameCount else {
                    throw OutputMediaVerificationError.frameCountMismatch(
                        expected: expectation.timing.frameCount,
                        actual: result.frameCount
                    )
                }
                return result
            } catch is CancellationError {
                cancellation.cancel()
                throw CancellationError()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func verifyDurations(
        reopened: ReopenedOutput,
        expectedVideoEndTime: CMTime,
        expectedMediaEndTime: CMTime
    ) throws {
        guard CMTimeCompare(
            reopened.duration,
            expectedMediaEndTime
        ) == 0 else {
            throw OutputMediaVerificationError.mediaDurationMismatch(
                expected: expectedMediaEndTime,
                actual: reopened.duration
            )
        }
        let trackEnd = CMTimeRangeGetEnd(reopened.trackTimeRange)
        guard CMTimeCompare(trackEnd, expectedVideoEndTime) == 0 else {
            throw OutputMediaVerificationError.trackEndMismatch(
                expected: expectedVideoEndTime,
                actual: trackEnd
            )
        }
    }

    private static func verifyTimedMetadata(
        asset: AVURLAsset,
        expected: [String: String],
        expectedEndTime: CMTime,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> CMPersistentTrackID? {
        guard !expected.isEmpty else { return nil }
        try cancellationCheck()
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        try cancellationCheck()
        let expectedIdentifiers = Set(
            expected.keys.map { "mdta/\($0)" }
        )
        var matchingTracks: [AVAssetTrack] = []
        for track in tracks {
            try cancellationCheck()
            let formatDescriptions = try await track.load(
                .formatDescriptions
            )
            let identifiers = Set(formatDescriptions.flatMap { description in
                (
                    CMMetadataFormatDescriptionGetIdentifiers(description)
                        as? [String]
                ) ?? []
            })
            if identifiers == expectedIdentifiers {
                matchingTracks.append(track)
            }
        }
        guard matchingTracks.count == 1,
              let track = matchingTracks.first else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed ASH identity",
                reason: "expected one track with identifiers "
                    + "\(expectedIdentifiers.sorted()), observed "
                    + "\(matchingTracks.count) exact matches among "
                    + "\(tracks.count) metadata tracks"
            )
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed ASH identity",
                reason: "reader creation failed: \(error)"
            )
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "reader rejected the metadata track"
            )
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(
            assetReaderTrackOutput: output
        )
        guard reader.startReading() else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: reader.error.map(String.init(describing:))
                    ?? "reader did not start"
            )
        }
        let cancellation = OutputMediaReaderCancellation(reader: reader)
        try await withTaskCancellationHandler {
            do {
                var groupCount = 0
                var firstGroup: AVTimedMetadataGroup?
                while true {
                    try cancellationCheck()
                    guard let group = adaptor.nextTimedMetadataGroup() else {
                        break
                    }
                    groupCount += 1
                    if firstGroup == nil {
                        firstGroup = group
                    }
                }
                try cancellationCheck()
                guard reader.status == .completed else {
                    throw OutputMediaVerificationError.metadataMismatch(
                        scope: "timed Mirmir identity",
                        reason: reader.error.map(String.init(describing:))
                            ?? "reader status \(reader.status.rawValue)"
                    )
                }
                guard groupCount == 1, let group = firstGroup else {
                    throw OutputMediaVerificationError.metadataMismatch(
                        scope: "timed Mirmir identity",
                        reason: "expected one group, observed \(groupCount)"
                    )
                }
                guard CMTimeCompare(group.timeRange.start, .zero) == 0,
                      CMTimeCompare(
                        CMTimeRangeGetEnd(group.timeRange),
                        expectedEndTime
                      ) == 0 else {
                    throw OutputMediaVerificationError.metadataMismatch(
                        scope: "timed Mirmir identity",
                        reason: "group time range does not span the completed video"
                    )
                }
                try await verifyMetadataItems(
                    group.items,
                    expected: expected,
                    scope: "timed Mirmir identity",
                    cancellationCheck: cancellationCheck
                )
            } catch is CancellationError {
                cancellation.cancel()
                throw CancellationError()
            }
        } onCancel: {
            cancellation.cancel()
        }
        return track.trackID
    }

    private static func verifyMetadataItems(
        _ items: [AVMetadataItem],
        expected: [String: String],
        scope: String,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        guard !expected.isEmpty else { return }
        var observed: [String: String] = [:]
        for item in items {
            try cancellationCheck()
            guard let key = metadataKey(item),
                  MirmirTimedMetadataPolicy.isValidKey(key) else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: scope,
                    reason: "metadata item has an invalid or foreign key"
                )
            }
            guard observed[key] == nil else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: scope,
                    reason: "duplicate key \(key)"
                )
            }
            guard let value = try await item.load(.stringValue), !value.isEmpty else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: scope,
                    reason: "key \(key) has no UTF-8 string value"
                )
            }
            try cancellationCheck()
            observed[key] = value
        }
        guard observed == expected else {
            let missing = Set(expected.keys).subtracting(observed.keys).sorted()
            let additional = Set(observed.keys).subtracting(expected.keys).sorted()
            let changed = expected.keys.filter {
                observed[$0] != nil && observed[$0] != expected[$0]
            }.sorted()
            throw OutputMediaVerificationError.metadataMismatch(
                scope: scope,
                reason: "missing=\(missing), additional=\(additional), changed=\(changed)"
            )
        }
    }

    private static func metadataKey(_ item: AVMetadataItem) -> String? {
        if let value = item.key as? String { return value }
        if let value = item.key as? NSString { return value as String }
        return nil
    }

    private static func verifyTiming(
        sample: CMSampleBuffer,
        actualDuration: CMTime,
        expected: FrameTiming
    ) throws {
        let actualPresentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        guard CMTimeCompare(actualPresentationTime, expected.presentationTime) == 0 else {
            throw OutputMediaVerificationError.presentationTimeMismatch(
                frameIndex: expected.frameIndex,
                expected: expected.presentationTime,
                actual: actualPresentationTime
            )
        }
        guard CMTimeCompare(actualDuration, expected.duration) == 0 else {
            throw OutputMediaVerificationError.frameDurationMismatch(
                frameIndex: expected.frameIndex,
                expected: expected.duration,
                actual: actualDuration
            )
        }
    }

    private static func verifyPlanes(
        pixelBuffer: CVPixelBuffer,
        frameIndex: Int,
        resolution: VideoResolution,
        colorExpectation: OutputMediaVideoColorExpectation?
    ) throws -> (luma: Int, chroma: Int, alpha: Int) {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let expectedFormat = colorExpectation?.pixelFormat ?? PixelBufferBridge.preferredFormat
        guard actualFormat == expectedFormat else {
            throw OutputMediaVerificationError.pixelFormatMismatch(
                frameIndex: frameIndex,
                expected: expectedFormat,
                actual: actualFormat
            )
        }
        let actualResolution = VideoResolution(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard actualResolution == resolution else {
            throw OutputMediaVerificationError.dimensionsMismatch(
                expected: resolution,
                actual: actualResolution
            )
        }
        if let colorExpectation {
            try verifyDecodedVideoColor(
                pixelBuffer: pixelBuffer,
                expected: colorExpectation
            )
        }
        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let expectedPlaneCount = colorExpectation?.expectedPlaneCount
            ?? 2
        guard planeCount == expectedPlaneCount else {
            throw OutputMediaVerificationError.planeCountMismatch(
                frameIndex: frameIndex,
                expected: expectedPlaneCount,
                actual: planeCount
            )
        }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            throw OutputMediaVerificationError.planeLockFailed(
                frameIndex: frameIndex,
                status: lockStatus
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if planeCount == 0 {
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard CVPixelBufferGetBaseAddress(pixelBuffer) != nil,
                  height > 0,
                  bytesPerRow > 0,
                  height <= Int.max / bytesPerRow else {
                throw OutputMediaVerificationError.emptyPlanePayload(
                    frameIndex: frameIndex,
                    planeIndex: 0
                )
            }
            return (
                luma: height * bytesPerRow,
                chroma: 0,
                alpha: 0
            )
        }

        var payloadBytes: [Int] = []
        for planeIndex in 0..<planeCount {
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
            let width = CVPixelBufferGetWidthOfPlane(
                pixelBuffer,
                planeIndex
            )
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
            if let colorExpectation {
                let expectedPlaneResolution =
                    expectedPlaneResolution(
                        planeIndex: planeIndex,
                        frameResolution: resolution,
                        storage: colorExpectation.pixelStorage
                    )
                let actualPlaneResolution = VideoResolution(
                    width: width,
                    height: height
                )
                guard actualPlaneResolution
                        == expectedPlaneResolution else {
                    throw OutputMediaVerificationError
                        .planeDimensionsMismatch(
                            frameIndex: frameIndex,
                            planeIndex: planeIndex,
                            expected: expectedPlaneResolution,
                            actual: actualPlaneResolution
                        )
                }
            }
            guard CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex) != nil,
                  height > 0,
                  bytesPerRow > 0,
                  height <= Int.max / bytesPerRow else {
                throw OutputMediaVerificationError.emptyPlanePayload(
                    frameIndex: frameIndex,
                    planeIndex: planeIndex
                )
            }
            payloadBytes.append(height * bytesPerRow)
        }
        return (
            luma: payloadBytes[0],
            chroma: payloadBytes[1],
            alpha: payloadBytes.count == 3 ? payloadBytes[2] : 0
        )
    }

    private static func expectedPlaneResolution(
        planeIndex: Int,
        frameResolution: VideoResolution,
        storage: MediaVideoPixelStorage
    ) -> VideoResolution {
        if planeIndex == 0 || planeIndex == 2 {
            return frameResolution
        }
        switch storage.chromaSampling {
        case .yuv420:
            return VideoResolution(
                width: frameResolution.width / 2,
                height: frameResolution.height / 2
            )
        case .yuv422:
            return VideoResolution(
                width: frameResolution.width / 2,
                height: frameResolution.height
            )
        case .yuv444, .rgb:
            return frameResolution
        }
    }

    private static func codecIdentifier(_ codec: OutputCodec) -> String {
        switch codec {
        case .hevc:
            return fourCCString(kCMVideoCodecType_HEVC)
        case .h264:
            return fourCCString(kCMVideoCodecType_H264)
        case .proRes422HQ:
            return fourCCString(kCMVideoCodecType_AppleProRes422HQ)
        case .proRes4444:
            return fourCCString(kCMVideoCodecType_AppleProRes4444)
        }
    }

    private static func transformsMatch(
        _ lhs: CGAffineTransform,
        _ rhs: CGAffineTransform
    ) -> Bool {
        [lhs.a - rhs.a, lhs.b - rhs.b, lhs.c - rhs.c, lhs.d - rhs.d,
         lhs.tx - rhs.tx, lhs.ty - rhs.ty]
            .allSatisfy { abs($0) <= 0.000_001 }
    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

// Reopen verification is reviewed as one ordered fail-closed transaction.
// swiftlint:disable:this file_length
