import XCTest
@testable import Mirmir

final class ASHGenericPhaseCompilerDiagnosticV3Tests: XCTestCase {
    func testEveryPhaseZeroStateContextCellIsGenericAndHasNoPreservationFlag() throws {
        for fixture in try ASHGenericPhaseCompilerTestSupportV3.fixtures() {
            let genericPhaseZero = fixture.generic.entries.filter { $0.phaseOrdinal == 0 }
            let legacyPhaseZero = fixture.legacy.entries.filter { $0.phaseOrdinal == 0 }
            XCTAssertEqual(genericPhaseZero.count, 4 * 256)
            XCTAssertEqual(legacyPhaseZero.count, 4 * 256)
            var forcedTupleDifferenceCount = 0

            for (offset, generic) in genericPhaseZero.enumerated() {
                let legacy = legacyPhaseZero[offset]
                let stateOrdinal = offset % 256
                let contextRaw = offset / 256
                XCTAssertEqual(generic.logicalIndex, offset)
                XCTAssertEqual(generic.validStateOrdinal, UInt16(stateOrdinal))
                XCTAssertEqual(generic.sourceState, ASHLUTStateOrdinalTableV2.validStates[stateOrdinal])
                XCTAssertEqual(generic.context.rawValue, UInt8(contextRaw))
                XCTAssertFalse(generic.sourceAlignedExact)
                assertNoSourceAlignedPreservationFlag(generic)
                assertLegacySourceAlignedSentinel(legacy)
                if compiledTupleDiffers(generic, legacy) {
                    forcedTupleDifferenceCount += 1
                }
            }

            XCTAssertGreaterThan(
                forcedTupleDifferenceCount,
                0,
                fixture.route.rawValue
            )
        }
    }

    func testGenericAndV2EntriesAreExactlyEqualOutsidePhaseZero() throws {
        for fixture in try ASHGenericPhaseCompilerTestSupportV3.fixtures() {
            var comparisonCount = 0
            for index in fixture.generic.entries.indices {
                guard fixture.generic.entries[index].phaseOrdinal != 0 else { continue }
                XCTAssertEqual(
                    fixture.generic.entries[index],
                    fixture.legacy.entries[index],
                    "\(fixture.route.rawValue) logical index \(index)"
                )
                comparisonCount += 1
            }
            XCTAssertEqual(
                comparisonCount,
                (fixture.route.phasePairCount - 1) * 4 * 256
            )
        }
    }

    func testGenericAndV2PathEvaluationCountsAreExact() throws {
        XCTAssertEqual(
            ASHGenericPhaseCompilerDiagnosticV3.pathEvaluationCountPerCell,
            81
        )
        for fixture in try ASHGenericPhaseCompilerTestSupportV3.fixtures() {
            let expectedEntryCount = fixture.route.phasePairCount * 4 * 256
            let expectedPathEvaluationCount = expectedEntryCount * 81
            XCTAssertEqual(fixture.generic.route, fixture.route)
            XCTAssertEqual(fixture.generic.entries.count, expectedEntryCount)
            XCTAssertEqual(
                fixture.generic.offlinePathEvaluationCount,
                expectedPathEvaluationCount
            )
            XCTAssertEqual(fixture.generic.runtimeTreeGenerationCount, 0)
            XCTAssertLessThanOrEqual(fixture.generic.maximumOperatorEvaluations, 2)
            XCTAssertEqual(fixture.legacy.entries.count, expectedEntryCount)
            XCTAssertEqual(
                fixture.legacy.offlinePathEvaluationCount,
                expectedPathEvaluationCount
            )
            XCTAssertEqual(fixture.legacy.runtimeTreeGenerationCount, 0)
            let phaseZeroEntryCount = fixture.generic.entries.filter {
                $0.phaseOrdinal == 0
            }.count
            XCTAssertEqual(
                phaseZeroEntryCount * ASHGenericPhaseCompilerDiagnosticV3.pathEvaluationCountPerCell,
                82_944
            )
        }
    }

    private func assertNoSourceAlignedPreservationFlag(
        _ entry: ASHLUTCompiledEntryV2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(entry.parameters.primary.isActive, file: file, line: line)
        XCTAssertEqual(
            entry.parameters.primary.flags & ASHLUTParameterSlotV2.sourceAlignedPreservationFlag,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            entry.parameters.secondary.flags & ASHLUTParameterSlotV2.sourceAlignedPreservationFlag,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(entry.secondary != nil, entry.parameters.secondary.isActive, file: file, line: line)
    }

    private func assertLegacySourceAlignedSentinel(
        _ entry: ASHLUTCompiledEntryV2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(entry.sourceAlignedExact, file: file, line: line)
        XCTAssertEqual(entry.primary.message.rawValue, 0, file: file, line: line)
        XCTAssertEqual(entry.primary.affineState, entry.sourceState, file: file, line: line)
        XCTAssertEqual(entry.primary.descriptorID, 0, file: file, line: line)
        XCTAssertEqual(entry.primary.representativePathOrdinal, 0, file: file, line: line)
        XCTAssertEqual(entry.primary.representativePenalty, 0, file: file, line: line)
        XCTAssertEqual(entry.primary.aggregatedWeight, 65_536, file: file, line: line)
        XCTAssertNil(entry.secondary, file: file, line: line)
        XCTAssertEqual(entry.primaryWeightUNorm16, UInt16.max, file: file, line: line)
        XCTAssertEqual(entry.secondaryWeightUNorm16, 0, file: file, line: line)
        XCTAssertEqual(entry.marginUNorm16, UInt16.max, file: file, line: line)
        XCTAssertEqual(
            entry.parameters.primary.flags,
            ASHLUTParameterSlotV2.activeFlag
                | ASHLUTParameterSlotV2.sourceAlignedPreservationFlag,
            file: file,
            line: line
        )
        XCTAssertEqual(entry.parameters.secondary, .inactive, file: file, line: line)
    }

    private func compiledTupleDiffers(
        _ generic: ASHLUTCompiledEntryV2,
        _ legacy: ASHLUTCompiledEntryV2
    ) -> Bool {
        generic.primary != legacy.primary
            || generic.secondary != legacy.secondary
            || generic.primaryWeightUNorm16 != legacy.primaryWeightUNorm16
            || generic.secondaryWeightUNorm16 != legacy.secondaryWeightUNorm16
            || generic.marginUNorm16 != legacy.marginUNorm16
            || generic.parameters != legacy.parameters
    }
}

private struct ASHGenericPhaseCompilerFixtureV3 {
    let route: ASHSpatialRouteV2
    let generic: ASHGenericPhaseCompilationV3
    let legacy: ASHLUTCompilationV2
}

private enum ASHGenericPhaseCompilerTestSupportV3 {
    private static let fixturesResult = Result {
        let configuration = try ASHLUTTestSupportV2.configuration(
            policy: .sourceAlignedRational
        )
        return try ASHSpatialRouteV2.allCases.map { route in
            ASHGenericPhaseCompilerFixtureV3(
                route: route,
                generic: try ASHGenericPhaseCompilerDiagnosticV3.compile(
                    route: route,
                    configuration: configuration
                ),
                legacy: try ASHLUTLeafCompilerV2.compile(
                    route: route,
                    configuration: configuration
                )
            )
        }
    }

    static func fixtures() throws -> [ASHGenericPhaseCompilerFixtureV3] {
        try fixturesResult.get()
    }
}
