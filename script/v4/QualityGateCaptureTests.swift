import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

/// This candidate-only file is injected into an ephemeral copy of the test
/// project by `run_quality_gate_v4.sh`. P05 is captured by a separate test
/// executable built from the frozen pre-v4 archive; this file must never
/// instantiate or time a P05 implementation from the candidate source tree.
@available(macOS 15.4, *)
final class ASHV4QualityGateCaptureTests: XCTestCase {
    // The runner replaces only these sentinels in its ephemeral source copy.
    // Environment lookup remains available for direct developer runs.
    private static let injectedCaptureDirectory
        = "__MIRMIR_V4_QUALITY_CAPTURE_DIR__"
    private static let injectedCorpusManifest
        = "__MIRMIR_V4_QUALITY_CORPUS_MANIFEST__"
    private static let injectedContractSHA256
        = "__MIRMIR_V4_QUALITY_CONTRACT_SHA256__"
    private static let injectedSourceCommit
        = "__MIRMIR_V4_QUALITY_SOURCE_COMMIT__"
    private static let injectedSourceTreeSHA256
        = "__MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256__"

    private struct CorpusManifest: Decodable {
        let schemaVersion: String
        let contractSHA256: String
        let cases: [CorpusCase]
    }

    private struct CorpusCase: Decodable {
        let id: String
        let clipID: String
        let cohort: String
        let frameIndex: Int
        let pixelFormat: String
        let sourceWidth: Int
        let sourceHeight: Int
        let targetWidth: Int
        let targetHeight: Int
        let sourceFile: String
        let sourceByteCount: Int
        let sourceSHA256: String
        let referenceFile: String
        let referenceByteCount: Int
        let referenceSHA256: String
    }

    private struct CaptureCase: Codable {
        let id: String
        let outputs: [String: String]
        let milliseconds: [String: Double]
    }

    private struct CaptureManifest: Codable {
        let schemaVersion: String
        let contractSHA256: String
        let corpusManifestSHA256: String
        let sourceCommit: String
        let sourceTreeIdentitySHA256: String
        let candidateBackendID: String
        let candidateImplementationVersion: String
        let runtimeManifestSHA256: String
        let runtimeSourceRevision: String
        let productionRuntimeLocked: Bool
        let fullMirrorIdentityPass: Bool
        let warmupCount: Int
        let cases: [CaptureCase]
    }

    private enum Variant: String, CaseIterable {
        case candidateV4 = "candidate_v4"
        case uniformPriors = "uniform_priors"
        case randomizedStateMessage = "randomized_state_message"
        case temporalHysteresisOff = "temporal_hysteresis_off"
        case motionHistoryOff = "motion_history_off"
    }

    private enum AblationMode {
        case full
        case uniformPriors
        case randomizedStateMessage(seed: UInt64)
        case temporalHysteresisOff
        case motionHistoryOff
    }

    private final class AblationPipeline {
        private let mode: AblationMode
        private let storage: PixelStorageV4
        private let scaler: FixedPointPixelBufferScalerV4
        private let measurementContract: ASHMeasurementContractV4
        private let program: ASHDepthFourBranchProgramV4
        private let formatIdentity: ASHSHA256V4
        private var history: ASHTemporalHistoryV4
        private var previousMeasurementFrame: PixelBufferSignalFrameV4?
        private var previousMeasurementState: ASHState?

        init(
            mode: AblationMode,
            storage: PixelStorageV4,
            sourceWidth: Int,
            sourceHeight: Int,
            targetWidth: Int,
            targetHeight: Int,
            runtime: ASHVerifiedRuntimeBundleV4
        ) throws {
            self.mode = mode
            self.storage = storage
            self.scaler = try FixedPointPixelBufferScalerV4(
                backend: .cpu,
                storage: storage,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                borderRule: .reflect101
            )
            self.measurementContract = try runtime.measurementContract()
            self.program = try runtime.branchProgram()
            self.formatIdentity = ASHSHA256V4(
                rawData: Data(
                    "ash-v4-quality-ablation|\(storage.rawValue)|"
                        .appending("\(sourceWidth)x\(sourceHeight)|")
                        .appending("\(targetWidth)x\(targetHeight)").utf8
                )
            )
            self.history = try ASHTemporalHistoryV4(capacity: 3)
        }

