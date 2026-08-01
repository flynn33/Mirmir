import CoreMedia
import CryptoKit
import Foundation

enum R13ProductBackendPrimaryFamily: String, Hashable, Sendable {
    case spatial
    case temporal
}

struct R13ProductBackendProfile: Hashable, Sendable {
    let primaryFamily: R13ProductBackendPrimaryFamily
    let qualityPreferred: Bool
    let fastPreferred: Bool
    let qualityConfidenceQ16: Int64
    let artifactRiskQ16: Int64
    let transitionCostQ16: Int64
    let resourceCostQ16: Int64

    static let videoToolboxQuality = R13ProductBackendProfile(
        primaryFamily: .temporal,
        qualityPreferred: true,
        fastPreferred: false,
        qualityConfidenceQ16: 65_536,
        artifactRiskQ16: 4_096,
        transitionCostQ16: 16_384,
        resourceCostQ16: 40_960
    )

    static let videoToolboxLowLatency = R13ProductBackendProfile(
        primaryFamily: .temporal,
        qualityPreferred: false,
        fastPreferred: true,
        qualityConfidenceQ16: 57_344,
        artifactRiskQ16: 8_192,
        transitionCostQ16: 8_192,
        resourceCostQ16: 12_288
    )

    static let metalFXSpatial = R13ProductBackendProfile(
        primaryFamily: .spatial,
        qualityPreferred: false,
        fastPreferred: true,
        qualityConfidenceQ16: 55_296,
        artifactRiskQ16: 8_192,
        transitionCostQ16: 8_192,
        resourceCostQ16: 12_288
    )

    static let vImageHighQuality = R13ProductBackendProfile(
        primaryFamily: .spatial,
        qualityPreferred: true,
        fastPreferred: false,
        qualityConfidenceQ16: 53_248,
        artifactRiskQ16: 4_096,
        transitionCostQ16: 4_096,
        resourceCostQ16: 28_672
    )

    static let mpsLanczos = R13ProductBackendProfile(
        primaryFamily: .spatial,
        qualityPreferred: true,
        fastPreferred: false,
        qualityConfidenceQ16: 51_200,
        artifactRiskQ16: 8_192,
        transitionCostQ16: 4_096,
        resourceCostQ16: 20_480
    )

    static let mpsBilinear = R13ProductBackendProfile(
        primaryFamily: .spatial,
        qualityPreferred: false,
        fastPreferred: true,
        qualityConfidenceQ16: 36_864,
        artifactRiskQ16: 12_288,
        transitionCostQ16: 2_048,
        resourceCostQ16: 4_096
    )

    func ashCandidate(
        routeIdentity: AppleUpscaleRouteIdentity,
        context: ASHDecisionContext,
        orchestrationKind: R13ReleaseOrchestrationKind
    ) throws -> R06ASHBackendFixture {
        let policy = R06ASHPolicyCatalog.profile(
            for: context.message
        )
        let alignment: Int64
        switch orchestrationKind {
        case .none:
            alignment = R06ASHQ16.scale
        case .automatic:
            let policyFamily: R13ProductBackendPrimaryFamily =
                policy.primaryBackendPreference == .temporal
                    ? .temporal
                    : .spatial
            alignment = policyFamily == primaryFamily
                ? R06ASHQ16.scale
                : R06ASHQ16.scale / 2
        case .quality:
            alignment = qualityPreferred
                ? R06ASHQ16.scale
                : R06ASHQ16.scale / 2
        case .fast:
            alignment = fastPreferred
                ? R06ASHQ16.scale
                : R06ASHQ16.scale / 4
        }
        let pressure = max(
            context.memoryPressureQ16.rawValue,
            context.thermalPressureQ16.rawValue,
            context.throughputPressureQ16.rawValue
        )
        let dynamicResourceCost = Self.clampedQ16(
            resourceCostQ16 + pressure / 2
        )
        let dynamicArtifactRisk = Self.clampedQ16(
            artifactRiskQ16 + context.artifactRiskQ16.rawValue / 4
        )
        return try R06ASHBackendFixture(
            backendID: routeIdentity.backend.backendID,
            routeID: routeIdentity.configurationIdentity,
            fixtureEligible: false,
            productQualified: true,
            wholeFrameOnly: true,
            scoreComponents: R06ASHScoreComponents(
                qualityConfidenceQ16: qualityConfidenceQ16,
                messageAlignmentQ16: alignment,
                artifactRiskQ16: dynamicArtifactRisk,
                transitionCostQ16: transitionCostQ16,
                resourceCostQ16: dynamicResourceCost,
                postflightPenaltyQ16: 0
            )
        )
    }

    private static func clampedQ16(_ value: Int64) -> Int64 {
        min(max(value, 0), R06ASHQ16.scale)
    }
}

struct R13ProductBackendSessionCandidate: Sendable {
    let session: any AppleUpscaleSession
    let routeIdentity: AppleUpscaleRouteIdentity
    let profile: R13ProductBackendProfile
}

enum R13ProductASHSelectedModelStatus:
    String,
    Codable,
    Hashable,
    Sendable {
    case notRequired = "not_required"
    case appleConfigurationManagedReady =
        "apple_configuration_managed_ready"
    case artifactBound = "artifact_bound"

    init(
        modelAssetsIdentity: AppleUpscaleModelAssetsIdentity
    ) {
        switch modelAssetsIdentity {
        case .notRequired:
            self = .notRequired
        case .appleConfigurationManaged(_, .ready):
            self = .appleConfigurationManagedReady
        case .bound:
            self = .artifactBound
        }
    }
}

struct R13ProductASHDecisionEvent: Equatable, Sendable {
    let sequenceNumber: Int
    let selectedRouteIdentity: AppleUpscaleRouteIdentity
    let reason: R06ASHTransitionReason
    let fallbackHistory: [AppleUpscaleFallbackLink]
    let processingPressureQ16: Int64

    init(
        sequenceNumber: Int,
        selectedRouteIdentity: AppleUpscaleRouteIdentity,
        reason: R06ASHTransitionReason,
        fallbackHistory: [AppleUpscaleFallbackLink],
        processingPressureQ16: Int64 = 0
    ) {
        self.sequenceNumber = sequenceNumber
        self.selectedRouteIdentity = selectedRouteIdentity
        self.reason = reason
        self.fallbackHistory = fallbackHistory
        self.processingPressureQ16 = processingPressureQ16
    }

