import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

// This file keeps the complete frozen R02 conformance scenario in one review unit.
// swiftlint:disable file_length

// The test case groups all assertions for the single frozen R02 fixture contract.
// swiftlint:disable type_body_length
final class R02FixtureConformanceTests: XCTestCase {
    func testFrozenSwiftGeneratorsMatchCatalogAndMaterializeRowAwareNV12() throws {
        let catalog = try R02FixtureCatalog.load()

        XCTAssertEqual(
            catalog.generatorContract,
            R02FixtureGenerators.generatorContract
        )
        XCTAssertEqual(
            catalog.scenarios.map(\.id),
            [
                "multiple_backends_common_session",
                "session_lifecycle",
                "typed_outcomes_and_fallback",
                "media_transaction_preservation"
            ]
        )

        var generatedFrameCount = 0
        for fixture in catalog.fixtures {
            XCTAssertEqual(fixture.generatorID, R02FixtureGenerators.nv12GeneratorID)
            XCTAssertEqual(fixture.pixelFormat, "420v")
            XCTAssertEqual(fixture.materialization, "runtime_ephemeral")
            XCTAssertEqual(fixture.sourceDimensions, fixture.targetDimensions)
            XCTAssertEqual(
                fixture.frames.map(\.sequenceNumber),
                Array(fixture.frames.indices)
            )
            for frame in fixture.frames {
                let payload = try R02FixtureGenerators.nv12FrameBytes(
                    width: fixture.sourceDimensions.width,
                    height: fixture.sourceDimensions.height,
                    seed: fixture.seed,
                    sequenceNumber: frame.sequenceNumber
                )
                XCTAssertEqual(
                    R02FixtureGenerators.sha256Hex(payload),
                    frame.generatedContentSHA256,
                    "\(fixture.id) frame \(frame.sequenceNumber)"
                )
                let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
                    width: fixture.sourceDimensions.width,
                    height: fixture.sourceDimensions.height,
                    logicalBytes: payload
                )
                XCTAssertEqual(
                    CVPixelBufferGetPixelFormatType(pixelBuffer),
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                )
                XCTAssertEqual(
                    CVPixelBufferGetWidth(pixelBuffer),
                    fixture.sourceDimensions.width
                )
                XCTAssertEqual(
                    CVPixelBufferGetHeight(pixelBuffer),
                    fixture.sourceDimensions.height
                )
                XCTAssertTrue(R02FixturePixelBuffers.hasFrozenColorAttachments(pixelBuffer))
                XCTAssertEqual(
                    try R02FixturePixelBuffers.logicalNV12Bytes(from: pixelBuffer),
                    payload
                )
                generatedFrameCount += 1
            }
        }
        XCTAssertEqual(generatedFrameCount, 9)

