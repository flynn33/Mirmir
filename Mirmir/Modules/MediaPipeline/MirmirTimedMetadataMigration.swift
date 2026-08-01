import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import OSLog

enum MirmirTimedMetadataEmptyForeignBehavior: Sendable, Equatable {
    case fail
    case preserveSanitizedShell
}

struct MirmirTimedMetadataMigrationInspection: Sendable, Equatable {
    enum Classification: String, Sendable, Equatable {
        case empty
        case controlledOnly
        case foreignOnly
        case mixedControlledAndForeign
        case sanitizedShell
    }

    let sourceTrackProperties: MirmirTimedMetadataMigrationTrackProperties
    let sourceGroupCount: Int
    let foreignGroupCount: Int
    let foreignItemCount: Int
    let retainedForeignFormatEntryCount: Int
    let removedControlledItemCount: Int
    let preservedStaticItemCount: Int
    let removedControlledStaticItemCount: Int
    let isSanitizedShell: Bool
    let classification: Classification
}

struct MirmirTimedMetadataMigrationTrackProperties: Sendable, Equatable {
    let sourceTrackID: CMPersistentTrackID
    let naturalTimeScale: CMTimeScale
    let languageCode: String?
    let extendedLanguageTag: String?
    let isEnabled: Bool
    let timeRange: CMTimeRange
    let originalDestinationStart: CMTime
    let normalizedPrivateSourceCopyTimeRange: CMTimeRange
    let staticMetadataItemCount: Int
}

final class MirmirTimedMetadataMigrationResult: @unchecked Sendable {
    let assetURL: URL
    let migrationAsset: AVURLAsset
    let sanitizedTrack: AVAssetTrack
    let sourceTrackProperties: MirmirTimedMetadataMigrationTrackProperties
    let retainedGroupCount: Int
    let retainedItemCount: Int
    let retainedForeignFormatEntryCount: Int
    let retainedFormatSchema: OutputMediaMetadataFormatSchemaIdentity?
    let originalDestinationStart: CMTime
    let normalizedPrivateSourceCopyTimeRange: CMTimeRange

    private let ownedArtifact: MirmirTimedMetadataOwnedArtifact

    fileprivate init(
        assetURL: URL,
        migrationAsset: AVURLAsset,
        sanitizedTrack: AVAssetTrack,
        sourceTrackProperties: MirmirTimedMetadataMigrationTrackProperties,
        retainedGroupCount: Int,
        retainedItemCount: Int,
        retainedForeignFormatEntryCount: Int,
        retainedFormatSchema: OutputMediaMetadataFormatSchemaIdentity?,
        ownedArtifact: MirmirTimedMetadataOwnedArtifact
    ) {
        self.assetURL = assetURL
        self.migrationAsset = migrationAsset
        self.sanitizedTrack = sanitizedTrack
        self.sourceTrackProperties = sourceTrackProperties
        self.retainedGroupCount = retainedGroupCount
        self.retainedItemCount = retainedItemCount
        self.retainedForeignFormatEntryCount =
            retainedForeignFormatEntryCount
        self.retainedFormatSchema = retainedFormatSchema
        originalDestinationStart =
            sourceTrackProperties.originalDestinationStart
        normalizedPrivateSourceCopyTimeRange =
            sourceTrackProperties.normalizedPrivateSourceCopyTimeRange
        self.ownedArtifact = ownedArtifact
    }

    /// Removes the exact verified file produced by this migration. The call is
    /// idempotent and refuses to remove a replacement path entry.
    func cleanup() throws {
        try ownedArtifact.cleanup()
    }

    deinit {
        try? ownedArtifact.cleanup()
    }
}

enum MirmirTimedMetadataMigrationError: Error, Sendable, Equatable,
    LocalizedError {
    case sourceTrackIsNotMetadata(String)
    case outputURLIsNotFileURL(String)
    case outputAlreadyExists(String)
    case invalidTrackProperties(String)
    case readerFailure(stage: String, reason: String)
    case writerFailure(stage: String, reason: String)
    case unsupportedSourceFormatSpecification(String)
    case unsupportedItemRepresentation(
        groupIndex: Int?,
        itemIndex: Int,
        reason: String
    )
    case inconsistentItemIdentity(
        groupIndex: Int?,
        itemIndex: Int,
        reason: String
    )
    case unsupportedGroupTimeRange(groupIndex: Int, reason: String)
    case nonmonotonicGroupOrder(groupIndex: Int)
    case noForeignTimedMetadata
    case sourceChangedDuringMigration
    case verificationFailure(String)
    case cleanupOwnershipMismatch(String)
    case cleanupFailure(path: String, reason: String)
    case migrationFailureWithCleanupFailure(
        path: String,
        migrationReason: String,
        cleanupReason: String
    )

    var errorDescription: String? {
        switch self {
        case .sourceTrackIsNotMetadata(let mediaType):
            return "The migration source track has media type \(mediaType), not metadata."
        case .outputURLIsNotFileURL(let value):
            return "The migration output URL is not a file URL: \(value)."
        case .outputAlreadyExists(let path):
            return "The migration output already exists and was not overwritten: \(path)."
        case .invalidTrackProperties(let reason):
            return "The metadata track properties cannot be preserved: \(reason)."
        case .readerFailure(let stage, let reason):
            return "Metadata reader failure during \(stage): \(reason)."
        case .writerFailure(let stage, let reason):
            return "Metadata writer failure during \(stage): \(reason)."
        case .unsupportedSourceFormatSpecification(let reason):
            return "The source metadata format cannot be migrated safely: \(reason)."
        case .unsupportedItemRepresentation(
            let groupIndex,
            let itemIndex,
            let reason
        ):
            return "Unsupported metadata item representation at "
                + Self.location(groupIndex: groupIndex, itemIndex: itemIndex)
                + ": \(reason)."
        case .inconsistentItemIdentity(
            let groupIndex,
            let itemIndex,
            let reason
        ):
            return "Inconsistent metadata item identity at "
                + Self.location(groupIndex: groupIndex, itemIndex: itemIndex)
                + ": \(reason)."
        case .unsupportedGroupTimeRange(let groupIndex, let reason):
            return "Unsupported metadata group time range at group \(groupIndex): \(reason)."
        case .nonmonotonicGroupOrder(let groupIndex):
            return "Metadata group \(groupIndex) overlaps or precedes the prior group."
        case .noForeignTimedMetadata:
            return "The source metadata track contains no foreign timed-metadata items."
        case .sourceChangedDuringMigration:
            return "The source timed-metadata stream changed between validation and writing."
        case .verificationFailure(let reason):
            return "Reopened migration asset verification failed: \(reason)."
        case .cleanupOwnershipMismatch(let path):
            return "Cleanup refused to remove a file that replaced the owned migration at \(path)."
        case .cleanupFailure(let path, let reason):
            return "Failed to remove owned migration output at \(path): \(reason)."
        case .migrationFailureWithCleanupFailure(
            let path,
            let migrationReason,
            let cleanupReason
        ):
            return "Metadata migration failed (\(migrationReason)), and "
                + "cleanup of \(path) also failed: \(cleanupReason)."
        }
    }

    private static func location(
        groupIndex: Int?,
        itemIndex: Int
    ) -> String {
        if let groupIndex {
            return "group \(groupIndex), item \(itemIndex)"
        }
        return "static track item \(itemIndex)"
    }
}

enum MirmirTimedMetadataMigration {
    // A format hint is mandatory even when a controlled-only track is emitted
    // as an item-free shell. This reserved, controlled-like identifier is
    // valid only as the sole schema entry of that strict zero-item shell.
    static let shellCarrierIdentifier =
        "mdta/com.mirmir.preservation.track-carrier"

    private static let logger = Logger(
        subsystem: "com.mirmir.app",
        category: "TimedMetadataMigration"
    )

