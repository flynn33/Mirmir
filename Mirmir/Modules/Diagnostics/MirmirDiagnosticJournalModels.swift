import Foundation

struct MirmirDiagnosticJournalHeader: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let nextSequence: UInt64
    let prunedRecordCount: UInt64
    let rejectedRecordCount: UInt64
    let recoveredCorruptTailCount: UInt64
    let recoveredCorruptByteCount: UInt64

    init(
        nextSequence: UInt64,
        prunedRecordCount: UInt64,
        rejectedRecordCount: UInt64,
        recoveredCorruptTailCount: UInt64,
        recoveredCorruptByteCount: UInt64
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.nextSequence = nextSequence
        self.prunedRecordCount = prunedRecordCount
        self.rejectedRecordCount = rejectedRecordCount
        self.recoveredCorruptTailCount = recoveredCorruptTailCount
        self.recoveredCorruptByteCount = recoveredCorruptByteCount
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case nextSequence = "next_sequence"
        case prunedRecordCount = "pruned_record_count"
        case rejectedRecordCount = "rejected_record_count"
        case recoveredCorruptTailCount = "recovered_corrupt_tail_count"
        case recoveredCorruptByteCount = "recovered_corrupt_byte_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MirmirDiagnosticStoreError.unsupportedJournalSchema(
                schemaVersion
            )
        }
        self.init(
            nextSequence: try container.decode(
                UInt64.self,
                forKey: .nextSequence
            ),
            prunedRecordCount: try container.decode(
                UInt64.self,
                forKey: .prunedRecordCount
            ),
            rejectedRecordCount: try container.decode(
                UInt64.self,
                forKey: .rejectedRecordCount
            ),
            recoveredCorruptTailCount: try container.decode(
                UInt64.self,
                forKey: .recoveredCorruptTailCount
            ),
            recoveredCorruptByteCount: try container.decode(
                UInt64.self,
                forKey: .recoveredCorruptByteCount
            )
        )
    }
}

struct MirmirStoredDiagnosticRecord: Sendable {
    let record: MirmirDiagnosticRecord
    let line: Data
}

struct MirmirDiagnosticStoreState: Sendable {
    var nextSequence: UInt64
    var prunedRecordCount: UInt64
    var rejectedRecordCount: UInt64
    var recoveredCorruptTailCount: UInt64
    var recoveredCorruptByteCount: UInt64
    var records: [MirmirStoredDiagnosticRecord]
    var journalByteCount: Int

    static let empty = MirmirDiagnosticStoreState(
        nextSequence: 0,
        prunedRecordCount: 0,
        rejectedRecordCount: 0,
        recoveredCorruptTailCount: 0,
        recoveredCorruptByteCount: 0,
        records: [],
        journalByteCount: 0
    )

    var retainedRecordByteCount: Int {
        records.reduce(into: 0) { total, stored in
            total += stored.line.count
        }
    }

    var header: MirmirDiagnosticJournalHeader {
        MirmirDiagnosticJournalHeader(
            nextSequence: nextSequence,
            prunedRecordCount: prunedRecordCount,
            rejectedRecordCount: rejectedRecordCount,
            recoveredCorruptTailCount: recoveredCorruptTailCount,
            recoveredCorruptByteCount: recoveredCorruptByteCount
        )
    }
}

enum MirmirDiagnosticPersistenceMutation {
    case append(Data)
    case replace(Data)
}
