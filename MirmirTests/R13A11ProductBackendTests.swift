import XCTest
@testable import Mirmir

final class R13A11ProductBackendTests: XCTestCase {
    func testDefaultSessionFactoryProcessesGenuineProductA11FramesForBothRoutes()
        async throws {
        for route in R03ScaleRoute.allCases {
            let binding = try await R13A11ProductSessionFactory.makeSession(
                route: route
            )

            XCTAssertEqual(binding.route, route)
            XCTAssertEqual(
                binding.routeIdentity.backend.backendID,
                R03A11ProductAdmission.subjectID.rawValue
            )
            XCTAssertEqual(
                binding.routeIdentity.policyIdentity,
                R03A11ProductAdmission.policyIdentity
            )
            XCTAssertEqual(
                binding.routeIdentity.materialDecisionIdentity,
                R03A11ProductAdmission.materialDecisionIdentity
            )
            XCTAssertEqual(
                binding.routeIdentity.backend.modelAssetsIdentity,
                .notRequired
            )
            let fixture = try R03DeterministicBackendTestSupport
                .makeInputFrame(
                    route: route,
                    sequenceNumber: 0,
                    seed: 13,
                    tokenPrefix: "r13.default.\(route.rawValue)"
                )
            let outcome = await binding.session.submit(fixture.frame)
            guard case .processed(let processed) = outcome else {
                await binding.session.cancel()
                return XCTFail(
                    "The default A11 session did not process "
                        + "\(route.rawValue)."
                )
            }
            XCTAssertEqual(processed.sequenceNumber, 0)
            XCTAssertEqual(
                processed.presentationTimestamp,
                fixture.frame.presentationTimestamp
            )
            XCTAssertEqual(processed.duration, fixture.frame.duration)
            XCTAssertEqual(
                processed.metadataIdentity,
                fixture.frame.metadataIdentity
            )
            XCTAssertEqual(
                processed.processingIdentity,
                try binding.processingIdentity
            )
            try R03NV12Contract.validate(
                pixelBuffer: processed.pixelBuffer,
                resolution: route.canonicalTargetResolution
            )
            XCTAssertTrue(fixture.frame.resourceLifetimeToken.isReleased)
            XCTAssertFalse(processed.resourceLifetimeToken.isReleased)
            processed.resourceLifetimeToken.release()
            XCTAssertTrue(processed.resourceLifetimeToken.isReleased)
            let summary = await binding.session.finish()
            XCTAssertEqual(summary.submittedFrameCount, 1)
            XCTAssertEqual(summary.processedFrameCount, 1)
            XCTAssertEqual(summary.terminalizationCount, 1)
        }
    }
}
