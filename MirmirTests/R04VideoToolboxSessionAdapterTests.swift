import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import XCTest
@testable import Mirmir

// This fixture suite keeps the closed route matrix and shared runtime recorder together.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class R04VideoToolboxSessionAdapterTests: XCTestCase {
    func testA01OneAndOneHalfRejectsBeforeRuntimeConstruction() async throws {
        let runtime = R04RecordingVideoToolboxRuntime()
        let factoryCount = R04SynchronousCounter()
        let backend = try makeBackend(
            .quality1p5xContract,
            runtime: runtime,
            factoryCount: factoryCount
        )

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try makeContext(for: backend.route)
        )

        assertCreationRejected(
            outcome,
            reason: .publicContractUnrepresentable,
            route: backend.routeIdentity
        )
        XCTAssertEqual(factoryCount.value, 0)
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.qualityQueries, [])
    }

    func testA02ExactDimensionQueryRejectsMissingScaleWithoutProcessing() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            lowLatencySupport: .observed([.two])
        )
        let backend = try makeBackend(.lowLatency1p5x, runtime: runtime)

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try makeContext(for: backend.route)
        )

        assertCreationRejected(
            outcome,
            reason: .exactDimensionQueryRejected,
            route: backend.routeIdentity
        )
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.lowLatencyQueries, [.p720])
        XCTAssertEqual(snapshot.processRequests, [])
        XCTAssertEqual(snapshot.finishCount, 1)
    }

    func testA02AcceptedRouteUsesRandomStatelessFIFORequest() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            lowLatencySupport: .observed([.two])
        )
        let backend = try makeBackend(.lowLatency2x, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let sessionRoute = await session.identity
        let fixture = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "r04.low-latency"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            return XCTFail("Expected injected low-latency processing")
        }

        XCTAssertEqual(processed.processingIdentity.route, sessionRoute)
        XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(processed.presentationTimestamp, fixture.frame.presentationTimestamp)
        XCTAssertEqual(processed.duration, fixture.frame.duration)
        XCTAssertEqual(processed.colorDescription, fixture.frame.colorDescription)
        XCTAssertEqual(processed.metadataIdentity, fixture.frame.metadataIdentity)
        XCTAssertEqual(fixture.releaseProbe.value, 1)

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.lowLatencyQueries, [.p1080])
        XCTAssertEqual(
            snapshot.processRequests,
            [
                .init(
                    routeID: .lowLatency2x,
                    sequenceNumber: 0,
                    previousSourceSequence: nil,
                    previousOutputSequence: nil,
                    historyGeneration: 0,
                    boundary: .notApplicable,
                    submissionMode: .random,
                    opticalFlowKind: .disabled
                )
            ]
        )

        processed.resourceLifetimeToken.release()
        XCTAssertEqual(runtime.outputReleaseCount, 1)
        let summary = await session.finish()
        XCTAssertEqual(summary.processedFrameCount, 1)
        let finishedSnapshot = await runtime.snapshot()
        XCTAssertEqual(finishedSnapshot.finishCount, 1)
    }

    func testQualitySessionOwnsOrderedHistoryResetAndSubmissionPolicy() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(qualitySupport: .observed(true))
        let backend = try R04VideoToolboxBackend(
            subjectID: .quality2x,
            modelAssetsIdentity: .notRequired,
            runtimeFactory: { runtime },
            opticalFlowProvider: { previous, _ in
                previous == nil ? .disabled : .appleComputed
            }
        )
        let session = try await makeSession(backend: backend)

        let first = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "r04.quality"
        )
        let second = try makeFrame(
            resolution: .p1080,
            sequence: 1,
            tokenPrefix: "r04.quality"
        )
        let third = try makeFrame(
            resolution: .p1080,
            sequence: 2,
            tokenPrefix: "r04.quality"
        )

        let firstOutput = try processed(await session.submit(first.frame))
        try R04VideoToolboxTestBuffers.fillFirstPlane(
            first.frame.pixelBuffer,
            value: 250
        )
        try R04VideoToolboxTestBuffers.fillFirstPlane(
            firstOutput.pixelBuffer,
            value: 251
        )
        firstOutput.resourceLifetimeToken.release()
        let secondOutput = try processed(await session.submit(second.frame))
        await session.reset(reason: .sceneCut)
        let thirdOutput = try processed(await session.submit(third.frame))

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.qualityQueries, [.p1080])
        XCTAssertEqual(
            snapshot.resetRequests,
            [
                .init(routeID: .quality2x, cause: .firstFrame, generation: 0),
                .init(routeID: .quality2x, cause: .session(.sceneCut), generation: 1)
            ]
        )
        XCTAssertEqual(
            snapshot.processRequests,
            [
                .init(
                    routeID: .quality2x,
                    sequenceNumber: 0,
                    previousSourceSequence: nil,
                    previousOutputSequence: nil,
                    historyGeneration: 0,
                    boundary: .firstFrame,
                    submissionMode: .random,
                    opticalFlowKind: .disabled
                ),
                .init(
                    routeID: .quality2x,
                    sequenceNumber: 1,
                    previousSourceSequence: 0,
                    previousOutputSequence: 0,
                    historyGeneration: 0,
                    boundary: .continuing,
                    submissionMode: .sequential,
                    opticalFlowKind: .appleComputed,
                    previousSourceFirstByte: 10,
                    previousOutputFirstByte: 100
                ),
                .init(
                    routeID: .quality2x,
                    sequenceNumber: 2,
                    previousSourceSequence: nil,
                    previousOutputSequence: nil,
                    historyGeneration: 1,
                    boundary: .firstFrame,
                    submissionMode: .random,
                    opticalFlowKind: .disabled
                )
            ]
        )
        XCTAssertEqual(first.releaseProbe.value, 1)
        XCTAssertEqual(second.releaseProbe.value, 1)
        XCTAssertEqual(third.releaseProbe.value, 1)

        secondOutput.resourceLifetimeToken.release()
        thirdOutput.resourceLifetimeToken.release()
        XCTAssertEqual(runtime.outputReleaseCount, 3)
        _ = await session.finish()
    }

    func testQualityPrecomputedConfigurationRejectsDisabledFlow() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            qualitySupport: .observed(true),
            diagnosticsBehavior: .observed(
                R04VideoToolboxTestDiagnostics.quality(
                    usesPrecomputedFlow: true
                )
            )
        )
        let backend = try makeBackend(.quality2x, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let fixture = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "r04.precomputed-disabled"
        )

        let outcome = await session.submit(fixture.frame)

        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected disabled flow to reject a precomputed configuration")
        }
        XCTAssertEqual(
            rejection.reason,
            R04VideoToolboxRouteRejectionReason.configurationIdentityMismatch.rawValue
        )
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.processRequests, [])
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        _ = await session.finish()
    }

    func testQualityAppleComputedConfigurationRejectsPrecomputedFlow() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            qualitySupport: .observed(true),
            diagnosticsBehavior: .observed(
                R04VideoToolboxTestDiagnostics.quality(
                    usesPrecomputedFlow: false
                )
            )
        )
        let flow = R04VideoToolboxPrecomputedFlow(
            forward: try R04VideoToolboxTestBuffers.makeNV12(.p1080),
            backward: try R04VideoToolboxTestBuffers.makeNV12(.p1080)
        )
        let backend = try R04VideoToolboxBackend(
            subjectID: .quality2x,
            modelAssetsIdentity: .notRequired,
            runtimeFactory: { runtime },
            opticalFlowProvider: { _, _ in .precomputed(flow) }
        )
        let session = try await makeSession(backend: backend)
        let fixture = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "r04.apple-computed-precomputed"
        )

        let outcome = await session.submit(fixture.frame)

        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected precomputed flow to reject an Apple-computed configuration")
        }
        XCTAssertEqual(
            rejection.reason,
            R04VideoToolboxRouteRejectionReason.configurationIdentityMismatch.rawValue
        )
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.processRequests, [])
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        _ = await session.finish()
    }

    func testQualitySequenceAndTimestampGapResetsThenContinuesSequentially() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(qualitySupport: .observed(true))
        let backend = try makeBackend(.quality2x, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let first = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "r04.gap"
        )
        let skipped = try makeFrame(
            resolution: .p1080,
            sequence: 2,
            tokenPrefix: "r04.gap"
        )
        let contiguous = try makeFrame(
            resolution: .p1080,
            sequence: 3,
            tokenPrefix: "r04.gap"
        )

        let firstOutput = try processed(await session.submit(first.frame))
        let skippedOutput = try processed(await session.submit(skipped.frame))
        let contiguousOutput = try processed(await session.submit(contiguous.frame))

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.resetRequests,
            [
                .init(routeID: .quality2x, cause: .firstFrame, generation: 0),
                .init(
                    routeID: .quality2x,
                    cause: .detectedDiscontinuity,
                    generation: 0
                )
            ]
        )
        XCTAssertEqual(
            snapshot.processRequests,
            [
                .init(
                    routeID: .quality2x,
                    sequenceNumber: 0,
                    previousSourceSequence: nil,
                    previousOutputSequence: nil,
                    historyGeneration: 0,
                    boundary: .firstFrame,
                    submissionMode: .random,
                    opticalFlowKind: .disabled
                ),
                .init(
                    routeID: .quality2x,
                    sequenceNumber: 2,
                    previousSourceSequence: nil,
                    previousOutputSequence: nil,
                    historyGeneration: 0,
                    boundary: .firstFrame,
                    submissionMode: .random,
                    opticalFlowKind: .disabled
                ),
                .init(
                    routeID: .quality2x,
                    sequenceNumber: 3,
                    previousSourceSequence: 2,
                    previousOutputSequence: 2,
                    historyGeneration: 0,
                    boundary: .continuing,
                    submissionMode: .sequential,
                    opticalFlowKind: .disabled,
                    previousSourceFirstByte: 12,
                    previousOutputFirstByte: 102
                )
            ]
        )

        firstOutput.resourceLifetimeToken.release()
        skippedOutput.resourceLifetimeToken.release()
        contiguousOutput.resourceLifetimeToken.release()
        _ = await session.finish()
    }

    func testOwnedHistoryCopyIsIOSurfaceBackedAndIndependent() throws {
        let source = try R04VideoToolboxTestBuffers.makeNV12(
            .p1080,
            firstPlaneByte: 41
        )
        let copy = try R04VideoToolboxNV12HistoryBufferCopier().makeOwnedCopy(
            of: source,
            resolution: .p1080
        )

        XCTAssertNotNil(CVPixelBufferGetIOSurface(copy))
        try R04VideoToolboxTestBuffers.fillFirstPlane(source, value: 99)
        XCTAssertEqual(try R04VideoToolboxTestBuffers.firstPlaneByte(copy), 41)
    }

    func testNotObservedSupportIsTypedUnavailableWithoutSession() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(qualitySupport: .notObserved)
        let backend = try makeBackend(.quality2x, runtime: runtime)

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try makeContext(for: backend.route)
        )

        assertCreationUnavailable(
            outcome,
            reason: .runtimeSupportNotObserved,
            route: backend.routeIdentity
        )
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.finishCount, 1)
    }

    func testNotObservedCapabilityDoesNotConstructRuntime() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(qualitySupport: .observed(true))
        let factoryCount = R04SynchronousCounter()
        let backend = try makeBackend(
            .quality2x,
            runtime: runtime,
            factoryCount: factoryCount
        )
        let capability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .notObserved,
            runtimeDisposition: .diagnosticOnly,
            backendEligibility: .notEvaluated
        )

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try makeContext(for: backend.route, capability: capability)
        )

        assertCreationUnavailable(
            outcome,
            reason: .capabilityNotObserved,
            route: backend.routeIdentity
        )
        XCTAssertEqual(factoryCount.value, 0)
    }

    func testProductScopeAndQualificationRemainForbidden() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(qualitySupport: .observed(true))
        let factoryCount = R04SynchronousCounter()
        let backend = try makeBackend(
            .quality2x,
            runtime: runtime,
            factoryCount: factoryCount
        )
        let capability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .productQualified
        )

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try makeContext(
                for: backend.route,
                scope: .product,
                capability: capability
            )
        )

        assertCreationRejected(
            outcome,
            reason: .productScopeForbidden,
            route: backend.routeIdentity
        )
        XCTAssertEqual(factoryCount.value, 0)
    }

    func testA05CanResolveOptionalSupportButCannotCreatePrimarySession() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(opticalFlowSupport: .observed(true))
        let route = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(
                R04VideoToolboxSubjectID.opticalFlowSupport
            )
        )
        let decision = await R04VideoToolboxRouteResolver.resolve(
            route,
            using: runtime
        )
        guard case .optionalSupported(let supported) = decision else {
            return XCTFail("A05 support observation must remain optional")
        }
        XCTAssertEqual(supported, route)
        let resolverSnapshot = await runtime.snapshot()
        XCTAssertEqual(resolverSnapshot.opticalFlowQueries, [.p1080])

        let factoryCount = R04SynchronousCounter()
        let backend = try makeBackend(
            .opticalFlowSupport,
            runtime: runtime,
            factoryCount: factoryCount
        )
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try makeContext(for: route)
        )
        assertCreationRejected(
            outcome,
            reason: .optionalSupportOnly,
            route: backend.routeIdentity
        )
        XCTAssertEqual(factoryCount.value, 0)
    }

    func testRuntimeUnavailableMapsWithoutFallback() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            lowLatencySupport: .observed([.oneAndOneHalf]),
            processBehavior: .unavailable(.runtimeUnavailable)
        )
        let backend = try makeBackend(.lowLatency1p5x, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let sessionRoute = await session.identity
        let fixture = try makeFrame(
            resolution: .p720,
            sequence: 0,
            tokenPrefix: "r04.unavailable"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .unavailable(let unavailable) = outcome else {
            return XCTFail("Expected typed runtime unavailability")
        }
        XCTAssertEqual(unavailable.reason, "r04_runtime_unavailable")
        XCTAssertEqual(unavailable.processingIdentity.route, sessionRoute)
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        _ = await session.finish()
    }

    func testOutputContractMismatchFailsAndReleasesRuntimeOutputExactlyOnce() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            lowLatencySupport: .observed([.oneAndOneHalf]),
            processBehavior: .wrongOutputDimensions
        )
        let backend = try makeBackend(.lowLatency1p5x, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let sessionRoute = await session.identity
        let fixture = try makeFrame(
            resolution: .p720,
            sequence: 0,
            tokenPrefix: "r04.bad-output"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .failed(let failure) = outcome else {
            return XCTFail("Expected an output-contract failure")
        }
        XCTAssertEqual(failure.reason, "r04_output_contract_mismatch")
        XCTAssertEqual(failure.processingIdentity.route, sessionRoute)
        XCTAssertTrue(failure.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        XCTAssertEqual(runtime.outputReleaseCount, 1)
        _ = await session.finish()
    }

    func testInputContractMismatchRejectsBeforeRuntimeProcessing() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            lowLatencySupport: .observed([.oneAndOneHalf])
        )
        let backend = try makeBackend(.lowLatency1p5x, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let fixture = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "r04.bad-input"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected an input-contract rejection")
        }
        XCTAssertEqual(rejection.reason, "r04_frame_contract_mismatch")
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.processRequests, [])
        _ = await session.finish()
    }

    private func makeBackend(
        _ subjectID: R04VideoToolboxSubjectID,
        runtime: R04RecordingVideoToolboxRuntime,
        factoryCount: R04SynchronousCounter = R04SynchronousCounter()
    ) throws -> R04VideoToolboxBackend {
        try R04VideoToolboxBackend(
            subjectID: subjectID,
            modelAssetsIdentity: .notRequired,
            runtimeFactory: {
                factoryCount.increment()
                return runtime
            }
        )
    }

    private func makeContext(
        for route: R04VideoToolboxRouteDescriptor,
        scope: AppleUpscaleAdmissionScope = .fixtureOnly,
        capability: AppleUpscaleCapability? = nil
    ) throws -> AppleUpscaleSessionContext {
        let role: AppleUpscaleCapabilityRole = route.backendKind == .optionalFlowSupport
            ? .temporalAnalyzer
            : .primaryScaler
        let capability = try capability ?? AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID(route.capabilityID),
            role: role,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
        return try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: scope,
            policyIdentity: R04VideoToolboxRouteCatalog.policyIdentity
        )
    }

    private func makeSession(
        backend: R04VideoToolboxBackend
    ) async throws -> any AppleUpscaleSession {
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try makeContext(for: backend.route)
        )
        guard case .created(let session) = outcome else {
            throw R04VideoToolboxAdapterTestError.sessionNotCreated
        }
        return session
    }

    private func makeFrame(
        resolution: VideoResolution,
        sequence: Int,
        tokenPrefix: String,
        presentationTimestamp: CMTime? = nil,
        duration: CMTime = CMTime(value: 1, timescale: 30)
    ) throws -> R04InputFrameFixture {
        let pixelBuffer = try R04VideoToolboxTestBuffers.makeNV12(resolution)
        try R04VideoToolboxTestBuffers.fillFirstPlane(
            pixelBuffer,
            value: UInt8(10 + sequence)
        )
        let releaseProbe = R04SynchronousCounter()
        let tokenIdentity = "\(tokenPrefix).\(sequence)"
        let token = try AppleUpscaleResourceLifetimeToken(
            identity: tokenIdentity,
            releaseAction: { releaseProbe.increment() }
        )
        let frame = try AppleUpscaleFrame(
            sequenceNumber: sequence,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: presentationTimestamp
                ?? CMTime(value: Int64(sequence), timescale: 30),
            duration: duration,
            colorDescription: try R04VideoToolboxTestBuffers.colorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity(
                "r04.metadata.\(sequence)"
            ),
            resourceLifetimeToken: token
        )
        return R04InputFrameFixture(frame: frame, releaseProbe: releaseProbe)
    }

    private func processed(
        _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
    ) throws -> AppleUpscaleProcessedFrame {
        guard case .processed(let value) = outcome else {
            throw R04VideoToolboxAdapterTestError.frameNotProcessed
        }
        return value
    }

    private func assertCreationRejected(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        reason: R04VideoToolboxRouteRejectionReason,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected session rejection", file: file, line: line)
        }
        XCTAssertEqual(rejection.reason, reason.rawValue, file: file, line: line)
        XCTAssertEqual(rejection.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
    }

    private func assertCreationUnavailable(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        reason: R04VideoToolboxRouteUnavailableReason,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let unavailable) = outcome else {
            return XCTFail("Expected session unavailability", file: file, line: line)
        }
        XCTAssertEqual(unavailable.reason, reason.rawValue, file: file, line: line)
        XCTAssertEqual(unavailable.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
    }
}

