import SwiftUI
import SwiftTerm

/// The Terminal surface: a host picker over a live terminal. Picking a host attaches
/// to that host's persistent tmux session — the hub directly, or EC2/Lightsail via
/// the hub (ProxyJump). Each host keeps its own session, so switching is lossless.
struct TerminalPane: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var hostID: String = AppSettings.hubAlias
    @State private var confirmed: Set<String> = []   // protected hosts OK'd this session

    private var selectedHost: Host? {
        settings.hosts.first { $0.id == hostID } ?? settings.hub
    }

    /// On the hub the terminal opens in the selected project's directory (or the vault
    /// when none is selected); other hosts use the default login directory.
    private var terminalWorkdir: String? {
        guard let host = selectedHost, host.isHub else { return nil }
        return settings.activePath
    }

    var body: some View {
        VStack(spacing: 0) {
            if settings.hosts.count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                    Picker("Host", selection: $hostID) {
                        ForEach(settings.hosts) { host in
                            Text(host.displayName).tag(host.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                Divider()
            }
            terminalArea
        }
    }

    @ViewBuilder private var terminalArea: some View {
        if let host = selectedHost, settings.isProtected(host), !confirmed.contains(host.id) {
            protectedGate(host)
        } else {
            VStack(spacing: 0) {
                if let host = selectedHost, settings.isProtected(host) {
                    protectedBanner(host)
                }
                HostTerminalView(host: selectedHost, workdir: terminalWorkdir)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Blocks connecting to a protected host until the user explicitly confirms.
    private func protectedGate(_ host: Host) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 46)).foregroundStyle(.red)
            Text("Protected host").font(.title2.bold())
            Text("\(host.displayName) (\(host.sshAlias)) is marked **protected**. A terminal here is a live root shell — commands affect it directly.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Button("Connect to \(host.displayName)") { confirmed.insert(host.id) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Persistent red banner so you always know you're on a protected host.
    private func protectedBanner(_ host: Host) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
            Text("PROTECTED — \(host.displayName) (\(host.sshAlias))").fontWeight(.semibold)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.red)
    }
}

/// A live terminal attached to a persistent tmux session on `host`.
///
/// Runs `ssh -tt <host> -- exec zsh -lc 'tmux new-session -A -s <session>'` inside
/// SwiftTerm's `LocalProcessTerminalView`. Because the work lives in tmux on the
/// remote, detaching/closing here never kills it — reattaching resumes the session.
///
/// On a host change or a `WakeObserver` reconnect signal (sleep/wake or network
/// change), the pane tears down the stale ssh client and reconnects.
struct HostTerminalView: NSViewRepresentable {
    let host: Host?
    let workdir: String?   // start dir; nil = default home. A per-project session per dir.
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wakeObserver: WakeObserver

    /// One tmux session per working directory, so each project gets its own terminal
    /// (opened in that project); a nil workdir uses the shared primary session.
    private var session: String {
        guard let workdir else { return settings.primaryTmuxSession }
        return settings.primaryTmuxSession + AgentController.sessionSuffix(for: workdir)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = ClipboardTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        context.coordinator.start(view, host: host, session: session, workdir: workdir,
                                  baselineSignal: wakeObserver.reconnectSignal)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.syncReconnect(signal: wakeObserver.reconnectSignal,
                                          view: nsView, host: host,
                                          session: session, workdir: workdir)
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
        private var workdir: String?

        private var stopping = false   // pane is being torn down
        private var retryCount = 0
        private var connectedAt: Date?
        private var retryWork: DispatchWorkItem?
        private let maxRetries = 6

        /// What to do with the shared ControlMaster before an attach.
        private enum MasterAction { case keep, resetOnce(Int), forceReset }

        func start(_ view: LocalProcessTerminalView, host: Host?, session: String,
                   workdir: String?, baselineSignal: Int) {
            guard !started else { return }
            started = true
            lastReconnectSignal = baselineSignal
            self.view = view
            self.host = host
            self.session = session
            self.workdir = workdir
            launch(reconnecting: false, master: .keep)   // first attach reuses the shared master
        }

        /// Called from `updateNSView`; re-attaches when the host, the session/project
        /// directory changes, or the reconnect signal advances.
        func syncReconnect(signal: Int, view: LocalProcessTerminalView,
                           host: Host?, session: String, workdir: String?) {
            guard started else { return }
            let hostChanged = host?.id != self.host?.id
            let sessionChanged = session != self.session
            let reconnect = signal != lastReconnectSignal
            guard hostChanged || sessionChanged || reconnect else { return }
            lastReconnectSignal = signal
            self.view = view
            self.host = host
            self.session = session
            self.workdir = workdir
            retryCount = 0   // a host/project switch / explicit Reconnect / wake gets a fresh budget
            // A wake/network reconnect drops the stale master once; a host/project
            // switch just attaches normally.
            launch(reconnecting: true, master: reconnect ? .resetOnce(signal) : .keep)
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

            // `-c <dir>` starts a *new* session in the project dir; if the session
            // already exists, tmux attaches to it (keeping its dir) — so the terminal
            // opens in the selected project.
            let startDir = workdir.map { " -c \(SSHManager.shellEscaped($0))" } ?? ""
            let args = SSHManager.shared.loginShellArguments(
                for: host,
                running: "tmux new-session -A -s \(SSHManager.shellEscaped(session))\(startDir)"
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
