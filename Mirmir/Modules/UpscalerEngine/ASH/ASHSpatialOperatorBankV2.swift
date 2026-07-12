import Foundation

// swiftlint:disable file_length

enum ASHSpatialOperatorErrorV2: Error, Equatable {
    case invalidDescriptorID(UInt8)
    case invalidPlaneDimensions(width: Int, height: Int)
    case invalidSampleCount(expected: Int, actual: Int)
    case invalidSample(index: Int)
    case invalidLegalRange
    case invalidDestinationIndex(index: Int, extent: Int)
    case invalidRouteExtent(sourceExtent: Int, numerator: Int, denominator: Int)
    case coordinateOverflow
    case invalidSidecar
    case invalidDevelopmentParameters
    case nonFiniteWeight
    case zeroWeight
    case nonFiniteResult
}

enum ASHSpatialNumericalFaultV2: String, Equatable, Sendable {
    case nonFiniteWeight = "nonfinite_weight"
    case zeroWeight = "zero_weight"
    case nonFiniteResult = "nonfinite_result"
}

struct ASHSpatialFallbackInstructionV2: Equatable, Sendable {
    let fault: ASHSpatialNumericalFaultV2
    let descriptorID: UInt8
    let limiterMode: ASHSpatialLimiterModeV2
    let preserveExactCoordinate: Bool
}

enum ASHSpatialBaseKernelV2: UInt8, CaseIterable, Sendable {
    case keysCubicAMinusHalf
    case lanczos3

    var supportRadius: Double {
        switch self {
        case .keysCubicAMinusHalf: 2.0
        case .lanczos3: 3.0
        }
    }
}

enum ASHSpatialSupportModeV2: UInt8, CaseIterable, Sendable {
    case isotropic
    case structureTensorAnisotropic
}

enum ASHSpatialDetailModeV2: UInt8, CaseIterable, Sendable {
    case conservative
    case controlledPositive
}

enum ASHSpatialLimiterModeV2: UInt8, CaseIterable, Sendable {
    case strictNeighborhoodRange
    case calibratedRelaxedRange
}

struct ASHSpatialDescriptorV2: Hashable, Sendable {
    static let count = 16

    let id: UInt8
    let baseKernel: ASHSpatialBaseKernelV2
    let supportMode: ASHSpatialSupportModeV2
    let detailMode: ASHSpatialDetailModeV2
    let limiterMode: ASHSpatialLimiterModeV2

    init(id: UInt8) throws {
        guard id < Self.count else { throw ASHSpatialOperatorErrorV2.invalidDescriptorID(id) }
        self.init(validatedID: id)
    }

    private init(validatedID id: UInt8) {
        self.id = id
        baseKernel = (id & 0b0001) == 0 ? .keysCubicAMinusHalf : .lanczos3
        supportMode = (id & 0b0010) == 0 ? .isotropic : .structureTensorAnisotropic
        detailMode = (id & 0b0100) == 0 ? .conservative : .controlledPositive
        limiterMode = (id & 0b1000) == 0 ? .strictNeighborhoodRange : .calibratedRelaxedRange
    }

    static let all: [ASHSpatialDescriptorV2] = (0..<count).map {
        ASHSpatialDescriptorV2(validatedID: UInt8($0))
    }
}

enum ASHSpatialCoordinatePolicyV2: String, CaseIterable, Sendable {
    case halfPixelCenter = "half_pixel_center"
    case sourceAlignedRational = "source_aligned_rational"
}

enum ASHSpatialRouteV2: String, CaseIterable, Sendable {
    case direct2x = "direct_2x"
    case direct3Over2 = "direct_3_over_2"

    var scaleNumerator: Int {
        switch self {
        case .direct2x: 2
        case .direct3Over2: 3
        }
    }

    var scaleDenominator: Int {
        switch self {
        case .direct2x: 1
        case .direct3Over2: 2
        }
    }

    var phasePairCount: Int {
        scaleNumerator * scaleNumerator
    }

