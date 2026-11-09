import AVFoundation
import Foundation

/// AVI's packet clock is a decode clock for reordered codecs. Reconstruct the
/// presentation clock from the unchanged bitstream before publishing a MOV.
struct NativeAVICompressedPresentationClockV4 {
    private var h264: NativeAVIH264PresentationOrderV4?
    private var mpeg4: NativeAVIMPEG4PresentationOrderV4?
    private var identityPresentation = false
    private var duration: CMTime?
    private var packetCount: Int64 = 0
    private var nextDisplayOrdinal: Int64 = 0
    private var pending: Set<Int64> = []

    init(strategy: NativeMediaInputAssetResolverV4.Strategy, format: CMVideoFormatDescription) throws {
        switch strategy {
        case .aviH264: h264 = try NativeAVIH264PresentationOrderV4(format: format)
        case .aviMPEG4: mpeg4 = try NativeAVIMPEG4PresentationOrderV4(format: format)
        case .aviOpenDMLJPEG:
            guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_JPEG else {
                throw Self.failure("OpenDML JPEG presentation requires the rewritten JPEG sample entry.")
            }
            identityPresentation = true
        }
    }

    mutating func presentationTime(packet: Data, timing: CMSampleTimingInfo) throws -> CMTime {
        let step = timing.duration
        guard Self.exact(step), CMTimeCompare(step, .zero) > 0,
              Self.exact(timing.decodeTimeStamp), Self.exact(timing.presentationTimeStamp),
              duration.map({ CMTimeCompare($0, step) == 0 }) ?? true,
              packetCount < Int64(Int32.max) else {
            throw Self.failure("AVI normalization requires a uniform exact video packet clock.")
        }
        duration = step
        let decodeTime = CMTimeMultiply(step, multiplier: Int32(packetCount))
        guard Self.exact(decodeTime), CMTimeCompare(timing.decodeTimeStamp, decodeTime) == 0,
              CMTimeCompare(timing.presentationTimeStamp, decodeTime) == 0 else {
            throw Self.failure("AVI packet timing is not the verified zero-origin decode clock.")
        }
        let ordinal: Int64
        if identityPresentation {
            ordinal = packetCount
        } else if h264 != nil {
            ordinal = try h264!.displayOrdinal(packet: packet, decodeOrdinal: packetCount)
        } else if mpeg4 != nil {
            ordinal = try mpeg4!.displayOrdinal(packet: packet, decodeOrdinal: packetCount, duration: step)
        } else { throw Self.failure("AVI presentation clock strategy is unavailable.") }
        guard ordinal >= nextDisplayOrdinal, ordinal - nextDisplayOrdinal <= 16,
              pending.insert(ordinal).inserted else {
            throw Self.failure("AVI picture ordering is duplicated, gapped, or exceeds the bounded reorder window.")
        }
        while pending.remove(nextDisplayOrdinal) != nil { nextDisplayOrdinal += 1 }
        packetCount += 1
        guard ordinal < Int64(Int32.max) else { throw Self.failure("AVI presentation clock overflowed.") }
        let result = CMTimeMultiply(step, multiplier: Int32(ordinal))
        guard Self.exact(result) else { throw Self.failure("AVI presentation clock is inexact.") }
        return result
    }

    func finish(expectedEnd: CMTime? = nil) throws {
        try mpeg4?.finish()
        guard packetCount > 0, nextDisplayOrdinal == packetCount, pending.isEmpty, let duration else {
            throw Self.failure("AVI picture ordering does not cover the complete source timeline.")
        }
        if let expectedEnd {
            guard Self.exact(expectedEnd),
                  CMTimeCompare(CMTimeMultiply(duration, multiplier: Int32(packetCount)), expectedEnd) == 0 else {
                throw Self.failure("AVI video packets do not cover the exact source track end.")
            }
        }
    }

