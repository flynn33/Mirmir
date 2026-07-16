import Foundation

// swiftlint:disable file_length

enum ASHLockedNonASHOutputCacheV2Error: Error, Equatable, Sendable {
    case invalidGeometry
    case invalidFeatureTensor
    case invalidSelectorIndex
    case invalidDescriptorOutput
    case nonfiniteOutput
    case invalidArtifact
}

struct ASHLockedNonASHCacheInputV2: Sendable {
    let luma: ASHVideoAnalyzerV2CodePlane
    let cb: ASHVideoAnalyzerV2CodePlane
    let cr: ASHVideoAnalyzerV2CodePlane
    let chromaSiting: ASHChromaSitingV2
    let route: ASHSpatialRouteV2
    let configuration: ASHLUTLockedConfigurationV2
    let mapping: ASHLockedVideoMappingV2
    let inputFrameSHA256: ASHLUTHashV2?

    init(
        luma: ASHVideoAnalyzerV2CodePlane,
        cb: ASHVideoAnalyzerV2CodePlane,
        cr: ASHVideoAnalyzerV2CodePlane,
        chromaSiting: ASHChromaSitingV2,
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2,
        mapping: ASHLockedVideoMappingV2,
        inputFrameSHA256: ASHLUTHashV2? = nil
    ) {
        self.luma = luma
        self.cb = cb
        self.cr = cr
        self.chromaSiting = chromaSiting
        self.route = route
        self.configuration = configuration
        self.mapping = mapping
        self.inputFrameSHA256 = inputFrameSHA256
    }
}

struct ASHLockedNonASHOutputCacheV2: Sendable {
    private static let artifactHeader = Data("MIRMIR-NON-ASH-CACHE-V1\0".utf8)
    let route: ASHSpatialRouteV2
    let configurationID: String
    let sharedBankConfigurationSHA256: ASHLUTHashV2
    let inputFrameSHA256: ASHLUTHashV2?
    let inputLumaWidth: Int
    let inputLumaHeight: Int
    let inputChromaWidth: Int
    let inputChromaHeight: Int
    let outputLumaWidth: Int
    let outputLumaHeight: Int
    let outputChromaWidth: Int
    let outputChromaHeight: Int
    let analysisGridSourceStep: Int
    let analysisCellCount: Int
    let cellFeatureValuesQ15: [Int16]
    let phaseFeatureValuesQ15: [Int16]
    let lumaFeatureIndexes: [Int32]
    let chromaFeatureIndexes: [Int32]
    let descriptorOutputByteCount: Int
    let descriptorOutputTableNV12: Data
    let analysisGridInvocationCount: Int
    let statefulLUTLookupCount: Int
    let descriptorPrecomputeCount: Int

    var featureRowCount: Int {
        analysisCellCount * route.phasePairCount
    }

