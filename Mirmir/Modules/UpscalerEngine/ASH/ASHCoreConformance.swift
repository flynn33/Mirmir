import Foundation

enum ASHCoreConformanceContractError: Error, CustomStringConvertible, Equatable {
    case invalidJSON(String)
    case mismatch(field: String, expected: String, actual: String)

    var description: String {
        switch self {
        case .invalidJSON(let message):
            return "Invalid ASH core contract JSON: \(message)"
        case .mismatch(let field, let expected, let actual):
            return "ASH core contract mismatch for \(field): expected \(expected), received \(actual)."
        }
    }
}

private struct ASHCoreConformanceRecordSizes: Decodable {
    let rawState: UInt16
    let codeword: UInt16
    let affine: UInt16
}

private struct ASHCoreConformanceSectionOffsets: Decodable {
    let rawState: UInt32
    let codeword: UInt32
    let affine: UInt32
}

private struct ASHCoreConformanceStatusCodes: Decodable {
    let exact: UInt8
    let corrected: UInt8
    let rejected: UInt8
}

private struct ASHCoreConformanceContract: Decodable {
    struct Core: Decodable {
        let stateBits: Int
        let payloadBits: Int
        let messageBits: Int
        let coordinate1PackedBit: Int
        let coordinate9PackedBit: Int
        let messageBit1Order: String
        let integrityCoordinate: Int
        let integrityOperation: String
        let integritySourceCoordinates: [Int]
        let generatorRows: [String]
    }

    struct Binary: Decodable {
        let magic: String
        let schemaVersion: UInt16
        let endianness: String
        let endiannessCode: UInt8
        let bitOrderCode: UInt8
        let decoderRadius: UInt8
        let implicitPadding: Bool
        let headerSize: UInt16
        let recordSizes: ASHCoreConformanceRecordSizes
        let sectionOffsets: ASHCoreConformanceSectionOffsets
        let fileSize: UInt32
        let statusCodes: ASHCoreConformanceStatusCodes
        let affineSectionOrder: [String]
        let rawStateFieldOrder: [String]
        let codewordFieldOrder: [String]
        let affineFieldOrder: [String]
    }

    struct Exhaustive: Decodable {
        let rawStateCount: UInt32
        let validAnchorCount: UInt32
        let codewordCount: UInt32
        let exactAffineCount: UInt32
        let oneBitAffineCount: UInt32
        let twoBitFaultPairCount: UInt32
        let twoBitAffineCount: UInt32
    }

    let contractSchemaVersion: UInt16
    let core: Core
    let binary: Binary
    let exhaustive: Exhaustive
}

/// Deterministic binary conformance vectors emitted through the production
/// packed-state and decoder implementation. The independent reference format
/// is documented in `validation/reference/README.md`.
enum ASHCoreConformanceBinary {
    static let contractSchemaVersion: UInt16 = 1
    static let schemaVersion: UInt16 = 1
    static let headerSize: UInt16 = 64
    static let rawStateRecordSize: UInt16 = 4
    static let codewordRecordSize: UInt16 = 4
    static let affineRecordSize: UInt16 = 16
    static let decoderRadius: UInt8 = 1

    static let rawStateCount: UInt32 = 512
    static let codewordCount: UInt32 = 16
    static let validAnchorCount: UInt32 = 256
    static let exactAffineRecordCount: UInt32 = validAnchorCount * codewordCount
    static let oneBitAffineRecordCount: UInt32 = exactAffineRecordCount * 9
    static let twoBitAffineRecordCount: UInt32 = exactAffineRecordCount * 36

    static let rawStateRecordsOffset: UInt32 = UInt32(headerSize)
    static let codewordRecordsOffset: UInt32 = rawStateRecordsOffset
        + rawStateCount * UInt32(rawStateRecordSize)
    static let affineRecordsOffset: UInt32 = codewordRecordsOffset
        + codewordCount * UInt32(codewordRecordSize)
    static let fileSize: UInt32 = affineRecordsOffset
        + (exactAffineRecordCount + oneBitAffineRecordCount + twoBitAffineRecordCount)
        * UInt32(affineRecordSize)

    private enum StatusCode: UInt8 {
        case exact = 0
        case corrected = 1
        case rejected = 2
    }