    private static func exact(_ time: CMTime) -> Bool {
        time.isNumeric && time.epoch == 0 && !time.flags.contains(.hasBeenRounded)
    }

    private static func failure(_ message: String) -> NativeMediaInputAssetErrorV4 { .unsupported(message) }
}

/// ITU-T H.264 (08/2021), §§7.3.2, 7.3.3 and 8.2.1.1. The supported
/// contract is frame-only POC type 0 with complete, consecutive frame POCs.
/// Other POC modes, fields and MMCO5 need separate clock proofs.
private struct NativeAVIH264PresentationOrderV4 {
    private let sps: SPS
    private let pps: PPS
    private var previousMSB: Int64 = 0
    private var previousLSB: Int64 = 0
    private var groupBase: Int64 = 0
    private var groupCount: Int64 = 0
    private var nextGroupOrdinal: Int64 = 0
    private var pending: Set<Int64> = []
    private var started = false

    init(format: CMVideoFormatDescription) throws {
        sps = try SPS(Self.parameterSet(format, index: 0))
        pps = try PPS(Self.parameterSet(format, index: 1))
        guard pps.spsID == sps.id else { throw Self.failure("H.264 PPS refers to a different SPS.") }
    }

    mutating func displayOrdinal(packet: Data, decodeOrdinal: Int64) throws -> Int64 {
        var picture: Picture?
        var firstMacroblocks: Set<Int> = []
        for nal in try NativeMediaInputAssetResolverV4.annexBNALs(packet) {
            guard let header = nal.first, header & 0x80 == 0 else { throw Self.failure("H.264 NAL header is invalid.") }
            let kind = header & 31
            switch kind {
            case 1, 5:
                let slice = try parseSlice(nal)
                guard firstMacroblocks.insert(slice.firstMacroblock).inserted,
                      picture.map({ $0 == slice.picture }) ?? true else {
                    throw Self.failure("H.264 AVI packet contains multiple or inconsistent pictures.")
                }
                picture = slice.picture
            case 6, 7, 8, 9, 12: break
            default: throw Self.failure("H.264 AVI NAL type \(kind) is outside the verified frame clock contract.")
            }
        }
        guard let picture, firstMacroblocks.contains(0) else { throw Self.failure("H.264 AVI packet has no complete primary picture header.") }
        if picture.idr {
            guard pending.isEmpty, nextGroupOrdinal == groupCount,
                  !started || !picture.discardsPrior else {
                throw Self.failure("H.264 IDR does not close the preceding presentation timeline.")
            }
            groupBase = decodeOrdinal
            groupCount = 0
            nextGroupOrdinal = 0
            previousMSB = 0
            previousLSB = 0
            started = true
            guard picture.lsb == 0, picture.frameNumber == 0 else {
                throw Self.failure("H.264 IDR clock does not start at zero.")
            }
        }
        guard started else { throw Self.failure("H.264 AVI must begin with an IDR picture.") }
        let modulus = Int64(1 << sps.logPOC)
        let msb: Int64
        if picture.lsb < previousLSB, previousLSB - picture.lsb >= modulus / 2 {
            msb = previousMSB + modulus
        } else if picture.lsb > previousLSB, picture.lsb - previousLSB > modulus / 2 {
            msb = previousMSB - modulus
        } else { msb = previousMSB }
        let poc = msb + picture.lsb
        guard poc >= 0, poc <= Int64(Int32.max), poc % 2 == 0 else {
            throw Self.failure("H.264 POC is outside the consecutive progressive frame clock contract.")
        }
        let ordinal = poc / 2
        guard ordinal >= nextGroupOrdinal, ordinal - nextGroupOrdinal <= 16,
              pending.insert(ordinal).inserted else {
            throw Self.failure("H.264 frame POCs are duplicated or exceed the bounded reorder window.")
        }
        while pending.remove(nextGroupOrdinal) != nil { nextGroupOrdinal += 1 }
        groupCount += 1
        if picture.reference { previousMSB = msb; previousLSB = picture.lsb }
        return groupBase + ordinal
    }

