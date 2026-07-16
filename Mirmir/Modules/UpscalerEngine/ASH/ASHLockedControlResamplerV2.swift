import Foundation

enum ASHLockedControlResamplerV2Error: Error, Equatable, Sendable {
    case invalidGeometry
    case invalidKernelNormalization
    case unsupportedAlgorithm
}

enum ASHLockedConventionalAlgorithmV2: String, CaseIterable, Sendable {
    case bilinear = "bilinear-separable-v1"
    case keysCubic = "keys-cubic-a-minus-0.5-separable-v1"
    case lanczos3 = "lanczos3-separable-v1"
}

struct ASHLockedControlFrameV2: Equatable, Sendable {
    let luma: ASHLockedReferencePlaneOutputV2
    let cb: ASHLockedReferencePlaneOutputV2
    let cr: ASHLockedReferencePlaneOutputV2
}

enum ASHLockedControlResamplerV2 {
    static func conventional(
        input: ASHLockedReferenceInputV2,
        algorithm: ASHLockedConventionalAlgorithmV2
    ) throws -> ASHLockedControlFrameV2 {
        let route = input.lut.route
        let selection = input.configuration.routeSelection(for: route)
        let luma = try normalizedPlane(input.luma, chroma: false)
        let cb = try normalizedPlane(input.cb, chroma: true)
        let cr = try normalizedPlane(input.cr, chroma: true)
        return ASHLockedControlFrameV2(
            luma: try resample(
                plane: luma,
                outputWidth: route.destinationExtent(for: luma.width),
                outputHeight: route.destinationExtent(for: luma.height),
                algorithm: algorithm,
                boundary: input.configuration.boundaryMode,
                coordinatePolicy: selection.lumaCoordinatePolicy,
                chromaSiting: nil
            ),
            cb: try resample(
                plane: cb,
                outputWidth: route.destinationExtent(for: cb.width),
                outputHeight: route.destinationExtent(for: cb.height),
                algorithm: algorithm,
                boundary: input.configuration.boundaryMode,
                coordinatePolicy: selection.chromaCoordinatePolicy,
                chromaSiting: input.chromaSiting
            ),
            cr: try resample(
                plane: cr,
                outputWidth: route.destinationExtent(for: cr.width),
                outputHeight: route.destinationExtent(for: cr.height),
                algorithm: algorithm,
                boundary: input.configuration.boundaryMode,
                coordinatePolicy: selection.chromaCoordinatePolicy,
                chromaSiting: input.chromaSiting
            )
        )
    }

    static func nearest(
        input: ASHLockedReferenceInputV2
    ) throws -> ASHLockedControlFrameV2 {
        let route = input.lut.route
        let luma = try normalizedPlane(input.luma, chroma: false)
        let cb = try normalizedPlane(input.cb, chroma: true)
        let cr = try normalizedPlane(input.cr, chroma: true)
        return ASHLockedControlFrameV2(
            luma: try nearest(
                plane: luma,
                outputWidth: route.destinationExtent(for: luma.width),
                outputHeight: route.destinationExtent(for: luma.height)
            ),
            cb: try nearest(
                plane: cb,
                outputWidth: route.destinationExtent(for: cb.width),
                outputHeight: route.destinationExtent(for: cb.height)
            ),
            cr: try nearest(
                plane: cr,
                outputWidth: route.destinationExtent(for: cr.width),
                outputHeight: route.destinationExtent(for: cr.height)
            )
        )
    }

