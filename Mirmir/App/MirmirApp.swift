import SwiftUI

@main
struct MirmirApp: App {
    var body: some Scene {
        WindowGroup("Mirmir") {
            ContentView()
                .frame(minWidth: 1024, minHeight: 640)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
