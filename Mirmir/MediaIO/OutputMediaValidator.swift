import AVFoundation
import CoreMedia
import Foundation

struct OutputMediaFacts: Equatable, Sendable {
    let duration: CMTime
    let encodedWidth: Int
    let encodedHeight: Int
    let hasAudio: Bool
    let audioTrackCount: Int
}

struct AudioTopologyV4: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        let enabled: Bool
        let language: MediaTrackLanguageV4
        let metadataFingerprint: ASHSHA256V4
    }

    struct Group: Equatable, Sendable {
        let kind: MediaTrackGroupKindV4
        let memberAudioOrdinals: [Int]
        let defaultAudioOrdinal: Int?
        let allowsEmptySelection: Bool
    }

    static let empty = AudioTopologyV4(tracks: [], groups: [])

    let tracks: [Track]
    let groups: [Group]

    private init(tracks: [Track], groups: [Group]) {
        self.tracks = tracks
        self.groups = groups
    }

    init(graph: MediaTrackGraphV4, preservingAudio: Bool) {
        guard preservingAudio else {
            self = .empty
            return
        }
        let audioTracks = graph.tracks.filter { $0.kind == .audio }
        let ordinalByID = Dictionary(
            uniqueKeysWithValues: audioTracks.enumerated().map {
                ($0.element.identity.stableID, $0.offset)
            }
        )
        tracks = audioTracks.map {
            Track(
                enabled: $0.enabled,
                language: $0.language,
                metadataFingerprint: $0.metadataFingerprint
            )
        }
        groups = graph.groups.compactMap { group in
            let memberOrdinals = group.memberTrackIDs.compactMap {
                ordinalByID[$0]
            }
            guard !memberOrdinals.isEmpty else { return nil }
            return Group(
                kind: group.kind,
                memberAudioOrdinals: memberOrdinals,
                defaultAudioOrdinal: group.defaultTrackID.flatMap {
                    ordinalByID[$0]
                },
                allowsEmptySelection: group.allowsEmptySelection
            )
        }
    }
}

struct OutputMediaValidator: Sendable {
    func validate(
        url: URL,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedAudioTopology: AudioTopologyV4
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

        let outputGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: asset
        )
        let audioTopology = AudioTopologyV4(
            graph: outputGraph,
            preservingAudio: true
        )
        let audioTrackCount = audioTopology.tracks.count
        let hasAudio = audioTrackCount > 0
        guard audioTrackCount == expectedAudioTopology.tracks.count else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie contains \(audioTrackCount) audio tracks instead of the source contract's \(expectedAudioTopology.tracks.count)"
            )
        }
        guard audioTopology.tracks == expectedAudioTopology.tracks else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie changed audio language, metadata, enabled state, or logical track order"
            )
        }
        guard audioTopology.groups == expectedAudioTopology.groups else {
            throw MirmirError.outputFinalizeFailed(
                "the completed movie changed alternate-audio membership or default selection"
            )
        }
        try readBoundarySample(asset: asset, track: videoTrack, duration: duration)

        return OutputMediaFacts(
            duration: duration,
            encodedWidth: encodedWidth,
            encodedHeight: encodedHeight,
            hasAudio: hasAudio,
            audioTrackCount: audioTrackCount
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
