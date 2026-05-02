//___FILEHEADER___

import Foundation

enum ___PACKAGENAME:identifier___DeploymentMode: String {
    case development
    case production

    // Start in development mode so the generated app immediately exposes Forsetti controls.
    // Switch to .production before shipping to end users.
    static let current: ___PACKAGENAME:identifier___DeploymentMode = .development

    static var deploymentPatternGuidance: String {
        switch current {
        case .development:
            return "Pattern C (developer testing): framework controls are visible."
        case .production:
            return "Pattern A/B (production): app-owned module UI is primary."
        }
    }
}
