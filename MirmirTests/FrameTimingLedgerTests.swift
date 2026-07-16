import CoreMedia
import XCTest
@testable import Mirmir

final class FrameTimingLedgerTests: XCTestCase {
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
}
