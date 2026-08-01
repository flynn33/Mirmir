import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

// swiftlint:disable file_length type_body_length function_body_length
final class R04FunctionalPhaseAcceptanceTests: XCTestCase {
    func testQualityAndLowLatency2xCompleteVerifiedMediaTransactionsBeforeAtomicPublication()
        async throws {
        try await runVerifiedMediaTransaction(subjectID: .quality2x)
        try await runVerifiedMediaTransaction(subjectID: .lowLatency2x)
    }

    func testLowLatency1p5xExecutesOnlyAfterExactDimensionSupport() async throws {
        let runtime = R04FunctionalTestRuntime(mode: .processed)
        let backend = try makeBackend(.lowLatency1p5x, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let sessionIdentity = await session.identity
        let fixture = try makeFrame(
            resolution: .p720,
            sequence: 0,
            tokenPrefix: "r04.functional.low-latency-1p5x"
        )

        let output = try processed(await session.submit(fixture.frame))
        XCTAssertEqual(output.processingIdentity.route, sessionIdentity)
        XCTAssertTrue(output.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(output.sequenceNumber, fixture.frame.sequenceNumber)
        XCTAssertEqual(output.metadataIdentity, fixture.frame.metadataIdentity)
        XCTAssertEqual(
            CMTimeCompare(
                output.presentationTimestamp,
                fixture.frame.presentationTimestamp
            ),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(output.duration, fixture.frame.duration),
            0
        )
        try R03NV12Contract.validate(
            pixelBuffer: output.pixelBuffer,
            resolution: .p1080
        )
        XCTAssertTrue(
            try R02FixturePixelBuffers.logicalNV12Bytes(
                from: output.pixelBuffer
            ).contains { $0 != 0 }
        )
        XCTAssertEqual(fixture.releaseProbe.value, 1)
        output.resourceLifetimeToken.release()
        output.resourceLifetimeToken.release()
        XCTAssertEqual(runtime.outputReleaseCount, 1)

        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 1)
        XCTAssertEqual(summary.terminalizationCount, 1)
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.events,
            [
                .lowLatencySupport(.p720),
                .configuration(.lowLatency1p5x),
                .process(.lowLatency1p5x, sequence: 0),
                .finish
            ]
        )
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertEqual(snapshot.requests[0].boundary, .notApplicable)
        XCTAssertEqual(snapshot.requests[0].submissionMode, .random)
        XCTAssertNil(snapshot.requests[0].previousSourceSequence)
        XCTAssertNil(snapshot.requests[0].previousOutputSequence)
    }

    func testCancellationPropagatesThroughProductionFIFOWithoutFallback() async throws {
        try await assertCancellation(subjectID: .quality2x)
        try await assertCancellation(subjectID: .lowLatency2x)
    }