    func destinationExtent(for sourceExtent: Int) throws -> Int {
        guard sourceExtent > 0 else {
            throw ASHSpatialOperatorErrorV2.invalidRouteExtent(
                sourceExtent: sourceExtent,
                numerator: scaleNumerator,
                denominator: scaleDenominator
            )
        }
        let product = sourceExtent.multipliedReportingOverflow(by: scaleNumerator)
        guard !product.overflow, product.partialValue.isMultiple(of: scaleDenominator) else {
            throw ASHSpatialOperatorErrorV2.invalidRouteExtent(
                sourceExtent: sourceExtent,
                numerator: scaleNumerator,
                denominator: scaleDenominator
            )
        }
        return product.partialValue / scaleDenominator
    }
}

enum ASHSpatialBoundaryModeV2: String, CaseIterable, Sendable {
    case clamp
    case mirrorReflect101
}

struct ASHSpatialRationalCoordinateV2: Hashable, Sendable {
    let numerator: Int64
    let denominator: Int64

    var value: Double {
        Double(numerator) / Double(denominator)
    }

    var isIntegral: Bool {
        numerator.isMultiple(of: denominator)
    }

    var integralValue: Int? {
        guard isIntegral else { return nil }
        return Int(exactly: numerator / denominator)
    }
}

struct ASHSpatialPhaseComponentV2: Hashable, Sendable {
    let numerator: Int64
    let denominator: Int64

    init(coordinate: ASHSpatialRationalCoordinateV2) {
        let rawRemainder = coordinate.numerator % coordinate.denominator
        let positiveRemainder = rawRemainder >= 0 ? rawRemainder : rawRemainder + coordinate.denominator
        let divisor = Self.greatestCommonDivisor(positiveRemainder, coordinate.denominator)
        numerator = positiveRemainder / divisor
        denominator = coordinate.denominator / divisor
    }

    private static func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var first = lhs
        var second = rhs
        while second != 0 {
            (first, second) = (second, first % second)
        }
        return max(first, 1)
    }
}

struct ASHSpatialPhaseV2: Hashable, Sendable {
    let horizontal: ASHSpatialPhaseComponentV2
    let vertical: ASHSpatialPhaseComponentV2
}

struct ASHSpatialPlaneV2: Sendable {
    let width: Int
    let height: Int
    let samples: [Double]
    let legalRange: ClosedRange<Double>

    init(width: Int, height: Int, samples: [Double], legalRange: ClosedRange<Double> = 0.0...1.0) throws {
        guard width > 0, height > 0 else {
            throw ASHSpatialOperatorErrorV2.invalidPlaneDimensions(width: width, height: height)
        }
        let expected = width.multipliedReportingOverflow(by: height)
        guard !expected.overflow, samples.count == expected.partialValue else {
            throw ASHSpatialOperatorErrorV2.invalidSampleCount(
                expected: expected.overflow ? 0 : expected.partialValue,
                actual: samples.count
            )
        }
        guard legalRange.lowerBound.isFinite,
              legalRange.upperBound.isFinite,
              legalRange.lowerBound >= 0.0,
              legalRange.upperBound <= 1.0 else {
            throw ASHSpatialOperatorErrorV2.invalidLegalRange
        }
        for (index, sample) in samples.enumerated() where !sample.isFinite || !(0.0...1.0).contains(sample) {
            throw ASHSpatialOperatorErrorV2.invalidSample(index: index)
        }
        self.width = width
        self.height = height
        self.samples = samples
        self.legalRange = legalRange
    }

    func sample(column: Int, row: Int, boundary: ASHSpatialBoundaryModeV2) -> Double {
        let resolvedColumn = Self.resolve(column, extent: width, boundary: boundary)
        let resolvedRow = Self.resolve(row, extent: height, boundary: boundary)
        return samples[(resolvedRow * width) + resolvedColumn]
    }

    func legalClamp(_ value: Double) -> Double {
        min(legalRange.upperBound, max(legalRange.lowerBound, value))
    }

    private static func resolve(_ index: Int, extent: Int, boundary: ASHSpatialBoundaryModeV2) -> Int {
        switch boundary {
        case .clamp:
            return min(extent - 1, max(0, index))
        case .mirrorReflect101:
            guard extent > 1 else { return 0 }
            let period = 2 * (extent - 1)
            let raw = index % period
            let positive = raw >= 0 ? raw : raw + period
            return positive < extent ? positive : period - positive
        }
    }
}

