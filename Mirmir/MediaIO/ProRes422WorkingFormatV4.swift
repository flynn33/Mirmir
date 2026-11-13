import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Darwin
import VideoToolbox

/// The native v216 delivery and the P010 processor input are distinct surfaces.
/// Original encoded facts remain in the canonical source inventory.
struct ProRes422WorkingFormatV4: Codable, Equatable, Sendable {
    enum Scan: String, Codable, Sendable {
        case progressive, topFirst, bottomFirst

        var fieldCount: Int { self == .progressive ? 1 : 2 }
        var fieldDetail: String? {
            switch self {
            case .progressive: nil
            case .topFirst: kCVImageBufferFieldDetailTemporalTopFirst as String
            case .bottomFirst: kCVImageBufferFieldDetailTemporalBottomFirst as String
            }
        }

        func agrees(with detail: String) -> Bool {
            switch self {
            case .progressive: false
            case .topFirst:
                detail == kCVImageBufferFieldDetailTemporalTopFirst as String
                    || detail == kCVImageBufferFieldDetailSpatialFirstLineEarly as String
            case .bottomFirst:
                detail == kCVImageBufferFieldDetailTemporalBottomFirst as String
                    || detail == kCVImageBufferFieldDetailSpatialFirstLineLate as String
            }
        }
    }

    static let procedureID = "native-prores422-v216-field-box-p010-rne-v1"
    let width: Int
    let height: Int
    let scan: Scan
    let primaries: String
    let transfer: String
    let matrix: String
    let decoderEnvironment: String

    init(width: Int, height: Int, scan: Scan,
         primaries: String, transfer: String, matrix: String) throws {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768,
              scan == .progressive || height.isMultiple(of: 4),
              !primaries.isEmpty, !transfer.isEmpty, !matrix.isEmpty else {
            throw ProRes422WorkingFormatV4Error.invalidPolicy
        }
        guard let environment = Self.currentDecoderEnvironment else {
            throw ProRes422WorkingFormatV4Error.decoderEnvironmentUnavailable
        }
        self.decoderEnvironment = environment
        self.width = width; self.height = height; self.scan = scan
        self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
    }

    var identity: String {
        [Self.procedureID, String(width), String(height), scan.rawValue,
         primaries, transfer, matrix, decoderEnvironment].map { "\($0.utf8.count):\($0)" }.joined()
    }

    // Native codec dependencies are supplied by the OS. Refuse to restore a
    // temporal state across an unqualified OS/model/architecture decoder change.
    private static let currentDecoderEnvironment: String? = {
        func value(_ key: String) -> String? {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1, size < 4096 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
            return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
        guard let build = value("kern.osversion"), let model = value("hw.model") else { return nil }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        return nil
        #endif
        return ["apple-v216", build, model, architecture].joined(separator: ":")
    }()

    var readerOutputSettings: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr16,
         AVVideoDecompressionPropertiesKey: [kVTDecompressionPropertyKey_FieldMode as String:
            kVTDecompressionProperty_FieldMode_BothFields]]
    }
}

enum ProRes422WorkingFormatV4Error: LocalizedError, Equatable {
    case invalidPolicy
    case decoderEnvironmentUnavailable
    case incompatibleWorkingAttributes
    case sourceStructure
    case sourceMetadata(String)
    case lockFailed(Int32)
    case poolFailed(Int32)
    case allocationFailed(Int32)
    case destinationStructure

    var errorDescription: String? {
        switch self {
        case .invalidPolicy: "Unsupported ProRes reader/working-format policy."
        case .decoderEnvironmentUnavailable: "The native ProRes decoder environment could not be identified."
        case .incompatibleWorkingAttributes: "The prepared input format conflicts with the ProRes P010 working policy."
        case .sourceStructure: "The native ProRes decoder delivered an unexpected pixel layout or raster."
        case .sourceMetadata(let name): "The native ProRes decoder delivered contradictory \(name) metadata."
        case .lockFailed(let status): "Cannot access the ProRes pixel buffer (Core Video status \(status))."
        case .poolFailed(let status): "Cannot create the ProRes working buffer pool (Core Video status \(status))."
        case .allocationFailed(let status): "Cannot allocate a ProRes working frame (Core Video status \(status))."
        case .destinationStructure: "The prepared ProRes working buffer has an unexpected pixel layout or raster."
        }
    }
}

