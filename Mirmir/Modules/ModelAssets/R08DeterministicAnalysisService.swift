import Foundation

struct R08AnalysisResourceMeasurement: Hashable, Sendable {
    static let deterministicFixtureNominal = R08AnalysisResourceMeasurement(
        validatedWorkingSetBytes: 4_096,
        validatedElapsedMicroseconds: 1_000
    )

    let workingSetBytes: Int64
    let elapsedMicroseconds: Int64

    init(workingSetBytes: Int64, elapsedMicroseconds: Int64) throws {
        guard workingSetBytes >= 0 else {
            throw R08AnalysisContractError.invalidBudget(
                role: "measured_working_set_bytes",
                value: workingSetBytes
            )
        }
        guard elapsedMicroseconds >= 0 else {
            throw R08AnalysisContractError.invalidBudget(
                role: "measured_elapsed_microseconds",
                value: elapsedMicroseconds
            )
        }
        self.workingSetBytes = workingSetBytes
        self.elapsedMicroseconds = elapsedMicroseconds
    }

    private init(
        validatedWorkingSetBytes: Int64,
        validatedElapsedMicroseconds: Int64
    ) {
        precondition(validatedWorkingSetBytes >= 0)
        precondition(validatedElapsedMicroseconds >= 0)
        workingSetBytes = validatedWorkingSetBytes
        elapsedMicroseconds = validatedElapsedMicroseconds
    }
}

struct R08OwnedAnalysisInputCopy: Hashable, Sendable {
    let bytes: [UInt8]
    let transfer: R08AnalysisInputTransfer
    let nativeExecution = R08NativeExecutionDisposition.notObserved
}

enum R08DeterministicInputCopy {
    static func make(
        sourceBytes: [UInt8],
        zeroCopyAttempt: R08ZeroCopyAttempt
    ) throws -> R08OwnedAnalysisInputCopy {
        let transfer = try R08AnalysisInputTransfer(
            executionMode: .nativeCoreAI,
            zeroCopyAttempt: zeroCopyAttempt
        )
        guard transfer.disposition == .copiedDeterministicFallback else {
            throw R08AnalysisContractError.invalidInputTransferBinding
        }
        let ownedBytes = sourceBytes.withUnsafeBufferPointer { buffer in
            Array(buffer)
        }
        return R08OwnedAnalysisInputCopy(bytes: ownedBytes, transfer: transfer)
    }
}

enum R08AOTExecutionTrace: String, Hashable, Sendable {
    case runtimeSpecialization = "runtime_specialization"
    case deterministicAOTFixtureSimulation = "deterministic_aot_fixture_simulation"
    case runtimeFallbackNativeAOTNotObserved = "runtime_fallback_native_aot_not_observed"
}

extension R08AnalysisResourceUsage {
    var aotExecutionTrace: R08AOTExecutionTrace {
        switch aotCompilation {
        case .notRequested:
            return .runtimeSpecialization
        case .behaviorallyEquivalent:
            return .deterministicAOTFixtureSimulation
        case .unavailable:
            return .runtimeFallbackNativeAOTNotObserved
        }
    }
}

struct R08AnalysisSpecializationKey: Hashable, Sendable {
    let modelSHA256: String
    let platformProfile: R08AnalysisPlatformProfile
    let ioContractIdentity: R08AnalysisIOContractIdentity
}

struct R08AnalysisServiceSnapshot: Equatable, Sendable {
    let stateGeneration: UInt64
    let streamID: String?
    let shotID: String?
    let lastFrameOrdinal: Int64?
    let specializationKeysOldestFirst: [R08AnalysisSpecializationKey]
    let analyzedCount: Int
    let specializationCount: Int
    let cacheHitCount: Int
}

