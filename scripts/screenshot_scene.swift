import AppKit
import SwiftUI
import WebKit
import MarkViewAppCore

// Hosts the shipping ContentView. WebKit renders in a separate process, so its
// own snapshot is composited at its measured native view bounds.
@main
struct ScreenshotScene {
    @MainActor static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @MainActor static func webViews(_ view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews($0) }
    }

    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard JSBundleCache.shared.failures.isEmpty else { fatalError("Bundled Prism resource missing") }
        let settings = AppSettings.shared
        settings.sidebarVisible = true
        settings.sidebarWidth = 220
        settings.previewFontSize = 16
        let manager = TabManager()
        manager.beginRestore() // Do not persist a demo session.
        for name in ["Welcome", "Notes", "Checklist"] {
            manager.openFile(root.appendingPathComponent("examples/\(name).md"))
        }
        manager.selectedTabID = manager.tabs.first?.id
        for _ in 0..<1000 {
            if manager.tabs.allSatisfy({ $0.viewModel.isLoaded && !$0.viewModel.renderedHTML.isEmpty }) { break }
            spin(0.02)
        }
        guard manager.tabs.allSatisfy({ $0.viewModel.isLoaded }),
              manager.tabs[0].viewModel.renderedHTML.contains("toc-sidebar") else { fatalError("Demo files or template failed to load") }

        for (name, theme, editor) in [("preview-dark", AppTheme.dark, false), ("editor-dark", .dark, true), ("preview-light", .light, false)] {
            settings.theme = theme
            manager.tabs[0].showEditor = editor
            let host = NSHostingController(rootView: ContentView(tabManager: manager, errorPresenter: ErrorPresenter()))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(NSSize(width: 1440, height: 1000))
            window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
            window.title = "OneMd — Welcome.md"
            window.isReleasedWhenClosed = false
            window.contentView?.layoutSubtreeIfNeeded()
            spin(3)
            let content = window.contentView!
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("No bitmap") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let base = NSImage(size: content.bounds.size)
            base.addRepresentation(bitmap)
            let result = NSImage(size: content.bounds.size)
            result.lockFocus()
            base.draw(in: content.bounds)
            // Never draw the status bar's real absolute path into public assets.
            let palette = theme.tokens(systemIsDark: true)
            NSColor(warpHex: palette.subtle)!.setFill()
            NSRect(x: 226, y: 0, width: content.bounds.width - 226, height: 23).fill()
            for web in webViews(content) {
                var inspected = false
                var hasHighlight = false
                web.evaluateJavaScript("document.querySelectorAll('code.language-swift .token.keyword').length > 0") { value, _ in
                    hasHighlight = value as? Bool == true
                    inspected = true
                }
                for _ in 0..<1000 {
                    if inspected { break }
                    spin(0.01)
                }
                guard hasHighlight else { fatalError("Swift syntax highlighting missing") }
                var finished = false
                var shot: NSImage?
                web.takeSnapshot(with: nil) { image, _ in shot = image; finished = true }
                for _ in 0..<1500 {
                    if finished { break }
                    spin(0.01)
                }
                guard let shot else { fatalError("WebKit snapshot failed") }
                let rect = web.convert(web.bounds, to: content)
                shot.draw(in: rect)
            }
            result.unlockFocus()
            guard let tiff = result.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
            let path = root.appendingPathComponent("docs/images/\(name).png")
            try data.write(to: path)
            print("Captured \(name): \(rep.pixelsWide)×\(rep.pixelsHigh)")
            window.contentView = nil
            window.close()
            spin(0.2)
        }
        for tab in manager.tabs { tab.viewModel.unloadFile() }
    }
}
