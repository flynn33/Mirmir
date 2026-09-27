import AVFoundation
import CoreMedia
import Darwin
import Foundation
import VideoToolbox

enum DeterministicV4InvalidSampleTimingSite: String, CaseIterable, Equatable,
    Sendable {
    case compressedPrefixInvalidConfiguration = "dv4_timing_001_compressed_prefix_invalid_configuration"
    case compressedPrefixInvalidAdmission = "dv4_timing_002_compressed_prefix_invalid_admission"
    case compressedPrefixDuplicateSelection = "dv4_timing_003_compressed_prefix_duplicate_selection"
    case decodedDurationLedgerInvalidConfiguration = "dv4_timing_004_decoded_duration_ledger_invalid_configuration"
    case decodedDurationLedgerInvalidRecord = "dv4_timing_005_decoded_duration_ledger_invalid_record"
    case decodedDurationLedgerOverlappingRecord = "dv4_timing_006_decoded_duration_ledger_overlapping_record"
    case decodedDurationLedgerUnexpectedPresentationTime = "dv4_timing_007_decoded_duration_ledger_unexpected_presentation_time"
    case decodedDurationLedgerUnconsumedRecords = "dv4_timing_008_decoded_duration_ledger_unconsumed_records"
    case segmentBoundaryInvalidTimebase = "dv4_timing_009_segment_boundary_invalid_timebase"
    case workflowTimeInexactConversion = "dv4_timing_010_workflow_time_inexact_conversion"
    case workflowTimeScalingOverflow = "dv4_timing_011_workflow_time_scaling_overflow"
    case authoritativeDurationInvalidCurrentTiming = "dv4_timing_012_authoritative_duration_invalid_current_timing"
    case authoritativeDurationInvalidFollowingDecodeTime = "dv4_timing_013_authoritative_duration_invalid_following_decode_time"
    case authoritativeDurationMissingTerminalDuration = "dv4_timing_014_authoritative_duration_missing_terminal_duration"
    case authoritativeDurationInvalidDuration = "dv4_timing_015_authoritative_duration_invalid_duration"
    case authoritativeDurationInvalidEnd = "dv4_timing_016_authoritative_duration_invalid_end"
    case authoritativeRecordsInvalidConfiguration = "dv4_timing_017_authoritative_records_invalid_configuration"
    case authoritativeRecordsDuplicatePresentationTime = "dv4_timing_018_authoritative_records_duplicate_presentation_time"
    case authoritativeRecordsInvalidSelection = "dv4_timing_019_authoritative_records_invalid_selection"
    case authoritativeRecordsMissingSelection = "dv4_timing_020_authoritative_records_missing_selection"
    case preflightRecordBoundOverflow = "dv4_timing_021_preflight_record_bound_overflow"
    case assembledScratchTimingOutsideSegment = "dv4_timing_022_assembled_scratch_timing_outside_segment"
    case processSegmentUnexpectedDecodedLedger = "dv4_timing_023_process_segment_unexpected_decoded_ledger"
    case decodedSampleAggregationFailed = "dv4_timing_024_decoded_sample_aggregation_failed"
    case decodedDurationRecordMissing = "dv4_timing_025_decoded_duration_record_missing"
    case nominalFrameDurationMissing = "dv4_timing_026_nominal_frame_duration_missing"
    case sourcePresentationTimeInvalid = "dv4_timing_027_source_presentation_time_invalid"
    case processedOutputTimingInvalid = "dv4_timing_028_processed_output_timing_invalid"
    case progressPresentationTimeInvalid = "dv4_timing_029_progress_presentation_time_invalid"
    case decodedLookaheadAggregationFailed = "dv4_timing_030_decoded_lookahead_aggregation_failed"
    case nominalDurationInvalidRational = "dv4_timing_031_nominal_duration_invalid_rational"
    case nominalDurationInvalidCMTime = "dv4_timing_032_nominal_duration_invalid_cm_time"
    case nominalCadenceInvalidNominalDuration = "dv4_timing_033_nominal_cadence_invalid_nominal_duration"
    case nominalCadenceInvalidDecodedDuration = "dv4_timing_034_nominal_cadence_invalid_decoded_duration"
    case nominalCadenceEmptyOrMismatchedSamples = "dv4_timing_035_nominal_cadence_empty_or_mismatched_samples"
    case nominalCadenceSampleCountOverflow = "dv4_timing_036_nominal_cadence_sample_count_overflow"
    case nominalCadenceInvalidPresentationTime = "dv4_timing_037_nominal_cadence_invalid_presentation_time"
    case nominalCadenceOffLattice = "dv4_timing_038_nominal_cadence_off_lattice"
    case scratchLedgerInvalidAssembledRange = "dv4_timing_039_scratch_ledger_invalid_assembled_range"
    case decodedPreflightAggregationFailed = "dv4_timing_040_decoded_preflight_aggregation_failed"
    case decodedPreflightInvalidPresentationTime = "dv4_timing_041_decoded_preflight_invalid_presentation_time"
    case decodedLookaheadPreflightAggregationFailed = "dv4_timing_042_decoded_lookahead_preflight_aggregation_failed"
    case decodedLookaheadInvalidPresentationTime = "dv4_timing_043_decoded_lookahead_invalid_presentation_time"
    case compressedRangeStartMismatch = "dv4_timing_044_compressed_range_start_mismatch"
    case compressedRecordInvalidDecodeTime = "dv4_timing_045_compressed_record_invalid_decode_time"
    case compressedLookaheadInvalidDecodeTime = "dv4_timing_046_compressed_lookahead_invalid_decode_time"
    case compressedRecordOutsideAdmittedRange = "dv4_timing_047_compressed_record_outside_admitted_range"
    case retimeEmptySampleBuffer = "dv4_timing_048_retime_empty_sample_buffer"
    case directReaderRangeInvalid = "dv4_timing_049_direct_reader_range_invalid"
    case canonicalizedSampleInvalidTiming = "dv4_timing_050_canonicalized_sample_invalid_timing"
    case unmappedDecodedPresentationTime = "dv4_timing_051_unmapped_decoded_presentation_time"
    case mappedSampleInvalidTiming = "dv4_timing_052_mapped_sample_invalid_timing"
    case cmTimeNotNumeric = "dv4_timing_053_cm_time_not_numeric"
    case cmTimeNotExactlyRepresentable = "dv4_timing_054_cm_time_not_exactly_representable"
    case rationalDenominatorNotRepresentable = "dv4_timing_055_rational_denominator_not_representable"
}

enum DeterministicV4MediaSegmentError: Error, Equatable, LocalizedError,
    CustomNSError, Sendable {
    case invalidMaximumInputFrames(Int)
    case primaryTrackMissing
    case segmentAlreadyExists(String)
    case readerCreationFailed
    case readerRejectedTrack
    case readerStartFailed
    case readerFailed
    case writerCreationFailed
    case writerRejectedTrack
    case writerStartFailed
    case writerFailed
    case emptySegment
    case nonContiguousBoundary
    case invalidSampleTiming(site: DeterministicV4InvalidSampleTimingSite)
    case retimingFailed(Int32)
    case appendFailed
    case dynamicHDRMetadataMismatch
    case unsafeTemporaryRoot(String)
    case scratchLedgerIO(String)
    case scratchLedgerMismatch
    case incompleteSegmentSequence
    case preservationReportMissing

    static let errorDomain = "Mirmir.DeterministicV4MediaSegmentError"

    var errorCode: Int {
        switch self {
        case .invalidMaximumInputFrames: 0
        case .segmentAlreadyExists: 1
        case .retimingFailed: 2
        case .unsafeTemporaryRoot: 3
        case .scratchLedgerIO: 4
        case .primaryTrackMissing: 5
        case .readerCreationFailed: 6
        case .readerRejectedTrack: 7
        case .readerStartFailed: 8
        case .readerFailed: 9
        case .writerCreationFailed: 10
        case .writerRejectedTrack: 11
        case .writerStartFailed: 12
        case .writerFailed: 13
        case .emptySegment: 14
        case .nonContiguousBoundary: 15
        case .invalidSampleTiming: 16
        case .appendFailed: 17
        case .dynamicHDRMetadataMismatch: 18
        case .scratchLedgerMismatch: 19
        case .incompleteSegmentSequence: 20
        case .preservationReportMissing: 21
        }
    }

    var errorUserInfo: [String: Any] {
        guard let errorDescription else { return [:] }
        return [NSLocalizedDescriptionKey: errorDescription]
    }

    var errorDescription: String? {
        guard case .invalidSampleTiming(let site) = self else { return nil }
        return "Invalid sample timing at site \(site.rawValue)."
    }
}

struct DeterministicV4DecodedDurationRecordV4: Equatable, Sendable {
    let presentationTime: HDR10PlusPresentationTimeV4
    let duration: CMTime
}

struct DeterministicV4CompressedTimingRecordV4: Equatable, Sendable {
    let presentationTime: HDR10PlusPresentationTimeV4
    let decodeTime: CMTime
    let readerReportedDuration: CMTime
}

struct DeterministicV4CompressedPrefixSelectorV4: Sendable {
    private let selectedPresentationTimes:
        Set<HDR10PlusPresentationTimeV4>
    private let maximumScannedRecordCount: Int
    private var seenPresentationTimes:
        Set<HDR10PlusPresentationTimeV4> = []
    private var foundSelectedPresentationTimes:
        Set<HDR10PlusPresentationTimeV4> = []

    init(
        selectedPresentationTimes: Set<HDR10PlusPresentationTimeV4>,
        maximumScannedRecordCount: Int
    ) throws {
        guard !selectedPresentationTimes.isEmpty,
              maximumScannedRecordCount
                >= selectedPresentationTimes.count else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .compressedPrefixInvalidConfiguration)
        }
        self.selectedPresentationTimes = selectedPresentationTimes
        self.maximumScannedRecordCount = maximumScannedRecordCount
    }

    var isComplete: Bool {
        foundSelectedPresentationTimes.count
            == selectedPresentationTimes.count
    }

    var hasRemainingCapacity: Bool {
        seenPresentationTimes.count < maximumScannedRecordCount
    }

    var scannedRecordCount: Int { seenPresentationTimes.count }

    func hasSeen(_ presentationTime: HDR10PlusPresentationTimeV4) -> Bool {
        seenPresentationTimes.contains(presentationTime)
    }

    mutating func admit(
        _ presentationTime: HDR10PlusPresentationTimeV4
    ) throws -> Bool {
        guard !isComplete,
              hasRemainingCapacity,
              seenPresentationTimes.insert(presentationTime).inserted else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .compressedPrefixInvalidAdmission)
        }
        guard selectedPresentationTimes.contains(presentationTime) else {
            return false
        }
        guard foundSelectedPresentationTimes.insert(
            presentationTime
        ).inserted else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .compressedPrefixDuplicateSelection)
        }
        return true
    }
}

struct DeterministicV4DecodedDurationLedgerV4: Sendable {
    private let records: [DeterministicV4DecodedDurationRecordV4]
    private var nextIndex = 0

    init(
        records: [DeterministicV4DecodedDurationRecordV4],
        maximumRecordCount: Int
    ) throws {
        guard maximumRecordCount > 0,
              !records.isEmpty,
              records.count <= maximumRecordCount else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedDurationLedgerInvalidConfiguration)
        }
        var prior: DeterministicV4DecodedDurationRecordV4?
        for record in records {
            guard record.duration.isNumeric,
                  record.duration.value > 0,
                  !record.duration.flags.contains(.hasBeenRounded),
                  prior.map({ $0.presentationTime < record.presentationTime })
                    ?? true else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedDurationLedgerInvalidRecord)
            }
            if let prior {
                let priorEnd = CMTimeAdd(
                    prior.presentationTime.cmTime,
                    prior.duration
                )
                guard priorEnd.isNumeric,
                      !priorEnd.flags.contains(.hasBeenRounded),
                      CMTimeCompare(
                        priorEnd,
                        record.presentationTime.cmTime
                      ) <= 0 else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedDurationLedgerOverlappingRecord)
                }
            }
            prior = record
        }
        self.records = records
    }

    mutating func consume(
        presentationTime: HDR10PlusPresentationTimeV4
    ) throws -> CMTime {
        guard records.indices.contains(nextIndex),
              records[nextIndex].presentationTime == presentationTime else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedDurationLedgerUnexpectedPresentationTime)
        }
        let duration = records[nextIndex].duration
        nextIndex += 1
        return duration
    }

    func seal() throws {
        guard nextIndex == records.count else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedDurationLedgerUnconsumedRecords)
        }
    }
}

struct DeterministicV4PrimaryTimelineMappingV4: Codable, Equatable,
    Hashable, Sendable {
    static let currentSchemaID = "ash.direct-primary-timeline-mapping.v4"
    static let identityDomain =
        "ash-direct-primary-timeline-mapping-v4"

    enum Topology: String, Codable, Equatable, Hashable, Sendable {
        case singleNonempty = "single_nonempty"
        case leadingEmptyThenNonempty =
            "leading_empty_then_single_nonempty"
    }

    let schemaID: String
    let mediaRange: MediaExactTimeRangeV4
    let targetRange: MediaExactTimeRangeV4
    let offset: ExactRationalV4
    let topology: Topology
    let acceptedEdits: [MediaTrackEditV4]

    init(plannedPrimary: MediaTrackPlannedTrackV4) throws {
        guard plannedPrimary.action == .process,
              let expected = plannedPrimary.expectedOutput,
              plannedPrimary.source.timeRange == expected.timeRange,
              plannedPrimary.source.edits == expected.edits else {
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }
        let edits = expected.edits
        guard edits.enumerated().allSatisfy({
            $0.element.ordinal == UInt32($0.offset)
        }) else {
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }
        let nonempty = edits.filter { !$0.isEmpty }
        guard nonempty.count == 1,
              let mapping = nonempty.first,
              let sourceRange = mapping.source,
              sourceRange.duration.isPositive,
              sourceRange.duration == mapping.target.duration,
              sourceRange.start >= .zero,
              mapping.target.start >= .zero else {
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }

        let acceptedTopology: Topology
        switch edits.count {
        case 1 where edits[0] == mapping:
            guard expected.timeRange == mapping.target else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            acceptedTopology = .singleNonempty
        case 2 where edits[0].isEmpty && edits[1] == mapping:
            let leading = edits[0]
            let leadingEnd = try leading.target.start.adding(
                leading.target.duration
            )
            let fullEnd = try expected.timeRange.start.adding(
                expected.timeRange.duration
            )
            let mappedEnd = try mapping.target.start.adding(
                mapping.target.duration
            )
            guard leading.target.start >= .zero,
                  leading.target.duration.isPositive,
                  expected.timeRange.duration.isPositive,
                  expected.timeRange.start == leading.target.start,
                  leadingEnd == mapping.target.start,
                  fullEnd == mappedEnd else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            acceptedTopology = .leadingEmptyThenNonempty
        default:
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }

        let exactOffset = try mapping.target.start.subtracting(
            sourceRange.start
        )
        let sourceEnd = try sourceRange.start.adding(sourceRange.duration)
        let targetEnd = try mapping.target.start.adding(
            mapping.target.duration
        )
        guard try sourceRange.start.adding(exactOffset)
                == mapping.target.start,
              try sourceEnd.adding(exactOffset) == targetEnd else {
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }
        schemaID = Self.currentSchemaID
        mediaRange = sourceRange
        targetRange = mapping.target
        offset = exactOffset
        topology = acceptedTopology
        acceptedEdits = edits
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            guard schemaID == Self.currentSchemaID else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            return try ASHCanonicalJSONV4.hash(
                self,
                domain: Self.identityDomain
            )
        }
    }

    var mediaEnd: ExactRationalV4 {
        get throws { try mediaRange.start.adding(mediaRange.duration) }
    }

    var targetEnd: ExactRationalV4 {
        get throws { try targetRange.start.adding(targetRange.duration) }
    }
}

