import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

final class MirmirTimedMetadataMigrationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(
               atPath: temporaryDirectory.path
           ) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testMigrationPreservesForeignGroupsAndTrackProperties() async throws {
        let controlled = metadataItem(
            key: "com.mirmir.release.backend-id",
            value: "controlled" as NSString
        )
        let controlledLike = metadataItem(
            key: "com.mirmir.",
            value: "controlled-like" as NSString
        )
        let foreignAlpha = metadataItem(
            key: "com.example.alpha",
            value: "alpha" as NSString,
            extendedLanguageTag: "en-US"
        )
        let foreignBeta = metadataItem(
            key: "com.example.beta",
            value: Data([0x01, 0x7f, 0xff]) as NSData,
            dataType: kCMMetadataBaseDataType_RawData as String
        )
        let foreignGamma = metadataItem(
            key: "com.example.gamma",
            value: "gamma" as NSString
        )
        foreignGamma.locale = Locale(identifier: "de_DE")
        let groups = [
            timedGroup(
                items: [controlled, foreignAlpha],
                start: 0,
                duration: 300
            ),
            timedGroup(
                items: [foreignBeta, controlledLike],
                start: 300,
                duration: 150
            ),
            timedGroup(
                items: [controlled],
                start: 450,
                duration: 150
            ),
            timedGroup(
                items: [foreignGamma],
                start: 600,
                duration: 600
            )
        ]
        let staticItem = metadataItem(
            key: "com.example.static",
            value: "static-value" as NSString,
            extendedLanguageTag: "fr-CA"
        )
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "mixed-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: groups,
            staticMetadata: [staticItem]
        )

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "migration.mov"
        )
        let contentsBeforeInspection = try Set(
            FileManager.default.contentsOfDirectory(
                atPath: temporaryDirectory.path
            )
        )
        let inspection = try await MirmirTimedMetadataMigration.inspect(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack
        )
        XCTAssertEqual(inspection.sourceGroupCount, 4)
        XCTAssertEqual(inspection.foreignGroupCount, 3)
        XCTAssertEqual(inspection.foreignItemCount, 3)
        XCTAssertEqual(inspection.removedControlledItemCount, 3)
        XCTAssertEqual(inspection.classification, .mixedControlledAndForeign)
        XCTAssertEqual(
            try Set(
                FileManager.default.contentsOfDirectory(
                    atPath: temporaryDirectory.path
                )
            ),
            contentsBeforeInspection,
            "Inspect-only preflight must not create an artifact."
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )

        XCTAssertEqual(result.assetURL, outputURL)
        XCTAssertEqual(result.retainedGroupCount, 3)
        XCTAssertEqual(result.retainedItemCount, 3)
        XCTAssertEqual(result.sourceTrackProperties.naturalTimeScale, 600)
        XCTAssertEqual(result.sourceTrackProperties.languageCode, "eng")
        XCTAssertEqual(
            result.sourceTrackProperties.extendedLanguageTag,
            "en-US"
        )
        XCTAssertTrue(result.sourceTrackProperties.isEnabled)
        XCTAssertEqual(
            result.sourceTrackProperties.staticMetadataItemCount,
            1
        )
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(
                result.originalDestinationStart,
                sourceTimeRange.start
            ),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(
                result.normalizedPrivateSourceCopyTimeRange.start,
                .zero
            ),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(
                result.normalizedPrivateSourceCopyTimeRange.duration,
                sourceTimeRange.duration
            ),
            0
        )

        let migratedAsset = result.migrationAsset
        let migratedTrack = result.sanitizedTrack
        XCTAssertEqual(migratedTrack.mediaType, .metadata)
        let migratedGroups = try readGroups(
            asset: migratedAsset,
            track: migratedTrack
        )
        XCTAssertEqual(migratedGroups.count, 4)
        XCTAssertEqual(
            migratedGroups.map(\.timeRange),
            groups.map(\.timeRange)
        )
        XCTAssertEqual(
            migratedGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            [
                "mdta/com.example.alpha",
                "mdta/com.example.beta",
                "mdta/com.example.gamma"
            ]
        )
        XCTAssertTrue(
            migratedGroups.flatMap(\.items).allSatisfy { item in
                guard let identifier = item.identifier?.rawValue else {
                    return false
                }
                return !MirmirTimedMetadataPolicy.isControlledIdentifier(
                    identifier
                ) && !MirmirTimedMetadataPolicy
                    .resemblesControlledIdentifier(identifier)
            }
        )
        let migratedValues = try await migratedGroups.flatMap(\.items)
            .asyncMap { try await $0.load(.value) }
        XCTAssertEqual(migratedValues[0] as? String, "alpha")
        XCTAssertEqual(migratedValues[1] as? Data, Data([0x01, 0x7f, 0xff]))
        XCTAssertEqual(migratedValues[2] as? String, "gamma")
        XCTAssertEqual(
            migratedGroups[3].items[0].locale?.identifier,
            "de-DE"
        )

        let staticMetadata = try await migratedTrack.load(.metadata)
        XCTAssertEqual(staticMetadata.count, 1)
        XCTAssertEqual(
            staticMetadata[0].identifier?.rawValue,
            "mdta/com.example.static"
        )
        let staticValue = try await staticMetadata[0].load(.stringValue)
        XCTAssertEqual(staticValue, "static-value")
        XCTAssertEqual(staticMetadata[0].extendedLanguageTag, "fr-CA")
        try result.cleanup()
        try result.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationPreservesControlledLeadingAndTrailingTimelineEdges()
        async throws {
        let groups = [
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.mirmir.release.leading",
                        value: "leading" as NSString
                    )
                ],
                start: 0,
                duration: 300
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.example.middle",
                        value: "middle" as NSString
                    )
                ],
                start: 300,
                duration: 300
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.mirmir.release.trailing",
                        value: "trailing" as NSString
                    )
                ],
                start: 600,
                duration: 300
            )
        ]
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "nonzero-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: groups,
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "nonzero-migration.mov"
        )

        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputTimeRange = try await result.sanitizedTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(outputTimeRange.start, sourceTimeRange.start),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(outputTimeRange.duration, sourceTimeRange.duration),
            0
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(outputGroups.count, 3)
        XCTAssertTrue(outputGroups[0].items.isEmpty)
        XCTAssertEqual(
            outputGroups[1].items.first?.identifier?.rawValue,
            "mdta/com.example.middle"
        )
        XCTAssertTrue(outputGroups[2].items.isEmpty)
        try result.cleanup()
    }

    func testMigrationDoesNotMaterializeLeadingEditAsMetadataGroup()
        async throws {
        let sourceGroups = [
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.example.delayed",
                        value: "delayed" as NSString
                    )
                ],
                start: 600,
                duration: 600
            )
        ]
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "leading-edit-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: sourceGroups,
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        XCTAssertEqual(CMTimeCompare(sourceTimeRange.start, .zero), 0)
        let reopenedSourceGroups = try readGroups(
            asset: sourceAsset,
            track: sourceTrack
        )
        XCTAssertEqual(reopenedSourceGroups.count, 1)
        XCTAssertGreaterThan(
            CMTimeCompare(reopenedSourceGroups[0].timeRange.start, .zero),
            0
        )

        let outputURL = temporaryDirectory.appendingPathComponent(
            "leading-edit-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(outputGroups.count, reopenedSourceGroups.count)
        XCTAssertEqual(
            outputGroups.map(\.timeRange),
            reopenedSourceGroups.map(\.timeRange)
        )
        XCTAssertEqual(
            outputGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            ["mdta/com.example.delayed"]
        )
        let outputTimeRange = try await result.sanitizedTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(outputTimeRange.start, sourceTimeRange.start),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(outputTimeRange.duration, sourceTimeRange.duration),
            0
        )
        try result.cleanup()
    }

    func testMigrationRetainsEveryControlledOnlyGroupBoundaryInMixedStream()
        async throws {
        let sourceGroups = [
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.mirmir.release.leading-a",
                        value: "remove" as NSString
                    )
                ],
                start: 0,
                duration: 120
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.mirmir.release.leading-b",
                        value: "remove" as NSString
                    )
                ],
                start: 120,
                duration: 180
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.example.foreign",
                        value: "keep" as NSString
                    )
                ],
                start: 300,
                duration: 150
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.mirmir.release.trailing-a",
                        value: "remove" as NSString
                    )
                ],
                start: 450,
                duration: 250
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.mirmir.release.trailing-b",
                        value: "remove" as NSString
                    )
                ],
                start: 700,
                duration: 500
            )
        ]
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "multiple-controlled-boundaries-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: sourceGroups,
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "multiple-controlled-boundaries-output.mov"
        )

        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(outputGroups.count, sourceGroups.count)
        XCTAssertEqual(
            outputGroups.map(\.timeRange),
            sourceGroups.map(\.timeRange)
        )
        XCTAssertEqual(
            outputGroups.map { $0.items.count },
            [0, 0, 1, 0, 0]
        )
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testNonzeroSourceTimelineMapsToPrivateMovieZero() {
        let sourceTrackStart = CMTime(value: 1_200, timescale: 600)
        let sourceRange = CMTimeRange(
            start: CMTime(value: 1_500, timescale: 600),
            duration: CMTime(
                value: 600,
                timescale: 1_200,
                flags: [.valid, .hasBeenRounded],
                epoch: 0
            )
        )
        let mapped = MirmirTimedMetadataMigration.migrationTimelineRange(
            sourceRange,
            sourceTrackStart: sourceTrackStart
        )
        XCTAssertEqual(
            CMTimeCompare(
                mapped.start,
                CMTime(value: 300, timescale: 600)
            ),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(
                mapped.duration,
                CMTime(value: 300, timescale: 600)
            ),
            0
        )
    }

    func testOwnedCleanupRefusesReplacementFile() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "cleanup-ownership-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "owned-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        try FileManager.default.removeItem(at: outputURL)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: outputURL)

        XCTAssertThrowsError(try result.cleanup()) { error in
            guard case .cleanupOwnershipMismatch =
                    error as? MirmirTimedMetadataMigrationError else {
                return XCTFail("Unexpected cleanup error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), replacement)
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testOwnedCleanupPreservesReplacementInjectedDuringRemoval()
        async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "cleanup-injected-replacement-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "cleanup-injected-replacement-output.mov"
        )
        let replacementBytes = Data("replacement-must-survive".utf8)
        let fileSystem = MigrationTrackingFileSystem(
            matchingRemovalBehavior: .replaceThenFail(replacementBytes)
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL,
            fileSystem: fileSystem
        )
        XCTAssertEqual(ownershipMarkerNames().count, 1)

        XCTAssertThrowsError(try result.cleanup()) { error in
            XCTAssertEqual(
                error as? MirmirTimedMetadataMigrationError,
                .cleanupOwnershipMismatch(outputURL.path)
            )
        }
        XCTAssertEqual(fileSystem.matchingRemovalCallCount, 1)
        XCTAssertEqual(fileSystem.discardReservationCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: outputURL), replacementBytes)
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationPreservesSetupDataFormatSpecification() async throws {
        let identifier = "mdta/com.example.setup-data"
        let groups = [
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.example.setup-data",
                        value: "first" as NSString
                    )
                ],
                start: 0,
                duration: 240
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.example.setup-data",
                        value: "second" as NSString
                    )
                ],
                start: 240,
                duration: 360
            )
        ]
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "setup-data-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: groups,
            staticMetadata: [],
            includeSetupData: true
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceDescriptions = try await sourceTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(sourceDescriptions.count, 1)
        let sourceDeclaration = try XCTUnwrap(
            try metadataFormatDeclarations(
                in: try XCTUnwrap(sourceDescriptions.first)
            ).first
        )
        XCTAssertEqual(sourceDeclaration.identifier, identifier)
        XCTAssertEqual(sourceDeclaration.setupData, Data([0x01, 0x02]))
        XCTAssertNil(sourceDeclaration.structuralDependency)
        let decodedSourceGroups = try readGroups(
            asset: sourceAsset,
            track: sourceTrack
        )
        XCTAssertEqual(
            decodedSourceGroups.map(\.timeRange),
            groups.map(\.timeRange)
        )
        let inspection = try await MirmirTimedMetadataMigration.inspect(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack
        )
        XCTAssertEqual(inspection.classification, .foreignOnly)
        XCTAssertEqual(inspection.foreignGroupCount, 2)
        XCTAssertEqual(inspection.foreignItemCount, 2)

        let outputURL = temporaryDirectory.appendingPathComponent(
            "setup-data-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputDescriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(outputDescriptions.count, 1)
        XCTAssertEqual(
            try metadataFormatDeclarations(
                in: try XCTUnwrap(outputDescriptions.first)
            ),
            [sourceDeclaration]
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(
            outputGroups.map(\.timeRange),
            decodedSourceGroups.map(\.timeRange)
        )
        XCTAssertEqual(
            outputGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            [identifier, identifier]
        )
        let outputValues = try await outputGroups.flatMap(\.items)
            .asyncMap { try await $0.load(.value) }
        XCTAssertEqual(outputValues.compactMap { $0 as? String }, [
            "first",
            "second"
        ])
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationPreservesStructuralDependencyFormatSpecification()
        async throws {
        let identifier = "mdta/com.example.structural-dependency"
        let dependency: NSDictionary = [
            kCMMetadataFormatDescription_StructuralDependencyKey_DependencyIsInvalidFlag
                as String: true
        ]
        let groups = [
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.example.structural-dependency",
                        value: "first" as NSString
                    )
                ],
                start: 0,
                duration: 180
            ),
            timedGroup(
                items: [
                    metadataItem(
                        key: "com.example.structural-dependency",
                        value: "second" as NSString
                    )
                ],
                start: 180,
                duration: 420
            )
        ]
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "structural-dependency-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: groups,
            staticMetadata: [],
            structuralDependency: dependency
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceDescriptions = try await sourceTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(sourceDescriptions.count, 1)
        let sourceDeclaration = try XCTUnwrap(
            try metadataFormatDeclarations(
                in: try XCTUnwrap(sourceDescriptions.first)
            ).first
        )
        XCTAssertEqual(sourceDeclaration.identifier, identifier)
        XCTAssertNil(sourceDeclaration.setupData)
        XCTAssertTrue(
            sourceDeclaration.structuralDependency?.isEqual(dependency)
                == true
        )
        let decodedSourceGroups = try readGroups(
            asset: sourceAsset,
            track: sourceTrack
        )
        XCTAssertEqual(
            decodedSourceGroups.map(\.timeRange),
            groups.map(\.timeRange)
        )

        let outputURL = temporaryDirectory.appendingPathComponent(
            "structural-dependency-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputDescriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(outputDescriptions.count, 1)
        XCTAssertEqual(
            try metadataFormatDeclarations(
                in: try XCTUnwrap(outputDescriptions.first)
            ),
            [sourceDeclaration]
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(
            outputGroups.map(\.timeRange),
            decodedSourceGroups.map(\.timeRange)
        )
        XCTAssertEqual(
            outputGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            [identifier, identifier]
        )
        let outputValues = try await outputGroups.flatMap(\.items)
            .asyncMap { try await $0.load(.value) }
        XCTAssertEqual(outputValues.compactMap { $0 as? String }, [
            "first",
            "second"
        ])
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testControlledSetupDataSpecificationIsRemovedWithoutRejectingForeign()
        async throws {
        let controlledKey = "com.mirmir.release.with-setup"
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "controlled-setup-data-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: controlledKey,
                            value: "remove" as NSString
                        ),
                        metadataItem(
                            key: "com.example.keep",
                            value: "keep" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: [],
            includeSetupData: true,
            setupDataKey: controlledKey
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceDescriptions = try await sourceTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(sourceDescriptions.count, 1)
        let sourceDeclarations = try metadataFormatDeclarations(
            in: try XCTUnwrap(sourceDescriptions.first)
        )
        let sourceControlledDeclaration = try XCTUnwrap(
            sourceDeclarations.first {
                $0.identifier == "mdta/\(controlledKey)"
            }
        )
        let sourceForeignDeclaration = try XCTUnwrap(
            sourceDeclarations.first {
                $0.identifier == "mdta/com.example.keep"
            }
        )
        XCTAssertEqual(
            sourceControlledDeclaration.setupData,
            Data([0x01, 0x02])
        )
        XCTAssertNil(sourceForeignDeclaration.setupData)
        let inspection = try await MirmirTimedMetadataMigration.inspect(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack
        )
        XCTAssertEqual(inspection.classification, .mixedControlledAndForeign)
        XCTAssertEqual(inspection.removedControlledItemCount, 1)
        XCTAssertEqual(inspection.foreignItemCount, 1)

        let outputURL = temporaryDirectory.appendingPathComponent(
            "controlled-setup-data-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputDescriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(outputDescriptions.count, 1)
        XCTAssertEqual(
            try metadataFormatDeclarations(
                in: try XCTUnwrap(outputDescriptions.first)
            ),
            [sourceForeignDeclaration]
        )
        let groups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(
            groups.flatMap(\.items).compactMap { $0.identifier?.rawValue },
            ["mdta/com.example.keep"]
        )
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationFailsAndCleansOutputWhenNoForeignItems() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "controlled-only.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.mirmir.release.backend-id",
                            value: "controlled" as NSString
                        ),
                        metadataItem(
                            key: "com.mirmir.",
                            value: "controlled-like" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "no-foreign-output.mov"
        )

        do {
            _ = try await MirmirTimedMetadataMigration.migrate(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                outputURL: outputURL
            )
            XCTFail("Expected noForeignTimedMetadata")
        } catch let error as MirmirTimedMetadataMigrationError {
            XCTAssertEqual(error, .noForeignTimedMetadata)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationPreservesUnusedForeignFormatDeclaration()
        async throws {
        let controlledIdentifier =
            "mdta/com.mirmir.release.schema-only-source"
        let foreignIdentifier = "mdta/com.example.unused-foreign"
        let foreignDataType = kCMMetadataBaseDataType_RawData as String
        let foreignLanguageTag = "fr-CA"
        let controlled = metadataItem(
            key: "com.mirmir.release.schema-only-source",
            value: "remove" as NSString
        )
        let sourceGroups = [
            timedGroup(
                items: [controlled],
                start: 0,
                duration: 240
            ),
            timedGroup(
                items: [controlled],
                start: 240,
                duration: 360
            )
        ]
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "unused-foreign-format-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: sourceGroups,
            staticMetadata: [],
            additionalFormatSpecifications: [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                    as String: foreignIdentifier,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                    as String: foreignDataType,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_ExtendedLanguageTag
                    as String: foreignLanguageTag
            ]]
        )

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceDescriptions = try await sourceTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(sourceDescriptions.count, 1)
        let sourceDeclarations = try metadataFormatDeclarations(
            in: try XCTUnwrap(sourceDescriptions.first)
        )
        XCTAssertEqual(
            sourceDeclarations.map(\.identifier).sorted(),
            [controlledIdentifier, foreignIdentifier].sorted()
        )
        let sourceControlledDeclaration = try XCTUnwrap(
            sourceDeclarations.first {
                $0.identifier == controlledIdentifier
            }
        )
        let sourceForeignDeclaration = try XCTUnwrap(
            sourceDeclarations.first { $0.identifier == foreignIdentifier }
        )
        XCTAssertNotEqual(
            sourceForeignDeclaration.dataType,
            sourceControlledDeclaration.dataType
        )
        XCTAssertEqual(
            sourceForeignDeclaration.extendedLanguageTag,
            foreignLanguageTag
        )
        XCTAssertEqual(
            sourceForeignDeclaration.tableLocalID,
            sourceForeignDeclaration.entryLocalID
        )
        let decodedSourceGroups = try readGroups(
            asset: sourceAsset,
            track: sourceTrack
        )
        XCTAssertEqual(
            decodedSourceGroups.map(\.timeRange),
            sourceGroups.map(\.timeRange)
        )
        XCTAssertTrue(
            decodedSourceGroups.flatMap(\.items).allSatisfy {
                $0.identifier?.rawValue == controlledIdentifier
            }
        )

        let outputURL = temporaryDirectory.appendingPathComponent(
            "unused-foreign-format-migration.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )

        let outputDescriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(outputDescriptions.count, 1)
        let outputDeclarations = try metadataFormatDeclarations(
            in: try XCTUnwrap(outputDescriptions.first)
        )
        XCTAssertEqual(outputDeclarations, [sourceForeignDeclaration])
        XCTAssertFalse(
            outputDeclarations.contains {
                MirmirTimedMetadataPolicy.isControlledIdentifier(
                    $0.identifier
                ) || MirmirTimedMetadataPolicy.resemblesControlledIdentifier(
                    $0.identifier
                )
            }
        )
        XCTAssertFalse(
            outputDeclarations.contains {
                $0.identifier
                    == MirmirTimedMetadataMigration.shellCarrierIdentifier
            }
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(outputGroups.count, decodedSourceGroups.count)
        XCTAssertEqual(
            outputGroups.map(\.timeRange),
            decodedSourceGroups.map(\.timeRange)
        )
        XCTAssertTrue(outputGroups.allSatisfy { $0.items.isEmpty })
        let outputInspection = try await MirmirTimedMetadataMigration.inspect(
            sourceAsset: result.migrationAsset,
            sourceTrack: result.sanitizedTrack
        )
        XCTAssertFalse(outputInspection.isSanitizedShell)
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationPreservesCollidingLocalIDsAcrossDescriptionsAndABAOrder()
        async throws {
        let firstIdentifier = "mdta/com.example.colliding-local-id-first"
        let secondIdentifier = "mdta/com.example.colliding-local-id-second"
        let controlledKey = "com.mirmir.release.colliding-local-id"
        let firstSourceURL = temporaryDirectory.appendingPathComponent(
            "colliding-local-id-first.mov"
        )
        let secondSourceURL = temporaryDirectory.appendingPathComponent(
            "colliding-local-id-second.mov"
        )
        try await writeMetadataAsset(
            at: firstSourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: controlledKey,
                            value: "remove-first" as NSString
                        ),
                        metadataItem(
                            key: "com.example.colliding-local-id-first",
                            value: "first" as NSString
                        )
                    ],
                    start: 0,
                    duration: 300
                )
            ],
            staticMetadata: []
        )
        try await writeMetadataAsset(
            at: secondSourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: controlledKey,
                            value: "remove-second" as NSString
                        ),
                        metadataItem(
                            key: "com.example.colliding-local-id-second",
                            value: "second" as NSString
                        )
                    ],
                    start: 0,
                    duration: 300
                )
            ],
            staticMetadata: []
        )
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "colliding-local-id-source.mov"
        )
        try await concatenateMetadataAssets(
            [firstSourceURL, secondSourceURL, firstSourceURL],
            at: sourceURL
        )

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceDescriptions = try await sourceTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(sourceDescriptions.count, 2)
        let sourceDeclarations = try sourceDescriptions.map {
            try metadataFormatDeclarations(in: $0)
        }
        XCTAssertEqual(sourceDeclarations.map(\.count), [2, 2])
        XCTAssertEqual(
            sourceDeclarations.map {
                $0.map(\.tableLocalID)
            },
            [[1, 2], [1, 2]]
        )
        let retainedSourceDeclarations = try sourceDeclarations.map {
            declarations in
            try XCTUnwrap(declarations.first {
                !MirmirTimedMetadataPolicy.isControlledIdentifier(
                    $0.identifier
                )
            })
        }
        XCTAssertEqual(
            retainedSourceDeclarations.map(\.identifier),
            [firstIdentifier, secondIdentifier]
        )
        XCTAssertEqual(
            retainedSourceDeclarations.map(\.tableLocalID),
            [2, 2]
        )

        let inspection = try await MirmirTimedMetadataMigration.inspect(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack
        )
        XCTAssertEqual(inspection.foreignItemCount, 3)
        XCTAssertEqual(inspection.removedControlledItemCount, 3)
        XCTAssertEqual(inspection.retainedForeignFormatEntryCount, 2)

        let outputURL = temporaryDirectory.appendingPathComponent(
            "colliding-local-id-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputDescriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(outputDescriptions.count, 2)
        XCTAssertEqual(
            try outputDescriptions.map {
                try metadataFormatDeclarations(in: $0)
            },
            retainedSourceDeclarations.map { [$0] }
        )
        XCTAssertTrue(
            outputDescriptions.flatMap {
                (CMMetadataFormatDescriptionGetIdentifiers($0)
                    as? [String]) ?? []
            }.allSatisfy {
                $0 != MirmirTimedMetadataMigration.shellCarrierIdentifier
            }
        )
        XCTAssertEqual(
            try metadataSampleFormatBindings(
                asset: result.migrationAsset,
                track: result.sanitizedTrack
            ),
            [[firstIdentifier], [secondIdentifier], [firstIdentifier]]
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(
            outputGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            [firstIdentifier, secondIdentifier, firstIdentifier]
        )
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationUsesDeterministicBoundaryCarrierForEmptiedDescription()
        async throws {
        let controlledKey = "com.mirmir.release.boundary-only"
        let foreignIdentifier = "mdta/com.example.boundary-foreign"
        let controlledSourceURL = temporaryDirectory.appendingPathComponent(
            "boundary-controlled-source.mov"
        )
        let mixedSourceURL = temporaryDirectory.appendingPathComponent(
            "boundary-mixed-source.mov"
        )
        try await writeMetadataAsset(
            at: controlledSourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: controlledKey,
                            value: "remove-a" as NSString
                        )
                    ],
                    start: 0,
                    duration: 300
                )
            ],
            staticMetadata: []
        )
        try await writeMetadataAsset(
            at: mixedSourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: controlledKey,
                            value: "remove-b" as NSString
                        ),
                        metadataItem(
                            key: "com.example.boundary-foreign",
                            value: "keep-b" as NSString
                        )
                    ],
                    start: 0,
                    duration: 300
                )
            ],
            staticMetadata: []
        )
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "boundary-aba-source.mov"
        )
        try await concatenateMetadataAssets(
            [controlledSourceURL, mixedSourceURL, controlledSourceURL],
            at: sourceURL
        )

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceDescriptions = try await sourceTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(sourceDescriptions.count, 2)
        XCTAssertEqual(
            try metadataSampleFormatBindings(
                asset: sourceAsset,
                track: sourceTrack
            ),
            [
                ["mdta/\(controlledKey)"],
                ["mdta/\(controlledKey)", foreignIdentifier],
                ["mdta/\(controlledKey)"]
            ]
        )
        let emptiedSourceIdentity = try
            OutputMediaMetadataFormatSchemaIdentityReader
            .canonicalFormatDescription(sourceDescriptions[0])
        let expectedBoundaryIdentifier =
            "mdta/org.mirmir.preservation.boundary."
            + SHA256.hash(data: emptiedSourceIdentity).map {
                String(format: "%02x", $0)
            }.joined()

        let inspection = try await MirmirTimedMetadataMigration.inspect(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack
        )
        XCTAssertEqual(inspection.foreignItemCount, 1)
        XCTAssertEqual(inspection.removedControlledItemCount, 3)
        XCTAssertEqual(inspection.retainedForeignFormatEntryCount, 1)

        let outputURL = temporaryDirectory.appendingPathComponent(
            "boundary-aba-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputDescriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(outputDescriptions.count, 2)
        let outputDeclarations = try outputDescriptions.map {
            try metadataFormatDeclarations(in: $0)
        }
        XCTAssertEqual(outputDeclarations.map(\.count), [1, 1])
        XCTAssertEqual(
            outputDeclarations.map { $0[0].identifier },
            [expectedBoundaryIdentifier, foreignIdentifier]
        )
        XCTAssertEqual(
            outputDeclarations.map { $0[0].tableLocalID },
            [2, 2],
            "Both sanitized descriptions may use local ID 2 independently."
        )
        XCTAssertEqual(
            try metadataSampleFormatBindings(
                asset: result.migrationAsset,
                track: result.sanitizedTrack
            ),
            [
                [expectedBoundaryIdentifier],
                [foreignIdentifier],
                [expectedBoundaryIdentifier]
            ]
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(outputGroups.count, 3)
        XCTAssertEqual(
            outputGroups.map {
                $0.items.compactMap { $0.identifier?.rawValue }
            },
            [[], [foreignIdentifier], []]
        )
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMigrationRetainsEntireDeclaredButUnusedFormatDescription()
        async throws {
        let firstIdentifier = "mdta/com.example.used-description"
        let secondIdentifier = "mdta/com.example.unused-description"
        let firstURL = temporaryDirectory.appendingPathComponent(
            "used-description.mov"
        )
        let secondURL = temporaryDirectory.appendingPathComponent(
            "unused-description.mov"
        )
        try await writeMetadataAsset(
            at: firstURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.used-description",
                            value: "used" as NSString
                        )
                    ],
                    start: 0,
                    duration: 300
                )
            ],
            staticMetadata: []
        )
        try await writeMetadataAsset(
            at: secondURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.unused-description",
                            value: "unused-fixture-sample" as NSString
                        )
                    ],
                    start: 0,
                    duration: 300
                )
            ],
            staticMetadata: []
        )
        let heterogeneousURL = temporaryDirectory.appendingPathComponent(
            "used-and-unused-descriptions.mov"
        )
        try await concatenateMetadataAssets(
            [firstURL, secondURL],
            at: heterogeneousURL
        )
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "declared-but-unused-description-source.mov"
        )
        try await copyMetadataTrackSettings(
            from: heterogeneousURL,
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(value: 300, timescale: 600)
            ),
            to: sourceURL
        )

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceDescriptions = try await sourceTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(
            sourceDescriptions.count,
            2,
            "The fixture must contain a complete unbound description."
        )
        let sourceDeclarations = try sourceDescriptions.map {
            try metadataFormatDeclarations(in: $0)
        }
        XCTAssertEqual(
            sourceDeclarations.map { $0.map(\.identifier) },
            [[firstIdentifier], [secondIdentifier]]
        )
        XCTAssertEqual(
            try metadataSampleFormatBindings(
                asset: sourceAsset,
                track: sourceTrack
            ),
            [[firstIdentifier]],
            "No encoded source sample may bind the second description."
        )

        let outputURL = temporaryDirectory.appendingPathComponent(
            "declared-but-unused-description-output.mov"
        )
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL
        )
        let outputDescriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        XCTAssertEqual(outputDescriptions.count, 2)
        XCTAssertEqual(
            try outputDescriptions.map {
                try metadataFormatDeclarations(in: $0)
            },
            sourceDeclarations
        )
        XCTAssertEqual(
            try metadataSampleFormatBindings(
                asset: result.migrationAsset,
                track: result.sanitizedTrack
            ),
            [[firstIdentifier]]
        )
        let outputGroups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(outputGroups.count, 1)
        XCTAssertEqual(
            outputGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            [firstIdentifier],
            "The unbound-description anchor must not enter the track timeline."
        )

        for fixtureURL in [
            firstURL,
            secondURL,
            heterogeneousURL,
            sourceURL
        ] {
            try FileManager.default.removeItem(at: fixtureURL)
        }
        let independentOutputAsset = AVURLAsset(url: outputURL)
        let independentOutputTracks = try await independentOutputAsset
            .loadTracks(withMediaType: .metadata)
        let independentOutputTrack = try XCTUnwrap(
            independentOutputTracks.first
        )
        let independentOutputDescriptions = try await
            independentOutputTrack.load(.formatDescriptions)
        XCTAssertEqual(
            independentOutputDescriptions.count,
            2
        )
        XCTAssertEqual(
            try metadataSampleFormatBindings(
                asset: independentOutputAsset,
                track: independentOutputTrack
            ),
            [[firstIdentifier]],
            "The output must remain readable after every source file is removed."
        )
        let independentGroups = try readGroups(
            asset: independentOutputAsset,
            track: independentOutputTrack
        )
        XCTAssertEqual(independentGroups.count, 1)
        XCTAssertEqual(
            independentGroups.flatMap(\.items).compactMap {
                $0.identifier?.rawValue
            },
            [firstIdentifier]
        )
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testControlledOnlyShellHasExactCarrierAndZeroDecodedItems()
        async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "controlled-shell-source.mov"
        )
        let foreignStatic = metadataItem(
            key: "com.example.static-foreign",
            value: "keep" as NSString
        )
        let controlledStatic = metadataItem(
            key: "com.mirmir.release.static-controlled",
            value: "remove" as NSString
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.mirmir.release.leading",
                            value: "leading" as NSString
                        )
                    ],
                    start: 1_200,
                    duration: 300
                ),
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.mirmir.release.trailing",
                            value: "trailing" as NSString
                        )
                    ],
                    start: 1_500,
                    duration: 600
                )
            ],
            staticMetadata: [foreignStatic, controlledStatic]
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let sourceTimeRange = try await sourceTrack.load(.timeRange)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "controlled-shell.mov"
        )

        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL,
            emptyForeignBehavior: .preserveSanitizedShell
        )
        XCTAssertEqual(result.retainedGroupCount, 0)
        XCTAssertEqual(result.retainedItemCount, 0)
        XCTAssertEqual(result.sourceTrackProperties.languageCode, "eng")
        XCTAssertEqual(
            result.sourceTrackProperties.extendedLanguageTag,
            "en-US"
        )
        XCTAssertTrue(result.sourceTrackProperties.isEnabled)
        let outputTimeRange = try await result.sanitizedTrack.load(.timeRange)
        XCTAssertEqual(
            CMTimeCompare(outputTimeRange.start, sourceTimeRange.start),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(outputTimeRange.duration, sourceTimeRange.duration),
            0
        )
        let groups = try readGroups(
            asset: result.migrationAsset,
            track: result.sanitizedTrack
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].items.isEmpty)
        XCTAssertEqual(
            try metadataSamplePayloadHex(
                asset: result.migrationAsset,
                track: result.sanitizedTrack
            ),
            ["0000000800000000"],
            "The anchor payload must match the metadata adaptor's canonical zero-item group encoding."
        )
        XCTAssertEqual(
            CMTimeCompare(groups[0].timeRange.start, sourceTimeRange.start),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(
                groups[0].timeRange.duration,
                sourceTimeRange.duration
            ),
            0
        )
        let descriptions = try await result.sanitizedTrack.load(
            .formatDescriptions
        )
        let identifiers = descriptions.flatMap {
            (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String]) ?? []
        }
        XCTAssertEqual(
            identifiers,
            [MirmirTimedMetadataMigration.shellCarrierIdentifier]
        )
        let staticMetadata = try await result.sanitizedTrack.load(.metadata)
        XCTAssertEqual(
            staticMetadata.compactMap { $0.identifier?.rawValue },
            ["mdta/com.example.static-foreign"]
        )
        let staticValue = try await staticMetadata[0].load(.stringValue)
        XCTAssertEqual(staticValue, "keep")
        let shellInspection = try await MirmirTimedMetadataMigration.inspect(
            sourceAsset: result.migrationAsset,
            sourceTrack: result.sanitizedTrack
        )
        XCTAssertTrue(shellInspection.isSanitizedShell)
        XCTAssertEqual(shellInspection.classification, .sanitizedShell)
        XCTAssertEqual(shellInspection.sourceGroupCount, 1)
        XCTAssertEqual(shellInspection.foreignItemCount, 0)
        XCTAssertEqual(shellInspection.removedControlledItemCount, 0)

        let reingestedURL = temporaryDirectory.appendingPathComponent(
            "controlled-shell-reingested.mov"
        )
        let reingested = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: result.migrationAsset,
            sourceTrack: result.sanitizedTrack,
            outputURL: reingestedURL,
            emptyForeignBehavior: .preserveSanitizedShell
        )
        let reingestedGroups = try readGroups(
            asset: reingested.migrationAsset,
            track: reingested.sanitizedTrack
        )
        XCTAssertEqual(reingestedGroups.count, 1)
        XCTAssertTrue(reingestedGroups[0].items.isEmpty)
        try reingested.cleanup()
        try result.cleanup()
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testInspectionRejectsCarrierDecodedAsTimedItem() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "carrier-item-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.mirmir.preservation.track-carrier",
                            value: "invalid" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        let track = try XCTUnwrap(tracks.first)

        do {
            _ = try await MirmirTimedMetadataMigration.inspect(
                sourceAsset: asset,
                sourceTrack: track
            )
            XCTFail("Expected carrier-as-item rejection")
        } catch let error as MirmirTimedMetadataMigrationError {
            guard case .unsupportedSourceFormatSpecification(let reason) =
                    error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("decoded as a metadata item"))
        }
    }

    func testInspectionRejectsCarrierMixedWithForeignFormat() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "mixed-carrier-format-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.mirmir.preservation.track-carrier",
                            value: "invalid" as NSString
                        ),
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        let track = try XCTUnwrap(tracks.first)

        do {
            _ = try await MirmirTimedMetadataMigration.inspect(
                sourceAsset: asset,
                sourceTrack: track
            )
            XCTFail("Expected mixed carrier-format rejection")
        } catch let error as MirmirTimedMetadataMigrationError {
            guard case .unsupportedSourceFormatSpecification(let reason) =
                    error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("only declared format identifier"))
        }
    }

    func testInspectionRejectsCarrierAsStaticMetadataItem() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "static-carrier-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: [
                metadataItem(
                    key: "com.mirmir.preservation.track-carrier",
                    value: "invalid" as NSString
                )
            ]
        )
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        let track = try XCTUnwrap(tracks.first)

        do {
            _ = try await MirmirTimedMetadataMigration.inspect(
                sourceAsset: asset,
                sourceTrack: track
            )
            XCTFail("Expected static carrier rejection")
        } catch let error as MirmirTimedMetadataMigrationError {
            guard case .unsupportedSourceFormatSpecification(let reason) =
                    error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("static metadata item"))
        }
    }

    func testInjectedFileSystemOwnsReservationAndResultCleanup() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "injected-filesystem-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        let track = try XCTUnwrap(tracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "injected-filesystem-output.mov"
        )
        let fileSystem = MigrationTrackingFileSystem()

        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: asset,
            sourceTrack: track,
            outputURL: outputURL,
            fileSystem: fileSystem
        )
        XCTAssertEqual(fileSystem.reclaimCallCount, 1)
        XCTAssertEqual(fileSystem.matchingRemovalCallCount, 0)
        try result.cleanup()
        XCTAssertEqual(fileSystem.matchingRemovalCallCount, 1)
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testResultDeinitCleansOwnedArtifact() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "deinit-cleanup-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "deinit-owned.mov"
        )
        var result: MirmirTimedMetadataMigrationResult? = try await
            MirmirTimedMetadataMigration.migrate(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                outputURL: outputURL
            )
        XCTAssertNotNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        result = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testCancellationRemovesPartialMigrationOutput() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "cancellation-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "cancelled-output.mov"
        )

        do {
            _ = try await MirmirTimedMetadataMigration.migrate(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                outputURL: outputURL,
                cancellationCheck: {
                    if FileManager.default.fileExists(
                        atPath: outputURL.path
                    ) {
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testCancellationCleanupFailureLeavesOwnedPartialForRecovery()
        async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "cleanup-failure-recovery-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "cleanup-failure-recovery-output.mov"
        )
        let failingFileSystem = MigrationTrackingFileSystem(
            matchingRemovalBehavior: .failPreservingFile
        )

        do {
            _ = try await MirmirTimedMetadataMigration.migrate(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                outputURL: outputURL,
                fileSystem: failingFileSystem,
                cancellationCheck: {
                    if FileManager.default.fileExists(
                        atPath: outputURL.path
                    ) {
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                }
            )
            XCTFail("Expected migration and cleanup failure")
        } catch let error as MirmirTimedMetadataMigrationError {
            guard case .migrationFailureWithCleanupFailure(
                let path,
                let migrationReason,
                let cleanupReason
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, outputURL.path)
            XCTAssertTrue(migrationReason.contains("CancellationError"))
            XCTAssertTrue(
                cleanupReason.contains("injectedMatchingRemovalFailure")
            )
            XCTAssertTrue(
                cleanupReason.contains(
                    "ownership reservation retained for retry"
                )
            )
        }
        XCTAssertEqual(failingFileSystem.matchingRemovalCallCount, 1)
        XCTAssertEqual(failingFileSystem.discardReservationCallCount, 0)
        let partialBytes = try Data(contentsOf: outputURL)
        XCTAssertEqual(
            partialBytes,
            try XCTUnwrap(failingFileSystem.matchingRemovalObservedBytes)
        )
        XCTAssertEqual(ownershipMarkerNames().count, 1)

        let recoveryFileSystem = MigrationTrackingFileSystem()
        let result = try await MirmirTimedMetadataMigration.migrate(
            sourceAsset: sourceAsset,
            sourceTrack: sourceTrack,
            outputURL: outputURL,
            fileSystem: recoveryFileSystem
        )
        XCTAssertEqual(recoveryFileSystem.reclaimCallCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(ownershipMarkerNames().count, 1)
        try result.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testCancellationCleanupFailurePreservesReplacementAndDiscardsMarker()
        async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "cleanup-replacement-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "cleanup-replacement-output.mov"
        )
        let replacementBytes = Data("replacement-must-survive".utf8)
        let fileSystem = MigrationTrackingFileSystem(
            matchingRemovalBehavior: .replaceThenFail(replacementBytes)
        )

        do {
            _ = try await MirmirTimedMetadataMigration.migrate(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                outputURL: outputURL,
                fileSystem: fileSystem,
                cancellationCheck: {
                    if FileManager.default.fileExists(
                        atPath: outputURL.path
                    ) {
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                }
            )
            XCTFail("Expected migration and cleanup failure")
        } catch let error as MirmirTimedMetadataMigrationError {
            guard case .migrationFailureWithCleanupFailure(
                let path,
                let migrationReason,
                let cleanupReason
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, outputURL.path)
            XCTAssertTrue(migrationReason.contains("CancellationError"))
            XCTAssertTrue(
                cleanupReason.contains("injectedMatchingRemovalFailure")
            )
            XCTAssertTrue(
                cleanupReason.contains(
                    "current path no longer matches the owned partial file"
                )
            )
        }
        XCTAssertEqual(fileSystem.matchingRemovalCallCount, 1)
        XCTAssertEqual(fileSystem.discardReservationCallCount, 1)
        XCTAssertEqual(try Data(contentsOf: outputURL), replacementBytes)
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    func testMarkedRemnantReclaimCleanupFailureIsWriterFailure()
        async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "reclaim-cleanup-failure-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "reclaim-cleanup-failure-output.mov"
        )
        let remnantBytes = Data("marked-remnant".utf8)
        let markerFileSystem = LocalAtomicMediaFileSystem()
        XCTAssertFalse(
            try markerFileSystem.reclaimTransactionTemporaryFile(
                at: outputURL
            )
        )
        try remnantBytes.write(to: outputURL)
        XCTAssertEqual(ownershipMarkerNames().count, 1)
        let failingFileSystem = MigrationTrackingFileSystem(
            reclaimBehavior: .failCleanup
        )

        do {
            _ = try await MirmirTimedMetadataMigration.migrate(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                outputURL: outputURL,
                fileSystem: failingFileSystem
            )
            XCTFail("Expected sibling-path reservation failure")
        } catch let error as MirmirTimedMetadataMigrationError {
            guard case .writerFailure(let stage, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(stage, "sibling-path reservation")
            XCTAssertTrue(reason.contains("injected reclaim cleanup failure"))
        }
        XCTAssertEqual(failingFileSystem.reclaimCallCount, 1)
        XCTAssertEqual(failingFileSystem.matchingRemovalCallCount, 0)
        XCTAssertEqual(failingFileSystem.discardReservationCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: outputURL), remnantBytes)
        XCTAssertEqual(ownershipMarkerNames().count, 1)
    }

    func testExistingOutputIsNeverDeletedOrOverwritten() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent(
            "existing-output-source.mov"
        )
        try await writeMetadataAsset(
            at: sourceURL,
            groups: [
                timedGroup(
                    items: [
                        metadataItem(
                            key: "com.example.foreign",
                            value: "foreign" as NSString
                        )
                    ],
                    start: 0,
                    duration: 600
                )
            ],
            staticMetadata: []
        )
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputURL = temporaryDirectory.appendingPathComponent(
            "preexisting.mov"
        )
        let sentinel = Data("do-not-delete".utf8)
        try sentinel.write(to: outputURL)

        do {
            _ = try await MirmirTimedMetadataMigration.migrate(
                sourceAsset: sourceAsset,
                sourceTrack: sourceTrack,
                outputURL: outputURL
            )
            XCTFail("Expected outputAlreadyExists")
        } catch let error as MirmirTimedMetadataMigrationError {
            XCTAssertEqual(error, .outputAlreadyExists(outputURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), sentinel)
        XCTAssertTrue(ownershipMarkerNames().isEmpty)
    }

    private func metadataItem(
        key: String,
        value: any NSCopying & NSObjectProtocol,
        dataType: String = kCMMetadataBaseDataType_UTF8 as String,
        extendedLanguageTag: String? = nil
    ) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = key as NSString
        item.value = value
        item.dataType = dataType
        item.extendedLanguageTag = extendedLanguageTag
        return item
    }

    private func timedGroup(
        items: [AVMetadataItem],
        start: Int64,
        duration: Int64
    ) -> AVTimedMetadataGroup {
        AVTimedMetadataGroup(
            items: items,
            timeRange: CMTimeRange(
                start: CMTime(value: start, timescale: 600),
                duration: CMTime(value: duration, timescale: 600)
            )
        )
    }

    private func writeMetadataAsset(
        at url: URL,
        groups: [AVTimedMetadataGroup],
        staticMetadata: [AVMetadataItem],
        includeSetupData: Bool = false,
        setupDataKey: String? = nil,
        structuralDependency: NSDictionary? = nil,
        additionalFormatSpecifications: [[String: Any]] = []
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let formatDescription = try makeFormatDescription(
            groups,
            includeSetupData: includeSetupData,
            setupDataKey: setupDataKey,
            structuralDependency: structuralDependency,
            additionalFormatSpecifications: additionalFormatSpecifications
        )
        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 600
        input.languageCode = "eng"
        input.extendedLanguageTag = "en-US"
        input.marksOutputTrackAsEnabled = true
        input.metadata = staticMetadata
        guard writer.canAdd(input) else {
            throw MigrationTestError.writerRejectedInput
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputMetadataAdaptor(
            assetWriterInput: input
        )
        guard writer.startWriting() else {
            throw MigrationTestError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)
        for group in groups {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else {
                    throw MigrationTestError.writerFailed(writer.error)
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard adaptor.append(group) else {
                throw MigrationTestError.writerFailed(writer.error)
            }
        }
        guard let endTime = groups.map(\.timeRange.end).max() else {
            throw MigrationTestError.emptyGroups
        }
        writer.endSession(atSourceTime: endTime)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MigrationTestError.writerFailed(writer.error)
        }
    }

    private func concatenateMetadataAssets(
        _ sourceURLs: [URL],
        at outputURL: URL
    ) async throws {
        guard !sourceURLs.isEmpty else {
            throw MigrationTestError.missingMetadataTrack
        }
        let sourceAssets = sourceURLs.map { AVURLAsset(url: $0) }
        var sourceTracks: [AVAssetTrack] = []
        for asset in sourceAssets {
            let tracks = try await asset.loadTracks(withMediaType: .metadata)
            sourceTracks.append(try XCTUnwrap(tracks.first))
        }
        let firstTrack = try XCTUnwrap(sourceTracks.first)
        let movie = AVMutableMovie()
        movie.timescale = 600
        movie.defaultMediaDataStorage = AVMediaDataStorage(
            url: outputURL,
            options: nil
        )
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: .metadata,
            copySettingsFrom: firstTrack,
            options: nil
        ) else {
            throw MigrationTestError.movieTrackCreationFailed
        }
        let naturalTimeScale = try await firstTrack.load(.naturalTimeScale)
        if naturalTimeScale > 0 {
            destinationTrack.timescale = naturalTimeScale
        }
        destinationTrack.isEnabled = try await firstTrack.load(.isEnabled)
        destinationTrack.languageCode = try await firstTrack.load(
            .languageCode
        )
        destinationTrack.extendedLanguageTag = try await firstTrack.load(
            .extendedLanguageTag
        )
        destinationTrack.metadata = try await firstTrack.load(.metadata)
        var insertionTime = CMTime.zero
        for sourceTrack in sourceTracks {
            let sourceTimeRange = try await sourceTrack.load(.timeRange)
            try destinationTrack.insertTimeRange(
                sourceTimeRange,
                of: sourceTrack,
                at: insertionTime,
                copySampleData: true
            )
            insertionTime = CMTimeAdd(
                insertionTime,
                sourceTimeRange.duration
            )
        }
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
        withExtendedLifetime(sourceAssets) {}
    }

    private func copyMetadataTrackSettings(
        from sourceURL: URL,
        timeRange: CMTimeRange,
        to outputURL: URL
    ) async throws {
        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceTracks = try await sourceAsset.loadTracks(
            withMediaType: .metadata
        )
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let movie = AVMutableMovie()
        movie.timescale = 600
        movie.defaultMediaDataStorage = AVMediaDataStorage(
            url: outputURL,
            options: nil
        )
        guard let destinationTrack = movie.addMutableTrack(
            withMediaType: .metadata,
            copySettingsFrom: sourceTrack,
            options: nil
        ) else {
            throw MigrationTestError.movieTrackCreationFailed
        }
        let naturalTimeScale = try await sourceTrack.load(.naturalTimeScale)
        if naturalTimeScale > 0 {
            destinationTrack.timescale = naturalTimeScale
        }
        destinationTrack.isEnabled = try await sourceTrack.load(.isEnabled)
        destinationTrack.languageCode = try await sourceTrack.load(
            .languageCode
        )
        destinationTrack.extendedLanguageTag = try await sourceTrack.load(
            .extendedLanguageTag
        )
        destinationTrack.metadata = try await sourceTrack.load(.metadata)
        let completeSourceTimeRange = try await sourceTrack.load(.timeRange)
        try destinationTrack.insertTimeRange(
            completeSourceTimeRange,
            of: sourceTrack,
            at: .zero,
            copySampleData: true
        )
        destinationTrack.removeTimeRange(destinationTrack.timeRange)
        guard destinationTrack.insertMediaTimeRange(
            timeRange,
            into: CMTimeRange(
                start: .zero,
                duration: timeRange.duration
            )
        ) else {
            throw MigrationTestError.movieSampleInsertionFailed
        }
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
        withExtendedLifetime(sourceAsset) {}
    }

    private func metadataSampleFormatBindings(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> [[String]] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MigrationTestError.readerRejectedOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MigrationTestError.readerFailed(reader.error)
        }
        var bindings: [[String]] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
                continue
            }
            guard let description = CMSampleBufferGetFormatDescription(
                sampleBuffer
            ) else {
                let dataLength = CMSampleBufferGetDataBuffer(sampleBuffer)
                    .map(CMBlockBufferGetDataLength) ?? -1
                throw MigrationTestError.missingSampleFormatDescription(
                    "sampleCount=\(CMSampleBufferGetNumSamples(sampleBuffer)), "
                        + "dataLength=\(dataLength), "
                        + "timingValid="
                        + "\(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).isValid)"
                )
            }
            let identifiers = (
                CMMetadataFormatDescriptionGetIdentifiers(description)
                    as? [String]
            ) ?? []
            bindings.append(contentsOf: repeatElement(
                identifiers,
                count: CMSampleBufferGetNumSamples(sampleBuffer)
            ))
        }
        guard reader.status == .completed else {
            throw MigrationTestError.readerFailed(reader.error)
        }
        return bindings
    }

    private func metadataSamplePayloadHex(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> [String] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw MigrationTestError.readerRejectedOutput
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MigrationTestError.readerFailed(reader.error)
        }
        var payloads: [String] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
                continue
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(
                sampleBuffer
            ) else {
                payloads.append("")
                continue
            }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let baseAddress = bytes.baseAddress else {
                    return length == 0
                        ? kCMBlockBufferNoErr
                        : kCMBlockBufferBadPointerParameterErr
                }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: baseAddress
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw MigrationTestError.readerFailed(nil)
            }
            payloads.append(data.map {
                String(format: "%02x", $0)
            }.joined())
        }
        guard reader.status == .completed else {
            throw MigrationTestError.readerFailed(reader.error)
        }
        return payloads
    }

    private func makeFormatDescription(
        _ groups: [AVTimedMetadataGroup],
        includeSetupData: Bool = false,
        setupDataKey: String? = nil,
        structuralDependency: NSDictionary? = nil,
        additionalFormatSpecifications: [[String: Any]] = []
    ) throws -> CMMetadataFormatDescription {
        var seen: Set<String> = []
        var specifications: [[String: Any]] = []
        for item in groups.flatMap(\.items) {
            guard let identifier = item.identifier?.rawValue,
                  let dataType = item.dataType else {
                throw MigrationTestError.invalidFixtureItem
            }
            let uniqueKey = identifier + "\u{0}" + dataType + "\u{0}"
                + (item.extendedLanguageTag ?? "")
            guard seen.insert(uniqueKey).inserted else { continue }
            var specification: [String: Any] = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier
                    as String: identifier,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType
                    as String: dataType
            ]
            if let language = item.extendedLanguageTag {
                specification[
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_ExtendedLanguageTag
                        as String
                ] = language
            }
            let receivesSetupData = setupDataKey.map {
                identifier == "mdta/\($0)"
            } ?? true
            if includeSetupData && receivesSetupData {
                specification[
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_SetupData
                        as String
                ] = Data([0x01, 0x02])
            }
            if let structuralDependency {
                specification[
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_StructuralDependency
                        as String
                ] = structuralDependency
            }
            specifications.append(specification)
        }
        specifications.append(contentsOf: additionalFormatSpecifications)
        var description: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw MigrationTestError.formatDescriptionFailed(status)
        }
        return description
    }

    private func metadataFormatDeclarations(
        in description: CMMetadataFormatDescription
    ) throws -> [MigrationTestMetadataFormatDeclaration] {
        guard CMFormatDescriptionGetMediaSubType(description)
                == kCMMetadataFormatType_Boxed,
              let extensions = CMFormatDescriptionGetExtensions(
                description
              ) as NSDictionary?,
              let keyTable = extensions[
                kCMFormatDescriptionExtensionKey_MetadataKeyTable as String
              ] as? NSDictionary else {
            throw MigrationTestError.invalidFormatDescription(
                "boxed metadata key table is missing"
            )
        }
        var declarations: [MigrationTestMetadataFormatDeclaration] = []
        for (rawLocalID, rawEntry) in keyTable {
            guard let tableLocalID = metadataFormatLocalID(rawLocalID) else {
                throw MigrationTestError.invalidFormatDescription(
                    "metadata key-table local ID has an unsupported type: "
                        + String(reflecting: type(of: rawLocalID))
                )
            }
            guard let entry = rawEntry as? NSDictionary else {
                throw MigrationTestError.invalidFormatDescription(
                    "metadata key-table entry has an unsupported type: "
                        + String(reflecting: type(of: rawEntry))
                )
            }
            guard CMMetadataFormatDescriptionGetKeyWithLocalID(
                description,
                localKeyID: tableLocalID
            ) != nil else {
                throw MigrationTestError.invalidFormatDescription(
                    "metadata key-table local ID is not exposed by CoreMedia: "
                        + "\(tableLocalID)"
                )
            }
            guard let entryLocalID = entry[
                    kCMMetadataFormatDescriptionKey_LocalID as String
                  ] as? NSNumber,
                  let namespace = entry[
                    kCMMetadataFormatDescriptionKey_Namespace as String
                  ] as? NSNumber,
                  let keyValue = metadataFormatData(
                    entry[kCMMetadataFormatDescriptionKey_Value as String]
                  ),
                  let identifier = metadataFormatIdentifier(
                    namespace: namespace.uint32Value,
                    keyValue: keyValue
                  ) else {
                throw MigrationTestError.invalidFormatDescription(
                    "metadata key-table entry is incomplete: \(entry)"
                )
            }
            guard tableLocalID == entryLocalID.uint32Value else {
                throw MigrationTestError.invalidFormatDescription(
                    "metadata key-table local ID does not match its entry: "
                        + "\(tableLocalID) != \(entryLocalID)"
                )
            }
            let dataType = metadataFormatData(
                entry[kCMMetadataFormatDescriptionKey_DataType as String]
            )
            let dataTypeNamespace = (
                entry[
                    kCMMetadataFormatDescriptionKey_DataTypeNamespace
                        as String
                ] as? NSNumber
            )?.uint32Value
            declarations.append(
                MigrationTestMetadataFormatDeclaration(
                    identifier: identifier,
                    namespace: namespace.uint32Value,
                    keyValue: keyValue,
                    tableLocalID: tableLocalID,
                    entryLocalID: entryLocalID.uint32Value,
                    dataType: dataType,
                    dataTypeNamespace: dataTypeNamespace,
                    extendedLanguageTag: entry[
                        kCMMetadataFormatDescriptionKey_LanguageTag as String
                    ] as? String,
                    setupData: metadataFormatData(
                        entry[
                            kCMMetadataFormatDescriptionKey_SetupData as String
                        ]
                    ),
                    structuralDependency: entry[
                        kCMMetadataFormatDescriptionKey_StructuralDependency
                            as String
                    ] as? NSDictionary,
                    rawEntry: entry
                )
            )
        }
        return declarations.sorted {
            if $0.tableLocalID != $1.tableLocalID {
                return $0.tableLocalID < $1.tableLocalID
            }
            return $0.identifier < $1.identifier
        }
    }

    private func metadataFormatLocalID(_ value: Any) -> UInt32? {
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        if let string = value as? NSString {
            return UInt32(string as String)
        }
        if let string = value as? String {
            return UInt32(string)
        }
        return nil
    }

    private func metadataFormatData(_ value: Any?) -> Data? {
        if let value = value as? Data { return value }
        if let value = value as? NSData { return value as Data }
        return nil
    }

    private func metadataFormatIdentifier(
        namespace: UInt32,
        keyValue: Data
    ) -> String? {
        let namespaceBytes: [UInt8] = [
            UInt8((namespace >> 24) & 0xff),
            UInt8((namespace >> 16) & 0xff),
            UInt8((namespace >> 8) & 0xff),
            UInt8(namespace & 0xff)
        ]
        guard namespaceBytes.allSatisfy({ 0x20...0x7e ~= $0 }),
              let namespaceString = String(
                bytes: namespaceBytes,
                encoding: .ascii
              ),
              let key = String(data: keyValue, encoding: .utf8) else {
            return nil
        }
        return "\(namespaceString)/\(key)"
    }

    private func ownershipMarkerNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        )) ?? []).filter {
            $0.hasPrefix(".mirmir-temporary-owner-")
                && $0.hasSuffix(".marker")
        }
    }

    private func readGroups(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> [AVTimedMetadataGroup] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else {
            throw MigrationTestError.readerRejectedOutput
        }
        reader.add(output)
        let adaptor = AVAssetReaderOutputMetadataAdaptor(
            assetReaderTrackOutput: output
        )
        guard reader.startReading() else {
            throw MigrationTestError.readerFailed(reader.error)
        }
        var groups: [AVTimedMetadataGroup] = []
        while let group = adaptor.nextTimedMetadataGroup() {
            groups.append(group)
        }
        guard reader.status == .completed else {
            throw MigrationTestError.readerFailed(reader.error)
        }
        return groups
    }
}

