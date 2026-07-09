import SwiftUI

struct MirmirPanel<Content: View>: View {
    let theme: MirmirThemeTokens
    let content: Content

    init(theme: MirmirThemeTokens, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        content
            .padding(theme.spacing.space4)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .fill(theme.surfaceElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.large)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
            .shadow(color: theme.shadowAmbient, radius: 10, y: 4)
    }
}

struct MirmirPrimaryButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.viewerOverlayText)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, theme.spacing.space4)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(configuration.isPressed ? theme.accentSecondary : theme.accentPrimary)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.focusRing.opacity(configuration.isPressed ? 1 : 0), lineWidth: 1)
            }
    }
}

struct MirmirSecondaryButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.textPrimary)
            .frame(minHeight: 34)
            .padding(.horizontal, theme.spacing.space3)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(configuration.isPressed ? theme.surfacePressed : theme.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
    }
}

struct MirmirIconButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(configuration.isPressed ? theme.surfacePressed : theme.surfaceElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
    }
}

struct MirmirFieldRow<Content: View>: View {
    let title: String
    let theme: MirmirThemeTokens
    let content: Content

    init(_ title: String, theme: MirmirThemeTokens, @ViewBuilder content: () -> Content) {
        self.title = title
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Text(title)
                .font(theme.typography.captionEmphasis)
                .foregroundStyle(theme.textSecondary)
            content
                .font(theme.typography.body)
        }
    }
}

struct MirmirStatusCard: View {
    let title: String
    let primary: String
    let secondary: String
    let symbolName: String
    let tone: MirmirStatusTone
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: symbolName)
                    .foregroundStyle(tone.color(theme: theme))
                Text(title)
                    .font(theme.typography.captionEmphasis)
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }

            Text(primary)
                .font(theme.typography.bodyEmphasis.monospacedDigit())
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Text(secondary)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(2)
        }
        .padding(theme.spacing.space3)
        .frame(minWidth: 150, maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large)
                .fill(theme.surfaceElevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.radius.large)
                .stroke(tone.borderColor(theme: theme), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

enum MirmirStatusTone {
    case neutral
    case active
    case success
    case warning
    case danger

    func color(theme: MirmirThemeTokens) -> Color {
        switch self {
        case .neutral:
            return theme.textTertiary
        case .active:
            return theme.info
        case .success:
            return theme.success
        case .warning:
            return theme.warning
        case .danger:
            return theme.danger
        }
    }

    func borderColor(theme: MirmirThemeTokens) -> Color {
        switch self {
        case .neutral:
            return theme.borderSubtle
        default:
            return color(theme: theme)
        }
    }
}

extension MirmirViewModel.JobState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var statusTitle: String {
        switch self {
        case .idle:
            return "Idle"
        case .probing:
            return "Analyzing source"
        case .ready:
            return "Ready"
        case .running:
            return "Running"
        case .finished:
            return "Complete"
        case .failed:
            return "Failed"
        }
    }
}
