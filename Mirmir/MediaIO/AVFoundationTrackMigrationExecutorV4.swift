import AVFoundation
import CoreMedia
import Foundation

enum AVFoundationTrackMigrationExecutionStageV4: String, CaseIterable,
    Codable, Hashable, Sendable {
    case validating
    case preparingReaderWriter = "preparing_reader_writer"
    case migrating
    case finalizing
    case verifying
    case publishing
    case completed
}

struct AVFoundationTrackMigrationProgressV4: Equatable, Hashable, Sendable {
    let stage: AVFoundationTrackMigrationExecutionStageV4
    let trackID: MediaTrackStableIDV4?
    let migratedSampleCount: Int64
    let finishedTrackCount: Int
    let totalTrackCount: Int
}

struct AVFoundationTrackMigrationFailureV4: Equatable, Hashable, Sendable {
    let domainID: String
    let code: Int
    let errorTypeID: String

    init(_ error: Error?) {
        guard let error else {
            domainID = "none"
            code = 0
            errorTypeID = "none"
            return
        }
        let nsError = error as NSError
        domainID = Self.stableToken(nsError.domain)
        code = nsError.code
        errorTypeID = Self.stableToken(String(reflecting: type(of: error)))
    }

    private static func stableToken(_ value: String) -> String {
        if MediaTrackGraphLexiconV4.isStableToken(value) {
            return value
        }
        return "utf8_" + value.utf8.map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum AVFoundationTrackMigrationExecutorV4Error: Error, Equatable, Sendable {
    case cancelled
    case sourceAndDestinationMustDiffer
    case destinationDirectoryMissing
    case destinationExists
    case unsupportedBlueprintSchema(String)
    case sourcePlanIdentityMismatch
    case blueprintMismatch
    case sourceAssetMismatch(expected: ASHSHA256V4, actual: ASHSHA256V4)
    case duplicateProcessingHook(MediaTrackStableIDV4)
    case missingProcessingHook(MediaTrackStableIDV4)
    case unexpectedProcessingHook(MediaTrackStableIDV4)
    case invalidProcessingHook(MediaTrackStableIDV4, reason: String)
    case unsupportedTrack(MediaTrackStableIDV4, reason: String)
    case unsupportedGroup(MediaTrackGroupStableIDV4, reason: String)
    case unsupportedAssociation(UInt32, reason: String)
    case sourceTrackInventoryMismatch
    case readerCreationFailed(AVFoundationTrackMigrationFailureV4)
    case writerCreationFailed(AVFoundationTrackMigrationFailureV4)
    case readerRejectedTrack(MediaTrackStableIDV4)
    case writerRejectedTrack(MediaTrackStableIDV4)
    case writerRejectedGroup(MediaTrackGroupStableIDV4)
    case writerRejectedAssociation(UInt32)
    case readerStartFailed(AVFoundationTrackMigrationFailureV4)
    case writerStartFailed(AVFoundationTrackMigrationFailureV4)
    case processorFailed(
        trackID: MediaTrackStableIDV4,
        failure: AVFoundationTrackMigrationFailureV4
    )
    case processedSampleChangedTiming(MediaTrackStableIDV4)
    case processedSampleIsNotVideo(MediaTrackStableIDV4)
    case appendFailed(
        trackID: MediaTrackStableIDV4,
        failure: AVFoundationTrackMigrationFailureV4
    )
    case sampleStreamReadFailed(
        trackID: MediaTrackStableIDV4,
        failure: AVFoundationTrackMigrationFailureV4
    )
    case sampleStreamUnrepresentable(
        trackID: MediaTrackStableIDV4,
        status: Int32
    )
    case sampleStreamDigestMismatch(
        trackID: MediaTrackStableIDV4,
        expected: ASHSHA256V4,
        actual: ASHSHA256V4
    )
    case readerFailed(AVFoundationTrackMigrationFailureV4)
    case writerFailed(AVFoundationTrackMigrationFailureV4)
    case semanticVerificationFailed(MediaTrackSemanticVerificationReportV4)
    case publishFailed(AVFoundationTrackMigrationFailureV4)
}

final class AVFoundationTrackMigrationCancellationV4: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }
}

struct AVFoundationVideoSampleV4: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

struct AVFoundationVideoTrackProcessingHookV4: @unchecked Sendable {
    typealias Processor = @Sendable (
        AVFoundationVideoSampleV4
    ) async throws -> AVFoundationVideoSampleV4

    let trackID: MediaTrackStableIDV4
    let readerOutputSettings: [String: Any]
    let writerOutputSettings: [String: Any]
    let declaredOutputFormats: [MediaTrackFormatDescriptorV4]
    let process: Processor

    init(
        trackID: MediaTrackStableIDV4,
        readerOutputSettings: [String: Any],
        writerOutputSettings: [String: Any],
        declaredOutputFormats: [MediaTrackFormatDescriptorV4],
        process: @escaping Processor
    ) {
        self.trackID = trackID
        self.readerOutputSettings = readerOutputSettings
        self.writerOutputSettings = writerOutputSettings
        self.declaredOutputFormats = declaredOutputFormats
        self.process = process
    }
}