    static func h07Lanczos3(
        direct2x: ASHLockedReferenceOutputV2,
        targetLumaWidth: Int,
        targetLumaHeight: Int,
        targetChromaWidth: Int,
        targetChromaHeight: Int,
        boundary: ASHSpatialBoundaryModeV2
    ) throws -> ASHLockedControlFrameV2 {
        guard targetLumaWidth == targetChromaWidth * 2,
              targetLumaHeight == targetChromaHeight * 2 else {
            throw ASHLockedControlResamplerV2Error.invalidGeometry
        }
        return ASHLockedControlFrameV2(
            luma: try resample(
                plane: spatialPlane(direct2x.luma),
                outputWidth: targetLumaWidth,
                outputHeight: targetLumaHeight,
                algorithm: .lanczos3,
                boundary: boundary,
                coordinatePolicy: .halfPixelCenter,
                chromaSiting: nil
            ),
            cb: try resample(
                plane: spatialPlane(direct2x.cb),
                outputWidth: targetChromaWidth,
                outputHeight: targetChromaHeight,
                algorithm: .lanczos3,
                boundary: boundary,
                coordinatePolicy: .halfPixelCenter,
                chromaSiting: nil
            ),
            cr: try resample(
                plane: spatialPlane(direct2x.cr),
                outputWidth: targetChromaWidth,
                outputHeight: targetChromaHeight,
                algorithm: .lanczos3,
                boundary: boundary,
                coordinatePolicy: .halfPixelCenter,
                chromaSiting: nil
            )
        )
    }

    private static func normalizedPlane(
        _ source: ASHVideoAnalyzerV2CodePlane,
        chroma: Bool
    ) throws -> ASHSpatialPlaneV2 {
        var samples: [Double] = []
        samples.reserveCapacity(source.width * source.height)
        for row in 0..<source.height {
            let offset = row * source.bytesPerRow
            for column in 0..<source.width {
                let code = source.codes[offset + column]
                let value = chroma
                    ? source.range.normalizeChroma(code) + 0.5
                    : source.range.normalizeLuma(code)
                samples.append(unit(value))
            }
        }
        return try ASHSpatialPlaneV2(
            width: source.width,
            height: source.height,
            samples: samples
        )
    }

    private static func spatialPlane(
        _ source: ASHLockedReferencePlaneOutputV2
    ) throws -> ASHSpatialPlaneV2 {
        try ASHSpatialPlaneV2(
            width: source.width,
            height: source.height,
            samples: source.normalizedSamples
        )
    }

    private static func nearest(
        plane: ASHSpatialPlaneV2,
        outputWidth: Int,
        outputHeight: Int
    ) throws -> ASHLockedReferencePlaneOutputV2 {
        guard outputWidth > 0, outputHeight > 0 else {
            throw ASHLockedControlResamplerV2Error.invalidGeometry
        }
        var output: [Double] = []
        output.reserveCapacity(outputWidth * outputHeight)
        for row in 0..<outputHeight {
            let sourceRow = min(
                (row * plane.height) / outputHeight,
                plane.height - 1
            )
            for column in 0..<outputWidth {
                let sourceColumn = min(
                    (column * plane.width) / outputWidth,
                    plane.width - 1
                )
                output.append(
                    plane.samples[(sourceRow * plane.width) + sourceColumn]
                )
            }
        }
        return ASHLockedReferencePlaneOutputV2(
            width: outputWidth,
            height: outputHeight,
            normalizedSamples: output
        )
    }

