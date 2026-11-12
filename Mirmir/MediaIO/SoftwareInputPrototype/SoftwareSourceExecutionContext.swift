import AVFoundation
import CoreVideo
import CryptoKit
import Foundation

struct SoftwareSourceExecutionTrackPolicy: Codable, Equatable, Sendable {
    let originalOrdinal: UInt32
    let originalTrackID: MediaTrackStableIDV4
    let originalContainerTrackID: Int32?
    let carrierContainerTrackID: Int32
    let sourceCodecID: Int32
    let sourceCodecPrivateSHA256: ASHSHA256V4
    let sourceVideoSHA256: ASHSHA256V4?
    let sourceFrameFactsSHA256: ASHSHA256V4
    let sourcePacketFactsSHA256: ASHSHA256V4
    let selectedOriginalStart: ExactRationalV4
    let selectedOriginalEnd: ExactRationalV4
    let executionStart: ExactRationalV4
    let executionEnd: ExactRationalV4
    let nominalVideoPeriod: ExactRationalV4?
    let videoFrameCount: Int64?
    let missingOrZeroVideoDurations: Int64?
    let audibleAudioSamples: Int64?
    let audioSampleRate: Int32?
    let requiresAudioTranscode: Bool
    let workingRepresentation: String
    let nativeCarrierRange: MediaExactTimeRangeV4
    let nativeCarrierEdits: [MediaTrackEditV4]
    let executionMediaStart: ExactRationalV4
    let nativeTimebase: ExactRationalV4
    let executionTimebase: ExactRationalV4
    let nativeSourceMediaTypeID: String
    let nativeFormatDescriptors: [MediaTrackFormatDescriptorV4]
    let nativeMetadataFingerprint: ASHSHA256V4
    let nativeVideoClockSHA256: ASHSHA256V4?
    let nativeDecodedPayloadSHA256: ASHSHA256V4
    let nativeOriginalAudioPacketStreamSHA256: ASHSHA256V4?
}

struct SoftwareDerivedAACPacketTableMetadata: Codable, Equatable, Sendable {
    let sourceOrdinal: UInt32
    let originalPacketStreamSHA256: ASHSHA256V4
    let packetCount: Int64
    let primingSamples: Int64
    let remainderSamples: Int64
    let validSamples: Int64

    var value: String {
        func hex(_ value: Int64, width: Int) -> String {
            let raw = String(value, radix: 16)
            return String(repeating: "0", count: max(0, width - raw.count)) + raw
        }
        return " 00000000 " + hex(primingSamples, width: 8) + " "
            + hex(remainderSamples, width: 8) + " " + hex(validSamples, width: 16)
            + String(repeating: " 00000000", count: 8)
    }
}

struct SoftwareDerivedAACMetadataVerification: Codable, Equatable, Sendable {
    let trackID: MediaTrackStableIDV4
    let hint: SoftwareDerivedAACPacketTableMetadata
    let executionPolicySHA256: ASHSHA256V4
    let executionPolicy: SoftwareSourceExecutionPolicy
    let sourceMetadataSHA256: ASHSHA256V4
    let preservedOutputMetadataSHA256: ASHSHA256V4
    let completeOutputMetadataSHA256: ASHSHA256V4

    func verifies(
        source: ASHSHA256V4, output: ASHSHA256V4,
        policy: ASHSHA256V4?,
        passThrough: Bool,
        sourceStreamSHA256: ASHSHA256V4?,
        outputStreamSHA256: ASHSHA256V4?
    ) -> Bool {
        guard source == sourceMetadataSHA256,
              source == preservedOutputMetadataSHA256,
              output == completeOutputMetadataSHA256,
              policy == executionPolicySHA256,
              (try? executionPolicy.canonicalSHA256) == executionPolicySHA256,
              executionPolicy.derivedAACPacketTableMetadata == hint,
              executionPolicy.tracks.filter({
                  $0.audioSampleRate != nil && !$0.requiresAudioTranscode
              }).filter({ $0.originalOrdinal == hint.sourceOrdinal }).count == 1,
              let row = executionPolicy.tracks.first(where: { $0.originalTrackID == trackID }),
              row.originalOrdinal == hint.sourceOrdinal,
              row.nativeOriginalAudioPacketStreamSHA256 == hint.originalPacketStreamSHA256,
              row.audibleAudioSamples == hint.validSamples,
              !row.requiresAudioTranscode,
              hint.packetCount > 0, hint.packetCount <= Int64.max / 1024,
              hint.primingSamples >= 0, hint.primingSamples <= 1024,
              hint.remainderSamples == 0,
              hint.validSamples == hint.packetCount * 1024 - hint.primingSamples,
              passThrough, let sourceStream = sourceStreamSHA256,
              outputStreamSHA256 == sourceStream else { return false }
        return true
    }
}

struct SoftwareSourceExecutionPolicy: Codable, Equatable, Sendable {
    static let identityDomain = "mirmir-software-source-execution-policy-v3"
    static let videoClockContract = "all original frame PTS and positive durations must be exact or adjacent original-clock ticks of firstPTS+n/fps; processed duration is complete count/fps; raw source end and missing durations retained separately"
    static let audioClockContract = "one shared offset; complete audible sample counter anchored to original eligible PTS; original skips/raw clocks/terminal missing PTS retained; proven original AAC and PCM16 packets pass through; incompatible decoded audio is explicitly transcoded with zero-based encoded media and original target offset; one original AAC track requires a separately bound derived packet-table hint"
    let schemaID: String
    let originalSourceSHA256: ASHSHA256V4
    let originalFactsSHA256: ASHSHA256V4
    let originalCanonicalSHA256: ASHSHA256V4
    let originalGraphSHA256: ASHSHA256V4
    let workingDecodePolicySHA256: ASHSHA256V4
    let workingDecodeEnvelopeSHA256: ASHSHA256V4
    let originalGlobalOrigin: ExactRationalV4
    let sharedWorkingOffset: ExactRationalV4
    let videoClockPolicy: String
    let audioClockPolicy: String
    let tracks: [SoftwareSourceExecutionTrackPolicy]
    let derivedAACPacketTableMetadata: SoftwareDerivedAACPacketTableMetadata?

    var canonicalSHA256: ASHSHA256V4 {
        get throws { try ASHCanonicalJSONV4.hash(self, domain: Self.identityDomain) }
    }
}

/// Private proof of an explicit original-source to working-sample operation.
/// Original canonical/graph values remain intact and are never replaced by the
/// decoded MOV's codec, clock, metadata or sampling declarations.
struct SoftwareSourceExecutionContext: Codable, Equatable, Sendable {
    let originalCanonicalMedia: CanonicalMediaStateV4
    let originalGraph: MediaTrackGraphV4
    let originalSourceSHA256: ASHSHA256V4
    let sourceFactsSHA256: ASHSHA256V4
    let executionCanonicalMedia: CanonicalMediaStateV4
    let executionGraph: MediaTrackGraphV4
    let policy: SoftwareSourceExecutionPolicy
    let executionCanonicalSHA256: ASHSHA256V4
    let executionGraphSHA256: ASHSHA256V4
    let workingDecodeEnvelope: OriginalSoftwareWorkingDecodeEnvelope

