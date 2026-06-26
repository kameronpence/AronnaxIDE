import SwiftUI
import SwiftTerm

/// M0: a bare SwiftTerm terminal view, proving the dependency links and renders.
/// M1 replaces this with a `LocalProcessTerminalView` running
/// `ssh -t <mini> -- tmux new-session -A -s main`, wired through SSHManager.
struct TerminalPane: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        let banner =
            "MiniIDE terminal\r\n" +
            "SSH + tmux wiring lands in M1 (SSHManager + ControlMaster).\r\n\r\n"
        view.feed(text: banner)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
