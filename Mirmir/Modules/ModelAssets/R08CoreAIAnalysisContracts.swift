import Foundation

enum R08AnalysisContractError: Error, Equatable, Sendable {
    case invalidIdentity(field: String)
    case invalidSHA256(field: String)
    case invalidDimension(role: String, value: Int)
    case sampleCountOverflow(width: Int, height: Int)
    case sampleCountMismatch(role: String, expected: Int, actual: Int)
    case sampleOutOfRange(role: String, index: Int, value: Int64)
    case headGeometryMismatch(role: String, expectedWidth: Int, expectedHeight: Int)
    case missingOutputHead(String)
    case duplicateOutputHead(String)
    case unexpectedOutputHead(String)
    case outputHeadKindMismatch(String)
    case forbiddenPixelOutput(String)
    case forbiddenModelDecisionAuthority(String)
    case invalidFrameOrdinal(Int64)
    case invalidBudget(role: String, value: Int64)
    case invalidCacheCapacity(Int)
    case invalidSimulationBinding
    case invalidInputTransferBinding
    case stateGenerationOverflow
}
enum R08AnalysisArtifactKind: String, Hashable, Sendable {
    case deterministicSimulationContract = "deterministic_simulation_contract"
    case coreAIModel = "core_ai_model"
}

struct R08AnalysisModelIdentity: Hashable, Sendable {
    let modelID: String
    let modelVersion: String
    let artifactKind: R08AnalysisArtifactKind
    let contentSHA256: String
    let preprocessingID: String
    let postprocessingID: String
    let calibrationID: String

    init(
        modelID: String,
        modelVersion: String,
        artifactKind: R08AnalysisArtifactKind,
        contentSHA256: String,
        preprocessingID: String,
        postprocessingID: String,
        calibrationID: String
    ) throws {
        self.modelID = try R08AnalysisValidation.identity(modelID, field: "model_id")
        self.modelVersion = try R08AnalysisValidation.identity(
            modelVersion,
            field: "model_version"
        )
        self.artifactKind = artifactKind
        self.contentSHA256 = try R08AnalysisValidation.sha256(
            contentSHA256,
            field: "content_sha256"
        )
        self.preprocessingID = try R08AnalysisValidation.identity(
            preprocessingID,
            field: "preprocessing_id"
        )
        self.postprocessingID = try R08AnalysisValidation.identity(
            postprocessingID,
            field: "postprocessing_id"
        )
        self.calibrationID = try R08AnalysisValidation.identity(
            calibrationID,
            field: "calibration_id"
        )
    }
}

struct R08AnalysisProxyIdentity: Hashable, Sendable {
    static let frozenAnalysisProxySHA256 =
        "bfcae4462f1720afc1c36fc5660130442dcd28f9bd55f46c041b6274fb6b3590"

    static let frozenAnalysisProxy = makeFrozenAnalysisProxy()

    let fixtureID: String
    let contentSHA256: String
    let width: Int
    let height: Int
    let pixelFormat: String

    init(
        fixtureID: String,
        contentSHA256: String,
        width: Int,
        height: Int,
        pixelFormat: String
    ) throws {
        guard width > 0 else {
            throw R08AnalysisContractError.invalidDimension(role: "proxy_width", value: width)
        }
        guard height > 0 else {
            throw R08AnalysisContractError.invalidDimension(role: "proxy_height", value: height)
        }
        self.fixtureID = try R08AnalysisValidation.identity(fixtureID, field: "fixture_id")
        self.contentSHA256 = try R08AnalysisValidation.sha256(
            contentSHA256,
            field: "proxy_content_sha256"
        )
        self.width = width
        self.height = height
        self.pixelFormat = try R08AnalysisValidation.identity(
            pixelFormat,
            field: "pixel_format"
        )
    }

    private static func makeFrozenAnalysisProxy() -> R08AnalysisProxyIdentity {
        do {
            return try R08AnalysisProxyIdentity(
                fixtureID: "analysis-proxy",
                contentSHA256: frozenAnalysisProxySHA256,
                width: 512,
                height: 288,
                pixelFormat: "BGRA"
            )
        } catch {
            preconditionFailure("Invalid internal R08 proxy identity: \(error)")
        }
    }
}

enum R08AnalysisExecutionMode: String, Hashable, Sendable {
    case deterministicFixtureSimulation = "deterministic_fixture_simulation"
    case nativeCoreAI = "native_core_ai"
}