    func adjustingAudioTranscodeMediaOrigins(
        in identified: MediaTrackGraphIdentifiedPlanV4
    ) throws -> MediaTrackGraphIdentifiedPlanV4 {
        try verifyIntegrity()
        let tracks = try identified.plan.tracks.map { planned -> MediaTrackPlannedTrackV4 in
            guard planned.action == .transcode,
                  let row = policy.tracks.first(where: { $0.originalTrackID == planned.source.identity.stableID }),
                  row.requiresAudioTranscode,
                  row.executionStart > .zero,
                  let expected = planned.expectedOutput else { return planned }
            // The private reader selects only actual audible content. AAC media
            // begins at its own zero; its target still retains the shared offset.
            let edits = try expected.edits.map { edit -> MediaTrackEditV4 in
                guard !edit.isEmpty, let source = edit.source else { return edit }
                return try MediaTrackEditV4(
                    ordinal: edit.ordinal,
                    source: MediaExactTimeRangeV4(
                        start: source.start.subtracting(row.executionStart),
                        duration: source.duration
                    ), target: edit.target, isEmpty: false
                )
            }
            let output = try MediaTrackNodeV4(
                identity: expected.identity, enabled: expected.enabled,
                kind: expected.kind, sourceMediaTypeID: expected.sourceMediaTypeID,
                language: expected.language, roleIDs: expected.roleIDs,
                timebase: expected.timebase, timeRange: expected.timeRange,
                edits: edits, formatDescriptors: expected.formatDescriptors,
                metadataFingerprint: expected.metadataFingerprint
            )
            return MediaTrackPlannedTrackV4(
                source: planned.source, action: planned.action, origin: planned.origin,
                expectedOutput: output, dropConsent: planned.dropConsent
            )
        }
        return try MediaTrackGraphIdentifiedPlanV4(plan: MediaTrackGraphPlanV4(
            sourceGraphSHA256: identified.plan.sourceGraphSHA256,
            tracks: tracks, groups: identified.plan.groups,
            associations: identified.plan.associations,
            diagnostics: identified.plan.diagnostics
        ))
    }

    var originalFactsSHA256: ASHSHA256V4 {
        get throws { sourceFactsSHA256 }
    }

    var policySHA256: ASHSHA256V4 {
        get throws { try policy.canonicalSHA256 }
    }

