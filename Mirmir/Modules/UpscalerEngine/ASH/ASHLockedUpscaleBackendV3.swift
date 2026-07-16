import CoreVideo
import Foundation

@available(macOS 15.4, *)
final class ASHLockedUpscaleBackendV3: ASHUpscaleBackend, @unchecked Sendable {
    private let route: ASHSpatialRouteV2
    private let lut: ASHLUTLoadedV3
    private let configuration: ASHLUTLockedConfigurationV3
    private let mapping: ASHLockedVideoMappingV2
    private let telemetry: any ASHTelemetryRecording
    private(set) var lastDebugSummary: ASHLockedFrameSummaryV3?

    init(
        route: ASHSpatialRouteV2,
        artifacts: ASHLockedArtifactSetV3,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws {
        try artifacts.mapping.validate(configuration: artifacts.configuration)
        let lut = artifacts.lut(for: route)
        guard lut.route == route,
              lut.configuration == artifacts.configuration else {
            throw ASHLockedFramePipelineErrorV3.configurationMismatch
        }
        self.route = route
        self.lut = lut
        self.configuration = artifacts.configuration
        self.mapping = artifacts.mapping
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

        let destinationGeometry = try ASHNV12FrameCodec.geometry(of: destination)
        let destinationRange = try ASHNV12FrameCodec.codeRange(for: destination)
        let output = try ASHLockedFramePipelineV3.process(
            ASHLockedFramePipelineInputV3(
                source: sourceFrame,
                destinationGeometry: destinationGeometry,
                destinationRange: destinationRange,
                expectedRange: mapping.codeRange,
                expectedChromaSiting: mapping.chromaSiting,
                lut: lut,
                configuration: configuration,
                analyzerConfiguration: mapping.analyzerConfiguration
            ),
            telemetry: telemetry
        )

        try Task.checkCancellation()
        try ASHNV12FrameCodec.write(
            luma: output.luma,
            cb: output.cb,
            cr: output.cr,
            chromaSiting: mapping.chromaSiting,
            to: destination
        )
        telemetry.increment(.fullFrameCopies, by: 3)
        telemetry.increment(.fullFrameCPULoops, by: 2)
        lastDebugSummary = output.summary
    }
}
