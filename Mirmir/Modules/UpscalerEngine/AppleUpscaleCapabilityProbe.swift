import Foundation

enum R01Anchor: String, CaseIterable, Codable, Sendable {
    case oldestSupported = "oldest-supported"
    case m3Air = "m3-air"
    case proMax = "pro-max"
    case coreAI = "core-ai"

    var canonicalOutputPath: String {
        "project-notes/evidence/r01/hosts/anchor-\(rawValue).json"
    }
}

enum R01CapabilityID: String, CaseIterable, Codable, Sendable {
    case a01 = "A01"
    case a02 = "A02"
    case a03 = "A03"
    case a04 = "A04"
    case a05 = "A05"
    case a06 = "A06"
    case a07 = "A07"
    case a08 = "A08"
    case a09 = "A09"
    case a10 = "A10"
    case a11 = "A11"
    case a12 = "A12"
    case a13 = "A13"
    case a14 = "A14"
    case a15 = "A15"
    case a16 = "A16"
    case a17 = "A17"
    case a18 = "A18"
}

enum R01ProbeClass: String, Codable, Sendable {
    case primaryScaler = "primary_scaler"
    case supportFilter = "support_filter"
    case temporalAnalyzer = "temporal_analyzer"
    case cadenceTransform = "cadence_transform"
    case analysisRuntime = "analysis_runtime"
}

enum R01CompileState: String, Codable, Sendable {
    case available
    case conditional
    case unavailable
}

enum R01RuntimeDisposition: String, Codable, Sendable {
    case runnable
    case restricted
    case diagnosticOnly = "diagnostic_only"
    case unsupported
    case unavailable
    case rejected
}

enum R01ReasonCode: String, Codable, Sendable {
    case none
    case apiAbsent = "api_absent"
    case osTooOld = "os_too_old"
    case sdkTooOld = "sdk_too_old"
    case hardwareUnsupported = "hardware_unsupported"
    case modelUnavailable = "model_unavailable"
    case modelAcquisitionFailed = "model_acquisition_failed"
    case inputContractUnsatisfied = "input_contract_unsatisfied"
    case runtimeProbeFailed = "runtime_probe_failed"
    case resourceLimit = "resource_limit"
    case notPublicAPI = "not_public_api"
    case notApplicable = "not_applicable"
}

struct R01CapabilityDefinition: Codable, Equatable, Sendable {
    let id: R01CapabilityID
    let family: String
    let method: String
    let probeClass: R01ProbeClass
}

struct R01HostRecord: Codable, Equatable, Sendable {
    let hostID: String
    let modelIdentifier: String
    let chip: String
    let memoryBytes: UInt64
    let osVersion: String
    let osBuild: String
    let xcodeVersion: String
    let xcodeBuild: String
    let sdkVersion: String
    let sdkBuild: String
    let hardwareClasses: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case hostID = "host_id"
        case modelIdentifier = "model_identifier"
        case chip
        case memoryBytes = "memory_bytes"
        case osVersion = "os_version"
        case osBuild = "os_build"
        case xcodeVersion = "xcode_version"
        case xcodeBuild = "xcode_build"
        case sdkVersion = "sdk_version"
        case sdkBuild = "sdk_build"
        case hardwareClasses = "hardware_classes"
    }

    static func validateClosedJSONObject(_ object: [String: Any]) throws {
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        let actual = Set(object.keys)
        guard expected == actual else {
            throw R01ProbeContractError.hostRecordKeysNotClosed(
                missing: expected.subtracting(actual).sorted(),
                extra: actual.subtracting(expected).sorted()
            )
        }
    }
}