struct DeterministicV4HDR10PlusPreservationReportV4: Codable, Equatable,
    Hashable, Sendable {
    static let currentSchemaID =
        "ash.hdr10plus-segment-preservation-report.v4.3"

    enum Route: String, Codable, Equatable, Hashable, Sendable {
        case canonicalDynamicAbsentOnePass =
            "ash.canonical-dynamic-absent-one-pass.v4"
        case boundedSegmentPrefixSEI =
            "ash.bounded-hdr10plus-segment-prefix-sei.v4"
    }

    let schemaID: String
    let routeID: Route
    let parserID: String
    let rewriterID: String
    let timelineMappingSHA256: ASHSHA256V4
    let sourceLedgerSHA256: ASHSHA256V4
    let outputLedgerSHA256: ASHSHA256V4
    let rewrittenSampleCount: Int
    let segmentCount: Int

    private enum CodingKeys: String, CodingKey {
        case schemaID
        case routeID
        case parserID
        case rewriterID
        case timelineMappingSHA256
        case sourceLedgerSHA256
        case outputLedgerSHA256
        case rewrittenSampleCount
        case segmentCount
    }

    private struct Fold: Codable {
        let previous: ASHSHA256V4
        let segmentOrdinal: Int
        let ledger: ASHSHA256V4
    }

    struct Accumulator: Sendable {
        private var source: ASHSHA256V4
        private var output: ASHSHA256V4
        private var timelineMappingSHA256: ASHSHA256V4?
        private var rewritten = 0
        private var count = 0

        init() throws {
            source = try ASHCanonicalJSONV4.hash(
                "empty",
                domain: "ash-hdr10plus-segment-source-ledgers-v4-root"
            )
            output = try ASHCanonicalJSONV4.hash(
                "empty",
                domain: "ash-hdr10plus-segment-output-ledgers-v4-root"
            )
            timelineMappingSHA256 = nil
        }

        mutating func append(
            _ report: DeterministicV4HDR10PlusPreservationReportV4
        ) throws {
            guard report.schemaID
                    == DeterministicV4HDR10PlusPreservationReportV4
                        .currentSchemaID,
                  report.routeID == .boundedSegmentPrefixSEI,
                  report.parserID
                    == AVFoundationHDRMetadataAdapterV4.compressedParserID,
                  report.rewriterID
                    == AVFoundationHDRMetadataAdapterV4.compressedRewriterID,
                  report.segmentCount == 1 else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "dynamic HDR segment report inventory differs"
                )
            }
            if let timelineMappingSHA256 {
                guard timelineMappingSHA256
                        == report.timelineMappingSHA256 else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "dynamic HDR segment timeline mapping differs"
                    )
                }
            } else {
                timelineMappingSHA256 = report.timelineMappingSHA256
            }
            source = try ASHCanonicalJSONV4.hash(
                DeterministicV4HDR10PlusPreservationReportV4.Fold(
                    previous: source,
                    segmentOrdinal: count,
                    ledger: report.sourceLedgerSHA256
                ),
                domain: "ash-hdr10plus-segment-source-ledgers-v4-fold"
            )
            output = try ASHCanonicalJSONV4.hash(
                DeterministicV4HDR10PlusPreservationReportV4.Fold(
                    previous: output,
                    segmentOrdinal: count,
                    ledger: report.outputLedgerSHA256
                ),
                domain: "ash-hdr10plus-segment-output-ledgers-v4-fold"
            )
            let addition = rewritten.addingReportingOverflow(
                report.rewrittenSampleCount
            )
            guard !addition.overflow else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "dynamic HDR rewritten sample count overflows"
                )
            }
            rewritten = addition.partialValue
            let nextCount = count.addingReportingOverflow(1)
            guard !nextCount.overflow else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "dynamic HDR segment count overflows"
                )
            }
            count = nextCount.partialValue
        }

        func finalize()
            throws -> DeterministicV4HDR10PlusPreservationReportV4 {
            guard count > 0, let timelineMappingSHA256 else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "dynamic HDR segment report inventory is empty"
                )
            }
            return try DeterministicV4HDR10PlusPreservationReportV4(
                routeID: .boundedSegmentPrefixSEI,
                timelineMappingSHA256: timelineMappingSHA256,
                sourceLedgerSHA256: source,
                outputLedgerSHA256: output,
                rewrittenSampleCount: rewritten,
                segmentCount: count
            )
        }
    }

    init(
        routeID: Route = .boundedSegmentPrefixSEI,
        timelineMappingSHA256: ASHSHA256V4,
        sourceLedgerSHA256: ASHSHA256V4,
        outputLedgerSHA256: ASHSHA256V4,
        rewrittenSampleCount: Int,
        segmentCount: Int = 1
    ) throws {
        guard rewrittenSampleCount >= 0 else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR preservation report counts are invalid"
            )
        }
        switch routeID {
        case .canonicalDynamicAbsentOnePass:
            let expectedSource = try ASHCanonicalJSONV4.hash(
                "empty",
                domain:
                    "ash-hdr10plus-canonical-absent-source-ledger-v4"
            )
            let expectedOutput = try ASHCanonicalJSONV4.hash(
                "empty",
                domain:
                    "ash-hdr10plus-canonical-absent-output-ledger-v4"
            )
            guard rewrittenSampleCount == 0,
                  segmentCount == 0,
                  sourceLedgerSHA256 == expectedSource,
                  outputLedgerSHA256 == expectedOutput else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "absent dynamic HDR one-pass report counts are invalid"
                )
            }
        case .boundedSegmentPrefixSEI:
            guard segmentCount > 0 else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "dynamic HDR segment report inventory is empty"
                )
            }
        }
        schemaID = Self.currentSchemaID
        self.routeID = routeID
        parserID = AVFoundationHDRMetadataAdapterV4.compressedParserID
        rewriterID = AVFoundationHDRMetadataAdapterV4.compressedRewriterID
        self.timelineMappingSHA256 = timelineMappingSHA256
        self.sourceLedgerSHA256 = sourceLedgerSHA256
        self.outputLedgerSHA256 = outputLedgerSHA256
        self.rewrittenSampleCount = rewrittenSampleCount
        self.segmentCount = segmentCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaID = try values.decode(String.self, forKey: .schemaID)
        let parserID = try values.decode(String.self, forKey: .parserID)
        let rewriterID = try values.decode(String.self, forKey: .rewriterID)
        guard schemaID == Self.currentSchemaID,
              parserID == AVFoundationHDRMetadataAdapterV4.compressedParserID,
              rewriterID
                == AVFoundationHDRMetadataAdapterV4.compressedRewriterID else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "dynamic HDR preservation implementation identity differs"
            )
        }
        try self.init(
            routeID: values.decode(Route.self, forKey: .routeID),
            timelineMappingSHA256: values.decode(
                ASHSHA256V4.self,
                forKey: .timelineMappingSHA256
            ),
            sourceLedgerSHA256: values.decode(
                ASHSHA256V4.self,
                forKey: .sourceLedgerSHA256
            ),
            outputLedgerSHA256: values.decode(
                ASHSHA256V4.self,
                forKey: .outputLedgerSHA256
            ),
            rewrittenSampleCount: values.decode(
                Int.self,
                forKey: .rewrittenSampleCount
            ),
            segmentCount: values.decode(Int.self, forKey: .segmentCount)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaID, forKey: .schemaID)
        try values.encode(routeID, forKey: .routeID)
        try values.encode(parserID, forKey: .parserID)
        try values.encode(rewriterID, forKey: .rewriterID)
        try values.encode(
            timelineMappingSHA256,
            forKey: .timelineMappingSHA256
        )
        try values.encode(sourceLedgerSHA256, forKey: .sourceLedgerSHA256)
        try values.encode(outputLedgerSHA256, forKey: .outputLedgerSHA256)
        try values.encode(rewrittenSampleCount, forKey: .rewrittenSampleCount)
        try values.encode(segmentCount, forKey: .segmentCount)
    }

    static func canonicalDynamicAbsentOnePass(
        trackPlanSHA256: ASHSHA256V4
    )
        throws -> DeterministicV4HDR10PlusPreservationReportV4 {
        try DeterministicV4HDR10PlusPreservationReportV4(
            routeID: .canonicalDynamicAbsentOnePass,
            timelineMappingSHA256: notApplicableTimelineMappingSHA256(
                trackPlanSHA256: trackPlanSHA256
            ),
            sourceLedgerSHA256: ASHCanonicalJSONV4.hash(
                "empty",
                domain:
                    "ash-hdr10plus-canonical-absent-source-ledger-v4"
            ),
            outputLedgerSHA256: ASHCanonicalJSONV4.hash(
                "empty",
                domain:
                    "ash-hdr10plus-canonical-absent-output-ledger-v4"
            ),
            rewrittenSampleCount: 0,
            segmentCount: 0
        )
    }

    static func notApplicableTimelineMappingSHA256(
        trackPlanSHA256: ASHSHA256V4
    ) throws -> ASHSHA256V4 {
        struct Identity: Codable {
            let schemaID: String
            let routeID: Route
            let trackPlanSHA256: ASHSHA256V4
        }
        return try ASHCanonicalJSONV4.hash(
            Identity(
                schemaID:
                    "ash.hdr10plus-timeline-mapping-not-applicable.v4",
                routeID: .canonicalDynamicAbsentOnePass,
                trackPlanSHA256: trackPlanSHA256
            ),
            domain:
                "ash-hdr10plus-timeline-mapping-not-applicable-v4"
        )
    }

    static func durableSegmentTimelineMappingSHA256(
        trackPlanSHA256: ASHSHA256V4,
        primaryTrackID: MediaTrackStableIDV4
    ) throws -> ASHSHA256V4 {
        struct Identity: Codable {
            let schemaID: String
            let routeID: Route
            let trackPlanSHA256: ASHSHA256V4
            let primaryTrackID: MediaTrackStableIDV4
            let progressDomain: String
        }
        return try ASHCanonicalJSONV4.hash(
            Identity(
                schemaID:
                    "ash.durable-segment-media-timeline-mapping.v4",
                routeID: .boundedSegmentPrefixSEI,
                trackPlanSHA256: trackPlanSHA256,
                primaryTrackID: primaryTrackID,
                progressDomain: "source_media_pts"
            ),
            domain:
                "ash-durable-segment-media-timeline-mapping-v4"
        )
    }

    static func aggregate(
        _ reports: [DeterministicV4HDR10PlusPreservationReportV4]
    ) throws -> DeterministicV4HDR10PlusPreservationReportV4 {
        var accumulator = try Accumulator()
        for report in reports { try accumulator.append(report) }
        return try accumulator.finalize()
    }
}

struct DeterministicV4MediaSegmentResultV4: Sendable {
    let segmentURL: URL
    let startTime: WorkflowMediaTimeV4
    let endTimeExclusive: WorkflowMediaTimeV4
    let inputSampleCount: Int
    let outputSampleCount: Int
    let lastCompletedInputOrdinal: Int64
    let terminal: Bool
    let nextStartTime: WorkflowMediaTimeV4?
    let processingDurationSeconds: TimeInterval
    let hdr10PlusPreservation:
        DeterministicV4HDR10PlusPreservationReportV4?
    let hdr10PlusOutputLedger: HDR10PlusSegmentLedgerSnapshotV4?

    init(
        segmentURL: URL,
        startTime: WorkflowMediaTimeV4,
        endTimeExclusive: WorkflowMediaTimeV4,
        inputSampleCount: Int,
        outputSampleCount: Int,
        lastCompletedInputOrdinal: Int64,
        terminal: Bool,
        nextStartTime: WorkflowMediaTimeV4? = nil,
        processingDurationSeconds: TimeInterval,
        hdr10PlusPreservation:
            DeterministicV4HDR10PlusPreservationReportV4? = nil,
        hdr10PlusOutputLedger: HDR10PlusSegmentLedgerSnapshotV4? = nil
    ) {
        self.segmentURL = segmentURL
        self.startTime = startTime
        self.endTimeExclusive = endTimeExclusive
        self.inputSampleCount = inputSampleCount
        self.outputSampleCount = outputSampleCount
        self.lastCompletedInputOrdinal = lastCompletedInputOrdinal
        self.terminal = terminal
        self.nextStartTime = nextStartTime
        self.processingDurationSeconds = processingDurationSeconds
        self.hdr10PlusPreservation = hdr10PlusPreservation
        self.hdr10PlusOutputLedger = hdr10PlusOutputLedger
    }
}

enum DeterministicV4MediaExecutionReceiptError: Error, Equatable, Sendable {
    case preparedPlanExecutorMismatch
    case actualBackendIdentityMismatch
    case sourceGraphIdentityMismatch
    case trackPlanIdentityMismatch
    case migrationBlueprintIdentityMismatch
    case migratedTrackInventoryMismatch
    case semanticVerificationIdentityMismatch
    case outputGraphIdentityMismatch
    case dynamicHDRTimelineMappingMismatch
}

struct DeterministicV4MediaPlannedTrackReceiptV4: Codable, Equatable,
    Hashable, Sendable {
    let ordinal: Int
    let stableID: String
    let kind: String
    let action: MediaTrackActionV4
}

struct DeterministicV4MediaMigratedTrackReceiptV4: Codable, Equatable,
    Hashable, Sendable {
    let stableID: String
    let action: MediaTrackActionV4
    let migratedSampleCount: Int64
    let sourceSampleStreamSHA256: ASHSHA256V4?
    let outputSampleStreamSHA256: ASHSHA256V4?
}

/// Immutable facts emitted from the exact plan, backend, migration result,
/// and output verification used by one deterministic whole-asset execution.
/// No caller-provided preflight value participates in this receipt.
struct DeterministicV4MediaExecutionReceiptV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID =
        "ash.deterministic-media-execution-receipt.v4.3"

    let schemaID: String
    let preparedBackendType: String
    let executor: ASHExecutorV4
    let requestedBackendID: UpscaleBackendID
    let actualBackendID: UpscaleBackendID
    let ashPlanSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let runtimeProvenanceSHA256: ASHSHA256V4
    let trackPlanSHA256: ASHSHA256V4
    let sourceGraphSHA256: ASHSHA256V4
    let migrationSourceGraphSHA256: ASHSHA256V4
    let migrationPlanSHA256: ASHSHA256V4
    let migrationBlueprintSHA256: ASHSHA256V4
    let sourceAssetMetadataSHA256: ASHSHA256V4
    let outputAssetMetadataSHA256: ASHSHA256V4
    let sourceChapterMetadataSHA256: ASHSHA256V4
    let outputChapterMetadataSHA256: ASHSHA256V4
    let outputGraphSHA256: ASHSHA256V4
    let semanticVerificationSHA256: ASHSHA256V4
    let primaryTrackOrdinal: Int
    let plannedTracks: [DeterministicV4MediaPlannedTrackReceiptV4]
    let migratedTracks: [DeterministicV4MediaMigratedTrackReceiptV4]
    let targetWidth: Int
    let targetHeight: Int
    let encodedWidth: Int
    let encodedHeight: Int
    let processedFrameCount: Int
    let sourceVideoTrackCount: Int
    let sourceAudioTrackCount: Int
    let plannedEnabledTrackCount: Int
    let alphaVerification: AlphaVideoWriterVerificationV4?
    let hdr10PlusPreservation:
        DeterministicV4HDR10PlusPreservationReportV4

    init(
        request: UpscaleRequest,
        preparedBackend: any PreparedDeterministicV4RuntimePlanningBackend,
        preparedPlan: DeterministicV4PreparedAssetPlan,
        migration: AVFoundationTrackMigrationExecutionResultV4,
        result: UpscaleResult,
        alphaVerification: AlphaVideoWriterVerificationV4?,
        hdr10PlusPreservation:
            DeterministicV4HDR10PlusPreservationReportV4
    ) throws {
        guard preparedPlan.ashPlan.plan.executor
                == preparedBackend.deterministicExecutor else {
            throw DeterministicV4MediaExecutionReceiptError
                .preparedPlanExecutorMismatch
        }
        guard result.actualBackendID == preparedBackend.actualBackendID else {
            throw DeterministicV4MediaExecutionReceiptError
                .actualBackendIdentityMismatch
        }
        let sourceGraphSHA256 = try preparedPlan.sourceGraph.canonicalSHA256
        guard migration.sourceGraphSHA256 == sourceGraphSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .sourceGraphIdentityMismatch
        }
        guard migration.planSHA256 == preparedPlan.trackPlan.planSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .trackPlanIdentityMismatch
        }
        switch hdr10PlusPreservation.routeID {
        case .canonicalDynamicAbsentOnePass:
            guard hdr10PlusPreservation.timelineMappingSHA256
                    == (try DeterministicV4HDR10PlusPreservationReportV4
                        .notApplicableTimelineMappingSHA256(
                            trackPlanSHA256:
                                preparedPlan.trackPlan.planSHA256
                        )) else {
                throw DeterministicV4MediaExecutionReceiptError
                    .dynamicHDRTimelineMappingMismatch
            }
        case .boundedSegmentPrefixSEI:
            let primaryRows = preparedPlan.trackPlan.plan.tracks.filter {
                $0.source.identity.stableID
                    == preparedPlan.primaryGraphTrack.identity.stableID
            }
            guard primaryRows.count == 1,
                  let primaryRow = primaryRows.first,
                  hdr10PlusPreservation.timelineMappingSHA256
                    == (try DeterministicV4PrimaryTimelineMappingV4(
                        plannedPrimary: primaryRow
                    ).canonicalSHA256) else {
                throw DeterministicV4MediaExecutionReceiptError
                    .dynamicHDRTimelineMappingMismatch
            }
        }
        guard migration.blueprintSHA256
                == (try preparedPlan.migrationBlueprint.canonicalSHA256) else {
            throw DeterministicV4MediaExecutionReceiptError
                .migrationBlueprintIdentityMismatch
        }
        let expectedMigratedTracks = preparedPlan.trackPlan.plan.tracks.filter {
            $0.action != .dropWithConsent
        }
        guard migration.trackResults.count == expectedMigratedTracks.count,
              zip(migration.trackResults, expectedMigratedTracks).allSatisfy({
                  migrated, planned in
                  migrated.trackID == planned.source.identity.stableID
                      && migrated.action == planned.action
              }) else {
            throw DeterministicV4MediaExecutionReceiptError
                .migratedTrackInventoryMismatch
        }
        let outputGraphSHA256 = try migration.outputGraph.canonicalSHA256
        guard migration.verificationReport.planSHA256
                == preparedPlan.trackPlan.planSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .semanticVerificationIdentityMismatch
        }
        guard migration.verificationReport.outputGraphSHA256
                == outputGraphSHA256 else {
            throw DeterministicV4MediaExecutionReceiptError
                .outputGraphIdentityMismatch
        }
        let enabledTracks = preparedPlan.sourceGraph.tracks.filter(\.enabled)

        schemaID = Self.currentSchemaID
        preparedBackendType = String(reflecting: type(of: preparedBackend))
        executor = preparedBackend.deterministicExecutor
        requestedBackendID = request.backendID
        actualBackendID = result.actualBackendID
        ashPlanSHA256 = preparedPlan.ashPlan.planSHA256
        runtimeManifestSHA256 = preparedPlan.ashPlan.plan
            .runtimeManifestSHA256
        runtimeProvenanceSHA256 = preparedPlan.ashPlan.plan
            .runtimeProvenanceSHA256
        trackPlanSHA256 = preparedPlan.trackPlan.planSHA256
        self.sourceGraphSHA256 = sourceGraphSHA256
        migrationSourceGraphSHA256 = migration.sourceGraphSHA256
        migrationPlanSHA256 = migration.planSHA256
        migrationBlueprintSHA256 = migration.blueprintSHA256
        sourceAssetMetadataSHA256 = migration.sourceAssetMetadataSHA256
        outputAssetMetadataSHA256 = migration.outputAssetMetadataSHA256
        sourceChapterMetadataSHA256 = migration.sourceChapterMetadataSHA256
        outputChapterMetadataSHA256 = migration.outputChapterMetadataSHA256
        self.outputGraphSHA256 = outputGraphSHA256
        semanticVerificationSHA256 = try migration.verificationReport
            .canonicalSHA256
        primaryTrackOrdinal = Int(
            preparedPlan.primaryGraphTrack.identity.ordinal
        )
        plannedTracks = preparedPlan.trackPlan.plan.tracks.map {
            DeterministicV4MediaPlannedTrackReceiptV4(
                ordinal: Int($0.source.identity.ordinal),
                stableID: $0.source.identity.stableID.rawValue,
                kind: $0.source.kind.rawValue,
                action: $0.action
            )
        }
        migratedTracks = migration.trackResults.map {
            DeterministicV4MediaMigratedTrackReceiptV4(
                stableID: $0.trackID.rawValue,
                action: $0.action,
                migratedSampleCount: $0.migratedSampleCount,
                sourceSampleStreamSHA256: $0.sourceSampleStreamSHA256,
                outputSampleStreamSHA256: $0.outputSampleStreamSHA256
            )
        }
        targetWidth = request.targetWidth
        targetHeight = request.targetHeight
        encodedWidth = result.encodedWidth
        encodedHeight = result.encodedHeight
        processedFrameCount = result.processedFrameCount
        sourceVideoTrackCount = enabledTracks.filter {
            $0.kind == .video
        }.count
        sourceAudioTrackCount = enabledTracks.filter {
            $0.kind == .audio
        }.count
        plannedEnabledTrackCount = enabledTracks.count
        self.alphaVerification = alphaVerification
        self.hdr10PlusPreservation = hdr10PlusPreservation
    }
}

