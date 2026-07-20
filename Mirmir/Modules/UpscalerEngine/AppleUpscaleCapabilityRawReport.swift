import Foundation

struct R01RepositoryBinding: Codable, Equatable, Sendable {
    let path: String
    let sizeBytes: Int
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case path
        case sizeBytes = "size_bytes"
        case sha256
    }
}

struct R01FixtureBinding: Codable, Equatable, Sendable {
    let id: String
    let kind: String
    let identity: String
    let path: String?
    let sizeBytes: Int?
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case id, kind, identity, path
        case sizeBytes = "size_bytes"
        case sha256
    }
}

struct R01CapabilityRecord: Codable, Equatable, Sendable {
    static let notEvaluated = "not_evaluated_in_r01"

    let id: R01CapabilityID
    let family: String
    let method: String
    let probeClass: R01ProbeClass
    let compileState: R01CompileState
    let runtimeDisposition: R01RuntimeDisposition
    let reasonCode: R01ReasonCode
    let failureClass: R01FailureClass
    let publicAPIStatus: R01PublicAPIStatus
    let hardwareEligibility: R01HardwareEligibility
    let platformRequirements: R01PlatformRequirements
    let supportQuery: R01SupportQuery
    let inputContract: R01InputContract
    let stateHistory: R01StateHistory
    let modelReadiness: R01ModelReadiness
    let offlineSuitability: R01OfflineSuitability
    let primaryScalerObservations: [R01PrimaryScalerObservation]
    let measurements: R01Measurements
    let productQualification: String
    let backendEligibility: String
    let qualityEvaluation: String
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case id, family, method
        case probeClass = "probe_class"
        case compileState = "compile_state"
        case runtimeDisposition = "runtime_disposition"
        case reasonCode = "reason_code"
        case failureClass = "failure_class"
        case publicAPIStatus = "public_api_status"
        case hardwareEligibility = "hardware_eligibility"
        case platformRequirements = "platform_requirements"
        case supportQuery = "support_query"
        case inputContract = "input_contract"
        case stateHistory = "state_history"
        case modelReadiness = "model_readiness"
        case offlineSuitability = "offline_suitability"
        case primaryScalerObservations = "primary_scaler_observations"
        case measurements
        case productQualification = "product_qualification"
        case backendEligibility = "backend_eligibility"
        case qualityEvaluation = "quality_evaluation"
        case limitations
    }

    func validate(
        definition: R01CapabilityDefinition,
        modelIdentity: String?,
        modelSHA256: String?
    ) throws {
        guard id == definition.id, family == definition.family, method == definition.method,
              probeClass == definition.probeClass else {
            throw R01LiveReportError.capabilityRecordNotClosed(id.rawValue)
        }
        if runtimeDisposition == .runnable {
            guard reasonCode == .none, failureClass == .none else {
                throw R01LiveReportError.capabilityRecordNotClosed(id.rawValue)
            }
        } else {
            guard reasonCode != .none,
                  R01FailureClass.allowed(for: reasonCode).contains(failureClass) else {
                throw R01LiveReportError.capabilityRecordNotClosed(id.rawValue)
            }
        }
        guard compileState != .unavailable || runtimeDisposition != .runnable,
              supportQuery.isClosed,
              inputContract == .frozen(
                capabilityID: id,
                for: probeClass,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256
              ),
              productQualification == Self.notEvaluated,
              backendEligibility == Self.notEvaluated,
              qualityEvaluation == Self.notEvaluated,
              Set(limitations).count == limitations.count,
              limitations.allSatisfy({ !$0.isEmpty }) else {
            throw R01LiveReportError.capabilityRecordNotClosed(id.rawValue)
        }
        let expectedPrimaryObservations = probeClass == .primaryScaler
            && runtimeDisposition == .runnable
            ? R01PrimaryScalerObservation.frozen
            : []
        guard primaryScalerObservations == expectedPrimaryObservations else {
            throw R01LiveReportError.capabilityRecordNotClosed(id.rawValue)
        }
        try measurements.validate(
            probeClass: probeClass,
            runtimeDisposition: runtimeDisposition,
            reasonCode: reasonCode,
            failureClass: failureClass
        )
    }
}

