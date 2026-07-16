import XCTest
@testable import Mirmir

final class ASHSpatialDispatchV2Tests: XCTestCase {
    func test_routePhaseCardinalityMatchesDirectContracts() throws {
        for route in ASHSpatialRouteV2.allCases {
            var phases = Set<ASHSpatialPhaseV2>()
            for row in 0..<route.scaleNumerator {
                for column in 0..<route.scaleNumerator {
                    phases.insert(try ASHSpatialPhaseV2.sourceAlignedDevelopment(
                        horizontalIndex: column,
                        verticalIndex: row,
                        route: route
                    ))
                }
            }
            XCTAssertEqual(phases.count, route.phasePairCount)
        }
        XCTAssertEqual(ASHSpatialRouteV2.direct2x.phasePairCount, 4)
        XCTAssertEqual(ASHSpatialRouteV2.direct3Over2.phasePairCount, 9)
    }

    func test_allValidStatesAndRoutePhasesUseExactBoundedAffineRecovery() throws {
        var descriptorIDs = Set<UInt8>()
        var dispatchCount = 0

        for route in ASHSpatialRouteV2.allCases {
            for vertical in 0..<route.scaleNumerator {
                for horizontal in 0..<route.scaleNumerator {
                    let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
                        horizontalIndex: horizontal,
                        verticalIndex: vertical,
                        route: route
                    )
                    for raw in UInt16(0)..<UInt16(1 << ASHState.bitCount) {
                        let state = try ASHState(rawValue: raw)
                        guard state.hasValidIntegrity else { continue }
                        let dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(
                            state: state,
                            phase: phase
                        )
                        dispatchCount += 1
                        descriptorIDs.insert(dispatch.primaryDecodedMessage.rawValue)
                        XCTAssertFalse(dispatch.parityWasRecomputed)
                        XCTAssertLessThanOrEqual(dispatch.operatorEvaluationCount, 2)
                        assertExact(
                            dispatch.primaryAffineState,
                            message: dispatch.primaryDecodedMessage,
                            anchor: state
                        )
                        if let secondary = dispatch.secondaryDecodedMessage,
                           let secondaryAffine = dispatch.secondaryAffineState {
                            assertExact(secondaryAffine, message: secondary, anchor: state)
                        }
                    }
                }
            }
        }

