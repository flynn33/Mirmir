import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
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
    case invalidProcessedVideoReplacement(MediaTrackStableIDV4, reason: String)
    case invalidProcessingHook(MediaTrackStableIDV4, reason: String)
    case unsupportedTrack(MediaTrackStableIDV4, reason: String)
    case unsupportedGroup(MediaTrackGroupStableIDV4, reason: String)
    case unsupportedAssociation(UInt32, reason: String)
    case sourceTrackInventoryMismatch
    case outputTrackOrderMismatch(
        ordinal: Int,
        expectedTrackID: MediaTrackStableIDV4,
        expectedMediaType: String,
        actualMediaType: String
    )
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
    case processedSampleMediaTypeMismatch(
        MediaTrackStableIDV4,
        expected: String,
        actual: String
    )
    case processedSampleCanonicalStreamMismatch(MediaTrackStableIDV4)
    case processedSamplePresentationRangeUnrepresentable(
        MediaTrackStableIDV4,
        reason: String
    )
    case processedSampleClipFailed(
        MediaTrackStableIDV4,
        status: Int32
    )
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
    case unexpectedCancellation(AVFoundationTrackMigrationFailureV4)
    case semanticVerificationFailed(MediaTrackSemanticVerificationReportV4)
    case publishFailed(AVFoundationTrackMigrationFailureV4)
}

/// A previously encoded, independently verified primary-video stream that
/// replaces the source primary track during the final rich-asset mux. All
/// other tracks, groups, associations, chapters, and asset metadata continue
/// to come from `sourceURL` and retain encoded-sample identity.
struct AVFoundationProcessedVideoReplacementV4: Sendable {
    let trackID: MediaTrackStableIDV4
    let sourceURL: URL

    init(trackID: MediaTrackStableIDV4, sourceURL: URL) {
        self.trackID = trackID
        self.sourceURL = sourceURL
    }
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

    var cancellationWasRequested: Bool {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        return cancelled
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

struct AVFoundationNonVideoSampleV4: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
}

/// The semantic transformation a non-video hook is allowed to perform before
/// AVFoundation applies the separately declared codec conversion. M5 supports
/// only identity in the decoded domain: timing, format, and every decoded
/// payload byte must remain unchanged. A future transform must add a typed case
/// with its own verifier; it cannot inherit the identity contract implicitly.
enum AVFoundationNonVideoDecodedTransformV4: String, Codable, Equatable,
    Hashable, Sendable {
    case preserveCanonicalSampleStream = "preserve_canonical_sample_stream"
}

/// A track-bound decode/process/encode contract for audio and other
/// non-video media. AVFoundation performs the codec conversion described by
/// the reader and writer settings; the processor may perform only its typed,
/// verifier-backed decoded transform. M5's sole transform is exact identity.
struct AVFoundationNonVideoTrackTranscodeHookV4: @unchecked Sendable {
    typealias Processor = @Sendable (
        AVFoundationNonVideoSampleV4
    ) async throws -> AVFoundationNonVideoSampleV4
    typealias Finalizer = @Sendable () async throws -> Void

    let trackID: MediaTrackStableIDV4
    let readerOutputSettings: [String: Any]
    let writerOutputSettings: [String: Any]
    let declaredOutputFormats: [MediaTrackFormatDescriptorV4]
    let decodedTransform: AVFoundationNonVideoDecodedTransformV4
    let process: Processor
    let finish: Finalizer

    init(
        trackID: MediaTrackStableIDV4,
        readerOutputSettings: [String: Any],
        writerOutputSettings: [String: Any],
        declaredOutputFormats: [MediaTrackFormatDescriptorV4],
        decodedTransform: AVFoundationNonVideoDecodedTransformV4 =
            .preserveCanonicalSampleStream,
        process: @escaping Processor = { $0 },
        finish: @escaping Finalizer = {}
    ) {
        self.trackID = trackID
        self.readerOutputSettings = readerOutputSettings
        self.writerOutputSettings = writerOutputSettings
        self.declaredOutputFormats = declaredOutputFormats
        self.decodedTransform = decodedTransform
        self.process = process
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
    let nonVideoTranscodeHooks: [
        AVFoundationNonVideoTrackTranscodeHookV4
    ]
    let processedVideoReplacement: AVFoundationProcessedVideoReplacementV4?

    init(
        sourceURL: URL,
        destinationURL: URL,
        outputFileType: AVFileType = .mov,
        overwriteExistingFile: Bool = false,
        sourceGraph: MediaTrackGraphV4,
        identifiedPlan: MediaTrackGraphIdentifiedPlanV4,
        blueprint: AVFoundationTrackMigrationBlueprintV4,
        videoProcessingHooks: [AVFoundationVideoTrackProcessingHookV4] = [],
        nonVideoTranscodeHooks: [
            AVFoundationNonVideoTrackTranscodeHookV4
        ] = [],
        processedVideoReplacement: AVFoundationProcessedVideoReplacementV4?
            = nil
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.outputFileType = outputFileType
        self.overwriteExistingFile = overwriteExistingFile
        self.sourceGraph = sourceGraph
        self.identifiedPlan = identifiedPlan
        self.blueprint = blueprint
        self.videoProcessingHooks = videoProcessingHooks
        self.nonVideoTranscodeHooks = nonVideoTranscodeHooks
        self.processedVideoReplacement = processedVideoReplacement
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

    static func validatePassThroughFormatInventory(
        _ descriptions: [CMFormatDescription],
        planned: MediaTrackPlannedTrackV4,
        sourceMediaType: AVMediaType
    ) throws {
        try Self().validatePassThroughFormats(
            descriptions,
            planned: planned,
            sourceMediaType: sourceMediaType
        )
    }

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
            let replacement = try await prepareProcessedVideoReplacement(
                request.processedVideoReplacement
            )
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
                    for: sourceAsset,
                    cancellation: cancellation
                )
            } catch let error as CancellationError {
                guard cancellation.cancellationWasRequested
                        || Task.isCancelled else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .assetMetadataReadFailed(.init(error))
                }
                throw error
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
                replacement: replacement,
                writer: writer,
                cancellation: cancellation,
                progress: progress
            )
            try prepareGroupsAndAssociations(
                plan: request.identifiedPlan.plan,
                blueprint: request.blueprint,
                pipes: pipes,
                writer: writer
            )
            try cancellation.check()

