import AppKit
import SwiftUI
import MarkViewCore
import MarkViewAppCore

struct ContentView: View {
    @ObservedObject var tabManager: TabManager
    var errorPresenter: ErrorPresenter
    @ObservedObject private var settings = AppSettings.shared
    @State private var sidebarWidth: CGFloat?

    var body: some View {
        let palette = settings.palette
        let width = min(420, max(160, sidebarWidth ?? CGFloat(settings.sidebarWidth)))
        HStack(spacing: 0) {
            if settings.sidebarVisible {
                OpenFilesSidebar(tabManager: tabManager) { id in
                    requestClose(id)
                }
                .frame(width: width)
                .frame(maxHeight: .infinity)

                SidebarResizeHandle(
                    width: Binding(
                        get: { width },
                        set: { newWidth in
                            sidebarWidth = newWidth
                        }
                    ),
                    palette: palette,
                    onResizeEnded: { settings.sidebarWidth = Double($0) }
                )
            }

            Group {
                if let tab = tabManager.selectedTab {
                    ActiveTabView(
                        tab: tab,
                        tabManager: tabManager,
                        errorPresenter: errorPresenter
                    )
                    .id(tab.id)
                    .contextMenu {
                        Button(Strings.showInFinder) {
                            FileReveal.showInFinder(path: tab.url?.path)
                        }
                        .disabled(tab.url == nil)
                    }
                } else {
                    HomeScreenView { url in
                        tabManager.openFile(url)
                    }
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.canvas)
        }
        .preferredColorScheme(settings.theme.preferredColorScheme)
        .background(palette.canvas)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    settings.sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(settings.sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
            }
            ToolbarItem {
                Picker(selection: $settings.themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .pickerStyle(.menu)
                .help(Strings.themeSection)
            }
        }
    }

    private func requestClose(_ id: UUID) {
        guard let target = tabManager.tabs.first(where: { $0.id == id }) else { return }
        if DocumentCloseGate.confirmClose(tab: target) == .proceed {
            tabManager.closeTab(id)
        }
    }
}

private struct ActiveTabView: View {
    let tab: TabState
    @ObservedObject var viewModel: PreviewViewModel
    @ObservedObject var tabManager: TabManager
    var errorPresenter: ErrorPresenter

    @ObservedObject private var settings = AppSettings.shared
    @State private var syncController: ScrollSyncController
    @State private var showEditor: Bool
    @State private var showExternalChangeAlert = false
    @State private var showSaveConflictAlert = false

