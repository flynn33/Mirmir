import Foundation
@testable import Mirmir
import XCTest

final class UpscalerEngineAvailabilityTests: XCTestCase {
    @available(macOS 15.4, *)
    func test_defaultUpscalerRemainsAnAvailableDirectReferenceService() {
        let service = DefaultUpscalerEngineService(
            media: NoopMediaPipelineService(),
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            backendFactory: ASHDevelopmentUpscaleBackendFactory()
        )

        XCTAssertEqual(service.availability, .available)
    }

    func test_viewModelSourceDoesNotPerformASHStartupValidation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Mirmir/Modules/UI/MirmirViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("ASHBackendStartupValidator"))
    }

    func test_unavailableServiceRejectsSubmissionWithTypedReason() {
        let service = UnavailableUpscalerEngineService()
        let reason = UnavailableUpscalerEngineService.roadmapTransitionReason

        XCTAssertEqual(service.availability, .unavailable(reason: reason))
        XCTAssertEqual(service.availability.unavailableReason, reason)
        XCTAssertThrowsError(try service.submit(makeJob())) { error in
            guard let engineError = error as? UpscalerEngineError,
                  case .backendUnavailable(let actualReason) = engineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(actualReason, reason)
            XCTAssertEqual(String(describing: error), reason)
        }
    }

    func test_transitionModelAssetsServiceIsPassiveAndFailClosed() async {
        let service = RoadmapTransitionModelAssetsService()
        var iterator = service.statusStream(for: .video).makeAsyncIterator()
        let firstStatus = await iterator.next()
        let terminalStatus = await iterator.next()

        XCTAssertEqual(service.currentStatus(for: .video), .unknown)
        XCTAssertEqual(firstStatus, .unknown)
        XCTAssertNil(terminalStatus)

        do {
            try await service.ensureReady(for: .video)
            XCTFail("Expected transition model staging to remain unavailable.")
        } catch let error as UpscalerEngineError {
            guard case .backendUnavailable(let reason) = error else {
                return XCTFail("Unexpected engine error: \(error)")
            }
            XCTAssertEqual(reason, UnavailableUpscalerEngineService.roadmapTransitionReason)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeJob() -> UpscaleJob {
        UpscaleJob(
            inputURL: URL(fileURLWithPath: "/tmp/source.mov"),
            outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
            targetResolution: .p2160,
            preserveAudio: false
        )
    }
}
