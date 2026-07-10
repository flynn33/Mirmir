import Foundation

struct ASHIntRect: Equatable, Sendable {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
}

struct ASHChromaPlane: Equatable, Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    func energy(inLumaRect rect: ASHIntRect) -> Double {
        guard width > 0, height > 0, bytesPerRow >= width * 2 else { return 0.0 }
        let startColumn = min(max(rect.originX / 2, 0), width - 1)
        let endColumn = min(max((rect.originX + rect.width + 1) / 2, startColumn + 1), width)
        let startRow = min(max(rect.originY / 2, 0), height - 1)
        let endRow = min(max((rect.originY + rect.height + 1) / 2, startRow + 1), height)

        var total = 0.0
        var count = 0
        for row in startRow..<endRow {
            let rowBase = row * bytesPerRow
            for column in startColumn..<endColumn {
                let offset = rowBase + (column * 2)
                guard offset + 1 < bytes.count else { continue }
                let cb = abs(Double(bytes[offset]) - 128.0)
                let cr = abs(Double(bytes[offset + 1]) - 128.0)
                total += (cb + cr) / 255.0
                count += 1
            }
        }
        guard count > 0 else { return 0.0 }
        return min(1.0, max(0.0, total / Double(count)))
    }
}

struct ASHTileDescriptor: Equatable, Sendable {
    let id: Int
    let sourceRect: ASHIntRect

    func outputRect(scale: Int) -> ASHIntRect {
        ASHIntRect(
            originX: sourceRect.originX * scale,
            originY: sourceRect.originY * scale,
            width: sourceRect.width * scale,
            height: sourceRect.height * scale
        )
    }
}

struct ASHTileDecision: Equatable, Sendable {
    let tile: ASHTileDescriptor
    let features: ASHFeatureVector
    let sourceState: ASHState
    let selectedMessage: ASHMessage
    let selectedScore: Double
    let historyResetReason: ASHHistoryResetReason?
}

enum ASHHistoryResetReason: String, Equatable, Sendable {
    case noPriorFrame
    case missingPriorTile
    case missingPriorState
    case invalidPriorState
    case sceneCut
}

struct ASHTileProcessingSummary: Equatable, Sendable {
    let tileCount: Int
    let selectedMessageHistogram: [ASHMessage: Int]
    let maxCandidatesPerTile: Int
    let estimatedPeakTemporaryBytes: Int
    let chromaFeatureEnabled: Bool
    let historyResetCount: Int
    let sceneCutResetCount: Int
    let configuration: ASHRuntimeConfiguration
}

struct ASHTileTemporalState: Equatable, Sendable {
    let sourceTiles: [Int: ASHImage]
    let sourceStates: [Int: ASHState]
    let reconstructions: [Int: ASHImage]
}

struct ASHTileProcessingResult: Equatable, Sendable {
    let reconstruction: ASHImage
    let decisions: [ASHTileDecision]
    let summary: ASHTileProcessingSummary
    let temporalState: ASHTileTemporalState
}

private struct ASHTileContext {
    let currentTile: ASHImage
    let mapping: ASHMappingResult
    let selected: ASHReconstructionCandidate
    let historyResetReason: ASHHistoryResetReason?
}

private struct ASHTileProcessingState {
    private let outputWidth: Int
    var stitchedValues: [Double]
    var decisions: [ASHTileDecision] = []
    var sourceTiles: [Int: ASHImage] = [:]
    var sourceStates: [Int: ASHState] = [:]
    var reconstructions: [Int: ASHImage] = [:]
    var histogram: [ASHMessage: Int] = [:]
    var maxCandidates = 0
    var estimatedPeakTemporaryBytes = 0
    var historyResetCount = 0
    var sceneCutResetCount = 0

    init(outputWidth: Int, outputHeight: Int) {
        self.outputWidth = outputWidth
        self.stitchedValues = Array(repeating: 0.0, count: outputWidth * outputHeight)
    }

