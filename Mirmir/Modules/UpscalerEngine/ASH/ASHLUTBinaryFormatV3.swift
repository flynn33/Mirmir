import CryptoKit
import Foundation

// MARK: - P06 LUT format 1.2 binary serialization and immutable loading
// Keep the fixed header layout in one auditable serialization routine.

enum ASHLUTBinaryContractV3 {
    static let magic = Array("ASHV2LUT".utf8)
    static let majorVersion: UInt16 = 1
    static let minorVersion: UInt16 = 2
    static let headerSize = 320
    static let endianTag: UInt16 = 0x4c45
    static let contextCount = 4
    static let planeCount = 2
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

enum ASHLUTBinaryErrorV3: Error, Equatable, Sendable {
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

enum ASHLUTLookupErrorV3: Error, Equatable, Sendable {
    case invalidState
    case invalidPhase
}

struct ASHLUTBinaryArtifactV3: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let data: Data
    let parameterCount: Int
    let payloadSHA256: ASHLUTHashV3
    let wholeFileSHA256: ASHLUTHashV3
}

struct ASHLUTLoadedEntryV3: Equatable, Sendable {
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

struct ASHLUTLoadedV3: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let configuration: ASHLUTLockedConfigurationV3
    let entries: [ASHLUTLoadedEntryV3]
    let parameters: [ASHLUTParameterPairV3]
    let payloadSHA256: ASHLUTHashV3
    let wholeFileSHA256: ASHLUTHashV3
    let immutableBytes: Data

    let runtimeTreeGenerationCount = 0

    var maximumOperatorEvaluations: Int {
        entries.map(\.operatorEvaluationCount).max() ?? 0
    }

    func entry(
        state: ASHState,
        planeRole: ASHLUTPlaneRoleV3,
        phaseOrdinal: Int,
        context: ASHLUTContextV3
    ) throws -> ASHLUTLoadedEntryV3 {
        guard let stateOrdinal = ASHLUTStateOrdinalTableV3.ordinal(for: state) else {
            throw ASHLUTLookupErrorV3.invalidState
        }
        guard (0..<route.phasePairCount).contains(phaseOrdinal) else {
            throw ASHLUTLookupErrorV3.invalidPhase
        }
        let entriesPerPlane = route.phasePairCount
            * ASHLUTContextV3.allCases.count
            * ASHLUTStateOrdinalTableV3.validStates.count
        let index = Int(planeRole.rawValue) * entriesPerPlane
            + (((phaseOrdinal * ASHLUTContextV3.allCases.count) + Int(context.rawValue))
                * ASHLUTStateOrdinalTableV3.validStates.count)
            + Int(stateOrdinal)
        return entries[index]
    }
}

enum ASHLUTCRC32V3 {
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

enum ASHLUTBinaryCodecV3 {}

extension ASHLUTBinaryCodecV3 {
    private struct EncodedParameter {
        let prefix: Data
        let full: Data
    }

    private struct HeaderMetadata {
        let mappingSHA256: [UInt8]
        let operatorBankSHA256: [UInt8]
        let metricPolicySHA256: [UInt8]
        let compilerInputsSHA256: [UInt8]
        let calibrationPlanSHA256: [UInt8]
        let corpusLockBundleSHA256: [UInt8]
        let spatialPolicyID: UInt8
        let lumaAnisotropyMode: ASHLUTAnisotropyModeV3
        let chromaAnisotropyMode: ASHLUTAnisotropyModeV3
        let lumaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
        let chromaCoordinatePolicy: ASHSpatialCoordinatePolicyV2
        let analysisGridSourceStep: UInt8
    }

    static func serialize(
        _ compilation: ASHLUTCompilationV3
    ) throws -> ASHLUTBinaryArtifactV3 {
        let configuration = compilation.configuration
        let selection = configuration.routeSelection(for: compilation.route)
        return try serialize(
            route: compilation.route,
            entries: compilation.entries,
            metadata: HeaderMetadata(
                mappingSHA256: configuration.mappingSHA256.bytes,
                operatorBankSHA256: configuration.operatorBankSHA256.bytes,
                metricPolicySHA256: configuration.metricPolicySHA256.bytes,
                compilerInputsSHA256: configuration.compilerInputsSHA256.bytes,
                calibrationPlanSHA256: configuration.calibrationPlanSHA256.bytes,
                corpusLockBundleSHA256: configuration.corpusLockBundleSHA256.bytes,
                spatialPolicyID: selection.spatialPolicyID,
                lumaAnisotropyMode: selection.lumaAnisotropyMode,
                chromaAnisotropyMode: selection.chromaAnisotropyMode,
                lumaCoordinatePolicy: selection.lumaCoordinatePolicy,
                chromaCoordinatePolicy: selection.chromaCoordinatePolicy,
                analysisGridSourceStep: selection.analysisGridSourceStep
            )
        )
    }