struct AVFoundationTrackMigrationExecutionRequestV4: @unchecked Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let outputFileType: AVFileType
    let overwriteExistingFile: Bool
    let sourceGraph: MediaTrackGraphV4
    let identifiedPlan: MediaTrackGraphIdentifiedPlanV4
    let blueprint: AVFoundationTrackMigrationBlueprintV4
    let videoProcessingHooks: [AVFoundationVideoTrackProcessingHookV4]

    init(
        sourceURL: URL,
        destinationURL: URL,
        outputFileType: AVFileType = .mov,
        overwriteExistingFile: Bool = false,
        sourceGraph: MediaTrackGraphV4,
        identifiedPlan: MediaTrackGraphIdentifiedPlanV4,
        blueprint: AVFoundationTrackMigrationBlueprintV4,
        videoProcessingHooks: [AVFoundationVideoTrackProcessingHookV4] = []
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.outputFileType = outputFileType
        self.overwriteExistingFile = overwriteExistingFile
        self.sourceGraph = sourceGraph
        self.identifiedPlan = identifiedPlan
        self.blueprint = blueprint
        self.videoProcessingHooks = videoProcessingHooks
    }
}

struct AVFoundationTrackMigrationTrackResultV4: Codable, Equatable, Hashable,
    Sendable {
    let trackID: MediaTrackStableIDV4
    let action: MediaTrackActionV4
    let migratedSampleCount: Int64
    let sourceSampleStreamSHA256: ASHSHA256V4?
    let outputSampleStreamSHA256: ASHSHA256V4?
}

struct AVFoundationTrackMigrationExecutionResultV4: Equatable, Sendable {
    let destinationURL: URL
    let sourceGraphSHA256: ASHSHA256V4
    let planSHA256: ASHSHA256V4
    let blueprintSHA256: ASHSHA256V4
    let trackResults: [AVFoundationTrackMigrationTrackResultV4]
    let outputGraph: MediaTrackGraphV4
    let verificationReport: MediaTrackSemanticVerificationReportV4
}

struct AVFoundationTrackMigrationExecutorV4: Sendable {
    typealias ProgressHandler = @Sendable (
        AVFoundationTrackMigrationProgressV4
    ) -> Void

    func execute(
        _ request: AVFoundationTrackMigrationExecutionRequestV4,
        cancellation: AVFoundationTrackMigrationCancellationV4 = .init(),
        progress: ProgressHandler? = nil
    ) async throws -> AVFoundationTrackMigrationExecutionResultV4 {
        do {
            emit(.validating, progress: progress)
            try cancellation.check()
            let hookByTrackID = try validate(request)

            let sourceAsset = AVURLAsset(
                url: request.sourceURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            let observedSource = try await AVFoundationTrackGraphAdapterV4
                .probe(asset: sourceAsset)
            let observedSourceHash = try observedSource.canonicalSHA256
            let expectedSourceHash = try request.sourceGraph.canonicalSHA256
            guard observedSourceHash == expectedSourceHash else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sourceAssetMismatch(
                        expected: expectedSourceHash,
                        actual: observedSourceHash
                    )
            }
            try cancellation.check()

            let destination = try AtomicMigrationDestinationV4(
                finalURL: request.destinationURL,
                overwriteExistingFile: request.overwriteExistingFile
            )
            defer { destination.discard() }

            emit(.preparingReaderWriter, progress: progress)
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: sourceAsset)
            } catch {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .readerCreationFailed(.init(error))
            }
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(
                    outputURL: destination.temporaryURL,
                    fileType: request.outputFileType
                )
            } catch {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .writerCreationFailed(.init(error))
            }

            var pipes = try await preparePipes(
                sourceAsset: sourceAsset,
                sourceGraph: request.sourceGraph,
                plan: request.identifiedPlan.plan,
                blueprint: request.blueprint,
                hooks: hookByTrackID,
                reader: reader,
                writer: writer
            )
            try prepareGroupsAndAssociations(
                plan: request.identifiedPlan.plan,
                blueprint: request.blueprint,
                pipes: pipes,
                writer: writer
            )
            try cancellation.check()

            guard reader.startReading() else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .readerStartFailed(.init(reader.error))
            }
            guard writer.startWriting() else {
                reader.cancelReading()
                throw AVFoundationTrackMigrationExecutorV4Error
                    .writerStartFailed(.init(writer.error))
            }
            writer.startSession(
                atSourceTime: try sessionStartTime(
                    plan: request.identifiedPlan.plan
                )
            )

            emit(
                .migrating,
                totalTrackCount: pipes.count,
                progress: progress
            )
            let writerBox = AssetWriterBoxV4(writer)
            do {
                try await drain(
                    pipes: &pipes,
                    reader: reader,
                    writer: writer,
                    cancellation: cancellation,
                    progress: progress
                )
                try await waitForReaderCompletion(
                    reader,
                    writer: writer,
                    cancellation: cancellation
                )

                emit(
                    .finalizing,
                    migratedSampleCount: pipes.reduce(0) {
                        $0 + $1.sampleCount
                    },
                    finishedTrackCount: pipes.count,
                    totalTrackCount: pipes.count,
                    progress: progress
                )
                await finishWriting(writerBox)
                try cancellation.check()
                guard writer.status == .completed else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .writerFailed(.init(writer.error))
                }
            } catch {
                reader.cancelReading()
                writer.cancelWriting()
                throw error
            }

            emit(
                .verifying,
                migratedSampleCount: pipes.reduce(0) { $0 + $1.sampleCount },
                finishedTrackCount: pipes.count,
                totalTrackCount: pipes.count,
                progress: progress
            )
            let outputAsset = AVURLAsset(
                url: destination.temporaryURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            )
            let outputGraph = try await AVFoundationTrackGraphAdapterV4
                .probe(asset: outputAsset)
            let report = try MediaTrackSemanticVerifierV4.verify(
                plan: request.identifiedPlan,
                output: outputGraph
            )
            guard report.isConformant else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .semanticVerificationFailed(report)
            }
            let outputStreamDigests = try await verifyPassThroughStreams(
                outputAsset: outputAsset,
                outputGraph: outputGraph,
                pipes: pipes,
                cancellation: cancellation
            )
            try cancellation.check()

            emit(
                .publishing,
                migratedSampleCount: pipes.reduce(0) { $0 + $1.sampleCount },
                finishedTrackCount: pipes.count,
                totalTrackCount: pipes.count,
                progress: progress
            )
            do {
                try destination.publish()
            } catch {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .publishFailed(.init(error))
            }

            let result = AVFoundationTrackMigrationExecutionResultV4(
                destinationURL: request.destinationURL,
                sourceGraphSHA256: expectedSourceHash,
                planSHA256: request.identifiedPlan.planSHA256,
                blueprintSHA256: try request.blueprint.canonicalSHA256,
                trackResults: pipes.map {
                    AVFoundationTrackMigrationTrackResultV4(
                        trackID: $0.trackID,
                        action: $0.action,
                        migratedSampleCount: $0.sampleCount,
                        sourceSampleStreamSHA256: $0.action == .passThrough
                            ? $0.sampleStream.digest
                            : nil,
                        outputSampleStreamSHA256: outputStreamDigests[
                            $0.trackID
                        ]
                    )
                },
                outputGraph: outputGraph,
                verificationReport: report
            )
            emit(
                .completed,
                migratedSampleCount: pipes.reduce(0) { $0 + $1.sampleCount },
                finishedTrackCount: pipes.count,
                totalTrackCount: pipes.count,
                progress: progress
            )
            return result
        } catch is CancellationError {
            throw AVFoundationTrackMigrationExecutorV4Error.cancelled
        }
    }
}

