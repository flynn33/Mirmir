import Foundation

struct ASHImage: Equatable, Sendable {
    let width: Int
    let height: Int
    let channels: Int
    let values: [Double]

    init(width: Int, height: Int, channels: Int, values: [Double]) throws {
        guard width > 0, height > 0, [1, 3, 4].contains(channels), values.count == width * height * channels else {
            throw ASHCoreError.invalidImageShape
        }
        for value in values {
            guard value.isFinite, value >= 0.0, value <= 1.0 else {
                throw ASHCoreError.invalidImageValue(value)
            }
        }
        self.width = width
        self.height = height
        self.channels = channels
        self.values = values
    }

    init(grayscaleRows rows: [[Double]]) throws {
        guard let first = rows.first, !first.isEmpty, rows.allSatisfy({ $0.count == first.count }) else {
            throw ASHCoreError.invalidImageShape
        }
        try self.init(width: first.count, height: rows.count, channels: 1, values: rows.flatMap { $0 })
    }

    init(grayscaleRows rows: [[Double]], repeatRowsToHeight height: Int) throws {
        guard height > 0, let first = rows.first, !first.isEmpty else {
            throw ASHCoreError.invalidImageShape
        }
        var repeatedRows: [[Double]] = []
        repeatedRows.reserveCapacity(height)
        for row in 0..<height {
            repeatedRows.append(rows[row % rows.count])
        }
        try self.init(grayscaleRows: repeatedRows)
    }

    init(width: Int, height: Int, generator: (Int, Int) -> Double) throws {
        guard width > 0, height > 0 else {
            throw ASHCoreError.invalidImageShape
        }
        var values: [Double] = []
        values.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                values.append(generator(row, column))
            }
        }
        try self.init(width: width, height: height, channels: 1, values: values)
    }

    init(rgbRows rows: [[[Double]]]) throws {
        guard let firstRow = rows.first,
              let firstPixel = firstRow.first,
              !firstPixel.isEmpty,
              [3, 4].contains(firstPixel.count),
              rows.allSatisfy({ row in
                  !row.isEmpty && row.count == firstRow.count && row.allSatisfy { $0.count == firstPixel.count }
              }) else {
            throw ASHCoreError.invalidImageShape
        }
        try self.init(
            width: firstRow.count,
            height: rows.count,
            channels: firstPixel.count,
            values: rows.flatMap { row in row.flatMap { $0 } }
        )
    }

    func value(row: Int, column: Int, channel: Int = 0) -> Double {
        values[((row * width) + column) * channels + channel]
    }

    func replacing(values newValues: [Double]) throws -> ASHImage {
        try ASHImage(width: width, height: height, channels: channels, values: newValues)
    }
}

struct ASHFeatureVector: Equatable, Sendable {
    static let count = 8

    let values: [Double]

    init(values: [Double]) throws {
        guard values.count == Self.count,
              values.allSatisfy({ $0.isFinite && $0 >= 0.0 && $0 <= 1.0 }) else {
            throw ASHCoreError.invalidFeatureVector
        }
        self.values = values
    }
}

enum ASHFeatureExtractor {
    static let featureNames = [
        "mean_luminance",
        "rms_contrast",
        "edge_energy",
        "texture_energy",
        "chroma_energy",
        "horizontal_gradient_energy",
        "vertical_gradient_energy",
        "temporal_change"
    ]

    static func extract(
        current: ASHImage,
        previous: ASHImage? = nil,
        chromaEnergy: Double? = nil
    ) throws -> ASHFeatureVector {
        let lumaValues = luminance(current)
        let gradients = forwardGradients(lumaValues, width: current.width, height: current.height)

        let meanLuminance = mean(lumaValues)
        let rmsContrast = min(1.0, 2.0 * standardDeviation(lumaValues, mean: meanLuminance))
        let edgeEnergy = mean(zip(gradients.dx, gradients.dy).map { sqrt(($0 * $0) + ($1 * $1)) }) / sqrt(2.0)
        let textureEnergy = mean(
            zip(lumaValues, boxBlur3(lumaValues, width: current.width, height: current.height)).map { abs($0 - $1) }
        )
        let chromaEnergy = chromaEnergy ?? chroma(current)
        let horizontalGradient = mean(gradients.dx.map(abs))
        let verticalGradient = mean(gradients.dy.map(abs))

        let temporalChange: Double
        if let previous {
            guard previous.width == current.width, previous.height == current.height else {
                throw ASHCoreError.previousImageShapeMismatch
            }
            let previousY = luminance(previous)
            temporalChange = mean(zip(lumaValues, previousY).map { abs($0 - $1) })
        } else {
            temporalChange = 0.0
        }

        return try ASHFeatureVector(values: [
            meanLuminance,
            rmsContrast,
            edgeEnergy,
            textureEnergy,
            chromaEnergy,
            horizontalGradient,
            verticalGradient,
            temporalChange
        ].map { min(1.0, max(0.0, $0)) })
    }