            let readers = uniqueReaders(in: pipes)
            for activeReader in readers where !activeReader.startReading() {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .readerStartFailed(.init(activeReader.error))
            }
            guard writer.startWriting() else {
                readers.forEach { $0.cancelReading() }
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
                    readers: readers,
                    writer: writer,
                    cancellation: cancellation,
                    progress: progress
                )
                try await waitForReaderCompletion(
                    readers,
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
                try rebuildEditMaps(
                    at: destination.temporaryURL,
                    fileType: request.outputFileType,
                    pipes: pipes
                )
            } catch {
                readers.forEach { $0.cancelReading() }
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
                    for: outputAsset,
                    cancellation: cancellation
                )
            } catch let error as CancellationError {
                guard cancellation.cancellationWasRequested
                        || Task.isCancelled else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .assetMetadataReadFailed(.init(error))
                }
                throw error
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
            try cancellation.check()
            let streamVerification = try await verifyPassThroughStreams(
                outputAsset: outputAsset,
                outputGraph: observedOutputGraph,
                pipes: pipes,
                cancellation: cancellation
            )
            let outputGraph = try reconcileOutputGraph(
                observedOutputGraph,
                plan: request.identifiedPlan.plan,
                observedToLogicalID:
                    streamVerification.observedToLogicalTrackID
            )
            let report = try MediaTrackSemanticVerifierV4.verify(
                plan: request.identifiedPlan,
                output: outputGraph
            )
            guard report.isConformant else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .semanticVerificationFailed(report)
            }
            let outputStreamDigests = streamVerification.digests
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
                        sourceSampleStreamSHA256:
                            $0.verifiesEncodedSampleStream
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
        } catch let error as CancellationError {
            guard cancellation.cancellationWasRequested
                    || Task.isCancelled else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unexpectedCancellation(.init(error))
            }
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
        let reader: AVAssetReader
        let readerOutput: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput
        let videoHook: AVFoundationVideoTrackProcessingHookV4?
        let nonVideoHook: AVFoundationNonVideoTrackTranscodeHookV4?
        let nonVideoPresentationEnd: CMTime?
        let passThroughFormatContract: PassThroughFormatContract?
        let edits: [MediaTrackEditV4]
        let requiresEditMapRebuild: Bool
        let verifiesEncodedSampleStream: Bool
        let accumulatesSourceStreamDuringDrain: Bool
        let verifiesDynamicHDRStream: Bool
        let accumulatesDynamicHDRStreamDuringDrain: Bool
        var isFinished = false
        var sampleCount: Int64 = 0
        var lastOutputPresentationTime: CMTime?
        var sampleStream = SampleStreamAccumulatorV4()
        var dynamicHDRStream = DynamicHDRMetadataStreamAccumulatorV4()
    }

    struct ProcessingHooks {
        let video: [
            MediaTrackStableIDV4: AVFoundationVideoTrackProcessingHookV4
        ]
        let nonVideo: [
            MediaTrackStableIDV4: AVFoundationNonVideoTrackTranscodeHookV4
        ]
    }

    struct PassThroughFormatContract {
        private let canonicalFingerprints: Set<ASHSHA256V4>

        init(descriptions: [CMFormatDescription]) throws {
            canonicalFingerprints = try Set(descriptions.map {
                try AVFoundationTrackGraphAdapterV4
                    .canonicalFormatDescriptor($0).canonicalFingerprint
            })
        }

        func accepts(_ sample: CMSampleBuffer) throws -> Bool {
            // AVAssetReader emits zero-sample edit/drain markers around
            // compressed tracks. They carry timeline state but no sample
            // description and are not a format transition.
            if CMSampleBufferGetNumSamples(sample) == 0 { return true }
            guard let observed = CMSampleBufferGetFormatDescription(sample)
            else { return false }
            let fingerprint = try AVFoundationTrackGraphAdapterV4
                .canonicalFormatDescriptor(observed).canonicalFingerprint
            return canonicalFingerprints.contains(fingerprint)
        }
    }

    struct ProcessedVideoReplacementContext {
        let declaration: AVFoundationProcessedVideoReplacementV4
        let asset: AVAsset
        let track: AVAssetTrack
        let reader: AVAssetReader
    }

    struct ScaledEditMediaTableContext {
        let asset: AVMutableMovie
        let reader: AVAssetReader
        let trackByID: [MediaTrackStableIDV4: AVMutableMovieTrack]
    }

    struct PassThroughStreamIdentityV4 {
        let encoded: SampleStreamAccumulatorV4
        let dynamicHDR: DynamicHDRMetadataStreamAccumulatorV4?
    }

    func validate(
        _ request: AVFoundationTrackMigrationExecutionRequestV4
    ) throws -> ProcessingHooks {
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
            AVMediaCharacteristic.usesWideGamutColorSpace.rawValue,
            AVMediaCharacteristic.containsHDRVideo.rawValue,
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
            guard expected.timebase.numerator == 1,
                  Int32(exactly: expected.timebase.denominator) != nil else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        expected.identity.stableID,
                        reason: "media_timescale_not_representable"
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

        var videoHooks: [
            MediaTrackStableIDV4: AVFoundationVideoTrackProcessingHookV4
        ] = [:]
        for hook in request.videoProcessingHooks {
            guard videoHooks.updateValue(hook, forKey: hook.trackID) == nil else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .duplicateProcessingHook(hook.trackID)
            }
        }
        var nonVideoHooks: [
            MediaTrackStableIDV4: AVFoundationNonVideoTrackTranscodeHookV4
        ] = [:]
        for hook in request.nonVideoTranscodeHooks {
            guard videoHooks[hook.trackID] == nil,
                  nonVideoHooks.updateValue(hook, forKey: hook.trackID) == nil
            else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .duplicateProcessingHook(hook.trackID)
            }
        }
        let hookTrackIDs = Set(videoHooks.keys).union(nonVideoHooks.keys)
        let requiredHookTracks = request.identifiedPlan.plan.tracks.filter {
            $0.action == .process || $0.action == .transcode
        }
        let requiredHookIDs = Set(requiredHookTracks.map {
            $0.source.identity.stableID
        })
        let replacementIDs = Set(
            request.processedVideoReplacement.map { [$0.trackID] } ?? []
        )
        if let replacement = request.processedVideoReplacement {
            guard replacement.sourceURL.isFileURL,
                  replacement.sourceURL.standardizedFileURL
                    != request.sourceURL.standardizedFileURL,
                  replacement.sourceURL.standardizedFileURL
                    != request.destinationURL.standardizedFileURL,
                  requiredHookIDs.contains(replacement.trackID),
                  !hookTrackIDs.contains(replacement.trackID) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .invalidProcessedVideoReplacement(
                        replacement.trackID,
                        reason: "identity_or_path_conflict"
                    )
            }
        }
        let suppliedProcessorIDs = hookTrackIDs.union(replacementIDs)
        if let missing = requiredHookIDs.subtracting(suppliedProcessorIDs)
            .sorted()
            .first {
            throw AVFoundationTrackMigrationExecutorV4Error
                .missingProcessingHook(missing)
        }
        if let unexpected = suppliedProcessorIDs.subtracting(requiredHookIDs)
            .sorted()
            .first {
            throw AVFoundationTrackMigrationExecutorV4Error
                .unexpectedProcessingHook(unexpected)
        }
        for planned in requiredHookTracks {
            let id = planned.source.identity.stableID
            if replacementIDs.contains(id) {
                guard planned.source.kind == .video,
                      planned.expectedOutput?.formatDescriptors.count == 1 else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .invalidProcessedVideoReplacement(
                            id,
                            reason: "replacement_target_is_not_single_format_video"
                        )
                }
                continue
            }
            guard let expected = planned.expectedOutput else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .invalidProcessingHook(id, reason: "missing_expected_output")
            }
            if planned.source.kind == .video {
                guard let hook = videoHooks[id],
                      nonVideoHooks[id] == nil,
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
            } else {
                guard planned.action == .transcode,
                      videoHooks[id] == nil,
                      let hook = nonVideoHooks[id],
                      !hook.readerOutputSettings.isEmpty,
                      !hook.writerOutputSettings.isEmpty,
                      hook.declaredOutputFormats == expected.formatDescriptors,
                      expected.formatDescriptors.count == 1,
                      expected.formatDescriptors[0].mediaTypeID
                        == planned.source.formatDescriptors.first?.mediaTypeID
                else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .invalidProcessingHook(
                            id,
                            reason:
                                "non_video_settings_or_declared_format_invalid"
                        )
                }
            }
        }
        return ProcessingHooks(video: videoHooks, nonVideo: nonVideoHooks)
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
        for asset: AVAsset,
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws -> AssetAuxiliaryMetadataIdentityV4 {
        try cancellation.check()
        let assetMetadata = try await asset.load(.metadata)
        let assetItems = try await canonicalMetadataItems(
            assetMetadata,
            cancellation: cancellation
        )
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
            try cancellation.check()
            let groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale
            )
            for (ordinal, group) in groups.enumerated() {
                try cancellation.check()
                guard ordinal <= Int(UInt32.max),
                      group.timeRange.start.isNumeric,
                      group.timeRange.start.timescale > 0,
                      group.timeRange.duration.isNumeric,
                      group.timeRange.duration.timescale > 0 else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .assetMetadataReadFailed(.init(nil))
                }
                let canonicalItems = try await canonicalMetadataItems(
                    group.items,
                    cancellation: cancellation
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
        _ items: [AVMetadataItem],
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws -> [Data] {
        var canonicalItems: [Data] = []
        canonicalItems.reserveCapacity(items.count)
        for item in items {
            try cancellation.check()
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

    func prepareProcessedVideoReplacement(
        _ declaration: AVFoundationProcessedVideoReplacementV4?
    ) async throws -> ProcessedVideoReplacementContext? {
        guard let declaration else { return nil }
        let asset = AVURLAsset(
            url: declaration.sourceURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let formats = try await tracks.first?.load(.formatDescriptions) ?? []
        guard tracks.count == 1,
              let track = tracks.first,
              track.mediaType == .video,
              !formats.isEmpty else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .invalidProcessedVideoReplacement(
                    declaration.trackID,
                    reason: "replacement_must_contain_exactly_one_video_track"
                )
        }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.value > 0 else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .invalidProcessedVideoReplacement(
                    declaration.trackID,
                    reason: "replacement_duration_is_invalid"
                )
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AVFoundationTrackMigrationExecutorV4Error
                .readerCreationFailed(.init(error))
        }
        return ProcessedVideoReplacementContext(
            declaration: declaration,
            asset: asset,
            track: track,
            reader: reader
        )
    }

    func makeScaledEditMediaTableContext(
        sourceAsset: AVAsset,
        sourceGraph: MediaTrackGraphV4,
        scaledTrackIDs: Set<MediaTrackStableIDV4>
    ) throws -> ScaledEditMediaTableContext? {
        guard !scaledTrackIDs.isEmpty else { return nil }
        guard let urlAsset = sourceAsset as? AVURLAsset else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let movie = AVMutableMovie(
            url: urlAsset.url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let movieTracks = movie.tracks
        guard movieTracks.count == sourceGraph.tracks.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        var trackByID: [
            MediaTrackStableIDV4: AVMutableMovieTrack
        ] = [:]
        for (node, track) in zip(sourceGraph.tracks, movieTracks) {
            guard scaledTrackIDs.contains(node.identity.stableID) else {
                continue
            }
            let mediaRange = track.mediaPresentationTimeRange
            guard mediaRange.start.isNumeric,
                  mediaRange.duration.isNumeric,
                  mediaRange.duration.value > 0 else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        node.identity.stableID,
                        reason: "scaled_edit_media_range_is_invalid"
                    )
            }
            track.removeTimeRange(track.timeRange)
            guard track.insertMediaTimeRange(mediaRange, into: mediaRange) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        node.identity.stableID,
                        reason: "scaled_edit_media_table_read_failed"
                    )
            }
            trackByID[node.identity.stableID] = track
        }
        guard trackByID.count == scaledTrackIDs.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        do {
            return ScaledEditMediaTableContext(
                asset: movie,
                reader: try AVAssetReader(asset: movie),
                trackByID: trackByID
            )
        } catch {
            throw AVFoundationTrackMigrationExecutorV4Error
                .readerCreationFailed(.init(error))
        }
    }

    func passThroughStreamIdentity(
        asset: AVAsset,
        track: AVAssetTrack,
        trackID: MediaTrackStableIDV4,
        verifiesDynamicHDRStream: Bool,
        cancellation: AVFoundationTrackMigrationCancellationV4,
        totalTrackCount: Int,
        progress: ProgressHandler?
    ) async throws -> PassThroughStreamIdentityV4 {
        try cancellation.check()
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sampleStreamReadFailed(
                    trackID: trackID,
                    failure: .init(error)
                )
        }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sampleStreamReadFailed(
                    trackID: trackID,
                    failure: .init(nil)
                )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sampleStreamReadFailed(
                    trackID: trackID,
                    failure: .init(reader.error)
                )
        }
        var identity = SampleStreamAccumulatorV4()
        var dynamicHDR = DynamicHDRMetadataStreamAccumulatorV4()
        var scannedSampleCount: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            do {
                try identity.append(sample)
                if verifiesDynamicHDRStream {
                    try dynamicHDR.append(sample)
                }
            } catch let error as SampleStreamAccumulatorV4.Error {
                reader.cancelReading()
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamUnrepresentable(
                        trackID: trackID,
                        status: error.status
                    )
            }
            scannedSampleCount += 1
            emit(
                .preparingReaderWriter,
                trackID: trackID,
                migratedSampleCount: scannedSampleCount,
                totalTrackCount: totalTrackCount,
                progress: progress
            )
        }
        guard reader.status == .completed else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sampleStreamReadFailed(
                    trackID: trackID,
                    failure: .init(reader.error)
                )
        }
        return PassThroughStreamIdentityV4(
            encoded: identity,
            dynamicHDR: verifiesDynamicHDRStream ? dynamicHDR : nil
        )
    }

    func preparePipes(
        sourceAsset: AVAsset,
        sourceGraph: MediaTrackGraphV4,
        plan: MediaTrackGraphPlanV4,
        blueprint: AVFoundationTrackMigrationBlueprintV4,
        hooks: ProcessingHooks,
        reader: AVAssetReader,
        replacement: ProcessedVideoReplacementContext?,
        writer: AVAssetWriter,
        cancellation: AVFoundationTrackMigrationCancellationV4,
        progress: ProgressHandler?
    ) async throws -> [TrackPipe] {
        try cancellation.check()
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
        let scaledTrackIDs: Set<MediaTrackStableIDV4> = Set(
            plan.tracks.compactMap { planned -> MediaTrackStableIDV4? in
                guard planned.expectedOutput?.edits.contains(where: { edit in
                    guard let source = edit.source else { return false }
                    return source.duration != edit.target.duration
                }) == true else { return nil }
                return planned.source.identity.stableID
            }
        )
        let mediaTableContext = try makeScaledEditMediaTableContext(
            sourceAsset: sourceAsset,
            sourceGraph: sourceGraph,
            scaledTrackIDs: scaledTrackIDs
        )
        var pipes: [TrackPipe] = []
        for planned in plan.tracks {
            try cancellation.check()
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
            let videoHook = hooks.video[id]
            let nonVideoHook = hooks.nonVideo[id]
            let replacementForTrack = replacement.flatMap {
                $0.declaration.trackID == id ? $0 : nil
            }
            let pipeReader: AVAssetReader
            let verifiesEncodedSampleStream: Bool
            let verifiesDynamicHDRStream: Bool
            let passThroughFormatContract: PassThroughFormatContract?
            let readsMediaTable = scaledTrackIDs.contains(id)
            let readTrack = mediaTableContext?.trackByID[id] ?? sourceTrack
            let sourceStreamIdentity: PassThroughStreamIdentityV4?
            switch planned.action {
            case .passThrough:
                guard [
                    AVFoundationTrackMigrationOutcomeV4.directReaderWriter,
                    .requiresComposition
                ].contains(migration.outcome),
                      migration.readerStrategy == .encodedTrackOutput,
                      migration.writerStrategy == .sourceFormatHintInput else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedTrack(
                            id,
                            reason: "encoded_pass_through_strategy_required"
                        )
                }
                try validatePassThroughFormats(
                    formatDescriptions,
                    planned: planned,
                    sourceMediaType: sourceTrack.mediaType
                )
                readerOutput = AVAssetReaderTrackOutput(
                    track: readTrack,
                    outputSettings: nil
                )
                readerOutput.alwaysCopiesSampleData = false
                pipeReader = readsMediaTable
                    ? mediaTableContext!.reader
                    : reader
                verifiesEncodedSampleStream = true
                verifiesDynamicHDRStream = sourceTrack.mediaType == .video
                sourceStreamIdentity = readsMediaTable
                    ? try await passThroughStreamIdentity(
                        asset: sourceAsset,
                        track: sourceTrack,
                        trackID: id,
                        verifiesDynamicHDRStream:
                            verifiesDynamicHDRStream,
                        cancellation: cancellation,
                        totalTrackCount: sourceGraph.tracks.count,
                        progress: progress
                    )
                    : nil
                passThroughFormatContract = try PassThroughFormatContract(
                    descriptions: formatDescriptions
                )
                if sourceTrack.mediaType == .auxiliaryPicture
                    || formatDescriptions.count > 1 {
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
                guard migration.outcome == .requiresProcessor else {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .missingProcessingHook(id)
                }
                if let replacementForTrack {
                    let replacementFormats = try await replacementForTrack
                        .track.load(.formatDescriptions)
                    guard replacementFormats.count == 1 else {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .invalidProcessedVideoReplacement(
                                id,
                                reason: "single_encoded_format_required"
                            )
                    }
                    readerOutput = AVAssetReaderTrackOutput(
                        track: replacementForTrack.track,
                        outputSettings: nil
                    )
                    readerOutput.alwaysCopiesSampleData = false
                    writerInput = AVAssetWriterInput(
                        mediaType: .video,
                        outputSettings: nil,
                        sourceFormatHint: replacementFormats[0]
                    )
                    pipeReader = replacementForTrack.reader
                    verifiesEncodedSampleStream = true
                    sourceStreamIdentity = nil
                    verifiesDynamicHDRStream = true
                    passThroughFormatContract = nil
                } else {
                    var dedicatedReader: AVAssetReader?
                    if let videoHook {
                        guard writer.canApply(
                            outputSettings: videoHook.writerOutputSettings,
                            forMediaType: .video
                        ) else {
                            throw AVFoundationTrackMigrationExecutorV4Error
                                .invalidProcessingHook(
                                    id,
                                    reason: "writer_rejected_output_settings"
                                )
                        }
                        readerOutput = AVAssetReaderTrackOutput(
                            track: readTrack,
                            outputSettings: videoHook.readerOutputSettings
                        )
                        readerOutput.alwaysCopiesSampleData = true
                        writerInput = AVAssetWriterInput(
                            mediaType: .video,
                            outputSettings: videoHook.writerOutputSettings
                        )
                        verifiesDynamicHDRStream = true
                    } else if let nonVideoHook {
                        guard writer.canApply(
                            outputSettings: nonVideoHook.writerOutputSettings,
                            forMediaType: sourceTrack.mediaType
                        ) else {
                            throw AVFoundationTrackMigrationExecutorV4Error
                                .invalidProcessingHook(
                                    id,
                                    reason: "writer_rejected_output_settings"
                                )
                        }
                        readerOutput = AVAssetReaderTrackOutput(
                            track: readTrack,
                            outputSettings:
                                nonVideoHook.readerOutputSettings
                        )
                        readerOutput.alwaysCopiesSampleData = true
                        writerInput = AVAssetWriterInput(
                            mediaType: sourceTrack.mediaType,
                            outputSettings:
                                nonVideoHook.writerOutputSettings
                        )
                        do {
                            let transcodeReader = try AVAssetReader(
                                asset: readsMediaTable
                                    ? mediaTableContext!.asset
                                    : sourceAsset
                            )
                            transcodeReader.timeRange = try cmTimeRange(
                                planned.source.timeRange,
                                trackID: id
                            )
                            dedicatedReader = transcodeReader
                        } catch let error as
                            AVFoundationTrackMigrationExecutorV4Error {
                            throw error
                        } catch {
                            throw AVFoundationTrackMigrationExecutorV4Error
                                .readerCreationFailed(.init(error))
                        }
                        verifiesDynamicHDRStream = false
                    } else {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .missingProcessingHook(id)
                    }
                    pipeReader = dedicatedReader ?? (readsMediaTable
                        ? mediaTableContext!.reader
                        : reader)
                    verifiesEncodedSampleStream = false
                    sourceStreamIdentity = nil
                    passThroughFormatContract = nil
                }
            case .dropWithConsent:
                preconditionFailure("Dropped tracks do not create a pipe.")
            }
            writerInput.expectsMediaDataInRealTime = false
            let nonVideoPresentationEnd: CMTime?
            if nonVideoHook != nil,
               sourceTrack.mediaType == .audio,
               let expected = planned.expectedOutput {
                nonVideoPresentationEnd = CMTimeRangeGetEnd(
                    try cmTimeRange(expected.timeRange, trackID: id)
                )
            } else {
                nonVideoPresentationEnd = nil
            }
            try await copyTrackProperties(
                from: sourceTrack,
                replacementTrack: replacementForTrack?.track,
                expected: planned.expectedOutput,
                to: writerInput,
                processingHook: videoHook
            )
            guard pipeReader.canAdd(readerOutput) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .readerRejectedTrack(id)
            }
            guard writer.canAdd(writerInput) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .writerRejectedTrack(id)
            }
            pipeReader.add(readerOutput)
            writer.add(writerInput)
            let expectedEdits = planned.expectedOutput?.edits ?? []
            let containsScaledEdit = expectedEdits.contains { edit in
                guard let source = edit.source else { return false }
                return source.duration != edit.target.duration
            }
            // AVAssetReader/Writer presents decoded gaps as a continuous
            // stream. Reapply the calibrated output map after encoding so
            // empty and discontiguous edits remain explicit in the movie.
            let requiresTranscodeEditRebuild = planned.action == .transcode
                && expectedEdits != planned.source.edits
            var pipe = TrackPipe(
                trackID: id,
                action: planned.action,
                reader: pipeReader,
                readerOutput: readerOutput,
                writerInput: writerInput,
                videoHook: videoHook,
                nonVideoHook: nonVideoHook,
                nonVideoPresentationEnd: nonVideoPresentationEnd,
                passThroughFormatContract: passThroughFormatContract,
                edits: expectedEdits,
                requiresEditMapRebuild: containsScaledEdit
                    || requiresTranscodeEditRebuild,
                verifiesEncodedSampleStream: verifiesEncodedSampleStream,
                accumulatesSourceStreamDuringDrain:
                    verifiesEncodedSampleStream && sourceStreamIdentity == nil,
                verifiesDynamicHDRStream: verifiesDynamicHDRStream,
                accumulatesDynamicHDRStreamDuringDrain:
                    verifiesDynamicHDRStream && sourceStreamIdentity == nil
            )
            if let sourceStreamIdentity {
                pipe.sampleStream = sourceStreamIdentity.encoded
                if let dynamicHDR = sourceStreamIdentity.dynamicHDR {
                    pipe.dynamicHDRStream = dynamicHDR
                }
            }
            pipes.append(pipe)
        }
        return pipes
    }

    func copyTrackProperties(
        from track: AVAssetTrack,
        replacementTrack: AVAssetTrack? = nil,
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
            } else if let replacementTrack {
                input.naturalSize = try await replacementTrack
                    .load(.naturalSize)
            } else {
                input.naturalSize = try await track.load(.naturalSize)
            }
            if let preferredTransform = processingHook?
                .outputPreferredTransform {
                input.transform = preferredTransform
            } else if let replacementTrack {
                input.transform = try await replacementTrack
                    .load(.preferredTransform)
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

    func rebuildEditMaps(
        at url: URL,
        fileType: AVFileType,
        pipes: [TrackPipe]
    ) throws {
        guard pipes.contains(where: \.requiresEditMapRebuild) else {
            return
        }
        let movie = AVMutableMovie(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard movie.tracks.count == pipes.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        for (track, pipe) in zip(movie.tracks, pipes)
        where pipe.requiresEditMapRebuild {
            let mediaRange = track.mediaPresentationTimeRange
            track.removeTimeRange(track.timeRange)
            guard track.mediaPresentationTimeRange == mediaRange else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        pipe.trackID,
                        reason: "edit_rebuild_changed_media_table"
                    )
            }
            for edit in pipe.edits {
                let target = try cmTimeRange(
                    edit.target,
                    trackID: pipe.trackID
                )
                if edit.isEmpty {
                    track.insertEmptyTimeRange(target)
                } else if let source = edit.source {
                    guard track.insertMediaTimeRange(
                        try cmTimeRange(source, trackID: pipe.trackID),
                        into: target
                    ) else {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .unsupportedTrack(
                                pipe.trackID,
                                reason: "edit_map_rebuild_failed"
                            )
                    }
                }
            }
        }
        do {
            try movie.writeHeader(
                to: url,
                fileType: fileType,
                options: .addMovieHeaderToDestination
            )
        } catch {
            throw AVFoundationTrackMigrationExecutorV4Error.publishFailed(
                .init(error)
            )
        }
    }

    func cmTimeRange(
        _ range: MediaExactTimeRangeV4,
        trackID: MediaTrackStableIDV4
    ) throws -> CMTimeRange {
        CMTimeRange(
            start: try cmTime(range.start, trackID: trackID),
            duration: try cmTime(range.duration, trackID: trackID)
        )
    }

    func validatePassThroughFormats(
        _ descriptions: [CMFormatDescription],
        planned: MediaTrackPlannedTrackV4,
        sourceMediaType: AVMediaType
    ) throws {
        let id = planned.source.identity.stableID
        let declared = planned.source.formatDescriptors
        guard !descriptions.isEmpty,
              descriptions.count == declared.count else {
            throw AVFoundationTrackMigrationExecutorV4Error.unsupportedTrack(
                id,
                reason: "source_format_inventory_mismatch"
            )
        }
        for (ordinal, pair) in zip(descriptions, declared).enumerated() {
            let (description, descriptor) = pair
            let observed = try AVFoundationTrackGraphAdapterV4
                .canonicalFormatDescriptor(
                    description,
                    ordinal: UInt32(ordinal)
                )
            guard observed == descriptor else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        id,
                        reason: "source_format_inventory_mismatch"
                    )
            }
        }

        let reference = descriptions[0]
        let referenceType = CMFormatDescriptionGetMediaType(reference)
        let referenceSubtype = CMFormatDescriptionGetMediaSubType(reference)
        let sourceTypeMatches = sourceMediaType == .auxiliaryPicture
            ? referenceType == kCMMediaType_Video
            : sourceMediaType.rawValue == fourCCString(referenceType)
        guard sourceTypeMatches else {
            throw AVFoundationTrackMigrationExecutorV4Error.unsupportedTrack(
                id,
                reason: "source_media_type_and_format_contradict"
            )
        }

        for description in descriptions.dropFirst() {
            guard CMFormatDescriptionGetMediaType(description) == referenceType,
                  CMFormatDescriptionGetMediaSubType(description)
                    == referenceSubtype,
                  formatGeometryIsCompatible(reference, description) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .unsupportedTrack(
                        id,
                        reason:
                            "incompatible_format_transition_requires_transcode_hook"
                    )
            }
        }
    }

    func formatGeometryIsCompatible(
        _ lhs: CMFormatDescription,
        _ rhs: CMFormatDescription
    ) -> Bool {
        switch CMFormatDescriptionGetMediaType(lhs) {
        case kCMMediaType_Video:
            let lhsDimensions = CMVideoFormatDescriptionGetDimensions(lhs)
            let rhsDimensions = CMVideoFormatDescriptionGetDimensions(rhs)
            return lhsDimensions.width == rhsDimensions.width
                && lhsDimensions.height == rhsDimensions.height
        case kCMMediaType_Audio:
            guard let lhsStream =
                    CMAudioFormatDescriptionGetStreamBasicDescription(lhs)?
                        .pointee,
                  let rhsStream =
                    CMAudioFormatDescriptionGetStreamBasicDescription(rhs)?
                        .pointee else {
                return false
            }
            return lhsStream.mSampleRate == rhsStream.mSampleRate
                && lhsStream.mChannelsPerFrame
                    == rhsStream.mChannelsPerFrame
        default:
            return true
        }
    }

    func fourCC(_ value: FourCharCode) -> String {
        "fourcc_" + String(format: "%08x", value)
    }

    func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? ""
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
        readers: [AVAssetReader],
        writer: AVAssetWriter,
        cancellation: AVFoundationTrackMigrationCancellationV4,
        progress: ProgressHandler?
    ) async throws {
        var finishedCount = 0
        while finishedCount < pipes.count {
            try cancellation.check()
            try checkStatuses(readers: readers, writer: writer)
            var advanced = false
            for index in pipes.indices where !pipes[index].isFinished {
                try cancellation.check()
                guard pipes[index].writerInput.isReadyForMoreMediaData else {
                    continue
                }
                guard let sourceSample = pipes[index].readerOutput
                    .copyNextSampleBuffer() else {
                    if let hook = pipes[index].videoHook {
                        do {
                            try await hook.finish()
                        } catch let error as CancellationError {
                            guard cancellation.cancellationWasRequested
                                    || Task.isCancelled else {
                                throw AVFoundationTrackMigrationExecutorV4Error
                                    .processorFailed(
                                        trackID: pipes[index].trackID,
                                        failure: .init(error)
                                    )
                            }
                            throw error
                        } catch {
                            throw AVFoundationTrackMigrationExecutorV4Error
                                .processorFailed(
                                    trackID: pipes[index].trackID,
                                    failure: .init(error)
                                )
                        }
                        try cancellation.check()
                    } else if let hook = pipes[index].nonVideoHook {
                        do {
                            try await hook.finish()
                        } catch let error as CancellationError {
                            guard cancellation.cancellationWasRequested
                                    || Task.isCancelled else {
                                throw AVFoundationTrackMigrationExecutorV4Error
                                    .processorFailed(
                                        trackID: pipes[index].trackID,
                                        failure: .init(error)
                                    )
                            }
                            throw error
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
                if let hook = pipes[index].videoHook {
                    do {
                        outputSamples = try await hook.processTemporal(
                            AVFoundationVideoSampleV4(
                                sampleBuffer: sourceSample
                            )
                        ).map(\.sampleBuffer)
                    } catch let error as CancellationError {
                        guard cancellation.cancellationWasRequested
                                || Task.isCancelled else {
                            throw AVFoundationTrackMigrationExecutorV4Error
                                .processorFailed(
                                    trackID: pipes[index].trackID,
                                    failure: .init(error)
                                )
                        }
                        throw error
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
                } else if let hook = pipes[index].nonVideoHook {
                    let inputCanonicalStreamSHA256 = try
                        canonicalSampleStreamSHA256(
                            sourceSample,
                            trackID: pipes[index].trackID
                        )
                    let output: CMSampleBuffer
                    do {
                        output = try await hook.process(
                            AVFoundationNonVideoSampleV4(
                                sampleBuffer: sourceSample
                            )
                        ).sampleBuffer
                    } catch let error as CancellationError {
                        guard cancellation.cancellationWasRequested
                                || Task.isCancelled else {
                            throw AVFoundationTrackMigrationExecutorV4Error
                                .processorFailed(
                                    trackID: pipes[index].trackID,
                                    failure: .init(error)
                                )
                        }
                        throw error
                    } catch {
                        throw AVFoundationTrackMigrationExecutorV4Error
                            .processorFailed(
                                trackID: pipes[index].trackID,
                                failure: .init(error)
                            )
                    }
                    try cancellation.check()
                    try validateNonVideoProcessedSample(
                        source: sourceSample,
                        output: output,
                        inputCanonicalStreamSHA256:
                            inputCanonicalStreamSHA256,
                        decodedTransform: hook.decodedTransform,
                        trackID: pipes[index].trackID,
                        previousPresentationTime:
                            pipes[index].lastOutputPresentationTime
                    )
                    if let presentationEnd =
                        pipes[index].nonVideoPresentationEnd {
                        outputSamples = try clipSampleBuffer(
                            output,
                            toPresentationEnd: presentationEnd,
                            trackID: pipes[index].trackID
                        ).map { [$0] } ?? []
                    } else {
                        outputSamples = [output]
                    }
                } else {
                    outputSamples = [sourceSample]
                }
                if let formatContract =
                    pipes[index].passThroughFormatContract,
                   try !formatContract.accepts(sourceSample) {
                    throw AVFoundationTrackMigrationExecutorV4Error
                        .unsupportedTrack(
                            pipes[index].trackID,
                            reason: "undeclared_sample_format_transition"
                        )
                }
                if pipes[index].verifiesEncodedSampleStream,
                   pipes[index].accumulatesSourceStreamDuringDrain {
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
                    if pipes[index].verifiesDynamicHDRStream,
                       pipes[index].accumulatesDynamicHDRStreamDuringDrain {
                        try pipes[index].dynamicHDRStream.append(outputSample)
                    }
                    try await waitUntilReady(
                        pipes[index].writerInput,
                        readers: readers,
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

    struct OutputStreamVerificationV4 {
        let digests: [MediaTrackStableIDV4: ASHSHA256V4]
        let observedToLogicalTrackID: [
            MediaTrackStableIDV4: MediaTrackStableIDV4
        ]
    }

    func verifyPassThroughStreams(
        outputAsset: AVAsset,
        outputGraph: MediaTrackGraphV4,
        pipes: [TrackPipe],
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws -> OutputStreamVerificationV4 {
        let outputTracks = try await outputAsset.load(.tracks)
        guard outputTracks.count == outputGraph.tracks.count,
              outputTracks.count == pipes.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }

        var digests: [MediaTrackStableIDV4: ASHSHA256V4] = [:]
        var observedToLogical: [
            MediaTrackStableIDV4: MediaTrackStableIDV4
        ] = [:]
        for (ordinal, outputTrack) in outputTracks.enumerated() {
            try cancellation.check()
            let pipe = pipes[ordinal]
            let observedNode = outputGraph.tracks[ordinal]
            guard outputTrack.mediaType == pipe.writerInput.mediaType else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .outputTrackOrderMismatch(
                        ordinal: ordinal,
                        expectedTrackID: pipe.trackID,
                        expectedMediaType: pipe.writerInput.mediaType.rawValue,
                        actualMediaType: outputTrack.mediaType.rawValue
                    )
            }
            guard observedToLogical.updateValue(
                pipe.trackID,
                forKey: observedNode.identity.stableID
            ) == nil else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sourceTrackInventoryMismatch
            }
            guard pipe.verifiesEncodedSampleStream
                    || pipe.verifiesDynamicHDRStream else {
                continue
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
            var encoded = SampleStreamAccumulatorV4()
            var dynamicHDR = DynamicHDRMetadataStreamAccumulatorV4()
            while let sample = output.copyNextSampleBuffer() {
                try cancellation.check()
                do {
                    if pipe.verifiesEncodedSampleStream {
                        try encoded.append(sample)
                    }
                    if pipe.verifiesDynamicHDRStream {
                        try dynamicHDR.append(sample)
                    }
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
            if pipe.verifiesEncodedSampleStream,
               encoded.digest != pipe.sampleStream.digest {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sampleStreamDigestMismatch(
                        trackID: pipe.trackID,
                        expected: pipe.sampleStream.digest,
                        actual: encoded.digest
                    )
            }
            if pipe.verifiesDynamicHDRStream {
                try Self.verifyDynamicHDRStream(
                    expected: pipe.dynamicHDRStream,
                    actual: dynamicHDR
                )
            }
            if pipe.verifiesEncodedSampleStream {
                digests[pipe.trackID] = encoded.digest
            }
        }
        return OutputStreamVerificationV4(
            digests: digests,
            observedToLogicalTrackID: observedToLogical
        )
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
        plan: MediaTrackGraphPlanV4,
        observedToLogicalID: [
            MediaTrackStableIDV4: MediaTrackStableIDV4
        ]
    ) throws -> MediaTrackGraphV4 {
        let expectedTracks = plan.tracks.compactMap(\.expectedOutput)
        let expectedByID = Dictionary(
            uniqueKeysWithValues: expectedTracks.map {
                ($0.identity.stableID, $0)
            }
        )
        guard observed.tracks.count == expectedTracks.count,
              observedToLogicalID.count == observed.tracks.count else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sourceTrackInventoryMismatch
        }
        let tracks = try observed.tracks.map { actual in
            guard let logicalID = observedToLogicalID[
                actual.identity.stableID
            ], let expected = expectedByID[logicalID] else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .sourceTrackInventoryMismatch
            }
            return try MediaTrackNodeV4(
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
        readers: [AVAssetReader],
        writer: AVAssetWriter,
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try cancellation.check()
            try checkStatuses(readers: readers, writer: writer)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitForReaderCompletion(
        _ readers: [AVAssetReader],
        writer: AVAssetWriter,
        cancellation: AVFoundationTrackMigrationCancellationV4
    ) async throws {
        for _ in 0..<1_000 where readers.contains(where: {
            $0.status == .reading
        }) {
            try cancellation.check()
            try checkStatuses(readers: readers, writer: writer)
            try await Task.sleep(for: .milliseconds(1))
        }
        guard readers.allSatisfy({ $0.status == .completed }) else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .readerFailed(.init(readers.first(where: {
                    $0.status != .completed
                })?.error))
        }
    }

    func checkStatuses(
        readers: [AVAssetReader],
        writer: AVAssetWriter
    ) throws {
        if let reader = readers.first(where: {
            $0.status == .failed || $0.status == .cancelled
        }) {
            throw AVFoundationTrackMigrationExecutorV4Error
                .readerFailed(.init(reader.error))
        }
        if writer.status == .failed || writer.status == .cancelled {
            throw AVFoundationTrackMigrationExecutorV4Error
                .writerFailed(.init(writer.error))
        }
    }

    func uniqueReaders(in pipes: [TrackPipe]) -> [AVAssetReader] {
        var identities = Set<ObjectIdentifier>()
        return pipes.compactMap { pipe in
            let identity = ObjectIdentifier(pipe.reader)
            return identities.insert(identity).inserted ? pipe.reader : nil
        }
    }

    func sampleTimingEqual(
        _ source: CMSampleBuffer,
        _ output: CMSampleBuffer
    ) -> Bool {
        let sourceCount = CMSampleBufferGetNumSamples(source)
        guard sourceCount == CMSampleBufferGetNumSamples(output) else {
            return false
        }
        for index in 0..<sourceCount {
            var sourceTiming = CMSampleTimingInfo.invalid
            var outputTiming = CMSampleTimingInfo.invalid
            guard CMSampleBufferGetSampleTimingInfo(
                source,
                at: index,
                timingInfoOut: &sourceTiming
            ) == noErr,
            CMSampleBufferGetSampleTimingInfo(
                output,
                at: index,
                timingInfoOut: &outputTiming
            ) == noErr,
            exactTimeEqual(
                sourceTiming.presentationTimeStamp,
                outputTiming.presentationTimeStamp
            ),
            exactTimeEqual(
                sourceTiming.decodeTimeStamp,
                outputTiming.decodeTimeStamp
            ),
            exactTimeEqual(sourceTiming.duration, outputTiming.duration) else {
                return false
            }
        }
        return true
    }

    func exactTimeEqual(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        lhs.value == rhs.value
            && lhs.timescale == rhs.timescale
            && lhs.flags == rhs.flags
            && lhs.epoch == rhs.epoch
    }

    func cmTime(
        _ time: ExactRationalV4,
        trackID: MediaTrackStableIDV4
    ) throws -> CMTime {
        guard time.denominator <= Int64(Int32.max) else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .unsupportedTrack(
                    trackID,
                    reason: "edit_time_not_representable"
                )
        }
        return CMTime(
            value: time.numerator,
            timescale: Int32(time.denominator)
        )
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

    func validateNonVideoProcessedSample(
        source: CMSampleBuffer,
        output: CMSampleBuffer,
        inputCanonicalStreamSHA256: ASHSHA256V4,
        decodedTransform: AVFoundationNonVideoDecodedTransformV4,
        trackID: MediaTrackStableIDV4,
        previousPresentationTime: CMTime?
    ) throws {
        guard sampleTimingEqual(source, output) else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSampleChangedTiming(trackID)
        }
        let sourceType = CMSampleBufferGetFormatDescription(source).map {
            CMFormatDescriptionGetMediaType($0)
        }
        let outputType = CMSampleBufferGetFormatDescription(output).map {
            CMFormatDescriptionGetMediaType($0)
        }
        guard let sourceType, let outputType, sourceType == outputType else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSampleMediaTypeMismatch(
                    trackID,
                    expected: sourceType.map(fourCC) ?? "missing",
                    actual: outputType.map(fourCC) ?? "missing"
                )
        }
        switch decodedTransform {
        case .preserveCanonicalSampleStream:
            guard try canonicalSampleStreamSHA256(
                output,
                trackID: trackID
            ) == inputCanonicalStreamSHA256 else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSampleCanonicalStreamMismatch(trackID)
            }
        }
        let presentation = CMSampleBufferGetPresentationTimeStamp(output)
        guard presentation.isNumeric,
              previousPresentationTime.map({
                  CMTimeCompare(presentation, $0) > 0
              }) ?? true else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSampleTimestampsNotStrictlyIncreasing(trackID)
        }
    }

    func canonicalSampleStreamSHA256(
        _ sample: CMSampleBuffer,
        trackID: MediaTrackStableIDV4
    ) throws -> ASHSHA256V4 {
        var accumulator = SampleStreamAccumulatorV4()
        do {
            try accumulator.append(sample)
        } catch let error as SampleStreamAccumulatorV4.Error {
            throw AVFoundationTrackMigrationExecutorV4Error
                .sampleStreamUnrepresentable(
                    trackID: trackID,
                    status: error.status
                )
        }
        return accumulator.digest
    }

    /// AVAssetReader can resample a mixed-description PCM track into slightly
    /// more decoded frames than the source track's declared presentation
    /// range. Keep the encoder input on the graph's exact boundary by copying
    /// only the complete PCM samples that fit before that boundary.
    func clipSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        toPresentationEnd presentationEnd: CMTime,
        trackID: MediaTrackStableIDV4
    ) throws -> CMSampleBuffer? {
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0 else { return sampleBuffer }
        guard sampleCount <= Int(Int32.max) else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSamplePresentationRangeUnrepresentable(
                    trackID,
                    reason: "sample_count_exceeds_core_media_limit"
                )
        }

        let presentationStart = CMSampleBufferGetPresentationTimeStamp(
            sampleBuffer
        )
        guard presentationStart.isNumeric, presentationEnd.isNumeric else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSamplePresentationRangeUnrepresentable(
                    trackID,
                    reason: "non_numeric_boundary"
                )
        }
        guard CMTimeCompare(presentationStart, presentationEnd) < 0 else {
            return nil
        }

        var sourceTimings: [CMSampleTimingInfo] = []
        sourceTimings.reserveCapacity(sampleCount)
        var expectedPresentation = presentationStart
        var retainedCount = 0
        var retainedEnd: CMTime?
        for index in 0..<sampleCount {
            var timing = CMSampleTimingInfo.invalid
            guard CMSampleBufferGetSampleTimingInfo(
                sampleBuffer,
                at: index,
                timingInfoOut: &timing
            ) == noErr,
            timing.presentationTimeStamp.isNumeric,
            timing.duration.isNumeric,
            timing.duration.value > 0,
            CMTimeCompare(
                timing.presentationTimeStamp,
                expectedPresentation
            ) == 0 else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSamplePresentationRangeUnrepresentable(
                        trackID,
                        reason: "non_contiguous_sample_timing"
                    )
            }
            sourceTimings.append(timing)
            let end = CMTimeAdd(
                timing.presentationTimeStamp,
                timing.duration
            )
            if CMTimeCompare(end, presentationEnd) <= 0 {
                retainedCount += 1
                retainedEnd = end
            }
            expectedPresentation = end
        }
        guard retainedCount < sampleCount else { return sampleBuffer }
        guard retainedCount > 0,
              retainedEnd.map({
                  CMTimeCompare($0, presentationEnd) == 0
              }) == true else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSamplePresentationRangeUnrepresentable(
                    trackID,
                    reason: "boundary_not_sample_aligned"
                )
        }

        var clipped: CMSampleBuffer?
        let clipStatus = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleRange: CFRange(
                location: 0,
                length: retainedCount
            ),
            sampleBufferOut: &clipped
        )
        guard clipStatus == noErr, let clipped else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSampleClipFailed(trackID, status: clipStatus)
        }
        guard CMSampleBufferGetNumSamples(clipped) == retainedCount else {
            throw AVFoundationTrackMigrationExecutorV4Error
                .processedSamplePresentationRangeUnrepresentable(
                    trackID,
                    reason: "clipped_sample_count_mismatch"
                )
        }
        for index in 0..<retainedCount {
            var clippedTiming = CMSampleTimingInfo.invalid
            let sourceTiming = sourceTimings[index]
            guard CMSampleBufferGetSampleTimingInfo(
                clipped,
                at: index,
                timingInfoOut: &clippedTiming
            ) == noErr,
            exactTimeEqual(
                sourceTiming.presentationTimeStamp,
                clippedTiming.presentationTimeStamp
            ),
            exactTimeEqual(
                sourceTiming.decodeTimeStamp,
                clippedTiming.decodeTimeStamp
            ),
            exactTimeEqual(sourceTiming.duration, clippedTiming.duration) else {
                throw AVFoundationTrackMigrationExecutorV4Error
                    .processedSamplePresentationRangeUnrepresentable(
                        trackID,
                        reason: "clipped_sample_timing_mismatch"
                    )
            }
        }
        return clipped
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

