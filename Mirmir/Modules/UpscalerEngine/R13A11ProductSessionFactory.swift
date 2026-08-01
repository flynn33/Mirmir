import Foundation

enum R13A11ProductCandidateConstructionError:
    Error,
    Equatable,
    Sendable,
    R13ProductASHCandidateFailureReasonProviding {
    case routeBindingUnavailable
    case capabilityNotAdmitted
    case sessionUnavailable(String)
    case sessionRejected(String)
    case sessionFailed(String)
    case sessionRouteIdentityMismatch(
        expectedBackendID: String,
        actualBackendID: String
    )

    var candidateFailureReasonCode: String {
        switch self {
        case .routeBindingUnavailable:
            return "route_binding_unavailable"
        case .capabilityNotAdmitted:
            return "capability_not_admitted"
        case .sessionUnavailable:
            return "session_unavailable"
        case .sessionRejected:
            return "session_rejected"
        case .sessionFailed:
            return "session_failed"
        case .sessionRouteIdentityMismatch:
            return "session_route_identity_mismatch"
        }
    }

    var admissionPhase:
        R13ProductASHScalingCandidateAdmissionPhase {
        switch self {
        case .routeBindingUnavailable:
            return .routeIdentity
        case .capabilityNotAdmitted,
             .sessionUnavailable,
             .sessionRejected,
             .sessionFailed,
             .sessionRouteIdentityMismatch:
            return .sessionConstruction
        }
    }
}

struct R13A11ProductCandidateDeclaration:
    Hashable,
    Sendable {
    let declaredKind: R13ProductASHCandidateKind
    let expectedBackendID: String
    let profile: R13ProductBackendProfile
}

typealias R13A11ProductCandidateConstructor = @Sendable (
    _ declaration: R13A11ProductCandidateDeclaration
) async throws -> R13ProductBackendSessionCandidate

enum R13A11ProductSessionFactory {
    static func makeSession(
        route: R03ScaleRoute
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        try await makeSession(
            route: route,
            modeBinding: R13ReleaseModePolicy.binding(
                for: .deterministic
            )
        )
    }

    static func makeSession(
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        try await makeSession(
            route: route,
            modeBinding: modeBinding,
            processingConfiguration: UpscaleProcessingConfiguration(
                enginePreference:
                    modeBinding.enginePreference
            ),
            streamIdentifier:
                "r13.\(modeBinding.requestedMode.rawValue)."
                + route.rawValue
        )
    }

    static func makeSession(
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding,
        processingConfiguration: UpscaleProcessingConfiguration,
        streamIdentifier: String
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        try await makeSession(
            route: route,
            modeBinding: modeBinding,
            processingConfiguration: processingConfiguration,
            streamIdentifier: streamIdentifier,
            candidateConstructor: { declaration in
                try await makeCandidate(
                    route: route,
                    declaration: declaration
                )
            }
        )
    }

    static func makeSession(
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding,
        processingConfiguration: UpscaleProcessingConfiguration,
        streamIdentifier: String,
        candidateConstructor:
            @escaping R13A11ProductCandidateConstructor
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        guard modeBinding.usesProductOrchestration else {
            return try await makeDirectSession(
                route: route,
                modeBinding: modeBinding
            )
        }
        return try await makeOrchestratedSession(
            route: route,
            modeBinding: modeBinding,
            processingConfiguration: processingConfiguration,
            streamIdentifier: streamIdentifier,
            candidateConstructor: candidateConstructor
        )
    }