/// Immutable pool/policy; each conversion returns a separately owned buffer.
/// CVPixelBufferPool supports concurrent allocation; no frame state is retained.
final class ProRes422WorkingConverterV4: @unchecked Sendable {
    let policy: ProRes422WorkingFormatV4
    private let pool: CVPixelBufferPool

    init(policy: ProRes422WorkingFormatV4, workingAttributes: [String: Any]) throws {
        let verified = try ProRes422WorkingFormatV4(width: policy.width, height: policy.height,
            scan: policy.scan, primaries: policy.primaries, transfer: policy.transfer, matrix: policy.matrix)
        guard verified == policy else { throw ProRes422WorkingFormatV4Error.invalidPolicy }
        guard (workingAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              (workingAttributes[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue == policy.width,
              (workingAttributes[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue == policy.height else {
            throw ProRes422WorkingFormatV4Error.incompatibleWorkingAttributes
        }
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 2] as CFDictionary,
            workingAttributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else {
            throw ProRes422WorkingFormatV4Error.poolFailed(status)
        }
        self.policy = policy; pool = created
    }

    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let pairs = (policy.width + 1) / 2
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_422YpCbCr16,
              !CVPixelBufferIsPlanar(source),
              CVPixelBufferGetWidth(source) == policy.width,
              CVPixelBufferGetHeight(source) == policy.height,
              CVPixelBufferGetBytesPerRow(source) >= pairs * 8 else {
            throw ProRes422WorkingFormatV4Error.sourceStructure
        }
        // A trusted frame-header policy can restore omitted decoder field tags;
        // an explicit contradictory delivery is rejected before allocation/write.
        if let raw = CVBufferCopyAttachment(source, kCVImageBufferFieldCountKey, nil) {
            guard let count = raw as? NSNumber, count.doubleValue == Double(policy.scan.fieldCount) else {
                throw ProRes422WorkingFormatV4Error.sourceMetadata("field count")
            }
        }
        if let raw = CVBufferCopyAttachment(source, kCVImageBufferFieldDetailKey, nil) {
            guard let detail = raw as? String, policy.scan.agrees(with: detail) else {
                throw ProRes422WorkingFormatV4Error.sourceMetadata("field detail")
            }
        }
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            if let raw = CVBufferCopyAttachment(source, key, nil) {
                guard let phase = raw as? String,
                      phase == kCVImageBufferChromaLocation_Left as String else {
                    throw ProRes422WorkingFormatV4Error.sourceMetadata("v216 chroma location")
                }
            }
        }
        if let raw = CVBufferCopyAttachment(source, kCVImageBufferChromaSubsamplingKey, nil) {
            guard let sampling = raw as? String,
                  sampling == kCVImageBufferChromaSubsampling_422 as String else {
                throw ProRes422WorkingFormatV4Error.sourceMetadata("subsampling")
            }
        }
        if let raw = CVBufferCopyAttachment(source, kCMFormatDescriptionExtension_FullRangeVideo, nil) {
            guard let range = raw as? NSNumber, range.doubleValue == 0 else {
                throw ProRes422WorkingFormatV4Error.sourceMetadata("range")
            }
        }
        let lock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard lock == kCVReturnSuccess else { throw ProRes422WorkingFormatV4Error.lockFailed(lock) }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let packed = CVPixelBufferGetBaseAddress(source) else {
            throw ProRes422WorkingFormatV4Error.sourceStructure
        }
        var result: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &result)
        guard allocation == kCVReturnSuccess, let destination = result else {
            throw ProRes422WorkingFormatV4Error.allocationFailed(allocation)
        }
        let writeLock = CVPixelBufferLockBaseAddress(destination, [])
        guard writeLock == kCVReturnSuccess else { throw ProRes422WorkingFormatV4Error.lockFailed(writeLock) }
        do {
            defer { CVPixelBufferUnlockBaseAddress(destination, []) }
            guard CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                  CVPixelBufferGetPlaneCount(destination) == 2,
                  let y = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
                  let uv = CVPixelBufferGetBaseAddressOfPlane(destination, 1),
                  CVPixelBufferGetWidthOfPlane(destination, 0) == policy.width,
                  CVPixelBufferGetHeightOfPlane(destination, 0) == policy.height,
                  CVPixelBufferGetWidthOfPlane(destination, 1) == pairs,
                  CVPixelBufferGetHeightOfPlane(destination, 1) == (policy.height + 1) / 2 else {
                throw ProRes422WorkingFormatV4Error.destinationStructure
            }
            let inputStride = CVPixelBufferGetBytesPerRow(source)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
            guard yStride >= policy.width * 2, uvStride >= pairs * 4 else {
                throw ProRes422WorkingFormatV4Error.destinationStructure
            }
            for row in 0..<policy.height {
                let input = packed.advanced(by: row * inputStride).assumingMemoryBound(to: UInt8.self)
                let output = y.advanced(by: row * yStride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<policy.width {
                    let offset = (column / 2) * 8 + (column.isMultiple(of: 2) ? 2 : 6)
                    Self.store(Self.quantize(Self.word(input, offset), divisor: 64), output, column * 2)
                }
            }
            for row in 0..<((policy.height + 1) / 2) {
                let first = policy.scan == .progressive ? row * 2 : (row / 2) * 4 + row % 2
                let next = first + (policy.scan == .progressive ? 1 : 2)
                let a = packed.advanced(by: first * inputStride).assumingMemoryBound(to: UInt8.self)
                let b = next < policy.height
                    ? packed.advanced(by: next * inputStride).assumingMemoryBound(to: UInt8.self) : nil
                let output = uv.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<pairs {
                    for component in 0..<2 {
                        let offset = column * 8 + component * 4
                        let sum = Self.word(a, offset) + (b.map { Self.word($0, offset) } ?? 0)
                        Self.store(Self.quantize(sum, divisor: b == nil ? 64 : 128),
                                   output, column * 4 + component * 2)
                    }
                }
            }
        }
        CVBufferRemoveAllAttachments(destination)
        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            if let values = CVBufferCopyAttachments(source, mode) { CVBufferSetAttachments(destination, values, mode) }
        }
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey,
                    kCVImageBufferChromaSubsamplingKey, kCVImageBufferFieldCountKey,
                    kCVImageBufferFieldDetailKey, kCMFormatDescriptionExtension_FullRangeVideo,
                    kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferYCbCrMatrixKey] { CVBufferRemoveAttachment(destination, key) }
        CVBufferSetAttachment(destination, kCVImageBufferChromaSubsamplingKey,
                              kCVImageBufferChromaSubsampling_420, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Left, .shouldPropagate)
        if let detail = policy.scan.fieldDetail {
            CVBufferSetAttachment(destination, kCVImageBufferChromaLocationBottomFieldKey,
                                  kCVImageBufferChromaLocation_Left, .shouldPropagate)
            CVBufferSetAttachment(destination, kCVImageBufferFieldDetailKey,
                                  detail as CFString, .shouldPropagate)
        }
        CVBufferSetAttachment(destination, kCVImageBufferFieldCountKey,
                              NSNumber(value: policy.scan.fieldCount), .shouldPropagate)
        CVBufferSetAttachment(destination, kCMFormatDescriptionExtension_FullRangeVideo,
                              kCFBooleanFalse, .shouldPropagate)
        for (key, value) in [(kCVImageBufferColorPrimariesKey, policy.primaries),
                              (kCVImageBufferTransferFunctionKey, policy.transfer),
                              (kCVImageBufferYCbCrMatrixKey, policy.matrix)] {
            CVBufferSetAttachment(destination, key, value as CFString, .shouldPropagate)
        }
        return destination
    }

    private static func word(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
    }
    private static func quantize(_ value: UInt32, divisor: UInt32) -> UInt16 {
        let quotient = value / divisor, remainder = value % divisor
        let rounded = quotient + (remainder * 2 > divisor
            || (remainder * 2 == divisor && !quotient.isMultiple(of: 2)) ? 1 : 0)
        return UInt16(min(1023, rounded)) << 6
    }
    private static func store(_ word: UInt16, _ bytes: UnsafeMutablePointer<UInt8>, _ offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: word)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: word >> 8)
    }
}