extension AVFoundationTrackMigrationExecutorV4 {
    /// Shared by the executable reopen gate and real-sample qualification so
    /// attachment-loss tests exercise the exact release comparison.
    static func verifyDynamicHDRStream(
        expected: DynamicHDRMetadataStreamAccumulatorV4,
        actual: DynamicHDRMetadataStreamAccumulatorV4
    ) throws {
        guard actual == expected else {
            throw VideoWriterFormatContractV4Error
                .dynamicHDRMetadataMismatch
        }
    }
}

struct SampleStreamAccumulatorV4 {
    struct Error: Swift.Error {
        let status: Int32
    }

    struct RetentionDiagnostic: Equatable, Sendable {
        let processedCanonicalByteCount: UInt64
        let retainedCanonicalByteCount: Int
        let fixedStateByteCount: Int
    }

    private static let hashDomain = "ash-avfoundation-sample-stream-v4"

    private var hasher: SHA256
    private var processedCanonicalByteCount: UInt64 = 0

    init() {
        var hasher = SHA256()
        hasher.update(data: Data(Self.hashDomain.utf8))
        hasher.update(data: Data([0]))
        self.hasher = hasher
    }

    var digest: ASHSHA256V4 {
        let snapshot = hasher
        let rawValue = snapshot.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        // CryptoKit always emits exactly 32 bytes, formatted above as 64
        // lowercase hexadecimal characters.
        return try! ASHSHA256V4(rawValue)
    }

