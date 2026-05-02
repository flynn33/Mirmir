//___FILEHEADER___

import SwiftUI

struct ___PACKAGENAME:identifier___UIModuleView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("___PACKAGENAME___ UI Module")
                .font(.title.bold())

            Text("Replace this with the app-facing UI for your module. Keep routing/events in module contracts, not host internals.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

#Preview {
    ___PACKAGENAME:identifier___UIModuleView()
}
