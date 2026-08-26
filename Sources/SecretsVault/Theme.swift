import SwiftUI
import AppKit

// MARK: - Hex color helper

extension Color {
    /// Opaque sRGB color from a 24-bit RGB value, e.g. `Color(hex: 0x282A36)`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Theme

/// Semantic color tokens for one theme. A nil token means "use the native
/// system look", so the built-in System theme (all nil) renders the app
/// exactly as it did before theming existed.
struct Theme: Identifiable {
    let id: String
    let name: String

    /// Forced appearance; nil follows the macOS light/dark setting.
    var colorScheme: ColorScheme? = nil
    var accent: Color? = nil

    /// Unlock/setup screens and the window at large.
    var windowBackground: Color? = nil
    /// Editor and markdown preview area.
    var contentBackground: Color? = nil
    /// Sidebar list; nil keeps the native translucent material.
    var sidebarBackground: Color? = nil

    var textPrimary: Color? = nil
    var textSecondary: Color? = nil

    var codeBackground: Color? = nil
    var codeBorder: Color? = nil
    var codeText: Color? = nil

    /// Accent bar next to block quotes; nil derives from the accent color.
    var quoteBar: Color? = nil
    /// Markdown heading color; nil falls back to the primary text color.
    var headingColor: Color? = nil

    // MARK: Resolved fallbacks — views use these and never branch on nil.

    var resolvedAccent: Color { accent ?? .accentColor }
    var resolvedTextPrimary: Color { textPrimary ?? .primary }
    var resolvedTextSecondary: Color { textSecondary ?? Color(nsColor: .secondaryLabelColor) }
    var resolvedTextTertiary: Color { textSecondary?.opacity(0.75) ?? Color(nsColor: .tertiaryLabelColor) }
    var resolvedCodeBackground: Color { codeBackground ?? Color.primary.opacity(0.06) }
    var resolvedCodeBorder: Color { codeBorder ?? Color.primary.opacity(0.08) }
    var resolvedCodeText: Color { codeText ?? resolvedTextPrimary }
    var resolvedQuoteBar: Color { quoteBar ?? resolvedAccent.opacity(0.6) }
    var resolvedHeading: Color { headingColor ?? resolvedTextPrimary }
    /// Subtle banner surface (e.g. the Recently Deleted strip).
    var resolvedBanner: Color { codeBackground ?? Color.primary.opacity(0.05) }
}

// MARK: - Built-in themes

extension Theme {

    // Native family

    static let system = Theme(id: "system", name: "System")

    static let light = Theme(
        id: "light", name: "Light",
        colorScheme: .light,
        accent: Color(hex: 0x007AFF)
    )

    static let dark = Theme(
        id: "dark", name: "Dark",
        colorScheme: .dark,
        accent: Color(hex: 0x0A84FF)
    )

    static let midnight = Theme(
        id: "midnight", name: "Midnight",
        colorScheme: .dark,
        accent: Color(hex: 0x5E5CE6),
        windowBackground: Color(hex: 0x000000),
        contentBackground: Color(hex: 0x000000),
        sidebarBackground: Color(hex: 0x0C0C11),
        textPrimary: Color(hex: 0xE5E5EA),
        textSecondary: Color(hex: 0x8E8E93),
        codeBackground: Color(hex: 0x131318),
        codeBorder: Color(hex: 0x2A2A31),
        codeText: Color(hex: 0xE5E5EA)
    )

    // Developer classics

    static let solarizedLight = Theme(
        id: "solarized-light", name: "Solarized Light",
        colorScheme: .light,
        accent: Color(hex: 0x268BD2),
        windowBackground: Color(hex: 0xFDF6E3),
        contentBackground: Color(hex: 0xFDF6E3),
        sidebarBackground: Color(hex: 0xEEE8D5),
        textPrimary: Color(hex: 0x586E75),
        textSecondary: Color(hex: 0x93A1A1),
        codeBackground: Color(hex: 0xEEE8D5),
        codeBorder: Color(hex: 0xDCD4BC),
        codeText: Color(hex: 0x657B83)
    )

    static let solarizedDark = Theme(
        id: "solarized-dark", name: "Solarized Dark",
        colorScheme: .dark,
        accent: Color(hex: 0x268BD2),
        windowBackground: Color(hex: 0x002B36),
        contentBackground: Color(hex: 0x002B36),
        sidebarBackground: Color(hex: 0x073642),
        textPrimary: Color(hex: 0x93A1A1),
        textSecondary: Color(hex: 0x586E75),
        codeBackground: Color(hex: 0x073642),
        codeBorder: Color(hex: 0x14515F),
        codeText: Color(hex: 0x93A1A1)
    )

