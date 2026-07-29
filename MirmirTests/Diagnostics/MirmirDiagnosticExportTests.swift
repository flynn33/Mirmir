import Foundation
import XCTest
@testable import Mirmir

final class MirmirDiagnosticExportTests: XCTestCase {
    func testJSONExportIsDeterministicAndRoundTrips() async throws {
        let clock = ExportTestClock(wall: 1_000, uptime: 123)
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            clock: clock.clock,
            sessionID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!
        )
        _ = try await store.record(incidentEvent())
        clock.set(wall: 2_000, uptime: 456)

        let snapshot = try await store.snapshot()
        let first = try MirmirDiagnosticExport.json(snapshot)
        let second = try MirmirDiagnosticExport.json(snapshot)
        let decoded = try JSONDecoder().decode(
            MirmirDiagnosticSnapshot.self,
            from: first
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(first.last, 0x0A)
        XCTAssertFalse(first.dropLast().last == 0x0A)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.contains(#""schema_version" : 1"#))
        XCTAssertTrue(text.contains(#""actual_decoded_dimensions""#))
        XCTAssertFalse(text.contains("\\/"))
    }

    func testMarkdownExportHasExactStableLayout() async throws {
        let clock = ExportTestClock(wall: 1_000, uptime: 123)
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            clock: clock.clock,
            sessionID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!
        )
        _ = try await store.record(incidentEvent())
        clock.set(wall: 2_000, uptime: 456)
        let snapshot = try await store.snapshot()

        let markdown = try XCTUnwrap(
            String(
                data: MirmirDiagnosticExport.markdown(snapshot),
                encoding: .utf8
            )
        )
        let expected = """
        # Mirmir Diagnostic Log

        - Schema version: 1
        - Exported at: 1970-01-01T00:00:02.000Z
        - Retained records: 1
        - Retained bytes: \(snapshot.retainedByteCount)
        - Pruned records: 0
        - Rejected records: 0
        - Recovered corrupt tails: 0
        - Recovered corrupt bytes: 0

        ## Records

        ### Record 00000000000000000000

        - Timestamp: 1970-01-01T00:00:01.000Z
        - Severity: error
        - Subsystem: media\\_pipeline
        - Operation: normalize\\_frame
        - Code: media\\_frame\\_geometry\\_mismatch
        - Session: 00000000-0000-0000-0000-000000000001
        - Correlation: 00000000-0000-0000-0000-000000000002
        - Uptime ns: 123
        - actual\\_decoded\\_dimensions: 1440x1080
        - coded\\_dimensions: 1440x1080
        - expected\\_normalized\\_dimensions: 1920x1080
        - frame\\_index: 0
        - pixel\\_aspect\\_ratio: 4/3
        - presentation\\_dimensions: 1920x1080

        """
        XCTAssertEqual(markdown, expected)
    }

    func testPrivateInputAndRawErrorsNeverReachPersistenceOrExports() async throws {
        let fixture = try ExportStoreFixture()
        defer { fixture.cleanup() }
        let privatePayload =
            "/Users/alice/Secret Client/person@example.com/"
            + "token-sk_test_SENTINEL/input.MP4 AQIDBA=="
        let underlying = NSError(
            domain: "NSPOSIXErrorDomain",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: privatePayload]
        )
        let rawError = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11_800,
            userInfo: [
                NSLocalizedDescriptionKey: privatePayload,
                NSUnderlyingErrorKey: underlying,
                "bookmark": Data([1, 2, 3, 4])
            ]
        )
        let resource = try MirmirDiagnosticResourceReference(
            role: "source_video",
            correlationID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000003"
            )!,
            fileExtension: "MP4",
            location: .userSelected
        )
        let diagnosticEvent = try MirmirDiagnosticEvent(
            severity: .error,
            subsystem: "media_pipeline",
            operation: "open_source",
            code: "media_source_open_failed",
            fields: [
                try MirmirDiagnosticField(
                    key: "private_input",
                    value: .redacting(privatePayload)
                ),
                try MirmirDiagnosticField(
                    key: "source_resource",
                    value: .resource(resource)
                )
            ],
            error: MirmirDiagnosticErrorIdentity(rawError)
        )
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: .production,
            clock: MirmirDiagnosticClock(
                wallMilliseconds: { 3_000 },
                uptimeNanoseconds: { 300 }
            )
        )
        _ = try await store.record(diagnosticEvent)

        let persisted = try Data(contentsOf: fixture.journalURL)
        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        for data in [persisted, json, markdown] {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            assertPrivateFixtureIsAbsent(from: text)
        }

        let snapshot = try await store.snapshot()
        let fields = try XCTUnwrap(snapshot.records.first?.event.fields)
        XCTAssertEqual(
            fields.first(where: {
                $0.key.rawValue == "private_input"
            })?.value.displayValue,
            "<redacted>"
        )
        XCTAssertEqual(
            fields.first(where: {
                $0.key.rawValue == "source_resource"
            })?.value.displayValue,
            "source_video:00000000-0000-0000-0000-000000000003:mp4:user_selected"
        )
        XCTAssertEqual(
            snapshot.records.first?.event.error?.frames.map(\.domain),
            ["AVFoundationErrorDomain", "NSPOSIXErrorDomain"]
        )
        XCTAssertEqual(
            snapshot.records.first?.event.error?.frames.map(\.code),
            [-11_800, 5]
        )
    }

    func testPrivacyValidatorRejectsRawPrivateDocuments() {
        let values = [
            "/Users/alice/input.mp4",
            "person@example.com",
            "sk_test_SENTINEL",
            "file:///private/input.mov"
        ]
        for value in values {
            XCTAssertThrowsError(
                try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                    value
                )
            ) {
                XCTAssertEqual(
                    $0 as? MirmirDiagnosticValidationError,
                    .privacyViolation
                )
            }
        }
    }

    func testEmptyExportsAreDeterministicAndEndInSingleNewline() throws {
        let snapshot = try MirmirDiagnosticSnapshot(
            exportedAtUnixMilliseconds: 0,
            retainedByteCount: 0,
            prunedRecordCount: 0,
            rejectedRecordCount: 0,
            recoveredCorruptTailCount: 0,
            recoveredCorruptByteCount: 0,
            records: []
        )

        let json = try MirmirDiagnosticExport.json(snapshot)
        let markdown = try MirmirDiagnosticExport.markdown(snapshot)

        XCTAssertEqual(json.last, 0x0A)
        XCTAssertFalse(json.dropLast().last == 0x0A)
        XCTAssertEqual(markdown.last, 0x0A)
        XCTAssertFalse(markdown.dropLast().last == 0x0A)
        XCTAssertEqual(
            String(data: markdown, encoding: .utf8),
            """
            # Mirmir Diagnostic Log

            - Schema version: 1
            - Exported at: 1970-01-01T00:00:00.000Z
            - Retained records: 0
            - Retained bytes: 0
            - Pruned records: 0
            - Rejected records: 0
            - Recovered corrupt tails: 0
            - Recovered corrupt bytes: 0

            ## Records

            """
        )
    }
}

