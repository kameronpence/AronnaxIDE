import SwiftUI
import SwiftTerm

/// Drives the CLI coding agents (Claude Code + Codex). The switcher picks Claude,
/// Codex, or Both; each agent shows in its own column — a header with the agent's
/// name and *its own* permission-mode dropdown, over a live terminal attached to
/// that agent's tmux session on the hub. "Both" shows the two columns side by side,
/// each with its own dropdown, because the two CLIs have different permission modes.
///
/// Because each agent lives in its own persistent tmux session, switching layout
/// (or a sleep/wake reconnect) just re-attaches — the agents keep running.
struct CodingPane: View {
    @State private var layout: AgentLayout = .claude

    var body: some View {
        VStack(spacing: 0) {
            Picker("Layout", selection: $layout) {
                ForEach(AgentLayout.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .claude:
            AgentColumn(agent: .claude)
        case .codex:
            AgentColumn(agent: .codex)
        case .both:
            HSplitView {
                AgentColumn(agent: .claude)
                AgentColumn(agent: .codex)
            }
        }
    }
}

/// How the Coding pane lays out the agents.
enum AgentLayout: String, CaseIterable, Identifiable {
    case claude
    case codex
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .both:   return "Both"
        }
    }
}

/// One agent's column: a header with its name + its own permission-mode dropdown,
/// over the live terminal. The dropdown shows that agent's modes (Claude and Codex
/// differ), and switching it restarts only that agent's session, after confirming.
private struct AgentColumn: View {
    let agent: Agent
    @EnvironmentObject private var settings: AppSettings
    @State private var showRestartWarning = false
    @State private var pendingClaude: ClaudeMode?
    @State private var pendingCodex: CodexMode?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(agent.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                modePicker
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            AgentTerminalView(agent: agent, workdir: settings.activePath, extraArgs: extraArgs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Restart \(agent.displayName) to switch mode?",
                            isPresented: $showRestartWarning, titleVisibility: .visible) {
            Button("Restart in \(pendingLabel) mode", role: .destructive) { applyPending() }
            Button("Cancel", role: .cancel) { clearPending() }
        } message: {
            Text("Switching the permission mode ends \(agent.displayName)'s running session and "
                + "starts it fresh — any in-progress state in that session is lost.")
        }
    }

