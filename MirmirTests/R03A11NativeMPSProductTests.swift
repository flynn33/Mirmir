import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

// The qualification transaction remains contiguous so its emitted contract is auditable.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class R03A11NativeMPSProductTests: XCTestCase {
    func testStrictNativeMPSLanczosIsRepeatableAcrossThreeFreshSessionsForBothRoutes()
        async throws {
        let evidenceRequest = try R03A11QualificationRouteEvidenceEmitter.freezeRequest()
        var backendIdentity: R03A11QualificationBackendIdentity?
        var routeEvidence: [R03A11QualificationRouteEvidence] = []
        for route in R03ScaleRoute.allCases {
            var captures: [R03A11NativeRunCapture] = []
            for run in 1...3 {
                captures.append(
                    try await runStrictNativeSession(route: route, run: run)
                )
            }
            let observedRoute = try makeRouteEvidence(captures: captures)
            routeEvidence.append(observedRoute)
            if let existingIdentity = backendIdentity {
                try require(
                    existingIdentity == captures[0].backendIdentity,
                    "backend identity changed between routes"
                )
            } else {
                backendIdentity = captures[0].backendIdentity
            }
        }
        guard let backendIdentity else {
            throw R03A11NativeMPSTestError.evidenceMismatch(
                "both native routes produced no backend identity"
            )
        }
        try require(
            routeEvidence.map(\.routeID) == R03ScaleRoute.allCases.map(\.rawValue),
            "route evidence order or identity changed"
        )
        if let evidenceRequest {
            try R03A11QualificationRouteEvidenceEmitter.emit(
                R03A11QualificationRouteEvidenceDocument(
                    schemaVersion: "1.0.0",
                    evidenceKind: "r03_a11_native_route_observations_v1",
                    qualificationInvocation: evidenceRequest.qualificationInvocation,
                    backendIdentity: backendIdentity,
                    routes: routeEvidence
                ),
                request: evidenceRequest
            )
        }
    }

    // Keeping session creation, native processing, and evidence capture together prevents
    // a partial run from being mistaken for a qualification observation.
    // swiftlint:disable:next function_body_length
    private func runStrictNativeSession(
        route: R03ScaleRoute,
        run: Int
    ) async throws -> R03A11NativeRunCapture {
        let outputReleaseProbe = R02FixtureReleaseProbe()
        let historyGenerationProbe = R03A11HistoryGenerationProbe()
        let backend = try R03DeterministicBackend.makeProductQualifiedMPSLanczos(
            route: route,
            outputReleaseObserver: { [outputReleaseProbe] identity in
                outputReleaseProbe.recordRelease(identity: identity)
            },
            historyGenerationObserver: { [historyGenerationProbe] observation in
                historyGenerationProbe.record(observation)
            }
        )
        let configuration = try backend.makeConfiguration()
        try validateConfiguration(configuration, backend: backend, route: route)

        let creation = await backend.makeSession(
            configuration: configuration,
            context: try R03A11ProductAdmission.makeProductSessionContext()
        )
        let session: any AppleUpscaleSession
        switch creation {
        case .created(let createdSession):
            session = createdSession
        case .unavailable(let unavailable):
            XCTFail(
                "Strict native MPS creation was unavailable: \(unavailable.reason)"
            )
            throw R03A11NativeMPSTestError.nativeSessionNotCreated
        case .rejected(let rejection):
            XCTFail("Strict native MPS creation was rejected: \(rejection.reason)")
            throw R03A11NativeMPSTestError.nativeSessionNotCreated
        case .failed(let failure):
            XCTFail("Strict native MPS creation failed: \(failure.reason)")
            throw R03A11NativeMPSTestError.nativeSessionNotCreated
        }

        let sessionIdentity = await session.identity
        try require(
            sessionIdentity == backend.routeIdentity,
            "session route identity differed from the product backend"
        )
        await session.reset(reason: AppleUpscaleResetReason.callerRequested)
        await session.reset(reason: AppleUpscaleResetReason.callerRequested)
        let fixture = try R03DeterministicBackendTestSupport.makeInputFrame(
            route: route,
            sequenceNumber: 0,
            seed: 91,
            tokenPrefix: "r03.a11.native.\(route.rawValue).run-\(run)"
        )
        let outcome = await session.submit(fixture.frame)
        guard case .processed(let processed) = outcome else {
            XCTFail("Strict native MPS did not process \(route.rawValue) run \(run)")
            throw R03A11NativeMPSTestError.nativeFrameNotProcessed
        }

        try validateProcessedFrame(
            processed,
            fixture: fixture,
            backend: backend,
            route: route
        )

        let logicalInputBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
            from: fixture.frame.pixelBuffer
        )
        let logicalBytes = try R02FixturePixelBuffers.logicalNV12Bytes(
            from: processed.pixelBuffer
        )
        try require(
            logicalBytes.count,
            equals: route.canonicalTargetResolution.width
                * route.canonicalTargetResolution.height * 3 / 2,
            field: "logical output byte count"
        )
        let logicalHash = R02FixtureGenerators.sha256Hex(logicalBytes)
        let outputTokenIdentity = processed.resourceLifetimeToken.identity
        try require(
            !processed.resourceLifetimeToken.isReleased,
            "output token was released before consumer release"
        )
        processed.resourceLifetimeToken.release()
        processed.resourceLifetimeToken.release()
        let inputReleaseCount = fixture.releaseProbe.releaseCount(
            for: fixture.tokenIdentity
        )
        let outputReleaseCount = outputReleaseProbe.releaseCount(
            for: outputTokenIdentity
        )
        try require(inputReleaseCount, equals: 1, field: "input release count")
        try require(outputReleaseCount, equals: 1, field: "output release count")
        try require(
            processed.resourceLifetimeToken.isReleased,
            "output token did not reach its released state"
        )

        let firstSummary = await session.finish()
        let secondSummary = await session.finish()
        await session.reset(reason: AppleUpscaleResetReason.callerRequested)
        await session.reset(reason: AppleUpscaleResetReason.callerRequested)
        let postResetSummary = await session.finish()
        await session.cancel()
        await session.cancel()
        let postCancelSummary = await session.finish()
        try require(firstSummary.submittedFrameCount, equals: 1, field: "submitted count")
        try require(firstSummary.processedFrameCount, equals: 1, field: "processed count")
        try require(
            firstSummary.terminalizationCount,
            equals: 1,
            field: "terminalization count"
        )
        try require(
            firstSummary == secondSummary && firstSummary == postResetSummary
                && firstSummary == postCancelSummary,
            "finish, reset, or cancel changed the terminal summary"
        )
        let historyGenerations = historyGenerationProbe.snapshot()
        try require(
            historyGenerations.resetNextHistoryGenerations == [1, 2],
            "completed reset generations differed"
        )
        guard historyGenerations.processHistoryGenerations == [2],
              let processedHistoryGeneration =
                historyGenerations.processHistoryGenerations.first else {
            throw R03A11NativeMPSTestError.evidenceMismatch(
                "processed history generation differed"
            )
        }

        let inputIdentity = try makeFrameIdentity(
            fixture.frame.pixelBuffer,
            color: fixture.frame.colorDescription
        )
        let outputIdentity = try makeFrameIdentity(
            processed.pixelBuffer,
            color: processed.colorDescription
        )
        let backendIdentity = try makeBackendIdentity(backend)
        return R03A11NativeRunCapture(
            routeID: route.rawValue,
            configurationIdentity: configuration.configurationIdentity,
            inputIdentity: inputIdentity,
            outputIdentity: outputIdentity,
            backendIdentity: backendIdentity,
            observation: R03A11QualificationRunEvidence(
                runOrdinal: run,
                logicalInputSHA256: R02FixtureGenerators.sha256Hex(logicalInputBytes),
                logicalOutputSHA256: logicalHash,
                sequenceNumber: processed.sequenceNumber,
                presentationTimestamp: makeTimeEvidence(
                    processed.presentationTimestamp
                ),
                duration: makeTimeEvidence(processed.duration),
                metadataIdentity: processed.metadataIdentity.rawValue,
                inputTokenIdentity: fixture.tokenIdentity,
                outputTokenIdentity: outputTokenIdentity,
                frameOrderPreserved: true,
                ptsPreserved: true,
                durationPreserved: true,
                metadataPreserved: true,
                lifecycleObservation: R03A11QualificationLifecycleEvidence(
                    inputReleaseCount: inputReleaseCount,
                    outputReleaseCount: outputReleaseCount,
                    terminalizationCount: firstSummary.terminalizationCount,
                    preSubmitResetOperations:
                        historyGenerations.resetNextHistoryGenerations.count,
                    postTerminalResetOperations: 2,
                    finishOperations: 4,
                    cancelOperations: 2,
                    resetNextHistoryGenerations:
                        historyGenerations.resetNextHistoryGenerations,
                    processedHistoryGeneration: processedHistoryGeneration,
                    finishIdempotent: true,
                    cancelIdempotent: true
                ),
                fallbackHistory: []
            )
        )
    }

    private func validateConfiguration(
        _ configuration: AppleUpscaleSessionConfiguration,
        backend: R03DeterministicBackend,
        route: R03ScaleRoute
    ) throws {
        try require(configuration.capabilityID.rawValue, equals: "A11", field: "capability")
        try require(
            configuration.sourceResolution,
            equals: route.canonicalSourceResolution,
            field: "source resolution"
        )
        try require(
            configuration.targetResolution,
            equals: route.canonicalTargetResolution,
            field: "target resolution"
        )
        try require(
            configuration.pixelFormat,
            equals: R03NV12Contract.pixelFormat,
            field: "pixel format"
        )
        try require(
            configuration.configurationIdentity,
            equals: backend.routeIdentity.configurationIdentity,
            field: "configuration identity"
        )
    }

    private func validateProcessedFrame(
        _ processed: AppleUpscaleProcessedFrame,
        fixture: R03InputFrameFixture,
        backend: R03DeterministicBackend,
        route: R03ScaleRoute
    ) throws {
        try require(
            processed.sequenceNumber,
            equals: fixture.frame.sequenceNumber,
            field: "sequence number"
        )
        try require(
            processed.presentationTimestamp,
            equals: fixture.frame.presentationTimestamp,
            field: "presentation timestamp"
        )
        try require(processed.duration, equals: fixture.frame.duration, field: "duration")
        try require(
            processed.colorDescription,
            equals: fixture.frame.colorDescription,
            field: "color description"
        )
        try require(
            processed.metadataIdentity,
            equals: fixture.frame.metadataIdentity,
            field: "metadata identity"
        )
        try require(
            processed.processingIdentity.route,
            equals: backend.routeIdentity,
            field: "processing route identity"
        )
        try require(
            processed.processingIdentity.fallbackHistory.isEmpty,
            "fallback history was not empty"
        )
        try require(
            processed.processingIdentity.route.policyIdentity,
            equals: R03A11ProductAdmission.policyIdentity,
            field: "policy identity"
        )
        try require(
            processed.processingIdentity.route.materialDecisionIdentity,
            equals: R03A11ProductAdmission.materialDecisionIdentity,
            field: "material decision identity"
        )
        try require(
            CVPixelBufferGetWidth(processed.pixelBuffer),
            equals: route.canonicalTargetResolution.width,
            field: "output width"
        )
        try require(
            CVPixelBufferGetHeight(processed.pixelBuffer),
            equals: route.canonicalTargetResolution.height,
            field: "output height"
        )
        try require(
            CVPixelBufferGetPlaneCount(processed.pixelBuffer),
            equals: 2,
            field: "output plane count"
        )
        try require(
            CVPixelBufferGetPixelFormatType(processed.pixelBuffer),
            equals: R03NV12Contract.pixelFormat,
            field: "output pixel format"
        )
        try R03NV12Contract.validate(
            pixelBuffer: processed.pixelBuffer,
            resolution: route.canonicalTargetResolution
        )
        try require(
            fixture.releaseProbe.releaseCount(for: fixture.tokenIdentity),
            equals: 1,
            field: "input release count"
        )
    }

    private func makeRouteEvidence(
        captures: [R03A11NativeRunCapture]
    ) throws -> R03A11QualificationRouteEvidence {
        guard let first = captures.first else {
            throw R03A11NativeMPSTestError.evidenceMismatch("route had no runs")
        }
        try require(captures.count, equals: 3, field: "route run count")
        try require(
            captures.map(\.observation.runOrdinal) == [1, 2, 3],
            "route run ordinals differed"
        )
        try require(
            Set(captures.map(\.observation.logicalOutputSHA256)).count == 1,
            "route produced more than one logical output hash"
        )
        try require(
            first.observation.logicalOutputSHA256.count == 64,
            "route logical output SHA-256 length differed"
        )
        for capture in captures.dropFirst() {
            try require(capture.routeID, equals: first.routeID, field: "route ID")
            try require(
                capture.configurationIdentity,
                equals: first.configurationIdentity,
                field: "configuration identity"
            )
            try require(
                capture.inputIdentity,
                equals: first.inputIdentity,
                field: "input identity"
            )
            try require(
                capture.outputIdentity,
                equals: first.outputIdentity,
                field: "output identity"
            )
            try require(
                capture.backendIdentity,
                equals: first.backendIdentity,
                field: "backend identity"
            )
        }
        return R03A11QualificationRouteEvidence(
            routeID: first.routeID,
            configurationIdentity: first.configurationIdentity,
            inputIdentity: first.inputIdentity,
            outputIdentity: first.outputIdentity,
            runs: captures.map(\.observation)
        )
    }

    private func makeBackendIdentity(
        _ backend: R03DeterministicBackend
    ) throws -> R03A11QualificationBackendIdentity {
        try require(
            backend.identity.modelAssetsIdentity == .notRequired,
            "A11 unexpectedly required model assets"
        )
        try require(
            backend.subject.frameworkIdentity == "MetalPerformanceShaders",
            "A11 framework identity differed"
        )
        return R03A11QualificationBackendIdentity(
            backendID: backend.identity.backendID,
            backendRevision: backend.identity.backendRevision,
            capabilityID: backend.capabilityID.rawValue,
            frameworkIdentity: backend.subject.frameworkIdentity,
            modelAssetsIdentity: "notRequired",
            policyIdentity: backend.routeIdentity.policyIdentity,
            materialDecisionIdentity: backend.routeIdentity.materialDecisionIdentity
        )
    }

    private func makeFrameIdentity(
        _ pixelBuffer: CVPixelBuffer,
        color: AppleUpscaleColorDescription
    ) throws -> R03A11QualificationFrameIdentity {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fourCC = try pixelFormatFourCC(pixelFormat)
        try require(fourCC, equals: "420v", field: "pixel format FourCC")
        try R03NV12Contract.validate(colorDescription: color)
        try require(
            color.chromaSiting,
            equals: R03NV12Contract.chromaSiting,
            field: "Core Video chroma siting"
        )
        return R03A11QualificationFrameIdentity(
            dimensions: R03A11QualificationDimensions(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            ),
            planeCount: CVPixelBufferGetPlaneCount(pixelBuffer),
            pixelFormat: fourCC,
            pixelFormatRawValue: pixelFormat,
            colorIdentity: R03A11QualificationColorIdentity(
                primaries: color.colorPrimaries,
                transferFunction: color.transferFunction,
                matrix: color.matrix,
                chromaLocation: "left",
                range: color.range.rawValue
            )
        )
    }

    private func pixelFormatFourCC(_ pixelFormat: OSType) throws -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: pixelFormat >> 24),
            UInt8(truncatingIfNeeded: pixelFormat >> 16),
            UInt8(truncatingIfNeeded: pixelFormat >> 8),
            UInt8(truncatingIfNeeded: pixelFormat)
        ]
        guard let value = String(bytes: bytes, encoding: .ascii) else {
            throw R03A11NativeMPSTestError.evidenceMismatch(
                "pixel format was not a four-character ASCII identity"
            )
        }
        return value
    }

    private func makeTimeEvidence(_ time: CMTime) -> R03A11QualificationTimeEvidence {
        R03A11QualificationTimeEvidence(
            value: time.value,
            timescale: time.timescale,
            flags: time.flags.rawValue,
            epoch: time.epoch
        )
    }

    private func require<Value: Equatable>(
        _ actual: Value,
        equals expected: Value,
        field: String
    ) throws {
        try require(actual == expected, "\(field) differed")
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        _ detail: String
    ) throws {
        guard condition() else {
            throw R03A11NativeMPSTestError.evidenceMismatch(detail)
        }
    }
}

