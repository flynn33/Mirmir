import Foundation

enum R07TemporalHistoryResetCause: String, CaseIterable, Equatable, Sendable {
    case sceneCut = "scene_cut"
    case discontinuity
    case callerRequested = "caller_requested"
    case cancellation
    case endOfStream = "end_of_stream"
}

enum R07TemporalHistoryInsertionDisposition: String, Equatable, Sendable {
    case inserted
    case duplicateRejected = "duplicate_rejected"
    case staleRejected = "stale_rejected"
}

struct R07TemporalHistoryEntry: Equatable, Sendable {
    let frameOrdinal: Int64
    let backendID: String
    let preprocessStrengthQ16: R06ASHQ16
    let postprocessStrengthQ16: R06ASHQ16
    let artifactRiskQ16: R06ASHQ16
}

struct R07BackendChurnMetric: Equatable, Sendable {
    let changes: Int
    let transitionCount: Int
    let windowEntryCount: Int
    let valueQ16: R06ASHQ16
    let withinBound: Bool
    let excessive: Bool
}

struct R07StrengthChurnMetric: Equatable, Sendable {
    let transitionCount: Int
    let windowEntryCount: Int
    let meanTransitionDeltaQ16: R06ASHQ16
    let withinBound: Bool
    let excessive: Bool
}

struct R07ArtifactPersistenceMetric: Equatable, Sendable {
    let windowEntryCount: Int
    let meanRiskQ16: R06ASHQ16
    let withinBound: Bool
    let excessive: Bool
}

struct R07TemporalHistory: Equatable, Sendable {
    static let capacity = 8
    static let maximumChurnEntries = 5
    static let maximumArtifactPersistenceEntries = 4
    static let backendChurnThresholdQ16: Int64 = 32_768
    static let strengthChurnThresholdQ16: Int64 = 8_192
    static let artifactPersistenceThresholdQ16: Int64 = 8_192

    private(set) var generation: Int64
    private(set) var entries: [R07TemporalHistoryEntry]

    init(generation: Int64 = 0) {
        self.generation = generation
        entries = []
    }

    mutating func insert(
        _ entry: R07TemporalHistoryEntry
    ) -> R07TemporalHistoryInsertionDisposition {
        if let latestOrdinal = entries.last?.frameOrdinal {
            if entry.frameOrdinal == latestOrdinal {
                return .duplicateRejected
            }
            if entry.frameOrdinal < latestOrdinal {
                return .staleRejected
            }
        }

        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        return .inserted
    }

    mutating func reset(cause: R07TemporalHistoryResetCause) throws {
        _ = cause
        let nextGeneration = try R07CheckedInt64.add(generation, 1)
        entries.removeAll(keepingCapacity: true)
        generation = nextGeneration
    }

    func backendChurn() throws -> R07BackendChurnMetric {
        let window = Array(entries.suffix(Self.maximumChurnEntries))
        let transitionCount = max(0, window.count - 1)
        guard transitionCount > 0 else {
            return R07BackendChurnMetric(
                changes: 0,
                transitionCount: 0,
                windowEntryCount: window.count,
                valueQ16: .zero,
                withinBound: true,
                excessive: false
            )
        }

        var changes: Int64 = 0
        for index in 1..<window.count where window[index - 1].backendID != window[index].backendID {
            changes = try R07CheckedInt64.add(changes, 1)
        }
        let numerator = try R07CheckedInt64.multiply(changes, R06ASHQ16.scale)
        let value = try R07CheckedInt64.divideTowardZero(
            numerator,
            by: Int64(transitionCount)
        )
        return R07BackendChurnMetric(
            changes: Int(changes),
            transitionCount: transitionCount,
            windowEntryCount: window.count,
            valueQ16: R06ASHQ16(validatedRawValue: value),
            withinBound: value <= Self.backendChurnThresholdQ16,
            excessive: value > Self.backendChurnThresholdQ16
        )
    }

    func strengthChurn() throws -> R07StrengthChurnMetric {
        let window = Array(entries.suffix(Self.maximumChurnEntries))
        let transitionCount = max(0, window.count - 1)
        guard transitionCount > 0 else {
            return R07StrengthChurnMetric(
                transitionCount: 0,
                windowEntryCount: window.count,
                meanTransitionDeltaQ16: .zero,
                withinBound: true,
                excessive: false
            )
        }

        var transitionMeanSum: Int64 = 0
        for index in 1..<window.count {
            let preprocessDelta = try R07CheckedInt64.absoluteDifference(
                window[index].preprocessStrengthQ16.rawValue,
                window[index - 1].preprocessStrengthQ16.rawValue
            )
            let postprocessDelta = try R07CheckedInt64.absoluteDifference(
                window[index].postprocessStrengthQ16.rawValue,
                window[index - 1].postprocessStrengthQ16.rawValue
            )
            let deltaSum = try R07CheckedInt64.add(preprocessDelta, postprocessDelta)
            let transitionMean = try R07CheckedInt64.divideTowardZero(deltaSum, by: 2)
            transitionMeanSum = try R07CheckedInt64.add(
                transitionMeanSum,
                transitionMean
            )
        }
        let value = try R07CheckedInt64.divideTowardZero(
            transitionMeanSum,
            by: Int64(transitionCount)
        )
        return R07StrengthChurnMetric(
            transitionCount: transitionCount,
            windowEntryCount: window.count,
            meanTransitionDeltaQ16: R06ASHQ16(validatedRawValue: value),
            withinBound: value <= Self.strengthChurnThresholdQ16,
            excessive: value > Self.strengthChurnThresholdQ16
        )
    }

    func artifactPersistence() throws -> R07ArtifactPersistenceMetric {
        let window = Array(entries.suffix(Self.maximumArtifactPersistenceEntries))
        guard !window.isEmpty else {
            return R07ArtifactPersistenceMetric(
                windowEntryCount: 0,
                meanRiskQ16: .zero,
                withinBound: true,
                excessive: false
            )
        }

        var sum: Int64 = 0
        for entry in window {
            sum = try R07CheckedInt64.add(sum, entry.artifactRiskQ16.rawValue)
        }
        let value = try R07CheckedInt64.divideTowardZero(sum, by: Int64(window.count))
        return R07ArtifactPersistenceMetric(
            windowEntryCount: window.count,
            meanRiskQ16: R06ASHQ16(validatedRawValue: value),
            withinBound: value <= Self.artifactPersistenceThresholdQ16,
            excessive: value > Self.artifactPersistenceThresholdQ16
        )
    }
}
