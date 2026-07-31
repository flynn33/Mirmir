import CoreMedia
import XCTest
@testable import Mirmir

struct R13ProductASHTestCandidate {
    let identity: AppleUpscaleRouteIdentity
    let session: R13ProductASHTestSession
    let candidate: R13ProductBackendSessionCandidate
}

enum R13ProductASHTestBehavior: Sendable {
    case processed
    case unavailable
    case failed
}

struct R13ProductASHTestSessionSnapshot:
    Equatable,
    Sendable {
    let submittedSequenceNumbers: [Int]
    let resetReasons: [AppleUpscaleResetReason]
    let finishCount: Int
    let cancelCount: Int
}

actor R13ProductASHTestSession: AppleUpscaleSession {
    nonisolated let identity: AppleUpscaleRouteIdentity

    private let processingIdentity: AppleUpscaleProcessingIdentity
    private let unavailable: AppleUpscaleBackendUnavailable
    private let failure: AppleUpscaleBackendFailed
    private let script: [R13ProductASHTestBehavior]
    private var submitCount = 0
    private var submittedSequenceNumbers: [Int] = []
    private var resetReasons: [AppleUpscaleResetReason] = []
    private var finishCount = 0
    private var cancelCount = 0

    init(
        identity: AppleUpscaleRouteIdentity,
        script: [R13ProductASHTestBehavior]
    ) throws {
        self.identity = identity
        processingIdentity = try AppleUpscaleProcessingIdentity(
            route: identity,
            fallbackHistory: []
        )
        unavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: processingIdentity,
            reason: "test_backend_unavailable"
        )
        failure = try AppleUpscaleBackendFailed(
            processingIdentity: processingIdentity,
            reason: "test_backend_failed"
        )
        self.script = script
    }

    func submit(
        _ frame: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        submittedSequenceNumbers.append(frame.sequenceNumber)
        let behavior = script.isEmpty
            ? .processed
            : script[min(submitCount, script.count - 1)]
        submitCount += 1
        frame.resourceLifetimeToken.release()
        switch behavior {
        case .processed:
            do {
                return .processed(
                    try AppleUpscaleProcessedFrame(
                        sequenceNumber: frame.sequenceNumber,
                        pixelBuffer: frame.pixelBuffer,
                        presentationTimestamp:
                            frame.presentationTimestamp,
                        duration: frame.duration,
                        colorDescription: frame.colorDescription,
                        metadataIdentity: frame.metadataIdentity,
                        resourceLifetimeToken:
                            AppleUpscaleResourceLifetimeToken(
                                identity:
                                    "\(identity.backend.backendID)."
                                    + "output.\(frame.sequenceNumber)",
                                releaseAction: {}
                            ),
                        processingIdentity: processingIdentity
                    )
                )
            } catch {
                return .failed(failure)
            }
        case .unavailable:
            return .unavailable(unavailable)
        case .failed:
            return .failed(failure)
        }
    }

    func reset(reason: AppleUpscaleResetReason) async {
        resetReasons.append(reason)
    }

    func finish() async -> AppleUpscaleSessionSummary {
        finishCount += 1
        return AppleUpscaleSessionSummary(
            submittedFrameCount: submittedSequenceNumbers.count,
            processedFrameCount: 0,
            terminalizationCount: 1
        )
    }

    func cancel() async {
        cancelCount += 1
    }

    func snapshot() -> R13ProductASHTestSessionSnapshot {
        R13ProductASHTestSessionSnapshot(
            submittedSequenceNumbers: submittedSequenceNumbers,
            resetReasons: resetReasons,
            finishCount: finishCount,
            cancelCount: cancelCount
        )
    }
}

struct R13ProductASHTestFrame {
    let frame: AppleUpscaleFrame
    let probe: R02FixtureReleaseProbe
    let tokenIdentity: String
}

private enum R13ProductASHTestError: Error {
    case expectedProcessed
}

