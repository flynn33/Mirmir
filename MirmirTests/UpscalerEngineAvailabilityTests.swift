import CoreMedia
import Foundation
import os.lock
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

    func test_modelStagerDoesNotAcquireWithoutExplicitAuthority() async {
        let provider = VTModelConfigurationProbe(status: .downloadRequired)
        let stager = VTModelStager(
            configurationProvider: provider,
            acquisitionAuthority: .statusOnly
        )
        let progress = VTModelProgressProbe()

        do {
            try await stager.ensureReady { progress.record($0) }
            XCTFail("Status-only model staging must not start a download.")
        } catch let error as VTModelStagerError {
            XCTAssertEqual(error, .acquisitionNotAuthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(provider.downloadCount, 0)
        XCTAssertEqual(progress.values, [])
        XCTAssertEqual(stager.currentStatus(), .downloadRequired)
    }

    func test_modelStagerUsesConcreteStatusAndAuthorizedDownload() async throws {
        let provider = VTModelConfigurationProbe(status: .downloadRequired)
        let stager = VTModelStager(
            configurationProvider: provider,
            acquisitionAuthority: .systemDownloadAuthorized
        )
        let progress = VTModelProgressProbe()

        try await stager.ensureReady { progress.record($0) }

        XCTAssertEqual(provider.downloadCount, 1)
        XCTAssertEqual(stager.currentStatus(), .ready)
        XCTAssertEqual(progress.values, [1.0])
    }

    func test_modelStagerReportsExistingDownloadWithoutStartingAnother() async {
        let provider = VTModelConfigurationProbe(status: .downloading(progress: 0.375))
        let stager = VTModelStager(
            configurationProvider: provider,
            acquisitionAuthority: .systemDownloadAuthorized
        )
        let progress = VTModelProgressProbe()

        do {
            try await stager.ensureReady { progress.record($0) }
            XCTFail("An existing model download must remain externally owned.")
        } catch let error as VTModelStagerError {
            XCTAssertEqual(error, .downloadAlreadyInProgress(progress: 0.375))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(provider.downloadCount, 0)
        XCTAssertEqual(progress.values, [0.375])
    }

    @available(macOS 26.0, *)
    func test_modelAssetsWaiterTerminatesForStatusOnlyDownloadRequirement() {
        XCTAssertEqual(
            DefaultModelAssetsService.terminalWaiterError(
                for: .downloadRequired,
                acquisitionAuthority: .statusOnly,
                acquisitionOwned: false
            ),
            .acquisitionNotAuthorized
        )
    }

    @available(macOS 26.0, *)
    func test_modelAssetsWaiterTerminatesForExternallyOwnedDownload() {
        XCTAssertEqual(
            DefaultModelAssetsService.terminalWaiterError(
                for: .downloading(progress: 0.625),
                acquisitionAuthority: .systemDownloadAuthorized,
                acquisitionOwned: false
            ),
            .downloadAlreadyInProgress(progress: 0.625)
        )
    }

    @available(macOS 26.0, *)
    func test_modelAssetsWaiterPreservesOwnedDownloadWaiting() {
        XCTAssertNil(
            DefaultModelAssetsService.terminalWaiterError(
                for: .downloadRequired,
                acquisitionAuthority: .systemDownloadAuthorized,
                acquisitionOwned: true
            )
        )
        XCTAssertNil(
            DefaultModelAssetsService.terminalWaiterError(
                for: .downloading(progress: 0.625),
                acquisitionAuthority: .systemDownloadAuthorized,
                acquisitionOwned: true
            )
        )
    }

    func test_lowLatencyAdmissionQueriesExactDimensionsBeforeConstruction() throws {
        var events: [String] = []

        let configured: String = try VTNativeLowLatencyScaleAdmission.construct(
            frameWidth: 1280,
            frameHeight: 720,
            requestedScale: 1.5,
            query: {
                events.append("query-1280x720")
                return [1.5, 2.0]
            },
            construct: {
                events.append("construct")
                return "configured"
            }
        )

        XCTAssertEqual(configured, "configured")
        XCTAssertEqual(events, ["query-1280x720", "construct"])
    }

    func test_lowLatencyAdmissionRejectsUnsupportedScaleWithoutConstruction() {
        var didConstruct = false

        XCTAssertThrowsError(
            try VTNativeLowLatencyScaleAdmission.construct(
                frameWidth: 1920,
                frameHeight: 1080,
                requestedScale: 2.0,
                query: { [1.5] },
                construct: {
                    didConstruct = true
                    return "must-not-be-created"
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? VTNativeSuperResolutionError,
                .rejected(.exactDimensionScaleUnsupported)
            )
        }

        XCTAssertFalse(didConstruct)
    }

    func test_qualityAdmissionChecksScaleAndRevisionBeforeConstruction() throws {
        var events: [String] = []

        let configured: String = try VTNativeQualityConfigurationAdmission.construct(
            scaleIsSupported: {
                events.append("scale")
                return true
            },
            revisionIsSupported: {
                events.append("revision")
                return true
            },
            construct: {
                events.append("construct")
                return "configured"
            }
        )

        XCTAssertEqual(configured, "configured")
        XCTAssertEqual(events, ["scale", "revision", "construct"])
    }

    func test_qualityAdmissionRejectsUnsupportedRevisionWithoutConstruction() {
        var didConstruct = false

        XCTAssertThrowsError(
            try VTNativeQualityConfigurationAdmission.construct(
                scaleIsSupported: { true },
                revisionIsSupported: { false },
                construct: {
                    didConstruct = true
                    return "must-not-be-created"
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? VTNativeSuperResolutionError,
                .unavailable(.qualityRevisionUnsupported)
            )
        }

        XCTAssertFalse(didConstruct)
    }

    func test_qualityDiagnosticsBindImmutablePrecomputedFlowChoice() {
        let diagnostics = VTNativeConfigurationDiagnosticsFactory.quality(
            frameWidth: 1920,
            frameHeight: 1080,
            integerScaleFactor: 2,
            usesPrecomputedFlow: true,
            revision: 7,
            supportedPixelFormats: [0x34323076, 0x34323066],
            modelStatus: .ready
        )

        guard case .quality(let identity) = diagnostics.nativeIdentity else {
            return XCTFail("Expected a quality diagnostics identity.")
        }
        XCTAssertTrue(identity.usesPrecomputedFlow)
        XCTAssertEqual(identity.revision, 7)
        XCTAssertEqual(diagnostics.modelStatus, .ready)
        XCTAssertEqual(diagnostics.processingMode, .quality)
        XCTAssertTrue(
            VTNativeQualityFlowConfiguration.precomputed.usesPrecomputedFlow
        )
        XCTAssertFalse(
            VTNativeQualityFlowConfiguration.precomputed.accepts(.disabled)
        )
        XCTAssertTrue(
            VTNativeQualityFlowConfiguration.appleComputed.accepts(.appleComputed)
        )
    }

    func test_nativeTemporalContinuityRequiresExactSequenceTimeAndDuration() {
        let priorTimestamp = CMTime(value: 100, timescale: 30)
        let duration = CMTime(value: 1, timescale: 30)
        let nextTimestamp = CMTimeAdd(priorTimestamp, duration)

        XCTAssertTrue(
            VTNativeTemporalContinuity.isContiguous(
                previousSequenceNumber: 41,
                previousPresentationTimestamp: priorTimestamp,
                previousDuration: duration,
                currentSequenceNumber: 42,
                currentPresentationTimestamp: nextTimestamp,
                currentDuration: duration
            )
        )
        XCTAssertFalse(
            VTNativeTemporalContinuity.isContiguous(
                previousSequenceNumber: 41,
                previousPresentationTimestamp: priorTimestamp,
                previousDuration: duration,
                currentSequenceNumber: 43,
                currentPresentationTimestamp: nextTimestamp,
                currentDuration: duration
            )
        )
        XCTAssertFalse(
            VTNativeTemporalContinuity.isContiguous(
                previousSequenceNumber: 41,
                previousPresentationTimestamp: priorTimestamp,
                previousDuration: duration,
                currentSequenceNumber: 42,
                currentPresentationTimestamp: CMTimeAdd(nextTimestamp, duration),
                currentDuration: duration
            )
        )
        XCTAssertFalse(
            VTNativeTemporalContinuity.isContiguous(
                previousSequenceNumber: 41,
                previousPresentationTimestamp: priorTimestamp,
                previousDuration: duration,
                currentSequenceNumber: 42,
                currentPresentationTimestamp: nextTimestamp,
                currentDuration: CMTime(value: 2, timescale: 30)
            )
        )
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

private final class VTModelConfigurationProbe:
    VTModelConfigurationProviding,
    @unchecked Sendable {
    private struct State {
        var status: VTModelStagerStatus
        var downloadCount = 0
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(status: VTModelStagerStatus) {
        lock = OSAllocatedUnfairLock(initialState: State(status: status))
    }

    var downloadCount: Int {
        lock.withLock { $0.downloadCount }
    }

    func currentStatus() -> VTModelStagerStatus {
        lock.withLock { $0.status }
    }

    func downloadConfigurationModel() async throws {
        lock.withLock { state in
            state.downloadCount += 1
            state.status = .ready
        }
    }
}

private final class VTModelProgressProbe: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Double]())

    var values: [Double] {
        lock.withLock { $0 }
    }

    func record(_ value: Double) {
        lock.withLock { $0.append(value) }
    }
}
