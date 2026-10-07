import Foundation

enum ASHTemporalV4Error: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidPlaneGeometry(width: Int, height: Int, sampleCount: Int)
    case invalidCodeRange(minimum: UInt16, maximum: UInt16)
    case sampleOutOfRange(index: Int, value: UInt16)
    case invalidConfiguration
    case frameOrdinalOutOfRange(Int64)
    case negativePresentationTime(ExactRationalV4)
    case nonIncreasingFrameIdentity
    case futureOrConcurrentHistory
    case streamIdentityMismatch
    case formatIdentityMismatch
    case planeGeometryMismatch
    case arithmeticOverflow
    case invalidMotionField
    case invalidHistory
    case unsupportedCheckpointSchema(String)
    case checkpointIdentityMismatch
    case nonCanonicalCheckpoint
    case invalidASHState(UInt16)
    case invalidTileGrid
    case invalidTileState
    case tileAllocationLimitExceeded(sampleCount: Int, limit: Int)
}

enum ASHTemporalResetReasonV4: String, Codable, CaseIterable, Hashable,
    Sendable {
    case streamStart = "stream_start"
    case sceneCut = "scene_cut"
    case discontinuity
    case presentationTimeDiscontinuity = "presentation_time_discontinuity"
    case seek
    case editBoundary = "edit_boundary"
    case formatChange = "format_change"
    case geometryChange = "geometry_change"
    case pixelFormatChange = "pixel_format_change"
    case colorDomainChange = "color_domain_change"
    case hdrMetadataChange = "hdr_metadata_change"
    case fieldCadenceChange = "field_cadence_change"
    case contractChange = "contract_change"
    case explicitReset = "explicit_reset"

    /// The measurement contract predates the finer operational reset
    /// vocabulary. Keep its stable artifact enum unchanged and map each typed
    /// boundary to the nearest already-qualified measurement reset rule.
    var measurementTrigger: ASHMeasurementResetTriggerV4 {
        switch self {
        case .streamStart:
            .streamStart
        case .sceneCut:
            .sceneCut
        case .discontinuity, .presentationTimeDiscontinuity, .editBoundary,
             .formatChange:
            .discontinuity
        case .seek:
            .seek
        case .geometryChange:
            .geometryChange
        case .pixelFormatChange:
            .pixelFormatChange
        case .colorDomainChange, .hdrMetadataChange:
            .colorDomainChange
        case .fieldCadenceChange:
            .fieldCadenceChange
        case .contractChange:
            .contractChange
        case .explicitReset:
            .explicitReset
        }
    }
}

/// Typed continuity evidence evaluated before a frame can observe history.
/// Identities are kept outside ASH9; a change clears temporal evidence rather
/// than being folded into a canonical state bit.
struct ASHTemporalContinuityDescriptorV4: Codable, Equatable, Hashable,
    Sendable {
    let frameOrdinal: Int64
    let presentationTime: ExactRationalV4
    let duration: ExactRationalV4
    let editIdentity: ASHSHA256V4
    let formatIdentity: ASHSHA256V4
    let geometryIdentity: ASHSHA256V4
    let pixelFormatIdentity: ASHSHA256V4
    let colorIdentity: ASHSHA256V4
    let hdrMetadataIdentity: ASHSHA256V4?
    let cadenceIdentity: ASHSHA256V4
    let contractIdentity: ASHSHA256V4
    let declaredReset: ASHTemporalResetReasonV4?

    init(
        frameOrdinal: Int64,
        presentationTime: ExactRationalV4,
        duration: ExactRationalV4,
        editIdentity: ASHSHA256V4,
        formatIdentity: ASHSHA256V4,
        geometryIdentity: ASHSHA256V4,
        pixelFormatIdentity: ASHSHA256V4,
        colorIdentity: ASHSHA256V4,
        hdrMetadataIdentity: ASHSHA256V4?,
        cadenceIdentity: ASHSHA256V4,
        contractIdentity: ASHSHA256V4,
        declaredReset: ASHTemporalResetReasonV4? = nil
    ) throws {
        guard frameOrdinal >= 0,
              presentationTime >= .zero,
              duration > .zero,
              declaredReset != .streamStart,
              declaredReset != .sceneCut else {
            throw ASHTemporalV4Error.invalidHistory
        }
        self.frameOrdinal = frameOrdinal
        self.presentationTime = presentationTime
        self.duration = duration
        self.editIdentity = editIdentity
        self.formatIdentity = formatIdentity
        self.geometryIdentity = geometryIdentity
        self.pixelFormatIdentity = pixelFormatIdentity
        self.colorIdentity = colorIdentity
        self.hdrMetadataIdentity = hdrMetadataIdentity
        self.cadenceIdentity = cadenceIdentity
        self.contractIdentity = contractIdentity
        self.declaredReset = declaredReset
    }

    func validate() throws {
        _ = try Self(
            frameOrdinal: frameOrdinal,
            presentationTime: presentationTime,
            duration: duration,
            editIdentity: editIdentity,
            formatIdentity: formatIdentity,
            geometryIdentity: geometryIdentity,
            pixelFormatIdentity: pixelFormatIdentity,
            colorIdentity: colorIdentity,
            hdrMetadataIdentity: hdrMetadataIdentity,
            cadenceIdentity: cadenceIdentity,
            contractIdentity: contractIdentity,
            declaredReset: declaredReset
        )
    }
}

struct ASHTemporalResetDecisionV4: Codable, Equatable, Hashable, Sendable {
    let primaryReason: ASHTemporalResetReasonV4?
    /// Every simultaneous boundary is retained in deterministic priority
    /// order so diagnostics and checkpoints never erase a secondary cause.
    let reasons: [ASHTemporalResetReasonV4]

    var resetsHistory: Bool { primaryReason != nil }
}

enum ASHTemporalContinuityEvaluatorV4 {
    static func evaluate(
        previous: ASHTemporalContinuityDescriptorV4?,
        current: ASHTemporalContinuityDescriptorV4
    ) throws -> ASHTemporalResetDecisionV4 {
        try current.validate()
        guard let previous else {
            return ASHTemporalResetDecisionV4(
                primaryReason: .streamStart,
                reasons: [.streamStart]
            )
        }
        try previous.validate()
        var reasons: [ASHTemporalResetReasonV4] = []
        if let declared = current.declaredReset {
            reasons.append(declared)
        }
        let expectedOrdinal = previous.frameOrdinal.addingReportingOverflow(1)
        if expectedOrdinal.overflow
            || expectedOrdinal.partialValue != current.frameOrdinal {
            reasons.append(.seek)
        }
        let expectedPresentation = try previous.presentationTime.adding(
            previous.duration
        )
        if expectedPresentation != current.presentationTime {
            reasons.append(.presentationTimeDiscontinuity)
        }
        if previous.editIdentity != current.editIdentity {
            reasons.append(.editBoundary)
        }
        if previous.geometryIdentity != current.geometryIdentity {
            reasons.append(.geometryChange)
        }
        if previous.pixelFormatIdentity != current.pixelFormatIdentity {
            reasons.append(.pixelFormatChange)
        }
        if previous.formatIdentity != current.formatIdentity {
            reasons.append(.formatChange)
        }
        if previous.colorIdentity != current.colorIdentity {
            reasons.append(.colorDomainChange)
        }
        if previous.hdrMetadataIdentity != current.hdrMetadataIdentity {
            reasons.append(.hdrMetadataChange)
        }
        if previous.cadenceIdentity != current.cadenceIdentity {
            reasons.append(.fieldCadenceChange)
        }
        if previous.contractIdentity != current.contractIdentity {
            reasons.append(.contractChange)
        }
        var seen = Set<ASHTemporalResetReasonV4>()
        let ordered = reasons.filter { seen.insert($0).inserted }
        return ASHTemporalResetDecisionV4(
            primaryReason: ordered.first,
            reasons: ordered
        )
    }
}

/// Tight, active-image-only luma storage used at the temporal and checkpoint
/// boundary. Padding bytes never become evidence or durable state.
struct ASHTemporalPlaneV4: Codable, Equatable, Hashable, Sendable {
    static let maximumSampleCount = 16_777_216

    let width: Int
    let height: Int
    let minimumCode: UInt16
    let maximumCode: UInt16
    let samples: [UInt16]

    init(
        width: Int,
        height: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        samples: [UInt16]
    ) throws {
        guard width > 0, height > 0 else {
            throw ASHTemporalV4Error.invalidPlaneGeometry(
                width: width,
                height: height,
                sampleCount: samples.count
            )
        }
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow,
              product.partialValue == samples.count,
              product.partialValue <= Self.maximumSampleCount else {
            throw ASHTemporalV4Error.invalidPlaneGeometry(
                width: width,
                height: height,
                sampleCount: samples.count
            )
        }
        guard minimumCode < maximumCode else {
            throw ASHTemporalV4Error.invalidCodeRange(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        for (index, sample) in samples.enumerated()
        where sample < minimumCode || sample > maximumCode {
            throw ASHTemporalV4Error.sampleOutOfRange(
                index: index,
                value: sample
            )
        }
        self.width = width
        self.height = height
        self.minimumCode = minimumCode
        self.maximumCode = maximumCode
        self.samples = samples
    }

    func sample(x: Int, y: Int) -> UInt16 {
        samples[y * width + x]
    }

    func replacing(samples: [UInt16]) throws -> Self {
        try Self(
            width: width,
            height: height,
            minimumCode: minimumCode,
            maximumCode: maximumCode,
            samples: samples
        )
    }

    /// Replays every invariant because synthesized Codable bypasses `init`.
    func validate() throws {
        _ = try Self(
            width: width,
            height: height,
            minimumCode: minimumCode,
            maximumCode: maximumCode,
            samples: samples
        )
    }
}

struct ASHTemporalFrameV4: Codable, Equatable, Hashable, Sendable {
    let frameID: String
    let streamID: String
    let formatIdentity: ASHSHA256V4
    let ordinal: Int64
    let presentationTime: ExactRationalV4
    let luma: ASHTemporalPlaneV4
    let tileStateRawValues: [UInt16]
    let cadenceID: String

    init(
        frameID: String,
        streamID: String,
        formatIdentity: ASHSHA256V4,
        ordinal: Int64,
        presentationTime: ExactRationalV4,
        luma: ASHTemporalPlaneV4,
        tileStateRawValues: [UInt16],
        cadenceID: String
    ) throws {
        guard Self.validIdentifier(frameID) else {
            throw ASHTemporalV4Error.invalidIdentifier(frameID)
        }
        guard Self.validIdentifier(streamID) else {
            throw ASHTemporalV4Error.invalidIdentifier(streamID)
        }
        guard Self.validIdentifier(cadenceID) else {
            throw ASHTemporalV4Error.invalidIdentifier(cadenceID)
        }
        guard ordinal >= 0 else {
            throw ASHTemporalV4Error.frameOrdinalOutOfRange(ordinal)
        }
        guard presentationTime >= .zero else {
            throw ASHTemporalV4Error.negativePresentationTime(
                presentationTime
            )
        }
        for rawValue in tileStateRawValues {
            guard let state = try? ASHState(rawValue: rawValue),
                  state.hasValidIntegrity else {
                throw ASHTemporalV4Error.invalidASHState(rawValue)
            }
        }
        self.frameID = frameID
        self.streamID = streamID
        self.formatIdentity = formatIdentity
        self.ordinal = ordinal
        self.presentationTime = presentationTime
        self.luma = luma
        self.tileStateRawValues = tileStateRawValues
        self.cadenceID = cadenceID
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 127
            && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }

    /// Replays identifier, time, luma, and tile-state validation after decode.
    func validate() throws {
        guard Self.validIdentifier(frameID) else {
            throw ASHTemporalV4Error.invalidIdentifier(frameID)
        }
        guard Self.validIdentifier(streamID) else {
            throw ASHTemporalV4Error.invalidIdentifier(streamID)
        }
        guard Self.validIdentifier(cadenceID) else {
            throw ASHTemporalV4Error.invalidIdentifier(cadenceID)
        }
        guard ordinal >= 0 else {
            throw ASHTemporalV4Error.frameOrdinalOutOfRange(ordinal)
        }
        guard presentationTime >= .zero else {
            throw ASHTemporalV4Error.negativePresentationTime(
                presentationTime
            )
        }
        try luma.validate()
        for rawValue in tileStateRawValues {
            guard let state = try? ASHState(rawValue: rawValue),
                  state.hasValidIntegrity else {
                throw ASHTemporalV4Error.invalidASHState(rawValue)
            }
        }
    }
}

struct ASHTemporalBlockMatchingConfigurationV4: Codable, Equatable, Hashable,
    Sendable {
    static let canonical = try! Self(
        policyID: "ash.p06.temporal.block-match.q16.v1",
        blockWidth: 8,
        blockHeight: 8,
        searchRadius: 4,
        sceneCutHistogramThresholdQ16: 24_576,
        occlusionCostThresholdQ16: 12_288,
        minimumConfidenceQ16: 2_048
    )

    let policyID: String
    let blockWidth: Int
    let blockHeight: Int
    let searchRadius: Int
    let sceneCutHistogramThresholdQ16: UInt32
    let occlusionCostThresholdQ16: UInt32
    let minimumConfidenceQ16: UInt32

    init(
        policyID: String,
        blockWidth: Int,
        blockHeight: Int,
        searchRadius: Int,
        sceneCutHistogramThresholdQ16: UInt32,
        occlusionCostThresholdQ16: UInt32,
        minimumConfidenceQ16: UInt32
    ) throws {
        guard ASHTemporalFrameV4.validIdentifier(policyID),
              (1...64).contains(blockWidth),
              (1...64).contains(blockHeight),
              (0...32).contains(searchRadius),
              sceneCutHistogramThresholdQ16 <= ASHNormalizedQ16V4.scale,
              occlusionCostThresholdQ16 <= ASHNormalizedQ16V4.scale,
              minimumConfidenceQ16 <= ASHNormalizedQ16V4.scale else {
            throw ASHTemporalV4Error.invalidConfiguration
        }
        self.policyID = policyID
        self.blockWidth = blockWidth
        self.blockHeight = blockHeight
        self.searchRadius = searchRadius
        self.sceneCutHistogramThresholdQ16 = sceneCutHistogramThresholdQ16
        self.occlusionCostThresholdQ16 = occlusionCostThresholdQ16
        self.minimumConfidenceQ16 = minimumConfidenceQ16
    }
}

struct ASHTemporalMotionVectorV4: Codable, Equatable, Hashable, Sendable {
    let blockIndex: Int
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    let dx: Int16
    let dy: Int16
    let absoluteDifference: UInt64
    let normalizedCostQ16: UInt32
    let confidenceQ16: UInt32
    let occluded: Bool
}

struct ASHTemporalMotionAnalysisV4: Codable, Equatable, Hashable, Sendable {
    let policyID: String
    let currentFrameID: String
    let previousFrameID: String
    let sceneDifferenceQ16: UInt32
    let sceneCut: Bool
    let temporalEvidenceQ16: UInt32
    let blockColumns: Int
    let blockRows: Int
    let vectors: [ASHTemporalMotionVectorV4]
    let alignedPrevious: ASHTemporalPlaneV4?

    func validate() throws {
        guard ASHTemporalFrameV4.validIdentifier(policyID),
              ASHTemporalFrameV4.validIdentifier(currentFrameID),
              ASHTemporalFrameV4.validIdentifier(previousFrameID),
              currentFrameID != previousFrameID,
              sceneDifferenceQ16 <= ASHNormalizedQ16V4.scale,
              temporalEvidenceQ16 <= ASHNormalizedQ16V4.scale,
              blockColumns > 0,
              blockRows > 0 else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        if sceneCut {
            guard vectors.isEmpty, alignedPrevious == nil else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            return
        }
        guard let alignedPrevious else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        do {
            try alignedPrevious.validate()
        } catch {
            throw ASHTemporalV4Error.invalidMotionField
        }
        let count = blockColumns.multipliedReportingOverflow(by: blockRows)
        guard !count.overflow,
              count.partialValue == vectors.count,
              vectors.enumerated().allSatisfy({ offset, vector in
                  vector.blockIndex == offset
                      && vector.normalizedCostQ16
                          <= ASHNormalizedQ16V4.scale
                      && vector.confidenceQ16 <= ASHNormalizedQ16V4.scale
              }) else {
            throw ASHTemporalV4Error.invalidMotionField
        }
    }
}

/// Canonical block motion without a materialized aligned image. Geometry and
/// identity fields bind vectors to the exact current/previous luma pair; the
/// reconstruction path samples the retained previous plane by `(dx, dy)`.
struct ASHTemporalMotionFieldV4: Codable, Equatable, Hashable, Sendable {
    let policyID: String
    let currentFrameID: String
    let previousFrameID: String
    let streamID: String
    let formatIdentity: ASHSHA256V4
    let planeWidth: Int
    let planeHeight: Int
    let minimumCode: UInt16
    let maximumCode: UInt16
    let sceneDifferenceQ16: UInt32
    let sceneCut: Bool
    let temporalEvidenceQ16: UInt32
    let blockColumns: Int
    let blockRows: Int
    let vectors: [ASHTemporalMotionVectorV4]

    func validate() throws {
        guard ASHTemporalFrameV4.validIdentifier(policyID),
              ASHTemporalFrameV4.validIdentifier(currentFrameID),
              ASHTemporalFrameV4.validIdentifier(previousFrameID),
              currentFrameID != previousFrameID,
              ASHTemporalFrameV4.validIdentifier(streamID),
              planeWidth > 0,
              planeHeight > 0,
              minimumCode < maximumCode,
              sceneDifferenceQ16 <= ASHNormalizedQ16V4.scale,
              temporalEvidenceQ16 <= ASHNormalizedQ16V4.scale,
              blockColumns > 0,
              blockRows > 0 else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        if sceneCut {
            guard vectors.isEmpty else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            return
        }
        let count = blockColumns.multipliedReportingOverflow(by: blockRows)
        guard !count.overflow, count.partialValue == vectors.count else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        for (offset, vector) in vectors.enumerated() {
            let endX = vector.originX.addingReportingOverflow(vector.width)
            let endY = vector.originY.addingReportingOverflow(vector.height)
            let sourceX = vector.originX.addingReportingOverflow(
                Int(vector.dx)
            )
            let sourceY = vector.originY.addingReportingOverflow(
                Int(vector.dy)
            )
            let sourceEndX = sourceX.partialValue.addingReportingOverflow(
                vector.width
            )
            let sourceEndY = sourceY.partialValue.addingReportingOverflow(
                vector.height
            )
            guard vector.blockIndex == offset,
                  vector.normalizedCostQ16 <= ASHNormalizedQ16V4.scale,
                  vector.confidenceQ16 <= ASHNormalizedQ16V4.scale,
                  vector.originX >= 0,
                  vector.originY >= 0,
                  vector.width > 0,
                  vector.height > 0,
                  !endX.overflow,
                  !endY.overflow,
                  endX.partialValue <= planeWidth,
                  endY.partialValue <= planeHeight,
                  !sourceX.overflow,
                  !sourceY.overflow,
                  !sourceEndX.overflow,
                  !sourceEndY.overflow,
                  sourceX.partialValue >= 0,
                  sourceY.partialValue >= 0,
                  sourceEndX.partialValue <= planeWidth,
                  sourceEndY.partialValue <= planeHeight else {
                throw ASHTemporalV4Error.invalidMotionField
            }
        }
        guard let first = vectors.first,
              first.originX == 0,
              first.originY == 0,
              first.width > 0,
              first.height > 0 else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        let expectedColumns = planeWidth / first.width
            + (planeWidth % first.width == 0 ? 0 : 1)
        let expectedRows = planeHeight / first.height
            + (planeHeight % first.height == 0 ? 0 : 1)
        guard expectedColumns == blockColumns,
              expectedRows == blockRows else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        for (index, vector) in vectors.enumerated() {
            let column = index % blockColumns
            let row = index / blockColumns
            let expectedX = column.multipliedReportingOverflow(by: first.width)
            let expectedY = row.multipliedReportingOverflow(by: first.height)
            guard !expectedX.overflow,
                  !expectedY.overflow,
                  expectedX.partialValue < planeWidth,
                  expectedY.partialValue < planeHeight else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            guard vector.originX == expectedX.partialValue,
                  vector.originY == expectedY.partialValue,
                  vector.width == min(
                    first.width,
                    planeWidth - expectedX.partialValue
                  ),
                  vector.height == min(
                    first.height,
                    planeHeight - expectedY.partialValue
                  ) else {
                throw ASHTemporalV4Error.invalidMotionField
            }
        }
    }
}

struct ASHTemporalMotionAllocationDiagnosticsV4: Equatable, Sendable {
    /// Streaming total-order selection retains only best and second-best.
    let maximumRetainedCandidatesPerBlock: Int
    let materializedAlignedSampleCount: Int
    let vectorCount: Int
    let vectorStorageByteUpperBound: Int
}

struct ASHTemporalMotionFieldResultV4: Equatable, Sendable {
    let field: ASHTemporalMotionFieldV4
    let allocationDiagnostics: ASHTemporalMotionAllocationDiagnosticsV4
}

enum ASHTemporalMotionExecutionPolicyV4: Sendable {
    case automatic
    case serial
    case parallel(maximumWorkers: Int)

    static let parallelBlockThreshold = 256

    func workerCount(rows: Int, blockCount: Int) throws -> Int {
        let available = max(1, ProcessInfo.processInfo.activeProcessorCount)
        switch self {
        case .automatic:
            return blockCount < Self.parallelBlockThreshold
                ? 1 : min(rows, available)
        case .serial:
            return 1
        case .parallel(let maximumWorkers):
            guard maximumWorkers > 0 else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            return min(rows, min(available, maximumWorkers))
        }
    }
}

private enum ASHTemporalMotionBatchExecutorV4 {
    private static let queue = DispatchQueue(
        label: "com.mirmir.deterministic.motion.v4",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func perform(iterations: Int, work: @Sendable (Int) -> Void) {
        queue.sync {
            DispatchQueue.concurrentPerform(iterations: iterations, execute: work)
        }
    }
}

// Matching reads immutable samples and owns its result buffers. The lock
// protects only publication; concurrentPerform joins before ordered reads.
private final class ASHTemporalMotionBatchResultsV4<Payload: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Payload, Error>?]

    init(count: Int) {
        results = Array(repeating: nil, count: count)
    }

    func store(_ result: Result<Payload, Error>, at index: Int) {
        lock.lock()
        results[index] = result
        lock.unlock()
    }

    func take(at index: Int) throws -> Payload {
        lock.lock()
        let result = results[index]
        results[index] = nil
        lock.unlock()
        guard let result else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        return try result.get()
    }
}

enum ASHTemporalMotionAnalyzerV4 {
    private struct Candidate: Comparable {
        let absoluteDifference: UInt64
        let dx: Int
        let dy: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.absoluteDifference != rhs.absoluteDifference {
                return lhs.absoluteDifference < rhs.absoluteDifference
            }
            let leftDistance = abs(lhs.dx) + abs(lhs.dy)
            let rightDistance = abs(rhs.dx) + abs(rhs.dy)
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            if lhs.dy != rhs.dy { return lhs.dy < rhs.dy }
            return lhs.dx < rhs.dx
        }
    }