private extension AVFoundationTrackMigrationExecutorV4 {
    struct TrackPipe {
        let trackID: MediaTrackStableIDV4
        let action: MediaTrackActionV4
        let readerOutput: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput
        let hook: AVFoundationVideoTrackProcessingHookV4?
        var isFinished = false
        var sampleCount: Int64 = 0
        var sampleStream = SampleStreamAccumulatorV4()
    }

    func validate(
        _ request: AVFoundationTrackMigrationExecutionRequestV4
    ) throws -> [
        MediaTrackStableIDV4: AVFoundationVideoTrackProcessingHookV4
    ] {
        guard request.sourceURL.standardizedFileURL
            != request.destinationURL.standardizedFileURL else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceAndDestinationMustDiffer
        }
        try request.sourceGraph.validate()
        try request.identifiedPlan.verify()
        let sourceHash = try request.sourceGraph.canonicalSHA256
        guard sourceHash == request.identifiedPlan.plan.sourceGraphSHA256 else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourcePlanIdentityMismatch
        }
        guard request.blueprint.schemaID
            == AVFoundationTrackMigrationBlueprintV4.currentSchemaID else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .unsupportedBlueprintSchema(request.blueprint.schemaID)
        }
        let expectedBlueprint = try AVFoundationTrackMigrationPlannerV4
            .makeBlueprint(
                source: request.sourceGraph,
                plan: request.identifiedPlan
            )
        guard expectedBlueprint == request.blueprint else {
            throw AVFoundationTrackMigrationExecutorV4Error.blueprintMismatch
        }

        for migration in request.blueprint.tracks {
            switch migration.outcome {
            case .directReaderWriter, .requiresProcessor, .authorizedDrop:
                break
            case .requiresComposition:
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        migration.trackID,
                        reason: "composition_required"
                    )
            case .incompatible:
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        migration.trackID,
                        reason: "blueprint_incompatible"
                    )
            }
        }
        for migration in request.blueprint.groups {
            guard migration.outcome != .incompatible,
                  migration.outcome != .requiresComposition else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        migration.groupID,
                        reason: "blueprint_incompatible"
                    )
            }
        }
        for migration in request.blueprint.associations {
            guard migration.outcome != .incompatible,
                  migration.outcome != .requiresComposition else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedAssociation(
                        migration.ordinal,
                        reason: "blueprint_incompatible"
                    )
            }
        }

        let intrinsicRoleIDs = Set([
            AVMediaCharacteristic.visual.rawValue,
            AVMediaCharacteristic.audible.rawValue,
            AVMediaCharacteristic.legible.rawValue,
            AVMediaCharacteristic.frameBased.rawValue,
            AVMediaCharacteristic.isMainProgramContent.rawValue
        ])
        for planned in request.identifiedPlan.plan.tracks {
            guard let expected = planned.expectedOutput else { continue }
            if expected.kind == .auxiliary {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "auxiliary_or_muxed_writer_support_unproven"
                    )
            }
            if expected.formatDescriptors.contains(where: {
                $0.completeness != .complete
            }) {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "partial_or_unknown_format_descriptor"
                    )
            }
            if expected.edits.count > 1
                || expected.edits.contains(where: { edit in
                    edit.isEmpty || edit.source != edit.target
                }) {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "nontrivial_edit_requires_composition"
                    )
            }
            if !Set(expected.roleIDs).isSubset(of: intrinsicRoleIDs) {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "media_characteristic_not_writable"
                    )
            }
            if let languageCode = expected.language.languageCode,
               !isISO6392(languageCode) {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "language_code_not_iso_639_2"
                    )
            }
            if let languageTag = expected.language.extendedLanguageTag,
               !isBCP47Like(languageTag) {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "extended_language_tag_invalid"
                    )
            }
        }
        for planned in request.identifiedPlan.plan.groups {
            guard let expected = planned.expectedOutput else { continue }
            guard expected.allowsEmptySelection,
                  expected.defaultTrackID == nil else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        expected.identity.stableID,
                        reason: "empty_selection_policy_not_writable"
                    )
            }
        }

        var hooks: [
            MediaTrackStableIDV4: AVFoundationVideoTrackProcessingHookV4
        ] = [:]
        for hook in request.videoProcessingHooks {
            guard hooks.updateValue(hook, forKey: hook.trackID) == nil else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .duplicateProcessingHook(hook.trackID)
            }
        }
        let hookTrackIDs = Set(hooks.keys)
        let requiredHookTracks = request.identifiedPlan.plan.tracks.filter {
            $0.action == .process || $0.action == .transcode
        }
        let requiredHookIDs = Set(requiredHookTracks.map {
            $0.source.identity.stableID
        })
        if let missing = requiredHookIDs.subtracting(hookTrackIDs).sorted()
            .first {
            throw AVFoundationTrackMigrationExecutorV4Error
                .missingProcessingHook(missing)
        }
        if let unexpected = hookTrackIDs.subtracting(requiredHookIDs).sorted()
            .first {
            throw AVFoundationTrackMigrationExecutorV4Error
                .unexpectedProcessingHook(unexpected)
        }
        for planned in requiredHookTracks {
            let id = planned.source.identity.stableID
            guard planned.source.kind == .video,
                  let expected = planned.expectedOutput,
                  let hook = hooks[id],
                  !hook.readerOutputSettings.isEmpty,
                  !hook.writerOutputSettings.isEmpty,
                  hook.declaredOutputFormats == expected.formatDescriptors,
                  expected.formatDescriptors.count == 1 else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .invalidProcessingHook(
                        id,
                        reason: "video_settings_or_declared_format_invalid"
                    )
            }
        }
        return hooks
    }

    func isISO6392(_ value: String) -> Bool {
        value.utf8.count == 3 && value.utf8.allSatisfy {
            (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
        }
    }

    func isBCP47Like(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        return !pieces.isEmpty && pieces.allSatisfy { piece in
            (1...8).contains(piece.utf8.count) && piece.utf8.allSatisfy {
                (0x30...0x39).contains($0)
                    || (0x41...0x5a).contains($0)
                    || (0x61...0x7a).contains($0)
            }
        }
    }

    func preparePipes(
        sourceAsset: AVAsset,
        sourceGraph: MediaTrackGraphV4,
        plan: MediaTrackGraphPlanV4,
        blueprint: AVFoundationTrackMigrationBlueprintV4,
        hooks: [
            MediaTrackStableIDV4: AVFoundationVideoTrackProcessingHookV4
        ],
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> [TrackPipe] {
        let sourceTracks = try await sourceAsset.load(.tracks)
        guard sourceTracks.count == sourceGraph.tracks.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let trackByID = Dictionary(
            uniqueKeysWithValues: zip(sourceGraph.tracks, sourceTracks).map {
                ($0.identity.stableID, $1)
            }
        )
        let migrationByID = Dictionary(
            uniqueKeysWithValues: blueprint.tracks.map { ($0.trackID, $0) }
        )
        var pipes: [TrackPipe] = []
        for planned in plan.tracks {
            let id = planned.source.identity.stableID
            guard let sourceTrack = trackByID[id],
                  let migration = migrationByID[id],
                  migration.sourceOrdinal == planned.source.identity.ordinal,
                  migration.action == planned.action else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sourceTrackInventoryMismatch
            }
            if planned.action == .dropWithConsent {
                continue
            }

            let formatDescriptions = try await sourceTrack
                .load(.formatDescriptions)
            let readerOutput: AVAssetReaderTrackOutput
            let writerInput: AVAssetWriterInput
            let hook = hooks[id]
            switch planned.action {
            case .passThrough:
                guard migration.outcome == .directReaderWriter,
                      migration.readerStrategy == .encodedTrackOutput,
                      migration.writerStrategy == .sourceFormatHintInput,
                      formatDescriptions.count == 1,
                      planned.source.formatDescriptors.count == 1 else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedTrack(
                            id,
                            reason: "single_source_format_required"
                        )
                }
                readerOutput = AVAssetReaderTrackOutput(
                    track: sourceTrack,
                    outputSettings: nil
                )
                readerOutput.alwaysCopiesSampleData = false
                writerInput = AVAssetWriterInput(
                    mediaType: sourceTrack.mediaType,
                    outputSettings: nil,
                    sourceFormatHint: formatDescriptions[0]
                )
            case .process, .transcode:
                guard migration.outcome == .requiresProcessor,
                      let hook else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .missingProcessingHook(id)
                }
                guard writer.canApply(
                    outputSettings: hook.writerOutputSettings,
                    forMediaType: .video
                ) else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .invalidProcessingHook(
                            id,
                            reason: "writer_rejected_output_settings"
                        )
                }
                readerOutput = AVAssetReaderTrackOutput(
                    track: sourceTrack,
                    outputSettings: hook.readerOutputSettings
                )
                readerOutput.alwaysCopiesSampleData = true
                writerInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: hook.writerOutputSettings
                )
            case .dropWithConsent:
                preconditionFailure("Dropped tracks do not create a pipe.")
            }
            writerInput.expectsMediaDataInRealTime = false
            try await copyTrackProperties(
                from: sourceTrack,
                expected: planned.expectedOutput,
                to: writerInput
            )
            guard reader.canAdd(readerOutput) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .readerRejectedTrack(id)
            }
            guard writer.canAdd(writerInput) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .writerRejectedTrack(id)
            }
            reader.add(readerOutput)
            writer.add(writerInput)
            pipes.append(TrackPipe(
                trackID: id,
                action: planned.action,
                readerOutput: readerOutput,
                writerInput: writerInput,
                hook: hook
            ))
        }
        return pipes
    }

    func copyTrackProperties(
        from track: AVAssetTrack,
        expected: MediaTrackNodeV4?,
        to input: AVAssetWriterInput
    ) async throws {
        guard let expected else { return }
        input.metadata = try await track.load(.metadata)
        input.languageCode = try await track.load(.languageCode)
        input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
        if track.mediaType == .video || track.mediaType == .muxed {
            input.naturalSize = try await track.load(.naturalSize)
            input.transform = try await track.load(.preferredTransform)
        }
        if track.mediaType == .audio {
            input.preferredVolume = try await track.load(.preferredVolume)
        } else {
            guard expected.timebase.numerator == 1,
                  expected.timebase.denominator <= Int64(Int32.max) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "media_timescale_not_representable"
                    )
            }
            input.mediaTimeScale = Int32(expected.timebase.denominator)
        }
    }

    func prepareGroupsAndAssociations(
        plan: MediaTrackGraphPlanV4,
        blueprint: AVFoundationTrackMigrationBlueprintV4,
        pipes: [TrackPipe],
        writer: AVAssetWriter
    ) throws {
        let inputByID = Dictionary(
            uniqueKeysWithValues: pipes.map { ($0.trackID, $0.writerInput) }
        )
        let expectedTrackByID = Dictionary(
            uniqueKeysWithValues: plan.tracks.compactMap { planned in
                planned.expectedOutput.map {
                    ($0.identity.stableID, $0)
                }
            }
        )
        let groupMigrationByID = Dictionary(
            uniqueKeysWithValues: blueprint.groups.map {
                ($0.groupID, $0)
            }
        )
        var groupedTrackIDs = Set<MediaTrackStableIDV4>()
        for planned in plan.groups {
            guard let migration = groupMigrationByID[
                planned.source.identity.stableID
            ] else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        planned.source.identity.stableID,
                        reason: "missing_blueprint_entry"
                    )
            }
            guard let expected = planned.expectedOutput else { continue }
            guard migration.usesAVAssetWriterInputGroup,
                  migration.outcome == .directReaderWriter,
                  expected.kind != .unknown else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        expected.identity.stableID,
                        reason: "writer_input_group_unavailable"
                    )
            }
            for id in expected.memberTrackIDs {
                guard groupedTrackIDs.insert(id).inserted else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedGroup(
                            expected.identity.stableID,
                            reason: "track_is_in_multiple_groups"
                        )
                }
            }
            let inputs = try expected.memberTrackIDs.map { id in
                guard let input = inputByID[id] else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedGroup(
                            expected.identity.stableID,
                            reason: "missing_member_input"
                        )
                }
                return input
            }
            let enabledMembers = expected.memberTrackIDs.filter {
                expectedTrackByID[$0]?.enabled == true
            }
            guard enabledMembers == expected.defaultTrackID.map({ [$0] }) ?? []
            else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        expected.identity.stableID,
                        reason: "enabled_state_not_representable_by_default"
                    )
            }
            let defaultInput = expected.defaultTrackID.flatMap {
                inputByID[$0]
            }
            let group = AVAssetWriterInputGroup(
                inputs: inputs,
                defaultInput: defaultInput
            )
            guard writer.canAdd(group) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .writerRejectedGroup(expected.identity.stableID)
            }
            writer.add(group)
        }

        for planned in plan.tracks {
            guard let expected = planned.expectedOutput,
                  !groupedTrackIDs.contains(expected.identity.stableID),
                  let input = inputByID[expected.identity.stableID] else {
                continue
            }
            input.marksOutputTrackAsEnabled = expected.enabled
        }

        let associationMigrationByOrdinal = Dictionary(
            uniqueKeysWithValues: blueprint.associations.map {
                ($0.ordinal, $0)
            }
        )
        for planned in plan.associations {
            guard planned.action == .passThrough else { continue }
            let association = planned.source
            guard let migration = associationMigrationByOrdinal[
                association.ordinal
            ], migration.usesAVAssetWriterInputAssociation,
                migration.outcome == .directReaderWriter,
                let sourceInput = inputByID[association.sourceTrackID],
                let targetInput = inputByID[association.targetTrackID] else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedAssociation(
                        association.ordinal,
                        reason: "missing_writer_input_or_blueprint_support"
                    )
            }
            let type = try associationType(for: association)
            guard sourceInput.canAddTrackAssociation(
                withTrackOf: targetInput,
                type: type
            ) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .writerRejectedAssociation(association.ordinal)
            }
            sourceInput.addTrackAssociation(
                withTrackOf: targetInput,
                type: type
            )
        }
    }

    func associationType(
        for association: MediaTrackAssociationV4
    ) throws -> String {
        let type: String
        switch association.kind {
        case .audioFallback:
            type = AVAssetTrack.AssociationType.audioFallback.rawValue
        case .chapterList:
            type = AVAssetTrack.AssociationType.chapterList.rawValue
        case .forcedSubtitlesOnly:
            type = AVAssetTrack.AssociationType.forcedSubtitlesOnly.rawValue
        case .selectionFollower:
            type = AVAssetTrack.AssociationType.selectionFollower.rawValue
        case .timecode:
            type = AVAssetTrack.AssociationType.timecode.rawValue
        case .metadataReferent:
            type = AVAssetTrack.AssociationType.metadataReferent.rawValue
        case .renderMetadataSource:
            if #available(macOS 26, *) {
                type = AVAssetTrack.AssociationType.renderMetadataSource.rawValue
                break
            }
            throw AVFoundationTrackMigrationExecutorV4Error
                .unsupportedAssociation(
                    association.ordinal,
                    reason: "render_metadata_source_requires_macos_26"
                )
        case .unknown:
            throw AVFoundationTrackMigrationExecutorV4Error
                .unsupportedAssociation(
                    association.ordinal,
                    reason: "unknown_association"
                )
        }
        guard association.sourceAssociationTypeID == type else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .unsupportedAssociation(
                    association.ordinal,
                    reason: "association_kind_and_source_type_contradict"
                )
        }
        return type
    }

    func sessionStartTime(plan: MediaTrackGraphPlanV4) throws -> CMTime {
        let starts = plan.tracks.compactMap {
            $0.expectedOutput?.timeRange.start
        }
        guard let earliest = starts.min() else { return .zero }
        guard earliest.denominator <= Int64(Int32.max) else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        return CMTime(
            value: earliest.numerator,
            timescale: Int32(earliest.denominator)
        )
    }

    func drain(
        pipes: inout [TrackPipe],
        reader: AVAssetReader,
        writer: AVAssetWriter,
        cancellation: AVFoundationTrackMigrationCancellationV4,
        progress: ProgressHandler?
    ) async throws {
        var finishedCount = 0
        while finishedCount < pipes.count {
            try cancellation.check()
            try checkStatuses(reader: reader, writer: writer)
            var advanced = false
            for index in pipes.indices where !pipes[index].isFinished {
                try cancellation.check()
                guard pipes[index].writerInput.isReadyForMoreMediaData else {
                    continue
                }
                guard let sourceSample = pipes[index].readerOutput
                    .copyNextSampleBuffer() else {
                    pipes[index].writerInput.markAsFinished()
                    pipes[index].isFinished = true
                    finishedCount += 1
                    advanced = true
                    emit(
                        .migrating,
                        trackID: pipes[index].trackID,
                        migratedSampleCount: pipes.reduce(0) {
                            $0 + $1.sampleCount
                        },
                        finishedTrackCount: finishedCount,
                        totalTrackCount: pipes.count,
                        progress: progress
                    )
                    continue
                }

                let outputSample: CMSampleBuffer
                if let hook = pipes[index].hook {
                    do {
                        outputSample = try await hook.process(
                            AVFoundationVideoSampleV4(
                                sampleBuffer: sourceSample
                            )
                        ).sampleBuffer
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .processorFailed(
                                trackID: pipes[index].trackID,
                                failure: .init(error)
                            )
                    }
                    try cancellation.check()
                    guard sampleTimingEqual(sourceSample, outputSample) else {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .processedSampleChangedTiming(
                                pipes[index].trackID
                            )
                    }
                    if let format = CMSampleBufferGetFormatDescription(
                        outputSample
                    ), CMFormatDescriptionGetMediaType(format)
                        != kCMMediaType_Video {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .processedSampleIsNotVideo(pipes[index].trackID)
                    }
                    try await waitUntilReady(
                        pipes[index].writerInput,
                        reader: reader,
                        writer: writer,
                        cancellation: cancellation
                    )
                } else {
                    outputSample = sourceSample
                    do {
                        try pipes[index].sampleStream.append(sourceSample)
                    } catch let error as SampleStreamAccumulatorV4.Error {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .sampleStreamUnrepresentable(
                                trackID: pipes[index].trackID,
                                status: error.status
                            )
                    }
                }
                guard pipes[index].writerInput.append(outputSample) else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .appendFailed(
                            trackID: pipes[index].trackID,
                            failure: .init(writer.error)
                        )
                }
                pipes[index].sampleCount += 1
                advanced = true
                emit(
                    .migrating,
                    trackID: pipes[index].trackID,
                    migratedSampleCount: pipes.reduce(0) {
                        $0 + $1.sampleCount
                    },
                    finishedTrackCount: finishedCount,
                    totalTrackCount: pipes.count,
                    progress: progress
                )
            }
            if !advanced {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    func verifyPassThroughStreams(
        outputAsset: AVAsset,
        outputGraph: MediaTrackGraphV4,
        pipes: [TrackPipe],
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws -> [MediaTrackStableIDV4: ASHSHA256V4] {
        let outputTracks = try await outputAsset.load(.tracks)
        guard outputTracks.count == outputGraph.tracks.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let trackByID = Dictionary(
            uniqueKeysWithValues: zip(outputGraph.tracks, outputTracks).map {
                ($0.identity.stableID, $1)
            }
        )
        var digests: [MediaTrackStableIDV4: ASHSHA256V4] = [:]
        for pipe in pipes where pipe.action == .passThrough {
            try cancellation.check()
            guard let outputTrack = trackByID[pipe.trackID] else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamReadFailed(
                        trackID: pipe.trackID,
                        failure: .init(nil)
                    )
            }
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: outputAsset)
            } catch {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamReadFailed(
                        trackID: pipe.trackID,
                        failure: .init(error)
                    )
            }
            let output = AVAssetReaderTrackOutput(
                track: outputTrack,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamReadFailed(
                        trackID: pipe.trackID,
                        failure: .init(nil)
                    )
            }
            reader.add(output)
            guard reader.startReading() else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamReadFailed(
                        trackID: pipe.trackID,
                        failure: .init(reader.error)
                    )
            }
            var accumulator = SampleStreamAccumulatorV4()
            while let sample = output.copyNextSampleBuffer() {
                try cancellation.check()
                do {
                    try accumulator.append(sample)
                } catch let error as SampleStreamAccumulatorV4.Error {
                    reader.cancelReading()
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .sampleStreamUnrepresentable(
                            trackID: pipe.trackID,
                            status: error.status
                        )
                }
            }
            guard reader.status == .completed else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamReadFailed(
                        trackID: pipe.trackID,
                        failure: .init(reader.error)
                    )
            }
            let expected = pipe.sampleStream.digest
            let actual = accumulator.digest
            guard actual == expected else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamDigestMismatch(
                        trackID: pipe.trackID,
                        expected: expected,
                        actual: actual
                    )
            }
            digests[pipe.trackID] = actual
        }
        return digests
    }

    func waitUntilReady(
        _ input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try cancellation.check()
            try checkStatuses(reader: reader, writer: writer)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitForReaderCompletion(
        _ reader: AVAssetReader,
        writer: AVAssetWriter,
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws {
        for _ in 0..<1_000 where reader.status == .reading {
            try cancellation.check()
            try checkStatuses(reader: reader, writer: writer)
            try await Task.sleep(for: .milliseconds(1))
        }
        guard reader.status == .completed else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .readerFailed(.init(reader.error))
        }
    }

    func checkStatuses(
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) throws {
        if reader.status == .failed || reader.status == .cancelled {
            throw AVFoundationTrackMigrationExecutorV4Error
                .readerFailed(.init(reader.error))
        }
        if writer.status == .failed || writer.status == .cancelled {
            throw AVFoundationTrackMigrationExecutorV4Error
                .writerFailed(.init(writer.error))
        }
    }

    func sampleTimingEqual(
        _ source: CMSampleBuffer,
        _ output: CMSampleBuffer
    ) -> Bool {
        CMTimeCompare(
            CMSampleBufferGetPresentationTimeStamp(source),
            CMSampleBufferGetPresentationTimeStamp(output)
        ) == 0 && CMTimeCompare(
            CMSampleBufferGetDecodeTimeStamp(source),
            CMSampleBufferGetDecodeTimeStamp(output)
        ) == 0 && CMTimeCompare(
            CMSampleBufferGetDuration(source),
            CMSampleBufferGetDuration(output)
        ) == 0
    }

    func finishWriting(_ box: AssetWriterBoxV4) async {
        await withCheckedContinuation { continuation in
            box.writer.finishWriting {
                continuation.resume()
            }
        }
    }

    func emit(
        _ stage: AVFoundationTrackMigrationExecutionStageV4,
        trackID: MediaTrackStableIDV4? = nil,
        migratedSampleCount: Int64 = 0,
        finishedTrackCount: Int = 0,
        totalTrackCount: Int = 0,
        progress: ProgressHandler?
    ) {
        progress?(AVFoundationTrackMigrationProgressV4(
            stage: stage,
            trackID: trackID,
            migratedSampleCount: migratedSampleCount,
            finishedTrackCount: finishedTrackCount,
            totalTrackCount: totalTrackCount
        ))
    }
}

