import SwiftUI
import SwiftTerm

/// A live terminal attached to a persistent tmux session on the hub.
///
/// Runs `ssh -tt kepler -- exec zsh -lc 'tmux new-session -A -s <session>'` inside
/// SwiftTerm's `LocalProcessTerminalView`. Because the work lives in tmux on the
/// mini, detaching/closing here never kills it — reattaching resumes the session.
/// (Automatic reconnect-on-wake is M2.)
struct TerminalPane: NSViewRepresentable {
    @EnvironmentObject private var settings: AppSettings

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        context.coordinator.startIfNeeded(view, host: settings.hub,
                                          session: settings.primaryTmuxSession)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    /// SwiftUI tears the pane down on tab switch / window close. Terminate the
    /// local ssh client so it doesn't leak — the tmux session it was attached to
    /// keeps running on the mini and is resumed on the next attach.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        // Only signal a live child: if ssh already exited, SwiftTerm has reaped it
        // and its stored pid may have been reused — terminating it would hit an
        // unrelated process.
        if nsView.process.running {
            nsView.terminate()
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private var started = false

        func startIfNeeded(_ view: LocalProcessTerminalView, host: Host?, session: String) {
            guard !started else { return }
            started = true

            guard let host else {
                view.feed(text: "No hub host configured.\r\n")
                return
            }

            let args = SSHManager.shared.loginShellArguments(
                for: host,
                running: "tmux new-session -A -s \(SSHManager.shellEscaped(session))"
            )
            view.feed(text: "Connecting to \(host.displayName) — tmux \"\(session)\"…\r\n")
            view.startProcess(executable: SSHManager.shared.sshExecutable, args: args)
        }

        // MARK: LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let suffix = exitCode.map { " (exit \($0))" } ?? ""
            source.feed(text: "\r\n[ssh session ended\(suffix). " +
                              "The tmux session keeps running on the mini; " +
                              "reconnect-on-wake lands in M2.]\r\n")
        }
    }
}