    var failedBackendIDs: [String] {
        fallbackHistory.map { $0.failedRoute.backend.backendID }
    }

    var selectedBackendID: String {
        selectedRouteIdentity.backend.backendID
    }

    var selectedConfigurationIdentity: String {
        selectedRouteIdentity.configurationIdentity
    }

    var selectedModelStatus:
        R13ProductASHSelectedModelStatus {
        R13ProductASHSelectedModelStatus(
            modelAssetsIdentity:
                selectedRouteIdentity.backend
                    .modelAssetsIdentity
        )
    }
}

struct R13ProductASHRoutingArtifactEvidence:
    Codable,
    Equatable,
    Sendable {
    let identifier: String
    let sha256: String

    init(_ artifact: AppleUpscaleArtifactIdentity) {
        identifier = artifact.identifier
        sha256 = artifact.sha256
    }

    func appleIdentity() throws -> AppleUpscaleArtifactIdentity {
        try AppleUpscaleArtifactIdentity(
            identifier: identifier,
            sha256: sha256
        )
    }
}

struct R13ProductASHRoutingRouteEvidence:
    Codable,
    Equatable,
    Sendable {
    let backendID: String
    let backendRevision: String
    let configurationIdentity: String
    let policyIdentity: String
    let materialDecisionIdentity: String
    let modelStatus: R13ProductASHSelectedModelStatus
    let modelConfigurationIdentity: String?
    let modelArtifacts: [R13ProductASHRoutingArtifactEvidence]

    init(_ route: AppleUpscaleRouteIdentity) {
        backendID = route.backend.backendID
        backendRevision = route.backend.backendRevision
        configurationIdentity = route.configurationIdentity
        policyIdentity = route.policyIdentity
        materialDecisionIdentity = route.materialDecisionIdentity
        modelStatus = R13ProductASHSelectedModelStatus(
            modelAssetsIdentity: route.backend.modelAssetsIdentity
        )
        switch route.backend.modelAssetsIdentity {
        case .notRequired:
            modelConfigurationIdentity = nil
            modelArtifacts = []
        case .appleConfigurationManaged(
            let configurationIdentity,
            .ready
        ):
            modelConfigurationIdentity = configurationIdentity
            modelArtifacts = []
        case .bound(let artifacts):
            modelConfigurationIdentity = nil
            modelArtifacts = artifacts.map(
                R13ProductASHRoutingArtifactEvidence.init
            )
        }
    }

    func appleIdentity() throws -> AppleUpscaleRouteIdentity {
        let modelAssetsIdentity: AppleUpscaleModelAssetsIdentity
        switch modelStatus {
        case .notRequired:
            guard modelConfigurationIdentity == nil,
                  modelArtifacts.isEmpty else {
                throw R13ProductASHDecisionMetadataError
                    .invalidRouteEvidence(backendID)
            }
            modelAssetsIdentity = .notRequired
        case .appleConfigurationManagedReady:
            guard let modelConfigurationIdentity,
                  modelArtifacts.isEmpty else {
                throw R13ProductASHDecisionMetadataError
                    .invalidRouteEvidence(backendID)
            }
            modelAssetsIdentity = .appleConfigurationManaged(
                configurationIdentity: modelConfigurationIdentity,
                readiness: .ready
            )
        case .artifactBound:
            guard modelConfigurationIdentity == nil,
                  !modelArtifacts.isEmpty else {
                throw R13ProductASHDecisionMetadataError
                    .invalidRouteEvidence(backendID)
            }
            modelAssetsIdentity = .bound(
                try modelArtifacts.map { try $0.appleIdentity() }
            )
        }
        return try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: backendID,
                backendRevision: backendRevision,
                modelAssetsIdentity: modelAssetsIdentity
            ),
            configurationIdentity: configurationIdentity,
            policyIdentity: policyIdentity,
            materialDecisionIdentity: materialDecisionIdentity
        )
    }

    private enum CodingKeys: String, CodingKey {
        case backendID = "backend_id"
        case backendRevision = "backend_revision"
        case configurationIdentity = "configuration_identity"
        case policyIdentity = "policy_identity"
        case materialDecisionIdentity = "material_decision_identity"
        case modelStatus = "model_status"
        case modelConfigurationIdentity =
            "model_configuration_identity"
        case modelArtifacts = "model_artifacts"
    }
}