    func verifyIntegrity() throws {
        try originalCanonicalMedia.validate()
        try originalGraph.validate()
        try executionCanonicalMedia.validate()
        try executionGraph.validate()
        guard policy.schemaID == "mirmir.software-source-execution.v3",
              originalSourceSHA256 == originalCanonicalMedia.input.contentSHA256,
              originalSourceSHA256 == policy.originalSourceSHA256,
              sourceFactsSHA256 == policy.originalFactsSHA256,
              try originalCanonicalMedia.canonicalSHA256 == policy.originalCanonicalSHA256,
              try originalGraph.canonicalSHA256 == policy.originalGraphSHA256,
              try executionCanonicalMedia.canonicalSHA256 == executionCanonicalSHA256,
              try executionGraph.canonicalSHA256 == executionGraphSHA256,
              originalCanonicalMedia.input == executionCanonicalMedia.input,
              originalGraph.tracks.count == executionGraph.tracks.count,
              originalCanonicalMedia.tracks.count >= policy.tracks.count,
              executionCanonicalMedia.tracks.count == originalCanonicalMedia.tracks.count,
              originalCanonicalMedia.tracks.map(\.identity) == executionCanonicalMedia.tracks.map(\.identity),
              Array(originalCanonicalMedia.tracks.prefix(policy.tracks.count)).map(\.identity.ordinal) == originalGraph.tracks.map(\.identity.ordinal),
              policy.videoClockPolicy == SoftwareSourceExecutionPolicy.videoClockContract,
              policy.audioClockPolicy == SoftwareSourceExecutionPolicy.audioClockContract,
              policy.tracks.count == originalGraph.tracks.count,
              originalGraph.tracks.map(\.identity.ordinal)
                == executionGraph.tracks.map(\.identity.ordinal),
              originalGraph.tracks.map(\.identity.stableID)
                == executionGraph.tracks.map(\.identity.stableID)
        else { throw ProbeFailure("software execution identity/inventory integrity") }
        try workingDecodeEnvelope.verify(originalCanonicalMedia: originalCanonicalMedia,
            originalGraph: originalGraph)
        guard workingDecodeEnvelope.originalFactsSHA256 == sourceFactsSHA256,
              try workingDecodeEnvelope.canonicalSHA256 == policy.workingDecodeEnvelopeSHA256,
              try workingDecodeEnvelope.decodePolicy.canonicalSHA256 == policy.workingDecodePolicySHA256,
              workingDecodeEnvelope.originalGlobalOrigin == policy.originalGlobalOrigin,
              workingDecodeEnvelope.sharedWorkingOffset == policy.sharedWorkingOffset else {
            throw ProbeFailure("software execution decode envelope differs")
        }
        let minimum = try policy.tracks.map {
            try $0.selectedOriginalStart.subtracting(policy.originalGlobalOrigin)
        }.min()
        guard let minimum, try minimum.negated() == policy.sharedWorkingOffset,
              originalCanonicalMedia.tracks.flatMap(\.metadata).contains(where: {
                  $0.key == "original-source-facts" && $0.valueSHA256 == sourceFactsSHA256
              }) else { throw ProbeFailure("software source facts/shared clock policy integrity") }
        let hash = try policySHA256
        guard executionCanonicalMedia.tracks.allSatisfy({ track in
            track.metadata.contains(where: { $0.key == "software-source-execution-policy" && $0.valueSHA256 == hash })
        }), executionCanonicalMedia.observations.contains(where: {
            $0.path == "asset.software_execution_policy" && $0.observedValue == hash.rawValue
        }), executionGraph.diagnostics.contains(where: {
            $0.path == "asset.software_execution_policy" && $0.observedValue == hash.rawValue
        }) else { throw ProbeFailure("software execution policy is not bound to plans") }
        let originalPacketAACRows = policy.tracks.filter {
            $0.audioSampleRate != nil && !$0.requiresAudioTranscode
                && originalCanonicalMedia.tracks[Int($0.originalOrdinal)].codecID == "libav-codec-\($0.sourceCodecID)-aac"
        }
        guard (policy.derivedAACPacketTableMetadata != nil) == !originalPacketAACRows.isEmpty else {
            throw ProbeFailure("original AAC explicit packet table hint inventory")
        }
        if let hint = policy.derivedAACPacketTableMetadata {
            // File-global iTunSMPB can describe exactly one original packet-AAC
            // track even when sibling audio tracks are present and transcoded.
            guard originalPacketAACRows.count == 1, let row = originalPacketAACRows.first,
                  row.originalOrdinal == hint.sourceOrdinal,
                  !row.requiresAudioTranscode,
                  row.nativeOriginalAudioPacketStreamSHA256 == hint.originalPacketStreamSHA256,
                  row.audibleAudioSamples == hint.validSamples,
                  let rate = row.audioSampleRate,
                  hint.primingSamples >= 0, hint.primingSamples <= 1024,
                  hint.remainderSamples == 0,
                  hint.packetCount > 0,
                  hint.packetCount <= Int64.max / 1024,
                  hint.packetCount * 1024 == hint.primingSamples + hint.validSamples,
                  row.executionMediaStart == (try ExactRationalV4(hint.primingSamples, Int64(rate))),
                  originalCanonicalMedia.tracks[Int(row.originalOrdinal)].codecID == "libav-codec-\(row.sourceCodecID)-aac" else {
                throw ProbeFailure("single original AAC packet table metadata integrity")
            }
        }
        for (index, row) in policy.tracks.enumerated() {
            let original = originalGraph.tracks[index]
            let execution = executionGraph.tracks[index]
            let nativeType: AVMediaType
            let descriptorType: String
            switch original.kind {
            case .video: nativeType = .video; descriptorType = "fourcc_76696465"
            case .audio: nativeType = .audio; descriptorType = "fourcc_736f756e"
            default: throw ProbeFailure("software execution unsupported original media kind")
            }
            guard row.originalOrdinal == original.identity.ordinal,
                  row.originalTrackID == original.identity.stableID,
                  row.originalContainerTrackID == original.identity.containerTrackID,
                  row.carrierContainerTrackID == execution.identity.containerTrackID,
                  execution.kind == original.kind,
                  row.nativeSourceMediaTypeID == Self.stableToken(nativeType.rawValue),
                  execution.sourceMediaTypeID == row.nativeSourceMediaTypeID,
                  row.nativeFormatDescriptors.allSatisfy({ $0.mediaTypeID == descriptorType }),
                  executionCanonicalMedia.tracks[index].kind == originalCanonicalMedia.tracks[index].kind,
                  execution.formatDescriptors == row.nativeFormatDescriptors,
                  execution.metadataFingerprint == row.nativeMetadataFingerprint,
                  row.executionTimebase == (try Self.executionTimebase(
                      native: row.nativeTimebase,
                      period: row.nominalVideoPeriod,
                      start: row.executionStart,
                      end: row.executionEnd
                  )),
                  execution.timebase == row.executionTimebase,
                  execution.timeRange.start == .zero,
                  execution.timeRange.duration == row.executionEnd,
                  execution.edits == (try Self.executionEdits(row)),
                  row.executionStart == (try row.selectedOriginalStart.subtracting(policy.originalGlobalOrigin).adding(policy.sharedWorkingOffset)),
                  executionCanonicalMedia.tracks[index].identity
                    == originalCanonicalMedia.tracks[index].identity,
                  executionCanonicalMedia.tracks[index].duration == execution.timeRange.duration
            else { throw ProbeFailure("software execution track binding integrity") }
            if let period = row.nominalVideoPeriod, let count = row.videoFrameCount {
                guard period.isPositive, count > 0, !row.requiresAudioTranscode,
                      row.executionEnd == (try row.executionStart.adding(period.multiplied(by: ExactRationalV4(count)))),
                      let originalVideo = originalCanonicalMedia.tracks[index].video,
                      row.sourceVideoSHA256 == (try ASHCanonicalJSONV4.hash(originalVideo, domain: "mirmir-original-video-semantics-v1")),
                      executionCanonicalMedia.tracks[index].video == (try Self.expectedExecutionVideo(originalVideo)) else {
                    throw ProbeFailure("qualified video execution clock integrity")
                }
            } else {
                guard let samples = row.audibleAudioSamples, let rate = row.audioSampleRate,
                      samples > 0, rate > 0,
                      row.requiresAudioTranscode == (row.nativeOriginalAudioPacketStreamSHA256 == nil),
                      row.executionEnd == (try row.executionStart.adding(ExactRationalV4(samples, Int64(rate)))) else {
                    throw ProbeFailure("complete audible execution clock integrity")
                }
            }
            let nonempty = row.nativeCarrierEdits.filter { !$0.isEmpty }
            guard nonempty.count == 1, let nativeSource = nonempty[0].source,
                  row.nativeCarrierEdits.count == (row.executionStart > .zero ? 2 : 1),
                  nativeSource.start == row.executionMediaStart,
                  nativeSource.duration == (try row.selectedOriginalEnd.subtracting(row.selectedOriginalStart)),
                  nonempty[0].target.start == row.executionStart,
                  nonempty[0].target.duration == nativeSource.duration,
                  row.nativeCarrierEdits.filter(\.isEmpty).allSatisfy({ $0.source == nil && $0.target.start == .zero && $0.target.duration == row.executionStart }) else {
                throw ProbeFailure("recorded native carrier edit topology integrity")
            }
            for edit in original.edits where !edit.isEmpty {
                guard let source = edit.source,
                      try source.start.subtracting(edit.target.start) == policy.originalGlobalOrigin else {
                    throw ProbeFailure("original global clock origin integrity")
                }
            }
        }
    }

    func verify(context: OriginalSoftwareMediaContext, asset: AVAsset) async throws {
        try verifyIntegrity()
        let rebuilt = try await Self.make(
            originalCanonicalMedia: originalCanonicalMedia,
            originalGraph: originalGraph, context: context, asset: asset
        )
        guard rebuilt == self else {
            throw ProbeFailure("authenticated source/native software execution binding changed")
        }
    }