private final class AssetWriterBoxV4: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private struct SampleStreamAccumulatorV4 {
    struct Error: Swift.Error {
        let status: Int32
    }

    private var canonicalBytes = Data()

    var digest: ASHSHA256V4 {
        var domainSeparated = Data(
            "ash-avfoundation-sample-stream-v4".utf8
        )
        domainSeparated.append(0)
        domainSeparated.append(canonicalBytes)
        return ASHSHA256V4(rawData: domainSeparated)
    }

    mutating func append(_ sample: CMSampleBuffer) throws {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        let format = CMSampleBufferGetFormatDescription(sample)
        let mediaType = format.map(CMFormatDescriptionGetMediaType) ?? 0
        let mediaSubtype = format.map(CMFormatDescriptionGetMediaSubType) ?? 0
        if sampleCount == 0 {
            canonicalBytes.append(0)
            appendTime(CMSampleBufferGetPresentationTimeStamp(sample))
            appendTime(CMSampleBufferGetDecodeTimeStamp(sample))
            appendTime(CMSampleBufferGetDuration(sample))
            appendInteger(mediaType)
            appendInteger(mediaSubtype)
            return
        }

        let dataBuffer = CMSampleBufferGetDataBuffer(sample)
        var dataOffset = 0
        for index in 0..<sampleCount {
            var timing = CMSampleTimingInfo()
            let timingStatus = CMSampleBufferGetSampleTimingInfo(
                sample,
                at: index,
                timingInfoOut: &timing
            )
            guard timingStatus == noErr else {
                throw Error(status: timingStatus)
            }
            let sampleSize = CMSampleBufferGetSampleSize(sample, at: index)
            let payload: Data
            if sampleSize == 0 {
                payload = Data()
            } else {
                guard let dataBuffer else {
                    throw Error(status: kCMSampleBufferError_BufferHasNoSampleSizes)
                }
                var bytes = Data(count: sampleSize)
                let copyStatus = bytes.withUnsafeMutableBytes { destination in
                    CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: dataOffset,
                        dataLength: sampleSize,
                        destination: destination.baseAddress!
                    )
                }
                guard copyStatus == kCMBlockBufferNoErr else {
                    throw Error(status: copyStatus)
                }
                payload = bytes
            }
            canonicalBytes.append(1)
            appendTime(timing.presentationTimeStamp)
            appendTime(timing.decodeTimeStamp)
            appendTime(timing.duration)
            appendInteger(mediaType)
            appendInteger(mediaSubtype)
            appendInteger(UInt64(sampleSize))
            canonicalBytes.append(contentsOf: ASHSHA256V4(
                rawData: payload
            ).rawValue.utf8)
            dataOffset += sampleSize
        }
    }

    private mutating func appendTime(_ time: CMTime) {
        appendInteger(time.value)
        appendInteger(time.timescale)
        appendInteger(time.flags.rawValue)
        appendInteger(time.epoch)
    }

    private mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            canonicalBytes.append(contentsOf: $0)
        }
    }
}

