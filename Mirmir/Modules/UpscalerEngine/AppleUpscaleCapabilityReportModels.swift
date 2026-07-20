import Foundation

enum R01PublicAPIStatus: String, Codable, Sendable {
    case `public`
    case notPublic = "not_public"
    case absent
}

enum R01HardwareEligibility: String, Codable, Sendable {
    case eligible
    case ineligible
    case unknown
}

enum R01StateHistory: String, Codable, Sendable {
    case stateless
    case stateful
    case requiresHistory = "requires_history"
    case unavailable
}

enum R01ModelReadiness: String, Codable, Sendable {
    case notRequired = "not_required"
    case ready
    case unavailable
    case acquisitionFailed = "acquisition_failed"
}

enum R01OfflineSuitability: String, Codable, Sendable {
    case suitable
    case requiresAcquisition = "requires_acquisition"
    case unavailable
    case unknown
}

enum R01SupportObservation: Equatable, Sendable {
    case supported
    case unsupported
    case notAvailable
}

extension R01SupportObservation: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = value ? .supported : .unsupported
        } else if try container.decode(String.self) == "not_available" {
            self = .notAvailable
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "R01 support observation must be true, false, or not_available."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .supported:
            try container.encode(true)
        case .unsupported:
            try container.encode(false)
        case .notAvailable:
            try container.encode("not_available")
        }
    }
}

struct R01PlatformRequirements: Codable, Equatable, Sendable {
    let minimumOSVersion: String?
    let minimumSDKVersion: String?
    let unavailableReason: R01ReasonCode?

    enum CodingKeys: String, CodingKey {
        case minimumOSVersion = "minimum_os_version"
        case minimumSDKVersion = "minimum_sdk_version"
        case unavailableReason = "unavailable_reason"
    }
}

struct R01SupportQuery: Codable, Equatable, Sendable {
    let apiOrEquivalentName: String
    let observed: R01SupportObservation
    let reasonCode: R01ReasonCode?

    enum CodingKeys: String, CodingKey {
        case apiOrEquivalentName = "api_or_equivalent_name"
        case observed
        case reasonCode = "reason_code"
    }
}

struct R01InputContract: Codable, Equatable, Sendable {
    let fixtureIDs: [String]
    let inputDimensions: [String]
    let outputDimensions: [String]
    let formats: [String]
    let colorExpectations: [String]
    let scales: [Double]
    let guidanceInputs: [String]
    let historyInputs: [String]
    let timestampContract: String?
    let modelIdentity: String?
    let modelSHA256: String?

    enum CodingKeys: String, CodingKey {
        case fixtureIDs = "fixture_ids"
        case inputDimensions = "input_dimensions"
        case outputDimensions = "output_dimensions"
        case formats
        case colorExpectations = "color_expectations"
        case scales
        case guidanceInputs = "guidance_inputs"
        case historyInputs = "history_inputs"
        case timestampContract = "timestamp_contract"
        case modelIdentity = "model_identity"
        case modelSHA256 = "model_sha256"
    }

    static func frozen(
        capabilityID: R01CapabilityID,
        for probeClass: R01ProbeClass,
        modelIdentity: String?,
        modelSHA256: String?
    ) -> R01InputContract {
        let color = ["SDR BT.709 video-range left-sited 8-bit NV12"]
        switch probeClass {
        case .primaryScaler:
            return .init(
                fixtureIDs: ["scaler-720p", "scaler-1080p"],
                inputDimensions: ["1280x720", "1920x1080"],
                outputDimensions: ["1920x1080", "3840x2160"],
                formats: ["420v"], colorExpectations: color,
                scales: [1.5, 2.0], guidanceInputs: [], historyInputs: [],
                timestampContract: nil, modelIdentity: nil, modelSHA256: nil
            )
        case .supportFilter:
            let fixtureIDs: [String]
            let formats: [String]
            let guidanceInputs: [String]
            let historyInputs: [String]
            switch capabilityID {
            case .a04:
                fixtureIDs = ["support-frame", "support-history"]
                formats = ["420v"]
                guidanceInputs = []
                historyInputs = ["support-history"]
            case .a15:
                fixtureIDs = ["support-frame", "support-guidance"]
                formats = ["420v", "L008"]
                guidanceInputs = ["support-guidance"]
                historyInputs = []
            case .a13, .a17:
                fixtureIDs = ["support-frame", "support-guidance", "support-history"]
                formats = ["420v", "L008"]
                guidanceInputs = ["support-guidance"]
                historyInputs = ["support-history"]
            default:
                fixtureIDs = []
                formats = []
                guidanceInputs = []
                historyInputs = []
            }
            return .init(
                fixtureIDs: fixtureIDs,
                inputDimensions: ["1920x1080"], outputDimensions: ["1920x1080"],
                formats: formats, colorExpectations: color,
                scales: [], guidanceInputs: guidanceInputs,
                historyInputs: historyInputs, timestampContract: nil,
                modelIdentity: nil, modelSHA256: nil
            )
        case .temporalAnalyzer:
            return .init(
                fixtureIDs: ["temporal-frame-0", "temporal-frame-1"],
                inputDimensions: ["1920x1080"], outputDimensions: [], formats: ["420v"],
                colorExpectations: color, scales: [], guidanceInputs: [],
                historyInputs: ["temporal-frame-0"], timestampContract: nil,
                modelIdentity: nil, modelSHA256: nil
            )
        case .cadenceTransform:
            return .init(
                fixtureIDs: ["cadence-frame-0", "cadence-frame-1"],
                inputDimensions: ["1920x1080"], outputDimensions: ["1920x1080"],
                formats: ["420v"], colorExpectations: color, scales: [], guidanceInputs: [],
                historyInputs: [], timestampContract: "PTS 0/600 and 20/600; duration 20/600",
                modelIdentity: nil, modelSHA256: nil
            )
        case .analysisRuntime:
            return .init(
                fixtureIDs: ["analysis-proxy", "analysis-probe-model"],
                inputDimensions: ["512x288"], outputDimensions: [], formats: ["BGRA"],
                colorExpectations: ["deterministic 8-bit BGRA proxy"], scales: [],
                guidanceInputs: [], historyInputs: [], timestampContract: nil,
                modelIdentity: modelIdentity, modelSHA256: modelSHA256
            )
        }
    }
}