    static func make(
        originalCanonicalMedia: CanonicalMediaStateV4,
        originalGraph: MediaTrackGraphV4,
        context: OriginalSoftwareMediaContext,
        asset: AVAsset
    ) async throws -> SoftwareSourceExecutionContext {
        try context.originalProbe.checkCancellation()
        guard OriginalSoftwareMediaContext.associated(with: asset) === context,
              let sourceState = context.typedProjection.state,
              let sourceGraph = context.typedProjection.graph,
              let working = context.workingDecodePolicy,
              originalCanonicalMedia.tracks == sourceState.tracks,
              originalCanonicalMedia.observations == sourceState.observations,
              originalCanonicalMedia.input.contentSHA256 == context.sourceFacts.sourceHash,
              originalCanonicalMedia.input.byteCount == context.sourceFacts.sourceBytes,
              originalGraph == sourceGraph,
              originalGraph.tracks.count == context.sourceFacts.streams.count
        else { throw ProbeFailure("original facts/context binding for software execution") }
        let decodeEnvelope = try context.workingDecodeEnvelope()
        try decodeEnvelope.verify(originalCanonicalMedia: originalCanonicalMedia, originalGraph: originalGraph)
        try context.originalProbe.file.verifyUnchanged(url: context.originalProbe.url)
        var authenticationError = MIBError()
        try check(mib_source_authenticate(context.originalProbe.source, &authenticationError), authenticationError)
        let physical = try await asset.load(.tracks)
        guard physical.count == originalGraph.tracks.count else {
            throw ProbeFailure("native working carrier inventory differs")
        }
        let offset = try SoftwareVirtualCarrier.sharedWorkingOffset(context)
        var rows: [SoftwareSourceExecutionTrackPolicy] = []
        var nativeLanguages: [MediaTrackLanguageV4] = []
        var nativeRoles: [[String]] = []
        var nativeEnabled: [Bool] = []
        for index in physical.indices {
            try context.originalProbe.checkCancellation()
            let track = physical[index]
            let stream = context.sourceFacts.streams[index]
            let timeline = context.timings[index]
            let original = originalGraph.tracks[index]
            guard stream.ordinal == Int32(index),
                  (stream.mediaType == 0 && track.mediaType == .video)
                    || (stream.mediaType == 1 && track.mediaType == .audio),
                  let first = timeline.selectedStart, let end = timeline.selectedEnd
            else { throw ProbeFailure("software original/native ordinal or selected clock mismatch") }
            let enabled = try await track.load(.isEnabled)
            guard enabled == original.enabled else {
                throw ProbeFailure("working carrier must preserve original track activation")
            }
            nativeEnabled.append(enabled)
            nativeLanguages.append(try MediaTrackLanguageV4(
                languageCode: try await track.load(.languageCode),
                extendedLanguageTag: try await track.load(.extendedLanguageTag)
            ))
            nativeRoles.append(Array(Set(try await track.load(.mediaCharacteristics)
                .map { stableToken($0.rawValue) })).sorted())
            let scale = try await track.load(.naturalTimeScale)
            guard scale > 0 else { throw ProbeFailure("native working clock invalid") }
            let nativeRangeTime = try await track.load(.timeRange)
            let nativeRange = try exactRange(nativeRangeTime)
            let nativeEdits = try await track.load(.segments).enumerated().map { index, segment in
                try MediaTrackEditV4(ordinal: UInt32(index), source: segment.isEmpty ? nil : exactRange(segment.timeMapping.source), target: exactRange(segment.timeMapping.target), isEmpty: segment.isEmpty)
            }
            guard nativeEdits == (try SoftwareVirtualCarrier.expectedEdits(in: asset, sourceOrdinal: stream.ordinal)) else {
                throw ProbeFailure("native working carrier has unauthorized multiple, empty or retimed edits")
            }
            let descriptions = try await track.load(.formatDescriptions)
            let formats = try descriptions.enumerated().map {
                try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor(
                    $0.element, ordinal: UInt32($0.offset)
                )
            }
            guard !formats.isEmpty else { throw ProbeFailure("native working format missing") }
            let metadata = try await AVFoundationTrackGraphAdapterV4
                .canonicalTrackMetadataFingerprint(try await track.load(.metadata))
            let start = try context.sharedOrigin.normalize(first).adding(offset)
            let selectedEnd = try context.sharedOrigin.normalize(end).adding(offset)
            guard start >= .zero else { throw ProbeFailure("working shared origin is negative") }
            var period: ExactRationalV4?, frames: Int64?, zeroDurations: Int64?
            var samples: Int64?, rate: Int32?, videoSHA: ASHSHA256V4?
            let executionEnd: ExactRationalV4
            let clockSHA: ASHSHA256V4?
            let payloadSHA: ASHSHA256V4
            let representation: String
            let requiresAudioTranscode: Bool
            let originalAudioPacketStreamSHA256: ASHSHA256V4?
            if stream.mediaType == 0 {
                guard let nominal = stream.nominalFrameRate, nominal.isPositive,
                      let workingTrack = working.tracks.first(where: { $0.sourceOrdinal == stream.ordinal }),
                      workingTrack.destinationChroma == .yuv420,
                      [8, 10].contains(workingTrack.destinationBitDepth) else {
                    throw ProbeFailure("qualified working video clock/sampling contract missing")
                }
                let cadence = try ExactRationalV4.one.divided(by: nominal)
                let originalFrames = try readOriginalFrames(context: context, ordinal: stream.ordinal)
                try qualifyOriginalClock(
                    frames: originalFrames, timeline: timeline,
                    stream: stream, first: first, period: cadence
                )
                let native = try verifyNativeVideo(
                    asset: asset, track: track, context: context,
                    originalFrames: originalFrames, first: first, end: end,
                    offset: offset, working: workingTrack
                )
                guard native.count == timeline.frameCount else {
                    throw ProbeFailure("native carrier video count changed")
                }
                period = cadence; frames = native.count
                zeroDurations = timeline.rawZeroDuration
                videoSHA = try context.sourceVideoSHA256(ordinal: stream.ordinal)
                executionEnd = try start.adding(cadence.multiplied(by: ExactRationalV4(native.count)))
                clockSHA = native.clock; payloadSHA = native.payload
                representation = "declared-working-\(workingTrack.destinationBitDepth)-bit-420; explicit all-frame-qualified nominal processing clock"
                requiresAudioTranscode = false
                originalAudioPacketStreamSHA256 = nil
            } else {
                guard stream.sampleRate > 0, timeline.audibleSamples > 0 else {
                    throw ProbeFailure("complete audible sample clock missing")
                }
                let native = try verifyNativeAudio(
                    asset: asset, track: track, context: context,
                    stream: stream, start: start, samples: timeline.audibleSamples
                )
                samples = timeline.audibleSamples; rate = stream.sampleRate
                executionEnd = try start.adding(ExactRationalV4(timeline.audibleSamples, Int64(stream.sampleRate)))
                guard executionEnd == selectedEnd else {
                    throw ProbeFailure("selected audio end does not retain every audible sample")
                }
                clockSHA = nil; payloadSHA = native
                let audio = descriptions.count == 1 ? CMAudioFormatDescriptionGetStreamBasicDescription(descriptions[0])?.pointee : nil
                let packetAAC = stream.codecName == "aac" && audio?.mFormatID == kAudioFormatMPEG4AAC
                let packetPCM = stream.codecName == "pcm_s16le" && audio?.mFormatID == kAudioFormatLinearPCM && audio?.mBitsPerChannel == 16
                requiresAudioTranscode = !(packetAAC || packetPCM)
                originalAudioPacketStreamSHA256 = requiresAudioTranscode ? nil
                    : try Self.verifyNativeOriginalAudioPacketStream(
                        asset: asset, track: track, context: context,
                        stream: stream, compressed: packetAAC
                    )
                representation = requiresAudioTranscode
                    ? "decoded-signed-packed-little-endian-s32; explicit AAC transcode required"
                    : "original authenticated audio packets; source ASC or PCM16 format and exact audible edit retained"
            }
            let expectedRange = try MediaExactTimeRangeV4(
                start: start, duration: selectedEnd.subtracting(start)
            )
            guard nativeRange.start <= expectedRange.start,
                  admitted(try nativeRange.start.adding(nativeRange.duration), exact: selectedEnd, timescale: CMTimeRangeGetEnd(nativeRangeTime).timescale)
            else { throw ProbeFailure("native carrier range changed selected original media extent") }
            let nonempty = nativeEdits.filter { !$0.isEmpty }
            guard nativeRange.start == .zero, nonempty.count == 1,
                  let media = nonempty[0].source,
                  nonempty[0].target.start == start,
                  nonempty[0].target.duration == expectedRange.duration,
                  media.duration == expectedRange.duration,
                  nativeEdits.filter(\.isEmpty).allSatisfy({ $0.target.start == .zero && $0.target.duration == start }) else {
                throw ProbeFailure("native working edit topology differs from selected source content")
            }
            rows.append(SoftwareSourceExecutionTrackPolicy(
                originalOrdinal: original.identity.ordinal,
                originalTrackID: original.identity.stableID,
                originalContainerTrackID: original.identity.containerTrackID,
                carrierContainerTrackID: track.trackID,
                sourceCodecID: stream.codecID,
                sourceCodecPrivateSHA256: ASHSHA256V4(rawData: stream.extradata),
                sourceVideoSHA256: videoSHA,
                sourceFrameFactsSHA256: timeline.frameFactsSHA256,
                sourcePacketFactsSHA256: timeline.packetFactsSHA256,
                selectedOriginalStart: first, selectedOriginalEnd: end,
                executionStart: start, executionEnd: executionEnd,
                nominalVideoPeriod: period, videoFrameCount: frames,
                missingOrZeroVideoDurations: zeroDurations,
                audibleAudioSamples: samples, audioSampleRate: rate,
                requiresAudioTranscode: requiresAudioTranscode,
                workingRepresentation: representation,
                nativeCarrierRange: nativeRange,
                nativeCarrierEdits: nativeEdits,
                executionMediaStart: media.start,
                nativeTimebase: try ExactRationalV4(1, Int64(scale)),
                executionTimebase: try Self.executionTimebase(
                    native: ExactRationalV4(1, Int64(scale)),
                    period: period, start: start, end: executionEnd
                ),
                nativeSourceMediaTypeID: Self.stableToken(track.mediaType.rawValue),
                nativeFormatDescriptors: formats,
                nativeMetadataFingerprint: metadata,
                nativeVideoClockSHA256: clockSHA,
                nativeDecodedPayloadSHA256: payloadSHA,
                nativeOriginalAudioPacketStreamSHA256: originalAudioPacketStreamSHA256
            ))
        }
        let packetAACRows = rows.filter {
            $0.audioSampleRate != nil && !$0.requiresAudioTranscode
                && context.sourceFacts.streams[Int($0.originalOrdinal)].codecName == "aac"
        }
        let derivedAACMetadata: SoftwareDerivedAACPacketTableMetadata?
        if let row = packetAACRows.first {
            // One file-global packet-table hint is legal only when exactly one
            // original audio track is packet-AAC. Sibling non-AAC audio may be
            // transcoded; multiple original AAC tracks remain unqualified.
            guard packetAACRows.count == 1,
                  let digest = row.nativeOriginalAudioPacketStreamSHA256,
                  let valid = row.audibleAudioSamples else {
                throw ProbeFailure("file-global AAC packet table hint requires exactly one original packet-AAC track")
            }
            let timeline = context.timings[Int(row.originalOrdinal)]
            derivedAACMetadata = SoftwareDerivedAACPacketTableMetadata(
                sourceOrdinal: row.originalOrdinal,
                originalPacketStreamSHA256: digest,
                packetCount: timeline.packetCount,
                primingSamples: timeline.skipStart,
                remainderSamples: timeline.skipEnd, validSamples: valid
            )
        } else { derivedAACMetadata = nil }
        let policy = SoftwareSourceExecutionPolicy(
            schemaID: "mirmir.software-source-execution.v3",
            originalSourceSHA256: context.sourceFacts.sourceHash,
            originalFactsSHA256: context.typedProjection.report.originalFactsSHA256,
            originalCanonicalSHA256: try originalCanonicalMedia.canonicalSHA256,
            originalGraphSHA256: try originalGraph.canonicalSHA256,
            workingDecodePolicySHA256: try working.canonicalSHA256,
            workingDecodeEnvelopeSHA256: try decodeEnvelope.canonicalSHA256,
            originalGlobalOrigin: context.sharedOrigin.seconds,
            sharedWorkingOffset: offset,
            videoClockPolicy: SoftwareSourceExecutionPolicy.videoClockContract,
            audioClockPolicy: SoftwareSourceExecutionPolicy.audioClockContract,
            tracks: rows,
            derivedAACPacketTableMetadata: derivedAACMetadata
        )
        let policyHash = try policy.canonicalSHA256
        var canonical: [CanonicalMediaTrackV4] = []
        var graph: [MediaTrackNodeV4] = []
        for (index, row) in rows.enumerated() {
            let source = originalCanonicalMedia.tracks[index]
            let node = originalGraph.tracks[index]
            let range = try MediaExactTimeRangeV4(
                start: .zero, duration: row.executionEnd
            )
            let video: CanonicalVideoStateV4?
            if let originalVideo = source.video,
               let workingTrack = working.tracks.first(where: { UInt32($0.sourceOrdinal) == row.originalOrdinal }) {
                let expected = try Self.expectedExecutionVideo(originalVideo)
                guard workingTrack.destinationRaster == expected.encodedRaster,
                      workingTrack.destinationFormatID == OriginalSoftwareWorkingVideoPolicy.destinationFormat(for: originalVideo),
                      workingTrack.destinationBitDepth == expected.pixel.bitDepth,
                      workingTrack.destinationRange == expected.pixel.range,
                      workingTrack.destinationChroma == expected.pixel.chromaSubsampling,
                      workingTrack.destinationSiting == expected.pixel.chromaSiting,
                      workingTrack.destinationColor == expected.color else {
                    throw ProbeFailure("working video policy differs from supported source-bound conversion")
                }
                video = expected
            } else { video = nil }
            let metadata = [
                CanonicalMetadataValueV4(key: "native-carrier-track-metadata", dataType: "application/vnd.mirmir.native-track-fingerprint.v1", locale: nil, valueSHA256: row.nativeMetadataFingerprint),
                CanonicalMetadataValueV4(key: "software-source-execution-policy", dataType: "application/vnd.mirmir.software-source-execution.v3", locale: nil, valueSHA256: policyHash)
            ]
            canonical.append(CanonicalMediaTrackV4(
                identity: source.identity, enabled: nativeEnabled[index], kind: source.kind,
                languageTag: nativeLanguages[index].languageCode,
                roleIDs: nativeRoles[index], codecID: row.nativeFormatDescriptors[0].mediaSubtypeID,
                timebase: row.executionTimebase, duration: range.duration,
                edits: [CanonicalMediaEditV4(ordinal: 0, sourceStart: row.executionMediaStart, sourceDuration: try row.executionEnd.subtracting(row.executionStart), timelineStart: row.executionStart, rate: .one)],
                metadata: metadata, video: video
            ))
            graph.append(try MediaTrackNodeV4(
                identity: MediaTrackIdentityV4(ordinal: node.identity.ordinal, stableID: node.identity.stableID, containerTrackID: row.carrierContainerTrackID),
                enabled: nativeEnabled[index], kind: node.kind,
                sourceMediaTypeID: row.nativeSourceMediaTypeID,
                language: nativeLanguages[index], roleIDs: nativeRoles[index],
                timebase: row.executionTimebase, timeRange: range,
                edits: try executionEdits(row),
                formatDescriptors: row.nativeFormatDescriptors,
                metadataFingerprint: row.nativeMetadataFingerprint
            ))
        }
        let maximumEnd = rows.map(\.executionEnd).max() ?? .zero
        for source in originalCanonicalMedia.tracks.dropFirst(rows.count) {
            canonical.append(CanonicalMediaTrackV4(
                identity: source.identity, enabled: source.enabled, kind: source.kind,
                languageTag: source.languageTag, roleIDs: source.roleIDs, codecID: source.codecID,
                timebase: source.timebase, duration: maximumEnd, edits: [],
                metadata: (source.metadata + [CanonicalMetadataValueV4(key: "software-source-execution-policy", dataType: "application/vnd.mirmir.software-source-execution.v3", locale: nil, valueSHA256: policyHash)]).sorted { $0.key < $1.key }, video: nil
            ))
        }
        let canonicalState = try CanonicalMediaStateV4(
            input: originalCanonicalMedia.input, tracks: canonical,
            observations: [CanonicalMediaObservationV4(severity: .information, code: .unknownValue, path: "asset.software_execution_policy", observedValue: policyHash.rawValue)]
        )
        let graphState = try MediaTrackGraphV4(
            tracks: graph, groups: [], associations: [],
            diagnostics: [MediaTrackDiagnosticV4(severity: .information, code: .unknownFormatProperty, path: "asset.software_execution_policy", observedValue: policyHash.rawValue)]
        )
        let result = SoftwareSourceExecutionContext(
            originalCanonicalMedia: originalCanonicalMedia, originalGraph: originalGraph,
            originalSourceSHA256: context.sourceFacts.sourceHash,
            sourceFactsSHA256: context.typedProjection.report.originalFactsSHA256,
            executionCanonicalMedia: canonicalState, executionGraph: graphState,
            policy: policy, executionCanonicalSHA256: try canonicalState.canonicalSHA256,
            executionGraphSHA256: try graphState.canonicalSHA256,
            workingDecodeEnvelope: decodeEnvelope
        )
        try result.verifyIntegrity()
        try context.originalProbe.file.verifyUnchanged(url: context.originalProbe.url)
        return result
    }
}