    static func analyze(
        current: ASHTemporalFrameV4,
        previous: ASHTemporalFrameV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4 = .canonical
    ) throws -> ASHTemporalMotionAnalysisV4 {
        let fieldResult = try analyzeField(
            current: current,
            previous: previous,
            configuration: configuration
        )
        let field = fieldResult.field
        if field.sceneCut {
            let result = ASHTemporalMotionAnalysisV4(
                policyID: field.policyID,
                currentFrameID: field.currentFrameID,
                previousFrameID: field.previousFrameID,
                sceneDifferenceQ16: field.sceneDifferenceQ16,
                sceneCut: true,
                temporalEvidenceQ16: field.temporalEvidenceQ16,
                blockColumns: field.blockColumns,
                blockRows: field.blockRows,
                vectors: [],
                alignedPrevious: nil
            )
            try result.validate()
            return result
        }
        var aligned = Array(
            repeating: UInt16(0),
            count: current.luma.samples.count
        )
        for vector in field.vectors {
            for y in vector.originY..<(vector.originY + vector.height) {
                let sourceY = y + Int(vector.dy)
                for x in vector.originX..<(vector.originX + vector.width) {
                    aligned[y * field.planeWidth + x] = previous.luma.sample(
                        x: x + Int(vector.dx),
                        y: sourceY
                    )
                }
            }
        }
        let result = ASHTemporalMotionAnalysisV4(
            policyID: field.policyID,
            currentFrameID: field.currentFrameID,
            previousFrameID: field.previousFrameID,
            sceneDifferenceQ16: field.sceneDifferenceQ16,
            sceneCut: false,
            temporalEvidenceQ16: field.temporalEvidenceQ16,
            blockColumns: field.blockColumns,
            blockRows: field.blockRows,
            vectors: field.vectors,
            alignedPrevious: try current.luma.replacing(samples: aligned)
        )
        try result.validate()
        return result
    }

    /// Performs canonical matching while retaining only two ordered candidates
    /// per block and never constructing the aligned previous image.
    static func analyzeField(
        current: ASHTemporalFrameV4,
        previous: ASHTemporalFrameV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4 = .canonical,
        executionPolicy: ASHTemporalMotionExecutionPolicyV4 = .automatic
    ) throws -> ASHTemporalMotionFieldResultV4 {
        try Task.checkCancellation()
        try current.validate()
        try previous.validate()
        guard previous.ordinal < current.ordinal,
              previous.presentationTime < current.presentationTime else {
            throw ASHTemporalV4Error.futureOrConcurrentHistory
        }
        guard previous.frameID != current.frameID else {
            throw ASHTemporalV4Error.nonIncreasingFrameIdentity
        }
        guard previous.streamID == current.streamID else {
            throw ASHTemporalV4Error.streamIdentityMismatch
        }
        guard previous.formatIdentity == current.formatIdentity else {
            throw ASHTemporalV4Error.formatIdentityMismatch
        }
        let currentPlane = current.luma
        let previousPlane = previous.luma
        guard currentPlane.width == previousPlane.width,
              currentPlane.height == previousPlane.height,
              currentPlane.minimumCode == previousPlane.minimumCode,
              currentPlane.maximumCode == previousPlane.maximumCode else {
            throw ASHTemporalV4Error.planeGeometryMismatch
        }

        let sceneDifference = try histogramDifferenceQ16(
            current: currentPlane,
            previous: previousPlane
        )
        let columns = ceilingDivision(
            currentPlane.width,
            configuration.blockWidth
        )
        let rows = ceilingDivision(
            currentPlane.height,
            configuration.blockHeight
        )
        let workerCount = try executionPolicy.workerCount(
            rows: rows,
            blockCount: columns * rows
        )
        if sceneDifference >= configuration.sceneCutHistogramThresholdQ16 {
            let field = ASHTemporalMotionFieldV4(
                policyID: configuration.policyID,
                currentFrameID: current.frameID,
                previousFrameID: previous.frameID,
                streamID: current.streamID,
                formatIdentity: current.formatIdentity,
                planeWidth: currentPlane.width,
                planeHeight: currentPlane.height,
                minimumCode: currentPlane.minimumCode,
                maximumCode: currentPlane.maximumCode,
                sceneDifferenceQ16: sceneDifference,
                sceneCut: true,
                temporalEvidenceQ16: sceneDifference,
                blockColumns: columns,
                blockRows: rows,
                vectors: []
            )
            try field.validate()
            return ASHTemporalMotionFieldResultV4(
                field: field,
                allocationDiagnostics:
                    ASHTemporalMotionAllocationDiagnosticsV4(
                        maximumRetainedCandidatesPerBlock: 2,
                        materializedAlignedSampleCount: 0,
                        vectorCount: 0,
                        vectorStorageByteUpperBound: 0
                    )
            )
        }

        var vectors: [ASHTemporalMotionVectorV4] = []
        if workerCount == 1 {
            vectors = try matchRows(
                0..<rows,
                columns: columns,
                currentPlane: currentPlane,
                previousPlane: previousPlane,
                configuration: configuration,
                checkCancellation: true
            )
        } else {
            vectors.reserveCapacity(columns * rows)
            let results = ASHTemporalMotionBatchResultsV4<
                [ASHTemporalMotionVectorV4]
            >(count: workerCount)
            let rowsPerWorker = rows / workerCount
            let extraRows = rows % workerCount
            ASHTemporalMotionBatchExecutorV4.perform(iterations: workerCount) { index in
                let lower = index * rowsPerWorker + min(index, extraRows)
                let upper = lower + rowsPerWorker + (index < extraRows ? 1 : 0)
                results.store(Result {
                    try matchRows(
                        lower..<upper,
                        columns: columns,
                        currentPlane: currentPlane,
                        previousPlane: previousPlane,
                        configuration: configuration
                    )
                }, at: index)
            }
            // Dispatch workers do not inherit the initiating Swift task.
            try Task.checkCancellation()
            // Completion order never changes vector order or error selection.
            for index in 0..<workerCount {
                vectors.append(contentsOf: try results.take(at: index))
            }
        }
        try Task.checkCancellation()

        var weightedEvidence: UInt64 = 0
        var weightedCount: UInt64 = 0
        for vector in vectors {
            let sampleCount = UInt64(vector.width * vector.height)
            let weighted = UInt64(vector.normalizedCostQ16)
                .multipliedReportingOverflow(by: sampleCount)
            let nextEvidence = weightedEvidence.addingReportingOverflow(
                weighted.partialValue
            )
            let nextCount = weightedCount.addingReportingOverflow(sampleCount)
            guard !weighted.overflow,
                  !nextEvidence.overflow,
                  !nextCount.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            weightedEvidence = nextEvidence.partialValue
            weightedCount = nextCount.partialValue
        }
        let temporalEvidence = try divideRoundedTiesToEven(
            weightedEvidence,
            by: weightedCount
        )
        guard temporalEvidence <= UInt64(ASHNormalizedQ16V4.scale) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let field = ASHTemporalMotionFieldV4(
            policyID: configuration.policyID,
            currentFrameID: current.frameID,
            previousFrameID: previous.frameID,
            streamID: current.streamID,
            formatIdentity: current.formatIdentity,
            planeWidth: currentPlane.width,
            planeHeight: currentPlane.height,
            minimumCode: currentPlane.minimumCode,
            maximumCode: currentPlane.maximumCode,
            sceneDifferenceQ16: sceneDifference,
            sceneCut: false,
            temporalEvidenceQ16: UInt32(temporalEvidence),
            blockColumns: columns,
            blockRows: rows,
            vectors: vectors
        )
        try field.validate()
        let vectorBytes = vectors.count.multipliedReportingOverflow(
            by: MemoryLayout<ASHTemporalMotionVectorV4>.stride
                * (workerCount > 1 ? 2 : 1)
        )
        guard !vectorBytes.overflow else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return ASHTemporalMotionFieldResultV4(
            field: field,
            allocationDiagnostics: ASHTemporalMotionAllocationDiagnosticsV4(
                maximumRetainedCandidatesPerBlock: 2,
                materializedAlignedSampleCount: 0,
                vectorCount: vectors.count,
                vectorStorageByteUpperBound: vectorBytes.partialValue
            )
        )
    }

    private static func matchRows(
        _ rowRange: Range<Int>,
        columns: Int,
        currentPlane: ASHTemporalPlaneV4,
        previousPlane: ASHTemporalPlaneV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4,
        checkCancellation: Bool = false
    ) throws -> [ASHTemporalMotionVectorV4] {
        let signalRange = UInt64(
            currentPlane.maximumCode - currentPlane.minimumCode
        )
        var vectors: [ASHTemporalMotionVectorV4] = []
        vectors.reserveCapacity(columns * rowRange.count)

        for blockY in rowRange {
            if checkCancellation { try Task.checkCancellation() }
            for blockX in 0..<columns {
                let originX = blockX * configuration.blockWidth
                let originY = blockY * configuration.blockHeight
                let width = min(
                    configuration.blockWidth,
                    currentPlane.width - originX
                )
                let height = min(
                    configuration.blockHeight,
                    currentPlane.height - originY
                )
                let candidates = try bestTwoCandidates(
                    current: currentPlane,
                    previous: previousPlane,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    radius: configuration.searchRadius
                )
                let best = candidates.best
                let second = candidates.second
                let sampleCount = UInt64(width * height)
                let denominator = sampleCount.multipliedReportingOverflow(
                    by: signalRange
                )
                guard !denominator.overflow else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                let costQ16 = try normalizedQ16(
                    numerator: best.absoluteDifference,
                    denominator: denominator.partialValue
                )
                let confidenceQ16: UInt32
                if second.absoluteDifference > best.absoluteDifference {
                    confidenceQ16 = try normalizedQ16(
                        numerator: second.absoluteDifference
                            - best.absoluteDifference,
                        denominator: max(second.absoluteDifference, 1)
                    )
                } else {
                    confidenceQ16 = 0
                }
                let occluded = costQ16
                    > configuration.occlusionCostThresholdQ16
                    || confidenceQ16 < configuration.minimumConfidenceQ16
                let index = blockY * columns + blockX
                vectors.append(ASHTemporalMotionVectorV4(
                    blockIndex: index,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    dx: Int16(best.dx),
                    dy: Int16(best.dy),
                    absoluteDifference: best.absoluteDifference,
                    normalizedCostQ16: costQ16,
                    confidenceQ16: confidenceQ16,
                    occluded: occluded
                ))
            }
        }
        return vectors
    }

