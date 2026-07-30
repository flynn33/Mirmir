import AVFoundation
import CoreMedia
import XCTest
@testable import Mirmir

final class FrameTimingLedgerTests: XCTestCase {
    func testProductionSessionAssetRequestsPreciseTiming() {
        XCTAssertEqual(
            AVFoundationSourceAssetFactory.options[
                AVURLAssetPreferPreciseDurationAndTimingKey
            ] as? Bool,
            true
        )
    }

    func testSessionPreflightRejectsNegativeVideoAndAudioTimelines() {
        for (mediaType, expectedIdentifier) in [
            (AVMediaType.video, "video"),
            (.audio, "audio")
        ] {
            XCTAssertThrowsError(
                try AVFoundationSourceTimelinePreflight.validate(
                    CMTimeRange(
                        start: CMTime(value: -1, timescale: 30),
                        duration: CMTime(value: 2, timescale: 30)
                    ),
                    mediaType: mediaType
                )
            ) { error in
                guard case let MediaPipelineError
                    .unsupportedNegativeSourceTimeline(
                        actualMediaType,
                        start,
                        end
                    ) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(actualMediaType, expectedIdentifier)
                XCTAssertEqual(
                    CMTimeCompare(
                        start,
                        CMTime(value: -1, timescale: 30)
                    ),
                    0
                )
                XCTAssertEqual(
                    CMTimeCompare(
                        end,
                        CMTime(value: 1, timescale: 30)
                    ),
                    0
                )
            }
        }
    }

    func testSessionPreflightAcceptsZeroAndPositiveTimelineStarts()
        throws {
        for start in [
            CMTime.zero,
            CMTime(value: 1, timescale: 30)
        ] {
            XCTAssertNoThrow(
                try AVFoundationSourceTimelinePreflight.validate(
                    CMTimeRange(
                        start: start,
                        duration: CMTime(value: 1, timescale: 30)
                    ),
                    mediaType: .video
                )
            )
        }
    }

    func testWriterTimeScalePreservesActualEditBoundaryExactly() throws {
        let trackTimeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(value: 31_884_353, timescale: 90_000)
        )

        let timeScale = try ExactVideoWriterTimeScale.resolve(
            naturalTimeScale: 24_000,
            trackTimeRange: trackTimeRange
        )

