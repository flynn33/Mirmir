import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import Mirmir

final class RationalPresentationGeometryV4Tests: XCTestCase {
    func testMediaClockPolicyAcceptsFerrisUpperAdjacent90kTick()
        throws {
        let observedLastStart = try ExactRationalV4(
            556_211_906,
            90_000
        )
        let nominalDuration = try ExactRationalV4(1_001, 24_000)
        let exactObservedEnd = try observedLastStart.adding(nominalDuration)
        let conversion = try MediaClockConversionPolicyV4
            .exactOrAdmittedAdjacent(
                exactObservedEnd,
                admittedBoundary: CMTime(
                    value: 556_215_660,
                    timescale: 90_000
                ),
                timescale: 90_000
            )

        XCTAssertEqual(conversion.time.value, 556_215_660)
        XCTAssertEqual(conversion.time.timescale, 90_000)
        XCTAssertEqual(conversion.quantization, .admittedCeiling)
    }

    func testMediaClockPolicyPreservesExactFerrisLastFrameStartAndEnd()
        throws {
        let nominalDuration = try ExactRationalV4(1_001, 24_000)
        let exactLastStart = try nominalDuration.multiplied(
            by: ExactRationalV4(148_175)
        )
        XCTAssertEqual(
            exactLastStart,
            try ExactRationalV4(5_932_927, 960)
        )
        let exactEnd = try exactLastStart.adding(nominalDuration)
        let conversion = try MediaClockConversionPolicyV4
            .exactOrAdmittedAdjacent(
                exactEnd,
                admittedBoundary: CMTime(
                    value: 556_215_660,
                    timescale: 90_000
                ),
                timescale: 90_000
            )

        XCTAssertEqual(conversion.time.value, 556_215_660)
        XCTAssertEqual(conversion.quantization, .exact)
    }

