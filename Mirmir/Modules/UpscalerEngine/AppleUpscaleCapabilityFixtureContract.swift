import CryptoKit
import Foundation

struct R01FixtureCatalog: Decodable, Sendable {
    let schemaVersion: String
    let phaseID: String
    let generatorContract: R01FixtureGeneratorContract
    let fixtures: [R01FixtureRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case phaseID = "phase_id"
        case generatorContract = "generator_contract"
        case fixtures
    }

    func validated() throws -> R01FixtureCatalog {
        guard schemaVersion == "1.0.0", phaseID == "R01" else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        try generatorContract.validate()
        let expectedIDs = [
            "scaler-720p", "scaler-1080p", "support-frame", "support-guidance",
            "support-history", "temporal-frame-0", "temporal-frame-1",
            "cadence-frame-0", "cadence-frame-1", "analysis-proxy",
            "analysis-probe-model"
        ]
        guard fixtures.map(\.id) == expectedIDs else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }

        for fixture in fixtures.dropLast() {
            guard fixture.status == "frozen",
                  fixture.generator == "r01-analytic-pixel-v1",
                  fixture.materializationPath ==
                    "project-notes/evidence/r01/fixtures/\(fixture.id).bin",
                  let expectedSize = fixture.byteCount,
                  let expectedHash = fixture.contentSHA256 else {
                throw R01LiveReportError.fixtureCatalogNotClosed
            }
            let generated = try R01DeterministicFixtureGenerator.materialize(fixture)
            guard generated.count == expectedSize,
                  R01SHA256.hexDigest(generated) == expectedHash else {
                throw R01LiveReportError.fixtureGeneratorDrift(fixture.id)
            }
        }
        return self
    }

    func fixture(id: String) throws -> R01FixtureRecord {
        guard let fixture = fixtures.first(where: { $0.id == id }) else {
            throw R01LiveReportError.fixtureMissing(id)
        }
        return fixture
    }
}

struct R01FixtureGeneratorContract: Decodable, Sendable {
    let id: String
    let byteOrder: String
    let nv12LumaFormula: String
    let nv12CBFormula: String
    let nv12CRFormula: String
    let gray8Formula: String
    let bgraFormula: String

    enum CodingKeys: String, CodingKey {
        case id
        case byteOrder = "byte_order"
        case nv12LumaFormula = "nv12_luma_formula"
        case nv12CBFormula = "nv12_cb_formula"
        case nv12CRFormula = "nv12_cr_formula"
        case gray8Formula = "gray8_formula"
        case bgraFormula = "bgra_formula"
    }

    func validate() throws {
        let expected = R01FixtureGeneratorContract(
            id: "r01-analytic-pixel-v1",
            byteOrder: "row_major_planes_in_declared_pixel_format_order",
            nv12LumaFormula: "16+((13*x+17*y+19*i+((x*y)%31))%220)",
            nv12CBFormula: "16+((7*cx+11*cy+23*i+((cx*cy)%29))%225)",
            nv12CRFormula: "16+((5*cx+19*cy+31*i+((cx+cy)%37))%225)",
            gray8Formula: "(3*x+5*y+7*i+((x*y)%251))%256",
            bgraFormula: "B=(3*x+5*y+11*i)%256;G=(7*x+2*y+13*i)%256;R=(x+9*y+17*i)%256;A=255"
        )
        guard id == expected.id,
              byteOrder == expected.byteOrder,
              nv12LumaFormula == expected.nv12LumaFormula,
              nv12CBFormula == expected.nv12CBFormula,
              nv12CRFormula == expected.nv12CRFormula,
              gray8Formula == expected.gray8Formula,
              bgraFormula == expected.bgraFormula else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
    }
}

struct R01FixtureRecord: Decodable, Sendable {
    let id: String
    let status: String
    let role: String
    let mediaKind: String
    let dimensions: R01Dimensions?
    let pixelFormat: String?
    let colorContract: R01FixtureColorContract?
    let frameIndex: Int?
    let scaleOutput: R01Dimensions?
    let timing: R01FixtureTiming?
    let generator: String?
    let materializationPath: String?
    let byteCount: Int?
    let contentSHA256: String?
    let modelIdentity: String?

    enum CodingKeys: String, CodingKey {
        case id, status, role
        case mediaKind = "media_kind"
        case dimensions
        case pixelFormat = "pixel_format"
        case colorContract = "color_contract"
        case frameIndex = "frame_index"
        case scaleOutput = "scale_output"
        case timing, generator
        case materializationPath = "materialization_path"
        case byteCount = "byte_count"
        case contentSHA256 = "content_sha256"
        case modelIdentity = "model_identity"
    }
}

struct R01Dimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int

    var closedString: String { "\(width)x\(height)" }
}

