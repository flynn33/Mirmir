import Foundation

enum ASHMeasurementExtractorV4Error: Error, Equatable, Sendable {
    case unsupportedStorage(PixelStorageV4)
    case missingPlane(Int)
    case invalidPlaneLayout(Int)
    case incompatibleHistory
    case invalidTemporalEvidence(UInt32)
    case arithmeticOverflow
}

struct ASHExtractedMeasurementV4: Equatable, Sendable {
    let projection: ASHMeasurementProjectionV4
    /// Canonical 32×32 (or contract-declared) Q16 luma window used to derive
    /// the projection. It is retained for independent conformance tests.
    let normalizedLumaWindowQ16: [UInt32]
}

/// Exact integer implementation of the canonical ASH image measurements. The
/// source is decoded YCbCr, so BT.709 encoded RGB is reconstructed in Q16 only
/// for chroma energy; luma and spatial differences use the equivalent decoded
/// luma signal. Every division uses nearest/ties-to-even.
enum ASHMeasurementExtractorV4 {
    private static let q16Scale: UInt64 = 65_536
    private static let inverseSquareRootTwoQ16: UInt64 = 46_341
    private static let redCrQ16: Int64 = 103_206       // 1.5748
    private static let greenCbQ16: Int64 = 12_276      // 0.187324
    private static let greenCrQ16: Int64 = 30_679      // 0.468124
    private static let blueCbQ16: Int64 = 121_609      // 1.8556

