import CoreVideo
import XCTest
@testable import Mirmir

final class R03GuidedSupportStagesTests: XCTestCase {
    func testContractsFreezeExactShapesRolesAndParameters() throws {
        let guided = R03SupportStageContract.mpsGuidedFilter
        XCTAssertEqual(guided.subjectID, .mpsGuidedFilter)
        XCTAssertEqual(guided.routeID, .guidedSupport1x)
        assertImageContract(guided.source, format: kCVPixelFormatType_OneComponent8, 64, 64)
        assertImageContract(guided.guidance, format: kCVPixelFormatType_OneComponent8, 64, 64)
        assertImageContract(guided.output, format: kCVPixelFormatType_OneComponent8, 64, 64)
        XCTAssertTrue(guided.configurationIdentity.contains("r8-to-rgba8-rgba16f"))
        XCTAssertEqual(R03SupportStageParameters.guidedFilterKernelDiameter, 5)
        XCTAssertEqual(R03SupportStageParameters.guidedFilterEpsilon, 0.01)

        let edge = R03SupportStageContract.coreImageEdgePreserve
        XCTAssertEqual(edge.subjectID, .coreImageEdgePreserve)
        XCTAssertEqual(edge.routeID, .edgePreserveSupport2x)
        assertImageContract(edge.source, format: kCVPixelFormatType_OneComponent8, 32, 32)
        assertImageContract(edge.guidance, format: kCVPixelFormatType_OneComponent8, 64, 64)
        assertImageContract(edge.output, format: kCVPixelFormatType_OneComponent8, 64, 64)
        XCTAssertEqual(R03SupportStageParameters.edgePreserveSpatialSigma, 3)
        XCTAssertEqual(R03SupportStageParameters.edgePreserveLumaSigma, 0.15)

        for subjectID in [
            R03BaselineSubjectID.mpsGuidedFilter,
            .coreImageEdgePreserve
        ] {
            let subject = try XCTUnwrap(
                R03DeterministicBackendCatalog.subject(subjectID)
            )
            XCTAssertEqual(subject.kind, .supportStage)
            XCTAssertEqual(subject.productDefaultEligibility, .ineligibleSupportStage)
            XCTAssertEqual(subject.capabilityRole, .supportFilter)
        }
    }

    func testSupportAdmissionIsTypedAndFixtureOnly() throws {
        let productContext = try makeContext(
            subjectID: .mpsGuidedFilter,
            admissionScope: .product
        )
        let productOutcome = try R03SupportStageFactory.makeMPSGuidedFilter(
            context: productContext
        )
        guard case .rejected(let rejection) = productOutcome else {
            return XCTFail("Product admission must reject a support-only stage")
        }
        XCTAssertEqual(
            rejection.processingIdentity.route.backend.backendID,
            R03BaselineSubjectID.mpsGuidedFilter.rawValue
        )
        XCTAssertTrue(rejection.processingIdentity.fallbackHistory.isEmpty)

        let notObserved = try R03DeterministicBackendCatalog
            .makeNotObservedCapability(for: .mpsGuidedFilter)
        let unavailableContext = try makeContext(
            subjectID: .mpsGuidedFilter,
            capability: notObserved
        )
        let unavailableOutcome = try R03SupportStageFactory.makeMPSGuidedFilter(
            context: unavailableContext
        )
        guard case .unavailable(let unavailable) = unavailableOutcome else {
            return XCTFail("Not-observed support must produce typed unavailability")
        }
        XCTAssertEqual(
            unavailable.processingIdentity.route.backend.backendID,
            R03BaselineSubjectID.mpsGuidedFilter.rawValue
        )
        XCTAssertTrue(unavailable.processingIdentity.fallbackHistory.isEmpty)
    }

    func testMPSGuidedFilterRunsGenuineRepeatablePathWhenAvailable() throws {
        let context = try makeContext(
            subjectID: .mpsGuidedFilter
        )
        let creation = try R03SupportStageFactory.makeMPSGuidedFilter(
            context: context
        )
        guard case .created(let stage) = creation else {
            if case .unavailable(let unavailable) = creation {
                XCTAssertEqual(
                    unavailable.processingIdentity.route.backend.backendID,
                    R03BaselineSubjectID.mpsGuidedFilter.rawValue
                )
                return
            }
            return XCTFail("Expected created or typed-unavailable MPS support")
        }
        let input = try makeGuidedInput()

        let first = try process(stage: stage, input: input)
        let second = try process(stage: stage, input: input)
        XCTAssertEqual(first.bytes, second.bytes)
        XCTAssertEqual(first.bytes.count, 64 * 64)
        XCTAssertEqual(
            first.identity.route.backend.backendID,
            R03BaselineSubjectID.mpsGuidedFilter.rawValue
        )
        XCTAssertTrue(first.identity.fallbackHistory.isEmpty)

        let invalidSource = try makeLumaBuffer(width: 32, height: 32) { _, _ in 0 }
        let invalidOutcome = stage.process(
            R03SupportStageInput(
                source: invalidSource,
                guidance: input.guidance
            ),
            cancellation: AppleUpscaleOperationCancellationSignal()
        )
        guard case .rejected(let rejection) = invalidOutcome else {
            return XCTFail("Invalid guided-filter dimensions must reject")
        }
        XCTAssertEqual(
            rejection.reason,
            "r03_support_stage_input_contract_mismatch"
        )
    }

