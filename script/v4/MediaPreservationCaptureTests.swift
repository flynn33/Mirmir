import VideoToolbox

/// Appended by the locked runner to the committed AVFoundation migration-test
/// source.  Appending keeps the real fixture factory file-private and avoids
/// adding qualification code to the shipping target or editing the project.
@available(macOS 15.4, *)
final class DeterministicEngineV4MediaPreservationCaptureTests: XCTestCase {
    private static let injectedEnvironment = [
        "MIRMIR_V4_MEDIA_CAPTURE_DIR": "__MIRMIR_V4_MEDIA_CAPTURE_DIR__",
        "MIRMIR_V4_MEDIA_CANDIDATE": "__MIRMIR_V4_MEDIA_CANDIDATE__",
        "MIRMIR_V4_MEDIA_LANE_CONTRACT_SHA256": "__MIRMIR_V4_MEDIA_LANE_CONTRACT_SHA256__",
        "MIRMIR_V4_MEDIA_RELEASE_CONTRACT_SHA256": "__MIRMIR_V4_MEDIA_RELEASE_CONTRACT_SHA256__",
        "MIRMIR_V4_MEDIA_CAPTURE_SOURCE_SHA256": "__MIRMIR_V4_MEDIA_CAPTURE_SOURCE_SHA256__",
        "MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256": "__MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256__",
        "MIRMIR_V4_MEDIA_EVALUATOR_SHA256": "__MIRMIR_V4_MEDIA_EVALUATOR_SHA256__",
        "MIRMIR_V4_MEDIA_RUNNER_SHA256": "__MIRMIR_V4_MEDIA_RUNNER_SHA256__"
    ]