private enum MigrationTestError: Error {
    case writerRejectedInput
    case writerFailed(Error?)
    case readerRejectedOutput
    case readerFailed(Error?)
    case emptyGroups
    case invalidFixtureItem
    case formatDescriptionFailed(OSStatus)
    case invalidFormatDescription(String)
    case missingMetadataTrack
    case movieTrackCreationFailed
    case movieSampleInsertionFailed
    case missingSampleFormatDescription(String)
}

private struct MigrationTestMetadataFormatDeclaration: Equatable {
    let identifier: String
    let namespace: UInt32
    let keyValue: Data
    let tableLocalID: UInt32
    let entryLocalID: UInt32
    let dataType: Data?
    let dataTypeNamespace: UInt32?
    let extendedLanguageTag: String?
    let setupData: Data?
    let structuralDependency: NSDictionary?
    let rawEntry: NSDictionary

    static func == (
        lhs: MigrationTestMetadataFormatDeclaration,
        rhs: MigrationTestMetadataFormatDeclaration
    ) -> Bool {
        lhs.tableLocalID == rhs.tableLocalID
            && lhs.rawEntry.isEqual(rhs.rawEntry)
    }
}

private enum MigrationTrackingMatchingRemovalBehavior: Sendable {
    case delegate
    case failPreservingFile
    case replaceThenFail(Data)
}