    static func luminance(_ image: ASHImage) -> [Double] {
        if image.channels == 1 {
            return image.values
        }

        var result: [Double] = []
        result.reserveCapacity(image.width * image.height)
        for row in 0..<image.height {
            for column in 0..<image.width {
                let red = image.value(row: row, column: column, channel: 0)
                let green = image.value(row: row, column: column, channel: 1)
                let blue = image.value(row: row, column: column, channel: 2)
                result.append((0.2126 * red) + (0.7152 * green) + (0.0722 * blue))
            }
        }
        return result
    }

    static func forwardGradients(_ values: [Double], width: Int, height: Int) -> (dx: [Double], dy: [Double]) {
        var dx = Array(repeating: 0.0, count: values.count)
        var dy = Array(repeating: 0.0, count: values.count)

        if width > 1 {
            for row in 0..<height {
                for column in 0..<(width - 1) {
                    let index = (row * width) + column
                    dx[index] = values[index + 1] - values[index]
                }
            }
        }

        if height > 1 {
            for row in 0..<(height - 1) {
                for column in 0..<width {
                    let index = (row * width) + column
                    dy[index] = values[index + width] - values[index]
                }
            }
        }

        return (dx, dy)
    }

    private static func boxBlur3(_ values: [Double], width: Int, height: Int) -> [Double] {
        var result = Array(repeating: 0.0, count: values.count)
        for row in 0..<height {
            for column in 0..<width {
                var total = 0.0
                for rowOffset in -1...1 {
                    for columnOffset in -1...1 {
                        let clampedRow = min(max(row + rowOffset, 0), height - 1)
                        let clampedColumn = min(max(column + columnOffset, 0), width - 1)
                        total += values[(clampedRow * width) + clampedColumn]
                    }
                }
                result[(row * width) + column] = total / 9.0
            }
        }
        return result
    }

    private static func chroma(_ image: ASHImage) -> Double {
        guard image.channels >= 3 else { return 0.0 }
        var values: [Double] = []
        values.reserveCapacity(image.width * image.height)
        for row in 0..<image.height {
            for column in 0..<image.width {
                let red = image.value(row: row, column: column, channel: 0)
                let green = image.value(row: row, column: column, channel: 1)
                let blue = image.value(row: row, column: column, channel: 2)
                values.append(Swift.max(red, Swift.max(green, blue)) - Swift.min(red, Swift.min(green, blue)))
            }
        }
        return mean(values)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0.0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        sqrt(values.map { pow($0 - mean, 2.0) }.reduce(0.0, +) / Double(values.count))
    }
}

enum ASHFeatureBinarizer {
    static let defaultThresholds = [0.50, 0.20, 0.12, 0.08, 0.10, 0.10, 0.10, 0.08]
    static let defaultHysteresis = [0.02, 0.02, 0.015, 0.015, 0.015, 0.015, 0.015, 0.02]

    static func binarize(
        _ features: ASHFeatureVector,
        previousState: ASHState? = nil,
        thresholds: [Double] = defaultThresholds,
        hysteresis: [Double] = defaultHysteresis
    ) throws -> ASHState {
        try validate(parameters: thresholds)
        try validate(parameters: hysteresis)

        let priorPayload: [Int]?
        if let previousState {
            guard previousState.hasValidIntegrity else {
                throw ASHCoreError.invalidPreviousState
            }
            priorPayload = Array(previousState.bits.prefix(ASHState.payloadBitCount))
        } else {
            priorPayload = nil
        }

        var payload: [Int] = []
        payload.reserveCapacity(ASHState.payloadBitCount)
        for index in 0..<ASHState.payloadBitCount {
            let value = features.values[index]
            let threshold = thresholds[index]
            let band = hysteresis[index]
            if let priorPayload {
                if priorPayload[index] == 0 {
                    payload.append(value >= min(1.0, threshold + band) ? 1 : 0)
                } else {
                    payload.append(value < max(0.0, threshold - band) ? 0 : 1)
                }
            } else {
                payload.append(value >= threshold ? 1 : 0)
            }
        }

        return try ASHState(payloadBits: payload)
    }

    private static func validate(parameters: [Double]) throws {
        guard parameters.count == ASHFeatureVector.count,
              parameters.allSatisfy({ $0.isFinite && $0 >= 0.0 && $0 <= 1.0 }) else {
            throw ASHCoreError.invalidFeatureVector
        }
    }
}