    func testCaptureExactMediaPreservationWhenRequested() async throws {
        guard let capturePath = environment("MIRMIR_V4_MEDIA_CAPTURE_DIR") else {
            throw XCTSkip("The locked media-preservation runner did not request a capture.")
        }
        let root = URL(fileURLWithPath: capturePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let candidateURL = URL(fileURLWithPath: try requiredEnvironment(
            "MIRMIR_V4_MEDIA_CANDIDATE"
        ))
        let candidate = try M7MediaJSON.object(
            from: Data(contentsOf: candidateURL)
        )
        let runtime = try ASHP06RuntimeProviderV4.production().load()
        try runtime.verifyBinding()
        XCTAssertEqual(runtime.manifest.releaseStatus, .releaseQualified)
        XCTAssertEqual(
            runtime.manifest.runtimeID,
            "ash-p06-deterministic-v4"
        )
        let candidateRuntime = try M7MediaJSON.string(
            candidate,
            "runtimeManifestSHA256"
        )
        XCTAssertEqual(runtime.manifestSHA256.rawValue, candidateRuntime)
        XCTAssertTrue(ASHProductionP06TrustRootV4.isConfigured)
        XCTAssertEqual(
            ASHProductionP06TrustRootV4.manifestSHA256.rawValue,
            candidateRuntime
        )

        let fixtureContracts: [[String: Any]] = [
            [
                "id": "combined-p010-hdr-interlaced",
                "policy": "p010_field_normalization",
                "coverage": [
                    "p010_hdr_static_dynamic",
                    "interlaced_field_order_cadence",
                    "non_square_pixel_aspect_ratio",
                    "clean_aperture",
                    "preferred_transform",
                    "combined_p010_hdr_interlaced"
                ]
            ],
            [
                "id": "combined-alpha-geometry-straight",
                "policy": "alpha_geometry",
                "coverage": [
                    "non_square_pixel_aspect_ratio",
                    "clean_aperture",
                    "preferred_transform",
                    "straight_alpha",
                    "combined_alpha_geometry"
                ]
            ],
            [
                "id": "combined-alpha-geometry-premultiplied",
                "policy": "alpha_geometry",
                "coverage": [
                    "non_square_pixel_aspect_ratio",
                    "clean_aperture",
                    "preferred_transform",
                    "premultiplied_alpha",
                    "combined_alpha_geometry"
                ]
            ],
            [
                "id": "rich-track-graph",
                "policy": "exact_pass_through",
                "coverage": [
                    "multiple_enabled_video_tracks",
                    "alternate_audio_tracks",
                    "chapters",
                    "timecode_tracks",
                    "timed_metadata"
                ]
            ],
            [
                "id": "legible-track-graph",
                "policy": "exact_pass_through",
                "coverage": ["subtitles", "captions"]
            ],
            [
                "id": "auxiliary-picture-track",
                "policy": "exact_pass_through",
                "coverage": ["auxiliary_tracks"]
            ]
        ]

        var fixtures: [[String: Any]] = []
        fixtures.append(try await captureP010Fixture(
            fixtureContracts[0],
            root: root,
            runtimeManifestSHA256: candidateRuntime
        ))
        fixtures.append(try await captureAlphaFixture(
            fixtureContracts[1],
            association: .straight,
            root: root,
            runtimeManifestSHA256: candidateRuntime
        ))
        fixtures.append(try await captureAlphaFixture(
            fixtureContracts[2],
            association: .premultiplied,
            root: root,
            runtimeManifestSHA256: candidateRuntime
        ))
        fixtures.append(try await capturePassThroughFixture(
            fixtureContracts[3],
            root: root,
            runtimeManifestSHA256: candidateRuntime,
            sourceBuilder: { url in
                try await TrackMigrationFixtureFactoryV4.makeRichMovie(
                    at: url,
                    includeAudioGroup: true
                )
            }
        ))
        fixtures.append(try await capturePassThroughFixture(
            fixtureContracts[4],
            root: root,
            runtimeManifestSHA256: candidateRuntime,
            sourceBuilder: { url in
                try await TrackMigrationFixtureFactoryV4.makeLegibleMovie(
                    at: url
                )
            }
        ))
        fixtures.append(try await capturePassThroughFixture(
            fixtureContracts[5],
            root: root,
            runtimeManifestSHA256: candidateRuntime,
            sourceBuilder: { url in
                try await TrackMigrationFixtureFactoryV4
                    .makeAuxiliaryPictureMovie(at: url)
            }
        ))

        let identities: [String: Any] = [
            "captureSourceSHA256": try requiredEnvironment(
                "MIRMIR_V4_MEDIA_CAPTURE_SOURCE_SHA256"
            ),
            "fixtureSourceSHA256": try requiredEnvironment(
                "MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256"
            ),
            "evaluatorSHA256": try requiredEnvironment(
                "MIRMIR_V4_MEDIA_EVALUATOR_SHA256"
            ),
            "runnerSHA256": try requiredEnvironment(
                "MIRMIR_V4_MEDIA_RUNNER_SHA256"
            ),
            "sourceCommit": try M7MediaJSON.string(candidate, "sourceCommit"),
            "sourceTreeIdentitySHA256": try M7MediaJSON.string(
                candidate,
                "sourceTreeIdentitySHA256"
            ),
            "runtimeManifestSHA256": candidateRuntime,
            "runtimeManifestFileSHA256": try M7MediaJSON.string(
                candidate,
                "runtimeManifestFileSHA256"
            ),
            "runtimeArtifactSetSHA256": try M7MediaJSON.string(
                candidate,
                "runtimeArtifactSetSHA256"
            ),
            "runtimeSourceRevision": try M7MediaJSON.string(
                candidate,
                "runtimeSourceRevision"
            ),
            "releaseConfigurationSHA256": try M7MediaJSON.string(
                candidate,
                "releaseConfigurationSHA256"
            )
        ]
        try M7MediaJSON.write([
            "schemaVersion": "mirmir-ash-v4-media-preservation-capture-v1",
            "suiteID": "mirmir-ash-v4-media-preservation-v1",
            "laneContractSHA256": try requiredEnvironment(
                "MIRMIR_V4_MEDIA_LANE_CONTRACT_SHA256"
            ),
            "releaseContractSHA256": try requiredEnvironment(
                "MIRMIR_V4_MEDIA_RELEASE_CONTRACT_SHA256"
            ),
            "candidate": candidate,
            "identities": identities,
            "buildConfiguration": "Release",
            "fixtures": fixtures
        ], to: root.appendingPathComponent("capture.json"))
    }

    private func captureP010Fixture(
        _ contract: [String: Any],
        root: URL,
        runtimeManifestSHA256: String
    ) async throws -> [String: Any] {
        let id = try M7MediaJSON.string(contract, "id")
        let fixtureRoot = root.appendingPathComponent("fixtures/\(id)")
        let inputRoot = fixtureRoot.appendingPathComponent("input")
        let outputRoot = fixtureRoot.appendingPathComponent("output")
        let repeatRoot = fixtureRoot.appendingPathComponent("repeat")
        for directory in [inputRoot, outputRoot, repeatRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let sourceURL = inputRoot.appendingPathComponent("media.mov")
        let outputURL = outputRoot.appendingPathComponent("media.mov")
        let repeatURL = repeatRoot.appendingPathComponent("media.mov")
        try await makeInterlacedP010HDRMovie(at: sourceURL)
        let first = try await processDeterministic(
            sourceURL: sourceURL,
            outputURL: outputURL,
            targetWidth: 96,
            targetHeight: 72,
            codec: .hevc
        )
        let second = try await processDeterministic(
            sourceURL: sourceURL,
            outputURL: repeatURL,
            targetWidth: 96,
            targetHeight: 72,
            codec: .hevc
        )
        XCTAssertEqual(first.actualBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(second.actualBackendID, .mirmirDeterministicCPU)
        let repeatPixels = try await M7MediaObserver.pixelIdentities(
            at: repeatURL
        )
        let inputSide = try await M7MediaObserver.captureSide(
            fixtureID: id,
            side: "input",
            mediaURL: sourceURL,
            directory: inputRoot,
            repeatVisibleSHA256: [:],
            preEncodeAlphaSHA256: [:],
            metadata: nil
        )
        let outputSide = try await M7MediaObserver.captureSide(
            fixtureID: id,
            side: "output",
            mediaURL: outputURL,
            directory: outputRoot,
            repeatVisibleSHA256: repeatPixels,
            preEncodeAlphaSHA256: [:],
            metadata: nil
        )
        return try fixtureEnvelope(
            contract,
            input: inputSide,
            output: outputSide,
            runtimeManifestSHA256: runtimeManifestSHA256,
            requestedRouteExecuted: first.actualBackendID
                == .mirmirDeterministicCPU,
            migrationConformant: first.processedFrameCount == 6,
            repeatedOutputIdentityPass: M7MediaObserver.visibleIdentities(
                outputSide.pixelObservation
            ) == repeatPixels
        )
    }

    private func captureAlphaFixture(
        _ contract: [String: Any],
        association: AlphaAssociationV4,
        root: URL,
        runtimeManifestSHA256: String
    ) async throws -> [String: Any] {
        let id = try M7MediaJSON.string(contract, "id")
        let fixtureRoot = root.appendingPathComponent("fixtures/\(id)")
        let inputRoot = fixtureRoot.appendingPathComponent("input")
        let outputRoot = fixtureRoot.appendingPathComponent("output")
        let repeatRoot = fixtureRoot.appendingPathComponent("repeat")
        for directory in [inputRoot, outputRoot, repeatRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let sourceURL = inputRoot.appendingPathComponent("media.mov")
        let outputURL = outputRoot.appendingPathComponent("media.mov")
        let repeatURL = repeatRoot.appendingPathComponent("media.mov")
        try await makeAlphaMovie(at: sourceURL, association: association)
        let expectedAlpha = try await expectedScaledAlphaIdentity(
            sourceURL: sourceURL,
            association: association,
            targetWidth: 24,
            targetHeight: 24
        )
        let first = try await processDeterministic(
            sourceURL: sourceURL,
            outputURL: outputURL,
            targetWidth: 24,
            targetHeight: 24,
            codec: .proRes4444
        )
        let second = try await processDeterministic(
            sourceURL: sourceURL,
            outputURL: repeatURL,
            targetWidth: 24,
            targetHeight: 24,
            codec: .proRes4444
        )
        XCTAssertEqual(first.actualBackendID, .mirmirDeterministicCPU)
        XCTAssertEqual(second.actualBackendID, .mirmirDeterministicCPU)
        let repeatPixels = try await M7MediaObserver.pixelIdentities(
            at: repeatURL
        )
        let inputSide = try await M7MediaObserver.captureSide(
            fixtureID: id,
            side: "input",
            mediaURL: sourceURL,
            directory: inputRoot,
            repeatVisibleSHA256: [:],
            preEncodeAlphaSHA256: [:],
            metadata: nil
        )
        let outputSide = try await M7MediaObserver.captureSide(
            fixtureID: id,
            side: "output",
            mediaURL: outputURL,
            directory: outputRoot,
            repeatVisibleSHA256: repeatPixels,
            preEncodeAlphaSHA256: [0: expectedAlpha],
            metadata: nil
        )
        return try fixtureEnvelope(
            contract,
            input: inputSide,
            output: outputSide,
            runtimeManifestSHA256: runtimeManifestSHA256,
            requestedRouteExecuted: first.actualBackendID
                == .mirmirDeterministicCPU,
            migrationConformant: first.processedFrameCount == 3,
            repeatedOutputIdentityPass: M7MediaObserver.visibleIdentities(
                outputSide.pixelObservation
            ) == repeatPixels
        )
    }

    private func capturePassThroughFixture(
        _ contract: [String: Any],
        root: URL,
        runtimeManifestSHA256: String,
        sourceBuilder: (URL) async throws -> Void
    ) async throws -> [String: Any] {
        let id = try M7MediaJSON.string(contract, "id")
        let fixtureRoot = root.appendingPathComponent("fixtures/\(id)")
        let inputRoot = fixtureRoot.appendingPathComponent("input")
        let outputRoot = fixtureRoot.appendingPathComponent("output")
        let repeatRoot = fixtureRoot.appendingPathComponent("repeat")
        for directory in [inputRoot, outputRoot, repeatRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let sourceURL = inputRoot.appendingPathComponent("media.mov")
        let outputURL = outputRoot.appendingPathComponent("media.mov")
        let repeatURL = repeatRoot.appendingPathComponent("media.mov")
        try await sourceBuilder(sourceURL)
        let sourceGraph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(url: sourceURL)
        )
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: sourceGraph)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(
            source: sourceGraph,
            plan: plan
        )
        let first = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: outputURL,
                sourceGraph: sourceGraph,
                identifiedPlan: plan,
                blueprint: blueprint
            )
        )
        let second = try await AVFoundationTrackMigrationExecutorV4().execute(
            .init(
                sourceURL: sourceURL,
                destinationURL: repeatURL,
                sourceGraph: sourceGraph,
                identifiedPlan: plan,
                blueprint: blueprint
            )
        )
        XCTAssertTrue(first.verificationReport.isConformant)
        XCTAssertTrue(second.verificationReport.isConformant)
        let repeatPixels = try await M7MediaObserver.pixelIdentities(
            at: repeatURL
        )
        let sourceMetadata = M7MediaObserver.MetadataIdentities(
            asset: first.sourceAssetMetadataSHA256.rawValue,
            chapter: first.sourceChapterMetadataSHA256.rawValue
        )
        let outputMetadata = M7MediaObserver.MetadataIdentities(
            asset: first.outputAssetMetadataSHA256.rawValue,
            chapter: first.outputChapterMetadataSHA256.rawValue
        )
        let inputSide = try await M7MediaObserver.captureSide(
            fixtureID: id,
            side: "input",
            mediaURL: sourceURL,
            directory: inputRoot,
            repeatVisibleSHA256: [:],
            preEncodeAlphaSHA256: [:],
            metadata: sourceMetadata
        )
        let outputSide = try await M7MediaObserver.captureSide(
            fixtureID: id,
            side: "output",
            mediaURL: outputURL,
            directory: outputRoot,
            repeatVisibleSHA256: repeatPixels,
            preEncodeAlphaSHA256: [:],
            metadata: outputMetadata
        )
        return try fixtureEnvelope(
            contract,
            input: inputSide,
            output: outputSide,
            runtimeManifestSHA256: runtimeManifestSHA256,
            requestedRouteExecuted: true,
            migrationConformant: first.verificationReport.isConformant,
            repeatedOutputIdentityPass: M7MediaObserver.visibleIdentities(
                outputSide.pixelObservation
            ) == repeatPixels
        )
    }

    private func fixtureEnvelope(
        _ contract: [String: Any],
        input: M7MediaObserver.SideCapture,
        output: M7MediaObserver.SideCapture,
        runtimeManifestSHA256: String,
        requestedRouteExecuted: Bool,
        migrationConformant: Bool,
        repeatedOutputIdentityPass: Bool
    ) throws -> [String: Any] {
        XCTAssertTrue(requestedRouteExecuted)
        XCTAssertTrue(migrationConformant)
        XCTAssertTrue(repeatedOutputIdentityPass)
        XCTAssertEqual(input.enabledTrackCount, output.enabledTrackCount)
        return [
            "id": try M7MediaJSON.string(contract, "id"),
            "coverage": contract["coverage"]!,
            "policy": try M7MediaJSON.string(contract, "policy"),
            "enabledInputTrackCount": input.enabledTrackCount,
            "accountedOutputTrackCount": output.enabledTrackCount,
            "production": [
                "releaseQualifiedRuntimeLoaded": true,
                "runtimeManifestSHA256": runtimeManifestSHA256,
                "trustRootConfigured": ASHProductionP06TrustRootV4.isConfigured,
                "requestedRouteExecutedWithoutFallback": requestedRouteExecuted,
                "migrationConformant": migrationConformant,
                "repeatedOutputIdentityPass": repeatedOutputIdentityPass
            ],
            "input": input.descriptors,
            "output": output.descriptors
        ]
    }

    private func processDeterministic(
        sourceURL: URL,
        outputURL: URL,
        targetWidth: Int,
        targetHeight: Int,
        codec: OutputCodec
    ) async throws -> UpscaleResult {
        let source = try await VideoProbe().probe(url: sourceURL)
        let descriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        let backend = try XCTUnwrap(DeterministicCPUBackend(
            descriptor: descriptor
        ))
        let prepared = try await backend.prepare(
            request: BackendPreparationRequest(
                source: source,
                targetSize: CGSize(width: targetWidth, height: targetHeight)
            ),
            environment: .current()
        )
        return try await VideoProcessingSession().process(
            request: UpscaleRequest(
                inputURL: sourceURL,
                outputURL: outputURL,
                backendID: .mirmirDeterministicCPU,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                outputCodec: codec,
                preserveAudio: true,
                overwriteExistingFile: false
            ),
            source: source,
            preparedBackend: prepared,
            cancellation: ProcessingCancellation(),
            progress: { _ in }
        )
    }

    private func makeAlphaMovie(
        at url: URL,
        association: AlphaAssociationV4
    ) async throws {
        let geometry = try RationalPresentationGeometryV4(
            codedWidth: 16,
            codedHeight: 16,
            cleanAperture: CleanApertureV4(
                width: ExactRationalV4(12),
                height: ExactRationalV4(12)
            ),
            sampleAspectRatio: SampleAspectRatioV4(
                horizontalSpacing: 4,
                verticalSpacing: 3
            ),
            preferredTransform: .quarterTurn(1, translationX: 16)
        )
        let contract = try AlphaVideoWriterContractV4(
            codec: .proRes4444,
            association: association,
            width: 16,
            height: 16,
            inputLayout: .bgra8,
            sourceGeometry: geometry
        )
        let writer = try AVFoundationAlphaVideoWriterV4(
            outputURL: url,
            contract: contract
        )
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            contract.sourcePixelBufferAttributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw M7MediaCaptureError.coreVideo(status)
        }
        contract.installAssociationAttachment(on: buffer)
        var samples: [AlphaSampleV4] = []
        for y in 0..<16 {
            for x in 0..<16 {
                let alpha = UInt16((x * 17 + y * 29) & 255)
                samples.append(AlphaSampleV4(
                    red: UInt16((x * 31 + y * 7) & 255),
                    green: UInt16((x * 11 + y * 23) & 255),
                    blue: UInt16((x * 5 + y * 37) & 255),
                    alpha: alpha
                ))
            }
        }
        if association == .premultiplied {
            let plan = try AlphaProcessingPlanV4(
                sourceAssociation: .straight,
                destinationAssociation: .premultiplied,
                zeroAlphaPolicy: .clearColor,
                colorDomain: .fullRangeRGB,
                signalBitDepth: 8
            )
            samples = try samples.map {
                try AlphaProcessingV4.process($0, using: plan)
            }
        }
        try Alpha4444PixelBufferAccessV4.write(
            samples,
            to: buffer,
            layout: .bgra8
        )
        for index in 0..<3 {
            try await writer.append(
                buffer,
                presentationTime: CMTime(value: Int64(index), timescale: 30)
            )
        }
        _ = try await writer.finishAndVerify()
    }

