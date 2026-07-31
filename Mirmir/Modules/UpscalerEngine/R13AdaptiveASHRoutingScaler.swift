import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

enum R13ProductASHScalingRouterError:
    Error,
    Equatable,
    Sendable {
    case noCandidates
    case noAdmittedCandidates(
        [R13ProductASHScalingCandidateExclusion]
    )
    case candidateExclusionEncoding
    case duplicateBackendID(String)
    case noRunnableCandidate
    case invalidReplayEvent(String)
    case terminal
}

struct R13ProductASHScalingCandidate: Sendable {
    let scaler: any R03NV12Scaling
    let routeIdentity: AppleUpscaleRouteIdentity
    let profile: R13ProductBackendProfile
}

enum R13ProductASHScalingCandidateAdmissionPhase:
    String,
    Codable,
    Equatable,
    Sendable {
    case scalerConstruction = "scaler_construction"
    case sessionConstruction = "session_construction"
    case routeIdentity = "route_identity"
}

enum R13ProductASHCandidateKind:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable {
    case highQualityVImage = "vimage_lanczos_high_quality"
    case fastMPSBilinear = "mps_bilinear"
    case deterministicMPSLanczos = "mps_lanczos"
    case videoToolboxQuality = "videotoolbox_quality"
    case videoToolboxLowLatency = "videotoolbox_low_latency"
    case metalFXSpatial = "metalfx_spatial"

    init(scalerKind: R13ReleaseScalerKind) {
        switch scalerKind {
        case .highQualityVImage:
            self = .highQualityVImage
        case .fastMPSBilinear:
            self = .fastMPSBilinear
        case .deterministicMPSLanczos:
            self = .deterministicMPSLanczos
        }
    }

    var scalerKind: R13ReleaseScalerKind? {
        switch self {
        case .highQualityVImage:
            return .highQualityVImage
        case .fastMPSBilinear:
            return .fastMPSBilinear
        case .deterministicMPSLanczos:
            return .deterministicMPSLanczos
        case .videoToolboxQuality,
             .videoToolboxLowLatency,
             .metalFXSpatial:
            return nil
        }
    }
}

protocol R13ProductASHCandidateFailureReasonProviding: Error {
    var candidateFailureReasonCode: String { get }
}

struct R13ProductASHScalingCandidateFailureEvidence:
    Codable,
    Equatable,
    Sendable {
    let reasonCode: String
    let errorType: String
    let errorDomain: String
    let errorCode: Int
    let detailSHA256: String

    init(error: Error) {
        let nsError = error as NSError
        reasonCode = Self.reasonCode(error)
        errorType = Self.safeIdentifier(
            String(reflecting: Swift.type(of: error))
        )
        errorDomain = Self.safeIdentifier(nsError.domain)
        errorCode = nsError.code
        detailSHA256 = SHA256.hash(
            data: Data(String(reflecting: error).utf8)
        ).map { String(format: "%02x", $0) }.joined()
    }

    private static func reasonCode(_ error: Error) -> String {
        if let typed =
                error as?
                    any R13ProductASHCandidateFailureReasonProviding {
            return typed.candidateFailureReasonCode
        }
        if error is R03MPSTextureDimensionLimitError {
            return "mps_texture_dimension_limit"
        }
        guard let scalingError =
                error as? R03NV12ScalingError else {
            return "unexpected_typed_error"
        }
        switch scalingError {
        case .runtimeUnavailable:
            return "runtime_unavailable"
        case .invalidPixelFormat:
            return "invalid_pixel_format"
        case .invalidDimensions:
            return "invalid_dimensions"
        case .invalidPlaneCount:
            return "invalid_plane_count"
        case .invalidPlaneDimensions:
            return "invalid_plane_dimensions"
        case .colorDescriptionMismatch:
            return "color_description_mismatch"
        case .colorAttachmentMismatch:
            return "color_attachment_mismatch"
        case .pixelBufferLockFailed:
            return "pixel_buffer_lock_failed"
        case .missingPlaneBaseAddress:
            return "missing_plane_base_address"
        case .scalingFailed:
            return "scaling_failed"
        case .operationCancelled:
            return "operation_cancelled"
        }
    }

    private static func safeIdentifier(_ value: String) -> String {
        let safeScalars = value.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return Character(String(scalar))
            case 45, 46, 95:
                return Character(String(scalar))
            default:
                return "_"
            }
        }
        let normalized = String(safeScalars.prefix(160))
        return normalized.isEmpty ? "untrusted" : normalized
    }
}

