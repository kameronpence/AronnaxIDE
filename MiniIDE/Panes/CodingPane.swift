import SwiftUI
import SwiftTerm

/// Drives the CLI coding agents (Claude Code + Codex). The switcher picks Claude,
/// Codex, or Both; the live terminal(s) show the agent TUI(s) attached to their
/// tmux session(s) on the hub, and you type prompts straight into them. "Both"
/// shows the two agents side by side, each attached to its own session.
///
/// Because each agent lives in its own persistent tmux session on the mini,
/// switching layout (or a sleep/wake reconnect) just re-attaches — the agents and
/// any work they're doing keep running.
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
            AgentTerminalView(agent: .claude)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .codex:
            AgentTerminalView(agent: .codex)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .both:
            HSplitView {
                labeledAgent(.claude)
                labeledAgent(.codex)
            }
        }
    }

    /// One agent column in the side-by-side layout: a small title over its terminal
    /// so it's clear which agent is which.
    private func labeledAgent(_ agent: Agent) -> some View {
        VStack(spacing: 0) {
            Text(agent.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            Divider()
            AgentTerminalView(agent: agent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// How the Chat pane lays out the agents.
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

/// A live terminal attached to an agent's persistent tmux session on the hub.
/// Mirrors `TerminalPane`, but the attached session is chosen by `agent`; changing
/// `agent` re-attaches to the other session (the previous one keeps running,
/// detached).
private struct AgentTerminalView: NSViewRepresentable {
    let agent: Agent
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wakeObserver: WakeObserver

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = ClipboardTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        context.coordinator.start(view, host: settings.hub, agent: agent,
                                  workdir: settings.agentWorkdir,
                                  baselineSignal: wakeObserver.reconnectSignal)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.sync(view: nsView, host: settings.hub, agent: agent,
                                 workdir: settings.agentWorkdir,
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
        private var lastReconnectSignal = 0

        func start(_ view: LocalProcessTerminalView, host: Host?, agent: Agent,
                   workdir: String, baselineSignal: Int) {
            guard !started else { return }
            started = true
            lastReconnectSignal = baselineSignal
            currentAgent = agent
            launch(view, host: host, agent: agent, workdir: workdir,
                   reconnecting: false, generation: baselineSignal)
        }

        /// Called from `updateNSView`; re-attaches when the agent changes or a
        /// wake/network reconnect signal advances.
        func sync(view: LocalProcessTerminalView, host: Host?, agent: Agent,
                  workdir: String, signal: Int) {
            guard started else { return }
            let agentChanged = agent != currentAgent
            let reconnect = signal != lastReconnectSignal
            guard agentChanged || reconnect else { return }
            lastReconnectSignal = signal
            currentAgent = agent
            launch(view, host: host, agent: agent, workdir: workdir,
                   reconnecting: reconnect, generation: signal)
        }

        private func launch(_ view: LocalProcessTerminalView, host: Host?,
                            agent: Agent, workdir: String,
                            reconnecting: Bool, generation: Int) {
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
                running: AgentController.attachCommand(for: agent, workdir: workdir)
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