enum R01CapabilityInventory {
    static let definitions: [R01CapabilityDefinition] = [
        .init(
            id: .a01,
            family: "VideoToolbox",
            method: "VTSuperResolutionScaler",
            probeClass: .primaryScaler
        ),
        .init(
            id: .a02,
            family: "VideoToolbox",
            method: "VTLowLatencySuperResolutionScaler",
            probeClass: .primaryScaler
        ),
        .init(
            id: .a03,
            family: "VideoToolbox",
            method: "VTLowLatencyFrameInterpolation spatial scaling",
            probeClass: .cadenceTransform
        ),
        .init(
            id: .a04,
            family: "VideoToolbox",
            method: "VTTemporalNoiseFilter",
            probeClass: .supportFilter
        ),
        .init(
            id: .a05,
            family: "VideoToolbox",
            method: "VTOpticalFlow",
            probeClass: .temporalAnalyzer
        ),
        .init(
            id: .a06,
            family: "VideoToolbox",
            method: "VTPixelTransferSession",
            probeClass: .primaryScaler
        ),
        .init(id: .a07, family: "MetalFX", method: "Spatial scaler", probeClass: .primaryScaler),
        .init(id: .a08, family: "MetalFX", method: "Temporal scaler", probeClass: .primaryScaler),
        .init(
            id: .a09,
            family: "MetalFX",
            method: "Temporal denoised scaler",
            probeClass: .primaryScaler
        ),
        .init(id: .a10, family: "MetalFX", method: "Frame interpolator", probeClass: .cadenceTransform),
        .init(id: .a11, family: "MPS", method: "MPSImageLanczosScale", probeClass: .primaryScaler),
        .init(id: .a12, family: "MPS", method: "MPSImageBilinearScale", probeClass: .primaryScaler),
        .init(
            id: .a13,
            family: "MPS",
            method: "Guided/detail/artifact filters",
            probeClass: .supportFilter
        ),
        .init(
            id: .a14,
            family: "CoreImage",
            method: "Lanczos/Bicubic scale",
            probeClass: .primaryScaler
        ),
        .init(
            id: .a15,
            family: "CoreImage",
            method: "EdgePreserveUpsample",
            probeClass: .supportFilter
        ),
        .init(
            id: .a16,
            family: "Accelerate",
            method: "vImage Lanczos-3/Lanczos-5/custom",
            probeClass: .primaryScaler
        ),
        .init(id: .a17, family: "Metal", method: "Custom compute", probeClass: .supportFilter),
        .init(
            id: .a18,
            family: "CoreAI",
            method: "Custom model runtime",
            probeClass: .analysisRuntime
        )
    ]

    static func validate(_ values: [R01CapabilityDefinition] = definitions) throws {
        guard values.map(\.id) == R01CapabilityID.allCases else {
            throw R01ProbeContractError.capabilityInventoryNotClosed
        }
        guard Set(values.map(\.id)).count == R01CapabilityID.allCases.count else {
            throw R01ProbeContractError.capabilityInventoryNotClosed
        }
    }
}

struct R01LiveProbeRequest: Equatable, Sendable {
    static let liveFlag = "MIRMIR_R01_LIVE_PROBES"
    static let acquisitionFlag = "MIRMIR_R01_ALLOW_MODEL_ACQUISITION"
    static let anchorVariable = "MIRMIR_R01_ANCHOR"
    static let outputVariable = "MIRMIR_R01_OUTPUT"

    let anchor: R01Anchor
    let outputURL: URL
    let allowsModelAcquisition: Bool

    static func resolve(
        environment: [String: String],
        repositoryRoot: URL
    ) throws -> R01LiveProbeRequest? {
        let liveValue = environment[liveFlag]
        let acquisitionValue = environment[acquisitionFlag]
        let anchorValue = environment[anchorVariable]
        let outputValue = environment[outputVariable]

        if let liveValue, liveValue != "1" {
            throw R01ProbeContractError.invalidBooleanFlag(name: liveFlag, value: liveValue)
        }
        if let acquisitionValue, acquisitionValue != "1" {
            throw R01ProbeContractError.invalidBooleanFlag(name: acquisitionFlag, value: acquisitionValue)
        }

        guard liveValue == "1" else {
            if acquisitionValue != nil || anchorValue != nil || outputValue != nil {
                throw R01ProbeContractError.liveConfigurationWithoutAuthorization
            }
            return nil
        }

        guard let anchorValue, let anchor = R01Anchor(rawValue: anchorValue) else {
            throw R01ProbeContractError.invalidAnchor(anchorValue)
        }
        guard let outputValue, !outputValue.isEmpty else {
            throw R01ProbeContractError.outputMissing
        }

        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let expected = root.appendingPathComponent(anchor.canonicalOutputPath).standardizedFileURL
        let supplied = outputValue.hasPrefix("/")
            ? URL(fileURLWithPath: outputValue).standardizedFileURL
            : root.appendingPathComponent(outputValue).standardizedFileURL
        guard supplied == expected else {
            throw R01ProbeContractError.noncanonicalOutput(
                expected: expected.path,
                actual: supplied.path
            )
        }
        try rejectSymbolicLinks(between: root, and: expected)

        return R01LiveProbeRequest(
            anchor: anchor,
            outputURL: expected,
            allowsModelAcquisition: acquisitionValue == "1"
        )
    }

