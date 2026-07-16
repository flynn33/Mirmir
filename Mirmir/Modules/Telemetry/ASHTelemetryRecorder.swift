import Foundation
import os

// The recorder keeps its lock-protected state machine and snapshot builder
// together so every terminal transition is audited in one implementation.
// swiftlint:disable file_length type_body_length

protocol ASHTelemetryRecording: AnyObject, Sendable {
    func beginRun(id: String)
    func beginStage(_ stage: ASHTelemetryStage, frameIndex: Int?) -> ASHTelemetryStageToken
    @discardableResult
    func endStage(_ token: ASHTelemetryStageToken) -> Bool
    func recordGPUTime(_ milliseconds: Double, for stage: ASHTelemetryStage)
    @discardableResult
    func increment(_ counter: ASHTelemetryCounter, by amount: UInt64) -> ASHTelemetryUpdateResult
    @discardableResult
    func recordState(rawValue: UInt16) -> ASHTelemetryUpdateResult
    @discardableResult
    func recordMessage(_ rawValue: UInt8) -> ASHTelemetryUpdateResult
    @discardableResult
    func recordOperator(_ rawValue: UInt8) -> ASHTelemetryUpdateResult
    func recordDecode(_ status: ASHDecodeStatus)
    func recordCandidateCount(_ count: Int)
    func recordCommandBuffer(_ observation: ASHCommandBufferObservation)
    func recordMedia(_ observation: ASHMediaObservation)
    func recordError(_ observation: ASHErrorObservation)
    @discardableResult
    func finish(status: ASHTelemetryRunStatus, message: String?) -> ASHTelemetrySnapshot
    func snapshot() -> ASHTelemetrySnapshot
}

extension ASHTelemetryRecording {
    func beginStage(_ stage: ASHTelemetryStage) -> ASHTelemetryStageToken {
        beginStage(stage, frameIndex: nil)
    }

    @discardableResult
    func increment(_ counter: ASHTelemetryCounter) -> ASHTelemetryUpdateResult {
        increment(counter, by: 1)
    }

    func measure<T>(
        _ stage: ASHTelemetryStage,
        frameIndex: Int? = nil,
        operation: () throws -> T
    ) rethrows -> T {
        let token = beginStage(stage, frameIndex: frameIndex)
        defer { endStage(token) }
        return try operation()
    }

    func measure<T>(
        _ stage: ASHTelemetryStage,
        frameIndex: Int? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        let token = beginStage(stage, frameIndex: frameIndex)
        defer { endStage(token) }
        return try await operation()
    }

    func recordError(_ error: Error, frameIndex: Int? = nil) {
        let nsError = error as NSError
        recordError(ASHErrorObservation(
            domain: nsError.domain,
            code: nsError.code,
            message: String(describing: error),
            frameIndex: frameIndex
        ))
    }
}

final class DefaultASHTelemetryRecorder: ASHTelemetryRecording, @unchecked Sendable {
    static let subsystem = "com.mirmir.ash.engine"
    static let category = "ASH"

    private struct OpenStage {
        let token: ASHTelemetryStageToken
        let startedNanoseconds: UInt64
        let frameIndex: Int?
        let signpostState: OSSignpostIntervalState?
    }

    private struct StageAccumulator {
        var count: UInt64 = 0
        var cpuTotalNanoseconds: UInt64 = 0
        var gpuTotalNanoseconds: UInt64 = 0
        var cpuSamplesNanoseconds: [UInt64] = []
        var gpuSamplesNanoseconds: [UInt64] = []
    }

    private enum HistogramKind {
        case state
        case message
        case `operator`

        var expectedCount: Int {
            switch self {
            case .state: 512
            case .message, .operator: 16
            }
        }

        var counter: ASHTelemetryCounter {
            switch self {
            case .state: .stateHistogram512
            case .message: .messageHistogram16
            case .operator: .operatorHistogram16
            }
        }
    }

    private struct State {
        var runID: String
        var startedNanoseconds: UInt64
        var endedNanoseconds: UInt64?
        var openStages: [UUID: OpenStage] = [:]
        var stages: [ASHTelemetryStage: StageAccumulator] = [:]
        var counters: [ASHTelemetryCounter: UInt64] = [:]
        var stateHistogram = Array(repeating: UInt64(0), count: 512)
        var messageHistogram = Array(repeating: UInt64(0), count: 16)
        var operatorHistogram = Array(repeating: UInt64(0), count: 16)
        var commandBuffers: [ASHCommandBufferObservation] = []
        var media: [ASHMediaObservation] = []
        var errors: [ASHErrorObservation] = []
        var events: [ASHTelemetryEvent] = []
        var nextSequence: UInt64 = 0
        var droppedEventCount: UInt64 = 0
        var droppedTimingSampleCount: UInt64 = 0
        var terminalStatus: ASHTelemetryRunStatus?
        var terminalMessage: String?