private enum MigrationTrackingReclaimBehavior: Sendable {
    case delegate
    case failCleanup
}

private enum MigrationTrackingFileSystemError: Error {
    case injectedMatchingRemovalFailure
}

private final class MigrationTrackingFileSystem:
    AtomicMediaFileSystem, @unchecked Sendable {
    private let base = LocalAtomicMediaFileSystem()
    private let lock = NSLock()
    private let matchingRemovalBehavior:
        MigrationTrackingMatchingRemovalBehavior
    private let reclaimBehavior: MigrationTrackingReclaimBehavior
    private var mutableReclaimCallCount = 0
    private var mutableMatchingRemovalCallCount = 0
    private var mutableDiscardReservationCallCount = 0
    private var mutableMatchingRemovalObservedBytes: Data?

    init(
        matchingRemovalBehavior:
            MigrationTrackingMatchingRemovalBehavior = .delegate,
        reclaimBehavior: MigrationTrackingReclaimBehavior = .delegate
    ) {
        self.matchingRemovalBehavior = matchingRemovalBehavior
        self.reclaimBehavior = reclaimBehavior
    }

    var reclaimCallCount: Int {
        lock.withLock { mutableReclaimCallCount }
    }

    var matchingRemovalCallCount: Int {
        lock.withLock { mutableMatchingRemovalCallCount }
    }

    var discardReservationCallCount: Int {
        lock.withLock { mutableDiscardReservationCallCount }
    }

    var matchingRemovalObservedBytes: Data? {
        lock.withLock { mutableMatchingRemovalObservedBytes }
    }

    func directoryExists(at url: URL) -> Bool {
        base.directoryExists(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        base.fileExists(at: url)
    }

    func pathEntryExists(at url: URL) -> Bool {
        base.pathEntryExists(at: url)
    }

    func acquireTransactionLease(
        for destinationURL: URL
    ) throws -> AtomicMediaTransactionLease {
        try base.acquireTransactionLease(for: destinationURL)
    }

    @discardableResult
    func reclaimTransactionTemporaryFile(at url: URL) throws -> Bool {
        lock.withLock { mutableReclaimCallCount += 1 }
        switch reclaimBehavior {
        case .delegate:
            return try base.reclaimTransactionTemporaryFile(at: url)
        case .failCleanup:
            throw AtomicMediaOutputError.cleanupFailed(
                temporary: url,
                attempts: 1,
                reason: "injected reclaim cleanup failure"
            )
        }
    }

    func discardTransactionTemporaryFileReservation(
        at url: URL
    ) throws {
        lock.withLock { mutableDiscardReservationCallCount += 1 }
        try base.discardTransactionTemporaryFileReservation(at: url)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }

    func removeItem(
        at url: URL,
        ifMatchingFile identity: AtomicMediaPinnedFileIdentity
    ) throws {
        let observedBytes = try? Data(contentsOf: url)
        lock.withLock {
            mutableMatchingRemovalCallCount += 1
            mutableMatchingRemovalObservedBytes = observedBytes
        }
        switch matchingRemovalBehavior {
        case .delegate:
            try base.removeItem(at: url, ifMatchingFile: identity)
        case .failPreservingFile:
            throw MigrationTrackingFileSystemError
                .injectedMatchingRemovalFailure
        case .replaceThenFail(let replacementBytes):
            try base.removeItem(at: url)
            try replacementBytes.write(to: url, options: .atomic)
            throw MigrationTrackingFileSystemError
                .injectedMatchingRemovalFailure
        }
    }

    func removeItem(
        at url: URL,
        ifMatching identity: AtomicMediaCleanupFileIdentity
    ) throws {
        try base.removeItem(at: url, ifMatching: identity)
    }

    func publishAtomically(
        from temporaryURL: URL,
        to destinationURL: URL
    ) throws {
        try base.publishAtomically(
            from: temporaryURL,
            to: destinationURL
        )
    }
}

private extension Array {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
