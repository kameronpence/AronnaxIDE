import Foundation

/// A CLI coding agent the Chat pane drives. Each runs its full-screen TUI in its
/// own persistent tmux session on the hub, so detaching/reattaching (or a
/// sleep/wake reconnect) never interrupts the agent.
enum Agent: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }

    /// tmux session that hosts this agent's TUI on the hub.
    var tmuxSession: String {
        switch self {
        case .claude: return "agent-claude"
        case .codex:  return "agent-codex"
        }
    }

    /// Command that launches the agent CLI.
    var launchCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        }
    }
}

/// Drives the CLI agents over the hub's tmux: attach-or-create each agent's
/// session in the vault, and forward chat input to it via `tmux send-keys`.
///
/// Stateless on purpose — the durable state is the tmux session on the hub. The
/// Chat pane attaches to the session (via SwiftTerm) and routes typed prompts
/// through `sendKeys`.
enum AgentController {

    /// Remote command that attaches to `agent`'s tmux session — creating it, with
    /// the agent CLI running in `workdir`, if it doesn't exist yet. `-A` makes
    /// re-attach lossless; `-c` starts a *new* session in the vault so the agent's
    /// "memory" is the same notes the user sees. Passed to
    /// `SSHManager.loginShellArguments`, which wraps it in `exec zsh -lc` so tmux
    /// and the agent binaries are on PATH.
    static func attachCommand(for agent: Agent, workdir: String) -> String {
        let session = SSHManager.shellEscaped(agent.tmuxSession)
        let dir = SSHManager.shellEscaped(workdir)
        let cmd = SSHManager.shellEscaped(agent.launchCommand)
        return "tmux new-session -A -s \(session) -c \(dir) \(cmd)"
    }

    /// Sends one line of input to `agent`'s tmux session: the literal prompt text,
    /// then a separate Enter to submit it.
    ///
    /// - `-l` keeps the text literal so characters like `;` or `$` are typed, not
    ///   interpreted as tmux key names.
    /// - The whole thing runs through a **login** shell (`zsh -lc`) so `tmux` is on
    ///   PATH — a plain non-interactive ssh command shell would not find it
    ///   (it lives in `~/.local/bin` / Homebrew), the same reason the terminal
    ///   panes wrap their commands in a login shell.
    static func sendKeys(_ text: String, to agent: Agent, on host: Host) async throws {
        let session = SSHManager.shellEscaped(agent.tmuxSession)
        let literal = SSHManager.shellEscaped(text)
        let inner = "tmux send-keys -t \(session) -l \(literal)"
            + " && tmux send-keys -t \(session) Enter"
        let remote = "zsh -lc \(SSHManager.shellEscaped(inner))"
        let result = try await SSHManager.shared.runShell(remote, on: host)
        guard result.ok else {
            let why = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.launchFailed(why.isEmpty ? "tmux send-keys failed" : why)
        }
    }
}
