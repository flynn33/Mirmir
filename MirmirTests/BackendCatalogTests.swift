import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Mirmir

final class BackendCatalogTests: XCTestCase {
    func testDescriptorsContainEveryStablePickerIdentity() {
        XCTAssertEqual(BackendDescriptor.all.count, 14)
        XCTAssertEqual(
            Set(BackendDescriptor.all.map(\.id)),
            Set(UpscaleBackendID.allCases)
        )
        XCTAssertEqual(
            BackendDescriptor.descriptor(
                for: .videoToolboxInterpolationWithSpatialScale
            )?.group,
            .smoothMotion
        )
        XCTAssertEqual(
            BackendDescriptor.descriptor(
                for: .mirmirDeterministicMetal
            )?.id.rawValue,
            "mirmirDeterministicMetal"
        )
    }

    func testAutomaticOrderIsFixedAndExcludesNonSpatialChoices() {
        XCTAssertEqual(
            AutomaticBackendSelector.orderedBackendIDs,
            [
                .videoToolboxSuperResolutionQuality,
                .videoToolboxSuperResolutionLowLatency,
                .metalFXSpatial,
                .mpsLanczos,
                .coreImageLanczos,
                .vImageHighQuality,
                .videoToolboxPixelTransfer
            ]
        )
        XCTAssertFalse(
            AutomaticBackendSelector.orderedBackendIDs.contains(
                .videoToolboxInterpolationWithSpatialScale
            )
        )
        XCTAssertFalse(
            AutomaticBackendSelector.orderedBackendIDs.contains(
                .mirmirDeterministicCPU
            )
        )
    }

    func testAutomaticReportsFirstAvailableBackendInDocumentedOrder() async {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-source.mov")
        )
        var values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        values[.videoToolboxSuperResolutionQuality] = .unavailable(
            reason: .appleAPIUnsupported(details: "test rejection")
        )
        let catalog = UpscaleBackendCatalog(
            backends: makeStubBackends(values: values)
        )

        let snapshot = await catalog.snapshot(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: testEnvironment
        )

