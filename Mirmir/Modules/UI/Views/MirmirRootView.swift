import SwiftUI

struct MirmirRootView: View {

    @ObservedObject var viewModel: MirmirViewModel

    var body: some View {
        MirmirWorkflowRootView(viewModel: viewModel)
    }
}
