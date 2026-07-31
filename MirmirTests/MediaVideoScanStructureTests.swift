import CoreMedia
import Foundation
import XCTest
@testable import Mirmir

final class MediaVideoScanStructureTests: XCTestCase {
    func testResolvesProgressiveAndEveryDeclaredInterlacedDetail()
        throws {
        XCTAssertEqual(
            try MediaVideoScanStructureResolver.resolve([
                try makeDescription()
            ]),
            .progressive
        )
        let fixtures: [(CFString?, MediaVideoScanStructure)] = [
            (
                kCMFormatDescriptionFieldDetail_TemporalTopFirst,
                .interlacedTopFieldFirst
            ),
            (
                kCMFormatDescriptionFieldDetail_TemporalBottomFirst,
                .interlacedBottomFieldFirst
            ),
            (
                kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly,
                .interlacedSpatialFirstLineEarly
            ),
            (
                kCMFormatDescriptionFieldDetail_SpatialFirstLineLate,
                .interlacedSpatialFirstLineLate
            ),
            (nil, .interlacedUnspecified)
        ]
        for (detail, expected) in fixtures {
            let resolved = try MediaVideoScanStructureResolver.resolve([
                try makeDescription(
                    fieldCount: 2,
                    fieldDetail: detail
                )
            ])
            XCTAssertEqual(resolved, expected)
            XCTAssertTrue(resolved.requiresDeinterlacing)
        }
        XCTAssertFalse(
            MediaVideoScanStructure.progressive
                .requiresDeinterlacing
        )
    }

    func testRejectsContradictoryOrUnknownFieldIdentity() throws {
        XCTAssertThrowsError(
            try MediaVideoScanStructureResolver.resolve([
                try makeDescription(
                    fieldCount: 1,
                    fieldDetail:
                        kCMFormatDescriptionFieldDetail_TemporalTopFirst
                )
            ])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "progressive video declares interlaced field detail"
                )
            )
        }
        XCTAssertThrowsError(
            try MediaVideoScanStructureResolver.resolve([
                try makeDescription(fieldCount: 3)
            ])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "field count must be 1 or 2"
                )
            )
        }
        XCTAssertThrowsError(
            try MediaVideoScanStructureResolver.resolve([
                try makeDescription(
                    fieldCount: 2,
                    fieldDetail: "UnsupportedFieldDetail" as CFString
                )
            ])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "unsupported interlaced field detail"
                )
            )
        }
    }

    func testRejectsScanChangesWithinOneTrack() throws {
        XCTAssertThrowsError(
            try MediaVideoScanStructureResolver.resolve([
                try makeDescription(),
                try makeDescription(
                    fieldCount: 2,
                    fieldDetail:
                        kCMFormatDescriptionFieldDetail_TemporalTopFirst
                )
            ])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "changes scan structure within one track"
                )
            )
        }
    }

    func testRejectsMissingFormatDescriptions() {
        XCTAssertThrowsError(
            try MediaVideoScanStructureResolver.resolve([])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "no format description"
                )
            )
        }
    }

    func testEveryIdentityHasStablePersistenceAndDisplayText()
        throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for structure in MediaVideoScanStructure.allCases {
            let data = try encoder.encode(structure)
            XCTAssertEqual(
                try decoder.decode(
                    MediaVideoScanStructure.self,
                    from: data
                ),
                structure
            )
            XCTAssertFalse(structure.displayName.isEmpty)
            XCTAssertEqual(
                structure.requiresDeinterlacing,
                structure != .progressive
            )
        }
    }

    func testSourceProfileDefaultsToProgressiveAndRebindingPreservesScan()
        throws {
        let original = try SourceProfile(
            url: URL(fileURLWithPath: "/tmp/interlaced-source.mov"),
            resolution: VideoResolution(width: 16, height: 16),
            codedResolution: VideoResolution(width: 16, height: 16),
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "apcn",
            audioTrackCount: 0,
            scanStructure: .interlacedBottomFieldFirst
        )

        let rebound = try original.bindingSourceURL(
            URL(fileURLWithPath: "/tmp/staged-interlaced-source.mov")
        )

        XCTAssertEqual(
            rebound.scanStructure,
            .interlacedBottomFieldFirst
        )
        XCTAssertEqual(rebound.codedResolution, original.codedResolution)
        XCTAssertEqual(
            rebound.url.lastPathComponent,
            "staged-interlaced-source.mov"
        )

        let progressive = SourceProfile(
            url: URL(fileURLWithPath: "/tmp/progressive-source.mov"),
            resolution: VideoResolution(width: 16, height: 16),
            frameRate: 30,
            durationSeconds: 1,
            estimatedFrameCount: 30,
            codecHint: "apcn",
            hasAudio: false
        )
        XCTAssertEqual(progressive.scanStructure, .progressive)
    }
}

private extension MediaVideoScanStructureTests {
    func makeDescription(
        fieldCount: Int? = nil,
        fieldDetail: CFString? = nil
    ) throws -> CMVideoFormatDescription {
        var extensions: [CFString: Any] = [:]
        if let fieldCount {
            extensions[
                kCMFormatDescriptionExtension_FieldCount
            ] = NSNumber(value: fieldCount)
        }
        if let fieldDetail {
            extensions[
                kCMFormatDescriptionExtension_FieldDetail
            ] = fieldDetail
        }
        var optionalDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AppleProRes422,
            width: 16,
            height: 16,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &optionalDescription
        )
        guard status == noErr, let optionalDescription else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status)
            )
        }
        return optionalDescription
    }
}