struct ASHSpatialSidecarV2: Equatable, Sendable {
    let orientationRadians: Double
    let normalizedMagnitude: Double
    let coherence: Double
    let risk: Double
    let chromaAlignment: Double
    let localMinimum: Double
    let localMaximum: Double

    init(
        orientationRadians: Double,
        normalizedMagnitude: Double,
        coherence: Double,
        risk: Double,
        chromaAlignment: Double,
        localMinimum: Double,
        localMaximum: Double
    ) throws {
        let unitValues = [normalizedMagnitude, coherence, risk, chromaAlignment, localMinimum, localMaximum]
        guard orientationRadians.isFinite,
              unitValues.allSatisfy({ $0.isFinite && (0.0...1.0).contains($0) }),
              localMinimum <= localMaximum else {
            throw ASHSpatialOperatorErrorV2.invalidSidecar
        }
        self.orientationRadians = orientationRadians
        self.normalizedMagnitude = normalizedMagnitude
        self.coherence = coherence
        self.risk = risk
        self.chromaAlignment = chromaAlignment
        self.localMinimum = localMinimum
        self.localMaximum = localMaximum
    }
}

struct ASHSpatialDevelopmentParametersV2: Equatable, Sendable {
    static let lockStatus = "development_only_not_release_locked"
    static let p05DevelopmentOnly = ASHSpatialDevelopmentParametersV2(
        anisotropyStrength: 0.75,
        minimumAnisotropicMagnitude: 0.05,
        minimumAnisotropicCoherence: 0.15,
        controlledDetailGain: 0.18,
        relaxedLimiterAlpha: 0.08,
        riskDetailSuppressionThreshold: 0.65,
        lowPassRadius: 2.0,
        weightEpsilon: 1.0e-12
    )

    let anisotropyStrength: Double
    let minimumAnisotropicMagnitude: Double
    let minimumAnisotropicCoherence: Double
    let controlledDetailGain: Double
    let relaxedLimiterAlpha: Double
    let riskDetailSuppressionThreshold: Double
    let lowPassRadius: Double
    let weightEpsilon: Double
    let supportRadius: Double?

    init(
        anisotropyStrength: Double,
        minimumAnisotropicMagnitude: Double,
        minimumAnisotropicCoherence: Double,
        controlledDetailGain: Double,
        relaxedLimiterAlpha: Double,
        riskDetailSuppressionThreshold: Double,
        lowPassRadius: Double,
        weightEpsilon: Double,
        supportRadius: Double? = nil
    ) {
        self.anisotropyStrength = anisotropyStrength
        self.minimumAnisotropicMagnitude = minimumAnisotropicMagnitude
        self.minimumAnisotropicCoherence = minimumAnisotropicCoherence
        self.controlledDetailGain = controlledDetailGain
        self.relaxedLimiterAlpha = relaxedLimiterAlpha
        self.riskDetailSuppressionThreshold = riskDetailSuppressionThreshold
        self.lowPassRadius = lowPassRadius
        self.weightEpsilon = weightEpsilon
        self.supportRadius = supportRadius
    }

    var isValid: Bool {
        let values = [
            anisotropyStrength,
            minimumAnisotropicMagnitude,
            minimumAnisotropicCoherence,
            controlledDetailGain,
            relaxedLimiterAlpha,
            riskDetailSuppressionThreshold,
            lowPassRadius,
            weightEpsilon
        ]
        return values.allSatisfy(\.isFinite)
            && anisotropyStrength >= 0.0
            && (0.0...1.0).contains(minimumAnisotropicMagnitude)
            && (0.0...1.0).contains(minimumAnisotropicCoherence)
            && controlledDetailGain >= 0.0
            && relaxedLimiterAlpha >= 0.0
            && (0.0...1.0).contains(riskDetailSuppressionThreshold)
            && riskDetailSuppressionThreshold > 0.0
            && lowPassRadius > 0.0
            && weightEpsilon > 0.0
            && (supportRadius.map { $0.isFinite && (1.0...3.0).contains($0) } ?? true)
    }
}

