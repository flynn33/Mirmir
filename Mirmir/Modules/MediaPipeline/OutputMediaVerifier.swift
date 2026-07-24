import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

struct OutputMediaVerifier: OutputMediaVerifying {
    private struct ReopenedOutput {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let duration: CMTime
        let trackTimeRange: CMTimeRange
        let codec: String
        let resolution: VideoResolution
    }

    private struct DecodedOutput {
        private(set) var frameCount = 0
        private(set) var lumaPayloadBytes = 0
        private(set) var chromaPayloadBytes = 0

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
            frameCount += 1
        }
    }

    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult {
        guard expectation.timing.frameCount > 0,
              let expectedVideoEndTime = expectation.timing.sessionEndTime else {
            throw OutputMediaVerificationError.emptyTimingLedger
        }
        var expectedMediaEndTime = expectedVideoEndTime
        if let expectedAAC = expectation.compressedAACIdentity {
            let audioEndTime = CMTimeRangeGetEnd(expectedAAC.trackTimeRange)
            if CMTimeCompare(audioEndTime, expectedMediaEndTime) > 0 {
                expectedMediaEndTime = audioEndTime
            }
        }
        let reopened = try await Self.reopen(url: url, expectation: expectation)
        let decoded = try Self.decodeFrames(
            reopened: reopened,
            expectation: expectation
        )
        try Self.verifyDurations(
            reopened: reopened,
            expectedVideoEndTime: expectedVideoEndTime,
            expectedMediaEndTime: expectedMediaEndTime
        )
        try await Self.verifyTimedMetadata(
            asset: reopened.asset,
            expected: expectation.timedMetadata,
            expectedEndTime: expectedVideoEndTime
        )
        if let expectedAAC = expectation.compressedAACIdentity {
            let actualAAC = try await OutputMediaAACIdentityReader.read(
                asset: reopened.asset
            )
            try Self.verifyCompressedAAC(actualAAC, expected: expectedAAC)
        }

        return OutputMediaVerificationResult(
            codec: reopened.codec,
            resolution: reopened.resolution,
            frameCount: decoded.frameCount,
            duration: reopened.duration,
            lumaPayloadBytes: decoded.lumaPayloadBytes,
            chromaPayloadBytes: decoded.chromaPayloadBytes
        )
    }
}

private extension OutputMediaVerifier {
    private static func reopen(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> ReopenedOutput {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard videoTracks.count == 1, let videoTrack = videoTracks.first else {
                throw OutputMediaVerificationError.videoTrackCount(
                    expected: 1,
                    actual: videoTracks.count
                )
            }
            let trackFormats = try await videoTrack.load(.formatDescriptions)
            guard let videoFormat = trackFormats.first else {
                throw OutputMediaVerificationError.missingVideoFormatDescription
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
            return ReopenedOutput(
                asset: asset,
                videoTrack: videoTrack,
                duration: try await asset.load(.duration),
                trackTimeRange: try await videoTrack.load(.timeRange),
                codec: codec,
                resolution: resolution
            )
        } catch let error as OutputMediaVerificationError {
            throw error
        } catch {
            throw OutputMediaVerificationError.reopenFailed(String(describing: error))
        }
    }

    private static func decodeFrames(
        reopened: ReopenedOutput,
        expectation: OutputMediaVerificationExpectation
    ) throws -> DecodedOutput {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: reopened.asset)
        } catch {
            throw OutputMediaVerificationError.readerCreationFailed(String(describing: error))
        }
        let output = AVAssetReaderTrackOutput(
            track: reopened.videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: PixelBufferBridge.preferredFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OutputMediaVerificationError.readerCreationFailed(
                "reader rejected the decoded NV12 output"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OutputMediaVerificationError.readerStartFailed(
                reader.error.map(String.init(describing:)) ?? "unknown"
            )
        }

        var result = DecodedOutput()
        var currentSample = output.copyNextSampleBuffer()
        let trackEnd = CMTimeRangeGetEnd(reopened.trackTimeRange)
        while let sample = currentSample {
            let nextSample = output.copyNextSampleBuffer()
            let actualDuration = FrameTiming.resolveDuration(
                sampleDuration: CMSampleBufferGetDuration(sample),
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sample),
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
            currentSample = nextSample
        }
        guard reader.status == .completed else {
            throw OutputMediaVerificationError.readerFailed(
                reader.error.map(String.init(describing:)) ?? "status \(reader.status.rawValue)"
            )
        }
        guard result.frameCount == expectation.timing.frameCount else {
            throw OutputMediaVerificationError.frameCountMismatch(
                expected: expectation.timing.frameCount,
                actual: result.frameCount
            )
        }
        return result
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
        expectedEndTime: CMTime
    ) async throws {
        guard !expected.isEmpty else { return }
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        guard tracks.count == 1, let track = tracks.first else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed ASH identity",
                reason: "expected one metadata track, observed \(tracks.count)"
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
        var groups: [AVTimedMetadataGroup] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            groups.append(group)
        }
        guard reader.status == .completed else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: reader.error.map(String.init(describing:))
                    ?? "reader status \(reader.status.rawValue)"
            )
        }
        guard groups.count == 1, let group = groups.first else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "expected one group, observed \(groups.count)"
            )
        }
        guard CMTimeCompare(group.timeRange.start, .zero) == 0,
              CMTimeCompare(CMTimeRangeGetEnd(group.timeRange), expectedEndTime) == 0 else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "group time range does not span the completed video"
            )
        }
        try await verifyMetadataItems(
            group.items,
            expected: expected,
            scope: "timed Mirmir identity"
        )
    }

    private static func verifyMetadataItems(
        _ items: [AVMetadataItem],
        expected: [String: String],
        scope: String
    ) async throws {
        guard !expected.isEmpty else { return }
        var observed: [String: String] = [:]
        for item in items {
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
    ) throws -> (luma: Int, chroma: Int) {
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
        guard planeCount == 2 else {
            throw OutputMediaVerificationError.planeCountMismatch(
                frameIndex: frameIndex,
                expected: 2,
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

        var payloadBytes: [Int] = []
        for planeIndex in 0..<planeCount {
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
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
        return (luma: payloadBytes[0], chroma: payloadBytes[1])
    }

    private static func codecIdentifier(_ codec: OutputCodec) -> String {
        switch codec {
        case .hevc:
            return fourCCString(kCMVideoCodecType_HEVC)
        case .h264:
            return fourCCString(kCMVideoCodecType_H264)
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
