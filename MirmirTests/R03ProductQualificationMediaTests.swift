import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

// swiftlint:disable type_body_length
final class R03ProductQualificationMediaTests: XCTestCase {
    private static let productPolicyIdentity =
        "r03.a11.product-qualified.no-fallback.v1"
    private static let productMaterialDecisionIdentity =
        "r03.a11.genuine-mps-lanczos-product-admission.v1"

    // This transaction is intentionally contiguous: its assertions bind decoded
    // input order, backend identity, token lifetime, verification, and publication.
    // swiftlint:disable function_body_length
    func testProductQualifiedMPSLanczosCompletesExact1080pTo2160pMediaTransaction()
        async throws {
        let files = try R03ProductQualificationMediaFiles()
        defer { files.remove() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.destination.path))

        try await R03PQMediaFixtureWriter.write(
            sourceURL: files.source,
            audioScratchURL: files.audioScratch
        )
        try await assertExactSourceIdentity(files.source)
        let sourceAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: files.source
        )
        XCTAssertEqual(sourceAACIdentity.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(
            sourceAACIdentity.sampleRate,
            Double(R03ProductQualificationMediaFixture.audioSampleRate)
        )
        XCTAssertEqual(
            sourceAACIdentity.channelCount,
            UInt32(R03ProductQualificationMediaFixture.audioChannelCount)
        )
        XCTAssertFalse(sourceAACIdentity.samples.isEmpty)

        let outputReleaseProbe = R02FixtureReleaseProbe()
        let backend = try R03DeterministicBackend.makeProductQualifiedMPSLanczos(
            route: .scale2x,
            outputReleaseObserver: { [outputReleaseProbe] identity in
                outputReleaseProbe.recordRelease(identity: identity)
            }
        )
        try assertExactBackendIdentity(backend)
        let capability = try makeProductCapability(backend: backend)
        let context = try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: .product,
            policyIdentity: Self.productPolicyIdentity
        )
        let configuration = try backend.makeConfiguration()
        XCTAssertEqual(configuration.capabilityID, backend.capabilityID)
        XCTAssertEqual(
            configuration.sourceResolution,
            R03ProductQualificationMediaFixture.sourceResolution
        )
        XCTAssertEqual(
            configuration.targetResolution,
            R03ProductQualificationMediaFixture.targetResolution
        )
        XCTAssertEqual(configuration.pixelFormat, R03NV12Contract.pixelFormat)
        XCTAssertEqual(
            configuration.configurationIdentity,
            backend.routeIdentity.configurationIdentity
        )

        let creation = await backend.makeSession(
            configuration: configuration,
            context: context
        )
        let backendSession = try requireCreatedSession(creation)
        let sessionIdentity = await backendSession.identity
        XCTAssertEqual(sessionIdentity, backend.routeIdentity)

        let finalMetadata = makeTimedMetadata(backend: backend)
        let prepublicationVerifier = R03PQMediaPrepublicationVerifier(
            destinationURL: files.destination,
            expectedAACIdentity: sourceAACIdentity,
            expectedTimedMetadata: finalMetadata
        )
        let pipeline = AVFoundationMediaPipeline(
            metal: NoopMetalRenderingService(),
            outputVerifier: prepublicationVerifier
        )
        let source = try await pipeline.probe(url: files.source)
        XCTAssertEqual(
            source.resolution,
            R03ProductQualificationMediaFixture.sourceResolution
        )
        XCTAssertEqual(source.codecHint, "avc1")
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

        let inputReleaseProbe = R02FixtureReleaseProbe()
        let expectedColor = try R03NV12Contract.makeColorDescription()
        for frameSpec in R03ProductQualificationMediaFixture.frames {
            let optionalRecord = try await mediaSession.nextSourceFrame()
            let record = try XCTUnwrap(optionalRecord)
            XCTAssertEqual(record.frameIndex, frameSpec.sequenceNumber)
            XCTAssertEqual(
                CMTimeCompare(record.presentationTime, frameSpec.presentationTime),
                0
            )
            XCTAssertEqual(CMTimeCompare(record.duration, frameSpec.duration), 0)
            XCTAssertEqual(
                CVPixelBufferGetWidth(record.pixelBuffer),
                R03ProductQualificationMediaFixture.sourceResolution.width
            )
            XCTAssertEqual(
                CVPixelBufferGetHeight(record.pixelBuffer),
                R03ProductQualificationMediaFixture.sourceResolution.height
            )
            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(record.pixelBuffer),
                R03NV12Contract.pixelFormat
            )

            let decodedBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
                from: record.pixelBuffer
            )
            let normalizedBuffer = try R02FixturePixelBuffers.makeNV12(
                width: R03ProductQualificationMediaFixture.sourceResolution.width,
                height: R03ProductQualificationMediaFixture.sourceResolution.height,
                logicalBytes: decodedBytes
            )
            try R03NV12Contract.validate(
                pixelBuffer: normalizedBuffer,
                resolution: R03ProductQualificationMediaFixture.sourceResolution
            )
            let inputToken = try AppleUpscaleResourceLifetimeToken(
                identity: frameSpec.inputTokenIdentity,
                releaseAction: { [inputReleaseProbe] in
                    inputReleaseProbe.recordRelease(
                        identity: frameSpec.inputTokenIdentity
                    )
                }
            )
            let inputFrame = try AppleUpscaleFrame(
                sequenceNumber: frameSpec.sequenceNumber,
                pixelBuffer: normalizedBuffer,
                presentationTimestamp: record.presentationTime,
                duration: record.duration,
                colorDescription: expectedColor,
                metadataIdentity: AppleUpscaleMetadataIdentity(
                    frameSpec.metadataIdentity
                ),
                resourceLifetimeToken: inputToken
            )
            let outcome = await backendSession.submit(inputFrame)
            let processed = try requireProcessedFrame(
                outcome,
                sequenceNumber: frameSpec.sequenceNumber
            )
            XCTAssertEqual(processed.sequenceNumber, frameSpec.sequenceNumber)
            XCTAssertEqual(
                CMTimeCompare(
                    processed.presentationTimestamp,
                    frameSpec.presentationTime
                ),
                0
            )
            XCTAssertEqual(CMTimeCompare(processed.duration, frameSpec.duration), 0)
            XCTAssertEqual(processed.colorDescription, expectedColor)
            XCTAssertEqual(
                processed.metadataIdentity.rawValue,
                frameSpec.metadataIdentity
            )
            XCTAssertEqual(processed.processingIdentity.route, backend.routeIdentity)
            XCTAssertTrue(processed.processingIdentity.fallbackHistory.isEmpty)
            XCTAssertEqual(
                CVPixelBufferGetWidth(processed.pixelBuffer),
                R03ProductQualificationMediaFixture.targetResolution.width
            )
            XCTAssertEqual(
                CVPixelBufferGetHeight(processed.pixelBuffer),
                R03ProductQualificationMediaFixture.targetResolution.height
            )
            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(processed.pixelBuffer),
                R03NV12Contract.pixelFormat
            )
            try R03NV12Contract.validate(
                pixelBuffer: processed.pixelBuffer,
                resolution: R03ProductQualificationMediaFixture.targetResolution
            )
            XCTAssertEqual(
                inputReleaseProbe.releaseCount(for: frameSpec.inputTokenIdentity),
                1
            )

            try await mediaSession.appendOutput(
                pixelBuffer: processed.pixelBuffer,
                timing: record.timing
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: files.destination.path)
            )
            let outputTokenIdentity =
                "r03.mps.lanczos.output.\(frameSpec.sequenceNumber)"
            XCTAssertEqual(
                processed.resourceLifetimeToken.identity,
                outputTokenIdentity
            )
            XCTAssertFalse(processed.resourceLifetimeToken.isReleased)
            processed.resourceLifetimeToken.release()
            processed.resourceLifetimeToken.release()
            XCTAssertTrue(processed.resourceLifetimeToken.isReleased)
            XCTAssertEqual(
                outputReleaseProbe.releaseCount(for: outputTokenIdentity),
                1
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.destination.path))

        try await mediaSession.finish(finalMetadata: finalMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.destination.path))
        XCTAssertTrue(files.partialFiles().isEmpty)

        let verification = prepublicationVerifier.snapshot
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
        let expectedEndTime = try XCTUnwrap(
            R03ProductQualificationMediaFixture.frames.last.map {
                CMTimeAdd($0.presentationTime, $0.duration)
            }
        )
        XCTAssertEqual(CMTimeCompare(reopened.duration, expectedEndTime), 0)
        XCTAssertGreaterThan(reopened.lumaPayloadBytes, 0)
        XCTAssertGreaterThan(reopened.chromaPayloadBytes, 0)
        let outputAACIdentity = try await OutputMediaAACIdentityReader().read(
            url: files.destination
        )
        XCTAssertEqual(outputAACIdentity, sourceAACIdentity)
    }
    // swiftlint:enable function_body_length

    private func assertExactSourceIdentity(_ url: URL) async throws {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let formats = try await videoTrack.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(
            CMFormatDescriptionGetMediaSubType(format),
            kCMVideoCodecType_H264
        )
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(
            VideoResolution(
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            ),
            R03ProductQualificationMediaFixture.sourceResolution
        )
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }

    private func makeProductCapability(
        backend: R03DeterministicBackend
    ) throws -> AppleUpscaleCapability {
        let capability = try R03A11ProductAdmission.makeProductQualifiedCapability()
        XCTAssertEqual(capability.id, backend.capabilityID)
        XCTAssertEqual(capability.id.rawValue, "A11")
        XCTAssertEqual(capability.role, .primaryScaler)
        XCTAssertEqual(capability.frameworkIdentity, "MetalPerformanceShaders")
        XCTAssertEqual(capability.observationStatus, .observed)
        XCTAssertEqual(capability.runtimeDisposition, .runnable)
        XCTAssertEqual(capability.backendEligibility, .productQualified)
        XCTAssertTrue(capability.isEligible(for: .product))
        XCTAssertFalse(capability.isEligible(for: .fixtureOnly))
        return capability
    }

    private func assertExactBackendIdentity(
        _ backend: R03DeterministicBackend,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(backend.subject.id, .mpsLanczos, file: file, line: line)
        XCTAssertEqual(backend.route, .scale2x, file: file, line: line)
        XCTAssertEqual(
            backend.identity.backendID,
            "r03.mps.lanczos",
            file: file,
            line: line
        )
        XCTAssertEqual(backend.identity.backendRevision, "1", file: file, line: line)
        XCTAssertEqual(
            backend.identity.modelAssetsIdentity,
            .notRequired,
            file: file,
            line: line
        )
        XCTAssertEqual(backend.capabilityID.rawValue, "A11", file: file, line: line)
        XCTAssertEqual(
            backend.routeIdentity.configurationIdentity,
            "r03.mps.lanczos.scale_2x.420v-bt709-video-left.v1",
            file: file,
            line: line
        )
        XCTAssertEqual(
            backend.routeIdentity.policyIdentity,
            Self.productPolicyIdentity,
            file: file,
            line: line
        )
        XCTAssertEqual(
            backend.routeIdentity.materialDecisionIdentity,
            Self.productMaterialDecisionIdentity,
            file: file,
            line: line
        )
    }

    private func requireCreatedSession(
        _ outcome: AppleUpscaleSessionCreationOutcome
    ) throws -> any AppleUpscaleSession {
        switch outcome {
        case .created(let session):
            return session
        case .unavailable(let unavailable):
            throw R03ProductQualificationMediaTestError.nativeMPSUnavailable(
                unavailable.reason
            )
        case .rejected(let rejection):
            throw R03ProductQualificationMediaTestError.sessionCreationFailed(
                "rejected:\(rejection.reason)"
            )
        case .failed(let failure):
            throw R03ProductQualificationMediaTestError.sessionCreationFailed(
                "failed:\(failure.reason)"
            )
        }
    }

    private func requireProcessedFrame(
        _ outcome: AppleUpscaleBackendOutcome<AppleUpscaleProcessedFrame>,
        sequenceNumber: Int
    ) throws -> AppleUpscaleProcessedFrame {
        switch outcome {
        case .processed(let frame):
            return frame
        case .unavailable(let unavailable):
            throw R03ProductQualificationMediaTestError.nativeMPSUnavailable(
                unavailable.reason
            )
        case .rejected(let rejection):
            throw R03ProductQualificationMediaTestError.frameProcessingFailed(
                sequenceNumber: sequenceNumber,
                reason: "rejected:\(rejection.reason)"
            )
        case .failed(let failure):
            throw R03ProductQualificationMediaTestError.frameProcessingFailed(
                sequenceNumber: sequenceNumber,
                reason: "failed:\(failure.reason)"
            )
        }
    }

    private func makeTimedMetadata(
        backend: R03DeterministicBackend
    ) -> [String: String] {
        let route = backend.routeIdentity
        return [
            "com.mirmir.ash.r03-qualification-contract":
                "r03-product-qualification-media-v2",
            "com.mirmir.ash.r03-fixture-id":
                R03ProductQualificationMediaFixture.id,
            "com.mirmir.ash.r03-backend-id": route.backend.backendID,
            "com.mirmir.ash.r03-backend-revision": route.backend.backendRevision,
            "com.mirmir.ash.r03-model-assets-disposition": "not_required",
            "com.mirmir.ash.r03-configuration-identity":
                route.configurationIdentity,
            "com.mirmir.ash.r03-policy-identity": route.policyIdentity,
            "com.mirmir.ash.r03-material-decision-identity":
                route.materialDecisionIdentity,
            "com.mirmir.ash.r03-fallback-history": "[]",
            "com.mirmir.ash.r03-frame-metadata-identities":
                R03ProductQualificationMediaFixture.frames
                    .map(\.metadataIdentity)
                    .joined(separator: "|")
        ]
    }
}
// swiftlint:enable type_body_length
