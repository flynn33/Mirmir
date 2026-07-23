import Foundation

// swiftlint:disable file_length

enum R12RouteResolverErrorV2: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidScaleFactor(numerator: Int64, denominator: Int64)
    case resolutionOutOfRange(role: String, width: Int, height: Int)
    case nonUniformScale(
        widthNumerator: Int64,
        widthDenominator: Int64,
        heightNumerator: Int64,
        heightDenominator: Int64
    )
    case invalidPreferenceOrdinal(routeID: String, ordinal: Int)
    case emptyScaleFactors(routeID: String)
    case duplicateScaleFactor(routeID: String, numerator: Int64, denominator: Int64)
    case emptyFormatTransitions(routeID: String)
    case duplicateFormatTransition(routeID: String)
    case backendFormatMismatch(routeID: String, contractSHA256: String)
    case nativeRouteRequiresNativeEvidence(routeID: String)
    case nativeEvidenceMismatch(routeID: String)
    case duplicateHardwareRoute(String)
    case duplicateCandidateRoute(String)
    case duplicateNativeObservation(String)
    case nativeObservationForDeterministicRoute(String)
    case nativeObservationForUnknownRoute(String)
}

struct R12ExactScaleFactorV2: Hashable, Sendable, CustomStringConvertible {
    let numerator: Int64
    let denominator: Int64

    init(numerator: Int64, denominator: Int64) throws {
        guard numerator > 0, denominator > 0 else {
            throw R12RouteResolverErrorV2.invalidScaleFactor(
                numerator: numerator,
                denominator: denominator
            )
        }
        let divisor = Self.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    var description: String {
        "\(numerator)/\(denominator)"
    }

    static func derive(
        source: R12ResolutionV2,
        target: R12ResolutionV2
    ) throws -> R12ExactScaleFactorV2 {
        guard let sourceWidth = Int64(exactly: source.width),
              let sourceHeight = Int64(exactly: source.height),
              let targetWidth = Int64(exactly: target.width),
              let targetHeight = Int64(exactly: target.height) else {
            throw R12RouteResolverErrorV2.resolutionOutOfRange(
                role: "source_or_target",
                width: target.width,
                height: target.height
            )
        }
        let widthScale = try R12ExactScaleFactorV2(
            numerator: targetWidth,
            denominator: sourceWidth
        )
        let heightScale = try R12ExactScaleFactorV2(
            numerator: targetHeight,
            denominator: sourceHeight
        )
        guard widthScale == heightScale else {
            throw R12RouteResolverErrorV2.nonUniformScale(
                widthNumerator: widthScale.numerator,
                widthDenominator: widthScale.denominator,
                heightNumerator: heightScale.numerator,
                heightDenominator: heightScale.denominator
            )
        }
        return widthScale
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return first
    }
}

enum R12RouteExecutionRequirementV2: String, Hashable, Sendable {
    case deterministicContract = "deterministic_contract"
    case nativeObserved = "native_observed"
}

enum R12RouteSelectionAuthorityV2: String, Hashable, Sendable {
    case softwareFunctionOnly = "software_function_only"
}

struct R12HardwareTierIdentityV2: Hashable, Sendable {
    static let deterministicFixture = makeStatic("deterministic_fixture")
    static let appleSiliconNative = makeStatic("apple_silicon_native")

    let rawValue: String

    init(_ rawValue: String) throws {
        self.rawValue = try R12RouteResolverValidationV2.identity(
            rawValue,
            field: "hardware_tier_id"
        )
    }

    private static func makeStatic(_ value: String) -> R12HardwareTierIdentityV2 {
        do {
            return try R12HardwareTierIdentityV2(value)
        } catch {
            preconditionFailure("Invalid static R12 hardware tier: \(error)")
        }
    }
}

struct R12HostIdentityV2: Hashable, Sendable {
    let hostID: String
    let modelIdentifier: String
    let chipIdentity: String

    init(
        hostID: String,
        modelIdentifier: String,
        chipIdentity: String
    ) throws {
        self.hostID = try R12RouteResolverValidationV2.identity(
            hostID,
            field: "host_id"
        )
        self.modelIdentifier = try R12RouteResolverValidationV2.identity(
            modelIdentifier,
            field: "model_identifier"
        )
        self.chipIdentity = try R12RouteResolverValidationV2.identity(
            chipIdentity,
            field: "chip_identity"
        )
    }
}

enum R12HardwareExecutionContextV2: Hashable, Sendable {
    case deterministicFixture
    case nativeHost(R12HostIdentityV2)
}

struct R12HardwareCapabilityProfileV2: Hashable, Sendable {
    let profileID: String
    let tierIdentity: R12HardwareTierIdentityV2
    let executionContext: R12HardwareExecutionContextV2
    let availableRouteIDs: [String]

