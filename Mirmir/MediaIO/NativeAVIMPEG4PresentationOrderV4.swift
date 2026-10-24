import AVFoundation
import Foundation

/// ISO/IEC 14496-2, §6.3.5: non-B VOPs advance the preceding decoded
/// reference time base. B-VOPs use a different reference time base and are
/// excluded until the native decoder can qualify that presentation path.
struct NativeAVIMPEG4PresentationOrderV4 {
    private let configuration: VOL
    private var timeBase: Int64 = 0
    private var origin: Int64?
    private var packetCount: Int64 = 0

    init(format: CMVideoFormatDescription) throws {
        let bytes = try NativeMediaInputVerificationV4.mpeg4Configuration(format)
        let headers = try Self.headers(bytes)
        let layers = headers.filter { (0x20...0x2f).contains($0.code) }
        guard layers.count == 1, let layer = layers.first else {
            throw Self.failure("MPEG-4 AVI requires one video object layer clock.")
        }
        configuration = try VOL(layer.payload)
    }

    mutating func displayOrdinal(
        packet: Data, decodeOrdinal: Int64, duration: CMTime
    ) throws -> Int64 {
        guard decodeOrdinal == packetCount, decodeOrdinal >= 0,
              decodeOrdinal < Int64(Int32.max), duration.isNumeric,
              duration.epoch == 0, !duration.flags.contains(.hasBeenRounded),
              CMTimeCompare(duration, .zero) > 0 else {
            throw Self.failure("MPEG-4 AVI requires an exact consecutive packet clock.")
        }
        let headers = try Self.headers(packet)
        guard headers.filter({ $0.code == 0xb6 }).count == 1 else {
            throw Self.failure("MPEG-4 AVI packet must contain one coded VOP.")
        }
        var ticks: Int64?
        for header in headers {
            guard ticks == nil || !Self.isConfigurationOrClockHeader(header.code) else {
                throw Self.failure("MPEG-4 AVI packet changes configuration or GOV clock after its coded VOP.")
            }
            if (0x20...0x2f).contains(header.code) {
                guard try VOL(header.payload) == configuration else {
                    throw Self.failure("MPEG-4 AVI changes its video object layer clock.")
                }
            } else if header.code == 0xb3 {
                var bits = Bits(header.payload)
                let hours = try bits.read(5)
                let minutes = try bits.read(6)
                try bits.marker()
                let seconds = try bits.read(6)
                guard hours < 24, minutes < 60, seconds < 60 else {
                    throw Self.failure("MPEG-4 AVI GOV clock is invalid.")
                }
                _ = try bits.read(2) // closed_gov and broken_link
                timeBase = Int64(hours * 3_600 + minutes * 60 + seconds)
            } else if header.code == 0xb6 {
                var bits = Bits(header.payload)
                let type = try bits.read(2)
                guard type == 0 || type == 1 else {
                    throw Self.failure("MPEG-4 B/S-VOP decoding is outside the verified native input contract.")
                }
                guard packetCount > 0 || type == 0 else {
                    throw Self.failure("MPEG-4 AVI must begin with an I-VOP.")
                }
                var modulo: Int64 = 0
                while try bits.read(1) != 0 {
                    guard modulo < 65_535 else {
                        throw Self.failure("MPEG-4 AVI VOP time base exceeds its bounded header contract.")
                    }
                    modulo += 1
                }
                try bits.marker()
                let increment = try bits.read(configuration.timeBits)
                try bits.marker()
                guard increment < configuration.resolution, try bits.read(1) == 1 else {
                    throw Self.failure("MPEG-4 AVI has an invalid or uncoded VOP clock.")
                }
                let base = timeBase.addingReportingOverflow(modulo)
                let scaled = base.partialValue.multipliedReportingOverflow(by: Int64(configuration.resolution))
                let time = scaled.partialValue.addingReportingOverflow(Int64(increment))
                guard !base.overflow, !scaled.overflow, !time.overflow else {
                    throw Self.failure("MPEG-4 AVI VOP clock overflowed.")
                }
                timeBase = base.partialValue
                ticks = time.partialValue
            }
        }
        guard let ticks else { throw Self.failure("MPEG-4 AVI has no VOP clock.") }
        let start = origin ?? ticks
        let elapsed = ticks.subtractingReportingOverflow(start)
        let expected = CMTimeMultiply(duration, multiplier: Int32(decodeOrdinal))
        guard !elapsed.overflow, elapsed.partialValue >= 0, expected.isNumeric,
              !expected.flags.contains(.hasBeenRounded),
              CMTimeCompare(CMTime(value: elapsed.partialValue, timescale: Int32(configuration.resolution)), expected) == 0 else {
            throw Self.failure("MPEG-4 AVI VOPs do not cover the exact container frame clock.")
        }
        origin = start
        packetCount += 1
        return decodeOrdinal
    }

    func finish() throws {
        guard packetCount > 0 else { throw Self.failure("MPEG-4 AVI has no complete presentation timeline.") }
    }

