import Foundation

enum R06ASHDenoise: String, CaseIterable, Hashable, Sendable {
    case off
    case low
}

enum R06ASHPrimaryPreference: String, CaseIterable, Hashable, Sendable {
    case spatial
    case temporal
}

enum R06ASHPostprocess: String, CaseIterable, Hashable, Sendable {
    case conservative
    case detailOriented = "detail_oriented"
}

enum R06ASHTemporalHistory: String, CaseIterable, Hashable, Sendable {
    case retain
    case reset
}

enum R06ASHPolicyProfileID: String, CaseIterable, Hashable, Sendable {
    case message00 = "policy.message.00"
    case message01 = "policy.message.01"
    case message02 = "policy.message.02"
    case message03 = "policy.message.03"
    case message04 = "policy.message.04"
    case message05 = "policy.message.05"
    case message06 = "policy.message.06"
    case message07 = "policy.message.07"
    case message08 = "policy.message.08"
    case message09 = "policy.message.09"
    case message10 = "policy.message.10"
    case message11 = "policy.message.11"
    case message12 = "policy.message.12"
    case message13 = "policy.message.13"
    case message14 = "policy.message.14"
    case message15 = "policy.message.15"

    fileprivate var messageRawValue: UInt8 {
        guard let value = UInt8(String(rawValue.suffix(2))), value < 16 else {
            preconditionFailure("Every frozen R06 profile ID must end in its two-digit message value")
        }
        return value
    }
}

struct R06ASHPolicyProfile: Hashable, Sendable {
    let id: R06ASHPolicyProfileID
    let message: ASHMessage
    let denoise: R06ASHDenoise
    let primaryBackendPreference: R06ASHPrimaryPreference
    let postprocess: R06ASHPostprocess
    let temporalHistory: R06ASHTemporalHistory

    fileprivate init(
        id: R06ASHPolicyProfileID,
        message: ASHMessage,
        denoise: R06ASHDenoise,
        primaryBackendPreference: R06ASHPrimaryPreference,
        postprocess: R06ASHPostprocess,
        temporalHistory: R06ASHTemporalHistory
    ) {
        self.id = id
        self.message = message
        self.denoise = denoise
        self.primaryBackendPreference = primaryBackendPreference
        self.postprocess = postprocess
        self.temporalHistory = temporalHistory
    }
}

enum R06ASHPolicyCatalog {
    static let version = "r06.policy.v1"
    static let profiles: [R06ASHPolicyProfile] = makeProfiles()

    static func profile(for message: ASHMessage) -> R06ASHPolicyProfile {
        let index = Int(message.rawValue)
        precondition(
            profiles.indices.contains(index),
            "Every valid ASHMessage must have one frozen R06 policy profile"
        )
        return profiles[index]
    }

    private static func makeProfiles() -> [R06ASHPolicyProfile] {
        let profiles = R06ASHPolicyProfileID.allCases.map { id in
            let message = ASHMessage(validatedRawValue: id.messageRawValue)
            let bits = message.bits
            return R06ASHPolicyProfile(
                id: id,
                message: message,
                denoise: bits[0] == 0 ? .off : .low,
                primaryBackendPreference: bits[1] == 0 ? .spatial : .temporal,
                postprocess: bits[2] == 0 ? .conservative : .detailOriented,
                temporalHistory: bits[3] == 0 ? .retain : .reset
            )
        }
        let expectedRawValues = (0..<(1 << ASHMessage.bitCount)).map { UInt8($0) }
        precondition(
            profiles.map(\.message.rawValue) == expectedRawValues,
            "The frozen R06 policy catalog must cover ASHMessage values 0 through 15 in order"
        )
        precondition(
            Set(profiles.map(\.id)).count == expectedRawValues.count,
            "The frozen R06 policy catalog must contain unique profile identities"
        )
        return profiles
    }
}
