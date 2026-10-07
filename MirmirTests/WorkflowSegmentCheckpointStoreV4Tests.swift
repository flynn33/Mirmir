import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import XCTest
#if canImport(Mirmir)
@testable import Mirmir
#endif

final class WorkflowSegmentCheckpointStoreV4Tests: XCTestCase {
    func testChapterMetadataTimesCompareExactValuesAcrossMovieClocks() throws {
        let sourceZero = CMTime(value: 0, timescale: 1)
        let remuxedZero = CMTime(value: 0, timescale: 500)
        XCTAssertEqual(
            try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(sourceZero),
            try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(remuxedZero)
        )
        XCTAssertEqual(
            try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(CMTime(value: 392_100, timescale: 1_000)),
            try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(CMTime(value: 196_050, timescale: 500))
        )
        XCTAssertNotEqual(
            try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(sourceZero),
            try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(CMTime(value: 1, timescale: 500))
        )
    }

    func testChapterMetadataTimeCanonicalizationRetainsFlagsEpochAndNonnumericTimes()
        throws {
        let rounded = CMTime(value: 0, timescale: 500, flags: [.valid, .hasBeenRounded], epoch: 7)
        let canonical = try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(rounded)
        XCTAssertEqual(canonical.value, 0)
        XCTAssertEqual(canonical.timescale, 1)
        XCTAssertEqual(canonical.flags, rounded.flags)
        XCTAssertEqual(canonical.epoch, rounded.epoch)
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            XCTAssertEqual(try AVFoundationTrackMigrationExecutorV4.canonicalChapterMetadataTime(time), time)
        }
    }

    func testCompressedAssemblyUsesExactDecodeCadenceWhenReaderDurationDiffersByOneTick()
        throws {
        let source = try assemblyTimingSample(pts: 221_471, dts: 210_210, duration: 3_753)
        let output = try assemblyTimingSample(pts: 221_471, dts: 210_210, duration: 3_754)
        let nextSource = try assemblyTimingSample(pts: 225_225, dts: 213_963, duration: 3_754)
        let nextOutput = try assemblyTimingSample(pts: 225_225, dts: 213_963, duration: 3_754)
        XCTAssertEqual(CMSampleBufferGetDuration(source), CMTime(value: 3_753, timescale: 90_000))
        XCTAssertEqual(CMSampleBufferGetDuration(output), CMTime(value: 3_754, timescale: 90_000))
        XCTAssertTrue(assemblyTimingMatches(source, output, nextSource: nextSource, nextOutput: nextOutput))
    }

    func testCompressedAssemblyRejectsChangedPresentationDecodeAndCadenceTiming()
        throws {
        let source = try assemblyTimingSample(pts: 221_471, dts: 210_210, duration: 3_753)
        let nextSource = try assemblyTimingSample(pts: 225_225, dts: 213_963, duration: 3_754)
        let output = try assemblyTimingSample(pts: 221_471, dts: 210_210, duration: 3_754)
        let nextOutput = try assemblyTimingSample(pts: 225_225, dts: 213_963, duration: 3_754)
        XCTAssertFalse(assemblyTimingMatches(source, try assemblyTimingSample(pts: 221_472, dts: 210_210, duration: 3_754), nextSource: nextSource, nextOutput: nextOutput))
        XCTAssertFalse(assemblyTimingMatches(source, try assemblyTimingSample(pts: 221_471, dts: 210_211, duration: 3_754), nextSource: nextSource, nextOutput: nextOutput))
        XCTAssertFalse(assemblyTimingMatches(source, output, nextSource: nextSource, nextOutput: try assemblyTimingSample(pts: 225_225, dts: 213_964, duration: 3_754)))
    }

    func testCompressedAssemblyRejectsChangedTerminalDurationAndInvalidDecodeCadence()
        throws {
        let source = try assemblyTimingSample(pts: 221_471, dts: 210_210, duration: 3_753)
        let output = try assemblyTimingSample(pts: 221_471, dts: 210_210, duration: 3_754)
        XCTAssertFalse(assemblyTimingMatches(source, output))
        let invalidSource = try assemblyTimingSample(pts: 221_471, dts: nil, duration: 3_753)
        let invalidOutput = try assemblyTimingSample(pts: 221_471, dts: nil, duration: 3_754)
        let invalidNext = try assemblyTimingSample(pts: 225_225, dts: nil, duration: 3_754)
        XCTAssertFalse(assemblyTimingMatches(invalidSource, invalidOutput, nextSource: invalidNext, nextOutput: invalidNext))
        XCTAssertFalse(assemblyTimingMatches(source, output, nextSource: invalidNext, nextOutput: invalidNext))
        let zeroCadence = try assemblyTimingSample(pts: 225_225, dts: 210_210, duration: 3_754)
        XCTAssertFalse(assemblyTimingMatches(source, output, nextSource: zeroCadence, nextOutput: zeroCadence))
        let negativeCadence = try assemblyTimingSample(pts: 225_225, dts: 210_209, duration: 3_754)
        XCTAssertFalse(assemblyTimingMatches(source, output, nextSource: negativeCadence, nextOutput: negativeCadence))
    }

    private func assemblyTimingMatches(
        _ source: CMSampleBuffer,
        _ output: CMSampleBuffer,
        nextSource: CMSampleBuffer? = nil,
        nextOutput: CMSampleBuffer? = nil
    ) -> Bool {
        var rawPresentationOffset: CMTime? = .zero
        var rawDecodeOffset: CMTime? = .zero
        return AVFoundationSegmentAssemblerV4.sampleTimingsMatch(
            source, output,
            nextSource: nextSource, nextOutput: nextOutput,
            logicalOffset: .zero,
            rawPresentationOffset: &rawPresentationOffset,
            rawDecodeOffset: &rawDecodeOffset,
            allowsIndependentDecodeRebasing: false
        )
    }

    private func assemblyTimingSample(
        pts: Int64,
        dts: Int64?,
        duration: Int64
    ) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 16, height: 16, extensions: nil,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(formatStatus, noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: 90_000),
            presentationTimeStamp: CMTime(value: pts, timescale: 90_000),
            decodeTimeStamp: dts.map { CMTime(value: $0, timescale: 90_000) } ?? .invalid
        )
        var sampleSize = 0
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try XCTUnwrap(format),
            sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sample)
    }

    func testSavedAssembledMovieHasCompleteCheckpointFrameCountWhenRequested()
        async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let checkpointPath = environment["MIRMIR_SAVED_ASSEMBLY_CHECKPOINT"],
              let outputPath = environment["MIRMIR_SAVED_ASSEMBLY_VERIFY_OUTPUT"],
              !checkpointPath.isEmpty, !outputPath.isEmpty else {
            throw XCTSkip("Set the saved checkpoint and verify-output paths to verify a completed replay.")
        }
        let checkpointURL = URL(fileURLWithPath: checkpointPath)
        let checkpointData = try Data(contentsOf: checkpointURL)
        let checkpoint = try WorkflowCanonicalCodec().decodeCanonical(
            WorkflowCheckpointDocumentV4.self, from: checkpointData
        )
        let video = try XCTUnwrap(checkpoint.body.trackProgress.first { $0.kind == .video })
        XCTAssertTrue(video.isComplete)
        let outputURL = URL(fileURLWithPath: outputPath)
        let concreteSampleCount = UInt64(try await videoConcreteOutputPresentationTimes(outputURL).count)
        XCTAssertEqual(concreteSampleCount, video.nextOutputSampleIndex)
        let first = try XCTUnwrap(checkpoint.body.segments.first)
        let last = try XCTUnwrap(checkpoint.body.segments.last)
        let expectedDuration = CMTimeSubtract(
            CMTime(value: last.endTimeExclusive.value, timescale: last.endTimeExclusive.timescale),
            CMTime(value: first.startTime.value, timescale: first.startTime.timescale)
        )
        let outputDuration = try await AVURLAsset(url: outputURL).load(.duration)
        XCTAssertEqual(CMTimeCompare(outputDuration, expectedDuration), 0)
        XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointData)
        let receipt: [String: Any] = [
            "schema": "mirmir-saved-assembly-concrete-frame-verification-v1",
            "outputPath": outputURL.path,
            "concreteSampleCount": concreteSampleCount,
            "expectedSampleCount": video.nextOutputSampleIndex,
            "outputDurationValue": outputDuration.value,
            "outputDurationTimescale": outputDuration.timescale,
            "expectedDurationValue": expectedDuration.value,
            "expectedDurationTimescale": expectedDuration.timescale
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputURL.deletingLastPathComponent().appendingPathComponent("concrete-frame-verification.json"), options: .atomic)
    }

    func testSavedCompleteCheckpointFinalizesAllTracksWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["MIRMIR_SAVED_ASSEMBLY_ROOT"],
              let checkpointPath = environment["MIRMIR_SAVED_ASSEMBLY_CHECKPOINT"],
              let assembledPath = environment["MIRMIR_SAVED_ASSEMBLY_VERIFY_OUTPUT"],
              let outputPath = environment["MIRMIR_SAVED_FINALIZATION_OUTPUT"],
              let evidencePath = environment["MIRMIR_SAVED_FINALIZATION_EVIDENCE_DIR"],
              !rootPath.isEmpty, !checkpointPath.isEmpty, !assembledPath.isEmpty,
              !outputPath.isEmpty, !evidencePath.isEmpty else {
            throw XCTSkip("Set the saved finalization paths to finish a complete checkpoint.")
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let checkpointURL = URL(fileURLWithPath: checkpointPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let assembledURL = URL(fileURLWithPath: assembledPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let outputURL = URL(fileURLWithPath: outputPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let evidenceURL = URL(fileURLWithPath: evidencePath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard checkpointURL.path.hasPrefix(rootURL.path + "/"),
              !outputURL.path.hasPrefix(rootURL.path + "/"),
              !evidenceURL.path.hasPrefix(rootURL.path + "/"),
              !FileManager.default.fileExists(atPath: outputURL.path) else {
            return XCTFail("Finalization must preserve the saved root and an existing output.")
        }
        let checkpointData = try Data(contentsOf: checkpointURL)
        let checkpoint = try WorkflowCanonicalCodec().decodeCanonical(
            WorkflowCheckpointDocumentV4.self, from: checkpointData
        )
        let jobID = checkpoint.body.compatibility.jobBinding.jobID
        let requestURL = rootURL.appendingPathComponent(
            "jobs/\(jobID.rawValue)/application-request-v4/request-v1.json"
        )
        let requestData = try Data(contentsOf: requestURL)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let body = try XCTUnwrap(envelope["body"] as? [String: Any])
        let canonicalBody = try JSONSerialization.data(
            withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard envelope["schemaVersion"] as? Int == 3,
              body["schemaVersion"] as? Int == 3,
              envelope["bodyHash"] as? String == WorkflowV4Validation.domainSeparatedSHA256(
                domain: "Mirmir.WorkflowApplication.RequestDocument.v1\u{0}",
                data: canonicalBody
              ) else {
            throw WorkflowApplicationQueueErrorV4.requestDocumentCorrupt(jobID)
        }
        func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(
                withJSONObject: XCTUnwrap(body[key]), options: [.sortedKeys, .fragmentsAllowed]
            ))
        }
        let specification = try decode(WorkflowJobSpecification.self, key: "specification")
        let expectedBinding = try decode(WorkflowVerifiedPreparedPlanBindingV4.self, key: "preparedPlanBinding")
        let snapshot = try decode(WorkflowApplicationSourceSnapshotBindingV4.self, key: "sourceSnapshot")
        guard specification.binding == checkpoint.body.compatibility.jobBinding,
              snapshot.identityID == checkpoint.body.compatibility.sourceSnapshotIdentityID else {
            throw WorkflowApplicationQueueErrorV4.requestDocumentBindingMismatch(jobID)
        }
        let sourceURL = rootURL.appendingPathComponent(snapshot.relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard sourceURL.path.hasPrefix(rootURL.path + "/"),
              sourceURL.lastPathComponent == body["canonicalSourceFileName"] as? String else {
            throw WorkflowApplicationQueueErrorV4.sourceSnapshotInvalid(jobID)
        }
        let sourceIdentity = try WorkflowSegmentCheckpointStoreV4.rawFileIdentity(sourceURL)
        guard sourceIdentity.byteCount == snapshot.byteCount,
              sourceIdentity.sha256 == snapshot.sha256.rawValue else {
            throw WorkflowApplicationQueueErrorV4.sourceSnapshotInvalid(jobID)
        }
        let request = UpscaleRequest(
            inputURL: sourceURL,
            outputURL: outputURL,
            backendID: expectedBinding.resolvedBackendID,
            targetWidth: try XCTUnwrap(body["targetWidth"] as? Int),
            targetHeight: try XCTUnwrap(body["targetHeight"] as? Int),
            outputCodec: try decode(OutputCodec.self, key: "outputCodec"),
            preserveAudio: try XCTUnwrap(body["preserveAudio"] as? Bool),
            overwriteExistingFile: false
        )
        let video = try XCTUnwrap(checkpoint.body.trackProgress.first { $0.kind == .video })
        guard video.isComplete, video.nextInputSampleIndex > 0,
              let completedOrdinal = Int64(exactly: video.nextInputSampleIndex - 1) else {
            throw WorkflowApplicationQueueErrorV4.terminalCheckpointMissing(jobID)
        }
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        let evidenceFile = evidenceURL.appendingPathComponent("saved-finalization-replay.json")
        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".mirmir-saved-finalization-\(UUID().uuidString.lowercased()).partial.mov"
        )
        let diagnosticStore = MirmirDiagnosticStore(inMemoryWith: .production)
        let recorder = MirmirDiagnosticRecorder(store: diagnosticStore)
        let engine = WorkflowDeterministicApplicationEngineV4(
            videoProbe: VideoProbe(), backendCatalog: .live(), runtimeEnvironment: .current()
        )
        let cancellation = ProcessingCancellation()
        let startedAt = Date()
        var evidence: [String: Any] = [
            "schema": "mirmir-saved-complete-finalization-replay-v1",
            "jobID": jobID.rawValue,
            "checkpointPath": checkpointURL.path,
            "sourcePath": sourceURL.path,
            "sourceSHA256": sourceIdentity.sha256,
            "assembledVideoPath": assembledURL.path,
            "outputPath": outputURL.path,
            "expectedPlanID": expectedBinding.planID.rawValue,
            "expectedRuntimeBindingID": expectedBinding.runtimeBindingID.rawValue,
            "expectedFrameCount": video.nextOutputSampleIndex,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "status": "revalidating"
        ]
        func writeEvidence() throws {
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidenceFile, options: .atomic)
        }
        try writeEvidence()
        do {
            let source = try await MirmirDiagnosticScope.$recorder.withValue(recorder) {
                try await engine.revalidateAndPrepare(
                    jobID: jobID, request: request,
                    expectedBinding: expectedBinding, cancellation: cancellation
                )
            }
            try await engine.validateTerminalSourceCompleteness(
                jobID: jobID, lastCompletedInputOrdinal: completedOrdinal
            )
            if environment["MIRMIR_SAVED_FINALIZATION_PREPARE_ONLY"] == "1" {
                evidence["status"] = "passed_preparation"
                evidence["sourceAudioTrackCount"] = source.audioTrackCount
                evidence["durationSeconds"] = Date().timeIntervalSince(startedAt)
                try writeEvidence()
                XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointData)
                XCTAssertEqual(try Data(contentsOf: requestURL), requestData)
                await engine.abandonPrepared(jobID: jobID)
                return
            }
            evidence["status"] = "finalizing"
            evidence["sourceAudioTrackCount"] = source.audioTrackCount
            try writeEvidence()
            let finalized = try await MirmirDiagnosticScope.$recorder.withValue(recorder) {
                try await engine.finalizePreparedOutput(
                    jobID: jobID, request: request, assembledVideoURL: assembledURL,
                    publicationURL: outputURL, migrationTemporaryURL: temporaryURL,
                    cancellation: cancellation, progress: { _ in }
                )
            }
            let completion = try await engine.inspectCompletion(
                request: request, checkpoint: checkpoint, segmentResult: nil,
                processingDurationSeconds: Date().timeIntervalSince(startedAt)
            )
            let output = try await VideoProbe().probe(url: outputURL)
            let concreteSampleCount = UInt64(try await videoConcreteOutputPresentationTimes(outputURL).count)
            XCTAssertEqual(concreteSampleCount, video.nextOutputSampleIndex)
            XCTAssertEqual(completion.result.processedFrameCount, Int(clamping: video.nextOutputSampleIndex))
            XCTAssertEqual(output.audioTrackCount, source.audioTrackCount)
            XCTAssertEqual(completion.result.audioResult, .preserved)
            XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointData)
            XCTAssertEqual(try Data(contentsOf: requestURL), requestData)
            let finalSourceIdentity = try WorkflowSegmentCheckpointStoreV4.rawFileIdentity(sourceURL)
            XCTAssertEqual(finalSourceIdentity.sha256, sourceIdentity.sha256)
            evidence["status"] = concreteSampleCount == video.nextOutputSampleIndex
                && output.audioTrackCount == source.audioTrackCount ? "passed" : "failed_verification"
            evidence["outputConcreteSampleCount"] = concreteSampleCount
            evidence["outputAudioTrackCount"] = output.audioTrackCount
            evidence["audioResult"] = completion.result.audioResult.rawValue
            evidence["migrationVerification"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(finalized.verification)
            )
            evidence["durationSeconds"] = Date().timeIntervalSince(startedAt)
            try writeEvidence()
            try await diagnosticStore.exportJSON().write(to: evidenceURL.appendingPathComponent("finalization-diagnostics.json"), options: .atomic)
            await engine.abandonPrepared(jobID: jobID)
        } catch {
            evidence["status"] = "failed"
            evidence["errorDomain"] = (error as NSError).domain
            evidence["errorCode"] = (error as NSError).code
            evidence["errorDescription"] = error.localizedDescription
            evidence["errorDebugDescription"] = String(describing: error)
            evidence["durationSeconds"] = Date().timeIntervalSince(startedAt)
            try writeEvidence()
            try await diagnosticStore.exportJSON().write(to: evidenceURL.appendingPathComponent("finalization-diagnostics.json"), options: .atomic)
            XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointData)
            XCTAssertEqual(try Data(contentsOf: requestURL), requestData)
            await engine.abandonPrepared(jobID: jobID)
            throw error
        }
    }

    func testSavedChapterMovieMigratesAcrossMovieClocksWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["MIRMIR_SAVED_CHAPTER_REPRO_SOURCE"],
              let outputPath = environment["MIRMIR_SAVED_CHAPTER_REPRO_OUTPUT"],
              !sourcePath.isEmpty, !outputPath.isEmpty else {
            throw XCTSkip("Set the saved chapter movie paths to replay chapter migration.")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let sourceAsset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let source = try await AVFoundationTrackGraphAdapterV4.probe(asset: sourceAsset)
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: source, plan: plan)
        let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
            sourceURL: sourceURL, destinationURL: outputURL,
            sourceGraph: source, identifiedPlan: plan, blueprint: blueprint
        ))
        XCTAssertTrue(result.verificationReport.isConformant)
        XCTAssertEqual(result.sourceChapterMetadataSHA256, result.outputChapterMetadataSHA256)
        try JSONEncoder().encode(result.trackResults).write(
            to: outputURL.deletingLastPathComponent().appendingPathComponent(outputURL.lastPathComponent + ".tracks.json"),
            options: .atomic
        )
    }

    func testSavedAudioTrackMetadataMatchesRepairedWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["MIRMIR_SAVED_AUDIO_ORIGINAL_SOURCE"],
              let repairedPath = environment["MIRMIR_SAVED_AUDIO_METADATA_REPAIRED"],
              let evidencePath = environment["MIRMIR_SAVED_AUDIO_METADATA_EVIDENCE"],
              !sourcePath.isEmpty, !repairedPath.isEmpty, !evidencePath.isEmpty else {
            throw XCTSkip("Set the original and repaired movie paths to verify track metadata.")
        }
        let source = AVURLAsset(url: URL(fileURLWithPath: sourcePath), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let repaired = AVURLAsset(url: URL(fileURLWithPath: repairedPath), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sourceTracks = try await source.loadTracks(withMediaType: .audio)
        let repairedTracks = try await repaired.loadTracks(withMediaType: .audio)
        XCTAssertEqual(sourceTracks.count, 2)
        XCTAssertEqual(repairedTracks.count, sourceTracks.count)
        var evidence: [[String: Any]] = []
        for (sourceTrack, repairedTrack) in zip(sourceTracks, repairedTracks) {
            let sourceItems = try await sourceTrack.load(.metadata)
            let repairedItems = try await repairedTrack.load(.metadata)
            let expected = try await AVFoundationTrackGraphAdapterV4.canonicalMigratedTrackMetadataFingerprint(sourceItems)
            let observed = try await AVFoundationTrackGraphAdapterV4.canonicalTrackMetadataFingerprint(repairedItems)
            XCTAssertEqual(sourceItems.count, 1)
            XCTAssertEqual(repairedItems.count, sourceItems.count)
            XCTAssertEqual(expected, observed)
            evidence.append([
                "sourceTrackID": sourceTrack.trackID, "repairedTrackID": repairedTrack.trackID,
                "sourceMetadataItemCount": sourceItems.count, "repairedMetadataItemCount": repairedItems.count,
                "expectedTypedSourceFingerprint": expected.rawValue, "observedFingerprint": observed.rawValue
            ])
        }
        let passed = evidence.count == 2 && evidence.allSatisfy {
            $0["expectedTypedSourceFingerprint"] as? String == $0["observedFingerprint"] as? String
                && $0["sourceMetadataItemCount"] as? Int == 1
                && $0["sourceMetadataItemCount"] as? Int == $0["repairedMetadataItemCount"] as? Int
        }
        try JSONSerialization.data(withJSONObject: [
            "status": passed ? "passed" : "failed_verification", "tracks": evidence,
            "sourcePath": sourcePath, "repairedPath": repairedPath
        ], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
    }

    func testSavedOriginalAudioStreamsMatchRecoveredWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["MIRMIR_SAVED_AUDIO_ORIGINAL_SOURCE"],
              let recoveredPath = environment["MIRMIR_SAVED_AUDIO_RECOVERED_OUTPUT"],
              let evidencePath = environment["MIRMIR_SAVED_AUDIO_STREAM_EVIDENCE"],
              !sourcePath.isEmpty, !recoveredPath.isEmpty, !evidencePath.isEmpty else {
            throw XCTSkip("Set the original and recovered audio paths to verify both source streams.")
        }
        let source = AVURLAsset(url: URL(fileURLWithPath: sourcePath), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let recovered = AVURLAsset(url: URL(fileURLWithPath: recoveredPath), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sourceTracks = try await source.loadTracks(withMediaType: .audio)
        let recoveredTracks = try await recovered.loadTracks(withMediaType: .audio)
        XCTAssertEqual(sourceTracks.count, 2)
        XCTAssertEqual(recoveredTracks.count, sourceTracks.count)
        func identity(_ asset: AVAsset, _ track: AVAssetTrack) throws -> (String, Int, Int) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw AVFoundationTrackMigrationExecutorV4Error.readerCreationFailed(.init(reader.error))
            }
            reader.add(output)
            guard reader.startReading() else {
                throw AVFoundationTrackMigrationExecutorV4Error.readerStartFailed(.init(reader.error))
            }
            var accumulator = SampleStreamAccumulatorV4()
            var packetCount = 0
            var bufferCount = 0
            while let sample = output.copyNextSampleBuffer() {
                let count = CMSampleBufferGetNumSamples(sample)
                packetCount += count
                if count > 0 { bufferCount += 1 }
                try autoreleasepool { try accumulator.append(sample) }
            }
            guard reader.status == .completed else {
                throw AVFoundationTrackMigrationExecutorV4Error.readerFailed(.init(reader.error))
            }
            return (accumulator.digest.rawValue, packetCount, bufferCount)
        }
        var evidence: [[String: Any]] = []
        for (sourceTrack, recoveredTrack) in zip(sourceTracks, recoveredTracks) {
            let sourceIdentity = try identity(source, sourceTrack)
            let recoveredIdentity = try identity(recovered, recoveredTrack)
            XCTAssertEqual(sourceIdentity.0, recoveredIdentity.0)
            XCTAssertEqual(sourceIdentity.1, recoveredIdentity.1)
            evidence.append([
                "sourceTrackID": sourceTrack.trackID,
                "recoveredTrackID": recoveredTrack.trackID,
                "sourceDigest": sourceIdentity.0, "recoveredDigest": recoveredIdentity.0,
                "sourcePacketCount": sourceIdentity.1, "recoveredPacketCount": recoveredIdentity.1,
                "sourceBufferCount": sourceIdentity.2, "recoveredBufferCount": recoveredIdentity.2
            ])
        }
        let passed = evidence.count == 2 && evidence.allSatisfy {
            $0["sourceDigest"] as? String == $0["recoveredDigest"] as? String
                && $0["sourcePacketCount"] as? Int == $0["recoveredPacketCount"] as? Int
        }
        try JSONSerialization.data(withJSONObject: [
            "status": passed ? "passed" : "failed_verification", "tracks": evidence,
            "sourcePath": sourcePath, "recoveredPath": recoveredPath
        ], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
    }

    func testSavedAudioMovieMigratesAllTracksWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sourcePath = environment["MIRMIR_SAVED_AUDIO_REPRO_SOURCE"],
              let outputPath = environment["MIRMIR_SAVED_AUDIO_REPRO_OUTPUT"],
              !sourcePath.isEmpty, !outputPath.isEmpty else {
            throw XCTSkip("Set the saved audio movie paths to replay audio migration.")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".mirmir-audio-replay-" + UUID().uuidString.lowercased() + ".partial.mov")
        let retainedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(outputURL.lastPathComponent + ".verification-snapshot.mov")
        let receiptURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(outputURL.lastPathComponent + ".replay.json")
        guard !FileManager.default.fileExists(atPath: retainedURL.path) else {
            return XCTFail("Use an output path without a previous verification snapshot.")
        }
        let sourceIdentity = try WorkflowSegmentCheckpointStoreV4.rawFileIdentity(sourceURL)
        let sourceAsset = AVURLAsset(url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let source = try await AVFoundationTrackGraphAdapterV4.probe(asset: sourceAsset)
        XCTAssertEqual(source.tracks.count, 2)
        XCTAssertTrue(source.tracks.allSatisfy { $0.kind == .audio })
        let plan = try MediaTrackGraphPlannerV4.makePlan(source: source)
        let blueprint = try AVFoundationTrackMigrationPlannerV4.makeBlueprint(source: source, plan: plan)
        try JSONEncoder().encode(source).write(
            to: outputURL.deletingLastPathComponent().appendingPathComponent(outputURL.lastPathComponent + ".source-graph.json"),
            options: .atomic
        )
        do {
            let result = try await AVFoundationTrackMigrationExecutorV4().execute(.init(
                sourceURL: sourceURL, destinationURL: outputURL, temporaryURL: temporaryURL,
                sourceGraph: source, identifiedPlan: plan, blueprint: blueprint
            ), progress: { progress in
                guard progress.stage == .verifying,
                      !FileManager.default.fileExists(atPath: retainedURL.path) else { return }
                do {
                    try FileManager.default.copyItem(at: temporaryURL, to: retainedURL)
                } catch {
                    try? String(describing: error).write(
                        to: retainedURL.appendingPathExtension("failure.txt"), atomically: true, encoding: .utf8
                    )
                }
            })
            let streamsMatch = result.trackResults.count == source.tracks.count && result.trackResults.allSatisfy {
                $0.sourceSampleStreamSHA256 != nil
                    && $0.sourceSampleStreamSHA256 == $0.outputSampleStreamSHA256
            }
            XCTAssertTrue(result.verificationReport.isConformant)
            XCTAssertTrue(streamsMatch)
            XCTAssertEqual(try WorkflowSegmentCheckpointStoreV4.rawFileIdentity(sourceURL).sha256, sourceIdentity.sha256)
            try JSONEncoder().encode(result.trackResults).write(
                to: outputURL.deletingLastPathComponent().appendingPathComponent(outputURL.lastPathComponent + ".tracks.json"),
                options: .atomic
            )
            try JSONEncoder().encode(result.verificationReport).write(
                to: outputURL.deletingLastPathComponent().appendingPathComponent(outputURL.lastPathComponent + ".semantics.json"),
                options: .atomic
            )
            try JSONSerialization.data(withJSONObject: [
                "status": result.verificationReport.isConformant && streamsMatch ? "passed" : "failed_verification",
                "sourcePath": sourceURL.path, "outputPath": outputURL.path,
                "retainedPath": retainedURL.path
            ], options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
        } catch {
            try JSONSerialization.data(withJSONObject: [
                "status": "failed", "sourcePath": sourceURL.path, "retainedPath": retainedURL.path,
                "errorDebugDescription": String(describing: error)
            ], options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL, options: .atomic)
            XCTAssertEqual(try WorkflowSegmentCheckpointStoreV4.rawFileIdentity(sourceURL).sha256, sourceIdentity.sha256)
            throw error
        }
    }

    func testSavedCompleteCheckpointAssemblesWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["MIRMIR_SAVED_ASSEMBLY_ROOT"],
              let checkpointPath = environment["MIRMIR_SAVED_ASSEMBLY_CHECKPOINT"],
              let evidencePath = environment["MIRMIR_SAVED_ASSEMBLY_EVIDENCE_DIR"],
              !rootPath.isEmpty, !checkpointPath.isEmpty, !evidencePath.isEmpty else {
            throw XCTSkip("Set the MIRMIR_SAVED_ASSEMBLY paths to replay saved segments.")
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let checkpointURL = URL(fileURLWithPath: checkpointPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let evidenceURL = URL(fileURLWithPath: evidencePath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard checkpointURL.path.hasPrefix(rootURL.path + "/"),
              !evidenceURL.path.hasPrefix(rootURL.path + "/") else {
            return XCTFail("Replay evidence must be outside the saved workflow root.")
        }
        let checkpointData = try Data(contentsOf: checkpointURL)
        let checkpoint = try WorkflowCanonicalCodec().decodeCanonical(
            WorkflowCheckpointDocumentV4.self,
            from: checkpointData
        )
        let video = try XCTUnwrap(checkpoint.body.trackProgress.first { $0.kind == .video })
        XCTAssertTrue(video.isComplete)
        var segments = checkpoint.body.segments
        let suffixCount = environment["MIRMIR_SAVED_ASSEMBLY_SUFFIX_COUNT"].flatMap(Int.init)
        if let suffixCount {
            guard suffixCount > 0, suffixCount <= segments.count else {
                return XCTFail("The requested segment suffix must be present in the checkpoint.")
            }
            let suffix = Array(segments.suffix(suffixCount))
            let origin = try XCTUnwrap(suffix.first).startTime
            segments = try suffix.enumerated().map { index, segment in
                guard segment.startTime.timescale == origin.timescale,
                      segment.endTimeExclusive.timescale == origin.timescale,
                      segment.nextStartTime.map({ $0.timescale == origin.timescale }) ?? true else {
                    throw AVFoundationSegmentV4Error.invalidSegmentSequence
                }
                return try WorkflowSegmentCheckpointV4(
                    ordinal: UInt64(index),
                    artifact: segment.artifact,
                    startTime: WorkflowMediaTimeV4(value: segment.startTime.value - origin.value, timescale: origin.timescale),
                    endTimeExclusive: WorkflowMediaTimeV4(value: segment.endTimeExclusive.value - origin.value, timescale: origin.timescale),
                    nextStartTime: index + 1 < suffix.count ? segment.nextStartTime.map {
                        try WorkflowMediaTimeV4(value: $0.value - origin.value, timescale: origin.timescale)
                    } : nil,
                    codecSettingsHash: segment.codecSettingsHash,
                    isIndependentlyDecodable: segment.isIndependentlyDecodable
                )
            }
        }
        let firstSegment = try XCTUnwrap(segments.first)
        try FileManager.default.createDirectory(at: evidenceURL, withIntermediateDirectories: true)
        let outputURL = evidenceURL.appendingPathComponent("saved-checkpoint-assembled.mov")
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            return XCTFail("Use an evidence directory without an existing assembled movie.")
        }
        let diagnosticStore = MirmirDiagnosticStore(inMemoryWith: .production)
        let recorder = MirmirDiagnosticRecorder(store: diagnosticStore)
        let startedAt = Date()
        var evidence: [String: Any] = [
            "schema": "mirmir-saved-segment-assembly-replay-v1",
            "checkpointPath": checkpointURL.path,
            "checkpointSHA256": SHA256.hash(data: checkpointData).map { String(format: "%02x", $0) }.joined(),
            "segmentCount": segments.count,
            "savedSegmentCount": checkpoint.body.segments.count,
            "suffixCount": suffixCount ?? checkpoint.body.segments.count,
            "videoSampleCount": video.nextOutputSampleIndex,
            "outputPath": outputURL.path,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "status": "running"
        ]
        let evidenceFile = evidenceURL.appendingPathComponent("saved-assembly-replay.json")
        func writeEvidence() throws {
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: evidenceFile, options: .atomic)
        }
        try writeEvidence()
        do {
            let assembly = try await MirmirDiagnosticScope.$recorder.withValue(recorder) {
                try await AVFoundationSegmentAssemblerV4().assemble(.init(
                    artifactRootURL: rootURL,
                    segments: segments,
                    mediaTimelineStart: firstSegment.startTime,
                    outputTimelineStart: try WorkflowMediaTimeV4(value: 0, timescale: 1),
                    destinationURL: outputURL
                ))
            }
            XCTAssertEqual(assembly.segmentCount, segments.count)
            XCTAssertTrue(assembly.preservation.contains(.trackPayloads))
            let concreteSampleCount = UInt64(try await videoConcreteOutputPresentationTimes(outputURL).count)
            evidence["outputConcreteSampleCount"] = concreteSampleCount
            if suffixCount == nil {
                XCTAssertEqual(concreteSampleCount, video.nextOutputSampleIndex)
            }
            let frameCountMatches = suffixCount != nil
                || concreteSampleCount == video.nextOutputSampleIndex
            evidence["status"] = assembly.segmentCount == segments.count
                && assembly.preservation.contains(.trackPayloads)
                && frameCountMatches ? "passed" : "failed_verification"
            evidence["outputFileSHA256"] = assembly.outputFileSHA256
            evidence["outputIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(assembly.outputIdentity))
        } catch {
            evidence["status"] = "failed"
            evidence["errorDomain"] = (error as NSError).domain
            evidence["errorCode"] = (error as NSError).code
            evidence["errorDescription"] = error.localizedDescription
            evidence["durationSeconds"] = Date().timeIntervalSince(startedAt)
            try writeEvidence()
            try await diagnosticStore.exportJSON().write(to: evidenceURL.appendingPathComponent("assembly-diagnostics.json"), options: .atomic)
            XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointData)
            throw error
        }
        evidence["durationSeconds"] = Date().timeIntervalSince(startedAt)
        try writeEvidence()
        try await diagnosticStore.exportJSON().write(to: evidenceURL.appendingPathComponent("assembly-diagnostics.json"), options: .atomic)
        XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointData)
    }

    func testPauseResumePublishesAndRestoresOpaqueStateThenAssemblesEquivalentMovies()
        async throws {
        let fixture = try makeFixture()
        let segment0 = fixture.root.appendingPathComponent("source-0.mov")
        let segment1 = fixture.root.appendingPathComponent("source-1.mov")
        try await writeSegment(
            to: segment0,
            colors: [(16, 32, 48), (24, 40, 56)]
        )
        try await writeSegment(
            to: segment1,
            colors: [(80, 96, 112), (88, 104, 120)]
        )

        let coordinator = try WorkflowDurableCoordinatorV4(
            rootURL: fixture.store
        )
        let specification = try makeSpecification()
        try await enqueue(specification, into: coordinator)
        let probingClaim = try await coordinator.acquire(
            acquisition(
                jobID: nil,
                lease: "lease-initial",
                worker: "worker-initial",
                event: "event-claim-initial",
                command: "command-claim-initial",
                from: .queued,
                to: .probing,
                attempt: nil
            )
        )
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-planned",
                command: "command-planned",
                from: .probing,
                to: .planned,
                attempt: nil
            ),
            using: probingClaim
        )
        let firstAttempt = try WorkflowAttemptID("attempt-initial")
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-running-initial",
                command: "command-running-initial",
                from: .planned,
                to: .running,
                attempt: firstAttempt
            ),
            using: probingClaim
        )
        let runningClaim = try await coordinator.currentClaim(for: probingClaim)
        let planSHA = try ASHSHA256V4(digest(101))
        let firstEngine = CheckpointEngineProbeV4(
            checkpoint: Data("opaque-state-after-frame-1".utf8)
        )
        let store = try WorkflowSegmentCheckpointStoreV4(
            rootURL: fixture.store
        )
        let firstRequest = try publicationRequest(
            checkpoint: 0,
            sourceURL: segment0,
            existing: [],
            start: 0,
            end: 2,
            nextStart: 2,
            nextSample: 2
        )
        let firstPublication = try await store.publishBoundary(
            firstRequest,
            using: runningClaim,
            upscaler: firstEngine,
            planSHA256: planSHA
        )
        // Models process death after append-only artifact publication but
        // before the coordinator head is advanced. Replaying the exact
        // boundary must reopen, verify, and reuse all bytes.
        let replayedPublication = try await store.publishBoundary(
            firstRequest,
            using: runningClaim,
            upscaler: firstEngine,
            planSHA256: planSHA
        )
        XCTAssertEqual(replayedPublication, firstPublication)
        let firstCommit = try await coordinator.commitCheckpoint(
            firstPublication.draft,
            using: runningClaim
        )
        XCTAssertEqual(firstCommit.document.body.segments.count, 1)
        let measurementURL = fixture.store.appendingPathComponent(
            firstCommit.document.body.measurementHysteresis.relativePath
        )
        let immutableMeasurementV1 = try Data(contentsOf: measurementURL)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WorkflowSchemaVersionProbeV4.self,
                from: immutableMeasurementV1
            ).schemaVersion,
            WorkflowSegmentArtifactPersistenceSchemaV4.immutableV1
        )
        let immutableReceiptHashesV1 =
            firstCommit.document.body.segments.map {
                $0.artifact.reopenReceiptSHA256
            }
            + [
                firstCommit.document.body.temporalHistory
                    .reopenReceiptSHA256,
                firstCommit.document.body.measurementHysteresis
                    .reopenReceiptSHA256
            ]
        let capturedOrdinal = await firstEngine.lastCheckpointOrdinal()
        XCTAssertEqual(capturedOrdinal, 1)

        _ = try await coordinator.transition(
            lifecycle(
                event: "event-pausing",
                command: "command-pausing",
                from: .running,
                to: .pausing,
                attempt: firstAttempt
            ),
            using: runningClaim
        )
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-paused",
                command: "command-paused",
                from: .pausing,
                to: .paused,
                attempt: firstAttempt
            ),
            using: runningClaim
        )

        let secondAttempt = try WorkflowAttemptID("attempt-resumed")
        let resumedClaim = try await coordinator.acquire(
            acquisition(
                jobID: specification.jobID,
                lease: "lease-resumed",
                worker: "worker-resumed",
                event: "event-claim-resumed",
                command: "command-claim-resumed",
                from: .paused,
                to: .running,
                attempt: secondAttempt
            )
        )
        let resumedStore = try WorkflowSegmentCheckpointStoreV4(
            rootURL: fixture.store
        )
        let resumedEngine = CheckpointEngineProbeV4(
            checkpoint: Data("opaque-state-after-frame-3".utf8)
        )
        _ = try await resumedStore.restoreCheckpoint(
            firstCommit.document,
            using: resumedClaim,
            into: resumedEngine,
            planSHA256: planSHA
        )
        let restoredCheckpoint = await resumedEngine.restoredCheckpoint()
        XCTAssertEqual(
            restoredCheckpoint,
            Data("opaque-state-after-frame-1".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: measurementURL),
            immutableMeasurementV1
        )
        XCTAssertEqual(
            firstCommit.document.body.segments.map {
                $0.artifact.reopenReceiptSHA256
            }
                + [
                    firstCommit.document.body.temporalHistory
                        .reopenReceiptSHA256,
                    firstCommit.document.body.measurementHysteresis
                        .reopenReceiptSHA256
                ],
            immutableReceiptHashesV1
        )

        let secondPublication = try await resumedStore.publishBoundary(
            publicationRequest(
                checkpoint: 1,
                sourceURL: segment1,
                existing: firstCommit.document.body.segments,
                start: 2,
                end: 4,
                nextStart: nil,
                nextSample: 4
            ),
            using: resumedClaim,
            upscaler: resumedEngine,
            planSHA256: planSHA
        )
        let secondCommit = try await coordinator.commitCheckpoint(
            secondPublication.draft,
            using: resumedClaim
        )
        let verification = try await resumedStore.verifyCheckpoint(
            secondCommit.document
        )
        XCTAssertEqual(verification.verifiedSegments.count, 2)
        XCTAssertEqual(secondCommit.document.body.segments.map(\.ordinal), [0, 1])

        // Run the same two boundaries without pausing in an independent
        // durable store. This makes the equivalence check compare genuinely
        // uninterrupted execution with the recovered execution above.
        let uninterruptedFixture = try makeFixture()
        let uninterruptedSetup = try await makeRunningCoordinator(
            fixture: uninterruptedFixture
        )
        let uninterruptedStore = try WorkflowSegmentCheckpointStoreV4(
            rootURL: uninterruptedFixture.store
        )
        let uninterruptedFirst = try await uninterruptedStore.publishBoundary(
            firstRequest,
            using: uninterruptedSetup.claim,
            temporalCheckpoint: Data("continuous-state-after-frame-1".utf8)
        )
        let uninterruptedFirstCommit = try await uninterruptedSetup.coordinator
            .commitCheckpoint(
                uninterruptedFirst.draft,
                using: uninterruptedSetup.claim
            )
        let uninterruptedSecond = try await uninterruptedStore.publishBoundary(
            publicationRequest(
                checkpoint: 1,
                sourceURL: segment1,
                existing: uninterruptedFirstCommit.document.body.segments,
                start: 2,
                end: 4,
                nextStart: nil,
                nextSample: 4
            ),
            using: uninterruptedSetup.claim,
            temporalCheckpoint: Data("continuous-state-after-frame-3".utf8)
        )
        let uninterruptedCommit = try await uninterruptedSetup.coordinator
            .commitCheckpoint(
                uninterruptedSecond.draft,
                using: uninterruptedSetup.claim
            )

        let uninterruptedURL = uninterruptedFixture.output.appendingPathComponent(
            "uninterrupted.mov"
        )
        let resumedURL = fixture.output.appendingPathComponent("resumed.mov")
        let assembler = AVFoundationSegmentAssemblerV4()
        let uninterrupted = try await assembler.assemble(
            AVFoundationSegmentAssemblyRequestV4(
                artifactRootURL: uninterruptedFixture.store,
                segments: uninterruptedCommit.document.body.segments,
                mediaTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 30
                ),
                outputTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 1
                ),
                destinationURL: uninterruptedURL
            )
        )
        let reopenedAssembler = AVFoundationSegmentAssemblerV4()
        let resumed = try await reopenedAssembler.assemble(
            AVFoundationSegmentAssemblyRequestV4(
                artifactRootURL: fixture.store,
                segments: secondCommit.document.body.segments,
                mediaTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 30
                ),
                outputTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 1
                ),
                destinationURL: resumedURL
            )
        )
        let equivalence = AVFoundationSegmentAssemblyEquivalenceV4(
            uninterrupted,
            resumed
        )
        XCTAssertTrue(equivalence.semanticIdentityIsIdentical)
        let uninterruptedDecoded = try await decodedVideoReceipt(
            uninterruptedURL
        )
        let resumedDecoded = try await decodedVideoReceipt(resumedURL)
        XCTAssertEqual(uninterruptedDecoded, resumedDecoded)
        XCTAssertTrue(uninterrupted.preservation.contains(.exactSampleTiming))
        XCTAssertTrue(
            uninterrupted.preservation.contains(.containerBytesNotContractual)
        )
        // MOV atom ordering and encoder/exporter metadata are not part of the
        // checkpoint contract. Equality is recorded when observed, but decoded
        // pixels, elementary payloads, and timing above are the release gate.
        _ = equivalence.containerBytesAreIdentical
    }

    func testENOSPCPublicationNamesFailureAndPreservesPreviousHead()
        async throws {
        let fixture = try makeFixture()
        let firstSource = fixture.root.appendingPathComponent("enospc-0.mov")
        let secondSource = fixture.root.appendingPathComponent("enospc-1.mov")
        try await writeSegment(
            to: firstSource,
            colors: [(12, 24, 36), (18, 30, 42)]
        )
        try await writeSegment(
            to: secondSource,
            colors: [(48, 60, 72), (54, 66, 78)]
        )

        let setup = try await makeRunningCoordinator(fixture: fixture)
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)
        let firstPublication = try await store.publishBoundary(
            publicationRequest(
                checkpoint: 0,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 2,
                nextSample: 2
            ),
            using: setup.claim,
            temporalCheckpoint: Data("enospc-state-0".utf8)
        )
        let firstCommit = try await setup.coordinator.commitCheckpoint(
            firstPublication.draft,
            using: setup.claim
        )
        let headURL = fixture.store
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent("job-segment-v4", isDirectory: true)
            .appendingPathComponent("checkpoints-v4", isDirectory: true)
            .appendingPathComponent("head-v1.json")
        let headBeforeFailure = try Data(contentsOf: headURL)

        let failingStore = try WorkflowSegmentCheckpointStoreV4(
            rootURL: fixture.store,
            publicationOperationHook: { point, url in
                guard point == .beforeTemporaryCreate,
                      url.deletingLastPathComponent().lastPathComponent
                        == "state" else {
                    return
                }
                throw WorkflowDurableFileSystemError.ioFailure(
                    operation: "write",
                    path: url.path,
                    code: ENOSPC
                )
            }
        )
        do {
            _ = try await failingStore.publishBoundary(
                publicationRequest(
                    checkpoint: 1,
                    sourceURL: secondSource,
                    existing: firstCommit.document.body.segments,
                    start: 2,
                    end: 4,
                    nextStart: nil,
                    nextSample: 4
                ),
                using: setup.claim,
                temporalCheckpoint: Data("enospc-state-1".utf8)
            )
            XCTFail("The injected ENOSPC publication unexpectedly succeeded.")
        } catch let error as WorkflowSegmentCheckpointStoreV4Error {
            guard case let .atomicPublicationFailed(path, code) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, ENOSPC)
            XCTAssertTrue(path.contains("/state/.publish-"))
            XCTAssertTrue(
                error.localizedDescription.contains("No space left on device")
            )
        }

        XCTAssertEqual(try Data(contentsOf: headURL), headBeforeFailure)
        let loadedCheckpoint = try await setup.coordinator.loadCompatibleCheckpoint(
            jobID: firstCommit.document.body.compatibility.jobBinding.jobID,
            expectedCodecSettingsHash: WorkflowOutputContractID(digest(9))
        )
        let reopened = try XCTUnwrap(loadedCheckpoint)
        XCTAssertEqual(reopened, firstCommit.document)
        XCTAssertEqual(reopened.body.segments.count, 1)
        let videoProgress = try XCTUnwrap(
            reopened.body.trackProgress.first { $0.kind == .video }
        )
        XCTAssertFalse(videoProgress.isComplete)

        let stateURL = fixture.store
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent("job-segment-v4", isDirectory: true)
            .appendingPathComponent("checkpoint-artifacts-v4", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: stateURL.path)
                .contains { $0.hasPrefix(".publish-") }
        )
    }

    func testTamperedOpaqueStateIsContainedBeforeBackendRestore() async throws {
        let fixture = try makeFixture()
        let source = fixture.root.appendingPathComponent("source.mov")
        try await writeSegment(to: source, colors: [(1, 2, 3), (4, 5, 6)])
        let setup = try await makeRunningCoordinator(fixture: fixture)
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)
        let publication = try await store.publishBoundary(
            publicationRequest(
                checkpoint: 0,
                sourceURL: source,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 2,
                nextSample: 2
            ),
            using: setup.claim,
            temporalCheckpoint: Data("valid-temporal-state".utf8)
        )
        let committed = try await setup.coordinator.commitCheckpoint(
            publication.draft,
            using: setup.claim
        )
        let temporalURL = fixture.store.appendingPathComponent(
            committed.document.body.temporalHistory.relativePath
        )
        let handle = try FileHandle(forWritingTo: temporalURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([0xff]))
        try handle.synchronize()
        try handle.close()

        let backend = CheckpointEngineProbeV4(checkpoint: Data("unused".utf8))
        do {
            _ = try await store.restoreCheckpoint(
                committed.document,
                using: setup.claim,
                into: backend,
                planSHA256: ASHSHA256V4(digest(101))
            )
            XCTFail("Tampered temporal state was restored.")
        } catch let error as WorkflowSegmentCheckpointStoreV4Error {
            XCTAssertEqual(
                error,
                .artifactHashMismatch(
                    committed.document.body.temporalHistory.relativePath
                )
            )
        }
        let unexpectedlyRestored = await backend.restoredCheckpoint()
        XCTAssertNil(unexpectedlyRestored)
    }

    func testConflictingRetryCannotReplacePublishedSegment() async throws {
        let fixture = try makeFixture()
        let source = fixture.root.appendingPathComponent("source.mov")
        try await writeSegment(to: source, colors: [(7, 8, 9), (10, 11, 12)])
        let setup = try await makeRunningCoordinator(fixture: fixture)
        let expectedRelative = "jobs/job-segment-v4/checkpoint-artifacts-v4/"
            + "segments/segment-00000000000000000000-segment-artifact-0.mov"
        let conflictURL = fixture.store.appendingPathComponent(expectedRelative)
        try FileManager.default.createDirectory(
            at: conflictURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreign = Data("foreign-owned-data".utf8)
        try foreign.write(to: conflictURL, options: .withoutOverwriting)

        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)
        do {
            _ = try await store.publishBoundary(
                publicationRequest(
                    checkpoint: 0,
                    sourceURL: source,
                    existing: [],
                    start: 0,
                    end: 2,
                    nextStart: 2,
                    nextSample: 2
                ),
                using: setup.claim,
                temporalCheckpoint: Data("state".utf8)
            )
            XCTFail("A conflicting artifact was replaced.")
        } catch let error as WorkflowSegmentCheckpointStoreV4Error {
            guard case .artifactConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: conflictURL), foreign)
    }

    func testSymlinkedArtifactDirectoryCannotEscapeTrustedStore() async throws {
        let fixture = try makeFixture()
        let source = fixture.root.appendingPathComponent("source.mov")
        try await writeSegment(to: source, colors: [(13, 14, 15), (16, 17, 18)])
        let setup = try await makeRunningCoordinator(fixture: fixture)

        let outside = fixture.root.appendingPathComponent(
            "outside-artifact-store",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let checkpointDirectory = fixture.store
            .appendingPathComponent("jobs/job-segment-v4")
            .appendingPathComponent("checkpoint-artifacts-v4")
        try FileManager.default.createSymbolicLink(
            at: checkpointDirectory,
            withDestinationURL: outside
        )

        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)
        do {
            _ = try await store.publishBoundary(
                publicationRequest(
                    checkpoint: 0,
                    sourceURL: source,
                    existing: [],
                    start: 0,
                    end: 2,
                    nextStart: 2,
                    nextSample: 2
                ),
                using: setup.claim,
                temporalCheckpoint: Data("state".utf8)
            )
            XCTFail("A symlinked checkpoint directory escaped the trusted root.")
        } catch let error as WorkflowSegmentCheckpointStoreV4Error {
            guard case .unsafeDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path),
            []
        )
    }

    func testBoundaryContractPersistsTrueGapAndRejectsInvalidTailStates()
        async throws {
        let fixture = try makeFixture()
        let firstSource = fixture.root.appendingPathComponent("gap-source-0.mov")
        let secondSource = fixture.root.appendingPathComponent("gap-source-1.mov")
        try await writeSegment(
            to: firstSource,
            colors: [(20, 30, 40), (21, 31, 41)]
        )
        try await writeSegment(
            to: secondSource,
            colors: [(50, 60, 70), (51, 61, 71)]
        )
        let setup = try await makeRunningCoordinator(fixture: fixture)
        let store = try WorkflowSegmentCheckpointStoreV4(rootURL: fixture.store)

        let first = try await store.publishBoundary(
            publicationRequest(
                checkpoint: 0,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 3,
                nextSample: 2
            ),
            using: setup.claim,
            temporalCheckpoint: Data("gap-state-0".utf8)
        )
        XCTAssertEqual(
            first.draft.segments[0].nextStartTime,
            try WorkflowMediaTimeV4(value: 3, timescale: 30)
        )
        _ = try await setup.coordinator.commitCheckpoint(
            first.draft,
            using: setup.claim
        )
        let specification = try makeSpecification()
        let loadedFirst = try await setup.coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        let reopenedFirst = try XCTUnwrap(loadedFirst)
        XCTAssertEqual(
            reopenedFirst.body.segments[0].nextStartTime,
            try WorkflowMediaTimeV4(value: 3, timescale: 30)
        )

        let invalidRequests = try [
            publicationRequest(
                checkpoint: 10,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 1,
                nextSample: 2
            ),
            publicationRequest(
                checkpoint: 11,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: nil,
                nextSample: 2
            ),
            publicationRequest(
                checkpoint: 12,
                sourceURL: firstSource,
                existing: [],
                start: 0,
                end: 2,
                nextStart: 3,
                nextSample: 4
            ),
            publicationRequest(
                checkpoint: 13,
                sourceURL: secondSource,
                existing: reopenedFirst.body.segments,
                start: 4,
                end: 6,
                nextStart: nil,
                nextSample: 4
            )
        ]
        for request in invalidRequests {
            do {
                _ = try await store.publishBoundary(
                    request,
                    using: setup.claim,
                    temporalCheckpoint: Data("must-not-publish".utf8)
                )
                XCTFail("An invalid persisted boundary was published.")
            } catch let error as WorkflowSegmentCheckpointStoreV4Error {
                XCTAssertEqual(error, .invalidSegmentSequence)
            }
        }

        let terminal = try await store.publishBoundary(
            publicationRequest(
                checkpoint: 1,
                sourceURL: secondSource,
                existing: reopenedFirst.body.segments,
                start: 3,
                end: 5,
                nextStart: nil,
                nextSample: 4
            ),
            using: setup.claim,
            temporalCheckpoint: Data("gap-state-1".utf8)
        )
        XCTAssertEqual(
            terminal.draft.segments.map(\.startTime.value),
            [0, 3]
        )
        XCTAssertEqual(
            terminal.draft.segments.map(\.endTimeExclusive.value),
            [2, 5]
        )
        XCTAssertNil(terminal.draft.segments.last?.nextStartTime)
        _ = try await setup.coordinator.commitCheckpoint(
            terminal.draft,
            using: setup.claim
        )
        let loadedTerminal = try await setup.coordinator.loadCompatibleCheckpoint(
            jobID: specification.jobID,
            expectedCodecSettingsHash: specification.output.contractID
        )
        let reopenedTerminal = try XCTUnwrap(loadedTerminal)
        XCTAssertEqual(
            reopenedTerminal.body.segments.map(\.nextStartTime?.value),
            [3, nil]
        )

        let assembledURL = fixture.output.appendingPathComponent(
            "dynamic-gap-assembled.mov"
        )
        let assembly = try await AVFoundationSegmentAssemblerV4().assemble(
            AVFoundationSegmentAssemblyRequestV4(
                artifactRootURL: fixture.store,
                segments: reopenedTerminal.body.segments,
                mediaTimelineStart: try WorkflowMediaTimeV4(
                    value: 0,
                    timescale: 30
                ),
                outputTimelineStart: try WorkflowMediaTimeV4(
                    value: 2,
                    timescale: 30
                ),
                destinationURL: assembledURL
            )
        )
        XCTAssertEqual(assembly.segmentCount, 2)
        XCTAssertEqual(
            CMTimeCompare(
                CMTime(
                    value: assembly.outputIdentity.duration.value,
                    timescale: assembly.outputIdentity.duration.timescale
                ),
                CMTime(value: 7, timescale: 30)
            ),
            0
        )
        let assembledAsset = AVURLAsset(
            url: assembledURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let assembledVideoTracks = try await assembledAsset.loadTracks(
            withMediaType: .video
        )
        let assembledVideoTrack = try XCTUnwrap(assembledVideoTracks.first)
        let assembledTrackRange = try await assembledVideoTrack.load(
            .timeRange
        )
        XCTAssertEqual(
            CMTimeCompare(
                assembledTrackRange.start,
                .zero
            ),
            0
        )
        let trackSegments = try await assembledVideoTrack.load(.segments)
        XCTAssertEqual(trackSegments.count, 4)
        let expectedTargetEdits: [
            (isEmpty: Bool, start: Int64, duration: Int64)
        ] = [
            (true, 0, 2),
            (false, 2, 2),
            (true, 4, 1),
            (false, 5, 2)
        ]
        for (actual, expected) in zip(trackSegments, expectedTargetEdits) {
            XCTAssertEqual(actual.isEmpty, expected.isEmpty)
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.target.start,
                    CMTime(value: expected.start, timescale: 30)
                ),
                0
            )
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.target.duration,
                    CMTime(value: expected.duration, timescale: 30)
                ),
                0
            )
        }
        let mediaEdits = trackSegments.filter { !$0.isEmpty }
        XCTAssertEqual(mediaEdits.count, 2)
        let expectedSourceEdits: [(start: Int64, duration: Int64)] = [
            (0, 2),
            (2, 2)
        ]
        for (actual, expected) in zip(mediaEdits, expectedSourceEdits) {
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.source.start,
                    CMTime(value: expected.start, timescale: 30)
                ),
                0
            )
            XCTAssertEqual(
                CMTimeCompare(
                    actual.timeMapping.source.duration,
                    CMTime(value: expected.duration, timescale: 30)
                ),
                0
            )
        }
        let presentationTimes = try await videoConcreteOutputPresentationTimes(
            assembledURL
        )
        XCTAssertEqual(presentationTimes.count, 4)
        for (actual, expected) in zip(presentationTimes, [2, 3, 5, 6]) {
            XCTAssertEqual(
                CMTimeCompare(
                    actual,
                    CMTime(value: Int64(expected), timescale: 30)
                ),
                0
            )
        }
    }
}

