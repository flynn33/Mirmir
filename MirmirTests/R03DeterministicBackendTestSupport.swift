import CoreMedia
import CoreVideo
import Foundation
@testable import Mirmir

enum R03DeterministicBackendTestSupportError: Error {
    case sessionNotCreated
}

struct R03InputFrameFixture {
    let frame: AppleUpscaleFrame
    let releaseProbe: R02FixtureReleaseProbe
    let tokenIdentity: String
}

enum R03DeterministicBackendTestSupport {
    static func makeContext(
        subjectID: R03BaselineSubjectID,
        admissionScope: AppleUpscaleAdmissionScope = .fixtureOnly,
        capability: AppleUpscaleCapability? = nil,
        policyIdentity: String = R03DeterministicBackendCatalog.policyIdentity
    ) throws -> AppleUpscaleSessionContext {
        let capability = try capability
            ?? R03DeterministicBackendCatalog.makeFixtureCapability(for: subjectID)
        return try AppleUpscaleSessionContext(
            capabilityRegistry: AppleUpscaleCapabilityRegistry(
                capabilities: [capability]
            ),
            admissionScope: admissionScope,
            policyIdentity: policyIdentity
        )
    }

    static func makeSession(
        backend: R03DeterministicBackend,
        context: AppleUpscaleSessionContext? = nil
    ) async throws -> any AppleUpscaleSession {
        let context = try context ?? makeContext(subjectID: backend.subject.id)
        let creation = await backend.makeSession(
            configuration: try backend.makeConfiguration(),
            context: context
        )
        guard case .created(let session) = creation else {
            throw R03DeterministicBackendTestSupportError.sessionNotCreated
        }
        return session
    }

    static func makeInputFrame(
        route: R03ScaleRoute,
        sequenceNumber: Int,
        seed: Int = 37,
        tokenPrefix: String = "r03.input"
    ) throws -> R03InputFrameFixture {
        let resolution = route.canonicalSourceResolution
        let payload = try R02FixtureGenerators.nv12FrameBytes(
            width: resolution.width,
            height: resolution.height,
            seed: seed,
            sequenceNumber: 0
        )
        let pixelBuffer = try R02FixturePixelBuffers.makeNV12(
            width: resolution.width,
            height: resolution.height,
            logicalBytes: payload
        )
        let releaseProbe = R02FixtureReleaseProbe()
        let tokenIdentity = "\(tokenPrefix).\(sequenceNumber)"
        let token = try AppleUpscaleResourceLifetimeToken(
            identity: tokenIdentity,
            releaseAction: { [releaseProbe] in
                releaseProbe.recordRelease(identity: tokenIdentity)
            }
        )
        let frame = try AppleUpscaleFrame(
            sequenceNumber: sequenceNumber,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: CMTime(value: Int64(sequenceNumber + 30), timescale: 30),
            duration: CMTime(value: 1, timescale: 30),
            colorDescription: R03NV12Contract.makeColorDescription(),
            metadataIdentity: AppleUpscaleMetadataIdentity(
                "r03.metadata.\(sequenceNumber)"
            ),
            resourceLifetimeToken: token
        )
        return R03InputFrameFixture(
            frame: frame,
            releaseProbe: releaseProbe,
            tokenIdentity: tokenIdentity
        )
    }
}
