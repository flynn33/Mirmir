import CoreVideo
import CryptoKit
import Foundation
import Metal

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArgument
    case bufferCreationFailed(CVReturn)
    case parityFailure(String, String, String)
    case outputChanged(String, String, String)
    case powerEnvelopeViolation(String)

    var description: String {
        switch self {
        case .invalidArgument:
            return "usage: pixel-buffer-scaler-hot-path-benchmark <metallib>"
        case let .bufferCreationFailed(status):
            return "CVPixelBufferCreate failed with status \(status)."
        case let .parityFailure(route, cpu, metal):
            return "CPU/Metal parity failed for \(route): \(cpu) != \(metal)."
        case let .outputChanged(route, expected, actual):
            return "Output changed for \(route): \(expected) != \(actual)."
        case let .powerEnvelopeViolation(reason):
            return "Benchmark power envelope is invalid: \(reason)."
        }
    }
}

private struct BenchmarkPowerEnvelope {
    let thermalState: String
    let lowPowerModeEnabled: Bool
    let powerSource: String
}

private struct BenchmarkRoute {
    let id: String
    let storage: PixelStorageV4
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let borderRule: SpatialBorderRuleV4
    let borderRuleName: String
    let inputSeed: Int
    let expectedVisiblePixelSHA256: String
}

private struct BenchmarkResult {
    let route: BenchmarkRoute
    let visiblePixelSHA256: String
    let cpuMilliseconds: [Double]
    let metalMilliseconds: [Double]
}

