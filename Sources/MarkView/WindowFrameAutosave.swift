import AppKit
import SwiftUI
import MarkViewAppCore

@MainActor
struct WindowFrameAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowFrameAutosaveView {
        WindowFrameAutosaveView(name: "MarkView.MainWindow")
    }

    func updateNSView(_ nsView: WindowFrameAutosaveView, context: Context) {
        nsView.configureWindowIfNeeded()
    }
}

@MainActor
final class WindowFrameAutosaveView: NSView {
    private let name: String
    private weak var configuredWindow: NSWindow?

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let window, window !== configuredWindow else { return }
        if window.frameAutosaveName == name || window.setFrameAutosaveName(name) {
            configuredWindow = window
        }
        zoomToVisibleScreen(window)
    }

    private func zoomToVisibleScreen(_ window: NSWindow) {
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame, !visible.isEmpty else { return }
        window.setFrame(visible, display: true)
    }
}

struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let palette: ThemePalette
    var onResizeEnded: (CGFloat) -> Void = { _ in }
    @State private var dragOrigin: CGFloat?

    var body: some View {
        ZStack {
            palette.subtle
            palette.border.frame(width: 1)
        }
        .frame(width: 6)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            // The divider moves during layout; measure against a stationary space.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragOrigin == nil {
                        dragOrigin = width
                    }
                    let next = (dragOrigin ?? width) + value.translation.width
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        width = min(420, max(160, next))
                    }
                }
                .onEnded { _ in
                    dragOrigin = nil
                    onResizeEnded(width)
                }
        )
    }
}