struct ASHSpatialSampleRequestV2: Sendable {
    let plane: ASHSpatialPlaneV2
    let destinationColumn: Int
    let destinationRow: Int
    let route: ASHSpatialRouteV2
    let coordinatePolicy: ASHSpatialCoordinatePolicyV2
    let descriptor: ASHSpatialDescriptorV2
    let sidecar: ASHSpatialSidecarV2
    let boundary: ASHSpatialBoundaryModeV2
    let parameters: ASHSpatialDevelopmentParametersV2
    let coordinateOverride: ASHSpatialSourceCoordinatesV2?
}

struct ASHSpatialSourceCoordinatesV2: Equatable, Sendable {
    let horizontal: ASHSpatialRationalCoordinateV2
    let vertical: ASHSpatialRationalCoordinateV2
}

struct ASHSpatialSampleResultV2: Equatable, Sendable {
    let value: Double
    let sourceX: ASHSpatialRationalCoordinateV2
    let sourceY: ASHSpatialRationalCoordinateV2
    let phase: ASHSpatialPhaseV2
    let descriptorID: UInt8
    let sourceAlignedSamplePreserved: Bool
    let contributingSampleCount: Int
    let diagnostics: ASHSpatialConstraintDiagnosticsV2
}

struct ASHSpatialConstraintDiagnosticsV2: Equatable, Sendable {
    let supportMinimum: Double
    let supportMaximum: Double
    let preLimiterValue: Double
    let limiterLowerBound: Double
    let limiterUpperBound: Double
    let postLimiterValue: Double
    let limiterMode: ASHSpatialLimiterModeV2
    let anisotropyUsed: Bool
    let effectiveDetailGain: Double
    let detailApplied: Bool
}

enum ASHSpatialOperatorBankV2 {
    static let descriptors = ASHSpatialDescriptorV2.all

    static func conservativeFallback(
        for error: ASHSpatialOperatorErrorV2
    ) -> ASHSpatialFallbackInstructionV2? {
        let fault: ASHSpatialNumericalFaultV2
        switch error {
        case .nonFiniteWeight:
            fault = .nonFiniteWeight
        case .zeroWeight:
            fault = .zeroWeight
        case .nonFiniteResult:
            fault = .nonFiniteResult
        default:
            return nil
        }
        return ASHSpatialFallbackInstructionV2(
            fault: fault,
            descriptorID: 0,
            limiterMode: .strictNeighborhoodRange,
            preserveExactCoordinate: true
        )
    }

    static func coordinate(
        destinationIndex: Int,
        sourceExtent: Int,
        destinationExtent: Int,
        policy: ASHSpatialCoordinatePolicyV2
    ) throws -> ASHSpatialRationalCoordinateV2 {
        guard sourceExtent > 0, destinationExtent > 0,
              (0..<destinationExtent).contains(destinationIndex) else {
            throw ASHSpatialOperatorErrorV2.invalidDestinationIndex(
                index: destinationIndex,
                extent: destinationExtent
            )
        }
        let index = Int64(destinationIndex)
        let source = Int64(sourceExtent)
        let destination = Int64(destinationExtent)
        switch policy {
        case .halfPixelCenter:
            let doubled = index.multipliedReportingOverflow(by: 2)
            let centered = doubled.partialValue.addingReportingOverflow(1)
            let scaled = centered.partialValue.multipliedReportingOverflow(by: source)
            let numerator = scaled.partialValue.subtractingReportingOverflow(destination)
            let denominator = destination.multipliedReportingOverflow(by: 2)
            guard !doubled.overflow, !centered.overflow, !scaled.overflow,
                  !numerator.overflow, !denominator.overflow else {
                throw ASHSpatialOperatorErrorV2.coordinateOverflow
            }
            return ASHSpatialRationalCoordinateV2(
                numerator: numerator.partialValue,
                denominator: denominator.partialValue
            )
        case .sourceAlignedRational:
            let numerator = index.multipliedReportingOverflow(by: source)
            guard !numerator.overflow else { throw ASHSpatialOperatorErrorV2.coordinateOverflow }
            return ASHSpatialRationalCoordinateV2(
                numerator: numerator.partialValue,
                denominator: destination
            )
        }
    }

