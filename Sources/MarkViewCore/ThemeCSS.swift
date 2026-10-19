import Foundation

/// Shared native and preview color palettes.
public enum ThemeCSS {
    public struct Tokens: Sendable {
        public let isDark: Bool
        public let canvas: String
        public let subtle: String
        public let inset: String
        public let foreground: String
        public let muted: String
        public let border: String
        public let accent: String
        public let codeInline: String

        public static let warpDark = Tokens(
            isDark: true,
            canvas: "#252833",
            subtle: "#30333d",
            inset: "#20222b",
            foreground: "#dcdfe4",
            muted: "#a0a4af",
            border: "#3d414d",
            accent: "#80a9d8",
            codeInline: "#3b3e49"
        )

        public static let warpLight = Tokens(
            isDark: false,
            canvas: "#ffffff",
            subtle: "#f4f4f4",
            inset: "#f6f6f6",
            foreground: "#111111",
            muted: "#616161",
            border: "#e0e0e0",
            accent: "#00c2ff",
            codeInline: "#eef6f8"
        )

        public static let dracula = Tokens(
            isDark: true,
            canvas: "#282a36",
            subtle: "#343746",
            inset: "#21222c",
            foreground: "#f8f8f2",
            muted: "#a5a8c0",
            border: "#44475a",
            accent: "#bd93f9",
            codeInline: "#44475a"
        )

        public static let nord = Tokens(
            isDark: true,
            canvas: "#2e3440",
            subtle: "#3b4252",
            inset: "#272d38",
            foreground: "#eceff4",
            muted: "#a6b1c2",
            border: "#4c566a",
            accent: "#88c0d0",
            codeInline: "#434c5e"
        )

        public static let oneDark = Tokens(
            isDark: true,
            canvas: "#282c34",
            subtle: "#303640",
            inset: "#21252b",
            foreground: "#abb2bf",
            muted: "#959cab",
            border: "#454c59",
            accent: "#61afef",
            codeInline: "#3b414d"
        )

        public static let tokyoNight = Tokens(
            isDark: true,
            canvas: "#1a1b26",
            subtle: "#24283b",
            inset: "#16161e",
            foreground: "#c0caf5",
            muted: "#929dcc",
            border: "#414868",
            accent: "#7aa2f7",
            codeInline: "#292e42"
        )

        public static let catppuccinMocha = Tokens(
            isDark: true,
            canvas: "#1e1e2e",
            subtle: "#313244",
            inset: "#181825",
            foreground: "#cdd6f4",
            muted: "#a6adc8",
            border: "#45475a",
            accent: "#cba6f7",
            codeInline: "#313244"
        )

        public static let solarizedLight = Tokens(
            isDark: false,
            canvas: "#fdf6e3",
            subtle: "#eee8d5",
            inset: "#f5efdc",
            foreground: "#586e75",
            muted: "#657b83",
            border: "#d5cdb6",
            accent: "#007ba3",
            codeInline: "#eee8d5"
        )

        public static func resolved(isDark: Bool) -> Tokens {
            isDark ? .warpDark : .warpLight
        }
    }

    public static func app(isDark: Bool) -> String {
        app(tokens: .resolved(isDark: isDark))
    }

    public static func app(tokens t: Tokens) -> String {
        let scheme = t.isDark ? "dark" : "light"
        return """
        :root { color-scheme: \(scheme); \
        --color-canvas-default: \(t.canvas); \
        --color-canvas-subtle: \(t.subtle); \
        --color-canvas-inset: \(t.inset); \
        --color-fg-default: \(t.foreground); \
        --color-fg-muted: \(t.muted); \
        --color-fg-subtle: \(t.muted); \
        --color-border-default: \(t.border); \
        --color-border-muted: \(t.border); \
        --color-accent-fg: \(t.accent); \
        --color-code-bg: \(t.inset); }
        body { color: \(t.foreground); background: \(t.canvas); }
        a { color: \(t.accent); }
        code:not([class*="language-"]) { background: \(t.codeInline); color: \(t.foreground); }
        pre { background: \(t.inset) !important; color: \(t.foreground); }
        th, td { border-color: \(t.border); color: \(t.foreground); }
        th { background-color: \(t.subtle); }
        tr { background-color: \(t.canvas); border-top-color: \(t.border); }
        tr:nth-child(2n) { background-color: \(t.subtle); }
        blockquote { border-left-color: \(t.border); color: \(t.muted); background: \(t.subtle); }
        hr { border-top-color: \(t.border); }
        h1, h2, h3, h4, h5 { color: \(t.foreground); }
        h1, h2 { border-bottom-color: \(t.border); }
        h6 { color: \(t.muted); }
        #toc-sidebar { background: \(t.subtle); border-left-color: \(t.border); }
        #toc-sidebar a { color: \(t.muted); }
        #toc-sidebar a:hover, #toc-sidebar a.active { color: \(t.accent); }
        #toc-sidebar .toc-title, #toc-sidebar .toc-h4 { color: \(t.muted); }
        .token.comment, .token.prolog, .token.doctype, .token.cdata { color: \(t.muted); }
        .token.punctuation, .token.operator, .token.entity, .token.url { color: \(t.foreground); }
        .token.property, .token.tag, .token.boolean, .token.number, .token.constant, .token.symbol { color: \(t.accent); }
        .token.selector, .token.attr-name, .token.string, .token.char, .token.builtin, .token.inserted { color: \(t.isDark ? "#a5d6ff" : "#0a3069"); }
        .token.atrule, .token.attr-value, .token.keyword { color: \(t.isDark ? "#ff7b72" : "#cf222e"); }
        .token.function, .token.class-name { color: \(t.isDark ? "#d2a8ff" : "#8250df"); }
        .token.regex, .token.important, .token.variable { color: \(t.isDark ? "#ffa657" : "#953800"); }
        """
    }
}
