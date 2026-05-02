import SwiftUI

struct ForsettiSettingsSheet: View {
    @ObservedObject var controller: ForsettiHostController
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Framework") {
                    HStack {
                        Text("Forsetti Version")
                        Spacer()
                        Text(controller.runtime.forsettiVersion.description)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Platform")
                        Spacer()
                        Text(controller.runtime.platform.rawValue)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Runtime") {
                    HStack {
                        Text("Active Service Modules")
                        Spacer()
                        Text("\(controller.enabledServiceModuleIDs.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Active UI Module")
                        Spacer()
                        Text(controller.activeUIModuleID ?? "None")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}