        XCTAssertEqual(timeScale, 360_000)
        let end = CMTimeRangeGetEnd(trackTimeRange)
        XCTAssertEqual(
            CMTimeCompare(
                CMTimeConvertScale(
                    end,
                    timescale: timeScale,
                    method: .default
                ),
                end
            ),
            0
        )
    }

    func testWriterTimeScaleUsesReducedBoundaryDenominator() throws {
        let timeScale = try ExactVideoWriterTimeScale.resolve(
            naturalTimeScale: 30,
            trackTimeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(value: 2, timescale: 6)
            )
        )

        XCTAssertEqual(timeScale, 30)
    }

    func testWriterTimeScaleRejectsUnrepresentableLCM() {
        XCTAssertThrowsError(
            try ExactVideoWriterTimeScale.resolve(
                naturalTimeScale: .max,
                trackTimeRange: CMTimeRange(
                    start: .zero,
                    duration: CMTime(value: 1, timescale: 2)
                )
            )
        ) { error in
            guard case MediaPipelineError.unrepresentableVideoTimeline =
                error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMovieTimeScaleUsesOnlyExactEditBoundaries()
        throws {
        let timeRanges = [
            CMTimeRange(
                start: CMTime(value: 1, timescale: 30),
                duration: CMTime(value: 31, timescale: 30)
            ),
            CMTimeRange(
                start: .zero,
                duration: CMTime(value: 2, timescale: 3)
            )
        ]

        let timeScale = try ExactVideoWriterTimeScale
            .commonBoundaryScale(timeRanges)

        XCTAssertEqual(timeScale, 30)
        for boundary in timeRanges.flatMap({
            [$0.start, CMTimeRangeGetEnd($0)]
        }) {
            XCTAssertEqual(
                CMTimeCompare(
                    CMTimeConvertScale(
                        boundary,
                        timescale: timeScale,
                        method: .default
                    ),
                    boundary
                ),
                0
            )
        }
    }

    func testMovieTimeScaleDoesNotRequireTrackTimescaleLCM()
        throws {
        XCTAssertThrowsError(
            try ExactVideoWriterTimeScale.commonScale([
                CMTimeScale.max,
                CMTimeScale.max - 18
            ])
        )

        XCTAssertEqual(
            try ExactVideoWriterTimeScale.commonBoundaryScale([
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(value: 1, timescale: 1)
                ),
                CMTimeRange(
                    start: .zero,
                    duration: CMTime(value: 2, timescale: 1)
                )
            ]),
            1
        )
    }

    func testLedgerRecordsExactCountOrderAndDurationEndpoint() throws {
        let frameDuration = CMTime(value: 1, timescale: 30)
        var ledger = FrameTimingLedger()
        try ledger.append(FrameTiming(
            frameIndex: 0,
            presentationTime: .zero,
            duration: frameDuration
        ))
        try ledger.append(FrameTiming(
            frameIndex: 1,
            presentationTime: frameDuration,
            duration: frameDuration
        ))

        XCTAssertEqual(ledger.snapshot.frameCount, 2)
        XCTAssertEqual(
            CMTimeCompare(ledger.snapshot.sessionEndTime ?? .invalid, CMTime(value: 2, timescale: 30)),
            0
        )
        XCTAssertEqual(
            CMTimeCompare(ledger.snapshot.duration ?? .invalid, CMTime(value: 2, timescale: 30)),
            0
        )
    }

    func testLedgerRejectsIndexGapWithoutMutatingCount() throws {
        var ledger = FrameTimingLedger()

        XCTAssertThrowsError(try ledger.append(FrameTiming(
            frameIndex: 1,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 30)
        ))) { error in
            XCTAssertEqual(
                error as? FrameTimingLedgerError,
                .unexpectedFrameIndex(expected: 0, actual: 1)
            )
        }
        XCTAssertEqual(ledger.snapshot.frameCount, 0)
    }

    func testLedgerRejectsNonMonotonicPTSAndInvalidDuration() throws {
        let frameDuration = CMTime(value: 1, timescale: 30)
        var ledger = FrameTimingLedger()
        try ledger.append(FrameTiming(
            frameIndex: 0,
            presentationTime: .zero,
            duration: frameDuration
        ))

        XCTAssertThrowsError(try ledger.append(FrameTiming(
            frameIndex: 1,
            presentationTime: .zero,
            duration: frameDuration
        ))) { error in
            XCTAssertEqual(
                error as? FrameTimingLedgerError,
                .nonMonotonicPresentationTime(previousFrameIndex: 0, frameIndex: 1)
            )
        }
        XCTAssertThrowsError(try ledger.append(FrameTiming(
            frameIndex: 1,
            presentationTime: frameDuration,
            duration: .zero
        ))) { error in
            XCTAssertEqual(
                error as? FrameTimingLedgerError,
                .invalidDuration(frameIndex: 1)
            )
        }
        XCTAssertEqual(ledger.snapshot.frameCount, 1)
    }

    func testLedgerValidatesBeforeOperationAndCommitsOnlyAfterSuccess() throws {
        enum InjectedFailure: Error {
            case operation
        }

        let frameDuration = CMTime(value: 1, timescale: 30)
        var ledger = FrameTimingLedger()
        var invalidOperationRan = false
        XCTAssertThrowsError(try ledger.append(
            FrameTiming(
                frameIndex: 1,
                presentationTime: .zero,
                duration: frameDuration
            ),
            afterValidation: {
                invalidOperationRan = true
            }
        ))
        XCTAssertFalse(invalidOperationRan)
        XCTAssertEqual(ledger.snapshot.frameCount, 0)

        XCTAssertThrowsError(try ledger.append(
            FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: frameDuration
            ),
            afterValidation: {
                throw InjectedFailure.operation
            }
        )) { error in
            XCTAssertTrue(error is InjectedFailure)
        }
        XCTAssertEqual(ledger.snapshot.frameCount, 0)

        try ledger.append(
            FrameTiming(
                frameIndex: 0,
                presentationTime: .zero,
                duration: frameDuration
            ),
            afterValidation: {}
        )
        XCTAssertEqual(ledger.snapshot.frameCount, 1)
    }
}