        func process(
            source: CVPixelBuffer,
            destination: CVPixelBuffer,
            frameIndex: Int
        ) async throws {
            let sourceSignal = try PixelBufferSignalCodecV4.read(
                source,
                storage: storage
            )
            let exactPTS = try ExactRationalV4(Int64(frameIndex), 30)
            let sourcePlane = try temporalLumaPlane(from: sourceSignal)
            let neutralState = try ASHState(rawValue: 0)
            let sourceTemporalFrame = try ASHTemporalFrameV4(
                frameID: "quality-measurement-\(frameIndex)",
                streamID: "quality-measurement-stream",
                formatIdentity: formatIdentity,
                ordinal: Int64(frameIndex),
                presentationTime: exactPTS,
                luma: sourcePlane,
                tileStateRawValues: [
                    previousMeasurementState?.rawValue
                        ?? neutralState.rawValue
                ],
                cadenceID: "progressive"
            )
            var measurementMotion: ASHTemporalMotionAnalysisV4?
            if case .temporalHysteresisOff = mode {
                measurementMotion = nil
            } else if frameIndex > 0,
                      let previousMeasurementFrame {
                let previousSourceFrame = try ASHTemporalFrameV4(
                    frameID: "quality-measurement-\(frameIndex - 1)",
                    streamID: sourceTemporalFrame.streamID,
                    formatIdentity: sourceTemporalFrame.formatIdentity,
                    ordinal: Int64(frameIndex - 1),
                    presentationTime: try ExactRationalV4(
                        Int64(frameIndex - 1),
                        30
                    ),
                    luma: try temporalLumaPlane(
                        from: previousMeasurementFrame
                    ),
                    tileStateRawValues: [
                        previousMeasurementState?.rawValue
                            ?? neutralState.rawValue
                    ],
                    cadenceID: "progressive"
                )
                measurementMotion = try ASHTemporalMotionAnalyzerV4.analyze(
                    current: sourceTemporalFrame,
                    previous: previousSourceFrame
                )
            }
            let measurementReset: ASHMeasurementResetTriggerV4?
            if case .temporalHysteresisOff = mode {
                measurementReset = .streamStart
            } else if previousMeasurementFrame == nil {
                measurementReset = .streamStart
            } else if measurementMotion?.sceneCut == true {
                measurementReset = .sceneCut
            } else {
                measurementReset = nil
            }
            let measurementHistory: ASHMeasurementHistoryV4
            if let measurementReset {
                measurementHistory = .reset(measurementReset)
            } else if let previousMeasurementState {
                measurementHistory = .continuous(
                    previousState: previousMeasurementState
                )
            } else {
                measurementHistory = .reset(.streamStart)
            }
            let measurement = try ASHMeasurementExtractorV4.extract(
                frame: sourceSignal,
                previousFrame: {
                    if case .temporalHysteresisOff = mode { return nil }
                    return previousMeasurementFrame
                }(),
                contract: measurementContract,
                history: measurementHistory,
                motionCompensatedTemporalEvidenceQ16:
                    measurementMotion?.temporalEvidenceQ16
                        ?? (measurementReset != nil ? 0 : nil)
            )
            try await scaler.process(source: source, destination: destination)
            let outputSignal = try PixelBufferSignalCodecV4.read(
                destination,
                storage: storage
            )
            let lumaPlane = outputSignal.planes[0]
            let bounds = lumaPlane.componentBounds[0]
            let spatial = try ASHTemporalPlaneV4(
                width: lumaPlane.width,
                height: lumaPlane.height,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum,
                samples: try lumaPlane.component(0)
            )
            let state = try selectedState(
                measured: measurement.projection.state,
                frameIndex: frameIndex
            )
            let conditionedSpatial: ASHTemporalPlaneV4
            if case .uniformPriors = mode {
                conditionedSpatial = try uniformSpatialReconstruction(
                    spatial: spatial
                )
            } else {
                conditionedSpatial = try ASHSpatialReconstructorV4.reconstruct(
                    spatial: spatial,
                    sourceState: state,
                    program: program
                ).output
            }
            let frame = try ASHTemporalFrameV4(
                frameID: "quality-frame-\(frameIndex)",
                streamID: "quality-stream",
                formatIdentity: formatIdentity,
                ordinal: Int64(frameIndex),
                presentationTime: exactPTS,
                luma: conditionedSpatial,
                tileStateRawValues: [state.rawValue],
                cadenceID: "progressive"
            )

            var resetReason: ASHTemporalResetReasonV4?
                = history.frames.isEmpty ? .streamStart : nil
            if measurementMotion?.sceneCut == true {
                resetReason = .sceneCut
            }
            var motionAnalysis: ASHTemporalMotionAnalysisV4?
            if case .motionHistoryOff = mode {
                motionAnalysis = nil
            } else if let previous = history.frames.last {
                let motion = try ASHTemporalMotionAnalyzerV4.analyze(
                    current: frame,
                    previous: previous
                )
                if motion.sceneCut {
                    resetReason = .sceneCut
                } else {
                    motionAnalysis = motion
                }
            }

            let reconstructed: ASHTemporalPlaneV4
            if case .uniformPriors = mode {
                reconstructed = try uniformReconstruction(
                    spatial: conditionedSpatial,
                    motionAnalysis: motionAnalysis,
                    resetReason: resetReason
                )
            } else {
                reconstructed = try ASHTemporalReconstructorV4.reconstruct(
                    spatial: conditionedSpatial,
                    motionAnalysis: motionAnalysis,
                    sourceState: state,
                    resetReason: resetReason,
                    program: program
                ).output
            }
            var outputPlanes = outputSignal.planes
            outputPlanes[0] = try lumaPlane.replacingComponent(
                0,
                with: reconstructed.samples
            )
            try PixelBufferSignalCodecV4.write(
                PixelBufferSignalFrameV4(
                    storage: outputSignal.storage,
                    width: outputSignal.width,
                    height: outputSignal.height,
                    planes: outputPlanes
                ),
                to: destination
            )
            if let resetReason {
                try history.reset(reason: resetReason)
            }
            try history.append(ASHTemporalFrameV4(
                frameID: frame.frameID,
                streamID: frame.streamID,
                formatIdentity: frame.formatIdentity,
                ordinal: frame.ordinal,
                presentationTime: frame.presentationTime,
                luma: reconstructed,
                tileStateRawValues: frame.tileStateRawValues,
                cadenceID: frame.cadenceID
            ))
            previousMeasurementFrame = sourceSignal
            previousMeasurementState = measurement.projection.state
        }

