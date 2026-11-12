import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import Foundation

struct ProbeFailure: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func text(_ p: UnsafePointer<CChar>?) -> String { p.map(String.init(cString:)) ?? "" }
func cText<T>(_ v: T) -> String { withUnsafeBytes(of: v) { text($0.baseAddress?.assumingMemoryBound(to: CChar.self)) } }
func span(_ v: MIBSpan) -> Data { v.size == 0 ? Data() : Data(bytes: v.data!, count: v.size) }
func check(_ code: Int32, _ error: MIBError) throws { if code < 0 { throw ProbeFailure(cText(error.stage) + ": " + cText(error.message)) } }
func hashBytes(_ value: String) throws -> [UInt8] { guard value.count == 64 else { throw ProbeFailure("invalid source hash") }; let a = Array(value.utf8); return try stride(from: 0, to: 64, by: 2).map { i in guard let n = UInt8(String(bytes: a[i..<i+2], encoding: .utf8)!, radix: 16) else { throw ProbeFailure("invalid source hash") }; return n } }
func tupleArray<T, E>(_ v: T, _: E.Type) -> [E] { withUnsafeBytes(of: v) { Array($0.bindMemory(to: E.self)) } }
struct RawTime: Codable, Equatable { let value: Int64; let numerator: Int32; let denominator: Int32
 init?(_ v: MIBTime) { guard v.valid != 0 else { return nil }; value = v.value; numerator = v.base.num; denominator = v.base.den }
 var seconds: ExactRationalV4 { get throws { try ExactRationalV4(value).multiplied(by: ExactRationalV4(Int64(numerator), Int64(denominator))) } }
}
func seconds(_ t: MIBTime) throws -> ExactRationalV4? { try RawTime(t)?.seconds }
func rational(_ q: MIBRational) throws -> ExactRationalV4 { try ExactRationalV4(Int64(q.num), Int64(q.den)) }
func cm(_ q: ExactRationalV4) throws -> CMTime { guard q.denominator <= Int32.max else { throw ProbeFailure("exact rational outside CMTime scale: \(q)") }; return CMTime(value: q.numerator, timescale: Int32(q.denominator)) }
struct RawSideData: Codable, Equatable { let type: Int32; let name: String; let bytes: Data }
struct MetadataEntry: Codable, Equatable { let key: String; let value: String }
struct MatroskaTrackEvidence: Codable, Equatable { let number: String; let uid: String; let type: UInt64; let enabled: Bool; let defaultTrack: Bool; let forced: Bool; let lacing: Bool; let flagsPresent: UInt32; let codecID: String; let codecPrivate: Data; let rawEntry: Data; let entryOffset: UInt64; let videoGeometry: MatroskaVideoEvidence? }
struct MatroskaVideoEvidence: Codable, Equatable { let pixelWidth: UInt64; let pixelHeight: UInt64; let cropLeft: UInt64; let cropRight: UInt64; let cropTop: UInt64; let cropBottom: UInt64; let displayWidth: UInt64; let displayHeight: UInt64; let displayUnit: UInt64; let alphaMode: UInt64; let fieldsPresent: UInt32 }
struct OriginalProgram: Codable, Equatable { let id: Int32; let number: Int32; let flags: Int32; let discard: Int32; let pmtPID: Int32; let pcrPID: Int32; let pmtVersion: Int32; let orderedStreamOrdinals: [UInt32]; let metadata: [MetadataEntry] }
// AVStream observations come from original bytes but may be synthesized by the
// demuxer/probe; these fields are not asserted to be on-wire declarations.
struct OriginalStream: Codable, Equatable {
 let ordinal: Int32; let libraryContainerID: Int32; let codecID: Int32; let codecName: String; let codecTag: UInt32; let mediaType: Int32; let profile: Int32; let level: Int32; let disposition: Int32
 let timebase: ExactRationalV4; let nominalFrameRate: ExactRationalV4?; let realFrameRate: ExactRationalV4?; let demuxerStart: RawTime?; let demuxerDuration: RawTime?; let demuxerReportedFrames: Int64
 let width: Int32; let height: Int32; let pixelFormat: Int32; let rawDepth: Int32; let codedDepth: Int32; let colorRange: Int32; let primaries: Int32; let transfer: Int32; let matrix: Int32; let chromaLocation: Int32; let fieldOrder: Int32; let videoDelay: Int32; let sampleAspectRatio: ExactRationalV4?
 let sampleRate: Int32; let sampleFormat: Int32; let channels: Int32; let channelLayout: String; let channelOrder: Int32; let channelMask: String; let channelIDs: [Int32]; let frameSize: Int32; let initialPadding: Int32; let trailingPadding: Int32; let seekPreroll: Int32
 let extradata: Data; let sideData: [RawSideData]; let metadata: [MetadataEntry]
 let matroska: MatroskaTrackEvidence?; let enabled: Bool?; let enabledEvidence: String
}
struct SourceFacts: Codable {
 let sourceHash: ASHSHA256V4; let sourceBytes: Int64; let filename: String; let demuxer: String; let start: RawTime?; let duration: RawTime?; let metadata: [MetadataEntry]
 let asfHeader: ASFOriginalHeader?; let chapterCount: Int32; let groupCount: Int32; let programs: [OriginalProgram]; let streams: [OriginalStream]
}
struct SharedOrigin: Codable { let seconds: ExactRationalV4; let evidence: String
 func normalize(_ original: ExactRationalV4) throws -> ExactRationalV4 { try original.subtracting(seconds) }
}
struct TimingSummary: Codable {
 let kind: String; let packetCount: Int64; let frameCount: Int64; let rawMissingPTS: Int64; let rawZeroDuration: Int64; let qualifiedMissingPTS: Int64
 let rawFirstPTS: ExactRationalV4?; let rawLastPTS: ExactRationalV4?; let selectedStart: ExactRationalV4?; let selectedEnd: ExactRationalV4?; let selectedClock: String
 let audibleSamples: Int64; let decodedSamples: Int64; let skipStart: Int64; let skipEnd: Int64; let maximumAudioPTSResidual: ExactRationalV4; let audioPTSResidualWithinOneSourceTick: Bool
 let hasHDRSideData: Bool; let hasDecodedCropping: Bool; let frameDepth: Int32; let chromaLog2Width: Int32; let chromaLog2Height: Int32; let components: Int32; let rawFrameFlagsOR: Int32; let frameFactsSHA256: ASHSHA256V4; let packetFactsSHA256: ASHSHA256V4
 let decodedPixelFormat: Int32?; let decodedPixelFormatName: String?; let decodedPixelFormatFlags: UInt64?; let decodedRGB: Bool?; let decodedAlpha: Bool?
 let legacyBitDepth: UInt8?; let legacyFullRange: Bool?; let legacySubsampling: CanonicalChromaSubsamplingV4?
}
struct PacketFact: Codable { let ordinal: Int64; let originalPosition: Int64; let rawPTS: RawTime?; let rawDTS: RawTime?; let rawDuration: RawTime?; let bitstreamVOPTime: RawTime?; let vopType: Int32; let vopCount: Int32; let flags: Int32; let payloadSHA256: ASHSHA256V4; let sideData: [RawSideData] }
struct FrameFact: Codable { let ordinal: Int64; let rawPTS: RawTime?; let rawBestEffortPTS: RawTime?; let rawDuration: RawTime?; let rawPacketDTS: RawTime?; let sourcePacketOrdinal: Int64?; let bitstreamVOPTime: RawTime?; let selectedPresentation: ExactRationalV4?; let normalizedPresentation: ExactRationalV4?; let flags: Int32; let decodeErrors: Int32; let skipStart: UInt32; let skipEnd: UInt32; let skipStartReason: UInt8; let skipEndReason: UInt8; let audibleOffset: Int32; let audibleSamples: Int32; let decodedSamples: Int32; let sampleRate: Int32; let rawPixelFormat: Int32?; let rawPixelFormatName: String?; let rawPixelFormatFlags: UInt64?; let rawPixelRGB: Bool?; let rawPixelAlpha: Bool?; let rawColorRange: Int32; let rawPrimaries: Int32; let rawTransfer: Int32; let rawMatrix: Int32; let rawChromaLocation: Int32; let rawWidth: Int32; let rawHeight: Int32; let crop: [UInt64]; let sideData: [RawSideData]; let decodedPayloadSHA256: ASHSHA256V4 }
final class Lines {
 let handle: FileHandle; var hash = SHA256()
 init(_ url: URL) throws { FileManager.default.createFile(atPath: url.path, contents: nil); handle = try FileHandle(forWritingTo: url) }
 func append<T: Encodable>(_ v: T) throws { var d = try ASHCanonicalJSONV4.encode(v); d.append(10); try handle.write(contentsOf: d); hash.update(data: d) }
 func finish() throws -> ASHSHA256V4 { try handle.close(); return try ASHSHA256V4(hash.finalize().map { String(format: "%02x", $0) }.joined()) }
}
private final class OriginalProbeCancellation {
 let cancellation: (any NativeMediaInputCancellationV4)?
 init(_ cancellation: (any NativeMediaInputCancellationV4)?) { self.cancellation = cancellation }
 func check() throws { try cancellation?.check(); try Task.checkCancellation() }
}
final class OriginalProbe {
 let implementationIdentity: SoftwareInputImplementationIdentity
 let url: URL; let file: ASHStreamingFileIdentityV4; let fd: Int32; var source: OpaquePointer?; var error = MIBError(); var catalog: OpaquePointer?
 private let cancellation: OriginalProbeCancellation
 init(url: URL, cancellation: (any NativeMediaInputCancellationV4)? = nil, sourceIdentity: ASHStreamingFileIdentityV4? = nil) throws {
  self.url = url; self.cancellation = OriginalProbeCancellation(cancellation)
  try self.cancellation.check()
  implementationIdentity = try SoftwareInputImplementationIdentity.current()
  file = try sourceIdentity ?? ASHStreamingFileIdentityV4.read(url: url)
  fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW); guard fd >= 0 else { throw ProbeFailure("open original FD") }
  do {
   let bytes = try hashBytes(file.contentSHA256.rawValue); var limits = mib_default_limits()
   let callback = MIBCancellation(is_cancelled: { raw in
    guard let raw else { return 1 }
    do { try Unmanaged<OriginalProbeCancellation>.fromOpaque(raw).takeUnretainedValue().check(); return 0 } catch { return 1 }
   }, context: Unmanaged.passUnretained(self.cancellation).toOpaque())
   let code = bytes.withUnsafeBufferPointer { mib_source_open_fd_with_cancel(fd, $0.baseAddress, file.byteCount, &limits, callback, &source, &error) }
   try self.cancellation.check(); try check(code, error)
  } catch { mib_source_close(&source); Darwin.close(fd); throw error }
 }
 func checkCancellation() throws { try cancellation.check() }
 deinit { mte_close(&catalog); mib_source_close(&source); Darwin.close(fd) }
 func metadata(_ stream: Int32) throws -> [MetadataEntry] { let count = mib_metadata_count(source, stream, &error); try check(count, error); return try (0..<count).map { i in var k: UnsafePointer<CChar>?; var v: UnsafePointer<CChar>?; try check(mib_metadata_at(source, stream, i, &k, &v, &error), error); return MetadataEntry(key: text(k), value: text(v)) }.sorted { $0.key < $1.key } }
 func sourceFacts() async throws -> SourceFacts {
  try checkCancellation()
  var asset = MIBAssetFacts(); try check(mib_asset_facts(source, &asset, &error), error); var mte: [MatroskaTrackEvidence] = []; let asfHeader = text(asset.demuxer) == "asf" ? try ASFOriginalHeader.read(fd: fd, expectedBytes: file.byteCount) : nil
  if text(asset.demuxer).contains("matroska") { var e = MTEError(); let bytes = try hashBytes(file.contentSHA256.rawValue); let callback = MTECancellation(is_cancelled: { raw in
    guard let raw else { return 1 }
    do { try Unmanaged<OriginalProbeCancellation>.fromOpaque(raw).takeUnretainedValue().check(); return 0 } catch { return 1 }
   }, context: Unmanaged.passUnretained(cancellation).toOpaque())
   let code = bytes.withUnsafeBufferPointer { mte_read_fd_with_cancel(fd, $0.baseAddress, file.byteCount, callback, &catalog, &e) }; try checkCancellation(); guard code == 0 else { throw ProbeFailure("original EBML: \(cText(e.reason)) at \(e.offset)") }; var f = MTEFacts(); guard mte_facts(catalog, &f) == 0 else { throw ProbeFailure("EBML facts") }
   for i in 0..<f.count { var t = MTETrack(); guard mte_track(catalog, i, &t) == 0 else { throw ProbeFailure("EBML track") }; mte.append(MatroskaTrackEvidence(number: String(t.number), uid: String(t.uid), type: t.type, enabled: t.enabled != 0, defaultTrack: t.default_track != 0, forced: t.forced != 0, lacing: t.lacing != 0, flagsPresent: t.flags_present, codecID: text(t.codec_id), codecPrivate: t.codec_private_size == 0 ? Data() : Data(bytes: t.codec_private!, count: t.codec_private_size), rawEntry: Data(bytes: t.raw_entry!, count: t.raw_entry_size), entryOffset: t.entry_offset, videoGeometry: t.has_video == 0 ? nil : MatroskaVideoEvidence(pixelWidth: t.pixel_width, pixelHeight: t.pixel_height, cropLeft: t.crop_left, cropRight: t.crop_right, cropTop: t.crop_top, cropBottom: t.crop_bottom, displayWidth: t.display_width, displayHeight: t.display_height, displayUnit: t.display_unit, alphaMode: t.alpha_mode, fieldsPresent: t.video_fields_present))) }
  }
  // Only supplementary original-source AVFoundation metadata is consulted here.
  // No carrier URL or decoded format is used to replace original source facts.
  let native = AVURLAsset(url: url)
  let nativeTracks = (try? await native.load(.tracks)) ?? []
  var nativeEnabled: [Int32: Bool] = [:]
  for type in [AVMediaType.video, .audio] { let candidates = nativeTracks.filter { $0.mediaType == type }; if candidates.count == 1, let value = try? await candidates[0].load(.isEnabled) { nativeEnabled[type == .video ? 0 : 1] = value } }
  var sourceTypeCounts: [Int32: Int] = [:]
  for i in 0..<asset.streams { var item = MIBStreamFacts(); try check(mib_stream_facts(source, i, &item, &error), error); sourceTypeCounts[item.media_type, default: 0] += 1 }
  var streams: [OriginalStream] = []; var boundUIDs = Set<String>()
  for i in 0..<asset.streams { var s = MIBStreamFacts(); try check(mib_stream_facts(source, i, &s, &error), error); var side: [RawSideData] = []
   for j in 0..<s.side_data_count { var v = MIBSideData(); try check(mib_stream_side_data(source, i, j, &v, &error), error); side.append(RawSideData(type: v.type, name: text(v.name), bytes: span(v.bytes))) }
   let codec = text(s.codec_name); let extra = span(s.extradata); let names = ["h264":"V_MPEG4/ISO/AVC", "vp9":"V_VP9", "aac":"A_AAC", "opus":"A_OPUS"]
   let matches = mte.filter { $0.type == (s.media_type == 0 ? 1 : s.media_type == 1 ? 2 : UInt64.max) && $0.codecID == names[codec] && $0.codecPrivate == extra }
   let bound: MatroskaTrackEvidence?
   if mte.isEmpty { bound = nil } else { guard matches.count == 1, boundUIDs.insert(matches[0].uid).inserted else { throw ProbeFailure("ambiguous original TrackEntry-to-libav mapping for ordinal \(i)") }; bound = matches[0] }
   let enabled: Bool?; let evidence: String
   if let bound { enabled = bound.enabled; evidence = "original TrackEntry.FlagEnabled, explicit/default presence retained; unique type+CodecID+exact CodecPrivate binding" }
   else if text(asset.demuxer).contains("mov") { enabled = s.disposition & 1 != 0; evidence = "original MOV tkhd enabled mapped by official mov.c:5593 to AV_DISPOSITION_DEFAULT" }
   else if let value = nativeEnabled[s.media_type], sourceTypeCounts[s.media_type] == 1, [Int32(0), 1].contains(s.media_type) { enabled = value; evidence = "original URL AVAssetTrack.isEnabled; unique source media-type mapping" }
   else { enabled = nil; evidence = "unknown: bridge does not expose a proven original enabled semantic for this container" }
   streams.append(OriginalStream(ordinal: i, libraryContainerID: s.container_id, codecID: s.codec_id, codecName: codec, codecTag: s.codec_tag, mediaType: s.media_type, profile: s.profile, level: s.level, disposition: s.disposition, timebase: try rational(s.time_base), nominalFrameRate: s.average_frame_rate.num > 0 ? try rational(s.average_frame_rate) : nil, realFrameRate: s.real_frame_rate.num > 0 ? try rational(s.real_frame_rate) : nil, demuxerStart: RawTime(s.start), demuxerDuration: RawTime(s.duration), demuxerReportedFrames: s.declared_frames, width: s.width, height: s.height, pixelFormat: s.pixel_format, rawDepth: s.raw_depth, codedDepth: s.coded_depth, colorRange: s.color_range, primaries: s.primaries, transfer: s.transfer, matrix: s.matrix, chromaLocation: s.chroma_location, fieldOrder: s.field_order, videoDelay: s.video_delay, sampleAspectRatio: s.sample_aspect_ratio.num > 0 ? try rational(s.sample_aspect_ratio) : nil, sampleRate: s.sample_rate, sampleFormat: s.sample_format, channels: s.channels, channelLayout: text(s.channel_layout), channelOrder: s.channel_order, channelMask: String(s.channel_mask, radix: 16), channelIDs: Array(tupleArray(s.channel_id, Int32.self).prefix(Int(s.channels))), frameSize: s.frame_size, initialPadding: s.initial_padding, trailingPadding: s.trailing_padding, seekPreroll: s.seek_preroll, extradata: extra, sideData: side, metadata: try metadata(i), matroska: bound, enabled: enabled, enabledEvidence: evidence))
  }
  guard mte.count == boundUIDs.count else { throw ProbeFailure("original TrackEntry inventory not fully mapped") }
  var programs: [OriginalProgram] = []
  for i in 0..<asset.programs { var p = MIBProgramFacts(); try check(mib_program_facts(source, i, &p, &error), error); var entries: [MetadataEntry] = []; let count = mib_program_metadata_count(source, i, &error); try check(count, error)
   for j in 0..<count { var k: UnsafePointer<CChar>?; var v: UnsafePointer<CChar>?; try check(mib_program_metadata_at(source, i, j, &k, &v, &error), error); entries.append(MetadataEntry(key: text(k), value: text(v))) }
   programs.append(OriginalProgram(id: p.id, number: p.program_number, flags: p.flags, discard: p.discard, pmtPID: p.pmt_pid, pcrPID: p.pcr_pid, pmtVersion: p.pmt_version, orderedStreamOrdinals: p.stream_count == 0 ? [] : Array(UnsafeBufferPointer(start: p.stream_ordinals, count: Int(p.stream_count))), metadata: entries.sorted { $0.key < $1.key }))
  }
  return SourceFacts(sourceHash: file.contentSHA256, sourceBytes: file.byteCount, filename: url.lastPathComponent, demuxer: text(asset.demuxer), start: RawTime(asset.start), duration: RawTime(asset.duration), metadata: try metadata(-1), asfHeader: asfHeader, chapterCount: asset.chapters, groupCount: asset.groups, programs: programs, streams: streams)
 }
 func timeline(_ stream: OriginalStream, origin: SharedOrigin, directory: URL) throws -> TimingSummary {
  var cursor: OpaquePointer?; let packets = try Lines(directory.appendingPathComponent("stream-\(stream.ordinal)-packets.jsonl")); var packetCount: Int64 = 0; var legacy = stream.codecName == "mpeg4" ? LegacyVideoSamplingFacts.mpeg4(stream.extradata) : nil; var everyJPEGIsJFIF = true; var hasHDR = stream.sideData.contains { $0.name.lowercased().contains("hdr") || $0.name.lowercased().contains("mastering") || $0.name.lowercased().contains("content light") }; var hasCropping = false
  try check(mib_cursor_open(source, stream.ordinal, 0, &cursor, &error), error)
  defer { mib_cursor_close(&cursor) }
  while true { try checkCancellation(); var p = MIBPacket(); let code = mib_next_packet(cursor, &p, &error); try check(code, error); if code == 0 { break }; var side: [RawSideData] = []
   for j in 0..<p.side_data_count { var v = MIBSideData(); try check(mib_packet_side_data(cursor, j, &v, &error), error); side.append(RawSideData(type: v.type, name: text(v.name), bytes: span(v.bytes))) }
   hasHDR = hasHDR || side.contains { $0.name.lowercased().contains("hdr") || $0.name.lowercased().contains("mastering") || $0.name.lowercased().contains("content light") }; let data = span(p.bytes)
   if stream.codecName == "mjpeg" { if let current = LegacyVideoSamplingFacts.jpeg(data) { if let legacy, current != legacy { throw ProbeFailure("changing original JFIF sampling") }; legacy = current } else { everyJPEGIsJFIF = false } }
   try packets.append(PacketFact(ordinal: p.identity.ordinal, originalPosition: p.identity.position, rawPTS: RawTime(p.identity.pts), rawDTS: RawTime(p.identity.dts), rawDuration: RawTime(p.identity.duration), bitstreamVOPTime: RawTime(p.identity.vop_time), vopType: p.identity.vop_type, vopCount: p.identity.vop_count, flags: p.identity.flags, payloadSHA256: ASHSHA256V4(rawData: data), sideData: side)); packetCount += 1
  }; mib_cursor_close(&cursor); let packetSHA = try packets.finish(); if stream.codecName == "mjpeg" && !everyJPEGIsJFIF { legacy = nil }
  let lines = try Lines(directory.appendingPathComponent("stream-\(stream.ordinal)-frames.jsonl")); try check(mib_cursor_open(source, stream.ordinal, stream.mediaType == 0 ? 1 : 2, &cursor, &error), error); defer { mib_cursor_close(&cursor) }
  var count: Int64 = 0, missing: Int64 = 0, zero: Int64 = 0, qualifiedMissing: Int64 = 0, decodedSamples: Int64 = 0, audibleSamples: Int64 = 0, skipStart: Int64 = 0, skipEnd: Int64 = 0
  var firstRaw: ExactRationalV4?, lastRaw: ExactRationalV4?, start: ExactRationalV4?, end: ExactRationalV4?, previous: ExactRationalV4?, audioAnchor: ExactRationalV4?, maximumResidual = ExactRationalV4.zero
  var depth: Int32 = 0, chromaW: Int32 = 0, chromaH: Int32 = 0, components: Int32 = 0, flags: Int32 = 0; var formatSignature: [Int32]?
  var decodedPixelFormat: Int32?, decodedPixelFormatName: String?, decodedPixelFormatFlags: UInt64?, decodedRGB: Bool?, decodedAlpha: Bool?
  let isAudio = stream.mediaType == 1
  while true { try checkCancellation(); var f = MIBDecodedFrame(); let code = mib_next_frame(cursor, &f, &error); try check(code, error); if code == 0 { break }; let raw = try seconds(f.pts); if raw == nil { missing += 1 }; if firstRaw == nil { firstRaw = raw }; lastRaw = raw
   if (try seconds(f.duration)) == .zero || f.duration.valid == 0 { zero += 1 }
   if f.decode_error_flags != 0 { throw ProbeFailure("decoder reported original frame corruption") }
   var selected = raw
   if !isAudio && stream.codecName == "mpeg4" { guard f.has_packet_identity != 0, f.packet_identity.vop_count == 1, let value = try seconds(f.packet_identity.vop_time) else { throw ProbeFailure("missing qualified original MPEG4 VOP clock") }; selected = value }
   var side: [RawSideData] = []; for j in 0..<f.side_data_count { var v = MIBSideData(); try check(mib_frame_side_data(cursor, j, &v, &error), error); side.append(RawSideData(type: v.type, name: text(v.name), bytes: span(v.bytes))) }
   hasHDR = hasHDR || side.contains { $0.name.lowercased().contains("hdr") || $0.name.lowercased().contains("mastering") || $0.name.lowercased().contains("content light") }; hasCropping = hasCropping || f.crop_left != 0 || f.crop_right != 0 || f.crop_top != 0 || f.crop_bottom != 0
   if isAudio {
    guard f.sample_rate == stream.sampleRate, f.channels == stream.channels else { throw ProbeFailure("changing decoded audio layout/rate") }
    decodedSamples += Int64(f.decoded_samples); skipStart += Int64(f.skip_start); skipEnd += Int64(f.skip_end)
    if f.audible_samples > 0 {
     let observed = try raw?.adding(ExactRationalV4(Int64(f.audible_offset), Int64(f.sample_rate)))
     if audioAnchor == nil { guard let observed else { throw ProbeFailure("missing first audible PCM anchor") }; audioAnchor = observed; start = observed }
     selected = try audioAnchor!.adding(ExactRationalV4(audibleSamples, Int64(f.sample_rate)))
     if let observed { let delta = try observed.subtracting(selected!); let absolute = delta < .zero ? try delta.negated() : delta; maximumResidual = max(maximumResidual, absolute) }
     audibleSamples += Int64(f.audible_samples); end = try audioAnchor!.adding(ExactRationalV4(audibleSamples, Int64(f.sample_rate)))
    } else { selected = nil }
   } else {
    let signature = [f.pixel_format, f.pixel_is_rgb, f.pixel_has_alpha, f.width, f.height, f.depth, f.components, f.chroma_log2_width, f.chroma_log2_height, f.color_range, f.primaries, f.transfer, f.matrix, f.chroma_location]
    if let formatSignature, formatSignature != signature { throw ProbeFailure("video semantics change within original source") }; formatSignature = signature
    decodedPixelFormat = f.pixel_format; decodedPixelFormatName = text(f.pixel_format_name); decodedPixelFormatFlags = f.pixel_format_flags; decodedRGB = f.pixel_is_rgb != 0; decodedAlpha = f.pixel_has_alpha != 0
    depth = f.depth; chromaW = f.chroma_log2_width; chromaH = f.chroma_log2_height; components = f.components; flags |= f.flags
    guard let selected else { qualifiedMissing += 1; throw ProbeFailure("video presentation time unknown") }
    if let previous, selected <= previous { throw ProbeFailure("selected original video display times are not strictly ordered") }
    if start == nil { start = selected }; previous = selected
    if let duration = try seconds(f.duration), duration.isPositive { end = try selected.adding(duration) } else { end = nil }
   }
   let payload = isAudio ? span(f.s32_interleaved) : span(f.image_bytes)
   try lines.append(FrameFact(ordinal: f.ordinal, rawPTS: RawTime(f.pts), rawBestEffortPTS: RawTime(f.best_effort_pts), rawDuration: RawTime(f.duration), rawPacketDTS: RawTime(f.packet_dts), sourcePacketOrdinal: f.has_packet_identity != 0 ? f.packet_identity.ordinal : nil, bitstreamVOPTime: RawTime(f.packet_identity.vop_time), selectedPresentation: selected, normalizedPresentation: try selected.map(origin.normalize), flags: f.flags, decodeErrors: f.decode_error_flags, skipStart: f.skip_start, skipEnd: f.skip_end, skipStartReason: f.skip_start_reason, skipEndReason: f.skip_end_reason, audibleOffset: f.audible_offset, audibleSamples: f.audible_samples, decodedSamples: f.decoded_samples, sampleRate: f.sample_rate, rawPixelFormat: isAudio ? nil : f.pixel_format, rawPixelFormatName: isAudio ? nil : text(f.pixel_format_name), rawPixelFormatFlags: isAudio ? nil : f.pixel_format_flags, rawPixelRGB: isAudio ? nil : f.pixel_is_rgb != 0, rawPixelAlpha: isAudio ? nil : f.pixel_has_alpha != 0, rawColorRange: f.color_range, rawPrimaries: f.primaries, rawTransfer: f.transfer, rawMatrix: f.matrix, rawChromaLocation: f.chroma_location, rawWidth: f.width, rawHeight: f.height, crop: [UInt64(f.crop_left), UInt64(f.crop_right), UInt64(f.crop_top), UInt64(f.crop_bottom)], sideData: side, decodedPayloadSHA256: ASHSHA256V4(rawData: payload))); count += 1
  }
  let frameSHA = try lines.finish(); guard !isAudio || maximumResidual <= stream.timebase else { throw ProbeFailure("audio original timestamps disagree with continuous PCM sample clock beyond one source tick") }
  return TimingSummary(kind: isAudio ? "audio" : "video", packetCount: packetCount, frameCount: count, rawMissingPTS: missing, rawZeroDuration: zero, qualifiedMissingPTS: qualifiedMissing, rawFirstPTS: firstRaw, rawLastPTS: lastRaw, selectedStart: start, selectedEnd: end, selectedClock: isAudio ? "audible PCM sample counter anchored to first original eligible PTS; all observed offsets validated within one original source tick; missing raw PTS retained" : stream.codecName == "mpeg4" ? "explicit qualified original packet-bound MPEG4 VOP clock; raw decoder PTS retained" : "original decoded source PTS with original source tick quantization", audibleSamples: audibleSamples, decodedSamples: decodedSamples, skipStart: skipStart, skipEnd: skipEnd, maximumAudioPTSResidual: maximumResidual, audioPTSResidualWithinOneSourceTick: maximumResidual <= stream.timebase, hasHDRSideData: hasHDR, hasDecodedCropping: hasCropping, frameDepth: depth, chromaLog2Width: chromaW, chromaLog2Height: chromaH, components: components, rawFrameFlagsOR: flags, frameFactsSHA256: frameSHA, packetFactsSHA256: packetSHA, decodedPixelFormat: decodedPixelFormat, decodedPixelFormatName: decodedPixelFormatName, decodedPixelFormatFlags: decodedPixelFormatFlags, decodedRGB: decodedRGB, decodedAlpha: decodedAlpha, legacyBitDepth: legacy?.bitDepth, legacyFullRange: legacy?.fullRange, legacySubsampling: legacy?.subsampling)
 }
}
struct VideoInfoRecord: Codable { let url: String; let duration: ExactRationalV4; let encodedWidth: Int; let encodedHeight: Int; let codecFourCC: UInt32?; let nominalFrameRate: String?; let audioTrackCount: Int; let videoTrackCount: Int; let readableBySoftwareCursor: Bool; let nativePlayable: Bool; let primaries: String?; let transfer: String?; let matrix: String?; let fullRange: Bool?; let dynamicRange: String }
struct ProcessingPolicyChoice: Codable, Equatable { let path: String; let rawValue: String; let effectiveValue: String; let evidence: String }
struct ProjectionReport: Codable {
 let source: SourceFacts; let sharedOrigin: SharedOrigin; let timelines: [TimingSummary]
 let canonical: CanonicalMediaStateV4?; let trackGraph: MediaTrackGraphV4?; let canonicalSHA256: ASHSHA256V4?; let trackGraphSHA256: ASHSHA256V4?; let originalFactsSHA256: ASHSHA256V4
 let processingPolicy: [ProcessingPolicyChoice]; let processingPolicySHA256: ASHSHA256V4; let videoInfo: VideoInfoRecord?; let admission: String; let reasons: [String]
}
struct TypedProjection { let state: CanonicalMediaStateV4?; let graph: MediaTrackGraphV4?; let videoInfo: VideoInfo?; let report: ProjectionReport }
enum OriginalFactsTranslator {
 static func translate(probe: OriginalProbe, source: SourceFacts, origin: SharedOrigin, timings: [TimingSummary], bookmarkHash: ASHSHA256V4) async throws -> TypedProjection {
  guard timings.count == source.streams.count,
        source.streams.map(\.ordinal) == (0..<source.streams.count).map({ Int32($0) }) else {
   throw ProbeFailure("original source/timing inventory or ordinal mismatch")
  }
  let sourceSHA = try ASHCanonicalJSONV4.hash(source, domain: "mirmir-original-source-facts-prototype-v1")
  var tracks: [CanonicalMediaTrackV4] = [], nodes: [MediaTrackNodeV4] = [], observations: [CanonicalMediaObservationV4] = [], reasons: [String] = [], policies: [ProcessingPolicyChoice] = []
  func reject(_ path: String, _ why: String) { reasons.append(path + ": " + why); observations.append(CanonicalMediaObservationV4(severity: .unsupported, code: .missingRequiredValue, path: path, observedValue: why)) }
  func warning(_ path: String, _ why: String) { observations.append(CanonicalMediaObservationV4(severity: .warning, code: .missingRequiredValue, path: path, observedValue: why)) }
  func policy(_ path: String, _ raw: String, _ value: String, _ evidence: String) {
   policies.append(ProcessingPolicyChoice(path: path, rawValue: raw, effectiveValue: value, evidence: evidence))
   warning(path, "explicit operating interpretation \(value); raw \(raw) retained; \(evidence)")
  }
  if source.chapterCount != 0 || source.groupCount != 0 { reject("asset.relationships", "chapter/group inventory not projected yet; raw counts retained") }
  if !source.programs.isEmpty {
   if source.programs.count == 1, source.programs[0].orderedStreamOrdinals.sorted() == source.streams.map({ UInt32($0.ordinal) }).sorted() {
    policy("asset.programs", "one complete original MPEG-TS program", "select sole program; preserve ordered membership and all raw program metadata", "single-program original inventory has no alternate-program selection ambiguity; program is not mislabeled as an alternate track group")
   } else { reject("asset.programs", "multiple/incomplete program selection requires explicit policy; original relationships retained") }
  }
  var videoInfo: VideoInfo?, videoRecord: VideoInfoRecord?
  for (s, t) in zip(source.streams, timings) {
   let root = "tracks[\(s.ordinal)]"; let identifier = "source-\(source.sourceHash.rawValue.prefix(16))-track-" + (s.matroska.map { "uid-\($0.uid)" } ?? "ordinal-\(s.ordinal)")
   let enabled: Bool
   if let original = s.enabled { enabled = original }
   else if let asf = source.asfHeader, asf.permitsIndependentActivationPolicy,
           let original = asf.streams.first(where: { Int32($0.number) == s.libraryContainerID }),
           original.flags & 0x8000 == 0, original.timeOffset100ns == "0",
           original.typeGUID == (s.mediaType == 0 ? "c0ef19bc4d5bcf11a8fd00805f5c442b" : s.mediaType == 1 ? "409e69f84d5bcf11a8fd00805f5c442b" : "unsupported"),
           Set(asf.streams.map({ Int32($0.number) })) == Set(source.streams.map(\.libraryContainerID)) {
    enabled = true
    policy(root + ".enabled", "ASF has no track-enabled declaration; original flags=\(original.flags)", "active for processing", "Microsoft ASF Stream Properties/Extended Stream flags and complete independent unencrypted/free-standing stream inventory; no mutual-exclusion or unknown selection object; raw enabled remains absent")
   } else { reject(root + ".enabled", s.enabledEvidence); continue }
   guard [Int32(0), 1].contains(s.mediaType) else { reject(root + ".kind", "unknown original media type \(s.mediaType)"); continue }
   guard let observedStart = t.selectedStart, let observedEnd = t.selectedEnd else { reject(root + ".timing", "no exact complete selected presentation extent; no duration fabricated"); continue }
   let demuxerStart = try s.demuxerStart?.seconds
   let originalStart = demuxerStart ?? observedStart
   let duration: ExactRationalV4
   if let declared = try s.demuxerDuration?.seconds { duration = declared }
   else { duration = try observedEnd.subtracting(observedStart); warning(root + ".duration", "original stream duration absent; typed duration is explicitly derived from complete selected source presentation extent \(duration); raw absence retained") }
   if originalStart != observedStart {
    let offset = try originalStart.subtracting(observedStart); let absolute = offset < .zero ? try offset.negated() : offset
    if s.mediaType == 1 && absolute <= s.timebase {
     policy(root + ".start", "demuxer start \(originalStart), audible anchor \(observedStart)", "retain both; PCM clock uses exact audible anchor", "quantized original timestamp differs by at most one original tick after exact codec skip; no trim/pad or per-stream zero reset")
    } else if s.mediaType == 1 && source.asfHeader != nil && t.skipStart > 0 {
     policy(root + ".start", "demuxer start \(originalStart), audible anchor \(observedStart)", "retain demuxer span and exact sample clock with original codec pre-skip", "complete native PCM skip evidence; all available subsequent timestamps agree within one original tick; missing terminal PTS remains explicitly recorded")
    } else { reject(root + ".start", "source demuxer/decoded starts differ beyond qualified clock policy") }
   }
   let normalizedStart = try origin.normalize(originalStart)
   let streamMetadata = try ASHCanonicalJSONV4.encode(s)
   let timingMetadata = try ASHCanonicalJSONV4.encode(t)
   var metadata = [CanonicalMetadataValueV4(key: "original-stream-facts", dataType: "application/vnd.mirmir.original-stream-facts.v1", locale: nil, valueSHA256: ASHSHA256V4(rawData: streamMetadata)), CanonicalMetadataValueV4(key: "original-stream-timing", dataType: "application/vnd.mirmir.original-stream-timing.v1", locale: nil, valueSHA256: ASHSHA256V4(rawData: timingMetadata))]
   let kind: CanonicalMediaTrackKindV4 = s.mediaType == 0 ? .video : .audio
   let nodeKind: MediaTrackKindV4 = s.mediaType == 0 ? .video : .audio
   let mediaType = s.mediaType == 0 ? "fourcc_76696465" : "fourcc_736f756e"
   let codec = "libav-codec-\(s.codecID)-\(s.codecName)"
   var video: CanonicalVideoStateV4?
   if s.mediaType == 0 {
    let declaredPAR = s.sampleAspectRatio
    let matroskaVideo = s.matroska?.videoGeometry
    let resolvedPAR: ExactRationalV4?
    if let declaredPAR { resolvedPAR = declaredPAR }
    else if let g = matroskaVideo, g.displayUnit == 0, g.pixelWidth == UInt64(s.width), g.pixelHeight == UInt64(s.height), g.cropLeft == 0, g.cropRight == 0, g.cropTop == 0, g.cropBottom == 0, g.displayWidth > 0, g.displayHeight > 0, g.displayWidth <= Int64.max, g.displayHeight <= Int64.max {
     resolvedPAR = try ExactRationalV4(Int64(g.displayWidth), Int64(g.pixelWidth)).divided(by: ExactRationalV4(Int64(g.displayHeight), Int64(g.pixelHeight)))
     warning(root + ".pixel_aspect_ratio", "libav SAR absent; original Matroska pixel/display geometry and normative defaults resolve exact PAR; raw absence retained")
    } else if source.asfHeader != nil && s.codecName == "wmv2" {
     resolvedPAR = .one
     policy(root + ".pixel_aspect_ratio", "unspecified source SAR", "1:1 working geometry", "Microsoft Uncompressed Video Media Types fixes missing PAR to square; AVCanonicalMediaStateAdapterV4.pixelAspectRatio uses the same explicit geometry default; no source declaration asserted")
    } else { resolvedPAR = nil }
    guard let par = resolvedPAR, par.isPositive else { reject(root + ".pixel_aspect_ratio", "original aspect ratio is unknown"); continue }
    guard par == .one else { reject(root + ".presentation_geometry", "non-square source aspect requires exact geometry projection; raw ratio retained"); continue }
    if t.hasDecodedCropping { reject(root + ".crop", "decoded crop requires exact aperture projection"); continue }
    if s.sideData.contains(where: { $0.name.lowercased().contains("display matrix") }) { reject(root + ".transform", "original display matrix retained raw; exact transform projection required"); continue }
    let subsampling: CanonicalChromaSubsamplingV4
    if t.decodedRGB == true { subsampling = .rgb }
    else if let value = t.legacySubsampling { subsampling = value }
    else if t.components == 1 { subsampling = .monochrome }
    else if t.chromaLog2Width == 1 && t.chromaLog2Height == 1 { subsampling = .yuv420 }
    else if t.chromaLog2Width == 1 && t.chromaLog2Height == 0 { subsampling = .yuv422 }
    else if t.chromaLog2Width == 0 && t.chromaLog2Height == 0 { subsampling = .yuv444 }
    else { subsampling = .unknown; reject(root + ".chroma", "unsupported original decoded sampling geometry") }
    let range: CanonicalPixelRangeV4
    if let full = t.legacyFullRange { range = full ? .full : .video }
    else if s.colorRange == 1 { range = .video }
    else if s.colorRange == 2 { range = .full }
    else if s.colorRange == 0 && s.codecName == "wmv2" {
     range = .video
     policy(root + ".range", "original color_range=0 unspecified", "limited-range decoder/display interpretation", "qualified WMV2 profile: official Microsoft YUV studio-range guidance; upstream swscale default; six known-code probes exact default=explicit limited601; source intent remains unknown")
    } else { range = .unknown; reject(root + ".range", "unqualified source range") }
    var siting: CanonicalChromaSitingV4
    if subsampling == .yuv444 || subsampling == .monochrome || subsampling == .rgb { siting = .notApplicable }
    else { siting = [1: .left, 2: .center, 3: .topLeft, 4: .top, 5: .bottomLeft, 6: .bottom][Int(s.chromaLocation)] ?? .unknown; if siting == .unknown && s.chromaLocation == 0 { siting = .center; policy(root + ".chroma_siting", "unspecified original source location", "center operating position", "FFmpeg8.1.2 libswscale/graph.c313-314 defaults unspecified chroma location to center; raw source declaration retained") } }
    var primaries: String = [1: "ITU_R_709_2", 5: "EBU_3213", 6: "SMPTE_C", 9: "ITU_R_2020" ][Int(s.primaries)] ?? "unknown"
    var transfer: String = [1: "ITU_R_709_2", 6: "ITU_R_709_2", 13: "sRGB", 16: "SMPTE_ST_2084_PQ", 18: "ITU_R_2100_HLG"][Int(s.transfer)] ?? "unknown"
    var matrix: String = [0: "Identity", 1: "ITU_R_709_2", 5: "ITU_R_601_4", 6: "ITU_R_601_4", 9: "ITU_R_2020"][Int(s.matrix)] ?? "unknown"
    if !t.hasHDRSideData && t.frameDepth == 8 {
     if primaries == "unknown" && s.primaries == 2 { primaries = "ITU_R_709_2"; policy(root + ".color.primaries", "unspecified", primaries, "named SDR rendering profile target-relative default; source primaries not asserted; qualified WMV Swift sample-buffer profile and same untransformed eight-bit working surface") }
     if transfer == "unknown" && s.transfer == 2 { transfer = "ITU_R_709_2"; policy(root + ".color.transfer", "unspecified", transfer, "named SDR rendering profile target-relative default; source transfer not asserted; no HDR side data and exact original eight-bit decode retained") }
     if matrix == "unknown" && s.matrix == 2 { matrix = "ITU_R_601_4"; policy(root + ".color.matrix", "unspecified", matrix, "FFmpeg8.1.2 libswscale/format.c1356 unspecified-YCbCr default uses BT470BG/BT601 coefficients; raw matrix retained") }
    }
    for (name, value) in [("primaries", primaries), ("transfer", transfer), ("matrix", matrix)] where value == "unknown" { reject(root + ".color." + name, "unqualified reserved/unknown source value") }
    let scan: CanonicalScanStateV4
    if s.fieldOrder == 1 || s.codecName == "mpeg4" && t.legacyBitDepth != nil { scan = CanonicalScanStateV4(fieldCount: 1, dominance: .none, cadence: .progressive) }
    else if s.codecName == "wmv2" && t.rawFrameFlagsOR & 8 == 0 && t.frameCount > 0 {
     scan = CanonicalScanStateV4(fieldCount: 1, dominance: .none, cadence: .progressive)
     policy(root + ".scan", "source fieldOrder unspecified", "progressive complete-frame decoder contract", "WMV2 -> msmpeg4/h263 -> ff_mpv_common_defaults progressive_frame/sequence=1; mpegvideo_dec frame flags checked across every original frame; raw fieldOrder retained")
    } else { reject(root + ".scan", "unqualified unknown source scan"); continue }
    let depth = t.legacyBitDepth ?? UInt8(exactly: s.rawDepth > 0 ? s.rawDepth : t.frameDepth)
    guard let depth, (1...16).contains(depth) else { reject(root + ".depth", "unknown source component precision"); continue }
    // Opaque surface policies below are restricted to qualified codec/container
    // inventories; unqualified auxiliary-alpha semantics remain blocking.
    let alpha: CanonicalAlphaModelV4
    if t.decodedAlpha == true { alpha = .unknown; reject(root + ".alpha", "original decoded alpha association requires an explicit preservation/conversion policy") }
    else if let g = matroskaVideo, g.alphaMode == 0 { alpha = .none }
    else if t.components == 3 && ["mpeg2video", "mpeg4", "mjpeg", "wmv2"].contains(s.codecName) {
     alpha = .none
     policy(root + ".alpha", "three-component supported codec and complete original stream inventory", "opaque processing surface", "MPEG4 rectangular VOL/JPEG three-component SOF or MPEG2/WMV2 decoder three-plane codec contract; exact original metadata retained; no auxiliary alpha stream discarded")
    } else { alpha = .unknown; reject(root + ".alpha", "unqualified original alpha association") }
    let color = CanonicalColorStateV4(primaries: primaries, transferFunction: transfer, matrix: matrix, masteringDisplay: nil, contentLightLevel: nil, dynamicHDRMetadata: [])
    let raster = CanonicalRasterV4(width: Int64(s.width), height: Int64(s.height))
    video = CanonicalVideoStateV4(encodedRaster: raster, presentationRaster: raster, preferredTransform: .identity, cleanAperture: nil, pixelAspectRatio: par, pixel: CanonicalPixelStateV4(formatID: "encoded-\(codec)", bitDepth: depth, range: range, chromaSubsampling: subsampling, chromaSiting: siting, alphaModel: alpha), color: color, scan: scan)
    let size = CGSize(width: Int(s.width), height: Int(s.height)); let exactVideoDuration = try observedEnd.subtracting(observedStart)
    let nativePlayable = (try? await AVURLAsset(url: probe.url).load(.isPlayable)) ?? false
    let colorInfo = VideoColorInfo(colorPrimaries: primaries == "unknown" ? nil : primaries, transferFunction: transfer == "unknown" ? nil : transfer, yCbCrMatrix: matrix == "unknown" ? nil : matrix, bitDepth: Int(depth), pixelFormat: nil, isFullRange: range == .unknown ? nil : range == .full, fieldCount: Int(scan.fieldCount), fieldDetail: nil, alphaModel: alpha, hasMasteringDisplayMetadata: false, hasContentLightLevelMetadata: false, dynamicRange: transfer == "unknown" ? .unknown : [16,18].contains(Int(s.transfer)) ? .hdr : .sdr)
    let nominal = s.nominalFrameRate.map { Float($0.numerator) / Float($0.denominator) }
    let codecTagBytes = (0..<4).map { UInt8(truncatingIfNeeded: s.codecTag >> ($0 * 8)) }; let originalFourCC: UInt32? = s.codecTag != 0 && codecTagBytes.allSatisfy { (0x20...0x7e).contains($0) } ? s.codecTag.byteSwapped : nil
    let info = VideoInfo(url: probe.url, duration: try cm(exactVideoDuration), geometry: VideoGeometry(encodedSize: size, naturalSize: size, presentationSize: size, displaySize: size, preferredTransform: .identity, cleanAperture: nil, pixelAspectRatio: VideoPixelAspectRatio(horizontalSpacing: Int(par.numerator), verticalSpacing: Int(par.denominator))), nominalFrameRate: nominal, minimumFrameDuration: nil, estimatedFrameCount: Int(exactly: t.frameCount), estimatedDataRate: nil, codecFourCC: originalFourCC, hasAudio: source.streams.contains { $0.mediaType == 1 }, audioTrackCount: source.streams.filter { $0.mediaType == 1 }.count, videoTrackCount: source.streams.filter { $0.mediaType == 0 }.count, isReadable: true, isPlayable: nativePlayable, fileSizeBytes: source.sourceBytes, color: colorInfo)
    videoInfo = info
    videoRecord = VideoInfoRecord(url: info.url.path, duration: exactVideoDuration, encodedWidth: Int(s.width), encodedHeight: Int(s.height), codecFourCC: originalFourCC, nominalFrameRate: s.nominalFrameRate?.description, audioTrackCount: info.audioTrackCount, videoTrackCount: info.videoTrackCount, readableBySoftwareCursor: info.isReadable, nativePlayable: info.isPlayable, primaries: info.color.colorPrimaries, transfer: info.color.transferFunction, matrix: info.color.yCbCrMatrix, fullRange: info.color.isFullRange, dynamicRange: info.color.dynamicRange.rawValue)
   }
   let rawRange = try MediaExactTimeRangeV4(start: originalStart, duration: duration)
   let targetRange = try MediaExactTimeRangeV4(start: normalizedStart, duration: duration)
   let edits = [try MediaTrackEditV4(ordinal: 0, source: rawRange, target: targetRange, isEmpty: false)]
   let canonicalEdit = CanonicalMediaEditV4(ordinal: 0, sourceStart: originalStart, sourceDuration: duration, timelineStart: normalizedStart, rate: .one)
   let language = s.metadata.first { $0.key == "language" }?.value
   // Matroska default/forced/lacing are container flags, not writable native
   // media characteristics. Their exact values/presence stay in original facts.
   let roles: [String] = []
   let streamPolicies = policies.filter { $0.path.hasPrefix(root + ".") }
   metadata.append(CanonicalMetadataValueV4(key: "processing-policy", dataType: "application/vnd.mirmir.original-source-operating-policy.v1", locale: nil, valueSHA256: ASHSHA256V4(rawData: try ASHCanonicalJSONV4.encode(streamPolicies))))
   metadata.sort { $0.key < $1.key }
   tracks.append(CanonicalMediaTrackV4(identity: CanonicalTrackIdentityV4(ordinal: UInt32(s.ordinal), persistentID: identifier), enabled: enabled, kind: kind, languageTag: language, roleIDs: roles.sorted(), codecID: codec, timebase: s.timebase, duration: duration, edits: [canonicalEdit], metadata: metadata, video: video))
   let descriptor = try MediaTrackFormatDescriptorV4(ordinal: 0, mediaTypeID: mediaType, mediaSubtypeID: "libav_codec_\(s.codecID)", canonicalFingerprint: ASHSHA256V4(rawData: streamMetadata), completeness: .partial, videoRaster: video?.encodedRaster)
   let physicalID = s.matroska.flatMap { Int32($0.number) } ?? (s.libraryContainerID != 0 ? s.libraryContainerID : nil)
   nodes.append(try MediaTrackNodeV4(identity: MediaTrackIdentityV4(ordinal: UInt32(s.ordinal), stableID: MediaTrackStableIDV4(identifier), containerTrackID: physicalID), enabled: enabled, kind: nodeKind, sourceMediaTypeID: mediaType, language: MediaTrackLanguageV4(languageCode: language, extendedLanguageTag: nil), roleIDs: roles.sorted(), timebase: s.timebase, timeRange: targetRange, edits: edits, formatDescriptors: [descriptor], metadataFingerprint: ASHSHA256V4(rawData: try ASHCanonicalJSONV4.encode(metadata))))
  }
  // The virtual canonical metadata track follows the existing domain pattern.
  // The graph retains the same asset fingerprint in diagnostics because its
  // current model has no asset-metadata node contract.
  if let assetDuration = try source.duration?.seconds {
   tracks.append(CanonicalMediaTrackV4(identity: CanonicalTrackIdentityV4(ordinal: UInt32(source.streams.count), persistentID: "virtual-original-asset-metadata"), enabled: true, kind: .auxiliaryMetadata, languageTag: nil, roleIDs: ["asset-level"], codecID: "original-container-facts", timebase: try ExactRationalV4(1, 1_000_000), duration: assetDuration, edits: [], metadata: [CanonicalMetadataValueV4(key: "original-source-facts", dataType: "application/vnd.mirmir.original-source-facts.v1", locale: nil, valueSHA256: sourceSHA), CanonicalMetadataValueV4(key: "processing-policy", dataType: "application/vnd.mirmir.original-source-operating-policy.v1", locale: nil, valueSHA256: ASHSHA256V4(rawData: try ASHCanonicalJSONV4.encode(policies)))], video: nil))
  } else { reject("asset.duration", "original duration absent; no asset metadata duration fabricated") }
  if !nodes.contains(where: { $0.kind == .video && $0.enabled }) { reject("asset.video_selection", "no active video stream under original flags and qualified selection policy") }
  let complete = nodes.count == source.streams.count
  let state = complete ? try CanonicalMediaStateV4(input: CanonicalInputIdentityV4(contentSHA256: source.sourceHash, byteCount: source.sourceBytes, fileName: source.filename, bookmarkReference: "prototype-original-source", bookmarkDocumentSHA256: bookmarkHash), tracks: tracks, observations: Array(Set(observations)).sorted()) : nil
  let diagnostics = reasons.map { MediaTrackDiagnosticV4(severity: .incompatible, code: .unknownFormatProperty, path: "original-source-projection", observedValue: $0) } + [MediaTrackDiagnosticV4(severity: .information, code: .unknownFormatProperty, path: "asset.original_facts_identity", observedValue: sourceSHA.rawValue)]
  let graph = complete ? try MediaTrackGraphV4(tracks: nodes, groups: [], associations: [], diagnostics: Array(Set(diagnostics)).sorted()) : nil
  let report = ProjectionReport(source: source, sharedOrigin: origin, timelines: timings, canonical: state, trackGraph: graph, canonicalSHA256: try state?.canonicalSHA256, trackGraphSHA256: try graph?.canonicalSHA256, originalFactsSHA256: sourceSHA, processingPolicy: policies, processingPolicySHA256: ASHSHA256V4(rawData: try ASHCanonicalJSONV4.encode(policies)), videoInfo: videoRecord, admission: reasons.isEmpty && complete ? "processable-under-explicit-qualified-operating-profile" : "rejected-with-specific-original-fact-gaps", reasons: reasons.sorted())
  return TypedProjection(state: state, graph: graph, videoInfo: videoInfo, report: report)
 }
}