    func descriptorOutputNV12(descriptorID: Int) throws -> Data {
        guard (0..<ASHSpatialDescriptorV2.count).contains(descriptorID),
              descriptorOutputByteCount > 0,
              descriptorOutputTableNV12.count
                == descriptorOutputByteCount * ASHSpatialDescriptorV2.count else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidDescriptorOutput
        }
        let lower = descriptorID * descriptorOutputByteCount
        return descriptorOutputTableNV12.subdata(
            in: lower..<(lower + descriptorOutputByteCount)
        )
    }

    func featureTensorQ15Data() throws -> Data {
        let cellWidth = ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        let phaseWidth = ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder.count
        guard analysisCellCount > 0,
              cellFeatureValuesQ15.count == analysisCellCount * cellWidth,
              phaseFeatureValuesQ15.count == route.phasePairCount * phaseWidth else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidFeatureTensor
        }
        var data = Data("MIRMIR-NON-ASH-FEATURE-Q15-V1\0".utf8)
        appendLittleEndian(UInt32(analysisCellCount), to: &data)
        appendLittleEndian(UInt32(route.phasePairCount), to: &data)
        appendLittleEndian(UInt16(cellWidth + phaseWidth), to: &data)
        data.reserveCapacity(
            data.count + featureRowCount * (cellWidth + phaseWidth) * 2
        )
        for cellIndex in 0..<analysisCellCount {
            let cellOffset = cellIndex * cellWidth
            for phaseOrdinal in 0..<route.phasePairCount {
                let phaseOffset = phaseOrdinal * phaseWidth
                for index in 0..<cellWidth {
                    appendLittleEndian(
                        UInt16(bitPattern: cellFeatureValuesQ15[cellOffset + index]),
                        to: &data
                    )
                }
                for index in 0..<phaseWidth {
                    appendLittleEndian(
                        UInt16(bitPattern: phaseFeatureValuesQ15[phaseOffset + index]),
                        to: &data
                    )
                }
            }
        }
        return data
    }

    func reconstructNV12(rule: ASHLockedNonASHRuleV2) throws -> Data {
        let cellWidth = ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        let phaseWidth = ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder.count
        let featureCount = featureRowCount
        guard analysisGridInvocationCount == 1,
              statefulLUTLookupCount == 0,
              descriptorPrecomputeCount == ASHSpatialDescriptorV2.count,
              featureCount > 0,
              cellFeatureValuesQ15.count == analysisCellCount * cellWidth,
              phaseFeatureValuesQ15.count == route.phasePairCount * phaseWidth,
              lumaFeatureIndexes.count == outputLumaWidth * outputLumaHeight,
              chromaFeatureIndexes.count == outputChromaWidth * outputChromaHeight,
              descriptorOutputByteCount
                == outputLumaWidth * outputLumaHeight
                    + (2 * outputChromaWidth * outputChromaHeight),
              descriptorOutputTableNV12.count
                == descriptorOutputByteCount * ASHSpatialDescriptorV2.count else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidFeatureTensor
        }

        let preparedRule = try ASHLockedControlRuntimeV2.prepareNonASHRule(rule)
        var selectedDescriptors = [UInt8](repeating: 0, count: featureCount)
        for featureIndex in 0..<featureCount {
            if featureIndex.isMultiple(of: 4_096) {
                try Task.checkCancellation()
            }
            let cellIndex = featureIndex / route.phasePairCount
            let phaseOrdinal = featureIndex % route.phasePairCount
            selectedDescriptors[featureIndex] = try ASHLockedControlRuntimeV2
                .nonASHDescriptorID(
                    preparedRule: preparedRule,
                    cellFeatureValuesQ15: cellFeatureValuesQ15,
                    cellOffset: cellIndex * cellWidth,
                    phaseFeatureValuesQ15: phaseFeatureValuesQ15,
                    phaseOffset: phaseOrdinal * phaseWidth
                )
        }

        var output = Data(count: descriptorOutputByteCount)
        try descriptorOutputTableNV12.withUnsafeBytes { sourceBytes in
            try output.withUnsafeMutableBytes { destinationBytes in
                guard let source = sourceBytes.bindMemory(to: UInt8.self).baseAddress,
                      let destination = destinationBytes.bindMemory(to: UInt8.self).baseAddress else {
                    throw ASHLockedNonASHOutputCacheV2Error.invalidDescriptorOutput
                }
                for pixelIndex in lumaFeatureIndexes.indices {
                    let featureIndex = Int(lumaFeatureIndexes[pixelIndex])
                    guard (0..<featureCount).contains(featureIndex) else {
                        throw ASHLockedNonASHOutputCacheV2Error.invalidSelectorIndex
                    }
                    let descriptor = Int(selectedDescriptors[featureIndex])
                    destination[pixelIndex] = source[
                        descriptor * descriptorOutputByteCount + pixelIndex
                    ]
                }
                let lumaByteCount = outputLumaWidth * outputLumaHeight
                for pixelIndex in chromaFeatureIndexes.indices {
                    let featureIndex = Int(chromaFeatureIndexes[pixelIndex])
                    guard (0..<featureCount).contains(featureIndex) else {
                        throw ASHLockedNonASHOutputCacheV2Error.invalidSelectorIndex
                    }
                    let descriptor = Int(selectedDescriptors[featureIndex])
                    let destinationOffset = lumaByteCount + (2 * pixelIndex)
                    let sourceOffset = descriptor * descriptorOutputByteCount
                        + destinationOffset
                    destination[destinationOffset] = source[sourceOffset]
                    destination[destinationOffset + 1] = source[sourceOffset + 1]
                }
            }
        }
        return output
    }

    func serializedArtifactData() throws -> Data {
        let cellWidth = ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        let phaseWidth = ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder.count
        let expectedCellFeatureCount = try Self.checkedMultiply(
            analysisCellCount,
            cellWidth
        )
        let expectedPhaseFeatureCount = try Self.checkedMultiply(
            route.phasePairCount,
            phaseWidth
        )
        let expectedLumaIndexCount = try Self.checkedMultiply(
            outputLumaWidth,
            outputLumaHeight
        )
        let expectedChromaIndexCount = try Self.checkedMultiply(
            outputChromaWidth,
            outputChromaHeight
        )
        let expectedChromaByteCount = try Self.checkedMultiply(
            2,
            expectedChromaIndexCount
        )
        let expectedDescriptorOutputByteCount = try Self.checkedAdd(
            expectedLumaIndexCount,
            expectedChromaByteCount
        )
        let expectedDescriptorTableCount = try Self.checkedMultiply(
            descriptorOutputByteCount,
            ASHSpatialDescriptorV2.count
        )
        guard analysisGridInvocationCount == 1,
              statefulLUTLookupCount == 0,
              descriptorPrecomputeCount == ASHSpatialDescriptorV2.count,
              analysisGridSourceStep > 0,
              analysisCellCount > 0,
              cellFeatureValuesQ15.count == expectedCellFeatureCount,
              phaseFeatureValuesQ15.count == expectedPhaseFeatureCount,
              lumaFeatureIndexes.count == expectedLumaIndexCount,
              chromaFeatureIndexes.count == expectedChromaIndexCount,
              descriptorOutputByteCount == expectedDescriptorOutputByteCount,
              descriptorOutputTableNV12.count
                == expectedDescriptorTableCount,
              let encodedCellFeatureCount = UInt32(
                exactly: cellFeatureValuesQ15.count
              ),
              let encodedPhaseFeatureCount = UInt32(
                exactly: phaseFeatureValuesQ15.count
              ),
              let encodedLumaIndexCount = UInt32(exactly: lumaFeatureIndexes.count),
              let encodedChromaIndexCount = UInt32(
                exactly: chromaFeatureIndexes.count
              ),
              let encodedDescriptorTableCount = UInt32(
                exactly: descriptorOutputTableNV12.count
              ) else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        var data = Self.artifactHeader
        data.append(route == .direct2x ? 1 : 2)
        data.append(contentsOf: sharedBankConfigurationSHA256.bytes)
        guard let inputFrameSHA256 else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        data.append(contentsOf: inputFrameSHA256.bytes)
        for value in [
            inputLumaWidth, inputLumaHeight,
            inputChromaWidth, inputChromaHeight,
            outputLumaWidth, outputLumaHeight,
            outputChromaWidth, outputChromaHeight,
            analysisGridSourceStep, analysisCellCount, descriptorOutputByteCount
        ] {
            guard let encoded = UInt32(exactly: value) else {
                throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
            }
            appendLittleEndian(encoded, to: &data)
        }
        appendLittleEndian(encodedCellFeatureCount, to: &data)
        for value in cellFeatureValuesQ15 {
            appendLittleEndian(UInt16(bitPattern: value), to: &data)
        }
        appendLittleEndian(encodedPhaseFeatureCount, to: &data)
        for value in phaseFeatureValuesQ15 {
            appendLittleEndian(UInt16(bitPattern: value), to: &data)
        }
        appendLittleEndian(encodedLumaIndexCount, to: &data)
        for value in lumaFeatureIndexes {
            appendLittleEndian(UInt32(bitPattern: value), to: &data)
        }
        appendLittleEndian(encodedChromaIndexCount, to: &data)
        for value in chromaFeatureIndexes {
            appendLittleEndian(UInt32(bitPattern: value), to: &data)
        }
        appendLittleEndian(encodedDescriptorTableCount, to: &data)
        data.append(descriptorOutputTableNV12)
        return data
    }
}