        init(runID: String, startedNanoseconds: UInt64) {
            self.runID = runID
            self.startedNanoseconds = startedNanoseconds
            for stage in ASHTelemetryStage.allCases {
                stages[stage] = StageAccumulator()
            }
            for counter in ASHTelemetryCounter.allCases {
                counters[counter] = 0
            }
        }
    }

    private let timestampProvider: @Sendable () -> UInt64
    private let eventCapacity: Int
    private let timingSampleCapacity: Int
    private let observationCapacity: Int
    private let signposter: OSSignposter?
    private let state: OSAllocatedUnfairLock<State>

    init(
        timestampProvider: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        eventCapacity: Int = 65_536,
        timingSampleCapacity: Int = 8_192,
        observationCapacity: Int = 8_192,
        emitsSignposts: Bool = true
    ) {
        precondition(eventCapacity >= 0)
        precondition(timingSampleCapacity >= 0)
        precondition(observationCapacity >= 0)
        self.timestampProvider = timestampProvider
        self.eventCapacity = eventCapacity
        self.timingSampleCapacity = timingSampleCapacity
        self.observationCapacity = observationCapacity
        self.signposter = emitsSignposts
            ? OSSignposter(subsystem: Self.subsystem, category: Self.category)
            : nil
        let now = timestampProvider()
        self.state = OSAllocatedUnfairLock(initialState: State(
            runID: UUID().uuidString,
            startedNanoseconds: now
        ))
    }

    func beginRun(id: String) {
        let now = timestampProvider()
        state.withLock { state in
            state = State(runID: id, startedNanoseconds: now)
            appendEvent(
                kind: .runStarted,
                timestamp: now,
                stage: nil,
                frameIndex: nil,
                details: ["run_id": id],
                state: &state
            )
        }
    }

    func beginStage(_ stage: ASHTelemetryStage, frameIndex: Int?) -> ASHTelemetryStageToken {
        let token = ASHTelemetryStageToken(id: UUID(), stage: stage)
        let now = timestampProvider()
        let signpostState = signposter?.beginInterval(stage.signpostName)
        let accepted = state.withLock { state -> Bool in
            guard state.terminalStatus == nil else { return false }
            state.openStages[token.id] = OpenStage(
                token: token,
                startedNanoseconds: now,
                frameIndex: frameIndex,
                signpostState: signpostState
            )
            appendEvent(
                kind: .stageBegan,
                timestamp: now,
                stage: stage,
                frameIndex: frameIndex,
                details: [:],
                state: &state
            )
            return true
        }
        if !accepted, let signpostState {
            signposter?.endInterval(stage.signpostName, signpostState)
        }
        return token
    }

    @discardableResult
    func endStage(_ token: ASHTelemetryStageToken) -> Bool {
        let now = timestampProvider()
        let openStage = state.withLock { state -> OpenStage? in
            guard state.terminalStatus == nil else { return nil }
            guard let openStage = state.openStages.removeValue(forKey: token.id),
                  openStage.token.stage == token.stage else {
                return nil
            }
            let duration = now >= openStage.startedNanoseconds
                ? now - openStage.startedNanoseconds
                : 0
            addTiming(
                duration,
                stage: token.stage,
                isGPU: false,
                state: &state
            )
            appendEvent(
                kind: .stageEnded,
                timestamp: now,
                stage: token.stage,
                frameIndex: openStage.frameIndex,
                details: ["duration_ns": String(duration)],
                state: &state
            )
            return openStage
        }
        guard let openStage else { return false }
        if let signpostState = openStage.signpostState {
            signposter?.endInterval(token.stage.signpostName, signpostState)
        }
        return true
    }