    var retentionDiagnosticForQualification: RetentionDiagnostic {
        RetentionDiagnostic(
            processedCanonicalByteCount: processedCanonicalByteCount,
            retainedCanonicalByteCount: 0,
            fixedStateByteCount: MemoryLayout<Self>.stride
        )
    }

    mutating func append(_ sample: CMSampleBuffer) throws {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        let format = CMSampleBufferGetFormatDescription(sample)
        let mediaType = format.map(CMFormatDescriptionGetMediaType) ?? 0
        let mediaSubtype = format.map(CMFormatDescriptionGetMediaSubType) ?? 0
        if sampleCount == 0 {
            // Reader-generated edit/control markers are container timeline
            // state, not encoded media samples. The semantic graph verifies
            // edit lists independently; including these synthetic buffers in
            // encoded-stream identity made an unrelated transcoded lane able
            // to perturb a preserved track's digest.
            return
        }
        guard let format,
              let formatFingerprint = try? AVFoundationTrackGraphAdapterV4
                .canonicalFormatDescriptor(format).canonicalFingerprint else {
            throw Error(status: kCMFormatDescriptionError_InvalidParameter)
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
            appendCanonicalByte(1)
            appendTime(timing.presentationTimeStamp)
            appendTime(timing.decodeTimeStamp)
            appendTime(timing.duration)
            appendInteger(mediaType)
            appendInteger(mediaSubtype)
            appendCanonicalData(Data(formatFingerprint.rawValue.utf8))
            appendInteger(UInt64(sampleSize))
            appendCanonicalData(Data(ASHSHA256V4(
                rawData: payload
            ).rawValue.utf8))
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
            hasher.update(bufferPointer: $0)
        }
        recordProcessedByteCount(MemoryLayout<T>.size)
    }

