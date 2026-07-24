import Foundation
import XCTest
@testable import Mirmir

final class R13EngineRecoveryScopeTests: XCTestCase {
    func testRecoveredJobRetainsSelectedSecurityScopesUntilTerminal()
        async throws {
        let eventLog = R13ReleaseTestEventLog()
        let media = R13ReleaseTestMediaPipeline(
            resolution: .p720,
            frames: [
                try R13ReleaseTestFrames.make(
                    resolution: .p720,
                    index: 0
                )
            ],
            eventLog: eventLog
        )
        let factory = R13ReleaseTestSessionFactory(
            behavior: .suspendUntilCancelled,
            eventLog: eventLog
        )
        let service = R13ReleaseUpscalerEngineService(
            media: media,
            sessionFactory: { [factory] route in
                try await factory.make(route: route)
            }
        )
        let job = makeJob()
        var access: R13SecurityScopedAccessSet? = R13SecurityScopedAccessSet(
            leases: try R13BookmarkRole.allCases.map { role in
                try R13SecurityScopeLease(
                    role: role,
                    resolved: R13ResolvedSecurityScopedBookmark(
                        url: role == .source
                            ? job.inputURL
                            : job.outputURL.deletingLastPathComponent(),
                        isStale: false,
                        startAccessing: {
                            eventLog.record(
                                "scope.start.\(role.rawValue)"
                            )
                            return true
                        },
                        stopAccessing: {
                            eventLog.record(
                                "scope.stop.\(role.rawValue)"
                            )
                        }
                    )
                )
            }
        )
        var recovered: R13ResolvedRecoverableUpscaleJob? =
            R13ResolvedRecoverableUpscaleJob(
                summary: try R13RecoverableUpscaleJob(job: job),
                job: job,
                securityAccess: try XCTUnwrap(access)
            )

        let handle = try service.submitRecoveredJob(
            try XCTUnwrap(recovered)
        )
        recovered = nil
        access = nil
        try await waitForEvent("apple.submit.0", in: eventLog)

        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(
                eventCount("scope.start.\(role.rawValue)", in: eventLog),
                1
            )
            XCTAssertEqual(
                eventCount("scope.stop.\(role.rawValue)", in: eventLog),
                0
            )
        }

        handle.cancel()
        do {
            _ = try await handle.waitForCompletion()
            XCTFail("Cancellation must terminate the recovered job.")
        } catch let error as UpscalerEngineError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
        }
        for role in R13BookmarkRole.allCases {
            XCTAssertEqual(
                eventCount("scope.stop.\(role.rawValue)", in: eventLog),
                1
            )
        }
    }

    func testCatalogRejectsCorruptRecordChainAndCachedArtifact()
        async throws {
        let fixture = try R13HardeningFixture()
        defer { fixture.cleanup() }
        let runtime = try fixture.makeRuntime(
            cacheProbe: R13CapacityProbe(capacity: UInt64.max),
            outputProbe: R13CapacityProbe(capacity: UInt64.max)
        )
        let jobIDs = [
            "r13-valid-cached-recovery",
            "r13-corrupt-record-recovery",
            "r13-corrupt-artifact-recovery"
        ]
        for jobID in jobIDs {
            let attempt = try await runtime.prepare(
                job: fixture.makeJob(identifier: jobID),
                source: fixture.sourceProfile,
                route: .scale3Over2,
                modeBinding: R13ReleaseModePolicy.binding(
                    for: .deterministic
                )
            )
            try await attempt.commit(
                pixelBuffer: R13ReleaseTestFrames.makeOutput(
                    resolution: .p1080
                ),
                at: 0
            )
            await attempt.releaseResources()
        }

        let corruptRecordDirectory = fixture.jobDirectory(
            identifier: jobIDs[1]
        )
        let corruptRecordURL = corruptRecordDirectory
            .appendingPathComponent("records/0.json")
        let originalRecord = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(contentsOf: corruptRecordURL)
        )
        let corruptRecord = try R13RestartCommitRecord(
            sequence: originalRecord.sequence,
            artifact: originalRecord.artifact,
            previousRecordSHA256: String(repeating: "f", count: 64),
            recordSHA256: originalRecord.recordSHA256
        )
        try R13RestartCanonical.data(corruptRecord).write(
            to: corruptRecordURL,
            options: .atomic
        )

        let corruptArtifactDirectory = fixture.jobDirectory(
            identifier: jobIDs[2]
        )
        let artifactRecord = try JSONDecoder().decode(
            R13RestartCommitRecord.self,
            from: Data(
                contentsOf: corruptArtifactDirectory
                    .appendingPathComponent("records/0.json")
            )
        )
        let corruptArtifactURL = corruptArtifactDirectory
            .appendingPathComponent(
                artifactRecord.artifact.relativePath
            )
        var corruptArtifact = try Data(contentsOf: corruptArtifactURL)
        corruptArtifact[corruptArtifact.startIndex] ^= 0x01
        try corruptArtifact.write(
            to: corruptArtifactURL,
            options: .atomic
        )

        let catalog = try await runtime.recoverableJobs()

        XCTAssertEqual(catalog.jobs.map(\.id), [jobIDs[0]])
        XCTAssertEqual(catalog.rejectedEntryCount, 2)
        let diagnostics = await runtime.diagnosticsSnapshot()
        XCTAssertTrue(
            diagnostics.records.contains { record in
                record.event.code == .recoveryDiscovered
                    && record.event.fields.contains { field in
                        field.key == .outcome
                            && field.value
                                == R13ReleaseDiagnosticOutcome
                                    .reopened.rawValue
                    }
            },
            "A valid cached recovery must remain discoverable as reopened."
        )
    }

    private func makeJob() -> UpscaleJob {
        let identifier = "r13-recovered-scope-lifetime"
        return UpscaleJob(
            identifier: identifier,
            inputURL: URL(fileURLWithPath: "/tmp/\(identifier)-input.mp4"),
            outputURL: URL(fileURLWithPath: "/tmp/\(identifier).mp4"),
            targetResolution: .p1080,
            preserveAudio: false,
            mode: .deterministic
        )
    }

    private func waitForEvent(
        _ event: String,
        in eventLog: R13ReleaseTestEventLog
    ) async throws {
        for _ in 0..<200 {
            if eventLog.contains(event) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(event). Events: \(eventLog.events)")
    }

    private func eventCount(
        _ event: String,
        in eventLog: R13ReleaseTestEventLog
    ) -> Int {
        eventLog.events.filter { $0 == event }.count
    }
}