    func recordGPUTime(_ milliseconds: Double, for stage: ASHTelemetryStage) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        let nanoseconds = milliseconds * 1_000_000
        let bounded = min(nanoseconds, Double(UInt64.max))
        state.withLock { state in
            guard state.terminalStatus == nil else { return }
            addTiming(UInt64(bounded.rounded()), stage: stage, isGPU: true, state: &state)
        }
    }

    @discardableResult
    func increment(_ counter: ASHTelemetryCounter, by amount: UInt64) -> ASHTelemetryUpdateResult {
        state.withLock { state in
            guard state.terminalStatus == nil else { return .ignoredAfterTerminal }
            let current = state.counters[counter, default: 0]
            let result = saturatingAdd(current, amount)
            state.counters[counter] = result.value
            return result.didSaturate ? .saturated : .applied
        }
    }

    @discardableResult
    func recordState(rawValue: UInt16) -> ASHTelemetryUpdateResult {
        recordHistogram(index: Int(rawValue), kind: .state)
    }

    @discardableResult
    func recordMessage(_ rawValue: UInt8) -> ASHTelemetryUpdateResult {
        recordHistogram(index: Int(rawValue), kind: .message)
    }

    @discardableResult
    func recordOperator(_ rawValue: UInt8) -> ASHTelemetryUpdateResult {
        recordHistogram(index: Int(rawValue), kind: .operator)
    }

    func recordDecode(_ status: ASHDecodeStatus) {
        switch status {
        case .exact:
            increment(.decodeExact)
        case .corrected:
            increment(.decodeCorrected)
        case .uncorrectable:
            increment(.decodeRejected)
        }
    }

    func recordCandidateCount(_ count: Int) {
        switch count {
        case 1:
            increment(.candidateOne)
        case 2:
            increment(.candidateTwo)
        case 3...:
            increment(.candidateMoreThanTwo)
        default:
            break
        }
    }

    func recordCommandBuffer(_ observation: ASHCommandBufferObservation) {
        let now = timestampProvider()
        state.withLock { state in
            guard state.terminalStatus == nil else { return }
            if state.commandBuffers.count < observationCapacity {
                state.commandBuffers.append(observation)
            } else {
                state.droppedEventCount = saturatingAdd(state.droppedEventCount, 1).value
            }
            appendEvent(
                kind: .commandBuffer,
                timestamp: now,
                stage: nil,
                frameIndex: nil,
                details: ["label": observation.label, "status": observation.status],
                state: &state
            )
        }
    }

    func recordMedia(_ observation: ASHMediaObservation) {
        let now = timestampProvider()
        state.withLock { state in
            guard state.terminalStatus == nil else { return }
            if state.media.count < observationCapacity {
                state.media.append(observation)
            } else {
                state.droppedEventCount = saturatingAdd(state.droppedEventCount, 1).value
            }
            appendEvent(
                kind: .media,
                timestamp: now,
                stage: nil,
                frameIndex: observation.frameIndex,
                details: ["kind": observation.kind],
                state: &state
            )
        }
    }

    func recordError(_ observation: ASHErrorObservation) {
        let now = timestampProvider()
        state.withLock { state in
            guard state.terminalStatus == nil else { return }
            if state.errors.count < observationCapacity {
                state.errors.append(observation)
            } else {
                state.droppedEventCount = saturatingAdd(state.droppedEventCount, 1).value
            }
            appendEvent(
                kind: .error,
                timestamp: now,
                stage: nil,
                frameIndex: observation.frameIndex,
                details: ["domain": observation.domain, "message": observation.message],
                state: &state
            )
        }
    }

    @discardableResult
    func finish(status: ASHTelemetryRunStatus, message: String? = nil) -> ASHTelemetrySnapshot {
        let now = timestampProvider()
        return state.withLock { state in
            guard status != .running else { return makeSnapshot(state) }
            if state.terminalStatus == nil {
                state.terminalStatus = status
                state.terminalMessage = message
                state.endedNanoseconds = now
                appendEvent(
                    kind: .terminal,
                    timestamp: now,
                    stage: nil,
                    frameIndex: nil,
                    details: ["status": status.rawValue],
                    state: &state
                )
            }
            return makeSnapshot(state)
        }
    }

    func snapshot() -> ASHTelemetrySnapshot {
        state.withLock { makeSnapshot($0) }
    }

    private func recordHistogram(
        index: Int,
        kind: HistogramKind
    ) -> ASHTelemetryUpdateResult {
        state.withLock { state in
            guard state.terminalStatus == nil else { return .ignoredAfterTerminal }
            guard (0..<kind.expectedCount).contains(index) else { return .rejectedOutOfBounds }
            let bucket: (value: UInt64, didSaturate: Bool)
            switch kind {
            case .state:
                bucket = saturatingAdd(state.stateHistogram[index], 1)
                state.stateHistogram[index] = bucket.value
            case .message:
                bucket = saturatingAdd(state.messageHistogram[index], 1)
                state.messageHistogram[index] = bucket.value
            case .operator:
                bucket = saturatingAdd(state.operatorHistogram[index], 1)
                state.operatorHistogram[index] = bucket.value
            }
            let aggregate = saturatingAdd(state.counters[kind.counter, default: 0], 1)
            state.counters[kind.counter] = aggregate.value
            return bucket.didSaturate || aggregate.didSaturate ? .saturated : .applied
        }
    }

    private func addTiming(
        _ nanoseconds: UInt64,
        stage: ASHTelemetryStage,
        isGPU: Bool,
        state: inout State
    ) {
        var accumulator = state.stages[stage, default: StageAccumulator()]
        if isGPU {
            accumulator.gpuTotalNanoseconds = saturatingAdd(
                accumulator.gpuTotalNanoseconds,
                nanoseconds
            ).value
            if accumulator.gpuSamplesNanoseconds.count < timingSampleCapacity {
                accumulator.gpuSamplesNanoseconds.append(nanoseconds)
            } else {
                state.droppedTimingSampleCount = saturatingAdd(state.droppedTimingSampleCount, 1).value
            }
        } else {
            accumulator.count = saturatingAdd(accumulator.count, 1).value
            accumulator.cpuTotalNanoseconds = saturatingAdd(
                accumulator.cpuTotalNanoseconds,
                nanoseconds
            ).value
            if accumulator.cpuSamplesNanoseconds.count < timingSampleCapacity {
                accumulator.cpuSamplesNanoseconds.append(nanoseconds)
            } else {
                state.droppedTimingSampleCount = saturatingAdd(state.droppedTimingSampleCount, 1).value
            }
        }
        state.stages[stage] = accumulator
    }

    private func appendEvent(
        kind: ASHTelemetryEventKind,
        timestamp: UInt64,
        stage: ASHTelemetryStage?,
        frameIndex: Int?,
        details: [String: String],
        state: inout State
    ) {
        guard state.events.count < eventCapacity else {
            state.droppedEventCount = saturatingAdd(state.droppedEventCount, 1).value
            return
        }
        let sequence = state.nextSequence
        state.nextSequence = saturatingAdd(sequence, 1).value
        state.events.append(ASHTelemetryEvent(
            sequence: sequence,
            kind: kind,
            timestampNanoseconds: timestamp,
            stage: stage,
            frameIndex: frameIndex,
            details: details
        ))
    }

    private func makeSnapshot(_ state: State) -> ASHTelemetrySnapshot {
        let status = state.terminalStatus ?? .running
        var failures = state.errors.map(\.message)
        if let terminalMessage = state.terminalMessage, !terminalMessage.isEmpty {
            failures.append(terminalMessage)
        }
        if !state.openStages.isEmpty {
            failures.append("unbalanced_stage_intervals=\(state.openStages.count)")
        }
        let counterValues = Dictionary(uniqueKeysWithValues: ASHTelemetryCounter.allCases.map {
            ($0.rawValue, state.counters[$0, default: 0])
        })
        let stageValues = ASHTelemetryStage.allCases.map { stage -> ASHStageTimingSnapshot in
            let value = state.stages[stage, default: StageAccumulator()]
            return ASHStageTimingSnapshot(
                name: stage,
                count: value.count,
                cpuMilliseconds: percentiles(
                    samples: value.cpuSamplesNanoseconds,
                    totalNanoseconds: value.cpuTotalNanoseconds
                ),
                gpuMilliseconds: percentiles(
                    samples: value.gpuSamplesNanoseconds,
                    totalNanoseconds: value.gpuTotalNanoseconds
                )
            )
        }
        return ASHTelemetrySnapshot(
            schemaVersion: "1.0.0",
            runID: state.runID,
            startedNanoseconds: state.startedNanoseconds,
            endedNanoseconds: state.endedNanoseconds,
            stages: stageValues,
            counters: counterValues,
            ash: ASHASHTelemetrySnapshot(
                stateHistogram: state.stateHistogram,
                messageHistogram: state.messageHistogram,
                operatorHistogram: state.operatorHistogram,
                decoder: ASHDecoderTelemetrySnapshot(
                    exact: state.counters[.decodeExact, default: 0],
                    correctedOneBit: state.counters[.decodeCorrected, default: 0],
                    rejected: state.counters[.decodeRejected, default: 0]
                ),
                candidateCounts: ASHCandidateTelemetrySnapshot(
                    one: state.counters[.candidateOne, default: 0],
                    two: state.counters[.candidateTwo, default: 0],
                    moreThanTwo: state.counters[.candidateMoreThanTwo, default: 0]
                ),
                runtimeTreeGenerations: state.counters[.runtimeTreeGenerations, default: 0]
            ),
            commandBuffers: state.commandBuffers,
            media: state.media,
            errors: state.errors,
            events: state.events,
            droppedEventCount: state.droppedEventCount,
            droppedTimingSampleCount: state.droppedTimingSampleCount,
            result: ASHTelemetryResultSnapshot(
                status: status,
                balancedIntervals: state.openStages.isEmpty,
                failures: failures
            )
        )
    }

    private func percentiles(samples: [UInt64], totalNanoseconds: UInt64) -> ASHPercentileTotals {
        guard !samples.isEmpty else {
            return ASHPercentileTotals(
                p50: 0,
                p95: 0,
                p99: 0,
                total: Double(totalNanoseconds) / 1_000_000
            )
        }
        let sorted = samples.sorted()
        func value(at percentile: Double) -> Double {
            let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
            return Double(sorted[min(rank - 1, sorted.count - 1)]) / 1_000_000
        }
        return ASHPercentileTotals(
            p50: value(at: 0.50),
            p95: value(at: 0.95),
            p99: value(at: 0.99),
            total: Double(totalNanoseconds) / 1_000_000
        )
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> (value: UInt64, didSaturate: Bool) {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? (UInt64.max, true) : (result.partialValue, false)
    }
}

