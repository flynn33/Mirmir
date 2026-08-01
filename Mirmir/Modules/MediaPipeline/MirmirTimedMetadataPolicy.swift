import AVFoundation
import CoreMedia
import Foundation

enum MirmirMetadataReplacementEligibility: Sendable, Equatable {
    case preserve
    case replace
    case migrate
}

enum MirmirTimedMetadataPolicy {
    static let namespace = "com.mirmir."
    private static let quickTimeMetadataIdentifierPrefix = "mdta/"

    static func validate(_ metadata: [String: String]) throws {
        for (key, value) in metadata {
            guard isValidKey(key) else {
                throw MediaPipelineError.outputMetadataMismatch(
                    "timed metadata key \(key) is outside the controlled \(namespace) namespace"
                )
            }
            guard !value.isEmpty else {
                throw MediaPipelineError.outputMetadataMismatch(
                    "timed metadata value for \(key) is empty"
                )
            }
        }
    }

    static func isValidKey(_ key: String) -> Bool {
        guard key.hasPrefix(namespace),
              key.count > namespace.count else {
            return false
        }
        return key.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    static func isReplaceableSourceIdentityTrack(
        mediaType: AVMediaType,
        formatDescriptions: [CMFormatDescription]
    ) -> Bool {
        sourceIdentityFormatEligibility(
            mediaType: mediaType,
            formatDescriptions: formatDescriptions
        ) == .replace
    }

    static func sourceIdentityFormatEligibility(
        mediaType: AVMediaType,
        formatDescriptions: [CMFormatDescription]
    ) -> MirmirMetadataReplacementEligibility {
        guard mediaType == .metadata,
              !formatDescriptions.isEmpty else {
            return .preserve
        }

        var foundControlledIdentifier = false
        var foundForeignIdentifier = false
        var foundUnknownIdentity = false
        for description in formatDescriptions {
            guard CMFormatDescriptionGetMediaSubType(description)
                    == kCMMetadataFormatType_Boxed else {
                foundUnknownIdentity = true
                continue
            }
            guard let identifiers =
                    CMMetadataFormatDescriptionGetIdentifiers(description)
                        as? [String],
                  !identifiers.isEmpty else {
                foundUnknownIdentity = true
                continue
            }
            for identifier in identifiers {
                if isControlledIdentifier(identifier) {
                    foundControlledIdentifier = true
                } else if resemblesControlledIdentifier(identifier) {
                    foundControlledIdentifier = true
                    foundUnknownIdentity = true
                } else {
                    foundForeignIdentifier = true
                }
            }
        }

        guard foundControlledIdentifier else {
            return .preserve
        }
        if foundUnknownIdentity {
            return .migrate
        }
        if foundForeignIdentifier {
            return .migrate
        }
        return .replace
    }

    static func isControlledIdentifier(
        _ identifier: String
    ) -> Bool {
        guard identifier.hasPrefix(
            quickTimeMetadataIdentifierPrefix
        ) else {
            return false
        }
        return isValidKey(
            String(
                identifier.dropFirst(
                    quickTimeMetadataIdentifierPrefix.count
                )
            )
        )
    }

    static func resemblesControlledIdentifier(
        _ identifier: String
    ) -> Bool {
        identifier.hasPrefix(
            quickTimeMetadataIdentifierPrefix + namespace
        ) || identifier.hasPrefix(namespace)
    }

    static func controlledLikeIdentifier(
        for item: AVMetadataItem
    ) -> String? {
        var candidates: [String] = []
        if let identifier = item.identifier?.rawValue {
            candidates.append(identifier)
        }
        let key: String?
        if let value = item.key as? String {
            key = value
        } else if let value = item.key as? NSString {
            key = value as String
        } else {
            key = nil
        }
        if let key {
            if item.keySpace == .quickTimeMetadata {
                candidates.append(
                    quickTimeMetadataIdentifierPrefix + key
                )
            }
            candidates.append(key)
        }
        return candidates.first { identifier in
            isControlledIdentifier(identifier)
                || resemblesControlledIdentifier(identifier)
        }
    }

    static func removingControlledStaticMetadata(
        from items: [AVMetadataItem]
    ) -> [AVMetadataItem] {
        items.filter { controlledLikeIdentifier(for: $0) == nil }
    }

    static func containerMetadataForPreservation(
        from items: [AVMetadataItem]
    ) -> [AVMetadataItem] {
        removingControlledStaticMetadata(from: items).filter { item in
            // The encoding-tool item describes the software that produced
            // the source container. Copying it after Mirmir rewrites the
            // video would falsely attribute the new output to that tool.
            item.identifier != .iTunesMetadataEncodingTool
        }
    }

    static func hasExplicitTrackLanguage(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.caseInsensitiveCompare("und") != .orderedSame
    }

    static func associationParticipantIDs(
        in tracks: [AVAssetTrack]
    ) async throws -> Set<CMPersistentTrackID> {
        let preservedTrackIDs = Set(tracks.map(\.trackID))
        var result: Set<CMPersistentTrackID> = []
        for sourceTrack in tracks {
            try Task.checkCancellation()
            let associationTypes = try await sourceTrack.load(
                .availableTrackAssociationTypes
            )
            for associationType in associationTypes {
                let targets = try await sourceTrack.loadAssociatedTracks(
                    ofType: associationType
                )
                let preservedTargets = targets.filter {
                    preservedTrackIDs.contains($0.trackID)
                }
                guard !preservedTargets.isEmpty else { continue }
                result.insert(sourceTrack.trackID)
                result.formUnion(preservedTargets.map(\.trackID))
            }
        }
        return result
    }
}
