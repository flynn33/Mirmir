import CoreVideo
import Foundation
import os.lock

@available(macOS 15.4, *)
final class ASHLockedUpscaleBackendV3: ASHUpscaleBackend, @unchecked Sendable {
    private let route: ASHSpatialRouteV2
    private let lut: ASHLUTLoadedV3
    private let configuration: ASHLUTLockedConfigurationV3
    private let mapping: ASHLockedVideoMappingV2
    private let telemetry: any ASHTelemetryRecording
    private let numericalFallbackTotal = OSAllocatedUnfairLock(initialState: UInt64(0))
    private(set) var lastDebugSummary: ASHLockedFrameSummaryV3?
    let releaseIdentityDetails: [String: String]
    let outputMetadata: [String: String]

    var finalOutputMetadata: [String: String] {
        outputMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": String(
                numericalFallbackTotal.withLock { $0 }
            )
        ]) { _, final in final }
    }

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
        let identity = try Self.makeReleaseIdentity(route: route, artifacts: artifacts)
        self.releaseIdentityDetails = identity.details
        self.outputMetadata = identity.metadata
        telemetry.recordMedia(ASHMediaObservation(
            kind: "ash_locked_release_identity",
            details: identity.details
        ))
    }

    func reset() {
        lastDebugSummary = nil
        numericalFallbackTotal.withLock { $0 = 0 }
    }

    func process(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        context _: ASHUpscaleFrameContext
    ) async throws -> any ASHUpscaleFrameCompletion {
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
        let summary = output.summary
        telemetry.increment(
            .declaredPrimaryCandidates,
            by: UInt64(summary.primaryEvaluationCount)
        )
        telemetry.increment(
            .declaredSecondaryCandidates,
            by: UInt64(summary.secondaryEvaluationCount)
        )
        telemetry.increment(
            .actualOperatorInvocations,
            by: UInt64(summary.actualOperatorInvocationCount)
        )
        telemetry.increment(
            .affineCorrections,
            by: UInt64(summary.correctedDecodeCount)
        )
        telemetry.increment(.affineFallbacks, by: UInt64(summary.affineFallbackCount))
        telemetry.increment(.numericalFallbacks, by: UInt64(summary.numericalFallbackCount))
        telemetry.increment(
            .parityRecomputations,
            by: UInt64(summary.parityRecomputationCount)
        )
        telemetry.increment(
            .sourceAlignedPreservations,
            by: UInt64(summary.sourceAlignedPreservationCount)
        )
        numericalFallbackTotal.withLock { total in
            let result = total.addingReportingOverflow(
                UInt64(summary.numericalFallbackCount)
            )
            total = result.overflow ? .max : result.partialValue
        }

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
        lastDebugSummary = summary
        return ASHImmediateFrameCompletion.shared
    }

    static func name(_ mode: ASHLUTAnisotropyModeV3) -> String {
        switch mode {
        case .isotropic: "isotropic"
        case .rotatedZero: "rotated_zero"
        case .rotatedQ12x1024: "rotated_q12_1024"
        case .rotatedQ12x2048: "rotated_q12_2048"
        case .rotatedQ12x3072: "rotated_q12_3072"
        case .rotatedQ12x4096: "rotated_q12_4096"
        }
    }

    static func makeReleaseIdentity(
        route: ASHSpatialRouteV2,
        artifacts: ASHLockedArtifactSetV3
    ) throws -> (details: [String: String], metadata: [String: String]) {
        let routeSelection = artifacts.configuration.routeSelection(for: route)
        let manifestRoute = try artifacts.manifest.route(route)
        let details = [
            "configuration_id": artifacts.configuration.configurationID,
            "release_manifest_sha256": artifacts.manifest.manifestSHA256.hex,
            "route": route.rawValue,
            "lut_whole_file_sha256": manifestRoute.wholeFileSHA256.hex,
            "lut_payload_sha256": manifestRoute.payloadSHA256.hex,
            "lut_format_version": "1.2",
            "spatial_only": "true",
            "luma_coordinate_mode": routeSelection.lumaCoordinatePolicy.rawValue,
            "chroma_coordinate_mode": routeSelection.chromaCoordinatePolicy.rawValue,
            "luma_anisotropy_mode": Self.name(routeSelection.lumaAnisotropyMode),
            "chroma_anisotropy_mode": Self.name(routeSelection.chromaAnisotropyMode),
            "analysis_grid_source_step": String(routeSelection.analysisGridSourceStep)
        ]
        let metadata = Dictionary(uniqueKeysWithValues: details.map { key, value in
            ("com.mirmir.ash.\(key.replacingOccurrences(of: "_", with: "-"))", value)
        })
        return (details, metadata)
    }
}

@available(macOS 15.4, *)
final class ASHMetalUpscaleBackendV3: ASHUpscaleBackend, @unchecked Sendable {
    private let runtime: ASHMetalSpatialRuntimeV3
    private let numericalFallbackTotal = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let debugSummary = OSAllocatedUnfairLock<ASHMetalFrameSummaryV3?>(initialState: nil)

    let releaseIdentityDetails: [String: String]
    let outputMetadata: [String: String]

    var lastDebugSummary: ASHMetalFrameSummaryV3? {
        debugSummary.withLock { $0 }
    }

    var finalOutputMetadata: [String: String] {
        outputMetadata.merging([
            "com.mirmir.ash.numerical-fallback-count": String(
                numericalFallbackTotal.withLock { $0 }
            )
        ]) { _, final in final }
    }

    init(
        route: ASHSpatialRouteV2,
        artifacts: ASHLockedArtifactSetV3,
        metal: any MetalRenderingService,
        telemetry: any ASHTelemetryRecording = ASHNoopTelemetryRecorder.shared
    ) throws {
        let identity = try ASHLockedUpscaleBackendV3.makeReleaseIdentity(
            route: route,
            artifacts: artifacts
        )
        self.releaseIdentityDetails = identity.details
        self.outputMetadata = identity.metadata
        self.runtime = try ASHMetalSpatialRuntimeV3(
            route: route,
            artifacts: artifacts,
            metal: metal,
            telemetry: telemetry
        )
        telemetry.recordMedia(ASHMediaObservation(
            kind: "ash_locked_release_identity",
            details: identity.details
        ))
    }

    func reset() {
        numericalFallbackTotal.withLock { $0 = 0 }
        debugSummary.withLock { $0 = nil }
    }

    func process(
        source: CVPixelBuffer,
        into destination: CVPixelBuffer,
        context: ASHUpscaleFrameContext
    ) async throws -> any ASHUpscaleFrameCompletion {
        let completion = try await runtime.process(
            source: source,
            into: destination,
            context: ASHMetalFrameContextV3(
                frameIndex: context.frameIndex,
                presentationTimestampValue: context.presentationTimestampValue,
                presentationTimestampTimescale: context.presentationTimestampTimescale
            )
        )
        let summary = completion.summary
        numericalFallbackTotal.withLock { total in
            let result = total.addingReportingOverflow(UInt64(summary.numericalFallbackCount))
            total = result.overflow ? .max : result.partialValue
        }
        debugSummary.withLock { $0 = summary }
        return completion
    }

    func diagnostics() -> ASHMetalRuntimeDiagnosticsV3 {
        runtime.diagnostics()
    }
}
