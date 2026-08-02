import CoreMedia
import Foundation

@available(macOS 15.4, *)
extension ASHP08PerformanceRuntime {
    struct ProfileOutputCounts: Equatable {
        let luma: UInt32
        let chroma: UInt32
    }

    private struct ProfileFrameCounts {
        var analysisGPUFrameCount = 0
        var reconstructionGPUFrameCount = 0
        var maximumCandidateEvaluations = 0
    }

    static func runProfile(
        route: ASHSpatialRouteV2,
        context: ASHP08NativeContext
    ) async throws -> [String: Any] {
        let fixture = try await ASHP08NativeSupport.loadFixture(route)
        let telemetry = DefaultASHTelemetryRecorder()
        telemetry.beginRun(id: "p08-profile-\(route.rawValue)")
        let runtime = try ASHMetalSpatialRuntimeV3(
            route: route,
            lut: ASHMetalRuntimeLUTV3(context.artifacts.lut(for: route)),
            mapping: context.artifacts.mapping.metalRuntimeMappingV3,
            metal: context.metal,
            telemetry: telemetry
        )
        try await warmUpProfileRuntime(runtime, fixture: fixture)
        let writer = try makeWriter(
            fixture: fixture,
            label: "profile-\(route.rawValue)"
        )
        defer { writer.removeOutput() }
        let counts = try await measureProfileFrames(
            runtime: runtime,
            fixture: fixture,
            writer: writer
        )
        try await writer.finish()
        let diagnostics = runtime.diagnostics()
        let telemetrySnapshot = telemetry.snapshot()
        let commandBufferErrors = telemetrySnapshot.commandBuffers.filter {
            $0.status != "completed" || $0.errorDomain != nil
        }.count
        let fullFrameCPULoops = telemetrySnapshot.counters[
            ASHTelemetryCounter.fullFrameCPULoops.rawValue,
            default: 0
        ]
        let fullFrameGPUReadbacks = telemetrySnapshot.counters[
            ASHTelemetryCounter.fullFrameGPUReadbacks.rawValue,
            default: 0
        ]
        guard diagnostics.currentGPUFrameCount == 0,
              diagnostics.failureCount == 0,
              diagnostics.constructionCountersAreP08Conformant else {
            throw ASHP08NativeError.invalidArtifact(
                "profile runtime diagnostics violate the production boundary"
            )
        }
        let conditions = try fixture.benchmarkConditions(mode: "end_to_end")
        return [
            "route": route.rawValue,
            "benchmark_conditions_sha256":
                try ASHP08NativeSupport.canonicalSHA256(conditions),
            "observed_frames": measurementFrameCount,
            "analysis_gpu_frame_count": counts.analysisGPUFrameCount,
            "reconstruction_gpu_frame_count": counts.reconstructionGPUFrameCount,
            "full_frame_cpu_reconstruction_loop_count": fullFrameCPULoops,
            "runtime_leaf_tree_generation_count":
                runtime.constructionCounters.runtimeTreeGenerationCount,
            "candidate_evaluation_maximum_from_gpu_summary":
                counts.maximumCandidateEvaluations,
            "command_completion_mode": diagnostics.commandCompletionMode.rawValue,
            "submitted_command_buffer_count": diagnostics.submissionCount,
            "completed_command_buffer_count": diagnostics.completionCount,
            "failed_command_buffer_count": diagnostics.failureCount,
            "command_buffer_observation_count":
                telemetrySnapshot.commandBuffers.count,
            "command_buffer_error_observation_count": commandBufferErrors,
            "avoidable_full_frame_gpu_readback_count": fullFrameGPUReadbacks
        ]
    }

