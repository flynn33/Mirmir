import Foundation
import XCTest
@testable import Mirmir

// swiftlint:disable file_length type_body_length

final class R12ChunkCheckpointLedgerTests: XCTestCase {
    func testInterruptedAndUninterruptedExecutionProduceIdenticalLedger() async throws {
        try await withRoots(count: 2) { roots in
            let header = try makeHeader()
            let interrupted = R12ChunkCheckpointStore(rootURL: roots[0])
            let uninterrupted = R12ChunkCheckpointStore(rootURL: roots[1])
            var interruptedCursor = try await interrupted.create(header: header)
            var uninterruptedCursor = try await uninterrupted.create(header: header)

            for index in 0..<3 {
                let payload = Data("closed-chunk-\(index)".utf8)
                let first = try makeChunk(
                    root: roots[0],
                    index: index,
                    payload: payload
                )
                let second = try makeChunk(
                    root: roots[1],
                    index: index,
                    payload: payload
                )
                interruptedCursor = try await interrupted.appendVerified(
                    first,
                    expectedHeadSHA256: interruptedCursor.headSHA256
                )
                if index == 1 {
                    let reopened = R12ChunkCheckpointStore(rootURL: roots[0])
                    interruptedCursor = try await reopened.reopen(
                        expecting: R12ResumeExpectation(
                            header: header,
                            expectedHeadSHA256: interruptedCursor.headSHA256
                        )
                    )
                }
                uninterruptedCursor = try await uninterrupted.appendVerified(
                    second,
                    expectedHeadSHA256: uninterruptedCursor.headSHA256
                )
            }

            XCTAssertEqual(interruptedCursor, uninterruptedCursor)
            let interruptedData = try await interrupted.canonicalLedgerData()
            let uninterruptedData = try await uninterrupted.canonicalLedgerData()
            XCTAssertEqual(interruptedData, uninterruptedData)
            XCTAssertEqual(interruptedCursor.nextSequence, 3)
            XCTAssertEqual(interruptedCursor.nextVideoSampleIndex, 30)
            XCTAssertEqual(
                interruptedCursor.resumeTime,
                try R12MediaTime(value: 3, timescale: 1)
            )
        }
    }

    func testSafeBoundaryRequiresSyncProgressSingleVideoAndUniqueTracks() throws {
        let start = try R12MediaTime(value: 0, timescale: 1)
        let end = try R12MediaTime(value: 1, timescale: 1)
        let video = try R12TrackWatermark(
            trackID: "video-0",
            kind: .video,
            nextSampleIndex: 10,
            time: end
        )
        XCTAssertThrowsError(
            try R12SafeMediaBoundary(
                start: start,
                endExclusive: end,
                firstVideoSampleIndex: 0,
                nextVideoSampleIndex: 10,
                nextSampleIsSync: false,
                trackWatermarks: [video],
                backendState: .stateless
            )
        )
        XCTAssertThrowsError(
            try R12SafeMediaBoundary(
                start: start,
                endExclusive: end,
                firstVideoSampleIndex: 0,
                nextVideoSampleIndex: 10,
                nextSampleIsSync: true,
                trackWatermarks: [],
                backendState: .stateless
            )
        )
        XCTAssertThrowsError(
            try R12SafeMediaBoundary(
                start: start,
                endExclusive: end,
                firstVideoSampleIndex: 0,
                nextVideoSampleIndex: 10,
                nextSampleIsSync: true,
                trackWatermarks: [video, video],
                backendState: .stateless
            )
        )
        let secondVideo = try R12TrackWatermark(
            trackID: "video-1",
            kind: .video,
            nextSampleIndex: 10,
            time: end
        )
        XCTAssertThrowsError(
            try R12SafeMediaBoundary(
                start: start,
                endExclusive: end,
                firstVideoSampleIndex: 0,
                nextVideoSampleIndex: 10,
                nextSampleIsSync: true,
                trackWatermarks: [video, secondVideo],
                backendState: .stateless
            )
        )
    }

