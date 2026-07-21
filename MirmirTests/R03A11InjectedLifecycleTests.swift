import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class R03A11InjectedLifecycleTests: XCTestCase {
    func testInjectedFixtureControlPathForwardsLifecycleAndLifetime() async throws {
        let scaler = R03A11FixtureInjectedScaler(behavior: .processed)
        let outputReleaseProbe = R02FixtureReleaseProbe()
        let backend = try makeFixtureBackend(
            scalerFactory: { _, _ in scaler },
            outputReleaseObserver: { [outputReleaseProbe] identity in
                outputReleaseProbe.recordRelease(identity: identity)
            }
        )
        let session = try await makeFixtureSession(backend: backend)
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 4,
            tokenPrefix: "r03.a11.injected-lifecycle"
        )

        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            return XCTFail("Expected the injected fixture control path to process")
        }
        XCTAssertEqual(processed.processingIdentity.route, backend.routeIdentity)
        XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(processed.sequenceNumber, fixture.frame.sequenceNumber)
        XCTAssertEqual(processed.presentationTimestamp, fixture.frame.presentationTimestamp)
        XCTAssertEqual(processed.duration, fixture.frame.duration)
        XCTAssertEqual(processed.colorDescription, fixture.frame.colorDescription)
        XCTAssertEqual(processed.metadataIdentity, fixture.frame.metadataIdentity)
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )
        XCTAssertEqual(scaler.scaleCallCount, 1)

        let outputTokenIdentity = processed.resourceLifetimeToken.identity
        processed.resourceLifetimeToken.release()
        processed.resourceLifetimeToken.release()
        XCTAssertEqual(outputReleaseProbe.releaseCount(for: outputTokenIdentity), 1)

        await session.reset(reason: AppleUpscaleResetReason.callerRequested)
        XCTAssertEqual(scaler.resetCallCount, 1)
        let summary = await session.finish()
        XCTAssertEqual(scaler.finishCallCount, 1)
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.terminalizationCount, 1)

        let cancellationScaler = R03A11FixtureInjectedScaler(behavior: .processed)
        let cancellationBackend = try makeFixtureBackend(
            scalerFactory: { _, _ in cancellationScaler }
        )
        let cancellationSession = try await makeFixtureSession(
            backend: cancellationBackend
        )
        await cancellationSession.cancel()
        XCTAssertEqual(cancellationScaler.cancelCallCount, 1)
    }

    func testInjectedFixtureControlPathMapsRuntimeAndScalingErrors() async throws {
        try await assertProcessingOutcome(
            behavior: .runtimeUnavailable,
            expectedReason: "r03_scaler_runtime_unavailable",
            expectedKind: .unavailable
        )
        try await assertProcessingOutcome(
            behavior: .failed,
            expectedReason: "r03_scaling_failed",
            expectedKind: .failed
        )
    }

    func testInjectedFixtureFactoryErrorsMapWithoutCreatingProductAdmission() async throws {
        let runtimeUnavailable = try makeFixtureBackend(
            scalerFactory: { _, _ in
                throw R03NV12ScalingError.runtimeUnavailable(
                    "r03.injected.fixture.runtime-unavailable"
                )
            }
        )
        assertCreationUnavailable(
            await runtimeUnavailable.makeSession(
                configuration: try runtimeUnavailable.makeConfiguration(),
                context: try fixtureContext()
            ),
            route: runtimeUnavailable.routeIdentity
        )

        let failed = try makeFixtureBackend(
            scalerFactory: { _, _ in
                throw R03A11InjectedTestError.factoryFailed
            }
        )
        assertCreationFailed(
            await failed.makeSession(
                configuration: try failed.makeConfiguration(),
                context: try fixtureContext()
            ),
            route: failed.routeIdentity
        )
    }

    private func assertProcessingOutcome(
        behavior: R03A11FixtureInjectedScaler.Behavior,
        expectedReason: String,
        expectedKind: R03A11InjectedOutcomeKind
    ) async throws {
        let scaler = R03A11FixtureInjectedScaler(behavior: behavior)
        let backend = try makeFixtureBackend(
            scalerFactory: { _, _ in scaler }
        )
        let session = try await makeFixtureSession(backend: backend)
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: .scale3Over2,
            sequenceNumber: 0,
            tokenPrefix: "r03.a11.injected-error.\(expectedKind.rawValue)"
        )

        let outcome = await session.submit(fixture.frame)
        let observedReason: String
        let observedRoute: AppleUpscaleRouteIdentity
        switch (expectedKind, outcome) {
        case (.unavailable, .unavailable(let unavailable)):
            observedReason = unavailable.reason
            observedRoute = unavailable.processingIdentity.route
        case (.failed, .failed(let failure)):
            observedReason = failure.reason
            observedRoute = failure.processingIdentity.route
        default:
            return XCTFail("Expected injected \(expectedKind.rawValue) outcome")
        }
        XCTAssertEqual(observedReason, expectedReason)
        XCTAssertEqual(observedRoute, backend.routeIdentity)
        XCTAssertEqual(scaler.scaleCallCount, 1)
        XCTAssertEqual(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            1
        )
        _ = await session.finish()
    }

    private func makeFixtureBackend(
        scalerFactory: @escaping R03NV12ScalerFactory,
        outputReleaseObserver: @escaping R03OutputReleaseObserver = { _ in }
    ) throws -> R03DeterministicBackend {
        let backend = try R03DeterministicBackend(
            subjectID: .mpsLanczos,
            route: .scale3Over2,
            scalerFactory: scalerFactory,
            outputReleaseObserver: outputReleaseObserver
        )
        XCTAssertEqual(backend.admissionProfile, .fixtureOnly)
        XCTAssertEqual(
            backend.routeIdentity.policyIdentity,
            R03DeterministicBackendCatalog.policyIdentity
        )
        return backend
    }

    private func makeFixtureSession(
        backend: R03DeterministicBackend
    ) async throws -> any AppleUpscaleSession {
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try fixtureContext()
        )
        guard case .created(let session) = outcome else {
            throw R03A11InjectedTestError.sessionNotCreated
        }
        return session
    }

    private func fixtureContext() throws -> AppleUpscaleSessionContext {
        try R03DeterministicBackendTestSupport.makeContext(
            subjectID: .mpsLanczos
        )
    }

    private func assertCreationUnavailable(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let unavailable) = outcome else {
            return XCTFail("Expected fixture factory unavailability", file: file, line: line)
        }
        XCTAssertEqual(unavailable.reason, "r03_capability_unavailable", file: file, line: line)
        XCTAssertEqual(unavailable.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
    }

    private func assertCreationFailed(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let failure) = outcome else {
            return XCTFail("Expected fixture factory failure", file: file, line: line)
        }
        XCTAssertEqual(failure.reason, "r03_session_creation_failed", file: file, line: line)
        XCTAssertEqual(failure.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(failure.processingIdentity.fallbackHistory.isEmpty, file: file, line: line)
    }
}

