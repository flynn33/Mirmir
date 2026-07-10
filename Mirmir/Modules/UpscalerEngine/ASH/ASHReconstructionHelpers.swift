extension ASHReconstruction {
    struct OperatorBasis {
        let baseline: ASHImage
        let horizontalDetail: [Double]
        let verticalDetail: [Double]
        let isotropicDetail: [Double]
    }

    static func makeOperatorBasis(source: ASHImage, scale: Int) throws -> OperatorBasis {
        let baseline = try nearestUpsample(source, scale: scale)
        let horizontalBlur = blurAxis(baseline, axis: 1)
        let verticalBlur = blurAxis(baseline, axis: 0)
        let isotropicBlur = blurAxis(try baseline.replacing(values: verticalBlur), axis: 1)
        return OperatorBasis(
            baseline: baseline,
            horizontalDetail: zip(baseline.values, horizontalBlur).map { baselineValue, blurValue in
                baselineValue - blurValue
            },
            verticalDetail: zip(baseline.values, verticalBlur).map { baselineValue, blurValue in
                baselineValue - blurValue
            },
            isotropicDetail: zip(baseline.values, isotropicBlur).map { baselineValue, blurValue in
                baselineValue - blurValue
            }
        )
    }

    static func applyOperator(
        basis: OperatorBasis,
        message: ASHMessage,
        strength: Double
    ) throws -> ASHImage {
        var result = basis.baseline.values
        for index in result.indices {
            if index.isMultiple(of: 4_096) {
                try Task.checkCancellation()
            }
            if message.bits[0] == 1 {
                result[index] += strength * basis.horizontalDetail[index]
            }
            if message.bits[1] == 1 {
                result[index] += strength * basis.verticalDetail[index]
            }
            if message.bits[2] == 1 {
                result[index] += strength * basis.isotropicDetail[index]
            }
            if message.bits[3] == 1 {
                result[index] -= strength * basis.isotropicDetail[index]
            }
            result[index] = min(1.0, max(0.0, result[index]))
        }
        return try basis.baseline.replacing(values: result)
    }

    static func policyAdjustment(
        features: ASHFeatureVector?,
        message: ASHMessage,
        policy: ASHScoringPolicy
    ) -> Double {
        guard policy == .mirmirAdaptiveV1, let features else { return 0.0 }
        let values = features.values
        let signals = [
            values[5],
            values[6],
            max(values[2], values[3], values[4]),
            max(values[0], values[1], values[4], values[7])
        ]
        var score = 0.0
        for index in 0..<ASHMessage.bitCount {
            let signal = signals[index]
            score += message.bits[index] == 1
                ? signal
                : max(0.0, ASHScoringPolicy.adaptiveInactiveFloor - signal)
        }
        return score * ASHScoringPolicy.adaptiveFeaturePriorWeight
    }

    static func isPreferred(
        _ lhs: ASHReconstructionCandidate,
        _ rhs: ASHReconstructionCandidate
    ) -> Bool {
        if lhs.totalScore != rhs.totalScore {
            return lhs.totalScore > rhs.totalScore
        }
        return lhs.message.rawValue < rhs.message.rawValue
    }

    static func blurAxis(_ image: ASHImage, axis: Int) -> [Double] {
        var output = Array(repeating: 0.0, count: image.values.count)

        for row in 0..<image.height {
            for column in 0..<image.width {
                for channel in 0..<image.channels {
                    let previousRow = axis == 0 ? max(row - 1, 0) : row
                    let nextRow = axis == 0 ? min(row + 1, image.height - 1) : row
                    let previousColumn = axis == 1 ? max(column - 1, 0) : column
                    let nextColumn = axis == 1 ? min(column + 1, image.width - 1) : column
                    let center = image.value(row: row, column: column, channel: channel)
                    let before = image.value(row: previousRow, column: previousColumn, channel: channel)
                    let after = image.value(row: nextRow, column: nextColumn, channel: channel)
                    output[index(row: row, column: column, channel: channel, width: image.width, channels: image.channels)] =
                        (before + (2.0 * center) + after) / 4.0
                }
            }
        }

        return output
    }

    static func gradientEnergy(_ image: ASHImage) -> (dx: [Double], dy: [Double]) {
        var dx = Array(repeating: 0.0, count: image.values.count)
        var dy = Array(repeating: 0.0, count: image.values.count)

        if image.width > 1 {
            for row in 0..<image.height {
                for column in 0..<(image.width - 1) {
                    for channel in 0..<image.channels {
                        let current = index(row: row, column: column, channel: channel, width: image.width, channels: image.channels)
                        let next = index(row: row, column: column + 1, channel: channel, width: image.width, channels: image.channels)
                        dx[current] = image.values[next] - image.values[current]
                    }
                }
            }
        }

        if image.height > 1 {
            for row in 0..<(image.height - 1) {
                for column in 0..<image.width {
                    for channel in 0..<image.channels {
                        let current = index(row: row, column: column, channel: channel, width: image.width, channels: image.channels)
                        let next = index(row: row + 1, column: column, channel: channel, width: image.width, channels: image.channels)
                        dy[current] = image.values[next] - image.values[current]
                    }
                }
            }
        }

        return (dx, dy)
    }

    static func mean(_ values: [Double]) -> Double {
        values.reduce(0.0, +) / Double(values.count)
    }

    static func index(row: Int, column: Int, channel: Int, width: Int, channels: Int) -> Int {
        ((row * width) + column) * channels + channel
    }
}
