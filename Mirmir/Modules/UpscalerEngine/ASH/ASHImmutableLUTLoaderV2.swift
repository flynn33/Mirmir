import Foundation

// Immutable, fail-closed LUT decoding in the frozen validation order.

extension ASHLUTBinaryCodecV2 {
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
        let values: [ASHLUTParameterPairV2]
        let records: [Data]
    }

    static func load(
        _ data: Data,
        expectedRoute: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLUTLoadedV2 {
        let identity = try validateHeader(data, expectedRoute: expectedRoute)
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
        return ASHLUTLoadedV2(
            route: identity.route,
            configuration: configuration,
            entries: entries,
            parameters: parameterTable.values,
            payloadSHA256: payloadHash,
            wholeFileSHA256: validationSHA256(data),
            immutableBytes: data
        )
    }

    static func load(
        _ data: Data,
        manifestRoute: ASHLockedLUTManifestRouteV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLUTLoadedV2 {
        guard manifestRoute.configuration == configuration else {
            throw ASHLockedLUTManifestErrorV2.configurationMismatch
        }
        guard data.count == manifestRoute.wholeFileSizeBytes,
              validationSHA256(data) == manifestRoute.wholeFileSHA256 else {
            throw ASHLockedLUTManifestErrorV2.wholeFileHashMismatch
        }
        let loaded = try load(
            data,
            expectedRoute: manifestRoute.route,
            configuration: configuration
        )
        guard loaded.payloadSHA256 == manifestRoute.payloadSHA256 else {
            throw ASHLockedLUTManifestErrorV2.payloadHashMismatch
        }
        let selection = configuration.routeSelection(for: loaded.route)
        guard loaded.entries.count == manifestRoute.entryCount,
              loaded.parameters.count == manifestRoute.parameterCount,
              selection.lumaCoordinatePolicy == manifestRoute.lumaCoordinatePolicy,
              selection.chromaCoordinatePolicy == manifestRoute.chromaCoordinatePolicy,
              selection.analysisGridSourceStep
                == manifestRoute.analysisGridSourceStep else {
            throw ASHLockedLUTManifestErrorV2.routeIdentityMismatch
        }
        guard ASHLUTLittleEndianV2.uint32(data, at: 288) == manifestRoute.headerCRC32,
              ASHLUTLittleEndianV2.uint32(data, at: 292) == manifestRoute.payloadCRC32 else {
            throw ASHLockedLUTManifestErrorV2.checksumMismatch
        }
        return loaded
    }

    private static func validateHeader(
        _ data: Data,
        expectedRoute: ASHSpatialRouteV2
    ) throws -> HeaderIdentity {
        guard data.count >= ASHLUTBinaryContractV2.headerSize else {
            throw ASHLUTBinaryErrorV2.truncatedFile
        }
        guard Array(data[0..<8]) == ASHLUTBinaryContractV2.magic else {
            throw ASHLUTBinaryErrorV2.badMagic
        }
        guard ASHLUTLittleEndianV2.uint16(data, at: 8) == ASHLUTBinaryContractV2.majorVersion,
              ASHLUTLittleEndianV2.uint16(data, at: 10) == ASHLUTBinaryContractV2.minorVersion,
              ASHLUTLittleEndianV2.uint16(data, at: 12) == ASHLUTBinaryContractV2.headerSize else {
            throw ASHLUTBinaryErrorV2.unsupportedVersion
        }
        guard ASHLUTLittleEndianV2.uint16(data, at: 14) == ASHLUTBinaryContractV2.endianTag else {
            throw ASHLUTBinaryErrorV2.badEndianness
        }
        let routeID = ASHLUTLittleEndianV2.uint16(data, at: 16)
        guard let route = ASHLUTBinaryContractV2.route(id: routeID),
              route == expectedRoute else {
            throw ASHLUTBinaryErrorV2.invalidRoute
        }
        let headerFlags = ASHLUTLittleEndianV2.uint16(data, at: 18)
        guard headerFlags == ASHLUTBinaryContractV2.requiredHeaderFlags,
              ASHLUTLittleEndianV2.uint16(data, at: 30) == 0,
              data[300..<320].allSatisfy({ $0 == 0 }) else {
            throw ASHLUTBinaryErrorV2.reservedNonzero
        }
        return HeaderIdentity(route: route, routeID: routeID)
    }

    private static func validateLayout(
        _ data: Data,
        route: ASHSpatialRouteV2
    ) throws -> Layout {
        let phaseCount = Int(ASHLUTLittleEndianV2.uint16(data, at: 20))
        let contextCount = Int(ASHLUTLittleEndianV2.uint16(data, at: 22))
        let stateCount = Int(ASHLUTLittleEndianV2.uint16(data, at: 24))
        let entryStride = Int(ASHLUTLittleEndianV2.uint16(data, at: 26))
        let parameterStride = Int(ASHLUTLittleEndianV2.uint16(data, at: 28))
        let entryCount = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 32))
        let parameterCount = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 36))
        guard phaseCount == route.phasePairCount,
              contextCount == ASHLUTBinaryContractV2.contextCount,
              stateCount == ASHLUTBinaryContractV2.validStateCount,
              entryStride == ASHLUTBinaryContractV2.entryStride,
              parameterStride == ASHLUTBinaryContractV2.parameterStride,
              parameterCount > 0,
              entryCount == UInt64(phaseCount * contextCount * stateCount) else {
            throw ASHLUTBinaryErrorV2.dimensionMismatch
        }

        let parameterOffset = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 40))
        let entryOffset = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 44))
        let parameterBytes = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 48))
        let entryBytes = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 52))
        let payloadOffset = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 56))
        let payloadBytes = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 60))
        let declaredFileSize = UInt64(ASHLUTLittleEndianV2.uint32(data, at: 296))
        let expectedParameterBytes = try checkedValidationMultiply(parameterCount, UInt64(parameterStride))
        let expectedEntryBytes = try checkedValidationMultiply(entryCount, UInt64(entryStride))
        let expectedEntryOffset = try checkedValidationAdd(
            UInt64(ASHLUTBinaryContractV2.headerSize),
            expectedParameterBytes
        )
        let expectedPayloadBytes = try checkedValidationAdd(expectedParameterBytes, expectedEntryBytes)
        let expectedFileSize = try checkedValidationAdd(
            UInt64(ASHLUTBinaryContractV2.headerSize),
            expectedPayloadBytes
        )
        guard parameterOffset == UInt64(ASHLUTBinaryContractV2.headerSize),
              entryOffset == expectedEntryOffset,
              parameterBytes == expectedParameterBytes,
              entryBytes == expectedEntryBytes,
              payloadOffset == UInt64(ASHLUTBinaryContractV2.headerSize),
              payloadBytes == expectedPayloadBytes else {
            throw ASHLUTBinaryErrorV2.offsetOrSizeOverflow
        }
        guard UInt64(data.count) >= declaredFileSize else {
            throw ASHLUTBinaryErrorV2.truncatedFile
        }
        guard declaredFileSize == expectedFileSize,
              UInt64(data.count) == declaredFileSize else {
            throw ASHLUTBinaryErrorV2.fileSizeMismatch
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
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHLUTHashV2 {
        var header = Data(data[0..<ASHLUTBinaryContractV2.headerSize])
        ASHLUTLittleEndianV2.write(UInt32(0), at: 288, in: &header)
        guard ASHLUTCRC32V2.checksum(header) == ASHLUTLittleEndianV2.uint32(data, at: 288) else {
            throw ASHLUTBinaryErrorV2.headerCRCMismatch
        }
        let payload = Data(data[ASHLUTBinaryContractV2.headerSize..<data.count])
        guard ASHLUTCRC32V2.checksum(payload) == ASHLUTLittleEndianV2.uint32(data, at: 292) else {
            throw ASHLUTBinaryErrorV2.payloadCRCMismatch
        }
        let declaredPayloadHash = ASHLUTHashV2(
            validatedBytes: Array(data[256..<(256 + ASHLUTHashV2.byteCount)])
        )
        guard validationSHA256(payload) == declaredPayloadHash else {
            throw ASHLUTBinaryErrorV2.payloadSHAMismatch
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
            let offset = 64 + index * ASHLUTHashV2.byteCount
            let observed = ASHLUTHashV2(
                validatedBytes: Array(data[offset..<(offset + ASHLUTHashV2.byteCount)])
            )
            guard observed == expected else {
                throw ASHLUTBinaryErrorV2.inputHashMismatch
            }
        }
        return declaredPayloadHash
    }

    private static func loadParameters(
        _ data: Data,
        layout: Layout,
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ParameterTable {
        var parameters: [ASHLUTParameterPairV2] = []
        var records: [Data] = []
        parameters.reserveCapacity(layout.parameterCount)
        records.reserveCapacity(layout.parameterCount)
        var previousPrefix: Data?
        for index in 0..<layout.parameterCount {
            let offset = layout.parameterOffset + index * ASHLUTBinaryContractV2.parameterStride
            let record = Data(data[offset..<(offset + ASHLUTBinaryContractV2.parameterStride)])
            let prefix = Data(record[0..<ASHLUTBinaryContractV2.parameterPrefixSize])
            guard ASHLUTCRC32V2.checksum(prefix) == ASHLUTLittleEndianV2.uint32(record, at: 60) else {
                throw ASHLUTBinaryErrorV2.parameterCRCMismatch
            }
            if let previousPrefix,
               !previousPrefix.lexicographicallyPrecedes(prefix) {
                throw ASHLUTBinaryErrorV2.dimensionMismatch
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
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> [ASHLUTLoadedEntryV2] {
        var entries: [ASHLUTLoadedEntryV2] = []
        var referencedParameterIndices = Set<UInt32>()
        entries.reserveCapacity(layout.entryCount)
        for logicalIndex in 0..<layout.entryCount {
            let offset = layout.entryOffset + logicalIndex * ASHLUTBinaryContractV2.entryStride
            let record = Data(data[offset..<(offset + ASHLUTBinaryContractV2.entryStride)])
            let parameterIndex = ASHLUTLittleEndianV2.uint32(record, at: 16)
            guard Int(parameterIndex) < parameterTable.values.count else {
                throw ASHLUTBinaryErrorV2.parameterIndexOutOfBounds
            }
            referencedParameterIndices.insert(parameterIndex)
            var provenance = Data()
            ASHLUTLittleEndianV2.append(identity.routeID, to: &provenance)
            ASHLUTLittleEndianV2.append(UInt32(logicalIndex), to: &provenance)
            provenance.append(record[0..<20])
            provenance.append(parameterTable.records[Int(parameterIndex)])
            guard ASHLUTCRC32V2.checksum(provenance)
                    == ASHLUTLittleEndianV2.uint32(record, at: 20) else {
                throw ASHLUTBinaryErrorV2.entryCRCMismatch
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
            throw ASHLUTBinaryErrorV2.dimensionMismatch
        }
        return entries
    }
}
