import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

@available(macOS 15.4, *)
enum ASHP08PerformanceRuntime {
    static let warmupFrameCount = 30
    static let measurementFrameCount = 300
    private static let cpuReferenceFrameCount = 3

    private struct FullResult {
        let elapsedSeconds: Double
        let gpuSamples: [Double]
        let analysisCellCount: UInt64
        let candidateLumaInvocationCount: UInt64
        let lumaFallbackInvocationCount: UInt64
        let actualLumaInvocationCount: UInt64
        let repeatOutputSHA256Values: [String]
    }

    private struct FixedResult {
        let elapsedSeconds: Double
        let gpuSamples: [Double]
    }

    static func measure(context: ASHP08NativeContext) async throws -> [String: Any] {
        var measurements: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try await ASHP08NativeSupport.loadFixture(route)
            for mode in ["compute_only", "end_to_end"] {
                let conditions = try fixture.benchmarkConditions(mode: mode)
                let conditionsSHA256 = try ASHP08NativeSupport.canonicalSHA256(conditions)
                let cpuElapsed = try await measureCPUReference(
                    fixture: fixture,
                    context: context,
                    mode: mode
                )
                let full = try await measureFullMetal(
                    fixture: fixture,
                    context: context,
                    mode: mode
                )
                let fixed = try await measureFixedMetal(
                    fixture: fixture,
                    context: context,
                    mode: mode
                )
                guard full.gpuSamples.count == measurementFrameCount,
                      fixed.gpuSamples.count == measurementFrameCount else {
                    throw ASHP08NativeError.invalidArtifact(
                        "GPU timing sample closure differs"
                    )
                }
                let pairedOverhead = zip(full.gpuSamples, fixed.gpuSamples).map {
                    (($0.0 - $0.1) / $0.1) * 100
                }
                let targetLumaPixels = UInt64(fixture.destinationWidth)
                    * UInt64(fixture.destinationHeight)
                    * UInt64(measurementFrameCount)
                let measuredDispatchCost = (
                    Double(full.analysisCellCount)
                        + Double(full.actualLumaInvocationCount)
                ) / Double(targetLumaPixels)
                let estimateError = abs(
                    measuredDispatchCost - context.calibrationEstimatedDispatchCost
                ) / context.calibrationEstimatedDispatchCost
                measurements.append([
                    "route": route.rawValue,
                    "mode": mode,
                    "input_sha256": fixture.fileSHA256,
                    "full_ash_conditions_sha256": conditionsSHA256,
                    "fixed_metal_conditions_sha256": conditionsSHA256,
                    "benchmark_conditions": conditions,
                    "cpu_reference_frames": cpuReferenceFrameCount,
                    "cpu_reference_elapsed_seconds": cpuElapsed,
                    "full_ash_metal_warmup_frames": warmupFrameCount,
                    "full_ash_metal_frames": measurementFrameCount,
                    "full_ash_metal_elapsed_seconds": full.elapsedSeconds,
                    "same_bank_fixed_metal_warmup_frames": warmupFrameCount,
                    "same_bank_fixed_metal_frames": measurementFrameCount,
                    "same_bank_fixed_metal_elapsed_seconds": fixed.elapsedSeconds,
                    "same_machine_speedup":
                        (cpuElapsed / Double(cpuReferenceFrameCount))
                            / (full.elapsedSeconds / Double(measurementFrameCount)),
                    "frames_per_second":
                        Double(measurementFrameCount) / full.elapsedSeconds,
                    "full_ash_gpu_time_samples_seconds": full.gpuSamples,
                    "same_bank_fixed_gpu_time_samples_seconds": fixed.gpuSamples,
                    "ash_dispatch_overhead_p95_percent":
                        try ASHP08NativeSupport.percentile95(pairedOverhead),
                    "calibration_estimate_source_artifact_sha256":
                        context.selectedEvaluationArtifactSHA256,
                    "analysis_cell_count": full.analysisCellCount,
                    "target_luma_pixel_count": targetLumaPixels,
                    "candidate_luma_operator_invocation_count":
                        full.candidateLumaInvocationCount,
                    "luma_numerical_fallback_invocation_count":
                        full.lumaFallbackInvocationCount,
                    "actual_luma_operator_invocation_count":
                        full.actualLumaInvocationCount,
                    "calibration_estimated_dispatch_cost":
                        context.calibrationEstimatedDispatchCost,
                    "measured_luma_dispatch_cost": measuredDispatchCost,
                    "calibration_estimate_relative_error": estimateError,
                    "repeat_output_sha256_values":
                        full.repeatOutputSHA256Values
                ])
            }
        }
        return [
            "measurement_protocol": measurementProtocol,
            "measurements": measurements
        ]
    }

    static func measureResourceRing(
        context: ASHP08NativeContext
    ) async throws -> [String: Any] {
        var routes: [[String: Any]] = []
        for route in ASHSpatialRouteV2.allCases {
            let fixture = try await ASHP08NativeSupport.loadFixture(route)
            let conditions = try fixture.benchmarkConditions(mode: "compute_only")
            let conditionsSHA256 = try ASHP08NativeSupport.canonicalSHA256(conditions)
            let runtime = try ASHMetalSpatialRuntimeV3(
                route: route,
                artifacts: context.artifacts,
                metal: context.metal
            )
            let destination = try ASHP08NativeSupport.makePixelBuffer(
                width: fixture.destinationWidth,
                height: fixture.destinationHeight
            )
            for index in 0..<warmupFrameCount {
                let frame = try await runtime.process(
                    source: fixture.frames[index % fixture.frames.count].pixelBuffer,
                    into: destination,
                    context: ASHMetalFrameContextV3(frameIndex: index)
                )
                frame.finishAfterAppend()
            }
            let memoryAfterWarmup = try ASHP08NativeSupport.residentMemoryBytes()
            var repeatHashes: [String] = []
            for index in 0..<measurementFrameCount {
                let sourceOrdinal = index % fixture.frames.count
                let frame = try await runtime.process(
                    source: fixture.frames[sourceOrdinal].pixelBuffer,
                    into: destination,
                    context: ASHMetalFrameContextV3(
                        frameIndex: warmupFrameCount + index
                    )
                )
                if sourceOrdinal == 0, repeatHashes.count < 2 {
                    repeatHashes.append(
                        try ASHP08NativeSupport.pixelBufferSHA256(destination)
                    )
                }
                frame.finishAfterAppend()
            }
            let memoryAfterMeasurement = try ASHP08NativeSupport.residentMemoryBytes()
            let diagnostics = runtime.diagnostics()
            guard repeatHashes.count == 2,
                  Set(repeatHashes).count == 1,
                  diagnostics.currentGPUFrameCount == 0,
                  diagnostics.ring.inFlightSlotCount == 0 else {
                throw ASHP08NativeError.invalidArtifact(
                    "resource-ring measurement did not drain deterministically"
                )
            }
            let memoryDrift = Double(max(0, memoryAfterMeasurement - memoryAfterWarmup))
                / Double(memoryAfterWarmup) * 100
            routes.append([
                "route": route.rawValue,
                "benchmark_conditions_sha256": conditionsSHA256,
                "configured_capacity": diagnostics.ring.capacity,
                "maximum_observed_in_flight": diagnostics.ring.peakInFlightSlotCount,
                "observed_frames": measurementFrameCount,
                "in_flight_after_drain": diagnostics.ring.inFlightSlotCount,
                "resource_failure_count": diagnostics.failureCount,
                "memory_metric": "rss",
                "memory_bytes_after_warmup": memoryAfterWarmup,
                "memory_bytes_after_measurement": memoryAfterMeasurement,
                "memory_drift_percent": memoryDrift,
                "live_frame_resource_bound": diagnostics.ring.capacity,
                "live_frame_resources_after_drain":
                    diagnostics.ring.availableSlotCount,
                "live_frame_resources_returned_to_bound":
                    diagnostics.ring.availableSlotCount == diagnostics.ring.capacity,
                "repeat_output_sha256_values": repeatHashes
            ])
        }
        return [
            "measurement_protocol": [
                "warmup_frames": warmupFrameCount,
                "measurement_frames": measurementFrameCount
            ],
            "routes": routes
        ]
    }

}

