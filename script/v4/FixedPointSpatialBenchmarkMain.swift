import Foundation
import Metal

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidSourceSize(Int)
    case parityFailure(route: String, cpu: UInt64, metal: UInt64)
    case outputChanged(route: String, expected: UInt64, actual: UInt64)

    var description: String {
        switch self {
        case let .invalidArgument(message):
            return message
        case let .invalidSourceSize(actual):
            return "Expected a 288-byte locked NV12 source; found \(actual) bytes."
        case let .parityFailure(route, cpu, metal):
            return "CPU/Metal checksum mismatch for \(route): \(cpu) != \(metal)."
        case let .outputChanged(route, expected, actual):
            return "Output checksum changed for \(route): expected \(expected), found \(actual)."
        }
    }
}

private final class PreparedPlane {
    let source: [UInt16]
    let sourceRowStride: Int
    let preparedScale: FixedPointPreparedScaleV4
    let minimumCode: UInt16
    let maximumCode: UInt16
    let preparedMetal: FixedPointMetalPreparedExecutionV4

    private(set) var workspace = FixedPointCPUWorkspaceV4()
    private var cpuOutput: [UInt16]

    init(
        source: [UInt16],
        sourceRowStride: Int,
        plan: SpatialScalePlanV4,
        minimumCode: UInt16,
        maximumCode: UInt16,
        metal: FixedPointMetalExecutorV4
    ) throws {
        let kernelIR = try FixedPointKernelIRV4(scalePlan: plan)
        let preparedScale = try FixedPointPreparedScaleV4(
            scalePlan: plan,
            kernelIR: kernelIR
        )
        self.source = source
        self.sourceRowStride = sourceRowStride
        self.preparedScale = preparedScale
        self.minimumCode = minimumCode
        self.maximumCode = maximumCode
        self.preparedMetal = try metal.prepare(
            sourceRowStride: sourceRowStride,
            scalePlan: plan,
            kernelIR: kernelIR,
            minimumCode: minimumCode,
            maximumCode: maximumCode
        )
        self.cpuOutput = Array(
            repeating: 0,
            count: preparedScale.outputSampleCount
        )
    }

    var reusableHorizontalSampleCount: Int {
        workspace.reusableHorizontalSampleCount
    }

    func executeCPU() throws -> UInt64 {
        try source.withUnsafeBufferPointer { sourceBuffer in
            try cpuOutput.withUnsafeMutableBufferPointer { destination in
                try FixedPointCPUExecutorV4.execute(
                    source: sourceBuffer,
                    sourceRowStride: sourceRowStride,
                    preparedScale: preparedScale,
                    minimumCode: minimumCode,
                    maximumCode: maximumCode,
                    destination: destination,
                    workspace: &workspace
                )
            }
        }
        return checksum(cpuOutput)
    }

    private func checksum(_ values: [UInt16]) -> UInt64 {
        values.reduce(UInt64(0)) { partial, value in
            partial &+ UInt64(value)
        }
    }
}

private final class PreparedRoute {
    let id: String
    let expectedChecksum: UInt64
    let planes: [PreparedPlane]
    let preparedMetalBatch: FixedPointMetalPreparedBatchV4

    private let metalSources: [[UInt16]]
    private var metalDestinations: [[UInt16]]

    init(
        id: String,
        expectedChecksum: UInt64,
        planes: [PreparedPlane]
    ) throws {
        self.id = id
        self.expectedChecksum = expectedChecksum
        self.planes = planes
        self.preparedMetalBatch = try FixedPointMetalPreparedBatchV4(
            executions: planes.map(\.preparedMetal)
        )
        self.metalSources = planes.map(\.source)
        self.metalDestinations = planes.map {
            Array(repeating: 0, count: $0.preparedScale.outputSampleCount)
        }
    }

    func executeCPU() throws -> UInt64 {
        try planes.reduce(UInt64(0)) { partial, plane in
            partial &+ (try plane.executeCPU())
        }
    }