struct R13ProductASHScalingCandidateExclusion:
    Codable,
    Equatable,
    Sendable {
    let declaredKind: R13ProductASHCandidateKind
    let expectedBackendID: String
    let phase: R13ProductASHScalingCandidateAdmissionPhase
    let failure: R13ProductASHScalingCandidateFailureEvidence

    init(
        declaredKind: R13ReleaseScalerKind,
        expectedBackendID: String,
        phase: R13ProductASHScalingCandidateAdmissionPhase,
        failure: R13ProductASHScalingCandidateFailureEvidence
    ) {
        self.init(
            declaredCandidateKind:
                R13ProductASHCandidateKind(
                    scalerKind: declaredKind
                ),
            expectedBackendID: expectedBackendID,
            phase: phase,
            failure: failure
        )
    }

    init(
        declaredCandidateKind:
            R13ProductASHCandidateKind,
        expectedBackendID: String,
        phase: R13ProductASHScalingCandidateAdmissionPhase,
        failure: R13ProductASHScalingCandidateFailureEvidence
    ) {
        declaredKind = declaredCandidateKind
        self.expectedBackendID = expectedBackendID
        self.phase = phase
        self.failure = failure
    }
}

struct R13ProductASHScalingCandidateSet: Sendable {
    let candidates: [R13ProductASHScalingCandidate]
    let exclusions: [R13ProductASHScalingCandidateExclusion]
    let declaredRouteIdentities:
        [String: AppleUpscaleRouteIdentity]
}

enum R13ProductASHScalingCandidateExclusionEncoding {
    static func canonicalJSON(
        _ exclusions:
            [R13ProductASHScalingCandidateExclusion]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        let data = try encoder.encode(exclusions)
        guard let value = String(data: data, encoding: .utf8) else {
            throw R13ProductASHScalingRouterError
                .candidateExclusionEncoding
        }
        return value
    }