    static func inspect(
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) async throws -> MirmirTimedMetadataMigrationInspection {
        try validateSourceTrack(sourceTrack)
        let cancellation = MirmirTimedMetadataMigrationCancellation()
        return try await withTaskCancellationHandler {
            let prepared = try await prepare(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                emptyForeignBehavior: .preserveSanitizedShell,
                cancellation: cancellation,
                cancellationCheck: cancellationCheck
            )
            return prepared.inspection
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func migrate(
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        outputURL: URL,
        emptyForeignBehavior:
            MirmirTimedMetadataEmptyForeignBehavior = .fail,
        fileSystem: any AtomicMediaFileSystem =
            LocalAtomicMediaFileSystem(),
        cancellationCheck: @escaping @Sendable () throws -> Void = {
            try Task.checkCancellation()
        }
    ) async throws -> MirmirTimedMetadataMigrationResult {
        try validateSourceTrack(sourceTrack)
        guard outputURL.isFileURL else {
            throw MirmirTimedMetadataMigrationError.outputURLIsNotFileURL(
                outputURL.absoluteString
            )
        }
        let cancellation = MirmirTimedMetadataMigrationCancellation(
            outputURL: outputURL,
            fileSystem: fileSystem
        )
        return try await withTaskCancellationHandler {
            var reservationEstablished = false
            do {
                let prepared = try await prepare(
                    sourceAsset: sourceAsset,
                    sourceTrack: sourceTrack,
                    emptyForeignBehavior: emptyForeignBehavior,
                    cancellation: cancellation,
                    cancellationCheck: cancellationCheck
                )
                if prepared.timed.foreignItemCount == 0,
                   prepared.sourceFormat.retainedForeignFormatEntryCount == 0,
                   emptyForeignBehavior == .fail {
                    throw MirmirTimedMetadataMigrationError
                        .noForeignTimedMetadata
                }
                try reserveOutputPath(
                    outputURL,
                    fileSystem: fileSystem
                )
                reservationEstablished = true
                try await write(
                    sourceAsset: sourceAsset,
                    sourceTrack: sourceTrack,
                    prepared: prepared,
                    outputURL: outputURL,
                    cancellation: cancellation,
                    cancellationCheck: cancellationCheck
                )
                try cancellationCheck()
                let reopened = try await verify(
                    outputURL: outputURL,
                    prepared: prepared,
                    cancellation: cancellation,
                    cancellationCheck: cancellationCheck
                )
                let ownedArtifact = try MirmirTimedMetadataOwnedArtifact(
                    url: outputURL,
                    fileSystem: fileSystem
                )
                cancellation.clearPartialOwnership()
                return MirmirTimedMetadataMigrationResult(
                    assetURL: outputURL,
                    migrationAsset: reopened.asset,
                    sanitizedTrack: reopened.track,
                    sourceTrackProperties: prepared.trackProperties,
                    retainedGroupCount: prepared.timed.foreignGroupCount,
                    retainedItemCount: prepared.timed.foreignItemCount,
                    retainedForeignFormatEntryCount:
                        prepared.sourceFormat
                            .retainedForeignFormatEntryCount,
                    retainedFormatSchema:
                        prepared.sourceFormat.retainedFormatSchema,
                    ownedArtifact: ownedArtifact
                )
            } catch {
                let migrationFailure = error
                cancellation.cancel()
                var cleanupFailure: String?
                if reservationEstablished {
                    let cleanup = cancellation
                        .cleanupOwnedPartialOutputIfPresent()
                    cleanupFailure = cleanup.failureReason
                    if cleanup.discardReservation {
                        do {
                            try fileSystem
                                .discardTransactionTemporaryFileReservation(
                                    at: outputURL
                                )
                        } catch {
                            let reservationFailure =
                                "ownership reservation cleanup failed: "
                                + String(describing: error)
                            cleanupFailure = cleanupFailure.map {
                                $0 + "; " + reservationFailure
                            } ?? reservationFailure
                        }
                    }
                    if let cleanupFailure {
                        logger.error(
                            "Migration partial-output cleanup failed: \(cleanupFailure, privacy: .public)"
                        )
                        throw MirmirTimedMetadataMigrationError
                            .migrationFailureWithCleanupFailure(
                                path: outputURL.path,
                                migrationReason:
                                    String(describing: migrationFailure),
                                cleanupReason: cleanupFailure
                            )
                    }
                }
                if migrationFailure is CancellationError {
                    throw CancellationError()
                }
                throw migrationFailure
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func prepare(
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        emptyForeignBehavior: MirmirTimedMetadataEmptyForeignBehavior,
        cancellation: MirmirTimedMetadataMigrationCancellation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> PreparedMigration {
        try cancellationCheck()
        let properties = try await loadTrackProperties(
            sourceTrack,
            cancellationCheck: cancellationCheck
        )
        let sourceFormat = try await validateSourceFormatDescriptions(
            sourceTrack,
            cancellationCheck: cancellationCheck
        )
        let staticPlan = try await makeStaticMetadataPlan(
            properties.metadata,
            cancellationCheck: cancellationCheck
        )
        let timed = try await preflightTimedStream(
            asset: sourceAsset,
            track: sourceTrack,
            trackTimeRange: properties.timeRange,
            emptyForeignBehavior: emptyForeignBehavior,
            sourceFormat: sourceFormat,
            cancellation: cancellation,
            cancellationCheck: cancellationCheck
        )
        let expectedSampleFormatBindings = try
            expectedOutputSampleFormatBindings(
                asset: sourceAsset,
                track: sourceTrack,
                sourceFormat: sourceFormat,
                timed: timed,
                cancellationCheck: cancellationCheck
            )
        let inspection = MirmirTimedMetadataMigrationInspection(
            sourceTrackProperties: trackProperties(properties),
            sourceGroupCount: timed.sourceGroupCount,
            foreignGroupCount: timed.foreignGroupCount,
            foreignItemCount: timed.foreignItemCount,
            retainedForeignFormatEntryCount:
                sourceFormat.retainedForeignFormatEntryCount,
            removedControlledItemCount: timed.controlledItemCount,
            preservedStaticItemCount: staticPlan.items.count,
            removedControlledStaticItemCount:
                staticPlan.controlledItemCount,
            isSanitizedShell: sourceFormat.isSanitizedShell,
            classification: classification(
                foreignCount: timed.foreignItemCount,
                controlledCount: timed.controlledItemCount,
                hasRetainedForeignFormat:
                    sourceFormat.retainedForeignFormatEntryCount > 0,
                isSanitizedShell: sourceFormat.isSanitizedShell
            )
        )
        return PreparedMigration(
            properties: properties,
            staticPlan: staticPlan,
            timed: timed,
            inspection: inspection,
            sourceFormat: sourceFormat,
            expectedSampleFormatBindings: expectedSampleFormatBindings,
            emptyForeignBehavior: emptyForeignBehavior
        )
    }

    private static func expectedOutputSampleFormatBindings(
        asset: AVAsset,
        track: AVAssetTrack,
        sourceFormat: SourceFormatInspection,
        timed: TimedStreamPreflight,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) throws -> OutputMediaMetadataSampleFormatBindingIdentity {
        if sourceFormat.requiresPerDescriptionSampleCopy {
            let sourceBindings = try
                OutputMediaMetadataSampleFormatBindingIdentityReader.read(
                    asset: asset,
                    track: track,
                    cancellationCheck: cancellationCheck
                )
            var sanitizedIdentityBySourceIdentity: [Data: Data] = [:]
            for mapping in sourceFormat.mappings {
                guard let sanitizedDescription =
                        mapping.sanitizedDescription else {
                    throw MirmirTimedMetadataMigrationError
                        .unsupportedSourceFormatSpecification(
                            "a multi-description source has no deterministic sanitized sample-format mapping"
                        )
                }
                let sanitizedIdentity = try
                    OutputMediaMetadataFormatSchemaIdentityReader
                    .canonicalFormatDescription(sanitizedDescription)
                if let existing = sanitizedIdentityBySourceIdentity[
                    mapping.sourceIdentity
                ], existing != sanitizedIdentity {
                    throw MirmirTimedMetadataMigrationError
                        .unsupportedSourceFormatSpecification(
                            "indistinguishable source format descriptions map to different sanitized descriptions"
                        )
                }
                sanitizedIdentityBySourceIdentity[mapping.sourceIdentity] =
                    sanitizedIdentity
            }
            let expectedBindings = try sourceBindings
                .canonicalFormatDescriptionsBySample.map { sourceIdentity in
                    guard let sanitizedIdentity =
                            sanitizedIdentityBySourceIdentity[
                                sourceIdentity
                            ] else {
                        throw MirmirTimedMetadataMigrationError
                            .unsupportedSourceFormatSpecification(
                                "a metadata sample uses an undeclared source format description"
                            )
                    }
                    return sanitizedIdentity
                }
            return OutputMediaMetadataSampleFormatBindingIdentity(
                canonicalFormatDescriptionsBySample: expectedBindings
            )
        }

        let outputDescription = try sourceFormat
            .retainedForeignFormatDescription
            ?? makeFormatDescription(
                timed.formatIdentities,
                useShellCarrier: timed.foreignItemCount == 0
            )
        let outputIdentity = try
            OutputMediaMetadataFormatSchemaIdentityReader
            .canonicalFormatDescription(outputDescription)
        return OutputMediaMetadataSampleFormatBindingIdentity(
            canonicalFormatDescriptionsBySample: Array(
                repeating: outputIdentity,
                count: timed.outputGroupCount
            )
        )
    }

    private static func validateSourceTrack(
        _ sourceTrack: AVAssetTrack
    ) throws {
        guard sourceTrack.mediaType == .metadata else {
            throw MirmirTimedMetadataMigrationError.sourceTrackIsNotMetadata(
                sourceTrack.mediaType.rawValue
            )
        }
    }

    private static func reserveOutputPath(
        _ outputURL: URL,
        fileSystem: any AtomicMediaFileSystem
    ) throws {
        do {
            _ = try fileSystem.reclaimTransactionTemporaryFile(
                at: outputURL
            )
        } catch {
            let isPreservedCollision: Bool
            if let outputError = error as? AtomicMediaOutputError {
                switch outputError {
                case .unownedTemporaryFilePreserved:
                    isPreservedCollision = true
                case .unsafeTemporaryFile:
                    isPreservedCollision = fileSystem
                        .pathEntryExists(at: outputURL)
                default:
                    isPreservedCollision = false
                }
            } else {
                isPreservedCollision = false
            }
            if isPreservedCollision {
                throw MirmirTimedMetadataMigrationError
                    .outputAlreadyExists(outputURL.path)
            }
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "sibling-path reservation",
                reason: String(describing: error)
            )
        }
    }

    private static func loadTrackProperties(
        _ track: AVAssetTrack,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> TrackProperties {
        try cancellationCheck()
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        let languageCode = try await track.load(.languageCode)
        let extendedLanguageTag = try await track.load(.extendedLanguageTag)
        let isEnabled = try await track.load(.isEnabled)
        let timeRange = try await track.load(.timeRange)
        let metadata = try await track.load(.metadata)
        try cancellationCheck()
        guard naturalTimeScale > 0 else {
            throw MirmirTimedMetadataMigrationError.invalidTrackProperties(
                "natural timescale is \(naturalTimeScale)"
            )
        }
        guard isSupportedTimeRange(timeRange) else {
            throw MirmirTimedMetadataMigrationError.invalidTrackProperties(
                "time range is invalid, indefinite, negative, or nonzero-epoch"
            )
        }
        return TrackProperties(
            trackID: track.trackID,
            naturalTimeScale: naturalTimeScale,
            languageCode: languageCode,
            extendedLanguageTag: extendedLanguageTag,
            isEnabled: isEnabled,
            timeRange: timeRange,
            metadata: metadata
        )
    }

    private static func validateSourceFormatDescriptions(
        _ track: AVAssetTrack,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> SourceFormatInspection {
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedSourceFormatSpecification(
                    "the track has no metadata format description"
                )
        }
        var declaredIdentifiers: [String] = []
        var keyTableEntryCount = 0
        var retainedKeyLists: [[NSDictionary]] = []
        var sourceIdentities: [Data] = []
        var sourceLocalIDSets: [Set<UInt32>] = []
        for description in descriptions {
            try cancellationCheck()
            guard CMFormatDescriptionGetMediaSubType(description)
                    == kCMMetadataFormatType_Boxed else {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "only boxed metadata format descriptions are supported"
                    )
            }
            guard let extensions = CMFormatDescriptionGetExtensions(
                description
            ) as NSDictionary?,
                  let keyTable = extensions[
                    kCMFormatDescriptionExtensionKey_MetadataKeyTable
                        as String
                  ] as? NSDictionary else {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "boxed metadata key table is missing"
                    )
            }
            keyTableEntryCount += keyTable.count
            sourceIdentities.append(
                try OutputMediaMetadataFormatSchemaIdentityReader
                    .canonicalFormatDescription(description)
            )
            declaredIdentifiers.append(
                contentsOf:
                    (CMMetadataFormatDescriptionGetIdentifiers(
                        description
                    ) as? [String]) ?? []
            )
            var retainedKeys: [NSDictionary] = []
            var sourceLocalIDs: Set<UInt32> = []
            for (rawLocalID, rawSpecification) in keyTable {
                try cancellationCheck()
                guard let specification = rawSpecification as? NSDictionary else {
                    throw MirmirTimedMetadataMigrationError
                        .unsupportedSourceFormatSpecification(
                            "metadata key-table entry is not a dictionary"
                        )
                }
                let localIDKey =
                    kCMMetadataFormatDescriptionKey_LocalID as String
                guard let tableLocalID = metadataTableLocalID(rawLocalID),
                      let entryLocalID = (
                        specification[localIDKey] as? NSNumber
                      )?.uint32Value,
                      tableLocalID == entryLocalID else {
                    throw MirmirTimedMetadataMigrationError
                        .unsupportedSourceFormatSpecification(
                            "metadata key-table local IDs are missing or inconsistent"
                        )
                }
                sourceLocalIDs.insert(tableLocalID)
                let identifier = metadataIdentifier(
                    fromKeyTableEntry: specification
                )
                if let identifier,
                   isControlledOrControlledLike(identifier) {
                    continue
                }
                retainedKeys.append(specification)
            }
            retainedKeys.sort(by: metadataKeyEntrySort)
            retainedKeyLists.append(retainedKeys)
            sourceLocalIDSets.append(sourceLocalIDs)
        }
        let carrierCount = declaredIdentifiers.filter {
            $0 == shellCarrierIdentifier
        }.count
        if carrierCount > 0 {
            guard keyTableEntryCount == 1,
                  carrierCount == 1,
                  declaredIdentifiers == [shellCarrierIdentifier],
                  isExactShellFormat(descriptions) else {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "the preservation carrier must be the only declared format identifier"
                    )
            }
            let schema = try OutputMediaMetadataFormatSchemaIdentityReader
                .read(descriptions)
            return SourceFormatInspection(
                isSanitizedShell: true,
                mappings: [
                    SourceFormatMapping(
                        sourceIdentity: sourceIdentities[0],
                        sanitizedDescription: descriptions[0],
                        isBoundaryCarrier: false
                    )
                ],
                sanitizedFormatDescriptions: descriptions,
                retainedForeignFormatEntryCount: 0,
                retainedFormatSchema: schema,
                retainedFormatCompatibilityIdentities: []
            )
        }
        var mappings: [SourceFormatMapping] = []
        var sanitizedDescriptions: [CMMetadataFormatDescription] = []
        var compatibilityIdentities:
            Set<TimedMetadataFormatCompatibilityIdentity> = []
        for index in descriptions.indices {
            let retainedKeys = retainedKeyLists[index]
            let reconstructed: CMMetadataFormatDescription?
            let isBoundaryCarrier: Bool
            if retainedKeys.isEmpty {
                if descriptions.count > 1 {
                    reconstructed = try makeBoundaryCarrierFormatDescription(
                        sourceIdentity: sourceIdentities[index],
                        occupiedLocalIDs: sourceLocalIDSets[index]
                    )
                    isBoundaryCarrier = true
                } else {
                    reconstructed = nil
                    isBoundaryCarrier = false
                }
            } else {
                reconstructed = try makeRetainedFormatDescription(
                    retainedKeys
                )
                isBoundaryCarrier = false
            }
            if let reconstructed {
                if !isBoundaryCarrier {
                    guard let reconstructedKeyTable = metadataKeyTable(
                        from: reconstructed
                    ) else {
                        throw MirmirTimedMetadataMigrationError
                            .unsupportedSourceFormatSpecification(
                                "the reconstructed sanitized format has no metadata key table"
                            )
                    }
                    let sourceDeclarationIdentity = try
                        canonicalMetadataKeyEntries(retainedKeys)
                    let reconstructedDeclarationIdentity = try
                        canonicalMetadataKeyEntries(
                            reconstructedKeyTable.allValues.compactMap {
                                $0 as? NSDictionary
                            }
                        )
                    guard reconstructedKeyTable.count
                            == reconstructedDeclarationIdentity.count,
                          sourceDeclarationIdentity
                            == reconstructedDeclarationIdentity else {
                        throw MirmirTimedMetadataMigrationError
                            .unsupportedSourceFormatSpecification(
                                "sanitized metadata declarations changed while reconstructing its source format description"
                            )
                    }
                    compatibilityIdentities.formUnion(
                        try metadataFormatCompatibilityIdentities(
                            from: reconstructed
                        )
                    )
                }
                sanitizedDescriptions.append(reconstructed)
            }
            mappings.append(SourceFormatMapping(
                sourceIdentity: sourceIdentities[index],
                sanitizedDescription: reconstructed,
                isBoundaryCarrier: isBoundaryCarrier
            ))
        }
        let retainedFormatSchema = sanitizedDescriptions.isEmpty
            ? nil
            : try OutputMediaMetadataFormatSchemaIdentityReader.read(
                sanitizedDescriptions
            )
        let retainedEntryCount = retainedKeyLists.reduce(0) {
            $0 + $1.count
        }
        return SourceFormatInspection(
            isSanitizedShell: false,
            mappings: mappings,
            sanitizedFormatDescriptions: sanitizedDescriptions,
            retainedForeignFormatEntryCount: retainedEntryCount,
            retainedFormatSchema: retainedFormatSchema,
            retainedFormatCompatibilityIdentities: compatibilityIdentities
        )
    }

    private static func makeRetainedFormatDescription(
        _ retainedKeys: [NSDictionary]
    ) throws -> CMMetadataFormatDescription? {
        guard !retainedKeys.isEmpty else { return nil }
        var description: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithKeys(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            keys: retainedKeys as CFArray,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedSourceFormatSpecification(
                    "the sanitized metadata key table could not be reconstructed (CoreMedia status \(status))"
                )
        }
        return description
    }

    private static func makeBoundaryCarrierFormatDescription(
        sourceIdentity: Data,
        occupiedLocalIDs: Set<UInt32>
    ) throws -> CMMetadataFormatDescription {
        let suffix = SHA256.hash(data: sourceIdentity).map {
            String(format: "%02x", $0)
        }.joined()
        let carrierIdentity = TimedMetadataFormatIdentity(
            identifier:
                "mdta/org.mirmir.preservation.boundary.\(suffix)",
            dataType: kCMMetadataBaseDataType_UTF8 as String,
            extendedLanguageTag: nil
        )
        let base = try makeFormatDescription(
            Set([carrierIdentity]),
            useShellCarrier: false
        )
        guard let baseTable = metadataKeyTable(from: base),
              let rawEntry = baseTable.allValues.first as? NSDictionary,
              let entry = rawEntry.mutableCopy() as? NSMutableDictionary else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedSourceFormatSpecification(
                    "the boundary-carrier key table could not be reconstructed"
                )
        }
        var localID: UInt32 = 1
        while occupiedLocalIDs.contains(localID) {
            guard localID < UInt32.max else {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "the source format consumes every boundary-carrier local ID"
                    )
            }
            localID += 1
        }
        guard localID <= UInt32(Int32.max) else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedSourceFormatSpecification(
                    "the source format consumes every stable boundary-carrier local ID"
                )
        }
        entry[
            kCMMetadataFormatDescriptionKey_LocalID as String
        ] = NSNumber(value: Int32(localID))
        var result: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithKeys(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            keys: [entry] as CFArray,
            formatDescriptionOut: &result
        )
        guard status == noErr, let result else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedSourceFormatSpecification(
                    "the deterministic boundary carrier could not be created (CoreMedia status \(status))"
                )
        }
        return result
    }

    private static func metadataKeyTable(
        from description: CMFormatDescription
    ) -> NSDictionary? {
        let extensions = CMFormatDescriptionGetExtensions(description)
            as NSDictionary?
        return extensions?[
            kCMFormatDescriptionExtensionKey_MetadataKeyTable as String
        ] as? NSDictionary
    }

    private static func metadataKeyEntrySort(
        _ lhs: NSDictionary,
        _ rhs: NSDictionary
    ) -> Bool {
        let key = kCMMetadataFormatDescriptionKey_LocalID as String
        let lhsID = (lhs[key] as? NSNumber)?.uint32Value ?? 0
        let rhsID = (rhs[key] as? NSNumber)?.uint32Value ?? 0
        if lhsID != rhsID { return lhsID < rhsID }
        let lhsIdentifier = metadataIdentifier(fromKeyTableEntry: lhs) ?? ""
        let rhsIdentifier = metadataIdentifier(fromKeyTableEntry: rhs) ?? ""
        return lhsIdentifier < rhsIdentifier
    }

    private static func metadataTableLocalID(_ value: Any) -> UInt32? {
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        if let string = value as? String {
            return UInt32(string)
        }
        if let string = value as? NSString {
            return UInt32(string as String)
        }
        return nil
    }

    private static func canonicalMetadataKeyEntries(
        _ entries: [NSDictionary]
    ) throws -> [Data] {
        var canonical = try entries.map {
            try MediaPreservationCanonicalEncoder.encode($0)
        }
        canonical.sort { $0.lexicographicallyPrecedes($1) }
        return canonical
    }

    private static func metadataFormatCompatibilityIdentities(
        from description: CMFormatDescription
    ) throws -> Set<TimedMetadataFormatCompatibilityIdentity> {
        guard let keyTable = metadataKeyTable(from: description) else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedSourceFormatSpecification(
                    "the retained boxed metadata format has no key table"
                )
        }
        var identities: Set<TimedMetadataFormatCompatibilityIdentity> = []
        for rawEntry in keyTable.allValues {
            guard let entry = rawEntry as? NSDictionary,
                  let identity = metadataFormatCompatibilityIdentity(
                    from: entry
                  ) else {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "a retained metadata declaration cannot be matched safely to decoded items"
                    )
            }
            identities.insert(identity)
        }
        return identities
    }

    private static func metadataFormatCompatibilityIdentity(
        for identity: TimedMetadataFormatIdentity
    ) throws -> TimedMetadataFormatCompatibilityIdentity {
        let description = try makeFormatDescription(
            [identity],
            useShellCarrier: false
        )
        let identities = try metadataFormatCompatibilityIdentities(
            from: description
        )
        guard identities.count == 1, let result = identities.first else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedSourceFormatSpecification(
                    "the decoded metadata item format could not be represented uniquely"
                )
        }
        return result
    }

    private static func metadataFormatCompatibilityIdentity(
        from entry: NSDictionary
    ) -> TimedMetadataFormatCompatibilityIdentity? {
        let namespaceKey =
            kCMMetadataFormatDescriptionKey_Namespace as String
        let valueKey = kCMMetadataFormatDescriptionKey_Value as String
        guard let namespace = entry[namespaceKey] as? NSNumber,
              let value = metadataFormatData(entry[valueKey]) else {
            return nil
        }
        let dataTypeKey =
            kCMMetadataFormatDescriptionKey_DataType as String
        let dataTypeNamespaceKey =
            kCMMetadataFormatDescriptionKey_DataTypeNamespace as String
        let languageKey =
            kCMMetadataFormatDescriptionKey_LanguageTag as String
        return TimedMetadataFormatCompatibilityIdentity(
            namespace: namespace.uint32Value,
            value: value,
            dataType: metadataFormatData(entry[dataTypeKey]),
            dataTypeNamespace:
                (entry[dataTypeNamespaceKey] as? NSNumber)?.int32Value,
            languageTag: entry[languageKey] as? String
        )
    }

    private static func metadataFormatData(_ value: Any?) -> Data? {
        if let value = value as? Data { return value }
        if let value = value as? NSData { return value as Data }
        return nil
    }

    static func isExactShellFormat(
        _ descriptions: [CMFormatDescription]
    ) -> Bool {
        guard descriptions.count == 1,
              let description = descriptions.first,
              CMFormatDescriptionGetMediaSubType(description)
                == kCMMetadataFormatType_Boxed,
              (CMMetadataFormatDescriptionGetIdentifiers(description)
                as? [String]) == [shellCarrierIdentifier],
              let extensions = CMFormatDescriptionGetExtensions(
                description
              ) as NSDictionary?,
              let keyTable = extensions[
                kCMFormatDescriptionExtensionKey_MetadataKeyTable
                    as String
              ] as? NSDictionary,
              keyTable.count == 1 else {
            return false
        }
        guard let expectedDescription = try? makeFormatDescription(
            [],
            useShellCarrier: true
        ),
              let expected = try?
                OutputMediaMetadataFormatSchemaIdentityReader.read(
                    [expectedDescription]
                ),
              let actual = try?
                OutputMediaMetadataFormatSchemaIdentityReader.read(
                    descriptions
                ) else {
            return false
        }
        return actual == expected
    }

    private static func metadataIdentifier(
        fromKeyTableEntry entry: NSDictionary
    ) -> String? {
        guard let namespaceNumber = entry[
            kCMMetadataFormatDescriptionKey_Namespace as String
        ] as? NSNumber else {
            return nil
        }
        let rawKeyData = entry[
            kCMMetadataFormatDescriptionKey_Value as String
        ]
        let keyData: Data
        if let value = rawKeyData as? Data {
            keyData = value
        } else if let value = rawKeyData as? NSData {
            keyData = value as Data
        } else {
            return nil
        }
        guard
              let key = String(data: keyData, encoding: .utf8) else {
            return nil
        }
        let rawNamespace = namespaceNumber.uint32Value
        let namespaceBytes: [UInt8] = [
            UInt8((rawNamespace >> 24) & 0xff),
            UInt8((rawNamespace >> 16) & 0xff),
            UInt8((rawNamespace >> 8) & 0xff),
            UInt8(rawNamespace & 0xff)
        ]
        guard namespaceBytes.allSatisfy({ 0x20...0x7e ~= $0 }),
              let namespace = String(
                bytes: namespaceBytes,
                encoding: .ascii
              ) else {
            return nil
        }
        return "\(namespace)/\(key)"
    }

    private static func makeStaticMetadataPlan(
        _ items: [AVMetadataItem],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> StaticMetadataPlan {
        var copies: [MirmirTimedMetadataItemBox] = []
        var canonicalItems: [Data] = []
        var controlledItemCount = 0
        for (itemIndex, item) in items.enumerated() {
            try cancellationCheck()
            let identity = try validatedIdentity(
                item,
                groupIndex: nil,
                itemIndex: itemIndex
            )
            if identity.identifier == shellCarrierIdentifier {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "the preservation carrier appeared as a static "
                            + "metadata item"
                    )
            }
            let canonical = try await loadedFullCanonicalIdentity(
                item,
                groupIndex: nil,
                itemIndex: itemIndex
            )
            if isControlledOrControlledLike(identity.identifier) {
                controlledItemCount += 1
                continue
            }
            copies.append(
                try loadedMutableCopy(
                    item,
                    groupIndex: nil,
                    itemIndex: itemIndex
                )
            )
            canonicalItems.append(canonical)
        }
        canonicalItems.sort { $0.lexicographicallyPrecedes($1) }
        return StaticMetadataPlan(
            items: copies,
            identity: OutputMediaMetadataIdentity(
                canonicalItems: canonicalItems
            ),
            controlledItemCount: controlledItemCount
        )
    }

    private static func preflightTimedStream(
        asset: AVAsset,
        track: AVAssetTrack,
        trackTimeRange: CMTimeRange,
        emptyForeignBehavior: MirmirTimedMetadataEmptyForeignBehavior,
        sourceFormat: SourceFormatInspection,
        cancellation: MirmirTimedMetadataMigrationCancellation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> TimedStreamPreflight {
        var digest = TimedMetadataStreamDigest()
        var sourceDigest = TimedMetadataStreamDigest()
        var formatIdentities: Set<TimedMetadataFormatIdentity> = []
        var sourceGroupCount = 0
        var foreignGroupCount = 0
        var foreignItemCount = 0
        var controlledItemCount = 0
        var outputGroupCount = 0
        var sourceItemCount = 0
        var shellGroupMatchesTrackEnvelope = false
        var previousSourceEnd: CMTime?

        try await enumerateTimedGroups(
            asset: asset,
            track: track,
            stage: "source preflight",
            cancellation: cancellation,
            cancellationCheck: cancellationCheck
        ) { groupIndex, group in
            try validateGroupTimeRange(
                group.timeRange,
                groupIndex: groupIndex,
                trackTimeRange: trackTimeRange,
                previousSourceEnd: previousSourceEnd
            )
            previousSourceEnd = group.timeRange.end
            sourceGroupCount += 1
            sourceItemCount += group.items.count
            if sourceFormat.isSanitizedShell {
                guard group.items.isEmpty else {
                    throw MirmirTimedMetadataMigrationError
                        .unsupportedSourceFormatSpecification(
                            "the preservation carrier decoded as a metadata item"
                        )
                }
                if sourceGroupCount == 1 {
                    shellGroupMatchesTrackEnvelope =
                        SemanticTimeRange(group.timeRange)
                        == SemanticTimeRange(trackTimeRange)
                }
            }
            var retainedCanonicalItems: [Data] = []
            var sourceCanonicalItems: [Data] = []
            for (itemIndex, item) in group.items.enumerated() {
                try cancellationCheck()
                let identity = try validatedIdentity(
                    item,
                    groupIndex: groupIndex,
                    itemIndex: itemIndex
                )
                let canonical = try await loadedFullCanonicalIdentity(
                    item,
                    groupIndex: groupIndex,
                    itemIndex: itemIndex
                )
                sourceCanonicalItems.append(canonical)
                if isControlledOrControlledLike(identity.identifier) {
                    controlledItemCount += 1
                    continue
                }
                retainedCanonicalItems.append(canonical)
                formatIdentities.insert(
                    TimedMetadataFormatIdentity(identity)
                )
                foreignItemCount += 1
            }
            let mappedGroupRange = migrationTimelineRange(
                group.timeRange,
                sourceTrackStart: trackTimeRange.start
            )
            sourceDigest.appendGroup(
                timeRange: mappedGroupRange,
                canonicalItems: sourceCanonicalItems
            )
            digest.appendGroup(
                timeRange: mappedGroupRange,
                canonicalItems: retainedCanonicalItems
            )
            outputGroupCount += 1
            if !retainedCanonicalItems.isEmpty {
                foreignGroupCount += 1
            }
        }

        if sourceFormat.isSanitizedShell {
            guard sourceGroupCount == 1,
                  sourceItemCount == 0,
                  shellGroupMatchesTrackEnvelope else {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "a sanitized preservation shell must contain exactly "
                            + "one decoded zero-item group spanning the track "
                            + "time range"
                    )
            }
        }

        for identity in formatIdentities {
            let compatibility = try metadataFormatCompatibilityIdentity(
                for: identity
            )
            guard sourceFormat.retainedFormatCompatibilityIdentities
                    .contains(compatibility) else {
                throw MirmirTimedMetadataMigrationError
                    .unsupportedSourceFormatSpecification(
                        "retained decoded item \(identity.identifier) with data type \(identity.dataType) and language \(identity.extendedLanguageTag ?? "<none>") is absent from the sanitized source format declaration"
                    )
            }
        }

        if foreignItemCount == 0,
           sourceFormat.retainedForeignFormatEntryCount == 0,
           emptyForeignBehavior == .preserveSanitizedShell {
            digest = TimedMetadataStreamDigest()
            digest.appendGroup(
                timeRange: migrationTimelineRange(
                    trackTimeRange,
                    sourceTrackStart: trackTimeRange.start
                ),
                canonicalItems: []
            )
            outputGroupCount = 1
        }

        return TimedStreamPreflight(
            digest: digest.finalize(),
            sourceDigest: sourceDigest.finalize(),
            formatIdentities: formatIdentities,
            sourceGroupCount: sourceGroupCount,
            foreignGroupCount: foreignGroupCount,
            foreignItemCount: foreignItemCount,
            controlledItemCount: controlledItemCount,
            outputGroupCount: outputGroupCount
        )
    }

    private static func write(
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        prepared: PreparedMigration,
        outputURL: URL,
        cancellation: MirmirTimedMetadataMigrationCancellation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        if prepared.sourceFormat.requiresPerDescriptionSampleCopy {
            try await writeByCopyingSamplesAndReplacingDescriptions(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                prepared: prepared,
                outputURL: outputURL,
                cancellation: cancellation,
                cancellationCheck: cancellationCheck
            )
            return
        }
        try await writeUsingMetadataAdaptor(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            prepared: prepared,
            outputURL: outputURL,
            cancellation: cancellation,
            cancellationCheck: cancellationCheck
        )
    }

    private static func writeByCopyingSamplesAndReplacingDescriptions(
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        prepared: PreparedMigration,
        outputURL: URL,
        cancellation: MirmirTimedMetadataMigrationCancellation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        try cancellationCheck()
        let currentSourceFormat = try await validateSourceFormatDescriptions(
            sourceTrack,
            cancellationCheck: cancellationCheck
        )
        guard try sourceFormatPlansAreEqual(
            currentSourceFormat,
            prepared.sourceFormat
        ) else {
            throw MirmirTimedMetadataMigrationError
                .sourceChangedDuringMigration
        }
        let currentTimed = try await preflightTimedStream(
            asset: sourceAsset,
            track: sourceTrack,
            trackTimeRange: prepared.properties.timeRange,
            emptyForeignBehavior: prepared.emptyForeignBehavior,
            sourceFormat: currentSourceFormat,
            cancellation: cancellation,
            cancellationCheck: cancellationCheck
        )
        guard timedPreflightsAreEqual(currentTimed, prepared.timed) else {
            throw MirmirTimedMetadataMigrationError
                .sourceChangedDuringMigration
        }
        let currentExpectedSampleFormatBindings = try
            expectedOutputSampleFormatBindings(
                asset: sourceAsset,
                track: sourceTrack,
                sourceFormat: currentSourceFormat,
                timed: currentTimed,
                cancellationCheck: cancellationCheck
            )
        guard currentExpectedSampleFormatBindings
                == prepared.expectedSampleFormatBindings else {
            throw MirmirTimedMetadataMigrationError
                .sourceChangedDuringMigration
        }

        let movie = AVMutableMovie()
        movie.timescale = prepared.properties.naturalTimeScale
        movie.defaultMediaDataStorage = AVMediaDataStorage(
            url: outputURL,
            options: nil
        )
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: .metadata,
            copySettingsFrom: sourceTrack,
            options: nil
        ) else {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "sample-copy track creation",
                reason: "the mutable movie rejected the metadata track"
            )
        }
        destinationTrack.timescale = prepared.properties.naturalTimeScale
        destinationTrack.languageCode = prepared.properties.languageCode
        destinationTrack.extendedLanguageTag =
            prepared.properties.extendedLanguageTag
        destinationTrack.isEnabled = prepared.properties.isEnabled
        destinationTrack.metadata = prepared.staticPlan.items.map(\.item)
        do {
            try destinationTrack.insertTimeRange(
                prepared.properties.timeRange,
                of: sourceTrack,
                at: .zero,
                copySampleData: true
            )
        } catch {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "sample-data copy",
                reason: String(describing: error)
            )
        }
        do {
            try cancellation.claimCurrentOutputForPartialCleanup()
        } catch {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "partial-output ownership",
                reason: String(describing: error)
            )
        }

        let copiedDescriptions = try await destinationTrack.load(
            .formatDescriptions
        )
        var remainingMappings = Array(
            prepared.sourceFormat.mappings.indices
        )
        for copiedDescription in copiedDescriptions {
            try cancellationCheck()
            let copiedIdentity = try
                OutputMediaMetadataFormatSchemaIdentityReader
                .canonicalFormatDescription(copiedDescription)
            guard let remainingOffset = remainingMappings.firstIndex(
                where: {
                    prepared.sourceFormat.mappings[$0].sourceIdentity
                        == copiedIdentity
                }
            ) else {
                throw MirmirTimedMetadataMigrationError.writerFailure(
                    stage: "format-description replacement",
                    reason: "the copied track contains an undeclared metadata format description"
                )
            }
            let mappingIndex = remainingMappings.remove(
                at: remainingOffset
            )
            guard let sanitized = prepared.sourceFormat
                .mappings[mappingIndex].sanitizedDescription else {
                throw MirmirTimedMetadataMigrationError.writerFailure(
                    stage: "format-description replacement",
                    reason: "a multi-description source has no deterministic sanitized replacement"
                )
            }
            destinationTrack.replaceFormatDescription(
                copiedDescription,
                with: sanitized
            )
        }
        for mappingIndex in remainingMappings {
            try cancellationCheck()
            guard let sanitizedDescription = prepared.sourceFormat
                    .mappings[mappingIndex].sanitizedDescription else {
                throw MirmirTimedMetadataMigrationError.writerFailure(
                    stage: "format-description anchoring",
                    reason: "an omitted source format description has no deterministic sanitized replacement"
                )
            }
            try appendUnboundFormatDescriptionAnchor(
                sanitizedDescription,
                to: destinationTrack,
                naturalTimeScale: prepared.properties.naturalTimeScale
            )
        }
        do {
            try movie.writeHeader(
                to: outputURL,
                fileType: .mov,
                options: .addMovieHeaderToDestination
            )
        } catch {
            try? cancellation.claimCurrentOutputForPartialCleanup()
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "movie-header write",
                reason: String(describing: error)
            )
        }
        try cancellation.claimCurrentOutputForPartialCleanup()
        try cancellationCheck()
        withExtendedLifetime(sourceAsset) {}
    }

    private static func appendUnboundFormatDescriptionAnchor(
        _ description: CMMetadataFormatDescription,
        to track: AVMutableMovieTrack,
        naturalTimeScale: CMTimeScale
    ) throws {
        do {
            try OutputMediaMetadataFormatDescriptionAnchorWriter.append(
                description,
                to: track,
                naturalTimeScale: naturalTimeScale
            )
        } catch {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "format-description anchoring",
                reason: String(describing: error)
            )
        }
    }

    private static func sourceFormatPlansAreEqual(
        _ lhs: SourceFormatInspection,
        _ rhs: SourceFormatInspection
    ) throws -> Bool {
        guard lhs.isSanitizedShell == rhs.isSanitizedShell,
              lhs.retainedForeignFormatEntryCount
                == rhs.retainedForeignFormatEntryCount,
              lhs.retainedFormatSchema == rhs.retainedFormatSchema,
              lhs.mappings.count == rhs.mappings.count else {
            return false
        }
        for (left, right) in zip(lhs.mappings, rhs.mappings) {
            guard left.sourceIdentity == right.sourceIdentity,
                  left.isBoundaryCarrier == right.isBoundaryCarrier else {
                return false
            }
            let leftSanitized = try left.sanitizedDescription.map {
                try OutputMediaMetadataFormatSchemaIdentityReader
                    .canonicalFormatDescription($0)
            }
            let rightSanitized = try right.sanitizedDescription.map {
                try OutputMediaMetadataFormatSchemaIdentityReader
                    .canonicalFormatDescription($0)
            }
            guard leftSanitized == rightSanitized else { return false }
        }
        return true
    }

    private static func timedPreflightsAreEqual(
        _ lhs: TimedStreamPreflight,
        _ rhs: TimedStreamPreflight
    ) -> Bool {
        lhs.digest == rhs.digest
            && lhs.sourceDigest == rhs.sourceDigest
            && lhs.formatIdentities == rhs.formatIdentities
            && lhs.sourceGroupCount == rhs.sourceGroupCount
            && lhs.foreignGroupCount == rhs.foreignGroupCount
            && lhs.foreignItemCount == rhs.foreignItemCount
            && lhs.controlledItemCount == rhs.controlledItemCount
            && lhs.outputGroupCount == rhs.outputGroupCount
    }

    private static func writeUsingMetadataAdaptor(
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        prepared: PreparedMigration,
        outputURL: URL,
        cancellation: MirmirTimedMetadataMigrationCancellation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        try cancellationCheck()
        let formatDescription = try prepared.sourceFormat
            .retainedForeignFormatDescription
            ?? makeFormatDescription(
                prepared.timed.formatIdentities,
                useShellCarrier:
                    prepared.timed.foreignItemCount == 0
            )
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "creation",
                reason: String(describing: error)
            )
        }
        cancellation.replaceWriter(writer)
        defer { cancellation.clearWriter(writer) }
        do {
            try cancellation.claimCurrentOutputForPartialCleanup()
        } catch {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "partial-output ownership",
                reason: String(describing: error)
            )
        }
        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = prepared.properties.naturalTimeScale
        input.languageCode = prepared.properties.languageCode
        input.extendedLanguageTag = prepared.properties.extendedLanguageTag
        input.marksOutputTrackAsEnabled = prepared.properties.isEnabled
        input.metadata = prepared.staticPlan.items.map(\.item)
        guard writer.canAdd(input) else {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "configuration",
                reason: "writer rejected metadata input"
            )
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputMetadataAdaptor(
            assetWriterInput: input
        )
        let startedWriting = writer.startWriting()
        do {
            try cancellation.claimCurrentOutputForPartialCleanup()
        } catch {
            writer.cancelWriting()
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "partial-output ownership",
                reason: String(describing: error)
            )
        }
        guard startedWriting else {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "start",
                reason: writer.error?.localizedDescription
                    ?? "startWriting returned false"
            )
        }
        writer.startSession(
            atSourceTime: prepared.properties.timeRange.start
        )

        var digest = TimedMetadataStreamDigest()
        var sourceDigest = TimedMetadataStreamDigest()
        var secondPassFormats: Set<TimedMetadataFormatIdentity> = []
        var outputGroupCount = 0
        var sourceGroupCount = 0
        var sourceItemCount = 0
        var shellGroupMatchesTrackEnvelope = false
        var previousSourceEnd: CMTime?
        let writesSanitizedSourceGroups =
            prepared.timed.foreignItemCount > 0
                || prepared.sourceFormat
                    .retainedForeignFormatEntryCount > 0
        try await enumerateTimedGroups(
            asset: sourceAsset,
            track: sourceTrack,
            stage: "source write pass",
            cancellation: cancellation,
            cancellationCheck: cancellationCheck
        ) { groupIndex, group in
            try validateGroupTimeRange(
                group.timeRange,
                groupIndex: groupIndex,
                trackTimeRange: prepared.properties.timeRange,
                previousSourceEnd: previousSourceEnd
            )
            previousSourceEnd = group.timeRange.end
            sourceGroupCount += 1
            sourceItemCount += group.items.count
            if prepared.inspection.isSanitizedShell {
                guard group.items.isEmpty else {
                    throw MirmirTimedMetadataMigrationError
                        .sourceChangedDuringMigration
                }
                if sourceGroupCount == 1 {
                    shellGroupMatchesTrackEnvelope =
                        SemanticTimeRange(group.timeRange)
                        == SemanticTimeRange(
                            prepared.properties.timeRange
                        )
                }
            }
            var retained: [MirmirTimedMetadataItemBox] = []
            var canonicalItems: [Data] = []
            var sourceCanonicalItems: [Data] = []
            for (itemIndex, item) in group.items.enumerated() {
                try cancellationCheck()
                let identity = try validatedIdentity(
                    item,
                    groupIndex: groupIndex,
                    itemIndex: itemIndex
                )
                let canonical = try await loadedFullCanonicalIdentity(
                    item,
                    groupIndex: groupIndex,
                    itemIndex: itemIndex
                )
                sourceCanonicalItems.append(canonical)
                if isControlledOrControlledLike(identity.identifier) {
                    continue
                }
                let formatIdentity = TimedMetadataFormatIdentity(identity)
                guard prepared.timed.formatIdentities.contains(
                    formatIdentity
                ) else {
                    throw MirmirTimedMetadataMigrationError
                        .sourceChangedDuringMigration
                }
                secondPassFormats.insert(formatIdentity)
                retained.append(
                    try loadedMutableCopy(
                        item,
                        groupIndex: groupIndex,
                        itemIndex: itemIndex
                    )
                )
                canonicalItems.append(canonical)
            }
            let mappedGroupRange = migrationTimelineRange(
                group.timeRange,
                sourceTrackStart: prepared.properties.timeRange.start
            )
            sourceDigest.appendGroup(
                timeRange: mappedGroupRange,
                canonicalItems: sourceCanonicalItems
            )
            guard writesSanitizedSourceGroups else { return }
            try await append(
                retained,
                timeRange: group.timeRange,
                input: input,
                adaptor: adaptor,
                writer: writer,
                cancellationCheck: cancellationCheck
            )
            digest.appendGroup(
                timeRange: mappedGroupRange,
                canonicalItems: canonicalItems
            )
            outputGroupCount += 1
        }

        if prepared.inspection.isSanitizedShell {
            guard sourceGroupCount == 1,
                  sourceItemCount == 0,
                  shellGroupMatchesTrackEnvelope else {
                throw MirmirTimedMetadataMigrationError
                    .sourceChangedDuringMigration
            }
        }

        if !writesSanitizedSourceGroups,
           prepared.emptyForeignBehavior
                    == .preserveSanitizedShell {
            try await append(
                [],
                timeRange: prepared.properties.timeRange,
                input: input,
                adaptor: adaptor,
                writer: writer,
                cancellationCheck: cancellationCheck
            )
            digest.appendGroup(
                timeRange: migrationTimelineRange(
                    prepared.properties.timeRange,
                    sourceTrackStart: prepared.properties.timeRange.start
                ),
                canonicalItems: []
            )
            outputGroupCount = 1
        }

        guard sourceDigest.finalize() == prepared.timed.sourceDigest,
              sourceGroupCount == prepared.timed.sourceGroupCount,
              digest.finalize() == prepared.timed.digest,
              outputGroupCount == prepared.timed.outputGroupCount,
              secondPassFormats == prepared.timed.formatIdentities else {
            throw MirmirTimedMetadataMigrationError
                .sourceChangedDuringMigration
        }
        writer.endSession(
            atSourceTime: prepared.properties.timeRange.end
        )
        input.markAsFinished()
        await writer.finishWriting()
        try cancellationCheck()
        guard writer.status == .completed else {
            if writer.status == .cancelled { throw CancellationError() }
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "finish",
                reason: writer.error?.localizedDescription
                    ?? "writer status \(writer.status.rawValue)"
            )
        }
    }

    private static func append(
        _ items: [MirmirTimedMetadataItemBox],
        timeRange: CMTimeRange,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputMetadataAdaptor,
        writer: AVAssetWriter,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try cancellationCheck()
            guard writer.status == .writing else {
                if writer.status == .cancelled { throw CancellationError() }
                throw MirmirTimedMetadataMigrationError.writerFailure(
                    stage: "append wait",
                    reason: writer.error?.localizedDescription
                        ?? "writer status \(writer.status.rawValue)"
                )
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try cancellationCheck()
        let group = AVTimedMetadataGroup(
            items: items.map(\.item),
            timeRange: timeRange
        )
        guard adaptor.append(group) else {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "append group",
                reason: writer.error?.localizedDescription
                    ?? "metadata adaptor rejected group"
            )
        }
    }

    private static func makeFormatDescription(
        _ identities: Set<TimedMetadataFormatIdentity>,
        useShellCarrier: Bool
    ) throws -> CMMetadataFormatDescription {
        var specifications = identities.sorted {
            if $0.identifier != $1.identifier {
                return $0.identifier < $1.identifier
            }
            if $0.dataType != $1.dataType {
                return $0.dataType < $1.dataType
            }
            return ($0.extendedLanguageTag ?? "")
                < ($1.extendedLanguageTag ?? "")
        }.map(\.specification)
        if useShellCarrier {
            specifications = [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                    as String: shellCarrierIdentifier,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                    as String: kCMMetadataBaseDataType_UTF8 as String
            ]]
        }
        guard !specifications.isEmpty else {
            throw MirmirTimedMetadataMigrationError.noForeignTimedMetadata
        }
        var description: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw MirmirTimedMetadataMigrationError.writerFailure(
                stage: "format description",
                reason: "CoreMedia status \(status)"
            )
        }
        return description
    }

    private static func verify(
        outputURL: URL,
        prepared: PreparedMigration,
        cancellation: MirmirTimedMetadataMigrationCancellation,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> ReopenedMigration {
        try cancellationCheck()
        let asset = AVURLAsset(url: outputURL)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        guard tracks.count == 1, let track = tracks.first else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "expected one metadata track, found \(tracks.count)"
            )
        }
        let actualTimeScale = try await track.load(.naturalTimeScale)
        let actualLanguageCode = try await track.load(.languageCode)
        let actualExtendedLanguageTag = try await track.load(
            .extendedLanguageTag
        )
        let actualIsEnabled = try await track.load(.isEnabled)
        let actualTimeRange = try await track.load(.timeRange)
        guard actualTimeScale == prepared.properties.naturalTimeScale,
              actualLanguageCode == prepared.properties.languageCode,
              actualExtendedLanguageTag
                == prepared.properties.extendedLanguageTag,
              actualIsEnabled == prepared.properties.isEnabled else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "basic track properties changed"
            )
        }
        let expectedMigrationTimeRange = migrationTimelineRange(
            prepared.properties.timeRange,
            sourceTrackStart: prepared.properties.timeRange.start
        )
        guard SemanticTimeRange(actualTimeRange)
                == SemanticTimeRange(expectedMigrationTimeRange) else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "track time range changed from "
                    + "\(SemanticTimeRange(expectedMigrationTimeRange).debugDescription) "
                    + "to \(SemanticTimeRange(actualTimeRange).debugDescription)"
            )
        }

        let actualStaticMetadata = try await track.load(.metadata)
        let actualStaticIdentity = try await canonicalStaticIdentity(
            actualStaticMetadata,
            cancellationCheck: cancellationCheck
        )
        guard actualStaticIdentity == prepared.staticPlan.identity else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "sanitized static metadata changed"
            )
        }
        for item in actualStaticMetadata {
            guard let identifier = item.identifier?.rawValue,
                  !isControlledOrControlledLike(identifier) else {
                throw MirmirTimedMetadataMigrationError.verificationFailure(
                    "controlled-like static metadata remains"
                )
            }
        }

        var digest = TimedMetadataStreamDigest()
        var groupCount = 0
        try await enumerateTimedGroups(
            asset: asset,
            track: track,
            stage: "reopen verification",
            cancellation: cancellation,
            cancellationCheck: cancellationCheck
        ) { groupIndex, group in
            try cancellationCheck()
            var canonicalItems: [Data] = []
            for (itemIndex, item) in group.items.enumerated() {
                let identity = try validatedIdentity(
                    item,
                    groupIndex: groupIndex,
                    itemIndex: itemIndex
                )
                guard !isControlledOrControlledLike(identity.identifier) else {
                    throw MirmirTimedMetadataMigrationError
                        .verificationFailure(
                            "controlled-like identifier remains: \(identity.identifier)"
                        )
                }
                canonicalItems.append(
                    try await loadedFullCanonicalIdentity(
                        item,
                        groupIndex: groupIndex,
                        itemIndex: itemIndex
                    )
                )
            }
            digest.appendGroup(
                timeRange: group.timeRange,
                canonicalItems: canonicalItems
            )
            groupCount += 1
        }
        guard digest.finalize() == prepared.timed.digest,
              groupCount == prepared.timed.outputGroupCount else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "stream timing, order, item identity, or boundary groups changed"
            )
        }

        let formatDescriptions = try await track.load(.formatDescriptions)
        let identifiers = formatDescriptions.flatMap {
            (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String]) ?? []
        }
        let shellMode = !prepared.sourceFormat
            .requiresPerDescriptionSampleCopy
            && prepared.timed.foreignItemCount == 0
            && prepared.sourceFormat.retainedForeignFormatEntryCount == 0
        guard !shellMode || isExactShellFormat(formatDescriptions) else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "the sanitized shell format is not the exact sole carrier"
            )
        }
        guard identifiers.allSatisfy({ identifier in
            !isControlledOrControlledLike(identifier)
                || (shellMode && identifier == shellCarrierIdentifier)
        }) else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "a controlled-like identifier remains in the output format description"
            )
        }
        let expectedIdentifiers: Set<String>
        if shellMode {
            expectedIdentifiers = [shellCarrierIdentifier]
        } else if !prepared.sourceFormat
            .sanitizedFormatDescriptions.isEmpty {
            expectedIdentifiers = Set(
                prepared.sourceFormat.sanitizedFormatDescriptions
                    .flatMap {
                        (CMMetadataFormatDescriptionGetIdentifiers($0)
                            as? [String]) ?? []
                    }
            )
        } else {
            expectedIdentifiers = Set(
                prepared.timed.formatIdentities.map(\.identifier)
            )
        }
        guard Set(identifiers) == expectedIdentifiers else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "format-description identifiers differ from the sanitized schema"
            )
        }
        if let expectedSchema = prepared.sourceFormat.retainedFormatSchema {
            let actualSchema = try
                OutputMediaMetadataFormatSchemaIdentityReader.read(
                    formatDescriptions
                )
            guard actualSchema == expectedSchema else {
                throw MirmirTimedMetadataMigrationError
                    .verificationFailure(
                        "declared metadata schema differs from the sanitized source schema"
                    )
            }
        }
        let actualSampleFormatBindings = try
            OutputMediaMetadataSampleFormatBindingIdentityReader.read(
                asset: asset,
                track: track,
                cancellationCheck: cancellationCheck
            )
        guard actualSampleFormatBindings
                == prepared.expectedSampleFormatBindings else {
            throw MirmirTimedMetadataMigrationError.verificationFailure(
                "metadata sample-format bindings differ from the sanitized source bindings"
            )
        }
        return ReopenedMigration(asset: asset, track: track)
    }

    private static func enumerateTimedGroups(
        asset: AVAsset,
        track: AVAssetTrack,
        stage: String,
        cancellation: MirmirTimedMetadataMigrationCancellation,
        cancellationCheck: @escaping @Sendable () throws -> Void,
        body: (Int, AVTimedMetadataGroup) async throws -> Void
    ) async throws {
        try cancellationCheck()
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MirmirTimedMetadataMigrationError.readerFailure(
                stage: stage,
                reason: "creation failed: \(error)"
            )
        }
        cancellation.replaceReader(reader)
        defer { cancellation.clearReader(reader) }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            throw MirmirTimedMetadataMigrationError.readerFailure(
                stage: stage,
                reason: "reader rejected metadata track output"
            )
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(
            assetReaderTrackOutput: output
        )
        guard reader.startReading() else {
            throw MirmirTimedMetadataMigrationError.readerFailure(
                stage: stage,
                reason: reader.error?.localizedDescription
                    ?? "startReading returned false"
            )
        }
        do {
            var groupIndex = 0
            while true {
                try cancellationCheck()
                guard let group = adaptor.nextTimedMetadataGroup() else {
                    break
                }
                for _ in group.items { try cancellationCheck() }
                try await body(groupIndex, group)
                groupIndex += 1
            }
            try cancellationCheck()
        } catch {
            reader.cancelReading()
            throw error
        }
        guard reader.status == .completed else {
            if reader.status == .cancelled { throw CancellationError() }
            throw MirmirTimedMetadataMigrationError.readerFailure(
                stage: stage,
                reason: reader.error?.localizedDescription
                    ?? "reader ended with status \(reader.status.rawValue)"
            )
        }
    }

    private static func validateGroupTimeRange(
        _ timeRange: CMTimeRange,
        groupIndex: Int,
        trackTimeRange: CMTimeRange,
        previousSourceEnd: CMTime?
    ) throws {
        guard isSupportedTimeRange(timeRange) else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedGroupTimeRange(
                    groupIndex: groupIndex,
                    reason: "range is invalid, indefinite, negative, or nonzero-epoch"
                )
        }
        guard CMTimeCompare(timeRange.start, trackTimeRange.start) >= 0,
              CMTimeCompare(timeRange.end, trackTimeRange.end) <= 0 else {
            throw MirmirTimedMetadataMigrationError
                .unsupportedGroupTimeRange(
                    groupIndex: groupIndex,
                    reason: "group lies outside the source track time range"
                )
        }
        if let previousSourceEnd,
           CMTimeCompare(timeRange.start, previousSourceEnd) < 0 {
            throw MirmirTimedMetadataMigrationError
                .nonmonotonicGroupOrder(groupIndex: groupIndex)
        }
    }

    private static func validatedIdentity(
        _ item: AVMetadataItem,
        groupIndex: Int?,
        itemIndex: Int
    ) throws -> TimedMetadataItemIdentity {
        guard let identifier = item.identifier?.rawValue,
              !identifier.isEmpty else {
            throw inconsistent(groupIndex, itemIndex, "identifier is missing")
        }
        guard let keySpace = item.keySpace,
              let key = item.key else {
            throw inconsistent(
                groupIndex,
                itemIndex,
                "key or keySpace is missing for \(identifier)"
            )
        }
        guard key is NSString || key is NSNumber || key is NSData else {
            throw unsupported(
                groupIndex,
                itemIndex,
                "key type \(String(reflecting: type(of: key))) is not writable"
            )
        }
        guard let derivedIdentifier = AVMetadataItem.identifier(
            forKey: key,
            keySpace: keySpace
        )?.rawValue else {
            throw inconsistent(
                groupIndex,
                itemIndex,
                "identifier cannot be derived from key/keySpace"
            )
        }
        guard derivedIdentifier == identifier else {
            throw inconsistent(
                groupIndex,
                itemIndex,
                "identifier \(identifier) differs from derived \(derivedIdentifier)"
            )
        }
        guard let dataType = item.dataType, !dataType.isEmpty else {
            throw unsupported(groupIndex, itemIndex, "dataType is missing")
        }
        return TimedMetadataItemIdentity(
            identifier: identifier,
            keySpace: keySpace.rawValue,
            dataType: dataType,
            extendedLanguageTag: item.extendedLanguageTag
        )
    }

    private static func loadedFullCanonicalIdentity(
        _ item: AVMetadataItem,
        groupIndex: Int?,
        itemIndex: Int
    ) async throws -> Data {
        do {
            _ = try await item.load(.value)
            _ = try await item.load(.extraAttributes)
            guard let identity = try await
                    MediaPreservationMetadataIdentityReader.read([item])
                    .canonicalItems.first else {
                throw MirmirTimedMetadataMigrationError.verificationFailure(
                    "canonical metadata identity is empty"
                )
            }
            return identity
        } catch let error as MirmirTimedMetadataMigrationError {
            throw error
        } catch {
            throw unsupported(
                groupIndex,
                itemIndex,
                "full semantic encoding failed: \(error)"
            )
        }
    }

    private static func loadedMutableCopy(
        _ item: AVMetadataItem,
        groupIndex: Int?,
        itemIndex: Int
    ) throws -> MirmirTimedMetadataItemBox {
        guard let copy = item.mutableCopy() as? AVMutableMetadataItem else {
            throw unsupported(
                groupIndex,
                itemIndex,
                "mutableCopy did not return AVMutableMetadataItem"
            )
        }
        return MirmirTimedMetadataItemBox(copy)
    }

    private static func canonicalStaticIdentity(
        _ items: [AVMetadataItem],
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) async throws -> OutputMediaMetadataIdentity {
        var canonicalItems: [Data] = []
        for (itemIndex, item) in items.enumerated() {
            try cancellationCheck()
            canonicalItems.append(
                try await loadedFullCanonicalIdentity(
                    item,
                    groupIndex: nil,
                    itemIndex: itemIndex
                )
            )
        }
        canonicalItems.sort { $0.lexicographicallyPrecedes($1) }
        return OutputMediaMetadataIdentity(canonicalItems: canonicalItems)
    }

    private static func classification(
        foreignCount: Int,
        controlledCount: Int,
        hasRetainedForeignFormat: Bool,
        isSanitizedShell: Bool
    ) -> MirmirTimedMetadataMigrationInspection.Classification {
        if isSanitizedShell { return .sanitizedShell }
        switch (
            foreignCount > 0 || hasRetainedForeignFormat,
            controlledCount > 0
        ) {
        case (false, false): return .empty
        case (false, true): return .controlledOnly
        case (true, false): return .foreignOnly
        case (true, true): return .mixedControlledAndForeign
        }
    }

    private static func trackProperties(
        _ properties: TrackProperties
    ) -> MirmirTimedMetadataMigrationTrackProperties {
        MirmirTimedMetadataMigrationTrackProperties(
            sourceTrackID: properties.trackID,
            naturalTimeScale: properties.naturalTimeScale,
            languageCode: properties.languageCode,
            extendedLanguageTag: properties.extendedLanguageTag,
            isEnabled: properties.isEnabled,
            timeRange: properties.timeRange,
            originalDestinationStart: properties.timeRange.start,
            normalizedPrivateSourceCopyTimeRange: migrationTimelineRange(
                properties.timeRange,
                sourceTrackStart: properties.timeRange.start
            ),
            staticMetadataItemCount: properties.metadata.count
        )
    }

    private static func isSupportedTimeRange(
        _ timeRange: CMTimeRange
    ) -> Bool {
        timeRange.isValid
            && timeRange.start.isNumeric
            && timeRange.duration.isNumeric
            && timeRange.start.epoch == 0
            && timeRange.duration.epoch == 0
            && CMTimeCompare(timeRange.start, .zero) >= 0
            && CMTimeCompare(timeRange.duration, .zero) >= 0
    }

    static func migrationTimelineRange(
        _ sourceRange: CMTimeRange,
        sourceTrackStart: CMTime
    ) -> CMTimeRange {
        CMTimeRange(
            start: CMTimeSubtract(sourceRange.start, sourceTrackStart),
            duration: sourceRange.duration
        )
    }

    private static func isControlledOrControlledLike(
        _ identifier: String
    ) -> Bool {
        MirmirTimedMetadataPolicy.isControlledIdentifier(identifier)
            || MirmirTimedMetadataPolicy.resemblesControlledIdentifier(
                identifier
            )
    }

    private static func inconsistent(
        _ groupIndex: Int?,
        _ itemIndex: Int,
        _ reason: String
    ) -> MirmirTimedMetadataMigrationError {
        .inconsistentItemIdentity(
            groupIndex: groupIndex,
            itemIndex: itemIndex,
            reason: reason
        )
    }

    private static func unsupported(
        _ groupIndex: Int?,
        _ itemIndex: Int,
        _ reason: String
    ) -> MirmirTimedMetadataMigrationError {
        .unsupportedItemRepresentation(
            groupIndex: groupIndex,
            itemIndex: itemIndex,
            reason: reason
        )
    }
}