        private func temporalLumaPlane(
            from frame: PixelBufferSignalFrameV4
        ) throws -> ASHTemporalPlaneV4 {
            guard let luma = frame.planes.first,
                  luma.componentsPerElement == 1,
                  let bounds = luma.componentBounds.first else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            return try ASHTemporalPlaneV4(
                width: luma.width,
                height: luma.height,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum,
                samples: try luma.component(0)
            )
        }

        private func selectedState(
            measured: ASHState,
            frameIndex: Int
        ) throws -> ASHState {
            guard case .randomizedStateMessage(let seed) = mode else {
                return measured
            }
            var value = seed &+ UInt64(frameIndex) &* 0x9e3779b97f4a7c15
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            value ^= value >> 31
            let payload = (0..<ASHState.payloadBitCount).map { index in
                Int((value >> UInt64(index)) & 1)
            }
            return try ASHState(payloadBits: payload)
        }

        private func uniformReconstruction(
            spatial: ASHTemporalPlaneV4,
            motionAnalysis: ASHTemporalMotionAnalysisV4?,
            resetReason: ASHTemporalResetReasonV4?
        ) throws -> ASHTemporalPlaneV4 {
            guard resetReason == nil,
                  let motionAnalysis else {
                return spatial
            }
            try motionAnalysis.validate()
            guard !motionAnalysis.sceneCut,
                  let aligned = motionAnalysis.alignedPrevious else {
                return spatial
            }
            guard spatial.width == aligned.width,
                  spatial.height == aligned.height,
                  spatial.minimumCode == aligned.minimumCode,
                  spatial.maximumCode == aligned.maximumCode else {
                throw ASHTemporalV4Error.planeGeometryMismatch
            }
            guard let basisIndex = program.operatorManifest.basisIDs
                .firstIndex(of: "regularization") else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            var numerator: UInt64 = 0
            for weight in program.baseWeightsByMessage {
                let entry = try program.operatorManifest.entry(
                    forMessage: weight.messageRawValue
                )
                let coefficient = entry.coefficients[basisIndex]
                if coefficient > 0 {
                    numerator += weight.massNumerator * UInt64(coefficient)
                }
            }
            let stateWeightQ16 = try roundedFraction(
                numerator: numerator * UInt64(ASHNormalizedQ16V4.scale),
                denominator: program.baseMassDenominator
            )
            let scale = UInt64(ASHNormalizedQ16V4.scale)
            let stateBoostQ16 = try roundedShift(
                stateWeightQ16,
                bits: 1
            )
            let confidenceGainQ16 = scale + stateBoostQ16
            var samples = spatial.samples
            for vector in motionAnalysis.vectors where !vector.occluded {
                let historyWeight = min(
                    UInt64(
                        ASHTemporalReconstructorV4.maximumHistoryWeightQ16
                    ),
                    try roundedShift(
                        UInt64(vector.confidenceQ16) * confidenceGainQ16,
                        bits: 16
                    )
                )
                guard historyWeight > 0 else { continue }
                let currentWeight = scale - historyWeight
                for y in vector.originY..<(vector.originY + vector.height) {
                    let row = y * spatial.width
                    for x in vector.originX..<(vector.originX + vector.width) {
                        let index = row + x
                        let value = UInt64(spatial.samples[index])
                            * currentWeight
                            + UInt64(aligned.samples[index]) * historyWeight
                        samples[index] = UInt16(
                            try roundedShift(value, bits: 16)
                        )
                    }
                }
            }
            return try spatial.replacing(samples: samples)
        }