    @MainActor
    init(tab: TabState, tabManager: TabManager, errorPresenter: ErrorPresenter) {
        self.tab = tab
        self.viewModel = tab.viewModel
        self.tabManager = tabManager
        self.errorPresenter = errorPresenter
        let controller = ScrollSyncController()
        controller.lastPreviewLine = tab.scrollLine
        controller.onLineChange = { [weak tab] line in tab?.scrollLine = line }
        _syncController = State(initialValue: controller)
        _showEditor = State(initialValue: tab.showEditor)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if viewModel.isLoaded {
                    if showEditor {
                        HSplitView {
                            EditorView(
                                text: $viewModel.editorContent,
                                onChange: { viewModel.contentDidChange($0) },
                                syncController: syncController
                            )
                            .frame(minWidth: 200, idealWidth: .infinity, maxWidth: .infinity)
                            .accessibilityElement(children: .contain)

                            WebPreviewView(
                                html: viewModel.renderedHTML,
                                baseDirectoryURL: viewModel.currentFileDirectoryURL,
                                fileIdentifier: viewModel.currentFilePath,
                                previewFontSize: settings.previewFontSize,
                                theme: settings.theme,
                                syncController: syncController,
                                onWebViewCreated: { viewModel.previewWebView = $0 },
                                onOpenMarkdown: openLinkedMarkdown,
                                onLinkError: { errorPresenter.show("无法打开链接", detail: $0) }
                            )
                            .id(tab.id)
                            .frame(minWidth: 200, idealWidth: .infinity, maxWidth: .infinity)
                            .accessibilityElement(children: .contain)
                        }
                    } else {
                        WebPreviewView(
                            html: viewModel.renderedHTML,
                            baseDirectoryURL: viewModel.currentFileDirectoryURL,
                            fileIdentifier: viewModel.currentFilePath,
                            previewFontSize: settings.previewFontSize,
                            theme: settings.theme,
                            syncController: syncController,
                            onWebViewCreated: { viewModel.previewWebView = $0 },
                            onOpenMarkdown: openLinkedMarkdown,
                            onLinkError: { errorPresenter.show("无法打开链接", detail: $0) }
                        )
                        .id(tab.id)
                    }
                } else if let error = viewModel.lastError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(error.localizedDescription)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button(Strings.openFileButton) { openFilePanel() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HomeScreenView { url in
                        tabManager.openFile(url)
                        registerFileInWindow(url.path)
                    }
                }

                if viewModel.isLoaded {
                    StatusBarView(
                        filePath: viewModel.currentFilePath,
                        isDirty: viewModel.isDirty
                    )
                }
            }
            .navigationTitle(viewModel.fileName)
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    if viewModel.isLoaded {
                        Button {
                            closeCurrentTab()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help(Strings.closeFile)

                        Button {
                            toggleEditor()
                        } label: {
                            Image(systemName: showEditor ? "doc.plaintext" : "rectangle.split.2x1")
                        }
                        .help(showEditor ? Strings.hideEditor : Strings.showEditor)
                        .accessibilityLabel(showEditor ? Strings.hideEditorPanel : Strings.showEditorPanel)
                        .keyboardShortcut("e", modifiers: .command)
                    }
                }
            }
            .alert(Strings.fileChanged, isPresented: $showExternalChangeAlert) {
                Button(Strings.reload) { viewModel.reloadFromDisk() }
                Button(Strings.keepMine, role: .cancel) { }
            } message: {
                Text(Strings.externalChangeMessage)
            }
            .alert(Strings.saveConflictTitle, isPresented: $showSaveConflictAlert) {
                Button(Strings.overwriteDisk) {
                    if viewModel.save(intent: .overwrite) == .failed {
                        errorPresenter.show("Save failed", detail: viewModel.lastError?.localizedDescription ?? "")
                    }
                }
                Button(Strings.reload) { viewModel.reloadFromDisk() }
                Button(Strings.cancel, role: .cancel) { }
            } message: {
                Text(Strings.saveConflictMessage)
            }
            .onReceive(viewModel.$externalChangeConflict) { conflict in
                if conflict { showExternalChangeAlert = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveDocument)) { _ in
                switch viewModel.save(intent: .normal) {
                case .success, .notNeeded:
                    break
                case .conflict:
                    showSaveConflictAlert = true
                case .failed:
                    errorPresenter.show("Save failed", detail: viewModel.lastError?.localizedDescription ?? "")
                    if let error = viewModel.lastError {
                        AppLogger.captureError(error, category: "file", message: "Manual save failed")
                    }
                }
            }
            .onReceive(viewModel.$lastError) { error in
                if let error = error, viewModel.isLoaded {
                    errorPresenter.show("File error", detail: error.localizedDescription)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeFile)) { _ in
                closeCurrentTab()
            }

            if let notification = errorPresenter.currentNotification {
                ErrorBanner(
                    notification: notification,
                    onDismiss: { errorPresenter.dismiss() }
                )
            }
        }
        .animation(.easeInOut(duration: 0.3), value: errorPresenter.currentNotification?.id)
    }

    private func closeCurrentTab() {
        requestClose(tab.id)
    }

    private func requestClose(_ id: UUID) {
        guard let target = tabManager.tabs.first(where: { $0.id == id }) else { return }
        if DocumentCloseGate.confirmClose(tab: target) == .proceed {
            tabManager.closeTab(id)
        }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "md")!,
            .init(filenameExtension: "markdown")!,
            .init(filenameExtension: "mdown")!,
            .init(filenameExtension: "mkd")!,
        ]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls where MarkdownFile.shouldAcceptOpen(url) {
                tabManager.openFile(url)
                registerFileInWindow(url.path)
            }
        }
    }

    private func openLinkedMarkdown(_ url: URL) {
        tabManager.openFile(url)
        registerFileInWindow(url.path)
    }

    private func registerFileInWindow(_ path: String) {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow })
                    ?? NSApplication.shared.windows.first(where: { $0.isVisible }) else { return }
            WindowFileTracker.shared.register(window: window, filePath: path)
        }
    }

    private func toggleEditor() {
        showEditor.toggle()
        tab.showEditor = showEditor
    }
}
