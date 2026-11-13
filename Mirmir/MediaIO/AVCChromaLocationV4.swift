import CoreMedia
import CoreVideo
import Foundation

/// Reads the encoded AVC location before a native interpretation can replace it.
/// Parsing is bounded and validates complete SPS RBSP termination.
enum AVCChromaLocationV4 {
    enum Failure: Error { case malformed(String) }
    struct Facts: Equatable, Sendable {
        let profile: UInt8
        let sequenceParameterSetID: UInt64
        let chromaFormat: UInt64
        let bitDepth: UInt64
        let progressive: Bool
        let macroblockAdaptiveField: Bool
        let explicitLocation: Bool
        let top: UInt8
        let bottom: UInt8
    }
    static func read(_ nal: Data) throws -> Facts {
        guard nal.count >= 5, nal.count <= 65_536 else {
            throw Failure.malformed("sps_size")
        }
        let bytes = Array(nal)
        guard bytes[0] & 0x80 == 0, bytes[0] & 0x1f == 7,
              bytes[0] & 0x60 != 0 else { throw Failure.malformed("sps_nal") }
        let raw = try unescape(Array(bytes.dropFirst()))
        var r = Reader(raw)
        let profile = UInt8(try r.bits(8))
        let constraints = try r.bits(8)
        guard constraints & 3 == 0 else { throw Failure.malformed("constraint_reserved") }
        _ = try r.bits(8) // level_idc
        let id = try r.ue(max: 31)
        let base: Set<UInt8> = [66, 77, 88]
        let high: Set<UInt8> = [44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 144, 244]
        guard base.contains(profile) || high.contains(profile) else {
            throw Failure.malformed("unsupported_profile")
        }
        var chroma: UInt64 = 1
        var depth: UInt64 = 8
        if high.contains(profile) {
            chroma = try r.ue(max: 3)
            if chroma == 3 { _ = try r.bit() }
            let luma = try r.ue(max: 6), color = try r.ue(max: 6)
            guard luma == color else { throw Failure.malformed("unequal_bit_depth") }
            depth = luma + 8
            _ = try r.bit() // qpprime_y_zero_transform_bypass_flag
            if try r.bit() {
                for index in 0..<(chroma == 3 ? 12 : 8) {
                    if try r.bit() { try scalingList(&r, count: index < 6 ? 16 : 64) }
                }
            }
        }
        _ = try r.ue(max: 12) // log2_max_frame_num_minus4
        let order = try r.ue(max: 2)
        if order == 0 { _ = try r.ue(max: 12) }
        if order == 1 {
            _ = try r.bit()
            _ = try r.se(); _ = try r.se()
            let cycle = try r.ue(max: 255)
            for _ in 0..<cycle { _ = try r.se() }
        }
        _ = try r.ue(max: 16) // max_num_ref_frames
        _ = try r.bit()
        _ = try r.ue(max: UInt64(UInt32.max)) // pic_width_in_mbs_minus1
        _ = try r.ue(max: UInt64(UInt32.max)) // pic_height_in_map_units_minus1
        let progressive = try r.bit()
        let macroblockAdaptiveField = !progressive ? try r.bit() : false
        _ = try r.bit()
        if try r.bit() { for _ in 0..<4 { _ = try r.ue(max: UInt64(UInt32.max)) } }
        let vui = try r.bit()
        var explicit = false
        var top: UInt8 = 0, bottom: UInt8 = 0
        if vui {
            if try r.bit() {
                let aspect = try r.bits(8)
                if aspect == 255 { _ = try r.bits(16); _ = try r.bits(16) }
            }
            if try r.bit() { _ = try r.bit() }
            if try r.bit() {
                _ = try r.bits(3); _ = try r.bit()
                if try r.bit() { _ = try r.bits(24) }
            }
            explicit = try r.bit()
            if explicit {
                top = UInt8(try r.ue(max: 5)); bottom = UInt8(try r.ue(max: 5))
            }
            if try r.bit() { _ = try r.bits(32); _ = try r.bits(32); _ = try r.bit() }
            let nalHRD = try r.bit()
            if nalHRD { try hrd(&r) }
            let vclHRD = try r.bit()
            if vclHRD { try hrd(&r) }
            if nalHRD || vclHRD { _ = try r.bit() }
            _ = try r.bit()
            if try r.bit() {
                _ = try r.bit()
                for _ in 0..<6 { _ = try r.ue(max: UInt64(UInt32.max)) }
            }
        }
        try r.finish()
        return Facts(profile: profile, sequenceParameterSetID: id,
            chromaFormat: chroma, bitDepth: depth, progressive: progressive,
            macroblockAdaptiveField: macroblockAdaptiveField,
            explicitLocation: explicit, top: top, bottom: bottom)
    }
    static func agreeing(_ nals: [Data]) throws -> Facts {
        guard !nals.isEmpty, nals.count <= 32 else { throw Failure.malformed("sps_count") }
        var first: Facts?
        var byID: [UInt64: Data] = [:]
        for nal in nals {
            let value = try read(nal)
            if let existing = byID[value.sequenceParameterSetID], existing != nal {
                throw Failure.malformed("conflicting_sps_id")
            }
            byID[value.sequenceParameterSetID] = nal
            if let first {
                guard first.chromaFormat == value.chromaFormat,
                      first.bitDepth == value.bitDepth,
                      first.progressive == value.progressive,
                      first.macroblockAdaptiveField == value.macroblockAdaptiveField,
                      first.top == value.top, first.bottom == value.bottom else {
                    throw Failure.malformed("sps_locations_disagree")
                }
            } else { first = value }
        }
        guard let first else { throw Failure.malformed("sps_empty") }
        return first
    }
    private static func scalingList(_ r: inout Reader, count: Int) throws {
        var last: Int64 = 8, next: Int64 = 8
        for _ in 0..<count {
            if next != 0 { next = (last + (try r.se()) + 256) % 256
                if next < 0 { next += 256 }
            }
            if next != 0 { last = next }
        }
    }
    private static func hrd(_ r: inout Reader) throws {
        let count = try r.ue(max: 31)
        _ = try r.bits(8)
        for _ in 0...count { _ = try r.ue(max: UInt64(UInt32.max)); _ = try r.ue(max: UInt64(UInt32.max)); _ = try r.bit() }
        _ = try r.bits(20)
    }
    private static func unescape(_ bytes: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = [], zeroes = 0, index = 0
        output.reserveCapacity(bytes.count)
        while index < bytes.count {
            let byte = bytes[index]
            if zeroes >= 2 {
                if byte == 3 {
                    guard index + 1 < bytes.count, bytes[index + 1] <= 3 else {
                        throw Failure.malformed("emulation_prevention")
                    }
                    zeroes = 0; index += 1; continue
                }
                guard byte > 2 else { throw Failure.malformed("unescaped_start_code") }
            }
            output.append(byte); zeroes = byte == 0 ? zeroes + 1 : 0; index += 1
        }
        return output
    }
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func bit() throws -> Bool { try bits(1) != 0 }
        mutating func bits(_ count: Int) throws -> UInt64 {
            guard count >= 0, count <= 64, count <= bytes.count * 8 - offset else {
                throw Failure.malformed("truncated")
            }
            var result: UInt64 = 0
            for _ in 0..<count {
                result = (result << 1) | UInt64((bytes[offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return result
        }
        mutating func ue(max: UInt64) throws -> UInt64 {
            var zeroes = 0
            while !(try bit()) {
                zeroes += 1
                guard zeroes <= 32 else { throw Failure.malformed("golomb_overflow") }
            }
            let result = (UInt64(1) << zeroes) - 1 + (try bits(zeroes))
            guard result <= max else { throw Failure.malformed("golomb_range") }
            return result
        }
        mutating func se() throws -> Int64 {
            let value = try ue(max: UInt64(UInt32.max))
            return value.isMultiple(of: 2) ? -Int64(value / 2) : Int64((value + 1) / 2)
        }
        mutating func finish() throws {
            guard try bit() else { throw Failure.malformed("rbsp_stop_bit") }
            while offset.isMultiple(of: 8) == false {
                guard try bit() == false else { throw Failure.malformed("rbsp_alignment") }
            }
            guard offset == bytes.count * 8 else { throw Failure.malformed("rbsp_trailing_bytes") }
        }
    }
}

extension AVCChromaLocationV4 {
    struct Declaration: Sendable {
        let facts: Facts
        let sourceParameterSets: [Data]
        let location: CanonicalChromaSitingV4
        let bottomLocation: CanonicalChromaSitingV4
        let correctsNativeTopLeftAlias: Bool
        let sourceInterlacedFieldDetail: String?

        fileprivate init(facts: Facts, sourceParameterSets: [Data],
            location: CanonicalChromaSitingV4, correctsNativeTopLeftAlias: Bool,
            sourceInterlacedFieldDetail: String? = nil) {
            self.facts = facts
            self.sourceParameterSets = sourceParameterSets
            self.location = location
            self.bottomLocation = AVCChromaLocationV4.canonicalLocation(facts.bottom)
            self.correctsNativeTopLeftAlias = correctsNativeTopLeftAlias
            self.sourceInterlacedFieldDetail = sourceInterlacedFieldDetail
        }
    }

    static func declaration(
        from description: CMFormatDescription
    ) throws -> Declaration? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video,
              CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264 else {
            return nil
        }
        var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size, parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength)
        if status != noErr {
            let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?
            let atoms = extensions?["SampleDescriptionExtensionAtoms"] as? NSDictionary
            guard atoms?["avcC"] == nil else { throw Failure.malformed("invalid_parameter_set_inventory") }
            return nil
        }
        guard count > 0, count <= 288, [1, 2, 4].contains(headerLength) else {
            throw Failure.malformed("parameter_set_inventory")
        }
        var parameterSets: [Data] = []
        for index in 0..<count {
            var current: UnsafePointer<UInt8>?, currentSize = 0, actualCount = 0
            var actualHeaderLength: Int32 = 0
            let result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: index,
                parameterSetPointerOut: &current, parameterSetSizeOut: &currentSize,
                parameterSetCountOut: &actualCount,
                nalUnitHeaderLengthOut: &actualHeaderLength)
            guard result == noErr, let current, currentSize > 0, currentSize <= 65_536,
                  actualCount == count, actualHeaderLength == headerLength else {
                throw Failure.malformed("parameter_set_read")
            }
            if current[0] & 0x1f == 7 {
                parameterSets.append(Data(bytes: current, count: currentSize))
            }
        }
        let facts = try agreeing(parameterSets)
        guard facts.chromaFormat == 1 else { return nil }
        guard !facts.progressive || facts.top == facts.bottom else {
            throw Failure.malformed("unsupported_progressive_field_pair")
        }
        let location = canonicalLocation(facts.top)
        let extensions = CMFormatDescriptionGetExtensions(description) as NSDictionary?
        let rawTop = extensions?[kCMFormatDescriptionExtension_ChromaLocationTopField as String]
        let rawBottom = extensions?[kCMFormatDescriptionExtension_ChromaLocationBottomField as String]
        guard rawTop == nil || rawTop is String,
              rawBottom == nil || rawBottom is String else {
            throw Failure.malformed("native_location_type")
        }
        let top = rawTop as? String
        let bottom = rawBottom as? String
        let values = [top, bottom].compactMap { $0 }
        let expected = nativeLocation(location)
        let expectedBottom = nativeLocation(canonicalLocation(facts.bottom))
        // Qualified 15.4 and 27.0.1 decoders retain the coded planes but label
        // this exact progressive 8-bit TopLeft case Center. Other mismatches
        // remain contradictions, and the source parameter sets stay retained.
        let alias = facts.progressive && facts.bitDepth == 8 && facts.top == 2 && !values.isEmpty
            && values.allSatisfy { $0 == kCMFormatDescriptionChromaLocation_Center as String }
        guard (top == nil || top == expected)
                && (bottom == nil || bottom == expectedBottom) || alias else {
            throw Failure.malformed("native_location_contradicts_sps")
        }
        let fieldCount = extensions?[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber
        let fieldDetail = extensions?[kCMFormatDescriptionExtension_FieldDetail as String] as? String
        let sourceInterlacedFieldDetail = !facts.progressive && facts.macroblockAdaptiveField
            && facts.bitDepth == 8 && fieldCount?.intValue == 2
            && fieldDetail.map(isKnownFieldDetail) == true ? fieldDetail : nil
        return Declaration(facts: facts, sourceParameterSets: parameterSets,
            location: location, correctsNativeTopLeftAlias: alias,
            sourceInterlacedFieldDetail: sourceInterlacedFieldDetail)
    }

    static func interpretedDecodedLocations(
        _ buffer: CVPixelBuffer, source: Declaration?
    ) throws -> (top: String?, bottom: String?) {
        let rawTop = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil)
        let rawBottom = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, nil)
        guard rawTop == nil || rawTop is String,
              rawBottom == nil || rawBottom is String else {
            throw Failure.malformed("decoded_location_type")
        }
        let top = rawTop as? String
        let bottom = rawBottom as? String
        guard let source, source.correctsNativeTopLeftAlias else { return (top, bottom) }
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw Failure.malformed("unqualified_decoded_alias_storage")
        }
        let values = [top, bottom].compactMap { $0 }
        let expected = kCVImageBufferChromaLocation_TopLeft as String
        if values.isEmpty { return (expected, expected) }
        if !values.isEmpty, values.allSatisfy({ $0 == expected }) { return (top, bottom) }
        guard !values.isEmpty, values.allSatisfy({ $0 == kCVImageBufferChromaLocation_Center as String }) else {
            throw Failure.malformed("decoded_location_contradicts_authenticated_sps")
        }
        return (expected, expected)
    }

    static func normalizeDecodedBuffer(
        _ buffer: CVPixelBuffer, source: Declaration?
    ) throws {
        guard let source, source.correctsNativeTopLeftAlias else { return }
        _ = try interpretedDecodedLocations(buffer, source: source)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_TopLeft, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_TopLeft, .shouldPropagate)
    }

    static func isKnownFieldDetail(_ value: String) -> Bool {
        [kCVImageBufferFieldDetailTemporalTopFirst as String,
         kCVImageBufferFieldDetailTemporalBottomFirst as String,
         kCVImageBufferFieldDetailSpatialFirstLineEarly as String,
         kCVImageBufferFieldDetailSpatialFirstLineLate as String].contains(value)
    }

    static func normalizeDecodedInterlacedFieldDeclaration(
        _ buffer: CVPixelBuffer, source: Declaration?
    ) throws {
        guard let source, let detail = source.sourceInterlacedFieldDetail else { return }
        guard [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange].contains(CVPixelBufferGetPixelFormatType(buffer)) else {
            throw Failure.malformed("unqualified_decoded_field_storage")
        }
        let rawCount = CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil)
        let rawDetail = CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil)
        guard rawCount == nil || rawCount is NSNumber,
              rawDetail == nil || rawDetail is String else {
            throw Failure.malformed("decoded_field_declaration_type")
        }
        if let number = rawCount as? NSNumber {
            guard CFGetTypeID(number) == CFNumberGetTypeID(),
                  number.doubleValue == Double(number.intValue) else {
                throw Failure.malformed("decoded_field_count_not_integer")
            }
        }
        let count = (rawCount as? NSNumber)?.intValue
        let decodedDetail = rawDetail as? String
        guard count == nil || count == 1 || count == 2,
              decodedDetail.map(isKnownFieldDetail) ?? true else {
            throw Failure.malformed("decoded_field_declaration_value")
        }
        if count == 2 { return }
        guard decodedDetail == nil else {
            throw Failure.malformed("decoded_progressive_count_with_field_detail")
        }
        CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, NSNumber(value: 2), .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferFieldDetailKey, detail as CFString, .shouldPropagate)
    }

    static func canonicalLocation(_ value: UInt8) -> CanonicalChromaSitingV4 {
        switch value {
        case 0: .left
        case 1: .center
        case 2: .topLeft
        case 3: .top
        case 4: .bottomLeft
        case 5: .bottom
        default: .unknown
        }
    }
    static func nativeLocation(_ value: CanonicalChromaSitingV4) -> String {
        switch value {
        case .left: kCVImageBufferChromaLocation_Left as String
        case .center: kCVImageBufferChromaLocation_Center as String
        case .topLeft: kCVImageBufferChromaLocation_TopLeft as String
        case .top: kCVImageBufferChromaLocation_Top as String
        case .bottomLeft: kCVImageBufferChromaLocation_BottomLeft as String
        case .bottom: kCVImageBufferChromaLocation_Bottom as String
        case .unknown, .notApplicable: "unresolved"
        }
    }
    static func canonicalLocation(_ value: String?) -> CanonicalChromaSitingV4? {
        guard let value else { return nil }
        return [CanonicalChromaSitingV4.left, .center, .topLeft, .top, .bottomLeft, .bottom]
            .first { nativeLocation($0) == value }
    }
}