private extension SoftwareSourceExecutionContext {
    static func expectedExecutionVideo(_ source: CanonicalVideoStateV4) throws -> CanonicalVideoStateV4 {
        guard (8...16).contains(source.pixel.bitDepth), source.pixel.alphaModel == .none,
              source.pixel.chromaSubsampling != .rgb || source.pixel.bitDepth == 8,
              source.pixel.range != .unknown,
              [.yuv420, .yuv422, .yuv444, .rgb].contains(source.pixel.chromaSubsampling) else {
            throw ProbeFailure("unqualified original-to-working video interpretation")
        }
        return CanonicalVideoStateV4(encodedRaster: source.encodedRaster,
            presentationRaster: source.presentationRaster, preferredTransform: source.preferredTransform,
            cleanAperture: source.cleanAperture, pixelAspectRatio: source.pixelAspectRatio,
            pixel: CanonicalPixelStateV4(formatID: "working-" + OriginalSoftwareWorkingVideoPolicy.destinationFormat(for: source),
                bitDepth: OriginalSoftwareWorkingVideoPolicy.destinationDepth(for: source), range: source.pixel.range, chromaSubsampling: .yuv420,
                chromaSiting: try OriginalSoftwareWorkingVideoPolicy.destinationSiting(for: source),
                alphaModel: .none),
            color: OriginalSoftwareWorkingVideoPolicy.destinationColor(for: source), scan: source.scan)
    }
    static func executionTimebase(
        native: ExactRationalV4,
        period: ExactRationalV4?,
        start: ExactRationalV4,
        end: ExactRationalV4
    ) throws -> ExactRationalV4 {
        guard native.numerator == 1, native.denominator > 0 else {
            throw ProbeFailure("software execution native clock is invalid")
        }
        var scale = native.denominator
        for denominator in [period?.denominator, start.denominator, end.denominator].compactMap({ $0 }) {
            var a = scale, b = denominator
            while b != 0 { (a, b) = (b, a % b) }
            let product = (scale / a).multipliedReportingOverflow(by: denominator)
            guard !product.overflow, product.partialValue <= Int64(Int32.max) else {
                throw ProbeFailure("software exact execution media clock is not representable")
            }
            scale = product.partialValue
        }
        return try ExactRationalV4(1, scale)
    }

