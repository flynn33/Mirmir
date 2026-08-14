import VideoToolbox

/// Appended by the locked runner to the committed AVFoundation migration-test
/// source. The test host only creates and observes source fixtures; normative
/// output production and observation belong to the archived executable.
@available(macOS 15.4, *)
final class DeterministicEngineV4MediaPreservationCaptureTests: XCTestCase {
    private static let injectedEnvironment = [
        "MIRMIR_V4_MEDIA_FIXTURE_DIR": "__MIRMIR_V4_MEDIA_FIXTURE_DIR__"
    ]

    func testGenerateMediaPreservationFixturesWhenRequested() async throws {
        guard let fixturePath = environment("MIRMIR_V4_MEDIA_FIXTURE_DIR") else {
            throw XCTSkip("The locked media-preservation runner did not request fixtures.")
        }
        let root = URL(fileURLWithPath: fixturePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
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
                "policy": "process_primary_preserve_auxiliary",
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
                "policy": "process_primary_preserve_auxiliary",
                "coverage": ["subtitles", "captions"]
            ],
            [
                "id": "auxiliary-picture-track",
                "policy": "process_primary_preserve_auxiliary",
                "coverage": ["auxiliary_tracks"]
            ]
        ]

        var fixtures: [[String: Any]] = []
        for (index, contract) in fixtureContracts.enumerated() {
            let id = try M7MediaJSON.string(contract, "id")
            let directory = root.appendingPathComponent("fixtures/\(id)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let source = directory.appendingPathComponent("media.mov")
            let targetWidth: Int
            let targetHeight: Int
            let outputCodec: String
            let expectedProcessedFrameCount: Int
            var alphaOracleInput: Any = NSNull()
            switch index {
            case 0:
                try await makeInterlacedP010HDRMovie(at: source)
                targetWidth = 96
                targetHeight = 72
                outputCodec = OutputCodec.hevc.rawValue
                expectedProcessedFrameCount = 6
            case 1, 2:
                let association: AlphaAssociationV4 = index == 1
                    ? .straight : .premultiplied
                try await makeAlphaMovie(at: source, association: association)
                targetWidth = 24
                targetHeight = 24
                outputCodec = OutputCodec.proRes4444.rawValue
                expectedProcessedFrameCount = 3
                alphaOracleInput = try await captureAlphaOracleInput(
                    sourceURL: source,
                    association: association,
                    directory: directory,
                    root: root
                )
            case 3:
                try await TrackMigrationFixtureFactoryV4.makeRichMovie(
                    at: source,
                    includeAudioGroup: true
                )
                targetWidth = 96
                targetHeight = 72
                outputCodec = OutputCodec.h264.rawValue
                expectedProcessedFrameCount = 8
            case 4:
                try await TrackMigrationFixtureFactoryV4
                    .makeVideoWithLegibleMovie(at: source)
                targetWidth = 96
                targetHeight = 72
                outputCodec = OutputCodec.h264.rawValue
                expectedProcessedFrameCount = 8
            default:
                try await TrackMigrationFixtureFactoryV4
                    .makeVideoWithAuxiliaryPictureMovie(at: source)
                targetWidth = 96
                targetHeight = 72
                outputCodec = OutputCodec.h264.rawValue
                expectedProcessedFrameCount = 8
            }
            let sourceBytes = try Data(contentsOf: source)
            fixtures.append([
                "id": id,
                "policy": contract["policy"]!,
                "coverage": contract["coverage"]!,
                "sourceFile": "fixtures/\(id)/media.mov",
                "sourceByteCount": sourceBytes.count,
                "sourceSHA256": ASHSHA256V4(
                    rawData: sourceBytes
                ).rawValue,
                "targetWidth": targetWidth,
                "targetHeight": targetHeight,
                "outputCodec": outputCodec,
                "expectedProcessedFrameCount": expectedProcessedFrameCount,
                "alphaOracleInput": alphaOracleInput
            ])
        }
        try M7MediaJSON.write([
            "schemaVersion": "mirmir-ash-v4-media-fixture-package-v2",
            "suiteID": "mirmir-ash-v4-media-preservation-v1",
            "fixtures": fixtures
        ], to: root.appendingPathComponent("fixture-manifest.json"))
    }