    private func assertCancellation(
        subjectID: R04VideoToolboxSubjectID
    ) async throws {
        let runtime = R04FunctionalTestRuntime(mode: .waitForCancellation)
        let backend = try makeBackend(subjectID, runtime: runtime)
        let session = try await makeSession(backend: backend)
        let sessionIdentity = await session.identity
        let fixture = try makeFrame(
            resolution: .p1080,
            sequence: 0,
            tokenPrefix: "\(subjectID.rawValue).functional-cancellation"
        )

        let submitTask = Task { await session.submit(fixture.frame) }
        do {
            try await waitUntilProcessStarts(runtime)
        } catch {
            await session.cancel()
            _ = await submitTask.value
            throw error
        }
        await session.cancel()

        let outcome = await submitTask.value
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Active R04 submission must reject after cancellation")
        }
        XCTAssertEqual(rejection.reason, "operation_cancelled")
        XCTAssertEqual(rejection.processingIdentity.route, sessionIdentity)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)
        XCTAssertEqual(fixture.releaseProbe.value, 1)

        let summary = await session.finish()
        XCTAssertEqual(summary.submittedFrameCount, 1)
        XCTAssertEqual(summary.processedFrameCount, 0)
        XCTAssertEqual(summary.terminalizationCount, 1)
        let snapshot = await runtime.snapshot()
        let expectedEvents: [R04FunctionalRuntimeEvent]
        switch subjectID {
        case .quality2x:
            expectedEvents = [
                .qualitySupport(.p1080),
                .configuration(.quality2x),
                .reset(.quality2x, cause: .firstFrame),
                .process(.quality2x, sequence: 0),
                .cancel
            ]
        case .lowLatency2x:
            expectedEvents = [
                .lowLatencySupport(.p1080),
                .configuration(.lowLatency2x),
                .process(.lowLatency2x, sequence: 0),
                .cancel
            ]
        default:
            throw R04FunctionalTestError.invalidFunctionalSubject
        }
        XCTAssertEqual(snapshot.events, expectedEvents)
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertEqual(runtime.outputReleaseCount, 0)
    }

    private func runVerifiedMediaTransaction(
        subjectID: R04VideoToolboxSubjectID
    ) async throws {
        guard subjectID == .quality2x || subjectID == .lowLatency2x else {
            throw R04FunctionalTestError.invalidFunctionalSubject
        }
        let runtime = R04FunctionalTestRuntime(mode: .processed)
        let backend = try makeBackend(subjectID, runtime: runtime)
        let backendSession = try await makeSession(backend: backend)
        let sessionIdentity = await backendSession.identity
        let files = try R04FunctionalMediaFiles(subjectID: subjectID)
        defer { files.remove() }

        try await R03PQMediaFixtureWriter.write(
            sourceURL: files.source,
            audioScratchURL: files.audioScratch
        )
        let sourceAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: files.source
        )
        let frameMetadataIdentities = R03ProductQualificationMediaFixture.frames.map {
            "\(subjectID.rawValue).frame.\($0.sequenceNumber)"
        }
        let finalMetadata = [
            "com.mirmir.ash.r04-functional-contract":
                "r04-functional-media-transaction-v1",
            "com.mirmir.ash.r04-backend-id":
                sessionIdentity.backend.backendID,
            "com.mirmir.ash.r04-configuration-identity":
                sessionIdentity.configurationIdentity,
            "com.mirmir.ash.r04-policy-identity":
                sessionIdentity.policyIdentity,
            "com.mirmir.ash.r04-material-decision-identity":
                sessionIdentity.materialDecisionIdentity,
            "com.mirmir.ash.r04-frame-metadata-identities":
                frameMetadataIdentities.joined(separator: "|"),
            "com.mirmir.ash.r04-fallback-history": "[]"
        ]
        let verifier = R03PQMediaPrepublicationVerifier(
            destinationURL: files.destination,
            expectedAACIdentity: sourceAACIdentity,
            expectedTimedMetadata: finalMetadata
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            outputVerifier: verifier
        )
        let source = try await pipeline.probe(url: files.source)
        XCTAssertEqual(
            source.resolution,
            R03ProductQualificationMediaFixture.sourceResolution
        )
        XCTAssertTrue(source.hasAudio)
        let mediaSession = try await pipeline.beginSession(
            source: source,
            output: OutputProfile(
                url: files.destination,
                resolution: R03ProductQualificationMediaFixture.targetResolution,
                codec: .h264,
                preserveAudio: true,
                timedMetadataTemplate: finalMetadata
            )
        )
        defer { mediaSession.cancel() }

        let color = try R03NV12Contract.makeColorDescription()
        for frameSpec in R03ProductQualificationMediaFixture.frames {
            let optionalRecord = try await mediaSession.nextSourceFrame()
            let record = try XCTUnwrap(optionalRecord)
            XCTAssertEqual(record.frameIndex, frameSpec.sequenceNumber)
            XCTAssertEqual(
                CMTimeCompare(record.presentationTime, frameSpec.presentationTime),
                0
            )
            XCTAssertEqual(CMTimeCompare(record.duration, frameSpec.duration), 0)
            let decodedBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
                from: record.pixelBuffer
            )
            let normalized = try R02FixturePixelBuffers.makeNV12(
                width: R03ProductQualificationMediaFixture.sourceResolution.width,
                height: R03ProductQualificationMediaFixture.sourceResolution.height,
                logicalBytes: decodedBytes
            )
            let inputReleaseProbe = R04FunctionalCounter()
            let inputToken = try AppleUpscaleResourceLifetimeToken(
                identity: "\(subjectID.rawValue).input.\(frameSpec.sequenceNumber)",
                releaseAction: { inputReleaseProbe.increment() }
            )
            let input = try AppleUpscaleFrame(
                sequenceNumber: frameSpec.sequenceNumber,
                pixelBuffer: normalized,
                presentationTimestamp: record.presentationTime,
                duration: record.duration,
                colorDescription: color,
                metadataIdentity: AppleUpscaleMetadataIdentity(
                    frameMetadataIdentities[frameSpec.sequenceNumber]
                ),
                resourceLifetimeToken: inputToken
            )
            let output = try processed(await backendSession.submit(input))
            XCTAssertEqual(output.processingIdentity.route, sessionIdentity)
            XCTAssertTrue(output.processingIdentity.fallbackHistory.isEmpty)
            XCTAssertEqual(output.metadataIdentity, input.metadataIdentity)
            XCTAssertEqual(
                CMTimeCompare(
                    output.presentationTimestamp,
                    record.presentationTime
                ),
                0
            )
            XCTAssertEqual(CMTimeCompare(output.duration, record.duration), 0)
            try R03NV12Contract.validate(
                pixelBuffer: output.pixelBuffer,
                resolution: R03ProductQualificationMediaFixture.targetResolution
            )
            XCTAssertTrue(
                try R02FixturePixelBuffers.logicalNV12Bytes(
                    from: output.pixelBuffer
                ).contains { $0 != 0 }
            )
            try await mediaSession.appendOutput(
                pixelBuffer: output.pixelBuffer,
                timing: record.timing
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: files.destination.path)
            )
            output.resourceLifetimeToken.release()
            output.resourceLifetimeToken.release()
            XCTAssertEqual(inputReleaseProbe.value, 1)
            XCTAssertEqual(
                runtime.outputReleaseCount,
                frameSpec.sequenceNumber + 1
            )
        }
        let endOfVideo = try await mediaSession.nextSourceFrame()
        XCTAssertNil(endOfVideo)

        let backendSummary = await backendSession.finish()
        XCTAssertEqual(
            backendSummary.submittedFrameCount,
            R03ProductQualificationMediaFixture.frames.count
        )
        XCTAssertEqual(
            backendSummary.processedFrameCount,
            R03ProductQualificationMediaFixture.frames.count
        )
        XCTAssertEqual(backendSummary.terminalizationCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: files.destination.path)
        )

        try await mediaSession.finish(finalMetadata: finalMetadata)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: files.destination.path)
        )
        XCTAssertTrue(files.partialFiles().isEmpty)
        let verification = verifier.snapshot
        XCTAssertEqual(verification.invocationCount, 1)
        XCTAssertEqual(verification.successfulVerificationCount, 1)
        XCTAssertTrue(verification.destinationWasAbsent)
        XCTAssertTrue(verification.temporaryInputWasPresent)
        XCTAssertNotEqual(verification.verifiedURL, files.destination)
        let reopened = try XCTUnwrap(verification.result)
        XCTAssertEqual(reopened.codec, "avc1")
        XCTAssertEqual(
            reopened.resolution,
            R03ProductQualificationMediaFixture.targetResolution
        )
        XCTAssertEqual(
            reopened.frameCount,
            R03ProductQualificationMediaFixture.frames.count
        )
        XCTAssertGreaterThan(reopened.lumaPayloadBytes, 0)
        XCTAssertGreaterThan(reopened.chromaPayloadBytes, 0)
        let outputAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: files.destination
        )
        XCTAssertEqual(outputAACIdentity, sourceAACIdentity)

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(
            snapshot.requests.map(\.routeID),
            Array(
                repeating: backend.route.routeID,
                count: R03ProductQualificationMediaFixture.frames.count
            )
        )
        switch subjectID {
        case .quality2x:
            XCTAssertEqual(
                snapshot.requests.map(\.boundary),
                [.firstFrame, .continuing, .continuing]
            )
            XCTAssertEqual(
                snapshot.requests.map(\.submissionMode),
                [.random, .sequential, .sequential]
            )
            XCTAssertEqual(
                snapshot.requests.map(\.previousSourceSequence),
                [nil, 0, 1]
            )
            XCTAssertEqual(
                snapshot.requests.map(\.previousOutputSequence),
                [nil, 0, 1]
            )
        case .lowLatency2x:
            XCTAssertEqual(
                snapshot.requests.map(\.boundary),
                [.notApplicable, .notApplicable, .notApplicable]
            )
            XCTAssertEqual(
                snapshot.requests.map(\.submissionMode),
                [.random, .random, .random]
            )
            XCTAssertTrue(
                snapshot.requests.allSatisfy {
                    $0.previousSourceSequence == nil
                        && $0.previousOutputSequence == nil
                }
            )
        default:
            XCTFail("Only functional 2x routes can reach verification")
        }
    }

    private func makeBackend(
        _ subjectID: R04VideoToolboxSubjectID,
        runtime: R04FunctionalTestRuntime
    ) throws -> R04VideoToolboxBackend {
        try R04VideoToolboxBackend(
            subjectID: subjectID,
            modelAssetsIdentity: .notRequired,
            runtimeFactory: { runtime }
        )
    }

    private func makeSession(
        backend: R04VideoToolboxBackend
    ) async throws -> any AppleUpscaleSession {
        let capability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "VideoToolbox",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: .fixtureOnly,
            policyIdentity: R04VideoToolboxRouteCatalog.policyIdentity
        )
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        guard case .created(let session) = outcome else {
            throw R04FunctionalTestError.sessionNotCreated
        }
        return session
    }

    private func makeFrame(
        resolution: VideoResolution,
        sequence: Int,
        tokenPrefix: String
    ) throws -> R04FunctionalFrameFixture {
        let payload = try R02FixtureGenerators.nv12FrameBytes(
            width: resolution.width,
            height: resolution.height,
            seed: 404,
            sequenceNumber: sequence
        )
        let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
            width: resolution.width,
            height: resolution.height,
            logicalBytes: payload
        )
        let releaseProbe = R04FunctionalCounter()
        let token = try AppleUpscaleResourceLifetimeToken(
            identity: "\(tokenPrefix).\(sequence)",
            releaseAction: { releaseProbe.increment() }
        )
        return R04FunctionalFrameFixture(
            frame: try AppleUpscaleFrame(
                sequenceNumber: sequence,
                pixelBuffer: pixelBuffer,
                presentationTimestamp: CMTime(
                    value: Int64(sequence),
                    timescale: 30
                ),
                duration: CMTime(value: 1, timescale: 30),
                colorDescription: try R03NV12Contract.makeColorDescription(),
                metadataIdentity: AppleUpscaleMetadataIdentity(
                    "\(tokenPrefix).metadata.\(sequence)"
                ),
                resourceLifetimeToken: token
            ),
            releaseProbe: releaseProbe
        )
    }

    private func processed(
        _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>
    ) throws -> AppleUpscaleProcessedFrame {
        guard case .processed(let output) = outcome else {
            throw R04FunctionalTestError.frameNotProcessed
        }
        return output
    }

    private func waitUntilProcessStarts(
        _ runtime: R04FunctionalTestRuntime
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await runtime.snapshot().requests.isEmpty {
            let now = clock.now
            guard now < deadline else {
                throw R04FunctionalTestError.runtimeProcessStartTimedOut
            }
            try await clock.sleep(
                until: min(deadline, now.advanced(by: .milliseconds(1)))
            )
        }
    }
}

