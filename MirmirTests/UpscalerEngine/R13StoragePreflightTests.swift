import Foundation
import XCTest
@testable import Mirmir

final class R13StoragePreflightTests: XCTestCase {
    func testCanonicalRawCacheDisclosuresAreExact() throws {
        let p1080 = R13StorageDisclosures.p1080At30FPSForOneMinute
        let p2160 = R13StorageDisclosures.p2160At30FPSForOneMinute

        XCTAssertEqual(p1080.rawNV12ByteCount, 5_598_720_000)
        XCTAssertEqual(p2160.rawNV12ByteCount, 22_394_880_000)
        XCTAssertEqual(
            try R13StorageDisclosures.canonicalOneMinute(
                width: 1_920,
                height: 1_080
            ),
            p1080
        )
        XCTAssertEqual(
            try R13StorageDisclosures.canonicalOneMinute(
                width: 3_840,
                height: 2_160
            ),
            p2160
        )
        XCTAssertEqual(
            p1080.binaryGiB,
            5.214_214_324_951_172,
            accuracy: 0.000_000_01
        )
        XCTAssertEqual(
            p2160.binaryGiB,
            20.856_857_299_804_688,
            accuracy: 0.000_000_01
        )
    }

    func testPreflightIncludesRawFallbackOutputMetadataAndReserve() throws {
        let request = try R13StoragePreflightRequest(
            outputWidth: 1_920,
            outputHeight: 1_080,
            totalFrameCount: 30,
            expectedFinalOutputBytes: 10_000_000,
            additionalReserveBytes: 1_000_000
        )
        let preflight = R13StoragePreflight(
            capacityProbe: R13FixedCapacityProbe(capacity: UInt64.max)
        )

        let receipt = try preflight.evaluate(
            request,
            at: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(receipt.rawCacheBytes, 93_312_000)
        XCTAssertGreaterThan(
            receipt.worstCaseCacheArtifactBytes,
            receipt.rawCacheBytes
        )
        XCTAssertEqual(receipt.expectedFinalOutputBytes, 10_000_000)
        XCTAssertEqual(receipt.additionalReserveBytes, 1_000_000)
        XCTAssertEqual(
            receipt.requiredBytes,
            receipt.worstCaseCacheArtifactBytes
                + receipt.recordAndManifestBytes
                + receipt.expectedFinalOutputBytes
                + receipt.additionalReserveBytes
        )
    }

    func testInsufficientCapacityFailsWithExactRequiredAndAvailableBytes() throws {
        let request = try R13StoragePreflightRequest(
            outputWidth: 4,
            outputHeight: 2,
            totalFrameCount: 1,
            expectedFinalOutputBytes: 100,
            additionalReserveBytes: 50
        )
        let preflight = R13StoragePreflight(
            capacityProbe: R13FixedCapacityProbe(capacity: 1)
        )

        XCTAssertThrowsError(
            try preflight.evaluate(
                request,
                at: URL(fileURLWithPath: "/tmp")
            )
        ) { error in
            guard case .insufficientDiskSpace(
                let requiredBytes,
                let availableBytes
            ) = error as? R13RestartJobError else {
                return XCTFail("Expected the typed disk-space failure.")
            }
            XCTAssertGreaterThan(requiredBytes, 1)
            XCTAssertEqual(availableBytes, 1)
        }
    }

    func testPreflightArithmeticOverflowFailsClosed() throws {
        let request = try R13StoragePreflightRequest(
            outputWidth: 3_840,
            outputHeight: 2_160,
            totalFrameCount: Int.max,
            expectedFinalOutputBytes: 1,
            additionalReserveBytes: 0
        )
        let preflight = R13StoragePreflight(
            capacityProbe: R13FixedCapacityProbe(capacity: UInt64.max)
        )

        XCTAssertThrowsError(
            try preflight.evaluate(
                request,
                at: URL(fileURLWithPath: "/tmp")
            )
        ) { error in
            XCTAssertEqual(
                error as? R13RestartJobError,
                .arithmeticOverflow(
                    field: "raw_cache_bytes"
                )
            )
        }
    }
}

private struct R13FixedCapacityProbe: R13AvailableCapacityProbing {
    let capacity: UInt64

    func availableCapacityForImportantUsage(at url: URL) throws -> UInt64 {
        capacity
    }
}
