import Darwin
import Foundation

struct SoftwareInputImplementationImage: Codable, Equatable, Sendable {
    let role: String
    let bytes: Int64
    let SHA256: ASHSHA256V4
}

struct SoftwareInputImplementationLibrary: Codable, Equatable, Sendable {
    let role: String
    let compiledVersion: UInt32
    let runtimeVersion: UInt32
    let bytes: Int64
    let SHA256: ASHSHA256V4
}

/// Observed loaded implementation, distinct from the expected source/recipe
/// inventory. Signed-image hashes intentionally describe this private build;
/// re-signing or thinning is a different identity and requires new evidence.
struct SoftwareInputImplementationIdentity: Codable, Equatable, Sendable {
    static let schemaID = "mirmir.software-input-observed-implementation.v1"
    let schemaID: String
    let architecture: String
    let ABIContractSHA256: ASHSHA256V4
    let expectedSourceProvenanceSHA256: ASHSHA256V4
    let implementationImages: [SoftwareInputImplementationImage]
    let libraries: [SoftwareInputImplementationLibrary]

    private static let captured: Result<Self, Error> = Result { try capture() }

    static func current() throws -> Self { try captured.get() }

    func verifyCurrent() throws {
        guard self == (try Self.current()) else {
            throw ProbeFailure("software decoder implementation/ABI identity differs")
        }
    }