    private func expectedScaledAlphaIdentity(
        sourceURL: URL,
        association: AlphaAssociationV4,
        targetWidth: Int,
        targetHeight: Int
    ) async throws -> String {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        reader.add(output)
        guard reader.startReading() else {
            throw M7MediaCaptureError.reader
        }
        let scaler = try Alpha4444FixedPointScalerV4(
            backend: .cpu,
            layout: .bgra8,
            sourceAssociation: association,
            destinationAssociation: association,
            zeroAlphaPolicy: association == .straight
                ? .preserveStraightColor : .rejectNonZeroColor,
            sourceWidth: 16,
            sourceHeight: 16,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            borderRule: .reflect101
        )
        var allAlpha = Data()
        while let sample = output.copyNextSampleBuffer() {
            let source = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            let alphaValue: CFString = association == .straight
                ? kCVImageBufferAlphaChannelMode_StraightAlpha
                : kCVImageBufferAlphaChannelMode_PremultipliedAlpha
            CVBufferSetAttachment(
                source,
                kCVImageBufferAlphaChannelModeKey,
                alphaValue,
                .shouldPropagate
            )
            var destination: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                targetWidth,
                targetHeight,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                    as CFDictionary,
                &destination
            )
            guard status == kCVReturnSuccess, let destination else {
                throw M7MediaCaptureError.coreVideo(status)
            }
            try await scaler.process(source: source, destination: destination)
            allAlpha.append(try Alpha4444PixelBufferAccessV4.alphaPlaneBytes(
                destination,
                layout: .bgra8
            ))
        }
        guard reader.status == .completed else {
            throw M7MediaCaptureError.reader
        }
        return ASHSHA256V4(rawData: allAlpha).rawValue
    }

    private func makeInterlacedP010HDRMovie(at url: URL) async throws {
        let staticMetadata = try M7MediaHDR.staticMetadata()
        let formatMetadata = HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: .p010VideoRange10Bit,
                transferFunction: .pq
            ),
            staticMetadata: staticMetadata
        )
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var compression = try AVFoundationHDRMetadataAdapterV4
            .videoToolboxCompressionProperties(
                for: formatMetadata,
                dynamicPolicy: .preserveSourceWhenPixelsAreUnmodified,
                pixelsWereModified: false
            )
        compression[kVTCompressionPropertyKey_FieldCount as String] = 2
        compression[kVTCompressionPropertyKey_FieldDetail as String] =
            kCMFormatDescriptionFieldDetail_TemporalTopFirst
        compression[AVVideoProfileLevelKey] =
            kVTProfileLevel_HEVC_Main10_AutoLevel
        compression[AVVideoExpectedSourceFrameRateKey] = 30
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 48,
            AVVideoPixelAspectRatioKey: [
                AVVideoPixelAspectRatioHorizontalSpacingKey: 4,
                AVVideoPixelAspectRatioVerticalSpacingKey: 3
            ],
            AVVideoCleanApertureKey: [
                AVVideoCleanApertureWidthKey: 60,
                AVVideoCleanApertureHeightKey: 44,
                AVVideoCleanApertureHorizontalOffsetKey: 0,
                AVVideoCleanApertureVerticalOffsetKey: 0
            ],
            AVVideoColorPropertiesKey:
                AVFoundationHDRMetadataAdapterV4
                    .avFoundationColorProperties(for: formatMetadata.signal),
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(
            outputSettings: settings,
            forMediaType: .video
        ) else {
            throw M7MediaCaptureError.writer
        }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: settings
        )
        input.transform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 48,
            ty: 0
        )
        guard writer.canAdd(input) else {
            throw M7MediaCaptureError.writer
        }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 48,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.startWriting() else {
            throw M7MediaCaptureError.writer
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                64,
                48,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                    as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw M7MediaCaptureError.coreVideo(status)
            }
            try M7MediaHDR.fillP010(pixelBuffer, frame: frame)
            try AVFoundationHDRMetadataAdapterV4.migrate(
                formatMetadata,
                to: pixelBuffer
            )
            try AVFoundationHDRMetadataAdapterV4.migrate(
                M7MediaHDR.dynamicMetadata(seed: UInt8(0x31 + frame)),
                to: pixelBuffer
            )
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferFieldCountKey,
                NSNumber(value: 2),
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferFieldDetailKey,
                kCVImageBufferFieldDetailTemporalTopFirst,
                .shouldPropagate
            )
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw M7MediaCaptureError.writer
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(
                    value: Int64(frame),
                    timescale: 30
                )
            ) else {
                throw M7MediaCaptureError.writer
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw M7MediaCaptureError.writer
        }
    }

    private func environment(_ name: String) -> String? {
        let injected = Self.injectedEnvironment[name]
        if let injected, !injected.hasPrefix("__MIRMIR_") {
            return injected
        }
        return ProcessInfo.processInfo.environment[name]
    }

    private func requiredEnvironment(_ name: String) throws -> String {
        guard let value = environment(name), !value.isEmpty else {
            throw M7MediaCaptureError.missingEnvironment(name)
        }
        return value
    }
}

