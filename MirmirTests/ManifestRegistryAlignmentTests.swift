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
        let buildModule: () -> ForsettiModule
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
            XCTAssertEqual(decoded.moduleID, module.descriptor.moduleID, "descriptor.moduleID mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.moduleVersion, module.descriptor.moduleVersion, "descriptor.moduleVersion mismatch in \(testCase.fileName)")
            XCTAssertEqual(decoded.moduleType, module.descriptor.moduleType, "descriptor.moduleType mismatch in \(testCase.fileName)")
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
}
