import CryptoKit
import XCTest
@testable import Mirmir

final class ASHLUTBinaryFormatV2Tests: XCTestCase {
    func testExactEndianLayoutIntegrityAndImmutableRoundTrip() throws {
        let fixture = try ASHLUTTestSupportV2.sourceDirect2x()
        let data = fixture.artifact.data
        XCTAssertEqual(Array(data[0..<8]), Array("ASHV2LUT".utf8))
        XCTAssertEqual(u16(data, 8), 1)
        XCTAssertEqual(u16(data, 10), 0)
        XCTAssertEqual(u16(data, 12), 320)
        XCTAssertEqual(u16(data, 14), 0x4c45)
        XCTAssertEqual(u16(data, 16), 1)
        XCTAssertEqual(u16(data, 18), 15)
        XCTAssertEqual(u16(data, 20), 4)
        XCTAssertEqual(u16(data, 22), 4)
        XCTAssertEqual(u16(data, 24), 256)
        XCTAssertEqual(u16(data, 26), 24)
        XCTAssertEqual(u16(data, 28), 64)
        XCTAssertEqual(u16(data, 30), 0)
        XCTAssertEqual(u32(data, 32), 4_096)
        XCTAssertEqual(u32(data, 40), 320)
        XCTAssertEqual(u32(data, 48), u32(data, 36) * 64)
        XCTAssertEqual(u32(data, 44), 320 + u32(data, 48))
        XCTAssertEqual(u32(data, 52), 4_096 * 24)
        XCTAssertEqual(u32(data, 56), 320)
        XCTAssertEqual(u32(data, 60), u32(data, 48) + u32(data, 52))
        XCTAssertEqual(u32(data, 296), UInt32(data.count))
        XCTAssertTrue(data[300..<320].allSatisfy { $0 == 0 })

        var header = Data(data[0..<320])
        write(UInt32(0), at: 288, in: &header)
        XCTAssertEqual(u32(data, 288), ASHLUTCRC32V2.checksum(header))
        let payload = Data(data[320..<data.count])
        XCTAssertEqual(u32(data, 292), ASHLUTCRC32V2.checksum(payload))
        XCTAssertEqual(
            Array(data[256..<288]),
            Array(SHA256.hash(data: payload))
        )
        XCTAssertEqual(fixture.artifact.payloadSHA256.bytes, Array(SHA256.hash(data: payload)))
        XCTAssertEqual(fixture.artifact.wholeFileSHA256.bytes, Array(SHA256.hash(data: data)))

        let parameterOffset = Int(u32(data, 40))
        let parameterCount = Int(u32(data, 36))
        var previousPrefix: Data?
        for index in 0..<parameterCount {
            let offset = parameterOffset + index * 64
            let record = Data(data[offset..<(offset + 64)])
            let prefix = Data(record[0..<60])
            XCTAssertEqual(u32(record, 60), ASHLUTCRC32V2.checksum(prefix))
            if let previousPrefix {
                XCTAssertTrue(previousPrefix.lexicographicallyPrecedes(prefix))
            }
            previousPrefix = prefix
        }

        let entryOffset = Int(u32(data, 44))
        for logicalIndex in 0..<4_096 {
            let offset = entryOffset + logicalIndex * 24
            let record = Data(data[offset..<(offset + 24)])
            let parameterIndex = Int(u32(record, 16))
            XCTAssertLessThan(parameterIndex, parameterCount)
            var provenance = Data()
            append(UInt16(1), to: &provenance)
            append(UInt32(logicalIndex), to: &provenance)
            provenance.append(record[0..<20])
            let parameterRecordOffset = parameterOffset + parameterIndex * 64
            provenance.append(data[parameterRecordOffset..<(parameterRecordOffset + 64)])
            XCTAssertEqual(u32(record, 20), ASHLUTCRC32V2.checksum(provenance))
        }

        let loaded = try ASHLUTBinaryCodecV2.load(
            data,
            expectedRoute: .direct2x,
            configuration: fixture.configuration
        )
        XCTAssertEqual(loaded.route, .direct2x)
        XCTAssertEqual(loaded.configuration, fixture.configuration)
        XCTAssertEqual(loaded.immutableBytes, data)
        XCTAssertEqual(loaded.payloadSHA256, fixture.artifact.payloadSHA256)
        XCTAssertEqual(loaded.wholeFileSHA256, fixture.artifact.wholeFileSHA256)
        XCTAssertEqual(loaded.runtimeTreeGenerationCount, 0)
        XCTAssertLessThanOrEqual(loaded.maximumOperatorEvaluations, 2)
        XCTAssertEqual(loaded.entries.count, fixture.compilation.entries.count)
        XCTAssertEqual(loaded.parameters.count, fixture.artifact.parameterCount)

        for (index, compiled) in fixture.compilation.entries.enumerated() {
            let decoded = loaded.entries[index]
            XCTAssertEqual(decoded.primaryAffineState, compiled.primary.affineState)
            XCTAssertEqual(decoded.secondaryAffineState, compiled.secondary?.affineState)
            XCTAssertEqual(decoded.primaryDescriptorID, compiled.primary.descriptorID)
            XCTAssertEqual(decoded.secondaryDescriptorID, compiled.secondary?.descriptorID)
            XCTAssertEqual(decoded.primaryMessage, compiled.primary.message)
            XCTAssertEqual(decoded.secondaryMessage, compiled.secondary?.message)
            XCTAssertEqual(decoded.primaryWeightUNorm16, compiled.primaryWeightUNorm16)
            XCTAssertEqual(decoded.secondaryWeightUNorm16, compiled.secondaryWeightUNorm16)
            XCTAssertEqual(decoded.marginUNorm16, compiled.marginUNorm16)
            XCTAssertEqual(loaded.parameters[Int(decoded.parameterIndex)], compiled.parameters)
            XCTAssertLessThanOrEqual(decoded.operatorEvaluationCount, 2)
            XCTAssertEqual(
                try loaded.entry(
                    state: compiled.sourceState,
                    phaseOrdinal: Int(compiled.phaseOrdinal),
                    context: compiled.context
                ),
                decoded
            )
        }
    }

