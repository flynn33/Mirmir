import Foundation
import XCTest
@testable import Mirmir

final class R13RestartJobContractsTests: XCTestCase {
    func testCoreBindsCallerSuppliedJobIdentityAndEveryProcessingInput() throws {
        let core = try makeCore(jobID: "5D5B4E39-74E9-4A57-A0E1-B86A9DF47042")

        XCTAssertEqual(
            core.jobID,
            "5D5B4E39-74E9-4A57-A0E1-B86A9DF47042"
        )
        XCTAssertEqual(core.source.byteCount, 42)
        XCTAssertEqual(core.processing.requestedMode, "quality")
        XCTAssertEqual(core.processing.effectiveMode, "deterministic")
        XCTAssertEqual(core.processing.routeIdentity, "scale_3_over_2")
        XCTAssertEqual(core.processing.backendIdentity, "r03.mps.lanczos")
        XCTAssertEqual(core.processing.backendRevision, "1")
        XCTAssertEqual(core.output.width, 4)
        XCTAssertEqual(core.output.height, 2)
        XCTAssertEqual(core.output.pixelFormat, "420v")
        XCTAssertEqual(core.totalFrameCount, 3)
        XCTAssertNoThrow(try core.validate())
    }

    func testCoreRejectsPathTraversalAndUnsupportedOutputFormat() throws {
        XCTAssertThrowsError(try makeCore(jobID: "../other-job")) { error in
            XCTAssertEqual(
                error as? R13RestartJobError,
                .invalidIdentity(field: "job_id")
            )
        }

        XCTAssertThrowsError(
            try R13RestartOutputIdentity(
                width: 4,
                height: 2,
                pixelFormat: "2vuy",
                codec: "hevc",
                audioPolicy: "preserve"
            )
        ) { error in
            XCTAssertEqual(
                error as? R13RestartJobError,
                .invalidPixelFormat("2vuy")
            )
        }
    }

    func testOutputIdentityAcceptsEveryCheckpointPixelFormat() throws {
        let supportedFormats = try R13PixelLayoutRegistry
            .supportedPixelFormats
            .map(R13CachedPixelFormat.fourCC)
            .sorted()

        for pixelFormat in supportedFormats {
            let output = try R13RestartOutputIdentity(
                width: 4,
                height: 2,
                pixelFormat: pixelFormat,
                codec: "hevc",
                audioPolicy: "preserve"
            )

            XCTAssertEqual(output.pixelFormat, pixelFormat)
            XCTAssertNoThrow(try output.validate())
        }
    }

    func testAttemptPlanAlwaysStartsFreshWriterAtFrameZero() throws {
        let first = try R13RestartRecordReference(
            sequence: 0,
            relativePath: "records/0.json",
            recordSHA256: String(repeating: "a", count: 64)
        )
        let second = try R13RestartRecordReference(
            sequence: 1,
            relativePath: "records/1.json",
            recordSHA256: String(repeating: "b", count: 64)
        )
        let plan = R13RestartAttemptPlan(
            jobID: "job-1",
            coreSHA256: String(repeating: "c", count: 64),
            headSHA256: second.recordSHA256,
            totalFrameCount: 3,
            verifiedCachedRecords: [first, second],
            writerStartFrameIndex: 0,
            partialMediaReusePolicy: .forbidden
        )

        XCTAssertTrue(plan.requiresFreshMediaWriter)
        XCTAssertEqual(plan.writerStartFrameIndex, 0)
        XCTAssertEqual(plan.verifiedCachedPrefixCount, 2)
        XCTAssertEqual(plan.backendStartFrameIndex, 2)
        XCTAssertEqual(
            try plan.disposition(forFrameAt: 0),
            .replayVerifiedCache
        )
        XCTAssertEqual(
            try plan.disposition(forFrameAt: 1),
            .replayVerifiedCache
        )
        XCTAssertEqual(try plan.disposition(forFrameAt: 2), .runBackend)
        XCTAssertThrowsError(try plan.disposition(forFrameAt: 3))
    }

    func testLocalSourceMeasurerBindsExactBytesAndDetectsMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.bin")
        try Data("source-v1".utf8).write(to: sourceURL)

        let measurer = R13LocalRestartSourceMeasurer()
        let first = try measurer.measureSource(at: sourceURL)
        try Data("source-v2".utf8).write(to: sourceURL, options: .atomic)
        let second = try measurer.measureSource(at: sourceURL)

        XCTAssertEqual(first.byteCount, 9)
        XCTAssertEqual(second.byteCount, 9)
        XCTAssertNotEqual(first.sha256, second.sha256)
    }

    private func makeCore(jobID: String) throws -> R13RestartJobCore {
        try R13RestartJobCore(
            jobID: jobID,
            source: R13RestartSourceIdentity(
                sha256: String(repeating: "1", count: 64),
                byteCount: 42
            ),
            processing: R13RestartProcessingIdentity(
                requestedMode: "quality",
                effectiveMode: "deterministic",
                routeIdentity: "scale_3_over_2",
                backendIdentity: "r03.mps.lanczos",
                backendRevision: "1"
            ),
            output: R13RestartOutputIdentity(
                width: 4,
                height: 2,
                codec: "hevc",
                audioPolicy: "preserve"
            ),
            totalFrameCount: 3
        )
    }
}
