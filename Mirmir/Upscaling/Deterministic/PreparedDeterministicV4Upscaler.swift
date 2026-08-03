import CoreMedia
import CoreVideo
import Foundation
import Metal

enum ASHPreparedTemporalCheckpointV4Error: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case identityMismatch
    case invalidState
    case nonCanonicalEncoding
}

/// Complete state needed to make the next emitted pixel independent of
/// whether execution crossed a process boundary. This deliberately includes
/// source-domain measurement and field history in addition to reconstructed
/// luma history; either omission changes temporal evidence after resume.
struct ASHPreparedTemporalCheckpointV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID = "ash.prepared-temporal-checkpoint.v4.1"

    let schemaID: String
    let planSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let formatIdentity: ASHSHA256V4
    let sourceStorage: PixelStorageV4
    let sourceWidth: Int
    let sourceHeight: Int
    let scanModeID: String
    let lastCompletedInputOrdinal: Int64
    let nextOutputOrdinal: Int64
    let lastCompletedOutputPresentationTime: ExactRationalV4
    let history: ASHTemporalHistoryV4
    let previousMeasurementFrame: PixelBufferSignalFrameV4?
    let previousMeasurementStateRawValue: UInt16?
    let previousInterlacedFrame: PixelBufferSignalFrameV4?

    init(
        planSHA256: ASHSHA256V4,
        runtimeManifestSHA256: ASHSHA256V4,
        formatIdentity: ASHSHA256V4,
        sourceStorage: PixelStorageV4,
        sourceWidth: Int,
        sourceHeight: Int,
        scanModeID: String,
        lastCompletedInputOrdinal: Int64,
        nextOutputOrdinal: Int64,
        lastCompletedOutputPresentationTime: ExactRationalV4,
        history: ASHTemporalHistoryV4,
        previousMeasurementFrame: PixelBufferSignalFrameV4?,
        previousMeasurementStateRawValue: UInt16?,
        previousInterlacedFrame: PixelBufferSignalFrameV4?
    ) throws {
        schemaID = Self.currentSchemaID
        self.planSHA256 = planSHA256
        self.runtimeManifestSHA256 = runtimeManifestSHA256
        self.formatIdentity = formatIdentity
        self.sourceStorage = sourceStorage
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.scanModeID = scanModeID
        self.lastCompletedInputOrdinal = lastCompletedInputOrdinal
        self.nextOutputOrdinal = nextOutputOrdinal
        self.lastCompletedOutputPresentationTime
            = lastCompletedOutputPresentationTime
        self.history = history
        self.previousMeasurementFrame = previousMeasurementFrame
        self.previousMeasurementStateRawValue
            = previousMeasurementStateRawValue
        self.previousInterlacedFrame = previousInterlacedFrame
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID else {
            throw ASHPreparedTemporalCheckpointV4Error.unsupportedSchema(
                schemaID
            )
        }
        guard sourceWidth > 0,
              sourceHeight > 0,
              lastCompletedInputOrdinal >= 0,
              nextOutputOrdinal > 0,
              lastCompletedOutputPresentationTime >= .zero,
              ASHTemporalFrameV4.validIdentifier(scanModeID) else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        try history.validate()
        guard let latest = history.frames.last,
              latest.ordinal == nextOutputOrdinal - 1,
              latest.presentationTime
                == lastCompletedOutputPresentationTime,
              previousMeasurementFrame != nil,
              previousMeasurementStateRawValue != nil else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        if let raw = previousMeasurementStateRawValue {
            let state = try ASHState(rawValue: raw)
            guard state.hasValidIntegrity,
                  latest.tileStateRawValues.last == raw else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
        }
        try validateSourceFrame(previousMeasurementFrame)
        try validateSourceFrame(previousInterlacedFrame)
        if scanModeID == "progressive" {
            guard previousInterlacedFrame == nil else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
        } else if scanModeID.hasPrefix("interlaced_") {
            guard previousInterlacedFrame != nil else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
        } else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
    }

    var canonicalData: Data {
        get throws {
            try validate()
            return try ASHCanonicalJSONV4.encode(self)
        }
    }

    static func decodeCanonical(
        _ data: Data,
        expectedPlanSHA256: ASHSHA256V4,
        expectedRuntimeManifestSHA256: ASHSHA256V4,
        expectedFormatIdentity: ASHSHA256V4
    ) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        try decoded.validate()
        guard decoded.planSHA256 == expectedPlanSHA256,
              decoded.runtimeManifestSHA256
                == expectedRuntimeManifestSHA256,
              decoded.formatIdentity == expectedFormatIdentity else {
            throw ASHPreparedTemporalCheckpointV4Error.identityMismatch
        }
        guard try ASHCanonicalJSONV4.encode(decoded) == data else {
            throw ASHPreparedTemporalCheckpointV4Error.nonCanonicalEncoding
        }
        return decoded
    }

    private func validateSourceFrame(
        _ frame: PixelBufferSignalFrameV4?
    ) throws {
        guard let frame else { return }
        try frame.validate()
        guard frame.storage == sourceStorage,
              frame.width == sourceWidth,
              frame.height == sourceHeight else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
    }
}

