import Foundation
import AppKit
import WebKit
import MarkViewCore
import MarkViewAppCore

// Focused app regressions. All fixtures stay inside this task directory.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var failures = 0
if CommandLine.arguments.contains("--sidebar-only") {
    MainActor.assumeIsolated { runSidebarResizeTests(check: check) }
    print("RESULT failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
}
if CommandLine.arguments.contains("--links-only") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        runDocumentLinkTests(root: root, check: check)
    }
    print("RESULT failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
}
@MainActor func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    fflush(nil)
    if !ok { failures += 1 }
}
func spin(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}
func wait(_ seconds: Double = 10, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() && Date() < end { spin(0.01) }
    return condition()
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
let file = root.appendingPathComponent("watched.md")
try "# First".write(to: file, atomically: true, encoding: .utf8)
let counter = Counter()
let watcher = FileWatcher(path: file.path) { counter.add() }
watcher.start()
try "# Pending".write(to: file, atomically: false, encoding: .utf8)
spin(0.04)
watcher.stop()
let stoppedAt = counter.value
spin(0.3)
check(counter.value == stoppedAt, "stop cancels a queued debounce")
watcher.start()
try FileManager.default.removeItem(at: file)
spin(0.2)
try "# Restored".write(to: file, atomically: true, encoding: .utf8)
spin(0.3)
let restoredAt = counter.value
try "# Restored change".write(to: file, atomically: false, encoding: .utf8)
check(wait(2) { counter.value > restoredAt }, "watch survives missing file and later recreation")
watcher.stop()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    runDocumentLinkTests(root: root, check: check)
    check(AppTheme.allCases.count == 9, "nine theme options")
    for theme in AppTheme.allCases {
        let tokens = theme.tokens(systemIsDark: true)
        let palette = ThemePalette.resolved(tokens: tokens)
        check(palette.isDark == tokens.isDark && ThemeCSS.app(tokens: tokens).contains(tokens.canvas), "palette \(theme.label)")
    }
    let vm = PreviewViewModel(renderOperation: { input in
        Thread.sleep(forTimeInterval: 0.12)
        return "<p>\(input)</p>"
    })
    vm.loadFile(at: file.path)
    check(wait { vm.isLoaded }, "initial document load")
    vm.contentDidChange("unsaved draft")
    vm.unloadFile()
    spin(0.4)
    check(vm.renderedHTML.isEmpty && vm.editorContent.isEmpty && !vm.isLoaded && !vm.isWatchingFile, "closed document stays empty after late render")
    vm.loadFile(at: file.path)
    check(wait { vm.isLoaded && vm.renderedHTML.contains("Restored change") }, "reopen after cancelled render")
    vm.unloadFile()

    let outside = root.appendingPathComponent("outside.png")
    let child = root.appendingPathComponent("document", isDirectory: true)
    try! FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try! Data([1,2,3]).write(to: outside)
    let traversal = HTMLPipeline.inlineLocalImages(in: "<img src=\"../outside.png\">", baseDirectory: child)
    check(!traversal.contains("data:image"), "local image cannot escape document directory")

    let valid = child.appendingPathComponent("valid.png")
    try! Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")!.write(to: valid)
    let embedded = HTMLPipeline.inlineLocalImages(in: "<img src=\"valid.png\">", baseDirectory: child)
    check(embedded.contains("data:image/png;base64,"), "document-local image still works")
    let link = child.appendingPathComponent("linked.png")
    try? FileManager.default.removeItem(at: link)
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    check(!HTMLPipeline.inlineLocalImages(in: "<img src=\"linked.png\">", baseDirectory: child).contains("data:image"), "symlink image cannot escape directory")
    let bomFile = root.appendingPathComponent("bom.md")
    try! Data([0xef,0xbb,0xbf] + Array("# BOM\r\nbody\r\n".utf8)).write(to: bomFile)
    let saving = PreviewViewModel()
    saving.loadFile(at: bomFile.path)
    check(wait { saving.isLoaded }, "BOM document loads")
    saving.contentDidChange(saving.editorContent + "changed\n")
    check(saving.save() == .success, "explicit save")
    let bytes = try! Data(contentsOf: bomFile)
    check(bytes.starts(with: [0xef,0xbb,0xbf]) && String(data: bytes, encoding: .utf8)!.contains("\r\n"), "save preserves BOM and CRLF")
    saving.contentDidChange("my unsaved changes")
    try! "# external".write(to: bomFile, atomically: true, encoding: .utf8)
    check(saving.save() == .conflict && saving.editorContent == "my unsaved changes", "external conflict protects draft")
    try! FileManager.default.removeItem(at: bomFile)
    saving.reloadFromDisk()
    _ = wait { saving.lastError != nil }
    check(saving.externalChangeConflict && saving.saveConflict && saving.editorContent == "my unsaved changes", "failed reload retains conflict and draft")
    saving.unloadFile()
    var workspace: PreviewWorkspace? = try! PreviewWorkspace(parentDirectory: root)
    let ownedDirectory = workspace!.directory
    _ = try! PreviewPageBuilder.assembleAndWrite(styledHTML: "<html><body>preview</body></html>", baseDirectory: nil, pipeline: HTMLPipeline(), temporaryDirectory: ownedDirectory)
    workspace = nil
    check(!FileManager.default.fileExists(atPath: ownedDirectory.path), "workspace releases generated HTML on destruction")

    // Mount a real offscreen WKWebView; never touch the user's app or preference domain.
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let view = DocumentWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: config)
    let coordinator = WebPreviewView.Coordinator()
    coordinator.theme = .dark
    coordinator.webView = view
    coordinator.fileIdentifier = file.path
    coordinator.baseDirectoryURL = root
    view.documentPath = file.path
    view.navigationDelegate = coordinator
    config.userContentController.add(coordinator, name: TemplateConstants.renderCompleteHandler)
    config.userContentController.add(coordinator, name: TemplateConstants.scrollSyncHandler)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    let menu = NSMenu()
    menu.addItem(withTitle: "Reload", action: nil, keyEquivalent: "")
    view.willOpenMenu(menu, with: event)
    check(menu.items.first?.title == Strings.showInFinder && menu.items.first?.target === view, "Finder action added to actual WebKit menu")
    let long = String(repeating: "long_path_without_spaces/", count: 40)
    let markdown = "# Document\n\n## Section A\n\n" + long + "\n\n## Section B\n\n```swift\n" + long + "\n```\n\n| A | B |\n|---|---|\n| " + long + " | 中文测试 |\n"
    let html = HTMLPipeline.assembleFullDocument(from: markdown + "\n![local](document/valid.png)\n\n```swift\nlet value = 42\n```\n")
    coordinator.updateContent(html, in: view)
    var ready = false
    var result: [String: Any] = [:]
    let loaded = wait(20) {
        if !ready {
            ready = true
            view.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('toc-sidebar')") { value, error in
                if value as? Bool == true { result["ready"] = true }
                ready = false
            }
        }
        return result["ready"] as? Bool == true
    }
    check(loaded, "WKWebView renders full document and TOC")
    if loaded {
        var highlighted = false
        view.evaluateJavaScript("document.querySelectorAll('code.language-swift .token.keyword').length > 0 && document.querySelectorAll('code.language-swift .token.number').length > 0") { value, _ in
            check(value as? Bool == true, "bundled Prism highlights Swift keywords and numbers")
            highlighted = true
        }
        check(wait { highlighted }, "syntax highlighting measurement completed")
        for width in [1440, 900, 600] {
            view.setFrameSize(NSSize(width: width, height: 900))
            spin(0.2)
            var measured = false
            view.evaluateJavaScript("JSON.stringify({viewport:document.documentElement.clientWidth,page:document.documentElement.scrollWidth,body:document.body.getBoundingClientRect().width,content:document.getElementById('content').getBoundingClientRect().width,overflow:Array.from(document.querySelectorAll('article,pre,table,.table-wrapper')).some(e=>e.scrollWidth>e.clientWidth+1),toc:getComputedStyle(document.getElementById('toc-sidebar')).display})") { value, _ in
                if let value = value as? String, let data = value.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let viewport = v["viewport"] as? Double ?? 0
                    check((v["page"] as? Double ?? .infinity) <= viewport + 1 && v["overflow"] as? Bool == false, "no horizontal overflow at \(width)px")
                    check((v["body"] as? Double ?? 0) >= viewport - 1, "full width at \(width)px")
                    check((v["toc"] as? String != "none") == (width > 880), "responsive TOC at \(width)px")
                    print("LAYOUT \(width) \(value)")
                } else { check(false, "layout JavaScript result") }
                measured = true
            }
            check(wait { measured }, "layout measurement completed")
        }
        for theme in AppTheme.allCases where theme != .system {
            coordinator.theme = theme
            coordinator.updateContent(html, in: view)
            spin(0.1) // Image inlining runs off the main thread before the DOM update.
            var checked = false
            view.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") { value, _ in
                let color = NSColor(warpHex: theme.tokens(systemIsDark: true).canvas)!.usingColorSpace(.sRGB)!
                let expected = "rgb(\(Int((color.redComponent * 255).rounded())), \(Int((color.greenComponent * 255).rounded())), \(Int((color.blueComponent * 255).rounded())))"
                check(value as? String == expected, "live preview theme \(theme.label): \(String(describing: value))")
                checked = true
            }
            check(wait { checked }, "live theme measurement")
            var imageChecked = false
            view.evaluateJavaScript("document.querySelector('article img').src.startsWith('data:image/png;base64,')") { value, _ in
                check(value as? Bool == true, "local image survives live theme \(theme.label)")
                imageChecked = true
            }
            check(wait { imageChecked }, "image measurement completed")
        }
        coordinator.theme = .dark
        coordinator.updateContent(html, in: view)
        // Save an artifact for visual inspection.
        view.setFrameSize(NSSize(width: 1440, height: 900))
        spin(0.2)
        var captured = false
        view.takeSnapshot(with: nil) { image, _ in
            if let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: root.appendingPathComponent("preview.png"))
            }
            captured = true
        }
        _ = wait { captured }
    }
    let loadedFile = view.url
    coordinator.teardown(view)
    check(loadedFile == nil || !FileManager.default.fileExists(atPath: loadedFile!.path), "teardown removes active preview workspace")
    window.contentView = nil
    window.close()
}