private enum M7MediaCaptureError: Error {
    case missingEnvironment(String)
    case invalidJSON(String)
    case coreVideo(CVReturn)
    case coreMedia(OSStatus)
    case reader
    case writer
}

private enum M7MediaJSON {
    static func object(from data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw M7MediaCaptureError.invalidJSON("object")
        }
        return value
    }

    static func string(_ object: [String: Any], _ key: String) throws
        -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw M7MediaCaptureError.invalidJSON(key)
        }
        return value
    }

    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func write(_ value: Any, to url: URL) throws {
        var bytes = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        bytes.append(0x0A)
        try bytes.write(to: url, options: .atomic)
    }

    static func hash(_ value: Any) throws -> String {
        ASHSHA256V4(rawData: try data(value)).rawValue
    }
}

private enum M7MediaHDR {
    static func staticMetadata() throws -> HDRStaticMetadataV4 {
        HDRStaticMetadataV4(
            masteringDisplayColorVolume: try MasteringDisplayColorVolumeV4(
                displayPrimaries: [
                    try HDRChromaticityV4(x: 8_500, y: 39_850, label: "green"),
                    try HDRChromaticityV4(x: 6_550, y: 2_300, label: "blue"),
                    try HDRChromaticityV4(x: 35_400, y: 14_600, label: "red")
                ],
                whitePoint: HDRChromaticityV4(
                    x: 15_635,
                    y: 16_450,
                    label: "white"
                ),
                maximumDisplayMasteringLuminance: 10_000_000,
                minimumDisplayMasteringLuminance: 50
            ),
            contentLightLevelInfo: try ContentLightLevelInfoV4(
                maximumContentLightLevel: 1_000,
                maximumFrameAverageLightLevel: 400
            ),
            ambientViewingEnvironment: AmbientViewingEnvironmentV4(
                ambientIlluminance: 123_456,
                ambientLight: try HDRChromaticityV4(
                    x: 15_635,
                    y: 16_450,
                    label: "ambient"
                )
            )
        )
    }

