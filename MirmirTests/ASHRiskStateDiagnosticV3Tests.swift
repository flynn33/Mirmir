import CryptoKit
import XCTest
@testable import Mirmir

final class ASHRiskStateDiagnosticV3Tests: XCTestCase {
    func testEveryRiskCellMatchesBuilderAndReportsCanonicalActivationEvidence() throws {
        let request = try makeRequest()
        let result = try ASHRiskStateDiagnosticV3.process(request)
        let baseline = try buildGrid(
            request: request,
            configuration: request.baseConfiguration
        )

        XCTAssertEqual(result.baselineGrid, baseline)
        XCTAssertEqual(result.cells.count, 30)
        XCTAssertEqual(
            ASHRiskStateDiagnosticV3.canonicalVectorDomain,
            Array("ASH-RISK-PROXY-UNORM15-V3\0".utf8)
        )
        var observedCells: Set<String> = []
        for (ordinal, cell) in result.cells.enumerated() {
            let weight = request.riskWeights[ordinal / request.riskThresholdBands.count]
            let band = request.riskThresholdBands[ordinal % request.riskThresholdBands.count]
            XCTAssertEqual(cell.ordinal, ordinal)
            XCTAssertEqual(cell.riskWeights, weight)
            XCTAssertEqual(cell.riskThresholdBand, band)
            observedCells.insert("\(weight.laplacianUNorm15)/\(band.lowUNorm15)/\(band.highUNorm15)")

            let configuration = try derivedConfiguration(
                base: request.baseConfiguration,
                weights: weight,
                band: band
            )
            let expected = try buildGrid(request: request, configuration: configuration)
            XCTAssertEqual(cell.grid, expected)
            assertEvidence(cell, expectedGrid: expected)
        }
        XCTAssertEqual(observedCells.count, 30)
        assertBandIndependentRiskVectors(result, request: request)
    }

    func testReorderedAndAlteredDiagnosticDimensionsFailClosed() throws {
        let valid = try makeRequest()
        var reorderedWeights = valid.riskWeights
        reorderedWeights.swapAt(0, 1)
        assertFailure(
            requestCopy(valid, weights: reorderedWeights),
            equals: .riskWeightSetMismatch
        )

        var alteredWeights = valid.riskWeights
        alteredWeights[0] = ASHRiskWeightPairV3(
            laplacianUNorm15: 8_191,
            alternatingDifferenceUNorm15: 24_576
        )
        assertFailure(
            requestCopy(valid, weights: alteredWeights),
            equals: .riskWeightSetMismatch
        )

        var reorderedBands = valid.riskThresholdBands
        reorderedBands.swapAt(0, 1)
        assertFailure(
            requestCopy(valid, bands: reorderedBands),
            equals: .thresholdBandSetMismatch
        )

        var alteredBands = valid.riskThresholdBands
        alteredBands[0] = ASHRiskThresholdBandV3(lowUNorm15: 0, highUNorm15: 257)
        assertFailure(
            requestCopy(valid, bands: alteredBands),
            equals: .thresholdBandSetMismatch
        )
    }

    private func assertEvidence(
        _ cell: ASHRiskStateDiagnosticCellV3,
        expectedGrid: ASHAnalysisGridV2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let proxies = expectedGrid.cells.map(\.analysis.measurements.riskProxy)
        let sorted = proxies.map(quantizeUNorm15).sorted()
        let stateOneCount = expectedGrid.cells.reduce(into: 0) { count, gridCell in
            count += gridCell.analysis.state.bit(coordinate: 6)
        }
        let midpoint = (
            Double(cell.riskThresholdBand.lowUNorm15)
                + Double(cell.riskThresholdBand.highUNorm15)
        ) / (2.0 * 32_767.0)
        let thresholdOneCount = proxies.filter { $0 >= midpoint }.count

        XCTAssertEqual(cell.riskOneCount, stateOneCount, file: file, line: line)
        XCTAssertEqual(cell.riskOneCount, thresholdOneCount, file: file, line: line)
        XCTAssertEqual(
            cell.riskZeroCount,
            expectedGrid.count - stateOneCount,
            file: file,
            line: line
        )
        XCTAssertEqual(cell.riskProxyMinimum, proxies.min() ?? 0.0, file: file, line: line)
        XCTAssertEqual(cell.riskProxyMaximum, proxies.max() ?? 0.0, file: file, line: line)
        XCTAssertEqual(cell.sortedRiskProxyUNorm15, sorted, file: file, line: line)
        XCTAssertEqual(
            cell.riskProxyVectorSHA256,
            vectorSHA256(sorted),
            file: file,
            line: line
        )
    }

