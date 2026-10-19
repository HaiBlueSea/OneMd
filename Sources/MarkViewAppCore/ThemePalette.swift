import AppKit
import SwiftUI
import MarkViewCore

public struct ThemePalette {
    public let isDark: Bool
    public let canvas: Color
    public let foreground: Color
    public let muted: Color
    public let subtle: Color
    public let border: Color
    public let accent: Color
    public let canvasNS: NSColor
    public let foregroundNS: NSColor

    public static func warp(isDark: Bool) -> ThemePalette {
        resolved(tokens: ThemeCSS.Tokens.resolved(isDark: isDark))
    }

    public static func resolved(tokens: ThemeCSS.Tokens) -> ThemePalette {
        let isDark = tokens.isDark
        return ThemePalette(
            isDark: isDark,
            canvas: Color(warpHex: tokens.canvas),
            foreground: Color(warpHex: tokens.foreground),
            muted: Color(warpHex: tokens.muted),
            subtle: Color(warpHex: tokens.subtle),
            border: Color(warpHex: tokens.border),
            accent: Color(warpHex: tokens.accent),
            canvasNS: NSColor(warpHex: tokens.canvas) ?? (isDark ? .black : .white),
            foregroundNS: NSColor(warpHex: tokens.foreground) ?? (isDark ? .white : .black)
        )
    }
}

public extension AppTheme {
    var preferredColorScheme: ColorScheme? {
        if self == .system { return nil }
        return tokens(systemIsDark: true).isDark ? .dark : .light
    }

    func tokens(systemIsDark: Bool) -> ThemeCSS.Tokens {
        switch self {
        case .dark: return .warpDark
        case .light: return .warpLight
        case .system: return .resolved(isDark: systemIsDark)
        case .dracula: return .dracula
        case .nord: return .nord
        case .oneDark: return .oneDark
        case .tokyoNight: return .tokyoNight
        case .catppuccinMocha: return .catppuccinMocha
        case .solarizedLight: return .solarizedLight
        }
    }
}

public extension AppSettings {
    var resolvedIsDark: Bool { themeTokens.isDark }

    var themeTokens: ThemeCSS.Tokens {
        theme.tokens(systemIsDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    var palette: ThemePalette { .resolved(tokens: themeTokens) }

    func adjustPreviewFont(delta: Double) {
        previewFontSize = min(32, max(10, previewFontSize + delta))
    }

    func resetPreviewFont() {
        previewFontSize = 16
    }
}

public enum FileReveal {
    public static func showInFinder(path: String?) {
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.open(directory)
        }
    }
}

public extension Color {
    init(warpHex: String) {
        let hex = warpHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

public extension NSColor {
    convenience init?(warpHex: String) {
        let hex = warpHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
