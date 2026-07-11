import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct OutputMediaVerificationExpectation: @unchecked Sendable, Equatable {
    let resolution: VideoResolution
    let codec: OutputCodec
    let timing: FrameTimingLedgerSnapshot
}

struct OutputMediaVerificationResult: @unchecked Sendable, Equatable {
    let codec: String
    let resolution: VideoResolution
    let frameCount: Int
    let duration: CMTime
    let lumaPayloadBytes: Int
    let chromaPayloadBytes: Int
}

enum OutputMediaVerificationError: Error, Equatable, CustomStringConvertible {
    case emptyTimingLedger
    case reopenFailed(String)
    case videoTrackCount(expected: Int, actual: Int)
    case missingVideoFormatDescription
    case codecMismatch(expected: String, actual: String)
    case dimensionsMismatch(expected: VideoResolution, actual: VideoResolution)
    case readerCreationFailed(String)
    case readerStartFailed(String)
    case readerFailed(String)
    case frameCountMismatch(expected: Int, actual: Int)
    case missingDecodedImage(frameIndex: Int)
    case pixelFormatMismatch(frameIndex: Int, expected: OSType, actual: OSType)
    case planeCountMismatch(frameIndex: Int, expected: Int, actual: Int)
    case planeLockFailed(frameIndex: Int, status: CVReturn)
    case emptyPlanePayload(frameIndex: Int, planeIndex: Int)
    case presentationTimeMismatch(frameIndex: Int, expected: CMTime, actual: CMTime)
    case frameDurationMismatch(frameIndex: Int, expected: CMTime, actual: CMTime)
    case mediaDurationMismatch(expected: CMTime, actual: CMTime)
    case trackEndMismatch(expected: CMTime, actual: CMTime)

    var description: String {
        switch self {
        case .emptyTimingLedger:
            return "Output verification requires at least one expected video frame."
        case .reopenFailed(let reason):
            return "Output could not be reopened: \(reason)."
        case .videoTrackCount(let expected, let actual):
            return "Output contains \(actual) video tracks; expected \(expected)."
        case .missingVideoFormatDescription:
            return "Output video track has no format description."
        case .codecMismatch(let expected, let actual):
            return "Output codec \(actual) does not match expected codec \(expected)."
        case .dimensionsMismatch(let expected, let actual):
            return "Output dimensions \(actual) do not match expected dimensions \(expected)."
        case .readerCreationFailed(let reason):
            return "Output verification reader creation failed: \(reason)."
        case .readerStartFailed(let reason):
            return "Output verification reader did not start: \(reason)."
        case .readerFailed(let reason):
            return "Output verification reader failed: \(reason)."
        case .frameCountMismatch(let expected, let actual):
            return "Decoded output frame count \(actual) does not match expected count \(expected)."
        case .missingDecodedImage(let frameIndex):
            return "Decoded output frame \(frameIndex) contains no image buffer."
        case .pixelFormatMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) pixel format \(actual) does not match NV12 format \(expected)."
        case .planeCountMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) has \(actual) planes; expected \(expected)."
        case .planeLockFailed(let frameIndex, let status):
            return "Decoded frame \(frameIndex) could not be locked for plane verification (\(status))."
        case .emptyPlanePayload(let frameIndex, let planeIndex):
            return "Decoded frame \(frameIndex) plane \(planeIndex) has no addressable payload."
        case .presentationTimeMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) PTS \(actual) does not match expected PTS \(expected)."
        case .frameDurationMismatch(let frameIndex, let expected, let actual):
            return "Decoded frame \(frameIndex) duration \(actual) does not match expected duration \(expected)."
        case .mediaDurationMismatch(let expected, let actual):
            return "Reopened media duration \(actual) does not match expected endpoint \(expected)."
        case .trackEndMismatch(let expected, let actual):
            return "Reopened video track endpoint \(actual) does not match expected endpoint \(expected)."
        }
    }
}

protocol OutputMediaVerifying: Sendable {
    func verify(
        url: URL,
        expectation: OutputMediaVerificationExpectation
    ) async throws -> OutputMediaVerificationResult
}

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
                resolution: expectation.resolution
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
              let expectedEndTime = expectation.timing.sessionEndTime else {
            throw OutputMediaVerificationError.emptyTimingLedger
        }
        let reopened = try await Self.reopen(url: url, expectation: expectation)
        let decoded = try Self.decodeFrames(
            reopened: reopened,
            expectation: expectation
        )
        try Self.verifyDurations(
            reopened: reopened,
            expectedEndTime: expectedEndTime
        )

        return OutputMediaVerificationResult(
            codec: reopened.codec,
            resolution: reopened.resolution,
            frameCount: decoded.frameCount,
            duration: reopened.duration,
            lumaPayloadBytes: decoded.lumaPayloadBytes,
            chromaPayloadBytes: decoded.chromaPayloadBytes
        )
    }

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
        expectedEndTime: CMTime
    ) throws {
        guard CMTimeCompare(reopened.duration, expectedEndTime) == 0 else {
            throw OutputMediaVerificationError.mediaDurationMismatch(
                expected: expectedEndTime,
                actual: reopened.duration
            )
        }
        let trackEnd = CMTimeRangeGetEnd(reopened.trackTimeRange)
        guard CMTimeCompare(trackEnd, expectedEndTime) == 0 else {
            throw OutputMediaVerificationError.trackEndMismatch(
                expected: expectedEndTime,
                actual: trackEnd
            )
        }
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
        resolution: VideoResolution
    ) throws -> (luma: Int, chroma: Int) {
        let actualFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard actualFormat == PixelBufferBridge.preferredFormat else {
            throw OutputMediaVerificationError.pixelFormatMismatch(
                frameIndex: frameIndex,
                expected: PixelBufferBridge.preferredFormat,
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
