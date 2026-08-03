import AVFoundation
import CoreMedia
import Foundation

protocol VideoProbing: Sendable {
    func probe(url: URL) async throws -> VideoInfo
}

struct VideoProbe: VideoProbing {
    func probe(url: URL) async throws -> VideoInfo {
        guard url.isFileURL else {
            throw MirmirError.invalidRequest("Select a video file stored on this Mac.")
        }

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        do {
            let (
                duration,
                isPlayable,
                isReadable,
                hasProtectedContent,
                tracks
            ) = try await asset.load(
                .duration,
                .isPlayable,
                .isReadable,
                .hasProtectedContent,
                .tracks
            )
            try Task.checkCancellation()

            guard !hasProtectedContent else {
                throw MirmirError.protectedAsset
            }
            guard isReadable else {
                throw MirmirError.unreadableAsset
            }
            guard isPlayable else {
                throw MirmirError.unplayableAsset
            }

            let videoTracks = tracks.filter { $0.mediaType == .video }
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            guard !videoTracks.isEmpty else {
                throw MirmirError.noVideoTrack
            }

            var enabledVideoTracks: [AVAssetTrack] = []
            for track in videoTracks {
                if try await track.load(.isEnabled) {
                    enabledVideoTracks.append(track)
                }
            }
            guard !enabledVideoTracks.isEmpty else {
                throw MirmirError.noEnabledVideoTrack
            }
            // Asset track order is the deterministic primary-track rule used
            // by the v4 whole-asset planner. Alternate enabled video tracks
            // remain in the media inventory and are migrated unchanged.
            let videoTrack = enabledVideoTracks[0]
            let (
                naturalSize,
                preferredTransform,
                rawNominalFrameRate,
                rawMinimumFrameDuration,
                rawEstimatedDataRate,
                formatDescriptions,
                mediaCharacteristics,
                isTrackPlayable
            ) = try await videoTrack.load(
                .naturalSize,
                .preferredTransform,
                .nominalFrameRate,
                .minFrameDuration,
                .estimatedDataRate,
                .formatDescriptions,
                .mediaCharacteristics,
                .isPlayable
            )
            let isTrackDecodable = try await videoTrack.load(.isDecodable)
            try Task.checkCancellation()

            guard isTrackPlayable, isTrackDecodable else {
                throw MirmirError.undecodableVideoTrack
            }
            guard Self.isValid(size: naturalSize) else {
                throw MirmirError.invalidVideoGeometry
            }

            let formatFacts = try Self.consistentFormatFacts(
                from: formatDescriptions,
                mediaCharacteristics: mediaCharacteristics
            )
            let presentationSize = formatFacts?.presentationSize ?? naturalSize
            guard Self.isValid(size: presentationSize) else {
                throw MirmirError.invalidVideoGeometry
            }

            let displaySize = VideoGeometry.displaySize(
                presentationSize: presentationSize,
                preferredTransform: preferredTransform
            )
            guard Self.isValid(size: displaySize) else {
                throw MirmirError.invalidVideoGeometry
            }

            let nominalFrameRate = Self.positiveFinite(rawNominalFrameRate)
            let minimumFrameDuration = Self.positiveTime(
                rawMinimumFrameDuration
            )

            return VideoInfo(
                url: url,
                duration: duration,
                geometry: VideoGeometry(
                    encodedSize: formatFacts?.encodedSize,
                    naturalSize: naturalSize,
                    presentationSize: presentationSize,
                    displaySize: displaySize,
                    preferredTransform: preferredTransform,
                    cleanAperture: formatFacts?.cleanAperture,
                    pixelAspectRatio: formatFacts?.pixelAspectRatio
                ),
                nominalFrameRate: nominalFrameRate,
                minimumFrameDuration: minimumFrameDuration,
                estimatedFrameCount: Self.estimatedFrameCount(
                    duration: duration,
                    nominalFrameRate: nominalFrameRate
                ),
                estimatedDataRate: Self.positiveFinite(
                    rawEstimatedDataRate
                ),
                codecFourCC: formatFacts?.codecFourCC,
                hasAudio: !audioTracks.isEmpty,
                audioTrackCount: audioTracks.count,
                videoTrackCount: videoTracks.count,
                isReadable: isReadable,
                isPlayable: isPlayable,
                fileSizeBytes: Self.fileSize(at: url),
                color: formatFacts?.color ?? .unknown
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MirmirError {
            throw error
        } catch {
            throw MirmirError.probeFailed(
                "Mirmir couldn’t inspect \(url.lastPathComponent): "
                    + "\(error.localizedDescription) Choose another local video."
            )
        }
    }
}

private extension VideoProbe {
    struct FormatFacts: Equatable {
        let encodedSize: CGSize?
        let presentationSize: CGSize?
        let codecFourCC: FourCharCode
        let cleanAperture: CGRect?
        let pixelAspectRatio: VideoPixelAspectRatio?
        let color: VideoColorInfo
    }

    static func consistentFormatFacts(
        from descriptions: [CMFormatDescription],
        mediaCharacteristics: [AVMediaCharacteristic]
    ) throws -> FormatFacts? {
        let facts = try descriptions.map { description in
            try formatFacts(
                from: description,
                mediaCharacteristics: mediaCharacteristics
            )
        }
        guard let first = facts.first else {
            return nil
        }
        guard facts.dropFirst().allSatisfy({ $0 == first }) else {
            throw MirmirError.unsupportedVideo(
                "the enabled video track changes codec, geometry, or color "
                    + "metadata over time"
            )
        }
        return first
    }

    static func formatFacts(
        from description: CMFormatDescription,
        mediaCharacteristics: [AVMediaCharacteristic]
    ) throws -> FormatFacts {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else {
            throw MirmirError.unsupportedVideo(
                "the enabled video track contains a non-video format description"
            )
        }

        let dimensions = description.dimensions
        let encodedSize: CGSize? = dimensions.width > 0 && dimensions.height > 0
            ? CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            : nil
        let rawPresentationSize = description.presentationDimensions(
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
        let presentationSize = isValid(size: rawPresentationSize)
            ? rawPresentationSize
            : nil
        let extensions = description.extensions
        let cleanAperture = extensions[.cleanAperture] == nil
            ? nil
            : valid(rect: description.cleanAperture(originIsAtTopLeft: false))

        return FormatFacts(
            encodedSize: encodedSize,
            presentationSize: presentationSize,
            codecFourCC: description.mediaSubType.rawValue,
            cleanAperture: cleanAperture,
            pixelAspectRatio: pixelAspectRatio(from: extensions),
            color: colorInfo(
                from: extensions,
                mediaCharacteristics: mediaCharacteristics
            )
        )
    }

    static func colorInfo(
        from extensions: CMFormatDescription.Extensions,
        mediaCharacteristics: [AVMediaCharacteristic]
    ) -> VideoColorInfo {
        let colorPrimaries = stringValue(extensions[.colorPrimaries])
        let transferFunction = stringValue(extensions[.transferFunction])
        let alternativeTransfer = stringValue(
            extensions[.alternativeTransferCharacteristics]
        )
        let yCbCrMatrix = stringValue(extensions[.yCbCrMatrix])
        let hasMasteringDisplayMetadata =
            extensions[.masteringDisplayColorVolume] != nil
        let hasContentLightLevelMetadata =
            extensions[.contentLightLevelInfo] != nil

        let hdrTransfers: Set<String> = [
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        ]
        let sdrTransfers: Set<String> = [
            kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
            kCMFormatDescriptionTransferFunction_SMPTE_240M_1995 as String,
            kCMFormatDescriptionTransferFunction_UseGamma as String,
            kCMFormatDescriptionTransferFunction_sRGB as String
        ]
        let hasHDRTransfer = [transferFunction, alternativeTransfer]
            .compactMap { $0 }
            .contains { hdrTransfers.contains($0) }

        let dynamicRange: VideoDynamicRange
        if mediaCharacteristics.contains(.containsHDRVideo)
            || hasHDRTransfer
            || hasMasteringDisplayMetadata
            || hasContentLightLevelMetadata {
            dynamicRange = .hdr
        } else if let transferFunction,
                  sdrTransfers.contains(transferFunction) {
            dynamicRange = .sdr
        } else {
            dynamicRange = .unknown
        }

        return VideoColorInfo(
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            bitDepth: positiveInteger(extensions[.bitsPerComponent]),
            pixelFormat: nil,
            isFullRange: booleanValue(extensions[.fullRangeVideo]),
            fieldCount: positiveInteger(extensions[.fieldCount]),
            fieldDetail: stringValue(extensions[.fieldDetail]),
            hasMasteringDisplayMetadata: hasMasteringDisplayMetadata,
            hasContentLightLevelMetadata: hasContentLightLevelMetadata,
            dynamicRange: dynamicRange
        )
    }

    static func pixelAspectRatio(
        from extensions: CMFormatDescription.Extensions
    ) -> VideoPixelAspectRatio? {
        guard let propertyList = extensions[.pixelAspectRatio]?
            .propertyListRepresentation,
              let dictionary = propertyList as? NSDictionary,
              let horizontal = dictionary[
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing
              ] as? NSNumber,
              let vertical = dictionary[
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing
              ] as? NSNumber,
              horizontal.intValue > 0,
              vertical.intValue > 0 else {
            return nil
        }

        return VideoPixelAspectRatio(
            horizontalSpacing: horizontal.intValue,
            verticalSpacing: vertical.intValue
        )
    }

    static func stringValue(
        _ value: CMFormatDescription.Extensions.Value?
    ) -> String? {
        value?.propertyListRepresentation as? String
    }

    static func positiveInteger(
        _ value: CMFormatDescription.Extensions.Value?
    ) -> Int? {
        guard let number = value?.propertyListRepresentation as? NSNumber,
              number.intValue > 0 else {
            return nil
        }
        return number.intValue
    }

    static func booleanValue(
        _ value: CMFormatDescription.Extensions.Value?
    ) -> Bool? {
        (value?.propertyListRepresentation as? NSNumber)?.boolValue
    }

    static func positiveFinite(_ value: Float) -> Float? {
        value.isFinite && value > 0 ? value : nil
    }

    static func positiveTime(_ value: CMTime) -> CMTime? {
        let seconds = CMTimeGetSeconds(value)
        return value.isNumeric && seconds.isFinite && seconds > 0 ? value : nil
    }

    static func estimatedFrameCount(
        duration: CMTime,
        nominalFrameRate: Float?
    ) -> Int? {
        guard let nominalFrameRate else {
            return nil
        }
        let seconds = CMTimeGetSeconds(duration)
        let estimate = seconds * Double(nominalFrameRate)
        guard duration.isNumeric,
              seconds.isFinite,
              seconds >= 0,
              estimate.isFinite,
              estimate >= 0,
              let frameCount = Int(exactly: estimate.rounded()) else {
            return nil
        }
        return frameCount
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size >= 0 else {
            return nil
        }
        return Int64(size)
    }

    static func isValid(size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }

    static func valid(rect: CGRect) -> CGRect? {
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              isValid(size: rect.size) else {
            return nil
        }
        return rect
    }
}
