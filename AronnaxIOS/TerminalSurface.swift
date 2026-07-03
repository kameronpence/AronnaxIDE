import SwiftUI
import SwiftTerm
import UIKit

/// Hosts SwiftTerm's iOS `TerminalView` in SwiftUI and wires it to the SSH session:
/// keystrokes go out via `send`, remote output is fed in by the session. Uses
/// SwiftTerm's built-in key toolbar (esc/ctrl/tab/arrows); a custom, safe-area-inset
/// key bar is a follow-up.
struct TerminalSurface: UIViewRepresentable {
    let session: SSHTerminalSession

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        // Light theme — matches the macOS app (plain shell honors it; full-screen TUIs
        // like Claude/Codex paint their own colors).
        tv.nativeBackgroundColor = UIColor(white: 0.99, alpha: 1)
        tv.nativeForegroundColor = UIColor(white: 0.15, alpha: 1)
        tv.caretColor = .systemBlue
        tv.terminalDelegate = context.coordinator
        session.terminalView = tv
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHTerminalSession
        init(session: SSHTerminalSession) { self.session = session }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // SwiftTerm calls this on the main thread; hop the isolation to reach the
            // @MainActor session without an await (the delegate method is synchronous).
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
