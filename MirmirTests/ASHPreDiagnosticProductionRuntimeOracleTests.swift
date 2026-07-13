import CryptoKit
import Foundation
import XCTest
@testable import Mirmir

final class ASHPreDiagnosticRuntimeOracleTests: XCTestCase {
    func test_productionSampleRuntimeMatchesFrozenPreDiagnosticOracle() throws {
        // Frozen from the optimized production arithmetic at clean tracked HEAD
        // 6a978871fbf4d731b338879cf1c627d6b8aa16dc.
        let expectedRouteHashes: [(ASHSpatialRouteV2, String)] = [
            (
                .direct2x,
                "1830179190d11d7fded4765714c8170848b3f21ab60e48a8448b101fb1202ca6"
            ),
            (
                .direct3Over2,
                "7eab71aa8d2052b62dc1022cb7f19474ce0608c527ee5a5d4198b6d2dd0acc46"
            )
        ]
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        for (route, expectedHash) in expectedRouteHashes {
            let fixture = try ASHLockedRuntimeTestSupportV2
                .preDiagnosticLockedMappingFixture(route)
            let output = try ASHLockedReferencePipelineV2.process(
                ASHLockedReferenceInputV2(
                    luma: planes.luma,
                    cb: planes.cb,
                    cr: planes.cr,
                    chromaSiting: .left,
                    lut: fixture.runtime.loaded,
                    configuration: fixture.runtime.configuration,
                    mapping: fixture.mapping
                )
            )
            XCTAssertEqual(
                productionRuntimeOracleHash(route: route, output: output),
                expectedHash,
                route.rawValue
            )
        }

        let fallback = try forcedFallbackProductionResult()
        XCTAssertTrue(fallback.numericalFallbackUsed)
        XCTAssertEqual(fallback.primaryResult.descriptorID, 0)
        XCTAssertNil(fallback.secondaryResult)
        XCTAssertEqual(
            productionFallbackOracleHash(fallback),
            "02a119268604545cd9963c5902c535de8b9a20a23b29848b76f5dd13b4841ca4"
        )
    }
}

private extension ASHPreDiagnosticRuntimeOracleTests {
    func productionRuntimeOracleHash(
        route: ASHSpatialRouteV2,
        output: ASHLockedReferenceOutputV2
    ) -> String {
        var payload = Data(
            "MIRMIR-ASH-PRODUCTION-SAMPLE-RUNTIME-PRE-DIAGNOSTIC-V1\0".utf8
        )
        appendOracleString(route.rawValue, to: &payload)
        appendOraclePlane("Y", output.luma, to: &payload)
        appendOraclePlane("CB", output.cb, to: &payload)
        appendOraclePlane("CR", output.cr, to: &payload)
        return SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
    }

    func productionFallbackOracleHash(
        _ result: ASHLockedRuntimeSampleResultV2
    ) -> String {
        var payload = Data(
            "MIRMIR-ASH-PRODUCTION-SAMPLE-RUNTIME-FALLBACK-PRE-DIAGNOSTIC-V1\0".utf8
        )
        appendOracleUInt64(result.value.bitPattern, to: &payload)
        appendOracleUInt64(result.primaryResult.value.bitPattern, to: &payload)
        payload.append(result.primaryResult.descriptorID)
        payload.append(result.numericalFallbackUsed ? 1 : 0)
        payload.append(result.secondaryResult == nil ? 1 : 0)
        payload.append(result.sourceAlignedSamplePreserved ? 1 : 0)
        appendOracleUInt64(UInt64(result.phaseOrdinal), to: &payload)
        appendOracleUInt64(UInt64(result.analysisCellColumn), to: &payload)
        appendOracleUInt64(UInt64(result.analysisCellRow), to: &payload)
        return SHA256.hash(data: payload).map {
            String(format: "%02x", $0)
        }.joined()
    }