private enum R04FunctionalTestError: Error {
    case invalidFunctionalSubject
    case sessionNotCreated
    case frameNotProcessed
    case runtimeProcessStartTimedOut
    case pixelBufferCreationFailed(CVReturn)
}

private struct R04FunctionalFrameFixture {
    let frame: AppleUpscaleFrame
    let releaseProbe: R04FunctionalCounter
}

private struct R04FunctionalMediaFiles {
    let directory: URL
    let source: URL
    let audioScratch: URL
    let destination: URL

    init(subjectID: R04VideoToolboxSubjectID) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r04-functional-media-\(UUID().uuidString)",
            isDirectory: true
        )
        source = directory.appendingPathComponent("source-1080p.mp4")
        audioScratch = directory.appendingPathComponent("source-aac.m4a")
        destination = directory.appendingPathComponent(
            "\(subjectID.rawValue)-2160p.mp4"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func partialFiles() -> [URL] {
        let baseName = destination.deletingPathExtension().lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix(".\(baseName).mirmir-")
                && $0.lastPathComponent.contains(".partial")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class R04FunctionalCounter: @unchecked Sendable {
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

private enum R04FunctionalRuntimeMode: Sendable {
    case processed
    case waitForCancellation
}

private enum R04FunctionalRuntimeEvent: Equatable, Sendable {
    case qualitySupport(VideoResolution)
    case lowLatencySupport(VideoResolution)
    case configuration(R04VideoToolboxRouteID)
    case reset(R04VideoToolboxRouteID, cause: R04VideoToolboxResetCause)
    case process(R04VideoToolboxRouteID, sequence: Int)
    case finish
    case cancel
}

private struct R04FunctionalRequestSnapshot: Equatable, Sendable {
    let routeID: R04VideoToolboxRouteID
    let sequenceNumber: Int
    let previousSourceSequence: Int?
    let previousOutputSequence: Int?
    let boundary: R04VideoToolboxHistoryBoundary
    let submissionMode: R04VideoToolboxSubmissionMode
}

private struct R04FunctionalRuntimeSnapshot: Equatable, Sendable {
    let events: [R04FunctionalRuntimeEvent]
    let requests: [R04FunctionalRequestSnapshot]
}

private actor R04FunctionalTestRuntime: R04VideoToolboxRuntime {
    private let mode: R04FunctionalRuntimeMode
    private let outputReleaseProbe = R04FunctionalCounter()
    private var events: [R04FunctionalRuntimeEvent] = []
    private var requests: [R04FunctionalRequestSnapshot] = []

    nonisolated var outputReleaseCount: Int {
        outputReleaseProbe.value
    }

    init(mode: R04FunctionalRuntimeMode) {
        self.mode = mode
    }

    func qualitySupport(
        sourceResolution: VideoResolution,
        scaleFactor _: R04VideoToolboxScaleFactor
    ) async -> R04VideoToolboxSupportObservation<Bool> {
        events.append(.qualitySupport(sourceResolution))
        return .observed(sourceResolution == .p1080)
    }

    func lowLatencySupportedScaleFactors(
        sourceResolution: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Set<R04VideoToolboxScaleFactor>> {
        events.append(.lowLatencySupport(sourceResolution))
        switch sourceResolution {
        case .p720:
            return .observed([.oneAndOneHalf])
        case .p1080:
            return .observed([.two])
        default:
            return .observed([])
        }
    }

    func opticalFlowSupport(
        sourceResolution _: VideoResolution
    ) async -> R04VideoToolboxSupportObservation<Bool> {
        .observed(false)
    }

    func configurationDiagnostics(
        for route: R04VideoToolboxRouteDescriptor
    ) async -> R04VideoToolboxSupportObservation<
        R04VideoToolboxConfigurationDiagnostics
    > {
        events.append(.configuration(route.routeID))
        switch route.backendKind {
        case .quality:
            return .observed(
                R04VideoToolboxConfigurationDiagnostics(
                    nativeIdentity: .quality(
                        R04ObservedQualityConfiguration(
                            frameWidth: route.sourceResolution.width,
                            frameHeight: route.sourceResolution.height,
                            integerScaleFactor: route.scaleFactor.numerator,
                            inputType: .video,
                            usesPrecomputedFlow: false,
                            qualityPriority: .normal,
                            revision: 1
                        )
                    ),
                    supportedPixelFormats: [
                        kCVPixelFormatType_64RGBAHalf
                    ],
                    modelStatus: .ready,
                    processingMode: .quality
                )
            )
        case .lowLatency:
            return .observed(
                R04VideoToolboxConfigurationDiagnostics(
                    nativeIdentity: .lowLatency(
                        R04ObservedLowLatencyConfiguration(
                            frameWidth: route.sourceResolution.width,
                            frameHeight: route.sourceResolution.height,
                            scaleFactor: Float(route.scaleFactor.numerator)
                                / Float(route.scaleFactor.denominator)
                        )
                    ),
                    supportedPixelFormats: [
                        R04VideoToolboxRouteCatalog.pixelFormat
                    ],
                    modelStatus: .notRequired,
                    processingMode: .lowLatency
                )
            )
        case .optionalFlowSupport:
            return .notObserved
        }
    }

    func process(
        _ request: R04VideoToolboxProcessingRequest,
        cancellation: AppleUpscaleOperationCancellationSignal
    ) async -> R04VideoToolboxRuntimeOutcome {
        events.append(
            .process(
                request.route.routeID,
                sequence: request.sourceFrame.sequenceNumber
            )
        )
        requests.append(
            R04FunctionalRequestSnapshot(
                routeID: request.route.routeID,
                sequenceNumber: request.sourceFrame.sequenceNumber,
                previousSourceSequence: request.previousSource?.sequenceNumber,
                previousOutputSequence: request.previousOutput?.sequenceNumber,
                boundary: request.historyBoundary,
                submissionMode: request.submissionMode
            )
        )
        switch mode {
        case .waitForCancellation:
            while !cancellation.isCancelled {
                await Task.yield()
            }
            return .rejected(.operationCancelled)
        case .processed:
            do {
                let output = try R04FunctionalTestPixelBuffers.makeNV12(
                    request.route.targetResolution
                )
                let scaleRoute: R03ScaleRoute
                switch request.route.scaleFactor {
                case .oneAndOneHalf:
                    scaleRoute = .scale3Over2
                case .two:
                    scaleRoute = .scale2x
                default:
                    return .rejected(.runtimeRejected)
                }
                try R03VImageScaler(
                    mode: .lanczos3,
                    route: scaleRoute
                ).scale(
                    source: request.sourceFrame.pixelBuffer,
                    destination: output,
                    cancellation: cancellation
                )
                return .processed(
                    R04VideoToolboxRuntimeOutput(
                        pixelBuffer: output,
                        releaseAction: { [outputReleaseProbe] in
                            outputReleaseProbe.increment()
                        }
                    )
                )
            } catch {
                return cancellation.isCancelled
                    ? .rejected(.operationCancelled)
                    : .failed(.runtimeProcessingFailed)
            }
        }
    }

    func reset(
        _ request: R04VideoToolboxResetRequest,
        cancellation _: AppleUpscaleOperationCancellationSignal
    ) async {
        events.append(.reset(request.route.routeID, cause: request.cause))
    }

    func finish() async {
        events.append(.finish)
    }

    func cancel() async {
        events.append(.cancel)
    }

    func snapshot() -> R04FunctionalRuntimeSnapshot {
        R04FunctionalRuntimeSnapshot(events: events, requests: requests)
    }
}

private enum R04FunctionalTestPixelBuffers {
    static func makeNV12(
        _ resolution: VideoResolution
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
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
            throw R04FunctionalTestError.pixelBufferCreationFailed(status)
        }
        R03NV12Contract.installColorAttachments(on: buffer)
        return buffer
    }
}
// swiftlint:enable file_length type_body_length function_body_length