enum OutputMediaMetadataFormatDescriptionAnchorError:
    Error,
    CustomStringConvertible {
    case invalidMediaType
    case blockBufferCreationFailed(OSStatus)
    case payloadCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case appendFailed(String)

    var description: String {
        switch self {
        case .invalidMediaType:
            return "the anchor format description is not metadata"
        case .blockBufferCreationFailed(let status):
            return "anchor block-buffer creation failed "
                + "(CoreMedia status \(status))"
        case .payloadCreationFailed(let status):
            return "anchor payload creation failed "
                + "(CoreMedia status \(status))"
        case .sampleBufferCreationFailed(let status):
            return "anchor sample-buffer creation failed "
                + "(CoreMedia status \(status))"
        case .appendFailed(let reason):
            return "anchor append failed: \(reason)"
        }
    }
}

enum OutputMediaMetadataFormatDescriptionAnchorWriter {
    /// AVAssetWriterInputMetadataAdaptor's boxed-metadata encoding for an
    /// AVTimedMetadataGroup with zero items. This was verified independently
    /// against an adaptor-produced sample in the migration test suite.
    static let zeroItemGroupPayload = Data([
        0x00, 0x00, 0x00, 0x08,
        0x00, 0x00, 0x00, 0x00
    ])

    /// Appends a self-contained media sample without adding a track edit.
    /// This keeps an otherwise unbound metadata format description in the
    /// serialized sample-description table without making the anchor visible
    /// to track readers or timed-metadata adaptors.
    static func append(
        _ description: CMMetadataFormatDescription,
        to track: AVMutableMovieTrack,
        naturalTimeScale: CMTimeScale
    ) throws {
        guard CMFormatDescriptionGetMediaType(description)
                == kCMMediaType_Metadata else {
            throw OutputMediaMetadataFormatDescriptionAnchorError
                .invalidMediaType
        }
        var blockBuffer: CMBlockBuffer?
        let payload = zeroItemGroupPayload
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr,
              let blockBuffer else {
            throw OutputMediaMetadataFormatDescriptionAnchorError
                .blockBufferCreationFailed(blockStatus)
        }
        let copyStatus = payload.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw OutputMediaMetadataFormatDescriptionAnchorError
                .payloadCreationFailed(copyStatus)
        }
        let timeScale = max(naturalTimeScale, 1)
        let mediaEnd = track.mediaPresentationTimeRange.end
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timeScale),
            presentationTimeStamp: mediaEnd.isNumeric ? mediaEnd : .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw OutputMediaMetadataFormatDescriptionAnchorError
                .sampleBufferCreationFailed(sampleStatus)
        }
        do {
            try track.append(
                sampleBuffer,
                decodeTime: nil,
                presentationTime: nil
            )
        } catch {
            throw OutputMediaMetadataFormatDescriptionAnchorError
                .appendFailed(String(describing: error))
        }
    }
}