    func appendOraclePlane(
        _ tag: String,
        _ plane: ASHLockedReferencePlaneOutputV2,
        to payload: inout Data
    ) {
        appendOracleString(tag, to: &payload)
        appendOracleUInt64(UInt64(plane.width), to: &payload)
        appendOracleUInt64(UInt64(plane.height), to: &payload)
        appendOracleUInt64(UInt64(plane.normalizedSamples.count), to: &payload)
        for sample in plane.normalizedSamples {
            appendOracleUInt64(sample.bitPattern, to: &payload)
        }
    }

    func appendOracleString(_ value: String, to payload: inout Data) {
        payload.append(contentsOf: value.utf8)
        payload.append(0)
    }

    func appendOracleUInt64(_ value: UInt64, to payload: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { payload.append(contentsOf: $0) }
    }

    func forcedFallbackProductionResult() throws -> ASHLockedRuntimeSampleResultV2 {
        let runtime = try ASHLockedRuntimeTestSupportV2.fixture(
            route: .direct2x,
            policy: .halfPixelCenter,
            step: 1
        )
        let planes = try ASHLockedRuntimeTestSupportV2.planes()
        let analysisGrid = try ASHLockedRuntimeTestSupportV2.analysisGrid(
            planes: planes,
            configuration: runtime.configuration,
            route: .direct2x,
            siting: .left
        )
        let dispatchGrid = try ASHLockedRuntimeV2.makeDispatchGrid(
            lut: runtime.loaded,
            configuration: runtime.configuration,
            analysisGrid: analysisGrid
        )
        let source = try XCTUnwrap(dispatchGrid.dispatches.first)
        let sourceCandidate = source.primary
        let parameters = ASHSpatialDevelopmentParametersV2(
            anisotropyStrength: sourceCandidate.parameters.anisotropyStrength,
            minimumAnisotropicMagnitude: sourceCandidate.parameters.minimumAnisotropicMagnitude,
            minimumAnisotropicCoherence: sourceCandidate.parameters.minimumAnisotropicCoherence,
            controlledDetailGain: 0.25,
            relaxedLimiterAlpha: 0.0,
            riskDetailSuppressionThreshold: sourceCandidate.parameters.riskDetailSuppressionThreshold,
            lowPassRadius: 0.5,
            weightEpsilon: 0.6,
            supportRadius: 2.0
        )
        let candidate = ASHLockedRuntimeCandidateV2(
            decodedMessage: sourceCandidate.decodedMessage,
            descriptor: try ASHSpatialDescriptorV2(id: 4),
            affineDecode: sourceCandidate.affineDecode,
            sidecar: sourceCandidate.sidecar,
            orientationSector: sourceCandidate.orientationSector,
            parameters: parameters
        )
        let dispatch = ASHLockedRuntimeDispatchV2(
            sourceState: source.sourceState,
            parityWasRecomputed: source.parityWasRecomputed,
            primary: candidate,
            secondary: nil,
            primaryWeightUNorm16: .max,
            secondaryWeightUNorm16: 0,
            marginUNorm16: .max,
            affineFallbackUsed: source.affineFallbackUsed,
            sourceAlignedEntryFlag: false,
            counters: source.counters
        )
        let fallbackGrid = ASHLockedDispatchGridV2(
            route: dispatchGrid.route,
            configuration: dispatchGrid.configuration,
            context: dispatchGrid.context,
            analysisColumnCount: dispatchGrid.analysisColumnCount,
            analysisRowCount: dispatchGrid.analysisRowCount,
            dispatches: Array(repeating: dispatch, count: dispatchGrid.dispatches.count),
            counters: dispatchGrid.counters
        )
        return try ASHLockedRuntimeV2.evaluateSample(
            dispatchGrid: fallbackGrid,
            configuration: runtime.configuration,
            analysisGrid: analysisGrid,
            plane: ASHLockedRuntimeTestSupportV2.spatialPlane(planes.luma),
            destinationColumn: 0,
            destinationRow: 0,
            chromaSiting: nil
        )
    }
}
