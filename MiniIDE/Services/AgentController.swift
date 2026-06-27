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

/// Builds the remote command that attaches the Chat pane's terminal to an agent's
/// persistent tmux session on the hub. The user types directly into that attached
/// terminal, so there's nothing else to route — the durable state is the tmux
/// session on the mini.
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
}
