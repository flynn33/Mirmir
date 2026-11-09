import AVFoundation
import Foundation
import XCTest
@testable import Mirmir

final class MOVStructuralCreationDatesV4Tests: XCTestCase {
    private let knownCreation: UInt64 = 3_660_779_045 // 2020-01-02T03:04:05Z
    private let knownModification: UInt64 = 3_660_779_100

    func testCaptureReturnsNilForRIFFAVI() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "avi"
        ))
        XCTAssertNil(try MOVStructuralCreationDatesV4.capture(from: url))
    }

    func testRestoreAndVerifyRoundTripPreservesZeroAndNonZeroDates() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "mov"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("source.mov")
        try FileManager.default.copyItem(at: source, to: copy)

        let baseline = try XCTUnwrap(try MOVStructuralCreationDatesV4.capture(from: copy))
        XCTAssertEqual(baseline.movie.creation, 0)
        XCTAssertEqual(baseline.tracks.count, 2)

        let owned = MOVStructuralCreationDatesV4.Snapshot(
            movie: .init(creation: knownCreation, modification: knownModification),
            tracks: baseline.tracks.enumerated().map { index, _ in
                .init(
                    trackHeader: .init(
                        creation: knownCreation &+ UInt64(index + 1),
                        modification: knownModification &+ UInt64(index + 1)
                    ),
                    mediaHeader: .init(
                        creation: knownCreation &+ UInt64(10 + index),
                        modification: knownModification &+ UInt64(10 + index)
                    )
                )
            }
        )
        let mapping = Dictionary(uniqueKeysWithValues: owned.tracks.indices.map { ($0, $0) })
        try MOVStructuralCreationDatesV4.restore(owned, into: copy, outputToSourceTrack: mapping)
        try MOVStructuralCreationDatesV4.verify(owned, in: copy, outputToSourceTrack: mapping)

        // Simulate AVFoundation export-time rewrite by zeroing, then restore again.
        try MOVStructuralCreationDatesV4.restore(
            MOVStructuralCreationDatesV4.Snapshot(
                movie: .init(creation: 0, modification: 0),
                tracks: owned.tracks.map { _ in
                    .init(
                        trackHeader: .init(creation: 0, modification: 0),
                        mediaHeader: .init(creation: 0, modification: 0)
                    )
                }
            ),
            into: copy,
            outputToSourceTrack: mapping
        )
        XCTAssertEqual(try MOVStructuralCreationDatesV4.capture(from: copy)?.movie.creation, 0)
        try MOVStructuralCreationDatesV4.restore(owned, into: copy, outputToSourceTrack: mapping)
        try MOVStructuralCreationDatesV4.verify(owned, in: copy, outputToSourceTrack: mapping)
        XCTAssertEqual(
            MOVStructuralCreationDatesV4.foundationDate(fromQuickTimeSeconds: knownCreation),
            Date(timeIntervalSince1970: TimeInterval(knownCreation - MOVStructuralCreationDatesV4.quickTimeEpochToUnix))
        )
    }

    func testRestoreFromSourceAfterWriteHeaderPreservesDates() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "mov"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-creation-writeheader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("dated-source.mov")
        let rewrittenURL = directory.appendingPathComponent("rewritten.mov")
        try FileManager.default.copyItem(at: fixture, to: sourceURL)

        let baseline = try XCTUnwrap(try MOVStructuralCreationDatesV4.capture(from: sourceURL))
        let owned = MOVStructuralCreationDatesV4.Snapshot(
            movie: .init(creation: knownCreation, modification: knownModification),
            tracks: baseline.tracks.enumerated().map { index, _ in
                .init(
                    trackHeader: .init(
                        creation: knownCreation &+ UInt64(index + 1),
                        modification: knownModification &+ UInt64(index + 1)
                    ),
                    mediaHeader: .init(
                        creation: knownCreation &+ UInt64(10 + index),
                        modification: knownModification &+ UInt64(10 + index)
                    )
                )
            }
        )
        let identityMapping = Dictionary(uniqueKeysWithValues: owned.tracks.indices.map { ($0, $0) })
        try MOVStructuralCreationDatesV4.restore(owned, into: sourceURL, outputToSourceTrack: identityMapping)

        // Simulate MediaPipeline/AVFoundation export-time rewrite: zero the
        // structural dates on a same-inventory copy, then restore from source.
        try FileManager.default.copyItem(at: sourceURL, to: rewrittenURL)
        let zeroed = MOVStructuralCreationDatesV4.Snapshot(
            movie: .init(creation: 0, modification: 0),
            tracks: owned.tracks.map { _ in
                .init(
                    trackHeader: .init(creation: 0, modification: 0),
                    mediaHeader: .init(creation: 0, modification: 0)
                )
            }
        )
        try MOVStructuralCreationDatesV4.restore(
            zeroed,
            into: rewrittenURL,
            outputToSourceTrack: identityMapping
        )
        XCTAssertEqual(try MOVStructuralCreationDatesV4.capture(from: rewrittenURL)?.movie.creation, 0)

        let restored = try XCTUnwrap(
            try MOVStructuralCreationDatesV4.restoreFromSource(
                sourceURL: sourceURL,
                into: rewrittenURL
            )
        )
        XCTAssertEqual(restored.movie.creation, knownCreation)
        try MOVStructuralCreationDatesV4.verify(
            owned,
            in: rewrittenURL,
            outputToSourceTrack: identityMapping
        )
    }

    func testRestoreFromSourceMovieOnlyWhenTrackInventoriesDiverge() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "mov"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-creation-diverge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("dated-source.mov")
        let outputURL = directory.appendingPathComponent("fewer-tracks.mov")
        try FileManager.default.copyItem(at: fixture, to: sourceURL)

        let baseline = try XCTUnwrap(try MOVStructuralCreationDatesV4.capture(from: sourceURL))
        XCTAssertGreaterThanOrEqual(baseline.tracks.count, 2)
        let owned = MOVStructuralCreationDatesV4.Snapshot(
            movie: .init(creation: knownCreation, modification: knownModification),
            tracks: baseline.tracks.enumerated().map { index, _ in
                .init(
                    trackHeader: .init(
                        creation: knownCreation &+ UInt64(index + 1),
                        modification: knownModification &+ UInt64(index + 1)
                    ),
                    mediaHeader: .init(
                        creation: knownCreation &+ UInt64(10 + index),
                        modification: knownModification &+ UInt64(10 + index)
                    )
                )
            }
        )
        let identityMapping = Dictionary(uniqueKeysWithValues: owned.tracks.indices.map { ($0, $0) })
        try MOVStructuralCreationDatesV4.restore(owned, into: sourceURL, outputToSourceTrack: identityMapping)

        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        let movie = try XCTUnwrap(AVMutableMovie(url: outputURL, options: nil))
        let removable = try XCTUnwrap(movie.tracks.last)
        movie.removeTrack(removable)
        try movie.writeHeader(
            to: outputURL,
            fileType: .mov,
            options: .addMovieHeaderToDestination
        )
        let reduced = try XCTUnwrap(try MOVStructuralCreationDatesV4.capture(from: outputURL))
        XCTAssertEqual(reduced.tracks.count, owned.tracks.count - 1)
        let zeroedTracks = Dictionary(
            uniqueKeysWithValues: reduced.tracks.indices.map { ($0, $0) }
        )
        try MOVStructuralCreationDatesV4.restore(
            MOVStructuralCreationDatesV4.Snapshot(
                movie: .init(creation: 0, modification: 0),
                tracks: reduced.tracks.map { _ in
                    .init(
                        trackHeader: .init(creation: 0, modification: 0),
                        mediaHeader: .init(creation: 0, modification: 0)
                    )
                }
            ),
            into: outputURL,
            outputToSourceTrack: zeroedTracks
        )

        _ = try MOVStructuralCreationDatesV4.restoreFromSource(
            sourceURL: sourceURL,
            into: outputURL
        )
        let after = try XCTUnwrap(try MOVStructuralCreationDatesV4.capture(from: outputURL))
        XCTAssertEqual(after.movie, owned.movie)
        // Track dates stay cleared when inventories diverge; only movie
        // ownership is restored without an explicit ordinal map.
        XCTAssertEqual(after.tracks[0].trackHeader.creation, 0)
        XCTAssertNotEqual(after.tracks[0].trackHeader.creation, owned.tracks[0].trackHeader.creation)
    }

    func testMigrationExecutorPreservesStructuralCreationDates() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "legacy-mjpeg", withExtension: "mov"
        ))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirmir-creation-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("dated-source.mov")
        let destinationURL = directory.appendingPathComponent("dated-output.mov")
        try FileManager.default.copyItem(at: fixture, to: sourceURL)

        let baseline = try XCTUnwrap(try MOVStructuralCreationDatesV4.capture(from: sourceURL))
        let owned = MOVStructuralCreationDatesV4.Snapshot(
            movie: .init(creation: knownCreation, modification: knownModification),
            tracks: baseline.tracks.enumerated().map { index, _ in
                .init(
                    trackHeader: .init(
                        creation: knownCreation &+ UInt64(index + 1),
                        modification: knownModification &+ UInt64(index + 1)
                    ),
                    mediaHeader: .init(
                        creation: knownCreation &+ UInt64(10 + index),
                        modification: knownModification &+ UInt64(10 + index)
                    )
                )
            }
        )
        let identityMapping = Dictionary(uniqueKeysWithValues: owned.tracks.indices.map { ($0, $0) })
        try MOVStructuralCreationDatesV4.restore(owned, into: sourceURL, outputToSourceTrack: identityMapping)

        let source = try await AVFoundationTrackGraphAdapterV4.probe(asset: AVURLAsset(url: sourceURL))
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceGraph: source,
            identifiedPlan: plan,
            blueprint: try AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: source, plan: plan)
        ))
        XCTAssertTrue(result.verificationReport.isConformant)

        try MOVStructuralCreationDatesV4.verify(
            owned,
            in: destinationURL,
            outputToSourceTrack: identityMapping
        )
        let outputAsset = AVURLAsset(url: destinationURL)
        let creationItem = try await outputAsset.load(.creationDate)
        let creationDate = try await creationItem?.load(.dateValue)
        XCTAssertEqual(
            creationDate,
            MOVStructuralCreationDatesV4.foundationDate(fromQuickTimeSeconds: knownCreation)
        )
    }
}