    static func generate(validatingContractAt contractURL: URL) throws -> Data {
        try generate(validatingContractData: Data(contentsOf: contractURL))
    }

    static func generate(validatingContractData contractData: Data) throws -> Data {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let contract: ASHCoreConformanceContract
        do {
            contract = try decoder.decode(ASHCoreConformanceContract.self, from: contractData)
        } catch {
            throw ASHCoreConformanceContractError.invalidJSON(error.localizedDescription)
        }
        try validate(contract)

        var data = Data()
        data.reserveCapacity(Int(fileSize))

        appendHeader(contract: contract, to: &data)
        appendRawStateRecords(to: &data)
        appendCodewordRecords(to: &data)
        appendAffineRecords(to: &data)

        precondition(data.count == Int(fileSize))
        return data
    }

    private static func validate(_ contract: ASHCoreConformanceContract) throws {
        let core = contract.core
        let binary = contract.binary
        let exhaustive = contract.exhaustive
        let productionRows = ASHCode.generatorRows.map { bitString($0.rawValue) }

        try require(contract.contractSchemaVersion, equals: contractSchemaVersion, field: "contract_schema_version")
        try require(core.stateBits, equals: ASHState.bitCount, field: "core.state_bits")
        try require(core.payloadBits, equals: ASHState.payloadBitCount, field: "core.payload_bits")
        try require(core.messageBits, equals: ASHMessage.bitCount, field: "core.message_bits")
        try require(core.coordinate1PackedBit, equals: ASHState.bitCount - 1, field: "core.coordinate_1_packed_bit")
        try require(core.coordinate9PackedBit, equals: 0, field: "core.coordinate_9_packed_bit")
        try require(core.messageBit1Order, equals: "most_significant", field: "core.message_bit_1_order")
        try require(core.integrityCoordinate, equals: ASHState.bitCount, field: "core.integrity_coordinate")
        try require(core.integrityOperation, equals: "xor", field: "core.integrity_operation")
        try require(
            core.integritySourceCoordinates,
            equals: Array(1...ASHState.payloadBitCount),
            field: "core.integrity_source_coordinates"
        )
        try require(core.generatorRows, equals: productionRows, field: "core.generator_rows")

        try require(binary.magic, equals: "ASHCORE1", field: "binary.magic")
        try require(binary.schemaVersion, equals: schemaVersion, field: "binary.schema_version")
        try require(binary.endianness, equals: "little", field: "binary.endianness")
        try require(binary.endiannessCode, equals: 1, field: "binary.endianness_code")
        try require(binary.bitOrderCode, equals: 1, field: "binary.bit_order_code")
        try require(binary.decoderRadius, equals: decoderRadius, field: "binary.decoder_radius")
        try require(binary.implicitPadding, equals: false, field: "binary.implicit_padding")
        try require(binary.headerSize, equals: headerSize, field: "binary.header_size")
        try require(binary.recordSizes.rawState, equals: rawStateRecordSize, field: "binary.record_sizes.raw_state")
        try require(binary.recordSizes.codeword, equals: codewordRecordSize, field: "binary.record_sizes.codeword")
        try require(binary.recordSizes.affine, equals: affineRecordSize, field: "binary.record_sizes.affine")
        try require(binary.sectionOffsets.rawState, equals: rawStateRecordsOffset, field: "binary.section_offsets.raw_state")
        try require(binary.sectionOffsets.codeword, equals: codewordRecordsOffset, field: "binary.section_offsets.codeword")
        try require(binary.sectionOffsets.affine, equals: affineRecordsOffset, field: "binary.section_offsets.affine")
        try require(binary.fileSize, equals: fileSize, field: "binary.file_size")
        try require(binary.statusCodes.exact, equals: StatusCode.exact.rawValue, field: "binary.status_codes.exact")
        try require(binary.statusCodes.corrected, equals: StatusCode.corrected.rawValue, field: "binary.status_codes.corrected")
        try require(binary.statusCodes.rejected, equals: StatusCode.rejected.rawValue, field: "binary.status_codes.rejected")
        try require(binary.affineSectionOrder, equals: ["exact", "one_bit", "two_bit"], field: "binary.affine_section_order")
        try require(
            binary.rawStateFieldOrder,
            equals: ["raw_u16", "payload_parity_u8", "integrity_valid_u8"],
            field: "binary.raw_state_field_order"
        )
        try require(
            binary.codewordFieldOrder,
            equals: ["message_u8", "hamming_weight_u8", "codeword_u16"],
            field: "binary.codeword_field_order"
        )
        try require(
            binary.affineFieldOrder,
            equals: [
                "anchor_u16", "message_u8", "fault_count_u8", "first_fault_coordinate_u8",
                "second_fault_coordinate_u8", "relative_codeword_u16", "transmitted_affine_u16",
                "received_affine_u16", "status_u8", "corrected_coordinate_u8",
                "nearest_distance_u8", "nearest_count_u8"
            ],
            field: "binary.affine_field_order"
        )

        try require(exhaustive.rawStateCount, equals: rawStateCount, field: "exhaustive.raw_state_count")
        try require(exhaustive.validAnchorCount, equals: validAnchorCount, field: "exhaustive.valid_anchor_count")
        try require(exhaustive.codewordCount, equals: codewordCount, field: "exhaustive.codeword_count")
        try require(exhaustive.exactAffineCount, equals: exactAffineRecordCount, field: "exhaustive.exact_affine_count")
        try require(exhaustive.oneBitAffineCount, equals: oneBitAffineRecordCount, field: "exhaustive.one_bit_affine_count")
        try require(exhaustive.twoBitFaultPairCount, equals: 36, field: "exhaustive.two_bit_fault_pair_count")
        try require(exhaustive.twoBitAffineCount, equals: twoBitAffineRecordCount, field: "exhaustive.two_bit_affine_count")
    }

