import XCTest
@testable import Mirmir

final class R13ReleaseDiagnosticsTests: XCTestCase {
    func testZeroSampleBufferDoesNotChangeFrameCount() throws {
        XCTAssertEqual(
            try R13AVFoundationSourceFrameCounter.addingSampleCount(
                0,
                to: 8_494
            ),
            8_494
        )
    }

    func testPositiveSampleBufferAddsToFrameCount() throws {
        XCTAssertEqual(
            try R13AVFoundationSourceFrameCounter.addingSampleCount(
                2,
                to: 8_494
            ),
            8_496
        )
    }

    func testSampleCountOverflowStillFailsClosed() {
        XCTAssertThrowsError(
            try R13AVFoundationSourceFrameCounter.addingSampleCount(
                1,
                to: .max
            )
        ) {
            XCTAssertEqual(
                $0 as? R13ReleaseEnvironmentError,
                .arithmeticOverflow(field: "source_frame_count")
            )
        }
    }

    func testHardeningRecorderMirrorsOnlyWarningsAndErrorsPersistently()
        async throws {
        let diagnostics = R13ReleaseDiagnostics(
            policy: try R13ReleaseDiagnosticsPolicy(
                maximumRecords: 8,
                maximumTotalBytes: 8_192
            )
        )
        let persistentStore = MirmirDiagnosticStore()
        let correlationID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000013"
        )!
        let jobIdentity = hash("a")
        let recorder = R13ReleaseHardeningDiagnosticRecorder(
            diagnostics: diagnostics,
            jobIdentitySHA256: jobIdentity,
            policyResources: try R13ReleasePolicyResourceBinding(
                policySHA256: hash("b"),
                resourceManifestSHA256: hash("c")
            ),
            persistentDiagnostics: MirmirDiagnosticRecorder(
                store: persistentStore
            ),
            correlationID: correlationID
        )

        try await recorder.recordCacheCommit()
        try await recorder.recordFault(point: .beforeMetadataReopen)
        try await recorder.recordSourceSnapshotCleanupFailed()

        let ringSnapshot = await diagnostics.snapshot()
        XCTAssertEqual(
            ringSnapshot.records.map(\.event.code),
            [
                .cacheFrameCommitted,
                .faultObserved,
                .sourceSnapshotCleanupFailed
            ]
        )

        let persistentSnapshot = try await persistentStore.snapshot()
        XCTAssertEqual(
            persistentSnapshot.records.map(\.event.code.rawValue),
            [
                "fault_observed",
                "source_snapshot_cleanup_failed"
            ]
        )
        XCTAssertEqual(
            persistentSnapshot.records.map(\.event.severity),
            [.warning, .error]
        )
        XCTAssertEqual(
            persistentSnapshot.records.map(\.event.correlationID?.rawValue),
            [
                correlationID.uuidString.lowercased(),
                correlationID.uuidString.lowercased()
            ]
        )

