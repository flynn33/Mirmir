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
}

struct ASHTileProcessingSummary: Equatable, Sendable {
    let tileCount: Int
    let selectedMessageHistogram: [ASHMessage: Int]
    let maxCandidatesPerTile: Int
    let estimatedPeakTemporaryBytes: Int
    let chromaFeatureEnabled: Bool
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

struct ASHTileProcessor: Sendable {
    let tileSize: Int
    let scale: Int
    let topK: Int

    init(
        tileSize: Int = 32,
        scale: Int = ASHReconstruction.defaultScale,
        topK: Int = ASHReconstruction.defaultTopK
    ) {
        self.tileSize = tileSize
        self.scale = scale
        self.topK = topK
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

        let tiles = makeTiles(width: luma.width, height: luma.height)
        let outputWidth = luma.width * scale
        let outputHeight = luma.height * scale
        var stitchedValues = Array(repeating: 0.0, count: outputWidth * outputHeight)
        var decisions: [ASHTileDecision] = []
        var sourceTiles: [Int: ASHImage] = [:]
        var sourceStates: [Int: ASHState] = [:]
        var reconstructions: [Int: ASHImage] = [:]
        var histogram: [ASHMessage: Int] = [:]
        var maxCandidates = 0
        var estimatedPeakTemporaryBytes = 0

        for tile in tiles {
            let currentTile = try luma.cropped(to: tile.sourceRect)
            let previousTile = previous?.sourceTiles[tile.id]?.matchingShape(currentTile)
            let previousState = previousTile == nil ? nil : previous?.sourceStates[tile.id]
            let previousReconstruction = previousTile == nil ? nil : previous?.reconstructions[tile.id]
            let mapping = try ASHReferencePipeline.mapPatch(
                current: currentTile,
                previous: previousTile,
                previousState: previousState,
                previousReconstruction: previousReconstruction,
                chromaEnergy: chroma?.energy(inLumaRect: tile.sourceRect),
                scale: scale,
                topK: topK
            )
            guard let selected = mapping.selected.first else {
                throw UpscalerEngineError.strategyFailed("ASH tile reconstruction produced no selected candidate")
            }

            let outputRect = tile.outputRect(scale: scale)
            try stitch(selected.reconstruction, into: &stitchedValues, outputWidth: outputWidth, outputRect: outputRect)
            decisions.append(ASHTileDecision(
                tile: tile,
                features: mapping.features,
                sourceState: mapping.sourceState,
                selectedMessage: selected.message,
                selectedScore: selected.totalScore
            ))
            sourceTiles[tile.id] = currentTile
            sourceStates[tile.id] = mapping.sourceState
            reconstructions[tile.id] = selected.reconstruction
            histogram[selected.message, default: 0] += 1
            maxCandidates = max(maxCandidates, mapping.candidates.count)
            estimatedPeakTemporaryBytes = max(
                estimatedPeakTemporaryBytes,
                mapping.candidates.count * selected.reconstruction.values.count * MemoryLayout<Double>.stride
            )
        }

        let reconstruction = try ASHImage(
            width: outputWidth,
            height: outputHeight,
            channels: 1,
            values: stitchedValues
        )
        return ASHTileProcessingResult(
            reconstruction: reconstruction,
            decisions: decisions,
            summary: ASHTileProcessingSummary(
                tileCount: tiles.count,
                selectedMessageHistogram: histogram,
                maxCandidatesPerTile: maxCandidates,
                estimatedPeakTemporaryBytes: estimatedPeakTemporaryBytes,
                chromaFeatureEnabled: chroma != nil
            ),
            temporalState: ASHTileTemporalState(
                sourceTiles: sourceTiles,
                sourceStates: sourceStates,
                reconstructions: reconstructions
            )
        )
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

    private func stitch(
        _ reconstruction: ASHImage,
        into output: inout [Double],
        outputWidth: Int,
        outputRect: ASHIntRect
    ) throws {
        guard reconstruction.channels == 1,
              reconstruction.width == outputRect.width,
              reconstruction.height == outputRect.height else {
            throw ASHCoreError.invalidCandidateShape
        }
        for localRow in 0..<outputRect.height {
            let outputRow = outputRect.originY + localRow
            for localColumn in 0..<outputRect.width {
                let outputColumn = outputRect.originX + localColumn
                output[(outputRow * outputWidth) + outputColumn] = reconstruction.value(
                    row: localRow,
                    column: localColumn
                )
            }
        }
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
}
