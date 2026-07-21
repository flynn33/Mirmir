import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
final class R05MetalFXSpatialBackendTests: XCTestCase {
    func testDecodedVideoRoutesRejectBeforeFactoryForFixtureAndProduct() async throws {
        let subjects: [R05MetalFXSubjectID] = [
            .temporal1p5x,
            .temporal2x,
            .denoisedTemporal1p5x,
            .denoisedTemporal2x,
            .frameInterpolation1080p
        ]
        for subject in subjects {
            let counter = R05BackendCounter()
            let backend = try makeBackend(subject, counter: counter)
            let expected = try XCTUnwrap(backend.route.decodedVideoRejectionReason)
            for scope: AppleUpscaleAdmissionScope in [.fixtureOnly, .product] {
                let outcome = await backend.makeSession(
                    configuration: try backend.makeConfiguration(),
                    context: try emptyContext(scope: scope)
                )
                guard case .rejected(let rejection) = outcome else {
                    return XCTFail("Expected decoded-video rejection for \(subject)")
                }
                XCTAssertEqual(rejection.reason, expected.rawValue)
                XCTAssertEqual(rejection.processingIdentity.route, backend.routeIdentity)
                XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)
            }
            XCTAssertEqual(counter.value, 0)
        }
    }

    func testSpatialProductAndNotObservedCapabilityNeverConstructDriver() async throws {
        for subject: R05MetalFXSubjectID in [.spatial1p5x, .spatial2x] {
            let counter = R05BackendCounter()
            let backend = try makeBackend(subject, counter: counter)

            let product = await backend.makeSession(
                configuration: try backend.makeConfiguration(),
                context: try productContext(for: backend.route)
            )
            assertCreationRejected(
                product,
                reason: R05MetalFXBackendRejectionReason
                    .productScopeForbidden.rawValue,
                route: backend.routeIdentity
            )

            let notObserved = await backend.makeSession(
                configuration: try backend.makeConfiguration(),
                context: try AppleUpscaleSessionContext(
                    capabilityRegistry: R05MetalFXRouteCatalog
                        .makeNotObservedCapabilityRegistry(),
                    admissionScope: .fixtureOnly,
                    policyIdentity: R05MetalFXRouteCatalog.policyIdentity
                )
            )
            assertCreationUnavailable(
                notObserved,
                reason: R05MetalFXBackendUnavailableReason
                    .capabilityNotObserved.rawValue,
                route: backend.routeIdentity
            )
            XCTAssertEqual(counter.value, 0)
        }
    }

    func testWrongConfigurationPolicyAndCapabilityRejectBeforeFactory() async throws {
        let counter = R05BackendCounter()
        let backend = try makeBackend(.spatial1p5x, counter: counter)
        let configuration = try AppleUpscaleSessionConfiguration(
            capabilityID: backend.capabilityID,
            sourceResolution: .p720,
            targetResolution: .p1080,
            pixelFormat: R05MetalFXColorBridge.pixelFormat,
            configurationIdentity: "wrong.configuration"
        )
        let wrongConfiguration = await backend.makeSession(
            configuration: configuration,
            context: try fixtureContext(for: backend.route)
        )
        assertCreationRejected(
            wrongConfiguration,
            reason: R05MetalFXBackendRejectionReason.sessionContractMismatch.rawValue,
            route: backend.routeIdentity
        )

        let wrongPolicy = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try AppleUpscaleSessionContext(
                capabilityRegistry: try fixtureRegistry(for: backend.route),
                admissionScope: .fixtureOnly,
                policyIdentity: "wrong.policy"
            )
        )
        assertCreationRejected(
            wrongPolicy,
            reason: R05MetalFXBackendRejectionReason.sessionContractMismatch.rawValue,
            route: backend.routeIdentity
        )

        let wrongCapability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .supportFilter,
            frameworkIdentity: "MetalFX",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
        let wrongRole = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try AppleUpscaleSessionContext(
                capabilityRegistry: AppleUpscaleCapabilityRegistry(
                    capabilities: [wrongCapability]
                ),
                admissionScope: .fixtureOnly,
                policyIdentity: R05MetalFXRouteCatalog.policyIdentity
            )
        )
        assertCreationRejected(
            wrongRole,
            reason: R05MetalFXBackendRejectionReason.sessionContractMismatch.rawValue,
            route: backend.routeIdentity
        )
        XCTAssertEqual(counter.value, 0)
    }

    func testNilNativeFactoryIsTypedUnavailableWithoutFallback() async throws {
        let backend = try R05MetalFXSpatialBackend(
            subjectID: .spatial1p5x,
            driverFactory: { _ in nil }
        )

        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try fixtureContext(for: backend.route)
        )

        assertCreationUnavailable(
            outcome,
            reason: R05MetalFXBackendUnavailableReason.nativeRuntimeUnavailable.rawValue,
            route: backend.routeIdentity
        )
    }

    func testBothSpatialRoutesPreserveIdentityAttachmentsAndLifetimes() async throws {
        for subject: R05MetalFXSubjectID in [.spatial1p5x, .spatial2x] {
            let releases = R05BackendCounter()
            let inputReleases = R05BackendCounter()
            let counter = R05BackendCounter()
            let driver = R05BackendDriver(behavior: .processed)
            let backend = try R05MetalFXSpatialBackend(
                subjectID: subject,
                driverFactory: { _ in
                    counter.increment()
                    return driver
                },
                outputReleaseObserver: { _ in releases.increment() }
            )
            let session = try await makeSession(backend)
            let fixture = try makeFrame(
                resolution: backend.route.sourceResolution,
                tokenPrefix: subject.rawValue,
                releaseCounter: inputReleases
            )

            let outcome = await session.submit(fixture)
            guard case .processed(let processed) = outcome else {
                return XCTFail("Expected fixture processing for \(subject)")
            }
            XCTAssertEqual(counter.value, 1)
            XCTAssertEqual(inputReleases.value, 1)
            XCTAssertEqual(releases.value, 0)
            XCTAssertEqual(processed.sequenceNumber, fixture.sequenceNumber)
            XCTAssertEqual(processed.presentationTimestamp, fixture.presentationTimestamp)
            XCTAssertEqual(processed.duration, fixture.duration)
            XCTAssertEqual(processed.colorDescription, fixture.colorDescription)
            XCTAssertEqual(processed.metadataIdentity, fixture.metadataIdentity)
            XCTAssertEqual(processed.processingIdentity.route, backend.routeIdentity)
            XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
            XCTAssertEqual(
                CVPixelBufferGetWidth(processed.pixelBuffer),
                backend.route.targetResolution.width
            )
            XCTAssertEqual(
                CVPixelBufferGetHeight(processed.pixelBuffer),
                backend.route.targetResolution.height
            )
            try R05MetalFXColorBridge.validate(pixelBuffer: processed.pixelBuffer)
            try R03NV12Contract.validate(
                pixelBuffer: processed.pixelBuffer,
                resolution: backend.route.targetResolution
            )

            processed.resourceLifetimeToken.release()
            XCTAssertEqual(releases.value, 1)
            let summary = await session.finish()
            XCTAssertEqual(summary.submittedFrameCount, 1)
            XCTAssertEqual(summary.processedFrameCount, 1)
            XCTAssertEqual(summary.terminalizationCount, 1)
        }
    }

    func testEveryClosedDriverOutcomeMapsCategoryReasonAndReleases() async throws {
        let behaviors = mappedBehaviors()
        for behavior in behaviors {
            let outputReleases = R05BackendCounter()
            let inputReleases = R05BackendCounter()
            let backend = try R05MetalFXSpatialBackend(
                subjectID: .spatial1p5x,
                driverFactory: { _ in R05BackendDriver(behavior: behavior) },
                outputReleaseObserver: { _ in outputReleases.increment() }
            )
            let session = try await makeSession(backend)
            let fixture = try makeFrame(
                resolution: .p720,
                tokenPrefix: "r05.mapping.\(behavior.reason)",
                releaseCounter: inputReleases
            )

            let outcome = await session.submit(fixture)
            behavior.assertMapped(
                outcome,
                route: backend.routeIdentity
            )
            XCTAssertEqual(inputReleases.value, 1, behavior.reason)
            XCTAssertEqual(outputReleases.value, 1, behavior.reason)
            _ = await session.finish()
        }
    }

    func testMalformedProcessedResultsFailClosed() async throws {
        let behaviors: [R05BackendBehavior] = [
            .wrongDestination,
            .wrongRoute,
            .missingPublish,
            .doublePublishIgnoringFailure
        ]
        for behavior in behaviors {
            let outputReleases = R05BackendCounter()
            let backend = try R05MetalFXSpatialBackend(
                subjectID: .spatial1p5x,
                driverFactory: { _ in R05BackendDriver(behavior: behavior) },
                outputReleaseObserver: { _ in outputReleases.increment() }
            )
            let session = try await makeSession(backend)
            let fixture = try makeFrame(
                resolution: .p720,
                tokenPrefix: "r05.bad-output",
                releaseCounter: R05BackendCounter()
            )

            let outcome = await session.submit(fixture)
            guard case .failed(let failure) = outcome else {
                return XCTFail("Expected output contract failure")
            }
            XCTAssertEqual(
                failure.reason,
                R05MetalFXBackendFailureReason.outputContractMismatch.rawValue
            )
            XCTAssertEqual(failure.processingIdentity.route, backend.routeIdentity)
            XCTAssertTrue(failure.processingIdentity.fallbackHistory.isEmpty)
            XCTAssertEqual(outputReleases.value, 1)
            _ = await session.finish()
        }
    }

    func testInputContractMismatchRejectsBeforeDriverAndOutputAllocation() async throws {
        let driver = R05BackendDriver(behavior: .processed)
        let outputReleases = R05BackendCounter()
        let inputReleases = R05BackendCounter()
        let backend = try R05MetalFXSpatialBackend(
            subjectID: .spatial1p5x,
            driverFactory: { _ in driver },
            outputReleaseObserver: { _ in outputReleases.increment() }
        )
        let session = try await makeSession(backend)
        let fixture = try makeFrame(
            resolution: .p1080,
            tokenPrefix: "r05.bad-input",
            releaseCounter: inputReleases
        )

        let outcome = await session.submit(fixture)
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected input contract rejection")
        }
        XCTAssertEqual(
            rejection.reason,
            R05MetalFXBackendRejectionReason.frameContractMismatch.rawValue
        )
        XCTAssertEqual(driver.processCount, 0)
        XCTAssertEqual(inputReleases.value, 1)
        XCTAssertEqual(outputReleases.value, 0)
        _ = await session.finish()
    }

    private func makeBackend(
        _ subject: R05MetalFXSubjectID,
        counter: R05BackendCounter
    ) throws -> R05MetalFXSpatialBackend {
        try R05MetalFXSpatialBackend(
            subjectID: subject,
            driverFactory: { _ in
                counter.increment()
                return R05BackendDriver(behavior: .processed)
            }
        )
    }

    private func makeSession(
        _ backend: R05MetalFXSpatialBackend
    ) async throws -> any AppleUpscaleSession {
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: try fixtureContext(for: backend.route)
        )
        guard case .created(let session) = outcome else {
            throw R05BackendTestError.sessionNotCreated
        }
        return session
    }

    private func fixtureContext(
        for route: R05MetalFXRouteDescriptor
    ) throws -> AppleUpscaleSessionContext {
        try AppleUpscaleSessionContext(
            capabilityRegistry: fixtureRegistry(for: route),
            admissionScope: .fixtureOnly,
            policyIdentity: R05MetalFXRouteCatalog.policyIdentity
        )
    }

    private func fixtureRegistry(
        for route: R05MetalFXRouteDescriptor
    ) throws -> AppleUpscaleCapabilityRegistry {
        try AppleUpscaleCapabilityRegistry(
            capabilities: [
                AppleUpscaleCapability(
                    id: route.capabilityID,
                    role: .primaryScaler,
                    frameworkIdentity: "MetalFX",
                    observationStatus: .observed,
                    runtimeDisposition: .runnable,
                    backendEligibility: .fixtureOnly
                )
            ]
        )
    }

    private func productContext(
        for route: R05MetalFXRouteDescriptor
    ) throws -> AppleUpscaleSessionContext {
        try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [
                    AppleUpscaleCapability(
                        id: route.capabilityID,
                        role: .primaryScaler,
                        frameworkIdentity: "MetalFX",
                        observationStatus: .observed,
                        runtimeDisposition: .runnable,
                        backendEligibility: .productQualified
                    )
                ]
            ),
            admissionScope: .product,
            policyIdentity: R05MetalFXRouteCatalog.policyIdentity
        )
    }

    private func emptyContext(
        scope: AppleUpscaleAdmissionScope
    ) throws -> AppleUpscaleSessionContext {
        try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(capabilities: []),
            admissionScope: scope,
            policyIdentity: R05MetalFXRouteCatalog.policyIdentity
        )
    }

    private func makeFrame(
        resolution: VideoResolution,
        tokenPrefix: String,
        releaseCounter: R05BackendCounter
    ) throws -> AppleUpscaleFrame {
        let pool = try PixelBufferBridge.makePool(
            width: resolution.width,
            height: resolution.height,
            format: R05MetalFXColorBridge.pixelFormat,
            capacity: 1
        )
        let pixelBuffer = try PixelBufferBridge.dequeue(from: pool)
        R05MetalFXColorBridge.installRequiredAttachments(on: pixelBuffer)
        return try AppleUpscaleFrame(
            sequenceNumber: 0,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: CMTime(value: 7, timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            colorDescription: R03NV12Contract.makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity("\(tokenPrefix).metadata"),
            resourceLifetimeToken: AppleUpscaleResourceLifetimeToken(
                identity: "\(tokenPrefix).input",
                releaseAction: { releaseCounter.increment() }
            )
        )
    }

    private func mappedBehaviors() -> [R05BackendBehavior] {
        R05MetalFXSpatialDriverRejectionReason.allCases.map(
            R05BackendBehavior.rejected
        )
            + R05MetalFXSpatialDriverUnsupportedReason.allCases.map(
                R05BackendBehavior.unsupported
            )
            + R05MetalFXSpatialDriverUnavailableReason.allCases.map(
                R05BackendBehavior.unavailable
            )
            + R05MetalFXSpatialDriverFailureReason.allCases.map(
                R05BackendBehavior.failed
            )
            + R05MetalFXSpatialCancellationReason.allCases.map(
                R05BackendBehavior.cancelled
            )
    }

    private func assertCreationRejected(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        reason: String,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected creation rejection", file: file, line: line)
        }
        XCTAssertEqual(rejection.reason, reason, file: file, line: line)
        XCTAssertEqual(rejection.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(
            rejection.processingIdentity.fallbackHistory.isEmpty,
            file: file,
            line: line
        )
    }

    private func assertCreationUnavailable(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        reason: String,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(let unavailable) = outcome else {
            return XCTFail("Expected creation unavailability", file: file, line: line)
        }
        XCTAssertEqual(unavailable.reason, reason, file: file, line: line)
        XCTAssertEqual(unavailable.processingIdentity.route, route, file: file, line: line)
        XCTAssertTrue(
            unavailable.processingIdentity.fallbackHistory.isEmpty,
            file: file,
            line: line
        )
    }
}

