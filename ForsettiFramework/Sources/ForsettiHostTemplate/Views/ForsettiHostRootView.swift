import SwiftUI
import ForsettiCore

public struct ForsettiHostRootView: View {
    @ObservedObject private var controller: ForsettiHostController
    private let injectionRegistry: ForsettiViewInjectionRegistry
    /// Controls whether Forsetti developer controls (Home, Settings, module switcher, error alerts)
    /// are visible. Set to `true` during development and testing (Pattern C / dashboard use).
    /// Set to `false` for production deployments (Pattern A / B) where the framework runs silently
    /// and end users interact only with the module's own UI.
    private let showDeveloperControls: Bool
    private let launchActivationStrategy: ForsettiLaunchActivationStrategy

    @State private var isSettingsPresented = false
    @State private var isFrameworkChromeVisible: Bool

    public init(
        controller: ForsettiHostController,
        injectionRegistry: ForsettiViewInjectionRegistry = ForsettiViewInjectionRegistry(),
        showDeveloperControls: Bool = true,
        launchActivationStrategy: ForsettiLaunchActivationStrategy = .restoreOnly
    ) {
        self.controller = controller
        self.injectionRegistry = injectionRegistry
        self.showDeveloperControls = showDeveloperControls
        self.launchActivationStrategy = launchActivationStrategy
        _isFrameworkChromeVisible = State(initialValue: showDeveloperControls)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                if isFrameworkChromeVisible {
                    frameworkChrome
                }

                if let selectedModule = controller.selectedModuleItem() {
                    moduleWorkspace(module: selectedModule)
                } else {
                    frameworkHome
                }
            }