    static let dracula = Theme(
        id: "dracula", name: "Dracula",
        colorScheme: .dark,
        accent: Color(hex: 0xBD93F9),
        windowBackground: Color(hex: 0x282A36),
        contentBackground: Color(hex: 0x282A36),
        sidebarBackground: Color(hex: 0x21222C),
        textPrimary: Color(hex: 0xF8F8F2),
        textSecondary: Color(hex: 0x6272A4),
        codeBackground: Color(hex: 0x44475A),
        codeBorder: Color(hex: 0x565869),
        codeText: Color(hex: 0xF8F8F2),
        quoteBar: Color(hex: 0xFF79C6)
    )

    static let nord = Theme(
        id: "nord", name: "Nord",
        colorScheme: .dark,
        accent: Color(hex: 0x88C0D0),
        windowBackground: Color(hex: 0x2E3440),
        contentBackground: Color(hex: 0x2E3440),
        sidebarBackground: Color(hex: 0x3B4252),
        textPrimary: Color(hex: 0xD8DEE9),
        textSecondary: Color(hex: 0x616E88),
        codeBackground: Color(hex: 0x3B4252),
        codeBorder: Color(hex: 0x4C566A),
        codeText: Color(hex: 0xECEFF4)
    )

    static let gruvboxDark = Theme(
        id: "gruvbox-dark", name: "Gruvbox Dark",
        colorScheme: .dark,
        accent: Color(hex: 0xFABD2F),
        windowBackground: Color(hex: 0x282828),
        contentBackground: Color(hex: 0x282828),
        sidebarBackground: Color(hex: 0x1D2021),
        textPrimary: Color(hex: 0xEBDBB2),
        textSecondary: Color(hex: 0x928374),
        codeBackground: Color(hex: 0x3C3836),
        codeBorder: Color(hex: 0x504945),
        codeText: Color(hex: 0xEBDBB2)
    )

    static let gruvboxLight = Theme(
        id: "gruvbox-light", name: "Gruvbox Light",
        colorScheme: .light,
        accent: Color(hex: 0xD65D0E),
        windowBackground: Color(hex: 0xFBF1C7),
        contentBackground: Color(hex: 0xFBF1C7),
        sidebarBackground: Color(hex: 0xF2E5BC),
        textPrimary: Color(hex: 0x3C3836),
        textSecondary: Color(hex: 0x7C6F64),
        codeBackground: Color(hex: 0xEBDBB2),
        codeBorder: Color(hex: 0xD5C4A1),
        codeText: Color(hex: 0x3C3836)
    )

    static let monokai = Theme(
        id: "monokai", name: "Monokai",
        colorScheme: .dark,
        accent: Color(hex: 0xA6E22E),
        windowBackground: Color(hex: 0x272822),
        contentBackground: Color(hex: 0x272822),
        sidebarBackground: Color(hex: 0x1E1F1C),
        textPrimary: Color(hex: 0xF8F8F2),
        textSecondary: Color(hex: 0x75715E),
        codeBackground: Color(hex: 0x3E3D32),
        codeBorder: Color(hex: 0x49483E),
        codeText: Color(hex: 0xF8F8F2),
        quoteBar: Color(hex: 0xF92672)
    )

    static let oneDark = Theme(
        id: "one-dark", name: "One Dark",
        colorScheme: .dark,
        accent: Color(hex: 0x61AFEF),
        windowBackground: Color(hex: 0x282C34),
        contentBackground: Color(hex: 0x282C34),
        sidebarBackground: Color(hex: 0x21252B),
        textPrimary: Color(hex: 0xABB2BF),
        textSecondary: Color(hex: 0x5C6370),
        codeBackground: Color(hex: 0x2C313C),
        codeBorder: Color(hex: 0x3E4451),
        codeText: Color(hex: 0xABB2BF)
    )

    static let tokyoNight = Theme(
        id: "tokyo-night", name: "Tokyo Night",
        colorScheme: .dark,
        accent: Color(hex: 0x7AA2F7),
        windowBackground: Color(hex: 0x1A1B26),
        contentBackground: Color(hex: 0x1A1B26),
        sidebarBackground: Color(hex: 0x16161E),
        textPrimary: Color(hex: 0xC0CAF5),
        textSecondary: Color(hex: 0x565F89),
        codeBackground: Color(hex: 0x24283B),
        codeBorder: Color(hex: 0x3B4261),
        codeText: Color(hex: 0xC0CAF5),
        quoteBar: Color(hex: 0xBB9AF7)
    )

    static let catppuccinLatte = Theme(
        id: "catppuccin-latte", name: "Catppuccin Latte",
        colorScheme: .light,
        accent: Color(hex: 0x8839EF),
        windowBackground: Color(hex: 0xEFF1F5),
        contentBackground: Color(hex: 0xEFF1F5),
        sidebarBackground: Color(hex: 0xE6E9EF),
        textPrimary: Color(hex: 0x4C4F69),
        textSecondary: Color(hex: 0x8C8FA1),
        codeBackground: Color(hex: 0xCCD0DA),
        codeBorder: Color(hex: 0xBCC0CC),
        codeText: Color(hex: 0x4C4F69)
    )

