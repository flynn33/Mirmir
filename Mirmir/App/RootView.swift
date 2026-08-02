import CoreMedia
import SwiftUI

struct RootView: View {
    let viewModel: MirmirViewModel

    var body: some View {
        MirmirWorkspaceRootView(viewModel: viewModel)
    }

    // Kept on the root surface because these formatting contracts are useful
    // to both the workspace and the focused view-model tests.
    func sizeText(_ size: CGSize?) -> String {
        MirmirPresentation.sizeText(size)
    }

    func durationText(_ duration: CMTime) -> String {
        MirmirPresentation.durationText(duration)
    }
}
