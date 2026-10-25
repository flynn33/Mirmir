import CoreMedia
import CoreVideo
import Foundation
import Metal

enum ASHPreparedTemporalCheckpointV4Error: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case identityMismatch
    case invalidState
    case nonCanonicalEncoding
    case operationInProgress
    case destinationAlias
    case pixelBufferLockFailed(role: String, status: CVReturn)
    case inputOrdinalMismatch(expected: Int64, actual: Int64)
    case ordinalOverflow
}

/// Complete state needed to make the next emitted pixel independent of
/// whether execution crossed a process boundary. This deliberately includes
/// source-domain measurement and field history in addition to reconstructed
/// luma history; either omission changes temporal evidence after resume.
struct ASHPreparedTemporalCheckpointV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID = "ash.prepared-temporal-checkpoint.v4.5"

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
    let previousMeasurementHistory: ASHCompactMeasurementHistoryV4?
    let previousSourceLumaFrame: ASHTemporalFrameV4?
    let previousMeasurementStateRawValue: UInt16?
    let previousInterlacedFrame: PixelBufferSignalFrameV4?
    let fieldCadenceState: DeterministicFieldCadenceStateV4?

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
        previousMeasurementHistory: ASHCompactMeasurementHistoryV4?,
        previousSourceLumaFrame: ASHTemporalFrameV4?,
        previousMeasurementStateRawValue: UInt16?,
        previousInterlacedFrame: PixelBufferSignalFrameV4?,
        fieldCadenceState: DeterministicFieldCadenceStateV4?
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
        self.previousMeasurementHistory = previousMeasurementHistory
        self.previousSourceLumaFrame = previousSourceLumaFrame
        self.previousMeasurementStateRawValue
            = previousMeasurementStateRawValue
        self.previousInterlacedFrame = previousInterlacedFrame
        self.fieldCadenceState = fieldCadenceState
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
        do {
            try history.validate()
            try previousMeasurementHistory?.validate()
            try previousSourceLumaFrame?.validate()
            try validateSourceFrame(previousInterlacedFrame)
        } catch {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let completedInputCount = lastCompletedInputOrdinal
            .addingReportingOverflow(1)
        guard !completedInputCount.overflow,
              completedInputCount.partialValue > 0,
              let completedInputCountUnsigned = UInt64(
                exactly: completedInputCount.partialValue
              ) else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let outputsPerInput: Int64
        switch scanModeID {
        case "progressive":
            outputsPerInput = 1
        case "interlaced_tff_double_rate", "interlaced_bff_double_rate":
            outputsPerInput = 2
        default:
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let expectedOutputCount = completedInputCount.partialValue
            .multipliedReportingOverflow(by: outputsPerInput)
        let nextInputOrdinal = lastCompletedInputOrdinal
            .addingReportingOverflow(1)
        let nextOutputOrdinalWithHeadroom = nextOutputOrdinal
            .addingReportingOverflow(outputsPerInput)
        guard !expectedOutputCount.overflow,
              expectedOutputCount.partialValue == nextOutputOrdinal,
              !nextInputOrdinal.overflow,
              !nextOutputOrdinalWithHeadroom.overflow else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        guard let latest = history.frames.last,
              latest.ordinal == nextOutputOrdinal - 1,
              latest.presentationTime
                == lastCompletedOutputPresentationTime,
              previousMeasurementHistory != nil,
              previousSourceLumaFrame != nil,
              previousMeasurementStateRawValue != nil else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        guard let raw = previousMeasurementStateRawValue,
              let state = try? ASHState(rawValue: raw),
              state.hasValidIntegrity,
              latest.tileStateRawValues.last == raw else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let expectedCadenceID: String
        if scanModeID == "progressive" {
            guard previousInterlacedFrame == nil,
                  fieldCadenceState == nil else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            expectedCadenceID = "progressive"
        } else {
            guard let previousInterlacedFrame,
                  let luma = previousInterlacedFrame.planes.first,
                  let lumaBounds = luma.componentBounds.first,
                  let expectedRepeatThresholdQ16 = try?
                    DeterministicFieldCadenceClassifierV4
                        .normalizedRepeatThresholdQ16(
                            minimumCode: lumaBounds.minimum,
                            maximumCode: lumaBounds.maximum,
                            repeatCodeDifference:
                                sourceStorage.signalBitDepth == 10 ? 16 : 4
                        ),
                  let fieldCadenceState,
                  (try? fieldCadenceState.validate()) != nil,
                  fieldCadenceState.streamInputFrameCount
                    == completedInputCountUnsigned,
                  fieldCadenceState.observations.allSatisfy({
                    $0.normalizedRepeatThresholdQ16
                        == expectedRepeatThresholdQ16
                  }),
                  latest.cadenceID == fieldCadenceState.cadenceID else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            expectedCadenceID = fieldCadenceState.cadenceID
        }
        try validateProductionTemporalHistory(
            expectedCadenceID: expectedCadenceID
        )
        try validateProductionMeasurementHistory(
            expectedCadenceID: expectedCadenceID,
            expectedStateRawValue: raw
        )
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

    /// Synthesized `Codable` initializers do not execute the throwing temporal
    /// plane/frame initializers. Reconstruct every decoded value here before it
    /// can become actor state, then enforce the narrower state shape emitted by
    /// this prepared engine. This keeps malformed durable data from reaching
    /// unchecked sample access in motion analysis.
    private func validateProductionTemporalHistory(
        expectedCadenceID: String
    ) throws {
        guard history.capacity == 1,
              history.generation > 0,
              history.generation < UInt64.max,
              history.lastResetReason == nil,
              history.frames.count == 1,
              let historyCount = Int64(exactly: history.frames.count) else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let firstOrdinal = nextOutputOrdinal.subtractingReportingOverflow(
            historyCount
        )
        guard !firstOrdinal.overflow, firstOrdinal.partialValue >= 0 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }

        for (index, frame) in history.frames.enumerated() {
            let validatedFrame: ASHTemporalFrameV4
            do {
                let validatedLuma = try ASHTemporalPlaneV4(
                    width: frame.luma.width,
                    height: frame.luma.height,
                    minimumCode: frame.luma.minimumCode,
                    maximumCode: frame.luma.maximumCode,
                    samples: frame.luma.samples
                )
                validatedFrame = try ASHTemporalFrameV4(
                    frameID: frame.frameID,
                    streamID: frame.streamID,
                    formatIdentity: frame.formatIdentity,
                    ordinal: frame.ordinal,
                    presentationTime: frame.presentationTime,
                    luma: validatedLuma,
                    tileStateRawValues: frame.tileStateRawValues,
                    cadenceID: frame.cadenceID
                )
            } catch {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            let ordinalOffset = Int64(index)
            let expectedOrdinal = firstOrdinal.partialValue
                .addingReportingOverflow(ordinalOffset)
            guard !expectedOrdinal.overflow,
                  validatedFrame == frame,
                  frame.ordinal == expectedOrdinal.partialValue,
                  frame.frameID == "v4-frame-\(frame.ordinal)",
                  frame.streamID == "primary-video",
                  frame.formatIdentity == formatIdentity,
                  frame.tileStateRawValues.count == 1,
                  frame.cadenceID == expectedCadenceID else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
        }
    }

    private func validateProductionMeasurementHistory(
        expectedCadenceID: String,
        expectedStateRawValue: UInt16
    ) throws {
        guard let compact = previousMeasurementHistory,
              compact.storage == sourceStorage,
              compact.sourceWidth == sourceWidth,
              compact.sourceHeight == sourceHeight,
              compact.windowWidth == 32,
              compact.windowHeight == 32,
              let frame = previousSourceLumaFrame,
              frame.frameID == "v4-measurement-\(nextOutputOrdinal - 1)",
              frame.streamID == "primary-video-measurement",
              frame.formatIdentity == formatIdentity,
              frame.ordinal == nextOutputOrdinal - 1,
              frame.presentationTime == lastCompletedOutputPresentationTime,
              frame.luma.width == sourceWidth,
              frame.luma.height == sourceHeight,
              frame.tileStateRawValues == [expectedStateRawValue],
              frame.cadenceID == expectedCadenceID else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let lumaBounds = PixelLayoutV4(storage: sourceStorage)
            .planes[0].signalCodeBounds[0]
        guard frame.luma.minimumCode == lumaBounds.minimum,
              frame.luma.maximumCode == lumaBounds.maximum else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        guard try normalizedMeasurementWindowQ16(from: frame.luma)
                == compact.normalizedLumaWindowQ16 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
    }

    /// Compact measurement evidence is durable only when it is an exact
    /// projection of the durable source luma. The direct extractor samples the
    /// top-left canonical window and clamps coordinates at the source edge.
    private func normalizedMeasurementWindowQ16(
        from luma: ASHTemporalPlaneV4
    ) throws -> [UInt32] {
        let windowWidth = 32
        let windowHeight = 32
        let scale = UInt64(ASHNormalizedQ16V4.scale)
        let range = UInt64(luma.maximumCode - luma.minimumCode)
        guard range > 0 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        var normalized = Array(
            repeating: UInt32(0),
            count: windowWidth * windowHeight
        )
        for y in 0..<windowHeight {
            let sourceY = min(y, luma.height - 1)
            for x in 0..<windowWidth {
                let sourceX = min(x, luma.width - 1)
                let code = luma.samples[sourceY * luma.width + sourceX]
                let numerator = UInt64(code - luma.minimumCode) * scale
                let quotient = numerator / range
                let remainder = numerator % range
                let complement = range - remainder
                let rounded = remainder > complement
                    || (remainder == complement && quotient & 1 == 1)
                    ? quotient + 1
                    : quotient
                guard let value = UInt32(exactly: rounded),
                      value <= ASHNormalizedQ16V4.scale else {
                    throw ASHPreparedTemporalCheckpointV4Error.invalidState
                }
                normalized[y * windowWidth + x] = value
            }
        }
        return normalized
    }
}

/// Durable state for the bounded tiled production path. This is intentionally
/// separate from the legacy contiguous checkpoint schema: decoding must never
/// guess which allocation contract a payload was produced under.
struct ASHPreparedTiledTemporalCheckpointV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID = "ash.prepared-tiled-temporal-checkpoint.v4.1"

    let schemaID: String
    let planSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let formatIdentity: ASHSHA256V4
    let sourceStorage: PixelStorageV4
    let sourceWidth: Int
    let sourceHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    let scanModeID: String
    let tilePolicy: ASHTemporalTilePolicyV4
    let lastCompletedInputOrdinal: Int64
    let nextOutputOrdinal: Int64
    let lastCompletedOutputPresentationTime: ExactRationalV4
    let history: ASHTemporalTiledHistoryV4
    let previousMeasurementHistory: ASHCompactMeasurementHistoryV4
    let previousSourceTiledFrame: ASHTemporalTiledFrameV4
    let previousMeasurementStateRawValue: UInt16
    let previousInterlacedFrame: PixelBufferSignalFrameV4?
    let fieldCadenceState: DeterministicFieldCadenceStateV4?

    init(
        planSHA256: ASHSHA256V4,
        runtimeManifestSHA256: ASHSHA256V4,
        formatIdentity: ASHSHA256V4,
        sourceStorage: PixelStorageV4,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        scanModeID: String,
        tilePolicy: ASHTemporalTilePolicyV4,
        lastCompletedInputOrdinal: Int64,
        nextOutputOrdinal: Int64,
        lastCompletedOutputPresentationTime: ExactRationalV4,
        history: ASHTemporalTiledHistoryV4,
        previousMeasurementHistory: ASHCompactMeasurementHistoryV4,
        previousSourceTiledFrame: ASHTemporalTiledFrameV4,
        previousMeasurementStateRawValue: UInt16,
        previousInterlacedFrame: PixelBufferSignalFrameV4?,
        fieldCadenceState: DeterministicFieldCadenceStateV4?
    ) throws {
        schemaID = Self.currentSchemaID
        self.planSHA256 = planSHA256
        self.runtimeManifestSHA256 = runtimeManifestSHA256
        self.formatIdentity = formatIdentity
        self.sourceStorage = sourceStorage
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.scanModeID = scanModeID
        self.tilePolicy = tilePolicy
        self.lastCompletedInputOrdinal = lastCompletedInputOrdinal
        self.nextOutputOrdinal = nextOutputOrdinal
        self.lastCompletedOutputPresentationTime
            = lastCompletedOutputPresentationTime
        self.history = history
        self.previousMeasurementHistory = previousMeasurementHistory
        self.previousSourceTiledFrame = previousSourceTiledFrame
        self.previousMeasurementStateRawValue
            = previousMeasurementStateRawValue
        self.previousInterlacedFrame = previousInterlacedFrame
        self.fieldCadenceState = fieldCadenceState
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
              targetWidth > 0,
              targetHeight > 0,
              lastCompletedInputOrdinal >= 0,
              nextOutputOrdinal > 0,
              lastCompletedOutputPresentationTime >= .zero,
              ASHTemporalFrameV4.validIdentifier(scanModeID) else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        do {
            try tilePolicy.validate()
            try history.validate()
            try previousMeasurementHistory.validate()
            try previousSourceTiledFrame.validate()
            try previousInterlacedFrame?.validate()
        } catch {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let sourceGrid: ASHTemporalTileGridV4
        let targetGrid: ASHTemporalTileGridV4
        do {
            sourceGrid = try ASHTemporalTileGridV4(
                frameWidth: sourceWidth,
                frameHeight: sourceHeight,
                policy: tilePolicy
            )
            targetGrid = try ASHTemporalTileGridV4(
                frameWidth: targetWidth,
                frameHeight: targetHeight,
                policy: tilePolicy
            )
        } catch {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let completedInputCount = lastCompletedInputOrdinal
            .addingReportingOverflow(1)
        guard !completedInputCount.overflow,
              completedInputCount.partialValue > 0,
              let completedInputCountUnsigned = UInt64(
                exactly: completedInputCount.partialValue
              ) else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let outputsPerInput: Int64
        switch scanModeID {
        case "progressive":
            outputsPerInput = 1
        case "interlaced_tff_double_rate", "interlaced_bff_double_rate":
            outputsPerInput = 2
        default:
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let expectedOutputCount = completedInputCount.partialValue
            .multipliedReportingOverflow(by: outputsPerInput)
        let nextInputOrdinal = lastCompletedInputOrdinal
            .addingReportingOverflow(1)
        let outputHeadroom = nextOutputOrdinal
            .addingReportingOverflow(outputsPerInput)
        guard !expectedOutputCount.overflow,
              expectedOutputCount.partialValue == nextOutputOrdinal,
              !nextInputOrdinal.overflow,
              !outputHeadroom.overflow,
              // Only the immediately preceding reconstructed frame can affect
              // the next pixel. Persisting the diagnostic second entry would
              // make an 8K JSON checkpoint exceed the durable 256 MiB limit.
              history.capacity == 1,
              history.generation > 0,
              history.generation < UInt64.max,
              history.lastResetReason == nil,
              history.entries.count == 1,
              let latest = history.entries.last?.frame,
              latest.ordinal == nextOutputOrdinal - 1,
              latest.presentationTime
                == lastCompletedOutputPresentationTime,
              latest.grid == targetGrid,
              latest.frameID == "v4-frame-\(latest.ordinal)",
              latest.streamID == "primary-video",
              latest.formatIdentity == formatIdentity else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let state: ASHState
        do {
            state = try ASHState(rawValue: previousMeasurementStateRawValue)
        } catch {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        guard state.hasValidIntegrity,
              latest.tiles.allSatisfy({
                  $0.ashStateRawValue == previousMeasurementStateRawValue
              }),
              previousSourceTiledFrame.grid == sourceGrid,
              previousSourceTiledFrame.ordinal == nextOutputOrdinal - 1,
              previousSourceTiledFrame.presentationTime
                == lastCompletedOutputPresentationTime,
              previousSourceTiledFrame.frameID
                == "v4-measurement-\(nextOutputOrdinal - 1)",
              previousSourceTiledFrame.streamID
                == "primary-video-measurement",
              previousSourceTiledFrame.formatIdentity == formatIdentity,
              previousSourceTiledFrame.tiles.allSatisfy({
                  $0.ashStateRawValue == previousMeasurementStateRawValue
              }),
              previousMeasurementHistory.storage == sourceStorage,
              previousMeasurementHistory.sourceWidth == sourceWidth,
              previousMeasurementHistory.sourceHeight == sourceHeight,
              previousMeasurementHistory.windowWidth == 32,
              previousMeasurementHistory.windowHeight == 32,
              previousSourceTiledFrame.cadenceID == latest.cadenceID else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let lumaBounds = PixelLayoutV4(storage: sourceStorage)
            .planes[0].signalCodeBounds[0]
        guard previousSourceTiledFrame.tiles.allSatisfy({
                  $0.minimumCode == lumaBounds.minimum
                      && $0.maximumCode == lumaBounds.maximum
              }),
              (try normalizedMeasurementWindowQ16(
                  from: previousSourceTiledFrame
              )) == previousMeasurementHistory.normalizedLumaWindowQ16 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let expectedCadenceID: String
        if scanModeID == "progressive" {
            guard previousInterlacedFrame == nil,
                  fieldCadenceState == nil else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            expectedCadenceID = "progressive"
        } else {
            guard let previousInterlacedFrame,
                  previousInterlacedFrame.storage == sourceStorage,
                  previousInterlacedFrame.width == sourceWidth,
                  previousInterlacedFrame.height == sourceHeight,
                  let luma = previousInterlacedFrame.planes.first,
                  let bounds = luma.componentBounds.first,
                  let expectedRepeatThresholdQ16 = try?
                    DeterministicFieldCadenceClassifierV4
                        .normalizedRepeatThresholdQ16(
                            minimumCode: bounds.minimum,
                            maximumCode: bounds.maximum,
                            repeatCodeDifference:
                                sourceStorage.signalBitDepth == 10 ? 16 : 4
                        ),
                  let fieldCadenceState,
                  (try? fieldCadenceState.validate()) != nil,
                  fieldCadenceState.streamInputFrameCount
                    == completedInputCountUnsigned,
                  fieldCadenceState.observations.allSatisfy({
                      $0.normalizedRepeatThresholdQ16
                        == expectedRepeatThresholdQ16
                  }) else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            expectedCadenceID = fieldCadenceState.cadenceID
        }
        guard latest.cadenceID == expectedCadenceID,
              previousSourceTiledFrame.cadenceID == expectedCadenceID else {
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
        expectedFormatIdentity: ASHSHA256V4,
        expectedTilePolicy: ASHTemporalTilePolicyV4
    ) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        try decoded.validate()
        guard decoded.planSHA256 == expectedPlanSHA256,
              decoded.runtimeManifestSHA256
                == expectedRuntimeManifestSHA256,
              decoded.formatIdentity == expectedFormatIdentity,
              decoded.tilePolicy == expectedTilePolicy else {
            throw ASHPreparedTemporalCheckpointV4Error.identityMismatch
        }
        guard try ASHCanonicalJSONV4.encode(decoded) == data else {
            throw ASHPreparedTemporalCheckpointV4Error.nonCanonicalEncoding
        }
        return decoded
    }

    private func normalizedMeasurementWindowQ16(
        from frame: ASHTemporalTiledFrameV4
    ) throws -> [UInt32] {
        let scale = UInt64(ASHNormalizedQ16V4.scale)
        guard let first = frame.tiles.first else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let range = UInt64(first.maximumCode - first.minimumCode)
        guard range > 0 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        var result = Array(repeating: UInt32(0), count: 32 * 32)
        for y in 0..<32 {
            let sourceY = min(y, frame.grid.frameHeight - 1)
            for x in 0..<32 {
                let sourceX = min(x, frame.grid.frameWidth - 1)
                let column = sourceX / frame.grid.policy.tileWidth
                let row = sourceY / frame.grid.policy.tileHeight
                let tileIndex = row * frame.grid.columns + column
                guard frame.tiles.indices.contains(tileIndex) else {
                    throw ASHPreparedTemporalCheckpointV4Error.invalidState
                }
                let code = try frame.tiles[tileIndex].sample(
                    x: sourceX,
                    y: sourceY
                )
                let numerator = UInt64(code - first.minimumCode) * scale
                let quotient = numerator / range
                let remainder = numerator % range
                let complement = range - remainder
                let rounded = remainder > complement
                    || (remainder == complement && quotient & 1 == 1)
                    ? quotient + 1
                    : quotient
                guard let value = UInt32(exactly: rounded),
                      value <= ASHNormalizedQ16V4.scale else {
                    throw ASHPreparedTemporalCheckpointV4Error.invalidState
                }
                result[y * 32 + x] = value
            }
        }
        return result
    }
}

private final class ASHPreparedProcessingWorkspaceV4 {
    var sourceLuma = PixelBufferLumaWorkspaceV4()
    var outputLuma = PixelBufferLumaWorkspaceV4()
    var measurement = ASHMeasurementExtractionWorkspaceV4()
    var spatial = ASHSpatialReconstructionWorkspaceV4()
}

/// Immutable proof of the allocation shape selected during preparation. The
/// media pixel buffers themselves necessarily cover the full raster; this
/// contract is specifically for ASH temporal/spatial Swift sample storage,
/// where no single allocation may scale with the full frame.
struct ASHPreparedTiledAllocationContractV4: Equatable, Sendable {
    let policyID: String
    let sourceFullFrameSampleCount: Int
    let sourceTileCount: Int
    let targetFullFrameSampleCount: Int
    let targetTileCount: Int
    let maximumRetainedTileSampleCount: Int
    let maximumOutputTileSampleCount: Int
    let fullFrameSampleArrayAllocationCap: Int
}

#if DEBUG
struct ASHPreparedWorkspaceDiagnosticsV4: Equatable, Sendable {
    let usesBoundedTiledTemporalPath: Bool
    let temporalHistoryCapacity: Int
    let temporalHistoryCount: Int
    let tiledTemporalHistoryCapacity: Int
    let tiledTemporalHistoryCount: Int
    let measurementHistorySampleCount: Int
    let sourceLumaAllocationCounts: [Int]
    let sourceLumaStorageIdentities: [UInt]
    let outputLumaAllocationCounts: [Int]
    let outputLumaStorageIdentities: [UInt]
    let measurementAllocationCounts: [Int]
    let measurementLumaStorageIdentities: [UInt]
    let measurementChromaStorageIdentities: [UInt]
    let signalWindowAllocationCounts: [Int]
    let signalWindowStorageIdentities: [UInt]
    let spatialAllocationCounts: [Int]
    let spatialStorageIdentities: [UInt]
    let lastSourceMaterializedAlignedSampleCount: Int
    let lastOutputMaterializedAlignedSampleCount: Int
    let tiledSourceFullFrameSampleArrayAllocationCount: Int
    let tiledOutputFullFrameSampleArrayAllocationCount: Int
    let tiledMotionFullFrameVectorArrayAllocationCount: Int
    let tiledReconstructionFullFrameSampleArrayAllocationCount: Int
    let tiledLargestContiguousSampleAllocation: Int
    let tiledLargestContiguousMotionVectorAllocation: Int
    let tiledMaterializedAlignedSampleCount: Int
    let scalerFullPlaneSwiftArrayStagingSampleCount: Int
    let scalerUsesDirectPixelBufferIO: Bool
    let scalerCPUReusableHorizontalSampleCount: Int
    let scalerMetalRetainedPlanarSampleCount: Int
    let interlacedNormalizedSourceIdentities: [UInt]
}
#endif

/// A temporal vote at a missing row comes from the opposite physical field.
/// Align that field's sample lattice before comparing or blending its codes.
/// Selected-field rows remain exact; the existing adaptive deinterlacer owns
/// the subsequent spatial/temporal decision.
private struct PreparedChromaFieldTemporalAlignmentV4: Sendable {
    let width: Int
    let height: Int
    let oppositeParity: Int
    let horizontal: [FixedPointPreparedAxisSampleV4]
    let vertical: [FixedPointPreparedAxisSampleV4]

    init(width: Int, height: Int, forTopField: Bool,
         geometry: SpatialInterlacedChromaGeometryV4) throws {
        guard width > 0, height > 1 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        self.width = width
        self.height = height
        self.oppositeParity = forTopField ? 1 : 0
        let source = forTopField ? geometry.bottomSource : geometry.topSource
        let target = forTopField ? geometry.topSource : geometry.bottomSource
        self.horizontal = try Self.prepareAxis(
            count: width,
            offset: ExactRationalV4(
                target.lumaOffsetNumerator(axis: .horizontal)
                    - source.lumaOffsetNumerator(axis: .horizontal), 4
            )
        )
        // Adjacent samples of one physical field are four frame-luma rows
        // apart, while the location numerators are half-luma-index units.
        self.vertical = try Self.prepareAxis(
            count: (height + 1 - oppositeParity) / 2,
            offset: ExactRationalV4(
                target.lumaOffsetNumerator(axis: .vertical)
                    - source.lumaOffsetNumerator(axis: .vertical), 8
            )
        )
        let horizontalBound = horizontal.map(Self.absoluteSum).max() ?? 0
        let verticalBound = vertical.map(Self.absoluteSum).max() ?? 0
        let first = UInt64(UInt16.max).multipliedReportingOverflow(by: horizontalBound)
        let second = first.partialValue.multipliedReportingOverflow(by: verticalBound)
        guard !first.overflow, !second.overflow,
              second.partialValue <= UInt64(Int64.max) else {
            throw FixedPointKernelV4Error.executionArithmeticOverflow
        }
    }

    func align(_ plane: FieldPlaneV4) throws -> FieldPlaneV4 {
        guard plane.width == width, plane.height == height else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        var samples = plane.samples
        for row in vertical.indices {
            let y = oppositeParity + 2 * row
            let v = vertical[row]
            for x in horizontal.indices {
                let h = horizontal[x]
                for component in 0..<plane.componentsPerSample {
                    let a = horizontalValue(plane, sample: h, row: v.source0, component: component)
                    let b = horizontalValue(plane, sample: h, row: v.source1, component: component)
                    let c = horizontalValue(plane, sample: h, row: v.source2, component: component)
                    let d = horizontalValue(plane, sample: h, row: v.source3, component: component)
                    // The UInt16/coefficient bound was proved at preparation.
                    let accumulator = (a &* v.coefficient0) &+ (b &* v.coefficient1)
                        &+ (c &* v.coefficient2) &+ (d &* v.coefficient3)
                    let rounded = try FixedPointCPUExecutorV4.roundTiesToEven(
                        accumulator, fractionalBits: 28
                    )
                    samples[(y * width + x) * plane.componentsPerSample + component]
                        = UInt16(min(Int64(plane.maximumCode), max(Int64(plane.minimumCode), rounded)))
                }
            }
        }
        return try FieldPlaneV4(
            width: plane.width, height: plane.height,
            componentsPerSample: plane.componentsPerSample,
            minimumCode: plane.minimumCode, maximumCode: plane.maximumCode,
            samples: samples
        )
    }

    @inline(__always)
    private func horizontalValue(_ plane: FieldPlaneV4,
        sample: FixedPointPreparedAxisSampleV4, row: Int, component: Int) -> Int64 {
        let base = ((oppositeParity + 2 * row) * width) * plane.componentsPerSample + component
        return (Int64(plane.samples[base + sample.source0 * plane.componentsPerSample]) &* sample.coefficient0)
            &+ (Int64(plane.samples[base + sample.source1 * plane.componentsPerSample]) &* sample.coefficient1)
            &+ (Int64(plane.samples[base + sample.source2 * plane.componentsPerSample]) &* sample.coefficient2)
            &+ (Int64(plane.samples[base + sample.source3 * plane.componentsPerSample]) &* sample.coefficient3)
    }

    private static func prepareAxis(count: Int, offset: ExactRationalV4) throws
        -> [FixedPointPreparedAxisSampleV4] {
        var base = offset.numerator / offset.denominator
        if offset.numerator % offset.denominator < 0 { base -= 1 }
        let phase = try ExactRationalV4(
            offset.numerator - base * offset.denominator, offset.denominator
        )
        let coefficients = try FixedPointCoefficientCompilerV4.compile(phase: phase).coefficients
        return (0..<count).map { index in
            let source = FixedPointPhaseKernelV4.tapOffsets.map {
                FixedPointCPUExecutorV4.borderIndex(Int(base) + index + $0,
                                                   count: count, rule: .reflect101)
            }
            return FixedPointPreparedAxisSampleV4(
                source0: source[0], source1: source[1], source2: source[2], source3: source[3],
                coefficient0: Int64(coefficients[0]), coefficient1: Int64(coefficients[1]),
                coefficient2: Int64(coefficients[2]), coefficient3: Int64(coefficients[3])
            )
        }
    }

    private static func absoluteSum(_ sample: FixedPointPreparedAxisSampleV4) -> UInt64 {
        sample.coefficient0.magnitude + sample.coefficient1.magnitude
            + sample.coefficient2.magnitude + sample.coefficient3.magnitude
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
    nonisolated let usesBoundedTiledTemporalPath: Bool
    nonisolated let temporalTilePolicy: ASHTemporalTilePolicyV4?
    nonisolated let temporalTileExecutionSchedule:
        ASHTemporalTileExecutionScheduleV4
    nonisolated let tiledAllocationContract:
        ASHPreparedTiledAllocationContractV4?

    nonisolated var deterministicSourceDeliveryIdentity: String? {
        configuration.sourceDeliveryIdentity
    }

    nonisolated var deterministicChromaGeometry: SpatialChromaGeometryV4? {
        configuration.chromaGeometry
    }
    nonisolated var deterministicInterlacedChromaGeometry:
        SpatialInterlacedChromaGeometryV4? {
        configuration.interlacedChromaGeometry
    }

    private let configuration: DeterministicPreparedConfigurationV4
    private let runtime: ASHVerifiedRuntimeBundleV4
    private let measurementContract: ASHMeasurementContractV4
    private let branchProgram: ASHDepthFourBranchProgramV4
    private let scaler: FixedPointPixelBufferScalerV4
    private let bottomFieldScaler: FixedPointPixelBufferScalerV4?
    private let fieldChromaTemporalAlignments:
        [FieldParityV4: PreparedChromaFieldTemporalAlignmentV4]
    private let formatIdentity: ASHSHA256V4
    private let interlacedScratchDestinations: [CVPixelBuffer]
    private let interlacedNormalizedSources: [CVPixelBuffer]
    private let processingWorkspaces: [ASHPreparedProcessingWorkspaceV4]

    private var temporalHistory: ASHTemporalHistoryV4
    private var tiledTemporalHistory: ASHTemporalTiledHistoryV4
    private var previousMeasurementHistory: ASHCompactMeasurementHistoryV4?
    private var previousSourceLumaFrame: ASHTemporalFrameV4?
    private var previousSourceTiledFrame: ASHTemporalTiledFrameV4?
    private var previousMeasurementState: ASHState?
    private var previousInterlacedFrame: PixelBufferSignalFrameV4?
    private var fieldCadenceState: DeterministicFieldCadenceStateV4?
    private var outputOrdinal: Int64 = 0
    private var lastCompletedInputOrdinal: Int64 = -1
    private var lastOutputPresentationTime = ExactRationalV4.zero
    private var lastInputPresentationTime: ExactRationalV4?
    private var lastInputDuration: ExactRationalV4?
    private var finished = false
    private var operationInFlight = false
#if DEBUG
    private var interlacedOutputBoundaryTestHook:
        (@Sendable (Int) async throws -> Void)?
    private var tiledTileBoundaryTestHook:
        (@Sendable (Int) async throws -> Void)?
    private var lastSourceMotionAllocationDiagnostics:
        ASHTemporalMotionAllocationDiagnosticsV4?
    private var lastOutputMotionAllocationDiagnostics:
        ASHTemporalMotionAllocationDiagnosticsV4?
    private var lastTiledSourceCaptureDiagnostics:
        ASHTemporalTileAllocationDiagnosticsV4?
    private var lastTiledOutputCaptureDiagnostics:
        ASHTemporalTileAllocationDiagnosticsV4?
    private var lastTiledMotionAllocationDiagnostics:
        ASHTemporalTiledMotionAllocationDiagnosticsV4?
    private var lastTiledReconstructionDiagnostics:
        ASHTemporalTiledReconstructionDiagnosticsV4?
#endif

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
        executionSchedule: FixedPointExecutionScheduleV4 = .productionFullFrame,
        temporalTilePolicy requestedTemporalTilePolicy:
            ASHTemporalTilePolicyV4? = nil,
        temporalTileExecutionSchedule:
            ASHTemporalTileExecutionScheduleV4 = .raster,
        metalDevice: MTLDevice? = nil,
        metalLibrary: MTLLibrary? = nil
    ) throws {
        try runtime.verifyBinding()
        switch configuration.scanMode {
        case .progressive:
            guard configuration.interlacedChromaGeometry == nil else {
                throw configuration.processingError("progressive preparation carries interlaced chroma geometry")
            }
        case .interlaced:
            if let fields = configuration.interlacedChromaGeometry {
                guard configuration.chromaGeometry == fields.geometry(forTopField: true) else {
                    throw configuration.processingError("interlaced primary geometry contradicts its bound top-field geometry")
                }
            } else if configuration.chromaGeometry != nil {
                throw configuration.processingError("interlaced preparation must bind both source field locations")
            }
        }
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
        let sourceSampleCount = configuration.sourceWidth
            .multipliedReportingOverflow(by: configuration.sourceHeight)
        let targetSampleCount = configuration.targetWidth
            .multipliedReportingOverflow(by: configuration.targetHeight)
        let requiresTiling = sourceSampleCount.overflow
            || targetSampleCount.overflow
            || sourceSampleCount.partialValue
                > ASHTemporalPlaneV4.maximumSampleCount
            || targetSampleCount.partialValue
                > ASHTemporalPlaneV4.maximumSampleCount
        let selectedTemporalTilePolicy = requestedTemporalTilePolicy
            ?? (requiresTiling ? .canonical : nil)
        let sourceTemporalGrid: ASHTemporalTileGridV4?
        let targetTemporalGrid: ASHTemporalTileGridV4?
        if let selectedTemporalTilePolicy {
            let motionConfiguration =
                ASHTemporalBlockMatchingConfigurationV4.canonical
            guard selectedTemporalTilePolicy.tileWidth
                    % motionConfiguration.blockWidth == 0,
                  selectedTemporalTilePolicy.tileHeight
                    % motionConfiguration.blockHeight == 0,
                  selectedTemporalTilePolicy.searchHalo
                    >= ASHTemporalBlockMatchingConfigurationV4.canonical
                        .searchRadius + 1 else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            sourceTemporalGrid = try ASHTemporalTileGridV4(
                frameWidth: configuration.sourceWidth,
                frameHeight: configuration.sourceHeight,
                policy: selectedTemporalTilePolicy
            )
            targetTemporalGrid = try ASHTemporalTileGridV4(
                frameWidth: configuration.targetWidth,
                frameHeight: configuration.targetHeight,
                policy: selectedTemporalTilePolicy
            )
        } else {
            sourceTemporalGrid = nil
            targetTemporalGrid = nil
        }
        self.temporalTilePolicy = selectedTemporalTilePolicy
        self.temporalTileExecutionSchedule = temporalTileExecutionSchedule
        self.usesBoundedTiledTemporalPath
            = selectedTemporalTilePolicy != nil
        if let selectedTemporalTilePolicy,
           let sourceTemporalGrid,
           let targetTemporalGrid {
            self.tiledAllocationContract =
                ASHPreparedTiledAllocationContractV4(
                    policyID: selectedTemporalTilePolicy.policyID,
                    sourceFullFrameSampleCount:
                        sourceTemporalGrid.fullFrameSampleCount,
                    sourceTileCount: sourceTemporalGrid.tileCount,
                    targetFullFrameSampleCount:
                        targetTemporalGrid.fullFrameSampleCount,
                    targetTileCount: targetTemporalGrid.tileCount,
                    maximumRetainedTileSampleCount:
                        selectedTemporalTilePolicy
                            .maximumRetainedTileSampleCount,
                    maximumOutputTileSampleCount:
                        selectedTemporalTilePolicy.tileWidth
                            * selectedTemporalTilePolicy.tileHeight,
                    fullFrameSampleArrayAllocationCap: 0
                )
        } else {
            self.tiledAllocationContract = nil
        }
        self.temporalHistory = try ASHTemporalHistoryV4(capacity: 1)
        self.tiledTemporalHistory = try ASHTemporalTiledHistoryV4(capacity: 2)
        self.processingWorkspaces = (0..<3).map { _ in
            ASHPreparedProcessingWorkspaceV4()
        }
        self.scaler = try FixedPointPixelBufferScalerV4(
            backend: configuration.executionBackend,
            storage: configuration.storage,
            sourceWidth: configuration.sourceWidth,
            sourceHeight: configuration.sourceHeight,
            targetWidth: configuration.targetWidth,
            targetHeight: configuration.targetHeight,
            borderRule: .reflect101,
            executionSchedule: executionSchedule,
            metalDevice: metalDevice,
            metalLibrary: metalLibrary,
            chromaGeometry: configuration.chromaGeometry
        )
        if let fields = configuration.interlacedChromaGeometry,
           fields.bottomSource != fields.topSource {
            self.bottomFieldScaler = try FixedPointPixelBufferScalerV4(
                backend: configuration.executionBackend,
                storage: configuration.storage,
                sourceWidth: configuration.sourceWidth,
                sourceHeight: configuration.sourceHeight,
                targetWidth: configuration.targetWidth,
                targetHeight: configuration.targetHeight,
                borderRule: .reflect101,
                executionSchedule: executionSchedule,
                metalDevice: metalDevice,
                metalLibrary: metalLibrary,
                chromaGeometry: fields.geometry(forTopField: false)
            )
        } else {
            self.bottomFieldScaler = nil
        }
        if let fields = configuration.interlacedChromaGeometry,
           fields.topSource != fields.bottomSource {
            self.fieldChromaTemporalAlignments = [
                .top: try PreparedChromaFieldTemporalAlignmentV4(
                    width: (configuration.sourceWidth + 1) / 2,
                    height: (configuration.sourceHeight + 1) / 2,
                    forTopField: true, geometry: fields
                ),
                .bottom: try PreparedChromaFieldTemporalAlignmentV4(
                    width: (configuration.sourceWidth + 1) / 2,
                    height: (configuration.sourceHeight + 1) / 2,
                    forTopField: false, geometry: fields
                )
            ]
        } else {
            self.fieldChromaTemporalAlignments = [:]
        }
        if configuration.scanMode == .progressive {
            self.interlacedScratchDestinations = []
            self.interlacedNormalizedSources = []
        } else {
            self.interlacedScratchDestinations = try (0..<2).map { _ in
                try PixelBufferSignalCodecV4.makeBuffer(
                    storage: configuration.storage,
                    width: configuration.targetWidth,
                    height: configuration.targetHeight,
                    metalCompatible: configuration.executionBackend == .metal
                )
            }
            self.interlacedNormalizedSources = try (0..<2).map { _ in
                try PixelBufferSignalCodecV4.makeBuffer(
                    storage: configuration.storage,
                    width: configuration.sourceWidth,
                    height: configuration.sourceHeight,
                    metalCompatible: configuration.executionBackend == .metal
                )
            }
        }
        self.formatIdentity = ASHSHA256V4(rawData: Data(
            [
                ASHRuntimeManifestV4.runtimeIdentity,
                runtime.manifestSHA256.rawValue,
                configuration.storage.rawValue,
                String(configuration.sourceWidth),
                String(configuration.sourceHeight),
                String(configuration.targetWidth),
                String(configuration.targetHeight),
                configuration.scaleRouteIdentity,
                SpatialChromaGeometryV4.coordinateProcedureID,
                configuration.chromaGeometryIdentity,
                configuration.interlacedChromaGeometryIdentity
                    + (configuration.sourceDeliveryIdentity.map { "|delivery=" + $0 } ?? "")
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
            fixedPointKernelID: configuration.chromaGeometry == nil
                ? FixedPointCoefficientCompilerV4.procedureID
                : SpatialChromaGeometryV4.kernelContractID,
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
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
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
            let inputOrdinal = try validatedNextInputOrdinal(timing.frameIndex)
            try validateOutputOrdinalHeadroom()
            try Task.checkCancellation()
            let inputResetReason = try temporalBoundaryReason(for: timing)
            switch configuration.scanMode {
            case .progressive:
                let hasPreviousSource = usesBoundedTiledTemporalPath
                    ? previousSourceTiledFrame != nil
                    : previousSourceLumaFrame != nil
                let resetReason = !hasPreviousSource
                    ? ASHTemporalResetReasonV4.streamStart
                    : inputResetReason
                let output = try await processProgressive(
                    source: source.value,
                    destination: destinations[0].value,
                    presentationTime: timing.presentationTime,
                    duration: timing.duration,
                    sourceField: .progressive,
                    sourceFrameIndex: timing.frameIndex,
                    cadenceID: "progressive",
                    resetTrigger: resetReason?.measurementTrigger,
                    typedResetReason: resetReason,
                    suppressAutomaticSceneCutReset: false
                )
                lastCompletedInputOrdinal = inputOrdinal
                recordCompletedInputTiming(timing)
                return [output]
            case .interlaced(let dominance):
                return try await processInterlaced(
                    source: source.value,
                    destinations: destinations,
                    timing: timing,
                    dominance: dominance,
                    inputResetReason: inputResetReason
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ASHPreparedTemporalCheckpointV4Error {
            throw error
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
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        guard !finished else { return }
        try Task.checkCancellation()
        try temporalHistory.reset(reason: .explicitReset)
        try tiledTemporalHistory.reset(reason: .explicitReset)
        previousMeasurementHistory = nil
        previousSourceLumaFrame = nil
        previousSourceTiledFrame = nil
        previousMeasurementState = nil
        previousInterlacedFrame = nil
        fieldCadenceState = nil
        lastInputPresentationTime = nil
        lastInputDuration = nil
        finished = true
    }

#if DEBUG
    /// Deterministic failure injection at an interlaced output boundary. This
    /// is compiled out of release builds and exists only to prove that an
    /// interrupted two-field transaction can be retried byte-identically.
    func setInterlacedOutputBoundaryTestHook(
        _ hook: (@Sendable (Int) async throws -> Void)?
    ) {
        interlacedOutputBoundaryTestHook = hook
    }

    /// Deterministic failure injection after a retained tile is spatially
    /// conditioned but before any temporal state is committed.
    func setTiledTileBoundaryTestHook(
        _ hook: (@Sendable (Int) async throws -> Void)?
    ) {
        tiledTileBoundaryTestHook = hook
    }

    func workspaceDiagnostics() -> ASHPreparedWorkspaceDiagnosticsV4 {
        let scalerDiagnostics = ([scaler] + [bottomFieldScaler].compactMap { $0 })
            .map { $0.hotPathDiagnostics() }
        return ASHPreparedWorkspaceDiagnosticsV4(
            usesBoundedTiledTemporalPath: usesBoundedTiledTemporalPath,
            temporalHistoryCapacity: temporalHistory.capacity,
            temporalHistoryCount: temporalHistory.frames.count,
            tiledTemporalHistoryCapacity: tiledTemporalHistory.capacity,
            tiledTemporalHistoryCount: tiledTemporalHistory.entries.count,
            measurementHistorySampleCount: previousMeasurementHistory?
                .normalizedLumaWindowQ16.count ?? 0,
            sourceLumaAllocationCounts: processingWorkspaces.map {
                $0.sourceLuma.storageAllocationCount
            },
            sourceLumaStorageIdentities: processingWorkspaces.map {
                $0.sourceLuma.storageIdentity
            },
            outputLumaAllocationCounts: processingWorkspaces.map {
                $0.outputLuma.storageAllocationCount
            },
            outputLumaStorageIdentities: processingWorkspaces.map {
                $0.outputLuma.storageIdentity
            },
            measurementAllocationCounts: processingWorkspaces.map {
                $0.measurement.storageAllocationCount
            },
            measurementLumaStorageIdentities: processingWorkspaces.map {
                $0.measurement.normalizedLumaStorageIdentity
            },
            measurementChromaStorageIdentities: processingWorkspaces.map {
                $0.measurement.chromaStorageIdentity
            },
            signalWindowAllocationCounts: processingWorkspaces.map {
                $0.measurement.signalWindow.storageAllocationCount
            },
            signalWindowStorageIdentities: processingWorkspaces.map {
                $0.measurement.signalWindow.storageIdentity
            },
            spatialAllocationCounts: processingWorkspaces.map {
                $0.spatial.storageAllocationCount
            },
            spatialStorageIdentities: processingWorkspaces.map {
                $0.spatial.storageIdentity
            },
            lastSourceMaterializedAlignedSampleCount:
                lastSourceMotionAllocationDiagnostics?
                    .materializedAlignedSampleCount ?? 0,
            lastOutputMaterializedAlignedSampleCount:
                lastOutputMotionAllocationDiagnostics?
                    .materializedAlignedSampleCount ?? 0,
            tiledSourceFullFrameSampleArrayAllocationCount:
                lastTiledSourceCaptureDiagnostics?
                    .fullFrameSampleArrayAllocationCount ?? 0,
            tiledOutputFullFrameSampleArrayAllocationCount:
                lastTiledOutputCaptureDiagnostics?
                    .fullFrameSampleArrayAllocationCount ?? 0,
            tiledMotionFullFrameVectorArrayAllocationCount:
                lastTiledMotionAllocationDiagnostics?
                    .fullFrameMotionVectorArrayAllocationCount ?? 0,
            tiledReconstructionFullFrameSampleArrayAllocationCount:
                lastTiledReconstructionDiagnostics?
                    .fullFrameSampleArrayAllocationCount ?? 0,
            tiledLargestContiguousSampleAllocation: max(
                lastTiledSourceCaptureDiagnostics?
                    .largestContiguousSampleAllocation ?? 0,
                max(
                    lastTiledOutputCaptureDiagnostics?
                        .largestContiguousSampleAllocation ?? 0,
                    lastTiledReconstructionDiagnostics?
                        .largestContiguousSampleAllocation ?? 0
                )
            ),
            tiledLargestContiguousMotionVectorAllocation:
                lastTiledMotionAllocationDiagnostics?
                    .largestContiguousMotionVectorAllocation ?? 0,
            tiledMaterializedAlignedSampleCount:
                lastTiledReconstructionDiagnostics?
                    .materializedAlignedSampleCount ?? 0,
            scalerFullPlaneSwiftArrayStagingSampleCount:
                scalerDiagnostics.reduce(0) { $0 + $1.fullPlaneSwiftArrayStagingSampleCount },
            scalerUsesDirectPixelBufferIO:
                scalerDiagnostics.allSatisfy(\.usesDirectPixelBufferIO),
            scalerCPUReusableHorizontalSampleCount:
                scalerDiagnostics.reduce(0) { $0 + $1.cpuReusableHorizontalSampleCount },
            scalerMetalRetainedPlanarSampleCount:
                scalerDiagnostics.reduce(0) { $0 + $1.metalRetainedPlanarSampleCount },
            interlacedNormalizedSourceIdentities:
                interlacedNormalizedSources.map {
                    UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque())
                }
        )
    }
#endif

    func makeTemporalCheckpoint(
        planSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal requestedInputOrdinal: Int64
    ) async throws -> Data {
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        guard !finished else {
            throw configuration.processingError(
                "a finished engine cannot produce a resumable checkpoint"
            )
        }
        guard requestedInputOrdinal == lastCompletedInputOrdinal else {
            throw ASHPreparedTemporalCheckpointV4Error.inputOrdinalMismatch(
                expected: lastCompletedInputOrdinal,
                actual: requestedInputOrdinal
            )
        }
        if usesBoundedTiledTemporalPath {
            guard let tilePolicy = temporalTilePolicy,
                  let previousMeasurementHistory,
                  let previousSourceTiledFrame,
                  let previousMeasurementState,
                  let latestEntry = tiledTemporalHistory.entries.last else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            let durableHistory = try ASHTemporalTiledHistoryV4(
                generation: tiledTemporalHistory.generation,
                capacity: 1,
                entries: [ASHTemporalTiledHistoryEntryV4(
                    frame: latestEntry.frame,
                    motionFromPrevious: nil
                )],
                lastResetReason: nil
            )
            return try ASHPreparedTiledTemporalCheckpointV4(
                planSHA256: planSHA256,
                runtimeManifestSHA256: runtime.manifestSHA256,
                formatIdentity: formatIdentity,
                sourceStorage: configuration.storage,
                sourceWidth: configuration.sourceWidth,
                sourceHeight: configuration.sourceHeight,
                targetWidth: configuration.targetWidth,
                targetHeight: configuration.targetHeight,
                scanModeID: scanModeIdentity,
                tilePolicy: tilePolicy,
                lastCompletedInputOrdinal: lastCompletedInputOrdinal,
                nextOutputOrdinal: outputOrdinal,
                lastCompletedOutputPresentationTime:
                    lastOutputPresentationTime,
                history: durableHistory,
                previousMeasurementHistory: previousMeasurementHistory,
                previousSourceTiledFrame: previousSourceTiledFrame,
                previousMeasurementStateRawValue:
                    previousMeasurementState.rawValue,
                previousInterlacedFrame: previousInterlacedFrame,
                fieldCadenceState: fieldCadenceState
            ).canonicalData
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
            previousMeasurementHistory: previousMeasurementHistory,
            previousSourceLumaFrame: previousSourceLumaFrame,
            previousMeasurementStateRawValue:
                previousMeasurementState?.rawValue,
            previousInterlacedFrame: previousInterlacedFrame,
            fieldCadenceState: fieldCadenceState
        ).canonicalData
    }

    func restoreTemporalCheckpoint(
        _ data: Data,
        planSHA256: ASHSHA256V4
    ) async throws {
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        guard !finished else {
            throw configuration.processingError(
                "a finished engine cannot restore a checkpoint"
            )
        }
        if usesBoundedTiledTemporalPath {
            guard let tilePolicy = temporalTilePolicy else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            let checkpoint = try ASHPreparedTiledTemporalCheckpointV4
                .decodeCanonical(
                    data,
                    expectedPlanSHA256: planSHA256,
                    expectedRuntimeManifestSHA256: runtime.manifestSHA256,
                    expectedFormatIdentity: formatIdentity,
                    expectedTilePolicy: tilePolicy
                )
            guard checkpoint.sourceStorage == configuration.storage,
                  checkpoint.sourceWidth == configuration.sourceWidth,
                  checkpoint.sourceHeight == configuration.sourceHeight,
                  checkpoint.targetWidth == configuration.targetWidth,
                  checkpoint.targetHeight == configuration.targetHeight,
                  checkpoint.scanModeID == scanModeIdentity else {
                throw ASHPreparedTemporalCheckpointV4Error.identityMismatch
            }
            tiledTemporalHistory = try ASHTemporalTiledHistoryV4(
                generation: checkpoint.history.generation,
                capacity: 2,
                entries: checkpoint.history.entries,
                lastResetReason: checkpoint.history.lastResetReason
            )
            temporalHistory = try ASHTemporalHistoryV4(capacity: 1)
            outputOrdinal = checkpoint.nextOutputOrdinal
            lastCompletedInputOrdinal = checkpoint
                .lastCompletedInputOrdinal
            lastOutputPresentationTime = checkpoint
                .lastCompletedOutputPresentationTime
            previousMeasurementHistory = checkpoint
                .previousMeasurementHistory
            previousSourceTiledFrame = checkpoint.previousSourceTiledFrame
            previousSourceLumaFrame = nil
            previousMeasurementState = try ASHState(
                rawValue: checkpoint.previousMeasurementStateRawValue
            )
            previousInterlacedFrame = checkpoint.previousInterlacedFrame
            fieldCadenceState = checkpoint.fieldCadenceState
            lastInputPresentationTime = nil
            lastInputDuration = nil
            return
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
        tiledTemporalHistory = try ASHTemporalTiledHistoryV4(capacity: 2)
        outputOrdinal = checkpoint.nextOutputOrdinal
        lastCompletedInputOrdinal = checkpoint.lastCompletedInputOrdinal
        lastOutputPresentationTime = checkpoint
            .lastCompletedOutputPresentationTime
        previousMeasurementHistory = checkpoint.previousMeasurementHistory
        previousSourceLumaFrame = checkpoint.previousSourceLumaFrame
        previousSourceTiledFrame = nil
        previousMeasurementState = try checkpoint
            .previousMeasurementStateRawValue.map(ASHState.init(rawValue:))
        previousInterlacedFrame = checkpoint.previousInterlacedFrame
        fieldCadenceState = checkpoint.fieldCadenceState
        // The media cursor owns source-duration continuity across a durable
        // boundary. Require its first resumed frame to carry an explicit
        // discontinuity when applicable instead of guessing from output PTS.
        lastInputPresentationTime = nil
        lastInputDuration = nil
    }

    private func processInterlaced(
        source: CVPixelBuffer,
        destinations: [FramePixelBuffer],
        timing: FrameTiming,
        dominance: FieldDominanceV4,
        inputResetReason: ASHTemporalResetReasonV4?
    ) async throws -> [TemporalOutputFrame] {
        let initialTemporalHistory = temporalHistory
        let initialTiledTemporalHistory = tiledTemporalHistory
        let initialPreviousMeasurementHistory = previousMeasurementHistory
        let initialPreviousSourceLumaFrame = previousSourceLumaFrame
        let initialPreviousSourceTiledFrame = previousSourceTiledFrame
        let initialPreviousMeasurementState = previousMeasurementState
        let initialPreviousInterlacedFrame = previousInterlacedFrame
        let initialFieldCadenceState = fieldCadenceState
        let initialOutputOrdinal = outputOrdinal
        let initialLastCompletedInputOrdinal = lastCompletedInputOrdinal
        let initialLastOutputPresentationTime = lastOutputPresentationTime
        let initialLastInputPresentationTime = lastInputPresentationTime
        let initialLastInputDuration = lastInputDuration
        var completedTransaction = false
        defer {
            if !completedTransaction {
                temporalHistory = initialTemporalHistory
                tiledTemporalHistory = initialTiledTemporalHistory
                previousMeasurementHistory = initialPreviousMeasurementHistory
                previousSourceLumaFrame = initialPreviousSourceLumaFrame
                previousSourceTiledFrame = initialPreviousSourceTiledFrame
                previousMeasurementState = initialPreviousMeasurementState
                previousInterlacedFrame = initialPreviousInterlacedFrame
                fieldCadenceState = initialFieldCadenceState
                outputOrdinal = initialOutputOrdinal
                lastCompletedInputOrdinal = initialLastCompletedInputOrdinal
                lastOutputPresentationTime = initialLastOutputPresentationTime
                lastInputPresentationTime = initialLastInputPresentationTime
                lastInputDuration = initialLastInputDuration
            }
        }
        try preflightInterlacedCallerDestinations(
            source: source,
            destinations: destinations
        )
        try validateInterlacedChromaFacts(source)
        let effectiveDominance = try resolvedFieldDominance(
            from: source,
            fallback: dominance
        )
        let signal = try PixelBufferSignalCodecV4.read(
            source,
            storage: configuration.storage
        )
        let previousCadencePlane: FieldPlaneV4?
        if let previousInterlacedFrame {
            previousCadencePlane = try cadencePlane(
                from: previousInterlacedFrame
            )
        } else {
            previousCadencePlane = nil
        }
        let cadenceDecision = try DeterministicFieldCadenceClassifierV4
            .observe(
                previous: previousCadencePlane,
                current: try cadencePlane(from: signal),
                dominance: effectiveDominance,
                repeatCodeDifference:
                    configuration.storage.signalBitDepth == 10 ? 16 : 4,
                state: fieldCadenceState
            )
        let cadenceID = cadenceDecision.state.cadenceID
        let cadenceChanged = cadenceDecision.didTransition
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
            func deinterlace(_ current: FieldPlaneV4, _ prior: FieldPlaneV4?) throws
                -> [DeinterlacedFieldFrameV4] {
                try DeterministicDeinterlacerV4.deinterlace(
                    previous: prior, current: current, next: prior,
                    dominance: effectiveDominance, timing: fieldTiming,
                    thresholds: DeinterlaceThresholdsV4(
                        motionCodeDifference: configuration.storage.signalBitDepth == 10 ? 16 : 4,
                        sceneCutMeanAbsoluteDifference: configuration.storage.signalBitDepth == 10 ? 128 : 32
                    )
                )
            }
            let fields: [DeinterlacedFieldFrameV4]
            if planeIndex == 1, let prior, !fieldChromaTemporalAlignments.isEmpty {
                fields = try effectiveDominance.outputOrder.map { parity in
                    guard let alignment = fieldChromaTemporalAlignments[parity],
                          let selected = try deinterlace(
                            alignment.align(current), alignment.align(prior)
                          ).first(where: { $0.sourceField == parity }) else {
                        throw ASHPreparedTemporalCheckpointV4Error.invalidState
                    }
                    return selected
                }
            } else {
                fields = try deinterlace(current, prior)
            }
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
        fieldCadenceState = cadenceDecision.state
        previousInterlacedFrame = signal

        let scratchDestinations = interlacedScratchDestinations
        let normalizedSources = interlacedNormalizedSources
        guard scratchDestinations.count == 2,
              normalizedSources.count == 2 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        var outputs: [TemporalOutputFrame] = []
        outputs.reserveCapacity(2)
        let hadPreviousTemporalSource = usesBoundedTiledTemporalPath
            ? previousSourceTiledFrame != nil
            : previousSourceLumaFrame != nil
        for outputIndex in 0..<2 {
#if DEBUG
            try await interlacedOutputBoundaryTestHook?(outputIndex)
#endif
            let normalized = PixelBufferSignalFrameV4(
                storage: configuration.storage,
                width: configuration.sourceWidth,
                height: configuration.sourceHeight,
                planes: outputPlanes[outputIndex]
            )
            let temporary = normalizedSources[outputIndex]
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
            if let fields = configuration.interlacedChromaGeometry {
                let isTop = effectiveDominance.outputOrder[outputIndex] == .top
                let sourceKey = isTop ? kCVImageBufferChromaLocationTopFieldKey
                    : kCVImageBufferChromaLocationBottomFieldKey
                var mode = CVAttachmentMode.shouldPropagate
                if CVBufferCopyAttachment(source, sourceKey, &mode) == nil {
                    mode = .shouldPropagate
                }
                CVBufferSetAttachment(
                    temporary, kCVImageBufferChromaLocationTopFieldKey,
                    FixedPointPixelBufferScalerV4.chromaLocation(
                        fields.geometry(forTopField: isTop).source
                    ) as CFString, mode
                )
            }
            // A normalized progressive field carries its own source location;
            // the selected scaler converts it to the common output location.
            CVBufferRemoveAttachment(
                temporary,
                kCVImageBufferChromaLocationBottomFieldKey
            )
            guard let outputTiming = outputTimings?[outputIndex] else {
                throw ASHPreparedTemporalCheckpointV4Error.invalidState
            }
            let presentation = CMTime(
                value: outputTiming.presentationValue,
                timescale: outputTiming.timescale
            )
            outputs.append(try await processProgressive(
                source: temporary,
                destination: scratchDestinations[outputIndex],
                presentationTime: presentation,
                duration: CMTime(
                    value: outputTiming.durationValue,
                    timescale: outputTiming.timescale
                ),
                sourceField: effectiveDominance.outputOrder[outputIndex] == .top
                    ? .top : .bottom,
                sourceFrameIndex: timing.frameIndex,
                cadenceID: cadenceID,
                resetTrigger: outputIndex == 0
                    ? (!hadPreviousTemporalSource
                        ? ASHMeasurementResetTriggerV4.streamStart
                        : (inputResetReason?.measurementTrigger
                            ?? (cadenceChanged
                                ? .fieldCadenceChange : nil)))
                    : nil,
                typedResetReason: outputIndex == 0
                    ? (!hadPreviousTemporalSource
                        ? ASHTemporalResetReasonV4.streamStart
                        : (inputResetReason
                            ?? (cadenceChanged
                                ? .fieldCadenceChange : nil)))
                    : nil,
                suppressAutomaticSceneCutReset:
                    cadenceChanged && outputIndex == 1
            ))
        }
#if DEBUG
        try await interlacedOutputBoundaryTestHook?(2)
#endif
        try Task.checkCancellation()
        try commitInterlacedScratchOutputs(
            scratchDestinations,
            to: destinations.map(\.value)
        )
        guard let completedInputOrdinal = Int64(exactly: timing.frameIndex)
        else {
            throw ASHPreparedTemporalCheckpointV4Error.ordinalOverflow
        }
        lastCompletedInputOrdinal = completedInputOrdinal
        recordCompletedInputTiming(timing)
        completedTransaction = true
        return outputs.enumerated().map { index, output in
            TemporalOutputFrame(
                pixelBuffer: destinations[index],
                presentationTime: output.presentationTime,
                duration: output.duration,
                sourceField: output.sourceField,
                cadenceID: output.cadenceID,
                temporalGeneration: output.temporalGeneration,
                temporalResetReason: output.temporalResetReason
            )
        }
    }

    private struct PixelBufferLockRequest {
        let buffer: CVPixelBuffer
        let flags: CVPixelBufferLockFlags
        let role: String
    }

    private struct PixelBufferPlaneSpan {
        let bufferIndex: Int
        let planeIndex: Int
        let start: UInt
        let end: UInt
    }

    private struct PixelBufferRowCopy {
        let source: UnsafeRawPointer
        let destination: UnsafeMutableRawPointer
        let sourceStride: Int
        let destinationStride: Int
        let activeByteCount: Int
        let height: Int
    }

    private func preflightInterlacedCallerDestinations(
        source: CVPixelBuffer,
        destinations: [FramePixelBuffer]
    ) throws {
        guard destinations.count >= 2 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let first = destinations[0].value
        let second = destinations[1].value
        guard first !== second,
              source !== first,
              source !== second else {
            throw ASHPreparedTemporalCheckpointV4Error.destinationAlias
        }
        try validateInterlacedDestination(first)
        try validateInterlacedDestination(second)
        try withLockedPixelBuffers([
            PixelBufferLockRequest(
                buffer: source,
                flags: .readOnly,
                role: "source"
            ),
            PixelBufferLockRequest(
                buffer: first,
                flags: .readOnly,
                role: "destination_0_preflight"
            ),
            PixelBufferLockRequest(
                buffer: second,
                flags: .readOnly,
                role: "destination_1_preflight"
            )
        ]) {
            try validateNonoverlappingPlaneSpans(
                buffers: [source, first, second]
            )
        }
    }

    /// Commits both completed field outputs as one non-suspending boundary.
    /// Every fallible lock, geometry, pointer, span, and row calculation is
    /// completed before the first caller-owned byte or attachment is changed.
    private func commitInterlacedScratchOutputs(
        _ scratch: [CVPixelBuffer],
        to destinations: [CVPixelBuffer]
    ) throws {
        guard scratch.count == 2, destinations.count >= 2 else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let allBuffers = [scratch[0], scratch[1], destinations[0], destinations[1]]
        for leftIndex in allBuffers.indices {
            for rightIndex in allBuffers.indices where rightIndex > leftIndex {
                guard allBuffers[leftIndex] !== allBuffers[rightIndex] else {
                    throw ASHPreparedTemporalCheckpointV4Error.destinationAlias
                }
            }
        }
        try validateInterlacedDestination(scratch[0])
        try validateInterlacedDestination(scratch[1])
        try validateInterlacedDestination(destinations[0])
        try validateInterlacedDestination(destinations[1])

        try withLockedPixelBuffers([
            PixelBufferLockRequest(
                buffer: scratch[0],
                flags: .readOnly,
                role: "scratch_0"
            ),
            PixelBufferLockRequest(
                buffer: scratch[1],
                flags: .readOnly,
                role: "scratch_1"
            ),
            PixelBufferLockRequest(
                buffer: destinations[0],
                flags: [],
                role: "destination_0_commit"
            ),
            PixelBufferLockRequest(
                buffer: destinations[1],
                flags: [],
                role: "destination_1_commit"
            )
        ]) {
            try validateNonoverlappingPlaneSpans(buffers: allBuffers)
            let layout = PixelLayoutV4(storage: configuration.storage)
            var copies: [PixelBufferRowCopy] = []
            copies.reserveCapacity(layout.planes.count * 2)
            for outputIndex in 0..<2 {
                for (planeIndex, plane) in layout.planes.enumerated() {
                    guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(
                        scratch[outputIndex],
                        planeIndex
                    ), let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                        destinations[outputIndex],
                        planeIndex
                    ) else {
                        throw ASHPreparedTemporalCheckpointV4Error.invalidState
                    }
                    let activeByteCount = try plane.activeBytesPerRow(
                        frameWidth: configuration.targetWidth
                    )
                    let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(
                        scratch[outputIndex],
                        planeIndex
                    )
                    let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(
                        destinations[outputIndex],
                        planeIndex
                    )
                    let sourceHeight = CVPixelBufferGetHeightOfPlane(
                        scratch[outputIndex],
                        planeIndex
                    )
                    let destinationHeight = CVPixelBufferGetHeightOfPlane(
                        destinations[outputIndex],
                        planeIndex
                    )
                    guard sourceStride >= activeByteCount,
                          destinationStride >= activeByteCount,
                          sourceHeight == destinationHeight else {
                        throw ASHPreparedTemporalCheckpointV4Error.invalidState
                    }
                    copies.append(PixelBufferRowCopy(
                        source: UnsafeRawPointer(sourceBase),
                        destination: destinationBase,
                        sourceStride: sourceStride,
                        destinationStride: destinationStride,
                        activeByteCount: activeByteCount,
                        height: sourceHeight
                    ))
                }
            }
            let propagatedAttachments = scratch.map {
                CVBufferCopyAttachments($0, .shouldPropagate)
            }
            let localAttachments = scratch.map {
                CVBufferCopyAttachments($0, .shouldNotPropagate)
            }

            // No throwing operation is permitted below this boundary.
            for copy in copies {
                for rowIndex in 0..<copy.height {
                    memcpy(
                        copy.destination.advanced(
                            by: rowIndex * copy.destinationStride
                        ),
                        copy.source.advanced(
                            by: rowIndex * copy.sourceStride
                        ),
                        copy.activeByteCount
                    )
                }
            }
            for outputIndex in 0..<2 {
                CVBufferRemoveAllAttachments(destinations[outputIndex])
                if let propagatedAttachments =
                    propagatedAttachments[outputIndex] {
                    CVBufferSetAttachments(
                        destinations[outputIndex],
                        propagatedAttachments,
                        .shouldPropagate
                    )
                }
                if let localAttachments = localAttachments[outputIndex] {
                    CVBufferSetAttachments(
                        destinations[outputIndex],
                        localAttachments,
                        .shouldNotPropagate
                    )
                }
            }
        }
    }

    private func validateInterlacedDestination(
        _ destination: CVPixelBuffer
    ) throws {
        guard CVPixelBufferGetPixelFormatType(destination)
                == configuration.storage.pixelFormat,
              CVPixelBufferGetWidth(destination) == configuration.targetWidth,
              CVPixelBufferGetHeight(destination)
                == configuration.targetHeight else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        try PixelLayoutV4(storage: configuration.storage)
            .validateStructure(of: destination)
    }

    private func withLockedPixelBuffers<T>(
        _ requests: [PixelBufferLockRequest],
        operation: () throws -> T
    ) throws -> T {
        var lockedRequests: [PixelBufferLockRequest] = []
        lockedRequests.reserveCapacity(requests.count)
        for request in requests {
            let status = CVPixelBufferLockBaseAddress(
                request.buffer,
                request.flags
            )
            guard status == kCVReturnSuccess else {
                for locked in lockedRequests.reversed() {
                    CVPixelBufferUnlockBaseAddress(
                        locked.buffer,
                        locked.flags
                    )
                }
                throw ASHPreparedTemporalCheckpointV4Error
                    .pixelBufferLockFailed(
                        role: request.role,
                        status: status
                    )
            }
            lockedRequests.append(request)
        }
        defer {
            for request in lockedRequests.reversed() {
                CVPixelBufferUnlockBaseAddress(request.buffer, request.flags)
            }
        }
        return try operation()
    }

    private func validateNonoverlappingPlaneSpans(
        buffers: [CVPixelBuffer]
    ) throws {
        var spans: [PixelBufferPlaneSpan] = []
        for (bufferIndex, buffer) in buffers.enumerated() {
            let planeCount = CVPixelBufferGetPlaneCount(buffer)
            for planeIndex in 0..<planeCount {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(
                    buffer,
                    planeIndex
                ) else {
                    throw ASHPreparedTemporalCheckpointV4Error.invalidState
                }
                let byteCount = CVPixelBufferGetBytesPerRowOfPlane(
                    buffer,
                    planeIndex
                ).multipliedReportingOverflow(
                    by: CVPixelBufferGetHeightOfPlane(buffer, planeIndex)
                )
                guard !byteCount.overflow,
                      let length = UInt(exactly: byteCount.partialValue) else {
                    throw ASHPreparedTemporalCheckpointV4Error.ordinalOverflow
                }
                let start = UInt(bitPattern: base)
                let end = start.addingReportingOverflow(length)
                guard !end.overflow else {
                    throw ASHPreparedTemporalCheckpointV4Error.ordinalOverflow
                }
                spans.append(PixelBufferPlaneSpan(
                    bufferIndex: bufferIndex,
                    planeIndex: planeIndex,
                    start: start,
                    end: end.partialValue
                ))
            }
        }
        for leftIndex in spans.indices {
            for rightIndex in spans.indices where rightIndex > leftIndex {
                let left = spans[leftIndex]
                let right = spans[rightIndex]
                if left.start < right.end, right.start < left.end {
                    throw ASHPreparedTemporalCheckpointV4Error.destinationAlias
                }
            }
        }
    }

    private func validateInterlacedChromaFacts(_ source: CVPixelBuffer) throws {
        guard let fields = configuration.interlacedChromaGeometry else { return }
        for (key, expected) in [
            (kCVImageBufferChromaLocationTopFieldKey, fields.topSource),
            (kCVImageBufferChromaLocationBottomFieldKey, fields.bottomSource)
        ] {
            if let raw = CVBufferCopyAttachment(source, key, nil) {
                guard let value = raw as? String,
                      value == FixedPointPixelBufferScalerV4.chromaLocation(expected) else {
                    throw FixedPointPixelBufferScalerV4Error.chromaSitingMismatch(
                        expected: expected, actual: raw as? String
                    )
                }
            }
        }
    }

    private func scaler(for sourceField: TemporalOutputSourceFieldV4)
        -> FixedPointPixelBufferScalerV4 {
        sourceField == .bottom ? (bottomFieldScaler ?? scaler) : scaler
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

    private func cadencePlane(
        from frame: PixelBufferSignalFrameV4
    ) throws -> FieldPlaneV4 {
        guard let luma = frame.planes.first,
              luma.componentsPerElement == 1,
              let bounds = luma.componentBounds.first else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        return try FieldPlaneV4(
            width: luma.width,
            height: luma.height,
            minimumCode: bounds.minimum,
            maximumCode: bounds.maximum,
            samples: luma.samples
        )
    }

    private func processProgressive(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        sourceField: TemporalOutputSourceFieldV4,
        sourceFrameIndex: Int,
        cadenceID: String,
        resetTrigger: ASHMeasurementResetTriggerV4?,
        typedResetReason: ASHTemporalResetReasonV4?,
        suppressAutomaticSceneCutReset: Bool
    ) async throws -> TemporalOutputFrame {
        let exactPTS = try ExactRationalV4(
            presentationTime.value,
            Int64(presentationTime.timescale)
        )
        if usesBoundedTiledTemporalPath {
            return try await processProgressiveTiled(
                source: source,
                destination: destination,
                presentationTime: presentationTime,
                duration: duration,
                sourceField: sourceField,
                sourceFrameIndex: sourceFrameIndex,
                cadenceID: cadenceID,
                resetTrigger: resetTrigger,
                typedResetReason: typedResetReason,
                suppressAutomaticSceneCutReset:
                    suppressAutomaticSceneCutReset,
                exactPTS: exactPTS
            )
        }
        guard !processingWorkspaces.isEmpty else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let workspaceIndex = Int(
            outputOrdinal % Int64(processingWorkspaces.count)
        )
        let workspace = processingWorkspaces[workspaceIndex]
        try PixelBufferSignalCodecV4.readLuma(
            source,
            storage: configuration.storage,
            into: &workspace.sourceLuma
        )
        let sourceTemporalPlane = try workspace.sourceLuma.temporalPlane()
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
        var measurementMotion: ASHTemporalMotionFieldResultV4?
        if resetTrigger == nil,
           outputOrdinal > 0,
           lastOutputPresentationTime < exactPTS,
           let previousSourceLumaFrame {
            measurementMotion = try ASHTemporalMotionAnalyzerV4.analyzeField(
                current: sourceTemporalFrame,
                previous: previousSourceLumaFrame
            )
        }
#if DEBUG
        lastSourceMotionAllocationDiagnostics = measurementMotion?
            .allocationDiagnostics
#endif
        let effectiveMeasurementReset: ASHMeasurementResetTriggerV4?
        if let resetTrigger {
            effectiveMeasurementReset = resetTrigger
        } else if measurementMotion?.field.sceneCut == true,
                  !suppressAutomaticSceneCutReset {
            effectiveMeasurementReset = .sceneCut
        } else {
            effectiveMeasurementReset = nil
        }
        let forceSpatialFallbackForSuppressedPairedFieldCut =
            suppressAutomaticSceneCutReset
                && measurementMotion?.field.sceneCut == true
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
                = measurementMotion.field.temporalEvidenceQ16
        } else if effectiveMeasurementReset != nil {
            canonicalTemporalEvidenceQ16 = 0
        } else {
            canonicalTemporalEvidenceQ16 = nil
        }
        let directMeasurement = try ASHMeasurementExtractorV4.extractDirect(
            buffer: source,
            storage: configuration.storage,
            previousHistory: previousMeasurementHistory,
            contract: measurementContract,
            history: measurementHistory,
            motionCompensatedTemporalEvidenceQ16:
                canonicalTemporalEvidenceQ16,
            workspace: &workspace.measurement
        )
        let measurement = directMeasurement.extracted
        let retainedSourceFrame = try ASHTemporalFrameV4(
            frameID: sourceTemporalFrame.frameID,
            streamID: sourceTemporalFrame.streamID,
            formatIdentity: sourceTemporalFrame.formatIdentity,
            ordinal: sourceTemporalFrame.ordinal,
            presentationTime: sourceTemporalFrame.presentationTime,
            luma: sourceTemporalFrame.luma,
            tileStateRawValues: [measurement.projection.state.rawValue],
            cadenceID: sourceTemporalFrame.cadenceID
        )

        try await scaler(for: sourceField).process(source: source, destination: destination)
        try PixelBufferSignalCodecV4.readLuma(
            destination,
            storage: configuration.storage,
            into: &workspace.outputLuma
        )
        let outputWidth = workspace.outputLuma.width
        let outputHeight = workspace.outputLuma.height
        let outputMinimumCode = workspace.outputLuma.minimumCode
        let outputMaximumCode = workspace.outputLuma.maximumCode
        _ = try workspace.outputLuma.withMutableSamples { samples in
            try ASHSpatialReconstructorV4.reconstructInPlace(
                samples: &samples,
                width: outputWidth,
                height: outputHeight,
                minimumCode: outputMinimumCode,
                maximumCode: outputMaximumCode,
                sourceState: measurement.projection.state,
                program: branchProgram,
                workspace: &workspace.spatial
            )
        }

        var resetReason = typedResetReason
            ?? effectiveMeasurementReset.map(temporalResetReason)
        var motionField: ASHTemporalMotionFieldV4?
        let dynamicMetadata = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: source)
        // Dynamic HDR metadata is frame-bound. Preserve it exactly by using
        // the spatial path for that frame rather than blending content under
        // metadata that the engine cannot regenerate.
        if dynamicMetadata != nil {
            resetReason = .hdrMetadataChange
        } else if forceSpatialFallbackForSuppressedPairedFieldCut {
            // Output zero already established the new cadence generation.
            // A cut between the paired fields must not blend old evidence or
            // advance that generation a second time.
            motionField = nil
        } else if resetReason == nil,
                  let previous = temporalHistory.frames.last {
            let motion = try analyzeOutputMotionField(
                currentLuma: try workspace.outputLuma.temporalPlane(),
                exactPTS: exactPTS,
                cadenceID: cadenceID,
                stateRawValue: measurement.projection.state.rawValue,
                previous: previous
            )
            #if DEBUG
            lastOutputMotionAllocationDiagnostics = motion
                .allocationDiagnostics
            #endif
            if motion.field.sceneCut {
                if !suppressAutomaticSceneCutReset {
                    resetReason = .sceneCut
                }
            } else {
                motionField = motion.field
            }
        }
#if DEBUG
        if dynamicMetadata != nil
            || forceSpatialFallbackForSuppressedPairedFieldCut
            || resetReason != nil
            || temporalHistory.frames.last == nil {
            lastOutputMotionAllocationDiagnostics = nil
        }
#endif
        let previousOutputFrame = temporalHistory.frames.last
        _ = try workspace.outputLuma.withMutableSamples { samples in
            try ASHTemporalReconstructorV4.reconstructInPlace(
                samples: &samples,
                width: outputWidth,
                height: outputHeight,
                minimumCode: outputMinimumCode,
                maximumCode: outputMaximumCode,
                motionField: motionField,
                previousHistory: previousOutputFrame,
                sourceState: measurement.projection.state,
                resetReason: resetReason,
                program: branchProgram
            )
        }
        let emittedFrame = try ASHTemporalFrameV4(
            frameID: "v4-frame-\(outputOrdinal)",
            streamID: "primary-video",
            formatIdentity: formatIdentity,
            ordinal: outputOrdinal,
            presentationTime: exactPTS,
            luma: try workspace.outputLuma.temporalPlane(),
            tileStateRawValues: [measurement.projection.state.rawValue],
            cadenceID: cadenceID
        )
        var nextTemporalHistory = temporalHistory
        if let resetReason {
            try nextTemporalHistory.reset(reason: resetReason)
        }
        try nextTemporalHistory.append(emittedFrame)
        try PixelBufferSignalCodecV4.writeLuma(
            from: workspace.outputLuma,
            to: destination,
            storage: configuration.storage
        )
        temporalHistory = nextTemporalHistory
        previousMeasurementHistory = directMeasurement.compactHistory
        previousSourceLumaFrame = retainedSourceFrame
        previousMeasurementState = measurement.projection.state
        outputOrdinal += 1
        lastOutputPresentationTime = exactPTS
        return TemporalOutputFrame(
            pixelBuffer: FramePixelBuffer(destination),
            presentationTime: presentationTime,
            duration: duration,
            sourceField: sourceField,
            cadenceID: cadenceID,
            temporalGeneration: temporalHistory.generation,
            temporalResetReason: resetReason
        )
    }

    /// Resolution-independent temporal path. Source/output samples, spatial
    /// conditioning, motion fields, history, and emitted pixels are all
    /// partitioned by the selected canonical tile policy. The fixed-point
    /// scaler itself already uses direct CVPixelBuffer I/O.
    private func processProgressiveTiled(
        source: CVPixelBuffer,
        destination: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        sourceField: TemporalOutputSourceFieldV4,
        sourceFrameIndex: Int,
        cadenceID: String,
        resetTrigger: ASHMeasurementResetTriggerV4?,
        typedResetReason: ASHTemporalResetReasonV4?,
        suppressAutomaticSceneCutReset: Bool,
        exactPTS: ExactRationalV4
    ) async throws -> TemporalOutputFrame {
        guard let policy = temporalTilePolicy,
              !processingWorkspaces.isEmpty else {
            throw ASHPreparedTemporalCheckpointV4Error.invalidState
        }
        let workspaceIndex = Int(
            outputOrdinal % Int64(processingWorkspaces.count)
        )
        let workspace = processingWorkspaces[workspaceIndex]
        let neutralState = try ASHState(rawValue: 0)
        let sourceCapture = try PixelBufferSignalCodecV4.readTiledLuma(
            source,
            storage: configuration.storage,
            frameID: "v4-measurement-\(outputOrdinal)",
            streamID: "primary-video-measurement",
            formatIdentity: formatIdentity,
            ordinal: outputOrdinal,
            presentationTime: exactPTS,
            cadenceID: cadenceID,
            policy: policy,
            stateForTile: { _ in neutralState }
        )
        var measurementMotion: ASHTemporalTiledMotionResultV4?
        if resetTrigger == nil,
           outputOrdinal > 0,
           lastOutputPresentationTime < exactPTS,
           let previousSourceTiledFrame {
            measurementMotion = try ASHTemporalTiledMotionAnalyzerV4.analyze(
                current: sourceCapture.frame,
                previous: previousSourceTiledFrame
            )
        }
        let effectiveMeasurementReset: ASHMeasurementResetTriggerV4?
        if let resetTrigger {
            effectiveMeasurementReset = resetTrigger
        } else if measurementMotion?.field.sceneCut == true,
                  !suppressAutomaticSceneCutReset {
            effectiveMeasurementReset = .sceneCut
        } else {
            effectiveMeasurementReset = nil
        }
        let forceSpatialFallbackForSuppressedPairedFieldCut =
            suppressAutomaticSceneCutReset
                && measurementMotion?.field.sceneCut == true
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
                = measurementMotion.field.temporalEvidenceQ16
        } else if effectiveMeasurementReset != nil {
            canonicalTemporalEvidenceQ16 = 0
        } else {
            canonicalTemporalEvidenceQ16 = nil
        }
        let directMeasurement = try ASHMeasurementExtractorV4.extractDirect(
            buffer: source,
            storage: configuration.storage,
            previousHistory: previousMeasurementHistory,
            contract: measurementContract,
            history: measurementHistory,
            motionCompensatedTemporalEvidenceQ16:
                canonicalTemporalEvidenceQ16,
            workspace: &workspace.measurement
        )
        let measurement = directMeasurement.extracted
        let retainedSourceFrame = ASHTemporalTiledFrameV4(
            frameID: sourceCapture.frame.frameID,
            streamID: sourceCapture.frame.streamID,
            formatIdentity: sourceCapture.frame.formatIdentity,
            ordinal: sourceCapture.frame.ordinal,
            presentationTime: sourceCapture.frame.presentationTime,
            cadenceID: sourceCapture.frame.cadenceID,
            grid: sourceCapture.frame.grid,
            tiles: sourceCapture.frame.tiles.map { tile in
                ASHTemporalTileHistoryStateV4(
                    descriptor: tile.descriptor,
                    minimumCode: tile.minimumCode,
                    maximumCode: tile.maximumCode,
                    retainedSamples: tile.retainedSamples,
                    ashStateRawValue: measurement.projection.state.rawValue
                )
            }
        )
        try retainedSourceFrame.validate()

        try await scaler(for: sourceField).process(source: source, destination: destination)
        let scaledCapture = try PixelBufferSignalCodecV4.readTiledLuma(
            destination,
            storage: configuration.storage,
            frameID: "v4-frame-\(outputOrdinal)",
            streamID: "primary-video",
            formatIdentity: formatIdentity,
            ordinal: outputOrdinal,
            presentationTime: exactPTS,
            cadenceID: cadenceID,
            policy: policy,
            stateForTile: { _ in measurement.projection.state }
        )
        var spatialTiles: [ASHTemporalTileHistoryStateV4] = []
        spatialTiles.reserveCapacity(scaledCapture.frame.grid.tileCount)
        for tile in scaledCapture.frame.tiles {
            try Task.checkCancellation()
            var samples = tile.retainedSamples
            _ = try ASHSpatialReconstructorV4.reconstructInPlace(
                samples: &samples,
                width: tile.descriptor.retained.width,
                height: tile.descriptor.retained.height,
                minimumCode: tile.minimumCode,
                maximumCode: tile.maximumCode,
                sourceState: measurement.projection.state,
                program: branchProgram,
                workspace: &workspace.spatial
            )
            spatialTiles.append(ASHTemporalTileHistoryStateV4(
                descriptor: tile.descriptor,
                minimumCode: tile.minimumCode,
                maximumCode: tile.maximumCode,
                retainedSamples: samples,
                ashStateRawValue: measurement.projection.state.rawValue
            ))
#if DEBUG
            try await tiledTileBoundaryTestHook?(
                tile.descriptor.tileIndex
            )
#endif
        }
        let spatialFrame = ASHTemporalTiledFrameV4(
            frameID: scaledCapture.frame.frameID,
            streamID: scaledCapture.frame.streamID,
            formatIdentity: scaledCapture.frame.formatIdentity,
            ordinal: scaledCapture.frame.ordinal,
            presentationTime: scaledCapture.frame.presentationTime,
            cadenceID: scaledCapture.frame.cadenceID,
            grid: scaledCapture.frame.grid,
            tiles: spatialTiles
        )
        try spatialFrame.validate()

        var resetReason = typedResetReason
            ?? effectiveMeasurementReset.map(temporalResetReason)
        let dynamicMetadata = try AVFoundationHDRMetadataAdapterV4
            .probeDynamicMetadata(from: source)
        if dynamicMetadata != nil {
            resetReason = .hdrMetadataChange
        }
        let previousOutput = tiledTemporalHistory.entries.last?.frame
        var outputMotion: ASHTemporalTiledMotionResultV4?
        if resetReason == nil,
           !forceSpatialFallbackForSuppressedPairedFieldCut,
           let previousOutput {
            outputMotion = try ASHTemporalTiledMotionAnalyzerV4.analyze(
                current: spatialFrame,
                previous: previousOutput
            )
            if outputMotion?.field.sceneCut == true,
               !suppressAutomaticSceneCutReset {
                resetReason = .sceneCut
            }
        } else if forceSpatialFallbackForSuppressedPairedFieldCut {
            resetReason = .sceneCut
        }
        let reconstruction = try ASHTemporalTiledReconstructorV4.reconstruct(
            currentSpatial: spatialFrame,
            previousHistory: previousOutput,
            motionField: outputMotion?.field,
            resetReason: resetReason,
            program: branchProgram,
            executor: deterministicExecutor,
            schedule: temporalTileExecutionSchedule
        )
        // Rebuild retained history directly from the already preflighted
        // active outputs. Re-reading the destination would scan the full 8K
        // luma twice (validation plus capture) without adding evidence.
        let emittedCapture = try ASHTemporalTiledFrameBuilderV4.capture(
            frameID: spatialFrame.frameID,
            streamID: spatialFrame.streamID,
            formatIdentity: spatialFrame.formatIdentity,
            ordinal: spatialFrame.ordinal,
            presentationTime: spatialFrame.presentationTime,
            cadenceID: spatialFrame.cadenceID,
            frameWidth: spatialFrame.grid.frameWidth,
            frameHeight: spatialFrame.grid.frameHeight,
            minimumCode: spatialFrame.tiles[0].minimumCode,
            maximumCode: spatialFrame.tiles[0].maximumCode,
            policy: policy,
            stateForTile: { _ in measurement.projection.state },
            sampleAt: { x, y in
                let column = x / policy.tileWidth
                let row = y / policy.tileHeight
                let tileIndex = row * spatialFrame.grid.columns + column
                guard reconstruction.tiles.indices.contains(tileIndex) else {
                    throw ASHTemporalV4Error.invalidTileState
                }
                let output = reconstruction.tiles[tileIndex]
                let localX = x - output.active.x
                let localY = y - output.active.y
                guard localX >= 0,
                      localX < output.active.width,
                      localY >= 0,
                      localY < output.active.height else {
                    throw ASHTemporalV4Error.invalidTileState
                }
                return output.samples[
                    localY * output.active.width + localX
                ]
            }
        )
        var nextTiledTemporalHistory = tiledTemporalHistory
        if let resetReason {
            try nextTiledTemporalHistory.reset(reason: resetReason)
        }
        try nextTiledTemporalHistory.append(
            emittedCapture.frame,
            motionFromPrevious: resetReason == nil
                ? outputMotion?.field : nil
        )
        try PixelBufferSignalCodecV4.writeTiledLuma(
            reconstruction.tiles,
            grid: spatialFrame.grid,
            to: destination,
            storage: configuration.storage
        )
        tiledTemporalHistory = nextTiledTemporalHistory
        previousMeasurementHistory = directMeasurement.compactHistory
        previousSourceTiledFrame = retainedSourceFrame
        previousSourceLumaFrame = nil
        previousMeasurementState = measurement.projection.state
        outputOrdinal += 1
        lastOutputPresentationTime = exactPTS
#if DEBUG
        lastTiledSourceCaptureDiagnostics = sourceCapture
            .allocationDiagnostics
        lastTiledOutputCaptureDiagnostics = emittedCapture
            .allocationDiagnostics
        lastTiledMotionAllocationDiagnostics = outputMotion?
            .allocationDiagnostics
        lastTiledReconstructionDiagnostics = reconstruction.diagnostics
        lastSourceMotionAllocationDiagnostics = nil
        lastOutputMotionAllocationDiagnostics = nil
#endif
        return TemporalOutputFrame(
            pixelBuffer: FramePixelBuffer(destination),
            presentationTime: presentationTime,
            duration: duration,
            sourceField: sourceField,
            cadenceID: cadenceID,
            temporalGeneration: tiledTemporalHistory.generation,
            temporalResetReason: resetReason
        )
    }

    private func analyzeOutputMotionField(
        currentLuma: ASHTemporalPlaneV4,
        exactPTS: ExactRationalV4,
        cadenceID: String,
        stateRawValue: UInt16,
        previous: ASHTemporalFrameV4
    ) throws -> ASHTemporalMotionFieldResultV4 {
        let current = try ASHTemporalFrameV4(
            frameID: "v4-frame-\(outputOrdinal)",
            streamID: "primary-video",
            formatIdentity: formatIdentity,
            ordinal: outputOrdinal,
            presentationTime: exactPTS,
            luma: currentLuma,
            tileStateRawValues: [stateRawValue],
            cadenceID: cadenceID
        )
        return try ASHTemporalMotionAnalyzerV4.analyzeField(
            current: current,
            previous: previous
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

    /// Detects a source-timeline gap before any temporal evidence is read.
    /// Explicit semantic boundaries win because seeks and edit transitions may
    /// preserve a numerically continuous PTS sequence.
    private func temporalBoundaryReason(
        for timing: FrameTiming
    ) throws -> ASHTemporalResetReasonV4? {
        if let declared = timing.temporalResetReason {
            return declared
        }
        guard lastCompletedInputOrdinal >= 0,
              let lastInputPresentationTime,
              let lastInputDuration,
              timing.presentationTime.isNumeric,
              timing.presentationTime.timescale > 0,
              timing.duration.isNumeric,
              timing.duration.timescale > 0,
              timing.duration.value > 0 else {
            return nil
        }
        let current = try ExactRationalV4(
            timing.presentationTime.value,
            Int64(timing.presentationTime.timescale)
        )
        let expected = try lastInputPresentationTime.adding(lastInputDuration)
        return current == expected ? nil : .presentationTimeDiscontinuity
    }

    private func recordCompletedInputTiming(_ timing: FrameTiming) {
        guard timing.presentationTime.isNumeric,
              timing.presentationTime.timescale > 0,
              timing.duration.isNumeric,
              timing.duration.timescale > 0,
              timing.duration.value > 0,
              let presentation = try? ExactRationalV4(
                timing.presentationTime.value,
                Int64(timing.presentationTime.timescale)
              ),
              let duration = try? ExactRationalV4(
                timing.duration.value,
                Int64(timing.duration.timescale)
              ) else {
            lastInputPresentationTime = nil
            lastInputDuration = nil
            return
        }
        lastInputPresentationTime = presentation
        lastInputDuration = duration
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

    private func beginExclusiveOperation() throws {
        guard !operationInFlight else {
            throw ASHPreparedTemporalCheckpointV4Error.operationInProgress
        }
        operationInFlight = true
    }

    private func endExclusiveOperation() {
        operationInFlight = false
    }

    private func validatedNextInputOrdinal(_ frameIndex: Int) throws -> Int64 {
        guard let actual = Int64(exactly: frameIndex) else {
            throw ASHPreparedTemporalCheckpointV4Error.ordinalOverflow
        }
        let next = lastCompletedInputOrdinal.addingReportingOverflow(1)
        guard !next.overflow else {
            throw ASHPreparedTemporalCheckpointV4Error.ordinalOverflow
        }
        guard actual == next.partialValue else {
            throw ASHPreparedTemporalCheckpointV4Error.inputOrdinalMismatch(
                expected: next.partialValue,
                actual: actual
            )
        }
        return actual
    }

    private func validateOutputOrdinalHeadroom() throws {
        let advance = Int64(maximumOutputFramesPerInput)
        let next = outputOrdinal.addingReportingOverflow(advance)
        guard !next.overflow else {
            throw ASHPreparedTemporalCheckpointV4Error.ordinalOverflow
        }
    }
}

typealias PreparedDeterministicCPUUpscaler = PreparedDeterministicV4Upscaler
typealias PreparedDeterministicMetalUpscaler = PreparedDeterministicV4Upscaler