    /// Serializes the runtime-consumed ABI without manufacturing the four
    /// release-lock identities that do not exist for the P05 preview. Their
    /// reserved header fields stay zero; the two checked-in seed identities,
    /// payload SHA-256, CRCs, and all frame-math values remain explicit.
    static func serializeDevelopmentRuntime(
        route: ASHSpatialRouteV2,
        entries: [ASHLUTCompiledEntryV3],
        mappingSHA256: ASHLUTHashV3,
        operatorBankSHA256: ASHLUTHashV3,
        selection: ASHMetalRuntimeRouteSelectionV3
    ) throws -> ASHLUTBinaryArtifactV3 {
        let absentLockIdentity = [UInt8](
            repeating: 0,
            count: ASHLUTHashV3.byteCount
        )
        return try serialize(
            route: route,
            entries: entries,
            metadata: HeaderMetadata(
                mappingSHA256: mappingSHA256.bytes,
                operatorBankSHA256: operatorBankSHA256.bytes,
                metricPolicySHA256: absentLockIdentity,
                compilerInputsSHA256: absentLockIdentity,
                calibrationPlanSHA256: absentLockIdentity,
                corpusLockBundleSHA256: absentLockIdentity,
                spatialPolicyID: selection.spatialPolicyID ?? UInt8.max,
                lumaAnisotropyMode: selection.lumaAnisotropyMode,
                chromaAnisotropyMode: selection.chromaAnisotropyMode,
                lumaCoordinatePolicy: selection.lumaCoordinatePolicy,
                chromaCoordinatePolicy: selection.chromaCoordinatePolicy,
                analysisGridSourceStep: selection.analysisGridSourceStep
            )
        )
    }