    static func makeWriter(
        fixture: ASHP08Fixture,
        label: String
    ) throws -> ASHP08WriterSession {
        let scratchPath = try ASHP08NativeSupport.environment("MIRMIR_P08_SCRATCH_ROOT")
        let scratch = URL(fileURLWithPath: scratchPath)
        guard scratch.path == scratchPath,
              scratch.path.hasPrefix("/"),
              let values = try? scratch.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey
              ]),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isAliasFile != true else {
            throw ASHP08NativeError.invalidPath(
                "MIRMIR_P08_SCRATCH_ROOT must be an absolute non-linked directory"
            )
        }
        let output = scratch.appendingPathComponent(
            "p08-\(label)-\(ProcessInfo.processInfo.processIdentifier).mp4"
        )
        return try ASHP08WriterSession(output: output, fixture: fixture)
    }

    static func expectedProfileOutputCounts(
        destinationWidth: Int,
        destinationHeight: Int
    ) throws -> ProfileOutputCounts {
        guard destinationWidth > 0, destinationHeight > 0 else {
            throw ASHP08NativeError.invalidArtifact(
                "profile destination dimensions must be positive"
            )
        }
        let luma = destinationWidth.multipliedReportingOverflow(
            by: destinationHeight
        )
        let chromaWidth = destinationWidth / 2 + destinationWidth % 2
        let chromaHeight = destinationHeight / 2 + destinationHeight % 2
        let chromaPositions = chromaWidth.multipliedReportingOverflow(
            by: chromaHeight
        )
        let chromaComponents = chromaPositions.partialValue
            .multipliedReportingOverflow(by: 2)
        guard !luma.overflow,
              !chromaPositions.overflow,
              !chromaComponents.overflow,
              let lumaCount = UInt32(exactly: luma.partialValue),
              let chromaCount = UInt32(exactly: chromaComponents.partialValue) else {
            throw ASHP08NativeError.invalidArtifact(
                "profile output counters exceed their exact UInt32 range"
            )
        }
        return ProfileOutputCounts(luma: lumaCount, chroma: chromaCount)
    }

    private static func warmUpProfileRuntime(
        _ runtime: ASHMetalSpatialRuntimeV3,
        fixture: ASHP08Fixture
    ) async throws {
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
    }

    private static func measureProfileFrames(
        runtime: ASHMetalSpatialRuntimeV3,
        fixture: ASHP08Fixture,
        writer: ASHP08WriterSession
    ) async throws -> ProfileFrameCounts {
        var counts = ProfileFrameCounts()
        let expectedOutputs = try expectedProfileOutputCounts(
            destinationWidth: fixture.destinationWidth,
            destinationHeight: fixture.destinationHeight
        )
        for index in 0..<measurementFrameCount {
            let destination = try writer.makePixelBuffer()
            let frame = try await runtime.process(
                source: fixture.frames[index % fixture.frames.count].pixelBuffer,
                into: destination,
                context: ASHMetalFrameContextV3(
                    frameIndex: warmupFrameCount + index,
                    presentationTimestampValue: Int64(index),
                    presentationTimestampTimescale: 60
                )
            )
            counts.analysisGPUFrameCount += frame.summary.analysisCellCount > 0 ? 1 : 0
            if frame.summary.lumaOutputCount == expectedOutputs.luma,
               frame.summary.chromaOutputCount == expectedOutputs.chroma {
                counts.reconstructionGPUFrameCount += 1
            }
            if frame.summary.twoCandidateDispatchCount > 0 {
                counts.maximumCandidateEvaluations = 2
            } else if frame.summary.oneCandidateDispatchCount > 0 {
                counts.maximumCandidateEvaluations = max(
                    counts.maximumCandidateEvaluations,
                    1
                )
            }
            try await writer.append(
                destination,
                at: CMTime(value: Int64(index), timescale: 60)
            )
            frame.finishAfterAppend()
        }
        return counts
    }
}

@available(macOS 15.4, *)
private extension ASHMetalRuntimeDiagnosticsV3 {
    var constructionCountersAreP08Conformant: Bool {
        commandCompletionMode == .asynchronousCompletionHandler
            && submissionCount == completionCount
            && failureCount == 0
    }
}