    func testNoSecondarySentinelsAndSourceExactRecordsAreExact() throws {
        let fixture = try ASHLUTTestSupportV2.sourceDirect2x()
        let data = fixture.artifact.data
        let entryOffset = Int(u32(data, 44))
        let parameterOffset = Int(u32(data, 40))
        for logicalIndex in 0..<1_024 {
            let offset = entryOffset + logicalIndex * 24
            let stateOrdinal = logicalIndex % 256
            let anchor = ASHLUTStateOrdinalTableV2.validStates[stateOrdinal]
            XCTAssertEqual(u16(data, offset), anchor.rawValue)
            XCTAssertEqual(u16(data, offset + 2), UInt16.max)
            XCTAssertEqual(data[offset + 4], 0)
            XCTAssertEqual(data[offset + 5], UInt8.max)
            XCTAssertEqual(data[offset + 6], 0)
            XCTAssertEqual(data[offset + 7], UInt8.max)
            XCTAssertEqual(u16(data, offset + 8), UInt16.max)
            XCTAssertEqual(u16(data, offset + 10), 0)
            XCTAssertEqual(u16(data, offset + 12), UInt16.max)
            XCTAssertEqual(u16(data, offset + 14) & 0b11, 0b10)
            let parameterIndex = Int(u32(data, offset + 16))
            let parameter = parameterOffset + parameterIndex * 64
            XCTAssertTrue(data[(parameter + 24)..<(parameter + 48)].allSatisfy { $0 == 0 })
            XCTAssertEqual(u16(data, parameter + 6), 0)
            XCTAssertEqual(u16(data, parameter + 8), 0)
            XCTAssertEqual(u16(data, parameter + 12), 512)
            XCTAssertEqual(u16(data, parameter + 22), 0b1_0001)
        }
    }

    func testLoaderRejectsHeaderPayloadAndIndexCorruptionByTaxonomy() throws {
        let fixture = try ASHLUTTestSupportV2.sourceDirect2x()
        let original = fixture.artifact.data
        try assertError(Data(original.prefix(319)), .truncatedFile, fixture)

        var data = original
        data[0] ^= 1
        try assertError(data, .badMagic, fixture)
        data = original
        write(UInt16(2), at: 8, in: &data)
        try assertError(data, .unsupportedVersion, fixture)
        data = original
        write(UInt16(0), at: 14, in: &data)
        try assertError(data, .badEndianness, fixture)
        data = original
        write(UInt16(1), at: 30, in: &data)
        try assertError(data, .reservedNonzero, fixture)
        data = original
        write(UInt16(2), at: 16, in: &data)
        try assertError(data, .invalidRoute, fixture)
        data = original
        write(UInt16(9), at: 20, in: &data)
        try assertError(data, .dimensionMismatch, fixture)
        data = original
        write(UInt32(321), at: 40, in: &data)
        try assertError(data, .offsetOrSizeOverflow, fixture)
        data = original
        data.append(0)
        try assertError(data, .fileSizeMismatch, fixture)
        data = original
        data[64] ^= 1
        try assertError(data, .headerCRCMismatch, fixture)
        data = original
        data[320] ^= 1
        try assertError(data, .payloadCRCMismatch, fixture)
        data = original
        data[320] ^= 1
        resealPayload(&data, updateSHA: false)
        try assertError(data, .payloadSHAMismatch, fixture)
        data = original
        data[64] ^= 1
        resealHeader(&data)
        try assertError(data, .inputHashMismatch, fixture)

        data = original
        data[320] ^= 1
        resealPayload(&data)
        try assertError(data, .parameterCRCMismatch, fixture)

        let entryOffset = Int(u32(original, 44))
        data = original
        data[entryOffset + 20] ^= 1
        resealPayload(&data)
        try assertError(data, .entryCRCMismatch, fixture)

        data = original
        write(u32(data, 36), at: entryOffset + 16, in: &data)
        resealPayload(&data)
        try assertError(data, .parameterIndexOutOfBounds, fixture)
    }

