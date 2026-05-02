//___FILEHEADER___

#if canImport(ForsettiCore)
import Foundation
import ForsettiCore

final class ___PACKAGENAME:identifier___UIModule: ForsettiUIModule {
    enum Constants {
        static let moduleID = "com.yourcompany.___PACKAGENAME:identifier___.ui-module"
        static let entryPoint = "___PACKAGENAME:identifier___UIModule"
        static let workspaceViewID = "___PACKAGENAME:identifier___.ui-module.workspace"
    }

    let descriptor = ModuleDescriptor(
        moduleID: Constants.moduleID,
        displayName: "___PACKAGENAME___ UI Module",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui
    )

    let manifest = ModuleManifest(
        schemaVersion: ModuleManifest.supportedSchemaVersion,
        moduleID: Constants.moduleID,
        displayName: "___PACKAGENAME___ UI Module",
        moduleVersion: SemVer(major: 1, minor: 0, patch: 0),
        moduleType: .ui,
        supportedPlatforms: [.iOS, .macOS],
        minForsettiVersion: SemVer(major: 0, minor: 1, patch: 0),
        capabilitiesRequested: [.toolbarItems, .viewInjection],
        iapProductID: nil,
        entryPoint: Constants.entryPoint
    )

    let uiContributions = UIContributions(
        toolbarItems: [
            ToolbarItemDescriptor(
                itemID: "___PACKAGENAME:identifier___.ui-module.refresh",
                title: "Send Event",
                systemImageName: "paperplane.fill",
                action: .publishEvent(type: "ui_module_action", payload: ["moduleID": Constants.moduleID])
            )
        ],
        viewInjections: [
            ViewInjectionDescriptor(
                injectionID: "___PACKAGENAME:identifier___.ui-module.workspace",
                slot: "module.workspace",
                viewID: Constants.workspaceViewID,
                priority: 100
            )
        ]
    )

    private var isStarted = false

    init() {}

    func start(context: ForsettiContext) throws {
        guard !isStarted else {
            return
        }

        isStarted = true
        context.moduleLogger(moduleID: descriptor.moduleID).info("UI module started")
    }

    func stop(context: ForsettiContext) {
        guard isStarted else {
            return
        }

        isStarted = false
        context.moduleLogger(moduleID: descriptor.moduleID).info("UI module stopped")
    }
}
#endif