    private mutating func appendCanonicalByte(_ byte: UInt8) {
        var byte = byte
        withUnsafeBytes(of: &byte) {
            hasher.update(bufferPointer: $0)
        }
        recordProcessedByteCount(1)
    }

    private mutating func appendCanonicalData(_ data: Data) {
        hasher.update(data: data)
        recordProcessedByteCount(data.count)
    }

    private mutating func recordProcessedByteCount(_ count: Int) {
        let (newCount, overflow) = processedCanonicalByteCount
            .addingReportingOverflow(UInt64(count))
        processedCanonicalByteCount = overflow ? .max : newCount
    }
}

/// Identity for frame-bound HDR10+ and post-decode metadata. Encoders may emit
/// samples in decode order, so this is a cryptographic multiset rather than an
/// ordered stream hash. Each canonical record digest is independently expanded
/// under two domain-separated SHA-256 labels and added modulo 2^256. Equality
/// binds the record count and both independent 256-bit sums, retaining
/// duplicate multiplicity while using constant memory for arbitrarily long
/// assets.
struct DynamicHDRMetadataStreamAccumulatorV4: Equatable {
    enum Error: Swift.Error {
        case recordCountOverflow
    }

    struct RetentionDiagnostic: Equatable, Sendable {
        let processedRecordCount: UInt64
        let retainedRecordByteCount: Int
        let fixedStateByteCount: Int
    }

