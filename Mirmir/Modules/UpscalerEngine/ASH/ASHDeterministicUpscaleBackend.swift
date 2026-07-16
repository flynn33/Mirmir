import CoreVideo
import Foundation

@available(macOS 15.4, *)
final class ASHDeterministicUpscaleBackend: ASHUpscaleBackend, @unchecked Sendable {
    private let route: ASHSpatialRouteV2
    private let runtimeConfiguration: ASHSpatialRuntimeConfigurationV2
    private let operatorParameters: ASHSpatialDevelopmentParametersV2
    private let stateInputEnabled: Bool
    private let telemetry: any ASHTelemetryRecording
    private(set) var lastDebugSummary: ASHSpatialReferenceSummaryV2?

    init(
        route: ASHSpatialRouteV2,
        runtimeConfiguration: ASHSpatialRuntimeConfigurationV2 = .developmentP05,
        operatorParameters: ASHSpatialDevelopmentParametersV2 = .p05DevelopmentOnly,
        stateInputEnabled: Bool = true,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) {
        self.route = route
        self.runtimeConfiguration = runtimeConfiguration
        self.operatorParameters = operatorParameters
        self.stateInputEnabled = stateInputEnabled
        self.telemetry = telemetry
    }

    func reset() {
        lastDebugSummary = nil
    }

    func process(source: CVPixelBuffer, into destination: CVPixelBuffer) async throws {
        try Task.checkCancellation()
        let sourceFrame = try telemetry.measure(.canonicalize) {
            try ASHNV12FrameCodec.extract(from: source)
        }
        telemetry.increment(.fullFrameCopies, by: 3)
        telemetry.increment(.fullFrameCPULoops, by: 2)

        let output = try ASHSpatialReferencePipelineV2.process(
            ASHSpatialReferenceInputV2(
                luma: sourceFrame.luma,
                cb: sourceFrame.cb,
                cr: sourceFrame.cr,
                chromaSiting: sourceFrame.chromaSiting,
                route: route,
                runtimeConfiguration: runtimeConfiguration,
                analyzerConfiguration: try .makeDisposableP05Reference(),
                operatorParameters: operatorParameters,
                stateInputEnabled: stateInputEnabled
            ),
            telemetry: telemetry
        )
        try Task.checkCancellation()
        try ASHNV12FrameCodec.write(
            luma: output.luma,
            cb: output.cb,
            cr: output.cr,
            chromaSiting: sourceFrame.chromaSiting,
            to: destination
        )
        telemetry.increment(.fullFrameCopies, by: 3)
        telemetry.increment(.fullFrameCPULoops, by: 2)
        lastDebugSummary = output.summary
    }
}