        let warningFields = fields(
            in: try XCTUnwrap(persistentSnapshot.records.first)
        )
        XCTAssertEqual(
            warningFields,
            [
                "fault_point": "before_metadata_reopen",
                "job_identity_sha256": jobIdentity,
                "outcome": "rejected",
                "reason": "injected_fault"
            ]
        )
        let errorFields = fields(
            in: try XCTUnwrap(persistentSnapshot.records.last)
        )
        XCTAssertEqual(
            errorFields,
            [
                "job_identity_sha256": jobIdentity,
                "outcome": "not_observed",
                "reason": "source_snapshot_cleanup_failed"
            ]
        )
        XCTAssertFalse(
            persistentSnapshot.records.contains {
                $0.event.code.rawValue == "cache_frame_committed"
            }
        )
        let persistentJSON = try await persistentStore.exportJSON()
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateJSON(
                persistentJSON
            )
        )
    }

    func testDiagnosticsAreDeterministicallyOrderedAndStrictlyBounded() async throws {
        let policy = try R13ReleaseDiagnosticsPolicy(
            maximumRecords: 2,
            maximumTotalBytes: 4_096
        )
        let diagnostics = R13ReleaseDiagnostics(policy: policy)
        let firstEvent = try event(
            code: .releaseIdentityCreated,
            outcome: .accepted
        )
        let secondEvent = try event(
            code: .resourceAdmitted,
            outcome: .accepted
        )
        let thirdEvent = try event(
            code: .outputReopened,
            outcome: .reopened
        )

        let first = try recorded(await diagnostics.record(firstEvent))
        let second = try recorded(await diagnostics.record(secondEvent))
        let third = try recorded(await diagnostics.record(thirdEvent))

        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(second.sequence, 1)
        XCTAssertEqual(third.sequence, 2)
        XCTAssertEqual(
            first.event.fields.map(\.key.rawValue),
            first.event.fields.map(\.key.rawValue).sorted()
        )

        let snapshot = await diagnostics.snapshot()
        XCTAssertEqual(snapshot.records.map(\.sequence), [1, 2])
        XCTAssertEqual(snapshot.droppedRecordCount, 1)
        XCTAssertEqual(snapshot.nextSequence, 3)
        XCTAssertLessThanOrEqual(snapshot.records.count, policy.maximumRecords)
        XCTAssertLessThanOrEqual(
            snapshot.retainedByteCount,
            policy.maximumTotalBytes
        )
        XCTAssertEqual(
            snapshot.retainedByteCount,
            snapshot.records.reduce(0) { $0 + $1.boundedByteCount }
        )
    }

    func testOversizedRecordIsRejectedWithoutMutatingTheRing() async throws {
        let diagnosticEvent = try event(
            code: .resourceRejected,
            outcome: .rejected
        )
        let policy = try R13ReleaseDiagnosticsPolicy(
            maximumRecords: 4,
            maximumTotalBytes: diagnosticEvent.boundedByteCount - 1
        )
        let diagnostics = R13ReleaseDiagnostics(policy: policy)

        let outcome = await diagnostics.record(diagnosticEvent)
        XCTAssertEqual(
            outcome,
            .rejected(
                .recordExceedsByteLimit(
                    observed: diagnosticEvent.boundedByteCount,
                    maximum: policy.maximumTotalBytes
                )
            )
        )
        let snapshot = await diagnostics.snapshot()
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(snapshot.retainedByteCount, 0)
        XCTAssertEqual(snapshot.droppedRecordCount, 0)
        XCTAssertEqual(snapshot.nextSequence, 0)
    }

    func testClosedFieldsRejectInvalidHashesDuplicatesAndFieldOverflow() throws {
        XCTAssertThrowsError(
            try R13ReleaseDiagnosticField.releaseIdentitySHA256(
                "operator@example.com"
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseDiagnosticsError,
                .invalidSHA256(
                    field: "diagnostic_release_identity_sha256"
                )
            )
        }

        let duplicate = R13ReleaseDiagnosticField.outcome(.accepted)
        XCTAssertThrowsError(
            try R13ReleaseDiagnosticEvent(
                code: .resourceAdmitted,
                severity: .info,
                fields: [duplicate, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseDiagnosticsError,
                .duplicateField("outcome")
            )
        }

        let overflowFields = try [
            R13ReleaseDiagnosticField.releaseIdentitySHA256(hash("1")),
            R13ReleaseDiagnosticField.jobIdentitySHA256(hash("2")),
            R13ReleaseDiagnosticField.policySHA256(hash("3")),
            R13ReleaseDiagnosticField.resourceManifestSHA256(hash("4")),
            R13ReleaseDiagnosticField.mode(.quality),
            R13ReleaseDiagnosticField.a11Backend,
            R13ReleaseDiagnosticField.route(.scale2x),
            R13ReleaseDiagnosticField.outcome(.rejected),
            R13ReleaseDiagnosticField.reason(.thermalLimited)
        ]
        XCTAssertThrowsError(
            try R13ReleaseDiagnosticEvent(
                code: .resourceRejected,
                severity: .warning,
                fields: overflowFields
            )
        ) { error in
            XCTAssertEqual(
                error as? R13ReleaseDiagnosticsError,
                .tooManyFields(maximum: 8)
            )
        }
    }

    func testRetainedDiagnosticsContainOnlyClosedNonSecretValues() async throws {
        let diagnostics = R13ReleaseDiagnostics(
            policy: try R13ReleaseDiagnosticsPolicy(
                maximumRecords: 4,
                maximumTotalBytes: 4_096
            )
        )
        let diagnosticEvent = try R13ReleaseDiagnosticEvent(
            code: .faultObserved,
            severity: .warning,
            fields: [
                try .releaseIdentitySHA256(hash("a")),
                try .jobIdentitySHA256(hash("b")),
                .mode(.deterministic),
                .a11Backend,
                .route(.scale2x),
                .outcome(.notObserved),
                .reason(.injectedFault),
                .faultPoint(.beforeMetadataReopen)
            ]
        )
        _ = await diagnostics.record(diagnosticEvent)

        let snapshot = await diagnostics.snapshot()
        let retained = snapshot.records.flatMap(\.event.fields)
        XCTAssertEqual(retained.count, 8)
        for field in retained {
            XCTAssertLessThanOrEqual(field.value.utf8.count, 64)
            XCTAssertFalse(field.value.contains("@"))
            XCTAssertFalse(field.value.contains("/"))
            XCTAssertFalse(field.value.contains("\\"))
            XCTAssertFalse(field.value.contains("\n"))
            XCTAssertFalse(field.value.lowercased().contains("password"))
            XCTAssertFalse(field.value.lowercased().contains("secret"))
            XCTAssertFalse(field.value.lowercased().contains("token"))
        }
    }
}