    private static let firstMomentDomain =
        "ash-dynamic-hdr-multiset-v4-first"
    private static let secondMomentDomain =
        "ash-dynamic-hdr-multiset-v4-second"
    private static let digestDomain = "ash-dynamic-hdr-multiset-v4"

    private var firstMoment = ModularUInt256V4.zero
    private var secondMoment = ModularUInt256V4.zero
    private(set) var sampleCount: UInt64 = 0

    mutating func append(_ sample: CMSampleBuffer) throws {
        guard CMSampleBufferGetImageBuffer(sample) != nil
                || CMSampleBufferGetTotalSampleSize(sample) > 0 else {
            return
        }
        let metadata = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: sample)
        var bytes = Data()
        try appendTime(
            CMSampleBufferGetPresentationTimeStamp(sample),
            to: &bytes
        )
        if let metadata {
            bytes.append(1)
            appendData(metadata.hdr10Plus?.ituTT35Payload, to: &bytes)
            appendData(
                metadata.postDecodeProcessing?.binaryPropertyList,
                to: &bytes
            )
        } else {
            bytes.append(0)
        }
        try appendCanonicalRecord(bytes)
    }

    static func == (
        lhs: DynamicHDRMetadataStreamAccumulatorV4,
        rhs: DynamicHDRMetadataStreamAccumulatorV4
    ) -> Bool {
        lhs.sampleCount == rhs.sampleCount
            && lhs.firstMoment == rhs.firstMoment
            && lhs.secondMoment == rhs.secondMoment
    }

    var digest: String {
        var canonical = Data(Self.digestDomain.utf8)
        canonical.append(0)
        appendInteger(sampleCount, to: &canonical)
        canonical.append(firstMoment.bigEndianData)
        canonical.append(secondMoment.bigEndianData)
        var hasher = SHA256()
        hasher.update(data: canonical)
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    var retentionDiagnosticForQualification: RetentionDiagnostic {
        RetentionDiagnostic(
            processedRecordCount: sampleCount,
            retainedRecordByteCount: 0,
            fixedStateByteCount: MemoryLayout<Self>.stride
        )
    }

    /// Test-only visibility for exercising the exact production multiset
    /// update without constructing a million Core Media objects.
    mutating func appendCanonicalRecordForQualification(
        _ canonicalRecord: Data
    ) throws {
        try appendCanonicalRecord(canonicalRecord)
    }

    /// Exercises more records than a practical Core Media fixture can create
    /// while still applying the production state transition once per logical
    /// record. The contribution is precomputed because every repeated record
    /// is intentionally identical.
    mutating func appendRepeatedCanonicalRecordForQualification(
        _ canonicalRecord: Data,
        count: Int
    ) throws {
        precondition(count >= 0)
        let contribution = Self.contribution(for: canonicalRecord)
        for _ in 0..<count {
            try append(contribution)
        }
    }

    private mutating func appendCanonicalRecord(
        _ canonicalRecord: Data
    ) throws {
        try append(Self.contribution(for: canonicalRecord))
    }

    private mutating func append(
        _ contribution: MultisetContribution
    ) throws {
        let nextCount = sampleCount.addingReportingOverflow(1)
        guard !nextCount.overflow else { throw Error.recordCountOverflow }
        firstMoment.add(contribution.first)
        secondMoment.add(contribution.second)
        sampleCount = nextCount.partialValue
    }

    private struct MultisetContribution {
        let first: ModularUInt256V4
        let second: ModularUInt256V4
    }

    private static func contribution(
        for canonicalRecord: Data
    ) -> MultisetContribution {
        let recordDigest = Data(SHA256.hash(data: canonicalRecord))
        return MultisetContribution(
            first: moment(
                domain: firstMomentDomain,
                recordDigest: recordDigest
            ),
            second: moment(
                domain: secondMomentDomain,
                recordDigest: recordDigest
            )
        )
    }

    private static func moment(
        domain: String,
        recordDigest: Data
    ) -> ModularUInt256V4 {
        var bytes = Data(domain.utf8)
        bytes.append(0)
        bytes.append(recordDigest)
        return ModularUInt256V4(digest: SHA256.hash(data: bytes))
    }

    private func appendTime(_ time: CMTime, to bytes: inout Data) throws {
        guard time.isNumeric, time.timescale != 0 else {
            bytes.append(0)
            return
        }
        let exact = try ExactRationalV4(
            time.value,
            Int64(time.timescale)
        )
        bytes.append(1)
        appendInteger(exact.numerator, to: &bytes)
        appendInteger(exact.denominator, to: &bytes)
        appendInteger(time.epoch, to: &bytes)
    }

    private func appendData(_ value: Data?, to bytes: inout Data) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        appendInteger(UInt64(value.count), to: &bytes)
        bytes.append(value)
    }

    private func appendInteger<T: FixedWidthInteger>(
        _ value: T,
        to bytes: inout Data
    ) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            bytes.append(contentsOf: $0)
        }
    }
}

