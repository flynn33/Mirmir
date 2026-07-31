import Foundation

enum R13SmoothMotionIntegration {
    static func makeMediaSession(
        base: MediaSession,
        runtime: R13ReleaseJobRuntime,
        source: SourceProfile
    ) throws -> MediaSession {
        guard runtime.job.mode == .smoothMotion else {
            return base
        }
        let recorder = runtime.diagnosticRecorder
        let job = runtime.job
        return try SmoothMotionMediaSession.make(
            base: base,
            configuration:
                job.processingConfiguration.smoothMotion
        ) { event in
            recorder.enqueue(
                severity: severity(for: event.kind),
                subsystem: "smooth_motion",
                operation: "interpolate_output_cadence",
                code: "smooth_motion_\(event.kind.rawValue)",
                job: job,
                source: source,
                additionalFields: diagnosticFields(for: event)
            )
        }
    }

    private static func severity(
        for kind: SmoothMotionDiagnosticEventKind
    ) -> MirmirDiagnosticSeverity {
        switch kind {
        case .routeSelected, .sceneCutHold:
            return .info
        case .nativeUnavailable,
                .nativeProcessingFallback,
                .sceneAnalysisHold:
            return .warning
        case .completed, .cancelled:
            return .notice
        }
    }

    private static func diagnosticFields(
        for event: SmoothMotionDiagnosticEvent
    ) -> [MirmirDiagnosticField] {
        var fields: [MirmirDiagnosticField?] = []
        if let frameIndex = event.frameIndex {
            fields.append(
                try? MirmirDiagnosticField(
                    key: "smooth_motion_source_frame_index",
                    value: .signedInteger(Int64(frameIndex))
                )
            )
        }
        if let route = event.route {
            fields.append(
                try? MirmirDiagnosticField(
                    key: "smooth_motion_route",
                    value: try .identifier(route.rawValue)
                )
            )
        }
        if let reason = event.reason {
            fields.append(
                try? MirmirDiagnosticField(
                    key: "smooth_motion_reason",
                    value: try .identifier(reason)
                )
            )
        }
        if let count = event.generatedFrameCount,
           count >= 0 {
            fields.append(
                try? MirmirDiagnosticField(
                    key: "smooth_motion_generated_frame_count",
                    value: .unsignedInteger(UInt64(count))
                )
            )
        }
        if let difference =
            event.meanNormalizedLumaDifference {
            fields.append(
                rationalField(
                    key: "smooth_motion_mean_luma_difference",
                    value: difference
                )
            )
        }
        if let ratio = event.changedSampleRatio {
            fields.append(
                rationalField(
                    key: "smooth_motion_changed_sample_ratio",
                    value: ratio
                )
            )
        }
        return fields.compactMap { $0 }
    }

    private static func rationalField(
        key: String,
        value: Double
    ) -> MirmirDiagnosticField? {
        guard value.isFinite, value >= 0, value <= 1 else {
            return nil
        }
        let denominator: Int64 = 1_000_000
        let numerator = Int64(
            (value * Double(denominator)).rounded()
        )
        return try? MirmirDiagnosticField(
            key: key,
            value: try .rational(
                numerator: numerator,
                denominator: denominator
            )
        )
    }
}
