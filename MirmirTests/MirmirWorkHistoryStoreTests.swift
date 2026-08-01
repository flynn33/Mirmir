import Foundation
import XCTest
@testable import Mirmir

final class MirmirWorkHistoryStoreTests: XCTestCase {
    func testRoundTripPersistsCompleteTypedRecordWithoutRawPathFields()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let record = makeWorkHistoryRecord(
            id: "job-round-trip",
            completedAt: Date(timeIntervalSinceReferenceDate: 4_000.125),
            processingConfiguration: UpscaleProcessingConfiguration(
                enginePreference: .mpsLanczos,
                strategyPreference: .adaptive,
                temporalConsistencyEnabled: false,
                edgeFidelityLevel: .high,
                detailRecoveryLevel: .low
            )
        )

        let mutation = try await store.upsert(record)
        XCTAssertEqual(mutation.records, [record])
        XCTAssertNil(mutation.recovery)

        let reloaded = MirmirWorkHistoryStore(directoryURL: directory)
        let snapshot = try await reloaded.snapshot()
        XCTAssertEqual(snapshot.records, [record])
        XCTAssertNil(snapshot.recovery)

        let data = try Data(
            contentsOf: directory.appendingPathComponent(
                MirmirWorkHistoryStore.documentFileName
            )
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
        XCTAssertTrue(json.contains("\"sourceAudioTrackCount\":2"))
        XCTAssertTrue(json.contains("\"sourceScanStructure\":\"progressive\""))
        XCTAssertFalse(json.contains("sourceURL"))
        XCTAssertFalse(json.contains("outputURL"))
        XCTAssertFalse(json.contains("/Users/example/source.mov"))
        XCTAssertFalse(json.contains("/Users/example/output.mov"))
    }

    func testLegacyRecordWithoutAudioTrackCountDecodesAsUnknown()
        throws {
        let record = makeWorkHistoryRecord(
            id: "job-legacy-audio-count",
            completedAt: Date(timeIntervalSinceReferenceDate: 500)
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        XCTAssertEqual(object.removeValue(
            forKey: "sourceAudioTrackCount"
        ) as? Int, 2)
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            MirmirWorkHistoryRecord.self,
            from: legacyData
        )

        XCTAssertNil(decoded.sourceAudioTrackCount)
        XCTAssertTrue(decoded.preserveAudio)
    }

    func testRoundTripPersistsExactSourceScanStructure() async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let record = makeWorkHistoryRecord(
            id: "job-scan-structure-round-trip",
            completedAt: Date(timeIntervalSinceReferenceDate: 600),
            sourceScanStructure: .interlacedBottomFieldFirst
        )

        _ = try await store.upsert(record)

        let reloaded = try await MirmirWorkHistoryStore(
            directoryURL: directory
        ).record(id: record.id)
        XCTAssertEqual(
            reloaded?.sourceScanStructure,
            .interlacedBottomFieldFirst
        )
        let data = try Data(
            contentsOf: directory.appendingPathComponent(
                MirmirWorkHistoryStore.documentFileName
            )
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(
            json.contains(
                "\"sourceScanStructure\":"
                    + "\"interlaced_bottom_field_first\""
            )
        )
    }

    func testLegacyRecordWithoutSourceScanStructureDecodesAsUnknown()
        throws {
        let record = makeWorkHistoryRecord(
            id: "job-legacy-scan-structure",
            completedAt: Date(timeIntervalSinceReferenceDate: 700),
            sourceScanStructure: .interlacedTopFieldFirst
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        XCTAssertEqual(
            object.removeValue(forKey: "sourceScanStructure") as? String,
            MediaVideoScanStructure.interlacedTopFieldFirst.rawValue
        )
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            MirmirWorkHistoryRecord.self,
            from: legacyData
        )

        XCTAssertNil(decoded.sourceScanStructure)
    }