    private static func bestTwoCandidates(
        current: ASHTemporalPlaneV4,
        previous: ASHTemporalPlaneV4,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        radius: Int
    ) throws -> (best: Candidate, second: Candidate) {
        let minimumDX = max(-radius, -originX)
        let maximumDX = min(radius, previous.width - originX - width)
        let minimumDY = max(-radius, -originY)
        let maximumDY = min(radius, previous.height - originY - height)
        guard minimumDX <= maximumDX, minimumDY <= maximumDY else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        return try current.samples.withUnsafeBufferPointer { currentSamples in
            try previous.samples.withUnsafeBufferPointer { previousSamples in
                var best: Candidate?
                var second: Candidate?
                for dy in minimumDY...maximumDY {
                    for dx in minimumDX...maximumDX {
                        var difference: UInt64 = 0
                        for localY in 0..<height {
                            for localX in 0..<width {
                                let currentValue = currentSamples[
                                    (originY + localY) * current.width
                                        + originX + localX
                                ]
                                let previousValue = previousSamples[
                                    (originY + localY + dy) * previous.width
                                        + originX + localX + dx
                                ]
                                let delta = currentValue > previousValue
                                    ? UInt64(currentValue - previousValue)
                                    : UInt64(previousValue - currentValue)
                                let sum = difference.addingReportingOverflow(delta)
                                guard !sum.overflow else {
                                    throw ASHTemporalV4Error.arithmeticOverflow
                                }
                                difference = sum.partialValue
                            }
                        }
                        let candidate = Candidate(
                            absoluteDifference: difference,
                            dx: dx,
                            dy: dy
                        )
                        if best == nil || candidate < best! {
                            second = best
                            best = candidate
                        } else if second == nil || candidate < second! {
                            second = candidate
                        }
                    }
                }
                guard let best else {
                    throw ASHTemporalV4Error.invalidMotionField
                }
                return (best, second ?? best)
            }
        }
    }

    private static func histogramDifferenceQ16(
        current: ASHTemporalPlaneV4,
        previous: ASHTemporalPlaneV4
    ) throws -> UInt32 {
        let binCount = 16
        let range = UInt64(current.maximumCode - current.minimumCode) + 1
        var currentBins = Array(repeating: UInt64(0), count: binCount)
        var previousBins = Array(repeating: UInt64(0), count: binCount)
        for sample in current.samples {
            let offset = UInt64(sample - current.minimumCode)
            currentBins[min(Int(offset * UInt64(binCount) / range), 15)] += 1
        }
        for sample in previous.samples {
            let offset = UInt64(sample - previous.minimumCode)
            previousBins[min(Int(offset * UInt64(binCount) / range), 15)] += 1
        }
        let difference = zip(currentBins, previousBins).reduce(UInt64(0)) {
            $0 + ($1.0 > $1.1 ? $1.0 - $1.1 : $1.1 - $1.0)
        }
        let denominator = UInt64(current.samples.count) * 2
        return try normalizedQ16(
            numerator: difference,
            denominator: denominator
        )
    }

    private static func normalizedQ16(
        numerator: UInt64,
        denominator: UInt64
    ) throws -> UInt32 {
        guard denominator > 0, numerator <= denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let product = numerator.multipliedFullWidth(
            by: UInt64(ASHNormalizedQ16V4.scale)
        )
        guard product.high < denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let division = denominator.dividingFullWidth(product)
        var value = division.quotient
        let complement = denominator - division.remainder
        if division.remainder > complement
            || (division.remainder == complement && value & 1 == 1) {
            value += 1
        }
        guard value <= UInt64(ASHNormalizedQ16V4.scale) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return UInt32(value)
    }

    private static func divideRoundedTiesToEven(
        _ numerator: UInt64,
        by denominator: UInt64
    ) throws -> UInt64 {
        guard denominator > 0 else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        var quotient = numerator / denominator
        let remainder = numerator % denominator
        let complement = denominator - remainder
        if remainder > complement
            || (remainder == complement && quotient & 1 == 1) {
            let increment = quotient.addingReportingOverflow(1)
            guard !increment.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            quotient = increment.partialValue
        }
        return quotient
    }

    private static func ceilingDivision(_ value: Int, _ divisor: Int) -> Int {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }
}

/// Canonical temporal tiling. The retained rectangle adds only the fixed
/// search halo to one active tile, so no operation needs a frame-sized Swift
/// sample array even for the largest admitted 8K raster.
struct ASHTemporalTilePolicyV4: Codable, Equatable, Hashable, Sendable {
    static let absoluteMaximumTileSampleCount = 262_144
    static let canonical = try! Self(
        policyID: "ash.p06.temporal.tiles.256x256-motion4-spatial1-v1",
        tileWidth: 256,
        tileHeight: 256,
        searchHalo: 5,
        maximumFrameWidth: 32_768,
        maximumFrameHeight: 32_768
    )

    let policyID: String
    let tileWidth: Int
    let tileHeight: Int
    let searchHalo: Int
    let maximumFrameWidth: Int
    let maximumFrameHeight: Int

    init(
        policyID: String,
        tileWidth: Int,
        tileHeight: Int,
        searchHalo: Int,
        maximumFrameWidth: Int,
        maximumFrameHeight: Int
    ) throws {
        let doubledHalo = searchHalo.multipliedReportingOverflow(by: 2)
        let retainedWidth = tileWidth.addingReportingOverflow(
            doubledHalo.partialValue
        )
        let retainedHeight = tileHeight.addingReportingOverflow(
            doubledHalo.partialValue
        )
        let retainedCount = retainedWidth.partialValue
            .multipliedReportingOverflow(by: retainedHeight.partialValue)
        guard ASHTemporalFrameV4.validIdentifier(policyID),
              (8...512).contains(tileWidth),
              (8...512).contains(tileHeight),
              (0...32).contains(searchHalo),
              maximumFrameWidth > 0,
              maximumFrameWidth <= 32_768,
              maximumFrameHeight > 0,
              maximumFrameHeight <= 32_768,
              !doubledHalo.overflow,
              !retainedWidth.overflow,
              !retainedHeight.overflow,
              !retainedCount.overflow,
              retainedCount.partialValue
                <= Self.absoluteMaximumTileSampleCount else {
            throw ASHTemporalV4Error.invalidTileGrid
        }
        self.policyID = policyID
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.searchHalo = searchHalo
        self.maximumFrameWidth = maximumFrameWidth
        self.maximumFrameHeight = maximumFrameHeight
    }

    var maximumRetainedTileSampleCount: Int {
        (tileWidth + searchHalo * 2) * (tileHeight + searchHalo * 2)
    }

    func validate() throws {
        _ = try Self(
            policyID: policyID,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            searchHalo: searchHalo,
            maximumFrameWidth: maximumFrameWidth,
            maximumFrameHeight: maximumFrameHeight
        )
    }
}

struct ASHTemporalTileRectV4: Codable, Equatable, Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maximumX: Int { x + width }
    var maximumY: Int { y + height }
    var sampleCount: Int { width * height }

    func contains(x coordinateX: Int, y coordinateY: Int) -> Bool {
        coordinateX >= x && coordinateX < maximumX
            && coordinateY >= y && coordinateY < maximumY
    }
}

struct ASHTemporalTileDescriptorV4: Codable, Equatable, Hashable, Sendable {
    let tileIndex: Int
    let column: Int
    let row: Int
    let active: ASHTemporalTileRectV4
    let retained: ASHTemporalTileRectV4
}

struct ASHTemporalTileGridV4: Codable, Equatable, Hashable, Sendable {
    let frameWidth: Int
    let frameHeight: Int
    let policy: ASHTemporalTilePolicyV4
    let columns: Int
    let rows: Int

    init(
        frameWidth: Int,
        frameHeight: Int,
        policy: ASHTemporalTilePolicyV4 = .canonical
    ) throws {
        try policy.validate()
        guard frameWidth > 0,
              frameHeight > 0,
              frameWidth <= policy.maximumFrameWidth,
              frameHeight <= policy.maximumFrameHeight else {
            throw ASHTemporalV4Error.invalidTileGrid
        }
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.policy = policy
        self.columns = Self.ceilingDivision(frameWidth, policy.tileWidth)
        self.rows = Self.ceilingDivision(frameHeight, policy.tileHeight)
        try validate()
    }

    var tileCount: Int { columns * rows }
    var fullFrameSampleCount: Int { frameWidth * frameHeight }

    func descriptor(at index: Int) throws -> ASHTemporalTileDescriptorV4 {
        guard index >= 0, index < tileCount else {
            throw ASHTemporalV4Error.invalidTileGrid
        }
        let column = index % columns
        let row = index / columns
        let x = column * policy.tileWidth
        let y = row * policy.tileHeight
        let active = ASHTemporalTileRectV4(
            x: x,
            y: y,
            width: min(policy.tileWidth, frameWidth - x),
            height: min(policy.tileHeight, frameHeight - y)
        )
        let retainedX = max(0, x - policy.searchHalo)
        let retainedY = max(0, y - policy.searchHalo)
        let retainedMaximumX = min(
            frameWidth,
            active.maximumX + policy.searchHalo
        )
        let retainedMaximumY = min(
            frameHeight,
            active.maximumY + policy.searchHalo
        )
        return ASHTemporalTileDescriptorV4(
            tileIndex: index,
            column: column,
            row: row,
            active: active,
            retained: ASHTemporalTileRectV4(
                x: retainedX,
                y: retainedY,
                width: retainedMaximumX - retainedX,
                height: retainedMaximumY - retainedY
            )
        )
    }

    func validate() throws {
        try policy.validate()
        guard frameWidth > 0,
              frameHeight > 0,
              frameWidth <= policy.maximumFrameWidth,
              frameHeight <= policy.maximumFrameHeight,
              columns == Self.ceilingDivision(frameWidth, policy.tileWidth),
              rows == Self.ceilingDivision(frameHeight, policy.tileHeight),
              columns > 0,
              rows > 0 else {
            throw ASHTemporalV4Error.invalidTileGrid
        }
        let count = columns.multipliedReportingOverflow(by: rows)
        guard !count.overflow else {
            throw ASHTemporalV4Error.invalidTileGrid
        }
        for index in 0..<count.partialValue {
            let descriptor = try descriptor(at: index)
            guard descriptor.active.sampleCount > 0,
                  descriptor.retained.sampleCount > 0,
                  descriptor.retained.sampleCount
                    <= policy.maximumRetainedTileSampleCount,
                  descriptor.retained.x <= descriptor.active.x,
                  descriptor.retained.y <= descriptor.active.y,
                  descriptor.retained.maximumX
                    >= descriptor.active.maximumX,
                  descriptor.retained.maximumY
                    >= descriptor.active.maximumY else {
                throw ASHTemporalV4Error.invalidTileGrid
            }
        }
    }

    private static func ceilingDivision(_ value: Int, _ divisor: Int) -> Int {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }
}

struct ASHTemporalTileHistoryStateV4: Codable, Equatable, Hashable,
    Sendable {
    let descriptor: ASHTemporalTileDescriptorV4
    let minimumCode: UInt16
    let maximumCode: UInt16
    /// Row-major samples for `descriptor.retained`, including only the fixed
    /// motion halo. Each tile owns a distinct bounded allocation.
    let retainedSamples: [UInt16]
    let ashStateRawValue: UInt16

    func sample(x: Int, y: Int) throws -> UInt16 {
        guard descriptor.retained.contains(x: x, y: y) else {
            throw ASHTemporalV4Error.invalidTileState
        }
        return retainedSamples[
            (y - descriptor.retained.y) * descriptor.retained.width
                + x - descriptor.retained.x
        ]
    }

    func activeSamples() throws -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(descriptor.active.sampleCount)
        for y in descriptor.active.y..<descriptor.active.maximumY {
            for x in descriptor.active.x..<descriptor.active.maximumX {
                result.append(try sample(x: x, y: y))
            }
        }
        return result
    }

    func validate(
        expected: ASHTemporalTileDescriptorV4,
        policy: ASHTemporalTilePolicyV4
    ) throws {
        let state = try? ASHState(rawValue: ashStateRawValue)
        guard descriptor == expected,
              minimumCode < maximumCode,
              retainedSamples.count == descriptor.retained.sampleCount,
              retainedSamples.count <= policy.maximumRetainedTileSampleCount,
              state?.hasValidIntegrity == true,
              retainedSamples.allSatisfy({
                  $0 >= minimumCode && $0 <= maximumCode
              }) else {
            throw ASHTemporalV4Error.invalidTileState
        }
    }
}

struct ASHTemporalTiledFrameV4: Codable, Equatable, Hashable, Sendable {
    let frameID: String
    let streamID: String
    let formatIdentity: ASHSHA256V4
    let ordinal: Int64
    let presentationTime: ExactRationalV4
    let cadenceID: String
    let grid: ASHTemporalTileGridV4
    let tiles: [ASHTemporalTileHistoryStateV4]

    func validate() throws {
        try grid.validate()
        guard ASHTemporalFrameV4.validIdentifier(frameID),
              ASHTemporalFrameV4.validIdentifier(streamID),
              ASHTemporalFrameV4.validIdentifier(cadenceID),
              ordinal >= 0,
              presentationTime >= .zero,
              tiles.count == grid.tileCount else {
            throw ASHTemporalV4Error.invalidTileState
        }
        for (index, tile) in tiles.enumerated() {
            try tile.validate(
                expected: grid.descriptor(at: index),
                policy: grid.policy
            )
        }
        guard let first = tiles.first,
              tiles.allSatisfy({
                  $0.minimumCode == first.minimumCode
                      && $0.maximumCode == first.maximumCode
              }) else {
            throw ASHTemporalV4Error.invalidTileState
        }
    }
}

struct ASHTemporalTileAllocationDiagnosticsV4: Codable, Equatable, Hashable,
    Sendable {
    let fullFrameSampleCount: Int
    let tileCount: Int
    let maximumTemporarySampleCount: Int
    let maximumRetainedTileSampleCount: Int
    let retainedSampleCount: Int
    let fullFrameSampleArrayAllocationCount: Int
    let largestContiguousSampleAllocation: Int
}

struct ASHTemporalTiledFrameCaptureResultV4: Equatable, Sendable {
    let frame: ASHTemporalTiledFrameV4
    let allocationDiagnostics: ASHTemporalTileAllocationDiagnosticsV4
}

enum ASHTemporalTiledFrameBuilderV4 {
    static func capture(
        frameID: String,
        streamID: String,
        formatIdentity: ASHSHA256V4,
        ordinal: Int64,
        presentationTime: ExactRationalV4,
        cadenceID: String,
        frameWidth: Int,
        frameHeight: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        policy: ASHTemporalTilePolicyV4 = .canonical,
        stateForTile: (Int) throws -> ASHState,
        sampleAt: (Int, Int) throws -> UInt16
    ) throws -> ASHTemporalTiledFrameCaptureResultV4 {
        let grid = try ASHTemporalTileGridV4(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            policy: policy
        )
        guard minimumCode < maximumCode else {
            throw ASHTemporalV4Error.invalidCodeRange(
                minimum: minimumCode,
                maximum: maximumCode
            )
        }
        var tiles: [ASHTemporalTileHistoryStateV4] = []
        tiles.reserveCapacity(grid.tileCount)
        var largest = 0
        var retainedTotal = 0
        for index in 0..<grid.tileCount {
            try Task.checkCancellation()
            let descriptor = try grid.descriptor(at: index)
            let count = descriptor.retained.sampleCount
            guard count <= policy.maximumRetainedTileSampleCount else {
                throw ASHTemporalV4Error.tileAllocationLimitExceeded(
                    sampleCount: count,
                    limit: policy.maximumRetainedTileSampleCount
                )
            }
            var retained: [UInt16] = []
            retained.reserveCapacity(count)
            for y in descriptor.retained.y..<descriptor.retained.maximumY {
                for x in descriptor.retained.x..<descriptor.retained.maximumX {
                    let sample = try sampleAt(x, y)
                    guard sample >= minimumCode, sample <= maximumCode else {
                        throw ASHTemporalV4Error.sampleOutOfRange(
                            index: retained.count,
                            value: sample
                        )
                    }
                    retained.append(sample)
                }
            }
            let state = try stateForTile(index)
            guard state.hasValidIntegrity else {
                throw ASHTemporalV4Error.invalidASHState(state.rawValue)
            }
            tiles.append(ASHTemporalTileHistoryStateV4(
                descriptor: descriptor,
                minimumCode: minimumCode,
                maximumCode: maximumCode,
                retainedSamples: retained,
                ashStateRawValue: state.rawValue
            ))
            largest = max(largest, retained.count)
            let sum = retainedTotal.addingReportingOverflow(retained.count)
            guard !sum.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            retainedTotal = sum.partialValue
        }
        let frame = ASHTemporalTiledFrameV4(
            frameID: frameID,
            streamID: streamID,
            formatIdentity: formatIdentity,
            ordinal: ordinal,
            presentationTime: presentationTime,
            cadenceID: cadenceID,
            grid: grid,
            tiles: tiles
        )
        try frame.validate()
        return ASHTemporalTiledFrameCaptureResultV4(
            frame: frame,
            allocationDiagnostics: ASHTemporalTileAllocationDiagnosticsV4(
                fullFrameSampleCount: grid.fullFrameSampleCount,
                tileCount: grid.tileCount,
                maximumTemporarySampleCount: largest,
                maximumRetainedTileSampleCount:
                    policy.maximumRetainedTileSampleCount,
                retainedSampleCount: retainedTotal,
                fullFrameSampleArrayAllocationCount: 0,
                largestContiguousSampleAllocation: largest
            )
        )
    }
}