@available(macOS 15.4, *)
private extension ASHP08PerformanceRuntime {
    private static var measurementProtocol: [String: Any] {
        [
            "warmup_frames": warmupFrameCount,
            "measurement_frames": measurementFrameCount,
            "cpu_reference_frames": cpuReferenceFrameCount,
            "gpu_timing_percentile":
                "ascending paired overhead percentages with linear interpolation at (n-1)*0.95",
            "calibration_estimate_source":
                "exact selected validation candidate-evaluation-v2 /evaluation/objective/estimated_dispatch_cost",
            "calibration_estimate_formula":
                "binary64 mean in locked row order of (analysis_cell_count + maximum_operator_evaluations * target_luma_pixel_count) / target_luma_pixel_count",
            "measured_dispatch_cost_formula":
                "(analysis_cell_count + actual_luma_operator_invocation_count) / target_luma_pixel_count",
            "dispatch_cost_count_scope":
                "luma only, summed across full_ash_metal_frames after warmup",
            "maximum_operator_evaluations_per_output_cell": 2,
            "candidate_and_fallback_rule":
                "candidate luma operator invocations are bounded at two per target pixel; "
                + "conservative numerical fallback invocations are recorded separately "
                + "and are not candidate evaluations",
            "compute_only_and_end_to_end_both_required": true,
            "fixed_control":
                "same-bank fixed-operator Metal under identical input/output/writer conditions"
        ]
    }

