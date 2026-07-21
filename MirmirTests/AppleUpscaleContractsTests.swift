import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class AppleUpscaleContractsTests: XCTestCase {
    func testCapabilityRegistryPreservesOrderAndDoesNotInferEligibility() throws {
        let diagnosticID = try AppleUpscaleCapabilityID("A01")
        let fixtureID = try AppleUpscaleCapabilityID("R02-FIXTURE")
        let diagnostic = try AppleUpscaleCapability(
            id: diagnosticID,
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .notObserved,
            runtimeDisposition: .diagnosticOnly,
            backendEligibility: .notEvaluated
        )
        let fixture = try AppleUpscaleCapability(
            id: fixtureID,
            role: .primaryScaler,
            frameworkIdentity: "MirmirFixture",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
        let registry = try AppleUpscaleCapabilityRegistry(
            capabilities: [diagnostic, fixture]
        )

        XCTAssertEqual(registry.capabilities.map(\.id), [diagnosticID, fixtureID])
        XCTAssertEqual(registry.capability(for: diagnosticID), diagnostic)
        XCTAssertFalse(diagnostic.isEligible(for: .fixtureOnly))
        XCTAssertFalse(diagnostic.isEligible(for: .product))
        XCTAssertTrue(fixture.isEligible(for: .fixtureOnly))
        XCTAssertFalse(fixture.isEligible(for: .product))
    }

    func testCapabilityRegistryRejectsDuplicateAndFabricatedQualification() throws {
        let id = try AppleUpscaleCapabilityID("A01")
        let diagnostic = try AppleUpscaleCapability(
            id: id,
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .notObserved,
            runtimeDisposition: .diagnosticOnly,
            backendEligibility: .notEvaluated
        )

        XCTAssertThrowsError(
            try AppleUpscaleCapabilityRegistry(capabilities: [diagnostic, diagnostic])
        ) { error in
            XCTAssertEqual(error as? AppleUpscaleContractError, .duplicateCapabilityID("A01"))
        }
        XCTAssertThrowsError(
            try AppleUpscaleCapability(
                id: id,
                role: .primaryScaler,
                frameworkIdentity: "VideoToolbox",
                observationStatus: .notObserved,
                runtimeDisposition: .runnable,
                backendEligibility: .productQualified
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleUpscaleContractError,
                .invalidCapabilityQualification("A01")
            )
        }
    }

    func testProcessingIdentityRequiresContiguousVisibleFallback() throws {
        let primary = try makeRoute(backendID: "r02.fixture.copy-a")
        let fallback = try makeRoute(backendID: "r02.fixture.copy-b")
        let link = try AppleUpscaleFallbackLink(
            failedRoute: primary,
            selectedRoute: fallback,
            reasonCode: .backendUnavailable,
            selectedFallbackOrdinal: 0
        )
        let identity = try AppleUpscaleProcessingIdentity(
            route: fallback,
            fallbackHistory: [link]
        )

        XCTAssertEqual(identity.route.backend.backendID, "r02.fixture.copy-b")
        XCTAssertEqual(identity.route.backend.backendRevision, "1")
        XCTAssertEqual(identity.route.backend.modelAssetsIdentity, .notRequired)
        XCTAssertEqual(identity.route.configurationIdentity, "r02-fixture-copy-v1")
        XCTAssertEqual(identity.route.policyIdentity, "r02-fixture-only-v1")
        XCTAssertEqual(
            identity.route.materialDecisionIdentity,
            "r02-fixture-copy-decision-v1"
        )
        XCTAssertEqual(identity.fallbackHistory, [link])

        XCTAssertThrowsError(
            try AppleUpscaleProcessingIdentity(
                route: primary,
                fallbackHistory: [link]
            )
        ) { error in
            XCTAssertEqual(
                error as? AppleUpscaleContractError,
                .fallbackTerminalRouteMismatch
            )
        }
    }

    func testFramePreservesEveryFrozenFieldAndTokenReleasesExactlyOnce() throws {
        let counter = ReleaseCounter()
        let token = try AppleUpscaleResourceLifetimeToken(
            identity: "fixture-sequence-a.token-0",
            releaseAction: { counter.increment() }
        )
        let pixelBuffer = try makePixelBuffer()
        let color = try makeColorDescription()
        let metadata = try AppleUpscaleMetadataIdentity("fixture-sequence-a.frame-0")
        let presentationTimestamp = CMTime(value: 100, timescale: 60)
        let duration = CMTime(value: 2, timescale: 60)
        let frame = try AppleUpscaleFrame(
            sequenceNumber: 0,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: presentationTimestamp,
            duration: duration,
            colorDescription: color,
            metadataIdentity: metadata,
            resourceLifetimeToken: token
        )

        XCTAssertEqual(frame.sequenceNumber, 0)
        XCTAssertTrue(frame.pixelBuffer === pixelBuffer)
        XCTAssertEqual(frame.presentationTimestamp, presentationTimestamp)
        XCTAssertEqual(frame.duration, duration)
        XCTAssertEqual(frame.colorDescription, color)
        XCTAssertEqual(frame.metadataIdentity, metadata)
        XCTAssertTrue(frame.resourceLifetimeToken === token)
        XCTAssertFalse(token.isReleased)

        token.release()
        token.release()
        XCTAssertTrue(token.isReleased)
        XCTAssertEqual(counter.value, 1)
    }

    func testAllFiveOrchestrationOutcomesCarryCompleteRouteIdentity() throws {
        let primaryRoute = try makeRoute(backendID: "r02.fixture.copy-a")
        let fallbackRoute = try makeRoute(backendID: "r02.fixture.copy-b")
        let directFrame = try makeProcessedFrame(
            route: primaryRoute,
            fallbackHistory: []
        )
        let link = try AppleUpscaleFallbackLink(
            failedRoute: primaryRoute,
            selectedRoute: fallbackRoute,
            reasonCode: .backendUnavailable,
            selectedFallbackOrdinal: 0
        )
        let fallbackFrame = try makeProcessedFrame(
            route: fallbackRoute,
            fallbackHistory: [link]
        )
        let primaryIdentity = try AppleUpscaleProcessingIdentity(
            route: primaryRoute,
            fallbackHistory: []
        )
        let unavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: primaryIdentity,
            reason: "fixture unavailable"
        )
        let rejected = try AppleUpscaleBackendRejected(
            processingIdentity: primaryIdentity,
            reason: "fixture rejected"
        )
        let failed = try AppleUpscaleBackendFailed(
            processingIdentity: primaryIdentity,
            reason: "fixture failed"
        )
        let outcomes: [AppleUpscaleOutcome] = [
            .processed(directFrame),
            .unavailable(unavailable),
            .rejected(rejected),
            .failed(failed),
            .fallbackApplied(
                try AppleUpscaleFallbackApplied(processedFrame: fallbackFrame)
            )
        ]

        XCTAssertEqual(outcomes.count, 5)
        for outcome in outcomes {
            let identity = processingIdentity(for: outcome)
            XCTAssertFalse(identity.route.backend.backendID.isEmpty)
            XCTAssertFalse(identity.route.backend.backendRevision.isEmpty)
            XCTAssertEqual(identity.route.backend.modelAssetsIdentity, .notRequired)
            XCTAssertFalse(identity.route.configurationIdentity.isEmpty)
            XCTAssertFalse(identity.route.policyIdentity.isEmpty)
            XCTAssertFalse(identity.route.materialDecisionIdentity.isEmpty)
        }
        XCTAssertEqual(
            processingIdentity(for: outcomes[4]).fallbackHistory,
            [link]
        )
    }

    func testBackendAndActorSessionCompileThroughCommonExistentials() async throws {
        let capability = try AppleUpscaleCapability(
            id: AppleUpscaleCapabilityID("R02-FIXTURE"),
            role: .primaryScaler,
            frameworkIdentity: "MirmirFixture",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
        let registry = try AppleUpscaleCapabilityRegistry(capabilities: [capability])
        let route = try makeRoute(backendID: "r02.fixture.copy-a")
        let session = try FixtureAppleUpscaleSession(identity: route)
        let backend: any AppleUpscaleBackend = FixtureAppleUpscaleBackend(
            identity: route.backend,
            capabilityID: capability.id,
            session: session
        )
        let configuration = try AppleUpscaleSessionConfiguration(
            capabilityID: capability.id,
            sourceResolution: VideoResolution(width: 16, height: 8),
            targetResolution: VideoResolution(width: 16, height: 8),
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            configurationIdentity: route.configurationIdentity
        )
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: registry,
            admissionScope: .fixtureOnly,
            policyIdentity: route.policyIdentity
        )

        XCTAssertEqual(backend.capability(in: registry), capability)
        let creation = await backend.makeSession(
            configuration: configuration,
            context: context
        )
        guard case .created(let commonSession) = creation else {
            return XCTFail("fixture backend did not create the common session")
        }
        let observedRoute = await commonSession.identity
        XCTAssertEqual(observedRoute, route)

        let frame = try makeFrame()
        let outcome = await commonSession.submit(frame)
        guard case .unavailable(let unavailable) = outcome else {
            return XCTFail("fixture session did not return its typed backend outcome")
        }
        XCTAssertEqual(unavailable.route, route)
        await commonSession.reset(reason: .callerRequested)
        let summary = await commonSession.finish()
        XCTAssertEqual(summary.terminalizationCount, 1)
        await commonSession.cancel()
    }

    func testInvalidFrameTimingAndDimensionsFailClosed() throws {
        let pixelBuffer = try makePixelBuffer()
        let color = try makeColorDescription()
        let metadata = try AppleUpscaleMetadataIdentity("fixture.frame")
        let token = try AppleUpscaleResourceLifetimeToken(
            identity: "fixture.token",
            releaseAction: {}
        )

        XCTAssertThrowsError(
            try AppleUpscaleFrame(
                sequenceNumber: -1,
                pixelBuffer: pixelBuffer,
                presentationTimestamp: .zero,
                duration: CMTime(value: 1, timescale: 30),
                colorDescription: color,
                metadataIdentity: metadata,
                resourceLifetimeToken: token
            )
        )
        XCTAssertThrowsError(
            try AppleUpscaleFrame(
                sequenceNumber: 0,
                pixelBuffer: pixelBuffer,
                presentationTimestamp: .zero,
                duration: .zero,
                colorDescription: color,
                metadataIdentity: metadata,
                resourceLifetimeToken: token
            )
        )
        XCTAssertThrowsError(
            try AppleUpscaleSessionConfiguration(
                capabilityID: AppleUpscaleCapabilityID("R02-FIXTURE"),
                sourceResolution: VideoResolution(width: 0, height: 8),
                targetResolution: VideoResolution(width: 16, height: 8),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                configurationIdentity: "fixture"
            )
        )
    }

    private func makeFrame() throws -> AppleUpscaleFrame {
        try AppleUpscaleFrame(
            sequenceNumber: 0,
            pixelBuffer: makePixelBuffer(),
            presentationTimestamp: .zero,
            duration: CMTime(value: 1, timescale: 30),
            colorDescription: makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity("fixture.frame-0"),
            resourceLifetimeToken: AppleUpscaleResourceLifetimeToken(
                identity: "fixture.token-0",
                releaseAction: {}
            )
        )
    }

    private func makeProcessedFrame(
        route: AppleUpscaleRouteIdentity,
        fallbackHistory: [AppleUpscaleFallbackLink]
    ) throws -> AppleUpscaleProcessedFrame {
        try AppleUpscaleProcessedFrame(
            sequenceNumber: 0,
            pixelBuffer: makePixelBuffer(),
            presentationTimestamp: .zero,
            duration: CMTime(value: 1, timescale: 30),
            colorDescription: makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity("fixture.frame-0"),
            resourceLifetimeToken: AppleUpscaleResourceLifetimeToken(
                identity: "fixture.token-0",
                releaseAction: {}
            ),
            processingIdentity: AppleUpscaleProcessingIdentity(
                route: route,
                fallbackHistory: fallbackHistory
            )
        )
    }

    private func makeRoute(backendID: String) throws -> AppleUpscaleRouteIdentity {
        try AppleUpscaleRouteIdentity(
            backend: AppleUpscaleBackendIdentity(
                backendID: backendID,
                backendRevision: "1",
                modelAssetsIdentity: .notRequired
            ),
            configurationIdentity: "r02-fixture-copy-v1",
            policyIdentity: "r02-fixture-only-v1",
            materialDecisionIdentity: "r02-fixture-copy-decision-v1"
        )
    }

    private func makeColorDescription() throws -> AppleUpscaleColorDescription {
        try AppleUpscaleColorDescription(
            colorPrimaries: "ITU_R_709_2",
            transferFunction: "ITU_R_709_2",
            matrix: "ITU_R_709_2",
            chromaSiting: "left",
            range: .video
        )
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            8,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return pixelBuffer
    }

    private func processingIdentity(
        for outcome: AppleUpscaleOutcome
    ) -> AppleUpscaleProcessingIdentity {
        switch outcome {
        case .processed(let frame):
            return frame.processingIdentity
        case .unavailable(let value):
            return value.processingIdentity
        case .rejected(let value):
            return value.processingIdentity
        case .failed(let value):
            return value.processingIdentity
        case .fallbackApplied(let value):
            return value.processedFrame.processingIdentity
        }
    }
}

