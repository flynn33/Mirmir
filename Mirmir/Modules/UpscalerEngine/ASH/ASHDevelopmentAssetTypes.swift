import Foundation

struct ASHVideoMappingV2SeedAsset: Decodable, Sendable {
    let schemaVersion: String
    let mappingId: String
    let status: String
    let canonicalCoreUnchanged: Bool
    let payloadBits: [ASHVideoPayloadBitSeedAsset]
    let integrityBit: ASHVideoPayloadBitSeedAsset
}

struct ASHVideoPayloadBitSeedAsset: Decodable, Sendable {
    let bit: Int
    let name: String
}

struct ASHOperatorBankV2SeedAsset: Decodable, Sendable {
    let schemaVersion: String
    let bankId: String
    let axes: [ASHOperatorAxisSeedAsset]
    let coordinateMappingCandidates: [ASHCoordinateMappingSeedAsset]
}

struct ASHOperatorAxisSeedAsset: Decodable, Equatable, Sendable {
    let bit: Int
    let name: String
    let zero: String
    let one: String
}

struct ASHCoordinateMappingSeedAsset: Decodable, Sendable {
    let id: String
}
