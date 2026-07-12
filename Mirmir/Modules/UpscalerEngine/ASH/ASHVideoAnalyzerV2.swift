import Foundation

// The reference analyzer intentionally keeps its complete numerical contract in
// one source file so the CPU formulas can be audited without cross-file state.
// swiftlint:disable file_length type_body_length identifier_name type_name

enum ASHVideoAnalyzerV2Error: Error, Equatable, Sendable {
    case invalidPlaneGeometry
    case insufficientPlaneStorage
    case invalidAnalysisLocation
    case mismatchedChromaPlanes
    case invalidThresholdBand
    case invalidEpsilon
    case invalidRiskWeights
    case invalidConfidence
    case invalidMeasurement
}

enum ASHVideoCodeRange8Bit: String, Equatable, Sendable {
    case video
    case full

    /// Maps the declared legal endpoints to 0 and 1. Excursions remain linear
    /// and are not silently clamped, so callers can measure out-of-range input.
    func normalizeLuma(_ code: UInt8) -> Double {
        normalize(code, minimum: self == .video ? 16.0 : 0.0, maximum: self == .video ? 235.0 : 255.0)
    }

    /// Maps the declared legal endpoints to -0.5 and 0.5 without clamping.
    func normalizeChroma(_ code: UInt8) -> Double {
        normalize(code, minimum: self == .video ? 16.0 : 0.0, maximum: self == .video ? 240.0 : 255.0) - 0.5
    }

    private func normalize(_ code: UInt8, minimum: Double, maximum: Double) -> Double {
        (Double(code) - minimum) / (maximum - minimum)
    }
}

enum ASHVideoAnalyzerV2BoundaryRule: Equatable, Sendable {
    case clamp
    case reflect101

    func index(_ proposed: Int, extent: Int) -> Int {
        precondition(extent > 0)
        switch self {
        case .clamp:
            return min(max(proposed, 0), extent - 1)
        case .reflect101:
            guard extent > 1 else { return 0 }
            var reflected = proposed
            while reflected < 0 || reflected >= extent {
                reflected = reflected < 0 ? -reflected : (2 * extent) - reflected - 2
            }
            return reflected
        }
    }
}

struct ASHVideoAnalyzerV2CodePlane: Equatable, Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let codes: [UInt8]
    let range: ASHVideoCodeRange8Bit

    init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        codes: [UInt8],
        range: ASHVideoCodeRange8Bit
    ) throws {
        guard width > 0, height > 0, bytesPerRow >= width else {
            throw ASHVideoAnalyzerV2Error.invalidPlaneGeometry
        }
        guard codes.count >= bytesPerRow * height else {
            throw ASHVideoAnalyzerV2Error.insufficientPlaneStorage
        }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.codes = codes
        self.range = range
    }

    func luma(x: Int, y: Int, boundary: ASHVideoAnalyzerV2BoundaryRule) -> Double {
        range.normalizeLuma(code(x: x, y: y, boundary: boundary))
    }

    func luma(x: Double, y: Double, boundary: ASHVideoAnalyzerV2BoundaryRule) -> Double {
        let lowerX = Int(floor(x))
        let lowerY = Int(floor(y))
        let horizontalFraction = x - Double(lowerX)
        let verticalFraction = y - Double(lowerY)
        let top = linear(
            luma(x: lowerX, y: lowerY, boundary: boundary),
            luma(x: lowerX + 1, y: lowerY, boundary: boundary),
            fraction: horizontalFraction
        )
        let bottom = linear(
            luma(x: lowerX, y: lowerY + 1, boundary: boundary),
            luma(x: lowerX + 1, y: lowerY + 1, boundary: boundary),
            fraction: horizontalFraction
        )
        return linear(top, bottom, fraction: verticalFraction)
    }

    func chroma(x: Int, y: Int, boundary: ASHVideoAnalyzerV2BoundaryRule) -> Double {
        range.normalizeChroma(code(x: x, y: y, boundary: boundary))
    }

    func chroma(x: Double, y: Double, boundary: ASHVideoAnalyzerV2BoundaryRule) -> Double {
        let lowerX = Int(floor(x))
        let lowerY = Int(floor(y))
        let horizontalFraction = x - Double(lowerX)
        let verticalFraction = y - Double(lowerY)
        let top = linear(
            chroma(x: lowerX, y: lowerY, boundary: boundary),
            chroma(x: lowerX + 1, y: lowerY, boundary: boundary),
            fraction: horizontalFraction
        )
        let bottom = linear(
            chroma(x: lowerX, y: lowerY + 1, boundary: boundary),
            chroma(x: lowerX + 1, y: lowerY + 1, boundary: boundary),
            fraction: horizontalFraction
        )
        return linear(top, bottom, fraction: verticalFraction)
    }

    private func linear(_ first: Double, _ second: Double, fraction: Double) -> Double {
        first + ((second - first) * fraction)
    }

    private func code(x: Int, y: Int, boundary: ASHVideoAnalyzerV2BoundaryRule) -> UInt8 {
        let boundedX = boundary.index(x, extent: width)
        let boundedY = boundary.index(y, extent: height)
        return codes[(boundedY * bytesPerRow) + boundedX]
    }
}