        private func uniformSpatialReconstruction(
            spatial: ASHTemporalPlaneV4
        ) throws -> ASHTemporalPlaneV4 {
            guard program.operatorManifest.basisIDs == [
                "horizontal_detail",
                "vertical_detail",
                "isotropic_detail",
                "regularization"
            ] else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            var numerators = Array(repeating: UInt64(0), count: 4)
            for weight in program.baseWeightsByMessage {
                let entry = try program.operatorManifest.entry(
                    forMessage: weight.messageRawValue
                )
                guard entry.coefficients.count == numerators.count else {
                    throw ASHTemporalV4Error.invalidConfiguration
                }
                for index in numerators.indices {
                    let coefficient = entry.coefficients[index]
                    guard coefficient >= 0 else {
                        throw ASHTemporalV4Error.invalidConfiguration
                    }
                    numerators[index] += weight.massNumerator
                        * UInt64(coefficient)
                }
            }
            var gains = try numerators.map { numerator in
                let expectationQ16 = try roundedFraction(
                    numerator: numerator
                        * UInt64(ASHNormalizedQ16V4.scale),
                    denominator: program.baseMassDenominator
                )
                return try roundedFraction(
                    numerator: expectationQ16
                        * UInt64(
                            ASHSpatialReconstructorV4.maximumDetailGainQ16
                        ),
                    denominator: UInt64(ASHNormalizedQ16V4.scale)
                )
            }
            gains[3] = 0
            let source = spatial.samples
            var output = source
            for y in 0..<spatial.height {
                let upY = max(0, y - 1)
                let downY = min(spatial.height - 1, y + 1)
                for x in 0..<spatial.width {
                    let leftX = max(0, x - 1)
                    let rightX = min(spatial.width - 1, x + 1)
                    let index = y * spatial.width + x
                    let center = Int64(source[index])
                    let left = Int64(source[y * spatial.width + leftX])
                    let right = Int64(source[y * spatial.width + rightX])
                    let up = Int64(source[upY * spatial.width + x])
                    let down = Int64(source[downY * spatial.width + x])
                    let horizontalAverage = try roundedSignedFraction(
                        numerator: left + right,
                        denominator: 2
                    )
                    let verticalAverage = try roundedSignedFraction(
                        numerator: up + down,
                        denominator: 2
                    )
                    let isotropicAverage = try roundedSignedFraction(
                        numerator: left + right + up + down,
                        denominator: 4
                    )
                    let weighted = (center - horizontalAverage)
                            * Int64(gains[0])
                        + (center - verticalAverage) * Int64(gains[1])
                        + (center - isotropicAverage) * Int64(gains[2])
                    let adjustment = try roundedSignedFraction(
                        numerator: weighted,
                        denominator: Int64(ASHNormalizedQ16V4.scale)
                    )
                    output[index] = UInt16(min(
                        Int64(spatial.maximumCode),
                        max(Int64(spatial.minimumCode), center + adjustment)
                    ))
                }
            }
            return try spatial.replacing(samples: output)
        }

        private func roundedFraction(
            numerator: UInt64,
            denominator: UInt64
        ) throws -> UInt64 {
            guard denominator > 0 else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            var quotient = numerator / denominator
            let remainder = numerator % denominator
            let complement = denominator - remainder
            if remainder > complement
                || (remainder == complement && quotient & 1 == 1) {
                quotient += 1
            }
            return quotient
        }