    private static func resample(
        plane: ASHSpatialPlaneV2,
        outputWidth: Int,
        outputHeight: Int,
        algorithm: ASHLockedConventionalAlgorithmV2,
        boundary: ASHSpatialBoundaryModeV2,
        coordinatePolicy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> ASHLockedReferencePlaneOutputV2 {
        guard outputWidth > 0, outputHeight > 0 else {
            throw ASHLockedControlResamplerV2Error.invalidGeometry
        }
        var output: [Double] = []
        output.reserveCapacity(outputWidth * outputHeight)
        for row in 0..<outputHeight {
            let vertical = try coordinate(
                destinationIndex: row,
                sourceExtent: plane.height,
                destinationExtent: outputHeight,
                policy: coordinatePolicy,
                chromaSiting: chromaSiting,
                axis: .vertical
            ).value
            let verticalTaps = try normalizedTaps(
                coordinate: vertical,
                algorithm: algorithm
            )
            for column in 0..<outputWidth {
                let horizontal = try coordinate(
                    destinationIndex: column,
                    sourceExtent: plane.width,
                    destinationExtent: outputWidth,
                    policy: coordinatePolicy,
                    chromaSiting: chromaSiting,
                    axis: .horizontal
                ).value
                let horizontalTaps = try normalizedTaps(
                    coordinate: horizontal,
                    algorithm: algorithm
                )
                var value = 0.0
                for verticalTap in verticalTaps {
                    var rowValue = 0.0
                    for horizontalTap in horizontalTaps {
                        rowValue += horizontalTap.weight * plane.sample(
                            column: horizontalTap.index,
                            row: verticalTap.index,
                            boundary: boundary
                        )
                    }
                    value += verticalTap.weight * rowValue
                }
                guard value.isFinite else {
                    throw ASHLockedControlResamplerV2Error.invalidKernelNormalization
                }
                output.append(unit(value))
            }
        }
        return ASHLockedReferencePlaneOutputV2(
            width: outputWidth,
            height: outputHeight,
            normalizedSamples: output
        )
    }

    private static func coordinate(
        destinationIndex: Int,
        sourceExtent: Int,
        destinationExtent: Int,
        policy: ASHSpatialCoordinatePolicyV2,
        chromaSiting: ASHChromaSitingV2?,
        axis: ASHChromaSitingAxisV2
    ) throws -> ASHSpatialRationalCoordinateV2 {
        if let chromaSiting {
            return try chromaSiting.sourceCoordinate(
                destinationIndex: destinationIndex,
                sourceExtent: sourceExtent,
                destinationExtent: destinationExtent,
                policy: policy,
                axis: axis
            )
        }
        return try ASHSpatialOperatorBankV2.coordinate(
            destinationIndex: destinationIndex,
            sourceExtent: sourceExtent,
            destinationExtent: destinationExtent,
            policy: policy
        )
    }

    private struct Tap {
        let index: Int
        let weight: Double
    }

    private static func normalizedTaps(
        coordinate: Double,
        algorithm: ASHLockedConventionalAlgorithmV2
    ) throws -> [Tap] {
        let base = Int(floor(coordinate))
        let indices: ClosedRange<Int>
        switch algorithm {
        case .bilinear: indices = base...(base + 1)
        case .keysCubic: indices = (base - 1)...(base + 2)
        case .lanczos3: indices = (base - 2)...(base + 3)
        }
        let raw = indices.map { index in
            Tap(index: index, weight: kernel(coordinate - Double(index), algorithm))
        }
        let sum = raw.reduce(0.0) { $0 + $1.weight }
        guard sum.isFinite, sum != 0.0 else {
            throw ASHLockedControlResamplerV2Error.invalidKernelNormalization
        }
        return raw.map { Tap(index: $0.index, weight: $0.weight / sum) }
    }

    private static func kernel(
        _ distance: Double,
        _ algorithm: ASHLockedConventionalAlgorithmV2
    ) -> Double {
        let value = abs(distance)
        switch algorithm {
        case .bilinear:
            return max(0.0, 1.0 - value)
        case .keysCubic:
            if value < 1.0 {
                return (1.5 * value * value * value)
                    - (2.5 * value * value) + 1.0
            }
            if value < 2.0 {
                return (-0.5 * value * value * value)
                    + (2.5 * value * value) - (4.0 * value) + 2.0
            }
            return 0.0
        case .lanczos3:
            guard value < 3.0 else { return 0.0 }
            guard value != 0.0 else { return 1.0 }
            return sinc(value) * sinc(value / 3.0)
        }
    }

    private static func sinc(_ value: Double) -> Double {
        sin(.pi * value) / (.pi * value)
    }

    private static func unit(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }
}
