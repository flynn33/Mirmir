import XCTest
@testable import Mirmir

struct R08TestRequestOptions {
    var requestID = "r08.request.12"
    var streamID = "r08.stream"
    var frameID = "r07.frame.101"
    var shotID = "r07.shot"
    var frameOrdinal: Int64 = 12
    var stateGeneration: UInt64 = 0
    var ashRequested = false
    var keyframe = false
    var proxyIdentity = R08AnalysisProxyIdentity.frozenAnalysisProxy
    var model: R08AnalysisModelIdentity?
    var platformID = "r08.test.platform"
    var ioContractID = "r08.analysis-input-output.q15-2x2.v1"
    var memoryBudget = R08AnalysisBudgets.functionalMemoryBytes
    var latencyBudget = R08AnalysisBudgets.functionalLatencyMicroseconds
    var executionMode = R08AnalysisExecutionMode.deterministicFixtureSimulation
    var zeroCopyAttempt = R08ZeroCopyAttempt.notApplicableDeterministicSimulation
    var aot = R08AOTCompilationDisposition.notRequested
}

enum R08TestSupport {
    static func model(
        hashCharacter: Character = "a",
        version: String = "1",
        artifactKind: R08AnalysisArtifactKind = .deterministicSimulationContract
    ) throws -> R08AnalysisModelIdentity {
        try R08AnalysisModelIdentity(
            modelID: "r08.fixture.analysis-model",
            modelVersion: version,
            artifactKind: artifactKind,
            contentSHA256: String(repeating: hashCharacter, count: 64),
            preprocessingID: "r08.fixture.preprocessing.bgra-512x288.v1",
            postprocessingID: "r08.fixture.postprocessing.q15-2x2.v1",
            calibrationID: "r08.fixture.calibration.q15.v1"
        )
    }

    static func request(
        _ options: R08TestRequestOptions = R08TestRequestOptions()
    ) throws -> R08AnalysisRequest {
        let selectedModel = try options.model ?? model()
        return R08AnalysisRequest(
            identity: try R08AnalysisRequestIdentity(
                requestID: options.requestID,
                streamID: options.streamID,
                frameID: options.frameID,
                shotID: options.shotID,
                frameOrdinal: options.frameOrdinal,
                stateGeneration: options.stateGeneration
            ),
            scheduleSignals: R08AnalysisScheduleSignals(
                ashRequested: options.ashRequested,
                keyframe: options.keyframe
            ),
            proxyIdentity: options.proxyIdentity,
            modelIdentity: selectedModel,
            platformProfile: try R08AnalysisPlatformProfile(profileID: options.platformID),
            ioContractIdentity: try R08AnalysisIOContractIdentity(options.ioContractID),
            budgets: try R08AnalysisBudgets(
                maximumMemoryBytes: options.memoryBudget,
                maximumLatencyMicroseconds: options.latencyBudget
            ),
            inputTransfer: try R08AnalysisInputTransfer(
                executionMode: options.executionMode,
                zeroCopyAttempt: options.zeroCopyAttempt
            ),
            aotCompilation: options.aot
        )
    }

    static func analyzed(
        _ outcome: R08AnalysisOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> R08AnalysisResult {
        guard case .analyzed(let result) = outcome else {
            XCTFail("Expected analyzed R08 outcome, got \(outcome)", file: file, line: line)
            throw R08TestError.unexpectedOutcome
        }
        return result
    }

    static func bypass(
        _ outcome: R08AnalysisOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> R08AnalysisBypass {
        guard case .bypassed(let bypass) = outcome else {
            XCTFail("Expected bypassed R08 outcome, got \(outcome)", file: file, line: line)
            throw R08TestError.unexpectedOutcome
        }
        return bypass
    }
}

enum R08TestError: Error {
    case unexpectedOutcome
}

actor R08TestCommitGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