        private func roundedShift(_ value: UInt64, bits: Int) throws -> UInt64 {
            guard (1...63).contains(bits) else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            let denominator = UInt64(1) << bits
            return try roundedFraction(
                numerator: value,
                denominator: denominator
            )
        }

        private func roundedSignedFraction(
            numerator: Int64,
            denominator: Int64
        ) throws -> Int64 {
            guard denominator > 0 else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            let magnitude = try roundedFraction(
                numerator: numerator.magnitude,
                denominator: UInt64(denominator)
            )
            guard magnitude <= UInt64(Int64.max) else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            return numerator < 0 ? -Int64(magnitude) : Int64(magnitude)
        }
    }

    func testCapturePreregisteredQualityCorpusWhenRequested() async throws {
        guard let outputValue = setting(
            "MIRMIR_V4_QUALITY_CAPTURE_DIR",
            injected: Self.injectedCaptureDirectory
        ),
              let corpusValue = setting(
                "MIRMIR_V4_QUALITY_CORPUS_MANIFEST",
                injected: Self.injectedCorpusManifest
              ),
              !outputValue.isEmpty,
              !corpusValue.isEmpty else {
            throw XCTSkip("quality capture environment is not configured")
        }
        let output = URL(fileURLWithPath: outputValue, isDirectory: true)
        let corpusURL = URL(fileURLWithPath: corpusValue)
        let corpusRoot = corpusURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: output.appendingPathComponent("artifacts", isDirectory: true),
            withIntermediateDirectories: true
        )
        let corpusData = try Data(contentsOf: corpusURL)
        let corpus = try JSONDecoder().decode(CorpusManifest.self, from: corpusData)
        XCTAssertEqual(corpus.schemaVersion, "mirmir-ash-v4-quality-corpus-v1")
        let expectedContract = try XCTUnwrap(setting(
            "MIRMIR_V4_QUALITY_CONTRACT_SHA256",
            injected: Self.injectedContractSHA256
        ))
        XCTAssertEqual(corpus.contractSHA256, expectedContract)
        let productionRuntimeConfigured = ASHProductionP06TrustRootV4
            .isConfigured
        let runtime: ASHVerifiedRuntimeBundleV4
        if productionRuntimeConfigured {
            runtime = try ASHP06RuntimeProviderV4.production().load()
        } else {
            runtime = try ASHV4SemanticArtifactTestSupport
                .executableSystemMetalRuntime()
        }
        try runtime.verifyBinding()
        let productionRuntimeLocked = productionRuntimeConfigured
            && runtime.manifest.releaseStatus == .releaseQualified
            && runtime.manifestSHA256
                == ASHProductionP06TrustRootV4.manifestSHA256
            && runtime.manifest.provenance.sourceRevision
                == ASHProductionP06TrustRootV4.sourceRevision
            && runtime.manifest.provenance.builderSourceSHA256
                == ASHProductionP06TrustRootV4.builderSourceSHA256