        XCTAssertEqual(
            snapshot.automaticProposal,
            .videoToolboxSuperResolutionLowLatency
        )
        XCTAssertEqual(snapshot.entry(for: .automatic)?.availability, .available)
        XCTAssertEqual(snapshot.entries.count, 14)
    }

    func testExplicitUnavailableSelectionIsRetainedWithoutFallback() async {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-explicit.mov")
        )
        var values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        let unavailable = BackendAvailability.unavailable(
            reason: .noMetalDevice
        )
        values[.mpsLanczos] = unavailable
        let catalog = UpscaleBackendCatalog(
            backends: makeStubBackends(values: values)
        )
        let snapshot = await catalog.snapshot(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: testEnvironment
        )

        let resolution = snapshot.resolution(for: .mpsLanczos)

        XCTAssertEqual(resolution.requestedBackendID, .mpsLanczos)
        XCTAssertEqual(resolution.actualBackendID, .mpsLanczos)
        XCTAssertEqual(resolution.availability, unavailable)
    }

    func testUnavailableReasonMappingIsActionableAndNotQualificationLanguage() {
        let text = BackendUnavailableReason.processingAdapterNotImplemented(
            backendID: .vImageHighQuality
        ).userFacingDescription

        XCTAssertTrue(text.contains("Accelerate/vImage High Quality"))
        XCTAssertTrue(text.contains("does not include"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("qualification"))
        XCTAssertEqual(
            BackendAvailability.unavailable(reason: .noMetalDevice).statusText,
            "Unavailable: No compatible Metal device is available on this Mac."
        )
    }

    func testSystemCapabilityProbeRejectsSubpixelDimensionsThatRoundToZero() async {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-subpixel.mov")
        )

        let availability = await SystemBackendCapabilityProbe().availability(
            for: .coreImageLanczos,
            source: source,
            targetSize: CGSize(width: 0.0009, height: 180)
        )

        XCTAssertEqual(
            availability,
            .unavailable(
                reason: .unsupportedTargetDimensions(
                    width: 0,
                    height: 0,
                    details: "The target must have positive integral dimensions."
                )
            )
        )
    }

    func testHDRAvoidsEveryEightBitBackendAndAdmitsDeterministicP010()
        async throws {
        let source = makeVideoInfo(
            url: URL(fileURLWithPath: "/tmp/catalog-hdr.mov"),
            bitDepth: 10,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            dynamicRange: .hdr
        )
        let snapshot = await UpscaleBackendCatalog.live().snapshot(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: .current()
        )

        let deterministicIDs: Set<UpscaleBackendID> = [
            .mirmirDeterministicCPU,
            .mirmirDeterministicMetal
        ]
        for descriptor in BackendDescriptor.concrete
            where !deterministicIDs.contains(descriptor.id) {
            XCTAssertEqual(
                snapshot.entry(for: descriptor.id)?.availability,
                .unavailable(reason: .hdrPreservationUnavailable),
                "\(descriptor.title) must not silently convert HDR to SDR."
            )
        }
        let runtime = try ASHV4SemanticArtifactTestSupport
            .executableSystemMetalRuntime()
        let cpuDescriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicCPU)
        )
        let cpu = try XCTUnwrap(DeterministicCPUBackend(
            descriptor: cpuDescriptor,
            runtimeProvider: .fixed(runtime)
        ))
        let cpuAvailability = await cpu.availability(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: .current()
        )
        XCTAssertEqual(cpuAvailability, .available)
        let metalDescriptor = try XCTUnwrap(
            BackendDescriptor.descriptor(for: .mirmirDeterministicMetal)
        )
        let metal = try XCTUnwrap(DeterministicMetalBackend(
            descriptor: metalDescriptor,
            runtimeProvider: .fixed(runtime)
        ))
        let metalAvailability = await metal.availability(
            for: source,
            targetSize: CGSize(width: 640, height: 360),
            environment: .current()
        )
        XCTAssertTrue(
            metalAvailability == .available
                || metalAvailability == .unavailable(reason: .noMetalDevice)
        )
        XCTAssertEqual(
            snapshot.entry(for: .automatic)?.availability,
            .unavailable(reason: .noCompatibleAutomaticBackend)
        )
    }

    @MainActor
    func testViewModelStartupDoesNotProbeBackends() async {
        let counter = ProbeCounter()
        let backends = BackendDescriptor.concrete.map {
            CountingBackend(descriptor: $0, counter: counter)
                as any UpscaleBackend
        }
        let catalog = UpscaleBackendCatalog(backends: backends)

        _ = MirmirViewModel(
            videoProbe: WaitingCatalogVideoProbe(),
            backendCatalog: catalog,
            runtimeEnvironment: testEnvironment
        )

        let probeCount = await counter.value()
        XCTAssertEqual(probeCount, 0)
    }

    @MainActor
    func testViewModelRetainsExplicitSelectionAfterAvailabilityRefresh() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-view-model.mov")
        let source = makeVideoInfo(url: url)
        let unavailable = BackendAvailability.unavailable(
            reason: .processingAdapterNotImplemented(
                backendID: .mpsLanczos
            )
        )
        let values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, unavailable)
            }
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment
        )

        viewModel.selectBackend(.mpsLanczos)
        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(viewModel.selectedBackendID, .mpsLanczos)
        XCTAssertEqual(
            viewModel.backendSnapshot?.entry(for: .mpsLanczos)?.availability,
            unavailable
        )
    }

    @MainActor
    func testViewModelProvidesExactThreeOverTwoPresetForDeterministicRoute() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-three-over-two.mov")
        let source = makeVideoInfo(
            url: url,
            encodedSize: CGSize(width: 320, height: 180)
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            runtimeEnvironment: testEnvironment
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        viewModel.applyScale(numerator: 3, denominator: 2)
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(viewModel.targetWidth, 480)
        XCTAssertEqual(viewModel.targetHeight, 270)
        XCTAssertEqual(viewModel.backendTargetSize, CGSize(width: 480, height: 270))
    }

    @MainActor
    func testQualitySelectionWarnsBeforeChangingDefaultTargetToSupportedScale() async throws {
        let url = URL(fileURLWithPath: "/tmp/catalog-quality-adjustment.mov")
        let source = makeVideoInfo(
            url: url,
            encodedSize: CGSize(width: 320, height: 180)
        )
        var values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        values[.videoToolboxSuperResolutionQuality] = .unavailable(
            reason: .unsupportedScaleFactor(
                details: "requested 2×; this Mac reports [4]"
            )
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment,
            superResolutionScaleProvider: { backendID, _, _ in
                backendID == .videoToolboxSuperResolutionQuality ? [4] : [2, 4]
            }
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        let adjustment = try XCTUnwrap(
            viewModel.targetAdjustmentForSelecting(
                .videoToolboxSuperResolutionQuality
            )
        )
        XCTAssertEqual(viewModel.targetWidth, 640)
        XCTAssertEqual(viewModel.targetHeight, 360)
        XCTAssertEqual(adjustment.proposedScaleFactor, 4)
        XCTAssertEqual(adjustment.proposedTargetWidth, 1_280)
        XCTAssertEqual(adjustment.proposedTargetHeight, 720)
        XCTAssertTrue(adjustment.message.contains("current 2× target"))
        XCTAssertTrue(adjustment.message.contains("quality model"))

        viewModel.applyBackendSelectionAdjustment(adjustment)
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(
            viewModel.selectedBackendID,
            .videoToolboxSuperResolutionQuality
        )
        XCTAssertEqual(viewModel.targetWidth, 1_280)
        XCTAssertEqual(viewModel.targetHeight, 720)
    }

    @MainActor
    func testLowLatencyDefaultTwoXSelectionNeedsNoTargetWarning() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-low-latency-default.mov")
        let source = makeVideoInfo(url: url)
        let values = Dictionary(
            uniqueKeysWithValues: BackendDescriptor.concrete.map {
                ($0.id, BackendAvailability.available)
            }
        )
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            backendCatalog: UpscaleBackendCatalog(
                backends: makeStubBackends(values: values)
            ),
            runtimeEnvironment: testEnvironment,
            superResolutionScaleProvider: { _, _, _ in [2, 4] }
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        XCTAssertNil(
            viewModel.targetAdjustmentForSelecting(
                .videoToolboxSuperResolutionLowLatency
            )
        )
        viewModel.selectBackend(.videoToolboxSuperResolutionLowLatency)
        XCTAssertEqual(viewModel.targetWidth, 640)
        XCTAssertEqual(viewModel.targetHeight, 360)
    }

    @MainActor
    func testQualitySelectionBeforeSourceWarnsAndChangesInitialDefaultAfterConsent() async {
        let url = URL(fileURLWithPath: "/tmp/catalog-quality-presource.mov")
        let source = makeVideoInfo(url: url)
        let viewModel = MirmirViewModel(
            videoProbe: ImmediateCatalogVideoProbe(info: source),
            runtimeEnvironment: testEnvironment,
            superResolutionScaleProvider: { backendID, _, _ in
                backendID == .videoToolboxSuperResolutionQuality ? [4] : [2, 4]
            }
        )

        let adjustment = try? XCTUnwrap(
            viewModel.targetAdjustmentForSelecting(
                .videoToolboxSuperResolutionQuality
            )
        )
        XCTAssertNil(adjustment?.sourceURL)
        XCTAssertEqual(adjustment?.proposedScaleFactor, 4)
        XCTAssertTrue(adjustment?.message.contains("normally starts") == true)
        guard let adjustment else { return }

        viewModel.applyBackendSelectionAdjustment(adjustment)
        XCTAssertEqual(
            viewModel.selectedBackendID,
            .videoToolboxSuperResolutionQuality
        )

        viewModel.selectVideo(url)
        await viewModel.waitForCurrentProbe()
        await viewModel.waitForBackendAvailability()

        XCTAssertEqual(viewModel.targetWidth, 1_280)
        XCTAssertEqual(viewModel.targetHeight, 720)
    }

    @MainActor
    func testViewModelRejectsUnrepresentableAndRoundedZeroEncodedDimensions() async {
        let sizes = [
            CGSize(width: CGFloat(Int.max), height: 180),
            CGSize(width: 0.0009, height: 180)
        ]

        for (index, size) in sizes.enumerated() {
            let url = URL(
                fileURLWithPath: "/tmp/catalog-invalid-geometry-\(index).mov"
            )
            let source = makeVideoInfo(url: url, encodedSize: size)
            let viewModel = MirmirViewModel(
                videoProbe: ImmediateCatalogVideoProbe(info: source),
                runtimeEnvironment: testEnvironment
            )

            viewModel.selectVideo(url)
            await viewModel.waitForCurrentProbe()

            XCTAssertEqual(viewModel.state, .ready(source))
            XCTAssertEqual(
                viewModel.backendAvailabilityMessage,
                "Backend availability requires positive integral encoded dimensions."
            )
            XCTAssertNil(viewModel.backendTargetSize)
            XCTAssertNil(viewModel.backendSnapshot)
        }
    }
}