private extension MirmirDiagnosticExportTests {
    func incidentEvent() throws -> MirmirDiagnosticEvent {
        try MirmirDiagnosticEvent(
            severity: .error,
            subsystem: "media_pipeline",
            operation: "normalize_frame",
            code: "media_frame_geometry_mismatch",
            correlationID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000002"
            ),
            fields: [
                try MirmirDiagnosticField(
                    key: "presentation_dimensions",
                    value: .dimensions(width: 1_920, height: 1_080)
                ),
                try MirmirDiagnosticField(
                    key: "coded_dimensions",
                    value: .dimensions(width: 1_440, height: 1_080)
                ),
                try MirmirDiagnosticField(
                    key: "actual_decoded_dimensions",
                    value: .dimensions(width: 1_440, height: 1_080)
                ),
                try MirmirDiagnosticField(
                    key: "expected_normalized_dimensions",
                    value: .dimensions(width: 1_920, height: 1_080)
                ),
                try MirmirDiagnosticField(
                    key: "pixel_aspect_ratio",
                    value: .rational(numerator: 4, denominator: 3)
                ),
                try MirmirDiagnosticField(
                    key: "frame_index",
                    value: .signedInteger(0)
                )
            ]
        )
    }

    func assertPrivateFixtureIsAbsent(
        from value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for forbidden in [
            "alice",
            "Secret Client",
            "person@example.com",
            "sk_test_SENTINEL",
            "/Users/",
            "file://",
            "AQIDBA=="
        ] {
            XCTAssertFalse(
                value.contains(forbidden),
                "Found forbidden diagnostic value: \(forbidden)",
                file: file,
                line: line
            )
        }
    }
}

private final class ExportTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Int64
    private var uptime: UInt64

    init(wall: Int64, uptime: UInt64) {
        self.wall = wall
        self.uptime = uptime
    }

    var clock: MirmirDiagnosticClock {
        MirmirDiagnosticClock(
            wallMilliseconds: { [self] in lock.withLock { wall } },
            uptimeNanoseconds: { [self] in lock.withLock { uptime } }
        )
    }

    func set(wall: Int64, uptime: UInt64) {
        lock.withLock {
            self.wall = wall
            self.uptime = uptime
        }
    }
}

private struct ExportStoreFixture {
    let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-diagnostic-export-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    var journalURL: URL {
        directoryURL.appendingPathComponent(
            MirmirDiagnosticStore.journalFileName,
            isDirectory: false
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
