import Foundation

struct ASHPercentileTotals: Codable, Equatable, Sendable {
    let p50: Double
    let p95: Double
    let p99: Double
    let total: Double

    static let zero = ASHPercentileTotals(p50: 0, p95: 0, p99: 0, total: 0)
}

struct ASHStageTimingSnapshot: Codable, Equatable, Sendable {
    let name: ASHTelemetryStage
    let count: UInt64
    let cpuMilliseconds: ASHPercentileTotals
    let gpuMilliseconds: ASHPercentileTotals

    enum CodingKeys: String, CodingKey {
        case name
        case count
        case cpuMilliseconds = "cpu_ms"
        case gpuMilliseconds = "gpu_ms"
    }
}

struct ASHDecoderTelemetrySnapshot: Codable, Equatable, Sendable {
    let exact: UInt64
    let correctedOneBit: UInt64
    let rejected: UInt64

    enum CodingKeys: String, CodingKey {
        case exact
        case correctedOneBit = "corrected_one_bit"
        case rejected
    }
}

struct ASHCandidateTelemetrySnapshot: Codable, Equatable, Sendable {
    let one: UInt64
    let two: UInt64
    let moreThanTwo: UInt64

    enum CodingKeys: String, CodingKey {
        case one
        case two
        case moreThanTwo = "more_than_two"
    }
}

struct ASHASHTelemetrySnapshot: Codable, Equatable, Sendable {
    let stateHistogram: [UInt64]
    let messageHistogram: [UInt64]
    let operatorHistogram: [UInt64]
    let decoder: ASHDecoderTelemetrySnapshot
    let candidateCounts: ASHCandidateTelemetrySnapshot
    let runtimeTreeGenerations: UInt64

    enum CodingKeys: String, CodingKey {
        case stateHistogram = "state_histogram"
        case messageHistogram = "message_histogram"
        case operatorHistogram = "operator_histogram"
        case decoder
        case candidateCounts = "candidate_counts"
        case runtimeTreeGenerations = "runtime_tree_generations"
    }
}

struct ASHCommandBufferObservation: Codable, Equatable, Sendable {
    let label: String
    let status: String
    let errorDomain: String?
    let errorCode: Int?
    let gpuStartSeconds: Double?
    let gpuEndSeconds: Double?

    init(
        label: String,
        status: String,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        gpuStartSeconds: Double? = nil,
        gpuEndSeconds: Double? = nil
    ) {
        self.label = label
        self.status = status
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.gpuStartSeconds = gpuStartSeconds
        self.gpuEndSeconds = gpuEndSeconds
    }

    enum CodingKeys: String, CodingKey {
        case label
        case status
        case errorDomain = "error_domain"
        case errorCode = "error_code"
        case gpuStartSeconds = "gpu_start_seconds"
        case gpuEndSeconds = "gpu_end_seconds"
    }
}

struct ASHMediaObservation: Codable, Equatable, Sendable {
    let kind: String
    let frameIndex: Int?
    let presentationTimestampValue: Int64?
    let presentationTimestampTimescale: Int32?
    let details: [String: String]

    init(
        kind: String,
        frameIndex: Int? = nil,
        presentationTimestampValue: Int64? = nil,
        presentationTimestampTimescale: Int32? = nil,
        details: [String: String] = [:]
    ) {
        self.kind = kind
        self.frameIndex = frameIndex
        self.presentationTimestampValue = presentationTimestampValue
        self.presentationTimestampTimescale = presentationTimestampTimescale
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case frameIndex = "frame_index"
        case presentationTimestampValue = "pts_value"
        case presentationTimestampTimescale = "pts_timescale"
        case details
    }
}

struct ASHErrorObservation: Codable, Equatable, Sendable {
    let domain: String
    let code: Int?
    let message: String
    let frameIndex: Int?

    init(domain: String, code: Int? = nil, message: String, frameIndex: Int? = nil) {
        self.domain = domain
        self.code = code
        self.message = message
        self.frameIndex = frameIndex
    }

    enum CodingKeys: String, CodingKey {
        case domain
        case code
        case message
        case frameIndex = "frame_index"
    }
}

struct ASHTelemetryEvent: Codable, Equatable, Sendable {
    let sequence: UInt64
    let kind: ASHTelemetryEventKind
    let timestampNanoseconds: UInt64
    let stage: ASHTelemetryStage?
    let frameIndex: Int?
    let details: [String: String]

    enum CodingKeys: String, CodingKey {
        case sequence
        case kind
        case timestampNanoseconds = "timestamp_ns"
        case stage
        case frameIndex = "frame_index"
        case details
    }
}

struct ASHTelemetryResultSnapshot: Codable, Equatable, Sendable {
    let status: ASHTelemetryRunStatus
    let balancedIntervals: Bool
    let failures: [String]

    enum CodingKeys: String, CodingKey {
        case status
        case balancedIntervals = "balanced_intervals"
        case failures
    }
}

struct ASHTelemetrySnapshot: Codable, Equatable, Sendable {
    let schemaVersion: String
    let runID: String
    let startedNanoseconds: UInt64
    let endedNanoseconds: UInt64?
    let stages: [ASHStageTimingSnapshot]
    let counters: [String: UInt64]
    let ash: ASHASHTelemetrySnapshot
    let commandBuffers: [ASHCommandBufferObservation]
    let media: [ASHMediaObservation]
    let errors: [ASHErrorObservation]
    let events: [ASHTelemetryEvent]
    let droppedEventCount: UInt64
    let droppedTimingSampleCount: UInt64
    let result: ASHTelemetryResultSnapshot

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case startedNanoseconds = "started_ns"
        case endedNanoseconds = "ended_ns"
        case stages
        case counters
        case ash
        case commandBuffers = "command_buffers"
        case media
        case errors
        case events
        case droppedEventCount = "dropped_event_count"
        case droppedTimingSampleCount = "dropped_timing_sample_count"
        case result
    }
}
