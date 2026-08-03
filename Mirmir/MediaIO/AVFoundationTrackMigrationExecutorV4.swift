import AVFoundation
import CoreGraphics
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
    case assetMetadataReadFailed(AVFoundationTrackMigrationFailureV4)
    case assetMetadataMismatch(expected: ASHSHA256V4, actual: ASHSHA256V4)
    case chapterMetadataMismatch(expected: ASHSHA256V4, actual: ASHSHA256V4)
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
    case processedSampleCountMismatch(
        MediaTrackStableIDV4,
        expected: Int,
        actual: Int
    )
    case processedSampleChangedTiming(MediaTrackStableIDV4)
    case processedSampleTimingContractViolation(
        MediaTrackStableIDV4,
        outputOrdinal: Int,
        field: String
    )
    case processedSampleTimestampsNotStrictlyIncreasing(
        MediaTrackStableIDV4
    )
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

/// Declares the only timing transformations a deterministic video hook may
/// perform. The executor verifies the declaration against every emitted
/// sample before appending it, so frame-rate changes cannot be smuggled in as
/// an implementation detail of a processor closure.
enum AVFoundationVideoOutputTimingContractV4: Equatable, Hashable, Sendable {
    case preserveSourceSample
    case uniformlySubdivideSourceInterval(
        outputCount: Int,
        invalidSourceDurationFallback: ExactRationalV4?
    )

    var outputCount: Int {
        switch self {
        case .preserveSourceSample:
            1
        case .uniformlySubdivideSourceInterval(let outputCount, _):
            outputCount
        }
    }
}

struct AVFoundationVideoTrackProcessingHookV4: @unchecked Sendable {
    typealias Processor = @Sendable (
        AVFoundationVideoSampleV4
    ) async throws -> AVFoundationVideoSampleV4
    typealias TemporalProcessor = @Sendable (
        AVFoundationVideoSampleV4
    ) async throws -> [AVFoundationVideoSampleV4]
    typealias Finalizer = @Sendable () async throws -> Void

    let trackID: MediaTrackStableIDV4
    let readerOutputSettings: [String: Any]
    let writerOutputSettings: [String: Any]
    let declaredOutputFormats: [MediaTrackFormatDescriptorV4]
    let outputPreferredTransform: CGAffineTransform?
    let outputNaturalSize: CGSize?
    let outputTimingContract: AVFoundationVideoOutputTimingContractV4
    let processTemporal: TemporalProcessor
    let finish: Finalizer

    init(
        trackID: MediaTrackStableIDV4,
        readerOutputSettings: [String: Any],
        writerOutputSettings: [String: Any],
        declaredOutputFormats: [MediaTrackFormatDescriptorV4],
        outputPreferredTransform: CGAffineTransform? = nil,
        outputNaturalSize: CGSize? = nil,
        process: @escaping Processor,
        finish: @escaping Finalizer = {}
    ) {
        self.trackID = trackID
        self.readerOutputSettings = readerOutputSettings
        self.writerOutputSettings = writerOutputSettings
        self.declaredOutputFormats = declaredOutputFormats
        self.outputPreferredTransform = outputPreferredTransform
        self.outputNaturalSize = outputNaturalSize
        self.outputTimingContract = .preserveSourceSample
        self.processTemporal = { sample in
            [try await process(sample)]
        }
        self.finish = finish
    }

