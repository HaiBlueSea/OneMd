import SwiftUI
import WebKit
import UniformTypeIdentifiers
import MarkViewCore
import MarkViewAppCore

struct WebPreviewView: NSViewRepresentable {
    let html: String
    var baseDirectoryURL: URL?
    /// Unique identifier for the current file. When this changes (new file opened),
    /// the coordinator forces a full page reload instead of the JS fast-path.
    var fileIdentifier: String?
    // These must be explicit properties (not read from AppSettings inside updateNSView)
    // so that SwiftUI detects changes and triggers updateNSView.
    var previewFontSize: Double = 16
    var theme: AppTheme = .dark
    /// Direct reference to the scroll sync controller (not a SwiftUI binding).
    var syncController: ScrollSyncController?
    var onWebViewCreated: ((WKWebView) -> Void)? = nil
    var onOpenMarkdown: ((URL) -> Void)? = nil
    var onLinkError: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Security: Do NOT enable allowFileAccessFromFileURLs — it allows JS to fetch
        // arbitrary file:// URLs, which combined with XSS could leak local files.
        // Local images are inlined; WebKit only reads the owned preview directory.

        // Register message handler for scroll sync: JS posts source line to Swift.
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: TemplateConstants.scrollSyncHandler)
        // Render completion: page JS posts once per load — drives listener install + restore (MV-002).
        contentController.add(context.coordinator, name: TemplateConstants.renderCompleteHandler)
        Coordinator.installLocalLinkHandler(in: contentController, coordinator: context.coordinator)

        let webView = DocumentWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(Strings.markdownPreview)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.syncController = syncController
        context.coordinator.onOpenMarkdown = onOpenMarkdown
        context.coordinator.onLinkError = onLinkError
        webView.documentPath = fileIdentifier

        // Register coordinator with the sync controller for direct calls
        syncController?.previewCoordinator = context.coordinator

        onWebViewCreated?(webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Sync WKWebView appearance with system so @media (prefers-color-scheme) works
        webView.appearance = theme.preferredColorScheme.map {
            NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)
        } ?? nil
        (webView as? DocumentWebView)?.documentPath = fileIdentifier
        context.coordinator.baseDirectoryURL = baseDirectoryURL
        context.coordinator.fileIdentifier = fileIdentifier
        context.coordinator.previewFontSize = previewFontSize
        context.coordinator.theme = theme
        context.coordinator.syncController = syncController
        context.coordinator.onOpenMarkdown = onOpenMarkdown
        context.coordinator.onLinkError = onLinkError
        syncController?.previewCoordinator = context.coordinator

        context.coordinator.updateContent(html, in: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown(webView)
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var baseDirectoryURL: URL?
        var fileIdentifier: String?
        var previewFontSize: Double = 16
        var theme: AppTheme = .system
        weak var syncController: ScrollSyncController?
        var onOpenMarkdown: ((URL) -> Void)?
        var onLinkError: ((String) -> Void)?
        var openExternalURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
        private var hasLoadedInitialPage = false
        private var lastHTML: String = ""
        private var lastCSS: String = ""
        private var lastBaseDirectory: URL?
        private var lastFileIdentifier: String?
        private var previewWorkspace: PreviewWorkspace?
        private var contentGeneration = 0
        /// When true, ignore the next scroll event from JS (it's from a programmatic scroll).
        var suppressNextScroll = false

        // The JS bundles are immutable app resources — loaded ONCE per process by
        // JSBundleCache (MarkViewAppCore) and shared across all Coordinators
        // (item-713 hang triage / #55; Sentry hang report #48 sampled the main
        // thread inside a per-Coordinator 2.9 MB mermaid.min.js read, multiplied
        // by MV-001 restore-all-tabs at launch). The cache's load-once contract
        // and main-thread budget are covered behaviorally in MarkViewTestRunner;
        // this wrapper only maps load failures to app-side logging.
        static let sharedJSBundles: JSBundleCache = {
            let cache = JSBundleCache.shared
            for failure in cache.failures {
                switch failure {
                case .resourceNotFound(let label):
                    AppLogger.render.warning("\(label) bundle resource not found")
                    AppLogger.breadcrumb("\(label) resource missing", category: "render", level: .warning)
                case .readFailed(let label, let message):
                    AppLogger.render.warning("Failed to load \(label) bundle: \(message)")
                    AppLogger.breadcrumb("\(label) load failed", category: "render", level: .warning)
                }
            }
            return cache
        }()

        private let prismJS = Coordinator.sharedJSBundles.prism

        // MARK: - HTML Pipeline

        /// The injection pipeline, built from the already-loaded JS strings.
        /// HTMLPipeline owns insertBeforeBodyClose and all inject* methods so they
        /// are testable from MarkViewTestRunner without an AppKit dependency.
        private lazy var pipeline: HTMLPipeline = {
            HTMLPipeline(prismJS: prismJS)
        }()

        static func installLocalLinkHandler(in controller: WKUserContentController, coordinator: Coordinator) {
            controller.add(coordinator, contentWorld: .defaultClient, name: TemplateConstants.localLinkHandler)
            let source = """
            document.addEventListener('click', function(event) {
                if (!event.isTrusted || event.button !== 0) return;
                const link = event.target.closest && event.target.closest('a[href]');
                if (!link) return;
                let url;
                try { url = new URL(link.getAttribute('href'), document.baseURI); } catch (_) { return; }
                if (url.protocol !== 'file:') return;
                event.preventDefault();
                event.stopImmediatePropagation();
                window.webkit.messageHandlers.\(TemplateConstants.localLinkHandler).postMessage(url.href);
            }, true);
            """
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }

        // MARK: - WKScriptMessageHandler

        /// Receives source line messages from the JS scroll listener, plus the
        /// once-per-load renderComplete signal.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == TemplateConstants.localLinkHandler {
                guard message.frameInfo.isMainFrame, let webView, message.webView === webView,
                      let source = message.frameInfo.request.url,
                      source.deletingLastPathComponent() == previewWorkspace?.directory,
                      let value = message.body as? String, let url = URL(string: value), url.isFileURL else { return }
                openLocalLink(url, in: webView)
                return
            }
            if message.name == TemplateConstants.renderCompleteHandler {
                handleRenderComplete()
                return
            }
            guard message.name == TemplateConstants.scrollSyncHandler else { return }

            if suppressNextScroll {
                suppressNextScroll = false
                return
            }

            // JS sends the source line of the topmost visible element with data-sourcepos
            if let line = message.body as? Int, line > 0 {
                syncController?.previewDidScrollToLine(line)
            }
        }

        // MARK: - WKNavigationDelegate

        /// Only the generated preview loads in WebKit. Clicked local documents
        /// are handed to the app or the system without expanding file read access.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if navigationAction.navigationType == .other {
                return url.isFileURL && url.deletingLastPathComponent() == previewWorkspace?.directory ? .allow : .cancel
            }
            guard navigationAction.navigationType == .linkActivated else { return .cancel }

            if url.isFileURL {
                // Native handoff comes only from trusted clicks in the isolated
                // content world. Script-triggered file navigations stay blocked.
                return .cancel
            }

            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "https" || scheme == "http" || scheme == "mailto" {
                if !openExternalURL(url) { onLinkError?("无法打开链接：\(url.absoluteString)") }
            }
            return .cancel
        }

        private func openLocalLink(_ url: URL, in webView: WKWebView) {
            guard url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
                onLinkError?("只支持本机文档链接。")
                return
            }
            if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: true)?.fragment,
               let path = fileIdentifier,
               URL(fileURLWithPath: url.path).standardizedFileURL == URL(fileURLWithPath: path).standardizedFileURL {
                scrollToFragment(fragment, in: webView)
            } else {
                openLocalDocument(url)
            }
        }

        private func openLocalDocument(_ url: URL) {
            let file = URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
                guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: file.path) else {
                    onLinkError?("无法读取本地文档：\(file.path)")
                    return
                }
                if MarkdownFile.hasMarkdownExtension(file) {
                    onOpenMarkdown?(file)
                } else {
                    let type = values.contentType
                    guard !FileManager.default.isExecutableFile(atPath: file.path),
                          type?.conforms(to: .executable) != true,
                          type?.conforms(to: .script) != true,
                          type?.conforms(to: .application) != true else {
                        onLinkError?("文档链接不能启动应用或可执行脚本。")
                        return
                    }
                    if !openExternalURL(file) { onLinkError?("系统无法打开文档：\(file.path)") }
                }
            } catch {
                onLinkError?("无法打开本地文档：\(file.path)\n\(error.localizedDescription)")
            }
        }

        private func scrollToFragment(_ fragment: String, in webView: WKWebView) {
            let js = """
            (function() {
                const id = \(Self.jsStringLiteral(fragment));
                const target = document.getElementById(id) || document.getElementsByName(id)[0];
                if (target) window.scrollTo(0, Math.max(0, target.getBoundingClientRect().top + window.scrollY - 16));
                else if (!id) window.scrollTo(0, 0);
            })();
            """
            webView.evaluateJavaScript(js)
        }

        func teardown(_ webView: WKWebView) {
            _ = loadLifecycle.begin()
            contentGeneration += 1
            previewWorkspace = nil
            lastHTML = ""
            syncController?.reset()
            (webView as? DocumentWebView)?.documentPath = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: TemplateConstants.scrollSyncHandler)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: TemplateConstants.renderCompleteHandler)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: TemplateConstants.localLinkHandler, contentWorld: .defaultClient)
            webView.loadHTMLString("", baseURL: nil)
            self.webView = nil
            onOpenMarkdown = nil
            onLinkError = nil
            syncController?.previewCoordinator = nil
        }

        // MARK: - Scroll Sync JS

        /// JavaScript scroll sync system. Builds a cached sorted array of {line, offsetTop}
        /// on content load/mutation, then binary-searches on scroll — O(log n) per frame,
        /// no DOM queries in the scroll path.
        private static let scrollListenerJS = """
        (function() {
            if (window._markviewScrollListenerInstalled) return;
            window._markviewScrollListenerInstalled = true;
            var _rafPending = false;
            var _lastLine = 0;

            // Cached sourcepos map: sorted array of {line, top}
            // Rebuilt on content change via _markviewRebuildCache()
            window._markviewSourceCache = [];

            window._markviewRebuildCache = function() {
                var elements = document.querySelectorAll('[data-sourcepos]');
                var cache = [];
                for (var i = 0; i < elements.length; i++) {
                    var sp = elements[i].getAttribute('data-sourcepos');
                    if (!sp) continue;
                    var line = parseInt(sp.split(':')[0], 10);
                    if (isNaN(line)) continue;
                    var rect = elements[i].getBoundingClientRect();
                    cache.push({ line: line, top: rect.top + window.scrollY });
                }
                // Already sorted by DOM order (top position)
                window._markviewSourceCache = cache;
            };

            function getTopVisibleSourceLine() {
                var cache = window._markviewSourceCache;
                if (!cache.length) return 0;
                var scrollY = window.scrollY;
                // Binary search for the last element with top <= scrollY
                var lo = 0, hi = cache.length - 1, best = 0;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    if (cache[mid].top <= scrollY + 2) {
                        best = mid;
                        lo = mid + 1;
                    } else {
                        hi = mid - 1;
                    }
                }
                return cache[best].line;
            }

            window.addEventListener('scroll', function() {
                if (window._markviewSuppressScroll) {
                    window._markviewSuppressScroll = false;
                    return;
                }
                if (_rafPending) return;
                _rafPending = true;
                requestAnimationFrame(function() {
                    _rafPending = false;
                    var line = getTopVisibleSourceLine();
                    if (line > 0 && line !== _lastLine) {
                        _lastLine = line;
                        try {
                            window.webkit.messageHandlers.scrollSync.postMessage(line);
                        } catch(e) {}
                    }
                });
            }, { passive: true });

            // Build initial cache
            window._markviewRebuildCache();
        })();
        """

        /// Scroll the preview to the element corresponding to the given source line.
        /// Uses the cached offset map for O(log n) binary search + direct window.scrollTo
        /// (no DOM query, no scrollIntoView reflow).
        func scrollToSourceLine(_ line: Int) {
            guard let webView = webView else { return }
            suppressNextScroll = true
            let js = """
            (function() {
                window._markviewSuppressScroll = true;
                var cache = window._markviewSourceCache || [];
                if (!cache.length) return;
                // Binary search for largest line <= target
                var lo = 0, hi = cache.length - 1, best = 0;
                while (lo <= hi) {
                    var mid = (lo + hi) >> 1;
                    if (cache[mid].line <= \(line)) {
                        best = mid;
                        lo = mid + 1;
                    } else {
                        hi = mid - 1;
                    }
                }
                window.scrollTo(0, cache[best].top);
            })();
            """
            webView.evaluateJavaScript(js)
        }

        // MARK: - Content Updates

        /// Tracks whether a file change is pending — ensures full page reload
        /// even if SwiftUI splits the update across multiple updateNSView calls
        /// (fileIdentifier may update before renderedHTML in separate @Published cycles).
        private var pendingFileReload = false

        /// True while an async full-page load (assemble → temp-file write → loadFileURL)
        /// is being prepared off-main. Content updates arriving in that window are routed
        /// back through the full-reload path: a JS fast-path swap issued against the
        /// outgoing page would be silently reverted the moment the in-flight loadFileURL
        /// lands with its older snapshot (item-713 / mar-028).
        private var fullReloadInFlight = false

        /// Monotonic token for full-page loads: only the NEWEST prepared page may reach
        /// loadFileURL. A stale completion (tab switch or live edit during preparation)
        /// deletes its temp file and exits without touching the web view, so rapid
        /// successive reloads always converge on the newest content.
        private var loadLifecycle = PreviewLoadLifecycle()
        private var loadGeneration: Int { loadLifecycle.generation }

        func updateContent(_ html: String, in webView: WKWebView) {
            let currentCSS = "\(Int(previewFontSize))|\(theme)|\(resolvedSystemIsDark)"
            let cssChanged = currentCSS != lastCSS
            lastCSS = currentCSS

            // Force full page reload when a different file is opened (even from the same
            // directory) so the entire document is replaced. The JS fast-path (innerHTML
            // swap) fails silently on loadFileURL-loaded pages after the temp file is deleted.
            let fileChanged = fileIdentifier != lastFileIdentifier
            if fileChanged {
                pendingFileReload = true
            }
            lastFileIdentifier = fileIdentifier

            let baseDirChanged = baseDirectoryURL != lastBaseDirectory
            lastBaseDirectory = baseDirectoryURL

            let contentChanged = html != lastHTML || cssChanged
            let needsFullReload = !hasLoadedInitialPage || baseDirChanged || pendingFileReload
                || (fullReloadInFlight && contentChanged)

            guard contentChanged || needsFullReload else { return }
            lastHTML = html
            contentGeneration += 1

            let styledHTML = injectSettingsCSS(into: html)

            if needsFullReload {
                pendingFileReload = false
                loadViaFileURL(styledHTML, in: webView)
                hasLoadedInitialPage = true
            } else {
                updateContentViaJS(styledHTML, in: webView)
            }
        }

        /// Kick off a full page load: assemble the document, write it to a temp file,
        /// and hand it to loadFileURL so WKWebView renders it as a real page.
        ///
        /// The assembly (string surgery over ~3.2 MB of injected JS bundles), image
        /// inlining, and the synchronous temp-file write previously all ran on the
        /// main thread here — the third item-713 hang class (mar-028). They now run
        /// in a detached task (userInitiated — the user is watching the page load)
        /// via PreviewPageBuilder (MarkViewCore);
        /// only the completion touches the web view, back on the main actor.
        private func loadViaFileURL(_ styledHTML: String, in webView: WKWebView) {
            let generation = loadLifecycle.begin()
            fullReloadInFlight = true
            let baseDir = baseDirectoryURL
            let pipeline = self.pipeline
            let workspace: PreviewWorkspace
            do {
                if let existing = previewWorkspace { workspace = existing }
                else {
                    workspace = try PreviewWorkspace()
                    previewWorkspace = workspace
                }
            } catch {
                AppLogger.render.error("Failed to create preview workspace: \(error.localizedDescription)")
                return
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                var tempFile: URL?
                do {
                    tempFile = try PreviewPageBuilder.assembleAndWrite(
                        styledHTML: styledHTML,
                        baseDirectory: baseDir,
                        pipeline: pipeline,
                        temporaryDirectory: workspace.directory
                    )
                } catch {
                    AppLogger.render.error("Failed to write temp preview file: \(error.localizedDescription)")
                    AppLogger.captureError(error, category: "render", message: "Temp file write failed")
                }
                await self?.finishFullPageLoad(tempFile, generation: generation)
                withExtendedLifetime(workspace) {}
            }
        }

        /// Main-actor completion of loadViaFileURL: hands the prepared temp file to
        /// WKWebView. Ordering guarantee: a stale generation (a newer full load started
        /// while this one was being prepared) never reaches the web view — it deletes
        /// its temp file and exits, so tab switches and rapid edits always end on the
        /// newest content, and renderComplete stays once-per-real-load (MV-002).
        private func finishFullPageLoad(_ tempFile: URL?, generation: Int) {
            guard generation == loadGeneration else {
                // Superseded while preparing — discard without touching the web view.
                if let tempFile { try? FileManager.default.removeItem(at: tempFile) }
                return
            }
            // Write failed (already logged off-main): keep fullReloadInFlight true so
            // the next content update retries the full-reload path instead of issuing
            // a JS swap against a page that never loaded.
            guard let tempFile else { return }
            fullReloadInFlight = false
            guard let webView else {
                try? FileManager.default.removeItem(at: tempFile)
                return
            }
            // Images are already inlined as data URIs, so WKWebView only needs access to the
            // temp directory. Never grant access to "/" or user home — least-privilege scope.
            guard loadLifecycle.markLoaded(generation) else {
                try? FileManager.default.removeItem(at: tempFile)
                return
            }
            webView.loadFileURL(tempFile, allowingReadAccessTo: tempFile.deletingLastPathComponent())
            // The page's renderComplete message drives scroll-listener install + restore
            // the moment all transforms finish (MV-002). The 2s timer only covers a page
            // whose JS died before posting. Both paths claim the loaded generation
            // exactly once; an older timer cannot finish a newer page.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.handleRenderComplete(generation: generation)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                // Teardown may already have removed this owned workspace.
                try? FileManager.default.removeItem(at: tempFile)
            }
        }

        /// Deterministic post-render hook (MV-002, replaces the 0.5s+0.2s asyncAfter
        /// timing hacks): installs the scroll listener and restores the persisted
        /// position exactly once per page load. The syncController persists via @State
        /// in ContentView, so lastPreviewLine survives the destroy/recreate cycle.
        private func handleRenderComplete(generation: Int? = nil) {
            guard let webView,
                  loadLifecycle.claimCompletion(generation ?? loadGeneration) else { return }
            webView.evaluateJavaScript(Self.scrollListenerJS)
            if let line = syncController?.lastPreviewLine, line > 0 {
                scrollToSourceLine(line)
            }
        }

        private func injectSettingsCSS(into html: String) -> String {
            var css = ""
            css += "body { max-width: none; width: 100%; margin-left: auto; margin-right: auto; font-size: \(Int(previewFontSize))px; }\n"

            css += ThemeCSS.app(tokens: theme.tokens(systemIsDark: resolvedSystemIsDark)) + "\n"

            if css.isEmpty { return html }

            let styleTag = "<style id=\"\(TemplateConstants.settingsStyleID)\">\(css)</style>"
            // The HTML lives in an owned temporary directory. Resolve links against
            // the actual Markdown file, including relative paths and #fragments.
            let baseTag = fileIdentifier.map {
                let href = URL(fileURLWithPath: $0).absoluteString.replacingOccurrences(of: "&", with: "&amp;")
                return "<base href=\"\(href)\">"
            } ?? ""
            return html.replacingOccurrences(of: "</head>", with: "\(baseTag)\n\(styleTag)\n</head>")
        }

        private func updateContentViaJS(_ html: String, in webView: WKWebView) {
            guard html.contains("<img"), let directory = baseDirectoryURL else {
                applyContentViaJS(html, in: webView)
                return
            }
            let generation = contentGeneration
            Task.detached(priority: .userInitiated) { [weak self] in
                let prepared = HTMLPipeline.inlineLocalImages(in: html, baseDirectory: directory)
                await self?.finishContentUpdate(prepared, generation: generation)
            }
        }

        private func finishContentUpdate(_ html: String, generation: Int) {
            guard generation == contentGeneration, let webView else { return }
            applyContentViaJS(html, in: webView)
        }

        private func applyContentViaJS(_ html: String, in webView: WKWebView) {
            let bodyContent: String
            if let startRange = html.range(of: "<article id=\"\(TemplateConstants.contentElementID)\"", options: .literal).flatMap({ html.range(of: ">", range: $0.upperBound..<html.endIndex) }),
               let endRange = html.range(of: "</article>") {
                bodyContent = String(html[startRange.upperBound..<endRange.lowerBound])
            } else if let startRange = html.range(of: "<body>"),
                      let endRange = html.range(of: "</body>") {
                bodyContent = String(html[startRange.upperBound..<endRange.lowerBound])
            } else {
                bodyContent = html
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: bodyContent, options: .fragmentsAllowed),
                  let escapedContent = String(data: jsonData, encoding: .utf8) else { return }

            var css = "body { max-width: none; width: 100%; margin-left: auto; margin-right: auto; font-size: \(Int(previewFontSize))px; }"
            css += " " + ThemeCSS.app(tokens: theme.tokens(systemIsDark: resolvedSystemIsDark))

            let js = """
            (function() {
                var scrollPos = window.scrollY;
                var contentEl = document.getElementById('\(TemplateConstants.contentElementID)');
                if (contentEl) {
                    contentEl.innerHTML = \(escapedContent);
                }
                var existing = document.getElementById('\(TemplateConstants.settingsStyleID)');
                if (existing) { existing.textContent = \(Self.jsStringLiteral(css)); }
                if (typeof Prism !== 'undefined') {
                    Prism.highlightAll();
                }
                requestAnimationFrame(function() {
                    window.scrollTo(0, scrollPos);
                    if (typeof window._markviewRebuildCache === 'function') {
                        window._markviewRebuildCache();
                    }
                    // Re-init TOC: innerHTML swap detaches old heading refs captured in
                    // click-handler closures; offsetTop on detached elements returns 0,
                    // causing every link to scroll to the top. Re-init wires fresh refs.
                    if (typeof window._markviewRebuildTOC === 'function') {
                        window._markviewRebuildTOC();
                    }
                });
            })();
            """
            webView.evaluateJavaScript(js)
            webView.evaluateJavaScript(Self.scrollListenerJS)
        }

        private var resolvedSystemIsDark: Bool {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        private static func jsStringLiteral(_ s: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
                  let str = String(data: data, encoding: .utf8) else { return "\"\"" }
            return str
        }

    }
}

/// WebKit constructs a contextual menu internally; customize the menu it actually opens.
final class DocumentWebView: WKWebView {
    var documentPath: String?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard menu.item(withTitle: Strings.showInFinder) == nil else { return }
        let item = NSMenuItem(title: Strings.showInFinder, action: #selector(revealDocument), keyEquivalent: "")
        item.target = self
        item.isEnabled = documentPath != nil
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
    }

    @objc private func revealDocument() {
        FileReveal.showInFinder(path: documentPath)
    }
}