    struct NativeVideoClockFact: Codable {
        let ordinal: Int64
        let presentation: ExactRationalV4
        let nativeDuration: ExactRationalV4?
        let nativeDurationState: String
        let selectedSourceSampleTableDuration: ExactRationalV4
    }

    static func readOriginalFrames(context: OriginalSoftwareMediaContext, ordinal: Int32) throws -> [FrameFact] {
        let path = context.evidenceDirectory.appendingPathComponent("stream-\(ordinal)-frames.jsonl")
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024,
              ASHSHA256V4(rawData: data) == context.timings[Int(ordinal)].frameFactsSHA256 else {
            throw ProbeFailure("original frame timing facts bound/authentication")
        }
        return try data.split(separator: 10).map { try JSONDecoder().decode(FrameFact.self, from: Data($0)) }
    }

    static func rawCMTime(_ raw: RawTime) throws -> CMTime {
        let value = raw.value.multipliedReportingOverflow(by: Int64(raw.numerator))
        guard !value.overflow, raw.denominator > 0 else { throw ProbeFailure("original raw clock overflow") }
        return CMTime(value: value.partialValue, timescale: raw.denominator)
    }

    static func qualifyOriginalClock(frames: [FrameFact], timeline: TimingSummary, stream: OriginalStream, first: ExactRationalV4, period: ExactRationalV4) throws {
        guard Int64(frames.count) == timeline.frameCount, !frames.isEmpty else {
            throw ProbeFailure("complete original video clock inventory missing")
        }
        for (index, frame) in frames.enumerated() {
            let raw = stream.codecName == "mpeg4" ? frame.bitstreamVOPTime : frame.rawPTS
            guard frame.ordinal == Int64(index), let raw,
                  let selected = frame.selectedPresentation,
                  try MediaClockConversionPolicyV4.exactRational(rawCMTime(raw)) == selected else {
                throw ProbeFailure("original selected/raw clock qualification missing")
            }
            let expected = try first.adding(period.multiplied(by: ExactRationalV4(Int64(index))))
            guard MediaClockConversionPolicyV4.isExactOrAdjacentClockQuantization(try rawCMTime(raw), of: try cm(expected)) else {
                throw ProbeFailure("original video PTS off nominal processing lattice")
            }
            if let duration = frame.rawDuration, duration.value > 0 {
                guard MediaClockConversionPolicyV4.isExactOrAdjacentClockQuantization(try rawCMTime(duration), of: try cm(period)) else {
                    throw ProbeFailure("original positive video duration off nominal processing lattice")
                }
            }
        }
    }

