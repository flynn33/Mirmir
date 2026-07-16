import CryptoKit
import XCTest
@testable import Mirmir

final class ASHLockedReferencePipelineV2Tests: XCTestCase {
    func test_wholeFrameCPUReferenceConsumesOneImmutableLUTAndReportsExplicitRuntimeEvidence() throws {
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        for route in ASHSpatialRouteV2.allCases {
            let lockedFixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(route)
            let fixture = lockedFixture.runtime
            let output = try ASHLockedReferencePipelineV2.process(ASHLockedReferenceInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                lut: fixture.loaded,
                configuration: fixture.configuration,
                mapping: lockedFixture.mapping
            ))
            XCTAssertEqual(output.luma.width, try route.destinationExtent(for: planes.luma.width))
            XCTAssertEqual(output.luma.height, try route.destinationExtent(for: planes.luma.height))
            XCTAssertEqual(output.cb.width, try route.destinationExtent(for: planes.cb.width))
            XCTAssertEqual(output.cb.height, try route.destinationExtent(for: planes.cb.height))
            XCTAssertEqual(output.cr.width, output.cb.width)
            XCTAssertEqual(output.cr.height, output.cb.height)
            for plane in [output.luma, output.cb, output.cr] {
                XCTAssertEqual(plane.normalizedSamples.count, plane.width * plane.height)
                XCTAssertTrue(plane.normalizedSamples.allSatisfy {
                    $0.isFinite && (0.0...1.0).contains($0)
                })
            }

            let summary = output.summary
            let selection = fixture.configuration.routeSelection(for: route)
            XCTAssertEqual(summary.route, route)
            XCTAssertEqual(summary.lumaCoordinatePolicy, selection.lumaCoordinatePolicy)
            XCTAssertEqual(summary.chromaCoordinatePolicy, selection.chromaCoordinatePolicy)
            XCTAssertEqual(summary.analysisGridSourceStep, Int(selection.analysisGridSourceStep))
            XCTAssertEqual(summary.occupiedAnalysisCellCount, summary.analysisCellCount)
            XCTAssertEqual(summary.dispatchRecordCount, summary.analysisCellCount * route.phasePairCount)
            XCTAssertEqual(summary.stateHistogram.values.reduce(0, +), summary.analysisCellCount)
            XCTAssertEqual(summary.correctedDecodeCount, 0)
            XCTAssertEqual(summary.rejectedDecodeCount, 0)
            XCTAssertEqual(summary.affineFallbackCount, 0)
            XCTAssertEqual(summary.numericalFallbackCount, 0)
            XCTAssertGreaterThan(summary.exactDecodeCount, 0)
            XCTAssertLessThanOrEqual(summary.maximumOperatorEvaluations, 2)
            XCTAssertEqual(summary.runtimeTreeGenerationCount, 0)
            XCTAssertEqual(summary.runtimePathAllocationCount, 0)
            XCTAssertEqual(summary.cpuReferenceAnalysisTraversalCount, 1)
            XCTAssertEqual(summary.cpuReferenceFullFrameLoopCount, 3)
            XCTAssertFalse(summary.productionMetalConstraintEvaluated)
            XCTAssertEqual(summary.loadedLUTInstanceCount, 1)
            XCTAssertEqual(summary.perFrameLUTLoadCount, 0)
            XCTAssertEqual(summary.configurationID, fixture.configuration.configurationID)
            XCTAssertEqual(summary.mappingSHA256, fixture.configuration.mappingSHA256)
            XCTAssertEqual(summary.operatorBankSHA256, fixture.configuration.operatorBankSHA256)
            XCTAssertEqual(summary.metricPolicySHA256, fixture.configuration.metricPolicySHA256)
            XCTAssertEqual(summary.compilerInputsSHA256, fixture.configuration.compilerInputsSHA256)
            XCTAssertEqual(summary.calibrationPlanSHA256, fixture.configuration.calibrationPlanSHA256)
            XCTAssertEqual(summary.corpusLockBundleSHA256, fixture.configuration.corpusLockBundleSHA256)
            XCTAssertEqual(summary.lutPayloadSHA256, fixture.loaded.payloadSHA256)
            XCTAssertEqual(summary.lutWholeFileSHA256, fixture.loaded.wholeFileSHA256)
            XCTAssertEqual(summary.chromaOutputConvention, .normalizedZeroToOne)
            XCTAssertGreaterThanOrEqual(summary.analysisElapsedMilliseconds, 0.0)
            XCTAssertGreaterThanOrEqual(summary.dispatchElapsedMilliseconds, 0.0)
            XCTAssertGreaterThanOrEqual(summary.reconstructionElapsedMilliseconds, 0.0)
        }
    }
    func test_wholeFramePixelOutputIsDeterministic() throws {
        let lockedFixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let fixture = lockedFixture.runtime
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let input = ASHLockedReferenceInputV2(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .left,
            lut: fixture.loaded,
            configuration: fixture.configuration,
            mapping: lockedFixture.mapping
        )
        let first = try ASHLockedReferencePipelineV2.process(input)
        let second = try ASHLockedReferencePipelineV2.process(input)
        XCTAssertEqual(first.luma, second.luma)
        XCTAssertEqual(first.cb, second.cb)
        XCTAssertEqual(first.cr, second.cr)
        XCTAssertEqual(first.summary.stateHistogram, second.summary.stateHistogram)
        XCTAssertEqual(first.summary.operatorHistogram, second.summary.operatorHistogram)
    }
    func test_candidateAdapterBridgeConvertsNormalizedChromaToCenteredExactlyOnce() throws {
        let normalized = ASHLockedReferencePlaneOutputV2(
            width: 2,
            height: 2,
            normalizedSamples: [0.0, 0.25, 0.5, 1.0]
        )
        let centered = try ASHLockedCandidateAdapterBridgeV2.centeredChroma(normalized)
        XCTAssertEqual(centered.width, 2)
        XCTAssertEqual(centered.height, 2)
        XCTAssertEqual(centered.samples, [-0.5, -0.25, 0.0, 0.5])

        let invalid = ASHLockedReferencePlaneOutputV2(
            width: 1,
            height: 1,
            normalizedSamples: [1.01]
        )
        XCTAssertThrowsError(try ASHLockedCandidateAdapterBridgeV2.centeredChroma(invalid)) { error in
            XCTAssertEqual(
                error as? ASHLockedReferencePipelineV2Error,
                .invalidNormalizedChromaSample(0)
            )
        }
    }
    func test_wholeFrameRejectsConfigurationDifferentFromLoaderBinding() throws {
        let lockedFixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let fixture = lockedFixture.runtime
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let different = try ASHLockedRuntimeTestSupportV2.configurationCopy(
            fixture.configuration,
            configurationID: "ash-p06-frame-mismatch"
        )
        XCTAssertThrowsError(try ASHLockedReferencePipelineV2.process(ASHLockedReferenceInputV2(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .left,
            lut: fixture.loaded,
            configuration: different,
            mapping: lockedFixture.mapping
        ))) { error in
            XCTAssertEqual(
                error as? ASHLockedReferencePipelineV2Error,
                .mappingConfigurationMismatch
            )
        }
    }
    func test_lockedMappingRejectsThresholdBytesChangedUnderOriginalHash() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let changed = try ASHLockedRuntimeTestSupportV2.lockedMappingData(
            edgePresentLow: 4_915
        )
        XCTAssertThrowsError(try ASHLockedVideoMappingV2.load(
            changed,
            expectedSHA256: fixture.runtime.configuration.mappingSHA256
        )) { error in
            XCTAssertEqual(error as? ASHLockedVideoMappingV2Error, .hashMismatch)
        }
    }
    func test_lockedMappingAcceptsAliasRiskFloorBand() throws {
        let data = try ASHLockedRuntimeTestSupportV2.lockedMappingData(
            aliasRiskLow: 0,
            aliasRiskHigh: 3_277
        )
        let hash = ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: data)))
        let mapping = try ASHLockedVideoMappingV2.load(data, expectedSHA256: hash)
        XCTAssertEqual(mapping.analyzerConfiguration.bands.aliasOrRingingRisk.low, 0.0)
        XCTAssertEqual(
            mapping.analyzerConfiguration.bands.aliasOrRingingRisk.high,
            3_277.0 / 32_767.0
        )

        let invalidGenericData = try ASHLockedRuntimeTestSupportV2.lockedMappingData(
            edgePresentLow: 0
        )
        let invalidGenericHash = ASHLUTHashV2(
            validatedBytes: Array(SHA256.hash(data: invalidGenericData))
        )
        XCTAssertThrowsError(try ASHLockedVideoMappingV2.load(
            invalidGenericData,
            expectedSHA256: invalidGenericHash
        )) { error in
            XCTAssertEqual(error as? ASHLockedVideoMappingV2Error, .invalidValue)
        }
    }
    func test_wholeFrameRejectsMappingWithChangedThresholdsAndDifferentHash() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let changedData = try ASHLockedRuntimeTestSupportV2.lockedMappingData(
            edgePresentLow: 4_915
        )
        let changedHash = ASHLUTHashV2(
            validatedBytes: Array(SHA256.hash(data: changedData))
        )
        let changedMapping = try ASHLockedVideoMappingV2.load(
            changedData,
            expectedSHA256: changedHash
        )
        XCTAssertThrowsError(try ASHLockedReferencePipelineV2.process(
            ASHLockedReferenceInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                lut: fixture.runtime.loaded,
                configuration: fixture.runtime.configuration,
                mapping: changedMapping
            )
        )) { error in
            XCTAssertEqual(
                error as? ASHLockedReferencePipelineV2Error,
                .mappingHashMismatch
            )
        }
    }
    func test_dispatchProjectionReusesExactGridAndAlternatesReconstructionOrder() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let measurement = try ASHLockedReferencePipelineV2.measureDispatchProjection(
            ASHLockedReferenceInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                lut: fixture.runtime.loaded,
                configuration: fixture.runtime.configuration,
                mapping: fixture.mapping
            )
        )
        XCTAssertEqual(
            measurement.measurementDomain,
            "native_cpu_reference_projection_not_metal"
        )
        XCTAssertEqual(measurement.warmupRepetitionCount, 3)
        XCTAssertEqual(measurement.repetitions.count, 10)
        XCTAssertEqual(measurement.fullOutput.luma, measurement.controlOutput.luma)
        XCTAssertEqual(measurement.fullOutput.cb, measurement.controlOutput.cb)
        XCTAssertEqual(measurement.fullOutput.cr, measurement.controlOutput.cr)
        for (index, repetition) in measurement.repetitions.enumerated() {
            XCTAssertEqual(repetition.index, index)
            XCTAssertEqual(
                repetition.order,
                index.isMultiple(of: 2) ? .fullThenControl : .controlThenFull
            )
            XCTAssertGreaterThanOrEqual(repetition.fullAnalysisMilliseconds, 0.0)
            XCTAssertGreaterThanOrEqual(repetition.fullDispatchMilliseconds, 0.0)
            XCTAssertGreaterThan(repetition.fullReconstructionMilliseconds, 0.0)
            XCTAssertGreaterThan(repetition.controlReconstructionMilliseconds, 0.0)
        }
    }
}

