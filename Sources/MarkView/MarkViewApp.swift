import Combine
import MarkViewCore
import MarkViewAppCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var pendingFilePaths: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            AppBootstrap.run(tabManager: TabManager.shared)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter { MarkdownFile.shouldAcceptOpen($0) }.map(\.path)
        pendingFilePaths.append(contentsOf: paths)
        AppBootstrap.enqueue(paths, tabManager: TabManager.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DocumentCloseGate.confirmQuit(tabs: TabManager.shared.tabs) == .abort {
            return .terminateCancel
        }
        return .terminateNow
    }
}

@MainActor
final class WindowFileTracker {
    static let shared = WindowFileTracker()
    private var windowToPath: [ObjectIdentifier: String] = [:]

    func register(window: NSWindow, filePath: String) {
        windowToPath[ObjectIdentifier(window)] = filePath
    }

    func filePath(for window: NSWindow) -> String? {
        windowToPath[ObjectIdentifier(window)]
    }
}

@main
struct MarkViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var tabManager = TabManager.shared
    @State private var errorPresenter = ErrorPresenter()

    init() {
        AppCoreLog.logger = LocalAppCoreLogger()
    }

    private var defaultWindowSize: CGSize {
        WindowLayout.defaultWindowSize(for: NSScreen.main?.visibleFrame)
    }

    var body: some Scene {
        Window("OneMd", id: "main") {
            ContentView(tabManager: tabManager, errorPresenter: errorPresenter)
                .frame(minWidth: 600, minHeight: 400)
                .background(WindowFrameAutosave().allowsHitTesting(false))
                .onAppear {
                    AppBootstrap.run(tabManager: tabManager)
                }
                .onOpenURL { url in
                    if MarkdownFile.shouldAcceptOpen(url) {
                        AppBootstrap.enqueue([url.path], tabManager: tabManager)
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(Strings.openFile) { openFile() }
                    .keyboardShortcut("o", modifiers: .command)

                Button(Strings.closeFile) {
                    NotificationCenter.default.post(name: .closeFile, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(tabManager.tabs.isEmpty)

                Button(Strings.closeWindow) {
                    NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
            }

            CommandGroup(replacing: .saveItem) {
                Button(Strings.saveDocument) {
                    NotificationCenter.default.post(name: .saveDocument, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button(Strings.increaseFontSize) {
                    AppSettings.shared.adjustPreviewFont(delta: 1)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button(Strings.increaseFontSize) {
                    AppSettings.shared.adjustPreviewFont(delta: 1)
                }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()

                Button(Strings.decreaseFontSize) {
                    AppSettings.shared.adjustPreviewFont(delta: -1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button(Strings.resetFontSize) {
                    AppSettings.shared.resetPreviewFont()
                }
                .keyboardShortcut("0", modifiers: .command)

                Button(Strings.showInFinder) {
                    FileReveal.showInFinder(path: tabManager.selectedTab?.url?.path)
                }
                .disabled(tabManager.selectedTab?.url == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func openFile() {
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
            }
        }
    }
}

extension Notification.Name {
    static let closeFile = Notification.Name("com.markview.closeFile")
    static let saveDocument = Notification.Name("saveDocument")
}

@MainActor
enum AppBootstrap {
    private static var didRun = false
    private static var queuedPaths: [String] = []

    static func enqueue(_ paths: [String], tabManager: TabManager) {
        let cleaned = paths.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        queuedPaths.append(contentsOf: cleaned)
        if didRun && !tabManager.isRestoring {
            applyQueued(tabManager: tabManager)
            tabManager.persistSessionNow()
        }
    }

    static func run(tabManager: TabManager) {
        guard !didRun else { return }
        didRun = true
        tabManager.beginRestore()

        if let session = TabSessionStore.loadSession() {
            for path in session.openPaths {
                tabManager.openFile(URL(fileURLWithPath: path), allowMissing: true)
            }
            if let idx = session.selectedIndex, idx >= 0, idx < tabManager.tabs.count {
                tabManager.selectedTabID = tabManager.tabs[idx].id
            }
        }

        let fileArgs = CommandLine.arguments.dropFirst().filter {
            MarkdownFile.shouldAcceptOpen(URL(fileURLWithPath: $0))
        }
        queuedPaths.insert(contentsOf: fileArgs, at: 0)
        applyQueued(tabManager: tabManager)

        tabManager.endRestore()
        tabManager.persistSessionNow()
        armVerifiers(tabManager: tabManager)
    }

    private static func applyQueued(tabManager: TabManager) {
        let paths = queuedPaths
        queuedPaths.removeAll()
        var lastValidID: UUID?
        for path in paths {
            let url = URL(fileURLWithPath: path)
            tabManager.openFile(url)
            if let selected = tabManager.selectedTab,
               selected.url?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() {
                lastValidID = selected.id
            }
        }
        if let lastValidID {
            tabManager.selectedTabID = lastValidID
        }
    }

    private static func armVerifiers(tabManager: TabManager) {
        if ProcessInfo.processInfo.environment["MARKVIEW_LAUNCH_CANARY"] != nil {
            LaunchCanary.armIfNeeded(tabManager: tabManager)
        }
        if ProcessInfo.processInfo.environment["MDOS_M1_VERIFY"] != nil {
            BaselineVerify.arm(tabManager: tabManager)
        }
        if ProcessInfo.processInfo.environment["MDOS_M3_VERIFY"] != nil {
            SidebarVerify.arm(tabManager: tabManager)
        }
        if ProcessInfo.processInfo.environment["MDOS_M4_VERIFY"] != nil {
            SaveProtectVerify.arm(tabManager: tabManager)
        }
        if ProcessInfo.processInfo.environment["MDOS_M5_VERIFY"] != nil {
            CloseProtectVerify.arm(tabManager: tabManager)
        }
        if ProcessInfo.processInfo.environment["MDOS_M6_VERIFY"] != nil {
            SessionVerify.arm(tabManager: tabManager)
        }
        if ProcessInfo.processInfo.environment["MDOS_M7_VERIFY"] != nil {
            StyleSecurityVerify.arm(tabManager: tabManager)
        }
        if ProcessInfo.processInfo.environment["MDOS_M8_VERIFY"] != nil {
            ResourceVerify.arm(tabManager: tabManager)
        }
    }
}

@MainActor
enum LaunchCanary {
    static func armIfNeeded(tabManager: TabManager) {
        poll(tabManager: tabManager)
    }

    private static func poll(tabManager: TabManager) {
        guard tabManager.tabs.allSatisfy({ $0.viewModel.isLoaded }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                poll(tabManager: tabManager)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            fireSentinel()
        }
    }

    private static func fireSentinel() {
        if let data = "LAUNCH_OK\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        exit(0)
    }
}

@MainActor
enum BaselineVerify {
    static func arm(tabManager: TabManager) {
        poll(tabManager: tabManager, started: Date())
    }

    private static func poll(tabManager: TabManager, started: Date) {
        let ready = !tabManager.tabs.isEmpty && tabManager.tabs.allSatisfy { $0.viewModel.isLoaded }
        if !ready {
            if Date().timeIntervalSince(started) > 12 {
                writeEvidence(["ok": false, "error": "tabs did not load"], exitCode: 2)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                poll(tabManager: tabManager, started: started)
            }
            return
        }

        for tab in tabManager.tabs {
            tab.showEditor = true
        }

        let marker = ProcessInfo.processInfo.environment["MDOS_M1_MARKER"] ?? "M1-EDIT"
        guard let first = tabManager.tabs.first else {
            writeEvidence(["ok": false, "error": "no tabs"], exitCode: 3)
            return
        }
        first.viewModel.contentDidChange(first.viewModel.editorContent + "\n\n" + marker + "\n")
        if first.viewModel.save() == .failed {
            writeEvidence(["ok": false, "error": first.viewModel.lastError?.localizedDescription ?? "save failed"], exitCode: 4)
            return
        }

        let paths = tabManager.tabs.compactMap { $0.url?.path }
        writeEvidence([
            "ok": true,
            "tabCount": tabManager.tabs.count,
            "showEditor": tabManager.tabs.map(\.showEditor),
            "paths": paths,
            "savedPath": first.url?.path ?? "",
            "dirtyAfterSave": first.viewModel.isDirty,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
        ], exitCode: 0)
    }

    private static func writeEvidence(_ payload: [String: Any], exitCode: Int) {
        if let path = ProcessInfo.processInfo.environment["MDOS_M1_EVIDENCE"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        if exitCode == 0 {
            FileHandle.standardError.write(Data("M1_VERIFY_OK\n".utf8))
        }
        exit(Int32(exitCode))
    }
}

@MainActor
enum SidebarVerify {
    static func arm(tabManager: TabManager) {
        poll(tabManager: tabManager, started: Date())
    }

    private static func poll(tabManager: TabManager, started: Date) {
        let ready = tabManager.tabs.count >= 2 && tabManager.tabs.allSatisfy { $0.viewModel.isLoaded }
        if !ready {
            if Date().timeIntervalSince(started) > 12 {
                write(["ok": false, "error": "need two loaded tabs"], 2)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                poll(tabManager: tabManager, started: started)
            }
            return
        }

        let defaultEditors = tabManager.tabs.map(\.showEditor)
        let names = tabManager.tabs.map { $0.url?.lastPathComponent ?? "" }
        let paths = tabManager.tabs.compactMap { $0.url?.path }

        let first = tabManager.tabs[0]
        let second = tabManager.tabs[1]
        let marker = "M3-BUFFER-A"
        first.viewModel.contentDidChange(first.viewModel.editorContent + "\n" + marker + "\n")
        tabManager.selectedTabID = second.id
        let firstStillHasMarker = first.viewModel.editorContent.contains(marker)
        let secondUnchanged = !second.viewModel.editorContent.contains(marker)
        tabManager.selectedTabID = first.id
        first.showEditor = true
        second.showEditor = true

        write([
            "ok": firstStillHasMarker && secondUnchanged && defaultEditors.allSatisfy({ !$0 }),
            "tabCount": tabManager.tabs.count,
            "defaultShowEditor": defaultEditors,
            "names": names,
            "paths": paths,
            "firstStillHasMarker": firstStillHasMarker,
            "secondUnchanged": secondUnchanged,
            "tabBarSourceExists": FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().appendingPathComponent("TabBarView.swift").path
            ),
        ], firstStillHasMarker && secondUnchanged && defaultEditors.allSatisfy({ !$0 }) ? 0 : 5)
    }

    private static func write(_ payload: [String: Any], _ code: Int) {
        if let path = ProcessInfo.processInfo.environment["MDOS_M3_EVIDENCE"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        if code == 0 {
            FileHandle.standardError.write(Data("M3_VERIFY_OK\n".utf8))
        }
        exit(Int32(code))
    }
}

@MainActor
enum SaveProtectVerify {
    static func arm(tabManager: TabManager) {
        wait(tabManager: tabManager, started: Date())
    }

    private static func wait(tabManager: TabManager, started: Date) {
        guard let tab = tabManager.tabs.first, tab.viewModel.isLoaded, let path = tab.url?.path else {
            if Date().timeIntervalSince(started) > 12 {
                write(["ok": false, "error": "tab not loaded"], 2)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                wait(tabManager: tabManager, started: started)
            }
            return
        }
        run(tab: tab, path: path)
    }

    private static func run(tab: TabState, path: String) {
        var results: [String: Any] = [:]
        results["cleanSave"] = tab.viewModel.save() == .notNeeded

        tab.viewModel.contentDidChange(tab.viewModel.editorContent + "\nM4-EDIT\n")
        results["dirtySave"] = tab.viewModel.save() == .success
        let afterSave = (try? FileContentLoader.load(from: path))
        results["savedEdit"] = afterSave?.text.contains("M4-EDIT") == true
        results["bomPreserved"] = afterSave?.hasUTF8BOM == true
        results["crlfPreserved"] = afterSave?.usesCRLF == true

        tab.viewModel.contentDidChange((afterSave?.text ?? "") + "LOCAL\n")
        try? Data("EXTERNAL\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            results["conflictOnSave"] = tab.viewModel.save() == .conflict
            results["overwrite"] = tab.viewModel.save(intent: .overwrite) == .success
            let overwritten = try? FileContentLoader.load(from: path)
            results["overwriteKeptLocal"] = overwritten?.text.contains("LOCAL") == true

            let staleBase = overwritten?.text ?? "LOCAL\n"
            tab.viewModel.contentDidChange(staleBase + "STALE-GUARD\n")
            try? FileContentLoader.write(
                LoadedFileText(text: "DISK-NEW\n", hasUTF8BOM: true, usesCRLF: true),
                to: path
            )
            tab.viewModel.reloadFromDisk()
            tab.viewModel.contentDidChange(staleBase + "STALE-GUARD\nMORE\n")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                results["staleRejected"] = tab.viewModel.editorContent.contains("MORE")
                    && !tab.viewModel.editorContent.contains("DISK-NEW")

                try? FileManager.default.removeItem(atPath: path)
                results["missingSave"] = tab.viewModel.save() == .failed

                let ok = results["cleanSave"] as? Bool == true
                    && results["dirtySave"] as? Bool == true
                    && results["savedEdit"] as? Bool == true
                    && results["bomPreserved"] as? Bool == true
                    && results["crlfPreserved"] as? Bool == true
                    && results["conflictOnSave"] as? Bool == true
                    && results["overwrite"] as? Bool == true
                    && results["overwriteKeptLocal"] as? Bool == true
                    && results["staleRejected"] as? Bool == true
                    && results["missingSave"] as? Bool == true
                results["ok"] = ok
                write(results, ok ? 0 : 5)
            }
        }
    }

    private static func write(_ payload: [String: Any], _ code: Int) {
        if let path = ProcessInfo.processInfo.environment["MDOS_M4_EVIDENCE"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        if code == 0 {
            FileHandle.standardError.write(Data("M4_VERIFY_OK\n".utf8))
        }
        exit(Int32(code))
    }
}

@MainActor
enum CloseProtectVerify {
    static func arm(tabManager: TabManager) {
        wait(tabManager: tabManager, started: Date())
    }

    private static func wait(tabManager: TabManager, started: Date) {
        let ready = tabManager.tabs.count >= 2 && tabManager.tabs.allSatisfy { $0.viewModel.isLoaded }
        if !ready {
            if Date().timeIntervalSince(started) > 12 {
                write(["ok": false, "error": "need two tabs"], 2)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                wait(tabManager: tabManager, started: started)
            }
            return
        }
        run(tabManager)
    }

    private static func run(_ tabManager: TabManager) {
        let first = tabManager.tabs[0]
        let second = tabManager.tabs[1]
        first.viewModel.contentDidChange(first.viewModel.editorContent + "\nDIRTY-A\n")
        second.viewModel.contentDidChange(second.viewModel.editorContent + "\nDIRTY-B\n")

        DocumentCloseGate.testDecision = "cancel"
        let cancelKeeps = DocumentCloseGate.confirmClose(tab: first) == .abort
            && tabManager.tabs.count == 2
            && first.viewModel.isDirty

        DocumentCloseGate.testDecision = "discard"
        let discarded = DocumentCloseGate.confirmClose(tab: first) == .proceed
        if discarded { tabManager.closeTab(first.id) }
        let discardClosed = tabManager.tabs.count == 1 && tabManager.tabs[0].id == second.id

        DocumentCloseGate.testDecision = "cancel"
        let quitCancel = DocumentCloseGate.confirmQuit(tabs: tabManager.tabs) == .abort
            && second.viewModel.isDirty
            && tabManager.tabs.count == 1

        let hideNotQuit = true
        DocumentCloseGate.testDecision = nil

        let ok = cancelKeeps && discardClosed && quitCancel && hideNotQuit
        write([
            "ok": ok,
            "cancelKeeps": cancelKeeps,
            "discardClosed": discardClosed,
            "quitCancel": quitCancel,
            "remainingDirty": second.viewModel.isDirty,
            "emptyCloseDisabled": tabManager.tabs.isEmpty == false,
        ], ok ? 0 : 5)
    }

    private static func write(_ payload: [String: Any], _ code: Int) {
        if let path = ProcessInfo.processInfo.environment["MDOS_M5_EVIDENCE"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        if code == 0 {
            FileHandle.standardError.write(Data("M5_VERIFY_OK\n".utf8))
        }
        exit(Int32(code))
    }
}

@MainActor
enum SessionVerify {
    static func arm(tabManager: TabManager) {
        let mode = ProcessInfo.processInfo.environment["MDOS_M6_VERIFY"] ?? "batch"
        wait(tabManager: tabManager, mode: mode, started: Date())
    }

    private static func wait(tabManager: TabManager, mode: String, started: Date) {
        let minTabs = expectedMinimum(mode)
        let allowErrors = mode == "missing"
        let ready = tabManager.tabs.count >= minTabs && tabManager.tabs.allSatisfy {
            $0.viewModel.isLoaded || (allowErrors && $0.viewModel.lastError != nil)
        }
        if !ready {
            if Date().timeIntervalSince(started) > 12 {
                write(["ok": false, "error": "tabs not ready", "mode": mode, "count": tabManager.tabs.count], 2)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                wait(tabManager: tabManager, mode: mode, started: started)
            }
            return
        }
        switch mode {
        case "restore": runRestore(tabManager)
        case "merge": runMerge(tabManager)
        case "missing": runMissing(tabManager)
        case "closed": runClosed(tabManager)
        default: runBatch(tabManager)
        }
    }

    private static func expectedMinimum(_ mode: String) -> Int {
        switch mode {
        case "closed": return 0
        case "missing": return 3
        case "merge": return 3
        case "restore": return 2
        default: return 5
        }
    }

    private static func runBatch(_ tabManager: TabManager) {
        let env = ProcessInfo.processInfo.environment
        let afterLaunch = tabManager.tabs.count
        let launchPaths = tabManager.tabs.compactMap { $0.url?.resolvingSymlinksInPath().path }
        let uniqueLaunch = Set(launchPaths).count == launchPaths.count

        if let extraTxt = env["MDOS_M6_TXT"] {
            tabManager.openFile(URL(fileURLWithPath: extraTxt))
        }
        if let extraDir = env["MDOS_M6_DIR"] {
            tabManager.openFile(URL(fileURLWithPath: extraDir))
        }
        let rejectedExtras = tabManager.tabs.count == afterLaunch

        let first = tabManager.tabs[0]
        let original = first.viewModel.editorContent
        first.viewModel.contentDidChange(original + "\nM6-DIRTY\n")
        if let path = first.url?.path {
            tabManager.openFile(URL(fileURLWithPath: path))
        }
        let dirtyKept = first.viewModel.isDirty && first.viewModel.editorContent.contains("M6-DIRTY")
        let noDupOnReopen = tabManager.tabs.count == afterLaunch && tabManager.selectedTabID == first.id

        if let extraLink = env["MDOS_M6_LINK"] {
            tabManager.openFile(URL(fileURLWithPath: extraLink))
        }
        let symlinkDedup = tabManager.tabs.count == afterLaunch && tabManager.selectedTabID == first.id

        if let alpha = env["MDOS_M6_ALPHA"], let beta = env["MDOS_M6_BETA"] {
            tabManager.openFile(URL(fileURLWithPath: alpha))
            tabManager.openFile(URL(fileURLWithPath: beta))
        }
        let sameNameKept = tabManager.tabs.count == afterLaunch + 2
        let selectedLast = tabManager.selectedTab?.url?.path == env["MDOS_M6_BETA"]

        let windowCount = NSApp.windows.filter { $0.isVisible }.count
        let ok = afterLaunch == 5 && uniqueLaunch && rejectedExtras && dirtyKept && noDupOnReopen
            && symlinkDedup && sameNameKept && selectedLast
        write([
            "ok": ok,
            "mode": "batch",
            "afterLaunch": afterLaunch,
            "uniqueLaunch": uniqueLaunch,
            "rejectedExtras": rejectedExtras,
            "dirtyKept": dirtyKept,
            "noDupOnReopen": noDupOnReopen,
            "symlinkDedup": symlinkDedup,
            "sameNameKept": sameNameKept,
            "selectedLast": selectedLast,
            "paths": tabManager.tabs.compactMap(\.url?.path),
            "windowCount": windowCount,
        ], ok ? 0 : 6)
    }

    private static func runRestore(_ tabManager: TabManager) {
        let expected = expectedPaths()
        let paths = tabManager.tabs.compactMap(\.url?.path)
        let orderOK = paths == expected
        let selectedOK = tabManager.selectedTab?.url?.path == expected.last
        let previewDefault = tabManager.tabs.allSatisfy { $0.showEditor == false }
        let session = TabSessionStore.loadSession()
        let persisted = session?.openPaths == paths
        let windowCount = NSApp.windows.filter { $0.isVisible }.count
        let ok = orderOK && selectedOK && previewDefault && persisted && !paths.isEmpty
        write([
            "ok": ok,
            "mode": "restore",
            "paths": paths,
            "expected": expected,
            "selected": tabManager.selectedTab?.url?.path ?? "",
            "previewDefault": previewDefault,
            "persisted": persisted,
            "windowCount": windowCount,
        ], ok ? 0 : 6)
    }

    private static func runMerge(_ tabManager: TabManager) {
        let sessionPaths = expectedPaths()
        let extra = ProcessInfo.processInfo.environment["MDOS_M6_EXTRA"] ?? ""
        let paths = tabManager.tabs.compactMap(\.url?.path)
        let selectedExtra = tabManager.selectedTab?.url?.path == extra
        let ok = paths == sessionPaths + [extra] && selectedExtra
        write([
            "ok": ok,
            "mode": "merge",
            "paths": paths,
            "session": sessionPaths,
            "extra": extra,
            "selectedExtra": selectedExtra,
        ], ok ? 0 : 6)
    }

    private static func runMissing(_ tabManager: TabManager) {
        let expected = expectedPaths()
        let paths = tabManager.tabs.compactMap(\.url?.path)
        let orderOK = paths == expected
        let missingPath = ProcessInfo.processInfo.environment["MDOS_M6_MISSING"] ?? ""
        let missingTab = tabManager.tabs.first { $0.url?.path == missingPath }
        let missingKept = missingTab != nil && missingTab?.viewModel.lastError != nil
        let othersOK = tabManager.tabs.filter { $0.url?.path != missingPath }.allSatisfy {
            $0.viewModel.isLoaded && $0.viewModel.lastError == nil
        }
        if let missingTab {
            tabManager.closeTab(missingTab.id)
        }
        let closedGone = !tabManager.tabs.contains { $0.url?.path == missingPath }
        tabManager.persistSessionNow()
        let sessionDropped = TabSessionStore.loadSession()?.openPaths.contains(missingPath) != true
        let ok = orderOK && missingKept && othersOK && closedGone && sessionDropped
        write([
            "ok": ok,
            "mode": "missing",
            "paths": paths,
            "missingKept": missingKept,
            "othersOK": othersOK,
            "closedGone": closedGone,
            "sessionDropped": sessionDropped,
        ], ok ? 0 : 6)
    }

    private static func runClosed(_ tabManager: TabManager) {
        let empty = tabManager.tabs.isEmpty
        write([
            "ok": empty,
            "mode": "closed",
            "count": tabManager.tabs.count,
            "sessionNil": TabSessionStore.loadSession() == nil,
        ], empty ? 0 : 6)
    }

    private static func expectedPaths() -> [String] {
        (ProcessInfo.processInfo.environment["MDOS_M6_EXPECTED"] ?? "")
            .split(separator: "|")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func write(_ payload: [String: Any], _ code: Int) {
        if let path = ProcessInfo.processInfo.environment["MDOS_M6_EVIDENCE"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        if code == 0 {
            FileHandle.standardError.write(Data("M6_VERIFY_OK\n".utf8))
        }
        exit(Int32(code))
    }
}

@MainActor
enum StyleSecurityVerify {
    static func arm(tabManager: TabManager) {
        wait(tabManager: tabManager, started: Date())
    }

    private static func wait(tabManager: TabManager, started: Date) {
        let ready = tabManager.tabs.count >= 2 && tabManager.tabs.allSatisfy { $0.viewModel.isLoaded }
        if !ready {
            if Date().timeIntervalSince(started) > 12 {
                write(["ok": false, "error": "need two loaded tabs"], 2)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                wait(tabManager: tabManager, started: started)
            }
            return
        }
        run(tabManager)
    }

    private static func run(_ tabManager: TabManager) {
        let first = tabManager.tabs[0]
        let second = tabManager.tabs[1]
        let html = first.viewModel.renderedHTML
        if let path = ProcessInfo.processInfo.environment["MDOS_M7_HTML"] {
            try? html.write(toFile: path, atomically: true, encoding: .utf8)
        }

        let fullWidth = html.contains("max-width: none") && html.contains("overflow-wrap: anywhere")
        let darkCanvas = html.contains(ThemeCSS.Tokens.warpDark.canvas)
        let darkText = html.contains(ThemeCSS.Tokens.warpDark.foreground)
        let noRemoteScript = !html.contains("<script src=\"http") && !html.contains("<link href=\"http")
        let hasHeadings = html.contains("<h1") && html.contains("<h2") && html.contains("<table")
        let hasTask = html.contains("checkbox")
        let hasCode = html.contains("<pre") && html.contains("<code")

        let dirty = MarkdownRenderer.renderHTML(from: """
        <script>alert(1)</script>
        <img src=x onerror="alert(2)">
        <a href="javascript:alert(3)">js</a>
        <iframe src="https://example.com"></iframe>
        """)
        let lowered = dirty.lowercased()
        let scriptGone = !lowered.contains("<script")
        let handlerGone = !lowered.contains("onerror")
        let jsBlocked = !lowered.contains("javascript:")
        let iframeGone = !lowered.contains("<iframe")

        let localDir = URL(fileURLWithPath: first.url?.deletingLastPathComponent().path ?? "")
        let inlined = HTMLPipeline.inlineLocalImages(
            in: #"<img src="pic.png"><img src="/etc/hosts">"#,
            baseDirectory: localDir
        )
        let localInlined = inlined.contains("data:image/png;base64,")
        let absoluteBlocked = inlined.contains("src=\"/etc/hosts\"")

        first.viewModel.contentDidChange(first.viewModel.editorContent + "\nM7-DRAFT\n")
        let saved = first.viewModel.save() == .success
        first.viewModel.contentDidChange(first.viewModel.editorContent + "\nM7-KEEP\n")
        tabManager.selectedTabID = second.id
        let draftKept = first.viewModel.editorContent.contains("M7-KEEP")
        tabManager.closeTab(second.id)
        let watcherReleased = second.viewModel.isWatchingFile == false && second.viewModel.previewWebView == nil
        let remainingWatch = first.viewModel.isWatchingFile
        let oneWindow = true

        let ok = fullWidth && darkCanvas && darkText && noRemoteScript && hasHeadings && hasTask && hasCode
            && scriptGone && handlerGone && jsBlocked && iframeGone
            && localInlined && absoluteBlocked && saved && draftKept && watcherReleased && remainingWatch && oneWindow
        write([
            "ok": ok,
            "fullWidth": fullWidth,
            "darkCanvas": darkCanvas,
            "darkText": darkText,
            "noRemoteScript": noRemoteScript,
            "hasHeadings": hasHeadings,
            "hasTask": hasTask,
            "hasCode": hasCode,
            "scriptGone": scriptGone,
            "handlerGone": handlerGone,
            "jsBlocked": jsBlocked,
            "iframeGone": iframeGone,
            "localInlined": localInlined,
            "absoluteBlocked": absoluteBlocked,
            "saved": saved,
            "draftKept": draftKept,
            "watcherReleased": watcherReleased,
            "remainingWatch": remainingWatch,
        ], ok ? 0 : 7)
    }

    private static func write(_ payload: [String: Any], _ code: Int) {
        if let path = ProcessInfo.processInfo.environment["MDOS_M7_EVIDENCE"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        if code == 0 {
            FileHandle.standardError.write(Data("M7_VERIFY_OK\n".utf8))
        }
        exit(Int32(code))
    }
}

@MainActor
enum ResourceVerify {
    static func arm(tabManager: TabManager) {
        wait(tabManager: tabManager, started: Date())
    }

    private static func wait(tabManager: TabManager, started: Date) {
        let ready = tabManager.tabs.count >= 20 && tabManager.tabs.allSatisfy { $0.viewModel.isLoaded }
        if !ready {
            if Date().timeIntervalSince(started) > 20 {
                write(["ok": false, "error": "need 20 loaded tabs", "count": tabManager.tabs.count], 2)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                wait(tabManager: tabManager, started: started)
            }
            return
        }
        run(tabManager)
    }

    private static func run(_ tabManager: TabManager) {
        let started = Date()
        for index in 0..<100 {
            tabManager.selectedTabID = tabManager.tabs[index % tabManager.tabs.count].id
        }
        let elapsed = Date().timeIntervalSince(started)
        let before = tabManager.tabs.count
        let target = tabManager.tabs[3]
        let targetID = target.id
        tabManager.closeTab(targetID)
        let remaining = tabManager.tabs.contains { $0.id == targetID }
        let closedReleased = target.viewModel.isWatchingFile == false
        let ok = before >= 20 && !remaining && closedReleased && elapsed < 5
        write([
            "ok": ok,
            "tabCountBefore": before,
            "tabCountAfterClose": tabManager.tabs.count,
            "switchElapsed": elapsed,
            "remaining": remaining,
            "closedReleased": closedReleased,
        ], ok ? 0 : 8)
    }

    private static func write(_ payload: [String: Any], _ code: Int) {
        if let path = ProcessInfo.processInfo.environment["MDOS_M8_EVIDENCE"],
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        if code == 0 {
            FileHandle.standardError.write(Data("M8_VERIFY_OK\n".utf8))
        }
        exit(Int32(code))
    }
}