    func testRavenForgeSite057ExactRepresentableEndIgnoresDistinctContainerBoundary()
        async throws {
        let sourceURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "raven-forge-site057-video-timing",
            withExtension: "mp4"
        ))
        let asset = AVURLAsset(
            url: sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let trackRange = try await track.load(.timeRange)
        let admittedContainerEnd = CMTimeRangeGetEnd(trackRange)
        let nominalFrameDuration = try await track.load(.minFrameDuration)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA)
            ]
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var decodedSampleCount = 0
        var firstPresentationTime = CMTime.invalid
        var lastPresentationTime = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            decodedSampleCount += count
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            if !firstPresentationTime.isNumeric {
                firstPresentationTime = presentation
            }
            if !lastPresentationTime.isNumeric ||
                CMTimeCompare(presentation, lastPresentationTime) > 0 {
                lastPresentationTime = presentation
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertNil(reader.error)
        XCTAssertEqual(decodedSampleCount, 241)
        XCTAssertEqual(firstPresentationTime.value, 0)
        XCTAssertEqual(firstPresentationTime.timescale, 12_288)
        XCTAssertEqual(lastPresentationTime.value, 122_880)
        XCTAssertEqual(lastPresentationTime.timescale, 12_288)
        XCTAssertEqual(nominalFrameDuration.value, 512)
        XCTAssertEqual(nominalFrameDuration.timescale, 12_288)

        let exactNominalEnd = CMTimeAdd(
            firstPresentationTime,
            CMTimeMultiply(
                nominalFrameDuration,
                multiplier: Int32(decodedSampleCount)
            )
        )
        XCTAssertEqual(exactNominalEnd.value, 123_392)
        XCTAssertEqual(exactNominalEnd.timescale, 12_288)
        XCTAssertEqual(admittedContainerEnd.value, 123_396)
        XCTAssertEqual(admittedContainerEnd.timescale, 12_288)
        XCTAssertEqual(
            CMTimeSubtract(admittedContainerEnd, exactNominalEnd).value,
            4
        )

        let workflowEnd = try DeterministicV4MediaProcessingSession.workflowTime(
                exact: exactNominalEnd,
                admittedBoundary: admittedContainerEnd,
                timescale: 12_288
            )

        XCTAssertEqual(workflowEnd.value, 123_392)
        XCTAssertEqual(workflowEnd.timescale, 12_288)
    }

    func testMediaClockPolicyRejectsNonAdjacentAndMissingFrameBoundaries()
        throws {
        let inexact = try ExactRationalV4(
            2_224_862_639,
            360_000
        )
        XCTAssertThrowsError(
            try MediaClockConversionPolicyV4.exactOrAdmittedAdjacent(
                inexact,
                admittedBoundary: CMTime(
                    value: 556_215_662,
                    timescale: 90_000
                ),
                timescale: 90_000
            )
        ) {
            XCTAssertEqual(
                $0 as? MediaClockConversionV4Error,
                .admittedBoundaryNotAdjacent
            )
        }

        let missingFrameEnd = try ExactRationalV4(1_001, 24_000)
            .multiplied(by: ExactRationalV4(148_175))
        XCTAssertThrowsError(
            try MediaClockConversionPolicyV4.exactOrAdmittedAdjacent(
                missingFrameEnd,
                admittedBoundary: CMTime(
                    value: 556_215_660,
                    timescale: 90_000
                ),
                timescale: 90_000
            )
        ) {
            XCTAssertEqual(
                $0 as? MediaClockConversionV4Error,
                .admittedBoundaryNotAdjacent
            )
        }
    }

    func testRationalNormalizationAndCheckedArithmeticAreExact() throws {
        XCTAssertEqual(try ExactRationalV4(16, 18), try ExactRationalV4(8, 9))
        XCTAssertEqual(try ExactRationalV4(1, -2), try ExactRationalV4(-1, 2))
        XCTAssertEqual(
            try ExactRationalV4(Int64.min, Int64.min),
            .one
        )
        XCTAssertEqual(
            try ExactRationalV4(1, 3).adding(ExactRationalV4(1, 6)),
            try ExactRationalV4(1, 2)
        )
        XCTAssertEqual(
            try ExactRationalV4(3, 7).multiplied(by: ExactRationalV4(14, 9)),
            try ExactRationalV4(2, 3)
        )
        XCTAssertEqual(
            try ExactRationalV4(4, 9).divided(by: ExactRationalV4(2, 3)),
            try ExactRationalV4(2, 3)
        )

        XCTAssertThrowsError(try ExactRationalV4(1, 0))
        XCTAssertThrowsError(try ExactRationalV4(1, Int64.min))
        XCTAssertThrowsError(try ExactRationalV4(Int64.max).adding(.one))
        XCTAssertThrowsError(try ExactRationalV4(1).divided(by: .zero))
    }

    func testRationalComparableAndCodablePreserveCanonicalForm() throws {
        let negative = try ExactRationalV4(Int64.min, Int64.max)
        let positive = try ExactRationalV4(Int64.max, Int64.max - 1)
        XCTAssertLessThan(negative, .zero)
        XCTAssertLessThan(.zero, positive)
        XCTAssertLessThan(
            try ExactRationalV4(Int64.max - 1, Int64.max),
            try ExactRationalV4(Int64.max, Int64.max - 1)
        )

        let canonical = try ExactRationalV4(-16, -18)
        let encoded = try JSONEncoder().encode(canonical)
        XCTAssertEqual(
            try JSONDecoder().decode(ExactRationalV4.self, from: encoded),
            try ExactRationalV4(8, 9)
        )

        let nonCanonical = Data(#"{"numerator":16,"denominator":18}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ExactRationalV4.self, from: nonCanonical),
            try ExactRationalV4(8, 9)
        )
        let invalid = Data(#"{"numerator":1,"denominator":0}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(ExactRationalV4.self, from: invalid)
        )
    }

    func testFullApertureAndReducedSampleAspectRatioProduceExactBounds() throws {
        let sar = try SampleAspectRatioV4(
            horizontalSpacing: 16,
            verticalSpacing: 18
        )
        XCTAssertEqual(sar.horizontalSpacing, 8)
        XCTAssertEqual(sar.verticalSpacing, 9)

        let geometry = try RationalPresentationGeometryV4(
            codedWidth: 720,
            codedHeight: 480,
            cleanAperture: CleanApertureV4.fullRaster(width: 720, height: 480),
            sampleAspectRatio: sar
        )
        let bounds = try geometry.presentationBounds()
        XCTAssertEqual(bounds.origin, RationalPointV4(x: .zero, y: .zero))
        XCTAssertEqual(bounds.size.width, try ExactRationalV4(640))
        XCTAssertEqual(bounds.size.height, try ExactRationalV4(480))
    }

    func testCompositionOrderIsCropThenSARThenPreferredTransform() throws {
        let aperture = try CleanApertureV4(
            width: ExactRationalV4(704),
            height: ExactRationalV4(464),
            horizontalOffset: ExactRationalV4(4),
            verticalOffset: ExactRationalV4(-3)
        )
        let preferred = RationalAffineTransformV4.quarterTurn(
            1,
            translationX: 480
        )
        let geometry = try RationalPresentationGeometryV4(
            codedWidth: 720,
            codedHeight: 480,
            cleanAperture: aperture,
            sampleAspectRatio: SampleAspectRatioV4(
                horizontalSpacing: 10,
                verticalSpacing: 11
            ),
            preferredTransform: preferred
        )

        let apertureRect = try geometry.cleanApertureRect()
        XCTAssertEqual(apertureRect.origin.x, try ExactRationalV4(12))
        XCTAssertEqual(apertureRect.origin.y, try ExactRationalV4(5))

        let transform = try geometry.composedTransform()
        XCTAssertEqual(
            try transform.applying(to: apertureRect.origin),
            RationalPointV4(x: try ExactRationalV4(480), y: .zero)
        )

        let bounds = try geometry.presentationBounds()
        XCTAssertEqual(
            bounds.origin,
            RationalPointV4(x: try ExactRationalV4(16), y: .zero)
        )
        XCTAssertEqual(bounds.size.width, try ExactRationalV4(464))
        XCTAssertEqual(bounds.size.height, try ExactRationalV4(640))
    }

    func testFractionalCleanApertureNeverPassesThroughFloatingPoint() throws {
        let geometry = try RationalPresentationGeometryV4(
            codedWidth: 1_920,
            codedHeight: 1_080,
            cleanAperture: CleanApertureV4(
                width: ExactRationalV4(3_777, 2),
                height: ExactRationalV4(1_079),
                horizontalOffset: ExactRationalV4(-1, 4),
                verticalOffset: ExactRationalV4(1, 2)
            )
        )
        let rect = try geometry.cleanApertureRect()
        XCTAssertEqual(rect.origin.x, try ExactRationalV4(31, 2))
        XCTAssertEqual(rect.origin.y, .one)
        XCTAssertEqual(rect.size.width, try ExactRationalV4(3_777, 2))
        XCTAssertEqual(rect.size.height, try ExactRationalV4(1_079))
    }

    func testMirrorIsAcceptedButShearAndFractionalTranslationFailClosed() throws {
        let aperture = try CleanApertureV4.fullRaster(width: 640, height: 480)
        let mirror = RationalAffineTransformV4(
            a: .negativeOne,
            b: .zero,
            c: .zero,
            d: .one,
            tx: try ExactRationalV4(640),
            ty: .zero
        )
        XCTAssertNoThrow(
            try RationalPresentationGeometryV4(
                codedWidth: 640,
                codedHeight: 480,
                cleanAperture: aperture,
                preferredTransform: mirror
            )
        )

        let shear = RationalAffineTransformV4(
            a: .one,
            b: .zero,
            c: try ExactRationalV4(1, 2),
            d: .one,
            tx: .zero,
            ty: .zero
        )
        XCTAssertThrowsError(
            try RationalPresentationGeometryV4(
                codedWidth: 640,
                codedHeight: 480,
                cleanAperture: aperture,
                preferredTransform: shear
            )
        ) { error in
            XCTAssertEqual(
                error as? RationalPresentationGeometryV4Error,
                .unsupportedPreferredLinearTransform
            )
        }

        let fractionalTranslation = RationalAffineTransformV4(
            a: .one,
            b: .zero,
            c: .zero,
            d: .one,
            tx: try ExactRationalV4(1, 2),
            ty: .zero
        )
        XCTAssertThrowsError(
            try RationalPresentationGeometryV4(
                codedWidth: 640,
                codedHeight: 480,
                cleanAperture: aperture,
                preferredTransform: fractionalTranslation
            )
        ) { error in
            XCTAssertEqual(
                error as? RationalPresentationGeometryV4Error,
                .fractionalPreferredTranslation
            )
        }
    }

    func testInvalidApertureSARScaleAndCompositionOverflowAreRejected() throws {
        XCTAssertThrowsError(
            try SampleAspectRatioV4(horizontalSpacing: 0, verticalSpacing: 1)
        )
        XCTAssertThrowsError(
            try CleanApertureV4(
                width: .zero,
                height: .one
            )
        )
        let unitAperture = try CleanApertureV4(
            width: .one,
            height: .one
        )
        XCTAssertThrowsError(
            try unitAperture.rect(codedWidth: -1, codedHeight: 1)
        )
        XCTAssertThrowsError(
            try RationalPresentationGeometryV4(
                codedWidth: 100,
                codedHeight: 100,
                cleanAperture: CleanApertureV4(
                    width: ExactRationalV4(101),
                    height: ExactRationalV4(100)
                )
            )
        )

        let overflowTransform = RationalAffineTransformV4(
            a: .negativeOne,
            b: .zero,
            c: .zero,
            d: .one,
            tx: try ExactRationalV4(Int64.max),
            ty: .zero
        )
        let overflowGeometry = try RationalPresentationGeometryV4(
            codedWidth: 3,
            codedHeight: 1,
            cleanAperture: CleanApertureV4(
                width: .one,
                height: .one
            ),
            preferredTransform: overflowTransform
        )
        XCTAssertThrowsError(try overflowGeometry.composedTransform()) {
            error in
            XCTAssertEqual(
                error as? RationalPresentationGeometryV4Error,
                .arithmeticOverflow
            )
        }

        let validGeometry = try RationalPresentationGeometryV4(
            codedWidth: 1,
            codedHeight: 1,
            cleanAperture: CleanApertureV4.fullRaster(width: 1, height: 1)
        )
        XCTAssertThrowsError(
            try validGeometry.composedTransform(outputScaleX: .zero)
        )
    }
}
