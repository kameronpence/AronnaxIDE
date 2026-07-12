import Foundation

/// Which surface a pane is showing. On iPad each pane leaf holds its own `AgentTarget`,
/// so this is the persisted leaf payload — hence `Codable`. `terminal`/`claude`/`codex` are
/// PTY-backed; `beads` (and future Git/Vault/Health) is a non-terminal "data" surface with no
/// PTY — see `isTerminal`.
enum AgentTarget: String, CaseIterable, Identifiable, Codable {
    case terminal, claude, codex, beads
    var id: String { rawValue }
    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .beads:    return "Beads"
        }
    }

    /// True for surfaces backed by a live PTY (get a `PaneSession`); false for data panes.
    var isTerminal: Bool { self != .beads }
}

/// Builds the remote commands the iOS app runs over the PTY. Mirrors the macOS
/// AgentController's tmux/session conventions so the phone attaches to the *same*
/// sessions the Mac app creates (session name = agent + FNV-1a suffix of the workdir).
/// (To be unified with the macOS AgentController in the shared-code refactor.)
enum AgentCommands {
    static func shellEscaped(_ token: String) -> String {
        "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Short, stable, tmux-safe suffix per workdir — identical algorithm to the Mac app.
    static func sessionSuffix(for workdir: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in workdir.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "-%08x", UInt32(truncatingIfNeeded: hash))
    }

    /// The command to run in the PTY shell for a target. `nil` = a plain login shell
    /// (Terminal). Claude/Codex attach to their per-project tmux session, creating it
    /// (with the agent + PATH) if it doesn't exist — matching the Mac app, so both
    /// clients share one live session.
    static func attachCommand(target: AgentTarget, workdir: String) -> String? {
        switch target {
        case .terminal, .beads:
            // .beads has no PTY (rendered by BeadsView, never opens a PaneSession); listed here
            // only for exhaustiveness. .terminal = a plain login shell.
            return nil
        case .claude, .codex:
            let name = target == .claude ? "agent-claude" : "agent-codex"
            let bin = target == .claude
                ? "claude --permission-mode auto"
                : "codex --ask-for-approval never --sandbox danger-full-access"
            let session = shellEscaped(name + sessionSuffix(for: workdir))
            let dir = shellEscaped(workdir)
            let launched = "env \"PATH=$HOME/.local/bin:/usr/local/bin:$PATH\" \(bin)"
            return "tmux new-session -A -d -s \(session) -c \(dir) \(launched); "
                + "tmux set -t \(session) mouse on; tmux attach -t \(session)"
        }
    }
}