    private func assertBandIndependentRiskVectors(
        _ result: ASHRiskStateDiagnosticResultV3,
        request: ASHRiskStateDiagnosticRequestV3
    ) {
        let bandCount = request.riskThresholdBands.count
        for weightIndex in request.riskWeights.indices {
            let start = weightIndex * bandCount
            let group = Array(result.cells[start..<(start + bandCount)])
            XCTAssertEqual(Set(group.map(\.riskProxyVectorSHA256)).count, 1)
            XCTAssertEqual(Set(group.map(\.sortedRiskProxyUNorm15)).count, 1)
            let counts = group.map(\.riskOneCount)
            for (earlier, later) in zip(counts, counts.dropFirst()) {
                XCTAssertGreaterThanOrEqual(earlier, later)
            }
        }
    }

    private func makeRequest() throws -> ASHRiskStateDiagnosticRequestV3 {
        let fixture = try ASHLockedRuntimeTestSupportV2.lockedMappingFixture(
            .direct3Over2
        )
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let mapping = fixture.mapping
        return ASHRiskStateDiagnosticRequestV3(
            luma: planes.luma,
            cb: planes.cb,
            cr: planes.cr,
            chromaSiting: mapping.chromaSiting,
            step: Int(mapping.direct3Over2AnalysisGridSourceStep),
            boundary: mapping.boundaryMode,
            baseConfiguration: mapping.analyzerConfiguration,
            riskWeights: ASHRiskStateDiagnosticV3.exactRiskWeights,
            riskThresholdBands: ASHRiskStateDiagnosticV3.exactRiskThresholdBands
        )
    }

    private func requestCopy(
        _ source: ASHRiskStateDiagnosticRequestV3,
        weights: [ASHRiskWeightPairV3]? = nil,
        bands: [ASHRiskThresholdBandV3]? = nil
    ) -> ASHRiskStateDiagnosticRequestV3 {
        ASHRiskStateDiagnosticRequestV3(
            luma: source.luma,
            cb: source.cb,
            cr: source.cr,
            chromaSiting: source.chromaSiting,
            step: source.step,
            boundary: source.boundary,
            baseConfiguration: source.baseConfiguration,
            riskWeights: weights ?? source.riskWeights,
            riskThresholdBands: bands ?? source.riskThresholdBands
        )
    }

    private func buildGrid(
        request: ASHRiskStateDiagnosticRequestV3,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHAnalysisGridV2 {
        try ASHAnalysisGridBuilderV2.build(
            luma: request.luma,
            cb: request.cb,
            cr: request.cr,
            chromaSiting: request.chromaSiting,
            step: request.step,
            boundary: request.boundary,
            configuration: configuration
        )
    }

    private func derivedConfiguration(
        base: ASHVideoAnalyzerV2DevelopmentConfiguration,
        weights: ASHRiskWeightPairV3,
        band: ASHRiskThresholdBandV3
    ) throws -> ASHVideoAnalyzerV2DevelopmentConfiguration {
        try ASHVideoAnalyzerV2DevelopmentConfiguration(
            bands: ASHVideoAnalyzerV2DevelopmentBands(
                edgePresent: base.bands.edgePresent,
                coherentStructure: base.bands.coherentStructure,
                textureHighFrequency: base.bands.textureHighFrequency,
                aliasOrRingingRisk: ASHVideoAnalyzerV2ThresholdBand(
                    low: Double(band.lowUNorm15) / 32_767.0,
                    high: Double(band.highUNorm15) / 32_767.0
                ),
                temporalSupportValid: base.bands.temporalSupportValid,
                chromaLumaStructureAligned: base.bands.chromaLumaStructureAligned
            ),
            epsilon: base.epsilon,
            riskWeights: ASHVideoAnalyzerV2RiskWeights(
                laplacian: Double(weights.laplacianUNorm15) / 32_767.0,
                alternatingDifference:
                    Double(weights.alternatingDifferenceUNorm15) / 32_767.0
            ),
            chromaEdgeConfidenceThreshold: base.chromaEdgeConfidenceThreshold
        )
    }

    private func assertFailure(
        _ request: ASHRiskStateDiagnosticRequestV3,
        equals expected: ASHRiskStateDiagnosticV3Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ASHRiskStateDiagnosticV3.process(request),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ASHRiskStateDiagnosticV3Error, expected)
        }
    }

    private func quantizeUNorm15(_ value: Double) -> UInt16 {
        UInt16((min(1.0, max(0.0, value)) * 32_767.0).rounded(.toNearestOrEven))
    }

    private func vectorSHA256(_ sortedValues: [UInt16]) -> ASHLUTHashV2 {
        var bytes = Data("ASH-RISK-PROXY-UNORM15-V3\0".utf8)
        ASHLUTLittleEndianV2.append(UInt32(sortedValues.count), to: &bytes)
        for value in sortedValues {
            ASHLUTLittleEndianV2.append(value, to: &bytes)
        }
        return ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: bytes)))
    }
}