struct ASHVideoAnalyzerV2Location: Equatable, Sendable {
    let x: Int
    let y: Int
}

struct ASHVideoAnalyzerV2ContinuousLocation: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct ASHVideoAnalyzerV2ChromaInput: Equatable, Sendable {
    let cb: ASHVideoAnalyzerV2CodePlane
    let cr: ASHVideoAnalyzerV2CodePlane
    let location: ASHChromaContinuousLocationV2

    init(
        cb: ASHVideoAnalyzerV2CodePlane,
        cr: ASHVideoAnalyzerV2CodePlane,
        location: ASHChromaContinuousLocationV2
    ) throws {
        guard cb.width == cr.width,
              cb.height == cr.height,
              cb.range == cr.range else {
            throw ASHVideoAnalyzerV2Error.mismatchedChromaPlanes
        }
        guard location.horizontal.isFinite,
              location.vertical.isFinite,
              (-0.5...Double(cb.width) - 0.5).contains(location.horizontal),
              (-0.5...Double(cb.height) - 0.5).contains(location.vertical) else {
            throw ASHVideoAnalyzerV2Error.invalidAnalysisLocation
        }
        self.cb = cb
        self.cr = cr
        self.location = location
    }

    init(
        cb: ASHVideoAnalyzerV2CodePlane,
        cr: ASHVideoAnalyzerV2CodePlane,
        location: ASHVideoAnalyzerV2Location
    ) throws {
        try self.init(
            cb: cb,
            cr: cr,
            location: ASHChromaContinuousLocationV2(
                horizontal: Double(location.x),
                vertical: Double(location.y)
            )
        )
    }
}

struct ASHVideoAnalyzerV2ThresholdBand: Equatable, Sendable {
    let low: Double
    let high: Double

    init(low: Double, high: Double) throws {
        guard low.isFinite,
              high.isFinite,
              low >= 0.0,
              high <= 1.0,
              low <= high else {
            throw ASHVideoAnalyzerV2Error.invalidThresholdBand
        }
        self.low = low
        self.high = high
    }
}

struct ASHVideoAnalyzerV2DevelopmentBands: Equatable, Sendable {
    let edgePresent: ASHVideoAnalyzerV2ThresholdBand
    let coherentStructure: ASHVideoAnalyzerV2ThresholdBand
    let textureHighFrequency: ASHVideoAnalyzerV2ThresholdBand
    let aliasOrRingingRisk: ASHVideoAnalyzerV2ThresholdBand
    let temporalSupportValid: ASHVideoAnalyzerV2ThresholdBand
    let chromaLumaStructureAligned: ASHVideoAnalyzerV2ThresholdBand
}

struct ASHVideoAnalyzerV2RiskWeights: Equatable, Sendable {
    let laplacian: Double
    let alternatingDifference: Double

    init(laplacian: Double, alternatingDifference: Double) throws {
        guard laplacian.isFinite,
              alternatingDifference.isFinite,
              laplacian >= 0.0,
              alternatingDifference >= 0.0,
              laplacian + alternatingDifference > 0.0 else {
            throw ASHVideoAnalyzerV2Error.invalidRiskWeights
        }
        self.laplacian = laplacian
        self.alternatingDifference = alternatingDifference
    }
}

struct ASHVideoAnalyzerV2DevelopmentConfiguration: Equatable, Sendable {
    let bands: ASHVideoAnalyzerV2DevelopmentBands
    let epsilon: Double
    let riskWeights: ASHVideoAnalyzerV2RiskWeights
    let chromaEdgeConfidenceThreshold: Double

