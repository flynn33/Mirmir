import CryptoKit
import Foundation

// MARK: - P06 LUT v1 binary serialization and immutable loading

enum ASHLUTBinaryContractV2 {
    static let magic = Array("ASHV2LUT".utf8)
    static let majorVersion: UInt16 = 1
    static let minorVersion: UInt16 = 1
    static let headerSize = 320
    static let endianTag: UInt16 = 0x4c45
    static let contextCount = 4
    static let validStateCount = 256
    static let entryStride = 24
    static let parameterStride = 64
    static let parameterPrefixSize = 60

    static let headerHasParameterTable: UInt16 = 1 << 0
    static let headerHasPayloadSHA256: UInt16 = 1 << 1
    static let headerHasPayloadCRC32: UInt16 = 1 << 2
    static let headerHasSourceAlignedPreservation: UInt16 = 1 << 3
    static let headerTemporalEnabled: UInt16 = 1 << 4
    static let requiredHeaderFlags = headerHasParameterTable
        | headerHasPayloadSHA256
        | headerHasPayloadCRC32
        | headerHasSourceAlignedPreservation

    static let entryHasSecondary: UInt16 = 1 << 0
    static let entrySourceAlignedExact: UInt16 = 1 << 1
    static let entryTemporalForcedSpatial: UInt16 = 1 << 2
    static let entryPrimaryExactVerified: UInt16 = 1 << 3
    static let entrySecondaryExactVerified: UInt16 = 1 << 4
    static let entryCompilerFallback: UInt16 = 1 << 5
    static let permittedEntryFlags: UInt16 = entryHasSecondary
        | entrySourceAlignedExact
        | entryTemporalForcedSpatial
        | entryPrimaryExactVerified
        | entrySecondaryExactVerified

    static func routeID(_ route: ASHSpatialRouteV2) -> UInt16 {
        switch route {
        case .direct2x: 1
        case .direct3Over2: 2
        }
    }

    static func route(id: UInt16) -> ASHSpatialRouteV2? {
        switch id {
        case 1: .direct2x
        case 2: .direct3Over2
        default: nil
        }
    }
}

enum ASHLUTBinaryErrorV2: Error, Equatable, Sendable {
    case truncatedFile
    case badMagic
    case unsupportedVersion
    case badEndianness
    case reservedNonzero
    case invalidRoute
    case dimensionMismatch
    case offsetOrSizeOverflow
    case fileSizeMismatch
    case headerCRCMismatch
    case payloadCRCMismatch
    case payloadSHAMismatch
    case inputHashMismatch
    case parameterCRCMismatch
    case parameterIndexOutOfBounds
    case entryCRCMismatch
    case invalidEntryFlags
    case invalidSentinel
    case invalidAffine
    case affineDecodeRejected
    case decodedMessageMismatch
}

enum ASHLUTLookupErrorV2: Error, Equatable, Sendable {
    case invalidState
    case invalidPhase
}

struct ASHLUTBinaryArtifactV2: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let data: Data
    let parameterCount: Int
    let payloadSHA256: ASHLUTHashV2
    let wholeFileSHA256: ASHLUTHashV2
}

struct ASHLUTLoadedEntryV2: Equatable, Sendable {
    let primaryAffineState: ASHState
    let secondaryAffineState: ASHState?
    let primaryDescriptorID: UInt8
    let secondaryDescriptorID: UInt8?
    let primaryMessage: ASHMessage
    let secondaryMessage: ASHMessage?
    let primaryWeightUNorm16: UInt16
    let secondaryWeightUNorm16: UInt16
    let marginUNorm16: UInt16
    let flags: UInt16
    let parameterIndex: UInt32
    let provenanceCRC32: UInt32

    var operatorEvaluationCount: Int { secondaryMessage == nil ? 1 : 2 }
}