private extension CMTimeRange {
    var end: CMTime { CMTimeAdd(start, duration) }
}

private struct PreparedMigration {
    let properties: TrackProperties
    let staticPlan: StaticMetadataPlan
    let timed: TimedStreamPreflight
    let inspection: MirmirTimedMetadataMigrationInspection
    let sourceFormat: SourceFormatInspection
    let expectedSampleFormatBindings:
        OutputMediaMetadataSampleFormatBindingIdentity
    let emptyForeignBehavior: MirmirTimedMetadataEmptyForeignBehavior

    var trackProperties: MirmirTimedMetadataMigrationTrackProperties {
        inspection.sourceTrackProperties
    }
}

private struct TrackProperties {
    let trackID: CMPersistentTrackID
    let naturalTimeScale: CMTimeScale
    let languageCode: String?
    let extendedLanguageTag: String?
    let isEnabled: Bool
    let timeRange: CMTimeRange
    let metadata: [AVMetadataItem]
}

private struct SourceFormatInspection {
    let isSanitizedShell: Bool
    let mappings: [SourceFormatMapping]
    let sanitizedFormatDescriptions: [CMMetadataFormatDescription]
    let retainedForeignFormatEntryCount: Int
    let retainedFormatSchema: OutputMediaMetadataFormatSchemaIdentity?
    let retainedFormatCompatibilityIdentities:
        Set<TimedMetadataFormatCompatibilityIdentity>