struct DeterministicV4MediaProcessingExecutionV4: Sendable {
    let result: UpscaleResult
    let receipt: DeterministicV4MediaExecutionReceiptV4
    let runtimeEvents: [ASHRuntimeEventEnvelopeV4]
}

/// Canonical planning, execution, and verification diagnostics derived only
/// from the immutable facts emitted by the production whole-asset session.
/// The event chain is returned with the execution so callers never have to
/// reconstruct policy from log text or wall-clock ordering.
struct DeterministicV4MediaRuntimeEventChainV4 {
    static func make(
        receipt: DeterministicV4MediaExecutionReceiptV4
    ) throws -> [ASHRuntimeEventEnvelopeV4] {
        let attemptID = "asset." + receipt.ashPlanSHA256.rawValue
        let planning = try ASHRuntimeEventEnvelopeV4(
            attemptID: attemptID,
            ordinal: 0,
            kind: .planning,
            severity: .information,
            code: "asset_plan_bound",
            recoveryDisposition: .none,
            parentEventSHA256: [],
            planSHA256: receipt.ashPlanSHA256,
            runtimeManifestSHA256: receipt.runtimeManifestSHA256,
            trackID: nil,
            frameIndex: nil,
            presentationTime: nil,
            fields: try [
                ASHDiagnosticFieldV4(
                    key: "source_graph_sha256",
                    value: .digest(receipt.sourceGraphSHA256)
                ),
                ASHDiagnosticFieldV4(
                    key: "track_plan_sha256",
                    value: .digest(receipt.trackPlanSHA256)
                )
            ].sorted()
        )
        let execution = try ASHRuntimeEventEnvelopeV4(
            attemptID: attemptID,
            ordinal: 1,
            kind: .execution,
            severity: .information,
            code: "asset_execution_completed",
            recoveryDisposition: .none,
            parentEventSHA256: [try planning.canonicalSHA256],
            planSHA256: receipt.ashPlanSHA256,
            runtimeManifestSHA256: receipt.runtimeManifestSHA256,
            trackID: nil,
            frameIndex: nil,
            presentationTime: nil,
            fields: try [
                ASHDiagnosticFieldV4(
                    key: "actual_backend_id",
                    value: .identifier(receipt.actualBackendID.rawValue)
                ),
                ASHDiagnosticFieldV4(
                    key: "executor_id",
                    value: .identifier(receipt.executor.rawValue)
                ),
                ASHDiagnosticFieldV4(
                    key: "processed_frame_count",
                    value: .integer(Int64(clamping: receipt.processedFrameCount))
                )
            ].sorted()
        )
        let verification = try ASHRuntimeEventEnvelopeV4(
            attemptID: attemptID,
            ordinal: 2,
            kind: .verification,
            severity: .information,
            code: "asset_output_verified",
            recoveryDisposition: .none,
            parentEventSHA256: [try execution.canonicalSHA256],
            planSHA256: receipt.ashPlanSHA256,
            runtimeManifestSHA256: receipt.runtimeManifestSHA256,
            trackID: nil,
            frameIndex: nil,
            presentationTime: nil,
            fields: try [
                ASHDiagnosticFieldV4(
                    key: "output_graph_sha256",
                    value: .digest(receipt.outputGraphSHA256)
                ),
                ASHDiagnosticFieldV4(
                    key: "semantic_verification_sha256",
                    value: .digest(receipt.semanticVerificationSHA256)
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_preservation_route_id",
                    value: try .identifier(
                        receipt.hdr10PlusPreservation.routeID.rawValue
                    )
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_parser_id",
                    value: try .identifier(
                        receipt.hdr10PlusPreservation.parserID
                    )
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_rewriter_id",
                    value: try .identifier(
                        receipt.hdr10PlusPreservation.rewriterID
                    )
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_timeline_mapping_sha256",
                    value: .digest(
                        receipt.hdr10PlusPreservation
                            .timelineMappingSHA256
                    )
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_source_ledger_sha256",
                    value: .digest(
                        receipt.hdr10PlusPreservation.sourceLedgerSHA256
                    )
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_output_ledger_sha256",
                    value: .digest(
                        receipt.hdr10PlusPreservation.outputLedgerSHA256
                    )
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_rewritten_sample_count",
                    value: .integer(Int64(clamping:
                        receipt.hdr10PlusPreservation.rewrittenSampleCount
                    ))
                ),
                ASHDiagnosticFieldV4(
                    key: "hdr10plus_segment_count",
                    value: .integer(Int64(clamping:
                        receipt.hdr10PlusPreservation.segmentCount
                    ))
                )
            ].sorted()
        )
        return [planning, execution, verification]
    }
}

/// Executes the deterministic v4 whole-asset plan. AVFoundation policy is
/// fixed before migration, the processed track is the only decoded stream,
/// and every pass-through stream is verified by encoded-sample digest.
struct DeterministicV4MediaProcessingSession: Sendable {
    typealias ProgressHandler = @Sendable (UpscaleProgress) -> Void

    private static let directSegmentMaximumInputFrames = 60