    private static func measureCPUReference(
        fixture: ASHP08Fixture,
        context: ASHP08NativeContext,
        mode: String
    ) async throws -> Double {
        let backend = try ASHLockedUpscaleBackendV3(
            route: fixture.route,
            artifacts: context.artifacts
        )
        let writer = mode == "end_to_end"
            ? try makeWriter(
                fixture: fixture,
                label: "cpu-\(fixture.route.rawValue)-\(mode)"
            ) : nil
        defer { writer?.removeOutput() }
        let reusable = writer == nil
            ? try ASHP08NativeSupport.makePixelBuffer(
                width: fixture.destinationWidth,
                height: fixture.destinationHeight
            ) : nil
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<cpuReferenceFrameCount {
            let destination = try writer?.makePixelBuffer() ?? unwrapped(reusable)
            let completion = try await backend.process(
                source: fixture.frames[index % fixture.frames.count].pixelBuffer,
                into: destination,
                context: ASHUpscaleFrameContext(
                    frameIndex: index,
                    presentationTimestampValue: Int64(index),
                    presentationTimestampTimescale: 60
                )
            )
            if let writer {
                try await writer.append(
                    destination,
                    at: CMTime(value: Int64(index), timescale: 60)
                )
            }
            completion.finishAfterAppend()
        }
        if let writer { try await writer.finish() }
        return try elapsedSeconds(since: start)
    }

    private static func measureFullMetal(
        fixture: ASHP08Fixture,
        context: ASHP08NativeContext,
        mode: String
    ) async throws -> FullResult {
        let runtime = try ASHMetalSpatialRuntimeV3(
            route: fixture.route,
            artifacts: context.artifacts,
            metal: context.metal
        )
        let warmupDestination = try ASHP08NativeSupport.makePixelBuffer(
            width: fixture.destinationWidth,
            height: fixture.destinationHeight
        )
        for index in 0..<warmupFrameCount {
            let frame = try await runtime.process(
                source: fixture.frames[index % fixture.frames.count].pixelBuffer,
                into: warmupDestination,
                context: ASHMetalFrameContextV3(frameIndex: index)
            )
            frame.finishAfterAppend()
        }
        let writer = mode == "end_to_end"
            ? try makeWriter(
                fixture: fixture,
                label: "full-\(fixture.route.rawValue)-\(mode)"
            ) : nil
        defer { writer?.removeOutput() }
        let reusable = writer == nil
            ? try ASHP08NativeSupport.makePixelBuffer(
                width: fixture.destinationWidth,
                height: fixture.destinationHeight
            ) : nil
        var samples: [Double] = []
        var analysis: UInt64 = 0
        var candidate: UInt64 = 0
        var fallback: UInt64 = 0
        var actual: UInt64 = 0
        var repeats: [String] = []
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<measurementFrameCount {
            let sourceOrdinal = index % fixture.frames.count
            let destination = try writer?.makePixelBuffer() ?? unwrapped(reusable)
            let frame = try await runtime.process(
                source: fixture.frames[sourceOrdinal].pixelBuffer,
                into: destination,
                context: ASHMetalFrameContextV3(
                    frameIndex: warmupFrameCount + index,
                    presentationTimestampValue: Int64(index),
                    presentationTimestampTimescale: 60
                )
            )
            guard let gpu = frame.gpuElapsedSeconds, gpu > 0,
                  frame.summary.actualLumaOperatorInvocationCount
                    >= frame.summary.lumaNumericalFallbackCount else {
                throw ASHP08NativeError.invalidArtifact(
                    "full ASH GPU timing or luma counters are invalid"
                )
            }
            samples.append(gpu)
            analysis += UInt64(frame.summary.analysisCellCount)
            fallback += UInt64(frame.summary.lumaNumericalFallbackCount)
            actual += UInt64(frame.summary.actualLumaOperatorInvocationCount)
            candidate += UInt64(
                frame.summary.actualLumaOperatorInvocationCount
                    - frame.summary.lumaNumericalFallbackCount
            )
            if sourceOrdinal == 0, repeats.count < 2 {
                repeats.append(try ASHP08NativeSupport.pixelBufferSHA256(destination))
            }
            if let writer {
                try await writer.append(
                    destination,
                    at: CMTime(value: Int64(index), timescale: 60)
                )
            }
            frame.finishAfterAppend()
        }
        if let writer { try await writer.finish() }
        let elapsed = try elapsedSeconds(since: start)
        guard repeats.count == 2, Set(repeats).count == 1 else {
            throw ASHP08NativeError.invalidArtifact(
                "full ASH output is not repeat deterministic"
            )
        }
        return FullResult(
            elapsedSeconds: elapsed,
            gpuSamples: samples,
            analysisCellCount: analysis,
            candidateLumaInvocationCount: candidate,
            lumaFallbackInvocationCount: fallback,
            actualLumaInvocationCount: actual,
            repeatOutputSHA256Values: repeats
        )
    }