    var retainedForeignFormatDescription: CMMetadataFormatDescription? {
        guard sanitizedFormatDescriptions.count == 1 else { return nil }
        return sanitizedFormatDescriptions[0]
    }

    var requiresPerDescriptionSampleCopy: Bool {
        mappings.count > 1
    }
}

private struct SourceFormatMapping {
    let sourceIdentity: Data
    let sanitizedDescription: CMMetadataFormatDescription?
    let isBoundaryCarrier: Bool
}

private struct StaticMetadataPlan {
    let items: [MirmirTimedMetadataItemBox]
    let identity: OutputMediaMetadataIdentity
    let controlledItemCount: Int
}

private struct TimedStreamPreflight {
    let digest: Data
    let sourceDigest: Data
    let formatIdentities: Set<TimedMetadataFormatIdentity>
    let sourceGroupCount: Int
    let foreignGroupCount: Int
    let foreignItemCount: Int
    let controlledItemCount: Int
    let outputGroupCount: Int
}

private struct TimedMetadataItemIdentity: Sendable, Equatable, Hashable {
    let identifier: String
    let keySpace: String
    let dataType: String
    let extendedLanguageTag: String?
}

private struct TimedMetadataFormatIdentity: Sendable, Hashable {
    let identifier: String
    let dataType: String
    let extendedLanguageTag: String?