    init(
        profileID: String,
        tierIdentity: R12HardwareTierIdentityV2,
        executionContext: R12HardwareExecutionContextV2,
        availableRouteIDs: [String]
    ) throws {
        var routeIDs: Set<String> = []
        for routeID in availableRouteIDs {
            let validated = try R12RouteResolverValidationV2.identity(
                routeID,
                field: "available_route_id"
            )
            guard routeIDs.insert(validated).inserted else {
                throw R12RouteResolverErrorV2.duplicateHardwareRoute(validated)
            }
        }
        self.profileID = try R12RouteResolverValidationV2.identity(
            profileID,
            field: "hardware_profile_id"
        )
        self.tierIdentity = tierIdentity
        self.executionContext = executionContext
        self.availableRouteIDs = routeIDs.sorted()
    }

    func declaresAvailable(routeID: String) -> Bool {
        availableRouteIDs.contains(routeID)
    }
}

struct R12RouteFormatTransitionV2: Sendable {
    let input: R12MediaFormatContractV2
    let output: R12MediaFormatContractV2

    var inputContractSHA256: String {
        input.canonicalSHA256
    }

    var outputContractSHA256: String {
        output.canonicalSHA256
    }

    var stableIdentity: String {
        "\(inputContractSHA256)->\(outputContractSHA256)"
    }

    func matches(
        input candidateInput: R12MediaFormatContractV2,
        output candidateOutput: R12MediaFormatContractV2
    ) -> Bool {
        inputContractSHA256 == candidateInput.canonicalSHA256
            && outputContractSHA256 == candidateOutput.canonicalSHA256
    }
}

struct R12RouteCapabilityV2: Sendable {
    let routeID: String
    let preferenceOrdinal: Int
    let backendCapability: R12BackendFormatCapabilityV2
    let supportedScaleFactors: [R12ExactScaleFactorV2]
    let formatTransitions: [R12RouteFormatTransitionV2]
    let executionRequirement: R12RouteExecutionRequirementV2
    let nativeObservationSHA256: String?

    init(
        routeID: String,
        preferenceOrdinal: Int,
        backendCapability: R12BackendFormatCapabilityV2,
        supportedScaleFactors: [R12ExactScaleFactorV2],
        formatTransitions: [R12RouteFormatTransitionV2],
        executionRequirement: R12RouteExecutionRequirementV2
    ) throws {
        let routeID = try R12RouteResolverValidationV2.identity(
            routeID,
            field: "route_id"
        )
        guard preferenceOrdinal >= 0 else {
            throw R12RouteResolverErrorV2.invalidPreferenceOrdinal(
                routeID: routeID,
                ordinal: preferenceOrdinal
            )
        }
        guard !supportedScaleFactors.isEmpty else {
            throw R12RouteResolverErrorV2.emptyScaleFactors(routeID: routeID)
        }
        var scaleFactors: Set<R12ExactScaleFactorV2> = []
        for scaleFactor in supportedScaleFactors {
            guard scaleFactors.insert(scaleFactor).inserted else {
                throw R12RouteResolverErrorV2.duplicateScaleFactor(
                    routeID: routeID,
                    numerator: scaleFactor.numerator,
                    denominator: scaleFactor.denominator
                )
            }
        }
        guard !formatTransitions.isEmpty else {
            throw R12RouteResolverErrorV2.emptyFormatTransitions(routeID: routeID)
        }
        var transitionIDs: Set<String> = []
        for transition in formatTransitions {
            guard transitionIDs.insert(transition.stableIdentity).inserted else {
                throw R12RouteResolverErrorV2.duplicateFormatTransition(
                    routeID: routeID
                )
            }
            for contract in [transition.input, transition.output]
            where !backendCapability.supports(contract) {
                throw R12RouteResolverErrorV2.backendFormatMismatch(
                    routeID: routeID,
                    contractSHA256: contract.canonicalSHA256
                )
            }
        }
        let nativeObservationSHA256: String?
        if executionRequirement == .nativeObserved {
            guard backendCapability.evidence.basis == .nativeObserved,
                  formatTransitions.allSatisfy({
                      $0.input.evidence.basis == .nativeObserved
                          && $0.output.evidence.basis == .nativeObserved
                  }) else {
                throw R12RouteResolverErrorV2.nativeRouteRequiresNativeEvidence(
                    routeID: routeID
                )
            }
            let evidenceHashes = [backendCapability.evidence.nativeObservationSHA256]
                + formatTransitions.flatMap {
                    [
                        $0.input.evidence.nativeObservationSHA256,
                        $0.output.evidence.nativeObservationSHA256
                    ]
                }
            guard let firstEvidenceHash = evidenceHashes.compactMap({ $0 }).first,
                  evidenceHashes.allSatisfy({ $0 == firstEvidenceHash }) else {
                throw R12RouteResolverErrorV2.nativeEvidenceMismatch(
                    routeID: routeID
                )
            }
            nativeObservationSHA256 = firstEvidenceHash
        } else {
            nativeObservationSHA256 = nil
        }
        self.routeID = routeID
        self.preferenceOrdinal = preferenceOrdinal
        self.backendCapability = backendCapability
        self.supportedScaleFactors = scaleFactors.sorted {
            if $0.numerator != $1.numerator {
                return $0.numerator < $1.numerator
            }
            return $0.denominator < $1.denominator
        }
        self.formatTransitions = formatTransitions.sorted {
            $0.stableIdentity < $1.stableIdentity
        }
        self.executionRequirement = executionRequirement
        self.nativeObservationSHA256 = nativeObservationSHA256
    }