    private static func makeDirectSession(
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        let backend = try makeDirectBackend(
            route: route,
            kind: modeBinding.scalerKind
        )
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try R13ReleaseScalerAdmission
                .makeProductSessionContext(
                    for: modeBinding.scalerKind
                )
        )
        switch outcome {
        case .created(let session):
            let sessionIdentity = await session.identity
            guard sessionIdentity == backend.routeIdentity else {
                await session.cancel()
                throw UpscalerEngineError.strategyFailed(
                    "Release scaler session identity did not match its admitted route."
                )
            }
            return R13ReleaseUpscaleSessionBinding(
                session: session,
                route: route,
                routeIdentity: backend.routeIdentity
            )
        case .unavailable(let unavailable):
            throw UpscalerEngineError.backendUnavailable(
                reason: unavailable.reason
            )
        case .rejected(let rejected):
            throw UpscalerEngineError.strategyFailed(
                "Release scaler session admission was rejected: \(rejected.reason)"
            )
        case .failed(let failure):
            throw UpscalerEngineError.strategyFailed(
                "Release scaler session creation failed: \(failure.reason)"
            )
        }
    }

    private static func makeOrchestratedSession(
        route: R03ScaleRoute,
        modeBinding: R13ReleaseModeBinding,
        processingConfiguration: UpscaleProcessingConfiguration,
        streamIdentifier: String,
        candidateConstructor:
            @escaping R13A11ProductCandidateConstructor
    ) async throws -> R13ReleaseUpscaleSessionBinding {
        var candidates: [R13ProductBackendSessionCandidate] = []
        var exclusions:
            [R13ProductASHScalingCandidateExclusion] = []
        for declaration in candidateDeclarations(
            route: route,
            orchestrationKind:
                modeBinding.orchestrationKind,
            enginePreference:
                modeBinding.enginePreference
        ) {
            do {
                let candidate = try await candidateConstructor(
                    declaration
                )
                let actualBackendID =
                    candidate.routeIdentity.backend.backendID
                guard actualBackendID
                        == declaration.expectedBackendID else {
                    await candidate.session.cancel()
                    throw R13A11ProductCandidateConstructionError
                        .sessionRouteIdentityMismatch(
                            expectedBackendID:
                                declaration.expectedBackendID,
                            actualBackendID: actualBackendID
                        )
                }
                candidates.append(candidate)
            } catch {
                if error is CancellationError
                    || Task.isCancelled
                    || Self.isEngineCancellation(error) {
                    await cancel(candidates)
                    throw CancellationError()
                }
                exclusions.append(
                    R13ProductASHScalingCandidateExclusion(
                        declaredCandidateKind:
                            declaration.declaredKind,
                        expectedBackendID:
                            declaration.expectedBackendID,
                        phase:
                            (error as?
                                R13A11ProductCandidateConstructionError)?
                                .admissionPhase
                                ?? .sessionConstruction,
                        failure:
                            R13ProductASHScalingCandidateFailureEvidence(
                                error: error
                            )
                    )
                )
            }
        }
        guard !candidates.isEmpty else {
            throw R13ProductASHScalingRouterError
                .noAdmittedCandidates(exclusions)
        }

        do {
            let routerIdentity = try R13ReleaseIdentity
                .makeProductRoute(
                    for: route,
                    modeBinding: modeBinding
                )
            let router = try R13ProductASHRoutingSession(
                identity: routerIdentity,
                route: route,
                orchestrationKind:
                    modeBinding.orchestrationKind,
                processingConfiguration:
                    processingConfiguration,
                streamIdentifier: streamIdentifier,
                candidates: candidates,
                candidateExclusions: exclusions
            )
            return R13ReleaseUpscaleSessionBinding(
                session: router,
                route: route,
                routeIdentity: routerIdentity,
                admittedFrameRouteIdentities: Set(
                    candidates.map(\.routeIdentity)
                )
            )
        } catch {
            await cancel(candidates)
            throw error
        }
    }

    private static func isEngineCancellation(
        _ error: Error
    ) -> Bool {
        guard let engineError =
                error as? UpscalerEngineError else {
            return false
        }
        if case .cancelled = engineError {
            return true
        }
        return false
    }

    static func candidateDeclarations(
        route: R03ScaleRoute,
        orchestrationKind: R13ReleaseOrchestrationKind,
        enginePreference: UpscaleEnginePreference = .automatic
    ) -> [R13A11ProductCandidateDeclaration] {
        guard orchestrationKind != .none else { return [] }
        if let exactDeclaration = exactNativeDeclaration(
            route: route,
            enginePreference: enginePreference
        ) {
            return [exactDeclaration]
        }
        var declarations =
            nativeVideoToolboxIntents(
                for: orchestrationKind
            ).map { intent in
                R13A11ProductCandidateDeclaration(
                    declaredKind:
                        intent == .quality
                        ? .videoToolboxQuality
                        : .videoToolboxLowLatency,
                    expectedBackendID:
                        videoToolboxSubjectID(
                            route: route,
                            intent: intent
                        ).rawValue,
                    profile:
                        intent == .quality
                        ? .videoToolboxQuality
                        : .videoToolboxLowLatency
                )
            }
        declarations.append(
            R13A11ProductCandidateDeclaration(
                declaredKind: .metalFXSpatial,
                expectedBackendID:
                    metalFXSubjectID(route: route).rawValue,
                profile: .metalFXSpatial
            )
        )
        declarations.append(
            contentsOf: fallbackProfiles(
                for: orchestrationKind
            ).map { fallback in
                let binding = R13ReleaseModeBinding(
                    requestedMode:
                        directMode(for: fallback.kind),
                    enginePreference:
                        directEnginePreference(for: fallback.kind)
                )
                return R13A11ProductCandidateDeclaration(
                    declaredKind:
                        R13ProductASHCandidateKind(
                            scalerKind: fallback.kind
                        ),
                    expectedBackendID: binding.backendID,
                    profile: fallback.profile
                )
            }
        )
        return declarations
    }

    private static func makeCandidate(
        route: R03ScaleRoute,
        declaration: R13A11ProductCandidateDeclaration
    ) async throws -> R13ProductBackendSessionCandidate {
        switch declaration.declaredKind {
        case .videoToolboxQuality:
            return try await makeVideoToolboxCandidate(
                route: route,
                intent: .quality
            )
        case .videoToolboxLowLatency:
            return try await makeVideoToolboxCandidate(
                route: route,
                intent: .lowLatency
            )
        case .metalFXSpatial:
            return try await makeMetalFXCandidate(route: route)
        case .standardVImage,
             .highQualityVImage,
             .fastMPSBilinear,
             .deterministicMPSLanczos,
             .coreImageLanczos,
             .coreImageBicubic,
             .videoToolboxPixelTransfer:
            guard let scalerKind =
                    declaration.declaredKind.scalerKind else {
                preconditionFailure(
                    "A declared direct candidate must map to a release scaler."
                )
            }
            return try await makeDirectCandidate(
                route: route,
                kind: scalerKind,
                profile: declaration.profile
            )
        }
    }

    private static func makeVideoToolboxCandidate(
        route: R03ScaleRoute,
        intent: R04VideoToolboxNativeRouteIntent
    ) async throws -> R13ProductBackendSessionCandidate {
        guard let binding =
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution:
                    route.canonicalSourceResolution,
                targetResolution:
                    route.canonicalTargetResolution,
                intent: intent
            ) else {
            throw R13A11ProductCandidateConstructionError
                .routeBindingUnavailable
        }
        let observation = try await R04VideoToolboxBackend
            .observeNativeCapability(
                subjectID: binding.subjectID
            )
        guard let modelAssetsIdentity =
                R13VideoToolboxProductCandidateAdmission
                    .modelAssetsIdentity(
                        binding: binding,
                        observation: observation
                    ) else {
            throw R13A11ProductCandidateConstructionError
                .capabilityNotAdmitted
        }
        let backend = try R04VideoToolboxBackend.makeNative(
            subjectID: binding.subjectID,
            modelAssetsIdentity: modelAssetsIdentity
        )
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry:
                AppleUpscaleCapabilityRegistry(
                    capabilities: [observation.capability]
                ),
            admissionScope: .product,
            policyIdentity: backend.routeIdentity
                .policyIdentity
        )
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        let session: any AppleUpscaleSession
        switch outcome {
        case .created(let created):
            session = created
        case .unavailable(let unavailable):
            throw R13A11ProductCandidateConstructionError
                .sessionUnavailable(unavailable.reason)
        case .rejected(let rejected):
            throw R13A11ProductCandidateConstructionError
                .sessionRejected(rejected.reason)
        case .failed(let failure):
            throw R13A11ProductCandidateConstructionError
                .sessionFailed(failure.reason)
        }
        let observedIdentity = await session.identity
        guard let validatedIdentity =
                validatedVideoToolboxSessionIdentity(
                    observedIdentity,
                    backend: backend,
                    observation: observation
                ) else {
            await session.cancel()
            throw R13A11ProductCandidateConstructionError
                .sessionRouteIdentityMismatch(
                    expectedBackendID:
                        backend.routeIdentity.backend.backendID,
                    actualBackendID:
                        observedIdentity.backend.backendID
                )
        }
        return R13ProductBackendSessionCandidate(
            session: session,
            routeIdentity: validatedIdentity,
            profile: intent == .quality
                ? .videoToolboxQuality
                : .videoToolboxLowLatency
        )
    }

    static func validatedVideoToolboxSessionIdentity(
        _ observedIdentity: AppleUpscaleRouteIdentity,
        backend: R04VideoToolboxBackend,
        observation: R04VTNativeCapabilityObservation
    ) -> AppleUpscaleRouteIdentity? {
        guard observation.route == backend.route,
              case .runnable = observation.status,
              observation.capability.id == backend.capabilityID,
              observation.capability.role == .primaryScaler,
              observation.capability.frameworkIdentity == "VideoToolbox",
              observation.capability.observationStatus == .observed,
              observation.capability.runtimeDisposition == .runnable,
              observation.capability.backendEligibility
                == .productQualified,
              let diagnostics = observation.diagnostics,
              let expectedIdentity = try?
                R04VideoToolboxObservedRouteIdentity.make(
                    declaredRouteIdentity: backend.routeIdentity,
                    route: observation.route,
                    diagnostics: diagnostics
                ),
              observedIdentity == expectedIdentity else {
            return nil
        }
        return observedIdentity
    }

    private static func makeMetalFXCandidate(
        route: R03ScaleRoute
    ) async throws -> R13ProductBackendSessionCandidate {
        let subjectID = metalFXSubjectID(route: route)
        let observation = try R05MetalFXSpatialBackend
            .observeNativeCapability(subjectID: subjectID)
        guard case .runnable = observation.status,
              observation.capability.backendEligibility
                == .productQualified else {
            throw R13A11ProductCandidateConstructionError
                .capabilityNotAdmitted
        }
        let backend = try R05MetalFXSpatialBackend.makeNative(
            subjectID: subjectID
        )
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry:
                AppleUpscaleCapabilityRegistry(
                    capabilities: [observation.capability]
                ),
            admissionScope: .product,
            policyIdentity: backend.routeIdentity
                .policyIdentity
        )
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        let session: any AppleUpscaleSession
        switch outcome {
        case .created(let created):
            session = created
        case .unavailable(let unavailable):
            throw R13A11ProductCandidateConstructionError
                .sessionUnavailable(unavailable.reason)
        case .rejected(let rejected):
            throw R13A11ProductCandidateConstructionError
                .sessionRejected(rejected.reason)
        case .failed(let failure):
            throw R13A11ProductCandidateConstructionError
                .sessionFailed(failure.reason)
        }
        let observedIdentity = await session.identity
        guard observedIdentity == backend.routeIdentity else {
            await session.cancel()
            throw R13A11ProductCandidateConstructionError
                .sessionRouteIdentityMismatch(
                    expectedBackendID:
                        backend.routeIdentity.backend.backendID,
                    actualBackendID:
                        observedIdentity.backend.backendID
                )
        }
        return R13ProductBackendSessionCandidate(
            session: session,
            routeIdentity: observedIdentity,
            profile: .metalFXSpatial
        )
    }

    private static func makeDirectCandidate(
        route: R03ScaleRoute,
        kind: R13ReleaseScalerKind,
        profile: R13ProductBackendProfile
    ) async throws -> R13ProductBackendSessionCandidate {
        let binding = try await makeDirectSession(
            route: route,
            modeBinding: R13ReleaseModeBinding(
                requestedMode: directMode(for: kind),
                enginePreference:
                    directEnginePreference(for: kind)
            )
        )
        return R13ProductBackendSessionCandidate(
            session: binding.session,
            routeIdentity: binding.routeIdentity,
            profile: profile
        )
    }

    private static func makeDirectBackend(
        route: R03ScaleRoute,
        kind: R13ReleaseScalerKind
    ) throws -> R03DeterministicBackend {
        switch kind {
        case .standardVImage:
            return try .makeProductQualifiedVImageStandard(
                route: route
            )
        case .highQualityVImage:
            return try .makeProductQualifiedVImageHighQuality(
                route: route
            )
        case .fastMPSBilinear:
            return try .makeProductQualifiedMPSBilinear(
                route: route
            )
        case .deterministicMPSLanczos:
            return try .makeProductQualifiedMPSLanczos(
                route: route
            )
        case .coreImageLanczos:
            return try .makeProductQualifiedCoreImage(
                mode: .lanczos,
                route: route
            )
        case .coreImageBicubic:
            return try .makeProductQualifiedCoreImage(
                mode: .bicubic,
                route: route
            )
        case .videoToolboxPixelTransfer:
            return try .makeProductQualifiedVTPixelTransfer(
                route: route
            )
        }
    }

    private static func exactNativeDeclaration(
        route: R03ScaleRoute,
        enginePreference: UpscaleEnginePreference
    ) -> R13A11ProductCandidateDeclaration? {
        switch enginePreference {
        case .videoToolboxQuality:
            return R13A11ProductCandidateDeclaration(
                declaredKind: .videoToolboxQuality,
                expectedBackendID:
                    videoToolboxSubjectID(
                        route: route,
                        intent: .quality
                    ).rawValue,
                profile: .videoToolboxQuality
            )
        case .videoToolboxLowLatency:
            return R13A11ProductCandidateDeclaration(
                declaredKind: .videoToolboxLowLatency,
                expectedBackendID:
                    videoToolboxSubjectID(
                        route: route,
                        intent: .lowLatency
                    ).rawValue,
                profile: .videoToolboxLowLatency
            )
        case .metalFXSpatial:
            return R13A11ProductCandidateDeclaration(
                declaredKind: .metalFXSpatial,
                expectedBackendID:
                    metalFXSubjectID(route: route).rawValue,
                profile: .metalFXSpatial
            )
        case .automatic,
             .accelerateVImageStandard,
             .accelerateVImageHighQuality,
             .mpsBilinear,
             .mpsLanczos,
             .coreImageLanczos,
             .coreImageBicubic,
             .videoToolboxPixelTransfer:
            return nil
        }
    }

    private static func nativeVideoToolboxIntents(
        for kind: R13ReleaseOrchestrationKind
    ) -> [R04VideoToolboxNativeRouteIntent] {
        switch kind {
        case .none:
            return []
        case .automatic:
            return [.quality, .lowLatency]
        case .quality:
            return [.quality]
        case .fast:
            return [.lowLatency]
        }
    }

    private static func videoToolboxSubjectID(
        route: R03ScaleRoute,
        intent: R04VideoToolboxNativeRouteIntent
    ) -> R04VideoToolboxSubjectID {
        switch (route, intent) {
        case (.scale3Over2, .quality):
            return .quality1p5xContract
        case (.scale3Over2, .lowLatency):
            return .lowLatency1p5x
        case (.scale2x, .quality):
            return .quality2x
        case (.scale2x, .lowLatency):
            return .lowLatency2x
        case (.scale4x, .quality):
            return .quality4x
        case (.scale4x, .lowLatency):
            return .lowLatency4x
        }
    }

    private static func metalFXSubjectID(
        route: R03ScaleRoute
    ) -> R05MetalFXSubjectID {
        switch route {
        case .scale3Over2:
            return .spatial1p5x
        case .scale2x:
            return .spatial2x
        case .scale4x:
            return .spatial4x
        }
    }

    static func fallbackProfiles(
        for kind: R13ReleaseOrchestrationKind
    ) -> [(
        kind: R13ReleaseScalerKind,
        profile: R13ProductBackendProfile
    )] {
        switch kind {
        case .none:
            return []
        case .automatic:
            return [
                (.highQualityVImage, .vImageHighQuality),
                (.deterministicMPSLanczos, .mpsLanczos),
                (.fastMPSBilinear, .mpsBilinear)
            ]
        case .quality:
            return [
                (.highQualityVImage, .vImageHighQuality),
                (.deterministicMPSLanczos, .mpsLanczos)
            ]
        case .fast:
            return [
                (.fastMPSBilinear, .mpsBilinear),
                (.deterministicMPSLanczos, .mpsLanczos),
                (.highQualityVImage, .vImageHighQuality)
            ]
        }
    }

    private static func directMode(
        for kind: R13ReleaseScalerKind
    ) -> UpscaleMode {
        switch kind {
        case .standardVImage,
             .highQualityVImage,
             .coreImageLanczos,
             .coreImageBicubic:
            return .quality
        case .fastMPSBilinear:
            return .fast
        case .deterministicMPSLanczos:
            return .deterministic
        case .videoToolboxPixelTransfer:
            return .fast
        }
    }

    private static func directEnginePreference(
        for kind: R13ReleaseScalerKind
    ) -> UpscaleEnginePreference {
        switch kind {
        case .standardVImage:
            return .accelerateVImageStandard
        case .highQualityVImage:
            return .accelerateVImageHighQuality
        case .fastMPSBilinear:
            return .mpsBilinear
        case .deterministicMPSLanczos:
            return .mpsLanczos
        case .coreImageLanczos:
            return .coreImageLanczos
        case .coreImageBicubic:
            return .coreImageBicubic
        case .videoToolboxPixelTransfer:
            return .videoToolboxPixelTransfer
        }
    }

    private static func cancel(
        _ candidates: [R13ProductBackendSessionCandidate]
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for candidate in candidates {
                group.addTask {
                    await candidate.session.cancel()
                }
            }
        }
    }
}

enum R13VideoToolboxProductCandidateAdmission {
    static func modelAssetsIdentity(
        binding: R04VideoToolboxNativeRouteBinding,
        observation: R04VTNativeCapabilityObservation
    ) -> AppleUpscaleModelAssetsIdentity? {
        guard observation.route == binding.route,
              case .runnable = observation.status,
              observation.capability.backendEligibility
                == .productQualified,
              let diagnostics = observation.diagnostics,
              R04VideoToolboxDiagnosticsValidator.validate(
                route: binding.route,
                diagnostics: diagnostics
              ) == .accepted else {
            return nil
        }

        switch binding.intent {
        case .quality:
            guard diagnostics.modelStatus == .ready else {
                return nil
            }
            return .appleConfigurationManaged(
                configurationIdentity:
                    binding.route.configurationIdentity,
                readiness: .ready
            )
        case .lowLatency:
            guard diagnostics.modelStatus == .notRequired else {
                return nil
            }
            return .notRequired
        }
    }
}
