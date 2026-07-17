import Darwin
import SwiftUI

@main
struct MirmirApp: App {
    private let p08LaunchDisposition: ASHP08ProductionEvidenceRunner.LaunchDisposition

    init() {
        let disposition = ASHP08ProductionEvidenceRunner.launchDisposition()
        p08LaunchDisposition = disposition
        switch disposition {
        case .normal:
            break
        case .requested:
            Task.detached {
                await ASHP08ProductionEvidenceRunner.runAndExit()
            }
        case .invalid:
            fputs(
                "P08 native mode requires the exact launch argument and environment pair\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        WindowGroup("Mirmir") {
            if p08LaunchDisposition == .normal {
                ContentView()
                    .frame(minWidth: 1024, minHeight: 640)
            } else {
                EmptyView()
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
