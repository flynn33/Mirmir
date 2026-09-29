import Foundation

struct MirmirDiagnosticRetentionPolicy: Equatable, Sendable {
    static let production = MirmirDiagnosticRetentionPolicy(
        maximumAgeMilliseconds: 90 * 24 * 60 * 60 * 1_000,
        maximumRecords: 50_000,
        maximumTotalBytes: 128 * 1_024 * 1_024,
        maximumRecordBytes: 128 * 1_024,
        validated: true
    )

    let maximumAgeMilliseconds: Int64
    let maximumRecords: Int
    let maximumTotalBytes: Int
    let maximumRecordBytes: Int

    init(
        maximumAgeMilliseconds: Int64,
        maximumRecords: Int,
        maximumTotalBytes: Int,
        maximumRecordBytes: Int
    ) throws {
        guard maximumAgeMilliseconds > 0,
              maximumAgeMilliseconds <= 10 * 366 * 24 * 60 * 60 * 1_000,
              maximumRecords > 0,
              maximumRecords <= 1_000_000,
              maximumTotalBytes >= 512,
              maximumTotalBytes <= 512 * 1_024 * 1_024,
              maximumRecordBytes >= 128,
              maximumRecordBytes <= 128 * 1_024,
              maximumRecordBytes < maximumTotalBytes else {
            throw MirmirDiagnosticStoreError.invalidRetentionPolicy
        }
        self.init(
            maximumAgeMilliseconds: maximumAgeMilliseconds,
            maximumRecords: maximumRecords,
            maximumTotalBytes: maximumTotalBytes,
            maximumRecordBytes: maximumRecordBytes,
            validated: true
        )
    }

    private init(
        maximumAgeMilliseconds: Int64,
        maximumRecords: Int,
        maximumTotalBytes: Int,
        maximumRecordBytes: Int,
        validated: Bool
    ) {
        precondition(validated)
        self.maximumAgeMilliseconds = maximumAgeMilliseconds
        self.maximumRecords = maximumRecords
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumRecordBytes = maximumRecordBytes
    }
}

struct MirmirDiagnosticClock: Sendable {
    let wallMilliseconds: @Sendable () -> Int64
    let uptimeNanoseconds: @Sendable () -> UInt64

    static let production = MirmirDiagnosticClock(
        wallMilliseconds: {
            let milliseconds = Date().timeIntervalSince1970 * 1_000
            return Int64(max(0, min(milliseconds, Double(Int64.max))).rounded(.down))
        },
        uptimeNanoseconds: {
            DispatchTime.now().uptimeNanoseconds
        }
    )
}

enum MirmirDiagnosticStoreError: Error, Equatable, Sendable {
    case invalidRetentionPolicy
    case recordExceedsByteLimit(observed: Int, maximum: Int)
    case journalCapacityInsufficient
    case sequenceExhausted
    case unsupportedJournalSchema(Int)
    case malformedJournal
    case persistenceFailure(operation: String)
}