extension ASHLockedNonASHOutputCacheV2 {
    static func loadSerializedArtifactData(
        _ data: Data,
        configurationID: String,
        expectedSharedBankConfigurationSHA256: ASHLUTHashV2
    ) throws -> ASHLockedNonASHOutputCacheV2 {
        var reader = ArtifactReader(data: data)
        guard try reader.readData(count: artifactHeader.count) == artifactHeader else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let route: ASHSpatialRouteV2
        switch try reader.readUInt8() {
        case 1: route = .direct2x
        case 2: route = .direct3Over2
        default: throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let bank = ASHLUTHashV2(
            validatedBytes: Array(try reader.readData(count: ASHLUTHashV2.byteCount))
        )
        guard bank == expectedSharedBankConfigurationSHA256 else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let inputFrameSHA256 = ASHLUTHashV2(
            validatedBytes: Array(try reader.readData(count: ASHLUTHashV2.byteCount))
        )
        var values: [Int] = []
        values.reserveCapacity(11)
        for _ in 0..<11 {
            values.append(Int(try reader.readUInt32()))
        }
        let inputLumaWidth = values[0]
        let inputLumaHeight = values[1]
        let inputChromaWidth = values[2]
        let inputChromaHeight = values[3]
        let outputLumaWidth = values[4]
        let outputLumaHeight = values[5]
        let outputChromaWidth = values[6]
        let outputChromaHeight = values[7]
        let analysisGridSourceStep = values[8]
        let analysisCellCount = values[9]
        let descriptorOutputByteCount = values[10]
        let cellCount = try checkedMultiply(
            analysisCellCount,
            ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        )
        let phaseCount = try checkedMultiply(
            route.phasePairCount,
            ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder.count
        )
        let lumaIndexCount = try checkedMultiply(
            outputLumaWidth,
            outputLumaHeight
        )
        let chromaIndexCount = try checkedMultiply(
            outputChromaWidth,
            outputChromaHeight
        )
        let chromaByteCount = try checkedMultiply(2, chromaIndexCount)
        let expectedDescriptorOutputByteCount = try checkedAdd(
            lumaIndexCount,
            chromaByteCount
        )
        let descriptorTableCount = try checkedMultiply(
            descriptorOutputByteCount,
            ASHSpatialDescriptorV2.count
        )
        let doubledInputChromaWidth = try checkedMultiply(2, inputChromaWidth)
        let doubledInputChromaHeight = try checkedMultiply(2, inputChromaHeight)
        let doubledOutputChromaWidth = try checkedMultiply(2, outputChromaWidth)
        let doubledOutputChromaHeight = try checkedMultiply(2, outputChromaHeight)
        guard let encodedCellCount = UInt32(exactly: cellCount) else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        guard inputLumaWidth > 0,
              inputLumaHeight > 0,
              inputChromaWidth > 0,
              inputChromaHeight > 0,
              outputLumaWidth > 0,
              outputLumaHeight > 0,
              outputChromaWidth > 0,
              outputChromaHeight > 0,
              analysisGridSourceStep > 0,
              analysisCellCount > 0,
              inputLumaWidth == doubledInputChromaWidth,
              inputLumaHeight == doubledInputChromaHeight,
              outputLumaWidth == doubledOutputChromaWidth,
              outputLumaHeight == doubledOutputChromaHeight,
              descriptorOutputByteCount
                == expectedDescriptorOutputByteCount,
              try reader.readUInt32() == encodedCellCount else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let metadata = ArtifactMetadata(
            route: route,
            configurationID: configurationID,
            bank: bank,
            inputFrameSHA256: inputFrameSHA256,
            values: values,
            cellCount: cellCount,
            phaseCount: phaseCount,
            lumaIndexCount: lumaIndexCount,
            chromaIndexCount: chromaIndexCount,
            descriptorTableCount: descriptorTableCount
        )
        return try readArtifactPayload(from: &reader, metadata: metadata)
    }

    private static func readArtifactPayload(
        from reader: inout ArtifactReader,
        metadata: ArtifactMetadata
    ) throws -> ASHLockedNonASHOutputCacheV2 {
        let cellFeatures = try reader.readInt16Array(count: metadata.cellCount)
        guard let encodedPhaseCount = UInt32(exactly: metadata.phaseCount),
              try reader.readUInt32() == encodedPhaseCount else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let phaseFeatures = try reader.readInt16Array(count: metadata.phaseCount)
        guard let encodedLumaIndexCount = UInt32(exactly: metadata.lumaIndexCount),
              try reader.readUInt32() == encodedLumaIndexCount else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let lumaIndexes = try reader.readInt32Array(count: metadata.lumaIndexCount)
        guard let encodedChromaIndexCount = UInt32(exactly: metadata.chromaIndexCount),
              try reader.readUInt32() == encodedChromaIndexCount else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let chromaIndexes = try reader.readInt32Array(count: metadata.chromaIndexCount)
        guard let encodedDescriptorTableCount = UInt32(
                exactly: metadata.descriptorTableCount
              ),
              try reader.readUInt32() == encodedDescriptorTableCount else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let descriptorTable = try reader.readData(count: metadata.descriptorTableCount)
        guard reader.isAtEnd else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        let featureRowCount = try checkedMultiply(
            metadata.values[9],
            metadata.route.phasePairCount
        )
        guard lumaIndexes.allSatisfy({ (0..<featureRowCount).contains(Int($0)) }),
              chromaIndexes.allSatisfy({
                  (0..<featureRowCount).contains(Int($0))
              }) else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        return ASHLockedNonASHOutputCacheV2(
            route: metadata.route,
            configurationID: metadata.configurationID,
            sharedBankConfigurationSHA256: metadata.bank,
            inputFrameSHA256: metadata.inputFrameSHA256,
            inputLumaWidth: metadata.values[0],
            inputLumaHeight: metadata.values[1],
            inputChromaWidth: metadata.values[2],
            inputChromaHeight: metadata.values[3],
            outputLumaWidth: metadata.values[4],
            outputLumaHeight: metadata.values[5],
            outputChromaWidth: metadata.values[6],
            outputChromaHeight: metadata.values[7],
            analysisGridSourceStep: metadata.values[8],
            analysisCellCount: metadata.values[9],
            cellFeatureValuesQ15: cellFeatures,
            phaseFeatureValuesQ15: phaseFeatures,
            lumaFeatureIndexes: lumaIndexes,
            chromaFeatureIndexes: chromaIndexes,
            descriptorOutputByteCount: metadata.values[10],
            descriptorOutputTableNV12: descriptorTable,
            analysisGridInvocationCount: 1,
            statefulLUTLookupCount: 0,
            descriptorPrecomputeCount: ASHSpatialDescriptorV2.count
        )
    }

    static func encodeCommonNV12(
        _ frame: ASHLockedControlFrameV2
    ) throws -> Data {
        let luma = frame.luma
        let cb = frame.cb
        let cr = frame.cr
        guard luma.width == cb.width * 2,
              luma.height == cb.height * 2,
              cb.width == cr.width,
              cb.height == cr.height,
              luma.normalizedSamples.count == luma.width * luma.height,
              cb.normalizedSamples.count == cb.width * cb.height,
              cr.normalizedSamples.count == cr.width * cr.height else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidGeometry
        }
        var result = Data()
        result.reserveCapacity(luma.width * luma.height * 3 / 2)
        for value in luma.normalizedSamples {
            result.append(try quantize(value * 219.0 + 16.0))
        }
        for index in cb.normalizedSamples.indices {
            result.append(try quantize(cb.normalizedSamples[index] * 224.0 + 16.0))
            result.append(try quantize(cr.normalizedSamples[index] * 224.0 + 16.0))
        }
        return result
    }