private enum R04VideoToolboxAdapterTestError: Error {
    case sessionNotCreated
    case frameNotProcessed
    case pixelBufferCreationFailed(CVReturn)
    case pixelBufferLockFailed(CVReturn)
    case missingPlaneBaseAddress
}

private struct R04InputFrameFixture {
    let frame: AppleUpscaleFrame
    let releaseProbe: R04SynchronousCounter
}

private final class R04SynchronousCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

private enum R04StubProcessBehavior: Sendable {
    case processed
    case wrongOutputDimensions
    case unavailable(R04VideoToolboxRouteUnavailableReason)
    case rejected(R04VideoToolboxRouteRejectionReason)
    case failed(R04VideoToolboxRouteFailureReason)
}

private enum R04StubDiagnosticsBehavior: Sendable {
    case routeValid
    case notObserved
    case observed(R04VideoToolboxConfigurationDiagnostics)
}

private enum R04OpticalFlowKind: Equatable, Sendable {
    case disabled
    case appleComputed
    case precomputed
}

private struct R04ProcessRequestSnapshot: Equatable, Sendable {
    let routeID: R04VideoToolboxRouteID
    let sequenceNumber: Int
    let previousSourceSequence: Int?
    let previousOutputSequence: Int?
    let previousSourceFirstByte: UInt8?
    let previousOutputFirstByte: UInt8?
    let historyGeneration: UInt64
    let boundary: R04VideoToolboxHistoryBoundary
    let submissionMode: R04VideoToolboxSubmissionMode
    let opticalFlowKind: R04OpticalFlowKind

