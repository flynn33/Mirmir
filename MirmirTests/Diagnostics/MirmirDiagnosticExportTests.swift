import AVFoundation
import Foundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class MirmirDiagnosticExportTests: XCTestCase {
    func testMPSTextureLimitExportsRequestedGeometryAndHardwareLimit()
        async throws {
        let store = MirmirDiagnosticStore()
        let error = R03MPSTextureDimensionLimitError(
            maximumTextureDimension2D: 8_192,
            sourceResolution: VideoResolution(
                width: 8_192,
                height: 4_608
            ),
            targetResolution: VideoResolution(
                width: 10_240,
                height: 5_760
            )
        )

        await MirmirDiagnosticRecorder(store: store).record(
            severity: .error,
            subsystem: "release_engine",
            operation: "adaptive_scaler_preflight",
            code: "release_adaptive_scaler_preflight_failed",
            error: error
        )

        let snapshot = try await store.snapshot()
        let record = try XCTUnwrap(snapshot.records.first)
        let fields = Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(
            fields["failure_category"],
            "mps_texture_dimension_limit_exceeded"
        )
        XCTAssertEqual(
            fields["maximum_texture_dimension_2d"],
            "8192"
        )
        XCTAssertEqual(
            fields["requested_source_dimensions"],
            "8192x4608"
        )
        XCTAssertEqual(
            fields["requested_target_dimensions"],
            "10240x5760"
        )
    }

    func testNegativeSourceTimelineExportsStructuredTimingEvidence()
        async throws {
        let store = MirmirDiagnosticStore()
        let error = MediaPipelineError.unsupportedNegativeSourceTimeline(
            mediaType: "video",
            start: CMTime(value: -1, timescale: 30),
            end: CMTime(value: 29, timescale: 30)
        )

        await MirmirDiagnosticRecorder(store: store).record(
            severity: .error,
            subsystem: "media",
            operation: "media_session_start",
            code: "media_session_start_failed",
            error: error
        )

        let snapshot = try await store.snapshot()
        let record = try XCTUnwrap(snapshot.records.first)
        let fields = Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(
            fields["failure_category"],
            "unsupported_negative_source_timeline"
        )
        XCTAssertEqual(
            fields["source_timeline_media_type"],
            "video"
        )
        XCTAssertEqual(fields["source_timeline_start_value"], "-1")
        XCTAssertEqual(fields["source_timeline_start_timescale"], "30")
        XCTAssertEqual(fields["source_timeline_end_value"], "29")
        XCTAssertEqual(fields["source_timeline_end_timescale"], "30")
    }

    func testFinalMuxFailureExportsUnderlyingIdentityWithoutPath()
        async throws {
        let store = MirmirDiagnosticStore()
        let privateOutputURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/person@example.com/"
                + "token-sk_test_SENTINEL/output.mp4"
        )
        let underlying = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.operationNotSupportedForAsset.rawValue
        )
        let error = MediaPipelineError.finalMuxFailed(
            privateOutputURL,
            underlying
        )

        await MirmirDiagnosticRecorder(store: store).record(
            severity: .error,
            subsystem: "media_pipeline",
            operation: "final_sample_copy_mux",
            code: "final_mux_failed",
            error: error
        )

        let snapshot = try await store.snapshot()
        let record = try XCTUnwrap(snapshot.records.first)
        let fields = Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(fields["failure_category"], "final_mux_failed")
        XCTAssertEqual(record.event.error?.frames.count, 2)
        XCTAssertEqual(
            record.event.error?.frames.last?.domain,
            AVFoundationErrorDomain
        )
        XCTAssertEqual(
            record.event.error?.frames.last?.code,
            AVError.operationNotSupportedForAsset.rawValue
        )

        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let markdownText = try XCTUnwrap(
            String(data: markdown, encoding: .utf8)
        )
        for exportedText in [jsonText, markdownText] {
            XCTAssertFalse(exportedText.contains(privateOutputURL.path))
            XCTAssertFalse(exportedText.contains("Secret Client"))
            XCTAssertFalse(exportedText.contains("person@example.com"))
            XCTAssertFalse(exportedText.contains("token-sk_test_SENTINEL"))
        }
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateJSON(json)
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                markdownText
            )
        )
    }

    // This privacy contract is intentionally verified end to end.
    // swiftlint:disable:next function_body_length
    func testFinalMuxGuardsExportDistinctStructuredPrivateSafeMetadata()
        async throws {
        struct GuardCase {
            let error: FinalMuxGuardError
            let reason: String
            let phase: String
            let code: Int
            let countKind: String
            let expectedCount: String
            let actualCount: String
            let trackKind: String?
        }

        let cases = [
            GuardCase(
                error: .stagingVideoTrackCount(expected: 1, actual: 0),
                reason: "staging_video_track_count_mismatch",
                phase: "staging_inspection",
                code: 1_001,
                countKind: "video_track",
                expectedCount: "1",
                actualCount: "0",
                trackKind: nil
            ),
            GuardCase(
                error: .stagingMetadataTrackCount(expected: 1, actual: 2),
                reason: "staging_metadata_track_count_mismatch",
                phase: "staging_inspection",
                code: 1_002,
                countKind: "metadata_track",
                expectedCount: "1",
                actualCount: "2",
                trackKind: nil
            ),
            GuardCase(
                error: .temporaryOutputAlreadyExists,
                reason: "temporary_output_already_exists",
                phase: "destination_preparation",
                code: 1_003,
                countKind: "temporary_output",
                expectedCount: "0",
                actualCount: "1",
                trackKind: nil
            ),
            GuardCase(
                error: .destinationTrackCreationFailed(trackKind: .audio),
                reason: "destination_track_creation_failed",
                phase: "destination_track_creation",
                code: 1_004,
                countKind: "destination_track",
                expectedCount: "1",
                actualCount: "0",
                trackKind: "audio"
            )
        ]
        let privateOutputURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/person@example.com/"
                + "token-sk_test_SENTINEL/output.mp4"
        )
        let store = MirmirDiagnosticStore()
        let recorder = MirmirDiagnosticRecorder(store: store)

        for testCase in cases {
            await recorder.record(
                severity: .error,
                subsystem: "media_pipeline",
                operation: "final_sample_copy_mux",
                code: "final_mux_failed",
                error: MediaPipelineError.finalMuxFailed(
                    privateOutputURL,
                    testCase.error
                )
            )
        }

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, cases.count)
        for (record, testCase) in zip(snapshot.records, cases) {
            let fields = Dictionary(
                uniqueKeysWithValues: record.event.fields.map {
                    ($0.key.rawValue, $0.value.displayValue)
                }
            )
            XCTAssertEqual(fields["failure_category"], "final_mux_failed")
            XCTAssertEqual(
                fields["final_mux_failure_reason"],
                testCase.reason
            )
            XCTAssertEqual(
                fields["final_mux_failure_phase"],
                testCase.phase
            )
            XCTAssertEqual(
                fields["final_mux_guard_code"],
                String(testCase.code)
            )
            XCTAssertEqual(
                fields["final_mux_count_kind"],
                testCase.countKind
            )
            XCTAssertEqual(
                fields["final_mux_expected_count"],
                testCase.expectedCount
            )
            XCTAssertEqual(
                fields["final_mux_actual_count"],
                testCase.actualCount
            )
            XCTAssertEqual(
                fields["final_mux_track_kind"],
                testCase.trackKind
            )
            XCTAssertEqual(
                record.event.error?.frames.last?.domain,
                FinalMuxGuardError.errorDomain
            )
            XCTAssertEqual(
                record.event.error?.frames.last?.code,
                testCase.code
            )
        }

        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let markdownText = try XCTUnwrap(
            String(data: markdown, encoding: .utf8)
        )
        for exportedText in [jsonText, markdownText] {
            assertPrivateFixtureIsAbsent(from: exportedText)
        }
        for testCase in cases {
            XCTAssertTrue(jsonText.contains(testCase.reason))
            XCTAssertTrue(
                markdownText.contains(markdownIdentifier(testCase.reason))
            )
        }
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateJSON(json)
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                markdownText
            )
        )
    }

    // This privacy contract is intentionally verified end to end.
    // swiftlint:disable:next function_body_length
    func testPrimaryMuxAndCleanupFailuresRemainSeparatePrivateSafeRecords()
        async throws {
        let privateOutputURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/person@example.com/"
                + "token-sk_test_SENTINEL/output.mp4"
        )
        let privateStagingURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/person@example.com/"
                + "token-sk_test_SENTINEL/.private-stage.mp4"
        )
        let store = MirmirDiagnosticStore()
        let recorder = MirmirDiagnosticRecorder(store: store)

        await recorder.record(
            severity: .error,
            subsystem: "release_engine",
            operation: "execute_job",
            code: "release_job_failed",
            error: MediaPipelineError.finalMuxFailed(
                privateOutputURL,
                FinalMuxGuardError.stagingVideoTrackCount(
                    expected: 1,
                    actual: 0
                )
            )
        )
        await recorder.record(
            severity: .error,
            subsystem: "release_engine",
            operation: "cleanup_media_session",
            code: "release_media_cleanup_failed",
            error: MediaPipelineError.partialCleanupFailed(
                privateStagingURL,
                "person@example.com token-sk_test_SENTINEL"
            )
        )

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, 2)
        let primary = try XCTUnwrap(
            snapshot.records.first {
                $0.event.code.rawValue == "release_job_failed"
            }
        )
        let cleanup = try XCTUnwrap(
            snapshot.records.first {
                $0.event.code.rawValue == "release_media_cleanup_failed"
            }
        )
        let primaryFields = Dictionary(
            uniqueKeysWithValues: primary.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        let cleanupFields = Dictionary(
            uniqueKeysWithValues: cleanup.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(
            primaryFields["failure_category"],
            "final_mux_failed"
        )
        XCTAssertEqual(
            primaryFields["final_mux_failure_reason"],
            "staging_video_track_count_mismatch"
        )
        XCTAssertEqual(
            cleanupFields["failure_category"],
            "partial_cleanup_failed"
        )
        XCTAssertEqual(primary.event.error?.frames.count, 2)
        XCTAssertEqual(cleanup.event.error?.frames.count, 1)

        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let markdownText = try XCTUnwrap(
            String(data: markdown, encoding: .utf8)
        )
        for exportedText in [jsonText, markdownText] {
            assertPrivateFixtureIsAbsent(from: exportedText)
        }
        XCTAssertTrue(
            jsonText.contains("staging_video_track_count_mismatch")
        )
        XCTAssertTrue(jsonText.contains("partial_cleanup_failed"))
        XCTAssertTrue(
            markdownText.contains(
                markdownIdentifier("staging_video_track_count_mismatch")
            )
        )
        XCTAssertTrue(
            markdownText.contains(
                markdownIdentifier("partial_cleanup_failed")
            )
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateJSON(json)
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                markdownText
            )
        )
    }

    func testOutputVerificationFailureExportsExactTimingEvidenceWithoutPath()
        async throws {
        let store = MirmirDiagnosticStore()
        let privateOutputURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/person@example.com/"
                + "token-sk_test_SENTINEL/output.mp4"
        )
        let expected = CMTime(value: 15_017, timescale: 360_000)
        let actual = CMTime(value: 1_001, timescale: 24_000)
        let error = MediaPipelineError.outputVerificationFailed(
            privateOutputURL,
            OutputMediaVerificationError.frameDurationMismatch(
                frameIndex: 8_493,
                expected: expected,
                actual: actual
            )
        )

        await MirmirDiagnosticRecorder(store: store).record(
            severity: .error,
            subsystem: "release_upscaler",
            operation: "finish_job",
            code: "release_job_failed",
            error: error
        )

        let snapshot = try await store.snapshot()
        let record = try XCTUnwrap(snapshot.records.first)
        let fields = Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(
            fields["failure_category"],
            "output_verification_failed"
        )
        XCTAssertEqual(
            fields["verification_failure_kind"],
            "frame_duration_mismatch"
        )
        XCTAssertEqual(fields["verification_frame_index"], "8493")
        XCTAssertEqual(
            fields["verification_expected_time"],
            "15017/360000"
        )
        XCTAssertEqual(fields["verification_actual_time"], "1001/24000")
        XCTAssertEqual(
            fields["verification_time_delta"],
            "-2/360000"
        )
        XCTAssertEqual(record.event.error?.frames.count, 2)
        XCTAssertTrue(
            record.event.error?.frames.last?.type.contains(
                "OutputMediaVerificationError"
            ) == true
        )

        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let markdownText = try XCTUnwrap(
            String(data: markdown, encoding: .utf8)
        )
        for exportedText in [jsonText, markdownText] {
            XCTAssertFalse(exportedText.contains(privateOutputURL.path))
            XCTAssertFalse(exportedText.contains("Secret Client"))
            XCTAssertFalse(exportedText.contains("person@example.com"))
            XCTAssertFalse(exportedText.contains("token-sk_test_SENTINEL"))
        }
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateJSON(json)
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                markdownText
            )
        )
    }

    // This privacy contract is intentionally verified end to end.
    // swiftlint:disable:next function_body_length
    func testInvalidOutputVerificationTimesRemainInPrivateSafeExports()
        async throws {
        struct InvalidTimeCase {
            let expected: CMTime
            let actual: CMTime
            let expectedValidity: String
            let actualValidity: String
        }

        let privateOutputURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/person@example.com/"
                + "token-sk_test_SENTINEL/output.mp4"
        )
        let cases = [
            InvalidTimeCase(
                expected: .invalid,
                actual: CMTime(value: 1, timescale: 30),
                expectedValidity: "invalid",
                actualValidity: "numeric"
            ),
            InvalidTimeCase(
                expected: CMTime(value: 1, timescale: 30),
                actual: .indefinite,
                expectedValidity: "numeric",
                actualValidity: "indefinite"
            ),
            InvalidTimeCase(
                expected: CMTime(
                    value: 7,
                    timescale: 0,
                    flags: [.valid],
                    epoch: 0
                ),
                actual: CMTime(value: 1, timescale: 30),
                expectedValidity: "nonpositive_timescale",
                actualValidity: "numeric"
            ),
            InvalidTimeCase(
                expected: CMTime(value: 1, timescale: 30),
                actual: CMTime(
                    value: 7,
                    timescale: -30,
                    flags: [.valid],
                    epoch: 0
                ),
                expectedValidity: "numeric",
                actualValidity: "nonpositive_timescale"
            )
        ]
        let store = MirmirDiagnosticStore()
        let recorder = MirmirDiagnosticRecorder(store: store)

        for testCase in cases {
            await recorder.record(
                severity: .error,
                subsystem: "release_upscaler",
                operation: "finish_job",
                code: "release_job_failed",
                error: MediaPipelineError.outputVerificationFailed(
                    privateOutputURL,
                    OutputMediaVerificationError.trackEndMismatch(
                        expected: testCase.expected,
                        actual: testCase.actual
                    )
                )
            )
        }

        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.records.count, cases.count)
        for (record, testCase) in zip(snapshot.records, cases) {
            let fields = Dictionary(
                uniqueKeysWithValues: record.event.fields.map {
                    ($0.key.rawValue, $0.value.displayValue)
                }
            )
            XCTAssertEqual(
                fields["failure_category"],
                "output_verification_failed"
            )
            XCTAssertEqual(
                fields["verification_failure_kind"],
                "track_end_mismatch"
            )
            XCTAssertEqual(
                fields["verification_expected_time_validity"],
                testCase.expectedValidity
            )
            XCTAssertEqual(
                fields["verification_actual_time_validity"],
                testCase.actualValidity
            )
            if testCase.expectedValidity == "numeric" {
                XCTAssertNotNil(fields["verification_expected_time"])
            } else {
                XCTAssertNil(fields["verification_expected_time"])
                XCTAssertNotNil(fields["verification_expected_time_value"])
                XCTAssertNotNil(
                    fields["verification_expected_time_timescale"]
                )
            }
            if testCase.actualValidity == "numeric" {
                XCTAssertNotNil(fields["verification_actual_time"])
            } else {
                XCTAssertNil(fields["verification_actual_time"])
                XCTAssertNotNil(fields["verification_actual_time_value"])
                XCTAssertNotNil(
                    fields["verification_actual_time_timescale"]
                )
            }
        }

        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        let jsonText = try XCTUnwrap(String(data: json, encoding: .utf8))
        let markdownText = try XCTUnwrap(
            String(data: markdown, encoding: .utf8)
        )
        for exportedText in [jsonText, markdownText] {
            assertPrivateFixtureIsAbsent(from: exportedText)
        }
        XCTAssertTrue(jsonText.contains("invalid"))
        XCTAssertTrue(jsonText.contains("indefinite"))
        XCTAssertTrue(jsonText.contains("nonpositive_timescale"))
        XCTAssertTrue(markdownText.contains("invalid"))
        XCTAssertTrue(markdownText.contains("indefinite"))
        XCTAssertTrue(
            markdownText.contains(
                markdownIdentifier("nonpositive_timescale")
            )
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateJSON(json)
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                markdownText
            )
        )
    }

    func testBackendFrameFailureExportsStructuredRootCause() async throws {
        let store = MirmirDiagnosticStore()
        let backend = try R03DeterministicBackend.makeVImage(
            mode: .lanczos3,
            route: .scale2x
        )
        let processingIdentity = try AppleUpscaleProcessingIdentity(
            route: backend.routeIdentity,
            fallbackHistory: []
        )
        let failure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "r03_output_pool_allocation_threshold_exceeded",
            context: AppleUpscaleBackendFailureContext(
                stage: .outputBufferAllocation,
                statusCode: Int(kCVReturnWouldExceedAllocationThreshold)
            )
        )

        await MirmirDiagnosticRecorder(store: store).record(
            severity: .error,
            subsystem: "release_upscaler",
            operation: "process_frame",
            code: "release_frame_processing_failed",
            error: R13BackendFrameProcessingError(
                frameIndex: 4,
                failure: failure
            )
        )

        let snapshot = try await store.snapshot()
        let record = try XCTUnwrap(snapshot.records.first)
        let fields = Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        XCTAssertEqual(
            fields["failure_category"],
            "backend_frame_processing_failed"
        )
        XCTAssertEqual(
            fields["backend_failure_reason"],
            "r03_output_pool_allocation_threshold_exceeded"
        )
        XCTAssertEqual(
            fields["backend_failure_stage"],
            "output_buffer_allocation"
        )
        XCTAssertEqual(
            fields["backend_status_code"],
            String(kCVReturnWouldExceedAllocationThreshold)
        )
        XCTAssertEqual(record.event.error?.frames.count, 2)
        XCTAssertTrue(
            record.event.error?.frames.last?.type.contains(
                "AppleUpscaleBackendFailed"
            ) == true
        )

        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateJSON(json)
        )
        let markdownText = try XCTUnwrap(
            String(data: markdown, encoding: .utf8)
        )
        XCTAssertNoThrow(
            try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                markdownText
            )
        )
    }

    func testQueuedRecorderEventsFlushBeforeImmediateSnapshotAndExports()
        async throws {
        let store = MirmirDiagnosticStore()
        let recorder = MirmirDiagnosticRecorder(store: store)

        recorder.enqueue(
            severity: .info,
            subsystem: "diagnostics_test",
            operation: "queue_flush",
            code: "queued_before_snapshot"
        )
        let snapshot = try await store.snapshot()
        XCTAssertEqual(
            snapshot.records.map(\.event.code.rawValue),
            ["queued_before_snapshot"]
        )

        recorder.enqueue(
            severity: .warning,
            subsystem: "diagnostics_test",
            operation: "queue_flush",
            code: "queued_before_json_export"
        )
        let json = try await store.exportJSON()
        let decoded = try JSONDecoder().decode(
            MirmirDiagnosticSnapshot.self,
            from: json
        )
        XCTAssertEqual(
            decoded.records.map(\.event.code.rawValue),
            [
                "queued_before_snapshot",
                "queued_before_json_export"
            ]
        )

        recorder.enqueue(
            severity: .error,
            subsystem: "diagnostics_test",
            operation: "queue_flush",
            code: "queued_before_markdown_export"
        )
        let markdownData = try await store.exportMarkdown()
        let markdown = try XCTUnwrap(
            String(data: markdownData, encoding: .utf8)
        )
        XCTAssertTrue(
            markdown.contains("- Code: queued\\_before\\_markdown\\_export")
        )
    }

    func testRecorderPersistsFailureGeometryAcrossReopenAndExportsWithoutPrivateDetails() async throws {
        let fixture = try ExportStoreFixture()
        defer { fixture.cleanup() }
        let correlationID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000004"
        )!
        let privateSourceURL = URL(
            fileURLWithPath:
                "/Users/alice/Secret Client/person@example.com/"
                + "token-sk_test_SENTINEL/input.MOV"
        )
        let source = SourceProfile(
            url: privateSourceURL,
            resolution: .p1080,
            codedResolution: VideoResolution(width: 1_440, height: 1_080),
            pixelAspectRatio: VideoPixelAspectRatio(
                horizontalSpacing: 4,
                verticalSpacing: 3
            ),
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "avc1",
            hasAudio: true
        )
        let frame = try diagnosticFrame(
            resolution: VideoResolution(width: 1_440, height: 1_080)
        )
        let privateError = NSError(
            domain: "AVFoundationErrorDomain",
            code: -11_800,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Unable to read \(privateSourceURL.path) AQIDBA=="
            ]
        )
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: .production,
            clock: MirmirDiagnosticClock(
                wallMilliseconds: { 4_000 },
                uptimeNanoseconds: { 400 }
            ),
            sessionID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!
        )

        await MirmirDiagnosticRecorder(store: store).record(
            severity: .error,
            subsystem: "media",
            operation: "normalize_frame",
            code: "media_frame_normalization_failed",
            correlationID: correlationID,
            source: source,
            frame: frame,
            expectedFrameResolution: .p1080,
            resources: [
                MirmirDiagnosticResourceInput(
                    role: "source_video",
                    url: privateSourceURL,
                    location: .userSelected
                )
            ],
            error: privateError
        )

        let reopened = try MirmirDiagnosticStore(
            persistentDirectoryURL: fixture.directoryURL,
            policy: .production,
            clock: MirmirDiagnosticClock(
                wallMilliseconds: { 5_000 },
                uptimeNanoseconds: { 500 }
            ),
            sessionID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000002"
            )!
        )
        let snapshot = try await reopened.snapshot()
        let record = try XCTUnwrap(snapshot.records.first)
        let fields = Dictionary(
            uniqueKeysWithValues: record.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )

        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(record.event.severity, .error)
        XCTAssertEqual(
            record.event.code.rawValue,
            "media_frame_normalization_failed"
        )
        XCTAssertEqual(
            record.event.correlationID?.rawValue,
            correlationID.uuidString.lowercased()
        )
        XCTAssertNotNil(record.event.error)
        XCTAssertEqual(fields["presentation_dimensions"], "1920x1080")
        XCTAssertEqual(fields["coded_dimensions"], "1440x1080")
        XCTAssertEqual(fields["actual_decoded_dimensions"], "1440x1080")
        XCTAssertEqual(fields["expected_normalized_dimensions"], "1920x1080")
        XCTAssertEqual(fields["pixel_aspect_ratio"], "4/3")
        XCTAssertEqual(fields["failure_category"], "unclassified_error")
        XCTAssertEqual(
            fields["source_video"],
            "source_video:\(correlationID.uuidString.lowercased()):mov:user_selected"
        )

        let persisted = try Data(contentsOf: fixture.journalURL)
        let json = try await reopened.exportJSON()
        let markdown = try await reopened.exportMarkdown()
        let decoded = try JSONDecoder().decode(
            MirmirDiagnosticSnapshot.self,
            from: json
        )
        XCTAssertEqual(
            decoded.records.map(\.event.code.rawValue),
            ["media_frame_normalization_failed"]
        )
        let markdownText = try XCTUnwrap(
            String(data: markdown, encoding: .utf8)
        )
        XCTAssertTrue(
            markdownText.contains(
                "- actual\\_decoded\\_dimensions: 1440x1080"
            )
        )
        XCTAssertTrue(
            markdownText.contains(
                "- expected\\_normalized\\_dimensions: 1920x1080"
            )
        )
        for data in [persisted, json, markdown] {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            assertPrivateFixtureIsAbsent(from: text)
        }
    }

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
        - Persistence failures: 0
        - Last persistence failure: none

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
            - Persistence failures: 0
            - Last persistence failure: none

            ## Records

            """
        )
    }
}

private extension MirmirDiagnosticExportTests {
    func markdownIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "\\_")
    }

    func diagnosticFrame(resolution: VideoResolution) throws -> FrameRecord {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            capacity: 1
        )
        let pixelBuffer = try PixelBufferBridge.dequeue(from: pool)
        return FrameRecord(
            pixelBuffer: pixelBuffer,
            timing: FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 30)
            )
        )
    }

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