/// A fixed-width unsigned integer used only for modular multiset moments.
/// Limbs are stored least-significant first; overflow is intentionally
/// discarded to implement addition in Z/(2^256).
private struct ModularUInt256V4: Equatable {
    static let zero = ModularUInt256V4(
        limb0: 0,
        limb1: 0,
        limb2: 0,
        limb3: 0
    )

    private var limb0: UInt64
    private var limb1: UInt64
    private var limb2: UInt64
    private var limb3: UInt64

    init(digest: SHA256.Digest) {
        let bytes = Data(digest)
        limb3 = Self.word(bytes, at: 0)
        limb2 = Self.word(bytes, at: 8)
        limb1 = Self.word(bytes, at: 16)
        limb0 = Self.word(bytes, at: 24)
    }

    private init(
        limb0: UInt64,
        limb1: UInt64,
        limb2: UInt64,
        limb3: UInt64
    ) {
        self.limb0 = limb0
        self.limb1 = limb1
        self.limb2 = limb2
        self.limb3 = limb3
    }

    mutating func add(_ other: Self) {
        let low = limb0.addingReportingOverflow(other.limb0)
        limb0 = low.partialValue
        let one = limb1.addingReportingOverflow(other.limb1)
        let oneCarry = one.partialValue.addingReportingOverflow(
            low.overflow ? 1 : 0
        )
        limb1 = oneCarry.partialValue
        let carryOne = one.overflow || oneCarry.overflow
        let two = limb2.addingReportingOverflow(other.limb2)
        let twoCarry = two.partialValue.addingReportingOverflow(
            carryOne ? 1 : 0
        )
        limb2 = twoCarry.partialValue
        let carryTwo = two.overflow || twoCarry.overflow
        let three = limb3.addingReportingOverflow(other.limb3)
        let threeCarry = three.partialValue.addingReportingOverflow(
            carryTwo ? 1 : 0
        )
        limb3 = threeCarry.partialValue
    }

    var bigEndianData: Data {
        var bytes = Data()
        bytes.reserveCapacity(32)
        Self.append(limb3, to: &bytes)
        Self.append(limb2, to: &bytes)
        Self.append(limb1, to: &bytes)
        Self.append(limb0, to: &bytes)
        return bytes
    }

    private static func word(_ bytes: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func append(_ value: UInt64, to bytes: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) {
            bytes.append(contentsOf: $0)
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