    static func segmentBoundaryTimescale(
        for primaryTimebase: ExactRationalV4
    ) throws -> CMTimeScale {
        guard primaryTimebase.numerator == 1,
              primaryTimebase.denominator <= 1_000_000_000,
              let timescale = CMTimeScale(
                exactly: primaryTimebase.denominator
              ),
              timescale > 0 else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .segmentBoundaryInvalidTimebase)
        }
        return timescale
    }

    static func workflowTime(
        _ time: ExactRationalV4,
        timescale: CMTimeScale
    ) throws -> WorkflowMediaTimeV4 {
        let scale = Int64(timescale)
        guard timescale > 0,
              timescale <= 1_000_000_000,
              scale.isMultiple(of: time.denominator) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .workflowTimeInexactConversion)
        }
        let multiplier = scale / time.denominator
        let scaled = time.numerator.multipliedReportingOverflow(
            by: multiplier
        )
        guard !scaled.overflow else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .workflowTimeScalingOverflow)
        }
        return try WorkflowMediaTimeV4(
            value: scaled.partialValue,
            timescale: timescale
        )
    }

    static func authoritativeDecodedDuration(
        currentDecodeTime: CMTime,
        followingDecodeTime: CMTime?,
        currentPresentationTime: CMTime,
        terminalReaderReportedDuration: CMTime?
    ) throws -> CMTime {
        guard currentDecodeTime.isNumeric,
              currentPresentationTime.isNumeric,
              currentDecodeTime.epoch == 0,
              currentPresentationTime.epoch == currentDecodeTime.epoch,
              !currentDecodeTime.flags.contains(.hasBeenRounded),
              !currentPresentationTime.flags.contains(.hasBeenRounded) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeDurationInvalidCurrentTiming)
        }

        let duration: CMTime
        if let followingDecodeTime {
            guard terminalReaderReportedDuration == nil,
                  followingDecodeTime.isNumeric,
                  followingDecodeTime.epoch == currentDecodeTime.epoch,
                  !followingDecodeTime.flags.contains(.hasBeenRounded),
                  CMTimeCompare(
                    followingDecodeTime,
                    currentDecodeTime
                  ) > 0 else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeDurationInvalidFollowingDecodeTime)
            }
            duration = CMTimeSubtract(
                followingDecodeTime,
                currentDecodeTime
            )
        } else {
            guard let terminalReaderReportedDuration else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeDurationMissingTerminalDuration)
            }
            duration = terminalReaderReportedDuration
        }

        guard duration.isNumeric,
              duration.epoch == 0,
              duration.value > 0,
              !duration.flags.contains(.hasBeenRounded) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeDurationInvalidDuration)
        }
        let currentEnd = CMTimeAdd(currentPresentationTime, duration)
        guard currentEnd.isNumeric,
              currentEnd.epoch == currentPresentationTime.epoch,
              !currentEnd.flags.contains(.hasBeenRounded) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeDurationInvalidEnd)
        }
        return duration
    }

    static func authoritativeDecodedDurationRecords(
        compressed: [DeterministicV4CompressedTimingRecordV4],
        selectedPresentationTimes:
            Set<HDR10PlusPresentationTimeV4>? = nil,
        followingDecodeTime: CMTime?,
        readerIsExhausted: Bool,
        maximumRecordCount: Int
    ) throws -> [DeterministicV4DecodedDurationRecordV4] {
        guard maximumRecordCount > 0,
              !compressed.isEmpty,
              compressed.count <= maximumRecordCount,
              (followingDecodeTime == nil) == readerIsExhausted else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeRecordsInvalidConfiguration)
        }
        var seen = Set<HDR10PlusPresentationTimeV4>()
        var records: [DeterministicV4DecodedDurationRecordV4] = []
        records.reserveCapacity(compressed.count)
        for index in compressed.indices {
            let current = compressed[index]
            guard seen.insert(current.presentationTime).inserted else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeRecordsDuplicatePresentationTime)
            }
            let nextDecodeTime = compressed.indices.contains(index + 1)
                ? compressed[index + 1].decodeTime
                : followingDecodeTime
            let duration = try authoritativeDecodedDuration(
                currentDecodeTime: current.decodeTime,
                followingDecodeTime: nextDecodeTime,
                currentPresentationTime: current.presentationTime.cmTime,
                terminalReaderReportedDuration: nextDecodeTime == nil
                    ? current.readerReportedDuration : nil
            )
            records.append(DeterministicV4DecodedDurationRecordV4(
                presentationTime: current.presentationTime,
                duration: duration
            ))
        }
        records.sort { $0.presentationTime < $1.presentationTime }
        _ = try DeterministicV4DecodedDurationLedgerV4(
            records: records,
            maximumRecordCount: maximumRecordCount
        )
        guard let selectedPresentationTimes else { return records }
        guard !selectedPresentationTimes.isEmpty,
              selectedPresentationTimes.count <= maximumRecordCount else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeRecordsInvalidSelection)
        }
        let selectedRecords = records.filter {
            selectedPresentationTimes.contains($0.presentationTime)
        }
        guard selectedRecords.count == selectedPresentationTimes.count else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .authoritativeRecordsMissingSelection)
        }
        _ = try DeterministicV4DecodedDurationLedgerV4(
            records: selectedRecords,
            maximumRecordCount: maximumRecordCount
        )
        return selectedRecords
    }

    static func maximumCompressedPreflightRecordCount(
        maximumInputFrames: Int
    ) throws -> Int {
        let bounded = maximumInputFrames.multipliedReportingOverflow(by: 2)
        guard maximumInputFrames > 0,
              !bounded.overflow,
              bounded.partialValue >= maximumInputFrames else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .preflightRecordBoundOverflow)
        }
        return bounded.partialValue
    }

    static func assembledScratchPresentationTime(
        localPresentationTime: CMTime,
        segmentMediaStart: CMTime,
        segmentDuration: CMTime
    ) throws -> CMTime {
        let rawPresentation = CMTimeAdd(
            localPresentationTime,
            segmentMediaStart
        )
        guard localPresentationTime.isNumeric,
              segmentMediaStart.isNumeric,
              segmentDuration.isNumeric,
              rawPresentation.isNumeric,
              localPresentationTime.epoch == 0,
              segmentMediaStart.epoch == 0,
              segmentDuration.epoch == 0,
              rawPresentation.epoch == 0,
              CMTimeCompare(localPresentationTime, .zero) >= 0,
              CMTimeCompare(localPresentationTime, segmentDuration) < 0,
              CMTimeCompare(segmentMediaStart, .zero) >= 0,
              segmentDuration.value > 0,
              !localPresentationTime.flags.contains(.hasBeenRounded),
              !segmentMediaStart.flags.contains(.hasBeenRounded),
              !segmentDuration.flags.contains(.hasBeenRounded),
              !rawPresentation.flags.contains(.hasBeenRounded) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .assembledScratchTimingOutsideSegment)
        }
        return rawPresentation
    }

    private let planner: DeterministicV4WholeAssetPlanner
    private let executor: AVFoundationTrackMigrationExecutorV4
    private let outputValidator: OutputMediaValidator

    init(
        planner: DeterministicV4WholeAssetPlanner = .init(),
        executor: AVFoundationTrackMigrationExecutorV4 = .init(),
        outputValidator: OutputMediaValidator = .init()
    ) {
        self.planner = planner
        self.executor = executor
        self.outputValidator = outputValidator
    }

    func process(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend: any PreparedDeterministicV4RuntimePlanningBackend,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> DeterministicV4MediaProcessingExecutionV4 {
        let startedAt = Date()
        var backendFinishAttempted = false
        var preparedPlanForCleanup: DeterministicV4PreparedAssetPlan?
        do {
            try cancellation.check()
            progress(event(
                phase: .preparingReaderWriter,
                source: source,
                backendID: preparedBackend.actualBackendID
            ))
            let preparedPlan = try await planner.prepare(
                request: request,
                source: source,
                backend: preparedBackend,
                cancellation: cancellation
            )
            preparedPlanForCleanup = preparedPlan
            try cancellation.check()
            guard let primaryVideo = preparedPlan.primaryCanonicalTrack.video
            else {
                throw DeterministicV4WholeAssetPlannerError
                    .primaryVideoMissing
            }
            if primaryVideo.color.dynamicHDRMetadata.isEmpty {
                let migration = try await executeCanonicalDynamicAbsentOnePass(
                    request: request,
                    source: source,
                    preparedPlan: preparedPlan,
                    preparedBackend: preparedBackend,
                    cancellation: cancellation,
                    progress: progress
                )
                backendFinishAttempted = true
                try await finishPreparedBackends(
                    plan: preparedPlan,
                    planningBackend: preparedBackend
                )
                let preservation = try
                    DeterministicV4HDR10PlusPreservationReportV4
                        .canonicalDynamicAbsentOnePass(
                            trackPlanSHA256:
                                preparedPlan.trackPlan.planSHA256
                        )
                return try await finalizeExecution(
                    request: request,
                    source: source,
                    preparedBackend: preparedBackend,
                    preparedPlan: preparedPlan,
                    migration: migration,
                    hdr10PlusPreservation: preservation,
                    startedAt: startedAt,
                    cancellation: cancellation,
                    progress: progress
                )
            }
            let plannedPrimaryRows = preparedPlan.trackPlan.plan.tracks.filter {
                $0.source.identity.stableID
                    == preparedPlan.primaryGraphTrack.identity.stableID
            }
            guard plannedPrimaryRows.count == 1,
                  let plannedPrimary = plannedPrimaryRows.first,
                  plannedPrimary.action == .process,
                  let plannedPrimaryOutput = plannedPrimary.expectedOutput else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            let primaryTimelineMapping = try
                DeterministicV4PrimaryTimelineMappingV4(
                    plannedPrimary: plannedPrimary
                )
            let segmentBoundaryTimescale = try Self
                .segmentBoundaryTimescale(
                    for: preparedPlan.primaryGraphTrack.timebase
                )
            let primaryMediaTimelineStart = try Self.workflowTime(
                primaryTimelineMapping.mediaRange.start,
                timescale: segmentBoundaryTimescale
            )
            let primaryMediaTimelineEnd = try Self.workflowTime(
                primaryTimelineMapping.mediaEnd,
                timescale: segmentBoundaryTimescale
            )
            let primaryOutputTimelineStart = try Self.workflowTime(
                primaryTimelineMapping.targetRange.start,
                timescale: segmentBoundaryTimescale
            )
            let primaryOutputTimelineEnd = try Self.workflowTime(
                primaryTimelineMapping.targetEnd,
                timescale: segmentBoundaryTimescale
            )
            guard primaryMediaTimelineStart.value >= 0,
                  primaryOutputTimelineStart.value >= 0,
                  CMTimeCompare(
                    cmTime(primaryMediaTimelineEnd),
                    cmTime(primaryMediaTimelineStart)
                  ) > 0,
                  CMTimeCompare(
                    cmTime(primaryOutputTimelineEnd),
                    cmTime(primaryOutputTimelineStart)
                  ) > 0 else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            let temporaryRoot = try makeDirectSegmentTemporaryRoot()
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }

            let codecSettingsHash = try WorkflowOutputContractID(
                preparedPlan.encodedFormatDescriptor.canonicalFingerprint
                    .rawValue
            )
            let maximumOutputFramesPerInput = (preparedBackend
                as? any PreparedTemporalFrameUpscaler)?
                .maximumOutputFramesPerInput ?? 1
            let maximumScratchRecordCount = Self
                .directSegmentMaximumInputFrames
                .multipliedReportingOverflow(
                    by: maximumOutputFramesPerInput
                )
            guard !maximumScratchRecordCount.overflow,
                  maximumScratchRecordCount.partialValue > 0 else {
                throw DeterministicV4MediaSegmentError
                    .scratchLedgerMismatch
            }
            var directSegmentFacts: [DirectSegmentFact] = []
            var transientSegments: [AVFoundationTransientSegmentV4] = []
            var preservationAccumulator = try
                DeterministicV4HDR10PlusPreservationReportV4.Accumulator()
            var nextInputFrameIndex = 0
            var nextStartTime: WorkflowMediaTimeV4?
                = primaryMediaTimelineStart
            var totalOutputSampleCount = 0
            var terminal = false
            var segmentOrdinal = 0
            while true {
                try cancellation.check()
                guard let expectedSegmentStart = nextStartTime else {
                    throw DeterministicV4MediaSegmentError
                        .incompleteSegmentSequence
                }
                let segmentURL = temporaryRoot.appendingPathComponent(
                    String(format: "segment-%08d.mov", segmentOrdinal),
                    isDirectory: false
                )
                let segment = try await processSegment(
                    request: request,
                    source: source,
                    preparedPlan: preparedPlan,
                    preparedBackend: preparedBackend,
                    startingInputFrameIndex: nextInputFrameIndex,
                    startTime: expectedSegmentStart,
                    maximumInputFrames: Self
                        .directSegmentMaximumInputFrames,
                    segmentURL: segmentURL,
                    cancellation: cancellation,
                    progress: progress,
                    recordAlphaForFinalVerification: true,
                    timelineMapping: primaryTimelineMapping,
                    progressPresentationOffset:
                        primaryTimelineMapping.offset
                )
                guard segment.lastCompletedInputOrdinal
                        == Int64(
                            nextInputFrameIndex + segment.inputSampleCount - 1
                        ),
                      segment.startTime == expectedSegmentStart,
                      segment.endTimeExclusive.timescale
                        == segment.startTime.timescale,
                      segment.endTimeExclusive.value
                        > segment.startTime.value else {
                    throw DeterministicV4MediaSegmentError
                        .incompleteSegmentSequence
                }
                guard let preservation = segment.hdr10PlusPreservation,
                      let outputLedger = segment.hdr10PlusOutputLedger,
                      preservation.outputLedgerSHA256
                        == outputLedger.canonicalSHA256 else {
                    throw DeterministicV4MediaSegmentError
                        .preservationReportMissing
                }
                let scratchLedger = try sealHDR10PlusScratchLedger(
                    outputLedger,
                    segmentOrdinal: segmentOrdinal,
                    trustedRoot: temporaryRoot,
                    maximumRecordCount:
                        maximumScratchRecordCount.partialValue
                )
                try preservationAccumulator.append(preservation)
                directSegmentFacts.append(DirectSegmentFact(
                    startTime: segment.startTime,
                    endTimeExclusive: segment.endTimeExclusive,
                    scratchLedger: scratchLedger
                ))
                transientSegments.append(AVFoundationTransientSegmentV4(
                    url: segment.segmentURL,
                    startTime: segment.startTime,
                    endTimeExclusive: segment.endTimeExclusive,
                    codecSettingsHash: codecSettingsHash
                ))
                nextInputFrameIndex += segment.inputSampleCount
                let outputAddition = totalOutputSampleCount
                    .addingReportingOverflow(segment.outputSampleCount)
                guard !outputAddition.overflow else {
                    throw DeterministicV4MediaSegmentError
                        .incompleteSegmentSequence
                }
                totalOutputSampleCount = outputAddition.partialValue
                terminal = segment.terminal
                if terminal {
                    guard segment.nextStartTime == nil else {
                        throw DeterministicV4MediaSegmentError
                            .incompleteSegmentSequence
                    }
                    break
                }
                guard let followingStart = segment.nextStartTime else {
                    throw DeterministicV4MediaSegmentError
                        .incompleteSegmentSequence
                }
                nextStartTime = followingStart
                segmentOrdinal += 1
            }
            guard !directSegmentFacts.isEmpty, terminal else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            guard let finalSegment = directSegmentFacts.last,
                  finalSegment.endTimeExclusive
                    == primaryMediaTimelineEnd else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }

            backendFinishAttempted = true
            try await finishPreparedBackends(
                plan: preparedPlan,
                planningBackend: preparedBackend
            )

            try cancellation.check()
            let assembledVideoURL = temporaryRoot.appendingPathComponent(
                "assembled-primary.mov",
                isDirectory: false
            )
            let assembly = try await AVFoundationSegmentAssemblerV4()
                .assembleTransient(
                    .init(
                        trustedRootURL: temporaryRoot,
                        segments: transientSegments,
                        mediaTimelineStart: primaryMediaTimelineStart,
                        outputTimelineStart: primaryOutputTimelineStart,
                        expectedTimeRange: plannedPrimaryOutput.timeRange,
                        expectedEdits: plannedPrimaryOutput.edits,
                        destinationURL: assembledVideoURL,
                        outputFileType: .mov,
                        overwriteExistingFile: false
                    )
                )
            guard assembly.segmentCount == directSegmentFacts.count else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            try await verifyAssembledPrimaryTimeline(
                at: assembledVideoURL,
                expected: plannedPrimaryOutput
            )
            try await verifyHDR10PlusScratchLedgers(
                at: assembledVideoURL,
                videoTrackOrdinal: 0,
                segments: directSegmentFacts,
                mediaTimelineStart: primaryMediaTimelineStart,
                outputTimelineStart: primaryOutputTimelineStart,
                trustedRoot: temporaryRoot,
                maximumRecordCount:
                    maximumScratchRecordCount.partialValue,
                cancellation: cancellation
            )

            let migrationCancellation =
                AVFoundationTrackMigrationCancellationV4()
            let cancellationMonitor = Task {
                while !Task.isCancelled {
                    do {
                        try cancellation.check()
                    } catch {
                        migrationCancellation.cancel()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            defer { cancellationMonitor.cancel() }

            let migration: AVFoundationTrackMigrationExecutionResultV4
            do {
                migration = try await executor.execute(
                    .init(
                        sourceURL: request.inputURL,
                        destinationURL: request.outputURL,
                        outputFileType: .mov,
                        overwriteExistingFile:
                            request.overwriteExistingFile,
                        sourceGraph: preparedPlan.sourceGraph,
                        identifiedPlan: preparedPlan.trackPlan,
                        blueprint: preparedPlan.migrationBlueprint,
                        nonVideoTranscodeHooks:
                            preparedPlan.nonVideoTranscodeHooks,
                        processedVideoReplacement: .init(
                            trackID: preparedPlan.primaryGraphTrack.identity
                                .stableID,
                            sourceURL: assembledVideoURL
                        )
                    ),
                    cancellation: migrationCancellation,
                    progress: { state in
                        progress(self.event(
                            phase: self.phase(for: state.stage),
                            source: source,
                            backendID: preparedBackend.actualBackendID,
                            frameCount: Int(clamping: state.migratedSampleCount)
                        ))
                    }
                )
            } catch AVFoundationTrackMigrationExecutorV4Error.cancelled {
                throw MirmirError.cancelled
            }
            try cancellation.check()
            try verifyFinalPrimaryTimeline(
                graph: migration.outputGraph,
                expected: plannedPrimaryOutput,
                stableID: preparedPlan.primaryGraphTrack.identity.stableID
            )
            let primaryOrdinal = Int(
                preparedPlan.primaryGraphTrack.identity.ordinal
            )
            try await verifyHDR10PlusScratchLedgers(
                at: request.outputURL,
                videoTrackOrdinal: primaryOrdinal,
                segments: directSegmentFacts,
                mediaTimelineStart: primaryMediaTimelineStart,
                outputTimelineStart: primaryOutputTimelineStart,
                trustedRoot: temporaryRoot,
                maximumRecordCount:
                    maximumScratchRecordCount.partialValue,
                cancellation: cancellation
            )
            let alphaVerification = try await preparedPlan.verifyProcessedOutput(
                at: request.outputURL
            )
            progress(event(
                phase: .validatingOutput,
                source: source,
                backendID: preparedBackend.actualBackendID
            ))
            let facts = try await outputValidator.validate(
                url: request.outputURL,
                expectedWidth: request.targetWidth,
                expectedHeight: request.targetHeight,
                expectedAudioTopology: AudioTopologyV4(
                    graph: preparedPlan.sourceGraph,
                    preservingAudio: request.preserveAudio
                )
            )
            let primaryResult = migration.trackResults.first {
                $0.trackID == preparedPlan.primaryGraphTrack.identity.stableID
            }
            let frameCount = Int(clamping:
                primaryResult?.migratedSampleCount ?? 0
            )
            guard frameCount == totalOutputSampleCount else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            let hdr10PlusPreservation = try preservationAccumulator
                .finalize()
            progress(event(
                phase: .completed,
                source: source,
                backendID: preparedBackend.actualBackendID,
                fraction: 1,
                frameCount: frameCount,
                processedTime: facts.duration
            ))
            let result = UpscaleResult(
                outputURL: request.outputURL,
                actualBackendID: preparedBackend.actualBackendID,
                encodedWidth: facts.encodedWidth,
                encodedHeight: facts.encodedHeight,
                durationSeconds: CMTimeGetSeconds(facts.duration),
                outputCodec: request.outputCodec,
                audioResult: audioResult(
                    request: request,
                    preparedPlan: preparedPlan
                ),
                processedFrameCount: frameCount,
                processingDurationSeconds: Date().timeIntervalSince(startedAt)
            )
            let receipt = try DeterministicV4MediaExecutionReceiptV4(
                request: request,
                preparedBackend: preparedBackend,
                preparedPlan: preparedPlan,
                migration: migration,
                result: result,
                alphaVerification: alphaVerification,
                hdr10PlusPreservation: hdr10PlusPreservation
            )
            let runtimeEvents = try DeterministicV4MediaRuntimeEventChainV4
                .make(receipt: receipt)
            return DeterministicV4MediaProcessingExecutionV4(
                result: result,
                receipt: receipt,
                runtimeEvents: runtimeEvents
            )
        } catch {
            if !backendFinishAttempted {
                backendFinishAttempted = true
                if let preparedPlanForCleanup {
                    try? await finishPreparedBackends(
                        plan: preparedPlanForCleanup,
                        planningBackend: preparedBackend
                    )
                } else {
                    try? await preparedBackend.finish()
                }
            }
            throw error
        }
    }

    /// Encodes one bounded, independently decodable primary-video segment.
    /// The backend observes global frame ordinals and timestamps; only the
    /// samples submitted to this segment's writer are rebased to zero.
    func processSegment(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedPlan: DeterministicV4PreparedAssetPlan,
        preparedBackend: any PreparedDeterministicV4RuntimePlanningBackend,
        startingInputFrameIndex: Int,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames: Int,
        segmentURL: URL,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler,
        recordAlphaForFinalVerification: Bool = false,
        timelineMapping: DeterministicV4PrimaryTimelineMappingV4? = nil,
        progressPresentationOffset: ExactRationalV4 = .zero
    ) async throws -> DeterministicV4MediaSegmentResultV4 {
        guard maximumInputFrames > 0 else {
            throw DeterministicV4MediaSegmentError
                .invalidMaximumInputFrames(maximumInputFrames)
        }
        guard !FileManager.default.fileExists(atPath: segmentURL.path) else {
            throw DeterministicV4MediaSegmentError
                .segmentAlreadyExists(segmentURL.path)
        }
        let timelineMappingSHA256: ASHSHA256V4
        if let timelineMapping {
            guard progressPresentationOffset == timelineMapping.offset else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            timelineMappingSHA256 = try timelineMapping.canonicalSHA256
        } else {
            timelineMappingSHA256 = try
                DeterministicV4HDR10PlusPreservationReportV4
                    .durableSegmentTimelineMappingSHA256(
                        trackPlanSHA256:
                            preparedPlan.trackPlan.planSHA256,
                        primaryTrackID:
                            preparedPlan.primaryGraphTrack.identity.stableID
                    )
        }
        let progressOffset = cmTime(try workflowTime(
            progressPresentationOffset
        ))
        let startedAt = Date()
        let asset = AVURLAsset(
            url: request.inputURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        let primaryOrdinal = Int(
            preparedPlan.primaryGraphTrack.identity.ordinal
        )
        guard tracks.indices.contains(primaryOrdinal),
              tracks[primaryOrdinal].mediaType == .video else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        let sourceTrack = tracks[primaryOrdinal]
        let primaryTimebase = preparedPlan.primaryGraphTrack.timebase
        let segmentBoundaryTimescale = try Self.segmentBoundaryTimescale(
            for: primaryTimebase
        )
        let hook = try preparedPlan.makeProcessingHook(
            backend: preparedBackend,
            startingFrameIndex: startingInputFrameIndex,
            finishBackendAtEnd: false,
            recordAlphaForFinalVerification:
                recordAlphaForFinalVerification
        )
        let maximumOutputFramesPerInput = (preparedBackend
            as? any PreparedTemporalFrameUpscaler)?
            .maximumOutputFramesPerInput ?? 1
        let hdrPreflight = try await makeHDR10PlusSegmentPreflight(
            asset: asset,
            track: sourceTrack,
            decodedOutputSettings: hook.readerOutputSettings,
            canonicalDynamicHDRIsAbsent:
                preparedPlan.primaryCanonicalTrack.video?
                    .color.dynamicHDRMetadata.isEmpty == true,
            nominalSourceFrameDuration:
                preparedPlan.nominalSourceFrameDuration,
            startTime: startTime,
            maximumInputFrames: maximumInputFrames,
            timelineMapping: timelineMapping,
            cancellation: cancellation
        )
        let nominalDecodedDuration: CMTime?
        if timelineMapping == nil {
            nominalDecodedDuration = try Self.nominalDecodedDuration(
                preparedPlan.nominalSourceFrameDuration
            )
        } else {
            nominalDecodedDuration = nil
        }
        let hdrLedger = try HDR10PlusSegmentLedgerV4(
            sourceRecords: hdrPreflight.sourceRecords,
            maximumInputFrames: maximumInputFrames,
            maximumOutputFramesPerInput: maximumOutputFramesPerInput
        )
        var decodedDurationLedger:
            DeterministicV4DecodedDurationLedgerV4?
        if timelineMapping != nil {
            decodedDurationLedger = try
                DeterministicV4DecodedDurationLedgerV4(
                    records: hdrPreflight.decodedDurations,
                    maximumRecordCount: maximumInputFrames
                )
        } else {
            guard hdrPreflight.decodedDurations.isEmpty else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .processSegmentUnexpectedDecodedLedger)
            }
            decodedDurationLedger = nil
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DeterministicV4MediaSegmentError.readerCreationFailed
        }
        let readerOutput = AVAssetReaderTrackOutput(
            track: sourceTrack,
            outputSettings: hook.readerOutputSettings
        )
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        reader.add(readerOutput)
        if let timelineMapping {
            reader.timeRange = try directDecodedReaderTimeRange(
                startTime: startTime,
                timelineMapping: timelineMapping
            )
        } else if let startTime {
            let start = CMTime(
                value: startTime.value,
                timescale: startTime.timescale
            )
            let assetDuration = try await asset.load(.duration)
            let remaining = CMTimeSubtract(assetDuration, start)
            guard remaining.isNumeric, remaining.value > 0 else {
                throw DeterministicV4MediaSegmentError
                    .nonContiguousBoundary
            }
            reader.timeRange = CMTimeRange(start: start, duration: remaining)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: segmentURL, fileType: .mov)
        } catch {
            throw DeterministicV4MediaSegmentError.writerCreationFailed
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: hook.writerOutputSettings
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.metadata = try await sourceTrack.load(.metadata)
        writerInput.languageCode = try await sourceTrack.load(.languageCode)
        writerInput.extendedLanguageTag = try await sourceTrack
            .load(.extendedLanguageTag)
        if let naturalSize = hook.outputNaturalSize {
            writerInput.naturalSize = naturalSize
        } else {
            writerInput.naturalSize = try await sourceTrack.load(.naturalSize)
        }
        if let transform = hook.outputPreferredTransform {
            writerInput.transform = transform
        } else {
            writerInput.transform = try await sourceTrack
                .load(.preferredTransform)
        }
        guard writer.canAdd(writerInput) else {
            throw DeterministicV4MediaSegmentError.writerRejectedTrack
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw DeterministicV4MediaSegmentError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        var inputCount = 0
        var outputCount = 0
        var segmentOrigin: CMTime?
        var globalEnd: CMTime?
        var expectedDynamicHDR = DynamicHDRMetadataStreamAccumulatorV4()
        let alphaVerifier: AVFoundationAlphaVideoOutputVerifierV4?
        if case .alpha(let delivery) = preparedPlan.videoDelivery {
            alphaVerifier = try AVFoundationAlphaVideoOutputVerifierV4(
                contract: delivery.writerContract
            )
        } else {
            alphaVerifier = nil
        }

        do {
            while inputCount < maximumInputFrames {
                try cancellation.check()
                guard let decodedSample = readerOutput.copyNextSampleBuffer() else {
                    break
                }
                let sourceSampleCount = CMSampleBufferGetNumSamples(
                    decodedSample
                )
                if sourceSampleCount == 0 { continue }
                guard sourceSampleCount == 1 else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedSampleAggregationFailed)
                }
                let sourceSample: CMSampleBuffer
                if timelineMapping != nil {
                    let canonicalPresentation = try
                        canonicalDecodedPresentationTime(
                            decodedSample,
                            timelineMapping: timelineMapping
                        )
                    let durationKey = try HDR10PlusPresentationTimeV4(
                        canonicalPresentation
                    )
                    guard let authoritativeDuration = try
                        decodedDurationLedger?.consume(
                            presentationTime: durationKey
                        ) else {
                        throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedDurationRecordMissing)
                    }
                    sourceSample = try canonicalizedDecodedSample(
                        decodedSample,
                        timelineMapping: timelineMapping,
                        authoritativeDuration: authoritativeDuration
                    )
                } else {
                    guard let nominalDecodedDuration else {
                        throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalFrameDurationMissing)
                    }
                    sourceSample = try canonicalizedNominalDecodedSample(
                        decodedSample,
                        nominalDuration: nominalDecodedDuration
                    )
                }
                let sourcePTS = CMSampleBufferGetPresentationTimeStamp(
                    sourceSample
                )
                guard sourcePTS.isNumeric else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .sourcePresentationTimeInvalid)
                }
                if segmentOrigin == nil {
                    if let startTime {
                        let expected = CMTime(
                            value: startTime.value,
                            timescale: startTime.timescale
                        )
                        guard CMTimeCompare(sourcePTS, expected) == 0 else {
                            throw DeterministicV4MediaSegmentError
                                .nonContiguousBoundary
                        }
                        segmentOrigin = expected
                    } else {
                        segmentOrigin = sourcePTS
                    }
                }
                let decodedDynamicHDR = try AVFoundationHDRMetadataAdapterV4
                    .probeDynamicMetadata(from: sourceSample)
                let sourceHDR10Plus = try await hdrLedger.consumeSource(
                    presentationTime: sourcePTS,
                    decodedMetadata: decodedDynamicHDR
                )
                if let sourceHDR10Plus {
                    try AVFoundationHDRMetadataAdapterV4.migrate(
                        HDRDynamicMetadataV4(hdr10Plus: sourceHDR10Plus),
                        to: sourceSample
                    )
                }
                let outputs = try await hook.processTemporal(
                    AVFoundationVideoSampleV4(sampleBuffer: sourceSample)
                )
                guard let origin = segmentOrigin, !outputs.isEmpty else {
                    throw DeterministicV4MediaSegmentError.emptySegment
                }
                for output in outputs {
                    let absolute = output.sampleBuffer
                    let duration = CMSampleBufferGetDuration(absolute)
                    let pts = CMSampleBufferGetPresentationTimeStamp(absolute)
                    guard duration.isNumeric, duration.value > 0,
                          pts.isNumeric else {
                        throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .processedOutputTimingInvalid)
                    }
                    globalEnd = CMTimeAdd(pts, duration)
                    let local = try retime(absolute, subtracting: origin)
                    let outputDynamicHDR = try AVFoundationHDRMetadataAdapterV4
                        .probeDynamicMetadata(from: local)
                    guard outputDynamicHDR?.postDecodeProcessing == nil,
                          outputDynamicHDR?.hdr10Plus == sourceHDR10Plus else {
                        throw DeterministicV4MediaSegmentError
                            .dynamicHDRMetadataMismatch
                    }
                    try await hdrLedger.recordOutput(
                        presentationTime: CMSampleBufferGetPresentationTimeStamp(
                            local
                        ),
                        metadata: sourceHDR10Plus
                    )
                    try expectedDynamicHDR.append(local)
                    try await alphaVerifier?.record(local)
                    try await waitUntilReady(
                        writerInput,
                        reader: reader,
                        writer: writer,
                        cancellation: cancellation
                    )
                    guard writerInput.append(local) else {
                        throw DeterministicV4MediaSegmentError.appendFailed
                    }
                    outputCount += 1
                }
                inputCount += 1
                guard let progressTime = globalEnd else {
                    throw DeterministicV4MediaSegmentError.emptySegment
                }
                let presentationProgressTime = CMTimeAdd(
                    progressTime,
                    progressOffset
                )
                guard presentationProgressTime.isNumeric,
                      !presentationProgressTime.flags.contains(
                        .hasBeenRounded
                      ) else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .progressPresentationTimeInvalid)
                }
                progress(event(
                    phase: .processingVideo,
                    source: source,
                    backendID: preparedBackend.actualBackendID,
                    fraction: progressFraction(
                        processedTime: presentationProgressTime,
                        sourceDuration: source.duration
                    ),
                    frameCount: startingInputFrameIndex + inputCount,
                    processedTime: presentationProgressTime
                ))
            }
            guard inputCount > 0,
                  let segmentOrigin,
                  let globalEnd else {
                throw DeterministicV4MediaSegmentError.emptySegment
            }
            let preferredTimescale = segmentBoundaryTimescale
            try cancellation.check()
            var nextPresentationTime: CMTime?
            if inputCount == maximumInputFrames {
                while let candidate = readerOutput.copyNextSampleBuffer() {
                    try cancellation.check()
                    let sampleCount = CMSampleBufferGetNumSamples(candidate)
                    if sampleCount == 0 { continue }
                    guard sampleCount == 1 else {
                        throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedLookaheadAggregationFailed)
                    }
                    nextPresentationTime = try
                        canonicalDecodedPresentationTime(
                            candidate,
                            timelineMapping: timelineMapping
                        )
                    break
                }
            }
            let terminal = nextPresentationTime == nil
            let nextStartTime: WorkflowMediaTimeV4?
            if let nextPresentation = nextPresentationTime {
                guard nextPresentation.isNumeric,
                      CMTimeCompare(nextPresentation, globalEnd) >= 0 else {
                    throw DeterministicV4MediaSegmentError
                        .nonContiguousBoundary
                }
                nextStartTime = try workflowTime(
                    nextPresentation,
                    timescale: preferredTimescale
                )
            } else {
                nextStartTime = nil
            }
            if reader.status == .failed || reader.status == .cancelled {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            try await hook.finish()
            writerInput.markAsFinished()
            await finishWriting(writer)
            guard writer.status == .completed else {
                throw DeterministicV4MediaSegmentError.writerFailed
            }
            reader.cancelReading()

            try decodedDurationLedger?.seal()
            let sealedHDRLedger = try await hdrLedger.seal(
                expectedSourceCount: inputCount,
                expectedOutputCount: outputCount
            )
            let rewrittenSampleCount = try await rewriteSegmentHDR10Plus(
                at: segmentURL,
                expected: sealedHDRLedger.output,
                cancellation: cancellation
            )

            try await verifySegment(
                at: segmentURL,
                plan: preparedPlan,
                expectedDynamicHDR: expectedDynamicHDR,
                alphaVerifier: alphaVerifier,
                cancellation: cancellation
            )
            let workflowStart = try workflowTime(
                segmentOrigin,
                timescale: preferredTimescale
            )
            let workflowEnd = try workflowTime(
                globalEnd,
                timescale: preferredTimescale
            )
            return DeterministicV4MediaSegmentResultV4(
                segmentURL: segmentURL,
                startTime: workflowStart,
                endTimeExclusive: workflowEnd,
                inputSampleCount: inputCount,
                outputSampleCount: outputCount,
                lastCompletedInputOrdinal: Int64(
                    startingInputFrameIndex + inputCount - 1
                ),
                terminal: terminal,
                nextStartTime: nextStartTime,
                processingDurationSeconds: Date().timeIntervalSince(startedAt),
                hdr10PlusPreservation: try
                    DeterministicV4HDR10PlusPreservationReportV4(
                        timelineMappingSHA256: timelineMappingSHA256,
                        sourceLedgerSHA256:
                            sealedHDRLedger.source.canonicalSHA256,
                        outputLedgerSHA256:
                            sealedHDRLedger.output.canonicalSHA256,
                        rewrittenSampleCount: rewrittenSampleCount
                    ),
                hdr10PlusOutputLedger: sealedHDRLedger.output
            )
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: segmentURL)
            throw error
        }
    }
}

