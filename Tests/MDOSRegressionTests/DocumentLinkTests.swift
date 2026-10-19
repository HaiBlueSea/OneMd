import AppKit
import WebKit
import MarkViewCore
import MarkViewAppCore

@MainActor
private final class LinkRecordingCoordinator: WebPreviewView.Coordinator {
    var navigations: [(URL, WKNavigationType, WKNavigationActionPolicy)] = []

    override func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let policy = await super.webView(webView, decidePolicyFor: action)
        if let url = action.request.url { navigations.append((url, action.navigationType, policy)) }
        return policy
    }
}

@MainActor
func runDocumentLinkTests(root: URL, check: (Bool, String) -> Void) {
    let directory = root.appendingPathComponent("local-links/文档 &copy; notes", isDirectory: true)
    let child = directory.appendingPathComponent("子目录", isDirectory: true)
    try! FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("Start &copy; 文档.md")
    let target = child.appendingPathComponent("中文 文件.md")
    let sibling = directory.deletingLastPathComponent().appendingPathComponent("兄弟.md")
    let pdf = child.appendingPathComponent("参考 文档.pdf")
    let executable = child.appendingPathComponent("run.command")
    let script = child.appendingPathComponent("test.scpt")
    let unreadable = child.appendingPathComponent("不可读.md")
    let alias = child.appendingPathComponent("Alias.md")
    let app = child.appendingPathComponent("Test.app", isDirectory: true)
    try! "# Target".write(to: target, atomically: true, encoding: .utf8)
    try! "# Sibling".write(to: sibling, atomically: true, encoding: .utf8)
    try! "%PDF-1.4\n%%EOF".write(to: pdf, atomically: true, encoding: .utf8)
    try! "#!/bin/sh\nexit 0".write(to: executable, atomically: true, encoding: .utf8)
    try! "display dialog \"test\"".write(to: script, atomically: true, encoding: .utf8)
    try! "# Private".write(to: unreadable, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: alias)
    try! FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    func attr(_ text: String) -> String { text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;") }
    let links = """
    <a id="relative" href="子目录/中文%20文件.md">Relative</a>
    <a id="absolute" href="\(attr(target.absoluteString))">Absolute</a>
    <a id="path" href="\(attr(target.path))">Absolute path</a>
    <a id="sibling" href="../兄弟.md">Sibling</a>
    <a id="alias" href="子目录/Alias.md">Alias</a>
    <a id="pdf" href="子目录/参考%20文档.pdf">PDF</a>
    <a id="blank" href="子目录/参考%20文档.pdf" target="_blank">New window</a>
    <a id="missing" href="missing.md">Missing</a>
    <a id="directory" href="子目录/">Directory</a>
    <a id="app" href="子目录/Test.app">App</a>
    <a id="executable" href="子目录/run.command">Executable</a>
    <a id="script" href="子目录/test.scpt">Script</a>
    <a id="remote-file" href="file://remote.invalid/volume/test.md">Remote file host</a>
    <a id="https" href="https://example.com/docs">Web</a>
    <a id="dangerous" href="javascript:alert(1)">Blocked</a>
    <a id="anchor" href="#deep-section">Anchor</a>
    <a id="unreadable" href="子目录/不可读.md">Unreadable</a>
    """
    let markdown = "# Links\n\n## Start\n\n" + links + String(repeating: "\n\nA paragraph for scrolling.", count: 80) + "\n\n## Deep Section\n\nEnd.\n"
    try! markdown.write(to: source, atomically: true, encoding: .utf8)

    let manager = TabManager()
    manager.beginRestore()
    manager.openFile(source)
    check(wait { manager.selectedTab?.viewModel.isLoaded == true }, "link source document loads")
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let coordinator = LinkRecordingCoordinator()
    WebPreviewView.Coordinator.installLocalLinkHandler(in: config.userContentController, coordinator: coordinator)
    let web = DocumentWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600), configuration: config)
    coordinator.webView = web
    coordinator.fileIdentifier = source.path
    coordinator.baseDirectoryURL = directory
    var openedMarkdown: [URL] = []
    var openedExternal: [URL] = []
    var errors: [String] = []
    var externalSucceeds = true
    coordinator.onOpenMarkdown = { url in openedMarkdown.append(url); manager.openFile(url) }
    coordinator.onLinkError = { errors.append($0) }
    coordinator.openExternalURL = { url in openedExternal.append(url); return externalSucceeds }
    web.navigationDelegate = coordinator
    config.userContentController.add(coordinator, name: TemplateConstants.renderCompleteHandler)
    config.userContentController.add(coordinator, name: TemplateConstants.scrollSyncHandler)
    let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
    window.orderBack(nil)
    window.makeKey()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        coordinator.teardown(web)
        window.contentView = nil
        window.close()
        for tab in manager.tabs { tab.viewModel.unloadFile() }
    }
    func evaluate(_ js: String) -> Any? {
        var done = false
        var value: Any?
        web.evaluateJavaScript(js) { result, _ in value = result; done = true }
        _ = wait { done }
        return value
    }
    func click(_ id: String) {
        _ = evaluate("document.getElementById('\(id)').scrollIntoView({block:'center'})")
        spin(0.1)
        guard let point = evaluate("(function(){const r=document.getElementById('\(id)').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()") as? [String: Double],
              let x = point["x"], let y = point["y"] else { return }
        let local = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
        let location = web.convert(local, to: nil)
        let receiver = web.hitTest(local) ?? web
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            if type == .leftMouseDown { receiver.mouseDown(with: event) }
            else { receiver.mouseUp(with: event) }
            spin(0.04)
        }
    }
    coordinator.updateContent(HTMLPipeline.assembleFullDocument(from: markdown), in: web)
    check(wait { evaluate("!!document.getElementById('deep-section')") as? Bool == true }, "link preview and page anchors render")
    let previewURL = web.url
    let resolvedBase = evaluate("document.baseURI") as? String
    check(resolvedBase == source.absoluteString, "link base uses original path including Chinese, spaces and HTML entities")
    _ = evaluate("window.linkClicks=[];document.addEventListener('click',e=>window.linkClicks.push({trusted:e.isTrusted,id:e.target.id}),true)")
    click("relative")
    let relativeOpened = wait(3) { openedMarkdown.count == 1 }
    check(relativeOpened && openedMarkdown.first == target, "relative Markdown link opens the intended local file")
    if !relativeOpened {
        print("LINK_DIAGNOSTIC \(coordinator.navigations.map { ($0.0.absoluteString, $0.1.rawValue, $0.2.rawValue) }) errors=\(errors) clicks=\(evaluate("JSON.stringify(window.linkClicks)") ?? "nil")")
        return
    }
    check(manager.tabs.count == 2 && manager.selectedTab?.url == target, "linked Markdown enters the existing sidebar session")
    let draft = manager.selectedTab?.viewModel
    _ = wait { draft?.isLoaded == true }
    draft?.contentDidChange("unsaved linked document")
    click("absolute")
    check(wait { openedMarkdown.count == 2 } && manager.tabs.count == 2 && draft?.editorContent == "unsaved linked document", "absolute file link reuses the tab and preserves its draft")
    click("path")
    check(wait { openedMarkdown.count == 3 } && openedMarkdown.last == target, "absolute path link opens with decoded filename")
    click("alias")
    check(wait { openedMarkdown.count == 4 } && manager.tabs.count == 2, "symlink Markdown link does not duplicate the file")
    click("sibling")
    check(wait { openedMarkdown.count == 5 } && openedMarkdown.last == sibling, "parent-directory links resolve against the source directory")
    click("pdf")
    check(wait { openedExternal.count == 1 } && openedExternal.last == pdf && manager.tabs.count == 3, "PDF is handed to the system opener without adding a Markdown tab")
    click("blank")
    check(wait { openedExternal.count == 2 } && openedExternal.last == pdf, "new-window local link uses the same document routing")
    externalSucceeds = false
    click("pdf")
    check(wait { errors.count == 1 }, "system opener failure is reported")
    externalSucceeds = true
    for id in ["missing", "directory", "app", "executable", "script", "remote-file"] {
        let before = errors.count
        click(id)
        check(wait { errors.count == before + 1 }, "invalid or non-document target is reported: \(id)")
    }
    check(openedMarkdown.count == 5 && openedExternal.count == 3, "invalid targets never reach app or system openers")
    click("https")
    check(wait { openedExternal.count == 4 } && openedExternal.last?.scheme == "https", "ordinary web link still uses the system opener")
    click("dangerous")
    spin(0.1)
    check(openedMarkdown.count == 5 && openedExternal.count == 4, "dangerous scheme cannot launch an external handler")
    click("anchor")
    check(wait { (evaluate("window.scrollY") as? Double ?? 0) > 100 }, "same-document anchor scrolls the current preview")
    check(web.url == previewURL && openedMarkdown.count == 5, "local links do not replace WebKit with a raw document")
    check(evaluate("typeof window.webkit.messageHandlers.openLocalDocument") as? String == "undefined", "page scripts cannot access the isolated local-file handler")
    _ = evaluate("document.getElementById('relative').click()")
    spin(0.2)
    check(openedMarkdown.count == 5 && openedExternal.count == 4, "synthetic clicks cannot launch local documents")
    _ = evaluate("window.location.href = document.getElementById('absolute').href")
    spin(0.2)
    check(openedMarkdown.count == 5 && openedExternal.count == 4 && evaluate("!!document.getElementById('relative')") as? Bool == true, "scripted file navigation cannot open or replace a document")

    let changed = markdown + "\n\n<a id=\"updated\" href=\"子目录/中文%20文件.md\">Updated</a>\n"
    coordinator.updateContent(HTMLPipeline.assembleFullDocument(from: changed), in: web)
    check(wait { evaluate("!!document.getElementById('updated')") as? Bool == true }, "edited preview updates its links")
    click("updated")
    check(wait { openedMarkdown.count == 6 } && openedMarkdown.last == target, "local links still resolve after a live preview update")
    let errorCount = errors.count
    click("unreadable")
    check(wait { errors.count == errorCount + 1 } && openedMarkdown.count == 6, "unreadable document is reported without adding a tab")
    coordinator.teardown(web)
    check(coordinator.onOpenMarkdown == nil && coordinator.onLinkError == nil, "closing the preview releases link callbacks")
}