private final class AtomicMigrationDestinationV4: @unchecked Sendable {
    let finalURL: URL
    let temporaryURL: URL

    private let fileManager: FileManager
    private let overwriteExistingFile: Bool
    private let lock = NSLock()
    private var published = false

    init(
        finalURL: URL,
        overwriteExistingFile: Bool,
        fileManager: FileManager = .default
    ) throws {
        guard finalURL.isFileURL else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .destinationDirectoryMissing
        }
        let directory = finalURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .destinationDirectoryMissing
        }
        if fileManager.fileExists(atPath: finalURL.path),
           !overwriteExistingFile {
            throw AVFoundationTrackMigrationExecutorV4Error
                .destinationExists
        }
        self.finalURL = finalURL
        self.overwriteExistingFile = overwriteExistingFile
        self.fileManager = fileManager
        temporaryURL = directory.appendingPathComponent(
            ".mirmir-track-v4-\(UUID().uuidString).partial.mov"
        )
    }

    func publish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !published else { return }
        if fileManager.fileExists(atPath: finalURL.path) {
            guard overwriteExistingFile else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .destinationExists
            }
            _ = try fileManager.replaceItemAt(
                finalURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        }
        published = true
    }

    func discard() {
        lock.lock()
        defer { lock.unlock() }
        guard !published,
              fileManager.fileExists(atPath: temporaryURL.path) else {
            return
        }
        try? fileManager.removeItem(at: temporaryURL)
    }

    deinit {
        discard()
    }
}