    init(
        trackID: MediaTrackStableIDV4,
        readerOutputSettings: [String: Any],
        writerOutputSettings: [String: Any],
        declaredOutputFormats: [MediaTrackFormatDescriptorV4],
        outputPreferredTransform: CGAffineTransform? = nil,
        outputNaturalSize: CGSize? = nil,
        outputTimingContract: AVFoundationVideoOutputTimingContractV4,
        processTemporal: @escaping TemporalProcessor,
        finish: @escaping Finalizer = {}
    ) {
        self.trackID = trackID
        self.readerOutputSettings = readerOutputSettings
        self.writerOutputSettings = writerOutputSettings
        self.declaredOutputFormats = declaredOutputFormats
        self.outputPreferredTransform = outputPreferredTransform
        self.outputNaturalSize = outputNaturalSize
        self.outputTimingContract = outputTimingContract
        self.processTemporal = processTemporal
        self.finish = finish
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
    let sourceAssetMetadataSHA256: ASHSHA256V4
    let outputAssetMetadataSHA256: ASHSHA256V4
    let sourceChapterMetadataSHA256: ASHSHA256V4
    let outputChapterMetadataSHA256: ASHSHA256V4
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
            let sourceAuxiliaryMetadata: AssetAuxiliaryMetadataIdentityV4
            do {
                sourceAuxiliaryMetadata = try await auxiliaryMetadataIdentity(
                    for: sourceAsset
                )
            } catch {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .assetMetadataReadFailed(.init(error))
            }
            writer.metadata = sourceAuxiliaryMetadata.assetMetadata

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
            let outputAuxiliaryMetadata: AssetAuxiliaryMetadataIdentityV4
            do {
                outputAuxiliaryMetadata = try await auxiliaryMetadataIdentity(
                    for: outputAsset
                )
            } catch {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .assetMetadataReadFailed(.init(error))
            }
            guard outputAuxiliaryMetadata.assetMetadataSHA256
                    == sourceAuxiliaryMetadata.assetMetadataSHA256 else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .assetMetadataMismatch(
                        expected: sourceAuxiliaryMetadata.assetMetadataSHA256,
                        actual: outputAuxiliaryMetadata.assetMetadataSHA256
                    )
            }
            guard outputAuxiliaryMetadata.chapterMetadataSHA256
                    == sourceAuxiliaryMetadata.chapterMetadataSHA256 else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .chapterMetadataMismatch(
                        expected: sourceAuxiliaryMetadata.chapterMetadataSHA256,
                        actual: outputAuxiliaryMetadata.chapterMetadataSHA256
                    )
            }
            let observedOutputGraph = try await AVFoundationTrackGraphAdapterV4
                .probe(asset: outputAsset)
            let outputGraph = try reconcileOutputGraph(
                observedOutputGraph,
                plan: request.identifiedPlan.plan
            )
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
                sourceAssetMetadataSHA256:
                    sourceAuxiliaryMetadata.assetMetadataSHA256,
                outputAssetMetadataSHA256:
                    outputAuxiliaryMetadata.assetMetadataSHA256,
                sourceChapterMetadataSHA256:
                    sourceAuxiliaryMetadata.chapterMetadataSHA256,
                outputChapterMetadataSHA256:
                    outputAuxiliaryMetadata.chapterMetadataSHA256,
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
    struct AssetAuxiliaryMetadataIdentityV4 {
        let assetMetadata: [AVMetadataItem]
        let assetMetadataSHA256: ASHSHA256V4
        let chapterMetadataSHA256: ASHSHA256V4
    }

    struct AssetMetadataPayloadV4: Codable {
        let canonicalItems: [Data]
    }

    struct ChapterMetadataPayloadV4: Codable {
        let groups: [ChapterMetadataGroupPayloadV4]
    }

    struct ChapterMetadataGroupPayloadV4: Codable {
        let localeID: String
        let ordinal: UInt32
        let start: ExactRationalV4
        let duration: ExactRationalV4
        let canonicalItems: [Data]
    }

    struct MetadataItemPayloadV4: Codable {
        let identifier: String?
        let keySpace: String?
        let commonKey: String?
        let key: MetadataValueV4?
        let extendedLanguageTag: String?
        let localeID: String?
        let startDateBitPattern: UInt64?
        let dataType: String?
        let time: RawMetadataTimeV4
        let duration: RawMetadataTimeV4
        let value: MetadataValueV4?
        let extraAttributes: MetadataValueV4?
    }

    struct RawMetadataTimeV4: Codable {
        let value: Int64
        let timescale: Int32
        let flags: UInt32
        let epoch: Int64

        init(_ time: CMTime) {
            value = time.value
            timescale = time.timescale
            flags = time.flags.rawValue
            epoch = time.epoch
        }
    }

    struct MetadataObjectEntryV4: Codable {
        let key: MetadataValueV4
        let value: MetadataValueV4
    }

    indirect enum MetadataValueV4: Codable {
        case null
        case string(String)
        case data(Data)
        case date(UInt64)
        case boolean(Bool)
        case number(typeID: String, value: String)
        case array([MetadataValueV4])
        case object([MetadataObjectEntryV4])
        case url(String)
    }

    struct TrackPipe {
        let trackID: MediaTrackStableIDV4
        let action: MediaTrackActionV4
        let readerOutput: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput
        let hook: AVFoundationVideoTrackProcessingHookV4?
        var isFinished = false
        var sampleCount: Int64 = 0
        var lastOutputPresentationTime: CMTime?
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
                guard migration.action == .passThrough,
                      migration.readerStrategy == .encodedTrackOutput,
                      migration.writerStrategy == .sourceFormatHintInput else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedTrack(
                            migration.trackID,
                            reason: "composition_strategy_not_representable"
                        )
                }
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
            AVMediaCharacteristic.isMainProgramContent.rawValue,
            AVMediaCharacteristic.isAuxiliaryContent.rawValue,
            AVMediaCharacteristic.containsAlphaChannel.rawValue,
            AVMediaCharacteristic
                .transcribesSpokenDialogForAccessibility.rawValue,
            AVMediaCharacteristic
                .describesMusicAndSoundForAccessibility.rawValue
        ])
        for planned in request.identifiedPlan.plan.tracks {
            guard let expected = planned.expectedOutput else { continue }
            if expected.formatDescriptors.contains(where: {
                $0.completeness != .complete
            }) {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "partial_or_unknown_format_descriptor"
                    )
            }
            let trackEnd = try expected.timeRange.start.adding(
                expected.timeRange.duration
            )
            var previousEditEnd: ExactRationalV4?
            for edit in expected.edits {
                let editEnd = try edit.target.start.adding(
                    edit.target.duration
                )
                guard edit.target.start >= expected.timeRange.start,
                      editEnd <= trackEnd else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedTrack(
                            expected.identity.stableID,
                            reason: "edit_target_outside_track_time_range"
                        )
                }
                if let previousEditEnd,
                   previousEditEnd > edit.target.start {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedTrack(
                            expected.identity.stableID,
                            reason: "overlapping_edit_targets"
                        )
                }
                previousEditEnd = editEnd
                if let source = edit.source,
                   source.duration != edit.target.duration {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedTrack(
                            expected.identity.stableID,
                            reason: "scaled_edit_requires_processing"
                        )
                }
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
        let expectedTrackByID = Dictionary(
            uniqueKeysWithValues: request.identifiedPlan.plan.tracks
                .compactMap { planned in
                    planned.expectedOutput.map {
                        ($0.identity.stableID, $0)
                    }
                }
        )
        var groupedTrackIDs = Set<MediaTrackStableIDV4>()
        for planned in request.identifiedPlan.plan.groups {
            guard let expected = planned.expectedOutput else { continue }
            guard expected.kind == .alternate else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        expected.identity.stableID,
                        reason: "group_kind_not_writable"
                    )
            }
            guard expected.allowsEmptySelection
                == (expected.defaultTrackID == nil) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        expected.identity.stableID,
                        reason: "selection_policy_not_representable"
                    )
            }
            let enabledMembers = expected.memberTrackIDs.filter {
                expectedTrackByID[$0]?.enabled == true
            }
            guard enabledMembers
                == expected.defaultTrackID.map({ [$0] }) ?? [] else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedGroup(
                        expected.identity.stableID,
                        reason: "enabled_state_not_representable_by_default"
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
                  hook.outputTimingContract.outputCount > 0,
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

    func auxiliaryMetadataIdentity(
        for asset: AVAsset
    ) async throws -> AssetAuxiliaryMetadataIdentityV4 {
        let assetMetadata = try await asset.load(.metadata)
        let assetItems = try await canonicalMetadataItems(assetMetadata)
        let assetMetadataSHA256 = try ASHCanonicalJSONV4.hash(
            AssetMetadataPayloadV4(
                canonicalItems: assetItems
            ),
            domain: "ash-avfoundation-asset-metadata-v4"
        )

        let locales = try await asset.load(.availableChapterLocales)
            .sorted { $0.identifier < $1.identifier }
        var chapterGroups: [ChapterMetadataGroupPayloadV4] = []
        for locale in locales {
            let groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale
            )
            for (ordinal, group) in groups.enumerated() {
                guard ordinal <= Int(UInt32.max),
                      group.timeRange.start.isNumeric,
                      group.timeRange.start.timescale > 0,
                      group.timeRange.duration.isNumeric,
                      group.timeRange.duration.timescale > 0 else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .assetMetadataReadFailed(.init(nil))
                }
                let canonicalItems = try await canonicalMetadataItems(
                    group.items
                )
                chapterGroups.append(ChapterMetadataGroupPayloadV4(
                    localeID: locale.identifier,
                    ordinal: UInt32(ordinal),
                    start: try ExactRationalV4(
                        group.timeRange.start.value,
                        Int64(group.timeRange.start.timescale)
                    ),
                    duration: try ExactRationalV4(
                        group.timeRange.duration.value,
                        Int64(group.timeRange.duration.timescale)
                    ),
                    canonicalItems: canonicalItems
                ))
            }
        }
        let chapterMetadataSHA256 = try ASHCanonicalJSONV4.hash(
            ChapterMetadataPayloadV4(groups: chapterGroups),
            domain: "ash-avfoundation-chapter-metadata-v4"
        )
        return AssetAuxiliaryMetadataIdentityV4(
            assetMetadata: assetMetadata,
            assetMetadataSHA256: assetMetadataSHA256,
            chapterMetadataSHA256: chapterMetadataSHA256
        )
    }

    func canonicalMetadataItems(
        _ items: [AVMetadataItem]
    ) async throws -> [Data] {
        var canonicalItems: [Data] = []
        canonicalItems.reserveCapacity(items.count)
        for item in items {
            let loadedValue = try await item.load(.value)
            let loadedExtraAttributes = try await item.load(.extraAttributes)
            let payload = MetadataItemPayloadV4(
                identifier: item.identifier?.rawValue,
                keySpace: item.keySpace?.rawValue,
                commonKey: item.commonKey?.rawValue,
                key: try item.key.map(metadataValue),
                extendedLanguageTag: item.extendedLanguageTag,
                localeID: item.locale?.identifier,
                startDateBitPattern: item.startDate.map {
                    $0.timeIntervalSinceReferenceDate.bitPattern
                },
                dataType: item.dataType,
                time: RawMetadataTimeV4(item.time),
                duration: RawMetadataTimeV4(item.duration),
                value: try loadedValue.map(metadataValue),
                extraAttributes: try loadedExtraAttributes.map(metadataValue)
            )
            canonicalItems.append(try ASHCanonicalJSONV4.encode(payload))
        }
        return canonicalItems.sorted { lhs, rhs in
            lhs.lexicographicallyPrecedes(rhs)
        }
    }

    func metadataValue(_ value: Any) throws -> MetadataValueV4 {
        if value is NSNull { return .null }
        if let string = value as? String { return .string(string) }
        if let data = value as? Data { return .data(data) }
        if let date = value as? Date {
            return .date(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            return .number(
                typeID: String(cString: number.objCType),
                value: number.stringValue
            )
        }
        if let array = value as? NSArray {
            return .array(try array.map(metadataValue))
        }
        if let dictionary = value as? NSDictionary {
            var entries = try dictionary.map { key, value in
                MetadataObjectEntryV4(
                    key: try metadataValue(key),
                    value: try metadataValue(value)
                )
            }
            entries.sort { lhs, rhs in
                let lhsData = try? ASHCanonicalJSONV4.encode(lhs)
                let rhsData = try? ASHCanonicalJSONV4.encode(rhs)
                return (lhsData ?? Data()).lexicographicallyPrecedes(
                    rhsData ?? Data()
                )
            }
            return .object(entries)
        }
        if let url = value as? URL { return .url(url.absoluteString) }
        throw AVFoundationTrackMigrationExecutorV4Error
            .assetMetadataReadFailed(.init(nil))
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
            guard writer.availableMediaTypes.contains(sourceTrack.mediaType)
            else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        id,
                        reason: "output_file_type_rejects_source_media_type"
                    )
            }
            let readerOutput: AVAssetReaderTrackOutput
            let writerInput: AVAssetWriterInput
            let hook = hooks[id]
            switch planned.action {
            case .passThrough:
                guard [
                    AVFoundationTrackMigrationOutcomeV4.directReaderWriter,
                    .requiresComposition
                ].contains(migration.outcome),
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
                if sourceTrack.mediaType == .auxiliaryPicture {
                    // Core Media deliberately reports a video format
                    // description for an auxiliary-picture track. Passing
                    // that description as an `auxv` source hint raises an
                    // Objective-C exception because the media types differ.
                    // AVAssetWriter's documented auxiliary-picture path
                    // accepts the encoded buffers without a source hint and
                    // derives the video sample description from the stream.
                    writerInput = AVAssetWriterInput(
                        mediaType: sourceTrack.mediaType,
                        outputSettings: nil
                    )
                } else {
                    writerInput = AVAssetWriterInput(
                        mediaType: sourceTrack.mediaType,
                        outputSettings: nil,
                        sourceFormatHint: formatDescriptions[0]
                    )
                }
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
                to: writerInput,
                processingHook: hook
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
        to input: AVAssetWriterInput,
        processingHook: AVFoundationVideoTrackProcessingHookV4?
    ) async throws {
        guard let expected else { return }
        input.metadata = try await track.load(.metadata)
        input.languageCode = try await track.load(.languageCode)
        input.extendedLanguageTag = try await track.load(.extendedLanguageTag)
        if track.mediaType == .video
            || track.mediaType == .auxiliaryPicture
            || track.mediaType == .muxed {
            if let naturalSize = processingHook?.outputNaturalSize {
                input.naturalSize = naturalSize
            } else {
                input.naturalSize = try await track.load(.naturalSize)
            }
            if let preferredTransform = processingHook?
                .outputPreferredTransform {
                input.transform = preferredTransform
            } else {
                input.transform = try await track.load(.preferredTransform)
            }
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
                    if let hook = pipes[index].hook {
                        do {
                            try await hook.finish()
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
                    }
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

                let outputSamples: [CMSampleBuffer]
                if let hook = pipes[index].hook {
                    do {
                        outputSamples = try await hook.processTemporal(
                            AVFoundationVideoSampleV4(
                                sampleBuffer: sourceSample
                            )
                        ).map(\.sampleBuffer)
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
                    try validateProcessedSamples(
                        source: sourceSample,
                        outputs: outputSamples,
                        contract: hook.outputTimingContract,
                        trackID: pipes[index].trackID,
                        previousPresentationTime:
                            pipes[index].lastOutputPresentationTime
                    )
                } else {
                    outputSamples = [sourceSample]
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
                for outputSample in outputSamples {
                    try await waitUntilReady(
                        pipes[index].writerInput,
                        reader: reader,
                        writer: writer,
                        cancellation: cancellation
                    )
                    guard pipes[index].writerInput.append(outputSample) else {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .appendFailed(
                                trackID: pipes[index].trackID,
                                failure: .init(writer.error)
                            )
                    }
                    pipes[index].sampleCount += 1
                    pipes[index].lastOutputPresentationTime
                        = CMSampleBufferGetPresentationTimeStamp(outputSample)
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
                    advanced = true
                }
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
        guard outputTracks.count == outputGraph.tracks.count,
              outputTracks.count == pipes.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let trackByID = Dictionary(
            uniqueKeysWithValues: zip(pipes, outputTracks).map {
                ($0.trackID, $1)
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

    /// AVAssetWriter does not provide a way to assign persistent output track
    /// IDs. When an authorized drop removes an input, later container IDs and
    /// ordinals can therefore shift even though every surviving track remains
    /// in writer-input order. Rebind only those uncontrollable identities to
    /// the plan's logical identities; all observed media semantics, group
    /// policy, associations, and encoded sample streams remain independently
    /// verified after the rebind.
    func reconcileOutputGraph(
        _ observed: MediaTrackGraphV4,
        plan: MediaTrackGraphPlanV4
    ) throws -> MediaTrackGraphV4 {
        let expectedTracks = plan.tracks.compactMap(\.expectedOutput)
        guard observed.tracks.count == expectedTracks.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let observedToLogicalID = Dictionary(
            uniqueKeysWithValues: zip(observed.tracks, expectedTracks).map {
                ($0.identity.stableID, $1.identity.stableID)
            }
        )
        let tracks = try zip(observed.tracks, expectedTracks).map {
            actual, expected in
            try MediaTrackNodeV4(
                identity: expected.identity,
                enabled: actual.enabled,
                kind: actual.kind,
                sourceMediaTypeID: actual.sourceMediaTypeID,
                language: actual.language,
                roleIDs: actual.roleIDs,
                timebase: actual.timebase,
                timeRange: actual.timeRange,
                edits: actual.edits,
                formatDescriptors: actual.formatDescriptors,
                metadataFingerprint: actual.metadataFingerprint
            )
        }

        let expectedGroups = plan.groups.compactMap(\.expectedOutput)
        guard observed.groups.count == expectedGroups.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let groups = try zip(observed.groups, expectedGroups).map {
            actual, expected in
            let members = try actual.memberTrackIDs.map { id in
                guard let mapped = observedToLogicalID[id] else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .sourceTrackInventoryMismatch
                }
                return mapped
            }
            let defaultTrackID: MediaTrackStableIDV4?
            if let actualDefault = actual.defaultTrackID {
                guard let mapped = observedToLogicalID[actualDefault] else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .sourceTrackInventoryMismatch
                }
                defaultTrackID = mapped
            } else {
                defaultTrackID = nil
            }
            return try MediaTrackGroupV4(
                identity: expected.identity,
                kind: actual.kind,
                memberTrackIDs: members,
                defaultTrackID: defaultTrackID,
                allowsEmptySelection: actual.allowsEmptySelection
            )
        }

        let expectedAssociations = plan.associations.compactMap {
            $0.action == .passThrough ? $0.source : nil
        }
        guard observed.associations.count == expectedAssociations.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let associations = try zip(
            observed.associations,
            expectedAssociations
        ).map { actual, expected in
            guard let sourceID = observedToLogicalID[actual.sourceTrackID],
                  let targetID = observedToLogicalID[actual.targetTrackID] else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sourceTrackInventoryMismatch
            }
            return try MediaTrackAssociationV4(
                ordinal: expected.ordinal,
                sourceTrackID: sourceID,
                targetTrackID: targetID,
                kind: actual.kind,
                sourceAssociationTypeID: actual.sourceAssociationTypeID
            )
        }

        return try MediaTrackGraphV4(
            tracks: tracks,
            groups: groups,
            associations: associations,
            diagnostics: observed.diagnostics
        )
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

    func validateProcessedSamples(
        source: CMSampleBuffer,
        outputs: [CMSampleBuffer],
        contract: AVFoundationVideoOutputTimingContractV4,
        trackID: MediaTrackStableIDV4,
        previousPresentationTime: CMTime?
    ) throws {
        let expectedCount = contract.outputCount
        guard outputs.count == expectedCount else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSampleCountMismatch(
                    trackID,
                    expected: expectedCount,
                    actual: outputs.count
                )
        }
        for output in outputs {
            guard let format = CMSampleBufferGetFormatDescription(output),
                  CMFormatDescriptionGetMediaType(format)
                    == kCMMediaType_Video else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSampleIsNotVideo(trackID)
            }
        }

        switch contract {
        case .preserveSourceSample:
            guard let output = outputs.first,
                  sampleTimingEqual(source, output) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSampleChangedTiming(trackID)
            }
        case .uniformlySubdivideSourceInterval(
            let outputCount,
            let invalidSourceDurationFallback
        ):
            let sourcePTS = CMSampleBufferGetPresentationTimeStamp(source)
            let sourceDTS = CMSampleBufferGetDecodeTimeStamp(source)
            let observedDuration = CMSampleBufferGetDuration(source)
            let sourceDuration: CMTime
            if observedDuration.isNumeric, observedDuration.value > 0 {
                sourceDuration = observedDuration
            } else if let fallback = invalidSourceDurationFallback,
                      fallback.numerator > 0,
                      fallback.denominator <= Int64(Int32.max) {
                sourceDuration = CMTime(
                    value: fallback.numerator,
                    timescale: Int32(fallback.denominator)
                )
            } else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSampleTimingContractViolation(
                        trackID,
                        outputOrdinal: 0,
                        field: "source_interval"
                    )
            }
            guard sourcePTS.isNumeric,
                  outputCount <= Int(Int32.max) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSampleTimingContractViolation(
                        trackID,
                        outputOrdinal: 0,
                        field: "source_interval"
                    )
            }
            let subduration = CMTimeMultiplyByRatio(
                sourceDuration,
                multiplier: 1,
                divisor: Int32(outputCount)
            )
            guard subduration.isNumeric, subduration.value > 0 else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSampleTimingContractViolation(
                        trackID,
                        outputOrdinal: 0,
                        field: "subduration"
                    )
            }
            for (ordinal, output) in outputs.enumerated() {
                let offset = CMTimeMultiply(
                    subduration,
                    multiplier: Int32(ordinal)
                )
                let expectedPTS = CMTimeAdd(sourcePTS, offset)
                let outputPTS = CMSampleBufferGetPresentationTimeStamp(output)
                let outputDTS = CMSampleBufferGetDecodeTimeStamp(output)
                let outputDuration = CMSampleBufferGetDuration(output)
                let expectedDTS = sourceDTS.isNumeric
                    ? CMTimeAdd(sourceDTS, offset)
                    : sourceDTS
                guard CMTimeCompare(outputPTS, expectedPTS) == 0 else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .processedSampleTimingContractViolation(
                            trackID,
                            outputOrdinal: ordinal,
                            field: "presentation_time"
                        )
                }
                guard CMTimeCompare(outputDTS, expectedDTS) == 0 else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .processedSampleTimingContractViolation(
                            trackID,
                            outputOrdinal: ordinal,
                            field: "decode_time"
                        )
                }
                guard CMTimeCompare(outputDuration, subduration) == 0 else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .processedSampleTimingContractViolation(
                            trackID,
                            outputOrdinal: ordinal,
                            field: "duration"
                        )
                }
            }
        }

        var prior = previousPresentationTime
        for output in outputs {
            let presentation = CMSampleBufferGetPresentationTimeStamp(output)
            guard presentation.isNumeric,
                  prior.map({ CMTimeCompare(presentation, $0) > 0 })
                    ?? true else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSampleTimestampsNotStrictlyIncreasing(trackID)
            }
            prior = presentation
        }
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