enum R08NativeExecutionDisposition: String, Hashable, Sendable {
    case notObserved = "not_observed"
    case observed = "observed"
}

struct R08AnalysisExecutionIdentity: Hashable, Sendable {
    static let deterministicFixtureV1 = makeDeterministicFixtureV1()

    let runtimeID: String
    let referencedCapabilityID: String
    let mode: R08AnalysisExecutionMode
    let nativeExecution: R08NativeExecutionDisposition

    init(
        runtimeID: String,
        referencedCapabilityID: String,
        mode: R08AnalysisExecutionMode,
        nativeExecution: R08NativeExecutionDisposition
    ) throws {
        guard (mode == .deterministicFixtureSimulation && nativeExecution == .notObserved)
                || (mode == .nativeCoreAI && nativeExecution == .observed) else {
            throw R08AnalysisContractError.invalidSimulationBinding
        }
        self.runtimeID = try R08AnalysisValidation.identity(runtimeID, field: "runtime_id")
        self.referencedCapabilityID = try R08AnalysisValidation.identity(
            referencedCapabilityID,
            field: "referenced_capability_id"
        )
        self.mode = mode
        self.nativeExecution = nativeExecution
    }

    private static func makeDeterministicFixtureV1() -> R08AnalysisExecutionIdentity {
        do {
            return try R08AnalysisExecutionIdentity(
                runtimeID: "r08.deterministic-analysis-fixture-simulation.v1",
                referencedCapabilityID: "A18",
                mode: .deterministicFixtureSimulation,
                nativeExecution: .notObserved
            )
        } catch {
            preconditionFailure("Invalid internal R08 execution identity: \(error)")
        }
    }
}

enum R08AnalysisScheduleTrigger: String, CaseIterable, Hashable, Sendable {
    static let periodicProxyIntervalFrames = 12

    case periodicProxyFrame = "periodic_proxy_frame"
    case keyframe
    case ashRequestedFrame = "ash_requested_frame"

    static let precedence: [R08AnalysisScheduleTrigger] = [
        .ashRequestedFrame,
        .keyframe,
        .periodicProxyFrame
    ]
}

struct R08AnalysisScheduleSignals: Hashable, Sendable {
    let ashRequested: Bool
    let keyframe: Bool
}

enum R08AnalysisScheduleResolver {
    static func resolve(
        signals: R08AnalysisScheduleSignals,
        frameOrdinal: Int64
    ) -> R08AnalysisScheduleTrigger? {
        if signals.ashRequested { return .ashRequestedFrame }
        if signals.keyframe { return .keyframe }
        if frameOrdinal.isMultiple(
            of: Int64(R08AnalysisScheduleTrigger.periodicProxyIntervalFrames)
        ) {
            return .periodicProxyFrame
        }
        return nil
    }
}

enum R08ZeroCopyDisposition: String, Hashable, Sendable {
    case used
    case copiedDeterministicFallback = "copied_deterministic_fallback"
    case notUsedDeterministicSimulation = "not_used_deterministic_simulation"
}

enum R08ZeroCopyAttempt: String, Hashable, Sendable {
    case notApplicableDeterministicSimulation = "not_applicable_deterministic_simulation"
    case succeeded
    case unavailable
    case failed
}

struct R08AnalysisInputTransfer: Hashable, Sendable {
    let executionMode: R08AnalysisExecutionMode
    let zeroCopyAttempt: R08ZeroCopyAttempt
    let disposition: R08ZeroCopyDisposition

    init(
        executionMode: R08AnalysisExecutionMode,
        zeroCopyAttempt: R08ZeroCopyAttempt
    ) throws {
        let disposition = try R08AnalysisInputTransferResolver.resolve(
            executionMode: executionMode,
            zeroCopyAttempt: zeroCopyAttempt
        )
        self.executionMode = executionMode
        self.zeroCopyAttempt = zeroCopyAttempt
        self.disposition = disposition
    }
}

enum R08AnalysisInputTransferResolver {
    static func resolve(
        executionMode: R08AnalysisExecutionMode,
        zeroCopyAttempt: R08ZeroCopyAttempt
    ) throws -> R08ZeroCopyDisposition {
        switch (executionMode, zeroCopyAttempt) {
        case (.deterministicFixtureSimulation, .notApplicableDeterministicSimulation):
            return .notUsedDeterministicSimulation
        case (.nativeCoreAI, .succeeded):
            return .used
        case (.nativeCoreAI, .unavailable), (.nativeCoreAI, .failed):
            return .copiedDeterministicFallback
        case (.deterministicFixtureSimulation, _),
             (.nativeCoreAI, .notApplicableDeterministicSimulation):
            throw R08AnalysisContractError.invalidInputTransferBinding
        }
    }
}