struct R13ProductASHFallbackEventEvidence:
    Codable,
    Equatable,
    Sendable {
    let sequenceNumber: Int
    let selectedFallbackOrdinal: Int
    let reason: String
    let failedRoute: R13ProductASHRoutingRouteEvidence
    let selectedRoute: R13ProductASHRoutingRouteEvidence

    init(
        sequenceNumber: Int,
        link: AppleUpscaleFallbackLink
    ) {
        self.sequenceNumber = sequenceNumber
        selectedFallbackOrdinal = link.selectedFallbackOrdinal
        reason = link.reasonCode.rawValue
        failedRoute = R13ProductASHRoutingRouteEvidence(
            link.failedRoute
        )
        selectedRoute = R13ProductASHRoutingRouteEvidence(
            link.selectedRoute
        )
    }

    func appleLink() throws -> AppleUpscaleFallbackLink {
        guard sequenceNumber >= 0,
              let reasonCode = AppleUpscaleFallbackReasonCode(
                  rawValue: reason
              ) else {
            throw R13ProductASHDecisionMetadataError
                .invalidFallbackHistory(
                    sequenceNumber: sequenceNumber
                )
        }
        return try AppleUpscaleFallbackLink(
            failedRoute: failedRoute.appleIdentity(),
            selectedRoute: selectedRoute.appleIdentity(),
            reasonCode: reasonCode,
            selectedFallbackOrdinal: selectedFallbackOrdinal
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sequenceNumber = "sequence_number"
        case selectedFallbackOrdinal = "selected_fallback_ordinal"
        case reason
        case failedRoute = "failed_route"
        case selectedRoute = "selected_route"
    }
}

enum R13ProductASHResumeBoundaryKind:
    String,
    Codable,
    Equatable,
    Sendable {
    case oneFrameSelectedCandidateWarmup =
        "one_frame_selected_candidate_warmup"
    case fullCacheNoBackendWarmup =
        "full_cache_no_backend_warmup"
    case statelessScalerStateRestored =
        "stateless_scaler_state_restored"
}

struct R13ProductASHResumeBoundary:
    Codable,
    Equatable,
    Sendable {
    let sequenceNumber: Int
    let kind: R13ProductASHResumeBoundaryKind
    let restoredHistoryFrameCount: Int

    init(
        sequenceNumber: Int,
        kind: R13ProductASHResumeBoundaryKind
    ) {
        self.sequenceNumber = sequenceNumber
        self.kind = kind
        restoredHistoryFrameCount =
            kind == .oneFrameSelectedCandidateWarmup
            ? 1
            : 0
    }
}

struct R13ProductASHDecisionSummary: Equatable, Sendable {
    let events: [R13ProductASHDecisionEvent]
    let candidateExclusions:
        [R13ProductASHScalingCandidateExclusion]
    let resumeBoundaries: [R13ProductASHResumeBoundary]

    init(
        events: [R13ProductASHDecisionEvent],
        candidateExclusions:
            [R13ProductASHScalingCandidateExclusion] = [],
        resumeBoundaries:
            [R13ProductASHResumeBoundary] = []
    ) {
        self.events = events
        self.candidateExclusions = candidateExclusions
        self.resumeBoundaries = resumeBoundaries
    }

    var selectedBackendIDs: [String] {
        var observed: Set<String> = []
        return events.compactMap { event in
            observed.insert(event.selectedBackendID).inserted
                ? event.selectedBackendID
                : nil
        }
    }

    var selectedModelStatuses:
        [R13ProductASHSelectedModelStatus] {
        Array(Set(events.map(\.selectedModelStatus)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    var fallbackCount: Int {
        events.reduce(0) { $0 + $1.failedBackendIDs.count }
    }

    var transitionCount: Int {
        zip(events, events.dropFirst()).reduce(0) { count, pair in
            count + (pair.0.selectedBackendID
                == pair.1.selectedBackendID ? 0 : 1)
        }
    }

    func outputMetadata() throws
        -> R13ProductASHDecisionMetadata {
        try R13ProductASHDecisionMetadata(summary: self)
    }
}

enum R13ProductASHDecisionMetadataError: Error, Equatable, Sendable {
    case emptyDecisionJournal
    case invalidSequenceNumber(Int)
    case nonMonotonicSequence(previous: Int, current: Int)
    case invalidFallbackHistory(sequenceNumber: Int)
    case invalidRouteEvidence(String)
    case repeatedFallbackRoute(String)
    case invalidResumeBoundary(sequenceNumber: Int)
    case evidenceEncodingFailed
}

struct R13ProductASHDecisionMetadata: Equatable, Sendable {
    static let statusKey =
        "com.mirmir.release.routing-status"
    static let decisionCountKey =
        "com.mirmir.release.routing-decision-count"
    static let transitionCountKey =
        "com.mirmir.release.routing-transition-count"
    static let fallbackCountKey =
        "com.mirmir.release.routing-fallback-count"
    static let fallbackEventsKey =
        "com.mirmir.release.routing-fallback-events"
    static let selectedBackendsKey =
        "com.mirmir.release.routing-selected-backends"
    static let selectedModelStatusesKey =
        "com.mirmir.release.routing-selected-model-statuses"
    static let modelStatusKey =
        "com.mirmir.release.model-status"
    static let journalSHA256Key =
        "com.mirmir.release.routing-journal-sha256"
    static let candidateExclusionCountKey =
        "com.mirmir.release.routing-candidate-exclusion-count"
    static let candidateExclusionsKey =
        "com.mirmir.release.routing-candidate-exclusions"
    static let resumeBoundaryCountKey =
        "com.mirmir.release.routing-resume-boundary-count"
    static let resumeBoundariesKey =
        "com.mirmir.release.routing-resume-boundaries"

    static let pendingValues: [String: String] = [
        statusKey: "pending",
        decisionCountKey: "0",
        transitionCountKey: "0",
        fallbackCountKey: "0",
        fallbackEventsKey: "[]",
        selectedBackendsKey: "pending",
        selectedModelStatusesKey: "pending",
        modelStatusKey: "pending",
        candidateExclusionCountKey: "0",
        candidateExclusionsKey: "[]",
        resumeBoundaryCountKey: "0",
        resumeBoundariesKey: "[]",
        journalSHA256Key: String(repeating: "0", count: 64)
    ]

    let decisionCount: Int
    let transitionCount: Int
    let fallbackCount: Int
    let fallbackEvents: [R13ProductASHFallbackEventEvidence]
    let fallbackEventsJSON: String
    let selectedBackendIDs: [String]
    let selectedModelStatuses:
        [R13ProductASHSelectedModelStatus]
    let modelStatus: String
    let candidateExclusionCount: Int
    let candidateExclusionsJSON: String
    let resumeBoundaryCount: Int
    let resumeBoundariesJSON: String
    let journalSHA256: String

    static func canonicalResumeBoundariesJSON(
        _ boundaries: [R13ProductASHResumeBoundary]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(boundaries)
        guard let value = String(
            data: data,
            encoding: .utf8
        ) else {
            throw R13ProductASHDecisionMetadataError
                .evidenceEncodingFailed
        }
        return value
    }

    static func canonicalFallbackEventsJSON(
        _ events: [R13ProductASHFallbackEventEvidence]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(events)
        guard let value = String(data: data, encoding: .utf8) else {
            throw R13ProductASHDecisionMetadataError
                .evidenceEncodingFailed
        }
        return value
    }

    init(summary: R13ProductASHDecisionSummary) throws {
        guard !summary.events.isEmpty else {
            throw R13ProductASHDecisionMetadataError
                .emptyDecisionJournal
        }
        guard summary.events.allSatisfy({
            $0.sequenceNumber >= 0
        }) else {
            throw R13ProductASHDecisionMetadataError
                .invalidSequenceNumber(
                    summary.events.first(where: {
                        $0.sequenceNumber < 0
                    })?.sequenceNumber ?? -1
                )
        }
        for pair in zip(
            summary.events,
            summary.events.dropFirst()
        ) where pair.1.sequenceNumber <= pair.0.sequenceNumber {
            throw R13ProductASHDecisionMetadataError
                .nonMonotonicSequence(
                    previous: pair.0.sequenceNumber,
                    current: pair.1.sequenceNumber
                )
        }
        var failedBackendIDs: Set<String> = []
        for event in summary.events {
            do {
                _ = try AppleUpscaleProcessingIdentity(
                    route: event.selectedRouteIdentity,
                    fallbackHistory: event.fallbackHistory
                )
            } catch {
                throw R13ProductASHDecisionMetadataError
                    .invalidFallbackHistory(
                        sequenceNumber: event.sequenceNumber
                    )
            }
            guard (event.reason == .fatalBackendFailover)
                    == !event.fallbackHistory.isEmpty else {
                throw R13ProductASHDecisionMetadataError
                    .invalidFallbackHistory(
                        sequenceNumber: event.sequenceNumber
                    )
            }
            for link in event.fallbackHistory {
                let failedBackendID =
                    link.failedRoute.backend.backendID
                guard failedBackendIDs.insert(
                    failedBackendID
                ).inserted else {
                    throw R13ProductASHDecisionMetadataError
                        .repeatedFallbackRoute(
                            failedBackendID
                        )
                }
            }
        }
        let eventSequenceNumbers = Set(
            summary.events.map(\.sequenceNumber)
        )
        guard summary.resumeBoundaries.allSatisfy({
            eventSequenceNumbers.contains($0.sequenceNumber)
                && $0.restoredHistoryFrameCount
                    == ($0.kind
                        == .oneFrameSelectedCandidateWarmup
                        ? 1
                        : 0)
        }) else {
            throw R13ProductASHDecisionMetadataError
                .invalidResumeBoundary(
                    sequenceNumber:
                        summary.resumeBoundaries.first?
                            .sequenceNumber ?? -1
                )
        }
        decisionCount = summary.events.count
        transitionCount = summary.transitionCount
        fallbackEvents = summary.events.flatMap { event in
            event.fallbackHistory.map {
                R13ProductASHFallbackEventEvidence(
                    sequenceNumber: event.sequenceNumber,
                    link: $0
                )
            }
        }
        fallbackCount = fallbackEvents.count
        selectedBackendIDs = summary.selectedBackendIDs
        selectedModelStatuses = summary.selectedModelStatuses
        modelStatus = selectedModelStatuses.count == 1
            ? selectedModelStatuses[0].rawValue
            : "mixed"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        candidateExclusionCount =
            summary.candidateExclusions.count
        fallbackEventsJSON = try Self
            .canonicalFallbackEventsJSON(fallbackEvents)
        candidateExclusionsJSON =
            try R13ProductASHScalingCandidateExclusionEncoding
                .canonicalJSON(summary.candidateExclusions)
        resumeBoundaryCount = summary.resumeBoundaries.count
        resumeBoundariesJSON = try Self
            .canonicalResumeBoundariesJSON(
            summary.resumeBoundaries
        )
        let payload = JournalPayload(
            candidateExclusions:
                summary.candidateExclusions,
            resumeBoundaries: summary.resumeBoundaries,
            events: summary.events.map {
                JournalEvent(event: $0)
            }
        )
        let data = try encoder.encode(payload)
        journalSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var values: [String: String] {
        [
            Self.statusKey: "complete",
            Self.decisionCountKey: String(decisionCount),
            Self.transitionCountKey: String(transitionCount),
            Self.fallbackCountKey: String(fallbackCount),
            Self.fallbackEventsKey: fallbackEventsJSON,
            Self.selectedBackendsKey:
                selectedBackendIDs.joined(separator: ","),
            Self.selectedModelStatusesKey:
                selectedModelStatuses
                    .map(\.rawValue)
                    .joined(separator: ","),
            Self.modelStatusKey: modelStatus,
            Self.candidateExclusionCountKey:
                String(candidateExclusionCount),
            Self.candidateExclusionsKey:
                candidateExclusionsJSON,
            Self.resumeBoundaryCountKey:
                String(resumeBoundaryCount),
            Self.resumeBoundariesKey:
                resumeBoundariesJSON,
            Self.journalSHA256Key: journalSHA256
        ]
    }

    private struct JournalPayload: Codable {
        let candidateExclusions:
            [R13ProductASHScalingCandidateExclusion]
        let resumeBoundaries:
            [R13ProductASHResumeBoundary]
        let events: [JournalEvent]

        private enum CodingKeys: String, CodingKey {
            case candidateExclusions =
                "candidate_exclusions"
            case resumeBoundaries = "resume_boundaries"
            case events
        }
    }

    private struct JournalEvent: Codable {
        let sequenceNumber: Int
        let selectedBackendID: String
        let selectedBackendRevision: String
        let selectedConfigurationIdentity: String
        let selectedPolicyIdentity: String
        let selectedMaterialDecisionIdentity: String
        let selectedModelStatus: String
        let selectedModelConfigurationIdentity: String?
        let selectedModelArtifacts: [JournalArtifactIdentity]
        let reason: String
        let fallbackHistory:
            [R13ProductASHFallbackEventEvidence]
        let processingPressureQ16: Int64

        init(event: R13ProductASHDecisionEvent) {
            let route = event.selectedRouteIdentity
            sequenceNumber = event.sequenceNumber
            selectedBackendID = route.backend.backendID
            selectedBackendRevision =
                route.backend.backendRevision
            selectedConfigurationIdentity =
                route.configurationIdentity
            selectedPolicyIdentity = route.policyIdentity
            selectedMaterialDecisionIdentity =
                route.materialDecisionIdentity
            selectedModelStatus =
                event.selectedModelStatus.rawValue
            switch route.backend.modelAssetsIdentity {
            case .notRequired:
                selectedModelConfigurationIdentity = nil
                selectedModelArtifacts = []
            case .appleConfigurationManaged(
                let configurationIdentity,
                .ready
            ):
                selectedModelConfigurationIdentity =
                    configurationIdentity
                selectedModelArtifacts = []
            case .bound(let artifacts):
                selectedModelConfigurationIdentity = nil
                selectedModelArtifacts = artifacts.map {
                    JournalArtifactIdentity(
                        identifier: $0.identifier,
                        sha256: $0.sha256
                    )
                }
            }
            reason = event.reason.rawValue
            fallbackHistory = event.fallbackHistory.map {
                R13ProductASHFallbackEventEvidence(
                    sequenceNumber: event.sequenceNumber,
                    link: $0
                )
            }
            processingPressureQ16 =
                event.processingPressureQ16
        }

        private enum CodingKeys: String, CodingKey {
            case sequenceNumber = "sequence_number"
            case selectedBackendID = "selected_backend_id"
            case selectedBackendRevision =
                "selected_backend_revision"
            case selectedConfigurationIdentity =
                "selected_configuration_identity"
            case selectedPolicyIdentity =
                "selected_policy_identity"
            case selectedMaterialDecisionIdentity =
                "selected_material_decision_identity"
            case selectedModelStatus =
                "selected_model_status"
            case selectedModelConfigurationIdentity =
                "selected_model_configuration_identity"
            case selectedModelArtifacts =
                "selected_model_artifacts"
            case reason
            case fallbackHistory = "fallback_history"
            case processingPressureQ16 =
                "processing_pressure_q16"
        }
    }

    private struct JournalArtifactIdentity: Codable {
        let identifier: String
        let sha256: String
    }
}

protocol R13ProductASHDecisionReporting: AppleUpscaleSession {
    func decisionSummary() async -> R13ProductASHDecisionSummary
}

protocol R13ProductASHDecisionReplaying:
    R13ProductASHDecisionReporting {
    func replayCachedDecision(
        _ frame: AppleUpscaleFrame,
        decision: R13ProductASHDecisionEvent,
        isFinalCachedPrefixFrame: Bool,
        requiresBackendWarmup: Bool
    ) async throws
}

enum R13ProductASHRoutingSessionError: Error, Equatable, Sendable {
    case noCandidates
    case duplicateBackendID(String)
    case duplicateRouteIdentity
    case duplicateCandidateExclusion(String)
    case admittedCandidateMarkedExcluded(String)
    case invalidRouterIdentity
    case invalidReplayDecision(sequenceNumber: Int)
    case replayCandidateWarmupFailed(sequenceNumber: Int)
}

actor R13ProductASHRoutingSession:
    R13ProductASHDecisionReplaying {
    nonisolated let identity: AppleUpscaleRouteIdentity

    private let route: R03ScaleRoute
    private let orchestrationKind: R13ReleaseOrchestrationKind
    private let processingConfiguration:
        UpscaleProcessingConfiguration
    private let streamIdentifier: String
    private let candidatesByBackendID:
        [String: R13ProductBackendSessionCandidate]
    private let orderedCandidates:
        [R13ProductBackendSessionCandidate]
    private let candidateExclusions:
        [R13ProductASHScalingCandidateExclusion]
    private let masks: R06ASHMaskSet
    private let modelReadiness: R06ASHModelReadiness
    private let analyzer = R13ProductASHAnalyzer()
    private let orchestrator = R06ASHOrchestrator(
        parameters: .frozen
    )
    private let unavailableOutcome: AppleUpscaleBackendUnavailable
    private let terminalRejection: AppleUpscaleBackendRejected
    private let cancellationRejection: AppleUpscaleBackendRejected
    private let routingFailure: AppleUpscaleBackendFailed

    private var unavailableBackendIDs: Set<String> = []
    private var currentBackendID: String?
    private var previousBackendID: String?
    private var dwellFrames = 0
    private var priorProcessingPressureQ16 = R06ASHQ16.zero
    private var submittedFrameCount = 0
    private var processedFrameCount = 0
    private var terminalizationCount = 0
    private var terminal = false
    private var events: [R13ProductASHDecisionEvent] = []
    private var resumeBoundaries:
        [R13ProductASHResumeBoundary] = []

    init(
        identity: AppleUpscaleRouteIdentity,
        route: R03ScaleRoute,
        orchestrationKind: R13ReleaseOrchestrationKind,
        processingConfiguration: UpscaleProcessingConfiguration,
        streamIdentifier: String,
        candidates: [R13ProductBackendSessionCandidate],
        candidateExclusions:
            [R13ProductASHScalingCandidateExclusion] = []
    ) throws {
        guard orchestrationKind != .none else {
            throw R13ProductASHRoutingSessionError
                .invalidRouterIdentity
        }
        guard !candidates.isEmpty else {
            throw R13ProductASHRoutingSessionError.noCandidates
        }
        var byBackendID:
            [String: R13ProductBackendSessionCandidate] = [:]
        var routeIdentities: Set<AppleUpscaleRouteIdentity> = []
        for candidate in candidates {
            let backendID =
                candidate.routeIdentity.backend.backendID
            guard byBackendID.updateValue(
                candidate,
                forKey: backendID
            ) == nil else {
                throw R13ProductASHRoutingSessionError
                    .duplicateBackendID(backendID)
            }
            guard routeIdentities.insert(
                candidate.routeIdentity
            ).inserted else {
                throw R13ProductASHRoutingSessionError
                    .duplicateRouteIdentity
            }
        }
        var excludedBackendIDs: Set<String> = []
        for exclusion in candidateExclusions {
            let backendID = exclusion.expectedBackendID
            guard excludedBackendIDs.insert(backendID).inserted
            else {
                throw R13ProductASHRoutingSessionError
                    .duplicateCandidateExclusion(backendID)
            }
            guard byBackendID[backendID] == nil else {
                throw R13ProductASHRoutingSessionError
                    .admittedCandidateMarkedExcluded(backendID)
            }
        }
        let routerProcessingIdentity =
            try AppleUpscaleProcessingIdentity(
                route: identity,
                fallbackHistory: []
            )
        self.identity = identity
        self.route = route
        self.orchestrationKind = orchestrationKind
        self.processingConfiguration = processingConfiguration
        self.streamIdentifier = streamIdentifier
        candidatesByBackendID = byBackendID
        self.candidateExclusions = candidateExclusions
        orderedCandidates = candidates.sorted {
            $0.routeIdentity.configurationIdentity
                < $1.routeIdentity.configurationIdentity
        }
        modelReadiness = Self.modelReadiness(
            for: candidates
        )
        masks = try Self.makeEmptyMasks()
        unavailableOutcome = try AppleUpscaleBackendUnavailable(
            processingIdentity: routerProcessingIdentity,
            reason: "r13_product_router_has_no_runnable_backend"
        )
        terminalRejection = try AppleUpscaleBackendRejected(
            processingIdentity: routerProcessingIdentity,
            reason: "admission_closed"
        )
        cancellationRejection = try AppleUpscaleBackendRejected(
            processingIdentity: routerProcessingIdentity,
            reason: "operation_cancelled"
        )
        routingFailure = try AppleUpscaleBackendFailed(
            processingIdentity: routerProcessingIdentity,
            reason: "r13_product_router_failed"
        )
    }

    func submit(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<
        AppleUpscaleProcessedFrame
    > {
        guard !terminal else {
            frame.resourceLifetimeToken.release()
            return .rejected(terminalRejection)
        }
        guard !Task.isCancelled else {
            frame.resourceLifetimeToken.release()
            return .rejected(cancellationRejection)
        }
        submittedFrameCount += 1
        defer { frame.resourceLifetimeToken.release() }

        do {
            let activeCurrentBackendID =
                currentBackendID.flatMap { backendID in
                    unavailableBackendIDs.contains(backendID)
                        ? nil
                        : backendID
                }
            let analysis = try await analyzer.analyze(
                pixelBuffer: R13ProductASHPixelBuffer(
                    value: frame.pixelBuffer
                ),
                frameIdentifier:
                    "\(streamIdentifier).frame.\(frame.sequenceNumber)",
                streamIdentifier: streamIdentifier,
                route: route,
                dwellFrames: dwellFrames,
                currentBackendID: activeCurrentBackendID,
                previousBackendID: previousBackendID,
                processingConfiguration: processingConfiguration,
                resources: resourceSnapshot()
            )
            let activeCandidates = try activeCandidates(
                context: analysis.decisionContext
            )
            guard !activeCandidates.isEmpty else {
                return .unavailable(unavailableOutcome)
            }
            let outcome = orchestrator.decide(
                scope: .product,
                context: analysis.decisionContext,
                candidates: activeCandidates.map(\.ash),
                masks: masks,
                ablation: .ashPlusContinuousSidecar
            )
            guard case .selected(let record) = outcome else {
                return outcome.isBlocked
                    ? .unavailable(unavailableOutcome)
                    : .failed(routingFailure)
            }
            let orderedBackendIDs =
                [record.selectedPlan.selectedBackendID]
                + record.candidateScores
                    .map(\.backendID)
                    .filter {
                        $0 != record.selectedPlan
                            .selectedBackendID
                    }
            return await process(
                frame,
                orderedBackendIDs: orderedBackendIDs,
                decision: record,
                sceneCut:
                    analysis.decisionContext
                        .sceneCutConfidenceQ16.rawValue
                    >= R06ASHParameters.frozen.thresholds
                        .sceneCutConfidenceQ16
            )
        } catch is CancellationError {
            return .rejected(cancellationRejection)
        } catch {
            return .failed(routingFailure)
        }
    }

    func replayCachedDecision(
        _ frame: AppleUpscaleFrame,
        decision: R13ProductASHDecisionEvent,
        isFinalCachedPrefixFrame: Bool,
        requiresBackendWarmup: Bool
    ) async throws {
        defer { frame.resourceLifetimeToken.release() }
        let expectedSequenceNumber =
            events.last.map { $0.sequenceNumber + 1 } ?? 0
        let selectedBackendID =
            decision.selectedRouteIdentity.backend.backendID
        let fallbackHistoryIsValid = (try? AppleUpscaleProcessingIdentity(
            route: decision.selectedRouteIdentity,
            fallbackHistory: decision.fallbackHistory
        )) != nil
        guard !terminal,
              frame.sequenceNumber == expectedSequenceNumber,
              decision.sequenceNumber == expectedSequenceNumber,
              (0...R06ASHQ16.scale).contains(
                  decision.processingPressureQ16
              ),
              !requiresBackendWarmup
                || isFinalCachedPrefixFrame,
              let candidate =
                candidatesByBackendID[selectedBackendID],
              candidate.routeIdentity
                == decision.selectedRouteIdentity,
              fallbackHistoryIsValid,
              decision.fallbackHistory.allSatisfy({ link in
                  let backendID = link.failedRoute.backend.backendID
                  return candidatesByBackendID[backendID]?
                      .routeIdentity == link.failedRoute
                      && !unavailableBackendIDs.contains(backendID)
              }),
              (decision.reason == .fatalBackendFailover)
                == !decision.fallbackHistory.isEmpty else {
            throw R13ProductASHRoutingSessionError
                .invalidReplayDecision(
                    sequenceNumber: frame.sequenceNumber
                )
        }

        let analysis: R13ProductASHFrameAnalysis
        do {
            analysis = try await analyzer.analyze(
                pixelBuffer: R13ProductASHPixelBuffer(
                    value: frame.pixelBuffer
                ),
                frameIdentifier:
                    "\(streamIdentifier).frame."
                    + "\(frame.sequenceNumber)",
                streamIdentifier: streamIdentifier,
                route: route,
                dwellFrames: dwellFrames,
                currentBackendID: currentBackendID,
                previousBackendID: previousBackendID,
                processingConfiguration:
                    processingConfiguration,
                resources: resourceSnapshot()
            )
        } catch {
            throw R13ProductASHRoutingSessionError
                .invalidReplayDecision(
                    sequenceNumber: frame.sequenceNumber
                )
        }

        if requiresBackendWarmup {
            let sceneCut =
                analysis.decisionContext
                    .sceneCutConfidenceQ16.rawValue
                >= R06ASHParameters.frozen.thresholds
                    .sceneCutConfidenceQ16
            await candidate.session.reset(
                reason: sceneCut ? .sceneCut : .discontinuity
            )
            let warmupFrame: AppleUpscaleFrame
            do {
                warmupFrame = try makeAttemptFrame(
                    frame,
                    backendID: selectedBackendID,
                    attemptOrdinal:
                        decision.fallbackHistory.count
                )
            } catch {
                throw R13ProductASHRoutingSessionError
                    .replayCandidateWarmupFailed(
                        sequenceNumber: frame.sequenceNumber
                    )
            }
            let outcome = await candidate.session.submit(
                warmupFrame
            )
            guard case .processed(let processed) = outcome,
                  processed.processingIdentity.route
                    == decision.selectedRouteIdentity,
                  processed.processingIdentity
                    .fallbackHistory.isEmpty else {
                if case .processed(let processed) = outcome {
                    processed.resourceLifetimeToken.release()
                }
                throw R13ProductASHRoutingSessionError
                    .replayCandidateWarmupFailed(
                        sequenceNumber: frame.sequenceNumber
                    )
            }
            processed.resourceLifetimeToken.release()
        }

        unavailableBackendIDs.formUnion(
            decision.failedBackendIDs
        )
        let changedBackend =
            currentBackendID != selectedBackendID
        if changedBackend {
            previousBackendID = currentBackendID
            currentBackendID = selectedBackendID
            dwellFrames = 1
        } else {
            dwellFrames = dwellFrames == Int.max
                ? Int.max
                : dwellFrames + 1
        }
        priorProcessingPressureQ16 = R06ASHQ16(
            validatedRawValue:
                decision.processingPressureQ16
        )
        submittedFrameCount += 1
        processedFrameCount += 1
        events.append(decision)
        if isFinalCachedPrefixFrame {
            resumeBoundaries.append(
                R13ProductASHResumeBoundary(
                    sequenceNumber: frame.sequenceNumber,
                    kind: requiresBackendWarmup
                        ? .oneFrameSelectedCandidateWarmup
                        : .fullCacheNoBackendWarmup
                )
            )
        }
    }

    func reset(reason: AppleUpscaleResetReason) async {
        guard !terminal else { return }
        await analyzer.reset()
        currentBackendID = nil
        previousBackendID = nil
        dwellFrames = 0
        await withTaskGroup(of: Void.self) { group in
            for candidate in orderedCandidates {
                group.addTask {
                    await candidate.session.reset(reason: reason)
                }
            }
        }
    }

    func finish() async -> AppleUpscaleSessionSummary {
        if !terminal {
            terminal = true
            terminalizationCount += 1
            await withTaskGroup(of: Void.self) { group in
                for candidate in orderedCandidates {
                    group.addTask {
                        _ = await candidate.session.finish()
                    }
                }
            }
        }
        return summary
    }

    func cancel() async {
        guard !terminal else { return }
        terminal = true
        terminalizationCount += 1
        await withTaskGroup(of: Void.self) { group in
            for candidate in orderedCandidates {
                group.addTask {
                    await candidate.session.cancel()
                }
            }
        }
    }

    func decisionSummary() async -> R13ProductASHDecisionSummary {
        R13ProductASHDecisionSummary(
            events: events,
            candidateExclusions: candidateExclusions,
            resumeBoundaries: resumeBoundaries
        )
    }

    private var summary: AppleUpscaleSessionSummary {
        AppleUpscaleSessionSummary(
            submittedFrameCount: submittedFrameCount,
            processedFrameCount: processedFrameCount,
            terminalizationCount: terminalizationCount
        )
    }

    private func activeCandidates(
        context: ASHDecisionContext
    ) throws -> [(
        runtime: R13ProductBackendSessionCandidate,
        ash: R06ASHBackendFixture
    )] {
        try orderedCandidates.compactMap { candidate in
            let backendID =
                candidate.routeIdentity.backend.backendID
            guard !unavailableBackendIDs.contains(backendID)
            else { return nil }
            return (
                candidate,
                try candidate.profile.ashCandidate(
                    routeIdentity: candidate.routeIdentity,
                    context: context,
                    orchestrationKind: orchestrationKind
                )
            )
        }
    }

    private func process(
        _ frame: AppleUpscaleFrame,
        orderedBackendIDs: [String],
        decision: R06ASHDecisionRecord,
        sceneCut: Bool
    ) async -> AppleUpscaleBackendOutcome<
        AppleUpscaleProcessedFrame
    > {
        var failures: [(
            route: AppleUpscaleRouteIdentity,
            reason: AppleUpscaleFallbackReasonCode
        )] = []
        for (attemptOrdinal, backendID) in
            orderedBackendIDs.enumerated() {
            guard !unavailableBackendIDs.contains(backendID),
                  let candidate =
                    candidatesByBackendID[backendID] else {
                continue
            }
            if backendID != currentBackendID {
                await candidate.session.reset(
                    reason: sceneCut ? .sceneCut : .discontinuity
                )
            }
            let attemptFrame: AppleUpscaleFrame
            do {
                attemptFrame = try makeAttemptFrame(
                    frame,
                    backendID: backendID,
                    attemptOrdinal: attemptOrdinal
                )
            } catch {
                return .failed(routingFailure)
            }
            let clock = ContinuousClock()
            let startedAt = clock.now
            let outcome = await candidate.session.submit(
                attemptFrame
            )
            updateProcessingPressure(
                elapsed: startedAt.duration(to: clock.now),
                frameDuration: frame.duration
            )
            switch outcome {
            case .processed(let processed):
                guard processed.processingIdentity.route
                        == candidate.routeIdentity,
                      processed.processingIdentity
                        .fallbackHistory.isEmpty else {
                    processed.resourceLifetimeToken.release()
                    unavailableBackendIDs.insert(backendID)
                    failures.append(
                        (
                            candidate.routeIdentity,
                            .backendFailed
                        )
                    )
                    continue
                }
                do {
                    let fallbackHistory = try makeFallbackHistory(
                        failures: failures,
                        selectedRoute:
                            processed.processingIdentity.route
                    )
                    let wrapped = try wrap(
                        processed,
                        fallbackHistory: fallbackHistory
                    )
                    let changedBackend =
                        currentBackendID != backendID
                    if changedBackend {
                        previousBackendID = currentBackendID
                        currentBackendID = backendID
                        dwellFrames = 1
                    } else {
                        dwellFrames = dwellFrames == Int.max
                            ? Int.max
                            : dwellFrames + 1
                    }
                    processedFrameCount += 1
                    events.append(
                        R13ProductASHDecisionEvent(
                            sequenceNumber:
                                frame.sequenceNumber,
                            selectedRouteIdentity:
                                candidate.routeIdentity,
                            reason: failures.isEmpty
                                ? decision.reason
                                : .fatalBackendFailover,
                            fallbackHistory: fallbackHistory,
                            processingPressureQ16:
                                priorProcessingPressureQ16
                                    .rawValue
                        )
                    )
                    return .processed(wrapped)
                } catch {
                    processed.resourceLifetimeToken.release()
                    return .failed(routingFailure)
                }
            case .unavailable:
                unavailableBackendIDs.insert(backendID)
                failures.append(
                    (
                        candidate.routeIdentity,
                        .backendUnavailable
                    )
                )
            case .rejected(let rejected):
                if rejected.reason == "operation_cancelled"
                    || Task.isCancelled {
                    return .rejected(cancellationRejection)
                }
                unavailableBackendIDs.insert(backendID)
                failures.append(
                    (
                        candidate.routeIdentity,
                        .backendRejected
                    )
                )
            case .failed:
                unavailableBackendIDs.insert(backendID)
                failures.append(
                    (
                        candidate.routeIdentity,
                        .backendFailed
                    )
                )
            }
        }
        currentBackendID = nil
        return .unavailable(unavailableOutcome)
    }

    private func makeAttemptFrame(
        _ source: AppleUpscaleFrame,
        backendID: String,
        attemptOrdinal: Int
    ) throws -> AppleUpscaleFrame {
        let token = try AppleUpscaleResourceLifetimeToken(
            identity:
                "r13.router.input.\(source.sequenceNumber)."
                + "\(attemptOrdinal).\(backendID)",
            releaseAction: {}
        )
        return try AppleUpscaleFrame(
            sequenceNumber: source.sequenceNumber,
            pixelBuffer: source.pixelBuffer,
            presentationTimestamp:
                source.presentationTimestamp,
            duration: source.duration,
            colorDescription: source.colorDescription,
            metadataIdentity: source.metadataIdentity,
            resourceLifetimeToken: token
        )
    }

    private func wrap(
        _ processed: AppleUpscaleProcessedFrame,
        fallbackHistory: [AppleUpscaleFallbackLink]
    ) throws -> AppleUpscaleProcessedFrame {
        try AppleUpscaleProcessedFrame(
            sequenceNumber: processed.sequenceNumber,
            pixelBuffer: processed.pixelBuffer,
            presentationTimestamp:
                processed.presentationTimestamp,
            duration: processed.duration,
            colorDescription: processed.colorDescription,
            metadataIdentity: processed.metadataIdentity,
            resourceLifetimeToken:
                processed.resourceLifetimeToken,
            processingIdentity: AppleUpscaleProcessingIdentity(
                route: processed.processingIdentity.route,
                fallbackHistory: fallbackHistory
            )
        )
    }

    private func makeFallbackHistory(
        failures: [(
            route: AppleUpscaleRouteIdentity,
            reason: AppleUpscaleFallbackReasonCode
        )],
        selectedRoute: AppleUpscaleRouteIdentity
    ) throws -> [AppleUpscaleFallbackLink] {
        var fallbackHistory: [AppleUpscaleFallbackLink] = []
        for index in failures.indices {
            let nextRoute =
                failures.indices.contains(index + 1)
                    ? failures[index + 1].route
                    : selectedRoute
            fallbackHistory.append(
                try AppleUpscaleFallbackLink(
                    failedRoute: failures[index].route,
                    selectedRoute: nextRoute,
                    reasonCode: failures[index].reason,
                    selectedFallbackOrdinal: index
                )
            )
        }
        _ = try AppleUpscaleProcessingIdentity(
            route: selectedRoute,
            fallbackHistory: fallbackHistory
        )
        return fallbackHistory
    }

    private func resourceSnapshot()
        -> R13ProductASHResourceSnapshot {
        R13ProductASHResourceSnapshot(
            backendAvailability:
                orderedCandidates.count
                    > unavailableBackendIDs.count
                ? .available
                : .unavailable,
            modelReadiness: modelReadiness,
            backendQualityConfidenceQ16: .one,
            memoryPressureQ16: .zero,
            thermalPressureQ16: Self.thermalPressure(),
            throughputPressureQ16: priorProcessingPressureQ16
        )
    }

    nonisolated static func modelReadiness(
        for candidates: [R13ProductBackendSessionCandidate]
    ) -> R06ASHModelReadiness {
        for candidate in candidates {
            switch candidate.routeIdentity.backend
                .modelAssetsIdentity {
            case .notRequired:
                continue
            case .appleConfigurationManaged(_, .ready),
                 .bound:
                return .ready
            }
        }
        return .notRequired
    }

    private func updateProcessingPressure(
        elapsed: Duration,
        frameDuration: CMTime
    ) {
        let frameSeconds = CMTimeGetSeconds(frameDuration)
        guard frameSeconds.isFinite, frameSeconds > 0 else {
            priorProcessingPressureQ16 = .zero
            return
        }
        let components = elapsed.components
        let elapsedSeconds =
            Double(components.seconds)
            + Double(components.attoseconds) / 1.0e18
        let pressure = min(
            max((elapsedSeconds / frameSeconds) - 1.0, 0.0),
            1.0
        )
        priorProcessingPressureQ16 = R06ASHQ16(
            validatedRawValue: Int64(
                (pressure * Double(R06ASHQ16.scale)).rounded()
            )
        )
    }

    private static func thermalPressure() -> R06ASHQ16 {
        let value: Int64
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            value = 0
        case .fair:
            value = R06ASHQ16.scale / 3
        case .serious:
            value = R06ASHQ16.scale * 2 / 3
        case .critical:
            value = R06ASHQ16.scale
        @unknown default:
            value = R06ASHQ16.scale
        }
        return R06ASHQ16(validatedRawValue: value)
    }

    private static func makeEmptyMasks() throws -> R06ASHMaskSet {
        try R06ASHMaskSet(
            lumaProtection: R06ASHMask(
                id: .lumaProtection,
                width: 1,
                height: 1,
                samplesQ15: [0]
            ),
            chromaProtection: R06ASHMask(
                id: .chromaProtection,
                width: 1,
                height: 1,
                samplesQ15: [0]
            ),
            postprocessSuppression: R06ASHMask(
                id: .postprocessSuppression,
                width: 1,
                height: 1,
                samplesQ15: [0]
            )
        )
    }
}

private extension R06ASHOrchestrationOutcome {
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}
