import SwiftUI

// MARK: - Setting Enums

public enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, system, dracula, nord, oneDark, tokyoNight, catppuccinMocha, solarizedLight
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .oneDark: return "One Dark"
        case .tokyoNight: return "Tokyo Night"
        case .catppuccinMocha: return "Catppuccin Mocha"
        case .solarizedLight: return "Solarized Light"
        }
    }
}

public enum PreviewWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide, full
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .narrow: return "Narrow (700px)"
        case .medium: return "Medium (860px)"
        case .wide: return "Wide (1200px)"
        case .full: return "Full Width"
        }
    }
    public var cssValue: String {
        switch self {
        case .narrow: return "700px"
        case .medium: return "860px"
        case .wide: return "1200px"
        case .full: return "100%"
        }
    }
}

public enum TabBehavior: String, CaseIterable, Identifiable {
    case twoSpaces, fourSpaces, tab
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .twoSpaces: return "2 Spaces"
        case .fourSpaces: return "4 Spaces"
        case .tab: return "Tab"
        }
    }
    public var insertionString: String {
        switch self {
        case .twoSpaces: return "  "
        case .fourSpaces: return "    "
        case .tab: return "\t"
        }
    }
}

// MARK: - Settings Model

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private init() {}

    @AppStorage("editorFontSize") public var editorFontSize: Double = 14
    @AppStorage("previewFontSize") public var previewFontSize: Double = 16
    @AppStorage("editorLineSpacing") public var editorLineSpacing: Double = 1.4
    @AppStorage("showLineNumbers") public var showLineNumbers: Bool = false
    @AppStorage("wordWrap") public var wordWrap: Bool = true

    @AppStorage("theme") public var themeRaw: String = AppTheme.dark.rawValue
    @AppStorage("previewWidth") public var previewWidthRaw: String = PreviewWidth.medium.rawValue
    @AppStorage("editorFontFamily") public var editorFontFamily: String = "SF Mono"
    @AppStorage("tabBehavior") public var tabBehaviorRaw: String = TabBehavior.fourSpaces.rawValue
    @AppStorage("spellCheck") public var spellCheck: Bool = true
    @AppStorage("defaultOpenDir") public var defaultOpenDir: String = ""
    @AppStorage("windowRestore") public var windowRestore: Bool = true
    @AppStorage("sidebarVisible") public var sidebarVisible: Bool = true
    @AppStorage("sidebarWidth") public var sidebarWidth: Double = 240
    @AppStorage("lineHighlight") public var lineHighlight: Bool = false
    @AppStorage("minimapEnabled") public var minimapEnabled: Bool = false

    public var theme: AppTheme {
        get { AppTheme(rawValue: themeRaw) ?? .system }
        set { themeRaw = newValue.rawValue }
    }

    public var previewWidth: PreviewWidth {
        get { PreviewWidth(rawValue: previewWidthRaw) ?? .medium }
        set { previewWidthRaw = newValue.rawValue }
    }

    public var tabBehavior: TabBehavior {
        get { TabBehavior(rawValue: tabBehaviorRaw) ?? .fourSpaces }
        set { tabBehaviorRaw = newValue.rawValue }
    }

    public var defaultOpenDirURL: URL? {
        get { defaultOpenDir.isEmpty ? nil : URL(fileURLWithPath: defaultOpenDir) }
        set { defaultOpenDir = newValue?.path ?? "" }
    }
}