enum R08AOTCompilationDisposition: String, Hashable, Sendable {
    case notRequested = "not_requested"
    case behaviorallyEquivalent = "behaviorally_equivalent"
    case unavailable
}

struct R08AnalysisPlatformProfile: Hashable, Sendable {
    let profileID: String

    init(profileID: String) throws {
        self.profileID = try R08AnalysisValidation.identity(
            profileID,
            field: "platform_profile_id"
        )
    }
}

struct R08AnalysisIOContractIdentity: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        self.rawValue = try R08AnalysisValidation.identity(
            rawValue,
            field: "io_contract_id"
        )
    }
}

struct R08AnalysisBudgets: Hashable, Sendable {
    static let functionalMemoryBytes: Int64 = 67_108_864
    static let functionalLatencyMicroseconds: Int64 = 20_000

    let maximumMemoryBytes: Int64
    let maximumLatencyMicroseconds: Int64

    init(maximumMemoryBytes: Int64, maximumLatencyMicroseconds: Int64) throws {
        guard maximumMemoryBytes == Self.functionalMemoryBytes else {
            throw R08AnalysisContractError.invalidBudget(
                role: "maximum_memory_bytes",
                value: maximumMemoryBytes
            )
        }
        guard maximumLatencyMicroseconds == Self.functionalLatencyMicroseconds else {
            throw R08AnalysisContractError.invalidBudget(
                role: "maximum_latency_microseconds",
                value: maximumLatencyMicroseconds
            )
        }
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumLatencyMicroseconds = maximumLatencyMicroseconds
    }
}

struct R08AnalysisRequestIdentity: Hashable, Sendable {
    let requestID: String
    let streamID: String
    let frameID: String
    let shotID: String
    let frameOrdinal: Int64
    let stateGeneration: UInt64

    init(
        requestID: String,
        streamID: String,
        frameID: String,
        shotID: String,
        frameOrdinal: Int64,
        stateGeneration: UInt64
    ) throws {
        guard frameOrdinal >= 0 else {
            throw R08AnalysisContractError.invalidFrameOrdinal(frameOrdinal)
        }
        self.requestID = try R08AnalysisValidation.identity(requestID, field: "request_id")
        self.streamID = try R08AnalysisValidation.identity(streamID, field: "stream_id")
        self.frameID = try R08AnalysisValidation.identity(frameID, field: "frame_id")
        self.shotID = try R08AnalysisValidation.identity(shotID, field: "shot_id")
        self.frameOrdinal = frameOrdinal
        self.stateGeneration = stateGeneration
    }
}

struct R08AnalysisRequest: Hashable, Sendable {
    let identity: R08AnalysisRequestIdentity
    let scheduleSignals: R08AnalysisScheduleSignals
    let proxyIdentity: R08AnalysisProxyIdentity
    let modelIdentity: R08AnalysisModelIdentity
    let platformProfile: R08AnalysisPlatformProfile
    let ioContractIdentity: R08AnalysisIOContractIdentity
    let budgets: R08AnalysisBudgets
    let inputTransfer: R08AnalysisInputTransfer
    let aotCompilation: R08AOTCompilationDisposition

    init(
        identity: R08AnalysisRequestIdentity,
        scheduleSignals: R08AnalysisScheduleSignals,
        proxyIdentity: R08AnalysisProxyIdentity,
        modelIdentity: R08AnalysisModelIdentity,
        platformProfile: R08AnalysisPlatformProfile,
        ioContractIdentity: R08AnalysisIOContractIdentity,
        budgets: R08AnalysisBudgets,
        inputTransfer: R08AnalysisInputTransfer,
        aotCompilation: R08AOTCompilationDisposition
    ) {
        self.identity = identity
        self.scheduleSignals = scheduleSignals
        self.proxyIdentity = proxyIdentity
        self.modelIdentity = modelIdentity
        self.platformProfile = platformProfile
        self.ioContractIdentity = ioContractIdentity
        self.budgets = budgets
        self.inputTransfer = inputTransfer
        self.aotCompilation = aotCompilation
    }

