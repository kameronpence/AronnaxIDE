import SwiftUI
import SwiftTerm

/// Drives the CLI coding agents (Claude Code + Codex). A segmented switcher picks
/// the active agent; the live terminal shows that agent's TUI attached to its tmux
/// session on the hub; the input bar sends typed prompts via `tmux send-keys`.
///
/// Because each agent lives in its own persistent tmux session on the mini,
/// switching agents (or a sleep/wake reconnect) just re-attaches — the agents and
/// any work they're doing keep running.
struct ChatPane: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedAgent: Agent = .claude
    @State private var input: String = ""
    @State private var sendError: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Agent", selection: $selectedAgent) {
                ForEach(Agent.allCases) { agent in
                    Text(agent.displayName).tag(agent)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            AgentTerminalView(agent: selectedAgent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            inputBar
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                TextField("Message \(selectedAgent.displayName)…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(trimmedInput.isEmpty)
            }
        }
        .padding(8)
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let text = trimmedInput
        guard !text.isEmpty else { return }
        guard let host = settings.hub else {
            sendError = "No hub host configured."
            return
        }
        let agent = selectedAgent
        input = ""
        sendError = nil
        Task {
            do {
                try await AgentController.sendKeys(text, to: agent, on: host)
            } catch {
                await MainActor.run {
                    sendError = "Couldn't send to \(agent.displayName): "
                        + error.localizedDescription
                }
            }
        }
    }
}

/// A live terminal attached to the selected agent's persistent tmux session on the
/// hub. Mirrors `TerminalPane`, but the attached session is chosen by `agent` and
/// switching agents re-attaches to the other session (the previous one keeps
/// running, detached).
private struct AgentTerminalView: NSViewRepresentable {
    let agent: Agent
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var wakeObserver: WakeObserver

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
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

        /// Called from `updateNSView`; re-attaches when the user switches agents or
        /// a wake/network reconnect signal advances.
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
