import AVFoundation
import Foundation

/// A declared change to the technical iTunes packet-table value following a
/// planned AAC transcode. Other metadata is compared with the same complete
/// canonicalizer used for unchanged migrations.
struct AACGaplessMetadataTranslationV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.aac-gapless-metadata-translation.v4.1"

    let schemaID: String
    let identifiedPlan: MediaTrackGraphIdentifiedPlanV4
    let trackID: MediaTrackStableIDV4
    let outputTrackOrdinal: Int
    let sourceAssetMetadataSHA256: ASHSHA256V4
    let outputAssetMetadataSHA256: ASHSHA256V4
    let sourceEntrySHA256: ASHSHA256V4
    let outputEntrySHA256: ASHSHA256V4
    let sourceValue: String
    let outputValue: String
    let encodedAudioPayloadSHA256: ASHSHA256V4
    let sampleRate: UInt32
    let framesPerPacket: UInt32
    let appendedPCMFrameCount: UInt64
    let encoderPrimingFrameCount: UInt64
    let firstMediaFrame: UInt64
    let validFrameCount: UInt64
    let remainderFrameCount: UInt64
    let packetTable: MOViTunesGaplessMetadataV4.PacketTable

    enum Failure: Error, Equatable {
        case invalidTranslation
        case unsupportedValue
        case metadataMismatch
        case outputMismatch
    }

    func validate() throws {
        try identifiedPlan.verify()
        let audio = identifiedPlan.plan.tracks.filter { $0.source.kind == .audio }
        let migrated = identifiedPlan.plan.tracks.filter { $0.action != .dropWithConsent }
        guard schemaID == Self.currentSchemaID,
              audio.count == 1, let planned = audio.first,
              planned.source.identity.stableID == trackID,
              planned.action == .transcode,
              let output = planned.expectedOutput,
              output.kind == .audio,
              output.formatDescriptors.count == 1,
              output.formatDescriptors[0].mediaSubtypeID == "fourcc_61616320",
              migrated.indices.contains(outputTrackOrdinal),
              migrated[outputTrackOrdinal].source.identity.stableID == trackID,
              packetTable.trackOrdinal == outputTrackOrdinal,
              sampleRate > 0, framesPerPacket > 0,
              packetTable.mediaTimescale == sampleRate,
              !packetTable.timingRuns.isEmpty,
              packetTable.timingRuns.allSatisfy({ $0.duration == framesPerPacket }),
              packetTable.timingRuns.reduce(UInt64(0), { $0 + UInt64($1.packetCount) }) == packetTable.packetCount,
              packetTable.packetCount <= UInt64(Int64.max) / UInt64(framesPerPacket),
              packetTable.mediaDuration == packetTable.packetCount * UInt64(framesPerPacket),
              try Self.rawEdits(packetTable) == output.edits else {
            throw Failure.invalidTranslation
        }
        let facts = try Self.derive(output: output, packetTable: packetTable,
            sampleRate: sampleRate, framesPerPacket: framesPerPacket)
        guard appendedPCMFrameCount == facts.appendedFrames,
              encoderPrimingFrameCount == facts.encoderPriming,
              firstMediaFrame == facts.firstMedia,
              validFrameCount == facts.valid,
              remainderFrameCount == facts.remainder,
              outputValue == (try Self.replacingPacketTable(in: sourceValue,
                priming: firstMediaFrame, remainder: remainderFrameCount,
                valid: validFrameCount)) else {
            throw Failure.invalidTranslation
        }
    }

    static func derive(
        output: MediaTrackNodeV4,
        packetTable: MOViTunesGaplessMetadataV4.PacketTable,
        sampleRate: UInt32,
        framesPerPacket: UInt32
    ) throws -> (appendedFrames: UInt64, encoderPriming: UInt64,
                 firstMedia: UInt64, valid: UInt64, remainder: UInt64) {
        let edits = output.edits
        let nonempty = edits.filter { !$0.isEmpty }
        guard output.timeRange.start == .zero,
              let first = nonempty.first, let source = first.source,
              let last = edits.last else { throw Failure.invalidTranslation }
        let end = try last.target.start.adding(last.target.duration)
        let priming = try source.start.subtracting(first.target.start)
        guard try nonempty.allSatisfy({ edit in
            guard let source = edit.source else { return false }
            return try source.start.subtracting(edit.target.start) == priming
        }) else { throw Failure.invalidTranslation }
        let appended = try frames(end, rate: sampleRate)
        let encoderPriming = try frames(priming, rate: sampleRate)
        let firstMedia = try frames(source.start, rate: sampleRate)
        let valid = try frames(end.subtracting(first.target.start), rate: sampleRate)
        guard framesPerPacket > 0,
              packetTable.packetCount <= UInt64(Int64.max) / UInt64(framesPerPacket) else {
            throw Failure.invalidTranslation
        }
        let coded = packetTable.packetCount * UInt64(framesPerPacket)
        guard firstMedia <= coded, valid <= coded - firstMedia else {
            throw Failure.invalidTranslation
        }
        let remainder = coded - firstMedia - valid
        guard remainder < UInt64(framesPerPacket),
              appended <= UInt64(Int64.max) - encoderPriming,
              appended + encoderPriming == firstMedia + valid else {
            throw Failure.invalidTranslation
        }
        return (appended, encoderPriming, firstMedia, valid, remainder)
    }

    static func frames(_ duration: ExactRationalV4, rate: UInt32) throws -> UInt64 {
        let value = try duration.multiplied(by: ExactRationalV4(Int64(rate), 1))
        guard value.denominator == 1, value.numerator >= 0 else {
            throw Failure.invalidTranslation
        }
        return UInt64(value.numerator)
    }

    static func rawEdits(_ table: MOViTunesGaplessMetadataV4.PacketTable) throws -> [MediaTrackEditV4] {
        guard table.movieTimescale > 0, table.mediaTimescale > 0,
              !table.edits.isEmpty else { throw Failure.invalidTranslation }
        var targetStart = ExactRationalV4.zero
        return try table.edits.enumerated().map { ordinal, edit in
            guard edit.mediaRate == 65_536, edit.movieDuration <= UInt64(Int64.max),
                  edit.mediaTime >= -1, ordinal <= Int(UInt32.max) else {
                throw Failure.invalidTranslation
            }
            let duration = try ExactRationalV4(Int64(edit.movieDuration), Int64(table.movieTimescale))
            let target = try MediaExactTimeRangeV4(start: targetStart, duration: duration)
            targetStart = try targetStart.adding(duration)
            return try MediaTrackEditV4(ordinal: UInt32(ordinal),
                source: edit.mediaTime == -1 ? nil : MediaExactTimeRangeV4(
                    start: ExactRationalV4(edit.mediaTime, Int64(table.mediaTimescale)), duration: duration),
                target: target, isEmpty: edit.mediaTime == -1)
        }
    }

    /// Rewrites exactly the three technical hexadecimal fields; whitespace,
    /// reserved fields and the original field widths remain unchanged.
    static func replacingPacketTable(
        in value: String, priming: UInt64, remainder: UInt64, valid: UInt64
    ) throws -> String {
        var bytes = Array(value.utf8)
        var ranges: [Range<Int>] = []
        var offset = 0
        while offset < bytes.count {
            if bytes[offset] == 32 || bytes[offset] == 9 { offset += 1; continue }
            let start = offset
            while offset < bytes.count && bytes[offset] != 32 && bytes[offset] != 9 {
                guard (48...57).contains(bytes[offset]) || (65...70).contains(bytes[offset])
                    || (97...102).contains(bytes[offset]) else { throw Failure.unsupportedValue }
                offset += 1
            }
            ranges.append(start..<offset)
        }
        guard ranges.count == 12, ranges[0].count == 8,
              ranges[1].count == 8, ranges[2].count == 8, ranges[3].count == 16,
              UInt64(String(decoding: bytes[ranges[0]], as: UTF8.self), radix: 16) == 0,
              priming <= UInt64(UInt32.max), remainder <= UInt64(UInt32.max) else {
            throw Failure.unsupportedValue
        }
        for (index, number) in [(1, priming), (2, remainder), (3, valid)] {
            let replacement = Array(String(format: "%0*llX", ranges[index].count, number).utf8)
            guard replacement.count == ranges[index].count else { throw Failure.unsupportedValue }
            bytes.replaceSubrange(ranges[index], with: replacement)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func validateOutputFile(at url: URL, cancellation: () throws -> Void = {}) throws {
        try validate()
        try cancellation()
        guard try MOViTunesGaplessMetadataV4.audioPacketTable(in: url,
                trackOrdinal: outputTrackOrdinal) == packetTable,
              try ASHSHA256V4(MOViTunesGaplessMetadataV4.audioPayloadSHA256(in: url,
                trackOrdinal: outputTrackOrdinal, cancellation: cancellation)) == encodedAudioPayloadSHA256 else {
            throw Failure.outputMismatch
        }
        let entries = try MOViTunesGaplessMetadataV4.originalEntries(in: url)
        guard entries.count == 1,
              ASHSHA256V4(rawData: MOViTunesGaplessMetadataV4.encodedBytes(of: entries[0])) == outputEntrySHA256,
              try MOViTunesGaplessMetadataV4.utf8Value(of: entries[0]) == outputValue else {
            throw Failure.outputMismatch
        }
    }

    func verifyMetadata(sourceURL: URL, outputURL: URL) async throws {
        try validateOutputFile(at: outputURL)
        let entries = try MOViTunesGaplessMetadataV4.originalEntries(in: sourceURL)
        guard entries.count == 1,
              ASHSHA256V4(rawData: MOViTunesGaplessMetadataV4.encodedBytes(of: entries[0])) == sourceEntrySHA256,
              try MOViTunesGaplessMetadataV4.utf8Value(of: entries[0]) == sourceValue else {
            throw Failure.metadataMismatch
        }
        let translated = try MOViTunesGaplessMetadataV4.entry(replacingUTF8Value: outputValue, in: entries[0])
        guard ASHSHA256V4(rawData: MOViTunesGaplessMetadataV4.encodedBytes(of: translated)) == outputEntrySHA256 else {
            throw Failure.metadataMismatch
        }
        let source = AVURLAsset(url: sourceURL)
        let output = AVURLAsset(url: outputURL)
        let outputTracks = try await output.load(.tracks)
        guard outputTracks.indices.contains(outputTrackOrdinal),
              let planned = identifiedPlan.plan.tracks.first(where: { $0.source.identity.stableID == trackID }),
              let expected = planned.expectedOutput else { throw Failure.outputMismatch }
        let outputFormats = try await outputTracks[outputTrackOrdinal].load(.formatDescriptions)
        let descriptors = try outputFormats.enumerated().map {
            try AVFoundationTrackGraphAdapterV4.canonicalFormatDescriptor($0.element, ordinal: UInt32($0.offset))
        }
        guard descriptors == expected.formatDescriptors else { throw Failure.outputMismatch }
        let sourceItems = try await source.load(.metadata)
        let expectedItems = try await Self.translatedMetadata(sourceItems, value: outputValue)
        guard try await AVFoundationTrackMigrationExecutorV4.canonicalAssetMetadataSHA256(sourceItems) == sourceAssetMetadataSHA256,
              try await AVFoundationTrackMigrationExecutorV4.canonicalAssetMetadataSHA256(expectedItems) == outputAssetMetadataSHA256,
              try await AVFoundationTrackMigrationExecutorV4.canonicalAssetMetadataSHA256(output.load(.metadata)) == outputAssetMetadataSHA256,
              try await AVFoundationTrackGraphAdapterV4.probe(asset: source).canonicalSHA256 == identifiedPlan.plan.sourceGraphSHA256 else {
            throw Failure.metadataMismatch
        }
    }

    static func translatedMetadata(_ items: [AVMetadataItem], value: String) async throws -> [AVMetadataItem] {
        guard items.filter({ $0.identifier?.rawValue == MOViTunesGaplessMetadataV4.identifier }).count == 1 else {
            throw Failure.metadataMismatch
        }
        return items.map { item in
            guard item.identifier?.rawValue == MOViTunesGaplessMetadataV4.identifier else { return item }
            let translated = item.mutableCopy() as! AVMutableMetadataItem
            translated.value = value as NSString
            return translated
        }
    }
}
