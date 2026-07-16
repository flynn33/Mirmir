import Foundation

struct ASHGenericPhaseCompilationV3: Equatable, Sendable {
    let route: ASHSpatialRouteV2
    let entries: [ASHLUTCompiledEntryV2]
    let offlinePathEvaluationCount: Int
    let runtimeTreeGenerationCount: Int

    var maximumOperatorEvaluations: Int {
        entries.map(\.operatorEvaluationCount).max() ?? 0
    }
}

/// Development diagnostic only. This compiles the generic 81-path result at every
/// phase and does not alter or select the V2 production compilation behavior.
enum ASHGenericPhaseCompilerDiagnosticV3 {
    static let pathEvaluationCountPerCell = 81

    static func compile(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2
    ) throws -> ASHGenericPhaseCompilationV3 {
        let paths = try ASHLUTLeafCompilerV2.canonicalPaths()
        guard paths.count == pathEvaluationCountPerCell,
              ASHLUTStateOrdinalTableV2.validStates.count == 256 else {
            throw ASHLUTCompilerErrorV2.entryCountMismatch
        }
        let expectedEntryCount = route.phasePairCount
            * ASHLUTContextV2.allCases.count
            * ASHLUTStateOrdinalTableV2.validStates.count
        var entries: [ASHLUTCompiledEntryV2] = []
        entries.reserveCapacity(expectedEntryCount)
        var pathEvaluationCount = 0

        for phaseOrdinal in 0..<route.phasePairCount {
            for context in ASHLUTContextV2.allCases {
                for (stateOrdinal, sourceState) in ASHLUTStateOrdinalTableV2.validStates.enumerated() {
                    let logicalIndex = try ASHLUTLeafCompilerV2.logicalIndex(
                        phaseOrdinal: phaseOrdinal,
                        context: context,
                        validStateOrdinal: stateOrdinal,
                        route: route
                    )
                    entries.append(try ASHLUTLeafCompilerV2.compileGenericCell(
                        logicalIndex: logicalIndex,
                        sourceState: sourceState,
                        validStateOrdinal: UInt16(stateOrdinal),
                        phaseOrdinal: UInt16(phaseOrdinal),
                        context: context,
                        route: route,
                        paths: paths,
                        configuration: configuration
                    ))
                    pathEvaluationCount += paths.count
                }
            }
        }
        guard entries.count == expectedEntryCount,
              pathEvaluationCount == expectedEntryCount * pathEvaluationCountPerCell else {
            throw ASHLUTCompilerErrorV2.entryCountMismatch
        }
        return ASHGenericPhaseCompilationV3(
            route: route,
            entries: entries,
            offlinePathEvaluationCount: pathEvaluationCount,
            runtimeTreeGenerationCount: 0
        )
    }
}