@MainActor func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : -1
}
func fdCount() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
final class LifetimeProbe {
    weak var viewModel: PreviewViewModel?
    weak var webView: WKWebView?
    weak var coordinator: WebPreviewView.Coordinator?
    weak var sync: ScrollSyncController?
    @MainActor var released: Bool { viewModel == nil && webView == nil && coordinator == nil && sync == nil }
}
@MainActor func closedPreviewCycle() -> LifetimeProbe {
    autoreleasepool {
        let probe = LifetimeProbe()
        let model = PreviewViewModel()
        model.loadFile(at: file.path)
        _ = wait { model.isLoaded }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let coordinator = WebPreviewView.Coordinator()
        WebPreviewView.Coordinator.installLocalLinkHandler(in: config.userContentController, coordinator: coordinator)
        let web = DocumentWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        coordinator.onOpenMarkdown = { _ in model.contentDidChange("linked document") }
        let sync = ScrollSyncController()
        coordinator.webView = web
        coordinator.syncController = sync
        sync.previewCoordinator = coordinator
        web.navigationDelegate = coordinator
        config.userContentController.add(coordinator, name: TemplateConstants.renderCompleteHandler)
        config.userContentController.add(coordinator, name: TemplateConstants.scrollSyncHandler)
        model.previewWebView = web
        coordinator.fileIdentifier = file.path
        coordinator.updateContent(model.renderedHTML, in: web)
        sync.previewDidScrollToLine(1)
        probe.viewModel = model
        probe.webView = web
        probe.coordinator = coordinator
        probe.sync = sync
        // Intentionally close while the detached page write is still in flight.
        coordinator.teardown(web)
        model.unloadFile()
        return probe
    }
}
if !CommandLine.arguments.contains("--quick") {
MainActor.assumeIsolated {
    let temporary = FileManager.default.temporaryDirectory
    func workspaces() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []).filter { $0.hasPrefix("mdos-preview-") })
    }
    let originalWorkspaces = workspaces()
    var probes: [LifetimeProbe] = []
    for _ in 0..<3 { probes.append(closedPreviewCycle()) }
    spin(2)
    let baselineFD = fdCount()
    var samples: [[String: Double]] = [["rssMB": rssMB(), "fds": Double(baselineFD)]]
    for round in 1...3 {
        for _ in 0..<10 { probes.append(closedPreviewCycle()) }
        spin(2)
        samples.append(["rssMB": rssMB(), "fds": Double(fdCount())])
        check(probes.allSatisfy { $0.released }, "round \(round): model, WebView, coordinator and display link release")
    }
    check(workspaces().subtracting(originalWorkspaces).isEmpty, "closing during page preparation leaves no temp workspaces")
    check(fdCount() <= baselineFD + 3, "file handles return to warm baseline")
    let last = samples.last!["rssMB"]!
    check(last - samples[1]["rssMB"]! < 20, "RSS does not grow continuously across repeated closures")
    print("RESOURCES \(samples)")
    let json = try! JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted])
    try! json.write(to: root.appendingPathComponent("resources.json"))
    // Idle observation with actual WebKit initialized.
    let beforeIdle = rssMB()
    spin(60)
    print("IDLE rssBeforeMB=\(beforeIdle) rssAfterMB=\(rssMB()) fds=\(fdCount())")
}
}
print("RESULT failures=\(failures)")
exit(failures == 0 ? 0 : 1)