    private static func rejectSymbolicLinks(between root: URL, and output: URL) throws {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard output.path.hasPrefix(rootPrefix) else {
            throw R01ProbeContractError.noncanonicalOutput(
                expected: rootPrefix,
                actual: output.path
            )
        }

        let relativePath = String(output.path.dropFirst(rootPrefix.count))
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw R01ProbeContractError.symbolicLinkInOutputPath(current.path)
            }
        }
    }
}

struct R01CapabilityProbeObservation: Codable, Equatable, Sendable {
    let id: R01CapabilityID
    let compileState: R01CompileState
    let runtimeDisposition: R01RuntimeDisposition
    let reasonCode: R01ReasonCode
    let limitations: [String]

    func validate(for definition: R01CapabilityDefinition) throws {
        guard id == definition.id else {
            throw R01ProbeContractError.observationIdentityMismatch(
                expected: definition.id,
                actual: id
            )
        }
        if runtimeDisposition == .runnable {
            guard reasonCode == .none else {
                throw R01ProbeContractError.invalidReasonPair(
                    disposition: runtimeDisposition,
                    reason: reasonCode
                )
            }
        } else {
            guard reasonCode != .none else {
                throw R01ProbeContractError.invalidReasonPair(
                    disposition: runtimeDisposition,
                    reason: reasonCode
                )
            }
        }
    }
}

protocol R01CapabilityProbing: Sendable {
    func probe(
        _ definition: R01CapabilityDefinition,
        request: R01LiveProbeRequest
    ) async throws -> R01CapabilityProbeObservation
}

struct R01CapabilityProbeCoordinator: Sendable {
    private let probeImplementation: any R01CapabilityProbing

    init(probeImplementation: any R01CapabilityProbing) {
        self.probeImplementation = probeImplementation
    }

    func run(request: R01LiveProbeRequest) async throws -> [R01CapabilityProbeObservation] {
        try R01CapabilityInventory.validate()
        var observations: [R01CapabilityProbeObservation] = []
        observations.reserveCapacity(R01CapabilityInventory.definitions.count)

        for definition in R01CapabilityInventory.definitions {
            let observation = try await probeImplementation.probe(definition, request: request)
            try observation.validate(for: definition)
            observations.append(observation)
        }
        return observations
    }
}

enum R01ProbeContractError: Error, Equatable, CustomStringConvertible {
    case capabilityInventoryNotClosed
    case invalidBooleanFlag(name: String, value: String)
    case liveConfigurationWithoutAuthorization
    case invalidAnchor(String?)
    case outputMissing
    case noncanonicalOutput(expected: String, actual: String)
    case observationIdentityMismatch(expected: R01CapabilityID, actual: R01CapabilityID)
    case invalidReasonPair(disposition: R01RuntimeDisposition, reason: R01ReasonCode)
    case hostRecordKeysNotClosed(missing: [String], extra: [String])
    case symbolicLinkInOutputPath(String)

    var description: String {
        switch self {
        case .capabilityInventoryNotClosed:
            return "R01 capability inventory must contain A01-A18 exactly once and in order."
        case .invalidBooleanFlag(let name, let value):
            return "\(name) must be absent or exactly 1; received \(value)."
        case .liveConfigurationWithoutAuthorization:
            return "R01 anchor, output, and acquisition settings require MIRMIR_R01_LIVE_PROBES=1."
        case .invalidAnchor(let value):
            return "Invalid R01 anchor: \(value ?? "<missing>")."
        case .outputMissing:
            return "MIRMIR_R01_OUTPUT is required for a live R01 probe."
        case .noncanonicalOutput(let expected, let actual):
            return "R01 output must be canonical. Expected \(expected); received \(actual)."
        case .observationIdentityMismatch(let expected, let actual):
            return "Probe returned \(actual.rawValue) while evaluating \(expected.rawValue)."
        case .invalidReasonPair(let disposition, let reason):
            return "Invalid runtime disposition/reason pair: \(disposition.rawValue)/\(reason.rawValue)."
        case .hostRecordKeysNotClosed(let missing, let extra):
            return "R01 host keys are not closed; missing=\(missing), extra=\(extra)."
        case .symbolicLinkInOutputPath(let path):
            return "R01 output path must not contain a symbolic link: \(path)."
        }
    }
}
