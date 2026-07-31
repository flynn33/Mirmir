// Standalone Release benchmark for R13FullFrameEnhancementProcessor.
//
// Build from the repository root:
// xcrun swiftc -O -whole-module-optimization \
//   Mirmir/Modules/UpscalerEngine/R13FullFrameEnhancementProcessor.swift \
//   MirmirTests/PerformanceTools/R13FullFrameEnhancementBenchmark.swift \
//   -framework CoreVideo -o /tmp/mirmir-r13-enhancement-benchmark
//
// Run one case in a fresh process:
// /tmp/mirmir-r13-enhancement-benchmark baseline_1920x1080

import CoreVideo
import Darwin
import Foundation

// These two definitions make the tool a self-contained compilation companion
// for the production processor. The file is intentionally not a test-target
// source, where the production module supplies the same types.
struct VideoResolution: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum MirmirAdjustmentLevel: Sendable {
    case low
    case medium
    case high
}

@main
enum R13FullFrameEnhancementBenchmark {
    enum Scenario: String {
        case baselineSpatial = "baseline_spatial"
        case allEffects = "all_effects"
        case temporalSteadyState = "temporal_steady_state"
    }

    enum BenchmarkCase: String {
        case baseline1080 = "baseline_1920x1080"
        case effects1080 = "all_effects_1920x1080"
        case temporal1080 = "temporal_1920x1080"
        case baseline2160 = "baseline_3840x2160"
        case effects2160 = "all_effects_3840x2160"
        case temporal2160 = "temporal_3840x2160"

        var resolution: VideoResolution {
            switch self {
            case .baseline1080, .effects1080, .temporal1080:
                return VideoResolution(width: 1_920, height: 1_080)
            case .baseline2160, .effects2160, .temporal2160:
                return VideoResolution(width: 3_840, height: 2_160)
            }
        }

        var scenario: Scenario {
            switch self {
            case .baseline1080, .baseline2160:
                return .baselineSpatial
            case .effects1080, .effects2160:
                return .allEffects
            case .temporal1080, .temporal2160:
                return .temporalSteadyState
            }
        }
    }