        let mediaFixture = try XCTUnwrap(
            catalog.fixtures.first { $0.id == "fixture-media-transaction" }
        )
        let audio = try XCTUnwrap(mediaFixture.audioContract)
        XCTAssertEqual(audio.sourceGeneratorID, R02FixtureGenerators.pcmGeneratorID)
        let pcm = try R02FixtureGenerators.pcmS16LEBytes(
            sampleFrames: audio.sourceSampleFrames,
            channelCount: audio.channelCount,
            seed: mediaFixture.seed
        )
        XCTAssertEqual(pcm.count, 480 * 2 * MemoryLayout<Int16>.size)
        XCTAssertEqual(
            R02FixtureGenerators.sha256Hex(pcm),
            audio.sourcePCMSHA256
        )
        XCTAssertEqual(
            audio.sourcePCMSHA256,
            "d9c0cdd3c0a79ff8fce1ae71b1e00ee8047de3243d6403b73d3d53cf6094b06a"
        )
    }

    // Keeping each backend/session lifecycle contiguous makes ordering and token
    // ownership assertions directly auditable against the frozen fixture catalog.
    // swiftlint:disable function_body_length
    func testBothFixtureBackendsProcessEveryFixtureThroughCommonSession() async throws {
        let catalog = try R02FixtureCatalog.load()
        let capability = try R02FixtureCopyBackend.makeCapability()
        let registry = try AppleUpscaleCapabilityRegistry(capabilities: [capability])
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: registry,
            admissionScope: .fixtureOnly,
            policyIdentity: R02FixtureCopyBackend.policyIdentity
        )

        for backendID in R02FixtureCopyBackend.supportedBackendIDs {
            let outputReleaseProbe = R02FixtureReleaseProbe()
            let driverProbe = R02FixtureDriverProbe()
            for fixture in catalog.fixtures {
                let backend: any AppleUpscaleBackend = try R02FixtureCopyBackend(
                    backendID: backendID,
                    sourceResolution: fixture.sourceDimensions.videoResolution,
                    targetResolution: fixture.targetDimensions.videoResolution,
                    outputReleaseProbe: outputReleaseProbe,
                    driverProbe: driverProbe
                )
                let configuration = try AppleUpscaleSessionConfiguration(
                    capabilityID: capability.id,
                    sourceResolution: fixture.sourceDimensions.videoResolution,
                    targetResolution: fixture.targetDimensions.videoResolution,
                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    configurationIdentity: R02FixtureCopyBackend.configurationIdentity
                )
                let creation = await backend.makeSession(
                    configuration: configuration,
                    context: context
                )
                guard case .created(let session) = creation else {
                    XCTFail("\(backendID) rejected frozen fixture \(fixture.id)")
                    continue
                }
                let sessionIdentity = await session.identity
                assertCompleteDirectIdentity(sessionIdentity, backendID: backendID)

                var observedSequenceNumbers: [Int] = []
                for frozenFrame in fixture.frames {
                    let payload = try R02FixtureGenerators.nv12FrameBytes(
                        width: fixture.sourceDimensions.width,
                        height: fixture.sourceDimensions.height,
                        seed: fixture.seed,
                        sequenceNumber: frozenFrame.sequenceNumber
                    )
                    let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
                        width: fixture.sourceDimensions.width,
                        height: fixture.sourceDimensions.height,
                        logicalBytes: payload
                    )
                    let inputReleaseProbe = R02FixtureReleaseProbe()
                    let tokenID = frozenFrame.resourceTokenID
                    let inputToken = try AppleUpscaleResourceLifetimeToken(
                        identity: tokenID,
                        releaseAction: { [inputReleaseProbe] in
                            inputReleaseProbe.recordRelease(identity: tokenID)
                        }
                    )
                    let frame = try AppleUpscaleFrame(
                        sequenceNumber: frozenFrame.sequenceNumber,
                        pixelBuffer: pixelBuffer,
                        presentationTimestamp: frozenFrame.pts.cmTime,
                        duration: frozenFrame.duration.cmTime,
                        colorDescription: fixture.colorContract.value(),
                        metadataIdentity: AppleUpscaleMetadataIdentity(
                            frozenFrame.metadataIdentity
                        ),
                        resourceLifetimeToken: inputToken
                    )

                    let outcome = await session.submit(frame)
                    guard case .processed(let processed) = outcome else {
                        XCTFail(
                            "\(backendID) did not process \(fixture.id) "
                                + "frame \(frozenFrame.sequenceNumber)"
                        )
                        continue
                    }
                    observedSequenceNumbers.append(processed.sequenceNumber)
                    XCTAssertEqual(processed.sequenceNumber, frozenFrame.sequenceNumber)
                    XCTAssertEqual(
                        CMTimeCompare(processed.presentationTimestamp, frozenFrame.pts.cmTime),
                        0
                    )
                    XCTAssertEqual(
                        CMTimeCompare(processed.duration, frozenFrame.duration.cmTime),
                        0
                    )
                    XCTAssertEqual(
                        processed.metadataIdentity.rawValue,
                        frozenFrame.metadataIdentity
                    )
                    XCTAssertEqual(
                        processed.colorDescription,
                        try fixture.colorContract.value()
                    )
                    XCTAssertEqual(
                        CVPixelBufferGetWidth(processed.pixelBuffer),
                        fixture.targetDimensions.width
                    )
                    XCTAssertEqual(
                        CVPixelBufferGetHeight(processed.pixelBuffer),
                        fixture.targetDimensions.height
                    )
                    XCTAssertTrue(
                        R02FixturePixelBuffers.hasFrozenColorAttachments(
                            processed.pixelBuffer
                        )
                    )
                    XCTAssertEqual(
                        try R02FixturePixelBuffers.logicalNV12Bytes(
                            from: processed.pixelBuffer
                        ),
                        payload
                    )
                    assertCompleteDirectIdentity(
                        processed.processingIdentity.route,
                        backendID: backendID
                    )
                    XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)

                    XCTAssertFalse(processed.resourceLifetimeToken === inputToken)
                    XCTAssertEqual(processed.resourceLifetimeToken.identity, tokenID)
                    XCTAssertTrue(inputToken.isReleased)
                    XCTAssertEqual(inputReleaseProbe.releaseCount(for: tokenID), 1)
                    XCTAssertFalse(processed.resourceLifetimeToken.isReleased)
                    processed.resourceLifetimeToken.release()
                    processed.resourceLifetimeToken.release()
                    XCTAssertEqual(outputReleaseProbe.releaseCount(for: tokenID), 1)
                }
                XCTAssertEqual(
                    observedSequenceNumbers,
                    fixture.frames.map(\.sequenceNumber)
                )

                let summary = await session.finish()
                let cachedSummary = await session.finish()
                XCTAssertEqual(summary, cachedSummary)
                XCTAssertEqual(summary.submittedFrameCount, fixture.frames.count)
                XCTAssertEqual(summary.processedFrameCount, fixture.frames.count)
                XCTAssertEqual(summary.terminalizationCount, 1)
                await session.cancel()
            }
            XCTAssertEqual(driverProbe.finishCallCount, catalog.fixtures.count)
            XCTAssertEqual(driverProbe.cancelCallCount, 0)
            XCTAssertEqual(driverProbe.maximumConcurrentProcessCount, 1)
            XCTAssertEqual(
                driverProbe.processedSequenceNumbers,
                catalog.fixtures.flatMap { $0.frames.map(\.sequenceNumber) }
            )
            for fixture in catalog.fixtures {
                for frame in fixture.frames {
                    XCTAssertEqual(
                        outputReleaseProbe.releaseCount(for: frame.resourceTokenID),
                        1
                    )
                }
            }
        }
    }
    // swiftlint:enable function_body_length

    func testBackendRejectsInvalidCapabilityConfigurationAndContextBeforeCreation() async throws {
        let resolution = VideoResolution(width: 16, height: 8)
        let outputReleaseProbe = R02FixtureReleaseProbe()
        let driverProbe = R02FixtureDriverProbe()
        let backend = try R02FixtureCopyBackend(
            backendID: "r02.fixture.copy-a",
            sourceResolution: resolution,
            targetResolution: resolution,
            outputReleaseProbe: outputReleaseProbe,
            driverProbe: driverProbe
        )
        let fixtureCapability = try R02FixtureCopyBackend.makeCapability()
        let validConfiguration = try AppleUpscaleSessionConfiguration(
            capabilityID: fixtureCapability.id,
            sourceResolution: resolution,
            targetResolution: resolution,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            configurationIdentity: R02FixtureCopyBackend.configurationIdentity
        )
        let validRegistry = try AppleUpscaleCapabilityRegistry(
            capabilities: [fixtureCapability]
        )
        let validContext = try AppleUpscaleSessionContext(
            capabilityRegistry: validRegistry,
            admissionScope: .fixtureOnly,
            policyIdentity: R02FixtureCopyBackend.policyIdentity
        )

        let invalidConfiguration = try AppleUpscaleSessionConfiguration(
            capabilityID: fixtureCapability.id,
            sourceResolution: resolution,
            targetResolution: VideoResolution(width: 32, height: 16),
            pixelFormat: kCVPixelFormatType_32BGRA,
            configurationIdentity: "wrong-configuration"
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: invalidConfiguration,
                context: validContext
            ),
            expectedRoute: backend.routeIdentity
        )

        let diagnosticCapability = try AppleUpscaleCapability(
            id: fixtureCapability.id,
            role: .primaryScaler,
            frameworkIdentity: "MirmirFixture",
            observationStatus: .notObserved,
            runtimeDisposition: .diagnosticOnly,
            backendEligibility: .notEvaluated
        )
        let ineligibleContext = try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [diagnosticCapability]
            ),
            admissionScope: .fixtureOnly,
            policyIdentity: R02FixtureCopyBackend.policyIdentity
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: validConfiguration,
                context: ineligibleContext
            ),
            expectedRoute: backend.routeIdentity
        )

        let productContext = try AppleUpscaleSessionContext(
            capabilityRegistry: validRegistry,
            admissionScope: .product,
            policyIdentity: "wrong-policy"
        )
        assertCreationRejected(
            await backend.makeSession(
                configuration: validConfiguration,
                context: productContext
            ),
            expectedRoute: backend.routeIdentity
        )
        XCTAssertEqual(driverProbe.finishCallCount, 0)
        XCTAssertEqual(driverProbe.cancelCallCount, 0)
    }

    // The atomic media transaction is kept contiguous so verification-before-
    // publication and exact AAC identity assertions retain their execution order.
    // swiftlint:disable function_body_length
    func testFrozenMP4AACTransactionVerifiesBeforeAtomicPublicationForBothBackends() async throws {
        let catalog = try R02FixtureCatalog.load()
        let fixture = try XCTUnwrap(
            catalog.fixtures.first { $0.id == "fixture-media-transaction" }
        )
        let audio = try XCTUnwrap(fixture.audioContract)
        let files = try R02MediaTransactionFiles()
        defer { files.remove() }

        let sourcePCM = try R02FixtureGenerators.pcmS16LEBytes(
            sampleFrames: audio.sourceSampleFrames,
            channelCount: audio.channelCount,
            seed: fixture.seed
        )
        XCTAssertEqual(
            R02FixtureGenerators.sha256Hex(sourcePCM),
            audio.sourcePCMSHA256
        )
        try await R02FrozenMediaFixtureWriter.write(
            fixture: fixture,
            sourceURL: files.source,
            audioScratchURL: files.audioScratch
        )
        let sourceAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: files.source
        )
        XCTAssertEqual(sourceAACIdentity.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(sourceAACIdentity.sampleRate, Double(audio.sampleRate))
        XCTAssertEqual(
            sourceAACIdentity.channelCount,
            UInt32(audio.channelCount)
        )
        XCTAssertFalse(sourceAACIdentity.samples.isEmpty)

        let capability = try R02FixtureCopyBackend.makeCapability()
        let registry = try AppleUpscaleCapabilityRegistry(capabilities: [capability])
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: registry,
            admissionScope: .fixtureOnly,
            policyIdentity: R02FixtureCopyBackend.policyIdentity
        )

        for backendID in R02FixtureCopyBackend.supportedBackendIDs {
            let destination = files.destination(backendID: backendID)
            let prepublicationVerifier = R02PrepublicationVerifier(
                destinationURL: destination,
                expectedAACIdentity: sourceAACIdentity
            )
            let pipeline = AVFoundationMediaPipeline(
                metal: NoopMetalRenderingService(),
                outputVerifier: prepublicationVerifier
            )
            let source = try await pipeline.probe(url: files.source)
            XCTAssertEqual(source.resolution, fixture.sourceDimensions.videoResolution)
            XCTAssertTrue(source.hasAudio)
            let finalMetadata = [
                "com.mirmir.ash.r02-fixture-id": fixture.id,
                "com.mirmir.ash.r02-backend-id": backendID,
                "com.mirmir.ash.r02-backend-revision": "1",
                "com.mirmir.ash.r02-model-assets-disposition": "not_required",
                "com.mirmir.ash.r02-configuration-identity":
                    R02FixtureCopyBackend.configurationIdentity,
                "com.mirmir.ash.r02-policy-identity":
                    R02FixtureCopyBackend.policyIdentity,
                "com.mirmir.ash.r02-material-decision-identity":
                    R02FixtureCopyBackend.materialDecisionIdentity,
                "com.mirmir.ash.r02-fallback-history": "[]",
                "com.mirmir.ash.r02-frame-metadata-identities": fixture.frames
                    .map(\.metadataIdentity)
                    .joined(separator: "|")
            ]
            let mediaSession = try await pipeline.beginSession(
                source: source,
                output: OutputProfile(
                    url: destination,
                    resolution: fixture.targetDimensions.videoResolution,
                    codec: .h264,
                    preserveAudio: true,
                    timedMetadataTemplate: finalMetadata
                )
            )
            defer { mediaSession.cancel() }

            let inputReleaseProbe = R02FixtureReleaseProbe()
            let outputReleaseProbe = R02FixtureReleaseProbe()
            let driverProbe = R02FixtureDriverProbe()
            let backend = try R02FixtureCopyBackend(
                backendID: backendID,
                sourceResolution: fixture.sourceDimensions.videoResolution,
                targetResolution: fixture.targetDimensions.videoResolution,
                outputReleaseProbe: outputReleaseProbe,
                driverProbe: driverProbe
            )
            let configuration = try AppleUpscaleSessionConfiguration(
                capabilityID: capability.id,
                sourceResolution: fixture.sourceDimensions.videoResolution,
                targetResolution: fixture.targetDimensions.videoResolution,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                configurationIdentity: R02FixtureCopyBackend.configurationIdentity
            )
            let creation = await backend.makeSession(
                configuration: configuration,
                context: context
            )
            guard case .created(let backendSession) = creation else {
                return XCTFail("\(backendID) did not create the frozen media session")
            }

            for frozenFrame in fixture.frames {
                let optionalRecord = try await mediaSession.nextSourceFrame()
                let record = try XCTUnwrap(optionalRecord)
                XCTAssertEqual(record.frameIndex, frozenFrame.sequenceNumber)
                XCTAssertEqual(
                    CMTimeCompare(record.presentationTime, frozenFrame.pts.cmTime),
                    0
                )
                XCTAssertEqual(
                    CMTimeCompare(record.duration, frozenFrame.duration.cmTime),
                    0
                )
                let decodedBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
                    from: record.pixelBuffer
                )
                let normalizedBuffer = try R02FixturePixelBuffers.makeNV12(
                    width: fixture.sourceDimensions.width,
                    height: fixture.sourceDimensions.height,
                    logicalBytes: decodedBytes
                )
                let tokenID = frozenFrame.resourceTokenID
                let inputToken = try AppleUpscaleResourceLifetimeToken(
                    identity: tokenID,
                    releaseAction: { [inputReleaseProbe] in
                        inputReleaseProbe.recordRelease(identity: tokenID)
                    }
                )
                let frame = try AppleUpscaleFrame(
                    sequenceNumber: frozenFrame.sequenceNumber,
                    pixelBuffer: normalizedBuffer,
                    presentationTimestamp: record.presentationTime,
                    duration: record.duration,
                    colorDescription: fixture.colorContract.value(),
                    metadataIdentity: AppleUpscaleMetadataIdentity(
                        frozenFrame.metadataIdentity
                    ),
                    resourceLifetimeToken: inputToken
                )
                let outcome = await backendSession.submit(frame)
                guard case .processed(let processed) = outcome else {
                    return XCTFail(
                        "\(backendID) did not process media frame "
                            + "\(frozenFrame.sequenceNumber)"
                    )
                }
                XCTAssertEqual(
                    processed.metadataIdentity.rawValue,
                    frozenFrame.metadataIdentity
                )
                XCTAssertEqual(processed.resourceLifetimeToken.identity, tokenID)
                XCTAssertEqual(inputReleaseProbe.releaseCount(for: tokenID), 1)
                try await mediaSession.appendOutput(
                    pixelBuffer: processed.pixelBuffer,
                    timing: record.timing
                )
                processed.resourceLifetimeToken.release()
                XCTAssertEqual(outputReleaseProbe.releaseCount(for: tokenID), 1)
            }
            let endOfVideo = try await mediaSession.nextSourceFrame()
            XCTAssertNil(endOfVideo)

            let backendSummary = await backendSession.finish()
            XCTAssertEqual(backendSummary.submittedFrameCount, fixture.frames.count)
            XCTAssertEqual(backendSummary.processedFrameCount, fixture.frames.count)
            XCTAssertEqual(backendSummary.terminalizationCount, 1)
            XCTAssertEqual(driverProbe.maximumConcurrentProcessCount, 1)
            XCTAssertEqual(
                driverProbe.processedSequenceNumbers,
                fixture.frames.map(\.sequenceNumber)
            )

            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try await mediaSession.finish(finalMetadata: finalMetadata)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(files.temporaryFiles(for: destination).isEmpty)

            let verification = prepublicationVerifier.snapshot
            XCTAssertEqual(verification.invocationCount, 1)
            XCTAssertEqual(verification.successfulVerificationCount, 1)
            XCTAssertTrue(verification.destinationWasAbsent)
            XCTAssertTrue(verification.temporaryInputWasPresent)
            XCTAssertNotEqual(verification.verifiedURL, destination)
            let outputAACIdentity = try await OutputMediaAACIdentityReader().read(
                url: destination
            )
            XCTAssertEqual(outputAACIdentity, sourceAACIdentity)
        }
    }
    // swiftlint:enable function_body_length

    private func assertCompleteDirectIdentity(
        _ route: AppleUpscaleRouteIdentity,
        backendID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(route.backend.backendID, backendID, file: file, line: line)
        XCTAssertEqual(route.backend.backendRevision, "1", file: file, line: line)
        XCTAssertEqual(
            route.backend.modelAssetsIdentity,
            .notRequired,
            file: file,
            line: line
        )
        XCTAssertEqual(
            route.configurationIdentity,
            R02FixtureCopyBackend.configurationIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(
            route.policyIdentity,
            R02FixtureCopyBackend.policyIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(
            route.materialDecisionIdentity,
            R02FixtureCopyBackend.materialDecisionIdentity,
            file: file,
            line: line
        )
    }

    private func assertCreationRejected(
        _ outcome: AppleUpscaleSessionCreationOutcome,
        expectedRoute: AppleUpscaleRouteIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .rejected(let rejection) = outcome else {
            return XCTFail("Expected fixture session rejection", file: file, line: line)
        }
        XCTAssertEqual(rejection.reason, "fixture_session_contract_mismatch")
        XCTAssertEqual(rejection.processingIdentity.route, expectedRoute)
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)
    }
}
// swiftlint:enable type_body_length
// swiftlint:enable file_length