    init(
        identifier: String,
        dataType: String,
        extendedLanguageTag: String?
    ) {
        self.identifier = identifier
        self.dataType = dataType
        self.extendedLanguageTag = extendedLanguageTag
    }

    init(_ item: TimedMetadataItemIdentity) {
        identifier = item.identifier
        dataType = item.dataType
        extendedLanguageTag = item.extendedLanguageTag
    }

    var specification: [String: Any] {
        var value: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                as String: identifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                as String: dataType
        ]
        if let extendedLanguageTag {
            value[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_ExtendedLanguageTag
                    as String
            ] = extendedLanguageTag
        }
        return value
    }
}

private struct TimedMetadataFormatCompatibilityIdentity:
    Sendable,
    Hashable {
    let namespace: UInt32
    let value: Data
    let dataType: Data?
    let dataTypeNamespace: Int32?
    let languageTag: String?
}

private struct SemanticTimeRange: Sendable, Equatable {
    let start: CMTime
    let duration: CMTime

    init(_ value: CMTimeRange) {
        start = value.start
        duration = value.duration
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        CMTimeCompare(lhs.start, rhs.start) == 0
            && CMTimeCompare(lhs.duration, rhs.duration) == 0
    }

    var debugDescription: String {
        "start=(\(Self.describe(start))),duration=(\(Self.describe(duration)))"
    }

