import Foundation
import XCTest
@testable import Mirmir

// swiftlint:disable type_body_length

final class ASHLockedNonASHSelectorV2Tests: XCTestCase {
    private enum ScalarReferenceError: Error {
        case invalidRule
        case invalidFeatureShape
        case invalidSelectorIndex
    }

    private static let featureBoundaries: [Int16] = [
        .min, -32_767, 0, 32_767, .max
    ]

    func test_preparedSelectorMatchesIndependentScalarForEveryRuleBoundaryRoutePhase() throws {
        let permitted = ASHLockedNonASHRuleV2.permittedValues.sorted()
        let cellPatterns = Self.featureBoundaries.map {
            [Int16](repeating: $0, count: ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count)
        }
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(route)
            let selection = fixture.runtime.configuration.routeSelection(for: route)
            for phaseOrdinal in 0..<route.phasePairCount {
                let phase = try ASHLockedControlRuntimeV2.nonASHPhaseFeatureValuesQ15(
                    phaseOrdinal: phaseOrdinal,
                    route: route,
                    selection: selection,
                    sourceWidth: 4,
                    sourceHeight: 4
                )
                for coordinate in ASHLockedNonASHRuleV2.coordinateOrder {
                    for value in permitted {
                        var values = Self.zeroCoordinates()
                        values[coordinate] = value
                        let rule = try ASHLockedNonASHRuleV2(coordinates: values)
                        for cell in cellPatterns {
                            try Self.assertPreparedMatchesScalar(
                                rule: rule,
                                cell: cell,
                                phase: phase,
                                label: "route=\(route.rawValue),phase=\(phaseOrdinal),"
                                    + "coordinate=\(coordinate),value=\(value),cell=\(cell[0])"
                            )
                        }
                    }
                }
            }
        }
    }

    func test_preparedSelectorMatchesScalarForEveryDescriptorFeatureAndBoundary() throws {
        let permitted = ASHLockedNonASHRuleV2.permittedValues.sorted()
        let cellCount = ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(route)
            let selection = fixture.runtime.configuration.routeSelection(for: route)
            for phaseOrdinal in 0..<route.phasePairCount {
                let routePhase = try ASHLockedControlRuntimeV2
                    .nonASHPhaseFeatureValuesQ15(
                        phaseOrdinal: phaseOrdinal,
                        route: route,
                        selection: selection,
                        sourceWidth: 4,
                        sourceHeight: 4
                    )
                for descriptor in 0..<ASHSpatialDescriptorV2.count {
                    var biased = Self.zeroCoordinates()
                    for candidate in 0..<ASHSpatialDescriptorV2.count {
                        biased[Self.biasName(candidate)] = candidate == descriptor ? 384 : -384
                    }
                    for (featureIndex, coordinate) in ASHLockedControlRuntimeV2
                        .nonASHFeatureOrder.enumerated() {
                        for weight in permitted {
                            var values = biased
                            values[coordinate] = weight
                            let rule = try ASHLockedNonASHRuleV2(coordinates: values)
                            for boundary in Self.featureBoundaries {
                                var cell = [Int16](repeating: 0, count: cellCount)
                                var phase = routePhase
                                if featureIndex < cellCount {
                                    cell[featureIndex] = boundary
                                } else {
                                    phase[featureIndex - cellCount] = boundary
                                }
                                try Self.assertPreparedMatchesScalar(
                                    rule: rule,
                                    cell: cell,
                                    phase: phase,
                                    label: "route=\(route.rawValue),phase=\(phaseOrdinal),"
                                        + "descriptor=\(descriptor),feature=\(coordinate),"
                                        + "weight=\(weight),boundary=\(boundary)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    func test_optimizedCacheBytesMatchIndependentScalarForEveryCoordinateValue() throws {
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(route)
            let cache = try ASHLockedReferencePipelineV2.prepareNonASHOutputCache(
                ASHLockedNonASHCacheInputV2(
                    luma: planes.luma,
                    cb: planes.cb,
                    cr: planes.cr,
                    chromaSiting: .left,
                    route: route,
                    configuration: fixture.runtime.configuration,
                    mapping: fixture.mapping
                )
            )
            for coordinate in ASHLockedNonASHRuleV2.coordinateOrder {
                for value in ASHLockedNonASHRuleV2.permittedValues.sorted() {
                    var values = Self.zeroCoordinates()
                    values[coordinate] = value
                    let rule = try ASHLockedNonASHRuleV2(coordinates: values)
                    XCTAssertEqual(
                        try cache.reconstructNV12(rule: rule),
                        try Self.scalarReconstruction(cache: cache, rule: rule),
                        "route=\(route.rawValue),coordinate=\(coordinate),value=\(value)"
                    )
                }
            }
        }
    }

    func test_preparedSelectorRejectsMalformedRulesShapesAndOverflowingOffsets() throws {
        var missing = Self.zeroCoordinates()
        missing.removeValue(forKey: ASHLockedNonASHRuleV2.coordinateOrder[0])
        XCTAssertThrowsError(try ASHLockedNonASHRuleV2(coordinates: missing)) {
            XCTAssertEqual($0 as? ASHLockedControlRuntimeV2Error, .invalidNonASHRule)
        }
        var extra = Self.zeroCoordinates()
        extra["foreign_coordinate"] = 0
        XCTAssertThrowsError(try ASHLockedNonASHRuleV2(coordinates: extra)) {
            XCTAssertEqual($0 as? ASHLockedControlRuntimeV2Error, .invalidNonASHRule)
        }
        var outside = Self.zeroCoordinates()
        outside[ASHLockedNonASHRuleV2.coordinateOrder[0]] = 385
        XCTAssertThrowsError(try ASHLockedNonASHRuleV2(coordinates: outside)) {
            XCTAssertEqual($0 as? ASHLockedControlRuntimeV2Error, .invalidNonASHRule)
        }

        let rule = try ASHLockedNonASHRuleV2(coordinates: Self.zeroCoordinates())
        let prepared = try ASHLockedControlRuntimeV2.prepareNonASHRule(rule)
        let cell = [Int16](
            repeating: 0,
            count: ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        )
        let phase = [Int16](
            repeating: 0,
            count: ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder.count
        )
        let malformed = [
            (Array(cell.dropLast()), 0, phase, 0),
            (cell, 0, Array(phase.dropLast()), 0),
            (cell, -1, phase, 0),
            (cell, 0, phase, -1),
            (cell, Int.max, phase, 0),
            (cell, 0, phase, Int.max)
        ]
        for (cellValues, cellOffset, phaseValues, phaseOffset) in malformed {
            XCTAssertThrowsError(try ASHLockedControlRuntimeV2.nonASHDescriptorID(
                preparedRule: prepared,
                cellFeatureValuesQ15: cellValues,
                cellOffset: cellOffset,
                phaseFeatureValuesQ15: phaseValues,
                phaseOffset: phaseOffset
            )) {
                XCTAssertEqual(
                    $0 as? ASHLockedControlRuntimeV2Error,
                    .invalidNonASHFeatureShape
                )
            }
        }

        let paddedCell = [Int16.min] + cell + [Int16.max]
        let paddedPhase = [Int16.min] + phase + [Int16.max]
        XCTAssertEqual(
            try ASHLockedControlRuntimeV2.nonASHDescriptorID(
                preparedRule: prepared,
                cellFeatureValuesQ15: paddedCell,
                cellOffset: 1,
                phaseFeatureValuesQ15: paddedPhase,
                phaseOffset: 1
            ),
            try Self.scalarDescriptor(rule: rule, cell: cell, phase: phase)
        )
    }

    func test_serializedCacheRejectsOverflowingArtifactDimensionsWithoutTrap() throws {
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let cache = try ASHLockedReferencePipelineV2.prepareNonASHOutputCache(
            ASHLockedNonASHCacheInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                route: .direct2x,
                configuration: fixture.runtime.configuration,
                mapping: fixture.mapping,
                inputFrameSHA256: ASHLUTHashV2(
                    validatedBytes: [UInt8](
                        repeating: 1,
                        count: ASHLUTHashV2.byteCount
                    )
                )
            )
        )
        var artifact = try cache.serializedArtifactData()
        let headerByteCount = Data("MIRMIR-NON-ASH-CACHE-V1\0".utf8).count
        let valuesOffset = headerByteCount + 1 + (2 * ASHLUTHashV2.byteCount)
        for fieldIndex in [4, 5] {
            let fieldOffset = valuesOffset + (fieldIndex * MemoryLayout<UInt32>.size)
            artifact.replaceSubrange(
                fieldOffset..<(fieldOffset + MemoryLayout<UInt32>.size),
                with: [UInt8](repeating: .max, count: MemoryLayout<UInt32>.size)
            )
        }

        XCTAssertThrowsError(try ASHLockedNonASHOutputCacheV2.loadSerializedArtifactData(
            artifact,
            configurationID: fixture.runtime.configuration.configurationID,
            expectedSharedBankConfigurationSHA256: cache.sharedBankConfigurationSHA256
        )) {
            XCTAssertEqual(
                $0 as? ASHLockedNonASHOutputCacheV2Error,
                .invalidArtifact
            )
        }

        let malformed = ASHLockedNonASHOutputCacheV2(
            route: cache.route,
            configurationID: cache.configurationID,
            sharedBankConfigurationSHA256: cache.sharedBankConfigurationSHA256,
            inputFrameSHA256: cache.inputFrameSHA256,
            inputLumaWidth: cache.inputLumaWidth,
            inputLumaHeight: cache.inputLumaHeight,
            inputChromaWidth: cache.inputChromaWidth,
            inputChromaHeight: cache.inputChromaHeight,
            outputLumaWidth: .max,
            outputLumaHeight: 2,
            outputChromaWidth: cache.outputChromaWidth,
            outputChromaHeight: cache.outputChromaHeight,
            analysisGridSourceStep: cache.analysisGridSourceStep,
            analysisCellCount: cache.analysisCellCount,
            cellFeatureValuesQ15: cache.cellFeatureValuesQ15,
            phaseFeatureValuesQ15: cache.phaseFeatureValuesQ15,
            lumaFeatureIndexes: cache.lumaFeatureIndexes,
            chromaFeatureIndexes: cache.chromaFeatureIndexes,
            descriptorOutputByteCount: cache.descriptorOutputByteCount,
            descriptorOutputTableNV12: cache.descriptorOutputTableNV12,
            analysisGridInvocationCount: cache.analysisGridInvocationCount,
            statefulLUTLookupCount: cache.statefulLUTLookupCount,
            descriptorPrecomputeCount: cache.descriptorPrecomputeCount
        )
        XCTAssertThrowsError(try malformed.serializedArtifactData()) {
            XCTAssertEqual(
                $0 as? ASHLockedNonASHOutputCacheV2Error,
                .invalidArtifact
            )
        }
    }

    private static func assertPreparedMatchesScalar(
        rule: ASHLockedNonASHRuleV2,
        cell: [Int16],
        phase: [Int16],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let prepared = try ASHLockedControlRuntimeV2.prepareNonASHRule(rule)
        let optimized = try ASHLockedControlRuntimeV2.nonASHDescriptorID(
            preparedRule: prepared,
            cellFeatureValuesQ15: cell,
            cellOffset: 0,
            phaseFeatureValuesQ15: phase,
            phaseOffset: 0
        )
        XCTAssertEqual(
            optimized,
            try scalarDescriptor(rule: rule, cell: cell, phase: phase),
            label,
            file: file,
            line: line
        )
    }

    private static func scalarDescriptor(
        rule: ASHLockedNonASHRuleV2,
        cell: [Int16],
        phase: [Int16]
    ) throws -> UInt8 {
        let cellOrder = ASHLockedControlRuntimeV2.nonASHCellFeatureOrder
        let phaseOrder = ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder
        let featureOrder = cellOrder + phaseOrder
        guard cell.count == cellOrder.count, phase.count == phaseOrder.count else {
            throw ScalarReferenceError.invalidFeatureShape
        }
        var bestDescriptor = UInt8(0)
        var bestScore = Int64.min
        for descriptor in 0..<ASHSpatialDescriptorV2.count {
            guard let bias = rule.coordinates[biasName(descriptor)] else {
                throw ScalarReferenceError.invalidRule
            }
            var score = Int64(bias) << 15
            for (index, coordinate) in featureOrder.enumerated() {
                guard let weight = rule.coordinates[coordinate] else {
                    throw ScalarReferenceError.invalidRule
                }
                let feature = index < cell.count ? cell[index] : phase[index - cell.count]
                score += Int64(
                    scalarSign(coordinate: coordinate, descriptor: UInt8(descriptor))
                        * weight
                ) * Int64(feature)
            }
            if score > bestScore {
                bestScore = score
                bestDescriptor = UInt8(descriptor)
            }
        }
        return bestDescriptor
    }

    private static func scalarReconstruction(
        cache: ASHLockedNonASHOutputCacheV2,
        rule: ASHLockedNonASHRuleV2
    ) throws -> Data {
        let featureCount = cache.featureRowCount
        let cellWidth = ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        let phaseWidth = ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder.count
        var descriptors = [UInt8](repeating: 0, count: featureCount)
        for featureIndex in 0..<featureCount {
            let cellIndex = featureIndex / cache.route.phasePairCount
            let phaseOrdinal = featureIndex % cache.route.phasePairCount
            let cell = Array(cache.cellFeatureValuesQ15[
                (cellIndex * cellWidth)..<((cellIndex + 1) * cellWidth)
            ])
            let phase = Array(cache.phaseFeatureValuesQ15[
                (phaseOrdinal * phaseWidth)..<((phaseOrdinal + 1) * phaseWidth)
            ])
            descriptors[featureIndex] = try scalarDescriptor(
                rule: rule,
                cell: cell,
                phase: phase
            )
        }
        let table = [UInt8](cache.descriptorOutputTableNV12)
        var output = [UInt8](repeating: 0, count: cache.descriptorOutputByteCount)
        for (pixelIndex, rawFeatureIndex) in cache.lumaFeatureIndexes.enumerated() {
            let featureIndex = Int(rawFeatureIndex)
            guard descriptors.indices.contains(featureIndex) else {
                throw ScalarReferenceError.invalidSelectorIndex
            }
            output[pixelIndex] = table[
                Int(descriptors[featureIndex]) * cache.descriptorOutputByteCount + pixelIndex
            ]
        }
        let lumaByteCount = cache.outputLumaWidth * cache.outputLumaHeight
        for (pixelIndex, rawFeatureIndex) in cache.chromaFeatureIndexes.enumerated() {
            let featureIndex = Int(rawFeatureIndex)
            guard descriptors.indices.contains(featureIndex) else {
                throw ScalarReferenceError.invalidSelectorIndex
            }
            let destinationOffset = lumaByteCount + 2 * pixelIndex
            let sourceOffset = Int(descriptors[featureIndex])
                * cache.descriptorOutputByteCount + destinationOffset
            output[destinationOffset] = table[sourceOffset]
            output[destinationOffset + 1] = table[sourceOffset + 1]
        }
        return Data(output)
    }

    private static func zeroCoordinates() -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: ASHLockedNonASHRuleV2.coordinateOrder.map {
                ($0, 0)
            }
        )
    }

    private static func biasName(_ descriptor: Int) -> String {
        String(format: "bias_descriptor_%02d_q8_8", descriptor)
    }

    private static func scalarSign(coordinate: String, descriptor: UInt8) -> Int {
        let bit: UInt8
        switch coordinate {
        case "weight_magnitude_q8_8", "weight_coherence_q8_8",
             "weight_orientation_cos_q8_8", "weight_orientation_sin_q8_8":
            bit = 0b0010
        case "weight_texture_q8_8", "weight_risk_q8_8":
            bit = 0b0100
        case "weight_chroma_alignment_q8_8", "weight_noise_q8_8":
            bit = 0b1000
        default:
            bit = 0b0001
        }
        return descriptor & bit == 0 ? -1 : 1
    }
}

// swiftlint:enable type_body_length
