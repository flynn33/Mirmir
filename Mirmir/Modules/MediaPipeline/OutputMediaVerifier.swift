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

    private struct CompressedFrameTiming {
        let presentationTime: CMTime
        let duration: CMTime
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
        try await Self.verifyCompressedFrameTiming(
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
            mediaPreservation: expectation.mediaPreservation,
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

    private static func verifyCompressedFrameTiming(
        reopened: ReopenedOutput,
        expectation: OutputMediaVerificationExpectation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: reopened.asset)
        } catch {
            throw OutputMediaVerificationError.readerCreationFailed(
                "compressed video timing reader creation failed: \(error)"
            )
        }
        let output = AVAssetReaderTrackOutput(
            track: reopened.videoTrack,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw OutputMediaVerificationError.readerCreationFailed(
                "reader rejected compressed video timing output"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OutputMediaVerificationError.readerStartFailed(
                reader.error.map(String.init(describing:)) ?? "unknown"
            )
        }

        let cancellation = OutputMediaReaderCancellation(reader: reader)
        let frames: [CompressedFrameTiming] = try await
            withTaskCancellationHandler {
                do {
                    var frames: [CompressedFrameTiming] = []
                    while let sample = output.copyNextSampleBuffer() {
                        try cancellationCheck()
                        try autoreleasepool {
                            frames.append(
                                contentsOf: try compressedFrameTimings(
                                    in: sample
                                )
                            )
                        }
                    }
                    try cancellationCheck()
                    guard reader.status == .completed else {
                        throw OutputMediaVerificationError.readerFailed(
                            reader.error.map(String.init(describing:))
                                ?? "compressed timing reader status "
                                    + "\(reader.status.rawValue)"
                        )
                    }
                    return frames
                } catch is CancellationError {
                    cancellation.cancel()
                    throw CancellationError()
                }
            } onCancel: {
                cancellation.cancel()
            }

        let presentationOrderedFrames = frames.sorted { left, right in
            CMTimeCompare(
                left.presentationTime,
                right.presentationTime
            ) < 0
        }
        guard presentationOrderedFrames.count
                == expectation.timing.frameCount else {
            throw OutputMediaVerificationError.frameCountMismatch(
                expected: expectation.timing.frameCount,
                actual: presentationOrderedFrames.count
            )
        }
        for (actual, expected) in zip(
            presentationOrderedFrames,
            expectation.timing.frames
        ) {
            try verifyCompressedTiming(
                actual: actual,
                expected: expected,
                frameCount: presentationOrderedFrames.count
            )
        }
    }

    private static func verifyCompressedTiming(
        actual: CompressedFrameTiming,
        expected: FrameTiming,
        frameCount: Int
    ) throws {
        guard actual.presentationTime.isValid,
              actual.presentationTime.isNumeric,
              CMTimeCompare(
                actual.presentationTime,
                expected.presentationTime
              ) == 0 else {
            throw OutputMediaVerificationError.presentationTimeMismatch(
                frameIndex: expected.frameIndex,
                expected: expected.presentationTime,
                actual: actual.presentationTime
            )
        }
        guard actual.duration.isValid,
              actual.duration.isNumeric,
              CMTimeCompare(actual.duration, .zero) > 0 else {
            throw OutputMediaVerificationError.frameDurationMismatch(
                frameIndex: expected.frameIndex,
                expected: expected.duration,
                actual: actual.duration
            )
        }
        // A one-frame encode can carry an arbitrarily padded packet that the
        // track edit trims to the requested duration, so the ledger alone
        // cannot distinguish that encoder behavior from a remux mutation.
        // With multiple frames, reject an encoded packet that overruns its
        // ledger duration. Shorter raw boundary packets remain governed by
        // the exact decoded PTS/duration and track-end checks above because
        // media-timescale quantization can make the untrimmed packet one tick
        // shorter than the exact edited presentation duration.
        guard frameCount == 1
                || CMTimeCompare(
                    actual.duration,
                    expected.duration
                ) <= 0 else {
            throw OutputMediaVerificationError.frameDurationMismatch(
                frameIndex: expected.frameIndex,
                expected: expected.duration,
                actual: actual.duration
            )
        }
    }

    private static func compressedFrameTimings(
        in sample: CMSampleBuffer
    ) throws -> [CompressedFrameTiming] {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        guard sampleCount > 0 else { return [] }
        let rawTiming = try sampleTimingInfo(
            in: sample,
            outputTiming: false
        )
        let outputTiming = try sampleTimingInfo(
            in: sample,
            outputTiming: true
        )
        guard [rawTiming.count, outputTiming.count].allSatisfy({ count in
            count == 1 || count == sampleCount
        }) else {
            throw OutputMediaVerificationError.readerFailed(
                "compressed video timing entry count does not match "
                    + "sample count \(sampleCount)"
            )
        }

        return (0..<sampleCount).map { sampleIndex in
            let raw = expandedTiming(
                rawTiming,
                sampleIndex: sampleIndex
            )
            let output = expandedTiming(
                outputTiming,
                sampleIndex: sampleIndex
            )
            return CompressedFrameTiming(
                presentationTime: output.presentationTimeStamp,
                // Output timing applies edit-list trimming. Exact packet
                // verification intentionally retains the encoded sample's
                // untrimmed duration so a remux cannot hide a lengthened
                // trailing packet behind an unchanged track endpoint.
                duration: raw.duration
            )
        }
    }

    private static func sampleTimingInfo(
        in sample: CMSampleBuffer,
        outputTiming: Bool
    ) throws -> [CMSampleTimingInfo] {
        var requiredEntryCount: CMItemCount = 0
        let countStatus: OSStatus
        if outputTiming {
            countStatus = CMSampleBufferGetOutputSampleTimingInfoArray(
                sample,
                entryCount: 0,
                arrayToFill: nil,
                entriesNeededOut: &requiredEntryCount
            )
        } else {
            countStatus = CMSampleBufferGetSampleTimingInfoArray(
                sample,
                entryCount: 0,
                arrayToFill: nil,
                entriesNeededOut: &requiredEntryCount
            )
        }
        guard countStatus == noErr, requiredEntryCount > 0 else {
            let timingKind = outputTiming ? "output " : ""
            throw OutputMediaVerificationError.readerFailed(
                "compressed video sample has no usable "
                    + timingKind + "timing "
                    + "(status \(countStatus))"
            )
        }

        var timing = Array(
            repeating: CMSampleTimingInfo.invalid,
            count: requiredEntryCount
        )
        let readStatus = timing.withUnsafeMutableBufferPointer { buffer in
            if outputTiming {
                return CMSampleBufferGetOutputSampleTimingInfoArray(
                    sample,
                    entryCount: buffer.count,
                    arrayToFill: buffer.baseAddress,
                    entriesNeededOut: &requiredEntryCount
                )
            }
            return CMSampleBufferGetSampleTimingInfoArray(
                sample,
                entryCount: buffer.count,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: &requiredEntryCount
            )
        }
        guard readStatus == noErr else {
            throw OutputMediaVerificationError.readerFailed(
                "compressed video sample timing read failed with status "
                    + "\(readStatus)"
            )
        }
        return timing
    }

    private static func expandedTiming(
        _ timing: [CMSampleTimingInfo],
        sampleIndex: Int
    ) -> CMSampleTimingInfo {
        guard timing.count == 1, sampleIndex > 0 else {
            return timing[timing.count == 1 ? 0 : sampleIndex]
        }
        let base = timing[0]
        return CMSampleTimingInfo(
            duration: base.duration,
            presentationTimeStamp: CMTimeAdd(
                base.presentationTimeStamp,
                CMTimeMultiply(
                    base.duration,
                    multiplier: Int32(sampleIndex)
                )
            ),
            decodeTimeStamp: base.decodeTimeStamp.isValid
                ? CMTimeAdd(
                    base.decodeTimeStamp,
                    CMTimeMultiply(
                        base.duration,
                        multiplier: Int32(sampleIndex)
                    )
                )
                : .invalid
        )
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
        mediaPreservation: OutputMediaPreservationExpectation?,
        expectedEndTime: CMTime,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> CMPersistentTrackID? {
        try cancellationCheck()
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        try cancellationCheck()
        try await verifyNoControlledStaticMetadata(
            asset: asset,
            cancellationCheck: cancellationCheck
        )
        let timedMetadataInspections =
            try await readTimedMetadataTrackInspections(
                asset: asset,
                tracks: tracks,
                cancellationCheck: cancellationCheck
            )
        let expectedIdentifiers = Set(
            expected.keys.map { "mdta/\($0)" }
        )
        var matchingTracks: [AVAssetTrack] = []
        var identifiersByTrackID:
            [CMPersistentTrackID: Set<String>] = [:]
        var hasCompleteFormatIdentityByTrackID:
            [CMPersistentTrackID: Bool] = [:]
        var formatDescriptionsByTrackID:
            [CMPersistentTrackID: [CMFormatDescription]] = [:]
        for track in tracks {
            try cancellationCheck()
            let formatDescriptions = try await track.load(
                .formatDescriptions
            )
            formatDescriptionsByTrackID[track.trackID] = formatDescriptions
            let identifierLists = formatDescriptions.map { description in
                (
                    CMMetadataFormatDescriptionGetIdentifiers(description)
                        as? [String]
                ) ?? []
            }
            let identifiers = Set(identifierLists.flatMap { $0 })
            identifiersByTrackID[track.trackID] = identifiers
            hasCompleteFormatIdentityByTrackID[track.trackID] =
                !identifierLists.isEmpty
                    && identifierLists.allSatisfy { !$0.isEmpty }
            if identifiers == expectedIdentifiers {
                matchingTracks.append(track)
            }
        }
        try verifyStructuralCarriers(
            tracks: tracks,
            identifiersByTrackID: identifiersByTrackID,
            hasCompleteFormatIdentityByTrackID:
                hasCompleteFormatIdentityByTrackID,
            formatDescriptionsByTrackID: formatDescriptionsByTrackID,
            timedMetadataInspections: timedMetadataInspections,
            mediaPreservation: mediaPreservation
        )
        let identifiersByTrack = Array(
            identifiersByTrackID.values
        )
        let controlledLikeIdentifiers = Set(
            identifiersByTrack.flatMap { identifiers in
                identifiers.filter { identifier in
                    identifier
                        != MirmirTimedMetadataMigration
                            .shellCarrierIdentifier
                        && (
                            MirmirTimedMetadataPolicy
                                .isControlledIdentifier(identifier)
                                || MirmirTimedMetadataPolicy
                                    .resemblesControlledIdentifier(
                                        identifier
                                    )
                        )
                }
            }
        )
        let duplicatedIdentifiers = expectedIdentifiers.filter {
            expectedIdentifier in
            identifiersByTrack.filter {
                $0.contains(expectedIdentifier)
            }.count > 1
        }
        let unexpectedControlledIdentifiers = controlledLikeIdentifiers
            .subtracting(expectedIdentifiers)
        let decodedControlledIdentifiers = Set(
            timedMetadataInspections.values.flatMap {
                $0.controlledLikeIdentifiers
            }
        ).subtracting([
            MirmirTimedMetadataMigration.shellCarrierIdentifier
        ])
        let unexpectedDecodedControlledIdentifiers =
            decodedControlledIdentifiers.subtracting(expectedIdentifiers)
        if expected.isEmpty {
            guard controlledLikeIdentifiers.isEmpty,
                  decodedControlledIdentifiers.isEmpty else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: "timed Mirmir identity",
                    reason: "output expected no controlled identity but "
                        + "observed format identifiers "
                        + "\(controlledLikeIdentifiers.sorted()) and "
                        + "decoded identifiers "
                        + "\(decodedControlledIdentifiers.sorted())"
                )
            }
            return nil
        }
        guard duplicatedIdentifiers.isEmpty,
              unexpectedControlledIdentifiers.isEmpty,
              unexpectedDecodedControlledIdentifiers.isEmpty else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "controlled identifiers must be globally unique; "
                    + "multiple metadata tracks contain "
                    + "\(duplicatedIdentifiers.sorted()), unexpected "
                    + "controlled identifiers "
                    + "\(unexpectedControlledIdentifiers.sorted()), "
                    + "unexpected decoded controlled identifiers "
                    + "\(unexpectedDecodedControlledIdentifiers.sorted())"
            )
        }
        guard matchingTracks.count == 1,
              let track = matchingTracks.first else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "expected one track with identifiers "
                    + "\(expectedIdentifiers.sorted()), observed "
                    + "\(matchingTracks.count) exact matches among "
                    + "\(tracks.count) metadata tracks"
            )
        }
        let noncanonicalControlledIdentifiers = Set(
            timedMetadataInspections.compactMap {
                trackID, inspection in
                trackID == track.trackID
                    ? nil
                    : inspection.controlledLikeIdentifiers
            }.flatMap { $0 }
        ).subtracting([
            MirmirTimedMetadataMigration.shellCarrierIdentifier
        ])
        guard noncanonicalControlledIdentifiers.isEmpty else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "noncanonical metadata tracks contain controlled "
                    + "identifiers "
                    + "\(noncanonicalControlledIdentifiers.sorted())"
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

    private static func verifyNoControlledStaticMetadata(
        asset: AVURLAsset,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        do {
            try cancellationCheck()
            try rejectControlledStaticMetadata(
                try await asset.load(.metadata),
                location: "container",
                cancellationCheck: cancellationCheck
            )
            let tracks = try await asset.load(.tracks)
            for track in tracks {
                try cancellationCheck()
                try rejectControlledStaticMetadata(
                    try await track.load(.metadata),
                    location: "\(track.mediaType.rawValue) track "
                        + "\(track.trackID)",
                    cancellationCheck: cancellationCheck
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OutputMediaVerificationError {
            throw error
        } catch {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "static metadata inspection failed: \(error)"
            )
        }
    }

    private static func rejectControlledStaticMetadata(
        _ items: [AVMetadataItem],
        location: String,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws {
        for item in items {
            try cancellationCheck()
            if metadataIdentifierCandidates(for: item).contains(
                MirmirTimedMetadataMigration.shellCarrierIdentifier
            ) {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: "timed Mirmir identity",
                    reason: "\(location) static metadata contains the "
                        + "reserved structural-carrier identifier"
                )
            }
            guard let identifier = controlledLikeIdentifier(for: item) else {
                continue
            }
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "\(location) static metadata contains controlled "
                    + "identifier \(identifier)"
            )
        }
    }

    private struct TimedMetadataTrackInspection {
        let controlledLikeIdentifiers: Set<String>
        let groupCount: Int
        let itemCount: Int
        let containsCarrierItem: Bool
    }

    private static func readTimedMetadataTrackInspections(
        asset: AVURLAsset,
        tracks: [AVAssetTrack],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws ->
        [CMPersistentTrackID: TimedMetadataTrackInspection] {
        var result:
            [CMPersistentTrackID: TimedMetadataTrackInspection] = [:]
        for track in tracks {
            try cancellationCheck()
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: "timed Mirmir identity",
                    reason: "global metadata reader creation failed: "
                        + "\(error)"
                )
            }
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            guard reader.canAdd(output) else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: "timed Mirmir identity",
                    reason: "global metadata reader rejected track "
                        + "\(track.trackID)"
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
                        ?? "global metadata reader did not start"
                )
            }
            let cancellation = OutputMediaReaderCancellation(
                reader: reader
            )
            let inspection: TimedMetadataTrackInspection = try await
                withTaskCancellationHandler {
                    do {
                        var identifiers: Set<String> = []
                        var groupCount = 0
                        var itemCount = 0
                        var containsCarrierItem = false
                        while true {
                            try cancellationCheck()
                            guard let group = adaptor
                                .nextTimedMetadataGroup() else {
                                break
                            }
                            groupCount += 1
                            itemCount += group.items.count
                            for item in group.items {
                                try cancellationCheck()
                                if metadataIdentifierCandidates(
                                    for: item
                                ).contains(
                                    MirmirTimedMetadataMigration
                                        .shellCarrierIdentifier
                                ) {
                                    containsCarrierItem = true
                                }
                                if let identifier =
                                    controlledLikeIdentifier(for: item) {
                                    identifiers.insert(identifier)
                                }
                            }
                        }
                        try cancellationCheck()
                        guard reader.status == .completed else {
                            throw OutputMediaVerificationError
                                .metadataMismatch(
                                    scope: "timed Mirmir identity",
                                    reason: reader.error.map(
                                        String.init(describing:)
                                    ) ?? "global metadata reader status "
                                        + "\(reader.status.rawValue)"
                                )
                        }
                        return TimedMetadataTrackInspection(
                            controlledLikeIdentifiers: identifiers,
                            groupCount: groupCount,
                            itemCount: itemCount,
                            containsCarrierItem: containsCarrierItem
                        )
                    } catch is CancellationError {
                        cancellation.cancel()
                        throw CancellationError()
                    }
                } onCancel: {
                    cancellation.cancel()
                }
            result[track.trackID] = inspection
        }
        return result
    }

    private static func verifyStructuralCarriers(
        tracks: [AVAssetTrack],
        identifiersByTrackID:
            [CMPersistentTrackID: Set<String>],
        hasCompleteFormatIdentityByTrackID:
            [CMPersistentTrackID: Bool],
        formatDescriptionsByTrackID:
            [CMPersistentTrackID: [CMFormatDescription]],
        timedMetadataInspections:
            [CMPersistentTrackID: TimedMetadataTrackInspection],
        mediaPreservation: OutputMediaPreservationExpectation?
    ) throws {
        let carrierIdentifier =
            MirmirTimedMetadataMigration.shellCarrierIdentifier
        let expectedCarriers = mediaPreservation?.tracks.filter {
            $0.role == .mirmirStructuralCarrier
        } ?? []
        guard expectedCarriers.allSatisfy({ expectation in
            expectation.reference.mediaType
                == AVMediaType.metadata.rawValue
        }) else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "a structural-carrier expectation targets a "
                    + "non-metadata track"
            )
        }

        var exactCarrierTracks: [AVAssetTrack] = []
        for track in tracks {
            let identifiers = identifiersByTrackID[
                track.trackID,
                default: []
            ]
            guard identifiers.contains(carrierIdentifier) else {
                continue
            }
            guard identifiers == [carrierIdentifier],
                  hasCompleteFormatIdentityByTrackID[
                    track.trackID
                  ] == true,
                  let formatDescriptions = formatDescriptionsByTrackID[
                    track.trackID
                  ],
                  MirmirTimedMetadataMigration.isExactShellFormat(
                    formatDescriptions
                  ) else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: "timed Mirmir identity",
                    reason: "metadata track \(track.trackID) does not "
                        + "have the reserved structural-carrier as its "
                        + "complete sole format identifier and canonical "
                        + "carrier schema"
                )
            }
            exactCarrierTracks.append(track)
        }

        let carrierItemTrackIDs = timedMetadataInspections.compactMap {
            trackID, inspection in
            inspection.containsCarrierItem ? trackID : nil
        }.sorted()
        guard carrierItemTrackIDs.isEmpty else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "the reserved structural-carrier identifier "
                    + "appears as a decoded metadata item on tracks "
                    + "\(carrierItemTrackIDs)"
            )
        }

        guard exactCarrierTracks.count == expectedCarriers.count else {
            throw OutputMediaVerificationError.metadataMismatch(
                scope: "timed Mirmir identity",
                reason: "structural-carrier track count differs "
                    + "(expected \(expectedCarriers.count), observed "
                    + "\(exactCarrierTracks.count))"
            )
        }
        for track in exactCarrierTracks {
            guard let inspection = timedMetadataInspections[
                track.trackID
            ] else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: "timed Mirmir identity",
                    reason: "structural-carrier track \(track.trackID) "
                        + "was not decoded"
                )
            }
            guard inspection.groupCount == 1,
                  inspection.itemCount == 0 else {
                throw OutputMediaVerificationError.metadataMismatch(
                    scope: "timed Mirmir identity",
                    reason: "structural-carrier track \(track.trackID) "
                        + "must contain exactly one decoded group and "
                        + "zero decoded items; observed "
                        + "\(inspection.groupCount) groups and "
                        + "\(inspection.itemCount) items"
                )
            }
        }
    }

    private static func controlledLikeIdentifier(
        for item: AVMetadataItem
    ) -> String? {
        metadataIdentifierCandidates(for: item).first { identifier in
            MirmirTimedMetadataPolicy.isControlledIdentifier(identifier)
                || MirmirTimedMetadataPolicy
                    .resemblesControlledIdentifier(identifier)
        }
    }

    private static func metadataIdentifierCandidates(
        for item: AVMetadataItem
    ) -> [String] {
        var candidates: [String] = []
        if let identifier = item.identifier?.rawValue {
            candidates.append(identifier)
        }
        if let key = metadataKey(item) {
            if item.keySpace == .quickTimeMetadata {
                candidates.append("mdta/\(key)")
            }
            candidates.append(key)
        }
        return candidates
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
        try verifyTiming(
            actualPresentationTime:
                CMSampleBufferGetPresentationTimeStamp(sample),
            actualDuration: actualDuration,
            expected: expected
        )
    }

    private static func verifyTiming(
        actualPresentationTime: CMTime,
        actualDuration: CMTime,
        expected: FrameTiming
    ) throws {
        guard actualPresentationTime.isValid,
              actualPresentationTime.isNumeric,
              CMTimeCompare(
                actualPresentationTime,
                expected.presentationTime
              ) == 0 else {
            throw OutputMediaVerificationError.presentationTimeMismatch(
                frameIndex: expected.frameIndex,
                expected: expected.presentationTime,
                actual: actualPresentationTime
            )
        }
        guard actualDuration.isValid,
              actualDuration.isNumeric,
              CMTimeCompare(actualDuration, expected.duration) == 0 else {
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
