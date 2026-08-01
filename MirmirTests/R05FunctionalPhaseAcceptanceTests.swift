import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

// swiftlint:disable function_body_length
final class R05FunctionalPhaseAcceptanceTests: XCTestCase {
    func testSpatialRoutesProcessSourceDerivedFramesThroughProductionFIFO()
        async throws {
        let subjects: [R05MetalFXSubjectID] = [
            .spatial1p5x,
            .spatial2x,
            .spatial4x
        ]

        for subject in subjects {
            let expectedDriverRoute = try driverRoute(for: subject)
            let driver = R05FunctionalSimulatedSpatialDriver()
            let outputReleaseProbe = R05FunctionalCounter()
            let backend = try R05MetalFXSpatialBackend(
                subjectID: subject,
                driverFactory: { _ in driver },
                outputReleaseObserver: { _ in outputReleaseProbe.increment() }
            )
            let session = try await makeSession(backend: backend)
            let sessionIdentity = await session.identity
            var outputSHA256s: [String] = []

            for sequenceNumber in 0..<2 {
                let fixture = try makeFrame(
                    resolution: backend.route.sourceResolution,
                    sequenceNumber: sequenceNumber,
                    identityPrefix: "\(subject.rawValue).functional"
                )
                let output = try processed(await session.submit(fixture.frame))

                XCTAssertEqual(output.sequenceNumber, fixture.frame.sequenceNumber)
                XCTAssertEqual(output.processingIdentity.route, sessionIdentity)
                XCTAssertTrue(output.processingIdentity.fallbackHistory.isEmpty)
                XCTAssertEqual(output.colorDescription, fixture.frame.colorDescription)
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
                try R05MetalFXColorBridge.validate(pixelBuffer: output.pixelBuffer)
                try R03NV12Contract.validate(
                    pixelBuffer: output.pixelBuffer,
                    resolution: backend.route.targetResolution
                )
                let outputBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
                    from: output.pixelBuffer
                )
                XCTAssertTrue(outputBytes.contains { $0 != 0 })
                outputSHA256s.append(
                    R02FixtureGenerators.sha256Hex(outputBytes)
                )

                XCTAssertEqual(fixture.releaseProbe.value, 1)
                output.resourceLifetimeToken.release()
                output.resourceLifetimeToken.release()
                XCTAssertEqual(outputReleaseProbe.value, sequenceNumber + 1)
            }

            XCTAssertEqual(outputSHA256s.count, 2)
            XCTAssertNotEqual(outputSHA256s[0], outputSHA256s[1])
            XCTAssertEqual(
                driver.processedRoutes,
                Array(
                    repeating: expectedDriverRoute,
                    count: 2
                )
            )

            let summary = await session.finish()
            XCTAssertEqual(summary.submittedFrameCount, 2)
            XCTAssertEqual(summary.processedFrameCount, 2)
            XCTAssertEqual(summary.terminalizationCount, 1)
        }
    }

    func testSpatial2xCompletesVerifiedMediaTransactionBeforeAtomicPublication()
        async throws {
        let driver = R05FunctionalSimulatedSpatialDriver()
        let outputReleaseProbe = R05FunctionalCounter()
        let backend = try R05MetalFXSpatialBackend(
            subjectID: .spatial2x,
            driverFactory: { _ in driver },
            outputReleaseObserver: { _ in outputReleaseProbe.increment() }
        )
        let backendSession = try await makeSession(backend: backend)
        let sessionIdentity = await backendSession.identity
        let files = try R05FunctionalMediaFiles()
        defer { files.remove() }

        try await R03PQMediaFixtureWriter.write(
            sourceURL: files.source,
            audioScratchURL: files.audioScratch
        )
        let sourceAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: files.source
        )
        let frameMetadataIdentities = R03ProductQualificationMediaFixture.frames.map {
            "r05.metalfx.spatial-2x.frame.\($0.sequenceNumber)"
        }
        let finalMetadata = [
            "com.mirmir.ash.r05-functional-contract":
                "r05-functional-media-transaction-v1",
            "com.mirmir.ash.r05-backend-id":
                sessionIdentity.backend.backendID,
            "com.mirmir.ash.r05-configuration-identity":
                sessionIdentity.configurationIdentity,
            "com.mirmir.ash.r05-policy-identity":
                sessionIdentity.policyIdentity,
            "com.mirmir.ash.r05-material-decision-identity":
                sessionIdentity.materialDecisionIdentity,
            "com.mirmir.ash.r05-frame-metadata-identities":
                frameMetadataIdentities.joined(separator: "|"),
            "com.mirmir.ash.r05-fallback-history": "[]"
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
            let inputReleaseProbe = R05FunctionalCounter()
            let inputToken = try AppleUpscaleResourceLifetimeToken(
                identity: "r05.metalfx.spatial-2x.input.\(frameSpec.sequenceNumber)",
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
            try R05MetalFXColorBridge.validate(pixelBuffer: output.pixelBuffer)
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
                outputReleaseProbe.value,
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
        XCTAssertEqual(
            driver.processedRoutes,
            Array(
                repeating: R05MetalFXSpatialDriverRoute.two,
                count: R03ProductQualificationMediaFixture.frames.count
            )
        )
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
    }

    private func makeSession(
        backend: R05MetalFXSpatialBackend
    ) async throws -> any AppleUpscaleSession {
        let capability = try AppleUpscaleCapability(
            id: backend.capabilityID,
            role: .primaryScaler,
            frameworkIdentity: "MetalFX",
            observationStatus: .observed,
            runtimeDisposition: .runnable,
            backendEligibility: .fixtureOnly
        )
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: .fixtureOnly,
            policyIdentity: R05MetalFXRouteCatalog.policyIdentity
        )
        let outcome = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        guard case .created(let session) = outcome else {
            throw R05FunctionalTestError.sessionNotCreated
        }
        return session
    }

    private func makeFrame(
        resolution: VideoResolution,
        sequenceNumber: Int,
        identityPrefix: String
    ) throws -> R05FunctionalFrameFixture {
        let payload = try R02FixtureGenerators.nv12FrameBytes(
            width: resolution.width,
            height: resolution.height,
            seed: 505,
            sequenceNumber: sequenceNumber
        )
        let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
            width: resolution.width,
            height: resolution.height,
            logicalBytes: payload
        )
        let releaseProbe = R05FunctionalCounter()
        let token = try AppleUpscaleResourceLifetimeToken(
            identity: "\(identityPrefix).input.\(sequenceNumber)",
            releaseAction: { releaseProbe.increment() }
        )
        return R05FunctionalFrameFixture(
            frame: try AppleUpscaleFrame(
                sequenceNumber: sequenceNumber,
                pixelBuffer: pixelBuffer,
                presentationTimestamp: CMTime(
                    value: Int64(sequenceNumber * 1_001),
                    timescale: 30_000
                ),
                duration: CMTime(value: 1_001, timescale: 30_000),
                colorDescription: R03NV12Contract.makeColorDescription(),
                metadataIdentity: AppleUpscaleMetadataIdentity(
                    "\(identityPrefix).metadata.\(sequenceNumber)"
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
            throw R05FunctionalTestError.frameNotProcessed
        }
        return output
    }

    private func driverRoute(
        for subject: R05MetalFXSubjectID
    ) throws -> R05MetalFXSpatialDriverRoute {
        switch subject {
        case .spatial1p5x:
            return .oneAndOneHalf
        case .spatial2x:
            return .two
        case .spatial4x:
            return .four
        case .temporal1p5x,
             .temporal2x,
             .denoisedTemporal1p5x,
             .denoisedTemporal2x,
             .frameInterpolation1080p:
            throw R05FunctionalTestError.invalidFunctionalSubject
        }
    }
}