struct R01RawHostReport: Codable, Equatable, Sendable {
    let schemaVersion: String
    let roadmapVersion: String
    let phaseID: String
    let sourceCommit: String
    let sourceTree: String
    let generatedAt: String
    let anchor: R01Anchor
    let host: R01HostRecord
    let implementationBindings: [R01RepositoryBinding]
    let preregistrationBinding: R01RepositoryBinding
    let fixtureBindings: [R01FixtureBinding]
    let capabilities: [R01CapabilityRecord]
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case roadmapVersion = "roadmap_version"
        case phaseID = "phase_id"
        case sourceCommit = "source_commit"
        case sourceTree = "source_tree"
        case generatedAt = "generated_at"
        case anchor, host
        case implementationBindings = "implementation_bindings"
        case preregistrationBinding = "preregistration_binding"
        case fixtureBindings = "fixture_bindings"
        case capabilities, limitations
    }

    func validate(modelIdentity: String?, modelSHA256: String?) throws {
        guard schemaVersion == "1.0", roadmapVersion == "1.0.1", phaseID == "R01",
              R01Validation.isGitObjectID(sourceCommit),
              R01Validation.isGitObjectID(sourceTree),
              R01Validation.isRFC3339(generatedAt),
              implementationBindings.map(\.path) == R01LiveProbeContext.implementationSourcePaths,
              implementationBindings.allSatisfy({
                  (1...R01RawReportWriter.maximumByteCount).contains($0.sizeBytes)
                      && R01Validation.isSHA256($0.sha256)
              }),
              preregistrationBinding.path ==
                "docs/roadmaps/evidence/r01/records/preregistration.json",
              fixtureBindings.map(\.id) == R01Validation.fixtureIDs,
              capabilities.map(\.id) == R01CapabilityID.allCases,
              Set(limitations).count == limitations.count,
              limitations.allSatisfy({ !$0.isEmpty }) else {
            throw R01LiveReportError.reportNotClosed
        }
        if anchor == .m3Air {
            guard ["Mac15,12", "Mac15,13"].contains(host.modelIdentifier),
                  host.chip == "Apple M3",
                  host.hardwareClasses.contains("macbook_air") else {
                throw R01LiveReportError.hostAssignmentMismatch("m3-air-hardware")
            }
        }
        if anchor == .coreAI,
           let coreAI = capabilities.first(where: { $0.id == .a18 }) {
            guard coreAI.compileState == .available || coreAI.compileState == .conditional,
                  coreAI.publicAPIStatus == .public else {
                throw R01LiveReportError.capabilityRecordNotClosed(R01CapabilityID.a18.rawValue)
            }
        }
        try R01CapabilityInventory.validate()
        for (definition, capability) in zip(R01CapabilityInventory.definitions, capabilities) {
            try capability.validate(
                definition: definition,
                modelIdentity: modelIdentity,
                modelSHA256: modelSHA256
            )
        }
    }
}

extension R01SupportQuery {
    var isClosed: Bool {
        guard !apiOrEquivalentName.isEmpty else { return false }
        switch observed {
        case .supported: return reasonCode == nil
        case .unsupported, .notAvailable:
            return reasonCode != nil && reasonCode != R01ReasonCode.none
        }
    }
}

extension R01FailureClass {
    static func allowed(for reason: R01ReasonCode) -> Set<R01FailureClass> {
        switch reason {
        case .none: return [.none]
        case .modelAcquisitionFailed: return [.setupFailure]
        case .runtimeProbeFailed:
            return [.timeout, .setupFailure, .processingFailure, .resourceFailure]
        case .resourceLimit: return [.resourceFailure]
        case .apiAbsent, .osTooOld, .sdkTooOld, .hardwareUnsupported,
             .modelUnavailable, .inputContractUnsatisfied, .notPublicAPI, .notApplicable:
            return [.unsupportedContract]
        }
    }
}