    init(
        routeID: R04VideoToolboxRouteID,
        sequenceNumber: Int,
        previousSourceSequence: Int?,
        previousOutputSequence: Int?,
        historyGeneration: UInt64,
        boundary: R04VideoToolboxHistoryBoundary,
        submissionMode: R04VideoToolboxSubmissionMode,
        opticalFlowKind: R04OpticalFlowKind,
        previousSourceFirstByte: UInt8? = nil,
        previousOutputFirstByte: UInt8? = nil
    ) {
        self.routeID = routeID
        self.sequenceNumber = sequenceNumber
        self.previousSourceSequence = previousSourceSequence
        self.previousOutputSequence = previousOutputSequence
        self.previousSourceFirstByte = previousSourceFirstByte
        self.previousOutputFirstByte = previousOutputFirstByte
        self.historyGeneration = historyGeneration
        self.boundary = boundary
        self.submissionMode = submissionMode
        self.opticalFlowKind = opticalFlowKind
    }
}

private struct R04ResetRequestSnapshot: Equatable, Sendable {
    let routeID: R04VideoToolboxRouteID
    let cause: R04VideoToolboxResetCause
    let generation: UInt64
}

private struct R04RuntimeSnapshot: Equatable, Sendable {
    let qualityQueries: [VideoResolution]
    let lowLatencyQueries: [VideoResolution]
    let opticalFlowQueries: [VideoResolution]
    let configurationQueries: [R04VideoToolboxRouteID]
    let processRequests: [R04ProcessRequestSnapshot]
    let resetRequests: [R04ResetRequestSnapshot]
    let finishCount: Int
    let cancelCount: Int
}