    /// The dropdown — Claude's modes or Codex's, depending on the agent. Selecting a
    /// new mode stages it and raises the restart confirmation instead of applying
    /// immediately (so the picker stays on the current mode until confirmed).
    @ViewBuilder private var modePicker: some View {
        switch agent {
        case .claude:
            Picker("Mode", selection: Binding(
                get: { settings.claudeMode },
                set: { newMode in
                    guard newMode != settings.claudeMode else { return }
                    pendingClaude = newMode
                    showRestartWarning = true
                })) {
                ForEach(ClaudeMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Claude's permission mode. Switching restarts Claude's session.")
        case .codex:
            Picker("Mode", selection: Binding(
                get: { settings.codexMode },
                set: { newMode in
                    guard newMode != settings.codexMode else { return }
                    pendingCodex = newMode
                    showRestartWarning = true
                })) {
                ForEach(CodexMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Codex's approval mode. Switching restarts Codex's session.")
        }
    }

    /// The agent's current launch flags, from its own mode.
    private var extraArgs: [String] {
        switch agent {
        case .claude: return settings.claudeMode.launchArgs
        case .codex:  return settings.codexMode.launchArgs
        }
    }

    private var pendingLabel: String { pendingClaude?.label ?? pendingCodex?.label ?? "" }

    private func applyPending() {
        if let mode = pendingClaude { settings.claudeMode = mode }
        if let mode = pendingCodex { settings.codexMode = mode }
        clearPending()
    }

    private func clearPending() {
        pendingClaude = nil
        pendingCodex = nil
    }
}

/// A live terminal attached to an agent's persistent tmux session on the hub,
/// launched with `extraArgs` (the agent's permission-mode flags). Changing
/// `extraArgs` recreates the session so the new mode actually takes effect; an
/// agent/workdir change or a wake/reconnect just re-attaches.
private struct AgentTerminalView: NSViewRepresentable {
    let agent: Agent
    let workdir: String       // explicit so a project switch re-renders + re-attaches
    let extraArgs: [String]   // explicit so a mode switch re-renders + relaunches
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wakeObserver: WakeObserver

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = ClipboardTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        context.coordinator.start(view, host: settings.activeHost, agent: agent,
                                  workdir: workdir, extraArgs: extraArgs,
                                  baselineSignal: wakeObserver.reconnectSignal)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.sync(view: nsView, host: settings.activeHost, agent: agent,
                                 workdir: workdir, extraArgs: extraArgs,
                                 signal: wakeObserver.reconnectSignal)
    }

    /// Terminate the local ssh client when the pane goes away — the agent's tmux
    /// session keeps running on the mini and resumes on the next attach.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if nsView.process.running {
            nsView.terminate()
        }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private var started = false
        private var currentAgent: Agent?
        private var currentWorkdir: String?
        private var currentArgs: [String]?
        private var currentHost: Host?
        private var lastReconnectSignal = 0

        func start(_ view: LocalProcessTerminalView, host: Host?, agent: Agent,
                   workdir: String, extraArgs: [String], baselineSignal: Int) {
            guard !started else { return }
            started = true
            lastReconnectSignal = baselineSignal
            currentAgent = agent
            currentWorkdir = workdir
            currentArgs = extraArgs
            currentHost = host
            launch(view, host: host, agent: agent, workdir: workdir, extraArgs: extraArgs,
                   recreate: false, reconnecting: false, generation: baselineSignal)
        }

        /// Called from `updateNSView`; re-attaches when the agent, workdir, or mode
        /// flags change, or a wake/network reconnect signal advances. A mode change
        /// recreates the session (new launch flags); the others just re-attach.
        func sync(view: LocalProcessTerminalView, host: Host?, agent: Agent,
                  workdir: String, extraArgs: [String], signal: Int) {
            guard started else { return }
            let agentChanged = agent != currentAgent
            let workdirChanged = workdir != currentWorkdir
            let argsChanged = extraArgs != currentArgs
            let hostChanged = host?.id != currentHost?.id
            let reconnect = signal != lastReconnectSignal
            guard agentChanged || workdirChanged || argsChanged || hostChanged || reconnect else { return }
            lastReconnectSignal = signal
            currentAgent = agent
            currentWorkdir = workdir
            currentArgs = extraArgs
            currentHost = host
            launch(view, host: host, agent: agent, workdir: workdir, extraArgs: extraArgs,
                   recreate: argsChanged, reconnecting: reconnect, generation: signal)
        }

        private func launch(_ view: LocalProcessTerminalView, host: Host?,
                            agent: Agent, workdir: String, extraArgs: [String],
                            recreate: Bool, reconnecting: Bool, generation: Int) {
            guard let host else {
                view.feed(text: "No hub host configured.\r\n")
                return
            }

            // Replace any live client first; only the remote tmux should persist.
            if view.process.running {
                view.terminate()
            }
            // On reconnect the post-wake socket is stale, so drop it for a fresh
            // master — once per signal across all panes, never on first attach.
            if reconnecting {
                SSHManager.shared.resetMasterOnce(for: host, generation: generation)
            }

            let verb = reconnecting ? "Reconnecting" : "Connecting"
            view.feed(text: "\r\n\(verb) to \(agent.displayName) — tmux "
                + "\"\(agent.tmuxSession)\" on \(host.displayName)…\r\n")

            let args = SSHManager.shared.loginShellArguments(
                for: host,
                running: AgentController.attachCommand(for: agent, workdir: workdir,
                                                       extraArgs: extraArgs, recreate: recreate),
                execProcess: false   // multi-statement: set mouse-on, then attach
            )
            view.startProcess(executable: SSHManager.shared.sshExecutable, args: args)
        }

        // MARK: LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let suffix = exitCode.map { " (exit \($0))" } ?? ""
            source.feed(text: "\r\n[agent session ended\(suffix). It keeps running on "
                + "the mini; switch away and back, or wake/reconnect, to re-attach.]\r\n")
        }
    }
}
