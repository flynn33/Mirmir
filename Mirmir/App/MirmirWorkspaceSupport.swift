import CoreMedia
import SwiftUI

enum MirmirPresentation {
    static func sizeText(_ size: CGSize?) -> String {
        guard let size,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              let width = Int(exactly: size.width.rounded()),
              let height = Int(exactly: size.height.rounded()),
              width > 0,
              height > 0 else {
            return "Unknown"
        }
        return "\(width) × \(height)"
    }

    static func durationText(_ duration: CMTime) -> String {
        let seconds = CMTimeGetSeconds(duration)
        guard duration.isNumeric,
              seconds.isFinite,
              seconds >= 0,
              let wholeSeconds = Int(exactly: seconds.rounded()) else {
            return "Unknown"
        }
        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        let remainingSeconds = wholeSeconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func frameRateText(_ rate: Float?) -> String {
        rate.map { String(format: "%.3f fps", $0) } ?? "Unknown"
    }

    static func timeIntervalText(_ time: CMTime?) -> String {
        guard let time else { return "Unknown" }
        let seconds = CMTimeGetSeconds(time)
        guard time.isNumeric, seconds.isFinite, seconds > 0 else {
            return "Unknown"
        }
        return String(format: "%.3f ms", seconds * 1_000)
    }

    static func dataRateText(_ rate: Float?) -> String {
        rate.map { String(format: "%.3f Mb/s", Double($0) / 1_000_000) }
            ?? "Unknown"
    }

    static func fileSizeText(_ byteCount: Int64?) -> String {
        guard let byteCount else { return "Unknown" }
        return ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    static func audioText(_ info: VideoInfo) -> String {
        guard info.hasAudio else { return "Absent" }
        let suffix = info.audioTrackCount == 1 ? "track" : "tracks"
        return "Present (\(info.audioTrackCount) \(suffix))"
    }

    static func rangeText(_ isFullRange: Bool?) -> String {
        guard let isFullRange else { return "Unknown" }
        return isFullRange ? "Full" : "Video"
    }

    static func apertureText(_ aperture: CGRect?) -> String {
        guard let aperture else { return "Unknown" }
        return String(
            format: "%.0f × %.0f at (%.0f, %.0f)",
            aperture.width,
            aperture.height,
            aperture.origin.x,
            aperture.origin.y
        )
    }

    static func pixelAspectRatioText(
        _ ratio: VideoPixelAspectRatio?
    ) -> String {
        guard let ratio else { return "Unknown" }
        return "\(ratio.horizontalSpacing):\(ratio.verticalSpacing)"
    }

    static func compatibilityWarning(for info: VideoInfo) -> String? {
        var limitations: [String] = []
        if info.color.dynamicRange == .hdr || (info.color.bitDepth ?? 0) > 8 {
            limitations.append(
                "This build has no end-to-end HDR/P010 preservation path. "
                    + "Unsupported methods remain unavailable rather than "
                    + "tone-mapping silently."
            )
        }
        if (info.color.fieldCount ?? 1) > 1 || info.color.fieldDetail != nil {
            limitations.append(
                "Interlaced sources require a defined deinterlace stage."
            )
        }
        if let ratio = info.geometry.pixelAspectRatio,
           ratio.horizontalSpacing != ratio.verticalSpacing {
            limitations.append("Non-square pixels reduce method availability.")
        }
        if let encodedWidth = info.geometry.encodedSize?.width,
           encodedWidth > 1_920 {
            limitations.append(
                "Apple’s quality super-resolution video initializer is "
                    + "limited to 1920-pixel source width."
            )
        }
        return limitations.isEmpty ? nil : limitations.joined(separator: " ")
    }
}

struct MirmirProductPanel<Content: View>: View {
    let theme: MirmirThemeTokens
    let content: Content

    init(
        theme: MirmirThemeTokens,
        @ViewBuilder content: () -> Content
    ) {
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

struct MirmirProductPrimaryButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.viewerOverlayText)
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, theme.spacing.space4)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        configuration.isPressed
                            ? theme.accentSecondary
                            : theme.accentPrimary
                    )
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.45)
    }
}

struct MirmirProductSecondaryButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.textPrimary)
            .frame(minHeight: 34)
            .padding(.horizontal, theme.spacing.space3)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        configuration.isPressed
                            ? theme.surfacePressed
                            : theme.surface
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct MirmirProductIconButtonStyle: ButtonStyle {
    let theme: MirmirThemeTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.typography.bodyEmphasis)
            .foregroundStyle(theme.textSecondary)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(
                        configuration.isPressed
                            ? theme.surfacePressed
                            : theme.surfaceElevated
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .stroke(theme.borderSubtle, lineWidth: 1)
            }
    }
}

struct MirmirProductField<Content: View>: View {
    let title: String
    let theme: MirmirThemeTokens
    let content: Content

    init(
        _ title: String,
        theme: MirmirThemeTokens,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.theme = theme
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            Text(title.uppercased())
                .font(theme.typography.micro)
                .foregroundStyle(theme.textTertiary)
            content
                .font(theme.typography.body)
        }
    }
}

struct MirmirProductStatusCard: View {
    let title: String
    let primary: String
    let secondary: String
    let symbolName: String
    let tone: MirmirProductStatusTone
    let theme: MirmirThemeTokens

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.space2) {
            HStack(spacing: theme.spacing.space2) {
                Image(systemName: symbolName)
                    .foregroundStyle(tone.color(theme: theme))
                Text(title.uppercased())
                    .font(theme.typography.micro)
                    .foregroundStyle(theme.textTertiary)
                Spacer(minLength: 0)
            }
            Text(primary)
                .font(theme.typography.bodyEmphasis.monospacedDigit())
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(secondary)
                .font(theme.typography.caption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
        }
        .padding(theme.spacing.space3)
        .frame(minWidth: 145, maxWidth: .infinity, minHeight: 88, alignment: .leading)
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

enum MirmirProductStatusTone: Equatable {
    case neutral
    case active
    case success
    case warning
    case danger

    func color(theme: MirmirThemeTokens) -> Color {
        switch self {
        case .neutral: theme.textTertiary
        case .active: theme.info
        case .success: theme.success
        case .warning: theme.warning
        case .danger: theme.danger
        }
    }

    func borderColor(theme: MirmirThemeTokens) -> Color {
        self == .neutral ? theme.borderSubtle : color(theme: theme)
    }
}