@main
private enum PixelBufferScalerHotPathBenchmarkMain {
    private static let warmupCount = 5
    private static let sampleCount = 15
    private static let scope = "production FixedPointPixelBufferScalerV4 process plus ordered visible-byte SHA-256"
    private static let timedSetupExcluded = [
        "scaler construction",
        "scale and coefficient preparation",
        "CPU workspace allocation",
        "Metal pipeline and reusable buffer allocation",
        "pixel-buffer allocation and source fill"
    ]
    private static let routes = [
        BenchmarkRoute(
            id: "nv12-full-arbitrary-853x481",
            storage: .nv12FullRange8Bit,
            sourceWidth: 512,
            sourceHeight: 288,
            targetWidth: 853,
            targetHeight: 481,
            borderRule: .reflect101,
            borderRuleName: "reflect101",
            inputSeed: 0,
            expectedVisiblePixelSHA256:
                "2343ba64fa01b4dc50aaf72ab0718ea47d7e3ac399b8efaf375970c4bba7ba93"
        ),
        BenchmarkRoute(
            id: "p010-video-exact-3-over-2",
            storage: .p010VideoRange10Bit,
            sourceWidth: 512,
            sourceHeight: 288,
            targetWidth: 768,
            targetHeight: 432,
            borderRule: .reflect101,
            borderRuleName: "reflect101",
            inputSeed: 0,
            expectedVisiblePixelSHA256:
                "3a04af52933190bd5ce47af8e5ffe69c36d52a7dfc67fe1485ac351eb917e61a"
        )
    ]

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw BenchmarkError.invalidArgument
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FixedPointMetalExecutorV4Error.metalUnavailable
        }
        let startingPowerEnvelope = try powerEnvelope(requiringACPower: true)
        let library = try device.makeLibrary(
            URL: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        var results: [BenchmarkResult] = []
        for route in routes {
            results.append(try await Task.detached(priority: .high) {
                try await run(route: route, device: device, library: library)
            }.value)
        }
        let endingPowerEnvelope = try powerEnvelope(requiringACPower: true)
        let document = makeDocument(
            results: results,
            deviceName: device.name,
            startingPowerEnvelope: startingPowerEnvelope,
            endingPowerEnvelope: endingPowerEnvelope
        )
        let encoded = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func run(
        route: BenchmarkRoute,
        device: MTLDevice,
        library: MTLLibrary
    ) async throws -> BenchmarkResult {
        let source = try makeBuffer(
            storage: route.storage,
            width: route.sourceWidth,
            height: route.sourceHeight
        )
        try fill(
            source,
            storage: route.storage,
            inputSeed: route.inputSeed
        )
        let cpuDestination = try makeBuffer(
            storage: route.storage,
            width: route.targetWidth,
            height: route.targetHeight
        )
        let metalDestination = try makeBuffer(
            storage: route.storage,
            width: route.targetWidth,
            height: route.targetHeight
        )
        let cpu = try FixedPointPixelBufferScalerV4(
            backend: .cpu,
            storage: route.storage,
            sourceWidth: route.sourceWidth,
            sourceHeight: route.sourceHeight,
            targetWidth: route.targetWidth,
            targetHeight: route.targetHeight,
            borderRule: route.borderRule
        )
        let metal = try FixedPointPixelBufferScalerV4(
            backend: .metal,
            storage: route.storage,
            sourceWidth: route.sourceWidth,
            sourceHeight: route.sourceHeight,
            targetWidth: route.targetWidth,
            targetHeight: route.targetHeight,
            borderRule: route.borderRule,
            metalDevice: device,
            metalLibrary: library
        )

        var expectedDigest: SHA256.Digest?
        for _ in 0..<warmupCount {
            try requireNominalThermalAndLowPowerState()
            try await cpu.process(source: source, destination: cpuDestination)
            try await metal.process(source: source, destination: metalDestination)
            let cpuDigest = try visiblePixelDigest(
                cpuDestination,
                storage: route.storage
            )
            let metalDigest = try visiblePixelDigest(
                metalDestination,
                storage: route.storage
            )
            try validate(
                route: route,
                cpu: cpuDigest,
                metal: metalDigest,
                expected: expectedDigest
            )
            try requireNominalThermalAndLowPowerState()
            expectedDigest = cpuDigest
        }

        var cpuSamples: [Double] = []
        var metalSamples: [Double] = []
        cpuSamples.reserveCapacity(sampleCount)
        metalSamples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            try requireNominalThermalAndLowPowerState()
            let cpuStart = DispatchTime.now().uptimeNanoseconds
            try await cpu.process(source: source, destination: cpuDestination)
            let cpuDigest = try visiblePixelDigest(
                cpuDestination,
                storage: route.storage
            )
            let cpuEnd = DispatchTime.now().uptimeNanoseconds
            try requireNominalThermalAndLowPowerState()
            try validate(
                route: route,
                cpu: cpuDigest,
                metal: expectedDigest!,
                expected: expectedDigest
            )
            cpuSamples.append(milliseconds(from: cpuStart, to: cpuEnd))
        }
        for _ in 0..<sampleCount {
            try requireNominalThermalAndLowPowerState()
            let metalStart = DispatchTime.now().uptimeNanoseconds
            try await metal.process(source: source, destination: metalDestination)
            let metalDigest = try visiblePixelDigest(
                metalDestination,
                storage: route.storage
            )
            let metalEnd = DispatchTime.now().uptimeNanoseconds
            try requireNominalThermalAndLowPowerState()
            try validate(
                route: route,
                cpu: expectedDigest!,
                metal: metalDigest,
                expected: expectedDigest
            )
            metalSamples.append(milliseconds(from: metalStart, to: metalEnd))
        }
        return BenchmarkResult(
            route: route,
            visiblePixelSHA256: hexadecimal(expectedDigest!),
            cpuMilliseconds: cpuSamples,
            metalMilliseconds: metalSamples
        )
    }

    private static func validate(
        route: BenchmarkRoute,
        cpu: SHA256.Digest,
        metal: SHA256.Digest,
        expected: SHA256.Digest?
    ) throws {
        guard cpu == metal else {
            throw BenchmarkError.parityFailure(
                route.id,
                hexadecimal(cpu),
                hexadecimal(metal)
            )
        }
        let actualHexadecimal = hexadecimal(cpu)
        guard actualHexadecimal == route.expectedVisiblePixelSHA256 else {
            throw BenchmarkError.outputChanged(
                route.id,
                route.expectedVisiblePixelSHA256,
                actualHexadecimal
            )
        }
        if let expected, cpu != expected {
            throw BenchmarkError.outputChanged(
                route.id,
                hexadecimal(expected),
                actualHexadecimal
            )
        }
    }

    private static func makeBuffer(
        storage: PixelStorageV4,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            storage.pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
                as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw BenchmarkError.bufferCreationFailed(status)
        }
        return buffer
    }

    private static func fill(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4,
        inputSeed: Int
    ) throws {
        let layout = PixelLayoutV4(storage: storage)
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw BenchmarkError.bufferCreationFailed(kCVReturnError)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (planeIndex, plane) in layout.planes.enumerated() {
            let width = try plane.width(forFrameWidth: CVPixelBufferGetWidth(buffer))
            let height = try plane.height(
                forFrameHeight: CVPixelBufferGetHeight(buffer)
            )
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)!
                .assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes)
                for x in 0..<width {
                    for component in 0..<plane.componentsPerElement {
                        let bounds = plane.signalCodeBounds[component]
                        let span = Int(bounds.maximum - bounds.minimum) + 1
                        let signal = bounds.minimum + UInt16(
                            (
                                x * 37
                                    + y * 71
                                    + component * 113
                                    + inputSeed
                            ) % span
                        )
                        let stored = signal << UInt16(plane.storedCodeShift)
                        let index = x * plane.componentsPerElement + component
                        if plane.bytesPerComponent == 1 {
                            row[index] = UInt8(stored)
                        } else {
                            row[index * 2] = UInt8(truncatingIfNeeded: stored)
                            row[index * 2 + 1] = UInt8(
                                truncatingIfNeeded: stored >> 8
                            )
                        }
                    }
                }
            }
        }
    }

    private static func visiblePixelDigest(
        _ buffer: CVPixelBuffer,
        storage: PixelStorageV4
    ) throws -> SHA256.Digest {
        let layout = PixelLayoutV4(storage: storage)
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly)
                == kCVReturnSuccess else {
            throw BenchmarkError.bufferCreationFailed(kCVReturnError)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var hasher = SHA256()
        for (planeIndex, plane) in layout.planes.enumerated() {
            let activeRowBytes = try plane.activeBytesPerRow(
                frameWidth: CVPixelBufferGetWidth(buffer)
            )
            let height = try plane.height(
                forFrameHeight: CVPixelBufferGetHeight(buffer)
            )
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, planeIndex)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, planeIndex)!
                .assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: row,
                    count: activeRowBytes
                ))
            }
        }
        return hasher.finalize()
    }

    private static func makeDocument(
        results: [BenchmarkResult],
        deviceName: String,
        startingPowerEnvelope: BenchmarkPowerEnvelope,
        endingPowerEnvelope: BenchmarkPowerEnvelope
    ) -> [String: Any] {
        let cpu = results.flatMap(\.cpuMilliseconds)
        let metal = results.flatMap(\.metalMilliseconds)
        return [
            "schemaVersion": "mirmir-v4-pixel-buffer-hot-path-benchmark-v4",
            "scope": scope,
            "configuration": [
                "warmupCount": warmupCount,
                "sampleCountPerCase": sampleCount,
                "device": deviceName,
                "powerEnvelope": "nominal thermal state and low-power disabled before and after every iteration; AC power at capture start and end",
                "timedSetupExcluded": timedSetupExcluded
            ],
            "environment": [
                "hardwareModel": requiredEnvironment("MIRMIR_V4_BENCHMARK_HARDWARE_MODEL"),
                "processor": requiredEnvironment("MIRMIR_V4_BENCHMARK_PROCESSOR"),
                "memoryBytes": requiredEnvironment("MIRMIR_V4_BENCHMARK_MEMORY_BYTES"),
                "macOSVersion": requiredEnvironment("MIRMIR_V4_BENCHMARK_MACOS_VERSION"),
                "macOSBuild": requiredEnvironment("MIRMIR_V4_BENCHMARK_MACOS_BUILD"),
                "metalDevice": deviceName,
                "thermalStateAtStart": startingPowerEnvelope.thermalState,
                "thermalStateAtEnd": endingPowerEnvelope.thermalState,
                "lowPowerModeEnabledAtStart": startingPowerEnvelope.lowPowerModeEnabled,
                "lowPowerModeEnabledAtEnd": endingPowerEnvelope.lowPowerModeEnabled,
                "powerSourceAtStart": startingPowerEnvelope.powerSource,
                "powerSourceAtEnd": endingPowerEnvelope.powerSource
            ],
            "compiler": [
                "xcodeVersion": requiredEnvironment("MIRMIR_V4_BENCHMARK_XCODE_VERSION"),
                "swiftVersion": requiredEnvironment("MIRMIR_V4_BENCHMARK_SWIFT_VERSION"),
                "swiftFlags": "-O -whole-module-optimization -warnings-as-errors -strict-concurrency=complete",
                "metalFlags": "-O3 -mmacosx-version-min=15.4 -std=metal3.2"
            ],
            "identities": [
                "benchmarkSourceSHA256": requiredEnvironment("MIRMIR_V4_BENCHMARK_HARNESS_SHA256"),
                "runnerSourceSHA256": requiredEnvironment("MIRMIR_V4_BENCHMARK_RUNNER_SHA256"),
                "engineSourceSHA256": requiredEnvironment("MIRMIR_V4_BENCHMARK_ENGINE_SOURCE_SHA256"),
                "engineSourceManifest": requiredEnvironment("MIRMIR_V4_BENCHMARK_ENGINE_SOURCE_MANIFEST"),
                "executableSHA256": requiredEnvironment("MIRMIR_V4_BENCHMARK_EXECUTABLE_SHA256"),
                "metalLibrarySHA256": requiredEnvironment("MIRMIR_V4_BENCHMARK_METALLIB_SHA256")
            ],
            "cases": results.map { result in
                [
                    "id": result.route.id,
                    "storage": result.route.storage.rawValue,
                    "sourceWidth": result.route.sourceWidth,
                    "sourceHeight": result.route.sourceHeight,
                    "targetWidth": result.route.targetWidth,
                    "targetHeight": result.route.targetHeight,
                    "borderRule": result.route.borderRuleName,
                    "inputSeed": result.route.inputSeed,
                    "warmupCount": warmupCount,
                    "sampleCount": sampleCount,
                    "visiblePixelSHA256": result.visiblePixelSHA256,
                    "cpuMetalByteParity": true,
                    "cpuMilliseconds": result.cpuMilliseconds,
                    "cpuMedianMilliseconds": percentile(
                        result.cpuMilliseconds,
                        0.5
                    ),
                    "cpuP95Milliseconds": percentile(
                        result.cpuMilliseconds,
                        0.95
                    ),
                    "metalMilliseconds": result.metalMilliseconds,
                    "metalMedianMilliseconds": percentile(
                        result.metalMilliseconds,
                        0.5
                    ),
                    "metalP95Milliseconds": percentile(
                        result.metalMilliseconds,
                        0.95
                    )
                ] as [String: Any]
            },
            "aggregate": [
                "cpuMedianMilliseconds": percentile(cpu, 0.5),
                "cpuP95Milliseconds": percentile(cpu, 0.95),
                "metalMedianMilliseconds": percentile(metal, 0.5),
                "metalP95Milliseconds": percentile(metal, 0.95)
            ]
        ]
    }

    private static func percentile(_ values: [Double], _ fraction: Double)
        -> Double {
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func milliseconds(from start: UInt64, to end: UInt64)
        -> Double {
        Double(end - start) / 1_000_000
    }

    private static func hexadecimal<Digest: Sequence>(_ digest: Digest)
        -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func requiredEnvironment(_ name: String) -> String {
        guard let value = ProcessInfo.processInfo.environment[name],
              !value.isEmpty else {
            fatalError("missing required benchmark environment: \(name)")
        }
        return value
    }

    private static func requireNominalThermalAndLowPowerState() throws {
        let processInfo = ProcessInfo.processInfo
        let thermalState = name(for: processInfo.thermalState)
        guard processInfo.thermalState == .nominal else {
            throw BenchmarkError.powerEnvelopeViolation(
                "thermal state is \(thermalState), expected nominal"
            )
        }
        guard !processInfo.isLowPowerModeEnabled else {
            throw BenchmarkError.powerEnvelopeViolation(
                "low-power mode is enabled"
            )
        }
    }

    private static func powerEnvelope(
        requiringACPower: Bool
    ) throws -> BenchmarkPowerEnvelope {
        try requireNominalThermalAndLowPowerState()
        let powerSource = try currentPowerSource()
        if requiringACPower, powerSource != "AC Power" {
            throw BenchmarkError.powerEnvelopeViolation(
                "power source is \(powerSource), expected AC Power"
            )
        }
        let processInfo = ProcessInfo.processInfo
        return BenchmarkPowerEnvelope(
            thermalState: name(for: processInfo.thermalState),
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            powerSource: powerSource
        )
    }

    private static func currentPowerSource() throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let firstQuote = text.firstIndex(of: "'"),
              let secondQuote = text[text.index(after: firstQuote)...]
                .firstIndex(of: "'") else {
            throw BenchmarkError.powerEnvelopeViolation(
                "unable to read the current power source"
            )
        }
        return String(text[text.index(after: firstQuote)..<secondQuote])
    }

    private static func name(
        for thermalState: ProcessInfo.ThermalState
    ) -> String {
        switch thermalState {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}
