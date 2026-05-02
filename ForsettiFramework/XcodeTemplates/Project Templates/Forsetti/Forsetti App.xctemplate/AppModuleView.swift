//___FILEHEADER___

import SwiftUI

struct ___PACKAGENAME:identifier___AppModuleView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("___PACKAGENAME___")
                    .font(.largeTitle.bold())

                Text("This is your app-owned Forsetti starter module UI. Replace this view with your first production feature surface.")
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Next steps")
                        .font(.headline)
                    Text("1. Build your first app feature in this view/module.")
                    Text("2. Add service modules as your app grows.")
                    Text("3. Keep manifest and module constants aligned.")
                }
                .font(.subheadline)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("App Module")
        }
    }
}

#Preview {
    ___PACKAGENAME:identifier___AppModuleView()
}