    static func phase(
        destinationColumn: Int,
        destinationRow: Int,
        plane: ASHSpatialPlaneV2,
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2
    ) throws -> ASHSpatialPhaseV2 {
        let coordinates = try sourceCoordinates(
            destinationColumn: destinationColumn,
            destinationRow: destinationRow,
            plane: plane,
            route: route,
            policy: policy
        )
        return ASHSpatialPhaseV2(
            horizontal: ASHSpatialPhaseComponentV2(coordinate: coordinates.horizontal),
            vertical: ASHSpatialPhaseComponentV2(coordinate: coordinates.vertical)
        )
    }

    // swiftlint:disable:next function_body_length
    static func evaluateSample(_ request: ASHSpatialSampleRequestV2) throws -> ASHSpatialSampleResultV2 {
        guard request.parameters.isValid else { throw ASHSpatialOperatorErrorV2.invalidDevelopmentParameters }
        let coordinates: ASHSpatialSourceCoordinatesV2
        if let coordinateOverride = request.coordinateOverride {
            coordinates = coordinateOverride
        } else {
            let computed = try sourceCoordinates(
                destinationColumn: request.destinationColumn,
                destinationRow: request.destinationRow,
                plane: request.plane,
                route: request.route,
                policy: request.coordinatePolicy
            )
            coordinates = ASHSpatialSourceCoordinatesV2(
                horizontal: computed.horizontal,
                vertical: computed.vertical
            )
        }
        let phase = ASHSpatialPhaseV2(
            horizontal: ASHSpatialPhaseComponentV2(coordinate: coordinates.horizontal),
            vertical: ASHSpatialPhaseComponentV2(coordinate: coordinates.vertical)
        )

        if request.coordinatePolicy == .sourceAlignedRational,
           let sourceColumn = coordinates.horizontal.integralValue,
           let sourceRow = coordinates.vertical.integralValue {
            let value = request.plane.sample(column: sourceColumn, row: sourceRow, boundary: request.boundary)
            let clampedValue = request.plane.legalClamp(value)
            return ASHSpatialSampleResultV2(
                value: clampedValue,
                sourceX: coordinates.horizontal,
                sourceY: coordinates.vertical,
                phase: phase,
                descriptorID: request.descriptor.id,
                sourceAlignedSamplePreserved: true,
                contributingSampleCount: 1,
                diagnostics: ASHSpatialConstraintDiagnosticsV2(
                    supportMinimum: value,
                    supportMaximum: value,
                    preLimiterValue: value,
                    limiterLowerBound: value,
                    limiterUpperBound: value,
                    postLimiterValue: value,
                    limiterMode: request.descriptor.limiterMode,
                    anisotropyUsed: false,
                    effectiveDetailGain: 0.0,
                    detailApplied: false
                )
            )
        }

        let reconstruction = try reconstruct(
            plane: request.plane,
            sourceX: coordinates.horizontal.value,
            sourceY: coordinates.vertical.value,
            descriptor: request.descriptor,
            sidecar: request.sidecar,
            boundary: request.boundary,
            parameters: request.parameters
        )
        var value = reconstruction.value
        var effectiveDetailGain = 0.0
        if request.descriptor.detailMode == .controlledPositive {
            let lowPass = try lowPassValue(
                plane: request.plane,
                sourceX: coordinates.horizontal.value,
                sourceY: coordinates.vertical.value,
                boundary: request.boundary,
                parameters: request.parameters
            )
            let riskScale = request.sidecar.risk >= request.parameters.riskDetailSuppressionThreshold
                ? 0.0
                : 1.0 - (request.sidecar.risk / request.parameters.riskDetailSuppressionThreshold)
            effectiveDetailGain = request.parameters.controlledDetailGain * riskScale
            value += effectiveDetailGain * (value - lowPass)
        }

        let supportRange = reconstruction.minimum...reconstruction.maximum
        let preLimiterValue = value
        let limiterLowerBound: Double
        let limiterUpperBound: Double
        switch request.descriptor.limiterMode {
        case .strictNeighborhoodRange:
            limiterLowerBound = supportRange.lowerBound
            limiterUpperBound = supportRange.upperBound
        case .calibratedRelaxedRange:
            let span = supportRange.upperBound - supportRange.lowerBound
            let allowance = request.parameters.relaxedLimiterAlpha * span
            limiterLowerBound = supportRange.lowerBound - allowance
            limiterUpperBound = supportRange.upperBound + allowance
        }
        value = min(limiterUpperBound, max(limiterLowerBound, value))
        guard value.isFinite else { throw ASHSpatialOperatorErrorV2.nonFiniteResult }

        return ASHSpatialSampleResultV2(
            value: request.plane.legalClamp(value),
            sourceX: coordinates.horizontal,
            sourceY: coordinates.vertical,
            phase: phase,
            descriptorID: request.descriptor.id,
            sourceAlignedSamplePreserved: false,
            contributingSampleCount: reconstruction.sampleCount,
            diagnostics: ASHSpatialConstraintDiagnosticsV2(
                supportMinimum: supportRange.lowerBound,
                supportMaximum: supportRange.upperBound,
                preLimiterValue: preLimiterValue,
                limiterLowerBound: limiterLowerBound,
                limiterUpperBound: limiterUpperBound,
                postLimiterValue: value,
                limiterMode: request.descriptor.limiterMode,
                anisotropyUsed: reconstruction.anisotropyUsed,
                effectiveDetailGain: effectiveDetailGain,
                detailApplied: effectiveDetailGain > 0.0
            )
        )
    }