private enum R03A11NativeMPSTestError: Error {
    case nativeSessionNotCreated
    case nativeFrameNotProcessed
    case evidenceMismatch(String)
    case evidenceOutputDirectoryMissing(String)
    case evidenceOutputAlreadyExists(String)
}

private struct R03A11NativeRunCapture {
    let routeID: String
    let configurationIdentity: String
    let inputIdentity: R03A11QualificationFrameIdentity
    let outputIdentity: R03A11QualificationFrameIdentity
    let backendIdentity: R03A11QualificationBackendIdentity
    let observation: R03A11QualificationRunEvidence
}

private struct R03A11QualificationRouteEvidenceDocument: Codable {
    let schemaVersion: String
    let evidenceKind: String
    let qualificationInvocation: R03QualificationInvocation
    let backendIdentity: R03A11QualificationBackendIdentity
    let routes: [R03A11QualificationRouteEvidence]
}

private struct R03A11QualificationBackendIdentity: Codable, Equatable {
    let backendID: String
    let backendRevision: String
    let capabilityID: String
    let frameworkIdentity: String
    let modelAssetsIdentity: String
    let policyIdentity: String
    let materialDecisionIdentity: String
}

private struct R03A11QualificationRouteEvidence: Codable {
    let routeID: String
    let configurationIdentity: String
    let inputIdentity: R03A11QualificationFrameIdentity
    let outputIdentity: R03A11QualificationFrameIdentity
    let runs: [R03A11QualificationRunEvidence]
}