final class ASHNoopTelemetryRecorder: ASHTelemetryRecording, @unchecked Sendable {
    static let shared = ASHNoopTelemetryRecorder()

    private init() {}

    func beginRun(id _: String) {}

    func beginStage(_ stage: ASHTelemetryStage, frameIndex _: Int?) -> ASHTelemetryStageToken {
        ASHTelemetryStageToken(id: UUID(), stage: stage)
    }

    func endStage(_: ASHTelemetryStageToken) -> Bool { true }
    func recordGPUTime(_: Double, for _: ASHTelemetryStage) {}
    func increment(_: ASHTelemetryCounter, by _: UInt64) -> ASHTelemetryUpdateResult { .applied }
    func recordState(rawValue _: UInt16) -> ASHTelemetryUpdateResult { .applied }
    func recordMessage(_: UInt8) -> ASHTelemetryUpdateResult { .applied }
    func recordOperator(_: UInt8) -> ASHTelemetryUpdateResult { .applied }
    func recordDecode(_: ASHDecodeStatus) {}
    func recordCandidateCount(_: Int) {}
    func recordCommandBuffer(_: ASHCommandBufferObservation) {}
    func recordMedia(_: ASHMediaObservation) {}
    func recordError(_: ASHErrorObservation) {}

    func finish(status: ASHTelemetryRunStatus, message: String?) -> ASHTelemetrySnapshot {
        makeSnapshot(status: status, message: message)
    }