private enum R03A11InjectedOutcomeKind: String {
    case unavailable
    case failed
}

private enum R03A11InjectedTestError: Error {
    case factoryFailed
    case sessionNotCreated
}

private final class R03A11FixtureInjectedScaler: R03NV12Scaling, @unchecked Sendable {
    enum Behavior: Sendable {
        case processed
        case runtimeUnavailable
        case failed
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var scaleCalls = 0
    private var resetCalls = 0
    private var finishCalls = 0
    private var cancelCalls = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    var scaleCallCount: Int {
        locked { scaleCalls }
    }

    var resetCallCount: Int {
        locked { resetCalls }
    }

    var finishCallCount: Int {
        locked { finishCalls }
    }

    var cancelCallCount: Int {
        locked { cancelCalls }
    }

    func scale(
        source _: CVPixelBuffer,
        destination _: CVPixelBuffer,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) throws {
        locked { scaleCalls += 1 }
        switch behavior {
        case .processed:
            return
        case .runtimeUnavailable:
            throw R03NV12ScalingError.runtimeUnavailable(
                "r03.injected.fixture.runtime-unavailable"
            )
        case .failed:
            throw R03NV12ScalingError.scalingFailed(plane: 0, status: -1)
        }
    }

    func reset() {
        locked { resetCalls += 1 }
    }

    func finish() {
        locked { finishCalls += 1 }
    }

    func cancel() {
        locked { cancelCalls += 1 }
    }

    private func locked<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
