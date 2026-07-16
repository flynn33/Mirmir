import Foundation

extension ASHLockedReferencePipelineV2 {
    static func prepareNonASHOutputCache(
        _ input: ASHLockedNonASHCacheInputV2
    ) throws -> ASHLockedNonASHOutputCacheV2 {
        try validateNonASHCacheInput(input)
        let outputLumaWidth = try input.route.destinationExtent(for: input.luma.width)
        let outputLumaHeight = try input.route.destinationExtent(for: input.luma.height)
        let outputChromaWidth = try input.route.destinationExtent(for: input.cb.width)
        let outputChromaHeight = try input.route.destinationExtent(for: input.cb.height)
        let selection = input.configuration.routeSelection(for: input.route)
        let analysisGrid = try ASHAnalysisGridBuilderV2.build(
            luma: input.luma,
            cb: input.cb,
            cr: input.cr,
            chromaSiting: input.chromaSiting,
            step: Int(selection.analysisGridSourceStep),
            boundary: input.configuration.boundaryMode,
            configuration: input.mapping.analyzerConfiguration
        )
        var cellFeatures: [Int16] = []
        cellFeatures.reserveCapacity(
            analysisGrid.count * ASHLockedControlRuntimeV2.nonASHCellFeatureOrder.count
        )
        for cell in analysisGrid.cells {
            cellFeatures.append(
                contentsOf: ASHLockedControlRuntimeV2.nonASHCellFeatureValuesQ15(
                    cell.analysis.sidecar
                )
            )
        }
        var phaseFeatures: [Int16] = []
        phaseFeatures.reserveCapacity(
            input.route.phasePairCount
                * ASHLockedControlRuntimeV2.nonASHPhaseFeatureOrder.count
        )
        for phaseOrdinal in 0..<input.route.phasePairCount {
            phaseFeatures.append(
                contentsOf: try ASHLockedControlRuntimeV2.nonASHPhaseFeatureValuesQ15(
                    phaseOrdinal: phaseOrdinal,
                    route: input.route,
                    selection: selection,
                    sourceWidth: analysisGrid.sourceWidth,
                    sourceHeight: analysisGrid.sourceHeight
                )
            )
        }

        let lumaPlane = try makePlane(input.luma, channel: .luma)
        let cbPlane = try makePlane(input.cb, channel: .chroma)
        let crPlane = try makePlane(input.cr, channel: .chroma)
        let lumaIndexes = try nonASHFeatureIndexes(
            route: input.route,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            plane: lumaPlane,
            chromaSiting: nil
        )
        let chromaIndexes = try nonASHFeatureIndexes(
            route: input.route,
            configuration: input.configuration,
            analysisGrid: analysisGrid,
            plane: cbPlane,
            chromaSiting: input.chromaSiting
        )

        let expectedOutputByteCount = outputLumaWidth * outputLumaHeight
            + (2 * outputChromaWidth * outputChromaHeight)
        let descriptorOutputTable = try makeNonASHDescriptorOutputTable(
            input: input,
            analysisGrid: analysisGrid,
            lumaPlane: lumaPlane,
            cbPlane: cbPlane,
            crPlane: crPlane,
            expectedOutputByteCount: expectedOutputByteCount
        )
        return ASHLockedNonASHOutputCacheV2(
            route: input.route,
            configurationID: input.configuration.configurationID,
            sharedBankConfigurationSHA256: input.mapping.sharedBankConfigurationSHA256,
            inputFrameSHA256: input.inputFrameSHA256,
            inputLumaWidth: input.luma.width,
            inputLumaHeight: input.luma.height,
            inputChromaWidth: input.cb.width,
            inputChromaHeight: input.cb.height,
            outputLumaWidth: outputLumaWidth,
            outputLumaHeight: outputLumaHeight,
            outputChromaWidth: outputChromaWidth,
            outputChromaHeight: outputChromaHeight,
            analysisGridSourceStep: analysisGrid.step,
            analysisCellCount: analysisGrid.count,
            cellFeatureValuesQ15: cellFeatures,
            phaseFeatureValuesQ15: phaseFeatures,
            lumaFeatureIndexes: lumaIndexes,
            chromaFeatureIndexes: chromaIndexes,
            descriptorOutputByteCount: expectedOutputByteCount,
            descriptorOutputTableNV12: descriptorOutputTable,
            analysisGridInvocationCount: 1,
            statefulLUTLookupCount: 0,
            descriptorPrecomputeCount: ASHSpatialDescriptorV2.count
        )
    }