    private func captureAlphaOracleInput(
        sourceURL: URL,
        association: AlphaAssociationV4,
        directory: URL,
        root: URL
    ) async throws -> [String: Any] {
        let asset = AVURLAsset(url: sourceURL)
        let track = try XCTUnwrap(
            try await asset.loadTracks(withMediaType: .video).first
        )
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        guard reader.canAdd(output) else { throw M7MediaCaptureError.reader }
        reader.add(output)
        guard reader.startReading() else { throw M7MediaCaptureError.reader }
        var bytes = Data()
        var frameSHA256: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let buffer = CMSampleBufferGetImageBuffer(sample) else {
                continue
            }
            let frame = try Alpha4444PixelBufferAccessV4.alphaPlaneBytes(
                buffer,
                layout: .bgra8
            )
            XCTAssertEqual(frame.count, 16 * 16)
            bytes.append(frame)
            frameSHA256.append(ASHSHA256V4(rawData: frame).rawValue)
        }
        guard reader.status == .completed, frameSHA256.count == 3 else {
            throw M7MediaCaptureError.reader
        }
        let url = directory.appendingPathComponent("alpha-source.bin")
        try bytes.write(to: url, options: .atomic)
        return [
            "schemaVersion": "mirmir-ash-v4-alpha-oracle-input-v1",
            "path": String(url.path.dropFirst(root.path.count + 1)),
            "byteCount": bytes.count,
            "sha256": ASHSHA256V4(rawData: bytes).rawValue,
            "frameSHA256": frameSHA256,
            "frameCount": frameSHA256.count,
            "width": 16,
            "height": 16,
            "association": association.rawValue
        ]
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
                // ProRes 4444 is allowed to move decoded RGB by a small code
                // amount. Keep premultiplied fixture colors and alpha away
                // from their validity boundary so codec ringing cannot turn a
                // valid encoded source into RGB > alpha before ASH admission.
                let alpha = association == .premultiplied
                    ? UInt16(96 + ((x * 17 + y * 29) % 160))
                    : UInt16((x * 17 + y * 29) & 255)
                let colorModulus = association == .premultiplied ? 128 : 256
                samples.append(AlphaSampleV4(
                    red: UInt16((x * 31 + y * 7) % colorModulus),
                    green: UInt16((x * 11 + y * 23) % colorModulus),
                    blue: UInt16((x * 5 + y * 37) % colorModulus),
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

private extension TrackMigrationFixtureFactoryV4 {
    static func makeVideoWithAuxiliaryPictureMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = assetMetadata()
        let primary = makeVideoLane(seed: 31, title: "primary-video")
        let auxiliary = makeVideoLane(
            seed: 211,
            title: "auxiliary-picture",
            mediaType: .auxiliaryPicture
        )
        auxiliary.input.mediaTimeScale = frameRate
        for input in [primary.input, auxiliary.input] {
            guard writer.availableMediaTypes.contains(input.mediaType),
                  writer.canAdd(input) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected composite \(input.mediaType.rawValue)."
                )
            }
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Composite auxiliary writer did not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        for frameIndex in 0..<frameCount {
            let time = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: frameRate
            )
            try await appendFrame(
                lane: primary,
                frameIndex: frameIndex,
                time: time,
                writer: writer
            )
            try await appendFrame(
                lane: auxiliary,
                frameIndex: frameIndex,
                time: time,
                writer: writer
            )
        }
        primary.input.markAsFinished()
        auxiliary.input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(
            value: CMTimeValue(frameCount),
            timescale: frameRate
        ))
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Composite auxiliary writer did not finish."
            )
        }
    }

    static func makeVideoWithLegibleMovie(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = assetMetadata()
        let primary = makeVideoLane(seed: 47, title: "primary-video")
        let subtitleFormat = try makeFormatDescription(
            mediaType: kCMMediaType_Subtitle,
            mediaSubtype: kCMTextFormatType_3GText,
            extensions: subtitleFormatExtensions
        )
        let captionFormat = try makeFormatDescription(
            mediaType: kCMMediaType_ClosedCaption,
            mediaSubtype: kCMClosedCaptionFormatType_CEA608
        )
        let subtitleInput = AVAssetWriterInput(
            mediaType: .subtitle,
            outputSettings: nil,
            sourceFormatHint: subtitleFormat
        )
        subtitleInput.mediaTimeScale = 600
        subtitleInput.languageCode = "eng"
        subtitleInput.extendedLanguageTag = "en-US"
        subtitleInput.metadata = trackMetadata(title: "English subtitles")
        let captionInput = AVAssetWriterInput(
            mediaType: .closedCaption,
            outputSettings: nil,
            sourceFormatHint: captionFormat
        )
        captionInput.mediaTimeScale = 600
        captionInput.languageCode = "eng"
        captionInput.extendedLanguageTag = "en-US"
        captionInput.metadata = trackMetadata(title: "CEA-608 captions")
        for input in [primary.input, subtitleInput, captionInput] {
            guard writer.availableMediaTypes.contains(input.mediaType),
                  writer.canAdd(input) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    "Writer rejected composite \(input.mediaType.rawValue)."
                )
            }
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Composite legible writer did not start."
            )
        }
        writer.startSession(atSourceTime: .zero)
        let duration = CMTime(
            value: CMTimeValue(frameCount),
            timescale: frameRate
        )
        let subtitleText = Data("ASH subtitle".utf8)
        let subtitleLength = UInt16(subtitleText.count).bigEndian
        var subtitleData = withUnsafeBytes(of: subtitleLength) { Data($0) }
        subtitleData.append(subtitleText)
        try await append(
            try makeEncodedSampleBuffer(
                data: subtitleData,
                format: subtitleFormat,
                duration: duration
            ),
            to: subtitleInput,
            writer: writer
        )
        let captionData = Data([
            0x00, 0x00, 0x00, 0x0C,
            0x63, 0x64, 0x61, 0x74,
            0x94, 0x20, 0xC8, 0xC9
        ])
        try await append(
            try makeEncodedSampleBuffer(
                data: captionData,
                format: captionFormat,
                duration: duration
            ),
            to: captionInput,
            writer: writer
        )
        subtitleInput.markAsFinished()
        captionInput.markAsFinished()
        for frameIndex in 0..<frameCount {
            try await appendFrame(
                lane: primary,
                frameIndex: frameIndex,
                time: CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: frameRate
                ),
                writer: writer
            )
        }
        primary.input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TrackMigrationFixtureErrorV4.writer(
                writer.error?.localizedDescription
                    ?? "Composite legible writer did not finish."
            )
        }
    }
}