        XCTAssertEqual(dispatchCount, 256 * (4 + 9))
        XCTAssertEqual(descriptorIDs, Set(UInt8(0)..<UInt8(16)))
    }

    func test_stateInputChangesDispatchUnderTheSamePhase() throws {
        let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
            horizontalIndex: 1,
            verticalIndex: 1,
            route: .direct3Over2
        )
        let flatState = try ASHState(payloadBits: [0, 0, 0, 0, 0, 0, 0, 1])
        let structuredState = try ASHState(payloadBits: [1, 0, 1, 1, 1, 0, 0, 1])

        let flat = try ASHSpatialDevelopmentSelectorV2.dispatch(state: flatState, phase: phase)
        let structured = try ASHSpatialDevelopmentSelectorV2.dispatch(state: structuredState, phase: phase)

        XCTAssertNotEqual(flat.primaryDecodedMessage, structured.primaryDecodedMessage)
        XCTAssertNotEqual(flat.primaryAffineState, structured.primaryAffineState)
    }

    func test_productionPhasesInfluenceOnlyTheKernelAxisForBothCoordinatePolicies() throws {
        let plane = try ASHSpatialPlaneV2(
            width: 6,
            height: 6,
            samples: Array(repeating: 0.5, count: 36)
        )
        let state = try ASHState(payloadBits: [1, 0, 1, 1, 0, 0, 0, 1])

        for policy in ASHSpatialCoordinatePolicyV2.allCases {
            for route in ASHSpatialRouteV2.allCases {
                var messages = Set<UInt8>()
                for row in 0..<route.scaleNumerator {
                    for column in 0..<route.scaleNumerator {
                        let phase = try ASHSpatialOperatorBankV2.phase(
                            destinationColumn: column,
                            destinationRow: row,
                            plane: plane,
                            route: route,
                            policy: policy
                        )
                        messages.insert(try ASHSpatialDevelopmentSelectorV2.dispatch(
                            state: state,
                            phase: phase
                        ).primaryDecodedMessage.rawValue)
                    }
                }
                XCTAssertGreaterThan(
                    messages.count,
                    1,
                    "route: \(route.rawValue), policy: \(policy.rawValue)"
                )
            }
        }
    }

    func test_stateDisabledControlUsesNeutralSelectorStateAndDiffers() throws {
        let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
            horizontalIndex: 1,
            verticalIndex: 0,
            route: .direct2x
        )
        let state = try ASHState(payloadBits: [1, 1, 1, 1, 1, 0, 0, 1])
        let enabled = try ASHSpatialDevelopmentSelectorV2.dispatch(state: state, phase: phase)
        let disabled = try ASHSpatialDevelopmentSelectorV2.dispatch(
            state: state,
            phase: phase,
            stateInputEnabled: false
        )

        XCTAssertNotEqual(enabled.primaryDecodedMessage, disabled.primaryDecodedMessage)
        XCTAssertNotEqual(enabled.selectorState, disabled.selectorState)
        XCTAssertEqual(
            disabled.selectorState,
            try ASHState(payloadBits: Array(repeating: 0, count: ASHState.payloadBitCount))
        )
    }

    func test_allValidStatePhaseDispatchesPreserveHardSemanticConstraints() throws {
        let plane = try ASHSpatialPlaneV2(
            width: 6,
            height: 6,
            samples: Array(repeating: 0.5, count: 36)
        )

        for policy in ASHSpatialCoordinatePolicyV2.allCases {
            for route in ASHSpatialRouteV2.allCases {
                for row in 0..<route.scaleNumerator {
                    for column in 0..<route.scaleNumerator {
                        let phase = try ASHSpatialOperatorBankV2.phase(
                            destinationColumn: column,
                            destinationRow: row,
                            plane: plane,
                            route: route,
                            policy: policy
                        )
                        try assertHardConstraintsForEveryState(phase: phase)
                    }
                }
            }
        }
    }

    func test_stateDisabledControlPreservesRealPhaseConditioning() throws {
        let plane = try ASHSpatialPlaneV2(
            width: 6,
            height: 6,
            samples: Array(repeating: 0.5, count: 36)
        )
        let sourceState = try ASHState(payloadBits: [1, 1, 1, 1, 1, 0, 0, 1])

        for policy in ASHSpatialCoordinatePolicyV2.allCases {
            for route in ASHSpatialRouteV2.allCases {
                var messages = Set<UInt8>()
                for row in 0..<route.scaleNumerator {
                    for column in 0..<route.scaleNumerator {
                        let phase = try ASHSpatialOperatorBankV2.phase(
                            destinationColumn: column,
                            destinationRow: row,
                            plane: plane,
                            route: route,
                            policy: policy
                        )
                        messages.insert(try ASHSpatialDevelopmentSelectorV2.dispatch(
                            state: sourceState,
                            phase: phase,
                            stateInputEnabled: false
                        ).primaryDecodedMessage.rawValue)
                    }
                }
                XCTAssertGreaterThan(messages.count, 1)
            }
        }
    }

    func test_sitingCorrectedExactPhasesRemainBoundedAndInfluential() throws {
        let sourceExtent = 6
        let sourceState = try ASHState(payloadBits: [1, 0, 1, 1, 0, 0, 0, 1])

        for siting in ASHChromaSitingV2.allCases {
            for policy in ASHSpatialCoordinatePolicyV2.allCases {
                for route in ASHSpatialRouteV2.allCases {
                    let destinationExtent = try route.destinationExtent(for: sourceExtent)
                    var phases = Set<ASHSpatialPhaseV2>()
                    var messages = Set<UInt8>()
                    for row in 0..<route.scaleNumerator {
                        for column in 0..<route.scaleNumerator {
                            let phase = ASHSpatialPhaseV2(
                                horizontal: ASHSpatialPhaseComponentV2(coordinate: try siting.sourceCoordinate(
                                    destinationIndex: column,
                                    sourceExtent: sourceExtent,
                                    destinationExtent: destinationExtent,
                                    policy: policy,
                                    axis: .horizontal
                                )),
                                vertical: ASHSpatialPhaseComponentV2(coordinate: try siting.sourceCoordinate(
                                    destinationIndex: row,
                                    sourceExtent: sourceExtent,
                                    destinationExtent: destinationExtent,
                                    policy: policy,
                                    axis: .vertical
                                ))
                            )
                            phases.insert(phase)
                            messages.insert(try ASHSpatialDevelopmentSelectorV2.dispatch(
                                state: sourceState,
                                phase: phase
                            ).primaryDecodedMessage.rawValue)
                        }
                    }
                    XCTAssertEqual(phases.count, route.phasePairCount)
                    XCTAssertGreaterThan(messages.count, 1)
                }
            }
        }
    }

    func test_lowConfidenceDispatchHasExactlyTwoDistinctDescriptors() throws {
        let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
            horizontalIndex: 0,
            verticalIndex: 1,
            route: .direct2x
        )
        let lowConfidence = try ASHState(payloadBits: [0, 0, 1, 0, 1, 1, 0, 0])
        let dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(state: lowConfidence, phase: phase)

        XCTAssertEqual(dispatch.operatorEvaluationCount, 2)
        XCTAssertNotEqual(dispatch.primaryDecodedMessage, dispatch.secondaryDecodedMessage)
        XCTAssertEqual(dispatch.primaryWeight + dispatch.secondaryWeight, 1.0, accuracy: 1e-12)
        XCTAssertLessThan(dispatch.margin, ASHSpatialDevelopmentSelectorV2.confidenceThreshold)
    }

    func test_invalidParityIsRecomputedBeforeAffineSelection() throws {
        let valid = try ASHState(payloadBits: [1, 0, 1, 1, 0, 0, 0, 1])
        let damaged = valid.toggled(coordinate: 9)
        let phase = try ASHSpatialPhaseV2.sourceAlignedDevelopment(
            horizontalIndex: 0,
            verticalIndex: 0,
            route: .direct3Over2
        )
        let dispatch = try ASHSpatialDevelopmentSelectorV2.dispatch(state: damaged, phase: phase)

        XCTAssertTrue(dispatch.parityWasRecomputed)
        XCTAssertEqual(dispatch.sourceState, valid)
        XCTAssertEqual(
            ASHCode.decodeAffine(
                received: dispatch.primaryAffineState,
                anchor: dispatch.sourceState
            ).status,
            .exact
        )
    }

    func test_sourceAlignedDevelopmentPhaseRejectsOutOfRangeIndex() {
        XCTAssertThrowsError(try ASHSpatialPhaseV2.sourceAlignedDevelopment(
            horizontalIndex: 2,
            verticalIndex: 0,
            route: .direct2x
        ))
    }

    private func assertExact(
        _ affine: ASHState,
        message: ASHMessage,
        anchor: ASHState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let decoded = ASHCode.decodeAffine(received: affine, anchor: anchor)
        XCTAssertEqual(decoded.status, .exact, file: file, line: line)
        XCTAssertEqual(decoded.messageBits, message.bits, file: file, line: line)
    }

    private func assertHardConstraintsForEveryState(
        phase: ASHSpatialPhaseV2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for raw in UInt16(0)..<UInt16(1 << ASHState.bitCount) {
            let state = try ASHState(rawValue: raw)
            guard state.hasValidIntegrity else { continue }
            let descriptorID = try ASHSpatialDevelopmentSelectorV2.dispatch(
                state: state,
                phase: phase
            ).primaryDecodedMessage.rawValue

            if descriptorID & 0b0010 != 0 {
                XCTAssertEqual(state.bit(coordinate: 3) & state.bit(coordinate: 4), 1, file: file, line: line)
            }
            if descriptorID & 0b0100 != 0 {
                XCTAssertEqual(state.bit(coordinate: 3), 1, file: file, line: line)
                XCTAssertEqual(state.bit(coordinate: 5), 1, file: file, line: line)
                XCTAssertEqual(state.bit(coordinate: 6), 0, file: file, line: line)
            }
            if descriptorID & 0b1000 != 0 {
                XCTAssertEqual(state.bit(coordinate: 6), 0, file: file, line: line)
                XCTAssertEqual(state.bit(coordinate: 8), 1, file: file, line: line)
            }
        }
    }
}