    private static func quantize(_ value: Double) throws -> UInt8 {
        guard value.isFinite else {
            throw ASHLockedNonASHOutputCacheV2Error.nonfiniteOutput
        }
        let rounded = value.rounded(.toNearestOrEven)
        return UInt8(min(255.0, max(0.0, rounded)))
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        return result
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
        }
        return result
    }

    private func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private struct ArtifactMetadata {
        let route: ASHSpatialRouteV2
        let configurationID: String
        let bank: ASHLUTHashV2
        let inputFrameSHA256: ASHLUTHashV2
        let values: [Int]
        let cellCount: Int
        let phaseCount: Int
        let lumaIndexCount: Int
        let chromaIndexCount: Int
        let descriptorTableCount: Int
    }

    private struct ArtifactReader {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else {
                throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
            }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readUInt16() throws -> UInt16 {
            let low = UInt16(try readUInt8())
            let high = UInt16(try readUInt8())
            return low | (high << 8)
        }

        mutating func readUInt32() throws -> UInt32 {
            var result: UInt32 = 0
            for shift in stride(from: 0, through: 24, by: 8) {
                result |= UInt32(try readUInt8()) << UInt32(shift)
            }
            return result
        }

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0,
                  count <= data.count,
                  offset <= data.count - count else {
                throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
            }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func readInt16Array(count: Int) throws -> [Int16] {
            guard count >= 0,
                  count <= (data.count - offset) / MemoryLayout<UInt16>.size else {
                throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
            }
            var result: [Int16] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                result.append(Int16(bitPattern: try readUInt16()))
            }
            return result
        }

        mutating func readInt32Array(count: Int) throws -> [Int32] {
            guard count >= 0,
                  count <= (data.count - offset) / MemoryLayout<UInt32>.size else {
                throw ASHLockedNonASHOutputCacheV2Error.invalidArtifact
            }
            var result: [Int32] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                result.append(Int32(bitPattern: try readUInt32()))
            }
            return result
        }
    }
}

// swiftlint:enable file_length
