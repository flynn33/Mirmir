import Foundation

enum ASHNormalizedChannel: Equatable, Sendable {
    case luma
    case chroma
}

enum ASHCodePlaneNormalizerV2 {
    static func normalizedPlane(
        _ plane: ASHVideoAnalyzerV2CodePlane,
        channel: ASHNormalizedChannel
    ) throws -> ASHSpatialPlaneV2 {
        var samples: [Double] = []
        samples.reserveCapacity(plane.width * plane.height)
        for row in 0..<plane.height {
            let rowOffset = row * plane.bytesPerRow
            for column in 0..<plane.width {
                let code = plane.codes[rowOffset + column]
                let normalized: Double
                switch channel {
                case .luma:
                    normalized = plane.range.normalizeLuma(code)
                case .chroma:
                    normalized = plane.range.normalizeChroma(code) + 0.5
                }
                samples.append(min(1.0, max(0.0, normalized)))
            }
        }
        return try ASHSpatialPlaneV2(
            width: plane.width,
            height: plane.height,
            samples: samples,
            legalRange: 0.0...1.0
        )
    }
}
