import Foundation
import ForsettiCore

/// The dedicated UI module. The only Mirmir module that imports SwiftUI/AppKit.
///
/// `start(context:)` is intentionally light: the actual SwiftUI view is
/// registered in the host's `ForsettiViewInjectionRegistry` (see
/// `MirmirForsettiBootstrap`). Forsetti renders the registered view by
/// resolving `MirmirUIConstants.primaryViewID` from the injection registry
/// when this module is the active UI module.
final class MirmirUIModule: ForsettiUIModule {

    let descriptor = ModuleDescriptor(
        moduleID: MirmirUIConstants.moduleID,
        displayName: MirmirUIConstants.displayName,
        moduleVersion: MirmirUIConstants.moduleVersion,
        moduleType: .ui
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.currentSchemaVersion,
        manifestTemplateVersion: .current,
        moduleID: MirmirUIConstants.moduleID,
        displayName: MirmirUIConstants.displayName,
        moduleVersion: MirmirUIConstants.moduleVersion,
        moduleType: .ui,
        supportedPlatforms: [.macOS],
        minForsettiVersion: MirmirForsettiConstants.minForsettiVersion,
        maxForsettiVersion: nil,
        capabilitiesRequested: [.viewInjection],
        iapProductID: nil,
        entryPoint: MirmirUIConstants.entryPoint,
        defaultModuleRole: .ui,
        runtimeRequirements: ModuleRuntimeRequirements(
            ui: ModuleUIRequirements(
                viewIDs: [MirmirUIConstants.primaryViewID],
                slotIDs: [MirmirUIConstants.primarySlot]
            )
        )
    )

    let uiContributions: UIContributions = UIContributions(
        themeMask: nil,
        toolbarItems: [],
        viewInjections: [
            ViewInjectionDescriptor(
                injectionID: "\(MirmirUIConstants.moduleID).workspace",
                slot: MirmirUIConstants.primarySlot,
                viewID: MirmirUIConstants.primaryViewID,
                priority: 100
            )
        ],
        overlaySchema: nil
    )

    private var didStart = false

    init() {}

    func start(context: any ForsettiModuleContext) throws {
        guard !didStart else { return }
        didStart = true
        context.logger.info("Mirmir UI module activated")
    }

    func stop(context _: any ForsettiModuleContext) {
        guard didStart else { return }
        didStart = false
    }
}
