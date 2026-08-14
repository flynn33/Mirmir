import AVFoundation
import CoreMedia
import Foundation

struct OutputMediaFacts: Equatable, Sendable {
    let duration: CMTime
    let encodedWidth: Int
    let encodedHeight: Int
    let hasAudio: Bool
}

struct OutputMediaValidator: Sendable {
    func validate(
        url: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        requiresAudio: Bool
    ) async throws -> OutputMediaFacts {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else {
            throw MirmirError.outputFinalizeFailed(
                "AVAssetWriter produced an empty file"
            )
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let (readable, playable, duration, tracks) = try await asset.load(
            .isReadable,
            .isPlayable,
            .duration,
            .tracks
        )
        guard readable, playable else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie is not readable and playable"
            )
        }
        guard duration.isNumeric, CMTimeGetSeconds(duration) > 0 else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie has no positive duration"
            )
        }
        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard let videoTrack = videoTracks.first else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie contains no video track"
            )
        }
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        guard let firstFormat = formatDescriptions.first else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie has no video format description"
            )
        }
        let encodedDimensions = CMVideoFormatDescriptionGetDimensions(
            firstFormat
        )
        let encodedWidth = Int(encodedDimensions.width)
        let encodedHeight = Int(encodedDimensions.height)
        guard encodedWidth == expectedWidth,
              encodedHeight == expectedHeight,
              formatDescriptions.allSatisfy({ description in
                  guard CMFormatDescriptionGetMediaType(description)
                    == kCMMediaType_Video else { return false }
                  let dimensions = CMVideoFormatDescriptionGetDimensions(
                      description
                  )
                  return Int(dimensions.width) == expectedWidth
                    && Int(dimensions.height) == expectedHeight
              }) else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie's encoded raster is \(encodedWidth) × \(encodedHeight) instead of \(expectedWidth) × \(expectedHeight)"
            )
        }

        let hasAudio = tracks.contains { $0.mediaType == .audio }
        guard !requiresAudio || hasAudio else {
            throw MirmirError.outputFinalizeFailed(
                "audio preservation was requested, but the completed movie has no audio track"
            )
        }
        try readBoundarySample(asset: asset, track: videoTrack, duration: duration)

        return OutputMediaFacts(
            duration: duration,
            encodedWidth: encodedWidth,
            encodedHeight: encodedHeight,
            hasAudio: hasAudio
        )
    }

    private func readBoundarySample(
        asset: AVAsset,
        track: AVAssetTrack,
        duration: CMTime
    ) throws {
        let firstReader = try AVAssetReader(asset: asset)
        let firstOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard firstReader.canAdd(firstOutput) else {
            throw MirmirError.outputFinalizeFailed(
                "AVFoundation could not inspect the first output sample"
            )
        }
        firstReader.add(firstOutput)
        guard firstReader.startReading(),
              firstOutput.copyNextSampleBuffer() != nil else {
            throw MirmirError.outputFinalizeFailed(
                firstReader.error?.localizedDescription
                    ?? "the completed movie contains no readable first frame"
            )
        }
        firstReader.cancelReading()

        let tailDuration = CMTime(seconds: 1, preferredTimescale: 600)
        let tailStart = CMTimeMaximum(.zero, CMTimeSubtract(duration, tailDuration))
        let lastReader = try AVAssetReader(asset: asset)
        lastReader.timeRange = CMTimeRange(
            start: tailStart,
            duration: CMTimeSubtract(duration, tailStart)
        )
        let lastOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard lastReader.canAdd(lastOutput) else {
            throw MirmirError.outputFinalizeFailed(
                "AVFoundation could not inspect the last output sample"
            )
        }
        lastReader.add(lastOutput)
        guard lastReader.startReading(),
              lastOutput.copyNextSampleBuffer() != nil else {
            throw MirmirError.outputFinalizeFailed(
                lastReader.error?.localizedDescription
                    ?? "the completed movie contains no readable final frame"
            )
        }
        lastReader.cancelReading()
    }
}