private enum R05FunctionalTestError: Error {
    case invalidFunctionalSubject
    case sessionNotCreated
    case frameNotProcessed
}

private struct R05FunctionalFrameFixture {
    let frame: AppleUpscaleFrame
    let releaseProbe: R05FunctionalCounter
}

private struct R05FunctionalMediaFiles {
    let directory: URL
    let source: URL
    let audioScratch: URL
    let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r05-functional-media-\(UUID().uuidString)",
            isDirectory: true
        )
        source = directory.appendingPathComponent("source-1080p.mp4")
        audioScratch = directory.appendingPathComponent("source-aac.m4a")
        destination = directory.appendingPathComponent(
            "metalfx-spatial-2x-2160p.mp4"
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

private final class R05FunctionalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class R05FunctionalSimulatedSpatialDriver:
    R05MetalFXSpatialDriving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var routeStorage: [R05MetalFXSpatialDriverRoute] = []

    var processedRoutes: [R05MetalFXSpatialDriverRoute] {
        lock.withLock { routeStorage }
    }

    func process(
        _ request: R05MetalFXSpatialDriverRequest
    ) async -> R05MetalFXSpatialDriverOutcome {
        guard !request.cancellation.isCancelled() else {
            return .cancelled(.beforeCommit)
        }
        guard let source = request.source
                as? R05MetalFXSpatialCVPixelBufferSurface,
              let destination = request.destination
                as? R05MetalFXSpatialCVPixelBufferSurface else {
            return .failed(.nv12ToLinearEncodingFailed)
        }

        let scaleRoute: R03ScaleRoute
        switch request.route {
        case .oneAndOneHalf:
            scaleRoute = .scale3Over2
        case .two:
            scaleRoute = .scale2x
        case .four:
            scaleRoute = .scale4x
        }
        do {
            try R03VImageScaler(
                mode: .lanczos3,
                route: scaleRoute
            ).scale(
                source: source.pixelBuffer,
                destination: destination.pixelBuffer,
                cancellation: AppleUpscaleOperationCancellationSignal()
            )
        } catch {
            return .failed(.scalerEncodingFailed)
        }
        guard !request.cancellation.isCancelled() else {
            return .cancelled(.afterCommit)
        }
        do {
            try request.publish()
        } catch {
            return .failed(.publicationFailed)
        }
        lock.withLock { routeStorage.append(request.route) }
        return .processed(
            R05MetalFXSpatialDriverProcessed(
                route: request.route,
                destination: request.destination
            )
        )
    }
}
// swiftlint:enable function_body_length
