import Foundation

enum LanczosCPUReferenceError: Error, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case invalidChannelCount(Int)
    case invalidByteCount(expected: Int, actual: Int)
}

struct LanczosReferencePlane: Equatable {
    let width: Int
    let height: Int
    let channels: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, channels: Int, bytes: [UInt8]) throws {
        guard width > 0, height > 0 else {
            throw LanczosCPUReferenceError.invalidDimensions(width: width, height: height)
        }
        guard channels > 0 else {
            throw LanczosCPUReferenceError.invalidChannelCount(channels)
        }
        let expectedByteCount = width * height * channels
        guard bytes.count == expectedByteCount else {
            throw LanczosCPUReferenceError.invalidByteCount(
                expected: expectedByteCount,
                actual: bytes.count
            )
        }
        self.width = width
        self.height = height
        self.channels = channels
        self.bytes = bytes
    }
}

enum LanczosCPUReference {
    private static let radius = 3.0

    static func scale(
        _ source: LanczosReferencePlane,
        destinationWidth: Int,
        destinationHeight: Int
    ) throws -> LanczosReferencePlane {
        guard destinationWidth > 0, destinationHeight > 0 else {
            throw LanczosCPUReferenceError.invalidDimensions(
                width: destinationWidth,
                height: destinationHeight
            )
        }
        let horizontalContributions = contributions(
            sourceCount: source.width,
            destinationCount: destinationWidth
        )
        var horizontal = Array(
            repeating: 0.0,
            count: destinationWidth * source.height * source.channels
        )
        for row in 0..<source.height {
            for destinationColumn in 0..<destinationWidth {
                let contribution = horizontalContributions[destinationColumn]
                for channel in 0..<source.channels {
                    var value = 0.0
                    for tap in contribution {
                        let sourceIndex = (
                            (row * source.width + tap.sourceIndex) * source.channels
                        ) + channel
                        value += Double(source.bytes[sourceIndex]) * tap.weight
                    }
                    let destinationIndex = (
                        (row * destinationWidth + destinationColumn) * source.channels
                    ) + channel
                    horizontal[destinationIndex] = value
                }
            }
        }

        let verticalContributions = contributions(
            sourceCount: source.height,
            destinationCount: destinationHeight
        )
        var destination = Array(
            repeating: UInt8(0),
            count: destinationWidth * destinationHeight * source.channels
        )
        for destinationRow in 0..<destinationHeight {
            let contribution = verticalContributions[destinationRow]
            for column in 0..<destinationWidth {
                for channel in 0..<source.channels {
                    var value = 0.0
                    for tap in contribution {
                        let sourceIndex = (
                            (tap.sourceIndex * destinationWidth + column) * source.channels
                        ) + channel
                        value += horizontal[sourceIndex] * tap.weight
                    }
                    let destinationIndex = (
                        (destinationRow * destinationWidth + column) * source.channels
                    ) + channel
                    destination[destinationIndex] = quantize(value)
                }
            }
        }
        return try LanczosReferencePlane(
            width: destinationWidth,
            height: destinationHeight,
            channels: source.channels,
            bytes: destination
        )
    }

    private static func contributions(
        sourceCount: Int,
        destinationCount: Int
    ) -> [[LanczosContribution]] {
        let scale = Double(destinationCount) / Double(sourceCount)
        let filterScale = min(scale, 1.0)
        let support = radius / filterScale
        return (0..<destinationCount).map { destinationIndex in
            let sourceCoordinate = (Double(destinationIndex) + 0.5) / scale - 0.5
            let firstSourceIndex = Int(floor(sourceCoordinate - support))
            let lastSourceIndex = Int(ceil(sourceCoordinate + support))
            var weightsBySourceIndex: [Int: Double] = [:]
            var weightSum = 0.0
            for unboundedSourceIndex in firstSourceIndex...lastSourceIndex {
                let distance = (
                    sourceCoordinate - Double(unboundedSourceIndex)
                ) * filterScale
                let weight = lanczos3(distance) * filterScale
                guard weight != 0 else { continue }
                let sourceIndex = min(max(unboundedSourceIndex, 0), sourceCount - 1)
                weightsBySourceIndex[sourceIndex, default: 0] += weight
                weightSum += weight
            }
            return weightsBySourceIndex
                .map { sourceIndex, weight in
                    LanczosContribution(
                        sourceIndex: sourceIndex,
                        weight: weight / weightSum
                    )
                }
                .sorted { $0.sourceIndex < $1.sourceIndex }
        }
    }

    private static func lanczos3(_ value: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude < radius else { return 0 }
        guard magnitude > Double.ulpOfOne else { return 1 }
        return sinc(value) * sinc(value / radius)
    }

    private static func sinc(_ value: Double) -> Double {
        let argument = Double.pi * value
        return sin(argument) / argument
    }

    private static func quantize(_ value: Double) -> UInt8 {
        UInt8(min(255.0, max(0.0, value.rounded())))
    }
}

private struct LanczosContribution {
    let sourceIndex: Int
    let weight: Double
}

struct LanczosNV12Fixture {
    let id: String
    let width: Int
    let height: Int
    let luma: [UInt8]
    let chroma: [UInt8]

    var chromaWidth: Int { width / 2 }
    var chromaHeight: Int { height / 2 }
}

enum LanczosDeterministicFixtures {
    static let sourceWidth = 64
    static let sourceHeight = 32
    static let destinationWidth = 48
    static let destinationHeight = 24
    static let randomSeed: UInt64 = 20_260_710