    static func extract(
        frame: PixelBufferSignalFrameV4,
        previousFrame: PixelBufferSignalFrameV4?,
        contract: ASHMeasurementContractV4,
        history: ASHMeasurementHistoryV4,
        motionCompensatedTemporalEvidenceQ16: UInt32? = nil
    ) throws -> ASHExtractedMeasurementV4 {
        try contract.validateCanonical()
        if let motionCompensatedTemporalEvidenceQ16,
           motionCompensatedTemporalEvidenceQ16
            > ASHNormalizedQ16V4.scale {
            throw ASHMeasurementExtractorV4Error.invalidTemporalEvidence(
                motionCompensatedTemporalEvidenceQ16
            )
        }
        guard frame.planes.count == 2 else {
            throw ASHMeasurementExtractorV4Error.missingPlane(1)
        }
        let lumaPlane = frame.planes[0]
        let chromaPlane = frame.planes[1]
        guard lumaPlane.componentsPerElement == 1,
              chromaPlane.componentsPerElement == 2,
              lumaPlane.width == frame.width,
              lumaPlane.height == frame.height else {
            throw ASHMeasurementExtractorV4Error.invalidPlaneLayout(0)
        }

        let previousLuma: PixelBufferSignalPlaneV4?
        if let previousFrame {
            guard previousFrame.storage == frame.storage,
                  previousFrame.width == frame.width,
                  previousFrame.height == frame.height,
                  previousFrame.planes.count == frame.planes.count else {
                throw ASHMeasurementExtractorV4Error.incompatibleHistory
            }
            previousLuma = previousFrame.planes[0]
        } else {
            previousLuma = nil
        }

        let windowWidth = Int(contract.window.width)
        let windowHeight = Int(contract.window.height)
        let count = try checkedProduct(windowWidth, windowHeight)
        let lumaBounds = lumaPlane.componentBounds[0]
        let chromaBounds = chromaPlane.componentBounds
        var yValues: [UInt32] = []
        var previousYValues: [UInt32]? = previousLuma == nil
            ? nil : []
        var chromaValues: [UInt32] = []
        yValues.reserveCapacity(count)
        previousYValues?.reserveCapacity(count)
        chromaValues.reserveCapacity(count)

        for y in 0..<windowHeight {
            let sourceY = min(y, frame.height - 1)
            let chromaY = min(
                sourceY / 2,
                chromaPlane.height - 1
            )
            for x in 0..<windowWidth {
                let sourceX = min(x, frame.width - 1)
                let chromaX = min(
                    sourceX / 2,
                    chromaPlane.width - 1
                )
                let lumaCode = lumaPlane.samples[
                    sourceY * lumaPlane.width + sourceX
                ]
                let yQ16 = try normalize(
                    lumaCode,
                    minimum: lumaBounds.minimum,
                    maximum: lumaBounds.maximum
                )
                yValues.append(yQ16)
                if let previousLuma {
                    let previousCode = previousLuma.samples[
                        sourceY * previousLuma.width + sourceX
                    ]
                    previousYValues?.append(try normalize(
                        previousCode,
                        minimum: lumaBounds.minimum,
                        maximum: lumaBounds.maximum
                    ))
                }
                let chromaIndex = (
                    chromaY * chromaPlane.width + chromaX
                ) * 2
                chromaValues.append(try chromaEnergyQ16(
                    yQ16: yQ16,
                    cb: chromaPlane.samples[chromaIndex],
                    cr: chromaPlane.samples[chromaIndex + 1],
                    cbBounds: chromaBounds[0],
                    crBounds: chromaBounds[1],
                    bitDepth: frame.storage.signalBitDepth
                ))
            }
        }

        let mean = try meanQ16(yValues)
        let contrast = try rmsContrastQ16(yValues, mean: mean)
        let gradients = try gradientMeasurements(
            yValues,
            width: windowWidth,
            height: windowHeight
        )
        let texture = try textureEnergyQ16(
            yValues,
            width: windowWidth,
            height: windowHeight
        )
        let chroma = try meanQ16(chromaValues)
        let temporal: UInt32
        if let motionCompensatedTemporalEvidenceQ16 {
            // Production supplies the residual from the canonical block-motion
            // analysis. The colocated window below remains the deterministic
            // fallback used by standalone measurement tooling and legacy
            // fixtures that do not own temporal motion state.
            temporal = motionCompensatedTemporalEvidenceQ16
        } else if let previousYValues {
            var total: UInt64 = 0
            for index in yValues.indices {
                total = try checkedSum(
                    total,
                    UInt64(absoluteDifference(
                        yValues[index],
                        previousYValues[index]
                    ))
                )
            }
            temporal = try UInt32(exactly: divideTiesToEven(
                total,
                by: UInt64(count)
            )).unwrapOrOverflow()
        } else {
            temporal = 0
        }

        let evidence = ASHMeasurementEvidenceV4(
            contract: contract,
            meanLuminance: try ASHNormalizedQ16V4(rawValue: mean),
            rmsContrast: try ASHNormalizedQ16V4(rawValue: contrast),
            edgeEnergy: try ASHNormalizedQ16V4(
                rawValue: gradients.edge
            ),
            textureEnergy: try ASHNormalizedQ16V4(rawValue: texture),
            chromaEnergy: try ASHNormalizedQ16V4(rawValue: chroma),
            horizontalGradientEnergy: try ASHNormalizedQ16V4(
                rawValue: gradients.horizontal
            ),
            verticalGradientEnergy: try ASHNormalizedQ16V4(
                rawValue: gradients.vertical
            ),
            temporalChange: try ASHNormalizedQ16V4(rawValue: temporal)
        )
        return ASHExtractedMeasurementV4(
            projection: try contract.project(evidence, history: history),
            normalizedLumaWindowQ16: yValues
        )
    }

    private static func normalize(
        _ code: UInt16,
        minimum: UInt16,
        maximum: UInt16
    ) throws -> UInt32 {
        guard code >= minimum, code <= maximum, minimum < maximum else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        let numerator = UInt64(code - minimum) * q16Scale
        return try UInt32(exactly: divideTiesToEven(
            numerator,
            by: UInt64(maximum - minimum)
        )).unwrapOrOverflow()
    }