struct ASHTemporalTileMotionStateV4: Codable, Equatable, Hashable,
    Sendable {
    let tileIndex: Int
    let sceneCut: Bool
    let temporalEvidenceQ16: UInt32
    let blockColumns: Int
    let blockRows: Int
    let vectors: [ASHTemporalMotionVectorV4]

    func validate(
        expected descriptor: ASHTemporalTileDescriptorV4,
        grid: ASHTemporalTileGridV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4
    ) throws {
        guard tileIndex == descriptor.tileIndex,
              temporalEvidenceQ16 <= ASHNormalizedQ16V4.scale,
              blockColumns > 0,
              blockRows > 0,
              blockColumns == Self.ceilingDivision(
                  descriptor.active.width,
                  configuration.blockWidth
              ),
              blockRows == Self.ceilingDivision(
                  descriptor.active.height,
                  configuration.blockHeight
              ) else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        if sceneCut {
            guard vectors.isEmpty else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            return
        }
        let count = blockColumns.multipliedReportingOverflow(by: blockRows)
        guard !count.overflow, count.partialValue == vectors.count else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        for (index, vector) in vectors.enumerated() {
            let column = index % blockColumns
            let row = index / blockColumns
            let expectedX = descriptor.active.x
                + column * configuration.blockWidth
            let expectedY = descriptor.active.y
                + row * configuration.blockHeight
            let expectedWidth = min(
                configuration.blockWidth,
                descriptor.active.maximumX - expectedX
            )
            let expectedHeight = min(
                configuration.blockHeight,
                descriptor.active.maximumY - expectedY
            )
            let sourceX = expectedX.addingReportingOverflow(Int(vector.dx))
            let sourceY = expectedY.addingReportingOverflow(Int(vector.dy))
            guard vector.blockIndex == index,
                  vector.originX == expectedX,
                  vector.originY == expectedY,
                  vector.width == expectedWidth,
                  vector.height == expectedHeight,
                  vector.normalizedCostQ16 <= ASHNormalizedQ16V4.scale,
                  vector.confidenceQ16 <= ASHNormalizedQ16V4.scale,
                  abs(Int(vector.dx)) <= configuration.searchRadius,
                  abs(Int(vector.dy)) <= configuration.searchRadius,
                  !sourceX.overflow,
                  !sourceY.overflow,
                  sourceX.partialValue >= 0,
                  sourceY.partialValue >= 0,
                  sourceX.partialValue + expectedWidth <= grid.frameWidth,
                  sourceY.partialValue + expectedHeight <= grid.frameHeight,
                  descriptor.retained.contains(
                    x: sourceX.partialValue,
                    y: sourceY.partialValue
                  ),
                  descriptor.retained.contains(
                    x: sourceX.partialValue + expectedWidth - 1,
                    y: sourceY.partialValue + expectedHeight - 1
                  ) else {
                throw ASHTemporalV4Error.invalidMotionField
            }
        }
    }

    private static func ceilingDivision(_ value: Int, _ divisor: Int) -> Int {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }
}

struct ASHTemporalTiledMotionFieldV4: Codable, Equatable, Hashable,
    Sendable {
    let policyID: String
    let currentFrameID: String
    let previousFrameID: String
    let streamID: String
    let formatIdentity: ASHSHA256V4
    let sceneDifferenceQ16: UInt32
    let sceneCut: Bool
    let temporalEvidenceQ16: UInt32
    let tileStates: [ASHTemporalTileMotionStateV4]

    func validate(
        current: ASHTemporalTiledFrameV4,
        previous: ASHTemporalTiledFrameV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4
    ) throws {
        guard policyID == configuration.policyID,
              currentFrameID == current.frameID,
              previousFrameID == previous.frameID,
              streamID == current.streamID,
              streamID == previous.streamID,
              formatIdentity == current.formatIdentity,
              formatIdentity == previous.formatIdentity,
              current.grid == previous.grid,
              sceneDifferenceQ16 <= ASHNormalizedQ16V4.scale,
              temporalEvidenceQ16 <= ASHNormalizedQ16V4.scale,
              tileStates.count == current.grid.tileCount else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        for (index, state) in tileStates.enumerated() {
            guard state.sceneCut == sceneCut else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            try state.validate(
                expected: current.grid.descriptor(at: index),
                grid: current.grid,
                configuration: configuration
            )
        }
    }
}

struct ASHTemporalTiledMotionAllocationDiagnosticsV4: Codable, Equatable,
    Hashable, Sendable {
    let maximumRetainedCandidatesPerBlock: Int
    let maximumMotionVectorCountPerTile: Int
    let totalMotionVectorCount: Int
    let largestContiguousMotionVectorAllocation: Int
    let fullFrameMotionVectorArrayAllocationCount: Int
    let materializedAlignedSampleCount: Int
}

struct ASHTemporalTiledMotionResultV4: Equatable, Sendable {
    let field: ASHTemporalTiledMotionFieldV4
    let allocationDiagnostics: ASHTemporalTiledMotionAllocationDiagnosticsV4
}

enum ASHTemporalTiledMotionAnalyzerV4 {
    private struct TileBatchResult: Sendable {
        let state: ASHTemporalTileMotionStateV4
        let weightedEvidence: UInt64
        let sampleCount: UInt64
    }

    private struct Candidate: Comparable {
        let absoluteDifference: UInt64
        let dx: Int
        let dy: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.absoluteDifference != rhs.absoluteDifference {
                return lhs.absoluteDifference < rhs.absoluteDifference
            }
            let leftDistance = abs(lhs.dx) + abs(lhs.dy)
            let rightDistance = abs(rhs.dx) + abs(rhs.dy)
            if leftDistance != rightDistance {
                return leftDistance < rightDistance
            }
            if lhs.dy != rhs.dy { return lhs.dy < rhs.dy }
            return lhs.dx < rhs.dx
        }
    }

    static func analyze(
        current: ASHTemporalTiledFrameV4,
        previous: ASHTemporalTiledFrameV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4 = .canonical,
        executionPolicy: ASHTemporalMotionExecutionPolicyV4 = .automatic
    ) throws -> ASHTemporalTiledMotionResultV4 {
        try Task.checkCancellation()
        try current.validate()
        try previous.validate()
        guard previous.ordinal < current.ordinal,
              previous.presentationTime < current.presentationTime else {
            throw ASHTemporalV4Error.futureOrConcurrentHistory
        }
        guard previous.frameID != current.frameID else {
            throw ASHTemporalV4Error.nonIncreasingFrameIdentity
        }
        guard previous.streamID == current.streamID else {
            throw ASHTemporalV4Error.streamIdentityMismatch
        }
        guard previous.formatIdentity == current.formatIdentity else {
            throw ASHTemporalV4Error.formatIdentityMismatch
        }
        guard previous.grid == current.grid,
              previous.cadenceID == current.cadenceID,
              configuration.searchRadius <= current.grid.policy.searchHalo,
              zip(current.tiles, previous.tiles).allSatisfy({
                  $0.minimumCode == $1.minimumCode
                      && $0.maximumCode == $1.maximumCode
              }) else {
            throw ASHTemporalV4Error.planeGeometryMismatch
        }
        var blockCount = 0
        for tileIndex in 0..<current.grid.tileCount {
            let active = try current.grid.descriptor(at: tileIndex).active
            blockCount += ceilingDivision(active.width, configuration.blockWidth)
                * ceilingDivision(active.height, configuration.blockHeight)
        }
        let workerCount = try executionPolicy.workerCount(
            rows: current.grid.tileCount,
            blockCount: blockCount
        )
        let sceneDifference = try histogramDifferenceQ16(
            current: current,
            previous: previous
        )
        let sceneCut = sceneDifference
            >= configuration.sceneCutHistogramThresholdQ16
        if sceneCut {
            let states = try (0..<current.grid.tileCount).map { index in
                let descriptor = try current.grid.descriptor(at: index)
                return ASHTemporalTileMotionStateV4(
                    tileIndex: index,
                    sceneCut: true,
                    temporalEvidenceQ16: sceneDifference,
                    blockColumns: ceilingDivision(
                        descriptor.active.width,
                        configuration.blockWidth
                    ),
                    blockRows: ceilingDivision(
                        descriptor.active.height,
                        configuration.blockHeight
                    ),
                    vectors: []
                )
            }
            let field = ASHTemporalTiledMotionFieldV4(
                policyID: configuration.policyID,
                currentFrameID: current.frameID,
                previousFrameID: previous.frameID,
                streamID: current.streamID,
                formatIdentity: current.formatIdentity,
                sceneDifferenceQ16: sceneDifference,
                sceneCut: true,
                temporalEvidenceQ16: sceneDifference,
                tileStates: states
            )
            try field.validate(
                current: current,
                previous: previous,
                configuration: configuration
            )
            return ASHTemporalTiledMotionResultV4(
                field: field,
                allocationDiagnostics:
                    ASHTemporalTiledMotionAllocationDiagnosticsV4(
                        maximumRetainedCandidatesPerBlock: 2,
                        maximumMotionVectorCountPerTile: 0,
                        totalMotionVectorCount: 0,
                        largestContiguousMotionVectorAllocation: 0,
                        fullFrameMotionVectorArrayAllocationCount: 0,
                        materializedAlignedSampleCount: 0
                    )
            )
        }

        var states: [ASHTemporalTileMotionStateV4] = []
        states.reserveCapacity(current.grid.tileCount)
        var totalVectorCount = 0
        var largestVectorCount = 0
        var globalWeightedEvidence: UInt64 = 0
        var globalSampleCount: UInt64 = 0
        // Each worker owns one tile's bounded block array. Waves cap the
        // pending results and give cancellation back to the initiating task.
        for batchStart in stride(
            from: 0, to: current.grid.tileCount, by: workerCount
        ) {
            try Task.checkCancellation()
            let count = min(workerCount, current.grid.tileCount - batchStart)
            let results = ASHTemporalMotionBatchResultsV4<TileBatchResult>(
                count: count
            )
            if workerCount == 1 {
                results.store(Result {
                    try matchTile(
                        at: batchStart,
                        current: current,
                        previous: previous,
                        configuration: configuration,
                        checkCancellation: true
                    )
                }, at: 0)
            } else {
                ASHTemporalMotionBatchExecutorV4.perform(iterations: count) { index in
                    results.store(Result {
                        try matchTile(
                            at: batchStart + index,
                            current: current,
                            previous: previous,
                            configuration: configuration,
                            checkCancellation: false
                        )
                    }, at: index)
                }
            }
            try Task.checkCancellation()
            for index in 0..<count {
                let result = try results.take(at: index)
                states.append(result.state)
                let nextTotal = totalVectorCount
                    .addingReportingOverflow(result.state.vectors.count)
                let globalEvidence = globalWeightedEvidence
                    .addingReportingOverflow(result.weightedEvidence)
                let globalCount = globalSampleCount
                    .addingReportingOverflow(result.sampleCount)
                guard !nextTotal.overflow,
                      !globalEvidence.overflow,
                      !globalCount.overflow else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                totalVectorCount = nextTotal.partialValue
                largestVectorCount = max(
                    largestVectorCount, result.state.vectors.count
                )
                globalWeightedEvidence = globalEvidence.partialValue
                globalSampleCount = globalCount.partialValue
            }
        }
        let globalEvidence = try divideRoundedTiesToEven(
            globalWeightedEvidence,
            by: globalSampleCount
        )
        guard let globalEvidenceQ16 = UInt32(exactly: globalEvidence),
              globalEvidenceQ16 <= ASHNormalizedQ16V4.scale else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let field = ASHTemporalTiledMotionFieldV4(
            policyID: configuration.policyID,
            currentFrameID: current.frameID,
            previousFrameID: previous.frameID,
            streamID: current.streamID,
            formatIdentity: current.formatIdentity,
            sceneDifferenceQ16: sceneDifference,
            sceneCut: false,
            temporalEvidenceQ16: globalEvidenceQ16,
            tileStates: states
        )
        try field.validate(
            current: current,
            previous: previous,
            configuration: configuration
        )
        return ASHTemporalTiledMotionResultV4(
            field: field,
            allocationDiagnostics:
                ASHTemporalTiledMotionAllocationDiagnosticsV4(
                    maximumRetainedCandidatesPerBlock: 2,
                    maximumMotionVectorCountPerTile: largestVectorCount,
                    totalMotionVectorCount: totalVectorCount,
                    largestContiguousMotionVectorAllocation:
                        largestVectorCount,
                    fullFrameMotionVectorArrayAllocationCount: 0,
                    materializedAlignedSampleCount: 0
                )
        )
    }

    private static func matchTile(
        at tileIndex: Int,
        current: ASHTemporalTiledFrameV4,
        previous: ASHTemporalTiledFrameV4,
        configuration: ASHTemporalBlockMatchingConfigurationV4,
        checkCancellation: Bool
    ) throws -> TileBatchResult {
        let descriptor = try current.grid.descriptor(at: tileIndex)
        let currentTile = current.tiles[tileIndex]
        let previousTile = previous.tiles[tileIndex]
        let columns = ceilingDivision(
            descriptor.active.width,
            configuration.blockWidth
        )
        let rows = ceilingDivision(
            descriptor.active.height,
            configuration.blockHeight
        )
        var vectors: [ASHTemporalMotionVectorV4] = []
        vectors.reserveCapacity(columns * rows)
        var tileWeightedEvidence: UInt64 = 0
        var tileSampleCount: UInt64 = 0
        let signalRange = UInt64(
            currentTile.maximumCode - currentTile.minimumCode
        )
        for blockRow in 0..<rows {
            if checkCancellation { try Task.checkCancellation() }
            for blockColumn in 0..<columns {
                let originX = descriptor.active.x
                    + blockColumn * configuration.blockWidth
                let originY = descriptor.active.y
                    + blockRow * configuration.blockHeight
                let width = min(
                    configuration.blockWidth,
                    descriptor.active.maximumX - originX
                )
                let height = min(
                    configuration.blockHeight,
                    descriptor.active.maximumY - originY
                )
                let candidates = try bestTwoCandidates(
                    current: currentTile,
                    previous: previousTile,
                    grid: current.grid,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    radius: configuration.searchRadius
                )
                let blockSampleCount = UInt64(width * height)
                let denominator = blockSampleCount
                    .multipliedReportingOverflow(by: signalRange)
                guard !denominator.overflow else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                let costQ16 = try normalizedQ16(
                    numerator: candidates.best.absoluteDifference,
                    denominator: denominator.partialValue
                )
                let confidenceQ16: UInt32
                if candidates.second.absoluteDifference
                    > candidates.best.absoluteDifference {
                    confidenceQ16 = try normalizedQ16(
                        numerator: candidates.second.absoluteDifference
                            - candidates.best.absoluteDifference,
                        denominator: max(
                            candidates.second.absoluteDifference,
                            1
                        )
                    )
                } else {
                    confidenceQ16 = 0
                }
                let occluded = costQ16
                    > configuration.occlusionCostThresholdQ16
                    || confidenceQ16
                        < configuration.minimumConfidenceQ16
                vectors.append(ASHTemporalMotionVectorV4(
                    blockIndex: vectors.count,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    dx: Int16(candidates.best.dx),
                    dy: Int16(candidates.best.dy),
                    absoluteDifference:
                        candidates.best.absoluteDifference,
                    normalizedCostQ16: costQ16,
                    confidenceQ16: confidenceQ16,
                    occluded: occluded
                ))
                let weighted = UInt64(costQ16)
                    .multipliedReportingOverflow(by: blockSampleCount)
                let tileSum = tileWeightedEvidence
                    .addingReportingOverflow(weighted.partialValue)
                let tileCount = tileSampleCount
                    .addingReportingOverflow(blockSampleCount)
                guard !weighted.overflow,
                      !tileSum.overflow,
                      !tileCount.overflow else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                tileWeightedEvidence = tileSum.partialValue
                tileSampleCount = tileCount.partialValue
            }
        }
        let tileEvidence = try divideRoundedTiesToEven(
            tileWeightedEvidence,
            by: tileSampleCount
        )
        guard let tileEvidenceQ16 = UInt32(exactly: tileEvidence),
              tileEvidenceQ16 <= ASHNormalizedQ16V4.scale else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return TileBatchResult(
            state: ASHTemporalTileMotionStateV4(
                tileIndex: tileIndex,
                sceneCut: false,
                temporalEvidenceQ16: tileEvidenceQ16,
                blockColumns: columns,
                blockRows: rows,
                vectors: vectors
            ),
            weightedEvidence: tileWeightedEvidence,
            sampleCount: tileSampleCount
        )
    }

    private static func histogramDifferenceQ16(
        current: ASHTemporalTiledFrameV4,
        previous: ASHTemporalTiledFrameV4
    ) throws -> UInt32 {
        let binCount = 16
        guard let first = current.tiles.first else {
            throw ASHTemporalV4Error.invalidTileState
        }
        let range = UInt64(first.maximumCode - first.minimumCode) + 1
        var currentBins = Array(repeating: UInt64(0), count: binCount)
        var previousBins = Array(repeating: UInt64(0), count: binCount)
        for tileIndex in current.tiles.indices {
            let currentTile = current.tiles[tileIndex]
            let previousTile = previous.tiles[tileIndex]
            let active = currentTile.descriptor.active
            for y in active.y..<active.maximumY {
                for x in active.x..<active.maximumX {
                    let currentOffset = UInt64(
                        try currentTile.sample(x: x, y: y)
                            - currentTile.minimumCode
                    )
                    let previousOffset = UInt64(
                        try previousTile.sample(x: x, y: y)
                            - previousTile.minimumCode
                    )
                    currentBins[min(
                        Int(currentOffset * UInt64(binCount) / range),
                        binCount - 1
                    )] += 1
                    previousBins[min(
                        Int(previousOffset * UInt64(binCount) / range),
                        binCount - 1
                    )] += 1
                }
            }
        }
        let difference = zip(currentBins, previousBins).reduce(UInt64(0)) {
            $0 + ($1.0 > $1.1 ? $1.0 - $1.1 : $1.1 - $1.0)
        }
        return try normalizedQ16(
            numerator: difference,
            denominator: UInt64(current.grid.fullFrameSampleCount) * 2
        )
    }

    private static func bestTwoCandidates(
        current: ASHTemporalTileHistoryStateV4,
        previous: ASHTemporalTileHistoryStateV4,
        grid: ASHTemporalTileGridV4,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        radius: Int
    ) throws -> (best: Candidate, second: Candidate) {
        let minimumDX = max(-radius, -originX)
        let maximumDX = min(radius, grid.frameWidth - originX - width)
        let minimumDY = max(-radius, -originY)
        let maximumDY = min(radius, grid.frameHeight - originY - height)
        guard minimumDX <= maximumDX, minimumDY <= maximumDY else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        var best: Candidate?
        var second: Candidate?
        for dy in minimumDY...maximumDY {
            for dx in minimumDX...maximumDX {
                var difference: UInt64 = 0
                for localY in 0..<height {
                    for localX in 0..<width {
                        let currentValue = try current.sample(
                            x: originX + localX,
                            y: originY + localY
                        )
                        let previousValue = try previous.sample(
                            x: originX + localX + dx,
                            y: originY + localY + dy
                        )
                        let delta = currentValue > previousValue
                            ? UInt64(currentValue - previousValue)
                            : UInt64(previousValue - currentValue)
                        let sum = difference.addingReportingOverflow(delta)
                        guard !sum.overflow else {
                            throw ASHTemporalV4Error.arithmeticOverflow
                        }
                        difference = sum.partialValue
                    }
                }
                let candidate = Candidate(
                    absoluteDifference: difference,
                    dx: dx,
                    dy: dy
                )
                if best == nil || candidate < best! {
                    second = best
                    best = candidate
                } else if second == nil || candidate < second! {
                    second = candidate
                }
            }
        }
        guard let best else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        return (best, second ?? best)
    }

    private static func normalizedQ16(
        numerator: UInt64,
        denominator: UInt64
    ) throws -> UInt32 {
        guard denominator > 0, numerator <= denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let product = numerator.multipliedFullWidth(
            by: UInt64(ASHNormalizedQ16V4.scale)
        )
        guard product.high < denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let division = denominator.dividingFullWidth(product)
        var value = division.quotient
        let complement = denominator - division.remainder
        if division.remainder > complement
            || (division.remainder == complement && value & 1 == 1) {
            value += 1
        }
        guard value <= UInt64(ASHNormalizedQ16V4.scale) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return UInt32(value)
    }

    private static func divideRoundedTiesToEven(
        _ numerator: UInt64,
        by denominator: UInt64
    ) throws -> UInt64 {
        guard denominator > 0 else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        var quotient = numerator / denominator
        let remainder = numerator % denominator
        let complement = denominator - remainder
        if remainder > complement
            || (remainder == complement && quotient & 1 == 1) {
            let increment = quotient.addingReportingOverflow(1)
            guard !increment.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            quotient = increment.partialValue
        }
        return quotient
    }

    private static func ceilingDivision(_ value: Int, _ divisor: Int) -> Int {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }
}