    static let catppuccinMocha = Theme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha",
        colorScheme: .dark,
        accent: Color(hex: 0xCBA6F7),
        windowBackground: Color(hex: 0x1E1E2E),
        contentBackground: Color(hex: 0x1E1E2E),
        sidebarBackground: Color(hex: 0x181825),
        textPrimary: Color(hex: 0xCDD6F4),
        textSecondary: Color(hex: 0x7F849C),
        codeBackground: Color(hex: 0x313244),
        codeBorder: Color(hex: 0x45475A),
        codeText: Color(hex: 0xCDD6F4)
    )

    static let rosePine = Theme(
        id: "rose-pine", name: "Ros\u{00E9} Pine",
        colorScheme: .dark,
        accent: Color(hex: 0xEBBCBA),
        windowBackground: Color(hex: 0x191724),
        contentBackground: Color(hex: 0x191724),
        sidebarBackground: Color(hex: 0x1F1D2E),
        textPrimary: Color(hex: 0xE0DEF4),
        textSecondary: Color(hex: 0x908CAA),
        codeBackground: Color(hex: 0x26233A),
        codeBorder: Color(hex: 0x403D52),
        codeText: Color(hex: 0xE0DEF4),
        quoteBar: Color(hex: 0xC4A7E7)
    )

    // Character themes

    static let sepia = Theme(
        id: "sepia", name: "Sepia",
        colorScheme: .light,
        accent: Color(hex: 0x8B5E3C),
        windowBackground: Color(hex: 0xF4ECD8),
        contentBackground: Color(hex: 0xF4ECD8),
        sidebarBackground: Color(hex: 0xEBE1C8),
        textPrimary: Color(hex: 0x5B4636),
        textSecondary: Color(hex: 0x8A7460),
        codeBackground: Color(hex: 0xEAE0C3),
        codeBorder: Color(hex: 0xD8CBAA),
        codeText: Color(hex: 0x5B4636)
    )

    static let terminal = Theme(
        id: "terminal", name: "Terminal",
        colorScheme: .dark,
        accent: Color(hex: 0x33FF66),
        windowBackground: Color(hex: 0x0A0E0A),
        contentBackground: Color(hex: 0x0A0E0A),
        sidebarBackground: Color(hex: 0x0D130D),
        textPrimary: Color(hex: 0x33FF66),
        textSecondary: Color(hex: 0x22AA44),
        codeBackground: Color(hex: 0x101A10),
        codeBorder: Color(hex: 0x1F3A24),
        codeText: Color(hex: 0x33FF66),
        headingColor: Color(hex: 0x99FFBB)
    )

    static let highContrast = Theme(
        id: "high-contrast", name: "High Contrast",
        colorScheme: .dark,
        accent: Color(hex: 0xFFD60A),
        windowBackground: Color(hex: 0x000000),
        contentBackground: Color(hex: 0x000000),
        sidebarBackground: Color(hex: 0x0A0A0A),
        textPrimary: Color(hex: 0xFFFFFF),
        textSecondary: Color(hex: 0xCCCCCC),
        codeBackground: Color(hex: 0x1A1A1A),
        codeBorder: Color(hex: 0x777777),
        codeText: Color(hex: 0xFFFFFF)
    )

    /// Every built-in theme, in picker order.
    static let all: [Theme] = [
        .system, .light, .dark, .midnight,
        .solarizedLight, .solarizedDark,
        .dracula, .nord,
        .gruvboxDark, .gruvboxLight,
        .monokai, .oneDark, .tokyoNight,
        .catppuccinLatte, .catppuccinMocha,
        .rosePine, .sepia, .terminal, .highContrast
    ]
}

// MARK: - Theme manager

@MainActor
final class ThemeManager: ObservableObject {
    private static let themeKey = "themeID"

    @Published var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Self.themeKey) }
    }

    init() {
        themeID = UserDefaults.standard.string(forKey: Self.themeKey) ?? Theme.system.id
    }

    var current: Theme {
        Theme.all.first { $0.id == themeID } ?? .system
    }
}

// MARK: - View helpers

extension View {
    /// Paints a themed background, or leaves the native look when nil.
    @ViewBuilder
    func themedBackground(_ color: Color?) -> some View {
        if let color {
            background(color)
        } else {
            self
        }
    }

    /// Replaces a scrollable view's native background (List, TextEditor,
    /// ScrollView) with a themed color; keeps the native material when nil.
    @ViewBuilder
    func themedScrollBackground(_ color: Color?) -> some View {
        if let color {
            scrollContentBackground(.hidden).background(color)
        } else {
            self
        }
    }

    /// Tints the window titlebar/toolbar strip; keeps the native material
    /// when the theme doesn't define a color.
    @ViewBuilder
    func themedToolbarBackground(_ color: Color?) -> some View {
        if let color {
            toolbarBackground(color, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            self
        }
    }
}