    private static func chromaEnergyQ16(
        yQ16: UInt32,
        cb: UInt16,
        cr: UInt16,
        cbBounds: PixelCodeBoundsV4,
        crBounds: PixelCodeBoundsV4,
        bitDepth: Int
    ) throws -> UInt32 {
        let neutral = Int64(1 << (bitDepth - 1))
        let cbExtent = max(
            neutral - Int64(cbBounds.minimum),
            Int64(cbBounds.maximum) - neutral
        )
        let crExtent = max(
            neutral - Int64(crBounds.minimum),
            Int64(crBounds.maximum) - neutral
        )
        guard cbExtent > 0, crExtent > 0 else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        let cbQ16 = try divideSignedTiesToEven(
            (Int64(cb) - neutral) * 32_768,
            by: cbExtent
        )
        let crQ16 = try divideSignedTiesToEven(
            (Int64(cr) - neutral) * 32_768,
            by: crExtent
        )
        let y = Int64(yQ16)
        let red = clampQ16(try checkedSumSigned(
            y,
            try multiplyQ16(redCrQ16, crQ16)
        ))
        let green = clampQ16(try checkedSumSigned(
            try checkedSumSigned(
                y,
                -(try multiplyQ16(greenCbQ16, cbQ16))
            ),
            -(try multiplyQ16(greenCrQ16, crQ16))
        ))
        let blue = clampQ16(try checkedSumSigned(
            y,
            try multiplyQ16(blueCbQ16, cbQ16)
        ))
        return UInt32(
            max(red, max(green, blue)) - min(red, min(green, blue))
        )
    }

    private static func meanQ16(_ values: [UInt32]) throws -> UInt32 {
        guard !values.isEmpty else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        let total = try values.reduce(UInt64(0)) {
            try checkedSum($0, UInt64($1))
        }
        return try UInt32(exactly: divideTiesToEven(
            total,
            by: UInt64(values.count)
        )).unwrapOrOverflow()
    }

    private static func rmsContrastQ16(
        _ values: [UInt32],
        mean: UInt32
    ) throws -> UInt32 {
        var squaredTotal: UInt64 = 0
        for value in values {
            let difference = UInt64(absoluteDifference(value, mean))
            let square = difference.multipliedReportingOverflow(by: difference)
            guard !square.overflow else {
                throw ASHMeasurementExtractorV4Error.arithmeticOverflow
            }
            squaredTotal = try checkedSum(squaredTotal, square.partialValue)
        }
        let variance = divideTiesToEven(
            squaredTotal,
            by: UInt64(values.count)
        )
        let standardDeviation = integerSquareRootNearestTiesToEven(variance)
        return UInt32(min(q16Scale, standardDeviation * 2))
    }

