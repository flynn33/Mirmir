import SwiftUI

enum MirmirTheme {
    static func tokens(for colorScheme: ColorScheme) -> MirmirThemeTokens {
        colorScheme == .dark ? .midnightNordic : .arcticIndigo
    }
}

enum MirmirAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case midnightNordic
    case arcticIndigo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .midnightNordic:
            return "Midnight Nordic"
        case .arcticIndigo:
            return "Arctic Indigo"
        }
    }

    func tokens(for colorScheme: ColorScheme) -> MirmirThemeTokens {
        switch self {
        case .system:
            return MirmirTheme.tokens(for: colorScheme)
        case .midnightNordic:
            return .midnightNordic
        case .arcticIndigo:
            return .arcticIndigo
        }
    }
}

struct MirmirThemeTokens {
    let name: String
    let background: Color
    let backgroundAlt: Color
    let surface: Color
    let surfaceElevated: Color
    let surfaceInset: Color
    let surfaceHover: Color
    let surfacePressed: Color
    let borderSubtle: Color
    let borderStrong: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textDisabled: Color
    let accentPrimary: Color
    let accentSecondary: Color
    let accentMuted: Color
    let success: Color
    let warning: Color
    let danger: Color
    let info: Color
    let viewerOverlay: Color
    let viewerOverlayText: Color
    let focusRing: Color
    let shadowAmbient: Color
    let shadowElevated: Color
    let spacing = MirmirSpacingTokens()
    let radius = MirmirRadiusTokens()
    let typography = MirmirTypographyTokens()

    static let midnightNordic = MirmirThemeTokens(
        name: "Midnight Nordic",
        background: Color(hex: 0x08111A),
        backgroundAlt: Color(hex: 0x0B1621),
        surface: Color(hex: 0x101C28),
        surfaceElevated: Color(hex: 0x152434),
        surfaceInset: Color(hex: 0x071019),
        surfaceHover: Color(hex: 0x1B2D40),
        surfacePressed: Color(hex: 0x22384E),
        borderSubtle: Color(hex: 0x213142),
        borderStrong: Color(hex: 0x385169),
        textPrimary: Color(hex: 0xF2F7FA),
        textSecondary: Color(hex: 0xB8C7D3),
        textTertiary: Color(hex: 0x7F93A4),
        textDisabled: Color(hex: 0x526575),
        accentPrimary: Color(hex: 0x75A9D6),
        accentSecondary: Color(hex: 0x9FC4E3),
        accentMuted: Color(hex: 0x375C78),
        success: Color(hex: 0x73C7A5),
        warning: Color(hex: 0xE3B868),
        danger: Color(hex: 0xE06F6F),
        info: Color(hex: 0x89B8E8),
        viewerOverlay: Color(hex: 0x02070B, opacity: 0.8),
        viewerOverlayText: Color(hex: 0xFFFFFF),
        focusRing: Color(hex: 0x8DC8F5),
        shadowAmbient: Color(hex: 0x000000, opacity: 0.2),
        shadowElevated: Color(hex: 0x000000, opacity: 0.4)
    )

    static let arcticIndigo = MirmirThemeTokens(
        name: "Arctic Indigo",
        background: Color(hex: 0xF6F9FC),
        backgroundAlt: Color(hex: 0xEDF3F8),
        surface: Color(hex: 0xFFFFFF),
        surfaceElevated: Color(hex: 0xF9FBFD),
        surfaceInset: Color(hex: 0xE8F0F7),
        surfaceHover: Color(hex: 0xEAF2F9),
        surfacePressed: Color(hex: 0xDCE9F3),
        borderSubtle: Color(hex: 0xD8E3EC),
        borderStrong: Color(hex: 0xB7C9D8),
        textPrimary: Color(hex: 0x162331),
        textSecondary: Color(hex: 0x4B6073),
        textTertiary: Color(hex: 0x7A8EA0),
        textDisabled: Color(hex: 0xA3B1BD),
        accentPrimary: Color(hex: 0x2F6F9F),
        accentSecondary: Color(hex: 0x5D92BD),
        accentMuted: Color(hex: 0xD8E9F5),
        success: Color(hex: 0x2F9E78),
        warning: Color(hex: 0xB77A22),
        danger: Color(hex: 0xC94A4A),
        info: Color(hex: 0x2F7FBF),
        viewerOverlay: Color(hex: 0x07111B, opacity: 0.8),
        viewerOverlayText: Color(hex: 0xFFFFFF),
        focusRing: Color(hex: 0x2F8FCE),
        shadowAmbient: Color(hex: 0x24384A, opacity: 0.1),
        shadowElevated: Color(hex: 0x24384A, opacity: 0.2)
    )
}

struct MirmirSpacingTokens {
    let space1: CGFloat = 4
    let space2: CGFloat = 8
    let space3: CGFloat = 12
    let space4: CGFloat = 16
    let space5: CGFloat = 20
    let space6: CGFloat = 24
    let space8: CGFloat = 32
    let space10: CGFloat = 40
}

struct MirmirRadiusTokens {
    let small: CGFloat = 6
    let medium: CGFloat = 8
    let large: CGFloat = 12
    let xlarge: CGFloat = 16

    var radiusSmall: CGFloat { small }
    var radiusMedium: CGFloat { medium }
    var radiusLarge: CGFloat { large }
    var radiusXLarge: CGFloat { xlarge }
}

struct MirmirTypographyTokens {
    let display = Font.system(size: 28, weight: .semibold)
    let title = Font.system(size: 22, weight: .semibold)
    let subtitle = Font.system(size: 17, weight: .medium)
    let headline = Font.system(size: 15, weight: .semibold)
    let body = Font.system(size: 13, weight: .regular)
    let bodyEmphasis = Font.system(size: 13, weight: .medium)
    let caption = Font.system(size: 11, weight: .regular)
    let captionEmphasis = Font.system(size: 11, weight: .medium)
    let micro = Font.system(size: 10, weight: .medium)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