struct ASHLUTLoadedV2: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let configuration: ASHLUTLockedConfigurationV2
    let entries: [ASHLUTLoadedEntryV2]
    let parameters: [ASHLUTParameterPairV2]
    let payloadSHA256: ASHLUTHashV2
    let wholeFileSHA256: ASHLUTHashV2
    let immutableBytes: Data

    let runtimeTreeGenerationCount = 0

    var maximumOperatorEvaluations: Int {
        entries.map(\.operatorEvaluationCount).max() ?? 0
    }

    func entry(
        state: ASHState,
        phaseOrdinal: Int,
        context: ASHLUTContextV2
    ) throws -> ASHLUTLoadedEntryV2 {
        guard let stateOrdinal = ASHLUTStateOrdinalTableV2.ordinal(for: state) else {
            throw ASHLUTLookupErrorV2.invalidState
        }
        guard (0..<route.phasePairCount).contains(phaseOrdinal) else {
            throw ASHLUTLookupErrorV2.invalidPhase
        }
        let index = (((phaseOrdinal * ASHLUTContextV2.allCases.count) + Int(context.rawValue))
            * ASHLUTStateOrdinalTableV2.validStates.count) + Int(stateOrdinal)
        return entries[index]
    }
}

enum ASHLUTCRC32V2 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return crc ^ UInt32.max
    }
}

enum ASHLUTBinaryCodecV2 {}

extension ASHLUTBinaryCodecV2 {
    private struct EncodedParameter {
        let prefix: Data
        let full: Data
    }

