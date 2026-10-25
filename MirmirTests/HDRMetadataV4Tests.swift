import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import Mirmir

final class HDRMetadataV4Tests: XCTestCase {
    func testPrimaryGraphTimebaseNormalizesSegmentBoundariesExactly() throws {
        let timescale = try DeterministicV4MediaProcessingSession
            .segmentBoundaryTimescale(for: ExactRationalV4(1, 600))

        XCTAssertEqual(timescale, 600)
        XCTAssertEqual(
            try DeterministicV4MediaProcessingSession.workflowTime(
                ExactRationalV4(91, 30),
                timescale: timescale
            ),
            try WorkflowMediaTimeV4(value: 1_820, timescale: 600)
        )
        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession.workflowTime(
                ExactRationalV4(1, 7),
                timescale: timescale
            )
        ) { error in
            XCTAssertEqual(
                error as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: .workflowTimeInexactConversion)
            )
        }
        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .segmentBoundaryTimescale(for: ExactRationalV4(1_001, 30_000))
        ) { error in
            XCTAssertEqual(
                error as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: .segmentBoundaryInvalidTimebase)
            )
        }
    }

    func testDecodedDurationUsesAdjacentDecodeTimeAcrossPresentationGap()
        throws
    {
        let duration = try DeterministicV4MediaProcessingSession
            .authoritativeDecodedDuration(
                currentDecodeTime: time(59),
                followingDecodeTime: time(60),
                currentPresentationTime: time(59),
                terminalReaderReportedDuration: nil
            )
        XCTAssertEqual(duration, time(1))

        let terminal = try DeterministicV4MediaProcessingSession
            .authoritativeDecodedDuration(
                currentDecodeTime: time(60),
                followingDecodeTime: nil,
                currentPresentationTime: time(90),
                terminalReaderReportedDuration: time(1)
            )
        XCTAssertEqual(terminal, time(1))
    }

    func testDecodedDurationRecordsBindDecodeCadenceToReorderedPresentation()
        throws
    {
        let presentationOrder: [Int64] = [0, 2, 1, 3]
        let compressed = try presentationOrder.enumerated().map {
            decodeOrdinal, presentationOrdinal in
            DeterministicV4CompressedTimingRecordV4(
                presentationTime: try HDR10PlusPresentationTimeV4(
                    time(presentationOrdinal)
                ),
                decodeTime: time(Int64(decodeOrdinal)),
                readerReportedDuration: time(1)
            )
        }
        let records = try DeterministicV4MediaProcessingSession
            .authoritativeDecodedDurationRecords(
                compressed: compressed,
                followingDecodeTime: nil,
                readerIsExhausted: true,
                maximumRecordCount: compressed.count
            )

        XCTAssertEqual(
            records.map(\.presentationTime),
            try (0..<4).map {
                try HDR10PlusPresentationTimeV4(time(Int64($0)))
            }
        )
        XCTAssertEqual(records.map(\.duration), Array(repeating: time(1), count: 4))

        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .authoritativeDecodedDurationRecords(
                    compressed: [compressed[0], compressed[0]],
                    followingDecodeTime: nil,
                    readerIsExhausted: true,
                    maximumRecordCount: 2
                )
        )
    }

    func testDecodedDurationRecordsScanSelectedPrefixAcrossDecodePermutation()
        throws
    {
        let decodeOrder: [Int64] = [0, 3, 1, 2]
        let compressed = try decodeOrder.enumerated().map {
            decodeOrdinal, presentationOrdinal in
            DeterministicV4CompressedTimingRecordV4(
                presentationTime: try HDR10PlusPresentationTimeV4(
                    time(presentationOrdinal)
                ),
                decodeTime: time(Int64(decodeOrdinal)),
                readerReportedDuration: time(1)
            )
        }
        let selected = Set(try [Int64(0), 1].map {
            try HDR10PlusPresentationTimeV4(time($0))
        })
        var selector = try DeterministicV4CompressedPrefixSelectorV4(
            selectedPresentationTimes: selected,
            maximumScannedRecordCount: 4
        )
        var admissions: [Bool] = []
        for record in compressed where !selector.isComplete {
            admissions.append(try selector.admit(record.presentationTime))
        }

        XCTAssertEqual(admissions, [true, false, true])
        XCTAssertTrue(selector.isComplete)
        XCTAssertEqual(selector.scannedRecordCount, 3)

        let records = try DeterministicV4MediaProcessingSession
            .authoritativeDecodedDurationRecords(
                compressed: Array(compressed.prefix(3)),
                selectedPresentationTimes: selected,
                followingDecodeTime: compressed[3].decodeTime,
                readerIsExhausted: false,
                maximumRecordCount: 4
            )
        XCTAssertEqual(
            records.map(\.presentationTime),
            try [Int64(0), 1].map {
                try HDR10PlusPresentationTimeV4(time($0))
            }
        )
        XCTAssertEqual(records.map(\.duration), [time(1), time(1)])

        var bounded = try DeterministicV4CompressedPrefixSelectorV4(
            selectedPresentationTimes: selected,
            maximumScannedRecordCount: 2
        )
        XCTAssertTrue(try bounded.admit(compressed[0].presentationTime))
        XCTAssertFalse(try bounded.admit(compressed[1].presentationTime))
        XCTAssertFalse(bounded.isComplete)
        XCTAssertFalse(bounded.hasRemainingCapacity)
        XCTAssertThrowsError(
            try bounded.admit(compressed[2].presentationTime)
        )
    }

    func testScratchLedgerProjectionRetainsNonzeroMediaOrigin() throws {
        let mediaStart = time(150)
        let segmentStart = time(180)
        let local = time(2)
        let duration = time(30)
        let outputStart = time(300)
        let readerStart = CMTimeAdd(
            outputStart,
            CMTimeSubtract(segmentStart, mediaStart)
        )

        XCTAssertEqual(
            try DeterministicV4MediaProcessingSession
                .assembledScratchPresentationTime(
                    localPresentationTime: local,
                    segmentMediaStart: segmentStart,
                    segmentDuration: duration
                ),
            time(182)
        )
        XCTAssertEqual(readerStart, time(330))
        XCTAssertNotEqual(time(182), CMTimeAdd(local, CMTimeSubtract(
            segmentStart,
            mediaStart
        )))
    }

    func testDecodedDurationRejectsInvalidAdjacentAndTerminalTiming() {
        assertDecodedDurationRejected(
            currentDecodeTime: time(1),
            followingDecodeTime: time(1),
            currentPresentationTime: time(1),
            expectedSite: .authoritativeDurationInvalidFollowingDecodeTime
        )
        assertDecodedDurationRejected(
            currentDecodeTime: time(2),
            followingDecodeTime: time(1),
            currentPresentationTime: time(1),
            expectedSite: .authoritativeDurationInvalidFollowingDecodeTime
        )
        assertDecodedDurationRejected(
            currentDecodeTime: time(1),
            followingDecodeTime: time(2, epoch: 1),
            currentPresentationTime: time(1),
            expectedSite: .authoritativeDurationInvalidFollowingDecodeTime
        )
        assertDecodedDurationRejected(
            currentDecodeTime: time(1),
            followingDecodeTime: nil,
            currentPresentationTime: time(1),
            terminalReaderReportedDuration: .invalid,
            expectedSite: .authoritativeDurationInvalidDuration
        )
    }

    func testMasteringCLLAndAmbientPayloadsRoundTripBigEndianExactly() throws {
        let staticMetadata = try makeStaticMetadata()
        let mastering = try XCTUnwrap(
            staticMetadata.masteringDisplayColorVolume
        )
        let contentLight = try XCTUnwrap(staticMetadata.contentLightLevelInfo)
        let ambient = try XCTUnwrap(
            staticMetadata.ambientViewingEnvironment
        )

        XCTAssertEqual(mastering.payload.count, 24)
        XCTAssertEqual(
            try MasteringDisplayColorVolumeV4(payload: mastering.payload),
            mastering
        )
        XCTAssertEqual(contentLight.payload, Data([0x03, 0xE8, 0x01, 0x90]))
        XCTAssertEqual(
            try ContentLightLevelInfoV4(payload: contentLight.payload),
            contentLight
        )
        XCTAssertEqual(ambient.payload.count, 8)
        XCTAssertEqual(
            try AmbientViewingEnvironmentV4(payload: ambient.payload),
            ambient
        )
    }

    func testInvalidStaticAndDynamicPayloadsFailClosed() throws {
        XCTAssertThrowsError(
            try MasteringDisplayColorVolumeV4(payload: Data(repeating: 0, count: 23))
        )
        XCTAssertThrowsError(
            try ContentLightLevelInfoV4(
                maximumContentLightLevel: 400,
                maximumFrameAverageLightLevel: 401
            )
        )
        XCTAssertThrowsError(
            try HDRChromaticityV4(x: 40_000, y: 20_000, label: "invalid")
        )
        XCTAssertThrowsError(
            try AmbientViewingEnvironmentV4(
                ambientIlluminance: 0,
                ambientLight: HDRChromaticityV4(
                    x: 15_635,
                    y: 16_450,
                    label: "ambient"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .invalidAmbientIlluminance(0)
            )
        }
        XCTAssertThrowsError(
            try AmbientViewingEnvironmentV4(
                payload: Data([0, 0, 0, 0, 0x3D, 0x13, 0x40, 0x42])
            )
        )
        XCTAssertThrowsError(
            try HDR10PlusMetadataV4(ituTT35Payload: Data([0x00, 0x01]))
        )
        XCTAssertThrowsError(
            try PostDecodeProcessingMetadataV4(propertyList: ["not", "a", "dict"])
        )
        XCTAssertThrowsError(
            try HDRSignalV4(
                storage: .nv12VideoRange8Bit,
                transferFunction: .pq
            )
        )
    }

    func testHDR10PlusHeaderRejectsTruncationAndWrongIdentifiers() throws {
        XCTAssertThrowsError(
            try HDR10PlusMetadataV4(
                ituTT35Payload: Data([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04])
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .invalidPayloadLength(
                    kind: "HDR10+ ITU-T T.35 header",
                    expected: 7,
                    actual: 6
                )
            )
        }
        XCTAssertThrowsError(
            try HDR10PlusMetadataV4(
                ituTT35Payload: Data([
                    0xB5, 0x00, 0x3D, 0x00, 0x01, 0x04, 0x01
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .invalidHDR10PlusTerminalProviderCode(0x003D)
            )
        }
        XCTAssertThrowsError(
            try HDR10PlusMetadataV4(
                ituTT35Payload: Data([
                    0xB5, 0x00, 0x3C, 0x00, 0x02, 0x04, 0x01
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .invalidHDR10PlusTerminalProviderOrientedCode(0x0002)
            )
        }
        XCTAssertThrowsError(
            try HDR10PlusMetadataV4(
                ituTT35Payload: Data([
                    0xB5, 0x00, 0x3C, 0x00, 0x01, 0x05, 0x01
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .invalidHDR10PlusApplicationIdentifier(5)
            )
        }
        XCTAssertThrowsError(
            try HDR10PlusMetadataV4(
                ituTT35Payload: Data([
                    0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x00
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .invalidHDR10PlusApplicationVersion(0)
            )
        }
    }

    func testPQAndHLGFormatDescriptionProbeRequiresBT2020Tags() throws {
        for transfer in [HDRTransferFunctionV4.pq, .hlg] {
            let expected = try makeFormatMetadata(transfer: transfer)
            let description = try makeFormatDescription(metadata: expected)
            XCTAssertEqual(
                try AVFoundationHDRMetadataAdapterV4.probe(
                    formatDescription: description,
                    decodedStorage: .p010VideoRange10Bit
                ),
                expected
            )
        }

        var contradictory = AVFoundationHDRMetadataAdapterV4
            .formatDescriptionExtensions(
                for: try makeFormatMetadata(transfer: .pq)
            )
        contradictory[kCMFormatDescriptionExtension_YCbCrMatrix] =
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        let description = try makeFormatDescription(extensions: contradictory)
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: description,
                decodedStorage: .p010VideoRange10Bit
            )
        )

        var alternativeConflict = AVFoundationHDRMetadataAdapterV4
            .formatDescriptionExtensions(
                for: try makeFormatMetadata(transfer: .pq)
            )
        alternativeConflict[
            kCMFormatDescriptionExtension_AlternativeTransferCharacteristics
        ] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: makeFormatDescription(
                    extensions: alternativeConflict
                ),
                decodedStorage: .p010VideoRange10Bit
            )
        )

        var bitDepthConflict = AVFoundationHDRMetadataAdapterV4
            .formatDescriptionExtensions(
                for: try makeFormatMetadata(transfer: .hlg)
            )
        bitDepthConflict[kCMFormatDescriptionExtension_BitsPerComponent] = 8
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: makeFormatDescription(
                    extensions: bitDepthConflict
                ),
                decodedStorage: .p010VideoRange10Bit
            )
        )
    }

    func testStaticMetadataWithoutPQOrHLGFailsClosed() throws {
        let staticMetadata = try makeStaticMetadata()
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries:
                kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction:
                kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix:
                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume:
                try XCTUnwrap(
                    staticMetadata.masteringDisplayColorVolume
                ).payload as CFData
        ]
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probe(
                formatDescription: makeFormatDescription(extensions: extensions),
                decodedStorage: .p010VideoRange10Bit
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .staticMetadataWithoutHDRTransfer
            )
        }
    }

    func testPixelBufferStaticMetadataMigrationRoundTripsAndRejectsConflict() throws {
        for transfer in [HDRTransferFunctionV4.pq, .hlg] {
            let metadata = try makeFormatMetadata(transfer: transfer)
            let buffer = try makePixelBuffer()
            try AVFoundationHDRMetadataAdapterV4.migrate(metadata, to: buffer)
            XCTAssertEqual(
                try AVFoundationHDRMetadataAdapterV4.probe(
                    pixelBuffer: buffer,
                    storage: .p010VideoRange10Bit
                ),
                metadata
            )
            XCTAssertFalse(metadata.signal.permitsToneMapping)
        }

        let conflicting = try makePixelBuffer()
        CVBufferSetAttachment(
            conflicting,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            .shouldPropagate
        )
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.migrate(
                makeFormatMetadata(transfer: .pq),
                to: conflicting
            )
        )
    }

    func testHDR10PlusAndPostDecodeAttachmentsRoundTripOnSampleAndPixelBuffer() throws {
        let dynamic = try makeDynamicMetadata(version: 1)
        let pixelBuffer = try makePixelBuffer()
        let sampleBuffer = try makeSampleBuffer(imageBuffer: pixelBuffer)

        try AVFoundationHDRMetadataAdapterV4.migrate(
            dynamic,
            to: sampleBuffer
        )
        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: sampleBuffer
            ),
            dynamic
        )

        try AVFoundationHDRMetadataAdapterV4.migrate(
            dynamic,
            to: pixelBuffer
        )
        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: pixelBuffer
            ),
            dynamic
        )

        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.migrate(
                makeDynamicMetadata(version: 2),
                to: sampleBuffer
            )
        )
    }

    func testCountOneImageBackedSampleProbesPixelDynamicMetadata() throws {
        let dynamic = try makeDynamicMetadata(version: 1)
        let pixelBuffer = try makePixelBuffer()
        try AVFoundationHDRMetadataAdapterV4.migrate(dynamic, to: pixelBuffer)
        let sampleBuffer = try makeSampleBuffer(imageBuffer: pixelBuffer)

        XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), 1)
        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: sampleBuffer
            ),
            dynamic
        )
    }

    func testEqualSampleAndImageDynamicMetadataReconcilesExactly() throws {
        let dynamic = try makeDynamicMetadata(version: 1)
        let pixelBuffer = try makePixelBuffer()
        let sampleBuffer = try makeSampleBuffer(imageBuffer: pixelBuffer)
        try AVFoundationHDRMetadataAdapterV4.migrate(dynamic, to: sampleBuffer)
        try AVFoundationHDRMetadataAdapterV4.migrate(dynamic, to: pixelBuffer)

        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: sampleBuffer
            ),
            dynamic
        )
    }

    func testComplementarySampleAndImageDynamicMetadataMergesExactly() throws {
        let dynamic = try makeDynamicMetadata(version: 1)
        let pixelBuffer = try makePixelBuffer()
        let sampleBuffer = try makeSampleBuffer(imageBuffer: pixelBuffer)
        try AVFoundationHDRMetadataAdapterV4.migrate(
            HDRDynamicMetadataV4(hdr10Plus: dynamic.hdr10Plus),
            to: sampleBuffer
        )
        try AVFoundationHDRMetadataAdapterV4.migrate(
            HDRDynamicMetadataV4(
                postDecodeProcessing: dynamic.postDecodeProcessing
            ),
            to: pixelBuffer
        )

        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: sampleBuffer
            ),
            dynamic
        )
    }

    func testContradictorySampleAndImageDynamicMetadataFailsClosed() throws {
        let pixelBuffer = try makePixelBuffer()
        let sampleBuffer = try makeSampleBuffer(imageBuffer: pixelBuffer)
        try AVFoundationHDRMetadataAdapterV4.migrate(
            makeDynamicMetadata(version: 1),
            to: sampleBuffer
        )
        try AVFoundationHDRMetadataAdapterV4.migrate(
            makeDynamicMetadata(version: 2),
            to: pixelBuffer
        )

        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4.probeDynamicMetadata(
                from: sampleBuffer
            )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .contradictoryMetadata(
                    "sample and image-buffer post-decode metadata differ"
                )
            )
        }
    }

    func testLengthPrefixedHEVCHDR10PlusParserAcceptsExactPayload() throws {
        let expected = try XCTUnwrap(
            makeDynamicMetadata(version: 1).hdr10Plus
        )
        let extendedNonHDRMessage = Data([0xFF, 0x05, 0xFF, 0x01])
            + Data(repeating: 0x7E, count: 256)
        let sei = makePrefixSEINAL(
            messages: extendedNonHDRMessage
                + Data([0x04, UInt8(expected.ituTT35Payload.count)])
                + expected.ituTT35Payload
        )
        let sample = lengthPrefixed(sei) + lengthPrefixed(
            Data([0x02, 0x01, 0x80])
        )

        XCTAssertEqual(
            try AVFoundationHDRMetadataAdapterV4.probeHDR10PlusMetadata(
                inLengthPrefixedHEVCSample: sample,
                nalUnitHeaderLength: 4
            ),
            expected
        )
        XCTAssertNil(
            try AVFoundationHDRMetadataAdapterV4.probeHDR10PlusMetadata(
                inLengthPrefixedHEVCSample: lengthPrefixed(
                    Data([0x02, 0x01, 0x80])
                ),
                nalUnitHeaderLength: 4
            )
        )
    }

    func testLengthPrefixedHEVCHDR10PlusParserRejectsMalformedAndDuplicateSEI()
        throws {
        let payload = try XCTUnwrap(
            makeDynamicMetadata(version: 1).hdr10Plus
        ).ituTT35Payload
        var conflictingPayload = payload
        conflictingPayload[
            conflictingPayload.index(before: conflictingPayload.endIndex)
        ] ^= 0x01
        let sei = makePrefixSEINAL(
            messages: Data([0x04, UInt8(payload.count)]) + payload
        )
        let conflictingSEI = makePrefixSEINAL(
            messages: Data([0x04, UInt8(conflictingPayload.count)])
                + conflictingPayload
        )
        let vcl = lengthPrefixed(Data([0x02, 0x01, 0x80]))
        let exact = lengthPrefixed(sei) + vcl
        let forgeries = [
            Data(exact.dropLast()),
            lengthPrefixed(sei) + lengthPrefixed(sei) + vcl,
            lengthPrefixed(sei) + lengthPrefixed(conflictingSEI) + vcl,
        ]

        for forgery in forgeries {
            XCTAssertThrowsError(
                try AVFoundationHDRMetadataAdapterV4.probeHDR10PlusMetadata(
                    inLengthPrefixedHEVCSample: forgery,
                    nalUnitHeaderLength: 4
                )
            )
        }
    }

    func testHDR10PlusPreservationReportFoldIsOrderedAndCountIndependent()
        throws {
        let sourceA = ASHSHA256V4(rawData: Data("source-a".utf8))
        let sourceB = ASHSHA256V4(rawData: Data("source-b".utf8))
        let outputA = ASHSHA256V4(rawData: Data("output-a".utf8))
        let outputB = ASHSHA256V4(rawData: Data("output-b".utf8))
        let timeline = ASHSHA256V4(rawData: Data("timeline".utf8))
        let first = try DeterministicV4HDR10PlusPreservationReportV4(
            timelineMappingSHA256: timeline,
            sourceLedgerSHA256: sourceA,
            outputLedgerSHA256: outputA,
            rewrittenSampleCount: 1
        )
        let second = try DeterministicV4HDR10PlusPreservationReportV4(
            timelineMappingSHA256: timeline,
            sourceLedgerSHA256: sourceB,
            outputLedgerSHA256: outputB,
            rewrittenSampleCount: 2
        )
        let ordered = try DeterministicV4HDR10PlusPreservationReportV4
            .aggregate([first, second])
        let reversed = try DeterministicV4HDR10PlusPreservationReportV4
            .aggregate([second, first])

        XCTAssertNotEqual(
            ordered.sourceLedgerSHA256,
            reversed.sourceLedgerSHA256
        )
        XCTAssertNotEqual(
            ordered.outputLedgerSHA256,
            reversed.outputLedgerSHA256
        )
        XCTAssertEqual(ordered.rewrittenSampleCount, 3)
        XCTAssertEqual(ordered.segmentCount, 2)

        let changedCount = try
            DeterministicV4HDR10PlusPreservationReportV4(
                timelineMappingSHA256: timeline,
                sourceLedgerSHA256: sourceA,
                outputLedgerSHA256: outputA,
                rewrittenSampleCount: 17
            )
        let countOne = try DeterministicV4HDR10PlusPreservationReportV4
            .aggregate([first])
        let countSeventeen = try
            DeterministicV4HDR10PlusPreservationReportV4.aggregate([
                changedCount
            ])
        XCTAssertEqual(
            countOne.sourceLedgerSHA256,
            countSeventeen.sourceLedgerSHA256
        )
        XCTAssertEqual(
            countOne.outputLedgerSHA256,
            countSeventeen.outputLedgerSHA256
        )
        XCTAssertNotEqual(
            countOne.rewrittenSampleCount,
            countSeventeen.rewrittenSampleCount
        )
        XCTAssertThrowsError(
            try DeterministicV4HDR10PlusPreservationReportV4.aggregate([
                first,
                DeterministicV4HDR10PlusPreservationReportV4(
                    timelineMappingSHA256: ASHSHA256V4(
                        rawData: Data("other-timeline".utf8)
                    ),
                    sourceLedgerSHA256: sourceB,
                    outputLedgerSHA256: outputB,
                    rewrittenSampleCount: 2
                )
            ])
        )
    }

    func testCanonicalDynamicAbsentOnePassReportIsLockedAndNonSegmented()
        throws {
        let trackPlan = ASHSHA256V4(rawData: Data("track-plan".utf8))
        let report = try DeterministicV4HDR10PlusPreservationReportV4
            .canonicalDynamicAbsentOnePass(trackPlanSHA256: trackPlan)
        XCTAssertEqual(report.routeID, .canonicalDynamicAbsentOnePass)
        XCTAssertEqual(report.rewrittenSampleCount, 0)
        XCTAssertEqual(report.segmentCount, 0)
        XCTAssertNotEqual(
            report.sourceLedgerSHA256,
            report.outputLedgerSHA256
        )
        XCTAssertEqual(
            report.timelineMappingSHA256,
            try DeterministicV4HDR10PlusPreservationReportV4
                .notApplicableTimelineMappingSHA256(
                    trackPlanSHA256: trackPlan
                )
        )
        XCTAssertEqual(
            report.timelineMappingSHA256,
            try ASHSHA256V4(
                "fe4442083000bc3d4647e6a72c5abd4afd0581d734ec71b5dd5400b7767864ef"
            )
        )
        XCTAssertNotEqual(
            report.timelineMappingSHA256,
            try DeterministicV4HDR10PlusPreservationReportV4
                .notApplicableTimelineMappingSHA256(
                    trackPlanSHA256: ASHSHA256V4(
                        rawData: Data("other-track-plan".utf8)
                    )
                )
        )
        let encoded = try ASHCanonicalJSONV4.encode(report)
        XCTAssertEqual(
            try ASHCanonicalJSONV4.decode(
                DeterministicV4HDR10PlusPreservationReportV4.self,
                from: encoded
            ),
            report
        )
        var missingTimeline = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        )
        missingTimeline.removeValue(forKey: "timelineMappingSHA256")
        let missingTimelineData = try JSONSerialization.data(
            withJSONObject: missingTimeline,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DeterministicV4HDR10PlusPreservationReportV4.self,
                from: missingTimelineData
            )
        )

        XCTAssertThrowsError(
            try DeterministicV4HDR10PlusPreservationReportV4(
                routeID: .canonicalDynamicAbsentOnePass,
                timelineMappingSHA256: report.timelineMappingSHA256,
                sourceLedgerSHA256: report.outputLedgerSHA256,
                outputLedgerSHA256: report.sourceLedgerSHA256,
                rewrittenSampleCount: 0,
                segmentCount: 0
            )
        )
        XCTAssertThrowsError(
            try DeterministicV4HDR10PlusPreservationReportV4(
                routeID: .canonicalDynamicAbsentOnePass,
                timelineMappingSHA256: report.timelineMappingSHA256,
                sourceLedgerSHA256: report.sourceLedgerSHA256,
                outputLedgerSHA256: report.outputLedgerSHA256,
                rewrittenSampleCount: 0,
                segmentCount: 1
            )
        )
        XCTAssertThrowsError(
            try DeterministicV4HDR10PlusPreservationReportV4.aggregate([
                report
            ])
        )
    }

    func testHDR10PlusNoMetadataLedgerIdentityIsDeterministicAndBounded()
        throws {
        let records = try [0, 1, 2].map { ordinal in
            HDR10PlusPresentationRecordV4(
                presentationTime: try HDR10PlusPresentationTimeV4(
                    CMTime(value: CMTimeValue(ordinal), timescale: 30)
                ),
                metadata: nil
            )
        }
        let forward = try HDR10PlusSegmentLedgerSnapshotV4(records)
        let reversed = try HDR10PlusSegmentLedgerSnapshotV4(
            Array(records.reversed())
        )
        XCTAssertEqual(forward, reversed)

        let leaf = try DeterministicV4HDR10PlusPreservationReportV4(
            timelineMappingSHA256: ASHSHA256V4(
                rawData: Data("no-metadata-timeline".utf8)
            ),
            sourceLedgerSHA256: forward.canonicalSHA256,
            outputLedgerSHA256: forward.canonicalSHA256,
            rewrittenSampleCount: 0
        )
        let first = try DeterministicV4HDR10PlusPreservationReportV4
            .aggregate([leaf])
        let repeatIdentity = try
            DeterministicV4HDR10PlusPreservationReportV4.aggregate([leaf])
        XCTAssertEqual(first, repeatIdentity)
        XCTAssertEqual(first.rewrittenSampleCount, 0)
        XCTAssertEqual(first.segmentCount, 1)

        let preaggregated = try
            DeterministicV4HDR10PlusPreservationReportV4(
                timelineMappingSHA256: leaf.timelineMappingSHA256,
                sourceLedgerSHA256: forward.canonicalSHA256,
                outputLedgerSHA256: forward.canonicalSHA256,
                rewrittenSampleCount: 0,
                segmentCount: 2
            )
        XCTAssertThrowsError(
            try DeterministicV4HDR10PlusPreservationReportV4.aggregate([
                preaggregated
            ])
        )
    }

    func testDurableSegmentTimelineIdentityStaysInMediaDomainWithoutDirectMapping()
        throws {
        let plan = ASHSHA256V4(rawData: Data("durable-plan".utf8))
        let primary = try MediaTrackStableIDV4("video-primary")
        let identity = try
            DeterministicV4HDR10PlusPreservationReportV4
                .durableSegmentTimelineMappingSHA256(
                    trackPlanSHA256: plan,
                    primaryTrackID: primary
                )
        XCTAssertEqual(
            identity,
            try DeterministicV4HDR10PlusPreservationReportV4
                .durableSegmentTimelineMappingSHA256(
                    trackPlanSHA256: plan,
                    primaryTrackID: primary
                )
        )
        XCTAssertNotEqual(
            identity,
            try DeterministicV4HDR10PlusPreservationReportV4
                .durableSegmentTimelineMappingSHA256(
                    trackPlanSHA256: ASHSHA256V4(
                        rawData: Data("other-durable-plan".utf8)
                    ),
                    primaryTrackID: primary
                )
        )
        XCTAssertNotEqual(
            identity,
            try DeterministicV4HDR10PlusPreservationReportV4
                .durableSegmentTimelineMappingSHA256(
                    trackPlanSHA256: plan,
                    primaryTrackID: try MediaTrackStableIDV4(
                        "video-alternate"
                    )
                )
        )
    }

    func testWriterPropertiesPreserveDynamicOnlyForUnmodifiedPixels() throws {
        let metadata = try makeFormatMetadata(transfer: .pq)
        XCTAssertThrowsError(
            try AVFoundationHDRMetadataAdapterV4
                .videoToolboxCompressionProperties(
                    for: metadata,
                    dynamicPolicy: .preserveSourceWhenPixelsAreUnmodified,
                    pixelsWereModified: true
                )
        ) { error in
            XCTAssertEqual(
                error as? HDRMetadataV4Error,
                .dynamicMetadataRequiresRegeneration
            )
        }

        let properties = try AVFoundationHDRMetadataAdapterV4
            .videoToolboxCompressionProperties(
                for: metadata,
                dynamicPolicy: .preserveSourceWhenPixelsAreUnmodified,
                pixelsWereModified: false
            )
        XCTAssertEqual(
            properties[
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String
            ] as? Bool,
            true
        )
        XCTAssertEqual(
            properties[
                kVTCompressionPropertyKey_MasteringDisplayColorVolume as String
            ] as? Data,
            metadata.staticMetadata.masteringDisplayColorVolume?.payload
        )
        XCTAssertEqual(
            AVFoundationHDRMetadataAdapterV4.avFoundationColorProperties(
                for: metadata.signal
            ),
            [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey:
                    AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        )

        let spatialProperties = try AVFoundationHDRMetadataAdapterV4
            .videoToolboxCompressionProperties(
                for: metadata,
                dynamicPolicy:
                    .preserveSourceSceneMetadataAcrossSpatialResampling,
                pixelsWereModified: true
            )
        XCTAssertEqual(
            spatialProperties[
                kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String
            ] as? Bool,
            true
        )
    }

    func testEncodedAmbientCorrectionRetainsParameterSetsAndUnknownAtoms() throws {
        let expected = try makeFormatMetadata(transfer: .pq)
        let configuration = encodedAmbientBaseConfiguration()
        let format = try encodedAmbientFormat(
            metadata: expected, configuration: configuration,
            ambient: nil
        )
        let corrected = try XCTUnwrap(
            AVFoundationHDRMetadataAdapterV4.correctingEncodedAmbientEnvironment(
                in: format, expected: expected
            )
        )
        XCTAssertEqual(try AVFoundationHDRMetadataAdapterV4.probe(
            formatDescription: corrected, decodedStorage: .p010VideoRange10Bit
        ), expected)
        let extensions = try XCTUnwrap(
            CMFormatDescriptionGetExtensions(corrected) as NSDictionary?
        )
        let atoms = try XCTUnwrap(extensions[
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ] as? NSDictionary)
        XCTAssertEqual(atoms["test"] as? Data, Data([9, 8, 7, 6]))
        let changed = try XCTUnwrap(atoms["hvcC"] as? Data)
        XCTAssertEqual(Data(changed.prefix(22)), Data(configuration.prefix(22)))
        XCTAssertEqual(changed[22], 4)
        XCTAssertEqual(
            Data(changed[23..<(23 + configuration.count - 23)]),
            Data(configuration.dropFirst(23))
        )
        XCTAssertNil(try AVFoundationHDRMetadataAdapterV4
            .correctingEncodedAmbientEnvironment(in: corrected, expected: expected))
    }

    func testEncodedAmbientCorrectionRemovesInventedDefaultAndPreservesOtherSEI()
        throws {
        let expected = try makeFormatMetadata(transfer: .hlg)
        let wrong = try AmbientViewingEnvironmentV4(
            ambientIlluminance: 3_140_000,
            ambientLight: HDRChromaticityV4(x: 15_635, y: 16_450, label: "ambient")
        )
        let retained = Data([5, 4, 1, 2, 3, 4])
        let mixed = makePrefixSEINAL(
            messages: retained + Data([148, 8]) + wrong.payload
        )
        let sourceConfiguration = ambientConfiguration(appending: [mixed])
        let source = try encodedAmbientFormat(
            metadata: expected, configuration: sourceConfiguration,
            ambient: wrong.payload
        )
        let corrected = try XCTUnwrap(
            AVFoundationHDRMetadataAdapterV4.correctingEncodedAmbientEnvironment(
                in: source, expected: expected
            )
        )
        let extensions = try XCTUnwrap(
            CMFormatDescriptionGetExtensions(corrected) as NSDictionary?
        )
        let atoms = try XCTUnwrap(extensions[
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ] as? NSDictionary)
        let ambient = try XCTUnwrap(
            expected.staticMetadata.ambientViewingEnvironment?.payload
        )
        XCTAssertEqual(atoms["hvcC"] as? Data, ambientConfiguration(appending: [
            makePrefixSEINAL(messages: retained),
            makePrefixSEINAL(messages: Data([148, 8]) + ambient)
        ]))

        let absent = HDRFormatMetadataV4(
            signal: expected.signal,
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume: expected.staticMetadata.masteringDisplayColorVolume,
                contentLightLevelInfo: expected.staticMetadata.contentLightLevelInfo,
                ambientViewingEnvironment: nil
            )
        )
        let removed = try XCTUnwrap(
            AVFoundationHDRMetadataAdapterV4.correctingEncodedAmbientEnvironment(
                in: source, expected: absent
            )
        )
        XCTAssertEqual(try AVFoundationHDRMetadataAdapterV4.probe(
            formatDescription: removed, decodedStorage: .p010VideoRange10Bit
        ), absent)
        XCTAssertNil(try AVFoundationHDRMetadataAdapterV4
            .correctingEncodedAmbientEnvironment(in: removed, expected: absent))
    }

    func testEncodedAmbientCorrectionRejectsMalformedConfigurationAndOtherHDRChanges()
        throws {
        let expected = try makeFormatMetadata(transfer: .pq)
        let configuration = encodedAmbientBaseConfiguration()
        for length in 0..<configuration.count {
            let format = try encodedAmbientFormat(
                metadata: expected,
                configuration: Data(configuration.prefix(length)), ambient: nil
            )
            XCTAssertThrowsError(try AVFoundationHDRMetadataAdapterV4
                .correctingEncodedAmbientEnvironment(in: format, expected: expected),
                "truncation \(length)")
        }
        let malformedSEI = makePrefixSEINAL(messages: Data([148, 7, 1, 2, 3, 4, 5, 6, 7]))
        let format = try encodedAmbientFormat(
            metadata: expected,
            configuration: ambientConfiguration(appending: [malformedSEI]),
            ambient: nil
        )
        XCTAssertThrowsError(try AVFoundationHDRMetadataAdapterV4
            .correctingEncodedAmbientEnvironment(in: format, expected: expected))
        let contradictory = HDRFormatMetadataV4(
            signal: expected.signal,
            staticMetadata: HDRStaticMetadataV4(
                masteringDisplayColorVolume: nil,
                contentLightLevelInfo: expected.staticMetadata.contentLightLevelInfo,
                ambientViewingEnvironment: expected.staticMetadata.ambientViewingEnvironment
            )
        )
        let otherMetadata = try encodedAmbientFormat(
            metadata: contradictory, configuration: configuration, ambient: nil
        )
        XCTAssertThrowsError(try AVFoundationHDRMetadataAdapterV4
            .correctingEncodedAmbientEnvironment(in: otherMetadata, expected: expected))
        XCTAssertThrowsError(try AVFoundationHDRMetadataAdapterV4
            .correctingEncodedAmbientEnvironment(
                in: makeFormatDescription(metadata: expected), expected: expected
            ))
    }

    private func encodedAmbientBaseConfiguration() -> Data {
        // Real Main10 VPS/SPS/PPS from the retained minimum-OS control fixture.
        let hex = "010220000000b000000000001ef000fcfdfafa00000b03a00001001840010c01ffff022000000300b0000003000003001e15c090a100010025420101022000000300b0000003000003001ea0142041c18c4b62057b916558735091009008a2000100084401c02cb8d45364"
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    private func ambientConfiguration(appending nals: [Data]) -> Data {
        var configuration = encodedAmbientBaseConfiguration()
        configuration[22] = 4
        configuration.append(0xA7)
        configuration.append(UInt8(nals.count >> 8))
        configuration.append(UInt8(nals.count & 255))
        for nal in nals {
            configuration.append(UInt8(nal.count >> 8))
            configuration.append(UInt8(nal.count & 255))
            configuration.append(nal)
        }
        return configuration
    }

    private func encodedAmbientFormat(
        metadata: HDRFormatMetadataV4, configuration: Data, ambient: Data?
    ) throws -> CMFormatDescription {
        var extensions = AVFoundationHDRMetadataAdapterV4
            .formatDescriptionExtensions(for: metadata)
        extensions[kCMFormatDescriptionExtension_AmbientViewingEnvironment] = ambient
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [
            "hvcC": configuration, "test": Data([9, 8, 7, 6])
        ]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
            width: 64, height: 48, extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }

    private func makeFormatMetadata(
        transfer: HDRTransferFunctionV4
    ) throws -> HDRFormatMetadataV4 {
        HDRFormatMetadataV4(
            signal: try HDRSignalV4(
                storage: .p010VideoRange10Bit,
                transferFunction: transfer
            ),
            staticMetadata: try makeStaticMetadata()
        )
    }

    private func time(_ value: Int64, epoch: Int64 = 0) -> CMTime {
        CMTime(
            value: value,
            timescale: 30,
            flags: .valid,
            epoch: epoch
        )
    }

    private func assertDecodedDurationRejected(
        currentDecodeTime: CMTime,
        followingDecodeTime: CMTime?,
        currentPresentationTime: CMTime,
        terminalReaderReportedDuration: CMTime? = nil,
        expectedSite: DeterministicV4InvalidSampleTimingSite,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DeterministicV4MediaProcessingSession
                .authoritativeDecodedDuration(
                    currentDecodeTime: currentDecodeTime,
                    followingDecodeTime: followingDecodeTime,
                    currentPresentationTime: currentPresentationTime,
                    terminalReaderReportedDuration:
                        terminalReaderReportedDuration
                ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DeterministicV4MediaSegmentError,
                .invalidSampleTiming(site: expectedSite),
                file: file,
                line: line
            )
        }
    }

    private func makeStaticMetadata() throws -> HDRStaticMetadataV4 {
        let primaries = [
            try HDRChromaticityV4(x: 8_500, y: 39_850, label: "green"),
            try HDRChromaticityV4(x: 6_550, y: 2_300, label: "blue"),
            try HDRChromaticityV4(x: 35_400, y: 14_600, label: "red")
        ]
        return HDRStaticMetadataV4(
            masteringDisplayColorVolume: try MasteringDisplayColorVolumeV4(
                displayPrimaries: primaries,
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

    private func makeDynamicMetadata(
        version: Int
    ) throws -> HDRDynamicMetadataV4 {
        HDRDynamicMetadataV4(
            hdr10Plus: try HDR10PlusMetadataV4(
                ituTT35Payload: Data([
                    0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01, 0x40,
                    0x00, 0x0C, 0x80, 0x3C, 0xB0, 0x19, 0xBD, 0x0D,
                    0x80, 0x00, 0x41, 0xE4, 0x08, 0x00, 0x00, 0x28,
                    0x5F, 0x00, 0x50, 0x01, 0x70, 0xC8, 0x00, 0x05,
                    0x90, 0x00, 0x12, 0x58, 0x01, 0xAE, 0xD0, 0x0B,
                    0x5A, 0xF8, 0x1B, 0xE3, 0x18, 0x5B, 0x4C, 0x00,
                    0x42, 0x90, 0x3C, 0x24, 0x8F, 0x4A, 0x9B, 0xF9,
                    0x42, 0xDB, 0xD8, 0x37, 0xBE, 0x57, 0xAA, 0x00
                ])
            ),
            postDecodeProcessing: try PostDecodeProcessingMetadataV4(
                propertyList: NSDictionary(dictionary: [
                    "Profile": "Test",
                    "Version": version,
                    "Flags": [true, false]
                ])
            )
        )
    }

    private func makeFormatDescription(
        metadata: HDRFormatMetadataV4
    ) throws -> CMVideoFormatDescription {
        try makeFormatDescription(
            extensions: AVFoundationHDRMetadataAdapterV4
                .formatDescriptionExtensions(for: metadata)
        )
    }

    private func makeFormatDescription(
        extensions: [CFString: Any]
    ) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            width: 4,
            height: 4,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attributes,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func makeSampleBuffer(
        imageBuffer: CVPixelBuffer
    ) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: imageBuffer,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func lengthPrefixed(_ nal: Data) -> Data {
        var size = UInt32(nal.count).bigEndian
        var result = Data(bytes: &size, count: MemoryLayout<UInt32>.size)
        result.append(nal)
        return result
    }

    private func makePrefixSEINAL(messages: Data) -> Data {
        var rbsp = messages
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
}