    private func parseSlice(_ nal: Data) throws -> (firstMacroblock: Int, picture: Picture) {
        let header = nal.first!
        let idr = header & 31 == 5
        let reference = header & 0x60 != 0
        guard !idr || reference else { throw Self.failure("H.264 IDR is not a reference picture.") }
        var bits = try Bits(nal: nal)
        let first = try bits.ue(maximum: sps.macroblocks - 1)
        let rawType = try bits.ue(maximum: 9)
        let type = rawType % 5
        guard type <= 2, try bits.ue(maximum: 255) == pps.id else {
            throw Self.failure("H.264 switching or unknown slice configuration is unsupported.")
        }
        guard !idr || type == 2 else { throw Self.failure("H.264 IDR has a non-intra slice.") }
        let frame = try bits.u(sps.logFrame)
        let idrID = idr ? try bits.ue(maximum: 65_535) : nil
        let lsb = try bits.u(sps.logPOC)
        if pps.bottomPOC { guard try bits.se() == 0 else { throw Self.failure("H.264 frame fields have different picture clocks.") } }
        if pps.redundant { guard try bits.ue(maximum: 127) == 0 else { throw Self.failure("H.264 redundant pictures are unsupported.") } }
        if type == 1 { _ = try bits.u(1) }
        var references = pps.references
        if type == 0 || type == 1, try bits.u(1) != 0 {
            references[0] = try bits.ue(maximum: 31) + 1
            if type == 1 { references[1] = try bits.ue(maximum: 31) + 1 }
        }
        if type != 2 {
            try Self.skipReferenceModification(&bits)
            if type == 1 { try Self.skipReferenceModification(&bits) }
        }
        if pps.weightedPrediction && type == 0 || pps.weightedBiprediction == 1 && type == 1 {
            _ = try bits.ue(maximum: 7)
            if sps.chroma != 0 { _ = try bits.ue(maximum: 7) }
            for list in 0..<(type == 1 ? 2 : 1) {
                for _ in 0..<references[list] {
                    if try bits.u(1) != 0 { _ = try bits.se(); _ = try bits.se() }
                    if sps.chroma != 0, try bits.u(1) != 0 {
                        for _ in 0..<2 { _ = try bits.se(); _ = try bits.se() }
                    }
                }
            }
        }
        var marking: [Int] = []
        var discardsPrior = false
        if reference {
            if idr {
                let prior = try bits.u(1)
                let longTerm = try bits.u(1)
                discardsPrior = prior != 0
                marking = [prior, longTerm]
            } else if try bits.u(1) != 0 {
                var ended = false
                for _ in 0..<64 {
                    let operation = try bits.ue(maximum: 6)
                    marking.append(operation)
                    guard operation != 5 else { throw Self.failure("H.264 MMCO5 presentation-clock resets are unsupported.") }
                    if operation == 0 { ended = true; break }
                    if operation == 1 || operation == 3 { marking.append(try bits.ue()) }
                    if operation == 2 { marking.append(try bits.ue()) }
                    if operation == 3 || operation == 6 { marking.append(try bits.ue()) }
                    if operation == 4 { marking.append(try bits.ue()) }
                }
                guard ended else { throw Self.failure("H.264 reference marking exceeds the bounded header size.") }
            }
        }
        return (first, Picture(idr: idr, reference: reference, frameNumber: frame, idrID: idrID,
                               lsb: Int64(lsb), discardsPrior: discardsPrior, marking: marking))
    }

    private static func skipReferenceModification(_ bits: inout Bits) throws {
        guard try bits.u(1) != 0 else { return }
        for _ in 0..<64 {
            let operation = try bits.ue(maximum: 3)
            if operation == 3 { return }
            _ = try bits.ue()
        }
        throw failure("H.264 reference list exceeds the bounded header size.")
    }

