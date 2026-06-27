import SwiftUI
import SwiftTerm

/// A live terminal attached to a persistent tmux session on the hub.
///
/// Runs `ssh -tt kepler -- exec zsh -lc 'tmux new-session -A -s <session>'` inside
/// SwiftTerm's `LocalProcessTerminalView`. Because the work lives in tmux on the
/// mini, detaching/closing here never kills it — reattaching resumes the session.
///
/// On a `WakeObserver` reconnect signal (sleep/wake or network change), the pane
/// tears down the stale ssh client and reconnects, re-attaching the same session.
struct TerminalPane: NSViewRepresentable {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wakeObserver: WakeObserver

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = ClipboardTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        context.coordinator.start(view, host: settings.hub,
                                  session: settings.primaryTmuxSession,
                                  baselineSignal: wakeObserver.reconnectSignal)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.syncReconnect(signal: wakeObserver.reconnectSignal,
                                          view: nsView,
                                          host: settings.hub,
                                          session: settings.primaryTmuxSession)
    }

    /// SwiftUI tears the pane down on tab switch / window close. Terminate the
    /// local ssh client so it doesn't leak — the tmux session it was attached to
    /// keeps running on the mini and is resumed on the next attach.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if nsView.process.running {
            nsView.terminate()
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private var started = false
        private var lastReconnectSignal = 0

        func start(_ view: LocalProcessTerminalView, host: Host?, session: String,
                   baselineSignal: Int) {
            guard !started else { return }
            started = true
            lastReconnectSignal = baselineSignal
            launch(view, host: host, session: session,
                   reconnecting: false, generation: baselineSignal)
        }

        /// Called from `updateNSView`; reconnects only when the signal advances.
        func syncReconnect(signal: Int, view: LocalProcessTerminalView,
                           host: Host?, session: String) {
            guard started, signal != lastReconnectSignal else { return }
            lastReconnectSignal = signal
            launch(view, host: host, session: session,
                   reconnecting: true, generation: signal)
        }

        private func launch(_ view: LocalProcessTerminalView, host: Host?,
                            session: String, reconnecting: Bool, generation: Int) {
            guard let host else {
                view.feed(text: "No hub host configured.\r\n")
                return
            }

            // Replace any live client first; only the remote tmux should persist.
            if view.process.running {
                view.terminate()
            }
            // On reconnect the post-wake socket is stale, so drop it for a fresh
            // master — but only once per signal across all panes (and never on a
            // first attach, which should reuse the shared master).
            if reconnecting {
                SSHManager.shared.resetMasterOnce(for: host, generation: generation)
            }

            let verb = reconnecting ? "Reconnecting to" : "Connecting to"
            view.feed(text: "\r\n\(verb) \(host.displayName) — tmux \"\(session)\"…\r\n")

            let args = SSHManager.shared.loginShellArguments(
                for: host,
                running: "tmux new-session -A -s \(SSHManager.shellEscaped(session))"
            )
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
                              "it reconnects on wake / network change.]\r\n")
        }
    }
}