    struct MemorySample {
        let residentBytes: UInt64
        let peakResidentBytes: UInt64
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let benchmarkCase = BenchmarkCase(
                  rawValue: CommandLine.arguments[1]
              ) else {
            let cases = BenchmarkCase.allRawValues.joined(separator: "\n  ")
            FileHandle.standardError.write(
                Data(
                    "Usage: benchmark <case>\n  \(cases)\n".utf8
                )
            )
            Foundation.exit(EXIT_FAILURE)
        }
        let report = try run(benchmarkCase)
        let data = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func run(_ benchmarkCase: BenchmarkCase) throws
        -> [String: Any] {
        let warmupIterations = 2
        let measuredIterations = 5
        let initialMemory = try memorySample()
        let resolution = benchmarkCase.resolution
        let inputs = [
            try makeBuffer(resolution: resolution, offset: 0),
            try makeBuffer(resolution: resolution, offset: 2)
        ]
        let processor = try makeProcessor(
            resolution: resolution,
            scenario: benchmarkCase.scenario
        )
        var checksum: UInt64 = 0
        var lastOutput: CVPixelBuffer?

        for iteration in 0..<warmupIterations {
            let output = try processor.process(
                inputs[iteration % inputs.count]
            )
            checksum &+= sampledChecksum(output)
            lastOutput = output
        }
        let warmedMemory = try memorySample()
        var frameMilliseconds: [Double] = []
        var maximumObservedResidentBytes =
            warmedMemory.residentBytes
        for iteration in 0..<measuredIterations {
            let started = DispatchTime.now().uptimeNanoseconds
            let output = try processor.process(
                inputs[(iteration + warmupIterations) % inputs.count]
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            frameMilliseconds.append(Double(elapsed) / 1_000_000)
            checksum &+= sampledChecksum(output)
            lastOutput = output
            maximumObservedResidentBytes = max(
                maximumObservedResidentBytes,
                try memorySample().residentBytes
            )
        }
        _ = lastOutput
        let finalMemory = try memorySample()
        try processor.finish()

        let sorted = frameMilliseconds.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = max(
            0,
            Int(ceil(Double(sorted.count) * 0.95)) - 1
        )
        let mean =
            frameMilliseconds.reduce(0, +)
            / Double(frameMilliseconds.count)
        return [
            "case": benchmarkCase.rawValue,
            "scenario": benchmarkCase.scenario.rawValue,
            "operating_system":
                ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "hardware_model": sysctlString("hw.model"),
            "cpu_brand": sysctlString("machdep.cpu.brand_string"),
            "active_processor_count":
                ProcessInfo.processInfo.activeProcessorCount,
            "physical_memory_bytes":
                ProcessInfo.processInfo.physicalMemory,
            "width": resolution.width,
            "height": resolution.height,
            "warmup_iterations": warmupIterations,
            "measured_iterations": measuredIterations,
            "frame_milliseconds": frameMilliseconds,
            "mean_milliseconds": mean,
            "median_milliseconds": median,
            "p95_milliseconds": sorted[p95Index],
            "frames_per_second": 1_000 / mean,
            "initial_resident_bytes": initialMemory.residentBytes,
            "warmed_resident_bytes": warmedMemory.residentBytes,
            "maximum_observed_resident_bytes":
                maximumObservedResidentBytes,
            "process_peak_resident_bytes":
                finalMemory.peakResidentBytes,
            "peak_growth_from_initial_bytes":
                max(
                    0,
                    Int64(finalMemory.peakResidentBytes)
                        - Int64(initialMemory.peakResidentBytes)
                ),
            "checksum": checksum
        ]
    }

    static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    static func sysctlString(_ name: String) -> String {
        var size = 0
        let sizeStatus = name.withCString {
            sysctlbyname($0, nil, &size, nil, 0)
        }
        guard sizeStatus == 0, size > 1 else {
            return "unavailable"
        }
        var bytes = [CChar](repeating: 0, count: size)
        let readStatus = bytes.withUnsafeMutableBytes { buffer in
            name.withCString {
                sysctlbyname(
                    $0,
                    buffer.baseAddress,
                    &size,
                    nil,
                    0
                )
            }
        }
        guard readStatus == 0 else {
            return "unavailable"
        }
        return bytes.withUnsafeBufferPointer {
            guard let baseAddress = $0.baseAddress else {
                return "unavailable"
            }
            return String(cString: baseAddress)
        }
    }

    static func makeProcessor(
        resolution: VideoResolution,
        scenario: Scenario
    ) throws -> R13FullFrameEnhancementProcessor {
        try R13FullFrameEnhancementProcessor(
            targetResolution: resolution,
            temporalConsistencyEnabled:
                scenario == .temporalSteadyState,
            edgeFidelityLevel: .high,
            detailRecoveryLevel: .high,
            edgePreservationEnabled: scenario == .allEffects,
            compressionCleanupEnabled: scenario == .allEffects,
            textureGrainProtectionEnabled: scenario == .allEffects,
            temporalStabilityEnabled:
                scenario != .baselineSpatial
        )
    }

    static func makeBuffer(
        resolution: VideoResolution,
        offset: Int
    ) throws -> CVPixelBuffer {
        let attributes = [
            kCVPixelBufferIOSurfacePropertiesKey as String:
                [String: Any]()
        ] as CFDictionary
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            resolution.width,
            resolution.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess,
              let buffer = optionalBuffer else {
            throw R13FullFrameEnhancementProcessorError
                .outputAllocationFailed(status)
        }
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw R13FullFrameEnhancementProcessorError
                .pixelBufferLockFailed(
                    role: .source,
                    status: lockStatus
                )
        }
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, [])
        }
        guard let lumaAddress =
                CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaAddress =
                CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw R13FullFrameEnhancementProcessorError
                .inaccessiblePlane(role: .source, plane: 0)
        }
        let luma = lumaAddress.assumingMemoryBound(to: UInt8.self)
        let lumaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<resolution.height {
            let lumaRow = luma.advanced(by: row * lumaStride)
            for column in 0..<resolution.width {
                lumaRow[column] = UInt8(
                    48 + (
                        row * 13
                            + column * 7
                            + (row / 8) * 3
                            + (column / 8) * 5
                    ) % 144 + offset
                )
            }
        }
        let chroma = chromaAddress.assumingMemoryBound(to: UInt8.self)
        let chromaStride =
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(resolution.height / 2) {
            let chromaRow = chroma.advanced(by: row * chromaStride)
            for column in 0..<(resolution.width / 2) {
                chromaRow[column * 2] = UInt8(
                    112 + (row * 3 + column * 5 + offset) % 17
                )
                chromaRow[column * 2 + 1] = UInt8(
                    128 + (row * 7 + column * 3 + offset) % 17
                )
            }
        }
        return buffer
    }

    static func sampledChecksum(_ buffer: CVPixelBuffer) -> UInt64 {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly)
                == kCVReturnSuccess else {
            return 0
        }
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        guard let address =
                CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return 0
        }
        let luma = address.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var checksum: UInt64 = 0
        for index in 0..<16 {
            let row = index * (height - 1) / 15
            let column = (15 - index) * (width - 1) / 15
            checksum = checksum &* 257
                &+ UInt64(luma[row * stride + column])
        }
        return checksum
    }

    static func memorySample() throws -> MemorySample {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw BenchmarkError.memoryQueryFailed(result)
        }
        return MemorySample(
            residentBytes: info.resident_size,
            peakResidentBytes: info.resident_size_max
        )
    }

    enum BenchmarkError: Error {
        case memoryQueryFailed(kern_return_t)
    }
}

private extension R13FullFrameEnhancementBenchmark.BenchmarkCase {
    static let allRawValues = [
        baseline1080.rawValue,
        effects1080.rawValue,
        temporal1080.rawValue,
        baseline2160.rawValue,
        effects2160.rawValue,
        temporal2160.rawValue
    ]
}