private actor CheckpointEngineProbeV4:
    PreparedCheckpointableTemporalFrameUpscaler {
    nonisolated let sourcePixelBufferAttributes = PixelBufferAttributes()
    nonisolated let destinationPixelBufferAttributes = PixelBufferAttributes()
    nonisolated let actualBackendID = UpscaleBackendID.mirmirDeterministicCPU
    nonisolated let maximumOutputFramesPerInput = 1

    private let checkpoint: Data
    private var restored: Data?
    private var checkpointOrdinal: Int64?

    init(checkpoint: Data) {
        self.checkpoint = checkpoint
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {}

    func processTemporal(
        source: FramePixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming
    ) async throws -> [TemporalOutputFrame] {
        []
    }

    func finish() async throws {}

    func makeTemporalCheckpoint(
        planSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64
    ) async throws -> Data {
        checkpointOrdinal = lastCompletedInputOrdinal
        return checkpoint
    }

    func restoreTemporalCheckpoint(
        _ data: Data,
        planSHA256: ASHSHA256V4
    ) async throws {
        restored = data
    }

    func restoredCheckpoint() -> Data? { restored }
    func lastCheckpointOrdinal() -> Int64? { checkpointOrdinal }
}

private struct SegmentCheckpointFixtureV4 {
    let root: URL
    let store: URL
    let output: URL
}

private extension WorkflowSegmentCheckpointStoreV4Tests {
    func makeFixture() throws -> SegmentCheckpointFixtureV4 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "segment-checkpoint-v4-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = root.appendingPathComponent("store", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SegmentCheckpointFixtureV4(root: root, store: store, output: output)
    }

    func makeRunningCoordinator(
        fixture: SegmentCheckpointFixtureV4
    ) async throws -> (
        coordinator: WorkflowDurableCoordinatorV4,
        claim: WorkflowDispatchClaimV4
    ) {
        let coordinator = try WorkflowDurableCoordinatorV4(rootURL: fixture.store)
        let specification = try makeSpecification()
        try await enqueue(specification, into: coordinator)
        let probing = try await coordinator.acquire(
            acquisition(
                jobID: nil,
                lease: "lease-fixture",
                worker: "worker-fixture",
                event: "event-claim-fixture",
                command: "command-claim-fixture",
                from: .queued,
                to: .probing,
                attempt: nil
            )
        )
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-planned-fixture",
                command: "command-planned-fixture",
                from: .probing,
                to: .planned,
                attempt: nil
            ),
            using: probing
        )
        let attempt = try WorkflowAttemptID("attempt-fixture")
        _ = try await coordinator.transition(
            lifecycle(
                event: "event-running-fixture",
                command: "command-running-fixture",
                from: .planned,
                to: .running,
                attempt: attempt
            ),
            using: probing
        )
        return (
            coordinator,
            try await coordinator.currentClaim(for: probing)
        )
    }

    func publicationRequest(
        checkpoint: Int,
        sourceURL: URL,
        existing: [WorkflowSegmentCheckpointV4],
        start: Int64,
        end: Int64,
        nextStart: Int64?,
        nextSample: UInt64
    ) throws -> WorkflowSegmentCheckpointPublicationRequestV4 {
        try WorkflowSegmentCheckpointPublicationRequestV4(
            checkpointID: WorkflowCheckpointIDV4("checkpoint-\(checkpoint)"),
            segmentArtifactID: WorkflowArtifactIDV4(
                "segment-artifact-\(checkpoint)"
            ),
            temporalArtifactID: WorkflowArtifactIDV4(
                "temporal-artifact-\(checkpoint)"
            ),
            measurementArtifactID: WorkflowArtifactIDV4(
                "measurement-artifact-\(checkpoint)"
            ),
            sourceSegmentURL: sourceURL,
            existingSegments: existing,
            startTime: WorkflowMediaTimeV4(value: start, timescale: 30),
            endTimeExclusive: WorkflowMediaTimeV4(value: end, timescale: 30),
            nextStartTime: try nextStart.map {
                try WorkflowMediaTimeV4(value: $0, timescale: 30)
            },
            codecSettingsHash: WorkflowOutputContractID(digest(9)),
            trackProgress: [
                WorkflowTrackProgressV4(
                    trackID: "video-primary",
                    kind: .video,
                    nextInputSampleIndex: nextSample,
                    nextOutputSampleIndex: nextSample,
                    lastInputTime: WorkflowMediaTimeV4(
                        value: Int64(nextSample - 1),
                        timescale: 30
                    ),
                    lastOutputTime: WorkflowMediaTimeV4(
                        value: Int64(nextSample - 1),
                        timescale: 30
                    ),
                    isComplete: nextSample == 4
                )
            ],
            committedAt: WorkflowSystemWallClockV4().now(),
            lastCompletedInputOrdinal: Int64(nextSample - 1)
        )
    }

    func makeSpecification() throws -> WorkflowJobSpecification {
        let sourceBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("source-bookmark-segment-v4"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(1))
        )
        let outputBookmark = try WorkflowBookmarkReference(
            bookmarkID: WorkflowBookmarkID("output-bookmark-segment-v4"),
            revision: 1,
            documentHash: WorkflowBookmarkDocumentHash(digest(2))
        )
        let runtime = WorkflowRuntimeBinding(
            id: try WorkflowRuntimeBindingID(digest(3)),
            runtimeManifestID: try WorkflowRuntimeManifestID(digest(4)),
            planID: try WorkflowPlanID(digest(5)),
            backendID: try WorkflowBackendID("backend-v4"),
            backendRevisionID: try WorkflowBackendRevisionID("backend-v4-p06"),
            mediaContractID: try WorkflowMediaContractID(digest(6))
        )
        return WorkflowJobSpecification(
            jobID: try WorkflowJobID("job-segment-v4"),
            requestID: try WorkflowRequestID(digest(7)),
            source: WorkflowSourceSpecification(
                identityID: try WorkflowSourceIdentityID(digest(8)),
                bookmark: sourceBookmark
            ),
            output: WorkflowOutputSpecification(
                contractID: try WorkflowOutputContractID(digest(9)),
                directoryBookmark: outputBookmark,
                fileName: try WorkflowOutputFileName("assembled.mov")
            ),
            runtimeBinding: runtime
        )
    }

    func enqueue(
        _ specification: WorkflowJobSpecification,
        into coordinator: WorkflowDurableCoordinatorV4
    ) async throws {
        _ = try await coordinator.append(
            WorkflowEventDraft(
                eventID: try WorkflowEventID("event-enqueue-segment-v4"),
                commandID: try WorkflowCommandID("command-enqueue-segment-v4"),
                scope: .job(specification.jobID),
                jobBinding: specification.binding,
                attemptID: nil,
                event: .jobEnqueued(specification)
            )
        )
    }

    func acquisition(
        jobID: WorkflowJobID?,
        lease: String,
        worker: String,
        event: String,
        command: String,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle,
        attempt: WorkflowAttemptID?
    ) throws -> WorkflowLeaseAcquisitionRequestV4 {
        try WorkflowLeaseAcquisitionRequestV4(
            jobID: jobID,
            leaseID: WorkflowLeaseIDV4(lease),
            workerID: WorkflowWorkerIDV4(worker),
            eventID: WorkflowEventID(event),
            commandID: WorkflowCommandID(command),
            expectedLifecycle: from,
            targetLifecycle: to,
            attemptID: attempt,
            duration: WorkflowLeaseIntervalV4(
                nanoseconds: 60_000_000_000
            )
        )
    }

    func lifecycle(
        event: String,
        command: String,
        from: WorkflowJobLifecycle,
        to: WorkflowJobLifecycle,
        attempt: WorkflowAttemptID?
    ) throws -> WorkflowLifecycleCommandV4 {
        try WorkflowLifecycleCommandV4(
            eventID: WorkflowEventID(event),
            commandID: WorkflowCommandID(command),
            from: from,
            to: to,
            attemptID: attempt
        )
    }

    func writeSegment(
        to url: URL,
        colors: [(UInt8, UInt8, UInt8)]
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16,
                AVVideoCompressionPropertiesKey: [
                    AVVideoMaxKeyFrameIntervalKey: 1,
                    AVVideoAverageBitRateKey: 200_000,
                    AVVideoExpectedSourceFrameRateKey: 30
                ]
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        guard writer.canAdd(input) else {
            throw AVFoundationSegmentV4Error.exportUnavailable
        }
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .commonIdentifierTitle
        metadata.value = "Mirmir deterministic segment" as NSString
        writer.metadata = [metadata]
        writer.add(input)
        guard writer.startWriting() else {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: writer.error)
            )
        }
        writer.startSession(atSourceTime: .zero)
        for (index, color) in colors.enumerated() {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else {
                throw AVFoundationSegmentV4Error.exportUnavailable
            }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                pool,
                &optional
            ) == kCVReturnSuccess,
            let buffer = optional else {
                throw AVFoundationSegmentV4Error.exportUnavailable
            }
            fill(buffer, color: color)
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: Int64(index), timescale: 30)
            ) else {
                throw AVFoundationSegmentV4Error.exportFailed(
                    String(describing: writer.error)
                )
            }
        }
        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(value: Int64(colors.count), timescale: 30)
        )
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw AVFoundationSegmentV4Error.exportFailed(
                String(describing: writer.error)
            )
        }
    }

    func fill(
        _ buffer: CVPixelBuffer,
        color: (UInt8, UInt8, UInt8)
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        for row in 0 ..< height {
            let bytes = base.advanced(by: row * stride)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                bytes[column * 4] = color.2
                bytes[column * 4 + 1] = color.1
                bytes[column * 4 + 2] = color.0
                bytes[column * 4 + 3] = 255
            }
        }
    }

    func decodedVideoReceipt(_ url: URL) async throws -> String {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AVFoundationSegmentV4Error.unreadableAsset("missing video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        guard reader.canAdd(output) else {
            throw AVFoundationSegmentV4Error.unreadableAsset("decode rejected")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        var hasher = SHA256()
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else {
                throw AVFoundationSegmentV4Error.unreadableAsset("missing image")
            }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            guard let base = CVPixelBufferGetBaseAddress(image) else {
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
                throw AVFoundationSegmentV4Error.unreadableAsset("missing pixels")
            }
            let byteCount = CVPixelBufferGetBytesPerRow(image)
                * CVPixelBufferGetHeight(image)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: base,
                count: byteCount
            ))
            for time in [
                CMSampleBufferGetPresentationTimeStamp(sample),
                CMSampleBufferGetDuration(sample)
            ] {
                var value = time.value.bigEndian
                var timescale = time.timescale.bigEndian
                withUnsafeBytes(of: &value) {
                    hasher.update(bufferPointer: $0)
                }
                withUnsafeBytes(of: &timescale) {
                    hasher.update(bufferPointer: $0)
                }
            }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
        }
        guard reader.status == .completed else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func videoConcreteOutputPresentationTimes(
        _ url: URL
    ) async throws -> [CMTime] {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let track = try await asset.loadTracks(
            withMediaType: .video
        ).first else {
            throw AVFoundationSegmentV4Error.unreadableAsset("missing video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                "sample timing read rejected"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            guard time.isNumeric,
                  !time.flags.contains(.hasBeenRounded) else {
                throw AVFoundationSegmentV4Error.assembledTimingMismatch
            }
            times.append(time)
        }
        guard reader.status == .completed else {
            throw AVFoundationSegmentV4Error.unreadableAsset(
                String(describing: reader.error)
            )
        }
        return times
    }
}

private func digest(_ value: Int) -> String {
    String(format: "%064llx", value)
}