private actor R04RecordingVideoToolboxRuntime: R04VideoToolboxRuntime {
    private let qualitySupport: R04VideoToolboxSupportObservation<Bool>
    private let lowLatencySupport: R04VideoToolboxSupportObservation<
        Set<R04VideoToolboxScaleFactor>
    >
    private let opticalFlowSupportValue: R04VideoToolboxSupportObservation<Bool>
    private let diagnosticsBehavior: R04StubDiagnosticsBehavior
    private let processBehavior: R04StubProcessBehavior
    private let outputReleaseProbe = R04SynchronousCounter()

    private var qualityQueries: [VideoResolution] = []
    private var lowLatencyQueries: [VideoResolution] = []
    private var opticalFlowQueries: [VideoResolution] = []
    private var configurationQueries: [R04VideoToolboxRouteID] = []
    private var processRequests: [R04ProcessRequestSnapshot] = []
    private var resetRequests: [R04ResetRequestSnapshot] = []
    private var finishCount = 0
    private var cancelCount = 0

    nonisolated var outputReleaseCount: Int {
        outputReleaseProbe.value
    }

    init(
        qualitySupport: R04VideoToolboxSupportObservation<Bool> = .notObserved,
        lowLatencySupport: R04VideoToolboxSupportObservation<
            Set<R04VideoToolboxScaleFactor>
        > = .notObserved,
        opticalFlowSupport: R04VideoToolboxSupportObservation<Bool> = .notObserved,
        diagnosticsBehavior: R04StubDiagnosticsBehavior = .routeValid,
        processBehavior: R04StubProcessBehavior = .processed
    ) {
        self.qualitySupport = qualitySupport
        self.lowLatencySupport = lowLatencySupport
        opticalFlowSupportValue = opticalFlowSupport
        self.diagnosticsBehavior = diagnosticsBehavior
        self.processBehavior = processBehavior
    }

    func quality2xSupport(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Bool> {
        qualityQueries.append(sourceResolution)
        return qualitySupport
    }

    func lowLatencySupportedScaleFactors(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Set<R04VideoToolboxScaleFactor>> {
        lowLatencyQueries.append(sourceResolution)
        return lowLatencySupport
    }

    func opticalFlowSupport(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Bool> {
        opticalFlowQueries.append(sourceResolution)
        return opticalFlowSupportValue
    }

    func configurationDiagnostics(
        for route: R04VideoToolboxRouteDescriptor
    ) async -> R04VideoToolboxSupportObservation<
        R04VideoToolboxConfigurationDiagnostics
    > {
        configurationQueries.append(route.routeID)
        switch diagnosticsBehavior {
        case .routeValid:
            return .observed(R04VideoToolboxTestDiagnostics.valid(for: route))
        case .notObserved:
            return .notObserved
        case .observed(let diagnostics):
            return .observed(diagnostics)
        }
    }

    func process(
        _ request: R04VideoToolboxProcessingRequest,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) async -> R04VideoToolboxRuntimeOutcome {
        processRequests.append(
            R04ProcessRequestSnapshot(
                routeID: request.route.routeID,
                sequenceNumber: request.sourceFrame.sequenceNumber,
                previousSourceSequence: request.previousSource?.sequenceNumber,
                previousOutputSequence: request.previousOutput?.sequenceNumber,
                historyGeneration: request.historyGeneration,
                boundary: request.historyBoundary,
                submissionMode: request.submissionMode,
                opticalFlowKind: opticalFlowKind(request.opticalFlowMode),
                previousSourceFirstByte: try? R04VideoToolboxTestBuffers
                    .firstPlaneByte(request.previousSource?.pixelBuffer),
                previousOutputFirstByte: try? R04VideoToolboxTestBuffers
                    .firstPlaneByte(request.previousOutput?.pixelBuffer)
            )
        )
        switch processBehavior {
        case .processed, .wrongOutputDimensions:
            let resolution = processBehavior.isWrongOutput
                ? request.route.sourceResolution
                : request.route.targetResolution
            do {
                return .processed(
                    R04VideoToolboxRuntimeOutput(
                        pixelBuffer: try R04VideoToolboxTestBuffers.makeNV12(
                            resolution,
                            firstPlaneByte: UInt8(100 + request.sourceFrame.sequenceNumber)
                        ),
                        releaseAction: { [outputReleaseProbe] in
                            outputReleaseProbe.increment()
                        }
                    )
                )
            } catch {
                return .failed(.runtimeProcessingFailed)
            }
        case .unavailable(let reason):
            return .unavailable(reason)
        case .rejected(let reason):
            return .rejected(reason)
        case .failed(let reason):
            return .failed(reason)
        }
    }

    func reset(
        _ request: R04VideoToolboxResetRequest,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) async {
        resetRequests.append(
            R04ResetRequestSnapshot(
                routeID: request.route.routeID,
                cause: request.cause,
                generation: request.historyGeneration
            )
        )
    }

    func finish() async {
        finishCount += 1
    }

    func cancel() async {
        cancelCount += 1
    }

    func snapshot() -> R04RuntimeSnapshot {
        R04RuntimeSnapshot(
            qualityQueries: qualityQueries,
            lowLatencyQueries: lowLatencyQueries,
            opticalFlowQueries: opticalFlowQueries,
            configurationQueries: configurationQueries,
            processRequests: processRequests,
            resetRequests: resetRequests,
            finishCount: finishCount,
            cancelCount: cancelCount
        )
    }

    private func opticalFlowKind(
        _ mode: R04VideoToolboxOpticalFlowMode
    ) -> R04OpticalFlowKind {
        switch mode {
        case .disabled:
            return .disabled
        case .appleComputed:
            return .appleComputed
        case .precomputed:
            return .precomputed
        }
    }
}

private extension R04StubProcessBehavior {
    var isWrongOutput: Bool {
        if case .wrongOutputDimensions = self { return true }
        return false
    }
}

private enum R04VideoToolboxTestBuffers {
    static func makeNV12(
        _ resolution: VideoResolution,
        firstPlaneByte: UInt8? = nil
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            resolution.width,
            resolution.height,
            R04VideoToolboxRouteCatalog.pixelFormat,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw R04VideoToolboxAdapterTestError.pixelBufferCreationFailed(status)
        }
        installColorAttachments(on: buffer)
        if let firstPlaneByte {
            try fillFirstPlane(buffer, value: firstPlaneByte)
        }
        return buffer
    }

    static func fillFirstPlane(
        _ pixelBuffer: CVPixelBuffer,
        value: UInt8
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R04VideoToolboxAdapterTestError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw R04VideoToolboxAdapterTestError.missingPlaneBaseAddress
        }
        baseAddress.assumingMemoryBound(to: UInt8.self).pointee = value
    }

    static func firstPlaneByte(
        _ pixelBuffer: CVPixelBuffer?
    ) throws -> UInt8? {
        guard let pixelBuffer else { return nil }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw R04VideoToolboxAdapterTestError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw R04VideoToolboxAdapterTestError.missingPlaneBaseAddress
        }
        return baseAddress.assumingMemoryBound(to: UInt8.self).pointee
    }

    static func colorDescription() throws -> AppleUpscaleColorDescription {
        try AppleUpscaleColorDescription(
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
            chromaSiting: kCVImageBufferChromaLocation_Left as String,
            range: .video
        )
    }

    private static func installColorAttachments(on pixelBuffer: CVPixelBuffer) {
        let attachments: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
            (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left)
        ]
        for (key, value) in attachments {
            CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
        }
    }
}

