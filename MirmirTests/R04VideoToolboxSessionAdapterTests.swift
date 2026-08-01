import Accelerate
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

    func testNativeProductAdmissionCreatesExactRouteSession() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            lowLatencySupport: .observed([.two])
        )
        let backend = try R04VideoToolboxBackend(
            subjectID: .lowLatency2x,
            modelAssetsIdentity: .notRequired,
            runtimeFactory: { runtime },
            admissionPolicy: .nativeProduct
        )
        let capability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .productQualified
        )
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: .product,
            policyIdentity: backend.routeIdentity.policyIdentity
        )

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )

        guard case .created(let session) = outcome else {
            return XCTFail("Expected native-product VideoToolbox session")
        }
        let identity = await session.identity
        XCTAssertEqual(
            identity.policyIdentity,
            R04VideoToolboxBackendAdmissionPolicy.nativeProduct.policyIdentity
        )
        XCTAssertTrue(identity.configurationIdentity.contains("observed"))
        _ = await session.finish()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.lowLatencyQueries, [.p1080])
        XCTAssertEqual(snapshot.configurationQueries, [.lowLatency2x])
    }

    func testProductFactoryAcceptsObservedIdentityForBothNativeVideoToolboxPaths()
        async throws {
        for subjectID in [
            R04VideoToolboxSubjectID.quality2x,
            .lowLatency2x
        ] {
            let fixture = try await makeNativeProductIdentityFixture(
                subjectID
            )

            XCTAssertEqual(
                R13A11ProductSessionFactory
                    .validatedVideoToolboxSessionIdentity(
                        fixture.identity,
                        backend: fixture.backend,
                        observation: fixture.observation
                    ),
                fixture.identity,
                subjectID.rawValue
            )
            _ = await fixture.session.finish()
        }
    }

    func testProductFactoryRejectsNativeVideoToolboxIdentityTampering()
        async throws {
        for subjectID in [
            R04VideoToolboxSubjectID.quality2x,
            .lowLatency2x
        ] {
            let fixture = try await makeNativeProductIdentityFixture(
                subjectID
            )
            let identity = fixture.identity

            let wrongBackend = try AppleUpscaleBackendIdentity(
                backendID: identity.backend.backendID + ".tampered",
                backendRevision: identity.backend.backendRevision,
                modelAssetsIdentity: identity.backend.modelAssetsIdentity
            )
            let wrongBackendIdentity = try AppleUpscaleRouteIdentity(
                backend: wrongBackend,
                configurationIdentity: identity.configurationIdentity,
                policyIdentity: identity.policyIdentity,
                materialDecisionIdentity:
                    identity.materialDecisionIdentity
            )
            XCTAssertNil(
                R13A11ProductSessionFactory
                    .validatedVideoToolboxSessionIdentity(
                        wrongBackendIdentity,
                        backend: fixture.backend,
                        observation: fixture.observation
                    ),
                subjectID.rawValue
            )

            let otherSubjectID: R04VideoToolboxSubjectID =
                subjectID == .quality2x ? .lowLatency2x : .quality2x
            let otherRoute = try XCTUnwrap(
                R04VideoToolboxRouteCatalog.route(otherSubjectID)
            )
            let wrongRouteObservation = R04VTNativeCapabilityObservation(
                route: otherRoute,
                capability: fixture.observation.capability,
                status: .runnable,
                diagnostics: fixture.observation.diagnostics
            )
            XCTAssertNil(
                R13A11ProductSessionFactory
                    .validatedVideoToolboxSessionIdentity(
                        identity,
                        backend: fixture.backend,
                        observation: wrongRouteObservation
                    ),
                subjectID.rawValue
            )

            let wrongConfigurationIdentity = try AppleUpscaleRouteIdentity(
                backend: identity.backend,
                configurationIdentity:
                    identity.configurationIdentity + ".tampered",
                policyIdentity: identity.policyIdentity,
                materialDecisionIdentity:
                    identity.materialDecisionIdentity
            )
            XCTAssertNil(
                R13A11ProductSessionFactory
                    .validatedVideoToolboxSessionIdentity(
                        wrongConfigurationIdentity,
                        backend: fixture.backend,
                        observation: fixture.observation
                    ),
                subjectID.rawValue
            )

            let alternateDiagnostics = try alternateAcceptedDiagnostics(
                for: fixture.backend.route
            )
            let wrongDiagnosticsIdentity = try
                R04VideoToolboxObservedRouteIdentity.make(
                    declaredRouteIdentity: fixture.backend.routeIdentity,
                    route: fixture.backend.route,
                    diagnostics: alternateDiagnostics
                )
            XCTAssertNil(
                R13A11ProductSessionFactory
                    .validatedVideoToolboxSessionIdentity(
                        wrongDiagnosticsIdentity,
                        backend: fixture.backend,
                        observation: fixture.observation
                    ),
                subjectID.rawValue
            )

            let wrongPolicyIdentity = try AppleUpscaleRouteIdentity(
                backend: identity.backend,
                configurationIdentity: identity.configurationIdentity,
                policyIdentity: identity.policyIdentity + ".tampered",
                materialDecisionIdentity:
                    identity.materialDecisionIdentity
            )
            XCTAssertNil(
                R13A11ProductSessionFactory
                    .validatedVideoToolboxSessionIdentity(
                        wrongPolicyIdentity,
                        backend: fixture.backend,
                        observation: fixture.observation
                    ),
                subjectID.rawValue
            )

            let wrongMaterialIdentity = try AppleUpscaleRouteIdentity(
                backend: identity.backend,
                configurationIdentity: identity.configurationIdentity,
                policyIdentity: identity.policyIdentity,
                materialDecisionIdentity:
                    identity.materialDecisionIdentity + ".tampered"
            )
            XCTAssertNil(
                R13A11ProductSessionFactory
                    .validatedVideoToolboxSessionIdentity(
                        wrongMaterialIdentity,
                        backend: fixture.backend,
                        observation: fixture.observation
                    ),
                subjectID.rawValue
            )
            _ = await fixture.session.finish()
        }
    }

    func testNativeCapabilityObserverQualifiesOnlyValidatedRunnableRoute() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            lowLatencySupport: .observed([.two])
        )

        let observation = try await R04VideoToolboxNativeCapabilityObserver.observe(
            subjectID: .lowLatency2x,
            runtimeFactory: { runtime }
        )

        XCTAssertEqual(observation.status, .runnable)
        XCTAssertNotNil(observation.diagnostics)
        XCTAssertEqual(observation.capability.observationStatus, .observed)
        XCTAssertEqual(observation.capability.runtimeDisposition, .runnable)
        XCTAssertEqual(
            observation.capability.backendEligibility,
            .productQualified
        )
        XCTAssertTrue(observation.capability.isEligible(for: .product))
        XCTAssertFalse(observation.capability.isEligible(for: .fixtureOnly))
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.finishCount, 1)
    }

    func testNativeCapabilityObserverDoesNotQualifyUnreadyQualityModel() async throws {
        let runtime = R04RecordingVideoToolboxRuntime(
            qualitySupport: .observed(true),
            diagnosticsBehavior: .observed(
                R04VideoToolboxTestDiagnostics.quality(
                    usesPrecomputedFlow: false,
                    modelStatus: .downloadRequired
                )
            )
        )

        let observation = try await R04VideoToolboxNativeCapabilityObserver.observe(
            subjectID: .quality2x,
            runtimeFactory: { runtime }
        )

        XCTAssertEqual(observation.status, .unavailable(.modelNotReady))
        XCTAssertEqual(observation.capability.observationStatus, .observed)
        XCTAssertEqual(observation.capability.runtimeDisposition, .unavailable)
        XCTAssertEqual(observation.capability.backendEligibility, .notEvaluated)
        XCTAssertFalse(observation.capability.isEligible(for: .product))
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.finishCount, 1)
    }

    func testLiveNativeCapabilityObservationIsInternallyConsistent() async throws {
        let observation = try await R04VideoToolboxBackend.observeNativeCapability(
            subjectID: .lowLatency2x
        )

        XCTAssertEqual(observation.route.subjectID, .lowLatency2x)
        switch observation.status {
        case .runnable:
            XCTAssertNotNil(observation.diagnostics)
            XCTAssertEqual(observation.capability.observationStatus, .observed)
            XCTAssertEqual(observation.capability.runtimeDisposition, .runnable)
            XCTAssertEqual(
                observation.capability.backendEligibility,
                .productQualified
            )
            XCTAssertTrue(observation.capability.isEligible(for: .product))
        case .rejected, .unavailable:
            XCTAssertNotEqual(observation.capability.runtimeDisposition, .runnable)
            XCTAssertEqual(
                observation.capability.backendEligibility,
                .notEvaluated
            )
            XCTAssertFalse(observation.capability.isEligible(for: .product))
        case .optionalSupported:
            XCTFail("A primary low-latency route cannot report optional support")
        }
    }

    func testLiveNativeLowLatencyFourTimesProductSessionProcessesWhenRunnable()
        async throws {
        let observation = try await R04VideoToolboxBackend.observeNativeCapability(
            subjectID: .lowLatency4x
        )
        guard case .runnable = observation.status else {
            throw XCTSkip(
                "This host does not expose the exact native "
                    + "VideoToolbox 480x270-to-1920x1080 route."
            )
        }

        let backend = try R04VideoToolboxBackend.makeNative(
            subjectID: .lowLatency4x
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try AppleUpscaleSessionContext(
                capabilityRegistry: AppleUpscaleCapabilityRegistry(
                    capabilities: [observation.capability]
                ),
                admissionScope: .product,
                policyIdentity: backend.routeIdentity.policyIdentity
            )
        )
        guard case .created(let session) = creation else {
            return XCTFail("A runnable native route must create its product session")
        }
        let fixture = try makeFrame(
            resolution: .p270,
            sequence: 0,
            tokenPrefix: "r04.live-native-low-latency4x"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            _ = await session.finish()
            return XCTFail("A runnable native route must process its exact NV12 frame")
        }
        XCTAssertEqual(CVPixelBufferGetWidth(processed.pixelBuffer), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(processed.pixelBuffer), 1080)
        let sessionIdentity = await session.identity
        XCTAssertEqual(
            processed.processingIdentity.route,
            sessionIdentity
        )
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        processed.resourceLifetimeToken.release()
        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
    }

    func testLiveNativeQualityFourTimesProductSessionProcessesWhenRunnable()
        async throws {
        let observation = try await R04VideoToolboxBackend.observeNativeCapability(
            subjectID: .quality4x
        )
        guard case .runnable = observation.status else {
            throw XCTSkip(
                "This host does not expose a ready native VideoToolbox "
                    + "Quality 480x270-to-1920x1080 route."
            )
        }

        let backend = try R04VideoToolboxBackend.makeNative(
            subjectID: .quality4x
        )
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try AppleUpscaleSessionContext(
                capabilityRegistry: AppleUpscaleCapabilityRegistry(
                    capabilities: [observation.capability]
                ),
                admissionScope: .product,
                policyIdentity: backend.routeIdentity.policyIdentity
            )
        )
        guard case .created(let session) = creation else {
            return XCTFail("A runnable native Quality route must create its session")
        }
        let fixture = try makeFrame(
            resolution: .p270,
            sequence: 0,
            tokenPrefix: "r04.live-native-quality4x"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            _ = await session.finish()
            return XCTFail("The native Quality route must process canonical NV12")
        }
        XCTAssertEqual(CVPixelBufferGetWidth(processed.pixelBuffer), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(processed.pixelBuffer), 1080)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(processed.pixelBuffer),
            R04VideoToolboxRouteCatalog.pixelFormat
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(processed.pixelBuffer), 2)
        try R03NV12Contract.validate(
            pixelBuffer: processed.pixelBuffer,
            resolution: .p1080
        )
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        processed.resourceLifetimeToken.release()
        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
    }

    @available(macOS 26.0, *)
    func testLiveAdaptiveQualityPreservesPQBT2020P010AndChangesImage()
        async throws {
        let observation = try await R04VideoToolboxBackend.observeNativeCapability(
            subjectID: .quality4x
        )
        guard case .runnable = observation.status else {
            throw XCTSkip(
                "This host does not expose a ready native VideoToolbox "
                    + "Quality 480x270-to-1920x1080 route."
            )
        }
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume: Data(repeating: 0x31, count: 24),
            contentLightLevelInfo: Data([0x03, 0xE8, 0x01, 0x90])
        )
        let fixture = try makeFormatFrame(
            format: format,
            resolution: .p270,
            sequence: 0,
            tokenPrefix: "r04.live-quality-pq-p010",
            offset: 11
        )
        let baseline = try R04VideoToolboxTestBuffers.makePixelBuffer(
            .p1080,
            pixelFormat: format.pixelStorage.pixelFormat
        )
        try R13PixelLayoutProcessor.scaleVImage(
            source: fixture.frame.pixelBuffer,
            destination: baseline,
            flags: vImage_Flags(
                kvImageEdgeExtend | kvImageHighQualityResampling
            )
        )
        let session = try VTAdaptiveNativeUpscaleSession.make(
            path: .quality,
            videoFormat: format,
            presentationSourceResolution: .p270,
            requestedSourceResolution: .p270,
            requestedTargetResolution: .p1080
        )

        let output = try await session.process(
            fixture.frame,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )

        try R13MediaVideoFormatContract.validate(
            output.pixelBuffer,
            resolution: .p1080,
            format: format
        )
        XCTAssertEqual(output.videoFormat, format)
        XCTAssertNotEqual(
            try R13PixelLayoutTestFixtures.lumaCodes(output.pixelBuffer),
            try R13PixelLayoutTestFixtures.lumaCodes(baseline),
            "The live Quality processor must measurably affect the output."
        )
        await session.finish()
        fixture.frame.resourceLifetimeToken.release()
        XCTAssertEqual(fixture.releaseProbe.value, 1)
    }

    @available(macOS 26.0, *)
    func testLiveAdaptiveLowLatencyPreservesSixteenBitAlphaAndChangesImage()
        async throws {
        let observation = try await R04VideoToolboxBackend.observeNativeCapability(
            subjectID: .lowLatency4x
        )
        guard case .runnable = observation.status else {
            throw XCTSkip(
                "This host does not expose the exact native "
                    + "VideoToolbox 480x270-to-1920x1080 route."
            )
        }
        let format = MediaVideoFormat.sdrBT709HighPrecisionAlpha(
            mode: .premultiplied
        )
        let fixture = try makeFormatFrame(
            format: format,
            resolution: .p270,
            sequence: 0,
            tokenPrefix: "r04.live-low-latency-alpha16",
            offset: 13
        )
        let baseline = try R04VideoToolboxTestBuffers.makePixelBuffer(
            .p1080,
            pixelFormat: format.pixelStorage.pixelFormat
        )
        try R13PixelLayoutProcessor.scaleVImage(
            source: fixture.frame.pixelBuffer,
            destination: baseline,
            flags: vImage_Flags(
                kvImageEdgeExtend | kvImageHighQualityResampling
            )
        )
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            baseline,
            format: format
        )
        let session = try VTAdaptiveNativeUpscaleSession.make(
            path: .lowLatency,
            videoFormat: format,
            presentationSourceResolution: .p270,
            requestedSourceResolution: .p270,
            requestedTargetResolution: .p1080
        )

        let output = try await session.process(
            fixture.frame,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )

        try R13MediaVideoFormatContract.validate(
            output.pixelBuffer,
            resolution: .p1080,
            format: format
        )
        XCTAssertEqual(
            try R13PixelLayoutTestFixtures.alphaCodes(output.pixelBuffer),
            try R13PixelLayoutTestFixtures.alphaCodes(baseline),
            "The native 420v guide must not replace sixteen-bit alpha storage."
        )
        try assertPremultipliedColorInvariant(
            output.pixelBuffer,
            format: format
        )
        XCTAssertNotEqual(
            try R13PixelLayoutTestFixtures.lumaCodes(output.pixelBuffer),
            try R13PixelLayoutTestFixtures.lumaCodes(baseline),
            "The live Low-Latency processor must measurably affect the output."
        )
        await session.finish()
        fixture.frame.resourceLifetimeToken.release()
        XCTAssertEqual(fixture.releaseProbe.value, 1)
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

    func testQualityJobRouteResolverUsesNativeTwoTimesThenExactFinishFor720p()
        throws {
        let resolved = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: .p720,
                targetResolution: .p1080,
                strategyPreference: .automatic,
                runtimeSupportedScaleFactors: [2, 4]
            )
        )

        XCTAssertEqual(
            resolved.releaseScalePlan,
            .productQualified(.scale3Over2)
        )
        XCTAssertTrue(resolved.requiresAdaptiveNativeExecution)
        let plan = try XCTUnwrap(resolved.adaptiveNativePlan)
        XCTAssertEqual(plan.requestedSourceResolution, .p720)
        XCTAssertEqual(plan.nativeSourceResolution, .p720)
        XCTAssertEqual(plan.nativeTargetResolution, .p1440)
        XCTAssertEqual(plan.requestedTargetResolution, .p1080)
        XCTAssertEqual(plan.nativeScaleFactor, 2)
        XCTAssertTrue(plan.requiresExactGeometryFinish)
        XCTAssertEqual(resolved.binding.intent, .quality)
        XCTAssertEqual(resolved.binding.subjectID, .quality2x)
        XCTAssertEqual(resolved.binding.route.sourceResolution, .p720)
        XCTAssertEqual(resolved.binding.route.targetResolution, .p1440)
        XCTAssertNotEqual(
            resolved.binding.subjectID,
            .quality1p5xContract
        )
    }

    func testQualityJobRouteResolverUsesAdaptivePlanForArbitraryGeometry()
        throws {
        let source = VideoResolution(width: 854, height: 480)
        let target = VideoResolution(width: 1_282, height: 720)
        let resolved = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: source,
                targetResolution: target,
                strategyPreference: .automatic,
                runtimeSupportedScaleFactors: [2, 4]
            )
        )

        guard case .adaptiveMPSLanczos(let releasePlan) =
                resolved.releaseScalePlan else {
            return XCTFail("Expected an adaptive release scale plan.")
        }
        XCTAssertEqual(releasePlan.processingSourceResolution, source)
        let plan = try XCTUnwrap(resolved.adaptiveNativePlan)
        XCTAssertEqual(plan.requestedSourceResolution, source)
        XCTAssertEqual(
            plan.nativeTargetResolution,
            VideoResolution(width: 1_708, height: 960)
        )
        XCTAssertEqual(plan.requestedTargetResolution, target)
        XCTAssertTrue(plan.requiresExactGeometryFinish)
        XCTAssertEqual(resolved.binding.route.scaleFactor, .two)
    }

    func testQualityJobRouteResolverBindsExtendedExplicitButNotAutomaticRoute()
        throws {
        let format = MediaVideoFormat.hdrBT2020PQ(
            masteringDisplayColorVolume:
                Data(repeating: 0x27, count: 24),
            contentLightLevelInfo:
                Data([0x01, 0x02, 0x03, 0x04])
        )
        let explicit = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .videoToolboxQuality,
                videoFormat: format,
                presentationSourceResolution: .p1080,
                targetResolution: .p2160,
                strategyPreference: .automatic,
                runtimeSupportedScaleFactors: [2, 4]
            )
        )

        XCTAssertTrue(explicit.requiresAdaptiveNativeExecution)
        XCTAssertEqual(
            explicit.adaptiveNativePlan?.videoFormat,
            format
        )
        XCTAssertEqual(explicit.binding.route.scaleFactor, .two)
        XCTAssertNil(
            try R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .automatic,
                videoFormat: format,
                presentationSourceResolution: .p1080,
                targetResolution: .p2160,
                strategyPreference: .automatic,
                runtimeSupportedScaleFactors: [2, 4]
            )
        )
    }

    func testQualityJobRouteResolverDoesNotBindUnsupportedAutomaticExactRoute()
        throws {
        XCTAssertNil(
            try R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .automatic,
                videoFormat: .sdrBT709,
                presentationSourceResolution: .p1080,
                targetResolution: .p2160,
                strategyPreference: .automatic,
                runtimeSupportedScaleFactors: [4]
            )
        )

        let explicit = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: .p1080,
                targetResolution: .p2160,
                strategyPreference: .automatic,
                runtimeSupportedScaleFactors: [4]
            )
        )
        XCTAssertTrue(explicit.requiresAdaptiveNativeExecution)
        XCTAssertEqual(explicit.binding.route.scaleFactor, .four)
        XCTAssertEqual(
            explicit.adaptiveNativePlan?.nativeTargetResolution,
            VideoResolution(width: 7_680, height: 4_320)
        )
        XCTAssertEqual(
            explicit.adaptiveNativePlan?.requestedTargetResolution,
            .p2160
        )
    }

    func testExplicitQualityRequirementExcludesAutomaticRouting() {
        XCTAssertTrue(
            R13VideoToolboxQualityJobRouteResolver
                .explicitlyRequiresQuality(
                    enginePreference: .videoToolboxQuality
                )
        )
        for mode in UpscaleMode.allCases {
            XCTAssertFalse(
                R13VideoToolboxQualityJobRouteResolver
                    .explicitlyRequiresQuality(
                        enginePreference: .automatic
                    ),
                mode.rawValue
            )
        }
    }

    func testDynamicQualityRouteAdmissionAcceptsOnlyStructuralQualityContract()
        throws {
        let resolved = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: .p720,
                targetResolution: .p1080,
                strategyPreference: .automatic,
                runtimeSupportedScaleFactors: [2]
            )
        )
        try R04VTNativeQualityRouteAdmission.validate(
            resolved.binding
        )
        let catalogBinding = try XCTUnwrap(
            R04VideoToolboxNativeRouteSelector.exactBinding(
                sourceResolution: .p1080,
                targetResolution: .p2160,
                intent: .quality
            )
        )
        try R04VTNativeQualityRouteAdmission.validate(
            catalogBinding
        )

        let route = resolved.binding.route
        let malformedRoute = try R04VideoToolboxRouteDescriptor(
            subjectID: route.subjectID,
            routeID: route.routeID,
            capabilityID: "A02",
            backendKind: route.backendKind,
            sourceResolution: route.sourceResolution,
            targetResolution: route.targetResolution,
            scaleFactor: route.scaleFactor,
            gate: route.gate,
            configurationContract: route.configurationContract,
            temporalPolicy: route.temporalPolicy,
            opticalFlowRole: route.opticalFlowRole,
            productDefaultEligibility:
                route.productDefaultEligibility,
            productQualification: route.productQualification
        )
        XCTAssertThrowsError(
            try R04VTNativeQualityRouteAdmission.validate(
                R04VideoToolboxNativeRouteBinding(
                    intent: .quality,
                    route: malformedRoute
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? VTNativeSuperResolutionError,
                .rejected(.routeContractMismatch)
            )
        }
    }

    func testAdaptiveQualityPlanUsesLargestSupportedNativeFactorBeforeExactFinish()
        throws {
        let presentationSource = VideoResolution(
            width: 480,
            height: 271
        )
        let processingSource = VideoResolution(width: 480, height: 272)
        let requestedTarget = VideoResolution(
            width: 3_840,
            height: 2_168
        )
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            presentationSourceResolution: presentationSource,
            requestedSourceResolution: processingSource,
            nativeSourceResolution: processingSource,
            requestedTargetResolution: requestedTarget,
            runtimeSupportedScaleFactors: [2, 4]
        )

        XCTAssertEqual(plan.path, .quality)
        XCTAssertEqual(
            plan.presentationSourceResolution,
            presentationSource
        )
        XCTAssertEqual(plan.requestedSourceResolution, processingSource)
        XCTAssertEqual(plan.nativeSourceResolution, processingSource)
        XCTAssertEqual(
            plan.nativeTargetResolution,
            VideoResolution(width: 1_920, height: 1_088)
        )
        XCTAssertEqual(plan.nativeScaleFactor, 4)
        XCTAssertFalse(plan.requiresInputPreparation)
        XCTAssertTrue(plan.requiresExactGeometryFinish)
        XCTAssertEqual(
            plan.stableIdentity,
            "vt-adaptive-native-v2.quality."
                + "format-nv12_video_range_8_bit.bt_709.bt_709.none."
                + "no-mastering-display.no-content-light-level."
                + "preservation-rgba-half-native-roundtrip-original-storage."
                + "presentation-source-480x271."
                + "input-source-480x272.native-source-480x272."
                + "native-target-1920x1088."
                + "requested-target-3840x2168.scale-bits-40800000"
        )
    }

    func testAdaptiveInputPreparationFailureHasStableTypedIdentity() {
        let error = VTNativeSuperResolutionError.failed(.inputPreparation)

        XCTAssertEqual(
            error,
            .failed(.inputPreparation)
        )
        XCTAssertEqual(
            VTNativeSuperResolutionFailureReason.inputPreparation.rawValue,
            "input_preparation"
        )
    }

    @available(macOS 26.0, *)
    func testAdaptiveNativePlansCarryEveryRegisteredFormatIdentity() throws {
        for format in r04VTFormatMatrix {
            let plan = try VTAdaptiveNativePlanAdmission.makeLowLatencyPlan(
                videoFormat: format,
                presentationSourceResolution: .p270,
                requestedSourceResolution: .p270,
                nativeSourceResolution: .p270,
                requestedTargetResolution: .p1080,
                runtimeSupportedScaleFactors: [4]
            )

            XCTAssertEqual(plan.videoFormat, format, format.description)
            XCTAssertTrue(
                plan.stableIdentity.contains(
                    R13ReleaseVideoFormatBinding(format).identityComponent
                ),
                format.description
            )
            XCTAssertEqual(
                try VTAdaptiveMediaVideoFormatContract.makeColorDescription(
                    for: format
                ).range,
                format.pixelStorage.codeRange == .video ? .video : .full,
                format.description
            )
        }
    }

    @available(macOS 26.0, *)
    func testQualityRGBAHalfBridgePreservesEveryFormatAndMetadata() throws {
        let resolution = VideoResolution(width: 16, height: 16)
        for format in r04VTFormatMatrix {
            let source = try makeFormatBuffer(
                format: format,
                resolution: resolution,
                offset: 1
            )
            CVBufferSetAttachment(
                source,
                r04VTCustomAttachmentKey,
                "retained" as CFString,
                .shouldNotPropagate
            )
            let native = try R04VideoToolboxTestBuffers.makePixelBuffer(
                resolution,
                pixelFormat: VTNativeQualityPixelBufferBridge.nativePixelFormat
            )
            let output = try R04VideoToolboxTestBuffers.makePixelBuffer(
                resolution,
                pixelFormat: format.pixelStorage.pixelFormat
            )
            let bridge = try VTNativeQualityPixelBufferBridge(
                videoFormat: format
            )

            try bridge.convertVideoFormat(
                source,
                toNativeRGBAHalf: native,
                resolution: resolution
            )
            try bridge.convertNativeRGBAHalf(
                native,
                toVideoFormat: output,
                resolution: resolution,
                metadataSource: source
            )

            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(output),
                format.pixelStorage.pixelFormat,
                format.description
            )
            try R13MediaVideoFormatContract.validate(
                output,
                resolution: resolution,
                format: format
            )
            try R13PixelLayoutProcessor.validateStoredCodes(output)
            XCTAssertEqual(
                CVBufferCopyAttachment(output, r04VTCustomAttachmentKey, nil)
                    as? String,
                "retained",
                format.description
            )
            XCTAssertEqual(
                CVBufferCopyAttachment(
                    native,
                    kCVImageBufferColorPrimariesKey,
                    nil
                ) as? String,
                format.colorPrimaries.cmValue,
                format.description
            )
            XCTAssertEqual(
                CVBufferCopyAttachment(
                    native,
                    kCVImageBufferTransferFunctionKey,
                    nil
                ) as? String,
                format.transferFunction.cmValue,
                format.description
            )
        }
    }

    @available(macOS 26.0, *)
    func testQualityAlphaRestorationRetainsEveryAlphaStorage() throws {
        let resolution = VideoResolution(width: 16, height: 16)
        for format in r04VTFormatMatrix where format.hasAlpha {
            let source = try makeFormatBuffer(
                format: format,
                resolution: resolution,
                offset: 3
            )
            let destination = try makeFormatBuffer(
                format: format,
                resolution: resolution,
                offset: 19
            )
            try R04VideoToolboxTestBuffers.fillAlphaWithMinimum(destination)
            let expectedAlpha = try R13PixelLayoutTestFixtures.alphaCodes(
                source
            )
            let originalLuma = try R13PixelLayoutTestFixtures.lumaCodes(
                destination
            )

            try VTNativeAlphaStoragePreserver.restoreAlpha(
                from: source,
                to: destination
            )

            XCTAssertEqual(
                try R13PixelLayoutTestFixtures.alphaCodes(destination),
                expectedAlpha,
                format.description
            )
            XCTAssertEqual(
                try R13PixelLayoutTestFixtures.lumaCodes(destination),
                originalLuma,
                format.description
            )
        }
    }

    @available(macOS 26.0, *)
    func testQualityRestorationEnforcesEveryPremultipliedAlphaStorage()
        throws {
        let resolution = VideoResolution(width: 16, height: 16)
        let formats = r04VTPremultipliedAlphaFormats
        XCTAssertEqual(formats.count, 4)

        for format in formats {
            let alphaCarrier = try makeConstantFormatBuffer(
                format: format,
                resolution: resolution,
                red: 0.01,
                green: 0.03,
                blue: 0.06,
                alpha: 0.5
            )
            let destination = try makeConstantFormatBuffer(
                format: format,
                resolution: resolution,
                red: 1,
                green: 1,
                blue: 1,
                alpha: 1
            )
            let expectedAlpha = try R13PixelLayoutTestFixtures.alphaCodes(
                alphaCarrier
            )
            try assertTranslucentAlpha(expectedAlpha, format: format)
            try assertPremultipliedColorInvariant(
                alphaCarrier,
                format: format
            )

            try VTNativeAlphaStoragePreserver.restoreAlpha(
                from: alphaCarrier,
                to: destination
            )
            try R13PremultipliedAlphaOutputPostcondition.reconcile(
                destination,
                format: format
            )

            XCTAssertEqual(
                try R13PixelLayoutTestFixtures.alphaCodes(destination),
                expectedAlpha,
                format.description
            )
            try assertPremultipliedColorInvariant(
                destination,
                format: format
            )
            try R13MediaVideoFormatContract.validate(
                destination,
                resolution: resolution,
                format: format
            )
        }
    }

    @available(macOS 26.0, *)
    func testQualityPostconditionLeavesStraightAndOpaqueColorUnclamped()
        throws {
        let resolution = VideoResolution(width: 16, height: 16)
        let straight = MediaVideoFormat.sdrBT709WithAlpha(mode: .straight)
        let alphaCarrier = try makeConstantFormatBuffer(
            format: straight,
            resolution: resolution,
            red: 1,
            green: 1,
            blue: 1,
            alpha: 0.25
        )
        let destination = try makeConstantFormatBuffer(
            format: straight,
            resolution: resolution,
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1
        )
        let colorBefore = try packedBGRAColorCodes(destination)
        let expectedAlpha = try R13PixelLayoutTestFixtures.alphaCodes(
            alphaCarrier
        )

        try VTNativeAlphaStoragePreserver.restoreAlpha(
            from: alphaCarrier,
            to: destination
        )
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            destination,
            format: straight
        )

        XCTAssertEqual(try packedBGRAColorCodes(destination), colorBefore)
        XCTAssertEqual(
            try R13PixelLayoutTestFixtures.alphaCodes(destination),
            expectedAlpha
        )

        let opaque = try makeConstantFormatBuffer(
            format: .sdrBT709,
            resolution: resolution,
            red: 1,
            green: 1,
            blue: 1,
            alpha: 1
        )
        let opaqueBefore = try R13TightPixelFrame(capturing: opaque)
        try R13PremultipliedAlphaOutputPostcondition.reconcile(
            opaque,
            format: .sdrBT709
        )
        XCTAssertEqual(
            try R13TightPixelFrame(capturing: opaque),
            opaqueBefore
        )
    }

    @available(macOS 26.0, *)
    func testLowLatencyGuideBridgeAcceptsEveryRegisteredFormatExplicitly()
        throws {
        let resolution = VideoResolution(width: 16, height: 16)
        for format in r04VTFormatMatrix {
            let source = try makeFormatBuffer(
                format: format,
                resolution: resolution,
                offset: 5
            )
            let guide = try R04VideoToolboxTestBuffers.makeNV12(resolution)
            let bridge = try VTNativeLowLatencyGuideBridge(
                videoFormat: format
            )

            try bridge.convertToNativeGuide(
                source,
                destination: guide,
                resolution: resolution
            )

            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(guide),
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                format.description
            )
            XCTAssertEqual(
                CVBufferCopyAttachment(
                    guide,
                    kCVImageBufferColorPrimariesKey,
                    nil
                ) as? String,
                format.colorPrimaries.cmValue,
                format.description
            )
            XCTAssertEqual(
                CVBufferCopyAttachment(
                    guide,
                    kCVImageBufferTransferFunctionKey,
                    nil
                ) as? String,
                format.transferFunction.cmValue,
                format.description
            )
            XCTAssertNil(
                CVBufferCopyAttachment(
                    guide,
                    kCVImageBufferAlphaChannelModeKey,
                    nil
                ),
                format.description
            )
        }
    }

    @available(macOS 26.0, *)
    func testLowLatencyNativeGuideMateriallyAffectsEveryPreservedStorage()
        throws {
        let resolution = VideoResolution(width: 16, height: 16)
        for format in r04VTFormatMatrix {
            let carrier = try makeFormatBuffer(
                format: format,
                resolution: resolution,
                offset: 7
            )
            let baselineGuide = try R04VideoToolboxTestBuffers.makeNV12(
                resolution
            )
            let nativeGuide = try R04VideoToolboxTestBuffers.makeNV12(
                resolution
            )
            try R04VideoToolboxTestBuffers.fillGuide(
                baselineGuide,
                luma: { _, _ in 96 }
            )
            try R04VideoToolboxTestBuffers.fillGuide(
                nativeGuide,
                luma: { column, row in
                    (column + row).isMultiple(of: 2) ? 108 : 96
                }
            )
            try R13PremultipliedAlphaOutputPostcondition.reconcile(
                carrier,
                format: format
            )
            let protectedBefore = try R04VideoToolboxTestBuffers
                .protectedComponentCodes(carrier)
            let expectedAlpha = try R13PixelLayoutTestFixtures.alphaCodes(
                carrier
            )
            let before = try R13TightPixelFrame(capturing: carrier)

            let evidence = try VTNativeLowLatencyGuideComposite.apply(
                nativeGuide: nativeGuide,
                baselineGuide: baselineGuide,
                to: carrier,
                resolution: resolution,
                format: format
            )
            let after = try R13TightPixelFrame(capturing: carrier)

            XCTAssertGreaterThan(
                evidence.guideApplicationChangedSampleCount,
                0,
                format.description
            )
            XCTAssertEqual(
                evidence.nativeGuideChangedSampleCount,
                resolution.width * resolution.height / 2,
                format.description
            )
            XCTAssertNotEqual(before.planes[0], after.planes[0], format.description)
            if format.alphaMode == .premultiplied {
                XCTAssertEqual(
                    try R13PixelLayoutTestFixtures.alphaCodes(carrier),
                    expectedAlpha,
                    format.description
                )
            } else {
                XCTAssertEqual(
                    try R04VideoToolboxTestBuffers
                        .protectedComponentCodes(carrier),
                    protectedBefore,
                    format.description
                )
            }
            try R13MediaVideoFormatContract.validate(
                carrier,
                resolution: resolution,
                format: format
            )
            try R13PixelLayoutProcessor.validateStoredCodes(carrier)
        }
    }

    @available(macOS 26.0, *)
    func testLowLatencyCompositeEnforcesEveryPremultipliedAlphaStorage()
        throws {
        let resolution = VideoResolution(width: 16, height: 16)
        let formats = r04VTPremultipliedAlphaFormats
        XCTAssertEqual(formats.count, 4)

        for format in formats {
            let carrier = try makeConstantFormatBuffer(
                format: format,
                resolution: resolution,
                red: 0.01,
                green: 0.03,
                blue: 0.06,
                alpha: 0.5
            )
            let expectedAlpha = try R13PixelLayoutTestFixtures.alphaCodes(
                carrier
            )
            try assertTranslucentAlpha(expectedAlpha, format: format)
            try assertPremultipliedColorInvariant(carrier, format: format)
            let before = try R13TightPixelFrame(capturing: carrier)
            let baselineGuide = try R04VideoToolboxTestBuffers.makeNV12(
                resolution
            )
            let nativeGuide = try R04VideoToolboxTestBuffers.makeNV12(
                resolution
            )
            try R04VideoToolboxTestBuffers.fillGuide(
                baselineGuide,
                luma: { _, _ in 16 }
            )
            try R04VideoToolboxTestBuffers.fillGuide(
                nativeGuide,
                luma: { _, _ in 235 }
            )

            let evidence = try VTNativeLowLatencyGuideComposite.apply(
                nativeGuide: nativeGuide,
                baselineGuide: baselineGuide,
                to: carrier,
                resolution: resolution,
                format: format
            )
            let after = try R13TightPixelFrame(capturing: carrier)

            XCTAssertEqual(
                evidence.nativeGuideChangedSampleCount,
                resolution.width * resolution.height,
                format.description
            )
            XCTAssertGreaterThan(
                evidence.guideApplicationChangedSampleCount,
                0,
                format.description
            )
            XCTAssertNotEqual(after, before, format.description)
            XCTAssertEqual(
                try R13PixelLayoutTestFixtures.alphaCodes(carrier),
                expectedAlpha,
                format.description
            )
            try assertPremultipliedColorInvariant(carrier, format: format)
        }
    }

    @available(macOS 26.0, *)
    func testLowLatencyEvidenceNamesOnlyProvisionalGuideChanges() throws {
        let resolution = VideoResolution(width: 16, height: 16)
        let format = MediaVideoFormat.sdrBT709WithAlpha(
            mode: .premultiplied
        )
        let carrier = try makeFormatBuffer(
            format: format,
            resolution: resolution,
            offset: 0
        )
        try R04VideoToolboxTestBuffers.fillPackedBGRA(
            carrier,
            blue: 128,
            green: 128,
            red: 128,
            alpha: 128
        )
        let expectedAlpha = try R13PixelLayoutTestFixtures.alphaCodes(carrier)
        let before = try R13TightPixelFrame(capturing: carrier)
        let baselineGuide = try R04VideoToolboxTestBuffers.makeNV12(resolution)
        let nativeGuide = try R04VideoToolboxTestBuffers.makeNV12(resolution)
        try R04VideoToolboxTestBuffers.fillGuide(
            baselineGuide,
            luma: { _, _ in 96 }
        )
        try R04VideoToolboxTestBuffers.fillGuide(
            nativeGuide,
            luma: { _, _ in 108 }
        )

        let evidence = try VTNativeLowLatencyGuideComposite.apply(
            nativeGuide: nativeGuide,
            baselineGuide: baselineGuide,
            to: carrier,
            resolution: resolution,
            format: format
        )

        XCTAssertEqual(
            evidence.guideApplicationChangedSampleCount,
            resolution.width * resolution.height
        )
        XCTAssertEqual(try R13TightPixelFrame(capturing: carrier), before)
        XCTAssertEqual(
            try R13PixelLayoutTestFixtures.alphaCodes(carrier),
            expectedAlpha
        )
        try assertPremultipliedColorInvariant(carrier, format: format)
    }

    func testAdaptiveOddHeightPlanAdmitsOnlyItsEvenCeilingInput() throws {
        let presentationSource = VideoResolution(
            width: 480,
            height: 271
        )
        let processingSource = VideoResolution(width: 480, height: 272)
        let requestedTarget = VideoResolution(
            width: 1_920,
            height: 1_084
        )
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            presentationSourceResolution: presentationSource,
            requestedSourceResolution: processingSource,
            nativeSourceResolution: processingSource,
            requestedTargetResolution: requestedTarget,
            runtimeSupportedScaleFactors: [4]
        )

        XCTAssertEqual(
            plan.presentationSourceResolution,
            presentationSource
        )
        XCTAssertEqual(plan.requestedSourceResolution, processingSource)
        XCTAssertEqual(
            plan.nativeTargetResolution,
            VideoResolution(width: 1_920, height: 1_088)
        )
        XCTAssertTrue(plan.requiresExactGeometryFinish)
        XCTAssertThrowsError(
            try VTAdaptiveNativePlanAdmission.makeQualityPlan(
                presentationSourceResolution: presentationSource,
                requestedSourceResolution: VideoResolution(
                    width: 480,
                    height: 274
                ),
                nativeSourceResolution: VideoResolution(
                    width: 480,
                    height: 274
                ),
                requestedTargetResolution: requestedTarget,
                runtimeSupportedScaleFactors: [4]
            )
        ) { error in
            XCTAssertEqual(
                error as? VTNativeSuperResolutionError,
                .rejected(.routeContractMismatch)
            )
        }
    }

    func testAdaptiveQualityPlanExposesPreparedNativeSourceSeparately() throws {
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            presentationSourceResolution: .p1440,
            requestedSourceResolution: .p1440,
            nativeSourceResolution: .p1080,
            requestedTargetResolution: .p2160,
            runtimeSupportedScaleFactors: [2]
        )

        XCTAssertEqual(plan.requestedSourceResolution, .p1440)
        XCTAssertEqual(plan.nativeSourceResolution, .p1080)
        XCTAssertEqual(plan.nativeTargetResolution, .p2160)
        XCTAssertTrue(plan.requiresInputPreparation)
        XCTAssertFalse(plan.requiresExactGeometryFinish)
    }

    func testAdaptiveLowLatencyPlanAdmitsRuntimeFactorAtActualDimensions()
        throws {
        let source = VideoResolution(width: 1_024, height: 576)
        let requestedTarget = VideoResolution(width: 1_152, height: 648)
        let plan = try VTAdaptiveNativePlanAdmission.makeLowLatencyPlan(
            presentationSourceResolution: source,
            requestedSourceResolution: source,
            nativeSourceResolution: source,
            requestedTargetResolution: requestedTarget,
            runtimeSupportedScaleFactors: [1.25]
        )

        XCTAssertEqual(plan.path, .lowLatency)
        XCTAssertEqual(plan.nativeScaleFactor, 1.25)
        XCTAssertEqual(
            plan.nativeTargetResolution,
            VideoResolution(width: 1_280, height: 720)
        )
        XCTAssertTrue(plan.requiresExactGeometryFinish)
    }

    func testAdaptivePlanAcceptsOneOutputPixelAspectRounding() throws {
        let source = VideoResolution(width: 854, height: 480)
        let roundedTarget = VideoResolution(width: 1_280, height: 720)

        XCTAssertTrue(
            R13AspectRatioContract.preservesWithinOneOutputPixel(
                source: source,
                target: roundedTarget
            )
        )
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            presentationSourceResolution: source,
            requestedSourceResolution: source,
            nativeSourceResolution: source,
            requestedTargetResolution: roundedTarget,
            runtimeSupportedScaleFactors: [2]
        )

        XCTAssertEqual(
            plan.nativeTargetResolution,
            VideoResolution(width: 1_708, height: 960)
        )
        XCTAssertTrue(plan.requiresExactGeometryFinish)
    }

    func testAdaptiveLowLatencyPlanRejectsWhenRuntimeReportsNoUsableFactor() {
        XCTAssertThrowsError(
            try VTAdaptiveNativePlanAdmission.makeLowLatencyPlan(
                presentationSourceResolution: .p720,
                requestedSourceResolution: .p720,
                nativeSourceResolution: .p720,
                requestedTargetResolution: .p1080,
                runtimeSupportedScaleFactors: []
            )
        ) { error in
            XCTAssertEqual(
                error as? VTNativeSuperResolutionError,
                .rejected(.exactDimensionScaleUnsupported)
            )
        }
    }

    @available(macOS 26.0, *)
    func testAdaptiveSessionRunsSelectedNativeBeforeFinisherAndPreservesTiming()
        async throws {
        let processingSource = VideoResolution.p270
        let nativeOutputResolution = VideoResolution.p1080
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            presentationSourceResolution: .p270,
            requestedSourceResolution: processingSource,
            nativeSourceResolution: processingSource,
            requestedTargetResolution: .p2160,
            runtimeSupportedScaleFactors: [4]
        )
        let processor = R04AdaptiveNativeProcessorRecorder(
            behavior: .processed(nativeOutputResolution)
        )
        let finisherCount = R04SynchronousCounter()
        let session = try VTAdaptiveNativeUpscaleSession(
            plan: plan,
            nativeProcessor: processor,
            exactGeometryFinisher: { nativeOutput, nativeResolution, target, signal in
                XCTAssertFalse(signal.isCancelled)
                XCTAssertEqual(nativeResolution, nativeOutputResolution)
                XCTAssertEqual(target, .p2160)
                XCTAssertEqual(CVPixelBufferGetWidth(nativeOutput), 1_920)
                finisherCount.increment()
                return try R04VideoToolboxTestBuffers.makeNV12(.p2160)
            }
        )
        let presentationTimestamp = CMTime(value: 90, timescale: 30)
        let duration = CMTime(value: 1, timescale: 30)
        let fixture = try makeFrame(
            resolution: processingSource,
            sequence: 7,
            tokenPrefix: "r04.adaptive-quality",
            presentationTimestamp: presentationTimestamp,
            duration: duration
        )

        let output = try await session.process(
            fixture.frame,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )

        XCTAssertEqual(output.sequenceNumber, 7)
        XCTAssertEqual(output.presentationTimestamp, presentationTimestamp)
        XCTAssertEqual(output.duration, duration)
        XCTAssertEqual(output.path, .quality)
        XCTAssertEqual(output.nativeSourceResolution, processingSource)
        XCTAssertEqual(
            output.nativeOutputResolution,
            nativeOutputResolution
        )
        XCTAssertEqual(output.requestedTargetResolution, .p2160)
        XCTAssertTrue(output.usedExactGeometryFinisher)
        XCTAssertEqual(CVPixelBufferGetWidth(output.pixelBuffer), 3_840)
        XCTAssertEqual(processor.processCount, 1)
        XCTAssertEqual(finisherCount.value, 1)
        await session.finish()
        XCTAssertEqual(processor.finishCount, 1)
        XCTAssertEqual(processor.cancelCount, 0)
        fixture.frame.resourceLifetimeToken.release()
    }

    @available(macOS 26.0, *)
    func testAdaptiveSessionNativeFailureDoesNotInvokeFinisher() async throws {
        let processingSource = VideoResolution.p270
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            presentationSourceResolution: .p270,
            requestedSourceResolution: processingSource,
            nativeSourceResolution: processingSource,
            requestedTargetResolution: .p2160,
            runtimeSupportedScaleFactors: [4]
        )
        let processor = R04AdaptiveNativeProcessorRecorder(
            behavior: .error(.unavailable(.qualityModelDownloading))
        )
        let finisherCount = R04SynchronousCounter()
        let session = try VTAdaptiveNativeUpscaleSession(
            plan: plan,
            nativeProcessor: processor,
            exactGeometryFinisher: { _, _, _, _ in
                finisherCount.increment()
                return try R04VideoToolboxTestBuffers.makeNV12(.p2160)
            }
        )
        let fixture = try makeFrame(
            resolution: processingSource,
            sequence: 0,
            tokenPrefix: "r04.adaptive-no-fallback"
        )

        do {
            _ = try await session.process(
                fixture.frame,
                cancellation: AppleUpscaleOperationCancellationSignal()
            )
            XCTFail("Expected selected native path failure")
        } catch {
            XCTAssertEqual(
                error as? VTNativeSuperResolutionError,
                .unavailable(.qualityModelDownloading)
            )
        }
        XCTAssertEqual(processor.processCount, 1)
        XCTAssertEqual(finisherCount.value, 0)
        await session.cancel()
        XCTAssertEqual(processor.cancelCount, 1)
        fixture.frame.resourceLifetimeToken.release()
    }

    @available(macOS 26.0, *)
    func testAdaptiveSessionCancelSignalsInflightNativeWorkAndWaitsForTeardown()
        async throws {
        let plan = try VTAdaptiveNativePlanAdmission.makeQualityPlan(
            presentationSourceResolution: .p1080,
            requestedSourceResolution: .p1080,
            nativeSourceResolution: .p1080,
            requestedTargetResolution: .p2160,
            runtimeSupportedScaleFactors: [2]
        )
        let processor = R04AdaptiveNativeProcessorRecorder(
            behavior: .waitForCancellation
        )
        let session = try VTAdaptiveNativeUpscaleSession(
            plan: plan,
            nativeProcessor: processor
        )
        let fixture = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "r04.adaptive-cancel"
        )
        let processing = Task {
            try await session.process(
                fixture.frame,
                cancellation: AppleUpscaleOperationCancellationSignal()
            )
        }
        while processor.processCount == 0 { await Task.yield() }

        await session.cancel()

        do {
            _ = try await processing.value
            XCTFail("Expected operation cancellation")
        } catch {
            XCTAssertEqual(
                error as? VTNativeSuperResolutionError,
                .rejected(.operationCancelled)
            )
        }
        XCTAssertEqual(processor.processCount, 1)
        XCTAssertEqual(processor.cancelCount, 1)
        XCTAssertEqual(processor.finishCount, 0)
        fixture.frame.resourceLifetimeToken.release()
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

    private func makeNativeProductIdentityFixture(
        _ subjectID: R04VideoToolboxSubjectID
    ) async throws -> (
        backend: R04VideoToolboxBackend,
        observation: R04VTNativeCapabilityObservation,
        session: any AppleUpscaleSession,
        identity: AppleUpscaleRouteIdentity
    ) {
        let route = try XCTUnwrap(
            R04VideoToolboxRouteCatalog.route(subjectID)
        )
        let diagnostics = R04VideoToolboxTestDiagnostics.valid(
            for: route
        )
        let runtime: R04RecordingVideoToolboxRuntime
        let modelAssetsIdentity: AppleUpscaleModelAssetsIdentity
        switch route.backendKind {
        case .quality:
            runtime = R04RecordingVideoToolboxRuntime(
                qualitySupport: .observed(true),
                diagnosticsBehavior: .observed(diagnostics)
            )
            modelAssetsIdentity = .appleConfigurationManaged(
                configurationIdentity: route.configurationIdentity,
                readiness: .ready
            )
        case .lowLatency:
            runtime = R04RecordingVideoToolboxRuntime(
                lowLatencySupport: .observed([route.scaleFactor]),
                diagnosticsBehavior: .observed(diagnostics)
            )
            modelAssetsIdentity = .notRequired
        case .optionalFlowSupport:
            throw R04VideoToolboxAdapterTestError.sessionNotCreated
        }
        let backend = try R04VideoToolboxBackend(
            subjectID: subjectID,
            modelAssetsIdentity: modelAssetsIdentity,
            runtimeFactory: { runtime },
            admissionPolicy: .nativeProduct
        )
        let capability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .productQualified
        )
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: .product,
            policyIdentity: backend.routeIdentity.policyIdentity
        )
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        guard case .created(let session) = outcome else {
            throw R04VideoToolboxAdapterTestError.sessionNotCreated
        }
        let identity = await session.identity
        return (
            backend,
            R04VTNativeCapabilityObservation(
                route: route,
                capability: capability,
                status: .runnable,
                diagnostics: diagnostics
            ),
            session,
            identity
        )
    }

    private func alternateAcceptedDiagnostics(
        for route: R04VideoToolboxRouteDescriptor
    ) throws -> R04VideoToolboxConfigurationDiagnostics {
        switch route.backendKind {
        case .quality:
            return R04VideoToolboxTestDiagnostics.valid(
                for: route,
                usesPrecomputedFlow: true
            )
        case .lowLatency:
            let original = R04VideoToolboxTestDiagnostics.valid(
                for: route
            )
            return R04VideoToolboxConfigurationDiagnostics(
                nativeIdentity: original.nativeIdentity,
                supportedPixelFormats: [
                    R04VideoToolboxRouteCatalog.pixelFormat,
                    kCVPixelFormatType_32BGRA
                ],
                modelStatus: original.modelStatus,
                processingMode: original.processingMode
            )
        case .optionalFlowSupport:
            throw R04VideoToolboxAdapterTestError.sessionNotCreated
        }
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

    private func makeFormatBuffer(
        format: MediaVideoFormat,
        resolution: VideoResolution,
        offset: Int
    ) throws -> CVPixelBuffer {
        let pixelBuffer = try R13PixelLayoutTestFixtures.makeEffectBuffer(
            pixelFormat: format.pixelStorage.pixelFormat,
            width: resolution.width,
            height: resolution.height,
            offset: offset
        )
        R13MediaVideoFormatContract.install(
            format,
            on: pixelBuffer,
            resolution: resolution
        )
        try R13MediaVideoFormatContract.validate(
            pixelBuffer,
            resolution: resolution,
            format: format
        )
        return pixelBuffer
    }

    private func makeConstantFormatBuffer(
        format: MediaVideoFormat,
        resolution: VideoResolution,
        red: Float16,
        green: Float16,
        blue: Float16,
        alpha: Float16
    ) throws -> CVPixelBuffer {
        let pixelBuffer = try makeFormatBuffer(
            format: format,
            resolution: resolution,
            offset: 0
        )
        var components: [Float16] = []
        components.reserveCapacity(
            resolution.width * resolution.height
                * R05LinearRGBA16FloatFrame.componentCount
        )
        for _ in 0..<(resolution.width * resolution.height) {
            components.append(red)
            components.append(green)
            components.append(blue)
            components.append(alpha)
        }
        let frame = try R05LinearRGBA16FloatFrame(
            width: resolution.width,
            height: resolution.height,
            components: components
        )
        try R05MetalFXFormatColorBridge.encodeClippingFiniteRGB(
            frame,
            into: pixelBuffer,
            format: format
        )
        return pixelBuffer
    }

    private func assertTranslucentAlpha(
        _ codes: [UInt16],
        format: MediaVideoFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bitDepth = try XCTUnwrap(
            format.pixelStorage.alphaBitDepth,
            file: file,
            line: line
        )
        let maximum = bitDepth == 16
            ? UInt16.max
            : UInt16((1 << bitDepth) - 1)
        XCTAssertFalse(codes.isEmpty, format.description, file: file, line: line)
        XCTAssertTrue(
            codes.allSatisfy { $0 > 0 && $0 < maximum },
            format.description,
            file: file,
            line: line
        )
    }

    private func assertPremultipliedColorInvariant(
        _ pixelBuffer: CVPixelBuffer,
        format: MediaVideoFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            format.alphaMode,
            .premultiplied,
            file: file,
            line: line
        )
        XCTAssertEqual(
            format.transferFunction,
            .bt709,
            file: file,
            line: line
        )
        let decoded = try R05MetalFXFormatColorBridge.decode(
            pixelBuffer: pixelBuffer,
            format: format
        )
        let tolerance = format.pixelStorage.bitDepth == 8 ? 0.02 : 0.005
        var foundTranslucentColor = false
        for index in stride(
            from: 0,
            to: decoded.components.count,
            by: R05LinearRGBA16FloatFrame.componentCount
        ) {
            let alpha = Double(decoded.components[index + 3])
            for component in index..<(index + 3) {
                let encoded = encodedBT709(
                    Double(decoded.components[component])
                )
                XCTAssertLessThanOrEqual(
                    encoded,
                    alpha + tolerance,
                    format.description,
                    file: file,
                    line: line
                )
                if alpha > 0, alpha < 1, encoded > 0 {
                    foundTranslucentColor = true
                }
            }
        }
        XCTAssertTrue(
            foundTranslucentColor,
            format.description,
            file: file,
            line: line
        )

        guard format.pixelStorage == .bgra8WithAlpha else { return }
        let colors = try packedBGRAColorCodes(pixelBuffer)
        let alpha = try R13PixelLayoutTestFixtures.alphaCodes(pixelBuffer)
        XCTAssertEqual(colors.count, alpha.count * 3, file: file, line: line)
        for index in alpha.indices {
            XCTAssertLessThanOrEqual(
                UInt16(colors[index * 3]),
                alpha[index],
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                UInt16(colors[index * 3 + 1]),
                alpha[index],
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                UInt16(colors[index * 3 + 2]),
                alpha[index],
                file: file,
                line: line
            )
        }
    }

    private func packedBGRAColorCodes(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> [UInt8] {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        guard layout.planes.count == 1,
              layout.planes[0].role == .packedBGRA else {
            throw R04VideoToolboxAdapterTestError.missingPlaneBaseAddress
        }
        try R13PixelLayoutProcessor.lockReadOnly(pixelBuffer)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try R13PixelBufferAccess.baseAddress(
            of: pixelBuffer,
            layout: layout,
            plane: 0
        )
        let rowBytes = R13PixelBufferAccess.rowBytes(
            of: pixelBuffer,
            layout: layout,
            plane: 0
        )
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var result: [UInt8] = []
        result.reserveCapacity(width * height * 3)
        for row in 0..<height {
            let bytes = base.advanced(by: row * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let offset = column * 4
                result.append(bytes[offset])
                result.append(bytes[offset + 1])
                result.append(bytes[offset + 2])
            }
        }
        return result
    }

    private func encodedBT709(_ linear: Double) -> Double {
        let value = min(max(linear, 0), 1)
        return value < 0.018
            ? 4.5 * value
            : 1.099 * pow(value, 0.45) - 0.099
    }

    private func makeFormatFrame(
        format: MediaVideoFormat,
        resolution: VideoResolution,
        sequence: Int,
        tokenPrefix: String,
        offset: Int = 0
    ) throws -> R04InputFrameFixture {
        let pixelBuffer = try makeFormatBuffer(
            format: format,
            resolution: resolution,
            offset: offset
        )
        let releaseProbe = R04SynchronousCounter()
        let token = try AppleUpscaleResourceLifetimeToken(
            identity: "\(tokenPrefix).\(sequence)",
            releaseAction: { releaseProbe.increment() }
        )
        return R04InputFrameFixture(
            frame: try AppleUpscaleFrame(
                sequenceNumber: sequence,
                pixelBuffer: pixelBuffer,
                presentationTimestamp: CMTime(
                    value: Int64(sequence),
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30),
                colorDescription:
                    try VTAdaptiveMediaVideoFormatContract
                    .makeColorDescription(for: format),
                metadataIdentity: AppleUpscaleMetadataIdentity(
                    "r04.format-metadata.\(sequence)"
                ),
                resourceLifetimeToken: token
            ),
            releaseProbe: releaseProbe
        )
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

private var r04VTCustomAttachmentKey: CFString {
    "com.mirmir.tests.vt-format-retention" as CFString
}

private var r04VTFormatMatrix: [MediaVideoFormat] {
    let registeredStorage = MediaVideoPixelStorage.allCases.map { storage in
        MediaVideoFormat(
            pixelStorage: storage,
            colorPrimaries: .bt709,
            transferFunction: .bt709,
            alphaMode: storage.hasAlpha ? .straight : .none
        )
    }
    let mastering = Data(repeating: 0x31, count: 24)
    let contentLight = Data([0x03, 0xE8, 0x01, 0x90])
    let semanticVariants: [MediaVideoFormat] = [
        .sdrBT2020TenBit,
        .hdrBT2020PQ(
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLG(
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020PQYUV444FullRange(
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight
        ),
        .hdrBT2020HLGYUV444FullRange(
            masteringDisplayColorVolume: mastering,
            contentLightLevelInfo: contentLight
        )
    ]
    let premultipliedAlpha = MediaVideoPixelStorage.allCases
        .filter(\.hasAlpha)
        .map { storage in
            MediaVideoFormat(
                pixelStorage: storage,
                colorPrimaries: .bt709,
                transferFunction: .bt709,
                alphaMode: .premultiplied
            )
        }
    return registeredStorage + semanticVariants + premultipliedAlpha
}

private var r04VTPremultipliedAlphaFormats: [MediaVideoFormat] {
    r04VTFormatMatrix.filter { $0.alphaMode == .premultiplied }
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

@available(macOS 26.0, *)
private enum R04AdaptiveNativeProcessorBehavior: Sendable {
    case processed(VideoResolution)
    case error(VTNativeSuperResolutionError)
    case waitForCancellation
}

@available(macOS 26.0, *)
private final class R04AdaptiveNativeProcessorRecorder:
    VTAdaptiveNativeFrameProcessing,
    @unchecked Sendable {
    private let behavior: R04AdaptiveNativeProcessorBehavior
    private let lock = NSLock()
    private var storedProcessCount = 0
    private var storedResetCount = 0
    private var storedFinishCount = 0
    private var storedCancelCount = 0

    var processCount: Int { locked { storedProcessCount } }
    var resetCount: Int { locked { storedResetCount } }
    var finishCount: Int { locked { storedFinishCount } }
    var cancelCount: Int { locked { storedCancelCount } }

    init(behavior: R04AdaptiveNativeProcessorBehavior) {
        self.behavior = behavior
    }

    func process(
        _: AppleUpscaleFrame,
        historyGeneration _: UInt64,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async throws -> CVPixelBuffer {
        increment(\R04AdaptiveNativeProcessorRecorder.storedProcessCount)
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
        switch behavior {
        case .processed(let resolution):
            return try R04VideoToolboxTestBuffers.makeNV12(resolution)
        case .error(let error):
            throw error
        case .waitForCancellation:
            while !cancellation.isCancelled, !Task.isCancelled {
                await Task.yield()
            }
            throw VTNativeSuperResolutionError.rejected(.operationCancelled)
        }
    }

    func reset() {
        increment(\R04AdaptiveNativeProcessorRecorder.storedResetCount)
    }

    func finish() {
        increment(\R04AdaptiveNativeProcessorRecorder.storedFinishCount)
    }

    func cancel() {
        increment(\R04AdaptiveNativeProcessorRecorder.storedCancelCount)
    }

    private func increment(
        _ keyPath: ReferenceWritableKeyPath<
            R04AdaptiveNativeProcessorRecorder,
            Int
        >
    ) {
        lock.lock()
        self[keyPath: keyPath] += 1
        lock.unlock()
    }

    private func locked<Value>(_ value: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value()
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

    func qualitySupport(
        sourceResolution: VideoResolution,
        scaleFactor _: R04VideoToolboxScaleFactor
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
    static func makePixelBuffer(
        _ resolution: VideoResolution,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            resolution.width,
            resolution.height,
            pixelFormat,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw R04VideoToolboxAdapterTestError.pixelBufferCreationFailed(status)
        }
        return buffer
    }

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

    static func fillGuide(
        _ pixelBuffer: CVPixelBuffer,
        luma: (_ column: Int, _ row: Int) -> UInt8
    ) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw R04VideoToolboxAdapterTestError.missingPlaneBaseAddress
        }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R04VideoToolboxAdapterTestError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            throw R04VideoToolboxAdapterTestError.missingPlaneBaseAddress
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            let rowBase = lumaBase
                .advanced(by: row * lumaStride)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                rowBase[column] = luma(column, row)
            }
        }
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let chromaActiveBytes = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) * 2
        for row in 0..<chromaHeight {
            memset(
                chromaBase.advanced(by: row * chromaStride),
                128,
                chromaActiveBytes
            )
        }
    }

    static func fillPackedBGRA(
        _ pixelBuffer: CVPixelBuffer,
        blue: UInt8,
        green: UInt8,
        red: UInt8,
        alpha: UInt8
    ) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_32BGRA else {
            throw R04VideoToolboxAdapterTestError.missingPlaneBaseAddress
        }
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw R04VideoToolboxAdapterTestError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw R04VideoToolboxAdapterTestError.missingPlaneBaseAddress
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            let bytes = base.advanced(by: row * rowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let offset = column * 4
                bytes[offset] = blue
                bytes[offset + 1] = green
                bytes[offset + 2] = red
                bytes[offset + 3] = alpha
            }
        }
    }

    static func fillAlphaWithMinimum(
        _ pixelBuffer: CVPixelBuffer
    ) throws {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        let alpha: (planeIndex: Int, componentIndex: Int)?
        if let planeIndex = layout.planes.firstIndex(
            where: { $0.role == .alpha }
        ) {
            alpha = (planeIndex, 0)
        } else {
            switch layout.planes.first?.role {
            case .packedAYCbCr:
                alpha = (0, 0)
            case .packedBGRA:
                alpha = (0, 3)
            default:
                alpha = nil
            }
        }
        guard let alpha else { return }
        try R13PixelLayoutProcessor.lockWritable(pixelBuffer)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let plane = layout.planes[alpha.planeIndex]
        let base = try R13PixelBufferAccess.baseAddress(
            of: pixelBuffer,
            layout: layout,
            plane: alpha.planeIndex
        )
        let stride = R13PixelBufferAccess.rowBytes(
            of: pixelBuffer,
            layout: layout,
            plane: alpha.planeIndex
        )
        let width = plane.width(for: CVPixelBufferGetWidth(pixelBuffer))
        let height = plane.height(for: CVPixelBufferGetHeight(pixelBuffer))
        let stored = UInt16(plane.componentBounds[alpha.componentIndex].minimum)
            << UInt16(plane.storedCodeShift)
        for row in 0..<height {
            for column in 0..<width {
                let index =
                    column * plane.componentsPerElement + alpha.componentIndex
                if plane.bytesPerComponent == 1 {
                    base.advanced(by: row * stride)
                        .assumingMemoryBound(to: UInt8.self)[index] =
                        UInt8(truncatingIfNeeded: stored)
                } else {
                    base.advanced(by: row * stride)
                        .assumingMemoryBound(to: UInt16.self)[index] = stored
                }
            }
        }
    }

    static func protectedComponentCodes(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> [UInt16] {
        let layout = try R13PixelLayoutRegistry.layout(
            for: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        try layout.validate(pixelBuffer)
        try R13PixelLayoutProcessor.lockReadOnly(pixelBuffer)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var result: [UInt16] = []
        for (planeIndex, plane) in layout.planes.enumerated() {
            let components: [Int]
            switch plane.role {
            case .luma:
                components = []
            case .interleavedChroma, .alpha:
                components = Array(0..<plane.componentsPerElement)
            case .packedAYCbCr:
                components = [0, 2, 3]
            case .packedBGRA:
                components = [3]
            }
            guard !components.isEmpty else { continue }
            let base = try R13PixelBufferAccess.baseAddress(
                of: pixelBuffer,
                layout: layout,
                plane: planeIndex
            )
            let stride = R13PixelBufferAccess.rowBytes(
                of: pixelBuffer,
                layout: layout,
                plane: planeIndex
            )
            let width = plane.width(for: CVPixelBufferGetWidth(pixelBuffer))
            let height = plane.height(for: CVPixelBufferGetHeight(pixelBuffer))
            result.reserveCapacity(result.count + width * height * components.count)
            for row in 0..<height {
                for column in 0..<width {
                    for component in components {
                        let index = column * plane.componentsPerElement + component
                        if plane.bytesPerComponent == 1 {
                            result.append(
                                UInt16(
                                    base.advanced(by: row * stride)
                                        .assumingMemoryBound(to: UInt8.self)[index]
                                )
                            )
                        } else {
                            result.append(
                                base.advanced(by: row * stride)
                                    .assumingMemoryBound(to: UInt16.self)[index]
                                    >> UInt16(plane.storedCodeShift)
                            )
                        }
                    }
                }
            }
        }
        return result
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
            kCVPixelFormatType_64RGBAHalf
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
