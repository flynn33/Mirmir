import Foundation

// Immutable, fail-closed LUT decoding in the frozen validation order.

extension ASHLUTBinaryCodecV3 {
    private struct HeaderIdentity {
        let route: ASHSpatialRouteV2
        let routeID: UInt16
    }

    private struct Layout {
        let entryCount: Int
        let parameterCount: Int
        let parameterOffset: Int
        let entryOffset: Int
    }

    private struct ParameterTable {
        let values: [ASHLUTParameterPairV3]
        let records: [Data]
    }

    static func load(
        _ data: Data,
        expectedRoute: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTLoadedV3 {
        let identity = try validateHeader(
            data,
            expectedRoute: expectedRoute,
            configuration: configuration
        )
        let layout = try validateLayout(data, route: identity.route)
        let payloadHash = try validateIntegrity(data, configuration: configuration)
        let parameterTable = try loadParameters(
            data,
            layout: layout,
            route: identity.route,
            configuration: configuration
        )
        let entries = try loadEntries(
            data,
            layout: layout,
            identity: identity,
            parameterTable: parameterTable,
            configuration: configuration
        )
        try validateForcedSpatialContextMirrors(entries, route: identity.route)
        return ASHLUTLoadedV3(
            route: identity.route,
            configuration: configuration,
            entries: entries,
            parameters: parameterTable.values,
            payloadSHA256: payloadHash,
            wholeFileSHA256: validationSHA256(data),
            immutableBytes: data
        )
    }

    private static func validateHeader(
        _ data: Data,
        expectedRoute: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> HeaderIdentity {
        guard data.count >= ASHLUTBinaryContractV3.headerSize else {
            throw ASHLUTBinaryErrorV3.truncatedFile
        }
        guard Array(data[0..<8]) == ASHLUTBinaryContractV3.magic else {
            throw ASHLUTBinaryErrorV3.badMagic
        }
        guard ASHLUTLittleEndianV3.uint16(data, at: 8) == ASHLUTBinaryContractV3.majorVersion,
              ASHLUTLittleEndianV3.uint16(data, at: 10) == ASHLUTBinaryContractV3.minorVersion,
              ASHLUTLittleEndianV3.uint16(data, at: 12) == ASHLUTBinaryContractV3.headerSize else {
            throw ASHLUTBinaryErrorV3.unsupportedVersion
        }
        guard ASHLUTLittleEndianV3.uint16(data, at: 14) == ASHLUTBinaryContractV3.endianTag else {
            throw ASHLUTBinaryErrorV3.badEndianness
        }
        let routeID = ASHLUTLittleEndianV3.uint16(data, at: 16)
        guard let route = ASHLUTBinaryContractV3.route(id: routeID),
              route == expectedRoute else {
            throw ASHLUTBinaryErrorV3.invalidRoute
        }
        let headerFlags = ASHLUTLittleEndianV3.uint16(data, at: 18)
        guard headerFlags == ASHLUTBinaryContractV3.requiredHeaderFlags,
              ASHLUTLittleEndianV3.uint16(data, at: 30) == ASHLUTBinaryContractV3.planeCount,
              ASHLUTLockedRouteSelectionV3.admissibleSpatialPolicyIDs.contains(data[300]),
              ASHLUTAnisotropyModeV3(rawValue: data[301]) != nil,
              ASHLUTAnisotropyModeV3(rawValue: data[302]) != nil,
              data[303] <= 1,
              data[304] <= 1,
              data[305] == 1,
              data[306..<320].allSatisfy({ $0 == 0 }) else {
            throw ASHLUTBinaryErrorV3.reservedNonzero
        }
        let selection = configuration.routeSelection(for: route)
        guard data[300] == selection.spatialPolicyID,
              data[301] == selection.lumaAnisotropyMode.rawValue,
              data[302] == selection.chromaAnisotropyMode.rawValue,
              data[303] == (selection.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1),
              data[304] == (selection.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1) else {
            throw ASHLUTBinaryErrorV3.inputHashMismatch
        }
        return HeaderIdentity(route: route, routeID: routeID)
    }

    private static func validateLayout(
        _ data: Data,
        route: ASHSpatialRouteV2
    ) throws -> Layout {
        let phaseCount = Int(ASHLUTLittleEndianV3.uint16(data, at: 20))
        let contextCount = Int(ASHLUTLittleEndianV3.uint16(data, at: 22))
        let stateCount = Int(ASHLUTLittleEndianV3.uint16(data, at: 24))
        let entryStride = Int(ASHLUTLittleEndianV3.uint16(data, at: 26))
        let parameterStride = Int(ASHLUTLittleEndianV3.uint16(data, at: 28))
        let entryCount = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 32))
        let parameterCount = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 36))
        guard phaseCount == route.phasePairCount,
              contextCount == ASHLUTBinaryContractV3.contextCount,
              stateCount == ASHLUTBinaryContractV3.validStateCount,
              entryStride == ASHLUTBinaryContractV3.entryStride,
              parameterStride == ASHLUTBinaryContractV3.parameterStride,
              parameterCount > 0,
              entryCount == UInt64(
                ASHLUTBinaryContractV3.planeCount * phaseCount * contextCount * stateCount
              ) else {
            throw ASHLUTBinaryErrorV3.dimensionMismatch
        }

        let parameterOffset = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 40))
        let entryOffset = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 44))
        let parameterBytes = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 48))
        let entryBytes = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 52))
        let payloadOffset = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 56))
        let payloadBytes = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 60))
        let declaredFileSize = UInt64(ASHLUTLittleEndianV3.uint32(data, at: 296))
        let expectedParameterBytes = try checkedValidationMultiply(parameterCount, UInt64(parameterStride))
        let expectedEntryBytes = try checkedValidationMultiply(entryCount, UInt64(entryStride))
        let expectedEntryOffset = try checkedValidationAdd(
            UInt64(ASHLUTBinaryContractV3.headerSize),
            expectedParameterBytes
        )
        let expectedPayloadBytes = try checkedValidationAdd(expectedParameterBytes, expectedEntryBytes)
        let expectedFileSize = try checkedValidationAdd(
            UInt64(ASHLUTBinaryContractV3.headerSize),
            expectedPayloadBytes
        )
        guard parameterOffset == UInt64(ASHLUTBinaryContractV3.headerSize),
              entryOffset == expectedEntryOffset,
              parameterBytes == expectedParameterBytes,
              entryBytes == expectedEntryBytes,
              payloadOffset == UInt64(ASHLUTBinaryContractV3.headerSize),
              payloadBytes == expectedPayloadBytes else {
            throw ASHLUTBinaryErrorV3.offsetOrSizeOverflow
        }
        guard UInt64(data.count) >= declaredFileSize else {
            throw ASHLUTBinaryErrorV3.truncatedFile
        }
        guard declaredFileSize == expectedFileSize,
              UInt64(data.count) == declaredFileSize else {
            throw ASHLUTBinaryErrorV3.fileSizeMismatch
        }
        return Layout(
            entryCount: Int(entryCount),
            parameterCount: Int(parameterCount),
            parameterOffset: Int(parameterOffset),
            entryOffset: Int(entryOffset)
        )
    }

    private static func validateIntegrity(
        _ data: Data,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ASHLUTHashV3 {
        var header = Data(data[0..<ASHLUTBinaryContractV3.headerSize])
        ASHLUTLittleEndianV3.write(UInt32(0), at: 288, in: &header)
        guard ASHLUTCRC32V3.checksum(header) == ASHLUTLittleEndianV3.uint32(data, at: 288) else {
            throw ASHLUTBinaryErrorV3.headerCRCMismatch
        }
        let payload = Data(data[ASHLUTBinaryContractV3.headerSize..<data.count])
        guard ASHLUTCRC32V3.checksum(payload) == ASHLUTLittleEndianV3.uint32(data, at: 292) else {
            throw ASHLUTBinaryErrorV3.payloadCRCMismatch
        }
        let declaredPayloadHash = ASHLUTHashV3(
            validatedBytes: Array(data[256..<(256 + ASHLUTHashV3.byteCount)])
        )
        guard validationSHA256(payload) == declaredPayloadHash else {
            throw ASHLUTBinaryErrorV3.payloadSHAMismatch
        }
        let expectedHashes = [
            configuration.mappingSHA256,
            configuration.operatorBankSHA256,
            configuration.metricPolicySHA256,
            configuration.compilerInputsSHA256,
            configuration.calibrationPlanSHA256,
            configuration.corpusLockBundleSHA256
        ]
        for (index, expected) in expectedHashes.enumerated() {
            let offset = 64 + index * ASHLUTHashV3.byteCount
            let observed = ASHLUTHashV3(
                validatedBytes: Array(data[offset..<(offset + ASHLUTHashV3.byteCount)])
            )
            guard observed == expected else {
                throw ASHLUTBinaryErrorV3.inputHashMismatch
            }
        }
        return declaredPayloadHash
    }

    private static func loadParameters(
        _ data: Data,
        layout: Layout,
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> ParameterTable {
        var parameters: [ASHLUTParameterPairV3] = []
        var records: [Data] = []
        parameters.reserveCapacity(layout.parameterCount)
        records.reserveCapacity(layout.parameterCount)
        var previousPrefix: Data?
        for index in 0..<layout.parameterCount {
            let offset = layout.parameterOffset + index * ASHLUTBinaryContractV3.parameterStride
            let record = Data(data[offset..<(offset + ASHLUTBinaryContractV3.parameterStride)])
            let prefix = Data(record[0..<ASHLUTBinaryContractV3.parameterPrefixSize])
            guard ASHLUTCRC32V3.checksum(prefix) == ASHLUTLittleEndianV3.uint32(record, at: 60) else {
                throw ASHLUTBinaryErrorV3.parameterCRCMismatch
            }
            if let previousPrefix,
               !previousPrefix.lexicographicallyPrecedes(prefix) {
                throw ASHLUTBinaryErrorV3.dimensionMismatch
            }
            parameters.append(try decodeParameter(
                record,
                route: route,
                configuration: configuration
            ))
            records.append(record)
            previousPrefix = prefix
        }
        return ParameterTable(values: parameters, records: records)
    }

    private static func loadEntries(
        _ data: Data,
        layout: Layout,
        identity: HeaderIdentity,
        parameterTable: ParameterTable,
        configuration: ASHLUTLockedConfigurationV3
    ) throws -> [ASHLUTLoadedEntryV3] {
        var entries: [ASHLUTLoadedEntryV3] = []
        var referencedParameterIndices = Set<UInt32>()
        entries.reserveCapacity(layout.entryCount)
        for logicalIndex in 0..<layout.entryCount {
            let offset = layout.entryOffset + logicalIndex * ASHLUTBinaryContractV3.entryStride
            let record = Data(data[offset..<(offset + ASHLUTBinaryContractV3.entryStride)])
            let parameterIndex = ASHLUTLittleEndianV3.uint32(record, at: 16)
            guard Int(parameterIndex) < parameterTable.values.count else {
                throw ASHLUTBinaryErrorV3.parameterIndexOutOfBounds
            }
            referencedParameterIndices.insert(parameterIndex)
            var provenance = Data()
            ASHLUTLittleEndianV3.append(identity.routeID, to: &provenance)
            ASHLUTLittleEndianV3.append(UInt32(logicalIndex), to: &provenance)
            provenance.append(record[0..<20])
            provenance.append(parameterTable.records[Int(parameterIndex)])
            guard ASHLUTCRC32V3.checksum(provenance)
                    == ASHLUTLittleEndianV3.uint32(record, at: 20) else {
                throw ASHLUTBinaryErrorV3.entryCRCMismatch
            }
            entries.append(try decodeEntry(
                record,
                logicalIndex: logicalIndex,
                route: identity.route,
                parameter: parameterTable.values[Int(parameterIndex)],
                configuration: configuration
            ))
        }
        guard referencedParameterIndices.count == parameterTable.values.count else {
            throw ASHLUTBinaryErrorV3.dimensionMismatch
        }
        return entries
    }
}