    static func serialize(_ compilation: ASHLUTCompilationV2) throws -> ASHLUTBinaryArtifactV2 {
        let expectedEntryCount = compilation.route.phasePairCount
            * ASHLUTBinaryContractV2.contextCount
            * ASHLUTBinaryContractV2.validStateCount
        guard compilation.entries.count == expectedEntryCount else {
            throw ASHLUTCompilerErrorV2.entryCountMismatch
        }

        var unique: [Data: ASHLUTParameterPairV2] = [:]
        for entry in compilation.entries {
            let prefix = encodeParameterPrefix(entry.parameters)
            unique[prefix] = entry.parameters
        }
        let sortedPrefixes = unique.keys.sorted { $0.lexicographicallyPrecedes($1) }
        let encodedParameters: [EncodedParameter] = sortedPrefixes.map { prefix in
            var full = prefix
            ASHLUTLittleEndianV2.append(ASHLUTCRC32V2.checksum(prefix), to: &full)
            return EncodedParameter(prefix: prefix, full: full)
        }
        let parameterIndexByPrefix = Dictionary(uniqueKeysWithValues: encodedParameters.enumerated().map {
            ($0.element.prefix, UInt32($0.offset))
        })
        var parameterBytes = Data()
        parameterBytes.reserveCapacity(encodedParameters.count * ASHLUTBinaryContractV2.parameterStride)
        for parameter in encodedParameters {
            parameterBytes.append(parameter.full)
        }

        let routeID = ASHLUTBinaryContractV2.routeID(compilation.route)
        var entryBytes = Data()
        entryBytes.reserveCapacity(compilation.entries.count * ASHLUTBinaryContractV2.entryStride)
        for entry in compilation.entries {
            let prefix = encodeParameterPrefix(entry.parameters)
            guard let parameterIndex = parameterIndexByPrefix[prefix] else {
                throw ASHLUTCompilerErrorV2.invalidLockedConfiguration
            }
            let parameter = encodedParameters[Int(parameterIndex)].full
            let firstTwenty = try encodeEntryPrefix(entry, parameterIndex: parameterIndex)
            var provenance = Data()
            ASHLUTLittleEndianV2.append(routeID, to: &provenance)
            ASHLUTLittleEndianV2.append(UInt32(entry.logicalIndex), to: &provenance)
            provenance.append(firstTwenty)
            provenance.append(parameter)
            var encodedEntry = firstTwenty
            ASHLUTLittleEndianV2.append(ASHLUTCRC32V2.checksum(provenance), to: &encodedEntry)
            entryBytes.append(encodedEntry)
        }

        var payload = parameterBytes
        payload.append(entryBytes)
        let payloadHash = sha256(payload)
        let payloadCRC = ASHLUTCRC32V2.checksum(payload)
        let parameterOffset = ASHLUTBinaryContractV2.headerSize
        let entryOffset = try checkedAdd(parameterOffset, parameterBytes.count)
        let fileSize = try checkedAdd(ASHLUTBinaryContractV2.headerSize, payload.count)
        var header = Data(repeating: 0, count: ASHLUTBinaryContractV2.headerSize)
        ASHLUTLittleEndianV2.write(bytes: ASHLUTBinaryContractV2.magic, at: 0, in: &header)
        ASHLUTLittleEndianV2.write(ASHLUTBinaryContractV2.majorVersion, at: 8, in: &header)
        ASHLUTLittleEndianV2.write(ASHLUTBinaryContractV2.minorVersion, at: 10, in: &header)
        ASHLUTLittleEndianV2.write(UInt16(ASHLUTBinaryContractV2.headerSize), at: 12, in: &header)
        ASHLUTLittleEndianV2.write(ASHLUTBinaryContractV2.endianTag, at: 14, in: &header)
        ASHLUTLittleEndianV2.write(routeID, at: 16, in: &header)
        ASHLUTLittleEndianV2.write(ASHLUTBinaryContractV2.requiredHeaderFlags, at: 18, in: &header)
        ASHLUTLittleEndianV2.write(UInt16(compilation.route.phasePairCount), at: 20, in: &header)
        ASHLUTLittleEndianV2.write(UInt16(ASHLUTBinaryContractV2.contextCount), at: 22, in: &header)
        ASHLUTLittleEndianV2.write(UInt16(ASHLUTBinaryContractV2.validStateCount), at: 24, in: &header)
        ASHLUTLittleEndianV2.write(UInt16(ASHLUTBinaryContractV2.entryStride), at: 26, in: &header)
        ASHLUTLittleEndianV2.write(UInt16(ASHLUTBinaryContractV2.parameterStride), at: 28, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(compilation.entries.count), at: 32, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(encodedParameters.count), at: 36, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(parameterOffset), at: 40, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(entryOffset), at: 44, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(parameterBytes.count), at: 48, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(entryBytes.count), at: 52, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(ASHLUTBinaryContractV2.headerSize), at: 56, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(payload.count), at: 60, in: &header)
        let configuration = compilation.configuration
        ASHLUTLittleEndianV2.write(bytes: configuration.mappingSHA256.bytes, at: 64, in: &header)
        ASHLUTLittleEndianV2.write(bytes: configuration.operatorBankSHA256.bytes, at: 96, in: &header)
        ASHLUTLittleEndianV2.write(bytes: configuration.metricPolicySHA256.bytes, at: 128, in: &header)
        ASHLUTLittleEndianV2.write(bytes: configuration.compilerInputsSHA256.bytes, at: 160, in: &header)
        ASHLUTLittleEndianV2.write(bytes: configuration.calibrationPlanSHA256.bytes, at: 192, in: &header)
        ASHLUTLittleEndianV2.write(bytes: configuration.corpusLockBundleSHA256.bytes, at: 224, in: &header)
        ASHLUTLittleEndianV2.write(bytes: payloadHash.bytes, at: 256, in: &header)
        ASHLUTLittleEndianV2.write(payloadCRC, at: 292, in: &header)
        ASHLUTLittleEndianV2.write(UInt32(fileSize), at: 296, in: &header)
        let headerCRC = ASHLUTCRC32V2.checksum(header)
        ASHLUTLittleEndianV2.write(headerCRC, at: 288, in: &header)
        var data = header
        data.append(payload)
        return ASHLUTBinaryArtifactV2(
            route: compilation.route,
            data: data,
            parameterCount: encodedParameters.count,
            payloadSHA256: payloadHash,
            wholeFileSHA256: sha256(data)
        )
    }
    private static func encodeEntryPrefix(
        _ entry: ASHLUTCompiledEntryV2,
        parameterIndex: UInt32
    ) throws -> Data {
        let primaryDecode = ASHCode.decodeAffine(
            received: entry.primary.affineState,
            anchor: entry.sourceState
        )
        guard primaryDecode.status == .exact,
              primaryDecode.messageBits == entry.primary.message.bits else {
            throw ASHLUTCompilerErrorV2.affineRecoveryFailed
        }
        var flags = ASHLUTBinaryContractV2.entryPrimaryExactVerified
        if entry.sourceAlignedExact { flags |= ASHLUTBinaryContractV2.entrySourceAlignedExact }
        if entry.temporalForcedSpatial { flags |= ASHLUTBinaryContractV2.entryTemporalForcedSpatial }
        var data = Data()
        ASHLUTLittleEndianV2.append(entry.primary.affineState.rawValue, to: &data)
        if let secondary = entry.secondary {
            let secondaryDecode = ASHCode.decodeAffine(received: secondary.affineState, anchor: entry.sourceState)
            guard secondaryDecode.status == .exact,
                  secondaryDecode.messageBits == secondary.message.bits,
                  entry.primaryWeightUNorm16 > 0,
                  entry.secondaryWeightUNorm16 > 0,
                  UInt32(entry.primaryWeightUNorm16) + UInt32(entry.secondaryWeightUNorm16) == UInt32(UInt16.max) else {
                throw ASHLUTCompilerErrorV2.affineRecoveryFailed
            }
            flags |= ASHLUTBinaryContractV2.entryHasSecondary
                | ASHLUTBinaryContractV2.entrySecondaryExactVerified
            ASHLUTLittleEndianV2.append(secondary.affineState.rawValue, to: &data)
            data.append(entry.primary.descriptorID)
            data.append(secondary.descriptorID)
            data.append(entry.primary.message.rawValue)
            data.append(secondary.message.rawValue)
        } else {
            guard entry.primaryWeightUNorm16 == UInt16.max,
                  entry.secondaryWeightUNorm16 == 0 else {
                throw ASHLUTCompilerErrorV2.invalidLockedConfiguration
            }
            ASHLUTLittleEndianV2.append(UInt16.max, to: &data)
            data.append(entry.primary.descriptorID)
            data.append(UInt8.max)
            data.append(entry.primary.message.rawValue)
            data.append(UInt8.max)
        }
        ASHLUTLittleEndianV2.append(entry.primaryWeightUNorm16, to: &data)
        ASHLUTLittleEndianV2.append(entry.secondaryWeightUNorm16, to: &data)
        ASHLUTLittleEndianV2.append(entry.marginUNorm16, to: &data)
        ASHLUTLittleEndianV2.append(flags, to: &data)
        ASHLUTLittleEndianV2.append(parameterIndex, to: &data)
        return data
    }
    private static func encodeParameterPrefix(_ parameter: ASHLUTParameterPairV2) -> Data {
        var data = Data()
        encode(parameter.primary, into: &data)
        encode(parameter.secondary, into: &data)
        ASHLUTLittleEndianV2.append(parameter.confidenceThresholdUNorm16, to: &data)
        data.append(parameter.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        data.append(parameter.boundaryMode == .clamp ? 0 : 1)
        data.append(1)
        data.append(0)
        data.append(parameter.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        data.append(Data(repeating: 0, count: 5))
        return data
    }

    private static func encode(_ slot: ASHLUTParameterSlotV2, into data: inout Data) {
        ASHLUTLittleEndianV2.append(slot.anisotropyStrengthQ12, to: &data)
        ASHLUTLittleEndianV2.append(slot.minimumAnisotropicMagnitudeUNorm15, to: &data)
        ASHLUTLittleEndianV2.append(slot.minimumAnisotropicCoherenceUNorm15, to: &data)
        ASHLUTLittleEndianV2.append(slot.detailGainQ12, to: &data)
        ASHLUTLittleEndianV2.append(slot.relaxedLimiterAlphaQ12, to: &data)
        ASHLUTLittleEndianV2.append(slot.riskSuppressionUNorm15, to: &data)
        ASHLUTLittleEndianV2.append(slot.supportRadiusQ8x8, to: &data)
        ASHLUTLittleEndianV2.append(slot.weightEpsilonF32Bits, to: &data)
        data.append(UInt8(bitPattern: slot.delta.orientation))
        data.append(UInt8(bitPattern: slot.delta.support))
        data.append(UInt8(bitPattern: slot.delta.detail))
        data.append(UInt8(bitPattern: slot.delta.regularization))
        ASHLUTLittleEndianV2.append(slot.flags, to: &data)
    }
    private static func sha256(_ data: Data) -> ASHLUTHashV2 {
        ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: data)))
    }
    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow, result.partialValue <= Int(UInt32.max) else {
            throw ASHLUTCompilerErrorV2.arithmeticOverflow
        }
        return result.partialValue
    }
}

enum ASHLUTLittleEndianV2 {
    static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    static func write(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func write(_ value: UInt32, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    static func write(bytes: [UInt8], at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
