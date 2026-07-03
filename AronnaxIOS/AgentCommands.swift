import Foundation

/// Which surface the single terminal is showing. One at a time — no split.
enum AgentTarget: String, CaseIterable, Identifiable {
    case terminal, claude, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        }
    }
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
        case .terminal:
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