struct R01PrimaryScalerObservation: Codable, Equatable, Sendable {
    let fixtureID: String
    let inputDimensions: String
    let outputDimensions: String
    let scale: Double
    let outputFormat: String

    enum CodingKeys: String, CodingKey {
        case fixtureID = "fixture_id"
        case inputDimensions = "input_dimensions"
        case outputDimensions = "output_dimensions"
        case scale
        case outputFormat = "output_format"
    }

    static let frozen: [R01PrimaryScalerObservation] = [
        .init(
            fixtureID: "scaler-720p",
            inputDimensions: "1280x720",
            outputDimensions: "1920x1080",
            scale: 1.5,
            outputFormat: "420v"
        ),
        .init(
            fixtureID: "scaler-1080p",
            inputDimensions: "1920x1080",
            outputDimensions: "3840x2160",
            scale: 2.0,
            outputFormat: "420v"
        )
    ]
}

enum R01MetricStatus: String, Codable, Sendable {
    case measured
    case notMeasured = "not_measured"
    case notApplicable = "not_applicable"
}

enum R01MetricValue: Equatable, Sendable {
    case string(String)
    case double(Double)
    case integer(Int)
    case boolean(Bool)
}

extension R01MetricValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }
}

struct R01MetricObservation: Codable, Equatable, Sendable {
    let status: R01MetricStatus
    let value: R01MetricValue?
    let unit: String
    let reason: String?
}

enum R01MetricName: String, CaseIterable, Codable, Sendable {
    case initializationSeconds = "initialization_seconds"
    case acquisitionSeconds = "acquisition_seconds"
    case medianWallSeconds = "median_wall_seconds"
    case p95WallSeconds = "p95_wall_seconds"
    case throughputUnitsPerSecond = "throughput_units_per_second"
    case peakResidentMemoryDeltaBytes = "peak_resident_memory_delta_bytes"
    case frameRate = "frame_rate"
    case preservedDimensions = "preserved_dimensions"
    case preservedFormat = "preserved_format"
    case requiredGuidance = "required_guidance"
    case flowDimensions = "flow_dimensions"
    case flowFormat = "flow_format"
    case confidenceAvailable = "confidence_available"
    case generatedFrameCount = "generated_frame_count"
    case outputCadence = "output_cadence"
    case timestampContract = "timestamp_contract"
    case loadSeconds = "load_seconds"
    case specializationSeconds = "specialization_seconds"
    case inferenceSeconds = "inference_seconds"
    case zeroCopyDisposition = "zero_copy_disposition"
    case statefulExecutionDisposition = "stateful_execution_disposition"

    var unit: String {
        switch self {
        case .initializationSeconds, .acquisitionSeconds, .medianWallSeconds,
             .p95WallSeconds, .loadSeconds, .specializationSeconds, .inferenceSeconds:
            return "seconds"
        case .throughputUnitsPerSecond: return "units_per_second"
        case .peakResidentMemoryDeltaBytes: return "bytes"
        case .preservedDimensions, .flowDimensions: return "pixels"
        case .preservedFormat, .flowFormat: return "pixel_format"
        case .frameRate, .outputCadence: return "frames_per_second"
        case .requiredGuidance, .confidenceAvailable: return "boolean"
        case .generatedFrameCount: return "frames"
        case .timestampContract: return "timestamp_contract"
        case .zeroCopyDisposition, .statefulExecutionDisposition: return "disposition"
        }
    }