extension ASHLockedReferencePipelineV2Tests {
    func test_fixedDescriptorControlUsesOneUniformOperatorWithoutBranching() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let output = try ASHLockedReferencePipelineV2.processControlDispatch(
            ASHLockedReferenceInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                lut: fixture.runtime.loaded,
                configuration: fixture.runtime.configuration,
                mapping: fixture.mapping
            ),
            mode: .fixedDescriptor(7)
        )
        XCTAssertEqual(output.summary.operatorHistogram, [7: output.summary.dispatchRecordCount])
        XCTAssertEqual(output.summary.maximumOperatorEvaluations, 1)
        XCTAssertEqual(output.summary.affineFallbackCount, 0)
        XCTAssertEqual(output.summary.runtimeTreeGenerationCount, 0)
        XCTAssertEqual(output.summary.runtimePathAllocationCount, 0)
    }

    func test_stateOnlyControlUsesBaseDescriptorAndZeroMessageForEveryCellPhase() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct3Over2)
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let grid = try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .left,
            step: Int(
                fixture.runtime.configuration.routeSelection(for: .direct3Over2)
                    .analysisGridSourceStep
            ),
            boundary: fixture.runtime.configuration.boundaryMode,
            configuration: fixture.mapping.analyzerConfiguration
        )
        let dispatch = try ASHLockedControlRuntimeV2.makeDispatchGrid(
            lut: fixture.runtime.loaded,
            configuration: fixture.runtime.configuration,
            analysisGrid: grid,
            mode: .stateOnly
        )
        for cell in grid.cells {
            let state = try ASHLUTLeafCompilerV2.spatialSemanticState(cell.analysis.state)
            for phaseOrdinal in 0..<ASHSpatialRouteV2.direct3Over2.phasePairCount {
                let record = try dispatch.dispatch(
                    cellColumn: cell.column,
                    cellRow: cell.row,
                    phaseOrdinal: phaseOrdinal
                )
                XCTAssertEqual(
                    record.primary.descriptor.id,
                    ASHLUTLeafCompilerV2.baseDescriptorID(
                        state: state,
                        phaseOrdinal: phaseOrdinal,
                        route: .direct3Over2
                    )
                )
                XCTAssertEqual(record.primary.decodedMessage.rawValue, 0)
                XCTAssertNil(record.secondary)
                XCTAssertEqual(record.primaryWeightUNorm16, UInt16.max)
                XCTAssertEqual(record.secondaryWeightUNorm16, 0)
                XCTAssertFalse(record.affineFallbackUsed)
            }
        }
    }

    func test_zeroNonASHRuleSelectsSmallestDescriptorOnEveryExactTie() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let rule = try ASHLockedNonASHRuleV2(
            coordinates: Dictionary(
                uniqueKeysWithValues: ASHLockedNonASHRuleV2.coordinateOrder.map {
                    ($0, 0)
                }
            )
        )
        let output = try ASHLockedReferencePipelineV2.processControlDispatch(
            ASHLockedReferenceInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                lut: fixture.runtime.loaded,
                configuration: fixture.runtime.configuration,
                mapping: fixture.mapping
            ),
            mode: .nonASHSelector(rule)
        )
        XCTAssertEqual(output.summary.operatorHistogram, [0: output.summary.dispatchRecordCount])
        XCTAssertEqual(output.summary.maximumOperatorEvaluations, 1)
    }

    func test_nonASHOutputCacheMatchesLegacyForEveryCoordinateValueAndBothRoutes() throws {
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let permittedValues = ASHLockedNonASHRuleV2.permittedValues.sorted()
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(route)
            let input = ASHLockedReferenceInputV2(
                luma: planes.luma,
                cb: planes.cb,
                cr: planes.cr,
                chromaSiting: .left,
                lut: fixture.runtime.loaded,
                configuration: fixture.runtime.configuration,
                mapping: fixture.mapping
            )
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
            XCTAssertEqual(cache.analysisGridInvocationCount, 1)
            XCTAssertEqual(cache.statefulLUTLookupCount, 0)
            XCTAssertEqual(cache.descriptorPrecomputeCount, 16)
            let expectedColumns = (
                planes.luma.width + cache.analysisGridSourceStep - 1
            ) / cache.analysisGridSourceStep
            let expectedRows = (
                planes.luma.height + cache.analysisGridSourceStep - 1
            ) / cache.analysisGridSourceStep
            XCTAssertEqual(cache.analysisCellCount, expectedColumns * expectedRows)
            XCTAssertFalse(try cache.featureTensorQ15Data().isEmpty)
            for descriptor in 0..<ASHSpatialDescriptorV2.count {
                XCTAssertEqual(
                    try cache.descriptorOutputNV12(descriptorID: descriptor).count,
                    cache.descriptorOutputByteCount
                )
            }

            let zero = Dictionary(
                uniqueKeysWithValues: ASHLockedNonASHRuleV2.coordinateOrder.map {
                    ($0, 0)
                }
            )
            for coordinate in ASHLockedNonASHRuleV2.coordinateOrder {
                for value in permittedValues {
                    var values = zero
                    values[coordinate] = value
                    let rule = try ASHLockedNonASHRuleV2(coordinates: values)
                    let cached = try cache.reconstructNV12(rule: rule)
                    let legacy = try ASHLockedReferencePipelineV2.processControlDispatch(
                        input,
                        mode: .nonASHSelector(rule)
                    )
                    let legacyBytes = try ASHLockedNonASHOutputCacheV2.encodeCommonNV12(
                        ASHLockedControlFrameV2(
                            luma: legacy.luma,
                            cb: legacy.cb,
                            cr: legacy.cr
                        )
                    )
                    XCTAssertEqual(
                        cached,
                        legacyBytes,
                        "route=\(route.rawValue), coordinate=\(coordinate), value=\(value)"
                    )
                }
            }
        }
    }

    func test_nonASHAndFixedControlDispatchDoNotReadCellState() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct2x)
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let grid = try ASHAnalysisGridBuilderV2.build(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .left,
            step: Int(
                fixture.runtime.configuration.routeSelection(for: .direct2x)
                    .analysisGridSourceStep
            ),
            boundary: fixture.runtime.configuration.boundaryMode,
            configuration: fixture.mapping.analyzerConfiguration
        )
        let zeroRule = try ASHLockedNonASHRuleV2(
            coordinates: Dictionary(
                uniqueKeysWithValues: ASHLockedNonASHRuleV2.coordinateOrder.map {
                    ($0, 0)
                }
            )
        )
        for mode in [
            ASHLockedDispatchControlModeV2.fixedDescriptor(7),
            .nonASHSelector(zeroRule)
        ] {
            let dispatch = try ASHLockedControlRuntimeV2.makeDispatchGrid(
                route: .direct2x,
                configuration: fixture.runtime.configuration,
                analysisGrid: grid,
                mode: mode
            )
            XCTAssertTrue(dispatch.dispatches.allSatisfy {
                $0.sourceState.rawValue == 0
                    && $0.primary.decodedMessage.rawValue == 0
                    && $0.secondary == nil
            })
        }
    }

    func test_conventionalAndNearestControlsUseLockedGeometryDeterministically() throws {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(.direct3Over2)
        let planes = try ASHLockedRuntimeTestSupportV2.planes(width: 4, height: 4)
        let input = ASHLockedReferenceInputV2(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: .left,
            lut: fixture.runtime.loaded,
            configuration: fixture.runtime.configuration,
            mapping: fixture.mapping
        )
        for algorithm in ASHLockedConventionalAlgorithmV2.allCases {
            let first = try ASHLockedControlResamplerV2.conventional(
                input: input,
                algorithm: algorithm
            )
            let second = try ASHLockedControlResamplerV2.conventional(
                input: input,
                algorithm: algorithm
            )
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.luma.width, 6)
            XCTAssertEqual(first.luma.height, 6)
            XCTAssertEqual(first.cb.width, 3)
            XCTAssertEqual(first.cb.height, 3)
            XCTAssertTrue(first.luma.normalizedSamples.allSatisfy {
                $0.isFinite && (0.0...1.0).contains($0)
            })
        }
        let nearest = try ASHLockedControlResamplerV2.nearest(input: input)
        XCTAssertEqual(nearest.luma.width, 6)
        XCTAssertEqual(nearest.luma.height, 6)
        let normalizedSource = planes.luma.range.normalizeLuma(planes.luma.codes[0])
        XCTAssertEqual(nearest.luma.normalizedSamples[0], normalizedSource)
        XCTAssertEqual(nearest.luma.normalizedSamples[1], normalizedSource)
    }

}