    func testLoaderRejectsResealedSemanticCorruption() throws {
        let fixture = try ASHLUTTestSupportV2.sourceDirect2x()
        let original = fixture.artifact.data
        let entryOffset = Int(u32(original, 44))
        let ordinaryEntryOffset = entryOffset + 1_024 * 24
        var data = original

        write(u16(data, entryOffset + 14) | (1 << 5), at: entryOffset + 14, in: &data)
        resealEntry(at: entryOffset, logicalIndex: 0, in: &data)
        resealPayload(&data)
        try assertError(data, .invalidEntryFlags, fixture)

        data = original
        data[entryOffset + 5] = 0
        resealEntry(at: entryOffset, logicalIndex: 0, in: &data)
        resealPayload(&data)
        try assertError(data, .invalidSentinel, fixture)

        data = original
        write(UInt16(512), at: entryOffset, in: &data)
        resealEntry(at: entryOffset, logicalIndex: 0, in: &data)
        resealPayload(&data)
        try assertError(data, .invalidAffine, fixture)

        data = original
        write(u16(data, ordinaryEntryOffset) ^ 1, at: ordinaryEntryOffset, in: &data)
        resealEntry(at: ordinaryEntryOffset, logicalIndex: 1_024, in: &data)
        resealPayload(&data)
        try assertError(data, .affineDecodeRejected, fixture)

        data = original
        data[ordinaryEntryOffset + 6] ^= 1
        resealEntry(at: ordinaryEntryOffset, logicalIndex: 1_024, in: &data)
        resealPayload(&data)
        try assertError(data, .decodedMessageMismatch, fixture)

        data = original
        let parameterIndex = Int(u32(data, entryOffset + 16))
        let parameterOffset = Int(u32(data, 40)) + parameterIndex * 64
        write(u16(data, parameterOffset + 22) | (1 << 6), at: parameterOffset + 22, in: &data)
        let prefix = Data(data[parameterOffset..<(parameterOffset + 60)])
        write(ASHLUTCRC32V2.checksum(prefix), at: parameterOffset + 60, in: &data)
        resealPayload(&data)
        try assertError(data, .invalidEntryFlags, fixture)
    }

    private func assertError(
        _ data: Data,
        _ expected: ASHLUTBinaryErrorV2,
        _ fixture: ASHLUTTestFixtureV2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try ASHLUTBinaryCodecV2.load(
                data,
                expectedRoute: .direct2x,
                configuration: fixture.configuration
            ),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? ASHLUTBinaryErrorV2, expected, file: file, line: line)
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
        write(ASHLUTCRC32V2.checksum(provenance), at: offset + 20, in: &data)
    }

    private func resealPayload(_ data: inout Data, updateSHA: Bool = true) {
        let payload = Data(data[320..<data.count])
        write(ASHLUTCRC32V2.checksum(payload), at: 292, in: &data)
        if updateSHA {
            data.replaceSubrange(256..<288, with: Array(SHA256.hash(data: payload)))
        }
        resealHeader(&data)
    }

    private func resealHeader(_ data: inout Data) {
        write(UInt32(0), at: 288, in: &data)
        let header = Data(data[0..<320])
        write(ASHLUTCRC32V2.checksum(header), at: 288, in: &data)
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
        ASHLUTTestSupportV2.uint16(data, at: offset)
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        ASHLUTTestSupportV2.uint32(data, at: offset)
    }

    private func write(_ value: UInt16, at offset: Int, in data: inout Data) {
        ASHLUTTestSupportV2.write(value, at: offset, in: &data)
    }

    private func write(_ value: UInt32, at offset: Int, in data: inout Data) {
        ASHLUTTestSupportV2.write(value, at: offset, in: &data)
    }
}