    init(
        bands: ASHVideoAnalyzerV2DevelopmentBands,
        epsilon: Double,
        riskWeights: ASHVideoAnalyzerV2RiskWeights,
        chromaEdgeConfidenceThreshold: Double
    ) throws {
        guard epsilon.isFinite, epsilon > 0.0 else {
            throw ASHVideoAnalyzerV2Error.invalidEpsilon
        }
        guard chromaEdgeConfidenceThreshold.isFinite,
              (0.0...1.0).contains(chromaEdgeConfidenceThreshold) else {
            throw ASHVideoAnalyzerV2Error.invalidConfidence
        }
        self.bands = bands
        self.epsilon = epsilon
        self.riskWeights = riskWeights
        self.chromaEdgeConfidenceThreshold = chromaEdgeConfidenceThreshold
    }

    /// Disposable P05 CPU-reference values. They are deliberately identified as
    /// development inputs and are not a calibrated or release-locked mapping.
    static func makeDisposableP05Reference() throws -> ASHVideoAnalyzerV2DevelopmentConfiguration {
        let band = try ASHVideoAnalyzerV2ThresholdBand(low: 0.20, high: 0.40)
        return try ASHVideoAnalyzerV2DevelopmentConfiguration(
            bands: ASHVideoAnalyzerV2DevelopmentBands(
                edgePresent: band,
                coherentStructure: band,
                textureHighFrequency: band,
                aliasOrRingingRisk: band,
                temporalSupportValid: band,
                chromaLumaStructureAligned: band
            ),
            epsilon: 1.0e-9,
            riskWeights: ASHVideoAnalyzerV2RiskWeights(
                laplacian: 0.5,
                alternatingDifference: 0.5
            ),
            chromaEdgeConfidenceThreshold: 0.10
        )
    }
}

struct ASHVideoAnalyzerV2History: Equatable, Sendable {
    let state: ASHState
    let correspondenceIsValid: Bool
}

struct ASHVideoAnalyzerV2ValidationTemporalEvidence: Equatable, Sendable {
    let motionResidualPassed: Bool
    let forwardBackwardConsistencyPassed: Bool
    let occlusionPassed: Bool
    let sceneCutPassed: Bool
    let confidence: Double
    let motionVectorQ8_8: ASHVideoAnalyzerV2MotionVectorQ8_8

    init(
        motionResidualPassed: Bool,
        forwardBackwardConsistencyPassed: Bool,
        occlusionPassed: Bool,
        sceneCutPassed: Bool,
        confidence: Double,
        motionVectorQ8_8: ASHVideoAnalyzerV2MotionVectorQ8_8
    ) throws {
        guard confidence.isFinite, (0.0...1.0).contains(confidence) else {
            throw ASHVideoAnalyzerV2Error.invalidConfidence
        }
        self.motionResidualPassed = motionResidualPassed
        self.forwardBackwardConsistencyPassed = forwardBackwardConsistencyPassed
        self.occlusionPassed = occlusionPassed
        self.sceneCutPassed = sceneCutPassed
        self.confidence = confidence
        self.motionVectorQ8_8 = motionVectorQ8_8
    }

    var allPredicatesPassed: Bool {
        motionResidualPassed
            && forwardBackwardConsistencyPassed
            && occlusionPassed
            && sceneCutPassed
    }
}

struct ASHVideoAnalyzerV2MotionVectorQ8_8: Equatable, Sendable {
    static let zero = ASHVideoAnalyzerV2MotionVectorQ8_8(x: 0, y: 0)

    let x: Int16
    let y: Int16
}

struct ASHVideoAnalyzerV2Input: Equatable, Sendable {
    let luma: ASHVideoAnalyzerV2CodePlane
    let location: ASHVideoAnalyzerV2Location
    let chroma: ASHVideoAnalyzerV2ChromaInput?
    let boundary: ASHVideoAnalyzerV2BoundaryRule
    let history: ASHVideoAnalyzerV2History?
    let validationTemporalEvidence: ASHVideoAnalyzerV2ValidationTemporalEvidence?
}

struct ASHVideoAnalyzerV2Measurements: Equatable, Sendable {
    let tensorXX: Double
    let tensorYY: Double
    let tensorXY: Double
    let normalizedGradientMagnitude: Double
    let structureCoherence: Double
    let edgeNormalRadians: Double
    let edgeTangentRadians: Double
    let orientationSector: Int
    let textureEnergy: Double
    let riskProxy: Double
    let localNoiseEstimate: Double
    let chromaAlignment: Double
    let chromaEdgeConfidence: Double
    let localMinimumY: Double
    let localMaximumY: Double
}