    private static func gradientMeasurements(
        _ values: [UInt32],
        width: Int,
        height: Int
    ) throws -> (edge: UInt32, horizontal: UInt32, vertical: UInt32) {
        var edgeTotal: UInt64 = 0
        var horizontalTotal: UInt64 = 0
        var verticalTotal: UInt64 = 0
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let dx: UInt32 = x + 1 < width
                    ? absoluteDifference(values[index + 1], values[index])
                    : 0
                let dy: UInt32 = y + 1 < height
                    ? absoluteDifference(values[index + width], values[index])
                    : 0
                horizontalTotal = try checkedSum(
                    horizontalTotal,
                    UInt64(dx)
                )
                verticalTotal = try checkedSum(verticalTotal, UInt64(dy))
                let dxSquare = UInt64(dx) * UInt64(dx)
                let dySquare = UInt64(dy) * UInt64(dy)
                let magnitude = integerSquareRootNearestTiesToEven(
                    try checkedSum(dxSquare, dySquare)
                )
                let normalized = divideTiesToEven(
                    magnitude * inverseSquareRootTwoQ16,
                    by: q16Scale
                )
                edgeTotal = try checkedSum(edgeTotal, normalized)
            }
        }
        let count = UInt64(values.count)
        return (
            try UInt32(exactly: divideTiesToEven(edgeTotal, by: count))
                .unwrapOrOverflow(),
            try UInt32(exactly: divideTiesToEven(horizontalTotal, by: count))
                .unwrapOrOverflow(),
            try UInt32(exactly: divideTiesToEven(verticalTotal, by: count))
                .unwrapOrOverflow()
        )
    }

    private static func textureEnergyQ16(
        _ values: [UInt32],
        width: Int,
        height: Int
    ) throws -> UInt32 {
        var total: UInt64 = 0
        for y in 0..<height {
            for x in 0..<width {
                var neighborhood: UInt64 = 0
                for offsetY in -1...1 {
                    let sampleY = min(max(y + offsetY, 0), height - 1)
                    for offsetX in -1...1 {
                        let sampleX = min(max(x + offsetX, 0), width - 1)
                        neighborhood = try checkedSum(
                            neighborhood,
                            UInt64(values[sampleY * width + sampleX])
                        )
                    }
                }
                let blurred = divideTiesToEven(neighborhood, by: 9)
                total = try checkedSum(
                    total,
                    UInt64(absoluteDifference(
                        values[y * width + x],
                        UInt32(blurred)
                    ))
                )
            }
        }
        return try UInt32(exactly: divideTiesToEven(
            total,
            by: UInt64(values.count)
        )).unwrapOrOverflow()
    }

    private static func absoluteDifference<T: FixedWidthInteger & UnsignedInteger>(
        _ left: T,
        _ right: T
    ) -> T {
        left >= right ? left - right : right - left
    }

    private static func multiplyQ16(_ left: Int64, _ right: Int64) throws -> Int64 {
        let product = left.multipliedReportingOverflow(by: right)
        guard !product.overflow else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        return try divideSignedTiesToEven(product.partialValue, by: 65_536)
    }

    private static func divideSignedTiesToEven(
        _ numerator: Int64,
        by denominator: Int64
    ) throws -> Int64 {
        guard denominator > 0, numerator != Int64.min else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        let negative = numerator < 0
        let magnitude = UInt64(negative ? -numerator : numerator)
        let rounded = divideTiesToEven(magnitude, by: UInt64(denominator))
        guard rounded <= UInt64(Int64.max) else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        let result = Int64(rounded)
        return negative ? -result : result
    }

    private static func divideTiesToEven(
        _ numerator: UInt64,
        by denominator: UInt64
    ) -> UInt64 {
        precondition(denominator > 0)
        var quotient = numerator / denominator
        let remainder = numerator % denominator
        let complement = denominator - remainder
        if remainder > complement
            || (remainder == complement && quotient & 1 == 1) {
            quotient += 1
        }
        return quotient
    }

    private static func integerSquareRootNearestTiesToEven(
        _ value: UInt64
    ) -> UInt64 {
        if value < 2 { return value }
        var low: UInt64 = 1
        var high = min(value, UInt64(UInt32.max) + 1)
        while low + 1 < high {
            let middle = low + (high - low) / 2
            if middle <= value / middle {
                low = middle
            } else {
                high = middle
            }
        }
        let lowerSquare = low * low
        let upper = low + 1
        let upperSquare = upper * upper
        let lowerDistance = value - lowerSquare
        let upperDistance = upperSquare - value
        if upperDistance < lowerDistance
            || (upperDistance == lowerDistance && low & 1 == 1) {
            return upper
        }
        return low
    }

    private static func clampQ16(_ value: Int64) -> Int64 {
        min(max(value, 0), 65_536)
    }

    private static func checkedSum(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func checkedSumSigned(
        _ left: Int64,
        _ right: Int64
    ) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        return result.partialValue
    }

    private static func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        return result.partialValue
    }
}

private extension Optional where Wrapped: FixedWidthInteger {
    func unwrapOrOverflow() throws -> Wrapped {
        guard let self else {
            throw ASHMeasurementExtractorV4Error.arithmeticOverflow
        }
        return self
    }
}
