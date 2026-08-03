import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

/// This file is injected into an ephemeral copy of the test project by
/// `run_quality_gate_v4.sh`. It is intentionally absent from the shipping app
/// and test target so calibration controls cannot enter the release runtime.
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
        let baselineImplementationVersion: String
        let runtimeManifestSHA256: String
        let runtimeSourceRevision: String
        let productionRuntimeLocked: Bool
        let fullMirrorIdentityPass: Bool
        let warmupCount: Int
        let cases: [CaptureCase]
    }

    private enum Variant: String, CaseIterable {
        case baselineP05 = "baseline_p05"
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
            let measurementHistory: ASHMeasurementHistoryV4
            switch mode {
            case .temporalHysteresisOff:
                measurementHistory = .reset(.streamStart)
            default:
                if let previousMeasurementState {
                    measurementHistory = .continuous(
                        previousState: previousMeasurementState
                    )
                } else {
                    measurementHistory = .reset(.streamStart)
                }
            }
            let measurement = try ASHMeasurementExtractorV4.extract(
                frame: sourceSignal,
                previousFrame: {
                    if case .temporalHysteresisOff = mode { return nil }
                    return previousMeasurementFrame
                }(),
                contract: measurementContract,
                history: measurementHistory
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
            let exactPTS = try ExactRationalV4(Int64(frameIndex), 30)
            let frame = try ASHTemporalFrameV4(
                frameID: "quality-frame-\(frameIndex)",
                streamID: "quality-stream",
                formatIdentity: formatIdentity,
                ordinal: Int64(frameIndex),
                presentationTime: exactPTS,
                luma: spatial,
                tileStateRawValues: [state.rawValue],
                cadenceID: "progressive"
            )

            var resetReason: ASHTemporalResetReasonV4?
                = history.frames.isEmpty ? .streamStart : nil
            var aligned: ASHTemporalPlaneV4?
            var confidence: UInt32 = 0
            if case .motionHistoryOff = mode {
                aligned = nil
            } else if let previous = history.frames.last {
                let motion = try ASHTemporalMotionAnalyzerV4.analyze(
                    current: frame,
                    previous: previous
                )
                if motion.sceneCut {
                    resetReason = .sceneCut
                } else {
                    aligned = motion.alignedPrevious
                    let admitted = motion.vectors.filter { !$0.occluded }
                    if !admitted.isEmpty {
                        confidence = UInt32(
                            admitted.reduce(UInt64(0)) {
                                $0 + UInt64($1.confidenceQ16)
                            } / UInt64(admitted.count)
                        )
                    }
                }
            }

            let reconstructed: ASHTemporalPlaneV4
            if case .uniformPriors = mode {
                reconstructed = try uniformReconstruction(
                    spatial: spatial,
                    aligned: aligned,
                    confidenceQ16: confidence,
                    resetReason: resetReason
                )
            } else {
                reconstructed = try ASHTemporalReconstructorV4.reconstruct(
                    spatial: spatial,
                    alignedHistory: aligned,
                    sourceState: state,
                    motionConfidenceQ16: confidence,
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
            aligned: ASHTemporalPlaneV4?,
            confidenceQ16: UInt32,
            resetReason: ASHTemporalResetReasonV4?
        ) throws -> ASHTemporalPlaneV4 {
            guard resetReason == nil,
                  let aligned,
                  confidenceQ16 > 0 else {
                return spatial
            }
            guard spatial.width == aligned.width,
                  spatial.height == aligned.height else {
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
            let historyWeight = try roundedShift(
                UInt64(ASHTemporalReconstructorV4.maximumHistoryWeightQ16)
                    * stateWeightQ16 * UInt64(confidenceQ16),
                bits: 32
            )
            guard historyWeight > 0 else { return spatial }
            let scale = UInt64(ASHNormalizedQ16V4.scale)
            var samples: [UInt16] = []
            samples.reserveCapacity(spatial.samples.count)
            for index in spatial.samples.indices {
                let value = UInt64(spatial.samples[index])
                    * (scale - historyWeight)
                    + UInt64(aligned.samples[index]) * historyWeight
                samples.append(UInt16(try roundedShift(value, bits: 16)))
            }
            return try spatial.replacing(samples: samples)
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
        let runtime = try ASHV4SemanticArtifactTestSupport
            .executableSystemMetalRuntime()
        try runtime.verifyBinding()

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
            let p05 = ASHDeterministicUpscaleBackend(
                route: .direct2x,
                runtimeConfiguration: .developmentP05,
                operatorParameters: .p05DevelopmentOnly,
                stateInputEnabled: true
            )
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

                let baselineOutput = try makeBuffer(
                    width: record.targetWidth,
                    height: record.targetHeight,
                    storage: storage
                )
                milliseconds[Variant.baselineP05.rawValue] = try await measured {
                    let completion = try await p05.process(
                        source: source,
                        into: baselineOutput,
                        context: ASHUpscaleFrameContext(
                            frameIndex: record.frameIndex,
                            presentationTimestampValue: Int64(record.frameIndex),
                            presentationTimestampTimescale: 30
                        )
                    )
                    completion.finishAfterAppend()
                }
                outputs[Variant.baselineP05.rawValue] = try writeOutput(
                    baselineOutput,
                    record: record,
                    variant: .baselineP05,
                    output: output
                )

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
            schemaVersion: "mirmir-ash-v4-quality-capture-v1",
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
            baselineImplementationVersion: "ash-p05-cpu-reference-preview",
            runtimeManifestSHA256: runtime.manifestSHA256.rawValue,
            runtimeSourceRevision: runtime.manifest.provenance.sourceRevision,
            productionRuntimeLocked: false,
            fullMirrorIdentityPass: fullMirrorIdentityPass,
            warmupCount: 5,
            cases: captures.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: output.appendingPathComponent("capture-manifest.json"),
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
        let p05 = ASHDeterministicUpscaleBackend(route: .direct2x)
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
            let p05Output = try makeBuffer(
                width: first.targetWidth,
                height: first.targetHeight,
                storage: storage
            )
            let completion = try await p05.process(
                source: source,
                into: p05Output,
                context: ASHUpscaleFrameContext(frameIndex: index)
            )
            completion.finishAfterAppend()
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
