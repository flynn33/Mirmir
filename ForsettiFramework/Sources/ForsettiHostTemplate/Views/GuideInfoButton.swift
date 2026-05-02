import SwiftUI

struct GuideInfoButton: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: 280, alignment: .leading)
        }
        .accessibilityLabel("Guide")
    }
}
