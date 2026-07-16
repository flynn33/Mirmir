import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Mirmir

final class ASHCorrectiveCLITests: XCTestCase {
    struct Fixture {
        let configuration: ASHLUTLockedConfigurationV2
        let mapping: ASHLockedVideoMappingV2
        let operatorBank: ASHLockedOperatorBankV2
        let manifest: ASHLockedCandidateLUTManifestV1
        let routeData: [ASHSpatialRouteV2: Data]
        let routeLUTs: [ASHSpatialRouteV2: ASHLUTLoadedV2]
        let planes: ASHLockedRuntimeTestSupportV2.Planes
        let inputData: Data
        let coordinateContractData: Data
    }

    struct RequestBundle {
        let document: [String: Any]
        let request: ASHCalibrationCorrectiveDiagnosticRequest
        let outputPaths: [String]
    }

    enum InjectedFailure: Error {
        case lateReopen
    }

    static let fixtureResult: Result<Fixture, Error> = Result {
        try makeFixture()
    }

    var temporaryRoot: URL!
    var inputPath: String!
    var contractPath: String!

    override func setUpWithError() throws {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolvedPath = realpath(temporaryPath, nil) else {
            throw ASHCalibrationCLIError.unsafePath(temporaryPath)
        }
        defer { free(resolvedPath) }
        let base = URL(
            fileURLWithPath: String(cString: resolvedPath),
            isDirectory: true
        )
        temporaryRoot = base.appendingPathComponent(
            "mirmir-corrective-cli-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        let fixture = try Self.fixtureResult.get()
        let inputURL = temporaryRoot.appendingPathComponent("input.nv12")
        let contractURL = temporaryRoot.appendingPathComponent("coordinate.json")
        try fixture.inputData.write(to: inputURL, options: .withoutOverwriting)
        try fixture.coordinateContractData.write(
            to: contractURL,
            options: .withoutOverwriting
        )
        inputPath = inputURL.path
        contractPath = contractURL.path
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        inputPath = nil
        contractPath = nil
    }

    func test_requestParserRejectsIdentityOrderAndPathTampering() throws {
        let fixture = try Self.fixtureResult.get()
        let valid = try requestBundle(
            fixture: fixture,
            route: .direct2x,
            suffix: "strict"
        )
        XCTAssertEqual(valid.request.outputDescriptors.count, 16)
        XCTAssertEqual(valid.request.frame.outputPath, valid.outputPaths.last)

        var noncanonical = try canonicalData(valid.document)
        noncanonical.append(0x20)
        XCTAssertThrowsError(try ASHCalibrationCorrectiveDiagnosticRequest.parse(
            noncanonical,
            configuration: fixture.configuration
        ))

        var wrongConfiguration = valid.document
        wrongConfiguration["configuration_id"] = "substituted"
        try assertParseRejects(wrongConfiguration, fixture: fixture)

        var wrongOrder = valid.document
        var descriptors = try XCTUnwrap(
            wrongOrder["output_descriptors"] as? [[String: Any]]
        )
        descriptors.swapAt(0, 1)
        wrongOrder["output_descriptors"] = descriptors
        try assertParseRejects(wrongOrder, fixture: fixture)

        var wrongCell = valid.document
        descriptors = try XCTUnwrap(
            wrongCell["output_descriptors"] as? [[String: Any]]
        )
        descriptors[0]["coordinate_cell_id"] = "SS"
        wrongCell["output_descriptors"] = descriptors
        try assertParseRejects(wrongCell, fixture: fixture)

        var duplicatePath = valid.document
        descriptors = try XCTUnwrap(
            duplicatePath["output_descriptors"] as? [[String: Any]]
        )
        descriptors[1]["output_path"] = descriptors[0]["output_path"]
        duplicatePath["output_descriptors"] = descriptors
        try assertParseRejects(duplicatePath, fixture: fixture)

        var unsafePath = valid.document
        descriptors = try XCTUnwrap(
            unsafePath["output_descriptors"] as? [[String: Any]]
        )
        descriptors[0]["output_path"] = "/tmp/../unsafe.nv12"
        unsafePath["output_descriptors"] = descriptors
        try assertParseRejects(unsafePath, fixture: fixture)

        var productionMismatch = valid.document
        productionMismatch["production_v2_reference_output_path"] =
            temporaryRoot.appendingPathComponent("substituted.nv12").path
        try assertParseRejects(productionMismatch, fixture: fixture)

        var stepMismatch = valid.document
        stepMismatch["analysis_grid_source_step"] = 4
        try assertParseRejects(stepMismatch, fixture: fixture)
    }

    func test_inputAndCoordinateContractHashTamperingLeavesNoOutputs() throws {
        let fixture = try Self.fixtureResult.get()
        let session = try makeSession(fixture)

        var inputTamper = try requestDocument(
            fixture: fixture,
            route: .direct2x,
            suffix: "input-hash"
        )
        var frame = try XCTUnwrap(inputTamper["frame"] as? [String: Any])
        frame["input_sha256"] = String(repeating: "f", count: 64)
        inputTamper["frame"] = frame
        let inputRequest = try ASHCalibrationCorrectiveDiagnosticRequest.parse(
            canonicalData(inputTamper),
            configuration: fixture.configuration
        )
        XCTAssertThrowsError(try session.diagnoseCorrective(inputRequest))
        try assertNoRequestedOutputs(inputTamper)

        var contractTamper = try requestDocument(
            fixture: fixture,
            route: .direct2x,
            suffix: "contract-hash"
        )
        contractTamper["coordinate_model_contract_sha256"] = String(
            repeating: "a",
            count: 64
        )
        let contractRequest = try ASHCalibrationCorrectiveDiagnosticRequest.parse(
            canonicalData(contractTamper),
            configuration: fixture.configuration
        )
        XCTAssertThrowsError(try session.diagnoseCorrective(contractRequest))
        try assertNoRequestedOutputs(contractTamper)
        XCTAssertEqual(session.correctiveGenericCompilationCount(for: .direct2x), 0)
    }

    func test_sessionProducesExactEvidenceParityAndCompilesOncePerRoute() throws {
        let fixture = try Self.fixtureResult.get()
        let session = try makeSession(fixture)
        let first = try requestBundle(
            fixture: fixture,
            route: .direct2x,
            suffix: "direct2-first"
        )
        let firstResponse = try session.diagnoseCorrective(first.request)
        try assertResponse(
            firstResponse,
            request: first.request,
            fixture: fixture,
            route: .direct2x
        )
        try assertProductionParity(
            response: firstResponse,
            request: first.request,
            fixture: fixture
        )
        try assertNormalizedAnisotropyIndependence(firstResponse)
        XCTAssertEqual(session.correctiveGenericCompilationCount(for: .direct2x), 1)
        XCTAssertEqual(session.correctiveGenericCompilationCount(for: .direct3Over2), 0)

        let second = try requestBundle(
            fixture: fixture,
            route: .direct2x,
            suffix: "direct2-second"
        )
        let secondResponse = try session.diagnoseCorrective(second.request)
        try assertResponse(
            secondResponse,
            request: second.request,
            fixture: fixture,
            route: .direct2x
        )
        XCTAssertEqual(session.correctiveGenericCompilationCount(for: .direct2x), 1)

        let direct3 = try requestBundle(
            fixture: fixture,
            route: .direct3Over2,
            suffix: "direct3"
        )
        let direct3Response = try session.diagnoseCorrective(direct3.request)
        try assertResponse(
            direct3Response,
            request: direct3.request,
            fixture: fixture,
            route: .direct3Over2
        )
        try assertProductionParity(
            response: direct3Response,
            request: direct3.request,
            fixture: fixture
        )
        XCTAssertEqual(session.correctiveGenericCompilationCount(for: .direct2x), 1)
        XCTAssertEqual(session.correctiveGenericCompilationCount(for: .direct3Over2), 1)
    }

    func test_genericSerializationRebindIsStrictAndSemanticsPreserving() throws {
        let fixture = try Self.fixtureResult.get()
        let session = try makeSession(fixture)
        let route = ASHSpatialRouteV2.direct3Over2
        let original = fixture.configuration
        let transformed = try session.correctiveDiagnosticContainerConfiguration(
            for: route
        )
        assertOnlySelectedRouteCoordinatePoliciesChanged(
            original: original,
            transformed: transformed,
            route: route
        )

        let compilation = try session.correctiveGenericDiagnosticCompilation(
            for: route
        )
        let rebound = session.correctiveDiagnosticContainerEntries(
            compilation.entries
        )
        XCTAssertTrue(zip(compilation.entries, rebound).allSatisfy { source, serialized in
            source.logicalIndex == serialized.logicalIndex
                && source.sourceState == serialized.sourceState
                && source.validStateOrdinal == serialized.validStateOrdinal
                && source.phaseOrdinal == serialized.phaseOrdinal
                && source.context == serialized.context
                && source.primary == serialized.primary
                && source.secondary == serialized.secondary
                && source.primaryWeightUNorm16 == serialized.primaryWeightUNorm16
                && source.secondaryWeightUNorm16 == serialized.secondaryWeightUNorm16
                && source.marginUNorm16 == serialized.marginUNorm16
                && source.sourceAlignedExact == serialized.sourceAlignedExact
                && source.temporalForcedSpatial == serialized.temporalForcedSpatial
                && source.parameters.primary == serialized.parameters.primary
                && source.parameters.secondary == serialized.parameters.secondary
                && source.parameters.confidenceThresholdUNorm16
                    == serialized.parameters.confidenceThresholdUNorm16
                && source.parameters.boundaryMode == serialized.parameters.boundaryMode
                && serialized.parameters.lumaCoordinatePolicy == .halfPixelCenter
                && serialized.parameters.chromaCoordinatePolicy == .halfPixelCenter
        })

        let artifact = try session.correctiveGenericDiagnosticArtifact(for: route)
        XCTAssertThrowsError(try ASHLUTBinaryCodecV2.load(
            artifact,
            expectedRoute: route,
            configuration: original
        )) { error in
            XCTAssertEqual(error as? ASHLUTBinaryErrorV2, .inputHashMismatch)
        }
        let loaded = try ASHLUTBinaryCodecV2.load(
            artifact,
            expectedRoute: route,
            configuration: transformed
        )
        XCTAssertEqual(loaded.configuration, transformed)
        XCTAssertEqual(
            try session.correctiveGenericDiagnosticConfiguration(for: route),
            transformed
        )
        XCTAssertEqual(loaded.immutableBytes, artifact)
        XCTAssertEqual(loaded.entries.count, rebound.count)
        XCTAssertTrue(zip(loaded.entries, rebound).allSatisfy { loadedEntry, source in
            let index = Int(loadedEntry.parameterIndex)
            guard loaded.parameters.indices.contains(index) else { return false }
            var flags = ASHLUTBinaryContractV2.entryPrimaryExactVerified
            if source.sourceAlignedExact {
                flags |= ASHLUTBinaryContractV2.entrySourceAlignedExact
            }
            if source.temporalForcedSpatial {
                flags |= ASHLUTBinaryContractV2.entryTemporalForcedSpatial
            }
            if source.secondary != nil {
                flags |= ASHLUTBinaryContractV2.entryHasSecondary
                    | ASHLUTBinaryContractV2.entrySecondaryExactVerified
            }
            return loadedEntry.primaryAffineState == source.primary.affineState
                && loadedEntry.secondaryAffineState == source.secondary?.affineState
                && loadedEntry.primaryDescriptorID == source.primary.descriptorID
                && loadedEntry.secondaryDescriptorID == source.secondary?.descriptorID
                && loadedEntry.primaryMessage == source.primary.message
                && loadedEntry.secondaryMessage == source.secondary?.message
                && loadedEntry.primaryWeightUNorm16 == source.primaryWeightUNorm16
                && loadedEntry.secondaryWeightUNorm16 == source.secondaryWeightUNorm16
                && loadedEntry.marginUNorm16 == source.marginUNorm16
                && loadedEntry.flags == flags
                && loaded.parameters[index] == source.parameters
        })
    }

    private func assertOnlySelectedRouteCoordinatePoliciesChanged(
        original: ASHLUTLockedConfigurationV2,
        transformed: ASHLUTLockedConfigurationV2,
        route: ASHSpatialRouteV2
    ) {
        XCTAssertEqual(transformed.configurationID, original.configurationID)
        XCTAssertEqual(transformed.mappingSHA256, original.mappingSHA256)
        XCTAssertEqual(transformed.operatorBankSHA256, original.operatorBankSHA256)
        XCTAssertEqual(transformed.metricPolicySHA256, original.metricPolicySHA256)
        XCTAssertEqual(transformed.compilerInputsSHA256, original.compilerInputsSHA256)
        XCTAssertEqual(transformed.calibrationPlanSHA256, original.calibrationPlanSHA256)
        XCTAssertEqual(transformed.corpusLockBundleSHA256, original.corpusLockBundleSHA256)
        XCTAssertEqual(transformed.boundaryMode, original.boundaryMode)
        XCTAssertEqual(transformed.operatorParameters, original.operatorParameters)
        XCTAssertEqual(transformed.semanticSteps, original.semanticSteps)
        XCTAssertEqual(transformed.compilerPolicy, original.compilerPolicy)
        let otherRoute: ASHSpatialRouteV2 = route == .direct2x ? .direct3Over2 : .direct2x
        XCTAssertEqual(
            transformed.routeSelection(for: otherRoute),
            original.routeSelection(for: otherRoute)
        )
        XCTAssertEqual(
            transformed.routeSelection(for: route).analysisGridSourceStep,
            original.routeSelection(for: route).analysisGridSourceStep
        )
        XCTAssertEqual(
            original.routeSelection(for: route).lumaCoordinatePolicy,
            .halfPixelCenter
        )
        XCTAssertEqual(
            original.routeSelection(for: route).chromaCoordinatePolicy,
            .sourceAlignedRational
        )
        XCTAssertEqual(
            transformed.routeSelection(for: route).lumaCoordinatePolicy,
            .halfPixelCenter
        )
        XCTAssertEqual(
            transformed.routeSelection(for: route).chromaCoordinatePolicy,
            .halfPixelCenter
        )
    }
}