    private static func require<Value: Equatable>(
        _ actual: Value,
        equals expected: Value,
        field: String
    ) throws {
        guard actual == expected else {
            throw ASHCoreConformanceContractError.mismatch(
                field: field,
                expected: String(describing: expected),
                actual: String(describing: actual)
            )
        }
    }

    private static func bitString(_ value: UInt16) -> String {
        let digits = String(value, radix: 2)
        return String(repeating: "0", count: ASHState.bitCount - digits.count) + digits
    }

    private static func appendHeader(contract: ASHCoreConformanceContract, to data: inout Data) {
        let core = contract.core
        let binary = contract.binary
        let exhaustive = contract.exhaustive
        data.append(contentsOf: binary.magic.utf8)
        append(binary.schemaVersion, to: &data)
        append(binary.headerSize, to: &data)
        data.append(byte(core.stateBits))
        data.append(byte(core.payloadBits))
        data.append(byte(core.messageBits))
        data.append(binary.bitOrderCode)
        data.append(binary.endiannessCode)
        data.append(binary.decoderRadius)
        append(binary.recordSizes.rawState, to: &data)
        append(binary.recordSizes.codeword, to: &data)
        append(binary.recordSizes.affine, to: &data)
        append(exhaustive.rawStateCount, to: &data)
        append(exhaustive.codewordCount, to: &data)
        append(exhaustive.validAnchorCount, to: &data)
        append(exhaustive.exactAffineCount, to: &data)
        append(exhaustive.oneBitAffineCount, to: &data)
        append(exhaustive.twoBitAffineCount, to: &data)
        append(binary.sectionOffsets.rawState, to: &data)
        append(binary.sectionOffsets.codeword, to: &data)
        append(binary.sectionOffsets.affine, to: &data)
        append(binary.fileSize, to: &data)
        precondition(data.count == Int(headerSize))
    }

    private static func appendRawStateRecords(to data: inout Data) {
        for raw in UInt16(0)..<UInt16(rawStateCount) {
            let state = ASHState(validatedRawValue: raw)
            let payloadParity = UInt8((raw >> 1).nonzeroBitCount & 1)
            append(raw, to: &data)
            data.append(payloadParity)
            data.append(state.hasValidIntegrity ? 1 : 0)
        }
        precondition(data.count == Int(codewordRecordsOffset))
    }

    private static func appendCodewordRecords(to data: inout Data) {
        for rawMessage in UInt8(0)..<UInt8(codewordCount) {
            let message = ASHMessage(validatedRawValue: rawMessage)
            let codeword = ASHCode.encode(message)
            data.append(rawMessage)
            data.append(UInt8(codeword.rawValue.nonzeroBitCount))
            append(codeword.rawValue, to: &data)
        }
        precondition(data.count == Int(affineRecordsOffset))
    }