private extension R13ReleaseDiagnosticsTests {
    func event(
        code: R13ReleaseDiagnosticCode,
        outcome: R13ReleaseDiagnosticOutcome
    ) throws -> R13ReleaseDiagnosticEvent {
        try R13ReleaseDiagnosticEvent(
            code: code,
            severity: .info,
            fields: [
                .a11Backend,
                .route(.scale2x),
                .mode(.quality),
                .outcome(outcome)
            ]
        )
    }

    func recorded(
        _ outcome: R13ReleaseDiagnosticWriteOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> R13ReleaseDiagnosticRecord {
        guard case .recorded(let record) = outcome else {
            XCTFail("Expected a retained R13 diagnostic", file: file, line: line)
            throw UnexpectedDiagnosticOutcome()
        }
        return record
    }

    func hash(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    func fields(
        in record: MirmirDiagnosticRecord
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
    }
}

private struct UnexpectedDiagnosticOutcome: Error {}

struct R13HardeningFixture {
    let root: URL
    let jobsRoot: URL
    let sourceURL: URL
    let outputDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        jobsRoot = root.appendingPathComponent("Jobs", isDirectory: true)
        sourceURL = root.appendingPathComponent("source.mov")
        outputDirectory = root.appendingPathComponent(
            "Output",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try Data("r13-hardening-source".utf8).write(to: sourceURL)
    }

    var sourceProfile: SourceProfile {
        SourceProfile(
            url: sourceURL,
            resolution: .p720,
            frameRate: 30,
            durationSeconds: 1.0 / 30.0,
            estimatedFrameCount: 1,
            codecHint: "r13-test",
            hasAudio: false
        )
    }

    func makeJob(identifier: String) -> UpscaleJob {
        UpscaleJob(
            identifier: identifier,
            inputURL: sourceURL,
            outputURL: outputDirectory.appendingPathComponent(
                "\(identifier).mp4"
            ),
            targetResolution: .p1080,
            codec: .hevc,
            preserveAudio: false,
            mode: .deterministic
        )
    }

    func jobDirectory(identifier: String) -> URL {
        jobsRoot.appendingPathComponent(identifier, isDirectory: true)
    }

    func makeRuntime(
        cacheProbe: R13CapacityProbe,
        outputProbe: R13CapacityProbe,
        sameVolume: Bool = false
    ) throws -> R13ReleaseHardeningRuntime {
        let documents = try R13ReleaseHardeningDocuments.production()
        let governor = R13ResourceGovernor(
            policy: documents.resourcePolicy,
            probes: R13ResourceProbes(
                availableDiskBytes: { cacheProbe.capacity },
                availableMemoryBytes: { UInt64.max },
                thermalCondition: { .nominal }
            )
        )
        return R13ReleaseHardeningRuntime(
            jobsRootURL: jobsRoot,
            sourceMeasurer: R13LocalRestartSourceMeasurer(),
            frameCounter: R13FixedFrameCounter(frameCount: 1),
            environmentCollector: try R13FixedEnvironmentCollector(),
            documents: documents,
            bookmarkResolver: R13TestBookmarkResolver(),
            storagePreflight: R13StoragePreflight(
                capacityProbe: cacheProbe,
                volumeTopologyProbe: R13FixedVolumeTopologyProbe(
                    result: sameVolume
                )
            ),
            outputCapacityProbe: outputProbe,
            resourceGovernor: governor,
            faultInjector: R13ProductionNoOpFaultInjector(),
            diagnostics: R13ReleaseDiagnostics(
                policy: try R13ReleaseDiagnosticsPolicy(
                    maximumRecords: 64,
                    maximumTotalBytes: 65_536
                )
            ),
            sourceSnapshotter: R13LocalSourceSnapshotter(
                sourceMeasurer: R13LocalRestartSourceMeasurer(),
                capacityProbe: R13CapacityProbe(
                    capacity: UInt64.max
                ),
                minimumFreeDiskBytes:
                    documents.resourcePolicy.minimumFreeDiskBytes
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

struct R13FixedVolumeTopologyProbe: R13VolumeTopologyProbing {
    let result: Bool

    func sharesVolume(_: URL, _: URL) throws -> Bool {
        result
    }
}

final class R13CapacityProbe: R13AvailableCapacityProbing,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedCapacity: UInt64
    private var storedURLs: [URL] = []

    init(capacity: UInt64) {
        storedCapacity = capacity
    }

    var capacity: UInt64 {
        get { lock.withLock { storedCapacity } }
        set { lock.withLock { storedCapacity = newValue } }
    }

    var probedURLs: [URL] {
        lock.withLock { storedURLs }
    }

    func availableCapacityForImportantUsage(at url: URL) throws -> UInt64 {
        lock.withLock {
            storedURLs.append(url.standardizedFileURL)
            return storedCapacity
        }
    }
}

struct R13FixedFrameCounter: R13SourceFrameCountMeasuring {
    let frameCount: Int

    func exactVideoFrameCount(at _: URL) async throws -> Int {
        frameCount
    }
}

struct R13FixedEnvironmentCollector:
    R13ReleaseEnvironmentCollecting {
    private let environment: R13ReleaseEnvironment

    init() throws {
        environment = try R13ReleaseEnvironment(
            application: R13ReleaseApplicationIdentity(
                bundleIdentifier: "com.mirmir.tests",
                semanticVersion: "1.0.0",
                buildVersion: "1",
                executableSHA256: String(repeating: "a", count: 64),
                executableByteCount: 1
            ),
            framework: R13ReleaseFrameworkIdentity(
                frameworkIdentifier:
                    R03A11ProductAdmission.frameworkIdentity,
                version: "1.0",
                buildIdentity: "test-build"
            ),
            runtime: R13ReleaseRuntimeIdentity(
                runtimeIdentifier: "macOS",
                version: "1.0",
                buildIdentity: "test-build",
                architecture: "arm64"
            )
        )
    }

    func collect() throws -> R13ReleaseEnvironment {
        environment
    }
}

struct R13TestBookmarkResolver: R13SecurityScopedBookmarkResolving {
    func makeBookmark(
        for url: URL,
        role: R13BookmarkRole
    ) throws -> Data {
        Data("\(role.rawValue)\u{0}\(url.path)".utf8)
    }

    func resolveBookmark(
        _ data: Data,
        role: R13BookmarkRole
    ) throws -> R13ResolvedSecurityScopedBookmark {
        guard let value = String(data: data, encoding: .utf8),
              let separator = value.firstIndex(of: "\u{0}") else {
            throw R13RestartJobError.bookmarkResolutionFailed(role: role)
        }
        let path = String(value[value.index(after: separator)...])
        return R13ResolvedSecurityScopedBookmark(
            url: URL(fileURLWithPath: path),
            isStale: false,
            startAccessing: { true },
            stopAccessing: {}
        )
    }
}
