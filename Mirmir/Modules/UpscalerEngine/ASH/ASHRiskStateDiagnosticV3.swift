import CryptoKit
import Foundation

enum ASHRiskStateDiagnosticV3Error: Error, Equatable, Sendable {
    case riskWeightSetMismatch
    case thresholdBandSetMismatch
    case evidenceCountOverflow

    var machineCode: String {
        switch self {
        case .riskWeightSetMismatch: "risk_state_diagnostic_weight_set_mismatch"
        case .thresholdBandSetMismatch: "risk_state_diagnostic_band_set_mismatch"
        case .evidenceCountOverflow: "risk_state_diagnostic_evidence_count_overflow"
        }
    }
}

struct ASHRiskWeightPairV3: Equatable, Sendable {
    let laplacianUNorm15: UInt16
    let alternatingDifferenceUNorm15: UInt16
}

struct ASHRiskThresholdBandV3: Equatable, Sendable {
    let lowUNorm15: UInt16
    let highUNorm15: UInt16
}

struct ASHRiskStateDiagnosticRequestV3: Sendable {
    let luma: ASHVideoAnalyzerV2CodePlane
    let cb: ASHVideoAnalyzerV2CodePlane
    let cr: ASHVideoAnalyzerV2CodePlane
    let chromaSiting: ASHChromaSitingV2
    let step: Int
    let boundary: ASHSpatialBoundaryModeV2
    let baseConfiguration: ASHVideoAnalyzerV2DevelopmentConfiguration
    let riskWeights: [ASHRiskWeightPairV3]
    let riskThresholdBands: [ASHRiskThresholdBandV3]
}

struct ASHRiskStateDiagnosticCellV3: Equatable, Sendable {
    let ordinal: Int
    let riskWeights: ASHRiskWeightPairV3
    let riskThresholdBand: ASHRiskThresholdBandV3
    let riskZeroCount: Int
    let riskOneCount: Int
    let riskProxyMinimum: Double
    let riskProxyMaximum: Double
    let sortedRiskProxyUNorm15: [UInt16]
    let riskProxyVectorSHA256: ASHLUTHashV2
    let grid: ASHAnalysisGridV2
}

struct ASHRiskStateDiagnosticResultV3: Equatable, Sendable {
    let baselineGrid: ASHAnalysisGridV2
    let cells: [ASHRiskStateDiagnosticCellV3]
}

/// Development diagnostic only. The canonical vector hash covers the ASCII
/// domain below, a UInt32 sample count, and sorted UInt16 values, all integers
/// encoded little-endian. This type does not select or persist a configuration.
enum ASHRiskStateDiagnosticV3 {
    static let canonicalVectorDomain = Array("ASH-RISK-PROXY-UNORM15-V3\0".utf8)
    static let exactRiskWeights = [
        ASHRiskWeightPairV3(
            laplacianUNorm15: 8_192,
            alternatingDifferenceUNorm15: 24_575
        ),
        ASHRiskWeightPairV3(
            laplacianUNorm15: 16_384,
            alternatingDifferenceUNorm15: 16_383
        ),
        ASHRiskWeightPairV3(
            laplacianUNorm15: 24_575,
            alternatingDifferenceUNorm15: 8_192
        )
    ]
    static let exactRiskThresholdBands = [
        ASHRiskThresholdBandV3(lowUNorm15: 0, highUNorm15: 256),
        ASHRiskThresholdBandV3(lowUNorm15: 0, highUNorm15: 512),
        ASHRiskThresholdBandV3(lowUNorm15: 0, highUNorm15: 1_024),
        ASHRiskThresholdBandV3(lowUNorm15: 0, highUNorm15: 1_638),
        ASHRiskThresholdBandV3(lowUNorm15: 0, highUNorm15: 3_277),
        ASHRiskThresholdBandV3(lowUNorm15: 819, highUNorm15: 4_096),
        ASHRiskThresholdBandV3(lowUNorm15: 1_638, highUNorm15: 4_915),
        ASHRiskThresholdBandV3(lowUNorm15: 2_458, highUNorm15: 5_735),
        ASHRiskThresholdBandV3(lowUNorm15: 3_277, highUNorm15: 6_554),
        ASHRiskThresholdBandV3(lowUNorm15: 4_915, highUNorm15: 8_192)
    ]

    static func process(
        _ request: ASHRiskStateDiagnosticRequestV3
    ) throws -> ASHRiskStateDiagnosticResultV3 {
        guard request.riskWeights == exactRiskWeights else {
            throw ASHRiskStateDiagnosticV3Error.riskWeightSetMismatch
        }
        guard request.riskThresholdBands == exactRiskThresholdBands else {
            throw ASHRiskStateDiagnosticV3Error.thresholdBandSetMismatch
        }
        let baseline = try ASHAnalysisGridBuilderV2.build(
            luma: request.luma,
            cb: request.cb,
            cr: request.cr,
            chromaSiting: request.chromaSiting,
            step: request.step,
            boundary: request.boundary,
            configuration: request.baseConfiguration
        )
        var cells: [ASHRiskStateDiagnosticCellV3] = []
        cells.reserveCapacity(exactRiskWeights.count * exactRiskThresholdBands.count)
        for weights in request.riskWeights {
            for band in request.riskThresholdBands {
                let configuration = try configuration(
                    base: request.baseConfiguration,
                    weights: weights,
                    band: band
                )
                let grid = try repack(
                    request: request,
                    layout: baseline,
                    configuration: configuration
                )
                cells.append(try evidence(
                    ordinal: cells.count,
                    weights: weights,
                    band: band,
                    grid: grid
                ))
            }
        }
        return ASHRiskStateDiagnosticResultV3(
            baselineGrid: baseline,
            cells: cells
        )
    }