actor PreparedDeterministicV4Upscaler:
    PreparedCheckpointableTemporalFrameUpscaler,
    PreparedDeterministicV4PlanningBackend {
    nonisolated let sourcePixelBufferAttributes: PixelBufferAttributes
    nonisolated let destinationPixelBufferAttributes: PixelBufferAttributes
    nonisolated let actualBackendID: UpscaleBackendID
    nonisolated let deterministicConfiguration: DeterministicConfiguration
    nonisolated let deterministicStorage: PixelStorageV4
    nonisolated let deterministicExecutor: ASHExecutorV4
    nonisolated let maximumOutputFramesPerInput: Int

    private let configuration: DeterministicPreparedConfigurationV4
    private let runtime: ASHVerifiedRuntimeBundleV4
    private let measurementContract: ASHMeasurementContractV4
    private let branchProgram: ASHDepthFourBranchProgramV4
    private let scaler: FixedPointPixelBufferScalerV4
    private let formatIdentity: ASHSHA256V4

    private var temporalHistory: ASHTemporalHistoryV4
    private var previousMeasurementFrame: PixelBufferSignalFrameV4?
    private var previousMeasurementState: ASHState?
    private var previousInterlacedFrame: PixelBufferSignalFrameV4?
    private var outputOrdinal: Int64 = 0
    private var lastOutputPresentationTime = ExactRationalV4.zero
    private var finished = false

    private var scanModeIdentity: String {
        switch configuration.scanMode {
        case .progressive:
            "progressive"
        case .interlaced(.topFieldFirst):
            "interlaced_tff_double_rate"
        case .interlaced(.bottomFieldFirst):
            "interlaced_bff_double_rate"
        }
    }

    init(
        configuration: DeterministicPreparedConfigurationV4,
        runtime: ASHVerifiedRuntimeBundleV4,
        metalDevice: MTLDevice? = nil,
        metalLibrary: MTLLibrary? = nil
    ) throws {
        try runtime.verifyBinding()
        let contract = try runtime.measurementContract()
        let program = try runtime.branchProgram()
        self.configuration = configuration
        self.runtime = runtime
        self.measurementContract = contract
        self.branchProgram = program
        self.sourcePixelBufferAttributes = configuration.sourceAttributes
        self.destinationPixelBufferAttributes = configuration
            .destinationAttributes
        self.actualBackendID = configuration.backendID
        self.deterministicStorage = configuration.storage
        self.deterministicExecutor = configuration.executionBackend == .cpu
            ? .cpuFixedPoint
            : .metalFixedPoint
        self.maximumOutputFramesPerInput = configuration.scanMode
            == .progressive ? 1 : 2
        self.temporalHistory = try ASHTemporalHistoryV4(capacity: 3)
        self.scaler = try FixedPointPixelBufferScalerV4(
            backend: configuration.executionBackend,
            storage: configuration.storage,
            sourceWidth: configuration.sourceWidth,
            sourceHeight: configuration.sourceHeight,
            targetWidth: configuration.targetWidth,
            targetHeight: configuration.targetHeight,
            borderRule: .reflect101,
            metalDevice: metalDevice,
            metalLibrary: metalLibrary
        )
        self.formatIdentity = ASHSHA256V4(rawData: Data(
            [
                ASHRuntimeManifestV4.runtimeIdentity,
                runtime.manifestSHA256.rawValue,
                configuration.storage.rawValue,
                String(configuration.sourceWidth),
                String(configuration.sourceHeight),
                String(configuration.targetWidth),
                String(configuration.targetHeight),
                configuration.scaleRouteIdentity
            ].joined(separator: "|").utf8
        ))
        self.deterministicConfiguration = DeterministicConfiguration(
            implementationVersion: ASHRuntimeManifestV4.runtimeIdentity,
            scaleRoute: configuration.scaleRouteIdentity,
            sourcePixelFormat: configuration.storage.pixelFormat,
            destinationPixelFormat: configuration.storage.pixelFormat,
            stateInputEnabled: true,
            mappingSchemaVersion: contract.contractID,
            operatorBankSchemaVersion: program.operatorManifest.manifestID,
            runtimeManifestSHA256: runtime.manifestSHA256.rawValue,
            fixedPointKernelID: ASHExecutionRequestV4
                .canonicalKernelContractID,
            temporalPolicyID: ASHTemporalBlockMatchingConfigurationV4
                .canonical.policyID
        )
    }

    func makeASHExecutionPlan(
        media: CanonicalMediaStateV4,
        request: ASHExecutionRequestV4
    ) throws -> ASHIdentifiedExecutionPlanV4 {
        try ASHExecutionPlannerV4.makePlan(
            media: media,
            request: request,
            runtime: runtime
        )
    }

    func process(
        source: FramePixelBuffer,
        destination: FramePixelBuffer,
        timing: FrameTiming
    ) async throws {
        guard maximumOutputFramesPerInput == 1 else {
            throw configuration.processingError(
                "interlaced input must use the two-output temporal interface",
                frameIndex: timing.frameIndex
            )
        }
        _ = try await processTemporal(
            source: source,
            destinations: [destination],
            timing: timing
        )
    }

    func processTemporal(
        source: FramePixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming
    ) async throws -> [TemporalOutputFrame] {
        do {
            guard !finished else {
                throw configuration.processingError(
                    "the prepared P06 v4 adapter is already finished",
                    frameIndex: timing.frameIndex
                )
            }
            guard destinations.count >= maximumOutputFramesPerInput else {
                throw configuration.processingError(
                    "the caller supplied \(destinations.count) destination "
                        + "buffers; v4 requires \(maximumOutputFramesPerInput)",
                    frameIndex: timing.frameIndex
                )
            }
            try Task.checkCancellation()
            switch configuration.scanMode {
            case .progressive:
                return [try await processProgressive(
                    source: source.value,
                    destination: destinations[0].value,
                    presentationTime: timing.presentationTime,
                    sourceFrameIndex: timing.frameIndex,
                    cadenceID: "progressive",
                    resetTrigger: previousMeasurementFrame == nil
                        ? .streamStart : nil
                )]
            case .interlaced(let dominance):
                return try await processInterlaced(
                    source: source.value,
                    destinations: destinations,
                    timing: timing,
                    dominance: dominance
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MirmirError {
            throw error
        } catch {
            throw configuration.processingError(
                "P06 v4 processing failed: \(String(describing: error))",
                frameIndex: timing.frameIndex
            )
        }
    }

    func finish() async throws {
        guard !finished else { return }
        try Task.checkCancellation()
        try temporalHistory.reset(reason: .explicitReset)
        previousMeasurementFrame = nil
        previousMeasurementState = nil
        previousInterlacedFrame = nil
        finished = true
    }

    func makeTemporalCheckpoint(
        planSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64
    ) async throws -> Data {
        guard !finished else {
            throw configuration.processingError(
                "a finished engine cannot produce a resumable checkpoint"
            )
        }
        return try ASHPreparedTemporalCheckpointV4(
            planSHA256: planSHA256,
            runtimeManifestSHA256: runtime.manifestSHA256,
            formatIdentity: formatIdentity,
            sourceStorage: configuration.storage,
            sourceWidth: configuration.sourceWidth,
            sourceHeight: configuration.sourceHeight,
            scanModeID: scanModeIdentity,
            lastCompletedInputOrdinal: lastCompletedInputOrdinal,
            nextOutputOrdinal: outputOrdinal,
            lastCompletedOutputPresentationTime: lastOutputPresentationTime,
            history: temporalHistory,
            previousMeasurementFrame: previousMeasurementFrame,
            previousMeasurementStateRawValue:
                previousMeasurementState?.rawValue,
            previousInterlacedFrame: previousInterlacedFrame
        ).canonicalData
    }

    func restoreTemporalCheckpoint(
        _ data: Data,
        planSHA256: ASHSHA256V4
    ) async throws {
        guard !finished else {
            throw configuration.processingError(
                "a finished engine cannot restore a checkpoint"
            )
        }
        let checkpoint = try ASHPreparedTemporalCheckpointV4.decodeCanonical(
            data,
            expectedPlanSHA256: planSHA256,
            expectedRuntimeManifestSHA256: runtime.manifestSHA256,
            expectedFormatIdentity: formatIdentity
        )
        guard checkpoint.sourceStorage == configuration.storage,
              checkpoint.sourceWidth == configuration.sourceWidth,
              checkpoint.sourceHeight == configuration.sourceHeight,
              checkpoint.scanModeID == scanModeIdentity else {
            throw ASHPreparedTemporalCheckpointV4Error.identityMismatch
        }
        temporalHistory = checkpoint.history
        outputOrdinal = checkpoint.nextOutputOrdinal
        lastOutputPresentationTime = checkpoint
            .lastCompletedOutputPresentationTime
        previousMeasurementFrame = checkpoint.previousMeasurementFrame
        previousMeasurementState = try checkpoint
            .previousMeasurementStateRawValue.map(ASHState.init(rawValue:))
        previousInterlacedFrame = checkpoint.previousInterlacedFrame
    }

    private func processInterlaced(
        source: CVPixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming,
        dominance: FieldDominanceV4
    ) async throws -> [TemporalOutputFrame] {
        let effectiveDominance = try resolvedFieldDominance(
            from: source,
            fallback: dominance
        )
        let cadenceID = effectiveDominance == .topFieldFirst
            ? "interlaced_tff_double_rate"
            : "interlaced_bff_double_rate"
        let previousCadenceID = temporalHistory.frames.last?.cadenceID
        let cadenceChanged = previousInterlacedFrame != nil
            && previousCadenceID != nil
            && previousCadenceID != cadenceID
        let signal = try PixelBufferSignalCodecV4.read(
            source,
            storage: configuration.storage
        )
        let duration = timing.duration.isNumeric
            && timing.duration.value > 0
            ? timing.duration
            : CMTime(value: 1, timescale: 30)
        guard timing.presentationTime.isNumeric,
              timing.presentationTime.timescale > 0 else {
            throw configuration.processingError(
                "interlaced input has an invalid presentation timestamp",
                frameIndex: timing.frameIndex
            )
        }
        let fieldTiming = try exactInterlacedTiming(
            presentationTime: timing.presentationTime,
            duration: duration
        )
        var outputPlanes = Array(
            repeating: [PixelBufferSignalPlaneV4](),
            count: 2
        )
        var outputTimings: [ProgressiveFieldTimingV4]?
        for planeIndex in signal.planes.indices {
            let plane = signal.planes[planeIndex]
            guard plane.height > 1,
                  Set(plane.componentBounds).count == 1,
                  let bounds = plane.componentBounds.first else {
                throw configuration.processingError(
                    "field normalization cannot represent plane \(planeIndex)",
                    frameIndex: timing.frameIndex
                )
            }
            let current = try FieldPlaneV4(
                width: plane.width,
                height: plane.height,
                componentsPerSample: plane.componentsPerElement,
                minimumCode: bounds.minimum,
                maximumCode: bounds.maximum,
                samples: plane.samples
            )
            let priorPlane = cadenceChanged
                ? nil : previousInterlacedFrame?.planes[planeIndex]
            let prior: FieldPlaneV4?
            if let priorPlane {
                prior = try FieldPlaneV4(
                    width: priorPlane.width,
                    height: priorPlane.height,
                    componentsPerSample: priorPlane.componentsPerElement,
                    minimumCode: bounds.minimum,
                    maximumCode: bounds.maximum,
                    samples: priorPlane.samples
                )
            } else {
                prior = nil
            }
            let fields = try DeterministicDeinterlacerV4.deinterlace(
                previous: prior,
                current: current,
                // No future frame is observed. Reusing the sole prior as the
                // second temporal vote makes agreement explicit and retains
                // immediate two-field output without a hidden lookahead.
                next: prior,
                dominance: effectiveDominance,
                timing: fieldTiming,
                thresholds: DeinterlaceThresholdsV4(
                    motionCodeDifference: configuration.storage.signalBitDepth
                        == 10 ? 16 : 4,
                    sceneCutMeanAbsoluteDifference:
                        configuration.storage.signalBitDepth == 10 ? 128 : 32
                )
            )
            let timings = fields.map(\.timing)
            if let outputTimings {
                guard outputTimings == timings else {
                    throw ASHPreparedTemporalCheckpointV4Error.invalidState
                }
            } else {
                outputTimings = timings
            }
            for outputIndex in fields.indices {
                outputPlanes[outputIndex].append(
                    try PixelBufferSignalPlaneV4(
                        width: plane.width,
                        height: plane.height,
                        componentsPerElement: plane.componentsPerElement,
                        componentBounds: plane.componentBounds,
                        samples: fields[outputIndex].progressivePlane.samples
                    )
                )
            }
        }
        previousInterlacedFrame = signal

        var outputs: [TemporalOutputFrame] = []
        outputs.reserveCapacity(2)
        for outputIndex in 0..<2 {
            let normalized = PixelBufferSignalFrameV4(
                storage: configuration.storage,
                width: configuration.sourceWidth,
                height: configuration.sourceHeight,
                planes: outputPlanes[outputIndex]
            )
            let temporary = try PixelBufferSignalCodecV4.makeBuffer(
                storage: configuration.storage,
                width: configuration.sourceWidth,
                height: configuration.sourceHeight,
                metalCompatible: configuration.executionBackend == .metal
            )
            try PixelBufferSignalCodecV4.write(
                normalized,
                to: temporary,
                copyAttachmentsFrom: source
            )
            CVBufferSetAttachment(
                temporary,
                kCVImageBufferFieldCountKey,
                NSNumber(value: 1),
                .shouldPropagate
            )
            CVBufferRemoveAttachment(temporary, kCVImageBufferFieldDetailKey)
            guard let outputTiming = outputTimings?[outputIndex] else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            let presentation = CMTime(
                value: outputTiming.presentationValue,
                timescale: outputTiming.timescale
            )
            outputs.append(try await processProgressive(
                source: temporary,
                destination: destinations[outputIndex].value,
                presentationTime: presentation,
                sourceFrameIndex: timing.frameIndex,
                cadenceID: cadenceID,
                resetTrigger: outputIndex == 0
                    && (cadenceChanged || previousMeasurementFrame == nil)
                    ? .fieldCadenceChange : nil
            ))
        }
        return outputs
    }

    private func resolvedFieldDominance(
        from source: CVPixelBuffer,
        fallback: FieldDominanceV4
    ) throws -> FieldDominanceV4 {
        if let count = CVBufferCopyAttachment(
            source,
            kCVImageBufferFieldCountKey,
            nil
        ) as? NSNumber, count.intValue != 2 {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        guard let detail = CVBufferCopyAttachment(
            source,
            kCVImageBufferFieldDetailKey,
            nil
        ) as? String else {
            return fallback
        }
        if detail == kCVImageBufferFieldDetailTemporalTopFirst as String
            || detail
                == kCVImageBufferFieldDetailSpatialFirstLineEarly as String {
            return .topFieldFirst
        }
        if detail == kCVImageBufferFieldDetailTemporalBottomFirst as String
            || detail
                == kCVImageBufferFieldDetailSpatialFirstLineLate as String {
            return .bottomFieldFirst
        }
        throw ASHPreparedTemporalCheckpointV4Error.invalidState
    }

    private func processProgressive(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        presentationTime: CMTime,
        sourceFrameIndex: Int,
        cadenceID: String,
        resetTrigger: ASHMeasurementResetTriggerV4?
    ) async throws -> TemporalOutputFrame {
        let sourceSignal = try PixelBufferSignalCodecV4.read(
            source,
            storage: configuration.storage
        )
        let exactPTS = try ExactRationalV4(
            presentationTime.value,
            Int64(presentationTime.timescale)
        )
        let sourceTemporalPlane = try temporalLumaPlane(from: sourceSignal)
        let neutralState = try ASHState(rawValue: 0)
        let sourceTemporalFrame = try ASHTemporalFrameV4(
            frameID: "v4-measurement-\(outputOrdinal)",
            streamID: "primary-video-measurement",
            formatIdentity: formatIdentity,
            ordinal: outputOrdinal,
            presentationTime: exactPTS,
            luma: sourceTemporalPlane,
            tileStateRawValues: [
                previousMeasurementState?.rawValue ?? neutralState.rawValue
            ],
            cadenceID: cadenceID
        )
        var measurementMotion: ASHTemporalMotionAnalysisV4?
        if resetTrigger == nil,
           outputOrdinal > 0,
           lastOutputPresentationTime < exactPTS,
           let previousMeasurementFrame {
            let previousSourceFrame = try ASHTemporalFrameV4(
                frameID: "v4-measurement-\(outputOrdinal - 1)",
                streamID: sourceTemporalFrame.streamID,
                formatIdentity: sourceTemporalFrame.formatIdentity,
                ordinal: outputOrdinal - 1,
                presentationTime: lastOutputPresentationTime,
                luma: try temporalLumaPlane(
                    from: previousMeasurementFrame
                ),
                tileStateRawValues: [
                    previousMeasurementState?.rawValue
                        ?? neutralState.rawValue
                ],
                cadenceID: cadenceID
            )
            measurementMotion = try ASHTemporalMotionAnalyzerV4.analyze(
                current: sourceTemporalFrame,
                previous: previousSourceFrame
            )
        }
        let effectiveMeasurementReset: ASHMeasurementResetTriggerV4?
        if let resetTrigger {
            effectiveMeasurementReset = resetTrigger
        } else if measurementMotion?.sceneCut == true {
            effectiveMeasurementReset = .sceneCut
        } else {
            effectiveMeasurementReset = nil
        }
        let measurementHistory: ASHMeasurementHistoryV4
        if let effectiveMeasurementReset {
            measurementHistory = .reset(effectiveMeasurementReset)
        } else if let previousMeasurementState {
            measurementHistory = .continuous(
                previousState: previousMeasurementState
            )
        } else {
            measurementHistory = .reset(.streamStart)
        }
        let canonicalTemporalEvidenceQ16: UInt32?
        if let measurementMotion {
            canonicalTemporalEvidenceQ16
                = measurementMotion.temporalEvidenceQ16
        } else if effectiveMeasurementReset != nil {
            canonicalTemporalEvidenceQ16 = 0
        } else {
            canonicalTemporalEvidenceQ16 = nil
        }
        let measurement = try ASHMeasurementExtractorV4.extract(
            frame: sourceSignal,
            previousFrame: previousMeasurementFrame,
            contract: measurementContract,
            history: measurementHistory,
            motionCompensatedTemporalEvidenceQ16:
                canonicalTemporalEvidenceQ16
        )

        try await scaler.process(source: source, destination: destination)
        let outputSignal = try PixelBufferSignalCodecV4.read(
            destination,
            storage: configuration.storage
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
        let conditionedSpatial = try ASHSpatialReconstructorV4.reconstruct(
            spatial: spatial,
            sourceState: measurement.projection.state,
            program: branchProgram
        ).output
        let frame = try ASHTemporalFrameV4(
            frameID: "v4-frame-\(outputOrdinal)",
            streamID: "primary-video",
            formatIdentity: formatIdentity,
            ordinal: outputOrdinal,
            presentationTime: exactPTS,
            luma: conditionedSpatial,
            tileStateRawValues: [measurement.projection.state.rawValue],
            cadenceID: cadenceID
        )

        var resetReason = effectiveMeasurementReset.map(temporalResetReason)
        var motionAnalysis: ASHTemporalMotionAnalysisV4?
        let dynamicMetadata = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: source)
        // Dynamic HDR metadata is frame-bound. Preserve it exactly by using
        // the spatial path for that frame rather than blending content under
        // metadata that the engine cannot regenerate.
        if dynamicMetadata != nil {
            resetReason = .colorDomainChange
        } else if resetReason == nil,
                  let previous = temporalHistory.frames.last {
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
        let reconstructed = try ASHTemporalReconstructorV4.reconstruct(
            spatial: conditionedSpatial,
            motionAnalysis: motionAnalysis,
            sourceState: measurement.projection.state,
            resetReason: resetReason,
            program: branchProgram
        )
        var reconstructedPlanes = outputSignal.planes
        reconstructedPlanes[0] = try lumaPlane.replacingComponent(
            0,
            with: reconstructed.output.samples
        )
        try PixelBufferSignalCodecV4.write(
            PixelBufferSignalFrameV4(
                storage: outputSignal.storage,
                width: outputSignal.width,
                height: outputSignal.height,
                planes: reconstructedPlanes
            ),
            to: destination
        )

        if let resetReason {
            try temporalHistory.reset(reason: resetReason)
        }
        let emittedFrame = try ASHTemporalFrameV4(
            frameID: frame.frameID,
            streamID: frame.streamID,
            formatIdentity: frame.formatIdentity,
            ordinal: frame.ordinal,
            presentationTime: frame.presentationTime,
            luma: reconstructed.output,
            tileStateRawValues: frame.tileStateRawValues,
            cadenceID: frame.cadenceID
        )
        try temporalHistory.append(emittedFrame)
        previousMeasurementFrame = sourceSignal
        previousMeasurementState = measurement.projection.state
        outputOrdinal += 1
        lastOutputPresentationTime = exactPTS
        return TemporalOutputFrame(
            pixelBuffer: FramePixelBuffer(destination),
            presentationTime: presentationTime
        )
    }

    private func temporalLumaPlane(
        from frame: PixelBufferSignalFrameV4
    ) throws -> ASHTemporalPlaneV4 {
        guard let luma = frame.planes.first,
              luma.componentsPerElement == 1,
              let bounds = luma.componentBounds.first else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        return try ASHTemporalPlaneV4(
            width: luma.width,
            height: luma.height,
            minimumCode: bounds.minimum,
            maximumCode: bounds.maximum,
            samples: try luma.component(0)
        )
    }

    private func temporalResetReason(
        _ trigger: ASHMeasurementResetTriggerV4
    ) -> ASHTemporalResetReasonV4 {
        switch trigger {
        case .streamStart: .streamStart
        case .discontinuity: .discontinuity
        case .seek: .seek
        case .sceneCut: .sceneCut
        case .geometryChange: .geometryChange
        case .pixelFormatChange: .pixelFormatChange
        case .colorDomainChange: .colorDomainChange
        case .fieldCadenceChange: .fieldCadenceChange
        case .contractChange: .contractChange
        case .explicitReset: .explicitReset
        }
    }

    private func exactInterlacedTiming(
        presentationTime: CMTime,
        duration: CMTime
    ) throws -> InterlacedFrameTimingV4 {
        guard presentationTime.isNumeric,
              duration.isNumeric,
              presentationTime.timescale > 0,
              duration.timescale > 0,
              duration.value > 0 else {
            throw DeterministicDeinterlacerV4Error.invalidTiming(
                presentationValue: presentationTime.value,
                durationValue: duration.value,
                timescale: presentationTime.timescale
            )
        }
        let firstScale = Int64(presentationTime.timescale)
        let secondScale = Int64(duration.timescale)
        let divisor = greatestCommonDivisor(firstScale, secondScale)
        let scaled = firstScale.multipliedReportingOverflow(
            by: secondScale / divisor
        )
        guard !scaled.overflow,
              scaled.partialValue > 0,
              scaled.partialValue <= Int64(Int32.max) / 2 else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        let commonScale = scaled.partialValue
        let presentationMultiplier = commonScale / firstScale
        let durationMultiplier = commonScale / secondScale
        let commonPresentation = presentationTime.value
            .multipliedReportingOverflow(by: presentationMultiplier)
        let commonDuration = duration.value
            .multipliedReportingOverflow(by: durationMultiplier)
        guard !commonPresentation.overflow,
              !commonDuration.overflow else {
            throw DeterministicDeinterlacerV4Error.arithmeticOverflow
        }
        return try InterlacedFrameTimingV4(
            presentationValue: commonPresentation.partialValue,
            durationValue: commonDuration.partialValue,
            timescale: Int32(commonScale)
        )
    }

    private func greatestCommonDivisor(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        var left = lhs
        var right = rhs
        while right != 0 {
            (left, right) = (right, left % right)
        }
        return left
    }
}

typealias PreparedDeterministicCPUUpscaler = PreparedDeterministicV4Upscaler
typealias PreparedDeterministicMetalUpscaler = PreparedDeterministicV4Upscaler
