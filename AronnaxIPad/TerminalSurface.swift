import SwiftUI
import SwiftTerm
import UIKit

/// Hosts SwiftTerm's iOS `TerminalView` in SwiftUI and wires it to one pane's `PaneSession`:
/// keystrokes go out via `send`, remote output is fed in by the session.
struct TerminalSurface: UIViewRepresentable {
    let session: PaneSession
    /// True when this leaf is the focused pane — only the focused terminal holds the keyboard.
    var isFocused: Bool = true

    func makeUIView(context: Context) -> AronnaxTerminalView {
        let tv = AronnaxTerminalView(frame: .zero)
        // Light theme — matches the macOS app (plain shell honors it; full-screen TUIs like
        // Claude/Codex paint their own colors).
        tv.nativeBackgroundColor = UIColor(white: 0.99, alpha: 1)
        tv.nativeForegroundColor = UIColor(white: 0.15, alpha: 1)
        tv.caretColor = .systemBlue
        // Off = a pan selects text locally (for copy) instead of being reported to the app;
        // also lets the scroll view own the plain shell's scrollback. Matches macOS.
        tv.allowMouseReporting = false
        tv.terminalDelegate = context.coordinator
        tv.installAronnaxGestures()
        tv.wantsFocus = isFocused
        session.terminalView = tv
        session.attach()
        return tv
    }

    func updateUIView(_ uiView: AronnaxTerminalView, context: Context) {
        // Drive the keyboard to follow the focused leaf: the focused terminal becomes first
        // responder, the others resign so keystrokes never go to a background pane.
        uiView.wantsFocus = isFocused
        if isFocused {
            if !uiView.isFirstResponder { _ = uiView.becomeFirstResponder() }
        } else if uiView.isFirstResponder {
            _ = uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: PaneSession
        init(session: PaneSession) { self.session = session }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            MainActor.assumeIsolated { session.sendInput(bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