private enum R05BackendTestError: Error {
    case sessionNotCreated
}

private final class R05BackendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private enum R05BackendBehavior: @unchecked Sendable {
    case processed
    case rejected(R05MetalFXSpatialDriverRejectionReason)
    case unsupported(R05MetalFXSpatialDriverUnsupportedReason)
    case unavailable(R05MetalFXSpatialDriverUnavailableReason)
    case failed(R05MetalFXSpatialDriverFailureReason)
    case cancelled(R05MetalFXSpatialCancellationReason)
    case wrongDestination
    case wrongRoute
    case missingPublish
    case doublePublishIgnoringFailure

    var reason: String {
        switch self {
        case .processed:
            return "processed"
        case .rejected(let value):
            return value.rawValue
        case .unsupported(let value):
            return value.rawValue
        case .unavailable(let value):
            return value.rawValue
        case .failed(let value):
            return value.rawValue
        case .cancelled(let value):
            return value.rawValue
        case .wrongDestination:
            return "wrong_destination"
        case .wrongRoute:
            return "wrong_route"
        case .missingPublish:
            return "missing_publish"
        case .doublePublishIgnoringFailure:
            return "double_publish_ignoring_failure"
        }
    }

    func assertMapped(
        _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
        route: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identity: AppleUpscaleProcessingIdentity
        let observedReason: String
        switch (self, outcome) {
        case (.rejected(let expected), .rejected(let value)):
            identity = value.processingIdentity
            observedReason = value.reason
            XCTAssertEqual(observedReason, expected.rawValue, file: file, line: line)
        case (.unsupported(let expected), .unavailable(let value)):
            identity = value.processingIdentity
            observedReason = value.reason
            XCTAssertEqual(observedReason, expected.rawValue, file: file, line: line)
        case (.unavailable(let expected), .unavailable(let value)):
            identity = value.processingIdentity
            observedReason = value.reason
            XCTAssertEqual(observedReason, expected.rawValue, file: file, line: line)
        case (.failed(let expected), .failed(let value)):
            identity = value.processingIdentity
            observedReason = value.reason
            XCTAssertEqual(observedReason, expected.rawValue, file: file, line: line)
        case (.cancelled(let expected), .rejected(let value)):
            identity = value.processingIdentity
            observedReason = value.reason
            XCTAssertEqual(observedReason, expected.rawValue, file: file, line: line)
        default:
            return XCTFail("Driver outcome category mapping differs", file: file, line: line)
        }
        XCTAssertEqual(identity.route, route, file: file, line: line)
        XCTAssertTrue(identity.fallbackHistory.isEmpty, file: file, line: line)
    }
}