    private static func capture() throws -> Self {
        let required = mib_copy_abi_contract_v1(nil, 0)
        guard required > 0, required < 32768 else { throw ProbeFailure("software bridge ABI query bound") }
        var raw = [CChar](repeating: 0, count: Int(required) + 1)
        guard mib_copy_abi_contract_v1(&raw, raw.count) == required else {
            throw ProbeFailure("software bridge ABI query incomplete")
        }
        let data = raw.withUnsafeBytes { Data($0.prefix(Int(required))) }
        guard let ABI = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ABI["schemaID"] as? String == "mirmir.software-input-bridge-abi.v1",
              (ABI["bridgeABIVersion"] as? NSNumber)?.intValue == 1,
              (ABI["pointerBytes"] as? NSNumber)?.intValue == MemoryLayout<UnsafeRawPointer>.size,
              ABI["littleEndian"] as? Bool == true,
              let types = ABI["types"] as? [String: Any],
              NSDictionary(dictionary: types).isEqual(to: expectedABILayout()) else {
            throw ProbeFailure("compiled C and imported Swift ABI layouts differ")
        }
        let ABIBytes = try JSONSerialization.data(withJSONObject: ABI, options: [.sortedKeys])
        let provenanceURL: URL?
        if let path = ProcessInfo.processInfo.environment["MIRMIR_SOFTWARE_EXPECTED_PROVENANCE_PATH"] {
            provenanceURL = URL(fileURLWithPath: path)
        } else {
            provenanceURL = Bundle.main.url(forResource: "SoftwareInputExpectedProvenance", withExtension: "json")
        }
        guard let provenanceURL else { throw ProbeFailure("software expected source provenance is missing") }
        let provenance = try Data(contentsOf: provenanceURL)
        guard provenance.count > 0, provenance.count <= 1024 * 1024,
              let body = try JSONSerialization.jsonObject(with: provenance) as? [String: Any],
              body["schemaID"] as? String == "mirmir.software-input-expected-source-provenance.v1" else {
            throw ProbeFailure("software expected source provenance schema/bound")
        }
        var images: [SoftwareInputImplementationImage] = []
        for (index, role) in ["bridge", "matroska-track-reader", "working-and-presentation-pixels"].enumerated() {
            guard let path = mib_implementation_image_path_v1(Int32(index)) else {
                throw ProbeFailure("software implementation image cannot be located")
            }
            let file = try ASHStreamingFileIdentityV4.read(url:
                URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath())
            images.append(.init(role: role, bytes: file.byteCount, SHA256: file.contentSHA256))
        }
        var libraries: [SoftwareInputImplementationLibrary] = []
        for (index, role) in ["avformat", "avcodec", "avutil", "swresample", "swscale"].enumerated() {
            let compiled = mib_library_compiled_version_v1(Int32(index))
            let runtime = mib_library_runtime_version_v1(Int32(index))
            guard compiled > 0, compiled == runtime,
                  let path = mib_library_image_path_v1(Int32(index)) else {
                throw ProbeFailure("software decoder library/header versions differ")
            }
            let file = try ASHStreamingFileIdentityV4.read(url:
                URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath())
            libraries.append(.init(role: role, compiledVersion: compiled, runtimeVersion: runtime,
                bytes: file.byteCount, SHA256: file.contentSHA256))
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        throw ProbeFailure("software decoder architecture is not qualified")
        #endif
        return Self(schemaID: schemaID, architecture: architecture,
            ABIContractSHA256: ASHSHA256V4(rawData: ABIBytes),
            expectedSourceProvenanceSHA256: ASHSHA256V4(rawData: provenance),
            implementationImages: images, libraries: libraries)
    }

    static func expectedABILayout() -> [String: Any] {
        var types: [String: Any] = [:]
        types["MIBAssetFacts"] = ["size": MemoryLayout<MIBAssetFacts>.size, "alignment": MemoryLayout<MIBAssetFacts>.alignment, "offsets": [
            "sha256": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.sha256)!,
            "bytes": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.bytes)!,
            "device": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.device)!,
            "inode": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.inode)!,
            "demuxer": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.demuxer)!,
            "start": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.start)!,
            "duration": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.duration)!,
            "streams": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.streams)!,
            "chapters": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.chapters)!,
            "programs": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.programs)!,
            "groups": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.groups)!,
            "denied_secondary_opens": MemoryLayout<MIBAssetFacts>.offset(of: \MIBAssetFacts.denied_secondary_opens)!,
        ]]
        types["MIBCancellation"] = ["size": MemoryLayout<MIBCancellation>.size, "alignment": MemoryLayout<MIBCancellation>.alignment, "offsets": [
            "is_cancelled": MemoryLayout<MIBCancellation>.offset(of: \MIBCancellation.is_cancelled)!,
            "context": MemoryLayout<MIBCancellation>.offset(of: \MIBCancellation.context)!,
        ]]
        types["MIBDecodedFrame"] = ["size": MemoryLayout<MIBDecodedFrame>.size, "alignment": MemoryLayout<MIBDecodedFrame>.alignment, "offsets": [
            "stream": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.stream)!,
            "ordinal": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.ordinal)!,
            "pts": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.pts)!,
            "best_effort_pts": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.best_effort_pts)!,
            "duration": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.duration)!,
            "packet_dts": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.packet_dts)!,
            "has_packet_identity": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.has_packet_identity)!,
            "packet_identity": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.packet_identity)!,
            "flags": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.flags)!,
            "decode_error_flags": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.decode_error_flags)!,
            "side_data_count": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.side_data_count)!,
            "pixel_format": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.pixel_format)!,
            "width": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.width)!,
            "height": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.height)!,
            "planes": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.planes)!,
            "components": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.components)!,
            "depth": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.depth)!,
            "chroma_log2_width": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.chroma_log2_width)!,
            "chroma_log2_height": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.chroma_log2_height)!,
            "pixel_format_flags": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.pixel_format_flags)!,
            "pixel_is_rgb": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.pixel_is_rgb)!,
            "pixel_has_alpha": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.pixel_has_alpha)!,
            "pixel_format_name": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.pixel_format_name)!,
            "color_range": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.color_range)!,
            "primaries": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.primaries)!,
            "transfer": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.transfer)!,
            "matrix": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.matrix)!,
            "chroma_location": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.chroma_location)!,
            "sample_aspect_ratio": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.sample_aspect_ratio)!,
            "crop_left": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.crop_left)!,
            "crop_right": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.crop_right)!,
            "crop_top": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.crop_top)!,
            "crop_bottom": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.crop_bottom)!,
            "plane": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.plane)!,
            "image_bytes": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.image_bytes)!,
            "sample_rate": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.sample_rate)!,
            "channels": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.channels)!,
            "native_sample_format": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.native_sample_format)!,
            "decoded_samples": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.decoded_samples)!,
            "normalized_samples": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.normalized_samples)!,
            "channel_layout": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.channel_layout)!,
            "channel_order": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.channel_order)!,
            "channel_id": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.channel_id)!,
            "channel_mask": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.channel_mask)!,
            "skip_start": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.skip_start)!,
            "skip_end": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.skip_end)!,
            "skip_start_reason": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.skip_start_reason)!,
            "skip_end_reason": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.skip_end_reason)!,
            "audible_offset": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.audible_offset)!,
            "audible_samples": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.audible_samples)!,
            "s32_interleaved": MemoryLayout<MIBDecodedFrame>.offset(of: \MIBDecodedFrame.s32_interleaved)!,
        ]]
        types["MIBError"] = ["size": MemoryLayout<MIBError>.size, "alignment": MemoryLayout<MIBError>.alignment, "offsets": [
            "code": MemoryLayout<MIBError>.offset(of: \MIBError.code)!,
            "stage": MemoryLayout<MIBError>.offset(of: \MIBError.stage)!,
            "message": MemoryLayout<MIBError>.offset(of: \MIBError.message)!,
        ]]
        types["MIBLimits"] = ["size": MemoryLayout<MIBLimits>.size, "alignment": MemoryLayout<MIBLimits>.alignment, "offsets": [
            "packet_bytes": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.packet_bytes)!,
            "frame_bytes": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.frame_bytes)!,
            "metadata_bytes": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.metadata_bytes)!,
            "streams": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.streams)!,
            "cursors": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.cursors)!,
            "max_width": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.max_width)!,
            "max_height": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.max_height)!,
            "max_channels": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.max_channels)!,
            "max_audio_samples": MemoryLayout<MIBLimits>.offset(of: \MIBLimits.max_audio_samples)!,
        ]]
        types["MIBPacket"] = ["size": MemoryLayout<MIBPacket>.size, "alignment": MemoryLayout<MIBPacket>.alignment, "offsets": [
            "stream": MemoryLayout<MIBPacket>.offset(of: \MIBPacket.stream)!,
            "identity": MemoryLayout<MIBPacket>.offset(of: \MIBPacket.identity)!,
            "bytes": MemoryLayout<MIBPacket>.offset(of: \MIBPacket.bytes)!,
            "side_data_count": MemoryLayout<MIBPacket>.offset(of: \MIBPacket.side_data_count)!,
        ]]
        types["MIBPacketIdentity"] = ["size": MemoryLayout<MIBPacketIdentity>.size, "alignment": MemoryLayout<MIBPacketIdentity>.alignment, "offsets": [
            "ordinal": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.ordinal)!,
            "position": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.position)!,
            "ordinal_valid": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.ordinal_valid)!,
            "payload_sha256": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.payload_sha256)!,
            "pts": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.pts)!,
            "dts": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.dts)!,
            "duration": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.duration)!,
            "vop_time": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.vop_time)!,
            "flags": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.flags)!,
            "vop_type": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.vop_type)!,
            "vop_count": MemoryLayout<MIBPacketIdentity>.offset(of: \MIBPacketIdentity.vop_count)!,
        ]]
        types["MIBPlane"] = ["size": MemoryLayout<MIBPlane>.size, "alignment": MemoryLayout<MIBPlane>.alignment, "offsets": [
            "bytes": MemoryLayout<MIBPlane>.offset(of: \MIBPlane.bytes)!,
            "row_bytes": MemoryLayout<MIBPlane>.offset(of: \MIBPlane.row_bytes)!,
            "width": MemoryLayout<MIBPlane>.offset(of: \MIBPlane.width)!,
            "height": MemoryLayout<MIBPlane>.offset(of: \MIBPlane.height)!,
        ]]
        types["MIBProgramFacts"] = ["size": MemoryLayout<MIBProgramFacts>.size, "alignment": MemoryLayout<MIBProgramFacts>.alignment, "offsets": [
            "id": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.id)!,
            "flags": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.flags)!,
            "discard": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.discard)!,
            "program_number": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.program_number)!,
            "pmt_pid": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.pmt_pid)!,
            "pcr_pid": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.pcr_pid)!,
            "pmt_version": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.pmt_version)!,
            "stream_count": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.stream_count)!,
            "stream_ordinals": MemoryLayout<MIBProgramFacts>.offset(of: \MIBProgramFacts.stream_ordinals)!,
        ]]
        types["MIBRational"] = ["size": MemoryLayout<MIBRational>.size, "alignment": MemoryLayout<MIBRational>.alignment, "offsets": [
            "num": MemoryLayout<MIBRational>.offset(of: \MIBRational.num)!,
            "den": MemoryLayout<MIBRational>.offset(of: \MIBRational.den)!,
        ]]
        types["MIBSideData"] = ["size": MemoryLayout<MIBSideData>.size, "alignment": MemoryLayout<MIBSideData>.alignment, "offsets": [
            "type": MemoryLayout<MIBSideData>.offset(of: \MIBSideData.type)!,
            "name": MemoryLayout<MIBSideData>.offset(of: \MIBSideData.name)!,
            "bytes": MemoryLayout<MIBSideData>.offset(of: \MIBSideData.bytes)!,
        ]]
        types["MIBSpan"] = ["size": MemoryLayout<MIBSpan>.size, "alignment": MemoryLayout<MIBSpan>.alignment, "offsets": [
            "data": MemoryLayout<MIBSpan>.offset(of: \MIBSpan.data)!,
            "size": MemoryLayout<MIBSpan>.offset(of: \MIBSpan.size)!,
        ]]
        types["MIBStreamFacts"] = ["size": MemoryLayout<MIBStreamFacts>.size, "alignment": MemoryLayout<MIBStreamFacts>.alignment, "offsets": [
            "ordinal": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.ordinal)!,
            "container_id": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.container_id)!,
            "media_type": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.media_type)!,
            "codec_id": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.codec_id)!,
            "codec_tag": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.codec_tag)!,
            "codec_name": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.codec_name)!,
            "profile": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.profile)!,
            "level": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.level)!,
            "disposition": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.disposition)!,
            "width": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.width)!,
            "height": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.height)!,
            "pixel_format": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.pixel_format)!,
            "raw_depth": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.raw_depth)!,
            "coded_depth": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.coded_depth)!,
            "color_range": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.color_range)!,
            "primaries": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.primaries)!,
            "transfer": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.transfer)!,
            "matrix": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.matrix)!,
            "chroma_location": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.chroma_location)!,
            "field_order": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.field_order)!,
            "video_delay": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.video_delay)!,
            "sample_rate": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.sample_rate)!,
            "sample_format": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.sample_format)!,
            "channels": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.channels)!,
            "frame_size": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.frame_size)!,
            "initial_padding": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.initial_padding)!,
            "trailing_padding": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.trailing_padding)!,
            "seek_preroll": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.seek_preroll)!,
            "side_data_count": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.side_data_count)!,
            "channel_order": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.channel_order)!,
            "channel_id": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.channel_id)!,
            "channel_mask": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.channel_mask)!,
            "time_base": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.time_base)!,
            "average_frame_rate": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.average_frame_rate)!,
            "real_frame_rate": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.real_frame_rate)!,
            "sample_aspect_ratio": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.sample_aspect_ratio)!,
            "start": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.start)!,
            "duration": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.duration)!,
            "declared_frames": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.declared_frames)!,
            "channel_layout": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.channel_layout)!,
            "extradata": MemoryLayout<MIBStreamFacts>.offset(of: \MIBStreamFacts.extradata)!,
        ]]
        types["MIBTime"] = ["size": MemoryLayout<MIBTime>.size, "alignment": MemoryLayout<MIBTime>.alignment, "offsets": [
            "valid": MemoryLayout<MIBTime>.offset(of: \MIBTime.valid)!,
            "value": MemoryLayout<MIBTime>.offset(of: \MIBTime.value)!,
            "base": MemoryLayout<MIBTime>.offset(of: \MIBTime.base)!,
        ]]
        types["MTECancellation"] = ["size": MemoryLayout<MTECancellation>.size, "alignment": MemoryLayout<MTECancellation>.alignment, "offsets": [
            "is_cancelled": MemoryLayout<MTECancellation>.offset(of: \MTECancellation.is_cancelled)!,
            "context": MemoryLayout<MTECancellation>.offset(of: \MTECancellation.context)!,
        ]]
        types["MTEError"] = ["size": MemoryLayout<MTEError>.size, "alignment": MemoryLayout<MTEError>.alignment, "offsets": [
            "code": MemoryLayout<MTEError>.offset(of: \MTEError.code)!,
            "offset": MemoryLayout<MTEError>.offset(of: \MTEError.offset)!,
            "reason": MemoryLayout<MTEError>.offset(of: \MTEError.reason)!,
        ]]
        types["MTEFacts"] = ["size": MemoryLayout<MTEFacts>.size, "alignment": MemoryLayout<MTEFacts>.alignment, "offsets": [
            "source_sha256": MemoryLayout<MTEFacts>.offset(of: \MTEFacts.source_sha256)!,
            "source_bytes": MemoryLayout<MTEFacts>.offset(of: \MTEFacts.source_bytes)!,
            "doc_type": MemoryLayout<MTEFacts>.offset(of: \MTEFacts.doc_type)!,
            "count": MemoryLayout<MTEFacts>.offset(of: \MTEFacts.count)!,
            "metadata_read_bytes": MemoryLayout<MTEFacts>.offset(of: \MTEFacts.metadata_read_bytes)!,
            "skipped_payload_bytes": MemoryLayout<MTEFacts>.offset(of: \MTEFacts.skipped_payload_bytes)!,
            "source_hash_read_bytes": MemoryLayout<MTEFacts>.offset(of: \MTEFacts.source_hash_read_bytes)!,
        ]]
        types["MTETrack"] = ["size": MemoryLayout<MTETrack>.size, "alignment": MemoryLayout<MTETrack>.alignment, "offsets": [
            "number": MemoryLayout<MTETrack>.offset(of: \MTETrack.number)!,
            "uid": MemoryLayout<MTETrack>.offset(of: \MTETrack.uid)!,
            "type": MemoryLayout<MTETrack>.offset(of: \MTETrack.type)!,
            "enabled": MemoryLayout<MTETrack>.offset(of: \MTETrack.enabled)!,
            "default_track": MemoryLayout<MTETrack>.offset(of: \MTETrack.default_track)!,
            "forced": MemoryLayout<MTETrack>.offset(of: \MTETrack.forced)!,
            "lacing": MemoryLayout<MTETrack>.offset(of: \MTETrack.lacing)!,
            "flags_present": MemoryLayout<MTETrack>.offset(of: \MTETrack.flags_present)!,
            "has_video": MemoryLayout<MTETrack>.offset(of: \MTETrack.has_video)!,
            "pixel_width": MemoryLayout<MTETrack>.offset(of: \MTETrack.pixel_width)!,
            "pixel_height": MemoryLayout<MTETrack>.offset(of: \MTETrack.pixel_height)!,
            "crop_left": MemoryLayout<MTETrack>.offset(of: \MTETrack.crop_left)!,
            "crop_right": MemoryLayout<MTETrack>.offset(of: \MTETrack.crop_right)!,
            "crop_top": MemoryLayout<MTETrack>.offset(of: \MTETrack.crop_top)!,
            "crop_bottom": MemoryLayout<MTETrack>.offset(of: \MTETrack.crop_bottom)!,
            "display_width": MemoryLayout<MTETrack>.offset(of: \MTETrack.display_width)!,
            "display_height": MemoryLayout<MTETrack>.offset(of: \MTETrack.display_height)!,
            "display_unit": MemoryLayout<MTETrack>.offset(of: \MTETrack.display_unit)!,
            "alpha_mode": MemoryLayout<MTETrack>.offset(of: \MTETrack.alpha_mode)!,
            "video_fields_present": MemoryLayout<MTETrack>.offset(of: \MTETrack.video_fields_present)!,
            "codec_id": MemoryLayout<MTETrack>.offset(of: \MTETrack.codec_id)!,
            "codec_private": MemoryLayout<MTETrack>.offset(of: \MTETrack.codec_private)!,
            "codec_private_size": MemoryLayout<MTETrack>.offset(of: \MTETrack.codec_private_size)!,
            "raw_entry": MemoryLayout<MTETrack>.offset(of: \MTETrack.raw_entry)!,
            "raw_entry_size": MemoryLayout<MTETrack>.offset(of: \MTETrack.raw_entry_size)!,
            "entry_offset": MemoryLayout<MTETrack>.offset(of: \MTETrack.entry_offset)!,
            "entry_sha256": MemoryLayout<MTETrack>.offset(of: \MTETrack.entry_sha256)!,
        ]]
        return types
    }
}