    static func sha256(
        _ exclusions:
            [R13ProductASHScalingCandidateExclusion]
    ) throws -> String {
        let canonical = try canonicalJSON(exclusions)
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum R13AdaptiveScalingExecution: Sendable {
    case direct(any R03NV12Scaling)
    case routed(R13ProductASHScalingRouter)

    var candidateExclusions:
        [R13ProductASHScalingCandidateExclusion] {
        switch self {
        case .direct:
            return []
        case .routed(let router):
            return router.candidateExclusions
        }
    }

    func scale(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        frameIndex: Int,
        frameDuration: CMTime,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> R13ProductASHDecisionEvent? {
        switch self {
        case .direct(let scaler):
            try scaler.scale(
                source: source,
                destination: destination,
                cancellation: cancellation
            )
            return nil
        case .routed(let router):
            return try await router.scale(
                source: R13ProductASHPixelBuffer(value: source),
                destination: R13ProductASHPixelBuffer(
                    value: destination
                ),
                frameIndex: frameIndex,
                frameDuration: frameDuration,
                cancellation: cancellation
            )
        }
    }

    func finish()
        async throws -> R13ProductASHDecisionMetadata? {
        switch self {
        case .direct(let scaler):
            scaler.finish()
            return nil
        case .routed(let router):
            let summary = await router.finish()
            return try summary.outputMetadata()
        }
    }

    func replayCachedDecision(
        source: CVPixelBuffer,
        frameIndex: Int,
        decision: R13ProductASHDecisionEvent?,
        isFinalCachedPrefixFrame: Bool
    ) async throws {
        switch self {
        case .direct:
            guard decision == nil else {
                throw R13ProductASHScalingRouterError
                    .invalidReplayEvent(
                        "direct_execution_has_routing_decision"
                    )
            }
        case .routed(let router):
            guard let decision else {
                throw R13ProductASHScalingRouterError
                    .invalidReplayEvent(
                        "routed_execution_missing_routing_decision"
                    )
            }
            try await router.replayCachedDecision(
                source: R13ProductASHPixelBuffer(value: source),
                frameIndex: frameIndex,
                decision: decision,
                isFinalCachedPrefixFrame:
                    isFinalCachedPrefixFrame
            )
        }
    }

    func cancel() async {
        switch self {
        case .direct(let scaler):
            scaler.cancel()
        case .routed(let router):
            await router.cancel()
        }
    }
}

actor R13ProductASHScalingRouter {
    private let scaleContext: R13ProductASHScaleContext
    private let orchestrationKind: R13ReleaseOrchestrationKind
    private let processingConfiguration:
        UpscaleProcessingConfiguration
    private let streamIdentifier: String
    private let candidatesByBackendID:
        [String: R13ProductASHScalingCandidate]
    private let declaredRouteIdentitiesByBackendID:
        [String: AppleUpscaleRouteIdentity]
    private let orderedCandidates:
        [R13ProductASHScalingCandidate]
    nonisolated let candidateExclusions:
        [R13ProductASHScalingCandidateExclusion]
    private let masks: R06ASHMaskSet
    private let analyzer = R13ProductASHAnalyzer()
    private let orchestrator = R06ASHOrchestrator(
        parameters: .frozen
    )

    private var unavailableBackendIDs: Set<String> = []
    private var replayedFailedBackendIDs: Set<String> = []
    private var currentBackendID: String?
    private var previousBackendID: String?
    private var dwellFrames = 0
    private var priorProcessingPressureQ16 = R06ASHQ16.zero
    private var terminal = false
    private var events: [R13ProductASHDecisionEvent] = []
    private var resumeBoundaries:
        [R13ProductASHResumeBoundary] = []

    init(
        scaleContext: R13ProductASHScaleContext,
        orchestrationKind: R13ReleaseOrchestrationKind,
        processingConfiguration: UpscaleProcessingConfiguration,
        streamIdentifier: String,
        candidates: [R13ProductASHScalingCandidate],
        candidateExclusions:
            [R13ProductASHScalingCandidateExclusion] = [],
        declaredRouteIdentities:
            [String: AppleUpscaleRouteIdentity] = [:]
    ) throws {
        guard orchestrationKind != .none else {
            throw R13ProductASHScalingRouterError.noCandidates
        }
        guard !candidates.isEmpty else {
            throw R13ProductASHScalingRouterError.noCandidates
        }
        var candidatesByBackendID:
            [String: R13ProductASHScalingCandidate] = [:]
        for candidate in candidates {
            let backendID =
                candidate.routeIdentity.backend.backendID
            guard candidatesByBackendID.updateValue(
                candidate,
                forKey: backendID
            ) == nil else {
                throw R13ProductASHScalingRouterError
                    .duplicateBackendID(backendID)
            }
        }
        var completeDeclaredRoutes = declaredRouteIdentities
        for candidate in candidates {
            let backendID =
                candidate.routeIdentity.backend.backendID
            if let declared = completeDeclaredRoutes[backendID],
               declared != candidate.routeIdentity {
                throw R13ProductASHScalingRouterError
                    .duplicateBackendID(backendID)
            }
            completeDeclaredRoutes[backendID] =
                candidate.routeIdentity
        }
        self.scaleContext = scaleContext
        self.orchestrationKind = orchestrationKind
        self.processingConfiguration = processingConfiguration
        self.streamIdentifier = streamIdentifier
        self.candidatesByBackendID = candidatesByBackendID
        declaredRouteIdentitiesByBackendID =
            completeDeclaredRoutes
        self.candidateExclusions = candidateExclusions
        unavailableBackendIDs = Set(
            candidateExclusions.map(\.expectedBackendID)
        )
        orderedCandidates = candidates.sorted {
            $0.routeIdentity.configurationIdentity
                < $1.routeIdentity.configurationIdentity
        }
        masks = try Self.makeEmptyMasks()
    }

    func scale(
        source: R13ProductASHPixelBuffer,
        destination: R13ProductASHPixelBuffer,
        frameIndex: Int,
        frameDuration: CMTime,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> R13ProductASHDecisionEvent {
        guard !terminal else {
            throw R13ProductASHScalingRouterError.terminal
        }
        guard !cancellation.isCancelled,
              !Task.isCancelled else {
            throw R03NV12ScalingError.operationCancelled
        }
        let activeCurrentBackendID =
            currentBackendID.flatMap { backendID in
                unavailableBackendIDs.contains(backendID)
                    ? nil
                    : backendID
            }
        let analysis = try await analyzer.analyze(
            pixelBuffer: source,
            frameIdentifier:
                "\(streamIdentifier).frame.\(frameIndex)",
            streamIdentifier: streamIdentifier,
            scale: scaleContext,
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
            throw R13ProductASHScalingRouterError
                .noRunnableCandidate
        }
        let outcome = orchestrator.decide(
            scope: .product,
            context: analysis.decisionContext,
            candidates: activeCandidates.map(\.ash),
            masks: masks,
            ablation: .ashPlusContinuousSidecar
        )
        guard case .selected(let decision) = outcome else {
            throw R13ProductASHScalingRouterError
                .noRunnableCandidate
        }
        let orderedBackendIDs =
            [decision.selectedPlan.selectedBackendID]
            + decision.candidateScores
                .map(\.backendID)
                .filter {
                    $0 != decision.selectedPlan
                        .selectedBackendID
                }
        return try process(
            source: source.value,
            destination: destination.value,
            frameIndex: frameIndex,
            frameDuration: frameDuration,
            cancellation: cancellation,
            orderedBackendIDs: orderedBackendIDs,
            decision: decision
        )
    }

    func finish() -> R13ProductASHDecisionSummary {
        if !terminal {
            terminal = true
            for candidate in orderedCandidates {
                candidate.scaler.finish()
            }
        }
        return R13ProductASHDecisionSummary(
            events: events,
            candidateExclusions: candidateExclusions,
            resumeBoundaries: resumeBoundaries
        )
    }

    func cancel() {
        guard !terminal else { return }
        terminal = true
        for candidate in orderedCandidates {
            candidate.scaler.cancel()
        }
    }

    func replayCachedDecision(
        source: R13ProductASHPixelBuffer,
        frameIndex: Int,
        decision: R13ProductASHDecisionEvent,
        isFinalCachedPrefixFrame: Bool
    ) async throws {
        guard !terminal else {
            throw R13ProductASHScalingRouterError.terminal
        }
        let expectedSequenceNumber =
            events.last.map { $0.sequenceNumber + 1 } ?? 0
        let selectedBackendID =
            decision.selectedRouteIdentity.backend.backendID
        guard frameIndex == expectedSequenceNumber,
              decision.sequenceNumber == expectedSequenceNumber,
              (0...R06ASHQ16.scale).contains(
                  decision.processingPressureQ16
              ),
              declaredRouteIdentitiesByBackendID[
                  selectedBackendID
              ] == decision.selectedRouteIdentity,
              Set(decision.failedBackendIDs).count
                == decision.failedBackendIDs.count,
              !decision.failedBackendIDs.contains(
                  selectedBackendID
              ),
              decision.failedBackendIDs.allSatisfy({
                  declaredRouteIdentitiesByBackendID[$0] != nil
              }),
              decision.failedBackendIDs.allSatisfy({
                  !replayedFailedBackendIDs.contains($0)
              }),
              (decision.reason == .fatalBackendFailover)
                == !decision.failedBackendIDs.isEmpty else {
            throw R13ProductASHScalingRouterError
                .invalidReplayEvent(
                    "sequence_or_route_contract"
                )
        }
        let activeCurrentBackendID =
            currentBackendID.flatMap { backendID in
                unavailableBackendIDs.contains(backendID)
                    ? nil
                    : backendID
            }
        _ = try await analyzer.analyze(
            pixelBuffer: source,
            frameIdentifier:
                "\(streamIdentifier).frame.\(frameIndex)",
            streamIdentifier: streamIdentifier,
            scale: scaleContext,
            dwellFrames: dwellFrames,
            currentBackendID: activeCurrentBackendID,
            previousBackendID: previousBackendID,
            processingConfiguration: processingConfiguration,
            resources: resourceSnapshot()
        )

        unavailableBackendIDs.formUnion(
            decision.failedBackendIDs
        )
        replayedFailedBackendIDs.formUnion(
            decision.failedBackendIDs
        )
        if candidatesByBackendID[selectedBackendID] == nil {
            unavailableBackendIDs.insert(selectedBackendID)
        }
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
        events.append(decision)
        if isFinalCachedPrefixFrame {
            resumeBoundaries.append(
                R13ProductASHResumeBoundary(
                    sequenceNumber: frameIndex,
                    kind: .statelessScalerStateRestored
                )
            )
        }
    }

    private func activeCandidates(
        context: ASHDecisionContext
    ) throws -> [(
        runtime: R13ProductASHScalingCandidate,
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
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        frameIndex: Int,
        frameDuration: CMTime,
        cancellation: AppleUpscaleOperationCancellationSignal,
        orderedBackendIDs: [String],
        decision: R06ASHDecisionRecord
    ) throws -> R13ProductASHDecisionEvent {
        var failedBackendIDs: [String] = []
        for backendID in orderedBackendIDs {
            guard !unavailableBackendIDs.contains(backendID),
                  let candidate =
                    candidatesByBackendID[backendID] else {
                continue
            }
            guard !cancellation.isCancelled,
                  !Task.isCancelled else {
                throw R03NV12ScalingError.operationCancelled
            }
            if currentBackendID != backendID {
                candidate.scaler.reset()
            }
            let clock = ContinuousClock()
            let startedAt = clock.now
            do {
                try candidate.scaler.scale(
                    source: source,
                    destination: destination,
                    cancellation: cancellation
                )
                updateProcessingPressure(
                    elapsed: startedAt.duration(to: clock.now),
                    frameDuration: frameDuration
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
                let event = R13ProductASHDecisionEvent(
                    sequenceNumber: frameIndex,
                    selectedRouteIdentity:
                        candidate.routeIdentity,
                    reason: failedBackendIDs.isEmpty
                        ? decision.reason
                        : .fatalBackendFailover,
                    failedBackendIDs: failedBackendIDs,
                    processingPressureQ16:
                        priorProcessingPressureQ16.rawValue
                )
                events.append(event)
                return event
            } catch R03NV12ScalingError.operationCancelled {
                throw R03NV12ScalingError.operationCancelled
            } catch {
                updateProcessingPressure(
                    elapsed: startedAt.duration(to: clock.now),
                    frameDuration: frameDuration
                )
                unavailableBackendIDs.insert(backendID)
                failedBackendIDs.append(backendID)
            }
        }
        currentBackendID = nil
        throw R13ProductASHScalingRouterError
            .noRunnableCandidate
    }

    private func resourceSnapshot()
        -> R13ProductASHResourceSnapshot {
        R13ProductASHResourceSnapshot(
            backendAvailability:
                orderedCandidates.count
                    > unavailableBackendIDs.count
                ? .available
                : .unavailable,
            modelReadiness: .notRequired,
            backendQualityConfidenceQ16: .one,
            memoryPressureQ16: .zero,
            thermalPressureQ16: Self.thermalPressure(),
            throughputPressureQ16: priorProcessingPressureQ16
        )
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

enum R13ProductASHScalingCandidateFactory {
    static func makeCandidates(
        scalePlan: R13ReleaseScalePlan,
        videoFormat: MediaVideoFormat,
        orchestrationKind: R13ReleaseOrchestrationKind,
        makeScaler: (
            _ kind: R13ReleaseScalerKind
        ) throws -> any R03NV12Scaling
    ) throws -> R13ProductASHScalingCandidateSet {
        var candidates: [R13ProductASHScalingCandidate] = []
        var exclusions:
            [R13ProductASHScalingCandidateExclusion] = []
        var declaredRouteIdentities:
            [String: AppleUpscaleRouteIdentity] = [:]
        for entry in R13A11ProductSessionFactory
            .fallbackProfiles(for: orchestrationKind) {
            let modeBinding = directModeBinding(
                for: entry.kind,
                videoFormat: videoFormat
            )
            let declaredRouteIdentity: AppleUpscaleRouteIdentity
            do {
                declaredRouteIdentity = try routeIdentity(
                    scalePlan: scalePlan,
                    modeBinding: modeBinding
                )
                declaredRouteIdentities[
                    declaredRouteIdentity.backend.backendID
                ] = declaredRouteIdentity
            } catch {
                exclusions.append(
                    exclusion(
                        kind: entry.kind,
                        modeBinding: modeBinding,
                        phase: .routeIdentity,
                        error: error
                    )
                )
                continue
            }
            let scaler: any R03NV12Scaling
            do {
                scaler = try makeScaler(entry.kind)
            } catch {
                exclusions.append(
                    exclusion(
                        kind: entry.kind,
                        modeBinding: modeBinding,
                        phase: .scalerConstruction,
                        error: error
                    )
                )
                continue
            }
            candidates.append(
                R13ProductASHScalingCandidate(
                    scaler: scaler,
                    routeIdentity: declaredRouteIdentity,
                    profile: entry.profile
                )
            )
        }
        guard !candidates.isEmpty else {
            throw R13ProductASHScalingRouterError
                .noAdmittedCandidates(exclusions)
        }
        return R13ProductASHScalingCandidateSet(
            candidates: candidates,
            exclusions: exclusions,
            declaredRouteIdentities:
                declaredRouteIdentities
        )
    }

    static func makeFormatPreservingScaler(
        kind: R13ReleaseScalerKind,
        sourceResolution: VideoResolution,
        targetResolution: VideoResolution,
        videoFormat: MediaVideoFormat
    ) throws -> any R03NV12Scaling {
        switch kind {
        case .highQualityVImage:
            return R13FormatPreservingVImageScaler(
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: videoFormat,
                quality: .highQuality
            )
        case .fastMPSBilinear:
            return try R13FormatPreservingMPSScaler(
                mode: .bilinear,
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: videoFormat
            )
        case .deterministicMPSLanczos:
            return try R13FormatPreservingMPSScaler(
                mode: .lanczos,
                sourceResolution: sourceResolution,
                targetResolution: targetResolution,
                videoFormat: videoFormat
            )
        }
    }

    static func directModeBinding(
        for kind: R13ReleaseScalerKind,
        videoFormat: MediaVideoFormat
    ) -> R13ReleaseModeBinding {
        let mode: UpscaleMode
        let preference: UpscaleEnginePreference
        switch kind {
        case .highQualityVImage:
            mode = .quality
            preference = .accelerateVImageHighQuality
        case .fastMPSBilinear:
            mode = .fast
            preference = .mpsBilinear
        case .deterministicMPSLanczos:
            mode = .deterministic
            preference = .mpsLanczos
        }
        return R13ReleaseModeBinding(
            requestedMode: mode,
            enginePreference: preference
        ).resolving(videoFormat: videoFormat)
    }

    static func scaleContext(
        for scalePlan: R13ReleaseScalePlan,
        routeID: String
    ) -> R13ProductASHScaleContext {
        switch scalePlan {
        case .productQualified(let route):
            return R13ProductASHScaleContext(route: route)
        case .adaptiveMPSLanczos(let plan):
            return R13ProductASHScaleContext(
                adaptivePlan: plan,
                routeID: routeID
            )
        }
    }

    static func resolutions(
        for scalePlan: R13ReleaseScalePlan
    ) -> (
        source: VideoResolution,
        target: VideoResolution
    ) {
        switch scalePlan {
        case .productQualified(let route):
            return (
                route.canonicalSourceResolution,
                route.canonicalTargetResolution
            )
        case .adaptiveMPSLanczos(let plan):
            return (
                plan.processingSourceResolution,
                plan.targetResolution
            )
        }
    }

    private static func routeIdentity(
        scalePlan: R13ReleaseScalePlan,
        modeBinding: R13ReleaseModeBinding
    ) throws -> AppleUpscaleRouteIdentity {
        switch scalePlan {
        case .productQualified(let route):
            return try R13ReleaseIdentity.makeProductRoute(
                for: route,
                modeBinding: modeBinding
            )
        case .adaptiveMPSLanczos(let plan):
            return try R13ReleaseIdentity.makeAdaptiveRoute(
                for: plan,
                modeBinding: modeBinding
            )
        }
    }

    private static func exclusion(
        kind: R13ReleaseScalerKind,
        modeBinding: R13ReleaseModeBinding,
        phase: R13ProductASHScalingCandidateAdmissionPhase,
        error: Error
    ) -> R13ProductASHScalingCandidateExclusion {
        R13ProductASHScalingCandidateExclusion(
            declaredKind: kind,
            expectedBackendID: modeBinding.backendID,
            phase: phase,
            failure:
                R13ProductASHScalingCandidateFailureEvidence(
                    error: error
                )
        )
    }
}