actor R08DeterministicAnalysisService: R08CoreAIAnalysisService {
    static let defaultCacheCapacity = 2

    private let executionIdentity = R08AnalysisExecutionIdentity.deterministicFixtureV1
    private let cacheCapacity: Int
    private let availabilityBypassReason: R08AnalysisBypassReason?
    private let resourceMeasurement: R08AnalysisResourceMeasurement
    private let analysisHeadProvider: @Sendable (R08AnalysisRequest) throws -> R08AnalysisHeads
    private let beforeCommit: @Sendable () async -> Void

    private var stateGeneration: UInt64 = 0
    private var streamID: String?
    private var shotID: String?
    private var lastFrameOrdinal: Int64?
    private var specializationKeysOldestFirst: [R08AnalysisSpecializationKey] = []
    private var analyzedCount = 0
    private var specializationCount = 0
    private var cacheHitCount = 0
    private var analysisInFlight = false

    init(
        cacheCapacity: Int = R08DeterministicAnalysisService.defaultCacheCapacity,
        availabilityBypassReason: R08AnalysisBypassReason? = nil,
        resourceMeasurement: R08AnalysisResourceMeasurement = .deterministicFixtureNominal,
        analysisHeadProvider: (@Sendable (R08AnalysisRequest) throws -> R08AnalysisHeads)? = nil,
        beforeCommit: @escaping @Sendable () async -> Void = {}
    ) throws {
        guard (1...8).contains(cacheCapacity) else {
            throw R08AnalysisContractError.invalidCacheCapacity(cacheCapacity)
        }
        self.cacheCapacity = cacheCapacity
        self.availabilityBypassReason = availabilityBypassReason
        self.resourceMeasurement = resourceMeasurement
        self.analysisHeadProvider = analysisHeadProvider ?? { request in
            try R08DeterministicAnalysisHeadFactory.make(request: request)
        }
        self.beforeCommit = beforeCommit
    }

    func analyze(_ request: R08AnalysisRequest) async throws -> R08AnalysisOutcome {
        if let reason = preflightBypassReason(for: request) {
            let outcome = bypass(request, reason: reason)
            if reason == .cancelled {
                _ = try resetState(reason: .cancellation)
            }
            return outcome
        }

        analysisInFlight = true
        defer { analysisInFlight = false }
        return try await performAnalysis(request)
    }

    func resetState(reason _: R08AnalysisStateResetReason) throws -> UInt64 {
        let next = stateGeneration.addingReportingOverflow(1)
        guard !next.overflow else {
            throw R08AnalysisContractError.stateGenerationOverflow
        }
        stateGeneration = next.partialValue
        streamID = nil
        shotID = nil
        lastFrameOrdinal = nil
        return stateGeneration
    }

    func snapshot() -> R08AnalysisServiceSnapshot {
        R08AnalysisServiceSnapshot(
            stateGeneration: stateGeneration,
            streamID: streamID,
            shotID: shotID,
            lastFrameOrdinal: lastFrameOrdinal,
            specializationKeysOldestFirst: specializationKeysOldestFirst,
            analyzedCount: analyzedCount,
            specializationCount: specializationCount,
            cacheHitCount: cacheHitCount
        )
    }
}

private extension R08DeterministicAnalysisService {
    func performAnalysis(_ request: R08AnalysisRequest) async throws -> R08AnalysisOutcome {
        let key = R08AnalysisSpecializationKey(
            modelSHA256: request.modelIdentity.contentSHA256,
            platformProfile: request.platformProfile,
            ioContractIdentity: request.ioContractIdentity
        )
        let cacheDisposition: R08AnalysisCacheDisposition =
            specializationKeysOldestFirst.contains(key) ? .hit : .specialized

        do {
            try Task.checkCancellation()
            let heads = try analysisHeadProvider(request)
            await beforeCommit()
            try Task.checkCancellation()
            guard request.stateGeneration == stateGeneration else {
                return bypass(
                    request,
                    reason: .stateGenerationMismatch(
                        expected: stateGeneration,
                        actual: request.stateGeneration
                    )
                )
            }
            if let lastFrameOrdinal,
               let reason = frameOrderBypassReason(
                   previous: lastFrameOrdinal,
                   actual: request.frameOrdinal
               ) {
                return bypass(
                    request,
                    reason: reason
                )
            }
            let result = try R08AnalysisResult(
                request: request,
                executionIdentity: executionIdentity,
                heads: heads,
                resourceUsage: R08AnalysisResourceUsage(
                    memoryBytes: resourceMeasurement.workingSetBytes,
                    latencyMicroseconds: resourceMeasurement.elapsedMicroseconds,
                    zeroCopyDisposition: request.zeroCopyDisposition,
                    aotCompilation: request.aotCompilation
                ),
                stateReceipt: R08AnalysisStateReceipt(
                    generation: stateGeneration,
                    frameOrdinal: request.frameOrdinal
                ),
                cacheDisposition: cacheDisposition
            )
            commit(
                key: key,
                streamID: request.streamID,
                shotID: request.shotID,
                frameOrdinal: request.frameOrdinal
            )
            return .analyzed(result)
        } catch is CancellationError {
            let outcome = bypass(request, reason: .cancelled)
            _ = try resetState(reason: .cancellation)
            return outcome
        } catch let error as R08AnalysisContractError {
            return bypass(request, reason: outputBypassReason(error))
        }
    }