func makeCandidate(
    backendID: String,
    rank: Int64,
    modelAssetsIdentity:
        AppleUpscaleModelAssetsIdentity = .notRequired,
    script: [R13ProductASHTestBehavior]
) throws -> R13ProductASHTestCandidate {
    let identity = try AppleUpscaleRouteIdentity(
        backend: AppleUpscaleBackendIdentity(
            backendID: backendID,
            backendRevision: "test.router.backend.v1",
            modelAssetsIdentity: modelAssetsIdentity
        ),
        configurationIdentity: "\(backendID).configuration.v1",
        policyIdentity: "test.router.policy.v1",
        materialDecisionIdentity: "test.router.decision.v1"
    )
    let session = try R13ProductASHTestSession(
        identity: identity,
        script: script
    )
    let profile = R13ProductBackendProfile(
        primaryFamily: .spatial,
        qualityPreferred: true,
        fastPreferred: true,
        qualityConfidenceQ16: rank,
        artifactRiskQ16: 0,
        transitionCostQ16: 0,
        resourceCostQ16: 0
    )
    return R13ProductASHTestCandidate(
        identity: identity,
        session: session,
        candidate: R13ProductBackendSessionCandidate(
            session: session,
            routeIdentity: identity,
            profile: profile
        )
    )
}

func makeRouter(
    candidates: [R13ProductBackendSessionCandidate]
) throws -> R13ProductASHRoutingSession {
    let modeBinding = R13ReleaseModePolicy.binding(for: .quality)
    return try R13ProductASHRoutingSession(
        identity: R13ReleaseIdentity.makeProductRoute(
            for: .scale3Over2,
            modeBinding: modeBinding
        ),
        route: .scale3Over2,
        orchestrationKind: modeBinding.orchestrationKind,
        processingConfiguration: .default,
        streamIdentifier: "test.product.router",
        candidates: candidates
    )
}

func makeFrame(
    sequenceNumber: Int,
    seed: Int
) throws -> R13ProductASHTestFrame {
    let width = 64
    let height = 36
    let payload = try R02FixtureGenerators.nv12FrameBytes(
        width: width,
        height: height,
        seed: seed,
        sequenceNumber: 0
    )
    let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
        width: width,
        height: height,
        logicalBytes: payload
    )
    let probe = R02FixtureReleaseProbe()
    let tokenIdentity = "test.router.input.\(sequenceNumber)"
    let token = try AppleUpscaleResourceLifetimeToken(
        identity: tokenIdentity,
        releaseAction: { [probe] in
            probe.recordRelease(identity: tokenIdentity)
        }
    )
    return R13ProductASHTestFrame(
        frame: try AppleUpscaleFrame(
            sequenceNumber: sequenceNumber,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: CMTime(
                value: Int64(sequenceNumber),
                timescale: 30
            ),
            duration: CMTime(value: 1, timescale: 30),
            colorDescription: R03NV12Contract.makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity(
                "test.router.metadata.\(sequenceNumber)"
            ),
            resourceLifetimeToken: token
        ),
        probe: probe,
        tokenIdentity: tokenIdentity
    )
}

func requireProcessed(
    _ outcome:
        AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> AppleUpscaleProcessedFrame {
    guard case .processed(let processed) = outcome else {
        XCTFail("Expected a processed router outcome.", file: file, line: line)
        throw R13ProductASHTestError.expectedProcessed
    }
    return processed
}

func submitAndRelease(
    sequenceNumber: Int,
    seed: Int,
    to router: R13ProductASHRoutingSession
) async throws {
    let fixture = try makeFrame(
        sequenceNumber: sequenceNumber,
        seed: seed
    )
    let outcome = await router.submit(fixture.frame)
    let processed = try requireProcessed(outcome)
    processed.resourceLifetimeToken.release()
    XCTAssertEqual(
        fixture.probe.releaseCount(for: fixture.tokenIdentity),
        1
    )
}