private enum R04VideoToolboxTestDiagnostics {
    static func valid(
        for route: R04VideoToolboxRouteDescriptor,
        usesPrecomputedFlow: Bool = false
    ) -> R04VideoToolboxConfigurationDiagnostics {
        switch route.backendKind {
        case .quality:
            return quality(
                usesPrecomputedFlow: usesPrecomputedFlow,
                sourceResolution: route.sourceResolution,
                scaleFactor: route.scaleFactor.numerator
            )
        case .lowLatency:
            return R04VideoToolboxConfigurationDiagnostics(
                nativeIdentity: .lowLatency(
                    R04ObservedLowLatencyConfiguration(
                        frameWidth: route.sourceResolution.width,
                        frameHeight: route.sourceResolution.height,
                        scaleFactor: Float(route.scaleFactor.numerator)
                            / Float(route.scaleFactor.denominator)
                    )
                ),
                supportedPixelFormats: [R04VideoToolboxRouteCatalog.pixelFormat],
                modelStatus: .notRequired,
                processingMode: .lowLatency
            )
        case .optionalFlowSupport:
            preconditionFailure("Optional flow support cannot create an R04 session")
        }
    }

    static func quality(
        usesPrecomputedFlow: Bool,
        sourceResolution: VideoResolution = .p1080,
        scaleFactor: Int = 2,
        supportedPixelFormats: [OSType] = [
            R04VideoToolboxRouteCatalog.pixelFormat
        ],
        modelStatus: R04VideoToolboxObservedModelStatus = .ready
    ) -> R04VideoToolboxConfigurationDiagnostics {
        R04VideoToolboxConfigurationDiagnostics(
            nativeIdentity: .quality(
                R04ObservedQualityConfiguration(
                    frameWidth: sourceResolution.width,
                    frameHeight: sourceResolution.height,
                    integerScaleFactor: scaleFactor,
                    inputType: .video,
                    usesPrecomputedFlow: usesPrecomputedFlow,
                    qualityPriority: .normal,
                    revision: 1
                )
            ),
            supportedPixelFormats: supportedPixelFormats,
            modelStatus: modelStatus,
            processingMode: .quality
        )
    }
}

// swiftlint:enable file_length