    func testInvalidSourceScanStructureRawValueIsRejected() throws {
        let record = makeWorkHistoryRecord(
            id: "job-invalid-scan-structure",
            completedAt: Date(timeIntervalSinceReferenceDate: 800)
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object["sourceScanStructure"] = "interlaced_guessed"
        let invalidData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MirmirWorkHistoryRecord.self,
                from: invalidData
            )
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail(
                    "Expected dataCorrupted, observed \(error)."
                )
            }
            XCTAssertEqual(
                context.codingPath.last?.stringValue,
                "sourceScanStructure"
            )
        }
    }

    func testUpdateRequiresExistingRecordAndRemoveIsPerRecord() async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let original = makeWorkHistoryRecord(
            id: "job-update",
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        _ = try await store.upsert(original)

        let updated = makeWorkHistoryRecord(
            id: original.id,
            completedAt: Date(timeIntervalSinceReferenceDate: 200),
            terminalResult: .failed,
            outputVerification: .unavailable
        )
        let snapshot = try await store.update(updated)
        XCTAssertEqual(snapshot.records, [updated])

        do {
            _ = try await store.update(
                makeWorkHistoryRecord(
                    id: "job-absent",
                    completedAt: Date(timeIntervalSinceReferenceDate: 300)
                )
            )
            XCTFail("Updating an absent record must fail.")
        } catch {
            XCTAssertEqual(
                error as? MirmirWorkHistoryStoreError,
                .recordNotFound
            )
        }

        let removed = try await store.remove(id: original.id)
        let removedAgain = try await store.remove(id: original.id)
        let remaining = try await store.records()
        XCTAssertTrue(removed)
        XCTAssertFalse(removedAgain)
        XCTAssertEqual(remaining, [])
    }

    func testReadsAreNewestFirstAndRetentionDropsOldestRecord() async throws {
        let directory = try temporaryDirectory()
        let limits = try MirmirWorkHistoryLimits(
            maximumRecords: 2,
            maximumDocumentBytes: 64 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let store = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: limits
        )
        let oldest = makeWorkHistoryRecord(
            id: "job-oldest",
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let newest = makeWorkHistoryRecord(
            id: "job-newest",
            completedAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        let middle = makeWorkHistoryRecord(
            id: "job-middle",
            completedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        _ = try await store.upsert(oldest)
        _ = try await store.upsert(newest)
        let snapshot = try await store.upsert(middle)

        XCTAssertEqual(snapshot.records.map(\.id), ["job-newest", "job-middle"])
        let reloaded = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: limits
        )
        let reloadedIDs = try await reloaded.records().map(\.id)
        XCTAssertEqual(reloadedIDs, ["job-newest", "job-middle"])
    }

    func testReadAtomicallyEnforcesAReducedRecordBound() async throws {
        let directory = try temporaryDirectory()
        let wideLimits = try MirmirWorkHistoryLimits(
            maximumRecords: 3,
            maximumDocumentBytes: 64 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let narrowLimits = try MirmirWorkHistoryLimits(
            maximumRecords: 2,
            maximumDocumentBytes: 64 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let seedStore = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: wideLimits
        )
        for index in 1...3 {
            _ = try await seedStore.upsert(
                makeWorkHistoryRecord(
                    id: "job-\(index)",
                    completedAt: Date(
                        timeIntervalSinceReferenceDate: Double(index)
                    )
                )
            )
        }

        let boundedStore = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: narrowLimits
        )
        let boundedIDs = try await boundedStore.records().map(\.id)
        XCTAssertEqual(boundedIDs, ["job-3", "job-2"])

        let wideReload = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: wideLimits
        )
        let reloadedIDs = try await wideReload.records().map(\.id)
        XCTAssertEqual(reloadedIDs, ["job-3", "job-2"])
    }

    func testMalformedDocumentIsQuarantinedAndRecoveredAsEmptyHistory()
        async throws {
        let directory = try temporaryDirectory()
        let documentURL = directory.appendingPathComponent(
            MirmirWorkHistoryStore.documentFileName
        )
        let malformed = Data(#"{"schemaVersion":1,"records":["#.utf8)
        try malformed.write(to: documentURL, options: .atomic)

        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let recovered = try await store.snapshot()

        XCTAssertEqual(recovered.records, [])
        XCTAssertEqual(recovered.recovery?.reason, .malformedDocument)
        let quarantineName = try XCTUnwrap(
            recovered.recovery?.quarantineFileName
        )
        XCTAssertFalse(quarantineName.contains("/"))
        XCTAssertEqual(
            try Data(
                contentsOf: directory.appendingPathComponent(quarantineName)
            ),
            malformed
        )

        let subsequent = try await store.snapshot()
        XCTAssertEqual(subsequent.records, [])
        XCTAssertNil(subsequent.recovery)
    }

    func testInvalidRecordsAreRejectedWithoutChangingPersistedHistory()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let valid = makeWorkHistoryRecord(
            id: "job-valid",
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        _ = try await store.upsert(valid)

        let invalidName = makeWorkHistoryRecord(
            id: "job-invalid-name",
            completedAt: Date(timeIntervalSinceReferenceDate: 200),
            sourceDisplayName: "/Users/example/private.mov"
        )
        await assertRejected(
            invalidName,
            field: .sourceDisplayName,
            by: store
        )

        let missingVerification = makeWorkHistoryRecord(
            id: "job-invalid-verification",
            completedAt: Date(timeIntervalSinceReferenceDate: 300),
            outputVerification: .unavailable
        )
        await assertRejected(
            missingVerification,
            field: .outputVerification,
            by: store
        )

        let invalidAudioTrackCount = makeWorkHistoryRecord(
            id: "job-invalid-audio-track-count",
            completedAt: Date(timeIntervalSinceReferenceDate: 400),
            sourceAudioTrackCount: -1
        )
        await assertRejected(
            invalidAudioTrackCount,
            field: .sourceAudioTrackCount,
            by: store
        )

        let persisted = try await store.records()
        XCTAssertEqual(persisted, [valid])
    }

    func testOutputDisplayNameBoundaryRejectsSlashNULAndDotTraversal()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let rejectedNames = [
            "nested/output.mov",
            "output\u{0}.mov",
            ".",
            ".."
        ]

        for (index, rejectedName) in rejectedNames.enumerated() {
            let record = makeWorkHistoryRecord(
                id: "job-invalid-output-name-\(index)",
                completedAt: Date(
                    timeIntervalSinceReferenceDate: Double(index)
                ),
                outputDisplayName: rejectedName
            )
            await assertRejected(
                record,
                field: .outputDisplayName,
                by: store
            )
        }

        let persisted = try await store.records()
        XCTAssertEqual(persisted, [])
    }

    func testDocumentByteBoundRejectsMutationWithoutReplacingExistingData()
        async throws {
        let directory = try temporaryDirectory()
        let limits = try MirmirWorkHistoryLimits(
            maximumRecords: 10,
            maximumDocumentBytes: 2_048,
            maximumBookmarkBytes: 1_500
        )
        let store = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: limits
        )
        let valid = makeWorkHistoryRecord(
            id: "job-before-capacity-error",
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        _ = try await store.upsert(valid)
        let oversizedDocumentRecord = makeWorkHistoryRecord(
            id: "job-over-document-capacity",
            completedAt: Date(timeIntervalSinceReferenceDate: 200),
            sourceBookmark: Data(repeating: 0x41, count: 1_200),
            outputBookmark: Data(repeating: 0x42, count: 1_200)
        )

        do {
            _ = try await store.upsert(oversizedDocumentRecord)
            XCTFail("A document over the configured byte bound was accepted.")
        } catch {
            XCTAssertEqual(
                error as? MirmirWorkHistoryStoreError,
                .documentTooLarge
            )
        }

        let reloaded = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: limits
        )
        let persisted = try await reloaded.records()
        XCTAssertEqual(persisted, [valid])
    }

    func testBookmarkStatesReportAvailableMissingAndReauthorization()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let record = makeWorkHistoryRecord(
            id: "job-bookmarks",
            completedAt: Date(timeIntervalSinceReferenceDate: 100),
            sourceBookmark: Data("source-token".utf8),
            outputBookmark: Data("output-token".utf8)
        )
        _ = try await store.upsert(record)

        let availableURL = URL(fileURLWithPath: "/virtual/source.mov")
        let missingURL = URL(fileURLWithPath: "/virtual/output.mov")
        let resolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: availableURL,
                        isStale: false
                    )
                ),
                record.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: missingURL,
                        isStale: false
                    )
                )
            ]
        )
        let availability = WorkHistoryFakeAvailabilityChecker(
            availablePaths: [availableURL.path]
        )
        let scopeAudit = WorkHistorySecurityScopeAudit()

        let first = try await store.bookmarkStates(
            id: record.id,
            resolver: resolver,
            availabilityChecker: availability,
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        XCTAssertEqual(first.source, .available)
        XCTAssertEqual(first.output, .missing)
        let allStates = await store.bookmarkStates(
            records: [record],
            resolver: resolver,
            availabilityChecker: availability,
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        XCTAssertEqual(allStates, [record.id: first])

        let staleResolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: availableURL,
                        isStale: true
                    )
                ),
                record.outputBookmark: .failed
            ]
        )
        let second = try await store.bookmarkStates(
            id: record.id,
            resolver: staleResolver,
            availabilityChecker: availability,
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        XCTAssertEqual(second.source, .reauthorizationRequired)
        XCTAssertEqual(second.output, .reauthorizationRequired)
        XCTAssertEqual(
            resolver.resolvedRoles,
            [.source, .output, .source, .output]
        )
        XCTAssertEqual(staleResolver.resolvedRoles, [.source, .output])
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
    }

    func testBookmarkStatesRetainResolvedScopesDuringAvailabilityChecks()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let record = makeWorkHistoryRecord(
            id: "job-scoped-bookmark-states",
            completedAt: Date(timeIntervalSinceReferenceDate: 100),
            sourceBookmark: Data("scoped-source".utf8),
            outputBookmark: Data("scoped-output".utf8)
        )
        _ = try await store.upsert(record)
        let sourceURL = URL(fileURLWithPath: "/scoped/source.mov")
        let outputDirectoryURL = URL(
            fileURLWithPath: "/scoped/Exports",
            isDirectory: true
        )
        let resolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: sourceURL,
                        isStale: false
                    )
                ),
                record.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: outputDirectoryURL,
                        isStale: false
                    )
                )
            ]
        )
        let scopeAudit = WorkHistorySecurityScopeAudit()

        let states = try await store.bookmarkStates(
            id: record.id,
            resolver: resolver,
            availabilityChecker:
                WorkHistoryScopeCheckingAvailabilityChecker(
                    audit: scopeAudit
                ),
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )

        XCTAssertEqual(
            states,
            MirmirWorkHistoryBookmarkStates(
                source: .available,
                output: .available
            )
        )
        XCTAssertEqual(
            scopeAudit.events,
            [
                "start:/scoped/source.mov",
                "check:/scoped/source.mov",
                "stop:/scoped/source.mov",
                "start:/scoped/Exports",
                "check:/scoped/Exports/output.mov",
                "stop:/scoped/Exports"
            ]
        )
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
    }

    func testCapturingBookmarksOutputDirectoryAndRetainsFileName()
        throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent(
            "source.mov",
            isDirectory: false
        )
        let outputDirectoryURL = directory.appendingPathComponent(
            "Exports",
            isDirectory: true
        )
        let outputURL = outputDirectoryURL.appendingPathComponent(
            "upscaled-output.mov",
            isDirectory: false
        )
        let resolver = WorkHistoryFakeBookmarkResolver(outcomes: [:])

        let record = try MirmirWorkHistoryRecord.capturing(
            id: "job-capture-directory",
            sourceURL: sourceURL,
            outputURL: outputURL,
            sourceResolution:
                VideoResolution(width: 1_920, height: 1_080),
            targetResolution:
                VideoResolution(width: 3_840, height: 2_160),
            codec: .hevc,
            sourceAudioTrackCount: 2,
            sourceScanStructure: .interlacedSpatialFirstLineEarly,
            preserveAudio: true,
            requestedMode: .quality,
            processingConfiguration: .default,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            startedAt: Date(timeIntervalSinceReferenceDate: 101),
            completedAt: Date(timeIntervalSinceReferenceDate: 102),
            terminalResult: .failed,
            outputVerification: .unavailable,
            resolver: resolver
        )

        XCTAssertEqual(record.outputBookmarkScope, .directory)
        XCTAssertEqual(record.outputDisplayName, "upscaled-output.mov")
        XCTAssertEqual(record.sourceAudioTrackCount, 2)
        XCTAssertEqual(
            record.sourceScanStructure,
            .interlacedSpatialFirstLineEarly
        )
        XCTAssertEqual(
            resolver.createdLocations,
            [
                WorkHistoryBookmarkLocation(
                    role: .source,
                    url: sourceURL.standardizedFileURL
                ),
                WorkHistoryBookmarkLocation(
                    role: .output,
                    url: outputDirectoryURL.standardizedFileURL
                )
            ]
        )
    }

    func testResolvedLocationsAndCompletedStateUseDerivedOutputFile()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let record = makeWorkHistoryRecord(
            id: "job-resolve-completed",
            completedAt: Date(timeIntervalSinceReferenceDate: 100),
            sourceBookmark: Data("source-resolve".utf8),
            outputBookmark: Data("output-directory-resolve".utf8)
        )
        _ = try await store.upsert(record)
        let sourceURL = URL(fileURLWithPath: "/virtual/source.mov")
        let outputDirectoryURL = URL(
            fileURLWithPath: "/virtual/Exports",
            isDirectory: true
        )
        let outputFileURL = outputDirectoryURL
            .appendingPathComponent(
                record.outputDisplayName,
                isDirectory: false
            )
            .standardizedFileURL
        let resolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: sourceURL,
                        isStale: false
                    )
                ),
                record.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: outputDirectoryURL,
                        isStale: false
                    )
                )
            ]
        )
        let scopeAudit = WorkHistorySecurityScopeAudit()

        let locations = try await store.resolveLocations(
            id: record.id,
            resolver: resolver
        )
        XCTAssertEqual(locations.sourceURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(
            locations.outputDirectoryURL,
            outputDirectoryURL.standardizedFileURL
        )
        XCTAssertEqual(locations.outputFileURL, outputFileURL)
        XCTAssertFalse(locations.sourceBookmarkIsStale)
        XCTAssertFalse(locations.outputBookmarkIsStale)

        let fileAvailable = try await store.bookmarkStates(
            id: record.id,
            resolver: resolver,
            availabilityChecker: WorkHistoryFakeAvailabilityChecker(
                availablePaths: [sourceURL.path, outputFileURL.path]
            ),
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        XCTAssertEqual(fileAvailable.output, .available)

        let directoryOnly = try await store.bookmarkStates(
            id: record.id,
            resolver: resolver,
            availabilityChecker: WorkHistoryFakeAvailabilityChecker(
                availablePaths: [
                    sourceURL.path,
                    outputDirectoryURL.path
                ]
            ),
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        XCTAssertEqual(directoryOnly.output, .missing)
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
    }

    func testBackslashOutputNamePersistsAndResolvesWithinDirectory()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let outputDisplayName = #"client\final.mov"#
        let record = makeWorkHistoryRecord(
            id: "job-backslash-output-name",
            completedAt: Date(timeIntervalSinceReferenceDate: 100),
            outputDisplayName: outputDisplayName,
            sourceBookmark: Data("backslash-source".utf8),
            outputBookmark: Data("backslash-output-directory".utf8)
        )

        _ = try await store.upsert(record)
        let reloaded = MirmirWorkHistoryStore(directoryURL: directory)
        let persistedRecord = try await reloaded.record(id: record.id)
        XCTAssertEqual(
            persistedRecord?.outputDisplayName,
            outputDisplayName
        )

        let sourceURL = URL(fileURLWithPath: "/virtual/source.mov")
        let outputDirectoryURL = URL(
            fileURLWithPath: "/virtual/Exports",
            isDirectory: true
        ).standardizedFileURL
        let resolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: sourceURL,
                        isStale: false
                    )
                ),
                record.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: outputDirectoryURL,
                        isStale: false
                    )
                )
            ]
        )
        let locations = try await reloaded.resolveLocations(
            id: record.id,
            resolver: resolver
        )
        XCTAssertEqual(
            locations.outputFileURL.lastPathComponent,
            outputDisplayName
        )
        XCTAssertEqual(
            locations.outputFileURL.deletingLastPathComponent()
                .standardizedFileURL,
            outputDirectoryURL
        )
    }

    func testFailedMissingOutputUsesAvailableOutputDirectoryState()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let record = makeWorkHistoryRecord(
            id: "job-resolve-failed",
            completedAt: Date(timeIntervalSinceReferenceDate: 100),
            terminalResult: .failed,
            outputVerification: .unavailable,
            sourceBookmark: Data("failed-source".utf8),
            outputBookmark: Data("failed-output-directory".utf8)
        )
        _ = try await store.upsert(record)
        let sourceURL = URL(fileURLWithPath: "/virtual/source.mov")
        let outputDirectoryURL = URL(
            fileURLWithPath: "/virtual/Exports",
            isDirectory: true
        )
        let resolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: sourceURL,
                        isStale: false
                    )
                ),
                record.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: outputDirectoryURL,
                        isStale: false
                    )
                )
            ]
        )
        let scopeAudit = WorkHistorySecurityScopeAudit()

        let locations = try await store.resolveLocations(
            id: record.id,
            resolver: resolver
        )
        XCTAssertEqual(
            locations.outputFileURL,
            outputDirectoryURL.appendingPathComponent(
                record.outputDisplayName,
                isDirectory: false
            ).standardizedFileURL
        )
        let states = try await store.bookmarkStates(
            id: record.id,
            resolver: resolver,
            availabilityChecker: WorkHistoryFakeAvailabilityChecker(
                availablePaths: [
                    sourceURL.path,
                    outputDirectoryURL.path
                ]
            ),
            securityScopedResourceAccess: scopeAudit.resourceAccess
        )
        XCTAssertEqual(states.source, .available)
        XCTAssertEqual(states.output, .available)
        XCTAssertEqual(scopeAudit.activeScopeCount, 0)
    }

    func testResolvedLocationsExposeStaleFlagsAndRejectInvalidURLs()
        async throws {
        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        let record = makeWorkHistoryRecord(
            id: "job-resolve-stale",
            completedAt: Date(timeIntervalSinceReferenceDate: 100),
            sourceBookmark: Data("stale-source".utf8),
            outputBookmark: Data("stale-output".utf8)
        )
        _ = try await store.upsert(record)
        let staleResolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: URL(fileURLWithPath: "/virtual/source.mov"),
                        isStale: true
                    )
                ),
                record.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: URL(fileURLWithPath: "/virtual/Exports"),
                        isStale: true
                    )
                )
            ]
        )
        let staleLocations = try await store.resolveLocations(
            id: record.id,
            resolver: staleResolver
        )
        XCTAssertTrue(staleLocations.sourceBookmarkIsStale)
        XCTAssertTrue(staleLocations.outputBookmarkIsStale)

        let invalidResolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                record.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: URL(fileURLWithPath: "/virtual/source.mov"),
                        isStale: false
                    )
                ),
                record.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: try XCTUnwrap(
                            URL(string: "https://example.com/Exports")
                        ),
                        isStale: false
                    )
                )
            ]
        )
        do {
            _ = try await store.resolveLocations(
                id: record.id,
                resolver: invalidResolver
            )
            XCTFail("A non-file output bookmark was accepted.")
        } catch {
            XCTAssertEqual(
                error as? MirmirWorkHistoryLocationError,
                .invalidFileURL(role: .output)
            )
        }
        let invalidStates = try await store.bookmarkStates(
            id: record.id,
            resolver: invalidResolver,
            availabilityChecker:
                WorkHistoryFakeAvailabilityChecker(
                    availablePaths: []
                )
        )
        XCTAssertEqual(
            invalidStates.output,
            .reauthorizationRequired
        )
    }

    func testSchemaV1RecordWithoutScopeResolvesLegacyFileBookmark()
        async throws {
        let original = makeWorkHistoryRecord(
            id: "job-legacy-output-bookmark",
            completedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        object.removeValue(forKey: "outputBookmarkScope")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacyRecord = try JSONDecoder().decode(
            MirmirWorkHistoryRecord.self,
            from: legacyData
        )
        XCTAssertEqual(legacyRecord.outputBookmarkScope, .file)

        let directory = try temporaryDirectory()
        let store = MirmirWorkHistoryStore(directoryURL: directory)
        _ = try await store.upsert(legacyRecord)
        let sourceURL = URL(fileURLWithPath: "/virtual/source.mov")
        let legacyOutputFileURL = URL(
            fileURLWithPath: "/virtual/Exports/output.mov"
        )
        let resolver = WorkHistoryFakeBookmarkResolver(
            outcomes: [
                legacyRecord.sourceBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: sourceURL,
                        isStale: false
                    )
                ),
                legacyRecord.outputBookmark: .resolved(
                    MirmirWorkHistoryResolvedBookmark(
                        url: legacyOutputFileURL,
                        isStale: false
                    )
                )
            ]
        )

        let locations = try await store.resolveLocations(
            id: legacyRecord.id,
            resolver: resolver
        )
        XCTAssertEqual(
            locations.outputDirectoryURL,
            legacyOutputFileURL.deletingLastPathComponent()
        )
        XCTAssertEqual(locations.outputFileURL, legacyOutputFileURL)
    }

    func testConcurrentUpsertsDoNotLoseRecords() async throws {
        let directory = try temporaryDirectory()
        let limits = try MirmirWorkHistoryLimits(
            maximumRecords: 150,
            maximumDocumentBytes: 2 * 1_024 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let store = MirmirWorkHistoryStore(
            directoryURL: directory,
            limits: limits
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let record = makeWorkHistoryRecord(
                        id: "job-\(index)",
                        completedAt: Date(
                            timeIntervalSinceReferenceDate: Double(index)
                        )
                    )
                    _ = try await store.upsert(record)
                }
            }
            try await group.waitForAll()
        }

        let records = try await store.records()
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(Set(records.map(\.id)).count, 100)
        XCTAssertEqual(records.first?.id, "job-99")
        XCTAssertEqual(records.last?.id, "job-0")
    }
}

private extension MirmirWorkHistoryStoreTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirWorkHistoryStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func assertRejected(
        _ record: MirmirWorkHistoryRecord,
        field: MirmirWorkHistoryRecordField,
        by store: MirmirWorkHistoryStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await store.upsert(record)
            XCTFail("The invalid record was accepted.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? MirmirWorkHistoryStoreError,
                .invalidRecord(field: field),
                file: file,
                line: line
            )
        }
    }
}

private func makeWorkHistoryRecord(
    id: String,
    completedAt: Date,
    sourceDisplayName: String = "source.mov",
    outputDisplayName: String = "output.mov",
    outputBookmarkScope:
        MirmirWorkHistoryOutputBookmarkScope = .directory,
    processingConfiguration: UpscaleProcessingConfiguration = .default,
    terminalResult: MirmirWorkTerminalResult = .completed,
    outputVerification: MirmirWorkOutputVerification =
        .available(identity: "sha256:verified-output"),
    sourceAudioTrackCount: Int? = 2,
    sourceScanStructure: MediaVideoScanStructure? = .progressive,
    sourceBookmark: Data = Data("source-bookmark".utf8),
    outputBookmark: Data = Data("output-bookmark".utf8)
) -> MirmirWorkHistoryRecord {
    MirmirWorkHistoryRecord(
        id: id,
        sourceBookmark: sourceBookmark,
        outputBookmark: outputBookmark,
        outputBookmarkScope: outputBookmarkScope,
        sourceDisplayName: sourceDisplayName,
        outputDisplayName: outputDisplayName,
        sourceResolution: VideoResolution(width: 1_920, height: 1_080),
        targetResolution: VideoResolution(width: 3_840, height: 2_160),
        codec: .hevc,
        sourceAudioTrackCount: sourceAudioTrackCount,
        sourceScanStructure: sourceScanStructure,
        preserveAudio: true,
        requestedMode: .quality,
        processingConfiguration: processingConfiguration,
        createdAt: completedAt.addingTimeInterval(-2),
        startedAt: completedAt.addingTimeInterval(-1),
        completedAt: completedAt,
        terminalResult: terminalResult,
        outputVerification: outputVerification
    )
}