extension AVCChromaLocationV4 {
    static func declaration(from descriptions: [CMFormatDescription]) throws -> Declaration? {
        let values = try descriptions.map { try declaration(from: $0) }
        guard let first = values.first ?? nil else {
            guard values.allSatisfy({ $0 == nil }) else { throw Failure.malformed("mixed_parameter_set_inventory") }
            return nil
        }
        var parameterSets: [Data] = []
        var alias = false
        for value in values {
            guard let value, value.location == first.location,
                  value.bottomLocation == first.bottomLocation,
                  value.facts.chromaFormat == first.facts.chromaFormat,
                  value.facts.bitDepth == first.facts.bitDepth,
                  value.facts.progressive == first.facts.progressive,
                  value.facts.macroblockAdaptiveField == first.facts.macroblockAdaptiveField,
                  value.sourceInterlacedFieldDetail == first.sourceInterlacedFieldDetail else {
                throw Failure.malformed("format_locations_disagree")
            }
            parameterSets.append(contentsOf: value.sourceParameterSets)
            alias = alias || value.correctsNativeTopLeftAlias
        }
        return Declaration(facts: first.facts, sourceParameterSets: parameterSets,
            location: first.location, correctsNativeTopLeftAlias: alias,
            sourceInterlacedFieldDetail: first.sourceInterlacedFieldDetail)
    }
}