private actor FixtureAppleUpscaleSession: AppleUpscaleSession {
    let identity: AppleUpscaleRouteIdentity
    private let unavailable: AppleUpscaleBackendUnavailable

    init(identity: AppleUpscaleRouteIdentity) throws {
        self.identity = identity
        self.unavailable = try AppleUpscaleBackendUnavailable(
            processingIdentity: AppleUpscaleProcessingIdentity(
                route: identity,
                fallbackHistory: []
            ),
            reason: "fixture unavailable"
        )
    }

    func submit(
        _: AppleUpscaleFrame
    ) async -> AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame> {
        .unavailable(unavailable)
    }

    func reset(reason _: AppleUpscaleResetReason) async {}

    func finish() async -> AppleUpscaleSessionSummary {
        AppleUpscaleSessionSummary(
            submittedFrameCount: 1,
            processedFrameCount: 0,
            terminalizationCount: 1
        )
    }

    func cancel() async {}
}

private final class FixtureAppleUpscaleBackend: AppleUpscaleBackend, @unchecked Sendable {
    let identity: AppleUpscaleBackendIdentity
    let capabilityID: AppleUpscaleCapabilityID

    private let session: FixtureAppleUpscaleSession

    init(
        identity: AppleUpscaleBackendIdentity,
        capabilityID: AppleUpscaleCapabilityID,
        session: FixtureAppleUpscaleSession
    ) {
        self.identity = identity
        self.capabilityID = capabilityID
        self.session = session
    }

    func makeSession(
        configuration _: AppleUpscaleSessionConfiguration,
        context _: AppleUpscaleSessionContext
    ) async -> AppleUpscaleSessionCreationOutcome {
        .created(session)
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