private struct WorkHistoryBookmarkLocation: Equatable, Sendable {
    let role: MirmirWorkHistoryBookmarkRole
    let url: URL
}

private final class WorkHistoryBookmarkCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var resolvedRoleStorage:
        [MirmirWorkHistoryBookmarkRole] = []
    private var createdLocationStorage:
        [WorkHistoryBookmarkLocation] = []

    func appendResolvedRole(_ role: MirmirWorkHistoryBookmarkRole) {
        lock.lock()
        resolvedRoleStorage.append(role)
        lock.unlock()
    }

    func appendCreatedLocation(
        role: MirmirWorkHistoryBookmarkRole,
        url: URL
    ) {
        lock.lock()
        createdLocationStorage.append(
            WorkHistoryBookmarkLocation(role: role, url: url)
        )
        lock.unlock()
    }

    var resolvedRoles: [MirmirWorkHistoryBookmarkRole] {
        lock.lock()
        defer { lock.unlock() }
        return resolvedRoleStorage
    }

    var createdLocations: [WorkHistoryBookmarkLocation] {
        lock.lock()
        defer { lock.unlock() }
        return createdLocationStorage
    }
}

private struct WorkHistoryFakeBookmarkResolver:
    MirmirWorkHistoryBookmarkResolving {
    enum Outcome: Sendable {
        case resolved(MirmirWorkHistoryResolvedBookmark)
        case failed
    }

    let outcomes: [Data: Outcome]
    private let callLog = WorkHistoryBookmarkCallLog()

    var resolvedRoles: [MirmirWorkHistoryBookmarkRole] {
        callLog.resolvedRoles
    }

    var createdLocations: [WorkHistoryBookmarkLocation] {
        callLog.createdLocations
    }

    func makeBookmark(
        for url: URL,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> Data {
        callLog.appendCreatedLocation(role: role, url: url)
        return Data("created-\(role.rawValue)".utf8)
    }

    func resolveBookmark(
        _ bookmark: Data,
        role: MirmirWorkHistoryBookmarkRole
    ) throws -> MirmirWorkHistoryResolvedBookmark {
        callLog.appendResolvedRole(role)
        switch outcomes[bookmark] {
        case .resolved(let resolved):
            return resolved
        case .failed, nil:
            throw MirmirWorkHistoryBookmarkError.resolutionFailed(role: role)
        }
    }
}

private struct WorkHistoryFakeAvailabilityChecker:
    MirmirWorkFileAvailabilityChecking {
    let availablePaths: Set<String>

    func isAvailable(at url: URL) -> Bool {
        availablePaths.contains(url.path)
    }
}

private final class WorkHistorySecurityScopeAudit: @unchecked Sendable {
    private struct State {
        var activeURLs: Set<URL> = []
        var events: [String] = []
    }

    private let lock = NSLock()
    private var state = State()

    var activeScopeCount: Int {
        lock.withLock { state.activeURLs.count }
    }

    var events: [String] {
        lock.withLock { state.events }
    }

    var resourceAccess: MirmirSecurityScopedResourceAccess {
        MirmirSecurityScopedResourceAccess(
            startAccessing: { [weak self] url in
                self?.lock.withLock {
                    self?.state.activeURLs.insert(url)
                    self?.state.events.append("start:\(url.path)")
                }
                return true
            },
            stopAccessing: { [weak self] url in
                self?.lock.withLock {
                    self?.state.events.append("stop:\(url.path)")
                    self?.state.activeURLs.remove(url)
                }
            },
            canCreateBookmark: { _ in true }
        )
    }

    func recordAvailabilityCheck(at url: URL) -> Bool {
        lock.withLock {
            state.events.append("check:\(url.path)")
            return !state.activeURLs.isEmpty
        }
    }
}

private struct WorkHistoryScopeCheckingAvailabilityChecker:
    MirmirWorkFileAvailabilityChecking {
    let audit: WorkHistorySecurityScopeAudit

    func isAvailable(at url: URL) -> Bool {
        audit.recordAvailabilityCheck(at: url)
    }
}
