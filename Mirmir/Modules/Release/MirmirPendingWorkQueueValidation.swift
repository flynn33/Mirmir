import Foundation

extension MirmirPendingWorkQueue {
    func validatedEnqueueBatch(
        _ records: [MirmirPendingWorkRecord]
    ) throws -> [MirmirPendingWorkRecord] {
        var ids = Set<String>()
        var orders = Set<Int>()
        for record in records {
            try validate(record)
            guard record.state == .pending,
                  record.startedAt == nil else {
                throw MirmirPendingQueueError.invalidRecord(
                    field: .lifecycle
                )
            }
            guard ids.insert(record.id).inserted else {
                throw MirmirPendingQueueError.duplicateJobID
            }
            guard orders.insert(record.order).inserted else {
                throw MirmirPendingQueueError.invalidRecord(field: .order)
            }
        }
        return records.sorted(by: Self.isEarlier)
    }

    func validateQueue(
        _ records: [MirmirPendingWorkRecord]
    ) throws {
        guard records.count <= limits.maximumRecords else {
            throw MirmirPendingQueueError.capacityExceeded
        }
        var ids = Set<String>()
        var startedIndex: Int?
        for (index, record) in records.enumerated() {
            try validate(record)
            guard record.order == index else {
                throw MirmirPendingQueueError.invalidRecord(field: .order)
            }
            guard ids.insert(record.id).inserted else {
                throw MirmirPendingQueueError.duplicateJobID
            }
            if record.state == .started {
                guard startedIndex == nil else {
                    throw MirmirPendingQueueError.invalidRecord(
                        field: .lifecycle
                    )
                }
                startedIndex = index
            }
        }
        if let startedIndex, startedIndex != 0 {
            throw MirmirPendingQueueError.invalidRecord(field: .lifecycle)
        }
    }

    func recoveryReason(
        for records: [MirmirPendingWorkRecord]
    ) -> MirmirPendingQueueRecoveryReason? {
        guard records.count <= limits.maximumRecords else {
            return .countBoundExceeded
        }
        var ids = Set<String>()
        var orders = Set<Int>()
        var startedIndex: Int?
        for (index, record) in records.enumerated() {
            do {
                try validate(record)
            } catch let error as MirmirPendingQueueError {
                if error == .invalidRecord(field: .order) {
                    return .invalidOrder
                }
                if error == .invalidRecord(field: .lifecycle) {
                    return .invalidLifecycle
                }
                return .invalidRecord
            } catch {
                return .invalidRecord
            }
            guard ids.insert(record.id).inserted else {
                return .duplicateJobID
            }
            guard orders.insert(record.order).inserted else {
                return .invalidOrder
            }
            if record.state == .started {
                guard startedIndex == nil else {
                    return .invalidLifecycle
                }
                startedIndex = index
            }
        }
        let sorted = records.sorted(by: Self.isEarlier)
        guard sorted.enumerated().allSatisfy({
            $0.element.order == $0.offset
        }) else {
            return .invalidOrder
        }
        if let startedRecord = sorted.firstIndex(
            where: { $0.state == .started }
        ), startedRecord != 0 {
            return .invalidLifecycle
        }
        return nil
    }

    func validate(_ record: MirmirPendingWorkRecord) throws {
        try validateIdentity(record.id)
        try validateBookmark(
            record.bookmarks.sourceBookmark,
            field: .sourceBookmark
        )
        try validateBookmark(
            record.bookmarks.outputBookmark,
            field: .outputBookmark
        )
        try validateDisplayName(
            record.bookmarks.sourceDisplayName,
            field: .sourceDisplayName
        )
        try validateDisplayName(
            record.bookmarks.outputDisplayName,
            field: .outputDisplayName
        )
        let resolution = record.settings.targetResolution
        guard resolution.width > 0,
              resolution.height > 0,
              resolution.width <= 131_072,
              resolution.height <= 131_072 else {
            throw MirmirPendingQueueError.invalidRecord(
                field: .targetResolution
            )
        }
        guard record.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MirmirPendingQueueError.invalidRecord(field: .createdAt)
        }
        guard record.order >= 0,
              record.order < limits.maximumRecords else {
            throw MirmirPendingQueueError.invalidRecord(field: .order)
        }
        switch record.state {
        case .pending:
            guard record.startedAt == nil else {
                throw MirmirPendingQueueError.invalidRecord(
                    field: .lifecycle
                )
            }
        case .started:
            guard let startedAt = record.startedAt,
                  startedAt.timeIntervalSinceReferenceDate.isFinite,
                  startedAt >= record.createdAt else {
                throw MirmirPendingQueueError.invalidRecord(
                    field: .lifecycle
                )
            }
        }
        if let batch = record.settings.processingPathBatch {
            try validate(batch)
        }
    }

    func validateBatchResults(
        _ results: [MirmirProcessingPathBatchResult]
    ) throws {
        guard results.count <= limits.maximumRecords else {
            throw MirmirPendingQueueError.capacityExceeded
        }
        var jobIDs = Set<String>()
        var ordinalsByBatch: [String: Set<Int>] = [:]
        for result in results {
            try validate(result.batch)
            try validateIdentity(result.jobID)
            try validateDisplayName(
                result.outputDisplayName,
                field: .outputDisplayName
            )
            guard result.completedAt.timeIntervalSinceReferenceDate.isFinite,
                  jobIDs.insert(result.jobID).inserted,
                  ordinalsByBatch[result.batch.id, default: []]
                    .insert(result.batch.ordinal).inserted else {
                throw MirmirPendingQueueError.invalidRecord(
                    field: .processingPathBatch
                )
            }
        }
    }

    func validate(_ batch: MirmirProcessingPathBatchContext) throws {
        try validateIdentity(batch.id)
        guard batch.path != .automatic,
              batch.totalCount > 1,
              batch.totalCount <= limits.maximumRecords,
              batch.ordinal >= 0,
              batch.ordinal < batch.totalCount else {
            throw MirmirPendingQueueError.invalidRecord(
                field: .processingPathBatch
            )
        }
    }

    func validateIdentity(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 192,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 0x30 && $0.value <= 0x39)
                      || ($0.value >= 0x41 && $0.value <= 0x5A)
                      || ($0.value >= 0x61 && $0.value <= 0x7A)
                      || $0 == "."
                      || $0 == "_"
                      || $0 == "-"
                      || $0 == ":"
              }) else {
            throw MirmirPendingQueueError.invalidRecord(field: .jobID)
        }
    }

    func validateBookmark(
        _ bookmark: Data,
        field: MirmirPendingQueueField
    ) throws {
        guard !bookmark.isEmpty,
              bookmark.count <= limits.maximumBookmarkBytes else {
            throw MirmirPendingQueueError.invalidRecord(field: field)
        }
    }

    func validateDisplayName(
        _ value: String,
        field: MirmirPendingQueueField
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 512,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\u{0}") else {
            throw MirmirPendingQueueError.invalidRecord(field: field)
        }
    }

    static func isEarlier(
        _ lhs: MirmirPendingWorkRecord,
        _ rhs: MirmirPendingWorkRecord
    ) -> Bool {
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }
}
