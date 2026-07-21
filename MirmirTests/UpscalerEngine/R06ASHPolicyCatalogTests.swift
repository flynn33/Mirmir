import XCTest
@testable import Mirmir

final class R06ASHPolicyCatalogTests: XCTestCase {
    func testCatalogIdentityOrderAndUniquenessAreFrozen() {
        let expectedIDs: [R06ASHPolicyProfileID] = [
            .message00,
            .message01,
            .message02,
            .message03,
            .message04,
            .message05,
            .message06,
            .message07,
            .message08,
            .message09,
            .message10,
            .message11,
            .message12,
            .message13,
            .message14,
            .message15
        ]
        let profiles = R06ASHPolicyCatalog.profiles

        XCTAssertEqual(R06ASHPolicyCatalog.version, "r06.policy.v1")
        XCTAssertEqual(R06ASHPolicyProfileID.allCases, expectedIDs)
        XCTAssertEqual(profiles.map(\.id), expectedIDs)
        XCTAssertEqual(
            profiles.map(\.message.rawValue),
            (0..<16).map { UInt8($0) }
        )
        XCTAssertEqual(Set(profiles.map(\.id)).count, 16)
        XCTAssertEqual(Set(profiles.map(\.message)).count, 16)
        XCTAssertEqual(Set(profiles).count, 16)

        for profile in profiles {
            XCTAssertEqual(
                R06ASHPolicyCatalog.profile(for: profile.message),
                profile
            )
        }
    }

    func testAllSixteenProfilesMapMSBFirstBitsToExactPolicyAxes() throws {
        for rawValue in UInt8(0)..<UInt8(16) {
            let message = try ASHMessage(rawValue: rawValue)
            let profile = R06ASHPolicyCatalog.profile(for: message)
            let bits = message.bits
            let suffix = rawValue < 10 ? "0\(rawValue)" : "\(rawValue)"

            XCTAssertEqual(profile.id.rawValue, "policy.message.\(suffix)")
            XCTAssertEqual(profile.message, message)
            XCTAssertEqual(profile.denoise, bits[0] == 0 ? .off : .low)
            XCTAssertEqual(
                profile.primaryBackendPreference,
                bits[1] == 0 ? .spatial : .temporal
            )
            XCTAssertEqual(
                profile.postprocess,
                bits[2] == 0 ? .conservative : .detailOriented
            )
            XCTAssertEqual(
                profile.temporalHistory,
                bits[3] == 0 ? .retain : .reset
            )
        }
    }

    func testEverySingleBitPerturbationChangesExactlyItsMappedPolicyAxis() throws {
        for rawValue in UInt8(0)..<UInt8(16) {
            let message = try ASHMessage(rawValue: rawValue)
            let profile = R06ASHPolicyCatalog.profile(for: message)

            for bitIndex in 0..<ASHMessage.bitCount {
                let toggledMessage = try message.toggled(bitIndex: bitIndex)
                let toggledProfile = R06ASHPolicyCatalog.profile(for: toggledMessage)
                let changedAxes = [
                    profile.denoise != toggledProfile.denoise,
                    profile.primaryBackendPreference
                        != toggledProfile.primaryBackendPreference,
                    profile.postprocess != toggledProfile.postprocess,
                    profile.temporalHistory != toggledProfile.temporalHistory
                ]

                XCTAssertEqual(
                    changedAxes.filter { $0 }.count,
                    1,
                    "Message \(rawValue), bit \(bitIndex) changed multiple axes"
                )
                XCTAssertTrue(
                    changedAxes[bitIndex],
                    "Message \(rawValue), bit \(bitIndex) changed the wrong axis"
                )
            }
        }
    }
}
