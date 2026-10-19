import Combine
import WebKit
import MarkViewCore

@MainActor
public final class PreviewViewModel: ObservableObject {
    public typealias RenderOperation = @Sendable (String) -> String

    @Published public var renderedHTML: String = ""
    @Published public var isLoaded: Bool = false
    @Published public var editorContent: String = ""
    @Published public var isDirty: Bool = false
    @Published public var externalChangeConflict: Bool = false
    @Published public var lastError: Error?
    @Published public var saveConflict: Bool = false

    @Published public var currentFilePath: String?
    @Published public var fileName: String = "OneMd"

    public enum SaveIntent {
        case normal
        case overwrite
    }

    public enum SaveOutcome: Equatable {
        case success
        case notNeeded
        case conflict
        case failed
    }

    public var currentFileDirectoryURL: URL? {
        guard let path = currentFilePath else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    public weak var previewWebView: WKWebView?
    public var isWatchingFile: Bool { fileWatcher != nil }

    private var fileWatcher: FileWatcher?
    private var renderTask: Task<Void, Never>?
    private var template: String?
    private var originalContent: String = ""
    private let renderOperation: RenderOperation
    private var renderGeneration = 0
    private var isRenderRunning = false
    private var pendingRenderMarkdown: String?
    private var contentLoadGeneration = 0
    private var editGeneration = 0
    private var hasUTF8BOM = false
    private var usesCRLF = false

    public init(
        renderOperation: @escaping RenderOperation = { markdown in
            MarkdownRenderer.renderHTML(from: markdown)
        }
    ) {
        self.renderOperation = renderOperation
    }

    public func loadFile(at path: String) {
        currentFilePath = path
        fileName = URL(fileURLWithPath: path).lastPathComponent
        UserDefaults.standard.set(false, forKey: "didExplicitlyCloseFile")

        loadTemplate()
        loadContent(from: path)
        watchFile(at: path)
    }

    public func contentDidChange(_ newText: String) {
        editGeneration += 1
        editorContent = newText
        isDirty = newText != originalContent
        renderDebounced(newText)
    }

    public func reloadFromDisk() {
        guard let path = currentFilePath else { return }
        loadContent(from: path)
    }

    @discardableResult
    public func save(intent: SaveIntent = .normal) -> SaveOutcome {
        guard let path = currentFilePath else {
            lastError = CocoaError(.fileNoSuchFile)
            return .failed
        }
        if intent == .normal && editorContent == originalContent && !isDirty {
            return .notNeeded
        }
        guard FileManager.default.fileExists(atPath: path) else {
            lastError = CocoaError(.fileNoSuchFile)
            return .failed
        }
        do {
            let disk = try FileContentLoader.load(from: path)
            if intent == .normal && disk.text != originalContent {
                saveConflict = true
                externalChangeConflict = true
                return .conflict
            }
            let payload = LoadedFileText(
                text: editorContent,
                hasUTF8BOM: hasUTF8BOM,
                usesCRLF: usesCRLF
            )
            try FileContentLoader.write(payload, to: path)
            originalContent = editorContent
            isDirty = false
            saveConflict = false
            externalChangeConflict = false
            lastError = nil
            return .success
        } catch {
            lastError = error
            AppCoreLog.logger.logError(error, category: "file", message: "Manual save failed")
            return .failed
        }
    }

    public func unloadFile() {
        fileWatcher?.stop()
        fileWatcher = nil
        renderTask?.cancel()
        contentLoadGeneration += 1
        renderGeneration += 1
        pendingRenderMarkdown = nil
        currentFilePath = nil
        fileName = "OneMd"
        renderedHTML = ""
        editorContent = ""
        originalContent = ""
        isDirty = false
        isLoaded = false
        externalChangeConflict = false
        saveConflict = false
        previewWebView = nil
        template = nil
        lastError = nil
    }

    private func loadTemplate() {
        guard let url = ResourceBundle.url(forResource: "template", withExtension: "html", subdirectory: "Resources") else {
            AppCoreLog.logger.logWarning("Template resource not found in bundle — preview will use fallback template", category: "render")
            AppCoreLog.logger.logError(CocoaError(.fileNoSuchFile), category: "render", message: "Template resource missing from bundle")
            assertionFailure("Template resource not found — ResourceBundle may not be resolving correctly")
            return
        }
        do {
            template = try String(contentsOf: url, encoding: .utf8)
            assert(template?.contains(TemplateConstants.contentPlaceholder) == true,
                   "Template missing \(TemplateConstants.contentPlaceholder) placeholder")
            assert(template?.contains("id=\"\(TemplateConstants.contentElementID)\"") == true,
                   "Template missing element with id=\"\(TemplateConstants.contentElementID)\"")
        } catch {
            AppCoreLog.logger.logWarning("Failed to load template: \(error.localizedDescription)", category: "render")
            AppCoreLog.logger.logError(error, category: "render", message: "Template load failed")
        }
    }

    private func loadContent(from path: String) {
        contentLoadGeneration += 1
        let generation = contentLoadGeneration
        let editAtStart = editGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let loaded = try FileContentLoader.load(from: path)
                await self?.finishLoadContent(loaded, generation: generation, editAtStart: editAtStart)
            } catch {
                await self?.failLoadContent(error, path: path, generation: generation)
            }
        }
    }

    private func finishLoadContent(_ loaded: LoadedFileText, generation: Int, editAtStart: Int) {
        guard generation == contentLoadGeneration else { return }
        guard editGeneration == editAtStart else { return }
        hasUTF8BOM = loaded.hasUTF8BOM
        usesCRLF = loaded.usesCRLF
        editorContent = loaded.text
        originalContent = loaded.text
        isDirty = false
        externalChangeConflict = false
        saveConflict = false
        lastError = nil
        renderImmediate(loaded.text)
    }

    private func failLoadContent(_ error: Error, path: String, generation: Int) {
        guard generation == contentLoadGeneration else { return }
        AppCoreLog.logger.logWarning("Failed to load file at \(path): \(error.localizedDescription)", category: "file")
        AppCoreLog.logger.logError(error, category: "file", message: "File load failed: \(path)")
        lastError = error
    }

    private func renderImmediate(_ markdown: String) {
        scheduleRender(markdown)
    }

    private func renderDebounced(_ markdown: String) {
        scheduleRender(markdown, debounceNanoseconds: 150_000_000)
    }

    private func scheduleRender(_ markdown: String, debounceNanoseconds: UInt64? = nil) {
        renderGeneration += 1
        let generation = renderGeneration

        guard !isRenderRunning else {
            pendingRenderMarkdown = markdown
            return
        }

        renderTask?.cancel()
        isRenderRunning = true
        let operation = renderOperation
        renderTask = Task {
            var currentMarkdown = markdown
            var currentGeneration = generation
            if let debounceNanoseconds {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
                guard !Task.isCancelled else {
                    self.isRenderRunning = false
                    self.renderTask = nil
                    if let pending = self.pendingRenderMarkdown {
                        self.pendingRenderMarkdown = nil
                        self.scheduleRender(pending)
                    }
                    return
                }
                if let pending = self.pendingRenderMarkdown {
                    self.pendingRenderMarkdown = nil
                    currentMarkdown = pending
                    currentGeneration = self.renderGeneration
                }
            }
            while true {
                let markdownToRender = currentMarkdown
                let currentTemplate = self.template
                let html = await Task.detached(priority: .userInitiated) {
                    MarkdownRenderer.wrapInTemplate(operation(markdownToRender), template: currentTemplate)
                }.value
                if Task.isCancelled { break }
                if currentGeneration == self.renderGeneration {
                    self.renderedHTML = html
                    self.isLoaded = true
                }
                guard let pending = self.pendingRenderMarkdown else { break }
                self.pendingRenderMarkdown = nil
                currentMarkdown = pending
                currentGeneration = self.renderGeneration
            }
            self.isRenderRunning = false
            self.renderTask = nil
            if let pending = self.pendingRenderMarkdown {
                self.pendingRenderMarkdown = nil
                self.scheduleRender(pending)
            }
        }
    }

    private func watchFile(at path: String) {
        fileWatcher?.stop()
        fileWatcher = FileWatcher(path: path) { [weak self] in
            Task { @MainActor in
                self?.handleDiskEvent(at: path)
            }
        }
        fileWatcher?.start()
    }

    private func handleDiskEvent(at path: String) {
        guard currentFilePath == path, fileWatcher != nil else { return }
        do {
            let disk = try FileContentLoader.load(from: path)
            if disk.text == originalContent {
                return
            }
            if isDirty {
                externalChangeConflict = true
            } else {
                loadContent(from: path)
            }
        } catch {
            lastError = error
        }
    }

    deinit {
        MainActor.assumeIsolated {
            fileWatcher?.stop()
        }
    }
}