    func testCoreImageEdgePreserveRunsRepeatablyAndRejectsInvalidInput() throws {
        let context = try makeContext(
            subjectID: .coreImageEdgePreserve
        )
        let creation = try R03SupportStageFactory.makeCoreImageEdgePreserve(
            context: context
        )
        guard case .created(let stage) = creation else {
            return XCTFail("Core Image support stage creation must be typed-created")
        }
        let input = try makeEdgeInput()

        let first = try process(stage: stage, input: input)
        let second = try process(stage: stage, input: input)
        XCTAssertEqual(first.bytes, second.bytes)
        XCTAssertEqual(first.bytes.count, 64 * 64)
        XCTAssertEqual(
            first.identity.route.backend.backendID,
            R03BaselineSubjectID.coreImageEdgePreserve.rawValue
        )
        XCTAssertTrue(first.identity.fallbackHistory.isEmpty)

        let invalidGuidance = try makeLumaBuffer(width: 32, height: 32) { _, _ in 0 }
        let invalidOutcome = stage.process(
            R03SupportStageInput(
                source: input.source,
                guidance: invalidGuidance
            ),
            cancellation: AppleUpscaleOperationCancellationSignal()
        )
        guard case .rejected(let rejection) = invalidOutcome else {
            return XCTFail("Invalid edge-preserve guidance dimensions must reject")
        }
        XCTAssertEqual(
            rejection.reason,
            "r03_support_stage_input_contract_mismatch"
        )
    }

    private func assertImageContract(
        _ contract: R03SupportImageContract,
        format: OSType,
        _ width: Int,
        _ height: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(contract.pixelFormat, format, file: file, line: line)
        XCTAssertEqual(contract.width, width, file: file, line: line)
        XCTAssertEqual(contract.height, height, file: file, line: line)
    }

    private func makeGuidedInput() throws -> R03SupportStageInput {
        try R03SupportStageInput(
            source: makeLumaBuffer(width: 64, height: 64) { column, row in
                UInt8((column * 3 + row * 5) % 256)
            },
            guidance: makeLumaBuffer(width: 64, height: 64) { column, _ in
                column < 32 ? 24 : 224
            }
        )
    }

    private func makeEdgeInput() throws -> R03SupportStageInput {
        try R03SupportStageInput(
            source: makeLumaBuffer(width: 32, height: 32) { column, _ in
                column < 16 ? 32 : 208
            },
            guidance: makeLumaBuffer(width: 64, height: 64) { column, row in
                let edge: UInt8 = column < 32 ? 16 : 240
                return UInt8(clamping: Int(edge) + (row % 3))
            }
        )
    }

    private func process(
        stage: any R03SupportStage,
        input: R03SupportStageInput
    ) throws -> (bytes: Data, identity: AppleUpscaleProcessingIdentity) {
        let outcome = stage.process(
            input,
            cancellation: AppleUpscaleOperationCancellationSignal()
        )
        guard case .processed(let output) = outcome else {
            throw TestError.unexpectedOutcome
        }
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output.pixelBuffer), kCVPixelFormatType_OneComponent8)
        XCTAssertEqual(CVPixelBufferGetWidth(output.pixelBuffer), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(output.pixelBuffer), 64)
        return (
            try readLumaBuffer(output.pixelBuffer),
            output.processingIdentity
        )
    }

    private enum TestError: Error {
        case unexpectedOutcome
    }

    private func makeContext(
        subjectID: R03BaselineSubjectID,
        admissionScope: AppleUpscaleAdmissionScope = .fixtureOnly,
        capability: AppleUpscaleCapability? = nil
    ) throws -> AppleUpscaleSessionContext {
        let capability = try capability
            ?? R03DeterministicBackendCatalog.makeFixtureCapability(for: subjectID)
        return try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: admissionScope,
            policyIdentity: R03DeterministicBackendCatalog.policyIdentity
        )
    }

    private func makeLumaBuffer(
        width: Int,
        height: Int,
        value: (_ column: Int, _ row: Int) -> UInt8
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            attributes as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for column in 0..<width {
                base[row * rowBytes + column] = value(column, row)
            }
        }
        return buffer
    }

    private func readLumaBuffer(_ pixelBuffer: CVPixelBuffer) throws -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            .assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var data = Data(capacity: width * height)
        for row in 0..<height {
            data.append(base.advanced(by: row * rowBytes), count: width)
        }
        return data
    }
}