extension R01Measurements {
    func validate(
        probeClass: R01ProbeClass,
        runtimeDisposition: R01RuntimeDisposition,
        reasonCode: R01ReasonCode,
        failureClass: R01FailureClass
    ) throws {
        guard warmupUnitsPerSession == 5, measuredUnitsPerSession == 30,
              timeoutSecondsPerSession == 120, sessionCount == sessions.count,
              sessions.count <= 3 else {
            throw R01LiveReportError.measurementsNotClosed
        }
        for (offset, session) in sessions.enumerated() {
            guard session.sessionIndex == offset + 1,
                  (0...5).contains(session.completedWarmupUnits),
                  (0...30).contains(session.completedMeasuredUnits),
                  session.elapsedSeconds.isFinite,
                  (0...120).contains(session.elapsedSeconds) else {
                throw R01LiveReportError.measurementsNotClosed
            }
            if session.outcome == .completed {
                guard session.completedWarmupUnits == 5,
                      session.completedMeasuredUnits == 30,
                      !session.timedOut, session.failureDetail == nil else {
                    throw R01LiveReportError.measurementsNotClosed
                }
            } else {
                guard session.outcome.rawValue == failureClass.rawValue,
                      session.timedOut == (session.outcome == .timeout),
                      session.failureDetail?.isEmpty == false else {
                    throw R01LiveReportError.measurementsNotClosed
                }
            }
        }
        if runtimeDisposition == .runnable {
            guard sessions.count == 3, sessions.allSatisfy({ $0.outcome == .completed }),
                  repeatability.status == .measured else {
                throw R01LiveReportError.measurementsNotClosed
            }
        }
        try metrics.validate(
            probeClass: probeClass,
            runtimeDisposition: runtimeDisposition,
            reasonCode: reasonCode
        )
        try repeatability.validate(
            runtimeDisposition: runtimeDisposition,
            reasonCode: reasonCode
        )
    }
}

extension R01Metrics {
    func validate(
        probeClass: R01ProbeClass,
        runtimeDisposition: R01RuntimeDisposition,
        reasonCode: R01ReasonCode
    ) throws {
        guard Set(values.keys) == Set(R01MetricName.allCases) else {
            throw R01LiveReportError.metricsNotClosed
        }
        let applicable = R01MetricName.applicable(to: probeClass)
        for metric in R01MetricName.allCases {
            guard let observation = values[metric], observation.unit == metric.unit else {
                throw R01LiveReportError.metricsNotClosed
            }
            if !applicable.contains(metric) {
                guard observation.status == .notApplicable, observation.value == nil,
                      observation.reason == "not_applicable_for_\(probeClass.rawValue)" else {
                    throw R01LiveReportError.metricsNotClosed
                }
            } else if runtimeDisposition == .runnable {
                guard observation.status == .measured, observation.value != nil,
                      observation.reason == nil else {
                    throw R01LiveReportError.metricsNotClosed
                }
            } else {
                guard observation.status == .notMeasured, observation.value == nil,
                      observation.reason == reasonCode.rawValue else {
                    throw R01LiveReportError.metricsNotClosed
                }
            }
            try observation.validateValue()
        }
    }
}

extension R01MetricObservation {
    func validateValue() throws {
        guard let value else { return }
        switch value {
        case .double(let number):
            guard number.isFinite, number >= 0 else { throw R01LiveReportError.metricsNotClosed }
        case .integer(let number):
            guard number >= 0 else { throw R01LiveReportError.metricsNotClosed }
        case .string(let string):
            guard !string.isEmpty else { throw R01LiveReportError.metricsNotClosed }
        case .boolean:
            break
        }
    }
}

extension R01Repeatability {
    func validate(
        runtimeDisposition: R01RuntimeDisposition,
        reasonCode: R01ReasonCode
    ) throws {
        if runtimeDisposition == .runnable {
            guard status == .measured, observations.count == 3, reason == nil else {
                throw R01LiveReportError.measurementsNotClosed
            }
            switch mode {
            case .hash:
                guard tolerance == nil,
                      observations.allSatisfy({
                        if case .hash(let value) = $0 { return R01Validation.isSHA256(value) }
                        return false
                      }) else {
                    throw R01LiveReportError.measurementsNotClosed
                }
            case .tolerance:
                guard let tolerance, tolerance.isFinite, tolerance >= 0,
                      observations.allSatisfy({
                        if case .tolerance(let value) = $0 { return value.isFinite }
                        return false
                      }) else {
                    throw R01LiveReportError.measurementsNotClosed
                }
            case .notApplicable:
                throw R01LiveReportError.measurementsNotClosed
            }
        } else {
            guard status == .notMeasured, mode == .notApplicable, observations.isEmpty,
                  tolerance == nil, reason == reasonCode.rawValue else {
                throw R01LiveReportError.measurementsNotClosed
            }
        }
    }
}

enum R01Validation {
    static let fixtureIDs = [
        "scaler-720p", "scaler-1080p", "support-frame", "support-guidance",
        "support-history", "temporal-frame-0", "temporal-frame-1",
        "cadence-frame-0", "cadence-frame-1", "analysis-proxy", "analysis-probe-model"
    ]

    static func isGitObjectID(_ value: String) -> Bool {
        value.count == 40 && value != String(repeating: "0", count: 40)
            && value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value != String(repeating: "0", count: 64)
            && value.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    }

    static func isRFC3339(_ value: String) -> Bool {
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
