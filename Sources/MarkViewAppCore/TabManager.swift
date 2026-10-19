import AppKit
import Combine
import Foundation
import MarkViewCore

@MainActor
public final class TabState: ObservableObject, Identifiable {
    public let id = UUID()

    @Published public var url: URL?

    public let viewModel: PreviewViewModel

    public var scrollLine: Int = 0
    public var showEditor: Bool = false

    public var displayName: String {
        guard let url else { return "OneMd" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public init(url: URL) {
        self.url = url
        self.viewModel = PreviewViewModel()
        self.viewModel.loadFile(at: url.path)
    }
}

@MainActor
public final class TabManager: ObservableObject {
    @Published public var tabs: [TabState] = [] {
        didSet { persistSession() }
    }
    @Published public var selectedTabID: UUID? {
        didSet { persistSession() }
    }

    public static let shared = TabManager()
    public var isRestoring = false

    public init() {}

    public var selectedTab: TabState? {
        tabs.first { $0.id == selectedTabID }
    }

    public func openFile(_ url: URL, allowMissing: Bool = false) {
        guard MarkdownFile.shouldAcceptOpen(url, allowMissing: allowMissing) else { return }
        let resolved = url.resolvingSymlinksInPath()
        if let existing = tabs.first(where: { $0.url?.resolvingSymlinksInPath() == resolved }) {
            selectedTabID = existing.id
            return
        }
        let tab = TabState(url: resolved)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    public func beginRestore() {
        isRestoring = true
    }

    public func endRestore() {
        isRestoring = false
    }

    public func persistSessionNow() {
        persistSession()
    }

    private func persistSession() {
        if isRestoring { return }
        let paths = tabs.compactMap { $0.url?.path }
        let hasURL = tabs.map { $0.url != nil }
        let rawSelectedIndex = selectedTabID.flatMap { id in tabs.firstIndex(where: { $0.id == id }) }
        let selectedIndex = TabSelection.filteredIndex(hasURL: hasURL, selectedRawIndex: rawSelectedIndex)
        TabSessionStore.save(openPaths: paths, selectedIndex: selectedIndex)
    }

    public func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].viewModel.unloadFile()
        tabs.remove(at: idx)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
        if tabs.isEmpty {
            UserDefaults.standard.set(true, forKey: "didExplicitlyCloseFile")
        }
    }
}