    func supports(
        scaleFactor: R12ExactScaleFactorV2,
        input: R12MediaFormatContractV2,
        output: R12MediaFormatContractV2
    ) -> Bool {
        supportedScaleFactors.contains(scaleFactor)
            && formatTransitions.contains { $0.matches(input: input, output: output) }
    }
}

struct R12RouteRequestV2: Sendable {
    let sourceResolution: R12ResolutionV2
    let targetResolution: R12ResolutionV2
    let inputFormat: R12MediaFormatContractV2
    let outputFormat: R12MediaFormatContractV2
    let hardwareProfile: R12HardwareCapabilityProfileV2
    let scaleFactor: R12ExactScaleFactorV2

    init(
        sourceResolution: R12ResolutionV2,
        targetResolution: R12ResolutionV2,
        inputFormat: R12MediaFormatContractV2,
        outputFormat: R12MediaFormatContractV2,
        hardwareProfile: R12HardwareCapabilityProfileV2
    ) throws {
        try inputFormat.format.validate(resolution: sourceResolution)
        try outputFormat.format.validate(resolution: targetResolution)
        self.sourceResolution = sourceResolution
        self.targetResolution = targetResolution
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.hardwareProfile = hardwareProfile
        self.scaleFactor = try R12ExactScaleFactorV2.derive(
            source: sourceResolution,
            target: targetResolution
        )
    }
}

struct R12NativeRouteObservationV2: Hashable, Sendable {
    let receiptID: String
    let receiptSHA256: String
    let hostIdentity: R12HostIdentityV2
    let hardwareProfileID: String
    let hardwareTierIdentity: R12HardwareTierIdentityV2
    let routeID: String
    let backendID: String
    let scaleFactor: R12ExactScaleFactorV2
    let inputContractSHA256: String
    let outputContractSHA256: String