    mutating func record(
        tile: ASHTileDescriptor,
        context: ASHTileContext,
        scale: Int,
        topK: Int
    ) throws {
        let outputRect = tile.outputRect(scale: scale)
        try stitch(context.selected.reconstruction, outputRect: outputRect)
        decisions.append(ASHTileDecision(
            tile: tile,
            features: context.mapping.features,
            sourceState: context.mapping.sourceState,
            selectedMessage: context.selected.message,
            selectedScore: context.selected.totalScore,
            historyResetReason: context.historyResetReason
        ))
        sourceTiles[tile.id] = context.currentTile
        sourceStates[tile.id] = context.mapping.sourceState
        reconstructions[tile.id] = context.selected.reconstruction
        histogram[context.selected.message, default: 0] += 1
        maxCandidates = max(maxCandidates, context.mapping.evaluatedCandidateCount)
        if context.historyResetReason != nil {
            historyResetCount += 1
        }
        if context.historyResetReason == .sceneCut {
            sceneCutResetCount += 1
        }

        let retainedImageCount = 4 + min(topK, context.mapping.evaluatedCandidateCount) + 1
        estimatedPeakTemporaryBytes = max(
            estimatedPeakTemporaryBytes,
            retainedImageCount * context.selected.reconstruction.values.count * MemoryLayout<Double>.stride
        )
    }

    func summary(
        tileCount: Int,
        chromaFeatureEnabled: Bool,
        configuration: ASHRuntimeConfiguration
    ) -> ASHTileProcessingSummary {
        ASHTileProcessingSummary(
            tileCount: tileCount,
            selectedMessageHistogram: histogram,
            maxCandidatesPerTile: maxCandidates,
            estimatedPeakTemporaryBytes: estimatedPeakTemporaryBytes,
            chromaFeatureEnabled: chromaFeatureEnabled,
            historyResetCount: historyResetCount,
            sceneCutResetCount: sceneCutResetCount,
            configuration: configuration
        )
    }

    var temporalState: ASHTileTemporalState {
        ASHTileTemporalState(
            sourceTiles: sourceTiles,
            sourceStates: sourceStates,
            reconstructions: reconstructions
        )
    }

    private mutating func stitch(_ reconstruction: ASHImage, outputRect: ASHIntRect) throws {
        guard reconstruction.channels == 1,
              reconstruction.width == outputRect.width,
              reconstruction.height == outputRect.height else {
            throw ASHCoreError.invalidCandidateShape
        }
        for localRow in 0..<outputRect.height {
            let outputRow = outputRect.originY + localRow
            for localColumn in 0..<outputRect.width {
                let outputColumn = outputRect.originX + localColumn
                stitchedValues[(outputRow * outputWidth) + outputColumn] = reconstruction.value(
                    row: localRow,
                    column: localColumn
                )
            }
        }
    }
}

struct ASHTileProcessor: Sendable {
    let tileSize: Int
    let scale: Int
    let topK: Int
    let configuration: ASHRuntimeConfiguration

    init(
        tileSize: Int = 32,
        scale: Int = ASHReconstruction.defaultScale,
        topK: Int = ASHReconstruction.defaultTopK,
        configuration: ASHRuntimeConfiguration = .current
    ) {
        self.tileSize = tileSize
        self.scale = scale
        self.topK = topK
        self.configuration = configuration
    }

    func process(
        luma: ASHImage,
        chroma: ASHChromaPlane? = nil,
        previous: ASHTileTemporalState? = nil
    ) throws -> ASHTileProcessingResult {
        guard luma.channels == 1 else { throw ASHCoreError.invalidImageShape }
        guard tileSize > 0 else { throw ASHCoreError.invalidImageShape }
        guard scale > 0 else { throw ASHCoreError.invalidScale(scale) }
        guard topK > 0 else { throw ASHCoreError.invalidTopK(topK) }
        guard configuration.sceneCutMeanAbsoluteLumaThreshold.isFinite,
              configuration.sceneCutMeanAbsoluteLumaThreshold >= 0.0,
              configuration.sceneCutMeanAbsoluteLumaThreshold <= 1.0 else {
            throw ASHCoreError.invalidFeatureVector
        }
        guard configuration.provenance.scoringSpecificationVersion
                == configuration.scoringPolicy.specificationVersion else {
            throw ASHReconstructionError.inconsistentRuntimeConfiguration
        }

        let tiles = makeTiles(width: luma.width, height: luma.height)
        let outputWidth = luma.width * scale
        let outputHeight = luma.height * scale
        var processingState = ASHTileProcessingState(outputWidth: outputWidth, outputHeight: outputHeight)

        for tile in tiles {
            try Task.checkCancellation()
            let context = try makeTileContext(tile: tile, luma: luma, chroma: chroma, previous: previous)
            try processingState.record(tile: tile, context: context, scale: scale, topK: topK)
        }

        let reconstruction = try ASHImage(
            width: outputWidth,
            height: outputHeight,
            channels: 1,
            values: processingState.stitchedValues
        )
        return ASHTileProcessingResult(
            reconstruction: reconstruction,
            decisions: processingState.decisions,
            summary: processingState.summary(
                tileCount: tiles.count,
                chromaFeatureEnabled: chroma != nil,
                configuration: configuration
            ),
            temporalState: processingState.temporalState
        )
    }

