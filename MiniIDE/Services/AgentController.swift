import Foundation

/// A CLI coding agent the Coding pane drives. Each runs its full-screen TUI in its
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

/// Claude Code's permission modes — exactly the ones its own UI cycles through.
/// Each maps to a `--permission-mode` value; bypass uses the explicit flag so it
/// also clears the workspace-trust gate.
enum ClaudeMode: String, CaseIterable, Identifiable {
    case acceptEdits
    case plan
    case auto
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .acceptEdits:       return "Accept Edits"
        case .plan:              return "Plan Mode"
        case .auto:              return "Auto Mode"
        case .bypassPermissions: return "Bypass Permissions"
        }
    }

    var launchArgs: [String] {
        switch self {
        case .bypassPermissions: return ["--dangerously-skip-permissions"]
        default:                 return ["--permission-mode", rawValue]
        }
    }
}

/// Codex's approval presets, mapped to its `--ask-for-approval` + `--sandbox` flags.
enum CodexMode: String, CaseIterable, Identifiable {
    case askForApproval
    case approveForMe
    case fullAccess

    var id: String { rawValue }

    var label: String {
        switch self {
        case .askForApproval: return "Ask for Approval"
        case .approveForMe:   return "Approve for Me"
        case .fullAccess:     return "Full Access"
        }
    }

    var launchArgs: [String] {
        switch self {
        case .askForApproval: return ["--ask-for-approval", "untrusted", "--sandbox", "workspace-write"]
        case .approveForMe:   return ["--ask-for-approval", "on-request", "--sandbox", "workspace-write"]
        case .fullAccess:     return ["--ask-for-approval", "never", "--sandbox", "danger-full-access"]
        }
    }
}

/// Builds the remote command that attaches the Coding pane's terminal to an agent's
/// persistent tmux session on the hub.
enum AgentController {

    /// Remote command that attaches to `agent`'s tmux session — creating it (with
    /// the agent CLI + `extraArgs` running in `workdir`) if it doesn't exist. `-A`
    /// makes re-attach lossless. When `recreate` is true (a permission-mode change),
    /// the old session is killed first — in the same command, so there's no race —
    /// so the new flags actually take effect instead of re-attaching the stale one.
    static func attachCommand(for agent: Agent, workdir: String,
                              extraArgs: [String], recreate: Bool = false) -> String {
        let session = SSHManager.shellEscaped(agent.tmuxSession + sessionSuffix(for: workdir))
        let dir = SSHManager.shellEscaped(workdir)
        // Binary + mode flags, each escaped separately so tmux receives them as
        // distinct argv entries (not one quoted blob).
        let argv = ([agent.launchCommand] + extraArgs)
            .map(SSHManager.shellEscaped)
            .joined(separator: " ")
        // Scope tmux mouse-on to this agent session so the wheel scrolls Codex's
        // history (Codex runs on the normal screen and doesn't grab the mouse). The
        // user's global mouse-off — and their manual tmux sessions — stay untouched.
        let attach = "tmux new-session -A -s \(session) -c \(dir) \(argv); tmux set -t \(session) mouse on"
        return recreate ? "tmux kill-session -t \(session) 2>/dev/null; \(attach)" : attach
    }

    /// A short, stable, tmux-safe suffix derived from the project directory (FNV-1a),
    /// so each project maps to its own agent session. Exposed so the Health panel can
    /// map a session name like `agent-claude-1a2b3c4d` back to its project.
    static func sessionSuffix(for workdir: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in workdir.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "-%08x", UInt32(truncatingIfNeeded: hash))
    }
}
