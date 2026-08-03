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
}

enum ASHTemporalResetReasonV4: String, Codable, CaseIterable, Hashable,
    Sendable {
    case streamStart = "stream_start"
    case sceneCut = "scene_cut"
    case discontinuity
    case seek
    case geometryChange = "geometry_change"
    case pixelFormatChange = "pixel_format_change"
    case colorDomainChange = "color_domain_change"
    case fieldCadenceChange = "field_cadence_change"
    case contractChange = "contract_change"
    case explicitReset = "explicit_reset"
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
        configuration: ASHTemporalBlockMatchingConfigurationV4 = .canonical
    ) throws -> ASHTemporalMotionFieldResultV4 {
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

        let signalRange = UInt64(
            currentPlane.maximumCode - currentPlane.minimumCode
        )
        var vectors: [ASHTemporalMotionVectorV4] = []
        vectors.reserveCapacity(columns * rows)
        var weightedEvidence: UInt64 = 0
        var weightedCount: UInt64 = 0

        for blockY in 0..<rows {
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
                let index = vectors.count
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
                let weighted = UInt64(costQ16).multipliedReportingOverflow(
                    by: sampleCount
                )
                let nextEvidence = weightedEvidence.addingReportingOverflow(
                    weighted.partialValue
                )
                let nextCount = weightedCount.addingReportingOverflow(
                    sampleCount
                )
                guard !weighted.overflow,
                      !nextEvidence.overflow,
                      !nextCount.overflow else {
                    throw ASHTemporalV4Error.arithmeticOverflow
                }
                weightedEvidence = nextEvidence.partialValue
                weightedCount = nextCount.partialValue
            }
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
        var best: Candidate?
        var second: Candidate?
        for dy in minimumDY...maximumDY {
            for dx in minimumDX...maximumDX {
                var difference: UInt64 = 0
                for localY in 0..<height {
                    for localX in 0..<width {
                        let currentValue = current.sample(
                            x: originX + localX,
                            y: originY + localY
                        )
                        let previousValue = previous.sample(
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

/// Three active rows are sufficient for the canonical four-neighbor stencil.
/// The workspace grows only with width, never with frame area, and exposes
/// allocation identity for qualification and long-run diagnostics.
struct ASHSpatialReconstructionWorkspaceV4: Sendable {
    fileprivate(set) var rows: [UInt16] = []
    private(set) var reservedWidth = 0
    private(set) var storageAllocationCount = 0
    private(set) var storageIdentity: UInt = 0

    var retainedSampleCapacity: Int { reservedWidth * 3 }
    var retainedByteUpperBound: Int {
        retainedSampleCapacity * MemoryLayout<UInt16>.stride
    }

    fileprivate mutating func prepare(width: Int) throws {
        guard width > 0 else {
            throw ASHTemporalV4Error.invalidPlaneGeometry(
                width: width,
                height: 0,
                sampleCount: 0
            )
        }
        let count = width.multipliedReportingOverflow(by: 3)
        guard !count.overflow else {
            throw ASHTemporalV4Error.arithmeticOverflow
        }
        let priorIdentity = storageIdentity
        let declaredAllocation = width > reservedWidth
        if declaredAllocation {
            rows = Array(repeating: 0, count: count.partialValue)
            reservedWidth = width
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

    /// Applies the exact reference stencil in place while retaining only three
    /// original source rows. Every validation and cancellation point precedes
    /// mutation; the commit loop is integer-bounded and non-throwing.
    static func reconstructInPlace(
        samples: inout [UInt16],
        width: Int,
        height: Int,
        minimumCode: UInt16,
        maximumCode: UInt16,
        sourceState: ASHState,
        program: ASHDepthFourBranchProgramV4,
        workspace: inout ASHSpatialReconstructionWorkspaceV4
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
        try workspace.prepare(width: width)

        func loadRow(_ sourceY: Int, into slot: Int) {
            let sourceStart = sourceY * width
            let destinationStart = slot * width
            for x in 0..<width {
                workspace.rows[destinationStart + x] = samples[sourceStart + x]
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
            retainedRowSampleCount: width * 3
        )
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
