import Foundation
import XCTest
@testable import Mirmir

final class MirmirPendingWorkQueueRecoveryTests: XCTestCase {
    func testMalformedDocumentIsQuarantinedAndResetWithoutDataLoss()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let malformed = Data(#"{"schemaVersion":1,"records":["#.utf8)
        try malformed.write(
            to: pendingQueueDocumentURL(in: directory),
            options: .atomic
        )

        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let recovered = try await queue.load()
        XCTAssertEqual(recovered.records, [])
        XCTAssertEqual(recovered.recovery?.reason, .malformedDocument)
        try assertQuarantinePreserved(
            original: malformed,
            recovery: recovered.recovery,
            directory: directory
        )

        let subsequent = try await queue.load()
        XCTAssertEqual(subsequent.records, [])
        XCTAssertNil(subsequent.recovery)
    }

    func testOversizedDocumentIsQuarantinedBeforeDecoding() async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let limits = try MirmirPendingQueueLimits(
            maximumRecords: 10,
            maximumDocumentBytes: 1_024,
            maximumBookmarkBytes: 256
        )
        let oversized = Data(repeating: 0x41, count: 1_025)
        try oversized.write(
            to: pendingQueueDocumentURL(in: directory),
            options: .atomic
        )

        let queue = MirmirPendingWorkQueue(
            directoryURL: directory,
            limits: limits
        )
        let recovered = try await queue.load()
        XCTAssertEqual(recovered.records, [])
        XCTAssertEqual(recovered.recovery?.reason, .oversizedDocument)
        try assertQuarantinePreserved(
            original: oversized,
            recovery: recovered.recovery,
            directory: directory
        )
    }

    func testReducedCountBoundQuarantinesWholeDocumentInsteadOfDroppingJobs()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let wideLimits = try MirmirPendingQueueLimits(
            maximumRecords: 3,
            maximumDocumentBytes: 64 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let narrowLimits = try MirmirPendingQueueLimits(
            maximumRecords: 2,
            maximumDocumentBytes: 64 * 1_024,
            maximumBookmarkBytes: 1_024
        )
        let seedQueue = MirmirPendingWorkQueue(
            directoryURL: directory,
            limits: wideLimits
        )
        _ = try await seedQueue.enqueueMany([
            makePendingQueueRecord(id: "job-one", order: 0),
            makePendingQueueRecord(id: "job-two", order: 1),
            makePendingQueueRecord(id: "job-three", order: 2)
        ])
        let original = try Data(
            contentsOf: pendingQueueDocumentURL(in: directory)
        )

        let boundedQueue = MirmirPendingWorkQueue(
            directoryURL: directory,
            limits: narrowLimits
        )
        let recovered = try await boundedQueue.load()
        XCTAssertEqual(recovered.records, [])
        XCTAssertEqual(recovered.recovery?.reason, .countBoundExceeded)
        try assertQuarantinePreserved(
            original: original,
            recovery: recovered.recovery,
            directory: directory
        )
    }

    func testDuplicateIdentifiersInSavedDocumentAreIsolated() async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        _ = try await queue.enqueueMany([
            makePendingQueueRecord(id: "job-one", order: 0),
            makePendingQueueRecord(id: "job-two", order: 1)
        ])

        var document = try readDocument(in: directory)
        var records = try XCTUnwrap(
            document["records"] as? [[String: Any]]
        )
        records[1]["id"] = records[0]["id"]
        document["records"] = records
        let corrupted = try writeDocument(document, in: directory)

        let recovered = try await queue.load()
        XCTAssertEqual(recovered.records, [])
        XCTAssertEqual(recovered.recovery?.reason, .duplicateJobID)
        try assertQuarantinePreserved(
            original: corrupted,
            recovery: recovered.recovery,
            directory: directory
        )
    }

    func testUnsupportedSchemaVersionIsRejectedWithoutReplacingDocument()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        _ = try await queue.enqueue(
            makePendingQueueRecord(id: "job-versioned", order: 0)
        )
        var document = try readDocument(in: directory)
        document["schemaVersion"] = 99
        let unsupported = try writeDocument(document, in: directory)

        do {
            _ = try await queue.load()
            XCTFail("An unsupported schema version was accepted.")
        } catch {
            XCTAssertEqual(
                error as? MirmirPendingQueueError,
                .unsupportedSchemaVersion(99)
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: pendingQueueDocumentURL(in: directory)),
            unsupported
        )
        let quarantineFiles = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("pending-work-corrupt-") }
        XCTAssertEqual(quarantineFiles, [])
    }

    func testLegacyConfigurationDecodingDefaultsMissingConfigurationAndEffects()
        async throws {
        let directory = try makePendingQueueTemporaryDirectory()
        let queue = MirmirPendingWorkQueue(directoryURL: directory)
        let effects = UpscaleEffectConfiguration(
            edgePreservationEnabled: true,
            compressionCleanupEnabled: true,
            textureGrainProtectionEnabled: true,
            temporalStabilityEnabled: true
        )
        let fullConfiguration = UpscaleProcessingConfiguration(
            enginePreference: .accelerateVImageHighQuality,
            strategyPreference: .direct,
            temporalConsistencyEnabled: false,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .low,
            effects: effects
        )
        _ = try await queue.enqueueMany([
            makePendingQueueRecord(
                id: "job-missing-configuration",
                order: 0,
                settings: makePendingQueueSettings(
                    codec: .h264,
                    preserveAudio: false,
                    requestedMode: .fast,
                    processingConfiguration: fullConfiguration
                )
            ),
            makePendingQueueRecord(
                id: "job-missing-effects",
                order: 1,
                settings: makePendingQueueSettings(
                    processingConfiguration: fullConfiguration
                )
            )
        ])

        var document = try readDocument(in: directory)
        var records = try XCTUnwrap(
            document["records"] as? [[String: Any]]
        )
        var firstSettings = try XCTUnwrap(
            records[0]["settings"] as? [String: Any]
        )
        firstSettings.removeValue(forKey: "processingConfiguration")
        records[0]["settings"] = firstSettings

        var secondSettings = try XCTUnwrap(
            records[1]["settings"] as? [String: Any]
        )
        var secondConfiguration = try XCTUnwrap(
            secondSettings["processingConfiguration"] as? [String: Any]
        )
        secondConfiguration.removeValue(forKey: "effects")
        secondSettings["processingConfiguration"] = secondConfiguration
        records[1]["settings"] = secondSettings
        document["records"] = records
        _ = try writeDocument(document, in: directory)

        let reloadedQueue = MirmirPendingWorkQueue(directoryURL: directory)
        let recovered = try await reloadedQueue.load()
        XCTAssertNil(recovered.recovery)
        XCTAssertEqual(recovered.records.count, 2)

        let first = recovered.records[0].settings
        XCTAssertEqual(first.codec.rawValue, OutputCodec.h264.rawValue)
        XCTAssertFalse(first.preserveAudio)
        XCTAssertEqual(first.requestedMode.rawValue, UpscaleMode.fast.rawValue)
        XCTAssertEqual(first.processingConfiguration, .default)

        let second = recovered.records[1].settings.processingConfiguration
        XCTAssertEqual(
            second.enginePreference,
            fullConfiguration.enginePreference
        )
        XCTAssertEqual(
            second.strategyPreference,
            fullConfiguration.strategyPreference
        )
        XCTAssertEqual(
            second.temporalConsistencyEnabled,
            fullConfiguration.temporalConsistencyEnabled
        )
        XCTAssertEqual(
            second.edgeFidelityLevel,
            fullConfiguration.edgeFidelityLevel
        )
        XCTAssertEqual(
            second.detailRecoveryLevel,
            fullConfiguration.detailRecoveryLevel
        )
        XCTAssertEqual(second.effects, .default)
    }
}

private extension MirmirPendingWorkQueueRecoveryTests {
    func readDocument(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: pendingQueueDocumentURL(in: directory))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    @discardableResult
    func writeDocument(
        _ document: [String: Any],
        in directory: URL
    ) throws -> Data {
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        )
        try data.write(
            to: pendingQueueDocumentURL(in: directory),
            options: .atomic
        )
        return data
    }

    func assertQuarantinePreserved(
        original: Data,
        recovery: MirmirPendingQueueRecovery?,
        directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fileName = try XCTUnwrap(
            recovery?.quarantineFileName,
            file: file,
            line: line
        )
        XCTAssertFalse(fileName.contains("/"), file: file, line: line)
        let quarantined = try Data(
            contentsOf: directory.appendingPathComponent(fileName)
        )
        XCTAssertEqual(quarantined, original, file: file, line: line)
    }
}
