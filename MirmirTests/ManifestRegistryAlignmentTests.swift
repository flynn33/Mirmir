import XCTest
import ForsettiCore
@testable import Mirmir

/// Enforces three invariants for every Mirmir module:
/// 1. The JSON manifest under `Resources/ForsettiManifests/` decodes cleanly.
/// 2. The corresponding Swift module's `manifest` literal equals the decoded JSON.
/// 3. The `entryPoint` is registered in `MirmirModuleRegistry` and the
///    instantiated module's `descriptor` and `manifest` match.
final class ManifestRegistryAlignmentTests: XCTestCase {

    private struct ManifestCase {
        let fileName: String
        let buildModule: () -> any ForsettiModule
    }

    private func manifestCases() -> [ManifestCase] {
        [
            ManifestCase(fileName: "MirmirUIModule") {
                MirmirUIModule()
            },
            ManifestCase(fileName: "MetalRenderingServiceModule") {
                MetalRenderingServiceModule(service: NoopMetalRenderingService())
            },
            ManifestCase(fileName: "ModelAssetsServiceModule") {
                ModelAssetsServiceModule(service: NoopModelAssetsService())
            },
            ManifestCase(fileName: "MediaPipelineServiceModule") {
                MediaPipelineServiceModule(service: NoopMediaPipelineService())
            },
            ManifestCase(fileName: "UpscalerEngineServiceModule") {
                UpscalerEngineServiceModule(service: NoopUpscalerEngineService())
            }
        ]
    }

    func test_repositoryDoesNotContainVendoredForsettiSource() {
        let embeddedFrameworkURL = repoRootURL().appendingPathComponent("ForsettiFramework", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: embeddedFrameworkURL.path),
            "Forsetti must be consumed as a sealed package dependency, not as an editable source subtree."
        )
    }

    func test_manifestFilesUseCurrentForsettiSchemaAndVersion() throws {
        for testCase in manifestCases() {
            let data = try Data(contentsOf: try manifestURL(fileName: testCase.fileName))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(json["schemaVersion"] as? String, "1.1", "\(testCase.fileName) must use schema 1.1")
            XCTAssertEqual(
                json["manifestTemplateVersion"] as? String,
                "1.1",
                "\(testCase.fileName) must use template 1.1"
            )

            let minVersion = try XCTUnwrap(json["minForsettiVersion"] as? [String: Any])
            XCTAssertEqual(minVersion["major"] as? Int, 0, "\(testCase.fileName) min major mismatch")
            XCTAssertEqual(minVersion["minor"] as? Int, 1, "\(testCase.fileName) min minor mismatch")
            XCTAssertEqual(minVersion["patch"] as? Int, 4, "\(testCase.fileName) min patch mismatch")
            XCTAssertNotNil(json["runtimeRequirements"], "\(testCase.fileName) must declare runtime requirements")
        }
    }

    func test_everyManifestDecodesAndAlignsWithSwiftModule() throws {
        // Mirmir's manifests are bundled in the app target as a folder
        // reference (`Resources/ForsettiManifests/`). In a hosted unit test the
        // app bundle is `Bundle.main` (the TEST_HOST), so look there first
        // and fall back to the test bundle for environments that ship the
        // manifests alongside the tests.
        let bundles = [Bundle.main, Bundle(for: type(of: self))]
        for testCase in manifestCases() {
            let url: URL? = bundles.compactMap { bundle in
                bundle.url(forResource: testCase.fileName, withExtension: "json", subdirectory: MirmirForsettiConstants.manifestSubdirectory)
                    ?? bundle.url(forResource: testCase.fileName, withExtension: "json")
            }.first
            guard let url else {
                XCTFail("Manifest \(testCase.fileName).json not found in test bundle")
                continue
            }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(ModuleManifest.self, from: data)
            let module = testCase.buildModule()

            XCTAssertEqual(decoded.moduleID, module.manifest.moduleID, "moduleID mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.displayName, module.manifest.displayName, "displayName mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.moduleVersion, module.manifest.moduleVersion, "moduleVersion mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.moduleType, module.manifest.moduleType, "moduleType mismatch in \(testCase.fileName)")
            XCTAssertEqual(Set(decoded.supportedPlatforms), Set(module.manifest.supportedPlatforms), "supportedPlatforms mismatch in \(testCase.fileName)")
            XCTAssertEqual(Set(decoded.capabilitiesRequested), Set(module.manifest.capabilitiesRequested), "capabilitiesRequested mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.entryPoint, module.manifest.entryPoint, "entryPoint mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.minForsettiVersion, module.manifest.minForsettiVersion, "minForsettiVersion mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.maxForsettiVersion, module.manifest.maxForsettiVersion, "maxForsettiVersion mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.iapProductID, module.manifest.iapProductID, "iapProductID mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.manifestTemplateVersion, module.manifest.manifestTemplateVersion, "manifestTemplateVersion mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.defaultModuleRole, module.manifest.defaultModuleRole, "defaultModuleRole mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.runtimeRequirements, module.manifest.runtimeRequirements, "runtimeRequirements mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.moduleID, module.descriptor.moduleID, "descriptor.moduleID mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.moduleVersion, module.descriptor.moduleVersion, "descriptor.moduleVersion mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.moduleType, module.descriptor.moduleType, "descriptor.moduleType mismatch in \(testCase.fileName)")
        }
    }

    func test_registryContainsEveryBundledEntryPointAndRejectsDuplicates() throws {
        let services = MirmirServices(
            metal: NoopMetalRenderingService(),
            modelAssets: NoopModelAssetsService(),
            media: NoopMediaPipelineService(),
            upscaler: NoopUpscalerEngineService()
        )
        let registry = ModuleRegistry()

        try MirmirModuleRegistry.registerAll(into: registry, services: services)

        let modules = manifestCases().map { $0.buildModule() }
        let expectedEntryPoints = Set(modules.map(\.manifest.entryPoint))
        XCTAssertEqual(Set(registry.registeredEntryPoints), expectedEntryPoints)

        for module in modules {
            let registered = try registry.makeModule(entryPoint: module.manifest.entryPoint)
            XCTAssertEqual(registered.descriptor.moduleID, module.descriptor.moduleID)
            XCTAssertEqual(registered.manifest.entryPoint, module.manifest.entryPoint)
        }

        XCTAssertThrowsError(try MirmirModuleRegistry.registerAll(into: registry, services: services)) { error in
            guard case ModuleRegistryError.duplicateEntryPoint = error else {
                return XCTFail("Expected duplicate entry point failure, got \(error)")
            }
        }
    }

    func test_capabilityPolicyAcceptsEveryCapabilityActuallyRequested() {
        let policy = FixedCapabilityPolicy(allowedCapabilities: MirmirForsettiConstants.allowedCapabilities)
        for testCase in manifestCases() {
            let module = testCase.buildModule()
            for capability in module.manifest.capabilitiesRequested {
                let decision = policy.evaluate(moduleID: module.manifest.moduleID, capability: capability)
                if case .denied(let reason) = decision {
                    XCTFail("\(testCase.fileName) requests capability \(capability.rawValue) which is not allowed: \(reason)")
                }
            }
        }
    }

    private func manifestURL(fileName: String) throws -> URL {
        let bundles = [Bundle.main, Bundle(for: type(of: self))]
        let url = bundles.compactMap { bundle in
            bundle.url(
                forResource: fileName,
                withExtension: "json",
                subdirectory: MirmirForsettiConstants.manifestSubdirectory
            ) ?? bundle.url(forResource: fileName, withExtension: "json")
        }.first
        return try XCTUnwrap(url, "Manifest \(fileName).json not found in test bundle")
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