private struct R03A11QualificationFrameIdentity: Codable, Equatable {
    let dimensions: R03A11QualificationDimensions
    let planeCount: Int
    let pixelFormat: String
    let pixelFormatRawValue: OSType
    let colorIdentity: R03A11QualificationColorIdentity
}

private struct R03A11QualificationDimensions: Codable, Equatable {
    let width: Int
    let height: Int
}

private struct R03A11QualificationColorIdentity: Codable, Equatable {
    let primaries: String
    let transferFunction: String
    let matrix: String
    let chromaLocation: String
    let range: String
}

private struct R03A11QualificationRunEvidence: Codable {
    let runOrdinal: Int
    let logicalInputSHA256: String
    let logicalOutputSHA256: String
    let sequenceNumber: Int
    let presentationTimestamp: R03A11QualificationTimeEvidence
    let duration: R03A11QualificationTimeEvidence
    let metadataIdentity: String
    let inputTokenIdentity: String
    let outputTokenIdentity: String
    let frameOrderPreserved: Bool
    let ptsPreserved: Bool
    let durationPreserved: Bool
    let metadataPreserved: Bool
    let lifecycleObservation: R03A11QualificationLifecycleEvidence
    let fallbackHistory: [String]
}

private struct R03A11QualificationTimeEvidence: Codable {
    let value: CMTimeValue
    let timescale: CMTimeScale
    let flags: UInt32
    let epoch: CMTimeEpoch
}