extension DeterministicV4MediaProcessingSession {
    static func isValidClockQuantization(
        _ observed: CMTime,
        of exact: CMTime
    ) -> Bool {
        guard observed.isNumeric,
              exact.isNumeric,
              observed.timescale > 0,
              observed.epoch == exact.epoch else {
            return false
        }
        if CMTimeCompare(observed, exact) == 0 {
            return true
        }
        let lower = CMTimeConvertScale(
            exact,
            timescale: observed.timescale,
            method: .roundTowardNegativeInfinity
        )
        let upper = CMTimeConvertScale(
            exact,
            timescale: observed.timescale,
            method: .roundTowardPositiveInfinity
        )
        return CMTimeCompare(observed, lower) == 0
            || CMTimeCompare(observed, upper) == 0
    }

    static func nominalDecodedDuration(
        _ nominalSourceFrameDuration: ExactRationalV4
    ) throws -> CMTime {
        guard nominalSourceFrameDuration.numerator > 0,
              nominalSourceFrameDuration.denominator > 0,
              nominalSourceFrameDuration.denominator
                <= Int64(Int32.max) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalDurationInvalidRational)
        }
        let nominalDuration = CMTime(
            value: nominalSourceFrameDuration.numerator,
            timescale: Int32(nominalSourceFrameDuration.denominator)
        )
        guard nominalDuration.isNumeric,
              nominalDuration.value > 0,
              !nominalDuration.flags.contains(.hasBeenRounded) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalDurationInvalidCMTime)
        }
        return nominalDuration
    }

    static func canonicalNominalDecodedDuration(
        observedDuration: CMTime,
        nominalDuration: CMTime
    ) throws -> CMTime {
        guard nominalDuration.isNumeric,
              nominalDuration.value > 0,
              !nominalDuration.flags.contains(.hasBeenRounded) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalCadenceInvalidNominalDuration)
        }
        if observedDuration.isNumeric,
           observedDuration.value > 0 {
            guard isValidClockQuantization(
                observedDuration,
                of: nominalDuration
            ) else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalCadenceInvalidDecodedDuration)
            }
        }
        return nominalDuration
    }

    static func validateNominalDecodedCadence(
        presentationTimes: [CMTime],
        decodedDurations: [CMTime],
        nominalSourceFrameDuration: ExactRationalV4
    ) throws {
        guard !presentationTimes.isEmpty,
              presentationTimes.count == decodedDurations.count else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalCadenceEmptyOrMismatchedSamples)
        }
        let nominalDuration = try nominalDecodedDuration(
            nominalSourceFrameDuration
        )

        guard let firstPresentationTime = presentationTimes.first,
              presentationTimes.count <= Int(Int32.max) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalCadenceSampleCountOverflow)
        }
        for (index, pair) in zip(
            presentationTimes,
            decodedDurations
        ).enumerated() {
            let (presentationTime, decodedDuration) = pair
            guard presentationTime.isNumeric,
                  presentationTime.timescale > 0,
                  !presentationTime.flags.contains(.hasBeenRounded) else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .nominalCadenceInvalidPresentationTime)
            }
            _ = try canonicalNominalDecodedDuration(
                observedDuration: decodedDuration,
                nominalDuration: nominalDuration
            )
            let expectedPresentationTime = CMTimeAdd(
                firstPresentationTime,
                CMTimeMultiply(
                    nominalDuration,
                    multiplier: Int32(index)
                )
            )
            let isOnAccumulatedLattice = isValidClockQuantization(
                presentationTime,
                of: expectedPresentationTime
            )
            var isAdjacentClockQuantization = false
            if index > 0 {
                let previousPresentationTime = presentationTimes[index - 1]
                let observedInterval = CMTimeSubtract(
                    presentationTime,
                    previousPresentationTime
                )
                let cadenceDifference = CMTimeSubtract(
                    observedInterval,
                    nominalDuration
                )
                let absoluteCadenceDifference = CMTimeCompare(
                    cadenceDifference,
                    .zero
                ) < 0
                    ? CMTimeMultiply(cadenceDifference, multiplier: -1)
                    : cadenceDifference
                let oneObservedClockTick = CMTime(
                    value: 1,
                    timescale: presentationTime.timescale
                )
                isAdjacentClockQuantization =
                    previousPresentationTime.isNumeric
                    && previousPresentationTime.epoch
                        == presentationTime.epoch
                    && observedInterval.isNumeric
                    && observedInterval.value > 0
                    && absoluteCadenceDifference.isNumeric
                    && CMTimeCompare(
                        absoluteCadenceDifference,
                        oneObservedClockTick
                    ) <= 0
            }
            guard isOnAccumulatedLattice
                    || isAdjacentClockQuantization else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(
                    site: .nominalCadenceOffLattice
                )
            }
        }
    }
}