enum ASHTemporalTileExecutionScheduleV4: String, Codable, CaseIterable,
    Hashable, Sendable {
    case raster
    case reverseRaster = "reverse_raster"
    case evenThenOdd = "even_then_odd"

    func orderedTileIndices(count: Int) -> [Int] {
        switch self {
        case .raster:
            Array(0..<count)
        case .reverseRaster:
            Array((0..<count).reversed())
        case .evenThenOdd:
            Array(stride(from: 0, to: count, by: 2))
                + Array(stride(from: 1, to: count, by: 2))
        }
    }
}

struct ASHTemporalTileOutputV4: Codable, Equatable, Hashable, Sendable {
    let tileIndex: Int
    let active: ASHTemporalTileRectV4
    let samples: [UInt16]
    let stateRawValue: UInt16
    let targetMessageRawValue: UInt8
    let historyWeightQ16: UInt32
}

struct ASHTemporalTiledReconstructionDiagnosticsV4: Codable, Equatable,
    Hashable, Sendable {
    let executor: ASHExecutorV4
    let schedule: ASHTemporalTileExecutionScheduleV4
    let maximumOutputTileSampleCount: Int
    let largestContiguousSampleAllocation: Int
    let fullFrameSampleArrayAllocationCount: Int
    let materializedAlignedSampleCount: Int
}

struct ASHTemporalTiledReconstructionResultV4: Equatable, Sendable {
    let tiles: [ASHTemporalTileOutputV4]
    let diagnostics: ASHTemporalTiledReconstructionDiagnosticsV4
}

enum ASHTemporalTiledReconstructorV4 {
    static func reconstruct(
        currentSpatial: ASHTemporalTiledFrameV4,
        previousHistory: ASHTemporalTiledFrameV4?,
        motionField: ASHTemporalTiledMotionFieldV4?,
        resetReason: ASHTemporalResetReasonV4?,
        program: ASHDepthFourBranchProgramV4,
        executor: ASHExecutorV4,
        schedule: ASHTemporalTileExecutionScheduleV4 = .raster,
        configuration: ASHTemporalBlockMatchingConfigurationV4 = .canonical
    ) throws -> ASHTemporalTiledReconstructionResultV4 {
        try currentSpatial.validate()
        if resetReason == nil, motionField != nil || previousHistory != nil {
            guard let previousHistory, let motionField else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            try motionField.validate(
                current: currentSpatial,
                previous: previousHistory,
                configuration: configuration
            )
        }
        let ordered = schedule.orderedTileIndices(
            count: currentSpatial.grid.tileCount
        )
        guard ordered.count == currentSpatial.grid.tileCount,
              Set(ordered).count == ordered.count else {
            throw ASHTemporalV4Error.invalidTileGrid
        }
        var outputs = Array<ASHTemporalTileOutputV4?>(
            repeating: nil,
            count: currentSpatial.grid.tileCount
        )
        var largest = 0
        for tileIndex in ordered {
            try Task.checkCancellation()
            let current = currentSpatial.tiles[tileIndex]
            let state = try ASHState(rawValue: current.ashStateRawValue)
            guard state.hasValidIntegrity else {
                throw ASHTemporalV4Error.invalidASHState(state.rawValue)
            }
            let conditioned = try program.conditionedWeights(for: state)
            var samples = try current.activeSamples()
            let spatialOnly = resetReason != nil
                || motionField == nil
                || motionField?.sceneCut == true
                || previousHistory == nil
            var weightedHistorySum: UInt64 = 0
            if !spatialOnly,
               let previous = previousHistory?.tiles[tileIndex],
               let motion = motionField?.tileStates[tileIndex] {
                let stateWeightQ16 = try regularizationExpectationQ16(
                    conditioned: conditioned,
                    program: program
                )
                let scale = UInt64(ASHNormalizedQ16V4.scale)
                let stateBoostQ16 = try roundedShift(
                    UInt64(stateWeightQ16),
                    fractionalBits: 1
                )
                let confidenceGainQ16 = scale + stateBoostQ16
                for vector in motion.vectors where !vector.occluded {
                    let unboundedWeight = try roundedShift(
                        UInt64(vector.confidenceQ16) * confidenceGainQ16,
                        fractionalBits: 16
                    )
                    let historyWeight = min(
                        UInt64(
                            ASHTemporalReconstructorV4
                                .maximumHistoryWeightQ16
                        ),
                        unboundedWeight
                    )
                    guard historyWeight > 0 else { continue }
                    let currentWeight = scale - historyWeight
                    for y in vector.originY..<(vector.originY + vector.height) {
                        for x in vector.originX..<(vector.originX + vector.width) {
                            let localX = x - current.descriptor.active.x
                            let localY = y - current.descriptor.active.y
                            let sampleIndex = localY
                                * current.descriptor.active.width + localX
                            let historical = try previous.sample(
                                x: x + Int(vector.dx),
                                y: y + Int(vector.dy)
                            )
                            let sum = UInt64(samples[sampleIndex])
                                * currentWeight
                                + UInt64(historical) * historyWeight
                            samples[sampleIndex] = UInt16(
                                roundedShift16Unchecked(sum)
                            )
                        }
                    }
                    let blockCount = UInt64(vector.width * vector.height)
                    let weighted = historyWeight
                        .multipliedReportingOverflow(by: blockCount)
                    let accumulated = weightedHistorySum
                        .addingReportingOverflow(weighted.partialValue)
                    guard !weighted.overflow, !accumulated.overflow else {
                        throw ASHTemporalV4Error.arithmeticOverflow
                    }
                    weightedHistorySum = accumulated.partialValue
                }
            }
            let averageWeight: UInt32
            if weightedHistorySum == 0 {
                averageWeight = 0
            } else {
                let divided = try divideRoundedTiesToEven(
                    weightedHistorySum,
                    by: UInt64(samples.count)
                )
                guard let value = UInt32(exactly: divided),
                      value <= ASHTemporalReconstructorV4
                        .maximumHistoryWeightQ16 else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                averageWeight = value
            }
            outputs[tileIndex] = ASHTemporalTileOutputV4(
                tileIndex: tileIndex,
                active: current.descriptor.active,
                samples: samples,
                stateRawValue: state.rawValue,
                targetMessageRawValue: conditioned.targetMessageRawValue,
                historyWeightQ16: averageWeight
            )
            largest = max(largest, samples.count)
        }
        let canonical = try outputs.map { output in
            guard let output else {
                throw ASHTemporalV4Error.invalidTileState
            }
            return output
        }
        return ASHTemporalTiledReconstructionResultV4(
            tiles: canonical,
            diagnostics: ASHTemporalTiledReconstructionDiagnosticsV4(
                executor: executor,
                schedule: schedule,
                maximumOutputTileSampleCount:
                    currentSpatial.grid.policy.tileWidth
                        * currentSpatial.grid.policy.tileHeight,
                largestContiguousSampleAllocation: largest,
                fullFrameSampleArrayAllocationCount: 0,
                materializedAlignedSampleCount: 0
            )
        )
    }

    private static func regularizationExpectationQ16(
        conditioned: ASHStateConditionedMessageWeightsV4,
        program: ASHDepthFourBranchProgramV4
    ) throws -> UInt32 {
        guard let historyBasisIndex = program.operatorManifest.basisIDs
            .firstIndex(of: "regularization") else {
            throw ASHTemporalV4Error.invalidConfiguration
        }
        let stateNumerator = conditioned.weightsByMessage.reduce(UInt64(0)) {
            partial, weight in
            let coefficient = weight.operatorCoefficients[historyBasisIndex]
            guard coefficient > 0 else { return partial }
            return partial + weight.numerator * UInt64(coefficient)
        }
        return try normalizedQ16(
            numerator: stateNumerator,
            denominator: conditioned.denominator
        )
    }

    private static func normalizedQ16(
        numerator: UInt64,
        denominator: UInt64
    ) throws -> UInt32 {
        guard denominator > 0, numerator <= denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let product = numerator.multipliedFullWidth(
            by: UInt64(ASHNormalizedQ16V4.scale)
        )
        guard product.high < denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let division = denominator.dividingFullWidth(product)
        var quotient = division.quotient
        let complement = denominator - division.remainder
        if division.remainder > complement
            || (division.remainder == complement && quotient & 1 == 1) {
            quotient += 1
        }
        guard quotient <= UInt64(ASHNormalizedQ16V4.scale) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return UInt32(quotient)
    }

    private static func divideRoundedTiesToEven(
        _ numerator: UInt64,
        by denominator: UInt64
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

    private static func roundedShift(
        _ value: UInt64,
        fractionalBits: Int
    ) throws -> UInt64 {
        guard (1...63).contains(fractionalBits) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let denominator = UInt64(1) << fractionalBits
        var quotient = value >> fractionalBits
        let remainder = value & (denominator - 1)
        let half = denominator >> 1
        if remainder > half || (remainder == half && quotient & 1 == 1) {
            quotient += 1
        }
        return quotient
    }

    private static func roundedShift16Unchecked(_ value: UInt64) -> UInt64 {
        var quotient = value >> 16
        let remainder = value & 0xffff
        if remainder > 0x8000
            || (remainder == 0x8000 && quotient & 1 == 1) {
            quotient += 1
        }
        return quotient
    }
}

struct ASHTemporalTiledHistoryEntryV4: Codable, Equatable, Hashable,
    Sendable {
    let frame: ASHTemporalTiledFrameV4
    let motionFromPrevious: ASHTemporalTiledMotionFieldV4?
}

struct ASHTemporalTiledHistoryV4: Codable, Equatable, Hashable, Sendable {
    static let maximumCapacity = 2

    private(set) var generation: UInt64
    let capacity: Int
    private(set) var entries: [ASHTemporalTiledHistoryEntryV4]
    private(set) var lastResetReason: ASHTemporalResetReasonV4?

    init(
        generation: UInt64 = 0,
        capacity: Int = 2,
        entries: [ASHTemporalTiledHistoryEntryV4] = [],
        lastResetReason: ASHTemporalResetReasonV4? = nil
    ) throws {
        guard (1...Self.maximumCapacity).contains(capacity) else {
            throw ASHTemporalV4Error.invalidHistory
        }
        self.generation = generation
        self.capacity = capacity
        self.entries = entries
        self.lastResetReason = lastResetReason
        try validate()
    }

    mutating func append(
        _ frame: ASHTemporalTiledFrameV4,
        motionFromPrevious: ASHTemporalTiledMotionFieldV4?
    ) throws {
        try validate()
        try frame.validate()
        if let previous = entries.last?.frame {
            guard previous.ordinal < frame.ordinal,
                  previous.presentationTime < frame.presentationTime,
                  previous.frameID != frame.frameID,
                  previous.streamID == frame.streamID,
                  previous.formatIdentity == frame.formatIdentity,
                  previous.cadenceID == frame.cadenceID,
                  previous.grid == frame.grid,
                  let motionFromPrevious else {
                throw ASHTemporalV4Error.invalidHistory
            }
            try motionFromPrevious.validate(
                current: frame,
                previous: previous,
                configuration: .canonical
            )
        } else if motionFromPrevious != nil {
            throw ASHTemporalV4Error.invalidHistory
        }
        entries.append(ASHTemporalTiledHistoryEntryV4(
            frame: frame,
            motionFromPrevious: motionFromPrevious
        ))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
            // The new first entry's motion references the evicted frame. It
            // remains useful diagnostic state but cannot be revalidated
            // against an absent value, so clear it canonically.
            entries[0] = ASHTemporalTiledHistoryEntryV4(
                frame: entries[0].frame,
                motionFromPrevious: nil
            )
        }
        lastResetReason = nil
        try validate()
    }

    mutating func reset(reason: ASHTemporalResetReasonV4) throws {
        let next = generation.addingReportingOverflow(1)
        guard !next.overflow else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        generation = next.partialValue
        entries.removeAll(keepingCapacity: true)
        lastResetReason = reason
    }