private struct R03A11QualificationLifecycleEvidence: Codable {
    let inputReleaseCount: Int
    let outputReleaseCount: Int
    let terminalizationCount: Int
    let preSubmitResetOperations: Int
    let postTerminalResetOperations: Int
    let finishOperations: Int
    let cancelOperations: Int
    let resetNextHistoryGenerations: [UInt64]
    let processedHistoryGeneration: UInt64
    let finishIdempotent: Bool
    let cancelIdempotent: Bool
}

private struct R03A11HistoryGenerationSnapshot {
    let resetNextHistoryGenerations: [UInt64]
    let processHistoryGenerations: [UInt64]
}

private final class R03A11HistoryGenerationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var resetNextHistoryGenerations: [UInt64] = []
    private var processHistoryGenerations: [UInt64] = []

    func record(_ observation: R03HistoryGenerationObservation) {
        lock.lock()
        defer { lock.unlock() }
        switch observation {
        case .reset(let nextHistoryGeneration):
            resetNextHistoryGenerations.append(nextHistoryGeneration)
        case .process(let historyGeneration):
            processHistoryGenerations.append(historyGeneration)
        }
    }

    func snapshot() -> R03A11HistoryGenerationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return R03A11HistoryGenerationSnapshot(
            resetNextHistoryGenerations: resetNextHistoryGenerations,
            processHistoryGenerations: processHistoryGenerations
        )
    }
}