    private static func describe(_ time: CMTime) -> String {
        "value=\(time.value),timescale=\(time.timescale),"
            + "flags=\(time.flags.rawValue),epoch=\(time.epoch)"
    }
}

private struct TimedMetadataStreamDigest {
    private var hasher = SHA256()

    mutating func appendGroup(
        timeRange: CMTimeRange,
        canonicalItems: [Data]
    ) {
        append(UInt8(0x47))
        appendSemanticTime(timeRange.start)
        appendSemanticTime(timeRange.duration)
        for item in canonicalItems {
            append(UInt8(0x49))
            append(UInt64(item.count))
            hasher.update(data: item)
        }
        append(UInt8(0x45))
        append(UInt64(canonicalItems.count))
    }

    mutating func finalize() -> Data {
        Data(hasher.finalize())
    }

    private mutating func appendSemanticTime(_ time: CMTime) {
        var numerator = time.value
        var denominator = Int64(time.timescale)
        let divisor = greatestCommonDivisor(numerator, denominator)
        numerator /= divisor
        denominator /= divisor
        append(UInt64(bitPattern: numerator))
        append(UInt64(bitPattern: denominator))
        append(UInt64(bitPattern: time.epoch))
    }

    private func greatestCommonDivisor(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(1, a)
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            hasher.update(bufferPointer: bytes)
        }
    }
}

