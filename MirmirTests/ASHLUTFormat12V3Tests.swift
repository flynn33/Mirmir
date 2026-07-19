import CryptoKit
import XCTest
@testable import Mirmir

// The format contract is kept in one suite so every byte-level mutation is visible.
// swiftlint:disable:next type_body_length
final class ASHLUTFormat12V3Tests: XCTestCase {
    func testStrictSchema2LoaderAndSelfHashFailClosed() throws {
        let data = try ASHLUTTestSupportV3.sharedLockedInputData()
        XCTAssertEqual(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "1c6f1076c994a257c25e8583cd12a3ce853b7cfb659734ba3e74020b53c13610"
        )
        let configuration = try ASHLUTLockedConfigurationJSONLoaderV3.load(data)
        XCTAssertEqual(configuration.configurationID, "format-1.2-cross-language-parity-001")
        XCTAssertEqual(
            configuration.compilerInputsSHA256.hex,
            "d2afbb3027bb9812aad2687f0f7dc1a6171f932a908c4053ee19cedf23548319"
        )
        let canonicalHashInput = try ASHLUTLockedConfigurationJSONLoaderV3.canonicalHashInput(data)
        XCTAssertEqual(
            SHA256.hash(data: canonicalHashInput).map { String(format: "%02x", $0) }.joined(),
            configuration.compilerInputsSHA256.hex
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let stale = Data(
            text.replacingOccurrences(of: "mirror_reflect101", with: "clamp").utf8
        )
        XCTAssertThrowsError(try ASHLUTLockedConfigurationJSONLoaderV3.load(stale)) {
            XCTAssertEqual($0 as? ASHLUTLockedConfigurationJSONErrorV3, .selfHashMismatch)
        }

        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = Data((compact.dropLast() + ",\"top_two\":2}").utf8)
        XCTAssertThrowsError(try ASHLUTLockedConfigurationJSONLoaderV3.load(duplicate)) {
            XCTAssertEqual($0 as? ASHLUTLockedConfigurationJSONErrorV3, .duplicateKey)
        }

        let projected = Data(
            text.replacingOccurrences(
                of: "\"minimum_anisotropic_magnitude_unorm15\":1638",
                with: "\"anisotropy_strength_q12\":3072,\"minimum_anisotropic_magnitude_unorm15\":1638"
            ).utf8
        )
        XCTAssertThrowsError(try ASHLUTLockedConfigurationJSONLoaderV3.load(projected)) {
            XCTAssertEqual($0 as? ASHLUTLockedConfigurationJSONErrorV3, .selfHashMismatch)
        }
    }

    func testConfigurationRejectsInadmissiblePolicyAndAllIsotropicVector() throws {
        XCTAssertThrowsError(try ASHLUTTestSupportV3.routeSelection(
            policyID: 8,
            lumaMode: .rotatedZero,
            chromaMode: .rotatedQ12x1024,
            lumaCoordinatePolicy: .halfPixelCenter,
            chromaCoordinatePolicy: .halfPixelCenter,
            analysisGridSourceStep: 1
        )) {
            XCTAssertEqual($0 as? ASHLUTCompilerErrorV3, .invalidLockedConfiguration)
        }

        let isotropic2x = try ASHLUTTestSupportV3.routeSelection(
            policyID: 7,
            lumaMode: .isotropic,
            chromaMode: .isotropic,
            lumaCoordinatePolicy: .sourceAlignedRational,
            chromaCoordinatePolicy: .halfPixelCenter,
            analysisGridSourceStep: 1
        )
        let isotropic3Over2 = try ASHLUTTestSupportV3.routeSelection(
            policyID: 16,
            lumaMode: .isotropic,
            chromaMode: .isotropic,
            lumaCoordinatePolicy: .halfPixelCenter,
            chromaCoordinatePolicy: .sourceAlignedRational,
            analysisGridSourceStep: 2
        )
        XCTAssertThrowsError(try ASHLUTTestSupportV3.configuration(
            direct2x: isotropic2x,
            direct3Over2: isotropic3Over2
        )) {
            XCTAssertEqual($0 as? ASHLUTCompilerErrorV3, .invalidLockedConfiguration)
        }
        XCTAssertEqual(ASHLUTAnisotropyModeV3.isotropic.anisotropyStrengthQ12, 0)
        XCTAssertEqual(ASHLUTAnisotropyModeV3.rotatedZero.anisotropyStrengthQ12, 0)
        XCTAssertFalse(ASHLUTAnisotropyModeV3.isotropic.usesAnisotropy)
        XCTAssertTrue(ASHLUTAnisotropyModeV3.rotatedZero.usesAnisotropy)
    }

    func testEveryAdmissiblePolicyMatchesIndependentKSDLProgram() throws {
        for route in ASHSpatialRouteV2.allCases {
            for policyID in ASHLUTLockedRouteSelectionV3.admissibleSpatialPolicyIDs.sorted() {
                for phase in 0..<route.phasePairCount {
                    for sourceState in ASHLUTStateOrdinalTableV3.validStates {
                        let semanticState = try ASHLUTLeafCompilerV3.spatialSemanticState(sourceState)
                        XCTAssertEqual(
                            ASHLUTLeafCompilerV3.baseDescriptorID(
                                state: semanticState,
                                phaseOrdinal: phase,
                                route: route,
                                spatialPolicyID: policyID
                            ),
                            independentDescriptor(
                                state: semanticState,
                                phaseOrdinal: phase,
                                route: route,
                                policyID: policyID
                            )
                        )
                    }
                }
            }
        }
    }

    func testPythonOracleParityForBothRoutesIsByteExact() throws {
        let direct2x = try ASHLUTTestSupportV3.direct2x()
        XCTAssertEqual(direct2x.compilation.entries.count, 8_192)
        XCTAssertEqual(direct2x.compilation.offlinePathEvaluationCount, 663_552)
        XCTAssertEqual(direct2x.artifact.data.count, 200_064)
        XCTAssertEqual(direct2x.artifact.parameterCount, 49)
        XCTAssertEqual(u32(direct2x.artifact.data, 288), 2_918_521_225)
        XCTAssertEqual(u32(direct2x.artifact.data, 292), 4_189_404_205)
        XCTAssertEqual(
            direct2x.artifact.payloadSHA256.hex,
            "e389e0644685fee07ebf5b297ea4817d9c86ff708d5ba3c47b847be1d87b5109"
        )
        XCTAssertEqual(
            direct2x.artifact.wholeFileSHA256.hex,
            "992d9b409c32d862b73d29ce7e6819b88ddbadbb7e59dd4cb3da9d8299f30b39"
        )

        let direct3Over2 = try ASHLUTTestSupportV3.direct3Over2()
        XCTAssertEqual(direct3Over2.compilation.entries.count, 18_432)
        XCTAssertEqual(direct3Over2.compilation.offlinePathEvaluationCount, 1_492_992)
        XCTAssertEqual(direct3Over2.artifact.data.count, 445_312)
        XCTAssertEqual(direct3Over2.artifact.parameterCount, 41)
        XCTAssertEqual(u32(direct3Over2.artifact.data, 288), 3_597_619_339)
        XCTAssertEqual(u32(direct3Over2.artifact.data, 292), 3_832_117_350)
        XCTAssertEqual(
            direct3Over2.artifact.payloadSHA256.hex,
            "5064d2d0a13cd82c0f807c88a3c6465784a9e7d0066f5e69c82517ccabf0b612"
        )
        XCTAssertEqual(
            direct3Over2.artifact.wholeFileSHA256.hex,
            "dc1a506d2f5914c9fc5982be2cdb6a36279d65988f1833133672f3b3e36398ab"
        )
        for fixture in [direct2x, direct3Over2] {
            let loaded = try ASHLUTBinaryCodecV3.load(
                fixture.artifact.data,
                expectedRoute: fixture.compilation.route,
                configuration: fixture.configuration
            )
            XCTAssertEqual(loaded.entries.count, fixture.compilation.entries.count)
            XCTAssertEqual(loaded.parameters.count, fixture.artifact.parameterCount)
            XCTAssertEqual(loaded.immutableBytes, fixture.artifact.data)
            XCTAssertLessThanOrEqual(loaded.maximumOperatorEvaluations, 2)
        }
    }

    func testFormat12HeaderLayoutParameterBindingsAndDeterminism() throws {
        for fixture in [try ASHLUTTestSupportV3.direct2x(), try ASHLUTTestSupportV3.direct3Over2()] {
            let data = fixture.artifact.data
            let selection = fixture.configuration.routeSelection(for: fixture.compilation.route)
            XCTAssertEqual(Array(data[0..<8]), Array("ASHV2LUT".utf8))
            XCTAssertEqual(u16(data, 8), 1)
            XCTAssertEqual(u16(data, 10), 2)
            XCTAssertEqual(u16(data, 12), 320)
            XCTAssertEqual(u16(data, 18), 15)
            XCTAssertEqual(u16(data, 22), 4)
            XCTAssertEqual(u16(data, 24), 256)
            XCTAssertEqual(u16(data, 26), 24)
            XCTAssertEqual(u16(data, 28), 64)
            XCTAssertEqual(u16(data, 30), 2)
            XCTAssertEqual(data[300], selection.spatialPolicyID)
            XCTAssertEqual(data[301], selection.lumaAnisotropyMode.rawValue)
            XCTAssertEqual(data[302], selection.chromaAnisotropyMode.rawValue)
            XCTAssertEqual(data[303], selection.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
            XCTAssertEqual(data[304], selection.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1)
            XCTAssertEqual(data[305], 1)
            XCTAssertTrue(data[306..<320].allSatisfy { $0 == 0 })
            XCTAssertEqual(u32(data, 32), UInt32(fixture.compilation.entries.count))
            XCTAssertEqual(u32(data, 52), UInt32(fixture.compilation.entries.count * 24))
            XCTAssertEqual(u32(data, 296), UInt32(data.count))

            let parameterOffset = Int(u32(data, 40))
            for index in 0..<fixture.artifact.parameterCount {
                let offset = parameterOffset + index * 64
                XCTAssertEqual(
                    data[offset + 50],
                    selection.lumaCoordinatePolicy == .halfPixelCenter ? 0 : 1
                )
                XCTAssertEqual(
                    data[offset + 54],
                    selection.chromaCoordinatePolicy == .halfPixelCenter ? 0 : 1
                )
                XCTAssertEqual(data[offset + 53], 0)
                XCTAssertTrue(data[(offset + 55)..<(offset + 60)].allSatisfy { $0 == 0 })
            }

            let repeated = try ASHLUTBinaryCodecV3.serialize(
                ASHLUTLeafCompilerV3.compile(
                    route: fixture.compilation.route,
                    configuration: fixture.configuration
                )
            )
            XCTAssertEqual(repeated.data, data)
        }
    }

    func testPlaneLocalSourceExactIndependentCompilationAndLookup() throws {
        let direct2x = try ASHLUTTestSupportV3.direct2x()
        let entriesPer2xPlane = 4 * 4 * 256
        XCTAssertEqual(
            direct2x.compilation.entries.filter { $0.planeRole == .luma && $0.sourceAlignedExact }.count,
            1_024
        )
        XCTAssertEqual(
            direct2x.compilation.entries.filter { $0.planeRole == .chroma && $0.sourceAlignedExact }.count,
            0
        )
        XCTAssertTrue(direct2x.compilation.entries[41].sourceAlignedExact)
        XCTAssertFalse(direct2x.compilation.entries[entriesPer2xPlane + 41].sourceAlignedExact)

        let lumaOrdinary = direct2x.compilation.entries[1_024 + 41]
        let chromaOrdinary = direct2x.compilation.entries[entriesPer2xPlane + 1_024 + 41]
        XCTAssertEqual(lumaOrdinary.primary.descriptorID, chromaOrdinary.primary.descriptorID)
        XCTAssertEqual(lumaOrdinary.primary.message, chromaOrdinary.primary.message)
        XCTAssertEqual(lumaOrdinary.parameters.primary.anisotropyStrengthQ12, 0)
        XCTAssertEqual(chromaOrdinary.parameters.primary.anisotropyStrengthQ12, 3_072)

        let loaded2x = try ASHLUTBinaryCodecV3.load(
            direct2x.artifact.data,
            expectedRoute: .direct2x,
            configuration: direct2x.configuration
        )
        XCTAssertEqual(
            try loaded2x.entry(
                state: lumaOrdinary.sourceState,
                planeRole: .luma,
                phaseOrdinal: 1,
                context: .spatialOnly
            ),
            loaded2x.entries[1_024 + 41]
        )
        XCTAssertEqual(
            try loaded2x.entry(
                state: chromaOrdinary.sourceState,
                planeRole: .chroma,
                phaseOrdinal: 1,
                context: .spatialOnly
            ),
            loaded2x.entries[entriesPer2xPlane + 1_024 + 41]
        )

        let direct3Over2 = try ASHLUTTestSupportV3.direct3Over2()
        XCTAssertEqual(
            direct3Over2.compilation.entries.filter { $0.planeRole == .luma && $0.sourceAlignedExact }.count,
            0
        )
        XCTAssertEqual(
            direct3Over2.compilation.entries.filter { $0.planeRole == .chroma && $0.sourceAlignedExact }.count,
            1_024
        )
    }

    func testTemporalContextsMirrorSpatialPerPlane() throws {
        for fixture in [try ASHLUTTestSupportV3.direct2x(), try ASHLUTTestSupportV3.direct3Over2()] {
            let route = fixture.compilation.route
            let entriesPerPlane = route.phasePairCount * 4 * 256
            for plane in 0..<2 {
                for phase in 0..<route.phasePairCount {
                    let base = plane * entriesPerPlane + phase * 4 * 256
                    for state in 0..<256 {
                        let spatial = fixture.compilation.entries[base + state]
                        XCTAssertFalse(spatial.temporalForcedSpatial)
                        for context in 1..<4 {
                            let temporal = fixture.compilation.entries[base + context * 256 + state]
                            XCTAssertTrue(temporal.temporalForcedSpatial)
                            XCTAssertEqual(temporal.primary, spatial.primary)
                            XCTAssertEqual(temporal.secondary, spatial.secondary)
                            XCTAssertEqual(temporal.parameters, spatial.parameters)
                        }
                    }
                }
            }
        }
    }

    func testRotatedZeroAndIsotropicHaveDistinctHeadersWithEqualPayload() throws {
        let base = try ASHLUTTestSupportV3.sharedConfiguration()
        let direct2x = base.routes.direct2x
        let isotropicSelection = try ASHLUTTestSupportV3.routeSelection(
            policyID: direct2x.spatialPolicyID,
            lumaMode: .isotropic,
            chromaMode: direct2x.chromaAnisotropyMode,
            lumaCoordinatePolicy: direct2x.lumaCoordinatePolicy,
            chromaCoordinatePolicy: direct2x.chromaCoordinatePolicy,
            analysisGridSourceStep: direct2x.analysisGridSourceStep
        )
        let rotatedSelection = try ASHLUTTestSupportV3.routeSelection(
            policyID: direct2x.spatialPolicyID,
            lumaMode: .rotatedZero,
            chromaMode: direct2x.chromaAnisotropyMode,
            lumaCoordinatePolicy: direct2x.lumaCoordinatePolicy,
            chromaCoordinatePolicy: direct2x.chromaCoordinatePolicy,
            analysisGridSourceStep: direct2x.analysisGridSourceStep
        )
        let isotropic = try ASHLUTBinaryCodecV3.serialize(ASHLUTLeafCompilerV3.compile(
            route: .direct2x,
            configuration: ASHLUTTestSupportV3.configuration(direct2x: isotropicSelection)
        ))
        let rotated = try ASHLUTBinaryCodecV3.serialize(ASHLUTLeafCompilerV3.compile(
            route: .direct2x,
            configuration: ASHLUTTestSupportV3.configuration(direct2x: rotatedSelection)
        ))
        XCTAssertEqual(isotropic.data[301], 0)
        XCTAssertEqual(rotated.data[301], 1)
        XCTAssertEqual(isotropic.payloadSHA256, rotated.payloadSHA256)
        XCTAssertNotEqual(isotropic.wholeFileSHA256, rotated.wholeFileSHA256)
    }

    func testLoaderRejectsResealedHeaderAndSemanticCorruptionByTaxonomy() throws {
        let fixture = try ASHLUTTestSupportV3.direct2x()
        var data = fixture.artifact.data
        data[306] = 1
        resealHeader(&data)
        try assertLoadError(data, expected: .reservedNonzero, fixture: fixture)

        data = fixture.artifact.data
        data[300] = 6
        resealHeader(&data)
        try assertLoadError(data, expected: .inputHashMismatch, fixture: fixture)

        data = fixture.artifact.data
        let logicalIndex = 1_065
        let entryOffset = Int(u32(data, 44)) + logicalIndex * 24
        data[entryOffset + 6] ^= 1
        resealEntry(at: entryOffset, logicalIndex: logicalIndex, in: &data)
        resealPayload(&data)
        try assertLoadError(data, expected: .decodedMessageMismatch, fixture: fixture)
    }

    private func independentDescriptor(
        state: ASHState,
        phaseOrdinal: Int,
        route: ASHSpatialRouteV2,
        policyID: UInt8
    ) -> UInt8 {
        let b1 = state.bit(coordinate: 1)
        let b2 = state.bit(coordinate: 2)
        let edge = state.bit(coordinate: 3)
        let coherent = state.bit(coordinate: 4)
        let texture = state.bit(coordinate: 5)
        let risk = state.bit(coordinate: 6)
        let aligned = state.bit(coordinate: 8)
        let horizontal = phaseOrdinal % route.scaleNumerator
        let vertical = phaseOrdinal / route.scaleNumerator
        let phase = ((2 * horizontal >= route.scaleNumerator) ? 1 : 0)
            ^ ((2 * vertical >= route.scaleNumerator) ? 1 : 0)
        let orientedEdge = edge & (b1 ^ b2)
        let kernels = [texture ^ orientedEdge ^ phase, texture ^ orientedEdge, texture | orientedEdge]
        let edgeCoherence = edge & coherent
        let supports = [
            edgeCoherence,
            edgeCoherence & (1 - risk),
            edgeCoherence & (1 - texture),
            edgeCoherence & (1 - risk) & (1 - texture)
        ]
        let details = [edge & texture & (1 - risk), texture & (1 - risk)]
        let limiters = [aligned & (1 - risk), aligned]
        let policyIndex: Int = Int(policyID)
        let kernelBits: Int = kernels[policyIndex / 16]
        let supportBits: Int = supports[(policyIndex % 16) / 4] << 1
        let detailBits: Int = details[(policyIndex % 4) / 2] << 2
        let limiterBits: Int = limiters[policyIndex % 2] << 3
        let descriptor: Int = kernelBits | supportBits | detailBits | limiterBits
        return UInt8(descriptor)
    }

    private func assertLoadError(
        _ data: Data,
        expected: ASHLUTBinaryErrorV3,
        fixture: ASHLUTTestFixtureV3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try ASHLUTBinaryCodecV3.load(
                data,
                expectedRoute: fixture.compilation.route,
                configuration: fixture.configuration
            ),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? ASHLUTBinaryErrorV3, expected, file: file, line: line)
        }
    }

