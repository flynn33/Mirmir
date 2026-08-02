import SwiftUI

@main
@MainActor
struct MirmirApp: App {
    @State private var viewModel = MirmirViewModel()

    var body: some Scene {
        WindowGroup("Mirmir", id: "main") {
            RootView(viewModel: viewModel)
                .frame(minWidth: 960, minHeight: 680)
        }
        .defaultSize(width: 1_180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") {
                    viewModel.openVideo()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(viewModel.isProcessing)
            }
        }
    }
}