    private struct Header {
        let code: UInt8
        let payload: Data
    }

    private static func isConfigurationOrClockHeader(_ code: UInt8) -> Bool {
        (0x00...0x2f).contains(code) || [0xb0, 0xb3, 0xb5].contains(code)
    }

    private static func headers(_ data: Data) throws -> [Header] {
        guard data.count >= 4, data.count <= 64 * 1024 * 1024 else {
            throw failure("MPEG-4 AVI packet exceeds the bounded header size.")
        }
        let bytes = [UInt8](data)
        var starts: [Int] = []
        for index in 0..<(bytes.count - 3)
        where bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
            guard starts.count < 1_024 else {
                throw failure("MPEG-4 AVI has too many start codes in one packet.")
            }
            starts.append(index)
        }
        guard starts.first == 0 else { throw failure("MPEG-4 AVI packet has no aligned start code.") }
        return starts.enumerated().map { ordinal, start in
            let end = ordinal + 1 < starts.count ? starts[ordinal + 1] : bytes.count
            return Header(code: bytes[start + 3], payload: Data(bytes[(start + 4)..<end]))
        }
    }

    private struct VOL: Equatable {
        let resolution: Int
        let timeBits: Int

        init(_ data: Data) throws {
            var bits = Bits(data)
            _ = try bits.read(1)
            let object = try bits.read(8)
            guard object == 1 || object == 17 else {
                throw failure("MPEG-4 AVI object type is outside the verified video clock contract.")
            }
            var version = 1
            if try bits.read(1) != 0 {
                version = try bits.read(4)
                guard version > 0 else { throw failure("MPEG-4 AVI VOL version is invalid.") }
                _ = try bits.read(3)
            }
            if try bits.read(4) == 15 { _ = try bits.read(16) }
            if try bits.read(1) != 0 {
                guard try bits.read(2) == 1 else { throw failure("MPEG-4 AVI requires 4:2:0 chroma.") }
                _ = try bits.read(1)
                if try bits.read(1) != 0 {
                    for width in [15, 15, 15, 14, 15] { _ = try bits.read(width); try bits.marker() }
                }
            }
            guard try bits.read(2) == 0 else { throw failure("MPEG-4 AVI requires a rectangular video object layer.") }
            try bits.marker()
            resolution = try bits.read(16)
            guard resolution > 0 else { throw failure("MPEG-4 AVI VOL clock resolution is zero.") }
            timeBits = max(1, Int.bitWidth - (resolution - 1).leadingZeroBitCount)
            try bits.marker()
            if try bits.read(1) != 0 {
                guard try bits.read(timeBits) > 0 else { throw failure("MPEG-4 AVI fixed VOP clock is invalid.") }
            }
            try bits.marker()
            guard try bits.read(13) > 0 else { throw failure("MPEG-4 AVI VOL width is zero.") }
            try bits.marker()
            guard try bits.read(13) > 0 else { throw failure("MPEG-4 AVI VOL height is zero.") }
            try bits.marker()
            guard try bits.read(1) == 0 else { throw failure("MPEG-4 AVI field picture clocks are unsupported.") }
            _ = try bits.read(1)
            guard try bits.read(version == 1 ? 1 : 2) == 0 else {
                throw failure("MPEG-4 AVI sprite picture clocks are unsupported.")
            }
            if try bits.read(1) != 0 { _ = try bits.read(4); guard try bits.read(4) == 8 else { throw failure("MPEG-4 AVI requires 8-bit video.") } }
            if try bits.read(1) != 0 {
                for _ in 0..<2 where try bits.read(1) != 0 {
                    for _ in 0..<64 { if try bits.read(8) == 0 { break } }
                }
            }
            if version != 1 { _ = try bits.read(1) }
            guard try bits.read(1) == 1 else {
                throw failure("MPEG-4 AVI complexity estimation headers are outside the verified clock contract.")
            }
            _ = try bits.read(1)
            if try bits.read(1) != 0 { _ = try bits.read(1) }
            if version != 1 {
                if try bits.read(1) != 0 { _ = try bits.read(3) }
                _ = try bits.read(1)
            }
            guard try bits.read(1) == 0 else { throw failure("MPEG-4 AVI scalable picture clocks are unsupported.") }
        }
    }

    private struct Bits {
        private let bytes: [UInt8]
        private var offset = 0
        init(_ data: Data) { bytes = [UInt8](data) }

        mutating func read(_ width: Int) throws -> Int {
            guard width >= 0, width <= 24, offset + width <= bytes.count * 8 else {
                throw failure("MPEG-4 AVI picture clock header is truncated.")
            }
            var result = 0
            for _ in 0..<width {
                result = (result << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return result
        }

        mutating func marker() throws {
            guard try read(1) == 1 else { throw failure("MPEG-4 AVI clock marker is invalid.") }
        }
    }

    private static func failure(_ message: String) -> NativeMediaInputAssetErrorV4 { .unsupported(message) }
}