    func validate() throws {
        guard (1...Self.maximumCapacity).contains(capacity),
              entries.count <= capacity,
              entries.isEmpty || lastResetReason == nil,
              entries.first?.motionFromPrevious == nil else {
            throw ASHTemporalV4Error.invalidHistory
        }
        for entry in entries {
            try entry.frame.validate()
        }
        for index in entries.indices.dropFirst() {
            let previous = entries[index - 1].frame
            let current = entries[index].frame
            guard previous.ordinal < current.ordinal,
                  previous.presentationTime < current.presentationTime,
                  previous.frameID != current.frameID,
                  previous.streamID == current.streamID,
                  previous.formatIdentity == current.formatIdentity,
                  previous.cadenceID == current.cadenceID,
                  previous.grid == current.grid,
                  let motion = entries[index].motionFromPrevious else {
                throw ASHTemporalV4Error.invalidHistory
            }
            try motion.validate(
                current: current,
                previous: previous,
                configuration: .canonical
            )
        }
    }
}

struct ASHTemporalTiledCheckpointV4: Codable, Equatable, Hashable,
    Sendable {
    static let currentSchemaID = "ash.temporal-tiled-checkpoint.v4.1"
    static let identityDomain = "ash-temporal-tiled-checkpoint-v4"

    let schemaID: String
    let planSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let lastCompletedInputOrdinal: Int64
    let lastCompletedOutputPresentationTime: ExactRationalV4
    let history: ASHTemporalTiledHistoryV4

    init(
        planSHA256: ASHSHA256V4,
        runtimeManifestSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64,
        lastCompletedOutputPresentationTime: ExactRationalV4,
        history: ASHTemporalTiledHistoryV4
    ) throws {
        self.schemaID = Self.currentSchemaID
        self.planSHA256 = planSHA256
        self.runtimeManifestSHA256 = runtimeManifestSHA256
        self.lastCompletedInputOrdinal = lastCompletedInputOrdinal
        self.lastCompletedOutputPresentationTime
            = lastCompletedOutputPresentationTime
        self.history = history
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID,
              lastCompletedInputOrdinal >= 0,
              lastCompletedOutputPresentationTime >= .zero else {
            throw ASHTemporalV4Error.invalidHistory
        }
        try history.validate()
        guard let latest = history.entries.last?.frame,
              latest.ordinal == lastCompletedInputOrdinal,
              latest.presentationTime
                == lastCompletedOutputPresentationTime else {
            throw ASHTemporalV4Error.invalidHistory
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
        expectedRuntimeManifestSHA256: ASHSHA256V4
    ) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        try decoded.validate()
        guard decoded.planSHA256 == expectedPlanSHA256,
              decoded.runtimeManifestSHA256
                == expectedRuntimeManifestSHA256 else {
            throw ASHTemporalV4Error.checkpointIdentityMismatch
        }
        guard try ASHCanonicalJSONV4.encode(decoded) == data else {
            throw ASHTemporalV4Error.nonCanonicalCheckpoint
        }
        return decoded
    }
}

struct ASHTemporalHistoryV4: Codable, Equatable, Hashable, Sendable {
    static let maximumCapacity = 8

    private(set) var generation: UInt64
    let capacity: Int
    private(set) var frames: [ASHTemporalFrameV4]
    private(set) var lastResetReason: ASHTemporalResetReasonV4?

    init(
        generation: UInt64 = 0,
        capacity: Int = 3,
        frames: [ASHTemporalFrameV4] = [],
        lastResetReason: ASHTemporalResetReasonV4? = nil
    ) throws {
        guard (1...Self.maximumCapacity).contains(capacity) else {
            throw ASHTemporalV4Error.invalidHistory
        }
        self.generation = generation
        self.capacity = capacity
        self.frames = frames
        self.lastResetReason = lastResetReason
        try validate()
    }

    mutating func append(_ frame: ASHTemporalFrameV4) throws {
        try validate()
        try frame.validate()
        if let previous = frames.last {
            guard previous.ordinal < frame.ordinal,
                  previous.presentationTime < frame.presentationTime,
                  previous.frameID != frame.frameID else {
                throw ASHTemporalV4Error.nonIncreasingFrameIdentity
            }
            guard previous.streamID == frame.streamID else {
                throw ASHTemporalV4Error.streamIdentityMismatch
            }
            guard previous.formatIdentity == frame.formatIdentity else {
                throw ASHTemporalV4Error.formatIdentityMismatch
            }
            guard previous.cadenceID == frame.cadenceID else {
                throw ASHTemporalV4Error.invalidHistory
            }
            guard previous.luma.width == frame.luma.width,
                  previous.luma.height == frame.luma.height,
                  previous.luma.minimumCode == frame.luma.minimumCode,
                  previous.luma.maximumCode == frame.luma.maximumCode else {
                throw ASHTemporalV4Error.planeGeometryMismatch
            }
        }
        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
        lastResetReason = nil
    }

    mutating func reset(reason: ASHTemporalResetReasonV4) throws {
        let next = generation.addingReportingOverflow(1)
        guard !next.overflow else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        generation = next.partialValue
        frames.removeAll(keepingCapacity: true)
        lastResetReason = reason
    }

    func validate() throws {
        guard (1...Self.maximumCapacity).contains(capacity),
              frames.count <= capacity,
              frames.isEmpty || lastResetReason == nil else {
            throw ASHTemporalV4Error.invalidHistory
        }
        for frame in frames {
            do {
                try frame.validate()
            } catch {
                throw ASHTemporalV4Error.invalidHistory
            }
        }
        for index in frames.indices.dropFirst() {
            let previous = frames[index - 1]
            let current = frames[index]
            guard previous.ordinal < current.ordinal,
                  previous.presentationTime < current.presentationTime,
                  previous.frameID != current.frameID,
                  previous.streamID == current.streamID,
                  previous.formatIdentity == current.formatIdentity,
                  previous.cadenceID == current.cadenceID,
                  previous.luma.width == current.luma.width,
                  previous.luma.height == current.luma.height,
                  previous.luma.minimumCode == current.luma.minimumCode,
                  previous.luma.maximumCode == current.luma.maximumCode else {
                throw ASHTemporalV4Error.invalidHistory
            }
        }
    }
}

struct ASHTemporalCheckpointV4: Codable, Equatable, Hashable, Sendable {
    static let currentSchemaID = "ash.temporal-checkpoint.v4.1"
    static let identityDomain = "ash-temporal-checkpoint-v4"

    let schemaID: String
    let planSHA256: ASHSHA256V4
    let runtimeManifestSHA256: ASHSHA256V4
    let lastCompletedInputOrdinal: Int64
    let lastCompletedOutputPresentationTime: ExactRationalV4
    let history: ASHTemporalHistoryV4

    init(
        planSHA256: ASHSHA256V4,
        runtimeManifestSHA256: ASHSHA256V4,
        lastCompletedInputOrdinal: Int64,
        lastCompletedOutputPresentationTime: ExactRationalV4,
        history: ASHTemporalHistoryV4
    ) throws {
        guard lastCompletedInputOrdinal >= 0,
              lastCompletedOutputPresentationTime >= .zero else {
            throw ASHTemporalV4Error.invalidHistory
        }
        self.schemaID = Self.currentSchemaID
        self.planSHA256 = planSHA256
        self.runtimeManifestSHA256 = runtimeManifestSHA256
        self.lastCompletedInputOrdinal = lastCompletedInputOrdinal
        self.lastCompletedOutputPresentationTime
            = lastCompletedOutputPresentationTime
        self.history = history
        try validate()
    }

    func validate() throws {
        guard schemaID == Self.currentSchemaID else {
            throw ASHTemporalV4Error.unsupportedCheckpointSchema(schemaID)
        }
        guard lastCompletedInputOrdinal >= 0,
              lastCompletedOutputPresentationTime >= .zero else {
            throw ASHTemporalV4Error.invalidHistory
        }
        try history.validate()
        if let latest = history.frames.last {
            guard latest.ordinal == lastCompletedInputOrdinal,
                  latest.presentationTime
                    == lastCompletedOutputPresentationTime else {
                throw ASHTemporalV4Error.invalidHistory
            }
        }
    }

    var canonicalData: Data {
        get throws {
            try validate()
            return try ASHCanonicalJSONV4.encode(self)
        }
    }

    var canonicalSHA256: ASHSHA256V4 {
        get throws {
            try ASHCanonicalJSONV4.hash(self, domain: Self.identityDomain)
        }
    }

    static func decodeCanonical(
        _ data: Data,
        expectedPlanSHA256: ASHSHA256V4,
        expectedRuntimeManifestSHA256: ASHSHA256V4
    ) throws -> Self {
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        try decoded.validate()
        guard decoded.planSHA256 == expectedPlanSHA256,
              decoded.runtimeManifestSHA256
                == expectedRuntimeManifestSHA256 else {
            throw ASHTemporalV4Error.checkpointIdentityMismatch
        }
        guard try ASHCanonicalJSONV4.encode(decoded) == data else {
            throw ASHTemporalV4Error.nonCanonicalCheckpoint
        }
        return decoded
    }
}

struct ASHTemporalReconstructionResultV4: Equatable, Sendable {
    let output: ASHTemporalPlaneV4
    let stateRawValue: UInt16
    let targetMessageRawValue: UInt8
    let historyWeightQ16: UInt32
}

struct ASHTemporalInPlaceResultV4: Equatable, Sendable {
    let stateRawValue: UInt16
    let targetMessageRawValue: UInt8
    let historyWeightQ16: UInt32
    let materializedAlignedSampleCount: Int
}

/// Applies a bounded temporal regularization basis after motion alignment.
/// The regularization strength is the exact conditioned expectation of the
/// fourth P06 operator control, so changing declared ASH state can change the
/// emitted pixels. Occlusion and reset paths return spatial pixels exactly.
enum ASHTemporalReconstructorV4 {
    /// A temporal sample can never outweigh the current spatial result. This
    /// bound is also what makes a wrong-but-admitted vector decay in one frame
    /// instead of becoming self-reinforcing history.
    static let maximumHistoryWeightQ16: UInt32 = 32_768

    /// Applies motion reliability at block granularity. Occluded blocks remain
    /// byte-for-byte spatial, while every admitted block uses its own confidence
    /// instead of inheriting the average confidence of unrelated blocks.
    ///
    /// Motion confidence supplies unit temporal support. The conditioned ASH
    /// regularization expectation contributes a bounded half-strength boost.
    /// This avoids the former triple-product attenuation (maximum * state *
    /// averaged confidence), which reduced useful support to only a few percent
    /// and still leaked that support into occluded blocks.
    static func reconstruct(
        spatial: ASHTemporalPlaneV4,
        motionAnalysis: ASHTemporalMotionAnalysisV4?,
        sourceState: ASHState,
        resetReason: ASHTemporalResetReasonV4?,
        program: ASHDepthFourBranchProgramV4
    ) throws -> ASHTemporalReconstructionResultV4 {
        guard sourceState.hasValidIntegrity else {
            throw ASHTemporalV4Error.invalidASHState(sourceState.rawValue)
        }
        let conditioned = try program.conditionedWeights(for: sourceState)
        let stateWeightQ16 = try regularizationExpectationQ16(
            conditioned: conditioned,
            program: program
        )
        guard resetReason == nil, let motionAnalysis else {
            return spatialResult(
                spatial: spatial,
                sourceState: sourceState,
                targetMessageRawValue: conditioned.targetMessageRawValue
            )
        }
        try motionAnalysis.validate()
        guard !motionAnalysis.sceneCut,
              let history = motionAnalysis.alignedPrevious else {
            return spatialResult(
                spatial: spatial,
                sourceState: sourceState,
                targetMessageRawValue: conditioned.targetMessageRawValue
            )
        }
        guard spatial.width == history.width,
              spatial.height == history.height,
              spatial.minimumCode == history.minimumCode,
              spatial.maximumCode == history.maximumCode else {
            throw ASHTemporalV4Error.planeGeometryMismatch
        }
        try validateBlockLayout(
            motionAnalysis.vectors,
            columns: motionAnalysis.blockColumns,
            rows: motionAnalysis.blockRows,
            width: spatial.width,
            height: spatial.height
        )

        let scale = UInt64(ASHNormalizedQ16V4.scale)
        let stateBoostQ16 = try roundedShift(
            UInt64(stateWeightQ16),
            fractionalBits: 1
        )
        let confidenceGainQ16 = scale + stateBoostQ16
        var output = spatial.samples
        var weightedHistorySum: UInt64 = 0

        for vector in motionAnalysis.vectors where !vector.occluded {
            let unboundedWeight = try roundedShift(
                UInt64(vector.confidenceQ16) * confidenceGainQ16,
                fractionalBits: 16
            )
            let historyWeight = min(
                UInt64(Self.maximumHistoryWeightQ16),
                unboundedWeight
            )
            guard historyWeight > 0 else { continue }
            let currentWeight = scale - historyWeight
            for y in vector.originY..<(vector.originY + vector.height) {
                let row = y * spatial.width
                for x in vector.originX..<(vector.originX + vector.width) {
                    let index = row + x
                    let currentTerm = UInt64(spatial.samples[index])
                        * currentWeight
                    let historyTerm = UInt64(history.samples[index])
                        * historyWeight
                    let sum = currentTerm.addingReportingOverflow(historyTerm)
                    guard !sum.overflow else {
                        throw ASHTemporalV4Error.arithmeticOverflow
                    }
                    let rounded = try roundedShift(
                        sum.partialValue,
                        fractionalBits: 16
                    )
                    guard let sample = UInt16(exactly: rounded),
                          sample >= spatial.minimumCode,
                          sample <= spatial.maximumCode else {
                        throw ASHTemporalV4Error.arithmeticOverflow
                    }
                    output[index] = sample
                }
            }
            let sampleCount = UInt64(vector.width * vector.height)
            let weighted = historyWeight.multipliedReportingOverflow(
                by: sampleCount
            )
            let accumulated = weightedHistorySum.addingReportingOverflow(
                weighted.partialValue
            )
            guard !weighted.overflow, !accumulated.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            weightedHistorySum = accumulated.partialValue
        }
        guard weightedHistorySum > 0 else {
            return spatialResult(
                spatial: spatial,
                sourceState: sourceState,
                targetMessageRawValue: conditioned.targetMessageRawValue
            )
        }
        let averageWeight = try divideRoundedTiesToEven(
            weightedHistorySum,
            by: UInt64(spatial.samples.count)
        )
        guard averageWeight <= UInt64(Self.maximumHistoryWeightQ16) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return ASHTemporalReconstructionResultV4(
            output: try spatial.replacing(samples: output),
            stateRawValue: sourceState.rawValue,
            targetMessageRawValue: conditioned.targetMessageRawValue,
            historyWeightQ16: UInt32(averageWeight)
        )
    }

