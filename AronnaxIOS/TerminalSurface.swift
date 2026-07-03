import SwiftUI
import SwiftTerm
import UIKit

/// A plain (non-input) container that hosts SwiftTerm's key toolbar pinned to the
/// safe-area edges, so its end buttons don't fall into the display's rounded corners.
/// An explicit intrinsic height keeps it from collapsing the way a nested UIInputView did.
final class KeyBar: UIView {
    static let barHeight: CGFloat = 40
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: KeyBar.barHeight) }

    init(terminal: TerminalView) {
        super.init(frame: CGRect(x: 0, y: 0, width: terminal.bounds.width, height: KeyBar.barHeight))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear
        let ta = TerminalAccessory(frame: bounds, inputViewStyle: .keyboard, container: terminal)
        ta.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ta)
        NSLayoutConstraint.activate([
            ta.topAnchor.constraint(equalTo: topAnchor),
            ta.bottomAnchor.constraint(equalTo: bottomAnchor),
            ta.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            ta.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Hosts SwiftTerm's iOS `TerminalView` in SwiftUI and wires it to the SSH session:
/// keystrokes go out via `send`, remote output is fed in by the session.
struct TerminalSurface: UIViewRepresentable {
    let session: SSHTerminalSession

    func makeUIView(context: Context) -> AronnaxTerminalView {
        let tv = AronnaxTerminalView(frame: .zero)
        // Light theme — matches the macOS app (plain shell honors it; full-screen TUIs
        // like Claude/Codex paint their own colors).
        tv.nativeBackgroundColor = UIColor(white: 0.99, alpha: 1)
        tv.nativeForegroundColor = UIColor(white: 0.15, alpha: 1)
        tv.caretColor = .systemBlue
        // Off = a pan selects text locally (for copy) instead of being reported to the
        // app; also lets the scroll view own the plain shell's scrollback. Matches macOS.
        tv.allowMouseReporting = false
        tv.terminalDelegate = context.coordinator
        tv.inputAccessoryView = KeyBar(terminal: tv)
        tv.installAronnaxGestures()
        // Two-finger swipe → wheel events to the remote (see AronnaxTerminalView).
        tv.sendToRemote = { bytes in MainActor.assumeIsolated { session.sendInput(bytes) } }
        session.terminalView = tv
        // Focus so the key bar docks (and you can type immediately).
        DispatchQueue.main.async { _ = tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: AronnaxTerminalView, context: Context) {}

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