    private static func configuration(
        base: ASHVideoAnalyzerV2DevelopmentConfiguration,
        weights: ASHRiskWeightPairV3,
        band: ASHRiskThresholdBandV3
    ) throws -> ASHVideoAnalyzerV2DevelopmentConfiguration {
        let riskBand = try ASHVideoAnalyzerV2ThresholdBand(
            low: Double(band.lowUNorm15) / 32_767.0,
            high: Double(band.highUNorm15) / 32_767.0
        )
        return try ASHVideoAnalyzerV2DevelopmentConfiguration(
            bands: ASHVideoAnalyzerV2DevelopmentBands(
                edgePresent: base.bands.edgePresent,
                coherentStructure: base.bands.coherentStructure,
                textureHighFrequency: base.bands.textureHighFrequency,
                aliasOrRingingRisk: riskBand,
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

    private static func repack(
        request: ASHRiskStateDiagnosticRequestV3,
        layout: ASHAnalysisGridV2,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHAnalysisGridV2 {
        let boundary = analyzerBoundary(request.boundary)
        var cells: [ASHAnalysisGridCellV2] = []
        cells.reserveCapacity(layout.count)
        for (offset, layoutCell) in layout.cells.enumerated() {
            if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
            let luma = try ASHVideoAnalyzerV2.analyzeLuma(
                plane: request.luma,
                location: ASHVideoAnalyzerV2ContinuousLocation(
                    x: layoutCell.centerX,
                    y: layoutCell.centerY
                ),
                boundary: boundary,
                configuration: configuration
            )
            let chroma = try ASHVideoAnalyzerV2ChromaInput(
                cb: request.cb,
                cr: request.cr,
                location: request.chromaSiting.sourceChromaLocation(
                    lumaX: layoutCell.centerX,
                    lumaY: layoutCell.centerY
                )
            )
            let measurements = ASHVideoAnalyzerV2.analyzeChroma(
                luma,
                chroma: chroma,
                boundary: boundary,
                configuration: configuration
            )
            let analysis = try ASHVideoAnalyzerV2.makeResult(
                measurements: measurements,
                inputRange: request.luma.range,
                history: nil,
                temporalEvidence: nil,
                configuration: configuration
            )
            cells.append(ASHAnalysisGridCellV2(
                column: layoutCell.column,
                row: layoutCell.row,
                originX: layoutCell.originX,
                originY: layoutCell.originY,
                actualWidth: layoutCell.actualWidth,
                actualHeight: layoutCell.actualHeight,
                centerX: layoutCell.centerX,
                centerY: layoutCell.centerY,
                analysis: analysis
            ))
        }
        return ASHAnalysisGridV2(
            sourceWidth: layout.sourceWidth,
            sourceHeight: layout.sourceHeight,
            step: layout.step,
            columnCount: layout.columnCount,
            rowCount: layout.rowCount,
            cells: cells
        )
    }

    private static func evidence(
        ordinal: Int,
        weights: ASHRiskWeightPairV3,
        band: ASHRiskThresholdBandV3,
        grid: ASHAnalysisGridV2
    ) throws -> ASHRiskStateDiagnosticCellV3 {
        let proxies = grid.cells.map(\.analysis.measurements.riskProxy)
        let sorted = proxies.map(quantizeUNorm15).sorted()
        let oneCount = grid.cells.reduce(into: 0) { count, cell in
            count += cell.analysis.state.bit(coordinate: 6)
        }
        return ASHRiskStateDiagnosticCellV3(
            ordinal: ordinal,
            riskWeights: weights,
            riskThresholdBand: band,
            riskZeroCount: grid.count - oneCount,
            riskOneCount: oneCount,
            riskProxyMinimum: proxies.min() ?? 0.0,
            riskProxyMaximum: proxies.max() ?? 0.0,
            sortedRiskProxyUNorm15: sorted,
            riskProxyVectorSHA256: try vectorSHA256(sorted),
            grid: grid
        )
    }

    private static func vectorSHA256(
        _ sortedValues: [UInt16]
    ) throws -> ASHLUTHashV2 {
        guard let count = UInt32(exactly: sortedValues.count) else {
            throw ASHRiskStateDiagnosticV3Error.evidenceCountOverflow
        }
        var bytes = Data(canonicalVectorDomain)
        ASHLUTLittleEndianV2.append(count, to: &bytes)
        for value in sortedValues {
            ASHLUTLittleEndianV2.append(value, to: &bytes)
        }
        return ASHLUTHashV2(validatedBytes: Array(SHA256.hash(data: bytes)))
    }

    private static func quantizeUNorm15(_ value: Double) -> UInt16 {
        let unit = min(1.0, max(0.0, value))
        return UInt16((unit * 32_767.0).rounded(.toNearestOrEven))
    }

    private static func analyzerBoundary(
        _ boundary: ASHSpatialBoundaryModeV2
    ) -> ASHVideoAnalyzerV2BoundaryRule {
        switch boundary {
        case .clamp: .clamp
        case .mirrorReflect101: .reflect101
        }
    }
}
