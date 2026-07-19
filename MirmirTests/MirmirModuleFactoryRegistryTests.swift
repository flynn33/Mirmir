import XCTest
@testable import Mirmir

@MainActor
final class MirmirModuleFactoryRegistryTests: XCTestCase {
    func test_catalogPreservesExactDescriptorsAndActivationOrder() {
        XCTAssertEqual(
            MirmirModuleCatalog.activationOrder.map(\.moduleID),
            [
                "com.mirmir.app.metal",
                "com.mirmir.app.model-assets",
                "com.mirmir.app.media-pipeline",
                "com.mirmir.app.upscaler-engine",
                "com.mirmir.app.ui"
            ]
        )
        XCTAssertEqual(
            MirmirModuleCatalog.activationOrder.map(\.entryPoint),
            [
                "MetalRenderingServiceModule",
                "ModelAssetsServiceModule",
                "MediaPipelineServiceModule",
                "UpscalerEngineServiceModule",
                "MirmirUIModule"
            ]
        )
        XCTAssertEqual(
            MirmirModuleCatalog.activationOrder.map(\.displayName),
            [
                "Metal Rendering",
                "Model Assets",
                "Media Pipeline",
                "Upscaler Engine",
                "Mirmir UI"
            ]
        )
        XCTAssertEqual(MirmirModuleCatalog.activationOrder.map(\.versionString), Array(repeating: "1.0.0", count: 5))
        XCTAssertEqual(MirmirModuleCatalog.activationOrder.map(\.kind), [.service, .service, .service, .service, .ui])
        XCTAssertEqual(MirmirUIConstants.primaryViewID, "com.mirmir.app.ui.workspace-root")
    }

    func test_registryRejectsDuplicateModuleIDsAndEntryPoints() throws {
        let recorder = MirmirModuleEventRecorder()
        let registry = MirmirModuleFactoryRegistry()
        let metal = MirmirModuleCatalog.metalRendering
        try registry.register(descriptor: metal) {
            MirmirRecordingModule(descriptor: metal, recorder: recorder)
        }

        XCTAssertThrowsError(try registry.register(descriptor: metal) {
            MirmirRecordingModule(descriptor: metal, recorder: recorder)
        }) { error in
            XCTAssertEqual(error as? MirmirModuleFactoryRegistryError, .duplicateModuleID(metal.moduleID))
        }

        let duplicateEntryPoint = MirmirModuleDescriptor(
            moduleID: "com.mirmir.test.other-metal",
            displayName: "Other Metal",
            versionString: "1.0.0",
            entryPoint: metal.entryPoint,
            kind: .service
        )
        XCTAssertThrowsError(try registry.register(descriptor: duplicateEntryPoint) {
            MirmirRecordingModule(descriptor: duplicateEntryPoint, recorder: recorder)
        }) { error in
            XCTAssertEqual(
                error as? MirmirModuleFactoryRegistryError,
                .duplicateEntryPoint(metal.entryPoint)
            )
        }
    }

    func test_registryRejectsInvalidDescriptors() {
        let invalid = MirmirModuleDescriptor(
            moduleID: " ",
            displayName: "Invalid",
            versionString: "1.0.0",
            entryPoint: "InvalidModule",
            kind: .service
        )
        let recorder = MirmirModuleEventRecorder()
        let registry = MirmirModuleFactoryRegistry()

        XCTAssertThrowsError(try registry.register(descriptor: invalid) {
            MirmirRecordingModule(descriptor: invalid, recorder: recorder)
        }) { error in
            guard let registryError = error as? MirmirModuleFactoryRegistryError,
                  case .invalidDescriptor = registryError else {
                return XCTFail("Expected invalid descriptor, got \(error)")
            }
        }
    }

    func test_registryVerifiesFactoryDescriptorIdentity() throws {
        let recorder = MirmirModuleEventRecorder()
        let registry = MirmirModuleFactoryRegistry()
        try registry.register(descriptor: MirmirModuleCatalog.metalRendering) {
            MirmirRecordingModule(
                descriptor: MirmirModuleCatalog.modelAssets,
                recorder: recorder
            )
        }

        XCTAssertThrowsError(
            try registry.makeModule(moduleID: MirmirModuleCatalog.metalRendering.moduleID)
        ) { error in
            XCTAssertEqual(
                error as? MirmirModuleFactoryRegistryError,
                .factoryDescriptorMismatch(
                    expected: MirmirModuleCatalog.metalRendering,
                    actual: MirmirModuleCatalog.modelAssets
                )
            )
        }
    }

    func test_registryResolvesFactoriesByModuleIDAndEntryPoint() throws {
        let recorder = MirmirModuleEventRecorder()
        let registry = MirmirModuleFactoryRegistry()
        let descriptor = MirmirModuleCatalog.ui
        try registry.register(descriptor: descriptor) {
            MirmirRecordingModule(descriptor: descriptor, recorder: recorder)
        }

        XCTAssertEqual(
            try registry.makeModule(moduleID: descriptor.moduleID).descriptor,
            descriptor
        )
        XCTAssertEqual(
            try registry.makeModule(entryPoint: descriptor.entryPoint).descriptor,
            descriptor
        )
    }

    func test_applicationRegistryContainsExactlyTheCatalog() throws {
        let services = MirmirServices(
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            media: NoopMediaPipelineService(),
            upscaler: NoopUpscalerEngineService()
        )
        let registry = try MirmirModuleRegistry.makeRegistry(services: services)

        XCTAssertEqual(
            Set(registry.registeredDescriptors),
            Set(MirmirModuleCatalog.activationOrder)
        )
        for descriptor in MirmirModuleCatalog.activationOrder {
            XCTAssertEqual(
                try registry.makeModule(moduleID: descriptor.moduleID).descriptor,
                descriptor
            )
        }
    }
}