    static func verifyNativeVideo(asset: AVAsset, track: AVAssetTrack, context: OriginalSoftwareMediaContext, originalFrames: [FrameFact], first: ExactRationalV4, end: ExactRationalV4, offset: ExactRationalV4, working: OriginalSoftwareWorkingVideoPolicy) throws -> (count: Int64, clock: ASHSHA256V4, payload: ASHSHA256V4) {
        let reader = try AVAssetReader(asset: asset)
        let selectedStart = try context.sharedOrigin.normalize(first).adding(offset)
        reader.timeRange = CMTimeRange(start: try cm(selectedStart), duration: try cm(end.subtracting(first)))
        let pixelFormat = working.destinationFormatID.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let rawDelivery = ["mirmir-opaque-yuv-rational420-raw-biplanar-delivery", "mirmir-rgb8-rational420-raw-biplanar-delivery"].contains(working.converterID)
        guard let originalVideo = context.typedProjection.state?.tracks.first(where: {
            $0.identity.ordinal == UInt32(working.sourceOrdinal)
        })?.video else { throw ProbeFailure("missing original video for working delivery check") }
        let workingVideo = try expectedExecutionVideo(originalVideo)
        let output: AVAssetReaderOutput = rawDelivery ? AVAssetReaderSampleReferenceOutput(track: track)
            : AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        guard reader.canAdd(output) else { throw ProbeFailure("native video reader refuses working sampling") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProbeFailure("native video reader start") }
        defer { reader.cancelReading() }
        var count: Int64 = 0, clock = SHA256(), payload = SHA256()
        while let delivered = output.copyNextSampleBuffer() {
            try context.originalProbe.checkCancellation()
            if CMSampleBufferGetNumSamples(delivered) == 0 {
                if rawDelivery { try SoftwareVirtualCarrier.accountReferenceControl(delivered, asset: asset, reader: reader) }
                continue
            }
            let sample = rawDelivery
                ? try SoftwareRawWorkingVideo.unpack(delivered, asset: asset, video: workingVideo, metalCompatible: false)
                : delivered
            guard count < Int64(originalFrames.count), CMSampleBufferGetNumSamples(sample) == 1,
                  let image = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetPixelFormatType(image) == pixelFormat,
                  CVPixelBufferGetWidth(image) == Int(working.destinationRaster.width),
                  CVPixelBufferGetHeight(image) == Int(working.destinationRaster.height),
                  CVPixelBufferGetPlaneCount(image) == 2,
                  let originalPTS = originalFrames[Int(count)].selectedPresentation else {
                throw ProbeFailure("native decoded working video shape/count changed")
            }
            let next = Int(count) + 1 < originalFrames.count ? originalFrames[Int(count) + 1].selectedPresentation : end
            guard let next else { throw ProbeFailure("source selected native duration missing") }
            let expectedPTS = try context.sharedOrigin.normalize(originalPTS).adding(offset)
            let expectedDuration = try next.subtracting(originalPTS)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample), duration = CMSampleBufferGetDuration(sample)
            guard MediaClockConversionPolicyV4.isExactOrAdjacentClockQuantization(pts, of: try cm(expectedPTS)) else {
                throw ProbeFailure("native working video changed selected original clock")
            }
            let observedDuration: ExactRationalV4?
            if duration.isNumeric, duration.value > 0 {
                guard MediaClockConversionPolicyV4.isExactOrAdjacentClockQuantization(duration, of: try cm(expectedDuration)) else {
                    throw ProbeFailure("native working video changed known duration")
                }
                observedDuration = try MediaClockConversionPolicyV4.exactRational(duration)
            } else {
                guard !duration.isValid else { throw ProbeFailure("unsupported native video duration state") }
                observedDuration = nil
            }
            var line = try ASHCanonicalJSONV4.encode(NativeVideoClockFact(ordinal: count, presentation: MediaClockConversionPolicyV4.exactRational(pts), nativeDuration: observedDuration, nativeDurationState: observedDuration == nil ? "invalid" : "numeric", selectedSourceSampleTableDuration: expectedDuration))
            line.append(10); clock.update(data: line)
            guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { throw ProbeFailure("native image lock") }
            do {
                defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
                for plane in 0..<2 {
                    guard let base = CVPixelBufferGetBaseAddressOfPlane(image, plane) else { throw ProbeFailure("native image plane missing") }
                    let width = CVPixelBufferGetWidthOfPlane(image, plane), height = CVPixelBufferGetHeightOfPlane(image, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
                    let active = width * (plane == 0 ? 1 : 2) * (working.destinationBitDepth == 8 ? 1 : 2)
                    guard stride >= active else { throw ProbeFailure("native image row bound") }
                    for row in 0..<height { payload.update(data: Data(bytes: base.advanced(by: row * stride), count: active)) }
                }
            }
            count += 1
        }
        guard reader.status == .completed else { throw reader.error ?? ProbeFailure("native video decode incomplete") }
        return (count, sha(clock), sha(payload))
    }

    static func verifyNativeOriginalAudioPacketStream(
        asset: AVAsset, track: AVAssetTrack,
        context: OriginalSoftwareMediaContext,
        stream: OriginalStream, compressed: Bool
    ) throws -> ASHSHA256V4 {
        var expected = SHA256(), observed = SHA256(), expectedPackets: Int64 = 0
        func update(_ hash: inout SHA256, payload: Data) {
            if compressed {
                var size = UInt64(payload.count).bigEndian
                withUnsafeBytes(of: &size) { hash.update(bufferPointer: $0) }
            }
            hash.update(data: payload)
        }
        var cursor: OpaquePointer?, error = MIBError()
        try check(mib_cursor_open(context.originalProbe.source, stream.ordinal, 0, &cursor, &error), error)
        defer { mib_cursor_close(&cursor) }
        while true {
            try context.originalProbe.checkCancellation()
            var packet = MIBPacket()
            let status = mib_next_packet(cursor, &packet, &error); try check(status, error)
            if status == 0 { break }
            guard packet.bytes.size > 0, packet.bytes.size <= 16 * 1024 * 1024,
                  packet.identity.ordinal_valid != 0,
                  packet.identity.ordinal == expectedPackets,
                  let pointer = packet.bytes.data else {
                throw ProbeFailure("source original audio packet inventory invalid")
            }
            update(&expected, payload: Data(bytes: pointer, count: packet.bytes.size))
            expectedPackets += 1
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw ProbeFailure("native original audio packet reader refused") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProbeFailure("native original audio packet reader start") }
        defer { reader.cancelReading() }
        var count: Int64 = 0
        while let sample = output.copyNextSampleBuffer() {
            try context.originalProbe.checkCancellation()
            let samples = CMSampleBufferGetNumSamples(sample)
            if samples == 0 { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw ProbeFailure("native original audio packet block absent") }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0, size <= 64 * 1024 * 1024 else { throw ProbeFailure("native original audio packet block bound") }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == noErr else { throw ProbeFailure("native original audio packet copy") }
            if compressed {
                var offset = 0
                for index in 0..<samples {
                    let bytes = CMSampleBufferGetSampleSize(sample, at: index)
                    guard bytes > 0, bytes <= size - offset else { throw ProbeFailure("native compressed audio packet size invalid") }
                    update(&observed, payload: data.subdata(in: offset..<offset + bytes))
                    offset += bytes; count += 1
                }
                guard offset == size else { throw ProbeFailure("native compressed audio packet trailing bytes") }
            } else {
                update(&observed, payload: data)
            }
        }
        let expectedSHA = sha(expected), observedSHA = sha(observed)
        guard reader.status == .completed, expectedSHA == observedSHA,
              !compressed || count == expectedPackets else {
            throw reader.error ?? ProbeFailure("native original encoded audio packet bytes/order/inventory changed: \(count)/\(expectedPackets)")
        }
        return observedSHA
    }