    /// Vector-only equivalent of blockwise reconstruction. The previous luma
    /// plane is sampled at each admitted vector's `(x + dx, y + dy)` coordinate;
    /// no aligned image and no output copy are required. A complete validation
    /// and weight pass precedes the non-throwing mutation pass.
    static func reconstructInPlace(
        samples: inout [UInt16],
        width: Int,
        height: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        motionField: ASHTemporalMotionFieldV4?,
        previousHistory: ASHTemporalFrameV4?,
        sourceState: ASHState,
        resetReason: ASHTemporalResetReasonV4?,
        program: ASHDepthFourBranchProgramV4
    ) throws -> ASHTemporalInPlaceResultV4 {
        guard sourceState.hasValidIntegrity else {
            throw ASHTemporalV4Error.invalidASHState(sourceState.rawValue)
        }
        let sampleCount = width.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              minimumCode < maximumCode,
              !sampleCount.overflow,
              sampleCount.partialValue == samples.count,
              samples.allSatisfy({
                  $0 >= minimumCode && $0 <= maximumCode
              }) else {
            throw ASHTemporalV4Error.invalidPlaneGeometry(
                width: width,
                height: height,
                sampleCount: samples.count
            )
        }
        let conditioned = try program.conditionedWeights(for: sourceState)
        let stateWeightQ16 = try regularizationExpectationQ16(
            conditioned: conditioned,
            program: program
        )
        let spatialOnly = ASHTemporalInPlaceResultV4(
            stateRawValue: sourceState.rawValue,
            targetMessageRawValue: conditioned.targetMessageRawValue,
            historyWeightQ16: 0,
            materializedAlignedSampleCount: 0
        )
        guard resetReason == nil,
              let motionField,
              let previousHistory else {
            return spatialOnly
        }
        try motionField.validate()
        guard !motionField.sceneCut else { return spatialOnly }
        guard motionField.previousFrameID == previousHistory.frameID,
              motionField.streamID == previousHistory.streamID,
              motionField.formatIdentity == previousHistory.formatIdentity
        else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        let previous = previousHistory.luma
        guard motionField.planeWidth == width,
              motionField.planeHeight == height,
              motionField.minimumCode == minimumCode,
              motionField.maximumCode == maximumCode,
              previous.width == width,
              previous.height == height,
              previous.minimumCode == minimumCode,
              previous.maximumCode == maximumCode else {
            throw ASHTemporalV4Error.planeGeometryMismatch
        }
        try validateBlockLayout(
            motionField.vectors,
            columns: motionField.blockColumns,
            rows: motionField.blockRows,
            width: width,
            height: height
        )
        for vector in motionField.vectors {
            let minimumSourceX = vector.originX.addingReportingOverflow(
                Int(vector.dx)
            )
            let minimumSourceY = vector.originY.addingReportingOverflow(
                Int(vector.dy)
            )
            guard !minimumSourceX.overflow,
                  !minimumSourceY.overflow else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            let maximumSourceX = minimumSourceX.partialValue
                .addingReportingOverflow(vector.width)
            let maximumSourceY = minimumSourceY.partialValue
                .addingReportingOverflow(vector.height)
            guard !maximumSourceX.overflow,
                  !maximumSourceY.overflow,
                  minimumSourceX.partialValue >= 0,
                  minimumSourceY.partialValue >= 0,
                  maximumSourceX.partialValue <= width,
                  maximumSourceY.partialValue <= height else {
                throw ASHTemporalV4Error.invalidMotionField
            }
        }

        let scale = UInt64(ASHNormalizedQ16V4.scale)
        let stateBoostQ16 = try roundedShift(
            UInt64(stateWeightQ16),
            fractionalBits: 1
        )
        let confidenceGainQ16 = scale + stateBoostQ16
        var weightedHistorySum: UInt64 = 0
        for vector in motionField.vectors where !vector.occluded {
            let unboundedWeight = try roundedShift(
                UInt64(vector.confidenceQ16) * confidenceGainQ16,
                fractionalBits: 16
            )
            let historyWeight = min(
                UInt64(Self.maximumHistoryWeightQ16),
                unboundedWeight
            )
            guard historyWeight > 0 else { continue }
            let blockSampleCount = UInt64(vector.width * vector.height)
            let weighted = historyWeight.multipliedReportingOverflow(
                by: blockSampleCount
            )
            let accumulated = weightedHistorySum.addingReportingOverflow(
                weighted.partialValue
            )
            guard !weighted.overflow, !accumulated.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            weightedHistorySum = accumulated.partialValue
        }
        guard weightedHistorySum > 0 else { return spatialOnly }
        let averageWeight = try divideRoundedTiesToEven(
            weightedHistorySum,
            by: UInt64(samples.count)
        )
        guard averageWeight <= UInt64(Self.maximumHistoryWeightQ16) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        try Task.checkCancellation()

        // Convex interpolation of two validated UInt16 signal codes cannot
        // overflow UInt64 or leave the declared code interval.
        for vector in motionField.vectors where !vector.occluded {
            let historyWeight = min(
                UInt64(Self.maximumHistoryWeightQ16),
                roundedShift16Unchecked(
                    UInt64(vector.confidenceQ16) * confidenceGainQ16
                )
            )
            guard historyWeight > 0 else { continue }
            let currentWeight = scale - historyWeight
            for y in vector.originY..<(vector.originY + vector.height) {
                let currentRow = y * width
                let historyRow = (y + Int(vector.dy)) * width
                for x in vector.originX..<(vector.originX + vector.width) {
                    let currentIndex = currentRow + x
                    let historyIndex = historyRow + x + Int(vector.dx)
                    let sum = UInt64(samples[currentIndex]) * currentWeight
                        + UInt64(previous.samples[historyIndex]) * historyWeight
                    samples[currentIndex] = UInt16(
                        roundedShift16Unchecked(sum)
                    )
                }
            }
        }
        return ASHTemporalInPlaceResultV4(
            stateRawValue: sourceState.rawValue,
            targetMessageRawValue: conditioned.targetMessageRawValue,
            historyWeightQ16: UInt32(averageWeight),
            materializedAlignedSampleCount: 0
        )
    }

    static func reconstruct(
        spatial: ASHTemporalPlaneV4,
        motionField: ASHTemporalMotionFieldV4?,
        previousHistory: ASHTemporalFrameV4?,
        sourceState: ASHState,
        resetReason: ASHTemporalResetReasonV4?,
        program: ASHDepthFourBranchProgramV4
    ) throws -> ASHTemporalReconstructionResultV4 {
        var samples = spatial.samples
        let controls = try reconstructInPlace(
            samples: &samples,
            width: spatial.width,
            height: spatial.height,
            minimumCode: spatial.minimumCode,
            maximumCode: spatial.maximumCode,
            motionField: motionField,
            previousHistory: previousHistory,
            sourceState: sourceState,
            resetReason: resetReason,
            program: program
        )
        return ASHTemporalReconstructionResultV4(
            output: try spatial.replacing(samples: samples),
            stateRawValue: controls.stateRawValue,
            targetMessageRawValue: controls.targetMessageRawValue,
            historyWeightQ16: controls.historyWeightQ16
        )
    }

    static func reconstruct(
        spatial: ASHTemporalPlaneV4,
        alignedHistory: ASHTemporalPlaneV4?,
        sourceState: ASHState,
        motionConfidenceQ16: UInt32,
        resetReason: ASHTemporalResetReasonV4?,
        program: ASHDepthFourBranchProgramV4
    ) throws -> ASHTemporalReconstructionResultV4 {
        guard sourceState.hasValidIntegrity else {
            throw ASHTemporalV4Error.invalidASHState(sourceState.rawValue)
        }
        guard motionConfidenceQ16 <= ASHNormalizedQ16V4.scale else {
            throw ASHTemporalV4Error.invalidConfiguration
        }
        let conditioned = try program.conditionedWeights(for: sourceState)
        let stateWeightQ16 = try regularizationExpectationQ16(
            conditioned: conditioned,
            program: program
        )
        let historyWeightQ16: UInt32
        if resetReason != nil || alignedHistory == nil {
            historyWeightQ16 = 0
        } else {
            let first = UInt64(Self.maximumHistoryWeightQ16)
                * UInt64(stateWeightQ16)
            let second = first * UInt64(motionConfidenceQ16)
            historyWeightQ16 = UInt32(
                try roundedShift(second, fractionalBits: 32)
            )
        }
        guard let history = alignedHistory, historyWeightQ16 > 0 else {
            return ASHTemporalReconstructionResultV4(
                output: spatial,
                stateRawValue: sourceState.rawValue,
                targetMessageRawValue: conditioned.targetMessageRawValue,
                historyWeightQ16: 0
            )
        }
        guard spatial.width == history.width,
              spatial.height == history.height,
              spatial.minimumCode == history.minimumCode,
              spatial.maximumCode == history.maximumCode else {
            throw ASHTemporalV4Error.planeGeometryMismatch
        }
        let scale = UInt64(ASHNormalizedQ16V4.scale)
        let currentWeight = scale - UInt64(historyWeightQ16)
        var output: [UInt16] = []
        output.reserveCapacity(spatial.samples.count)
        for index in spatial.samples.indices {
            let currentTerm = UInt64(spatial.samples[index]) * currentWeight
            let historyTerm = UInt64(history.samples[index])
                * UInt64(historyWeightQ16)
            let sum = currentTerm.addingReportingOverflow(historyTerm)
            guard !sum.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            let rounded = try roundedShift(sum.partialValue, fractionalBits: 16)
            guard let sample = UInt16(exactly: rounded),
                  sample >= spatial.minimumCode,
                  sample <= spatial.maximumCode else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            output.append(sample)
        }
        return ASHTemporalReconstructionResultV4(
            output: try spatial.replacing(samples: output),
            stateRawValue: sourceState.rawValue,
            targetMessageRawValue: conditioned.targetMessageRawValue,
            historyWeightQ16: historyWeightQ16
        )
    }

    private static func regularizationExpectationQ16(
        conditioned: ASHStateConditionedMessageWeightsV4,
        program: ASHDepthFourBranchProgramV4
    ) throws -> UInt32 {
        guard let historyBasisIndex = program.operatorManifest.basisIDs
            .firstIndex(of: "regularization") else {
            throw ASHTemporalV4Error.invalidConfiguration
        }
        let stateNumerator = conditioned.weightsByMessage.reduce(UInt64(0)) {
            partial, weight in
            let coefficient = weight.operatorCoefficients[historyBasisIndex]
            guard coefficient > 0 else { return partial }
            return partial + weight.numerator * UInt64(coefficient)
        }
        return try normalizedQ16(
            numerator: stateNumerator,
            denominator: conditioned.denominator
        )
    }

    private static func spatialResult(
        spatial: ASHTemporalPlaneV4,
        sourceState: ASHState,
        targetMessageRawValue: UInt8
    ) -> ASHTemporalReconstructionResultV4 {
        ASHTemporalReconstructionResultV4(
            output: spatial,
            stateRawValue: sourceState.rawValue,
            targetMessageRawValue: targetMessageRawValue,
            historyWeightQ16: 0
        )
    }

    private static func validateBlockLayout(
        _ vectors: [ASHTemporalMotionVectorV4],
        columns: Int,
        rows: Int,
        width: Int,
        height: Int
    ) throws {
        guard width > 0,
              height > 0,
              columns > 0,
              rows > 0,
              let first = vectors.first,
              first.originX == 0,
              first.originY == 0,
              first.width > 0,
              first.height > 0,
              ceilingDivision(width, first.width) == columns,
              ceilingDivision(height, first.height) == rows else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        let expectedCount = columns.multipliedReportingOverflow(by: rows)
        guard !expectedCount.overflow,
              expectedCount.partialValue == vectors.count else {
            throw ASHTemporalV4Error.invalidMotionField
        }
        for (index, vector) in vectors.enumerated() {
            let column = index % columns
            let row = index / columns
            let expectedX = column.multipliedReportingOverflow(by: first.width)
            let expectedY = row.multipliedReportingOverflow(by: first.height)
            guard !expectedX.overflow,
                  !expectedY.overflow,
                  expectedX.partialValue >= 0,
                  expectedY.partialValue >= 0,
                  expectedX.partialValue < width,
                  expectedY.partialValue < height else {
                throw ASHTemporalV4Error.invalidMotionField
            }
            let expectedWidth = min(
                first.width,
                width - expectedX.partialValue
            )
            let expectedHeight = min(
                first.height,
                height - expectedY.partialValue
            )
            guard vector.originX == expectedX.partialValue,
                  vector.originY == expectedY.partialValue,
                  vector.width == expectedWidth,
                  vector.height == expectedHeight else {
                throw ASHTemporalV4Error.invalidMotionField
            }
        }
    }

    private static func ceilingDivision(_ value: Int, _ divisor: Int) -> Int {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }

    private static func divideRoundedTiesToEven(
        _ numerator: UInt64,
        by denominator: UInt64
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

    private static func normalizedQ16(
        numerator: UInt64,
        denominator: UInt64
    ) throws -> UInt32 {
        guard denominator > 0, numerator <= denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let product = numerator.multipliedFullWidth(
            by: UInt64(ASHNormalizedQ16V4.scale)
        )
        guard product.high < denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let division = denominator.dividingFullWidth(product)
        var quotient = division.quotient
        let complement = denominator - division.remainder
        if division.remainder > complement
            || (division.remainder == complement && quotient & 1 == 1) {
            quotient += 1
        }
        guard quotient <= UInt64(ASHNormalizedQ16V4.scale) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return UInt32(quotient)
    }

    private static func roundedShift(
        _ value: UInt64,
        fractionalBits: Int
    ) throws -> UInt64 {
        guard (1...63).contains(fractionalBits) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let denominator = UInt64(1) << fractionalBits
        var quotient = value >> fractionalBits
        let remainder = value & (denominator - 1)
        let half = denominator >> 1
        if remainder > half || (remainder == half && quotient & 1 == 1) {
            quotient += 1
        }
        return quotient
    }

    private static func roundedShift16Unchecked(_ value: UInt64) -> UInt64 {
        var quotient = value >> 16
        let remainder = value & 0xffff
        if remainder > 0x8000
            || (remainder == 0x8000 && quotient & 1 == 1) {
            quotient += 1
        }
        return quotient
    }
}

struct ASHSpatialReconstructionResultV4: Equatable, Sendable {
    let output: ASHTemporalPlaneV4
    let stateRawValue: UInt16
    let targetMessageRawValue: UInt8
    /// Q16 gains in canonical operator-basis order. Regularization remains a
    /// temporal control and is therefore reported as zero in the spatial IR.
    let basisGainsQ16: [UInt32]
}

enum ASHSpatialExecutionPolicyV4: Sendable {
    case automatic
    case serial
    case parallel(maximumWorkers: Int)

    static let parallelSampleThreshold = 262_144

    func workerCount(rows: Int, sampleCount: Int) throws -> Int {
        let available = max(1, ProcessInfo.processInfo.activeProcessorCount)
        switch self {
        case .automatic:
            return sampleCount < Self.parallelSampleThreshold
                ? 1 : min(rows, available)
        case .serial:
            return 1
        case .parallel(let maximumWorkers):
            guard maximumWorkers > 0 else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            return min(rows, min(available, maximumWorkers))
        }
    }
}

private enum ASHSpatialBatchExecutorV4 {
    private static let queue = DispatchQueue(
        label: "com.mirmir.deterministic.spatial.v4",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func perform(iterations: Int, work: @Sendable (Int) -> Void) {
        queue.sync {
            DispatchQueue.concurrentPerform(iterations: iterations, execute: work)
        }
    }
}

// These borrows exist only inside one exclusive output borrow and one workspace
// borrow. Workers own disjoint output stripes and three-row rings; boundary rows
// are immutable snapshots. The executor joins before either borrow ends.
private struct ASHSpatialStripeBorrowV4: @unchecked Sendable {
    let output: UnsafeMutableBufferPointer<UInt16>
    let rows: UnsafeMutableBufferPointer<UInt16>
    let previousBoundaryRow: UnsafeBufferPointer<UInt16>
    let nextBoundaryRow: UnsafeBufferPointer<UInt16>
    let rowRange: Range<Int>
}

/// Each worker retains three active rows for the canonical four-neighbor
/// stencil; two original rows are saved per stripe boundary. Storage grows with
/// width and the bounded worker count, never with frame area.
struct ASHSpatialReconstructionWorkspaceV4: Sendable {
    fileprivate(set) var rows: [UInt16] = []
    private(set) var reservedWidth = 0
    private(set) var storageAllocationCount = 0
    private(set) var storageIdentity: UInt = 0
    private(set) var retainedSampleCapacity = 0

    var retainedByteUpperBound: Int {
        retainedSampleCapacity * MemoryLayout<UInt16>.stride
    }

    fileprivate mutating func prepare(
        width: Int,
        workerCount: Int = 1
    ) throws {
        guard width > 0 else {
            throw ASHTemporalV4Error.invalidPlaneGeometry(
                width: width,
                height: 0,
                sampleCount: 0
            )
        }
        guard workerCount > 0 else {
            throw ASHTemporalV4Error.invalidConfiguration
        }
        let rowCount = workerCount.multipliedReportingOverflow(by: 5)
        guard !rowCount.overflow else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let count = width.multipliedReportingOverflow(
            by: rowCount.partialValue - 2
        )
        guard !count.overflow else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let priorIdentity = storageIdentity
        let declaredAllocation = count.partialValue > retainedSampleCapacity
        if declaredAllocation {
            rows = Array(repeating: 0, count: count.partialValue)
            retainedSampleCapacity = count.partialValue
            storageAllocationCount += 1
        } else if rows.count < count.partialValue {
            rows.append(
                contentsOf: repeatElement(
                    0,
                    count: count.partialValue - rows.count
                )
            )
        } else if rows.count > count.partialValue {
            rows.removeLast(rows.count - count.partialValue)
        }
        reservedWidth = max(reservedWidth, width)
        let nextIdentity = rows.withUnsafeBufferPointer { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: base)
        }
        if !declaredAllocation,
           priorIdentity != 0,
           nextIdentity != priorIdentity {
            storageAllocationCount += 1
        }
        storageIdentity = nextIdentity
    }
}

struct ASHSpatialInPlaceResultV4: Equatable, Sendable {
    let stateRawValue: UInt16
    let targetMessageRawValue: UInt8
    let basisGainsQ16: [UInt32]
    let retainedRowSampleCount: Int
    let workerCount: Int
}

/// Shared integer spatial reconstruction policy applied after the common
/// rational resampling kernel and before temporal history. CPU and Metal routes
/// consume the same state-conditioned blend here, so the selected ASH state
/// changes first-frame pixels without introducing backend-specific arithmetic.
enum ASHSpatialReconstructorV4 {
    static let outputRuleID = "ash.p06.conditioned-fixed-point-blend.v1"
    static let maximumDetailGainQ16: UInt32 = 2_048 // 1/32 per basis

