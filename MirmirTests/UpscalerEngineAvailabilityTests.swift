import CoreMedia
import CoreVideo
import Foundation
import os.lock
@testable import Mirmir
#if compiler(>=6.2) && !targetEnvironment(simulator)
import VideoToolbox
#endif
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

    func test_notRequiredModelAssetsServiceIsTruthfulReadyAndPassive() async throws {
        let service = NotRequiredModelAssetsService()
        var iterator = service.statusStream(for: .video).makeAsyncIterator()

        XCTAssertEqual(service.currentStatus(for: .video), .notRequired)
        let firstStatus = await iterator.next()
        let terminalStatus = await iterator.next()
        XCTAssertEqual(firstStatus, .notRequired)
        XCTAssertNil(terminalStatus)

        try await service.ensureReady(for: .video)
        XCTAssertEqual(service.currentStatus(for: .video), .notRequired)
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

    func test_modelStagerObservesExistingDownloadWithoutStartingAnother()
        async throws {
        let provider = VTModelConfigurationProbe(status: .downloading(progress: 0.375))
        let stager = VTModelStager(
            configurationProvider: provider,
            acquisitionAuthority: .systemDownloadAuthorized,
            pollingIntervalNanoseconds: 1_000_000
        )
        let progress = VTModelProgressProbe()

        Task {
            try await Task.sleep(nanoseconds: 3_000_000)
            provider.setStatus(.downloading(progress: 0.75))
            try await Task.sleep(nanoseconds: 3_000_000)
            provider.setStatus(.ready)
        }
        try await stager.ensureReady { progress.record($0) }

        XCTAssertEqual(provider.downloadCount, 0)
        XCTAssertEqual(progress.values.first, 0.375)
        XCTAssertTrue(progress.values.contains(0.75))
        XCTAssertEqual(progress.values.last, 1.0)
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

#if compiler(>=6.2) && !targetEnvironment(simulator)
    @available(macOS 26.0, *)
    func test_qualityConfigurationFactoryBuildsDynamic720pAdmittedRoute()
        throws {
        let resolved = try XCTUnwrap(
            R13VideoToolboxQualityJobRouteResolver.resolve(
                mode: .quality,
                enginePreference: .videoToolboxQuality,
                videoFormat: .sdrBT709,
                presentationSourceResolution: .p720,
                targetResolution: .p1080,
                strategyPreference: .automatic
            )
        )
        XCTAssertTrue(resolved.requiresAdaptiveNativeExecution)

        let configuration = try R04VTNativeConfigurationFactory
            .makeQualityConfiguration(binding: resolved.binding)

        XCTAssertEqual(configuration.frameWidth, 1_280)
        XCTAssertEqual(configuration.frameHeight, 720)
        let scaleFactor = resolved.binding.route
            .scaleFactor.numerator
        XCTAssertEqual(configuration.scaleFactor, scaleFactor)
        XCTAssertEqual(
            (configuration.destinationPixelBufferAttributes[
                kCVPixelBufferWidthKey as String
            ] as? NSNumber)?.intValue,
            1_280 * scaleFactor
        )
        XCTAssertEqual(
            (configuration.destinationPixelBufferAttributes[
                kCVPixelBufferHeightKey as String
            ] as? NSNumber)?.intValue,
            720 * scaleFactor
        )
    }

    @available(macOS 26.0, *)
    func test_qualityBuilderUsesSupportedFourTimesRouteAndRGBAHalfContract()
        throws {
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw XCTSkip("The host does not expose native Quality SR.")
        }
        guard VTSuperResolutionScalerConfiguration.supportedScaleFactors
                .contains(4) else {
            throw XCTSkip("The host does not expose the public 4x route.")
        }

        let configuration = try VTNativeSRConfigurationBuilder.quality(
            sourceResolution: .p270,
            scaleFactor: .four,
            flowConfiguration: .appleComputed
        )

        XCTAssertEqual(configuration.frameWidth, 480)
        XCTAssertEqual(configuration.frameHeight, 270)
        XCTAssertEqual(configuration.scaleFactor, 4)
        XCTAssertEqual(configuration.inputType, .video)
        XCTAssertFalse(configuration.usesPrecomputedFlow)
        XCTAssertEqual(configuration.qualityPrioritization, .normal)
        XCTAssertTrue(
            configuration.supportedPixelFormats.contains(
                VTNativeQualityPixelBufferBridge.nativePixelFormat
            )
        )
        XCTAssertEqual(
            (configuration.destinationPixelBufferAttributes[
                kCVPixelBufferWidthKey as String
            ] as? NSNumber)?.intValue,
            VideoResolution.p1080.width
        )
        XCTAssertEqual(
            (configuration.destinationPixelBufferAttributes[
                kCVPixelBufferHeightKey as String
            ] as? NSNumber)?.intValue,
            VideoResolution.p1080.height
        )
    }

    @available(macOS 26.0, *)
    func test_qualityPixelBufferBridgeConvertsCanonicalNV12ToRGBAHalfAndBack()
        throws {
        let resolution = VideoResolution(width: 16, height: 16)
        let source = try PixelBufferBridge.dequeue(
            from: PixelBufferBridge.makePool(
                width: resolution.width,
                height: resolution.height
            )
        )
        R05MetalFXColorBridge.installRequiredAttachments(on: source)
        try Self.fillNeutralNV12(source, luma: 128)
        let native = try PixelBufferBridge.dequeue(
            from: PixelBufferBridge.makePool(
                width: resolution.width,
                height: resolution.height,
                format: VTNativeQualityPixelBufferBridge.nativePixelFormat
            )
        )
        let roundTrip = try PixelBufferBridge.dequeue(
            from: PixelBufferBridge.makePool(
                width: resolution.width,
                height: resolution.height
            )
        )
        let bridge = VTNativeQualityPixelBufferBridge()

        try bridge.convertCanonicalNV12(
            source,
            toNativeRGBAHalf: native,
            resolution: resolution
        )
        try bridge.convertNativeRGBAHalf(
            native,
            toCanonicalNV12: roundTrip,
            resolution: resolution
        )

        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(native),
            kCVPixelFormatType_64RGBAHalf
        )
        XCTAssertEqual(CVPixelBufferGetPlaneCount(native), 0)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(native))
        try R03NV12Contract.validate(
            pixelBuffer: roundTrip,
            resolution: resolution
        )
        let roundTripLuma = try Self.firstLumaSample(roundTrip)
        XCTAssertLessThanOrEqual(abs(Int(roundTripLuma) - 128), 1)
    }