    private struct Picture: Equatable {
        let idr: Bool
        let reference: Bool
        let frameNumber: Int
        let idrID: Int?
        let lsb: Int64
        let discardsPrior: Bool
        let marking: [Int]
    }

    private struct SPS {
        let id: Int
        let chroma: Int
        let logFrame: Int
        let logPOC: Int
        let macroblocks: Int
        init(_ nal: Data) throws {
            var bits = try Bits(nal: nal)
            let profile = try bits.u(8)
            let constraints = try bits.u(8)
            _ = try bits.u(8)
            id = try bits.ue(maximum: 31)
            guard constraints & 3 == 0 else { throw failure("H.264 reserved SPS bits are not zero.") }
            var chroma = 1
            if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
                chroma = try bits.ue(maximum: 3)
                if chroma == 3 { guard try bits.u(1) == 0 else { throw failure("H.264 separate color planes are unsupported.") } }
                _ = try bits.ue(maximum: 6); _ = try bits.ue(maximum: 6); _ = try bits.u(1)
                if try bits.u(1) != 0 {
                    for index in 0..<(chroma == 3 ? 12 : 8) where try bits.u(1) != 0 {
                        var last = 8, next = 8
                        for _ in 0..<(index < 6 ? 16 : 64) {
                            if next != 0 {
                                let delta = try bits.se()
                                guard (-128...127).contains(delta) else { throw failure("H.264 scaling delta is invalid.") }
                                next = (last + delta + 256) % 256
                            }
                            if next != 0 { last = next }
                        }
                    }
                }
            } else {
                guard [66, 77, 88].contains(profile) else { throw failure("H.264 SPS profile has no verified picture-clock parser.") }
            }
            self.chroma = chroma
            logFrame = try bits.ue(maximum: 12) + 4
            guard try bits.ue(maximum: 2) == 0 else { throw failure("H.264 picture-order count types 1 and 2 are unsupported.") }
            logPOC = try bits.ue(maximum: 12) + 4
            _ = try bits.ue(maximum: 16)
            guard try bits.u(1) == 0 else { throw failure("H.264 frame-number gaps are unsupported.") }
            let width = try bits.ue(maximum: 65_535) + 1
            let height = try bits.ue(maximum: 65_535) + 1
            guard try bits.u(1) != 0 else { throw failure("H.264 field-coded presentation clocks are unsupported.") }
            macroblocks = width * height
            _ = try bits.u(1)
            if try bits.u(1) != 0 { for _ in 0..<4 { _ = try bits.ue() } }
            if try bits.u(1) != 0 { try Self.skipVUI(&bits) }
        }

        private static func skipVUI(_ bits: inout Bits) throws {
            if try bits.u(1) != 0, try bits.u(8) == 255 { _ = try bits.u(16); _ = try bits.u(16) }
            if try bits.u(1) != 0 { _ = try bits.u(1) }
            if try bits.u(1) != 0 {
                _ = try bits.u(3); _ = try bits.u(1)
                if try bits.u(1) != 0 { _ = try bits.u(8); _ = try bits.u(8); _ = try bits.u(8) }
            }
            if try bits.u(1) != 0 { _ = try bits.ue(); _ = try bits.ue() }
            if try bits.u(1) != 0 { _ = try bits.u(32); _ = try bits.u(32); _ = try bits.u(1) }
            let nalHRD = try bits.u(1) != 0
            if nalHRD { try skipHRD(&bits) }
            let vclHRD = try bits.u(1) != 0
            if vclHRD { try skipHRD(&bits) }
            if nalHRD || vclHRD { _ = try bits.u(1) }
            guard try bits.u(1) == 0 else { throw failure("H.264 picture-structure timing requires a separate duration proof.") }
            if try bits.u(1) != 0 {
                _ = try bits.u(1)
                for _ in 0..<4 { _ = try bits.ue() }
                let reorder = try bits.ue(maximum: 16)
                let buffering = try bits.ue(maximum: 16)
                guard reorder <= buffering else { throw failure("H.264 VUI reorder depth exceeds decoder buffering.") }
            }
        }