private enum M7MediaCaptureError: Error {
    case missingEnvironment(String)
    case invalidJSON(String)
    case coreVideo(CVReturn)
    case coreMedia(OSStatus)
    case reader
    case writer
    case invalidProductionRoute
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
            ambientViewingEnvironment: try AmbientViewingEnvironmentV4(
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
        // Standards-valid SMPTE ST 2094-40 Application 4, Version 1
        // metadata carried as registered ITU-T T.35 user data. The complete
        // 64-byte payload is deliberately stable across frames; the sample
        // timeline supplies the per-frame identity while allowing the
        // preservation qualification to compare exact metadata bytes.
        let hdr10PlusPayload = Data([
            0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01, 0x40,
            0x00, 0x0C, 0x80, 0x3C, 0xB0, 0x19, 0xBD, 0x0D,
            0x80, 0x00, 0x41, 0xE4, 0x08, 0x00, 0x00, 0x28,
            0x5F, 0x00, 0x50, 0x01, 0x70, 0xC8, 0x00, 0x05,
            0x90, 0x00, 0x12, 0x58, 0x01, 0xAE, 0xD0, 0x0B,
            0x5A, 0xF8, 0x1B, 0xE3, 0x18, 0x5B, 0x4C, 0x00,
            0x42, 0x90, 0x3C, 0x24, 0x8F, 0x4A, 0x9B, 0xF9,
            0x42, 0xDB, 0xD8, 0x37, 0xBE, 0x57, 0xAA, 0x00
        ])
        return HDRDynamicMetadataV4(
            hdr10Plus: try HDR10PlusMetadataV4(
                ituTT35Payload: hdr10PlusPayload
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
                    // Keep the compressed/decompressed fixture well inside
                    // legal P010 video range. Values at the 64/940 and
                    // 64/960 endpoints can ring outside the admitted signal
                    // interval after HEVC encoding even though the source
                    // buffer itself is legal.
                    let phase = (
                        y * (plane == 0 ? 3 : 7)
                            + x * (plane == 0 ? 5 : 11)
                            + frame * (plane == 0 ? 17 : 19)
                    ) % 512
                    let triangle = phase <= 255 ? phase : 511 - phase
                    let code = plane == 0
                        ? 256 + triangle * 2
                        : 384 + triangle
                    base[y * stride + x] = UInt16(code << 6)
                }
            }
        }
    }
}