#endif

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

    private static func fillNeutralNV12(
        _ pixelBuffer: CVPixelBuffer,
        luma: UInt8
    ) throws {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard status == kCVReturnSuccess else {
            throw PixelBufferBridgeError.poolDequeueFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                0
              ),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                1
              ) else {
            throw PixelBufferBridgeError.invalidPlaneCount(
                expected: 2,
                actual: CVPixelBufferGetPlaneCount(pixelBuffer)
            )
        }
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) {
            memset(
                lumaBase.advanced(
                    by: row * CVPixelBufferGetBytesPerRowOfPlane(
                        pixelBuffer,
                        0
                    )
                ),
                Int32(luma),
                CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            )
        }
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
            memset(
                chromaBase.advanced(
                    by: row * CVPixelBufferGetBytesPerRowOfPlane(
                        pixelBuffer,
                        1
                    )
                ),
                128,
                CVPixelBufferGetWidth(pixelBuffer)
            )
        }
    }

    private static func firstLumaSample(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> UInt8 {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw PixelBufferBridgeError.poolDequeueFailed(status)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(
            pixelBuffer,
            0
        ) else {
            throw PixelBufferBridgeError.invalidPlaneCount(
                expected: 2,
                actual: CVPixelBufferGetPlaneCount(pixelBuffer)
            )
        }
        return base.assumingMemoryBound(to: UInt8.self).pointee
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

    func setStatus(_ status: VTModelStagerStatus) {
        lock.withLock { $0.status = status }
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