private struct ReopenedMigration {
    let asset: AVURLAsset
    let track: AVAssetTrack
}

private final class MirmirTimedMetadataItemBox: @unchecked Sendable {
    let item: AVMutableMetadataItem

    init(_ item: AVMutableMetadataItem) {
        self.item = item
    }
}

private final class MirmirTimedMetadataOwnedArtifact: @unchecked Sendable {
    private let url: URL
    private let verifiedFile: AtomicMediaVerifiedTemporaryFile
    private let fileSystem: any AtomicMediaFileSystem
    private let lock = NSLock()
    private var cleaned = false

    init(
        url: URL,
        fileSystem: any AtomicMediaFileSystem
    ) throws {
        self.url = url
        self.fileSystem = fileSystem
        verifiedFile = try AtomicMediaVerifiedTemporaryFile(url: url)
    }

    func cleanup() throws {
        try lock.withLock {
            guard !cleaned else { return }
            var removalFailure: Error?
            do {
                try verifiedFile.validatePathAndContents(at: url)
                let identity = try verifiedFile.makePinnedFileIdentity()
                try fileSystem.removeItem(
                    at: url,
                    ifMatchingFile: identity
                )
            } catch {
                removalFailure = error
            }

            guard fileSystem.pathEntryExists(at: url) else {
                do {
                    try fileSystem
                        .discardTransactionTemporaryFileReservation(
                            at: url
                        )
                } catch {
                    throw MirmirTimedMetadataMigrationError.cleanupFailure(
                        path: url.path,
                        reason: "ownership reservation cleanup failed: "
                            + String(describing: error)
                    )
                }
                cleaned = true
                return
            }

            do {
                try verifiedFile.validatePathAndContents(at: url)
                _ = try verifiedFile.makePinnedFileIdentity()
            } catch {
                do {
                    try fileSystem
                        .discardTransactionTemporaryFileReservation(
                            at: url
                        )
                } catch {
                    throw MirmirTimedMetadataMigrationError.cleanupFailure(
                        path: url.path,
                        reason: "ownership reservation cleanup failed after "
                            + "the owned path was replaced: "
                            + String(describing: error)
                    )
                }
                cleaned = true
                throw MirmirTimedMetadataMigrationError
                    .cleanupOwnershipMismatch(url.path)
            }

            let reason = removalFailure.map(String.init(describing:))
                ?? "path entry remains after verified removal"
            throw MirmirTimedMetadataMigrationError.cleanupFailure(
                path: url.path,
                reason: reason
                    + "; ownership reservation retained for retry"
            )
        }
    }

    deinit {
        try? cleanup()
    }
}

private struct MirmirTimedMetadataPartialCleanupResult {
    let discardReservation: Bool
    let failureReason: String?
}

private final class MirmirTimedMetadataMigrationCancellation:
    @unchecked Sendable {
    private let lock = NSLock()
    private let outputURL: URL?
    private let fileSystem: any AtomicMediaFileSystem
    private var partialOwner: AtomicMediaVerifiedTemporaryFile?
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    init(
        outputURL: URL? = nil,
        fileSystem: any AtomicMediaFileSystem =
            LocalAtomicMediaFileSystem()
    ) {
        self.outputURL = outputURL
        self.fileSystem = fileSystem
    }

    func replaceReader(_ reader: AVAssetReader) {
        lock.withLock { self.reader = reader }
    }

    func clearReader(_ reader: AVAssetReader) {
        lock.withLock {
            if self.reader === reader { self.reader = nil }
        }
    }

    func replaceWriter(_ writer: AVAssetWriter) {
        lock.withLock { self.writer = writer }
    }

    func clearWriter(_ writer: AVAssetWriter) {
        lock.withLock {
            if self.writer === writer { self.writer = nil }
        }
    }

    func claimCurrentOutputForPartialCleanup() throws {
        try lock.withLock {
            guard partialOwner == nil,
                  let outputURL,
                  fileSystem.pathEntryExists(at: outputURL) else { return }
            partialOwner = try AtomicMediaVerifiedTemporaryFile(
                url: outputURL,
                requirePopulatedFile: false
            )
        }
    }

    func clearPartialOwnership() {
        lock.withLock { partialOwner = nil }
    }

    func cleanupOwnedPartialOutputIfPresent()
        -> MirmirTimedMetadataPartialCleanupResult {
        let state = lock.withLock { (outputURL, partialOwner) }
        guard let outputURL = state.0 else {
            return MirmirTimedMetadataPartialCleanupResult(
                discardReservation: true,
                failureReason: nil
            )
        }
        guard fileSystem.pathEntryExists(at: outputURL) else {
            return MirmirTimedMetadataPartialCleanupResult(
                discardReservation: true,
                failureReason: nil
            )
        }
        guard let partialOwner = state.1 else {
            return MirmirTimedMetadataPartialCleanupResult(
                discardReservation: true,
                failureReason:
                    "an unverified path entry remains and was preserved"
            )
        }

        var removalFailure: Error?
        do {
            let identity = try partialOwner.makePinnedFileIdentity()
            try fileSystem.removeItem(
                at: outputURL,
                ifMatchingFile: identity
            )
        } catch {
            removalFailure = error
        }
        guard fileSystem.pathEntryExists(at: outputURL) else {
            return MirmirTimedMetadataPartialCleanupResult(
                discardReservation: true,
                failureReason: nil
            )
        }

        do {
            _ = try partialOwner.makePinnedFileIdentity()
            let reason = removalFailure.map(String.init(describing:))
                ?? "the owned path entry remains after verified removal"
            return MirmirTimedMetadataPartialCleanupResult(
                discardReservation: false,
                failureReason: reason
                    + "; ownership reservation retained for retry"
            )
        } catch {
            let removalReason = removalFailure.map {
                "removal failed: " + String(describing: $0) + "; "
            } ?? ""
            return MirmirTimedMetadataPartialCleanupResult(
                discardReservation: true,
                failureReason: removalReason
                    + "the current path no longer matches the owned partial "
                    + "file and was preserved: "
                    + String(describing: error)
            )
        }
    }

    func cancel() {
        let active: (AVAssetReader?, AVAssetWriter?) = lock.withLock {
            (reader, writer)
        }
        active.0?.cancelReading()
        active.1?.cancelWriting()
    }
}