    private func resealEntry(at offset: Int, logicalIndex: Int, in data: inout Data) {
        let parameterIndex = Int(u32(data, offset + 16))
        let parameterOffset = Int(u32(data, 40)) + parameterIndex * 64
        var provenance = Data()
        append(u16(data, 16), to: &provenance)
        append(UInt32(logicalIndex), to: &provenance)
        provenance.append(data[offset..<(offset + 20)])
        provenance.append(data[parameterOffset..<(parameterOffset + 64)])
        ASHLUTTestSupportV3.write(
            ASHLUTCRC32V3.checksum(provenance),
            at: offset + 20,
            in: &data
        )
    }

    private func resealPayload(_ data: inout Data) {
        let payload = Data(data[320..<data.count])
        data.replaceSubrange(256..<288, with: Array(SHA256.hash(data: payload)))
        ASHLUTTestSupportV3.write(ASHLUTCRC32V3.checksum(payload), at: 292, in: &data)
        resealHeader(&data)
    }

    private func resealHeader(_ data: inout Data) {
        ASHLUTTestSupportV3.write(UInt32(0), at: 288, in: &data)
        ASHLUTTestSupportV3.write(
            ASHLUTCRC32V3.checksum(Data(data[0..<320])),
            at: 288,
            in: &data
        )
    }

    private func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        ASHLUTTestSupportV3.uint16(data, at: offset)
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        ASHLUTTestSupportV3.uint32(data, at: offset)
    }
}