    static func reconstruct(
        spatial: ASHTemporalPlaneV4,
        sourceState: ASHState,
        program: ASHDepthFourBranchProgramV4
    ) throws -> ASHSpatialReconstructionResultV4 {
        guard sourceState.hasValidIntegrity else {
            throw ASHTemporalV4Error.invalidASHState(sourceState.rawValue)
        }
        let conditioned = try program.conditionedWeights(for: sourceState)
        let expectedBasis = try expectedBasisWeightsQ16(
            conditioned: conditioned,
            program: program
        )
        guard expectedBasis.count == 4,
              program.operatorManifest.basisIDs == [
                "horizontal_detail",
                "vertical_detail",
                "isotropic_detail",
                "regularization"
              ] else {
            throw ASHTemporalV4Error.invalidConfiguration
        }
        var gains = try expectedBasis.map { expectation in
            try scaledGain(expectation)
        }
        // The fourth canonical control is consumed only by temporal history.
        gains[3] = 0

        let width = spatial.width
        let height = spatial.height
        let source = spatial.samples
        var output = source
        for y in 0..<height {
            let upY = max(0, y - 1)
            let downY = min(height - 1, y + 1)
            for x in 0..<width {
                let leftX = max(0, x - 1)
                let rightX = min(width - 1, x + 1)
                let index = y * width + x
                let center = Int64(source[index])
                let left = Int64(source[y * width + leftX])
                let right = Int64(source[y * width + rightX])
                let up = Int64(source[upY * width + x])
                let down = Int64(source[downY * width + x])
                let horizontalAverage = try divideSignedTiesToEven(
                    left + right,
                    by: 2
                )
                let verticalAverage = try divideSignedTiesToEven(
                    up + down,
                    by: 2
                )
                let isotropicAverage = try divideSignedTiesToEven(
                    left + right + up + down,
                    by: 4
                )
                let weighted = (center - horizontalAverage)
                        * Int64(gains[0])
                    + (center - verticalAverage) * Int64(gains[1])
                    + (center - isotropicAverage) * Int64(gains[2])
                let adjustment = try divideSignedTiesToEven(
                    weighted,
                    by: Int64(ASHNormalizedQ16V4.scale)
                )
                let reconstructed = min(
                    Int64(spatial.maximumCode),
                    max(Int64(spatial.minimumCode), center + adjustment)
                )
                guard let sample = UInt16(exactly: reconstructed) else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                output[index] = sample
            }
        }
        return ASHSpatialReconstructionResultV4(
            output: try spatial.replacing(samples: output),
            stateRawValue: sourceState.rawValue,
            targetMessageRawValue: conditioned.targetMessageRawValue,
            basisGainsQ16: gains
        )
    }

    /// Applies the exact reference stencil with bounded row storage. Every
    /// validation and cancellation point precedes mutation; serial and joined
    /// parallel commit loops are integer-bounded and non-throwing.
    static func reconstructInPlace(
        samples: inout [UInt16],
        width: Int,
        height: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        sourceState: ASHState,
        program: ASHDepthFourBranchProgramV4,
        workspace: inout ASHSpatialReconstructionWorkspaceV4,
        executionPolicy: ASHSpatialExecutionPolicyV4 = .automatic
    ) throws -> ASHSpatialInPlaceResultV4 {
        guard sourceState.hasValidIntegrity else {
            throw ASHTemporalV4Error.invalidASHState(sourceState.rawValue)
        }
        let sampleCount = width.multipliedReportingOverflow(by: height)
        guard width > 0,
              height > 0,
              minimumCode < maximumCode,
              !sampleCount.overflow,
              sampleCount.partialValue == samples.count,
              samples.allSatisfy({
                  $0 >= minimumCode && $0 <= maximumCode
              }) else {
            throw ASHTemporalV4Error.invalidPlaneGeometry(
                width: width,
                height: height,
                sampleCount: samples.count
            )
        }
        let conditioned = try program.conditionedWeights(for: sourceState)
        let expectedBasis = try expectedBasisWeightsQ16(
            conditioned: conditioned,
            program: program
        )
        guard expectedBasis.count == 4,
              program.operatorManifest.basisIDs == [
                "horizontal_detail",
                "vertical_detail",
                "isotropic_detail",
                "regularization"
              ] else {
            throw ASHTemporalV4Error.invalidConfiguration
        }
        var gains = try expectedBasis.map { try scaledGain($0) }
        gains[3] = 0
        let workerCount = try executionPolicy.workerCount(
            rows: height,
            sampleCount: sampleCount.partialValue
        )
        try workspace.prepare(width: width, workerCount: workerCount)

        if workerCount > 1 {
            try reconstructParallelStripes(
                samples: &samples,
                width: width,
                height: height,
                minimumCode: minimumCode,
                maximumCode: maximumCode,
                gains: gains,
                workerCount: workerCount,
                workspace: &workspace
            )
            return ASHSpatialInPlaceResultV4(
                stateRawValue: sourceState.rawValue,
                targetMessageRawValue: conditioned.targetMessageRawValue,
                basisGainsQ16: gains,
                retainedRowSampleCount: workspace.rows.count,
                workerCount: workerCount
            )
        }

        func loadRow(_ sourceY: Int, into slot: Int) {
            let sourceStart = sourceY * width
            let destinationStart = slot * width
            samples.withUnsafeBufferPointer { sourceBuffer in
                workspace.rows.withUnsafeMutableBufferPointer {
                    destinationBuffer in
                    for x in 0..<width {
                        destinationBuffer[destinationStart + x] =
                            sourceBuffer[sourceStart + x]
                    }
                }
            }
        }
        loadRow(0, into: 0)
        loadRow(0, into: 1)
        loadRow(min(1, height - 1), into: 2)
        try Task.checkCancellation()

        var previousSlot = 0
        var currentSlot = 1
        var nextSlot = 2
        for y in 0..<height {
            let previousStart = previousSlot * width
            let currentStart = currentSlot * width
            let nextStart = nextSlot * width
            let outputStart = y * width
            for x in 0..<width {
                let leftX = max(0, x - 1)
                let rightX = min(width - 1, x + 1)
                let center = Int64(workspace.rows[currentStart + x])
                let left = Int64(workspace.rows[currentStart + leftX])
                let right = Int64(workspace.rows[currentStart + rightX])
                let up = Int64(workspace.rows[previousStart + x])
                let down = Int64(workspace.rows[nextStart + x])
                let horizontalAverage = divideSignedTiesToEvenUnchecked(
                    left + right,
                    by: 2
                )
                let verticalAverage = divideSignedTiesToEvenUnchecked(
                    up + down,
                    by: 2
                )
                let isotropicAverage = divideSignedTiesToEvenUnchecked(
                    left + right + up + down,
                    by: 4
                )
                let weighted = (center - horizontalAverage)
                        * Int64(gains[0])
                    + (center - verticalAverage) * Int64(gains[1])
                    + (center - isotropicAverage) * Int64(gains[2])
                let adjustment = divideSignedTiesToEvenUnchecked(
                    weighted,
                    by: Int64(ASHNormalizedQ16V4.scale)
                )
                samples[outputStart + x] = UInt16(
                    min(
                        Int64(maximumCode),
                        max(Int64(minimumCode), center + adjustment)
                    )
                )
            }
            guard y + 1 < height else { continue }
            let recycledSlot = previousSlot
            previousSlot = currentSlot
            currentSlot = nextSlot
            nextSlot = recycledSlot
            loadRow(min(y + 2, height - 1), into: nextSlot)
        }
        return ASHSpatialInPlaceResultV4(
            stateRawValue: sourceState.rawValue,
            targetMessageRawValue: conditioned.targetMessageRawValue,
            basisGainsQ16: gains,
            retainedRowSampleCount: width * 3,
            workerCount: workerCount
        )
    }

    private static func reconstructParallelStripes(
        samples: inout [UInt16],
        width: Int,
        height: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        gains: [UInt32],
        workerCount: Int,
        workspace: inout ASHSpatialReconstructionWorkspaceV4
    ) throws {
        let rowsPerWorker = height / workerCount
        let extraRows = height % workerCount
        let boundaryStart = workerCount * 3 * width
        try samples.withUnsafeMutableBufferPointer { output in
            try workspace.rows.withUnsafeMutableBufferPointer { scratch in
                // Save both sides of every boundary before any output writes.
                for index in 1..<workerCount {
                    let firstRow = index * rowsPerWorker + min(index, extraRows)
                    let snapshotStart = boundaryStart + (index - 1) * 2 * width
                    scratch.baseAddress!.advanced(by: snapshotStart).update(
                        from: output.baseAddress!.advanced(
                            by: (firstRow - 1) * width
                        ),
                        count: width * 2
                    )
                }
                var stripes: [ASHSpatialStripeBorrowV4] = []
                stripes.reserveCapacity(workerCount)
                for index in 0..<workerCount {
                    let lower = index * rowsPerWorker + min(index, extraRows)
                    let upper = lower + rowsPerWorker
                        + (index < extraRows ? 1 : 0)
                    let ringStart = index * 3 * width
                    let ringEnd = ringStart + 3 * width
                    let previousBoundary = index == 0
                        ? UnsafeBufferPointer<UInt16>(start: nil, count: 0)
                        : UnsafeBufferPointer(
                            start: scratch.baseAddress!.advanced(
                                by: boundaryStart + (index - 1) * 2 * width
                            ),
                            count: width
                        )
                    let nextBoundary = index + 1 == workerCount
                        ? UnsafeBufferPointer<UInt16>(start: nil, count: 0)
                        : UnsafeBufferPointer(
                            start: scratch.baseAddress!.advanced(
                                by: boundaryStart + (index * 2 + 1) * width
                            ),
                            count: width
                        )
                    stripes.append(ASHSpatialStripeBorrowV4(
                        output: UnsafeMutableBufferPointer(
                            rebasing: output[(lower * width)..<(upper * width)]
                        ),
                        rows: UnsafeMutableBufferPointer(
                            rebasing: scratch[ringStart..<ringEnd]
                        ),
                        previousBoundaryRow: previousBoundary,
                        nextBoundaryRow: nextBoundary,
                        rowRange: lower..<upper
                    ))
                }
                let stripeBorrows = stripes
                try Task.checkCancellation()
                ASHSpatialBatchExecutorV4.perform(iterations: workerCount) { index in
                    reconstructStripe(
                        stripeBorrows[index],
                        width: width,
                        height: height,
                        minimumCode: minimumCode,
                        maximumCode: maximumCode,
                        gains: gains
                    )
                }
            }
        }
    }

    private static func reconstructStripe(
        _ stripe: ASHSpatialStripeBorrowV4,
        width: Int,
        height: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        gains: [UInt32]
    ) {
        func loadRow(_ sourceY: Int, into slot: Int) {
            let source: UnsafeBufferPointer<UInt16>
            if sourceY < stripe.rowRange.lowerBound {
                source = stripe.previousBoundaryRow
            } else if sourceY >= stripe.rowRange.upperBound {
                source = stripe.nextBoundaryRow
            } else {
                source = UnsafeBufferPointer(
                    start: stripe.output.baseAddress!.advanced(
                        by: (sourceY - stripe.rowRange.lowerBound) * width
                    ),
                    count: width
                )
            }
            stripe.rows.baseAddress!.advanced(by: slot * width).update(
                from: source.baseAddress!,
                count: width
            )
        }
        let firstRow = stripe.rowRange.lowerBound
        loadRow(max(0, firstRow - 1), into: 0)
        loadRow(firstRow, into: 1)
        loadRow(min(firstRow + 1, height - 1), into: 2)
        var previousSlot = 0
        var currentSlot = 1
        var nextSlot = 2
        for y in stripe.rowRange {
            let previousStart = previousSlot * width
            let currentStart = currentSlot * width
            let nextStart = nextSlot * width
            let outputStart = (y - firstRow) * width
            for x in 0..<width {
                let leftX = max(0, x - 1)
                let rightX = min(width - 1, x + 1)
                let center = Int64(stripe.rows[currentStart + x])
                let left = Int64(stripe.rows[currentStart + leftX])
                let right = Int64(stripe.rows[currentStart + rightX])
                let up = Int64(stripe.rows[previousStart + x])
                let down = Int64(stripe.rows[nextStart + x])
                let horizontalAverage = divideSignedTiesToEvenUnchecked(
                    left + right,
                    by: 2
                )
                let verticalAverage = divideSignedTiesToEvenUnchecked(
                    up + down,
                    by: 2
                )
                let isotropicAverage = divideSignedTiesToEvenUnchecked(
                    left + right + up + down,
                    by: 4
                )
                let weighted = (center - horizontalAverage)
                        * Int64(gains[0])
                    + (center - verticalAverage) * Int64(gains[1])
                    + (center - isotropicAverage) * Int64(gains[2])
                let adjustment = divideSignedTiesToEvenUnchecked(
                    weighted,
                    by: Int64(ASHNormalizedQ16V4.scale)
                )
                stripe.output[outputStart + x] = UInt16(
                    min(
                        Int64(maximumCode),
                        max(Int64(minimumCode), center + adjustment)
                    )
                )
            }
            guard y + 1 < stripe.rowRange.upperBound else { continue }
            let recycledSlot = previousSlot
            previousSlot = currentSlot
            currentSlot = nextSlot
            nextSlot = recycledSlot
            loadRow(min(y + 2, height - 1), into: nextSlot)
        }
    }

    private static func expectedBasisWeightsQ16(
        conditioned: ASHStateConditionedMessageWeightsV4,
        program: ASHDepthFourBranchProgramV4
    ) throws -> [UInt32] {
        let basisCount = program.operatorManifest.basisIDs.count
        var numerators = Array(repeating: UInt64(0), count: basisCount)
        for weight in conditioned.weightsByMessage {
            guard weight.operatorCoefficients.count == basisCount else {
                throw ASHTemporalV4Error.invalidConfiguration
            }
            for index in 0..<basisCount {
                let coefficient = weight.operatorCoefficients[index]
                guard coefficient >= 0 else {
                    throw ASHTemporalV4Error.invalidConfiguration
                }
                let product = weight.numerator.multipliedReportingOverflow(
                    by: UInt64(coefficient)
                )
                let sum = numerators[index].addingReportingOverflow(
                    product.partialValue
                )
                guard !product.overflow, !sum.overflow else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                numerators[index] = sum.partialValue
            }
        }
        return try numerators.map { numerator in
            try normalizedQ16(
                numerator: numerator,
                denominator: conditioned.denominator
            )
        }
    }

    private static func scaledGain(_ expectationQ16: UInt32) throws -> UInt32 {
        let product = UInt64(expectationQ16).multipliedReportingOverflow(
            by: UInt64(maximumDetailGainQ16)
        )
        guard !product.overflow else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let value = try divideUnsignedTiesToEven(
            product.partialValue,
            by: UInt64(ASHNormalizedQ16V4.scale)
        )
        guard let result = UInt32(exactly: value),
              result <= maximumDetailGainQ16 else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return result
    }

    private static func normalizedQ16(
        numerator: UInt64,
        denominator: UInt64
    ) throws -> UInt32 {
        guard denominator > 0, numerator <= denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let product = numerator.multipliedFullWidth(
            by: UInt64(ASHNormalizedQ16V4.scale)
        )
        guard product.high < denominator else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let division = denominator.dividingFullWidth(product)
        var quotient = division.quotient
        let complement = denominator - division.remainder
        if division.remainder > complement
            || (division.remainder == complement && quotient & 1 == 1) {
            quotient += 1
        }
        guard let value = UInt32(exactly: quotient),
              value <= ASHNormalizedQ16V4.scale else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return value
    }

    private static func divideUnsignedTiesToEven(
        _ numerator: UInt64,
        by denominator: UInt64
    ) throws -> UInt64 {
        guard denominator > 0 else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        var quotient = numerator / denominator
        let remainder = numerator % denominator
        let complement = denominator - remainder
        if remainder > complement
            || (remainder == complement && quotient & 1 == 1) {
            let increment = quotient.addingReportingOverflow(1)
            guard !increment.overflow else {
                throw ASHTemporalV4Error.arithmeticOverflow
            }
            quotient = increment.partialValue
        }
        return quotient
    }

    private static func divideSignedTiesToEven(
        _ numerator: Int64,
        by denominator: Int64
    ) throws -> Int64 {
        guard denominator > 0 else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let negative = numerator < 0
        let magnitude = numerator.magnitude
        let rounded = try divideUnsignedTiesToEven(
            magnitude,
            by: UInt64(denominator)
        )
        guard rounded <= UInt64(Int64.max) else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        return negative ? -Int64(rounded) : Int64(rounded)
    }

    private static func divideSignedTiesToEvenUnchecked(
        _ numerator: Int64,
        by denominator: Int64
    ) -> Int64 {
        precondition(denominator > 0 && numerator != Int64.min)
        let negative = numerator < 0
        let magnitude = UInt64(negative ? -numerator : numerator)
        let divisor = UInt64(denominator)
        var quotient = magnitude / divisor
        let remainder = magnitude % divisor
        let complement = divisor - remainder
        if remainder > complement
            || (remainder == complement && quotient & 1 == 1) {
            quotient += 1
        }
        let value = Int64(quotient)
        return negative ? -value : value
    }
}