private final class R05BackendDriver: R05MetalFXSpatialDriving, @unchecked Sendable {
    private let behavior: R05BackendBehavior
    private let lock = NSLock()
    private var count = 0

    init(behavior: R05BackendBehavior) {
        self.behavior = behavior
    }

    var processCount: Int { lock.withLock { count } }

    func process(
        _ request: R05MetalFXSpatialDriverRequest
    ) async -> R05MetalFXSpatialDriverOutcome {
        lock.withLock { count += 1 }
        switch behavior {
        case .processed:
            do {
                try request.publish()
                return .processed(
                    R05MetalFXSpatialDriverProcessed(
                        route: request.route,
                        destination: request.destination
                    )
                )
            } catch {
                return .failed(.publicationFailed)
            }
        case .rejected(let value):
            return .rejected(value)
        case .unsupported(let value):
            return .unsupported(value)
        case .unavailable(let value):
            return .unavailable(value)
        case .failed(let value):
            return .failed(value)
        case .cancelled(let value):
            return .cancelled(value)
        case .wrongDestination:
            do {
                try request.publish()
            } catch {
                return .failed(.publicationFailed)
            }
            return .processed(
                R05MetalFXSpatialDriverProcessed(
                    route: request.route,
                    destination: R05BackendSurface(
                        dimensions: request.destination.dimensions
                    )
                )
            )
        case .wrongRoute:
            do {
                try request.publish()
            } catch {
                return .failed(.publicationFailed)
            }
            let wrongRoute: R05MetalFXSpatialDriverRoute = request.route == .oneAndOneHalf
                ? .two
                : .oneAndOneHalf
            return .processed(
                R05MetalFXSpatialDriverProcessed(
                    route: wrongRoute,
                    destination: request.destination
                )
            )
        case .missingPublish:
            return .processed(
                R05MetalFXSpatialDriverProcessed(
                    route: request.route,
                    destination: request.destination
                )
            )
        case .doublePublishIgnoringFailure:
            do {
                try request.publish()
            } catch {
                return .failed(.publicationFailed)
            }
            _ = try? request.publish()
            return .processed(
                R05MetalFXSpatialDriverProcessed(
                    route: request.route,
                    destination: request.destination
                )
            )
        }
    }
}

private final class R05BackendSurface: R05MetalFXSpatialNV12Surface,
    @unchecked Sendable {
    let dimensions: R05MetalFXSpatialDriverDimensions

    init(dimensions: R05MetalFXSpatialDriverDimensions) {
        self.dimensions = dimensions
    }
}

// swiftlint:enable file_length
