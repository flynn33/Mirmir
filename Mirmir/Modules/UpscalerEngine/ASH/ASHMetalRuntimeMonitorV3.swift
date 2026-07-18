import Foundation
import os.lock

final class ASHMetalRuntimeMonitorV3: @unchecked Sendable {
    private struct RuntimeState {
        var submissionCount: UInt64 = 0
        var completionCount: UInt64 = 0
        var failureCount: UInt64 = 0
        var currentGPUFrameCount = 0
        var peakGPUFrameCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: RuntimeState())
    private let telemetry: any ASHTelemetryRecording

    init(telemetry: any ASHTelemetryRecording) {
        self.telemetry = telemetry
    }

    func diagnostics(
        ring: ASHMetalFrameResourceRingV3,
        completionMode: ASHMetalCommandCompletionModeV3
    ) -> ASHMetalRuntimeDiagnosticsV3 {
        let runtime = state.withLock { $0 }
        return ASHMetalRuntimeDiagnosticsV3(
            ring: ring.snapshot(),
            commandCompletionMode: completionMode,
            submissionCount: runtime.submissionCount,
            completionCount: runtime.completionCount,
            failureCount: runtime.failureCount,
            currentGPUFrameCount: runtime.currentGPUFrameCount,
            peakGPUFrameCount: runtime.peakGPUFrameCount
        )
    }

    func markSubmission() {
        state.withLock { state in
            state.submissionCount = Self.saturatingIncrement(state.submissionCount)
            state.currentGPUFrameCount += 1
            state.peakGPUFrameCount = max(
                state.peakGPUFrameCount,
                state.currentGPUFrameCount
            )
        }
        telemetry.increment(.inFlightFrames)
    }

    func markCompletion(failed: Bool) {
        state.withLock { state in
            state.completionCount = Self.saturatingIncrement(state.completionCount)
            state.currentGPUFrameCount = max(0, state.currentGPUFrameCount - 1)
        }
        if failed {
            telemetry.increment(.commandBufferErrors)
        }
    }

    func recordProcessingFailure(_ error: Error, frameIndex: Int) {
        guard !(error is CancellationError) else { return }
        state.withLock { state in
            state.failureCount = Self.saturatingIncrement(state.failureCount)
        }
        telemetry.recordError(error, frameIndex: frameIndex)
    }

    func recordCommandCompletion(_ completion: MetalCommandBufferCompletion) {
        telemetry.recordCommandBuffer(ASHCommandBufferObservation(
            label: completion.context.label,
            status: completion.status.name,
            frameIndex: completion.context.frameIndex,
            presentationTimestampValue: completion.context.presentationTimestampValue,
            presentationTimestampTimescale: completion.context.presentationTimestampTimescale,
            errorDomain: completion.error?.domain,
            errorCode: completion.error?.code,
            gpuStartSeconds: completion.gpuStartSeconds,
            gpuEndSeconds: completion.gpuEndSeconds
        ))
    }

    func recordCommandFailure(
        _ error: Error,
        context: MetalCommandBufferExecutionContext
    ) {
        if let execution = error as? MetalCommandBufferExecutionError,
           case .executionFailed(let completion) = execution {
            recordCommandCompletion(completion)
            return
        }
        telemetry.recordCommandBuffer(ASHCommandBufferObservation(
            label: context.label,
            status: error is CancellationError ? "cancelled" : "failed",
            frameIndex: context.frameIndex,
            presentationTimestampValue: context.presentationTimestampValue,
            presentationTimestampTimescale: context.presentationTimestampTimescale
        ))
    }

    func record(
        _ summary: ASHMetalFrameSummaryV3,
        context: ASHMetalFrameContextV3,
        completion: MetalCommandBufferCompletion
    ) {
        telemetry.increment(.decodeExact, by: UInt64(summary.exactDecodeCount))
        telemetry.increment(.decodeCorrected, by: UInt64(summary.correctedDecodeCount))
        telemetry.increment(.decodeRejected, by: UInt64(summary.rejectedDecodeCount))
        telemetry.increment(.candidateOne, by: UInt64(summary.oneCandidateDispatchCount))
        telemetry.increment(.candidateTwo, by: UInt64(summary.twoCandidateDispatchCount))
        telemetry.increment(.declaredPrimaryCandidates, by: UInt64(summary.dispatchCount))
        telemetry.increment(
            .declaredSecondaryCandidates,
            by: UInt64(summary.twoCandidateDispatchCount)
        )
        telemetry.increment(
            .actualOperatorInvocations,
            by: UInt64(summary.actualOperatorInvocationCount)
        )
        telemetry.increment(.affineCorrections, by: UInt64(summary.correctedDecodeCount))
        telemetry.increment(.affineFallbacks, by: UInt64(summary.affineFallbackCount))
        telemetry.increment(
            .parityRecomputations,
            by: UInt64(summary.parityRecomputationCount)
        )
        telemetry.increment(.numericalFallbacks, by: UInt64(summary.numericalFallbackCount))
        telemetry.increment(
            .sourceAlignedPreservations,
            by: UInt64(summary.sourceAlignedPreservationCount)
        )
        if let start = completion.gpuStartSeconds,
           let end = completion.gpuEndSeconds,
           end >= start {
            telemetry.recordGPUTime((end - start) * 1_000, for: .frameTotal)
        }
        telemetry.recordMedia(ASHMediaObservation(
            kind: "ash_metal_v3_frame_reduction",
            frameIndex: context.frameIndex,
            presentationTimestampValue: context.presentationTimestampValue,
            presentationTimestampTimescale: context.presentationTimestampTimescale,
            details: [
                "analysis_cells": String(summary.analysisCellCount),
                "dispatches": String(summary.dispatchCount),
                "luma_operator_invocations": String(
                    summary.actualLumaOperatorInvocationCount
                ),
                "chroma_operator_invocations": String(
                    summary.actualChromaOperatorInvocationCount
                ),
                "luma_numerical_fallbacks": String(summary.lumaNumericalFallbackCount),
                "chroma_numerical_fallbacks": String(
                    summary.chromaNumericalFallbackCount
                ),
                "affine_fallbacks": String(summary.affineFallbackCount),
                "parity_recomputations": String(summary.parityRecomputationCount),
                "luma_outputs": String(summary.lumaOutputCount),
                "chroma_outputs": String(summary.chromaOutputCount)
            ]
        ))
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        let result = value.addingReportingOverflow(1)
        return result.overflow ? .max : result.partialValue
    }
}