    private static func appendAffineRecords(to data: inout Data) {
        let anchors = (UInt16(0)..<UInt16(rawStateCount))
            .map(ASHState.init(validatedRawValue:))
            .filter(\.hasValidIntegrity)
        precondition(anchors.count == Int(validAnchorCount))

        for anchor in anchors {
            for rawMessage in UInt8(0)..<UInt8(codewordCount) {
                let message = ASHMessage(validatedRawValue: rawMessage)
                appendAffineRecord(
                    anchor: anchor,
                    message: message,
                    firstFaultCoordinate: 0,
                    secondFaultCoordinate: 0,
                    to: &data
                )
            }
        }

        for anchor in anchors {
            for rawMessage in UInt8(0)..<UInt8(codewordCount) {
                let message = ASHMessage(validatedRawValue: rawMessage)
                for coordinate in 1...ASHState.bitCount {
                    appendAffineRecord(
                        anchor: anchor,
                        message: message,
                        firstFaultCoordinate: UInt8(coordinate),
                        secondFaultCoordinate: 0,
                        to: &data
                    )
                }
            }
        }

        for anchor in anchors {
            for rawMessage in UInt8(0)..<UInt8(codewordCount) {
                let message = ASHMessage(validatedRawValue: rawMessage)
                for firstCoordinate in 1..<ASHState.bitCount {
                    for secondCoordinate in (firstCoordinate + 1)...ASHState.bitCount {
                        appendAffineRecord(
                            anchor: anchor,
                            message: message,
                            firstFaultCoordinate: UInt8(firstCoordinate),
                            secondFaultCoordinate: UInt8(secondCoordinate),
                            to: &data
                        )
                    }
                }
            }
        }
    }

    private static func appendAffineRecord(
        anchor: ASHState,
        message: ASHMessage,
        firstFaultCoordinate: UInt8,
        secondFaultCoordinate: UInt8,
        to data: inout Data
    ) {
        let codeword = ASHCode.encode(message)
        let transmitted = anchor.xor(codeword)
        let faultCoordinates = [firstFaultCoordinate, secondFaultCoordinate].filter { $0 != 0 }
        let received = faultCoordinates.reduce(transmitted) { state, coordinate in
            state.toggled(coordinate: Int(coordinate))
        }
        let decoded = ASHCode.decodeAffine(received: received, anchor: anchor)
        let faultCount = UInt8(faultCoordinates.count)
        let correctedCoordinate = faultCount == 1 ? firstFaultCoordinate : 0
        let expectedStatus: ASHDecodeStatus
        switch faultCount {
        case 0:
            expectedStatus = .exact
        case 1:
            expectedStatus = .corrected
        case 2:
            expectedStatus = .uncorrectable
        default:
            preconditionFailure("Unsupported affine fault count.")
        }
        precondition(decoded.status == expectedStatus)
        precondition(decoded.distance == Int(faultCount))
        if expectedStatus == .uncorrectable {
            precondition(decoded.codeword == nil)
            precondition(decoded.messageBits == nil)
        } else {
            precondition(decoded.codeword == transmitted)
            precondition(decoded.messageBits == message.bits)
        }

        append(anchor.rawValue, to: &data)
        data.append(message.rawValue)
        data.append(faultCount)
        data.append(firstFaultCoordinate)
        data.append(secondFaultCoordinate)
        append(codeword.rawValue, to: &data)
        append(transmitted.rawValue, to: &data)
        append(received.rawValue, to: &data)
        data.append(statusCode(decoded.status).rawValue)
        data.append(correctedCoordinate)
        data.append(byte(decoded.distance))
        data.append(byte(decoded.nearestCount))
    }

    private static func statusCode(_ status: ASHDecodeStatus) -> StatusCode {
        switch status {
        case .exact:
            return .exact
        case .corrected:
            return .corrected
        case .uncorrectable:
            return .rejected
        }
    }

    private static func byte(_ value: Int) -> UInt8 {
        guard let result = UInt8(exactly: value) else {
            preconditionFailure("Conformance value does not fit in one byte.")
        }
        return result
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