    func snapshot() -> ASHTelemetrySnapshot {
        makeSnapshot(status: .running, message: nil)
    }

    private func makeSnapshot(status: ASHTelemetryRunStatus, message: String?) -> ASHTelemetrySnapshot {
        ASHTelemetrySnapshot(
            schemaVersion: "1.0.0",
            runID: "disabled",
            startedNanoseconds: 0,
            endedNanoseconds: nil,
            stages: ASHTelemetryStage.allCases.map {
                ASHStageTimingSnapshot(
                    name: $0,
                    count: 0,
                    cpuMilliseconds: .zero,
                    gpuMilliseconds: .zero
                )
            },
            counters: Dictionary(uniqueKeysWithValues: ASHTelemetryCounter.allCases.map { ($0.rawValue, 0) }),
            ash: ASHASHTelemetrySnapshot(
                stateHistogram: Array(repeating: 0, count: 512),
                messageHistogram: Array(repeating: 0, count: 16),
                operatorHistogram: Array(repeating: 0, count: 16),
                decoder: ASHDecoderTelemetrySnapshot(exact: 0, correctedOneBit: 0, rejected: 0),
                candidateCounts: ASHCandidateTelemetrySnapshot(one: 0, two: 0, moreThanTwo: 0),
                runtimeTreeGenerations: 0
            ),
            commandBuffers: [],
            media: [],
            errors: [],
            events: [],
            droppedEventCount: 0,
            droppedTimingSampleCount: 0,
            result: ASHTelemetryResultSnapshot(
                status: status,
                balancedIntervals: true,
                failures: message.map { [$0] } ?? []
            )
        )
    }
}

// swiftlint:enable file_length type_body_length