    // swiftlint:disable:next function_body_length
    private static func serialize(
        route: ASHSpatialRouteV2,
        entries: [ASHLUTCompiledEntryV3],
        metadata: HeaderMetadata
    ) throws -> ASHLUTBinaryArtifactV3 {
        let expectedEntryCount = route.phasePairCount
            * ASHLUTBinaryContractV3.planeCount
            * ASHLUTBinaryContractV3.contextCount
            * ASHLUTBinaryContractV3.validStateCount
        guard entries.count == expectedEntryCount else {
            throw ASHLUTCompilerErrorV3.entryCountMismatch
        }

        var unique: [Data: ASHLUTParameterPairV3] = [:]
        for entry in entries {
            let prefix = encodeParameterPrefix(entry.parameters)
            unique[prefix] = entry.parameters
        }
        let sortedPrefixes = unique.keys.sorted { $0.lexicographicallyPrecedes($1) }
        let encodedParameters: [EncodedParameter] = sortedPrefixes.map { prefix in
            var full = prefix
            ASHLUTLittleEndianV3.append(ASHLUTCRC32V3.checksum(prefix), to: &full)
            return EncodedParameter(prefix: prefix, full: full)
        }
        let parameterIndexByPrefix = Dictionary(uniqueKeysWithValues: encodedParameters.enumerated().map {
            ($0.element.prefix, UInt32($0.offset))
        })
        var parameterBytes = Data()
        parameterBytes.reserveCapacity(encodedParameters.count * ASHLUTBinaryContractV3.parameterStride)
        for parameter in encodedParameters {
            parameterBytes.append(parameter.full)
        }

        let routeID = ASHLUTBinaryContractV3.routeID(route)
        var entryBytes = Data()
        entryBytes.reserveCapacity(entries.count * ASHLUTBinaryContractV3.entryStride)
        for entry in entries {
            let prefix = encodeParameterPrefix(entry.parameters)
            guard let parameterIndex = parameterIndexByPrefix[prefix] else {
                throw ASHLUTCompilerErrorV3.invalidLockedConfiguration
            }
            let parameter = encodedParameters[Int(parameterIndex)].full
            let firstTwenty = try encodeEntryPrefix(entry, parameterIndex: parameterIndex)
            var provenance = Data()
            ASHLUTLittleEndianV3.append(routeID, to: &provenance)
            ASHLUTLittleEndianV3.append(UInt32(entry.logicalIndex), to: &provenance)
            provenance.append(firstTwenty)
            provenance.append(parameter)
            var encodedEntry = firstTwenty
            ASHLUTLittleEndianV3.append(ASHLUTCRC32V3.checksum(provenance), to: &encodedEntry)
            entryBytes.append(encodedEntry)
        }

        var payload = parameterBytes
        payload.append(entryBytes)
        let payloadHash = sha256(payload)
        let payloadCRC = ASHLUTCRC32V3.checksum(payload)
        let parameterOffset = ASHLUTBinaryContractV3.headerSize
        let entryOffset = try checkedAdd(parameterOffset, parameterBytes.count)
        let fileSize = try checkedAdd(ASHLUTBinaryContractV3.headerSize, payload.count)
        var header = Data(repeating: 0, count: ASHLUTBinaryContractV3.headerSize)
        ASHLUTLittleEndianV3.write(bytes: ASHLUTBinaryContractV3.magic, at: 0, in: &header)
        ASHLUTLittleEndianV3.write(ASHLUTBinaryContractV3.majorVersion, at: 8, in: &header)
        ASHLUTLittleEndianV3.write(ASHLUTBinaryContractV3.minorVersion, at: 10, in: &header)
        ASHLUTLittleEndianV3.write(UInt16(ASHLUTBinaryContractV3.headerSize), at: 12, in: &header)
        ASHLUTLittleEndianV3.write(ASHLUTBinaryContractV3.endianTag, at: 14, in: &header)
        ASHLUTLittleEndianV3.write(routeID, at: 16, in: &header)
        ASHLUTLittleEndianV3.write(ASHLUTBinaryContractV3.requiredHeaderFlags, at: 18, in: &header)
        ASHLUTLittleEndianV3.write(UInt16(route.phasePairCount), at: 20, in: &header)
        ASHLUTLittleEndianV3.write(UInt16(ASHLUTBinaryContractV3.contextCount), at: 22, in: &header)
        ASHLUTLittleEndianV3.write(UInt16(ASHLUTBinaryContractV3.validStateCount), at: 24, in: &header)
        ASHLUTLittleEndianV3.write(UInt16(ASHLUTBinaryContractV3.entryStride), at: 26, in: &header)
        ASHLUTLittleEndianV3.write(UInt16(ASHLUTBinaryContractV3.parameterStride), at: 28, in: &header)
        ASHLUTLittleEndianV3.write(UInt16(ASHLUTBinaryContractV3.planeCount), at: 30, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(entries.count), at: 32, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(encodedParameters.count), at: 36, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(parameterOffset), at: 40, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(entryOffset), at: 44, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(parameterBytes.count), at: 48, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(entryBytes.count), at: 52, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(ASHLUTBinaryContractV3.headerSize), at: 56, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(payload.count), at: 60, in: &header)
        ASHLUTLittleEndianV3.write(bytes: metadata.mappingSHA256, at: 64, in: &header)
        ASHLUTLittleEndianV3.write(bytes: metadata.operatorBankSHA256, at: 96, in: &header)
        ASHLUTLittleEndianV3.write(bytes: metadata.metricPolicySHA256, at: 128, in: &header)
        ASHLUTLittleEndianV3.write(bytes: metadata.compilerInputsSHA256, at: 160, in: &header)
        ASHLUTLittleEndianV3.write(bytes: metadata.calibrationPlanSHA256, at: 192, in: &header)
        ASHLUTLittleEndianV3.write(bytes: metadata.corpusLockBundleSHA256, at: 224, in: &header)
        ASHLUTLittleEndianV3.write(bytes: payloadHash.bytes, at: 256, in: &header)
        ASHLUTLittleEndianV3.write(payloadCRC, at: 292, in: &header)
        ASHLUTLittleEndianV3.write(UInt32(fileSize), at: 296, in: &header)
        header[300] = metadata.spatialPolicyID
        header[301] = metadata.lumaAnisotropyMode.rawValue
        header[302] = metadata.chromaAnisotropyMode.rawValue
        header[303] = metadata.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1
        header[304] = metadata.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1
        header[305] = metadata.analysisGridSourceStep
        let headerCRC = ASHLUTCRC32V3.checksum(header)
        ASHLUTLittleEndianV3.write(headerCRC, at: 288, in: &header)
        var data = header
        data.append(payload)
        return ASHLUTBinaryArtifactV3(
            route: route,
            data: data,
            parameterCount: encodedParameters.count,
            payloadSHA256: payloadHash,
            wholeFileSHA256: sha256(data)
        )
    }
    private static func encodeEntryPrefix(
        _ entry: ASHLUTCompiledEntryV3,
        parameterIndex: UInt32
    ) throws -> Data {
        let primaryDecode = ASHCode.decodeAffine(
            received: entry.primary.affineState,
            anchor: entry.sourceState
        )
        guard primaryDecode.status == .exact,
              primaryDecode.messageBits == entry.primary.message.bits else {
            throw ASHLUTCompilerErrorV3.affineRecoveryFailed
        }
        var flags = ASHLUTBinaryContractV3.entryPrimaryExactVerified
        if entry.sourceAlignedExact { flags |= ASHLUTBinaryContractV3.entrySourceAlignedExact }
        if entry.temporalForcedSpatial { flags |= ASHLUTBinaryContractV3.entryTemporalForcedSpatial }
        var data = Data()
        ASHLUTLittleEndianV3.append(entry.primary.affineState.rawValue, to: &data)
        if let secondary = entry.secondary {
            let secondaryDecode = ASHCode.decodeAffine(received: secondary.affineState, anchor: entry.sourceState)
            guard secondaryDecode.status == .exact,
                  secondaryDecode.messageBits == secondary.message.bits,
                  entry.primaryWeightUNorm16 > 0,
                  entry.secondaryWeightUNorm16 > 0,
                  UInt32(entry.primaryWeightUNorm16) + UInt32(entry.secondaryWeightUNorm16) == UInt32(UInt16.max) else {
                throw ASHLUTCompilerErrorV3.affineRecoveryFailed
            }
            flags |= ASHLUTBinaryContractV3.entryHasSecondary
                | ASHLUTBinaryContractV3.entrySecondaryExactVerified
            ASHLUTLittleEndianV3.append(secondary.affineState.rawValue, to: &data)
            data.append(entry.primary.descriptorID)
            data.append(secondary.descriptorID)
            data.append(entry.primary.message.rawValue)
            data.append(secondary.message.rawValue)
        } else {
            guard entry.primaryWeightUNorm16 == UInt16.max,
                  entry.secondaryWeightUNorm16 == 0 else {
                throw ASHLUTCompilerErrorV3.invalidLockedConfiguration
            }
            ASHLUTLittleEndianV3.append(UInt16.max, to: &data)
            data.append(entry.primary.descriptorID)
            data.append(UInt8.max)
            data.append(entry.primary.message.rawValue)
            data.append(UInt8.max)
        }
        ASHLUTLittleEndianV3.append(entry.primaryWeightUNorm16, to: &data)
        ASHLUTLittleEndianV3.append(entry.secondaryWeightUNorm16, to: &data)
        ASHLUTLittleEndianV3.append(entry.marginUNorm16, to: &data)
        ASHLUTLittleEndianV3.append(flags, to: &data)
        ASHLUTLittleEndianV3.append(parameterIndex, to: &data)
        return data
    }
    private static func encodeParameterPrefix(_ parameter: ASHLUTParameterPairV3) -> Data {
        var data = Data()
        encode(parameter.primary, into: &data)
        encode(parameter.secondary, into: &data)
        ASHLUTLittleEndianV3.append(parameter.confidenceThresholdUNorm16, to: &data)
        data.append(parameter.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        data.append(parameter.boundaryMode == .clamp ? 0 : 1)
        data.append(1)
        data.append(0)
        data.append(parameter.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
        data.append(Data(repeating: 0, count: 5))
        return data
    }

    private static func encode(_ slot: ASHLUTParameterSlotV3, into data: inout Data) {
        ASHLUTLittleEndianV3.append(slot.anisotropyStrengthQ12, to: &data)
        ASHLUTLittleEndianV3.append(slot.minimumAnisotropicMagnitudeUNorm15, to: &data)
        ASHLUTLittleEndianV3.append(slot.minimumAnisotropicCoherenceUNorm15, to: &data)
        ASHLUTLittleEndianV3.append(slot.detailGainQ12, to: &data)
        ASHLUTLittleEndianV3.append(slot.relaxedLimiterAlphaQ12, to: &data)
        ASHLUTLittleEndianV3.append(slot.riskSuppressionUNorm15, to: &data)
        ASHLUTLittleEndianV3.append(slot.supportRadiusQ8x8, to: &data)
        ASHLUTLittleEndianV3.append(slot.weightEpsilonF32Bits, to: &data)
        data.append(UInt8(bitPattern: slot.delta.orientation))
        data.append(UInt8(bitPattern: slot.delta.support))
        data.append(UInt8(bitPattern: slot.delta.detail))
        data.append(UInt8(bitPattern: slot.delta.regularization))
        ASHLUTLittleEndianV3.append(slot.flags, to: &data)
    }
    private static func sha256(_ data: Data) -> ASHLUTHashV3 {
        ASHLUTHashV3(validatedBytes: Array(SHA256.hash(data: data)))
    }
    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow, result.partialValue <= Int(UInt32.max) else {
            throw ASHLUTCompilerErrorV3.arithmeticOverflow
        }
        return result.partialValue
    }
}

enum ASHLUTLittleEndianV3 {
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