struct ASHVideoAnalyzerV2Sidecar: Equatable, Sendable {
    let inputRange: ASHVideoCodeRange8Bit
    let normalizedGradientMagnitude: Double
    let structureCoherence: Double
    let edgeNormalRadians: Double
    let edgeTangentRadians: Double
    let orientationSector: Int
    let textureEnergy: Double
    let riskProxy: Double
    let localNoiseEstimate: Double
    let temporalConfidence: Double
    let motionVectorQ8_8: ASHVideoAnalyzerV2MotionVectorQ8_8
    let chromaAlignment: Double
    let chromaEdgeConfidence: Double
    let localMinimumY: Double
    let localMaximumY: Double
}

enum ASHVideoAnalyzerV2HysteresisDecision: String, CaseIterable, Equatable, Sendable {
    case midpointSet = "midpoint_set"
    case midpointClear = "midpoint_clear"
    case heldSet = "held_set"
    case heldClear = "held_clear"
    case roseAboveHigh = "rose_above_high"
    case fellBelowLow = "fell_below_low"
    case forcedOffWithoutTemporalEvidence = "forced_off_without_temporal_evidence"
}

struct ASHVideoAnalyzerV2HysteresisDiagnostics: Equatable, Sendable {
    let edgePresent: ASHVideoAnalyzerV2HysteresisDecision
    let coherentStructure: ASHVideoAnalyzerV2HysteresisDecision
    let textureHighFrequency: ASHVideoAnalyzerV2HysteresisDecision
    let aliasOrRingingRisk: ASHVideoAnalyzerV2HysteresisDecision
    let temporalSupportValid: ASHVideoAnalyzerV2HysteresisDecision
    let chromaLumaStructureAligned: ASHVideoAnalyzerV2HysteresisDecision
}

struct ASHVideoAnalyzerV2Result: Equatable, Sendable {
    let state: ASHState
    let measurements: ASHVideoAnalyzerV2Measurements
    let sidecar: ASHVideoAnalyzerV2Sidecar
    let hysteresis: ASHVideoAnalyzerV2HysteresisDiagnostics
}

enum ASHVideoAnalyzerV2 {
    private static let scharrX = [
        [-3.0, 0.0, 3.0],
        [-10.0, 0.0, 10.0],
        [-3.0, 0.0, 3.0]
    ]
    private static let scharrY = [
        [-3.0, -10.0, -3.0],
        [0.0, 0.0, 0.0],
        [3.0, 10.0, 3.0]
    ]
    private static let binomial = [1.0, 4.0, 6.0, 4.0, 1.0]
    private static let binomialNormalization = 256.0

