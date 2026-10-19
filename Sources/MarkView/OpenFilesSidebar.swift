import SwiftUI
import MarkViewAppCore

/// Left list of already-open files. Binds directly to TabManager.tabs.
struct OpenFilesSidebar: View {
    @ObservedObject var tabManager: TabManager
    var onClose: (UUID) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let palette = settings.palette
        VStack(alignment: .leading, spacing: 0) {
            Text("OPEN FILES")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            palette.border.opacity(0.7)
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tabManager.tabs) { tab in
                        SidebarRow(
                            tab: tab,
                            isSelected: tab.id == tabManager.selectedTabID,
                            pathHint: pathHint(for: tab),
                            palette: palette,
                            onSelect: { tabManager.selectedTabID = tab.id },
                            onClose: { onClose(tab.id) }
                        )
                        palette.border.opacity(0.45)
                            .frame(height: 1)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .foregroundStyle(palette.foreground)
        .background(palette.subtle)
    }

    private func pathHint(for tab: TabState) -> String? {
        guard let url = tab.url else { return nil }
        let name = url.lastPathComponent
        let duplicates = tabManager.tabs.filter { $0.url?.lastPathComponent == name }.count > 1
        guard duplicates else { return nil }
        return url.deletingLastPathComponent().path
    }
}

private struct SidebarRow: View {
    @ObservedObject var tab: TabState
    let isSelected: Bool
    let pathHint: String?
    let palette: ThemePalette
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? palette.accent : palette.muted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(fileName)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if tab.viewModel.isDirty {
                        Circle()
                            .fill(isSelected ? palette.accent : palette.foreground)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(Strings.unsavedA11yLabel)
                    }
                    if isInvalid {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                    }
                }
                if let pathHint {
                    Text(pathHint)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(pathHint)
                }
            }
            Spacer(minLength: 0)
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)
                .help(Strings.closeFile)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? palette.accent.opacity(0.16) : (isHovered ? palette.canvas.opacity(0.35) : Color.clear))
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }

    private var fileName: String {
        tab.url?.lastPathComponent ?? tab.displayName
    }

    private var isInvalid: Bool {
        if tab.viewModel.lastError != nil { return true }
        guard let path = tab.url?.path else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }
}