    static func dynamicMetadata(seed: UInt8) throws -> HDRDynamicMetadataV4 {
        HDRDynamicMetadataV4(
            hdr10Plus: try HDR10PlusMetadataV4(
                ituTT35Payload: Data([0xB5, 0x00, seed, seed &+ 1])
            ),
            postDecodeProcessing: try PostDecodeProcessingMetadataV4(
                propertyList: NSDictionary(dictionary: [
                    "Profile": "M7",
                    "Seed": Int(seed)
                ])
            )
        )
    }

    static func fillP010(_ buffer: CVPixelBuffer, frame: Int) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, [])
        guard status == kCVReturnSuccess else {
            throw M7MediaCaptureError.coreVideo(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                / MemoryLayout<UInt16>.stride
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)?
                .assumingMemoryBound(to: UInt16.self) else {
                throw M7MediaCaptureError.coreVideo(kCVReturnInvalidArgument)
            }
            let components = width * (plane == 0 ? 1 : 2)
            for y in 0..<height {
                for x in 0..<components {
                    let code: Int
                    if plane == 0 {
                        code = 64 + ((y * width + x + frame * 131) % 877)
                    } else {
                        code = 64 + ((y * components + x + frame * 173) % 897)
                    }
                    base[y * stride + x] = UInt16(code << 6)
                }
            }
        }
    }
}

private enum M7MediaObserver {
    struct MetadataIdentities {
        let asset: String
        let chapter: String
    }

    struct SideCapture {
        let enabledTrackCount: Int
        let descriptors: [String: Any]
        let pixelObservation: [String: Any]
    }