    func preflightBypassReason(
        for request: R08AnalysisRequest
    ) -> R08AnalysisBypassReason? {
        guard isValidSimulationRequest(request) else { return .identityInvalid }
        if let availabilityBypassReason { return availabilityBypassReason }
        if resourceMeasurement.workingSetBytes > request.budgets.maximumMemoryBytes {
            return .memoryBudgetExceeded(
                required: resourceMeasurement.workingSetBytes,
                limit: request.budgets.maximumMemoryBytes
            )
        }
        if resourceMeasurement.elapsedMicroseconds > request.budgets.maximumLatencyMicroseconds {
            return .latencyBudgetExceeded(
                required: resourceMeasurement.elapsedMicroseconds,
                limit: request.budgets.maximumLatencyMicroseconds
            )
        }
        guard request.stateGeneration == stateGeneration else {
            return .stateGenerationMismatch(
                expected: stateGeneration,
                actual: request.stateGeneration
            )
        }
        if let streamID, request.streamID != streamID {
            return .streamIdentityMismatch(expected: streamID, actual: request.streamID)
        }
        if let shotID, request.shotID != shotID {
            return .shotIdentityMismatch(expected: shotID, actual: request.shotID)
        }
        if let lastFrameOrdinal,
           let reason = frameOrderBypassReason(
               previous: lastFrameOrdinal,
               actual: request.frameOrdinal
           ) {
            return reason
        }
        guard request.scheduleTrigger != nil else { return .unscheduledFrame }
        if analysisInFlight { return .busy }
        if Task.isCancelled { return .cancelled }
        return nil
    }

    func isValidSimulationRequest(_ request: R08AnalysisRequest) -> Bool {
        request.proxyIdentity == .frozenAnalysisProxy
            && request.modelIdentity.artifactKind == .deterministicSimulationContract
            && request.inputTransfer.executionMode == executionIdentity.mode
            && request.zeroCopyDisposition == .notUsedDeterministicSimulation
    }

    func frameOrderBypassReason(
        previous: Int64,
        actual: Int64
    ) -> R08AnalysisBypassReason? {
        if actual == previous { return .duplicateFrameOrdinal(actual) }
        if actual < previous {
            return .staleFrameOrdinal(previous: previous, actual: actual)
        }
        return nil
    }

    func outputBypassReason(
        _ error: R08AnalysisContractError
    ) -> R08AnalysisBypassReason {
        switch error {
        case .forbiddenPixelOutput(let id):
            return .pixelOutputForbidden(id)
        case .forbiddenModelDecisionAuthority(let id):
            return .modelDecisionAuthorityForbidden(id)
        default:
            return .outputInvalid
        }
    }

    func bypass(
        _ request: R08AnalysisRequest,
        reason: R08AnalysisBypassReason
    ) -> R08AnalysisOutcome {
        .bypassed(
            R08AnalysisBypass(
                request: request,
                executionIdentity: executionIdentity,
                reason: reason
            )
        )
    }

    func commit(
        key: R08AnalysisSpecializationKey,
        streamID: String,
        shotID: String,
        frameOrdinal: Int64
    ) {
        if let index = specializationKeysOldestFirst.firstIndex(of: key) {
            specializationKeysOldestFirst.remove(at: index)
            cacheHitCount += 1
        } else {
            specializationCount += 1
        }
        specializationKeysOldestFirst.append(key)
        if specializationKeysOldestFirst.count > cacheCapacity {
            specializationKeysOldestFirst.removeFirst(
                specializationKeysOldestFirst.count - cacheCapacity
            )
        }
        analyzedCount += 1
        self.streamID = streamID
        self.shotID = shotID
        lastFrameOrdinal = frameOrdinal
    }
}