private extension DeterministicV4MediaProcessingSession {
    func verifyAssembledPrimaryTimeline(
        at url: URL,
        expected: MediaTrackNodeV4
    ) async throws {
        let graph = try await AVFoundationTrackGraphAdapterV4.probe(
            asset: AVURLAsset(
                url: url,
                options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: true
                ]
            )
        )
        let videos = graph.tracks.filter { $0.kind == .video }
        guard videos.count == 1,
              videos[0].timeRange == expected.timeRange,
              videos[0].edits == expected.edits else {
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }
    }

    func verifyFinalPrimaryTimeline(
        graph: MediaTrackGraphV4,
        expected: MediaTrackNodeV4,
        stableID: MediaTrackStableIDV4
    ) throws {
        let matching = graph.tracks.filter {
            $0.identity.stableID == stableID
        }
        guard matching.count == 1,
              matching[0].timeRange == expected.timeRange,
              matching[0].edits == expected.edits else {
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }
    }

    func executeCanonicalDynamicAbsentOnePass(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedPlan: DeterministicV4PreparedAssetPlan,
        preparedBackend:
            any PreparedDeterministicV4RuntimePlanningBackend,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> AVFoundationTrackMigrationExecutionResultV4 {
        let hook = try preparedPlan.makeProcessingHook(
            backend: preparedBackend,
            finishBackendAtEnd: false,
            recordAlphaForFinalVerification: true
        )
        let migrationCancellation =
            AVFoundationTrackMigrationCancellationV4()
        let cancellationMonitor = Task {
            while !Task.isCancelled {
                do {
                    try cancellation.check()
                } catch {
                    migrationCancellation.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        defer { cancellationMonitor.cancel() }

        do {
            return try await executor.execute(
                .init(
                    sourceURL: request.inputURL,
                    destinationURL: request.outputURL,
                    outputFileType: .mov,
                    overwriteExistingFile: request.overwriteExistingFile,
                    sourceGraph: preparedPlan.sourceGraph,
                    identifiedPlan: preparedPlan.trackPlan,
                    blueprint: preparedPlan.migrationBlueprint,
                    videoProcessingHooks: [hook],
                    nonVideoTranscodeHooks:
                        preparedPlan.nonVideoTranscodeHooks
                ),
                cancellation: migrationCancellation,
                progress: { state in
                    progress(self.event(
                        phase: self.phase(for: state.stage),
                        source: source,
                        backendID: preparedBackend.actualBackendID,
                        frameCount: Int(clamping: state.migratedSampleCount)
                    ))
                }
            )
        } catch AVFoundationTrackMigrationExecutorV4Error.cancelled {
            throw MirmirError.cancelled
        }
    }

    func finalizeExecution(
        request: UpscaleRequest,
        source: VideoInfo,
        preparedBackend:
            any PreparedDeterministicV4RuntimePlanningBackend,
        preparedPlan: DeterministicV4PreparedAssetPlan,
        migration: AVFoundationTrackMigrationExecutionResultV4,
        hdr10PlusPreservation:
            DeterministicV4HDR10PlusPreservationReportV4,
        startedAt: Date,
        cancellation: ProcessingCancellation,
        progress: @escaping ProgressHandler
    ) async throws -> DeterministicV4MediaProcessingExecutionV4 {
        try cancellation.check()
        let alphaVerification = try await preparedPlan.verifyProcessedOutput(
            at: request.outputURL
        )
        progress(event(
            phase: .validatingOutput,
            source: source,
            backendID: preparedBackend.actualBackendID
        ))
        let facts = try await outputValidator.validate(
            url: request.outputURL,
            expectedWidth: request.targetWidth,
            expectedHeight: request.targetHeight,
            expectedAudioTopology: AudioTopologyV4(
                graph: preparedPlan.sourceGraph,
                preservingAudio: request.preserveAudio
            )
        )
        try cancellation.check()
        let primaryResult = migration.trackResults.first {
            $0.trackID == preparedPlan.primaryGraphTrack.identity.stableID
        }
        let frameCount = Int(clamping:
            primaryResult?.migratedSampleCount ?? 0
        )
        progress(event(
            phase: .completed,
            source: source,
            backendID: preparedBackend.actualBackendID,
            fraction: 1,
            frameCount: frameCount,
            processedTime: facts.duration
        ))
        let result = UpscaleResult(
            outputURL: request.outputURL,
            actualBackendID: preparedBackend.actualBackendID,
            encodedWidth: facts.encodedWidth,
            encodedHeight: facts.encodedHeight,
            durationSeconds: CMTimeGetSeconds(facts.duration),
            outputCodec: request.outputCodec,
            audioResult: audioResult(
                request: request,
                preparedPlan: preparedPlan
            ),
            processedFrameCount: frameCount,
            processingDurationSeconds: Date().timeIntervalSince(startedAt)
        )
        let receipt = try DeterministicV4MediaExecutionReceiptV4(
            request: request,
            preparedBackend: preparedBackend,
            preparedPlan: preparedPlan,
            migration: migration,
            result: result,
            alphaVerification: alphaVerification,
            hdr10PlusPreservation: hdr10PlusPreservation
        )
        let runtimeEvents = try DeterministicV4MediaRuntimeEventChainV4.make(
            receipt: receipt
        )
        return DeterministicV4MediaProcessingExecutionV4(
            result: result,
            receipt: receipt,
            runtimeEvents: runtimeEvents
        )
    }

    struct HDR10PlusScratchRecord: Codable, Equatable, Sendable {
        let presentationTime: HDR10PlusPresentationTimeV4
        let hdr10PlusSHA256: ASHSHA256V4?
    }

    struct HDR10PlusScratchDocument: Codable, Equatable, Sendable {
        static let currentSchemaID =
            "ash.hdr10plus-segment-scratch-ledger.v4.1"

        let schemaID: String
        let segmentOrdinal: Int
        let outputLedgerSHA256: ASHSHA256V4
        let records: [HDR10PlusScratchRecord]

        init(
            segmentOrdinal: Int,
            outputLedgerSHA256: ASHSHA256V4,
            records: [HDR10PlusScratchRecord]
        ) {
            schemaID = Self.currentSchemaID
            self.segmentOrdinal = segmentOrdinal
            self.outputLedgerSHA256 = outputLedgerSHA256
            self.records = records
        }
    }

    struct HDR10PlusScratchArtifact: Sendable {
        let url: URL
        let sha256: ASHSHA256V4
        let byteCount: Int
        let recordCount: Int
        let segmentOrdinal: Int
        let outputLedgerSHA256: ASHSHA256V4
    }

    struct DirectSegmentFact: Sendable {
        let startTime: WorkflowMediaTimeV4
        let endTimeExclusive: WorkflowMediaTimeV4
        let scratchLedger: HDR10PlusScratchArtifact
    }

    struct HDR10PlusSegmentPreflight {
        let sourceRecords: [HDR10PlusPresentationRecordV4]
        let decodedDurations: [DeterministicV4DecodedDurationRecordV4]
    }

    func makeDirectSegmentTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mirmir-v4-direct-segments-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try validateDirectSegmentTemporaryRoot(root)
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func sealHDR10PlusScratchLedger(
        _ snapshot: HDR10PlusSegmentLedgerSnapshotV4,
        segmentOrdinal: Int,
        trustedRoot: URL,
        maximumRecordCount: Int
    ) throws -> HDR10PlusScratchArtifact {
        guard segmentOrdinal >= 0,
              maximumRecordCount > 0,
              snapshot.records.count <= maximumRecordCount else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        try validateDirectSegmentTemporaryRoot(trustedRoot)
        let records = snapshot.records.map {
            HDR10PlusScratchRecord(
                presentationTime: $0.presentationTime,
                hdr10PlusSHA256: $0.metadata.map {
                    ASHSHA256V4(rawData: $0.ituTT35Payload)
                }
            )
        }
        let ledgerSHA256 = try ASHCanonicalJSONV4.hash(
            records,
            domain: "ash-hdr10plus-presentation-ledger-v4"
        )
        guard ledgerSHA256 == snapshot.canonicalSHA256 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        let document = HDR10PlusScratchDocument(
            segmentOrdinal: segmentOrdinal,
            outputLedgerSHA256: ledgerSHA256,
            records: records
        )
        let data = try ASHCanonicalJSONV4.encode(document)
        let maximumByteCount = try maximumHDR10PlusScratchByteCount(
            maximumRecordCount: maximumRecordCount
        )
        guard data.count <= maximumByteCount else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        let url = trustedRoot.appendingPathComponent(
            String(format: "hdr-ledger-%08d.json", segmentOrdinal),
            isDirectory: false
        )
        try writeOwnerOnlyScratchData(data, to: url)
        return HDR10PlusScratchArtifact(
            url: url,
            sha256: ASHSHA256V4(rawData: data),
            byteCount: data.count,
            recordCount: records.count,
            segmentOrdinal: segmentOrdinal,
            outputLedgerSHA256: ledgerSHA256
        )
    }

    func loadHDR10PlusScratchLedger(
        _ artifact: HDR10PlusScratchArtifact,
        trustedRoot: URL,
        maximumRecordCount: Int
    ) throws -> HDR10PlusScratchDocument {
        let maximumByteCount = try maximumHDR10PlusScratchByteCount(
            maximumRecordCount: maximumRecordCount
        )
        guard artifact.recordCount >= 0,
              artifact.recordCount <= maximumRecordCount,
              artifact.byteCount > 0,
              artifact.byteCount <= maximumByteCount else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        try validateDirectSegmentTemporaryRoot(trustedRoot)
        let root = trustedRoot.standardizedFileURL
            .resolvingSymlinksInPath()
        let parent = artifact.url.deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        guard parent == root else {
            throw DeterministicV4MediaSegmentError
                .scratchLedgerIO(artifact.url.path)
        }
        let data = try readOwnerOnlyScratchData(
            from: artifact.url,
            expectedByteCount: artifact.byteCount
        )
        guard ASHSHA256V4(rawData: data) == artifact.sha256 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        let document = try ASHCanonicalJSONV4.decode(
            HDR10PlusScratchDocument.self,
            from: data
        )
        guard document.schemaID
                == HDR10PlusScratchDocument.currentSchemaID,
              document.segmentOrdinal == artifact.segmentOrdinal,
              document.records.count == artifact.recordCount,
              document.records.count <= maximumRecordCount,
              Set(document.records.map(\.presentationTime)).count
                == document.records.count,
              document.records == document.records.sorted(by: {
                  $0.presentationTime < $1.presentationTime
              }),
              document.outputLedgerSHA256
                == artifact.outputLedgerSHA256,
              try ASHCanonicalJSONV4.hash(
                document.records,
                domain: "ash-hdr10plus-presentation-ledger-v4"
              ) == document.outputLedgerSHA256 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        return document
    }

    func writeOwnerOnlyScratchData(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerIO(url.path)
        }
        var complete = false
        defer {
            Darwin.close(descriptor)
            if !complete { try? FileManager.default.removeItem(at: url) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw DeterministicV4MediaSegmentError
                        .scratchLedgerIO(url.path)
                }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerIO(url.path)
        }
        var facts = stat()
        guard fstat(descriptor, &facts) == 0,
              (facts.st_mode & S_IFMT) == S_IFREG,
              facts.st_nlink == 1,
              facts.st_uid == getuid(),
              (facts.st_mode & 0o777) == 0o600,
              facts.st_size == off_t(data.count) else {
            throw DeterministicV4MediaSegmentError.scratchLedgerIO(url.path)
        }
        complete = true
    }

    func readOwnerOnlyScratchData(
        from url: URL,
        expectedByteCount: Int
    ) throws -> Data {
        guard expectedByteCount > 0 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerIO(url.path)
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerIO(url.path)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_uid == getuid(),
              (before.st_mode & 0o777) == 0o600,
              before.st_size == off_t(expectedByteCount) else {
            throw DeterministicV4MediaSegmentError.scratchLedgerIO(url.path)
        }
        var data = Data(count: expectedByteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw DeterministicV4MediaSegmentError
                        .scratchLedgerIO(url.path)
                }
                offset += count
            }
        }
        var after = stat()
        var lexical = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &lexical) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_dev == lexical.st_dev,
              before.st_ino == lexical.st_ino,
              before.st_mode == lexical.st_mode,
              before.st_nlink == lexical.st_nlink,
              before.st_size == lexical.st_size else {
            throw DeterministicV4MediaSegmentError.scratchLedgerIO(url.path)
        }
        return data
    }

    func maximumHDR10PlusScratchByteCount(
        maximumRecordCount: Int
    ) throws -> Int {
        guard maximumRecordCount > 0 else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        let records = maximumRecordCount.multipliedReportingOverflow(by: 256)
        guard !records.overflow else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        let total = records.partialValue.addingReportingOverflow(2_048)
        guard !total.overflow else {
            throw DeterministicV4MediaSegmentError.scratchLedgerMismatch
        }
        return total.partialValue
    }

    func validateDirectSegmentTemporaryRoot(_ root: URL) throws {
        var facts = stat()
        guard root.isFileURL,
              lstat(root.path, &facts) == 0,
              (facts.st_mode & S_IFMT) == S_IFDIR,
              facts.st_uid == getuid(),
              (facts.st_mode & 0o777) == 0o700 else {
            throw DeterministicV4MediaSegmentError
                .unsafeTemporaryRoot(root.path)
        }
    }

    func verifyHDR10PlusScratchLedgers(
        at url: URL,
        videoTrackOrdinal: Int,
        segments: [DirectSegmentFact],
        mediaTimelineStart: WorkflowMediaTimeV4,
        outputTimelineStart: WorkflowMediaTimeV4,
        trustedRoot: URL,
        maximumRecordCount: Int,
        cancellation: ProcessingCancellation
    ) async throws {
        guard let first = segments.first else {
            throw DeterministicV4MediaSegmentError.emptySegment
        }
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.load(.tracks)
        guard tracks.indices.contains(videoTrackOrdinal),
              tracks[videoTrackOrdinal].mediaType == .video else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        let track = tracks[videoTrackOrdinal]
        let origin = CMTime(
            value: first.startTime.value,
            timescale: first.startTime.timescale
        )
        let mediaStart = cmTime(mediaTimelineStart)
        let outputStart = cmTime(outputTimelineStart)
        guard mediaStart.isNumeric,
              outputStart.isNumeric,
              mediaStart.epoch == 0,
              outputStart.epoch == 0,
              !mediaStart.flags.contains(.hasBeenRounded),
              !outputStart.flags.contains(.hasBeenRounded),
              mediaTimelineStart.timescale == outputTimelineStart.timescale,
              CMTimeCompare(mediaStart, .zero) >= 0,
              CMTimeCompare(outputStart, .zero) >= 0,
              CMTimeCompare(mediaStart, origin) == 0 else {
            throw DeterministicV4MediaSegmentError
                .incompleteSegmentSequence
        }
        var priorEnd: CMTime?
        for (ordinal, segment) in segments.enumerated() {
            try cancellation.check()
            guard segment.scratchLedger.segmentOrdinal == ordinal else {
                throw DeterministicV4MediaSegmentError
                    .scratchLedgerMismatch
            }
            let globalStart = CMTime(
                value: segment.startTime.value,
                timescale: segment.startTime.timescale
            )
            let globalEnd = CMTime(
                value: segment.endTimeExclusive.value,
                timescale: segment.endTimeExclusive.timescale
            )
            guard globalStart.isNumeric,
                  globalEnd.isNumeric,
                  CMTimeCompare(globalEnd, globalStart) > 0,
                  priorEnd.map({
                      CMTimeCompare($0, globalStart) <= 0
                  }) ?? true else {
                throw DeterministicV4MediaSegmentError
                    .incompleteSegmentSequence
            }
            priorEnd = globalEnd
            let offset = CMTimeSubtract(globalStart, mediaStart)
            let duration = CMTimeSubtract(globalEnd, globalStart)
            let readerStart = CMTimeAdd(outputStart, offset)
            let readerEnd = CMTimeAdd(readerStart, duration)
            guard offset.isNumeric,
                  duration.isNumeric,
                  readerStart.isNumeric,
                  readerEnd.isNumeric,
                  offset.epoch == 0,
                  duration.epoch == 0,
                  readerStart.epoch == 0,
                  readerEnd.epoch == 0,
                  CMTimeCompare(offset, .zero) >= 0,
                  duration.value > 0,
                  !offset.flags.contains(.hasBeenRounded),
                  !duration.flags.contains(.hasBeenRounded),
                  !readerStart.flags.contains(.hasBeenRounded),
                  !readerEnd.flags.contains(.hasBeenRounded),
                  CMTimeCompare(readerStart, outputStart) >= 0,
                  CMTimeCompare(readerEnd, readerStart) > 0 else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .scratchLedgerInvalidAssembledRange)
            }
            let document = try loadHDR10PlusScratchLedger(
                segment.scratchLedger,
                trustedRoot: trustedRoot,
                maximumRecordCount: maximumRecordCount
            )
            var expected: [
                HDR10PlusPresentationTimeV4: ASHSHA256V4?
            ] = [:]
            expected.reserveCapacity(document.records.count)
            for record in document.records {
                let local = record.presentationTime.cmTime
                let shifted: HDR10PlusPresentationTimeV4
                do {
                    shifted = try HDR10PlusPresentationTimeV4(
                        Self.assembledScratchPresentationTime(
                            localPresentationTime: local,
                            segmentMediaStart: globalStart,
                            segmentDuration: duration
                        )
                    )
                } catch {
                    throw DeterministicV4MediaSegmentError
                        .scratchLedgerMismatch
                }
                guard expected.updateValue(
                    record.hdr10PlusSHA256,
                    forKey: shifted
                ) == nil else {
                    throw DeterministicV4MediaSegmentError
                        .scratchLedgerMismatch
                }
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw DeterministicV4MediaSegmentError.readerRejectedTrack
            }
            reader.add(output)
            reader.timeRange = CMTimeRange(
                start: readerStart,
                duration: duration
            )
            guard reader.startReading() else {
                throw DeterministicV4MediaSegmentError.readerStartFailed
            }
            do {
                while let sample = output.copyNextSampleBuffer() {
                    try cancellation.check()
                    let sampleCount = CMSampleBufferGetNumSamples(sample)
                    if sampleCount == 0 { continue }
                    guard sampleCount == 1 else {
                        throw HDRMetadataV4Error.contradictoryMetadata(
                            "encoded whole-asset sample aggregation is unsupported"
                        )
                    }
                    let presentation = try HDR10PlusPresentationTimeV4(
                        CMSampleBufferGetPresentationTimeStamp(sample)
                    )
                    guard let retained = expected.removeValue(
                        forKey: presentation
                    ) else {
                        throw HDRMetadataV4Error.contradictoryMetadata(
                            "encoded whole-asset presentation time is extra or duplicated"
                        )
                    }
                    let actual = try AVFoundationHDRMetadataAdapterV4
                        .compressedHDR10PlusMetadata(from: sample).map {
                            ASHSHA256V4(rawData: $0.ituTT35Payload)
                        }
                    guard actual == retained else {
                        throw DeterministicV4MediaSegmentError
                            .dynamicHDRMetadataMismatch
                    }
                }
                guard reader.status == .completed, expected.isEmpty else {
                    throw DeterministicV4MediaSegmentError.readerFailed
                }
            } catch {
                reader.cancelReading()
                throw error
            }
        }
    }

    func finishPreparedBackends(
        plan: DeterministicV4PreparedAssetPlan,
        planningBackend:
            any PreparedDeterministicV4RuntimePlanningBackend
    ) async throws {
        var firstError: Error?
        if case .alpha(let delivery) = plan.videoDelivery {
            do {
                try await delivery.backend.finish()
            } catch {
                firstError = error
            }
        }
        do {
            try await planningBackend.finish()
        } catch {
            if firstError == nil { firstError = error }
        }
        if let firstError { throw firstError }
    }

    func makeHDR10PlusSegmentPreflight(
        asset: AVURLAsset,
        track: AVAssetTrack,
        decodedOutputSettings: [String: Any],
        canonicalDynamicHDRIsAbsent: Bool,
        nominalSourceFrameDuration: ExactRationalV4,
        startTime: WorkflowMediaTimeV4?,
        maximumInputFrames: Int,
        timelineMapping: DeterministicV4PrimaryTimelineMappingV4?,
        cancellation: ProcessingCancellation
    ) async throws -> HDR10PlusSegmentPreflight {
        let decodedReader = try AVAssetReader(asset: asset)
        var decodedSettings = decodedOutputSettings
        decodedSettings[AVVideoDecompressionPropertiesKey] = [
            kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata
                as String: true
        ]
        let decodedOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: decodedSettings
        )
        decodedOutput.alwaysCopiesSampleData = false
        guard decodedReader.canAdd(decodedOutput) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        decodedReader.add(decodedOutput)
        if let timelineMapping {
            decodedReader.timeRange = try directDecodedReaderTimeRange(
                startTime: startTime,
                timelineMapping: timelineMapping
            )
        } else if let startTime {
            let start = CMTime(
                value: startTime.value,
                timescale: startTime.timescale
            )
            let duration = try await asset.load(.duration)
            let remaining = CMTimeSubtract(duration, start)
            guard remaining.isNumeric, remaining.value > 0 else {
                throw DeterministicV4MediaSegmentError.nonContiguousBoundary
            }
            decodedReader.timeRange = CMTimeRange(
                start: start,
                duration: remaining
            )
        }
        guard decodedReader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        defer {
            if decodedReader.status == .reading {
                decodedReader.cancelReading()
            }
        }
        var decodedTimes: [HDR10PlusPresentationTimeV4] = []
        var decodedTimeSet = Set<HDR10PlusPresentationTimeV4>()
        var decodedCadenceTimes: [CMTime] = []
        var decodedCadenceDurations: [CMTime] = []
        var firstSelectionPresentationTime: CMTime?
        while decodedTimes.count < maximumInputFrames,
              let decodedSample = decodedOutput.copyNextSampleBuffer() {
            try cancellation.check()
            let sampleCount = CMSampleBufferGetNumSamples(decodedSample)
            if sampleCount == 0 { continue }
            guard sampleCount == 1 else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedPreflightAggregationFailed)
            }
            let selectionPresentation = CMSampleBufferGetPresentationTimeStamp(
                decodedSample
            )
            guard selectionPresentation.isNumeric else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedPreflightInvalidPresentationTime)
            }
            let presentation: CMTime
            if timelineMapping != nil {
                presentation = try canonicalDecodedPresentationTime(
                    decodedSample,
                    timelineMapping: timelineMapping
                )
            } else {
                guard canonicalDynamicHDRIsAbsent else {
                    throw DeterministicV4MediaSegmentError
                        .dynamicHDRMetadataMismatch
                }
                guard try AVFoundationHDRMetadataAdapterV4
                    .probeDynamicMetadata(from: decodedSample) == nil else {
                    throw DeterministicV4MediaSegmentError
                        .dynamicHDRMetadataMismatch
                }
                presentation = selectionPresentation
                decodedCadenceTimes.append(presentation)
                decodedCadenceDurations.append(
                    CMSampleBufferGetDuration(decodedSample)
                )
            }
            if decodedTimes.isEmpty, let startTime {
                let expected = CMTime(
                    value: startTime.value,
                    timescale: startTime.timescale
                )
                guard CMTimeCompare(presentation, expected) == 0 else {
                    throw DeterministicV4MediaSegmentError
                        .nonContiguousBoundary
                }
            }
            let key = try HDR10PlusPresentationTimeV4(presentation)
            guard decodedTimeSet.insert(key).inserted else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "decoded source presentation time is duplicated"
                )
            }
            decodedTimes.append(key)
            if firstSelectionPresentationTime == nil {
                firstSelectionPresentationTime = selectionPresentation
            }
        }
        if timelineMapping == nil,
           decodedTimes.count == maximumInputFrames {
            while let lookaheadSample = decodedOutput.copyNextSampleBuffer() {
                try cancellation.check()
                let sampleCount = CMSampleBufferGetNumSamples(lookaheadSample)
                if sampleCount == 0 { continue }
                guard sampleCount == 1 else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedLookaheadPreflightAggregationFailed)
                }
                let presentation = CMSampleBufferGetPresentationTimeStamp(
                    lookaheadSample
                )
                guard presentation.isNumeric else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .decodedLookaheadInvalidPresentationTime)
                }
                guard try AVFoundationHDRMetadataAdapterV4
                    .probeDynamicMetadata(from: lookaheadSample) == nil else {
                    throw DeterministicV4MediaSegmentError
                        .dynamicHDRMetadataMismatch
                }
                decodedCadenceTimes.append(presentation)
                decodedCadenceDurations.append(
                    CMSampleBufferGetDuration(lookaheadSample)
                )
                break
            }
        }
        let decodedReaderExhausted = decodedReader.status == .completed
        guard decodedReader.status != .failed,
              decodedReader.status != .cancelled else {
            throw DeterministicV4MediaSegmentError.readerFailed
        }
        decodedReader.cancelReading()
        guard !decodedTimes.isEmpty,
              let firstSelectionPresentationTime else {
            throw DeterministicV4MediaSegmentError.emptySegment
        }
        if timelineMapping == nil {
            // The immutable prepared plan already proved that the canonical
            // source has no dynamic HDR metadata. Keep the preflight in the
            // decoded target-time domain; a passthrough reader can expose a
            // different media-time domain for sources with edit lists. The
            // decoded PTS cadence and decoded duration fields are authoritative;
            // a container track time range can be coarsely rounded.
            try Self.validateNominalDecodedCadence(
                presentationTimes: decodedCadenceTimes,
                decodedDurations: decodedCadenceDurations,
                nominalSourceFrameDuration: nominalSourceFrameDuration
            )
            try cancellation.check()
            return HDR10PlusSegmentPreflight(
                sourceRecords: decodedTimes.map {
                    HDR10PlusPresentationRecordV4(
                        presentationTime: $0,
                        metadata: nil
                    )
                },
                decodedDurations: []
            )
        }

        let compressedReader = try AVAssetReader(asset: asset)
        let compressedOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        compressedOutput.alwaysCopiesSampleData = false
        guard compressedReader.canAdd(compressedOutput) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        compressedReader.add(compressedOutput)
        if let timelineMapping {
            let exactRange = try directDecodedReaderTimeRange(
                startTime: startTime,
                timelineMapping: timelineMapping
            )
            guard CMTimeCompare(
                exactRange.start,
                firstSelectionPresentationTime
            ) == 0 else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .compressedRangeStartMismatch)
            }
            compressedReader.timeRange = exactRange
        }
        guard compressedReader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        defer {
            if compressedReader.status == .reading {
                compressedReader.cancelReading()
            }
        }
        var compressed: [
            HDR10PlusPresentationTimeV4: HDR10PlusMetadataV4?
        ] = [:]
        var decodedDurations: [
            DeterministicV4DecodedDurationRecordV4
        ] = []
        var compressedTiming: [
            DeterministicV4CompressedTimingRecordV4
        ] = []
        let maximumCompressedRecordCount = try Self
            .maximumCompressedPreflightRecordCount(
                maximumInputFrames: maximumInputFrames
            )
        var compressedSelector = try
            DeterministicV4CompressedPrefixSelectorV4(
                selectedPresentationTimes: decodedTimeSet,
                maximumScannedRecordCount: maximumCompressedRecordCount
            )
        while !compressedSelector.isComplete,
              compressedSelector.hasRemainingCapacity,
              let sample = compressedOutput.copyNextSampleBuffer() {
            try cancellation.check()
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { continue }
            guard sampleCount == 1 else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed source sample aggregation is unsupported"
                )
            }
            let key = try HDR10PlusPresentationTimeV4(
                CMSampleBufferGetPresentationTimeStamp(sample)
            )
            let isSelected = try compressedSelector.admit(key)
            if timelineMapping != nil {
                let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
                let readerReportedDuration = CMSampleBufferGetDuration(sample)
                guard decodeTime.isNumeric,
                      decodeTime.epoch == key.epoch,
                      !decodeTime.flags.contains(.hasBeenRounded)
                else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .compressedRecordInvalidDecodeTime)
                }
                compressedTiming.append(
                    DeterministicV4CompressedTimingRecordV4(
                        presentationTime: key,
                        decodeTime: decodeTime,
                        readerReportedDuration: readerReportedDuration
                    )
                )
            }
            guard isSelected else {
                // Decode-order samples outside the selected presentation
                // prefix establish cadence only. They never enter the
                // segment HDR ledger.
                continue
            }
            let dynamic = try AVFoundationHDRMetadataAdapterV4
                .probeDynamicMetadata(from: sample)
            guard dynamic?.postDecodeProcessing == nil else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "post-decode metadata has no HEVC/MOV preservation contract"
                )
            }
            guard compressed.updateValue(
                dynamic?.hdr10Plus,
                forKey: key
            ) == nil else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed source presentation time is duplicated"
                )
            }
        }
        guard compressedSelector.isComplete else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed source presentation prefix is incomplete"
            )
        }
        var lookaheadDecodeTime: CMTime?
        if timelineMapping != nil,
           !decodedReaderExhausted {
            while let sample = compressedOutput.copyNextSampleBuffer() {
                try cancellation.check()
                let sampleCount = CMSampleBufferGetNumSamples(sample)
                if sampleCount == 0 { continue }
                guard sampleCount == 1 else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "compressed source sample aggregation is unsupported"
                    )
                }
                let key = try HDR10PlusPresentationTimeV4(
                    CMSampleBufferGetPresentationTimeStamp(sample)
                )
                guard !compressedSelector.hasSeen(key),
                      !decodedTimeSet.contains(key) else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "compressed source presentation time is duplicated"
                    )
                }
                let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
                guard decodeTime.isNumeric,
                      decodeTime.epoch == key.epoch,
                      !decodeTime.flags.contains(.hasBeenRounded) else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .compressedLookaheadInvalidDecodeTime)
                }
                lookaheadDecodeTime = decodeTime
                break
            }
        }
        if timelineMapping == nil || decodedReaderExhausted {
            var drainedBufferCount = 0
            while let sample = compressedOutput.copyNextSampleBuffer() {
                try cancellation.check()
                guard drainedBufferCount < maximumCompressedRecordCount else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "compressed source tail exceeds its scan bound"
                    )
                }
                drainedBufferCount += 1
                let sampleCount = CMSampleBufferGetNumSamples(sample)
                if sampleCount == 0 { continue }
                guard sampleCount == 1 else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "compressed source sample aggregation is unsupported"
                    )
                }
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed source has an extra presentation time"
                )
            }
            guard compressedReader.status == .completed else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
        } else {
            guard compressedReader.status != .failed,
                  compressedReader.status != .cancelled else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            compressedReader.cancelReading()
        }
        if let timelineMapping {
            guard compressedTiming.count
                    == compressedSelector.scannedRecordCount,
                  compressedTiming.count <= maximumCompressedRecordCount else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "compressed and decoded source timing domains differ"
                )
            }
            let offset = cmTime(try workflowTime(timelineMapping.offset))
            let admittedMediaEnd = cmTime(try workflowTime(
                timelineMapping.mediaEnd
            ))
            let admittedTargetEnd = cmTime(try workflowTime(
                timelineMapping.targetEnd
            ))
            decodedDurations = try Self.authoritativeDecodedDurationRecords(
                compressed: compressedTiming,
                selectedPresentationTimes: decodedTimeSet,
                followingDecodeTime: lookaheadDecodeTime,
                readerIsExhausted: compressedReader.status == .completed,
                maximumRecordCount: maximumCompressedRecordCount
            )
            for record in decodedDurations {
                let duration = record.duration
                let mediaPresentation = record.presentationTime.cmTime
                let mediaEnd = CMTimeAdd(mediaPresentation, duration)
                let targetPresentation = CMTimeAdd(
                    mediaPresentation,
                    offset
                )
                let targetEnd = CMTimeAdd(targetPresentation, duration)
                guard duration.isNumeric,
                      duration.value > 0,
                      !duration.flags.contains(.hasBeenRounded),
                      mediaEnd.isNumeric,
                      targetPresentation.isNumeric,
                      targetEnd.isNumeric,
                      !mediaEnd.flags.contains(.hasBeenRounded),
                      !targetPresentation.flags.contains(.hasBeenRounded),
                      !targetEnd.flags.contains(.hasBeenRounded),
                      CMTimeCompare(mediaEnd, admittedMediaEnd) <= 0,
                      CMTimeCompare(targetEnd, admittedTargetEnd) <= 0 else {
                    throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .compressedRecordOutsideAdmittedRange)
                }
            }
        }
        try cancellation.check()
        guard Set(compressed.keys) == decodedTimeSet,
              timelineMapping == nil
                || decodedDurations.map(\.presentationTime) == decodedTimes,
              timelineMapping == nil
                || decodedDurations.count == decodedTimes.count else {
            throw HDRMetadataV4Error.contradictoryMetadata(
                "compressed and decoded source presentation domains differ"
            )
        }
        return HDR10PlusSegmentPreflight(
            sourceRecords: try decodedTimes.map { key in
                guard let retained = compressed.removeValue(forKey: key) else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "compressed source presentation record is missing"
                    )
                }
                return HDR10PlusPresentationRecordV4(
                    presentationTime: key,
                    metadata: retained
                )
            },
            decodedDurations: decodedDurations
        )
    }

    func rewriteSegmentHDR10Plus(
        at url: URL,
        expected: HDR10PlusSegmentLedgerSnapshotV4,
        cancellation: ProcessingCancellation
    ) async throws -> Int {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        let formats = try await track.load(.formatDescriptions)
        guard formats.count == 1, let format = formats.first else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        let isHEVC = CMFormatDescriptionGetMediaSubType(format)
            == kCMVideoCodecType_HEVC
        let needed = try await verifyEncodedHDR10PlusDomain(
            asset: asset,
            track: track,
            expected: expected,
            requireInBand: false,
            cancellation: cancellation
        )
        if !isHEVC {
            guard needed == 0,
                  expected.records.allSatisfy({ $0.metadata == nil }) else {
                throw DeterministicV4MediaSegmentError
                    .dynamicHDRMetadataMismatch
            }
            return 0
        }
        guard needed > 0 else { return 0 }

        let destination = try AtomicOutputFile(
            finalURL: url,
            overwriteExistingFile: true
        )
        defer { destination.discard() }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        readerOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(readerOutput) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        reader.add(readerOutput)
        let writer = try AVAssetWriter(
            outputURL: destination.temporaryURL,
            fileType: .mov
        )
        writer.metadata = try await asset.load(.commonMetadata)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: format
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.metadata = try await track.load(.metadata)
        writerInput.languageCode = try await track.load(.languageCode)
        writerInput.extendedLanguageTag = try await track
            .load(.extendedLanguageTag)
        writerInput.transform = try await track.load(.preferredTransform)
        writerInput.naturalSize = try await track.load(.naturalSize)
        guard writer.canAdd(writerInput) else {
            throw DeterministicV4MediaSegmentError.writerRejectedTrack
        }
        writer.add(writerInput)
        guard reader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw DeterministicV4MediaSegmentError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)
        var remaining = Dictionary(
            uniqueKeysWithValues: expected.records.map {
                ($0.presentationTime, $0.metadata)
            }
        )
        var rewrittenSampleCount = 0
        do {
            while let sample = readerOutput.copyNextSampleBuffer() {
                try cancellation.check()
                let sampleCount = CMSampleBufferGetNumSamples(sample)
                if sampleCount == 0 { continue }
                guard sampleCount == 1 else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "encoded segment sample aggregation is unsupported"
                    )
                }
                let key = try HDR10PlusPresentationTimeV4(
                    CMSampleBufferGetPresentationTimeStamp(sample)
                )
                guard let retained = remaining.removeValue(forKey: key) else {
                    throw HDRMetadataV4Error.contradictoryMetadata(
                        "encoded segment presentation time is extra or duplicated"
                    )
                }
                let outputSample: CMSampleBuffer
                if let retained {
                    let inserted = try AVFoundationHDRMetadataAdapterV4
                        .insertingHDR10PlusMetadata(retained, into: sample)
                    outputSample = inserted.sampleBuffer
                    if inserted.rewritten { rewrittenSampleCount += 1 }
                } else {
                    guard try AVFoundationHDRMetadataAdapterV4
                        .compressedHDR10PlusMetadata(from: sample) == nil else {
                        throw DeterministicV4MediaSegmentError
                            .dynamicHDRMetadataMismatch
                    }
                    outputSample = sample
                }
                try await waitUntilReady(
                    writerInput,
                    reader: reader,
                    writer: writer,
                    cancellation: cancellation
                )
                guard writerInput.append(outputSample) else {
                    throw DeterministicV4MediaSegmentError.appendFailed
                }
            }
            guard reader.status == .completed, remaining.isEmpty else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            writerInput.markAsFinished()
            await finishWriting(writer)
            guard writer.status == .completed else {
                throw DeterministicV4MediaSegmentError.writerFailed
            }
            let rewrittenAsset = AVURLAsset(url: destination.temporaryURL)
            let rewrittenTracks = try await rewrittenAsset.loadTracks(
                withMediaType: .video
            )
            guard rewrittenTracks.count == 1,
                  let rewrittenTrack = rewrittenTracks.first,
                  try await verifyEncodedHDR10PlusDomain(
                    asset: rewrittenAsset,
                    track: rewrittenTrack,
                    expected: expected,
                    requireInBand: true,
                    cancellation: cancellation
                  ) == 0 else {
                throw DeterministicV4MediaSegmentError
                    .dynamicHDRMetadataMismatch
            }
            try destination.publish()
            return rewrittenSampleCount
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    func verifyEncodedHDR10PlusDomain(
        asset: AVAsset,
        track: AVAssetTrack,
        expected: HDR10PlusSegmentLedgerSnapshotV4,
        requireInBand: Bool,
        cancellation: ProcessingCancellation
    ) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        reader.add(output)
        guard reader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        var remaining = Dictionary(
            uniqueKeysWithValues: expected.records.map {
                ($0.presentationTime, $0.metadata)
            }
        )
        var missingInBandCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try cancellation.check()
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            if sampleCount == 0 { continue }
            guard sampleCount == 1 else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded segment sample aggregation is unsupported"
                )
            }
            let key = try HDR10PlusPresentationTimeV4(
                CMSampleBufferGetPresentationTimeStamp(sample)
            )
            guard let retained = remaining.removeValue(forKey: key) else {
                throw HDRMetadataV4Error.contradictoryMetadata(
                    "encoded segment presentation time is extra or duplicated"
                )
            }
            let raw = try AVFoundationHDRMetadataAdapterV4
                .compressedHDR10PlusMetadata(from: sample)
            if let retained {
                if raw == nil, !requireInBand {
                    missingInBandCount += 1
                } else if raw != retained {
                    throw DeterministicV4MediaSegmentError
                        .dynamicHDRMetadataMismatch
                }
            } else if raw != nil {
                throw DeterministicV4MediaSegmentError
                    .dynamicHDRMetadataMismatch
            }
        }
        guard reader.status == .completed, remaining.isEmpty else {
            throw DeterministicV4MediaSegmentError.readerFailed
        }
        try cancellation.check()
        return missingInBandCount
    }

    func retime(
        _ sample: CMSampleBuffer,
        subtracting origin: CMTime?,
        authoritativeDuration: CMTime? = nil
    ) throws -> CMSampleBuffer {
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .retimeEmptySampleBuffer)
        }
        var timing = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(),
            count: count
        )
        var needed = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: timing.count,
            arrayToFill: &timing,
            entriesNeededOut: &needed
        )
        guard status == noErr, needed == count else {
            throw DeterministicV4MediaSegmentError.retimingFailed(status)
        }
        for index in timing.indices {
            if let authoritativeDuration {
                timing[index].duration = authoritativeDuration
            }
            if let origin,
               timing[index].presentationTimeStamp.isNumeric {
                timing[index].presentationTimeStamp = CMTimeSubtract(
                    timing[index].presentationTimeStamp,
                    origin
                )
            }
            if let origin,
               timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeSubtract(
                    timing[index].decodeTimeStamp,
                    origin
                )
            }
        }
        var copy: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard status == noErr, let copy else {
            throw DeterministicV4MediaSegmentError.retimingFailed(status)
        }
        return copy
    }

    func waitUntilReady(
        _ input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        cancellation: ProcessingCancellation
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try cancellation.check()
            guard reader.status != .failed,
                  reader.status != .cancelled else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            guard writer.status != .failed,
                  writer.status != .cancelled else {
                throw DeterministicV4MediaSegmentError.writerFailed
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
    }

    func directDecodedReaderTimeRange(
        startTime: WorkflowMediaTimeV4?,
        timelineMapping: DeterministicV4PrimaryTimelineMappingV4
    ) throws -> CMTimeRange {
        let admittedMediaStart = cmTime(try workflowTime(
            timelineMapping.mediaRange.start
        ))
        let admittedMediaEnd = cmTime(try workflowTime(
            timelineMapping.mediaEnd
        ))
        let requestedMediaStart = startTime.map { cmTime($0) }
            ?? admittedMediaStart
        let offset = cmTime(try workflowTime(timelineMapping.offset))
        let admittedTargetStart = cmTime(try workflowTime(
            timelineMapping.targetRange.start
        ))
        let admittedTargetEnd = cmTime(try workflowTime(
            timelineMapping.targetEnd
        ))
        let requestedTargetStart = CMTimeAdd(requestedMediaStart, offset)
        let duration = CMTimeSubtract(
            admittedTargetEnd,
            requestedTargetStart
        )
        guard requestedMediaStart.isNumeric,
              requestedTargetStart.isNumeric,
              duration.isNumeric,
              duration.value > 0,
              !requestedTargetStart.flags.contains(.hasBeenRounded),
              !duration.flags.contains(.hasBeenRounded),
              CMTimeCompare(requestedMediaStart, admittedMediaStart) >= 0,
              CMTimeCompare(requestedMediaStart, admittedMediaEnd) < 0,
              CMTimeCompare(requestedTargetStart, admittedTargetStart) >= 0,
              CMTimeCompare(requestedTargetStart, admittedTargetEnd) < 0,
              CMTimeCompare(
                CMTimeSubtract(requestedTargetStart, offset),
                requestedMediaStart
              ) == 0 else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .directReaderRangeInvalid)
        }
        return CMTimeRange(start: requestedTargetStart, duration: duration)
    }

    func canonicalizedDecodedSample(
        _ sample: CMSampleBuffer,
        timelineMapping: DeterministicV4PrimaryTimelineMappingV4?,
        authoritativeDuration: CMTime? = nil
    ) throws -> CMSampleBuffer {
        guard let timelineMapping else { return sample }
        let mediaPresentation = try canonicalDecodedPresentationTime(
            sample,
            timelineMapping: timelineMapping
        )
        let targetPresentation = CMSampleBufferGetPresentationTimeStamp(
            sample
        )
        let offset = cmTime(try workflowTime(timelineMapping.offset))
        if let authoritativeDuration {
            let targetEnd = CMTimeAdd(
                targetPresentation,
                authoritativeDuration
            )
            let mediaEnd = CMTimeAdd(
                mediaPresentation,
                authoritativeDuration
            )
            let admittedTargetEnd = cmTime(try workflowTime(
                timelineMapping.targetEnd
            ))
            let admittedMediaEnd = cmTime(try workflowTime(
                timelineMapping.mediaEnd
            ))
            guard authoritativeDuration.isNumeric,
                  authoritativeDuration.value > 0,
                  !authoritativeDuration.flags.contains(.hasBeenRounded),
                  targetEnd.isNumeric,
                  mediaEnd.isNumeric,
                  !targetEnd.flags.contains(.hasBeenRounded),
                  !mediaEnd.flags.contains(.hasBeenRounded),
                  CMTimeCompare(targetEnd, admittedTargetEnd) <= 0,
                  CMTimeCompare(mediaEnd, admittedMediaEnd) <= 0 else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .canonicalizedSampleInvalidTiming)
            }
        }
        return try retime(
            sample,
            subtracting: offset,
            authoritativeDuration: authoritativeDuration
        )
    }

    func canonicalizedNominalDecodedSample(
        _ sample: CMSampleBuffer,
        nominalDuration: CMTime
    ) throws -> CMSampleBuffer {
        let authoritativeDuration = try Self
            .canonicalNominalDecodedDuration(
                observedDuration: CMSampleBufferGetDuration(sample),
                nominalDuration: nominalDuration
            )
        return try retime(
            sample,
            subtracting: nil,
            authoritativeDuration: authoritativeDuration
        )
    }

    func canonicalDecodedPresentationTime(
        _ sample: CMSampleBuffer,
        timelineMapping: DeterministicV4PrimaryTimelineMappingV4?
    ) throws -> CMTime {
        let targetPresentation = CMSampleBufferGetPresentationTimeStamp(
            sample
        )
        guard let timelineMapping else {
            guard targetPresentation.isNumeric else {
                throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .unmappedDecodedPresentationTime)
            }
            return targetPresentation
        }
        let admittedTargetStart = cmTime(try workflowTime(
            timelineMapping.targetRange.start
        ))
        let admittedTargetEnd = cmTime(try workflowTime(
            timelineMapping.targetEnd
        ))
        let offset = cmTime(try workflowTime(timelineMapping.offset))
        let mediaPresentation = CMTimeSubtract(targetPresentation, offset)
        let admittedMediaStart = cmTime(try workflowTime(
            timelineMapping.mediaRange.start
        ))
        let admittedMediaEnd = cmTime(try workflowTime(
            timelineMapping.mediaEnd
        ))
        guard targetPresentation.isNumeric,
              mediaPresentation.isNumeric,
              !mediaPresentation.flags.contains(.hasBeenRounded),
              CMTimeCompare(targetPresentation, admittedTargetStart) >= 0,
              CMTimeCompare(targetPresentation, admittedTargetEnd) < 0,
              CMTimeCompare(mediaPresentation, admittedMediaStart) >= 0,
              CMTimeCompare(mediaPresentation, admittedMediaEnd) < 0,
              CMTimeCompare(
                CMTimeAdd(mediaPresentation, offset),
                targetPresentation
              ) == 0 else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .mappedSampleInvalidTiming)
        }
        return mediaPresentation
    }

    func workflowTime(
        _ time: CMTime,
        timescale: Int32
    ) throws -> WorkflowMediaTimeV4 {
        guard time.isNumeric else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .cmTimeNotNumeric)
        }
        let converted = CMTimeConvertScale(
            time,
            timescale: timescale,
            method: .default
        )
        guard CMTimeCompare(time, converted) == 0 else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .cmTimeNotExactlyRepresentable)
        }
        return try WorkflowMediaTimeV4(
            value: converted.value,
            timescale: converted.timescale
        )
    }

    func workflowTime(
        _ time: ExactRationalV4
    ) throws -> WorkflowMediaTimeV4 {
        guard time.denominator <= Int64(Int32.max),
              let timescale = Int32(exactly: time.denominator) else {
            throw DeterministicV4MediaSegmentError.invalidSampleTiming(site: .rationalDenominatorNotRepresentable)
        }
        return try WorkflowMediaTimeV4(
            value: time.numerator,
            timescale: timescale
        )
    }

    func cmTime(_ time: WorkflowMediaTimeV4) -> CMTime {
        CMTime(value: time.value, timescale: time.timescale)
    }

    func verifySegment(
        at url: URL,
        plan: DeterministicV4PreparedAssetPlan,
        expectedDynamicHDR: DynamicHDRMetadataStreamAccumulatorV4,
        alphaVerifier: AVFoundationAlphaVideoOutputVerifierV4?,
        cancellation: ProcessingCancellation
    ) async throws {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else {
            throw DeterministicV4MediaSegmentError.primaryTrackMissing
        }
        switch plan.videoDelivery {
        case .opaque(let contract):
            try contract.verifyReopenedFormat(
                format,
                preferredTransform: try await track.load(.preferredTransform)
            )
            let decodedReader = try AVAssetReader(asset: asset)
            let decodedOutput = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: contract.sourcePixelBufferAttributes
            )
            guard decodedReader.canAdd(decodedOutput) else {
                throw DeterministicV4MediaSegmentError.readerRejectedTrack
            }
            decodedReader.add(decodedOutput)
            guard decodedReader.startReading() else {
                throw DeterministicV4MediaSegmentError.readerStartFailed
            }
            while let sample = decodedOutput.copyNextSampleBuffer() {
                try cancellation.check()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw DeterministicV4MediaSegmentError.readerFailed
                }
                try contract.verifyDecodedPixelBuffer(pixelBuffer)
            }
            guard decodedReader.status == .completed else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
        case .alpha(let delivery):
            guard let alphaVerifier else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
            let report = try await alphaVerifier.verify(
                outputURL: url,
                videoTrackOrdinal: 0
            )
            guard report.encodedFormat == delivery.encodedFormatDescriptor else {
                throw DeterministicV4MediaSegmentError.readerFailed
            }
        }

        let encodedReader = try AVAssetReader(asset: asset)
        let encodedOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: nil
        )
        encodedOutput.alwaysCopiesSampleData = false
        guard encodedReader.canAdd(encodedOutput) else {
            throw DeterministicV4MediaSegmentError.readerRejectedTrack
        }
        encodedReader.add(encodedOutput)
        guard encodedReader.startReading() else {
            throw DeterministicV4MediaSegmentError.readerStartFailed
        }
        var actualDynamicHDR = DynamicHDRMetadataStreamAccumulatorV4()
        while let sample = encodedOutput.copyNextSampleBuffer() {
            try cancellation.check()
            try actualDynamicHDR.append(sample)
        }
        guard encodedReader.status == .completed else {
            throw DeterministicV4MediaSegmentError.readerFailed
        }
        guard actualDynamicHDR == expectedDynamicHDR else {
            throw DeterministicV4MediaSegmentError
                .dynamicHDRMetadataMismatch
        }
    }

    func phase(
        for stage: AVFoundationTrackMigrationExecutionStageV4
    ) -> UpscalePhase {
        switch stage {
        case .validating, .preparingReaderWriter:
            .preparingReaderWriter
        case .migrating:
            .processingVideo
        case .finalizing:
            .finalizing
        case .verifying, .publishing:
            .validatingOutput
        case .completed:
            .completed
        }
    }

    func progressFraction(
        processedTime: CMTime,
        sourceDuration: CMTime
    ) -> Double? {
        guard processedTime.isNumeric,
              sourceDuration.isNumeric else { return nil }
        let processedSeconds = CMTimeGetSeconds(processedTime)
        let durationSeconds = CMTimeGetSeconds(sourceDuration)
        guard processedSeconds.isFinite,
              durationSeconds.isFinite,
              durationSeconds > 0 else { return nil }
        return min(1, max(0, processedSeconds / durationSeconds))
    }

    func audioResult(
        request: UpscaleRequest,
        preparedPlan: DeterministicV4PreparedAssetPlan
    ) -> AudioOutputResult {
        guard request.preserveAudio else { return .omitted }
        let audioTracks = preparedPlan.trackPlan.plan.tracks.filter {
            $0.source.kind == .audio && $0.expectedOutput != nil
        }
        guard !audioTracks.isEmpty else { return .absent }
        return audioTracks.contains { $0.action == .transcode }
            ? .transcoded
            : .preserved
    }

    func event(
        phase: UpscalePhase,
        source: VideoInfo,
        backendID: UpscaleBackendID,
        fraction: Double? = nil,
        frameCount: Int = 0,
        processedTime: CMTime? = nil
    ) -> UpscaleProgress {
        UpscaleProgress(
            phase: phase,
            fractionCompleted: fraction,
            processedFrameCount: frameCount,
            processedTime: processedTime,
            duration: source.duration,
            actualBackendID: backendID
        )
    }
}