    func executeMetal() throws -> UInt64 {
        try preparedMetalBatch.execute(
            sources: metalSources,
            destinations: &metalDestinations
        )
        return metalDestinations.reduce(UInt64(0)) { partial, output in
            partial &+ output.reduce(UInt64(0)) {
                $0 &+ UInt64($1)
            }
        }
    }
}

private struct RouteResult {
    let id: String
    let expectedChecksum: UInt64
    let outputChecksum: UInt64
    let cpuMilliseconds: [Double]
    let metalMilliseconds: [Double]
    let reusableCPUHorizontalSamples: Int
    let reusableMetalBuffers: Int
}

@main
private enum FixedPointSpatialBenchmarkMain {
    private static let warmupCount = 5
    private static let sampleCount = 10
    private static let lockedSourceSHA256 =
        "87dc513caa392105a02425704e15b9fbd0fa81f92c1a552daa37550822225024"

    // Captured from commit bd2db59 immediately before the M2 hot-path edit.
    private static let committedBeforeCPU = (median: 0.029958, p95: 0.0385048)
    private static let committedBeforeMetal = (median: 0.62025, p95: 1.3072274)

    // Locked P05 whole-engine spatial baseline retained only as a cross-scope
    // budget reference. The same-scope committed-before numbers above are the
    // valid performance comparison for this isolated fixed-point slice.
    private static let lockedP05CPU = (median: 8.3390625, p95: 12.66410205)
    private static let lockedP05Metal = (median: 2.0679795, p95: 6.76918605)

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw BenchmarkError.invalidArgument(
                "usage: fixed-point-spatial-benchmark <metallib> <locked-source>"
            )
        }
        let libraryURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FixedPointMetalExecutorV4Error.metalUnavailable
        }
        let library = try device.makeLibrary(URL: libraryURL)
        let metal = try FixedPointMetalExecutorV4(
            device: device,
            library: library
        )
        let sourceBytes = [UInt8](try Data(contentsOf: sourceURL))
        guard sourceBytes.count == 288 else {
            throw BenchmarkError.invalidSourceSize(sourceBytes.count)
        }

        var results: [RouteResult] = []
        for format in ["420f", "420v"] {
            for route in ["direct_2x", "direct_3_over_2"] {
                let id = "\(format)-\(route)-radial_detail"
                let dimensions = route == "direct_2x" ? (32, 24) : (24, 18)
                let expectedChecksum = expectedChecksum(for: id)
                let prepared = try makeRoute(
                    id: id,
                    source: sourceBytes,
                    targetWidth: dimensions.0,
                    targetHeight: dimensions.1,
                    videoRange: format == "420v",
                    expectedChecksum: expectedChecksum,
                    metal: metal
                )

                for _ in 0..<warmupCount {
                    let cpu = try prepared.executeCPU()
                    let gpu = try prepared.executeMetal()
                    try validate(
                        route: id,
                        cpu: cpu,
                        metal: gpu,
                        expected: expectedChecksum
                    )
                }

                var cpuSamples: [Double] = []
                var metalSamples: [Double] = []
                cpuSamples.reserveCapacity(sampleCount)
                metalSamples.reserveCapacity(sampleCount)
                var finalChecksum = UInt64(0)
                for _ in 0..<sampleCount {
                    let cpuStart = DispatchTime.now().uptimeNanoseconds
                    let cpuChecksum = try prepared.executeCPU()
                    let cpuEnd = DispatchTime.now().uptimeNanoseconds

                    let metalStart = DispatchTime.now().uptimeNanoseconds
                    let metalChecksum = try prepared.executeMetal()
                    let metalEnd = DispatchTime.now().uptimeNanoseconds

                    try validate(
                        route: id,
                        cpu: cpuChecksum,
                        metal: metalChecksum,
                        expected: expectedChecksum
                    )
                    finalChecksum = cpuChecksum
                    cpuSamples.append(milliseconds(from: cpuStart, to: cpuEnd))
                    metalSamples.append(milliseconds(from: metalStart, to: metalEnd))
                }
                results.append(RouteResult(
                    id: id,
                    expectedChecksum: expectedChecksum,
                    outputChecksum: finalChecksum,
                    cpuMilliseconds: cpuSamples,
                    metalMilliseconds: metalSamples,
                    reusableCPUHorizontalSamples: prepared.planes.reduce(0) {
                        $0 + $1.reusableHorizontalSampleCount
                    },
                    reusableMetalBuffers: prepared.preparedMetalBatch
                        .reusableBufferCount
                ))
            }
        }

        let document = makeDocument(results: results, deviceName: device.name)
        let json = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func makeRoute(
        id: String,
        source: [UInt8],
        targetWidth: Int,
        targetHeight: Int,
        videoRange: Bool,
        expectedChecksum: UInt64,
        metal: FixedPointMetalExecutorV4
    ) throws -> PreparedRoute {
        let luma = source[0..<(16 * 12)].map(UInt16.init)
        let chroma = Array(source[(16 * 12)...])
        var u: [UInt16] = []
        var v: [UInt16] = []
        u.reserveCapacity(8 * 6)
        v.reserveCapacity(8 * 6)
        for index in stride(from: 0, to: chroma.count, by: 2) {
            u.append(UInt16(chroma[index]))
            v.append(UInt16(chroma[index + 1]))
        }
        let lumaPlan = try SpatialScalePlanV4(
            sourceWidth: 16,
            sourceHeight: 12,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        let chromaPlan = try SpatialScalePlanV4(
            sourceWidth: 8,
            sourceHeight: 6,
            targetWidth: (targetWidth + 1) / 2,
            targetHeight: (targetHeight + 1) / 2
        )
        let lumaMaximum: UInt16 = videoRange ? 235 : 255
        let chromaMaximum: UInt16 = videoRange ? 240 : 255
        let minimum: UInt16 = videoRange ? 16 : 0
        return try PreparedRoute(
            id: id,
            expectedChecksum: expectedChecksum,
            planes: [
                PreparedPlane(
                    source: luma,
                    sourceRowStride: 16,
                    plan: lumaPlan,
                    minimumCode: minimum,
                    maximumCode: lumaMaximum,
                    metal: metal
                ),
                PreparedPlane(
                    source: u,
                    sourceRowStride: 8,
                    plan: chromaPlan,
                    minimumCode: minimum,
                    maximumCode: chromaMaximum,
                    metal: metal
                ),
                PreparedPlane(
                    source: v,
                    sourceRowStride: 8,
                    plan: chromaPlan,
                    minimumCode: minimum,
                    maximumCode: chromaMaximum,
                    metal: metal
                )
            ]
        )
    }

    private static func validate(
        route: String,
        cpu: UInt64,
        metal: UInt64,
        expected: UInt64
    ) throws {
        guard cpu == metal else {
            throw BenchmarkError.parityFailure(
                route: route,
                cpu: cpu,
                metal: metal
            )
        }
        guard cpu == expected else {
            throw BenchmarkError.outputChanged(
                route: route,
                expected: expected,
                actual: cpu
            )
        }
    }

    private static func expectedChecksum(for id: String) -> UInt64 {
        switch id {
        case "420f-direct_2x-radial_detail": 153_143
        case "420f-direct_3_over_2-radial_detail": 86_154
        case "420v-direct_2x-radial_detail": 153_145
        case "420v-direct_3_over_2-radial_detail": 86_175
        default: preconditionFailure("Unrecognized locked benchmark route.")
        }
    }

    private static func makeDocument(
        results: [RouteResult],
        deviceName: String
    ) -> [String: Any] {
        let allCPU = results.flatMap(\.cpuMilliseconds)
        let allMetal = results.flatMap(\.metalMilliseconds)
        let afterCPU = (median: percentile(allCPU, 0.5), p95: percentile(allCPU, 0.95))
        let afterMetal = (
            median: percentile(allMetal, 0.5),
            p95: percentile(allMetal, 0.95)
        )
        return [
            "schemaVersion": "mirmir-v4-fixed-point-spatial-benchmark-v1",
            "scope": "prepared fixed-point spatial kernel only; luma plus deinterleaved chroma",
            "configuration": [
                "warmupCount": warmupCount,
                "sampleCountPerCase": sampleCount,
                "sourceByteCount": 288,
                "sourceSHA256": lockedSourceSHA256,
                "device": deviceName,
                "compilerConfiguration": "swiftc -O -whole-module-optimization -warnings-as-errors -strict-concurrency=complete",
                "timedSetupExcluded": [
                    "scale-plan construction",
                    "fixed-point IR construction and validation",
                    "border-index and coefficient preparation",
                    "CPU workspace allocation",
                    "Metal pipeline, reusable buffer allocation, and immutable plan upload"
                ]
            ],
            "baseline": [
                "committedFixedKernel": [
                    "commit": "bd2db59",
                    "cpuMedianMilliseconds": committedBeforeCPU.median,
                    "cpuP95Milliseconds": committedBeforeCPU.p95,
                    "metalMedianMilliseconds": committedBeforeMetal.median,
                    "metalP95Milliseconds": committedBeforeMetal.p95
                ],
                "lockedP05WholeEngineReference": [
                    "comparisonScope": "non-comparable cross-scope reference",
                    "cpuMedianMilliseconds": lockedP05CPU.median,
                    "cpuP95Milliseconds": lockedP05CPU.p95,
                    "metalMedianMilliseconds": lockedP05Metal.median,
                    "metalP95Milliseconds": lockedP05Metal.p95
                ]
            ],
            "cases": results.map { result in
                [
                    "id": result.id,
                    "warmupCount": warmupCount,
                    "sampleCount": sampleCount,
                    "expectedChecksum": result.expectedChecksum,
                    "outputChecksum": result.outputChecksum,
                    "cpuMetalByteParity": true,
                    "cpuMilliseconds": result.cpuMilliseconds,
                    "cpuMedianMilliseconds": percentile(result.cpuMilliseconds, 0.5),
                    "cpuP95Milliseconds": percentile(result.cpuMilliseconds, 0.95),
                    "metalMilliseconds": result.metalMilliseconds,
                    "metalMedianMilliseconds": percentile(result.metalMilliseconds, 0.5),
                    "metalP95Milliseconds": percentile(result.metalMilliseconds, 0.95),
                    "reusableCPUHorizontalSamples": result.reusableCPUHorizontalSamples,
                    "reusableMetalBuffers": result.reusableMetalBuffers
                ] as [String: Any]
            },
            "aggregate": [
                "cpuMedianMilliseconds": afterCPU.median,
                "cpuP95Milliseconds": afterCPU.p95,
                "metalMedianMilliseconds": afterMetal.median,
                "metalP95Milliseconds": afterMetal.p95,
                "ratiosVersusCommittedFixedKernel": ratios(
                    afterCPU: afterCPU,
                    afterMetal: afterMetal,
                    beforeCPU: committedBeforeCPU,
                    beforeMetal: committedBeforeMetal
                ),
                "nonComparableRatiosVersusLockedP05WholeEngineReference": ratios(
                    afterCPU: afterCPU,
                    afterMetal: afterMetal,
                    beforeCPU: lockedP05CPU,
                    beforeMetal: lockedP05Metal
                ),
                "allCPUAndMetalChecksumsMatch": true,
                "allChecksumsMatchCommittedBefore": true
            ]
        ]
    }

    private static func ratios(
        afterCPU: (median: Double, p95: Double),
        afterMetal: (median: Double, p95: Double),
        beforeCPU: (median: Double, p95: Double),
        beforeMetal: (median: Double, p95: Double)
    ) -> [String: Double] {
        [
            "cpuMedian": afterCPU.median / beforeCPU.median,
            "cpuP95": afterCPU.p95 / beforeCPU.p95,
            "metalMedian": afterMetal.median / beforeMetal.median,
            "metalP95": afterMetal.p95 / beforeMetal.p95
        ]
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        precondition(!values.isEmpty)
        let ordered = values.sorted()
        let position = Double(ordered.count - 1) * quantile
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        let fraction = position - Double(lower)
        return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction
    }
}