private enum R08DeterministicAnalysisHeadFactory {
    static func make(request: R08AnalysisRequest) throws -> R08AnalysisHeads {
        switch request.aotCompilation {
        case .notRequested:
            return try makeRuntimeSpecialized(request)
        case .behaviorallyEquivalent:
            return try makeDeterministicAOTFixtureSimulation(request)
        case .unavailable:
            return try makeRuntimeSpecialized(request)
        }
    }

    private static func makeRuntimeSpecialized(
        _ request: R08AnalysisRequest
    ) throws -> R08AnalysisHeads {
        try makeDeterministicHeads(request)
    }

    private static func makeDeterministicAOTFixtureSimulation(
        _ request: R08AnalysisRequest
    ) throws -> R08AnalysisHeads {
        try makeDeterministicHeads(request)
    }

    private static func makeDeterministicHeads(
        _ request: R08AnalysisRequest
    ) throws -> R08AnalysisHeads {
        let seed = request.frameOrdinal % 251
        let face = try q15(role: "face_skin_protection") { row, column in
            row == column ? 22_000 + Int64(row * 1_000) + seed : 0
        }
        let text = try q15(role: "text_line_art_protection") { row, column in
            row == 1 || column == 1 ? 24_000 + Int64(row * 500 + column * 250) + seed : 0
        }
        let animation = try q15(role: "animation_ui_likelihood") { row, column in
            8_000 + (Int64(row * 733 + column * 421) + seed * 17) % 12_000
        }
        let noiseCompression = try q15(role: "noise_compression_severity") { row, column in
            2_000 + (Int64(row * 499 + column * 307) + seed * 11) % 10_000
        }
        let blurMotionBlur = try q15(role: "blur_motion_blur_estimate") { row, column in
            1_000 + (Int64(row * 389 + column * 211) + seed * 13) % 11_000
        }
        let aliasingRinging = try q15(role: "aliasing_ringing_risk") { row, column in
            1_500 + (Int64(row * 347 + column * 191) + seed * 7) % 9_500
        }
        let texture = try q15(role: "texture_detail_confidence") { row, column in
            26_000 - (Int64(row * 137 + column * 101) + seed * 5) % 6_000
        }
        let motionOcclusion = try q15(role: "motion_reliability_occlusion_risk") { row, column in
            20_000 - (Int64(row * 127 + column * 83) + seed * 3) % 5_000
        }
        return try R08AnalysisHeads(
            protection: R08ProtectionHeads(
                faceSkinQ15: face,
                textLineArtQ15: text
            ),
            condition: R08ConditionHeads(
                animationUILikelihoodQ15: animation,
                noiseCompressionSeverityQ15: noiseCompression,
                blurMotionBlurEstimateQ15: blurMotionBlur
            ),
            riskConfidence: R08RiskConfidenceHeads(
                aliasingRingingRiskQ15: aliasingRinging,
                textureDetailConfidenceQ15: texture,
                motionReliabilityOcclusionRiskQ15: motionOcclusion
            ),
            noReferenceQualityQ15: try R08Q15Value(
                23_000 - seed,
                role: "no_reference_quality"
            ),
            sourceClassification: R08SourceClassificationResult(
                classification: .mixed,
                confidenceQ15: try R08Q15Value(
                    22_500,
                    role: "source_classification_confidence"
                )
            )
        )
    }

    private static func q15(
        role: String,
        value: (_ row: Int, _ column: Int) -> Int64
    ) throws -> R08Q15Map {
        try R08Q15Map(
            width: R08AnalysisHeads.width,
            height: R08AnalysisHeads.height,
            samples: samples(value),
            role: role
        )
    }

    private static func samples(
        _ value: (_ row: Int, _ column: Int) -> Int64
    ) -> [Int64] {
        (0..<R08AnalysisHeads.height).flatMap { row in
            (0..<R08AnalysisHeads.width).map { column in
                value(row, column)
            }
        }
    }
}
