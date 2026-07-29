import Darwin
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
                backendStartState: .stateless,
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
                backendStartState: .stateless,
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
                backendStartState: .stateless,
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
                backendStartState: .stateless,
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
            XCTAssertThrowsError(
                try makeChunk(
                    root: roots[0],
                    index: 0,
                    payload: Data("video-only".utf8),
                    boundary: try makeBoundary(index: 0, includeAudio: false),
                    header: header
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
                do {
                    let chunk = try makeChunk(
                        root: roots[0],
                        index: 1,
                        payload: Data(testCase.name.utf8),
                        relativePath: "\(testCase.name).bin",
                        boundary: testCase.boundary,
                        header: header
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
                } catch {
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

    func testSealedArtifactMutationAndMissingFileRejectOnReopen() async throws {
        try await withRoots(count: 2) { roots in
            for (index, mutation) in ["content", "missing"].enumerated() {
                let header = try makeHeader(jobID: "job-\(mutation)")
                let store = R12ChunkCheckpointStore(rootURL: roots[index])
                let cursor = try await store.create(header: header)
                let chunk = try makeChunk(
                    root: roots[index],
                    index: 0,
                    payload: Data("sealed".utf8),
                    header: header
                )
                let advanced = try await store.appendVerified(
                    chunk,
                    expectedHeadSHA256: cursor.headSHA256
                )
                let ledger = try JSONDecoder().decode(
                    R12ChunkCheckpointLedgerV1.self,
                    from: try await store.canonicalLedgerData()
                )
                let artifact = try XCTUnwrap(ledger.records.first?.artifact)
                let artifactURL = roots[index].appendingPathComponent(
                    artifact.relativePath
                )
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
                let artifactPath = "chunk-0.bin"
                let artifactURL = root.appendingPathComponent(artifactPath)
                let artifactData = try R12VerifiedChunk.makeCanonicalArtifactData(
                    mediaPayload: Data(kind.utf8),
                    boundary: try makeBoundary(index: 0),
                    header: header
                )
                try artifactData.write(to: artifactURL)
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
                XCTAssertThrowsError(
                    try R12VerifiedChunk.verifyCanonicalArtifact(
                        rootURL: root,
                        relativePath: artifactPath,
                        header: header,
                        expectedArtifactSHA256:
                            R12CryptoKitDigest().sha256(artifactData)
                    )
                )
                let reopened = try await store.reopen(
                    expecting: R12ResumeExpectation(
                        header: header,
                        expectedHeadSHA256: cursor.headSHA256
                    )
                )
                XCTAssertEqual(reopened, cursor)
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
            XCTAssertThrowsError(
                try R12VerifiedChunk.verifyCanonicalArtifact(
                    rootURL: roots[1],
                    relativePath: "nested/chunk.bin",
                    header: header,
                    expectedArtifactSHA256:
                        R12CryptoKitDigest().sha256(payload)
                )
            ) { error in
                guard let checkpointError = error as? R12ChunkCheckpointError,
                      case .unsafeFilesystemEntry = checkpointError else {
                    return XCTFail(
                        "Expected unsafe intermediate directory, received \(error)"
                    )
                }
            }
            let reopened = try await nestedStore.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: nestedCursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, nestedCursor)
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
                "f4b5c022982a29f77cadcff3b9f749ac464a93d9141e3f8254f616ce9e25c571"
            )
            let advanced = try await store.appendVerified(
                chunk,
                expectedHeadSHA256: cursor.headSHA256
            )
            XCTAssertEqual(
                advanced.headSHA256,
                "566f11eba2f1d6d615b0c5fd371804e7698dbb87fa97b89046f1ee593cdecbd9"
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
                    payload: Data(mutation.utf8),
                    header: header
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

    func testResumeCursorRoundTripsAllTrackWatermarksAndBackendState() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let initial = try await store.create(header: header)
            XCTAssertEqual(initial.trackWatermarks, header.initialTrackWatermarks)
            XCTAssertEqual(
                initial.backendResumeState,
                header.initialBackendState
            )

            let boundary = try makeBoundary(
                index: 0,
                backendState: .resetAtBoundary(
                    resetIdentity: "fixture-reset-v2"
                )
            )
            let chunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("all-tracks".utf8),
                boundary: boundary,
                header: header
            )
            let advanced = try await store.appendVerified(
                chunk,
                expectedHeadSHA256: initial.headSHA256
            )
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: advanced.headSHA256
                )
            )
            XCTAssertEqual(reopened, advanced)
            XCTAssertEqual(reopened.trackWatermarks, boundary.trackWatermarks)
            XCTAssertEqual(
                Set(reopened.trackWatermarks.map(\.kind)),
                Set(R12TrackKind.allCases)
            )
            XCTAssertEqual(
                reopened.backendResumeState,
                boundary.backendState
            )
        }
    }

    func testBackendStateMustContinueFromPriorResumeState() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            var cursor = try await store.create(header: header)
            let firstBoundary = try makeBoundary(
                index: 0,
                backendState: .resetAtBoundary(
                    resetIdentity: "fixture-reset-v2"
                )
            )
            cursor = try await store.appendVerified(
                try makeChunk(
                    root: roots[0],
                    index: 0,
                    payload: Data("first-state".utf8),
                    boundary: firstBoundary,
                    header: header
                ),
                expectedHeadSHA256: cursor.headSHA256
            )

            let wrongStart = try makeBoundary(index: 1)
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    try makeChunk(
                        root: roots[0],
                        index: 1,
                        payload: Data("wrong-start".utf8),
                        relativePath: "wrong-start.r12chunk",
                        boundary: wrongStart,
                        header: header
                    ),
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .checkpointContinuityMismatch
                )
            }

            let correct = try makeBoundary(
                index: 1,
                backendStartState: .resetAtBoundary(
                    resetIdentity: "fixture-reset-v2"
                ),
                backendState: .stateless
            )
            cursor = try await store.appendVerified(
                try makeChunk(
                    root: roots[0],
                    index: 1,
                    payload: Data("correct-start".utf8),
                    relativePath: "correct-start.r12chunk",
                    boundary: correct,
                    header: header
                ),
                expectedHeadSHA256: cursor.headSHA256
            )
            XCTAssertEqual(cursor.backendResumeState, .stateless)
        }
    }

    func testCanonicalBackendStartStateTamperRejects() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await store.create(header: header)
            _ = try await store.appendVerified(
                try makeChunk(
                    root: roots[0],
                    index: 0,
                    payload: Data("state-tamper".utf8),
                    header: header
                ),
                expectedHeadSHA256: cursor.headSHA256
            )
            let ledger = try JSONDecoder().decode(
                R12ChunkCheckpointLedgerV1.self,
                from: try await store.canonicalLedgerData()
            )
            let record = try XCTUnwrap(ledger.records.first)
            let boundary = record.boundary
            let tamperedBoundary = try R12SafeMediaBoundary(
                start: boundary.start,
                endExclusive: boundary.endExclusive,
                firstVideoSampleIndex: boundary.firstVideoSampleIndex,
                nextVideoSampleIndex: boundary.nextVideoSampleIndex,
                nextSampleIsSync: boundary.nextSampleIsSync,
                trackWatermarks: boundary.trackWatermarks,
                backendStartState: .stateless,
                backendState: boundary.backendState
            )
            let tamperedRecord = R12ChunkCheckpoint(
                sequence: record.sequence,
                boundary: tamperedBoundary,
                artifact: record.artifact,
                previousRecordSHA256: record.previousRecordSHA256,
                recordSHA256: record.recordSHA256
            )
            try canonicalJSONData(
                R12ChunkCheckpointLedgerV1(
                    schemaVersion: ledger.schemaVersion,
                    header: ledger.header,
                    records: [tamperedRecord],
                    headSHA256: ledger.headSHA256
                )
            ).write(
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
                    .checkpointContinuityMismatch
                )
            }
        }
    }

    func testArtifactPolicyBoundaryIsIndependentFromLedgerLimit() throws {
        let maximum = UInt64(64 * 1_024 * 1_024)
        let policy = try R12ChunkArtifactPolicy(
            maximumArtifactBytes: maximum
        )
        XCTAssertNoThrow(
            try policy.validate(byteCount: maximum, path: "maximum.r12chunk")
        )
        XCTAssertThrowsError(
            try policy.validate(
                byteCount: maximum + 1,
                path: "too-large.r12chunk"
            )
        ) { error in
            XCTAssertEqual(
                error as? R12ChunkCheckpointError,
                .artifactSizeMismatch(path: "too-large.r12chunk")
            )
        }
        XCTAssertEqual(policy.readLimit, Int(maximum))
        XCTAssertNotEqual(policy.readLimit, 16 * 1_024 * 1_024)
    }

    func testAppendReadsOnlyLedgerAndNewArtifactNotHistory() async throws {
        try await withRoots(count: 1) { roots in
            let fileSystem = CountingR12CheckpointFileSystem()
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: roots[0],
                fileSystem: fileSystem
            )
            var cursor = try await store.create(header: header)
            cursor = try await store.appendVerified(
                try makeChunk(
                    root: roots[0],
                    index: 0,
                    payload: Data("historical".utf8),
                    header: header
                ),
                expectedHeadSHA256: cursor.headSHA256
            )
            let second = try makeChunk(
                root: roots[0],
                index: 1,
                payload: Data("new".utf8),
                header: header
            )
            fileSystem.resetReads()
            _ = try await store.appendVerified(
                second,
                expectedHeadSHA256: cursor.headSHA256
            )
            let reads = fileSystem.readObservations
            XCTAssertEqual(reads.count, 2)
            XCTAssertEqual(
                reads.filter {
                    $0.path.hasSuffix("checkpoint-ledger-v1.json")
                        && $0.maximumBytes == 16 * 1_024 * 1_024
                }.count,
                1
            )
            XCTAssertEqual(
                reads.filter {
                    $0.path.contains(
                        ".r12-checkpoint-artifacts-v1/1-"
                    ) && $0.maximumBytes == header.artifactPolicy.readLimit
                }.count,
                1
            )
            XCTAssertFalse(
                reads.contains {
                    $0.path.contains(
                        ".r12-checkpoint-artifacts-v1/0-"
                    )
                }
            )
        }
    }

    func testVerifiedBytesAreOwnedBeforeExternalSubstitution() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(rootURL: roots[0])
            let cursor = try await store.create(header: header)
            let candidatePath = "externally-mutable.r12chunk"
            let candidateURL = roots[0].appendingPathComponent(candidatePath)
            let boundary = try makeBoundary(index: 0)
            let original = try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data("original".utf8),
                boundary: boundary,
                header: header
            )
            try original.write(to: candidateURL)
            let verified = try R12VerifiedChunk.verifyCanonicalArtifact(
                rootURL: roots[0],
                relativePath: candidatePath,
                header: header,
                expectedArtifactSHA256:
                    R12CryptoKitDigest().sha256(original)
            )
            let substitution = try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data("substitution".utf8),
                boundary: boundary,
                header: header
            )
            try substitution.write(to: candidateURL)

            let advanced = try await store.appendVerified(
                verified,
                expectedHeadSHA256: cursor.headSHA256
            )
            let ledger = try JSONDecoder().decode(
                R12ChunkCheckpointLedgerV1.self,
                from: try await store.canonicalLedgerData()
            )
            let sealedPath = try XCTUnwrap(
                ledger.records.first?.artifact.relativePath
            )
            let sealed = try Data(
                contentsOf: roots[0].appendingPathComponent(sealedPath)
            )
            XCTAssertEqual(sealed, original)
            XCTAssertNotEqual(sealed, substitution)
            XCTAssertNotEqual(
                sealedPath,
                candidatePath
            )
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: advanced.headSHA256
                )
            )
            XCTAssertEqual(reopened, advanced)
        }
    }

    func testVerifierRejectsMalformedMismatchedAndNonSyncEnvelopes() async throws {
        try await withRoots(count: 3) { roots in
            let header = try makeHeader()
            try FileManager.default.createDirectory(
                at: roots[0],
                withIntermediateDirectories: true
            )
            let malformed = Data(#"{"not":"a-chunk"}"#.utf8)
            try malformed.write(
                to: roots[0].appendingPathComponent("malformed.r12chunk")
            )
            XCTAssertThrowsError(
                try R12VerifiedChunk.verifyCanonicalArtifact(
                    rootURL: roots[0],
                    relativePath: "malformed.r12chunk",
                    header: header,
                    expectedArtifactSHA256:
                        R12CryptoKitDigest().sha256(malformed)
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .malformedChunkEnvelope
                )
            }

            try FileManager.default.createDirectory(
                at: roots[1],
                withIntermediateDirectories: true
            )
            let mismatched = try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data("bound-to-other-header".utf8),
                boundary: try makeBoundary(index: 0),
                header: header
            )
            try mismatched.write(
                to: roots[1].appendingPathComponent("mismatch.r12chunk")
            )
            XCTAssertThrowsError(
                try R12VerifiedChunk.verifyCanonicalArtifact(
                    rootURL: roots[1],
                    relativePath: "mismatch.r12chunk",
                    header: try makeHeader(jobID: "other-job"),
                    expectedArtifactSHA256:
                        R12CryptoKitDigest().sha256(mismatched)
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .sourceBindingMismatch
                )
            }

            try FileManager.default.createDirectory(
                at: roots[2],
                withIntermediateDirectories: true
            )
            let syncSafe = try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data("must-be-sync-safe".utf8),
                boundary: try makeBoundary(index: 0),
                header: header
            )
            let syncJSON = try XCTUnwrap(
                String(data: syncSafe, encoding: .utf8)
            )
            let nonSync = Data(
                syncJSON.replacingOccurrences(
                    of: #""nextSampleIsSync":true"#,
                    with: #""nextSampleIsSync":false"#
                ).utf8
            )
            try nonSync.write(
                to: roots[2].appendingPathComponent("non-sync.r12chunk")
            )
            XCTAssertThrowsError(
                try R12VerifiedChunk.verifyCanonicalArtifact(
                    rootURL: roots[2],
                    relativePath: "non-sync.r12chunk",
                    header: header,
                    expectedArtifactSHA256:
                        R12CryptoKitDigest().sha256(nonSync)
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .invalidBoundary(reason: "unsafe_video_boundary")
                )
            }
        }
    }

    func testVerifierRejectsCanonicalArtifactHashSubstitution() async throws {
        try await withRoots(count: 1) { roots in
            let header = try makeHeader()
            try FileManager.default.createDirectory(
                at: roots[0],
                withIntermediateDirectories: true
            )
            let boundary = try makeBoundary(index: 0)
            let expected = try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data("expected".utf8),
                boundary: boundary,
                header: header
            )
            let substituted = try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data("substituted".utf8),
                boundary: boundary,
                header: header
            )
            try substituted.write(
                to: roots[0].appendingPathComponent("substituted.r12chunk")
            )
            XCTAssertThrowsError(
                try R12VerifiedChunk.verifyCanonicalArtifact(
                    rootURL: roots[0],
                    relativePath: "substituted.r12chunk",
                    header: header,
                    expectedArtifactSHA256:
                        R12CryptoKitDigest().sha256(expected)
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .artifactHashMismatch(path: "substituted.r12chunk")
                )
            }
        }
    }

    func testDirectorySyncFailureRollsBackToPreviousLedgerHead() async throws {
        try await withRoots(count: 1) { roots in
            let syncController = R12DirectorySyncController()
            let fileSystem = R12LocalCheckpointFileSystem(
                directorySynchronizer: {
                    try syncController.synchronize(
                        descriptor: $0,
                        url: $1
                    )
                }
            )
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: roots[0],
                fileSystem: fileSystem
            )
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: roots[0],
                index: 0,
                payload: Data("durability".utf8),
                header: header
            )
            let before = try await store.canonicalLedgerData()
            syncController.failAfterSuccessfulCalls(1)
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
            let after = try await store.canonicalLedgerData()
            XCTAssertEqual(after, before)
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, cursor)
        }
    }

    func testDescriptorReadRejectsPreOpenAndPostReadPathSubstitution() async throws {
        try await withRoots(count: 2) { roots in
            let points: [R12CheckpointFileSystemHookPoint] = [
                .afterReadPathSnapshot,
                .beforeReadPathResnapshot
            ]
            for (index, point) in points.enumerated() {
                let root = roots[index]
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
                let source = root.appendingPathComponent("source.bin")
                let replacement = root.appendingPathComponent("replacement.bin")
                let displaced = root.appendingPathComponent("displaced.bin")
                let originalData = Data("original".utf8)
                let replacementData = Data("attacker".utf8)
                try originalData.write(to: source)
                try replacementData.write(to: replacement)
                let hook = R12FileSystemHookController()
                let fileSystem = R12LocalCheckpointFileSystem(
                    operationHook: {
                        try hook.invoke(point: $0, url: $1)
                    }
                )
                hook.arm(point: point) { observedURL in
                    XCTAssertEqual(observedURL, source)
                    try FileManager.default.moveItem(
                        at: source,
                        to: displaced
                    )
                    try FileManager.default.moveItem(
                        at: replacement,
                        to: source
                    )
                }
                XCTAssertThrowsError(
                    try fileSystem.readRegularFile(
                        source,
                        maximumBytes: 1_024
                    )
                ) { error in
                    guard let checkpointError =
                            error as? R12ChunkCheckpointError,
                          case .unsafeFilesystemEntry = checkpointError else {
                        return XCTFail(
                            "Expected unsafe path substitution, received \(error)"
                        )
                    }
                }
                XCTAssertEqual(
                    try Data(contentsOf: displaced),
                    originalData
                )
                XCTAssertEqual(
                    try Data(contentsOf: source),
                    replacementData
                )
            }
        }
    }

    func testReplaceRejectsPreSwapPathSubstitution() async throws {
        try await withRoots(count: 1) { roots in
            let root = roots[0]
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            try fileSystem.ensureDirectory(root)
            let ledger = root.appendingPathComponent("ledger.json")
            let preserved = root.appendingPathComponent("preserved.json")
            let substitute = root.appendingPathComponent("substitute.json")
            let oldData = Data("old-ledger".utf8)
            let attackerData = Data("attacker!!".utf8)
            try fileSystem.writeNewAtomically(oldData, to: ledger)
            try attackerData.write(to: substitute)
            hook.arm(point: .beforeReplacePathResnapshot) { _ in
                try FileManager.default.moveItem(at: ledger, to: preserved)
                try FileManager.default.moveItem(at: substitute, to: ledger)
            }
            XCTAssertThrowsError(
                try fileSystem.replaceAtomically(
                    Data("new-ledger".utf8),
                    at: ledger
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .atomicWriteFailed
                )
            }
            XCTAssertEqual(try Data(contentsOf: preserved), oldData)
            XCTAssertEqual(try Data(contentsOf: ledger), attackerData)
        }
    }

    func testReplaceRejectsPostReadTemporaryContentMutation() async throws {
        try await withRoots(count: 1) { roots in
            let root = roots[0]
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: root,
                fileSystem: fileSystem
            )
            let cursor = try await store.create(header: header)
            let priorLedger = try await store.canonicalLedgerData()
            let chunk = try makeChunk(
                root: root,
                index: 0,
                payload: Data("post-read-mutation".utf8),
                header: header
            )
            let ledger = root.appendingPathComponent(
                "checkpoint-ledger-v1.json"
            )
            hook.arm(
                point: .afterReplaceTemporaryContentRead
            ) { observedURL in
                XCTAssertEqual(observedURL, ledger)
                let temporaryNames =
                    try FileManager.default.contentsOfDirectory(
                        atPath: root.path
                    ).filter {
                        $0.hasPrefix(".checkpoint-ledger-v1.json.")
                            && $0.hasSuffix(".tmp")
                    }
                XCTAssertEqual(temporaryNames.count, 1)
                let temporary = root.appendingPathComponent(
                    try XCTUnwrap(temporaryNames.first)
                )
                try Self.overwriteContentsPreservingInode(
                    at: temporary,
                    repeating: 0xA5
                )
            }
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
            XCTAssertEqual(ledgerAfterFailure, priorLedger)
            let reopened = try await R12ChunkCheckpointStore(
                rootURL: root
            ).reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, cursor)
        }
    }

    func testPostSwapIdentitySubstitutionRollsBackPriorDestination() async throws {
        try await withRoots(count: 1) { roots in
            let root = roots[0]
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            try fileSystem.ensureDirectory(root)
            let ledger = root.appendingPathComponent("ledger.json")
            let movedNew = root.appendingPathComponent("moved-new.json")
            let attacker = root.appendingPathComponent("attacker.json")
            let oldData = Data("prior-ledger".utf8)
            let newData = Data("newer-ledger".utf8)
            try fileSystem.writeNewAtomically(oldData, to: ledger)
            try Data("attacker-led".utf8).write(to: attacker)
            hook.arm(point: .afterReplaceSwap) { _ in
                try FileManager.default.moveItem(at: ledger, to: movedNew)
                try FileManager.default.moveItem(at: attacker, to: ledger)
            }
            XCTAssertThrowsError(
                try fileSystem.replaceAtomically(newData, at: ledger)
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .atomicWriteFailed
                )
            }
            XCTAssertEqual(try Data(contentsOf: ledger), oldData)
            XCTAssertEqual(try Data(contentsOf: movedNew), newData)
        }
    }

    func testCreatePublishesOneLinkAndSyncFailureRemovesDestination() async throws {
        try await withRoots(count: 2) { roots in
            let normal = R12LocalCheckpointFileSystem()
            try normal.ensureDirectory(roots[0])
            let durable = roots[0].appendingPathComponent("durable.json")
            try normal.writeNewAtomically(
                Data("durable".utf8),
                to: durable
            )
            var durableMetadata = stat()
            XCTAssertEqual(lstat(durable.path, &durableMetadata), 0)
            XCTAssertEqual(durableMetadata.st_nlink, 1)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(
                    atPath: roots[0].path
                ).contains { $0.hasSuffix(".tmp") }
            )

            let controller = R12DirectorySyncController()
            let failing = R12LocalCheckpointFileSystem(
                directorySynchronizer: {
                    try controller.synchronize(
                        descriptor: $0,
                        url: $1
                    )
                }
            )
            try failing.ensureDirectory(roots[1])
            controller.failAfterSuccessfulCalls(0)
            let rejected = roots[1].appendingPathComponent("rejected.json")
            XCTAssertThrowsError(
                try failing.writeNewAtomically(
                    Data("not-durable".utf8),
                    to: rejected
                )
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .atomicWriteFailed
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(
                    atPath: roots[1].path
                ).contains { $0.hasSuffix(".tmp") }
            )
        }
    }

    func testFailedSwapBackPreservesPriorLedgerRecoveryEntry() async throws {
        try await withRoots(count: 1) { roots in
            let root = roots[0]
            let sync = R12DirectorySyncController()
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                directorySynchronizer: {
                    try sync.synchronize(descriptor: $0, url: $1)
                },
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            try fileSystem.ensureDirectory(root)
            let ledger = root.appendingPathComponent("ledger.json")
            let oldData = Data("prior-ledger".utf8)
            let newData = Data("candidate-new".utf8)
            try fileSystem.writeNewAtomically(oldData, to: ledger)
            sync.failAfterSuccessfulCalls(0)
            hook.arm(point: .beforeRollbackSwap) { _ in
                throw R12ChunkCheckpointError.atomicWriteFailed
            }
            XCTAssertThrowsError(
                try fileSystem.replaceAtomically(newData, at: ledger)
            ) { error in
                XCTAssertEqual(
                    error as? R12ChunkCheckpointError,
                    .durabilityRollbackFailed
                )
            }
            XCTAssertEqual(try Data(contentsOf: ledger), newData)
            let recoveryNames = try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ).filter { $0.hasPrefix(".ledger.json.") && $0.hasSuffix(".tmp") }
            XCTAssertEqual(recoveryNames.count, 1)
            let recovery = root.appendingPathComponent(
                try XCTUnwrap(recoveryNames.first)
            )
            XCTAssertEqual(try Data(contentsOf: recovery), oldData)
            var recoveryMetadata = stat()
            XCTAssertEqual(lstat(recovery.path, &recoveryMetadata), 0)
            XCTAssertEqual(recoveryMetadata.st_nlink, 1)
        }
    }

    func testCreateRejectsTemporaryAndDestinationSubstitution() async throws {
        try await withRoots(count: 2) { roots in
            let points: [R12CheckpointFileSystemHookPoint] = [
                .beforeCreateRename,
                .afterCreateRename
            ]
            for (index, point) in points.enumerated() {
                let root = roots[index]
                let hook = R12FileSystemHookController()
                let fileSystem = R12LocalCheckpointFileSystem(
                    operationHook: {
                        try hook.invoke(point: $0, url: $1)
                    }
                )
                try fileSystem.ensureDirectory(root)
                let destination = root.appendingPathComponent("ledger.json")
                let preserved = root.appendingPathComponent("preserved.json")
                let attacker = root.appendingPathComponent("attacker.json")
                let expectedData = Data("expected-ledger".utf8)
                let attackerData = Data("attacker-ledger".utf8)
                if point == .afterCreateRename {
                    try attackerData.write(to: attacker)
                }
                hook.arm(point: point) { observedURL in
                    XCTAssertEqual(observedURL, destination)
                    if point == .beforeCreateRename {
                        let temporaryName = try XCTUnwrap(
                            FileManager.default.contentsOfDirectory(
                                atPath: root.path
                            ).first {
                                $0.hasPrefix(".ledger.json.")
                                    && $0.hasSuffix(".tmp")
                            }
                        )
                        let temporary = root.appendingPathComponent(
                            temporaryName
                        )
                        try FileManager.default.moveItem(
                            at: temporary,
                            to: preserved
                        )
                        try attackerData.write(to: temporary)
                    } else {
                        try FileManager.default.moveItem(
                            at: destination,
                            to: preserved
                        )
                        try FileManager.default.moveItem(
                            at: attacker,
                            to: destination
                        )
                    }
                }
                XCTAssertThrowsError(
                    try fileSystem.writeNewAtomically(
                        expectedData,
                        to: destination
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? R12ChunkCheckpointError,
                        .atomicWriteFailed
                    )
                }
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: destination.path)
                )
                XCTAssertEqual(
                    try Data(contentsOf: preserved),
                    expectedData
                )
                XCTAssertFalse(
                    try FileManager.default.contentsOfDirectory(
                        atPath: root.path
                    ).contains { $0.hasSuffix(".tmp") }
                )
            }
        }
    }

    func testEnsureDirectoryRollsBackAndClosesOnEveryCreationSyncFailure() async throws {
        try await withRoots(count: 2) { roots in
            for (successfulSyncs, root) in roots.enumerated() {
                try R12LocalCheckpointFileSystem().ensureDirectory(root)
                let controller = R12DirectorySyncController()
                let fileSystem = R12LocalCheckpointFileSystem(
                    directorySynchronizer: {
                        try controller.synchronize(
                            descriptor: $0,
                            url: $1
                        )
                    }
                )
                controller.failAfterSuccessfulCalls(successfulSyncs)
                let created = root.appendingPathComponent(
                    "created-before-sync-failure"
                )
                XCTAssertThrowsError(
                    try fileSystem.ensureDirectory(created)
                ) { error in
                    XCTAssertEqual(
                        error as? R12ChunkCheckpointError,
                        .atomicWriteFailed
                    )
                }
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: created.path)
                )
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: root.path
                    ),
                    []
                )
                let descriptor = try XCTUnwrap(
                    controller.mostRecentFailedDescriptor
                )
                var metadata = stat()
                errno = 0
                XCTAssertEqual(fstat(descriptor, &metadata), -1)
                XCTAssertEqual(errno, EBADF)
            }
        }
    }

    func testCanonicalArtifactConstructionRejectsBeforeUnboundedEncoding() throws {
        let payloadLimit: UInt64 = 64
        let header = try makeHeader(maximumArtifactBytes: payloadLimit)
        let boundary = try makeBoundary(index: 0)

        XCTAssertThrowsError(
            try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data(
                    repeating: 0xA5,
                    count: Int(payloadLimit) + 1
                ),
                boundary: boundary,
                header: header,
                digest: R12UnexpectedDigest()
            )
        ) { error in
            XCTAssertEqual(
                error as? R12ChunkCheckpointError,
                .artifactSizeMismatch(path: "canonical-media-payload")
            )
        }

        XCTAssertThrowsError(
            try R12VerifiedChunk.makeCanonicalArtifactData(
                mediaPayload: Data([0xA5]),
                boundary: boundary,
                header: header
            )
        ) { error in
            XCTAssertEqual(
                error as? R12ChunkCheckpointError,
                .artifactSizeMismatch(path: "canonical-media-envelope")
            )
        }
    }

    func testPinnedTransactionRejectsOutOfRootWithoutDescriptorLeak() async throws {
        try await withRoots(count: 1) { roots in
            let root = roots[0]
            let fileSystem = R12LocalCheckpointFileSystem()
            try fileSystem.ensureDirectory(root)
            let lockURL = root.appendingPathComponent("test.lock")
            try fileSystem.withExclusiveLock(at: lockURL) { transaction in
                let countBefore = Self.openDescriptorCount()
                for index in 0..<32 {
                    let outside = root.deletingLastPathComponent()
                        .appendingPathComponent("outside-\(index)")
                    XCTAssertThrowsError(
                        try transaction.ensureDirectory(outside)
                    )
                }
                XCTAssertEqual(
                    Self.openDescriptorCount(),
                    countBefore
                )
            }
        }
    }

    func testPinnedRootReplacementDuringCreateCommitsNeitherRoot() async throws {
        try await withRoots(count: 1) { roots in
            let configuredRoot = roots[0]
            let displacedRoot = configuredRoot.deletingLastPathComponent()
                .appendingPathComponent("displaced-create-root")
            let replacementRoot = configuredRoot.deletingLastPathComponent()
                .appendingPathComponent("replacement-create-root")
            try FileManager.default.createDirectory(
                at: replacementRoot,
                withIntermediateDirectories: true
            )
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            let store = R12ChunkCheckpointStore(
                rootURL: configuredRoot,
                fileSystem: fileSystem
            )
            hook.arm(point: .afterCreateRename) { _ in
                try Self.replaceConfiguredRoot(
                    configuredRoot,
                    displacedRoot: displacedRoot,
                    replacementRoot: replacementRoot
                )
            }
            await XCTAssertThrowsErrorAsync(
                try await store.create(header: try makeHeader())
            )
            XCTAssertFalse(
                Self.ledgerExists(at: configuredRoot)
            )
            XCTAssertFalse(
                Self.ledgerExists(at: displacedRoot)
            )
        }
    }

    func testPinnedRootReplacementDuringAppendRollsBackOriginalLedger() async throws {
        try await withRoots(count: 1) { roots in
            let configuredRoot = roots[0]
            let displacedRoot = configuredRoot.deletingLastPathComponent()
                .appendingPathComponent("displaced-append-root")
            let replacementRoot = configuredRoot.deletingLastPathComponent()
                .appendingPathComponent("replacement-append-root")
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: configuredRoot,
                fileSystem: fileSystem
            )
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: configuredRoot,
                index: 0,
                payload: Data("root-race".utf8),
                header: header
            )
            let priorLedger = try await store.canonicalLedgerData()
            try FileManager.default.createDirectory(
                at: replacementRoot,
                withIntermediateDirectories: true
            )
            hook.arm(point: .afterReplaceSwap) { _ in
                try Self.replaceConfiguredRoot(
                    configuredRoot,
                    displacedRoot: displacedRoot,
                    replacementRoot: replacementRoot
                )
            }
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
            XCTAssertFalse(Self.ledgerExists(at: configuredRoot))
            XCTAssertEqual(
                try Self.ledgerData(at: displacedRoot),
                priorLedger
            )
            let recovered = R12ChunkCheckpointStore(rootURL: displacedRoot)
            let recoveredCursor = try await recovered.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(
                recoveredCursor,
                cursor
            )
        }
    }

    func testPinnedRootReplacementDuringReopenFailsWithoutMutation() async throws {
        try await withRoots(count: 1) { roots in
            let configuredRoot = roots[0]
            let displacedRoot = configuredRoot.deletingLastPathComponent()
                .appendingPathComponent("displaced-reopen-root")
            let replacementRoot = configuredRoot.deletingLastPathComponent()
                .appendingPathComponent("replacement-reopen-root")
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: configuredRoot,
                fileSystem: fileSystem
            )
            let cursor = try await store.create(header: header)
            let priorLedger = try await store.canonicalLedgerData()
            try FileManager.default.createDirectory(
                at: replacementRoot,
                withIntermediateDirectories: true
            )
            hook.arm(point: .beforeReadPathResnapshot) { _ in
                try Self.replaceConfiguredRoot(
                    configuredRoot,
                    displacedRoot: displacedRoot,
                    replacementRoot: replacementRoot
                )
            }
            await XCTAssertThrowsErrorAsync(
                try await store.reopen(
                    expecting: R12ResumeExpectation(
                        header: header,
                        expectedHeadSHA256: cursor.headSHA256
                    )
                )
            )
            XCTAssertFalse(Self.ledgerExists(at: configuredRoot))
            XCTAssertEqual(
                try Self.ledgerData(at: displacedRoot),
                priorLedger
            )
        }
    }

    func testLockPathReplacementRollsBackPinnedTransaction() async throws {
        try await withRoots(count: 1) { roots in
            let root = roots[0]
            let lockURL = root.appendingPathComponent(
                ".checkpoint-ledger-v1.lock"
            )
            let displacedLock = root.appendingPathComponent(
                "displaced-ledger.lock"
            )
            let hook = R12FileSystemHookController()
            let fileSystem = R12LocalCheckpointFileSystem(
                operationHook: {
                    try hook.invoke(point: $0, url: $1)
                }
            )
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: root,
                fileSystem: fileSystem
            )
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: root,
                index: 0,
                payload: Data("lock-race".utf8),
                header: header
            )
            let priorLedger = try await store.canonicalLedgerData()
            hook.arm(point: .afterReplaceSwap) { _ in
                try FileManager.default.moveItem(
                    at: lockURL,
                    to: displacedLock
                )
                guard FileManager.default.createFile(
                    atPath: lockURL.path,
                    contents: Data()
                ) else {
                    throw R12ChunkCheckpointError.atomicWriteFailed
                }
            }
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
            XCTAssertEqual(
                try Self.ledgerData(at: root),
                priorLedger
            )
            let reopened = try await R12ChunkCheckpointStore(
                rootURL: root
            ).reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, cursor)
        }
    }

    func testMaximumLedgerOverrideCannotWidenProductionReadCap() async throws {
        try await withRoots(count: 1) { roots in
            let fileSystem = CountingR12CheckpointFileSystem()
            let header = try makeHeader()
            let store = R12ChunkCheckpointStore(
                rootURL: roots[0],
                fileSystem: fileSystem,
                maximumLedgerBytes: Int.max
            )
            let cursor = try await store.create(header: header)
            fileSystem.resetReads()
            _ = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            let ledgerReads = fileSystem.readObservations.filter {
                $0.path.hasSuffix("checkpoint-ledger-v1.json")
            }
            XCTAssertEqual(ledgerReads.count, 1)
            XCTAssertEqual(
                ledgerReads.first?.maximumBytes,
                16 * 1_024 * 1_024
            )
        }
    }

    func testLedgerLimitRejectsCreateAndAppendBeforePublication() async throws {
        try await withRoots(count: 2) { roots in
            let header = try makeHeader()
            let probe = R12ChunkCheckpointStore(
                rootURL: roots[0],
                maximumLedgerBytes: 1
            )
            var emptyLedgerByteCount = 0
            await XCTAssertThrowsErrorAsync(
                try await probe.create(header: header)
            ) { error in
                guard let checkpointError =
                        error as? R12ChunkCheckpointError,
                      case .ledgerSizeLimitExceeded(
                        let observed,
                        let maximum
                      ) = checkpointError else {
                    return XCTFail(
                        "Expected ledger size limit, received \(error)"
                    )
                }
                emptyLedgerByteCount = observed
                XCTAssertEqual(maximum, 1)
            }
            XCTAssertGreaterThan(emptyLedgerByteCount, 1)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: roots[0]
                        .appendingPathComponent("checkpoint-ledger-v1.json")
                        .path
                )
            )

            let store = R12ChunkCheckpointStore(
                rootURL: roots[1],
                maximumLedgerBytes: emptyLedgerByteCount
            )
            let cursor = try await store.create(header: header)
            let chunk = try makeChunk(
                root: roots[1],
                index: 0,
                payload: Data("bounded-ledger".utf8),
                header: header
            )
            await XCTAssertThrowsErrorAsync(
                try await store.appendVerified(
                    chunk,
                    expectedHeadSHA256: cursor.headSHA256
                )
            ) { error in
                guard let checkpointError =
                        error as? R12ChunkCheckpointError,
                      case .ledgerSizeLimitExceeded(
                        let observed,
                        let maximum
                      ) = checkpointError else {
                    return XCTFail(
                        "Expected append ledger limit, received \(error)"
                    )
                }
                XCTAssertGreaterThan(observed, maximum)
                XCTAssertEqual(maximum, emptyLedgerByteCount)
            }
            let sealedDirectory = roots[1].appendingPathComponent(
                ".r12-checkpoint-artifacts-v1"
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: sealedDirectory.path
                ),
                []
            )
            let reopened = try await store.reopen(
                expecting: R12ResumeExpectation(
                    header: header,
                    expectedHeadSHA256: cursor.headSHA256
                )
            )
            XCTAssertEqual(reopened, cursor)
        }
    }

    func testConfiguredRootSymlinkIsRejectedWithoutResolution() async throws {
        try await withRoots(count: 1) { roots in
            let actual = roots[0]
            try FileManager.default.createDirectory(
                at: actual,
                withIntermediateDirectories: true
            )
            let configured = actual.deletingLastPathComponent()
                .appendingPathComponent("configured-root-link")
            try FileManager.default.createSymbolicLink(
                at: configured,
                withDestinationURL: actual
            )
            let store = R12ChunkCheckpointStore(rootURL: configured)
            await XCTAssertThrowsErrorAsync(
                try await store.create(header: try makeHeader())
            ) { error in
                guard let checkpointError =
                        error as? R12ChunkCheckpointError,
                      case .unsafeFilesystemEntry = checkpointError else {
                    return XCTFail(
                        "Expected configured-root symlink rejection, received \(error)"
                    )
                }
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: actual
                        .appendingPathComponent("checkpoint-ledger-v1.json")
                        .path
                )
            )
        }
    }

    func testConfiguredIntermediateSymlinkIsRejectedWithoutResolution() async throws {
        try await withRoots(count: 1) { roots in
            let actual = roots[0].appendingPathComponent("actual")
            let nested = actual.appendingPathComponent("nested")
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            let intermediateLink = roots[0].appendingPathComponent(
                "configured-intermediate-link"
            )
            try FileManager.default.createSymbolicLink(
                at: intermediateLink,
                withDestinationURL: actual
            )
            let configured = intermediateLink.appendingPathComponent("nested")
            let store = R12ChunkCheckpointStore(rootURL: configured)
            await XCTAssertThrowsErrorAsync(
                try await store.create(header: try makeHeader())
            ) { error in
                guard let checkpointError =
                        error as? R12ChunkCheckpointError,
                      case .unsafeFilesystemEntry = checkpointError else {
                    return XCTFail(
                        "Expected intermediate symlink rejection, received \(error)"
                    )
                }
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: nested
                        .appendingPathComponent("checkpoint-ledger-v1.json")
                        .path
                )
            )
        }
    }

    func testVerificationScopeIsDeterministicEnvelopeNotNativeMedia() {
        XCTAssertEqual(
            R12VerifiedChunk.verificationScope,
            "deterministic_canonical_envelope_v1_not_native_media_observation"
        )
        XCTAssertTrue(
            R12VerifiedChunk.verificationScope.contains(
                "not_native_media_observation"
            )
        )
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
        let parent = try trustedTemporaryDirectory().appendingPathComponent(
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

    private static func replaceConfiguredRoot(
        _ configuredRoot: URL,
        displacedRoot: URL,
        replacementRoot: URL
    ) throws {
        try FileManager.default.moveItem(
            at: configuredRoot,
            to: displacedRoot
        )
        try FileManager.default.moveItem(
            at: replacementRoot,
            to: configuredRoot
        )
    }

    private static func ledgerExists(at root: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: root
                .appendingPathComponent("checkpoint-ledger-v1.json")
                .path
        )
    }

    private static func ledgerData(at root: URL) throws -> Data {
        try Data(
            contentsOf: root.appendingPathComponent(
                "checkpoint-ledger-v1.json"
            )
        )
    }

    private static func openDescriptorCount() -> Int {
        var count = 0
        for rawDescriptor in 0..<Int(getdtablesize()) {
            var metadata = stat()
            if fstat(Int32(rawDescriptor), &metadata) == 0 {
                count += 1
            }
        }
        return count
    }

    private static func overwriteContentsPreservingInode(
        at url: URL,
        repeating byte: UInt8
    ) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw NSError(
                domain: "R12ChunkCheckpointLedgerTests",
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0 else {
            throw NSError(
                domain: "R12ChunkCheckpointLedgerTests",
                code: 1,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        let replacement = Data(
            repeating: byte,
            count: Int(before.st_size)
        )
        try replacement.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw NSError(
                    domain: "R12ChunkCheckpointLedgerTests",
                    code: 2,
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
            var offset = 0
            while offset < rawBuffer.count {
                let amount = pwrite(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset,
                    off_t(offset)
                )
                guard amount > 0 else {
                    throw NSError(
                        domain: "R12ChunkCheckpointLedgerTests",
                        code: Int(errno),
                        userInfo: [NSFilePathErrorKey: url.path]
                    )
                }
                offset += amount
            }
        }
        let timestamps = [
            before.st_atimespec,
            before.st_mtimespec
        ]
        let timestampResult = timestamps.withUnsafeBufferPointer {
            futimens(descriptor, $0.baseAddress)
        }
        guard timestampResult == 0, fsync(descriptor) == 0 else {
            throw NSError(
                domain: "R12ChunkCheckpointLedgerTests",
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw NSError(
                domain: "R12ChunkCheckpointLedgerTests",
                code: 3,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
        let changeTimeChanged =
            before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
                || before.st_ctimespec.tv_nsec
                    != after.st_ctimespec.tv_nsec
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_mode == after.st_mode,
              before.st_nlink == after.st_nlink,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              changeTimeChanged else {
            throw NSError(
                domain: "R12ChunkCheckpointLedgerTests",
                code: 3,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }

    /// XCTest may expose the trusted system temporary directory through
    /// `/var`, which is a symlink to `/private/var` on macOS. Resolve only
    /// this OS-owned, already-existing base before creating test fixtures so
    /// the production store can continue rejecting configured symlink roots.
    private func trustedTemporaryDirectory() throws -> URL {
        let exposedDirectory = FileManager.default.temporaryDirectory
        var resolvedPath = [CChar](
            repeating: 0,
            count: Int(PATH_MAX)
        )
        let resolved = exposedDirectory.path.withCString { sourcePath in
            realpath(sourcePath, &resolvedPath)
        }
        guard resolved != nil else {
            let errorNumber = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorNumber),
                userInfo: [NSFilePathErrorKey: exposedDirectory.path]
            )
        }
        return URL(
            fileURLWithPath: String(cString: resolvedPath),
            isDirectory: true
        )
    }

    private func makeHeader(
        jobID: String = "job-fixture",
        trackLayout: [R12TrackIdentity]? = nil,
        maximumArtifactBytes: UInt64 = 64 * 1_024 * 1_024
    ) throws -> R12ChunkLedgerHeader {
        let layout = try trackLayout ?? [
            R12TrackIdentity(trackID: "video-0", kind: .video),
            R12TrackIdentity(trackID: "audio-0", kind: .audio),
            R12TrackIdentity(trackID: "subtitle-0", kind: .subtitle),
            R12TrackIdentity(
                trackID: "metadata-0",
                kind: .timedMetadata
            )
        ]
        let zero = try R12MediaTime(value: 0, timescale: 1)
        return try R12ChunkLedgerHeader(
            sourceIdentitySHA256: hash("1"),
            jobID: jobID,
            formatContractSHA256: hash("2"),
            routeIdentity: "route-fixture",
            hardwareTierIdentity: "tier-fixture",
            executionIdentity: "execution-fixture",
            chunkPolicyIdentity: "closed-sync-boundaries-v1",
            trackLayout: layout,
            initialTrackWatermarks: try layout.map {
                try R12TrackWatermark(
                    trackID: $0.trackID,
                    kind: $0.kind,
                    nextSampleIndex: 0,
                    time: zero
                )
            },
            initialBackendState: .resetAtBoundary(
                resetIdentity: "fixture-reset-v1"
            ),
            artifactPolicy: try R12ChunkArtifactPolicy(
                maximumArtifactBytes: maximumArtifactBytes
            )
        )
    }

    private func makeChunk(
        root: URL,
        index: Int,
        payload: Data,
        relativePath: String? = nil,
        boundary: R12SafeMediaBoundary? = nil,
        header: R12ChunkLedgerHeader? = nil
    ) throws -> R12VerifiedChunk {
        let verifiedHeader = try header ?? makeHeader()
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
        let artifactData = try R12VerifiedChunk.makeCanonicalArtifactData(
            mediaPayload: payload,
            boundary: verifiedBoundary,
            header: verifiedHeader
        )
        try artifactData.write(to: artifactURL)
        return try R12VerifiedChunk.verifyCanonicalArtifact(
            rootURL: root,
            relativePath: artifactPath,
            header: verifiedHeader,
            expectedArtifactSHA256:
                R12CryptoKitDigest().sha256(artifactData)
        )
    }

    private func makeBoundary(
        index: Int,
        audioTrackID: String = "audio-0",
        audioKind: R12TrackKind = .audio,
        audioNextSampleIndex: Int? = nil,
        includeAudio: Bool = true,
        backendStartState: R12BackendBoundaryState = .resetAtBoundary(
            resetIdentity: "fixture-reset-v1"
        ),
        backendState: R12BackendBoundaryState = .resetAtBoundary(
            resetIdentity: "fixture-reset-v1"
        )
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
        watermarks.append(
            try R12TrackWatermark(
                trackID: "subtitle-0",
                kind: .subtitle,
                nextSampleIndex: index + 1,
                time: end
            )
        )
        watermarks.append(
            try R12TrackWatermark(
                trackID: "metadata-0",
                kind: .timedMetadata,
                nextSampleIndex: (index + 1) * 2,
                time: end
            )
        )
        return try R12SafeMediaBoundary(
            start: start,
            endExclusive: end,
            firstVideoSampleIndex: index * 10,
            nextVideoSampleIndex: nextSample,
            nextSampleIsSync: true,
            trackWatermarks: watermarks,
            backendStartState: backendStartState,
            backendState: backendState
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
                ),
                try R12TrackWatermark(
                    trackID: "subtitle-0",
                    kind: .subtitle,
                    nextSampleIndex: 2,
                    time: end
                ),
                try R12TrackWatermark(
                    trackID: "metadata-0",
                    kind: .timedMetadata,
                    nextSampleIndex: 4,
                    time: end
                )
            ],
            backendStartState: .resetAtBoundary(
                resetIdentity: "fixture-reset-v1"
            ),
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

private struct R12UnexpectedDigest: R12Digesting {
    func sha256(_ data: Data) -> String {
        XCTFail("Oversized payload must be rejected before digest or encoding.")
        return String(repeating: "a", count: 64)
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

private struct R12ReadObservation: Equatable {
    let path: String
    let maximumBytes: Int
}

private final class R12CountingFileSystemState: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [R12ReadObservation] = []

    var readObservations: [R12ReadObservation] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }

    func resetReads() {
        lock.lock()
        observations.removeAll()
        lock.unlock()
    }

    func record(_ observation: R12ReadObservation) {
        lock.lock()
        observations.append(observation)
        lock.unlock()
    }
}

private final class CountingR12CheckpointFileSystem:
    R12CheckpointFileSystem,
    @unchecked Sendable {
    private let state: R12CountingFileSystemState
    private let backing: any R12CheckpointFileSystem

    init() {
        self.state = R12CountingFileSystemState()
        self.backing = R12LocalCheckpointFileSystem()
    }

    private init(
        state: R12CountingFileSystemState,
        backing: any R12CheckpointFileSystem
    ) {
        self.state = state
        self.backing = backing
    }

    var readObservations: [R12ReadObservation] {
        state.readObservations
    }

    func resetReads() {
        state.resetReads()
    }

    func ensureDirectory(_ url: URL) throws {
        try backing.ensureDirectory(url)
    }

    func validateDirectory(_ url: URL) throws {
        try backing.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        backing.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        state.record(
            R12ReadObservation(
                path: url.path,
                maximumBytes: maximumBytes
            )
        )
        return try backing.readRegularFile(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try backing.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        try backing.replaceAtomically(data, at: url)
    }

    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (
            _ transactionFileSystem: any R12CheckpointFileSystem
        ) throws -> T
    ) throws -> T {
        try backing.withExclusiveLock(at: url) { transactionBacking in
            try operation(
                CountingR12CheckpointFileSystem(
                    state: state,
                    backing: transactionBacking
                )
            )
        }
    }
}

private final class R12DirectorySyncController: @unchecked Sendable {
    private let lock = NSLock()
    private var successfulCallsBeforeFailure: Int?
    private var failedDescriptor: Int32?

    var mostRecentFailedDescriptor: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return failedDescriptor
    }

    func failAfterSuccessfulCalls(_ count: Int) {
        lock.lock()
        successfulCallsBeforeFailure = count
        failedDescriptor = nil
        lock.unlock()
    }

    func synchronize(descriptor: Int32, url: URL) throws {
        let fail: Bool
        lock.lock()
        if let remaining = successfulCallsBeforeFailure {
            if remaining == 0 {
                successfulCallsBeforeFailure = nil
                failedDescriptor = descriptor
                fail = true
            } else {
                successfulCallsBeforeFailure = remaining - 1
                fail = false
            }
        } else {
            fail = false
        }
        lock.unlock()
        if fail {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        guard fsync(descriptor) == 0 else {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
    }
}

private final class R12FileSystemHookController: @unchecked Sendable {
    typealias Action = @Sendable (URL) throws -> Void

    private let lock = NSLock()
    private var armedPoint: R12CheckpointFileSystemHookPoint?
    private var action: Action?

    func arm(
        point: R12CheckpointFileSystemHookPoint,
        action: @escaping Action
    ) {
        lock.lock()
        armedPoint = point
        self.action = action
        lock.unlock()
    }

    func invoke(
        point: R12CheckpointFileSystemHookPoint,
        url: URL
    ) throws {
        let selectedAction: Action?
        lock.lock()
        if armedPoint == point {
            selectedAction = action
            armedPoint = nil
            action = nil
        } else {
            selectedAction = nil
        }
        lock.unlock()
        try selectedAction?(url)
    }
}

private final class FailingR12CheckpointFileSystem:
    R12CheckpointFileSystem,
    @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replacementFailureArmed = false

        var failNextReplacement: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return replacementFailureArmed
            }
            set {
                lock.lock()
                replacementFailureArmed = newValue
                lock.unlock()
            }
        }

        func consumeReplacementFailure() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard replacementFailureArmed else {
                return false
            }
            replacementFailureArmed = false
            return true
        }
    }

    private let state: State
    private let backing: any R12CheckpointFileSystem

    init() {
        self.state = State()
        self.backing = R12LocalCheckpointFileSystem()
    }

    private init(
        state: State,
        backing: any R12CheckpointFileSystem
    ) {
        self.state = state
        self.backing = backing
    }

    var failNextReplacement: Bool {
        get { state.failNextReplacement }
        set { state.failNextReplacement = newValue }
    }

    func ensureDirectory(_ url: URL) throws {
        try backing.ensureDirectory(url)
    }

    func validateDirectory(_ url: URL) throws {
        try backing.validateDirectory(url)
    }

    func exists(_ url: URL) -> Bool {
        backing.exists(url)
    }

    func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try backing.readRegularFile(url, maximumBytes: maximumBytes)
    }

    func writeNewAtomically(_ data: Data, to url: URL) throws {
        try backing.writeNewAtomically(data, to: url)
    }

    func replaceAtomically(_ data: Data, at url: URL) throws {
        if state.consumeReplacementFailure() {
            throw R12ChunkCheckpointError.atomicWriteFailed
        }
        try backing.replaceAtomically(data, at: url)
    }

    func withExclusiveLock<T>(
        at url: URL,
        _ operation: (
            _ transactionFileSystem: any R12CheckpointFileSystem
        ) throws -> T
    ) throws -> T {
        try backing.withExclusiveLock(at: url) { transactionBacking in
            try operation(
                FailingR12CheckpointFileSystem(
                    state: state,
                    backing: transactionBacking
                )
            )
        }
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
