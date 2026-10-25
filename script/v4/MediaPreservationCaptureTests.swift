import CoreMedia
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
                    "p010_absolute_pixel_oracle",
                    "per_frame_p010_distribution_oracle",
                    "pq_transfer_profile",
                    "hdr10plus_in_band_pts_preservation",
                    "bounded_dynamic_hdr_pts_ledger",
                    "direct_media_target_timeline_mapping",
                    "zero_normalized_replacement_media_pts",
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
                    "combined_alpha_geometry",
                    "canonical_dynamic_absent_one_pass",
                    "plan_bound_absent_timeline_mapping"
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
                    "combined_alpha_geometry",
                    "canonical_dynamic_absent_one_pass",
                    "plan_bound_absent_timeline_mapping"
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
                    "timed_metadata",
                    "canonical_dynamic_absent_one_pass",
                    "plan_bound_absent_timeline_mapping"
                ]
            ],
            [
                "id": "legible-track-graph",
                "policy": "process_primary_preserve_auxiliary",
                "coverage": [
                    "subtitles",
                    "captions",
                    "canonical_dynamic_absent_one_pass",
                    "plan_bound_absent_timeline_mapping"
                ]
            ],
            [
                "id": "auxiliary-picture-track",
                "policy": "process_primary_preserve_auxiliary",
                "coverage": [
                    "auxiliary_tracks",
                    "p010_absolute_pixel_oracle",
                    "per_frame_p010_distribution_oracle",
                    "archived_hlg_p010_fixture",
                    "canonical_dynamic_absent_one_pass",
                    "plan_bound_absent_timeline_mapping",
                    "hlg_transfer_profile"
                ]
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
                try await assertTimingMarkerFiltering(at: source)
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
                outputCodec = OutputCodec.hevc.rawValue
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

    private func assertTimingMarkerFiltering(at source: URL) async throws {
        var marker: CMSampleBuffer?
        let markerStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 0,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &marker
        )
        guard markerStatus == noErr, let marker else {
            throw M7MediaCaptureError.coreMedia(markerStatus)
        }
        XCTAssertFalse(MirmirPackagedMediaTimingSampleV4.admits(marker))

        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        guard reader.canAdd(output) else { throw M7MediaCaptureError.reader }
        reader.add(output)
        guard reader.startReading() else { throw M7MediaCaptureError.reader }
        var presentationValues: [Int64] = []
        var durationValues: [Int64] = []
        while let sample = output.copyNextSampleBuffer() {
            guard MirmirPackagedMediaTimingSampleV4.admits(sample) else {
                continue
            }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            XCTAssertTrue(presentation.isNumeric)
            XCTAssertTrue(duration.isNumeric)
            presentationValues.append(
                CMTimeConvertScale(
                    presentation,
                    timescale: 600,
                    method: .default
                ).value
            )
            durationValues.append(
                CMTimeConvertScale(
                    duration,
                    timescale: 600,
                    method: .default
                ).value
            )
        }
        guard reader.status == .completed else {
            throw M7MediaCaptureError.reader
        }
        XCTAssertEqual(presentationValues, [0, 20, 40])
        XCTAssertEqual(durationValues, [20, 20, 20])
    }

    private func captureAlphaOracleInput(
        sourceURL: URL,
        association: AlphaAssociationV4,
        directory: URL,
        root: URL
    ) async throws -> [String: Any] {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
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
        let encodedURL = url.deletingPathExtension()
            .appendingPathExtension("encoded.mov")
        try await encodeInterlacedP010HDRMovie(at: encodedURL)
        try await remuxHDR10PlusPrefixSEI(from: encodedURL, to: url)
        try await assertDynamicHDRMetadata(at: url)
        try FileManager.default.removeItem(at: encodedURL)
    }

    private func encodeInterlacedP010HDRMovie(at url: URL) async throws {
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
            throw M7MediaCaptureError.writerDetail(
                "canApply outputSettings=hevc-p010-64x48"
            )
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
            throw M7MediaCaptureError.writerDetail(
                "canAdd: " + (writer.error?.localizedDescription
                    ?? "status=\(writer.status.rawValue)")
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw M7MediaCaptureError.writerDetail(
                "start: " + (writer.error?.localizedDescription
                    ?? "status=\(writer.status.rawValue)")
            )
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
                    throw M7MediaCaptureError.writerDetail(
                        "readiness: " + (writer.error?.localizedDescription
                            ?? "status=\(writer.status.rawValue)")
                    )
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            var formatDescription: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
            guard formatStatus == noErr, let formatDescription else {
                throw M7MediaCaptureError.coreMedia(formatStatus)
            }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(
                    value: Int64(frame),
                    timescale: 30
                ),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            guard sampleStatus == noErr, let sampleBuffer else {
                throw M7MediaCaptureError.coreMedia(sampleStatus)
            }
            guard input.append(sampleBuffer) else {
                throw M7MediaCaptureError.writerDetail(
                    writer.error?.localizedDescription
                        ?? "status=\(writer.status.rawValue)"
                )
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw M7MediaCaptureError.writerDetail(
                "finish: " + (writer.error?.localizedDescription
                    ?? "status=\(writer.status.rawValue)")
            )
        }
        try await AVFoundationHDRMetadataAdapterV4.finalizeEncodedHDRMetadata(
            at: url, expectedByTrackOrdinal: [0: formatMetadata]
        )
    }

    private func remuxHDR10PlusPrefixSEI(
        from encodedURL: URL,
        to outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: encodedURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let sourceFormatHint = try XCTUnwrap(formatDescriptions.first)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw M7MediaCaptureError.reader
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.metadata = try await asset.load(.metadata)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: sourceFormatHint
        )
        writerInput.transform = try await track.load(.preferredTransform)
        writerInput.naturalSize = try await track.load(.naturalSize)
        writerInput.metadata = try await track.load(.metadata)
        guard writer.canAdd(writerInput) else {
            throw M7MediaCaptureError.writerDetail(
                "remux canAdd: " + (writer.error?.localizedDescription
                    ?? "status=\(writer.status.rawValue)")
            )
        }
        writer.add(writerInput)
        guard reader.startReading() else {
            throw M7MediaCaptureError.reader
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw M7MediaCaptureError.writerDetail(
                "remux start: " + (writer.error?.localizedDescription
                    ?? "status=\(writer.status.rawValue)")
            )
        }
        writer.startSession(atSourceTime: .zero)

        var seenFrames = Set<Int>()
        while let encodedSample = readerOutput.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(encodedSample) > 0 else {
                continue
            }
            let presentation = CMSampleBufferGetPresentationTimeStamp(
                encodedSample
            )
            guard presentation.isNumeric else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "remux presentation time is not numeric"
                )
            }
            let frame = Int(CMTimeConvertScale(
                presentation,
                timescale: 30,
                method: .default
            ).value)
            guard frame >= 0, frame < 3,
                  seenFrames.insert(frame).inserted else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "remux frame index \(frame)"
                )
            }
            let dynamicMetadata = try M7MediaHDR.dynamicMetadata(
                seed: UInt8(0x31 + frame)
            )
            guard let hdr10Plus = dynamicMetadata.hdr10Plus,
                  dynamicMetadata.postDecodeProcessing == nil else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "fixture metadata is not an HDR10+-only payload"
                )
            }
            let rewrittenSample = try rewriteHEVCSampleWithHDR10Plus(
                encodedSample,
                payload: hdr10Plus.ituTT35Payload
            )
            while !writerInput.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    reader.cancelReading()
                    throw M7MediaCaptureError.writerDetail(
                        "remux readiness: "
                            + (writer.error?.localizedDescription
                                ?? "status=\(writer.status.rawValue)")
                    )
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard writerInput.append(rewrittenSample) else {
                reader.cancelReading()
                throw M7MediaCaptureError.writerDetail(
                    "remux append: " + (writer.error?.localizedDescription
                        ?? "status=\(writer.status.rawValue)")
                )
            }
        }
        guard reader.status == .completed else {
            throw M7MediaCaptureError.reader
        }
        guard seenFrames == Set(0..<3) else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "remux observed frame indices \(seenFrames.sorted())"
            )
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw M7MediaCaptureError.writerDetail(
                "remux finish: " + (writer.error?.localizedDescription
                    ?? "status=\(writer.status.rawValue)")
            )
        }
    }

    private func rewriteHEVCSampleWithHDR10Plus(
        _ encodedSample: CMSampleBuffer,
        payload: Data
    ) throws -> CMSampleBuffer {
        guard CMSampleBufferGetNumSamples(encodedSample) == 1,
              let format = CMSampleBufferGetFormatDescription(encodedSample),
              CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
              let blockBuffer = CMSampleBufferGetDataBuffer(encodedSample) else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "prefix-SEI source is not a single HEVC sample"
            )
        }

        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize = 0
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let formatStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard formatStatus == noErr,
              parameterSetPointer != nil,
              parameterSetSize > 0,
              parameterSetCount >= 3,
              (1...4).contains(Int(nalUnitHeaderLength)) else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "prefix-SEI HEVC format description is incomplete"
            )
        }

        let sourceLength = CMBlockBufferGetDataLength(blockBuffer)
        var source = Data(count: sourceLength)
        let copyStatus = source.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: sourceLength,
                destination: baseAddress
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw M7MediaCaptureError.coreMedia(copyStatus)
        }

        let headerLength = Int(nalUnitHeaderLength)
        let insertionOffset = try hevcPrefixSEIInsertionOffset(
            in: source,
            nalUnitHeaderLength: headerLength
        )
        let nalUnit = makeHDR10PlusPrefixSEINAL(payload: payload)
        try validateHDR10PlusPrefixSEINAL(nalUnit, payload: payload)
        var encodedLength = nalUnit.count
        var lengthPrefix = Data(repeating: 0, count: headerLength)
        for index in stride(from: headerLength - 1, through: 0, by: -1) {
            lengthPrefix[index] = UInt8(encodedLength & 0xFF)
            encodedLength >>= 8
        }
        guard encodedLength == 0 else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "prefix-SEI NAL does not fit the HEVC length prefix"
            )
        }

        var rewrittenData = Data()
        rewrittenData.reserveCapacity(
            source.count + lengthPrefix.count + nalUnit.count
        )
        rewrittenData.append(source.prefix(insertionOffset))
        rewrittenData.append(lengthPrefix)
        rewrittenData.append(nalUnit)
        rewrittenData.append(source.suffix(from: insertionOffset))

        var rewrittenBlock: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: rewrittenData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: rewrittenData.count,
            flags: 0,
            blockBufferOut: &rewrittenBlock
        )
        guard status == kCMBlockBufferNoErr, let rewrittenBlock else {
            throw M7MediaCaptureError.coreMedia(status)
        }
        status = rewrittenData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: rewrittenBlock,
                offsetIntoDestination: 0,
                dataLength: rewrittenData.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw M7MediaCaptureError.coreMedia(status)
        }

        var timing = CMSampleTimingInfo()
        status = CMSampleBufferGetSampleTimingInfo(
            encodedSample,
            at: 0,
            timingInfoOut: &timing
        )
        guard status == noErr else {
            throw M7MediaCaptureError.coreMedia(status)
        }
        var sampleSize = rewrittenData.count
        var rewrittenSample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: rewrittenBlock,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &rewrittenSample
        )
        guard status == noErr, let rewrittenSample else {
            throw M7MediaCaptureError.coreMedia(status)
        }
        CMPropagateAttachments(encodedSample, destination: rewrittenSample)
        try copySampleAttachments(
            from: encodedSample,
            to: rewrittenSample
        )
        return rewrittenSample
    }

    private func hevcPrefixSEIInsertionOffset(
        in sample: Data,
        nalUnitHeaderLength: Int
    ) throws -> Int {
        var offset = 0
        var insertionOffset: Int?
        while offset < sample.count {
            guard offset + nalUnitHeaderLength <= sample.count else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "truncated HEVC NAL length prefix"
                )
            }
            var nalLength = 0
            for byte in sample[offset..<(offset + nalUnitHeaderLength)] {
                nalLength = (nalLength << 8) | Int(byte)
            }
            let nalOffset = offset + nalUnitHeaderLength
            let nalEnd = nalOffset + nalLength
            guard nalLength >= 2, nalEnd <= sample.count else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "invalid length-prefixed HEVC NAL"
                )
            }
            let nalType = (sample[nalOffset] >> 1) & 0x3F
            if nalType <= 31, insertionOffset == nil {
                insertionOffset = offset
            }
            offset = nalEnd
        }
        guard offset == sample.count, let insertionOffset else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "HEVC sample contains no complete VCL NAL"
            )
        }
        return insertionOffset
    }

    private func makeHDR10PlusPrefixSEINAL(payload: Data) -> Data {
        precondition(payload.count == 64)
        var rbsp = Data([0x04, 0x40])
        rbsp.append(payload)
        rbsp.append(0x80)
        var escaped = Data()
        escaped.reserveCapacity(rbsp.count + 8)
        var zeroCount = 0
        for byte in rbsp {
            if zeroCount >= 2, byte <= 0x03 {
                escaped.append(0x03)
                zeroCount = 0
            }
            escaped.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        var nal = Data([0x4E, 0x01])
        nal.append(escaped)
        return nal
    }

    private func validateHDR10PlusPrefixSEINAL(
        _ nal: Data,
        payload: Data
    ) throws {
        guard nal.count >= 5,
              (nal[0] >> 1) & 0x3F == 39,
              nal[0] & 0x81 == 0,
              nal[1] == 0x01 else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "invalid HDR10+ prefix-SEI NAL header"
            )
        }
        var rbsp = Data()
        var zeroCount = 0
        var index = 2
        while index < nal.count {
            let byte = nal[index]
            if zeroCount >= 2, byte == 0x03 {
                guard index + 1 < nal.count, nal[index + 1] <= 0x03 else {
                    throw M7MediaCaptureError.dynamicHDRDetail(
                        "invalid prefix-SEI emulation-prevention byte"
                    )
                }
                zeroCount = 0
                index += 1
                continue
            }
            rbsp.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
            index += 1
        }
        guard rbsp.count == payload.count + 3,
              rbsp[0] == 0x04,
              rbsp[1] == UInt8(payload.count),
              rbsp.dropFirst(2).dropLast() == payload,
              rbsp.last == 0x80 else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "HDR10+ prefix-SEI payload or trailing bits differ"
            )
        }
    }

    private func copySampleAttachments(
        from source: CMSampleBuffer,
        to destination: CMSampleBuffer
    ) throws {
        guard let sourceArray = CMSampleBufferGetSampleAttachmentsArray(
            source,
            createIfNecessary: false
        ) else { return }
        let sourceCount = CFArrayGetCount(sourceArray)
        guard sourceCount == 1,
              let destinationArray = CMSampleBufferGetSampleAttachmentsArray(
                  destination,
                  createIfNecessary: true
              ),
              CFArrayGetCount(destinationArray) == 1 else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "HEVC sample attachment cardinality differs"
            )
        }
        let sourceDictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(sourceArray, 0),
            to: CFDictionary.self
        )
        let destinationDictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(destinationArray, 0),
            to: CFMutableDictionary.self
        )
        CFDictionaryApplyFunction(
            sourceDictionary,
            { key, value, context in
                guard let key, let value, let context else { return }
                let dictionary = Unmanaged<CFMutableDictionary>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                CFDictionarySetValue(dictionary, key, value)
            },
            Unmanaged.passUnretained(destinationDictionary).toOpaque()
        )
    }

    private func assertDynamicHDRMetadata(at source: URL) async throws {
        let compressed = try await dynamicHDRMetadata(
            at: source,
            outputSettings: nil
        )
        let decoded = try await dynamicHDRMetadata(
            at: source,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                AVVideoDecompressionPropertiesKey: [
                    kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata
                        as String: true
                ]
            ]
        )
        let expected = try (0..<3).map { frame in
            try M7MediaHDR.dynamicMetadata(seed: UInt8(0x31 + frame))
        }
        guard compressed == expected, decoded == expected else {
            func status(_ values: [HDRDynamicMetadataV4?]) -> String {
                values.enumerated().map { index, value in
                    guard let value else { return "empty" }
                    return value == expected[index] ? "exact" : "mismatch"
                }.joined(separator: ",")
            }
            throw M7MediaCaptureError.dynamicHDRDetail(
                "compressed=[\(status(compressed))] "
                    + "decoded=[\(status(decoded))]"
            )
        }
    }

    private func dynamicHDRMetadata(
        at source: URL,
        outputSettings: [String: Any]?
    ) async throws -> [HDRDynamicMetadataV4?] {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: outputSettings
        )
        guard reader.canAdd(output) else { throw M7MediaCaptureError.reader }
        reader.add(output)
        guard reader.startReading() else { throw M7MediaCaptureError.reader }
        var seenFrames = Set<Int>()
        var observations: [Int: HDRDynamicMetadataV4] = [:]
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else {
                continue
            }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            guard presentation.isNumeric else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "decoded presentation time is not numeric"
                )
            }
            let frameTime = CMTimeConvertScale(
                presentation,
                timescale: 30,
                method: .default
            )
            let frame = Int(frameTime.value)
            guard frame >= 0, frame < 3 else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "decoded frame index \(frame)"
                )
            }
            let observed = try AVFoundationHDRMetadataAdapterV4
                .probeDynamicMetadata(from: sample)
            guard seenFrames.insert(frame).inserted else {
                throw M7MediaCaptureError.dynamicHDRDetail(
                    "duplicate frame index \(frame)"
                )
            }
            observations[frame] = observed
        }
        guard reader.status == .completed else {
            throw M7MediaCaptureError.reader
        }
        guard seenFrames == Set(0..<3) else {
            throw M7MediaCaptureError.dynamicHDRDetail(
                "observed frame indices \(seenFrames.sorted())"
            )
        }
        return (0..<3).map { observations[$0] }
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
        let formatMetadata = HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: .p010VideoRange10Bit,
                transferFunction: .hlg
            ),
            staticMetadata: try M7MediaHDR.staticMetadata()
        )
        var compression = try AVFoundationHDRMetadataAdapterV4
            .videoToolboxCompressionProperties(
                for: formatMetadata,
                dynamicPolicy: .preserveSourceWhenPixelsAreUnmodified,
                pixelsWereModified: false
            )
        compression[AVVideoProfileLevelKey] =
            kVTProfileLevel_HEVC_Main10_AutoLevel
        compression[AVVideoExpectedSourceFrameRateKey] = frameRate
        compression[AVVideoMaxKeyFrameIntervalKey] = frameCount
        let primarySettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey:
                AVFoundationHDRMetadataAdapterV4
                    .avFoundationColorProperties(for: formatMetadata.signal),
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(
            outputSettings: primarySettings,
            forMediaType: .video
        ) else {
            throw TrackMigrationFixtureErrorV4.writer(
                "Writer rejected the HLG Main10 primary settings."
            )
        }
        let primary = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: primarySettings
        )
        primary.mediaTimeScale = frameRate
        let primaryAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: primary,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        let auxiliary = makeVideoLane(
            seed: 211,
            title: "auxiliary-picture",
            mediaType: .auxiliaryPicture
        )
        auxiliary.input.mediaTimeScale = frameRate
        for input in [primary, auxiliary.input] {
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
            try await waitUntilReady(primary, writer: writer)
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
                    as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw TrackMigrationFixtureErrorV4.coreMedia(status)
            }
            try M7MediaHDR.fillHLGP010(
                pixelBuffer,
                frame: frameIndex
            )
            try AVFoundationHDRMetadataAdapterV4.migrate(
                formatMetadata,
                to: pixelBuffer
            )
            guard primaryAdaptor.append(
                pixelBuffer,
                withPresentationTime: time
            ) else {
                throw TrackMigrationFixtureErrorV4.writer(
                    writer.error?.localizedDescription
                        ?? "HLG primary append failed."
                )
            }
            try await appendFrame(
                lane: auxiliary,
                frameIndex: frameIndex,
                time: time,
                writer: writer
            )
        }
        primary.markAsFinished()
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
        try await AVFoundationHDRMetadataAdapterV4.finalizeEncodedHDRMetadata(
            at: url, expectedByTrackOrdinal: [0: formatMetadata]
        )
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
    case writerDetail(String)
    case dynamicHDRDetail(String)
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

    static func dynamicMetadata(seed _: UInt8) throws -> HDRDynamicMetadataV4 {
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
                    // The two fields occupy disjoint code bands. The bounded
                    // detail term retains more than 8-bit signal diversity,
                    // while the large band separation makes field dominance
                    // independently observable after Main10 encode/decode.
                    let field = y & 1
                    let fieldRow = y / 2
                    let detail = (
                        x * (plane == 0 ? 5 : 11)
                            + fieldRow * (plane == 0 ? 7 : 13)
                            + frame * (plane == 0 ? 17 : 19)
                    ) % 192
                    let code: Int
                    if plane == 0 {
                        code = (field == 0 ? 160 : 672) + detail
                    } else {
                        let componentOffset = x & 1
                        let base: Int
                        if field == 0 {
                            base = componentOffset == 0 ? 224 : 352
                        } else {
                            base = componentOffset == 0 ? 672 : 544
                        }
                        code = base + detail
                    }
                    base[y * stride + x] = UInt16(code << 6)
                }
            }
        }
    }

    static func fillHLGP010(_ buffer: CVPixelBuffer, frame: Int) throws {
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
                    let detail = (
                        x * (plane == 0 ? 7 : 9)
                            + y * (plane == 0 ? 5 : 15)
                            + frame * (plane == 0 ? 23 : 29)
                    ) % 384
                    let componentOffset = x & 1
                    let code = plane == 0
                        ? 224 + detail
                        : (componentOffset == 0 ? 288 : 416) + detail
                    base[y * stride + x] = UInt16(code << 6)
                }
            }
        }
    }
}