private let testEnvironment = RuntimeEnvironment(
    operatingSystem: RuntimeOperatingSystem(
        OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 0,
            patchVersion: 0
        )
    ),
    capabilityProbe: TestCapabilityProbe()
)

private struct TestCapabilityProbe: BackendCapabilityProbing {
    func availability(
        for backendID: UpscaleBackendID,
        source: VideoInfo,
        targetSize: CGSize
    ) async -> BackendAvailability {
        .unavailable(
            reason: .appleAPIUnsupported(
                details: "The injected stub backend owns this test result."
            )
        )
    }
}

private struct StubBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let value: BackendAvailability

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        value
    }

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        throw BackendPreparationError.unavailable(
            descriptor.id,
            .processingAdapterNotImplemented(backendID: descriptor.id)
        )
    }
}

private actor ProbeCounter {
    private var count = 0

    func record() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct CountingBackend: UpscaleBackend {
    let descriptor: BackendDescriptor
    let counter: ProbeCounter

    func availability(
        for source: VideoInfo,
        targetSize: CGSize,
        environment: RuntimeEnvironment
    ) async -> BackendAvailability {
        await counter.record()
        return .available
    }

    func prepare(
        request: BackendPreparationRequest,
        environment: RuntimeEnvironment
    ) async throws -> any PreparedFrameUpscaler {
        throw BackendPreparationError.unavailable(
            descriptor.id,
            .processingAdapterNotImplemented(backendID: descriptor.id)
        )
    }
}

private struct WaitingCatalogVideoProbe: VideoProbing {
    func probe(url: URL) async throws -> VideoInfo {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}

private struct ImmediateCatalogVideoProbe: VideoProbing {
    let info: VideoInfo

    func probe(url: URL) async throws -> VideoInfo {
        info
    }
}

private func makeStubBackends(
    values: [UpscaleBackendID: BackendAvailability]
) -> [any UpscaleBackend] {
    BackendDescriptor.concrete.map { descriptor in
        StubBackend(
            descriptor: descriptor,
            value: values[descriptor.id]
                ?? .unavailable(
                    reason: .sdkAdapterNotCompiled(
                        requiredSymbol: descriptor.id.rawValue
                    )
                )
        ) as any UpscaleBackend
    }
}

private func makeVideoInfo(
    url: URL,
    encodedSize: CGSize = CGSize(width: 320, height: 180),
    bitDepth: Int = 8,
    pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    dynamicRange: VideoDynamicRange = .sdr
) -> VideoInfo {
    VideoInfo(
        url: url,
        duration: CMTime(seconds: 1, preferredTimescale: 600),
        geometry: VideoGeometry(
            encodedSize: encodedSize,
            naturalSize: encodedSize,
            presentationSize: encodedSize,
            displaySize: encodedSize,
            preferredTransform: .identity,
            cleanAperture: nil,
            pixelAspectRatio: VideoPixelAspectRatio(
                horizontalSpacing: 1,
                verticalSpacing: 1
            )
        ),
        nominalFrameRate: 30,
        minimumFrameDuration: CMTime(value: 1, timescale: 30),
        estimatedFrameCount: 30,
        estimatedDataRate: nil,
        codecFourCC: kCMVideoCodecType_H264,
        hasAudio: false,
        audioTrackCount: 0,
        videoTrackCount: 1,
        isReadable: true,
        isPlayable: true,
        fileSizeBytes: nil,
        color: VideoColorInfo(
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
            bitDepth: bitDepth,
            pixelFormat: pixelFormat,
            isFullRange: false,
            fieldCount: 1,
            fieldDetail: nil,
            alphaModel: .none,
            hasMasteringDisplayMetadata: false,
            hasContentLightLevelMetadata: false,
            dynamicRange: dynamicRange
        )
    )
}