    static func normalize(weightedSum: Double, totalWeight: Double, epsilon: Double) throws -> Double {
        guard weightedSum.isFinite, totalWeight.isFinite else {
            throw ASHSpatialOperatorErrorV2.nonFiniteWeight
        }
        guard abs(totalWeight) > epsilon else { throw ASHSpatialOperatorErrorV2.zeroWeight }
        let value = weightedSum / totalWeight
        guard value.isFinite else { throw ASHSpatialOperatorErrorV2.nonFiniteResult }
        return value
    }

    private struct Reconstruction {
        let value: Double
        let minimum: Double
        let maximum: Double
        let sampleCount: Int
        let anisotropyUsed: Bool
    }

    private static func sourceCoordinates(
        destinationColumn: Int,
        destinationRow: Int,
        plane: ASHSpatialPlaneV2,
        route: ASHSpatialRouteV2,
        policy: ASHSpatialCoordinatePolicyV2
    ) throws -> (horizontal: ASHSpatialRationalCoordinateV2, vertical: ASHSpatialRationalCoordinateV2) {
        let destinationWidth = try route.destinationExtent(for: plane.width)
        let destinationHeight = try route.destinationExtent(for: plane.height)
        let sourceX = try coordinate(
            destinationIndex: destinationColumn,
            sourceExtent: plane.width,
            destinationExtent: destinationWidth,
            policy: policy
        )
        let sourceY = try coordinate(
            destinationIndex: destinationRow,
            sourceExtent: plane.height,
            destinationExtent: destinationHeight,
            policy: policy
        )
        return (sourceX, sourceY)
    }

