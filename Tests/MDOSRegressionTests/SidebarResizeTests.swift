import AppKit
import SwiftUI
import WebKit
import MarkViewCore
import MarkViewAppCore

@MainActor
private final class SidebarDragProbe: ObservableObject {
    @Published var width: CGFloat = 240
    var samples: [CGFloat] = []
    var committedWidths: [CGFloat] = []
    @Published var document = 0
    @Published var showPreview = false
    var webViewCreations = 0
    weak var webView: WKWebView?
}

private struct SidebarDragHarness: View {
    @ObservedObject var probe: SidebarDragProbe

    var body: some View {
        HStack(spacing: 0) {
            Color.gray.frame(width: probe.width)
            SidebarResizeHandle(width: Binding(
                get: { probe.width },
                set: { probe.width = $0; probe.samples.append($0) }
            ), palette: .warp(isDark: true), onResizeEnded: { probe.committedWidths.append($0) })
            if probe.showPreview {
                WebPreviewView(
                    html: HTMLPipeline.assembleFullDocument(from: "# Document \(probe.document)\n\nResize preview."),
                    theme: .dark,
                    onWebViewCreated: { probe.webViewCreations += 1; probe.webView = $0 }
                )
                .id(probe.document)
                .frame(maxWidth: .infinity)
            } else {
                Color.black.overlay(Text("Document \(probe.document)")).frame(maxWidth: .infinity)
            }
        }
        .frame(width: 1000, height: 500)
    }
}

@MainActor
func runSidebarResizeTests(check: (Bool, String) -> Void) {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let probe = SidebarDragProbe()
    let hosting = NSHostingView(rootView: SidebarDragHarness(probe: probe))
    let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1000, height: 500),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderBack(nil)
    func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    func send(_ type: NSEvent.EventType, x: CGFloat) {
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 250),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(event)
        pump()
    }
    pump()
    hosting.layoutSubtreeIfNeeded()
    send(.leftMouseDown, x: 243)
    let offsets: [CGFloat] = [10, 20, 40, 70, 100, 130, 150, 120, 80, 40]
    var observed: [CGFloat] = []
    for offset in offsets {
        send(.leftMouseDragged, x: 243 + offset)
        observed.append(probe.width)
    }
    check(probe.committedWidths.isEmpty, "dragging does not persist intermediate widths")
    send(.leftMouseUp, x: 283)
    print("SIDEBAR offsets=\(offsets) widths=\(observed) callbacks=\(probe.samples.count)")
    check(!probe.samples.isEmpty, "native drag events reach the sidebar handle")
    check(zip(offsets, observed).allSatisfy { abs($1 - min(420, max(160, 240 + $0))) <= 2 },
          "divider follows the pointer without layout feedback")
    check(probe.committedWidths.count == 1 && abs(probe.committedWidths[0] - 280) <= 2,
          "mouse release commits the final width once")
    // A second drag must start from the current divider, including direction reversals.
    send(.leftMouseDown, x: 283)
    send(.leftMouseDragged, x: 800)
    check(abs(probe.width - 420) <= 2, "drag clamps at the maximum width")
    send(.leftMouseDragged, x: 20)
    check(abs(probe.width - 160) <= 2, "drag clamps at the minimum width")
    send(.leftMouseDragged, x: 323)
    send(.leftMouseUp, x: 323)
    check(abs(probe.width - 320) <= 2 && probe.committedWidths.count == 2,
          "a second drag reverses smoothly and commits its final width")
    probe.document = 1
    pump()
    pump()
    check(abs(probe.width - 320) <= 2,
          "switching documents preserves the dragged sidebar width")
    // Offscreen synthetic events stop reaching SwiftUI gestures with a WKView sibling.
    // Check gesture behavior above, and native preview geometry separately below.
    probe.showPreview = true
    for _ in 0..<12 { pump() }
    var paneFramesMatch = true
    for width: CGFloat in [160, 200, 260, 320, 420, 360, 280] {
        probe.width = width
        pump()
        if let web = probe.webView {
            let frame = hosting.convert(web.bounds, from: web)
            paneFramesMatch = paneFramesMatch && abs(frame.minX - width - 6) <= 1
                && abs(frame.maxX - 1000) <= 1
        } else { paneFramesMatch = false }
    }
    check(paneFramesMatch && probe.webViewCreations == 1,
          "native preview resizes without overlap or WebView recreation")
    probe.document = 2
    pump()
    pump()
    check(abs(probe.width - 280) <= 2 && probe.webViewCreations == 2,
          "switching native previews preserves the sidebar width")
    window.orderOut(nil)
    window.contentView = nil
    window.close()
}
