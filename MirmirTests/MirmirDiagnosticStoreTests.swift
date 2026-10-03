import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import Mirmir

@Suite("Mirmir diagnostic store forensic exports")
struct MirmirDiagnosticStoreTests {
    @Test
    func testCurrentProcessUnifiedLogsExportAsValidatedJSON()
        async throws {
        let sessionID = fixedUUID(30)
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: sessionID,
            runtimeIdentity: MirmirDiagnosticRuntimeIdentity(
                applicationName: "Mirmir",
                applicationVersion: "1.4.2",
                applicationBuild: "11",
                bundleIdentifier: "com.mirmir.app",
                operatingSystemVersion: "macOS Test",
                operatingSystemBuild: "25A100",
                architecture: "arm64",
                processName: "Mirmir",
                processIdentifier: 42,
                metalDeviceName: "Test GPU"
            )
        )
        let data = try await store.exportApplicationLogs()
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(
            object["scope"] as? String
                == "current_process_available_unified_logs"
        )
        #expect(
            object["diagnostic_session_id"] as? String
                == sessionID.uuidString.lowercased()
        )
        let snapshot = try await store.snapshot()
        let startRecord = try #require(snapshot.records.first {
            $0.event.code.rawValue == "diagnostic_session_started"
        })
        let startSessionID = startRecord.event.fields.first {
            $0.key.rawValue == "diagnostic_session_id"
        }?.value.displayValue
        #expect(
            object["diagnostic_session_id"] as? String == startSessionID
        )
        #expect(object["entries"] is [Any])
    }

    @Test
    func testInjectedUnifiedLogExportIncludesLogAndSignpostMetadata()
        throws {
        let candidates: [MirmirDiagnosticApplicationLogExport.Candidate] = [
            .entry(applicationLogSource(
                kind: .log,
                message: "Rendered frame 42"
            )),
            .entry(applicationLogSource(
                kind: .signpost,
                message: "Upscale interval",
                ordinal: 2
            ))
        ]
        let data = try MirmirDiagnosticApplicationLogExport.json(
            candidates: candidates,
            environment: applicationLogEnvironment(),
            limits: .init(
                maximumEntries: 10,
                maximumBytes: 32_768,
                maximumMessageBytes: 1_024
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let entries = try #require(object["entries"] as? [[String: Any]])

        #expect(object["application_name"] as? String == "Mirmir")
        #expect(object["bundle_identifier"] as? String == "com.example.Mirmir")
        #expect(object["application_version"] as? String == "1.4.2")
        #expect(object["application_build"] as? String == "11")
        #expect(object["operating_system"] as? String == "macOS Test")
        #expect(object["architecture"] as? String == "arm64")
        #expect(object["process_name"] as? String == "Mirmir")
        #expect((object["process_identifier"] as? NSNumber)?.intValue == 42)
        #expect(object["diagnostic_session_id"] as? String == "session-42")
        #expect((object["retained_entry_count"] as? NSNumber)?.intValue == 2)
        #expect(entries.count == 2)
        #expect(entries[0]["kind"] as? String == "log")
        #expect(entries[0]["level"] as? String == "notice")
        #expect(entries[0]["store_category"] as? String == "longTermAuto")
        #expect(entries[0]["process"] as? String == "Mirmir")
        #expect((entries[0]["process_identifier"] as? NSNumber)?.intValue == 42)
        #expect(entries[0]["sender"] as? String == "Mirmir")
        #expect(entries[0]["subsystem"] as? String == "com.example.Mirmir")
        #expect(entries[0]["category"] as? String == "processing")
        #expect(entries[0]["message"] as? String == "Rendered frame 42")
        #expect((entries[0]["thread_identifier"] as? NSNumber)?.intValue == 8)
        #expect((entries[0]["activity_identifier"] as? NSNumber)?.intValue == 9)
        #expect(entries[1]["kind"] as? String == "signpost")
        #expect(entries[1]["signpost_name"] as? String == "upscale")
        #expect(entries[1]["signpost_type"] as? String == "intervalBegin")
        #expect((entries[1]["signpost_identifier"] as? NSNumber)?.intValue == 12)
    }

    @Test
    func testUnifiedLogExportCountsEachOmissionReasonSeparately() throws {
        let candidates: [MirmirDiagnosticApplicationLogExport.Candidate] = [
            .unsupported,
            .entry(applicationLogSource(
                kind: .log,
                message: "password=fake-diagnostic-only"
            )),
            .entry(applicationLogSource(
                kind: .log,
                message: String(repeating: "x", count: 33),
                ordinal: 2
            )),
            .entry(applicationLogSource(
                kind: .log,
                message: "retained",
                ordinal: 3
            )),
            .entry(applicationLogSource(
                kind: .log,
                message: "entry-limit",
                ordinal: 4
            ))
        ]
        let data = try MirmirDiagnosticApplicationLogExport.json(
            candidates: candidates,
            environment: applicationLogEnvironment(),
            limits: .init(
                maximumEntries: 1,
                maximumBytes: 32_768,
                maximumMessageBytes: 32
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect((object["retained_entry_count"] as? NSNumber)?.intValue == 1)
        #expect((object["omitted_private_entry_count"] as? NSNumber)?.intValue == 1)
        #expect((object["omitted_oversize_entry_count"] as? NSNumber)?.intValue == 1)
        #expect((object["omitted_unsupported_entry_count"] as? NSNumber)?.intValue == 1)
        #expect((object["omitted_entry_limit_count"] as? NSNumber)?.intValue == 1)
        #expect((object["omitted_byte_limit_entry_count"] as? NSNumber)?.intValue == 0)
        #expect(object["truncated"] as? Bool == true)
        #expect(!String(decoding: data, as: UTF8.self).contains(
            "fake-diagnostic-only"
        ))
    }

    @Test
    func testUnifiedLogExportEnforcesEncodedByteLimit() throws {
        let first = MirmirDiagnosticApplicationLogExport.Candidate.entry(
            applicationLogSource(
                kind: .log,
                message: String(repeating: "a", count: 400)
            )
        )
        let second = MirmirDiagnosticApplicationLogExport.Candidate.entry(
            applicationLogSource(
                kind: .log,
                message: String(repeating: "b", count: 400),
                ordinal: 2
            )
        )
        let environment = applicationLogEnvironment()
        let oneEntryData = try MirmirDiagnosticApplicationLogExport.json(
            candidates: [first],
            environment: environment,
            limits: .init(
                maximumEntries: 10,
                maximumBytes: 32_768,
                maximumMessageBytes: 1_024
            )
        )
        let maximumBytes = oneEntryData.count + 256
        let data = try MirmirDiagnosticApplicationLogExport.json(
            candidates: [first, second],
            environment: environment,
            limits: .init(
                maximumEntries: 10,
                maximumBytes: maximumBytes,
                maximumMessageBytes: 1_024
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(data.count <= maximumBytes)
        #expect((object["retained_entry_count"] as? NSNumber)?.intValue == 1)
        #expect((object["omitted_byte_limit_entry_count"] as? NSNumber)?.intValue == 1)
        #expect((object["omitted_entry_limit_count"] as? NSNumber)?.intValue == 0)
        #expect(object["truncated"] as? Bool == true)
    }

    @Test
    func testUnifiedLogExportRejectsPlainCredentialsWithoutRejectingWords()
        throws {
        let privateMessages = [
            "token=fake-plain-token",
            "secret=fake-plain-secret",
            #"{"secret":"fake-json-secret"}"#,
            "MIRMIR_TOKEN=fake-mirmir-token",
            "DATABASE_PASSWORD=fake-database-password",
            "credential=fake-credential",
            "security_bookmark=fake-bookmark",
            "OPENAI_API_KEY=fake-openai-api-key",
            "AWS_SECRET_ACCESS_KEY=fake-aws-secret-access-key",
            "MYTOKEN=fake-collapsed-token",
            "DATABASEPASSWORD=fake-collapsed-password",
            "SECURITYBOOKMARK=fake-collapsed-bookmark",
            "tokenvalue=fake-token-value",
            "passwordvalue=fake-password-value",
            "secretdata=fake-secret-data",
            "credentialdata=fake-credential-data",
            "bookmarkdata=fake-bookmark-data",
            "authorizationheader=fake-authorization-header",
            "apikeyvalue=fake-api-key-value",
            "API Key: opaque-private-value",
            "Private Key = opaque-private-key-value",
            "Secret Key: opaque-secret-key-value",
            "auth=opaque-auth-value",
            "access_key=opaque-access-key-value",
            "cookie=opaque-cookie-value",
            "set_cookie=opaque-set-cookie-value",
            "passwd=opaque-passwd-value",
            "pwd=opaque-pwd-value",
            "passcode=opaque-passcode-value",
            "password.value=opaque-qualified-password-value",
            "config/password.value=opaque-qualified-path-password-value",
            "config[password]=opaque-bracket-password-value",
            "credentials['password']=opaque-quoted-bracket-password-value"
        ]
        let retainedMessages = [
            "tokenization=enabled",
            "secretariat=available",
            "authentication=required",
            "Render Status: ready",
            "Source URL: https://example.invalid/video.mov"
        ]
        let candidates: [MirmirDiagnosticApplicationLogExport.Candidate] =
            (privateMessages + retainedMessages).enumerated().map {
                offset,
                message in
                .entry(applicationLogSource(
                    kind: .log,
                    message: message,
                    ordinal: UInt64(offset + 1)
                ))
            }
        let data = try MirmirDiagnosticApplicationLogExport.json(
            candidates: candidates,
            environment: applicationLogEnvironment(),
            limits: .init(
                maximumEntries: 10,
                maximumBytes: 32_768,
                maximumMessageBytes: 1_024
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let exported = String(decoding: data, as: UTF8.self)

        #expect(
            (object["retained_entry_count"] as? NSNumber)?.intValue
                == retainedMessages.count
        )
        #expect(
            (object["omitted_private_entry_count"] as? NSNumber)?.intValue
                == privateMessages.count
        )
        for privateValue in [
            "fake-plain-token", "fake-plain-secret", "fake-json-secret",
            "fake-mirmir-token", "fake-database-password",
            "fake-credential", "fake-bookmark", "fake-openai-api-key",
            "fake-aws-secret-access-key", "fake-collapsed-token",
            "fake-collapsed-password", "fake-collapsed-bookmark",
            "fake-token-value", "fake-password-value", "fake-secret-data",
            "fake-credential-data", "fake-bookmark-data",
            "fake-authorization-header", "fake-api-key-value",
            "opaque-private-value", "opaque-private-key-value",
            "opaque-secret-key-value", "opaque-auth-value",
            "opaque-access-key-value", "opaque-cookie-value",
            "opaque-set-cookie-value", "opaque-passwd-value",
            "opaque-pwd-value", "opaque-passcode-value",
            "opaque-qualified-password-value",
            "opaque-qualified-path-password-value",
            "opaque-bracket-password-value",
            "opaque-quoted-bracket-password-value"
        ] {
            #expect(!exported.contains(privateValue))
        }
        #expect(exported.contains("tokenization=enabled"))
        #expect(exported.contains("secretariat=available"))
        #expect(exported.contains("authentication=required"))
        #expect(exported.contains("Render Status: ready"))
        #expect(exported.contains("https://example.invalid/video.mov"))
    }

    @Test
    func testNewestUnifiedLogsAreSelectedWithinBoundAndEmittedChronologically()
        throws {
        let sharedTimestamp: Int64 = 1_800_000_000_010
        let sequence = MirmirCountingApplicationLogSequence(
            [
                .entry(applicationLogSource(
                    kind: .log,
                    message: "newer",
                    ordinal: 10,
                    timestampUnixMilliseconds: sharedTimestamp
                )),
                .entry(applicationLogSource(
                    kind: .log,
                    message: "older",
                    ordinal: 9,
                    timestampUnixMilliseconds: sharedTimestamp
                )),
                .entry(applicationLogSource(
                    kind: .log,
                    message: "outside-scan-bound",
                    ordinal: 8
                ))
            ]
        )
        let data = try MirmirDiagnosticApplicationLogExport.json(
            candidates: sequence,
            environment: applicationLogEnvironment(),
            limits: .init(
                maximumEntries: 10,
                maximumBytes: 32_768,
                maximumMessageBytes: 1_024,
                maximumScannedEntries: 2
            ),
            candidateOrder: .newestFirst
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let entries = try #require(object["entries"] as? [[String: Any]])

        #expect(sequence.nextCallCount == 3)
        #expect((object["scanned_entry_count"] as? NSNumber)?.intValue == 2)
        #expect((object["scan_entry_limit"] as? NSNumber)?.intValue == 2)
        #expect((object["retained_entry_count"] as? NSNumber)?.intValue == 2)
        #expect(
            (object["omitted_scan_limit_entry_count_minimum"] as? NSNumber)?
                .intValue == 1
        )
        #expect(object["truncated"] as? Bool == true)
        #expect(entries.compactMap { $0["message"] as? String } == [
            "older", "newer"
        ])
        #expect(entries.compactMap {
            ($0["timestamp_unix_ms"] as? NSNumber)?.int64Value
        } == [sharedTimestamp, sharedTimestamp])
    }

    @Test
    func testApplicationLogExportDoesNotBlockJournalActor() async throws {
        let store = MirmirDiagnosticStore(inMemoryWith: .production)
        let exporter = MirmirBlockingDiagnosticExporter()
        let exportTask = Task {
            try await store.exportApplicationLogs(using: {
                exporter.export()
            })
        }
        #expect(exporter.waitUntilStarted())

        let completion = MirmirDiagnosticCompletionFlag()
        let recordTask = Task {
            defer { completion.finish() }
            return try await store.record(try event(code: "during_log_export"))
        }
        for _ in 0..<200 where !completion.isFinished {
            try await Task.sleep(for: .milliseconds(10))
        }
        let completedBeforeExporterWasReleased = completion.isFinished
        exporter.release()

        _ = try await recordTask.value
        _ = try await exportTask.value
        #expect(completedBeforeExporterWasReleased)
    }

    @Test
    func testPrivacyValidatorRejectsCredentialShapesAndKeys() throws {
        let forbiddenValues = [
            "password=fake-diagnostic-password",
            "api_key: fake-diagnostic-api-key",
            "client-secret=fake-diagnostic-client-secret",
            "token=fake-diagnostic-plain-token",
            "secret=fake-diagnostic-plain-secret",
            "token_value=fake-diagnostic-token-value",
            "secretData=fake-diagnostic-secret-data",
            "authToken=fake-diagnostic-auth-token",
            "secret_key=fake-diagnostic-secret-key",
            "MIRMIR_TOKEN=fake-mirmir-token",
            "DATABASE_PASSWORD=fake-database-password",
            "credential=fake-credential",
            "security_bookmark=fake-bookmark",
            "OPENAI_API_KEY=fake-openai-api-key",
            "AWS_SECRET_ACCESS_KEY=fake-aws-secret-access-key",
            "MYTOKEN=fake-collapsed-token",
            "DATABASEPASSWORD=fake-collapsed-password",
            "SECURITYBOOKMARK=fake-collapsed-bookmark",
            "tokenvalue=fake-token-value",
            "passwordvalue=fake-password-value",
            "secretdata=fake-secret-data",
            "credentialdata=fake-credential-data",
            "bookmarkdata=fake-bookmark-data",
            "authorizationheader=fake-authorization-header",
            "apikeyvalue=fake-api-key-value",
            "API Key: opaque-private-value",
            "Private Key = opaque-private-key-value",
            "Secret Key: opaque-secret-key-value",
            "auth=opaque-auth-value",
            "access_key=opaque-access-key-value",
            "cookie=opaque-cookie-value",
            "set_cookie=opaque-set-cookie-value",
            "passwd=opaque-passwd-value",
            "pwd=opaque-pwd-value",
            "passcode=opaque-passcode-value",
            "password.value=opaque-qualified-password-value",
            "config/password.value=opaque-qualified-path-password-value",
            "config[password]=opaque-bracket-password-value",
            "credentials['password']=opaque-quoted-bracket-password-value",
            #"{"token":"fake-diagnostic-json-token"}"#,
            "sk-proj-fake-diagnostic-token",
            "github_pat_fake_diagnostic_token",
            "https://fake-user:fake-password@example.invalid"
        ]
        for value in forbiddenValues {
            #expect(throws: MirmirDiagnosticValidationError.self) {
                try MirmirDiagnosticPrivacyValidator.validateDocumentText(
                    value
                )
            }
        }
        for key in [
            "api-key", "apiKey", "clientSecret", "refreshToken",
            "auth_token", "secretKey", "token_value", "APIKeyValue",
            "OAuthTokenValue", "MIRMIR_TOKEN", "DATABASE_PASSWORD",
            "credential", "security_bookmark", "OPENAI_API_KEY",
            "AWS_SECRET_ACCESS_KEY", "MYTOKEN", "DATABASEPASSWORD",
            "SECURITYBOOKMARK", "mytoken", "databasepassword",
            "securitybookmark", "tokenvalue", "passwordvalue",
            "secretdata", "credentialdata", "bookmarkdata",
            "authorizationheader", "apikeyvalue", "auth", "access_key",
            "access-key", "accessKey", "cookie", "set_cookie", "passwd",
            "pwd", "passcode"
        ] {
            #expect(!MirmirDiagnosticPrivacyValidator.permitsUserInfoKey(key))
        }
        for key in [
            "tokenization_duration_ms", "secretariat_name",
            "authentication_attempt_count"
        ] {
            #expect(MirmirDiagnosticPrivacyValidator.permitsUserInfoKey(key))
        }
        try MirmirDiagnosticPrivacyValidator.validateDocumentText(
            "Completed private-source.mov with tokenization and "
                + "disk-cache-identifier-is-long enabled"
        )
        try MirmirDiagnosticPrivacyValidator.validateDocumentText(
            "tokenization=enabled; secretariat=available; "
                + "authentication=required"
        )
        try MirmirDiagnosticPrivacyValidator.validateDocumentText(
            "Render Status: ready; Source URL: "
                + "https://example.invalid/video.mov"
        )
    }

    @Test
    func testStructuredFieldKeysUseCredentialPrivacyPolicyWhenCreatedAndDecoded()
        throws {
        let safeField = try MirmirDiagnosticField(
            key: "tokenization_duration_ms",
            value: .durationMilliseconds(17)
        )
        let encodedSafeField = try JSONEncoder().encode(safeField)
        let safeJSON = String(decoding: encodedSafeField, as: UTF8.self)

        for privateKey in [
            "password", "credential", "mytoken", "databasepassword",
            "securitybookmark", "tokenvalue", "passwordvalue",
            "secretdata", "credentialdata", "bookmarkdata",
            "authorizationheader", "apikeyvalue", "auth", "access_key",
            "access-key", "accessKey", "cookie", "set_cookie", "passwd",
            "pwd", "passcode"
        ] {
            #expect(throws: MirmirDiagnosticValidationError.self) {
                try MirmirDiagnosticField(
                    key: privateKey,
                    value: .signedInteger(17)
                )
            }
            let privateJSON = safeJSON.replacingOccurrences(
                of: "tokenization_duration_ms",
                with: privateKey
            )
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    MirmirDiagnosticField.self,
                    from: Data(privateJSON.utf8)
                )
            }
        }
    }

    @Test
    func testErrorUserInfoUsesCredentialPrivacyPolicyWhenCreatedAndDecoded()
        throws {
        let safeEntry = try MirmirDiagnosticErrorFrame.UserInfoEntry(
            key: "safe_context",
            value: "opaque-safe-value"
        )
        let encodedSafeEntry = try JSONEncoder().encode(safeEntry)
        let safeJSON = String(decoding: encodedSafeEntry, as: UTF8.self)

        for privateKey in [
            "password", "credential", "auth", "access_key", "cookie",
            "set_cookie"
        ] {
            #expect(throws: MirmirDiagnosticValidationError.self) {
                try MirmirDiagnosticErrorFrame.UserInfoEntry(
                    key: privateKey,
                    value: "opaque-private-value"
                )
            }
            let privateJSON = safeJSON.replacingOccurrences(
                of: "safe_context",
                with: privateKey
            )
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    MirmirDiagnosticErrorFrame.UserInfoEntry.self,
                    from: Data(privateJSON.utf8)
                )
            }
        }
        #expect(throws: MirmirDiagnosticValidationError.self) {
            try MirmirDiagnosticErrorFrame.UserInfoEntry(
                key: "safe_context",
                value: "token=opaque-private-value"
            )
        }
    }

    @Test
    func testLocalizedErrorDescriptionSurvivesJSONAndMarkdownExport()
        async throws {
        let reason =
            "the completed movie changed alternate-audio membership or default selection"
        let identity = MirmirDiagnosticErrorIdentity(
            MirmirError.outputFinalizeFailed(reason)
        )
        let expected = "The output could not be finalized safely: \(reason)"
        let description = identity.frames.first?.userInfo.first {
            $0.key == NSLocalizedDescriptionKey
        }?.value

        #expect(description == expected)

        let store = MirmirDiagnosticStore(inMemoryWith: .production)
        _ = try await store.record(try event(
            code: "output_validation_failed",
            error: identity
        ))
        let json = String(
            decoding: try await store.exportJSON(),
            as: UTF8.self
        )
        let markdown = String(
            decoding: try await store.exportMarkdown(),
            as: UTF8.self
        )

        #expect(json.contains(expected))
        #expect(markdown.contains(expected))
    }

    @Test
    func testCredentialBearingLocalizedErrorDescriptionIsOmitted() {
        let identity = MirmirDiagnosticErrorIdentity(NSError(
            domain: "MirmirDiagnosticStoreTests",
            code: 41,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "output validation failed token=must-not-export"
            ]
        ))

        #expect(identity.frames.first?.userInfo.isEmpty == true)
        #expect(identity.omittedUserInfoEntryCount == 1)
    }

    @Test
    func testNSErrorMetadataPastFrameLimitIsCountedAsOmitted() throws {
        var underlying: NSError?
        for depth in (0...MirmirDiagnosticErrorIdentity.maximumFrames)
            .reversed() {
            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: "frame-\(depth)",
                "safe_context": "context-\(depth)"
            ]
            if let underlying {
                userInfo[NSUnderlyingErrorKey] = underlying
            }
            underlying = NSError(
                domain: "com.mirmir.frame\(depth)",
                code: depth,
                userInfo: userInfo
            )
        }

        let identity = MirmirDiagnosticErrorIdentity(
            try #require(underlying)
        )

        #expect(
            identity.frames.count
                == MirmirDiagnosticErrorIdentity.maximumFrames
        )
        #expect(identity.frames.last?.domain == "com.mirmir.frame7")
        #expect(identity.omittedUserInfoEntryCount == 2)
    }

    @Test
    func testAggregateErrorMetadataPastFrameLimitIsCountedAsOmitted() {
        let errors: [Error] = (0...MirmirDiagnosticErrorIdentity.maximumFrames)
            .map { index in
                NSError(
                    domain: "com.mirmir.aggregate\(index)",
                    code: index,
                    userInfo: [
                        NSLocalizedDescriptionKey: "aggregate-\(index)",
                        "safe_context": "context-\(index)"
                    ]
                )
            }

        let identity = MirmirDiagnosticErrorIdentity(errors: errors)

        #expect(
            identity.frames.count
                == MirmirDiagnosticErrorIdentity.maximumFrames
        )
        #expect(identity.frames.last?.domain == "com.mirmir.aggregate7")
        #expect(identity.omittedUserInfoEntryCount == 2)
    }

    @Test
    @MainActor
    func testLiveProcessTelemetryReachesTheExportedJournal()
        async throws {
        let store = MirmirDiagnosticStore(inMemoryWith: .production)
        let samples = MirmirDiagnosticTelemetrySampleSequence([
            MirmirProcessTelemetryCounters(
                timestampTicks: 1_000_000_000,
                userNanoseconds: 0,
                systemNanoseconds: 0,
                residentBytes: 4_096,
                physicalFootprintBytes: 8_192,
                diskReadBytes: 512,
                diskWrittenBytes: 1_024
            ),
            MirmirProcessTelemetryCounters(
                timestampTicks: 2_000_000_000,
                userNanoseconds: 250_000_000,
                systemNanoseconds: 0,
                residentBytes: 4_096,
                physicalFootprintBytes: 8_192,
                diskReadBytes: 1_512,
                diskWrittenBytes: 2_024
            )
        ])
        let telemetry = MirmirDashboardTelemetry(
            sampleProvider: {
                samples.next()
            },
            timebase: MirmirMachTimebase(numerator: 1, denominator: 1),
            metalDeviceName: "Test GPU",
            diagnosticRecorder: MirmirDiagnosticRecorder(store: store)
        )
        telemetry.refresh()
        telemetry.refresh()

        let exported = String(
            decoding: try await store.exportJSON(), as: UTF8.self
        )
        #expect(exported.contains("process_telemetry_sample"))
        #expect(exported.contains("physical_footprint_bytes"))
        #expect(exported.contains("metal_device_name"))
        #expect(exported.contains("process_cpu_percent_hundredths"))
        #expect(exported.contains("\"signed_value\" : 2500"))
        #expect(
            exported.components(
                separatedBy: "\"code\" : \"process_telemetry_sample\""
            ).count - 1 == 2
        )
    }

    @Test
    func testTimingFailureExportsExactAndAdmittedBoundaryFields()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(11)
        )
        MirmirDiagnosticRecorder(store: store).recordTimingFailure(
            subsystem: "deterministic_v4",
            operation: "validate_terminal_boundary",
            processingContext: nil,
            timing: .init(
                nominalFrameDuration: CMTime(value: 1_001, timescale: 24_000),
                sampleIndex: 148_175,
                siteID: DeterministicV4InvalidSampleTimingSite
                    .exactRationalNotAdjacentToAdmittedClockBoundary.rawValue,
                exactBoundary: CMTime(
                    value: 2_224_862_639,
                    timescale: 360_000
                ),
                admittedBoundary: CMTime(
                    value: 556_215_662,
                    timescale: 90_000
                ),
                clockTimescale: 90_000
            ),
            error: DeterministicV4MediaSegmentError.invalidSampleTiming(
                site: .exactRationalNotAdjacentToAdmittedClockBoundary
            )
        )
        let exported = String(
            decoding: try await store.exportJSON(), as: UTF8.self
        )

        #expect(exported.contains("exact_boundary_value"))
        #expect(exported.contains("\"signed_value\" : 2224862639"))
        #expect(exported.contains("admitted_boundary_value"))
        #expect(exported.contains("\"signed_value\" : 556215662"))
        #expect(exported.contains("boundary_clock_timescale"))
    }

    @Test
    func testVerboseNSErrorTimingFailurePersistsWithinProductionRecordLimit()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(24)
        )
        var underlyingError: NSError?
        for depth in (0..<MirmirDiagnosticErrorIdentity.maximumFrames)
            .reversed() {
            var userInfo = Dictionary(uniqueKeysWithValues: (0..<40).map {
                index in
                (
                    "context_\(String(format: "%02d", index))",
                    "frame-\(depth)-entry-\(index)-"
                        + String(repeating: "x", count: 16_000)
                )
            }) as [String: Any]
            if let underlyingError {
                userInfo[NSUnderlyingErrorKey] = underlyingError
            }
            underlyingError = NSError(
                domain: "com.mirmir.verbose.frame\(depth)",
                code: 700 + depth,
                userInfo: userInfo
            )
        }
        let verboseError = try #require(underlyingError)

        MirmirDiagnosticRecorder(store: store).recordTimingFailure(
            subsystem: "deterministic_v4",
            operation: "validate_terminal_boundary",
            processingContext: nil,
            timing: .init(
                nominalFrameDuration: CMTime(value: 1_001, timescale: 24_000),
                sampleIndex: 148_175,
                siteID: DeterministicV4InvalidSampleTimingSite
                    .exactRationalNotAdjacentToAdmittedClockBoundary.rawValue,
                exactBoundary: CMTime(
                    value: 2_224_862_639,
                    timescale: 360_000
                ),
                admittedBoundary: CMTime(
                    value: 556_215_662,
                    timescale: 90_000
                ),
                clockTimescale: 90_000
            ),
            error: verboseError
        )

        let snapshot = try await store.snapshot()
        let record = try #require(snapshot.records.first)
        let error = try #require(record.event.error)
        let line = try MirmirDiagnosticStore.recordLine(record)
        let exported = try await store.exportJSON()
        let exportedText = String(decoding: exported, as: UTF8.self)
        let markdown = String(
            decoding: try await store.exportMarkdown(),
            as: UTF8.self
        )

        #expect(snapshot.records.count == 1)
        #expect(snapshot.rejectedRecordCount == 0)
        #expect(error.frames.count == MirmirDiagnosticErrorIdentity.maximumFrames)
        #expect(error.frames.first?.domain == "com.mirmir.verbose.frame0")
        #expect(error.frames.first?.code == 700)
        #expect(error.frames.last?.domain == "com.mirmir.verbose.frame7")
        #expect(error.frames.last?.code == 707)
        #expect(error.frames.flatMap(\.userInfo).count < 40 * 8)
        #expect(
            error.omittedUserInfoEntryCount
                >= (40 - MirmirDiagnosticErrorFrame.maximumUserInfoEntries) * 8
        )
        #expect(
            try MirmirDiagnosticCanonicalJSON.data(error).count
                <= MirmirDiagnosticErrorIdentity.maximumEncodedBytes
        )
        #expect(
            line.count
                <= MirmirDiagnosticRetentionPolicy.production.maximumRecordBytes
        )
        #expect(
            exported.count
                <= MirmirDiagnosticRetentionPolicy.production.maximumRecordBytes
        )
        #expect(exportedText.contains("validate_terminal_boundary"))
        #expect(exportedText.contains("com.mirmir.verbose.frame0"))
        #expect(exportedText.contains("\"code\" : 700"))
        #expect(exportedText.contains("exact_boundary_value"))
        #expect(exportedText.contains("\"signed_value\" : 2224862639"))
        #expect(exportedText.contains("admitted_boundary_value"))
        #expect(exportedText.contains("\"signed_value\" : 556215662"))
        #expect(exportedText.contains("omitted_user_info_entry_count"))
        #expect(markdown.contains("Omitted error userInfo entries:"))
    }

    @Test
    func testExistingDiagnosticsV1JournalPersistsAndReloads() async throws {
        let directory = temporaryDirectory("v1-reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: fixedUUID(1),
            runtimeIdentity: nil
        )
        let event = try event(
            code: "journal_round_trip",
            fields: [
                try MirmirDiagnosticRecorder.textField(
                    "source_path",
                    "/Users/developer/Movies/source.mov"
                ),
                try MirmirDiagnosticRecorder.field(
                    "tokenization_duration_ms",
                    .durationMilliseconds(17)
                )
            ]
        )
        _ = try await store.record(event)

        let reopened = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: fixedUUID(2),
            runtimeIdentity: nil
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
        let exported = String(
            decoding: try await reopened.exportJSON(),
            as: UTF8.self
        )
        #expect(exported.contains("tokenization_duration_ms"))
        #expect(exported.contains("/Users/developer/Movies/source.mov"))
    }

    @Test
    func testSessionStartRecordsPreserveRuntimeIdentityAcrossLaunches()
        async throws {
        let directory = temporaryDirectory("session-runtime-identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSessionID = fixedUUID(28)
        let secondSessionID = fixedUUID(29)
        let firstIdentity = MirmirDiagnosticRuntimeIdentity(
            applicationName: "Mirmir",
            applicationVersion: "1.4.1",
            applicationBuild: "10",
            bundleIdentifier: "com.mirmir.app",
            operatingSystemVersion: "macOS 26.0",
            operatingSystemBuild: "25A100",
            architecture: "arm64",
            processName: "Mirmir",
            processIdentifier: 101,
            metalDeviceName: "Test GPU A"
        )
        let secondIdentity = MirmirDiagnosticRuntimeIdentity(
            applicationName: "Mirmir",
            applicationVersion: "1.4.2",
            applicationBuild: "11",
            bundleIdentifier: "com.mirmir.app",
            operatingSystemVersion: "macOS 26.1",
            operatingSystemBuild: "25B200",
            architecture: "arm64",
            processName: "Mirmir",
            processIdentifier: 202,
            metalDeviceName: "Test GPU B"
        )

        let firstStore = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: firstSessionID,
            runtimeIdentity: firstIdentity
        )
        #expect((try await firstStore.snapshot()).records.count == 1)

        let secondStore = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: secondSessionID,
            runtimeIdentity: secondIdentity
        )
        let snapshot = try await secondStore.snapshot()
        let sessionRecords = snapshot.records.filter {
            $0.event.code.rawValue == "diagnostic_session_started"
        }
        let firstRecord = try #require(sessionRecords.first {
            $0.sessionID.rawValue == firstSessionID.uuidString.lowercased()
        })
        let secondRecord = try #require(sessionRecords.first {
            $0.sessionID.rawValue == secondSessionID.uuidString.lowercased()
        })
        let firstFields = Dictionary(uniqueKeysWithValues:
            firstRecord.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        let secondFields = Dictionary(uniqueKeysWithValues:
            secondRecord.event.fields.map {
                ($0.key.rawValue, $0.value.displayValue)
            }
        )
        let exported = String(
            decoding: try await secondStore.exportJSON(), as: UTF8.self
        )

        #expect(sessionRecords.count == 2)
        #expect(firstFields["application_version"] == "1.4.1")
        #expect(firstFields["application_build"] == "10")
        #expect(firstFields["operating_system_build"] == "25A100")
        #expect(firstFields["process_identifier"] == "101")
        #expect(firstFields["metal_device_name"] == "Test GPU A")
        #expect(
            firstFields["diagnostic_session_id"]
                == firstSessionID.uuidString.lowercased()
        )
        #expect(secondFields["application_version"] == "1.4.2")
        #expect(secondFields["application_build"] == "11")
        #expect(secondFields["operating_system_build"] == "25B200")
        #expect(secondFields["process_identifier"] == "202")
        #expect(secondFields["metal_device_name"] == "Test GPU B")
        #expect(
            secondFields["diagnostic_session_id"]
                == secondSessionID.uuidString.lowercased()
        )
        #expect(exported.contains("1.4.1"))
        #expect(exported.contains("1.4.2"))
        #expect(exported.contains(firstSessionID.uuidString.lowercased()))
        #expect(exported.contains(secondSessionID.uuidString.lowercased()))
    }

    @Test
    func testRetentionKeepsIdentityForEveryRetainedSession() async throws {
        let policy = try MirmirDiagnosticRetentionPolicy(
            maximumAgeMilliseconds: 1_000,
            maximumRecords: 2,
            maximumTotalBytes: 64 * 1_024,
            maximumRecordBytes: 4 * 1_024
        )
        let clock = MirmirAdjustableDiagnosticClock(
            wallMilliseconds: 1_000,
            uptimeNanoseconds: 1
        )
        let store = MirmirDiagnosticStore(
            inMemoryWith: policy,
            clock: clock.clock,
            sessionID: fixedUUID(31),
            runtimeIdentity: MirmirDiagnosticRuntimeIdentity(
                applicationName: "Mirmir",
                applicationVersion: "1.4.2",
                applicationBuild: "11",
                bundleIdentifier: "com.mirmir.app",
                operatingSystemVersion: "macOS Test",
                operatingSystemBuild: "25A100",
                architecture: "arm64",
                processName: "Mirmir",
                processIdentifier: 31,
                metalDeviceName: "Test GPU"
            )
        )
        clock.set(wallMilliseconds: 2_501, uptimeNanoseconds: 2)
        _ = try await store.record(try event(code: "retention_first"))
        _ = try await store.record(try event(code: "retention_second"))

        let retained = try await store.snapshot()
        #expect(retained.records.count == 2)
        #expect(
            retained.records.first?.event.code.rawValue
                == "diagnostic_session_started"
        )
        #expect(
            retained.records.last?.event.code.rawValue
                == "retention_second"
        )
        #expect(retained.prunedRecordCount == 1)

        clock.set(wallMilliseconds: 4_000, uptimeNanoseconds: 3)
        let expired = try await store.snapshot()
        #expect(expired.records.count == 1)
        #expect(
            expired.records.first?.event.code.rawValue
                == "diagnostic_session_started"
        )
        #expect(expired.prunedRecordCount == 2)
    }

    @Test
    func testPersistentLongRunningSessionRetainsIdentityBeforeLaterRecord()
        async throws {
        let directory = temporaryDirectory("long-running-session-identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try MirmirDiagnosticRetentionPolicy(
            maximumAgeMilliseconds: 1_000,
            maximumRecords: 10,
            maximumTotalBytes: 64 * 1_024,
            maximumRecordBytes: 4 * 1_024
        )
        let clock = MirmirAdjustableDiagnosticClock(
            wallMilliseconds: 1_000,
            uptimeNanoseconds: 1
        )
        let sessionID = fixedUUID(32)
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            policy: policy,
            clock: clock.clock,
            sessionID: sessionID,
            runtimeIdentity: MirmirDiagnosticRuntimeIdentity(
                applicationName: "Mirmir",
                applicationVersion: "1.4.2",
                applicationBuild: "11",
                bundleIdentifier: "com.mirmir.app",
                operatingSystemVersion: "macOS Test",
                operatingSystemBuild: "25A100",
                architecture: "arm64",
                processName: "Mirmir",
                processIdentifier: 32,
                metalDeviceName: "Test GPU"
            )
        )

        clock.set(wallMilliseconds: 2_501, uptimeNanoseconds: 2)
        _ = try await store.record(try event(code: "before_age_snapshot"))
        clock.set(wallMilliseconds: 4_000, uptimeNanoseconds: 3)
        let aged = try await store.snapshot()
        #expect(aged.records.count == 1)
        #expect(
            aged.records.first?.event.code.rawValue
                == "diagnostic_session_started"
        )

        clock.set(wallMilliseconds: 4_001, uptimeNanoseconds: 4)
        _ = try await store.record(try event(code: "after_age_snapshot"))
        let retained = try await store.snapshot()
        let sessionRecords = retained.records.filter {
            $0.sessionID.rawValue == sessionID.uuidString.lowercased()
        }

        #expect(sessionRecords.count == 2)
        #expect(
            sessionRecords.first?.event.code.rawValue
                == "diagnostic_session_started"
        )
        #expect(
            sessionRecords.last?.event.code.rawValue
                == "after_age_snapshot"
        )
    }

    @Test
    func testLegacyDiagnosticsV1LargeErrorIdentityReloadsUnchanged()
        async throws {
        let directory = temporaryDirectory("v1-large-error-reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let frames = try (0..<MirmirDiagnosticErrorIdentity.maximumFrames).map {
            frameIndex in
            MirmirDiagnosticErrorFrame(
                type: "LegacyDiagnosticError",
                domain: "com.mirmir.legacy.frame\(frameIndex)",
                code: 800 + frameIndex,
                userInfo: try (0..<4).map { entryIndex in
                    try MirmirDiagnosticErrorFrame.UserInfoEntry(
                        key: "context_\(entryIndex)",
                        value: "frame-\(frameIndex)-entry-\(entryIndex)-"
                            + String(repeating: "x", count: 2_000)
                    )
                }
            )
        }
        let framesObject = try #require(
            JSONSerialization.jsonObject(
                with: MirmirDiagnosticCanonicalJSON.data(frames)
            ) as? [Any]
        )
        let legacyErrorObject: [String: Any] = ["frames": framesObject]
        let legacyErrorData = try JSONSerialization.data(
            withJSONObject: legacyErrorObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(
            legacyErrorData.count
                > MirmirDiagnosticErrorIdentity.maximumEncodedBytes
        )

        let event = try event(code: "legacy_large_error_identity")
        let record = try MirmirDiagnosticRecord(
            sequence: 0,
            timestampUnixMilliseconds: Int64(
                Date().timeIntervalSince1970 * 1_000
            ),
            uptimeNanoseconds: 1,
            sessionID: MirmirDiagnosticID(fixedUUID(25)),
            event: event
        )
        var recordObject = try #require(
            JSONSerialization.jsonObject(
                with: MirmirDiagnosticCanonicalJSON.data(record)
            ) as? [String: Any]
        )
        var eventObject = try #require(
            recordObject["event"] as? [String: Any]
        )
        eventObject["error"] = legacyErrorObject
        recordObject["event"] = eventObject
        let legacyRecordData = try JSONSerialization.data(
            withJSONObject: recordObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(
            legacyRecordData.count + 1
                <= MirmirDiagnosticRetentionPolicy.production
                    .maximumRecordBytes
        )
        _ = try MirmirDiagnosticStore.decodeCanonical(
            MirmirDiagnosticRecord.self,
            from: legacyRecordData
        )

        let header = MirmirDiagnosticJournalHeader(
            nextSequence: 1,
            prunedRecordCount: 0,
            rejectedRecordCount: 0,
            recoveredCorruptTailCount: 0,
            recoveredCorruptByteCount: 0
        )
        var journal = try MirmirDiagnosticCanonicalJSON.data(header)
        journal.append(0x0A)
        journal.append(legacyRecordData)
        journal.append(0x0A)
        let journalURL = directory.appendingPathComponent(
            MirmirDiagnosticStore.journalFileName
        )
        try journal.write(to: journalURL, options: .atomic)

        let reopened = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: fixedUUID(26),
            runtimeIdentity: nil
        )
        let snapshot = try await reopened.snapshot()
        let reloadedError = try #require(
            snapshot.records.first?.event.error
        )

        #expect(snapshot.recoveredCorruptTailCount == 0)
        #expect(snapshot.records.count == 1)
        #expect(reloadedError.frames == frames)
        #expect(reloadedError.omittedUserInfoEntryCount == 0)
        #expect(try Data(contentsOf: journalURL) == journal)
    }

    @Test
    func testPrivateStructuredFieldsAreRemovedDuringJournalReload()
        async throws {
        for privateKey in [
            "password", "credential", "tokenvalue", "passwordvalue",
            "secretdata", "credentialdata", "bookmarkdata",
            "authorizationheader", "apikeyvalue", "auth", "access_key",
            "cookie", "set_cookie"
        ] {
            let directory = temporaryDirectory("private-field-\(privateKey)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try MirmirDiagnosticStore(
                persistentDirectoryURL: directory,
                sessionID: fixedUUID(20),
                runtimeIdentity: nil
            )
            _ = try await store.record(try event(
                code: "private_field_decode_probe",
                fields: [
                    try MirmirDiagnosticRecorder.textField(
                        "safe_field",
                        "structured-private-sentinel"
                    )
                ]
            ))
            let journalURL = directory.appendingPathComponent(
                MirmirDiagnosticStore.journalFileName
            )
            let journalData = try Data(contentsOf: journalURL)
            let journal = String(decoding: journalData, as: UTF8.self)
            let mutated = journal.replacingOccurrences(
                of: #""key":"safe_field""#,
                with: #""key":"\#(privateKey)""#
            )
            #expect(mutated != journal)
            try Data(mutated.utf8).write(to: journalURL, options: .atomic)

            let reopened = try MirmirDiagnosticStore(
                persistentDirectoryURL: directory,
                sessionID: fixedUUID(21),
                runtimeIdentity: nil
            )
            let snapshot = try await reopened.snapshot()
            let exported = String(
                decoding: try await reopened.exportJSON(),
                as: UTF8.self
            )

            #expect(snapshot.recoveredCorruptTailCount == 1)
            #expect(snapshot.records.count == 1)
            #expect(
                snapshot.records.first?.event.code.rawValue
                    == "diagnostic_store_tail_recovered"
            )
            #expect(!exported.contains("structured-private-sentinel"))
            #expect(!exported.contains(#""key" : "\#(privateKey)""#))
        }
    }

    @Test
    func testPrivateErrorUserInfoIsRemovedDuringJournalReload() async throws {
        for privateKey in [
            "password", "credential", "auth", "access_key", "cookie",
            "set_cookie"
        ] {
            let directory = temporaryDirectory(
                "private-error-info-\(privateKey)"
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try MirmirDiagnosticStore(
                persistentDirectoryURL: directory,
                sessionID: fixedUUID(22),
                runtimeIdentity: nil
            )
            let error = NSError(
                domain: "MirmirDiagnosticStoreTests",
                code: 22,
                userInfo: ["safe_context": "error-user-info-sentinel"]
            )
            _ = try await store.record(try event(
                code: "private_error_info_decode_probe",
                error: MirmirDiagnosticErrorIdentity(error)
            ))
            let journalURL = directory.appendingPathComponent(
                MirmirDiagnosticStore.journalFileName
            )
            let journalData = try Data(contentsOf: journalURL)
            let journal = String(decoding: journalData, as: UTF8.self)
            let mutated = journal.replacingOccurrences(
                of: #""key":"safe_context""#,
                with: #""key":"\#(privateKey)""#
            )
            #expect(mutated != journal)
            try Data(mutated.utf8).write(to: journalURL, options: .atomic)

            let reopened = try MirmirDiagnosticStore(
                persistentDirectoryURL: directory,
                sessionID: fixedUUID(23),
                runtimeIdentity: nil
            )
            let snapshot = try await reopened.snapshot()
            let exported = String(
                decoding: try await reopened.exportJSON(),
                as: UTF8.self
            )

            #expect(snapshot.recoveredCorruptTailCount == 1)
            #expect(snapshot.records.count == 1)
            #expect(
                snapshot.records.first?.event.code.rawValue
                    == "diagnostic_store_tail_recovered"
            )
            #expect(!exported.contains("error-user-info-sentinel"))
            #expect(!exported.contains(#""key" : "\#(privateKey)""#))
        }
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
    func testProductionCadenceValidatorSubmitsFailureWithoutProcessingContext()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(12)
        )
        let recorder = MirmirDiagnosticRecorder(store: store)
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
                try DeterministicV4MediaProcessingSession
                    .validateNominalDecodedCadence(
                        presentationTimes: presentationTimes,
                        decodedDurations: decodedDurations,
                        nominalSourceFrameDuration: try ExactRationalV4(1, 30)
                    )
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
        #expect(record.event.error != nil)
        #expect(record.event.source?.fileID
            == "Mirmir/DeterministicV4MediaProcessingSession.swift")
        #expect(record.event.source?.function?.contains(
            "validateNominalDecodedCadence"
        ) == true)
        #expect(record.event.fields.contains {
            $0.key.rawValue == "timing_site_id"
                && $0.value.displayValue
                    == "dv4_timing_038_nominal_cadence_off_lattice"
        })
        #expect(record.event.fields.contains {
            $0.key.rawValue == "sample_index"
                && $0.value.displayValue == "2"
        })
        #expect(!record.event.fields.contains {
            ["job_id", "workflow_id", "queue_item_id"]
                .contains($0.key.rawValue)
        })
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
    func testFinalizeFailureRecorderExportsDurableCheckpointPath()
        async throws {
        let directory = temporaryDirectory("finalize-checkpoint")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let checkpointURL = directory
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent("job-finalize", isDirectory: true)
            .appendingPathComponent("checkpoints-v4", isDirectory: true)
            .appendingPathComponent("head-v1.json")
        try FileManager.default.createDirectory(
            at: checkpointURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("checkpoint".utf8).write(to: checkpointURL)
        let destinationURL = directory.appendingPathComponent("output.mov")
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]
        )
        let failure = MirmirAtomicPublicationError(
            temporaryURL: directory.appendingPathComponent("output.partial"),
            finalURL: destinationURL,
            underlyingError: underlying
        )
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(13)
        )
        let recorder = MirmirDiagnosticRecorder(store: store)

        MirmirDiagnosticScope.$recorder.withValue(recorder) {
            WorkflowApplicationCoordinatorV4.recordFinalizeDiagnostic(
                executionContext: .init(
                    jobID: "job-finalize",
                    workflowID: "workflow-finalize",
                    queueItemID: "queue-finalize"
                ),
                nextInputSampleIndex: 240,
                segmentOrdinal: 3,
                segmentCount: 4,
                isComplete: false,
                checkpointURL: checkpointURL,
                destinationURL: destinationURL,
                error: failure
            )
        }

        let snapshot = try await store.snapshot()
        #expect(snapshot.records.count == 1)
        let record = try #require(snapshot.records.first)
        #expect(record.event.operation.rawValue == "finalize")
        #expect(record.event.fields.contains {
            $0.key.rawValue == "checkpoint_path"
                && !$0.value.displayValue.isEmpty
                && $0.value.displayValue == checkpointURL.path
        })
        let exported = String(
            decoding: try await store.exportJSON(),
            as: UTF8.self
        )
        #expect(exported.contains("\"operation\" : \"finalize\""))
        #expect(exported.contains(checkpointURL.path))
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
    func testOutOfRangePOSIXCodeDoesNotTrapDiagnosticRecording()
        async throws {
        let store = MirmirDiagnosticStore(
            inMemoryWith: .production,
            sessionID: fixedUUID(27)
        )
        let outOfRange = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int.max
        )
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [NSUnderlyingErrorKey: outOfRange]
        )

        #expect(MirmirDiagnosticRecorder.posixErrno(outOfRange) == nil)
        #expect(MirmirDiagnosticRecorder.posixErrno(wrapped) == nil)
        await MirmirDiagnosticRecorder(store: store).record(
            severity: .error,
            subsystem: "diagnostics_test",
            operation: "record_out_of_range_posix_error",
            code: "out_of_range_posix_error",
            error: wrapped
        )

        let snapshot = try await store.snapshot()
        let record = try #require(snapshot.records.first)
        #expect(snapshot.records.count == 1)
        #expect(!record.event.fields.contains { $0.key.rawValue == "errno" })
        #expect(record.event.error?.frames.count == 2)
    }

    @Test
    func testDevelopmentPathsArePreservedWhileCredentialValuesAreRejected()
        async throws {
        let directory = temporaryDirectory("privacy-rejection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MirmirDiagnosticStore(
            persistentDirectoryURL: directory,
            sessionID: fixedUUID(7),
            runtimeIdentity: nil
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
                    "request_header",
                    "Bearer abcdef123456"
                )
            ]
        )
        await #expect(throws: MirmirDiagnosticValidationError.self) {
            _ = try await store.record(forbidden)
        }
        let qualifiedForbidden = try event(
            code: "qualified_credential_rejected",
            fields: [
                try MirmirDiagnosticRecorder.textField(
                    "request_context",
                    "config[password].value=opaque-qualified-secret"
                )
            ]
        )
        await #expect(throws: MirmirDiagnosticValidationError.self) {
            _ = try await store.record(qualifiedForbidden)
        }
        let snapshot = try await store.snapshot()
        let health = await store.persistenceHealth()

        #expect(snapshot.records.count == 1)
        #expect(snapshot.rejectedRecordCount == 2)
        #expect(health.failedOperationCount == 0)
        #expect(health.lastFailedOperation == nil)
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
        let exportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-diagnostic-upgrade-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: exportDirectory)
        }
        let jsonURL = exportDirectory.appendingPathComponent(
            "forced-failure.json",
            isDirectory: false
        )
        let markdownURL = exportDirectory.appendingPathComponent(
            "forced-failure.md",
            isDirectory: false
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
        error: MirmirDiagnosticErrorIdentity? = nil,
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
            error: error,
            source: try .init(
                fileID: fileID,
                function: function,
                line: line
            )
        )
    }

    private func applicationLogEnvironment()
        -> MirmirDiagnosticApplicationLogExport.Environment {
        .init(
            exportedAtUnixMilliseconds: 1_800_000_000_000,
            applicationName: "Mirmir",
            bundleIdentifier: "com.example.Mirmir",
            applicationVersion: "1.4.2",
            applicationBuild: "11",
            operatingSystem: "macOS Test",
            architecture: "arm64",
            processName: "Mirmir",
            processIdentifier: 42,
            diagnosticSessionID: "session-42"
        )
    }

    private func applicationLogSource(
        kind: MirmirDiagnosticApplicationLogExport.EntryKind,
        message: String,
        ordinal: UInt64 = 1,
        timestampUnixMilliseconds: Int64? = nil
    ) -> MirmirDiagnosticApplicationLogExport.SourceEntry {
        .init(
            kind: kind,
            timestampUnixMilliseconds: timestampUnixMilliseconds
                ?? 1_800_000_000_000 + Int64(ordinal),
            storeCategory: "longTermAuto",
            process: "Mirmir",
            processIdentifier: 42,
            threadIdentifier: 7 + ordinal,
            activityIdentifier: 8 + ordinal,
            sender: "Mirmir",
            subsystem: "com.example.Mirmir",
            category: "processing",
            message: message,
            level: kind == .log ? "notice" : nil,
            signpostName: kind == .signpost ? "upscale" : nil,
            signpostType: kind == .signpost ? "intervalBegin" : nil,
            signpostIdentifier: kind == .signpost ? 10 + ordinal : nil
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

private final class MirmirDiagnosticTelemetrySampleSequence:
    @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [MirmirProcessTelemetryCounters]
    private var index = 0

    init(_ samples: [MirmirProcessTelemetryCounters]) {
        self.samples = samples
    }

    func next() -> MirmirProcessTelemetryCounters {
        lock.withLock {
            let sample = samples[index]
            index += 1
            return sample
        }
    }
}

private final class MirmirAdjustableDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var wallMilliseconds: Int64
    private var uptimeNanoseconds: UInt64

    init(wallMilliseconds: Int64, uptimeNanoseconds: UInt64) {
        self.wallMilliseconds = wallMilliseconds
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    var clock: MirmirDiagnosticClock {
        MirmirDiagnosticClock(
            wallMilliseconds: { [self] in
                lock.withLock { wallMilliseconds }
            },
            uptimeNanoseconds: { [self] in
                lock.withLock { uptimeNanoseconds }
            }
        )
    }

    func set(wallMilliseconds: Int64, uptimeNanoseconds: UInt64) {
        lock.withLock {
            self.wallMilliseconds = wallMilliseconds
            self.uptimeNanoseconds = uptimeNanoseconds
        }
    }
}

private final class MirmirCountingApplicationLogSequence:
    Sequence, IteratorProtocol, @unchecked Sendable {
    typealias Element = MirmirDiagnosticApplicationLogExport.Candidate

    private let lock = NSLock()
    private let candidates: [Element]
    private var index = 0
    private var calls = 0

    init(_ candidates: [Element]) {
        self.candidates = candidates
    }

    var nextCallCount: Int {
        lock.withLock { calls }
    }

    func makeIterator() -> MirmirCountingApplicationLogSequence {
        self
    }

    func next() -> Element? {
        lock.withLock {
            calls += 1
            guard index < candidates.count else { return nil }
            defer { index += 1 }
            return candidates[index]
        }
    }
}

private final class MirmirBlockingDiagnosticExporter: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func export() -> Data {
        started.signal()
        released.wait()
        return Data("{}\n".utf8)
    }

    func waitUntilStarted() -> Bool {
        started.wait(timeout: .now() + 2) == .success
    }

    func release() {
        released.signal()
    }
}

private final class MirmirDiagnosticCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func finish() {
        lock.withLock { finished = true }
    }
}