        let clips = Dictionary(grouping: corpus.cases, by: \.clipID)
        try await runWarmups(
            first: try XCTUnwrap(corpus.cases.sorted { $0.id < $1.id }.first),
            corpusRoot: corpusRoot,
            runtime: runtime,
            count: 5
        )
        var captures: [CaptureCase] = []
        var fullMirrorIdentityPass = true
        for clipID in clips.keys.sorted() {
            let cases = clips[clipID]!.sorted { $0.frameIndex < $1.frameIndex }
            guard let first = cases.first else { continue }
            XCTAssertEqual(cases.map(\.frameIndex), Array(0..<cases.count))
            let storage = try storage(first.pixelFormat)
            let configuration = DeterministicPreparedConfigurationV4(
                backendID: .mirmirDeterministicCPU,
                executionBackend: .cpu,
                storage: storage,
                sourceWidth: first.sourceWidth,
                sourceHeight: first.sourceHeight,
                targetWidth: first.targetWidth,
                targetHeight: first.targetHeight,
                scanMode: .progressive
            )
            let candidate = try PreparedDeterministicV4Upscaler(
                configuration: configuration,
                runtime: runtime
            )
            let pipelines: [Variant: AblationPipeline] = [
                .candidateV4: try AblationPipeline(
                    mode: .full,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .uniformPriors: try AblationPipeline(
                    mode: .uniformPriors,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .randomizedStateMessage: try AblationPipeline(
                    mode: .randomizedStateMessage(seed: stableSeed(clipID)),
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .temporalHysteresisOff: try AblationPipeline(
                    mode: .temporalHysteresisOff,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                ),
                .motionHistoryOff: try AblationPipeline(
                    mode: .motionHistoryOff,
                    storage: storage,
                    sourceWidth: first.sourceWidth,
                    sourceHeight: first.sourceHeight,
                    targetWidth: first.targetWidth,
                    targetHeight: first.targetHeight,
                    runtime: runtime
                )
            ]

            for record in cases {
                let sourceURL = corpusRoot.appendingPathComponent(record.sourceFile)
                let bytes = try Data(contentsOf: sourceURL)
                XCTAssertEqual(bytes.count, record.sourceByteCount)
                XCTAssertEqual(ASHSHA256V4(rawData: bytes).rawValue, record.sourceSHA256)
                let source = try makeBuffer(
                    width: record.sourceWidth,
                    height: record.sourceHeight,
                    storage: storage,
                    bytes: bytes
                )
                var outputs: [String: String] = [:]
                var milliseconds: [String: Double] = [:]

                let candidateOutput = try makeBuffer(
                    width: record.targetWidth,
                    height: record.targetHeight,
                    storage: storage
                )
                let timing = FrameTiming(
                    frameIndex: record.frameIndex,
                    presentationTime: CMTime(value: Int64(record.frameIndex), timescale: 30),
                    duration: CMTime(value: 1, timescale: 30)
                )
                milliseconds[Variant.candidateV4.rawValue] = try await measured {
                    try await candidate.process(
                        source: FramePixelBuffer(source),
                        destination: FramePixelBuffer(candidateOutput),
                        timing: timing
                    )
                }
                outputs[Variant.candidateV4.rawValue] = try writeOutput(
                    candidateOutput,
                    record: record,
                    variant: .candidateV4,
                    output: output
                )

                for variant in [
                    Variant.uniformPriors,
                    .randomizedStateMessage,
                    .temporalHysteresisOff,
                    .motionHistoryOff
                ] {
                    let destination = try makeBuffer(
                        width: record.targetWidth,
                        height: record.targetHeight,
                        storage: storage
                    )
                    milliseconds[variant.rawValue] = try await measured {
                        try await pipelines[variant]!.process(
                            source: source,
                            destination: destination,
                            frameIndex: record.frameIndex
                        )
                    }
                    outputs[variant.rawValue] = try writeOutput(
                        destination,
                        record: record,
                        variant: variant,
                        output: output
                    )
                }

                let mirror = try makeBuffer(
                    width: record.targetWidth,
                    height: record.targetHeight,
                    storage: storage
                )
                let mirrorMilliseconds = try await measured {
                    try await pipelines[.candidateV4]!.process(
                        source: source,
                        destination: mirror,
                        frameIndex: record.frameIndex
                    )
                }
                _ = mirrorMilliseconds
                let mirrorBytes = try visibleBytes(mirror)
                let candidateBytes = try visibleBytes(candidateOutput)
                fullMirrorIdentityPass = fullMirrorIdentityPass
                    && mirrorBytes == candidateBytes
                captures.append(CaptureCase(
                    id: record.id,
                    outputs: outputs,
                    milliseconds: milliseconds
                ))
            }
            try await candidate.finish()
        }
        XCTAssertTrue(fullMirrorIdentityPass)
        let manifest = CaptureManifest(
            schemaVersion: "mirmir-ash-v4-quality-candidate-capture-v1",
            contractSHA256: expectedContract,
            corpusManifestSHA256: ASHSHA256V4(rawData: corpusData).rawValue,
            sourceCommit: setting(
                "MIRMIR_V4_QUALITY_SOURCE_COMMIT",
                injected: Self.injectedSourceCommit
            ) ?? "unknown",
            sourceTreeIdentitySHA256: try XCTUnwrap(
                setting(
                    "MIRMIR_V4_QUALITY_SOURCE_TREE_SHA256",
                    injected: Self.injectedSourceTreeSHA256
                )
            ),
            candidateBackendID: "mirmir_deterministic_cpu",
            candidateImplementationVersion: ASHRuntimeManifestV4.runtimeIdentity,
            runtimeManifestSHA256: runtime.manifestSHA256.rawValue,
            runtimeSourceRevision: runtime.manifest.provenance.sourceRevision,
            productionRuntimeLocked: productionRuntimeLocked,
            fullMirrorIdentityPass: fullMirrorIdentityPass,
            warmupCount: 5,
            cases: captures.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: output.appendingPathComponent("candidate-capture-manifest.json"),
            options: .atomic
        )
    }

    private func runWarmups(
        first: CorpusCase,
        corpusRoot: URL,
        runtime: ASHVerifiedRuntimeBundleV4,
        count: Int
    ) async throws {
        let storage = try storage(first.pixelFormat)
        let source = try makeBuffer(
            width: first.sourceWidth,
            height: first.sourceHeight,
            storage: storage,
            bytes: Data(contentsOf: corpusRoot.appendingPathComponent(first.sourceFile))
        )
        let candidate = try PreparedDeterministicV4Upscaler(
            configuration: DeterministicPreparedConfigurationV4(
                backendID: .mirmirDeterministicCPU,
                executionBackend: .cpu,
                storage: storage,
                sourceWidth: first.sourceWidth,
                sourceHeight: first.sourceHeight,
                targetWidth: first.targetWidth,
                targetHeight: first.targetHeight,
                scanMode: .progressive
            ),
            runtime: runtime
        )
        for index in 0..<count {
            let candidateOutput = try makeBuffer(
                width: first.targetWidth,
                height: first.targetHeight,
                storage: storage
            )
            try await candidate.process(
                source: FramePixelBuffer(source),
                destination: FramePixelBuffer(candidateOutput),
                timing: FrameTiming(
                    frameIndex: index,
                    presentationTime: CMTime(value: Int64(index), timescale: 30),
                    duration: CMTime(value: 1, timescale: 30)
                )
            )
        }
        try await candidate.finish()
    }

    private func setting(_ name: String, injected: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name],
           !value.isEmpty {
            return value
        }
        guard !injected.hasPrefix("__MIRMIR_") else { return nil }
        return injected
    }

    private func storage(_ id: String) throws -> PixelStorageV4 {
        switch id {
        case "420v": .nv12VideoRange8Bit
        case "420f": .nv12FullRange8Bit
        default: throw XCTSkip("unsupported quality storage \(id)")
        }
    }

    private func makeBuffer(
        width: Int,
        height: Int,
        storage: PixelStorageV4,
        bytes: Data? = nil
    ) throws -> CVPixelBuffer {
        let buffer = try SyntheticNV12PixelBuffer.make(
            width: width,
            height: height,
            pixelFormat: storage.pixelFormat
        )
        if let bytes {
            let expected = width * height * 3 / 2
            guard bytes.count == expected else {
                throw SyntheticPixelBufferError.invalidNV12Geometry(
                    width: width,
                    height: height,
                    rowAlignment: bytes.count
                )
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            var offset = 0
            for plane in 0..<2 {
                let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let components = plane == 0 ? 1 : 2
                let visibleRowBytes = planeWidth * components
                let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
                    .assumingMemoryBound(to: UInt8.self)
                bytes.withUnsafeBytes { raw in
                    let source = raw.bindMemory(to: UInt8.self)
                    for row in 0..<planeHeight {
                        base.advanced(by: row * stride).update(
                            from: source.baseAddress!.advanced(by: offset),
                            count: visibleRowBytes
                        )
                        offset += visibleRowBytes
                    }
                }
            }
        }
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferFieldCountKey,
            NSNumber(value: 1),
            .shouldPropagate
        )
        return buffer
    }

    private func visibleBytes(_ buffer: CVPixelBuffer) throws -> Data {
        Data(
            try SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 0)
                + SyntheticNV12PixelBuffer.visibleBytes(buffer, plane: 1)
        )
    }

    private func writeOutput(
        _ buffer: CVPixelBuffer,
        record: CorpusCase,
        variant: Variant,
        output: URL
    ) throws -> String {
        let relative = "artifacts/\(record.id)-\(variant.rawValue).nv12"
        try visibleBytes(buffer).write(
            to: output.appendingPathComponent(relative),
            options: .atomic
        )
        return relative
    }

    private func stableSeed(_ text: String) -> UInt64 {
        text.utf8.reduce(UInt64(0xcbf29ce484222325)) {
            ($0 ^ UInt64($1)) &* 0x100000001b3
        }
    }

    private func measured(
        _ operation: () async throws -> Void
    ) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }
}
