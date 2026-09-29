import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import Mirmir

@Suite("Mirmir diagnostic store forensic exports")
struct MirmirDiagnosticStoreTests {
    @Test
    func testExistingDiagnosticsV1JournalPersistsAndReloads() async throws {
        let directory = temporaryDirectory("v1-reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: fixedUUID(1)
        )
        let event = try event(
            code: "journal_round_trip",
            fields: [
                try MirmirDiagnosticRecorder.textField(
                    "source_path",
                    "/Users/developer/Movies/source.mov"
                )
            ]
        )
        _ = try await store.record(event)

        let reopened = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: fixedUUID(2)
        )
        let snapshot = try await reopened.snapshot()

        #expect(snapshot.records.count == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    MirmirDiagnosticStore.journalFileName
                ).path
            )
        )
        #expect(MirmirDiagnosticStore.journalFileName == "diagnostics-v1.jsonl")
    }

    @Test
    func testTimingSiteFailureSurvivesJSONExportWithExactRationals()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(3)
        )
        try await recordTimingFailure(in: store)
        let json = try await store.exportJSON()
        let text = String(decoding: json, as: UTF8.self)

        #expect(text.contains("dv4_timing_038_nominal_cadence_off_lattice"))
        #expect(text.contains("\"observed_presentation_time_value\""))
        #expect(text.contains("\"signed_value\" : 7508"))
        #expect(text.contains("\"expected_presentation_time_value\""))
        #expect(text.contains("\"signed_value\" : 7506"))
        #expect(text.contains("\"nominal_frame_duration_value\""))
        #expect(text.contains("\"signed_value\" : 1001"))
        #expect(text.contains("\"nominal_frame_duration_timescale\""))
        #expect(text.contains("\"signed_value\" : 24000"))
        #expect(text.contains("\"sample_index\""))
        for required in [
            "job-timing-16",
            "workflow-timing-16",
            "queue-timing-16",
            "mirmirDeterministicMetal",
            "fallback_occurred",
            "requested_geometry",
            "effective_geometry",
            "effective_output_pixel_format",
            "effective_dynamic_range",
            "audio_tracks_opened",
            "audio_codecs",
            "audio_alternate_group_flags",
            "audio_reader_drain_mode",
            "next_input_sample_index",
            "segment_ordinal",
            "checkpoint_schema",
            "/Users/developer/Movies/source.mov",
            "/Users/developer/Movies/output.mov",
            "site_id"
        ] {
            #expect(text.contains(required))
        }
    }

    @Test
    func testTimingSiteFailureSurvivesMarkdownExportWithThrowSite()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(4)
        )
        try await recordTimingFailure(in: store)
        let markdown = String(
            decoding: try await store.exportMarkdown(),
            as: UTF8.self
        )

        #expect(markdown.contains(
            "timing\\_site\\_id: dv4\\_timing\\_038\\_nominal\\_cadence\\_off\\_lattice"
        ))
        #expect(markdown.contains(
            "Source: Mirmir/MediaIO/DeterministicV4MediaProcessingSession.swift:2477"
        ))
        #expect(markdown.contains(
            "Function: validateNominalDecodedCadence"
        ))
        #expect(markdown.contains("observed\\_presentation\\_time\\_value: 7508"))
        #expect(markdown.contains("expected\\_presentation\\_time\\_value: 7506"))
        #expect(markdown.contains("actual\\_backend: mirmirDeterministicMetal"))
        #expect(markdown.contains("audio\\_tracks\\_opened: 2"))
        #expect(markdown.contains("next\\_input\\_sample\\_index: 2"))
    }

    @Test
    func testProductionCadenceValidatorSubmitsFailureToInjectedStore()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(10)
        )
        let recorder = MirmirDiagnosticRecorder(store: store)
        let (request, source) = timingFixture()
        let processingContext = MirmirDiagnosticProcessingContext(
            request: request,
            source: source,
            actualBackendID: .mirmirDeterministicMetal,
            fallbackOccurred: false,
            effectiveSourceAttributes: PixelBufferAttributes([
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 816
            ]),
            effectiveDestinationAttributes: PixelBufferAttributes([
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: 7680,
                kCVPixelBufferHeightKey as String: 3264
            ]),
            durable: .init(
                nextInputSampleIndex: 100,
                segmentOrdinal: 2,
                segmentCount: 4,
                isComplete: false,
                checkpointSchema: "workflow-segment-checkpoint-v4-v1",
                publishAttempted: false,
                atomicPublicationFailed: false,
                checkpointURL: URL(
                    fileURLWithPath:
                        "/Users/developer/Library/Application Support/Mirmir/checkpoints/production-cadence"
                )
            ),
            audio: .init(
                openedTrackCount: 2,
                codecs: ["aac ", "ac-3"],
                alternateGroupFlags: [false, true],
                readerDrainMode: "round_robin_serial_reader"
            )
        )
        let presentationTimes = [
            CMTime(value: 0, timescale: 30),
            CMTime(value: 1, timescale: 30),
            CMTime(value: 90, timescale: 30)
        ]
        let decodedDurations = Array(
            repeating: CMTime(value: 1, timescale: 30),
            count: presentationTimes.count
        )

        do {
            try MirmirDiagnosticScope.$recorder.withValue(recorder) {
                try MirmirDiagnosticScope.$executionContext.withValue(.init(
                    jobID: "job-production-cadence",
                    workflowID: "workflow-production-cadence",
                    queueItemID: "queue-production-cadence"
                )) {
                    try MirmirDiagnosticScope.$processingContext.withValue(
                        processingContext
                    ) {
                        try DeterministicV4MediaProcessingSession
                            .validateNominalDecodedCadence(
                                presentationTimes: presentationTimes,
                                decodedDurations: decodedDurations,
                                nominalSourceFrameDuration:
                                    try ExactRationalV4(1, 30)
                            )
                    }
                }
            }
            Issue.record("Expected production cadence validation to fail")
        } catch {
            #expect(
                error as? DeterministicV4MediaSegmentError
                    == .invalidSampleTiming(
                        site: .nominalCadenceOffLattice
                    )
            )
        }

        let snapshot = try await store.snapshot()
        #expect(snapshot.records.count == 1)
        let record = try #require(snapshot.records.first)
        #expect(
            record.event.operation.rawValue
                == "validate_nominal_decoded_cadence"
        )
        #expect(record.event.code.rawValue == "invalid_sample_timing")
        let sourceLocation = try #require(record.event.source)
        #expect(
            sourceLocation.fileID
                == "Mirmir/DeterministicV4MediaProcessingSession.swift"
        )
        #expect(
            sourceLocation.function?.contains(
                "validateNominalDecodedCadence"
            ) == true
        )
        #expect(record.event.fields.contains {
            $0.key.rawValue == "timing_site_id"
                && $0.value.displayValue
                    == "dv4_timing_038_nominal_cadence_off_lattice"
        })
        #expect(record.event.fields.contains {
            $0.key.rawValue == "sample_index"
                && $0.value.displayValue == "102"
        })
        #expect(record.event.fields.contains {
            $0.key.rawValue == "job_id"
                && $0.value.displayValue == "job-production-cadence"
        })

        let exported = String(
            decoding: try await store.exportJSON(),
            as: UTF8.self
        )
        #expect(exported.contains(
            "dv4_timing_038_nominal_cadence_off_lattice"
        ))
        #expect(exported.contains("job-production-cadence"))
    }

    @Test
    func testAtomicOutputPublishSubmitsMissingTemporaryFailureToInjectedStore()
        async throws {
        let directory = temporaryDirectory("production-publication")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(11)
        )
        let recorder = MirmirDiagnosticRecorder(store: store)
        let outputURL = directory.appendingPathComponent("output.mov")
        let output = try AtomicOutputFile(
            finalURL: outputURL,
            overwriteExistingFile: false
        )

        do {
            try MirmirDiagnosticScope.$recorder.withValue(recorder) {
                try MirmirDiagnosticScope.$executionContext.withValue(.init(
                    jobID: "job-production-publication",
                    workflowID: "workflow-production-publication",
                    queueItemID: "queue-production-publication"
                )) {
                    try output.publish()
                }
            }
            Issue.record("Expected atomic publication to fail")
        } catch {
            #expect(
                error as? MirmirError
                    == .outputFinalizeFailed(
                        "the completed temporary movie is missing"
                    )
            )
        }

        let snapshot = try await store.snapshot()
        #expect(snapshot.records.count == 1)
        let record = try #require(snapshot.records.first)
        #expect(record.event.operation.rawValue == "publish")
        #expect(record.event.code.rawValue == "atomic_publication_failed")
        #expect(record.event.source?.fileID == "Mirmir/AtomicOutputFile.swift")
        #expect(record.event.source?.function?.contains("publish") == true)
        #expect(record.event.fields.contains {
            $0.key.rawValue == "atomic_publication_failed"
                && $0.value.displayValue == "true"
        })
        #expect(record.event.fields.contains {
            $0.key.rawValue == "publish"
                && $0.value.displayValue == "true"
        })
        #expect(record.event.fields.contains {
            $0.key.rawValue == "job_id"
                && $0.value.displayValue == "job-production-publication"
        })

        let exported = String(
            decoding: try await store.exportJSON(),
            as: UTF8.self
        )
        #expect(exported.contains("atomic_publication_failed"))
        #expect(exported.contains("job-production-publication"))
        #expect(exported.contains(output.temporaryURL.path))
        #expect(exported.contains(outputURL.path))
    }

    @Test
    func testENOSPCPublicationFailureSurvivesJSONExportWithDiskAndDurableState()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(5)
        )
        await recordENOSPCFailure(in: store)
        let json = String(
            decoding: try await store.exportJSON(),
            as: UTF8.self
        )

        for required in [
            "job-42",
            "workflow-request-42",
            "queue-item-42",
            "atomic_publication_failed",
            "next_input_sample_index",
            "segment_ordinal",
            "segment_count",
            "is_complete",
            "checkpoint_schema",
            "publish",
            "destination_volume_free_bytes",
            "checkpoint_volume_free_bytes",
            "destination_path",
            NSPOSIXErrorDomain
        ] {
            #expect(json.contains(required))
        }
        #expect(json.contains("\"signed_value\" : 28"))
    }

    @Test
    func testENOSPCPublicationFailureSurvivesMarkdownExportWithNestedError()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(6)
        )
        await recordENOSPCFailure(in: store)
        let markdown = String(
            decoding: try await store.exportMarkdown(),
            as: UTF8.self
        )

        #expect(markdown.contains("Code: enospc"))
        #expect(markdown.contains("atomic\\_publication\\_failed: true"))
        #expect(markdown.contains("errno: 28"))
        #expect(markdown.contains("Error 0:"))
        #expect(markdown.contains("Error 1:"))
        #expect(markdown.contains("NSPOSIXErrorDomain"))
        #expect(markdown.contains(
            "/Users/developer/Movies/output.mov"
        ))
    }

    @Test
    func testDevelopmentPathsArePreservedWhileCredentialValuesAreRejected()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(7)
        )
        _ = try await store.record(try event(
            code: "path_allowed",
            fields: [
                try MirmirDiagnosticRecorder.textField(
                    "source_path",
                    "/Users/developer/Movies/private-source.mov"
                )
            ]
        ))
        let exported = String(
            decoding: try await store.exportJSON(),
            as: UTF8.self
        )
        #expect(exported.contains(
            "/Users/developer/Movies/private-source.mov"
        ))

        let forbidden = try event(
            code: "credential_rejected",
            fields: [
                try MirmirDiagnosticRecorder.textField(
                    "authorization_value",
                    "Bearer abcdef123456"
                )
            ]
        )
        await #expect(throws: MirmirDiagnosticValidationError.self) {
            _ = try await store.record(forbidden)
        }
    }

    @Test
    func testSourceFunctionFileAndLineSurviveBothExports() async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(8)
        )
        _ = try await store.record(try event(
            code: "source_location",
            fileID: "Mirmir/MediaIO/AtomicOutputFile.swift",
            function: "publish()",
            line: 91
        ))

        let json = String(
            decoding: try await store.exportJSON(),
            as: UTF8.self
        )
        let markdown = String(
            decoding: try await store.exportMarkdown(),
            as: UTF8.self
        )
        #expect(json.contains("Mirmir/MediaIO/AtomicOutputFile.swift"))
        #expect(json.contains("\"function\" : \"publish()\""))
        #expect(json.contains("\"line\" : 91"))
        #expect(markdown.contains(
            "Source: Mirmir/MediaIO/AtomicOutputFile.swift:91"
        ))
        #expect(markdown.contains("Function: publish()"))
    }

    @Test
    func testForcedFailureEvidenceExportsJSONAndMarkdown() async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            clock: .init(
                wallMilliseconds: { 1_800_000_000_000 },
                uptimeNanoseconds: { 42_000_000 }
            ),
            sessionID: fixedUUID(9)
        )
        try await recordTimingFailure(in: store)
        await recordENOSPCFailure(in: store)

        let json = try await store.exportJSON()
        let markdown = try await store.exportMarkdown()
        let jsonURL = URL(
            fileURLWithPath:
                "/tmp/mirmir-diagnostic-upgrade-forced-failure.json"
        )
        let markdownURL = URL(
            fileURLWithPath:
                "/tmp/mirmir-diagnostic-upgrade-forced-failure.md"
        )
        try json.write(to: jsonURL, options: .atomic)
        try markdown.write(to: markdownURL, options: .atomic)

        #expect(json.count > 0)
        #expect(markdown.count > 0)
        #expect(
            String(decoding: json, as: UTF8.self)
                .contains("dv4_timing_038_nominal_cadence_off_lattice")
        )
        #expect(
            String(decoding: markdown, as: UTF8.self)
                .contains("atomic\\_publication\\_failed: true")
        )
    }

    private func recordTimingFailure(
        in store: MirmirDiagnosticStore
    ) async throws {
        let error = DeterministicV4MediaSegmentError.invalidSampleTiming(
            site: .nominalCadenceOffLattice
        )
        let (request, source) = timingFixture()
        let recorder = MirmirDiagnosticRecorder(store: store)
        recorder.recordProcessingFailure(
            subsystem: "deterministic_v4",
            operation: "validate_nominal_decoded_cadence",
            executionContext: .init(
                jobID: "job-timing-16",
                workflowID: "workflow-timing-16",
                queueItemID: "queue-timing-16"
            ),
            request: request,
            source: source,
            actualBackendID: .mirmirDeterministicMetal,
            fallbackOccurred: false,
            effectiveSourceAttributes: PixelBufferAttributes([
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: 1920,
                kCVPixelBufferHeightKey as String: 816
            ]),
            effectiveDestinationAttributes: PixelBufferAttributes([
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: 7680,
                kCVPixelBufferHeightKey as String: 3264
            ]),
            timing: .init(
                nominalFrameDuration: CMTime(
                    value: 1001,
                    timescale: 24000
                ),
                sampleIndex: 2,
                observedPresentationTime: CMTime(
                    value: 7508,
                    timescale: 90000
                ),
                expectedPresentationTime: CMTime(
                    value: 7506,
                    timescale: 90000
                ),
                observedDuration: CMTime(value: 3754, timescale: 90000),
                expectedDuration: CMTime(value: 1001, timescale: 24000),
                siteID: DeterministicV4InvalidSampleTimingSite
                    .nominalCadenceOffLattice.rawValue
            ),
            durable: .init(
                nextInputSampleIndex: 2,
                segmentOrdinal: 0,
                segmentCount: 4,
                isComplete: false,
                checkpointSchema: "workflow-segment-checkpoint-v4-v1",
                publishAttempted: false,
                atomicPublicationFailed: false,
                checkpointURL: URL(
                    fileURLWithPath:
                        "/Users/developer/Library/Application Support/Mirmir/checkpoints/job-timing-16"
                )
            ),
            audio: .init(
                openedTrackCount: 2,
                codecs: ["aac ", "ac-3"],
                alternateGroupFlags: [false, true],
                readerDrainMode: "round_robin_serial_reader"
            ),
            error: error,
            fileID:
                "Mirmir/MediaIO/DeterministicV4MediaProcessingSession.swift",
            function: "validateNominalDecodedCadence",
            line: 2477
        )
    }

    private func timingFixture() -> (UpscaleRequest, VideoInfo) {
        let request = UpscaleRequest(
            inputURL: URL(
                fileURLWithPath: "/Users/developer/Movies/source.mov"
            ),
            outputURL: URL(
                fileURLWithPath: "/Users/developer/Movies/output.mov"
            ),
            backendID: .mirmirDeterministicMetal,
            targetWidth: 7680,
            targetHeight: 3264,
            outputCodec: .hevc,
            preserveAudio: true,
            overwriteExistingFile: true
        )
        let source = VideoInfo(
            url: request.inputURL,
            duration: CMTime(seconds: 6_180, preferredTimescale: 600),
            geometry: VideoGeometry(
                encodedSize: CGSize(width: 1920, height: 816),
                naturalSize: CGSize(width: 1920, height: 816),
                presentationSize: CGSize(width: 1920, height: 816),
                displaySize: CGSize(width: 1920, height: 816),
                preferredTransform: .identity,
                cleanAperture: nil,
                pixelAspectRatio: nil
            ),
            nominalFrameRate: 23.976,
            minimumFrameDuration: CMTime(value: 1001, timescale: 24000),
            estimatedFrameCount: 148_172,
            estimatedDataRate: nil,
            codecFourCC: nil,
            hasAudio: true,
            audioTrackCount: 2,
            videoTrackCount: 1,
            isReadable: true,
            isPlayable: true,
            fileSizeBytes: 12_000_000_000,
            color: VideoColorInfo(
                colorPrimaries: "ITU_R_709_2",
                transferFunction: "ITU_R_709_2",
                yCbCrMatrix: "ITU_R_709_2",
                bitDepth: 10,
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                isFullRange: false,
                fieldCount: 1,
                fieldDetail: nil,
                alphaModel: .none,
                hasMasteringDisplayMetadata: false,
                hasContentLightLevelMetadata: false,
                dynamicRange: .sdr
            )
        )
        return (request, source)
    }

    private func recordENOSPCFailure(
        in store: MirmirDiagnosticStore
    ) async {
        let posix = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [
                NSLocalizedDescriptionKey: "No space left on device",
                "destination_path":
                    "/Users/developer/Movies/output.mov"
            ]
        )
        let publication = NSError(
            domain: MirmirAtomicPublicationError.errorDomain,
            code: Int(ENOSPC),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Atomic publication failed.",
                NSUnderlyingErrorKey: posix,
                "destination_path":
                    "/Users/developer/Movies/output.mov",
                "checkpoint_path":
                    "/Users/developer/Library/Application Support/Mirmir/checkpoints/job-42",
                "authorization": "Bearer must-not-export"
            ]
        )
        MirmirDiagnosticRecorder(store: store).recordCheckpoint(
            subsystem: "durable_publication",
            operation: "finalize",
            executionContext: .init(
                jobID: "job-42",
                workflowID: "workflow-request-42",
                queueItemID: "queue-item-42"
            ),
            durable: .init(
                nextInputSampleIndex: 2400,
                segmentOrdinal: 3,
                segmentCount: 4,
                isComplete: false,
                checkpointSchema: "workflow-checkpoint-v4-v3",
                publishAttempted: true,
                atomicPublicationFailed: true,
                checkpointURL: URL(
                    fileURLWithPath:
                        "/Users/developer/Library/Application Support/Mirmir/checkpoints/job-42"
                )
            ),
            destinationURL: URL(
                fileURLWithPath:
                    "/Users/developer/Movies/output.mov"
            ),
            fields: (try? [
                MirmirDiagnosticRecorder.field(
                    "errno",
                    .signedInteger(Int64(ENOSPC))
                ),
                MirmirDiagnosticRecorder.textField(
                    "output_path",
                    "/Users/developer/Movies/output.mov"
                )
            ]) ?? [],
            error: publication,
            fileID: "Mirmir/App/WorkflowApplicationCoordinatorV4.swift",
            function: "finalize",
            line: 4702
        )
    }

    private func event(
        code: String,
        fields: [MirmirDiagnosticField] = [],
        fileID: String = "MirmirTests/MirmirDiagnosticStoreTests.swift",
        function: String = "test",
        line: UInt = 1
    ) throws -> MirmirDiagnosticEvent {
        try MirmirDiagnosticEvent(
            severity: .error,
            subsystem: "diagnostics_test",
            operation: "forced_failure",
            code: code,
            fields: fields,
            source: try .init(
                fileID: fileID,
                function: function,
                line: line
            )
        )
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MirmirDiagnosticStoreTests-\(suffix)-\(UUID().uuidString)",
                isDirectory: true
            )
    }

    private func fixedUUID(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, value
        ))
    }
}