    static func verifyNativeAudio(asset: AVAsset, track: AVAssetTrack, context: OriginalSoftwareMediaContext, stream: OriginalStream, start: ExactRationalV4, samples: Int64) throws -> ASHSHA256V4 {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: try cm(start), duration: try cm(ExactRationalV4(samples, Int64(stream.sampleRate))))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw ProbeFailure("native audible PCM reader refused") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProbeFailure("native audio reader start") }
        defer { reader.cancelReading() }
        var count: Int64 = 0, payload = SHA256()
        while let sample = output.copyNextSampleBuffer() {
            try context.originalProbe.checkCancellation()
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            guard sampleCount > 0,
                  let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32,
                  asbd.mSampleRate == Double(stream.sampleRate),
                  asbd.mChannelsPerFrame == UInt32(stream.channels),
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
                  asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  let block = CMSampleBufferGetDataBuffer(sample) else {
                throw ProbeFailure("native audible PCM representation changed")
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let expected = try start.adding(ExactRationalV4(count, Int64(stream.sampleRate)))
            guard MediaClockConversionPolicyV4.isExactOrAdjacentClockQuantization(pts, of: try cm(expected)),
                  MediaClockConversionPolicyV4.isExactOrAdjacentClockQuantization(CMSampleBufferGetDuration(sample), of: try cm(ExactRationalV4(Int64(sampleCount), Int64(stream.sampleRate)))) else {
                throw ProbeFailure("native audible PCM clock shifted/gapped/overlapped")
            }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount <= 64 * 1024 * 1024,
                  byteCount == sampleCount * Int(stream.channels) * 4 else {
                throw ProbeFailure("native audible PCM byte/sample bound")
            }
            var bytes = Data(count: byteCount)
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!) }
            guard status == noErr else { throw ProbeFailure("native audible PCM block copy") }
            payload.update(data: bytes)
            count += Int64(sampleCount)
            guard count <= samples else { throw ProbeFailure("native audible PCM padded") }
        }
        guard reader.status == .completed, count == samples else {
            throw reader.error ?? ProbeFailure("native audible PCM incomplete/trimmed")
        }
        return sha(payload)
    }

    static func executionEdits(_ row: SoftwareSourceExecutionTrackPolicy) throws -> [MediaTrackEditV4] {
        var edits: [MediaTrackEditV4] = []
        if row.executionStart > .zero {
            edits.append(try MediaTrackEditV4(ordinal: 0, source: nil, target: MediaExactTimeRangeV4(start: .zero, duration: row.executionStart), isEmpty: true))
        }
        let duration = try row.executionEnd.subtracting(row.executionStart)
        edits.append(try MediaTrackEditV4(ordinal: UInt32(edits.count), source: MediaExactTimeRangeV4(start: row.executionMediaStart, duration: duration), target: MediaExactTimeRangeV4(start: row.executionStart, duration: duration), isEmpty: false))
        return edits
    }

    static func exactRange(_ range: CMTimeRange) throws -> MediaExactTimeRangeV4 {
        try MediaExactTimeRangeV4(start: MediaClockConversionPolicyV4.exactRational(range.start), duration: MediaClockConversionPolicyV4.exactRational(range.duration))
    }

    static func admitted(_ observed: ExactRationalV4, exact: ExactRationalV4, timescale: CMTimeScale) -> Bool {
        guard let observed = try? MediaClockConversionPolicyV4.exact(observed, timescale: timescale).time,
              let exact = try? cm(exact) else { return false }
        return MediaClockConversionPolicyV4.isExactOrAdjacentClockQuantization(observed, of: exact)
    }

    static func stableToken(_ raw: String) -> String {
        MediaTrackGraphLexiconV4.isStableToken(raw) ? raw : "utf8_" + raw.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func sha(_ hash: SHA256) -> ASHSHA256V4 {
        try! ASHSHA256V4(hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}


extension SoftwareSourceExecutionContext {
    func originalMetadataItemsAfterDerivedAACAddition(
        _ items: [AVMetadataItem]
    ) async throws -> [AVMetadataItem] {
        guard let hint = policy.derivedAACPacketTableMetadata else { return items }
        let derived = items.filter { $0.identifier?.rawValue == "itlk/com.apple.iTunes.iTunSMPB" }
        guard derived.count == 1, let item = derived.first,
              item.keySpace?.rawValue == "itlk",
              item.dataType == kCMMetadataBaseDataType_UTF8 as String,
              try await item.load(.stringValue) == hint.value else {
            throw ProbeFailure("declared derived AAC metadata item was lost/changed/duplicated")
        }
        return items.filter { $0.identifier?.rawValue != "itlk/com.apple.iTunes.iTunSMPB" }
    }

    func applyDerivedSingleAACPacketTableHint(
        to url: URL,
        cancellationCheck: @Sendable () throws -> Void = {}
    ) async throws {
        try cancellationCheck()
        try verifyIntegrity()
        guard let hint = policy.derivedAACPacketTableMetadata else { return }
        let before = AVURLAsset(url: url)
        let existing = try await before.loadMetadata(for: .iTunesMetadata)
            .filter { $0.identifier?.rawValue == "itlk/com.apple.iTunes.iTunSMPB" }
        guard existing.isEmpty else { throw ProbeFailure("output AAC packet table hint already exists; original tags cannot be overwritten") }
        let entry = try MOViTunesGaplessMetadataV4.entry(utf8Value: hint.value)
        try MOViTunesGaplessMetadataV4.insertIfMissing([entry], into: url, cancellation: cancellationCheck)
        try cancellationCheck()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let items = try await asset.loadMetadata(for: .iTunesMetadata)
            .filter { $0.identifier?.rawValue == "itlk/com.apple.iTunes.iTunSMPB" }
        guard items.count == 1, let item = items.first,
              try await item.load(.stringValue) == hint.value,
              let end = policy.tracks.map(\.executionEnd).max(),
              try MediaClockConversionPolicyV4.exactRational(await asset.load(.duration)) == end else {
            throw ProbeFailure("derived single AAC packet table metadata/native duration readback failed")
        }
    }
}
