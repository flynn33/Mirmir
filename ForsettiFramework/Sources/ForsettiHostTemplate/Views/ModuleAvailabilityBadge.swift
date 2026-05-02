import SwiftUI

struct ModuleAvailabilityBadge: View {
    let availability: ForsettiHostModuleAvailability

    var body: some View {
        switch availability {
        case .eligible:
            Text("Eligible")
                .font(.caption2)
                .foregroundStyle(.green)
        case .locked:
            Text("Locked")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .incompatible:
            Text("Incompatible")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}