    static func analyze(
        _ input: ASHVideoAnalyzerV2Input,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHVideoAnalyzerV2Result {
        let luma = try analyzeLuma(input, configuration: configuration)
        let combined = analyzeChroma(
            luma,
            chroma: input.chroma,
            boundary: input.boundary,
            configuration: configuration
        )
        return try makeResult(
            measurements: combined,
            inputRange: input.luma.range,
            history: input.history,
            temporalEvidence: input.validationTemporalEvidence,
            configuration: configuration
        )
    }

    static func analyzeLuma(
        _ input: ASHVideoAnalyzerV2Input,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHVideoAnalyzerV2Measurements {
        guard (0..<input.luma.width).contains(input.location.x),
              (0..<input.luma.height).contains(input.location.y) else {
            throw ASHVideoAnalyzerV2Error.invalidAnalysisLocation
        }
        return lumaMeasurements(
            plane: input.luma,
            x: Double(input.location.x),
            y: Double(input.location.y),
            boundary: input.boundary,
            configuration: configuration
        )
    }

    static func analyzeLuma(
        plane: ASHVideoAnalyzerV2CodePlane,
        location: ASHVideoAnalyzerV2ContinuousLocation,
        boundary: ASHVideoAnalyzerV2BoundaryRule,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHVideoAnalyzerV2Measurements {
        guard location.x.isFinite,
              location.y.isFinite,
              (0.0...Double(plane.width - 1)).contains(location.x),
              (0.0...Double(plane.height - 1)).contains(location.y) else {
            throw ASHVideoAnalyzerV2Error.invalidAnalysisLocation
        }
        return lumaMeasurements(
            plane: plane,
            x: location.x,
            y: location.y,
            boundary: boundary,
            configuration: configuration
        )
    }

    static func analyzeChroma(
        _ luma: ASHVideoAnalyzerV2Measurements,
        chroma: ASHVideoAnalyzerV2ChromaInput?,
        boundary: ASHVideoAnalyzerV2BoundaryRule,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) -> ASHVideoAnalyzerV2Measurements {
        let chroma = chromaMeasurements(
            chroma,
            lumaConfidence: luma.normalizedGradientMagnitude,
            lumaTangent: luma.edgeTangentRadians,
            boundary: boundary,
            configuration: configuration
        )
        return ASHVideoAnalyzerV2Measurements(
            tensorXX: luma.tensorXX,
            tensorYY: luma.tensorYY,
            tensorXY: luma.tensorXY,
            normalizedGradientMagnitude: luma.normalizedGradientMagnitude,
            structureCoherence: luma.structureCoherence,
            edgeNormalRadians: luma.edgeNormalRadians,
            edgeTangentRadians: luma.edgeTangentRadians,
            orientationSector: luma.orientationSector,
            textureEnergy: luma.textureEnergy,
            riskProxy: luma.riskProxy,
            localNoiseEstimate: luma.localNoiseEstimate,
            chromaAlignment: chroma.alignment,
            chromaEdgeConfidence: chroma.confidence,
            localMinimumY: luma.localMinimumY,
            localMaximumY: luma.localMaximumY
        )
    }

    static func makeResult(
        measurements: ASHVideoAnalyzerV2Measurements,
        inputRange: ASHVideoCodeRange8Bit,
        history: ASHVideoAnalyzerV2History?,
        temporalEvidence: ASHVideoAnalyzerV2ValidationTemporalEvidence?,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHVideoAnalyzerV2Result {
        let packed = try packedState(
            measurements: measurements,
            history: history,
            temporalEvidence: temporalEvidence,
            configuration: configuration
        )
        let edgePresent = packed.state.bit(coordinate: 3) == 1
        let temporalConfidence = temporalEvidence.flatMap {
            $0.allPredicatesPassed ? $0.confidence : nil
        } ?? 0.0
        let motionVector = temporalEvidence.flatMap {
            $0.allPredicatesPassed ? $0.motionVectorQ8_8 : nil
        } ?? .zero
        return ASHVideoAnalyzerV2Result(
            state: packed.state,
            measurements: measurements,
            sidecar: ASHVideoAnalyzerV2Sidecar(
                inputRange: inputRange,
                normalizedGradientMagnitude: measurements.normalizedGradientMagnitude,
                structureCoherence: measurements.structureCoherence,
                edgeNormalRadians: measurements.edgeNormalRadians,
                edgeTangentRadians: measurements.edgeTangentRadians,
                orientationSector: edgePresent ? measurements.orientationSector : 0,
                textureEnergy: measurements.textureEnergy,
                riskProxy: measurements.riskProxy,
                localNoiseEstimate: measurements.localNoiseEstimate,
                temporalConfidence: temporalConfidence,
                motionVectorQ8_8: motionVector,
                chromaAlignment: measurements.chromaAlignment,
                chromaEdgeConfidence: measurements.chromaEdgeConfidence,
                localMinimumY: measurements.localMinimumY,
                localMaximumY: measurements.localMaximumY
            ),
            hysteresis: packed.diagnostics
        )
    }

    static func packState(
        measurements: ASHVideoAnalyzerV2Measurements,
        history: ASHVideoAnalyzerV2History?,
        temporalEvidence: ASHVideoAnalyzerV2ValidationTemporalEvidence?,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> ASHState {
        try packedState(
            measurements: measurements,
            history: history,
            temporalEvidence: temporalEvidence,
            configuration: configuration
        ).state
    }

    private struct PackedState {
        let state: ASHState
        let diagnostics: ASHVideoAnalyzerV2HysteresisDiagnostics
    }

    private static func packedState(
        measurements: ASHVideoAnalyzerV2Measurements,
        history: ASHVideoAnalyzerV2History?,
        temporalEvidence: ASHVideoAnalyzerV2ValidationTemporalEvidence?,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) throws -> PackedState {
        try validate(measurements)
        let previous = validPreviousPayload(history)
        let edge = hystereticBit(
            measurements.normalizedGradientMagnitude,
            band: configuration.bands.edgePresent,
            previous: previous?[2]
        )
        let orientation = edge.bit == 1 ? measurements.orientationSector : 0
        let temporal: (bit: Int, decision: ASHVideoAnalyzerV2HysteresisDecision)
        if let evidence = temporalEvidence, evidence.allPredicatesPassed {
            temporal = hystereticBit(
                    evidence.confidence,
                    band: configuration.bands.temporalSupportValid,
                    previous: previous?[6]
                )
        } else {
            temporal = (0, .forcedOffWithoutTemporalEvidence)
        }
        let coherence = hystereticBit(
            measurements.structureCoherence,
            band: configuration.bands.coherentStructure,
            previous: previous?[3]
        )
        let texture = hystereticBit(
            measurements.textureEnergy,
            band: configuration.bands.textureHighFrequency,
            previous: previous?[4]
        )
        let risk = hystereticBit(
            measurements.riskProxy,
            band: configuration.bands.aliasOrRingingRisk,
            previous: previous?[5]
        )
        let chroma = hystereticBit(
            measurements.chromaAlignment,
            band: configuration.bands.chromaLumaStructureAligned,
            previous: previous?[7]
        )
        let payload = [
            orientation & 1,
            (orientation >> 1) & 1,
            edge.bit,
            coherence.bit,
            texture.bit,
            risk.bit,
            temporal.bit,
            chroma.bit
        ]
        return try PackedState(
            state: ASHState(payloadBits: payload),
            diagnostics: ASHVideoAnalyzerV2HysteresisDiagnostics(
                edgePresent: edge.decision,
                coherentStructure: coherence.decision,
                textureHighFrequency: texture.decision,
                aliasOrRingingRisk: risk.decision,
                temporalSupportValid: temporal.decision,
                chromaLumaStructureAligned: chroma.decision
            )
        )
    }

    private static func lumaMeasurements(
        plane: ASHVideoAnalyzerV2CodePlane,
        x: Double,
        y: Double,
        boundary: ASHVideoAnalyzerV2BoundaryRule,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) -> ASHVideoAnalyzerV2Measurements {
        let sample: (Double, Double) -> Double = { x, y in
            plane.luma(x: x, y: y, boundary: boundary)
        }
        let tensor = structureTensor(x: x, y: y, sample: sample)
        let orientation = orientations(tensor)
        let statistics = localStatistics(x: x, y: y, sample: sample)
        let magnitude = sqrt(max(0.0, tensor.xx + tensor.yy))
        let normalizedMagnitude = unit(magnitude / (sqrt(statistics.variance) + configuration.epsilon))
        let coherence = unit(
            sqrt(pow(tensor.xx - tensor.yy, 2.0) + (4.0 * pow(tensor.xy, 2.0)))
                / (tensor.xx + tensor.yy + configuration.epsilon)
        )
        let texture = textureMeasurements(
            x: x,
            y: y,
            localVariance: statistics.variance,
            epsilon: configuration.epsilon,
            sample: sample
        )
        let risk = riskProxy(
            x: x,
            y: y,
            normalRadians: orientation.normal,
            weights: configuration.riskWeights,
            sample: sample
        )
        return ASHVideoAnalyzerV2Measurements(
            tensorXX: tensor.xx,
            tensorYY: tensor.yy,
            tensorXY: tensor.xy,
            normalizedGradientMagnitude: normalizedMagnitude,
            structureCoherence: coherence,
            edgeNormalRadians: orientation.normal,
            edgeTangentRadians: orientation.tangent,
            orientationSector: quantizeTangentSector(orientation.tangent),
            textureEnergy: texture.normalizedEnergy,
            riskProxy: risk,
            localNoiseEstimate: texture.localNoiseEstimate,
            chromaAlignment: 1.0,
            chromaEdgeConfidence: 0.0,
            localMinimumY: statistics.minimum,
            localMaximumY: statistics.maximum
        )
    }

    private static func chromaMeasurements(
        _ chroma: ASHVideoAnalyzerV2ChromaInput?,
        lumaConfidence: Double,
        lumaTangent: Double,
        boundary: ASHVideoAnalyzerV2BoundaryRule,
        configuration: ASHVideoAnalyzerV2DevelopmentConfiguration
    ) -> (alignment: Double, confidence: Double) {
        guard let chroma else { return (1.0, 0.0) }
        let cbSample: (Double, Double) -> Double = { x, y in
            chroma.cb.chroma(
                x: chroma.location.horizontal + x,
                y: chroma.location.vertical + y,
                boundary: boundary
            )
        }
        let crSample: (Double, Double) -> Double = { x, y in
            chroma.cr.chroma(
                x: chroma.location.horizontal + x,
                y: chroma.location.vertical + y,
                boundary: boundary
            )
        }
        let tensor = combinedStructureTensor(
            x: 0,
            y: 0,
            first: cbSample,
            second: crSample
        )
        let cbStatistics = localStatistics(x: 0, y: 0, sample: cbSample)
        let crStatistics = localStatistics(x: 0, y: 0, sample: crSample)
        let magnitude = sqrt(max(0.0, tensor.xx + tensor.yy))
        let confidence = unit(
            magnitude / (sqrt(cbStatistics.variance + crStatistics.variance) + configuration.epsilon)
        )
        guard confidence >= configuration.chromaEdgeConfidenceThreshold else {
            return (1.0, confidence)
        }
        let chromaTangent = orientations(tensor).tangent
        let directionalAgreement = max(0.0, cos(2.0 * (lumaTangent - chromaTangent)))
        return (unit(directionalAgreement * min(lumaConfidence, confidence)), confidence)
    }

    private static func validate(_ measurements: ASHVideoAnalyzerV2Measurements) throws {
        let unitValues = [
            measurements.normalizedGradientMagnitude,
            measurements.structureCoherence,
            measurements.textureEnergy,
            measurements.riskProxy,
            measurements.localNoiseEstimate,
            measurements.chromaAlignment,
            measurements.chromaEdgeConfidence
        ]
        guard unitValues.allSatisfy({ $0.isFinite && (0.0...1.0).contains($0) }),
              measurements.tensorXX.isFinite,
              measurements.tensorYY.isFinite,
              measurements.tensorXY.isFinite,
              measurements.edgeNormalRadians.isFinite,
              measurements.edgeTangentRadians.isFinite,
              (0...3).contains(measurements.orientationSector),
              measurements.localMinimumY.isFinite,
              measurements.localMaximumY.isFinite,
              measurements.localMinimumY <= measurements.localMaximumY else {
            throw ASHVideoAnalyzerV2Error.invalidMeasurement
        }
    }

    private static func validPreviousPayload(_ history: ASHVideoAnalyzerV2History?) -> [Int]? {
        guard let history,
              history.correspondenceIsValid,
              history.state.hasValidIntegrity else {
            return nil
        }
        return Array(history.state.bits.prefix(ASHState.payloadBitCount))
    }

    private static func hystereticBit(
        _ measurement: Double,
        band: ASHVideoAnalyzerV2ThresholdBand,
        previous: Int?
    ) -> (bit: Int, decision: ASHVideoAnalyzerV2HysteresisDecision) {
        switch previous {
        case 0:
            return measurement > band.high ? (1, .roseAboveHigh) : (0, .heldClear)
        case 1:
            return measurement < band.low ? (0, .fellBelowLow) : (1, .heldSet)
        default:
            return measurement >= (band.low + band.high) / 2.0
                ? (1, .midpointSet)
                : (0, .midpointClear)
        }
    }

    private struct Gradient {
        let x: Double
        let y: Double
    }

    private struct Tensor {
        let xx: Double
        let yy: Double
        let xy: Double
    }

    private struct Statistics {
        let variance: Double
        let minimum: Double
        let maximum: Double
    }

    private static func scharrGradient(
        x: Double,
        y: Double,
        sample: (Double, Double) -> Double
    ) -> Gradient {
        var gradientX = 0.0
        var gradientY = 0.0
        for row in 0..<3 {
            for column in 0..<3 {
                let value = sample(x + Double(column - 1), y + Double(row - 1))
                gradientX += scharrX[row][column] * value
                gradientY += scharrY[row][column] * value
            }
        }
        return Gradient(x: gradientX / 32.0, y: gradientY / 32.0)
    }

    private static func structureTensor(
        x: Double,
        y: Double,
        sample: (Double, Double) -> Double
    ) -> Tensor {
        var xx = 0.0
        var yy = 0.0
        var xy = 0.0
        for row in 0..<5 {
            for column in 0..<5 {
                let weight = binomial[row] * binomial[column] / binomialNormalization
                let gradient = scharrGradient(
                    x: x + Double(column - 2),
                    y: y + Double(row - 2),
                    sample: sample
                )
                xx += weight * gradient.x * gradient.x
                yy += weight * gradient.y * gradient.y
                xy += weight * gradient.x * gradient.y
            }
        }
        return Tensor(xx: xx, yy: yy, xy: xy)
    }

    private static func combinedStructureTensor(
        x: Double,
        y: Double,
        first: (Double, Double) -> Double,
        second: (Double, Double) -> Double
    ) -> Tensor {
        let firstTensor = structureTensor(x: x, y: y, sample: first)
        let secondTensor = structureTensor(x: x, y: y, sample: second)
        return Tensor(
            xx: firstTensor.xx + secondTensor.xx,
            yy: firstTensor.yy + secondTensor.yy,
            xy: firstTensor.xy + secondTensor.xy
        )
    }

    private static func orientations(_ tensor: Tensor) -> (normal: Double, tangent: Double) {
        let normal = moduloPi(0.5 * atan2(2.0 * tensor.xy, tensor.xx - tensor.yy))
        return (normal, moduloPi(normal + (.pi / 2.0)))
    }

    private static func moduloPi(_ angle: Double) -> Double {
        var reduced = angle.truncatingRemainder(dividingBy: .pi)
        if reduced < 0.0 {
            reduced += .pi
        }
        return reduced
    }

    static func quantizeTangentSector(_ tangentRadians: Double) -> Int {
        let scaled = moduloPi(tangentRadians) / (.pi / 4.0)
        let lower = Int(floor(scaled))
        let fractionQ15 = Int(((scaled - Double(lower)) * 32_768.0).rounded(.toNearestOrEven))
        return (lower + (fractionQ15 > 16_384 ? 1 : 0)) % 4
    }

    private static func localStatistics(
        x: Double,
        y: Double,
        sample: (Double, Double) -> Double
    ) -> Statistics {
        var mean = 0.0
        var meanSquare = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for row in 0..<5 {
            for column in 0..<5 {
                let value = sample(x + Double(column - 2), y + Double(row - 2))
                let weight = binomial[row] * binomial[column] / binomialNormalization
                mean += weight * value
                meanSquare += weight * value * value
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
        }
        return Statistics(
            variance: max(0.0, meanSquare - (mean * mean)),
            minimum: minimum,
            maximum: maximum
        )
    }

    private static func textureMeasurements(
        x: Double,
        y: Double,
        localVariance: Double,
        epsilon: Double,
        sample: (Double, Double) -> Double
    ) -> (normalizedEnergy: Double, localNoiseEstimate: Double) {
        var residualEnergy = 0.0
        for row in 0..<5 {
            for column in 0..<5 {
                let localX = x + Double(column - 2)
                let localY = y + Double(row - 2)
                let residual = sample(localX, localY) - binomialBlur(x: localX, y: localY, sample: sample)
                let weight = binomial[row] * binomial[column] / binomialNormalization
                residualEnergy += weight * residual * residual
            }
        }
        return (
            unit(residualEnergy / (localVariance + epsilon)),
            unit(sqrt(max(0.0, residualEnergy)))
        )
    }

    private static func binomialBlur(
        x: Double,
        y: Double,
        sample: (Double, Double) -> Double
    ) -> Double {
        var total = 0.0
        for row in 0..<5 {
            for column in 0..<5 {
                let weight = binomial[row] * binomial[column] / binomialNormalization
                total += weight * sample(x + Double(column - 2), y + Double(row - 2))
            }
        }
        return total
    }

    private static func riskProxy(
        x: Double,
        y: Double,
        normalRadians: Double,
        weights: ASHVideoAnalyzerV2RiskWeights,
        sample: (Double, Double) -> Double
    ) -> Double {
        let direction = normalDirection(sector: quantizeTangentSector(normalRadians))
        var laplacianEnergy = 0.0
        var alternatingEnergy = 0.0
        for row in 0..<5 {
            for column in 0..<5 {
                let localX = x + Double(column - 2)
                let localY = y + Double(row - 2)
                let center = sample(localX, localY)
                let laplacian = abs(
                    (4.0 * center)
                        - sample(localX - 1.0, localY)
                        - sample(localX + 1.0, localY)
                        - sample(localX, localY - 1.0)
                        - sample(localX, localY + 1.0)
                ) / 4.0
                let before = sample(localX - Double(direction.x), localY - Double(direction.y))
                let after = sample(localX + Double(direction.x), localY + Double(direction.y))
                let alternating = abs(before - (2.0 * center) + after) / 2.0
                let weight = binomial[row] * binomial[column] / binomialNormalization
                laplacianEnergy += weight * laplacian
                alternatingEnergy += weight * alternating
            }
        }
        let weightTotal = weights.laplacian + weights.alternatingDifference
        return unit(
            ((weights.laplacian * laplacianEnergy)
                + (weights.alternatingDifference * alternatingEnergy)) / weightTotal
        )
    }

    private static func normalDirection(sector: Int) -> (x: Int, y: Int) {
        switch sector {
        case 0:
            return (1, 0)
        case 1:
            return (1, 1)
        case 2:
            return (0, 1)
        default:
            return (1, -1)
        }
    }

    private static func unit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}

// swiftlint:enable file_length type_body_length identifier_name type_name
