import SwiftUI
import SwiftTerm
import UIKit

/// Wraps SwiftTerm's built-in key toolbar so it insets to the safe area — otherwise its
/// end buttons (esc / keyboard) fall into the display's rounded corners and get clipped.
final class InsetTerminalAccessory: UIInputView {
    private let inner: TerminalAccessory
    init(terminal: TerminalView) {
        inner = TerminalAccessory(frame: CGRect(x: 0, y: 0, width: terminal.bounds.width, height: 36),
                                  inputViewStyle: .keyboard, container: terminal)
        super.init(frame: CGRect(x: 0, y: 0, width: terminal.bounds.width, height: 36),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: topAnchor),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 8),
            inner.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Hosts SwiftTerm's iOS `TerminalView` in SwiftUI and wires it to the SSH session:
/// keystrokes go out via `send`, remote output is fed in by the session.
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
        tv.inputAccessoryView = InsetTerminalAccessory(terminal: tv)
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