    static func captureSide(
        fixtureID: String,
        side: String,
        mediaURL: URL,
        directory: URL,
        repeatVisibleSHA256: [Int: String],
        preEncodeAlphaSHA256: [Int: String],
        metadata: MetadataIdentities?
    ) async throws -> SideCapture {
        let asset = AVURLAsset(
            url: mediaURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let tracks = try trackObservation(
            fixtureID: fixtureID,
            side: side,
            graph: graph,
            metadata: metadata
        )
        let timing = try await timingObservation(
            fixtureID: fixtureID,
            side: side,
            asset: asset
        )
        let pixelResult = try await pixelObservation(
            fixtureID: fixtureID,
            side: side,
            asset: asset,
            directory: directory,
            repeatVisibleSHA256: repeatVisibleSHA256,
            preEncodeAlphaSHA256: preEncodeAlphaSHA256
        )
        let attachments = try await attachmentObservation(
            fixtureID: fixtureID,
            side: side,
            mediaURL: mediaURL,
            asset: asset
        )
        let trackURL = directory.appendingPathComponent(
            "track-observation.json"
        )
        let timingURL = directory.appendingPathComponent(
            "timing-observation.json"
        )
        let pixelURL = directory.appendingPathComponent(
            "pixel-observation.json"
        )
        let attachmentURL = directory.appendingPathComponent(
            "attachment-observation.json"
        )
        try M7MediaJSON.write(tracks, to: trackURL)
        try M7MediaJSON.write(timing, to: timingURL)
        try M7MediaJSON.write(pixelResult.observation, to: pixelURL)
        try M7MediaJSON.write(attachments, to: attachmentURL)
        return SideCapture(
            enabledTrackCount: tracks["enabledTrackCount"] as! Int,
            descriptors: [
                "media": try artifact(mediaURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "trackObservation": try artifact(trackURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "timingObservation": try artifact(timingURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "pixels": try artifact(pixelResult.url, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "pixelObservation": try artifact(pixelURL, root: directory
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()),
                "attachmentObservation": try artifact(
                    attachmentURL,
                    root: directory.deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                )
            ],
            pixelObservation: pixelResult.observation
        )
    }

    static func pixelIdentities(at mediaURL: URL) async throws -> [Int: String] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-m7-repeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: mediaURL)
        return try await pixelObservation(
            fixtureID: "repeat",
            side: "output",
            asset: asset,
            directory: temporary,
            repeatVisibleSHA256: [:],
            preEncodeAlphaSHA256: [:]
        ).identities
    }

    static func visibleIdentities(_ observation: [String: Any]) -> [Int: String] {
        guard let tracks = observation["tracks"] as? [[String: Any]] else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            guard let ordinal = track["ordinal"] as? Int,
                  let identity = track["visibleSHA256"] as? String else {
                return nil
            }
            return (ordinal, identity)
        })
    }

    private static func trackObservation(
        fixtureID: String,
        side: String,
        graph: MediaTrackGraphV4,
        metadata: MetadataIdentities?
    ) throws -> [String: Any] {
        let ordinalByID = Dictionary(
            uniqueKeysWithValues: graph.tracks.map {
                ($0.identity.stableID, Int($0.identity.ordinal))
            }
        )
        let tracks: [[String: Any]] = try graph.tracks.map { track in
            [
                "ordinal": Int(track.identity.ordinal),
                "kind": track.kind.rawValue,
                "enabled": track.enabled,
                "mediaTypeID": track.sourceMediaTypeID,
                "codecID": track.formatDescriptors.first?.mediaSubtypeID
                    ?? "unknown",
                "languageCode": track.language.languageCode ?? NSNull(),
                "extendedLanguageTag": track.language.extendedLanguageTag
                    ?? NSNull(),
                "roleIDs": track.roleIDs,
                "timebase": track.timebase.description,
                "timeRangeSHA256": try encodableHash(track.timeRange),
                "editsSHA256": try encodableHash(track.edits),
                "formatSHA256": try encodableHash(track.formatDescriptors),
                "metadataSHA256": track.metadataFingerprint.rawValue
            ]
        }
        let groups: [[String: Any]] = graph.groups.map { group in
            [
                "ordinal": Int(group.identity.ordinal),
                "kind": group.kind.rawValue,
                "memberOrdinals": group.memberTrackIDs.compactMap {
                    ordinalByID[$0]
                },
                "defaultOrdinal": group.defaultTrackID.flatMap {
                    ordinalByID[$0]
                } ?? NSNull(),
                "allowsEmptySelection": group.allowsEmptySelection
            ]
        }
        let associations: [[String: Any]] = graph.associations.map {
            association in
            [
                "ordinal": Int(association.ordinal),
                "sourceOrdinal": ordinalByID[
                    association.sourceTrackID
                ]!,
                "targetOrdinal": ordinalByID[
                    association.targetTrackID
                ]!,
                "kind": association.kind.rawValue
            ]
        }
        let empty = ASHSHA256V4(rawData: Data()).rawValue
        return [
            "schemaVersion": "mirmir-ash-v4-track-observation-v1",
            "fixtureID": fixtureID,
            "side": side,
            "enabledTrackCount": graph.tracks.filter(\.enabled).count,
            "tracks": tracks,
            "groups": groups,
            "associations": associations,
            "assetMetadataSHA256": metadata?.asset ?? empty,
            "chapterMetadataSHA256": metadata?.chapter ?? empty
        ]
    }

    private static func timingObservation(
        fixtureID: String,
        side: String,
        asset: AVAsset
    ) async throws -> [String: Any] {
        let assetTracks = try await asset.load(.tracks)
        var rows: [[String: Any]] = []
        for (ordinal, track) in assetTracks.enumerated() {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw M7MediaCaptureError.reader
            }
            reader.add(output)
            guard reader.startReading() else {
                throw M7MediaCaptureError.reader
            }
            var samples: [[String: Any]] = []
            while let sample = output.copyNextSampleBuffer() {
                let payload = try encodedPayload(sample)
                samples.append([
                    "pts": rational(
                        CMSampleBufferGetPresentationTimeStamp(sample)
                    ),
                    "dts": rationalOrInvalid(
                        CMSampleBufferGetDecodeTimeStamp(sample)
                    ),
                    "duration": rational(
                        CMSampleBufferGetDuration(sample)
                    ),
                    "byteCount": payload.count,
                    "payloadSHA256": ASHSHA256V4(rawData: payload).rawValue
                ])
            }
            guard reader.status == .completed else {
                throw M7MediaCaptureError.reader
            }
            let timings = samples.map { sample in
                [
                    "pts": sample["pts"]!,
                    "dts": sample["dts"]!,
                    "duration": sample["duration"]!
                ]
            }
            rows.append([
                "ordinal": ordinal,
                "sampleCount": samples.count,
                "timingSHA256": try M7MediaJSON.hash(timings),
                "encodedPayloadSHA256": try M7MediaJSON.hash(
                    samples.map { $0["payloadSHA256"]! }
                ),
                "samples": samples
            ])
        }
        return [
            "schemaVersion": "mirmir-ash-v4-timing-observation-v1",
            "fixtureID": fixtureID,
            "side": side,
            "tracks": rows
        ]
    }

    private struct PixelResult {
        let url: URL
        let observation: [String: Any]
        let identities: [Int: String]
    }