    static func applicable(to probeClass: R01ProbeClass) -> Set<R01MetricName> {
        let common: Set<R01MetricName> = [
            .initializationSeconds, .acquisitionSeconds, .medianWallSeconds,
            .p95WallSeconds, .throughputUnitsPerSecond, .peakResidentMemoryDeltaBytes
        ]
        switch probeClass {
        case .primaryScaler:
            return common.union([.frameRate])
        case .supportFilter:
            return common.union([.preservedDimensions, .preservedFormat, .requiredGuidance])
        case .temporalAnalyzer:
            return common.union([.flowDimensions, .flowFormat, .confidenceAvailable])
        case .cadenceTransform:
            return common.union([.generatedFrameCount, .outputCadence, .timestampContract])
        case .analysisRuntime:
            return common.union([
                .loadSeconds, .specializationSeconds, .inferenceSeconds,
                .zeroCopyDisposition, .statefulExecutionDisposition
            ])
        }
    }
}

struct R01Metrics: Codable, Equatable, Sendable {
    let values: [R01MetricName: R01MetricObservation]

    init(values: [R01MetricName: R01MetricObservation]) throws {
        guard Set(values.keys) == Set(R01MetricName.allCases) else {
            throw R01LiveReportError.metricsNotClosed
        }
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: R01DynamicCodingKey.self)
        var decoded: [R01MetricName: R01MetricObservation] = [:]
        for key in container.allKeys {
            guard let metric = R01MetricName(rawValue: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Unknown R01 metric key."
                )
            }
            decoded[metric] = try container.decode(R01MetricObservation.self, forKey: key)
        }
        try self.init(values: decoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: R01DynamicCodingKey.self)
        for metric in R01MetricName.allCases {
            guard let value = values[metric] else {
                throw EncodingError.invalidValue(
                    values,
                    .init(codingPath: encoder.codingPath, debugDescription: "R01 metrics are not closed.")
                )
            }
            try container.encode(value, forKey: .init(metric.rawValue))
        }
    }
}

struct R01DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

enum R01SessionOutcome: String, Codable, Sendable {
    case completed
    case timeout
    case unsupportedContract = "unsupported_contract"
    case setupFailure = "setup_failure"
    case processingFailure = "processing_failure"
    case resourceFailure = "resource_failure"
}

enum R01FailureClass: String, Codable, Sendable {
    case none
    case timeout
    case unsupportedContract = "unsupported_contract"
    case setupFailure = "setup_failure"
    case processingFailure = "processing_failure"
    case resourceFailure = "resource_failure"
}

struct R01MeasurementSession: Codable, Equatable, Sendable {
    let sessionIndex: Int
    let completedWarmupUnits: Int
    let completedMeasuredUnits: Int
    let elapsedSeconds: Double
    let timedOut: Bool
    let outcome: R01SessionOutcome
    let failureDetail: String?

    enum CodingKeys: String, CodingKey {
        case sessionIndex = "session_index"
        case completedWarmupUnits = "completed_warmup_units"
        case completedMeasuredUnits = "completed_measured_units"
        case elapsedSeconds = "elapsed_seconds"
        case timedOut = "timed_out"
        case outcome
        case failureDetail = "failure_detail"
    }
}

enum R01RepeatabilityStatus: String, Codable, Sendable {
    case measured
    case notMeasured = "not_measured"
}

enum R01RepeatabilityMode: String, Codable, Sendable {
    case hash
    case tolerance
    case notApplicable = "not_applicable"
}

enum R01RepeatabilityValue: Equatable, Sendable {
    case hash(String)
    case tolerance(Double)
}

extension R01RepeatabilityValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .tolerance(value)
        } else {
            self = .hash(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .hash(let value): try container.encode(value)
        case .tolerance(let value): try container.encode(value)
        }
    }
}

struct R01Repeatability: Codable, Equatable, Sendable {
    let status: R01RepeatabilityStatus
    let mode: R01RepeatabilityMode
    let observations: [R01RepeatabilityValue]
    let tolerance: Double?
    let reason: String?
}

struct R01Measurements: Codable, Equatable, Sendable {
    let sessionCount: Int
    let warmupUnitsPerSession: Int
    let measuredUnitsPerSession: Int
    let timeoutSecondsPerSession: Int
    let sessions: [R01MeasurementSession]
    let metrics: R01Metrics
    let repeatability: R01Repeatability

    enum CodingKeys: String, CodingKey {
        case sessionCount = "session_count"
        case warmupUnitsPerSession = "warmup_units_per_session"
        case measuredUnitsPerSession = "measured_units_per_session"
        case timeoutSecondsPerSession = "timeout_seconds_per_session"
        case sessions, metrics, repeatability
    }
}
