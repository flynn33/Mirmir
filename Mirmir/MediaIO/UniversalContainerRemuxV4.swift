import Foundation

enum UniversalContainerRemuxV4 {
    struct Probe: Equatable, Sendable {
        let formatName: String
        let videoCodecName: String
        let audioCodecName: String?
        let hasAudio: Bool
        let streamCount: Int
        let admissible: Bool
    }

    enum Failure: LocalizedError {
        case probe(String)
        case unsupported(String)
        case remux(String)

        var errorDescription: String? {
            switch self {
            case .probe(let details): return "Universal remux probe: \(details)"
            case .unsupported(let details): return "Universal remux unsupported: \(details)"
            case .remux(let details): return "Universal remux: \(details)"
            }
        }
    }

    static func probe(url: URL) throws -> Probe {
        var info = UCRProbeInfo()
        var error = [CChar](repeating: 0, count: 512)
        let rc = url.path.withCString { path in
            ucr_probe(path, &info, &error, error.count)
        }
        if rc != Int32(UCR_OK) {
            throw Failure.probe(String(cString: error))
        }
        let formatName = cString(info.format_name)
        let videoCodecName = cString(info.video_codec_name)
        let audioCodecName = info.has_audio != 0 ? cString(info.audio_codec_name) : nil
        var mutable = info
        return Probe(
            formatName: formatName,
            videoCodecName: videoCodecName,
            audioCodecName: audioCodecName,
            hasAudio: info.has_audio != 0,
            streamCount: Int(info.stream_count),
            admissible: ucr_is_remux_admissible(&mutable) != 0
        )
    }

    static func remuxToMOV(input: URL, output: URL) throws {
        var error = [CChar](repeating: 0, count: 512)
        let rc = input.path.withCString { inPath in
            output.path.withCString { outPath in
                ucr_remux_to_mov(inPath, outPath, &error, error.count)
            }
        }
        switch Int(rc) {
        case Int(UCR_OK):
            return
        case Int(UCR_ERR_UNSUPPORTED):
            throw Failure.unsupported(String(cString: error))
        default:
            throw Failure.remux(String(cString: error))
        }
    }

    /// Containers that may need bitstream remux into MOV for native decode.
    static func containerFamily(url: URL) throws -> String? {
        guard url.isFileURL else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 188) ?? Data()
        if header.count >= 4, header.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) {
            return "matroska"
        }
        if header.count >= 16 {
            let asf: [UInt8] = [
                0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C
            ]
            if Array(header.prefix(16)) == asf { return "asf" }
        }
        if !header.isEmpty {
            let bytes = [UInt8](header)
            let limit = min(188, bytes.count)
            for offset in 0..<limit where bytes[offset] == 0x47 {
                return "mpegts"
            }
        }
        return nil
    }

    private static func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }
}
