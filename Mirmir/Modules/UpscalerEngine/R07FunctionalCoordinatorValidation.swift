enum R07FunctionalCoordinatorValidation {
    static func validateInput(
        _ input: R07FunctionalCoordinatorInput
    ) throws -> UInt64 {
        guard input.nextBaseContext.shotID == input.completedDecision.shotID else {
            throw R07FunctionalCoordinatorError.shotIdentityMismatch(
                expected: input.completedDecision.shotID,
                actual: input.nextBaseContext.shotID
            )
        }
        let target = input.completedDecision.decisionOrdinal.addingReportingOverflow(1)
        guard !target.overflow else {
            throw R07FunctionalCoordinatorError.targetDecisionOrdinalOverflow(
                input.completedDecision.decisionOrdinal
            )
        }
        guard input.targetDecisionOrdinal == target.partialValue else {
            throw R07FunctionalCoordinatorError.targetDecisionOrdinalMismatch(
                expected: target.partialValue,
                actual: input.targetDecisionOrdinal
            )
        }
        guard input.completedDecision.decisionOrdinal <= UInt64(Int64.max),
              target.partialValue <= UInt64(Int64.max) else {
            throw R07FunctionalCoordinatorError
                .decisionOrdinalOutsideTemporalDomain(
                    input.completedDecision.decisionOrdinal
                )
        }
        let expectedTemporalOrdinal = Int64(input.completedDecision.decisionOrdinal)
        guard input.temporalInput.currentFrameOrdinal == expectedTemporalOrdinal else {
            throw R07FunctionalCoordinatorError.temporalDecisionOrdinalMismatch(
                expected: expectedTemporalOrdinal,
                actual: input.temporalInput.currentFrameOrdinal
            )
        }
        try validateFull(input.temporalInput.currentLumaQ16, role: "current_luma_q16")
        try validateFull(input.sourceChromaCbQ16, role: "source_chroma_cb_q16")
        try validateFull(input.sourceChromaCrQ16, role: "source_chroma_cr_q16")
        for region in input.lowResolutionProtectedRegions {
            try validateLowMask(region.samplesQ15)
        }
        return target.partialValue
    }

    static func requireLuma(
        _ execution: R07FunctionalSupportExecution
    ) throws -> [Int64] {
        guard case .denoisedLumaQ16(let values) = execution.payload else {
            throw R07FunctionalCoordinatorError.supportExecutionPayloadMismatch(
                .temporalNoiseFilter
            )
        }
        return try validateOutput(
            values,
            capability: .temporalNoiseFilter,
            maximum: R06ASHQ16.scale
        )
    }

    static func requireChroma(
        _ execution: R07FunctionalSupportExecution
    ) throws -> (cb: [Int64], cr: [Int64]) {
        guard case .reconstructedChromaQ16(let cb, let cr) = execution.payload else {
            throw R07FunctionalCoordinatorError.supportExecutionPayloadMismatch(
                .mpsGuidedFilter
            )
        }
        return (
            try validateOutput(
                cb,
                capability: .mpsGuidedFilter,
                maximum: R06ASHQ16.scale
            ),
            try validateOutput(
                cr,
                capability: .mpsGuidedFilter,
                maximum: R06ASHQ16.scale
            )
        )
    }

    static func requireProtectionMask(
        _ execution: R07FunctionalSupportExecution
    ) throws -> [Int64] {
        guard case .upsampledProtectionMaskQ15(let values) = execution.payload else {
            throw R07FunctionalCoordinatorError.supportExecutionPayloadMismatch(
                .coreImageEdgePreserve
            )
        }
        return try validateOutput(
            values,
            capability: .coreImageEdgePreserve,
            maximum: R06ASHQ15.maximum
        )
    }
}

private extension R07FunctionalCoordinatorValidation {
    static func validateOutput(
        _ values: [Int64],
        capability: R07SupportCapabilityID,
        maximum: Int64
    ) throws -> [Int64] {
        guard values.count == R07FunctionalSupportGeometry.fullSampleCount else {
            throw R07FunctionalCoordinatorError.invalidFullResolutionSampleCount(
                role: "\(capability.rawValue).output",
                actual: values.count
            )
        }
        if let invalid = values.enumerated().first(where: {
            !(0...maximum).contains($0.element)
        }) {
            throw R07FunctionalCoordinatorError.supportOutputSampleOutOfRange(
                capability: capability,
                index: invalid.offset,
                value: invalid.element
            )
        }
        return values
    }

    static func validateFull(_ values: [Int64], role: String) throws {
        guard values.count == R07FunctionalSupportGeometry.fullSampleCount else {
            throw R07FunctionalCoordinatorError.invalidFullResolutionSampleCount(
                role: role,
                actual: values.count
            )
        }
        try validateDomain(values, role: role, maximum: R06ASHQ16.scale)
    }

    static func validateLowMask(_ values: [Int64]) throws {
        guard values.count == R07FunctionalSupportGeometry.lowSampleCount else {
            throw R07FunctionalCoordinatorError.invalidLowResolutionSampleCount(
                role: "low_resolution_protection_mask_q15",
                actual: values.count
            )
        }
        try validateDomain(
            values,
            role: "low_resolution_protection_mask_q15",
            maximum: R06ASHQ15.maximum
        )
    }

    static func validateDomain(
        _ values: [Int64],
        role: String,
        maximum: Int64
    ) throws {
        if let invalid = values.enumerated().first(where: {
            !(0...maximum).contains($0.element)
        }) {
            throw R07FunctionalCoordinatorError.inputSampleOutOfRange(
                role: role,
                index: invalid.offset,
                value: invalid.element
            )
        }
    }
}