    private static func makeNonASHDescriptorOutputTable(
        input: ASHLockedNonASHCacheInputV2,
        analysisGrid: ASHAnalysisGridV2,
        lumaPlane: ASHSpatialPlaneV2,
        cbPlane: ASHSpatialPlaneV2,
        crPlane: ASHSpatialPlaneV2,
        expectedOutputByteCount: Int
    ) throws -> Data {
        var descriptorOutputTable = Data()
        descriptorOutputTable.reserveCapacity(
            expectedOutputByteCount * ASHSpatialDescriptorV2.count
        )
        for descriptor in 0..<ASHSpatialDescriptorV2.count {
            let dispatchGrid = try ASHLockedControlRuntimeV2.makeDispatchGrid(
                route: input.route,
                configuration: input.configuration,
                analysisGrid: analysisGrid,
                mode: .fixedDescriptor(UInt8(descriptor))
            )
            let luma = try reconstruct(
                plane: lumaPlane,
                dispatchGrid: dispatchGrid,
                configuration: input.configuration,
                analysisGrid: analysisGrid,
                chromaSiting: nil
            )
            let cb = try reconstruct(
                plane: cbPlane,
                dispatchGrid: dispatchGrid,
                configuration: input.configuration,
                analysisGrid: analysisGrid,
                chromaSiting: input.chromaSiting
            )
            let cr = try reconstruct(
                plane: crPlane,
                dispatchGrid: dispatchGrid,
                configuration: input.configuration,
                analysisGrid: analysisGrid,
                chromaSiting: input.chromaSiting
            )
            let payload = try ASHLockedNonASHOutputCacheV2.encodeCommonNV12(
                ASHLockedControlFrameV2(
                    luma: luma.output,
                    cb: cb.output,
                    cr: cr.output
                )
            )
            guard payload.count == expectedOutputByteCount else {
                throw ASHLockedNonASHOutputCacheV2Error.invalidDescriptorOutput
            }
            descriptorOutputTable.append(payload)
        }
        return descriptorOutputTable
    }

    private static func validateNonASHCacheInput(
        _ input: ASHLockedNonASHCacheInputV2
    ) throws {
        guard input.mapping.sha256 == input.configuration.mappingSHA256 else {
            throw ASHLockedReferencePipelineV2Error.mappingHashMismatch
        }
        do {
            try input.mapping.validate(configuration: input.configuration)
        } catch {
            throw ASHLockedReferencePipelineV2Error.mappingConfigurationMismatch
        }
        guard input.chromaSiting == input.mapping.chromaSiting else {
            throw ASHLockedReferencePipelineV2Error.chromaSitingMismatch
        }
        guard input.cb.width == input.cr.width,
              input.cb.height == input.cr.height else {
            throw ASHLockedReferencePipelineV2Error.mismatchedChromaGeometry
        }
        guard input.luma.range == input.cb.range,
              input.cb.range == input.cr.range else {
            throw ASHLockedReferencePipelineV2Error.mismatchedPlaneRange
        }
        guard input.luma.width == input.cb.width * 2,
              input.luma.height == input.cb.height * 2 else {
            throw ASHLockedReferencePipelineV2Error.unsupportedChromaSubsampling
        }
    }

    private static func nonASHFeatureIndexes(
        route: ASHSpatialRouteV2,
        configuration: ASHLUTLockedConfigurationV2,
        analysisGrid: ASHAnalysisGridV2,
        plane: ASHSpatialPlaneV2,
        chromaSiting: ASHChromaSitingV2?
    ) throws -> [Int32] {
        let outputWidth = try route.destinationExtent(for: plane.width)
        let outputHeight = try route.destinationExtent(for: plane.height)
        var indexes: [Int32] = []
        indexes.reserveCapacity(outputWidth * outputHeight)
        for row in 0..<outputHeight {
            for column in 0..<outputWidth {
                if indexes.count.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                let index = try ASHLockedRuntimeV2.nonASHFeatureIndex(
                    route: route,
                    configuration: configuration,
                    analysisGrid: analysisGrid,
                    plane: plane,
                    destinationColumn: column,
                    destinationRow: row,
                    chromaSiting: chromaSiting
                )
                guard let exact = Int32(exactly: index) else {
                    throw ASHLockedNonASHOutputCacheV2Error.invalidSelectorIndex
                }
                indexes.append(exact)
            }
        }
        return indexes
    }
}