    private static func measureFixedMetal(
        fixture: ASHP08Fixture,
        context: ASHP08NativeContext,
        mode: String
    ) async throws -> FixedResult {
        let runtime = try ASHP08FixedMetalRuntimeV3(
            route: fixture.route,
            descriptorID: context.bestFixedDescriptorID,
            artifacts: context.artifacts,
            metal: context.metal
        )
        let warmupDestination = try ASHP08NativeSupport.makePixelBuffer(
            width: fixture.destinationWidth,
            height: fixture.destinationHeight
        )
        for index in 0..<warmupFrameCount {
            let frame = try await runtime.process(
                source: fixture.frames[index % fixture.frames.count].pixelBuffer,
                into: warmupDestination,
                frameIndex: index
            )
            frame.finishAfterAppend()
        }
        let writer = mode == "end_to_end"
            ? try makeWriter(
                fixture: fixture,
                label: "fixed-\(fixture.route.rawValue)-\(mode)"
            ) : nil
        defer { writer?.removeOutput() }
        let reusable = writer == nil
            ? try ASHP08NativeSupport.makePixelBuffer(
                width: fixture.destinationWidth,
                height: fixture.destinationHeight
            ) : nil
        var samples: [Double] = []
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<measurementFrameCount {
            let destination = try writer?.makePixelBuffer() ?? unwrapped(reusable)
            let frame = try await runtime.process(
                source: fixture.frames[index % fixture.frames.count].pixelBuffer,
                into: destination,
                frameIndex: warmupFrameCount + index
            )
            guard frame.gpuElapsedSeconds > 0 else {
                throw ASHP08NativeError.invalidArtifact(
                    "fixed-control GPU timing is unavailable"
                )
            }
            samples.append(frame.gpuElapsedSeconds)
            if let writer {
                try await writer.append(
                    destination,
                    at: CMTime(value: Int64(index), timescale: 60)
                )
            }
            frame.finishAfterAppend()
        }
        if let writer { try await writer.finish() }
        return FixedResult(
            elapsedSeconds: try elapsedSeconds(since: start),
            gpuSamples: samples
        )
    }

    private static func unwrapped(_ value: CVPixelBuffer?) throws -> CVPixelBuffer {
        guard let value else {
            throw ASHP08NativeError.mediaFailure("reusable destination is absent")
        }
        return value
    }

    private static func elapsedSeconds(since start: UInt64) throws -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
        guard end > start else {
            throw ASHP08NativeError.invalidArtifact("monotonic elapsed time is zero")
        }
        return Double(end - start) / 1_000_000_000
    }
}