    private func makeTileContext(
        tile: ASHTileDescriptor,
        luma: ASHImage,
        chroma: ASHChromaPlane?,
        previous: ASHTileTemporalState?
    ) throws -> ASHTileContext {
        let currentTile = try luma.cropped(to: tile.sourceRect)
        let candidatePreviousTile = previous?.sourceTiles[tile.id]?.matchingShape(currentTile)
        let candidatePreviousState = previous?.sourceStates[tile.id]
        let historyResetReason = determineHistoryResetReason(
            current: currentTile,
            previous: candidatePreviousTile,
            previousState: candidatePreviousState,
            hasPreviousFrame: previous != nil
        )
        let previousTile = historyResetReason == nil ? candidatePreviousTile : nil
        let previousState = historyResetReason == nil ? candidatePreviousState : nil
        let previousReconstruction = historyResetReason == nil
            ? previous?.reconstructions[tile.id]?.matchingReconstructionShape(of: currentTile, scale: scale)
            : nil
        let mapping = try ASHReferencePipeline.mapPatch(
            current: currentTile,
            previous: previousTile,
            previousState: previousState,
            previousReconstruction: previousReconstruction,
            chromaEnergy: chroma?.energy(inLumaRect: tile.sourceRect),
            scale: scale,
            topK: topK,
            candidateRetention: .selectedOnly,
            scoringPolicy: configuration.scoringPolicy
        )
        guard let selected = mapping.selected.first else {
            throw UpscalerEngineError.strategyFailed("ASH tile reconstruction produced no selected candidate")
        }
        return ASHTileContext(
            currentTile: currentTile,
            mapping: mapping,
            selected: selected,
            historyResetReason: historyResetReason
        )
    }

    private func determineHistoryResetReason(
        current: ASHImage,
        previous: ASHImage?,
        previousState: ASHState?,
        hasPreviousFrame: Bool
    ) -> ASHHistoryResetReason? {
        guard let previous else {
            return hasPreviousFrame ? .missingPriorTile : .noPriorFrame
        }
        guard let previousState else {
            return .missingPriorState
        }
        guard previousState.hasValidIntegrity else {
            return .invalidPriorState
        }

        let totalDifference = zip(current.values, previous.values).reduce(0.0) { partial, pair in
            partial + abs(pair.0 - pair.1)
        }
        let meanDifference = totalDifference / Double(current.values.count)
        return meanDifference >= configuration.sceneCutMeanAbsoluteLumaThreshold ? .sceneCut : nil
    }

    private func makeTiles(width: Int, height: Int) -> [ASHTileDescriptor] {
        var tiles: [ASHTileDescriptor] = []
        var id = 0
        var originY = 0
        while originY < height {
            var originX = 0
            while originX < width {
                tiles.append(ASHTileDescriptor(
                    id: id,
                    sourceRect: ASHIntRect(
                        originX: originX,
                        originY: originY,
                        width: min(tileSize, width - originX),
                        height: min(tileSize, height - originY)
                    )
                ))
                id += 1
                originX += tileSize
            }
            originY += tileSize
        }
        return tiles
    }

}

private extension ASHImage {
    func cropped(to rect: ASHIntRect) throws -> ASHImage {
        guard rect.originX >= 0,
              rect.originY >= 0,
              rect.width > 0,
              rect.height > 0,
              rect.originX + rect.width <= width,
              rect.originY + rect.height <= height else {
            throw ASHCoreError.invalidImageShape
        }
        var croppedValues: [Double] = []
        croppedValues.reserveCapacity(rect.width * rect.height * channels)
        for row in rect.originY..<(rect.originY + rect.height) {
            for column in rect.originX..<(rect.originX + rect.width) {
                for channel in 0..<channels {
                    croppedValues.append(value(row: row, column: column, channel: channel))
                }
            }
        }
        return try ASHImage(width: rect.width, height: rect.height, channels: channels, values: croppedValues)
    }

    func matchingShape(_ other: ASHImage) -> ASHImage? {
        guard width == other.width, height == other.height, channels == other.channels else {
            return nil
        }
        return self
    }

    func matchingReconstructionShape(of source: ASHImage, scale: Int) -> ASHImage? {
        guard width == source.width * scale,
              height == source.height * scale,
              channels == source.channels else {
            return nil
        }
        return self
    }
}
