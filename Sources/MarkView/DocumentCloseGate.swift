import AppKit
import MarkViewAppCore

@MainActor
enum DocumentCloseGate {
    enum Decision {
        case proceed
        case abort
    }

    private static var isConfirming = false
    static var testDecision: String?

    static func confirmClose(tab: TabState) -> Decision {
        guard tab.viewModel.isDirty else { return .proceed }
        if isConfirming { return .abort }
        isConfirming = true
        defer { isConfirming = false }
        return resolveDirty(tab: tab)
    }

    static func confirmQuit(tabs: [TabState]) -> Decision {
        if isConfirming { return .abort }
        isConfirming = true
        defer { isConfirming = false }
        for tab in tabs where tab.viewModel.isDirty {
            if resolveDirty(tab: tab) == .abort {
                return .abort
            }
        }
        return .proceed
    }

    private static func resolveDirty(tab: TabState) -> Decision {
        if let forced = testDecision ?? ProcessInfo.processInfo.environment["MDOS_M5_DECISION"] {
            switch forced {
            case "save":
                return applySave(tab)
            case "discard":
                return .proceed
            default:
                return .abort
            }
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to \(tab.url?.lastPathComponent ?? "this document")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return applySave(tab)
        case .alertSecondButtonReturn:
            return .proceed
        default:
            return .abort
        }
    }

    private static func applySave(_ tab: TabState) -> Decision {
        switch tab.viewModel.save(intent: .normal) {
        case .success, .notNeeded:
            return .proceed
        case .conflict:
            return resolveSaveConflict(tab)
        case .failed:
            return .abort
        }
    }

    private static func resolveSaveConflict(_ tab: TabState) -> Decision {
        if let forced = testDecision ?? ProcessInfo.processInfo.environment["MDOS_M5_DECISION"] {
            return forced == "save" && tab.viewModel.save(intent: .overwrite) != .failed ? .proceed : .abort
        }
        let alert = NSAlert()
        alert.messageText = Strings.saveConflictTitle
        alert.informativeText = Strings.saveConflictMessage
        alert.addButton(withTitle: Strings.overwriteDisk)
        alert.addButton(withTitle: Strings.reload)
        alert.addButton(withTitle: Strings.cancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return tab.viewModel.save(intent: .overwrite) == .failed ? .abort : .proceed
        case .alertSecondButtonReturn:
            tab.viewModel.reloadFromDisk()
            return .abort
        default:
            return .abort
        }
    }
}