    var requestID: String { identity.requestID }
    var streamID: String { identity.streamID }
    var frameID: String { identity.frameID }
    var shotID: String { identity.shotID }
    var frameOrdinal: Int64 { identity.frameOrdinal }
    var stateGeneration: UInt64 { identity.stateGeneration }
    var scheduleTrigger: R08AnalysisScheduleTrigger? {
        R08AnalysisScheduleResolver.resolve(
            signals: scheduleSignals,
            frameOrdinal: frameOrdinal
        )
    }
    var zeroCopyDisposition: R08ZeroCopyDisposition { inputTransfer.disposition }
}

enum R08AnalysisPixelAuthority: String, Hashable, Sendable {
    case analysisOnlyNoPixelOutput = "analysis_only_no_pixel_output"
}

enum R08AnalysisCacheDisposition: String, Hashable, Sendable {
    case specialized
    case hit
}

struct R08AnalysisResourceUsage: Hashable, Sendable {
    let memoryBytes: Int64
    let latencyMicroseconds: Int64
    let zeroCopyDisposition: R08ZeroCopyDisposition
    let aotCompilation: R08AOTCompilationDisposition
}

struct R08AnalysisStateReceipt: Hashable, Sendable {
    let generation: UInt64
    let frameOrdinal: Int64
}

enum R08AnalysisBypassReason: Equatable, Sendable {
    case unsupportedOS
    case frameworkUnavailable
    case assetsAbsent
    case disabledByPolicy
    case identityInvalid
    case outputInvalid
    case unscheduledFrame
    case memoryBudgetExceeded(required: Int64, limit: Int64)
    case latencyBudgetExceeded(required: Int64, limit: Int64)
    case cancelled
    case busy
    case streamIdentityMismatch(expected: String, actual: String)
    case shotIdentityMismatch(expected: String, actual: String)
    case stateGenerationMismatch(expected: UInt64, actual: UInt64)
    case duplicateFrameOrdinal(Int64)
    case staleFrameOrdinal(previous: Int64, actual: Int64)
    case pixelOutputForbidden(String)
    case modelDecisionAuthorityForbidden(String)
}

struct R08AnalysisBypass: Equatable, Sendable {
    let request: R08AnalysisRequest
    let executionIdentity: R08AnalysisExecutionIdentity
    let reason: R08AnalysisBypassReason
    let pixelAuthority = R08AnalysisPixelAuthority.analysisOnlyNoPixelOutput
}

enum R08AnalysisOutcome: Equatable, Sendable {
    case analyzed(R08AnalysisResult)
    case bypassed(R08AnalysisBypass)
}

protocol R08CoreAIAnalysisService: Sendable {
    func analyze(_ request: R08AnalysisRequest) async throws -> R08AnalysisOutcome
    func resetState(reason: R08AnalysisStateResetReason) async throws -> UInt64
}

enum R08AnalysisStateResetReason: String, CaseIterable, Hashable, Sendable {
    case sceneCut = "scene_cut"
    case discontinuity
    case cancellation
    case endOfStream = "end_of_stream"
}

enum R08AnalysisValidation {
    static let maximumMapDimension = 64
    static let maximumMapSampleCount = 4_096

    static func identity(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value else {
            throw R08AnalysisContractError.invalidIdentity(field: field)
        }
        return value
    }

    static func sha256(_ value: String, field: String) throws -> String {
        guard value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              }) else {
            throw R08AnalysisContractError.invalidSHA256(field: field)
        }
        return value
    }

    static func sampleCount(width: Int, height: Int, role: String) throws -> Int {
        guard (1...maximumMapDimension).contains(width) else {
            throw R08AnalysisContractError.invalidDimension(role: "\(role)_width", value: width)
        }
        guard (1...maximumMapDimension).contains(height) else {
            throw R08AnalysisContractError.invalidDimension(role: "\(role)_height", value: height)
        }
        let count = width.multipliedReportingOverflow(by: height)
        guard !count.overflow else {
            throw R08AnalysisContractError.sampleCountOverflow(width: width, height: height)
        }
        guard count.partialValue <= maximumMapSampleCount else {
            throw R08AnalysisContractError.sampleCountMismatch(
                role: role,
                expected: maximumMapSampleCount,
                actual: count.partialValue
            )
        }
        return count.partialValue
    }
}