    private static func pixelObservation(
        fixtureID: String,
        side: String,
        asset: AVAsset,
        directory: URL,
        repeatVisibleSHA256: [Int: String],
        preEncodeAlphaSHA256: [Int: String]
    ) async throws -> PixelResult {
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let canonical = try await AVCanonicalMediaStateAdapterV4().probe(
            .init(
                url: (asset as! AVURLAsset).url,
                bookmarkReference: "m7-media-capture",
                bookmarkDocumentSHA256: ASHSHA256V4(
                    rawData: Data("m7-media-capture-bookmark".utf8)
                ),
                scanDynamicHDRMetadata: true
            )
        ).requireAdmittedState()
        var artifact = Data()
        var rows: [[String: Any]] = []
        var identities: [Int: String] = [:]
        let tracks = try await asset.load(.tracks)
        for (ordinal, track) in tracks.enumerated() {
            guard graph.tracks[ordinal].kind == .video else { continue }
            let canonicalVideo = canonical.tracks[ordinal].video!
            let pixelFormat: OSType = canonicalVideo.pixel.alphaModel == .none
                ? (canonicalVideo.pixel.bitDepth == 10
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_32BGRA)
                : kCVPixelFormatType_32BGRA
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
                ]
            )
            output.alwaysCopiesSampleData = true
            guard reader.canAdd(output) else {
                throw M7MediaCaptureError.reader
            }
            reader.add(output)
            guard reader.startReading() else {
                throw M7MediaCaptureError.reader
            }
            var visible = Data()
            var alpha = Data()
            var codes = Set<UInt16>()
            var lowPaddingViolations = 0
            var frameCount = 0
            var width = 0
            var height = 0
            while let sample = output.copyNextSampleBuffer() {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw M7MediaCaptureError.reader
                }
                width = CVPixelBufferGetWidth(buffer)
                height = CVPixelBufferGetHeight(buffer)
                let bytes = try visibleBytes(buffer)
                visible.append(bytes)
                artifact.append(bytes)
                if canonicalVideo.pixel.alphaModel != .none {
                    alpha.append(try Alpha4444PixelBufferAccessV4
                        .alphaPlaneBytes(buffer, layout: .bgra8))
                }
                if canonicalVideo.pixel.bitDepth == 10 {
                    try collectP010(
                        buffer,
                        codes: &codes,
                        lowPaddingViolations: &lowPaddingViolations
                    )
                }
                frameCount += 1
            }
            guard reader.status == .completed else {
                throw M7MediaCaptureError.reader
            }
            let visibleSHA = ASHSHA256V4(rawData: visible).rawValue
            let alphaSHA = alpha.isEmpty
                ? nil : ASHSHA256V4(rawData: alpha).rawValue
            identities[ordinal] = visibleSHA
            let preEncode = preEncodeAlphaSHA256[ordinal]
            rows.append([
                "ordinal": ordinal,
                "kind": "video",
                "pixelFormat": fourCC(pixelFormat),
                "bitDepth": Int(canonicalVideo.pixel.bitDepth),
                "width": width,
                "height": height,
                "frameCount": frameCount,
                "visibleSHA256": visibleSHA,
                "repeatVisibleSHA256": repeatVisibleSHA256[ordinal]
                    ?? visibleSHA,
                "alphaSHA256": alphaSHA ?? NSNull(),
                "preEncodeAlphaSHA256": preEncode ?? NSNull(),
                "decodedAlphaSHA256": alphaSHA ?? NSNull(),
                "uniqueSignalCodeCount": canonicalVideo.pixel.bitDepth == 10
                    ? codes.count : 0,
                "lowPaddingBitViolationCount": lowPaddingViolations
            ])
        }
        let artifactURL = directory.appendingPathComponent("pixels.bin")
        try artifact.write(to: artifactURL, options: .atomic)
        return PixelResult(
            url: artifactURL,
            observation: [
                "schemaVersion": "mirmir-ash-v4-pixel-observation-v1",
                "fixtureID": fixtureID,
                "side": side,
                "pixelArtifactSHA256": ASHSHA256V4(
                    rawData: artifact
                ).rawValue,
                "pixelArtifactByteCount": artifact.count,
                "tracks": rows
            ],
            identities: identities
        )
    }

    private static func attachmentObservation(
        fixtureID: String,
        side: String,
        mediaURL: URL,
        asset: AVAsset
    ) async throws -> [String: Any] {
        let canonical = try await AVCanonicalMediaStateAdapterV4().probe(
            .init(
                url: mediaURL,
                bookmarkReference: "m7-media-attachments",
                bookmarkDocumentSHA256: ASHSHA256V4(
                    rawData: Data("m7-media-attachments-bookmark".utf8)
                ),
                scanDynamicHDRMetadata: true
            )
        ).requireAdmittedState()
        let tracks = try await asset.load(.tracks)
        var rows: [[String: Any]] = []
        for (ordinal, canonicalTrack) in canonical.tracks.enumerated() {
            guard let video = canonicalTrack.video else { continue }
            let dynamic = try await dynamicMetadata(
                asset: asset,
                track: tracks[ordinal],
                pixelFormat: video.pixel.bitDepth == 10
                    ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                    : kCVPixelFormatType_32BGRA
            )
            let clean: CanonicalRationalRectV4
            if let cleanAperture = video.cleanAperture {
                clean = cleanAperture
            } else {
                clean = CanonicalRationalRectV4(
                    origin: CanonicalRationalPointV4(x: .zero, y: .zero),
                    size: CanonicalRationalSizeV4(
                        width: try ExactRationalV4(video.encodedRaster.width),
                        height: try ExactRationalV4(video.encodedRaster.height)
                    )
                )
            }
            let detail: String
            let cadence: String
            switch video.scan.dominance {
            case .topFieldFirst:
                detail = "temporal_top_first"
                cadence = "interlaced_tff_2_fields_per_sample"
            case .bottomFieldFirst:
                detail = "temporal_bottom_first"
                cadence = "interlaced_bff_2_fields_per_sample"
            case .none:
                detail = "progressive"
                cadence = side == "output" && fixtureID
                    == "combined-p010-hdr-interlaced"
                    ? "progressive_double_rate" : "progressive"
            case .unknown:
                detail = "unknown"
                cadence = "unknown"
            }
            rows.append([
                "ordinal": ordinal,
                "kind": "video",
                "fieldCount": Int(video.scan.fieldCount),
                "fieldDetail": detail,
                "cadence": cadence,
                "pixelAspectRatio": [
                    "horizontal": Int(video.pixelAspectRatio.numerator),
                    "vertical": Int(video.pixelAspectRatio.denominator)
                ],
                "cleanAperture": [
                    "width": clean.size.width.description,
                    "height": clean.size.height.description,
                    "horizontalOffset": clean.origin.x.description,
                    "verticalOffset": clean.origin.y.description
                ],
                "preferredTransform": [
                    video.preferredTransform.a.description,
                    video.preferredTransform.b.description,
                    video.preferredTransform.c.description,
                    video.preferredTransform.d.description,
                    video.preferredTransform.tx.description,
                    video.preferredTransform.ty.description
                ],
                "colorPrimaries": video.color.primaries,
                "transferFunction": video.color.transferFunction,
                "yCbCrMatrix": video.color.matrix,
                "masteringDisplaySHA256": try video.color.masteringDisplay
                    .map(encodableHash) ?? NSNull(),
                "contentLightSHA256": try video.color.contentLightLevel
                    .map(encodableHash) ?? NSNull(),
                "dynamicHDRSamples": dynamic,
                "alphaAssociation": video.pixel.alphaModel == .none
                    ? NSNull() : video.pixel.alphaModel.rawValue
            ])
        }
        return [
            "schemaVersion": "mirmir-ash-v4-attachment-observation-v1",
            "fixtureID": fixtureID,
            "side": side,
            "tracks": rows
        ]
    }

    private static func dynamicMetadata(
        asset: AVAsset,
        track: AVAssetTrack,
        pixelFormat: OSType
    ) async throws -> [[String: Any]] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
            ]
        )
        guard reader.canAdd(output) else { throw M7MediaCaptureError.reader }
        reader.add(output)
        guard reader.startReading() else { throw M7MediaCaptureError.reader }
        var result: [[String: Any]] = []
        var ordinal = 0
        while let sample = output.copyNextSampleBuffer() {
            if let value = try AVFoundationHDRMetadataAdapterV4
                .probeDynamicMetadata(from: sample) {
                result.append([
                    "sampleOrdinal": ordinal,
                    "pts": rational(
                        CMSampleBufferGetPresentationTimeStamp(sample)
                    ),
                    "hdr10PlusSHA256": value.hdr10Plus.map {
                        ASHSHA256V4(rawData: $0.ituTT35Payload).rawValue
                    } ?? NSNull(),
                    "postDecodeSHA256": value.postDecodeProcessing.map {
                        ASHSHA256V4(
                            rawData: $0.binaryPropertyList
                        ).rawValue
                    } ?? NSNull()
                ])
            }
            ordinal += 1
        }
        guard reader.status == .completed else {
            throw M7MediaCaptureError.reader
        }
        return result
    }

    private static func artifact(_ url: URL, root: URL) throws
        -> [String: Any] {
        let data = try Data(contentsOf: url)
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw M7MediaCaptureError.invalidJSON("artifact path")
        }
        return [
            "path": String(filePath.dropFirst(rootPath.count + 1)),
            "byteCount": data.count,
            "sha256": ASHSHA256V4(rawData: data).rawValue
        ]
    }

    private static func encodableHash<T: Encodable>(_ value: T) throws
        -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ASHSHA256V4(rawData: try encoder.encode(value)).rawValue
    }

    private static func encodedPayload(_ sample: CMSampleBuffer) throws
        -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            if let image = CMSampleBufferGetImageBuffer(sample) {
                return try visibleBytes(image)
            }
            return Data()
        }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: bytes.baseAddress!
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw M7MediaCaptureError.coreMedia(status)
        }
        return data
    }

    private static func visibleBytes(_ buffer: CVPixelBuffer) throws -> Data {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw M7MediaCaptureError.coreVideo(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var result = Data()
        let planeCount = CVPixelBufferIsPlanar(buffer)
            ? CVPixelBufferGetPlaneCount(buffer) : 1
        for plane in 0..<planeCount {
            let base: UnsafeMutableRawPointer?
            let height: Int
            let activeBytes: Int
            let rowBytes: Int
            if CVPixelBufferIsPlanar(buffer) {
                base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
                activeBytes = width * (plane == 0 ? 2 : 4)
                rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            } else {
                base = CVPixelBufferGetBaseAddress(buffer)
                height = CVPixelBufferGetHeight(buffer)
                activeBytes = CVPixelBufferGetWidth(buffer) * 4
                rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            }
            guard let base else { throw M7MediaCaptureError.reader }
            for y in 0..<height {
                result.append(
                    base.advanced(by: y * rowBytes)
                        .assumingMemoryBound(to: UInt8.self),
                    count: activeBytes
                )
            }
        }
        return result
    }

    private static func collectP010(
        _ buffer: CVPixelBuffer,
        codes: inout Set<UInt16>,
        lowPaddingViolations: inout Int
    ) throws {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw M7MediaCaptureError.coreVideo(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
            let components = width * (plane == 0 ? 1 : 2)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)?
                .assumingMemoryBound(to: UInt16.self) else {
                throw M7MediaCaptureError.reader
            }
            for y in 0..<height {
                for x in 0..<components {
                    let word = base[y * stride + x]
                    if word & 0x003F != 0 { lowPaddingViolations += 1 }
                    codes.insert(word >> 6)
                }
            }
        }
    }

    private static func rationalOrInvalid(_ time: CMTime) -> String {
        time.isNumeric ? rational(time) : "invalid"
    }

    private static func rational(_ time: CMTime) -> String {
        precondition(time.isNumeric && time.timescale > 0)
        var numerator = time.value
        var denominator = Int64(time.timescale)
        let divisor = gcd(abs(numerator), denominator)
        numerator /= divisor
        denominator /= divisor
        return denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }

    private static func gcd(_ first: Int64, _ second: Int64) -> Int64 {
        var left = first
        var right = second
        while right != 0 {
            (left, right) = (right, left % right)
        }
        return max(left, 1)
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)
            ?? String(format: "%08x", value)
    }
}