    func testHeaderRequiresUniqueSingleVideoTrackLayout() throws {
        let audio = try R12TrackIdentity(trackID: "audio-0", kind: .audio)
        let video = try R12TrackIdentity(trackID: "video-0", kind: .video)
        let header = try makeHeader(trackLayout: [video, audio])
        XCTAssertEqual(header.trackLayout, [audio, video])

        XCTAssertThrowsError(
            try makeHeader(trackLayout: [video, video])
        ) { error in
            XCTAssertEqual(
                error as? R12ChunkCheckpointError,
                .duplicateTrack("video-0")
            )
        }
        XCTAssertThrowsError(
            try makeHeader(trackLayout: [audio])
        ) { error in
            XCTAssertEqual(
                error as? R12ChunkCheckpointError,
                .missingVideoWatermark
            )
        }
        XCTAssertThrowsError(
            try makeHeader(
                trackLayout: [
                    video,
                    try R12TrackIdentity(trackID: "video-1", kind: .video)
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? R12ChunkCheckpointError,
                .missingVideoWatermark
            )
        }
    }

    func testFirstCheckpointMustMatchDeclaredTrackLayout() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await store.create(header: header)
            let incomplete = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("video-only".utf8),
                boundary: try makeBoundary(index: 0, includeAudio: false)
            )
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    incomplete,
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .trackLayoutMismatch
                )
            }
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, cursor)
        }
    }

    func testTimeAndVideoContinuityAndFirstChunkOffsetReject() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            var cursor = try await store.create(header: header)
            let first = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("first".utf8)
            )
            cursor = try await store.appendVerified(
                first,
                expectedHeadSHA256: cursor.headSHA256
            )

            let gap = try makeChunk(
                root: roots[0],
                index: 2,
                payload: Data("gap".utf8)
            )
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    gap,
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .checkpointContinuityMismatch
                )
            }

            let overlap = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("overlap".utf8),
                relativePath: "overlap.bin"
            )
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    overlap,
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .checkpointContinuityMismatch
                )
            }

            let sampleDiscontinuity = try makeSampleDiscontinuityBoundary()
            let discontinuousChunk = try makeChunk(
                root: roots[0],
                index: 1,
                payload: Data("sample-discontinuity".utf8),
                relativePath: "sample-discontinuity.bin",
                boundary: sampleDiscontinuity
            )
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    discontinuousChunk,
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .checkpointContinuityMismatch
                )
            }

            let freshRoot = roots[0].appendingPathComponent("fresh")
            let freshStore = R12ChunkCheckpointStore(rootURL: freshRoot)
            let freshCursor = try await freshStore.create(header: header)
            let offset = try makeChunk(
                root: freshRoot,
                index: 1,
                payload: Data("offset".utf8)
            )
            await XCTAssertThrowsErrorAsync(
                try await freshStore.appendVerified(
                    offset,
                    expectedHeadSHA256: freshCursor.headSHA256
                )
            )
        }
    }

    func testTrackLayoutAndPerTrackWatermarkRegressionReject() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            var cursor = try await store.create(header: header)
            let first = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("first".utf8)
            )
            cursor = try await store.appendVerified(
                first,
                expectedHeadSHA256: cursor.headSHA256
            )

            let cases = [
                R12BoundaryRejectionCase(
                    name: "missing-audio",
                    boundary: try makeBoundary(index: 1, includeAudio: false),
                    error: .trackLayoutMismatch
                ),
                R12BoundaryRejectionCase(
                    name: "changed-audio-id",
                    boundary: try makeBoundary(index: 1, audioTrackID: "audio-1"),
                    error: .trackLayoutMismatch
                ),
                R12BoundaryRejectionCase(
                    name: "changed-audio-kind",
                    boundary: try makeBoundary(index: 1, audioKind: .subtitle),
                    error: .trackLayoutMismatch
                ),
                R12BoundaryRejectionCase(
                    name: "regressed-audio-index",
                    boundary: try makeBoundary(
                        index: 1,
                        audioNextSampleIndex: 47_999
                    ),
                    error: .checkpointContinuityMismatch
                )
            ]
            for testCase in cases {
                let chunk = try makeChunk(
                    root: roots[0],
                    index: 1,
                    payload: Data(testCase.name.utf8),
                    relativePath: "\(testCase.name).bin",
                    boundary: testCase.boundary
                )
                await XCTAssertThrowsErrorAsync(
                    try await store.appendVerified(
                        chunk,
                        expectedHeadSHA256: cursor.headSHA256
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? R12ChunkCheckpointError,
                        testCase.error
                    )
                }
            }
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, cursor)
        }
    }

    func testStaleHeadAndSourceIdentityDriftReject() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("first".utf8)
            )
            let advanced = try await store.appendVerified(
                chunk,
                expectedHeadSHA256: cursor.headSHA256
            )
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    chunk,
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                guard let checkpointError = error as? R12ChunkCheckpointError,
                      case .staleHead = checkpointError else {
                    return XCTFail("Expected stale head, received \(error)")
                }
            }
            let changed = try makeHeader(jobID: "job-changed")
            await XCTAssertThrowsErrorAsync(
                try await store.reopen(
                    expecting: R12ResumeExpectation(
                        header: changed,
                        expectedHeadSHA256: advanced.headSHA256
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .sourceBindingMismatch
                )
            }
        }
    }

    func testExclusiveLockSerializesCompetingStoreHeads() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let firstStore = R12ChunkCheckpointStore(rootURL: roots[0])
            let secondStore = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await firstStore.create(header: header)
            let chunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("single-winner".utf8)
            )

            async let first = r12AppendOutcome(
                store: firstStore,
                chunk: chunk,
                expectedHead: cursor.headSHA256
            )
            async let second = r12AppendOutcome(
                store: secondStore,
                chunk: chunk,
                expectedHead: cursor.headSHA256
            )
            let outcomes = await [first, second]
            let successes = outcomes.compactMap { outcome -> R12ResumeCursor? in
                guard case .success(let advanced) = outcome else {
                    return nil
                }
                return advanced
            }
            XCTAssertEqual(successes.count, 1)
            XCTAssertEqual(outcomes.filter { $0 == .staleHead }.count, 1)
            XCTAssertEqual(successes.first?.nextSequence, 1)

            let reopened = try await secondStore.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: successes.first?.headSHA256
                )
            )
            XCTAssertEqual(reopened, successes.first)
        }
    }

    func testArtifactMutationMissingFileAndReceiptDriftReject() async throws {
        try await withRoots(count: 3) { roots in
            for (index, mutation) in [
                "content",
                "missing",
                "receipt"
            ].enumerated() {
                let header = try makeHeader(jobID: "job-\(mutation)")
                let store = R12ChunkCheckpointStore(rootURL: roots[index])
                let cursor = try await store.create(header: header)
                var chunk = try makeChunk(
                    root: roots[index],
                    index: 0,
                    payload: Data("sealed".utf8)
                )
                if mutation == "receipt" {
                    chunk = R12VerifiedChunk(
                        boundary: chunk.boundary,
                        artifact: try R12ChunkArtifactIdentity(
                            relativePath: chunk.artifact.relativePath,
                            byteCount: chunk.artifact.byteCount,
                            sha256: chunk.artifact.sha256,
                            reopenReceiptSHA256: hash("e")
                        )
                    )
                    await XCTAssertThrowsErrorAsync(
                        try await store.appendVerified(
                            chunk,
                            expectedHeadSHA256: cursor.headSHA256
                        )
                    )
                    continue
                }
                let advanced = try await store.appendVerified(
                    chunk,
                    expectedHeadSHA256: cursor.headSHA256
                )
                let artifactURL = roots[index]
                    .appendingPathComponent(chunk.artifact.relativePath)
                if mutation == "content" {
                    try Data("mutated".utf8).write(to: artifactURL)
                } else {
                    try FileManager.default.removeItem(at: artifactURL)
                }
                await XCTAssertThrowsErrorAsync(
                    try await store.reopen(
                        expecting: R12ResumeExpectation(
                            header: header,
                            expectedHeadSHA256: advanced.headSHA256
                        )
                    )
                )
            }
        }
    }

    func testSymlinkHardlinkAndPathEscapeReject() async throws {
        XCTAssertThrowsError(
            try R12ChunkArtifactIdentity(
                relativePath: "../escape.bin",
                byteCount: 1,
                sha256: hash("a"),
                reopenReceiptSHA256: hash("b")
            )
        )
        try await withRoots(count: 2) { roots in
            let header = try makeHeader()
            for (index, kind) in ["symlink", "hardlink"].enumerated() {
                let root = roots[index]
                let store = R12ChunkCheckpointStore(rootURL: root)
                let cursor = try await store.create(header: header)
                let payload = Data(kind.utf8)
                let chunk = try makeChunk(
                    root: root,
                    index: 0,
                    payload: payload
                )
                let artifactURL = root.appendingPathComponent(
                    chunk.artifact.relativePath
                )
                if kind == "symlink" {
                    try FileManager.default.removeItem(at: artifactURL)
                    try FileManager.default.createSymbolicLink(
                        at: artifactURL,
                        withDestinationURL: root.appendingPathComponent(
                            "missing-target.bin"
                        )
                    )
                } else {
                    try FileManager.default.linkItem(
                        at: artifactURL,
                        to: root.appendingPathComponent("second-link.bin")
                    )
                }
                await XCTAssertThrowsErrorAsync(
                    try await store.appendVerified(
                        chunk,
                        expectedHeadSHA256: cursor.headSHA256
                    )
                )
            }
        }
    }

    func testRootAndIntermediateDirectorySymlinkReject() async throws {
        try await withRoots(count: 2) { roots in
            let header = try makeHeader()
            let rootStore = R12ChunkCheckpointStore(rootURL: roots[0])
            let rootCursor = try await rootStore.create(header: header)
            let rootChunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("root-symlink".utf8)
            )
            let advanced = try await rootStore.appendVerified(
                rootChunk,
                expectedHeadSHA256: rootCursor.headSHA256
            )
            let movedRoot = roots[0].deletingLastPathComponent()
                .appendingPathComponent("moved-root")
            try FileManager.default.moveItem(at: roots[0], to: movedRoot)
            try FileManager.default.createSymbolicLink(
                at: roots[0],
                withDestinationURL: movedRoot
            )
            await XCTAssertThrowsErrorAsync(
                try await rootStore.reopen(
                    expecting: R12ResumeExpectation(
                        header: header,
                        expectedHeadSHA256: advanced.headSHA256
                    )
                )
            ) { error in
                guard let checkpointError = error as? R12ChunkCheckpointError,
                      case .unsafeFilesystemEntry = checkpointError else {
                    return XCTFail("Expected unsafe root, received \(error)")
                }
            }

            let nestedStore = R12ChunkCheckpointStore(rootURL: roots[1])
            let nestedCursor = try await nestedStore.create(header: header)
            let outside = roots[1].deletingLastPathComponent()
                .appendingPathComponent("outside-artifacts")
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            let payload = Data("outside".utf8)
            try payload.write(to: outside.appendingPathComponent("chunk.bin"))
            try FileManager.default.createSymbolicLink(
                at: roots[1].appendingPathComponent("nested"),
                withDestinationURL: outside
            )
            let nestedChunk = R12VerifiedChunk(
                boundary: try makeBoundary(index: 0),
                artifact: try R12ChunkArtifactIdentity.make(
                    relativePath: "nested/chunk.bin",
                    data: payload
                )
            )
            await XCTAssertThrowsErrorAsync(
                try await nestedStore.appendVerified(
                    nestedChunk,
                    expectedHeadSHA256: nestedCursor.headSHA256
                )
            ) { error in
                guard let checkpointError = error as? R12ChunkCheckpointError,
                      case .unsafeFilesystemEntry = checkpointError else {
                    return XCTFail(
                        "Expected unsafe intermediate directory, received \(error)"
                    )
                }
            }
        }
    }

    func testLedgerSymlinkAndHardlinkReject() async throws {
        try await withRoots(count: 2) { roots in
            let header = try makeHeader()
            let ledgerName = "checkpoint-ledger-v1.json"

            let symlinkStore = R12ChunkCheckpointStore(rootURL: roots[0])
            _ = try await symlinkStore.create(header: header)
            let ledgerURL = roots[0].appendingPathComponent(ledgerName)
            let movedLedger = roots[0].appendingPathComponent("moved-ledger.json")
            try FileManager.default.moveItem(at: ledgerURL, to: movedLedger)
            try FileManager.default.createSymbolicLink(
                at: ledgerURL,
                withDestinationURL: movedLedger
            )
            await XCTAssertThrowsErrorAsync(
                try await symlinkStore.reopen(
                    expecting: R12ResumeExpectation(header: header)
                )
            ) { error in
                guard let checkpointError = error as? R12ChunkCheckpointError,
                      case .unsafeFilesystemEntry = checkpointError else {
                    return XCTFail("Expected unsafe ledger link, received \(error)")
                }
            }

            let hardlinkStore = R12ChunkCheckpointStore(rootURL: roots[1])
            _ = try await hardlinkStore.create(header: header)
            let hardlinkLedger = roots[1].appendingPathComponent(ledgerName)
            try FileManager.default.linkItem(
                at: hardlinkLedger,
                to: roots[1].appendingPathComponent("second-ledger-link.json")
            )
            await XCTAssertThrowsErrorAsync(
                try await hardlinkStore.reopen(
                    expecting: R12ResumeExpectation(header: header)
                )
            ) { error in
                guard let checkpointError = error as? R12ChunkCheckpointError,
                      case .unsafeFilesystemEntry = checkpointError else {
                    return XCTFail("Expected unsafe ledger hardlink, received \(error)")
                }
            }
        }
    }

    func testTamperedAndNoncanonicalLedgerReject() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("sealed".utf8)
            )
            XCTAssertEqual(
                cursor.headSHA256,
                "908b2908289835df42ec36fc4c021d7994f055cc2492b82c271182dadadcd57c"
            )
            let advanced = try await store.appendVerified(
                chunk,
                expectedHeadSHA256: cursor.headSHA256
            )
            XCTAssertEqual(
                advanced.headSHA256,
                "853760660c98011be219a6a74195ef64611b4a8238bb830452778751abed380a"
            )
            let ledgerURL = roots[0].appendingPathComponent(
                "checkpoint-ledger-v1.json"
            )
            var bytes = try Data(contentsOf: ledgerURL)
            bytes.append(0x0A)
            try bytes.write(to: ledgerURL)
            await XCTAssertThrowsErrorAsync(
                try await store.reopen(
                    expecting: R12ResumeExpectation(header: header)
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .nonCanonicalLedger
                )
            }
        }
    }

    func testCanonicalButSemanticallyUnsafeBoundaryRejects() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("sealed".utf8)
            )
            _ = try await store.appendVerified(
                chunk,
                expectedHeadSHA256: cursor.headSHA256
            )
            let original = try await store.canonicalLedgerData()
            let originalJSON = try XCTUnwrap(
                String(data: original, encoding: .utf8)
            )
            let syncMarker = #""nextSampleIsSync":true"#
            XCTAssertEqual(
                originalJSON.components(separatedBy: syncMarker).count,
                2
            )
            let mutated = Data(
                originalJSON.replacingOccurrences(
                    of: syncMarker,
                    with: #""nextSampleIsSync":false"#
                ).utf8
            )
            XCTAssertNotEqual(mutated, original)
            try mutated.write(
                to: roots[0].appendingPathComponent(
                    "checkpoint-ledger-v1.json"
                )
            )

            await XCTAssertThrowsErrorAsync(
                try await store.reopen(
                    expecting: R12ResumeExpectation(header: header)
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .invalidBoundary(reason: "unsafe_video_boundary")
                )
            }
        }
    }

    func testCanonicalUnknownFieldRejects() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            _ = try await store.create(header: header)
            let original = try await store.canonicalLedgerData()
            let originalJSON = try XCTUnwrap(
                String(data: original, encoding: .utf8)
            )
            let closingMarker = #""schemaVersion":"1.0.0"}"#
            XCTAssertTrue(originalJSON.hasSuffix(closingMarker))
            let mutatedJSON = String(
                originalJSON.dropLast(closingMarker.count)
            )
                + #""schemaVersion":"1.0.0","unsupported":"must-reject"}"#
            let mutated = Data(mutatedJSON.utf8)
            try mutated.write(
                to: roots[0].appendingPathComponent(
                    "checkpoint-ledger-v1.json"
                )
            )

            await XCTAssertThrowsErrorAsync(
                try await store.reopen(
                    expecting: R12ResumeExpectation(header: header)
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .nonCanonicalLedger
                )
            }
        }
    }

    func testRecordPreviousHashRecordHashAndLedgerHeadTamperingReject() async throws {
        try await withRoots(count: 3) { roots in
            for (index, mutation) in [
                "previous",
                "record",
                "head"
            ].enumerated() {
                let header = try makeHeader(jobID: "job-\(mutation)")
                let store = R12ChunkCheckpointStore(rootURL: roots[index])
                let cursor = try await store.create(header: header)
                let chunk = try makeChunk(
                    root: roots[index],
                    index: 0,
                    payload: Data(mutation.utf8)
                )
                _ = try await store.appendVerified(
                    chunk,
                    expectedHeadSHA256: cursor.headSHA256
                )
                let data = try await store.canonicalLedgerData()
                let ledger = try JSONDecoder().decode(
                    R12ChunkCheckpointLedgerV1.self,
                    from: data
                )
                let record = try XCTUnwrap(ledger.records.first)
                let alteredRecord = R12ChunkCheckpoint(
                    sequence: record.sequence,
                    boundary: record.boundary,
                    artifact: record.artifact,
                    previousRecordSHA256: mutation == "previous"
                        ? hash("e")
                        : record.previousRecordSHA256,
                    recordSHA256: mutation == "record"
                        ? hash("f")
                        : record.recordSHA256
                )
                let alteredLedger = R12ChunkCheckpointLedgerV1(
                    schemaVersion: ledger.schemaVersion,
                    header: ledger.header,
                    records: [alteredRecord],
                    headSHA256: mutation == "record"
                        ? alteredRecord.recordSHA256
                        : mutation == "head"
                            ? hash("d")
                            : ledger.headSHA256
                )
                try canonicalJSONData(alteredLedger).write(
                    to: roots[index].appendingPathComponent(
                        "checkpoint-ledger-v1.json"
                    )
                )
                let expectedError: R12ChunkCheckpointError = mutation == "head"
                    ? .ledgerHeadMismatch
                    : .checkpointHashMismatch
                await XCTAssertThrowsErrorAsync(
                    try await store.reopen(
                        expecting: R12ResumeExpectation(header: header)
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? R12ChunkCheckpointError,
                        expectedError
                    )
                }
            }
        }
    }

    func testAtomicReplacementFailureLeavesLastCursorReopenable() async throws {
        try await withRoots(count: 1) { roots in
            let fileSystem = FailingR12CheckpointFileSystem()
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: roots[0],
                fileSystem: fileSystem
            )
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("sealed".utf8)
            )
            let ledgerBeforeFailure = try await store.canonicalLedgerData()
            fileSystem.failNextReplacement = true
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    chunk,
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .atomicWriteFailed
                )
            }
            let ledgerAfterFailure = try await store.canonicalLedgerData()
            XCTAssertEqual(ledgerAfterFailure, ledgerBeforeFailure)
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, cursor)
        }
    }

    func testOrphanAndUnsealedChunksDoNotAdvanceLedger() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await store.create(header: header)
            try Data("orphan".utf8).write(
                to: roots[0].appendingPathComponent("orphan.tmp")
            )
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(header: header)
            )
            XCTAssertEqual(reopened, cursor)
            XCTAssertEqual(reopened.nextSequence, 0)
        }
    }

    private func withRoots(
        count: Int,
        operation: ([URL]) async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-r12-checkpoint-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let roots = (0..<count).map {
            parent.appendingPathComponent("root-\($0)")
        }
        try await operation(roots)
    }

    private func makeHeader(
        jobID: String = "job-fixture",
        trackLayout: [R12TrackIdentity]? = nil
    ) throws -> R12ChunkLedgerHeader {
        try R12ChunkLedgerHeader(
            sourceIdentitySHA256: hash("1"),
            jobID: jobID,
            formatContractSHA256: hash("2"),
            routeIdentity: "route-fixture",
            hardwareTierIdentity: "tier-fixture",
            executionIdentity: "execution-fixture",
            chunkPolicyIdentity: "closed-sync-boundaries-v1",
            trackLayout: trackLayout ?? [
                try R12TrackIdentity(trackID: "video-0", kind: .video),
                try R12TrackIdentity(trackID: "audio-0", kind: .audio)
            ]
        )
    }

    private func makeChunk(
        root: URL,
        index: Int,
        payload: Data,
        relativePath: String? = nil,
        boundary: R12SafeMediaBoundary? = nil
    ) throws -> R12VerifiedChunk {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let artifactPath = relativePath ?? "chunk-\(index).bin"
        let artifactURL = root.appendingPathComponent(artifactPath)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: artifactURL)
        let verifiedBoundary: R12SafeMediaBoundary
        if let boundary {
            verifiedBoundary = boundary
        } else {
            verifiedBoundary = try makeBoundary(index: index)
        }
        return R12VerifiedChunk(
            boundary: verifiedBoundary,
            artifact: try R12ChunkArtifactIdentity.make(
                relativePath: artifactPath,
                data: payload
            )
        )
    }

    private func makeBoundary(
        index: Int,
        audioTrackID: String = "audio-0",
        audioKind: R12TrackKind = .audio,
        audioNextSampleIndex: Int? = nil,
        includeAudio: Bool = true
    ) throws -> R12SafeMediaBoundary {
        let start = try R12MediaTime(value: Int64(index), timescale: 1)
        let end = try R12MediaTime(value: Int64(index + 1), timescale: 1)
        let nextSample = (index + 1) * 10
        var watermarks = [
            try R12TrackWatermark(
                trackID: "video-0",
                kind: .video,
                nextSampleIndex: nextSample,
                time: end
            )
        ]
        if includeAudio {
            watermarks.append(
                try R12TrackWatermark(
                    trackID: audioTrackID,
                    kind: audioKind,
                    nextSampleIndex: audioNextSampleIndex ?? (index + 1) * 48_000,
                    time: end
                )
            )
        }
        return try R12SafeMediaBoundary(
            start: start,
            endExclusive: end,
            firstVideoSampleIndex: index * 10,
            nextVideoSampleIndex: nextSample,
            nextSampleIsSync: true,
            trackWatermarks: watermarks,
            backendState: .resetAtBoundary(
                resetIdentity: "fixture-reset-v1"
            )
        )
    }

    private func makeSampleDiscontinuityBoundary() throws -> R12SafeMediaBoundary {
        let start = try R12MediaTime(value: 1, timescale: 1)
        let end = try R12MediaTime(value: 2, timescale: 1)
        return try R12SafeMediaBoundary(
            start: start,
            endExclusive: end,
            firstVideoSampleIndex: 11,
            nextVideoSampleIndex: 21,
            nextSampleIsSync: true,
            trackWatermarks: [
                try R12TrackWatermark(
                    trackID: "video-0",
                    kind: .video,
                    nextSampleIndex: 21,
                    time: end
                ),
                try R12TrackWatermark(
                    trackID: "audio-0",
                    kind: .audio,
                    nextSampleIndex: 96_000,
                    time: end
                )
            ],
            backendState: .stateless
        )
    }

    private func hash(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func canonicalJSONData<T: Encodable>(
        _ value: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private struct R12BoundaryRejectionCase {
    let name: String
    let boundary: R12SafeMediaBoundary
    let error: R12ChunkCheckpointError
}

private enum R12AppendOutcome: Equatable, Sendable {
    case success(R12ResumeCursor)
    case staleHead
    case unexpected
}

private func r12AppendOutcome(
    store: R12ChunkCheckpointStore,
    chunk: R12VerifiedChunk,
    expectedHead: String
) async -> R12AppendOutcome {
    do {
        return .success(
            try await store.appendVerified(
                chunk,
                expectedHeadSHA256: expectedHead
            )
        )
    } catch let error as R12ChunkCheckpointError {
        guard case .staleHead = error else {
            return .unexpected
        }
        return .staleHead
    } catch {
        return .unexpected
    }
}

private final class FailingR12CheckpointFileSystem:
    R12CheckpointFileSystem,
    @unchecked Sendable {
    var failNextReplacement = false
    private let local = R12LocalCheckpointFileSystem()

    func ensureDirectory(_ url: URL) throws {
        try local.ensureDirectory(url)
    }

    func validateDirectory(_ url: URL) throws {
        try local.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        local.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try local.readRegularFile(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try local.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        if failNextReplacement {
            failNextReplacement = false
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        try local.replaceAtomically(data, at: url)
    }

    func withExclusiveLock<T>(
        at url: URL,
        _ operation: () throws -> T
    ) throws -> T {
        try local.withExclusiveLock(at: url, operation)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.")
    } catch {
        errorHandler(error)
    }
}

// swiftlint:enable file_length type_body_length