struct R01FixtureColorContract: Decodable, Sendable {
    let chromaSiting: String
    let colorPrimaries: String
    let matrix: String
    let range: String
    let transferFunction: String

    enum CodingKeys: String, CodingKey {
        case chromaSiting = "chroma_siting"
        case colorPrimaries = "color_primaries"
        case matrix, range
        case transferFunction = "transfer_function"
    }
}

struct R01FixtureTiming: Decodable, Sendable {
    let pts: Int
    let duration: Int
    let timescale: Int
}

enum R01DeterministicFixtureGenerator {
    static func materialize(_ fixture: R01FixtureRecord) throws -> Data {
        guard let dimensions = fixture.dimensions,
              dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= 8_192, dimensions.height <= 8_192,
              let frameIndex = fixture.frameIndex, frameIndex >= 0 else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        switch fixture.mediaKind {
        case "nv12_frame":
            return try nv12(dimensions: dimensions, frameIndex: frameIndex)
        case "gray8_plane":
            return try gray8(dimensions: dimensions, frameIndex: frameIndex)
        case "bgra_frame":
            return try bgra(dimensions: dimensions, frameIndex: frameIndex)
        default:
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
    }

    private static func nv12(dimensions: R01Dimensions, frameIndex: Int) throws -> Data {
        guard dimensions.width.isMultiple(of: 2), dimensions.height.isMultiple(of: 2) else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        let lumaCount = try checkedCount(dimensions.width, dimensions.height)
        let totalCount = try checkedAdd(lumaCount, lumaCount / 2)
        var data = Data(count: totalCount)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for yPosition in 0..<dimensions.height {
                for xPosition in 0..<dimensions.width {
                    let xTerm = 13 * xPosition
                    let yTerm = 17 * yPosition
                    let frameTerm = 19 * frameIndex
                    let crossTerm = (xPosition * yPosition) % 31
                    let value = 16 + (xTerm + yTerm + frameTerm + crossTerm) % 220
                    bytes[yPosition * dimensions.width + xPosition] = UInt8(value)
                }
            }
            for chromaY in 0..<(dimensions.height / 2) {
                for chromaX in 0..<(dimensions.width / 2) {
                    let offset = lumaCount + chromaY * dimensions.width + chromaX * 2
                    let cbBase = 7 * chromaX + 11 * chromaY + 23 * frameIndex
                    let cbCross = (chromaX * chromaY) % 29
                    bytes[offset] = UInt8(16 + (cbBase + cbCross) % 225)
                    let crBase = 5 * chromaX + 19 * chromaY + 31 * frameIndex
                    let crCross = (chromaX + chromaY) % 37
                    bytes[offset + 1] = UInt8(16 + (crBase + crCross) % 225)
                }
            }
        }
        return data
    }

    private static func gray8(dimensions: R01Dimensions, frameIndex: Int) throws -> Data {
        var data = Data(count: try checkedCount(dimensions.width, dimensions.height))
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for yPosition in 0..<dimensions.height {
                for xPosition in 0..<dimensions.width {
                    let base = 3 * xPosition + 5 * yPosition + 7 * frameIndex
                    let cross = (xPosition * yPosition) % 251
                    bytes[yPosition * dimensions.width + xPosition] = UInt8((base + cross) % 256)
                }
            }
        }
        return data
    }

    private static func bgra(dimensions: R01Dimensions, frameIndex: Int) throws -> Data {
        let pixelCount = try checkedCount(dimensions.width, dimensions.height)
        var data = Data(count: try checkedAdd(pixelCount, pixelCount * 3))
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for yPosition in 0..<dimensions.height {
                for xPosition in 0..<dimensions.width {
                    let offset = (yPosition * dimensions.width + xPosition) * 4
                    let blue = 3 * xPosition + 5 * yPosition + 11 * frameIndex
                    let green = 7 * xPosition + 2 * yPosition + 13 * frameIndex
                    let red = xPosition + 9 * yPosition + 17 * frameIndex
                    bytes[offset] = UInt8(blue % 256)
                    bytes[offset + 1] = UInt8(green % 256)
                    bytes[offset + 2] = UInt8(red % 256)
                    bytes[offset + 3] = 255
                }
            }
        }
        return data
    }

    private static func checkedCount(_ first: Int, _ second: Int) throws -> Int {
        let result = first.multipliedReportingOverflow(by: second)
        guard !result.overflow, result.partialValue <= 25 * 1_024 * 1_024 else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        return result.partialValue
    }

    private static func checkedAdd(_ first: Int, _ second: Int) throws -> Int {
        let result = first.addingReportingOverflow(second)
        guard !result.overflow, result.partialValue <= 25 * 1_024 * 1_024 else {
            throw R01LiveReportError.fixtureCatalogNotClosed
        }
        return result.partialValue
    }
}

enum R01SHA256 {
    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