    static func all() -> [LanczosNV12Fixture] {
        [
            constant(id: "constant_legal_low", luma: 16, cb: 16, cr: 16),
            constant(id: "constant_legal_high", luma: 235, cb: 240, cr: 240),
            horizontalRamp(),
            verticalRamp(),
            centerImpulse(),
            borderImpulses(),
            legalEndpointStep(),
            chromaEdge(id: "cb_only_edge", changesCb: true),
            chromaEdge(id: "cr_only_edge", changesCb: false),
            fixedSeedRandom()
        ]
    }

    private static func constant(
        id: String,
        luma: UInt8,
        cb: UInt8,
        cr: UInt8
    ) -> LanczosNV12Fixture {
        makeFixture(id: id, luma: { _, _ in luma }, chroma: { _, _ in (cb, cr) })
    }

    private static func horizontalRamp() -> LanczosNV12Fixture {
        let lumaSpan = 235 - 16
        let chromaSpan = 240 - 16
        return makeFixture(id: "horizontal_ramp", luma: { _, column in
            let codeValue = 16 + (column * lumaSpan) / (sourceWidth - 1)
            return UInt8(codeValue)
        }, chroma: { _, column in
            let codeValue = 16 + (column * chromaSpan) / ((sourceWidth / 2) - 1)
            let value = UInt8(codeValue)
            return (value, UInt8(256 - Int(value)))
        })
    }

    private static func verticalRamp() -> LanczosNV12Fixture {
        let lumaSpan = 235 - 16
        let chromaSpan = 240 - 16
        return makeFixture(id: "vertical_ramp", luma: { row, _ in
            let codeValue = 16 + (row * lumaSpan) / (sourceHeight - 1)
            return UInt8(codeValue)
        }, chroma: { row, _ in
            let codeValue = 16 + (row * chromaSpan) / ((sourceHeight / 2) - 1)
            let value = UInt8(codeValue)
            return (value, UInt8(256 - Int(value)))
        })
    }

    private static func centerImpulse() -> LanczosNV12Fixture {
        makeFixture(id: "center_impulse", luma: { row, column in
            row == sourceHeight / 2 && column == sourceWidth / 2 ? 235 : 16
        }, chroma: { row, column in
            row == sourceHeight / 4 && column == sourceWidth / 4
                ? (240, 16)
                : (128, 128)
        })
    }

    private static func borderImpulses() -> LanczosNV12Fixture {
        makeFixture(id: "border_impulses", luma: { row, column in
            let borderRow = row == 0 || row == sourceHeight - 1
            let borderColumn = column == 0 || column == sourceWidth - 1
            return borderRow && borderColumn ? 235 : 16
        }, chroma: { row, column in
            let borderRow = row == 0 || row == (sourceHeight / 2) - 1
            let borderColumn = column == 0 || column == (sourceWidth / 2) - 1
            return borderRow && borderColumn ? (240, 16) : (128, 128)
        })
    }

    private static func legalEndpointStep() -> LanczosNV12Fixture {
        makeFixture(id: "legal_endpoint_step", luma: { _, column in
            column < sourceWidth / 2 ? 16 : 235
        }, chroma: { _, column in
            column < sourceWidth / 4 ? (16, 240) : (240, 16)
        })
    }

    private static func chromaEdge(id: String, changesCb: Bool) -> LanczosNV12Fixture {
        makeFixture(id: id, luma: { _, _ in 128 }, chroma: { _, column in
            let lowSide = column < sourceWidth / 4
            if changesCb {
                return (lowSide ? 16 : 240, 128)
            }
            return (128, lowSide ? 16 : 240)
        })
    }

    private static func fixedSeedRandom() -> LanczosNV12Fixture {
        let generator = LanczosLinearCongruentialGenerator(state: randomSeed)
        return makeFixture(id: "fixed_seed_random", luma: { _, _ in
            UInt8(16 + generator.next() % UInt64(235 - 16 + 1))
        }, chroma: { _, _ in
            let cb = UInt8(16 + generator.next() % UInt64(240 - 16 + 1))
            let cr = UInt8(16 + generator.next() % UInt64(240 - 16 + 1))
            return (cb, cr)
        })
    }

    private static func makeFixture(
        id: String,
        luma: (Int, Int) -> UInt8,
        chroma: (Int, Int) -> (UInt8, UInt8)
    ) -> LanczosNV12Fixture {
        var lumaBytes: [UInt8] = []
        lumaBytes.reserveCapacity(sourceWidth * sourceHeight)
        for row in 0..<sourceHeight {
            for column in 0..<sourceWidth {
                lumaBytes.append(luma(row, column))
            }
        }
        var chromaBytes: [UInt8] = []
        chromaBytes.reserveCapacity(sourceWidth * sourceHeight / 2)
        for row in 0..<(sourceHeight / 2) {
            for column in 0..<(sourceWidth / 2) {
                let pair = chroma(row, column)
                chromaBytes.append(pair.0)
                chromaBytes.append(pair.1)
            }
        }
        return LanczosNV12Fixture(
            id: id,
            width: sourceWidth,
            height: sourceHeight,
            luma: lumaBytes,
            chroma: chromaBytes
        )
    }
}

private final class LanczosLinearCongruentialGenerator {
    var state: UInt64

    init(state: UInt64) {
        self.state = state
    }

    func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 32
    }
}