private struct R03A11QualificationRouteEvidenceRequest {
    let destination: URL
    let qualificationInvocation: R03QualificationInvocation
}

private enum R03A11QualificationRouteEvidenceEmitter {
    static let environmentVariable = "R03_QUALIFICATION_ROUTE_OBSERVATIONS_PATH"

    static func freezeRequest() throws -> R03A11QualificationRouteEvidenceRequest? {
        guard let path = ProcessInfo.processInfo.environment[environmentVariable],
              !path.isEmpty else {
            return nil
        }
        let destination = URL(fileURLWithPath: path)
        let directory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw R03A11NativeMPSTestError.evidenceOutputDirectoryMissing(
                directory.path
            )
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw R03A11NativeMPSTestError.evidenceOutputAlreadyExists(
                destination.path
            )
        }
        return R03A11QualificationRouteEvidenceRequest(
            destination: destination,
            qualificationInvocation: try R03QualificationInvocation.readRequired()
        )
    }

    static func emit(
        _ document: R03A11QualificationRouteEvidenceDocument,
        request: R03A11QualificationRouteEvidenceRequest
    ) throws {
        guard !FileManager.default.fileExists(atPath: request.destination.path) else {
            throw R03A11NativeMPSTestError.evidenceOutputAlreadyExists(
                request.destination.path
            )
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        try data.write(
            to: request.destination,
            options: [.atomic, .withoutOverwriting]
        )
    }
}