            if !isFrameworkChromeVisible && showDeveloperControls {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFrameworkChromeVisible = true
                    }
                } label: {
                    Label("Show Menus", systemImage: "line.3.horizontal")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thickMaterial, in: Capsule())
                }
                .padding(12)
                .accessibilityLabel("Show Forsetti framework controls")
            }
        }
        .task {
            await controller.bootIfNeeded(activationStrategy: launchActivationStrategy)
        }
        .refreshable {
            await controller.refreshModuleState()
        }
        .sheet(isPresented: $isSettingsPresented) {
            ForsettiSettingsSheet(controller: controller, isPresented: $isSettingsPresented)
        }
        .alert(
            "Forsetti Error",
            isPresented: Binding(
                get: { showDeveloperControls && controller.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        controller.clearError()
                    }
                }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    controller.clearError()
                }
            },
            message: {
                Text(controller.errorMessage ?? "Unknown error")
            }
        )
    }

    private var frameworkChrome: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    controller.goHome()
                } label: {
                    Image(systemName: "house.fill")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("Forsetti Home")

                GuideInfoButton(
                    text: "Home always returns to the default Forsetti module dashboard."
                )
            }

            Spacer()

            Text(controller.selectedModuleID == nil ? "Forsetti Home" : "Module Workspace")
                .font(.headline)

            Spacer()

            HStack(spacing: 8) {
                GuideInfoButton(
                    text: "Settings is a developer framework control. It should not be visible in production deployments. "
                        + "Use showDeveloperControls: false when deploying to end users."
                )

                Button {
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("Forsetti Settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var frameworkHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modulesOverview
                frameworkActions
            }
            .padding(16)
        }
    }

    private var modulesOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installed Modules")
                    .font(.title3.bold())

                GuideInfoButton(
                    text: "Service modules can run concurrently. Opening a UI module makes it the active UI module."
                )
            }

            if controller.serviceModules.isEmpty, controller.uiModules.isEmpty {
                Text("No modules discovered.")
                    .foregroundStyle(.secondary)
            }

            if !controller.serviceModules.isEmpty {
                Text("Service Modules")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ForEach(controller.serviceModules) { module in
                    serviceModuleCard(module: module)
                }
            }

            if !controller.uiModules.isEmpty {
                Text("UI Modules")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ForEach(controller.uiModules) { module in
                    uiModuleCard(module: module)
                }
            }
        }
    }

    private var frameworkActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Framework Actions")
                    .font(.title3.bold())

                GuideInfoButton(
                    text: "These controls are provided by Forsetti and apply globally to all modules."
                )
            }

            HStack(spacing: 8) {
                Button("Refresh Entitlements") {
                    Task {
                        await controller.refreshEntitlements()
                    }
                }
                GuideInfoButton(
                    text: "Re-queries module unlock state from Forsetti entitlement services."
                )
            }

            if hasPurchasableModules {
                HStack(spacing: 8) {
                    Button("Restore Purchases") {
                        Task {
                            await controller.restorePurchases()
                        }
                    }
                    GuideInfoButton(
                        text: "Runs the restore flow and refreshes paid module access."
                    )
                }
            }

            if let lastAction = controller.lastToolbarActionDescription {
                Text("Last module action: \(lastAction)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func serviceModuleCard(module: ForsettiHostModuleItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    isOn: Binding(
                        get: { module.isActive },
                        set: { isEnabled in
                            Task {
                                await controller.setServiceModuleEnabled(moduleID: module.moduleID, isEnabled: isEnabled)
                            }
                        }
                    )
                ) {
                    Text(module.displayName)
                        .font(.headline)
                }
                .disabled(!module.canActivate && !module.isActive)

                GuideInfoButton(
                    text: "Service module activation controls background module runtime state."
                )
            }

            moduleMeta(module: module)

            HStack(spacing: 8) {
                Button("Open") {
                    Task {
                        await controller.openModule(moduleID: module.moduleID)
                    }
                }
                .disabled(!module.canActivate && !module.isActive)

                GuideInfoButton(
                    text: "Open moves into the module workspace while preserving Forsetti shell controls."
                )
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func uiModuleCard(module: ForsettiHostModuleItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    isOn: Binding(
                        get: { module.isActive },
                        set: { isEnabled in
                            Task {
                                await controller.setUIModuleEnabled(moduleID: module.moduleID, isEnabled: isEnabled)
                            }
                        }
                    )
                ) {
                    Text(module.displayName)
                        .font(.headline)
                }
                .disabled(!module.canActivate && !module.isActive)

                GuideInfoButton(
                    text: "Activating a UI module replaces the previously active UI module."
                )
            }

            moduleMeta(module: module)

            HStack(spacing: 8) {
                Button("Open") {
                    Task {
                        await controller.openModule(moduleID: module.moduleID)
                    }
                }
                .disabled(!module.canActivate && !module.isActive)

                GuideInfoButton(
                    text: "Open activates this UI module and deactivates the previously active UI module."
                )
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func moduleMeta(module: ForsettiHostModuleItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(module.moduleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ModuleAvailabilityBadge(availability: module.availability)
            }

            if let reason = module.availability.userFacingReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func moduleWorkspace(module: ForsettiHostModuleItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(module.displayName)
                            .font(.title2.bold())
                        Spacer()
                        ModuleAvailabilityBadge(availability: module.availability)
                    }

                    Text(module.moduleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showDeveloperControls {
                        HStack(spacing: 8) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isFrameworkChromeVisible = false
                                }
                            } label: {
                                Label("Hide Framework Menus", systemImage: "rectangle.compress.vertical")
                            }

                            GuideInfoButton(
                                text: "In developer mode, modules may temporarily hide framework chrome. "
                                    + "Use the top-left Show Menus control to reveal it again. "
                                    + "In production (showDeveloperControls: false), framework chrome is permanently hidden."
                            )
                        }
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if module.moduleType == .ui || module.moduleType == .app {
                    ForsettiModuleContributionsView(
                        controller: controller,
                        injectionRegistry: injectionRegistry,
                        moduleID: module.moduleID
                    )
                } else {
                    Text("This service module is running in the framework runtime. Use Home to switch modules.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

private extension ForsettiHostRootView {
    private var hasPurchasableModules: Bool {
        let allModules = controller.serviceModules + controller.uiModules
        return allModules.contains { $0.manifest.iapProductID != nil }
    }
}
