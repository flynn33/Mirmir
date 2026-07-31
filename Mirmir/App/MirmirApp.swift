import Darwin
import SwiftUI

@MainActor
private final class MirmirApplicationState: ObservableObject {
    let composition: MirmirAppComposition?

    init(
        launchDisposition:
            ASHP08ProductionEvidenceRunner.LaunchDisposition
    ) {
        if launchDisposition == .normal {
            composition = MirmirAppComposition()
        } else {
            composition = nil
        }
    }
}

@main
struct MirmirApp: App {
    private let p08LaunchDisposition: ASHP08ProductionEvidenceRunner.LaunchDisposition
    @StateObject private var applicationState: MirmirApplicationState

    init() {
        let disposition = ASHP08ProductionEvidenceRunner.launchDisposition()
        p08LaunchDisposition = disposition
        _applicationState = StateObject(
            wrappedValue: MirmirApplicationState(
                launchDisposition: disposition
            )
        )
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
            if p08LaunchDisposition == .normal,
               let composition = applicationState.composition {
                ContentView(composition: composition)
                    .frame(minWidth: 1024, minHeight: 640)
            } else {
                EmptyView()
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            if p08LaunchDisposition == .normal,
               let composition = applicationState.composition {
                MirmirNativeSettingsRoot(
                    composition: composition
                )
            } else {
                EmptyView()
            }
        }
    }
}

private struct MirmirNativeSettingsRoot: View {
    @ObservedObject var composition: MirmirAppComposition

    var body: some View {
        switch composition.state {
        case .ready(let bootstrap):
            MirmirSettingsView(viewModel: bootstrap.viewModel)
        case .failed(let reason):
            MirmirStartupDiagnosticSettingsView(
                store: composition.diagnosticStore,
                reason: reason
            )
        }
    }
}
