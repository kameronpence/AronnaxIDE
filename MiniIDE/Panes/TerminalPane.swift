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

    /// SwiftUI tears the pane down on tab switch / window close. Cancel any pending
    /// retry and terminate the local ssh client so it doesn't leak — the tmux session
    /// it was attached to keeps running on the mini and resumes on the next attach.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.stop(nsView)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private var started = false
        private var lastReconnectSignal = 0

        // Retained so an auto-retry can relaunch without waiting on a SwiftUI update.
        private weak var view: LocalProcessTerminalView?
        private var host: Host?
        private var session = ""

        private var stopping = false   // pane is being torn down
        private var retryCount = 0
        private var connectedAt: Date?
        private var retryWork: DispatchWorkItem?
        private let maxRetries = 6

        /// What to do with the shared ControlMaster before an attach.
        private enum MasterAction { case keep, resetOnce(Int), forceReset }

        func start(_ view: LocalProcessTerminalView, host: Host?, session: String,
                   baselineSignal: Int) {
            guard !started else { return }
            started = true
            lastReconnectSignal = baselineSignal
            self.view = view
            self.host = host
            self.session = session
            launch(reconnecting: false, master: .keep)   // first attach reuses the shared master
        }

        /// Called from `updateNSView`; reconnects only when the signal advances.
        func syncReconnect(signal: Int, view: LocalProcessTerminalView,
                           host: Host?, session: String) {
            guard started, signal != lastReconnectSignal else { return }
            lastReconnectSignal = signal
            self.view = view
            self.host = host
            self.session = session
            retryCount = 0   // an explicit Reconnect / wake gets a fresh retry budget
            // resetOnce dedups across panes reacting to the same wake/network signal.
            launch(reconnecting: true, master: .resetOnce(signal))
        }

        /// Pane teardown: cancel a pending retry and terminate the client so it can't
        /// leak — the remote tmux keeps running and resumes on the next attach.
        func stop(_ view: LocalProcessTerminalView) {
            retryWork?.cancel()
            retryWork = nil
            stopping = true
            if view.process.running {
                view.terminate()   // synchronous; cancels its monitor, so no callback fires
            }
        }

        private func launch(reconnecting: Bool, master: MasterAction) {
            retryWork?.cancel()
            retryWork = nil
            guard let view, let host else {
                self.view?.feed(text: "No hub host configured.\r\n")
                return
            }

            // Replace any live client first. terminate() is synchronous and cancels the
            // process monitor, so it sets `running = false` now and fires NO delegate
            // callback — startProcess below proceeds cleanly and only genuine drops
            // reach processTerminated.
            if view.process.running {
                view.terminate()
            }
            switch master {
            case .keep:                break
            case .resetOnce(let gen):  _ = SSHManager.shared.resetMasterOnce(for: host, generation: gen)
            case .forceReset:          SSHManager.shared.closeMaster(for: host)
            }

            let verb = reconnecting ? "Reconnecting to" : "Connecting to"
            view.feed(text: "\r\n\(verb) \(host.displayName) — tmux \"\(session)\"…\r\n")

            let args = SSHManager.shared.loginShellArguments(
                for: host,
                running: "tmux new-session -A -s \(SSHManager.shellEscaped(session))"
            )
            connectedAt = Date()
            view.startProcess(executable: SSHManager.shared.sshExecutable, args: args)
        }

        // MARK: LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            // Only *genuine* exits reach here — our own terminate() never calls back.
            if stopping { return }   // pane is going away

            // A clean exit (the user typed `exit`, or detached tmux) is deliberate —
            // don't fight it. Only non-zero exits are dropped connections worth retrying.
            if exitCode == 0 {
                source.feed(text: "\r\n[session ended. Hit Reconnect to reattach — the " +
                                  "tmux session keeps running on the mini.]\r\n")
                return
            }
            // A connection that stayed up a while then dropped gets a fresh retry budget.
            if let connectedAt, Date().timeIntervalSince(connectedAt) > 20 {
                retryCount = 0
            }
            guard retryCount < maxRetries else {
                let suffix = exitCode.map { " (exit \($0))" } ?? ""
                source.feed(text: "\r\n[ssh session ended\(suffix). Hit Reconnect to try " +
                                  "again — the tmux session keeps running on the mini.]\r\n")
                return
            }
            // Auto-reconnect with backoff so a transient drop (mini asleep, network
            // blip) heals itself instead of sitting dead until a manual Reconnect.
            retryCount += 1
            let delay = min(1 << retryCount, 16)   // 2, 4, 8, 16, 16, 16 s
            source.feed(text: "\r\n[connection lost — retrying in \(delay)s " +
                              "(\(retryCount)/\(maxRetries))…]\r\n")
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.launch(reconnecting: true, master: .forceReset)   // fresh master each retry
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
        }
    }
}