    init(
        receiptID: String,
        receiptSHA256: String,
        hostIdentity: R12HostIdentityV2,
        hardwareProfileID: String,
        hardwareTierIdentity: R12HardwareTierIdentityV2,
        routeID: String,
        backendID: String,
        scaleFactor: R12ExactScaleFactorV2,
        inputContractSHA256: String,
        outputContractSHA256: String
    ) throws {
        self.receiptID = try R12RouteResolverValidationV2.identity(
            receiptID,
            field: "receipt_id"
        )
        self.receiptSHA256 = try R12RouteResolverValidationV2.sha256(
            receiptSHA256,
            field: "receipt_sha256"
        )
        self.hostIdentity = hostIdentity
        self.hardwareProfileID = try R12RouteResolverValidationV2.identity(
            hardwareProfileID,
            field: "observation_hardware_profile_id"
        )
        self.hardwareTierIdentity = hardwareTierIdentity
        self.routeID = try R12RouteResolverValidationV2.identity(
            routeID,
            field: "observation_route_id"
        )
        self.backendID = try R12RouteResolverValidationV2.identity(
            backendID,
            field: "observation_backend_id"
        )
        self.scaleFactor = scaleFactor
        self.inputContractSHA256 = try R12RouteResolverValidationV2.sha256(
            inputContractSHA256,
            field: "observation_input_contract_sha256"
        )
        self.outputContractSHA256 = try R12RouteResolverValidationV2.sha256(
            outputContractSHA256,
            field: "observation_output_contract_sha256"
        )
    }
}

enum R12RouteAttemptDispositionV2: String, Hashable, Sendable {
    case rejected
    case selected
}

enum R12RouteRejectionReasonV2: String, Hashable, Sendable {
    case hardwareProfileDoesNotDeclareRoute = "hardware_profile_does_not_declare_route"
    case formatTransitionUnsupported = "format_transition_unsupported"
    case exactScaleUnsupported = "exact_scale_unsupported"
    case fixtureCannotAuthorizeNative = "fixture_cannot_authorize_native"
    case nativeObservationMissing = "native_observation_missing"
    case nativeObservationMismatch = "native_observation_mismatch"
}

struct R12RouteFallbackRecordV2: Hashable, Sendable {
    let attemptOrdinal: Int
    let routeID: String
    let backendID: String
    let disposition: R12RouteAttemptDispositionV2
    let rejectionReason: R12RouteRejectionReasonV2?
}

enum R12RouteSelectionEvidenceV2: Hashable, Sendable {
    case deterministicContract
    case nativeObserved(R12NativeRouteObservationV2)
}

struct R12ResolvedRouteV2: Hashable, Sendable {
    let routeID: String
    let backendID: String
    let scaleFactor: R12ExactScaleFactorV2
    let inputContractSHA256: String
    let outputContractSHA256: String
    let hardwareProfileID: String
    let hardwareTierIdentity: R12HardwareTierIdentityV2
    let evidence: R12RouteSelectionEvidenceV2
    let authority = R12RouteSelectionAuthorityV2.softwareFunctionOnly
}

struct R12RouteResolutionV2: Hashable, Sendable {
    let selectedRoute: R12ResolvedRouteV2?
    let fallbackRecords: [R12RouteFallbackRecordV2]
    let authority = R12RouteSelectionAuthorityV2.softwareFunctionOnly

    var isAvailable: Bool {
        selectedRoute != nil
    }
}

enum R12RouteAndHardwareResolverV2 {
    static func resolve(
        request: R12RouteRequestV2,
        candidates: [R12RouteCapabilityV2],
        nativeObservations: [R12NativeRouteObservationV2] = []
    ) throws -> R12RouteResolutionV2 {
        let candidateIndex = try validateCandidates(candidates)
        let observationIndex = try validateObservations(
            nativeObservations,
            candidates: candidateIndex
        )
        let orderedCandidates = candidates.sorted {
            if $0.preferenceOrdinal != $1.preferenceOrdinal {
                return $0.preferenceOrdinal < $1.preferenceOrdinal
            }
            if $0.routeID != $1.routeID {
                return $0.routeID < $1.routeID
            }
            return $0.backendCapability.backendID < $1.backendCapability.backendID
        }

        var records: [R12RouteFallbackRecordV2] = []
        for candidate in orderedCandidates {
            if let rejection = rejectionReason(
                candidate: candidate,
                request: request,
                observation: observationIndex[candidate.routeID]
            ) {
                records.append(
                    record(
                        candidate: candidate,
                        ordinal: records.count,
                        rejection: rejection
                    )
                )
                continue
            }

            let evidence: R12RouteSelectionEvidenceV2
            switch candidate.executionRequirement {
            case .deterministicContract:
                evidence = .deterministicContract
            case .nativeObserved:
                guard let observation = observationIndex[candidate.routeID] else {
                    preconditionFailure("Native observation was validated before selection")
                }
                evidence = .nativeObserved(observation)
            }
            let selected = R12ResolvedRouteV2(
                routeID: candidate.routeID,
                backendID: candidate.backendCapability.backendID,
                scaleFactor: request.scaleFactor,
                inputContractSHA256: request.inputFormat.canonicalSHA256,
                outputContractSHA256: request.outputFormat.canonicalSHA256,
                hardwareProfileID: request.hardwareProfile.profileID,
                hardwareTierIdentity: request.hardwareProfile.tierIdentity,
                evidence: evidence
            )
            records.append(
                R12RouteFallbackRecordV2(
                    attemptOrdinal: records.count,
                    routeID: candidate.routeID,
                    backendID: candidate.backendCapability.backendID,
                    disposition: .selected,
                    rejectionReason: nil
                )
            )
            return R12RouteResolutionV2(
                selectedRoute: selected,
                fallbackRecords: records
            )
        }
        return R12RouteResolutionV2(
            selectedRoute: nil,
            fallbackRecords: records
        )
    }

