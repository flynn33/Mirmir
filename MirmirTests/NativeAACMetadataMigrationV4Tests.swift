import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import XCTest
@testable import Mirmir

@MainActor
final class NativeAACMetadataMigrationV4Tests: XCTestCase {
    func testPreservesCompleteITunesMetadataForMOVMP4AndM4V() async throws {
        for name in ["priming1024.mov", "priming1024.mp4", "priming1024.m4v",
                     "no-smpb.mov", "no-smpb.mp4", "no-smpb.m4v"] {
            let source = try fixture(name)
            let before = try Data(contentsOf: source)
            let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: AVURLAsset(url: source))
            let plan = try MediaTrackGraphPlannerV4.makePlan(source: graph)
            let output = try temporaryOutput()
            let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
                sourceURL: source, destinationURL: output, sourceGraph: graph,
                identifiedPlan: plan,
                blueprint: AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: graph, plan: plan)))
            XCTAssertTrue(result.verificationReport.isConformant)
            XCTAssertNil(result.aacGaplessMetadataTranslation)
            XCTAssertEqual(result.sourceAssetMetadataSHA256, result.outputAssetMetadataSHA256)
            XCTAssertTrue(result.trackResults.allSatisfy {
                $0.sourceSampleStreamSHA256 != nil && $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
            })
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.originalEntries(in: source),
                try MOViTunesGaplessMetadataV4.originalEntries(in: output))
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: source),
                try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: output))
            XCTAssertEqual(try Data(contentsOf: source), before)
            let verification = try WorkflowApplicationMigrationVerificationV4(result)
            XCTAssertEqual(verification.schemaVersion, 1)
            let encoded = try WorkflowCanonicalCodec().canonicalData(verification)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("aacGaplessMetadataTranslation"))
        }
    }

    func testLargeOriginalFreeformValueSurvivesRealNativeMigration() async throws {
        func box(_ type: String, _ body: Data) -> Data {
            var size = UInt32(body.count + 8).bigEndian
            return withUnsafeBytes(of: &size) { Data($0) } + Data(type.utf8) + body
        }
        let value = Data(repeating: 88, count: 1_200_000)
        let entry = box("----", box("mean", Data(repeating: 0, count: 4) + Data("com.example.qualification".utf8))
            + box("name", Data(repeating: 0, count: 4) + Data("LargeUserNote".utf8))
            + box("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + value))
        let handler = box("hdlr", Data(repeating: 0, count: 8) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9))
        let seed = try temporaryOutput()
        try box("moov", box("udta", box("meta", Data(repeating: 0, count: 4)
            + handler + box("ilst", entry)))).write(to: seed)
        let source = try temporaryOutput()
        try FileManager.default.copyItem(at: fixture("priming1024.mov"), to: source)
        XCTAssertTrue(try MOViTunesGaplessMetadataV4.insertIfMissing(
            MOViTunesGaplessMetadataV4.originalFreeformEntries(in: seed), into: source))
        let asset = AVURLAsset(url: source)
        let items = try await asset.load(.metadata)
        let originalItem = try XCTUnwrap(items.first {
            $0.identifier?.rawValue == "itlk/com.example.qualification.LargeUserNote"
        })
        let originalValue = try await originalItem.load(.stringValue)
        XCTAssertEqual(originalValue?.utf8.count, value.count)
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: graph)
        let output = try temporaryOutput()
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: source, destinationURL: output, sourceGraph: graph,
            identifiedPlan: plan,
            blueprint: AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: graph, plan: plan)))
        XCTAssertEqual(result.sourceAssetMetadataSHA256, result.outputAssetMetadataSHA256)
        XCTAssertEqual(try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: source),
            try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: output))
        XCTAssertTrue(result.trackResults.allSatisfy {
            $0.sourceSampleStreamSHA256 != nil && $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
        })
    }

    func testAACTranslationPreservesPCMPlayerAndRawClocksWithLeadingAndInternalEmptyEdits() async throws {
        for (name, firstMedia, valid, appended, editCount) in [
            ("priming1024.mov", UInt64(2112), UInt64(144000), UInt64(144000), 1),
            ("leading-empty.mov", 14112, 144000, 156000, 2),
            ("internal-empty.mov", 2112, 156000, 156000, 3)
        ] {
            let source = try fixture(name)
            let result = try await transcode(source)
            let proof = try XCTUnwrap(result.aacGaplessMetadataTranslation)
            XCTAssertEqual(proof.encoderPrimingFrameCount, 2112)
            XCTAssertEqual(proof.firstMediaFrame, firstMedia)
            XCTAssertEqual(proof.validFrameCount, valid)
            XCTAssertEqual(proof.appendedPCMFrameCount, appended)
            XCTAssertEqual(proof.packetTable.edits.count, editCount)
            XCTAssertEqual(proof.firstMediaFrame + proof.validFrameCount + proof.remainderFrameCount,
                proof.packetTable.packetCount * UInt64(proof.framesPerPacket))
            try await proof.verifyMetadata(sourceURL: source, outputURL: result.destinationURL)
            XCTAssertNotEqual(result.sourceAssetMetadataSHA256, result.outputAssetMetadataSHA256)
            let verification = try WorkflowApplicationMigrationVerificationV4(result)
            XCTAssertEqual(verification.schemaVersion, 2)
            XCTAssertTrue(try verification.metadataIsConformant())
            let encoded = try WorkflowCanonicalCodec().canonicalData(verification)
            XCTAssertEqual(try WorkflowCanonicalCodec().decodeCanonical(
                WorkflowApplicationMigrationVerificationV4.self, from: encoded), verification)

            // This independent AVMutableMovie rewrite deliberately omits the
            // technical tag, yielding the unhinted encoded-media control.
            let control = try temporaryOutput()
            try FileManager.default.copyItem(at: result.destinationURL, to: control)
            let movie = AVMutableMovie(url: control,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            try movie.writeHeader(to: control, fileType: .mov, options: .addMovieHeaderToDestination)
            XCTAssertTrue(try MOViTunesGaplessMetadataV4.originalEntries(in: control).isEmpty)
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.audioPacketTable(in: control,
                trackOrdinal: proof.outputTrackOrdinal), proof.packetTable)
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: control,
                trackOrdinal: proof.outputTrackOrdinal), proof.encodedAudioPayloadSHA256.rawValue)
            let actualPCM = try await pcm(result.destinationURL)
            let controlPCM = try await pcm(control)
            XCTAssertEqual(actualPCM, controlPCM)
            XCTAssertEqual(actualPCM.frames, appended)
            let actualPlayer = try await playerFacts(result.destinationURL)
            let controlPlayer = try await playerFacts(control)
            XCTAssertEqual(actualPlayer, controlPlayer)
            XCTAssertEqual(actualPlayer.duration, appended == 144000 ? 3 : 3.25)
        }
    }

    func testAudioTranscodeWithoutOriginalSMPBDoesNotInventMetadata() async throws {
        let source = try fixture("no-smpb.mov")
        let result = try await transcode(source)
        XCTAssertNil(result.aacGaplessMetadataTranslation)
        XCTAssertEqual(result.sourceAssetMetadataSHA256, result.outputAssetMetadataSHA256)
        XCTAssertTrue(try MOViTunesGaplessMetadataV4.originalEntries(in: result.destinationURL).isEmpty)
        XCTAssertEqual(try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: source),
            try MOViTunesGaplessMetadataV4.originalFreeformEntries(in: result.destinationURL))
        let verification = try WorkflowApplicationMigrationVerificationV4(result)
        XCTAssertEqual(verification.schemaVersion, 1)
        let facts = try await playerFacts(result.destinationURL)
        XCTAssertEqual(facts.duration, 3)
        XCTAssertEqual(facts.lastSeek, 3)
    }

    func testDroppingAudioRetainsOriginalMetadataAndVideoPlayback() async throws {
        for name in ["priming1024.mov", "leading-empty.mov", "internal-empty.mov", "audio-longer.mov"] {
            let source = try fixture(name)
            let result = try await dropAudio(source)
            XCTAssertNil(result.aacGaplessMetadataTranslation)
            XCTAssertEqual(result.sourceAssetMetadataSHA256, result.outputAssetMetadataSHA256)
            let tracks = try await AVURLAsset(url: result.destinationURL).loadTracks(withMediaType: .audio)
            XCTAssertTrue(tracks.isEmpty)
            let facts = try await playerFacts(result.destinationURL)
            XCTAssertEqual(facts.duration, 3)
            XCTAssertEqual(facts.lastSeek, 3)
            XCTAssertEqual(try MOViTunesGaplessMetadataV4.originalEntries(in: source),
                try MOViTunesGaplessMetadataV4.originalEntries(in: result.destinationURL))
            XCTAssertTrue(result.trackResults.allSatisfy {
                $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
            })
        }
    }

    func testForgedRehashedTranslationCannotChangePlanHintCountsDigestOrMetadata() async throws {
        let source = try fixture("priming1024.mov")
        let result = try await transcode(source)
        let proof = try XCTUnwrap(result.aacGaplessMetadataTranslation)
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as! [String: Any]
        for (key, value) in [
            ("outputTrackOrdinal", 0 as Any),
            ("encoderPrimingFrameCount", 1024),
            ("firstMediaFrame", 1024),
            ("validFrameCount", 143999),
            ("appendedPCMFrameCount", 143999),
            ("remainderFrameCount", 321),
            ("outputValue", proof.sourceValue),
            ("schemaID", "ash.aac-gapless-metadata-translation.unknown")
        ] {
            var changed = original; changed[key] = value
            let forged = try JSONDecoder().decode(AACGaplessMetadataTranslationV4.self,
                from: JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]))
            XCTAssertThrowsError(try forged.validate(), key)
        }
        for key in ["encodedAudioPayloadSHA256", "sourceEntrySHA256", "outputEntrySHA256",
                    "sourceAssetMetadataSHA256", "outputAssetMetadataSHA256"] {
            var changed = original; changed[key] = String(repeating: "0", count: 64)
            let forged = try JSONDecoder().decode(AACGaplessMetadataTranslationV4.self,
                from: JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]))
            do {
                try await forged.verifyMetadata(sourceURL: source, outputURL: result.destinationURL)
                XCTFail("Forged bound digest accepted: \(key)")
            } catch { }
        }
        let sourceGraph = try await AVFoundationTrackGraphAdapterV4.probe(asset: AVURLAsset(url: source))
        let wrongPlan = try MediaTrackGraphPlannerV4.makePlan(source: sourceGraph)
        var changed = original
        changed["identifiedPlan"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wrongPlan))
        let forged = try JSONDecoder().decode(AACGaplessMetadataTranslationV4.self,
            from: JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys]))
        XCTAssertThrowsError(try forged.validate())

        let verification = try WorkflowApplicationMigrationVerificationV4(result)
        var queueObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(verification)) as! [String: Any]
        queueObject["schemaVersion"] = 1
        let wrongVersion = try JSONDecoder().decode(WorkflowApplicationMigrationVerificationV4.self,
            from: JSONSerialization.data(withJSONObject: queueObject, options: [.sortedKeys]))
        XCTAssertFalse(try wrongVersion.metadataIsConformant())
        queueObject["schemaVersion"] = 2; queueObject.removeValue(forKey: "aacGaplessMetadataTranslation")
        let missingProof = try JSONDecoder().decode(WorkflowApplicationMigrationVerificationV4.self,
            from: JSONSerialization.data(withJSONObject: queueObject, options: [.sortedKeys]))
        XCTAssertFalse(try missingProof.metadataIsConformant())
    }

    private func fixture(_ name: String) throws -> URL {
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "NativeAACMetadata", withExtension: nil))
        return folder.appendingPathComponent(name)
    }

    private func temporaryOutput() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirmir-native-aac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("output.mov")
    }

    private func transcode(_ source: URL) async throws -> AVFoundationTrackMigrationExecutionResultV4 {
        let asset = AVURLAsset(url: source)
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: asset)
        let audio = try XCTUnwrap(graph.tracks.first { $0.kind == .audio })
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        let sourceAudio = try XCTUnwrap(sourceAudioTracks.first)
        let calibration = try await AVFoundationAACFormatCalibratorV4().calibrate(
            asset: asset, track: sourceAudio, trackID: audio.identity.stableID)
        let base = try MediaTrackGraphPlannerV4.makePlan(source: graph, request: .init(
            trackDirectives: [MediaTrackDirectiveV4(trackID: audio.identity.stableID,
                action: .transcode, targetFormatDescriptors: [calibration.targetFormat], dropConsent: nil)]))
        let plan = try base.applyingTranscodePrimingDurations([
            audio.identity.stableID: calibration.encoderPrimingDuration])
        return try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: source, destinationURL: temporaryOutput(), sourceGraph: graph,
            identifiedPlan: plan,
            blueprint: AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: graph, plan: plan),
            nonVideoTranscodeHooks: [calibration.hook]))
    }

    private func dropAudio(_ source: URL) async throws -> AVFoundationTrackMigrationExecutionResultV4 {
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(asset: AVURLAsset(url: source))
        let audio = try XCTUnwrap(graph.tracks.first { $0.kind == .audio })
        let approval = ASHSHA256V4(rawData: Data("qualification-drop-audio".utf8))
        let consent = try MediaTrackDropConsentV4(subjectID: audio.identity.stableID.rawValue,
            reasonID: "qualification-drop-audio", approvalSHA256: approval)
        let groups = try graph.groups.filter { $0.memberTrackIDs.contains(audio.identity.stableID) }.map { group in
            let members = group.memberTrackIDs.filter { $0 != audio.identity.stableID }
            return MediaTrackGroupDirectiveV4(groupID: group.identity.stableID,
                action: members.isEmpty ? .dropWithConsent : .transcode,
                outputMemberTrackIDs: members.isEmpty ? nil : members,
                outputDefaultTrackID: members.first,
                dropConsent: try MediaTrackDropConsentV4(subjectID: group.identity.stableID.rawValue,
                    reasonID: "qualification-drop-audio", approvalSHA256: approval))
        }
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: graph, request: .init(
            trackDirectives: [MediaTrackDirectiveV4(trackID: audio.identity.stableID,
                action: .dropWithConsent, targetFormatDescriptors: [], dropConsent: consent)], groupDirectives: groups))
        return try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: source, destinationURL: temporaryOutput(), sourceGraph: graph,
            identifiedPlan: plan,
            blueprint: AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: graph, plan: plan)))
    }

    private struct PCM: Equatable {
        let frames: UInt64
        let SHA256: String
        let firstPTS: CMTime
        let end: CMTime
    }

    private func pcm(_ url: URL) async throws -> PCM {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = try await track.load(.timeRange)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var digest = SHA256(); var frames: UInt64 = 0
        var first = CMTime.invalid; var end = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { continue }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let byteCount = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: byteCount)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, 0)
            digest.update(data: bytes); frames += UInt64(count)
            if !first.isValid { first = CMSampleBufferGetPresentationTimeStamp(sample) }
            end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample))
        }
        XCTAssertEqual(reader.status, .completed)
        return PCM(frames: frames, SHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            firstPTS: first, end: end)
    }

    private struct PlayerFacts: Equatable {
        let duration: Double
        let lastSeek: Double
    }

    private func playerFacts(_ url: URL) async throws -> PlayerFacts {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil) }
        for _ in 0..<500 where item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(item.status, .readyToPlay)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(item.duration.seconds, duration)
        let completed = await player.seek(to: CMTime(value: 10, timescale: 1),
            toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(completed)
        return PlayerFacts(duration: duration, lastSeek: player.currentTime().seconds)
    }
}