        private static func skipHRD(_ bits: inout Bits) throws {
            let count = try bits.ue(maximum: 31) + 1
            _ = try bits.u(4); _ = try bits.u(4)
            for _ in 0..<count { _ = try bits.ue(); _ = try bits.ue(); _ = try bits.u(1) }
            for _ in 0..<4 { _ = try bits.u(5) }
        }
    }

    private struct PPS {
        let id: Int
        let spsID: Int
        let bottomPOC: Bool
        let references: [Int]
        let weightedPrediction: Bool
        let weightedBiprediction: Int
        let redundant: Bool
        init(_ nal: Data) throws {
            var bits = try Bits(nal: nal)
            id = try bits.ue(maximum: 255)
            spsID = try bits.ue(maximum: 31)
            _ = try bits.u(1)
            bottomPOC = try bits.u(1) != 0
            guard try bits.ue(maximum: 7) == 0 else { throw failure("H.264 slice groups are unsupported.") }
            references = [try bits.ue(maximum: 31) + 1, try bits.ue(maximum: 31) + 1]
            weightedPrediction = try bits.u(1) != 0
            weightedBiprediction = try bits.u(2)
            guard weightedBiprediction <= 2 else { throw failure("H.264 weighted prediction syntax is invalid.") }
            _ = try bits.se(); _ = try bits.se(); _ = try bits.se()
            _ = try bits.u(1); _ = try bits.u(1)
            redundant = try bits.u(1) != 0
        }
    }

    private struct Bits {
        private let bytes: [UInt8]
        private var cursor = 0
        init(nal: Data) throws {
            guard nal.count > 1, nal.count <= 64 * 1024 * 1024 else { throw failure("H.264 header is empty or exceeds its byte bound.") }
            var result: [UInt8] = []
            var zeros = 0
            let source = Array(nal.dropFirst())
            for index in source.indices {
                let byte = source[index]
                if zeros >= 2, byte == 3 {
                    guard index + 1 < source.count, source[index + 1] <= 3 else { throw failure("H.264 emulation prevention is invalid.") }
                    zeros = 0
                    continue
                }
                result.append(byte)
                zeros = byte == 0 ? zeros + 1 : 0
            }
            bytes = result
        }
        mutating func u(_ count: Int) throws -> Int {
            guard count >= 0, count <= 32, cursor <= bytes.count * 8 - count else { throw failure("H.264 picture header is truncated.") }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[cursor / 8] >> (7 - cursor % 8)) & 1)
                cursor += 1
            }
            return value
        }
        mutating func ue(maximum: Int = Int(Int32.max)) throws -> Int {
            var zeros = 0
            while try u(1) == 0 {
                zeros += 1
                guard zeros < 31 else { throw failure("H.264 Exp-Golomb header exceeds its bound.") }
            }
            let value = (1 << zeros) - 1 + (try u(zeros))
            guard value <= maximum else { throw failure("H.264 picture header value exceeds its verified bound.") }
            return value
        }
        mutating func se() throws -> Int {
            let value = try ue()
            return value % 2 == 0 ? -(value / 2) : (value + 1) / 2
        }
    }

    private static func parameterSet(_ format: CMVideoFormatDescription, index: Int) throws -> Data {
        var pointer: UnsafePointer<UInt8>?
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
            parameterSetIndex: index, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              let pointer, count > 0, count <= 1024 * 1024 else {
            throw failure("H.264 canonical parameter set is unavailable or oversized.")
        }
        return Data(bytes: pointer, count: count)
    }

    private static func failure(_ message: String) -> NativeMediaInputAssetErrorV4 { .unsupported(message) }
}