    private static func rejectionReason(
        candidate: R12RouteCapabilityV2,
        request: R12RouteRequestV2,
        observation: R12NativeRouteObservationV2?
    ) -> R12RouteRejectionReasonV2? {
        guard request.hardwareProfile.declaresAvailable(routeID: candidate.routeID) else {
            return .hardwareProfileDoesNotDeclareRoute
        }
        guard candidate.formatTransitions.contains(where: {
            $0.matches(input: request.inputFormat, output: request.outputFormat)
        }) else {
            return .formatTransitionUnsupported
        }
        guard candidate.supportedScaleFactors.contains(request.scaleFactor) else {
            return .exactScaleUnsupported
        }
        guard candidate.executionRequirement == .nativeObserved else {
            return nil
        }
        guard case .nativeHost(let expectedHost) =
            request.hardwareProfile.executionContext else {
            return .fixtureCannotAuthorizeNative
        }
        guard let observation else {
            return .nativeObservationMissing
        }
        guard observation.hostIdentity == expectedHost,
              observation.hardwareProfileID == request.hardwareProfile.profileID,
              observation.hardwareTierIdentity == request.hardwareProfile.tierIdentity,
              observation.routeID == candidate.routeID,
              observation.backendID == candidate.backendCapability.backendID,
              observation.receiptSHA256 == candidate.nativeObservationSHA256,
              observation.scaleFactor == request.scaleFactor,
              observation.inputContractSHA256 == request.inputFormat.canonicalSHA256,
              observation.outputContractSHA256 == request.outputFormat.canonicalSHA256 else {
            return .nativeObservationMismatch
        }
        return nil
    }

    private static func record(
        candidate: R12RouteCapabilityV2,
        ordinal: Int,
        rejection: R12RouteRejectionReasonV2
    ) -> R12RouteFallbackRecordV2 {
        R12RouteFallbackRecordV2(
            attemptOrdinal: ordinal,
            routeID: candidate.routeID,
            backendID: candidate.backendCapability.backendID,
            disposition: .rejected,
            rejectionReason: rejection
        )
    }

    private static func validateCandidates(
        _ candidates: [R12RouteCapabilityV2]
    ) throws -> [String: R12RouteCapabilityV2] {
        var index: [String: R12RouteCapabilityV2] = [:]
        for candidate in candidates {
            guard index.updateValue(candidate, forKey: candidate.routeID) == nil else {
                throw R12RouteResolverErrorV2.duplicateCandidateRoute(
                    candidate.routeID
                )
            }
        }
        return index
    }

    private static func validateObservations(
        _ observations: [R12NativeRouteObservationV2],
        candidates: [String: R12RouteCapabilityV2]
    ) throws -> [String: R12NativeRouteObservationV2] {
        var index: [String: R12NativeRouteObservationV2] = [:]
        for observation in observations {
            guard let candidate = candidates[observation.routeID] else {
                throw R12RouteResolverErrorV2.nativeObservationForUnknownRoute(
                    observation.routeID
                )
            }
            guard candidate.executionRequirement == .nativeObserved else {
                throw R12RouteResolverErrorV2
                    .nativeObservationForDeterministicRoute(observation.routeID)
            }
            guard index.updateValue(observation, forKey: observation.routeID) == nil else {
                throw R12RouteResolverErrorV2.duplicateNativeObservation(
                    observation.routeID
                )
            }
        }
        return index
    }
}

private enum R12RouteResolverValidationV2 {
    static func identity(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else {
            throw R12RouteResolverErrorV2.invalidIdentity(field: field)
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(Int(byte)) || (97...102).contains(Int(byte))
              }) else {
            throw R12RouteResolverErrorV2.invalidSHA256(field: field)
        }
        return value
    }
}