    private static func reconstruct(
        plane: ASHSpatialPlaneV2,
        sourceX: Double,
        sourceY: Double,
        descriptor: ASHSpatialDescriptorV2,
        sidecar: ASHSpatialSidecarV2,
        boundary: ASHSpatialBoundaryModeV2,
        parameters: ASHSpatialDevelopmentParametersV2
    ) throws -> Reconstruction {
        let useAnisotropy = descriptor.supportMode == .structureTensorAnisotropic
            && sidecar.normalizedMagnitude >= parameters.minimumAnisotropicMagnitude
            && sidecar.coherence >= parameters.minimumAnisotropicCoherence
        let cosine = cos(sidecar.orientationRadians)
        let sine = sin(sidecar.orientationRadians)
        let tangentScale = useAnisotropy ? 1.0 + (parameters.anisotropyStrength * sidecar.coherence) : 1.0
        let normalScale = useAnisotropy ? 1.0 / tangentScale : 1.0
        let radius = parameters.supportRadius ?? descriptor.baseKernel.supportRadius
        let kernelCoordinateScale = descriptor.baseKernel.supportRadius / radius
        let xRadius = radius * ((abs(cosine) * tangentScale) + (abs(sine) * normalScale))
        let yRadius = radius * ((abs(sine) * tangentScale) + (abs(cosine) * normalScale))
        let columns = Int(ceil(sourceX - xRadius))...Int(floor(sourceX + xRadius))
        let rows = Int(ceil(sourceY - yRadius))...Int(floor(sourceY + yRadius))

        var weightedSum = 0.0
        var totalWeight = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var sampleCount = 0
        for row in rows {
            for column in columns {
                let offsetX = Double(column) - sourceX
                let offsetY = Double(row) - sourceY
                let kernelX: Double
                let kernelY: Double
                if useAnisotropy {
                    kernelX = (((offsetX * cosine) + (offsetY * sine)) / tangentScale)
                        * kernelCoordinateScale
                    kernelY = (((-offsetX * sine) + (offsetY * cosine)) / normalScale)
                        * kernelCoordinateScale
                } else {
                    kernelX = offsetX * kernelCoordinateScale
                    kernelY = offsetY * kernelCoordinateScale
                }
                let weight = kernel(descriptor.baseKernel, kernelX) * kernel(descriptor.baseKernel, kernelY)
                guard weight.isFinite else { throw ASHSpatialOperatorErrorV2.nonFiniteWeight }
                if abs(weight) <= parameters.weightEpsilon { continue }
                let sample = plane.sample(column: column, row: row, boundary: boundary)
                weightedSum += weight * sample
                totalWeight += weight
                minimum = min(minimum, sample)
                maximum = max(maximum, sample)
                sampleCount += 1
            }
        }
        return Reconstruction(
            value: try normalize(weightedSum: weightedSum, totalWeight: totalWeight, epsilon: parameters.weightEpsilon),
            minimum: minimum,
            maximum: maximum,
            sampleCount: sampleCount,
            anisotropyUsed: useAnisotropy
        )
    }

    private static func lowPassValue(
        plane: ASHSpatialPlaneV2,
        sourceX: Double,
        sourceY: Double,
        boundary: ASHSpatialBoundaryModeV2,
        parameters: ASHSpatialDevelopmentParametersV2
    ) throws -> Double {
        let radius = parameters.lowPassRadius
        let columns = Int(ceil(sourceX - radius))...Int(floor(sourceX + radius))
        let rows = Int(ceil(sourceY - radius))...Int(floor(sourceY + radius))
        var weightedSum = 0.0
        var totalWeight = 0.0
        for row in rows {
            for column in columns {
                let xWeight = max(0.0, 1.0 - (abs(Double(column) - sourceX) / radius))
                let yWeight = max(0.0, 1.0 - (abs(Double(row) - sourceY) / radius))
                let weight = xWeight * yWeight
                if weight <= parameters.weightEpsilon { continue }
                weightedSum += weight * plane.sample(column: column, row: row, boundary: boundary)
                totalWeight += weight
            }
        }
        return try normalize(weightedSum: weightedSum, totalWeight: totalWeight, epsilon: parameters.weightEpsilon)
    }

    private static func kernel(_ base: ASHSpatialBaseKernelV2, _ value: Double) -> Double {
        let distance = abs(value)
        switch base {
        case .keysCubicAMinusHalf:
            let parameter = -0.5
            if distance < 1.0 {
                return ((parameter + 2.0) * pow(distance, 3.0))
                    - ((parameter + 3.0) * pow(distance, 2.0)) + 1.0
            }
            if distance < 2.0 {
                return (parameter * pow(distance, 3.0))
                    - (5.0 * parameter * pow(distance, 2.0))
                    + (8.0 * parameter * distance) - (4.0 * parameter)
            }
            return 0.0
        case .lanczos3:
            if distance <= Double.ulpOfOne { return 1.0 }
            guard distance < 3.0 else { return 0.0 }
            return sinc(value) * sinc(value / 3.0)
        }
    }

    private static func sinc(_ value: Double) -> Double {
        if abs(value) <= Double.ulpOfOne { return 1.0 }
        let scaled = Double.pi * value
        return sin(scaled) / scaled
    }
}
